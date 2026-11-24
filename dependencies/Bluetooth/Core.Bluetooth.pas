unit Core.Bluetooth;

interface

uses
  Core.Bluetooth.Types;

// An absent backend is observable, rather than an empty successful discovery.
function CreateUnavailableBluetoothProvider: IBluetoothProvider;

implementation

type
  TUnavailableOperation = class(TInterfacedObject, IBluetoothOperation, IBluetoothDeviceDiscovery, IBluetoothServiceDiscovery, IBluetoothConnect, IBluetoothListen)
  public
    function State: TBluetoothOperationState;
    function Error: TBluetoothError;
    procedure Cancel;
    function TryTakeDevice(out Device: TBluetoothDevice): Boolean;
    function TryTakeService(out Service: TBluetoothService): Boolean;
    function TakeChannel: IBluetoothChannel;
    function TakeListener: IBluetoothListener;
  end;

  TUnavailableProvider = class(TInterfacedObject, IBluetoothProvider)
  public
    function Info: TBluetoothAdapterInfo;
    function KnownDevices: TArray<TBluetoothDevice>;
    function Discover(TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
    function FindServices(const Device: TBluetoothAddress; const UUIDs: TArray<TBluetoothUUID>; const Attributes: TArray<Word>): IBluetoothServiceDiscovery;
    function Connect(const Endpoint: TBluetoothEndpoint; const Options: TBluetoothConnectOptions): IBluetoothConnect;
    function Listen(const Service: TBluetoothService; const Options: TBluetoothConnectOptions): IBluetoothListen;
    function SetDiscoverable(Enabled: Boolean): IBluetoothOperation;
  end;

function TUnavailableOperation.State: TBluetoothOperationState;
begin
  Result := TBluetoothOperationState.Failed;
end;

function TUnavailableOperation.Error: TBluetoothError;
begin
  Result := Default(TBluetoothError);
  Result.Code := TBluetoothErrorCode.Unavailable;
  Result.MessageText := 'Bluetooth backend is not connected';
end;

procedure TUnavailableOperation.Cancel;
begin
end;

function TUnavailableOperation.TryTakeDevice(out Device: TBluetoothDevice): Boolean;
begin
  Device := Default(TBluetoothDevice);
  Result := False;
end;

function TUnavailableOperation.TryTakeService(out Service: TBluetoothService): Boolean;
begin
  Service := Default(TBluetoothService);
  Result := False;
end;

function TUnavailableOperation.TakeChannel: IBluetoothChannel;
begin
  Result := nil;
end;

function TUnavailableOperation.TakeListener: IBluetoothListener;
begin
  Result := nil;
end;

function TUnavailableProvider.Info: TBluetoothAdapterInfo;
begin
  Result := Default(TBluetoothAdapterInfo);
  Result.State := TBluetoothState.Unavailable;
end;

function TUnavailableProvider.KnownDevices: TArray<TBluetoothDevice>;
begin
  Result := nil;
end;

function TUnavailableProvider.Discover(TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
begin
  Result := TUnavailableOperation.Create;
end;

function TUnavailableProvider.FindServices(const Device: TBluetoothAddress; const UUIDs: TArray<TBluetoothUUID>; const Attributes: TArray<Word>): IBluetoothServiceDiscovery;
begin
  Result := TUnavailableOperation.Create;
end;

function TUnavailableProvider.Connect(const Endpoint: TBluetoothEndpoint; const Options: TBluetoothConnectOptions): IBluetoothConnect;
begin
  Result := TUnavailableOperation.Create;
end;

function TUnavailableProvider.Listen(const Service: TBluetoothService; const Options: TBluetoothConnectOptions): IBluetoothListen;
begin
  Result := TUnavailableOperation.Create;
end;

function TUnavailableProvider.SetDiscoverable(Enabled: Boolean): IBluetoothOperation;
begin
  Result := TUnavailableOperation.Create;
end;

function CreateUnavailableBluetoothProvider: IBluetoothProvider;
begin
  Result := TUnavailableProvider.Create;
end;

end.

