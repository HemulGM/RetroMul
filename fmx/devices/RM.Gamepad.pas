unit RM.Gamepad;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller, Core.Emulation;

type
  TScreenGamepadLayout = (Nes, Sega);

  // Coordinates passed to PointerDown/Move are local logical FMX coordinates.
  // OnChange runs on the UI thread. The consumer owns the emulator connection.
  TScreenGamepad = class(TControl)
  private
    type
      TRegion = (None, DPad, Actions, Menu);

      TContact = record
        Region: TRegion;
        Buttons: TEmulatorButtons;
        HeldButtons: TEmulatorButtons;
      end;
  private
    FContacts: TDictionary<NativeInt, TContact>;
    FButtons: TEmulatorButtons;
    FCoreButtons: TEmulatorButtons;
    FLayout: TScreenGamepadLayout;
    FOnChange: TNotifyEvent;
    FBounds: array[TEmulatorButton] of TRectF;
    FDPad: TRectF;
    FActionArea: TRectF;
    FUnit: Single;
    FLevels, FStarts, FTargets: array[TEmulatorButton] of Single;
    FTimes: array[TEmulatorButton] of Int64;
    FAnimation: TTimer;
    FNativeInput: TObject;
    procedure SetLayout(Value: TScreenGamepadLayout);
    function ActiveButtons: TEmulatorButtons;
    procedure LayoutButtons;
    function RegionAt(const Point: TPointF): TRegion;
    function ButtonsAt(const Point: TPointF; Region: TRegion): TEmulatorButtons;
    procedure UpdateButtons;
    procedure UpdateHighlight;
    function GetHighlightedButtons: TEmulatorButtons;
    procedure SetCoreButtons(const Value: TEmulatorButtons);
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
    function ButtonBounds(Button: TEmulatorButton): TRectF;
    property Buttons: TEmulatorButtons read FButtons;
    // Feedback never becomes input. Local contacts always keep their highlight.
    property CoreButtons: TEmulatorButtons read FCoreButtons write SetCoreButtons;
    property HighlightedButtons: TEmulatorButtons read GetHighlightedButtons;
    property Layout: TScreenGamepadLayout read FLayout write SetLayout;
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

  // Preserve the NES control's public API for existing hosts.
  TNesGamepad = class(TScreenGamepad)
  private
    function GetNesButtons: TNesButtons;
  public
    function ButtonBounds(Button: TNesButton): TRectF; reintroduce;
    property Buttons: TNesButtons read GetNesButtons;
  end;

implementation

uses
  System.SysUtils, System.Math, System.Math.Vectors, System.Diagnostics,
  {$IFDEF ANDROID}
  RM.TouchInput.Android,
  {$ENDIF}
  FMX.Graphics;

const
  NesButtonMap: array[TNesButton] of TEmulatorButton =
    (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
    TEmulatorButton.Start, TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right);
  ActionButtons =[ TEmulatorButton.A,  TEmulatorButton.B,  TEmulatorButton.C,
      TEmulatorButton.X,  TEmulatorButton.Y,  TEmulatorButton.Z];
  MenuButtons =[ TEmulatorButton.Select,  TEmulatorButton.Start,  TEmulatorButton.Mode];

function TNesGamepad.GetNesButtons: TNesButtons;
begin
  Result := [];
  for var Button := Low(TNesButton) to High(TNesButton) do
    if NesButtonMap[Button] in inherited Buttons then
      Include(Result, Button);
end;

function TNesGamepad.ButtonBounds(Button: TNesButton): TRectF;
begin
  Result := inherited ButtonBounds(NesButtonMap[Button]);
end;


constructor TScreenGamepad.Create(AOwner: TComponent);
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

destructor TScreenGamepad.Destroy;
begin
  FreeAndNil(FNativeInput);
  if FAnimation <> nil then
    FAnimation.Enabled := False;
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

class function TScreenGamepad.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(212.0, Min(AvailableWidth * 0.46, AvailableHeight * 0.36));
  Result := Max(128.0, Result);
end;

procedure TScreenGamepad.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll, True);
  {$ENDIF}
end;

procedure TScreenGamepad.LayoutButtons;
const
  SegaActions: array[0..5] of TEmulatorButton =
    (TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
var
  U, CX, CY, AX, AY, BX, BY: Single;
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FBounds[Button] := TRectF.Empty;
  // Controls grow up to a comfortable tablet size; extra width separates hands.
  U := Max(0.01, Min(1.5, Min(Width / 400, Height / 160)));
  if FLayout = TScreenGamepadLayout.Sega then
    U := Max(0.01, Min(1.5, Min(Width / 400, Height / 200)));
  if FLayout = TScreenGamepadLayout.Sega then
    U := Max(0.01, Min(1.5, Min(Width / 400, Height / 200)));
  FUnit := U;
  CX := 76 * U;
  CY := Height * 0.43;
  FDPad := RectF(CX - 60 * U, CY - 60 * U, CX + 60 * U, CY + 60 * U);
  FBounds[TEmulatorButton.Up] := RectF(CX - 20 * U, CY - 58 * U, CX + 20 * U, CY - 18 * U);
  FBounds[TEmulatorButton.Down] := RectF(CX - 20 * U, CY + 18 * U, CX + 20 * U, CY + 58 * U);
  FBounds[TEmulatorButton.Left] := RectF(CX - 58 * U, CY - 20 * U, CX - 18 * U, CY + 20 * U);
  FBounds[TEmulatorButton.Right] := RectF(CX + 18 * U, CY - 20 * U, CX + 58 * U, CY + 20 * U);
  AX := Width - 45 * U;
  AY := CY - 18 * U;
  BX := AX - 66 * U;
  BY := CY + 18 * U;
  FBounds[TEmulatorButton.A] := RectF(AX - 27 * U, AY - 27 * U, AX + 27 * U, AY + 27 * U);
  FBounds[TEmulatorButton.B] := RectF(BX - 27 * U, BY - 27 * U, BX + 27 * U, BY + 27 * U);
  CY := Height - 34 * U;
  FBounds[TEmulatorButton.Select] := RectF(Width / 2 - 58 * U, CY - 14 * U, Width / 2 - 8 * U, CY + 10 * U);
  FBounds[TEmulatorButton.Start] := RectF(Width / 2 + 8 * U, CY - 14 * U, Width / 2 + 58 * U, CY + 10 * U);
  if FLayout = TScreenGamepadLayout.Sega then
  begin
    // Two rows of three; leave a full gap between the cross and action area.
    for var I := Low(SegaActions) to High(SegaActions) do
    begin
      AX := Width - (145 - (I mod 3) * 54) * U;
      AY := Height * 0.43 + ((I div 3) * 54 - 27) * U;
      FBounds[SegaActions[I]] := RectF(AX - 23 * U, AY - 23 * U,
          AX + 23 * U, AY + 23 * U);
    end;
    FBounds[TEmulatorButton.Mode] := FBounds[TEmulatorButton.Select];
    FBounds[TEmulatorButton.Select] := TRectF.Empty;
  end;
  // Keep the initial action pressed while the finger crosses gaps between keys.
  FActionArea := TRectF.Empty;
  for var Button in (ActiveButtons * ActionButtons) do
  begin
    var R := FBounds[Button];
    if FActionArea.IsEmpty then FActionArea := R
    else FActionArea := RectF(Min(FActionArea.Left, R.Left), Min(FActionArea.Top, R.Top),
      Max(FActionArea.Right, R.Right), Max(FActionArea.Bottom, R.Bottom));
  end;
  FActionArea.Inflate(6 * FUnit, 6 * FUnit);
end;

function TScreenGamepad.ActiveButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start];
  if FLayout = TScreenGamepadLayout.Sega then
    Result := Result + [TEmulatorButton.C, TEmulatorButton.X, TEmulatorButton.Y,
        TEmulatorButton.Z, TEmulatorButton.Mode]
  else
    Include(Result, TEmulatorButton.Select);
end;

procedure TScreenGamepad.SetLayout(Value: TScreenGamepadLayout);
begin
  if FLayout = Value then
    Exit;
  ReleaseAll;
  FLayout := Value;
  LayoutButtons;
  Repaint;
end;

procedure TScreenGamepad.Resize;
begin
  inherited;
  // A rotation/layout change invalidates all old contact coordinates.
  ReleaseAll;
  LayoutButtons;
  Repaint;
end;

procedure TScreenGamepad.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
  Repaint;
end;

procedure TScreenGamepad.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TScreenGamepad.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

function TScreenGamepad.ButtonBounds(Button: TEmulatorButton): TRectF;
begin
  Result := FBounds[Button];
end;

function TScreenGamepad.RegionAt(const Point: TPointF): TRegion;
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

function TScreenGamepad.ButtonsAt(const Point: TPointF; Region: TRegion): TEmulatorButtons;
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
            Include(Result, TEmulatorButton.Left)
          else
            Include(Result, TEmulatorButton.Right);
        if DY >= DX * 0.42 then
          if Delta.Y < 0 then
            Include(Result, TEmulatorButton.Up)
          else
            Include(Result, TEmulatorButton.Down);
      end;
    TRegion.Actions:
      for var Button in (ActiveButtons * ActionButtons) do
        if Point.Distance(FBounds[Button].CenterPoint) <= FBounds[Button].Width / 2 + 6 * FUnit then
          Include(Result, Button);
    TRegion.Menu:
      for var Button in (ActiveButtons * MenuButtons) do
      begin
        var Bounds := FBounds[Button];
        Bounds.Inflate(5 * FUnit, 9 * FUnit);
        if Bounds.Contains(Point) then
          Include(Result, Button);
      end;
  end;
end;

procedure TScreenGamepad.PointerDown(Id: NativeInt; const Point: TPointF);
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
  Contact.HeldButtons := [];
  if Contact.Region = TRegion.Actions then Contact.HeldButtons := Contact.Buttons;
  FContacts.AddOrSetValue(Id, Contact);
  UpdateButtons;
end;

procedure TScreenGamepad.PointerMove(Id: NativeInt; const Point: TPointF);
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
  if Contact.Region = TRegion.Actions then
  begin
    if LocalRect.Contains(Point) and FActionArea.Contains(Point) then
      Contact.Buttons := Contact.Buttons + Contact.HeldButtons
    else
    begin
      Contact.Buttons := [];
      Contact.HeldButtons := [];
    end;
  end;
  FContacts.AddOrSetValue(Id, Contact);
  UpdateButtons;
end;

procedure TScreenGamepad.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateButtons;
end;

procedure TScreenGamepad.ReleaseAll;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
  FCoreButtons := [];
  UpdateButtons;
  // Backgrounded/hidden controls should not keep an animation timer alive.
  if FAnimation <> nil then
    FAnimation.Enabled := False;
  FillChar(FLevels, SizeOf(FLevels), 0);
  FillChar(FTargets, SizeOf(FTargets), 0);
  Repaint;
end;

procedure TScreenGamepad.UpdateButtons;
begin
  var NewButtons: TEmulatorButtons := [];
  for var Contact in FContacts.Values do
    NewButtons := NewButtons + Contact.Buttons;
  if [TEmulatorButton.Left, TEmulatorButton.Right] <= NewButtons then
    NewButtons := NewButtons - [TEmulatorButton.Left, TEmulatorButton.Right];
  if [TEmulatorButton.Up, TEmulatorButton.Down] <= NewButtons then
    NewButtons := NewButtons - [TEmulatorButton.Up, TEmulatorButton.Down];
  if NewButtons = FButtons then
    Exit;
  FButtons := NewButtons;
  UpdateHighlight;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TScreenGamepad.GetHighlightedButtons: TEmulatorButtons;
begin
  Result := (FButtons + FCoreButtons) * ActiveButtons;
end;

procedure TScreenGamepad.SetCoreButtons(const Value: TEmulatorButtons);
begin
  if FCoreButtons = Value then
    Exit;
  FCoreButtons := Value;
  UpdateHighlight;
end;

procedure TScreenGamepad.UpdateHighlight;
begin
  var NewButtons := GetHighlightedButtons;
  var NowTicks := TStopwatch.GetTimeStamp;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if Ord(Button in NewButtons) <> FTargets[Button] then
    begin
      FStarts[Button] := FLevels[Button];
      FTargets[Button] := Ord(Button in NewButtons);
      FTimes[Button] := NowTicks;
    end;
  FAnimation.Enabled := True;
  Repaint;
end;

procedure TScreenGamepad.Animate(Sender: TObject);
begin
  var Active := False;
  var NowTicks := TStopwatch.GetTimeStamp;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
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

procedure TScreenGamepad.Paint;
const
  Labels: array[TEmulatorButton] of string =
    ('', '', '', '', 'A', 'B', 'SELECT', 'START', 'C', 'X', 'Y', 'Z', 'MODE');
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
  for var Button in ActiveButtons do
  begin
    var R := FBounds[Button];
    var Level := FLevels[Button];
    R.Inflate(-R.Width * 0.045 * Level, -R.Height * 0.045 * Level);
    R.Offset(0, 2 * FUnit * Level);
    var Shadow := R;
    Shadow.Offset(0, 4 * FUnit * (1 - Level));
    Canvas.Fill.Color := $FF080D15;
    var RoundButton := Button in ActionButtons;
    if RoundButton then
      Canvas.FillEllipse(Shadow, Opacity)
    else
      Canvas.FillRect(Shadow, 7 * FUnit, 7 * FUnit, AllCorners, Opacity);
    if Button in [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z] then
      Canvas.Fill.Color := MixColor($FF65758D, $FFA9C6E8, Level)
    else if RoundButton then
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
    if RoundButton then
    begin
      Canvas.Font.Size := 23 * FUnit;
      Canvas.FillText(R, Labels[Button], False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
    end
    else if Button in MenuButtons then
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
        TEmulatorButton.Up:
          begin
            P[0] := PointF(C.X, C.Y - S);
            P[1] := PointF(C.X - S, C.Y + S);
            P[2] := PointF(C.X + S, C.Y + S);
          end;
        TEmulatorButton.Down:
          begin
            P[0] := PointF(C.X, C.Y + S);
            P[1] := PointF(C.X - S, C.Y - S);
            P[2] := PointF(C.X + S, C.Y - S);
          end;
        TEmulatorButton.Left:
          begin
            P[0] := PointF(C.X - S, C.Y);
            P[1] := PointF(C.X + S, C.Y - S);
            P[2] := PointF(C.X + S, C.Y + S);
          end;
        TEmulatorButton.Right:
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

procedure TScreenGamepad.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TScreenGamepad.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TScreenGamepad.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IFNDEF ANDROID}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

