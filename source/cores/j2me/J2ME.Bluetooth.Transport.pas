unit J2ME.Bluetooth.Transport;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Runtime, Core.Bluetooth.Types;

type
  TBTConnection = class
    Ref, Mode, InputRef, OutputRef, RecordRef, Position: Integer;
    Closed, InputOpened, OutputOpened, PacketReady, EOF, Server, Advertised: Boolean;
    Options: TBluetoothConnectOptions;
    Service: TBluetoothService;
    Channel: IBluetoothChannel;
    Listener: IBluetoothListener;
    Buffer: TBytes;
    destructor Destroy; override;
  end;

  TBTWork = class
    Ref, Connection, Position: Integer;
    Started: Int64;
    Data: TBytes;
    Operation: IBluetoothOperation;
    Connect: IBluetoothConnect;
    Listen: IBluetoothListen;
    Service: TBluetoothService;
    Options: TBluetoothConnectOptions;
    Server, Timeouts: Boolean;
    destructor Destroy; override;
  end;

  TJ2MEBluetoothTransport = class
  private
    FVM: TJVM;
    FProvider: IBluetoothProvider;
    FStopped: Boolean;
    FConnections: TObjectDictionary<Integer, TBTConnection>;
    FWork: TObjectDictionary<Integer, TBTWork>;
    FExport: TFunc<Integer, TBluetoothService>;
    function Work: TBTWork;
    procedure Wait(W: TBTWork);
    procedure Interrupt(W: TBTWork);
    procedure IOError(const Text: string; Transferred: Integer = 0);
    procedure Failure(const E: TBluetoothError; Connecting: Boolean = False);
    procedure Close(C: TBTConnection; Force: Boolean = False);
    function Attach(const Channel: IBluetoothChannel; Mode: Integer; const Options: TBluetoothConnectOptions; Server: Boolean): Integer;
    function Prefetch(C: TBTConnection): Boolean;
    procedure Validate(C: TBTConnection);
  public
    constructor Create(VM: TJVM; const Provider: IBluetoothProvider);
    destructor Destroy; override;
    procedure Install;
    procedure Collect;
    procedure Shutdown;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function LocalService(Ref: Integer; out Service: TBluetoothService; out RecordRef: Integer): Boolean;
    procedure AssignRecord(Ref, RecordRef: Integer);
    procedure Publish(Ref: Integer; RegisterIfNeeded: Boolean = False);
    function RemoteInfo(Ref: Integer; out Info: TBluetoothChannelInfo; out Server: Boolean): Boolean;
    function HasSecurity(const Address: TBluetoothAddress; Security: TBluetoothSecurity): Boolean;
    function ConnectionFor(const Address: TBluetoothAddress): Integer;
    function SetSecurity(Ref: Integer; Security: TBluetoothSecurity; Enabled: Boolean): Boolean;
    property ExportRecord: TFunc<Integer, TBluetoothService> read FExport write FExport;
  end;

implementation

uses
  System.Math, Java.Classes, J2ME.Bluetooth.Data, Core.Bluetooth.SDP,
  Core.Bluetooth.Service;
{$Q-}{$R-}

const
  BT = 'javax/bluetooth/';
  IO = 'javax/microedition/io/';
  Base = BT + 'Transport$';
  Stream = Base + 'Stream';
  Packet = Base + 'Packet';
  StreamServer = Base + 'StreamServer';
  PacketServer = Base + 'PacketServer';
  Input = Base + 'Input';
  Output = Base + 'Output';
  WorkClass = Base + 'Work';
  ConnectionKey = '$bt.connection';
  ClosedKey = '$bt.closed';

function Field(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsInt;
end;

procedure ConnectionException(VM: TJVM; Status: Integer; const Text: string);
begin
  try
    VM.RaiseJava(BT + 'BluetoothConnectionException', Text);
  except
    on E: EJVMThrown do
    begin
      VM.GetObject(E.Reference).Fields.AddOrSetValue('$bt.number', TJVMValue.Int(Status));
      raise;
    end;
  end;
end;

function ValidEndpoint(const E: TBluetoothEndpoint): Boolean;
begin
  Result := E.Device.Value <= $FFFFFFFFFFFF;
  if E.Transport = TBluetoothTransport.RFCOMM then
    Result := Result and (E.Channel in [1..30])
  else
    Result := Result and (E.Channel >= 5) and ((E.Channel and $0101) = 1);
end;

procedure Parse(VM: TJVM; const URL: string; out Service: TBluetoothService; out Options: TBluetoothConnectOptions; out Server: Boolean);

  procedure Invalid;
  begin
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Bluetooth URL');
  end;

  function BooleanValue(const Value: string): Boolean;
  begin
    if SameText(Value, 'true') then
      Exit(True);
    if SameText(Value, 'false') then
      Exit(False);
    Invalid;
    Result := False;
  end;

  function Number(const Value: string; Hex: Boolean): Integer;
  begin
    if Value = '' then
      Invalid;
    for var C in Value do
      if not CharInSet(C, ['0'..'9']) and (not Hex or not CharInSet(C, ['a'..'f', 'A'..'F'])) then
        Invalid;
    var S := Value;
    if Hex then
      S := '$' + S;
    if not TryStrToInt(S, Result) or (Result < 0) or (Result > 65535) then
      Invalid;
  end;

begin
  Service := Default(TBluetoothService);
  Options := Default(TBluetoothConnectOptions);
  Server := False;
  if (Length(URL) > 16384) or (Length(URL) < 12) then
    Invalid;
  var P := Pos('://', URL);
  var Scheme := Copy(URL, 1, P - 1);
  if P = 0 then
    Invalid;
  if SameText(Scheme, 'btspp') then
    Service.Endpoint.Transport := TBluetoothTransport.RFCOMM
  else if SameText(Scheme, 'btl2cap') then
    Service.Endpoint.Transport := TBluetoothTransport.L2CAP
  else
    Invalid;
  var Parts := Copy(URL, P + 3, MaxInt).Split([';']);
  P := Pos(':', Parts[0]);
  if P = 0 then
    Invalid;
  var Host := Copy(Parts[0], 1, P - 1);
  var Port := Copy(Parts[0], P + 1, MaxInt);
  Server := SameText(Host, 'localhost');
  if Server then
  begin
    if (Length(Port) < 1) or (Length(Port) > 32) or not TBluetoothUUID.TryParse(Port, Service.Endpoint.Service) then
      Invalid;
    Service.UUIDs := [Service.Endpoint.Service];
  end
  else
  begin
    if (Length(Host) <> 12) or not TBluetoothAddress.TryParse(Host, Service.Endpoint.Device) then
      Invalid;
    Service.Endpoint.Channel := Number(Port, Service.Endpoint.Transport = TBluetoothTransport.L2CAP);
    if Service.Endpoint.Transport = TBluetoothTransport.RFCOMM then
    begin
      if not (Service.Endpoint.Channel in [1..30]) then
        Invalid;
    end
    else if (Service.Endpoint.Channel < 5) or ((Service.Endpoint.Channel and $0101) <> 1) then
      Invalid;
  end;
  var Seen := TDictionary<string, Boolean>.Create;
  var AuthExplicit := False;
  var Auth := False;
  var Encrypt := False;
  var Authorize := False;
  try
    for var I := 1 to High(Parts) do
    begin
      P := Pos('=', Parts[I]);
      if P < 2 then
        Invalid;
      var Key := Copy(Parts[I], 1, P - 1).ToLower;
      var Value := Copy(Parts[I], P + 1, MaxInt);
      if Seen.ContainsKey(Key) then
        Invalid;
      Seen.Add(Key, True);
      if Key = 'authenticate' then
      begin
        AuthExplicit := True;
        Auth := BooleanValue(Value);
      end
      else if Key = 'encrypt' then
        Encrypt := BooleanValue(Value)
      else if Key = 'authorize' then
      begin
        if not Server then
          ConnectionException(VM, 6, 'Client authorization parameter');
        Authorize := BooleanValue(Value);
      end
      else if Key = 'master' then
        Options.RequireMaster := BooleanValue(Value)
      else if Key = 'name' then
      begin
        if not Server or (Value = '') then
          Invalid;
        for var C in Value do
          if not CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', ' ', '-', '_']) then
            Invalid;
        Service.Name := Value;
      end
      else if (Key = 'receivemtu') or (Key = 'transmitmtu') then
      begin
        if Service.Endpoint.Transport <> TBluetoothTransport.L2CAP then
          Invalid;
        var N := Number(Value, False);
        if N < 48 then
          ConnectionException(VM, 6, 'Classic L2CAP MTU below48');
        if Key = 'receivemtu' then
          Options.ReceiveMTU := N
        else
          Options.TransmitMTU := N;
      end
      else if Key = 'psm' then
      begin
        if not Server or (Service.Endpoint.Transport <> TBluetoothTransport.L2CAP) then
          Invalid;
        var N := Number(Value, True);
        if (N < 5) or ((N and $0101) <> 1) then
          Invalid;
        Service.Endpoint.Channel := N;
      end
      else
        Invalid;
    end;
  finally
    Seen.Free;
  end;
  if Encrypt or Authorize then
  begin
    if AuthExplicit and not Auth then
      ConnectionException(VM, 6, 'Security requires authentication');
    Auth := True;
  end;
  if Auth then
    Include(Options.Security, TBluetoothSecurity.Authenticated);
  if Encrypt then
    Include(Options.Security, TBluetoothSecurity.Encrypted);
  if Authorize then
    Include(Options.Security, TBluetoothSecurity.Authorized);
  if Service.Endpoint.Transport = TBluetoothTransport.L2CAP then
    if Options.ReceiveMTU = 0 then
      Options.ReceiveMTU := 672;
  Options.DeferredAdvertisement := Server;
  if Server then
    BindBluetoothService(Service, Service.Endpoint);
end;

destructor TBTConnection.Destroy;
begin
  if Channel <> nil then
    Channel.Close;
  if Listener <> nil then
    Listener.Close;
  inherited;
end;

destructor TBTWork.Destroy;
begin
  if Operation <> nil then
    Operation.Cancel;
  inherited;
end;

constructor TJ2MEBluetoothTransport.Create(VM: TJVM; const Provider: IBluetoothProvider);
begin
  inherited Create;
  FVM := VM;
  FProvider := Provider;
  FConnections := TObjectDictionary<Integer, TBTConnection>.Create([doOwnsValues]);
  FWork := TObjectDictionary<Integer, TBTWork>.Create([doOwnsValues]);
end;

destructor TJ2MEBluetoothTransport.Destroy;
begin
  Shutdown;
  FWork.Free;
  FConnections.Free;
  inherited;
end;

procedure TJ2MEBluetoothTransport.Shutdown;
begin
  FStopped := True;
  FWork.Clear;
  for var C in FConnections.Values do
    Close(C, True);
end;

procedure TJ2MEBluetoothTransport.Close(C: TBTConnection; Force: Boolean);
begin
  C.Closed := True;
  if C.Listener <> nil then
  begin
    C.Listener.Close;
    C.Listener := nil;
  end;
  if Force or ((C.InputRef = 0) and (C.OutputRef = 0)) then
  begin
    if C.Channel <> nil then
      C.Channel.Close;
    C.Channel := nil;
    C.Buffer := nil;
    C.PacketReady := False;
  end;
end;

procedure TJ2MEBluetoothTransport.Collect;
begin
  for var Ref in FWork.Keys.ToArray do
    if not FVM.HasNativeContinuation(Ref) then
      FWork.Remove(Ref);
  for var Ref in FConnections.Keys.ToArray do
  begin
    var C := FConnections[Ref];
    if not FVM.IsObjectAlive(Ref) then
    begin
      FConnections.Remove(Ref);
      Continue;
    end;
    if (C.InputRef <> 0) and not FVM.IsObjectAlive(C.InputRef) then
      C.InputRef := 0;
    if (C.OutputRef <> 0) and not FVM.IsObjectAlive(C.OutputRef) then
      C.OutputRef := 0;
    if C.Closed then
      Close(C);
  end;
end;

procedure TJ2MEBluetoothTransport.IOError(const Text: string; Transferred: Integer);
begin
  try
    FVM.RaiseJava('java/io/InterruptedIOException', Text);
  except
    on E: EJVMThrown do
    begin
      FVM.GetObject(E.Reference).Fields.AddOrSetValue('java/io/InterruptedIOException.bytesTransferred:I', TJVMValue.Int(Transferred));
      raise;
    end;
  end;
end;

procedure TJ2MEBluetoothTransport.Failure(const E: TBluetoothError; Connecting: Boolean);
begin
  if E.Code = TBluetoothErrorCode.None then
    Exit;
  if E.Code = TBluetoothErrorCode.PermissionDenied then
    FVM.RaiseJava('java/lang/SecurityException', E.MessageText);
  if Connecting then
  begin
    var Status := 4;
    case E.Code of
      TBluetoothErrorCode.Unreachable:
        Status := 1;
      TBluetoothErrorCode.AuthenticationFailed:
        Status := 2;
      TBluetoothErrorCode.ResourceLimit, TBluetoothErrorCode.Busy:
        Status := 3;
      TBluetoothErrorCode.Timeout:
        Status := 5;
      TBluetoothErrorCode.InvalidArgument:
        Status := 6;
    end;
    ConnectionException(FVM, Status, E.MessageText);
  end;
  FVM.RaiseJava('java/io/IOException', E.MessageText);
end;

function TJ2MEBluetoothTransport.Work: TBTWork;
begin
  var V := FVM.NativeContinuation;
  if (V.Kind = TJVMKind.Reference) and FWork.TryGetValue(V.AsRef, Result) then
    Exit;
  Collect;
  if FWork.Count >= 64 then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth pending-operation capacity');
  Result := TBTWork.Create;
  try
    Result.Ref := FVM.NewObject(WorkClass);
    Result.Started := FVM.Host.MonotonicMillis;
    FWork.Add(Result.Ref, Result);
  except
    Result.Free;
    raise;
  end;
  FVM.SetNativeContinuation(TJVMValue.Ref(Result.Ref));
end;

procedure TJ2MEBluetoothTransport.Interrupt(W: TBTWork);
begin
  if FVM.ClearInterrupted then
  begin
    var Count := W.Position;
    FWork.Remove(W.Ref);
    IOError('Bluetooth operation interrupted', Count);
  end;
end;

procedure TJ2MEBluetoothTransport.Wait(W: TBTWork);
begin
  if W.Timeouts and (FVM.Host.MonotonicMillis - W.Started >= 30000) then
  begin
    var Count := W.Position;
    var Connecting := (W.Connect <> nil) or (W.Listen <> nil);
    FWork.Remove(W.Ref);
    if Connecting then
      ConnectionException(FVM, 5, 'Bluetooth connection timed out');
    IOError('Bluetooth operation timed out', Count);
  end;
  FVM.SleepCurrent(1, 'java/io/InterruptedIOException', True);
  FVM.RetryNative;
end;

procedure TJ2MEBluetoothTransport.Validate(C: TBTConnection);
begin
  if C.Channel = nil then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth channel closed');
  var Info := C.Channel.Info;
  if (C.Options.Security - Info.Security) <> [] then
    ConnectionException(FVM, 2, 'Required Bluetooth security was not achieved');
  if Info.Endpoint.Transport = TBluetoothTransport.L2CAP then
  begin
    if (Info.ReceiveMTU < 48) or (Info.TransmitMTU < 48) or ((C.Options.ReceiveMTU <> 0) and (Info.ReceiveMTU > C.Options.ReceiveMTU)) or
      ((C.Options.TransmitMTU <> 0) and (Info.TransmitMTU < C.Options.TransmitMTU)) then
      ConnectionException(FVM, 6, 'Unacceptable L2CAP MTU');
  end;
end;

function TJ2MEBluetoothTransport.Attach(const Channel: IBluetoothChannel; Mode: Integer; const Options: TBluetoothConnectOptions; Server: Boolean): Integer;
begin
  if Channel = nil then
    FVM.RaiseJava('java/io/IOException', 'Provider returned no Bluetooth channel');
  var C := TBTConnection.Create;
  try
    C.Channel := Channel;
    C.Mode := Mode;
    C.Options := Options;
    C.Server := Server;
    Validate(C);
    Collect;
    if FConnections.Count >= 128 then
      FVM.RaiseJava('java/io/IOException', 'Bluetooth connection capacity');
    var N := Stream;
    if Channel.Info.Endpoint.Transport = TBluetoothTransport.L2CAP then
      N := Packet;
    C.Ref := FVM.NewObject(N);
    Result := C.Ref;
    FConnections.Add(C.Ref, C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2MEBluetoothTransport.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
begin
  if FStopped then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth stopped');
  if not (Mode in [1, 2, 3]) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth mode');
  var W := Work;
  Interrupt(W);
  if W.Operation = nil then
  begin
    Parse(FVM, URL, W.Service, W.Options, W.Server);
    W.Timeouts := Timeouts;
    if Timeouts then
      W.Options.TimeoutMillis := 30000;
    if W.Server then
    begin
      W.Listen := FProvider.Listen(W.Service, W.Options);
      W.Operation := W.Listen;
    end
    else
    begin
      W.Connect := FProvider.Connect(W.Service.Endpoint, W.Options);
      W.Operation := W.Connect;
    end;
    if W.Operation = nil then
      FVM.RaiseJava('java/io/IOException', 'Provider returned no Bluetooth operation');
  end;
  if W.Operation.State = TBluetoothOperationState.Pending then
  begin
    Wait(W);
    Exit(0);
  end;
  if W.Operation.State <> TBluetoothOperationState.Completed then
  begin
    var E := W.Operation.Error;
    if E.Code = TBluetoothErrorCode.None then
      E.Code := TBluetoothErrorCode.IOFailure;
    Failure(E, True);
  end;
  if not W.Server then
  begin
    var Channel := W.Connect.TakeChannel;
    if Channel <> nil then
    begin
      var E := Channel.Info.Endpoint;
      if not ValidEndpoint(E) or (E.Device.Value <> W.Service.Endpoint.Device.Value) or (E.Transport <> W.Service.Endpoint.Transport) or (E.Channel <> W.Service.Endpoint.Channel) then
      begin
        Channel.Close;
        FVM.RaiseJava('java/io/IOException', 'Provider connected another Bluetooth endpoint');
      end;
    end;
    Result := Attach(Channel, Mode, W.Options, False);
  end
  else
  begin
    if FConnections.Count >= 128 then
      FVM.RaiseJava('java/io/IOException', 'Bluetooth connection capacity');
    var Listener := W.Listen.TakeListener;
    if Listener = nil then
      FVM.RaiseJava('java/io/IOException', 'Provider returned no Bluetooth listener');
    var C := TBTConnection.Create;
    try
      C.Listener := Listener;
      var Registration: IBluetoothServiceRegistration;
      if not Supports(Listener, IBluetoothServiceRegistration, Registration) then
        FVM.RaiseJava('java/io/IOException', 'Provider lacks deferred service registration');
      C.Service := W.Service;
      BindBluetoothService(C.Service, Listener.Service.Endpoint);
      if not ValidEndpoint(C.Service.Endpoint) or (C.Service.Endpoint.Device.Value <> FProvider.Info.Device.Address.Value) or
        (C.Service.Endpoint.Transport <> W.Service.Endpoint.Transport) then
        FVM.RaiseJava('java/io/IOException', 'Invalid bound Bluetooth endpoint');
      C.Mode := Mode;
      C.Options := W.Options;
      C.Server := True;
      var N := StreamServer;
      if C.Service.Endpoint.Transport = TBluetoothTransport.L2CAP then
        N := PacketServer;
      C.Ref := FVM.NewObject(N);
      Result := C.Ref;
      FConnections.Add(C.Ref, C);
      C := nil;
    finally
      C.Free;
    end;
  end;
  FWork.Remove(W.Ref);
end;

function TJ2MEBluetoothTransport.Prefetch(C: TBTConnection): Boolean;
begin
  if C.PacketReady or (C.Position < Length(C.Buffer)) then
    Exit(True);
  if C.EOF then
    Exit(False);
  var Count := 4096;
  if C.Channel.Info.Endpoint.Transport = TBluetoothTransport.L2CAP then
    Count := C.Channel.Info.ReceiveMTU;
  SetLength(C.Buffer, Count);
  C.Position := 0;
  var T := C.Channel.Read(C.Buffer, 0, Count);
  if (T.Count < 0) or (T.Count > Count) then
    FVM.RaiseJava('java/io/IOException', 'Invalid Bluetooth read count');
  if T.State = TBluetoothIOState.Ready then
  begin
    SetLength(C.Buffer, T.Count);
    C.PacketReady := C.Channel.Info.Endpoint.Transport = TBluetoothTransport.L2CAP;
    if not C.PacketReady and (T.Count = 0) then
      FVM.RaiseJava('java/io/IOException', 'Bluetooth stream made no read progress');
    Exit(True);
  end;
  C.Buffer := nil;
  if T.State = TBluetoothIOState.WouldBlock then
    Exit(False);
  if T.State = TBluetoothIOState.EndOfStream then
  begin
    C.EOF := True;
    Exit(False);
  end;
  if T.State = TBluetoothIOState.Failed then
    Failure(T.Error);
  FVM.RaiseJava('java/io/IOException', 'Bluetooth input closed');
  Result := False;
end;

function TJ2MEBluetoothTransport.LocalService(Ref: Integer; out Service: TBluetoothService; out RecordRef: Integer): Boolean;
begin
  Service := Default(TBluetoothService);
  RecordRef := 0;
  var C: TBTConnection;
  Result := FConnections.TryGetValue(Ref, C) and (C.Listener <> nil) and not C.Closed;
  if Result then
  begin
    Service := C.Service;
    RecordRef := C.RecordRef;
  end;
end;

procedure TJ2MEBluetoothTransport.AssignRecord(Ref, RecordRef: Integer);
begin
  var C := FConnections[Ref];
  C.RecordRef := RecordRef;
  FVM.GetObject(Ref).Fields.AddOrSetValue('$bt.record', TJVMValue.Ref(RecordRef));
end;

procedure TJ2MEBluetoothTransport.Publish(Ref: Integer; RegisterIfNeeded: Boolean);
begin
  var C: TBTConnection;
  if not FConnections.TryGetValue(Ref, C) or C.Closed or (C.Listener = nil) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Closed or foreign Bluetooth notifier');
  if not C.Advertised and not RegisterIfNeeded then
  begin
    if (C.RecordRef <> 0) and Assigned(FExport) then
      C.Service := FExport(C.RecordRef);
    Exit;
  end;
  var W := Work;
  Interrupt(W);
  W.Connection := Ref;
  if W.Operation = nil then
  begin
    var Service := C.Service;
    var Classes := UInt32(0);
    if (C.RecordRef <> 0) and Assigned(FExport) then
    begin
      Service := FExport(C.RecordRef);
      Classes := UInt32(Field(FVM.GetObject(C.RecordRef), '$bt.classes'));
    end;
    Service.Endpoint := C.Service.Endpoint;
    var Registration: IBluetoothServiceRegistration;
    if not Supports(C.Listener, IBluetoothServiceRegistration, Registration) then
      FVM.RaiseJava(BT + 'ServiceRegistrationException', 'Provider cannot publish service');
    W.Service := Service;
    W.Operation := Registration.Publish(Service, Classes);
    if W.Operation = nil then
      FVM.RaiseJava(BT + 'ServiceRegistrationException', 'Provider returned no registration operation');
  end;
  if W.Operation.State = TBluetoothOperationState.Pending then
  begin
    Wait(W);
    Exit;
  end;
  if W.Operation.State <> TBluetoothOperationState.Completed then
    FVM.RaiseJava(BT + 'ServiceRegistrationException', W.Operation.Error.MessageText);
  C.Service := W.Service;
  C.Advertised := True;
  FWork.Remove(W.Ref);
  FVM.SetNativeContinuation(Default(TJVMValue));
end;

function TJ2MEBluetoothTransport.RemoteInfo(Ref: Integer; out Info: TBluetoothChannelInfo; out Server: Boolean): Boolean;
begin
  Info := Default(TBluetoothChannelInfo);
  Server := False;
  var C: TBTConnection;
  Result := FConnections.TryGetValue(Ref, C);
  if Result then
  begin
    if C.Closed then
      FVM.RaiseJava('java/io/IOException', 'Bluetooth connection closed');
    Result := C.Channel <> nil;
    if Result then
    begin
      Info := C.Channel.Info;
      Server := C.Server;
    end;
  end;
end;

function TJ2MEBluetoothTransport.ConnectionFor(const Address: TBluetoothAddress): Integer;
begin
  for var C in FConnections.Values do
    if not C.Closed and (C.Channel <> nil) and (C.Channel.Info.Endpoint.Device.Value = Address.Value) then
      Exit(C.Ref);
  Result := 0;
end;

function TJ2MEBluetoothTransport.HasSecurity(const Address: TBluetoothAddress; Security: TBluetoothSecurity): Boolean;
begin
  Result := False;
  for var C in FConnections.Values do
    if C.Channel <> nil then
    begin
      var Info := C.Channel.Info;
      if (Info.Endpoint.Device.Value = Address.Value) and (Security in Info.Security) then
        Exit(True);
    end;
end;

function TJ2MEBluetoothTransport.SetSecurity(Ref: Integer; Security: TBluetoothSecurity; Enabled: Boolean): Boolean;
begin
  var C: TBTConnection;
  if not FConnections.TryGetValue(Ref, C) or C.Closed or (C.Channel = nil) then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth connection closed');
  var State := FVM.NativeContinuation;
  if (State.Kind <> TJVMKind.Reference) and ((Security in C.Channel.Info.Security) = Enabled) then
    Exit(True);
  var Control: IBluetoothLinkControl;
  if not Supports(C.Channel, IBluetoothLinkControl, Control) then
    Exit(False);
  var W := Work;
  Interrupt(W);
  W.Connection := Ref;
  if W.Operation = nil then
    W.Operation := Control.ChangeSecurity(Security, Enabled);
  if W.Operation = nil then
    FVM.RaiseJava('java/io/IOException', 'Provider returned no security operation');
  if W.Operation.State = TBluetoothOperationState.Pending then
  begin
    Wait(W);
    Exit(False);
  end;
  Result := (W.Operation.State = TBluetoothOperationState.Completed) and ((Security in C.Channel.Info.Security) = Enabled);
  FWork.Remove(W.Ref);
  FVM.SetNativeContinuation(Default(TJVMValue));
end;

function TJ2MEBluetoothTransport.Handles(const Owner: string): Boolean;
begin
  Result := Owner.StartsWith(Base) and (Owner <> WorkClass);
end;

procedure TJ2MEBluetoothTransport.Install;
var
  B: TJavaClassBuilder;

  procedure Native(const N, D: string; Sync: Boolean = False);
  begin
    var Flags := JVM_ACC_PUBLIC;
    if Sync then
      Flags := Flags or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative(N, D).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(WorkClass, 'java/lang/Object', JVM_ACC_FINAL);
    Done;
    B := TJavaClassBuilder.Create(Stream, 'java/lang/Object', JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [IO + 'StreamConnection'];
    Native('close', '()V');
    for var Reading in [True, False] do
    begin
      var Direction := 'Output';
      if Reading then
        Direction := 'Input';
      Native('open' + Direction + 'Stream', '()Ljava/io/' + Direction + 'Stream;');
      var Wrapper := 'java/io/Data' + Direction + 'Stream';
      B.Start;
      B.Ref($BB, B.ClassRef(Wrapper));
      B.Emit([$59, $2A]);
      B.Ref($B6, B.Member(Stream, 'open' + Direction + 'Stream', '()Ljava/io/' + Direction + 'Stream;'));
      B.Ref($B7, B.Member(Wrapper, '<init>', '(Ljava/io/' + Direction + 'Stream;)V'));
      B.Emit([$B0]);
      B.Finish('openData' + Direction + 'Stream', '()L' + Wrapper + ';', JVM_ACC_PUBLIC, 3, 1);
    end;
    Done;
    B := TJavaClassBuilder.Create(Packet, 'java/lang/Object', JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [BT + 'L2CAPConnection'];
    Native('close', '()V');
    for var N in ['getTransmitMTU', 'getReceiveMTU'] do
      Native(N, '()I');
    Native('ready', '()Z', True);
    Native('send', '([B)V');
    Native('receive', '([B)I', True);
    Done;
    B := TJavaClassBuilder.Create(StreamServer, 'java/lang/Object', JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [IO + 'StreamConnectionNotifier'];
    Native('close', '()V');
    Native('acceptAndOpen', '()Ljavax/microedition/io/StreamConnection;', True);
    Done;
    B := TJavaClassBuilder.Create(PacketServer, 'java/lang/Object', JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [BT + 'L2CAPConnectionNotifier'];
    Native('close', '()V');
    Native('acceptAndOpen', '()Ljavax/bluetooth/L2CAPConnection;', True);
    Done;
    B := TJavaClassBuilder.Create(Input, 'java/io/InputStream', JVM_ACC_FINAL);
    Native('read', '()I', True);
    Native('read', '([BII)I', True);
    Native('available', '()I', True);
    Native('skip', '(J)J', True);
    Native('close', '()V');
    Done;
    B := TJavaClassBuilder.Create(Output, 'java/io/OutputStream', JVM_ACC_FINAL);
    Native('write', '(I)V', True);
    Native('write', '([BII)V', True);
    Native('flush', '()V');
    Native('close', '()V');
    Done;
  finally
    B.Free;
  end;
end;

function TJ2MEBluetoothTransport.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  C: TBTConnection;
  O, A: TJVMObject;
  Offset, Count: Integer;

  procedure Range;
  begin
    A := FVM.GetObject(Args[1].AsRef);
    Offset := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
      FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;

begin
  Result := Default(TJVMValue);
  var N := Method.Name;
  var Owner := Method.Owner.Name;
  O := FVM.GetObject(Args[0].AsRef);
  Collect;
  var IsInput := Owner = Input;
  var IsOutput := Owner = Output;
  var Ref := Args[0].AsRef;
  if IsInput or IsOutput then
  begin
    if Field(O, ClosedKey) <> 0 then
    begin
      if N = 'close' then
        Exit;
      FVM.RaiseJava('java/io/IOException', 'Bluetooth stream closed');
    end;
    Ref := O.Fields[ConnectionKey].AsRef;
  end;
  if not FConnections.TryGetValue(Ref, C) then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth connection released');
  if N = 'close' then
  begin
    if not IsInput and not IsOutput then
      Close(C)
    else
    begin
      O.Fields.AddOrSetValue(ClosedKey, TJVMValue.Int(1));
      O.Fields.AddOrSetValue(ConnectionKey, TJVMValue.Ref(0));
      if IsInput then
        C.InputRef := 0
      else
        C.OutputRef := 0;
      if C.Closed then
        Close(C);
    end;
    Exit;
  end;
  if C.Closed and not IsInput and not IsOutput then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth connection closed');
  if N = 'acceptAndOpen' then
  begin
    if not C.Advertised then
    begin
      Publish(Ref, True);
      if FVM.NativeContinuation.Kind <> TJVMKind.Empty then
        Exit;
    end;
    var W := Work;
    Interrupt(W);
    W.Connection := Ref;
    var Channel: IBluetoothChannel;
    var T := C.Listener.TryAccept(Channel);
    if T.State = TBluetoothIOState.WouldBlock then
    begin
      Wait(W);
      Exit;
    end;
    if T.State <> TBluetoothIOState.Ready then
    begin
      Failure(T.Error);
      FVM.RaiseJava('java/io/IOException', 'Bluetooth accept closed');
    end;
    if Channel <> nil then
    begin
      var E := Channel.Info.Endpoint;
      if not ValidEndpoint(E) or (E.Transport <> C.Service.Endpoint.Transport) or (E.Channel <> C.Service.Endpoint.Channel) then
      begin
        Channel.Close;
        FVM.RaiseJava('java/io/IOException', 'Invalid accepted Bluetooth endpoint');
      end;
    end;
    Result := TJVMValue.Ref(Attach(Channel, C.Mode, C.Options, True));
    FWork.Remove(W.Ref);
    Exit;
  end;
  if Owner = Stream then
  begin
    var Reading := N = 'openInputStream';
    if Reading then
    begin
      if (C.Mode and 1) = 0 then
        FVM.RaiseJava('java/io/IOException', 'Write-only Bluetooth connection');
      if C.InputOpened then
        FVM.RaiseJava('java/io/IOException', 'Bluetooth input already opened');
    end
    else
    begin
      if (C.Mode and 2) = 0 then
        FVM.RaiseJava('java/io/IOException', 'Read-only Bluetooth connection');
      if C.OutputOpened then
        FVM.RaiseJava('java/io/IOException', 'Bluetooth output already opened');
    end;
    var ClassName := Output;
    if Reading then
      ClassName := Input;
    var StreamRef := FVM.NewObject(ClassName);
    FVM.GetObject(StreamRef).Fields.AddOrSetValue(ConnectionKey, TJVMValue.Ref(Ref));
    if Reading then
    begin
      C.InputOpened := True;
      C.InputRef := StreamRef;
    end
    else
    begin
      C.OutputOpened := True;
      C.OutputRef := StreamRef;
    end;
    Exit(TJVMValue.Ref(StreamRef));
  end;
  if C.Channel = nil then
    FVM.RaiseJava('java/io/IOException', 'Bluetooth transport closed');
  if N = 'getReceiveMTU' then
    Exit(TJVMValue.Int(C.Channel.Info.ReceiveMTU));
  if N = 'getTransmitMTU' then
    Exit(TJVMValue.Int(C.Channel.Info.TransmitMTU));
  if N = 'flush' then
    Exit;
  if (N = 'ready') or (N = 'available') then
  begin
    var Ready := Prefetch(C);
    if N = 'ready' then
      Exit(TJVMValue.Int(Ord(Ready)));
    Exit(TJVMValue.Int(Length(C.Buffer) - C.Position));
  end;
  A := nil;
  Offset := 0;
  Count := 1;
  if (N = 'read') and (Method.Descriptor <> '()I') then
    Range;
  if (N = 'write') and (Method.Descriptor <> '(I)V') then
    Range;
  if (N = 'receive') or (N = 'send') then
  begin
    A := FVM.GetObject(Args[1].AsRef);
    Count := Length(A.Elements);
  end;
  if (N = 'read') or (N = 'receive') or (N = 'skip') then
  begin
    if (C.Mode and 1) = 0 then
      FVM.RaiseJava('java/io/IOException', 'Write-only Bluetooth connection');
    if ((N = 'read') and (Count = 0)) or ((N = 'skip') and (Args[1].AsLong <= 0)) then
    begin
      if N = 'skip' then
        Exit(TJVMValue.Long(0));
      Exit(TJVMValue.Int(0));
    end;
    var W := Work;
    Interrupt(W);
    W.Connection := Ref;
    W.Timeouts := C.Options.TimeoutMillis <> 0;
    if not Prefetch(C) then
    begin
      if C.EOF then
      begin
        FWork.Remove(W.Ref);
        if N = 'receive' then
          FVM.RaiseJava('java/io/IOException', 'L2CAP peer closed');
        if N = 'skip' then
          Exit(TJVMValue.Long(0));
        Exit(TJVMValue.Int(-1));
      end;
      Wait(W);
      Exit;
    end;
    if N = 'skip' then
    begin
      Count := Integer(Min(Args[1].AsLong, Int64(Length(C.Buffer) - C.Position)));
      Inc(C.Position, Count);
      Result := TJVMValue.Long(Count);
    end
    else
    begin
      Count := Min(Count, Length(C.Buffer) - C.Position);
      if A = nil then
      begin
        Result := TJVMValue.Int(C.Buffer[C.Position]);
        Inc(C.Position);
      end
      else
      begin
        for var I := 0 to Count - 1 do
          A.Elements[Offset + I] := TJVMValue.Int(ShortInt(C.Buffer[C.Position + I]));
        Inc(C.Position, Count);
        Result := TJVMValue.Int(Count);
      end;
      if N = 'receive' then
      begin
        C.PacketReady := False;
        C.Buffer := nil;
        C.Position := 0;
      end;
    end;
    FWork.Remove(W.Ref);
    Exit;
  end;
  if (N = 'write') or (N = 'send') then
  begin
    if (C.Mode and 2) = 0 then
      FVM.RaiseJava('java/io/IOException', 'Read-only Bluetooth connection');
    var V := FVM.NativeContinuation;
    var NewWork := V.Kind <> TJVMKind.Reference;
    var W := Work;
    Interrupt(W);
    W.Connection := Ref;
    W.Timeouts := C.Options.TimeoutMillis <> 0;
    if NewWork then
    begin
      if N = 'send' then
        Count := Min(Count, Integer(C.Channel.Info.TransmitMTU));
      SetLength(W.Data, Count);
      if A = nil then
        W.Data[0] := Byte(Args[1].AsInt)
      else
        for var I := 0 to Count - 1 do
          W.Data[I] := Byte(A.Elements[Offset + I].AsInt);
    end;
    if (Length(W.Data) = W.Position) and (N <> 'send') then
    begin
      FWork.Remove(W.Ref);
      Exit;
    end;
    var T := C.Channel.Write(W.Data, W.Position, Length(W.Data) - W.Position);
    if (T.Count < 0) or (T.Count > Length(W.Data) - W.Position) then
      FVM.RaiseJava('java/io/IOException', 'Invalid Bluetooth write count');
    if T.State = TBluetoothIOState.Ready then
    begin
      if (N = 'send') and (T.Count <> Length(W.Data)) then
        FVM.RaiseJava('java/io/IOException', 'Partial L2CAP packet write');
      if (N = 'write') and (T.Count = 0) then
        FVM.RaiseJava('java/io/IOException', 'Bluetooth stream made no write progress');
      Inc(W.Position, T.Count);
      if W.Position = Length(W.Data) then
      begin
        FWork.Remove(W.Ref);
        Exit;
      end;
    end
    else if T.State <> TBluetoothIOState.WouldBlock then
    begin
      Failure(T.Error);
      FVM.RaiseJava('java/io/IOException', 'Bluetooth output closed');
    end;
    Wait(W);
    Exit;
  end;
  raise EJVMUnsupported.Create('Bluetooth transport ' + N);
end;

end.

