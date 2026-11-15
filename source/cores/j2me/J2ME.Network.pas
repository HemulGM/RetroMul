unit J2ME.Network;

interface

uses
  System.SysUtils, System.Generics.Collections, System.Net.URLClient, JVM.Types,
  JVM.ClassFile, JVM.Runtime, J2ME.Network.HTTP;

type
  TJ2MEHTTPConnection = class
  public
    Ref, Mode, Port, InputRef, OutputRef, Position: Integer;
    URL, TransportURL, Host, FilePart, Query, Fragment, RequestMethod: string;
    HasFile, HasQuery, HasFragment: Boolean;
    Closed, InputOpened, OutputOpened, OutputClosing, Timeouts: Boolean;
    Headers: TNetHeaders;
    Body: TBytes;
    Job: TJ2MEHTTPJob;
    destructor Destroy; override;
  end;

  TJ2MENetwork = class
  private
    FVM: TJVM;
    FProtocolOpen: TFunc<string, Integer, Boolean, Integer>;
    FConnections: TObjectDictionary<Integer, TJ2MEHTTPConnection>;
    FRetired: TObjectList<TJ2MEHTTPJob>;
    procedure Retire(Connection: TJ2MEHTTPConnection);
    procedure ReleaseClosed(Connection: TJ2MEHTTPConnection);
    function Ready(Connection: TJ2MEHTTPConnection): Boolean;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    function OpenStream(Connection: TJ2MEHTTPConnection; Reading: Boolean): Integer;
  public
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    // -1 means unhandled;0 is a handled call that yielded and requested retry.
    property ProtocolOpen: TFunc<string, Integer, Boolean, Integer> read FProtocolOpen write FProtocolOpen;
    procedure Install;
    procedure Collect;
    procedure Stop;
    function Handles(Method: TJVMMethod): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  end;

implementation

uses
  System.Math, System.DateUtils, Java.Classes, JVM.Threading;

{$Q-}{$R-}

const
  IO = 'javax/microedition/io/';
  Factory = IO + 'Connector';
  HTTP = IO + 'HttpConnection';
  ImplementationName = Factory + '$HTTP';
  InputName = Factory + '$Input';
  OutputName = Factory + '$Output';
  ConnectionKey = '$network.connection';
  ClosedKey = '$network.closed';
  NetworkLimit = 8 * 1024 * 1024;

function IntegerField(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsInt;
end;

function HTTPDate(const Text: string; Default: Int64): Int64;
var
  D, M, Y, H, N, S: Integer;
  DateParts, TimeParts, Words: TArray<string>;
  Value, DateText, TimeText, MonthText: string;
  Stamp: TDateTime;
const
  Months: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
begin
  Result := Default;
  Value := Text.Trim;
  if Value = '' then
    Exit;
  var Comma := Pos(',', Value);
  if Comma > 0 then
  begin
    Value := Copy(Value, Comma + 1, MaxInt).Trim;
    Words := Value.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Words) = 3) and ((Words[2] = 'GMT') or (Words[2] = 'UTC')) then
    begin
      DateParts := Words[0].Split(['-']);
      if Length(DateParts) <> 3 then
        Exit;
      DateText := DateParts[0];
      MonthText := DateParts[1];
      if not TryStrToInt(DateParts[2], Y) then
        Exit;
      if Length(DateParts[2]) = 2 then
      begin
        if Y >= 70 then
          Inc(Y, 1900)
        else
          Inc(Y, 2000);
      end;
      TimeText := Words[1];
    end
    else
    begin
      if (Length(Words) <> 5) or ((Words[4] <> 'GMT') and (Words[4] <> 'UTC')) then
        Exit;
      DateText := Words[0];
      MonthText := Words[1];
      TimeText := Words[3];
      if not TryStrToInt(Words[2], Y) then
        Exit;
    end;
  end
  else
  begin
    Words := Value.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if Length(Words) <> 5 then
      Exit;
    DateText := Words[2];
    MonthText := Words[1];
    TimeText := Words[3];
    if not TryStrToInt(Words[4], Y) then
      Exit;
  end;
  M := 0;
  for var I := 1 to 12 do
    if SameText(MonthText, Months[I]) then
      M := I;
  TimeParts := TimeText.Split([':']);
  if Length(TimeParts) <> 3 then
    Exit;
  if not TryStrToInt(DateText, D) or not TryStrToInt(TimeParts[0], H) or not TryStrToInt(TimeParts[1], N) or not TryStrToInt(TimeParts[2], S) then
    Exit;
  if (Y < 1) or (Y > 9999) or (M = 0) or (D < 1) or (D > 31) or (H < 0) or (H > 23) or (N < 0) or (N > 59) or (S < 0) or (S > 59) then
    Exit;
  if TryEncodeDate(Y, M, D, Stamp) then
  begin
    Stamp := Stamp + EncodeTime(H, N, S, 0);
    Result := DateTimeToUnix(Stamp, True) * 1000;
  end;
end;

function Header(const Headers: TNetHeaders; const Name: string; out Value: string): Boolean;
begin
  for var I := High(Headers) downto 0 do
    if SameText(Headers[I].Name, Name) then
    begin
      Value := Headers[I].Value;
      Exit(True);
    end;
  Value := '';
  Result := False;
end;

function HTTPInteger(const Text: string; Signed: Boolean; out Value: Int64): Boolean;
begin
  var S := Text.Trim;
  Result := False;
  if S = '' then
    Exit;
  var First := 1;
  if Signed and CharInSet(S[1], ['+', '-']) then
    Inc(First);
  if First > Length(S) then
    Exit;
  for var I := First to Length(S) do
    if not CharInSet(S[I], ['0'..'9']) then
      Exit;
  Result := TryStrToInt64(S, Value);
end;

destructor TJ2MEHTTPConnection.Destroy;
begin
  Job.Free;
  inherited;
end;

constructor TJ2MENetwork.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
  FConnections := TObjectDictionary<Integer, TJ2MEHTTPConnection>.Create([doOwnsValues]);
  FRetired := TObjectList<TJ2MEHTTPJob>.Create(True);
end;

destructor TJ2MENetwork.Destroy;
begin
  Stop;
  FConnections.Free;
  FRetired.Free;
  inherited;
end;

procedure TJ2MENetwork.Stop;
begin
  for var C in FConnections.Values do
    if C.Job <> nil then
      C.Job.Cancel;
  for var Job in FRetired do
    Job.Cancel;
end;

procedure TJ2MENetwork.Retire(Connection: TJ2MEHTTPConnection);
begin
  if Connection.Job = nil then
    Exit;
  Connection.Job.Cancel;
  FRetired.Add(Connection.Job);
  Connection.Job := nil;
end;

procedure TJ2MENetwork.ReleaseClosed(Connection: TJ2MEHTTPConnection);
begin
  if Connection.Closed and (Connection.InputRef = 0) and (Connection.OutputRef = 0) then
  begin
    Retire(Connection);
    Connection.Body := nil;
  end;
end;

procedure TJ2MENetwork.Collect;
begin
  for var I := FRetired.Count - 1 downto 0 do
    if FRetired[I].Done then
      FRetired.Delete(I);
  for var Ref in FConnections.Keys.ToArray do
  begin
    var C := FConnections[Ref];
    if not FVM.IsObjectAlive(Ref) then
    begin
      Retire(C);
      FConnections.Remove(Ref);
    end
    else
    begin
      if not FVM.IsObjectAlive(C.InputRef) then
        C.InputRef := 0;
      if not FVM.IsObjectAlive(C.OutputRef) then
        C.OutputRef := 0;
      ReleaseClosed(C);
    end;
  end;
end;

procedure TJ2MENetwork.Install;
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

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure InterfaceClass(const Name: string; const Parents: TArray<string>);
  begin
    B := TJavaClassBuilder.Create(IO + Name, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.Interfaces := Parents;
  end;

  procedure StreamFactories;
  begin
    for var Reading in [False, True] do
    begin
      var Direction := 'Output';
      if Reading then
        Direction := 'Input';
      Native('open' + Direction + 'Stream', '()Ljava/io/' + Direction + 'Stream;');
      var Wrapper := 'java/io/Data' + Direction + 'Stream';
      B.Start;
      B.Ref($BB, B.ClassRef(Wrapper));
      B.Emit([$59, $2A]);
      B.Ref($B6, B.Member(ImplementationName, 'open' + Direction + 'Stream', '()Ljava/io/' + Direction + 'Stream;'));
      B.Ref($B7, B.Member(Wrapper, '<init>', '(Ljava/io/' + Direction + 'Stream;)V'));
      B.Emit([$B0]);
      B.Finish('openData' + Direction + 'Stream', '()L' + Wrapper + ';', JVM_ACC_PUBLIC, 3, 1);
    end;
  end;

  procedure HTTPMethods(abstract: Boolean);

    procedure Method(const Name, Desc: string);
    begin
      if abstract then
        AbstractMethod(Name, Desc)
      else
        Native(Name, Desc);
    end;

  begin
    for var N in ['getURL', 'getProtocol', 'getHost', 'getFile', 'getRef', 'getQuery', 'getRequestMethod', 'getResponseMessage', 'getType', 'getEncoding'] do
      Method(N, '()Ljava/lang/String;');
    for var N in ['getPort', 'getResponseCode'] do
      Method(N, '()I');
    for var N in ['getLength', 'getDate', 'getExpiration', 'getLastModified'] do
      Method(N, '()J');
    Method('setRequestMethod', '(Ljava/lang/String;)V');
    Method('setRequestProperty', '(Ljava/lang/String;Ljava/lang/String;)V');
    Method('getRequestProperty', '(Ljava/lang/String;)Ljava/lang/String;');
    Method('getHeaderField', '(Ljava/lang/String;)Ljava/lang/String;');
    Method('getHeaderField', '(I)Ljava/lang/String;');
    Method('getHeaderFieldKey', '(I)Ljava/lang/String;');
    Method('getHeaderFieldInt', '(Ljava/lang/String;I)I');
    Method('getHeaderFieldDate', '(Ljava/lang/String;J)J');
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(IO + 'ConnectionNotFoundException', 'java/io/IOException');
    Native('<init>', '()V');
    Native('<init>', '(Ljava/lang/String;)V');
    Done;
    B := TJavaClassBuilder.Create('java/io/InterruptedIOException', 'java/io/IOException');
    B.Field('bytesTransferred', 'I', JVM_ACC_PUBLIC);
    Native('<init>', '()V');
    Native('<init>', '(Ljava/lang/String;)V');
    Done;
    InterfaceClass('Connection', []);
    AbstractMethod('close', '()V');
    Done;
    InterfaceClass('InputConnection', [IO + 'Connection']);
    AbstractMethod('openInputStream', '()Ljava/io/InputStream;');
    AbstractMethod('openDataInputStream', '()Ljava/io/DataInputStream;');
    Done;
    InterfaceClass('OutputConnection', [IO + 'Connection']);
    AbstractMethod('openOutputStream', '()Ljava/io/OutputStream;');
    AbstractMethod('openDataOutputStream', '()Ljava/io/DataOutputStream;');
    Done;
    InterfaceClass('StreamConnection', [IO + 'InputConnection', IO + 'OutputConnection']);
    Done;
    InterfaceClass('StreamConnectionNotifier', [IO + 'Connection']);
    AbstractMethod('acceptAndOpen', '()Ljavax/microedition/io/StreamConnection;');
    Done;
    InterfaceClass('ContentConnection', [IO + 'StreamConnection']);
    AbstractMethod('getType', '()Ljava/lang/String;');
    AbstractMethod('getEncoding', '()Ljava/lang/String;');
    AbstractMethod('getLength', '()J');
    Done;
    InterfaceClass('HttpConnection', [IO + 'ContentConnection']);
    HTTPMethods(True);
    for var Method in ['GET', 'POST', 'HEAD'] do
    begin
      B.Field(Method, 'Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Ref(FVM.InternString(Method));
    end;
    var Codes := 'HTTP_OK=200 HTTP_CREATED=201 HTTP_ACCEPTED=202 HTTP_NOT_AUTHORITATIVE=203 HTTP_NO_CONTENT=204 HTTP_RESET=205 HTTP_PARTIAL=206 ' +
      'HTTP_MULT_CHOICE=300 HTTP_MOVED_PERM=301 HTTP_MOVED_TEMP=302 HTTP_SEE_OTHER=303 HTTP_NOT_MODIFIED=304 HTTP_USE_PROXY=305 HTTP_TEMP_REDIRECT=307 ' +
      'HTTP_BAD_REQUEST=400 HTTP_UNAUTHORIZED=401 HTTP_PAYMENT_REQUIRED=402 HTTP_FORBIDDEN=403 HTTP_NOT_FOUND=404 HTTP_BAD_METHOD=405 HTTP_NOT_ACCEPTABLE=406 HTTP_PROXY_AUTH=407 HTTP_CLIENT_TIMEOUT=408 HTTP_CONFLICT=409 HTTP_GONE=410 HTTP_LENGTH_REQUIRED=411 ' +
      'HTTP_PRECON_FAILED=412 HTTP_ENTITY_TOO_LARGE=413 HTTP_REQ_TOO_LONG=414 HTTP_UNSUPPORTED_TYPE=415 HTTP_UNSUPPORTED_RANGE=416 HTTP_EXPECT_FAILED=417 HTTP_INTERNAL_ERROR=500 HTTP_NOT_IMPLEMENTED=501 HTTP_BAD_GATEWAY=502 HTTP_UNAVAILABLE=503 HTTP_GATEWAY_TIMEOUT=504 HTTP_VERSION=505';
    for var Pair in Codes.Split([' ']) do
    begin
      var P := Pair.Split(['=']);
      B.Field(P[0], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(StrToInt(P[1]));
    end;
    Done;
    B := TJavaClassBuilder.Create(ImplementationName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [HTTP];
    Native('close', '()V');
    StreamFactories;
    HTTPMethods(False);
    Done;
    B := TJavaClassBuilder.Create(InputName, 'java/io/InputStream', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    for var N in ['read', 'available'] do
      Native(N, '()I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('read', '([BII)I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('skip', '(J)J', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('close', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Done;
    B := TJavaClassBuilder.Create(OutputName, 'java/io/OutputStream', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Native('write', '(I)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('write', '([BII)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('flush', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('close', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Done;
    B := TJavaClassBuilder.Create(Factory, 'java/lang/Object');
    for var I := 1 to 3 do
    begin
      var N := 'READ_WRITE';
      if I = 1 then
        N := 'READ'
      else if I = 2 then
        N := 'WRITE';
      B.Field(N, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
    end;
    for var Desc in ['(Ljava/lang/String;)L', '(Ljava/lang/String;I)L', '(Ljava/lang/String;IZ)L'] do
      Native('open', Desc + IO + 'Connection;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    for var Reading in [False, True] do
    begin
      var Direction := 'Output';
      var Mode := 2;
      if Reading then
      begin
        Direction := 'Input';
        Mode := 1;
      end;
      var API := IO + Direction + 'Connection';
      var Stream := 'java/io/' + Direction + 'Stream';
      B.Start;
      B.Emit([$2A, Byte($03 + Mode)]);
      B.Ref($B8, B.Member(Factory, 'open', '(Ljava/lang/String;I)L' + IO + 'Connection;'));
      B.Emit([$4C]);
      B.Mark('try');
      B.Emit([$2B]);
      B.Ref($C0, B.ClassRef(API));
      B.Ref($B9, B.Member(API, 'open' + Direction + 'Stream', '()L' + Stream + ';', 11));
      B.Emit([$01, $00, $4D]);
      B.Mark('end');
      B.Emit([$2B]);
      B.Ref($B9, B.Member(IO + 'Connection', 'close', '()V', 11));
      B.Emit([$01, $00, $2C, $B0]);
      B.Mark('catch');
      B.Emit([$4D, $2B]);
      B.Ref($B9, B.Member(IO + 'Connection', 'close', '()V', 11));
      B.Emit([$01, $00, $2C, $BF]);
      B.Finish('open' + Direction + 'Stream', '(Ljava/lang/String;)L' + Stream + ';', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 2, 3);
      var M := B.JavaClass.Methods.Last;
      var H: TJVMExceptionHandler;
      H.StartPC := B.Position('try');
      H.EndPC := B.Position('end');
      H.HandlerPC := B.Position('catch');
      H.CatchType := 0;
      M.Handlers := [H];
      var Wrapper := 'java/io/Data' + Direction + 'Stream';
      B.Start;
      B.Ref($BB, B.ClassRef(Wrapper));
      B.Emit([$59, $2A]);
      B.Ref($B8, B.Member(Factory, 'open' + Direction + 'Stream', '(Ljava/lang/String;)L' + Stream + ';'));
      B.Ref($B7, B.Member(Wrapper, '<init>', '(L' + Stream + ';)V'));
      B.Emit([$B0]);
      B.Finish('openData' + Direction + 'Stream', '(Ljava/lang/String;)L' + Wrapper + ';', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 3, 1);
    end;
    Done;
  finally
    B.Free;
  end;
end;

function TJ2MENetwork.Handles(Method: TJVMMethod): Boolean;
begin
  Result := (Method.Owner.Name = Factory) or (Method.Owner.Name = ImplementationName) or (Method.Owner.Name = InputName) or (Method.Owner.Name = OutputName);
end;

function TJ2MENetwork.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
var
  C: TJ2MEHTTPConnection;
  Authority, PortText, Rest: string;
  P, EndHost: Integer;

  procedure Invalid;
  begin
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid connection URL');
  end;

begin
  if not (Mode in [1, 2, 3]) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Connection mode');
  if Length(URL) > 16384 then
    FVM.RaiseJava('java/io/IOException', 'URL capacity');
  P := Pos(':', URL);
  if P <= 1 then
    Invalid;
  for var I := 1 to P - 1 do
    if not CharInSet(URL[I], ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.']) or ((I = 1) and not CharInSet(URL[I], ['a'..'z', 'A'..'Z'])) then
      Invalid;
  if not SameText(Copy(URL, 1, P - 1), 'http') then
  begin
    if Assigned(FProtocolOpen) then
    begin
      Result := FProtocolOpen(URL, Mode, Timeouts);
      if Result >= 0 then
        Exit;
    end;
    FVM.RaiseJava(IO + 'ConnectionNotFoundException', 'Unsupported protocol');
  end;
  for var Ch in URL do
    if (Ord(Ch) <= 32) or (Ord(Ch) = 127) then
      Invalid;
  Rest := Copy(URL, P + 1, MaxInt);
  if not Rest.StartsWith('//') then
    Invalid;
  Delete(Rest, 1, 2);
  P := 1;
  while (P <= Length(Rest)) and not CharInSet(Rest[P], ['/', '?', '#']) do
    Inc(P);
  Authority := Copy(Rest, 1, P - 1);
  Rest := Copy(Rest, P, MaxInt);
  if (Authority = '') or Authority.Contains('@') or Authority.Contains('\') then
    Invalid;
  C := TJ2MEHTTPConnection.Create;
  try
    C.Port := 80;
    C.Mode := Mode;
    C.Timeouts := Timeouts;
    C.URL := URL;
    C.RequestMethod := 'GET';
    if Authority.StartsWith('[') then
    begin
      EndHost := Pos(']', Authority);
      if EndHost < 3 then
        Invalid;
      C.Host := Copy(Authority, 1, EndHost);
      PortText := Copy(Authority, EndHost + 1, MaxInt);
      if (PortText <> '') and not PortText.StartsWith(':') then
        Invalid;
      if PortText <> '' then
        Delete(PortText, 1, 1);
      if (Length(Authority) > EndHost) and (PortText = '') then
        Invalid;
    end
    else
    begin
      P := Pos(':', Authority);
      C.Host := Authority;
      PortText := '';
      if P > 0 then
      begin
        C.Host := Copy(Authority, 1, P - 1);
        PortText := Copy(Authority, P + 1, MaxInt);
        if PortText = '' then
          Invalid;
      end;
    end;
    if C.Host = '' then
      Invalid;
    if PortText <> '' then
    begin
      for var Ch in PortText do
        if not CharInSet(Ch, ['0'..'9']) then
          Invalid;
      if not TryStrToInt(PortText, C.Port) or (C.Port < 0) or (C.Port > 65535) then
        Invalid;
    end;
    P := Pos('#', Rest);
    C.HasFragment := P > 0;
    if P > 0 then
    begin
      C.Fragment := Copy(Rest, P + 1, MaxInt);
      Rest := Copy(Rest, 1, P - 1);
    end;
    P := Pos('?', Rest);
    C.HasQuery := P > 0;
    if P > 0 then
    begin
      C.Query := Copy(Rest, P + 1, MaxInt);
      Rest := Copy(Rest, 1, P - 1);
    end;
    C.FilePart := Rest;
    C.HasFile := Rest <> '';
    C.TransportURL := 'http://' + Authority + Rest;
    if C.HasQuery then
      C.TransportURL := C.TransportURL + '?' + C.Query;
    Collect;
    if (FConnections.Count >= 32) or (FRetired.Count >= 32) then
      FVM.RaiseJava('java/io/IOException', 'Connection capacity');
    Result := FVM.NewObject(ImplementationName);
    C.Ref := Result;
    FConnections.Add(Result, C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2MENetwork.Ready(Connection: TJ2MEHTTPConnection): Boolean;
begin
  if FVM.ClearInterrupted then
    FVM.RaiseJava('java/io/InterruptedIOException', 'HTTP operation interrupted');
  if Connection.Job = nil then
  begin
    var Count := FRetired.Count;
    for var C in FConnections.Values do
      if (C.Job <> nil) and not C.Job.Done then
        Inc(Count);
    if Count >= 16 then
      FVM.RaiseJava('java/io/IOException', 'HTTP worker capacity');
    Connection.Job := TJ2MEHTTPJob.Create(Connection.TransportURL, Connection.RequestMethod, Connection.Body, Connection.Headers, Min(NetworkLimit, FVM.MaxArrayLength));
    Connection.Job.Start;
    Connection.Body := nil;
  end;
  Result := Connection.Job.Done;
  if not Result then
  begin
    FVM.SleepCurrent(1, 'java/io/InterruptedIOException');
    FVM.RetryNative;
    Exit;
  end;
  if Connection.Job.ErrorText <> '' then
    FVM.RaiseJava('java/io/IOException', Connection.Job.ErrorText);
end;

function TJ2MENetwork.OpenStream(Connection: TJ2MEHTTPConnection; Reading: Boolean): Integer;
begin
  if Connection.Closed then
    FVM.RaiseJava('java/io/IOException', 'Connection closed');
  if Reading then
  begin
    if (Connection.Mode and 1) = 0 then
      FVM.RaiseJava('java/io/IOException', 'Connection is write-only');
    if Connection.InputOpened then
      FVM.RaiseJava('java/io/IOException', 'HTTP input already opened');
    if not Ready(Connection) then
      Exit(0);
    Result := FVM.NewObject(InputName);
    Connection.InputOpened := True;
    Connection.InputRef := Result;
  end
  else
  begin
    if (Connection.Mode and 2) = 0 then
      FVM.RaiseJava('java/io/IOException', 'Connection is read-only');
    if Connection.OutputOpened or (Connection.Job <> nil) then
      FVM.RaiseJava('java/io/IOException', 'HTTP output already opened or committed');
    Result := FVM.NewObject(OutputName);
    Connection.OutputOpened := True;
    Connection.OutputRef := Result;
  end;
  FVM.GetObject(Result).Fields.AddOrSetValue(ConnectionKey, TJVMValue.Ref(Connection.Ref));
end;

function TJ2MENetwork.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  C: TJ2MEHTTPConnection;
  O, A: TJVMObject;
  N, Owner, Value, Name: string;
  Offset, Count: Integer;

  function StringValue(const Text: string; Present: Boolean = True): TJVMValue;
  begin
    Result := TJVMValue.Ref(0);
    if Present then
      Result := TJVMValue.Ref(FVM.NewString(Text));
  end;

  function Text(Index: Integer): string;
  begin
    Result := FVM.GetObject(Args[Index].AsRef).Text;
  end;

  procedure ArrayRange;
  begin
    A := FVM.GetObject(Args[1].AsRef);
    Offset := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
      FVM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;

  procedure StreamClosed;
  begin
    O.Fields.AddOrSetValue(ClosedKey, TJVMValue.Int(1));
    O.Fields.AddOrSetValue(ConnectionKey, TJVMValue.Ref(0));
    if Owner = InputName then
      C.InputRef := 0
    else
      C.OutputRef := 0;
    ReleaseClosed(C);
  end;

begin
  Result := Default(TJVMValue);
  A := nil;
  N := Method.Name;
  Owner := Method.Owner.Name;
  Collect;
  if Owner = Factory then
  begin
    var Mode := 3;
    var Timeouts := False;
    if Length(Args) > 1 then
      Mode := Args[1].AsInt;
    if Length(Args) > 2 then
      Timeouts := Args[2].AsInt <> 0;
    Exit(TJVMValue.Ref(Open(Text(0), Mode, Timeouts)));
  end;
  O := FVM.GetObject(Args[0].AsRef);
  if (Owner = InputName) or (Owner = OutputName) then
  begin
    if IntegerField(O, ClosedKey) <> 0 then
    begin
      if N = 'close' then
        Exit;
      FVM.RaiseJava('java/io/IOException', 'Stream closed');
    end;
    var ConnectionRef: TJVMValue;
    if not O.Fields.TryGetValue(ConnectionKey, ConnectionRef) or
      not FConnections.TryGetValue(ConnectionRef.AsRef, C) then
      FVM.RaiseJava('java/io/IOException', 'Connection released');
    if Owner = InputName then
    begin
      if N = 'close' then
      begin
        StreamClosed;
        Exit;
      end;
      if (C.Job = nil) or not C.Job.Done then
        FVM.RaiseJava('java/io/IOException', 'Response unavailable');
      var Remaining := Length(C.Job.Data) - C.Position;
      if N = 'available' then
        Exit(TJVMValue.Int(Remaining));
      if N = 'skip' then
      begin
        var Skipped := Min(Int64(Remaining), Max(Int64(0), Args[1].AsLong));
        Inc(C.Position, Integer(Skipped));
        Exit(TJVMValue.Long(Skipped));
      end;
      if Method.Descriptor = '()I' then
      begin
        if Remaining = 0 then
          Exit(TJVMValue.Int(-1));
        Result := TJVMValue.Int(C.Job.Data[C.Position]);
        Inc(C.Position);
        Exit;
      end;
      ArrayRange;
      if Count = 0 then
        Exit(TJVMValue.Int(0));
      if Remaining = 0 then
        Exit(TJVMValue.Int(-1));
      Count := Min(4096, Min(Count, Remaining));
      for var I := 0 to Count - 1 do
        A.Elements[Offset + I] := TJVMValue.Int(ShortInt(C.Job.Data[C.Position + I]));
      Inc(C.Position, Count);
      Exit(TJVMValue.Int(Count));
    end;
    if (N = 'flush') or (N = 'close') then
    begin
      if N = 'close' then
        C.OutputClosing := True;
      try
        if not Ready(C) then
          Exit;
      except
        if N = 'close' then
          StreamClosed;
        raise;
      end;
      if N = 'close' then
        StreamClosed;
      Exit;
    end;
    if C.OutputClosing or (C.Job <> nil) then
      FVM.RaiseJava('java/io/IOException', 'HTTP request body already committed');
    Count := 1;
    Offset := 0;
    if Method.Descriptor <> '(I)V' then
      ArrayRange;
    if Count > Min(NetworkLimit, FVM.MaxArrayLength) - Length(C.Body) then
      FVM.RaiseJava('java/io/IOException', 'HTTP request exceeds implementation capacity');
    var Start := Length(C.Body);
    SetLength(C.Body, Start + Count);
    if A <> nil then
    begin
      for var I := 0 to Count - 1 do
        C.Body[Start + I] := Byte(A.Elements[Offset + I].AsInt);
    end
    else
      C.Body[Start] := Byte(Args[1].AsInt);
    Exit;
  end;
  if not FConnections.TryGetValue(Args[0].AsRef, C) then
    FVM.RaiseJava('java/io/IOException', 'Connection released');
  if N = 'close' then
  begin
    C.Closed := True;
    ReleaseClosed(C);
    Exit;
  end;
  if C.Closed then
    FVM.RaiseJava('java/io/IOException', 'Connection closed');
  if N = 'getURL' then
    Exit(StringValue(C.URL));
  if N = 'getProtocol' then
    Exit(StringValue('http'));
  if N = 'getHost' then
    Exit(StringValue(C.Host));
  if N = 'getFile' then
    Exit(StringValue(C.FilePart, C.HasFile));
  if N = 'getQuery' then
    Exit(StringValue(C.Query, C.HasQuery));
  if N = 'getRef' then
    Exit(StringValue(C.Fragment, C.HasFragment));
  if N = 'getPort' then
    Exit(TJVMValue.Int(C.Port));
  if N = 'getRequestMethod' then
    Exit(StringValue(C.RequestMethod));
  if N = 'getRequestProperty' then
  begin
    var Found := Header(C.Headers, Text(1), Value);
    Exit(StringValue(Value, Found));
  end;
  if (N = 'setRequestMethod') or (N = 'setRequestProperty') then
  begin
    if C.Job <> nil then
      FVM.RaiseJava('java/io/IOException', 'HTTP request already committed');
    if C.OutputOpened then
      Exit;
    Value := Text(1);
    if N = 'setRequestMethod' then
    begin
      if (Value <> 'GET') and (Value <> 'POST') and (Value <> 'HEAD') then
        FVM.RaiseJava('java/io/IOException', 'Unsupported HTTP method');
      C.RequestMethod := Value;
      Exit;
    end;
    Name := Value;
    Value := Text(2);
    if Name = '' then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Empty header name');
    var HeaderSize := Length(Name) + Length(Value);
    for var H in C.Headers do
      if not SameText(H.Name, Name) then
        Inc(HeaderSize, Length(H.Name) + Length(H.Value));
    if (Length(Name) > 256) or (Length(Value) > 8192) or (HeaderSize > 65536) then
      FVM.RaiseJava('java/io/IOException', 'Header size capacity');
    for var Ch in Name do
      if not CharInSet(Ch, ['a'..'z', 'A'..'Z', '0'..'9', '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~']) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid header name');
    for var Ch in Value do
      if ((Ord(Ch) < 32) and (Ch <> #9)) or (Ord(Ch) = 127) then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid header value');
    for var I := 0 to High(C.Headers) do
      if SameText(C.Headers[I].Name, Name) then
      begin
        C.Headers[I].Value := Value;
        Exit;
      end;
    if Length(C.Headers) >= 128 then
      FVM.RaiseJava('java/io/IOException', 'Header capacity');
    var I := Length(C.Headers);
    SetLength(C.Headers, I + 1);
    C.Headers[I] := TNameValuePair.Create(Name, Value);
    Exit;
  end;
  if N = 'openOutputStream' then
    Exit(TJVMValue.Ref(OpenStream(C, False)));
  if N = 'openInputStream' then
    Exit(TJVMValue.Ref(OpenStream(C, True)));
  if not Ready(C) then
    Exit;
  if N = 'getResponseCode' then
    Exit(TJVMValue.Int(C.Job.Code));
  if N = 'getResponseMessage' then
    Exit(StringValue(C.Job.MessageText));
  if (N = 'getHeaderFieldKey') or ((N = 'getHeaderField') and (Method.Descriptor = '(I)Ljava/lang/String;')) then
  begin
    var I := Args[1].AsInt;
    if I = 0 then
    begin
      if N = 'getHeaderFieldKey' then
        Exit(StringValue('', False));
      Exit(StringValue(C.Job.StatusLine));
    end;
    Dec(I);
    if (I < 0) or (I >= Length(C.Job.ResponseHeaders)) then
      Exit(StringValue('', False));
    if N = 'getHeaderFieldKey' then
      Exit(StringValue(C.Job.ResponseHeaders[I].Name));
    Exit(StringValue(C.Job.ResponseHeaders[I].Value));
  end;
  if N = 'getHeaderField' then
  begin
    if Args[1].AsRef = 0 then
      Exit(StringValue(C.Job.StatusLine));
    var Found := Header(C.Job.ResponseHeaders, Text(1), Value);
    Exit(StringValue(Value, Found));
  end;
  Name := '';
  if N = 'getType' then
    Name := 'Content-Type'
  else if N = 'getEncoding' then
    Name := 'Content-Encoding'
  else if N = 'getLength' then
    Name := 'Content-Length'
  else if N = 'getDate' then
    Name := 'Date'
  else if N = 'getLastModified' then
    Name := 'Last-Modified'
  else if N = 'getExpiration' then
    Name := 'Expires'
  else if (N = 'getHeaderFieldInt') or (N = 'getHeaderFieldDate') then
    Name := Text(1);
  var Found := Header(C.Job.ResponseHeaders, Name, Value);
  if (N = 'getType') or (N = 'getEncoding') then
    Exit(StringValue(Value, Found));
  if N = 'getLength' then
  begin
    var L: Int64;
    if not Found or not HTTPInteger(Value, False, L) then
      L := -1;
    Exit(TJVMValue.Long(L));
  end;
  if N = 'getHeaderFieldInt' then
  begin
    var I: Int64;
    if not Found or not HTTPInteger(Value, True, I) or (I < Low(Integer)) or (I > High(Integer)) then
      I := Args[2].AsInt;
    Exit(TJVMValue.Int(Integer(I)));
  end;
  var DefaultDate := Int64(0);
  if N = 'getHeaderFieldDate' then
    DefaultDate := Args[2].AsLong;
  Exit(TJVMValue.Long(HTTPDate(Value, DefaultDate)));
end;

end.

