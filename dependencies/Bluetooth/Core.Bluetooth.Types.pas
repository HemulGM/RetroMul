unit Core.Bluetooth.Types;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

type
  TBluetoothAddressKind = (public, Random, Unspecified);

  TBluetoothAddress = record
    Value: UInt64; // Low 48 bits, independent of native byte order.
    Kind: TBluetoothAddressKind;
    class function TryParse(const Text: string; out Address: TBluetoothAddress): Boolean; static;
    function ToString: string;
  end;

  TBluetoothUUID = record
    Value: TGUID;
    class function TryParse(const Text: string; out UUID: TBluetoothUUID): Boolean; static;
    function ToString: string; // Canonical uppercase, 32 hexadecimal digits.
  end;

  TBluetoothState = (Unavailable, PermissionRequired, PoweredOff, Ready);

  TBluetoothCapability = (DeviceDiscovery, ServiceDiscovery, RFCOMMClient,
    RFCOMMServer, L2CAPClient, L2CAPServer, GattClient);

  TBluetoothCapabilities = set of TBluetoothCapability;

  TBluetoothTransport = (RFCOMM, L2CAP);

  TBluetoothSecurity = (Authenticated, Encrypted, Authorized);

  TBluetoothSecurityFlags = set of TBluetoothSecurity;

  TBluetoothErrorCode = (None, Unavailable, PermissionDenied, PoweredOff,
    Unsupported, InvalidArgument, Busy, Timeout, Cancelled, Unreachable,
    AuthenticationFailed, ResourceLimit, IOFailure);

  TBluetoothError = record
    Code: TBluetoothErrorCode;
    NativeCode: Int64;
    MessageText: string;
  end;

  TBluetoothDevice = record
    Address: TBluetoothAddress;
    Name: string;
    ClassOfDevice: UInt32;
    Paired, Connected, Trusted: Boolean;
  end;

  TBluetoothAdapterInfo = record
    State: TBluetoothState;
    Device: TBluetoothDevice;
    Capabilities: TBluetoothCapabilities;
    DiscoverableCode: UInt32; // Classic inquiry access code, zero when hidden.
  end;

  TBluetoothAttribute = record
    ID: Word;
    Data: TBytes; // SDP Data Element wire encoding; no Java object references.
  end;

  TBluetoothEndpoint = record
    Device: TBluetoothAddress;
    Transport: TBluetoothTransport;
    Service: TBluetoothUUID;
    Channel: Word; // RFCOMM channel or L2CAP PSM; zero requests UUID resolution.
  end;

  TBluetoothService = record
    Endpoint: TBluetoothEndpoint;
    Name: string;
    UUIDs: TArray<TBluetoothUUID>;
    Attributes: TArray<TBluetoothAttribute>;
  end;

  TBluetoothConnectOptions = record
    Security: TBluetoothSecurityFlags; // Requirements, not achieved security.
    ReceiveMTU, TransmitMTU: Word; // Zero selects backend defaults.
    TimeoutMillis: Cardinal;
    RequireMaster: Boolean;
    // A prepared server must not become discoverable until explicit Publish.
    // Providers accepting this option return IBluetoothServiceRegistration on
    // the listener, or fail Unsupported; silently advertising is not permitted.
    DeferredAdvertisement: Boolean;
  end;

  TBluetoothOperationState = (Pending, Completed, Cancelled, Failed);

  TBluetoothIOState = (Ready, WouldBlock, EndOfStream, Closed, Failed);

  TBluetoothChannelInfo = record
    Endpoint: TBluetoothEndpoint;
    Security: TBluetoothSecurityFlags; // Actual negotiated security.
    ReceiveMTU, TransmitMTU: Word;
  end;

  TBluetoothTransfer = record
    State: TBluetoothIOState;
    Count: Integer;
    PacketLength: Integer; // Original packet size on L2CAP reads, zero on streams.
    Error: TBluetoothError;
  end;

  // All methods are thread-safe and nonblocking, including Close and Cancel.
  // Backends own OS handles/threads/permission prompts. They never invoke guest
  // code. Callers poll on their own executor and retain interfaces while in use.
  // Returned arrays/records are caller-owned snapshots, not shared mutable data.
  IBluetoothOperation = interface
    ['{CA3F08D3-4416-4651-B39E-4962180CF138}']
    function State: TBluetoothOperationState;
    function Error: TBluetoothError;
    // Idempotent; a terminal operation remains terminal. A pending cancellation
    // becomes Cancelled and publishes no further results. Releasing the last
    // reference cancels pending work and releases completed unclaimed resources.
    procedure Cancel;
  end;

  IBluetoothDeviceDiscovery = interface(IBluetoothOperation)
    ['{C38E9D4C-C5DE-4CC8-A172-5B370F658F88}']
    function TryTakeDevice(out Device: TBluetoothDevice): Boolean;
  end;

  IBluetoothServiceDiscovery = interface(IBluetoothOperation)
    ['{746B46EA-527F-4589-9176-080B6E688749}']
    function TryTakeService(out Service: TBluetoothService): Boolean;
  end;

  IBluetoothChannel = interface
    ['{7C5E49CD-8420-4D31-8823-AB1C97FAFA83}']
    function Info: TBluetoothChannelInfo;
    // Offsets/counts use bytes. Invalid ranges throw EArgumentOutOfRangeException.
    // Stream writes may be partial; L2CAP writes are atomic packets. A truncated
    // packet read discards its remainder and reports the original PacketLength.
    // Zero-count reads are no-ops. WouldBlock never consumes data.
    function Read(var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    function Write(const Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    // Local close is idempotent. Peer close lets queued input drain, then EOF.
    procedure Close;
  end;

  IBluetoothConnect = interface(IBluetoothOperation)
    ['{04CE4F25-C82F-4208-9350-632B75901846}']
    // Available once, only in Completed. Ownership transfers to the caller.
    function TakeChannel: IBluetoothChannel;
  end;

  IBluetoothListener = interface
    ['{E6628841-DFBA-44A5-AE42-808030AF508C}']
    function Service: TBluetoothService;
    function TryAccept(out Channel: IBluetoothChannel): TBluetoothTransfer;
    procedure Close; // Cancels accepts and unregisters advertised service.
  end;

  IBluetoothListen = interface(IBluetoothOperation)
    ['{733680D5-6066-4346-8CFB-760C57FD011F}']
    function TakeListener: IBluetoothListener;
  end;

  IBluetoothServiceRegistration = interface
    ['{8201D589-96E1-4A77-A942-56C01E2027F2}']
    // First call publishes, subsequent calls atomically replace attributes.
    // Endpoint identity is fixed by the listener. Close unregisters and removes
    // this registration's contribution to the adapter service-class bits.
    function Publish(const Service: TBluetoothService; DeviceServiceClasses: UInt32): IBluetoothOperation;
  end;

  IBluetoothLinkControl = interface
    ['{4596BC99-47EF-42E9-9094-3FC36589B242}']
    // Optional live security negotiation. Completion is not proof of achieved
    // security; consumers query the channel's current Info.Security afterward.
    function ChangeSecurity(Security: TBluetoothSecurity; Enabled: Boolean): IBluetoothOperation;
  end;

  IBluetoothProvider = interface
    ['{46E0C359-370C-4884-BF5A-BA5C0DB63B6D}']
    function Info: TBluetoothAdapterInfo;
    function KnownDevices: TArray<TBluetoothDevice>;
    function Discover(TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
    function FindServices(const Device: TBluetoothAddress; const UUIDs: TArray<TBluetoothUUID>; const Attributes: TArray<Word>): IBluetoothServiceDiscovery;
    function Connect(const Endpoint: TBluetoothEndpoint; const Options: TBluetoothConnectOptions): IBluetoothConnect;
    function Listen(const Service: TBluetoothService; const Options: TBluetoothConnectOptions): IBluetoothListen;
    function SetDiscoverable(Enabled: Boolean): IBluetoothOperation;
  end;

  IBluetoothDeviceQuery = interface(IBluetoothOperation)
    ['{89DF24BC-B450-481E-B2A5-D31248822847}']
    function Device: TBluetoothDevice;
  end;
  // Optional classic controls preserve inquiry-code and remote-name semantics
  // without forcing every provider (including virtual adapters) to support them.

  IBluetoothClassicControl = interface
    ['{674BCA41-4B99-4E02-89EC-1A1D9DB0D3C1}']
    function Inquiry(AccessCode: UInt32; TimeoutMillis: Cardinal): IBluetoothDeviceDiscovery;
    function SetDiscoverability(AccessCode: UInt32): IBluetoothOperation;
    function QueryDevice(const Device: TBluetoothAddress; RefreshName: Boolean): IBluetoothDeviceQuery;
  end;

  // BLE/GATT is a separate optional capability, not an RFCOMM byte stream.
  TBluetoothGattAttribute = record
    Service, Characteristic, Descriptor: TBluetoothUUID;
    Handle: UInt64; // Backend-local opaque identifier, never an OS pointer.
    Properties: UInt32;
  end;

  IBluetoothGattOperation = interface(IBluetoothOperation)
    ['{016708D7-BED9-444C-BE65-15A51CD44F32}']
    function Value: TBytes;
    function Attributes: TArray<TBluetoothGattAttribute>;
  end;

  IBluetoothGattSession = interface
    ['{62DC72A6-5B0D-4CE0-99C4-ACF773B618A9}']
    function Discover: IBluetoothGattOperation;
    function Read(const Attribute: TBluetoothGattAttribute): IBluetoothGattOperation;
    function Write(const Attribute: TBluetoothGattAttribute; const Value: TBytes; WithResponse: Boolean): IBluetoothGattOperation;
    function Subscribe(const Attribute: TBluetoothGattAttribute; Enabled: Boolean): IBluetoothGattOperation;
    function TryTakeNotification(out Attribute: TBluetoothGattAttribute; out Value: TBytes): Boolean;
    procedure Close;
  end;

  IBluetoothGattConnect = interface(IBluetoothOperation)
    ['{E75FA92A-2303-44D3-9D3E-D92011A3FC26}']
    function TakeSession: IBluetoothGattSession;
  end;

  IBluetoothGattProvider = interface
    ['{4F60DA07-9000-4D74-B135-43D4258042D4}']
    function ConnectGatt(const Device: TBluetoothAddress; const Options: TBluetoothConnectOptions): IBluetoothGattConnect;
  end;

implementation

function IsHex(const Value: string): Boolean;
begin
  Result := Value <> '';
  for var C in Value do
    if not CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

class function TBluetoothAddress.TryParse(const Text: string; out Address: TBluetoothAddress): Boolean;
begin
  Address := Default(TBluetoothAddress);
  var S := Text;
  if (Length(S) = 17) and CharInSet(S[3], [':', '-']) then
  begin
    var Separator := S[3];
    for var I := 1 to 5 do
      if S[I * 3] <> Separator then
        Exit(False);
    S := S.Replace(string(Separator), '');
  end;
  Result := (Length(S) = 12) and IsHex(S) and TryStrToUInt64('$' + S, Address.Value);
  if not Result then
    Address := Default(TBluetoothAddress);
end;

function TBluetoothAddress.ToString: string;
begin
  if Value > $FFFFFFFFFFFF then
    raise EArgumentOutOfRangeException.Create('Bluetooth address exceeds 48 bits');
  Result := IntToHex(Value, 12);
end;

class function TBluetoothUUID.TryParse(const Text: string; out UUID: TBluetoothUUID): Boolean;
begin
  UUID := Default(TBluetoothUUID);
  var S := Text;
  if Length(S) = 36 then
  begin
    if (S[9] <> '-') or (S[14] <> '-') or (S[19] <> '-') or (S[24] <> '-') then
      Exit(False);
    S := S.Replace('-', '');
  end;
  if not IsHex(S) then
    Exit(False);
  if Length(S) <= 8 then
    S := S.PadLeft(8, '0') + '00001000800000805F9B34FB';
  if Length(S) <> 32 then
    Exit(False);
  S := Copy(S, 1, 8) + '-' + Copy(S, 9, 4) + '-' + Copy(S, 13, 4) + '-' + Copy(S, 17, 4) + '-' + Copy(S, 21, 12);
  UUID.Value := StringToGUID('{' + S + '}');
  Result := True;
end;

function TBluetoothUUID.ToString: string;
begin
  Result := GUIDToString(Value).Replace('{', '').Replace('}', '').Replace('-', '').ToUpper;
end;

end.

