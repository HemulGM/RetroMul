unit RM.Platforms.PS1.Devices;

interface

uses
  FMX.Controls, RM.Settings.Devices, RM.Settings.Callouts;

type
  TPS1SettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
    class function Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding; override;
  end;

type
  TPS1DeviceCallouts = class(TPlatformDeviceCallouts)
  public
    class function Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>; override;
  end;

implementation

uses
  RM.Platforms.PS1.Input, Core.Platforms.PS1.Adapter, FMX.Types, RM.Gamepad,
  RM.Input;

class function TPS1SettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
    if (Extra = TPS1Extra.L2) or (Context.Device = 'pad-analog') then
      Result := Result + [TSettingsDeviceBinding.Create(PS1Action(Context.Port, Extra), PS1ExtraName(Extra))];
end;

class function TPS1SettingsDevices.Selection(const Context: TSettingsDeviceContext; Control: TControl): TSettingsDeviceBinding;
begin
  Result := TSettingsDeviceBinding.None;
  if Control is TScreenGamepad then
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      if (TScreenGamepad(Control).AuxiliaryButtons and (1 shl Ord(Extra))) <> 0 then
        Result := TSettingsDeviceBinding.Create(PS1Action(Context.Port, Extra), Translate('Button ') + Translate(PS1ExtraName(Extra)));
  var Logical := inherited Selection(Context, Control);
  if Logical.Action >= 0 then
    Result := Logical;
end;

class function TPS1DeviceCallouts.Definitions(const Context: TDeviceCalloutContext): TArray<TDeviceCalloutDefinition>;
begin
  Result := inherited Definitions(Context);
  if Context.Device is TScreenGamepad then
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      if not TScreenGamepad(Context.Device).AuxiliaryButtonBounds(Ord(Extra)).IsEmpty then
        Result := Result + [TDeviceCalloutDefinition.Create(-1 - Ord(Extra), PS1Action(Context.Port, Extra),
          Translate(PS1ExtraName(Extra)), Translate('Button ') + Translate(PS1ExtraName(Extra)), True)];
end;

end.

