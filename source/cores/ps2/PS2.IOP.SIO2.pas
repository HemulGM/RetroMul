unit PS2.IOP.SIO2;

// SIO2, the IOP's serial controller for pads, multitaps, infrared and
// memory cards, as IOP drivers (SIO2MAN, DBCMAN, SIO2D, DS2U_D...) program
// it. A transfer is a queue of up to 16 entries (SEND3: port, bytes to send,
// bytes to receive, PIO or DMA each way) with timing words per port
// (SEND1/SEND2). The bytes to send come from the input FIFO, which the CPU
// or DMA channel 11 fills (an entry sending by DMA takes one DMA block);
// replies go to the output FIFO, which the CPU or DMA channel 12 empties (an
// entry receiving by DMA gives one block). Setting CTRL bit 0 runs the
// queue; RECV1 then shows the entries no device answered and the interrupt
// flags completion. The first byte of a command picks the device: 01h pad,
// 21h multitap, 61h infrared, 81h memory card. DualShock 2 pads answer on
// ports 0 and 1, memory cards (as flash, TPS2CardLink) on ports 2 and 3.
// References: ps2tek (SIO2), ps2sdk sio2man and the SIO2 register notes of
// mx4sio_bd (AFL 2.0).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  Core.Snapshots, PS2.IOP.Pad, PS2.IOP.MemoryCard;

type
  TPS2SIO2 = class
  private
    FRAM: PByte;
    FSend3: array[0..15] of Cardinal;
    FSend1, FSend2: array[0..3] of Cardinal;
    FCtrl, FRecv1, FIStat: Cardinal;
    FIn, FOut: TList<Byte>;
    // DMA block size of the input FIFO data (0: written by the CPU).
    FInBlock: Integer;
    // Reply sizes of the entries waiting in the output FIFO for DMA.
    FOutSizes: TList<Integer>;
    // DMA channel 12 started before the replies were there.
    FOutArmed: Boolean;
    FOutAddress: Cardinal;
    FOutBlock, FOutBlocks: Integer;
    FCardLinks: array[0..1] of TPS2CardLink;
    procedure RunQueue;
    procedure Exchange(Port: Integer; Cmd, Reply: PByte; Len: Integer; out Answered: Boolean);
    function DeliverOut: Boolean;
  public
    // The pads (front-end inputs and their controller state).
    PadSource: TPS2PadMan;
    // The memory cards (CardSource's card N is in SIO2 port 2 + N).
    CardSource: TPS2MCServer;
    // Raised when a transfer completes (SIO2 interrupt line).
    OnInterrupt: TProc;
    // DMA channel 12 delivered its blocks (the channel completes).
    OnOutDMADone: TProc;
    // Diagnostics: transfers when assigned.
    Log: TStrings;
    constructor Create(IOPRAM: PByte);
    destructor Destroy; override;
    procedure Reset;
    // A memory card in SIO2 port 2 or 3.
    function CardPresent(Port: Integer): Boolean;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    // DMA channel 11: Blocks blocks of BlockSize bytes into the input FIFO.
    procedure DMAIn(Data: PByte; BlockSize, Blocks: Integer);
    // DMA channel 12 starts: Blocks blocks of BlockSize bytes to IOP RAM at
    // Address, now or once a transfer has produced them (OnOutDMADone).
    procedure StartOutDMA(Address: Cardinal; BlockSize, Blocks: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  PS2.Types;

const
  RegSend3 = $1F808200;
  RegSend12 = $1F808240;
  RegFIFOIn = $1F808260;
  RegFIFOOut = $1F808264;
  RegCtrl = $1F808268;
  RegRecv1 = $1F80826C;
  RegRecv2 = $1F808270;
  RegRecv3 = $1F808274;
  RegIStat = $1F808280;

  // CTRL: start, resume, reset the queue, reset the FIFOs (all act once).
  CtrlStart = $1;
  CtrlActions = $F;
  CtrlResetQueue = $4;
  CtrlResetFIFOs = $8;

  // SEND3: port, DMA for sending / receiving, sizes.
  EntryTxDMA = $10;
  EntryRxDMA = $20;

  // RECV1: idle, missing acknowledge and FIFO error, failed entries (bit
  // 16 + entry); bits 8-11 the next entry.
  Recv1Idle = $1000;
  Recv1NoAck = $C000;

  // IStat: transfer complete, error.
  IStatDone = $1;
  IStatError = $2;
  DevicePad = $01;
  DeviceCard = $81;

constructor TPS2SIO2.Create(IOPRAM: PByte);
begin
  inherited Create;
  FRAM := IOPRAM;
  FIn := TList<Byte>.Create;
  FOut := TList<Byte>.Create;
  FOutSizes := TList<Integer>.Create;
  Reset;
end;

destructor TPS2SIO2.Destroy;
begin
  FIn.Free;
  FOut.Free;
  FOutSizes.Free;
  inherited;
end;

procedure TPS2SIO2.Reset;
begin
  FillChar(FSend3, SizeOf(FSend3), 0);
  FillChar(FSend1, SizeOf(FSend1), 0);
  FillChar(FSend2, SizeOf(FSend2), 0);
  FCtrl := 0;
  FRecv1 := Recv1Idle;
  FIStat := 0;
  FIn.Clear;
  FOut.Clear;
  FOutSizes.Clear;
  FInBlock := 0;
  FOutArmed := False;
  FCardLinks[0].Reset;
  FCardLinks[1].Reset;
end;

function TPS2SIO2.CardPresent(Port: Integer): Boolean;
begin
  Result := (CardSource <> nil) and (Port >= 2) and (Port <= 3) and (CardSource.PortCard(Port - 2) <> nil);
end;

function TPS2SIO2.Read(Address: Cardinal): Cardinal;
begin
  case Address of
    RegFIFOOut:
      if FOut.Count > 0 then
      begin
        Result := FOut[0];
        FOut.Delete(0);
      end
      else
        Result := $FF;
    RegCtrl:
      Result := FCtrl;
    RegRecv1:
      Result := FRecv1;
    // Connection detect lines: all set.
      RegRecv2:
      Result := $F;
    // FIFO levels: input in bits 0-8, output in bits 16-24.
      RegRecv3:
      Result := Cardinal(Min(FIn.Count, $1FF)) or (Cardinal(Min(FOut.Count, $1FF)) shl 16);
    RegIStat:
      Result := FIStat;
  else
    if (Address >= RegSend3) and (Address < RegSend12) then
      Result := FSend3[(Address - RegSend3) div 4]
    else if (Address >= RegSend12) and (Address < RegFIFOIn) then
    begin
      var Port := Integer((Address - RegSend12) div 8);
      if ((Address - RegSend12) and 4) = 0 then
        Result := FSend1[Port]
      else
        Result := FSend2[Port];
    end
    else
      Result := 0;
  end;
end;

procedure TPS2SIO2.Write(Address, Value: Cardinal);
begin
  case Address of
    RegFIFOIn:
      FIn.Add(Byte(Value));
    RegCtrl:
      begin
        FCtrl := Value and not Cardinal(CtrlActions);
        if (Value and CtrlResetFIFOs) <> 0 then
        begin
          FIn.Clear;
          FOut.Clear;
          FOutSizes.Clear;
          FInBlock := 0;
        end;
        if (Value and CtrlResetQueue) <> 0 then
          FRecv1 := Recv1Idle;
        if (Value and CtrlStart) <> 0 then
          RunQueue;
      end;
    RegIStat:
      FIStat := FIStat and not Value;
  else
    if (Address >= RegSend3) and (Address < RegSend12) then
      FSend3[(Address - RegSend3) div 4] := Value
    else if (Address >= RegSend12) and (Address < RegFIFOIn) then
    begin
      var Port := Integer((Address - RegSend12) div 8);
      if ((Address - RegSend12) and 4) = 0 then
        FSend1[Port] := Value
      else
        FSend2[Port] := Value;
    end;
  end;
end;

procedure TPS2SIO2.Exchange(Port: Integer; Cmd, Reply: PByte; Len: Integer; out Answered: Boolean);
begin
  Answered := False;
  if (Len > 0) and (Cmd[0] = DevicePad) and (Port <= 1) and (PadSource <> nil) then
  begin
    Answered := True;
    PadSource.Devices[Port].Exchange(PadSource.Pads[Port], Cmd, Reply, Len);
  end
  else if (Len > 0) and (Cmd[0] = DeviceCard) and CardPresent(Port) then
  begin
    Answered := True;
    FCardLinks[Port - 2].Exchange(CardSource.PortCard(Port - 2), CardSource.CardNow, Cmd, Reply, Len);
  end
  else
    // Nobody drives the line: all ones.
    FillChar(Reply^, Len, $FF);
end;

// Runs the queue up to the first empty entry.
procedure TPS2SIO2.RunQueue;
var
  Cmd, Reply: array[0..511] of Byte;
begin
  var Failed: Cardinal := 0;
  var Count := 0;
  while Count < 16 do
  begin
    var Entry := FSend3[Count];
    if Entry = 0 then
      Break;
    var Port := Integer(Entry and 3);
    var TxSize := Integer((Entry shr 8) and $1FF);
    var RxSize := Integer((Entry shr 18) and $1FF);
    // Bytes to send; a DMA entry takes a whole block.
    var Take := TxSize;
    if ((Entry and EntryTxDMA) <> 0) and (FInBlock > 0) then
      Take := Max(1, (TxSize + FInBlock - 1) div FInBlock) * FInBlock;
    var Len := Max(TxSize, RxSize);
    FillChar(Cmd, Len, 0);
    for var K := 0 to Take - 1 do
      if FIn.Count > 0 then
      begin
        if K < TxSize then
          Cmd[K] := FIn[0];
        FIn.Delete(0);
      end;
    var Answered: Boolean;
    Exchange(Port, @Cmd[0], @Reply[0], Len, Answered);
    if not Answered then
      Failed := Failed or (Cardinal(1) shl Count);
    for var K := 0 to RxSize - 1 do
      FOut.Add(Reply[K]);
    if (Entry and EntryRxDMA) <> 0 then
      FOutSizes.Add(RxSize);
    if Log <> nil then
    begin
      var Hex := '';
      for var K := 0 to Min(Len, 24) - 1 do
        Hex := Hex + IntToHex(Reply[K], 2);
      Log.Add(Format('sio2 %d: %.8x %.2x %.2x -> %.2x %.2x answered=%d len %d: %s', [Count, Entry, Cmd[0], Cmd[1], Reply[1],
            Reply[2], Ord(Answered), Len, Hex]));
    end;
    Inc(Count);
  end;
  if FIn.Count = 0 then
    FInBlock := 0;
  FRecv1 := Recv1Idle or (Cardinal(Count and $F) shl 8);
  FIStat := FIStat or IStatDone;
  if Failed <> 0 then
  begin
    FRecv1 := FRecv1 or Recv1NoAck or (Failed shl 16);
    FIStat := FIStat or IStatError;
  end;
  if FOutArmed and DeliverOut then
  begin
    FOutArmed := False;
    if Assigned(OnOutDMADone) then
      OnOutDMADone;
  end;
  if Assigned(OnInterrupt) then
    OnInterrupt;
end;

procedure TPS2SIO2.DMAIn(Data: PByte; BlockSize, Blocks: Integer);
begin
  FInBlock := BlockSize;
  for var K := 0 to BlockSize * Blocks - 1 do
    FIn.Add(Data[K]);
end;

// Output FIFO data for the armed DMA: a block per entry received by DMA,
// else the FIFO as it is. False while there is nothing yet.
function TPS2SIO2.DeliverOut: Boolean;
begin
  if FOut.Count = 0 then
    Exit(False);
  var Dest := FOutAddress;
  for var B := 0 to FOutBlocks - 1 do
  begin
    var N := Min(FOutBlock, FOut.Count);
    if FOutSizes.Count > 0 then
    begin
      N := Min(FOutSizes[0], FOut.Count);
      FOutSizes.Delete(0);
    end;
    for var K := 0 to N - 1 do
    begin
      if K < FOutBlock then
        FRAM[(Dest + Cardinal(K)) and PS2IOPRAMMask] := FOut[0];
      FOut.Delete(0);
    end;
    Inc(Dest, FOutBlock);
    if FOut.Count = 0 then
      Break;
  end;
  Result := True;
end;

procedure TPS2SIO2.StartOutDMA(Address: Cardinal; BlockSize, Blocks: Integer);
begin
  FOutAddress := Address;
  FOutBlock := BlockSize;
  FOutBlocks := Blocks;
  FOutArmed := not DeliverOut;
  if not FOutArmed and Assigned(OnOutDMADone) then
    OnOutDMADone;
end;

procedure TPS2SIO2.SerializeState(State: TStateArchive);

  procedure Bytes(L: TList<Byte>);
  begin
    var N: NativeInt := L.Count;
    State.NativeCount(N);
    if State.Loading then
    begin
      if (N < 0) or (N > $100000) then
        raise EReadError.Create('PS2 snapshot SIO2');
      L.Clear;
      for var K := 0 to N - 1 do
      begin
        var B: Byte;
        State.Field(B, 1);
        L.Add(B);
      end;
    end
    else
      for var K := 0 to N - 1 do
      begin
        var B := L[K];
        State.Field(B, 1);
      end;
  end;

begin
  State.Field(FSend3, SizeOf(FSend3));
  State.Field(FSend1, SizeOf(FSend1));
  State.Field(FSend2, SizeOf(FSend2));
  State.Field(FCtrl, SizeOf(FCtrl));
  State.Field(FRecv1, SizeOf(FRecv1));
  State.Field(FIStat, SizeOf(FIStat));
  State.Field(FInBlock, SizeOf(FInBlock));
  State.Field(FOutArmed, SizeOf(FOutArmed));
  State.Field(FOutAddress, SizeOf(FOutAddress));
  State.Field(FOutBlock, SizeOf(FOutBlock));
  State.Field(FOutBlocks, SizeOf(FOutBlocks));
  State.Field(FCardLinks, SizeOf(FCardLinks));
  Bytes(FIn);
  Bytes(FOut);
  var N: NativeInt := FOutSizes.Count;
  State.NativeCount(N);
  if State.Loading then
  begin
    if (N < 0) or (N > 4096) then
      raise EReadError.Create('PS2 snapshot SIO2');
    FOutSizes.Clear;
    for var K := 0 to N - 1 do
    begin
      var V: Integer;
      State.Field(V, SizeOf(V));
      FOutSizes.Add(V);
    end;
  end
  else
    for var K := 0 to N - 1 do
    begin
      var V := FOutSizes[K];
      State.Field(V, SizeOf(V));
    end;
end;

end.

