unit Core.Emulation.Bluetooth;

interface

uses
  Core.Bluetooth.Types;

type
  IEmulationBluetooth = interface
    ['{FDBAD160-9D30-4AF1-A03B-262854507399}']
    // Bind while stopped. The provider itself reports runtime hardware changes.
    procedure SetBluetoothProvider(const Provider: IBluetoothProvider);
    function GetBluetoothProvider: IBluetoothProvider;
  end;

implementation

end.
