unit J2ME.Bluetooth;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Runtime, Core.Bluetooth.Types, J2ME.Bluetooth.Transport;

type
  TJ2MEBluetoothEvent = record
    Token: Integer;
    Name, Descriptor: string;
    Arguments: TArray<TJVMValue>;
  end;

  TJ2MEBluetoothSearch = class
  public
    ID, Listener, Results: Integer;
    Inquiry, Cancelled: Boolean;
    Devices: IBluetoothDeviceDiscovery;
    Services: IBluetoothServiceDiscovery;
    Seen: TDictionary<UInt64, Byte>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJ2MEBluetoothSelection = class
  public
    Ref, Index, Results, Security: Integer;
    Master, Inquired, Initialized: Boolean;
    UUID: TBluetoothUUID;
    Target: TBluetoothAddress;
    Candidates: TArray<TBluetoothDevice>;
    Seen: TDictionary<UInt64, Byte>;
    Devices: IBluetoothDeviceDiscovery;
    Services: IBluetoothServiceDiscovery;
    constructor Create;
    destructor Destroy; override;
  end;

  TJ2MEBluetoothRecord = class
  public
    Ref, Origin: Integer;
    Info: TBluetoothService;
    Populate: IBluetoothServiceDiscovery;
    Requested: TArray<Word>;
    destructor Destroy; override;
  end;

  TJ2MEBluetooth = class
  private
    FVM: TJVM;
    FProvider: IBluetoothProvider;
    FTransport: TJ2MEBluetoothTransport;
    FJobs: TObjectList<TJ2MEBluetoothSearch>;
    FEvents: TQueue<TJ2MEBluetoothEvent>;
    FRecords: TObjectDictionary<Integer, TJ2MEBluetoothRecord>;
    FCache: TDictionary<UInt64, TBluetoothDevice>;
    FSelections: TObjectDictionary<Integer, TJ2MEBluetoothSelection>;
    FNextID: Integer;
    FDiscoverable: IBluetoothOperation;
    FNameQuery: TDictionary<Integer, IBluetoothDeviceQuery>;
    function ExportRecord(Ref: Integer): TBluetoothService;
    procedure Ready;
    function SelectService(const UUID: TBluetoothUUID; Security: Integer; Master: Boolean): TJVMValue;
    function ServiceQueries: Integer;
    function Inquiring: Boolean;
    procedure Queue(Token: Integer; const Name, Desc: string; const Args: array of TJVMValue);
    procedure Discard(Token: Integer);
    function Remote(const Device: TBluetoothDevice): Integer;
    function DeviceClass(Value: UInt32): Integer;
    function NewRecord(const Service: TBluetoothService; Origin: Integer): Integer;
    function InvokeRecord(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  public
    constructor Create(VM: TJVM; const Provider: IBluetoothProvider);
    destructor Destroy; override;
    procedure Install;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    procedure Poll;
    procedure Shutdown;
    function TakeEvent(out Event: TJ2MEBluetoothEvent): Boolean;
    procedure ReleaseEvent(const Event: TJ2MEBluetoothEvent);
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  end;

implementation

uses
  System.Math, Java.Classes, J2ME.Bluetooth.Data, Core.Bluetooth.SDP,
  Core.Bluetooth.Service;
{$Q-}{$R-}

const
  BT = 'javax/bluetooth/';
  local = BT + 'LocalDevice';
  Agent = BT + 'DiscoveryAgent';
  Listener = BT + 'DiscoveryListener';
  RemoteName = BT + 'RemoteDevice';
  RecordAPI = BT + 'ServiceRecord';
  RecordName = Agent + '$Record';
  SelectionClass = Agent + '$Selection';
  Dispatcher = Agent + '$Dispatcher';
  GIAC = $9E8B33;
  LIAC = $9E8B00;

function BTArray(VM: TJVM; const Descriptor: string; Count: Integer): Integer;
begin
  if Count > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Bluetooth array capacity');
  Result := VM.NewArray(Descriptor, Count);
end;

function GetInt(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsInt;
end;

function GetRef(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsRef;
end;

destructor TJ2MEBluetoothSearch.Destroy;
begin
  Seen.Free;
  if Devices <> nil then
    Devices.Cancel;
  if Services <> nil then
    Services.Cancel;
  inherited;
end;

constructor TJ2MEBluetoothSearch.Create;
begin
  inherited Create;
  Seen := TDictionary<UInt64, Byte>.Create;
end;

constructor TJ2MEBluetoothSelection.Create;
begin
  inherited Create;
  Seen := TDictionary<UInt64, Byte>.Create;
end;

destructor TJ2MEBluetoothSelection.Destroy;
begin
  if Devices <> nil then
    Devices.Cancel;
  if Services <> nil then
    Services.Cancel;
  Seen.Free;
  inherited;
end;

destructor TJ2MEBluetoothRecord.Destroy;
begin
  if Populate <> nil then
    Populate.Cancel;
  inherited;
end;

constructor TJ2MEBluetooth.Create(VM: TJVM; const Provider: IBluetoothProvider);
begin
  inherited Create;
  FVM := VM;
  FProvider := Provider;
  FJobs := TObjectList<TJ2MEBluetoothSearch>.Create(True);
  FEvents := TQueue<TJ2MEBluetoothEvent>.Create;
  FRecords := TObjectDictionary<Integer, TJ2MEBluetoothRecord>.Create([doOwnsValues]);
  FSelections := TObjectDictionary<Integer, TJ2MEBluetoothSelection>.Create([doOwnsValues]);
  FCache := TDictionary<UInt64, TBluetoothDevice>.Create;
  FNameQuery := TDictionary<Integer, IBluetoothDeviceQuery>.Create;
  FNextID := 1;
  FTransport := TJ2MEBluetoothTransport.Create(VM, Provider);
  FTransport.ExportRecord :=
    function(Ref: Integer): TBluetoothService
    begin
      Result := ExportRecord(Ref);
    end;
end;

procedure TJ2MEBluetooth.Shutdown;
begin
  if FTransport <> nil then
    FTransport.Shutdown;
  FSelections.Clear;
  for var J in FJobs do
    FVM.RemoveRoot(J.Listener);
  FJobs.Clear;
  while FEvents.Count > 0 do
    ReleaseEvent(FEvents.Dequeue);
  if FDiscoverable <> nil then
    FDiscoverable.Cancel;
  FDiscoverable := nil;
  for var Operation in FNameQuery.Values do
    Operation.Cancel;
  FNameQuery.Clear;
  for var R in FRecords.Values do
    if R.Populate <> nil then
    begin
      R.Populate.Cancel;
      R.Populate := nil;
    end;
end;

destructor TJ2MEBluetooth.Destroy;
begin
  Shutdown;
  FSelections.Free;
  FTransport.Free;
  FNameQuery.Free;
  FCache.Free;
  FRecords.Free;
  FEvents.Free;
  FJobs.Free;
  inherited;
end;

procedure TJ2MEBluetooth.Ready;
begin
  var Info := FProvider.Info;
  if Info.State <> TBluetoothState.Ready then
    FVM.RaiseJava(BT + 'BluetoothStateException', 'Bluetooth provider is unavailable, disabled or requires permission');
end;

procedure TJ2MEBluetooth.Install;
var
  B: TJavaClassBuilder;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure AbstractMethod(const Name, Desc: string);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure RecordMethods(abstract: Boolean);

    procedure Method(const Name, Desc: string);
    begin
      if abstract then
        AbstractMethod(Name, Desc)
      else
        Native(Name, Desc, JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    end;

  begin
    Method('getAttributeValue', '(I)Ljavax/bluetooth/DataElement;');
    Method('getAttributeIDs', '()[I');
    Method('getHostDevice', '()Ljavax/bluetooth/RemoteDevice;');
    Method('getConnectionURL', '(IZ)Ljava/lang/String;');
    Method('populateRecord', '([I)Z');
    Method('setAttributeValue', '(ILjavax/bluetooth/DataElement;)Z');
    Method('setDeviceServiceClasses', '(I)V');
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(Listener, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    for var Pair in ['INQUIRY_COMPLETED=0', 'INQUIRY_TERMINATED=5', 'INQUIRY_ERROR=7', 'SERVICE_SEARCH_COMPLETED=1', 'SERVICE_SEARCH_TERMINATED=2', 'SERVICE_SEARCH_ERROR=3', 'SERVICE_SEARCH_NO_RECORDS=4', 'SERVICE_SEARCH_DEVICE_NOT_REACHABLE=6'] do
    begin
      var P := Pair.Split(['=']);
      Constant(P[0], StrToInt(P[1]));
    end;
    AbstractMethod('deviceDiscovered', '(Ljavax/bluetooth/RemoteDevice;Ljavax/bluetooth/DeviceClass;)V');
    AbstractMethod('inquiryCompleted', '(I)V');
    AbstractMethod('servicesDiscovered', '(I[Ljavax/bluetooth/ServiceRecord;)V');
    AbstractMethod('serviceSearchCompleted', '(II)V');
    Done;
    B := TJavaClassBuilder.Create(Dispatcher, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    for var Name in ['deviceDiscovered', 'inquiryCompleted', 'servicesDiscovered', 'serviceSearchCompleted'] do
    begin
      var Desc := '(I)V';
      var Wrapper := '(Ljavax/bluetooth/DiscoveryListener;I)V';
      var Arity := 2;
      B.Start;
      B.Emit([$2A, $1B]);
      if Name = 'deviceDiscovered' then
      begin
        B.Start;
        B.Emit([$2A, $2B, $2C]);
        Desc := '(Ljavax/bluetooth/RemoteDevice;Ljavax/bluetooth/DeviceClass;)V';
        Wrapper := '(Ljavax/bluetooth/DiscoveryListener;Ljavax/bluetooth/RemoteDevice;Ljavax/bluetooth/DeviceClass;)V';
        Arity := 3;
      end
      else if Name = 'servicesDiscovered' then
      begin
        B.Emit([$2C]);
        Desc := '(I[Ljavax/bluetooth/ServiceRecord;)V';
        Wrapper := '(Ljavax/bluetooth/DiscoveryListener;I[Ljavax/bluetooth/ServiceRecord;)V';
        Arity := 3;
      end
      else if Name = 'serviceSearchCompleted' then
      begin
        B.Emit([$1C]);
        Desc := '(II)V';
        Wrapper := '(Ljavax/bluetooth/DiscoveryListener;II)V';
        Arity := 3;
      end;
      B.Ref($B9, B.Member(Listener, Name, Desc, 11));
      B.Emit([Byte(Arity), 0, $B1]);
      B.Finish(Name, Wrapper, JVM_ACC_PUBLIC or JVM_ACC_STATIC, Arity, Arity);
    end;
    Done;
    B := TJavaClassBuilder.Create(local, 'java/lang/Object');
    B.Field('$instance', 'Ljavax/bluetooth/LocalDevice;', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Native('getLocalDevice', '()Ljavax/bluetooth/LocalDevice;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_SYNCHRONIZED);
    Native('isPowerOn', '()Z', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getProperty', '(Ljava/lang/String;)Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('getDiscoveryAgent', '()Ljavax/bluetooth/DiscoveryAgent;');
    for var Name in ['getFriendlyName', 'getBluetoothAddress'] do
      Native(Name, '()Ljava/lang/String;');
    Native('getDeviceClass', '()Ljavax/bluetooth/DeviceClass;');
    Native('getDiscoverable', '()I');
    Native('setDiscoverable', '(I)Z', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('getRecord', '(Ljavax/microedition/io/Connection;)Ljavax/bluetooth/ServiceRecord;');
    Native('updateRecord', '(Ljavax/bluetooth/ServiceRecord;)V');
    Done;
    B := TJavaClassBuilder.Create(SelectionClass, 'java/lang/Object', JVM_ACC_FINAL);
    Done;
    B := TJavaClassBuilder.Create(Agent, 'java/lang/Object');
    Constant('NOT_DISCOVERABLE', 0);
    Constant('GIAC', GIAC);
    Constant('LIAC', LIAC);
    Constant('CACHED', 0);
    Constant('PREKNOWN', 1);
    Native('retrieveDevices', '(I)[Ljavax/bluetooth/RemoteDevice;');
    Native('startInquiry', '(ILjavax/bluetooth/DiscoveryListener;)Z');
    Native('cancelInquiry', '(Ljavax/bluetooth/DiscoveryListener;)Z');
    Native('cancelServiceSearch', '(I)Z');
    Native('searchServices', '([I[Ljavax/bluetooth/UUID;Ljavax/bluetooth/RemoteDevice;Ljavax/bluetooth/DiscoveryListener;)I');
    Native('selectService', '(Ljavax/bluetooth/UUID;IZ)Ljava/lang/String;');
    Done;
    B := TJavaClassBuilder.Create(RemoteName, 'java/lang/Object');
    Native('<init>', '(Ljava/lang/String;)V', JVM_ACC_PROTECTED);
    Native('getBluetoothAddress', '()Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Native('getFriendlyName', '(Z)Ljava/lang/String;');
    Native('equals', '(Ljava/lang/Object;)Z');
    Native('hashCode', '()I');
    Native('isTrustedDevice', '()Z');
    Native('authenticate', '()Z');
    Native('isAuthenticated', '()Z');
    Native('isEncrypted', '()Z');
    Native('authorize', '(Ljavax/microedition/io/Connection;)Z');
    Native('isAuthorized', '(Ljavax/microedition/io/Connection;)Z');
    Native('encrypt', '(Ljavax/microedition/io/Connection;Z)Z');
    Native('getRemoteDevice', '(Ljavax/microedition/io/Connection;)Ljavax/bluetooth/RemoteDevice;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Done;
    B := TJavaClassBuilder.Create(RecordAPI, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    Constant('NOAUTHENTICATE_NOENCRYPT', 0);
    Constant('AUTHENTICATE_NOENCRYPT', 1);
    Constant('AUTHENTICATE_ENCRYPT', 2);
    RecordMethods(True);
    Done;
    B := TJavaClassBuilder.Create(RecordName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [RecordAPI];
    RecordMethods(False);
    Done;
  finally
    B.Free;
  end;
  FTransport.Install;
end;

function TJ2MEBluetooth.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
begin
  Result := FTransport.Open(URL, Mode, Timeouts);
end;

function TJ2MEBluetooth.Handles(const Owner: string): Boolean;
begin
  Result := FTransport.Handles(Owner) or (Owner = local) or (Owner = Agent) or (Owner = RemoteName) or (Owner = RecordName);
end;

function TJ2MEBluetooth.DeviceClass(Value: UInt32): Integer;
begin
  Result := FVM.NewObject(BT + 'DeviceClass');
  InvokeJ2MEBluetoothData(FVM, FVM.LoadClass(BT + 'DeviceClass').FindMethod('<init>', '(I)V'), [TJVMValue.Ref(Result), TJVMValue.Int(Integer(Value))]);
end;

function TJ2MEBluetooth.Remote(const Device: TBluetoothDevice): Integer;
begin
  Result := FVM.NewObject(RemoteName);
  var O := FVM.GetObject(Result);
  O.Text := Device.Address.ToString;
  O.Fields.AddOrSetValue('$bt.name', TJVMValue.Ref(FVM.NewString(Device.Name)));
  O.Fields.AddOrSetValue('$bt.paired', TJVMValue.Int(Ord(Device.Paired)));
  O.Fields.AddOrSetValue('$bt.trusted', TJVMValue.Int(Ord(Device.Trusted)));
end;

procedure TJ2MEBluetooth.Queue(Token: Integer; const Name, Desc: string; const Args: array of TJVMValue);
begin
  var E: TJ2MEBluetoothEvent;
  E.Token := Token;
  E.Name := Name;
  E.Descriptor := Desc;
  SetLength(E.Arguments, Length(Args));
  for var I := 0 to High(Args) do
  begin
    E.Arguments[I] := Args[I];
    if Args[I].Kind = TJVMKind.Reference then
      FVM.AddRoot(Args[I].AsRef);
  end;
  FEvents.Enqueue(E);
end;

procedure TJ2MEBluetooth.ReleaseEvent(const Event: TJ2MEBluetoothEvent);
begin
  for var V in Event.Arguments do
    if V.Kind = TJVMKind.Reference then
      FVM.RemoveRoot(V.AsRef);
end;

procedure TJ2MEBluetooth.Discard(Token: Integer);
begin
  var Count := FEvents.Count;
  for var I := 1 to Count do
  begin
    var E := FEvents.Dequeue;
    if E.Token = Token then
      ReleaseEvent(E)
    else
      FEvents.Enqueue(E);
  end;
end;

function TJ2MEBluetooth.TakeEvent(out Event: TJ2MEBluetoothEvent): Boolean;
begin
  Result := FEvents.Count > 0;
  if Result then
    Event := FEvents.Dequeue;
end;

function TJ2MEBluetooth.NewRecord(const Service: TBluetoothService; Origin: Integer): Integer;
begin
  if (Length(Service.Attributes) > Min(256, FVM.MaxArrayLength)) or (FRecords.Count >= 1024) then
    raise EBluetoothSDP.Create('Bluetooth record attribute capacity');
  var Total := Int64(0);
  var Seen := TDictionary<Word, Byte>.Create;
  try
    for var A in Service.Attributes do
    begin
      Inc(Total, Length(A.Data));
      if (Total > BLUETOOTH_SDP_MAX_BYTES) or Seen.ContainsKey(A.ID) then
        raise EBluetoothSDP.Create('Excessive or duplicate SDP attributes');
      Seen.Add(A.ID, 0);
    end;
  finally
    Seen.Free;
  end;
  var RecordValue := TJ2MEBluetoothRecord.Create;
  try
    Result := FVM.NewObject(RecordName);
    RecordValue.Ref := Result;
    RecordValue.Info := Service;
    RecordValue.Origin := Origin;
    var O := FVM.GetObject(Result);
    O.Fields.AddOrSetValue('$bt.origin', TJVMValue.Ref(Origin));
    if Origin = 0 then
    begin
      var Device: TBluetoothDevice;
      Device := Default(TBluetoothDevice);
      Device.Address := Service.Endpoint.Device;
      if FCache.ContainsKey(Device.Address.Value) then
        Device := FCache[Device.Address.Value];
      O.Fields.AddOrSetValue('$bt.host', TJVMValue.Ref(Remote(Device)));
    end;
    var IDs := BTArray(FVM, '[I', Length(Service.Attributes));
    var Values := BTArray(FVM, '[Ljavax/bluetooth/DataElement;', Length(Service.Attributes));
    for var I := 0 to High(Service.Attributes) do
    begin
      FVM.GetObject(IDs).Elements[I] := TJVMValue.Int(Service.Attributes[I].ID);
      FVM.GetObject(Values).Elements[I] := TJVMValue.Ref(DecodeJ2MEBluetoothSDP(FVM, Service.Attributes[I].Data));
    end;
    O.Fields.AddOrSetValue('$bt.ids', TJVMValue.Ref(IDs));
    O.Fields.AddOrSetValue('$bt.values', TJVMValue.Ref(Values));
    FRecords.Add(Result, RecordValue);
    RecordValue := nil;
  finally
    RecordValue.Free;
  end;
end;

procedure TJ2MEBluetooth.Poll;
begin
  FTransport.Collect;
  for var Ref in FSelections.Keys.ToArray do
    if not FVM.HasNativeContinuation(Ref) then
      FSelections.Remove(Ref);
  for var Ref in FRecords.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FRecords.Remove(Ref);
  for var Ref in FNameQuery.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
    begin
      FNameQuery[Ref].Cancel;
      FNameQuery.Remove(Ref);
    end;
  for var I := FJobs.Count - 1 downto 0 do
  begin
    if FEvents.Count > 120 then
      Break;
    var J := FJobs[I];
    var State := TBluetoothOperationState.Pending;
    var Taken := 0;
    if J.Inquiry then
    begin
      var Observed := J.Devices.State;
      if not J.Cancelled then
        for var N := 1 to 4 do
        begin
          var Device: TBluetoothDevice;
          if not J.Devices.TryTakeDevice(Device) then
            Break;
          Inc(Taken);
          if (Device.Address.Value = FProvider.Info.Device.Address.Value) or J.Seen.ContainsKey(Device.Address.Value) then
            Continue;
          if J.Seen.Count >= 1024 then
          begin
            J.Devices.Cancel;
            State := TBluetoothOperationState.Failed;
            Break;
          end;
          J.Seen.Add(Device.Address.Value, 0);
          try
            var DeviceRef := Remote(Device);
            var ClassRef := DeviceClass(Device.ClassOfDevice);
            if (FCache.Count >= 256) and not FCache.ContainsKey(Device.Address.Value) then
              FCache.Remove(FCache.Keys.ToArray[0]);
            FCache.AddOrSetValue(Device.Address.Value, Device);
            Queue(J.ID, 'deviceDiscovered', '(Ljavax/bluetooth/DiscoveryListener;Ljavax/bluetooth/RemoteDevice;Ljavax/bluetooth/DeviceClass;)V',
              [TJVMValue.Ref(J.Listener), TJVMValue.Ref(DeviceRef), TJVMValue.Ref(ClassRef)]);
            Inc(J.Results);
          except
            on E: EArgumentException do
            begin
              J.Devices.Cancel;
              State := TBluetoothOperationState.Failed;
              Break;
            end;
            on E: EJVMThrown do
            begin
              J.Devices.Cancel;
              State := TBluetoothOperationState.Failed;
              Break;
            end;
          end;
        end;
      if State <> TBluetoothOperationState.Failed then
        State := Observed;
    end
    else
    begin
      var Observed := J.Services.State;
      if not J.Cancelled then
        for var N := 1 to 4 do
        begin
          var Service: TBluetoothService;
          if not J.Services.TryTakeService(Service) then
            Break;
          Inc(Taken);
          try
            var RecordRef := NewRecord(Service, 0);
            var Records := BTArray(FVM, '[Ljavax/bluetooth/ServiceRecord;', 1);
            FVM.GetObject(Records).Elements[0] := TJVMValue.Ref(RecordRef);
            Queue(J.ID, 'servicesDiscovered', '(Ljavax/bluetooth/DiscoveryListener;I[Ljavax/bluetooth/ServiceRecord;)V', [TJVMValue.Ref(J.Listener), TJVMValue.Int(J.ID), TJVMValue.Ref(Records)]);
            Inc(J.Results);
          except
            on E: EBluetoothSDP do
            begin
              J.Services.Cancel;
              State := TBluetoothOperationState.Failed;
              Break;
            end;
            on E: EJVMThrown do
            begin
              J.Services.Cancel;
              State := TBluetoothOperationState.Failed;
              Break;
            end;
          end;
        end;
      if State <> TBluetoothOperationState.Failed then
        State := Observed;
    end;
    // Allow a further poll after a full batch before publishing completion.
    if not J.Cancelled and (State = TBluetoothOperationState.Completed) and (Taken = 4) then
      Continue;
    if J.Cancelled then
      State := TBluetoothOperationState.Cancelled;
    if State = TBluetoothOperationState.Pending then
      Continue;
    var Code := 0;
    if J.Inquiry then
    begin
      if State = TBluetoothOperationState.Cancelled then
        Code := 5
      else if State = TBluetoothOperationState.Failed then
        Code := 7;
      Queue(J.ID, 'inquiryCompleted', '(Ljavax/bluetooth/DiscoveryListener;I)V', [TJVMValue.Ref(J.Listener), TJVMValue.Int(Code)]);
    end
    else
    begin
      Code := 1;
      if State = TBluetoothOperationState.Cancelled then
        Code := 2
      else if State = TBluetoothOperationState.Failed then
      begin
        Code := 3;
        if J.Services.Error.Code = TBluetoothErrorCode.Unreachable then
          Code := 6;
      end
      else if J.Results = 0 then
        Code := 4;
      Queue(J.ID, 'serviceSearchCompleted', '(Ljavax/bluetooth/DiscoveryListener;II)V', [TJVMValue.Ref(J.Listener), TJVMValue.Int(J.ID), TJVMValue.Int(Code)]);
    end;
    FVM.RemoveRoot(J.Listener);
    FJobs.Delete(I);
  end;
end;

function ConnectionURL(const E: TBluetoothEndpoint; Security: Integer; Master: Boolean): string;
begin
  if E.Channel = 0 then
    Exit('');
  Result := 'btspp://' + E.Device.ToString + ':' + IntToStr(E.Channel);
  if E.Transport = TBluetoothTransport.L2CAP then
    Result := 'btl2cap://' + E.Device.ToString + ':' + IntToHex(E.Channel, 4);
  Result := Result + ';authenticate=';
  if Security > 0 then
    Result := Result + 'true'
  else
    Result := Result + 'false';
  Result := Result + ';encrypt=';
  if Security = 2 then
    Result := Result + 'true'
  else
    Result := Result + 'false';
  Result := Result + ';master=';
  if Master then
    Result := Result + 'true'
  else
    Result := Result + 'false';
end;

function TJ2MEBluetooth.ServiceQueries: Integer;
begin
  Result := 0;
  for var J in FJobs do
    if not J.Inquiry then
      Inc(Result);
  for var W in FSelections.Values do
    if W.Services <> nil then
      Inc(Result);
end;

function TJ2MEBluetooth.Inquiring: Boolean;
begin
  for var J in FJobs do
    if J.Inquiry then
      Exit(True);
  for var W in FSelections.Values do
    if W.Devices <> nil then
      Exit(True);
  Result := False;
end;

function TJ2MEBluetooth.SelectService(const UUID: TBluetoothUUID; Security: Integer; Master: Boolean): TJVMValue;
var
  W: TJ2MEBluetoothSelection;

  procedure Failure(const Text: string);
  begin
    FVM.RaiseJava(BT + 'BluetoothStateException', Text);
  end;

  procedure Candidate(const D: TBluetoothDevice);
  begin
    if D.Address.Value > $FFFFFFFFFFFF then
      Failure('Invalid Bluetooth device address');
    if (D.Address.Value = FProvider.Info.Device.Address.Value) or W.Seen.ContainsKey(D.Address.Value) then
      Exit;
    if W.Seen.Count >= 1024 then
      Failure('Bluetooth selection device capacity');
    W.Seen.Add(D.Address.Value, 0);
    W.Candidates := W.Candidates + [D];
  end;

  function MatchingURL(const Service: TBluetoothService): string;
  begin
    Result := '';
    if Service.Endpoint.Device.Value <> W.Target.Value then
      Failure('SDP result belongs to another device');
    // Decode the complete bounded record, then inspect only ServiceClassIDList.
    // A UUID occurring in ProtocolDescriptorList or another attribute is not a match.
    var Decoded := DecodeBluetoothService(EncodeBluetoothService(Service), W.Target);
    var Match := False;
    for var A in Service.Attributes do
      if A.ID = 1 then
      begin
        var E := DecodeBluetoothSDP(A.Data);
        try
          if E.Kind <> TBluetoothSDPKind.Sequence then
            raise EBluetoothSDP.Create('Invalid service class list');
          for var C in E.Children do
          begin
            if C.Kind <> TBluetoothSDPKind.UUID then
              raise EBluetoothSDP.Create('Invalid service class UUID');
            var Text := '';
            for var B in C.Data do
              Text := Text + IntToHex(B, 2);
            var U: TBluetoothUUID;
            if not TBluetoothUUID.TryParse(Text, U) then
              raise EBluetoothSDP.Create('Invalid service class UUID');
            if IsEqualGUID(U.Value, W.UUID.Value) then
              Match := True;
          end;
        finally
          E.Free;
        end;
      end;
    // Higher protocols such as OBEX require a different GCF scheme. Until that
    // translator exists, do not misidentify such a service as a raw byte stream.
    for var A in Service.Attributes do
      if A.ID = 4 then
      begin
        var E := DecodeBluetoothSDP(A.Data);
        try
          for var P in E.Children do
          begin
            var Text := '';
            for var B in P.Children[0].Data do
              Text := Text + IntToHex(B, 2);
            var U: TBluetoothUUID;
            if not TBluetoothUUID.TryParse(Text, U) then
              raise EBluetoothSDP.Create('Invalid protocol UUID');
            if (U.ToString <> '0000010000001000800000805F9B34FB') and
              (U.ToString <> '0000000300001000800000805F9B34FB') then
              Exit;
          end;
        finally
          E.Free;
        end;
      end;
    if not Match or (Decoded.Endpoint.Channel = 0) then
      Exit;
    if (Decoded.Endpoint.Transport <> Service.Endpoint.Transport) or (Decoded.Endpoint.Channel <> Service.Endpoint.Channel) then
      Failure('SDP transport does not match provider endpoint');
    var E := Decoded.Endpoint;
    if (E.Transport = TBluetoothTransport.L2CAP) and ((E.Channel < 5) or ((E.Channel and $0101) <> 1)) then
      Failure('Invalid Classic L2CAP PSM');
    Result := ConnectionURL(E, W.Security, W.Master);
  end;

begin
  Result := TJVMValue.Ref(0);
  W := nil;
  var V := FVM.NativeContinuation;
  if V.Kind = TJVMKind.Reference then
    FSelections.TryGetValue(V.AsRef, W);
  if W = nil then
  begin
    if FSelections.Count >= 4 then
      Failure('Concurrent Bluetooth selection capacity');
    W := TJ2MEBluetoothSelection.Create;
    try
      W.Ref := FVM.NewObject(SelectionClass);
      W.UUID := UUID;
      W.Security := Security;
      W.Master := Master;
      FSelections.Add(W.Ref, W);
    except
      W.Free;
      raise;
    end;
    FVM.SetNativeContinuation(TJVMValue.Ref(W.Ref));
    // Candidate initialization is inside the cleanup guard below.
  end;
  try
    if FVM.ClearInterrupted then
      Failure('Bluetooth service selection interrupted');
    Ready;
    if not W.Initialized then
    begin
      W.Initialized := True;
      var Known := FProvider.KnownDevices;
      for var D in Known do
        if D.Paired then
          Candidate(D);
      for var D in FCache.Values do
        Candidate(D);
      for var D in Known do
        Candidate(D);
    end;
    // Bound each visit so even synchronously completed providers yield the VM.
    for var Step := 1 to 8 do
    begin
      if W.Services <> nil then
      begin
        // Observe terminal state before draining: completion may publish a final
        // result after an empty read. A Pending snapshot requires another poll.
        var State := W.Services.State;
        var Service: TBluetoothService;
        if W.Services.TryTakeService(Service) then
        begin
          Inc(W.Results);
          if W.Results > 1024 then
            Failure('Bluetooth selection service capacity');
          var URL := MatchingURL(Service);
          if URL <> '' then
          begin
            Result := TJVMValue.Ref(FVM.NewString(URL));
            FSelections.Remove(W.Ref);
            FVM.SetNativeContinuation(Default(TJVMValue));
            Exit;
          end;
          Continue;
        end;
        if State = TBluetoothOperationState.Pending then
          Break;
        if State = TBluetoothOperationState.Cancelled then
          Failure('Bluetooth service search cancelled');
        if (State = TBluetoothOperationState.Failed) and not (W.Services.Error.Code in
          [TBluetoothErrorCode.Unreachable, TBluetoothErrorCode.Timeout, TBluetoothErrorCode.IOFailure]) then
          Failure(W.Services.Error.MessageText);
        W.Services := nil;
        Continue;
      end;
      if W.Devices <> nil then
      begin
        var State := W.Devices.State;
        var D: TBluetoothDevice;
        if W.Devices.TryTakeDevice(D) then
        begin
          Candidate(D);
          if D.Address.Value <> FProvider.Info.Device.Address.Value then
          begin
            if (FCache.Count >= 256) and not FCache.ContainsKey(D.Address.Value) then
              FCache.Remove(FCache.Keys.ToArray[0]);
            FCache.AddOrSetValue(D.Address.Value, D);
          end;
          Continue;
        end;
        if State = TBluetoothOperationState.Pending then
          Break;
        if State <> TBluetoothOperationState.Completed then
          Failure(W.Devices.Error.MessageText);
        W.Devices := nil;
        Continue;
      end;
      if W.Index < Length(W.Candidates) then
      begin
        if ServiceQueries >= 4 then
          Failure('Concurrent SDP query capacity');
        W.Target := W.Candidates[W.Index].Address;
        Inc(W.Index);
        W.Services := FProvider.FindServices(W.Target, [W.UUID], [0, 1, 2, 3, 4]);
        if W.Services = nil then
          Failure('Bluetooth provider returned no service query');
        Continue;
      end;
      if W.Inquired then
      begin
        FSelections.Remove(W.Ref);
        FVM.SetNativeContinuation(Default(TJVMValue));
        Exit;
      end;
      if Inquiring then
        Failure('Bluetooth inquiry already active');
      var Control: IBluetoothClassicControl;
      if Supports(FProvider, IBluetoothClassicControl, Control) then
        W.Devices := Control.Inquiry(GIAC, 10000)
      else
        W.Devices := FProvider.Discover(10000);
      if W.Devices = nil then
        Failure('Bluetooth provider returned no inquiry');
      W.Inquired := True;
    end;
    FVM.SleepCurrent(1, BT + 'BluetoothStateException', True);
    FVM.RetryNative;
  except
    on E: EBluetoothSDP do
    begin
      FSelections.Remove(W.Ref);
      FVM.SetNativeContinuation(Default(TJVMValue));
      Failure(E.Message);
    end;
    else
      begin
        FSelections.Remove(W.Ref);
        FVM.SetNativeContinuation(Default(TJVMValue));
        raise;
      end;
  end;
end;

function TJ2MEBluetooth.InvokeRecord(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := FVM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  var R: TJ2MEBluetoothRecord;
  if not FRecords.TryGetValue(Args[0].AsRef, R) then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Bluetooth service record released');
  var IDs := FVM.GetObject(GetRef(O, '$bt.ids'));
  var Values := FVM.GetObject(GetRef(O, '$bt.values'));
  if N = 'getHostDevice' then
    Exit(TJVMValue.Ref(GetRef(O, '$bt.host')));
  if N = 'getAttributeIDs' then
    Exit(TJVMValue.Ref(FVM.CloneObject(GetRef(O, '$bt.ids'))));
  if N = 'getConnectionURL' then
  begin
    var Security := Args[1].AsInt;
    if not (Security in [0..2]) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth security');
    var URL := ConnectionURL(R.Info.Endpoint, Security, Args[2].AsInt <> 0);
    if URL = '' then
      Exit(TJVMValue.Ref(0));
    Exit(TJVMValue.Ref(FVM.NewString(URL)));
  end;
  if N = 'setDeviceServiceClasses' then
  begin
    if R.Origin = 0 then
      FVM.RaiseJava('java/lang/RuntimeException', 'Remote service record');
    if (UInt32(Args[1].AsInt) and $FF003FFF) <> 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth service class bits');
    O.Fields.AddOrSetValue('$bt.classes', Args[1]);
    Exit;
  end;
  if (N = 'getAttributeValue') or (N = 'setAttributeValue') then
  begin
    var ID := Args[1].AsInt;
    if (ID < 0) or (ID > 65535) or ((N = 'setAttributeValue') and (ID = 0)) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'SDP attribute ID');
    var Index := -1;
    for var I := 0 to High(IDs.Elements) do
      if IDs.Elements[I].AsInt = ID then
      begin
        Index := I;
        Break;
      end;
    if N = 'getAttributeValue' then
    begin
      if Index < 0 then
        Exit(TJVMValue.Ref(0));
      Exit(TJVMValue.Ref(CopyJ2MEBluetoothData(FVM, Values.Elements[Index].AsRef)));
    end;
    if R.Origin = 0 then
      FVM.RaiseJava('java/lang/RuntimeException', 'Remote service record cannot be updated');
    var Value := Args[2].AsRef;
    if (Index < 0) and (Value = 0) then
      Exit(TJVMValue.Int(0));
    if Value <> 0 then
      Value := CopyJ2MEBluetoothData(FVM, Value);
    var Count := Length(IDs.Elements);
    if Index < 0 then
      Inc(Count)
    else if Value = 0 then
      Dec(Count);
    if Count > 256 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'SDP attribute capacity');
    var NewIDs := BTArray(FVM, '[I', Count);
    var NewValues := BTArray(FVM, '[Ljavax/bluetooth/DataElement;', Count);
    var Target := 0;
    for var I := 0 to High(IDs.Elements) do
    begin
      if (I = Index) and (Value = 0) then
        Continue;
      FVM.GetObject(NewIDs).Elements[Target] := IDs.Elements[I];
      if I = Index then
        FVM.GetObject(NewValues).Elements[Target] := TJVMValue.Ref(Value)
      else
        FVM.GetObject(NewValues).Elements[Target] := Values.Elements[I];
      Inc(Target);
    end;
    if Index < 0 then
    begin
      FVM.GetObject(NewIDs).Elements[Target] := TJVMValue.Int(ID);
      FVM.GetObject(NewValues).Elements[Target] := TJVMValue.Ref(Value);
    end;
    O.Fields.AddOrSetValue('$bt.ids', TJVMValue.Ref(NewIDs));
    O.Fields.AddOrSetValue('$bt.values', TJVMValue.Ref(NewValues));
    Exit(TJVMValue.Int(1));
  end;
  if N = 'populateRecord' then
  begin
    var ArrayValue := FVM.GetObject(Args[1].AsRef);
    if R.Origin <> 0 then
      FVM.RaiseJava('java/lang/RuntimeException', 'Local service record cannot be populated');
    if (Length(ArrayValue.Elements) = 0) or (Length(ArrayValue.Elements) > 256) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'SDP attribute count');
    var Requested: TArray<Word>;
    SetLength(Requested, Length(ArrayValue.Elements));
    for var I := 0 to High(Requested) do
    begin
      var ID := ArrayValue.Elements[I].AsInt;
      if (ID < 0) or (ID > 65535) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'SDP attribute ID');
      for var J := 0 to I - 1 do
        if Requested[J] = ID then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Duplicate SDP attribute');
      Requested[I] := ID;
    end;
    if FVM.ClearInterrupted then
    begin
      if R.Populate <> nil then
        R.Populate.Cancel;
      R.Populate := nil;
      FVM.RaiseJava('java/io/InterruptedIOException', 'Bluetooth SDP query interrupted');
    end;
    if R.Populate = nil then
    begin
      R.Requested := Requested;
      R.Populate := FProvider.FindServices(R.Info.Endpoint.Device, R.Info.UUIDs, Requested);
    end;
    if R.Populate = nil then
      FVM.RaiseJava('java/io/IOException', 'Bluetooth provider did not return a query');
    if R.Populate.State = TBluetoothOperationState.Pending then
    begin
      FVM.SleepCurrent(1, 'java/io/InterruptedIOException', True);
      FVM.RetryNative;
      Exit;
    end;
    if R.Populate.State <> TBluetoothOperationState.Completed then
    begin
      var Error := R.Populate.Error;
      R.Populate := nil;
      FVM.RaiseJava('java/io/IOException', Error.MessageText);
    end;
    // A full population update must match this record's transport endpoint.
    var Service: TBluetoothService;
    var Matched := False;
    while R.Populate.TryTakeService(Service) do
      if (Service.Endpoint.Device.Value = R.Info.Endpoint.Device.Value) and
        (Service.Endpoint.Transport = R.Info.Endpoint.Transport) and (Service.Endpoint.Channel = R.Info.Endpoint.Channel) then
      begin
        Matched := True;
        Break;
      end;
    R.Populate := nil;
    if not Matched then
      Exit(TJVMValue.Int(0));
    var Retained: TArray<TBluetoothAttribute>;
    var Found := False;
    for var A in R.Info.Attributes do
    begin
      var WasRequested := False;
      for var ID in R.Requested do
        if A.ID = ID then
          WasRequested := True;
      if not WasRequested then
        Retained := Retained + [A];
    end;
    for var A in Service.Attributes do
      for var ID in R.Requested do
        if A.ID = ID then
        begin
          Retained := Retained + [A];
          Found := True;
          Break;
        end;
    var Updated := Service;
    Updated.Attributes := Retained;
    var Temp := NewRecord(Updated, 0);
    var TempObject := FVM.GetObject(Temp);
    O.Fields.AddOrSetValue('$bt.ids', TempObject.Fields['$bt.ids']);
    O.Fields.AddOrSetValue('$bt.values', TempObject.Fields['$bt.values']);
    R.Info.Attributes := Retained;
    FRecords.Remove(Temp);
    R.Requested := nil;
    Exit(TJVMValue.Int(Ord(Found)));
  end;
  raise EJVMUnsupported.Create('Bluetooth service record: ' + N);
end;

function TJ2MEBluetooth.ExportRecord(Ref: Integer): TBluetoothService;

  procedure CollectUUIDs(E: TBluetoothSDPElement);
  begin
    if E.Kind = TBluetoothSDPKind.UUID then
    begin
      var Hex := '';
      for var B in E.Data do
        Hex := Hex + IntToHex(B, 2);
      var U: TBluetoothUUID;
      if not TBluetoothUUID.TryParse(Hex, U) then
        raise EBluetoothSDP.Create('SDP UUID');
      for var Existing in Result.UUIDs do
        if Existing.ToString = U.ToString then
          Exit;
      Result.UUIDs := Result.UUIDs + [U];
    end;
    for var Child in E.Children do
      CollectUUIDs(Child);
  end;

begin
  var R: TJ2MEBluetoothRecord;
  if not FRecords.TryGetValue(Ref, R) or (R.Origin = 0) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Foreign Bluetooth record');
  Result := R.Info;
  Result.Attributes := nil;
  Result.UUIDs := nil;
  Result.Name := '';
  var O := FVM.GetObject(Ref);
  var IDs := FVM.GetObject(GetRef(O, '$bt.ids'));
  var Values := FVM.GetObject(GetRef(O, '$bt.values'));
  var ClassList := False;
  var Protocol := False;
  var Total := Int64(0);
  try
    for var I := 0 to High(IDs.Elements) do
    begin
      var A: TBluetoothAttribute;
      A.ID := IDs.Elements[I].AsInt;
      A.Data := EncodeJ2MEBluetoothSDP(FVM, Values.Elements[I].AsRef);
      Inc(Total, Length(A.Data));
      if Total > BLUETOOTH_SDP_MAX_BYTES then
        raise EBluetoothSDP.Create('Excessive Bluetooth service record');
      var Element := DecodeBluetoothSDP(A.Data);
      try
        CollectUUIDs(Element);
        if (A.ID = $100) and (Element.Kind = TBluetoothSDPKind.TextString) then
          Result.Name := TEncoding.UTF8.GetString(Element.Data);
      finally
        Element.Free;
      end;
      if A.ID = 1 then
      begin
        var E := DecodeBluetoothSDP(A.Data);
        try
          if E.Kind <> TBluetoothSDPKind.Sequence then
            raise EBluetoothSDP.Create('ServiceClassIDList must be a sequence');
          for var Child in E.Children do
          begin
            if Child.Kind <> TBluetoothSDPKind.UUID then
              raise EBluetoothSDP.Create('Service class must be UUID');
          end;
          ClassList := E.Children.Count <> 0;
        finally
          E.Free;
        end;
      end;
      if A.ID = 4 then
        for var Original in R.Info.Attributes do
          if Original.ID = 4 then
          begin
        // The Java DataElement codec canonicalizes short UUIDs to128 bits.
        // Compare canonical encodings, preserving the bound channel/PSM value.
            var Canonical := EncodeJ2MEBluetoothSDP(FVM, DecodeJ2MEBluetoothSDP(FVM, Original.Data));
            Protocol := Length(A.Data) = Length(Canonical);
            if Protocol then
              for var J := 0 to High(A.Data) do
                if A.Data[J] <> Canonical[J] then
                begin
                  Protocol := False;
                  Break;
                end;
          end;
      Result.Attributes := Result.Attributes + [A];
    end;
    if not ClassList or not Protocol then
      raise EBluetoothSDP.Create('Missing service class or changed transport descriptor');
  except
    on E: EBluetoothSDP do
      FVM.RaiseJava('java/lang/IllegalArgumentException', E.Message);
  end;
end;

function TJ2MEBluetooth.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

  function Text(Index: Integer): string;
  begin
    Result := FVM.GetObject(Args[Index].AsRef).Text;
  end;

  function StringValue(const Value: string): TJVMValue;
  begin
    Result := TJVMValue.Ref(FVM.NewString(Value));
  end;

  procedure Wait;
  begin
    FVM.SleepCurrent(1, 'java/io/InterruptedIOException', True);
    FVM.RetryNative;
  end;

  function Address(Ref: Integer): TBluetoothAddress;
  begin
    if not TBluetoothAddress.TryParse(FVM.GetObject(Ref).Text, Result) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth address');
  end;

begin
  if FTransport.Handles(Method.Owner.Name) then
    Exit(FTransport.Invoke(Method, Args));
  Result := Default(TJVMValue);
  var Owner := Method.Owner.Name;
  var N := Method.Name;
  if Owner = RecordName then
  begin
    try
      Exit(InvokeRecord(Method, Args));
    except
      on E: EBluetoothSDP do
        FVM.RaiseJava('java/lang/IllegalArgumentException', E.Message);
    end;
  end;
  if Owner = local then
  begin
    if N = 'isPowerOn' then
      Exit(TJVMValue.Int(Ord(FProvider.Info.State = TBluetoothState.Ready)));
    if N = 'getProperty' then
    begin
      var Key := Text(0);
      var Value := '';
      if Key = 'bluetooth.api.version' then
        Value := '1.1'
      else if Key = 'bluetooth.sd.trans.max' then
        Value := '4'
      else if Key = 'bluetooth.sd.attr.retrievable.max' then
        Value := '256'
      else if (Key = 'bluetooth.l2cap.receiveMTU.max') or (Key = 'bluetooth.l2cap.supported') then
      begin
        var Caps := FProvider.Info.Capabilities;
        var L2CAP := (TBluetoothCapability.L2CAPClient in Caps) or (TBluetoothCapability.L2CAPServer in Caps);
        if Key = 'bluetooth.l2cap.receiveMTU.max' then
        begin
          if L2CAP then
            Value := '65535';
        end
        else if L2CAP then
          Value := 'true'
        else
          Value := 'false';
      end
      else if Key = 'bluetooth.connected.devices.max' then
        Value := '32';
      if Value = '' then
        Exit(TJVMValue.Ref(0));
      Exit(StringValue(Value));
    end;
    if N = 'getLocalDevice' then
    begin
      Ready;
      var F := FVM.LoadClass(local).Fields[0];
      if F.Value.AsRef = 0 then
      begin
        var LocalRef := FVM.NewObject(local);
        var AgentRef := FVM.NewObject(Agent);
        var ObjectValue := FVM.GetObject(LocalRef);
        ObjectValue.Fields.AddOrSetValue('$bt.agent', TJVMValue.Ref(AgentRef));
        ObjectValue.Fields.AddOrSetValue('$bt.address', StringValue(FProvider.Info.Device.Address.ToString));
        ObjectValue.Fields.AddOrSetValue('$bt.name', StringValue(FProvider.Info.Device.Name));
        ObjectValue.Fields.AddOrSetValue('$bt.class', TJVMValue.Ref(DeviceClass(FProvider.Info.Device.ClassOfDevice)));
        F.Value := TJVMValue.Ref(LocalRef);
      end;
      Exit(F.Value);
    end;
    var O := FVM.GetObject(Args[0].AsRef);
    if N = 'getDiscoveryAgent' then
      Exit(TJVMValue.Ref(GetRef(O, '$bt.agent')));
    if N = 'getBluetoothAddress' then
      Exit(O.Fields['$bt.address']);
    if N = 'getFriendlyName' then
      Exit(O.Fields['$bt.name']);
    if N = 'getDeviceClass' then
      Exit(TJVMValue.Ref(DeviceClass(FProvider.Info.Device.ClassOfDevice)));
    if N = 'getDiscoverable' then
    begin
      if FProvider.Info.State <> TBluetoothState.Ready then
        Exit(TJVMValue.Int(0));
      Exit(TJVMValue.Int(Integer(FProvider.Info.DiscoverableCode)));
    end;
    if N = 'setDiscoverable' then
    begin
      var Mode := Args[1].AsInt;
      if (Mode <> 0) and ((Mode < $9E8B00) or (Mode > $9E8B3F)) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Inquiry access code');
      Ready;
      if FVM.ClearInterrupted then
      begin
        if FDiscoverable <> nil then
          FDiscoverable.Cancel;
        FDiscoverable := nil;
        FVM.RaiseJava(BT + 'BluetoothStateException', 'Discoverability interrupted');
      end;
      if FDiscoverable = nil then
      begin
        var Control: IBluetoothClassicControl;
        if Supports(FProvider, IBluetoothClassicControl, Control) then
          FDiscoverable := Control.SetDiscoverability(Mode)
        else if (Mode = 0) or (Mode = GIAC) then
          FDiscoverable := FProvider.SetDiscoverable(Mode <> 0)
        else
          Exit(TJVMValue.Int(0));
      end;
      if FDiscoverable = nil then
        FVM.RaiseJava(BT + 'BluetoothStateException', 'Bluetooth provider did not return a control operation');
      if FDiscoverable.State = TBluetoothOperationState.Pending then
      begin
        Wait;
        Exit;
      end;
      var OK := FDiscoverable.State = TBluetoothOperationState.Completed;
      var Error := FDiscoverable.Error;
      FDiscoverable := nil;
      if not OK and (Error.Code <> TBluetoothErrorCode.Unsupported) then
        FVM.RaiseJava(BT + 'BluetoothStateException', Error.MessageText);
      Exit(TJVMValue.Int(Ord(OK)));
    end;
    if N = 'getRecord' then
    begin
      FVM.GetObject(Args[1].AsRef);
      var Service: TBluetoothService;
      var RecordRef: Integer;
      if not FTransport.LocalService(Args[1].AsRef, Service, RecordRef) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Not an open Bluetooth service notifier');
      if RecordRef = 0 then
      begin
        RecordRef := NewRecord(Service, Args[1].AsRef);
        FTransport.AssignRecord(Args[1].AsRef, RecordRef);
      end;
      Exit(TJVMValue.Ref(RecordRef));
    end;
    if N = 'updateRecord' then
    begin
      FVM.GetObject(Args[1].AsRef);
      var R: TJ2MEBluetoothRecord;
      if not FRecords.TryGetValue(Args[1].AsRef, R) or (R.Origin = 0) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Not a local Bluetooth service record');
      FTransport.Publish(R.Origin);
      Exit;
    end;
  end;
  if Owner = RemoteName then
  begin
    if N = 'getRemoteDevice' then
    begin
      FVM.GetObject(Args[0].AsRef);
      var Info: TBluetoothChannelInfo;
      var Server: Boolean;
      if not FTransport.RemoteInfo(Args[0].AsRef, Info, Server) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Not a Bluetooth connection');
      var D := Default(TBluetoothDevice);
      D.Address := Info.Endpoint.Device;
      for var Known in FProvider.KnownDevices do
        if Known.Address.Value = D.Address.Value then
        begin
          D := Known;
          Break;
        end;
      Exit(TJVMValue.Ref(Remote(D)));
    end;
    var O := FVM.GetObject(Args[0].AsRef);
    if N = '<init>' then
    begin
      var Value := Text(1);
      var A: TBluetoothAddress;
      if (Length(Value) <> 12) or not TBluetoothAddress.TryParse(Value, A) or (A.Value = FProvider.Info.Device.Address.Value) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth remote address');
      O.Text := A.ToString;
      Exit;
    end;
    if N = 'getBluetoothAddress' then
      Exit(StringValue(O.Text));
    if N = 'equals' then
    begin
      var Other := Args[1].AsRef;
      Exit(TJVMValue.Int(Ord((Other <> 0) and FVM.IsAssignable(FVM.GetObject(Other).ClassName, RemoteName) and (FVM.GetObject(Other).Text = O.Text))));
    end;
    if N = 'hashCode' then
    begin
      var A := Address(Args[0].AsRef);
      Exit(TJVMValue.Int(Integer(A.Value xor (A.Value shr 32))));
    end;
    if N = 'getFriendlyName' then
    begin
      if Args[1].AsInt = 0 then
      begin
        var R := GetRef(O, '$bt.name');
        if R <> 0 then
          Exit(TJVMValue.Ref(R));
      end;
      var Control: IBluetoothClassicControl;
      if not Supports(FProvider, IBluetoothClassicControl, Control) then
        FVM.RaiseJava('java/io/IOException', 'Bluetooth provider cannot refresh remote names');
      var Query: IBluetoothDeviceQuery;
      if not FNameQuery.TryGetValue(Args[0].AsRef, Query) then
      begin
        if FNameQuery.Count >= 32 then
          FVM.RaiseJava('java/io/IOException', 'Bluetooth name-query capacity');
        Query := Control.QueryDevice(Address(Args[0].AsRef), Args[1].AsInt <> 0);
        if Query = nil then
          FVM.RaiseJava('java/io/IOException', 'Bluetooth name query unavailable');
        FNameQuery.Add(Args[0].AsRef, Query);
      end;
      if FVM.ClearInterrupted then
      begin
        Query.Cancel;
        FNameQuery.Remove(Args[0].AsRef);
        FVM.RaiseJava('java/io/InterruptedIOException', 'Bluetooth name query interrupted');
      end;
      if Query.State = TBluetoothOperationState.Pending then
      begin
        Wait;
        Exit;
      end;
      FNameQuery.Remove(Args[0].AsRef);
      if Query.State <> TBluetoothOperationState.Completed then
        FVM.RaiseJava('java/io/IOException', Query.Error.MessageText);
      var Device := Query.Device;
      if Device.Address.Value <> Address(Args[0].AsRef).Value then
        FVM.RaiseJava('java/io/IOException', 'Bluetooth query returned another device');
      if FCache.ContainsKey(Device.Address.Value) then
        FCache.AddOrSetValue(Device.Address.Value, Device);
      O.Fields.AddOrSetValue('$bt.name', StringValue(Device.Name));
      O.Fields.AddOrSetValue('$bt.trusted', TJVMValue.Int(Ord(Device.Trusted)));
      Exit(O.Fields['$bt.name']);
    end;
    if N = 'isTrustedDevice' then
      Exit(TJVMValue.Int(GetInt(O, '$bt.trusted')));
    if (N = 'isAuthenticated') or (N = 'isEncrypted') then
    begin
      var Security := TBluetoothSecurity.Authenticated;
      if N = 'isEncrypted' then
        Security := TBluetoothSecurity.Encrypted;
      Exit(TJVMValue.Int(Ord(FTransport.HasSecurity(Address(Args[0].AsRef), Security))));
    end;
    if (N = 'authenticate') or (N = 'authorize') or (N = 'isAuthorized') or (N = 'encrypt') then
    begin
      var A := Address(Args[0].AsRef);
      var Ref := FTransport.ConnectionFor(A);
      var Server: Boolean;
      var Info: TBluetoothChannelInfo;
      if N <> 'authenticate' then
      begin
        FVM.GetObject(Args[1].AsRef);
        Ref := Args[1].AsRef;
        if not FTransport.RemoteInfo(Ref, Info, Server) or (Info.Endpoint.Device.Value <> A.Value) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Connection belongs to another remote device');
        if (N = 'authorize') and not Server then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Authorization requires a server connection');
        if N = 'isAuthorized' then
          Exit(TJVMValue.Int(Ord(Server and (TBluetoothSecurity.Authorized in Info.Security))));
      end;
      if Ref = 0 then
        FVM.RaiseJava('java/io/IOException', 'No active Bluetooth connection');
      var Security := TBluetoothSecurity.Authenticated;
      if N = 'authorize' then
        Security := TBluetoothSecurity.Authorized
      else if N = 'encrypt' then
        Security := TBluetoothSecurity.Encrypted;
      var Enabled := True;
      if N = 'encrypt' then
        Enabled := Args[2].AsInt <> 0;
      Exit(TJVMValue.Int(Ord(FTransport.SetSecurity(Ref, Security, Enabled))));
    end;
    FVM.RaiseJava('java/io/IOException', 'No active Bluetooth security-capable connection');
  end;
  if Owner = Agent then
  begin
    FVM.GetObject(Args[0].AsRef);
    if N = 'retrieveDevices' then
    begin
      var Option := Args[1].AsInt;
      if not (Option in [0, 1]) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth device-cache option');
      var Devices: TArray<TBluetoothDevice> := nil;
      if Option = 0 then
      begin
        for var D in FCache.Values do
          Devices := Devices + [D];
      end
      else
        for var D in FProvider.KnownDevices do
          if D.Paired then
            Devices := Devices + [D];
      if Length(Devices) = 0 then
        Exit(TJVMValue.Ref(0));
      if Length(Devices) > 256 then
        SetLength(Devices, 256);
      var A := BTArray(FVM, '[Ljavax/bluetooth/RemoteDevice;', Length(Devices));
      for var I := 0 to High(Devices) do
        FVM.GetObject(A).Elements[I] := TJVMValue.Ref(Remote(Devices[I]));
      Exit(TJVMValue.Ref(A));
    end;
    if N = 'cancelInquiry' then
    begin
      var Ref := Args[1].AsRef;
      FVM.GetObject(Ref);
      for var J in FJobs do
        if J.Inquiry and not J.Cancelled and (J.Listener = Ref) then
        begin
          J.Cancelled := True;
          J.Devices.Cancel;
          Discard(J.ID);
          Exit(TJVMValue.Int(1));
        end;
      Exit(TJVMValue.Int(0));
    end;
    if N = 'cancelServiceSearch' then
    begin
      for var J in FJobs do
        if not J.Inquiry and not J.Cancelled and (J.ID = Args[1].AsInt) then
        begin
          J.Cancelled := True;
          J.Services.Cancel;
          Discard(J.ID);
          Exit(TJVMValue.Int(1));
        end;
      Exit(TJVMValue.Int(0));
    end;
    if (N = 'startInquiry') or (N = 'searchServices') then
    begin
      var Inquiry := N = 'startInquiry';
      var ListenerRef := Args[High(Args)].AsRef;
      FVM.GetObject(ListenerRef);
      var UUIDs: TArray<TBluetoothUUID> := nil;
      var Attributes: TArray<Word> := nil;
      var Device: TBluetoothAddress;
      Device := Default(TBluetoothAddress);
      if Inquiry then
      begin
        var Code := Args[1].AsInt;
        if (Code < $9E8B00) or (Code > $9E8B3F) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Inquiry access code');
        if Inquiring then
          Exit(TJVMValue.Int(0));
      end
      else
      begin
        var A := FVM.GetObject(Args[2].AsRef);
        if (Length(A.Elements) < 1) or (Length(A.Elements) > 12) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth UUID search count');
        for var V in A.Elements do
        begin
          var U := J2MEBluetoothUUID(FVM, V.AsRef);
          var Duplicate := False;
          for var Existing in UUIDs do
            if IsEqualGUID(Existing.Value, U.Value) then
              Duplicate := True;
          if not Duplicate then
            UUIDs := UUIDs + [U];
        end;
        Device := Address(Args[3].AsRef);
        Attributes := [0, 1, 2, 3, 4];
        if Args[1].AsRef <> 0 then
        begin
          A := FVM.GetObject(Args[1].AsRef);
          if (Length(A.Elements) < 1) or (Length(A.Elements) > 256) then
            FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth attribute search count');
          for var I := 0 to High(A.Elements) do
          begin
            var ID := A.Elements[I].AsInt;
            if (ID < 0) or (ID > 65535) then
              FVM.RaiseJava('java/lang/IllegalArgumentException', 'SDP attribute ID');
            for var J := 0 to I - 1 do
              if A.Elements[J].AsInt = ID then
                FVM.RaiseJava('java/lang/IllegalArgumentException', 'Duplicate SDP attribute');
            if ID > 4 then
              Attributes := Attributes + [Word(ID)];
          end;
          if Length(Attributes) > 256 then
            FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth extended attribute count');
        end;
        if ServiceQueries >= 4 then
          FVM.RaiseJava(BT + 'BluetoothStateException', 'Concurrent SDP query capacity');
      end;
      Ready;
      if FNextID = MaxInt then
        FVM.RaiseJava(BT + 'BluetoothStateException', 'Bluetooth transaction IDs exhausted');
      var J := TJ2MEBluetoothSearch.Create;
      try
        J.Inquiry := Inquiry;
        J.Listener := ListenerRef;
        J.ID := FNextID;
        Inc(FNextID);
        if Inquiry then
        begin
          var Control: IBluetoothClassicControl;
          if Supports(FProvider, IBluetoothClassicControl, Control) then
            J.Devices := Control.Inquiry(Args[1].AsInt, 10000)
          else if Args[1].AsInt = GIAC then
            J.Devices := FProvider.Discover(10000)
          else
            FVM.RaiseJava(BT + 'BluetoothStateException', 'Provider cannot select inquiry access code');
          if J.Devices = nil then
            FVM.RaiseJava(BT + 'BluetoothStateException', 'Bluetooth discovery unavailable');
          if J.Devices.State = TBluetoothOperationState.Failed then
            FVM.RaiseJava(BT + 'BluetoothStateException', J.Devices.Error.MessageText);
          Result := TJVMValue.Int(1);
        end
        else
        begin
          J.Services := FProvider.FindServices(Device, UUIDs, Attributes);
          if J.Services = nil then
            FVM.RaiseJava(BT + 'BluetoothStateException', 'Bluetooth SDP search unavailable');
          Result := TJVMValue.Int(J.ID);
        end;
        FVM.AddRoot(J.Listener);
        FJobs.Add(J);
        J := nil;
      finally
        J.Free;
      end;
      Exit;
    end;
    if N = 'selectService' then
    begin
      var UUID := J2MEBluetoothUUID(FVM, Args[1].AsRef);
      if not (Args[2].AsInt in [0..2]) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth security');
      Exit(SelectService(UUID, Args[2].AsInt, Args[3].AsInt <> 0));
    end;
  end;
  raise EJVMUnsupported.Create('Bluetooth API: ' + Owner + '.' + N);
end;

end.

