unit NES.Mapper.ExtendedIrq;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, HW.PIC16C5x,
  HW.EEPROM93Cxx;

type
  TMapperExtendedIrq = class(TMapperBanked)
  private
    FBoard, FSubmapper, FCounter, FLatch, FControl, FSelect, FWorkBank: Integer;
    FRegs: array[0..15] of Integer;
    FEnabled, FPending, FToggle, FA12, FStarted: Boolean;
    FLowSince: UInt64;
    FNameRam: array[0..$7FF] of Byte;
    function RamOffset(Address: UInt16): Integer;
    procedure UpdateTaitoChr;
    procedure UpdateYoko;
    procedure UpdateSmb2j4In1;
    procedure UpdateP3117;
    procedure UpdateSb5013;
  public
    procedure ReadFormerIrq(out Counter: Integer; out Enabled, Pending: Boolean);
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer = 0);
    procedure SetP3117Dip(Bank: Byte);
    procedure SerializeState(State: TNesStateArchive); override;
    procedure PowerOn; override;
    procedure Reset; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function NameTableOffset(Address: UInt16): UInt16; override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function ConsumeDacWrite(out Value: UInt8): Boolean; override;
  end;

  TMapper3dBlock = class(TMapperBanked)
  private
    FPic: TPIC16C54;
    FAddress: Word;
    FClocksUntilStep: Integer;
    FIrq: Boolean;
    function ReadPicPort(Port: Integer): Byte;
    procedure WritePicPort(Port: Integer; Value: Byte);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; const Firmware: TArray<Byte>);
    destructor Destroy; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    procedure ClockCpuBus(Address: UInt16); override;
    function IrqPending: Boolean; override;
  end;

  TMapperBmc810344C = class(TMapperBanked)
  private
    FSaveChips: array[0..1] of TSerialEEPROM93Cxx;
    FGame: Byte;
    FPrgSwap, FIrqEnabled, FIrqPending: Boolean;
    FIrqReload, FIrqCounter: Word;
    procedure SelectGame(Game: Byte);
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    destructor Destroy; override;
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

  TMapperDbzBootleg = class(TMapperBanked)
  private
    FSubmapper, FIrqPeriod, FIrqCounter, FSaveRamSize: Integer;
    FPrgSwap, FIrqEnabled, FIrqPending: Boolean;
    FSaveChip: TSerialEEPROM93Cxx;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    destructor Destroy; override;
    procedure ConfigureSaveMemory(PrgRamSize, PrgNvRamSize: UInt64);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

implementation

constructor TMapperDbzBootleg.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FSubmapper := Submapper;
  FIrqPeriod := $400;
  if Submapper = 1 then
    FIrqPeriod := $800;
  ConfigureSaveMemory(0, 0);
  PowerOn;
end;

destructor TMapperDbzBootleg.Destroy;
begin
  FSaveChip.Free;
  inherited;
end;

procedure TMapperDbzBootleg.ConfigureSaveMemory(PrgRamSize, PrgNvRamSize: UInt64);
begin
  if (FSubmapper = 1) or ((FSubmapper = 0) and (PrgNvRamSize = $100)) then
  begin
    if FSaveChip = nil then
      FSaveChip := TSerialEEPROM93Cxx.Create($100, 16, True, True);
    FPrgRam := nil;
    FSaveRamSize := 0;
    Exit;
  end;

  if (PrgRamSize > $2000) or (PrgNvRamSize > $2000) or (PrgRamSize + PrgNvRamSize > $2000) then
    raise ENesException.Create('Unsupported mapper 318 SRAM size');
  FSaveChip.Free;
  FSaveChip := nil;
  // The battery-backed portion is followed by volatile RAM in the CPU window.
  FSaveRamSize := Integer(PrgNvRamSize);
  SetLength(FPrgRam, Integer(PrgNvRamSize + PrgRamSize));
end;

procedure TMapperDbzBootleg.PowerOn;
begin
  // TMapperBanked resets all mappings. On these boards only power-on does that.
  inherited Reset;
  FPrgSwap := False;
  if FHasChrRam then
    FillChar(FChrMemory[0], Length(FChrMemory), 0);
  if Length(FPrgRam) > FSaveRamSize then
    FillChar(FPrgRam[FSaveRamSize], Length(FPrgRam) - FSaveRamSize, 0);
  if (FSaveChip <> nil) and (FSubmapper <> 1) then
    FSaveChip.Reset;
  Reset;
end;

procedure TMapperDbzBootleg.Reset;
begin
  FIrqCounter := 0;
  FIrqEnabled := False;
  FIrqPending := False;
  if FSubmapper = 1 then
    FSaveChip.Reset;
end;

procedure TMapperDbzBootleg.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgSwap, SizeOf(FPrgSwap));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  if FSaveChip <> nil then
    State.SharedFields(FSaveChip.SerializeState);
end;

function TMapperDbzBootleg.GetSaveMemory: TByteArray;
begin
  if FSaveChip <> nil then
    Exit(TByteArray(FSaveChip.Battery));
  Result := Copy(FPrgRam, 0, FSaveRamSize);
end;

procedure TMapperDbzBootleg.SetSaveMemory(const Data: TByteArray);
begin
  if FSaveChip <> nil then
    FSaveChip.LoadBattery(TArray<Byte>(Data))
  else
  begin
    if Length(Data) <> FSaveRamSize then
      raise ENesException.Create('Invalid mapper 318 SRAM save size');
    if FSaveRamSize <> 0 then
      Move(Data[0], FPrgRam[0], FSaveRamSize);
  end;
end;

function TMapperDbzBootleg.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $8000 then
    Exit(inherited CpuRead(Address, Value));
  if Address < $6000 then
    Exit(False);
  if FSaveChip <> nil then
  begin
    Value := Ord(FSaveChip.Output);
    Exit(True);
  end;
  var Offset := Address - $6000;
  Result := Offset < Length(FPrgRam);
  if Result then
    Value := FPrgRam[Offset];
end;

function TMapperDbzBootleg.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  case Address of
    $6000..$7FFF:
      if FSaveChip <> nil then
        FSaveChip.Lines((Value and 4) <> 0, (Value and 2) <> 0, (Value and 1) <> 0)
      else
      begin
        var Offset := Address - $6000;
        Result := Offset < Length(FPrgRam);
        if Result then
          FPrgRam[Offset] := Value;
      end;
    $9000..$9FFF:
      if (Address and 2) = 0 then
        Mirror(Value)
      else if FPrgSwap <> ((Value and 2) <> 0) then
      begin
        FPrgSwap := not FPrgSwap;
        var Bank := FPrgBanks[0];
        FPrgBanks[0] := FPrgBanks[2];
        FPrgBanks[2] := Bank;
      end;
    $A000:
      Prg16(0, Value);
    $B000..$EFFF:
      begin
        var Slot := ((Address shr 12) - $B) * 2 + ((Address shr 1) and 1);
        var Shift := (Address and 1) * 4;
        var PreviousBank := ((FChrBanks[Slot] * $400) mod Length(FChrMemory)) div $400;
        Chr1(Slot, (PreviousBank and ($FF xor ($F shl Shift))) or ((Value and $F) shl Shift));
      end;
    $F000..$FFFF:
      begin
        // The CH-25 also decodes the IRQ registers with A4 set.
        if FSubmapper = 2 then
          Address := Address and $FFEF;
        case Address of
          $F004:
            FIrqPending := False;
          $F008:
            begin
              FIrqCounter := 0;
              FIrqEnabled := True;
              FIrqPending := False;
            end;
          $F00C:
            begin
              FIrqEnabled := False;
              FIrqPending := False;
            end;
        else
          Result := False;
        end;
      end;
  else
    Result := False;
  end;
end;

procedure TMapperDbzBootleg.ClockCpu;
begin
  if FIrqEnabled then
  begin
    Inc(FIrqCounter);
    if FIrqCounter = FIrqPeriod then
    begin
      FIrqCounter := 0;
      FIrqPending := True;
    end;
  end;
end;

function TMapperDbzBootleg.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

constructor TMapperBmc810344C.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FPrgRam := nil;
  for var Chip := Low(FSaveChips) to High(FSaveChips) do
    // 93C56 shifts eight address bits, including the leading don't-care bit.
    FSaveChips[Chip] := TSerialEEPROM93Cxx.Create($100, 16, True, True);
  PowerOn;
end;

destructor TMapperBmc810344C.Destroy;
begin
  for var Chip in FSaveChips do
    Chip.Free;
  inherited;
end;

procedure TMapperBmc810344C.SelectGame(Game: Byte);
begin
  FGame := Game;
  var FirstBank := Integer(Game) shl 5;
  Prg8(0, FirstBank);
  Prg8(1, FirstBank + 1);
  Prg8(2, FirstBank + $1E);
  Prg8(3, FirstBank + $1F);
end;

procedure TMapperBmc810344C.PowerOn;
begin
  FIrqEnabled := False;
  for var Chip in FSaveChips do
    Chip.Reset;
  Chr8(0);
  Reset;
end;

procedure TMapperBmc810344C.Reset;
begin
  FRamEnabled := False;
  FPrgSwap := False;
  FIrqPending := False;
  FIrqReload := 0;
  FIrqCounter := 0;
  SelectGame(0);
end;

procedure TMapperBmc810344C.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FGame, SizeOf(FGame));
  State.Field(FPrgSwap, SizeOf(FPrgSwap));
  State.Field(FIrqEnabled, SizeOf(FIrqEnabled));
  State.Field(FIrqPending, SizeOf(FIrqPending));
  State.Field(FIrqReload, SizeOf(FIrqReload));
  State.Field(FIrqCounter, SizeOf(FIrqCounter));
  for var Chip in FSaveChips do
    State.SharedFields(Chip.SerializeState);
end;

function TMapperBmc810344C.GetSaveMemory: TByteArray;
begin
  Result := TByteArray(FSaveChips[0].Battery + FSaveChips[1].Battery);
end;

procedure TMapperBmc810344C.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> $200 then
    raise ENesException.Create('Invalid BMC-810344-C EEPROM save size');
  for var Chip := Low(FSaveChips) to High(FSaveChips) do
    FSaveChips[Chip].LoadBattery(TArray<Byte>(Copy(Data, Chip * $100, $100)));
end;

function TMapperBmc810344C.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address >= $6000) and (Address < $8000) then
  begin
    Value := Ord(FSaveChips[FGame].Output);
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperBmc810344C.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  Result := True;
  case Address of
    $6000..$7FFF:
      FSaveChips[FGame].Lines((Value and 4) <> 0, (Value and 2) <> 0, (Value and 1) <> 0);
    $8000..$8FFF:
      Prg8(Ord(FPrgSwap) * 2, (Integer(FGame) shl 5) or (Value and $1F));
    $A000..$AFFF:
      Prg8(1, (Integer(FGame) shl 5) or (Value and $1F));
    $F000:
      if Value = $FF then
        SelectGame(1);
    $F400:
      begin
        FIrqCounter := FIrqReload;
        FIrqEnabled := (Value and 1) <> 0;
        FIrqPending := False;
      end;
    $F800:
      FIrqReload := (FIrqReload and $FF00) or Value;
    $FC00:
      FIrqReload := (FIrqReload and $00FF) or (Word(Value) shl 8);
  else
    // A1/A0 also select the two register bits exposed on A9/A8.
    var RegisterAddress := (Address and $FF00) or ((Address and 3) shl 8);
    case RegisterAddress of
      $9000, $9100:
        Exit(True);
      $9200, $9300:
        if FPrgSwap <> ((Value and 2) <> 0) then
        begin
          FPrgSwap := not FPrgSwap;
          var Bank := FPrgBanks[0];
          FPrgBanks[0] := FPrgBanks[2];
          FPrgBanks[2] := Bank;
        end;
      $B000..$B300, $C000..$C300, $D000..$D300, $E000..$E300:
        begin
          var Slot := ((RegisterAddress shr 12) - $B) * 2 + ((RegisterAddress shr 9) and 1);
          var Shift := ((RegisterAddress shr 8) and 1) * 4;
          var PreviousBank := ((FChrBanks[Slot] * $400) mod Length(FChrMemory)) div $400;
          var Bank := (PreviousBank and ($FF xor ($F shl Shift))) or ((Value and $F) shl Shift);
          Chr1(Slot, (Integer(FGame) shl 8) or Bank);
        end;
    else
      Result := False;
    end;
  end;
end;

procedure TMapperBmc810344C.ClockCpu;
begin
  if not FIrqEnabled then
    Exit;
  if FIrqCounter = 0 then
  begin
    FIrqPending := True;
    FIrqCounter := High(Word);
  end
  else
    Dec(FIrqCounter);
end;

function TMapperBmc810344C.IrqPending: Boolean;
begin
  Result := FIrqPending;
end;

destructor TMapper3dBlock.Destroy;
begin
  FPic.Free;
  inherited;
end;

constructor TMapper3dBlock.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; const Firmware: TArray<Byte>);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FPic := TPIC16C54.Create(Firmware);
  FPic.OnReadPort := ReadPicPort;
  FPic.OnWritePort := WritePicPort;
  PowerOn;
end;

procedure TMapper3dBlock.PowerOn;
begin
  Reset;
  FPic.Reset;
end;

procedure TMapper3dBlock.Reset;
begin
  inherited;
  FRamEnabled := False;
  FAddress := 0;
  FClocksUntilStep := 4;
  FIrq := False;
  FPic.Reset(False);
end;

function TMapper3dBlock.ReadPicPort(Port: Integer): Byte;
begin
  if Port = 0 then
    Exit(1 or ((FAddress and $40) shr 5) or ((FAddress and $20) shr 3) or
      ((FAddress and $10) shr 1));
  Result := ((FAddress and $1000) shr 12) or ((FAddress and $80) shr 6) or
    ((FAddress and $C00) shr 8) or ((FAddress and $200) shr 5) or
    ((FAddress and $100) shr 3) or ((FAddress and $6000) shr 7);
end;

procedure TMapper3dBlock.WritePicPort(Port: Integer; Value: Byte);
begin
  if Port = 0 then
    FIrq := (Value and 1) = 0;
end;

procedure TMapper3dBlock.ClockCpuBus(Address: UInt16);
begin
  FAddress := Address;
  Dec(FClocksUntilStep);
  if FClocksUntilStep = 0 then
    FClocksUntilStep := 4 * FPic.Step;
end;

function TMapper3dBlock.IrqPending: Boolean;
begin
  Result := FIrq;
end;

procedure TMapper3dBlock.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FClocksUntilStep, SizeOf(FClocksUntilStep));
  State.Field(FIrq, SizeOf(FIrq));
  if (FClocksUntilStep < 1) or (FClocksUntilStep > 8) then
    raise ENesException.Create('Invalid PIC16C54 instruction phase');
  FPic.SerializeState(State.Field);
end;

constructor TMapperExtendedIrq.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FSubmapper := Submapper;
  if (Board = MAPPER_FFE_F4XXX) or (Board = MAPPER_FFE_F8XXX) then
    if HasChrRam then
      SetLength(FChrMemory, $8000);
  if (Board = MAPPER_TAITO_X1017) or (Board = MAPPER_TAITO_X1017_552) then
    SetLength(FPrgRam, $1400);
  if (Board = MAPPER_TAITO_X1005) or (Board = MAPPER_TAITO_X1005_207) then
    SetLength(FPrgRam, $80);
  Reset;
end;

procedure TMapperExtendedIrq.ReadFormerIrq(out Counter: Integer; out Enabled, Pending: Boolean);
begin
  Counter := FCounter;
  Enabled := FEnabled;
  Pending := FPending;
end;

procedure TMapperExtendedIrq.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FWorkBank, SizeOf(FWorkBank));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FToggle, SizeOf(FToggle));
  State.Field(FA12, SizeOf(FA12));
  State.Field(FLowSince, SizeOf(FLowSince));
  State.Field(FNameRam, SizeOf(FNameRam));
end;

procedure TMapperExtendedIrq.SetP3117Dip(Bank: Byte);
begin
  if FBoard <> MAPPER_BIT_P3117 then
    Exit;
  FRegs[3] := Bank and $18;
  UpdateP3117;
end;

procedure TMapperExtendedIrq.UpdateP3117;
const
  SmbBanks: array[0..1, 0..7] of Byte = ((4, 3, 5, 3, 6, 3, 7, 3), (1, 1, 5, 1, 4, 1, 5, 1));
begin
  FWorkBank := -1;
  if FRegs[3] = 0 then
  begin
    var Swap := FRegs[2];
    FWorkBank := 2 * (1 - Swap);
    Prg8(0, 1 - Swap);
    Prg8(1, 0);
    Prg8(2, SmbBanks[Swap, FRegs[0]]);
    Prg8(3, 10 - 2 * Swap);
  end
  else
  begin
    Prg16(0, FRegs[3] or FRegs[1]);
    Prg16(1, FRegs[3] or 7);
  end;
  Mirror(Ord(FRegs[3] = $18));
end;

procedure TMapperExtendedIrq.PowerOn;
begin
  var P3117Dip := FRegs[3];
  FStarted := False;
  inherited;
  if FBoard = MAPPER_BIT_P3117 then
    SetP3117Dip(P3117Dip);
end;

procedure TMapperExtendedIrq.Reset;
begin
  if FStarted then
    case FBoard of
      MAPPER_BIT_P3117, MAPPER_IMPACT_SOFT_IM1:
        begin
          FCounter := 0;
          FEnabled := False;
          FPending := False;
          FA12 := False;
          Exit;
        end;
      MAPPER_DOUBLE_DRAGON_PIRATE, MAPPER_SMB2J_311:
        Exit;
      MAPPER_J2012_II:
        begin
          FA12 := False;
          Exit;
        end;
      MAPPER_BMC_SB5013, MAPPER_82112C, MAPPER_BJ56, MAPPER_YUNG_08, MAPPER_WHIRLWIND_LH53, MAPPER_CTC15:
        Exit;
      MAPPER_SMB2J_4IN1:
        begin
          FSelect := 0;
          FCounter := 0;
          FEnabled := False;
          FPending := False;
          UpdateSmb2j4In1;
          Exit;
        end;
    end;
  inherited;
  FStarted := True;
  FCounter := 0;
  FLatch := 0;
  FControl := 0;
  FSelect := 0;
  FWorkBank := -1;
  FEnabled := False;
  FPending := False;
  FToggle := False;
  FA12 := False;
  FLowSince := 0;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FRamEnabled := (FBoard = MAPPER_FFE_F4XXX) or (FBoard = MAPPER_FFE_F8XXX) or (FBoard = MAPPER_KAISER_KS202_56) or (FBoard = MAPPER_KAISER_KS202_142);
  case FBoard of
    MAPPER_BIT_P3117:
      begin
        FRegs[0] := 3;
        UpdateP3117;
      end;
    MAPPER_IMPACT_SOFT_IM1:
      Prg32(0);
    MAPPER_DOUBLE_DRAGON_PIRATE:
      begin
        for var Slot := 0 to 3 do
          Prg8(Slot, 15);
        for var Slot := 0 to 7 do
          Chr1(Slot, 0);
      end;
    MAPPER_J2012_II:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        for var Slot := 0 to 7 do
          Chr1(Slot, 0);
        Mirror(0);
      end;
    MAPPER_BMC_SB5013, MAPPER_82112C:
      begin
        for var Slot := 0 to 3 do
          FRegs[Slot] := $FC + Slot;
        for var Slot := 0 to 7 do
          FRegs[4 + Slot] := Slot;
        FRegs[13] := $40;
        Mirror(0);
        UpdateSb5013;
      end;
    MAPPER_BJ56:
      begin
        FRamEnabled := True;
        Prg32(-1);
        Mirror(0);
      end;
    MAPPER_WHIRLWIND_LH53:
      begin
        FWorkBank := 0;
        Prg32(3);
      end;
    MAPPER_YUNG_08:
      begin
        FWorkBank := 2;
        Prg8(0, 1);
        Prg8(1, 0);
        Prg8(2, 4);
        Prg8(3, 8);
        Mirror(0);
      end;
    MAPPER_SMB2J_4IN1:
      begin
        FWorkBank := 7;
        UpdateSmb2j4In1;
      end;
    MAPPER_CTC15:
      begin
        FRamEnabled := True;
        FSelect := 7;
        Prg16(0, 7);
        Prg16(1, 3);
        Mirror(1);
      end;
    MAPPER_FINE_STUDIO:
      begin
        for var Slot := 0 to 2 do
          Prg8(Slot, 0);
        Prg8(3, -1);
        for var Slot := 0 to 7 do
          Chr1(Slot, 0);
      end;
    MAPPER_YOKO:
      UpdateYoko;
    MAPPER_CITY_FIGHTER:
      begin
        Prg32(0);
        Prg8(2, 0);
        Mirror(0);
        for var i := 0 to 7 do
          Chr1(i, 0)
      end;
    MAPPER_FFE_F4XXX:
      begin
        Prg16(0, 0);
        Prg16(1, 7);
        FControl := 1
      end;
    MAPPER_FFE_F8XXX:
      Prg32(-1);
    MAPPER_IRQ_106:
      for var i := 0 to 3 do
        Prg8(i, -1);
    MAPPER_IRQ_117:
      Prg32(-1);
    MAPPER_IRQ_222:
      begin
        Prg8(2, -2);
        Prg8(3, -1)
      end;
    MAPPER_KAISER7017:
      begin
        Prg16(0, 0);
        Prg16(1, 2);
        Mirror(0)
      end;
    MAPPER_SMB2J:
      begin
        Prg32(0);
        FRamEnabled := False
      end;
    MAPPER_JY_35, MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142, MAPPER_TAITO_X1005, MAPPER_TAITO_X1017, MAPPER_TAITO_X1005_207, MAPPER_TAITO_X1017_552:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, 0);
        Prg8(3, -1)
      end;
    MAPPER_SMB2J_40:
      begin
        FWorkBank := 6;
        Prg8(0, 4);
        Prg8(1, 5);
        Prg8(2, 0);
        Prg8(3, 7)
      end;
    MAPPER_SMB2J_311:
      begin
        FWorkBank := 9;
        Prg32(0);
      end;
    MAPPER_SMB2J_43:
      begin
        FWorkBank := 2;
        Prg8(0, 1);
        Prg8(1, 0);
        Prg8(2, 0);
        Prg8(3, 9)
      end;
    MAPPER_SMB2J_50:
      begin
        FWorkBank := 15;
        Prg8(0, 8);
        Prg8(1, 9);
        Prg8(2, 0);
        Prg8(3, 11)
      end;
    MAPPER_IREM_H3001:
      begin
        Prg8(0, 0);
        Prg8(1, 1);
        Prg8(2, $FE);
        Prg8(3, -1)
      end;
  end;
end;

function TMapperExtendedIrq.RamOffset(Address: UInt16): Integer;
begin
  Result := -1;
  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
  begin
    if (Address >= $7F00) and (Address <= $7FFF) and (FRegs[8] = $A3) then
      Result := Address and $7F;
  end
  else if (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
  begin
    if (Address >= $6000) and (Address < $6800) and (FRegs[7] = $CA) then
      Result := Address - $6000;
    if (Address >= $6800) and (Address < $7000) and (FRegs[8] = $69) then
      Result := Address - $6000;
    if (Address >= $7000) and (Address < $7400) and (FRegs[9] = $84) then
      Result := Address - $6000;
  end;
end;

function TMapperExtendedIrq.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_WHIRLWIND_LH53) and (Address >= $B800) and (Address < $D800) then
  begin
    Value := FPrgRam[Address - $B800];
    Exit(True);
  end;
  if (FBoard = MAPPER_YUNG_08) and ((Address and $F1FF) = $4122) then
  begin
    Value := $8A or (FControl and $35);
    Exit(True);
  end;

  if (FBoard = MAPPER_YOKO) and (Address >= $5000) and (Address < $6000) then
  begin
    if Address < $5400 then
      Value := FCpuOpenBus and $FC
    else
      Value := FRegs[8 + (Address and 3)];
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7017) and (Address = $4030) then
  begin
    Value := Ord(FPending);
    FPending := False;
    Exit(True);
  end;

  if (FBoard = MAPPER_SMB2J) and (Address >= $5000) and (Address < $8000) then
  begin
    Value := FPrgRom[(Length(FPrgRom) - $3000 + Address - $5000) mod Length(FPrgRom)];
    Exit(True);
  end;

  if FBoard = MAPPER_SMB2J_311 then
  begin
    if (Address >= $4042) and (Address <= $4055) then
    begin
      Value := $FF;
      Exit(True);
    end;
    if (Address >= $5000) and (Address < $6000) then
    begin
      Value := FPrgRom[($11000 + (Address and $FFF)) mod Length(FPrgRom)];
      Exit(True);
    end;
  end;
  if (FBoard = MAPPER_SMB2J_43) and (Address >= $5000) and (Address < $6000) then
  begin
    Value := FPrgRom[($10000 + (Address and $FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (Address >= $6000) and (Address < $8000) and (FWorkBank >= 0) then
  begin
    Value := FPrgRom[(FWorkBank * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
    Exit(True);
  end;

  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) or (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
    if Address < $8000 then
    begin
      var Offset := RamOffset(Address);
      Result := Offset >= 0;
      if Result then
        Value := FPrgRam[Offset];
      Exit;
    end;

  Result := inherited CpuRead(Address, Value);
end;

procedure TMapperExtendedIrq.UpdateTaitoChr;
begin
  var Swap := (FRegs[6] and 2) shl 1;
  if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
    Swap := 0;
  for var i := 0 to 7 do
  begin
    var Bank: Integer;
    if i < 4 then
      if (FBoard = MAPPER_TAITO_X1005) or (FBoard = MAPPER_TAITO_X1005_207) then
        Bank := FRegs[i shr 1] + (i and 1)
      else
        Bank := (FRegs[i shr 1] and $FE) or (i and 1)
    else
      Bank := FRegs[i - 2];
    Chr1(i xor Swap, Bank);
  end;
end;

function TMapperExtendedIrq.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
const
  Map43: array[0..7] of Byte = (4, 3, 5, 3, 6, 3, 7, 3);
var
  Reg, Slot: Integer;
begin
  Result := True;
  case FBoard of
    MAPPER_BIT_P3117:
      begin
        if Address < $4020 then
          Exit(False);
        if Address >= $8000 then
          FRegs[1] := Value and 7;
        case Address and $71FF of
          $4022:
            FRegs[0] := Value and 7;
          $4120:
            FRegs[2] := Value and 1;
        else
          if (Address < $8000) and ((Address and $F1FF) <> $4122) then
            Exit(False);
        end;
        if (Address and $F1FF) = $4122 then
        begin
          FEnabled := (Value and 1) <> 0;
          FCounter := 0;
          FPending := False;
        end;
        UpdateP3117;
      end;
    MAPPER_IMPACT_SOFT_IM1:
      begin
        if Address < $8000 then
          Exit(False);
        Prg32(Address and $FF);
        Chr8(Address and $FF);
        if Address < $9000 then
          FPending := False;
      end;
    MAPPER_DOUBLE_DRAGON_PIRATE:
      begin
        if Address < $8000 then
          Exit(False);
        Slot := Address and 3;
        case Address and $70 of
          0:
            if Slot = 3 then
              Prg8(3, $C or (Value and 3))
            else
              Prg8(Slot, Value and $F);
          $10:
            Chr1(Slot, Value and $7F);
          $20:
            Chr1(4 + Slot, Value and $7F);
          $30:
            FEnabled := True;
          $40:
            begin
              FEnabled := False;
              FCounter := 0;
              FPending := False;
            end;
          $50:
            FRegs[Slot] := Value and 1;
        else
          Exit(False);
        end;
      end;
    MAPPER_J2012_II:
      begin
        if Address < $8000 then
          Exit(False);
        case Address and $C00C of
          $8004:
            FControl := Value and 3;
          $800C:
            FPending := True;
          $C004:
            FPending := False;
          $C008:
            FEnabled := True;
          $C00C:
            begin
              FEnabled := False;
              FCounter := 0;
              FPending := False;
            end;
        end;
        case Address shr 12 of
          $8:
            Prg8(0, Value);
          $9:
            FSelect := Value and 1;
          $A:
            Prg8(1, Value);
          $B..$E:
            begin
              Slot := ((Address shr 12) - $B) * 2 + ((Address shr 1) and 1);
              if (Address and 1) = 0 then
                FRegs[Slot] := (FRegs[Slot] and $F0) or (Value and $F)
              else
                FRegs[Slot] := (FRegs[Slot] and $F) or ((Value and $F) shl 4);
              Chr1(Slot, FRegs[Slot]);
            end;
        end;
        if FControl >= 2 then
          Mirror(FControl)
        else
          Mirror(FSelect);
      end;
    MAPPER_BMC_SB5013, MAPPER_82112C:
      begin
        Slot := Address and 3;
        case Address and $F003 of
          $8000..$8003:
            FRegs[Slot] := Value;
          $9000:
            FRegs[12] := (Value and $38) shl 1;
          $9001:
            FRegs[13] := Value;
          $9002:
            Mirror(Value and 3);
          $9003:
            FRegs[14] := (Value and 3) shl 7;
          $A000..$A003:
            FRegs[4 + Slot] := Value;
          $B000..$B003:
            FRegs[8 + Slot] := Value;
          $C000..$C003:
            begin
              case Slot of
                0:
                  begin
                    if (FControl and 2) <> 0 then
                      FToggle := True
                    else
                      FCounter := (FCounter and $FF00) or Value;
                    if (FControl and 4) <> 0 then
                      FEnabled := False;
                  end;
                1:
                  begin
                    FCounter := (FCounter and $FF) or (Value shl 8);
                    if (FControl and 4) <> 0 then
                      FEnabled := True;
                  end;
                2:
                  begin
                    FControl := Value and 6;
                    FEnabled := (Value and 1) <> 0;
                  end;
                3:
                  if (FControl and 4) = 0 then
                    FEnabled := (Value and 1) <> 0;
              end;
              FPending := False;
              Exit;
            end;
        else
          Exit(False);
        end;
        UpdateSb5013;
      end;
    MAPPER_BJ56:
      case Address and $E00F of
        $8000..$8007:
          Chr1(Address and 7, Value);
        $8008..$800B:
          Prg8(Address and 3, Value);
        $800D:
          FCounter := 0;
        $800F:
          FPending := False;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_WHIRLWIND_LH53:
      case Address of
        $B800..$D7FF:
          FPrgRam[Address - $B800] := Value;
        $E000..$EFFF:
          begin
            FEnabled := (Value and 2) <> 0;
            FCounter := 0;
            FPending := False;
          end;
        $F000..$FFFF:
          FWorkBank := Value and $F;
      else
        Exit(False);
      end;
    MAPPER_YUNG_08:
      case Address and $F1FF of
        $4022:
          if (Value and 1) <> 0 then
            Prg8(2, 3)
          else
            Prg8(2, 4 or ((Value shr 1) and 3));
        $4122:
          begin
            FControl := Value;
            FEnabled := (Value and 1) <> 0;
            if not FEnabled then
            begin
              FCounter := 0;
              FPending := False;
            end;
          end;
      else
        Exit(False);
      end;
    MAPPER_SMB2J_4IN1:
      begin
        if (Address and $E000) = $8000 then
        begin
          FControl := Value;
          UpdateSmb2j4In1;
        end
        else if (Address and $E060) = $4020 then
        begin
          if (Address and $100) = 0 then
          begin
            FSelect := Value and $F;
            UpdateSmb2j4In1;
          end
          else
          begin
            FEnabled := (Value and 1) <> 0;
            if not FEnabled then
            begin
              FCounter := 0;
              FPending := False;
            end;
          end;
        end
        else
          Exit(False);
      end;
    MAPPER_CTC15:
      case Address and $F800 of
        $4800:
          begin
            FSelect := ((Address shr 3) and 4) or ((Address shr 2) and 3);
            FEnabled := (Address and 4) = 0;
            if not FEnabled then
            begin
              FCounter := 0;
              FPending := False;
            end;
          end;
        $5000:
          Prg16(0, FSelect xor 5);
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_FINE_STUDIO:
      begin
        if Address < $8000 then
          Exit(False);
        Slot := Address and 3;
        case Address and $8073 of
          $8000..$8002:
            Prg8(Slot, Value);
          $8010..$8013:
            begin
              Chr1(Slot, Value);
              if FSubmapper = 1 then
                FRegs[Slot] := Value shr 7;
            end;
          $8020..$8023:
            Chr1(4 + Slot, Value);
          $8050..$8053:
            if FSubmapper <> 1 then
              FRegs[Slot] := Value and 1;
        end;
        case Address and $8070 of
          $8030:
            begin
              FCounter := 0;
              FEnabled := True;
              FPending := False;
            end;
          $8040:
            begin
              FEnabled := False;
              FPending := False;
            end;
        end;
      end;
    MAPPER_YOKO:
      if (Address >= $5400) and (Address < $6000) then
        FRegs[8 + (Address and 3)] := Value
      else if Address >= $8000 then
      begin
        case Address and $8C17 of
          $8000:
            FSelect := Value;
          $8400:
            FControl := Value;
          $8800:
            begin
              FCounter := (FCounter and $FF00) or Value;
              FPending := False
            end;
          $8801:
            begin
              FCounter := (FCounter and $FF) or (Value shl 8);
              FEnabled := (FControl and $80) <> 0
            end;
          $8C00..$8C02:
            FRegs[Address and 3] := Value;
          $8C10..$8C13:
            FRegs[3 + (Address and 3)] := Value;
        end;
        UpdateYoko;
      end
      else
        Exit(False);
    MAPPER_CITY_FIGHTER:
      if Address >= $8000 then
      begin
        case Address and $F00C of
          $9000:
            begin
              FSelect := Value and 12;
              Mirror(Value and 3)
            end;
          $9004, $9008, $900C:
            if (Address and $800) <> 0 then
              FRegs[15] := ((Value and 15) shl 3) or $100
            else
              FSelect := Value and 12;
          $C000, $C004, $C008, $C00C:
            FControl := Value and 1;
          $F000:
            FCounter := (FCounter and $1E0) or ((Value and 15) shl 1);
          $F004:
            FCounter := (FCounter and $1E) or ((Value and 15) shl 5);
          $F008:
            begin
              FEnabled := (Value and 2) <> 0;
              FPending := False
            end;
        else
          case Address and $F000 of
            $D000:
              Slot := 0;
            $A000:
              Slot := 2;
            $B000:
              Slot := 4;
            $E000:
              Slot := 6;
          else
            Exit(True);
          end;
          Slot := Slot + ((Address shr 3) and 1);
          var Shift := Address and 4;
          FRegs[Slot] := (FRegs[Slot] and ($FF xor (15 shl Shift))) or ((Value and 15) shl Shift);
          Chr1(Slot, FRegs[Slot]);
        end;
        Prg32(FSelect shr 2);
        if FControl = 0 then
          Prg8(2, FSelect);
      end
      else
        Exit(False);
    MAPPER_IRQ_106:
      if Address >= $8000 then
        case Address and 15 of
          0, 2:
            Chr1(Address and 15, Value and $FE);
          1, 3:
            Chr1(Address and 15, Value or 1);
          4..7:
            Chr1(Address and 15, Value);
          8, 11:
            Prg8((Address and 15) - 8, (Value and 15) or $10);
          9, 10:
            Prg8((Address and 15) - 8, Value and 31);
          13:
            begin
              FEnabled := False;
              FCounter := 0;
              FPending := False
            end;
          14:
            FCounter := (FCounter and $FF00) or Value;
          15:
            begin
              FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FEnabled := True
            end;
        end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_IRQ_117:
      case Address of
        $8000..$8003:
          Prg8(Address and 3, Value);
        $A000..$A007:
          Chr1(Address and 7, Value);
        $C001:
          FLatch := Value;
        $C002:
          FPending := False;
        $C003:
          begin
            FCounter := FLatch;
            FControl := 1
          end;
        $D000:
          Mirror(Value and 1);
        $E000:
          begin
            FEnabled := (Value and 1) <> 0;
            FPending := False
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_IRQ_222:
      case Address and $F003 of
        $8000:
          Prg8(0, Value);
        $9000:
          Mirror(Value and 1);
        $A000:
          Prg8(1, Value);
        $B000, $B002, $C000, $C002, $D000, $D002, $E000, $E002:
          Chr1(((Address shr 12) - 11) * 2 + ((Address shr 1) and 1), Value);
        $F000:
          begin
            FCounter := Value;
            FPending := False
          end;
      else
        Exit(inherited CpuWrite(Address, Value));
      end;
    MAPPER_KAISER7017:
      if (Address >= $4020) and (Address < $6000) then
      begin
        if (Address and $FF00) = $4A00 then
          FRegs[0] := ((Address shr 2) and 3) or ((Address shr 4) and 4)
        else if (Address and $FF00) = $5100 then
        begin
          Prg16(0, FRegs[0]);
          Mirror(FRegs[1])
        end
        else
          case Address of
            $4020:
              begin
                FCounter := (FCounter and $FF00) or Value;
                FPending := False
              end;
            $4021:
              begin
                FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
                FEnabled := True;
                FPending := False
              end;
            $4025:
              FRegs[1] := (Value shr 3) and 1;
          end;
      end
      else
        Exit(False);
    MAPPER_SMB2J:
      case Address of
        $4022:
          if Length(FPrgRom) >= $10000 then
          begin
            Prg16(0, Value and 1);
            Prg16(1, (Value and 1) + 1)
          end;
        $4122:
          begin
            FEnabled := (Value and 3) <> 0;
            FCounter := 0;
            FPending := False
          end;
      else
        Exit(False);
      end;
    MAPPER_FFE_F4XXX, MAPPER_FFE_F8XXX:
      begin
        case Address of
          $42FE:
            begin
              FControl := Ord((Value and $80) = 0);
              Mirror(2 + ((Value shr 4) and 1))
            end;
          $42FF:
            Mirror((Value shr 4) and 1);
          $4501:
            begin
              FEnabled := False;
              FPending := False
            end;
          $4502:
            begin
              FCounter := (FCounter and $FF00) or Value;
              FPending := False
            end;
          $4503:
            begin
              FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FEnabled := True;
              FPending := False
            end;
        else
          if (FBoard = MAPPER_FFE_F4XXX) and (Address >= $8000) then
          begin
            if FHasChrRam or (FControl <> 0) then
            begin
              Prg16(0, Value shr 2);
              Value := Value and 3
            end;
            Chr8(Value);
          end
          else if (FBoard = MAPPER_FFE_F8XXX) and (Address >= $4504) and (Address <= $4507) then
            Prg8(Address - $4504, Value)
          else if (FBoard = MAPPER_FFE_F8XXX) and (Address >= $4510) and (Address <= $4517) then
            Chr1(Address - $4510, Value)
          else
            Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_JY_35:
      begin
        case Address and $F007 of
          $8000..$8003:
            Prg8(Address and 3, Value);
          $9000..$9007:
            Chr1(Address and 7, Value);
          $C002:
            begin
              FEnabled := False;
              FPending := False
            end;
          $C003:
            FEnabled := True;
          $C005:
            FCounter := Value;
          $D001:
            Mirror(Value and 1);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_SMB2J_40:
      if Address >= $8000 then
        case Address and $E000 of
          $8000:
            begin
              FCounter := 0;
              FPending := False
            end;
          $A000:
            FCounter := 4096;
          $E000:
            Prg8(2, Value);
        end
      else
        Exit(False);
    MAPPER_SMB2J_311:
      case Address of
        $4022:
          Prg32(Value and 1);
        $4122:
          begin
            FEnabled := (Value and 1) <> 0;
            FCounter := 0;
            FPending := False;
          end;
      else
        Exit(False);
      end;
    MAPPER_SMB2J_43:
      begin
        case Address and $F1FF of
          $4022:
            Prg8(2, Map43[Value and 7]);
          $4120:
            begin
              if (Value and 1) <> 0 then
              begin
                FWorkBank := 0;
                Prg8(3, 8)
              end
              else
              begin
                FWorkBank := 2;
                Prg8(3, 9)
              end
            end;
          $4122, $8122:
            begin
              FEnabled := (Value and 1) <> 0;
              FCounter := 0;
              FPending := False
            end;
        else
          Exit(False);
        end;
      end;
    MAPPER_SMB2J_50:
      if (Address >= $4020) and (Address < $6000) then
      begin
        case Address and $4120 of
          $4020:
            Prg8(2, (Value and 8) or ((Value and 1) shl 2) or ((Value and 6) shr 1));
          $4120:
            begin
              FEnabled := (Value and 1) <> 0;
              if not FEnabled then
              begin
                FCounter := 0;
                FPending := False
              end
            end;
        end;
      end
      else
        Exit(False);
    MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142:
      if Address >= $8000 then
      begin
        Reg := Address shr 12;
        case Reg of
          8..11:
            begin
              Slot := (Reg - 8) * 4;
              FLatch := (FLatch and ($FFFF xor ($F shl Slot))) or ((Value and 15) shl Slot)
            end;
          12:
            begin
              FEnabled := (Value and 2) <> 0;
              if FEnabled then
                FCounter := FLatch;
              FPending := False
            end;
          13:
            FPending := False;
          14:
            FSelect := (Value and 7) - 1;
          15:
            begin
              if (FSelect >= 0) and (FSelect <= 3) then
                FRegs[FSelect] := (FRegs[FSelect] and $10) or (Value and 15);
              if FSelect = 4 then
                FControl := Value and 4;
              if FBoard = MAPPER_KAISER_KS202_56 then
                case Address and $FC00 of
                  $F000:
                    FRegs[Address and 3] := (Value and $10) or (FRegs[Address and 3] and 15);
                  $F800:
                    Mirror(1 - (Value and 1));
                  $FC00:
                    Chr1(Address and 7, Value);
                end;
              FWorkBank := -1;
              if FControl <> 0 then
                FWorkBank := FRegs[3];
              for Slot := 0 to 2 do
                Prg8(Slot, FRegs[Slot]);
            end;
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_IREM_H3001:
      begin
        case Address of
          $8000:
            Prg8(0, Value);
          $A000:
            Prg8(1, Value);
          $C000:
            Prg8(2, Value);
          $9001:
            Mirror(Value shr 7);
          $9003:
            begin
              FEnabled := (Value and $80) <> 0;
              FPending := False
            end;
          $9004:
            begin
              FCounter := FLatch;
              FPending := False
            end;
          $9005:
            FLatch := (FLatch and $FF) or (Integer(Value) shl 8);
          $9006:
            FLatch := (FLatch and $FF00) or Value;
          $B000..$B007:
            Chr1(Address and 7, Value);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_SUNSOFT3:
      begin
        case Address and $F800 of
          $8800, $9800, $A800, $B800:
            Chr2((Address shr 12) - 8, Value);
          $C800:
            begin
              if FToggle then
                FCounter := (FCounter and $FF00) or Value
              else
                FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
              FToggle := not FToggle
            end;
          $D800:
            begin
              FEnabled := (Value and $10) <> 0;
              FToggle := False;
              FPending := False
            end;
          $E800:
            Mirror(Value);
          $F800:
            Prg16(0, Value);
        else
          Exit(inherited CpuWrite(Address, Value));
        end;
      end;
    MAPPER_TAITO_X1005, MAPPER_TAITO_X1017, MAPPER_TAITO_X1005_207, MAPPER_TAITO_X1017_552:
      begin
        if (Address >= $7EF0) and (Address <= $7EFF) then
        begin
          Reg := Address and 15;
          if Reg < 6 then
          begin
            FRegs[Reg] := Value;
            UpdateTaitoChr
          end
          else if (FBoard = MAPPER_TAITO_X1017) or (FBoard = MAPPER_TAITO_X1017_552) then
            case Reg of
              6:
                begin
                  FRegs[6] := Value;
                  Mirror(1 - (Value and 1));
                  UpdateTaitoChr
                end;
              7..9:
                FRegs[Reg] := Value;
              10..12:
                begin
                  Slot := Value shr 2;
                  if FBoard = MAPPER_TAITO_X1017_552 then
                  begin
                    Slot := 0;
                    for var i := 0 to 5 do
                      Slot := Slot or (((Value shr i) and 1) shl (5 - i))
                  end;
                  Prg8(Reg - 10, Slot);
                end;
            end
          else
            case Reg of
              6, 7:
                if FBoard = MAPPER_TAITO_X1005 then
                  Mirror(1 - (Value and 1));
              8, 9:
                FRegs[8] := Value;
              10..15:
                Prg8((Reg - 10) shr 1, Value);
            end;
          Exit;
        end;
        Slot := RamOffset(Address);
        Result := Slot >= 0;
        if Result then
          FPrgRam[Slot] := Value;
      end;
  else
    Result := inherited CpuWrite(Address, Value);
  end;
end;

function TMapperExtendedIrq.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TAITO_X1005_207) and (Address >= $2000) and (Address < $3F00) then
  begin
    Value := FNameRam[((FRegs[(Address shr 11) and 1] shr 7) * $400) + (Address and $3FF)];
    Exit(True)
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedIrq.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_TAITO_X1005_207) and (Address >= $2000) and (Address < $3F00) then
  begin
    FNameRam[((FRegs[(Address shr 11) and 1] shr 7) * $400) + (Address and $3FF)] := Value;
    Exit(True)
  end;

  Result := inherited PpuWrite(Address, Value);
end;

function TMapperExtendedIrq.NameTableOffset(Address: UInt16): UInt16;
begin
  if (FBoard = MAPPER_FINE_STUDIO) or (FBoard = MAPPER_DOUBLE_DRAGON_PIRATE) then
    Exit((FRegs[(Address shr 10) and 3] shl 10) or (Address and $3FF));
  Result := inherited NameTableOffset(Address);
end;

procedure TMapperExtendedIrq.ClockCpu;
begin
  if FBoard = MAPPER_BIT_P3117 then
  begin
    if FEnabled then
    begin
      FCounter := (FCounter + 1) and $FFF;
      if FCounter = 0 then
        FPending := True;
    end;
    Exit;
  end;
  case FBoard of
    MAPPER_BMC_SB5013, MAPPER_82112C:
      begin
        if FRegs[15] > 0 then
          Dec(FRegs[15]);
        if FEnabled and ((FControl and 2) = 0) and (FCounter > 0) then
        begin
          Dec(FCounter);
          if FCounter = 0 then
            FPending := True;
        end;
        Exit;
      end;
    MAPPER_BJ56:
      begin
        FCounter := (FCounter + 1) and $1FFF;
        if (FCounter and $1000) <> 0 then
          FPending := True;
        Exit;
      end;
  end;
  if FBoard = MAPPER_FINE_STUDIO then
  begin
    var IrqBit := $400;
    if FSubmapper = 1 then
      IrqBit := $1000;
    FCounter := (FCounter + 1) and ((IrqBit shl 1) - 1);
    FPending := FEnabled and ((FCounter and IrqBit) <> 0);
    Exit;
  end;
  if FBoard = MAPPER_SMB2J_40 then
  begin
    if FCounter > 0 then
    begin
      Dec(FCounter);
      if FCounter = 0 then
        FPending := True
    end;
    Exit
  end;

  if not FEnabled then
    Exit;

  case FBoard of
    MAPPER_DOUBLE_DRAGON_PIRATE:
      begin
        FCounter := (FCounter - 1) and $FF;
        if FCounter = 0 then
          FPending := True;
      end;
    MAPPER_WHIRLWIND_LH53:
      if FCounter < 7560 then
      begin
        Inc(FCounter);
        if FCounter = 7560 then
          FPending := True;
      end;
    MAPPER_SMB2J_4IN1:
      begin
        FCounter := (FCounter + 1) and $1FFF;
        FPending := (FCounter and $1000) <> 0;
      end;
    MAPPER_YUNG_08:
      begin
        FCounter := (FCounter + 1) and $FFF;
        if FCounter = 0 then
          FPending := True;
      end;
    MAPPER_CTC15:
      begin
        FCounter := (FCounter + 1) mod (640 * 64);
        FPending := ((FCounter div 640) and 37) = 37;
      end;
    MAPPER_YOKO:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
        begin
          FCounter := $FFFF;
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_CITY_FIGHTER:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
          FPending := True
      end;
    MAPPER_FFE_F4XXX, MAPPER_FFE_F8XXX, MAPPER_IRQ_106:
      begin
        FCounter := (FCounter + 1) and $FFFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_KAISER7017:
      if FCounter > 0 then
      begin
        Dec(FCounter);
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SMB2J:
      begin
        FCounter := (FCounter + 1) and $FFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SMB2J_311:
      if FCounter = 4096 then
      begin
        FPending := True;
        FEnabled := False;
      end
      else
        Inc(FCounter);
    MAPPER_SMB2J_43, MAPPER_SMB2J_50:
      begin
        Inc(FCounter);
        if FCounter = 4096 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_KAISER_KS202_56, MAPPER_KAISER_KS202_142:
      begin
        FCounter := (FCounter + 1) and $FFFF;
        if FCounter = $FFFF then
        begin
          FCounter := FLatch;
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_IREM_H3001:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = 0 then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
    MAPPER_SUNSOFT3:
      begin
        FCounter := (FCounter - 1) and $FFFF;
        if FCounter = $FFFF then
        begin
          FPending := True;
          FEnabled := False
        end
      end;
  end;
end;

procedure TMapperExtendedIrq.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard = MAPPER_IMPACT_SOFT_IM1 then
  begin
    var A12 := (Address and $1000) <> 0;
    if FA12 and not A12 then
      FPending := True;
    FA12 := A12;
    Exit;
  end;
  if FBoard = MAPPER_J2012_II then
  begin
    // Clock the board's counter on falling edges of PPU A13.
    var A13 := (Address and $2000) <> 0;
    if FA12 and not A13 and FEnabled then
    begin
      Inc(FCounter);
      if FCounter = 84 then
      begin
        FCounter := 0;
        FPending := True;
      end;
    end;
    FA12 := A13;
    Exit;
  end;
  if (FBoard = MAPPER_BMC_SB5013) or (FBoard = MAPPER_82112C) then
  begin
    if (Address and $1000) = 0 then
      Exit;
    if (FRegs[15] = 0) and ((FControl and 2) <> 0) then
    begin
      if FToggle or ((FCounter and $FF) = 0) then
        FCounter := (FCounter and $FF00) or (FCounter shr 8)
      else
        Dec(FCounter);
      FToggle := False;
      if FEnabled and ((FCounter and $FF) = 0) then
        FPending := True;
    end;
    FRegs[15] := 5;
    Exit;
  end;
  if not (FBoard in [MAPPER_JY_35, MAPPER_IRQ_117, MAPPER_IRQ_222]) then
    Exit;

  if (Address and $1000) = 0 then
  begin
    if FA12 then
      FLowSince := PpuCycle;
    FA12 := False
  end
  else if not FA12 then
  begin
    FA12 := True;
    if PpuCycle >= FLowSince + 8 then
      case FBoard of
        MAPPER_JY_35:
          if FEnabled then
          begin
            FCounter := (FCounter - 1) and $FF;
            if FCounter = 0 then
            begin
              FPending := True;
              FEnabled := False
            end
          end;
        MAPPER_IRQ_117:
          if FEnabled and (FControl <> 0) and (FCounter <> 0) then
          begin
            Dec(FCounter);
            if FCounter = 0 then
            begin
              FPending := True;
              FControl := 0
            end
          end;
        MAPPER_IRQ_222:
          if FCounter <> 0 then
          begin
            Inc(FCounter);
            if FCounter >= 240 then
            begin
              FPending := True;
              FCounter := 0
            end
          end;
      end;
  end;
end;

procedure TMapperExtendedIrq.UpdateSb5013;
const
  PrgMasks: array[0..3] of Byte = ($3F, $1F, $2F, $0F);
  Chr2Registers: array[0..3] of Byte = (4, 5, 10, 11);
begin
  var PrgMask := PrgMasks[FRegs[13] and 3];
  var PrgBase := FRegs[12];
  FWorkBank := (FRegs[3] and PrgMask) or PrgBase;
  for var Slot := 0 to 2 do
    Prg8(Slot, (FRegs[Slot] and PrgMask) or PrgBase);
  Prg8(3, PrgMask or PrgBase);
  if FBoard = MAPPER_82112C then
    for var Slot := 0 to 3 do
      Chr2(Slot, FRegs[Chr2Registers[Slot]])
  else if FHasChrRam then
    Chr8(0)
  else
  begin
    var ChrMask := $7F or ((FRegs[13] and $40) shl 1);
    for var Slot := 0 to 7 do
      Chr1(Slot, (FRegs[4 + Slot] and ChrMask) or FRegs[14]);
  end;
end;

function TMapperExtendedIrq.IrqPending: Boolean;
begin
  Result := FPending;
end;

procedure TMapperExtendedIrq.UpdateSmb2j4In1;
begin
  Chr8((FControl shr 1) and 3);
  Mirror((FControl shr 2) and 1);
  if (FControl and 8) = 0 then
  begin
    Prg8(0, 0);
    Prg8(1, 1);
    Prg8(2, (FSelect and 8) or ((FSelect and 1) shl 2) or ((FSelect shr 1) and 3));
    Prg8(3, 3);
    Exit;
  end;

  var Bank := 4 or ((FControl shr 6) and 2) or ((FControl shr 5) and 1);
  if (FControl and $80) <> 0 then
    Prg32(Bank shr 1)
  else if (FControl and $40) <> 0 then
  begin
    Prg16(0, Bank);
    Prg16(1, Bank);
  end
  else
    for var Slot := 0 to 3 do
      Prg8(Slot, Bank shl 1);
end;

procedure TMapperExtendedIrq.UpdateYoko;
begin
  Mirror(FControl and 1);
  for var i := 0 to 3 do
    Chr2(i, FRegs[3 + i]);
  if (FControl and $10) <> 0 then
  begin
    var Outer := (FSelect and 8) shl 1;
    for var i := 0 to 2 do
      Prg8(i, Outer or (FRegs[i] and 15));
    Prg8(3, Outer or 15)
  end
  else if (FControl and 8) <> 0 then
    Prg32(FSelect shr 1)
  else
  begin
    Prg16(0, FSelect);
    Prg16(1, -1)
  end;
end;

function TMapperExtendedIrq.ConsumeDacWrite(out Value: UInt8): Boolean;
begin
  Result := (FBoard = MAPPER_CITY_FIGHTER) and ((FRegs[15] and $100) <> 0);
  Value := FRegs[15] and $FF;
  FRegs[15] := 0
end;

end.

