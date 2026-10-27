unit SG1000.Keyboard;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, SG1000.Console;

type
  TSGKeyboard = class(TControl)
  private
    type
      TVisualKey = record
        Code: Byte;
        Caption: string;
        Bounds: TRectF;
      end;
    var
      FVisualKeys: TArray<TVisualKey>;
      FContacts: TDictionary<NativeInt, Byte>;
      FKeys, FSticky: TSGHostKeys;
      FOnChange: TNotifyEvent;
      FNativeInput: TObject;
      FSpectrumMode: Boolean;
    procedure SetSpectrumMode(Value: Boolean);
    procedure LayoutKeys;
    procedure AddKey(Code: Byte; const Caption: string; Row: Integer; Column, Span: Single);
    function KeyAt(const Point: TPointF): Byte;
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
    property Keys: TSGHostKeys read FKeys;
    property SpectrumMode: Boolean read FSpectrumMode write SetSpectrumMode;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Graphics
  {$IFDEF ANDROID}, RM.TouchInput.Android{$ENDIF};

constructor TSGKeyboard.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, Byte>.Create;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 720, 240);
  LayoutKeys;
end;

destructor TSGKeyboard.Destroy;
begin
  FOnChange := nil;
  FNativeInput.Free;
  FContacts.Free;
  inherited;
end;

class function TSGKeyboard.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Max(130.0, Min(260.0, Min(AvailableWidth * 0.34, AvailableHeight * 0.44)));
end;

procedure TSGKeyboard.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);

  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

procedure TSGKeyboard.AddKey(Code: Byte; const Caption: string; Row: Integer; Column, Span: Single);
begin
  var i := Length(FVisualKeys);
  SetLength(FVisualKeys, i + 1);
  FVisualKeys[i].Code := Code;
  FVisualKeys[i].Caption := Caption;
  var U := Width / 16;
  var H := Height / 5;
  if FSpectrumMode then
    H := Height / 4;
  FVisualKeys[i].Bounds := RectF(Column * U + 2, Row * H + 2, (Column + Span) * U - 2, (Row + 1) * H - 2);
end;

procedure TSGKeyboard.LayoutKeys;
const
  Letters: array[0..2] of string = ('QWERTYUIOP', 'ASDFGHJKL', 'ZXCVBNM');
begin
  FVisualKeys := nil;
  if FSpectrumMode then
  begin
    for var i := 1 to 10 do
      AddKey(Ord('0') + (i mod 10), IntToStr(i mod 10), 0, (i - 1) * 1.6, 1.6);
    for var i := 1 to Length(Letters[0]) do
      AddKey(Ord(Letters[0][i]), Letters[0][i], 1, (i - 1) * 1.6, 1.6);
    for var i := 1 to Length(Letters[1]) do
      AddKey(Ord(Letters[1][i]), Letters[1][i], 2, (i - 1) * 1.5, 1.5);
    AddKey(vkReturn, 'ENTER', 2, 13.5, 2.5);
    AddKey(vkShift, 'CAPS SHIFT', 3, 0, 2);
    for var i := 1 to Length(Letters[2]) do
      AddKey(Ord(Letters[2][i]), Letters[2][i], 3, 2 + (i - 1) * 1.4, 1.4);
    AddKey(vkControl, 'SYMBOL SHIFT', 3, 11.8, 2.1);
    AddKey(vkSpace, 'SPACE', 3, 13.9, 2.1);
    Exit;
  end;
  for var i := 1 to 9 do
    AddKey($30 + i, IntToStr(i), 0, i - 1, 1);
  AddKey($30, '0', 0, 9, 1);
  AddKey(vkMinus, '- =', 0, 10, 1);
  AddKey(vkEqual, '^ ~', 0, 11, 1);
  AddKey(vkBackslash, '¥ |', 0, 12, 1);
  AddKey(vkInsert, 'Clr', 0, 13, 1.5);
  AddKey(vkDelete, 'Del', 0, 14.5, 1.5);
  for var Row := 0 to 2 do
    for var i := 1 to Length(Letters[Row]) do
      AddKey(Ord(Letters[Row][i]), Letters[Row][i], Row + 1, i - 1, 1);
  AddKey($C0, '@', 1, 10, 1);
  AddKey($DB, '[', 1, 11, 1);
  AddKey($DD, ']', 1, 12, 1);
  AddKey(vkReturn, 'Return', 1, 13, 3);
  AddKey($BA, '; +', 2, 9, 1);
  AddKey($DE, ': *', 2, 10, 1);
  AddKey($E2, 'π', 2, 11, 1);
  AddKey(vkUp, '↑', 2, 13, 1);
  AddKey(vkEscape, 'Break', 2, 14, 2);
  AddKey($BC, ', <', 3, 7, 1);
  AddKey($BE, '. >', 3, 8, 1);
  AddKey($BF, '/ ?', 3, 9, 1);
  AddKey(vkLeft, '←', 3, 12, 1);
  AddKey(vkDown, '↓', 3, 13, 1);
  AddKey(vkRight, '→', 3, 14, 1);
  AddKey(vkShift, 'Shift', 4, 0, 2);
  AddKey(vkControl, 'Ctrl', 4, 2, 1.5);
  AddKey(vkMenu, 'Graph', 4, 3.5, 1.5);
  AddKey(vkSpace, 'Space', 4, 5, 6);
  AddKey(vkTab, 'Func', 4, 11, 2);
  AddKey(vkRMenu, 'Kana', 4, 13, 3);
end;

procedure TSGKeyboard.SetSpectrumMode(Value: Boolean);
begin
  if FSpectrumMode = Value then
    Exit;
  ReleaseAll;
  FSpectrumMode := Value;
  LayoutKeys;
  Repaint;
end;

function TSGKeyboard.KeyAt(const Point: TPointF): Byte;
begin
  Result := 0;
  for var K in FVisualKeys do
    if K.Bounds.Contains(Point) then
      Exit(K.Code);
end;

procedure TSGKeyboard.UpdateKeys;
begin
  if FContacts = nil then
    Exit;

  FKeys := FSticky;
  for var Code in FContacts.Values do
    FKeys[Code] := True;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TSGKeyboard.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not Enabled or not Visible then
    Exit;

  var Code := KeyAt(Point);
  if Code = 0 then
    Exit;

  if Code in [vkShift, vkControl, vkMenu, vkRMenu] then
    FSticky[Code] := not FSticky[Code]
  else
    FContacts.AddOrSetValue(Id, Code);
  UpdateKeys;
end;

procedure TSGKeyboard.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not FContacts.ContainsKey(Id) then
    Exit;

  var Code := KeyAt(Point);
  if (Code = 0) or (Code in [vkShift, vkControl, vkMenu, vkRMenu]) then
    FContacts.Remove(Id)
  else
    FContacts.AddOrSetValue(Id, Code);
  UpdateKeys;
end;

procedure TSGKeyboard.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TSGKeyboard.ReleaseAll;
begin
  if FContacts = nil then
    Exit;

  FContacts.Clear;
  FillChar(FSticky, SizeOf(FSticky), 0);
  UpdateKeys;
end;

procedure TSGKeyboard.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
end;

procedure TSGKeyboard.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TSGKeyboard.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TSGKeyboard.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TSGKeyboard.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
end;

procedure TSGKeyboard.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  PointerMove(-1, PointF(X, Y));
end;

procedure TSGKeyboard.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
end;

procedure TSGKeyboard.Paint;
begin
  Canvas.Fill.Color := $FF20242C;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Font.Size := Max(9.0, Min(15.0, Width / 65));
  for var K in FVisualKeys do
  begin
    if FKeys[K.Code] then
      Canvas.Fill.Color := $FF467DB8
    else
      Canvas.Fill.Color := $FF3C424D;
    Canvas.FillRect(K.Bounds, 4, 4, AllCorners, AbsoluteOpacity);
    Canvas.Fill.Color := $FFF0F0F0;
    Canvas.FillText(K.Bounds, K.Caption, False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
end;

end.

