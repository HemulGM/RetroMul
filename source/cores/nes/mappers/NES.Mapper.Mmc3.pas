unit NES.Mapper.Mmc3;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  TMmc3T9552 = (NoT9552, LegacyT9552, CanonicalT9552);

  // MMC3, MMC6 and Acclaim MC-ACC.
  TMapperMmc3 = class(TMapper)
  private
    FIsMcAcc, FIsNec, FHardwiredMirroring: Boolean;
    FMcAccPulsePhase: Byte;
    FIrqRevision: TMmc3IrqRevision;
    FIrqReloadSetMask: Byte;
    FIrqReloadBlocked: Boolean;
    FFceuxCompatibility, FFceuxReloadLatched: Boolean;
    FT9552: TMmc3T9552;
    FPrgRamMask: Integer;
    procedure ClockIrqCounter;
  protected
    FPrgRom, FChrMemory: TByteArray;
    FLegacySave: TByteArray;
    FExtraPrgRam: TByteArray;
    FPrgRam: array[0..$1FFF] of UInt8;
    FHasChrRam, FFourScreenMirroring: Boolean;
    FInitialMirrorMode, FMirrorMode: TMirrorMode;
    FBankRegisters: array[0..7] of UInt8;
    FBankSelect, FPrgRamControl, FIrqLatch, FIrqCounter: UInt8;
    FIrqReloadPending, FIrqEnabled, FIrqPending, FA12High: Boolean;
    FIrqRequiresCounterTransition: Boolean;
    FA12LowSince: UInt64;
    FUseBankCache, FIsMmc6: Boolean;
    FT9552Pattern: Byte;
    FPrgOffsets: array[0..3] of Integer;
    FChrOffsets: array[0..7] of Integer;
    procedure UpdateBankOffsets;
    function GetChrOffset(Address: UInt16): Integer;
    function PrgRegisterBank(Slot: Integer): Integer;
    function ChrRegisterBank(Slot: Integer): Integer; inline;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ConfigurePrgRam(Size: Integer);
    procedure ConfigureIrqRevision(Revision: TMmc3IrqRevision);
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; AMmc6: Boolean = False; AMcAcc: Boolean = False; AHardwiredMirroring: Boolean = False; ANec: Boolean = False; AT9552: TMmc3T9552 = NoT9552; AUseReloadInterlock: Boolean = False; AFceuxCompatibility: Boolean = False);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function AllowsPpuReadCaching: Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockFceuxIrq(Dot: Integer; Rendering: Boolean);
    property FceuxCompatibility: Boolean read FFceuxCompatibility;
    function IrqPending: Boolean; override;
    procedure PowerOn; override;
    procedure Reset; override;
  end;

function Mmc3A12RisingEdge(High: Boolean; PpuCycle: UInt64; var WasHigh: Boolean; var LowSince: UInt64): Boolean;

implementation

const
  // Each pattern lists the bank bits connected to the same physical output pins.
  // Mapper 249 dumps use column $00; NES 2.0 mapper 4.5 dumps use $02.
  T9552PrgPins: array[0..3, 0..3] of Byte = (
    (3, 4, 2, 1), (4, 3, 1, 2), (1, 2, 3, 4), (2, 1, 4, 3)
  );
  T9552ChrPins: array[0..7, 0..5] of Byte = (
    (5, 2, 6, 7, 4, 3), (4, 5, 3, 2, 7, 6), (2, 3, 4, 5, 6, 7), (6, 4, 2, 3, 7, 5),
    (5, 3, 7, 6, 2, 4), (4, 2, 5, 6, 7, 3), (3, 6, 4, 5, 2, 7), (2, 5, 6, 7, 3, 4)
  );

function T9552Bank(Bank, ScrambledBits: Integer; const PatternPins, DumpPins: array of Byte): Integer;
begin
  Result := Bank and not ScrambledBits;
  for var Pin := Low(PatternPins) to High(PatternPins) do
    Result := Result or (((Bank shr PatternPins[Pin]) and 1) shl DumpPins[Pin]);
end;

function Mmc3A12RisingEdge(High: Boolean; PpuCycle: UInt64; var WasHigh: Boolean; var LowSince: UInt64): Boolean;
begin
  if High = WasHigh then
    Exit(False);
  WasHigh := High;
  // Approximate the M2-qualified filter in PPU dots. Ten dots also reject
  // the short dummy-fetch gap across scanlines with background at $1000.
  if High then
    Exit((PpuCycle >= LowSince) and (PpuCycle - LowSince >= 10));
  LowSince := PpuCycle;
  Result := False;
end;

function TMapperMmc3.PrgRegisterBank(Slot: Integer): Integer;
begin
  if (FBankSelect and $40) <> 0 then
    if (Slot = 0) or (Slot = 2) then
      Slot := Slot xor 2;
  case Slot of
    0:
      Result := FBankRegisters[6];
    1:
      Result := FBankRegisters[7];
    2:
      Result := $FFFE;
  else
    Result := $FFFF;
  end;
end;

function TMapperMmc3.ChrRegisterBank(Slot: Integer): Integer;
begin
  if Slot < 4 then
    Result := (FBankRegisters[Slot shr 1] and $FE) or (Slot and 1)
  else
    Result := FBankRegisters[Slot - 2];
end;

procedure TMapperMmc3.UpdateBankOffsets;
begin
  if not FUseBankCache then
    Exit;

  var Bank6 := FBankRegisters[6] and $3F;
  var Bank7 := FBankRegisters[7] and $3F;
  var DumpOrder := 0;
  if FT9552 = CanonicalT9552 then
    DumpOrder := 2;
  if FT9552 <> NoT9552 then
  begin
    Bank6 := T9552Bank(Bank6, $1E, T9552PrgPins[FT9552Pattern and 3], T9552PrgPins[DumpOrder]);
    Bank7 := T9552Bank(Bank7, $1E, T9552PrgPins[FT9552Pattern and 3], T9552PrgPins[DumpOrder]);
  end;
  var Count := Length(FPrgRom) div $2000;
  FPrgOffsets[0] := (Bank6 mod Count) * $2000;
  FPrgOffsets[1] := (Bank7 mod Count) * $2000;
  FPrgOffsets[2] := (Count - 2) * $2000;
  FPrgOffsets[3] := (Count - 1) * $2000;
  if (FBankSelect and $40) <> 0 then
  begin
    var Offset := FPrgOffsets[0];
    FPrgOffsets[0] := FPrgOffsets[2];
    FPrgOffsets[2] := Offset;
  end;
  Count := Length(FChrMemory) div $400;
  for var Slot := 0 to 7 do
  begin
    var MappedSlot := Slot;
    if (FBankSelect and $80) <> 0 then
      MappedSlot := Slot xor 4;
    var Bank := ChrRegisterBank(MappedSlot);
    if FT9552 <> NoT9552 then
      Bank := T9552Bank(Bank, $FC, T9552ChrPins[FT9552Pattern], T9552ChrPins[DumpOrder]);
    FChrOffsets[Slot] := (Bank mod Count) * $400;
  end;
end;

procedure TMapperMmc3.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  State.Field(FPrgRam, SizeOf(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FFourScreenMirroring, SizeOf(FFourScreenMirroring));
  State.Field(FInitialMirrorMode, SizeOf(FInitialMirrorMode));
  State.Field(FMirrorMode, SizeOf(FMirrorMode));
  State.Field(FBankRegisters, SizeOf(FBankRegisters));
  State.Field(FBankSelect, SizeOf(FBankSelect));
  State.Field(FPrgRamControl, SizeOf(FPrgRamControl));
  State.Field(FIrqLatch, SizeOf(FIrqLatch));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqReloadPending, SizeOf(FIrqReloadPending));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  State.Field(FA12High, SizeOf(FA12High));
  State.Field(FA12LowSince, SizeOf(FA12LowSince));
  if FIsMcAcc then
    if State.Version >= 26 then
      State.Field(FMcAccPulsePhase, SizeOf(FMcAccPulsePhase))
    else if State.Loading then
      FMcAccPulsePhase := 0;
  if Length(FExtraPrgRam) > 0 then
    if State.Version >= 21 then
      State.Field(FExtraPrgRam[0], Length(FExtraPrgRam))
    else if State.Loading then
      FillChar(FExtraPrgRam[0], Length(FExtraPrgRam), 0);
  if FT9552 = CanonicalT9552 then
  begin
    if State.Version >= T9552_STATE_VERSION then
      State.Field(FT9552Pattern, SizeOf(FT9552Pattern))
    else if State.Loading then
      FT9552Pattern := 2; // Pre-v48 snapshots always used the dump's unswizzled bank order.
    if State.Loading then
      FT9552Pattern := FT9552Pattern and 7;
  end;
  if FIrqRevision <> TMmc3IrqRevision.Auto then
  begin
    if State.Version >= MMC3_IRQ_REVISION_STATE_VERSION then
    begin
      var Revision := Byte(Ord(FIrqRevision));
      State.Field(Revision, SizeOf(Revision));
      if State.Loading and (Revision <> Byte(Ord(FIrqRevision))) then
        raise ENesException.Create('Snapshot belongs to a different MMC3 IRQ revision');
    end;
    if State.Version >= MMC3_RELOAD_STATE_VERSION then
      State.Field(FIrqReloadBlocked, SizeOf(FIrqReloadBlocked))
    else if State.Loading then
      FIrqReloadBlocked := False;
  end;
  if FFceuxCompatibility then
    if State.Version >= MMC3_FCEUX_STATE_VERSION then
    begin
      State.Field(FIrqReloadBlocked, SizeOf(FIrqReloadBlocked));
      State.Field(FFceuxReloadLatched, SizeOf(FFceuxReloadLatched));
    end
    else if State.Loading then
    begin
      FIrqReloadBlocked := False;
      FFceuxReloadLatched := FIrqReloadPending;
      if FIrqReloadPending then
        FIrqCounter := FIrqCounter or FIrqReloadSetMask;
    end;
  if State.Loading then
  begin
    if FHardwiredMirroring then
      FMirrorMode := FInitialMirrorMode;
    UpdateBankOffsets;
  end;
end;

function TMapperMmc3.GetSaveMemory: TByteArray;
begin
  if FIsMmc6 and (Length(FLegacySave) = $2000) then
  begin
    Result := Copy(FLegacySave);
    for var Offset := 0 to 3 do
      Move(FPrgRam[0], Result[$1000 + Offset * $400], $400);
    Exit;
  end;

  var MappedSize := FPrgRamMask + 1;
  if FIsMmc6 then
    MappedSize := $400;
  SetLength(Result, MappedSize + Length(FExtraPrgRam));
  if MappedSize > 0 then
    Move(FPrgRam[0], Result[0], MappedSize);
  if Length(FExtraPrgRam) > 0 then
    Move(FExtraPrgRam[0], Result[MappedSize], Length(FExtraPrgRam));
end;

procedure TMapperMmc3.SetSaveMemory(const Data: TByteArray);
begin
  // Accept legacy 8 KiB saves produced before HKROM was recognized.
  if (Length(Data) <> FPrgRamMask + 1 + Length(FExtraPrgRam)) and not (FIsMmc6 and (Length(Data) = $400)) then
    raise ENesException.Create('Invalid cartridge save size');

  if FIsMmc6 and (Length(Data) = $2000) then
  begin
    FLegacySave := Copy(Data);
    Move(Data[$1000], FPrgRam[0], $400);
    Exit;
  end;

  var MappedSize := FPrgRamMask + 1;
  if FIsMmc6 then
    MappedSize := $400;
  if MappedSize > 0 then
    Move(Data[0], FPrgRam[0], MappedSize);
  if Length(FExtraPrgRam) > 0 then
    Move(Data[MappedSize], FExtraPrgRam[0], Length(FExtraPrgRam));
end;

procedure TMapperMmc3.ConfigurePrgRam(Size: Integer);
begin
  if FIsMmc6 or not FUseBankCache or (Size < 0) or (Size > $10000) then
    raise ENesException.Create('Unsupported MMC3 RAM size');

  if Size <= SizeOf(FPrgRam) then
  begin
    if (Size > 0) and ((Size and (Size - 1)) <> 0) then
      raise ENesException.Create('Unsupported MMC3 RAM size');
    FPrgRamMask := Size - 1;
    SetLength(FExtraPrgRam, 0);
  end
  else
  begin
    // Preserve previously supported save sizes without inventing a RAM bank register.
    FPrgRamMask := High(FPrgRam);
    SetLength(FExtraPrgRam, Size - SizeOf(FPrgRam));
  end;
end;

constructor TMapperMmc3.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; AMmc6, AMcAcc, AHardwiredMirroring, ANec: Boolean; AT9552: TMmc3T9552; AUseReloadInterlock, AFceuxCompatibility: Boolean);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  FPrgRamMask := High(FPrgRam);
  FIsMmc6 := AMmc6;
  FIsMcAcc := AMcAcc;
  FIsNec := ANec;
  FFceuxCompatibility := AFceuxCompatibility;
  FIrqRequiresCounterTransition := ANec or FFceuxCompatibility;
  if FFceuxCompatibility then
    FIrqReloadSetMask := $80
  else if AUseReloadInterlock then
    if ANec then
      ConfigureIrqRevision(TMmc3IrqRevision.NecBC)
    else
      ConfigureIrqRevision(TMmc3IrqRevision.SharpBC);
  FHardwiredMirroring := AHardwiredMirroring;
  FInitialMirrorMode := AMirrorMode;
  FFourScreenMirroring := AMirrorMode = TMirrorMode.FourScreen;
  FT9552 := AT9552;
  // Derived boards retain their own bank interpretation and original read path.
  FUseBankCache := (ClassType = TMapperMmc3) or (FT9552 <> NoT9552);
  Reset;
end;

procedure TMapperMmc3.ConfigureIrqRevision(Revision: TMmc3IrqRevision);
const
  ReloadSetMasks: array[TMmc3IrqRevision] of Byte = (0, $80, $80, $FF, $F0);
begin
  if Revision = TMmc3IrqRevision.Auto then
    Exit;
  FIrqRevision := Revision;
  FIrqReloadSetMask := ReloadSetMasks[Revision];
  FIsNec := Revision in [TMmc3IrqRevision.NecA, TMmc3IrqRevision.NecBC];
  FIrqRequiresCounterTransition := Revision <> TMmc3IrqRevision.SharpBC;
end;

procedure TMapperMmc3.PowerOn;
begin
  FT9552Pattern := 0;
  inherited;
end;

procedure TMapperMmc3.Reset;
begin
  FBankSelect := 0;
  if FIsMmc6 then
    FPrgRamControl := 0
  else
    FPrgRamControl := $80;
  FMirrorMode := FInitialMirrorMode;
  FBankRegisters[0] := 0;
  FBankRegisters[1] := 2;
  for var i := 2 to 5 do
    FBankRegisters[i] := i + 2;
  FBankRegisters[6] := 0;
  FBankRegisters[7] := 1;
  FIrqLatch := 0;
  FIrqCounter := 0;
  FIrqReloadPending := False;
  FIrqReloadBlocked := False;
  FFceuxReloadLatched := False;
  FIrqEnabled := False;
  FIrqPending := False;
  FA12High := False;
  FA12LowSince := 0;
  FMcAccPulsePhase := 0;
  UpdateBankOffsets;
end;

function TMapperMmc3.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  var Bank: Integer;
  var Count: Integer;
  Result := False;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if FIsMmc6 then
    begin
      Result := (Address >= $7000) and ((FPrgRamControl and $A0) <> 0);
      if Result then
      begin
        var ReadBit := $20 shl ((Address and $200) shr 8);
        if (FPrgRamControl and ReadBit) <> 0 then
          Value := FPrgRam[Address and $3FF]
        else
          Value := 0;
      end;
    end
    else
    begin
      Result := (FPrgRamMask >= 0) and (FFceuxCompatibility or ((FPrgRamControl and $80) <> 0));
      if Result then
        Value := FPrgRam[Address and FPrgRamMask];
    end;
  end
  else if Address >= $8000 then
  begin
    if FUseBankCache then
    begin
      Value := FPrgRom[FPrgOffsets[(Address - $8000) shr 13] + (Address and $1FFF)];
      Exit(True);
    end;

    Count := Length(FPrgRom) div $2000;
    case (Address - $8000) shr 13 of
      0:
        if (FBankSelect and $40) = 0 then
          Bank := FBankRegisters[6] and $3F
        else
          Bank := Count - 2;
      1:
        Bank := FBankRegisters[7] and $3F;
      2:
        if (FBankSelect and $40) = 0 then
          Bank := Count - 2
        else
          Bank := FBankRegisters[6] and $3F;
    else
      Bank := Count - 1;
    end;
    Value := FPrgRom[(Bank mod Count) * $2000 + (Address and $1FFF)];
    Result := True;
  end;
end;

function TMapperMmc3.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if ((Address and $F000) = $5000) and (FT9552 <> NoT9552) then
  begin
    var Pattern := Value and 7;
    if FT9552Pattern <> Pattern then
    begin
      FT9552Pattern := Pattern;
      UpdateBankOffsets;
    end;
    Exit(True);
  end;
  Result := Address >= $6000;
  if not Result then
    Exit;

  if Address < $8000 then
  begin
    if FIsMmc6 then
    begin
      var EnableBits := $30 shl ((Address and $200) shr 8);
      if (Address >= $7000) and ((FPrgRamControl and EnableBits) = EnableBits) then
        FPrgRam[Address and $3FF] := Value;
    end
    else
    begin
      Result := FPrgRamMask >= 0;
      if Result and (FFceuxCompatibility or ((FPrgRamControl and $C0) = $80)) then
        FPrgRam[Address and FPrgRamMask] := Value;
    end;
    Exit;
  end;

  case Address and $E001 of
    $8000:
      begin
        var BankModesChanged := ((FBankSelect xor Value) and $C0) <> 0;
        FBankSelect := Value;
        if FIsMmc6 and ((Value and $20) = 0) then
          FPrgRamControl := 0;
        if BankModesChanged then
          UpdateBankOffsets;
      end;
    $8001:
      begin
        var RegisterIndex := FBankSelect and 7;
        if FBankRegisters[RegisterIndex] <> Value then
        begin
          FBankRegisters[RegisterIndex] := Value;
          UpdateBankOffsets;
        end;
      end;
    $A000:
      if not (FFourScreenMirroring or FHardwiredMirroring) then
        if (Value and 1) = 0 then
          FMirrorMode := TMirrorMode.Vertical
        else
          FMirrorMode := TMirrorMode.Horizontal;
    $A001:
      if not FIsMmc6 or ((FBankSelect and $20) <> 0) then
        FPrgRamControl := Value;
    $C000:
      FIrqLatch := Value;
    $C001:
      begin
        // The write affects the counter even if the last reload still blocks the request latch.
        if FIrqReloadSetMask = 0 then
          FIrqCounter := 0
        else
          FIrqCounter := FIrqCounter or FIrqReloadSetMask;
        if not FIrqReloadBlocked then
          FIrqReloadPending := True;
        FMcAccPulsePhase := 0;
      end;
    $E000:
      begin
        FIrqEnabled := False;
        FIrqPending := False;
      end;
    $E001:
      FIrqEnabled := True;
  end;
end;

function TMapperMmc3.GetChrOffset(Address: UInt16): Integer;
begin
  if FUseBankCache then
    Exit(FChrOffsets[Address shr 10] + (Address and $3FF));

  var Bank: Integer;
  if (FBankSelect and $80) <> 0 then
    Address := Address xor $1000;
  case Address shr 10 of
    0:
      Bank := FBankRegisters[0] and $FE;
    1:
      Bank := FBankRegisters[0] or 1;
    2:
      Bank := FBankRegisters[1] and $FE;
    3:
      Bank := FBankRegisters[1] or 1;
  else
    Bank := FBankRegisters[2 + ((Address shr 10) - 4)];
  end;
  Result := (Bank * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperMmc3.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if Result then
    Value := FChrMemory[GetChrOffset(Address)];
end;

function TMapperMmc3.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := (Address < $2000) and FHasChrRam;
  if Result then
    FChrMemory[GetChrOffset(Address)] := Value;
end;

function TMapperMmc3.GetMirrorMode: TMirrorMode;
begin
  Result := FMirrorMode;
end;

function TMapperMmc3.AllowsDirectPpuRead: Boolean;
begin
  Result := FUseBankCache;
end;

function TMapperMmc3.AllowsPpuReadCaching: Boolean;
begin
  // CHR reads are passive; A12 IRQs use the separate timed address callbacks.
  // Derived boards must explicitly opt in after checking their read side effects.
  Result := FUseBankCache;
end;

procedure TMapperMmc3.ClockIrqCounter;
begin
  var PreviousCounter := FIrqCounter;
  var RequestedReload := FIrqReloadPending;
  if (FIrqCounter = 0) or RequestedReload then
    FIrqCounter := FIrqLatch
  else
    Dec(FIrqCounter);
  FIrqReloadPending := False;
  FIrqReloadBlocked := RequestedReload and (FIrqReloadSetMask <> 0);
  // On NEC, $C001 sets counter bits before the reload, creating a transition to zero.
  if (FIrqCounter = 0) and FIrqEnabled and
    (not FIrqRequiresCounterTransition or (PreviousCounter <> 0) or (FIsNec and RequestedReload)) then
    FIrqPending := True;
end;

procedure TMapperMmc3.ClockFceuxIrq(Dot: Integer; Rendering: Boolean);
begin
  // The scanline clock consumes the reload request sampled on the previous dot.
  if Dot = 255 then
    FFceuxReloadLatched := FIrqReloadPending
  else if Rendering then
  begin
    var Request := FIrqReloadPending;
    FIrqReloadPending := FFceuxReloadLatched;
    ClockIrqCounter;
    FIrqReloadPending := Request and not FFceuxReloadLatched;
  end;
end;

procedure TMapperMmc3.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FFceuxCompatibility then
    Exit;
  var High: Boolean := (Address and $1000) <> 0;
  if FIsMcAcc then
  begin
    if FA12High = High then
      Exit;
    // MC-ACC clocks on the first A12 fall of each group of eight.
    if not High then
    begin
      if FMcAccPulsePhase = 0 then
        ClockIrqCounter;
      FMcAccPulsePhase := (FMcAccPulsePhase + 1) and 7;
    end;
    FA12High := High;
    Exit;
  end;

  if Mmc3A12RisingEdge(High, PpuCycle, FA12High, FA12LowSince) then
    ClockIrqCounter;
end;

function TMapperMmc3.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

end.

