unit Core.Platforms.Bluetooth;

interface

uses
  Core.Bluetooth.Types;

function CreatePlatformBluetoothProvider: IBluetoothProvider;

implementation

uses
  Core.Bluetooth
  {$IFDEF MSWINDOWS}
    , Core.Platforms.Bluetooth.Windows
  {$ENDIF};

function CreatePlatformBluetoothProvider: IBluetoothProvider;
begin
  {$IFDEF MSWINDOWS}
  Result := CreateWindowsBluetoothProvider;
  {$ELSE}
  Result := CreateUnavailableBluetoothProvider;
  {$ENDIF}
end;

end.

