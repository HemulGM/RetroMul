unit NES.Gamepad;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller;

type
  // Coordinates passed to PointerDown/Move are local logical FMX coordinates.
  // OnChange runs on the UI thread. The consumer owns the emulator connection.
  TNesGamepad = class(TControl)
  private
    type
      TRegion = (None, DPad, Actions, Menu);

      TContact = record
        Region: TRegion;
        Buttons: TNesButtons;
      end;
  private
    FContacts: TDictionary<NativeInt, TContact>;
    FButtons: TNesButtons;
    FOnChange: TNotifyEvent;
    FBounds: array[TNesButton] of TRectF;
    FDPad: TRectF;
    FUnit: Single;
    FLevels, FStarts, FTargets: array[TNesButton] of Single;
    FTimes: array[TNesButton] of Int64;
    FAnimation: TTimer;
    FNativeInput: TObject;
    procedure LayoutButtons;
    function RegionAt(const Point: TPointF): TRegion;
    function ButtonsAt(const Point: TPointF; Region: TRegion): TNesButtons;
    procedure UpdateButtons;
    procedure Animate(Sender: TObject);
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
    // Android: observes the form's native view. Use one gamepad per form.
    // Other platforms: ordinary captured mouse input is available automatically.
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF);
    procedure PointerMove(Id: NativeInt; const Point: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll;
    function ButtonBounds(Button: TNesButton): TRectF;
    property Buttons: TNesButtons read FButtons;
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
  System.SysUtils, System.Math, System.Math.Vectors, System.Diagnostics,
  {$IFDEF ANDROID}
  Androidapi.JNIBridge, Androidapi.JNI.GraphicsContentViewText,
  FMX.Platform.Android,
  {$ENDIF}
  FMX.Graphics;

{$IFDEF ANDROID}
type
  TGamepadAndroidInput = class(TJavaLocal, JView_OnTouchListener)
  private
    FPad: TNesGamepad;
    FView: JView;
    FScale: Single;
  public
    constructor Create(Pad: TNesGamepad; Form: TCommonCustomForm);
    destructor Destroy; override;
    function onTouch(v: JView; event: JMotionEvent): Boolean; cdecl;
  end;

constructor TGamepadAndroidInput.Create(Pad: TNesGamepad; Form: TCommonCustomForm);
begin
  inherited Create;
  FPad := Pad;
  var Handle := WindowHandleToPlatform(Form.Handle);
  FScale := Handle.Scale;
  FView := Handle.View;
  FView.setOnTouchListener(Self);
end;

destructor TGamepadAndroidInput.Destroy;
begin
  if FView <> nil then
    FView.setOnTouchListener(nil);
  FPad := nil;
  FView := nil;
  inherited;
end;

function TGamepadAndroidInput.onTouch(v: JView; event: JMotionEvent): Boolean;
begin
  // Do not consume the event: Open ROM and the rest of the form keep working.
  // FMX's synthesized mouse input is ignored by the gamepad on Android.
  Result := False;
  if FPad = nil then
    Exit;
  var Action := event.getActionMasked;
  if Action = TJMotionEvent.JavaClass.ACTION_DOWN then
    FPad.ReleaseAll; // A fresh gesture cannot inherit a lost pointer-up.
  if Action = TJMotionEvent.JavaClass.ACTION_CANCEL then
  begin
    FPad.ReleaseAll;
    Exit;
  end;
  var ChangedIndex := event.getActionIndex;
  for var i := 0 to event.getPointerCount - 1 do
  begin
    var Id := event.getPointerId(i);
    var Point := FPad.AbsoluteToLocal(TPointF.Create(event.getX(i) / FScale,
        event.getY(i) / FScale));
    if (i = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_UP) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_UP)) then
      FPad.PointerUp(Id)
    else if (i = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_DOWN) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_DOWN)) then
      FPad.PointerDown(Id, Point)
    else
      FPad.PointerMove(Id, Point);
  end;
end;
{$ENDIF}

constructor TNesGamepad.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, TContact>.Create;
  FAnimation := TTimer.Create(Self);
  FAnimation.Enabled := False;
  FAnimation.Interval := 16;
  FAnimation.OnTimer := Animate;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 400, 184);
  LayoutButtons;
end;

destructor TNesGamepad.Destroy;
begin
  FreeAndNil(FNativeInput);
  if FAnimation <> nil then
    FAnimation.Enabled := False;
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

class function TNesGamepad.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(212.0, Min(AvailableWidth * 0.46, AvailableHeight * 0.36));
  Result := Max(128.0, Result);
end;

procedure TNesGamepad.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TGamepadAndroidInput.Create(Self, Form);
  {$ENDIF}
end;

procedure TNesGamepad.LayoutButtons;
var
  U, CX, CY, AX, AY, BX, BY: Single;
begin
  // Controls grow up to a comfortable tablet size; extra width separates hands.
  U := Max(0.01, Min(1.5, Min(Width / 400, Height / 160)));
  FUnit := U;
  CX := 76 * U;
  CY := Height * 0.43;
  FDPad := RectF(CX - 60 * U, CY - 60 * U, CX + 60 * U, CY + 60 * U);
  FBounds[TNesButton.Up] := RectF(CX - 20 * U, CY - 58 * U, CX + 20 * U, CY - 18 * U);
  FBounds[TNesButton.Down] := RectF(CX - 20 * U, CY + 18 * U, CX + 20 * U, CY + 58 * U);
  FBounds[TNesButton.Left] := RectF(CX - 58 * U, CY - 20 * U, CX - 18 * U, CY + 20 * U);
  FBounds[TNesButton.Right] := RectF(CX + 18 * U, CY - 20 * U, CX + 58 * U, CY + 20 * U);
  AX := Width - 45 * U;
  AY := CY - 18 * U;
  BX := AX - 66 * U;
  BY := CY + 18 * U;
  FBounds[TNesButton.A] := RectF(AX - 27 * U, AY - 27 * U, AX + 27 * U, AY + 27 * U);
  FBounds[TNesButton.B] := RectF(BX - 27 * U, BY - 27 * U, BX + 27 * U, BY + 27 * U);
  CY := Height - 34 * U;
  FBounds[TNesButton.Select] := RectF(Width / 2 - 58 * U, CY - 14 * U, Width / 2 - 8 * U, CY + 10 * U);
  FBounds[TNesButton.Start] := RectF(Width / 2 + 8 * U, CY - 14 * U, Width / 2 + 58 * U, CY + 10 * U);
end;

procedure TNesGamepad.Resize;
begin
  inherited;
  // A rotation/layout change invalidates all old contact coordinates.
  ReleaseAll;
  LayoutButtons;
  Repaint;
end;

procedure TNesGamepad.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
  Repaint;
end;

procedure TNesGamepad.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesGamepad.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

function TNesGamepad.ButtonBounds(Button: TNesButton): TRectF;
begin
  Result := FBounds[Button];
end;

function TNesGamepad.RegionAt(const Point: TPointF): TRegion;
begin
  Result := TRegion.None;
  if not LocalRect.Contains(Point) then
    Exit;
  if FDPad.Contains(Point) then
    Exit(TRegion.DPad);
  if ButtonsAt(Point, TRegion.Actions) <> [] then
    Exit(TRegion.Actions);
  if ButtonsAt(Point, TRegion.Menu) <> [] then
    Exit(TRegion.Menu);
end;

function TNesGamepad.ButtonsAt(const Point: TPointF; Region: TRegion): TNesButtons;
begin
  Result := [];
  if not LocalRect.Contains(Point) then
    Exit;
  case Region of
    TRegion.DPad:
      begin
        var Delta := Point - FDPad.CenterPoint;
        var DX := Abs(Delta.X);
        var DY := Abs(Delta.Y);
        // A small center dead zone; diagonal sectors overlap adjacent directions.
        if Max(DX, DY) < 13 * FUnit then
          Exit;
        if DX >= DY * 0.42 then
          if Delta.X < 0 then
            Include(Result, TNesButton.Left)
          else
            Include(Result, TNesButton.Right);
        if DY >= DX * 0.42 then
          if Delta.Y < 0 then
            Include(Result, TNesButton.Up)
          else
            Include(Result, TNesButton.Down);
      end;
    TRegion.Actions:
      for var Button := TNesButton.A to TNesButton.B do
        if Point.Distance(FBounds[Button].CenterPoint) <= 33 * FUnit then
          Include(Result, Button);
    TRegion.Menu:
      for var Button := TNesButton.Select to TNesButton.Start do
      begin
        var Bounds := FBounds[Button];
        Bounds.Inflate(5 * FUnit, 9 * FUnit);
        if Bounds.Contains(Point) then
          Include(Result, Button);
      end;
  end;
end;

procedure TNesGamepad.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;
  FContacts.Remove(Id);
  var Contact: TContact;
  Contact.Region := RegionAt(Point);
  if Contact.Region = TRegion.None then
  begin
    UpdateButtons;
    Exit;
  end;
  Contact.Buttons := ButtonsAt(Point, Contact.Region);
  FContacts.AddOrSetValue(Id, Contact);
  UpdateButtons;
end;

procedure TNesGamepad.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;
  var Contact: TContact;
  if not FContacts.TryGetValue(Id, Contact) then
    Exit;
  Contact.Buttons := ButtonsAt(Point, Contact.Region);
  FContacts.AddOrSetValue(Id, Contact);
  UpdateButtons;
end;

procedure TNesGamepad.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateButtons;
end;

procedure TNesGamepad.ReleaseAll;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
  UpdateButtons;
  // Backgrounded/hidden controls should not keep an animation timer alive.
  if FAnimation <> nil then
    FAnimation.Enabled := False;
  FillChar(FLevels, SizeOf(FLevels), 0);
  FillChar(FTargets, SizeOf(FTargets), 0);
  Repaint;
end;

procedure TNesGamepad.UpdateButtons;
begin
  var NewButtons: TNesButtons := [];
  for var Contact in FContacts.Values do
    NewButtons := NewButtons + Contact.Buttons;
  if [TNesButton.Left, TNesButton.Right] <= NewButtons then
    NewButtons := NewButtons - [TNesButton.Left, TNesButton.Right];
  if [TNesButton.Up, TNesButton.Down] <= NewButtons then
    NewButtons := NewButtons - [TNesButton.Up, TNesButton.Down];
  if NewButtons = FButtons then
    Exit;
  var NowTicks := TStopwatch.GetTimeStamp;
  for var Button := Low(TNesButton) to High(TNesButton) do
    if (Button in NewButtons) <> (Button in FButtons) then
    begin
      FStarts[Button] := FLevels[Button];
      FTargets[Button] := Ord(Button in NewButtons);
      FTimes[Button] := NowTicks;
    end;
  FButtons := NewButtons;
  FAnimation.Enabled := True;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesGamepad.Animate(Sender: TObject);
begin
  var Active := False;
  var NowTicks := TStopwatch.GetTimeStamp;
  for var Button := Low(TNesButton) to High(TNesButton) do
    if FLevels[Button] <> FTargets[Button] then
    begin
      var Duration: Double := 0.14;
      if FTargets[Button] > 0 then
        Duration := 0.075;
      var T: Double := Min(1.0, (NowTicks - FTimes[Button]) / TStopwatch.Frequency / Duration);
      FLevels[Button] := FStarts[Button] + (FTargets[Button] - FStarts[Button]) * (1 - Power(1 - T, 3));
      if T >= 1 then
        FLevels[Button] := FTargets[Button]
      else
        Active := True;
    end;
  FAnimation.Enabled := Active;
  Repaint;
end;

function MixColor(A, B: TAlphaColor; Amount: Single): TAlphaColor;
begin
  Result := $FF000000;
  for var Shift := 0 to 2 do
  begin
    var CA := Integer((A shr (Shift * 8)) and $FF);
    var CB := Integer((B shr (Shift * 8)) and $FF);
    Result := Result or (Cardinal(Round(CA + (CB - CA) * Amount)) shl (Shift * 8));
  end;
end;

procedure TNesGamepad.Paint;
const
  Labels: array[TNesButton] of string = ('A', 'B', 'SELECT', 'START', '', '', '', '');
begin
  inherited;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FF151A24;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := $FF313A49;
  Canvas.Stroke.Thickness := 1;
  Canvas.DrawLine(PointF(16 * FUnit, 0.5), PointF(Width - 16 * FUnit, 0.5), AbsoluteOpacity);
  var Opacity := AbsoluteOpacity;
  if not Enabled then
    Opacity := Opacity * 0.5;
  // The cross center connects the four directional arms.
  var Center := FDPad.CenterPoint;
  Canvas.Fill.Color := $FF303B4D;
  const CenterSize = 11;
  Canvas.FillRect(RectF(Center.X - CenterSize * FUnit, Center.Y - CenterSize * FUnit,
      Center.X + CenterSize * FUnit, Center.Y + CenterSize * FUnit), 6 * FUnit, 6 * FUnit, AllCorners, Opacity);
  for var Button := Low(TNesButton) to High(TNesButton) do
  begin
    var R := FBounds[Button];
    var Level := FLevels[Button];
    R.Inflate(-R.Width * 0.045 * Level, -R.Height * 0.045 * Level);
    R.Offset(0, 2 * FUnit * Level);
    var Shadow := R;
    Shadow.Offset(0, 4 * FUnit * (1 - Level));
    Canvas.Fill.Color := $FF080D15;
    var RoundButton := Button in [TNesButton.A, TNesButton.B];
    if RoundButton then
      Canvas.FillEllipse(Shadow, Opacity)
    else
      Canvas.FillRect(Shadow, 7 * FUnit, 7 * FUnit, AllCorners, Opacity);
    if RoundButton then
      Canvas.Fill.Color := MixColor($FFCB4660, $FFFF8A92, Level)
    else
      Canvas.Fill.Color := MixColor($FF303B4D, $FF5989B2, Level);
    if RoundButton then
      Canvas.FillEllipse(R, Opacity)
    else
      Canvas.FillRect(R, 7 * FUnit, 7 * FUnit, AllCorners, Opacity);
    Canvas.Fill.Color := $FFF3F5FA;
    Canvas.Font.Family := 'sans-serif';
    Canvas.Font.Style := [TFontStyle.fsBold];
    if Button in [TNesButton.A, TNesButton.B] then
    begin
      Canvas.Font.Size := 23 * FUnit;
      Canvas.FillText(R, Labels[Button], False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
    end
    else if Button in [TNesButton.Select, TNesButton.Start] then
    begin
      var Bar := R;
      Bar.Inflate(-14 * FUnit, -10 * FUnit);
      Canvas.FillRect(Bar, FUnit, FUnit, AllCorners, Opacity * 0.8);
      Canvas.Font.Size := 9 * FUnit;
      var LabelRect := FBounds[Button];
      LabelRect.Top := LabelRect.Bottom + 6 * FUnit;
      LabelRect.Bottom := LabelRect.Top + 13 * FUnit;
      Canvas.FillText(LabelRect, Labels[Button], False, Opacity * 0.8, [], TTextAlign.Center, TTextAlign.Center);
    end
    else
    begin
      var P: TPolygon;
      SetLength(P, 3);
      var C := R.CenterPoint;
      var S := 6 * FUnit;
      case Button of
        TNesButton.Up:
          begin
            P[0] := PointF(C.X, C.Y - S);
            P[1] := PointF(C.X - S, C.Y + S);
            P[2] := PointF(C.X + S, C.Y + S);
          end;
        TNesButton.Down:
          begin
            P[0] := PointF(C.X, C.Y + S);
            P[1] := PointF(C.X - S, C.Y - S);
            P[2] := PointF(C.X + S, C.Y - S);
          end;
        TNesButton.Left:
          begin
            P[0] := PointF(C.X - S, C.Y);
            P[1] := PointF(C.X + S, C.Y - S);
            P[2] := PointF(C.X + S, C.Y + S);
          end;
        TNesButton.Right:
          begin
            P[0] := PointF(C.X + S, C.Y);
            P[1] := PointF(C.X - S, C.Y - S);
            P[2] := PointF(C.X - S, C.Y + S);
          end;
      end;
      Canvas.FillPolygon(P, Opacity * 0.8);
    end;
  end;
end;

procedure TNesGamepad.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesGamepad.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TNesGamepad.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

