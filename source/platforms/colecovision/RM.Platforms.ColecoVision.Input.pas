unit RM.Platforms.ColecoVision.Input;

interface

uses
  Core.Emulation.Types, RM.Input.Runtime, RM.Settings.Callouts,
  RM.ControlsHelp.Content;

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

  TColecoControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
  end;

implementation

uses
  System.SysUtils, Core.Platforms.ColecoVision.Adapter, RM.Gamepad;

class function TColecoInputHandler.KeyPolicy(const Context: TInputRuntimeContext): TInputKeyPolicy;
begin
  Result := inherited;
  // Numeric keys belong to the controller, including Q/W/E/R for star/hash.
  // Preserve direct host keys alongside user-configurable pad bindings.
  Result.KeyboardActive := True;
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
      Result[I].Name := 'Gas';
      Result[I].Caption := 'Gas pedal';
    end;
  end;
end;

class function TColecoControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited;
  Result.ControllerTitle := 'ColecoVision';
  Result.Note := 'Keypad 1: 0–9, Q (*), W (#). Keypad 2: numpad 0–9, E (*), R (#). ' +
    'Enter = 1, Space = 2. Mouse controls the port selected in settings; roller uses both axes. ' +
    'Analog sticks control each wheel/spinner independently. S-/S+ turn the Super Action spinner. ' +
    'Driving: left/right steer, right trigger accelerates.';
end;

end.

