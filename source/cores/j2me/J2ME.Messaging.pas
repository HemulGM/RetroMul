unit J2ME.Messaging;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, JVM.Types,
  JVM.ClassFile, JVM.Runtime, Core.Messaging.Types, J2ME.Suite;

type
  TJ2MEMessageConnection = class
    Ref, Mode, Generation: Integer;
    Endpoint: TMessageAddress;
    Channel: IMessagingChannel;
    Closed, Timeouts, ListenerRoot, Siemens: Boolean;
    Seen, Notifications: UInt64;
    destructor Destroy; override;
  end;

  TJ2MEMessageEvent = record
    Connection, Generation: Integer;
    Siemens: Boolean;
  end;

  TJ2MEPushEntry = record
    URL, MIDlet, Filter: string;
    Address: TMessageAddress;
  end;

  TJ2MEMessaging = class
  private
    FVM: TJVM;
    FProvider, FLoopback: IMessagingProvider;
    FConnections: TObjectDictionary<Integer, TJ2MEMessageConnection>;
    FStopped, FStaticSiemensListener: Boolean;
    FPushEntries: TArray<TJ2MEPushEntry>;
    procedure InstallPushRegistry(Suite: TJ2MESuite);
    function InvokePushRegistry(const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
    procedure Close(C: TJ2MEMessageConnection);
    procedure Error(Code: TMessagingError);
    procedure InstallSiemens;
    procedure SetSiemensListener(Connection, ListenerRef: Integer; const Provider: IMessagingProvider; Address: TMessageAddress);
    function SiemensProvider(const Endpoint: string; out Address: TMessageAddress): IMessagingProvider;
    function InvokeSiemens(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function SendSiemensSMS(const Descriptor: string; const Args: TArray<TJVMValue>): TJVMValue;
    function SiemensUnicodeToGSM(TextRef: Integer): TJVMValue;
    function TakeSiemensData(Connection, Generation: Integer): TJVMValue;
    function NewMessage(Kind: TMessagingPayload; Address: Integer; Protocol: TMessagingProtocol): Integer;
  public
    procedure RequireSnapshotIdle;
    constructor Create(VM: TJVM; const Provider: IMessagingProvider);
    destructor Destroy; override;
    procedure Install(Suite: TJ2MESuite = nil);
    class function SupportsLegacyClassLayout(C: TJVMClass; Count: Integer): Boolean; static;
    procedure Poll;
    procedure Shutdown;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    function Permission(const Name: string): Integer;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function TakeEvent(out Event: TJ2MEMessageEvent): Boolean;
    procedure ReleaseEvent(const Event: TJ2MEMessageEvent);
    procedure BeginEvent(Context: Integer; const Event: TJ2MEMessageEvent);
    function GetProperty(const Name: string; out Value: string): Boolean;
  end;

implementation

uses
  Java.Classes, Core.Messaging.Virtual;

{$Q-}{$R-}

const
  PushRegistry = 'javax/microedition/io/PushRegistry';
  WMA = 'javax/wireless/messaging/';
  Msg = WMA + 'Message';
  TextMsg = WMA + 'TextMessage';
  BinaryMsg = WMA + 'BinaryMessage';
  Conn = WMA + 'MessageConnection';
  Listener = WMA + 'MessageListener';
  Impl = WMA + 'MessageConnection$Native';
  Dispatcher = WMA + 'MessageConnection$Dispatcher';
  SiemensConnection = 'com/siemens/mp/io/Connection';
  SiemensSMS = 'com/siemens/mp/gsm/SMS';
  SiemensStringConverter = 'com/siemens/mp/misc/StringConverter';
  SiemensListener = 'com/siemens/mp/io/ConnectionListener';
  SiemensError = 'com/siemens/mp/NotAllowedException';
  SiemensDispatch = 'org/retromul/messaging/SiemensDispatcher';
  SiemensListenerDesc = 'L' + SiemensListener + ';';
  SiemensSetListenerDesc = '(' + SiemensListenerDesc + ')V';
  SiemensReceiverField = '$legacyReceiver';
  SiemensConnectionDesc = 'L' + SiemensConnection + ';';
  SiemensArgs = '(L' + SiemensConnection + ';I)';
  SiemensDispatchDesc = SiemensArgs + 'V';
  SiemensTakeDesc = SiemensArgs + '[Ljava/lang/Object;';
  SiemensEndpointKey = '$siemens.endpoint';
  SiemensGenerationKey = '$siemens.generation';
  AddressKey = '$message.address';
  PayloadKey = '$message.payload';
  TimestampKey = '$message.timestamp';
  HasTimeKey = '$message.hasTime';
  ProtocolKey = '$message.protocol';
  ListenerKey = '$message.listener';
  ClosedKey = '$message.closed';

function Ref(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsRef;
end;

function Int(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsInt;
end;

procedure Put(O: TJVMObject; const Key: string; V: TJVMValue);
begin
  O.Fields.AddOrSetValue(Key, V);
end;

destructor TJ2MEMessageConnection.Destroy;
begin
  if Channel <> nil then
    Channel.Close;
  inherited;
end;

constructor TJ2MEMessaging.Create(VM: TJVM; const Provider: IMessagingProvider);
begin
  inherited Create;
  FVM := VM;
  FProvider := Provider;
  FConnections := TObjectDictionary<Integer, TJ2MEMessageConnection>.Create([doOwnsValues]);
end;

destructor TJ2MEMessaging.Destroy;
begin
  Shutdown;
  FConnections.Free;
  inherited;
end;

procedure TJ2MEMessaging.Close(C: TJ2MEMessageConnection);
begin
  if C.Closed then
    Exit;
  C.Closed := True;
  C.Notifications := 0;
  Inc(C.Generation);
  if C.Channel <> nil then
  begin
    C.Channel.Close;
    C.Channel := nil;
  end;
  if C.ListenerRoot then
  begin
    Put(FVM.GetObject(C.Ref), ListenerKey, TJVMValue.Ref(0));
    FVM.RemoveRoot(C.Ref);
    C.ListenerRoot := False;
  end;
end;

procedure TJ2MEMessaging.Shutdown;
begin
  FStopped := True;
  if FConnections <> nil then
    for var C in FConnections.Values do
      Close(C);
end;

procedure TJ2MEMessaging.Error(Code: TMessagingError);
begin
  case Code of
    TMessagingError.None:
      Exit;
    TMessagingError.Denied:
      FVM.RaiseJava('java/lang/SecurityException', 'Messaging permission denied');
    TMessagingError.InvalidAddress:
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid message address or mode');
    TMessagingError.TooLarge:
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Message exceeds transport capacity');
    TMessagingError.Unavailable:
      FVM.RaiseJava('java/io/IOException', 'Messaging transport unavailable');
    TMessagingError.Closed:
      FVM.RaiseJava('java/io/IOException', 'Message connection closed');
    TMessagingError.Busy:
      FVM.RaiseJava('java/io/IOException', 'Message port already bound');
    TMessagingError.Capacity:
      FVM.RaiseJava('java/io/IOException', 'Messaging resource capacity');
  else
    FVM.RaiseJava('java/io/IOException', 'Messaging transport failure');
  end;
end;

function UsesStaticSiemensListener(Suite: TJ2MESuite): Boolean;

  function CallsStatic(const ClassName: string): Boolean;
  begin
    var Data := Suite.LoadClass(ClassName);
    if Length(Data) = 0 then
      Exit(False);
    var C: TJVMClass;
    try
      C := TJVMClass.Parse(Data);
    except
      on EJVMFormatError do
        Exit(False);
    end;
    try
      for var I := 1 to High(C.Constants) do
        if C.Constants[I].Tag = 10 then
        begin
          var Owner, Name, Desc: string;
          C.MemberRef(I, Owner, Name, Desc);
          if (Owner <> SiemensConnection) or (Name <> 'setListener') or (Desc <> SiemensSetListenerDesc) then
            Continue;
          for var M in C.Methods do
            for var PC := 0 to Length(M.Code) - 3 do
              if M.InstructionStarts[PC] and (M.Code[PC] = $B8) and
                (((Integer(M.Code[PC + 1]) shl 8) or M.Code[PC + 2]) = I) then
                Exit(True);
        end;
      Result := False;
    finally
      C.Free;
    end;
  end;

begin
  if Suite = nil then
    Exit(False);
  for var I := 0 to Suite.MIDletCount - 1 do
    if CallsStatic(Suite.MIDlet(I).ClassName) then
      Exit(True);
  // Sticker uses the early API from its infrared helpers rather than its MIDlet.
  Result := CallsStatic('sticker/TestIrda') or CallsStatic('sticker/another/irda/IrdaStrategy');
end;

class function TJ2MEMessaging.SupportsLegacyClassLayout(C: TJVMClass; Count: Integer): Boolean;
begin
  Result := (C.Name = SiemensConnection) and (Count = 0) and (C.Fields.Count = 1) and
    (C.Fields[0].Name = SiemensReceiverField) and (C.Fields[0].Descriptor = SiemensConnectionDesc);
end;

procedure TJ2MEMessaging.Install(Suite: TJ2MESuite);
var
  B: TJavaClassBuilder;

  procedure Native(const N, D: string);
  begin
    B.JavaClass.AddNative(N, D);
  end;

  procedure AbstractMethod(const N, D: string);
  begin
    B.JavaClass.AddNative(N, D).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure MessageMethods(Kind: TMessagingPayload; abstract: Boolean);

    procedure Add(const N, D: string);
    begin
      if abstract then
        AbstractMethod(N, D)
      else
        Native(N, D);
    end;

  begin
    if not abstract then
    begin
      Add('getAddress', '()Ljava/lang/String;');
      Add('setAddress', '(Ljava/lang/String;)V');
      Add('getTimestamp', '()Ljava/util/Date;');
    end;
    if Kind = TMessagingPayload.Text then
    begin
      Add('getPayloadText', '()Ljava/lang/String;');
      Add('setPayloadText', '(Ljava/lang/String;)V');
    end
    else
    begin
      Add('getPayloadData', '()[B');
      Add('setPayloadData', '([B)V');
    end;
  end;

begin
  B := TJavaClassBuilder.Create(Msg, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $200);
  try
    AbstractMethod('getAddress', '()Ljava/lang/String;');
    AbstractMethod('setAddress', '(Ljava/lang/String;)V');
    AbstractMethod('getTimestamp', '()Ljava/util/Date;');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  for var Kind in [TMessagingPayload.Text, TMessagingPayload.Binary] do
  begin
    var N := TextMsg;
    if Kind = TMessagingPayload.Binary then
      N := BinaryMsg;
    B := TJavaClassBuilder.Create(N, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $200);
    try
      B.JavaClass.Interfaces := [Msg];
      MessageMethods(Kind, True);
      FVM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
    B := TJavaClassBuilder.Create(N + '$Native', 'java/lang/Object', JVM_ACC_FINAL or $20);
    try
      B.JavaClass.Interfaces := [N];
      MessageMethods(Kind, False);
      FVM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
  end;
  B := TJavaClassBuilder.Create(Listener, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $200);
  try
    AbstractMethod('notifyIncomingMessage', '(Ljavax/wireless/messaging/MessageConnection;)V');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  for var abstract in [True, False] do
  begin
    var N := Impl;
    var Access := JVM_ACC_FINAL or $20;
    if abstract then
    begin
      N := Conn;
      Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $200;
    end;
    B := TJavaClassBuilder.Create(N, 'java/lang/Object', Access);
    try
      B.JavaClass.Interfaces := ['javax/microedition/io/Connection'];
      if not abstract then
        B.JavaClass.Interfaces := [Conn];
      for var Entry in ['newMessage|(Ljava/lang/String;)Ljavax/wireless/messaging/Message;', 'newMessage|(Ljava/lang/String;Ljava/lang/String;)Ljavax/wireless/messaging/Message;', 'numberOfSegments|(Ljavax/wireless/messaging/Message;)I', 'receive|()Ljavax/wireless/messaging/Message;', 'send|(Ljavax/wireless/messaging/Message;)V', 'setMessageListener|(Ljavax/wireless/messaging/MessageListener;)V'] do
      begin
        var P := Pos('|', Entry);
        if abstract then
          AbstractMethod(Copy(Entry, 1, P - 1), Copy(Entry, P + 1, MaxInt))
        else
          Native(Copy(Entry, 1, P - 1), Copy(Entry, P + 1, MaxInt));
      end;
      if not abstract then
        Native('close', '()V')
      else
      begin
        for var T in ['text', 'binary'] do
        begin
          var Field := 'TEXT_MESSAGE';
          if T = 'binary' then
            Field := 'BINARY_MESSAGE';
          B.Field(Field, 'Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
          B.JavaClass.Fields.Last.Value := TJVMValue.Ref(FVM.InternString(T));
        end;
      end;
      FVM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
  end;
  B := TJavaClassBuilder.Create(Dispatcher, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $20);
  try
    B.JavaClass.AddNative('$listener', '(Ljavax/wireless/messaging/MessageConnection;I)Ljavax/wireless/messaging/MessageListener;', True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
    B.Start;
    B.Emit([$2A, $1B]);
    B.Ref($B8, B.Member(Dispatcher, '$listener', '(Ljavax/wireless/messaging/MessageConnection;I)Ljavax/wireless/messaging/MessageListener;'));
    B.Emit([$59]);
    B.Jump($C6, 'empty');
    B.Emit([$2A]);
    B.Ref($B9, B.Member(Listener, 'notifyIncomingMessage', '(Ljavax/wireless/messaging/MessageConnection;)V', 11));
    B.Emit([$02, $00, $B1]);
    B.Mark('empty');
    B.Emit([$57, $B1]);
    B.Finish('$deliver', '(Ljavax/wireless/messaging/MessageConnection;I)V', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 2, 2);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  InstallPushRegistry(Suite);
  FStaticSiemensListener := UsesStaticSiemensListener(Suite);
  InstallSiemens;
end;

procedure TJ2MEMessaging.InstallPushRegistry(Suite: TJ2MESuite);
begin
  var B := TJavaClassBuilder.Create(PushRegistry, 'java/lang/Object');
  try
    B.JavaClass.AddNative('listConnections', '(Z)[Ljava/lang/String;', True);
    for var Name in ['getMIDlet', 'getFilter'] do
      B.JavaClass.AddNative(Name, '(Ljava/lang/String;)Ljava/lang/String;', True);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;

  if Suite = nil then
    Exit;
  for var Index := 1 to 1024 do
  begin
    var Value := Suite.GetProperty('MIDlet-Push-' + IntToStr(Index));
    if Value = '' then
      Break;
    var Parts := Value.Split([',']);
    if Length(Parts) <> 3 then
      Continue;
    var Entry: TJ2MEPushEntry;
    Entry.URL := Parts[0].Trim;
    Entry.MIDlet := Parts[1].Trim;
    Entry.Filter := Parts[2].Trim;
    if not TMessageAddress.TryParse(Entry.URL, Entry.Address) or not Entry.Address.Server or
      not (Entry.Address.Protocol in [TMessagingProtocol.SMS, TMessagingProtocol.CBS]) then
      Continue;
    if (Entry.Filter = '') or (Length(Entry.Filter) > 128) or
      ((Entry.Address.Protocol = TMessagingProtocol.CBS) and (Entry.Filter <> '*')) then
      Continue;
    var ClassName := Entry.MIDlet.Replace('.', '/');
    for var MIDletIndex := 0 to Suite.MIDletCount - 1 do
      if Suite.MIDlet(MIDletIndex).ClassName = ClassName then
      begin
        FPushEntries := FPushEntries + [Entry];
        Break;
      end;
  end;
end;

function TJ2MEMessaging.InvokePushRegistry(const Name: string; const Args: TArray<TJVMValue>): TJVMValue;
var
  Inbox: IMessagingInbox;
begin
  if Name = 'listConnections' then
  begin
    var Available := Args[0].AsInt <> 0;
    var URLs: TArray<string> := nil;
    if not Available or Supports(FProvider, IMessagingInbox, Inbox) then
      for var Entry in FPushEntries do
        if not Available or Inbox.HasUnread(Entry.Address, Entry.Filter) then
          URLs := URLs + [Entry.URL];
    var ArrayRef := FVM.NewArray('[Ljava/lang/String;', Length(URLs));
    var Items := FVM.GetObject(ArrayRef);
    for var I := 0 to High(URLs) do
      Items.Elements[I] := TJVMValue.Ref(FVM.NewString(URLs[I]));
    Exit(TJVMValue.Ref(ArrayRef));
  end;
  if Args[0].AsRef <> 0 then
  begin
    var URL := FVM.GetObject(Args[0].AsRef).Text;
    for var Entry in FPushEntries do
      if Entry.URL = URL then
      begin
        if Name = 'getMIDlet' then
          Exit(TJVMValue.Ref(FVM.NewString(Entry.MIDlet)));
        Exit(TJVMValue.Ref(FVM.NewString(Entry.Filter)));
      end;
  end;
  Result := TJVMValue.Ref(0);
end;

procedure TJ2MEMessaging.InstallSiemens;
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(SiemensListener, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
  try
    B.JavaClass.AddNative('receiveData', '([B)V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SiemensError, 'java/lang/Exception');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;)V');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SiemensConnection, 'java/lang/Object');
  try
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;)V');
    B.JavaClass.AddNative('getListener', '()' + SiemensListenerDesc);
    B.JavaClass.AddNative('setListener', SiemensSetListenerDesc, FStaticSiemensListener);
    if FStaticSiemensListener then
      B.Field(SiemensReceiverField, SiemensConnectionDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.JavaClass.AddNative('send', '([B)V');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SiemensSMS, 'java/lang/Object');
  try
    B.JavaClass.AddNative('send', '(Ljava/lang/String;Ljava/lang/String;)I', True);
    B.JavaClass.AddNative('send', '(Ljava/lang/String;[B)I', True);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SiemensStringConverter, 'java/lang/Object');
  try
    B.JavaClass.AddNative('Unicode2GSM', '(Ljava/lang/String;)[B', True);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(SiemensDispatch, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $20);
  try
    B.JavaClass.AddNative('$take', SiemensTakeDesc, True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
    B.Start;
    B.Emit([$2A, $1B]);
    B.Ref($B8, B.Member(SiemensDispatch, '$take', SiemensTakeDesc));
    B.Emit([$59]);
    B.Jump($C6, 'empty');
    B.Emit([$59, $03, $32]);
    B.Ref($C0, B.ClassRef(SiemensListener));
    B.Emit([$5F, $04, $32]);
    B.Ref($C0, B.ClassRef('[B'));
    B.Ref($B9, B.Member(SiemensListener, 'receiveData', '([B)V', 11));
    B.Emit([$02, $00, $B1]);
    B.Mark('empty');
    B.Emit([$57, $B1]);
    B.Finish('$deliver', SiemensDispatchDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC, 3, 2);
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function TJ2MEMessaging.GetProperty(const Name: string; out Value: string): Boolean;
begin
  Value := '';
  Result := Name = 'wireless.messaging.sms.smsc';
  if Result then
  begin
    Value := FProvider.Info.ServiceCenter;
    Result := Value <> '';
  end;
end;

function TJ2MEMessaging.Permission(const Name: string): Integer;
var
  P: TMessagingPermission;
begin
  Result := -1;
  if Name = 'javax.microedition.io.Connector.sms' then
    P := TMessagingPermission.SMSConnect
  else if Name = 'javax.wireless.messaging.sms.send' then
    P := TMessagingPermission.SMSSend
  else if Name = 'javax.wireless.messaging.sms.receive' then
    P := TMessagingPermission.SMSReceive
  else if Name = 'javax.microedition.io.Connector.cbs' then
    P := TMessagingPermission.CBSConnect
  else if Name = 'javax.wireless.messaging.cbs.receive' then
    P := TMessagingPermission.CBSReceive
  else
    Exit;
  Result := Ord(P in FProvider.Info.Permissions);
end;

function TJ2MEMessaging.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
begin
  if FStopped then
    FVM.RaiseJava('java/io/IOException', 'Messaging stopped');
  var A: TMessageAddress;
  if not TMessageAddress.TryParse(URL, A) or (A.Protocol = TMessagingProtocol.SiemensSMS) or not (Mode in [1, 2, 3]) then
    Error(TMessagingError.InvalidAddress);
  var Channel: IMessagingChannel;
  Error(FProvider.Open(A, Mode, Channel));
  if Channel = nil then
    Error(TMessagingError.IOFailure);
  var C := TJ2MEMessageConnection.Create;
  try
    C.Channel := Channel;
    C.Endpoint := A;
    C.Mode := Mode;
    C.Timeouts := Timeouts;
    var Pending: Integer;
    Error(Channel.Status(Pending, C.Seen));
    C.Ref := FVM.NewObject(Impl);
    var O := FVM.GetObject(C.Ref);
    Put(O, ProtocolKey, TJVMValue.Int(Ord(A.Protocol)));
    if not A.Server then
      O.Text := URL;
    Result := C.Ref;
    FConnections.Add(C.Ref, C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2MEMessaging.NewMessage(Kind: TMessagingPayload; Address: Integer; Protocol: TMessagingProtocol): Integer;
begin
  var N := TextMsg;
  if Kind = TMessagingPayload.Binary then
    N := BinaryMsg;
  Result := FVM.NewObject(N + '$Native');
  var O := FVM.GetObject(Result);
  Put(O, AddressKey, TJVMValue.Ref(Address));
  Put(O, PayloadKey, TJVMValue.Ref(0));
  Put(O, ProtocolKey, TJVMValue.Int(Ord(Protocol)));
  Put(O, HasTimeKey, TJVMValue.Int(0));
end;

procedure TJ2MEMessaging.Poll;
begin
  for var Key in FConnections.Keys.ToArray do
  begin
    var C := FConnections[Key];
    if not FVM.IsObjectAlive(Key) then
    begin
      FConnections.Remove(Key);
      Continue;
    end;
    if C.Closed then
      Continue;
    var Pending: Integer;
    var Serial: UInt64;
    if C.Channel.Status(Pending, Serial) <> TMessagingError.None then
      Continue;
    if C.ListenerRoot and (Serial >= C.Seen) then
      Inc(C.Notifications, Serial - C.Seen);
    C.Seen := Serial;
  end;
end;

function TJ2MEMessaging.TakeEvent(out Event: TJ2MEMessageEvent): Boolean;
begin
  Event := Default(TJ2MEMessageEvent);
  Result := False;
  for var C in FConnections.Values do
    if not C.Closed and C.ListenerRoot and (C.Notifications <> 0) then
    begin
      Dec(C.Notifications);
      Event.Connection := C.Ref;
      Event.Generation := C.Generation;
      Event.Siemens := C.Siemens;
      FVM.AddRoot(C.Ref);
      Exit(True);
    end;
end;

procedure TJ2MEMessaging.BeginEvent(Context: Integer; const Event: TJ2MEMessageEvent);
begin
  var Owner := Dispatcher;
  var Desc := '(Ljavax/wireless/messaging/MessageConnection;I)V';
  if Event.Siemens then
  begin
    Owner := SiemensDispatch;
    Desc := SiemensDispatchDesc;
  end;
  FVM.BeginContextCall(Context, Owner, '$deliver', Desc,
    [TJVMValue.Ref(Event.Connection), TJVMValue.Int(Event.Generation)]);
end;

procedure TJ2MEMessaging.ReleaseEvent(const Event: TJ2MEMessageEvent);
begin
  FVM.RemoveRoot(Event.Connection);
end;

function TJ2MEMessaging.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = PushRegistry) or (Owner = SiemensConnection) or (Owner = SiemensDispatch) or
    (Owner = SiemensSMS) or (Owner = SiemensStringConverter) or (Owner = Impl) or (Owner = TextMsg + '$Native') or
    (Owner = BinaryMsg + '$Native') or (Owner = Dispatcher);
end;

function TJ2MEMessaging.SiemensProvider(const Endpoint: string; out Address: TMessageAddress): IMessagingProvider;
begin
  Result := nil;
  if Endpoint = 'IRDA:' then
    Exit;
  if Endpoint = 'INTERNAL:' then
  begin
    if FLoopback = nil then
      FLoopback := CreateVirtualMessagingNetwork.Provider('0', [TMessagingPermission.SMSConnect,
          TMessagingPermission.SMSSend, TMessagingPermission.SMSReceive]);
    TMessageAddress.TryParse('siemens-sms://0:0', Address);
    Exit(FLoopback);
  end;
  if TMessageAddress.TryParse(Endpoint, Address) then
    Result := FProvider;
end;

function TJ2MEMessaging.TakeSiemensData(Connection, Generation: Integer): TJVMValue;
begin
  Result := TJVMValue.Ref(0);
  var C: TJ2MEMessageConnection;
  if not FConnections.TryGetValue(Connection, C) or C.Closed or not C.Siemens or (C.Generation <> Generation) then
    Exit;
  var ListenerRef := Ref(FVM.GetObject(Connection), ListenerKey);
  if ListenerRef = 0 then
    Exit;
  var Packet: TWirelessMessage;
  if C.Channel.Receive(Packet) <> TMessagingError.None then
    Exit;
  if Packet.Kind = TMessagingPayload.Text then
    Packet.Data := TEncoding.UTF8.GetBytes(Packet.Text);
  var Pair := FVM.NewArray('[Ljava/lang/Object;', 2);
  FVM.AddRoot(Pair);
  try
    var Bytes := FVM.NewArray('[B', Length(Packet.Data));
    var Payload := FVM.GetObject(Bytes);
    for var I := 0 to High(Packet.Data) do
      Payload.Elements[I] := TJVMValue.Int(ShortInt(Packet.Data[I]));
    FVM.GetObject(Pair).Elements[0] := TJVMValue.Ref(ListenerRef);
    FVM.GetObject(Pair).Elements[1] := TJVMValue.Ref(Bytes);
    Result := TJVMValue.Ref(Pair);
  finally
    FVM.RemoveRoot(Pair);
  end;
end;

procedure TJ2MEMessaging.SetSiemensListener(Connection, ListenerRef: Integer; const Provider: IMessagingProvider; Address: TMessageAddress);
begin
  var O := FVM.GetObject(Connection);
  var Generation := Int(O, SiemensGenerationKey) + 1;
  Put(O, SiemensGenerationKey, TJVMValue.Int(Generation));
  var C: TJ2MEMessageConnection;
  if FConnections.TryGetValue(Connection, C) then
  begin
    Close(C);
    FConnections.Remove(Connection);
  end;
  Put(O, ListenerKey, TJVMValue.Ref(ListenerRef));
  // The Java registration is valid even when the handset has no SMS service.
  // In that case it is only guest state and can be saved with the game.
  if (ListenerRef = 0) or FStopped or (Provider = nil) then
    Exit;
  var Info := Provider.Info;
  if (Info.State <> TMessagingState.Ready) or not (TMessagingPermission.SMSReceive in Info.Permissions) then
    Exit;
  Address.Server := True;
  Address.Phone := '';
  var Channel: IMessagingChannel;
  if (Provider.Open(Address, 1, Channel) <> TMessagingError.None) or (Channel = nil) then
    Exit;
  var Pending: Integer;
  var Seen: UInt64;
  if Channel.Status(Pending, Seen) <> TMessagingError.None then
  begin
    Channel.Close;
    Exit;
  end;
  C := TJ2MEMessageConnection.Create;
  try
    C.Ref := Connection;
    C.Endpoint := Address;
    C.Mode := 1;
    C.Channel := Channel;
    C.Generation := Generation;
    C.Seen := Seen;
    C.Notifications := Pending;
    C.Siemens := True;
    FConnections.Add(Connection, C);
    FVM.AddRoot(Connection);
    C.ListenerRoot := True;
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2MEMessaging.InvokeSiemens(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  if FStaticSiemensListener and (Method.Name = 'setListener') then
  begin
    var Field := Method.Owner.Fields[0];
    var Receiver := Field.Value.AsRef;
    if Receiver = 0 then
    begin
      if Args[0].AsRef = 0 then
        Exit;
      Receiver := FVM.NewObject(SiemensConnection);
      Field.Value := TJVMValue.Ref(Receiver);
    end;
    var DefaultAddress: TMessageAddress;
    TMessageAddress.TryParse('siemens-sms://:0', DefaultAddress);
    SetSiemensListener(Receiver, Args[0].AsRef, FProvider, DefaultAddress);
    Exit;
  end;
  var Connection := Args[0].AsRef;
  var O := FVM.GetObject(Connection);
  if Method.Name = '<init>' then
  begin
    var URL := FVM.GetObject(Args[1].AsRef).Text;
    var Endpoint := UpperCase(URL);
    if SameText(Copy(URL, 1, 4), 'SMS:') then
    begin
      var Tail := Copy(URL, 5, MaxInt);
      if Tail.StartsWith('//') then
        Delete(Tail, 1, 2);
      if FStaticSiemensListener and (Pos(':', Tail) = 0) then
        Tail := Tail + ':0';
      var Address: TMessageAddress;
      if not TMessageAddress.TryParse('siemens-sms://' + Tail, Address) or Address.Server then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Siemens SMS destination');
      Endpoint := Address.ToString;
    end
    else if (Endpoint <> 'INTERNAL:') and (Endpoint <> 'IRDA:') then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Unsupported Siemens connection');
    Put(O, SiemensEndpointKey, TJVMValue.Ref(FVM.NewString(Endpoint)));
    Exit;
  end;
  if Method.Name = 'getListener' then
    Exit(TJVMValue.Ref(Ref(O, ListenerKey)));

  var Address: TMessageAddress;
  var Provider := SiemensProvider(FVM.GetObject(Ref(O, SiemensEndpointKey)).Text, Address);
  if Method.Name = 'setListener' then
  begin
    SetSiemensListener(Connection, Args[1].AsRef, Provider, Address);
    Exit;
  end;
  if Method.Name = 'send' then
  begin
    var Data := FVM.GetObject(Args[1].AsRef);
    if FStopped or (Provider = nil) then
      FVM.RaiseJava(SiemensError, 'Siemens transport unavailable');
    var Info := Provider.Info;
    if (Info.State <> TMessagingState.Ready) or not (TMessagingPermission.SMSSend in Info.Permissions) then
      FVM.RaiseJava(SiemensError, 'Siemens send not allowed');
    var Segments := SMSCountSegments('', Data.ElementCount, True, True);
    if (Segments = 0) or (Segments > Info.MaxSMSSegments) then
      FVM.RaiseJava(SiemensError, 'Message exceeds transport capacity');
    var Channel: IMessagingChannel;
    if (Provider.Open(Address, 2, Channel) <> TMessagingError.None) or (Channel = nil) then
      FVM.RaiseJava(SiemensError, 'Unable to open Siemens SMS channel');
    try
      var Packet := Default(TWirelessMessage);
      Packet.Kind := TMessagingPayload.Binary;
      Packet.HasTimestamp := True;
      Packet.Timestamp := FVM.Host.TimeMillis;
      SetLength(Packet.Data, Data.ElementCount);
      for var I := 0 to High(Packet.Data) do
        Packet.Data[I] := Byte(Data.Elements[I].AsInt);
      if Channel.Send(Address, Packet) <> TMessagingError.None then
        FVM.RaiseJava(SiemensError, 'Siemens transport rejected the message');
    finally
      Channel.Close;
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(SiemensConnection + '.' + Method.Name);
end;

function TJ2MEMessaging.SendSiemensSMS(const Descriptor: string; const Args: TArray<TJVMValue>): TJVMValue;
var
  Destination: TMessageAddress;
  Channel: IMessagingChannel;

  procedure CheckSend(Code: TMessagingError);
  begin
    if Code = TMessagingError.Denied then
      FVM.RaiseJava(SiemensError, 'Siemens SMS send not allowed');
    Error(Code);
  end;

begin
  if (Args[0].AsRef = 0) or (Args[1].AsRef = 0) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Missing Siemens SMS number or data');
  var Number := FVM.GetObject(Args[0].AsRef).Text;
  if not TMessageAddress.TryParse('sms://' + Number, Destination) or Destination.Server or
    (Destination.Port >= 0) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Siemens SMS number');
  if FStopped or (FProvider = nil) then
    Error(TMessagingError.Unavailable);
  var Info := FProvider.Info;
  if Info.State <> TMessagingState.Ready then
    Error(TMessagingError.Unavailable);
  if not ([TMessagingPermission.SMSConnect, TMessagingPermission.SMSSend] <= Info.Permissions) then
    CheckSend(TMessagingError.Denied);

  var Packet := Default(TWirelessMessage);
  var Binary := Descriptor = '(Ljava/lang/String;[B)I';
  var Data := FVM.GetObject(Args[1].AsRef);
  var Count: Integer;
  if Binary then
  begin
    Packet.Kind := TMessagingPayload.Binary;
    Count := Data.ElementCount;
  end
  else
  begin
    Packet.Kind := TMessagingPayload.Text;
    Packet.Text := Data.Text;
    Count := Length(Packet.Text);
  end;
  var Segments := SMSCountSegments(Packet.Text, Count, Binary, False);
  if (Segments = 0) or (Segments > Info.MaxSMSSegments) then
    Error(TMessagingError.TooLarge);
  if Binary then
  begin
    SetLength(Packet.Data, Count);
    for var I := 0 to Count - 1 do
      Packet.Data[I] := Byte(Data.ElementValues[I].AsInt);
  end;
  Packet.HasTimestamp := True;
  Packet.Timestamp := FVM.Host.TimeMillis;
  CheckSend(FProvider.Open(Destination, 2, Channel));
  if Channel = nil then
    Error(TMessagingError.Unavailable);
  try
    CheckSend(Channel.Send(Destination, Packet));
  finally
    Channel.Close;
  end;
  Result := TJVMValue.Int(Count);
end;

function TJ2MEMessaging.SiemensUnicodeToGSM(TextRef: Integer): TJVMValue;
begin
  var Data: TBytes;
  if not TryEncodeSMSGSM(FVM.GetObject(TextRef).Text, Data) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Text cannot be encoded in the GSM alphabet');
  var ArrayRef := FVM.NewArray('[B', Length(Data));
  var Values := FVM.GetObject(ArrayRef);
  for var I := 0 to High(Data) do
    Values.ElementValues[I] := TJVMValue.Int(Data[I]);
  Result := TJVMValue.Ref(ArrayRef);
end;

function TJ2MEMessaging.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, MessageObject: TJVMObject;
  C: TJ2MEMessageConnection;
  N: string;
  Kind: TMessagingPayload;
  Payload: TWirelessMessage;
  Destination: TMessageAddress;

  procedure CheckOpen;
  begin
    if (C = nil) or C.Closed then
    begin
      if FVM.NativeContinuation.Kind <> TJVMKind.Empty then
        FVM.RaiseJava('java/io/InterruptedIOException', 'Message connection closed while waiting');
      Error(TMessagingError.Closed);
    end;
  end;

  procedure RequirePermission(Sending: Boolean);
  var
    P: TMessagingPermission;
  begin
    P := TMessagingPermission.SMSReceive;
    if C.Endpoint.Protocol = TMessagingProtocol.CBS then
      P := TMessagingPermission.CBSReceive
    else if Sending then
      P := TMessagingPermission.SMSSend;
    if not (P in FProvider.Info.Permissions) then
      Error(TMessagingError.Denied);
  end;

  function MessageData(Sending: Boolean): Integer;
  begin
    MessageObject := FVM.GetObject(Args[1].AsRef);
    Kind := TMessagingPayload.Text;
    if MessageObject.ClassName = BinaryMsg + '$Native' then
      Kind := TMessagingPayload.Binary
    else if MessageObject.ClassName <> TextMsg + '$Native' then
    begin
      if Sending then
        Error(TMessagingError.InvalidAddress);
      Exit(0);
    end;
    if Int(MessageObject, ProtocolKey) <> Ord(TMessagingProtocol.SMS) then
    begin
      if Sending then
        Error(TMessagingError.InvalidAddress);
      Exit(0);
    end;
    var Address := Ref(MessageObject, AddressKey);
    var HasPort := False;
    if Address <> 0 then
    begin
      if not TMessageAddress.TryParse(FVM.GetObject(Address).Text, Destination) or Destination.Server or (Destination.Protocol <> TMessagingProtocol.SMS) then
      begin
        if Sending then
          Error(TMessagingError.InvalidAddress);
        Exit(0);
      end;
      HasPort := Destination.Port >= 0;
    end
    else if Sending then
      Error(TMessagingError.InvalidAddress);
    var Data := Ref(MessageObject, PayloadKey);
    if Data = 0 then
    begin
      if Sending then
        Error(TMessagingError.InvalidAddress);
      Exit(0);
    end;
    Payload := Default(TWirelessMessage);
    Payload.Kind := Kind;
    var BinaryLength := 0;
    if Kind = TMessagingPayload.Text then
    begin
      Payload.Text := FVM.GetObject(Data).Text;
      if Sending and (Int64(Length(Payload.Text)) > Int64(FProvider.Info.MaxSMSSegments) * 160) then
        Error(TMessagingError.TooLarge);
    end
    else
      BinaryLength := Length(FVM.GetObject(Data).Elements);
    Result := SMSCountSegments(Payload.Text, BinaryLength, Kind = TMessagingPayload.Binary, HasPort);
    if Sending then
    begin
      if (Result = 0) or (Result > FProvider.Info.MaxSMSSegments) then
        Error(TMessagingError.TooLarge);
      if Kind = TMessagingPayload.Binary then
      begin
        var A := FVM.GetObject(Data);
        SetLength(Payload.Data, BinaryLength);
        for var I := 0 to High(Payload.Data) do
          Payload.Data[I] := Byte(A.Elements[I].AsInt);
      end;
    end;
  end;

begin
  Result := Default(TJVMValue);
  N := Method.Name;
  if Method.Owner.Name = SiemensDispatch then
    Exit(TakeSiemensData(Args[0].AsRef, Args[1].AsInt));
  if Method.Owner.Name = PushRegistry then
    Exit(InvokePushRegistry(N, Args));
  if Method.Owner.Name = SiemensConnection then
    Exit(InvokeSiemens(Method, Args));
  if Method.Owner.Name = SiemensSMS then
    Exit(SendSiemensSMS(Method.Descriptor, Args));
  if Method.Owner.Name = SiemensStringConverter then
    Exit(SiemensUnicodeToGSM(Args[0].AsRef));
  if Method.Owner.Name = Dispatcher then
  begin
    if not FConnections.TryGetValue(Args[0].AsRef, C) or C.Closed or (C.Generation <> Args[1].AsInt) then
      Exit(TJVMValue.Ref(0));
    Exit(TJVMValue.Ref(Ref(FVM.GetObject(C.Ref), ListenerKey)));
  end;
  O := FVM.GetObject(Args[0].AsRef);
  if Method.Owner.Name <> Impl then
  begin
    if N = 'getAddress' then
      Exit(TJVMValue.Ref(Ref(O, AddressKey)));
    if N = 'setAddress' then
    begin
      Put(O, AddressKey, Args[1]);
      Exit;
    end;
    if N = 'getTimestamp' then
    begin
      if Int(O, HasTimeKey) = 0 then
        Exit(TJVMValue.Ref(0));
      var D := FVM.NewObject('java/util/Date');
      FVM.GetObject(D).Fields['java/util/Date.$time:J'] := O.Fields[TimestampKey];
      Exit(TJVMValue.Ref(D));
    end;
    if N.StartsWith('getPayload') then
      Exit(TJVMValue.Ref(Ref(O, PayloadKey)));
    if N.StartsWith('setPayload') then
    begin
      Put(O, PayloadKey, Args[1]);
      Exit;
    end;
    raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N);
  end;
  var ConnectionRef := Args[0].AsRef;
  if not FConnections.TryGetValue(ConnectionRef, C) and (Int(O, ClosedKey) = 0) then
    Error(TMessagingError.Closed);
  if N = 'close' then
  begin
    if C <> nil then
    begin
      Close(C);
      Put(O, ClosedKey, TJVMValue.Int(1));
      FConnections.Remove(ConnectionRef);
    end;
    Exit;
  end;
  // Message construction and sizing remain legal after closing the transport.
  var Protocol := TMessagingProtocol(Int(O, ProtocolKey));
  if N = 'newMessage' then
  begin
    var T := '';
    if Args[1].AsRef <> 0 then
      T := FVM.GetObject(Args[1].AsRef).Text;
    Kind := TMessagingPayload.Text;
    if T = 'binary' then
      Kind := TMessagingPayload.Binary
    else if T <> 'text' then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Message type');
    var Address := 0;
    if Length(Args) > 2 then
      Address := Args[2].AsRef
    else if O.Text <> '' then
      Address := FVM.NewString(O.Text);
    Exit(TJVMValue.Ref(NewMessage(Kind, Address, Protocol)));
  end;
  if N = 'numberOfSegments' then
  begin
    FVM.GetObject(Args[1].AsRef);
    if Protocol <> TMessagingProtocol.SMS then
      Exit(TJVMValue.Int(0));
    Exit(TJVMValue.Int(MessageData(False)));
  end;
  CheckOpen;
  if N = 'setMessageListener' then
  begin
    if not C.Endpoint.Server or ((C.Mode and 1) = 0) then
      FVM.RaiseJava('java/io/IOException', 'Connection cannot receive messages');
    RequirePermission(False);
    var Pending: Integer;
    Error(C.Channel.Status(Pending, C.Seen));
    Inc(C.Generation);
    C.Notifications := 0;
    Put(O, ListenerKey, Args[1]);
    if Args[1].AsRef <> 0 then
    begin
      if not C.ListenerRoot then
      begin
        FVM.AddRoot(C.Ref);
        C.ListenerRoot := True;
      end;
      C.Notifications := Pending;
    end
    else if C.ListenerRoot then
    begin
      FVM.RemoveRoot(C.Ref);
      C.ListenerRoot := False;
    end;
    Exit;
  end;
  if N = 'send' then
  begin
    if (C.Endpoint.Protocol <> TMessagingProtocol.SMS) or ((C.Mode and 2) = 0) then
      FVM.RaiseJava('java/io/IOException', 'Connection cannot send messages');
    RequirePermission(True);
    if FVM.ClearInterrupted then
      FVM.RaiseJava('java/io/InterruptedIOException', 'Message send interrupted');
    var Segments := MessageData(True);
    if Segments > FProvider.Info.MaxSMSSegments then
      Error(TMessagingError.TooLarge);
    if SMSRestrictedPort(Destination.Port) then
      Error(TMessagingError.Denied);
    Payload.HasTimestamp := True;
    Payload.Timestamp := FVM.Host.TimeMillis;
    var Code := C.Channel.Send(Destination, Payload);
    if Code <> TMessagingError.WouldBlock then
    begin
      Error(Code);
      Exit;
    end;
    var State := FVM.NativeContinuation;
    var Started := FVM.Host.MonotonicMillis;
    if State.Kind = TJVMKind.Long then
      Started := State.AsLong
    else
      FVM.SetNativeContinuation(TJVMValue.Long(Started));
    if C.Timeouts and (FVM.Host.MonotonicMillis - Started >= 15000) then
      FVM.RaiseJava('java/io/InterruptedIOException', 'Message send timed out');
    FVM.SleepCurrent(1, 'java/io/InterruptedIOException');
    FVM.RetryNative;
    Exit;
  end;
  if N = 'receive' then
  begin
    if not C.Endpoint.Server or ((C.Mode and 1) = 0) then
      FVM.RaiseJava('java/io/IOException', 'Connection cannot receive messages');
    RequirePermission(False);
    if FVM.ClearInterrupted then
      FVM.RaiseJava('java/io/InterruptedIOException', 'Message receive interrupted');
    var Code := C.Channel.Receive(Payload);
    if Code = TMessagingError.WouldBlock then
    begin
      FVM.SetNativeContinuation(TJVMValue.Int(1));
      FVM.SleepCurrent(1, 'java/io/InterruptedIOException');
      FVM.RetryNative;
      Exit;
    end;
    Error(Code);
    var Address := FVM.NewString(Payload.Address);
    var M := NewMessage(Payload.Kind, Address, C.Endpoint.Protocol);
    MessageObject := FVM.GetObject(M);
    var Data: Integer;
    if Payload.Kind = TMessagingPayload.Text then
      Data := FVM.NewString(Payload.Text)
    else
    begin
      Data := FVM.NewArray('[B', Length(Payload.Data));
      var A := FVM.GetObject(Data);
      for var I := 0 to High(Payload.Data) do
        A.Elements[I] := TJVMValue.Int(ShortInt(Payload.Data[I]));
    end;
    Put(MessageObject, PayloadKey, TJVMValue.Ref(Data));
    Put(MessageObject, HasTimeKey, TJVMValue.Int(Ord(Payload.HasTimestamp and (C.Endpoint.Protocol = TMessagingProtocol.SMS))));
    Put(MessageObject, TimestampKey, TJVMValue.Long(Payload.Timestamp));
    Exit(TJVMValue.Ref(M));
  end;
  raise EJVMUnsupported.Create(Impl + '.' + N);
end;

procedure TJ2MEMessaging.RequireSnapshotIdle;
begin
  for var ConnectionRef in FConnections.Keys.ToArray do
    if not FVM.IsObjectAlive(ConnectionRef) then
      FConnections.Remove(ConnectionRef);
  if FConnections.Count <> 0 then
    raise EInvalidOpException.Create('Java ME snapshots require inactive network, Bluetooth and messaging connections');
end;

end.

