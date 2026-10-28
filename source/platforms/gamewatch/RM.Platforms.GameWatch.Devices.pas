unit RM.Platforms.GameWatch.Devices;

interface

uses
  FMX.Controls, RM.Settings.Devices;

type
  TGWSettingsDevices = class(TPlatformSettingsDevices)
  public
    class function FixedDevice(const Context: TSettingsDeviceContext): string; override;
    class function HasPortSettings: Boolean; override;
  end;

implementation

class function TGWSettingsDevices.FixedDevice(const Context: TSettingsDeviceContext): string;
begin
  Result := 'pad';
end;

class function TGWSettingsDevices.HasPortSettings: Boolean;
begin
  Result := False;
end;

end.
