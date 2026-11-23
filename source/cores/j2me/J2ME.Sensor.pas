unit J2ME.Sensor;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

const
  J2MESensorConnection = 'javax/microedition/sensor/SensorConnection$Device';
  J2MESensorDelivery = '(Ljavax/microedition/sensor/DataListener;[Ljavax/microedition/sensor/Data;ZI)V';

type
  TJ2MESensorInput = record
    Available: Boolean;
    X, Y, Z: Double; // Screen-space g, converted to m/s² when sampled.
  end;

  TJ2MESensors = class
  private
    FVM: TJVM;
    FInput: TJ2MESensorInput;
    FRequested: Boolean;
    function Subscriptions(MIDlet: Integer; Create: Boolean): Integer;
    function NewInfo: Integer;
    function NewChannels: Integer;
    function MakeData(Connection: TJVMObject; Samples: TJVMObject; Size: Integer): Integer;
    procedure SampleInto(Samples: TJVMObject; Index: Integer);
    procedure RemoveListener(MIDlet, Connection: Integer);
  public
    constructor Create(VM: TJVM);
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Open(const URL: string; Mode: Integer): Integer;
    function Invoke(MIDlet: Integer; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function Poll(MIDlet: Integer; Now: Int64; CanDeliver: Boolean; out Args: TArray<TJVMValue>): Boolean;
    property Input: TJ2MESensorInput read FInput write FInput;
    property Requested: Boolean read FRequested;
  end;

implementation

uses
  System.SysUtils;

const
  Prefix = 'javax/microedition/sensor/';
  Manager = Prefix + 'SensorManager';
  Info = Prefix + 'SensorInfo';
  Channel = Prefix + 'ChannelInfo';
  Data = Prefix + 'Data';
  Listener = Prefix + 'DataListener';
  ConnectionAPI = Prefix + 'SensorConnection';
  InfoClass = Info + '$Device';
  ChannelClass = Channel + '$Device';
  DataClass = Data + '$Device';
  StringResult = '()Ljava/lang/String;';
  AccelerationURL = 'sensor:acceleration;contextType=device;model=RetroMul';
  ListenerField = '$sensor.listener';
  SamplesField = '$sensor.samples';
  CountField = '$sensor.count';
  NextField = '$sensor.next';
  LostField = '$sensor.lost';
  ClosedField = '$sensor.closed';
  GenerationField = '$sensor.generation';
  SampleInterval = 20;
  MaxBuffer = 128;
  MaxListeners = 16;
  StateOpened = 1;
  StateListening = 2;
  StateClosed = 4;
  AxisNames: array[0..2] of string = ('axisX', 'axisY', 'axisZ');

function Field(O: TJVMObject; const Key: string): TJVMValue;
begin
  if not O.Fields.TryGetValue(Key, Result) then
    Result := TJVMValue.Int(0);
end;

function RefField(O: TJVMObject; const Key: string): Integer;
var
  Value: TJVMValue;
begin
  if O.Fields.TryGetValue(Key, Value) then
    Exit(Value.AsRef);
  Result := 0;
end;

function MatchesURL(const URL: string): Boolean;
begin
  Result := (URL = 'sensor:acceleration') or (URL = 'sensor:acceleration;contextType=device') or
    (URL = AccelerationURL);
end;

constructor TJ2MESensors.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
end;

procedure TJ2MESensors.Install;
var
  C: TJVMClass;

  procedure Start(const Name: string; IsInterface: Boolean; const Implemented: string = '');
  begin
    C := TJVMClass.Create;
    try
      C.Name := Name;
      C.SuperName := 'java/lang/Object';
      C.Access := JVM_ACC_PUBLIC;
      if IsInterface then
        C.Access := C.Access or $0200 or JVM_ACC_ABSTRACT
      else
        C.Access := C.Access or JVM_ACC_FINAL;
      if Implemented <> '' then
        C.Interfaces := [Implemented];
      FVM.DefineClass(C);
    except
      C.Free;
      raise;
    end;
  end;

  procedure Method(const Name, Descriptor: string);
  begin
    var M := C.AddNative(Name, Descriptor);
    if (C.Access and $0200) <> 0 then
      M.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure Constant(const Name: string; Value: Integer);
  begin
    var Item := TJVMField.Create;
    Item.Name := Name;
    Item.Descriptor := 'I';
    Item.Access := JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL;
    Item.Value := TJVMValue.Int(Value);
    C.Fields.Add(Item);
  end;

begin
  Start(Manager, False);
  C.AddNative('findSensors', '(Ljava/lang/String;Ljava/lang/String;)[L' + Info + ';', True);
  C.AddNative('findSensors', '(Ljava/lang/String;)[L' + Info + ';', True);
  Start(Listener, True);
  Method('dataReceived', '(L' + ConnectionAPI + ';[L' + Data + ';Z)V');
  for var Concrete in [False, True] do
  begin
    if Concrete then
      Start(InfoClass, False, Info)
    else
      Start(Info, True);
    Method('getChannelInfos', '()[L' + Channel + ';');
    for var Name in ['getUrl', 'getQuantity', 'getContextType', 'getModel', 'getDescription'] do
      Method(Name, StringResult);
    Method('getConnectionType', '()I');
    Method('getMaxBufferSize', '()I');
    Method('isAvailable', '()Z');
    Method('isAvailabilityPushSupported', '()Z');
    Method('isConditionPushSupported', '()Z');
    if Concrete then
      Start(ChannelClass, False, Channel)
    else
      Start(Channel, True);
    Method('getName', StringResult);
    Method('getDataType', '()I');
    Method('getScale', '()I');
    if Concrete then
      Start(DataClass, False, Data)
    else
      Start(Data, True);
    Method('getChannelInfo', '()L' + Channel + ';');
    Method('getDoubleValues', '()[D');
    Method('getIntValues', '()[I');
    Method('getObjectValues', '()[Ljava/lang/Object;');
    if Concrete then
    begin
      Start(J2MESensorConnection, False, ConnectionAPI);
      Method('close', '()V');
      Method('$deliver', J2MESensorDelivery);
    end
    else
    begin
      Start(ConnectionAPI, True);
      C.Interfaces := ['javax/microedition/io/Connection'];
      Constant('STATE_OPENED', StateOpened);
      Constant('STATE_LISTENING', StateListening);
      Constant('STATE_CLOSED', StateClosed);
    end;
    Method('getSensorInfo', '()L' + Info + ';');
    Method('getState', '()I');
    Method('getData', '(I)[L' + Data + ';');
    Method('setDataListener', '(L' + Listener + ';I)V');
    Method('removeDataListener', '()V');
  end;
end;

function TJ2MESensors.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = Manager) or (Owner = InfoClass) or (Owner = ChannelClass) or
    (Owner = DataClass) or (Owner = J2MESensorConnection);
end;

function TJ2MESensors.Subscriptions(MIDlet: Integer; Create: Boolean): Integer;
begin
  if MIDlet = 0 then
    Exit(0);
  var O := FVM.GetObject(MIDlet);
  Result := RefField(O, '$sensor.subscriptions');
  if (Result = 0) and Create then
  begin
    Result := FVM.NewArray('[L' + J2MESensorConnection + ';', MaxListeners);
    O.Fields.Add('$sensor.subscriptions', TJVMValue.Ref(Result));
  end;
end;

function TJ2MESensors.NewInfo: Integer;
begin
  Result := FVM.NewObject(InfoClass);
  FVM.GetObject(Result).Fields.Add('$sensor.channels', TJVMValue.Ref(NewChannels));
end;

function TJ2MESensors.NewChannels: Integer;
begin
  Result := FVM.NewArray('[L' + Channel + ';', Length(AxisNames));
  for var Axis := 0 to High(AxisNames) do
  begin
    var Ref := FVM.NewObject(ChannelClass);
    FVM.GetObject(Ref).Fields.Add('$sensor.axis', TJVMValue.Int(Axis));
    FVM.GetObject(Result).ElementValues[Axis] := TJVMValue.Ref(Ref);
  end;
end;

procedure TJ2MESensors.SampleInto(Samples: TJVMObject; Index: Integer);
const
  StandardGravity = 9.80665;
begin
  Samples.ElementValues[Index * 3] := TJVMValue.Double(FInput.X * StandardGravity);
  Samples.ElementValues[Index * 3 + 1] := TJVMValue.Double(FInput.Y * StandardGravity);
  Samples.ElementValues[Index * 3 + 2] := TJVMValue.Double(FInput.Z * StandardGravity);
end;

function TJ2MESensors.MakeData(Connection, Samples: TJVMObject; Size: Integer): Integer;
begin
  Result := FVM.NewArray('[L' + Data + ';', Length(AxisNames));
  var InfoObject := FVM.GetObject(RefField(Connection, '$sensor.info'));
  var Channels := FVM.GetObject(RefField(InfoObject, '$sensor.channels'));
  for var Axis := 0 to High(AxisNames) do
  begin
    var Values := FVM.NewArray('[D', Size);
    var ValuesObject := FVM.GetObject(Values);
    for var Sample := 0 to Size - 1 do
      ValuesObject.ElementValues[Sample] := Samples.ElementValues[Sample * 3 + Axis];
    var Item := FVM.NewObject(DataClass);
    var ItemObject := FVM.GetObject(Item);
    ItemObject.Fields.Add('$sensor.channel', Channels.ElementValues[Axis]);
    ItemObject.Fields.Add('$sensor.values', TJVMValue.Ref(Values));
    FVM.GetObject(Result).ElementValues[Axis] := TJVMValue.Ref(Item);
  end;
end;

function TJ2MESensors.Open(const URL: string; Mode: Integer): Integer;
begin
  FRequested := True;
  if not FInput.Available or not MatchesURL(URL) then
    FVM.RaiseJava('javax/microedition/io/ConnectionNotFoundException', URL);
  if Mode = 2 then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'Sensor connections are read only');
  Result := FVM.NewObject(J2MESensorConnection);
  FVM.GetObject(Result).Fields.Add('$sensor.info', TJVMValue.Ref(NewInfo));
end;

procedure TJ2MESensors.RemoveListener(MIDlet, Connection: Integer);
begin
  var Registry := Subscriptions(MIDlet, False);
  if Registry <> 0 then
    for var I := 0 to MaxListeners - 1 do
      if FVM.GetObject(Registry).ElementValues[I].AsRef = Connection then
      begin
        FVM.GetObject(Registry).ElementValues[I] := TJVMValue.Ref(0);
        Break;
      end;
  var O := FVM.GetObject(Connection);
  if O.Fields.ContainsKey(ListenerField) then
  begin
    O.Fields.Remove(ListenerField);
    var Generation := Field(O, GenerationField).AsInt;
    if Generation = MaxInt then
      Generation := 0;
    O.Fields.AddOrSetValue(GenerationField, TJVMValue.Int(Generation + 1));
  end;
  O.Fields.Remove(SamplesField);
  O.Fields.Remove(CountField);
  O.Fields.Remove(NextField);
  O.Fields.Remove(LostField);
end;

function TJ2MESensors.Invoke(MIDlet: Integer; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  var Owner := Method.Owner.Name;
  var Name := Method.Name;
  if Owner = Manager then
  begin
    FRequested := True;
    var Match: Boolean;
    if Length(Args) = 1 then
    begin
      if Args[0].AsRef = 0 then
        FVM.RaiseJava('java/lang/NullPointerException', 'sensor URL');
      var URL := FVM.GetObject(Args[0].AsRef).Text;
      if not URL.StartsWith('sensor:') then
        FVM.RaiseJava('java/lang/IllegalArgumentException', 'sensor URL');
      Match := MatchesURL(URL);
    end
    else
    begin
      var Context := '';
      if Args[1].AsRef <> 0 then
      begin
        Context := FVM.GetObject(Args[1].AsRef).Text;
        if (Context <> 'device') and (Context <> 'ambient') and (Context <> 'user') then
          FVM.RaiseJava('java/lang/IllegalArgumentException', 'sensor context');
      end;
      Match := ((Args[1].AsRef = 0) or (Context = 'device')) and
        ((Args[0].AsRef = 0) or (FVM.GetObject(Args[0].AsRef).Text = 'acceleration'));
    end;
    Match := Match and FInput.Available;
    var Ref := FVM.NewArray('[L' + Info + ';', Ord(Match));
    if Match then
      FVM.GetObject(Ref).ElementValues[0] := TJVMValue.Ref(NewInfo);
    Exit(TJVMValue.Ref(Ref));
  end;

  var This := Args[0].AsRef;
  var O := FVM.GetObject(This);
  if Owner = InfoClass then
  begin
    if Name = 'getUrl' then
      Exit(TJVMValue.Ref(FVM.NewString(AccelerationURL)));
    if Name = 'getQuantity' then
      Exit(TJVMValue.Ref(FVM.NewString('acceleration')));
    if Name = 'getContextType' then
      Exit(TJVMValue.Ref(FVM.NewString('device')));
    if Name = 'getModel' then
      Exit(TJVMValue.Ref(FVM.NewString('RetroMul')));
    if Name = 'getDescription' then
      Exit(TJVMValue.Ref(FVM.NewString('Device acceleration')));
    if Name = 'getConnectionType' then
      Exit(TJVMValue.Int(1));
    if Name = 'getMaxBufferSize' then
      Exit(TJVMValue.Int(MaxBuffer));
    if Name = 'isAvailable' then
      Exit(TJVMValue.Int(Ord(FInput.Available)));
    if Name = 'getChannelInfos' then
    begin
      var Ref := FVM.NewArray('[L' + Channel + ';', Length(AxisNames));
      var Source := FVM.GetObject(RefField(O, '$sensor.channels'));
      for var Axis := 0 to High(AxisNames) do
        FVM.GetObject(Ref).ElementValues[Axis] := Source.ElementValues[Axis];
      Exit(TJVMValue.Ref(Ref));
    end;
    Exit(TJVMValue.Int(0));
  end;
  if Owner = ChannelClass then
  begin
    if Name = 'getName' then
      Exit(TJVMValue.Ref(FVM.NewString(AxisNames[Field(O, '$sensor.axis').AsInt])));
    if Name = 'getDataType' then
      Exit(TJVMValue.Int(1)); // TYPE_DOUBLE
    Exit(TJVMValue.Int(0)); // Decimal scale.
  end;
  if Owner = DataClass then
  begin
    if Name = 'getChannelInfo' then
      Exit(TJVMValue.Ref(RefField(O, '$sensor.channel')));
    if Name <> 'getDoubleValues' then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Sensor channel contains double values');
    var Source := FVM.GetObject(RefField(O, '$sensor.values'));
    var Ref := FVM.NewArray('[D', Source.ElementCount);
    for var I := 0 to Source.ElementCount - 1 do
      FVM.GetObject(Ref).ElementValues[I] := Source.ElementValues[I];
    Exit(TJVMValue.Ref(Ref));
  end;

  Result := Default(TJVMValue);
  var CurrentListener := RefField(O, ListenerField);
  if Name = '$deliver' then
  begin
    if (CurrentListener = Args[1].AsRef) and (CurrentListener <> 0) and
      (Field(O, GenerationField).AsInt = Args[4].AsInt) then
    begin
      var C := FVM.LoadClass(FVM.GetObject(CurrentListener).ClassName);
      FVM.InvokeGuest(FVM.ResolveMethod(C, 'dataReceived', '(L' + ConnectionAPI + ';[L' + Data + ';Z)V'),
        [Args[1], Args[0], Args[2], Args[3]]);
    end;
    Exit;
  end;
  var Closed := Field(O, ClosedField).AsInt <> 0;
  if Name = 'getSensorInfo' then
    Exit(TJVMValue.Ref(RefField(O, '$sensor.info')));
  if Name = 'getState' then
  begin
    if Closed then
      Exit(TJVMValue.Int(StateClosed));
    if CurrentListener <> 0 then
      Exit(TJVMValue.Int(StateListening));
    Exit(TJVMValue.Int(StateOpened));
  end;
  if Name = 'close' then
  begin
    RemoveListener(MIDlet, This);
    O.Fields.AddOrSetValue(ClosedField, TJVMValue.Int(1));
    Exit;
  end;
  if Name = 'getData' then
  begin
    var Size := Args[1].AsInt;
    if (Size < 1) or (Size > MaxBuffer) then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'sensor buffer size');
    if Closed or not FInput.Available then
      FVM.RaiseJava('java/io/IOException', 'Sensor is unavailable');
    if CurrentListener <> 0 then
      FVM.RaiseJava('java/lang/IllegalStateException', 'Sensor connection is listening');
    var Continuation := FVM.NativeContinuation;
    var Batch: Integer;
    if Continuation.Kind = TJVMKind.Reference then
      Batch := Continuation.AsRef
    else
    begin
      Batch := FVM.NewObject(DataClass);
      var Buffer := FVM.NewArray('[D', Size * Length(AxisNames));
      FVM.GetObject(Batch).Fields.Add(SamplesField, TJVMValue.Ref(Buffer));
      FVM.SetNativeContinuation(TJVMValue.Ref(Batch));
    end;
    var BatchObject := FVM.GetObject(Batch);
    var Samples := FVM.GetObject(RefField(BatchObject, SamplesField));
    var Count := Field(BatchObject, CountField).AsInt;
    SampleInto(Samples, Count);
    Inc(Count);
    if Count = Size then
      Exit(TJVMValue.Ref(MakeData(O, Samples, Size)));
    BatchObject.Fields.AddOrSetValue(CountField, TJVMValue.Int(Count));
    FVM.SleepCurrent(SampleInterval, 'java/io/InterruptedIOException');
    FVM.RetryNative;
    Exit;
  end;
  if Closed then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Sensor connection is closed');
  if Name = 'removeDataListener' then
  begin
    RemoveListener(MIDlet, This);
    Exit;
  end;
  if Args[1].AsRef = 0 then
    FVM.RaiseJava('java/lang/NullPointerException', 'sensor listener');
  var Size := Args[2].AsInt;
  if (Size < 1) or (Size > MaxBuffer) then
    FVM.RaiseJava('java/lang/IllegalArgumentException', 'sensor buffer size');
  var Registry := Subscriptions(MIDlet, True);
  if Registry = 0 then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Sensor listener requires an active MIDlet');
  var Entries := FVM.GetObject(Registry);
  RemoveListener(MIDlet, This);
  for var I := 0 to MaxListeners - 1 do
    if Entries.ElementValues[I].AsRef = 0 then
    begin
      var Samples := FVM.NewArray('[D', Size * Length(AxisNames));
      O.Fields.Add(ListenerField, Args[1]);
      O.Fields.Add(SamplesField, TJVMValue.Ref(Samples));
      Entries.ElementValues[I] := Args[0];
      Exit;
    end;
  FVM.RaiseJava('java/lang/IllegalStateException', 'Too many sensor listeners');
end;

function TJ2MESensors.Poll(MIDlet: Integer; Now: Int64; CanDeliver: Boolean; out Args: TArray<TJVMValue>): Boolean;
begin
  Result := False;
  var Registry := Subscriptions(MIDlet, False);
  if Registry = 0 then
    Exit;
  FRequested := True;
  if not FInput.Available then
    Exit;
  var Anchor := FVM.GetObject(MIDlet);
  var Entries := FVM.GetObject(Registry);
  var Start := Field(Anchor, '$sensor.cursor').AsInt;
  for var Offset := 0 to MaxListeners - 1 do
  begin
    var Index := (Start + Offset) mod MaxListeners;
    var Connection := Entries.ElementValues[Index].AsRef;
    if Connection = 0 then
      Continue;
    var O := FVM.GetObject(Connection);
    var Samples := FVM.GetObject(RefField(O, SamplesField));
    var Size := Samples.ElementCount div Length(AxisNames);
    var Count := Field(O, CountField).AsInt;
    var Next: TJVMValue;
    if not O.Fields.TryGetValue(NextField, Next) or (Now >= Next.AsLong) then
    begin
      O.Fields.AddOrSetValue(NextField, TJVMValue.Long(Now + SampleInterval));
      if Count < Size then
      begin
        SampleInto(Samples, Count);
        Inc(Count);
        O.Fields.AddOrSetValue(CountField, TJVMValue.Int(Count));
      end
      else
        O.Fields.AddOrSetValue(LostField, TJVMValue.Int(1));
    end;
    if not CanDeliver or Result or (Count < Size) then
      Continue;
    var DataRef := MakeData(O, Samples, Size);
    Args := [TJVMValue.Ref(Connection), TJVMValue.Ref(RefField(O, ListenerField)),
        TJVMValue.Ref(DataRef), Field(O, LostField), Field(O, GenerationField)];
    O.Fields.Remove(CountField);
    O.Fields.Remove(LostField);
    Anchor.Fields.AddOrSetValue('$sensor.cursor', TJVMValue.Int((Index + 1) mod MaxListeners));
    Result := True;
  end;
end;

end.

