unit NES.Controller;

interface

uses
  System.Types, System.SysUtils, NES.State, NES.Types;

{$SCOPEDENUMS ON}

type
  TNesButton = (A, B, Select, Start, Up, Down, Left, Right);

  TNesButtons = set of TNesButton;

  TPowerPadButton = 1..12;

  TPowerPadButtons = set of TPowerPadButton;

  TFamilyTrainerMode = (ftDisconnected, ftSideA, ftSideB);

  TKeyMap = record
    A, B, Select, Start, Up, Down, Left, Right: UInt32;
  end;

{$SCOPEDENUMS OFF}
  TSuborKey = (
    SkA, SkB, SkC, SkD, SkE, SkF, SkG, SkH, SkI, SkJ, SkK, SkL, SkM,
    SkN, SkO, SkP, SkQ, SkR, SkS, SkT, SkU, SkV, SkW, SkX, SkY, SkZ,
    SkNum0, SkNum1, SkNum2, SkNum3, SkNum4, SkNum5, SkNum6, SkNum7, SkNum8, SkNum9,
    SkF1, SkF2, SkF3, SkF4, SkF5, SkF6, SkF7, SkF8, SkF9, SkF10, SkF11, SkF12,
    SkNumpad0, SkNumpad1, SkNumpad2, SkNumpad3, SkNumpad4, SkNumpad5, SkNumpad6,
    SkNumpad7, SkNumpad8, SkNumpad9, SkNumpadEnter, SkNumpadDot, SkNumpadPlus,
    SkNumpadMultiply, SkNumpadDivide, SkNumpadMinus, SkNumLock, SkComma, SkDot,
    SkSemiColon, SkApostrophe, SkSlash, SkBackslash, SkEqual, SkMinus, SkGrave,
    SkLeftBracket, SkRightBracket, SkCapsLock, SkPause, SkCtrl, SkShift, SkAlt,
    SkSpace, SkBackspace, SkTab, SkEsc, SkEnter, SkEnd, SkHome, SkIns, SkDelete,
    SkPageUp, SkPageDown, SkUp, SkDown, SkLeft, SkRight, SkUnknown1, SkUnknown2,
    SkUnknown3, SkNone, SkBreak, SkReset);
{$SCOPEDENUMS ON}

  TSuborKeys = set of TSuborKey;

  TNesKeyboardModel = (Subor, Dongda, Sonic, Keda, Kingwon);

  TSuborIndicators = record
    NumLock, CapsLock: Boolean;
  end;

  // Famicom expansion-port keyboard used by Subor educational computers.
  TSuborKeyboard = class
  private
    FHostKeys: TSuborKeys;
    FScreenKeys: TSuborKeys;
    // Keyboard lamps belong to the input device, independent of ROM snapshots.
    FIndicators: TSuborIndicators;
    FRow, FColumn: Byte;
    FEnabled, FConnected, FStrobe, FMemoryMapped: Boolean;
    FModel: TNesKeyboardModel;
    FSerialPort: Byte;
    procedure WriteSerialPort(Value: Byte);
    function ReadSerialPort: Byte;
    function MatrixBits(Row: Byte): Byte;
    function HostKey(Code: UInt32): TSuborKey;
    function ActiveKeys: Byte;
    procedure UpdateIndicators(const PreviousKeys: TSuborKeys);
  public
    procedure SerializeState(State: TNesStateArchive);
    procedure Reset;
    procedure SetHostKey(Code: UInt32; Pressed: Boolean);
    procedure SetScreenKeys(const Keys: TSuborKeys);
    function GetPressedKeys: TSuborKeys;
    property Indicators: TSuborIndicators read FIndicators;
    procedure Write(Value: UInt8);
    function Read: UInt8;
    procedure Clear;
    property Connected: Boolean read FConnected write FConnected;
    property MemoryMapped: Boolean read FMemoryMapped write FMemoryMapped;
    property Model: TNesKeyboardModel read FModel write FModel;
    function ReadMatrixRow(Row: Byte): Byte;
  end;

  // Change host configuration only while stopped or on the emulation thread.
  TZapper = class
  private
    FEnabled: Boolean;
    FTriggerPressed: Boolean;
    FSerialMouse: Boolean;
    FDrawingTablet: Boolean;
    FOnReadLight: TNesZapperLightCallback;
    FOnReadPosition: TFunc<TPoint>;
    FVsMode, FVsStrobe: Boolean;
    FVsShift: UInt8;
    procedure LatchVs(const Mask: TNesZapperMask);
  public
    class function ReadMask(const Mask: TNesZapperMask; const PixelX, PixelY: Integer): Boolean;
  public
    procedure SerializeState(State: TNesStateArchive);
    function Read(const Mask: TNesZapperMask): UInt8;
    procedure Reset;
    procedure WriteVs(Value: UInt8; const Mask: TNesZapperMask);
    function ReadVs(const Mask: TNesZapperMask): UInt8;
    // Selected by the cartridge; the host uses the same trigger and sensor API.
    property VsMode: Boolean read FVsMode write FVsMode;
    property Enabled: Boolean read FEnabled write FEnabled;
    property TriggerPressed: Boolean read FTriggerPressed write FTriggerPressed;
    property SerialMouse: Boolean read FSerialMouse write FSerialMouse;
    property DrawingTablet: Boolean read FDrawingTablet write FDrawingTablet;
    property OnReadLight: TNesZapperLightCallback read FOnReadLight write FOnReadLight;
    property OnReadPosition: TFunc<TPoint> read FOnReadPosition write FOnReadPosition;
  end;

  TController = class
  private
    FState: UInt8;
    FShift: UInt8;
    FStrobe: Boolean;
    FPowerPadEnabled: Boolean;
    FPowerPadState: UInt16;
    FPowerPadLowShift: UInt8;
    FPowerPadHighShift: UInt8;
    FSwapStartSelect: Boolean;
    procedure Latch(ExtraButtons: Byte = 0);
  public
    procedure SerializeState(State: TNesStateArchive);
    procedure SetButton(Button: TNesButton; Pressed: Boolean);
    function IsButtonPressed(Button: TNesButton): Boolean;
    procedure SetPowerPadButton(Button: Integer; Pressed: Boolean);
    function ReadFamilyTrainer(RowSelect: Byte; Mode: TFamilyTrainerMode): Byte;
    procedure Write(Value: UInt8; ExtraButtons: Byte = 0);
    function Read: UInt8;
    property PowerPadEnabled: Boolean read FPowerPadEnabled write FPowerPadEnabled;
    property SwapStartSelect: Boolean read FSwapStartSelect write FSwapStartSelect;
  end;

implementation

uses
  System.UITypes;

{ TSuborKeyboard }

procedure TSuborKeyboard.SerializeState(State: TNesStateArchive);
begin
  State.Field(FHostKeys, SizeOf(FHostKeys));
  State.Field(FScreenKeys, SizeOf(FScreenKeys));
  State.Field(FRow, SizeOf(FRow));
  State.Field(FColumn, SizeOf(FColumn));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FConnected, SizeOf(FConnected));
  if FModel <> TNesKeyboardModel.Subor then
    State.Field(FSerialPort, SizeOf(FSerialPort));
  State.Field(FStrobe, SizeOf(FStrobe));
end;

procedure TSuborKeyboard.Reset;
begin
  FSerialPort := 0;
  FRow := 0;
  FColumn := 0;
  FEnabled := False;
  FStrobe := False;
end;

procedure TSuborKeyboard.Clear;
begin
  FHostKeys := [];
  FScreenKeys := [];
end;

function TSuborKeyboard.HostKey(Code: UInt32): TSuborKey;
begin
  Result := SkNone;
  if (Code >= vkA) and (Code <= vkZ) then
    Exit(TSuborKey(Ord(SkA) + Integer(Code) - vkA));
  if (Code >= vk0) and (Code <= vk9) then
    Exit(TSuborKey(Ord(SkNum0) + Integer(Code) - vk0));
  if (Code >= vkF1) and (Code <= vkF12) then
    Exit(TSuborKey(Ord(SkF1) + Integer(Code) - vkF1));
  if (Code >= vkNumpad0) and (Code <= vkNumpad9) then
    Exit(TSuborKey(Ord(SkNumpad0) + Integer(Code) - vkNumpad0));
  case Code of
    vkCancel: // Ctrl+Break.
      Result := SkBreak;
    vkBack:
      Result := SkBackspace;
    vkTab:
      Result := SkTab;
    vkReturn:
      Result := SkEnter;
    vkShift:
      Result := SkShift;
    vkControl:
      Result := SkCtrl;
    vkMenu:
      Result := SkAlt;
    vkPause:
      Result := SkPause;
    vkCapital:
      Result := SkCapsLock;
    vkEscape:
      Result := SkEsc;
    vkSpace:
      Result := SkSpace;
    vkPrior:
      Result := SkPageUp;
    vkNext:
      Result := SkPageDown;
    vkEnd:
      Result := SkEnd;
    vkHome:
      Result := SkHome;
    vkLeft:
      Result := SkLeft;
    vkUp:
      Result := SkUp;
    vkRight:
      Result := SkRight;
    vkDown:
      Result := SkDown;
    vkInsert:
      Result := SkIns;
    vkDelete:
      Result := SkDelete;
    vkMultiply:
      Result := SkNumpadMultiply;
    vkAdd:
      Result := SkNumpadPlus;
    vkSubtract:
      Result := SkNumpadMinus;
    vkDecimal:
      Result := SkNumpadDot;
    vkDivide:
      Result := SkNumpadDivide;
    vkNumLock:
      Result := SkNumLock;
    vkSemicolon:
      Result := SkSemiColon;
    vkEqual:
      Result := SkEqual;
    vkComma:
      Result := SkComma;
    vkMinus:
      Result := SkMinus;
    vkPeriod:
      Result := SkDot;
    vkSlash:
      Result := SkSlash;
    vkTilde:
      Result := SkGrave;
    vkLeftBracket:
      Result := SkLeftBracket;
    vkBackslash:
      Result := SkBackslash;
    vkRightBracket:
      Result := SkRightBracket;
    vkQuote:
      Result := SkApostrophe;
  end;
end;

procedure TSuborKeyboard.SetHostKey(Code: UInt32; Pressed: Boolean);
begin
  var Key := HostKey(Code);
  if Key = SkNone then
    Exit;

  var PreviousKeys := GetPressedKeys;
  if Pressed then
    Include(FHostKeys, Key)
  else
    Exclude(FHostKeys, Key);
  UpdateIndicators(PreviousKeys);
end;

procedure TSuborKeyboard.UpdateIndicators(const PreviousKeys: TSuborKeys);
begin
  var NewKeys := GetPressedKeys - PreviousKeys;
  if SkNumLock in NewKeys then
    FIndicators.NumLock := not FIndicators.NumLock;
  if SkCapsLock in NewKeys then
    FIndicators.CapsLock := not FIndicators.CapsLock;
end;

function TSuborKeyboard.GetPressedKeys: TSuborKeys;
begin
  Result := FHostKeys + FScreenKeys;
end;

procedure TSuborKeyboard.SetScreenKeys(const Keys: TSuborKeys);
begin
  var PreviousKeys := GetPressedKeys;
  FScreenKeys := Keys;
  UpdateIndicators(PreviousKeys);
end;

function TSuborKeyboard.MatrixBits(Row: Byte): Byte;
const
  SuborMatrix: array[0..12, 0..7] of TSuborKey = (
    (SkNum4, SkG, SkF, SkC, SkF2, SkE, SkNum5, SkV),
    (SkNum2, SkD, SkS, SkEnd, SkF1, SkW, SkNum3, SkX),
    (SkIns, SkBackspace, SkPageDown, SkRight, SkF8, SkPageUp, SkDelete, SkHome),
    (SkNum9, SkI, SkL, SkComma, SkF5, SkO, SkNum0, SkDot),
    (SkRightBracket, SkEnter, SkUp, SkLeft, SkF7, SkLeftBracket, SkBackslash, SkDown),
    (SkQ, SkCapsLock, SkZ, SkPause, SkEsc, SkA, SkNum1, SkCtrl),
    (SkNum7, SkY, SkK, SkM, SkF4, SkU, SkNum8, SkJ),
    (SkMinus, SkSemiColon, SkApostrophe, SkSlash, SkF6, SkP, SkEqual, SkShift),
    (SkT, SkH, SkN, SkSpace, SkF3, SkR, SkNum6, SkB),
    (SkNumpad6, SkNumpadEnter, SkNumpad4, SkNumpad8, SkNone, SkUnknown1, SkUnknown2, SkUnknown3),
    (SkBreak, SkNumpad4, SkNumpad7, SkF11, SkF12, SkNumpad1, SkNumpad2, SkNumpad8),
    (SkNumpadMinus, SkNumpadPlus, SkNumpadMultiply, SkNumpad9, SkF10, SkNumpad5, SkNumpadDivide, SkNumLock),
    (SkGrave, SkNumpad6, SkAlt, SkTab, SkF9, SkNumpad3, SkNumpadDot, SkNumpad0));
  DongdaMatrix: array[0..12, 0..7] of TSuborKey = (
    (SkEsc, SkSpace, SkAlt, SkCapsLock, SkCtrl, SkGrave, SkTab, SkShift),
    (SkF6, SkF7, SkF5, SkF4, SkF8, SkF2, SkF1, SkF3),
    (SkEqual, SkNumpad0, SkDot, SkA, SkEnter, SkNum1, SkQ, SkZ),
    (SkNone, SkNumpad3, SkNumpad6, SkS, SkNumpad9, SkNum2, SkW, SkX),
    (SkSlash, SkNumpad2, SkNumpad5, SkD, SkNumpad8, SkNum3, SkE, SkC),
    (SkBreak, SkNumpad1, SkNumpad4, SkF, SkNumpad7, SkNum4, SkR, SkV),
    (SkBackspace, SkBackslash, SkNumpadEnter, SkG, SkRightBracket, SkNum5, SkT, SkB),
    (SkNum9, SkNumpadDot, SkL, SkK, SkO, SkNum8, SkI, SkComma),
    (SkNum0, SkSlash, SkSemiColon, SkJ, SkP, SkNum7, SkU, SkM),
    (SkMinus, SkNumpadMinus, SkApostrophe, SkH, SkLeftBracket, SkNum6, SkY, SkN),
    (SkF11, SkF12, SkF10, SkNone, SkMinus, SkF9, SkNone, SkNone),
    (SkUp, SkRight, SkDown, SkPageDown, SkLeft, SkNumpadMultiply, SkNumpadMinus, SkNumpadPlus),
    (SkIns, SkNumpad1, SkPageUp, SkHome, SkDelete, SkEnd, SkNumpadDivide, SkNumLock));
  // The Sonic board drives the keyboard's serial data into $4017 D6.
  SonicMatrix: array[0..10, 0..7] of TSuborKey = (
    (SkEsc, SkSpace, SkAlt, SkCapsLock, SkCtrl, SkGrave, SkTab, SkShift),
    (SkF6, SkF7, SkF5, SkF4, SkF8, SkF2, SkF1, SkF3),
    (SkNumpadPlus, SkNumpad0, SkNumpadDot, SkA, SkNumpadEnter, SkNum1, SkQ, SkZ),
    (SkNumpadMultiply, SkNumpad3, SkNumpad6, SkS, SkNumpad9, SkNum2, SkW, SkX),
    (SkNumpadDivide, SkNumpad2, SkNumpad5, SkD, SkNumpad8, SkNum3, SkE, SkC),
    (SkNumLock, SkNumpad1, SkNumpad4, SkF, SkNumpad7, SkNum4, SkR, SkV),
    (SkBackspace, SkBackslash, SkEnter, SkG, SkRightBracket, SkNum5, SkT, SkB),
    (SkNum9, SkDot, SkL, SkK, SkO, SkNum8, SkI, SkComma),
    (SkNum0, SkSlash, SkSemiColon, SkJ, SkP, SkNum7, SkU, SkM),
    (SkMinus, SkEqual, SkApostrophe, SkH, SkLeftBracket, SkNum6, SkY, SkN),
    (SkF11, SkF12, SkF10, SkNone, SkNumpadMinus, SkF9, SkNone, SkNone));
  KedaMatrix: array[0..10, 0..7] of TSuborKey = (
    (SkGrave, SkTab, SkCapsLock, SkShift, SkNum1, SkQ, SkA, SkZ),
    (SkNum2, SkW, SkS, SkX, SkNum3, SkE, SkD, SkC),
    (SkNum4, SkR, SkF, SkV, SkNum5, SkT, SkG, SkB),
    (SkNum6, SkY, SkH, SkN, SkNum7, SkU, SkJ, SkM),
    (SkNum8, SkI, SkK, SkComma, SkNum9, SkO, SkL, SkDot),
    (SkNum0, SkP, SkSemiColon, SkSlash, SkMinus, SkLeftBracket, SkApostrophe, SkBackslash),
    (SkEqual, SkRightBracket, SkEnter, SkBackspace, SkNumpadMultiply, SkHome, SkLeft, SkEnd),
    (SkNone, SkUp, SkNone, SkDown, SkEsc, SkNone, SkRight, SkNone),
    (SkNone, SkNone, SkSpace, SkIns, SkNumpadEnter, SkNone, SkNumpadPlus, SkNumpadMinus),
    (SkF1, SkF2, SkF3, SkF4, SkF5, SkF6, SkF7, SkF8),
    (SkNone, SkNone, SkF12, SkF11, SkNone, SkNumpadMultiply, SkNone, SkNone));
  KingwonMatrix: array[0..9, 0..7] of TSuborKey = (
    (SkZ, SkA, SkQ, SkNum1, SkShift, SkCapsLock, SkTab, SkGrave),
    (SkC, SkD, SkE, SkNum3, SkX, SkS, SkW, SkNum2),
    (SkB, SkG, SkT, SkNum5, SkV, SkF, SkR, SkNum4),
    (SkM, SkJ, SkU, SkNum7, SkN, SkH, SkY, SkNum6),
    (SkDot, SkL, SkO, SkNum9, SkComma, SkK, SkI, SkNum8),
    (SkBackslash, SkApostrophe, SkLeftBracket, SkMinus, SkSlash, SkSemiColon, SkP, SkNum0),
    (SkEnd, SkLeft, SkHome, SkNone, SkBackspace, SkEnter, SkRightBracket, SkEqual),
    (SkPageDown, SkRight, SkPageUp, SkEsc, SkDown, SkNone, SkUp, SkNone),
    (SkDelete, SkNumpadPlus, SkNumpadMultiply, SkNumpadEnter, SkIns, SkSpace, SkAlt, SkCtrl),
    (SkF8, SkF7, SkF6, SkF5, SkF4, SkF3, SkF2, SkF1));
begin
  Result := 0;
  var Keys := (FHostKeys + FScreenKeys) - [SkNone];
  for var Column := 0 to 7 do
  begin
    var Key := SkNone;
    case FModel of
      TNesKeyboardModel.Subor:
        if Row <= High(SuborMatrix) then
          Key := SuborMatrix[Row, Column];
      TNesKeyboardModel.Dongda:
        if Row <= High(DongdaMatrix) then
          Key := DongdaMatrix[Row, Column];
      TNesKeyboardModel.Sonic:
        if Row <= High(SonicMatrix) then
          Key := SonicMatrix[Row, Column];
      TNesKeyboardModel.Keda:
        if Row <= High(KedaMatrix) then
          Key := KedaMatrix[Row, Column];
      TNesKeyboardModel.Kingwon:
        if Row <= High(KingwonMatrix) then
          Key := KingwonMatrix[Row, Column];
    end;
    if Key in Keys then
      Result := Result or (1 shl Column);
  end;
  if (FModel = TNesKeyboardModel.Subor) and (Row = 9) then
    Result := Result or $10;
end;

function TSuborKeyboard.ActiveKeys: Byte;
begin
  Result := (MatrixBits(FRow) shr (FColumn * 4)) and $0F;
end;

function TSuborKeyboard.ReadMatrixRow(Row: Byte): Byte;
begin
  if not FConnected then
    Exit($FF);
  Result := not MatrixBits(Row mod 13);
end;

procedure TSuborKeyboard.WriteSerialPort(Value: Byte);
begin
  var Rising := Value and not FSerialPort;
  var Falling := FSerialPort and not Value;
  if FModel = TNesKeyboardModel.Kingwon then
  begin
    if (Value and 4) = 0 then
      Exit;
    if (Falling and 2) <> 0 then
    begin
      FRow := 0;
      FColumn := 0;
    end
    else if (Falling and 1) <> 0 then
    begin
      FRow := (FRow + 1) mod 13;
      FColumn := 0;
    end;
  end
  else
  begin
    var RowCount := 13;
    case FModel of
      TNesKeyboardModel.Keda:
        RowCount := 11;
      TNesKeyboardModel.Sonic:
        RowCount := 16;
    end;
    if (Rising and 2) <> 0 then
      FRow := 0;
    if (Falling and 1) <> 0 then
      FColumn := 0;
    if (Falling and 4) <> 0 then
      FRow := (FRow + 1) mod RowCount;
  end;
  FSerialPort := Value;
end;

function TSuborKeyboard.ReadSerialPort: Byte;
begin
  var Bits := MatrixBits(FRow);
  case FModel of
    TNesKeyboardModel.Kingwon:
      Result := Ord((Bits and (1 shl FColumn)) = 0) shl 1;
    TNesKeyboardModel.Sonic:
      Result := Ord((Bits and ($80 shr FColumn)) <> 0) shl 6;
  else
    Result := Ord((Bits and ($80 shr FColumn)) <> 0) shl 1;
  end;
  FColumn := (FColumn + 1) and 7;
end;

procedure TSuborKeyboard.Write(Value: UInt8);
begin
  if not FConnected or FMemoryMapped then
    Exit;

  if FModel <> TNesKeyboardModel.Subor then
  begin
    WriteSerialPort(Value);
    Exit;
  end;
  var NewStrobe := (Value and 1) <> 0;
  // A falling strobe latches a new matrix scan, starting at row zero.  Without
  // this reset, a new query can resume in an old row and look like a held key.
  if FStrobe and not NewStrobe then
  begin
    FRow := 0;
    FColumn := 0;
  end;
  FStrobe := NewStrobe;
  var PreviousColumn := FColumn;
  FColumn := (Value shr 1) and 1;
  FEnabled := (Value and 4) <> 0;
  if FEnabled and (FColumn = 0) and (PreviousColumn = 1) then
    FRow := (FRow + 1) mod 13;
end;

function TSuborKeyboard.Read: UInt8;
begin
  if not FConnected or FMemoryMapped then
    Exit(0);
  if FModel <> TNesKeyboardModel.Subor then
    Exit(ReadSerialPort);
  if not FEnabled then
    Exit($1E);

  Result := (not (ActiveKeys shl 1)) and $1E;
end;

class function TZapper.ReadMask(const Mask: TNesZapperMask; const PixelX, PixelY: Integer): Boolean;
begin
  Result := False;
  if (PixelX < Low(Mask)) or (PixelX > High(Mask)) then
    Exit;
  if (PixelY < Low(Mask[PixelX])) or (PixelY > High(Mask[PixelX])) then
    Exit;

  Result := Mask[PixelX, PixelY] <> 0;
end;

procedure TZapper.SerializeState(State: TNesStateArchive);
begin
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FTriggerPressed, SizeOf(FTriggerPressed));
  if State.Version >= 22 then
  begin
    State.Field(FVsStrobe, SizeOf(FVsStrobe));
    State.Field(FVsShift, SizeOf(FVsShift));
  end
  else if State.Loading then
  begin
    FVsStrobe := False;
    FVsShift := 0;
  end;
  // The callback and cartridge-selected protocol are never serialized.
end;

procedure TZapper.Reset;
begin
  FTriggerPressed := False;
  FVsStrobe := False;
  FVsShift := 0;
end;

procedure TZapper.LatchVs(const Mask: TNesZapperMask);
begin
  // NESdev: 0,0,0,0,1,0,light,trigger, transmitted least significant bit first.
  FVsShift := $10;
  if Assigned(FOnReadLight) then
    if FOnReadLight(Mask) then
      FVsShift := FVsShift or $40;
  if FTriggerPressed then
    FVsShift := FVsShift or $80;
end;

procedure TZapper.WriteVs(Value: UInt8; const Mask: TNesZapperMask);
begin
  if FVsStrobe or ((Value and 1) <> 0) then
    LatchVs(Mask);
  FVsStrobe := (Value and 1) <> 0;
end;

function TZapper.ReadVs(const Mask: TNesZapperMask): UInt8;
begin
  if FVsStrobe then
    LatchVs(Mask);
  Result := FVsShift and 1;
  if not FVsStrobe then
    FVsShift := FVsShift shr 1;
end;

function TZapper.Read(const Mask: TNesZapperMask): UInt8;
begin
  Result := 0;
  if not FEnabled then
    Exit;

  Result := $08;
  if Assigned(FOnReadLight) then
    if FOnReadLight(Mask) then
      Result := 0;
  if FTriggerPressed then
    Result := Result or $10;
end;

procedure TController.SerializeState(State: TNesStateArchive);
begin
  State.Field(FState, SizeOf(FState));
  State.Field(FShift, SizeOf(FShift));
  State.Field(FStrobe, SizeOf(FStrobe));
  State.Field(FPowerPadEnabled, SizeOf(FPowerPadEnabled));
  State.Field(FPowerPadState, SizeOf(FPowerPadState));
  State.Field(FPowerPadLowShift, SizeOf(FPowerPadLowShift));
  State.Field(FPowerPadHighShift, SizeOf(FPowerPadHighShift));
end;

procedure TController.Latch(ExtraButtons: Byte);
const
  LOW_BUTTONS: array[0..7] of Integer = (2, 1, 5, 9, 6, 10, 11, 7);
  HIGH_BUTTONS: array[0..3] of Integer = (4, 3, 12, 8);
begin
  FShift := FState or ExtraButtons;
  if FSwapStartSelect then
    FShift := (FShift and $F3) or ((FShift and $04) shl 1) or ((FShift and $08) shr 1);
  FPowerPadLowShift := 0;
  FPowerPadHighShift := $F0;
  for var i := 0 to High(LOW_BUTTONS) do
    if (FPowerPadState and (UInt16(1) shl (LOW_BUTTONS[i] - 1))) <> 0 then
      FPowerPadLowShift := FPowerPadLowShift or (UInt8(1) shl i);
  for var i := 0 to High(HIGH_BUTTONS) do
    if (FPowerPadState and (UInt16(1) shl (HIGH_BUTTONS[i] - 1))) <> 0 then
      FPowerPadHighShift := FPowerPadHighShift or (UInt8(1) shl i);
end;

procedure TController.SetButton(Button: TNesButton; Pressed: Boolean);
const
  MASKS: array[TNesButton] of UInt8 = ($01, $02, $04, $08, $10, $20, $40, $80);
begin
  if Pressed then
    FState := FState or MASKS[Button]
  else
    FState := FState and not MASKS[Button];

  if FStrobe then
    Latch;
end;

function TController.IsButtonPressed(Button: TNesButton): Boolean;
begin
  Result := (FState and (UInt8(1) shl Ord(Button))) <> 0;
end;

function TController.ReadFamilyTrainer(RowSelect: Byte; Mode: TFamilyTrainerMode): Byte;
begin
  var Columns: Byte := 0;
  if (RowSelect and 4) = 0 then
    Columns := FPowerPadState and 15;
  if (RowSelect and 2) = 0 then
    Columns := Columns or ((FPowerPadState shr 4) and 15);
  if (RowSelect and 1) = 0 then
    Columns := Columns or ((FPowerPadState shr 8) and 15);

  // With side B facing up, the left column drives D4.
  if Mode = TFamilyTrainerMode.ftSideB then
    Columns := ((Columns and 1) shl 3) or ((Columns and 2) shl 1) or
      ((Columns and 4) shr 1) or ((Columns and 8) shr 3);
  Result := (Columns xor 15) shl 1;
end;

procedure TController.SetPowerPadButton(Button: Integer; Pressed: Boolean);
begin
  if (Button < 1) or (Button > 12) then
    Exit;

  var Mask := UInt16(1) shl (Button - 1);
  if Pressed then
    FPowerPadState := FPowerPadState or Mask
  else
    FPowerPadState := FPowerPadState and not Mask;
  if FStrobe then
    Latch;
end;

procedure TController.Write(Value: UInt8; ExtraButtons: Byte);
begin
  var NewStrobe: Boolean := (Value and 1) <> 0;
  if FStrobe and not NewStrobe then
    Latch(ExtraButtons);
  FStrobe := NewStrobe;
  if FStrobe then
    Latch(ExtraButtons);
end;

function TController.Read: UInt8;
begin
  if FStrobe then
    Latch;
  Result := FShift and 1;
  FShift := (FShift shr 1) or $80;
  if FPowerPadEnabled then
  begin
    Result := Result or ((FPowerPadLowShift and 1) shl 3)
      or ((FPowerPadHighShift and 1) shl 4);
    FPowerPadLowShift := (FPowerPadLowShift shr 1) or $80;
    FPowerPadHighShift := (FPowerPadHighShift shr 1) or $80;
  end;
end;

end.

