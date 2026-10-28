unit RM.Platforms.ColecoVision.Input;

interface

uses
  Core.Emulation.Types, RM.Input.Runtime, RM.Settings.Callouts,
  RM.ControlsHelp.Content, RM.Settings.Devices, FMX.Controls;

type
  TColecoInputHandler = class(TPlatformInputHandler)
  public
    class function KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy; override;
    class procedure CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput); override;
  end;

  TColecoDeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

  TColecoSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

  TColecoControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; override;
  end;

implementation

uses
  System.SysUtils, FMX.Types, Core.Platforms.ColecoVision.Adapter, RM.Gamepad,
  RM.Input;

class function TColecoInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  // Numeric keys belong to the controller, including Q/W/E/R for star/hash.
  // Preserve direct host keys alongside user-configurable pad bindings.
  Result.KeyboardActive := (Context.State = nil) or Context.State.Input.Ports.KeyboardEnabled;
  Result.ForwardWithManager := True;
  Result.AllowSnapshotsWithKeyboard := True;
end;

class procedure TColecoInputHandler.CombineInput(const Context: TInputRuntimeContext; var Input: TEmulatorInput);
begin
  var Mask: Cardinal := 0;
  if Context.State.Input.Gamepad <> nil then
    Mask := Context.State.Input.Gamepad.AuxiliaryButtons;
  if Mask and $3000 <> 0 then
  begin
    Input.Analog[0].Valid := True;
    Input.Analog[0].X := (Ord(Mask and $2000 <> 0) - Ord(Mask and $1000 <> 0)) * 24576;
  end;
  var Keypad: IColecoKeypadInput;
  if Supports(Context.State.Session.Emulation, IColecoKeypadInput, Keypad) then
  begin
    Keypad.SetVirtualKeypad(0, Mask and $FFF);
  end;
end;

class function TColecoDeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited;
  for var I := 0 to High(Result) do
  begin
    Result[I].Left := not (TEmulatorButton(Result[I].Button) in [TEmulatorButton.Start, TEmulatorButton.Select]);
    if (Context.Device is TScreenGamepad) and
      (TScreenGamepad(Context.Device).DeviceId = 'driving') and
      (Result[I].Button = Ord(TEmulatorButton.A)) then
    begin
      Result[I].Name := Translate('Gas');
      Result[I].Caption := Translate('Gas pedal');
    end;
  end;
end;

class function TColecoSettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited;
  if Context.Device = 'driving' then
    for var I := 0 to High(Result) do
      if Result[I].Action = PadAction(Context.Port, TEmulatorButton.A) then
        Result[I].Caption := 'Gas';
end;

class function TColecoSettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := inherited;
  if (Context.Device = 'driving') and (Result.Action = PadAction(Context.Port, TEmulatorButton.A)) then
    Result.Caption := Translate('Gas pedal');
end;

class function TColecoControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited;
  Result.ControllerTitle := 'ColecoVision';
  if Context.Ports.Devices[Context.Player] = 'superaction' then
    Result.AssignmentCaptionWidth := 90;
  Result.Note := Translate('Keypad 1: 0–9, Q (*), W (#). Keypad 2: numpad 0–9, E (*), R (#).') + ' ' +
    Translate('Keypad buttons 1 and 2 can also use the bindings shown below.') + ' ' +
    Translate('Mouse controls the port selected in settings; roller uses both axes.') + ' ' +
    Translate('Analog sticks control each wheel/spinner independently. S-/S+ turn the Super Action spinner.') + ' ' +
    Translate('Driving: left/right steer, right trigger accelerates.') + ' ' +
    Translate('When the physical keyboard is enabled, letter shortcuts and F8 are unavailable. F5/F6 remain available.');
end;

class function TColecoControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited;
  if Context.Ports.Devices[Context.Player] = 'driving' then
    for var I := 0 to High(Result) do
      if Result[I].Action = PadAction(Context.Player, TEmulatorButton.A) then
        Result[I].Caption := 'Gas';
end;

class function TColecoControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  // Match KeyPolicy: raw keypad letters reserve host shortcuts, but F5/F6
  // are always available for snapshots. With the keypad disabled, all return.
  Result := not Context.Ports.KeyboardEnabled or
    not ((Id = 'screenshot') or (Id = 'pause') or (Id = 'reset') or
    (Id = 'hard-restart') or (Id = 'open') or (Id = 'coin'));
end;

end.

