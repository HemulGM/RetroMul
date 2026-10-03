unit NES.Mapper.Mmc3;

interface

uses
  NES.State, NES.Types, NES.Mapper;

type
  // Standard MMC3B/C. MMC6 and mapper-4 submapper variants are not implemented.
  TMapperMmc3 = class(TMapper)
  protected
    FPrgRom, FChrMemory: TByteArray;
    FPrgRam: array[0..$1FFF] of UInt8;
    FHasChrRam, FFourScreenMirroring: Boolean;
    FInitialMirrorMode, FMirrorMode: TMirrorMode;
    FBankRegisters: array[0..7] of UInt8;
    FBankSelect, FPrgRamControl, FIrqLatch, FIrqCounter: UInt8;
    FIrqReloadPending, FIrqEnabled, FIrqPending, FA12High: Boolean;
    FA12LowSince: UInt64;
    FUseBankCache: Boolean;
    FPrgOffsets: array[0..3] of Integer;
    FChrOffsets: array[0..7] of Integer;
    procedure UpdateBankOffsets;
    function GetChrOffset(Address: UInt16): Integer;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function AllowsPpuReadCaching: Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    procedure Reset; override;
  end;

implementation

procedure TMapperMmc3.UpdateBankOffsets;
begin
  if not FUseBankCache then Exit;
  var Count := Length(FPrgRom) div $2000;
  FPrgOffsets[0] := ((FBankRegisters[6] and $3F) mod Count) * $2000;
  FPrgOffsets[1] := ((FBankRegisters[7] and $3F) mod Count) * $2000;
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
    if (FBankSelect and $80) <> 0 then MappedSlot := Slot xor 4;
    var Bank: Integer;
    if MappedSlot < 4 then
      Bank := (FBankRegisters[MappedSlot shr 1] and $FE) or (MappedSlot and 1)
    else
      Bank := FBankRegisters[MappedSlot - 2];
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
  if State.Loading then UpdateBankOffsets;
end;

function TMapperMmc3.GetSaveMemory: TByteArray;
begin
  SetLength(Result, SizeOf(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperMmc3.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> SizeOf(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');
  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperMmc3.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  FInitialMirrorMode := AMirrorMode;
  FFourScreenMirroring := AMirrorMode = TMirrorMode.FourScreen;
  // Derived boards retain their own bank interpretation and original read path.
  FUseBankCache := ClassType = TMapperMmc3;
  Reset;
end;

procedure TMapperMmc3.Reset;
begin
  FBankSelect := 0;
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
  FIrqEnabled := False;
  FIrqPending := False;
  FA12High := False;
  FA12LowSince := 0;
  UpdateBankOffsets;
end;

function TMapperMmc3.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  var Bank: Integer;
  var Count: Integer;
  Result := False;
  if (Address >= $6000) and (Address < $8000) then
  begin
    Result := (FPrgRamControl and $80) <> 0;
    if Result then
      Value := FPrgRam[Address and $1FFF];
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
  Result := Address >= $6000;
  if not Result then
    Exit;
  if Address < $8000 then
  begin
    if (FPrgRamControl and $C0) = $80 then
      FPrgRam[Address and $1FFF] := Value;
    Exit;
  end;
  case Address and $E001 of
    $8000:
      begin
        FBankSelect := Value;
        UpdateBankOffsets;
      end;
    $8001:
      begin
        FBankRegisters[FBankSelect and 7] := Value;
        UpdateBankOffsets;
      end;
    $A000:
      if not FFourScreenMirroring then
        if (Value and 1) = 0 then
          FMirrorMode := TMirrorMode.Vertical
        else
          FMirrorMode := TMirrorMode.Horizontal;
    $A001:
      FPrgRamControl := Value;
    $C000:
      FIrqLatch := Value;
    $C001:
      begin
        FIrqCounter := 0;
        FIrqReloadPending := True;
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

function TMapperMmc3.AllowsPpuReadCaching: Boolean;
begin
  // CHR reads are passive; A12 IRQs use the separate timed address callbacks.
  // Derived boards must explicitly opt in after checking their read side effects.
  Result := ClassType = TMapperMmc3;
end;

procedure TMapperMmc3.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  var High: Boolean := (Address and $1000) <> 0;
  if not High and FA12High then
    FA12LowSince := PpuCycle;
  // Approximate the M2-qualified filter in PPU dots. Ten dots also reject
  // the short dummy-fetch gap across scanlines with background at $1000.
  if High and not FA12High and (PpuCycle >= FA12LowSince) and (PpuCycle - FA12LowSince >= 10) then
  begin
    if (FIrqCounter = 0) or FIrqReloadPending then
      FIrqCounter := FIrqLatch
    else
      Dec(FIrqCounter);
    FIrqReloadPending := False;
    if (FIrqCounter = 0) and FIrqEnabled then
      FIrqPending := True;
  end;
  FA12High := High;
end;

function TMapperMmc3.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

end.

