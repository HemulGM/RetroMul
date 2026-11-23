unit J2ME.Network.Datagram;

interface

uses
  System.Classes, System.Generics.Collections, System.Net.Socket,
  System.SyncObjs, JVM.Types, JVM.ClassFile, JVM.Runtime;

type
  IJ2MEUDPLookup = interface
    procedure Resolve(const Host: string);
    function TryGetResult(out Address: TIPAddress; out Failure: string): Boolean;
  end;

  TJ2MEUDPLookupEntry = record
    Lookup: IJ2MEUDPLookup;
    ExpiresAt: Int64;
  end;

  TJ2MEUDPReceiver = class(TThread)
  private
    FSocket: TSocket;
    FRequested: TEvent;
    FPending: Boolean;
    FReady: Integer;
    FData: TArray<Byte>;
    FSize: Integer;
    FSender: TNetEndpoint;
    FFailure: string;
  protected
    procedure Execute; override;
  public
    constructor Create(Socket: System.Net.Socket.TSocket);
    destructor Destroy; override;
    procedure Cancel;
    function TryRead(out Data: TArray<Byte>; out Size: Integer; out Sender: TNetEndpoint; out Failure: string): Boolean;
  end;

  TJ2MEUDPConnection = class
    Socket: TSocket;
    Receiver: TJ2MEUDPReceiver;
    Mode: Integer;
    DefaultAddress: string;
    Destination: TNetEndpoint;
    Timeouts: Boolean;
    destructor Destroy; override;
  end;

  TJ2MEDatagrams = class
  private
    FVM: TJVM;
    FConnections: TObjectDictionary<Integer, TJ2MEUDPConnection>;
    FLookups: TDictionary<string, TJ2MEUDPLookupEntry>;
    function ParseAddress(const URL: string; AllowServer: Boolean; out Host: string; out Port: Word): Boolean;
    function ResolveEndpoint(const Host: string; Port: Word; out Endpoint: TNetEndpoint): Boolean;
    function NewPacket(const Args: TArray<TJVMValue>; const Descriptor, DefaultAddress: string): Integer;
    function InvokePacket(const Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  public
    constructor Create(VM: TJVM);
    destructor Destroy; override;
    procedure Install;
    procedure Collect;
    procedure Stop;
    function IsIdle: Boolean;
    function Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
    function Handles(const Owner: string): Boolean;
    function Invoke(const Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
  end;

implementation

uses
  {$IFDEF MSWINDOWS}    Winapi.Winsock2, {$ENDIF}
  {$IFDEF POSIX}Posix.ArpaInet, Posix.NetinetIn, Posix.Errno, {$ENDIF}
  System.Math, System.StrUtils, System.SysUtils, System.Types, Java.Classes,
  JVM.Threading;

const
  IO = 'javax/microedition/io/';
  Datagram = IO + 'Datagram';
  Connection = IO + 'DatagramConnection';
  UDPConnection = IO + 'UDPDatagramConnection';
  UDPNative = UDPConnection + '$Native';
  PacketNative = Datagram + '$Native';
  PacketOutput = Datagram + '$Output';
  InputStream = 'java/io/InputStream';
  OutputStream = 'java/io/OutputStream';
  DataInput = 'java/io/DataInput';
  DataOutput = 'java/io/DataOutput';
  PacketDesc = 'L' + Datagram + ';';
  StringDesc = 'Ljava/lang/String;';
  URLPrefix = 'datagram://';
  DataKey = '$udp.data';
  OffsetKey = '$udp.offset';
  LengthKey = '$udp.length';
  AddressKey = '$udp.address';
  CursorKey = '$udp.cursor';
  OutputPacketField = '$packet';
  MaxPayload = 65507;
  NominalPayload = 512;
  ConnectionLimit = 32;
  LookupLimit = 16;
  DNSCacheMillis = 60000;
  DNSWaitMillis = 15000;
  InterfaceFlag = $0200;

type
  TJ2MEUDPLookup = class(TInterfacedObject, IJ2MEUDPLookup)
  private
    FAddress: TIPAddress;
    FFailure: string;
    FDone: Integer;
  public
    procedure Resolve(const Host: string);
    function TryGetResult(out Address: TIPAddress; out Failure: string): Boolean;
  end;

procedure TJ2MEUDPLookup.Resolve(const Host: string);
begin
  try
    FAddress := TIPAddress.Create(Host);
  except
    on E: Exception do
      FFailure := E.Message;
  end;
  TInterlocked.Exchange(FDone, 1);
end;

function TJ2MEUDPLookup.TryGetResult(out Address: TIPAddress; out Failure: string): Boolean;
begin
  Result := TInterlocked.CompareExchange(FDone, 0, 0) <> 0;
  if Result then
  begin
    Address := FAddress;
    Failure := FFailure;
  end;
end;

function StartLookup(const Host: string): IJ2MEUDPLookup;
begin
  var Lookup: IJ2MEUDPLookup := TJ2MEUDPLookup.Create;
  // The worker owns only the request. Closing the MIDlet does not wait for DNS.
  var Worker := TThread.CreateAnonymousThread(
    procedure
    begin
      Lookup.Resolve(Host);
    end);
  try
    Worker.Start;
  except
    Worker.Free;
    raise;
  end;
  Result := Lookup;
end;

constructor TJ2MEUDPReceiver.Create(Socket: System.Net.Socket.TSocket);
begin
  inherited Create(True);
  FSocket := Socket;
  FRequested := TEvent.Create(nil, False, False, '');
  SetLength(FData, MaxPayload);
  FSocket.ReceiveTimeout := 50;
end;

procedure TJ2MEUDPReceiver.Cancel;
begin
  Terminate;
  if FRequested <> nil then
    FRequested.SetEvent;
end;

destructor TJ2MEUDPReceiver.Destroy;
begin
  Cancel;
  inherited;
  FRequested.Free;
end;

procedure TJ2MEUDPReceiver.Execute;
begin
  while not Terminated do
  begin
    FRequested.WaitFor(INFINITE);
    if Terminated then
      Break;
    FFailure := '';
    FSize := -1;
    repeat
      try
        // Keep the original datagram intact, including zero-length payloads.
        FSize := FSocket.ReceiveFrom(FData[0], Length(FData), FSender);
      except
        on E: ESocketError do
        begin
          FSize := -1;
          {$IFDEF MSWINDOWS}
          if E.Code <> WSAETIMEDOUT then
          {$ELSE}
            if (E.Code <> EAGAIN) and (E.Code <> EWOULDBLOCK) and (E.Code <> EINTR) then
          {$ENDIF}
              FFailure := E.Message;
        end;
        on E: Exception do
          FFailure := E.Message;
      end;
    until Terminated or (FSize >= 0) or (FFailure <> '');
    TInterlocked.Exchange(FReady, 1);
  end;
end;

function TJ2MEUDPReceiver.TryRead(out Data: TArray<Byte>; out Size: Integer; out Sender: TNetEndpoint; out Failure: string): Boolean;
begin
  if not FPending then
  begin
    TInterlocked.Exchange(FReady, 0);
    FPending := True;
    FRequested.SetEvent;
  end;
  Result := TInterlocked.CompareExchange(FReady, 0, 0) <> 0;
  if not Result then
    Exit;
  Data := FData;
  Size := FSize;
  Sender := FSender;
  Failure := FFailure;
  FPending := False;
end;

destructor TJ2MEUDPConnection.Destroy;
begin
  Receiver.Free;
  Socket.Free;
  inherited;
end;

constructor TJ2MEDatagrams.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
  FConnections := TObjectDictionary<Integer, TJ2MEUDPConnection>.Create([doOwnsValues]);
  FLookups := TDictionary<string, TJ2MEUDPLookupEntry>.Create;
end;

destructor TJ2MEDatagrams.Destroy;
begin
  if (FConnections <> nil) and (FLookups <> nil) then
    Stop;
  FConnections.Free;
  FLookups.Free;
  inherited;
end;

procedure TJ2MEDatagrams.Collect;
begin
  for var Ref in FConnections.Keys.ToArray do
    if not FVM.IsObjectAlive(Ref) then
      FConnections.Remove(Ref);
end;

procedure TJ2MEDatagrams.Stop;
begin
  for var C in FConnections.Values do
    if C.Receiver <> nil then
      C.Receiver.Cancel;
  FConnections.Clear;
  FLookups.Clear;
end;

function TJ2MEDatagrams.IsIdle: Boolean;
begin
  Result := FConnections.Count = 0;
end;

procedure TJ2MEDatagrams.Install;
var
  B: TJavaClassBuilder;

  procedure Start(const Name: string; const Parents: TArray<string>; IsInterface: Boolean; const SuperName: string = 'java/lang/Object');
  begin
    var Flags := JVM_ACC_PUBLIC;
    if IsInterface then
      Flags := Flags or JVM_ACC_ABSTRACT or InterfaceFlag;
    B := TJavaClassBuilder.Create(Name, SuperName, Flags);
    B.JavaClass.Interfaces := Parents;
  end;

  procedure Method(const Name, Descriptor: string);
  begin
    var M := B.JavaClass.AddNative(Name, Descriptor);
    if (B.JavaClass.Access and InterfaceFlag) <> 0 then
      M.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure Finish;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure PacketMethods;
  begin
    Method('getData', '()[B');
    Method('getAddress', '()' + StringDesc);
    Method('getOffset', '()I');
    Method('getLength', '()I');
    Method('setAddress', '(' + StringDesc + ')V');
    Method('setAddress', '(' + PacketDesc + ')V');
    Method('setLength', '(I)V');
    Method('setData', '([BII)V');
    Method('reset', '()V');
  end;

  procedure ConnectionMethods;
  begin
    Method('getMaximumLength', '()I');
    Method('getNominalLength', '()I');
    Method('newDatagram', '(I)' + PacketDesc);
    Method('newDatagram', '(I' + StringDesc + ')' + PacketDesc);
    Method('newDatagram', '([BI)' + PacketDesc);
    Method('newDatagram', '([BI' + StringDesc + ')' + PacketDesc);
    Method('send', '(' + PacketDesc + ')V');
    Method('receive', '(' + PacketDesc + ')V');
  end;

  procedure DataMethods(const API, Stream, Wrapper: string; Reading: Boolean);
  begin
    for var M in FVM.LoadClass(API).Methods do
    begin
      var Signature := JVMMethodType(M.Descriptor);
      B.Start;
      B.Ref($BB, B.ClassRef(Wrapper));
      B.Emit([$59]);
      if not Reading then
      begin
        B.Ref($BB, B.ClassRef(PacketOutput));
        B.Emit([$59, $2A]);
        B.Ref($B7, B.Member(PacketOutput, '<init>', '(L' + PacketNative + ';)V'));
      end
      else
        B.Emit([$2A]);
      B.Ref($B7, B.Member(Wrapper, '<init>', '(L' + Stream + ';)V'));
      var Slot := 1;
      for var Arg in Signature.Arguments do
      begin
        var Op: Byte := $15;
        case Arg[1] of
          'J':
            Op := $16;
          'F':
            Op := $17;
          'D':
            Op := $18;
          'L', '[':
            Op := $19;
        end;
        B.Emit([Op, Byte(Slot)]);
        Inc(Slot, 1 + Ord(CharInSet(Arg[1], ['J', 'D'])));
      end;
      B.Ref($B6, B.Member(Wrapper, M.Name, M.Descriptor));
      var ReturnOp: Byte := $AC;
      case Signature.ReturnType[1] of
        'V':
          ReturnOp := $B1;
        'J':
          ReturnOp := $AD;
        'F':
          ReturnOp := $AE;
        'D':
          ReturnOp := $AF;
        'L', '[':
          ReturnOp := $B0;
      end;
      B.Emit([ReturnOp]);
      B.Finish(M.Name, M.Descriptor, JVM_ACC_PUBLIC, Max(5, Slot), Slot);
    end;
  end;

begin
  B := nil;
  try
    Start(Datagram, [DataInput, DataOutput], True);
    PacketMethods;
    Finish;
    Start(Connection, [IO + 'Connection'], True);
    ConnectionMethods;
    Finish;
    Start(UDPConnection, [Connection], True);
    Method('getLocalAddress', '()' + StringDesc);
    Method('getLocalPort', '()I');
    Finish;
    Start(PacketNative, [Datagram], False, InputStream);
    PacketMethods;
    Method('read', '()I');
    DataMethods(DataInput, InputStream, DataInput + 'Stream', True);
    DataMethods(DataOutput, OutputStream, DataOutput + 'Stream', False);
    Finish;
    B := TJavaClassBuilder.Create(PacketOutput, OutputStream, JVM_ACC_FINAL or $20);
    B.Field(OutputPacketField, 'L' + PacketNative + ';', JVM_ACC_PRIVATE or JVM_ACC_FINAL);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(OutputStream, '<init>', '()V'));
    B.Emit([$2A, $2B]);
    B.Ref($B5, B.Member(PacketOutput, OutputPacketField, 'L' + PacketNative + ';', 9));
    B.Emit([$B1]);
    B.Finish('<init>', '(L' + PacketNative + ';)V', 0, 2, 2);
    Method('write', '(I)V');
    Finish;
    Start(UDPNative, [UDPConnection], False);
    Method('close', '()V');
    Method('getLocalAddress', '()' + StringDesc);
    Method('getLocalPort', '()I');
    ConnectionMethods;
    Finish;
  finally
    B.Free;
  end;
end;

function TJ2MEDatagrams.ParseAddress(const URL: string; AllowServer: Boolean; out Host: string; out Port: Word): Boolean;
begin
  Result := False;
  Host := '';
  Port := 0;
  if not StartsText(URLPrefix, URL) or (Length(URL) > 300) then
    Exit;
  var Authority := Copy(URL, Length(URLPrefix) + 1, MaxInt);
  if Authority = '' then
    Exit(AllowServer);
  var Colon := Pos(':', Authority);
  if Colon = 0 then
    Exit;
  Host := Copy(Authority, 1, Colon - 1);
  if (Host = '') and not AllowServer then
    Exit;
  for var Ch in Host do
    if not CharInSet(Ch, ['a'..'z', 'A'..'Z', '0'..'9', '-', '.']) then
      Exit;
  var Value := 0;
  for var I := Colon + 1 to Length(Authority) do
  begin
    if not CharInSet(Authority[I], ['0'..'9']) then
      Exit;
    Value := Value * 10 + Ord(Authority[I]) - Ord('0');
    if Value > High(Word) then
      Exit;
  end;
  if (Value = 0) and (Host <> '') then
    Exit;
  Port := Word(Value);
  Result := True;
end;

function TJ2MEDatagrams.ResolveEndpoint(const Host: string; Port: Word; out Endpoint: TNetEndpoint): Boolean;
begin
  var Key := LowerCase(Host);
  var Now := FVM.Host.MonotonicMillis;
  var Entry: TJ2MEUDPLookupEntry;
  var Address: TIPAddress;
  var Failure: string;
  var Found := FLookups.TryGetValue(Key, Entry);
  if Found and (Now >= Entry.ExpiresAt) and Entry.Lookup.TryGetResult(Address, Failure) then
  begin
    FLookups.Remove(Key);
    Found := False;
  end;
  if not Found then
  begin
    if FLookups.Count >= LookupLimit then
    begin
      for var Candidate in FLookups.Keys.ToArray do
        if FLookups[Candidate].Lookup.TryGetResult(Address, Failure) then
        begin
          FLookups.Remove(Candidate);
          Break;
        end;
      if FLookups.Count >= LookupLimit then
        FVM.RaiseJava('java/io/IOException', 'Datagram address lookup capacity');
    end;
    try
      Entry.Lookup := StartLookup(Key);
    except
      on E: Exception do
        FVM.RaiseJava('java/io/IOException', E.Message);
    end;
    Entry.ExpiresAt := Now + DNSCacheMillis;
    FLookups.Add(Key, Entry);
  end;
  if Entry.Lookup.TryGetResult(Address, Failure) then
  begin
    if Failure <> '' then
      FVM.RaiseJava('java/io/IOException', Failure);
    Endpoint := TNetEndpoint.Create(Address, Port);
    Exit(True);
  end;
  var Deadline := FVM.NativeContinuation;
  if Deadline.Kind = TJVMKind.Empty then
    FVM.SetNativeContinuation(TJVMValue.Long(Now + DNSWaitMillis))
  else if Now >= Deadline.AsLong then
    FVM.RaiseJava('java/io/InterruptedIOException', 'Datagram address lookup timed out');
  FVM.SleepCurrent(5, 'java/io/InterruptedIOException');
  FVM.RetryNative;
  Result := False;
end;

function TJ2MEDatagrams.Open(const URL: string; Mode: Integer; Timeouts: Boolean): Integer;
begin
  var Host: string;
  var Port: Word;
  if not ParseAddress(URL, True, Host, Port) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram URL');
  if FConnections.Count >= ConnectionLimit then
    FVM.RaiseJava('java/io/IOException', 'Datagram connection capacity');
  var Destination: TNetEndpoint;
  if (Host <> '') and not ResolveEndpoint(Host, Port, Destination) then
    Exit(0);
  var C := TJ2MEUDPConnection.Create;
  try
    C.Mode := Mode;
    C.Timeouts := Timeouts;
    try
      C.Socket := System.Net.Socket.TSocket.Create(TSocketType.UDP);
      if Host <> '' then
      begin
        C.Destination := Destination;
        C.DefaultAddress := URL;
        C.Socket.Bind(0);
      end
      else
        C.Socket.Bind(Port);
    except
      on E: ESocketError do
        FVM.RaiseJava('java/io/IOException', E.Message);
    end;
    Result := FVM.NewObject(UDPNative);
    FConnections.Add(Result, C);
    C := nil;
  finally
    C.Free;
  end;
end;

function TJ2MEDatagrams.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = PacketNative) or (Owner = UDPNative) or (Owner = PacketOutput);
end;

function TJ2MEDatagrams.NewPacket(const Args: TArray<TJVMValue>; const Descriptor, DefaultAddress: string): Integer;
begin
  var Param := 1;
  var BufferRef := 0;
  var HaveBuffer := Descriptor[2] = '[';
  if HaveBuffer then
  begin
    BufferRef := Args[Param].AsRef;
    Inc(Param);
  end;
  var Size := Args[Param].AsInt;
  if (Size < 0) or (Size > MaxPayload) or
    (HaveBuffer and ((BufferRef = 0) or (Size > FVM.GetObject(BufferRef).ElementCount))) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram buffer size');
  var AddressRef := 0;
  if Length(Args) > Param + 1 then
  begin
    AddressRef := Args[Param + 1].AsRef;
    var Host: string;
    var Port: Word;
    if (AddressRef = 0) or not ParseAddress(FVM.GetObject(AddressRef).Text, False, Host, Port) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram destination');
  end;
  Result := FVM.NewObject(PacketNative);
  FVM.AddRoot(Result);
  try
    var Packet := FVM.GetObject(Result);
    if not HaveBuffer then
      BufferRef := FVM.NewArray('[B', Size);
    Packet.Fields.Add(DataKey, TJVMValue.Ref(BufferRef));
    Packet.Fields.Add(OffsetKey, TJVMValue.Int(0));
    Packet.Fields.Add(LengthKey, TJVMValue.Int(Size));
    Packet.Fields.Add(CursorKey, TJVMValue.Int(0));
    if (AddressRef = 0) and (DefaultAddress <> '') then
      AddressRef := FVM.NewString(DefaultAddress);
    Packet.Fields.Add(AddressKey, TJVMValue.Ref(AddressRef));
  finally
    FVM.RemoveRoot(Result);
  end;
end;

function TJ2MEDatagrams.InvokePacket(const Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Packet := FVM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  if Name = 'getData' then
    Exit(Packet.Fields[DataKey]);
  if Name = 'getAddress' then
    Exit(Packet.Fields[AddressKey]);
  if Name = 'getOffset' then
    Exit(Packet.Fields[OffsetKey]);
  if Name = 'getLength' then
    Exit(Packet.Fields[LengthKey]);
  if Name = 'read' then
  begin
    var Cursor := Packet.Fields[CursorKey].AsInt;
    if Cursor >= Packet.Fields[LengthKey].AsInt then
      Exit(TJVMValue.Int(-1));
    var Data := FVM.GetObject(Packet.Fields[DataKey].AsRef);
    var Index := Packet.Fields[OffsetKey].AsInt + Cursor;
    Packet.Fields[CursorKey] := TJVMValue.Int(Cursor + 1);
    Exit(TJVMValue.Int(Byte(Data.ElementValues[Index].AsInt)));
  end;
  if Name = 'setAddress' then
  begin
    var Address := Args[1];
    if (Address.AsRef <> 0) and (Method.Descriptor = '(' + PacketDesc + ')V') then
    begin
      var Other := FVM.GetObject(Address.AsRef);
      if Other.ClassName <> PacketNative then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram object');
      Address := Other.Fields[AddressKey];
    end;
    var Host: string;
    var Port: Word;
    if (Address.AsRef = 0) or not ParseAddress(FVM.GetObject(Address.AsRef).Text, False, Host, Port) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram destination');
    Packet.Fields.AddOrSetValue(AddressKey, Address);
    Exit;
  end;
  if Name = 'reset' then
  begin
    Packet.Fields[OffsetKey] := TJVMValue.Int(0);
    Packet.Fields[LengthKey] := TJVMValue.Int(0);
    Packet.Fields[CursorKey] := TJVMValue.Int(0);
    Exit;
  end;
  var BufferRef := Packet.Fields[DataKey];
  var Offset := Packet.Fields[OffsetKey].AsInt;
  var Size: Integer;
  if Name = 'setData' then
  begin
    BufferRef := Args[1];
    Offset := Args[2].AsInt;
    Size := Args[3].AsInt;
  end
  else
    Size := Args[1].AsInt;
  if (BufferRef.AsRef = 0) or (Offset < 0) or (Size < 0) or
    (Int64(Offset) + Size > FVM.GetObject(BufferRef.AsRef).ElementCount) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram buffer range');
  Packet.Fields[DataKey] := BufferRef;
  Packet.Fields[OffsetKey] := TJVMValue.Int(Offset);
  Packet.Fields[LengthKey] := TJVMValue.Int(Size);
end;

function TJ2MEDatagrams.Invoke(const Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  if Method.Owner.Name = PacketNative then
    Exit(InvokePacket(Method, Args));
  Result := Default(TJVMValue);
  if Method.Owner.Name = PacketOutput then
  begin
    var Stream := FVM.GetObject(Args[0].AsRef);
    var Packet := FVM.GetObject(Stream.Fields[PacketOutput + '.' + OutputPacketField + ':L' + PacketNative + ';'].AsRef);
    var Buffer := FVM.GetObject(Packet.Fields[DataKey].AsRef);
    var Cursor := Packet.Fields[CursorKey].AsInt;
    var Index := Int64(Packet.Fields[OffsetKey].AsInt) + Cursor;
    if Index >= Buffer.ElementCount then
      FVM.RaiseJava('java/io/IOException', 'Datagram output buffer is full');
    Buffer.ElementValues[Integer(Index)] := TJVMValue.Int(ShortInt(Args[1].AsInt));
    Packet.Fields[CursorKey] := TJVMValue.Int(Cursor + 1);
    Packet.Fields[LengthKey] := TJVMValue.Int(Max(Packet.Fields[LengthKey].AsInt, Cursor + 1));
    Exit;
  end;
  var Ref := Args[0].AsRef;
  var Name := Method.Name;
  if Name = 'close' then
  begin
    FConnections.Remove(Ref);
    Exit;
  end;
  var C: TJ2MEUDPConnection;
  if not FConnections.TryGetValue(Ref, C) then
  begin
    if (Name = 'receive') and (FVM.NativeContinuation.Kind <> TJVMKind.Empty) then
      FVM.RaiseJava('java/io/InterruptedIOException', 'Datagram connection closed while receiving');
    FVM.RaiseJava('java/io/IOException', 'Datagram connection closed');
  end;
  if Name = 'getMaximumLength' then
    Exit(TJVMValue.Int(MaxPayload));
  if Name = 'getNominalLength' then
    Exit(TJVMValue.Int(NominalPayload));
  if Name = 'getLocalPort' then
    Exit(TJVMValue.Int(C.Socket.LocalPort));
  if Name = 'getLocalAddress' then
    Exit(TJVMValue.Ref(FVM.NewString(C.Socket.LocalAddress)));
  if Name = 'newDatagram' then
    Exit(TJVMValue.Ref(NewPacket(Args, Method.Descriptor, C.DefaultAddress)));
  var Packet := FVM.GetObject(Args[1].AsRef);
  if Packet.ClassName <> PacketNative then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram object');
  var Buffer := FVM.GetObject(Packet.Fields[DataKey].AsRef);
  var Offset := Packet.Fields[OffsetKey].AsInt;
  var Count := Packet.Fields[LengthKey].AsInt;
  try
    if Name = 'send' then
    begin
      if ((C.Mode and 2) = 0) or (Count > MaxPayload) then
        FVM.RaiseJava('java/io/IOException', 'Datagram cannot be sent');
      var Destination := C.Destination;
      var AddressRef := Packet.Fields[AddressKey].AsRef;
      var Address := C.DefaultAddress;
      if AddressRef <> 0 then
        Address := FVM.GetObject(AddressRef).Text;
      if Address = '' then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'Datagram destination is missing');
      if Address <> C.DefaultAddress then
      begin
        var Host: string;
        var Port: Word;
        if not ParseAddress(Address, False, Host, Port) then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid datagram destination');
        if not ResolveEndpoint(Host, Port, Destination) then
          Exit;
      end;
      var Bytes: TBytes;
      SetLength(Bytes, Max(1, Count));
      for var I := 0 to Count - 1 do
        Bytes[I] := Byte(Buffer.ElementValues[Offset + I].AsInt);
      if C.Socket.SendTo(Bytes[0], Count, Destination) <> Count then
        FVM.RaiseJava('java/io/IOException', 'Incomplete datagram send');
      Exit;
    end;
    if (C.Mode and 1) = 0 then
      FVM.RaiseJava('java/io/IOException', 'Datagram connection is write-only');
    if C.Receiver = nil then
    begin
      C.Receiver := TJ2MEUDPReceiver.Create(C.Socket);
      C.Receiver.Start;
    end;
    var Bytes: TArray<Byte>;
    var Sender: TNetEndpoint;
    var Size: Integer;
    var Failure: string;
    if not C.Receiver.TryRead(Bytes, Size, Sender, Failure) then
    begin
      var Deadline := FVM.NativeContinuation;
      if Deadline.Kind = TJVMKind.Empty then
        FVM.SetNativeContinuation(TJVMValue.Long(FVM.Host.MonotonicMillis + 30000))
      else if C.Timeouts and (FVM.Host.MonotonicMillis >= Deadline.AsLong) then
        FVM.RaiseJava('java/io/InterruptedIOException', 'Datagram receive timed out');
      FVM.SleepCurrent(5, 'java/io/InterruptedIOException');
      FVM.RetryNative;
      Exit;
    end;
    if Failure <> '' then
      FVM.RaiseJava('java/io/IOException', Failure);
    Count := Min(Count, Size);
    for var I := 0 to Count - 1 do
      Buffer.ElementValues[Offset + I] := TJVMValue.Int(ShortInt(Bytes[I]));
    Packet.Fields[LengthKey] := TJVMValue.Int(Count);
    Packet.Fields[AddressKey] := TJVMValue.Ref(FVM.NewString(URLPrefix + Sender.Address.Address + ':' + IntToStr(Sender.Port)));
  except
    on E: ESocketError do
      FVM.RaiseJava('java/io/IOException', E.Message);
  end;
end;

end.

