unit NES.SuborKeyboard;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller;

type
  // Visual representation of the Subor keyboard.  It reports the actual matrix
  // keys, not characters, so the ROM sees exactly the same codes as hardware.
  TNesSuborKeyboard = class(TControl)
  private
    type
      TVisualKey = record
        Key: TSuborKey;
        Bounds: TRectF;
      end;
  private
    FContacts: TDictionary<NativeInt, TSuborKey>;
    FKeys: TSuborKeys;
    FCoreKeys: TSuborKeys;
    FOnChange: TNotifyEvent;
    FNativeInput: TObject;
    FVisualKeys: TArray<TVisualKey>;
    FIndicators: TSuborIndicators;
    FKeyOrigin: TPointF;
    FKeyUnit, FKeyHeight, FKeyGap: Single;
    FIndicatorBounds: array[0..2] of TRectF;
    FPowerBounds: TRectF;
    FPowerContact, FPowerPressed: Boolean;
    FPowerPointer: NativeInt;
    FOnPower: TNotifyEvent;
    FOnReset: TNotifyEvent;
    procedure SetIndicators(const Value: TSuborIndicators);
    procedure SetCoreKeys(const Value: TSuborKeys);
    function GetHighlightedKeys: TSuborKeys;
    procedure LayoutKeys;
    procedure AddKey(Key: TSuborKey; Row: Integer; Column, Span: Single);
    procedure AddTallKey(Key: TSuborKey; Row: Integer; Column, Span, Rows: Single);
    procedure AddVisualKey(Key: TSuborKey; const Bounds: TRectF);
    function KeyAt(const Point: TPointF): TSuborKey;
    procedure UpdateKeys;
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
    function ButtonBounds(Key: TSuborKey): TRectF;
    property PowerBounds: TRectF read FPowerBounds;
    property Indicators: TSuborIndicators read FIndicators write SetIndicators;
    property Keys: TSuborKeys read FKeys;
    property CoreKeys: TSuborKeys read FCoreKeys write SetCoreKeys;
    property HighlightedKeys: TSuborKeys read GetHighlightedKeys;
  published
    property Align;
    property Anchors;
    property Enabled;
    property Margins;
    property Position;
    property Size;
    property Visible;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnPower: TNotifyEvent read FOnPower write FOnPower;
    property OnReset: TNotifyEvent read FOnReset write FOnReset;
  end;

implementation

uses
  System.SysUtils, System.TypInfo, FMX.Graphics,
  {$IFDEF ANDROID}
  RM.TouchInput.Android,
  {$ENDIF}
  System.Math;

{ TNesSuborKeyboard }

constructor TNesSuborKeyboard.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, TSuborKey>.Create;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 600, 250);
  LayoutKeys;
end;

destructor TNesSuborKeyboard.Destroy;
begin
  FreeAndNil(FNativeInput);
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

procedure TNesSuborKeyboard.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

class function TNesSuborKeyboard.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(300.0, Min(AvailableWidth * 0.43, AvailableHeight * 0.48));
  Result := Max(170.0, Result);
end;

procedure TNesSuborKeyboard.AddKey(Key: TSuborKey; Row: Integer; Column, Span: Single);
begin
  var U := FKeyUnit;
  var Gap := FKeyGap;
  var H := FKeyHeight;
  AddVisualKey(Key, RectF(FKeyOrigin.X + Column * U + Gap, FKeyOrigin.Y + Row * (H + Gap) + Gap,
      FKeyOrigin.X + (Column + Span) * U - Gap, FKeyOrigin.Y + Row * (H + Gap) + H));
end;

procedure TNesSuborKeyboard.AddTallKey(Key: TSuborKey; Row: Integer; Column, Span, Rows: Single);
begin
  var U := FKeyUnit;
  var Gap := FKeyGap;
  var H := FKeyHeight;
  AddVisualKey(Key, RectF(FKeyOrigin.X + Column * U + Gap, FKeyOrigin.Y + Row * (H + Gap) + Gap,
      FKeyOrigin.X + (Column + Span) * U - Gap, FKeyOrigin.Y + (Row + Rows) * (H + Gap) - Gap));
end;

procedure TNesSuborKeyboard.AddVisualKey(Key: TSuborKey; const Bounds: TRectF);
begin
  var Index := Length(FVisualKeys);
  SetLength(FVisualKeys, Index + 1);
  FVisualKeys[Index].Key := Key;
  FVisualKeys[Index].Bounds := Bounds;
end;

procedure TNesSuborKeyboard.LayoutKeys;
begin
  SetLength(FVisualKeys, 0);
  FKeyUnit := Max(0, Min(Width / 25, Height / 8));
  FKeyGap := FKeyUnit * 0.08;
  FKeyHeight := FKeyUnit * 1.05;
  FKeyOrigin := PointF((Width - FKeyUnit * 25) / 2 + FKeyUnit * 0.5,
    (Height - FKeyUnit * 8) / 2 + FKeyUnit * 0.8);
  var U := FKeyUnit;
  var Gap := FKeyGap;
  var H := FKeyHeight;
  for var i := 0 to 2 do
    FIndicatorBounds[i] := RectF(FKeyOrigin.X + (20 + i) * U + Gap, FKeyOrigin.Y + Gap,
        FKeyOrigin.X + (21 + i) * U - Gap, FKeyOrigin.Y + H);
  var Diameter := Max(0, Min(U - Gap * 2, H - Gap));
  FPowerBounds := RectF(FKeyOrigin.X + 23.5 * U - Diameter / 2, FKeyOrigin.Y + (H + Gap - Diameter) / 2,
    FKeyOrigin.X + 23.5 * U + Diameter / 2, FKeyOrigin.Y + (H + Gap + Diameter) / 2);
  // Original Subor geometry: main keyboard, navigation cluster, then numpad.
  AddKey(SkEsc, 0, 0, 1);
  AddKey(SkF1, 0, 2, 1);
  AddKey(SkF2, 0, 3, 1);
  AddKey(SkF3, 0, 4, 1);
  AddKey(SkF4, 0, 5, 1);
  AddKey(SkF5, 0, 7, 1);
  AddKey(SkF6, 0, 8, 1);
  AddKey(SkF7, 0, 9, 1);
  AddKey(SkF8, 0, 10, 1);
  AddKey(SkF9, 0, 12, 1);
  AddKey(SkF10, 0, 13, 1);
  AddKey(SkF11, 0, 14, 1);
  AddKey(SkF12, 0, 15, 1);
  AddKey(SkPause, 0, 17, 1);
  AddKey(SkBreak, 0, 18, 1);
  AddKey(SkReset, 0, 19, 1);
  AddKey(SkNumLock, 1, 20, 1);
  AddKey(SkNumpadDivide, 1, 21, 1);
  AddKey(SkNumpadMultiply, 1, 22, 1);
  AddKey(SkNumpadMinus, 1, 23, 1);
  AddKey(SkGrave, 1, 0, 1);
  AddKey(SkNum1, 1, 1, 1);
  AddKey(SkNum2, 1, 2, 1);
  AddKey(SkNum3, 1, 3, 1);
  AddKey(SkNum4, 1, 4, 1);
  AddKey(SkNum5, 1, 5, 1);
  AddKey(SkNum6, 1, 6, 1);
  AddKey(SkNum7, 1, 7, 1);
  AddKey(SkNum8, 1, 8, 1);
  AddKey(SkNum9, 1, 9, 1);
  AddKey(SkNum0, 1, 10, 1);
  AddKey(SkMinus, 1, 11, 1);
  AddKey(SkEqual, 1, 12, 1);
  AddKey(SkBackspace, 1, 13, 3);
  AddKey(SkTab, 2, 0, 1.5);
  AddKey(SkQ, 2, 1.5, 1);
  AddKey(SkW, 2, 2.5, 1);
  AddKey(SkE, 2, 3.5, 1);
  AddKey(SkR, 2, 4.5, 1);
  AddKey(SkT, 2, 5.5, 1);
  AddKey(SkY, 2, 6.5, 1);
  AddKey(SkU, 2, 7.5, 1);
  AddKey(SkI, 2, 8.5, 1);
  AddKey(SkO, 2, 9.5, 1);
  AddKey(SkP, 2, 10.5, 1);
  AddKey(SkLeftBracket, 2, 11.5, 1);
  AddKey(SkRightBracket, 2, 12.5, 1);
  AddKey(SkBackslash, 2, 13.5, 2.5);
  AddKey(SkIns, 2, 17, 1);
  AddKey(SkHome, 2, 18, 1);
  AddKey(SkPageUp, 2, 19, 1);
  AddKey(SkNumpad7, 2, 20, 1);
  AddKey(SkNumpad8, 2, 21, 1);
  AddKey(SkNumpad9, 2, 22, 1);
  AddTallKey(SkNumpadPlus, 2, 23, 1, 2);
  AddKey(SkCapsLock, 3, 0, 1.8);
  AddKey(SkA, 3, 1.8, 1);
  AddKey(SkS, 3, 2.8, 1);
  AddKey(SkD, 3, 3.8, 1);
  AddKey(SkF, 3, 4.8, 1);
  AddKey(SkG, 3, 5.8, 1);
  AddKey(SkH, 3, 6.8, 1);
  AddKey(SkJ, 3, 7.8, 1);
  AddKey(SkK, 3, 8.8, 1);
  AddKey(SkL, 3, 9.8, 1);
  AddKey(SkSemiColon, 3, 10.8, 1);
  AddKey(SkApostrophe, 3, 11.8, 1);
  AddKey(SkEnter, 3, 12.8, 3.2);
  AddKey(SkDelete, 3, 17, 1);
  AddKey(SkEnd, 3, 18, 1);
  AddKey(SkPageDown, 3, 19, 1);
  AddKey(SkNumpad4, 3, 20, 1);
  AddKey(SkNumpad5, 3, 21, 1);
  AddKey(SkNumpad6, 3, 22, 1);
  AddKey(SkShift, 4, 0, 2.2);
  AddKey(SkZ, 4, 2.2, 1);
  AddKey(SkX, 4, 3.2, 1);
  AddKey(SkC, 4, 4.2, 1);
  AddKey(SkV, 4, 5.2, 1);
  AddKey(SkB, 4, 6.2, 1);
  AddKey(SkN, 4, 7.2, 1);
  AddKey(SkM, 4, 8.2, 1);
  AddKey(SkComma, 4, 9.2, 1);
  AddKey(SkDot, 4, 10.2, 1);
  AddKey(SkSlash, 4, 11.2, 1);
  AddKey(SkShift, 4, 12.2, 3.8);
  AddKey(SkUp, 4, 18, 1);
  AddKey(SkNumpad1, 4, 20, 1);
  AddKey(SkNumpad2, 4, 21, 1);
  AddKey(SkNumpad3, 4, 22, 1);
  AddTallKey(SkNumpadEnter, 4, 23, 1, 2);
  AddKey(SkCtrl, 5, 0, 1.5);
  AddKey(SkAlt, 5, 1.5, 1.5);
  AddKey(SkSpace, 5, 3, 9);
  AddKey(SkAlt, 5, 12, 1.5);
  AddKey(SkCtrl, 5, 13.5, 2.5);
  AddKey(SkLeft, 5, 17, 1);
  AddKey(SkDown, 5, 18, 1);
  AddKey(SkRight, 5, 19, 1);
  AddKey(SkNumpad0, 5, 20, 2);
  AddKey(SkNumpadDot, 5, 22, 1);
end;

function TNesSuborKeyboard.KeyAt(const Point: TPointF): TSuborKey;
begin
  Result := SkNone;
  if not LocalRect.Contains(Point) then
    Exit;

  for var VisualKey in FVisualKeys do
    if VisualKey.Bounds.Contains(Point) then
      Exit(VisualKey.Key);
end;

function TNesSuborKeyboard.GetHighlightedKeys: TSuborKeys;
begin
  Result := FKeys + FCoreKeys;
  if (FContacts <> nil) and FContacts.ContainsValue(SkReset) then
    Include(Result, SkReset);
end;

function TNesSuborKeyboard.ButtonBounds(Key: TSuborKey): TRectF;
begin
  Result := TRectF.Empty;
  for var VisualKey in FVisualKeys do
    if VisualKey.Key = Key then
      Exit(VisualKey.Bounds);
end;

procedure TNesSuborKeyboard.SetIndicators(const Value: TSuborIndicators);
begin
  if (FIndicators.NumLock = Value.NumLock) and (FIndicators.CapsLock = Value.CapsLock) then
    Exit;

  FIndicators := Value;
  Repaint;
end;

procedure TNesSuborKeyboard.SetCoreKeys(const Value: TSuborKeys);
begin
  if FCoreKeys = Value then
    Exit;

  FCoreKeys := Value;
  Repaint;
end;

procedure TNesSuborKeyboard.UpdateKeys;
begin
  var NewKeys: TSuborKeys := [];
  for var Key in FContacts.Values do
    if Key <> SkReset then
      Include(NewKeys, Key);
  if NewKeys = FKeys then
    Exit;

  FKeys := NewKeys;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesSuborKeyboard.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;

  if FPowerBounds.Contains(Point) then
  begin
    if not FPowerContact then
    begin
      FPowerContact := True;
      FPowerPressed := True;
      FPowerPointer := Id;
      Repaint;
    end;
    Exit;
  end;

  FContacts.Remove(Id);
  var Key := KeyAt(Point);
  if Key <> SkNone then
    FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
  Repaint;
end;

procedure TNesSuborKeyboard.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;

  if FPowerContact and (Id = FPowerPointer) then
  begin
    FPowerPressed := FPowerBounds.Contains(Point);
    Repaint;
    Exit;
  end;

  var OldKey: TSuborKey;
  if not FContacts.TryGetValue(Id, OldKey) then
    Exit;
  var Key := KeyAt(Point);
  if Key = OldKey then
    Exit;

  if Key = SkNone then
    FContacts.Remove(Id)
  else
    FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
  Repaint;
end;

procedure TNesSuborKeyboard.PointerUp(Id: NativeInt);
begin
  if FPowerContact and (Id = FPowerPointer) then
  begin
    var Activate := FPowerPressed and AbsoluteEnabled and ParentedVisible;
    FPowerContact := False;
    FPowerPressed := False;
    Repaint;
    if Activate and Assigned(FOnPower) then
      FOnPower(Self);
    Exit;
  end;

  var Key: TSuborKey;
  var ResetPressed := FContacts.TryGetValue(Id, Key) and (Key = SkReset);
  FContacts.Remove(Id);
  UpdateKeys;
  Repaint;
  if ResetPressed and AbsoluteEnabled and ParentedVisible and Assigned(FOnReset) then
    FOnReset(Self);
end;

procedure TNesSuborKeyboard.ReleaseAll;
begin
  if FContacts = nil then
    Exit;

  FContacts.Clear;
  FPowerContact := False;
  FPowerPressed := False;
  FCoreKeys := [];
  UpdateKeys;
  Repaint;
end;

procedure TNesSuborKeyboard.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
  Repaint;
end;

procedure TNesSuborKeyboard.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
  Repaint;
end;

procedure TNesSuborKeyboard.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesSuborKeyboard.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

function CyrillicLegend(CodePoint: string; const Latin, Symbol: string): string;
begin
  Result := CodePoint;
  if Symbol <> '' then
    Result := Result + ' ' + Symbol;
  Result := Result + sLineBreak + Latin;
end;

function KeyCaption(Key: TSuborKey): string;
begin
  // The first line is the legend printed on the Subor keycap; the second is
  // its Latin/number counterpart.  This mirrors the bilingual original.
  case Key of
    SkEsc:
      Result := 'Esc';
    SkBackspace:
      Result := '←';
    SkCapsLock:
      Result := 'Caps';
    SkShift:
      Result := 'Shift';
    SkCtrl:
      Result := 'Ctrl';
    SkAlt:
      Result := 'Alt';
    SkSpace:
      Result := 'Space';
    SkEnter:
      Result := 'Enter';
    SkTab:
      Result := 'Tab';
    SkPageUp:
      Result := 'Page' + sLineBreak + 'Up';
    SkPageDown:
      Result := 'Page' + sLineBreak + 'Down';
    SkNumpadEnter:
      Result := 'Enter';
    SkNumpadDivide:
      Result := '/';
    SkNumpadMultiply:
      Result := '*';
    SkNumpadMinus:
      Result := '-';
    SkNumpadPlus:
      Result := '+';
    SkNumpadDot:
      Result := '.';
    SkNumpad0..SkNumpad9:
      Result := IntToStr(Ord(Key) - Ord(SkNumpad0));
    SkNum1:
      Result := '№  !' + sLineBreak + '1';
    SkNum2:
      Result := '—  @' + sLineBreak + '2';
    SkNum3:
      Result := '/  #' + sLineBreak + '3';
    SkNum4:
      Result := '"  $' + sLineBreak + '4';
    SkNum5:
      Result := ':  %' + sLineBreak + '5';
    SkNum6:
      Result := ',  ^' + sLineBreak + '6';
    SkNum7:
      Result := '.  &' + sLineBreak + '7';
    SkNum8:
      Result := '-  *' + sLineBreak + '8';
    SkNum9:
      Result := '?  (' + sLineBreak + '9';
    SkNum0:
      Result := '%  )' + sLineBreak + '0';
    SkQ:
      Result := CyrillicLegend('Й', 'Q', '');
    SkW:
      Result := CyrillicLegend('Ц', 'W', '');
    SkE:
      Result := CyrillicLegend('У', 'E', '');
    SkR:
      Result := CyrillicLegend('К', 'R', '');
    SkT:
      Result := CyrillicLegend('Е', 'T', '');
    SkY:
      Result := CyrillicLegend('Н', 'Y', '');
    SkU:
      Result := CyrillicLegend('Г', 'U', '');
    SkI:
      Result := CyrillicLegend('Ш', 'I', '');
    SkO:
      Result := CyrillicLegend('Щ', 'O', '');
    SkP:
      Result := CyrillicLegend('З', 'P', '');
    SkLeftBracket:
      Result := CyrillicLegend('Х', '[', '{');
    SkRightBracket:
      Result := CyrillicLegend('Ъ', ']', '}');
    SkA:
      Result := CyrillicLegend('Ф', 'A', '');
    SkS:
      Result := CyrillicLegend('Ы', 'S', '');
    SkD:
      Result := CyrillicLegend('В', 'D', '');
    SkF:
      Result := CyrillicLegend('А', 'F', '');
    SkG:
      Result := CyrillicLegend('П', 'G', '');
    SkH:
      Result := CyrillicLegend('Р', 'H', '');
    SkJ:
      Result := CyrillicLegend('О', 'J', '');
    SkK:
      Result := CyrillicLegend('Л', 'K', '');
    SkL:
      Result := CyrillicLegend('Д', 'L', '');
    SkSemiColon:
      Result := CyrillicLegend('Ж', ';', ':');
    SkApostrophe:
      Result := CyrillicLegend('Э', '''', '"');
    SkZ:
      Result := CyrillicLegend('Я', 'Z', '');
    SkX:
      Result := CyrillicLegend('Ч', 'X', '');
    SkC:
      Result := CyrillicLegend('С', 'C', '');
    SkV:
      Result := CyrillicLegend('М', 'V', '');
    SkB:
      Result := CyrillicLegend('И', 'B', '');
    SkN:
      Result := CyrillicLegend('Т', 'N', '');
    SkM:
      Result := CyrillicLegend('Ь', 'M', '');
    SkComma:
      Result := CyrillicLegend('Б', ',', '<');
    SkDot:
      Result := CyrillicLegend('Ю', '.', '>');
    SkSlash:
      Result := CyrillicLegend('Ё', '/', '?');
    SkF1..SkF12:
      Result := 'F' + IntToStr(Ord(Key) - Ord(SkF1) + 1);
    SkGrave:
      Result := CyrillicLegend('§', '+  `', '~');
    SkMinus:
      Result := '!  -' + sLineBreak + '=  -';
    SkEqual:
      Result := '¤  +' + sLineBreak + '$  =';
    SkBackslash:
      Result := '(  )' + sLineBreak + '|  \';
    SkLeft:
      Result := '←';
    SkRight:
      Result := '→';
    SkUp:
      Result := '↑';
    SkDown:
      Result := '↓';
    SkIns:
      Result := 'Insert';
    SkPause:
      Result := 'Pause';
    SkBreak:
      Result := 'Break';
    SkReset:
      Result := 'Reset';
    SkHome:
      Result := 'Home';
    SkDelete:
      Result := 'Delete';
    SkEnd:
      Result := 'End';
    SkNumLock:
      Result := 'Num' + sLineBreak + 'Lock';
  else
    Result := GetEnumName(TypeInfo(TSuborKey), Ord(Key));
  end;
end;

procedure TNesSuborKeyboard.Paint;
const
  IndicatorCaptions: array[0..2] of string = ('Num Lock', 'Caps Lock', 'Power');
begin
  inherited;
  var U := FKeyUnit;
  if U <= 0 then
    Exit;
  var Opacity := AbsoluteOpacity;
  if not AbsoluteEnabled then
    Opacity := Opacity * 0.5;
  var X := FKeyOrigin.X - 0.5 * U;
  var Y := FKeyOrigin.Y - 0.8 * U;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FFB2AC99;
  Canvas.FillRect(RectF(X, Y + U * 0.1, X + U * 25, Y + U * 8), U * 0.2, U * 0.2, AllCorners, Opacity);
  Canvas.Fill.Color := $FFE0D9C5;
  Canvas.FillRect(RectF(X, Y, X + U * 25, Y + U * 7.85), U * 0.2, U * 0.2, AllCorners, Opacity);
  Canvas.Font.Family := 'Arial';
  Canvas.Font.Style := [TFontStyle.fsBold];
  Canvas.Font.Size := U * 0.32;
  Canvas.Fill.Color := $FF755E3E;
  Canvas.FillText(RectF(X + U * 0.65, Y + U * 0.08, X + U * 6, Y + U * 0.64),
    'SUBOR  小霸王', False, Opacity, [], TTextAlign.Leading, TTextAlign.Center);
  Canvas.Font.Size := U * 0.22;
  Canvas.FillText(RectF(X + U * 17, Y + U * 0.08, X + U * 24.3, Y + U * 0.64),
    'COMPUTER LEARNING SYSTEM', False, Opacity, [], TTextAlign.Trailing, TTextAlign.Center);
  var Highlighted := HighlightedKeys;
  for var VisualKey in FVisualKeys do
  begin
    var Key := VisualKey.Key;
    var R := VisualKey.Bounds;
    var Pressed := Key in Highlighted;
    var Functional := (R.Left >= FKeyOrigin.X + 16 * U) or
      (R.Top < FKeyOrigin.Y + FKeyHeight) or
      (R.Width > U * 1.4);
    Canvas.Fill.Color := $FF8D8879;
    Canvas.FillRect(R, U * 0.09, U * 0.09, AllCorners, Opacity);
    R.Inflate(-U * 0.055, -U * 0.055);
    if Pressed then
      R.Offset(0, U * 0.06)
    else
      R.Bottom := R.Bottom - U * 0.07;
    if Pressed then
      Canvas.Fill.Color := $FFD6B66F
    else if Key = SkReset then
      Canvas.Fill.Color := $FFAA5545
    else if Functional then
      Canvas.Fill.Color := $FFC8C7BB
    else
      Canvas.Fill.Color := $FFF0EBD8;
    Canvas.FillRect(R, U * 0.06, U * 0.06, AllCorners, Opacity);
    Canvas.Stroke.Color := $FFF6F0DF;
    Canvas.Stroke.Thickness := Max(0.4, U * 0.025);
    Canvas.DrawLine(PointF(R.Left + U * 0.07, R.Top), PointF(R.Right - U * 0.07, R.Top), Opacity);
    R.Inflate(-U * 0.04, -U * 0.03);
    Canvas.Fill.Color := $FF333A39;
    if Key = SkReset then
      Canvas.Fill.Color := $FFFFF4DD;
    Canvas.Font.Style := [];
    Canvas.Font.Size := U * 0.25;
    Canvas.FillText(R, KeyCaption(Key), False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
  for var I := 0 to 2 do
  begin
    var R := FIndicatorBounds[I];
    var Lit := (I = 2) or ((I = 0) and FIndicators.NumLock) or
      ((I = 1) and FIndicators.CapsLock);
    Canvas.Fill.Color := $FF333A39;
    Canvas.Font.Size := U * 0.18;
    Canvas.FillText(R, IndicatorCaptions[I], True, Opacity, [], TTextAlign.Center, TTextAlign.Leading);
    var Lamp := RectF(R.Left + R.Width * 0.35, R.Top + R.Height * 0.67,
      R.Right - R.Width * 0.35, R.Top + R.Height * 0.85);
    if Lit then
      Canvas.Fill.Color := $FF5CAE44
    else
      Canvas.Fill.Color := $FF535A39;
    Canvas.FillRect(Lamp, U * 0.04, U * 0.04, AllCorners, Opacity);
  end;
  if FPowerPressed then
    Canvas.Fill.Color := $FFD6B66F
  else
    Canvas.Fill.Color := $FFAA5545;
  Canvas.FillEllipse(FPowerBounds, Opacity);
  Canvas.Fill.Color := $FFFFF4DD;
  Canvas.Font.Size := FPowerBounds.Width * 0.6;
  Canvas.FillText(FPowerBounds, '⏻', False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
end;

procedure TNesSuborKeyboard.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesSuborKeyboard.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesSuborKeyboard.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

