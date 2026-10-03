unit NES.FamicomKeyboardDevice;

interface

uses
  NES.State;

type
  TFamicomKey = (FkNone,
    FkA, FkB, FkC, FkD, FkE, FkF, FkG, FkH, FkI, FkJ, FkK, FkL, FkM,
    FkN, FkO, FkP, FkQ, FkR, FkS, FkT, FkU, FkV, FkW, FkX, FkY, FkZ,
    FkNum0, FkNum1, FkNum2, FkNum3, FkNum4, FkNum5, FkNum6, FkNum7, FkNum8, FkNum9,
    FkReturn, FkSpace, FkDel, FkIns, FkEsc, FkCtrl, FkRightShift, FkLeftShift,
    FkRightBracket, FkLeftBracket, FkUp, FkDown, FkLeft, FkRight,
    FkDot, FkComma, FkColon, FkSemiColon, FkUnderscore, FkSlash, FkMinus, FkCaret,
    FkF1, FkF2, FkF3, FkF4, FkF5, FkF6, FkF7, FkF8,
    FkYen, FkStop, FkAtSign, FkGrph, FkClrHome, FkKana);

  TFamicomKeys = set of TFamicomKey;

  // HVC-007: nine populated rows and one empty row on a decade counter.
  TFamicomKeyboard = class
  private
    FHostKeys, FScreenKeys: TFamicomKeys;
    FRow, FColumn: Byte;
    FEnabled, FConnected: Boolean;
    function HostKey(Code: UInt32): TFamicomKey;
    function ActiveKeys: Byte;
  public
    procedure SerializeState(State: TNesStateArchive);
    procedure Reset;
    procedure Clear;
    procedure SetHostKey(Code: UInt32; Pressed: Boolean);
    procedure SetScreenKeys(const Keys: TFamicomKeys);
    function GetPressedKeys: TFamicomKeys;
    procedure Write(Value: UInt8);
    function Read: UInt8;
    property Connected: Boolean read FConnected write FConnected;
  end;

implementation

uses
  System.UITypes;

procedure TFamicomKeyboard.SerializeState(State: TNesStateArchive);
begin
  State.Field(FHostKeys, SizeOf(FHostKeys));
  State.Field(FScreenKeys, SizeOf(FScreenKeys));
  State.Field(FRow, SizeOf(FRow));
  State.Field(FColumn, SizeOf(FColumn));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FConnected, SizeOf(FConnected));
end;

procedure TFamicomKeyboard.Reset;
begin
  FRow := 0;
  FColumn := 0;
  FEnabled := False;
end;

procedure TFamicomKeyboard.Clear;
begin
  FHostKeys := [];
  FScreenKeys := [];
end;

function TFamicomKeyboard.HostKey(Code: UInt32): TFamicomKey;
begin
  Result := FkNone;
  if (Code >= vkA) and (Code <= vkZ) then
    Exit(TFamicomKey(Ord(FkA) + Integer(Code) - vkA));
  if (Code >= vk0) and (Code <= vk9) then
    Exit(TFamicomKey(Ord(FkNum0) + Integer(Code) - vk0));
  if (Code >= vkF1) and (Code <= vkF8) then
    Exit(TFamicomKey(Ord(FkF1) + Integer(Code) - vkF1));
  case Code of
    vkReturn:
      Result := FkReturn;
    vkSpace:
      Result := FkSpace;
    vkDelete, vkBack:
      Result := FkDel;
    vkInsert:
      Result := FkIns;
    vkEscape:
      Result := FkEsc;
    vkControl, vkLControl, vkRControl:
      Result := FkCtrl;
    vkShift, vkLShift:
      Result := FkLeftShift;
    vkRShift:
      Result := FkRightShift;
    vkLeftBracket:
      Result := FkLeftBracket;
    vkRightBracket:
      Result := FkRightBracket;
    vkUp:
      Result := FkUp;
    vkDown:
      Result := FkDown;
    vkLeft:
      Result := FkLeft;
    vkRight:
      Result := FkRight;
    vkPeriod:
      Result := FkDot;
    vkComma:
      Result := FkComma;
    vkQuote:
      Result := FkColon;
    vkSemicolon:
      Result := FkSemiColon;
    vkOem102:
      Result := FkUnderscore;
    vkSlash:
      Result := FkSlash;
    vkMinus:
      Result := FkMinus;
    vkEqual:
      Result := FkCaret;
    vkBackslash:
      Result := FkYen;
    vkPause, vkCancel:
      Result := FkStop;
    vkTilde:
      Result := FkAtSign;
    vkMenu, vkLMenu, vkRMenu:
      Result := FkGrph;
    vkHome:
      Result := FkClrHome;
    vkCapital, vkKana:
      Result := FkKana;
  end;
end;

procedure TFamicomKeyboard.SetHostKey(Code: UInt32; Pressed: Boolean);
begin
  var Key := HostKey(Code);
  if Key = FkNone then
    Exit;
  if Pressed then
    Include(FHostKeys, Key)
  else
    Exclude(FHostKeys, Key);
end;

procedure TFamicomKeyboard.SetScreenKeys(const Keys: TFamicomKeys);
begin
  FScreenKeys := Keys - [FkNone];
end;

function TFamicomKeyboard.GetPressedKeys: TFamicomKeys;
begin
  Result := FHostKeys + FScreenKeys;
end;

function TFamicomKeyboard.ActiveKeys: Byte;
const
  Matrix: array[0..8, 0..7] of TFamicomKey = (
    (FkF8, FkReturn, FkLeftBracket, FkRightBracket, FkKana, FkRightShift, FkYen, FkStop),
    (FkF7, FkAtSign, FkColon, FkSemiColon, FkUnderscore, FkSlash, FkMinus, FkCaret),
    (FkF6, FkO, FkL, FkK, FkDot, FkComma, FkP, FkNum0),
    (FkF5, FkI, FkU, FkJ, FkM, FkN, FkNum9, FkNum8),
    (FkF4, FkY, FkG, FkH, FkB, FkV, FkNum7, FkNum6),
    (FkF3, FkT, FkR, FkD, FkF, FkC, FkNum5, FkNum4),
    (FkF2, FkW, FkS, FkA, FkX, FkZ, FkE, FkNum3),
    (FkF1, FkEsc, FkQ, FkCtrl, FkLeftShift, FkGrph, FkNum1, FkNum2),
    (FkClrHome, FkUp, FkRight, FkLeft, FkDown, FkSpace, FkDel, FkIns));
begin
  Result := 0;
  if FRow >= 9 then
    Exit;
  var Keys := GetPressedKeys;
  for var I := 0 to 3 do
    if Matrix[FRow, FColumn * 4 + I] in Keys then
      Result := Result or (1 shl I);
end;

procedure TFamicomKeyboard.Write(Value: UInt8);
begin
  if not FConnected then
    Exit;
  var PreviousColumn := FColumn;
  FColumn := (Value shr 1) and 1;
  if (FColumn = 0) and (PreviousColumn = 1) then
    FRow := (FRow + 1) mod 10;
  if (Value and 1) <> 0 then
    FRow := 0;
  FEnabled := (Value and 4) <> 0;
end;

function TFamicomKeyboard.Read: UInt8;
begin
  if not FConnected or not FEnabled then
    Exit(0);
  Result := (not (ActiveKeys shl 1)) and $1E;
end;

end.

