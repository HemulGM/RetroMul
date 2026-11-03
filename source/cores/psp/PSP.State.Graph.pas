unit PSP.State.Graph;

// A checked object graph for direct states. The wire format contains object IDs
// and method names, never VMTs, code addresses, handles or reference counts.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, Core.Snapshots;

type
  EPSPStateOpaque = class(EInvalidOpException);
  TPSPGraphRoots = array[0..3] of string;
  TPSPGraphStreamMode = reference to function(Stream: TStream): Word;
  TPSPGraphFactory = reference to function: TObject;
  TPSPGraphTransfer = reference to procedure(Instance: TObject; State: TStateArchive);
  TPSPGraphNative = record
    Factory: TPSPGraphFactory;
    Transfer: TPSPGraphTransfer;
  end;

  TPSPGraphSchema = class
  private
    FClasses: TDictionary<string, TClass>;
    FNames: TDictionary<TClass, string>;
    FSkipped: TDictionary<TClass, TArray<string>>;
    FOptional: TDictionary<TClass, TArray<string>>;
    FAliases: TDictionary<string, PTypeInfo>;
    FPlain: TDictionary<PTypeInfo, Boolean>;
    FNative: TDictionary<TClass, TPSPGraphNative>;
    FFactories: TDictionary<TClass, TPSPGraphFactory>;
    FVisited: TDictionary<PTypeInfo, Boolean>;
    FContext: TRttiContext;
    function AliasKey(Owner: TRttiType; const Name: string): string;
    procedure AdmitContainers(Info: PTypeInfo);
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddClass(C: TClass; const Skip: array of string);
    procedure Optional(C: TClass; const Names: array of string);
    function IsOptional(C: TClass; const Name: string): Boolean;
    procedure AddPublicTypes(const Prefixes: array of string);
    procedure Alias(Owner: PTypeInfo; const Field: string; Info: PTypeInfo);
    procedure Plain(Info: PTypeInfo);
    procedure Native(C: TClass; const Factory: TPSPGraphFactory; const Transfer: TPSPGraphTransfer);
    procedure Factory(C: TClass; const CreateInstance: TPSPGraphFactory);
    function HasFactory(C: TClass): Boolean;
    function CreateData(C: TClass): TObject;
    function IsNative(C: TClass): Boolean;
    function NewNative(C: TClass): TObject;
    procedure TransferNative(Instance: TObject; State: TStateArchive);
    function ClassName(C: TClass): string;
    function FindClass(const Name: string): TClass;
    function SkipField(C: TClass; const Name: string): Boolean;
    function FieldInfo(Field: TRttiField): PTypeInfo;
    function IsPlain(Info: PTypeInfo): Boolean;
  end;

  TPSPGraph = class
  private
    type
      TCell = record
        Field: TRttiField;
        Info: PTypeInfo;
        Value: TValue;
      end;
      PCell = ^TCell;
      TNode = class
        Instance: TObject;
        Name, Binding: string;
        Selected: TArray<string>;
        Fields, Backup: TList<TCell>;
        Elements: TValue;
        Kind: Byte;
        Ownership: Byte;
        Created: Boolean;
        Constructed: Boolean;
        constructor Create;
        destructor Destroy; override;
      end;
      TFixup = record
        Address: Pointer;
        Info: PTypeInfo;
        ID: Cardinal;
        MethodName: string;
      end;
  private
    FSchema: TPSPGraphSchema;
    FContext: TRttiContext;
    FNodes: TObjectList<TNode>;
    FIDs: TDictionary<TObject, Cardinal>;
    FBindings: TDictionary<string, TNode>;
    FFixups: TList<TFixup>;
    FStream: TStream;
    FLoading: Boolean;
    FPath: string;
    FAllocated: Int64;
    FRoots: TPSPGraphRoots;
    FStreamMode: TPSPGraphStreamMode;
    procedure U32(var V: Cardinal);
    procedure U64(var V: UInt64);
    procedure Text(var V: string);
    procedure Blob(var Data: TBytes; Limit: Integer = 128 * 1024 * 1024);
    procedure Raw(P: Pointer; Count: NativeInt);
    function NewValue(Info: PTypeInfo): TValue;
    function ObjectID(O: TObject): Cardinal;
    function Fields(Node: TNode): TArray<TRttiField>;
    function KindOf(C: TClass): Byte;
    function ArrayMethod(C: TClass): TRttiMethod;
    function CreateCollection(C: TClass): TObject;
    function OwnershipField(O: TObject): TRttiField;
    procedure TransferValue(Info: PTypeInfo; Address: Pointer);
    procedure TransferNode(Node: TNode);
    procedure ResolveFixups;
    procedure Assign(const Cell: TCell; Instance: TObject);
    procedure ClearLinks(Info: PTypeInfo; Address: Pointer);
    procedure CollectOldValue(Info: PTypeInfo; Address: Pointer; Seen: TDictionary<TObject, Boolean>;
      List: TList<TObject>);
    procedure CollectOld(O: TObject; Seen: TDictionary<TObject, Boolean>; List: TList<TObject>);
    procedure ReleaseObjects(const Objects: TList<TObject>; LinksApplied: Boolean = True);
    procedure FillCollection(Node: TNode);
    function NamedMethod(O: TObject; Code: Pointer): string;
    function MethodCode(O: TObject; const Name: string; Info: PTypeInfo): Pointer;
    procedure TransferFile(Node: TNode);
  public
    constructor Create(Schema: TPSPGraphSchema; const Roots: TPSPGraphRoots;
      const StreamMode: TPSPGraphStreamMode = nil);
    destructor Destroy; override;
    // Empty Select means an external binding, '*' means all admitted fields.
    procedure Bind(const Name: string; Instance: TObject; const Select: array of string);
    procedure Save(Stream: TStream);
    procedure Load(Stream: TStream);
  end;

implementation

uses
  System.IOUtils, System.Math;

const
  GraphVersion = 1;
  MaxNodes = 100000;
  MaxElements = 8 * 1024 * 1024;
  MaxData = Int64(256) * 1024 * 1024;
  nkObject = 0;
  nkCollection = 1;
  nkMemory = 2;
  nkFile = 3;
  nkBuilder = 4;
  nkNative = 5;

function CollectionClass(C: TClass): Boolean;
begin
  Result := False;
  while C <> nil do
  begin
    var N := C.ClassName;
    if N.StartsWith('TList<') or N.StartsWith('TDictionary<') or N.StartsWith('TQueue<') or N.StartsWith('TStack<') then
      Exit(True);
    C := C.ClassParent;
  end;
end;

{ TPSPGraphSchema }

constructor TPSPGraphSchema.Create;
begin
  inherited;
  FContext := TRttiContext.Create;
  FClasses := TDictionary<string, TClass>.Create;
  FNames := TDictionary<TClass, string>.Create;
  FSkipped := TDictionary<TClass, TArray<string>>.Create;
  FOptional := TDictionary<TClass, TArray<string>>.Create;
  FAliases := TDictionary<string, PTypeInfo>.Create;
  FPlain := TDictionary<PTypeInfo, Boolean>.Create;
  FNative := TDictionary<TClass, TPSPGraphNative>.Create;
  FFactories := TDictionary<TClass, TPSPGraphFactory>.Create;
  FVisited := TDictionary<PTypeInfo, Boolean>.Create;
end;

destructor TPSPGraphSchema.Destroy;
begin
  FVisited.Free;
  FFactories.Free;
  FNative.Free;
  FPlain.Free;
  FAliases.Free;
  FOptional.Free;
  FSkipped.Free;
  FNames.Free;
  FClasses.Free;
  FContext.Free;
  inherited;
end;

procedure TPSPGraphSchema.AddClass(C: TClass; const Skip: array of string);
begin
  var N := C.UnitName + '.' + C.ClassName;
  var Existing: TClass;
  if FClasses.TryGetValue(N, Existing) and (Existing <> C) then
    raise EInvalidOpException.Create('Ambiguous state class ' + N);
  FNames.AddOrSetValue(C, N);
  FClasses.AddOrSetValue(N, C);
  var Names: TArray<string> := nil;
  for var S in Skip do
    Names := Names + [S];
  FSkipped.AddOrSetValue(C, Names);
  AdmitContainers(C.ClassInfo);
end;

procedure TPSPGraphSchema.AdmitContainers(Info: PTypeInfo);
begin
  if (Info = nil) or FVisited.ContainsKey(Info) then
    Exit;
  var T := FContext.GetType(Info);
  if T is TRttiInstanceType then
  begin
    var C := TRttiInstanceType(T).MetaclassType;
    if not FNames.ContainsKey(C) and not CollectionClass(C) then
    begin
      // Reference-picture classes are private nested codec data types. Admit
      // them only when reached through an already admitted AVC field schema.
      if C.UnitName.StartsWith('Video.AVC.') then
        AddClass(C, [])
      else
        Exit;
      Exit;
    end;
    FVisited.Add(Info, True);
    if CollectionClass(C) and not FNames.ContainsKey(C) then
      AddClass(C, []);
    for var F in T.GetFields do
      if F.FieldType <> nil then
        AdmitContainers(F.FieldType.Handle);
  end
  else
  begin
    FVisited.Add(Info, True);
    if T is TRttiDynamicArrayType then
      AdmitContainers(TRttiDynamicArrayType(T).ElementType.Handle)
    else if T is TRttiArrayType then
      AdmitContainers(TRttiArrayType(T).ElementType.Handle)
    else if T.TypeKind in [tkRecord, tkMRecord] then
      for var F in T.GetFields do
        if F.FieldType <> nil then
          AdmitContainers(F.FieldType.Handle);
  end;
end;

procedure TPSPGraphSchema.Optional(C: TClass; const Names: array of string);
begin
  var Values: TArray<string> := nil;
  for var N in Names do
    Values := Values + [N];
  FOptional.AddOrSetValue(C, Values);
end;

function TPSPGraphSchema.IsOptional(C: TClass; const Name: string): Boolean;
begin
  while C <> nil do
  begin
    var Names: TArray<string>;
    if FOptional.TryGetValue(C, Names) then
      for var N in Names do
        if N = Name then
          Exit(True);
    C := C.ClassParent;
  end;
  Result := False;
end;

procedure TPSPGraphSchema.AddPublicTypes(const Prefixes: array of string);
begin
  for var T in FContext.GetTypes do
    if T is TRttiInstanceType then
      for var Prefix in Prefixes do
        if TRttiInstanceType(T).MetaclassType.UnitName.StartsWith(Prefix) and
          (not TRttiInstanceType(T).MetaclassType.UnitName.StartsWith('PSP.State.') or
          (TRttiInstanceType(T).MetaclassType.UnitName = 'PSP.State.Action')) and
          not TRttiInstanceType(T).MetaclassType.UnitName.StartsWith('PSP.CPU.JIT') then
        begin
          AddClass(TRttiInstanceType(T).MetaclassType, []);
          Break;
        end;
end;

function TPSPGraphSchema.AliasKey(Owner: TRttiType; const Name: string): string;
begin
  Result := IntToHex(NativeUInt(Owner.Handle), SizeOf(Pointer) * 2) + '/' + Name;
end;

procedure TPSPGraphSchema.Alias(Owner: PTypeInfo; const Field: string; Info: PTypeInfo);
begin
  FAliases.AddOrSetValue(AliasKey(FContext.GetType(Owner), Field), Info);
  AdmitContainers(Info);
end;

procedure TPSPGraphSchema.Plain(Info: PTypeInfo);
begin
  FPlain.AddOrSetValue(Info, True);
end;

procedure TPSPGraphSchema.Native(C: TClass; const Factory: TPSPGraphFactory; const Transfer: TPSPGraphTransfer);
begin
  AddClass(C, []);
  var Spec: TPSPGraphNative;
  Spec.Factory := Factory;
  Spec.Transfer := Transfer;
  FNative.AddOrSetValue(C, Spec);
end;

procedure TPSPGraphSchema.Factory(C: TClass; const CreateInstance: TPSPGraphFactory);
begin
  FFactories.AddOrSetValue(C, CreateInstance);
end;

function TPSPGraphSchema.HasFactory(C: TClass): Boolean;
begin
  Result := FFactories.ContainsKey(C);
end;

function TPSPGraphSchema.CreateData(C: TClass): TObject;
begin
  Result := FFactories[C]();
end;

function TPSPGraphSchema.IsNative(C: TClass): Boolean;
begin
  Result := FNative.ContainsKey(C);
end;

function TPSPGraphSchema.NewNative(C: TClass): TObject;
begin
  Result := FNative[C].Factory();
end;

procedure TPSPGraphSchema.TransferNative(Instance: TObject; State: TStateArchive);
begin
  FNative[Instance.ClassType].Transfer(Instance, State);
end;

function TPSPGraphSchema.IsPlain(Info: PTypeInfo): Boolean;
begin
  Result := FPlain.ContainsKey(Info);
end;

function TPSPGraphSchema.ClassName(C: TClass): string;
begin
  if not FNames.TryGetValue(C, Result) then
    raise EPSPStateOpaque.Create('No direct-state schema for ' + C.ClassName);
end;

function TPSPGraphSchema.FindClass(const Name: string): TClass;
begin
  if FClasses.TryGetValue(Name, Result) then
    Exit;
  // Collection specializations are reached through their field type metadata.
  for var T in FContext.GetTypes do
    if T is TRttiInstanceType then
    begin
      var C := TRttiInstanceType(T).MetaclassType;
      if CollectionClass(C) and (C.UnitName + '.' + C.ClassName = Name) then
      begin
        AddClass(C, []);
        Exit(C);
      end;
    end;
  raise EReadError.Create('Unknown direct-state class ' + Name);
end;

function TPSPGraphSchema.SkipField(C: TClass; const Name: string): Boolean;
begin
  while C <> nil do
  begin
    var Names: TArray<string>;
    if FSkipped.TryGetValue(C, Names) then
      for var S in Names do
        if S = Name then
          Exit(True);
    if (C = TInterfacedObject) and (Name = 'FRefCount') then
      Exit(True);
    C := C.ClassParent;
  end;
  Result := False;
end;

function TPSPGraphSchema.FieldInfo(Field: TRttiField): PTypeInfo;
begin
  if FAliases.TryGetValue(AliasKey(Field.Parent, Field.Name), Result) then
    Exit;
  if Field.FieldType = nil then
    raise EPSPStateOpaque.Create('Missing direct-state field type: ' + Field.Parent.Name + '.' + Field.Name);
  Result := Field.FieldType.Handle;
end;

{ TPSPGraph }

constructor TPSPGraph.TNode.Create;
begin
  inherited;
  Fields := TList<TCell>.Create;
  Backup := TList<TCell>.Create;
end;

destructor TPSPGraph.TNode.Destroy;
begin
  Backup.Free;
  Fields.Free;
  inherited;
end;

constructor TPSPGraph.Create(Schema: TPSPGraphSchema; const Roots: TPSPGraphRoots;
  const StreamMode: TPSPGraphStreamMode);
begin
  inherited Create;
  FSchema := Schema;
  FRoots := Roots;
  FStreamMode := StreamMode;
  FContext := TRttiContext.Create;
  FNodes := TObjectList<TNode>.Create(True);
  FIDs := TDictionary<TObject, Cardinal>.Create;
  FBindings := TDictionary<string, TNode>.Create;
  FFixups := TList<TFixup>.Create;
end;

destructor TPSPGraph.Destroy;
begin
  FFixups.Free;
  FBindings.Free;
  FIDs.Free;
  FNodes.Free;
  FContext.Free;
  inherited;
end;

procedure TPSPGraph.Raw(P: Pointer; Count: NativeInt);
begin
  if (Count < 0) or (Count > MaxData) then
    raise EReadError.Create('Direct-state data is too large');
  if Count = 0 then
    Exit;
  if FLoading then
    FStream.ReadBuffer(P^, Count)
  else
    FStream.WriteBuffer(P^, Count);
end;

procedure TPSPGraph.U32(var V: Cardinal);
begin
  Raw(@V, 4);
end;

procedure TPSPGraph.U64(var V: UInt64);
begin
  Raw(@V, 8);
end;

procedure TPSPGraph.Blob(var Data: TBytes; Limit: Integer);
begin
  var N := Cardinal(Length(Data));
  U32(N);
  if N > Cardinal(Limit) then
    raise EReadError.Create('Direct-state byte field is too large');
  if FLoading then
  begin
    Inc(FAllocated, N);
    if FAllocated > MaxData then
      raise EReadError.Create('Direct-state allocation limit exceeded');
    SetLength(Data, N);
  end;
  if N > 0 then
    Raw(@Data[0], N);
end;

procedure TPSPGraph.Text(var V: string);
begin
  var B := TEncoding.UTF8.GetBytes(V);
  Blob(B, 16 * 1024 * 1024);
  if FLoading then
    V := TEncoding.UTF8.GetString(B);
end;

function TPSPGraph.NewValue(Info: PTypeInfo): TValue;
begin
  TValue.Make(nil, Info, Result);
end;

procedure TPSPGraph.Bind(const Name: string; Instance: TObject; const Select: array of string);
begin
  if (Name = '') or (Instance = nil) or FBindings.ContainsKey(Name) or FIDs.ContainsKey(Instance) then
    raise EArgumentException.Create('Invalid direct-state binding ' + Name);
  var Node := TNode.Create;
  Node.Instance := Instance;
  Node.Name := FSchema.ClassName(Instance.ClassType);
  Node.Binding := Name;
  for var S in Select do
    Node.Selected := Node.Selected + [S];
  FNodes.Add(Node);
  FIDs.Add(Instance, FNodes.Count);
  FBindings.Add(Name, Node);
end;

function TPSPGraph.KindOf(C: TClass): Byte;
begin
  if FSchema.IsNative(C) then
    Exit(nkNative);
  if CollectionClass(C) then
    Exit(nkCollection);
  if C.InheritsFrom(TMemoryStream) then
    Exit(nkMemory);
  if C = TFileStream then
    Exit(nkFile);
  if C = TStringBuilder then
    Exit(nkBuilder);
  Result := nkObject;
end;

function TPSPGraph.ObjectID(O: TObject): Cardinal;
begin
  if O = nil then
    Exit(0);
  if (NativeUInt(O) < $10000) or (NativeUInt(O) > NativeUInt(High(NativeInt))) then
    raise EPSPStateOpaque.Create('Invalid transient object reference at ' + FPath);
  if FIDs.TryGetValue(O, Result) then
    Exit;
  if FNodes.Count >= MaxNodes then
    raise EReadError.Create('Too many direct-state objects');
  var Node := TNode.Create;
  try
    Node.Name := FSchema.ClassName(O.ClassType);
    Node.Instance := O;
    Node.Kind := KindOf(O.ClassType);
    Node.Selected := ['*'];
    Result := FNodes.Count + 1;
    FIDs.Add(O, Result);
    FNodes.Add(Node);
  except
    Node.Free;
    raise;
  end;
end;

function TPSPGraph.Fields(Node: TNode): TArray<TRttiField>;
begin
  Result := nil;
  for var F in FContext.GetType(Node.Instance.ClassType).GetFields do
  begin
    if FSchema.SkipField(Node.Instance.ClassType, F.Name) then
      Continue;
    for var S in Node.Selected do
      if (S = '*') or (S = F.Name) then
      begin
        Result := Result + [F];
        Break;
      end;
  end;
end;

function TPSPGraph.ArrayMethod(C: TClass): TRttiMethod;
begin
  for var M in FContext.GetType(C).GetMethods do
    if (M.Name = 'ToArray') and (Length(M.GetParameters) = 0) and (M.ReturnType is TRttiDynamicArrayType) then
      Exit(M);
  raise EPSPStateOpaque.Create('No array view for direct-state collection ' + C.ClassName);
end;

function TPSPGraph.CreateCollection(C: TClass): TObject;
begin
  for var M in FContext.GetType(C).GetMethods do
    if M.IsConstructor and (M.Name = 'Create') and (Length(M.GetParameters) = 0) then
      Exit(M.Invoke(C, []).AsObject);
  // TObjectList's optional ownership argument has no zero-argument overload.
  for var M in FContext.GetType(C).GetMethods do
    if M.IsConstructor and (M.Name = 'Create') and (Length(M.GetParameters) = 1) and
      (M.GetParameters[0].ParamType.Handle = TypeInfo(Boolean)) then
      Exit(M.Invoke(C, [False]).AsObject);
  raise EPSPStateOpaque.Create('No state collection constructor for ' + C.ClassName);
end;

function TPSPGraph.OwnershipField(O: TObject): TRttiField;
begin
  var T := FContext.GetType(O.ClassType);
  Result := T.GetField('FOwnsObjects');
  if Result = nil then
    Result := T.GetField('FOwnerships');
end;

function TPSPGraph.NamedMethod(O: TObject; Code: Pointer): string;
begin
  if O <> nil then
    for var M in FContext.GetType(O.ClassType).GetMethods do
      if (M.CodeAddress = Code) and not M.IsConstructor and not M.IsDestructor then
        Exit(M.Parent.Name + '::' + M.Name);
  raise EPSPStateOpaque.Create('A direct-state callback has no registered method name at ' + FPath);
end;

function TPSPGraph.MethodCode(O: TObject; const Name: string; Info: PTypeInfo): Pointer;
begin
  var Expected := FContext.GetType(Info) as TRttiMethodType;
  if O <> nil then
    for var M in FContext.GetType(O.ClassType).GetMethods do
      if (M.Parent.Name + '::' + M.Name = Name) and not M.IsConstructor and not M.IsDestructor then
      begin
        if M.ReturnType <> Expected.ReturnType then
          Continue;
        var A := M.GetParameters;
        var B := Expected.GetParameters;
        if Length(A) <> Length(B) then
          Continue;
        var Match := True;
        for var I := 0 to High(A) do
          if (A[I].ParamType <> B[I].ParamType) or (A[I].Flags <> B[I].Flags) then
            Match := False;
        if Match then
          Exit(M.CodeAddress);
      end;
  raise EReadError.Create('Unknown direct-state callback ' + Name);
end;

procedure TPSPGraph.TransferValue(Info: PTypeInfo; Address: Pointer);
begin
  var T := FContext.GetType(Info);
  if T = nil then
    raise EPSPStateOpaque.Create('No direct-state type at ' + FPath);
  if FSchema.IsPlain(Info) then
  begin
    var Size := Cardinal(T.TypeSize);
    U32(Size);
    if Size <> Cardinal(T.TypeSize) then
      raise EReadError.Create('Incompatible direct-state plain record');
    Raw(Address, Size);
    Exit;
  end;
  case T.TypeKind of
    tkInteger, tkInt64, tkChar, tkWChar, tkEnumeration, tkSet:
      begin
        if T.TypeSize > 8 then
          raise EPSPStateOpaque.Create('Large ordinal at ' + FPath);
        var V: UInt64 := 0;
        if not FLoading then
          Move(Address^, V, T.TypeSize);
        U64(V);
        if FLoading then
        begin
          Move(V, Address^, T.TypeSize);
          if T is TRttiEnumerationType then
          begin
            var Checked: TValue;
            TValue.Make(Address, Info, Checked);
            var N := Checked.AsOrdinal;
            if (N < TRttiEnumerationType(T).MinValue) or (N > TRttiEnumerationType(T).MaxValue) then
              raise EReadError.Create('Invalid direct-state enumeration at ' + FPath);
          end;
        end;
      end;
    tkFloat:
      begin
        if not (T.TypeSize in [4, 8]) then
          raise EPSPStateOpaque.Create('Nonportable float at ' + FPath);
        var Size := Cardinal(T.TypeSize);
        U32(Size);
        if Size <> Cardinal(T.TypeSize) then
          raise EReadError.Create('Incompatible direct-state float');
        Raw(Address, Size);
      end;
    tkUString, tkWString:
      begin
        var S := '';
        if not FLoading then
          if T.TypeKind = tkUString then
            S := PString(Address)^
          else
            S := PWideString(Address)^;
        Text(S);
        if FLoading then
          if T.TypeKind = tkUString then
            PString(Address)^ := S
          else
            PWideString(Address)^ := S;
      end;
    tkLString:
      begin
        var S: RawByteString := '';
        if not FLoading then
          S := PRawByteString(Address)^;
        var Data: TBytes := nil;
        if not FLoading then
        begin
          SetLength(Data, Length(S));
          if Length(S) > 0 then
            Move(S[1], Data[0], Length(S));
        end;
        var Page := Cardinal(StringCodePage(S));
        U32(Page);
        Blob(Data);
        if FLoading then
        begin
          SetLength(S, Length(Data));
          if Length(Data) > 0 then
            Move(Data[0], S[1], Length(Data));
          SetCodePage(S, Page, False);
          PRawByteString(Address)^ := S;
        end;
      end;
    tkString:
      begin
        var B: TBytes := nil;
        if not FLoading then
        begin
          SetLength(B, Ord(PShortString(Address)^[0]));
          if Length(B) > 0 then
            Move(PShortString(Address)^[1], B[0], Length(B));
        end;
        Blob(B, GetTypeData(Info).MaxLength);
        if FLoading then
        begin
          PShortString(Address)^[0] := AnsiChar(Length(B));
          if Length(B) > 0 then
            Move(B[0], PShortString(Address)^[1], Length(B));
        end;
      end;
    tkClass, tkInterface:
      begin
        var ID: Cardinal := 0;
        if not FLoading then
        begin
          var O: TObject := nil;
          if T.TypeKind = tkClass then
            O := PObject(Address)^
          else if PInterface(Address)^ <> nil then
          begin
            if IsEqualGUID(GetTypeData(Info).Guid, TGUID.Empty) then
              raise EPSPStateOpaque.Create('An opaque continuation is active at ' + FPath);
            O := PInterface(Address)^ as TObject;
          end;
          ID := ObjectID(O);
        end;
        U32(ID);
        if FLoading then
        begin
          var Fix := Default(TFixup);
          Fix.Address := Address;
          Fix.Info := Info;
          Fix.ID := ID;
          FFixups.Add(Fix);
        end;
      end;
    tkMethod:
      begin
        var M := PMethod(Address)^;
        var ID: Cardinal := 0;
        var Name := '';
        if not FLoading and (M.Code <> nil) then
        begin
          ID := ObjectID(TObject(M.Data));
          Name := NamedMethod(TObject(M.Data), M.Code);
        end;
        U32(ID);
        Text(Name);
        if FLoading then
        begin
          var Fix := Default(TFixup);
          Fix.Address := Address;
          Fix.Info := Info;
          Fix.ID := ID;
          Fix.MethodName := Name;
          FFixups.Add(Fix);
        end;
      end;
    tkDynArray, tkArray:
      begin
        var E: TRttiType;
        var N: Cardinal;
        var Base: Pointer;
        if T is TRttiDynamicArrayType then
        begin
          E := TRttiDynamicArrayType(T).ElementType;
          N := System.DynArraySize(PPointer(Address)^);
          U32(N);
          if (N > MaxElements) or (Int64(N) * E.TypeSize > MaxData) then
            raise EReadError.Create('Direct-state array is too large');
          if FLoading then
          begin
            Inc(FAllocated, Int64(N) * E.TypeSize);
            if FAllocated > MaxData then
              raise EReadError.Create('Direct-state allocation limit exceeded');
            var Length: NativeInt := N;
            DynArraySetLength(PPointer(Address)^, Info, 1, @Length);
          end;
          Base := PPointer(Address)^;
        end
        else
        begin
          E := TRttiArrayType(T).ElementType;
          N := T.TypeSize div E.TypeSize;
          var Stored := N;
          U32(Stored);
          if Stored <> N then
            raise EReadError.Create('Incompatible direct-state fixed array');
          Base := Address;
        end;
        if E.Handle = TypeInfo(Byte) then
          Raw(Base, N)
        else
          for var I := 0 to Integer(N) - 1 do
            TransferValue(E.Handle, PByte(Base) + NativeInt(I) * E.TypeSize);
      end;
    tkRecord, tkMRecord:
      begin
        var Fs := T.GetFields;
        if Length(Fs) = 0 then
          raise EPSPStateOpaque.Create('No record schema at ' + FPath + ': ' + T.Name);
        for var F in Fs do
        begin
          var Before := FPath;
          FPath := Before + '.' + F.Name;
          try
            TransferValue(FSchema.FieldInfo(F), PByte(Address) + F.Offset);
          finally
            FPath := Before;
          end;
        end;
      end;
    tkPointer, tkProcedure:
      begin
        if not FLoading and (PPointer(Address)^ <> nil) then
          raise EPSPStateOpaque.Create('A host pointer or procedure is active at ' + FPath);
        var Zero: Cardinal := 0;
        U32(Zero);
        if Zero <> 0 then
          raise EReadError.Create('Invalid direct-state null pointer');
        if FLoading then
          PPointer(Address)^ := nil;
      end;
  else
    raise EPSPStateOpaque.Create('Unsupported direct-state type at ' + FPath + ': ' + T.Name);
  end;
end;

procedure TPSPGraph.TransferFile(Node: TNode);
begin
  var Root: Cardinal := 4;
  var Relative := '';
  var Mode: Cardinal := fmOpenRead;
  var Position: UInt64 := 0;
  if not FLoading then
  begin
    var Stream := TFileStream(Node.Instance);
    var Name := TPath.GetFullPath(Stream.FileName);
    for var I := 0 to High(FRoots) do
      if FRoots[I] <> '' then
      begin
        var Prefix := IncludeTrailingPathDelimiter(TPath.GetFullPath(FRoots[I]));
        if Name.StartsWith(Prefix, {$IFDEF MSWINDOWS} True {$ELSE} False {$ENDIF}) then
        begin
          Root := I;
          Relative := Name.Substring(Prefix.Length).Replace(PathDelim, '/');
          Break;
        end;
      end;
    if Root > High(FRoots) then
      raise EPSPStateOpaque.Create('An open file is outside the mounted state folders');
    if Assigned(FStreamMode) then
      Mode := FStreamMode(Stream) and 3;
    Position := Stream.Position;
  end;
  U32(Root);
  Text(Relative);
  U32(Mode);
  U64(Position);
  if FLoading then
  begin
    if (Root > High(FRoots)) or (FRoots[Root] = '') or (Mode > 2) or (Position > UInt64(High(Int64))) or
      (Relative = '') or Relative.StartsWith('/') or Relative.Contains('\') or Relative.Contains(':') then
      raise EReadError.Create('Invalid state file path');
    for var Part in Relative.Split(['/']) do
      if (Part = '') or (Part = '.') or (Part = '..') or Part.EndsWith('.') or Part.EndsWith(' ') then
        raise EReadError.Create('Unsafe state file path');
    var Path := TPath.Combine(FRoots[Root], Relative.Replace('/', PathDelim));
    Node.Instance := TFileStream.Create(Path, Word(Mode) or fmShareDenyNone);
    TStream(Node.Instance).Position := Int64(Position);
  end;
end;

procedure TPSPGraph.TransferNode(Node: TNode);
begin
  FPath := Node.Name;
  case Node.Kind of
    nkObject:
      begin
        var Fs := Fields(Node);
        var N := Cardinal(Length(Fs));
        U32(N);
        if N > Cardinal(Length(Fs)) then
          raise EReadError.Create('Incompatible direct-state object fields: ' + Node.Name);
        if FLoading then
          Node.Fields.Capacity := N;
        var Seen := TDictionary<TRttiField, Boolean>.Create;
        try
          for var I := 0 to Integer(N) - 1 do
          begin
            var F := Fs[I];
            var Name := F.Parent.Name + '.' + F.Name;
            var Stored := Name;
            Text(Stored);
            if FLoading then
            begin
              F := nil;
              for var Candidate in Fs do
                if Candidate.Parent.Name + '.' + Candidate.Name = Stored then
                begin
                  F := Candidate;
                  Break;
                end;
              if (F = nil) or Seen.ContainsKey(F) then
                raise EReadError.Create('Incompatible direct-state field: ' + Stored);
            end;
            Seen.Add(F, True);
            var Info := FSchema.FieldInfo(F);
            FPath := Node.Name + '.' + F.Name;
            if FLoading then
            begin
              var Cell := Default(TCell);
              Cell.Field := F;
              Cell.Info := Info;
              Cell.Value := NewValue(Info);
              Node.Fields.Add(Cell);
              var StoredCell: PCell := @Node.Fields.List[Node.Fields.Count - 1];
              TransferValue(Info, StoredCell.Value.GetReferenceToRawData);
            end
            else
              TransferValue(Info, PByte(Node.Instance) + F.Offset);
          end;
          if FLoading then
            for var F in Fs do
              if not Seen.ContainsKey(F) and not FSchema.IsOptional(Node.Instance.ClassType, F.Name) then
                raise EReadError.Create('Missing direct-state field: ' + F.Name);
        finally
          Seen.Free;
        end;
      end;
    nkCollection:
      begin
        if not FLoading then
        begin
          Node.Elements := ArrayMethod(Node.Instance.ClassType).Invoke(Node.Instance, []);
          var Ownership := OwnershipField(Node.Instance);
          if Ownership <> nil then
            Move((PByte(Node.Instance) + Ownership.Offset)^, Node.Ownership, 1);
        end;
        Raw(@Node.Ownership, 1);
        var Info := ArrayMethod(Node.Instance.ClassType).ReturnType.Handle;
        if FLoading then
          Node.Elements := NewValue(Info);
        TransferValue(Info, Node.Elements.GetReferenceToRawData);
      end;
    nkMemory:
      begin
        var Data: TBytes := nil;
        var Position: UInt64 := 0;
        if not FLoading then
        begin
          var Stream := TMemoryStream(Node.Instance);
          if Stream.Size > MaxData then
            raise EPSPStateOpaque.Create('State memory stream is too large');
          SetLength(Data, Stream.Size);
          if Length(Data) > 0 then
            Move(Stream.Memory^, Data[0], Length(Data));
          Position := Stream.Position;
        end;
        Blob(Data);
        U64(Position);
        if FLoading then
        begin
          var Stream := TMemoryStream(Node.Instance);
          if Length(Data) > 0 then
            Stream.WriteBuffer(Data[0], Length(Data));
          if Position > UInt64(High(Int64)) then
            raise EReadError.Create('Invalid state stream position');
          Stream.Position := Int64(Position);
        end;
      end;
    nkFile:
      TransferFile(Node);
    nkBuilder:
      begin
        var S := '';
        if not FLoading then
          S := TStringBuilder(Node.Instance).ToString;
        Text(S);
        if FLoading then
          TStringBuilder(Node.Instance).Append(S);
      end;
    nkNative:
      begin
        var Data: TBytes := nil;
        if not FLoading then
        begin
          var Output := TMemoryStream.Create;
          var State := TStateArchive.Create(Output, False);
          try
            FSchema.TransferNative(Node.Instance, State);
            SetLength(Data, Output.Size);
            if Length(Data) > 0 then
              Move(Output.Memory^, Data[0], Length(Data));
          finally
            State.Free;
            Output.Free;
          end;
        end;
        Blob(Data);
        if FLoading then
        begin
          var Input := TBytesStream.Create(Data);
          var State := TStateArchive.Create(Input, True);
          try
            FSchema.TransferNative(Node.Instance, State);
            if Input.Position <> Input.Size then
              raise EReadError.Create('Unexpected codec state data');
          finally
            State.Free;
            Input.Free;
          end;
        end;
      end;
  else
    raise EReadError.Create('Unknown direct-state object kind');
  end;
end;

procedure TPSPGraph.ResolveFixups;
begin
  for var Fix in FFixups do
  begin
    if Fix.ID > Cardinal(FNodes.Count) then
      raise EReadError.Create('Invalid direct-state object reference');
    var O: TObject := nil;
    if Fix.ID <> 0 then
      O := FNodes[Fix.ID - 1].Instance;
    case Fix.Info.Kind of
      tkClass:
        begin
          var Expected := TRttiInstanceType(FContext.GetType(Fix.Info)).MetaclassType;
          if (O <> nil) and not O.InheritsFrom(Expected) then
            raise EReadError.Create('Invalid state object reference type');
          PObject(Fix.Address)^ := O;
        end;
      tkInterface:
        begin
          var I: IInterface := nil;
          if (O <> nil) and not O.GetInterface(GetTypeData(Fix.Info).Guid, I) then
            raise EReadError.Create('Invalid state continuation interface');
          PInterface(Fix.Address)^ := I;
        end;
      tkMethod:
        begin
          var M := Default(TMethod);
          if O <> nil then
          begin
            M.Data := O;
            M.Code := MethodCode(O, Fix.MethodName, Fix.Info);
          end
          else if Fix.MethodName <> '' then
            raise EReadError.Create('Invalid null state callback');
          PMethod(Fix.Address)^ := M;
        end;
    end;
  end;
end;

procedure TPSPGraph.Assign(const Cell: TCell; Instance: TObject);
begin
  var P := PByte(Instance) + Cell.Field.Offset;
  if (Cell.Info.Kind <> tkMethod) and System.Rtti.IsManaged(Cell.Info) then
    System.FinalizeArray(P, Cell.Info, 1);
  FillChar(P^, FContext.GetType(Cell.Info).TypeSize, 0);
  Cell.Value.ExtractRawData(P);
end;

procedure TPSPGraph.FillCollection(Node: TNode);
begin
  var O := Node.Instance;
  var T := FContext.GetType(O.ClassType);
  var Ownership := OwnershipField(O);
  if Ownership <> nil then
    Move(Node.Ownership, (PByte(O) + Ownership.Offset)^, 1);
  var Add: TRttiMethod := nil;
  for var M in T.GetMethods do
    if ((M.Name = 'Add') and (Length(M.GetParameters) in [1, 2])) or ((M.Name = 'Enqueue') and
      (Length(M.GetParameters) = 1)) or ((M.Name = 'Push') and (Length(M.GetParameters) = 1)) then
    begin
      Add := M;
      Break;
    end;
  if Add = nil then
    raise EReadError.Create('No state collection insertion method');
  var N := Node.Elements.GetArrayLength;
  for var I := 0 to N - 1 do
  begin
    var Item := Node.Elements.GetArrayElement(I);
    if Length(Add.GetParameters) = 2 then
    begin
      var PairType := FContext.GetType(Item.TypeInfo);
      Add.Invoke(O,
        [ PairType.GetField('Key').GetValue(Item.GetReferenceToRawData),
        PairType.GetField('Value').GetValue(Item.GetReferenceToRawData)]);
    end
    else
      Add.Invoke(O, [Item]);
  end;
end;

procedure TPSPGraph.ClearLinks(Info: PTypeInfo; Address: Pointer);
begin
  var T := FContext.GetType(Info);
  if FSchema.IsPlain(Info) then
    Exit;
  case T.TypeKind of
    tkClass:
      PObject(Address)^ := nil;
    tkInterface:
      PInterface(Address)^ := nil;
    tkMethod:
      PMethod(Address)^ := Default(TMethod);
    tkDynArray, tkArray:
      begin
        var E: TRttiType;
        var N: NativeInt;
        var Base: Pointer;
        if T is TRttiDynamicArrayType then
        begin
          E := TRttiDynamicArrayType(T).ElementType;
          N := DynArraySize(PPointer(Address)^);
          Base := PPointer(Address)^;
        end
        else
        begin
          E := TRttiArrayType(T).ElementType;
          N := T.TypeSize div E.TypeSize;
          Base := Address;
        end;
        for var I := 0 to N - 1 do
          ClearLinks(E.Handle, PByte(Base) + I * E.TypeSize);
      end;
    tkRecord, tkMRecord:
      for var F in T.GetFields do
        ClearLinks(FSchema.FieldInfo(F), PByte(Address) + F.Offset);
  end;
end;

procedure TPSPGraph.CollectOldValue(Info: PTypeInfo; Address: Pointer; Seen: TDictionary<TObject, Boolean>;
  List: TList<TObject>);
begin
  var T := FContext.GetType(Info);
  if FSchema.IsPlain(Info) then
    Exit;
  case T.TypeKind of
    tkClass:
      CollectOld(PObject(Address)^, Seen, List);
    tkInterface:
      if PInterface(Address)^ <> nil then
        CollectOld(PInterface(Address)^ as TObject, Seen, List);
    tkDynArray, tkArray:
      begin
        var E: TRttiType;
        var N: NativeInt;
        var Base: Pointer;
        if T is TRttiDynamicArrayType then
        begin
          E := TRttiDynamicArrayType(T).ElementType;
          N := DynArraySize(PPointer(Address)^);
          Base := PPointer(Address)^;
        end
        else
        begin
          E := TRttiArrayType(T).ElementType;
          N := T.TypeSize div E.TypeSize;
          Base := Address;
        end;
        for var I := 0 to N - 1 do
          CollectOldValue(E.Handle, PByte(Base) + I * E.TypeSize, Seen, List);
      end;
    tkRecord, tkMRecord:
      for var F in T.GetFields do
        CollectOldValue(FSchema.FieldInfo(F), PByte(Address) + F.Offset, Seen, List);
  end;
end;

procedure TPSPGraph.CollectOld(O: TObject; Seen: TDictionary<TObject, Boolean>; List: TList<TObject>);
begin
  if (O = nil) or Seen.ContainsKey(O) then
    Exit;
  var ID: Cardinal;
  if FIDs.TryGetValue(O, ID) then
    Exit; // External/root bindings are not owned here.
  Seen.Add(O, True);
  List.Add(O);
  if KindOf(O.ClassType) = nkCollection then
  begin
    var A := ArrayMethod(O.ClassType).Invoke(O, []);
    CollectOldValue(A.TypeInfo, A.GetReferenceToRawData, Seen, List);
  end
  else if KindOf(O.ClassType) = nkObject then
    for var F in FContext.GetType(O.ClassType).GetFields do
      if not FSchema.SkipField(O.ClassType, F.Name) then
        CollectOldValue(FSchema.FieldInfo(F), PByte(O) + F.Offset, Seen, List);
end;

procedure TPSPGraph.ReleaseObjects(const Objects: TList<TObject>; LinksApplied: Boolean);
begin
  var Leases: TArray<IInterface> := nil;
  for var O in Objects do
    if O is TInterfacedObject then
    begin
      SetLength(Leases, Length(Leases) + 1);
      if not O.GetInterface(GetTypeData(TypeInfo(IInterface)).Guid, Leases[High(Leases)]) then
        raise EReadError.Create('State object has no interface identity');
    end;
  if LinksApplied then
    for var O in Objects do
      if KindOf(O.ClassType) = nkCollection then
      begin
        var F := OwnershipField(O);
        if F <> nil then
          PByte(PByte(O) + F.Offset)^ := 0;
        var Notify := FContext.GetType(O.ClassType).GetField('FOnNotify');
        if Notify <> nil then
          PMethod(PByte(O) + Notify.Offset)^ := Default(TMethod);
        FContext.GetType(O.ClassType).GetMethod('Clear').Invoke(O, []);
      end
      else if KindOf(O.ClassType) = nkObject then
        for var F in FContext.GetType(O.ClassType).GetFields do
          if not FSchema.SkipField(O.ClassType, F.Name) then
            ClearLinks(FSchema.FieldInfo(F), PByte(O) + F.Offset);
  for var O in Objects do
    if not (O is TInterfacedObject) then
      if KindOf(O.ClassType) = nkObject then
        O.FreeInstance
      else
        O.Free;
  Leases := nil;
end;

procedure TPSPGraph.Save(Stream: TStream);
begin
  FStream := Stream;
  FLoading := False;
  FAllocated := 0;
  var Version: Cardinal := GraphVersion;
  U32(Version);
  var Count := Cardinal(FNodes.Count);
  U32(Count);
  for var Node in FNodes do
  begin
    var Name := Node.Binding;
    Text(Name);
    var TypeName := Node.Name;
    Text(TypeName);
  end;
  var CountAt := FStream.Position;
  Count := 0;
  U32(Count);
  var I := 0;
  while I < FNodes.Count do
  begin
    var Node := FNodes[I];
    var Name := Node.Name;
    Text(Name);
    var Binding := Node.Binding;
    Text(Binding);
    Raw(@Node.Kind, 1);
    TransferNode(Node);
    Inc(I);
  end;
  var EndAt := FStream.Position;
  FStream.Position := CountAt;
  Count := FNodes.Count;
  U32(Count);
  FStream.Position := EndAt;
end;

procedure TPSPGraph.Load(Stream: TStream);
begin
  FStream := Stream;
  FLoading := True;
  FAllocated := 0;
  var Version: Cardinal := 0;
  U32(Version);
  if Version <> GraphVersion then
    raise EReadError.Create('Unsupported PSP direct-state graph version');
  var BindingCount: Cardinal := 0;
  U32(BindingCount);
  if BindingCount <> Cardinal(FNodes.Count) then
    raise EReadError.Create('Incompatible direct-state bindings');
  for var I := 0 to Integer(BindingCount) - 1 do
  begin
    var Name := '';
    var TypeName := '';
    Text(Name);
    Text(TypeName);
    if (Name <> FNodes[I].Binding) or (TypeName <> FNodes[I].Name) then
      raise EReadError.Create('Incompatible direct-state binding ' + Name);
  end;
  var Count: Cardinal := 0;
  U32(Count);
  if (Count < BindingCount) or (Count > MaxNodes) then
    raise EReadError.Create('Invalid direct-state object count');
  var Created := TList<TObject>.Create;
  var Old := TList<TObject>.Create;
  var OldConstructed := TList<TObject>.Create;
  var Seen := TDictionary<TObject, Boolean>.Create;
  var Applying := False;
  var Committed := False;
  try
    for var I := 0 to Integer(Count) - 1 do
    begin
      var Name := '';
      var Binding := '';
      var Kind: Byte := 0;
      Text(Name);
      Text(Binding);
      Raw(@Kind, 1);
      var Node: TNode;
      if I < Integer(BindingCount) then
      begin
        Node := FNodes[I];
        if (Name <> Node.Name) or (Binding <> Node.Binding) or (Kind <> nkObject) then
          raise EReadError.Create('Invalid bound direct-state object');
      end
      else
      begin
        if Binding <> '' then
          raise EReadError.Create('Unexpected direct-state binding');
        var C := FSchema.FindClass(Name);
        if Kind <> KindOf(C) then
          raise EReadError.Create('Invalid direct-state object representation');
        Node := TNode.Create;
        Node.Name := Name;
        Node.Kind := Kind;
        Node.Selected := ['*'];
        Node.Created := True;
        FNodes.Add(Node);
        case Kind of
          nkCollection:
            Node.Instance := CreateCollection(C);
          nkMemory:
            Node.Instance := TMemoryStream.Create;
          nkBuilder:
            Node.Instance := TStringBuilder.Create;
          nkFile:
            ; // Validated path is read before opening a sandbox stream.
          nkNative:
            Node.Instance := FSchema.NewNative(C);
        else
          begin
            Node.Constructed := FSchema.HasFactory(C);
            if Node.Constructed then
              Node.Instance := FSchema.CreateData(C)
            else
            begin
              Node.Instance := C.NewInstance;
              if Node.Instance is TInterfacedObject then
                Node.Instance.AfterConstruction;
            end;
          end;
        end;
        if Node.Instance <> nil then
          Created.Add(Node.Instance);
      end;
      TransferNode(Node);
      if (Kind = nkFile) and (Node.Instance <> nil) then
        Created.Add(Node.Instance);
    end;
    if FStream.Position <> FStream.Size then
      raise EReadError.Create('Unexpected direct-state graph data');
    ResolveFixups;
    // Keep the old child graph alive until all new fields and containers apply.
    for var I := 0 to Integer(BindingCount) - 1 do
      for var Cell in FNodes[I].Fields do
      begin
        var Backup := Cell;
        TValue.Make(PByte(FNodes[I].Instance) + Cell.Field.Offset, Cell.Info, Backup.Value);
        FNodes[I].Backup.Add(Backup);
      end;
    for var Node in FNodes do
      if Node.Binding <> '' then
        for var Cell in Node.Fields do
        begin
          CollectOldValue(Cell.Info, PByte(Node.Instance) + Cell.Field.Offset, Seen, Old);
        end;
    for var Node in FNodes do
      if Node.Constructed then
        for var Cell in Node.Fields do
          CollectOldValue(Cell.Info, PByte(Node.Instance) + Cell.Field.Offset, Seen, OldConstructed);
    Applying := True;
    for var Node in FNodes do
      for var Cell in Node.Fields do
      begin
        Assign(Cell, Node.Instance);
      end;
    for var Node in FNodes do
      if Node.Kind = nkCollection then
        FillCollection(Node);
    Committed := True;
    // A bound interface may be the old graph's last owner. Keep the backups
    // alive until ReleaseObjects has leased its continuations and cleared links.
    ReleaseObjects(Old);
    ReleaseObjects(OldConstructed);
    for var I := 0 to Integer(BindingCount) - 1 do
      FNodes[I].Backup.Clear;
  finally
    if not Committed then
    begin
      if Applying then
        for var I := 0 to Integer(BindingCount) - 1 do
          for var Backup in FNodes[I].Backup do
            Assign(Backup, FNodes[I].Instance);
      // Staged interface values retain continuations until their links clear.
      ReleaseObjects(Created, Applying);
      if Applying then
        ReleaseObjects(OldConstructed);
    end;
    Seen.Free;
    OldConstructed.Free;
    Old.Free;
    Created.Free;
  end;
end;

end.
