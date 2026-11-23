unit AVM1.Broadcaster;

interface

uses
  System.SysUtils, AVM1.Runtime;

procedure RegisterAVMBroadcaster(VM: TAVM1);

procedure AVMInitializeBroadcaster(VM: TAVM1; O: TAVMObject);

function AVMBroadcasterCall(VM: TAVM1; const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;

function AVMBroadcast(VM: TAVM1; ThisObj: TAVMObject; const Name: string; const Args: TArray<TAVMValue>): Boolean;

implementation

uses
  AVM1.Coercion, SWF.Reader;

procedure AVMInitializeBroadcaster(VM: TAVM1; O: TAVMObject);
var
  ConstructorValue: TAVMValue;
  Name: string;
  Flags: Word;
begin
  if O = nil then
    Exit;
  VM.Put(O, 'broadcastMessage', VM.NativeFunction('AsBroadcaster.broadcastMessage'));
  ConstructorValue := VM.Get(VM.Global, 'AsBroadcaster');
  VM.Put(O, 'addListener', VM.Get(ConstructorValue.Obj, 'addListener'));
  ConstructorValue := VM.Get(VM.Global, 'AsBroadcaster');
  VM.Put(O, 'removeListener', VM.Get(ConstructorValue.Obj, 'removeListener'));
  VM.Put(O, '_listeners', TAVMValue.Ref(VM.CreateArray(nil)));
  for Name in ['broadcastMessage', 'addListener', 'removeListener', '_listeners'] do
  begin
    Flags := 0;
    O.Attributes.TryGetValue(Name, Flags);
    O.Attributes.AddOrSetValue(Name, Flags or 3);
  end;
end;

procedure RegisterAVMBroadcaster(VM: TAVM1);
var
  ConstructorValue: TAVMValue;
  PrototypeObject, NamespaceObject, Owner: TAVMObject;
  Name: string;
begin
  ConstructorValue := VM.NativeFunction('AsBroadcaster');
  PrototypeObject := VM.NewObject;
  VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  ConstructorValue.Obj.Attributes.AddOrSetValue('prototype', $83);
  VM.PutData(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
  VM.PutData(VM.Global, 'AsBroadcaster', ConstructorValue);
  for Name in ['broadcastMessage', 'addListener', 'removeListener', 'initialize'] do
  begin
    VM.PutData(ConstructorValue.Obj, Name, VM.NativeFunction('AsBroadcaster.' + Name));
    ConstructorValue.Obj.Attributes.AddOrSetValue(Name, $83);
  end;
  NamespaceObject := VM.NewObject;
  VM.Put(VM.Global, 'System', TAVMValue.Ref(NamespaceObject));
  Owner := VM.NewObject;
  VM.Put(NamespaceObject, 'IME', TAVMValue.Ref(Owner));
  AVMInitializeBroadcaster(VM, Owner);
  // Register the standard event-carrier prototypes. Their other native APIs
  // are implemented separately; these slots share AsBroadcaster's functions.
  NamespaceObject := VM.Get(VM.Global, 'flash').Obj;
  Owner := VM.NewObject;
  VM.Put(NamespaceObject, 'net', TAVMValue.Ref(Owner));
  for Name in ['TextField', 'FileReference', 'FileReferenceList'] do
  begin
    ConstructorValue := VM.NativeFunction(Name);
    PrototypeObject := VM.NewObject;
    VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
    ConstructorValue.Obj.Attributes.AddOrSetValue('prototype', 3);
    VM.PutData(PrototypeObject, 'constructor', ConstructorValue);
    PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
    AVMInitializeBroadcaster(VM, PrototypeObject);
    if Name = 'TextField' then
      VM.Put(VM.Global, Name, ConstructorValue)
    else
      VM.Put(Owner, Name, ConstructorValue);
  end;
end;

function AVMBroadcast(VM: TAVM1; ThisObj: TAVMObject; const Name: string; const Args: TArray<TAVMValue>): Boolean;
var
  ListValue, Value: TAVMValue;
  ListObject, Listener: TAVMObject;
  Count, I: Integer;
  Snapshot: TArray<TAVMValue>;
begin
  Result := False;
  ListValue := VM.GetSpecial(ThisObj, '_listeners');
  ListObject := ListValue.Obj;
  if ListObject = nil then
    Exit;
  // Native collection reads stored length/elements without invoking accessors.
  Count := AVMToInt32(VM.CoerceNumber(VM.GetData(ListObject, 'length')));
  if Count < 0 then
    Count := 0;
  if Count > 65536 then
    raise ESWFError.Create('AVM1 broadcaster listener limit');
  VM.ChargeWork(Count);
  SetLength(Snapshot, Count);
  for I := 0 to Count - 1 do
    Snapshot[I] := VM.GetData(ListObject, IntToStr(I));
  for Value in Snapshot do
  begin
    Listener := VM.Box(Value);
    if Listener = nil then
      Continue;
    Result := True;
    if Name = '' then
      VM.Call(TAVMValue.Ref(Listener), Listener, Args)
    else
      VM.Call(VM.GetSpecial(Listener, Name), Listener, Args);
  end;
end;

function AVMBroadcasterCall(VM: TAVM1; const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Listener, ListValue, Method, LengthValue: TAVMValue;
  ListObject: TAVMObject;
  I: Integer;
  EventName: string;
begin
  Result := Default(TAVMValue);
  Listener := Default(TAVMValue);
  if Length(Args) > 0 then
    Listener := Args[0];
  if Name = 'AsBroadcaster' then
    Exit;
  if Name = 'AsBroadcaster.initialize' then
  begin
    AVMInitializeBroadcaster(VM, VM.Box(Listener));
    Exit;
  end;
  if Name = 'AsBroadcaster.addListener' then
  begin
    Method := VM.Get(ThisObj, 'removeListener');
    VM.Call(Method, ThisObj, [Listener]);
    ListValue := VM.Get(ThisObj, '_listeners');
    ListObject := VM.Box(ListValue);
    VM.Call(VM.Get(ListObject, 'push'), ListObject, [Listener]);
    Exit(TAVMValue.Bool(True));
  end;
  if Name = 'AsBroadcaster.removeListener' then
  begin
    ListValue := VM.Get(ThisObj, '_listeners');
    ListObject := VM.Box(ListValue);
    I := 0;
    while True do
    begin
      VM.ChargeWork(1);
      LengthValue := VM.Get(ListObject, 'length');
      if not VM.LessThan(TAVMValue.Num(I), LengthValue).AsBoolean(VM.SWFVersion) then
        Break;
      if VM.EqualValues(VM.Get(ListObject, IntToStr(I)), Listener, False) then
      begin
        VM.Call(VM.Get(ListObject, 'splice'), ListObject, [TAVMValue.Num(I), TAVMValue.Num(1)]);
        Exit(TAVMValue.Bool(True));
      end;
      Inc(I);
    end;
    Exit(TAVMValue.Bool(False));
  end;
  if (Name = 'AsBroadcaster.broadcastMessage') and (Length(Args) > 0) then
  begin
    EventName := VM.CoerceString(Listener);
    if AVMBroadcast(VM, ThisObj, EventName, Copy(Args, 1, MaxInt)) then
      Result := TAVMValue.Bool(True);
  end;
end;

end.

