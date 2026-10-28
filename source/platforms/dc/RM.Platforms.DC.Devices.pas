unit RM.Platforms.DC.Devices;

interface

uses
  FMX.Controls, RM.Settings.Devices;

type
  TDCSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>; override;
  end;

implementation

uses
  RM.Platforms.DC.Runtime, Core.Platforms.DC.Adapter;

class function TDCSettingsDevices.Assignments(const Context: TSettingsDeviceContext): TArray<TSettingsDeviceBinding>;
begin
  Result := inherited Assignments(Context);
  for var Extra := Low(TDCExtra) to High(TDCExtra) do
    Result := Result + [TSettingsDeviceBinding.Create(DCAction(Context.Port, Extra), DCExtraName(Extra))];
end;

end.
