unit NES.Controller;

interface

uses
  NES.State, NES.Types;

{$SCOPEDENUMS ON}

type
  TNesButton = (A, B, Select, Start, Up, Down, Left, Right);

  TNesButtons = set of TNesButton;

  TPowerPadButton = 1..12;

  TPowerPadButtons = set of TPowerPadButton;

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
    FEnabled, FConnected, FStrobe: Boolean;
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
  end;

  // Change host configuration only while stopped or on the emulation thread.
  TZapper = class
  private
    FEnabled: Boolean;
    FTriggerPressed: Boolean;
    FOnReadLight: TNesZapperLightCallback;
  public
    class function ReadMask(const Mask: TNesZapperMask; const PixelX, PixelY: Integer): Boolean;
  public
    procedure SerializeState(State: TNesStateArchive);
    function Read(const Mask: TNesZapperMask): UInt8;
    property Enabled: Boolean read FEnabled write FEnabled;
    property TriggerPressed: Boolean read FTriggerPressed write FTriggerPressed;
    property OnReadLight: TNesZapperLightCallback read FOnReadLight write FOnReadLight;
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
    procedure Latch;
  public
    procedure SerializeState(State: TNesStateArchive);
    procedure SetButton(Button: TNesButton; Pressed: Boolean);
    function IsButtonPressed(Button: TNesButton): Boolean;
    procedure SetPowerPadButton(Button: Integer; Pressed: Boolean);
    procedure Write(Value: UInt8);
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
  State.Field(FStrobe, SizeOf(FStrobe));
end;

procedure TSuborKeyboard.Reset;
begin
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

function TSuborKeyboard.ActiveKeys: Byte;
const
  MATRIX: array[0..12, 0..7] of TSuborKey = (
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
begin
  Result := 0;
  var Keys := FHostKeys + FScreenKeys;
  var Base := FColumn * 4;
  for var i := 0 to 3 do
    if MATRIX[FRow, Base + i] in Keys then
      Result := Result or (1 shl i);
  if (FRow = 9) and (FColumn = 1) then
    Result := Result or 1;
end;

procedure TSuborKeyboard.Write(Value: UInt8);
begin
  if not FConnected then
    Exit;
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
  if not FConnected then
    Exit(0);
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
  // The callback belongs to the host and is never serialized.
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

procedure TController.Latch;
const
  LOW_BUTTONS: array[0..7] of Integer = (2, 1, 5, 9, 6, 10, 11, 7);
  HIGH_BUTTONS: array[0..3] of Integer = (4, 3, 12, 8);
begin
  FShift := FState;
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

procedure TController.Write(Value: UInt8);
begin
  var NewStrobe: Boolean := (Value and 1) <> 0;
  if FStrobe and not NewStrobe then
    Latch;
  FStrobe := NewStrobe;
  if FStrobe then
    Latch;
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

