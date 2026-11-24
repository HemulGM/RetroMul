unit PS2.IOP.Hardware;

// IOP hardware registers as IOP modules see them while the kernel and the
// system modules are high level: a register file for the I/O area, running
// root counters, the SPU2 (PS2.SPU2) behind its register window and IOP DMA
// channels 4/7 (completion interrupts paced like the hardware: an AutoDMA
// transfer ends when the core has taken its last block) and SIO2.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.IOP.SIO2, PS2.SPU2;

const
  // IOP interrupt lines (intrman numbering): INTC bits, then 32 + DMA
  // channel for channels 0..6 and 33 + channel for 7..13.
  IOPIntVBlank = 0;
  IOPIntCDVD = 2;
  IOPIntDMA = 3;
  IOPIntSPU2 = 9;
  IOPIntEVBlank = 11;
  IOPIntDMASPU0 = 36;
  IOPIntDMASPU1 = 40;
  IOPIntSIO2 = 17;
  IOPIntDMASIO2In = 44;
  IOPIntDMASIO2Out = 45;

type
  TPS2IOPInterrupt = procedure(Line: Integer) of object;

  TPS2IOPHardware = class
  private
    FScheduler: TPS2Scheduler;
    FIO: array[0..$3FFF] of Byte;
    FDue: array[0..1] of Int64;
    FPendingLine: array[0..1] of Integer;
    function IO32(Offset: Cardinal): Cardinal; inline;
    procedure SetIO32(Offset, Value: Cardinal); inline;
    procedure StartDMA(Channel: Integer);
    procedure StartSIO2DMA(Base: Cardinal; ToDevice: Boolean);
    procedure FinishSIO2DMA(Base: Cardinal; ToDevice: Boolean);
    procedure SIO2Interrupt;
    procedure ScheduleNext;
    procedure Fire(Line: Integer);
  public
    SPU2: TPS2SPU2;
    RAM: PByte;
    // IOP cycles (for the root counters).
    IOPCycles: PInt64;
    OnInterrupt: TPS2IOPInterrupt;
    // Diagnostics: interrupts raised per line.
    LineCounts: array[0..63] of Int64;
    SIO2: TPS2SIO2;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; IOPRAM: PByte; Cycles: PInt64);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    // Scheduler event IOPDMA.
    procedure Event;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // Offsets from 1F801000h.
  DMACh4 = $0C0;
  DMACh7 = $500;
  DMACh11 = $540;
  DMACh12 = $550;

constructor TPS2IOPHardware.Create(Scheduler: TPS2Scheduler; IOPRAM: PByte; Cycles: PInt64);
begin
  inherited Create;
  FScheduler := Scheduler;
  RAM := IOPRAM;
  IOPCycles := Cycles;
  SPU2 := TPS2SPU2.Create(Scheduler);
  SPU2.OnInterrupt := procedure
    begin
      if Assigned(OnInterrupt) then
        Fire(IOPIntSPU2);
    end;
  SPU2.IOPRAM := IOPRAM;
  // AutoDMA: the channel's address follows the blocks the core takes; the
  // transfer ends (soon after) once it has taken the last one.
  SPU2.OnAutoDMA := procedure(Core: Integer; Address: Cardinal; Finished: Boolean)
    begin
      var Base: Cardinal := DMACh4;
      if Core = 1 then
        Base := DMACh7;
      SetIO32(Base, Address);
      if Finished then
      begin
        FDue[Core] := FScheduler.Now + 64;
        ScheduleNext;
      end;
    end;
  SIO2 := TPS2SIO2.Create(IOPRAM);
  SIO2.OnInterrupt := SIO2Interrupt;
  SIO2.OnOutDMADone := procedure
    begin
      FinishSIO2DMA(DMACh12, False);
    end;
  Reset;
end;

destructor TPS2IOPHardware.Destroy;
begin
  SIO2.Free;
  SPU2.Free;
  inherited;
end;

procedure TPS2IOPHardware.SIO2Interrupt;
begin
  if Assigned(OnInterrupt) then
    Fire(IOPIntSIO2);
end;

// SIO2 DMA: blocks of BCR.size words, BCR.count blocks. Channel 11 hands
// them over at once; channel 12 ends when the SIO2 has delivered them.
procedure TPS2IOPHardware.StartSIO2DMA(Base: Cardinal; ToDevice: Boolean);
begin
  var MADR := IO32(Base) and PS2IOPRAMMask;
  var BCR := IO32(Base + 4);
  var BlockSize := Integer(BCR and $FFFF) * 4;
  var Blocks := Integer(BCR shr 16);
  if ToDevice then
  begin
    if MADR + Cardinal(BlockSize * Blocks) <= PS2IOPRAMSize then
      SIO2.DMAIn(RAM + MADR, BlockSize, Blocks);
    FinishSIO2DMA(Base, True);
  end
  else
    SIO2.StartOutDMA(MADR, BlockSize, Blocks);
end;

procedure TPS2IOPHardware.FinishSIO2DMA(Base: Cardinal; ToDevice: Boolean);
begin
  var MADR := IO32(Base) and PS2IOPRAMMask;
  var BCR := IO32(Base + 4);
  var BlockSize := Integer(BCR and $FFFF) * 4;
  var Blocks := Integer(BCR shr 16);
  SetIO32(Base, MADR + Cardinal(BlockSize * Blocks));
  SetIO32(Base + 4, BCR and $FFFF);
  SetIO32(Base + 8, IO32(Base + 8) and not $01000000);
  if Assigned(OnInterrupt) then
    if ToDevice then
      Fire(IOPIntDMASIO2In)
    else
      Fire(IOPIntDMASIO2Out);
end;

procedure TPS2IOPHardware.Reset;
begin
  FillChar(FIO, SizeOf(FIO), 0);
  SPU2.Reset;
  FDue[0] := PS2Never;
  FDue[1] := PS2Never;
  FPendingLine[0] := 0;
  FPendingLine[1] := 0;
  FScheduler.Cancel(TPS2Event.IOPDMA);
  SIO2.Reset;
end;

function TPS2IOPHardware.IO32(Offset: Cardinal): Cardinal;
begin
  Result := PCardinal(@FIO[Offset and $3FFC])^;
end;

procedure TPS2IOPHardware.SetIO32(Offset, Value: Cardinal);
begin
  PCardinal(@FIO[Offset and $3FFC])^ := Value;
end;

procedure TPS2IOPHardware.StartDMA(Channel: Integer);
begin
  var Base: Cardinal := DMACh4;
  var Core := 0;
  if Channel = 7 then
  begin
    Base := DMACh7;
    Core := 1;
  end;
  var MADR := IO32(Base) and PS2IOPRAMMask;
  var BCR := IO32(Base + 4);
  var CHCR := IO32(Base + 8);
  var Words := Integer(BCR and $FFFF) * Integer(Max(BCR shr 16, 1));
  if (BCR and $FFFF) = 0 then
    Words := Integer(BCR shr 16) * 16;
  var Bytes := Words * 4;
  if Log <> nil then
    Log.Add(Format('iop dma%d madr %.6x bcr %.8x chcr %.8x tsa %x adma %d', [Channel, MADR, BCR, CHCR,
      (Cardinal(SPU2.Read(Cardinal(Core) * $400 + $1A8)) shl 16) or SPU2.Read(Cardinal(Core) * $400 + $1AA), Ord(SPU2.AutoDMA(Core))]));
  if MADR + Cardinal(Bytes) > PS2IOPRAMSize then
    Bytes := Integer(PS2IOPRAMSize - MADR);
  if Channel = 7 then
    FPendingLine[Core] := IOPIntDMASPU1
  else
    FPendingLine[Core] := IOPIntDMASPU0;
  if SPU2.AutoDMA(Core) and ((CHCR and 1) <> 0) then
  begin
    // AutoDMA blocks go out as the core plays them (OnAutoDMA ends it).
    FDue[Core] := PS2Never;
    ScheduleNext;
    SPU2.StartAutoDMA(Core, MADR, Bytes);
    Exit;
  end;
  SPU2.DMA(Core, RAM + MADR, Bytes, (CHCR and 1) <> 0);
  // Other transfers take about a cycle per halfword.
  FDue[Core] := FScheduler.Now + Int64(Max(Bytes, 64)) * 4;
  ScheduleNext;
end;

procedure TPS2IOPHardware.Fire(Line: Integer);
begin
  Inc(LineCounts[Line and 63]);
  if Assigned(OnInterrupt) then
    OnInterrupt(Line);
end;

procedure TPS2IOPHardware.ScheduleNext;
begin
  var Next := Min(FDue[0], FDue[1]);
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.IOPDMA)
  else
    FScheduler.Schedule(TPS2Event.IOPDMA, Next);
end;

procedure TPS2IOPHardware.Event;
begin
  for var Core := 0 to 1 do
    if FDue[Core] <= FScheduler.Now then
    begin
      FDue[Core] := PS2Never;
      var Base: Cardinal := DMACh4;
      if Core = 1 then
        Base := DMACh7;
      SetIO32(Base + 8, IO32(Base + 8) and not $01000000);
      SPU2.DMADone(Core);
      if Assigned(OnInterrupt) then
        Fire(FPendingLine[Core]);
    end;
  ScheduleNext;
end;

function TPS2IOPHardware.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  if (Address >= $1F808200) and (Address < $1F808280) then
    Exit(SIO2.Read(Address));
  if (Address >= $1F900000) and (Address < $1F910000) then
  begin
    Result := SPU2.Read(Address and $7FF);
    if Size = 4 then
      Result := Result or (Cardinal(SPU2.Read((Address + 2) and $7FF)) shl 16);
    Exit;
  end;
  if (Address >= $1F801000) and (Address < $1F805000) then
  begin
    var O := Address - $1F801000;
    // Root counters: counts derived from the IOP clock.
    if ((O >= $100) and (O < $130) or (O >= $480) and (O < $4B0)) and ((O and $F) = 0) then
    begin
      var C := IOPCycles^;
      if O < $130 then
        Exit(Cardinal(C and $FFFF))
      else
        Exit(Cardinal(C and $FFFFFFFF));
    end;
    case Size of
      1: Result := FIO[O and $3FFF];
      2: Result := PWord(@FIO[O and $3FFE])^;
    else
      Result := IO32(O);
    end;
    Exit;
  end;
  Result := 0;
end;

procedure TPS2IOPHardware.Write(Address, Value: Cardinal; Size: Integer);
begin
  if (Address >= $1F808200) and (Address < $1F808280) then
  begin
    SIO2.Write(Address, Value);
    Exit;
  end;
  if (Log <> nil) and (Log.Count < 4000) and ((Address and $FFFFF000) <> $1F900000) then
    Log.Add(Format('iop w %.8x %.8x/%d', [Address, Value, Size]));
  if (Address >= $1F900000) and (Address < $1F910000) then
  begin
    SPU2.Write(Address and $7FF, Word(Value));
    if Size = 4 then
      SPU2.Write((Address + 2) and $7FF, Word(Value shr 16));
    Exit;
  end;
  if (Address >= $1F801000) and (Address < $1F805000) then
  begin
    var O := Address - $1F801000;
    case Size of
      1: FIO[O and $3FFF] := Byte(Value);
      2: PWord(@FIO[O and $3FFE])^ := Word(Value);
    else
      SetIO32(O, Value);
    end;
    if ((O and $3FFC) = DMACh4 + 8) and ((IO32(DMACh4 + 8) and $01000000) <> 0) then
      StartDMA(4)
    else if ((O and $3FFC) = DMACh7 + 8) and ((IO32(DMACh7 + 8) and $01000000) <> 0) then
      StartDMA(7)
    else if ((O and $3FFC) = DMACh11 + 8) and ((IO32(DMACh11 + 8) and $01000000) <> 0) then
      StartSIO2DMA(DMACh11, True)
    else if ((O and $3FFC) = DMACh12 + 8) and ((IO32(DMACh12 + 8) and $01000000) <> 0) then
      StartSIO2DMA(DMACh12, False);
  end;
end;

procedure TPS2IOPHardware.SerializeState(State: TStateArchive);
begin
  State.Field(FIO, SizeOf(FIO));
  State.Field(FDue, SizeOf(FDue));
  State.Field(FPendingLine, SizeOf(FPendingLine));
  SPU2.SerializeState(State);
  SIO2.SerializeState(State);
end;

end.
