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
    FOnChange: TNotifyEvent;
    FNativeInput: TObject;
    FVisualKeys: TArray<TVisualKey>;
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
    property Keys: TSuborKeys read FKeys;
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
  System.SysUtils, System.TypInfo, FMX.Graphics,
  {$IFDEF ANDROID}
  Androidapi.JNIBridge, Androidapi.JNI.GraphicsContentViewText,
  FMX.Platform.Android,
  {$ENDIF}
  System.Math;

{$IFDEF ANDROID}
type
  TSuborKeyboardAndroidInput = class(TJavaLocal, JView_OnTouchListener)
  private
    FKeyboard: TNesSuborKeyboard;
    FView: JView;
    FScale: Single;
  public
    constructor Create(Keyboard: TNesSuborKeyboard; Form: TCommonCustomForm);
    destructor Destroy; override;
    function onTouch(v: JView; event: JMotionEvent): Boolean; cdecl;
  end;

constructor TSuborKeyboardAndroidInput.Create(Keyboard: TNesSuborKeyboard; Form: TCommonCustomForm);
begin
  inherited Create;
  FKeyboard := Keyboard;
  var Handle := WindowHandleToPlatform(Form.Handle);
  FScale := Handle.Scale;
  FView := Handle.View;
  FView.setOnTouchListener(Self);
end;

destructor TSuborKeyboardAndroidInput.Destroy;
begin
  if FView <> nil then
    FView.setOnTouchListener(nil);
  FKeyboard := nil;
  FView := nil;
  inherited;
end;

function TSuborKeyboardAndroidInput.onTouch(v: JView; event: JMotionEvent): Boolean;
begin
  Result := False;
  if FKeyboard = nil then
    Exit;
  var Action := event.getActionMasked;
  if Action = TJMotionEvent.JavaClass.ACTION_CANCEL then
  begin
    FKeyboard.ReleaseAll;
    Exit;
  end;
  var ChangedIndex := event.getActionIndex;
  for var i := 0 to event.getPointerCount - 1 do
  begin
    var Id := event.getPointerId(i);
    var Point := FKeyboard.AbsoluteToLocal(TPointF.Create(event.getX(i) / FScale, event.getY(i) / FScale));
    if (i = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_UP) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_UP)) then
      FKeyboard.PointerUp(Id)
    else if (i = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_DOWN) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_DOWN)) then
      FKeyboard.PointerDown(Id, Point)
    else
      FKeyboard.PointerMove(Id, Point);
  end;
end;
{$ENDIF}

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
    FNativeInput := TSuborKeyboardAndroidInput.Create(Self, Form);
  {$ENDIF}
end;

class function TNesSuborKeyboard.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(300.0, Min(AvailableWidth * 0.43, AvailableHeight * 0.48));
  Result := Max(170.0, Result);
end;

procedure TNesSuborKeyboard.AddKey(Key: TSuborKey; Row: Integer; Column, Span: Single);
var
  U, Gap, H: Single;
begin
  U := Width / 24;
  Gap := Max(1.5, U * 0.08);
  H := (Height - Gap * 7) / 6;
  AddVisualKey(Key, RectF(Column * U + Gap, Row * (H + Gap) + Gap,
      (Column + Span) * U - Gap, Row * (H + Gap) + H));
end;

procedure TNesSuborKeyboard.AddTallKey(Key: TSuborKey; Row: Integer; Column, Span, Rows: Single);
var
  U, Gap, H: Single;
begin
  U := Width / 24;
  Gap := Max(1.5, U * 0.08);
  H := (Height - Gap * 7) / 6;
  AddVisualKey(Key, RectF(Column * U + Gap, Row * (H + Gap) + Gap,
      (Column + Span) * U - Gap, (Row + Rows) * (H + Gap) - Gap));
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

procedure TNesSuborKeyboard.UpdateKeys;
begin
  var NewKeys: TSuborKeys := [];
  for var Key in FContacts.Values do
    Include(NewKeys, Key);
  if NewKeys = FKeys then
    Exit;
  FKeys := NewKeys;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesSuborKeyboard.PointerDown(Id: NativeInt; const Point: TPointF);
var
  Key: TSuborKey;
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;
  FContacts.Remove(Id);
  Key := KeyAt(Point);
  if Key <> SkNone then
    FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
end;

procedure TNesSuborKeyboard.PointerMove(Id: NativeInt; const Point: TPointF);
var
  Key, OldKey: TSuborKey;
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;
  if not FContacts.TryGetValue(Id, OldKey) then
    Exit;
  Key := KeyAt(Point);
  if Key = OldKey then
    Exit;
  if Key = SkNone then
    FContacts.Remove(Id)
  else
    FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
end;

procedure TNesSuborKeyboard.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TNesSuborKeyboard.ReleaseAll;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
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
begin
  inherited;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FF151A24;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Font.Family := 'sans-serif';
  Canvas.Font.Size := Max(8, Height / 30);
  Canvas.Font.Style := [TFontStyle.fsBold];
  for var VisualKey in FVisualKeys do
  begin
    var Key := VisualKey.Key;
    var R := VisualKey.Bounds;
    if Key in FKeys then
      Canvas.Fill.Color := $FF5989B2
    else
      Canvas.Fill.Color := $FF303B4D;
    Canvas.FillRect(R, 4, 4, AllCorners, AbsoluteOpacity);
    Canvas.Stroke.Color := $FF080D15;
    Canvas.Stroke.Thickness := 1;
    Canvas.DrawRect(R, 4, 4, AllCorners, AbsoluteOpacity);
    Canvas.Fill.Color := $FFF3F5FA;
    Canvas.FillText(R, KeyCaption(Key), True, AbsoluteOpacity * Ord(Enabled), [], TTextAlign.Center, TTextAlign.Center);
  end;
end;

procedure TNesSuborKeyboard.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited; {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y)); {$ENDIF}
end;

procedure TNesSuborKeyboard.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited; {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y)); {$ENDIF}
end;

procedure TNesSuborKeyboard.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited; {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1); {$ENDIF}
end;

end.

