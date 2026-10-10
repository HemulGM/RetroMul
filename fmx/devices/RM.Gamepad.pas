unit RM.Gamepad;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller, Core.Emulation;

type
  TScreenGamepadLayout = (Nes, Sega, Snes, GameBoy, GameBoyColor, NeoGeo);

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
    FButtonMask: TEmulatorButtons;
    FLayout: TScreenGamepadLayout;
    FOnChange: TNotifyEvent;
    FBounds: array[TEmulatorButton] of TRectF;
    FShell: TRectF;
    FDPad: TRectF;
    FActionArea: TRectF;
    FSegaPod: TRectF;
    FSegaPodAngle: Single;
    FSegaButtonsCenter: TPointF;
    FSegaButtonsAngle: Single;
    FUnit: Single;
    FLevels, FStarts, FTargets: array[TEmulatorButton] of Single;
    FTimes: array[TEmulatorButton] of Int64;
    FAnimation: TTimer;
    FNativeInput: TObject;
    procedure SetLayout(Value: TScreenGamepadLayout);
    procedure SetButtonMask(const Value: TEmulatorButtons);
    function ActiveButtons: TEmulatorButtons;
    procedure LayoutButtons;
    procedure PaintConsole;
    function SegaSixButtons: Boolean;
    function ArtworkHeight: Single;
    function GetAspectRatio: Single;
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
    property AspectRatio: Single read GetAspectRatio;
    property ButtonMask: TEmulatorButtons read FButtonMask write SetButtonMask;
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
  FMX.Graphics, RM.Icons;

const
  NesButtonMap: array[TNesButton] of TEmulatorButton =
    (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
    TEmulatorButton.Start, TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right);
  ActionButtons =[ TEmulatorButton.A,  TEmulatorButton.B,  TEmulatorButton.C,
      TEmulatorButton.X,  TEmulatorButton.Y,  TEmulatorButton.Z];
  MenuButtons =[ TEmulatorButton.Select,  TEmulatorButton.Start,  TEmulatorButton.Mode];

{ TNesGamepad }

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

{ TScreenGamepad }

constructor TScreenGamepad.Create(AOwner: TComponent);
begin
  inherited;
  FButtonMask := [Low(TEmulatorButton)..High(TEmulatorButton)];
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

function TScreenGamepad.SegaSixButtons: Boolean;
begin
  Result := FButtonMask * [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z] <> [];
end;

function TScreenGamepad.ArtworkHeight: Single;
begin
  Result := 184;
  if FLayout = TScreenGamepadLayout.Sega then
    if SegaSixButtons then
      Result := 208
    else
      Result := 216;
end;

function TScreenGamepad.GetAspectRatio: Single;
begin
  Result := ArtworkHeight / 400;
end;

procedure TScreenGamepad.LayoutButtons;
var
  U, OX, OY, CX, CY, Half, Arm: Single;

  function R(X, Y, W, H: Single): TRectF;
  begin
    Result := RectF(OX + X * U, OY + Y * U, OX + (X + W) * U, OY + (Y + H) * U);
  end;

  procedure SegaAction(Button: TEmulatorButton; X, Y, Diameter: Single);
  begin
    // The six-button base leans outward; its button rows still rise to the right.
    var Angle := DegToRad(FSegaButtonsAngle);
    var Center := FSegaButtonsCenter;
    Center.Offset((X * Cos(Angle) - Y * Sin(Angle)) * U,
      (X * Sin(Angle) + Y * Cos(Angle)) * U);
    var Radius := Diameter * U / 2;
    FBounds[Button] := RectF(Center.X - Radius, Center.Y - Radius,
        Center.X + Radius, Center.Y + Radius);
  end;

begin
  FSegaPod := TRectF.Empty;
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FBounds[Button] := TRectF.Empty;
  // One coordinate system for artwork and input, including wide tablet panels.
  U := Max(0.001, Min(Width / 400, Height / ArtworkHeight));
  OX := (Width - 400 * U) / 2;
  OY := (Height - ArtworkHeight * U) / 2;
  FUnit := U;
  FShell := R(6, 6, 388, 172);
  CX := 78;
  CY := 96;
  Half := 52;
  Arm := 18;
  case FLayout of
    TScreenGamepadLayout.Nes:
      begin
        CY := 111;
        Half := 37;
        Arm := 12;
      end;
    TScreenGamepadLayout.Snes:
      begin
        CY := 102;
        Half := 32;
        Arm := 10;
      end;
    TScreenGamepadLayout.Sega:
      begin
        if SegaSixButtons then
        begin
          CX := 100;
          CY := 97;
        end
        else
        begin
          CX := 93;
          CY := 126;
        end;
        Half := 35;
        Arm := 12;
      end;
    TScreenGamepadLayout.NeoGeo:
      begin
        CX := 82;
        CY := 97;
        Half := 37;
        Arm := 12;
      end;
  end;
  FDPad := R(CX - Half - 4, CY - Half - 4, 2 * Half + 8, 2 * Half + 8);
  FBounds[TEmulatorButton.Up] := R(CX - Arm, CY - Half, 2 * Arm, Half - Arm);
  FBounds[TEmulatorButton.Down] := R(CX - Arm, CY + Arm, 2 * Arm, Half - Arm);
  FBounds[TEmulatorButton.Left] := R(CX - Half, CY - Arm, Half - Arm, 2 * Arm);
  FBounds[TEmulatorButton.Right] := R(CX + Arm, CY - Arm, Half - Arm, 2 * Arm);
  FBounds[TEmulatorButton.B] := R(270, 92, 46, 46);
  FBounds[TEmulatorButton.A] := R(330, 92, 46, 46);
  FBounds[TEmulatorButton.Select] := R(151, 119, 44, 18);
  FBounds[TEmulatorButton.Start] := R(207, 119, 44, 18);
  case FLayout of
    TScreenGamepadLayout.Nes:
      begin
        FBounds[TEmulatorButton.B] := R(270, 111, 46, 46);
        FBounds[TEmulatorButton.A] := R(330, 111, 46, 46);
        FBounds[TEmulatorButton.Select] := R(153, 119, 39, 19);
        FBounds[TEmulatorButton.Start] := R(207, 119, 39, 19);
      end;
    TScreenGamepadLayout.Sega:
      begin
        if SegaSixButtons then
        begin
          FSegaPod := R(220, 43, 156, 128);
          FSegaPodAngle := 35;
          FSegaButtonsCenter := PointF(OX + 298 * U, OY + 103 * U);
          FSegaButtonsAngle := -20;
          SegaAction(TEmulatorButton.X, -38, -21, 27);
          SegaAction(TEmulatorButton.Y, 0, -21, 27);
          SegaAction(TEmulatorButton.Z, 38, -21, 27);
          SegaAction(TEmulatorButton.A, -38, 21, 36);
          SegaAction(TEmulatorButton.B, 0, 21, 36);
          SegaAction(TEmulatorButton.C, 38, 21, 36);
          FBounds[TEmulatorButton.Start] := R(179, 72, 35, 13);
          FBounds[TEmulatorButton.Mode] := R(186.5, 101, 20, 20);
        end
        else
        begin
          FSegaPod := R(230, 91, 156, 70);
          FSegaPodAngle := -25;
          FSegaButtonsCenter := FSegaPod.CenterPoint;
          FSegaButtonsAngle := FSegaPodAngle;
          SegaAction(TEmulatorButton.A, -44, 0, 36);
          SegaAction(TEmulatorButton.B, 0, 0, 36);
          SegaAction(TEmulatorButton.C, 44, 0, 36);
          FBounds[TEmulatorButton.Start] := R(263, 62, 44, 23);
          FBounds[TEmulatorButton.Mode] := TRectF.Empty;
        end;
        FBounds[TEmulatorButton.Select] := TRectF.Empty;
      end;
    TScreenGamepadLayout.Snes:
      begin
        FBounds[TEmulatorButton.X] := R(291, 42, 34, 34);
        FBounds[TEmulatorButton.B] := R(291, 114, 34, 34);
        FBounds[TEmulatorButton.Y] := R(255, 78, 34, 34);
        FBounds[TEmulatorButton.A] := R(327, 78, 34, 34);
        FBounds[TEmulatorButton.C] := R(38, 8, 94, 19);
        FBounds[TEmulatorButton.Z] := R(268, 8, 94, 19);
        FBounds[TEmulatorButton.Select] := R(153, 99, 34, 24);
        FBounds[TEmulatorButton.Start] := R(198, 99, 34, 24);
      end;
    TScreenGamepadLayout.NeoGeo:
      begin
        FBounds[TEmulatorButton.A] := R(276, 116, 36, 36);
        FBounds[TEmulatorButton.B] := R(328, 79, 36, 36);
        FBounds[TEmulatorButton.C] := R(246, 65, 36, 36);
        FBounds[TEmulatorButton.X] := R(292, 27, 36, 36);
        FBounds[TEmulatorButton.Select] := R(183, 80, 40, 26);
        FBounds[TEmulatorButton.Start] := R(183, 130, 40, 26);
      end;
    TScreenGamepadLayout.GameBoy, TScreenGamepadLayout.GameBoyColor:
      begin
        FBounds[TEmulatorButton.B] := R(269, 100, 46, 46);
        FBounds[TEmulatorButton.A] := R(327, 76, 46, 46);
      end;
  end;
  FActionArea := TRectF.Empty;
  for var Button in (ActiveButtons * ActionButtons) do
  begin
    var Bounds := FBounds[Button];
    if FActionArea.IsEmpty then
      FActionArea := Bounds
    else
      FActionArea := RectF(Min(FActionArea.Left, Bounds.Left), Min(FActionArea.Top, Bounds.Top),
        Max(FActionArea.Right, Bounds.Right), Max(FActionArea.Bottom, Bounds.Bottom));
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
  if FLayout = TScreenGamepadLayout.Snes then
    Result := Result + [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z];
  if FLayout = TScreenGamepadLayout.NeoGeo then
    Result := Result + [TEmulatorButton.C, TEmulatorButton.X];
  if (FLayout = TScreenGamepadLayout.Sega) and not SegaSixButtons then
    Exclude(Result, TEmulatorButton.Mode);
  Result := Result * FButtonMask;
end;

procedure TScreenGamepad.SetButtonMask(const Value: TEmulatorButtons);
begin
  if FButtonMask = Value then
    Exit;
  ReleaseAll;
  FButtonMask := Value;
  LayoutButtons;
  Repaint;
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
  if Button in ActiveButtons then
    Result := FBounds[Button]
  else
    Result := TRectF.Empty;
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
      begin
        var Bounds := FBounds[Button];
        if (FLayout = TScreenGamepadLayout.Snes) and
          (Button in [TEmulatorButton.C, TEmulatorButton.Z]) then
        begin
          Bounds.Inflate(4 * FUnit, 4 * FUnit);
          if Bounds.Contains(Point) then
            Include(Result, Button);
        end
        else if Point.Distance(Bounds.CenterPoint) <= Bounds.Width / 2 + 6 * FUnit then
          Include(Result, Button);
      end;
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
  if Contact.Region = TRegion.Actions then
    Contact.HeldButtons := Contact.Buttons;
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

procedure TScreenGamepad.PaintConsole;
var
  OX, OY, Opacity: Single;
  Shell, Ink: TAlphaColor;

  function R(X, Y, W, H: Single): TRectF;
  begin
    Result := RectF(OX + X * FUnit, OY + Y * FUnit,
      OX + (X + W) * FUnit, OY + (Y + H) * FUnit);
  end;

  procedure Solid(Color: TAlphaColor);
  begin
    Canvas.Fill.Kind := TBrushKind.Solid;
    Canvas.Fill.Color := Color;
  end;

  procedure Gradient(Top, Bottom: TAlphaColor);
  begin
    Canvas.Fill.Kind := TBrushKind.Gradient;
    var G := Canvas.Fill.Gradient;
    G.Style := TGradientStyle.Linear;
    G.StartPosition.Point := PointF(0.25, 0);
    G.StopPosition.Point := PointF(0.75, 1);
    if G.Points.Count <> 2 then
    begin
      G.Points.Clear;
      G.Points.Add;
      G.Points.Add;
    end;
    G.Points[0].Offset := 0;
    G.Points[0].Color := Top;
    G.Points[1].Offset := 1;
    G.Points[1].Color := Bottom;
  end;

  procedure Box(const Bounds: TRectF; Color: TAlphaColor; Radius: Single);
  begin
    Solid(Color);
    Canvas.FillRect(Bounds, Radius * FUnit, Radius * FUnit, AllCorners, Opacity);
  end;

  procedure Text(const Bounds: TRectF; const Caption: string; Color: TAlphaColor; Size: Single);
  begin
    Solid(Color);
    Canvas.Font.Size := Size * FUnit;
    Canvas.FillText(Bounds, Caption, False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
  end;

  procedure Oval(const Bounds: TRectF; Top, Bottom: TAlphaColor);
  begin
    Gradient(Top, Bottom);
    Canvas.FillEllipse(Bounds, Opacity);
  end;

  procedure TiltedOval(const Bounds: TRectF; Angle: Single; Top, Bottom: TAlphaColor);
  begin
    var Path := TPathData.Create;
    try
      var C := Bounds.CenterPoint;
      Path.AddEllipse(RectF(-Bounds.Width / 2, -Bounds.Height / 2, Bounds.Width / 2, Bounds.Height / 2));
      Path.ApplyMatrix(TMatrix.CreateRotation(DegToRad(Angle)));
      Path.Translate(C.X, C.Y);
      Gradient(Top, Bottom);
      Canvas.FillPath(Path, Opacity);
      Canvas.Stroke.Color := $FF111214;
      Canvas.Stroke.Thickness := FUnit;
      Canvas.DrawPath(Path, Opacity * 0.65);
    finally
      Path.Free;
    end;
  end;

  procedure TiltedText(const Bounds: TRectF; const Caption: string; Color: TAlphaColor; Size, Angle: Single);
  begin
    var State := Canvas.SaveState;
    try
      var C := Bounds.CenterPoint;
      Canvas.SetMatrix(TMatrix.CreateTranslation(-C.X, -C.Y) *
        TMatrix.CreateRotation(DegToRad(Angle)) * TMatrix.CreateTranslation(C.X, C.Y) * Canvas.Matrix);
      Text(Bounds, Caption, Color, Size);
    finally
      Canvas.RestoreState(State);
    end;
  end;

  procedure TiltedCapsule(const Bounds: TRectF; Angle: Single; Top, Bottom: TAlphaColor);
  begin
    var Path := TPathData.Create;
    try
      var C := Bounds.CenterPoint;
      Path.AddRectangle(RectF(-Bounds.Width / 2, -Bounds.Height / 2, Bounds.Width / 2, Bounds.Height / 2),
        Bounds.Height / 2, Bounds.Height / 2, AllCorners);
      Path.ApplyMatrix(TMatrix.CreateRotation(DegToRad(Angle)));
      Path.Translate(C.X, C.Y);
      Canvas.Stroke.Color := $FF080A0D;
      Canvas.Stroke.Thickness := 4 * FUnit;
      Canvas.DrawPath(Path, Opacity);
      Gradient(Top, Bottom);
      Canvas.FillPath(Path, Opacity);
    finally
      Path.Free;
    end;
  end;

  procedure Arrow(X, Y, Angle: Single; Color: TAlphaColor);
  begin
    var Path := TPathData.Create;
    try
      Path.Data := IconArrowUp;
      Path.ApplyMatrix(TMatrix.CreateRotation(DegToRad(Angle)));
      Path.Translate(X, Y);
      Path.Scale(FUnit, FUnit);
      Path.Translate(OX, OY);
      Solid(Color);
      Canvas.FillPath(Path, Opacity);
    finally
      Path.Free;
    end;
  end;

begin
  if FUnit <= 0 then
    Exit;
  OX := (Width - 400 * FUnit) / 2;
  OY := (Height - ArtworkHeight * FUnit) / 2;
  Opacity := AbsoluteOpacity;
  if not AbsoluteEnabled then
    Opacity := Opacity * 0.5;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Font.Family := 'Arial';
  Canvas.Font.Style := [TFontStyle.fsBold];
  Shell := $FFCECFD0;
  Ink := $FF545659;
  if FLayout in [TScreenGamepadLayout.Sega, TScreenGamepadLayout.NeoGeo] then
  begin
    Shell := $FF37393C;
    Ink := $FFD9DCDA;
  end;

  if FLayout = TScreenGamepadLayout.NeoGeo then
    Shell := $FF353A35;
  if FLayout = TScreenGamepadLayout.Sega then
    Shell := $FF292B30;
  var Body := TPathData.Create;
  try
    case FLayout of
      TScreenGamepadLayout.Nes:
        Body.AddRectangle(RectF(6, 10, 394, 177), 9, 9, AllCorners);
      TScreenGamepadLayout.Snes:
        begin
          Body.MoveTo(PointF(81, 20));
          Body.CurveTo(PointF(126, 20), PointF(132, 26), PointF(153, 26));
          Body.LineTo(PointF(247, 26));
          Body.CurveTo(PointF(268, 26), PointF(281, 20), PointF(317, 20));
          Body.CurveTo(PointF(365, 20), PointF(394, 48), PointF(394, 97));
          Body.CurveTo(PointF(394, 146), PointF(363, 176), PointF(317, 176));
          Body.CurveTo(PointF(273, 176), PointF(260, 154), PointF(241, 151));
          Body.LineTo(PointF(158, 151));
          Body.CurveTo(PointF(140, 154), PointF(126, 176), PointF(81, 176));
          Body.CurveTo(PointF(35, 176), PointF(6, 146), PointF(6, 97));
          Body.CurveTo(PointF(6, 48), PointF(35, 20), PointF(81, 20));
          Body.ClosePath;
        end;
      TScreenGamepadLayout.Sega:
        begin
          if SegaSixButtons then
          begin
            Body.MoveTo(PointF(200, 8));
            Body.CurveTo(PointF(301, 8), PointF(378, 57), PointF(390, 112));
            Body.CurveTo(PointF(401, 166), PointF(386, 205), PointF(343, 204));
            Body.CurveTo(PointF(296, 207), PointF(275, 168), PointF(200, 168));
            Body.CurveTo(PointF(125, 168), PointF(104, 207), PointF(57, 204));
            Body.CurveTo(PointF(14, 205), PointF(-1, 166), PointF(10, 112));
            Body.CurveTo(PointF(22, 57), PointF(99, 8), PointF(200, 8));
            Body.ClosePath;
          end
          else
          begin
            Body.MoveTo(PointF(198, 8));
            Body.CurveTo(PointF(290, 8), PointF(366, 36), PointF(386, 94));
            Body.CurveTo(PointF(404, 158), PointF(374, 212), PointF(348, 212));
            Body.CurveTo(PointF(282, 212), PointF(264, 169), PointF(202, 169));
            Body.CurveTo(PointF(152, 169), PointF(136, 215), PointF(84, 213));
            Body.CurveTo(PointF(40, 213), PointF(5, 172), PointF(7, 122));
            Body.CurveTo(PointF(15, 43), PointF(93, 10), PointF(198, 8));
            Body.ClosePath;
          end;
        end;
      TScreenGamepadLayout.NeoGeo:
        begin
          Body.MoveTo(PointF(65, 17));
          Body.CurveTo(PointF(119, 5), PointF(150, 14), PointF(198, 17));
          Body.CurveTo(PointF(244, 16), PointF(286, 4), PointF(338, 17));
          Body.CurveTo(PointF(373, 26), PointF(385, 64), PointF(392, 107));
          Body.CurveTo(PointF(402, 158), PointF(375, 178), PointF(327, 177));
          Body.CurveTo(PointF(269, 171), PointF(252, 162), PointF(200, 162));
          Body.CurveTo(PointF(150, 162), PointF(127, 175), PointF(70, 177));
          Body.CurveTo(PointF(22, 181), PointF(-1, 155), PointF(8, 107));
          Body.CurveTo(PointF(15, 63), PointF(27, 26), PointF(65, 17));
          Body.ClosePath;
        end;
    end;
    Body.Scale(FUnit, FUnit);
    Body.Translate(OX, OY + 3 * FUnit);
    Solid($FF0D1013);
    Canvas.FillPath(Body, Opacity * 0.45);
    Body.Translate(0, -3 * FUnit);
    if FLayout = TScreenGamepadLayout.Sega then
      Gradient(MixColor(Shell, $FFFFFFFF, 0.16), MixColor(Shell, $FF000000, 0.38))
    else
      Gradient(MixColor(Shell, $FFFFFFFF, 0.2), MixColor(Shell, $FF000000, 0.22));
    Canvas.FillPath(Body, Opacity);
    Canvas.Stroke.Color := MixColor(Shell, $FFFFFFFF, 0.25);
    Canvas.Stroke.Thickness := 1.1 * FUnit;
    Canvas.DrawPath(Body, Opacity);
  finally
    Body.Free;
  end;

  case FLayout of
    TScreenGamepadLayout.Nes:
      begin
        Box(R(16, 42, 368, 127), $FF28292B, 4);
        Box(R(140, 42, 110, 15), $FF93948C, 3);
        Box(R(140, 64, 110, 15), $FF93948C, 3);
        Box(R(140, 87, 110, 22), $FF93948C, 3);
        Box(R(140, 153, 110, 16), $FF93948C, 3);
        Box(R(140, 115, 111, 31), $FFDDDEDA, 3);
        Box(R(145, 119, 101, 23), $FFB1B2AE, 2);
        Box(R(266, 108, 54, 53), $FFD8DADA, 4);
        Box(R(326, 108, 54, 53), $FFD8DADA, 4);
        Text(R(258, 60, 125, 25), 'Nintendo', $FFEC413C, 21);
        Text(R(143, 90, 53, 15), 'SELECT', $FFDD3D35, 9);
        Text(R(201, 90, 47, 15), 'START', $FFDD3D35, 9);
      end;
    TScreenGamepadLayout.Snes:
      begin
        Oval(R(243, 31, 136, 136), $FF8F9295, $FF767A7F);
        Canvas.Stroke.Color := $FFE0E0DA;
        Canvas.Stroke.Thickness := FUnit;
        Canvas.DrawEllipse(R(243, 31, 136, 136), Opacity * 0.65);
        Text(R(133, 43, 118, 15), 'SUPER NINTENDO', $FF55595D, 10);
        Text(R(133, 57, 118, 10), 'ENTERTAINMENT SYSTEM', $FF686C70, 5.7);
        // Four matching lobes echo the original Super Nintendo emblem.
        for var I := 0 to 3 do
          Oval(R(120 + (I mod 2) * 5, 45 + (I div 2) * 5, 5, 5), $FF73777B, $FF55595D);
      end;
    TScreenGamepadLayout.Sega:
      begin
        var Seam := TPathData.Create;
        try
          if SegaSixButtons then
          begin
            Seam.MoveTo(PointF(119, 23));
            Seam.LineTo(PointF(134, 30));
            Seam.CurveTo(PointF(176, 19), PointF(232, 19), PointF(270, 29));
            Seam.LineTo(PointF(284, 20));
          end
          else
          begin
            Seam.MoveTo(PointF(38, 67));
            Seam.CurveTo(PointF(104, 12), PointF(295, 8), PointF(365, 65));
          end;
          Seam.Scale(FUnit, FUnit);
          Seam.Translate(OX, OY);
          Canvas.Stroke.Color := $FF111318;
          Canvas.Stroke.Thickness := 1.2 * FUnit;
          Canvas.DrawPath(Seam, Opacity);
        finally
          Seam.Free;
        end;
        if SegaSixButtons then
        begin
          // Mirrored oval axes point toward the lower outer corners of the shell.
          TiltedOval(R(19, 43, 156, 128), -FSegaPodAngle, $FF64676D, $FF36383E);
          TiltedOval(FSegaPod, FSegaPodAngle, $FF5E6167, $FF2B2D33);
          // Light outline on the logo, like the moulded six-button pad.
          Text(R(171.5, 35.5, 66, 20), 'SEGA', $FFDFE1E4, 18);
          Text(R(172, 36, 65, 19), 'SEGA', $FF8A8D94, 16);
        end
        else
        begin
          Oval(R(29, 62, 128, 128), $FF4F5358, $FF1B1D21);
          TiltedOval(FSegaPod, FSegaPodAngle, $FF080B0F, $FF41464C);
          var Badge := TPathData.Create;
          try
            Badge.MoveTo(PointF(154, 87));
            Badge.LineTo(PointF(164, 80));
            Badge.LineTo(PointF(244, 80));
            Badge.LineTo(PointF(252, 87));
            Badge.LineTo(PointF(247, 105));
            Badge.LineTo(PointF(154, 105));
            Badge.ClosePath;
            Badge.Scale(FUnit, FUnit);
            Badge.Translate(OX, OY);
            Gradient($FFDFE2E7, $FF777F8B);
            Canvas.FillPath(Badge, Opacity);
          finally
            Badge.Free;
          end;
          Canvas.Font.Style := [TFontStyle.fsBold, TFontStyle.fsItalic];
          Text(R(155, 86, 95, 18), 'GENESIS', $FF343A43, 16);
          Canvas.Font.Style := [TFontStyle.fsBold];
          Text(R(177, 69, 52, 14), 'SEGA', $FFD1D7DE, 11);
          TiltedText(R(266, 91, 72, 13), 'TRIGGER', Ink, 7, FSegaPodAngle);
        end;
      end;
    TScreenGamepadLayout.NeoGeo:
      begin
        Oval(R(22, 37, 120, 120), $FF4F514C, $FF292C29);
        Text(R(156, 27, 85, 19), 'SNK', $FFE5E8DD, 18);
        Text(R(151, 47, 94, 18), 'NEO-GEO', $FFE5E8DD, 14);
      end;
  end;

  // A recessed circular base and solid cross share the same input geometry.
  var Center := FDPad.CenterPoint;
  var Up := FBounds[TEmulatorButton.Up];
  var Down := FBounds[TEmulatorButton.Down];
  var Left := FBounds[TEmulatorButton.Left];
  var Right := FBounds[TEmulatorButton.Right];
  if FLayout = TScreenGamepadLayout.Snes then
    Oval(RectF(Center.X - 45 * FUnit, Center.Y - 45 * FUnit,
        Center.X + 45 * FUnit, Center.Y + 45 * FUnit), $FFBBBDB7, $FFD8D8D0)
  else if FLayout in [TScreenGamepadLayout.Sega, TScreenGamepadLayout.NeoGeo] then
  begin
    Oval(RectF(Center.X - 46 * FUnit, Center.Y - 46 * FUnit,
        Center.X + 46 * FUnit, Center.Y + 46 * FUnit), $FF080A0C, $FF17191C);
    Canvas.Stroke.Color := $FF7A7C7D;
    Canvas.Stroke.Thickness := FUnit;
    Canvas.DrawEllipse(RectF(Center.X - 43 * FUnit, Center.Y - 43 * FUnit,
        Center.X + 43 * FUnit, Center.Y + 43 * FUnit), Opacity * 0.5);
  end;
  var Cross := TPathData.Create;
  try
    Cross.MoveTo(PointF(Up.Left, Up.Top));
    Cross.LineTo(PointF(Up.Right, Up.Top));
    Cross.LineTo(PointF(Up.Right, Right.Top));
    Cross.LineTo(PointF(Right.Right, Right.Top));
    Cross.LineTo(PointF(Right.Right, Right.Bottom));
    Cross.LineTo(PointF(Down.Right, Right.Bottom));
    Cross.LineTo(PointF(Down.Right, Down.Bottom));
    Cross.LineTo(PointF(Down.Left, Down.Bottom));
    Cross.LineTo(PointF(Down.Left, Left.Bottom));
    Cross.LineTo(PointF(Left.Left, Left.Bottom));
    Cross.LineTo(PointF(Left.Left, Left.Top));
    Cross.LineTo(PointF(Up.Left, Left.Top));
    Cross.ClosePath;
    Canvas.Stroke.Color := $FF0B0D10;
    Canvas.Stroke.Thickness := 4 * FUnit;
    if FLayout = TScreenGamepadLayout.Nes then
    begin
      Canvas.Stroke.Color := $FFD4D5D4;
      Canvas.Stroke.Thickness := 7 * FUnit;
    end;
    Canvas.DrawPath(Cross, Opacity);
    Gradient($FF4C4E50, $FF24272A);
    Canvas.FillPath(Cross, Opacity);
    Canvas.Stroke.Color := $FF111316;
    Canvas.Stroke.Thickness := 1.2 * FUnit;
    Canvas.DrawPath(Cross, Opacity);
  finally
    Cross.Free;
  end;
  Oval(RectF(Center.X - 5 * FUnit, Center.Y - 5 * FUnit,
      Center.X + 5 * FUnit, Center.Y + 5 * FUnit), $FF111315, $FF424649);

  for var B in [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right] do
  begin
    var Bounds := FBounds[B];
    if FLevels[B] > 0 then
      Box(Bounds, MixColor($FF35383A, $FFE3C368, FLevels[B]), 2);
    var C := Bounds.CenterPoint;
    var X := (C.X - OX) / FUnit;
    var Y := (C.Y - OY) / FUnit;
    var Angle: Single := 0;
    case B of
      TEmulatorButton.Right:
        Angle := 90;
      TEmulatorButton.Down:
        Angle := 180;
      TEmulatorButton.Left:
        Angle := 270;
    end;
    Arrow(X, Y, Angle, $FF16191B);
    if (FLayout = TScreenGamepadLayout.Sega) and not SegaSixButtons then
    begin
      X := (Center.X - OX) / FUnit;
      Y := (Center.Y - OY) / FUnit;
      case B of
        TEmulatorButton.Up:
          Y := Y - 55;
        TEmulatorButton.Down:
          Y := Y + 55;
        TEmulatorButton.Left:
          X := X - 55;
        TEmulatorButton.Right:
          X := X + 55;
      end;
      Arrow(X, Y, Angle, $FFE35541);
    end;
    if FLayout = TScreenGamepadLayout.NeoGeo then
    begin
      X := (Center.X - OX) / FUnit;
      Y := (Center.Y - OY) / FUnit;
      case B of
        TEmulatorButton.Up:
          Y := Y - 51;
        TEmulatorButton.Down:
          Y := Y + 51;
        TEmulatorButton.Left:
          X := X - 51;
        TEmulatorButton.Right:
          X := X + 51;
      end;
      Arrow(X, Y, Angle, $FFDDE2D3);
    end;
  end;

  for var B in ActiveButtons * (ActionButtons + MenuButtons) do
  begin
    var Bounds := FBounds[B];
    var Level := FLevels[B];
    var Face := Bounds;
    Face.Inflate(-Face.Width * 0.025 * Level, -Face.Height * 0.025 * Level);
    Face.Offset(0, 1.3 * FUnit * Level);
    var Color: TAlphaColor := $FF36383A;
    var Caption := '';
    case B of
      TEmulatorButton.A:
        Caption := 'A';
      TEmulatorButton.B:
        Caption := 'B';
      TEmulatorButton.C:
        Caption := 'C';
      TEmulatorButton.X:
        Caption := 'X';
      TEmulatorButton.Y:
        Caption := 'Y';
      TEmulatorButton.Z:
        Caption := 'Z';
      TEmulatorButton.Select:
        Caption := 'SELECT';
      TEmulatorButton.Start:
        Caption := 'START';
      TEmulatorButton.Mode:
        Caption := 'MODE';
    end;
    var Shoulder := (FLayout = TScreenGamepadLayout.Snes) and (B in [TEmulatorButton.C, TEmulatorButton.Z]);
    if Shoulder then
    begin
      if B = TEmulatorButton.C then
        Caption := 'L'
      else
        Caption := 'R';
      Box(Face, MixColor($FFBFC1BF, $FFE3C368, Level), 7);
      Text(Face, Caption, $FF686C70, 8);
      Continue;
    end;
    if B in ActionButtons then
    begin
      case FLayout of
        TScreenGamepadLayout.Nes:
          Color := $FFD92F2D;
        TScreenGamepadLayout.Sega:
          if B in [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z] then
            Color := $FF838689;
        TScreenGamepadLayout.Snes:
          case B of
            TEmulatorButton.A:
              Color := $FFE03726;
            TEmulatorButton.B:
              Color := $FFF1C20D;
            TEmulatorButton.X:
              Color := $FF204CD2;
            TEmulatorButton.Y:
              Color := $FF00945B;
          end;
        TScreenGamepadLayout.NeoGeo:
          case B of
            TEmulatorButton.A:
              Color := $FFEE4139;
            TEmulatorButton.B:
              Color := $FFE5BE00;
            TEmulatorButton.C:
              Color := $FF00B24C;
            TEmulatorButton.X:
              begin
                Color := $FF007CB9;
                Caption := 'D';
              end;
          end;
      end;
      var Bezel := Face;
      Bezel.Inflate(2.7 * FUnit, 2.7 * FUnit);
      Oval(Bezel, $FF0A0C0E, $FF606467);
      Color := MixColor(Color, $FFFFD56B, Level * 0.6);
      Oval(Face, MixColor(Color, $FFFFFFFF, 0.2), MixColor(Color, $FF000000, 0.22));
      Canvas.Stroke.Color := MixColor(Color, $FFFFFFFF, 0.4);
      Canvas.Stroke.Thickness := 0.8 * FUnit;
      var Rim := Face;
      Rim.Inflate(-1.4 * FUnit, -1.4 * FUnit);
      Canvas.DrawEllipse(Rim, Opacity * 0.7);
      case FLayout of
        TScreenGamepadLayout.Nes:
          Text(RectF(Bounds.Left, Bounds.Bottom + 3 * FUnit, Bounds.Right,
              Bounds.Bottom + 16 * FUnit), Caption, $FFED4237, 12);
        TScreenGamepadLayout.Sega:
          begin
            var LetterColor := MixColor(Color, $FF000000, 0.65);
            if not SegaSixButtons then
              LetterColor := $FFE74732;
            TiltedText(Face, Caption, LetterColor, 14, FSegaButtonsAngle);
          end;
        TScreenGamepadLayout.Snes:
          case B of
            TEmulatorButton.X:
              Text(R(326, 38, 19, 14), Caption, $FFD2D4CF, 9);
            TEmulatorButton.Y:
              Text(R(244, 105, 16, 14), Caption, $FFD2D4CF, 9);
            TEmulatorButton.B:
              Text(R(306, 152, 16, 14), Caption, $FFD2D4CF, 9);
            TEmulatorButton.A:
              Text(R(365, 88, 16, 14), Caption, $FFD2D4CF, 9);
          end;
        TScreenGamepadLayout.NeoGeo:
          case B of
            TEmulatorButton.A:
              Text(R(280, 155, 22, 15), Caption, Ink, 12);
            TEmulatorButton.B:
              Text(R(365, 104, 20, 15), Caption, Ink, 12);
            TEmulatorButton.C:
              Text(R(253, 106, 20, 15), Caption, Ink, 12);
            TEmulatorButton.X:
              Text(R(332, 47, 20, 15), Caption, Ink, 12);
          end;
      end;
    end
    else
    begin
      var LabelBounds := Bounds;
      LabelBounds.Top := Bounds.Bottom + 3 * FUnit;
      LabelBounds.Bottom := LabelBounds.Top + 12 * FUnit;
      Color := MixColor(Color, $FFFFD56B, Level * 0.6);
      if FLayout = TScreenGamepadLayout.Nes then
      begin
        Face.Inflate(-2 * FUnit, -3 * FUnit);
        Gradient($FF595C5E, $FF26292B);
        Canvas.FillRect(Face, 7 * FUnit, 7 * FUnit, AllCorners, Opacity);
      end
      else if (FLayout = TScreenGamepadLayout.Sega) and not SegaSixButtons then
      begin
        Face.Inflate(-3 * FUnit, -6 * FUnit);
        TiltedCapsule(Face, -27, $FFB7C0C4, $FF4D555C);
        TiltedText(R(253, 47, 50, 13), 'START', Ink, 7, -27);
      end
      else if (FLayout = TScreenGamepadLayout.Sega) and SegaSixButtons then
      begin
        if B = TEmulatorButton.Start then
          Color := MixColor($FFCD3438, $FFFFD56B, Level * 0.6);
        if B = TEmulatorButton.Mode then
          Oval(Face, $FF818588, Color)
        else
        begin
          Gradient(MixColor(Color, $FFFFFFFF, 0.2), Color);
          Canvas.FillRect(Face, 8 * FUnit, 8 * FUnit, AllCorners, Opacity);
        end;
        Text(LabelBounds, Caption, Ink, 7);
      end
      else
      begin
        var Angle: Single := -30;
        if FLayout = TScreenGamepadLayout.Snes then
          Angle := -35;
        var BottomColor: TAlphaColor := $FF171A1B;
        if FLayout = TScreenGamepadLayout.Sega then
        begin
          Color := MixColor($FFBDC2C4, $FFFFD56B, Level * 0.6);
          BottomColor := $FF7E8589;
        end;
        Face.Inflate(-2 * FUnit, -7 * FUnit);
        TiltedOval(Face, Angle, MixColor(Color, $FFFFFFFF, 0.2), BottomColor);
        if FLayout in [TScreenGamepadLayout.NeoGeo, TScreenGamepadLayout.Sega] then
        begin
          LabelBounds.Bottom := Bounds.Top - 2 * FUnit;
          LabelBounds.Top := LabelBounds.Bottom - 12 * FUnit;
        end;
        Text(LabelBounds, Caption, Ink, 7);
      end;
    end;
  end;
  Canvas.Fill.Kind := TBrushKind.Solid;
end;

procedure TScreenGamepad.Paint;
const
  Labels: array[TEmulatorButton] of string = ('', '', '', '', 'A', 'B', 'SELECT', 'START', 'C', 'X', 'Y', 'Z', 'MODE');
var
  ShellColor, Ink, ButtonColor: TAlphaColor;
  Opacity, OX, OY: Single;

  function R(X, Y, W, H: Single): TRectF;
  begin
    Result := RectF(OX + X * FUnit, OY + Y * FUnit,
      OX + (X + W) * FUnit, OY + (Y + H) * FUnit);
  end;

  procedure Box(const Bounds: TRectF; Color: TAlphaColor; Radius: Single);
  begin
    Canvas.Fill.Color := Color;
    Canvas.FillRect(Bounds, Radius * FUnit, Radius * FUnit, AllCorners, Opacity);
  end;

  procedure Text(const Bounds: TRectF; const Caption: string; Color: TAlphaColor; Size: Single);
  begin
    Canvas.Fill.Color := Color;
    Canvas.Font.Size := Size * FUnit;
    Canvas.FillText(Bounds, Caption, False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
  end;

begin
  inherited;
  if not (FLayout in [TScreenGamepadLayout.GameBoy, TScreenGamepadLayout.GameBoyColor]) then
  begin
    PaintConsole;
    Exit;
  end;
  if FUnit <= 0 then
    Exit;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Font.Family := 'Arial';
  Canvas.Font.Style := [TFontStyle.fsBold];
  Opacity := AbsoluteOpacity;
  if not AbsoluteEnabled then
    Opacity := Opacity * 0.5;
  OX := (Width - 400 * FUnit) / 2;
  OY := (Height - 184 * FUnit) / 2;
  ShellColor := $FFD4D0BD;
  Ink := $FF303D78;
  if FLayout = TScreenGamepadLayout.GameBoyColor then
  begin
    ShellColor := $FF50448A;
    Ink := $FFE7E5EE;
  end;
  var Body := TPathData.Create;
  try
    Body.AddRectangle(FShell, 10 * FUnit, 10 * FUnit, AllCorners);
    Body.Translate(0, 3 * FUnit);
    Canvas.Fill.Color := $FF161619;
    Canvas.FillPath(Body, Opacity);
    Body.Translate(0, -3 * FUnit);
    Canvas.Fill.Color := ShellColor;
    Canvas.FillPath(Body, Opacity);
  finally
    Body.Free;
  end;
  Text(R(140, 32, 122, 25), 'Nintendo', Ink, 15);
  if FLayout = TScreenGamepadLayout.GameBoy then
    Text(R(133, 57, 136, 20), 'GAME BOY', Ink, 17)
  else
    Text(R(131, 57, 139, 20), 'GAME BOY COLOR', Ink, 13);
  for var I := 0 to 4 do
    Box(R(309 + I * 13, 166, 7, 2), $FF777478, 1);
  // The four arms meet the center to form the original solid plastic cross.
  Canvas.Fill.Color := $FF19191C;
  Canvas.FillEllipse(R(19, 37, 118, 118), Opacity * 0.18);
  var Cross := TPathData.Create;
  try
    Cross.MoveTo(PointF(60, 44));
    Cross.LineTo(PointF(96, 44));
    Cross.LineTo(PointF(96, 78));
    Cross.LineTo(PointF(130, 78));
    Cross.LineTo(PointF(130, 114));
    Cross.LineTo(PointF(96, 114));
    Cross.LineTo(PointF(96, 148));
    Cross.LineTo(PointF(60, 148));
    Cross.LineTo(PointF(60, 114));
    Cross.LineTo(PointF(26, 114));
    Cross.LineTo(PointF(26, 78));
    Cross.LineTo(PointF(60, 78));
    Cross.ClosePath;
    Cross.Scale(FUnit, FUnit);
    Cross.Translate(OX, OY);
    Canvas.Fill.Color := $FF303034;
    Canvas.FillPath(Cross, Opacity);
    Canvas.Stroke.Color := $FF151518;
    Canvas.Stroke.Thickness := 2 * FUnit;
    Canvas.DrawPath(Cross, Opacity);
  finally
    Cross.Free;
  end;
  for var Button in ActiveButtons do
  begin
    var Bounds := FBounds[Button];
    var Level := FLevels[Button];
    var RoundButton := Button in ActionButtons;
    var Face := Bounds;
    Face.Inflate(-Face.Width * 0.035 * Level, -Face.Height * 0.035 * Level);
    Face.Offset(0, 1.5 * FUnit * Level);
    var Directional := Button in [TEmulatorButton.Up, TEmulatorButton.Down,
        TEmulatorButton.Left, TEmulatorButton.Right];
    if Button in MenuButtons then
      Face.Inflate(-3 * FUnit, -4 * FUnit);
    var Bezel := Face;
    Bezel.Inflate(3 * FUnit, 3 * FUnit);
    Canvas.Fill.Color := $FF17171A;
    if RoundButton then
      Canvas.FillEllipse(Bezel, Opacity)
    else if not Directional then
      Box(Bezel, $FF17171A, 5);
    ButtonColor := $FF343438;
    if RoundButton then
      if FLayout = TScreenGamepadLayout.GameBoy then
        ButtonColor := $FF8C2351
      else
        ButtonColor := $FF33343A;
    Canvas.Fill.Color := MixColor(ButtonColor, $FFE1CA8B, Level * 0.65);
    if RoundButton then
      Canvas.FillEllipse(Face, Opacity)
    else if not Directional or (Level > 0) then
      Canvas.FillRect(Face, 3 * FUnit, 3 * FUnit, AllCorners, Opacity);
    Canvas.Stroke.Color := MixColor(ButtonColor, $FFFFFFFF, 0.22);
    Canvas.Stroke.Thickness := Max(0.5, FUnit);
    if RoundButton then
      Canvas.DrawEllipse(Face, Opacity)
    else if not Directional then
      Canvas.DrawRect(Face, 3 * FUnit, 3 * FUnit, AllCorners, Opacity);
    var Caption := Labels[Button];
    if RoundButton then
    begin
      if FLayout in [TScreenGamepadLayout.Nes, TScreenGamepadLayout.GameBoy,
          TScreenGamepadLayout.GameBoyColor] then
      begin
        var LabelBounds := Bounds;
        LabelBounds.Top := Bounds.Bottom + 3 * FUnit;
        LabelBounds.Bottom := LabelBounds.Top + 15 * FUnit;
        var LabelInk := Ink;
        Text(LabelBounds, Caption, LabelInk, 12);
      end
      else
        Text(Face, Caption, $FFF5F3E9, 17);
    end
    else if Button in MenuButtons then
    begin
      var LabelBounds := Bounds;
      LabelBounds.Top := Bounds.Bottom + 4 * FUnit;
      LabelBounds.Bottom := LabelBounds.Top + 12 * FUnit;
      var LabelInk := Ink;
      Text(LabelBounds, Caption, LabelInk, 8);
    end
    else if Caption <> '' then
      Text(Face, Caption, $FF44434C, 10)
    else
    begin
      // Raised ridges on the cross arms.
      var C := Face.CenterPoint;
      Canvas.Stroke.Color := $FF67676B;
      for var I := -1 to 1 do
        if Button in [TEmulatorButton.Up, TEmulatorButton.Down] then
          Canvas.DrawLine(PointF(C.X - 7 * FUnit, C.Y + I * 4 * FUnit),
            PointF(C.X + 7 * FUnit, C.Y + I * 4 * FUnit), Opacity)
        else
          Canvas.DrawLine(PointF(C.X + I * 4 * FUnit, C.Y - 7 * FUnit),
            PointF(C.X + I * 4 * FUnit, C.Y + 7 * FUnit), Opacity);
    end;
  end;
end;

procedure TScreenGamepad.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FNativeInput = nil then
  begin
    if Button = TMouseButton.mbLeft then
      PointerDown(-1, PointF(X, Y));
  end;
end;

procedure TScreenGamepad.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FNativeInput = nil then
  begin
    PointerMove(-1, PointF(X, Y));
  end;
end;

procedure TScreenGamepad.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FNativeInput = nil then
  begin
    if Button = TMouseButton.mbLeft then
      PointerUp(-1);
  end;
end;

end.

