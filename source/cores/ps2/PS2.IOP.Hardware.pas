unit PS2.IOP.Hardware;

// IOP hardware registers as IOP modules see them while the kernel and the
// system modules are high level: a register file for the I/O area, running
// root counters, the SPU2 register file with its 2 MiB sound RAM (manual
// transfers and IOP DMA channels 4/7, with completion interrupts paced like
// the hardware: AutoDMA blocks at the 48 kHz output rate) and the status
// bits the sound libraries poll. Sound output itself is not generated yet.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler;

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
  PS2SPU2RAMSize = $200000;

type
  TPS2IOPInterrupt = procedure(Line: Integer) of object;

  TPS2IOPHardware = class
  private
    FScheduler: TPS2Scheduler;
    FIO: array[0..$3FFF] of Byte;
    FSPU2Regs: array[0..$7FF] of Word;
    FDue: array[0..1] of Int64;
    FPendingLine: array[0..1] of Integer;
    // STATX: bit 7 set once a DMA transfer finished.
    FStatX: array[0..1] of Word;
    function IO32(Offset: Cardinal): Cardinal; inline;
    procedure SetIO32(Offset, Value: Cardinal); inline;
    function CoreTSA(Core: Integer): Cardinal;
    procedure SetCoreTSA(Core: Integer; Value: Cardinal);
    procedure StartDMA(Channel: Integer);
    procedure ScheduleNext;
    function ReadSPU2(Offset: Cardinal): Cardinal;
    procedure WriteSPU2(Offset, Value: Cardinal);
  public
    SPU2RAM: array of Byte;
    RAM: PByte;
    // IOP cycles (for the root counters).
    IOPCycles: PInt64;
    OnInterrupt: TPS2IOPInterrupt;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; IOPRAM: PByte; Cycles: PInt64);
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
  SPUAttr = $19A;
  SPUTSAHi = $1A8;
  SPUTSALo = $1AA;
  SPUData = $1AC;
  SPUAdma = $1B0;
  SPUStatX = $344;

constructor TPS2IOPHardware.Create(Scheduler: TPS2Scheduler; IOPRAM: PByte; Cycles: PInt64);
begin
  inherited Create;
  FScheduler := Scheduler;
  RAM := IOPRAM;
  IOPCycles := Cycles;
  SetLength(SPU2RAM, PS2SPU2RAMSize);
  Reset;
end;

procedure TPS2IOPHardware.Reset;
begin
  FillChar(FIO, SizeOf(FIO), 0);
  FillChar(FSPU2Regs, SizeOf(FSPU2Regs), 0);
  FillChar(SPU2RAM[0], Length(SPU2RAM), 0);
  FDue[0] := PS2Never;
  FDue[1] := PS2Never;
  FPendingLine[0] := 0;
  FPendingLine[1] := 0;
  FStatX[0] := 0;
  FStatX[1] := 0;
  FScheduler.Cancel(TPS2Event.IOPDMA);
end;

function TPS2IOPHardware.IO32(Offset: Cardinal): Cardinal;
begin
  Result := PCardinal(@FIO[Offset and $3FFC])^;
end;

procedure TPS2IOPHardware.SetIO32(Offset, Value: Cardinal);
begin
  PCardinal(@FIO[Offset and $3FFC])^ := Value;
end;

function TPS2IOPHardware.CoreTSA(Core: Integer): Cardinal;
begin
  var B := Cardinal(Core) * $200;
  Result := ((Cardinal(FSPU2Regs[(SPUTSAHi shr 1) + B]) shl 16) or FSPU2Regs[(SPUTSALo shr 1) + B]) and $FFFFF;
end;

procedure TPS2IOPHardware.SetCoreTSA(Core: Integer; Value: Cardinal);
begin
  var B := Cardinal(Core) * $200;
  Value := Value and $FFFFF;
  FSPU2Regs[(SPUTSAHi shr 1) + B] := Word(Value shr 16);
  FSPU2Regs[(SPUTSALo shr 1) + B] := Word(Value);
end;

function TPS2IOPHardware.ReadSPU2(Offset: Cardinal): Cardinal;
begin
  var Index := (Offset shr 1) and $7FF;
  var Local := Offset and $3FF;
  if (Offset < $800) and (Local = SPUStatX) then
    // No manual transfer in progress, FIFO empty; bit 7 after a DMA.
    Exit(FStatX[(Offset shr 10) and 1]);
  if Offset = $7C2 then
    Exit(0);
  Result := FSPU2Regs[Index];
end;

procedure TPS2IOPHardware.WriteSPU2(Offset, Value: Cardinal);
begin
  var Index := (Offset shr 1) and $7FF;
  FSPU2Regs[Index] := Word(Value);
  if Offset >= $800 then
    Exit;
  var Core := Integer(Offset shr 10) and 1;
  case Offset and $3FF of
    SPUAttr:
      FStatX[Core] := 0;
    SPUData:
      begin
        // Manual transfer: one halfword at the transfer address.
        var A := CoreTSA(Core);
        PWord(@SPU2RAM[(A * 2) and (PS2SPU2RAMSize - 2)])^ := Word(Value);
        SetCoreTSA(Core, A + 1);
      end;
  end;
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
    Log.Add(Format('iop dma%d madr %.6x bcr %.8x chcr %.8x tsa %x', [Channel, MADR, BCR, CHCR, CoreTSA(Core)]));
  var A := CoreTSA(Core) * 2;
  FStatX[Core] := FStatX[Core] and not $80;
  if Bytes > 0 then
  begin
    for var K := 0 to Bytes div 2 - 1 do
    begin
      var S := (A + Cardinal(K) * 2) and (PS2SPU2RAMSize - 2);
      var M := (MADR + Cardinal(K) * 2) and (PS2IOPRAMMask and not 1);
      if (CHCR and 1) <> 0 then
        PWord(@SPU2RAM[S])^ := PWord(RAM + M)^
      else
        PWord(RAM + M)^ := PWord(@SPU2RAM[S])^;
    end;
  end;
  // AutoDMA blocks play out at 48 kHz (4 bytes per stereo sample); other
  // transfers take about a cycle per halfword.
  var Delay: Int64;
  if (FSPU2Regs[((SPUAdma shr 1) + Cardinal(Core) * $200)] and (1 shl Core)) <> 0 then
    Delay := Int64(Max(Bytes, 512)) div 4 * PS2EEClock div PS2SPU2Rate
  else
    Delay := Int64(Max(Bytes, 64)) * 4;
  FDue[Core] := FScheduler.Now + Delay;
  if Channel = 7 then
    FPendingLine[Core] := IOPIntDMASPU1
  else
    FPendingLine[Core] := IOPIntDMASPU0;
  ScheduleNext;
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
      FStatX[Core] := FStatX[Core] or $80;
      if Assigned(OnInterrupt) then
        OnInterrupt(FPendingLine[Core]);
    end;
  ScheduleNext;
end;

function TPS2IOPHardware.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  if (Address >= $1F900000) and (Address < $1F910000) then
  begin
    Result := ReadSPU2(Address and $FFFF);
    if Size = 4 then
      Result := Result or (ReadSPU2((Address and $FFFF) + 2) shl 16);
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
  if (Log <> nil) and (Log.Count < 4000) and ((Address and $FFFFF000) <> $1F900000) then
    Log.Add(Format('iop w %.8x %.8x/%d', [Address, Value, Size]));
  if (Address >= $1F900000) and (Address < $1F910000) then
  begin
    WriteSPU2(Address and $FFFF, Value and $FFFF);
    if Size = 4 then
      WriteSPU2((Address and $FFFF) + 2, Value shr 16);
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
      StartDMA(7);
  end;
end;

procedure TPS2IOPHardware.SerializeState(State: TStateArchive);
begin
  State.Field(FIO, SizeOf(FIO));
  State.Field(FSPU2Regs, SizeOf(FSPU2Regs));
  State.Field(FDue, SizeOf(FDue));
  State.Field(FPendingLine, SizeOf(FPendingLine));
  State.Field(FStatX, SizeOf(FStatX));
  State.Field(SPU2RAM[0], Length(SPU2RAM));
end;

end.
