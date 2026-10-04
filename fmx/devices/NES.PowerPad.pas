unit NES.PowerPad;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller;

type
  // Twelve pressure pads with independent pointer contacts.
  TNesPowerPad = class(TControl)
  private
    type
      TVisualKey = record
        Key: Integer;
        Bounds: TRectF;
      end;
  private
    FContacts: TDictionary<NativeInt, Integer>;
    FKeys: TPowerPadButtons;
    FCoreButtons: TPowerPadButtons;
    FOnChange: TNotifyEvent;
    FNativeInput: TObject;
    FVisualKeys: TArray<TVisualKey>;
    procedure SetCoreButtons(const Value: TPowerPadButtons);
    function GetHighlightedButtons: TPowerPadButtons;
    procedure LayoutKeys;
    procedure AddVisualKey(Key: Integer; const Bounds: TRectF);
    function KeyAt(const Point: TPointF): Integer;
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
    function ButtonBounds(Button: TPowerPadButton): TRectF;
    property Buttons: TPowerPadButtons read FKeys;
    property CoreButtons: TPowerPadButtons read FCoreButtons write SetCoreButtons;
    property HighlightedButtons: TPowerPadButtons read GetHighlightedButtons;
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
  System.SysUtils, FMX.Graphics,
  {$IFDEF ANDROID}
  RM.TouchInput.Android,
  {$ENDIF}
  System.Math;

{ TNesPowerPad }

constructor TNesPowerPad.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, Integer>.Create;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 400, 300);
  LayoutKeys;
end;

destructor TNesPowerPad.Destroy;
begin
  FreeAndNil(FNativeInput);
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

procedure TNesPowerPad.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

class function TNesPowerPad.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(300.0, Min(AvailableWidth * 0.75, AvailableHeight * 0.48));
  Result := Max(0.0, Result);
end;

procedure TNesPowerPad.AddVisualKey(Key: Integer; const Bounds: TRectF);
begin
  var Index := Length(FVisualKeys);
  SetLength(FVisualKeys, Index + 1);
  FVisualKeys[Index].Key := Key;
  FVisualKeys[Index].Bounds := Bounds;
end;

procedure TNesPowerPad.LayoutKeys;
begin
  SetLength(FVisualKeys, 0);
  var Cell := Max(0, Min(Width / 4.4, Height / 3.8));
  var Left := (Width - Cell * 4.4) / 2 + Cell * 0.2;
  var Top := (Height - Cell * 3.8) / 2 + Cell * 0.65;
  var Gap := Cell * 0.09;
  for var Button := 1 to 12 do
  begin
    var X := Left + ((Button - 1) mod 4) * Cell;
    var Y := Top + ((Button - 1) div 4) * Cell;
    AddVisualKey(Button, RectF(X + Gap, Y + Gap, X + Cell - Gap, Y + Cell - Gap));
  end;
end;

function TNesPowerPad.ButtonBounds(Button: TPowerPadButton): TRectF;
begin
  Result := FVisualKeys[Button - 1].Bounds;
end;

function TNesPowerPad.KeyAt(const Point: TPointF): Integer;
begin
  Result := 0;
  if not LocalRect.Contains(Point) then
    Exit;

  for var VisualKey in FVisualKeys do
    if VisualKey.Bounds.Contains(Point) and (Point.Distance(VisualKey.Bounds.CenterPoint) <= VisualKey.Bounds.Width / 2) then
      Exit(VisualKey.Key);
end;

function TNesPowerPad.GetHighlightedButtons: TPowerPadButtons;
begin
  Result := FKeys + FCoreButtons;
end;

procedure TNesPowerPad.SetCoreButtons(const Value: TPowerPadButtons);
begin
  if FCoreButtons = Value then
    Exit;

  FCoreButtons := Value;
  Repaint;
end;

procedure TNesPowerPad.UpdateKeys;
begin
  var NewKeys: TPowerPadButtons := [];
  for var Key in FContacts.Values do
    if Key <> 0 then
      Include(NewKeys, Key);
  if NewKeys = FKeys then
    Exit;

  FKeys := NewKeys;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesPowerPad.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;

  FContacts.Remove(Id);
  var Key := KeyAt(Point);
  if Key <> 0 then
    FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
end;

procedure TNesPowerPad.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;

  var OldKey: Integer;
  if not FContacts.TryGetValue(Id, OldKey) then
    Exit;

  var Key := KeyAt(Point);
  if Key = OldKey then
    Exit;

  FContacts.AddOrSetValue(Id, Key);
  UpdateKeys;
end;

procedure TNesPowerPad.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TNesPowerPad.ReleaseAll;
begin
  if FContacts = nil then
    Exit;

  FContacts.Clear;
  FCoreButtons := [];
  UpdateKeys;
  Repaint;
end;

procedure TNesPowerPad.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
  Repaint;
end;

procedure TNesPowerPad.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
  Repaint;
end;

procedure TNesPowerPad.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesPowerPad.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesPowerPad.Paint;
begin
  inherited;
  var Cell := Max(0, Min(Width / 4.4, Height / 3.8));
  if Cell <= 0 then Exit;
  var X := (Width - Cell * 4.4) / 2;
  var Y := (Height - Cell * 3.8) / 2;
  var Opacity := AbsoluteOpacity;
  if not AbsoluteEnabled then Opacity := Opacity * 0.5;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FFE3E1D8;
  var Mat := RectF(X, Y, X + Cell * 4.4, Y + Cell * 3.8);
  Canvas.FillRect(Mat, Cell * 0.08, Cell * 0.08, AllCorners, Opacity);
  Mat.Inflate(-Cell * 0.04, -Cell * 0.04);
  Canvas.Stroke.Color := $FFB7B7B0;
  Canvas.Stroke.Thickness := Max(0.5, Cell * 0.015);
  Canvas.DrawRect(Mat, Cell * 0.05, Cell * 0.05, AllCorners, Opacity);
  Canvas.Font.Family := 'Arial';
  Canvas.Font.Style := [TFontStyle.fsBold];
  Canvas.Font.Size := Cell * 0.22;
  Canvas.Fill.Color := $FF343536;
  Canvas.FillText(RectF(X + Cell * 0.2, Y + Cell * 0.1, X + Cell * 3.1, Y + Cell * 0.38),
    'POWER PAD', False, Opacity, [], TTextAlign.Leading, TTextAlign.Center);
  Canvas.Font.Size := Cell * 0.12;
  Canvas.FillText(RectF(X + Cell * 3.1, Y + Cell * 0.1, X + Cell * 4.2, Y + Cell * 0.38),
    'SIDE B', False, Opacity, [], TTextAlign.Trailing, TTextAlign.Center);
  Canvas.Font.Size := Cell * 0.08;
  Canvas.FillText(RectF(X + Cell * 0.2, Y + Cell * 0.4, X + Cell * 4.2, Y + Cell * 0.57),
    'Nintendo  •  DO NOT WEAR SHOES', False, Opacity, [], TTextAlign.Leading, TTextAlign.Center);
  var Highlighted := HighlightedButtons;
  for var VisualKey in FVisualKeys do
  begin
    var R := VisualKey.Bounds;
    var Color: TAlphaColor := $FF267CB5;
    if not Odd(VisualKey.Key) then Color := $FFCA444C;
    Canvas.Stroke.Color := Color;
    Canvas.Stroke.Thickness := Max(1, Cell * 0.025);
    Canvas.DrawEllipse(R, Opacity);
    R.Inflate(-Cell * 0.065, -Cell * 0.065);
    if VisualKey.Key in Highlighted then Canvas.Fill.Color := $FFE4B849
    else Canvas.Fill.Color := Color;
    Canvas.FillEllipse(R, Opacity);
    Canvas.Fill.Color := $FFEFEDE4;
    Canvas.Font.Size := Cell * 0.31;
    Canvas.FillText(R, IntToStr(VisualKey.Key), False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
end;

procedure TNesPowerPad.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesPowerPad.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesPowerPad.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

