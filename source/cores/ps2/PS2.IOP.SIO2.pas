unit PS2.IOP.SIO2;

// SIO2, the IOP's serial controller for pads, multitaps and memory cards, as
// IOP drivers (SIO2MAN, DBCMAN, SIO2D, DS2U_D...) program it: a queue of
// transfer descriptors (SEND3), per-port control words, data in and out
// through the register FIFO or IOP DMA channels 11/12, and the completion
// interrupt. Two DualShock 2 pads answer the controller protocol (read data,
// config mode, mode lock, model/actuator/mode queries, poll mask); multitap
// and memory card commands report no device (memory cards stay high level).
// Protocol after Play! (BSD-2, Iop_Sio2).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.IOP.Pad;

type
  TPS2SIO2Pad = record
    Mode: Byte;
    ConfigMode: Boolean;
    PollMask: array[0..2] of Byte;
  end;
  PPS2SIO2Pad = ^TPS2SIO2Pad;

  TPS2SIO2 = class
  private
    FRegs: array[0..15] of Cardinal;
    FCtrl1, FCtrl2: array[0..3] of Cardinal;
    FStat6C: Cardinal;
    FIndex: Integer;
    FInput, FOutput: TList<Byte>;
    FPads: array[0..1] of TPS2SIO2Pad;
    procedure ProcessCommand;
    procedure ProcessController(Port, Offset, DstSize: Integer);
    procedure SetOut(Offset: Integer; Value: Byte); inline;
    function InByte(Index: Integer): Byte; inline;
  public
    // The pad states (front-end inputs).
    PadSource: TPS2PadMan;
    // Raised when a transfer completes (SIO2 interrupt line).
    OnInterrupt: TProc;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    // IOP DMA 11 (to SIO2) and 12 (from SIO2): blocks of BlockSize bytes.
    procedure DMAIn(Data: PByte; BlockSize, Blocks: Integer);
    procedure DMAOut(Data: PByte; BlockSize, Blocks: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  IdDigital = $41;
  IdAnalog = $73;
  IdPressure = $79;
  IdConfig = $F3;
  ModelInfo: array[0..5] of Byte = ($03, $02, $00, $02, $01, $00);
  ActInfo: array[0..4, 0..4] of Byte = (
    ($00, $01, $02, $00, $0A),
    ($00, $01, $01, $01, $14),
    ($00, $02, $00, $01, $00),
    ($00, $00, $04, $00, $00),
    ($00, $00, $07, $00, $00));
  // Pressure bytes after the sticks: right, left, up, down, triangle,
  // circle, cross, square, L1, R1, L2, R2 (pad bits, active high).
  PressureBits: array[0..11] of Word = ($0020, $0080, $0010, $0040, $1000, $2000, $4000, $8000, $0400, $0800,
    $0100, $0200);

constructor TPS2SIO2.Create;
begin
  inherited Create;
  FInput := TList<Byte>.Create;
  FOutput := TList<Byte>.Create;
  Reset;
end;

destructor TPS2SIO2.Destroy;
begin
  FInput.Free;
  FOutput.Free;
  inherited;
end;

procedure TPS2SIO2.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FCtrl1, SizeOf(FCtrl1), 0);
  FillChar(FCtrl2, SizeOf(FCtrl2), 0);
  FStat6C := 0;
  FIndex := 0;
  FInput.Clear;
  FOutput.Clear;
  for var P := 0 to 1 do
  begin
    FPads[P].Mode := IdAnalog;
    FPads[P].ConfigMode := False;
    FPads[P].PollMask[0] := $FF;
    FPads[P].PollMask[1] := $FF;
    FPads[P].PollMask[2] := $03;
  end;
end;

function TPS2SIO2.InByte(Index: Integer): Byte;
begin
  if Index < FInput.Count then
    Result := FInput[Index]
  else
    Result := 0;
end;

procedure TPS2SIO2.SetOut(Offset: Integer; Value: Byte);
begin
  if Offset < FOutput.Count then
    FOutput[Offset] := Value;
end;

function TPS2SIO2.Read(Address: Cardinal): Cardinal;
begin
  case Address of
    $1F808264:
      if FOutput.Count > 0 then
      begin
        Result := FOutput[0];
        FOutput.Delete(0);
      end
      else
        Result := $FF;
    $1F80826C: Result := FStat6C;
    $1F808270, $1F808274: Result := 0;
  else
    if (Address >= $1F808200) and (Address < $1F808240) then
      Result := FRegs[(Address - $1F808200) div 4]
    else if (Address >= $1F808240) and (Address < $1F808260) then
    begin
      var Port := Integer((Address - $1F808240) div 8);
      if ((Address - $1F808240) and 4) = 0 then
        Result := FCtrl1[Port]
      else
        Result := FCtrl2[Port];
    end
    else
      Result := 0;
  end;
end;

procedure TPS2SIO2.Write(Address, Value: Cardinal);
begin
  if (Address >= $1F808200) and (Address < $1F808240) then
  begin
    FRegs[(Address - $1F808200) div 4] := Value;
    Exit;
  end;
  if (Address >= $1F808240) and (Address < $1F808260) then
  begin
    var Port := Integer((Address - $1F808240) div 8);
    if ((Address - $1F808240) and 4) = 0 then
      FCtrl1[Port] := Value
    else
      FCtrl2[Port] := Value;
    Exit;
  end;
  case Address of
    $1F808268:
      begin
        if Value = $0C then
          FIndex := 0;
        if Value = $01 then
          if Assigned(OnInterrupt) then
            OnInterrupt;
      end;
    $1F808260:
      begin
        FInput.Add(Byte(Value));
        ProcessCommand;
      end;
  end;
end;

procedure TPS2SIO2.DMAIn(Data: PByte; BlockSize, Blocks: Integer);
begin
  for var B := 0 to Blocks - 1 do
  begin
    for var K := 0 to BlockSize - 1 do
      FInput.Add(Data[B * BlockSize + K]);
    ProcessCommand;
  end;
end;

procedure TPS2SIO2.DMAOut(Data: PByte; BlockSize, Blocks: Integer);
begin
  for var B := 0 to Blocks - 1 do
  begin
    var Reg := FRegs[Min(B, 15)];
    var DstSize := Integer((Reg shr 18) and $1FF);
    for var K := 0 to DstSize - 1 do
      if FOutput.Count > 0 then
      begin
        if K < BlockSize then
          Data[B * BlockSize + K] := FOutput[0];
        FOutput.Delete(0);
      end;
  end;
end;

procedure TPS2SIO2.ProcessCommand;
begin
  if FIndex > 15 then
    Exit;
  var Reg := FRegs[FIndex];
  var SrcSize := Integer((Reg shr 8) and $1FF);
  var DstSize := Integer((Reg shr 18) and $1FF);
  if FInput.Count < SrcSize then
    Exit;
  var Port := Integer(Reg and 3);
  var Device := FCtrl2[Port];
  var Offset := FOutput.Count;
  FStat6C := 0;
  for var K := 0 to DstSize - 1 do
    FOutput.Add($FF);
  if (Device = $00030064) or (Device = $0005FFFF) or (Port > 1) then
    // Multitap or memory card: nothing answers.
    FStat6C := $1D100
  else
    ProcessController(Port, Offset, DstSize);
  FInput.Clear;
  Inc(FIndex);
end;

procedure TPS2SIO2.ProcessController(Port, Offset, DstSize: Integer);
begin
  if DstSize < 3 then
    Exit;
  var Pad: PPS2SIO2Pad := @FPads[Port];
  var Buttons: Word := 0;
  var Axes: array[0..3] of Byte;
  FillChar(Axes, SizeOf(Axes), $80);
  if PadSource <> nil then
  begin
    Buttons := PadSource.Pads[Port].Buttons;
    for var K := 0 to 3 do
      Axes[K] := PadSource.Pads[Port].Axes[K];
  end;
  var Bits := not Buttons;
  SetOut(Offset, $FF);
  if Pad.ConfigMode then
    SetOut(Offset + 1, IdConfig)
  else
    SetOut(Offset + 1, Pad.Mode);
  SetOut(Offset + 2, $5A);
  case InByte(1) of
    $40:
      begin
        SetOut(Offset + 3, 0);
        SetOut(Offset + 4, 0);
        SetOut(Offset + 5, 2);
        SetOut(Offset + 6, 0);
        SetOut(Offset + 7, 0);
        SetOut(Offset + 8, $5A);
      end;
    $41:
      if Pad.Mode = IdDigital then
        for var K := 3 to 8 do
          SetOut(Offset + K, 0)
      else
      begin
        SetOut(Offset + 3, Pad.PollMask[0]);
        SetOut(Offset + 4, Pad.PollMask[1]);
        SetOut(Offset + 5, Pad.PollMask[2]);
        SetOut(Offset + 6, 0);
        SetOut(Offset + 7, 0);
        SetOut(Offset + 8, $5A);
      end;
    $42, $43:
      begin
        if (InByte(1) = $43) and Pad.ConfigMode then
        begin
          // In config mode 43h only switches config mode off/on.
          for var K := 3 to DstSize - 1 do
            SetOut(Offset + K, 0);
        end
        else
        begin
          SetOut(Offset + 3, Byte(Bits));
          SetOut(Offset + 4, Byte(Bits shr 8));
          if DstSize >= 9 then
            for var K := 0 to 3 do
              SetOut(Offset + 5 + K, Axes[K]);
          if DstSize >= 21 then
            for var K := 0 to 11 do
              if (Buttons and PressureBits[K]) <> 0 then
                SetOut(Offset + 9 + K, $FF)
              else
                SetOut(Offset + 9 + K, 0);
        end;
        if InByte(1) = $43 then
          Pad.ConfigMode := InByte(3) = 1;
      end;
    $44:
      begin
        for var K := 3 to DstSize - 1 do
          SetOut(Offset + K, 0);
        if InByte(3) = 1 then
          Pad.Mode := IdAnalog
        else
          Pad.Mode := IdDigital;
      end;
    $45:
      begin
        for var K := 0 to 5 do
          SetOut(Offset + 3 + K, ModelInfo[K]);
        SetOut(Offset + 5, Ord(Pad.Mode <> IdDigital));
      end;
    $46:
      for var K := 0 to 4 do
        SetOut(Offset + 4 + K, ActInfo[Ord(InByte(3) <> 0), K]);
    $47:
      for var K := 0 to 4 do
        SetOut(Offset + 4 + K, ActInfo[2, K]);
    $4C:
      for var K := 0 to 4 do
        SetOut(Offset + 4 + K, ActInfo[3 + Ord(InByte(3) <> 0), K]);
    $4D:
      ;
    $4F:
      begin
        Pad.Mode := IdPressure;
        for var K := 3 to 7 do
          SetOut(Offset + K, 0);
        SetOut(Offset + 8, $5A);
        Pad.PollMask[0] := InByte(3);
        Pad.PollMask[1] := InByte(4);
        Pad.PollMask[2] := InByte(5);
      end;
  end;
end;

procedure TPS2SIO2.SerializeState(State: TStateArchive);

  procedure Bytes(L: TList<Byte>);
  begin
    var N := L.Count;
    State.Field(N, SizeOf(N));
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
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FCtrl1, SizeOf(FCtrl1));
  State.Field(FCtrl2, SizeOf(FCtrl2));
  State.Field(FStat6C, SizeOf(FStat6C));
  State.Field(FIndex, SizeOf(FIndex));
  State.Field(FPads, SizeOf(FPads));
  Bytes(FInput);
  Bytes(FOutput);
end;

end.
