unit RM.Settings.Callouts;

interface

uses
  System.Classes, System.Types, FMX.Controls, FMX.StdCtrls, FMXInput;

type
  TDeviceCalloutContext = record
    SystemId: string;
    Port: Integer;
    Device: TControl; // Borrowed; owned by the diagram/view.
  end;

  TDeviceCalloutDefinition = record
    Button, Action: Integer;
    Name, Caption: string;
    Left: Boolean;
    class function Create(Button, Action: Integer; const Name, Caption: string; Left: Boolean): TDeviceCalloutDefinition; static;
  end;

  TPlatformDeviceCallouts = class
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; virtual;
    class function ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF; virtual;
    class function AspectRatio(const Context: TDeviceCalloutContext): Single; virtual;
    class function ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean; virtual;
    // Points are in diagram coordinates. The first point receives the anchor dot.
    class function LinePath(const Context: TDeviceCalloutContext; const Definition: TDeviceCalloutDefinition; const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>; virtual;
  end;

  TPlatformDeviceCalloutsClass = class of TPlatformDeviceCallouts;

  TDeviceCallouts = class;

  TBindingLines = class(TControl)
  protected
    procedure Paint; override;
  end;

  TBindingCallout = record
    Definition: TDeviceCalloutDefinition;
    LabelControl: TLabel;
  end;

  TDeviceCallouts = class(TControl)
  private
    FDevice: TControl;
    FCalloutProvider: TPlatformDeviceCalloutsClass;
    FCalloutContext: TDeviceCalloutContext;
    FItems: TArray<TBindingCallout>;
    FLines: TBindingLines;
    FInput: TInputManager;
    FAnnotations: Boolean;
    function ButtonBounds(Index: Integer): TRectF;
    procedure AddCallout(const Definition: TDeviceCalloutDefinition; Click: TNotifyEvent);
  protected
    procedure Resize; override;
  public
    procedure Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
    procedure Refresh;
    procedure ShowAnnotations(Value: Boolean);
  end;

procedure RegisterPlatformDeviceCallouts(const PlatformId: string; Provider: TPlatformDeviceCalloutsClass);

function TryPlatformDeviceCallouts(const PlatformId: string; out Provider: TPlatformDeviceCalloutsClass): Boolean;

function PlatformDeviceCallouts(const PlatformId: string): TPlatformDeviceCalloutsClass;

implementation

uses
  System.SysUtils, System.Generics.Collections, System.Generics.Defaults,
  System.Math, System.UITypes, FMX.Types, FMX.Graphics, FMX.Text, Core.Platforms,
  Core.Emulation, RM.Gamepad, RM.Input;

var
  Providers: TDictionary<string, TPlatformDeviceCalloutsClass>;

class function TDeviceCalloutDefinition.Create(Button, Action: Integer; const Name, Caption: string; Left: Boolean): TDeviceCalloutDefinition;
begin
  Result.Button := Button;
  Result.Action := Action;
  Result.Name := Name;
  Result.Caption := Caption;
  Result.Left := Left;
end;

procedure RegisterPlatformDeviceCallouts(const PlatformId: string; Provider: TPlatformDeviceCalloutsClass);
begin
  var Id := PlatformId.Trim.ToLower;
  if (Id = '') or (Provider = nil) then
    raise EArgumentException.Create('Invalid device callouts provider: ' + PlatformId);
  if Providers.ContainsKey(Id) then
    raise EArgumentException.Create('Duplicate device callouts provider: ' + Id);
  Providers.Add(Id, Provider);
end;

function TryPlatformDeviceCallouts(const PlatformId: string; out Provider: TPlatformDeviceCalloutsClass): Boolean;
begin
  Provider := nil;
  var Id := PlatformId.Trim.ToLower;
  Result := Providers.TryGetValue(Id, Provider);
  if not Result then
    Result := Providers.TryGetValue(TPlatformRegistry.CanonicalId(Id), Provider);
end;

function PlatformDeviceCallouts(const PlatformId: string): TPlatformDeviceCalloutsClass;
begin
  if not TryPlatformDeviceCallouts(PlatformId, Result) then
    Result := TPlatformDeviceCallouts;
end;

class function TPlatformDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := nil;
  if not (Context.Device is TScreenGamepad) then
    Exit;
  for var Button in TScreenGamepad(Context.Device).ButtonMask do
  begin
    if ButtonBounds(Context, Ord(Button)).IsEmpty then
      Continue;
    var Left := Button in [TEmulatorButton.Up, TEmulatorButton.Down,
        TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.Select, TEmulatorButton.Mode];
    var Name := Translate(CoreButtonName(Context.SystemId, Button));
    Result := Result + [TDeviceCalloutDefinition.Create(Ord(Button), PadAction(Context.Port, Button),
      Name, Translate('Button ') + Name, Left)];
  end;
end;

class function TPlatformDeviceCallouts.ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF;
begin
  Result := TRectF.Empty;
  if not (Context.Device is TScreenGamepad) then
    Exit;
  if Button < 0 then
    Result := TScreenGamepad(Context.Device).AuxiliaryButtonBounds(-1 - Button)
  else
    Result := TScreenGamepad(Context.Device).ButtonBounds(TEmulatorButton(Button));
end;

class function TPlatformDeviceCallouts.AspectRatio(const Context: TDeviceCalloutContext): Single;
begin
  Result := 0.46;
  if Context.Device is TScreenGamepad then
    Result := TScreenGamepad(Context.Device).AspectRatio;
end;

class function TPlatformDeviceCallouts.ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean;
begin
  Result := False;
end;

class function TPlatformDeviceCallouts.LinePath(const Context: TDeviceCalloutContext; const Definition: TDeviceCalloutDefinition; const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>;
begin
  var Start := Bounds.CenterPoint + Context.Device.Position.Point;
  var Finish := TPointF.Create(LabelControl.Position.X - 5, LabelControl.Position.Y + LabelControl.Height / 2);
  Start.X := Bounds.Right + Context.Device.Position.X;
  if Definition.Left then
  begin
    Start.X := Bounds.Left + Context.Device.Position.X;
    Finish.X := LabelControl.Position.X + LabelControl.Width + 5;
  end;
  var Elbow := TPointF.Create((Start.X + Finish.X) / 2, Finish.Y);
  Result := [Start, Elbow, Finish];
end;

function TDeviceCallouts.ButtonBounds(Index: Integer): TRectF;
begin
  Result := FCalloutProvider.ButtonBounds(FCalloutContext, FItems[Index].Definition.Button);
end;

procedure TDeviceCallouts.AddCallout(const Definition: TDeviceCalloutDefinition; Click: TNotifyEvent);
begin
  var Index := Length(FItems);
  SetLength(FItems, Index + 1);
  FItems[Index].Definition := Definition;
  var L := TLabel.Create(Self);
  FItems[Index].LabelControl := L;
  L.Parent := Self;
  L.Height := 28;
  L.HitTest := FInput <> nil;
  L.OnClick := Click;
  L.Tag := Definition.Action;
  L.TagString := Definition.Caption;
  L.StyledSettings := L.StyledSettings - [TStyledSetting.Size, TStyledSetting.Other];
  L.TextSettings.Font.Size := 12;
  L.TextSettings.WordWrap := False;
  L.TextSettings.Trimming := TTextTrimming.Character;
  if Definition.Left then
    L.TextSettings.HorzAlign := TTextAlign.Trailing
  else
    L.TextSettings.HorzAlign := TTextAlign.Leading;
end;

procedure TDeviceCallouts.Configure(Device: TControl; Input: TInputManager; const Core: string; Port: Integer; Click: TNotifyEvent);
begin
  FCalloutContext.SystemId := Core;
  FCalloutContext.Port := Port;
  FCalloutContext.Device := Device;
  FCalloutProvider := PlatformDeviceCallouts(Core);
  HitTest := False;
  FDevice := Device;
  FInput := Input;
  FDevice.Parent := Self;
  FAnnotations := True;
  FDevice.Align := TAlignLayout.None;
  FLines := TBindingLines.Create(Self);
  FLines.Parent := Self;
  FLines.Align := TAlignLayout.Client;
  FLines.HitTest := False;
  for var Definition in FCalloutProvider.Definitions(FCalloutContext) do
    AddCallout(Definition, Click);
  Refresh;
  Resize;
end;

procedure TDeviceCallouts.Refresh;
begin
  for var Item in FItems do
  begin
    var L := Item.LabelControl;
    if L = nil then
      Continue;

    var Assignment := BindingCaption(FInput, L.Tag, FCalloutContext.SystemId);
    L.Text := Item.Definition.Name + ' · ' + Assignment;
    if Width < 460 then
      L.Text := Assignment;
    L.Hint := L.TagString + ': ' + Assignment;
    L.ShowHint := True;
  end;
end;

procedure TDeviceCallouts.Resize;
begin
  inherited;
  if csDestroying in ComponentState then
    Exit;
  if (FDevice = nil) or (FLines = nil) then
    Exit;

  var Rail := Min(170, Max(40, Width * 0.18));
  if not FAnnotations then
    Rail := 0;
  var Aspect := FCalloutProvider.AspectRatio(FCalloutContext);
  var Limit := IfThen(FAnnotations, 400, 640);
  var PadWidth := Min(Min(Limit, Max(40, Height / Aspect)), Max(40, Width - 2 * (Rail + 12)));
  FDevice.SetBounds((Width - PadWidth) / 2, (Height - PadWidth * Aspect) / 2,
    PadWidth, PadWidth * Aspect);
  for var Side := 0 to 1 do
  begin
    var Buttons: TArray<Integer> := nil;
    for var B := 0 to High(FItems) do
      if FItems[B].Definition.Left = (Side = 0) then
      begin
        var N := Length(Buttons);
        SetLength(Buttons, N + 1);
        Buttons[N] := B;
      end;
    // Match vertical button order to the callouts to limit crossed leaders.
    for var i := 0 to High(Buttons) - 1 do
      for var J := i + 1 to High(Buttons) do
      begin
        var ReverseColumns := FCalloutProvider.ReverseColumns(FCalloutContext, Side = 0);
        var EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X < ButtonBounds(Buttons[i]).CenterPoint.X;
        if ReverseColumns then
          EarlierColumn := ButtonBounds(Buttons[J]).CenterPoint.X > ButtonBounds(Buttons[i]).CenterPoint.X;
        if (ButtonBounds(Buttons[J]).CenterPoint.Y < ButtonBounds(Buttons[i]).CenterPoint.Y) or
          ((ButtonBounds(Buttons[J]).CenterPoint.Y = ButtonBounds(Buttons[i]).CenterPoint.Y) and
          EarlierColumn) then
        begin
          var B := Buttons[i];
          Buttons[i] := Buttons[J];
          Buttons[J] := B;
        end;
      end;
    var Step := Min(34, Height / Max(1, Length(Buttons)));
    for var i := 0 to High(Buttons) do
    begin
      var L := FItems[Buttons[i]].LabelControl;
      var X: Single := 0;
      if Side = 1 then
        X := Width - Rail;
      L.SetBounds(X, (Height - Step * Length(Buttons)) / 2 + i * Step + (Step - L.Height) / 2,
        Rail, L.Height);
    end;
  end;
  Refresh;
  FLines.Repaint;
end;

procedure TDeviceCallouts.ShowAnnotations(Value: Boolean);
begin
  FAnnotations := Value;
  for var Item in FItems do
    Item.LabelControl.Visible := Value;
  FLines.Visible := Value;
  Resize;
end;

procedure TBindingLines.Paint;
begin
  inherited;
  // PaintTo temporarily detaches Parent when rendering to a bitmap.
  var D := TDeviceCallouts(Owner);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := TAlphaColors.Gray;
  Canvas.Stroke.Thickness := 1;
  for var B := 0 to High(D.FItems) do
  begin
    var R := D.ButtonBounds(B);
    var L := D.FItems[B].LabelControl;
    var Points := D.FCalloutProvider.LinePath(D.FCalloutContext, D.FItems[B].Definition, R, L);
    for var i := 0 to High(Points) - 1 do
      Canvas.DrawLine(Points[i], Points[i + 1], AbsoluteOpacity * 0.8);
    if Length(Points) > 0 then
    begin
      var Start := Points[0];
      Canvas.Fill.Color := TAlphaColors.Gray;
      Canvas.FillEllipse(TRectF.Create(Start.X - 2, Start.Y - 2, Start.X + 2, Start.Y + 2), AbsoluteOpacity);
    end;
  end;
end;

initialization
  Providers := TDictionary<string, TPlatformDeviceCalloutsClass>.Create(TIStringComparer.Ordinal);

finalization
  Providers.Free;

end.

