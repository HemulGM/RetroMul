unit RM.Gamepad;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.Controller, Core.Emulation;

type
  TScreenGamepadLayout = (Nes, Sega, Snes, GameBoy, GameBoyColor);

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
    FUnit: Single;
    FLevels, FStarts, FTargets: array[TEmulatorButton] of Single;
    FTimes: array[TEmulatorButton] of Int64;
    FAnimation: TTimer;
    FNativeInput: TObject;
    procedure SetLayout(Value: TScreenGamepadLayout);
    procedure SetButtonMask(const Value: TEmulatorButtons);
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
  FMX.Graphics;

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

procedure TScreenGamepad.LayoutButtons;
const
  SegaActions: array[0..5] of TEmulatorButton =
    (TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z,
    TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
var
  U, OX, OY, CX, CY: Single;

  function R(X, Y, W, H: Single): TRectF;
  begin
    Result := RectF(OX + X * U, OY + Y * U, OX + (X + W) * U, OY + (Y + H) * U);
  end;

begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    FBounds[Button] := TRectF.Empty;
  // One coordinate system for artwork and input, including wide tablet panels.
  U := Max(0.001, Min(Width / 400, Height / 184));
  OX := (Width - 400 * U) / 2;
  OY := (Height - 184 * U) / 2;
  FUnit := U;
  FShell := R(6, 6, 388, 172);
  CX := 78;
  CY := 96;
  FDPad := R(CX - 56, CY - 56, 112, 112);
  FBounds[TEmulatorButton.Up] := R(CX - 18, CY - 52, 36, 34);
  FBounds[TEmulatorButton.Down] := R(CX - 18, CY + 18, 36, 34);
  FBounds[TEmulatorButton.Left] := R(CX - 52, CY - 18, 34, 36);
  FBounds[TEmulatorButton.Right] := R(CX + 18, CY - 18, 34, 36);
  FBounds[TEmulatorButton.B] := R(270, 92, 46, 46);
  FBounds[TEmulatorButton.A] := R(330, 92, 46, 46);
  FBounds[TEmulatorButton.Select] := R(151, 119, 44, 18);
  FBounds[TEmulatorButton.Start] := R(207, 119, 44, 18);
  case FLayout of
    TScreenGamepadLayout.Sega:
      begin
        for var I := Low(SegaActions) to High(SegaActions) do
          FBounds[SegaActions[I]] := R(252 + (I mod 3) * 43,
              55 + (I div 3) * 46 - (I mod 3) * 7, 36, 36);
        FBounds[TEmulatorButton.Start] := R(171, 79, 46, 18);
        FBounds[TEmulatorButton.Mode] := R(184, 142, 36, 14);
        FBounds[TEmulatorButton.Select] := TRectF.Empty;
      end;
    TScreenGamepadLayout.Snes:
      begin
        FBounds[TEmulatorButton.X] := R(291, 42, 38, 38);
        FBounds[TEmulatorButton.B] := R(291, 116, 38, 38);
        FBounds[TEmulatorButton.Y] := R(254, 79, 38, 38);
        FBounds[TEmulatorButton.A] := R(328, 79, 38, 38);
        FBounds[TEmulatorButton.C] := R(38, 8, 94, 19);
        FBounds[TEmulatorButton.Z] := R(268, 8, 94, 19);
        FBounds[TEmulatorButton.Select] := R(153, 102, 36, 17);
        FBounds[TEmulatorButton.Start] := R(207, 102, 36, 17);
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
  ShellColor := $FFC9C8C3;
  Ink := $FF313136;
  case FLayout of
    TScreenGamepadLayout.Sega:
      begin
        ShellColor := $FF242429;
        Ink := $FFD6D6D9;
      end;
    TScreenGamepadLayout.Snes:
      ShellColor := $FFD7D6D2;
    TScreenGamepadLayout.GameBoy:
      begin
        ShellColor := $FFD4D0BD;
        Ink := $FF303D78;
      end;
    TScreenGamepadLayout.GameBoyColor:
      begin
        ShellColor := $FF50448A;
        Ink := $FFE7E5EE;
      end;
  end;
  var Body := TPathData.Create;
  try
    if FLayout in [TScreenGamepadLayout.Sega, TScreenGamepadLayout.Snes] then
    begin
      Body.MoveTo(PointF(84, 18));
      Body.CurveTo(PointF(123, 18), PointF(130, 26), PointF(151, 26));
      Body.LineTo(PointF(249, 26));
      Body.CurveTo(PointF(270, 26), PointF(277, 18), PointF(316, 18));
      Body.CurveTo(PointF(362, 18), PointF(394, 48), PointF(394, 98));
      Body.CurveTo(PointF(394, 146), PointF(362, 178), PointF(316, 178));
      Body.CurveTo(PointF(276, 178), PointF(261, 155), PointF(246, 154));
      Body.LineTo(PointF(154, 154));
      Body.CurveTo(PointF(139, 155), PointF(124, 178), PointF(84, 178));
      Body.CurveTo(PointF(38, 178), PointF(6, 146), PointF(6, 98));
      Body.CurveTo(PointF(6, 48), PointF(38, 18), PointF(84, 18));
      Body.ClosePath;
      Body.Scale(FUnit, FUnit);
      Body.Translate(OX, OY);
    end
    else
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
  case FLayout of
    TScreenGamepadLayout.Nes:
      begin
        Box(R(18, 35, 364, 132), $FF29292B, 4);
        for var I := 0 to 3 do
          Box(R(140, 49 + I * 16, 112, 9), $FF787975, 2);
        Box(R(145, 113, 110, 30), $FFB5B6AF, 3);
        Text(R(263, 41, 115, 23), 'Nintendo', $FFE0433C, 17);
      end;
    TScreenGamepadLayout.Sega:
      begin
        Text(R(155, 32, 80, 22), 'SEGA', $FFDEE1E8, 19);
        Text(R(146, 57, 100, 14), 'MEGA DRIVE', Ink, 8);
      end;
    TScreenGamepadLayout.Snes:
      begin
        Canvas.Fill.Color := $FFB2B1B8;
        Canvas.FillEllipse(R(244, 31, 133, 133), Opacity);
        Text(R(138, 42, 117, 16), 'SUPER NINTENDO', $FF595960, 9);
        Text(R(139, 57, 114, 11), 'ENTERTAINMENT SYSTEM', $FF77777D, 6);
      end;
    TScreenGamepadLayout.GameBoy, TScreenGamepadLayout.GameBoyColor:
      begin
        Text(R(140, 32, 122, 25), 'Nintendo', Ink, 15);
        if FLayout = TScreenGamepadLayout.GameBoy then
          Text(R(133, 57, 136, 20), 'GAME BOY', Ink, 17)
        else
          Text(R(131, 57, 139, 20), 'GAME BOY COLOR', Ink, 13);
        for var I := 0 to 4 do
          Box(R(309 + I * 13, 166, 7, 2), $FF777478, 1);
      end;
  end;
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
    if (FLayout = TScreenGamepadLayout.Snes) and
      (Button in [TEmulatorButton.C, TEmulatorButton.Z]) then
      RoundButton := False;
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
      case FLayout of
        TScreenGamepadLayout.Nes:
          ButtonColor := $FFC63130;
        TScreenGamepadLayout.GameBoy:
          ButtonColor := $FF8C2351;
        TScreenGamepadLayout.GameBoyColor:
          ButtonColor := $FF33343A;
        TScreenGamepadLayout.Sega:
          if Button in [TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z] then
            ButtonColor := $FF85858A;
        TScreenGamepadLayout.Snes:
          case Button of
            TEmulatorButton.A:
              ButtonColor := $FFBD343D;
            TEmulatorButton.B:
              ButtonColor := $FFDAB739;
            TEmulatorButton.X:
              ButtonColor := $FF345CB2;
            TEmulatorButton.Y:
              ButtonColor := $FF33855A;
          end;
      end;
    if (FLayout = TScreenGamepadLayout.Snes) and
      (Button in [TEmulatorButton.C, TEmulatorButton.Z]) then
      ButtonColor := $FFA6A5AC;
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
    if FLayout = TScreenGamepadLayout.Snes then
      case Button of
        TEmulatorButton.C:
          Caption := 'L';
        TEmulatorButton.Z:
          Caption := 'R';
      end;
    if RoundButton then
    begin
      if FLayout in [TScreenGamepadLayout.Nes, TScreenGamepadLayout.GameBoy,
          TScreenGamepadLayout.GameBoyColor] then
      begin
        var LabelBounds := Bounds;
        LabelBounds.Top := Bounds.Bottom + 3 * FUnit;
        LabelBounds.Bottom := LabelBounds.Top + 15 * FUnit;
        var LabelInk := Ink;
        if FLayout = TScreenGamepadLayout.Nes then
          LabelInk := $FFE0433C;
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
      if FLayout = TScreenGamepadLayout.Nes then
        LabelInk := $FFE0433C;
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

