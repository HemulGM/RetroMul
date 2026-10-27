unit PS1.DMA;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler,
  PS1.Bus;

type
  // Device side of DMA channels 0..5 (channel 6 only clears ordering tables).
  TPS1DMADevice = class abstract
  public
    // DREQ: whether the device can take or supply the next block.
    function DMARequest(Channel: Integer): Boolean; virtual;
    procedure DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer); virtual;
    procedure DMARead(Channel: Integer; Data: PCardinal; Count: Integer); virtual;
  end;

  TPS1StallRequest = procedure(Ready: Int64) of object;

  // A channel transfers in steps: all words (burst), one block (slice) or one
  // node (linked list). Each step's data moves at once while the CPU is held
  // off the bus for its duration; between slice/list steps the CPU gets a
  // short window. Completion (CHCR bit 24, DICR flags, IRQ3) follows the
  // last step.
  TPS1DMA = class
  private
    type
      TChannel = record
        Address, Block, Control: Cardinal;
      // A burst that started keeps going without DREQ (chopped bursts).
        Bursting: Cardinal;
      end;

      PChannel = ^TChannel;
  private
    FChannels: array[0..6] of TChannel;
    FPriority, FInterrupt: Cardinal;
    // 0 = idle, 1 = step in progress, 2 = CPU window between steps.
    FPhase: Integer;
    FBusyChannel: Integer;
    FBuffer: array of Cardinal;
    FScheduler: TPS1Scheduler;
    FBus: TPS1Bus;
    FIRQ: TPS1IRQRequest;
    FStall: TPS1StallRequest;
    function Runnable(Index: Integer): Boolean;
    function WordCost(Index: Integer): Integer;
    function Transfer(Index: Integer): Int64;
    function TransferWords(Index: Integer; Address: Cardinal; Count: Integer): Cardinal;
    function Finish(Index: Integer): Boolean;
    function Gap(Index: Integer): Integer;
    procedure UpdateMaster(Before: Boolean);
  public
    Devices: array[0..5] of TPS1DMADevice;
    constructor Create(Scheduler: TPS1Scheduler; Bus: TPS1Bus; const IRQ: TPS1IRQRequest; const Stall: TPS1StallRequest);
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    // Starts the highest-priority runnable channel; devices call it when
    // their DREQ rises.
    procedure Kick;
    procedure Event(Time: Int64);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  ControlStart = $01000000;
  ControlTrigger = $10000000;
  ControlChop = $00000100;
  ControlWritable = $71770703;
  OTCWritable = $51000000;
  // Per linked-list node overhead and the CPU window between blocks and list
  // nodes, fitted to the CPU share measured by ps1-tests dma/chain-looping
  // and the block timings of dma/chopping.
  ListNodeOverhead = 8;
  StepGap = 10;
  ChopOverhead = 6;

function TPS1DMADevice.DMARequest(Channel: Integer): Boolean;
begin
  Result := True;
end;

procedure TPS1DMADevice.DMAWrite(Channel: Integer; Data: PCardinal; Count: Integer);
begin
end;

procedure TPS1DMADevice.DMARead(Channel: Integer; Data: PCardinal; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    Data^ := $FFFFFFFF;
    Inc(Data);
  end;
end;

constructor TPS1DMA.Create(Scheduler: TPS1Scheduler; Bus: TPS1Bus; const IRQ: TPS1IRQRequest; const Stall: TPS1StallRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FBus := Bus;
  FIRQ := IRQ;
  FStall := Stall;
  Reset;
end;

procedure TPS1DMA.Reset;
begin
  FillChar(FChannels, SizeOf(FChannels), 0);
  FChannels[6].Control := $00000002;
  FPriority := $07654321;
  FInterrupt := 0;
  FPhase := 0;
  FBusyChannel := 0;
  FScheduler.Cancel(TPS1Event.DMA);
end;

function TPS1DMA.Runnable(Index: Integer): Boolean;
begin
  var C := FChannels[Index].Control;
  Result := ((C and ControlStart) <> 0) and (((FPriority shr (Index * 4 + 3)) and 1) <> 0);
  if not Result then
    Exit;

  if (C and ControlTrigger) <> 0 then
    Exit(True);

  // A burst starts on the first DREQ and then ignores it.
  var Mode := (C shr 9) and 3;
  if (Mode = 0) and (FChannels[Index].Bursting <> 0) then
    Exit(True);
  Result := (Mode <> 3) and (Index < 6) and (Devices[Index] <> nil) and Devices[Index].DMARequest(Index);
end;

// Cost in 1/16 cycles per word (psx-spx DMA transfer rates).
function TPS1DMA.WordCost(Index: Integer): Integer;
begin
  case Index of
    3:
      Result := FBus.DeviceCycles(6, 4, False) * 16;
    4:
      Result := 66;
    5:
      Result := 320;
  else
    Result := 17;
  end;
end;

function TPS1DMA.TransferWords(Index: Integer; Address: Cardinal; Count: Integer): Cardinal;
begin
  var C := FChannels[Index].Control;
  var Step: Cardinal := 4;
  if (C and 2) <> 0 then
    Step := Cardinal(-4);
  if Length(FBuffer) < Count then
    SetLength(FBuffer, Count);
  if Index = 6 then
  begin
    // Ordering table clear: each entry links to the previous address.
    for var I := 0 to Count - 1 do
    begin
      var Value: Cardinal := Sub32(Address, 4) and $FFFFFF;
      if I = Count - 1 then
        Value := $FFFFFF;
      PCardinal(@FBus.RAM[Address and $1FFFFC])^ := Value;
      Address := Sub32(Address, 4) and $FFFFFC;
    end;
    Exit(Address);
  end;

  var Device := Devices[Index];
  if (C and 1) <> 0 then
  begin
    for var I := 0 to Count - 1 do
    begin
      FBuffer[I] := PCardinal(@FBus.RAM[Address and $1FFFFC])^;
      Address := Add32(Address, Step) and $FFFFFC;
    end;
    if Device <> nil then
      Device.DMAWrite(Index, @FBuffer[0], Count);
  end
  else
  begin
    if Device <> nil then
      Device.DMARead(Index, @FBuffer[0], Count)
    else
      for var I := 0 to Count - 1 do
        FBuffer[I] := $FFFFFFFF;
    for var I := 0 to Count - 1 do
    begin
      PCardinal(@FBus.RAM[Address and $1FFFFC])^ := FBuffer[I];
      Address := Add32(Address, Step) and $FFFFFC;
    end;
  end;
  Result := Address;
end;

// Moves the data of one start and returns its duration in cycles.
function TPS1DMA.Transfer(Index: Integer): Int64;
begin
  var Ch: PChannel := @FChannels[Index];
  Ch.Control := Ch.Control and not ControlTrigger;
  var Cost: Int64;
  var Unit_ := WordCost(Index);
  case (Ch.Control shr 9) and 3 of
    0:
      begin
        var Count := Integer(Ch.Block and $FFFF);
        if Count = 0 then
          Count := $10000;
        if (Ch.Control and ControlChop) <> 0 then
        begin
          // Chopping moves a DMA window at a time and counts MADR and BCR.
          var Chunk := 1 shl ((Ch.Control shr 16) and 7);
          if Chunk > Count then
            Chunk := Count;
          Ch.Address := TransferWords(Index, Ch.Address and $FFFFFC, Chunk);
          Ch.Block := (Ch.Block and $FFFF0000) or Cardinal((Count - Chunk) and $FFFF);
          Ch.Bursting := 1;
          Cost := Int64(Chunk) * Unit_;
        end
        else
        begin
          TransferWords(Index, Ch.Address and $FFFFFC, Count);
          Cost := Int64(Count) * Unit_;
        end;
      end;
    1:
      begin
        var Size := Integer(Ch.Block and $FFFF);
        if Size = 0 then
          Size := $10000;
        Ch.Address := TransferWords(Index, Ch.Address and $FFFFFC, Size);
        Cost := Int64(Size) * Unit_;
        var Blocks := Sub32(Ch.Block shr 16, 1) and $FFFF;
        Ch.Block := (Ch.Block and $FFFF) or (Blocks shl 16);
      end;
    2:
      begin
        var Node := Ch.Address and $1FFFFC;
        var Header := PCardinal(@FBus.RAM[Node])^;
        var Count := Integer(Header shr 24);
        if Count > 0 then
          TransferWords(Index, Node + 4, Count);
        Ch.Address := Header and $FFFFFF;
        Cost := Int64(Count + 1) * Unit_ + ListNodeOverhead * 16;
      end;
  else
    Cost := 16;
  end;
  Result := (Cost + 15) div 16;
end;

procedure TPS1DMA.UpdateMaster(Before: Boolean);
begin
  var Master := ((FInterrupt and $8000) <> 0) or
    (((FInterrupt and $800000) <> 0) and ((FInterrupt and $7F000000) <> 0));
  if Master then
    FInterrupt := FInterrupt or $80000000
  else
    FInterrupt := FInterrupt and not $80000000;
  if Master and not Before then
    FIRQ(TPS1IRQ.DMA);
end;

// CPU time between two steps. Chopped bursts use the CPU window, which
// cannot exceed 32 cycles per DMA word (ps1-tests dma/chopping).
function TPS1DMA.Gap(Index: Integer): Integer;
begin
  var C := FChannels[Index].Control;
  if (((C shr 9) and 3) <> 0) or ((C and ControlChop) = 0) then
    Exit(StepGap);

  var Window := 1 shl ((C shr 20) and 7);
  var Limit := 32 shl ((C shr 16) and 7);
  if Window > Limit then
    Window := Limit;
  Result := Window + ChopOverhead;
end;

function TPS1DMA.Finish(Index: Integer): Boolean;
begin
  var Ch: PChannel := @FChannels[Index];
  var Done := True;
  case (Ch.Control shr 9) and 3 of
    1:
      Done := (Ch.Block shr 16) = 0;
    2:
      Done := (Ch.Address and $800000) <> 0;
  end;
  if (((Ch.Control shr 9) and 3) = 0) and ((Ch.Control and ControlChop) <> 0) then
    Done := (Ch.Block and $FFFF) = 0;
  Result := Done;
  if Done then
  begin
    Ch.Control := Ch.Control and not ControlStart;
    Ch.Bursting := 0;
  end;
  // Completion flags need both the channel enable and the master enable;
  // bits 0..6 also flag every finished slice or list part.
  if (Done or (((FInterrupt shr Index) and 1) <> 0)) and
    (((FInterrupt shr (16 + Index)) and 1) <> 0) and ((FInterrupt and $800000) <> 0) then
  begin
    var Before := (FInterrupt and $80000000) <> 0;
    FInterrupt := FInterrupt or (Cardinal(1) shl (24 + Index));
    UpdateMaster(Before);
  end;
end;

procedure TPS1DMA.Kick;
begin
  if FPhase <> 0 then
    Exit;

  var Best := -1;
  var BestPriority := 8;
  for var I := 6 downto 0 do
  begin
    if not Runnable(I) then
      Continue;
    var Priority := Integer((FPriority shr (I * 4)) and 7);
    if Priority < BestPriority then
    begin
      Best := I;
      BestPriority := Priority;
    end;
  end;
  if Best < 0 then
    Exit;

  var Duration := Transfer(Best);
  FPhase := 1;
  FBusyChannel := Best;
  var Ready := FScheduler.Now + Duration;
  FScheduler.Schedule(TPS1Event.DMA, Ready);
  if Assigned(FStall) then
    FStall(Ready);
end;

procedure TPS1DMA.Event(Time: Int64);
begin
  case FPhase of
    1:
      if Finish(FBusyChannel) then
      begin
        FPhase := 0;
        Kick;
      end
      else
      begin
        FPhase := 2;
        FScheduler.Schedule(TPS1Event.DMA, Time + Gap(FBusyChannel));
      end;
    2:
      begin
        FPhase := 0;
        Kick;
      end;
  end;
end;

function TPS1DMA.Read(Address: Cardinal): Cardinal;
begin
  var Index := Integer((Address shr 4) and 7);
  if Index < 7 then
    case Address and $C of
      $0:
        Result := FChannels[Index].Address;
      $4:
        Result := FChannels[Index].Block;
    else
      Result := FChannels[Index].Control;
    end
  else
    case Address and $C of
      $0:
        Result := FPriority;
      $4:
        Result := FInterrupt;
      $8:
        Result := $7FFAC68B;
    else
      Result := $00FFFFF7;
    end;
end;

procedure TPS1DMA.Write(Address, Value: Cardinal);
begin
  var Index := Integer((Address shr 4) and 7);
  if Index < 7 then
  begin
    var Ch: PChannel := @FChannels[Index];
    case Address and $C of
      $0:
        Ch.Address := Value and $FFFFFF;
      $4:
        Ch.Block := Value;
    else
      Ch.Bursting := 0;
      if Index = 6 then
        Ch.Control := (Value and OTCWritable) or $00000002
      else
        Ch.Control := Value and ControlWritable;
    end;
  end
  else
    case Address and $C of
      $0:
        FPriority := Value;
      $4:
        begin
          var Before := (FInterrupt and $80000000) <> 0;
          FInterrupt := (FInterrupt and $7F000000 and not (Value and $7F000000)) or (Value and $00FF803F);
          UpdateMaster(Before);
        end;
    end;
  Kick;
end;

procedure TPS1DMA.SerializeState(State: TStateArchive);
begin
  State.Field(FChannels, SizeOf(FChannels));
  State.Field(FPriority, SizeOf(FPriority));
  State.Field(FInterrupt, SizeOf(FInterrupt));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FBusyChannel, SizeOf(FBusyChannel));
  if State.Loading and ((FBusyChannel < 0) or (FBusyChannel > 6) or (FPhase < 0) or (FPhase > 2)) then
    raise EReadError.Create('PS1 snapshot DMA channel');
end;

end.

