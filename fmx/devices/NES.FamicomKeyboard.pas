unit NES.FamicomKeyboard;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.FamicomKeyboardDevice;

type
  TFamicomKey = NES.FamicomKeyboardDevice.TFamicomKey;

  TFamicomKeys = NES.FamicomKeyboardDevice.TFamicomKeys;

  TNesFamicomKeyboard = class(TControl)
  private
    type
      TVisualKey = record
        Key: TFamicomKey;
        Bounds: TRectF;
      end;
  private
    FContacts: TDictionary<NativeInt, TFamicomKey>;
    FKeys, FCoreKeys: TFamicomKeys;
    FOnChange: TNotifyEvent;
    FNativeInput: TObject;
    FVisualKeys: TArray<TVisualKey>;
    procedure AddKey(Key: TFamicomKey; Row, Column, Span: Single);
    procedure LayoutKeys;
    function KeyAt(const Point: TPointF): TFamicomKey;
    procedure UpdateKeys;
    procedure SetCoreKeys(const Value: TFamicomKeys);
    function GetHighlightedKeys: TFamicomKeys;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure EnabledChanged; override;
    procedure VisibleChanged; override;
    procedure AncestorVisibleChanged(const Visible: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class function PreferredHeight(AvailableWidth, AvailableHeight: Single): Single; static;
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF);
    procedure PointerMove(Id: NativeInt; const Point: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll;
    function ButtonBounds(Key: TFamicomKey): TRectF;
    property Keys: TFamicomKeys read FKeys;
    property CoreKeys: TFamicomKeys read FCoreKeys write SetCoreKeys;
    property HighlightedKeys: TFamicomKeys read GetHighlightedKeys;
  published
    property Align;
    property Anchors;
    property Enabled;
    property Margins;
    property Position;
    property Size;
    property Visible;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Graphics
  {$IFDEF ANDROID}
    , RM.TouchInput.Android
  {$ENDIF};

procedure TNesFamicomKeyboard.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

constructor TNesFamicomKeyboard.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, TFamicomKey>.Create;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 800, 300);
  LayoutKeys;
end;

destructor TNesFamicomKeyboard.Destroy;
begin
  FreeAndNil(FNativeInput);
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

class function TNesFamicomKeyboard.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Max(0, Min(AvailableWidth * 0.375, AvailableHeight * 0.48));
end;

procedure TNesFamicomKeyboard.AddKey(Key: TFamicomKey; Row, Column, Span: Single);
begin
  // Units describe the photographed stagger and widths. Scale without distortion.
  var U := Max(0, Min(Width / 20.5, Height / 7.5));
  var X := (Width - U * 20.5) / 2 + U * 0.5;
  var Y := (Height - U * 7.5) / 2 + U * 0.75;
  var Gap := U * 0.045;
  var I := Length(FVisualKeys);
  SetLength(FVisualKeys, I + 1);
  FVisualKeys[I].Key := Key;
  FVisualKeys[I].Bounds := RectF(X + Column * U + Gap, Y + Row * U + Gap,
      X + (Column + Span) * U - Gap, Y + (Row + 1) * U - Gap);
end;

procedure TNesFamicomKeyboard.LayoutKeys;
const
  NumberRow: array[0..13] of TFamicomKey = (FkNum1, FkNum2, FkNum3, FkNum4,
    FkNum5, FkNum6, FkNum7, FkNum8, FkNum9, FkNum0, FkMinus, FkCaret, FkYen, FkStop);
  UpperRow: array[0..12] of TFamicomKey = (FkEsc, FkQ, FkW, FkE, FkR, FkT,
    FkY, FkU, FkI, FkO, FkP, FkAtSign, FkLeftBracket);
  HomeRow: array[0..13] of TFamicomKey = (FkCtrl, FkA, FkS, FkD, FkF, FkG,
    FkH, FkJ, FkK, FkL, FkSemiColon, FkColon, FkRightBracket, FkKana);
  LowerRow: array[0..10] of TFamicomKey = (FkZ, FkX, FkC, FkV, FkB, FkN,
    FkM, FkComma, FkDot, FkSlash, FkUnderscore);
begin
  SetLength(FVisualKeys, 0);
  for var I := 0 to 7 do
    AddKey(TFamicomKey(Ord(FkF1) + I), 0, I * 2, 2);
  for var I := 0 to High(NumberRow) do
    AddKey(NumberRow[I], 1, I + 0.5, 1);
  for var I := 0 to High(UpperRow) do
    AddKey(UpperRow[I], 2, I, 1);
  AddKey(FkReturn, 2, 13, 2);
  for var I := 0 to High(HomeRow) do
    AddKey(HomeRow[I], 3, I + 0.25, 1);
  AddKey(FkLeftShift, 4, -0.25, 2);
  for var I := 0 to High(LowerRow) do
    AddKey(LowerRow[I], 4, I + 1.75, 1);
  AddKey(FkRightShift, 4, 12.75, 2);
  AddKey(FkGrph, 5, 2.75, 1);
  AddKey(FkSpace, 5, 3.75, 8);
  AddKey(FkClrHome, 1.5, 15.5, 1);
  AddKey(FkIns, 1.5, 16.5, 1);
  AddKey(FkDel, 1.5, 17.5, 1);
  AddKey(FkUp, 2.5, 16, 2);
  AddKey(FkLeft, 3.5, 15, 2);
  AddKey(FkRight, 3.5, 17, 2);
  AddKey(FkDown, 4.5, 16, 2);
end;

function TNesFamicomKeyboard.KeyAt(const Point: TPointF): TFamicomKey;
begin
  Result := FkNone;
  if not LocalRect.Contains(Point) then
    Exit;
  for var K in FVisualKeys do
    if K.Bounds.Contains(Point) then
      Exit(K.Key);
end;

function TNesFamicomKeyboard.ButtonBounds(Key: TFamicomKey): TRectF;
begin
  Result := TRectF.Empty;
  for var K in FVisualKeys do
    if K.Key = Key then
      Exit(K.Bounds);
end;

function TNesFamicomKeyboard.GetHighlightedKeys: TFamicomKeys;
begin
  Result := FKeys + FCoreKeys;
end;

procedure TNesFamicomKeyboard.SetCoreKeys(const Value: TFamicomKeys);
begin
  var NewKeys := Value - [FkNone];
  if NewKeys = FCoreKeys then
    Exit;
  FCoreKeys := NewKeys;
  Repaint;
end;

procedure TNesFamicomKeyboard.UpdateKeys;
begin
  var NewKeys: TFamicomKeys := [];
  for var Key in FContacts.Values do
    if Key <> FkNone then
      Include(NewKeys, Key);
  if NewKeys = FKeys then
    Exit;
  FKeys := NewKeys;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesFamicomKeyboard.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;
  // Retain blank contacts so sliding out and back into a key works.
  FContacts.AddOrSetValue(Id, KeyAt(Point));
  UpdateKeys;
end;

procedure TNesFamicomKeyboard.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;
  if not FContacts.ContainsKey(Id) then
    Exit;
  FContacts.AddOrSetValue(Id, KeyAt(Point));
  UpdateKeys;
end;

procedure TNesFamicomKeyboard.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TNesFamicomKeyboard.ReleaseAll;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
  FCoreKeys := [];
  UpdateKeys;
  Repaint;
end;

procedure TNesFamicomKeyboard.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
  Repaint;
end;

procedure TNesFamicomKeyboard.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
  Repaint;
end;

procedure TNesFamicomKeyboard.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesFamicomKeyboard.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

function KeyCaption(Key: TFamicomKey): string;
const
  Kana: array[0..25] of string = ('サ', 'ト', 'ツ', 'ス', 'ク', 'セ', 'ソ', 'ハ',
    'プ', 'ヒ', 'フ', 'ヘ', 'ユ', 'ヤ', 'ペ', 'ポ', 'カ', 'ケ', 'シ', 'コ',
    'ピ', 'テ', 'キ', 'チ', 'パ', 'タ');
begin
  // Latin and kana legends describe keycaps; the ROM handles text conversion.
  if Key in [FkA..FkZ] then
    Exit(Char(Ord('A') + Ord(Key) - Ord(FkA)) + sLineBreak + Kana[Ord(Key) - Ord(FkA)]);
  if Key in [FkF1..FkF8] then
    Exit('F' + IntToStr(Ord(Key) - Ord(FkF1) + 1));
  case Key of
    FkNum1:
      Result := '1 !' + sLineBreak + 'ア';
    FkNum2:
      Result := '2 "' + sLineBreak + 'イ';
    FkNum3:
      Result := '3 #' + sLineBreak + 'ウ';
    FkNum4:
      Result := '4 $' + sLineBreak + 'エ';
    FkNum5:
      Result := '5 %' + sLineBreak + 'オ';
    FkNum6:
      Result := '6 &' + sLineBreak + 'ナ';
    FkNum7:
      Result := '7 ''' + sLineBreak + 'ニ';
    FkNum8:
      Result := '8 (' + sLineBreak + 'ヌ';
    FkNum9:
      Result := '9 )' + sLineBreak + 'ネ';
    FkNum0:
      Result := '0' + sLineBreak + 'ノ';
    FkReturn:
      Result := 'RETURN';
    FkSpace:
      Result := '';
    FkEsc:
      Result := 'ESC';
    FkCtrl:
      Result := 'CTR';
    FkLeftShift, FkRightShift:
      Result := 'SHIFT';
    FkClrHome:
      Result := 'CLR' + sLineBreak + 'HOME';
    FkIns:
      Result := 'INS';
    FkDel:
      Result := 'DEL';
    FkStop:
      Result := 'STOP';
    FkKana:
      Result := 'カナ';
    FkGrph:
      Result := 'GRPH';
    FkUp:
      Result := '▲';
    FkDown:
      Result := '▼';
    FkLeft:
      Result := '◀';
    FkRight:
      Result := '▶';
    FkAtSign:
      Result := '@' + sLineBreak + 'レ';
    FkLeftBracket:
      Result := '[ 「' + sLineBreak + 'ロ';
    FkRightBracket:
      Result := '] 」' + sLineBreak + '。';
    FkMinus:
      Result := '- =' + sLineBreak + 'ラ';
    FkCaret:
      Result := '^' + sLineBreak + 'リ';
    FkYen:
      Result := '¥' + sLineBreak + 'ル';
    FkSemiColon:
      Result := '; +' + sLineBreak + 'モ';
    FkColon:
      Result := ': *' + sLineBreak + 'ミ';
    FkComma:
      Result := ', <' + sLineBreak + 'ヨ';
    FkDot:
      Result := '. >' + sLineBreak + 'ワ';
    FkSlash:
      Result := '/ ?' + sLineBreak + 'ヲ';
    FkUnderscore:
      Result := '_' + sLineBreak + 'ン';
  else
    Result := '';
  end;
end;

procedure TNesFamicomKeyboard.Paint;
begin
  inherited;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FFE5D8AC;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Font.Family := 'sans-serif';
  Canvas.Font.Style := [];
  var Highlighted := HighlightedKeys;
  for var K in FVisualKeys do
  begin
    var Red := K.Key in [FkF1..FkF8, FkReturn, FkLeftShift, FkRightShift,
        FkSpace, FkUp, FkDown, FkLeft, FkRight];
    if K.Key in Highlighted then
      Canvas.Fill.Color := $FFD4A647
    else if Red then
      Canvas.Fill.Color := $FF8D302E
    else
      Canvas.Fill.Color := $FFD2CFB9;
    var R := K.Bounds;
    var Radius := R.Height * 0.06;
    Canvas.FillRect(R, Radius, Radius, AllCorners, AbsoluteOpacity);
    Canvas.Stroke.Color := $FF5A4435;
    Canvas.Stroke.Thickness := Max(0.5, R.Height * 0.025);
    Canvas.DrawRect(R, Radius, Radius, AllCorners, AbsoluteOpacity);
    R.Inflate(-R.Height * 0.06, -R.Height * 0.06);
    Canvas.Font.Size := R.Height * 0.30;
    if Red then
      Canvas.Fill.Color := $FFF8E8CE
    else
      Canvas.Fill.Color := $FF302D26;
    var Opacity := AbsoluteOpacity;
    if not AbsoluteEnabled then
      Opacity := Opacity * 0.45;
    Canvas.FillText(R, KeyCaption(K.Key), False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
  var U := Max(0, Min(Width / 20.5, Height / 7.5));
  var X := (Width - U * 20.5) / 2;
  var Y := (Height - U * 7.5) / 2;
  Canvas.Fill.Color := $FF8D302E;
  Canvas.Font.Size := U * 0.25;
  Canvas.FillText(RectF(X + 17 * U, Y + 0.1 * U, X + 19.5 * U, Y + 0.65 * U),
    'HVC-007', False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
  Canvas.FillText(RectF(X + 6 * U, Y + 6.9 * U, X + 14.5 * U, Y + 7.4 * U),
    'FAMILY COMPUTER', False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
end;

procedure TNesFamicomKeyboard.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesFamicomKeyboard.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesFamicomKeyboard.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

