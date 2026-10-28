unit RM.Platforms.NES.Devices;

interface

uses
  FMX.Controls, RM.Settings.Builder, RM.Settings.Devices, System.Types,
  RM.Settings.Callouts;

type
  TNESSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function SourceKey(const Context: TSettingsDeviceContext): string; override;
    class procedure BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder); override;
    class function DirectBindings(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function CreateVisual(const Context: TSettingsDeviceContext): TSettingsDeviceVisual; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
    class procedure Disconnect(const Context: TSettingsDeviceContext; Control: TControl); override;
  end;

type
  TNESDeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
    class function ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF; override;
    class function AspectRatio(const Context: TDeviceCalloutContext): Single; override;
    class function ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean; override;
    class function LinePath(const Context: TDeviceCalloutContext; const Definition: TDeviceCalloutDefinition; const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>; override;
  end;

implementation

uses
  RM.Platforms.NES.Input, System.SysUtils, System.TypInfo, FMX.Types,
  Core.Emulation, RM.Input, RM.Platforms.NES.Controls.PowerPad,
  RM.Platforms.NES.Keyboard, RM.Platforms.NES.Controls.MiraclePiano,
  NES.Controller, NES.FamicomKeyboardDevice, NES.MiraclePianoDevice;

class function TNESSettingsDevices.SourceKey(const Context: TSettingsDeviceContext): string;
begin
  if Context.Port = 4 then
    Result := 'SourceExpansion'
  else
    Result := inherited SourceKey(Context);
end;

class procedure TNESSettingsDevices.BindingFields(const Context: TSettingsDeviceContext; Page: TSettingsPageBuilder);
begin
  if Context.Device = 'piano' then
    Page.AddBoolean('RowPhysicalkeyboard2' + IntToStr(Context.Port), 'Physical keyboard',
      'Notes Z–M and Q–P; Space is the pedal. An on-screen piano is also available.', 'Ports', 'KeyboardEnabled', True);
end;

class function TNESSettingsDevices.DirectBindings(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := nil;
  if Context.Device = 'zapper' then
    Result := TArray<TSettingsDeviceBinding>.Create(TSettingsDeviceBinding.Create(ZapperTriggerAction, 'Zapper trigger'));
end;

class function TNESSettingsDevices.CreateVisual(const Context: TSettingsDeviceContext): TSettingsDeviceVisual;
begin
  Result := Default(TSettingsDeviceVisual);
  Result.InitialHeight := 340;
  if Context.Device = 'powerpad' then
  begin
    var Pad := TGamepadNESPowerPad.Create(Context.Owner);
    Pad.OnChange := Context.OnChange;
    Result.Control := Pad;
    Result.Diagram := Context.CreateDiagram(Pad);
    Result.InitialHeight := 448;
  end
  else if Context.Device = 'subor' then
  begin
    var Keyboard := TNesSuborKeyboard.Create(Context.Owner);
    Keyboard.OnChange := Context.OnChange;
    Result.Control := Keyboard;
  end
  else if Context.Device = 'famicom' then
  begin
    var Keyboard := TNesFamicomKeyboard.Create(Context.Owner);
    Keyboard.OnChange := Context.OnChange;
    Result.Control := Keyboard;
  end
  else if Context.Device = 'piano' then
  begin
    var Piano := TNesMiraclePiano.Create(Context.Owner);
    Piano.OnChange := Context.OnChange;
    Result.Control := Piano;
  end
  else
    Result := inherited CreateVisual(Context);
end;

class function TNESSettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
const
  Mapping: array[TNesButton] of TEmulatorButton = (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
    TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right);
  Notes: array[0..11] of string = ('C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B');
begin
  Result := inherited Selection(Context, Control);
  if Control is TGamepadNESPowerPad then
    for var B in TGamepadNESPowerPad(Control).Buttons do
      Exit(TSettingsDeviceBinding.Create(PowerPadAction + B - 1, Translate('Pad ') + IntToStr(B)));
  if Control is TNesSuborKeyboard then
    for var K in TNesSuborKeyboard(Control).Keys do
      Exit(TSettingsDeviceBinding.Create(SuborAction + Ord(K), Translate('Key ') + Copy(GetEnumName(TypeInfo(TSuborKey), Ord(K)), 3, MaxInt)));
  if Control is TNesFamicomKeyboard then
    for var K in TNesFamicomKeyboard(Control).Keys do
      Exit(TSettingsDeviceBinding.Create(FamicomAction + Ord(K), Translate('Key ') + Copy(GetEnumName(TypeInfo(TFamicomKey), Ord(K)), 3, MaxInt)));
  if Control is TNesMiraclePiano then
  begin
    for var K in TNesMiraclePiano(Control).Keys do
      if K < 49 then
        Exit(TSettingsDeviceBinding.Create(PianoAction + K, Translate('Note ') + Notes[K mod 12] + IntToStr(2 + K div 12)))
      else
        Exit(TSettingsDeviceBinding.Create(PianoAction + K, Translate('Piano button ') + IntToStr(K)));
    if Result.Action < 0 then
      for var B in TNesMiraclePiano(Control).Buttons do
        Exit(TSettingsDeviceBinding.Create(PadAction(0, Mapping[B]), Translate('Button ') + CoreButtonName(Context.SystemId, Mapping[B])));
  end;
end;

class procedure TNESSettingsDevices.Disconnect(const Context: TSettingsDeviceContext; Control: TControl);
begin
  inherited;
  if Control is TGamepadNESPowerPad then
    TGamepadNESPowerPad(Control).OnChange := nil;
  if Control is TNesSuborKeyboard then
    TNesSuborKeyboard(Control).OnChange := nil;
  if Control is TNesFamicomKeyboard then
    TNesFamicomKeyboard(Control).OnChange := nil;
  if Control is TNesMiraclePiano then
    TNesMiraclePiano(Control).OnChange := nil;
end;

class function TNESDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  if not (Context.Device is TGamepadNESPowerPad) then
    Exit(inherited Definitions(Context));
  Result := nil;
  for var Button := 1 to 12 do
    Result := Result + [TDeviceCalloutDefinition.Create(Button, PowerPadAction + Button - 1,
      IntToStr(Button), Translate('Pad ') + IntToStr(Button), (Button - 1) mod 4 < 2)];
end;

class function TNESDeviceCallouts.ButtonBounds(const Context: TDeviceCalloutContext; Button: Integer): TRectF;
begin
  if Context.Device is TGamepadNESPowerPad then
    Result := TGamepadNESPowerPad(Context.Device).ButtonBounds(Button)
  else
    Result := inherited ButtonBounds(Context, Button);
end;

class function TNESDeviceCallouts.AspectRatio(const Context: TDeviceCalloutContext): Single;
begin
  if Context.Device is TGamepadNESPowerPad then
    Result := TGamepadNESPowerPad(Context.Device).AspectRatio
  else
    Result := inherited AspectRatio(Context);
end;

class function TNESDeviceCallouts.ReverseColumns(const Context: TDeviceCalloutContext; Left: Boolean): Boolean;
begin
  Result := (Context.Device is TGamepadNESPowerPad) and not Left;
end;

class function TNESDeviceCallouts.LinePath(const Context: TDeviceCalloutContext; const Definition: TDeviceCalloutDefinition; const Bounds: TRectF; LabelControl: TControl): TArray<TPointF>;
begin
  if not (Context.Device is TGamepadNESPowerPad) or not ((Definition.Button - 1) mod 4 in [1, 2]) then
    Exit(inherited LinePath(Context, Definition, Bounds, LabelControl));
  // Inner columns pass through the gaps below each row, away from pad numbers.
  var Start := TPointF.Create(Bounds.CenterPoint.X + Context.Device.Position.X, Bounds.Bottom + Context.Device.Position.Y);
  var Finish := TPointF.Create(LabelControl.Position.X - 5, LabelControl.Position.Y + LabelControl.Height / 2);
  var RailX := Context.Device.Position.X + Context.Device.Width + 8;
  if Definition.Left then
  begin
    Finish.X := LabelControl.Position.X + LabelControl.Width + 5;
    RailX := Context.Device.Position.X - 8;
  end;
  var ExitPoint := TPointF.Create(Start.X, Start.Y + 4);
  var Outside := TPointF.Create(RailX, ExitPoint.Y);
  var Elbow := TPointF.Create(RailX, Finish.Y);
  Result := [Start, ExitPoint, Outside, Elbow, Finish];
end;

end.

