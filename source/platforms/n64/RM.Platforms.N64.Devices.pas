unit RM.Platforms.N64.Devices;

interface

uses
  FMX.Controls, RM.Settings.Devices, RM.Settings.Callouts;

type
  TN64SettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

type
  TN64DeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

implementation

uses
  RM.Platforms.N64.Input, FMX.Types, RM.Gamepad, RM.Input;

class function TN64SettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  Result := Result + [TSettingsDeviceBinding.Create(N64LAction + Context.Port, 'L')];
end;

class function TN64SettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := TSettingsDeviceBinding.None;
  if (Control is TScreenGamepad) and ((TScreenGamepad(Control).AuxiliaryButtons and 1) <> 0) then
    Result := TSettingsDeviceBinding.Create(N64LAction + Context.Port, Translate('Button ') + 'L');
  var Logical := inherited Selection(Context, Control);
  if Logical.Action >= 0 then
    Result := Logical;
end;

class function TN64DeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited Definitions(Context);
  if (Context.Device is TScreenGamepad) and not TScreenGamepad(Context.Device).AuxiliaryButtonBounds(0).IsEmpty then
    Result := Result + [TDeviceCalloutDefinition.Create(-1, N64LAction + Context.Port,
      'L', Translate('Button ') + 'L', True)];
end;

end.

