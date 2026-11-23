unit NES.Mapper.Mmc1;

interface

uses
  NES.State, NES.Types, NES.Mapper, HW.EEPROM93Cxx;

type
  TMapperMmc1 = class(TMapper)
  private
    FPrgRom: TByteArray;
    FChrMemory: TByteArray;
    FPrgRam: TByteArray;
    FHasChrRam: Boolean;
    FHasBoardPrgRam: Boolean;
    FFixedPrg, FFixedMirror: Boolean;
    FForceRamEnabled: Boolean;
    FBoardMirrorMode: TMirrorMode;
    FShiftRegister: UInt8;
    FWriteCount: Integer;
    FLastWriteCycle: UInt64;
    FHasLastWrite: Boolean;
    FBoard, FOuter, FInit: Integer;
    FDiscreteLatch, FOuterShift, FOuterBits: Byte;
    FLocked, FIrqEnabled, FPending: Boolean;
    FIrqCounter: UInt32;
    // Derived slot offsets; excluded from snapshots and rebuilt on load.
    FUseBankCache: Boolean;
    FPrgOffsets, FChrOffsets: array[0..1] of Integer;
    procedure UpdateBankOffsets;
    procedure ResetRegisters;
    function GetPrgOffset(Address: UInt16): Integer;
    function GetPrgRamOffset(Address: UInt16): Integer;
    function GetChrOffset(Address: UInt16): Integer;
    procedure UpdateEvent;
    function GetPrgBankCount: Integer;
    function GetChrBankCount4K: Integer;
    function MapPrgBank(Bank: Integer): Integer;
    function MapChrBank4K(Bank: Integer): Integer;
    function Uses3927ChrLatch: Boolean; inline;
    procedure Latch03101OuterBank(Address: UInt16); inline;
  protected
    FControl, FChrBank0, FChrBank1, FPrgBank: UInt8;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    constructor Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; ForceRamEnabled: Boolean = False; Board: Integer = MAPPER_MMC1; Submapper: Integer = 0);
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function GetMirrorMode: TMirrorMode; override;
    function AllowsPpuReadCaching: Boolean; override;
    function AllowsDirectPpuRead: Boolean; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SelectNt319Block(Block: Integer);
    property HasBoardPrgRam: Boolean read FHasBoardPrgRam write FHasBoardPrgRam;
  end;

  // This mapper sees the FCNS card bus. The adapter owns the PPU and CPU-side I/O.
  TMapperMmc1TwoMe = class(TMapperMmc1)
  private
    FEeprom: TSerialEEPROM93Cxx;
    FEepromCycle: Int64;
    FCardRamSize, FCardNvRamSize: Integer;
    procedure UpdateEepromPins;
    function CardRamOffset(Address: UInt16): Integer; inline;
  public
    constructor Create(const Prg: TByteArray);
    destructor Destroy; override;
    procedure ConfigureCardRam(RamSize, NvRamSize: UInt64);
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    procedure PowerOn; override;
    procedure Reset; override;
  end;

function ShiftMmc1Register(Value: Byte; var Shift: Byte; var WriteCount: Integer): Boolean; inline;

implementation

uses
  NES.Consts;

const
  TWO_ME_STATE_VERSION = 32;
  TWO_ME_SRAM_CAPACITY = $8000;
  TWO_ME_EEPROM_SIZE = $80;
  MICROWIRE_PROGRAM_US = 4000;

function ShiftMmc1Register(Value: Byte; var Shift: Byte; var WriteCount: Integer): Boolean;
begin
  Shift := (Shift shr 1) or ((Value and 1) shl 4);
  Inc(WriteCount);
  Result := WriteCount = 5;
end;

function TMapperMmc1.AllowsDirectPpuRead: Boolean;
begin
  // Derived boards retain the contextual path unless they explicitly opt in.
  Result := ClassType = TMapperMmc1;
end;

function TMapperMmc1.AllowsPpuReadCaching: Boolean;
begin
  // CHR mapping changes only on CPU writes, outside synchronous scanline rendering.
  Result := ClassType = TMapperMmc1;
end;

procedure TMapperMmc1.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if Length(FChrMemory) > 0 then
    State.Field(FChrMemory[0], Length(FChrMemory) * SizeOf(FChrMemory[0]));
  if (State.Version < TWO_ME_STATE_VERSION) and (Self is TMapperMmc1TwoMe) then
    State.Field(FPrgRam[0], $2000)
  else
    State.Field(FPrgRam[0], Length(FPrgRam));
  State.Field(FHasChrRam, SizeOf(FHasChrRam));
  State.Field(FBoardMirrorMode, SizeOf(FBoardMirrorMode));
  State.Field(FShiftRegister, SizeOf(FShiftRegister));
  State.Field(FWriteCount, SizeOf(FWriteCount));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FChrBank0, SizeOf(FChrBank0));
  State.Field(FChrBank1, SizeOf(FChrBank1));
  State.Field(FPrgBank, SizeOf(FPrgBank));
  State.Field(FLastWriteCycle, SizeOf(FLastWriteCycle));
  State.Field(FHasLastWrite, SizeOf(FHasLastWrite));
  if FBoard <> MAPPER_MMC1 then
  begin
    State.Field(FOuter, SizeOf(FOuter));
    State.Field(FInit, SizeOf(FInit));
    State.Field(FLocked, SizeOf(FLocked));
    State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FIrqCounter, SizeOf(FIrqCounter));
  end;
  if (FBoard = MAPPER_JY_CHESS_550) or (FBoard = MAPPER_BMC_3927) then
    State.Field(FDiscreteLatch, SizeOf(FDiscreteLatch));
  if FBoard = MAPPER_CH501 then
  begin
    State.Field(FOuterShift, SizeOf(FOuterShift));
    State.Field(FOuterBits, SizeOf(FOuterBits));
  end;
  if State.Loading then
    UpdateBankOffsets;
end;

function TMapperMmc1.GetSaveMemory: TByteArray;
begin
  SetLength(Result, Length(FPrgRam));
  Move(FPrgRam[0], Result[0], Length(Result));
end;

procedure TMapperMmc1.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> Length(FPrgRam) then
    raise ENesException.Create('Invalid cartridge save size');

  Move(Data[0], FPrgRam[0], Length(Data));
end;

constructor TMapperMmc1.Create(const APrgRom, AChrData: TByteArray; AHasChrRam: Boolean; AMirrorMode: TMirrorMode; ForceRamEnabled: Boolean; Board, Submapper: Integer);
begin
  inherited Create;
  ValidateMemory(APrgRom, AChrData);
  FPrgRom := Copy(APrgRom);
  FChrMemory := Copy(AChrData);
  FHasChrRam := AHasChrRam;
  FFixedPrg := Submapper = 5;
  FFixedMirror := Submapper = 7;
  FHasBoardPrgRam := not FFixedPrg and (Board <> MAPPER_MGC002) and (Board <> MAPPER_GAMESTAR_CM9309);
  FForceRamEnabled := ForceRamEnabled;
  FBoard := Board;
  if FBoard = MAPPER_CH501 then
    SetLength(FPrgRam, $10000)
  else
    SetLength(FPrgRam, $2000);
  FUseBankCache := ClassType = TMapperMmc1;
  FBoardMirrorMode := AMirrorMode;
  if Length(FChrMemory) = 0 then
    SetLength(FChrMemory, $2000);
  if FBoard = MAPPER_CH501 then
    SetLength(FChrMemory, $8000);
  PowerOn;
end;

function TMapperMmc1.GetPrgBankCount: Integer;
begin
  Result := Length(FPrgRom) div $4000;
  if Result <= 0 then
    Result := 1;
end;

function TMapperMmc1.GetChrBankCount4K: Integer;
begin
  Result := Length(FChrMemory) div $1000;
  if Result <= 0 then
    Result := 1;
end;

function TMapperMmc1.MapPrgBank(Bank: Integer): Integer;
begin
  if FBoard = MAPPER_FARID_SLROM then
    Bank := FOuter or (Bank and 7);
  if FBoard = MAPPER_JY_CHESS_550 then
    Bank := ((FOuter and 7) shl 2) or (Bank and 7);
  if (FBoard = MAPPER_RESET_SLROM) or (FBoard = MAPPER_BMC_NT319) then
    Bank := (FOuter shl 3) or (Bank and 7);
  if FBoard = MAPPER_JY012005 then
  begin
    var Mask := $F shr Ord((FOuter and $40) <> 0);
    Bank := ((FOuter shl 3) and not Mask) or (Bank and Mask);
  end;
  case FBoard of
    MAPPER_BMC_3927, MAPPER_BMC_FC41:
      Bank := (FOuter shl 3) or (Bank and 7);
    MAPPER_BMC_K3011:
      Bank := ((FOuter shr 1) and $20) or (FOuter and $18) or (Bank and 7);
    MAPPER_BMC_03101:
      Bank := $10 or (Bank and $0F);
    MAPPER_GAMESTAR_CM9309:
      begin
        var Mask := 3 or ((FOuter and 8) shr 1);
        Bank := (FOuter and $0C) or (Bank and Mask);
      end;
    MAPPER_MGC002:
      Bank := $08 or (Bank and 7);
    MAPPER_CH501:
      Bank := (FOuter shl 4) or (Bank and $0F);
  end;
  Result := Bank mod GetPrgBankCount;
  if Result < 0 then
    Inc(Result, GetPrgBankCount);
end;

function TMapperMmc1.MapChrBank4K(Bank: Integer): Integer;
begin
  if FBoard = MAPPER_FARID_SLROM then
    Bank := (FOuter shl 2) or (Bank and 31);
  if FBoard = MAPPER_JY_CHESS_550 then
    Bank := ((FOuter shl 2) and $18) or (Bank and 7);
  if (FBoard = MAPPER_RESET_SLROM) or (FBoard = MAPPER_BMC_NT319) then
    Bank := (FOuter shl 5) or (Bank and $1F);
  if FBoard = MAPPER_JY012005 then
    Bank := (FOuter shl 5) or (Bank and $1F);
  case FBoard of
    MAPPER_BMC_3927:
      if FOuter = 6 then
        Bank := $78 or (Bank and 7)
      else
        Bank := (FOuter shl 5) or (Bank and $1F);
    MAPPER_BMC_K3011:
      Bank := ((FOuter shl 1) and $80) or ((FOuter shl 2) and $60) or (Bank and $1F);
    MAPPER_BMC_FC41:
      Bank := (FOuter shl 5) or (Bank and $1F);
    MAPPER_GAMESTAR_CM9309:
      if (FOuter and 4) <> 0 then
        Bank := ((FOuter shl 2) and $20) or (Bank and $1F)
      else
        Bank := $40 or (Bank and 7);
    MAPPER_MGC002:
      Bank := $20 or (Bank and $1F);
    MAPPER_CH501:
      Bank := Bank and 7;
  end;
  Result := Bank mod GetChrBankCount4K;
  if Result < 0 then
    Inc(Result, GetChrBankCount4K);
end;

function TMapperMmc1.GetPrgOffset(Address: UInt16): Integer;
begin
  // SEROM, SHROM and SH1ROM take PRG A14 directly from the CPU.
  if FFixedPrg then
    Exit((Address and $7FFF) mod Length(FPrgRom));
  if (FBoard = MAPPER_GAMESTAR_CM9309) and ((FOuter and 4) = 0) then
    Exit((((FOuter and 3) * $4000) + (Address and $3FFF)) mod Length(FPrgRom));
  if (FBoard = MAPPER_MGC002) and ((FOuter and 1) = 0) then
  begin
    var Bank := (FOuter and 2) shl 1;
    if Address < $C000 then
      Bank := Bank or ((FDiscreteLatch shr 4) and 3)
    else
      Bank := Bank or 3;
    Exit((Bank * $4000 + (Address and $3FFF)) mod Length(FPrgRom));
  end;
  if (FBoard = MAPPER_BMC_03101) and ((FOuter and $10) = 0) then
  begin
    if (FOuter and $20) <> 0 then
      Exit(((FOuter shr 1) * $8000 + (Address and $7FFF)) mod Length(FPrgRom));
    Exit((FOuter * $4000 + (Address and $3FFF)) mod Length(FPrgRom));
  end;
  if (FBoard = MAPPER_BMC_3927) and (FOuter >= 3) then
    Exit(((FOuter + 9) * $8000 + (Address and $7FFF)) mod Length(FPrgRom));
  if (FBoard = MAPPER_BMC_K3011) and ((FOuter and $20) = 0) then
  begin
    if (FOuter and 5) <> 0 then
      Exit(((FOuter shr 1) * $8000 + (Address and $7FFF)) mod Length(FPrgRom));
    Exit((FOuter * $4000 + (Address and $3FFF)) mod Length(FPrgRom));
  end;
  if (FBoard = MAPPER_JY_CHESS_550) and ((FOuter and 6) <> 6) then
  begin
    var Bank32K := ((FOuter and 7) shl 1) or ((FDiscreteLatch shr 4) and 1);
    Exit((Bank32K * $8000 + (Address and $7FFF)) mod Length(FPrgRom));
  end;
  var Bank16K, Offset: Integer;
  var PrgMode: Integer := (FControl shr 2) and 3;
  if FBoard = MAPPER_MMC1_105 then
  begin
    if FInit <> 2 then
      Bank16K := (Address - $8000) div $4000
    else if (FChrBank0 and 8) = 0 then
      Bank16K := (FChrBank0 and 6) + ((Address - $8000) div $4000)
    else if PrgMode < 2 then
      Bank16K := (FPrgBank and 6) + 8 + ((Address - $8000) div $4000)
    else if PrgMode = 2 then
      if Address < $C000 then
        Bank16K := 8
      else
        Bank16K := (FPrgBank and 7) or 8
    else if Address < $C000 then
      Bank16K := (FPrgBank and 7) or 8
    else
      Bank16K := 15;
    Exit((MapPrgBank(Bank16K) * $4000 + (Address and $3FFF)) mod Length(FPrgRom));
  end;
  var OuterBank := 0;
  // SUROM connects CHR A16 to PRG A18, including the fixed bank.
  if (FBoard <> MAPPER_BMC_03101) and FHasChrRam and (Length(FPrgRom) >= $80000) then
    OuterBank := FChrBank0 and $10;
  case PrgMode of
    0, 1:
      begin
        Bank16K := MapPrgBank(OuterBank or ((FPrgBank and $0E) + ((Address - $8000) div $4000)));
        Offset := Bank16K * $4000 + ((Address - $8000) and $3FFF);
      end;
    2:
      begin
        if Address < $C000 then
          Bank16K := MapPrgBank(OuterBank)
        else
          Bank16K := MapPrgBank(OuterBank or (FPrgBank and $0F));
        Offset := Bank16K * $4000 + (Address and $3FFF);
      end;
  else
    begin
      if Address < $C000 then
        Bank16K := MapPrgBank(OuterBank or (FPrgBank and $0F))
      else if FHasChrRam and (GetPrgBankCount > 16) then
        Bank16K := MapPrgBank(OuterBank or $0F)
      else if FBoard = MAPPER_GAMESTAR_CM9309 then
        Bank16K := MapPrgBank($F)
      else if FBoard = MAPPER_JY012005 then
        Bank16K := MapPrgBank($F)
      else if (FBoard = MAPPER_FARID_SLROM) or (FBoard = MAPPER_JY_CHESS_550) or (FBoard = MAPPER_RESET_SLROM) or
        (FBoard = MAPPER_BMC_3927) or (FBoard = MAPPER_BMC_K3011) or (FBoard = MAPPER_BMC_FC41) or
        (FBoard = MAPPER_BMC_NT319) or (FBoard = MAPPER_MGC002) then
        Bank16K := MapPrgBank(7)
      else
        Bank16K := GetPrgBankCount - 1;
      Offset := Bank16K * $4000 + (Address and $3FFF);
    end;
  end;

  Result := Offset mod Length(FPrgRom);
end;

function TMapperMmc1.GetPrgRamOffset(Address: UInt16): Integer;
begin
  Result := Address and $1FFF;
  if FBoard = MAPPER_CH501 then
  begin
    var Bank := ((FOuter and 1) shl 1) or ((FChrBank0 and 8) shr 3);
    if (FOuter and 2) <> 0 then
      Bank := 4 or (FOuter and 1) or ((FOuter and 4) shr 1);
    Inc(Result, Bank * $2000);
  end;
end;

function TMapperMmc1.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    if (FBoard = MAPPER_BMC_03101) and ((FOuter and $10) = 0) then
      Exit(False);
    if not FHasBoardPrgRam or
      ((FBoard <> MAPPER_GAMESTAR_CM9309) and not FForceRamEnabled and ((FPrgBank and $10) <> 0)) then
      Exit(False); // Unmapped PRG RAM leaves the CPU's open bus intact.
    Value := FPrgRam[GetPrgRamOffset(Address)];
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  if FUseBankCache then
    Value := FPrgRom[FPrgOffsets[(Address - $8000) shr 14] + (Address and $3FFF)]
  else
    Value := FPrgRom[GetPrgOffset(Address)];
end;

function TMapperMmc1.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_GAMESTAR_CM9309) and (Address >= $6000) and (Address < $8000) then
  begin
    if FHasBoardPrgRam then
      FPrgRam[Address and $1FFF] := Value;
    FOuter := Address and $FF;
    UpdateBankOffsets;
    Exit(True);
  end;
  if (FBoard = MAPPER_MGC002) and ((Address and $E100) = $4100) then
  begin
    FOuter := Value and 3;
    FHasLastWrite := False;
    UpdateBankOffsets;
    Exit(True);
  end;
  if (FBoard = MAPPER_CH501) and ((Address and $F000) = $5000) then
  begin
    FOuterShift := FOuterShift or (((Value and 8) shr 3) shl FOuterBits);
    Inc(FOuterBits);
    if FOuterBits = 4 then
    begin
      FOuter := FOuterShift;
      FOuterShift := 0;
      FOuterBits := 0;
      UpdateBankOffsets;
    end;
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if (FBoard = MAPPER_BMC_03101) and ((FOuter and $10) = 0) then
      Exit(False);
    if FBoard = MAPPER_JY012005 then
    begin
      if FHasBoardPrgRam then
        FPrgRam[Address and $1FFF] := Value;
      if not FLocked then
      begin
        FOuter := Value;
        FLocked := (Value and $80) <> 0;
        UpdateBankOffsets;
      end;
      Exit(True);
    end;
    case FBoard of
      MAPPER_BMC_K3011, MAPPER_BMC_FC41:
        begin
          if not FForceRamEnabled and ((FPrgBank and $10) <> 0) then
            Exit(True);
          if FHasBoardPrgRam then
            FPrgRam[Address and $1FFF] := Value;
          if (FBoard = MAPPER_BMC_K3011) or ((FOuter and 8) = 0) then
          begin
            FOuter := Address and $FF;
            UpdateBankOffsets;
          end;
          Exit(True);
        end;
    end;
    if not FHasBoardPrgRam then
      Exit(False);
    if FBoard = MAPPER_FARID_SLROM then
    begin
      if not FLocked and ((FPrgBank and $10) = 0) then
      begin
        FOuter := (Value and $70) shr 1;
        FLocked := (Value and 8) <> 0;
        UpdateBankOffsets;
      end;
      Exit(True);
    end;
    if FForceRamEnabled or ((FPrgBank and $10) = 0) then
      FPrgRam[GetPrgRamOffset(Address)] := Value;
    if (FBoard = MAPPER_JY_CHESS_550) and (Address >= $7000) and ((FOuter and 8) = 0) then
    begin
      FOuter := Address and $0F;
      UpdateBankOffsets;
    end;
    Exit(True);
  end;

  Result := Address >= $8000;
  if not Result then
    Exit;

  if FBoard = MAPPER_BMC_03101 then
    Latch03101OuterBank(Address);

  if (FBoard = MAPPER_MGC002) and ((FOuter and 1) = 0) then
  begin
    FDiscreteLatch := Value;
    UpdateBankOffsets;
    Exit;
  end;

  if Uses3927ChrLatch then
  begin
    FDiscreteLatch := Value and 3;
    UpdateBankOffsets;
    Exit;
  end;

  if FBoard = MAPPER_JY_CHESS_550 then
  begin
    FDiscreteLatch := Value;
    if (FOuter and 6) <> 6 then
    begin
      UpdateBankOffsets;
      Exit;
    end;
  end;

  if (Value and $80) <> 0 then
  begin
    FShiftRegister := $10;
    FWriteCount := 0;
    FControl := FControl or $0C;
    UpdateEvent;
    UpdateBankOffsets;
    Exit;
  end;

  var RegisterIndex := (Address shr 13) and 3;
  var RegisterValue: UInt8;
  if FBoard = MAPPER_PREDATOR_C806 then
  begin
    RegisterIndex := Address and 3;
    RegisterValue := Value and $1F;
  end
  else
  begin
    if not ShiftMmc1Register(Value, FShiftRegister, FWriteCount) then
      Exit;
    RegisterValue := FShiftRegister and $1F;
  end;
  case RegisterIndex of
    0:
      FControl := RegisterValue;
    1:
      FChrBank0 := RegisterValue;
    2:
      FChrBank1 := RegisterValue;
    3:
      FPrgBank := RegisterValue;
  end;

  FShiftRegister := $10;
  FWriteCount := 0;
  UpdateEvent;
  UpdateBankOffsets;
end;

procedure TMapperMmc1.Latch03101OuterBank(Address: UInt16);
begin
  if (Address and $EF00) = $8000 then
  begin
    FOuter := Address and $FF;
    UpdateBankOffsets;
  end;
end;

procedure TMapperMmc1.UpdateBankOffsets;
begin
  if not FUseBankCache then
    Exit;
  FPrgOffsets[0] := GetPrgOffset($8000);
  FPrgOffsets[1] := GetPrgOffset($C000);
  FChrOffsets[0] := GetChrOffset($0000);
  FChrOffsets[1] := GetChrOffset($1000);
end;

procedure TMapperMmc1.UpdateEvent;
begin
  if FBoard <> MAPPER_MMC1_105 then
    Exit;
  if (FInit = 0) and ((FChrBank0 and $10) = 0) then
    FInit := 1
  else if (FInit = 1) and ((FChrBank0 and $10) <> 0) then
    FInit := 2;
  FIrqEnabled := (FChrBank0 and $10) = 0;
  if not FIrqEnabled then
  begin
    FIrqCounter := 0;
    FPending := False
  end;
end;

procedure TMapperMmc1.ClockCpu;
begin
  if FIrqEnabled then
  begin
    Inc(FIrqCounter);
    if FIrqCounter >= $20000000 then
    begin
      FPending := True;
      FIrqEnabled := False
    end
  end;
end;

function TMapperMmc1.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperMmc1.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  if (Address >= $8000) and (((FBoard = MAPPER_MGC002) and ((FOuter and 1) = 0)) or
    Uses3927ChrLatch or
    ((FBoard = MAPPER_PREDATOR_C806) and ((Value and $80) = 0))) then
    Exit(CpuWrite(Address, Value));
  if (FBoard = MAPPER_JY_CHESS_550) and (Address >= $8000) then
  begin
    FDiscreteLatch := Value;
    if (FOuter and 6) <> 6 then
      Exit(CpuWrite(Address, Value));
  end;
  if Address >= $8000 then
  begin
    // MMC1 ignores the second consecutive write of a CPU RMW instruction.
    if FHasLastWrite and (CpuCycle > FLastWriteCycle) and (CpuCycle - FLastWriteCycle = 1) then
    begin
      if FBoard = MAPPER_BMC_03101 then
        Latch03101OuterBank(Address);
      Exit(True);
    end;
    FHasLastWrite := True;
    FLastWriteCycle := CpuCycle;
  end;
  Result := CpuWrite(Address, Value);
end;

function TMapperMmc1.Uses3927ChrLatch: Boolean;
begin
  Result := (FBoard = MAPPER_BMC_3927) and (FOuter >= 3) and (FOuter <= 5);
end;

function TMapperMmc1.GetChrOffset(Address: UInt16): Integer;
begin
  if (FBoard = MAPPER_MGC002) and ((FOuter and 1) = 0) then
    Exit((((FDiscreteLatch and $F) * $2000) + Address) mod Length(FChrMemory));
  if FBoard = MAPPER_BMC_03101 then
    Exit(Address);
  if Uses3927ChrLatch then
  begin
    var Bank8K := $30 or ((FOuter - 3) shl 2) or FDiscreteLatch;
    Exit((Bank8K * $2000 + (Address and $1FFF)) mod Length(FChrMemory));
  end;
  if (FBoard = MAPPER_JY_CHESS_550) and ((FOuter and 6) <> 6) then
  begin
    var Bank8K := ((FOuter shl 1) and $0C) or (FDiscreteLatch and 3);
    Exit((Bank8K * $2000 + (Address and $1FFF)) mod Length(FChrMemory));
  end;
  if (FBoard = MAPPER_MMC1_105) and (Address < $2000) then
  begin
    Exit(Address)
  end;
  var Bank4K: Integer;
  var Offset: Integer;
  var ChrMode: Integer := (FControl shr 4) and 1;
  if ChrMode = 0 then
  begin
    Bank4K := MapChrBank4K((FChrBank0 and $1E) + (Address div $1000));
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end
  else
  begin
    if Address < $1000 then
      Bank4K := MapChrBank4K(FChrBank0)
    else
      Bank4K := MapChrBank4K(FChrBank1);
    Offset := Bank4K * $1000 + (Address and $0FFF);
  end;

  Result := Offset mod Length(FChrMemory);
end;

function TMapperMmc1.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := Address < $2000;
  if not Result then
    Exit;
  if FUseBankCache then
    Value := FChrMemory[FChrOffsets[Address shr 12] + (Address and $0FFF)]
  else
    Value := FChrMemory[GetChrOffset(Address)];
end;

function TMapperMmc1.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_BMC_03101) and ((FOuter and $80) <> 0) and (Address < $2000) then
    Exit(True);
  Result := (Address < $2000) and FHasChrRam;
  if not Result then
    Exit;
  if FUseBankCache then
    FChrMemory[FChrOffsets[Address shr 12] + (Address and $0FFF)] := Value
  else
    FChrMemory[GetChrOffset(Address)] := Value;
end;

function TMapperMmc1.GetMirrorMode: TMirrorMode;
begin
  if Uses3927ChrLatch or ((FBoard = MAPPER_MGC002) and ((FOuter and 1) = 0)) then
    Exit(TMirrorMode.Vertical);
  // The KS-7058 routes the PPU address line directly to CIRAM.
  if FFixedMirror or (FBoardMirrorMode = TMirrorMode.FourScreen) then
    Exit(FBoardMirrorMode);

  case FControl and 3 of
    0:
      Result := TMirrorMode.Single0;
    1:
      Result := TMirrorMode.Single1;
    2:
      Result := TMirrorMode.Vertical;
  else
    Result := TMirrorMode.Horizontal;
  end;
end;

procedure TMapperMmc1.PowerOn;
begin
  if (FBoard = MAPPER_RESET_SLROM) or (FBoard = MAPPER_BMC_3927) or (FBoard = MAPPER_MGC002) then
  begin
    FOuter := 0;
    ResetRegisters;
  end
  else
    inherited;
end;

procedure TMapperMmc1.Reset;
begin
  if FBoard = MAPPER_MGC002 then
  begin
    FHasLastWrite := False;
    Exit;
  end;
  if FBoard = MAPPER_RESET_SLROM then
    FOuter := (FOuter + 1) and $FF
  else if FBoard = MAPPER_BMC_3927 then
    FOuter := (FOuter + 1) mod 7
  else
    FOuter := 0;
  ResetRegisters;
end;

procedure TMapperMmc1.SelectNt319Block(Block: Integer);
begin
  FOuter := Block;
  UpdateBankOffsets;
end;

procedure TMapperMmc1.ResetRegisters;
begin
  FShiftRegister := $10;
  FWriteCount := 0;
  FControl := $0C;
  FChrBank0 := 0;
  FChrBank1 := 0;
  FPrgBank := 0;
  FOuterShift := 0;
  FOuterBits := 0;
  if FBoard = MAPPER_CH501 then
    FPrgBank := $0E;
  FHasLastWrite := False;
  FLastWriteCycle := 0;
  FDiscreteLatch := 0;
  FLocked := False;
  FInit := 0;
  FIrqCounter := 0;
  FIrqEnabled := False;
  FPending := False;
  if FBoard = MAPPER_MMC1_105 then
    FChrBank0 := $10;
  UpdateBankOffsets;
end;

constructor TMapperMmc1TwoMe.Create(const Prg: TByteArray);
begin
  inherited Create(Prg, nil, False, TMirrorMode.Horizontal);
  FUseBankCache := True;
  UpdateBankOffsets;
  SetLength(FPrgRam, TWO_ME_SRAM_CAPACITY);
  ConfigureCardRam(0, TWO_ME_SRAM_CAPACITY);
  FEeprom := TSerialEEPROM93Cxx.Create(TWO_ME_EEPROM_SIZE, 16);
  FEeprom.Configure93LC46B;
  SetRegion(TNesRegion.NTSC);
  UpdateEepromPins;
end;

destructor TMapperMmc1TwoMe.Destroy;
begin
  FEeprom.Free;
  inherited;
end;

procedure TMapperMmc1TwoMe.ConfigureCardRam(RamSize, NvRamSize: UInt64);
begin
  if (RamSize > TWO_ME_SRAM_CAPACITY) or (NvRamSize > TWO_ME_SRAM_CAPACITY) or
    (RamSize + NvRamSize > TWO_ME_SRAM_CAPACITY) then
    raise ENesException.Create('Invalid MMC1 2ME SRAM size');
  var Total := Integer(RamSize + NvRamSize);
  if (Total <> 0) and ((Total and (Total - 1)) <> 0) then
    raise ENesException.Create('Invalid MMC1 2ME SRAM size');
  FCardRamSize := Total;
  FCardNvRamSize := Integer(NvRamSize);
end;

procedure TMapperMmc1TwoMe.SetRegion(Region: TNesRegion);
begin
  FEeprom.ConfigureTiming(CpuFrequency(Region), MICROWIRE_PROGRAM_US,
    MICROWIRE_PROGRAM_US, MICROWIRE_PROGRAM_US);
end;

procedure TMapperMmc1TwoMe.UpdateEepromPins;
begin
  FEeprom.RunUntil(FEepromCycle);
  FEeprom.Lines((FControl and 3) = 1, (FChrBank0 and 2) <> 0,
    ((FControl and $10) <> 0) and ((FChrBank0 and 1) <> 0));
end;

procedure TMapperMmc1TwoMe.ClockCpu;
begin
  Inc(FEepromCycle);
end;

procedure TMapperMmc1TwoMe.PowerOn;
begin
  if FEeprom <> nil then
  begin
    FEeprom.Reset;
    FEepromCycle := 0;
  end;
  inherited;
end;

procedure TMapperMmc1TwoMe.Reset;
begin
  inherited;
  if FEeprom <> nil then
    UpdateEepromPins;
end;

function TMapperMmc1TwoMe.CardRamOffset(Address: UInt16): Integer;
begin
  // CHR register 0 drives the two high SRAM address lines.
  Result := (((Integer(FChrBank0) and $0C) shl 11) or (Integer(Address) and $1FFF)) and (FCardRamSize - 1);
end;

function TMapperMmc1TwoMe.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address < $6000) or (Address >= $8000) then
    Exit(inherited CpuRead(Address, Value));
  if (FPrgBank and $10) <> 0 then
    Exit(False);
  if (FChrBank0 and $10) <> 0 then
  begin
    FEeprom.RunUntil(FEepromCycle);
    if not FEeprom.OutputDriven then
      Exit(False);
    Value := (FCpuOpenBus and $FE) or Byte(Ord(FEeprom.Output));
  end
  else
  begin
    if FCardRamSize = 0 then
      Exit(False);
    Value := FPrgRam[CardRamOffset(Address)];
  end;
  Result := True;
end;

function TMapperMmc1TwoMe.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    Result := (FCardRamSize <> 0) and (((FPrgBank or FChrBank0) and $10) = 0);
    if Result then
      FPrgRam[CardRamOffset(Address)] := Value;
    Exit;
  end;
  var OldControl := FControl;
  var OldChrBank := FChrBank0;
  Result := inherited CpuWrite(Address, Value);
  if (OldControl <> FControl) or (OldChrBank <> FChrBank0) then
    UpdateEepromPins;
end;

function TMapperMmc1TwoMe.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := False;
end;

function TMapperMmc1TwoMe.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := False;
end;

procedure TMapperMmc1TwoMe.SerializeState(State: TNesStateArchive);
begin
  inherited;
  if State.Version >= TWO_ME_STATE_VERSION then
  begin
    State.Field(FEepromCycle, SizeOf(FEepromCycle));
    if FEepromCycle < 0 then
      raise ENesException.Create('Invalid MMC1 2ME clock state');
    State.SharedFields(FEeprom.SerializeState);
  end
  else if State.Loading then
  begin
    // Older states only stored the first SRAM bank and standard MMC1 registers.
    FillChar(FPrgRam[$2000], Length(FPrgRam) - $2000, 0);
    FEeprom.Reset;
    FEepromCycle := 0;
    UpdateEepromPins;
  end;
end;

function TMapperMmc1TwoMe.GetSaveMemory: TByteArray;
begin
  Result := Copy(FPrgRam, FCardRamSize - FCardNvRamSize, FCardNvRamSize);
  SetLength(Result, FCardNvRamSize + TWO_ME_EEPROM_SIZE);
  var Cells := FEeprom.Battery;
  // The serial engine keeps little-endian cells internally. FCNS dumps use big-endian words.
  for var Offset := 0 to TWO_ME_EEPROM_SIZE - 1 do
    Result[FCardNvRamSize + Offset] := Cells[Offset xor 1];
end;

procedure TMapperMmc1TwoMe.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> FCardNvRamSize + TWO_ME_EEPROM_SIZE then
    raise ENesException.Create('Invalid MMC1 2ME save size');
  if FCardNvRamSize <> 0 then
    Move(Data[0], FPrgRam[FCardRamSize - FCardNvRamSize], FCardNvRamSize);
  var Cells: TArray<Byte>;
  SetLength(Cells, TWO_ME_EEPROM_SIZE);
  for var Offset := 0 to TWO_ME_EEPROM_SIZE - 1 do
    Cells[Offset xor 1] := Data[FCardNvRamSize + Offset];
  FEeprom.LoadBattery(Cells);
end;

end.

