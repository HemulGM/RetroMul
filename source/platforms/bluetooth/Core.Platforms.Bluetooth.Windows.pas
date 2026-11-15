unit Core.Platforms.Bluetooth.Windows;

interface

uses
  Core.Bluetooth.Types;

function CreateWindowsBluetoothProvider: IBluetoothProvider;

// Takes ownership of an already connected nonblocking Winsock stream socket.
function AdoptWindowsBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;

implementation

uses
  System.SysUtils, Core.Bluetooth
{$IFDEF MSWINDOWS}
    , System.Classes, System.SyncObjs, System.Math, System.Generics.Collections,
    Winapi.Windows, Winapi.Winsock2, Winapi.Bluetooth, Core.Bluetooth.SDP,
    Core.Bluetooth.Service, Core.Platforms.Bluetooth.Windows.IO
{$ENDIF};

{$IFDEF MSWINDOWS}
type
  TAddress = Core.Bluetooth.Types.TBluetoothAddress;

  TUUID = Core.Bluetooth.Types.TBluetoothUUID;

  TContext = class;

  IContext = interface
    ['{3134881A-2092-442A-B315-DCBBEAD083E1}']
    function Raw: TContext;
  end;

  TJob = class;

  IJob = interface
    ['{FB457769-305B-44A0-B869-1989526755AF}']
    function Raw: TJob;
  end;

  TJob = class(TInterfacedObject, IJob)
    Lock: TCriticalSection;
    Stop: TEvent;
    Context: IContext;
    Current: TBluetoothOperationState;
    Problem: TBluetoothError;
    Devices: TQueue<TBluetoothDevice>;
    Services: TQueue<TBluetoothService>;
    Device: TBluetoothDevice;
    Channel: IBluetoothChannel;
    Listener: IBluetoothListener;
    Socket: TSocket;
    constructor Create(const C: IContext);
    destructor Destroy; override;
    function Raw: TJob;
    procedure Cancel;
    procedure Fail(const E: TBluetoothError);
    procedure Complete;
    function Pending: Boolean;
    procedure AddDevice(const D: TBluetoothDevice);
    procedure AddService(const S: TBluetoothService);
    procedure SetChannel(const C: IBluetoothChannel);
    procedure SetListener(const L: IBluetoothListener);
  end;

  TOperation = class(TInterfacedObject, IBluetoothOperation, IBluetoothDeviceDiscovery, IBluetoothServiceDiscovery, IBluetoothDeviceQuery, IBluetoothConnect, IBluetoothListen)
    Job: IJob;
    destructor Destroy; override;
    function State: TBluetoothOperationState;
    function Error: TBluetoothError;
    procedure Cancel;
    function TryTakeDevice(out Device: TBluetoothDevice): Boolean;
    function TryTakeService(out Service: TBluetoothService): Boolean;
    function Device: TBluetoothDevice;
    function TakeChannel: IBluetoothChannel;
    function TakeListener: IBluetoothListener;
  end;

  TContext = class(TInterfacedObject, IContext)
    Lock: TCriticalSection;
    Details: TBluetoothAdapterInfo;
    Known: TArray<TBluetoothDevice>;
    Slots, Listeners: Integer;
    Started: Boolean;
    DiscoveryLock: TCriticalSection;
    DiscoveryChanged, DiscoveryOriginal, DiscoveryLast: Boolean;
    DiscoveryRadio: TAddress;
    constructor Create;
    destructor Destroy; override;
    function Raw: TContext;
    procedure Refresh;
    function Radio: THandle;
    function Start(const Action: TProc<TJob>; RunCancelled: Boolean = False): TOperation;
    function Snapshot: TBluetoothAdapterInfo;
  end;

  TListener = class(TInterfacedObject, IBluetoothListener, IBluetoothServiceRegistration)
    Lock: TCriticalSection;
    Context: IContext;
    Socket: TSocket;
    Details: TBluetoothService;
    Security: TBluetoothSecurityFlags;
    RecordHandle: THandle;
    Classes: UInt32;
    Closed, Publishing: Boolean;
    constructor Create(const C: IContext; S: TSocket; const Service: TBluetoothService; Flags: TBluetoothSecurityFlags);
    destructor Destroy; override;
    function Service: TBluetoothService;
    function TryAccept(out Channel: IBluetoothChannel): TBluetoothTransfer;
    procedure Close;
    function Publish(const Service: TBluetoothService; DeviceServiceClasses: UInt32): IBluetoothOperation;
  end;

  TProvider = class(TInterfacedObject, IBluetoothProvider, IBluetoothClassicControl)
    Context: IContext;
    Lock: TCriticalSection;
    RefreshJob: IBluetoothOperation;
    Refreshed: UInt64;
    constructor Create;
    destructor Destroy; override;
    function Info: TBluetoothAdapterInfo;
    function KnownDevices: TArray<TBluetoothDevice>;
    function Discover(TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
    function FindServices(const Device: TAddress; const UUIDs: TArray<TUUID>; const Attributes: TArray<Word>): IBluetoothServiceDiscovery;
    function Connect(const Endpoint: TBluetoothEndpoint; const Options: TBluetoothConnectOptions): IBluetoothConnect;
    function Listen(const Service: TBluetoothService; const Options: TBluetoothConnectOptions): IBluetoothListen;
    function SetDiscoverable(Enabled: Boolean): IBluetoothOperation;
    function Inquiry(AccessCode: UInt32; TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
    function SetDiscoverability(AccessCode: UInt32): IBluetoothOperation;
    function QueryDevice(const Device: TAddress; RefreshName: Boolean): IBluetoothDeviceQuery;
  end;

function ErrorValue(Code: TBluetoothErrorCode; Native: Integer; const Text: string): TBluetoothError;
begin
  Result := Default(TBluetoothError);
  Result.Code := Code;
  Result.NativeCode := Native;
  Result.MessageText := Text;
  if Native <> 0 then
    Result.MessageText := Result.MessageText + ': ' + SysErrorMessage(Native);
end;

function NativeError(Code: Integer; const Text: string): TBluetoothError;
begin
  var Kind := TBluetoothErrorCode.IOFailure;
  case Code of
    ERROR_ACCESS_DENIED, WSAEACCES:
      Kind := TBluetoothErrorCode.PermissionDenied;
    WSAEAFNOSUPPORT, WSAEPROTONOSUPPORT, WSAEOPNOTSUPP:
      Kind := TBluetoothErrorCode.Unsupported;
    WSAEINVAL:
      Kind := TBluetoothErrorCode.InvalidArgument;
    WSAENOBUFS, WSAEMFILE:
      Kind := TBluetoothErrorCode.ResourceLimit;
    WSAETIMEDOUT:
      Kind := TBluetoothErrorCode.Timeout;
    WSAEHOSTDOWN, WSAEHOSTUNREACH, WSAECONNREFUSED, WSASERVICE_NOT_FOUND:
      Kind := TBluetoothErrorCode.Unreachable;
    WSAENETDOWN, WSASYSNOTREADY:
      Kind := TBluetoothErrorCode.PoweredOff;
  end;
  Result := ErrorValue(Kind, Code, Text);
end;

function Ready(J: TJob): Boolean;
begin
  var State := J.Context.Raw.Snapshot.State;
  Result := State = TBluetoothState.Ready;
  if not Result then
  begin
    var Code := TBluetoothErrorCode.Unavailable;
    if State = TBluetoothState.PermissionRequired then
      Code := TBluetoothErrorCode.PermissionDenied
    else if State = TBluetoothState.PoweredOff then
      Code := TBluetoothErrorCode.PoweredOff;
    J.Fail(ErrorValue(Code, 0, 'Bluetooth radio is not ready'));
  end;
end;

function DeviceValue(const N: Winapi.Bluetooth.TBluetoothDeviceInfo): TBluetoothDevice;
begin
  Result := Default(TBluetoothDevice);
  Result.Address.Value := N.Address.ullLong;
  Result.Name := N.szName;
  Result.ClassOfDevice := N.ulClassofDevice;
  Result.Paired := N.fAuthenticated;
  Result.Connected := N.fConnected; // Pairing is not service authorization/trust.
end;

function CreateRadio(const Expected: TAddress): THandle;
begin
  Result := 0;
  var Params: TBluetoothFindRadioParams := Default(TBluetoothFindRadioParams);
  Params.dwSize := SizeOf(Params);
  var Radio: THandle := 0;
  var Find := BluetoothFindFirstRadio(Params, Radio);
  if Find = 0 then
    Exit;
  try
    repeat
      var N: TBluetoothRadioInfo := Default(TBluetoothRadioInfo);
      N.dwSize := SizeOf(N);
      if (BluetoothGetRadioInfo(Radio, N) = 0) and ((Expected.Value = 0) or (N.address.ullLong = Expected.Value)) then
      begin
        Result := Radio;
        Radio := 0;
        Exit;
      end;
      CloseHandle(Radio);
      Radio := 0;
    until not BluetoothFindNextRadio(Find, Radio);
  finally
    if Radio <> 0 then
      CloseHandle(Radio);
    BluetoothFindRadioClose(Find);
  end;
end;

constructor TContext.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  DiscoveryLock := TCriticalSection.Create;
  var Data: WSAData;
  var Code := WSAStartup($0202, Data);
  Started := Code = 0;
  Details := Default(TBluetoothAdapterInfo);
  Details.State := TBluetoothState.Unavailable;
  if Started then
    Refresh;
end;

destructor TContext.Destroy;
begin
  if DiscoveryChanged then
  begin
    var Address := DiscoveryRadio;
    var Original := DiscoveryOriginal;
    var Last := DiscoveryLast;
    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        var Radio := CreateRadio(Address);
        if Radio = 0 then
          Exit;
        try
          var Current := BluetoothIsDiscoverable(Radio) <> False;
          if Current = Last then
            BluetoothEnableDiscovery(Radio, Original);
        finally
          CloseHandle(Radio);
        end;
      end);
    Worker.Start;
  end;
  if Started then
    WSACleanup;
  DiscoveryLock.Free;
  Lock.Free;
  inherited;
end;

function TContext.Raw: TContext;
begin
  Result := Self;
end;

function TContext.Snapshot: TBluetoothAdapterInfo;
begin
  Lock.Acquire;
  try
    Result := Details;
  finally
    Lock.Release;
  end;
end;

function TContext.Radio: THandle;
begin
  Result := CreateRadio(Snapshot.Device.Address);
end;

procedure TContext.Refresh;
begin
  var Info: TBluetoothAdapterInfo := Default(TBluetoothAdapterInfo);
  Info.State := TBluetoothState.Unavailable;
  var Devices: TArray<TBluetoothDevice> := nil;
  var Radio := CreateRadio(Default(TAddress));
  if Radio <> 0 then
  try
    var N: TBluetoothRadioInfo := Default(TBluetoothRadioInfo);
    N.dwSize := SizeOf(N);
    var Code := BluetoothGetRadioInfo(Radio, N);
    if Code = 0 then
    begin
      Info.State := TBluetoothState.Ready;
      Info.Device.Address.Value := N.address.ullLong;
      Info.Device.Name := N.szName;
      Info.Device.ClassOfDevice := N.ulClassofDevice;
      Info.Capabilities := [TBluetoothCapability.DeviceDiscovery, TBluetoothCapability.ServiceDiscovery, TBluetoothCapability.RFCOMMClient, TBluetoothCapability.RFCOMMServer];
      if BluetoothIsDiscoverable(Radio) then
        Info.DiscoverableCode := $9E8B33;
      var Params: TBluetoothDeviceSearchParams := Default(TBluetoothDeviceSearchParams);
      Params.dwSize := SizeOf(Params);
      Params.hRadio := Radio;
      Params.fReturnAuthenticated := True;
      Params.fReturnRemembered := True;
      Params.fReturnUnknown := True;
      Params.fReturnConnected := True;
      var D: Winapi.Bluetooth.TBluetoothDeviceInfo := Default(Winapi.Bluetooth.TBluetoothDeviceInfo);
      D.dwSize := SizeOf(D);
      var Find := BluetoothFindFirstDevice(Params, D);
      if Find <> 0 then
      try
        repeat
          Devices := Devices + [DeviceValue(D)];
          if Length(Devices) >= 256 then
            Break;
        until not BluetoothFindNextDevice(Find, D);
      finally
        BluetoothFindDeviceClose(Find);
      end;
    end
    else if Code = ERROR_ACCESS_DENIED then
      Info.State := TBluetoothState.PermissionRequired;
  finally
    CloseHandle(Radio);
  end;
  Lock.Acquire;
  try
    Details := Info;
    Known := Devices;
  finally
    Lock.Release;
  end;
end;

constructor TJob.Create(const C: IContext);
begin
  inherited Create;
  Context := C;
  Lock := TCriticalSection.Create;
  Stop := TEvent.Create(nil, True, False, '');
  Devices := TQueue<TBluetoothDevice>.Create;
  Services := TQueue<TBluetoothService>.Create;
  Socket := INVALID_SOCKET;
end;

destructor TJob.Destroy;
begin
  Cancel;
  if Channel <> nil then
    Channel.Close;
  if Listener <> nil then
    Listener.Close;
  Devices.Free;
  Services.Free;
  Stop.Free;
  Lock.Free;
  inherited;
end;

function TJob.Raw: TJob;
begin
  Result := Self;
end;

function TJob.Pending: Boolean;
begin
  Lock.Acquire;
  try
    Result := Current = TBluetoothOperationState.Pending;
  finally
    Lock.Release;
  end;
end;

procedure TJob.Cancel;
begin
  var S := INVALID_SOCKET;
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      Current := TBluetoothOperationState.Cancelled;
      Problem := ErrorValue(TBluetoothErrorCode.Cancelled, 0, 'Bluetooth operation cancelled');
      Stop.SetEvent;
      S := Socket;
      Socket := INVALID_SOCKET;
      Devices.Clear;
      Services.Clear;
    end;
  finally
    Lock.Release;
  end;
  if S <> INVALID_SOCKET then
    closesocket(S);
end;

procedure TJob.Fail(const E: TBluetoothError);
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      Current := TBluetoothOperationState.Failed;
      Problem := E;
    end;
  finally
    Lock.Release;
  end;
end;

procedure TJob.Complete;
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
      Current := TBluetoothOperationState.Completed;
  finally
    Lock.Release;
  end;
end;

procedure TJob.AddDevice(const D: TBluetoothDevice);
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      if Devices.Count >= 256 then
        Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'Device result capacity'))
      else
        Devices.Enqueue(D);
    end;
  finally
    Lock.Release;
  end;
end;

procedure TJob.AddService(const S: TBluetoothService);
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      if Services.Count >= 64 then
        Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'Service result capacity'))
      else
        Services.Enqueue(CopyBluetoothService(S));
    end;
  finally
    Lock.Release;
  end;
end;

procedure TJob.SetChannel(const C: IBluetoothChannel);
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      Channel := C;
      Exit;
    end;
  finally
    Lock.Release;
  end;
  if C <> nil then
    C.Close;
end;

procedure TJob.SetListener(const L: IBluetoothListener);
begin
  Lock.Acquire;
  try
    if Current = TBluetoothOperationState.Pending then
    begin
      Listener := L;
      Exit;
    end;
  finally
    Lock.Release;
  end;
  if L <> nil then
    L.Close;
end;

function TContext.Start(const Action: TProc<TJob>; RunCancelled: Boolean): TOperation;
begin
  var Keep: IJob := TJob.Create(Self);
  var J := Keep.Raw;
  Result := TOperation.Create;
  Result.Job := Keep;
  Lock.Acquire;
  try
    if Slots >= 8 then
    begin
      J.Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'Native Bluetooth worker capacity'));
      Exit;
    end;
    Inc(Slots);
  finally
    Lock.Release;
  end;
  var Run := Action;
  try
    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        try
          try
            if J.Pending or RunCancelled then
              Run(J);
            J.Complete;
          except
            on E: Exception do
              J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, E.Message));
          end;
        finally
          var C := Keep.Raw.Context.Raw;
          C.Lock.Acquire;
          try
            Dec(C.Slots);
          finally
            C.Lock.Release;
          end;
        end;
      end);
    Worker.Start;
  except
    Lock.Acquire;
    try
      Dec(Slots);
    finally
      Lock.Release;
    end;
    J.Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'Cannot start native Bluetooth worker'));
  end;
end;

destructor TOperation.Destroy;
begin
  Cancel;
  inherited;
end;

function TOperation.State: TBluetoothOperationState;
begin
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    Result := J.Current;
  finally
    J.Lock.Release;
  end;
end;

function TOperation.Error: TBluetoothError;
begin
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    Result := J.Problem;
  finally
    J.Lock.Release;
  end;
end;

procedure TOperation.Cancel;
begin
  if Job <> nil then
    Job.Raw.Cancel;
end;

function TOperation.TryTakeDevice(out Device: TBluetoothDevice): Boolean;
begin
  Device := Default(TBluetoothDevice);
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    Result := (J.Current in [TBluetoothOperationState.Pending, TBluetoothOperationState.Completed]) and (J.Devices.Count <> 0);
    if Result then
      Device := J.Devices.Dequeue;
  finally
    J.Lock.Release;
  end;
end;

function TOperation.TryTakeService(out Service: TBluetoothService): Boolean;
begin
  Service := Default(TBluetoothService);
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    Result := (J.Current in [TBluetoothOperationState.Pending, TBluetoothOperationState.Completed]) and (J.Services.Count <> 0);
    if Result then
      Service := J.Services.Dequeue;
  finally
    J.Lock.Release;
  end;
end;

function TOperation.Device: TBluetoothDevice;
begin
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    Result := J.Device;
  finally
    J.Lock.Release;
  end;
end;

function TOperation.TakeChannel: IBluetoothChannel;
begin
  Result := nil;
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    if J.Current = TBluetoothOperationState.Completed then
    begin
      Result := J.Channel;
      J.Channel := nil;
    end;
  finally
    J.Lock.Release;
  end;
end;

function TOperation.TakeListener: IBluetoothListener;
begin
  Result := nil;
  var J := Job.Raw;
  J.Lock.Acquire;
  try
    if J.Current = TBluetoothOperationState.Completed then
    begin
      Result := J.Listener;
      J.Listener := nil;
    end;
  finally
    J.Lock.Release;
  end;
end;

function Nonblocking(S: TSocket): Boolean;
begin
  var One: u_long := 1;
  Result := ioctlsocket(S, Longint(FIONBIO), One) = 0;
end;

function Adopt(const C: IContext; S: TSocket; const Info: TBluetoothChannelInfo): IBluetoothChannel;
begin
  Result := AdoptOverlappedBluetoothSocket(NativeUInt(S), Info);
end;

function Configure(S: TSocket; const Options: TBluetoothConnectOptions): TBluetoothError;
begin
  Result := Default(TBluetoothError);
  if Options.RequireMaster or (TBluetoothSecurity.Authorized in Options.Security) then
    Exit(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows does not expose required master role/service authorization'));
  var Value: ULONG := 1;
  if TBluetoothSecurity.Authenticated in Options.Security then
    if setsockopt(S, SOL_RFCOMM, Integer(SO_BTH_AUTHENTICATE), PAnsiChar(@Value), SizeOf(Value)) <> 0 then
      Exit(NativeError(WSAGetLastError, 'Require authentication'));
  if TBluetoothSecurity.Encrypted in Options.Security then
    if setsockopt(S, SOL_RFCOMM, Integer(SO_BTH_ENCRYPT), PAnsiChar(@Value), SizeOf(Value)) <> 0 then
      Exit(NativeError(WSAGetLastError, 'Require encryption'));
end;

function SetRecord(var Handle: THandle; const Data: TBytes; Classes: UInt32; Delete: Boolean): Integer;
begin
  var Bytes: TBytes;
  SetLength(Bytes, SizeOf(TBthSetService) - 1 + Max(1, Length(Data)));
  FillChar(Bytes[0], Length(Bytes), 0);
  var B := PBthSetService(@Bytes[0]);
  var Version: ULONG := 1;
  B.pSdpVersion := @Version;
  B.pRecordHandle := @Handle;
  B.fCodService := Classes shr COD_SERVICE_BIT_OFFSET;
  B.ulRecordLength := Length(Data);
  if Length(Data) <> 0 then
    Move(Data[0], B.pRecord[0], Length(Data));
  var Blob: Winapi.Winsock2.BLOB;
  Blob.cbSize := Length(Bytes);
  Blob.pBlobData := @Bytes[0];
  var Query: WSAQUERYSETW := Default(WSAQUERYSETW);
  Query.dwSize := SizeOf(Query);
  Query.dwNameSpace := NS_BTH;
  Query.lpBlob := @Blob;
  var Operation := RNRSERVICE_REGISTER;
  if Delete then
    Operation := RNRSERVICE_DELETE;
  Result := 0;
  if WSASetServiceW(@Query, Operation, 0) <> 0 then
    Result := WSAGetLastError;
end;

constructor TListener.Create(const C: IContext; S: TSocket; const Service: TBluetoothService; Flags: TBluetoothSecurityFlags);
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Context := C;
  Socket := S;
  Details := CopyBluetoothService(Service);
  Security := Flags;
end;

destructor TListener.Destroy;
begin
  Close;
  Context.Raw.Lock.Acquire;
  try
    Dec(Context.Raw.Listeners);
  finally
    Context.Raw.Lock.Release;
  end;
  Lock.Free;
  inherited;
end;

function TListener.Service: TBluetoothService;
begin
  Lock.Acquire;
  try
    Result := CopyBluetoothService(Details);
  finally
    Lock.Release;
  end;
end;

procedure TListener.Close;
begin
  var Handle: THandle := 0;
  var Keep: IContext := nil;
  Lock.Acquire;
  try
    if Closed then
      Exit;
    Closed := True;
    if Socket <> INVALID_SOCKET then
      closesocket(Socket);
    Socket := INVALID_SOCKET;
    Handle := RecordHandle;
    RecordHandle := 0;
    Keep := Context;
  finally
    Lock.Release;
  end;
  if Handle <> 0 then
  begin
    // Cleanup must not block the emulation executor in the namespace provider.
    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        var H := Handle;
        SetRecord(H, nil, 0, True);
        var Retain := Keep;
      end);
    Worker.Start;
  end;
end;

function TListener.TryAccept(out Channel: IBluetoothChannel): TBluetoothTransfer;
begin
  Channel := nil;
  Result := Default(TBluetoothTransfer);
  Lock.Acquire;
  try
    if Closed then
    begin
      Result.State := TBluetoothIOState.Closed;
      Exit;
    end;
    if RecordHandle = 0 then
    begin
      Result.State := TBluetoothIOState.WouldBlock;
      Exit;
    end;
    var Address: TSockAddrBth := Default(TSockAddrBth);
    var Size: Integer := SizeOf(Address);
    var S := accept(Socket, PSockAddr(@Address), @Size);
    if S = INVALID_SOCKET then
    begin
      var Code := WSAGetLastError;
      if Code = WSAEWOULDBLOCK then
        Result.State := TBluetoothIOState.WouldBlock
      else
      begin
        Result.State := TBluetoothIOState.Failed;
        Result.Error := NativeError(Code, 'Bluetooth accept');
      end;
      Exit;
    end;
    var Info: TBluetoothChannelInfo := Default(TBluetoothChannelInfo);
    Info.Endpoint := Details.Endpoint;
    Info.Endpoint.Device.Value := Address.btAddr;
    // Successful accept enforces the security options set on the listen socket.
    Info.Security := Security;
    Channel := Adopt(Context, S, Info);
    Result.State := TBluetoothIOState.Ready;
  finally
    Lock.Release;
  end;
end;

function TListener.Publish(const Service: TBluetoothService; DeviceServiceClasses: UInt32): IBluetoothOperation;
begin
  var Candidate := CopyBluetoothService(Service);
  var Raw := EncodeBluetoothService(Candidate);
  var Keep: IBluetoothListener := Self;
  var This := Self;
  Lock.Acquire;
  try
    if Closed or Publishing then
    begin
      var Op := Context.Raw.Start(
        procedure(J: TJob)
        begin
          J.Fail(ErrorValue(TBluetoothErrorCode.Busy, 0, 'Listener closed or publication pending'));
        end);
      Exit(Op);
    end;
    Publishing := True;
  finally
    Lock.Release;
  end;
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      var Retain := Keep;
      var H: THandle := 0;
      try
        if not J.Pending then
          Exit;
        This.Lock.Acquire;
        try
          if This.Closed then
          begin
            J.Fail(ErrorValue(TBluetoothErrorCode.Cancelled, 0, 'Listener closed'));
            Exit;
          end;
          H := This.RecordHandle;
        finally
          This.Lock.Release;
        end;
        if H <> 0 then
        begin
          var Existing := EncodeBluetoothService(This.Service);
          var Same := Length(Existing) = Length(Raw);
          if Same then
            for var I := 0 to High(Raw) do
              if Existing[I] <> Raw[I] then
              begin
                Same := False;
                Break;
              end;
          if Same and (This.Classes = DeviceServiceClasses) then
            Exit;
          // Desktop Winsock only exposes registration/deletion of a handle.
          // Do not delete a working record to emulate an atomic replacement.
          J.Fail(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows cannot atomically replace a registered SDP record'));
          Exit;
        end;
        var Code := SetRecord(H, Raw, DeviceServiceClasses, False);
        if Code <> 0 then
        begin
          J.Fail(NativeError(Code, 'Publish Bluetooth SDP'));
          Exit;
        end;
        var Discard := False;
        This.Lock.Acquire;
        J.Lock.Acquire;
        try
          Discard := This.Closed or (J.Current <> TBluetoothOperationState.Pending);
          if not Discard then
          begin
            This.RecordHandle := H;
            This.Details := Candidate;
            This.Classes := DeviceServiceClasses;
            This.Publishing := False;
            J.Current := TBluetoothOperationState.Completed;
          end;
        finally
          J.Lock.Release;
          This.Lock.Release;
        end;
        if Discard then
          SetRecord(H, nil, 0, True)
        else
          J.Context.Raw.Refresh;
      finally
        This.Lock.Acquire;
        try
          This.Publishing := False;
        finally
          This.Lock.Release;
        end;
      end;
    end, True);
  if Result.State = TBluetoothOperationState.Failed then
  begin
    Lock.Acquire;
    try
      Publishing := False;
    finally
      Lock.Release;
    end;
  end;
end;

procedure Lookup(J: TJob; var Query: WSAQUERYSETW; Flags: DWORD; const Take: TProc<PWSAQUERYSETW, TBytes>);
begin
  if not J.Pending then
    Exit;
  var Handle: THandle := 0;
  if WSALookupServiceBeginW(@Query, Flags, Handle) <> 0 then
  begin
    var Code := WSAGetLastError;
    if (Code = WSASERVICE_NOT_FOUND) or (Code = WSANO_DATA) then
      Exit;
    J.Fail(NativeError(Code, 'Bluetooth lookup begin'));
    Exit;
  end;
  try
    var Buffer: TBytes;
    SetLength(Buffer, 8192);
    var Count := 0;
    while J.Pending do
    begin
      var Size: DWORD := Length(Buffer);
      FillChar(Buffer[0], Length(Buffer), 0);
      PWSAQUERYSETW(@Buffer[0]).dwSize := SizeOf(WSAQUERYSETW);
      if WSALookupServiceNextW(Handle, Flags, Size, LPWSAQUERYSETW(@Buffer[0])) <> 0 then
      begin
        var Code := WSAGetLastError;
        if ((Code = WSAEFAULT) or (Code = WSAENOBUFS)) and (Size > DWORD(Length(Buffer))) and (Size <= 2097152) then
        begin
          SetLength(Buffer, Size);
          Continue;
        end;
        if (Code <> WSA_E_NO_MORE) and (Code <> WSAENOMORE) then
          J.Fail(NativeError(Code, 'Bluetooth lookup next'));
        Break;
      end;
      Inc(Count);
      if Count > 512 then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'Bluetooth lookup result capacity'));
        Break;
      end;
      if J.Pending then
        Take(PWSAQUERYSETW(@Buffer[0]), Buffer);
    end;
  finally
    WSALookupServiceEnd(Handle);
  end;
end;

function InBuffer(P: Pointer; Size: NativeUInt; const Buffer: TBytes): Boolean;
begin
  Result := (Length(Buffer) > 0) and (NativeUInt(P) >= NativeUInt(@Buffer[0])) and (Size <= NativeUInt(Length(Buffer))) and (NativeUInt(P) - NativeUInt(@Buffer[0]) <= NativeUInt(Length(Buffer)) - Size);
end;

constructor TProvider.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Context := TContext.Create;
  Refreshed := GetTickCount64;
end;

destructor TProvider.Destroy;
begin
  if RefreshJob <> nil then
    RefreshJob.Cancel;
  RefreshJob := nil;
  Lock.Free;
  inherited;
end;

function TProvider.Info: TBluetoothAdapterInfo;
begin
  Lock.Acquire;
  try
    if (GetTickCount64 - Refreshed >= 2000) and ((RefreshJob = nil) or (RefreshJob.State <> TBluetoothOperationState.Pending)) then
    begin
      RefreshJob := Context.Raw.Start(
        procedure(J: TJob)
        begin
          if J.Pending then
            J.Context.Raw.Refresh;
        end);
      Refreshed := GetTickCount64;
    end;
  finally
    Lock.Release;
  end;
  Result := Context.Raw.Snapshot;
end;

function TProvider.KnownDevices: TArray<TBluetoothDevice>;
begin
  Info;
  var C := Context.Raw;
  C.Lock.Acquire;
  try
    Result := Copy(C.Known);
  finally
    C.Lock.Release;
  end;
end;

function TProvider.Discover(TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
begin
  Result := Inquiry($9E8B33, TimeoutMillis);
end;

procedure DoInquiry(J: TJob; AccessCode: UInt32; TimeoutMillis: Cardinal; const Take: TProc<TBluetoothDevice>);
begin
  var Receive := Take;
  if AccessCode <> $9E8B33 then
  begin
    J.Fail(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows supports GIAC inquiry only'));
    Exit;
  end;
  if not Ready(J) then
    Exit;
  var Restriction: TBthQueryDevice := Default(TBthQueryDevice);
  Restriction.length := EnsureRange(Integer((UInt64(TimeoutMillis) + 999) div 1000), 1, 60);
  var Blob: Winapi.Winsock2.BLOB;
  Blob.cbSize := SizeOf(Restriction);
  Blob.pBlobData := @Restriction;
  var Query: WSAQUERYSETW := Default(WSAQUERYSETW);
  Query.dwSize := SizeOf(Query);
  Query.dwNameSpace := NS_BTH;
  Query.lpBlob := @Blob;
  Lookup(J, Query, LUP_CONTAINERS or LUP_FLUSHCACHE or LUP_RETURN_BLOB,
    procedure(Q: PWSAQUERYSETW; Buffer: TBytes)
    begin
      if not InBuffer(Q.lpBlob, SizeOf(Winapi.Winsock2.BLOB), Buffer) then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, 'Missing inquiry blob'));
        Exit;
      end;
      if (Q.lpBlob.cbSize < SizeOf(TBthDeviceInfo)) or not InBuffer(Q.lpBlob.pBlobData, Q.lpBlob.cbSize, Buffer) then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, 'Invalid inquiry blob'));
        Exit;
      end;
      var N := PBTH_DEVICE_INFO(Q.lpBlob.pBlobData);
      var D: TBluetoothDevice := Default(TBluetoothDevice);
      D.Address.Value := N.address;
      D.ClassOfDevice := N.classOfDevice;
      D.Paired := (N.flags and (BDIF_PAIRED or BDIF_SSP_PAIRED)) <> 0;
      D.Connected := (N.flags and BDIF_CONNECTED) <> 0;
      var Len := 0;
      while (Len < Length(N.name)) and (N.name[Len] <> 0) do
        Inc(Len);
      var Name: TBytes;
      SetLength(Name, Len);
      if Len <> 0 then
        Move(N.name[0], Name[0], Len);
      D.Name := TEncoding.UTF8.GetString(Name);
      Receive(D);
    end);
end;

function TProvider.Inquiry(AccessCode: UInt32; TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
begin
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      DoInquiry(J, AccessCode, TimeoutMillis,
        procedure(D: TBluetoothDevice)
        begin
          J.AddDevice(D);
        end);
    end);
end;

function TProvider.FindServices(const Device: TAddress; const UUIDs: TArray<TUUID>; const Attributes: TArray<Word>): IBluetoothServiceDiscovery;
begin
  var TargetDevice := Device;
  var Wanted := Copy(UUIDs);
  var IDs := Copy(Attributes);
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      if (TargetDevice.Value > $FFFFFFFFFFFF) or (Length(Wanted) > 12) or (Length(IDs) > 256) then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.InvalidArgument, 0, 'Invalid SDP query'));
        Exit;
      end;
      if not Ready(J) then
        Exit;
      var Address: TSockAddrBth := Default(TSockAddrBth);
      Address.addressFamily := AF_BTH;
      Address.btAddr := TargetDevice.Value;
      var Text: array[0..127] of WideChar;
      var Size: DWORD := Length(Text);
      if WSAAddressToStringW(PSockAddr(@Address)^, SizeOf(Address), nil, @Text[0], Size) <> 0 then
      begin
        J.Fail(NativeError(WSAGetLastError, 'Bluetooth query address'));
        Exit;
      end;
      var ClassID: TGUID := L2CAP_PROTOCOL_UUID;
      if Length(Wanted) <> 0 then
        ClassID := Wanted[0].Value;
      var Query: WSAQUERYSETW := Default(WSAQUERYSETW);
      Query.dwSize := SizeOf(Query);
      Query.dwNameSpace := NS_BTH;
      Query.lpszContext := @Text[0];
      Query.lpServiceClassId := @ClassID;
      Lookup(J, Query, LUP_FLUSHCACHE or LUP_RETURN_BLOB,
        procedure(Q: PWSAQUERYSETW; Buffer: TBytes)
        begin
          if not InBuffer(Q.lpBlob, SizeOf(Winapi.Winsock2.BLOB), Buffer) then
          begin
            J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, 'Missing SDP blob'));
            Exit;
          end;
          if (Q.lpBlob.cbSize > BLUETOOTH_SDP_MAX_BYTES) or not InBuffer(Q.lpBlob.pBlobData, Q.lpBlob.cbSize, Buffer) then
          begin
            J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, 'Invalid native SDP record'));
            Exit;
          end;
          var Bytes: TBytes;
          SetLength(Bytes, Q.lpBlob.cbSize);
          if Length(Bytes) <> 0 then
            Move(Q.lpBlob.pBlobData^, Bytes[0], Length(Bytes));
          try
            var S := DecodeBluetoothService(Bytes, TargetDevice);
            if BluetoothServiceMatches(S, Wanted) then
              J.AddService(SelectBluetoothAttributes(S, IDs));
          except
            on E: EBluetoothSDP do
              J.Fail(ErrorValue(TBluetoothErrorCode.IOFailure, 0, E.Message));
          end;
        end);
    end);
end;

function TProvider.Connect(const Endpoint: TBluetoothEndpoint; const Options: TBluetoothConnectOptions): IBluetoothConnect;
begin
  var Target := Endpoint;
  var Requirements := Options;
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      if Target.Transport <> TBluetoothTransport.RFCOMM then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows user-mode backend supports RFCOMM'));
        Exit;
      end;
      if (Target.Device.Value > $FFFFFFFFFFFF) or (Target.Channel > 30) or ((Target.Channel = 0) and IsEqualGUID(Target.Service.Value, Default(TGUID))) then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.InvalidArgument, 0, 'Invalid RFCOMM endpoint'));
        Exit;
      end;
      if not Ready(J) then
        Exit;
      var S := WSASocketW(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM, nil, 0, WSA_FLAG_OVERLAPPED);
      if S = INVALID_SOCKET then
      begin
        J.Fail(NativeError(WSAGetLastError, 'Create RFCOMM socket'));
        Exit;
      end;
      J.Lock.Acquire;
      try
        if not J.Pending then
        begin
          closesocket(S);
          Exit;
        end;
        J.Socket := S;
      finally
        J.Lock.Release;
      end;
      try
        J.Lock.Acquire;
        try
          if not J.Pending then
            Exit;
          var E := Configure(J.Socket, Requirements);
          if E.Code <> TBluetoothErrorCode.None then
          begin
            J.Fail(E);
            Exit;
          end;
          if not Nonblocking(J.Socket) then
          begin
            J.Fail(NativeError(WSAGetLastError, 'Nonblocking RFCOMM'));
            Exit;
          end;
        finally
          J.Lock.Release;
        end;
        var Address: TSockAddrBth := Default(TSockAddrBth);
        Address.addressFamily := AF_BTH;
        Address.btAddr := Target.Device.Value;
        Address.port := Target.Channel;
        if Address.port = 0 then
          Address.serviceClassId := Target.Service.Value;
        var Code := 0;
        J.Lock.Acquire;
        try
          if not J.Pending then
            Exit;
          if Winapi.Winsock2.connect(J.Socket, PSockAddr(@Address)^, SizeOf(Address)) <> 0 then
            Code := WSAGetLastError;
        finally
          J.Lock.Release;
        end;
        if (Code <> 0) and (Code <> WSAEWOULDBLOCK) and (Code <> WSAEINPROGRESS) then
        begin
          J.Fail(NativeError(Code, 'Connect RFCOMM'));
          Exit;
        end;
        var Started := GetTickCount64;
        var Timeout := Requirements.TimeoutMillis;
        if Timeout = 0 then
          Timeout := 30000;
        while J.Pending and (Code <> 0) do
        begin
          if GetTickCount64 - Started >= Timeout then
          begin
            J.Fail(ErrorValue(TBluetoothErrorCode.Timeout, WSAETIMEDOUT, 'RFCOMM connect timeout'));
            Exit;
          end;
          J.Lock.Acquire;
          try
            if J.Socket = INVALID_SOCKET then
              Exit;
            var WriteSet, ErrorSet: TFDSet;
            FD_ZERO(WriteSet);
            FD_ZERO(ErrorSet);
            _FD_SET(J.Socket, WriteSet);
            _FD_SET(J.Socket, ErrorSet);
            var Time: TTimeVal := Default(TTimeVal);
            var Selected := select(0, nil, @WriteSet, @ErrorSet, @Time);
            if Selected = SOCKET_ERROR then
            begin
              J.Fail(NativeError(WSAGetLastError, 'RFCOMM select'));
              Exit;
            end;
            if Selected > 0 then
            begin
              var Len: Integer := SizeOf(Code);
              Code := 0;
              if getsockopt(J.Socket, SOL_SOCKET, SO_ERROR, PAnsiChar(@Code), Len) <> 0 then
                Code := WSAGetLastError;
              if Code <> 0 then
              begin
                J.Fail(NativeError(Code, 'RFCOMM connect completion'));
                Exit;
              end;
            end;
          finally
            J.Lock.Release;
          end;
          if Code <> 0 then
            J.Stop.WaitFor(5);
        end;
        if not J.Pending then
          Exit;
        var Info: TBluetoothChannelInfo := Default(TBluetoothChannelInfo);
        Info.Endpoint := Target;
        var Peer: TSockAddrBth := Default(TSockAddrBth);
        var Len: Integer := SizeOf(Peer);
        J.Lock.Acquire;
        try
          if J.Socket = INVALID_SOCKET then
            Exit;
          if getpeername(J.Socket, PSockAddr(@Peer)^, Len) <> 0 then
          begin
            J.Fail(NativeError(WSAGetLastError, 'RFCOMM peer'));
            Exit;
          end;
          S := J.Socket;
          J.Socket := INVALID_SOCKET;
        finally
          J.Lock.Release;
        end;
        Info.Endpoint.Device.Value := Peer.btAddr;
        if (Peer.port >= 1) and (Peer.port <= 30) then
          Info.Endpoint.Channel := Peer.port;
        Info.Security := Requirements.Security;
        if TBluetoothSecurity.Encrypted in Info.Security then
          Include(Info.Security, TBluetoothSecurity.Authenticated);
        J.SetChannel(Adopt(J.Context, S, Info));
      finally
        J.Lock.Acquire;
        try
          if J.Socket <> INVALID_SOCKET then
            closesocket(J.Socket);
          J.Socket := INVALID_SOCKET;
        finally
          J.Lock.Release;
        end;
      end;
    end);
end;

function TProvider.Listen(const Service: TBluetoothService; const Options: TBluetoothConnectOptions): IBluetoothListen;
begin
  var Requirements := Options;
  var Requested := CopyBluetoothService(Service);
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      if Requested.Endpoint.Transport <> TBluetoothTransport.RFCOMM then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows user-mode backend supports RFCOMM'));
        Exit;
      end;
      if (Requested.Endpoint.Channel > 30) or not Ready(J) then
      begin
        if J.Pending then
          J.Fail(ErrorValue(TBluetoothErrorCode.InvalidArgument, 0, 'Invalid RFCOMM channel'));
        Exit;
      end;
      var C := J.Context.Raw;
      C.Lock.Acquire;
      try
        if C.Listeners >= 32 then
        begin
          J.Fail(ErrorValue(TBluetoothErrorCode.ResourceLimit, 0, 'RFCOMM listener capacity'));
          Exit;
        end;
        Inc(C.Listeners);
      finally
        C.Lock.Release;
      end;
      var S := WSASocketW(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM, nil, 0, WSA_FLAG_OVERLAPPED);
      var Transferred := False;
      try
        if S = INVALID_SOCKET then
        begin
          J.Fail(NativeError(WSAGetLastError, 'Create RFCOMM listener'));
          Exit;
        end;
        var E := Configure(S, Requirements);
        if E.Code <> TBluetoothErrorCode.None then
        begin
          J.Fail(E);
          Exit;
        end;
        var Address: TSockAddrBth := Default(TSockAddrBth);
        Address.addressFamily := AF_BTH;
        Address.btAddr := C.Snapshot.Device.Address.Value;
        Address.port := Requested.Endpoint.Channel;
        if Address.port = 0 then
          Address.port := BT_PORT_ANY;
        if bind(S, PSockAddr(@Address)^, SizeOf(Address)) <> 0 then
        begin
          J.Fail(NativeError(WSAGetLastError, 'Bind RFCOMM listener'));
          Exit;
        end;
        var Len: Integer := SizeOf(Address);
        if getsockname(S, PSockAddr(@Address)^, Len) <> 0 then
        begin
          J.Fail(NativeError(WSAGetLastError, 'RFCOMM listener address'));
          Exit;
        end;
        if not Nonblocking(S) or (Winapi.Winsock2.listen(S, 8) <> 0) then
        begin
          J.Fail(NativeError(WSAGetLastError, 'Listen RFCOMM'));
          Exit;
        end;
        var Bound := Requested;
        var Endpoint := Bound.Endpoint;
        Endpoint.Device.Value := Address.btAddr;
        Endpoint.Channel := Address.port;
        BindBluetoothService(Bound, Endpoint);
        var L: IBluetoothListener := TListener.Create(J.Context, S, Bound, Requirements.Security);
        Transferred := True;
        J.SetListener(L);
        if not Requirements.DeferredAdvertisement then
        begin
          var Registration: IBluetoothServiceRegistration;
          Supports(L, IBluetoothServiceRegistration, Registration);
          var P := Registration.Publish(Bound, 0);
          while (P.State = TBluetoothOperationState.Pending) and J.Pending do
            J.Stop.WaitFor(1);
          if not J.Pending then
          begin
            P.Cancel;
            L.Close;
          end
          else if P.State <> TBluetoothOperationState.Completed then
          begin
            J.Fail(P.Error);
            L.Close;
          end;
        end;
      finally
        if not Transferred then
        begin
          if S <> INVALID_SOCKET then
            closesocket(S);
          C.Lock.Acquire;
          try
            Dec(C.Listeners);
          finally
            C.Lock.Release;
          end;
        end;
      end;
    end);
end;

function TProvider.SetDiscoverable(Enabled: Boolean): IBluetoothOperation;
begin
  var Code: UInt32 := 0;
  if Enabled then
    Code := $9E8B33;
  Result := SetDiscoverability(Code);
end;

function TProvider.SetDiscoverability(AccessCode: UInt32): IBluetoothOperation;
begin
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      if (AccessCode <> 0) and (AccessCode <> $9E8B33) then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.Unsupported, 0, 'Windows exposes GIAC discoverability only'));
        Exit;
      end;
      var Radio := J.Context.Raw.Radio;
      if Radio = 0 then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.Unavailable, 0, 'Bluetooth radio unavailable'));
        Exit;
      end;
      var C := J.Context.Raw;
      C.DiscoveryLock.Acquire;
      try
        var Original := BluetoothIsDiscoverable(Radio) <> False;
        if not BluetoothEnableDiscovery(Radio, AccessCode <> 0) then
          J.Fail(NativeError(GetLastError, 'Set radio discoverability'))
        else
        begin
          if not C.DiscoveryChanged then
          begin
            C.DiscoveryOriginal := Original;
            C.DiscoveryRadio := C.Snapshot.Device.Address;
          end;
          C.DiscoveryChanged := True;
          C.DiscoveryLast := AccessCode <> 0;
          C.Refresh;
        end;
      finally
        C.DiscoveryLock.Release;
        CloseHandle(Radio);
      end;
    end);
end;

function TProvider.QueryDevice(const Device: TAddress; RefreshName: Boolean): IBluetoothDeviceQuery;
begin
  var TargetDevice := Device;
  Result := Context.Raw.Start(
    procedure(J: TJob)
    begin
      if RefreshName then
      begin
        var Found := False;
        DoInquiry(J, $9E8B33, 6000,
          procedure(D: TBluetoothDevice)
          begin
            if D.Address.Value = TargetDevice.Value then
            begin
              J.Lock.Acquire;
              try
                J.Device := D;
              finally
                J.Lock.Release;
              end;
              Found := True;
            end;
          end);
        if not Found and J.Pending then
          J.Fail(ErrorValue(TBluetoothErrorCode.Unreachable, 0, 'Device did not answer fresh inquiry'));
        Exit;
      end;
      var Radio := J.Context.Raw.Radio;
      if Radio = 0 then
      begin
        J.Fail(ErrorValue(TBluetoothErrorCode.Unavailable, 0, 'Bluetooth radio unavailable'));
        Exit;
      end;
      try
        var N: Winapi.Bluetooth.TBluetoothDeviceInfo := Default(Winapi.Bluetooth.TBluetoothDeviceInfo);
        N.dwSize := SizeOf(N);
        N.Address.ullLong := TargetDevice.Value;
        var Code := BluetoothGetDeviceInfo(Radio, N);
        if Code <> 0 then
          J.Fail(NativeError(Code, 'Cached Bluetooth device query'))
        else
        begin
          J.Lock.Acquire;
          try
            J.Device := DeviceValue(N);
          finally
            J.Lock.Release;
          end;
        end;
      finally
        CloseHandle(Radio);
      end;
    end);
end;

function CreateWindowsBluetoothProvider: IBluetoothProvider;
begin
  try
    Result := TProvider.Create;
  except
    Result := CreateUnavailableBluetoothProvider;
  end;
end;

function AdoptWindowsBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;
begin
  Result := AdoptOverlappedBluetoothSocket(Socket, Info);
end;
{$ELSE}

function CreateWindowsBluetoothProvider: IBluetoothProvider;
begin
  Result := CreateUnavailableBluetoothProvider;
end;

function AdoptWindowsBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;
begin
  raise ENotSupportedException.Create('Windows Bluetooth sockets are unavailable');
end;
{$ENDIF}

end.

