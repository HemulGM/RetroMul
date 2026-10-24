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
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, PS2.Types, PS2.Scheduler, PS2.IOP.SIO2;

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
  PS2SPU2RAMSize = $200000;

type
  TPS2IOPInterrupt = procedure(Line: Integer) of object;

  // A voice's playback position (no sound is generated): the ADPCM block
  // being read (halfword address), samples into it in 1/4096 units, and the
  // loop address.
  TPS2SPU2Voice = record
    Active: Boolean;
    Addr, Frac, Loop: Cardinal;
  end;

  TPS2IOPHardware = class
  private
    FScheduler: TPS2Scheduler;
    FIO: array[0..$3FFF] of Byte;
    FSPU2Regs: array[0..$7FF] of Word;
    FDue: array[0..1] of Int64;
    FPendingLine: array[0..1] of Integer;
    // STATX: bit 7 set once a DMA transfer finished.
    FStatX: array[0..1] of Word;
    FVoices: array[0..1, 0..23] of TPS2SPU2Voice;
    FEndX: array[0..1] of Cardinal;
    FIRQInfo: Word;
    // IRQ raised since the core's enable bit was last set.
    FIRQFired: array[0..1] of Boolean;
    function Reg(Core: Integer; Offset: Cardinal): Word; inline;
    function IRQAddress(Core: Integer): Cardinal;
    procedure CheckIRQ(Core: Integer; First, Count: Cardinal);
    procedure KeyOn(Core: Integer; Mask: Cardinal);
    procedure KeyOff(Core: Integer; Mask: Cardinal);
    function IO32(Offset: Cardinal): Cardinal; inline;
    procedure SetIO32(Offset, Value: Cardinal); inline;
    function CoreTSA(Core: Integer): Cardinal;
    procedure SetCoreTSA(Core: Integer; Value: Cardinal);
    procedure StartDMA(Channel: Integer);
    procedure StartSIO2DMA(Base: Cardinal; ToDevice: Boolean);
    procedure FinishSIO2DMA(Base: Cardinal; ToDevice: Boolean);
    procedure SIO2Interrupt;
    procedure ScheduleNext;
    function ReadSPU2(Offset: Cardinal): Cardinal;
    procedure WriteSPU2(Offset, Value: Cardinal);
  public
    SPU2RAM: array of Byte;
    RAM: PByte;
    // IOP cycles (for the root counters).
    IOPCycles: PInt64;
    OnInterrupt: TPS2IOPInterrupt;
    SIO2: TPS2SIO2;
    Log: TStrings;
    constructor Create(Scheduler: TPS2Scheduler; IOPRAM: PByte; Cycles: PInt64);
    destructor Destroy; override;
    procedure Reset;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    // Scheduler event IOPDMA.
    procedure Event;
    // Advances the voices by Samples output samples (48 kHz): end and loop
    // flags, ENDX, IRQ address hits.
    procedure TickSPU2(Samples: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // Offsets from 1F801000h.
  DMACh4 = $0C0;
  DMACh7 = $500;
  DMACh11 = $540;
  DMACh12 = $550;
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
  inherited;
end;

procedure TPS2IOPHardware.SIO2Interrupt;
begin
  if Assigned(OnInterrupt) then
    OnInterrupt(IOPIntSIO2);
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
      OnInterrupt(IOPIntDMASIO2In)
    else
      OnInterrupt(IOPIntDMASIO2Out);
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
  FillChar(FVoices, SizeOf(FVoices), 0);
  FillChar(FEndX, SizeOf(FEndX), 0);
  FIRQInfo := 0;
  FIRQFired[0] := False;
  FIRQFired[1] := False;
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
  begin
    Result := FIRQInfo;
    FIRQInfo := 0;
    Exit;
  end;
  if Offset < $800 then
  begin
    var Core := Integer(Offset shr 10) and 1;
    case Local of
      $340: Exit(FEndX[Core] and $FFFF);
      $342: Exit(FEndX[Core] shr 16);
      $1C0..$2DF:
        begin
          // Voice addresses: SSA, LSAX, NAX (hi/lo) per 12 bytes.
          var V := Integer((Local - $1C0) div 12);
          var Field := (Local - $1C0) mod 12;
          if FVoices[Core, V].Active and (Field >= 8) then
            if Field = 8 then
              Exit((FVoices[Core, V].Addr shr 16) and $F)
            else
              Exit(FVoices[Core, V].Addr and $FFFF);
        end;
    end;
    if (Local < $180) and ((Local and $F) = $A) then
    begin
      // ENVX: full while the voice plays.
      var V := Integer(Local shr 4);
      if (V < 24) and FVoices[Core, V].Active then
        Exit($7FFF)
      else
        Exit(0);
    end;
  end;
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
      begin
        FStatX[Core] := 0;
        if (Value and $40) = 0 then
          FIRQFired[Core] := False;
      end;
    $1A0: KeyOn(Core, Value and $FFFF);
    $1A2: KeyOn(Core, (Value and $FF) shl 16);
    $1A4: KeyOff(Core, Value and $FFFF);
    $1A6: KeyOff(Core, (Value and $FF) shl 16);
    $340, $342: FEndX[Core] := 0;
    SPUData:
      begin
        // Manual transfer: one halfword at the transfer address.
        var A := CoreTSA(Core);
        PWord(@SPU2RAM[(A * 2) and (PS2SPU2RAMSize - 2)])^ := Word(Value);
        SetCoreTSA(Core, A + 1);
      end;
  end;
end;

function TPS2IOPHardware.Reg(Core: Integer; Offset: Cardinal): Word;
begin
  Result := FSPU2Regs[((Offset + Cardinal(Core) * $400) shr 1) and $7FF];
end;

function TPS2IOPHardware.IRQAddress(Core: Integer): Cardinal;
begin
  Result := ((Cardinal(Reg(Core, $19C)) shl 16) or Reg(Core, $19E)) and $FFFFF;
end;

// An access to Count halfwords at First: the IRQ fires when it covers the
// core's IRQ address (ATTR bit 6 enables it).
procedure TPS2IOPHardware.CheckIRQ(Core: Integer; First, Count: Cardinal);
begin
  for var C := 0 to 1 do
  begin
    if FIRQFired[C] or ((Reg(C, SPUAttr) and $40) = 0) then
      Continue;
    var A := IRQAddress(C);
    if (A >= First) and (A < First + Count) then
    begin
      FIRQFired[C] := True;
      FIRQInfo := FIRQInfo or Word(4 shl C);
      if Assigned(OnInterrupt) then
        OnInterrupt(IOPIntSPU2);
    end;
  end;
end;

procedure TPS2IOPHardware.KeyOn(Core: Integer; Mask: Cardinal);
begin
  for var V := 0 to 23 do
    if (Mask and (Cardinal(1) shl V)) <> 0 then
    begin
      var R := $1C0 + Cardinal(V) * 12;
      FVoices[Core, V].Active := True;
      FVoices[Core, V].Addr := ((Cardinal(Reg(Core, R)) shl 16) or Reg(Core, R + 2)) and $FFFF8;
      FVoices[Core, V].Loop := ((Cardinal(Reg(Core, R + 4)) shl 16) or Reg(Core, R + 6)) and $FFFF8;
      FVoices[Core, V].Frac := 0;
      FEndX[Core] := FEndX[Core] and not (Cardinal(1) shl V);
    end;
end;

procedure TPS2IOPHardware.KeyOff(Core: Integer; Mask: Cardinal);
begin
  for var V := 0 to 23 do
    if (Mask and (Cardinal(1) shl V)) <> 0 then
      FVoices[Core, V].Active := False;
end;

procedure TPS2IOPHardware.TickSPU2(Samples: Integer);
begin
  for var Core := 0 to 1 do
    for var V := 0 to 23 do
    begin
      var P: ^TPS2SPU2Voice := @FVoices[Core, V];
      if not P.Active then
        Continue;
      var Pitch := Cardinal(Reg(Core, Cardinal(V) * $10 + 4)) and $3FFF;
      Inc(P.Frac, Pitch * Cardinal(Samples));
      // 28 samples per 16-byte block (8 halfwords).
      var Guard := 0;
      while (P.Frac >= 28 * 4096) and P.Active and (Guard < 4096) do
      begin
        Dec(P.Frac, 28 * 4096);
        Inc(Guard);
        var Flags := SPU2RAM[((P.Addr * 2) + 1) and (PS2SPU2RAMSize - 1)];
        if (Flags and 4) <> 0 then
          P.Loop := P.Addr;
        CheckIRQ(Core, P.Addr, 8);
        if (Flags and 1) <> 0 then
        begin
          FEndX[Core] := FEndX[Core] or (Cardinal(1) shl V);
          if (Flags and 2) <> 0 then
            P.Addr := P.Loop
          else
            P.Active := False;
        end
        else
          P.Addr := (P.Addr + 8) and $FFFFF;
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
  CheckIRQ(Core, CoreTSA(Core), Cardinal(Max(Bytes, 2) div 2));
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
  if (Address >= $1F808200) and (Address < $1F808280) then
    Exit(SIO2.Read(Address));
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
  if (Address >= $1F808200) and (Address < $1F808280) then
  begin
    SIO2.Write(Address, Value);
    Exit;
  end;
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
  State.Field(FSPU2Regs, SizeOf(FSPU2Regs));
  State.Field(FDue, SizeOf(FDue));
  State.Field(FPendingLine, SizeOf(FPendingLine));
  State.Field(FStatX, SizeOf(FStatX));
  State.Field(FVoices, SizeOf(FVoices));
  State.Field(FEndX, SizeOf(FEndX));
  State.Field(FIRQInfo, SizeOf(FIRQInfo));
  State.Field(FIRQFired, SizeOf(FIRQFired));
  State.Field(SPU2RAM[0], Length(SPU2RAM));
  SIO2.SerializeState(State);
end;

end.
