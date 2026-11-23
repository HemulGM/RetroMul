unit NES.Mapper.Sunsoft;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperSunsoft = class(TMapperBanked)
  protected
    FWorkBank: Byte;
  private
    FBoard, FCounter: Integer;
    FSelect: Byte;
    FOuterBank: Integer;
    FBankPrg: array[0..1] of Byte;
    FBankChr: array[0..7] of Byte;
    FIrqControl, FIrqLatch: Byte;
    FIrqCycles: Integer;
    FNametableBanks: array[0..1] of Byte;
    FUseChrNametables, FCountEnabled, FIrqEnabled, FPending: Boolean;
    function NameOffset(Address: UInt16): Integer;
    procedure Update831128Banks;
    function Write831128Register(Address: UInt16; Value: Byte): Boolean;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure PowerOn; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperSunsoftDcs = class(TMapperSunsoft)
  private
    FOptionSelected: Boolean;
    FOptionCycles, FOptionBankCount, FOptionOffset: Integer;
    procedure UpdateOptionBank;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ClockCpu; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

const
  DCS_PRG_BANK_SIZE = $4000;
  DCS_INTERNAL_PRG_SIZE = $20000;
  DCS_OPTION_CYCLES = 107520;

procedure TMapperSunsoft.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FBoard, SizeOf(FBoard));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FNametableBanks, SizeOf(FNametableBanks));
  State.Field(FUseChrNametables, SizeOf(FUseChrNametables));
  State.Field(FCountEnabled, SizeOf(FCountEnabled));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FPending, SizeOf(FPending));
  if FBoard = MAPPER_BMC_831128C then
  begin
    State.Field(FOuterBank, SizeOf(FOuterBank));
    State.Field(FBankPrg, SizeOf(FBankPrg));
    State.Field(FBankChr, SizeOf(FBankChr));
    State.Field(FIrqControl, SizeOf(FIrqControl));
    State.Field(FIrqLatch, SizeOf(FIrqLatch));
    State.Field(FIrqCycles, SizeOf(FIrqCycles));
  end;
end;

constructor TMapperSunsoft.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  if FBoard <> MAPPER_BMC_831128C then
    SetLength(FPrgRam, $8000);
  PowerOn;
end;

procedure TMapperSunsoft.PowerOn;
begin
  if FBoard = MAPPER_BMC_831128C then
  begin
    FWorkBank := 0;
    FBankPrg[0] := 0;
    FBankPrg[1] := 1;
    for var Slot := 0 to 7 do
      FBankChr[Slot] := Slot;
    FInitialMirror := TMirrorMode.Vertical;
  end;
  inherited;
end;

procedure TMapperSunsoft.Reset;
begin
  inherited;
  FSelect := 0;
  if FBoard <> MAPPER_BMC_831128C then
    FWorkBank := 0;
  FCounter := 0;
  FCountEnabled := False;
  FIrqEnabled := False;
  FPending := False;
  FUseChrNametables := False;
  FillChar(FNametableBanks, SizeOf(FNametableBanks), 0);
  if FBoard = MAPPER_BMC_831128C then
  begin
    FOuterBank := 0;
    FIrqControl := 0;
    FIrqLatch := 0;
    FIrqCycles := 0;
    Update831128Banks;
  end
  else if FBoard = MAPPER_FME7 then
  begin
    Prg8(0, 0);
    Prg8(1, 1);
    Prg8(2, 2);
  end
  else
  begin
    Prg16(1, 7);
    FRamEnabled := False;
  end;
end;

procedure TMapperSunsoft.Update831128Banks;
begin
  var Mask := FOuterBank or $0F;
  Prg8(0, FOuterBank + (FBankPrg[0] and Mask));
  Prg8(1, FOuterBank + (FBankPrg[1] and Mask));
  Prg8(2, FOuterBank + ($FE and Mask));
  Prg8(3, FOuterBank + Mask);
  for var Slot := 0 to 7 do
    Chr1(Slot, (FOuterBank shl 4) or FBankChr[Slot]);
end;

function TMapperSunsoft.Write831128Register(Address: UInt16; Value: Byte): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if FWorkBank = 1 then
      FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;
  if ((Address and $F000) <> $A000) and ((Address and $F000) <> $C000) then
    Exit(False);

  var RegisterIndex := Address and $0F;
  case RegisterIndex of
    0..7:
      FBankChr[RegisterIndex] := Value;
    8:
      FWorkBank := Value;
    9, 10:
      FBankPrg[RegisterIndex - 9] := Value;
    12:
      Mirror(Value and 3);
    13:
      begin
        FIrqControl := Value;
        if (Value and 2) <> 0 then
        begin
          FCounter := FIrqLatch;
          FIrqCycles := 341;
        end;
        FPending := False;
      end;
    14:
      begin
        FIrqControl := (FIrqControl and $FD) or ((FIrqControl and 1) shl 1);
        FPending := False;
      end;
    15:
      FIrqLatch := Value;
  end;
  FOuterBank := (Address and $4000) shr 10;
  Update831128Banks;
  Result := True;
end;

function TMapperSunsoft.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_BMC_831128C) and (Address >= $6000) and (Address < $8000) then
  begin
    if FWorkBank = 1 then
      Value := FPrgRam[Address and $1FFF]
    else
    begin
      var Bank := FOuterBank + (FWorkBank and (FOuterBank or $0F));
      Value := FPrgRom[(Bank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    end;
    Exit(True);
  end;
  if (FBoard = MAPPER_FME7) and (Address >= $6000) and (Address < $8000) then
  begin
    if (FWorkBank and $40) = 0 then
      Value := FPrgRom[((FWorkBank and $3F) * $2000 + (Address and $1FFF)) mod Length(FPrgRom)]
    else if (FWorkBank and $80) <> 0 then
      Value := FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)]
    else
      Exit(False);
    Exit(True);
  end;

  Result := inherited CpuRead(Address, Value);
end;

function TMapperSunsoft.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FBoard = MAPPER_BMC_831128C then
    Exit(Write831128Register(Address, Value));
  if Address < $8000 then
  begin
    if (FBoard = MAPPER_FME7) and (Address >= $6000) then
    begin
      if (FWorkBank and $C0) = $C0 then
        FPrgRam[(FWorkBank and 3) * $2000 + (Address and $1FFF)] := Value;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;

  Result := True;
  if FBoard = MAPPER_SUNSOFT4 then
    case Address shr 12 of
      8..$B:
        Chr2((Address shr 12) - 8, Value);
      $C, $D:
        FNametableBanks[(Address shr 12) - $C] := Value or $80;
      $E:
        begin
          Mirror(Value and 3);
          FUseChrNametables := (Value and $10) <> 0;
        end;
      $F:
        begin
          Prg16(0, Value and 7);
          FRamEnabled := (Value and $10) <> 0;
        end;
    end
  else
    case Address and $E000 of
      $8000:
        FSelect := Value and $0F;
      $A000:
        case FSelect of
          0..7:
            Chr1(FSelect, Value);
          8:
            FWorkBank := Value;
          9..11:
            Prg8(FSelect - 9, Value and $3F);
          12:
            Mirror(Value and 3);
          13:
            begin
              FIrqEnabled := (Value and 1) <> 0;
              FCountEnabled := (Value and $80) <> 0;
              FPending := False;
            end;
          14:
            FCounter := (FCounter and $FF00) or Value;
          15:
            FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
        end;
    end;
end;

function TMapperSunsoft.NameOffset(Address: UInt16): Integer;
begin
  var Slot := ((Address - $2000) shr 10) and 3;
  case FMirror of
    TMirrorMode.Vertical:
      Slot := Slot and 1;
    TMirrorMode.Horizontal:
      Slot := Slot shr 1;
    TMirrorMode.Single0:
      Slot := 0;
    TMirrorMode.Single1:
      Slot := 1;
  else
    Slot := Slot and 1;
  end;
  Result := (FNametableBanks[Slot] * $400 + (Address and $3FF)) mod Length(FChrMemory);
end;

function TMapperSunsoft.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FUseChrNametables and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FChrMemory[NameOffset(Address)];
    Exit(True);
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperSunsoft.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if FUseChrNametables and (Address >= $2000) and (Address < $3F00) then
  begin
    if FHasChrRam then
      FChrMemory[NameOffset(Address)] := Value;
    Exit(True);
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperSunsoft.ClockCpu;
begin
  if FBoard = MAPPER_BMC_831128C then
  begin
    if (FIrqControl and 2) = 0 then
      Exit;
    if (FIrqControl and 4) = 0 then
    begin
      Dec(FIrqCycles, 3);
      if FIrqCycles > 0 then
        Exit;
      Inc(FIrqCycles, 341);
    end;
    if FCounter = $FF then
    begin
      FCounter := FIrqLatch;
      FPending := True;
    end
    else
      Inc(FCounter);
    Exit;
  end;
  if FCountEnabled then
  begin
    FCounter := (FCounter - 1) and $FFFF;
    if (FCounter = $FFFF) and FIrqEnabled then
      FPending := True;
  end;
end;

function TMapperSunsoft.IrqPending: Boolean;
begin
  Result := FPending;
end;

constructor TMapperSunsoftDcs.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  if (Length(Prg) < DCS_INTERNAL_PRG_SIZE) or (Length(Prg) > DCS_INTERNAL_PRG_SIZE * 2) or
    ((Length(Prg) mod DCS_PRG_BANK_SIZE) <> 0) then
    raise ENesException.Create('Invalid Sunsoft DCS PRG ROM layout');

  // The combined dump places the option ROM after the eight internal banks.
  FOptionBankCount := (Length(Prg) - DCS_INTERNAL_PRG_SIZE) div DCS_PRG_BANK_SIZE;
  inherited Create(MAPPER_SUNSOFT4, Prg, Chr, HasChrRam, MirrorMode);
end;

procedure TMapperSunsoftDcs.Reset;
begin
  inherited;
  FOptionSelected := True;
  FOptionCycles := 0;
  UpdateOptionBank;
end;

procedure TMapperSunsoftDcs.UpdateOptionBank;
begin
  if FOptionBankCount <> 0 then
    FOptionOffset := DCS_INTERNAL_PRG_SIZE + ((FPrgBanks[0] shr 1) mod FOptionBankCount) * DCS_PRG_BANK_SIZE;
end;

procedure TMapperSunsoftDcs.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= 34 then
  begin
    State.Field(FOptionSelected, SizeOf(FOptionSelected));
    State.Field(FOptionCycles, SizeOf(FOptionCycles));
  end
  else if State.Loading then
  begin
    // Older snapshots used the ordinary Sunsoft-4 mapper with internal PRG.
    FOptionSelected := False;
    FOptionCycles := 0;
  end;
  if State.Loading then
    UpdateOptionBank;
end;

procedure TMapperSunsoftDcs.ClockCpu;
begin
  if FOptionCycles > 0 then
    Dec(FOptionCycles);
end;

function TMapperSunsoftDcs.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FOptionSelected and (Address >= $8000) and (Address < $C000) then
  begin
    if (FOptionBankCount = 0) or (FOptionCycles = 0) then
      Exit(False);
    Value := FPrgRom[FOptionOffset + (Address and $3FFF)];
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperSunsoftDcs.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) and not FRamEnabled then
  begin
    if FOptionBankCount <> 0 then
      FOptionCycles := DCS_OPTION_CYCLES;
    Exit(True);
  end;

  Result := inherited CpuWrite(Address, Value);
  if Address >= $F000 then
  begin
    FOptionSelected := (Value and 8) = 0;
    UpdateOptionBank;
  end;
end;

end.

