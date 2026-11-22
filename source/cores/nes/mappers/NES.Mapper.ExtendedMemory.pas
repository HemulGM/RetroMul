unit NES.Mapper.ExtendedMemory;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked, NES.Mapper.Mmc3,
  NES.Controller, NES.FamicomDataRecorder;

type
  TMapperPec = class(TMapperBanked)
  private
    FBoard: Integer;
    FLargePec: Boolean;
    FMode, FPrgControl, FProtectionIndex, FStatus: Byte;
    FNameOffset: Word;
    FLastA13: Boolean;
    FTape: TFamicomDataRecorder;
    procedure UpdateBanks;
    function UsesPpuAddressLatch: Boolean;
    function ReadRegister(Address: UInt16; out Value: UInt8; Inspect: Boolean): Boolean;
    function ReadPattern(Address: UInt16; out Value: UInt8): Boolean;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
    procedure ConnectDataRecorder(Recorder: TFamicomDataRecorder);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; override;
  end;

  TMapperAsderPc95 = class(TMapperBanked)
  private
    FPrgRegisters: array[0..3] of Byte;
    FChrRegisters: array[0..7] of Byte;
    FKeyboardRow: Byte;
    FKeyboard: TSuborKeyboard;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure ConnectKeyboard(Keyboard: TSuborKeyboard);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperLittleKimPc95 = class(TMapperMmc3)
  private
    FPrgHigh: array[0..1] of Byte;
    FKeyboardRow: Byte;
    FKeyboard: TSuborKeyboard;
    procedure UpdatePrgOffsets;
    procedure LatchPrgHigh(Address: Word; Value: Byte);
    function ReadKeyboard: Byte;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure ConnectKeyboard(Keyboard: TSuborKeyboard);
    procedure PowerOn; override;
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  TMapperDancingExpert = class(TMapperBanked)
  private
    FChrLow, FChrHigh: Byte;
    FPanel: TController;
  public
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure ConnectPanel(Panel: TController);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

  T93C66Phase = (Start, Command, ReadData, WriteData, Done);

  TMapperExtendedMemory = class(TMapperBanked)
  private
    FBoard, FSelect, FMode, FCounter: Integer;
    FRegs: array[0..15] of Integer;
    FPending, FLocked: Boolean;
    FNameRam: array[0..$7FF] of Byte;
    FHasEeprom, FEepromClock, FEepromOutput, FEepromWriteEnabled: Boolean;
    FEeprom: array[0..511] of Byte;
    FEepromPhase: T93C66Phase;
    FEepromBits, FEepromShift, FEepromAddress, FEepromOpcode: Integer;
    procedure ResetEepromBus;
    procedure WriteEeprom(Value: Byte);
    procedure UpdateOuter;
    procedure UpdateWaixing558;
    function SmallPrgRead(Address: UInt16; out Value: Byte): Boolean;
  public
    constructor Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Eeprom: Boolean = False);
    procedure Configure93C66(PrgRamSize: Integer);
    procedure ConfigureWaixing558Ram(Size: UInt64);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); override;
    procedure ClockCpu; override;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); override;
    function IrqPending: Boolean; override;
    function GetSaveMemory: TByteArray; override;
    procedure SetSaveMemory(const Data: TByteArray); override;
  end;

  TMapperBlazeProFds = class(TMapperBanked)
  private
    FMode, FBank, FDisk, FDiskControl: Byte;
    FDiskOffset, FDataPhase: Integer;
    FDiskIdle, FChangeDelay, FChangeStep: Integer;
    FInserted, FDataPending: Boolean;
    FTimerLatch, FTimerCounter: Word;
    FTimerEnabled, FTimerRepeat, FTimerPending: Boolean;
    procedure MapBanks;
    procedure PollDiskChange;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure SerializeState(State: TNesStateArchive); override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
  end;

implementation

uses
  NES.Consts;

constructor TMapperPec.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  FLargePec := (Board = MAPPER_PEC586) and ((Submapper = 2) or
    ((Submapper = 0) and (Length(FPrgRom) >= $80000)));
  PowerOn;
end;

procedure TMapperPec.ConnectDataRecorder(Recorder: TFamicomDataRecorder);
begin
  FTape := Recorder;
end;

procedure TMapperPec.PowerOn;
begin
  FMode := 0;
  FPrgControl := 0;
  FProtectionIndex := 0;
  FStatus := 0;
  FNameOffset := 0;
  FLastA13 := False;
  if ((FBoard = MAPPER_PEC586) and not FLargePec) or (FBoard = MAPPER_SONIC_REC9388) then
    FMode := $0E;
  Reset;
end;

procedure TMapperPec.Reset;
begin
  inherited;
  if FBoard = MAPPER_GOLDEN_KEY then
  begin
    FMode := 0;
    FProtectionIndex := 0;
  end;
  if UsesPpuAddressLatch then
  begin
    FNameOffset := 0;
    FLastA13 := False;
  end;
  UpdateBanks;
end;

procedure TMapperPec.UpdateBanks;
begin
  case FBoard of
    MAPPER_PEC586:
      if FLargePec then
      begin
        if (FMode and $10) <> 0 then
          Prg32(((FPrgControl shl 1) and $10) or (FMode and 7))
        else if (FMode and $40) <> 0 then
          Prg8(0, $20 or ((FMode shr 1) and $10) or (FMode and $0F));
        Mirror(Ord((FMode and $78) = $58));
      end
      else
      begin
        // The small board selects paired 16 KiB banks using a PLA.
        if (FMode and $10) <> 0 then
        begin
          if (FMode and 1) <> 0 then
          begin
            Prg16(0, 6);
            Prg16(1, 7);
          end
          else
          begin
            Prg16(0, 4);
            Prg16(1, 5 + ((FMode shr 4) and 2));
          end;
        end
        else
        begin
          Prg16(0, FMode and 3);
          var FixedBank := 3 - ((FMode shr 6) and 1);
          if (FMode and $7C) = $6C then
            FixedBank := 0;
          Prg16(1, FixedBank);
        end;
      end;
    MAPPER_MEGASONIC_PEC586:
      begin
        var Bank := (FMode and $0F) or ((FPrgControl and 1) shl 4);
        if (FMode and $70) = $50 then
        begin
          Prg16(0, Bank + 4);
          Prg16(1, Bank + 4);
        end
        else
        begin
          Prg16(0, Bank and 3);
          Prg16(1, 3);
        end;
        Mirror(1 - ((FPrgControl shr 1) and 1));
      end;
    MAPPER_SONIC_REC9388:
      begin
        Prg32(((FMode shr 5) and 3) or (FMode and 1));
        Mirror(1 - ((FPrgControl shr 1) and 1));
      end;
    MAPPER_GOLDEN_KEY:
      Prg32((FMode and 7) or ((FMode shr 1) and 8));
  end;
end;

function TMapperPec.ReadRegister(Address: UInt16; out Value: UInt8; Inspect: Boolean): Boolean;
const
  Protection: array[0..15] of Byte = ($00, $09, $00, $00, $00, $00, $00, $20, $04, $00, $00, $00, $00, $00, $00, $02);
begin
  Result := (Address and $F000) = $5000;
  if not Result then
    Exit;
  Value := FCpuOpenBus;
  var RegisterIndex := (Address shr 8) and 7;
  if FBoard = MAPPER_SONIC_REC9388 then
  begin
    case RegisterIndex of
      3:
        begin
          if not Inspect then
            FStatus := FStatus xor 4;
          Value := FStatus;
        end;
      5:
        Value := (FCpuOpenBus and $D8) or Protection[FProtectionIndex shr 4];
    end;
  end
  else if FLargePec or (FBoard = MAPPER_GOLDEN_KEY) then
  begin
    case RegisterIndex of
      3:
        begin
          Value := Value and $FB;
          if FTape <> nil then
            Value := Value or (FTape.Read(not Inspect) shl 1);
        end;
      5:
        Value := Protection[FProtectionIndex shr 4];
    end;
  end
  else if RegisterIndex = 5 then
  begin
    Value := 0;
    if FTape <> nil then
      Value := FTape.Read(not Inspect) shl 1;
  end;
end;

function TMapperPec.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if FLargePec and (Address >= $8000) and ((FMode and $10) = 0) and
    ((Address >= $A000) or ((FMode and $40) = 0)) then
  begin
    // The fixed menu window receives 1 KiB fragments from the ends of 8 KiB banks.
    var WindowOffset := Address and $7FFF;
    var RomOffset := $41C00 or ((WindowOffset and $7C00) shl 3) or (WindowOffset and $3FF);
    Value := FPrgRom[RomOffset mod Length(FPrgRom)];
    Exit(True);
  end;
  Result := ReadRegister(Address, Value, False) or inherited CpuRead(Address, Value);
end;

function TMapperPec.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := ReadRegister(Address, Value, True);
  if not Result then
    Result := CpuRead(Address, Value);
end;

function TMapperPec.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address and $F000) <> $5000 then
    Exit(inherited CpuWrite(Address, Value));

  var RegisterIndex := (Address shr 8) and $0F;
  if FBoard <> MAPPER_MEGASONIC_PEC586 then
    RegisterIndex := RegisterIndex and 7;
  case RegisterIndex of
    0:
      begin
        FMode := Value;
        UpdateBanks;
      end;
    1:
      begin
        if FLargePec or (FBoard = MAPPER_MEGASONIC_PEC586) or (FBoard = MAPPER_SONIC_REC9388) then
          FPrgControl := Value;
        if (FTape <> nil) and ((FBoard = MAPPER_PEC586) or (FBoard = MAPPER_MEGASONIC_PEC586)) then
        begin
          var SignalBit := 0;
          if FLargePec then
            SignalBit := 2;
          FTape.Write(4 or ((Value shr SignalBit) and 1));
        end;
        // The upper PEC latch is sampled at the next write to the mode register.
        if not FLargePec then
          UpdateBanks;
      end;
    4:
      FProtectionIndex := Value;
  end;
  Result := True;
end;

function TMapperPec.UsesPpuAddressLatch: Boolean;
begin
  Result := FLargePec or (FBoard = MAPPER_GOLDEN_KEY);
end;

procedure TMapperPec.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if UsesPpuAddressLatch then
  begin
    var A13 := (Address and $2000) <> 0;
    if A13 and not FLastA13 then
      FNameOffset := Address and $3FF;
    FLastA13 := A13;
  end;
end;

function TMapperPec.ReadPattern(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (Address < $2000) and ((FMode and $80) <> 0) then
    Address := (Address and $0FF7) or ((FNameOffset and $200) shl 3) or ((FNameOffset and 1) shl 3);
  Result := inherited PpuRead(Address, Value);
end;

function TMapperPec.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if not UsesPpuAddressLatch and (Address >= $2000) and (Address < $3F00) and
    ((Address and $3FF) < $3C0) then
    FNameOffset := Address and $3FF;
  Result := ReadPattern(Address, Value);
end;

function TMapperPec.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := ReadPattern(Address, Value);
end;

procedure TMapperPec.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FMode, SizeOf(FMode));
  State.Field(FPrgControl, SizeOf(FPrgControl));
  State.Field(FProtectionIndex, SizeOf(FProtectionIndex));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FNameOffset, SizeOf(FNameOffset));
  State.Field(FLastA13, SizeOf(FLastA13));
end;

constructor TMapperLittleKimPc95.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FIrqRequiresCounterTransition := True;
  PowerOn;
end;

procedure TMapperLittleKimPc95.ConnectKeyboard(Keyboard: TSuborKeyboard);
begin
  FKeyboard := Keyboard;
end;

procedure TMapperLittleKimPc95.PowerOn;
begin
  FPrgHigh[0] := $40;
  FPrgHigh[1] := $40;
  FKeyboardRow := 0;
  inherited;
end;

procedure TMapperLittleKimPc95.Reset;
begin
  inherited;
  UpdatePrgOffsets;
end;

procedure TMapperLittleKimPc95.UpdatePrgOffsets;
begin
  var Count := Length(FPrgRom) div $2000;
  for var Slot := 0 to 3 do
  begin
    // The PAL selects PRG A19 by CPU window, independently of MMC3 PRG inversion.
    var HighBit: Integer := $40;
    if Slot < Length(FPrgHigh) then
      HighBit := FPrgHigh[Slot];
    var Bank := HighBit or (PrgRegisterBank(Slot) and $3F);
    FPrgOffsets[Slot] := (Bank mod Count) * $2000;
  end;
end;

procedure TMapperLittleKimPc95.LatchPrgHigh(Address: Word; Value: Byte);
begin
  var Slot := Address and 1;
  Value := Value and $40;
  if FPrgHigh[Slot] = Value then
    Exit;
  FPrgHigh[Slot] := Value;
  UpdatePrgOffsets;
end;

function TMapperLittleKimPc95.ReadKeyboard: Byte;
const
  Matrix: array[0..11, 0..7] of TSuborKey = (
    (SkNum4, SkG, SkF, SkC, SkF2, SkE, SkNum5, SkV),
    (SkNum2, SkD, SkS, SkEnd, SkF1, SkW, SkNum3, SkX),
    (SkIns, SkBackspace, SkPageDown, SkRight, SkF8, SkPageUp, SkDelete, SkHome),
    (SkNum9, SkI, SkL, SkComma, SkF5, SkO, SkNum0, SkDot),
    (SkRightBracket, SkEnter, SkUp, SkLeft, SkF7, SkLeftBracket, SkBackslash, SkDown),
    (SkQ, SkCapsLock, SkZ, SkTab, SkEsc, SkA, SkNum1, SkCtrl),
    (SkNum7, SkY, SkK, SkM, SkF4, SkU, SkNum8, SkJ),
    (SkMinus, SkSemiColon, SkApostrophe, SkSlash, SkF6, SkP, SkEqual, SkShift),
    (SkT, SkH, SkN, SkSpace, SkF3, SkR, SkNum6, SkB),
    (SkNumpad6, SkNumpadEnter, SkNumpad4, SkNumpad8, SkNumpad2, SkNone, SkNone, SkNone),
    (SkNumpadMinus, SkNumpadPlus, SkNumpadMultiply, SkNumpad9, SkF10, SkNumpad5, SkNumpadDivide, SkNumLock),
    (SkGrave, SkNumpad6, SkPause, SkSpace, SkF9, SkNumpad3, SkNumpadDot, SkNumpad0));
begin
  Result := $FF;
  if (FKeyboard = nil) or not FKeyboard.Connected or (FKeyboardRow > High(Matrix)) then
    Exit;
  var Keys := FKeyboard.GetPressedKeys - [SkNone];
  for var Column := 0 to High(Matrix[0]) do
    if Matrix[FKeyboardRow, Column] in Keys then
      Result := Result xor (1 shl Column);
end;

function TMapperLittleKimPc95.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  // The PAL decodes both read and write cycles. During reads the latch sees open bus.
  if (Address and $FD06) = $4C00 then
    LatchPrgHigh(Address, FCpuOpenBus);
  Result := CpuPeek(Address, Value);
end;

function TMapperLittleKimPc95.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address >= $8000 then
  begin
    Value := FPrgRom[FPrgOffsets[(Address - $8000) shr 13] + (Address and $1FFF)];
    Exit(True);
  end;
  if Address >= $6000 then
  begin
    Value := FPrgRam[Address and $1FFF];
    Exit(True);
  end;
  if Address = $4906 then
  begin
    Value := ReadKeyboard;
    Exit(True);
  end;
  if (Address and $FD07) = $4C03 then
  begin
    // Keep the unidentified speech chip ready. The PAL only drives D7.
    Value := FCpuOpenBus and $7F;
    Exit(True);
  end;
  if (Address and $FD06) = $4C00 then
  begin
    Value := FCpuOpenBus;
    Exit(True);
  end;
  Result := False;
end;

function TMapperLittleKimPc95.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address = $4904 then
  begin
    FKeyboardRow := Value;
    Exit(True);
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    // This board's WRAM stays mapped independently of the MMC3 protect register.
    FPrgRam[Address and $1FFF] := Value;
    Exit(True);
  end;
  case Address and $FD07 of
    $4C00, $4C01:
      begin
        LatchPrgHigh(Address, Value);
        Exit(True);
      end;
    $4C04..$4C07:
      Exit(True); // OUTA and OUTB drive the unidentified speech chip.
  end;

  Result := inherited CpuWrite(Address, Value);
  if (Address and $E000) = $8000 then
    UpdatePrgOffsets;
end;

procedure TMapperLittleKimPc95.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgHigh, SizeOf(FPrgHigh));
  State.Field(FKeyboardRow, SizeOf(FKeyboardRow));
  if State.Loading then
    UpdatePrgOffsets;
end;

constructor TMapperDancingExpert.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  Reset;
end;

procedure TMapperDancingExpert.ConnectPanel(Panel: TController);
begin
  FPanel := Panel;
end;

procedure TMapperDancingExpert.Reset;
begin
  inherited;
  FRamEnabled := False;
  FRamWritable := False;
  FChrLow := 0;
  FChrHigh := 0;
end;

procedure TMapperDancingExpert.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FChrLow, SizeOf(FChrLow));
  State.Field(FChrHigh, SizeOf(FChrHigh));
end;

function TMapperDancingExpert.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := CpuPeek(Address, Value);
end;

function TMapperDancingExpert.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
const
  PanelBits: array[0..7] of TNesButton = (TNesButton.Up, TNesButton.Left, TNesButton.Down, TNesButton.Right,
    TNesButton.A, TNesButton.B, TNesButton.Select, TNesButton.Start);
begin
  case Address of
    $4016:
      begin
        // Idle level of the auxiliary input. The external device protocol is unknown.
        Value := $FE;
        Exit(True);
      end;
    $4017:
      begin
        Value := 0;
        if FPanel <> nil then
          for var Bit := Low(PanelBits) to High(PanelBits) do
            if FPanel.IsButtonPressed(PanelBits[Bit]) then
              Value := Value or (1 shl Bit);
        Exit(True);
      end;
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperDancingExpert.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if Address = $4016 then
  begin
    FChrHigh := Value and 7;
    Chr8((FChrHigh shl 2) or FChrLow);
    Exit(True);
  end;
  Result := (Address >= $5000) and (Address < $5800);
  if not Result then
    Exit;
  case Address and $0300 of
    $000:
      Prg16(0, Value and 7);
    $100:
      begin
        FChrLow := Value and 3;
        Chr8((FChrHigh shl 2) or FChrLow);
      end;
  end;
end;

constructor TMapperAsderPc95.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  PowerOn;
end;

procedure TMapperAsderPc95.ConnectKeyboard(Keyboard: TSuborKeyboard);
begin
  FKeyboard := Keyboard;
end;

procedure TMapperAsderPc95.PowerOn;
begin
  for var Slot := 0 to High(FPrgRegisters) do
    FPrgRegisters[Slot] := $FC or Slot;
  FillChar(FChrRegisters, SizeOf(FChrRegisters), 0);
  Reset;
end;

procedure TMapperAsderPc95.Reset;
begin
  inherited;
  FKeyboardRow := 0;
  for var Slot := 0 to High(FPrgRegisters) do
    Prg8(Slot, FPrgRegisters[Slot]);
  for var Slot := 0 to High(FChrRegisters) do
    Chr1(Slot, FChrRegisters[Slot]);
end;

function TMapperAsderPc95.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $4902:
      Value := FCpuOpenBus or $80; // A disconnected printer cannot accept data.
      $4906:
      begin
        Value := $FF;
        if FKeyboard <> nil then
          Value := FKeyboard.ReadMatrixRow(FKeyboardRow);
      end;
  else
    Exit(inherited CpuRead(Address, Value));
  end;
  Result := True;
end;

function TMapperAsderPc95.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $4904:
      FKeyboardRow := Value;
    $4900, $4901, $4905:
      ;
    $8000..$9FFF:
      begin
        var Slot := Address and 3;
        if Slot = 3 then
          Value := Value or 1;
        FPrgRegisters[Slot] := Value;
        Prg8(Slot, Value);
      end;
    $A000..$BFFF:
      begin
        var Slot := Address and 7;
        FChrRegisters[Slot] := Value;
        Chr1(Slot, Value);
      end;
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

procedure TMapperAsderPc95.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FPrgRegisters, SizeOf(FPrgRegisters));
  State.Field(FChrRegisters, SizeOf(FChrRegisters));
  State.Field(FKeyboardRow, SizeOf(FKeyboardRow));
end;

constructor TMapperExtendedMemory.Create(Board: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; Eeprom: Boolean);
begin
  inherited Create(Prg, Chr, HasChrRam, MirrorMode);
  FBoard := Board;
  if Eeprom then
    Configure93C66($2000);
  if Board = MAPPER_FDS_CONVERSION_103 then
    SetLength(FPrgRam, $4000);
  if Board = MAPPER_RACERMATE then
  begin
    SetLength(FChrMemory, $10000);
    FHasChrRam := True
  end;
  Reset;
end;

procedure TMapperExtendedMemory.Configure93C66(PrgRamSize: Integer);
begin
  if ((FBoard <> MAPPER_WAIXING164) and (FBoard <> MAPPER_WAIXING558)) or
    (PrgRamSize < 0) or (PrgRamSize > $2000) then
    raise ENesException.Create('Unsupported Waixing 93C66 RAM layout');

  FHasEeprom := True;
  SetLength(FPrgRam, PrgRamSize);
  FillChar(FEeprom, SizeOf(FEeprom), $FF);
  FEepromWriteEnabled := False;
  ResetEepromBus;
end;

procedure TMapperExtendedMemory.ConfigureWaixing558Ram(Size: UInt64);
begin
  if Size > $2000 then
    raise ENesException.Create('Unsupported mapper 558 RAM layout');
  SetLength(FPrgRam, Integer(Size));
end;

procedure TMapperExtendedMemory.ResetEepromBus;
begin
  FEepromPhase := T93C66Phase.Start;
  FEepromClock := False;
  FEepromOutput := True;
  FEepromBits := 0;
  FEepromShift := 0;
  FEepromAddress := 0;
  FEepromOpcode := 0;
end;

procedure TMapperExtendedMemory.WriteEeprom(Value: Byte);
begin
  // 93C66, ORG=0: start bit, two opcode bits, nine address bits,
  // then eight data bits, all MSB first. $5200 drives CS/CLK/DI.
  var Clock := (Value and $04) <> 0;
  if (Value and $10) = 0 then
    ResetEepromBus
  else if Clock and not FEepromClock then
    case FEepromPhase of
      T93C66Phase.Start:
        if (Value and 1) <> 0 then
        begin
          FEepromPhase := T93C66Phase.Command;
          FEepromBits := 0;
          FEepromShift := 0;
        end;
      T93C66Phase.Command:
        begin
          FEepromShift := (FEepromShift shl 1) or (Value and 1);
          Inc(FEepromBits);
          if FEepromBits = 11 then
          begin
            FEepromOpcode := FEepromShift shr 9;
            FEepromAddress := FEepromShift and $1FF;
            FEepromBits := 0;
            FEepromShift := 0;
            FEepromPhase := T93C66Phase.Done;
            case FEepromOpcode of
              0:
                case FEepromAddress shr 7 of
                  0:
                    FEepromWriteEnabled := False; // EWDS
                    1:
                    FEepromPhase := T93C66Phase.WriteData; // WRAL
                    2:
                    if FEepromWriteEnabled then
                      FillChar(FEeprom, SizeOf(FEeprom), $FF); // ERAL
                      3:
                    FEepromWriteEnabled := True; // EWEN
                end;
              1:
                FEepromPhase := T93C66Phase.WriteData;
              2:
                begin
                  FEepromPhase := T93C66Phase.ReadData;
                  FEepromOutput := False; // Dummy zero precedes the first byte.
                end;
              3:
                if FEepromWriteEnabled then
                  FEeprom[FEepromAddress] := $FF;
            end;
          end;
        end;
      T93C66Phase.ReadData:
        begin
          FEepromOutput := (FEeprom[FEepromAddress] and ($80 shr FEepromBits)) <> 0;
          Inc(FEepromBits);
          if FEepromBits = 8 then
          begin
            FEepromBits := 0;
            FEepromAddress := (FEepromAddress + 1) and $1FF;
          end;
        end;
      T93C66Phase.WriteData:
        begin
          FEepromShift := (FEepromShift shl 1) or (Value and 1);
          Inc(FEepromBits);
          if FEepromBits = 8 then
          begin
            if FEepromWriteEnabled then
              if FEepromOpcode = 0 then
                FillChar(FEeprom, SizeOf(FEeprom), Byte(FEepromShift))
              else
                FEeprom[FEepromAddress] := Byte(FEepromShift);
            // Programming completes immediately; DO reports ready. A new
            // instruction requires CS to fall before its start bit.
            FEepromOutput := True;
            FEepromPhase := T93C66Phase.Done;
          end;
        end;
    end;
  FEepromClock := Clock;
end;

procedure TMapperExtendedMemory.Reset;
begin
  inherited;
  if FHasEeprom then
    ResetEepromBus;
  FillChar(FRegs, SizeOf(FRegs), 0);
  FSelect := 0;
  FMode := 0;
  FCounter := 0;
  FPending := False;
  FLocked := False;
  case FBoard of
    MAPPER_CROAKY_KARAOKE:
      begin
        FRamEnabled := False;
        Prg16(0, 0);
        Prg16(1, 0);
        Mirror(0);
      end;
    MAPPER_ACTION53:
      SetLength(FChrMemory, $8000);
    MAPPER_WAIXING162:
      begin
        FRegs[0] := 3;
        FRegs[3] := 7;
        UpdateOuter
      end;
    MAPPER_NANJING:
      begin
        FLocked := True;
        Prg32(0);
        Chr4(0, 0);
        Chr4(1, 0)
      end;
    MAPPER_WAIXING558:
      UpdateWaixing558;
    MAPPER_WAIXING164:
      begin
        FRegs[0] := 15;
        Prg32(15)
      end;
    MAPPER_FDS_CONVERSION_103:
      Prg32(-1);
    MAPPER_RACERMATE:
      begin
        Chr4(0, 0);
        Chr4(1, 0)
      end;
    MAPPER_KAISER7022, MAPPER_MAGIC_KID_GOO_GOO:
      begin
        Prg16(0, 0);
        Prg16(1, 0)
      end;
    MAPPER_BANDAI_KARAOKE:
      Prg16(1, 7);
    MAPPER_MAGIC_FLOOR218:
      Prg32(0);
    MAPPER_DANCE2000:
      begin
        Prg16(0, 0);
        Prg16(1, 0);
        Mirror(0)
      end;
    MAPPER_T262, MAPPER_T262_LEGACY:
      begin
        Prg16(0, 0);
        Prg16(1, 7)
      end;
    MAPPER_KAISER7057, MAPPER_KAISER7031, MAPPER_KAISER7037, MAPPER_LH10, MAPPER_AX5705:
      begin
        Prg8(0, 0);
        Prg8(1, 0);
        Prg8(2, -2);
        Prg8(3, -1)
      end;
  end;
  if FBoard = MAPPER_MAGIC_KID_GOO_GOO then
    Mirror(0);
  if FBoard = MAPPER_KAISER7031 then
    Mirror(0);
  if FBoard = MAPPER_AX5705 then
    for var i := 0 to 7 do
      Chr1(i, 0);
  if FBoard = MAPPER_SPECIAL_174 then
    CpuWrite($8000, 0);
end;

procedure TMapperExtendedMemory.UpdateOuter;
var
  Bank, Mask, Mode, FixedSlot: Integer;
begin
  if FBoard = MAPPER_ACTION53 then
  begin
    Mode := FRegs[2] and 3;
    if Mode < 2 then
      Mirror(FMode + 2)
    else
      Mirror(Mode - 2);
    Chr8(FRegs[0] and 3);
    Mask := (2 shl ((FRegs[2] shr 4) and 3)) - 1;
    Bank := (FRegs[3] shl 1) and (511 xor Mask);
    if (FRegs[2] and 8) <> 0 then
    begin
      FixedSlot := (FRegs[2] shr 2) and 1;
      Prg16(1 - FixedSlot, Bank or (FRegs[1] and Mask));
      Prg16(FixedSlot, (FRegs[3] shl 1) or FixedSlot);
    end
    else
    begin
      Prg16(0, Bank or ((FRegs[1] shl 1) and Mask));
      Prg16(1, Bank or (((FRegs[1] shl 1) or 1) and Mask))
    end;
  end
  else if FBoard = MAPPER_WAIXING162 then
  begin
    Bank := (FRegs[2] and 15) shl 4;
    case FRegs[3] and 5 of
      0:
        Bank := Bank or (FRegs[0] and 12) or (FRegs[1] and 2);
      1:
        Bank := Bank or (FRegs[0] and 12);
      4:
        Bank := Bank or (FRegs[0] and 14) or ((FRegs[1] shr 1) and 1);
      5:
        Bank := Bank or (FRegs[0] and 15);
    end;
    Prg32(Bank);
  end
  else if FBoard = MAPPER_NANJING then
    Prg32((FRegs[0] and 15) or ((FRegs[2] and 15) shl 4));
end;

procedure TMapperExtendedMemory.UpdateWaixing558;
begin
  var Bank := (FRegs[1] shl 4) or (FRegs[0] and $0F);
  if (FRegs[3] and 4) = 0 then
    Bank := Bank or 3;
  if (Length(FPrgRom) = $100000) and ((FRegs[3] and 2) <> 0) then
    Bank := Bank or ((FRegs[1] shl 3) and $10);
  Prg32(Bank);
end;

procedure TMapperExtendedMemory.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FSelect, SizeOf(FSelect));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FLocked, SizeOf(FLocked));
  State.Field(FNameRam, SizeOf(FNameRam));
  if (FBoard = MAPPER_WAIXING164) or (FBoard = MAPPER_WAIXING558) then
    if (State.Version >= 18) or (FBoard = MAPPER_WAIXING558) then
    begin
      var HasEeprom := FHasEeprom;
      State.Field(HasEeprom, SizeOf(HasEeprom));
      if HasEeprom <> FHasEeprom then
        raise ENesException.Create('Snapshot belongs to a different Waixing memory layout');

      if FHasEeprom then
      begin
        State.Field(FEeprom, SizeOf(FEeprom));
        State.Field(FEepromClock, SizeOf(FEepromClock));
        State.Field(FEepromOutput, SizeOf(FEepromOutput));
        State.Field(FEepromWriteEnabled, SizeOf(FEepromWriteEnabled));
        State.Field(FEepromPhase, SizeOf(FEepromPhase));
        State.Field(FEepromBits, SizeOf(FEepromBits));
        State.Field(FEepromShift, SizeOf(FEepromShift));
        State.Field(FEepromAddress, SizeOf(FEepromAddress));
        State.Field(FEepromOpcode, SizeOf(FEepromOpcode));
      end;
    end
    else if FHasEeprom then
      raise ENesException.Create('Snapshot predates mapper 164 EEPROM support');
end;

function TMapperExtendedMemory.SmallPrgRead(Address: UInt16; out Value: Byte): Boolean;
var
  Bank, Offset: Integer;
begin
  Result := False;
  Offset := 0;
  case FBoard of
    MAPPER_KAISER7057:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          Bank := FRegs[4 + ((Address - $6000) shr 11)]
        else if Address < $A000 then
          Bank := FRegs[(Address - $8000) shr 11]
        else
          Bank := $34 + ((Address - $A000) shr 11);
        Offset := Bank * $800 + (Address and $7FF);
        Result := True;
      end;
    MAPPER_KAISER7031:
      if Address >= $6000 then
      begin
        if Address < $8000 then
          Bank := FRegs[(Address - $6000) shr 11]
        else
          Bank := 15 - ((Address - $8000) shr 11);
        Offset := Bank * $800 + (Address and $7FF);
        Result := True;
      end;
    MAPPER_KAISER7037:
      case Address shr 12 of
        6:
          begin
            Value := FPrgRam[Address and $FFF];
            Exit(True)
          end;
        7:
          begin
            Offset := 15 * $1000 + (Address and $FFF);
            Result := True
          end;
        10:
          begin
            Offset := Length(FPrgRom) - $4000 + (Address and $FFF);
            Result := True
          end;
        11:
          begin
            Value := FPrgRam[$1000 + (Address and $FFF)];
            Exit(True)
          end;
      end;
    MAPPER_LH10:
      if (Address >= $6000) and (Address < $8000) then
      begin
        Offset := Length(FPrgRom) - $4000 + (Address and $1FFF);
        Result := True
      end
      else if (Address >= $C000) and (Address < $E000) then
      begin
        Value := FPrgRam[Address and $1FFF];
        Exit(True)
      end;
  end;
  if Result then
    Value := FPrgRom[Offset mod Length(FPrgRom)];
end;

function TMapperExtendedMemory.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if (FBoard = MAPPER_WAIXING558) and ((Address and $F000) = $5000) then
  begin
    if FHasEeprom then
      Value := Ord(FEepromOutput) shl 2
    else
      Value := FRegs[2] and 4;
    Exit(True);
  end;
  if FHasEeprom or (FBoard = MAPPER_WAIXING558) then
  begin
    if (FBoard = MAPPER_WAIXING164) and ((Address and $FC00) = $5400) then
    begin
      Value := Ord(not FEepromOutput) shl 2; // Inverted DO at $5400-$57FF.
      Exit(True);
    end;

    if (Address >= $6000) and (Address < $8000) then
    begin
      if Length(FPrgRam) = 0 then
        Exit(False);
      Value := FPrgRam[(Address - $6000) mod Length(FPrgRam)];
      Exit(True);
    end;
  end;
  if (FBoard = MAPPER_NANJING) and (Address >= $5000) and (Address < $6000) then
  begin
    case Address and $7700 of
      $5100:
        Value := Byte(FRegs[3] or FRegs[1] or FRegs[0] or (FRegs[2] xor $FF));
      $5500:
        if FLocked then
          Value := Byte(FRegs[3] or FRegs[0])
        else
          Value := 0;
    else
      Value := 4
    end;
    Exit(True);
  end;

  if SmallPrgRead(Address, Value) then
    Exit(True);

  if (FBoard = MAPPER_KAISER7022) and (Address = $FFFC) then
  begin
    Prg16(0, FRegs[0]);
    Prg16(1, FRegs[0]);
    Chr8(FRegs[0])
  end;
  if FBoard = MAPPER_FDS_CONVERSION_103 then
  begin
    if (Address >= $6000) and (Address < $8000) then
    begin
      if FMode = 0 then
        Value := FPrgRam[Address - $6000]
      else
        Value := FPrgRom[(FRegs[0] * $2000 + (Address and $1FFF)) mod Length(FPrgRom)];
      Exit(True);
    end;
    if (Address >= $B800) and (Address < $D800) and (FMode = 0) then
    begin
      Value := FPrgRam[$2000 + Address - $B800];
      Exit(True)
    end;
  end;

  if (FBoard = MAPPER_BANDAI_KARAOKE) and (Address >= $6000) and (Address < $8000) then
  begin
    Value := FCpuOpenBus and $F8;
    Exit(True)
  end;

  if (FBoard = MAPPER_BANDAI_KARAOKE) and (Address >= $8000) and (Address < $C000) and (FMode <> 0) then
    Exit(False);

  if (FBoard = MAPPER_DANCE2000) and (Address >= $8000) and ((FRegs[0] and $40) <> 0) then
    Exit(False);

  Result := inherited CpuRead(Address, Value);
end;

function TMapperExtendedMemory.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Slot, Shift, Bank: Integer;
  Bus: Byte;
begin
  if FHasEeprom or (FBoard = MAPPER_WAIXING558) then
  begin
    if (FBoard = MAPPER_WAIXING164) and ((Address and $FF00) = $5200) then
    begin
      WriteEeprom(Value);
      Exit(True);
    end;

    if (Address >= $6000) and (Address < $8000) then
    begin
      if Length(FPrgRam) = 0 then
        Exit(False);
      FPrgRam[(Address - $6000) mod Length(FPrgRam)] := Value;
      Exit(True);
    end;
  end;
  Result := True;
  case FBoard of
    MAPPER_CROAKY_KARAOKE:
      if (Address and $F000) = $5000 then
      begin
        FRegs[(Address shr 8) and 3] := Value;
        if (FRegs[2] and 4) <> 0 then
          Prg32(FRegs[0])
        else
        begin
          Prg16(0, FRegs[0]);
          Prg16(1, FRegs[0]);
        end;
        Mirror(FRegs[2] and 1);
      end
      else
        Exit(False);
    MAPPER_ACTION53:
      if (Address >= $5000) and (Address < $6000) then
        FSelect := ((Value and $80) shr 6) or (Value and 1)
      else if Address >= $8000 then
      begin
        if FSelect < 2 then
          FMode := (Value shr 4) and 1
        else if FSelect = 2 then
          FMode := Value and 1;
        FRegs[FSelect] := Value;
        UpdateOuter;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_WAIXING558:
      if (Address and $F800) = $5000 then
      begin
        Slot := (Address shr 8) and 7;
        // D0 and D1 are crossed on the board. The ASIC can swap them back.
        if (Slot >= 3) or ((FRegs[3] and 2) = 0) then
          Value := (Value and $FC) or ((Value and 1) shl 1) or ((Value and 2) shr 1);
        FRegs[Slot] := Value;
        if FHasEeprom and (Slot = 2) then
          WriteEeprom(((Value and 4) shl 2) or ((Value and 2) shl 1) or (Value and 1));
        UpdateWaixing558;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_WAIXING162, MAPPER_NANJING, MAPPER_WAIXING164:
      if (Address >= $5000) and (Address < $6000) then
      begin
        if FBoard = MAPPER_WAIXING164 then
        begin
          case Address and $7300 of
            $5000:
              FRegs[0] := (FRegs[0] and $F0) or (Value and 15);
            $5100:
              FRegs[0] := (FRegs[0] and 15) or ((Value and 15) shl 4);
          end;
          Prg32(FRegs[0]);
        end
        else if (FBoard = MAPPER_NANJING) and (Address = $5101) then
        begin
          if (FRegs[4] <> 0) and (Value = 0) then
            FLocked := not FLocked;
          FRegs[4] := Value
        end
        else if (FBoard = MAPPER_NANJING) and ((Address and $7300) = $5100) and (Value = 6) then
          Prg32(3)
        else
        begin
          FRegs[(Address shr 8) and 3] := Value;
          if (FBoard = MAPPER_NANJING) and ((Address and $7300) = $5000) and ((Value and $80) = 0) and (FCounter < 128) then
          begin
            Chr4(0, 0);
            Chr4(1, 1)
          end;
          UpdateOuter;
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_FDS_CONVERSION_103:
      if (Address >= $6000) and (Address < $8000) then
        FPrgRam[Address - $6000] := Value
      else if (Address >= $B800) and (Address < $D800) then
        FPrgRam[$2000 + Address - $B800] := Value
      else
        case Address and $F000 of
          $8000:
            FRegs[0] := Value and 15;
          $E000:
            Mirror(Ord((Value and 8) <> 0));
          $F000:
            FMode := Value and $10;
        else
          Exit(False)
        end;
    MAPPER_RACERMATE:
      if Address >= $8000 then
        if Address < $C000 then
        begin
          Prg16(0, (Value shr 6) and 3);
          Chr4(1, Value and 15)
        end
        else
        begin
          FCounter := 1024;
          FPending := False
        end
      else
        Exit(False);
    MAPPER_SPECIAL_174:
      if Address >= $8000 then
      begin
        Bank := (Address shr 4) and 7;
        if (Address and $80) <> 0 then
        begin
          Prg16(0, Bank and $FE);
          Prg16(1, Bank or 1)
        end
        else
        begin
          Prg16(0, Bank);
          Prg16(1, Bank)
        end;
        Chr8((Address shr 1) and 7);
        Mirror(Address and 1);
      end
      else
        Exit(False);
    MAPPER_KAISER7022:
      case Address and $F000 of
        $8000:
          Mirror(Ord((Value and 4) <> 0));
        $A000:
          FRegs[0] := Value and 15;
      else
        Exit(False)
      end;
    MAPPER_BANDAI_KARAOKE:
      if Address >= $8000 then
      begin
        if inherited CpuRead(Address, Bus) then
          Value := Value and Bus;
        Bank := Value and 7;
        FMode := 0;
        if (Value and $10) = 0 then
          if Length(FPrgRom) >= $40000 then
            Bank := Bank or 8
          else
            FMode := 1;
        Prg16(0, Bank);
        Mirror(Ord((Value and $20) <> 0));
      end
      else
        Exit(False);
    MAPPER_MAGIC_KID_GOO_GOO:
      if Address >= $8000 then
        if (Address and $A000) = $A000 then
          Chr2(Address and 3, Value)
        else if Address < $A000 then
          Prg16(0, Value and 7)
        else
          Prg16(0, (Value and 7) or 8)
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_T262_LEGACY:
      if Address >= $8000 then
      begin
        // The preliminary mapper number uses this address decode.
        if not FLocked then
        begin
          FRegs[0] := (Address shr 2) and $FF;
          FRegs[1] := Address shr 10;
          FLocked := Address >= $F000;
          Mirror((Address shr 1) and 1);
        end;
        Bank := FRegs[0] or (Integer(FRegs[1]) shl 8);
        Prg16(0, Bank or (Value and 7));
        Prg16(1, Bank or 7);
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_T262:
      if Address >= $8000 then
      begin
        if not FLocked then
        begin
          FRegs[0] := ((Address and $60) shr 2) or ((Address and $300) shr 3);
          FMode := Address and $81;
          FLocked := (Address and $2000) <> 0;
          Mirror((Address shr 1) and 1);
        end;
        var LowerBank := FRegs[0] or (Value and 7);
        var UpperBank := FRegs[0] or 7;
        if (FMode and $80) <> 0 then
          UpperBank := LowerBank;
        // A0 of the address latch can route CPU A14 directly to PRG A14.
        if Odd(FMode) then
        begin
          LowerBank := LowerBank and $FE;
          UpperBank := UpperBank or 1;
        end;
        Prg16(0, LowerBank);
        Prg16(1, UpperBank);
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_KAISER7057:
      if (Address >= $B000) and (Address < $F000) then
      begin
        Slot := ((Address shr 12) - 11) * 2 + ((Address shr 1) and 1);
        Shift := (Address and 1) * 4;
        FRegs[Slot] := (FRegs[Slot] and ($FF xor ($F shl Shift))) or ((Value and 15) shl Shift);
      end
      else if (Address >= $8000) and (Address < $A000) then
        Mirror(1 - (Value and 1))
      else
        Exit(False);
    MAPPER_KAISER7031:
      if Address >= $8000 then
        FRegs[(Address shr 11) and 3] := Value
      else
        Exit(False);
    MAPPER_KAISER7037, MAPPER_LH10:
      if ((FBoard = MAPPER_KAISER7037) and (((Address >= $6000) and (Address < $7000)) or ((Address >= $B000) and (Address < $C000)))) then
        FPrgRam[(Ord(Address >= $B000) * $1000) + (Address and $FFF)] := Value
      else if (FBoard = MAPPER_LH10) and (Address >= $C000) and (Address < $E000) then
        FPrgRam[Address and $1FFF] := Value
      else if (Address >= $8000) and ((FBoard = MAPPER_LH10) or (Address < $A000) or (Address >= $C000)) then
      begin
        if (Address and 1) = 0 then
          FSelect := Value and 7
        else
        begin
          FRegs[FSelect] := Value;
          if FSelect >= 6 then
            Prg8((FSelect - 6) * Ord(FBoard = MAPPER_KAISER7037) + FSelect - 6, Value)
        end;
      end
      else
        Exit(False);
    MAPPER_DANCE2000:
      if (Address = $5000) or (Address = $5200) then
      begin
        if Address = $5000 then
          FRegs[0] := Value
        else
          FMode := Value;
        if (Address = $5200) and ((FMode and 4) = 0) then
          Exit(True);
        Mirror(FMode and 1);
        if (FMode and 4) <> 0 then
          Prg32(FRegs[0] and 7)
        else
        begin
          Prg16(0, FRegs[0] and 15);
          Prg16(1, 0)
        end;
      end
      else
        Exit(inherited CpuWrite(Address, Value));
    MAPPER_AX5705:
      case Address and $F00F of
        $8000:
          Prg8(0, ((Value and 2) shl 2) or ((Value and 8) shr 2) or (Value and 5));
        $A000:
          Prg8(1, ((Value and 2) shl 2) or ((Value and 8) shr 2) or (Value and 5));
        $8008:
          Mirror(Value and 1);
      else
        case Address and $F00E of
          $A008:
            Slot := 0;
          $A00A:
            Slot := 1;
          $C000:
            Slot := 2;
          $C002:
            Slot := 3;
          $C008:
            Slot := 4;
          $C00A:
            Slot := 5;
          $E000:
            Slot := 6;
          $E002:
            Slot := 7;
        else
          Exit(False)
        end;
        Shift := (Address and 1) * 4;
        if Shift <> 0 then
          Value := (Value and 9) or ((Value and 2) shl 1) or ((Value and 4) shr 1);
        FRegs[Slot] := (FRegs[Slot] and ($FF xor ($F shl Shift))) or ((Value and 15) shl Shift);
        Chr1(Slot, FRegs[Slot]);
      end;
  else
    Exit(inherited CpuWrite(Address, Value))
  end;
end;

function TMapperExtendedMemory.PpuRead(Address: UInt16; out Value: UInt8): Boolean;
var
  Slot, Bank: Integer;
begin
  if (FBoard = MAPPER_WAIXING558) and (Address < $2000) and ((FRegs[0] and $80) <> 0) then
    Address := (Address and $0FFF) or (FRegs[9] shl 12);

  if (FBoard = MAPPER_MAGIC_FLOOR218) and (Address < $3F00) then
  begin
    Slot := $800;
    if FMirror = TMirrorMode.Vertical then
      Slot := $400;
    if FMirror = TMirrorMode.Single0 then
      Slot := $1000;
    if FMirror = TMirrorMode.Single1 then
      Slot := $2000;
    Value := FNameRam[Ord((Address and Slot) <> 0) * $400 + (Address and $3FF)];
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7037) and (Address >= $2000) and (Address < $3F00) then
  begin
    Slot := (Address shr 10) and 3;
    case Slot of
      0:
        Bank := FRegs[2];
      1:
        Bank := FRegs[4];
      2:
        Bank := FRegs[3];
    else
      Bank := FRegs[5]
    end;
    Value := FNameRam[(Bank and 1) * $400 + (Address and $3FF)];
    Exit(True);
  end;

  Result := inherited PpuRead(Address, Value);
end;

function TMapperExtendedMemory.PpuWrite(Address: UInt16; Value: UInt8): Boolean;
var
  Slot, Bank: Integer;
begin
  if (FBoard = MAPPER_MAGIC_FLOOR218) and (Address < $3F00) then
  begin
    Slot := $800;
    if FMirror = TMirrorMode.Vertical then
      Slot := $400;
    if FMirror = TMirrorMode.Single0 then
      Slot := $1000;
    if FMirror = TMirrorMode.Single1 then
      Slot := $2000;
    FNameRam[Ord((Address and Slot) <> 0) * $400 + (Address and $3FF)] := Value;
    Exit(True);
  end;

  if (FBoard = MAPPER_KAISER7037) and (Address >= $2000) and (Address < $3F00) then
  begin
    Slot := (Address shr 10) and 3;
    case Slot of
      0:
        Bank := FRegs[2];
      1:
        Bank := FRegs[4];
      2:
        Bank := FRegs[3];
    else
      Bank := FRegs[5]
    end;
    FNameRam[(Bank and 1) * $400 + (Address and $3FF)] := Value;
    Exit(True);
  end;

  Result := inherited PpuWrite(Address, Value);
end;

procedure TMapperExtendedMemory.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
  if FBoard = MAPPER_WAIXING558 then
  begin
    var A13 := Ord((Address and $2000) <> 0);
    if (FRegs[8] = 0) and (A13 <> 0) then
      FRegs[9] := (Address shr 9) and 1;
    FRegs[8] := A13;
    Exit;
  end;

  if (FBoard = MAPPER_DANCE2000) and (Address >= $2000) and (Address < $3000) and ((FMode and 2) <> 0) then
    Chr4(0, (Address shr 11) and 1);
  if (FBoard = MAPPER_DANCE2000) and ((FMode and 2) = 0) then
    Chr4(0, 0);
end;

procedure TMapperExtendedMemory.ClockScanline(Line: Integer; Rendering: Boolean);
begin
  if FBoard = MAPPER_NANJING then
    FCounter := Line;
  if (FBoard = MAPPER_NANJING) and ((FRegs[0] and $80) <> 0) then
    if Line = 128 then
    begin
      Chr4(0, 1);
      Chr4(1, 1)
    end
    else if Line = 240 then
    begin
      Chr4(0, 0);
      Chr4(1, 0)
    end;
end;

procedure TMapperExtendedMemory.ClockCpu;
begin
  if FBoard = MAPPER_RACERMATE then
  begin
    FCounter := (FCounter - 1) and $FFFF;
    if FCounter = 0 then
    begin
      FCounter := 1024;
      FPending := True
    end
  end;
end;

function TMapperExtendedMemory.IrqPending: Boolean;
begin
  Result := FPending
end;

function TMapperExtendedMemory.GetSaveMemory: TByteArray;
begin
  if FHasEeprom then
  begin
    SetLength(Result, SizeOf(FEeprom));
    Move(FEeprom[0], Result[0], Length(Result));
  end
  else if FBoard = MAPPER_RACERMATE then
    Result := Copy(FChrMemory, $8000, $8000)
  else
    Result := inherited GetSaveMemory;
end;

procedure TMapperExtendedMemory.SetSaveMemory(const Data: TByteArray);
begin
  if FHasEeprom then
  begin
    if Length(Data) <> SizeOf(FEeprom) then
      raise ENesException.Create('Invalid mapper 164 EEPROM save size');

    Move(Data[0], FEeprom[0], SizeOf(FEeprom));
  end
  else if FBoard = MAPPER_RACERMATE then
  begin
    if Length(Data) <> $8000 then
      raise ENesException.Create('Invalid Racermate save size');

    Move(Data[0], FChrMemory[$8000], $8000);
  end
  else
    inherited;
end;

const
  BlazeProDiskIdleTicks = 3 * NES_CPU_HZ;
  BlazeProDiskChangeTicks = 50000;

constructor TMapperBlazeProFds.Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode);
begin
  if (Length(Prg) < $100000) or (Length(Chr) <> 0) then
    raise ENesException.Create('Invalid BlazePro FDS ROM layout');
  inherited Create(Prg, Chr, True, MirrorMode);
  SetLength(FPrgRam, $8000);
  Reset;
end;

procedure TMapperBlazeProFds.Reset;
begin
  inherited;
  FMode := 0;
  FBank := $FF;
  FDisk := 0;
  FDiskControl := 0;
  FDiskOffset := 0;
  FDataPhase := 0;
  FDiskIdle := 0;
  FChangeDelay := 0;
  FChangeStep := 0;
  FInserted := True;
  FDataPending := False;
  FTimerLatch := 0;
  FTimerCounter := 0;
  FTimerEnabled := False;
  FTimerRepeat := False;
  FTimerPending := False;
  MapBanks;
end;

procedure TMapperBlazeProFds.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FMode, SizeOf(FMode));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FDisk, SizeOf(FDisk));
  State.Field(FDiskControl, SizeOf(FDiskControl));
  State.Field(FDiskOffset, SizeOf(FDiskOffset));
  State.Field(FDataPhase, SizeOf(FDataPhase));
  State.Field(FDiskIdle, SizeOf(FDiskIdle));
  State.Field(FChangeDelay, SizeOf(FChangeDelay));
  State.Field(FChangeStep, SizeOf(FChangeStep));
  State.Field(FInserted, SizeOf(FInserted));
  State.Field(FDataPending, SizeOf(FDataPending));
  State.Field(FTimerLatch, SizeOf(FTimerLatch));
  State.Field(FTimerCounter, SizeOf(FTimerCounter));
  State.Field(FTimerEnabled, SizeOf(FTimerEnabled));
  State.Field(FTimerRepeat, SizeOf(FTimerRepeat));
  State.Field(FTimerPending, SizeOf(FTimerPending));
end;

procedure TMapperBlazeProFds.MapBanks;
begin
  if (FMode shr 4) = 4 then
  begin
    Prg8(3, (Integer(FBank) shl 5) or 7);
    if (FDiskControl and 8) <> 0 then
      FMirror := TMirrorMode.Horizontal
    else
      FMirror := TMirrorMode.Vertical;
  end
  else
  begin
    Prg32(FBank);
    FMirror := TMirrorMode.Horizontal;
  end;
end;

procedure TMapperBlazeProFds.PollDiskChange;
begin
  if FChangeDelay = 0 then
    case FChangeStep of
      0:
        if FDiskIdle >= BlazeProDiskIdleTicks then
        begin
          FChangeStep := 1;
          FChangeDelay := BlazeProDiskChangeTicks;
        end;
      1:
        begin
          FInserted := False;
          FChangeStep := 2;
          FChangeDelay := BlazeProDiskChangeTicks;
        end;
      2:
        begin
          FInserted := True;
          FDisk := FDisk xor 1;
          FChangeStep := 0;
        end;
    end;
  FDiskIdle := 0;
end;

function TMapperBlazeProFds.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  case Address of
    $5030:
      if FTimerPending then
        Value := 1
      else
        Value := Ord(FDataPending) shl 1;
    $5032:
      Value := Ord(not FInserted) * 5;
    $5103:
      if (FDisk = 2) or (FDisk = 3) then
      begin
        var Bank := ((FDisk - 2) shl 1) or ((FDiskOffset shr 15) and 1);
        Value := FPrgRom[(Bank shl 18) + $38000 + (FDiskOffset and $7FFF)];
      end
      else
        Value := FCpuOpenBus;
    $6000..$DFFF:
      if (FMode shr 4) = 4 then
        Value := FPrgRam[Address - $6000]
      else if Address >= $8000 then
        Value := FPrgRom[PrgOffset(Address)]
      else
        Value := FCpuOpenBus;
    $E000..$FFFF:
      Value := FPrgRom[PrgOffset(Address)];
  else
    Exit(False);
  end;
  Result := True;
end;

function TMapperBlazeProFds.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address = $5032 then
    PollDiskChange;
  Result := CpuPeek(Address, Value);
  if Address = $5030 then
  begin
    FTimerPending := False;
    FDataPending := False;
  end;
end;

function TMapperBlazeProFds.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  case Address of
    $5020:
      FTimerLatch := (FTimerLatch and $FF00) or Value;
    $5021:
      FTimerLatch := (FTimerLatch and $FF) or (Word(Value) shl 8);
    $5022:
      begin
        FTimerRepeat := (Value and 1) <> 0;
        FTimerEnabled := (Value and 2) <> 0;
        if FTimerEnabled then
          FTimerCounter := FTimerLatch
        else
          FTimerPending := False;
      end;
    $5025:
      begin
        FDiskControl := Value;
        FDataPhase := 0;
        MapBanks;
      end;
    $5100:
      begin
        FDiskOffset := $FFFB;
        FDiskIdle := 0;
      end;
    $5102:
      begin
        FDiskOffset := (FDiskOffset + 1) and $FFFF;
        FDataPending := False;
      end;
    $5110:
      begin
        FDisk := Value;
        FDiskIdle := 0;
      end;
    $5700:
      begin
        FMode := Value;
        MapBanks;
      end;
    $5701:
      begin
        FBank := Value;
        MapBanks;
      end;
    $6000..$DFFF:
      if (FMode shr 4) = 4 then
        FPrgRam[Address - $6000] := Value;
  else
    Exit(False);
  end;
  Result := True;
end;

procedure TMapperBlazeProFds.ClockCpu;
begin
  if FTimerEnabled then
    if FTimerCounter <> 0 then
      Dec(FTimerCounter)
    else
    begin
      FTimerPending := True;
      FTimerEnabled := FTimerRepeat;
      if FTimerRepeat then
        FTimerCounter := FTimerLatch;
    end;

  Inc(FDataPhase, 3);
  if FDataPhase >= 448 then
  begin
    Dec(FDataPhase, 448);
    FDataPending := True;
  end;

  if FDiskIdle < BlazeProDiskIdleTicks then
    Inc(FDiskIdle);
  if FChangeDelay > 0 then
    Dec(FChangeDelay);
end;

function TMapperBlazeProFds.IrqPending: Boolean;
begin
  Result := FTimerPending or (((FDiskControl and $80) <> 0) and FDataPending);
end;

end.

