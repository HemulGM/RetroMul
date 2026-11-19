unit J2ME.Network.TCP;

interface

uses
  System.Classes, System.Generics.Collections, System.Net.Socket,
  System.SyncObjs, System.SysUtils, JVM.ClassFile, JVM.Runtime, JVM.Types;

type
  IJ2METCPDial = interface
    procedure Connect(const Host: string; Port: Word);
    function Done: Boolean;
    function TryTake(out Socket: TSocket; out Error: string): Boolean;
  end;

  TJ2METCPReader = class(TThread)
  private
    FSocket: TSocket;
    FRequest: TEvent;
    FData: TBytes;
    FOffset, FCount, FSize, FReady: Integer;
    FPending: Boolean;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(Socket: System.Net.Socket.TSocket);
    destructor Destroy; override;
    function Available: Integer;
    function TryRead(var Data: array of Byte; Count: Integer; out Size: Integer; out Error: string): Boolean;
  end;

  TJ2METCPWriter = class(TThread)
  private
    FSocket: TSocket;
    FRequest: TEvent;
    FData: TBytes;
    FCount, FTransferred, FReady: Integer;
    FError: string;
    FPending: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(Socket: System.Net.Socket.TSocket);
    destructor Destroy; override;
    procedure Submit(const Buffer: array of Byte; Count: Integer);
    function TryFinish(out Transferred: Integer; out Error: string): Boolean;
    property Pending: Boolean read FPending;
  end;

  TJ2METCPConnection = class
    Socket: TSocket;
    Reader: TJ2METCPReader;
    Writer: TJ2METCPWriter;
    InputRef, OutputRef, Mode: Integer;
    Closed, InputOpened, OutputOpened, Timeouts, LingerEnabled: Boolean;
    WriteDeadline: Int64;
    function CloseOutput: Integer;
    destructor Destroy; override;
  end;

  TJ2METCPListener = class(TSocket)
  public
    function TryAccept: TSocket;
  end;

  TJ2METCPListeningConnection = class
    Socket: TJ2METCPListener;
    Mode: Integer;
    Timeouts: Boolean;
    destructor Destroy; override;
  end;

  TJ2METCP = class
  private
    FVM: TJVM;
    FConnections: TObjectDictionary<Integer, TJ2METCPConnection>;
    FDials: TDictionary<Integer, IJ2METCPDial>;
    FListeners: TObjectDictionary<Integer, TJ2METCPListeningConnection>;
    procedure RequireCapacity;
    function RegisterSocket(Socket: TSocket; Mode: Integer; Timeouts: Boolean): Integer;
    function OpenListener(Port: Word; Mode: Integer; Timeouts: Boolean): Integer;
    function InvokeListener(const Name: string; Ref: Integer): TJVMValue;
    procedure Wait;
    procedure InterruptWrite(const MessageText: string; Transferred: Integer);
    procedure WriteStream(C: TJ2METCPConnection; Ref: Integer; Data: TJVMObject; Offset, Count, Value: Integer);
    procedure ReleaseClosed(Ref: Integer; C: TJ2METCPConnection);
    function OpenStream(Ref: Integer; C: TJ2METCPConnection; Reading: Boolean): Integer;
    function StreamCall(C: TJ2METCPConnection; Ref: Integer; Reading: Boolean; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  public
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    procedure Install;
    procedure Collect;
    procedure Stop;
    function IsIdle: Boolean;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}  Winapi.Winsock2, {$ENDIF}
  {$IFDEF POSIX}Posix.Errno, Posix.Fcntl, Posix.NetinetIn, Posix.NetinetTCP,
  Posix.SysSocket, Posix.Unistd, {$ENDIF}
  System.Math, Java.Classes;

const
  API = 'javax/microedition/io/SocketConnection';
  ConnectionClass = API + '$Native';
  InputClass = API + '$Input';
  OutputClass = API + '$Output';
  ListenerAPI = 'javax/microedition/io/ServerSocketConnection';
  ListenerClass = ListenerAPI + '$Native';
  ConnectionKey = '$tcp.connection';
  BlockSize = 4096;
  ConnectionLimit = 32;
  ConnectTimeout = 15000;
  IOTimeout = 30000;
  OptionNames: array[0..4] of string = ('DELAY', 'LINGER', 'KEEPALIVE', 'RCVBUF', 'SNDBUF');

type
  TJ2METCPDial = class(TInterfacedObject, IJ2METCPDial)
  private
    FSocket: System.Net.Socket.TSocket;
    FError: string;
    FDone: Integer;
  public
    destructor Destroy; override;
    procedure Connect(const Host: string; Port: Word);
    function Done: Boolean;
    function TryTake(out Socket: System.Net.Socket.TSocket; out Error: string): Boolean;
  end;

function IsRetryable(Code: Integer): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := (Code = WSAETIMEDOUT) or (Code = WSAEWOULDBLOCK);
  {$ELSE}
  Result := (Code = EAGAIN) or (Code = EWOULDBLOCK) or (Code = EINTR);
  {$ENDIF}
end;

destructor TJ2METCPDial.Destroy;
begin
  FSocket.Free;
  inherited;
end;

procedure TJ2METCPDial.Connect(const Host: string; Port: Word);
begin
  try
    FSocket := System.Net.Socket.TSocket.Create(TSocketType.TCP);
    FSocket.Connect(TNetEndpoint.Create(TIPAddress.Create(Host), Port));
  except
    on E: Exception do
      FError := E.Message;
  end;
  TInterlocked.Exchange(FDone, 1);
end;

function TJ2METCPDial.Done: Boolean;
begin
  Result := TInterlocked.CompareExchange(FDone, 0, 0) <> 0;
end;

function TJ2METCPDial.TryTake(out Socket: System.Net.Socket.TSocket; out Error: string): Boolean;
begin
  Result := Done;
  if not Result then
    Exit;
  Error := FError;
  if Error = '' then
  begin
    Socket := FSocket;
    FSocket := nil;
  end;
end;

function StartDial(const Host: string; Port: Word): IJ2METCPDial;
begin
  var Dial: IJ2METCPDial := TJ2METCPDial.Create;
  var Worker := TThread.CreateAnonymousThread(
    procedure
    begin
      Dial.Connect(Host, Port);
    end);
  try
    Worker.Start;
  except
    Worker.Free;
    raise;
  end;
  Result := Dial;
end;

constructor TJ2METCPReader.Create(Socket: System.Net.Socket.TSocket);
begin
  inherited Create(True);
  FSocket := Socket;
  FRequest := TEvent.Create(nil, False, False, '');
  SetLength(FData, BlockSize);
  FSocket.ReceiveTimeout := 50;
end;

destructor TJ2METCPReader.Destroy;
begin
  Terminate;
  if FRequest <> nil then
    FRequest.SetEvent;
  inherited;
  FRequest.Free;
end;

procedure TJ2METCPReader.Execute;
begin
  while not Terminated do
  begin
    FRequest.WaitFor(INFINITE);
    if Terminated then
      Break;
    FError := '';
    FSize := -1;
    repeat
      try
        {$IFDEF MSWINDOWS}
        var Chunk: TWSABuf;
        Chunk.buf := MarshaledAString(@FData[0]);
        Chunk.len := FCount;
        var Received: Cardinal := 0;
        var Flags: Cardinal := 0;
        if WSARecv(FSocket.Handle, @Chunk, 1, Received, Flags, nil, nil) = 0 then
          FSize := Integer(Received)
        else
        begin
          var Code := WSAGetLastError;
          if not IsRetryable(Code) then
            FError := SysErrorMessage(Code);
        end;
        {$ELSE}
        FSize := FSocket.Receive(FData[0], FCount);
        {$ENDIF}
      except
        on E: ESocketError do
          if not IsRetryable(E.Code) then
            FError := E.Message;
        on E: Exception do
          FError := E.Message;
      end;
    until Terminated or (FSize >= 0) or (FError <> '');
    TInterlocked.Exchange(FReady, 1);
  end;
end;

function TJ2METCPReader.Available: Integer;
begin
  Result := 0;
  if TInterlocked.CompareExchange(FReady, 0, 0) <> 0 then
    Result := Max(0, FSize - FOffset);
end;

function TJ2METCPReader.TryRead(var Data: array of Byte; Count: Integer; out Size: Integer; out Error: string): Boolean;
begin
  if not FPending then
  begin
    TInterlocked.Exchange(FReady, 0);
    FOffset := 0;
    FCount := Count;
    FPending := True;
    FRequest.SetEvent;
  end;
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
  if not Result then
    Exit;
  Size := Min(Count, Max(0, FSize - FOffset));
  Error := FError;
  if Size > 0 then
  begin
    Move(FData[FOffset], Data[0], Size);
    Inc(FOffset, Size);
  end;
  FPending := FOffset < FSize;
  if not FPending then
    TInterlocked.Exchange(FReady, 0);
end;

constructor TJ2METCPWriter.Create(Socket: System.Net.Socket.TSocket);
begin
  inherited Create(True);
  FSocket := Socket;
  FRequest := TEvent.Create(nil, False, False, '');
  SetLength(FData, BlockSize);
  FSocket.SendTimeout := 50;
end;

destructor TJ2METCPWriter.Destroy;
begin
  Terminate;
  if FRequest <> nil then
    FRequest.SetEvent;
  inherited;
  FRequest.Free;
end;

procedure TJ2METCPWriter.Execute;
begin
  while not Terminated do
  begin
    FRequest.WaitFor(INFINITE);
    if Terminated then
      Break;
    FTransferred := 0;
    FError := '';
    try
      {$IFDEF MSWINDOWS}
      var Chunk: TWSABuf;
      Chunk.buf := MarshaledAString(@FData[0]);
      Chunk.len := FCount;
      var Sent: Cardinal := 0;
      if WSASend(FSocket.Handle, @Chunk, 1, Sent, 0, nil, nil) = 0 then
        FTransferred := Integer(Sent)
      else
      begin
        var Code := WSAGetLastError;
        if not IsRetryable(Code) then
          FError := SysErrorMessage(Code);
      end;
      {$ELSE}
      {$WARN SYMBOL_PLATFORM OFF}
      {$IF Declared(MSG_NOSIGNAL)}
      FTransferred := FSocket.Send(FData[0], FCount, MSG_NOSIGNAL);
      {$ELSE}
      FTransferred := FSocket.Send(FData[0], FCount);
      {$ENDIF}
      {$WARN SYMBOL_PLATFORM ON}
      {$ENDIF}
    except
      on E: ESocketError do
        if not IsRetryable(E.Code) then
          FError := E.Message;
      on E: Exception do
        FError := E.Message;
    end;
    TInterlocked.Exchange(FReady, 1);
  end;
end;

procedure TJ2METCPWriter.Submit(const Buffer: array of Byte; Count: Integer);
begin
  Move(Buffer[0], FData[0], Count);
  FCount := Count;
  TInterlocked.Exchange(FReady, 0);
  FPending := True;
  FRequest.SetEvent;
end;

function TJ2METCPWriter.TryFinish(out Transferred: Integer; out Error: string): Boolean;
begin
  Result := FPending and (TInterlocked.CompareExchange(FReady, 0, 0) <> 0);
  if not Result then
    Exit;
  Transferred := FTransferred;
  Error := FError;
  FPending := False;
end;

procedure CloseSocket(Socket: System.Net.Socket.TSocket);
begin
  if Socket = nil then
    Exit;
  try
    if TSocketState.Connected in Socket.State then
      Socket.Close(True);
  finally
    Socket.Free;
  end;
end;

procedure SetNonblocking(Handle: TSocketHandle; Enabled: Boolean);
begin
  {$IFDEF MSWINDOWS}
  var Mode: Cardinal := Ord(Enabled);
  if ioctlsocket(Handle, Longint(FIONBIO), Mode) <> 0 then
    raise ESocketError.Create(SysErrorMessage(WSAGetLastError));
  {$ELSE}
  var Flags := fcntl(Handle, F_GETFL);
  if Flags < 0 then
    raise ESocketError.Create(SysErrorMessage(Posix.Errno.errno));
  if Enabled then
    Flags := Flags or O_NONBLOCK
  else
    Flags := Flags and not O_NONBLOCK;
  if fcntl(Handle, F_SETFL, Flags) < 0 then
    raise ESocketError.Create(SysErrorMessage(Posix.Errno.errno));
  {$ENDIF}
end;

function TJ2METCPListener.TryAccept: System.Net.Socket.TSocket;
var
  Address: sockaddr_in;
  Client: TSocketHandle;
begin
  Result := nil;
  Address := Default(sockaddr_in);
  {$IFDEF MSWINDOWS}
  var Size: Integer := SizeOf(Address);
  Client := Winapi.Winsock2.accept(Handle, PSockAddr(@Address), @Size);
  if Client = INVALID_SOCKET then
  begin
    var Code := WSAGetLastError;
  {$ELSE}
  var Size: socklen_t := SizeOf(Address);
  Client := Posix.SysSocket.accept(Handle, sockaddr(Address), Size);
  if Client < 0 then
  begin
    var Code := Posix.Errno.errno;
  {$ENDIF}
    if IsRetryable(Code) then
      Exit;
    raise ESocketError.Create(SysErrorMessage(Code));
  end;
  try
    SetNonblocking(Client, False);
    Result := GetClientSocket(Client, Address);
  except
    {$IFDEF MSWINDOWS}
    Winapi.Winsock2.closesocket(Client);
    {$ELSE}
    Posix.Unistd.__close(Client);
    {$ENDIF}
    raise;
  end;
end;

destructor TJ2METCPListeningConnection.Destroy;
begin
  CloseSocket(Socket);
  inherited;
end;

function TJ2METCPConnection.CloseOutput: Integer;
begin
  Result := 0;
  shutdown(Socket.Handle, 1);
  if (Writer <> nil) and Writer.Pending then
  begin
    // A send may have completed between the VM's last poll and shutdown.
    Writer.Terminate;
    Writer.FRequest.SetEvent;
    Writer.WaitFor;
    var Transferred: Integer;
    var Error: string;
    if Writer.TryFinish(Transferred, Error) then
      Result := Max(Transferred, 0);
  end;
  FreeAndNil(Writer);
  OutputRef := 0;
end;

destructor TJ2METCPConnection.Destroy;
begin
  if Writer <> nil then
    CloseOutput;
  if Reader <> nil then
  begin
    shutdown(Socket.Handle, 0);
    Reader.Free;
  end;
  if LingerEnabled then
  begin
    // The host may wait for pending output when closing a lingering socket.
    // The worker owns only the detached host socket.
    var Detached := Socket;
    var Worker := TThread.CreateAnonymousThread(
      procedure
      begin
        CloseSocket(Detached);
      end);
    try
      Worker.Start;
    except
      Worker.Free;
      CloseSocket(Detached);
    end;
  end
  else
    CloseSocket(Socket);
  inherited;
end;

constructor TJ2METCP.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
  FDials := TDictionary<Integer, IJ2METCPDial>.Create;
  FListeners := TObjectDictionary<Integer, TJ2METCPListeningConnection>.Create([doOwnsValues]);
  FConnections := TObjectDictionary<Integer, TJ2METCPConnection>.Create([doOwnsValues]);
end;

destructor TJ2METCP.Destroy;
begin
  FListeners.Free;
  FConnections.Free;
  FDials.Free;
  inherited;
end;

procedure TJ2METCP.Stop;
begin
  FListeners.Clear;
  FConnections.Clear;
  FDials.Clear;
end;

function TJ2METCP.IsIdle: Boolean;
begin
  if (FConnections.Count <> 0) or (FListeners.Count <> 0) then
    Exit(False);
  for var Ref in FDials.Keys do
    if FVM.HasNativeContinuation(Ref) then
      Exit(False);
  Result := True;
end;

procedure TJ2METCP.Collect;
begin
  for var Ref in FListeners.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FListeners.Remove(Ref);
  for var Ref in FDials.Keys.ToArray do
    if not FVM.HasNativeContinuation(Ref) and FDials[Ref].Done then
      FDials.Remove(Ref);
  for var Ref in FConnections.Keys.ToArray do
  begin
    if not FVM.IsObjectAlive(Ref) then
    begin
      FConnections.Remove(Ref);
      Continue;
    end;
    var C := FConnections[Ref];
    if not FVM.IsObjectAlive(C.InputRef) then
      C.InputRef := 0;
    if not FVM.IsObjectAlive(C.OutputRef) then
      C.OutputRef := 0;
    ReleaseClosed(Ref, C);
  end;
end;

procedure TJ2METCP.ReleaseClosed(Ref: Integer; C: TJ2METCPConnection);
begin
  if C.Closed and (C.InputRef = 0) and (C.OutputRef = 0) then
    FConnections.Remove(Ref);
end;

procedure TJ2METCP.Install;
var
  B: TJavaClassBuilder;

  procedure Method(const Name, Desc: string; abstract: Boolean);
  begin
    var M := B.JavaClass.AddNative(Name, Desc);
    if abstract then
      M.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure ConnectionMethods(abstract: Boolean);
  begin
    for var Name in ['getAddress', 'getLocalAddress'] do
      Method(Name, '()Ljava/lang/String;', abstract);
    for var Name in ['getPort', 'getLocalPort'] do
      Method(Name, '()I', abstract);
    Method('getSocketOption', '(B)I', abstract);
    Method('setSocketOption', '(BI)V', abstract);
  end;

  procedure ListenerMethods(abstract: Boolean);
  begin
    Method('getLocalAddress', '()Ljava/lang/String;', abstract);
    Method('getLocalPort', '()I', abstract);
    if not abstract then
    begin
      Method('acceptAndOpen', '()Ljavax/microedition/io/StreamConnection;', False);
      Method('close', '()V', False);
    end;
  end;

  procedure Finish;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

begin
  B := TJavaClassBuilder.Create(API, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
  try
    B.JavaClass.Interfaces := ['javax/microedition/io/StreamConnection'];
    ConnectionMethods(True);
    for var I := Low(OptionNames) to High(OptionNames) do
    begin
      B.Field(OptionNames[I], 'B', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
    end;
    Finish;
    B := TJavaClassBuilder.Create(ConnectionClass, 'java/lang/Object');
    B.JavaClass.Interfaces := [API];
    ConnectionMethods(False);
    Method('close', '()V', False);
    for var Direction in ['Input', 'Output'] do
    begin
      var Stream := 'Ljava/io/' + Direction + 'Stream;';
      var Wrapper := 'java/io/Data' + Direction + 'Stream';
      var Factory := 'open' + Direction + 'Stream';
      Method(Factory, '()' + Stream, False);
      B.Start;
      B.Ref($BB, B.ClassRef(Wrapper));
      B.Emit([$59, $2A]); // dup; aload_0
      B.Ref($B6, B.Member(ConnectionClass, Factory, '()' + Stream));
      B.Ref($B7, B.Member(Wrapper, '<init>', '(' + Stream + ')V'));
      B.Emit([$B0]); // areturn
      B.Finish('openData' + Direction + 'Stream', '()L' + Wrapper + ';', JVM_ACC_PUBLIC, 3, 1);
    end;
    Finish;
    B := TJavaClassBuilder.Create(ListenerAPI, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.Interfaces := ['javax/microedition/io/StreamConnectionNotifier'];
    ListenerMethods(True);
    Finish;
    B := TJavaClassBuilder.Create(ListenerClass, 'java/lang/Object');
    B.JavaClass.Interfaces := [ListenerAPI];
    ListenerMethods(False);
    Finish;
    B := TJavaClassBuilder.Create(InputClass, 'java/io/InputStream');
    Method('read', '()I', False);
    Method('read', '([BII)I', False);
    Method('available', '()I', False);
    Method('close', '()V', False);
    Finish;
    B := TJavaClassBuilder.Create(OutputClass, 'java/io/OutputStream');
    B.JavaClass.AddNative('write', '(I)V').Access := JVM_ACC_NATIVE or JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('write', '([BII)V').Access := JVM_ACC_NATIVE or JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED;
    Method('flush', '()V', False);
    Method('close', '()V', False);
    Finish;
  finally
    B.Free;
  end;
end;

function TJ2METCP.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = ConnectionClass) or (Owner = ListenerClass) or
    (Owner = InputClass) or (Owner = OutputClass);
end;

procedure TJ2METCP.Wait;
begin
  FVM.SleepCurrent(5, 'java/io/InterruptedIOException');
  FVM.RetryNative;
end;

function TJ2METCP.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
begin
  var State := FVM.NativeContinuation;
  var Ref: Integer;
  var Job: IJ2METCPDial;
  var Marker: TJVMObject;
  if State.Kind = TJVMKind.Empty then
  begin
    if not URL.StartsWith('socket://', True) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid socket URL');
    var Endpoint := Copy(URL, Length('socket://') + 1, MaxInt);
    RequireCapacity;
    if Endpoint = '' then
      Exit(OpenListener(0, Mode, Timeouts));
    var Separator := Pos(':', Endpoint);
    var PortText := Copy(Endpoint, Separator + 1, MaxInt);
    for var Ch in PortText do
      if not CharInSet(Ch, ['0'..'9']) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid socket port');
    var Port: Integer;
    if (Separator = 0) or not TryStrToInt(PortText, Port) or (Port < 0) or (Port > 65535) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid socket URL');
    if Separator = 1 then
      Exit(OpenListener(Word(Port), Mode, Timeouts));
    if Port = 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid TCP destination port');
    var Host := Copy(Endpoint, 1, Separator - 1);
    for var Ch in Host do
      if not CharInSet(Ch, ['0'..'9', 'A'..'Z', 'a'..'z', '.', '-', '_']) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid socket host');
    try
      Job := StartDial(Host, Word(Port));
    except
      on E: Exception do
        FVM.RaiseJava('java/io/IOException', E.Message);
    end;
    Ref := FVM.NewObject('java/lang/Object');
    Marker := FVM.GetObject(Ref);
    Marker.Fields.Add('$tcp.deadline', TJVMValue.Long(FVM.Host.MonotonicMillis + ConnectTimeout));
    FDials.Add(Ref, Job);
    FVM.SetNativeContinuation(TJVMValue.Ref(Ref));
  end
  else
  begin
    Ref := State.AsRef;
    Marker := FVM.GetObject(Ref);
    if not FDials.TryGetValue(Ref, Job) then
      FVM.RaiseJava('java/io/InterruptedIOException', 'TCP connection interrupted');
  end;
  var Socket: System.Net.Socket.TSocket := nil;
  var Error: string;
  if not Job.TryTake(Socket, Error) then
  begin
    if FVM.Host.MonotonicMillis >= Marker.Fields['$tcp.deadline'].AsLong then
    begin
      if Timeouts then
        FVM.RaiseJava('java/io/InterruptedIOException', 'TCP connection timed out');
      FVM.RaiseJava('java/io/IOException', 'TCP connection timed out');
    end;
    Wait;
    Exit(0);
  end;
  FDials.Remove(Ref);
  if Error <> '' then
    FVM.RaiseJava('java/io/IOException', Error);
  Result := RegisterSocket(Socket, Mode, Timeouts);
end;

procedure TJ2METCP.RequireCapacity;
begin
  if FConnections.Count + FDials.Count + FListeners.Count >= ConnectionLimit then
    FVM.RaiseJava('java/io/IOException', 'TCP connection capacity');
end;

function TJ2METCP.RegisterSocket(Socket: System.Net.Socket.TSocket; Mode: Integer; Timeouts: Boolean): Integer;
begin
  var C := TJ2METCPConnection.Create;
  try
    C.Socket := Socket;
    C.Mode := Mode;
    C.Timeouts := Timeouts;
    Result := FVM.NewObject(ConnectionClass);
    FConnections.Add(Result, C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2METCP.OpenListener(Port: Word; Mode: Integer; Timeouts: Boolean): Integer;
begin
  var Listener := TJ2METCPListeningConnection.Create;
  try
    try
      Listener.Socket := TJ2METCPListener.Create(TSocketType.TCP);
      Listener.Socket.Listen(TNetEndpoint.Create(TIPAddress.Any, Port));
      SetNonblocking(Listener.Socket.Handle, True);
    except
      on E: ESocketError do
        FVM.RaiseJava('java/io/IOException', E.Message);
    end;
    Listener.Mode := Mode;
    Listener.Timeouts := Timeouts;
    Result := FVM.NewObject(ListenerClass);
    FListeners.Add(Result, Listener);
    Listener := nil;
  finally
    Listener.Free;
  end;
end;

function TJ2METCP.InvokeListener(const Name: string; Ref: Integer): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Name = 'close' then
  begin
    FListeners.Remove(Ref);
    Exit;
  end;
  var State := FVM.NativeContinuation;
  var Listener: TJ2METCPListeningConnection;
  if not FListeners.TryGetValue(Ref, Listener) then
  begin
    if (Name = 'acceptAndOpen') and (State.Kind <> TJVMKind.Empty) then
      FVM.RaiseJava('java/io/InterruptedIOException', 'TCP listener closed while accepting');
    FVM.RaiseJava('java/io/IOException', 'TCP listener closed');
  end;
  if Name = 'getLocalPort' then
    Exit(TJVMValue.Int(Listener.Socket.LocalPort));
  if Name = 'getLocalAddress' then
    Exit(TJVMValue.Ref(FVM.NewString(Listener.Socket.LocalAddress)));
  RequireCapacity;
  var Accepted := Listener.Socket.TryAccept;
  if Accepted <> nil then
    Exit(TJVMValue.Ref(RegisterSocket(Accepted, Listener.Mode, Listener.Timeouts)));
  if State.Kind = TJVMKind.Empty then
    FVM.SetNativeContinuation(TJVMValue.Long(FVM.Host.MonotonicMillis + IOTimeout))
  else if Listener.Timeouts and (FVM.Host.MonotonicMillis >= State.AsLong) then
    FVM.RaiseJava('java/io/InterruptedIOException', 'TCP accept timed out');
  Wait;
end;

function TJ2METCP.OpenStream(Ref: Integer; C: TJ2METCPConnection; Reading: Boolean): Integer;
begin
  if Reading then
  begin
    if ((C.Mode and 1) = 0) or C.InputOpened then
      FVM.RaiseJava('java/io/IOException', 'TCP input stream unavailable');
    Result := FVM.NewObject(InputClass);
    C.InputOpened := True;
    C.InputRef := Result;
  end
  else
  begin
    if ((C.Mode and 2) = 0) or C.OutputOpened then
      FVM.RaiseJava('java/io/IOException', 'TCP output stream unavailable');
    Result := FVM.NewObject(OutputClass);
    C.OutputOpened := True;
    C.OutputRef := Result;
  end;
  FVM.GetObject(Result).Fields.Add(ConnectionKey, TJVMValue.Ref(Ref));
end;

procedure TJ2METCP.InterruptWrite(const MessageText: string; Transferred: Integer);
begin
  try
    FVM.RaiseJava('java/io/InterruptedIOException', MessageText);
  except
    on E: EJVMThrown do
    begin
      FVM.GetObject(E.Reference).Fields.AddOrSetValue(
          'java/io/InterruptedIOException.bytesTransferred:I', TJVMValue.Int(Transferred));
      raise;
    end;
  end;
end;

procedure TJ2METCP.WriteStream(C: TJ2METCPConnection; Ref: Integer; Data: TJVMObject; Offset, Count, Value: Integer);
var
  Buffer: array[0..BlockSize - 1] of Byte;
  Transferred: Integer;
  Error: string;
begin
  var State := FVM.NativeContinuation;
  var Processed := 0;
  if State.Kind = TJVMKind.Empty then
    C.WriteDeadline := FVM.Host.MonotonicMillis + IOTimeout
  else
    Processed := State.AsInt;

  if (C.Writer <> nil) and C.Writer.TryFinish(Transferred, Error) then
  begin
    if Error <> '' then
      FVM.RaiseJava('java/io/IOException', Error);
    Inc(Processed, Max(Transferred, 0));
  end;
  var Interrupted := FVM.ClearInterrupted;
  var TimedOut := C.Timeouts and (FVM.Host.MonotonicMillis >= C.WriteDeadline);
  if Interrupted or (TimedOut and (Processed < Count)) then
  begin
    if (C.Writer <> nil) and C.Writer.Pending then
    begin
      // Stop the current host write before reporting an incomplete Java write.
      Inc(Processed, C.CloseOutput);
      ReleaseClosed(Ref, C);
    end;
    if Interrupted then
      InterruptWrite('TCP write interrupted', Processed);
    InterruptWrite('TCP write timed out', Processed);
  end;
  if Processed = Count then
    Exit;

  if C.Writer = nil then
  begin
    C.Writer := TJ2METCPWriter.Create(C.Socket);
    C.Writer.Start;
  end;
  if not C.Writer.Pending then
  begin
    var Block := Min(Count - Processed, Length(Buffer));
    if Data = nil then
      Buffer[0] := Byte(Value)
    else
      for var I := 0 to Block - 1 do
        Buffer[I] := Byte(Data.ElementValues[Offset + Processed + I].AsInt);
    C.Writer.Submit(Buffer, Block);
  end;
  FVM.SetNativeContinuation(TJVMValue.Int(Processed));
  FVM.SleepCurrent(1, 'java/io/InterruptedIOException', True);
  FVM.RetryNative;
end;

function TJ2METCP.StreamCall(C: TJ2METCPConnection; Ref: Integer; Reading: Boolean; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Buffer: array[0..BlockSize - 1] of Byte;
  Data: TJVMObject;
  Offset, Count, Transferred: Integer;
begin
  Result := Default(TJVMValue);
  var N := Method.Name;
  var StreamRef := Args[0].AsRef;
  var Open := (C <> nil) and ((Reading and (C.InputRef = StreamRef)) or
    ((not Reading) and (C.OutputRef = StreamRef)));
  if N = 'close' then
  begin
    if Open then
    begin
      // Shutdown only the closed half. The other stream may still be live,
      // even after the MIDlet has closed its connection handle.
      if Reading then
      begin
        shutdown(C.Socket.Handle, 0);
        FreeAndNil(C.Reader);
        C.InputRef := 0;
      end
      else
      begin
        var TransferredOnClose := C.CloseOutput;
        if TransferredOnClose <> 0 then
          FVM.GetObject(StreamRef).Fields.AddOrSetValue('$tcp.closedWriteBytes',
              TJVMValue.Int(TransferredOnClose));
      end;
      ReleaseClosed(Ref, C);
    end;
    Exit;
  end;
  if not Open then
  begin
    var Progress := FVM.NativeContinuation;
    if Progress.Kind <> TJVMKind.Empty then
    begin
      if not Reading then
      begin
        var TransferredOnClose: TJVMValue;
        var TransferredBytes := Progress.AsInt;
        if FVM.GetObject(StreamRef).Fields.TryGetValue('$tcp.closedWriteBytes', TransferredOnClose) then
          Inc(TransferredBytes, TransferredOnClose.AsInt);
        InterruptWrite('TCP stream closed during transfer', TransferredBytes);
      end;
      FVM.RaiseJava('java/io/InterruptedIOException', 'TCP stream closed during transfer');
    end;
    FVM.RaiseJava('java/io/IOException', 'TCP stream closed');
  end;
  if N = 'flush' then
    Exit;
  if N = 'available' then
  begin
    var Ready := C.Socket.Receive(Buffer[0], -1);
    if C.Reader <> nil then
      Inc(Ready, C.Reader.Available);
    Exit(TJVMValue.Int(Ready));
  end;
  Offset := 0;
  Count := 1;
  Data := nil;
  var Bulk := (Method.Descriptor = '([BII)I') or (Method.Descriptor = '([BII)V');
  if Bulk then
  begin
    Data := FVM.GetObject(Args[1].AsRef);
    Offset := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Length(Data.Elements) - Count) then
      FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
    if Count = 0 then
      Exit(TJVMValue.Int(0));
  end;
  if not Reading then
  begin
    var Value := 0;
    if not Bulk then
      Value := Args[1].AsInt;
    WriteStream(C, Ref, Data, Offset, Count, Value);
    Exit;
  end;
  var State := FVM.NativeContinuation;
  try
    if C.Reader = nil then
    begin
      C.Reader := TJ2METCPReader.Create(C.Socket);
      C.Reader.Start;
    end;
    var Error: string;
    if not C.Reader.TryRead(Buffer, Min(Count, Length(Buffer)), Transferred, Error) then
      Transferred := -1
    else if Error <> '' then
      FVM.RaiseJava('java/io/IOException', Error);
    if Transferred = 0 then
      Exit(TJVMValue.Int(-1));
    if Transferred > 0 then
    begin
      if not Bulk then
        Exit(TJVMValue.Int(Buffer[0]));
      for var I := 0 to Transferred - 1 do
        Data.ElementValues[Offset + I] := TJVMValue.Int(ShortInt(Buffer[I]));
      Exit(TJVMValue.Int(Transferred));
    end;
  except
    on E: ESocketError do
      if not IsRetryable(E.Code) then
        raise;
  end;
  if State.Kind = TJVMKind.Empty then
    FVM.SetNativeContinuation(TJVMValue.Long(FVM.Host.MonotonicMillis + IOTimeout))
  else if C.Timeouts and (FVM.Host.MonotonicMillis >= State.AsLong) then
    FVM.RaiseJava('java/io/InterruptedIOException', 'TCP read timed out');
  Wait;
end;

function TJ2METCP.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var N := Method.Name;
  var Owner := Method.Owner.Name;
  if Owner = ListenerClass then
  begin
    try
      Exit(InvokeListener(N, Args[0].AsRef));
    except
      on E: ESocketError do
        FVM.RaiseJava('java/io/IOException', E.Message);
    end;
  end;
  var Ref := Args[0].AsRef;
  if Owner <> ConnectionClass then
    Ref := FVM.GetObject(Ref).Fields[ConnectionKey].AsRef;
  var C: TJ2METCPConnection;
  FConnections.TryGetValue(Ref, C);
  try
    if Owner <> ConnectionClass then
      Exit(StreamCall(C, Ref, Owner = InputClass, Method, Args));
    if N = 'close' then
    begin
      if C <> nil then
      begin
        C.Closed := True;
        ReleaseClosed(Ref, C);
      end;
      Exit;
    end;
    if (C = nil) or C.Closed then
      FVM.RaiseJava('java/io/IOException', 'TCP connection closed');
    if N = 'openInputStream' then
      Exit(TJVMValue.Ref(OpenStream(Ref, C, True)));
    if N = 'openOutputStream' then
      Exit(TJVMValue.Ref(OpenStream(Ref, C, False)));
    if N = 'getAddress' then
      Exit(TJVMValue.Ref(FVM.NewString(C.Socket.RemoteAddress)));
    if N = 'getLocalAddress' then
      Exit(TJVMValue.Ref(FVM.NewString(C.Socket.LocalAddress)));
    if N = 'getPort' then
      Exit(TJVMValue.Int(C.Socket.RemotePort));
    if N = 'getLocalPort' then
      Exit(TJVMValue.Int(C.Socket.LocalPort));
    var Option := Args[1].AsInt;
    if not (Option in [0..4]) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Unknown TCP socket option');
    var Level := SOL_SOCKET;
    var Code: Integer;
    case Option of
      0:
        begin
          Level := IPPROTO_TCP;
          Code := TCP_NODELAY;
        end;
      1:
        Code := SO_LINGER;
      2:
        Code := SO_KEEPALIVE;
      3:
        Code := SO_RCVBUF;
    else
      Code := SO_SNDBUF;
    end;
    var Storage: Integer := 0;
    var LingerOpt: linger := Default(linger);
    var ValueAddress: Pointer := @Storage;
    {$IFDEF MSWINDOWS}
    var Size: Integer := SizeOf(Storage);
    {$ELSE}
    var Size: socklen_t := SizeOf(Storage);
    {$ENDIF}
    if Option = 1 then
    begin
      ValueAddress := @LingerOpt;
      Size := SizeOf(LingerOpt);
    end;
    if N = 'getSocketOption' then
    begin
      {$IFDEF MSWINDOWS}
      if getsockopt(C.Socket.Handle, Level, Code, MarshaledAString(ValueAddress), Size) <> 0 then
      {$ELSE}
        if getsockopt(C.Socket.Handle, Level, Code, ValueAddress^, Size) <> 0 then
      {$ENDIF}
          FVM.RaiseJava('java/io/IOException', 'Cannot read TCP socket option');
      if (Option = 1) and (LingerOpt.l_onoff <> 0) then
        Storage := LingerOpt.l_linger
      else if Option = 0 then
        Storage := Ord(Storage = 0);
      Exit(TJVMValue.Int(Storage));
    end;
    var Value := Args[2].AsInt;
    if (Value < 0) or ((Option = 1) and (Value > High(Word))) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid TCP socket option value');
    Storage := Value;
    case Option of
      0:
        Storage := Ord(Value = 0); // MIDP DELAY is the inverse of TCP_NODELAY.
        1:
        begin
          LingerOpt.l_onoff := Ord(Value <> 0);
          LingerOpt.l_linger := Word(Value);
        end;
      2:
        Storage := Ord(Value <> 0);
    end;
    {$IFDEF MSWINDOWS}
    if setsockopt(C.Socket.Handle, Level, Code, MarshaledAString(ValueAddress), Size) <> 0 then
    {$ELSE}
      if setsockopt(C.Socket.Handle, Level, Code, ValueAddress^, Size) <> 0 then
    {$ENDIF}
        FVM.RaiseJava('java/io/IOException', 'Cannot set TCP socket option');
    if Option = 1 then
      C.LingerEnabled := Value <> 0;
  except
    on E: ESocketError do
      FVM.RaiseJava('java/io/IOException', E.Message);
  end;
end;

end.

