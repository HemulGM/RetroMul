unit Core.Messaging.virtual;

interface

uses
  Core.Messaging.Types;

type
  IVirtualMessagingNetwork = interface
    ['{9171C59C-BDED-4786-B3E2-289B678F5BB3}']
    function Provider(const Phone: string; Permissions: TMessagingPermissions): IMessagingProvider;
    function TakeInbox(const Phone: string; out Message: TWirelessMessage): TMessagingError;
    function Broadcast(Identifier: Word; const Message: TWirelessMessage): TMessagingError;
  end;

function CreateVirtualMessagingNetwork(QueueCapacity: Integer = 64; AddressCapacity: Integer = 1024; MaxSMSSegments: Integer = 255; ByteCapacity: Int64 = 8388608): IVirtualMessagingNetwork;

implementation

uses
  System.SysUtils, System.Generics.Collections;

type
  TInbox = class
    Values: TQueue<TWirelessMessage>;
    Serial: UInt64;
    constructor Create;
    destructor Destroy; override;
  end;

  TNetwork = class;

  TChannel = class(TInterfacedObject, IMessagingChannel)
    Network: TNetwork;
    Keep: IVirtualMessagingNetwork;
    Phone, Key: string;
    Endpoint: TMessageAddress;
    Mode, MaxSMSSegments: Integer;
    Permissions: TMessagingPermissions;
    Closed: Boolean;
    Inbox: TInbox;
    destructor Destroy; override;
    function Send(const Destination: TMessageAddress; const Message: TWirelessMessage): TMessagingError;
    function Receive(out Message: TWirelessMessage): TMessagingError;
    function Status(out Pending: Integer; out ArrivalSerial: UInt64): TMessagingError;
    procedure Close;
  end;

  TProvider = class(TInterfacedObject, IMessagingProvider)
    Network: TNetwork;
    Keep: IVirtualMessagingNetwork;
    Details: TMessagingInfo;
    function Info: TMessagingInfo;
    function Open(const Address: TMessageAddress; Mode: Integer; out Channel: IMessagingChannel): TMessagingError;
  end;

  TNetwork = class(TInterfacedObject, IVirtualMessagingNetwork)
    Lock: TObject;
    Queues: TObjectDictionary<string, TInbox>;
    Servers: TList<TChannel>;
    QueueCapacity, AddressCapacity, MaxSMSSegments: Integer;
    ByteCapacity, QueuedBytes: Int64;
    constructor Create(Q, A, S: Integer; Bytes: Int64);
    destructor Destroy; override;
    function GetQueue(const Key: string): TInbox;
    function Provider(const Phone: string; Permissions: TMessagingPermissions): IMessagingProvider;
    function TakeInbox(const Phone: string; out Message: TWirelessMessage): TMessagingError;
    function Broadcast(Identifier: Word; const Message: TWirelessMessage): TMessagingError;
  end;

function Digits(const Phone: string): string;
begin
  Result := Phone;
  if Result.StartsWith('+') then
    Delete(Result, 1, 1);
end;

function QueueKey(const Phone: string; Protocol: TMessagingProtocol; Port: Integer; ApplicationID: UInt32 = 0): string;
begin
  if Protocol = TMessagingProtocol.SiemensSMS then
    Exit(IntToStr(Ord(Protocol)) + '|' + Digits(Phone) + '|' + UIntToStr(ApplicationID));
  Result := IntToStr(Ord(Protocol)) + '|' + Digits(Phone) + '|' + IntToStr(Port);
end;

function Snapshot(const Message: TWirelessMessage): TWirelessMessage;
begin
  Result := Message;
  Result.Data := Copy(Message.Data);
end;

function StorageBytes(const Message: TWirelessMessage): Int64;
begin
  Result := Int64(Length(Message.Text)) * 2 + Length(Message.Data) + Int64(Length(Message.Address)) * 2 + 64;
end;

constructor TInbox.Create;
begin
  inherited;
  Values := TQueue<TWirelessMessage>.Create;
end;

destructor TInbox.Destroy;
begin
  Values.Free;
  inherited;
end;

constructor TNetwork.Create(Q, A, S: Integer; Bytes: Int64);
begin
  inherited Create;
  if (Q < 1) or (Q > 65536) or (A < 1) or (A > 65536) or (S < 3) or (S > 255) or (Bytes < 1) or (Bytes > 1073741824) then
    raise EArgumentOutOfRangeException.Create('Virtual messaging capacity');
  Lock := TObject.Create;
  Queues := TObjectDictionary<string, TInbox>.Create([doOwnsValues]);
  Servers := TList<TChannel>.Create;
  QueueCapacity := Q;
  AddressCapacity := A;
  MaxSMSSegments := S;
  ByteCapacity := Bytes;
end;

destructor TNetwork.Destroy;
begin
  Servers.Free;
  Queues.Free;
  Lock.Free;
  inherited;
end;

function TNetwork.GetQueue(const Key: string): TInbox;
begin
  if Queues.TryGetValue(Key, Result) then
    Exit;
  Result := nil;
  if Queues.Count >= AddressCapacity then
    for var Old in Queues.Keys.ToArray do
      if Queues[Old].Values.Count = 0 then
      begin
        var Active := False;
        for var C in Servers do
          if C.Key = Old then
          begin
            Active := True;
            Break;
          end;
        if not Active then
        begin
          Queues.Remove(Old);
          Break;
        end;
      end;
  if Queues.Count >= AddressCapacity then
    Exit;
  Result := TInbox.Create;
  Queues.Add(Key, Result);
end;

function TNetwork.Provider(const Phone: string; Permissions: TMessagingPermissions): IMessagingProvider;
begin
  var A: TMessageAddress;
  if not TMessageAddress.TryParse('sms://' + Phone, A) or A.Server or (A.Port <> -1) then
    raise EArgumentException.Create('Virtual phone number');
  var P := TProvider.Create;
  P.Network := Self;
  P.Keep := Self;
  P.Details.State := TMessagingState.Ready;
  P.Details.PhoneNumber := Phone;
  P.Details.ServiceCenter := '+555000';
  P.Details.Permissions := Permissions;
  P.Details.MaxSMSSegments := MaxSMSSegments;
  Result := P;
end;

function TProvider.Info: TMessagingInfo;
begin
  Result := Details;
end;

function TProvider.Open(const Address: TMessageAddress; Mode: Integer; out Channel: IMessagingChannel): TMessagingError;
begin
  Channel := nil;
  if not (Mode in [1, 2, 3]) then
    Exit(TMessagingError.InvalidAddress);
  var Parsed: TMessageAddress;
  if not TMessageAddress.TryParse(Address.ToString, Parsed) or (Parsed.Server <> Address.Server) or (Parsed.Protocol <> Address.Protocol) or (Parsed.Port <> Address.Port) or
    (Parsed.Phone <> Address.Phone) or (Parsed.ApplicationID <> Address.ApplicationID) then
    Exit(TMessagingError.InvalidAddress);
  if ((Address.Protocol <> TMessagingProtocol.CBS) and not (TMessagingPermission.SMSConnect in Details.Permissions)) or
    ((Address.Protocol = TMessagingProtocol.CBS) and not (TMessagingPermission.CBSConnect in Details.Permissions)) then
    Exit(TMessagingError.Denied);
  if (Address.Protocol = TMessagingProtocol.CBS) and (not Address.Server or (Mode = 2)) then
    Exit(TMessagingError.InvalidAddress);
  TMonitor.Enter(Network.Lock);
  try
    var Key := QueueKey(Details.PhoneNumber, Address.Protocol, Address.Port, Address.ApplicationID);
    var Inbox: TInbox := nil;
    if Address.Server then
    begin
      for var S in Network.Servers do
        if not S.Closed and (S.Key = Key) then
          Exit(TMessagingError.Busy);
      Inbox := Network.GetQueue(Key);
      if Inbox = nil then
        Exit(TMessagingError.Capacity);
    end;
    var C := TChannel.Create;
    C.Network := Network;
    C.Keep := Keep;
    var Hold: IMessagingChannel := C;
    C.Phone := Details.PhoneNumber;
    C.Endpoint := Address;
    C.Mode := Mode;
    C.Permissions := Details.Permissions;
    C.MaxSMSSegments := Details.MaxSMSSegments;
    C.Key := Key;
    C.Inbox := Inbox;
    if Address.Server then
      Network.Servers.Add(C);
    Channel := Hold;
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Network.Lock);
  end;
end;

destructor TChannel.Destroy;
begin
  Close;
  Keep := nil;
  inherited;
end;

procedure TChannel.Close;
begin
  TMonitor.Enter(Network.Lock);
  try
    if Closed then
      Exit;
    Closed := True;
    Network.Servers.Remove(Self);
  finally
    TMonitor.Exit(Network.Lock);
  end;
end;

function TChannel.Status(out Pending: Integer; out ArrivalSerial: UInt64): TMessagingError;
begin
  Pending := 0;
  ArrivalSerial := 0;
  TMonitor.Enter(Network.Lock);
  try
    if Closed then
      Exit(TMessagingError.Closed);
    if Inbox <> nil then
    begin
      Pending := Inbox.Values.Count;
      ArrivalSerial := Inbox.Serial;
    end;
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Network.Lock);
  end;
end;

function TChannel.Send(const Destination: TMessageAddress; const Message: TWirelessMessage): TMessagingError;
begin
  TMonitor.Enter(Network.Lock);
  try
    if Closed then
      Exit(TMessagingError.Closed);
    if not (TMessagingPermission.SMSSend in Permissions) then
      Exit(TMessagingError.Denied);
    if ((Mode and 2) = 0) or (Endpoint.Protocol = TMessagingProtocol.CBS) or
      (Destination.Protocol <> Endpoint.Protocol) or Destination.Server then
      Exit(TMessagingError.InvalidAddress);
    var Parsed: TMessageAddress;
    if not TMessageAddress.TryParse(Destination.ToString, Parsed) or Parsed.Server or (Parsed.Phone <> Destination.Phone) or
      (Parsed.Port <> Destination.Port) or (Parsed.ApplicationID <> Destination.ApplicationID) then
      Exit(TMessagingError.InvalidAddress);
    if SMSRestrictedPort(Destination.Port) then
      Exit(TMessagingError.Denied);
    var Segments := SMSCountSegments(Message.Text, Length(Message.Data), Message.Kind = TMessagingPayload.Binary,
      (Destination.Port >= 0) or (Destination.Protocol = TMessagingProtocol.SiemensSMS));
    if (Segments = 0) or (Segments > MaxSMSSegments) then
      Exit(TMessagingError.TooLarge);
    var Q := Network.GetQueue(QueueKey(Destination.Phone, Destination.Protocol, Destination.Port, Destination.ApplicationID));
    if Q = nil then
      Exit(TMessagingError.Capacity);
    if (Q.Values.Count >= Network.QueueCapacity) or (Q.Serial = High(UInt64)) then
      Exit(TMessagingError.WouldBlock);
    var CopyOfMessage := Snapshot(Message);
    var Source: TMessageAddress := Default(TMessageAddress);
    Source.Protocol := Destination.Protocol;
    Source.ApplicationID := Destination.ApplicationID;
    Source.Phone := Phone;
    Source.Port := -1;
    if Endpoint.Server and (Destination.Port >= 0) then
      Source.Port := Endpoint.Port;
    CopyOfMessage.Address := Source.ToString;
    var Cost := StorageBytes(CopyOfMessage);
    if Cost > Network.ByteCapacity then
      Exit(TMessagingError.Capacity);
    if Cost > Network.ByteCapacity - Network.QueuedBytes then
      Exit(TMessagingError.WouldBlock);
    Q.Values.Enqueue(CopyOfMessage);
    Inc(Network.QueuedBytes, Cost);
    Inc(Q.Serial);
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Network.Lock);
  end;
end;

function TChannel.Receive(out Message: TWirelessMessage): TMessagingError;
begin
  Message := Default(TWirelessMessage);
  TMonitor.Enter(Network.Lock);
  try
    if Closed then
      Exit(TMessagingError.Closed);
    if (Inbox = nil) or ((Mode and 1) = 0) then
      Exit(TMessagingError.InvalidAddress);
    if ((Endpoint.Protocol <> TMessagingProtocol.CBS) and not (TMessagingPermission.SMSReceive in Permissions)) or
      ((Endpoint.Protocol = TMessagingProtocol.CBS) and not (TMessagingPermission.CBSReceive in Permissions)) then
      Exit(TMessagingError.Denied);
    if Inbox.Values.Count = 0 then
      Exit(TMessagingError.WouldBlock);
    Message := Snapshot(Inbox.Values.Peek);
    Inbox.Values.Dequeue;
    Dec(Network.QueuedBytes, StorageBytes(Message));
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Network.Lock);
  end;
end;

function TNetwork.TakeInbox(const Phone: string; out Message: TWirelessMessage): TMessagingError;
begin
  Message := Default(TWirelessMessage);
  TMonitor.Enter(Lock);
  try
    var Q: TInbox;
    if not Queues.TryGetValue(QueueKey(Phone, TMessagingProtocol.SMS, -1), Q) or (Q.Values.Count = 0) then
      Exit(TMessagingError.WouldBlock);
    Message := Snapshot(Q.Values.Peek);
    Q.Values.Dequeue;
    Dec(QueuedBytes, StorageBytes(Message));
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Lock);
  end;
end;

function TNetwork.Broadcast(Identifier: Word; const Message: TWirelessMessage): TMessagingError;
begin
  TMonitor.Enter(Lock);
  try
    var Total := Int64(0);
    for var C in Servers do
      if not C.Closed and (C.Endpoint.Protocol = TMessagingProtocol.CBS) and (C.Endpoint.Port = Identifier) then
      begin
        if (C.Inbox.Values.Count >= QueueCapacity) or (C.Inbox.Serial = High(UInt64)) then
          Exit(TMessagingError.WouldBlock);
        var M := Message;
        M.Address := C.Endpoint.ToString;
        Inc(Total, StorageBytes(M));
      end;
    if Total > ByteCapacity then
      Exit(TMessagingError.Capacity);
    if Total > ByteCapacity - QueuedBytes then
      Exit(TMessagingError.WouldBlock);
    for var C in Servers do
      if not C.Closed and (C.Endpoint.Protocol = TMessagingProtocol.CBS) and (C.Endpoint.Port = Identifier) then
      begin
        var CopyOfMessage := Snapshot(Message);
        CopyOfMessage.Address := C.Endpoint.ToString;
        CopyOfMessage.HasTimestamp := False;
        CopyOfMessage.Timestamp := 0;
        C.Inbox.Values.Enqueue(CopyOfMessage);
        Inc(C.Inbox.Serial);
      end;
    Inc(QueuedBytes, Total);
    Result := TMessagingError.None;
  finally
    TMonitor.Exit(Lock);
  end;
end;

function CreateVirtualMessagingNetwork(QueueCapacity, AddressCapacity, MaxSMSSegments: Integer; ByteCapacity: Int64): IVirtualMessagingNetwork;
begin
  Result := TNetwork.Create(QueueCapacity, AddressCapacity, MaxSMSSegments, ByteCapacity);
end;

end.

