unit J2ME.RMS;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Runtime, Core.Storage, J2ME.RMS.Store;

type
  TRMSHandle = class
  public
    Reference, Opens: Integer;
    Lease: TRMSLease;
    destructor Destroy; override;
  end;

  TRMSIterator = class
  public
    Reference, Store, Cursor: Integer;
    Version: Int64;
    Built, KeepUpdated, Destroyed, Gap: Boolean;
  end;

  TJ2MERMS = class
  private
    FVM: TJVM;
    FDatabase: TRMSDatabase;
    FVendor, FSuite: string;
    FHandles: TObjectDictionary<Integer, TRMSHandle>;
    FOpen: TDictionary<string, Integer>;
    FEnums: TObjectDictionary<Integer, TRMSIterator>;
    function Handle(Ref: Integer): TRMSHandle;
    function Iterator(Ref: Integer): TRMSIterator;
    function Bytes(Ref, Offset, Count: Integer; Nullable: Boolean): TBytes;
    function ArrayBytes(const Data: TBytes; EmptyNull: Boolean = True): Integer;
    function StoreObject(const Name, Vendor, Suite: string; CreateIfMissing: Boolean; Mode: Integer; Writable: Boolean): Integer;
    function Rebuild(E: TRMSIterator; Auto: Boolean): Boolean;
    function Ensure(E: TRMSIterator): Boolean;
    function Advance(E: TRMSIterator; forward: Boolean): Integer;
    procedure Notify(H: TRMSHandle; Kind, ID: Integer);
    procedure Sweep;
  public
    constructor Create(VM: TJVM; const Storage: IStorage; const Vendor, Suite: string);
    destructor Destroy; override;
    procedure Install;
    function Handles(const Owner: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function TakeNotification(out StoreRef, Kind, ID: Integer): Boolean;
    procedure Shutdown;
  end;

implementation

uses
  System.Math, System.Classes, Java.Classes;

{$Q-}{$R-}

const
  RMS = 'javax/microedition/rms/';
  Store = RMS + 'RecordStore';
  EnumAPI = RMS + 'RecordEnumeration';
  EnumImpl = 'org/retromul/rms/Enumeration';
  Filter = RMS + 'RecordFilter';
  Comparator = RMS + 'RecordComparator';
  Listener = RMS + 'RecordListener';
  StoreD = 'Ljavax/microedition/rms/RecordStore;';
  EnumD = 'Ljavax/microedition/rms/RecordEnumeration;';
  ListenerField = Store + '.$listeners:[Ljavax/microedition/rms/RecordListener;';
  RowsField = EnumImpl + '.$rows:[Ljava/lang/Object;';
  StoreField = EnumImpl + '.$store:' + StoreD;
  FilterField = EnumImpl + '.$filter:Ljavax/microedition/rms/RecordFilter;';
  ComparatorField = EnumImpl + '.$comparator:Ljavax/microedition/rms/RecordComparator;';

function Int(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function Ref(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Name, TJVMValue.Int(Value));
end;

procedure PutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Name, TJVMValue.Ref(Value));
end;

destructor TRMSHandle.Destroy;
begin
  Lease.Free;
  inherited;
end;

constructor TJ2MERMS.Create(VM: TJVM; const Storage: IStorage; const Vendor, Suite: string);
begin
  inherited Create;
  FVM := VM;
  FVendor := Vendor;
  FSuite := Suite;
  FDatabase := TRMSDatabase.Create(Storage, Vendor, Suite);
  FDatabase.Cancelled :=
    function: Boolean
    begin
      var Executor := TThread.CurrentThread;
      if not Executor.ExternalThread then
        if Executor.CheckTerminated then
          VM.RequestStop;
      Result := VM.StopRequested;
    end;
  FHandles := TObjectDictionary<Integer, TRMSHandle>.Create([doOwnsValues]);
  FOpen := TDictionary<string, Integer>.Create;
  FEnums := TObjectDictionary<Integer, TRMSIterator>.Create([doOwnsValues]);
end;

destructor TJ2MERMS.Destroy;
begin
  Shutdown;
  FEnums.Free;
  FOpen.Free;
  FHandles.Free;
  FDatabase.Free;
  inherited;
end;

procedure TJ2MERMS.Shutdown;
begin
  if FHandles = nil then
    Exit;
  for var H in FHandles.Values do
    if H.Opens > 0 then
    begin
      H.Opens := 0;
      FVM.RemoveRoot(H.Reference);
      FreeAndNil(H.Lease);
    end;
  FOpen.Clear;
end;

procedure TJ2MERMS.Install;
var
  B: TJavaClassBuilder;

  procedure Native(const Name, D: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, D).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure AbstractMethod(const Name, D: string);
  begin
    B.JavaClass.AddNative(Name, D).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure Done;
  begin
    FVM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

begin
  B := nil;
  try
    for var Name in ['RecordStoreException', 'RecordStoreFullException', 'RecordStoreNotFoundException', 'RecordStoreNotOpenException', 'InvalidRecordIDException'] do
    begin
      var Parent := RMS + 'RecordStoreException';
      if Name = 'RecordStoreException' then
        Parent := 'java/lang/Exception';
      B := TJavaClassBuilder.Create(RMS + Name, Parent);
      Native('<init>', '()V');
      Native('<init>', '(Ljava/lang/String;)V');
      Done;
    end;
    B := TJavaClassBuilder.Create(Filter, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    AbstractMethod('matches', '([B)Z');
    Done;
    B := TJavaClassBuilder.Create(Comparator, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    AbstractMethod('compare', '([B[B)I');
    for var I := -1 to 1 do
    begin
      var Name := 'EQUIVALENT';
      if I = -1 then
        Name := 'PRECEDES'
      else if I = 1 then
        Name := 'FOLLOWS';
      B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
    end;
    Done;
    B := TJavaClassBuilder.Create(Listener, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    for var Name in ['recordAdded', 'recordChanged', 'recordDeleted'] do
      AbstractMethod(Name, '(' + StoreD + 'I)V');
    Done;
    B := TJavaClassBuilder.Create(Store, 'java/lang/Object');
    B.Field('$listeners', '[Ljavax/microedition/rms/RecordListener;', JVM_ACC_PRIVATE);
    for var I := 0 to 1 do
    begin
      var Name := 'AUTHMODE_PRIVATE';
      if I = 1 then
        Name := 'AUTHMODE_ANY';
      B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
    end;
    for var D in ['(Ljava/lang/String;Z)', '(Ljava/lang/String;ZIZ)', '(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)'] do
      Native('openRecordStore', D + StoreD, JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('deleteRecordStore', '(Ljava/lang/String;)V', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('listRecordStores', '()[Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    Native('closeRecordStore', '()V');
    Native('getName', '()Ljava/lang/String;');
    for var Name in ['getVersion', 'getNumRecords', 'getSize', 'getSizeAvailable', 'getNextRecordID'] do
      Native(Name, '()I');
    Native('getLastModified', '()J');
    Native('setMode', '(IZ)V');
    Native('addRecord', '([BII)I');
    Native('setRecord', '(I[BII)V');
    Native('deleteRecord', '(I)V');
    Native('getRecord', '(I)[B');
    Native('getRecord', '(I[BI)I');
    Native('getRecordSize', '(I)I');
    Native('enumerateRecords', '(Ljavax/microedition/rms/RecordFilter;Ljavax/microedition/rms/RecordComparator;Z)' + EnumD);
    for var Name in ['addRecordListener', 'removeRecordListener'] do
      Native(Name, '(Ljavax/microedition/rms/RecordListener;)V');
    Native('$notifyPending', '(II)V');
    // Listener callbacks are ordinary guest frames, including nested mutations,
    // scheduling, exceptions and GC. The mutation has already committed.
    B.Start;
    B.Emit([$03, $36, 4]);
    B.Mark('loop');
    B.Emit([$15, 4, $2B, $BE]);
    B.Jump($A2, 'end');
    B.Emit([$2B, $15, 4, $32, $3A, 5, $1C, $04]);
    B.Jump($A0, 'changed');
    B.Emit([$19, 5, $2A, $1D]);
    B.Ref($B9, B.Member(Listener, 'recordAdded', '(' + StoreD + 'I)V', 11));
    B.Emit([3, 0]);
    B.Jump($A7, 'next');
    B.Mark('changed');
    B.Emit([$1C, $05]);
    B.Jump($A0, 'deleted');
    B.Emit([$19, 5, $2A, $1D]);
    B.Ref($B9, B.Member(Listener, 'recordChanged', '(' + StoreD + 'I)V', 11));
    B.Emit([3, 0]);
    B.Jump($A7, 'next');
    B.Mark('deleted');
    B.Emit([$19, 5, $2A, $1D]);
    B.Ref($B9, B.Member(Listener, 'recordDeleted', '(' + StoreD + 'I)V', 11));
    B.Emit([3, 0]);
    B.Mark('next');
    B.Emit([$84, 4, 1]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$B1]);
    B.Finish('$notify', '([Ljavax/microedition/rms/RecordListener;II)V', JVM_ACC_PRIVATE, 3, 6);
    Done;
    B := TJavaClassBuilder.Create(EnumAPI, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    for var Name in ['numRecords', 'nextRecordId', 'previousRecordId'] do
      AbstractMethod(Name, '()I');
    for var Name in ['nextRecord', 'previousRecord'] do
      AbstractMethod(Name, '()[B');
    for var Name in ['reset', 'rebuild', 'destroy'] do
      AbstractMethod(Name, '()V');
    for var Name in ['hasNextElement', 'hasPreviousElement', 'isKeptUpdated'] do
      AbstractMethod(Name, '()Z');
    AbstractMethod('keepUpdated', '(Z)V');
    Done;
    B := TJavaClassBuilder.Create(EnumImpl, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    B.JavaClass.Interfaces := [EnumAPI];
    B.Field('$store', StoreD, JVM_ACC_PRIVATE);
    B.Field('$rows', '[Ljava/lang/Object;', JVM_ACC_PRIVATE);
    B.Field('$filter', 'Ljavax/microedition/rms/RecordFilter;', JVM_ACC_PRIVATE);
    B.Field('$comparator', 'Ljavax/microedition/rms/RecordComparator;', JVM_ACC_PRIVATE);
    for var Name in ['numRecords', 'nextRecordId', 'previousRecordId'] do
      Native(Name, '()I');
    for var Name in ['nextRecord', 'previousRecord'] do
      Native(Name, '()[B');
    for var Name in ['reset', 'rebuild', 'destroy', '$rebuildUpdated'] do
      Native(Name, '()V');
    for var Name in ['hasNextElement', 'hasPreviousElement', 'isKeptUpdated'] do
      Native(Name, '()Z');
    Native('keepUpdated', '(Z)V');
    Done;
  finally
    B.Free;
  end;
end;

function TJ2MERMS.Handles(const Owner: string): Boolean;
begin
  Result := (Owner = Store) or (Owner = EnumImpl);
end;

procedure TJ2MERMS.Sweep;
begin
  for var R in FEnums.Keys.ToArray do
    if not FVM.IsObjectAlive(R) then
      FEnums.Remove(R);
  for var R in FHandles.Keys.ToArray do
    if (FHandles[R].Opens = 0) and not FVM.IsObjectAlive(R) then
      FHandles.Remove(R);
end;

function TJ2MERMS.Handle(Ref: Integer): TRMSHandle;
begin
  FVM.GetObject(Ref);
  if not FHandles.TryGetValue(Ref, Result) or (Result.Opens = 0) then
    raise ERMS.Create('RecordStoreNotOpenException', 'RecordStore is closed');
end;

function TJ2MERMS.Iterator(Ref: Integer): TRMSIterator;
begin
  FVM.GetObject(Ref);
  if not FEnums.TryGetValue(Ref, Result) or Result.Destroyed then
    FVM.RaiseJava('java/lang/IllegalStateException', 'Enumeration is destroyed');
end;

function TJ2MERMS.Bytes(Ref, Offset, Count: Integer; Nullable: Boolean): TBytes;
begin
  Result := nil;
  if (Offset < 0) or (Count < 0) then
    FVM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  if (Ref = 0) and Nullable and (Count = 0) then
    Exit;
  var A := FVM.GetObject(Ref);
  if (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
    FVM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  SetLength(Result, Count);
  for var I := 0 to Count - 1 do
    Result[I] := Byte(A.Elements[Offset + I].AsInt);
end;

function TJ2MERMS.ArrayBytes(const Data: TBytes; EmptyNull: Boolean): Integer;
begin
  if EmptyNull and (Length(Data) = 0) then
    Exit(0);
  Result := FVM.NewArray('[B', Length(Data));
  for var I := 0 to High(Data) do
    FVM.GetObject(Result).Elements[I] := TJVMValue.Int(ShortInt(Data[I]));
end;

function TJ2MERMS.StoreObject(const Name, Vendor, Suite: string; CreateIfMissing: Boolean; Mode: Integer; Writable: Boolean): Integer;
begin
  if (Length(Name) < 1) or (Length(Name) > 32) then
    raise ERMS.Create('IllegalArgumentException', 'RecordStore name');
  Sweep;
  var Key := FDatabase.StoreFile(Vendor, Suite, Name);
  // Open rechecks current authorization even if this VM already has the object.
  var Lease := FDatabase.Open(Vendor, Suite, Name, CreateIfMissing, Mode, Writable, FVM.Host.TimeMillis);
  try
    if FOpen.TryGetValue(Key, Result) then
    begin
      Inc(FHandles[Result].Opens);
      Exit;
    end;
    Result := FVM.NewObject(Store);
    var H := TRMSHandle.Create;
    try
      H.Reference := Result;
      H.Opens := 1;
      H.Lease := Lease;
      Lease := nil;
      FHandles.Add(Result, H);
      H := nil;
    finally
      H.Free;
    end;
    FOpen.Add(Key, Result);
    FVM.AddRoot(Result);
  finally
    Lease.Free;
  end;
end;

procedure TJ2MERMS.Notify(H: TRMSHandle; Kind, ID: Integer);
begin
  var R := Ref(FVM.GetObject(H.Reference), ListenerField);
  if (R = 0) or (Length(FVM.GetObject(R).Elements) = 0) then
    Exit;
  FVM.InvokeGuest(FVM.LoadClass(Store).FindMethod('$notify', '([Ljavax/microedition/rms/RecordListener;II)V'),
    [TJVMValue.Ref(H.Reference), TJVMValue.Ref(R), TJVMValue.Int(Kind), TJVMValue.Int(ID)]);
end;

function TJ2MERMS.TakeNotification(out StoreRef, Kind, ID: Integer): Boolean;
var
  Change: TRMSChange;
begin
  Result := False;
  for var H in FHandles.Values do
    if (H.Opens > 0) and H.Lease.TakeChange(Change) then
    begin
      StoreRef := H.Reference;
      Kind := Change.Kind;
      ID := Change.ID;
      Exit(True);
    end;
end;

function TJ2MERMS.Ensure(E: TRMSIterator): Boolean;
var
  V: TJVMValue;
begin
  FVM.TakeGuestResult(V);
  Handle(E.Store);
  if E.Built and not E.KeepUpdated then
    Exit(True);
  var Snapshot := FDatabase.Read(Handle(E.Store).Lease);
  try
    Result := E.Built and (E.Version = Snapshot.Version);
  finally
    Snapshot.Free;
  end;
  if not Result then
    FVM.InvokeGuestResult(FVM.LoadClass(EnumImpl).FindMethod('$rebuildUpdated', '()V'), [TJVMValue.Ref(E.Reference)]);
end;

function TJ2MERMS.Rebuild(E: TRMSIterator; Auto: Boolean): Boolean;
var
  S, Source, Destination: TJVMObject;
  StateRef, SourceRef, TargetRef, N, Phase, I, J, K, Middle, Finish: Integer;
  V: TJVMValue;

  function Callback(MethodName, Descriptor: string; Target: Integer; const Args: array of TJVMValue): Boolean;
  begin
    var M := FVM.ResolveMethod(FVM.LoadClass(FVM.GetObject(Target).ClassName), MethodName, Descriptor);
    FVM.InvokeGuestResult(M, Args);
    Result := False;
  end;

begin
  Result := False;
  Handle(E.Store);
  var State := FVM.NativeContinuation;
  if (State.Kind <> TJVMKind.Reference) or (State.AsRef = 0) then
  begin
    var Snapshot := FDatabase.Read(Handle(E.Store).Lease);
    try
      StateRef := FVM.NewObject('java/lang/Object');
      FVM.SetNativeContinuation(TJVMValue.Ref(StateRef));
      S := FVM.GetObject(StateRef);
      S.Fields.Add('version', TJVMValue.Long(Snapshot.Version));
      Put(S, 'auto', Ord(Auto));
      Put(S, 'n', Snapshot.Records.Count);
      var Rows := FVM.NewArray('[Ljava/lang/Object;', Snapshot.Records.Count);
      PutRef(S, 'original', Rows);
      var IDs := Snapshot.Records.Keys.ToArray;
      TArray.Sort<Integer>(IDs);
      for var Index := 0 to High(IDs) do
      begin
        var Row := FVM.NewObject('java/lang/Object');
        Put(FVM.GetObject(Row), 'id', IDs[Index]);
        PutRef(FVM.GetObject(Row), 'bytes', ArrayBytes(Snapshot.Records[IDs[Index]]));
        FVM.GetObject(Rows).Elements[Index] := TJVMValue.Ref(Row);
      end;
      if Ref(FVM.GetObject(E.Reference), FilterField) = 0 then
      begin
        PutRef(S, 'src', Rows);
        Put(S, 'count', Length(IDs));
        Put(S, 'phase', 1);
      end
      else
      begin
        PutRef(S, 'src', FVM.NewArray('[Ljava/lang/Object;', Length(IDs)));
        Put(S, 'phase', 0);
      end;
    finally
      Snapshot.Free;
    end;
  end
  else
    S := FVM.GetObject(State.AsRef);
  Phase := Int(S, 'phase');
  if FVM.TakeGuestResult(V) then
  begin
    if Phase = 10 then
    begin
      I := Int(S, 'filterIndex');
      K := Int(S, 'count');
      Source := FVM.GetObject(Ref(S, 'original'));
      if V.AsInt <> 0 then
      begin
        FVM.GetObject(Ref(S, 'src')).Elements[K] := Source.Elements[I];
        Put(S, 'count', K + 1);
      end;
      Put(S, 'filterIndex', I + 1);
      Put(S, 'phase', 0);
    end
    else if Phase = 11 then
    begin
      Source := FVM.GetObject(Ref(S, 'src'));
      Destination := FVM.GetObject(Ref(S, 'dst'));
      I := Int(S, 'i');
      J := Int(S, 'j');
      K := Int(S, 'k');
      if V.AsInt <= 0 then
      begin
        Destination.Elements[K] := Source.Elements[I];
        Inc(I);
      end
      else
      begin
        Destination.Elements[K] := Source.Elements[J];
        Inc(J);
      end;
      Put(S, 'i', I);
      Put(S, 'j', J);
      Put(S, 'k', K + 1);
      Put(S, 'phase', 2);
    end
    else
      raise EJVMError.Create('RMS unexpected callback result');
  end;
  for var Work := 1 to 128 do
  begin
    Phase := Int(S, 'phase');
    if Phase = 0 then
    begin
      I := Int(S, 'filterIndex');
      N := Int(S, 'n');
      if I < N then
      begin
        var Target := Ref(FVM.GetObject(E.Reference), FilterField);
        var Row := FVM.GetObject(FVM.GetObject(Ref(S, 'original')).Elements[I].AsRef);
        Put(S, 'phase', 10);
        Exit(Callback('matches', '([B)Z', Target, [TJVMValue.Ref(Target), TJVMValue.Ref(Ref(Row, 'bytes'))]));
      end;
      Put(S, 'phase', 1);
      Continue;
    end;
    if Phase = 1 then
    begin
      N := Int(S, 'count');
      Put(S, 'n', N);
      if (N <= 1) or (Ref(FVM.GetObject(E.Reference), ComparatorField) = 0) then
      begin
        Put(S, 'phase', 3);
        Continue;
      end;
      PutRef(S, 'dst', FVM.NewArray('[Ljava/lang/Object;', N));
      Put(S, 'width', 1);
      Put(S, 'left', 0);
      Put(S, 'k', -1);
      Put(S, 'phase', 2);
      Continue;
    end;
    if Phase = 2 then
    begin
      N := Int(S, 'n');
      var Width := Int(S, 'width');
      var Left := Int(S, 'left');
      if Width >= N then
      begin
        Put(S, 'phase', 3);
        Continue;
      end;
      if Left >= N then
      begin
        SourceRef := Ref(S, 'src');
        TargetRef := Ref(S, 'dst');
        PutRef(S, 'src', TargetRef);
        PutRef(S, 'dst', SourceRef);
        Put(S, 'left', 0);
        Put(S, 'k', -1);
        Put(S, 'width', Width * 2);
        Continue;
      end;
      Middle := Min(N, Left + Width);
      Finish := Min(N, Left + Width * 2);
      if Int(S, 'k') = -1 then
      begin
        Put(S, 'i', Left);
        Put(S, 'j', Middle);
        Put(S, 'k', Left);
      end;
      I := Int(S, 'i');
      J := Int(S, 'j');
      K := Int(S, 'k');
      if K >= Finish then
      begin
        Put(S, 'left', Finish);
        Put(S, 'k', -1);
        Continue;
      end;
      Source := FVM.GetObject(Ref(S, 'src'));
      Destination := FVM.GetObject(Ref(S, 'dst'));
      if (I < Middle) and (J < Finish) then
      begin
        var Target := Ref(FVM.GetObject(E.Reference), ComparatorField);
        Put(S, 'phase', 11);
        Exit(Callback('compare', '([B[B)I', Target, [TJVMValue.Ref(Target),
              TJVMValue.Ref(Ref(FVM.GetObject(Source.Elements[I].AsRef), 'bytes')), TJVMValue.Ref(Ref(FVM.GetObject(Source.Elements[J].AsRef), 'bytes'))]));
      end;
      if I < Middle then
      begin
        Destination.Elements[K] := Source.Elements[I];
        Put(S, 'i', I + 1);
      end
      else
      begin
        Destination.Elements[K] := Source.Elements[J];
        Put(S, 'j', J + 1);
      end;
      Put(S, 'k', K + 1);
      Continue;
    end;
    if Phase = 3 then
    begin
      var Snapshot := FDatabase.Read(Handle(E.Store).Lease);
      var Version: Int64;
      try
        Version := Snapshot.Version;
      finally
        Snapshot.Free;
      end;
      if Version <> S.Fields['version'].AsLong then
      begin
        FVM.SetNativeContinuation(Default(TJVMValue));
        FVM.RetryNative;
        Exit(False);
      end;
      Source := FVM.GetObject(Ref(S, 'src'));
      N := Int(S, 'n');
      var Rows := FVM.NewArray('[Ljava/lang/Object;', N);
      for var Index := 0 to N - 1 do
        FVM.GetObject(Rows).Elements[Index] := Source.Elements[Index];
      if (Int(S, 'auto') = 0) or not E.Built then
      begin
        E.Cursor := -1;
        E.Gap := False;
      end
      else
      begin
        var OldRef := Ref(FVM.GetObject(E.Reference), RowsField);
        var Old := FVM.GetObject(OldRef);
        if E.Gap then
          E.Cursor := Min(E.Cursor, N)
        else if (E.Cursor >= 0) and (E.Cursor < Length(Old.Elements)) then
        begin
          var ID := Int(FVM.GetObject(Old.Elements[E.Cursor].AsRef), 'id');
          var Found := -1;
          for var Index := 0 to N - 1 do
            if Int(FVM.GetObject(FVM.GetObject(Rows).Elements[Index].AsRef), 'id') = ID then
              Found := Index;
          if Found >= 0 then
            E.Cursor := Found
          else
          begin
            E.Cursor := Min(E.Cursor, N);
            E.Gap := True;
          end;
        end
        else if E.Cursor >= 0 then
          E.Cursor := N;
      end;
      PutRef(FVM.GetObject(E.Reference), RowsField, Rows);
      E.Version := Version;
      E.Built := True;
      FVM.SetNativeContinuation(Default(TJVMValue));
      Exit(True);
    end;
    raise EJVMError.Create('RMS rebuild phase');
  end;
  FVM.RetryNative;
end;

function TJ2MERMS.Advance(E: TRMSIterator; forward: Boolean): Integer;
begin
  var Rows := FVM.GetObject(Ref(FVM.GetObject(E.Reference), RowsField));
  var N := Length(Rows.Elements);
  var Index := E.Cursor;
  if E.Gap then
  begin
    if not forward then
      Dec(Index);
  end
  else if forward then
  begin
    if Index < 0 then
      Index := 0
    else
      Inc(Index);
  end
  else if Index = -1 then
    Index := N - 1
  else
    Dec(Index);
  E.Gap := False;
  if (Index < 0) or (Index >= N) then
  begin
    if forward then
      E.Cursor := N
    else
      E.Cursor := -2;
    raise ERMS.Create('InvalidRecordIDException', 'Enumeration exhausted');
  end;
  E.Cursor := Index;
  Result := Int(FVM.GetObject(Rows.Elements[Index].AsRef), 'id');
end;

function TJ2MERMS.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  H: TRMSHandle;
  E: TRMSIterator;
  Snapshot: TRMSSnapshot;
  Name, Vendor, Suite, N: string;
  ID, Kind, R, Count, Offset: Integer;
  Data: TBytes;

  function NameArg(Index: Integer): string;
  begin
    if Args[Index].AsRef = 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException', 'Null RecordStore name');
    Result := FVM.GetObject(Args[Index].AsRef).Text;
  end;

begin
  Result := Default(TJVMValue);
  N := Method.Name;
  try
    if Method.Owner.Name = Store then
    begin
      if N = 'openRecordStore' then
      begin
        Name := NameArg(0);
        Vendor := FVendor;
        Suite := FSuite;
        if Length(Args) = 3 then
        begin
          Vendor := FVM.GetObject(Args[1].AsRef).Text;
          Suite := FVM.GetObject(Args[2].AsRef).Text;
          R := StoreObject(Name, Vendor, Suite, False, 0, False);
        end
        else
        begin
          var Mode := 0;
          var Writable := False;
          if Length(Args) = 4 then
          begin
            Mode := Args[2].AsInt;
            Writable := Args[3].AsInt <> 0;
          end;
          R := StoreObject(Name, Vendor, Suite, Args[1].AsInt <> 0, Mode, Writable);
        end;
        Exit(TJVMValue.Ref(R));
      end;
      if N = 'deleteRecordStore' then
      begin
        FDatabase.Delete(NameArg(0));
        Exit;
      end;
      if N = 'listRecordStores' then
      begin
        var Names := FDatabase.Names;
        if Length(Names) = 0 then
          Exit(TJVMValue.Ref(0));
        R := FVM.NewArray('[Ljava/lang/String;', Length(Names));
        for var I := 0 to High(Names) do
          FVM.GetObject(R).Elements[I] := TJVMValue.Ref(FVM.NewString(Names[I]));
        Exit(TJVMValue.Ref(R));
      end;
      H := Handle(Args[0].AsRef);
      if N = 'closeRecordStore' then
      begin
        Dec(H.Opens);
        if H.Opens = 0 then
        begin
          FOpen.Remove(H.Lease.FileName);
          FreeAndNil(H.Lease);
          FVM.RemoveRoot(H.Reference);
          PutRef(FVM.GetObject(H.Reference), ListenerField, 0);
        end;
        Exit;
      end;
      if N = 'getName' then
        Exit(TJVMValue.Ref(FVM.NewString(H.Lease.Name)));
      if N = 'setMode' then
      begin
        FDatabase.SetMode(H.Lease, Args[1].AsInt, Args[2].AsInt <> 0, FVM.Host.TimeMillis);
        Exit;
      end;
      if N = 'getSizeAvailable' then
        Exit(TJVMValue.Int(FDatabase.Available(H.Lease)));
      if N = '$notifyPending' then
      begin
        Notify(H, Args[1].AsInt, Args[2].AsInt);
        Exit;
      end;
      if (N = 'addRecordListener') or (N = 'removeRecordListener') then
      begin
        R := Args[1].AsRef;
        if R = 0 then
          Exit;
        var OldRef := Ref(FVM.GetObject(H.Reference), ListenerField);
        var IDs: TArray<TJVMValue>;
        if OldRef <> 0 then
          IDs := Copy(FVM.GetObject(OldRef).Elements);
        var Found := -1;
        for var I := 0 to High(IDs) do
          if IDs[I].AsRef = R then
            Found := I;
        if N = 'addRecordListener' then
        begin
          if Found >= 0 then
            Exit;
          var I := Length(IDs);
          SetLength(IDs, I + 1);
          IDs[I] := TJVMValue.Ref(R);
        end
        else
        begin
          if Found < 0 then
            Exit;
          for var I := Found to Length(IDs) - 2 do
            IDs[I] := IDs[I + 1];
          SetLength(IDs, Length(IDs) - 1);
        end;
        var A := FVM.NewArray('[Ljavax/microedition/rms/RecordListener;', Length(IDs));
        FVM.GetObject(A).Elements := IDs;
        PutRef(FVM.GetObject(H.Reference), ListenerField, A);
        H.Lease.SetNotifications(Length(IDs) <> 0);
        Exit;
      end;
      if N = 'enumerateRecords' then
      begin
        Sweep;
        R := FVM.NewObject(EnumImpl);
        E := TRMSIterator.Create;
        E.Reference := R;
        E.Store := H.Reference;
        E.Cursor := -1;
        E.KeepUpdated := Args[3].AsInt <> 0;
        FEnums.Add(R, E);
        PutRef(FVM.GetObject(R), StoreField, H.Reference);
        FVM.GetObject(R).Fields[FilterField] := Args[1];
        FVM.GetObject(R).Fields[ComparatorField] := Args[2];
        Result := TJVMValue.Ref(R);
        FVM.InvokeGuest(FVM.LoadClass(EnumImpl).FindMethod('rebuild', '()V'), [Result]);
        Exit;
      end;
      if (N = 'addRecord') or (N = 'setRecord') or (N = 'deleteRecord') then
      begin
        ID := 0;
        Offset := 1;
        Kind := 1;
        if N <> 'addRecord' then
        begin
          ID := Args[1].AsInt;
          Offset := 2;
          Kind := 2;
        end;
        if not H.Lease.CanWrite then
          FVM.RaiseJava('java/lang/SecurityException', 'Read-only RecordStore');
        if N = 'deleteRecord' then
          Kind := 3
        else
          Data := Bytes(Args[Offset].AsRef, Args[Offset + 1].AsInt, Args[Offset + 2].AsInt, True);
        ID := FDatabase.Modify(H.Lease, Kind, ID, Data, FVM.Host.TimeMillis);
        if Kind = 1 then
          Result := TJVMValue.Int(ID);
        Notify(H, Kind, ID);
        Exit;
      end;
      Snapshot := FDatabase.Read(H.Lease);
      try
        if N = 'getVersion' then
          Exit(TJVMValue.Int(Integer(Snapshot.Version)));
        if N = 'getLastModified' then
          Exit(TJVMValue.Long(Snapshot.Modified));
        if N = 'getNumRecords' then
          Exit(TJVMValue.Int(Snapshot.Records.Count));
        if N = 'getNextRecordID' then
          Exit(TJVMValue.Int(Snapshot.NextID));
        if N = 'getSize' then
          Exit(TJVMValue.Int(Length(Snapshot.Encode)));
        ID := Args[1].AsInt;
        if not Snapshot.Records.TryGetValue(ID, Data) then
          raise ERMS.Create('InvalidRecordIDException', IntToStr(ID));
        if N = 'getRecordSize' then
          Exit(TJVMValue.Int(Length(Data)));
        if (N = 'getRecord') and (Length(Args) = 2) then
          Exit(TJVMValue.Ref(ArrayBytes(Data)));
        if N = 'getRecord' then
        begin
          var A := FVM.GetObject(Args[2].AsRef);
          Offset := Args[3].AsInt;
          Count := Length(Data);
          if (Offset < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
            FVM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
          for var I := 0 to Count - 1 do
            A.Elements[Offset + I] := TJVMValue.Int(ShortInt(Data[I]));
          Exit(TJVMValue.Int(Count));
        end;
      finally
        Snapshot.Free;
      end;
    end
    else
    begin
      E := Iterator(Args[0].AsRef);
      if N = 'destroy' then
      begin
        E.Destroyed := True;
        var O := FVM.GetObject(E.Reference);
        PutRef(O, RowsField, 0);
        PutRef(O, FilterField, 0);
        PutRef(O, ComparatorField, 0);
        PutRef(O, StoreField, 0);
        Exit;
      end;
      if (N = 'hasNextElement') or (N = 'hasPreviousElement') then
        if not FHandles.ContainsKey(E.Store) or (FHandles[E.Store].Opens = 0) then
          Exit(TJVMValue.Int(0));
      Handle(E.Store);
      if (N = 'rebuild') or (N = '$rebuildUpdated') then
      begin
        Rebuild(E, N = '$rebuildUpdated');
        Exit;
      end;
      if N = 'isKeptUpdated' then
        Exit(TJVMValue.Int(Ord(E.KeepUpdated)));
      if N = 'keepUpdated' then
      begin
        E.KeepUpdated := Args[1].AsInt <> 0;
        if E.KeepUpdated then
          FVM.InvokeGuest(FVM.LoadClass(EnumImpl).FindMethod('rebuild', '()V'), [TJVMValue.Ref(E.Reference)]);
        Exit;
      end;
      if not Ensure(E) then
        Exit;
      var Rows := FVM.GetObject(Ref(FVM.GetObject(E.Reference), RowsField));
      Count := Length(Rows.Elements);
      if N = 'reset' then
      begin
        E.Cursor := -1;
        E.Gap := False;
        Exit;
      end;
      if N = 'numRecords' then
        Exit(TJVMValue.Int(Count));
      if N = 'hasNextElement' then
      begin
        var B := E.Cursor < Count - 1;
        if E.Gap then
          B := E.Cursor < Count
        else if E.Cursor < 0 then
          B := Count > 0;
        Exit(TJVMValue.Int(Ord(B)));
      end;
      if N = 'hasPreviousElement' then
      begin
        var B := E.Cursor > 0;
        if E.Cursor = -1 then
          B := Count > 0;
        Exit(TJVMValue.Int(Ord(B)));
      end;
      ID := Advance(E, N.StartsWith('next'));
      if N.EndsWith('Id') then
        Exit(TJVMValue.Int(ID));
      Snapshot := FDatabase.Read(Handle(E.Store).Lease);
      try
        if not Snapshot.Records.TryGetValue(ID, Data) then
          raise ERMS.Create('InvalidRecordIDException', IntToStr(ID));
        Result := TJVMValue.Ref(ArrayBytes(Data));
      finally
        Snapshot.Free;
      end;
      Exit;
    end;
    raise ERMS.Create('RecordStoreException', 'Unimplemented RMS method ' + N);
  except
    on X: EJVMThrown do
      raise;
    on X: ERMS do
    begin
      var Prefix := RMS;
      if (X.Kind = 'SecurityException') or (X.Kind = 'IllegalArgumentException') then
        Prefix := 'java/lang/';
      FVM.RaiseJava(Prefix + X.Kind, X.Message);
    end;
    on X: Exception do
      FVM.RaiseJava(RMS + 'RecordStoreException', X.ClassName + ': ' + X.Message);
  end;
end;

end.

