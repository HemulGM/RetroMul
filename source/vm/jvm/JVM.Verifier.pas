unit JVM.Verifier;

interface

uses
  JVM.ClassFile;

type
  TJVMVerificationResolver = reference to function(const Name: string): TJVMClass;

procedure JVMVerifyMethod(Method: TJVMMethod; const Resolve: TJVMVerificationResolver);

implementation

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.Bytecode,
  JVM.Linker;

{$SCOPEDENUMS ON}

type
  TVKind = (Top, Int, Float, Long, Double, Null, Reference, UninitializedThis, Uninitialized, ReturnAddress, WideTail);

  TVType = record
    Kind: TVKind;
    Name: string;
    Offset: Integer;
    class function Make(Kind: TVKind; const Name: string = ''; Offset: Integer = 0): TVType; static;
    function Width: Integer;
    function Same(const Other: TVType): Boolean;
  end;

  TSubroutine = record
    Target, ReturnPC: Integer;
  end;

  TVFrame = class
  public
    Locals, Stack: TArray<TVType>;
    Context: TArray<TSubroutine>;
    ThisPending, Queued: Boolean;
    PC, StackSlots: Integer;
    function Clone: TVFrame;
    procedure Store(Index: Integer; const Value: TVType);
  end;

  TMapReader = record
    Data: TBytes;
    Position: Integer;
    function U1: Byte;
    function U2: Word;
    procedure Finish;
  end;

  TVChecker = class
  private
    FMethod: TJVMMethod;
    FResolve: TJVMVerificationResolver;
    FLinker: TJVMClassLinker;
    FStates: TObjectDictionary<string, TVFrame>;
    FMaps: TObjectDictionary<Integer, TVFrame>;
    FQueue: TQueue<string>;
    FFrame: TVFrame;
    FPC, FStart, FCells: Integer;
    FWork: Int64;
    FConstructorToken: TVType;
    FHasConstructorToken: Boolean;
    function Resolve(const Name: string): TJVMClass;
    function StrictAssignable(const Actual, Expected: string; Depth: Integer = 0): Boolean;
    function Assignable(const Actual, Expected: TVType): Boolean;
    function Common(const A, B: TVType): TVType;
    function FromDescriptor(const Descriptor: string): TVType;
    function Reference(const Name: string): TVType;
    function InitialFrame: TVFrame;
    procedure Fail(const Message: string);
    procedure Work(Count: Integer);
    procedure Push(const Value: TVType);
    function Pop: TVType;
    function Take(Kind: TVKind; AllowUninitialized: Boolean = False): TVType;
    procedure Expect(const Value, Expected: TVType);
    procedure Category1(const Value: TVType);
    function U1: Byte;
    function U2: Word;
    function S4: Integer;
    function Key(Frame: TVFrame; PC: Integer): string;
    procedure Flow(PC: Integer; Frame: TVFrame);
    procedure NormalizeLocals(Frame: TVFrame);
    procedure ReadMaps;
    function ReadMapType(var Reader: TMapReader): TVType;
    procedure AddMap(PC: Integer; const Locals, Stack: TArray<TVType>);
    procedure RequireMap(PC: Integer);
    procedure StaticInstructions;
    procedure CheckMap(Frame, Map: TVFrame);
    procedure ExceptionEdges(Before: TVFrame);
    procedure Instruction;
    function ArrayValue(const Value: TVType; Opcode: Byte): TVType;
    procedure InitializeAliases(const Token: TVType; const ClassName: string);
    procedure ProtectedReceiver(const ClassName, Name, Descriptor: string; const Value: TVType; IsField: Boolean);
  public
    constructor Create(Method: TJVMMethod; const Resolve: TJVMVerificationResolver);
    destructor Destroy; override;
    procedure Run;
  end;

class function TVType.Make(Kind: TVKind; const Name: string; Offset: Integer): TVType;
begin
  Result.Kind := Kind;
  Result.Name := Name;
  Result.Offset := Offset;
end;

function TVType.Width: Integer;
begin
  if Kind in [TVKind.Long, TVKind.Double] then
    Result := 2
  else
    Result := 1;
end;

function TVType.Same(const Other: TVType): Boolean;
begin
  Result := (Kind = Other.Kind) and (Name = Other.Name) and (Offset = Other.Offset);
end;

function TVFrame.Clone: TVFrame;
begin
  Result := TVFrame.Create;
  Result.Locals := Copy(Locals);
  Result.Stack := Copy(Stack);
  Result.Context := Copy(Context);
  Result.ThisPending := ThisPending;
  Result.PC := PC;
  Result.StackSlots := StackSlots;
end;

procedure TVFrame.Store(Index: Integer; const Value: TVType);

  procedure Clear(At: Integer);
  begin
    if (Locals[At].Kind = TVKind.WideTail) and (At > 0) then
      Locals[At - 1] := TVType.Make(TVKind.Top);
    if (Locals[At].Width = 2) and (At + 1 < Length(Locals)) then
      Locals[At + 1] := TVType.Make(TVKind.Top);
    Locals[At] := TVType.Make(TVKind.Top);
  end;

begin
  if (Index < 0) or (Index > Length(Locals) - Value.Width) then
    raise EJVMVerifyError.Create('Local outside frame');
  Clear(Index);
  if Value.Width = 2 then
    Clear(Index + 1);
  Locals[Index] := Value;
  if Value.Width = 2 then
    Locals[Index + 1] := TVType.Make(TVKind.WideTail);
end;

function TMapReader.U1: Byte;
begin
  if Position >= Length(Data) then
    raise EJVMVerifyError.Create('Truncated stack map');
  Result := Data[Position];
  Inc(Position);
end;

function TMapReader.U2: Word;
var
  A: Byte;
begin
  A := U1;
  Result := (Word(A) shl 8) or U1;
end;

procedure TMapReader.Finish;
begin
  if Position <> Length(Data) then
    raise EJVMVerifyError.Create('Trailing stack map data');
end;

constructor TVChecker.Create(Method: TJVMMethod; const Resolve: TJVMVerificationResolver);
begin
  inherited Create;
  FMethod := Method;
  FResolve := Resolve;
  FLinker := TJVMClassLinker.Create(
    function(const Name: string): TJVMClass
    begin
      Result := Self.Resolve(Name);
    end);
  FStates := TObjectDictionary<string, TVFrame>.Create([doOwnsValues]);
  FMaps := TObjectDictionary<Integer, TVFrame>.Create([doOwnsValues]);
  FQueue := TQueue<string>.Create;
end;

destructor TVChecker.Destroy;
begin
  FLinker.Free;
  FFrame.Free;
  FQueue.Free;
  FMaps.Free;
  FStates.Free;
  inherited;
end;

procedure TVChecker.Fail(const Message: string);
begin
  raise EJVMVerifyError.CreateFmt('%s.%s%s pc=%d: %s', [FMethod.Owner.Name, FMethod.Name, FMethod.Descriptor, FStart, Message]);
end;

procedure TVChecker.Work(Count: Integer);
begin
  Inc(FWork, Count);
  if FWork > 50000000 then
    raise EJVMUnsupported.Create('Verification work limit exceeded');
end;

function TVChecker.Resolve(const Name: string): TJVMClass;
begin
  if Name = FMethod.Owner.Name then
    Exit(FMethod.Owner);
  if not Assigned(FResolve) then
    raise EJVMUnsupported.Create('Verification needs a class resolver: ' + Name);
  Result := FResolve(Name);
end;

function TVChecker.Reference(const Name: string): TVType;
begin
  Result := TVType.Make(TVKind.Reference, Name);
end;

procedure TVChecker.ProtectedReceiver(const ClassName, Name, Descriptor: string; const Value: TVType; IsField: Boolean);
var
  C, Owner: TJVMClass;
  Field: TJVMField;
  M: TJVMMethod;
  Flags: Word;
  Depth: Integer;
begin
  if Value.Kind <> TVKind.Reference then
    Exit;
  if ClassName.StartsWith('[') and (Name = 'clone') then
    Exit;
  // JVMS 4.10.1.8 applies when the symbolic owner names this class or a
  // superclass. Other illegal accesses remain lazy linkage errors.
  C := FMethod.Owner;
  Depth := 0;
  while (C <> nil) and (C.Name <> ClassName) do
  begin
    if C.SuperName = '' then
      Exit;
    C := Resolve(C.SuperName);
    Inc(Depth);
    if Depth > 256 then
      Fail('Deep protected member hierarchy');
  end;
  if C = nil then
    Exit;
  try
    if IsField then
    begin
      Field := FLinker.Field(C, Name, Descriptor, Owner);
      Flags := Field.Access;
    end
    else
    begin
      M := FLinker.Method(C, Name, Descriptor);
      Owner := M.Owner;
      Flags := M.Access;
    end;
  except
    on E: EJVMLinkError do
      Exit;
  end; // Absent members fail upon resolution at execution.
  if ((Flags and (JVM_ACC_PROTECTED or JVM_ACC_STATIC)) = JVM_ACC_PROTECTED) and
    (JVMPackage(Owner.Name) <> JVMPackage(FMethod.Owner.Name)) then
    Expect(Value, Reference(FMethod.Owner.Name));
end;

function TVChecker.FromDescriptor(const Descriptor: string): TVType;
begin
  JVMFieldType(Descriptor);
  case Descriptor[1] of
    'J':
      Result := TVType.Make(TVKind.Long);
    'F':
      Result := TVType.Make(TVKind.Float);
    'D':
      Result := TVType.Make(TVKind.Double);
    '[':
      Result := Reference(Descriptor);
    'L':
      Result := Reference(Copy(Descriptor, 2, Length(Descriptor) - 2));
  else
    Result := TVType.Make(TVKind.Int);
  end;
end;

function TVChecker.StrictAssignable(const Actual, Expected: string; Depth: Integer): Boolean;
var
  C: TJVMClass;
  Name, A, E: string;
begin
  if Depth > 256 then
    Fail('Cyclic/deep type hierarchy');
  if (Actual = Expected) or (Expected = 'java/lang/Object') then
    Exit(True);
  if Actual.StartsWith('[') then
  begin
    if (Expected = 'java/lang/Cloneable') or (Expected = 'java/io/Serializable') then
      Exit(True);
    if not Expected.StartsWith('[') then
      Exit(False);
    A := Copy(Actual, 2, MaxInt);
    E := Copy(Expected, 2, MaxInt);
    if (Length(A) = 1) or (Length(E) = 1) then
      Exit(A = E);
    if A[1] = 'L' then
      A := Copy(A, 2, Length(A) - 2);
    if E[1] = 'L' then
      E := Copy(E, 2, Length(E) - 2);
    Exit(StrictAssignable(A, E, Depth + 1));
  end;
  if Expected.StartsWith('[') then
    Exit(False);
  C := Resolve(Actual);
  for Name in C.Interfaces do
    if StrictAssignable(Name, Expected, Depth + 1) then
      Exit(True);
  Result := (C.SuperName <> '') and StrictAssignable(C.SuperName, Expected, Depth + 1);
end;

function TVChecker.Assignable(const Actual, Expected: TVType): Boolean;
begin
  if Expected.Kind = TVKind.Top then
    Exit(True);
  if Actual.Same(Expected) then
    Exit(True);
  if (Actual.Kind = TVKind.Null) and (Expected.Kind = TVKind.Reference) then
    Exit(True);
  if (Actual.Kind <> TVKind.Reference) or (Expected.Kind <> TVKind.Reference) then
    Exit(False);
  if (Expected.Name = 'java/lang/Object') or (Actual.Name = Expected.Name) then
    Exit(True);
  // Interface use is checked by invokeinterface/runtime. JVMS verification treats
  // interface destinations as Object; array component subtyping remains strict.
  if not Expected.Name.StartsWith('[') and ((Resolve(Expected.Name).Access and $0200) <> 0) then
    Exit(True);
  Result := StrictAssignable(Actual.Name, Expected.Name);
end;

function TVChecker.Common(const A, B: TVType): TVType;
var
  C: TJVMClass;
  Name: string;
  Depth: Integer;
  AC, BC, Component: TVType;
begin
  if A.Same(B) then
    Exit(A);
  if A.Kind = TVKind.Null then
    Exit(B);
  if B.Kind = TVKind.Null then
    Exit(A);
  if StrictAssignable(A.Name, B.Name) then
    Exit(B);
  if StrictAssignable(B.Name, A.Name) then
    Exit(A);
  if A.Name.StartsWith('[') and B.Name.StartsWith('[') then
  begin
    AC := FromDescriptor(Copy(A.Name, 2, MaxInt));
    BC := FromDescriptor(Copy(B.Name, 2, MaxInt));
    if (AC.Kind = TVKind.Reference) and (BC.Kind = TVKind.Reference) then
    begin
      Component := Common(AC, BC);
      if Component.Name.StartsWith('[') then
        Exit(Reference('[' + Component.Name));
      Exit(Reference('[L' + Component.Name + ';'));
    end;
  end;
  Name := A.Name;
  Depth := 0;
  while not Name.StartsWith('[') do
  begin
    C := Resolve(Name);
    Name := C.SuperName;
    if Name = '' then
      Break;
    if StrictAssignable(B.Name, Name) then
      Exit(Reference(Name));
    Inc(Depth);
    if Depth > 256 then
      Fail('Cyclic common superclass');
  end;
  Result := Reference('java/lang/Object');
end;

function TVChecker.InitialFrame: TVFrame;
var
  P: Integer;
  D: string;
  Value: TVType;
begin
  Result := TVFrame.Create;
  try
    SetLength(Result.Locals, FMethod.MaxLocals);
    P := 0;
    if (FMethod.Access and JVM_ACC_STATIC) = 0 then
    begin
      Value := Reference(FMethod.Owner.Name);
      if (FMethod.Name = '<init>') and (FMethod.Owner.Name <> 'java/lang/Object') then
      begin
        Value := TVType.Make(TVKind.UninitializedThis, FMethod.Owner.Name, -1);
        Result.ThisPending := True;
      end;
      Result.Store(0, Value);
      P := 1;
    end;
    for D in FMethod.Signature.Arguments do
    begin
      Value := FromDescriptor(D);
      Result.Store(P, Value);
      Inc(P, Value.Width);
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TVChecker.Push(const Value: TVType);
var
  N: Integer;
begin
  if FFrame.StackSlots + Value.Width > FMethod.MaxStack then
    Fail('Operand stack exceeds max_stack');
  N := Length(FFrame.Stack);
  SetLength(FFrame.Stack, N + 1);
  FFrame.Stack[N] := Value;
  Inc(FFrame.StackSlots, Value.Width);
end;

function TVChecker.Pop: TVType;
var
  N: Integer;
begin
  N := Length(FFrame.Stack);
  if N = 0 then
    Fail('Operand stack underflow');
  Result := FFrame.Stack[N - 1];
  SetLength(FFrame.Stack, N - 1);
  Dec(FFrame.StackSlots, Result.Width);
end;

function TVChecker.Take(Kind: TVKind; AllowUninitialized: Boolean): TVType;
begin
  Result := Pop;
  if Kind = TVKind.Reference then
  begin
    if Result.Kind in [TVKind.Reference, TVKind.Null] then
      Exit;
    if AllowUninitialized and (Result.Kind in [TVKind.Uninitialized, TVKind.UninitializedThis]) then
      Exit;
  end
  else if Result.Kind = Kind then
    Exit;
  Fail('Incorrect operand type');
end;

procedure TVChecker.Expect(const Value, Expected: TVType);
begin
  if not Assignable(Value, Expected) then
    Fail('Value is not assignable to ' + Expected.Name);
end;

procedure TVChecker.Category1(const Value: TVType);
begin
  if (Value.Width <> 1) or (Value.Kind in [TVKind.Top, TVKind.WideTail]) then
    Fail('Expected category-1 value');
end;

function TVChecker.U1: Byte;
begin
  if FPC >= Length(FMethod.Code) then
    Fail('Truncated instruction');
  Result := FMethod.Code[FPC];
  Inc(FPC);
end;

function TVChecker.U2: Word;
var
  A: Byte;
begin
  A := U1;
  Result := (Word(A) shl 8) or U1;
end;

function TVChecker.S4: Integer;
var
  A: Word;
begin
  A := U2;
  Result := Integer((UInt32(A) shl 16) or U2);
end;

function TVChecker.Key(Frame: TVFrame; PC: Integer): string;
begin
  Result := IntToStr(PC);
  for var Sub in Frame.Context do
    Result := Result + '/' + IntToStr(Sub.Target) + ':' + IntToStr(Sub.ReturnPC);
end;

procedure TVChecker.NormalizeLocals(Frame: TVFrame);
begin
  for var I := 0 to High(Frame.Locals) do
  begin
    if (Frame.Locals[I].Kind = TVKind.WideTail) and
      ((I = 0) or (Frame.Locals[I - 1].Width <> 2)) then
      Frame.Locals[I] := TVType.Make(TVKind.Top);
    if (Frame.Locals[I].Width = 2) and
      ((I + 1 >= Length(Frame.Locals)) or (Frame.Locals[I + 1].Kind <> TVKind.WideTail)) then
      Frame.Locals[I] := TVType.Make(TVKind.Top);
  end;
end;

procedure TVChecker.CheckMap(Frame, Map: TVFrame);
begin
  if Length(Frame.Stack) <> Length(Map.Stack) then
    Fail('Stack map stack height mismatch');
  for var I := 0 to High(Frame.Stack) do
    Expect(Frame.Stack[I], Map.Stack[I]);
  for var I := 0 to High(Frame.Locals) do
    Expect(Frame.Locals[I], Map.Locals[I]);
  Frame.Locals := Copy(Map.Locals);
  Frame.Stack := Copy(Map.Stack);
  Frame.StackSlots := Map.StackSlots;
  NormalizeLocals(Frame);
end;

procedure TVChecker.Flow(PC: Integer; Frame: TVFrame);
var
  State, Map, Incoming: TVFrame;
  StateKey: string;
  Changed: Boolean;
  Merged: TVType;
begin
  Work(Length(Frame.Locals) + Length(Frame.Stack) + 1);
  if Frame.StackSlots > FMethod.MaxStack then
    Fail('Incoming operand stack exceeds max_stack');
  if (PC < 0) or (PC >= Length(FMethod.Code)) or not FMethod.InstructionStarts[PC] then
    Fail('Invalid control-flow successor');
  Incoming := Frame.Clone;
  try
    Incoming.PC := PC;
    if FMaps.TryGetValue(PC, Map) then
      CheckMap(Incoming, Map);
    StateKey := Key(Incoming, PC);
    if not FStates.TryGetValue(StateKey, State) then
    begin
      if (FStates.Count >= 100000) or (FCells > 4194304 - Length(Incoming.Locals) - Length(Incoming.Stack)) then
        raise EJVMUnsupported.Create('Verification state limit exceeded');
      Inc(FCells, Length(Incoming.Locals) + Length(Incoming.Stack));
      State := Incoming;
      Incoming := nil;
      FStates.Add(StateKey, State);
      Changed := True;
    end
    else
    begin
      Changed := False;
      if Length(State.Stack) <> Length(Incoming.Stack) then
        Fail('Incompatible stack heights at merge');
      for var I := 0 to High(State.Stack) do
        if not State.Stack[I].Same(Incoming.Stack[I]) then
        begin
          if not (State.Stack[I].Kind in [TVKind.Reference, TVKind.Null]) or
            not (Incoming.Stack[I].Kind in [TVKind.Reference, TVKind.Null]) then
            Fail('Incompatible stack types at merge');
          Merged := Common(State.Stack[I], Incoming.Stack[I]);
          if not State.Stack[I].Same(Merged) then
          begin
            State.Stack[I] := Merged;
            Changed := True;
          end;
        end;
      for var I := 0 to High(State.Locals) do
        if not State.Locals[I].Same(Incoming.Locals[I]) then
        begin
          if (State.Locals[I].Kind in [TVKind.Reference, TVKind.Null]) and
            (Incoming.Locals[I].Kind in [TVKind.Reference, TVKind.Null]) then
            Merged := Common(State.Locals[I], Incoming.Locals[I])
          else
            Merged := TVType.Make(TVKind.Top);
          if not State.Locals[I].Same(Merged) then
          begin
            State.Locals[I] := Merged;
            Changed := True;
          end;
        end;
      if Incoming.ThisPending and not State.ThisPending then
      begin
        State.ThisPending := True;
        Changed := True;
      end;
      NormalizeLocals(State);
    end;
    if Changed and not State.Queued then
    begin
      State.Queued := True;
      FQueue.Enqueue(StateKey);
    end;
  finally
    Incoming.Free;
  end;
end;

function TVChecker.ReadMapType(var Reader: TMapReader): TVType;
var
  Tag, At, Index: Integer;
begin
  Tag := Reader.U1;
  case Tag of
    0:
      Result := TVType.Make(TVKind.Top);
    1:
      Result := TVType.Make(TVKind.Int);
    2:
      Result := TVType.Make(TVKind.Float);
    3:
      Result := TVType.Make(TVKind.Double);
    4:
      Result := TVType.Make(TVKind.Long);
    5:
      Result := TVType.Make(TVKind.Null);
    6:
      begin
        if FMethod.Name <> '<init>' then
          Fail('uninitializedThis outside a constructor');
        Result := TVType.Make(TVKind.UninitializedThis, FMethod.Owner.Name, -1);
      end;
    7:
      Result := Reference(FMethod.Owner.ClassName(Reader.U2));
    8:
      begin
        At := Reader.U2;
        if (At < 0) or (At + 2 >= Length(FMethod.Code)) or not FMethod.InstructionStarts[At] or
          (FMethod.Code[At] <> $BB) then
          Fail('Stack map uninitialized offset does not identify new');
        Index := (Word(FMethod.Code[At + 1]) shl 8) or FMethod.Code[At + 2];
        Result := TVType.Make(TVKind.Uninitialized, FMethod.Owner.ClassName(Index), At);
      end;
  else
    Fail('Invalid verification_type_info tag');
    Result := Default(TVType);
  end;
end;

procedure TVChecker.AddMap(PC: Integer; const Locals, Stack: TArray<TVType>);
var
  Map: TVFrame;
  P: Integer;
begin
  if (PC < 0) or (PC >= Length(FMethod.Code)) or not FMethod.InstructionStarts[PC] then
    Fail('Stack map offset is not an instruction');
  if FMaps.ContainsKey(PC) then
    Fail('Duplicate stack map offset');
  if FCells > 4194304 - FMethod.MaxLocals - Length(Stack) then
    raise EJVMUnsupported.Create('Stack map state limit exceeded');
  Inc(FCells, FMethod.MaxLocals + Length(Stack));
  Map := TVFrame.Create;
  try
    Map.PC := PC;
    SetLength(Map.Locals, FMethod.MaxLocals);
    P := 0;
    for var Value in Locals do
    begin
      Map.Store(P, Value);
      Inc(P, Value.Width);
    end;
    Map.Stack := Copy(Stack);
    for var Value in Stack do
      Inc(Map.StackSlots, Value.Width);
    if Map.StackSlots > FMethod.MaxStack then
      Fail('Stack map exceeds max_stack');
    FMaps.Add(PC, Map);
    Map := nil;
  finally
    Map.Free;
  end;
end;

procedure TVChecker.ReadMaps;
var
  R: TMapReader;
  Count, PC, LastPC, I, J, Tag, Delta, N: Integer;
  Locals, Stack: TArray<TVType>;
  Initial: TVFrame;

  procedure ReadList(var Values: TArray<TVType>);
  begin
    SetLength(Values, R.U2);
    for var At := 0 to High(Values) do
      Values[At] := ReadMapType(R);
  end;

begin
  R := Default(TMapReader);
  if FMethod.HasStackMap and not (FMethod.HasStackMapTable and (FMethod.Owner.Major >= 50)) then
  begin
    R.Data := FMethod.StackMap;
    Count := R.U2;
    LastPC := -1;
    for I := 1 to Count do
    begin
      PC := R.U2;
      if PC <= LastPC then
        Fail('Unsorted CLDC stack map offsets');
      LastPC := PC;
      ReadList(Locals);
      ReadList(Stack);
      AddMap(PC, Locals, Stack);
    end;
    R.Finish;
  end;
  if not FMethod.HasStackMapTable or (FMethod.Owner.Major < 50) then
    Exit;
  Initial := InitialFrame;
  try
    for I := 0 to High(Initial.Locals) do
    begin
      if Initial.Locals[I].Kind = TVKind.WideTail then
        Continue;
      if Initial.Locals[I].Kind = TVKind.Top then
        Break;
      Locals := Locals + [Initial.Locals[I]];
    end;
  finally
    Initial.Free;
  end;
  R.Data := FMethod.StackMapTable;
  Count := R.U2;
  PC := -1;
  for I := 1 to Count do
  begin
    Tag := R.U1;
    Stack := nil;
    case Tag of
      0..63:
        Delta := Tag;
      64..127:
        begin
          Delta := Tag - 64;
          Stack := TArray<TVType>.Create(ReadMapType(R));
        end;
      247:
        begin
          Delta := R.U2;
          Stack := TArray<TVType>.Create(ReadMapType(R));
        end;
      248..250:
        begin
          Delta := R.U2;
          N := 251 - Tag;
          if N > Length(Locals) then
            Fail('StackMapTable chop underflow');
          SetLength(Locals, Length(Locals) - N);
        end;
      251:
        Delta := R.U2;
      252..254:
        begin
          Delta := R.U2;
          for J := 1 to Tag - 251 do
            Locals := Locals + [ReadMapType(R)];
        end;
      255:
        begin
          Delta := R.U2;
          ReadList(Locals);
          ReadList(Stack);
        end;
    else
      Fail('Reserved StackMapTable frame type');
      Delta := 0;
    end;
    if Int64(PC) + Delta + 1 > High(Integer) then
      Fail('Stack map offset overflow');
    Inc(PC, Delta + 1);
    AddMap(PC, Locals, Stack);
  end;
  R.Finish;
end;

procedure TVChecker.ExceptionEdges(Before: TVFrame);
var
  Edge: TVFrame;
  Value: TVType;
begin
  for var H in FMethod.Handlers do
  begin
    Work(1);
    if (FStart < H.StartPC) or (FStart >= H.EndPC) then
      Continue;
    Edge := Before.Clone;
    try
      if FHasConstructorToken then
        for var I := 0 to High(Edge.Locals) do
          if Edge.Locals[I].Same(FConstructorToken) then
            Edge.Locals[I] := TVType.Make(TVKind.Top);
      if H.CatchType = 0 then
        Value := Reference('java/lang/Throwable')
      else
        Value := Reference(FMethod.Owner.ClassName(H.CatchType));
      if not StrictAssignable(Value.Name, 'java/lang/Throwable') then
        Fail('Exception handler type is not Throwable');
      Edge.Stack := TArray<TVType>.Create(Value);
      Edge.StackSlots := 1;
      RequireMap(H.HandlerPC);
      Flow(H.HandlerPC, Edge);
    finally
      Edge.Free;
    end;
  end;
end;

procedure TVChecker.InitializeAliases(const Token: TVType; const ClassName: string);
begin
  FConstructorToken := Token;
  FHasConstructorToken := True;
  for var I := 0 to High(FFrame.Locals) do
    if FFrame.Locals[I].Same(Token) then
      FFrame.Locals[I] := Reference(ClassName);
  for var I := 0 to High(FFrame.Stack) do
    if FFrame.Stack[I].Same(Token) then
      FFrame.Stack[I] := Reference(ClassName);
  if Token.Kind = TVKind.UninitializedThis then
    FFrame.ThisPending := False;
end;

function TVChecker.ArrayValue(const Value: TVType; Opcode: Byte): TVType;
var
  D: string;
begin
  if Value.Kind = TVKind.Null then
  begin
    if Opcode in [$32, $53] then
      Exit(Value);
    case Opcode of
      $2F, $50:
        Exit(TVType.Make(TVKind.Long));
      $30, $51:
        Exit(TVType.Make(TVKind.Float));
      $31, $52:
        Exit(TVType.Make(TVKind.Double));
    else
      Exit(TVType.Make(TVKind.Int));
    end;
  end;
  if (Value.Kind <> TVKind.Reference) or not Value.Name.StartsWith('[') then
    Fail('Expected array type');
  D := Copy(Value.Name, 2, MaxInt);
  case Opcode of
    $2E, $4F:
      if D <> 'I' then
        Fail('Expected int array');
    $2F, $50:
      if D <> 'J' then
        Fail('Expected long array');
    $30, $51:
      if D <> 'F' then
        Fail('Expected float array');
    $31, $52:
      if D <> 'D' then
        Fail('Expected double array');
    $32, $53:
      if not CharInSet(D[1], ['L', '[']) then
        Fail('Expected reference array');
    $33, $54:
      if (D <> 'B') and (D <> 'Z') then
        Fail('Expected byte/boolean array');
    $34, $55:
      if D <> 'C' then
        Fail('Expected char array');
    $35, $56:
      if D <> 'S' then
        Fail('Expected short array');
  end;
  Result := FromDescriptor(D);
end;

procedure TVChecker.Instruction;
const
  Kinds: array[0..4] of TVKind = (TVKind.Int, TVKind.Long, TVKind.Float, TVKind.Double, TVKind.Reference);
var
  Op, SubOp: Byte;
  A, B, V, W, Expected: TVType;
  C: TJVMConstant;
  I, J, Index, Offset, LowKey, HighKey, Count: Integer;
  FallsThrough, Found: Boolean;
  ClassName, Name, Descriptor: string;
  Signature: TJVMMethodType;
  Sub: TSubroutine;

  procedure Edge(At: Int64);
  begin
    if (At < 0) or (At >= Length(FMethod.Code)) then
      Fail('Branch outside method');
    RequireMap(Integer(At));
    Flow(Integer(At), FFrame);
  end;

  procedure LocalLoad(At, Family: Integer);
  var
    Value: TVType;
  begin
    if (At < 0) or (At >= Length(FFrame.Locals)) then
      Fail('Local outside frame');
    Value := FFrame.Locals[At];
    if Family = 4 then
    begin
      if not (Value.Kind in [TVKind.Reference, TVKind.Null, TVKind.Uninitialized, TVKind.UninitializedThis]) then
        Fail('Invalid aload local');
    end
    else if Value.Kind <> Kinds[Family] then
      Fail('Incorrect local type');
    if (Value.Width = 2) and ((At + 1 >= Length(FFrame.Locals)) or (FFrame.Locals[At + 1].Kind <> TVKind.WideTail)) then
      Fail('Invalid wide local tail');
    Push(Value);
  end;

  procedure LocalStore(At, Family: Integer);
  var
    Value: TVType;
  begin
    Value := Pop;
    if Family = 4 then
    begin
      if not (Value.Kind in [TVKind.Reference, TVKind.Null, TVKind.Uninitialized, TVKind.UninitializedThis, TVKind.ReturnAddress]) then
        Fail('Invalid astore value');
    end
    else if Value.Kind <> Kinds[Family] then
      Fail('Incorrect local store type');
    FFrame.Store(At, Value);
  end;

  procedure Increment(At: Integer);
  begin
    if (At < 0) or (At >= Length(FFrame.Locals)) or (FFrame.Locals[At].Kind <> TVKind.Int) then
      Fail('iinc needs an int local');
  end;

  procedure Jsr(At: Integer);
  begin
    if FMethod.Owner.Major >= 51 then
      Fail('jsr is not permitted in class version 51');
    if Length(FFrame.Context) >= 32 then
      Fail('Subroutine nesting limit');
    for var Entry in FFrame.Context do
      if Entry.Target = At then
        Fail('Recursive jsr');
    Sub.Target := At;
    Sub.ReturnPC := FPC;
    FFrame.Context := FFrame.Context + [Sub];
    Push(TVType.Make(TVKind.ReturnAddress, '', FPC));
    Edge(At);
    FallsThrough := False;
  end;

  procedure Ret(At: Integer);
  var
    Value: TVType;
  begin
    if (FMethod.Owner.Major >= 51) or (Length(FFrame.Context) = 0) then
      Fail('ret outside a legacy subroutine');
    if (At < 0) or (At >= Length(FFrame.Locals)) then
      Fail('ret local outside frame');
    Value := FFrame.Locals[At];
    if (Value.Kind <> TVKind.ReturnAddress) or (Value.Offset <> FFrame.Context[High(FFrame.Context)].ReturnPC) then
      Fail('ret does not match its jsr');
    SetLength(FFrame.Context, Length(FFrame.Context) - 1);
    Flow(Value.Offset, FFrame);
    FallsThrough := False;
  end;

begin
  Op := U1;
  FallsThrough := True;
  case Op of
    $00:
      ;
    $01:
      Push(TVType.Make(TVKind.Null));
    $02..$08, $10, $11:
      begin
        if Op = $10 then
          U1
        else if Op = $11 then
          U2;
        Push(TVType.Make(TVKind.Int));
      end;
    $09..$0A:
      Push(TVType.Make(TVKind.Long));
    $0B..$0D:
      Push(TVType.Make(TVKind.Float));
    $0E..$0F:
      Push(TVType.Make(TVKind.Double));
    $12..$14:
      begin
        if Op = $12 then
          Index := U1
        else
          Index := U2;
        C := FMethod.Owner.Constant(Index);
        case C.Tag of
          3:
            V := TVType.Make(TVKind.Int);
          4:
            V := TVType.Make(TVKind.Float);
          5:
            V := TVType.Make(TVKind.Long);
          6:
            V := TVType.Make(TVKind.Double);
          7:
            V := Reference('java/lang/Class');
          8:
            V := Reference('java/lang/String');
        else
          Fail('Invalid ldc constant');
          V := Default(TVType);
        end;
        if (V.Width = 2) <> (Op = $14) then
          Fail('Incorrect ldc width');
        Push(V);
      end;
    $15..$19:
      LocalLoad(U1, Op - $15);
    $1A..$2D:
      LocalLoad((Op - $1A) mod 4, (Op - $1A) div 4);
    $2E..$35:
      begin
        Take(TVKind.Int);
        V := Take(TVKind.Reference);
        Push(ArrayValue(V, Op));
      end;
    $36..$3A:
      LocalStore(U1, Op - $36);
    $3B..$4E:
      LocalStore((Op - $3B) mod 4, (Op - $3B) div 4);
    $4F..$56:
      begin
        V := Pop;
        Take(TVKind.Int);
        A := Take(TVKind.Reference);
        Expected := ArrayValue(A, Op);
        if Op = $53 then
        begin
          if not (V.Kind in [TVKind.Reference, TVKind.Null]) then
            Fail('aastore requires an initialized reference');
        end
        else
          Expect(V, Expected);
      end;
    $57:
      Category1(Pop);
    $58:
      begin
        V := Pop;
        if V.Width = 1 then
        begin
          Category1(V);
          Category1(Pop);
        end;
      end;
    $59:
      begin
        V := Pop;
        Category1(V);
        Push(V);
        Push(V);
      end;
    $5A:
      begin
        V := Pop;
        W := Pop;
        Category1(V);
        Category1(W);
        Push(V);
        Push(W);
        Push(V);
      end;
    $5B:
      begin
        V := Pop;
        W := Pop;
        Category1(V);
        if W.Width = 2 then
        begin
          Push(V);
          Push(W);
          Push(V);
        end
        else
        begin
          Category1(W);
          A := Pop;
          Category1(A);
          Push(V);
          Push(A);
          Push(W);
          Push(V);
        end;
      end;
    $5C:
      begin
        V := Pop;
        if V.Width = 2 then
        begin
          Push(V);
          Push(V);
        end
        else
        begin
          Category1(V);
          W := Pop;
          Category1(W);
          Push(W);
          Push(V);
          Push(W);
          Push(V);
        end;
      end;
    $5D:
      begin
        V := Pop;
        W := Pop;
        if V.Width = 2 then
        begin
          Category1(W);
          Push(V);
          Push(W);
          Push(V);
        end
        else
        begin
          Category1(V);
          Category1(W);
          A := Pop;
          Category1(A);
          Push(W);
          Push(V);
          Push(A);
          Push(W);
          Push(V);
        end;
      end;
    $5E:
      begin
        V := Pop;
        W := Pop;
        if V.Width = 2 then
        begin
          if W.Width = 2 then
          begin
            Push(V);
            Push(W);
            Push(V);
          end
          else
          begin
            Category1(W);
            A := Pop;
            Category1(A);
            Push(V);
            Push(A);
            Push(W);
            Push(V);
          end;
        end
        else
        begin
          Category1(V);
          Category1(W);
          A := Pop;
          if A.Width = 2 then
          begin
            Push(W);
            Push(V);
            Push(A);
            Push(W);
            Push(V);
          end
          else
          begin
            Category1(A);
            B := Pop;
            Category1(B);
            Push(W);
            Push(V);
            Push(B);
            Push(A);
            Push(W);
            Push(V);
          end;
        end;
      end;
    $5F:
      begin
        V := Pop;
        W := Pop;
        Category1(V);
        Category1(W);
        Push(V);
        Push(W);
      end;
    $60..$73:
      begin
        I := (Op - $60) mod 4;
        Take(Kinds[I]);
        Take(Kinds[I]);
        Push(TVType.Make(Kinds[I]));
      end;
    $74..$77:
      begin
        I := Op - $74;
        Take(Kinds[I]);
        Push(TVType.Make(Kinds[I]));
      end;
    $78..$7D:
      begin
        Take(TVKind.Int);
        if (Op and 1) = 0 then
          I := 0
        else
          I := 1;
        Take(Kinds[I]);
        Push(TVType.Make(Kinds[I]));
      end;
    $7E..$83:
      begin
        I := Op and 1;
        Take(Kinds[I]);
        Take(Kinds[I]);
        Push(TVType.Make(Kinds[I]));
      end;
    $84:
      begin
        Index := U1;
        U1;
        Increment(Index);
      end;
    $85..$93:
      begin
        case Op of
          $85..$87:
            I := 0;
          $88..$8A:
            I := 1;
          $8B..$8D:
            I := 2;
          $8E..$90:
            I := 3;
        else
          I := 0;
        end;
        Take(Kinds[I]);
        case Op of
          $85, $8C, $8F:
            I := 1;
          $86, $89, $90:
            I := 2;
          $87, $8A, $8D:
            I := 3;
        else
          I := 0;
        end;
        Push(TVType.Make(Kinds[I]));
      end;
    $94..$98:
      begin
        if Op = $94 then
          I := 1
        else if Op <= $96 then
          I := 2
        else
          I := 3;
        Take(Kinds[I]);
        Take(Kinds[I]);
        Push(TVType.Make(TVKind.Int));
      end;
    $99..$A6, $C6, $C7:
      begin
        if (Op >= $9F) and (Op <= $A4) then
        begin
          Take(TVKind.Int);
          Take(TVKind.Int);
        end
        else if Op in [$A5, $A6] then
        begin
          Take(TVKind.Reference);
          Take(TVKind.Reference);
        end
        else if Op >= $C6 then
          Take(TVKind.Reference)
        else
          Take(TVKind.Int);
        Offset := SmallInt(U2);
        Edge(Int64(FStart) + Offset);
      end;
    $A7:
      begin
        Offset := SmallInt(U2);
        Edge(Int64(FStart) + Offset);
        FallsThrough := False;
      end;
    $A8:
      begin
        Offset := SmallInt(U2);
        Jsr(FStart + Offset);
      end;
    $A9:
      Ret(U1);
    $AA, $AB:
      begin
        while (FPC and 3) <> 0 do
          U1;
        Take(TVKind.Int);
        Offset := S4;
        Edge(Int64(FStart) + Offset);
        if Op = $AA then
        begin
          LowKey := S4;
          HighKey := S4;
          Count := Integer(Int64(HighKey) - LowKey + 1);
          for I := 1 to Count do
          begin
            Offset := S4;
            Edge(Int64(FStart) + Offset);
          end;
        end
        else
        begin
          Count := S4;
          for I := 1 to Count do
          begin
            S4;
            Offset := S4;
            Edge(Int64(FStart) + Offset);
          end;
        end;
        FallsThrough := False;
      end;
    $AC..$B1:
      begin
        if Op = $B1 then
        begin
          if FMethod.Signature.ReturnType <> 'V' then
            Fail('Void return in non-void method');
          if FFrame.ThisPending then
            Fail('Constructor returns before initialization of this');
        end
        else
        begin
          if FMethod.Signature.ReturnType = 'V' then
            Fail('Value return in void method');
          I := Op - $AC;
          V := Take(Kinds[I]);
          Expect(V, FromDescriptor(FMethod.Signature.ReturnType));
        end;
        FallsThrough := False;
      end;
    $B2..$B5:
      begin
        Index := U2;
        FMethod.Owner.Constant(Index, 9);
        FMethod.Owner.MemberRef(Index, ClassName, Name, Descriptor);
        Expected := FromDescriptor(Descriptor);
        if Op in [$B3, $B5] then
          Expect(Pop, Expected);
        if Op in [$B4, $B5] then
        begin
          V := Take(TVKind.Reference, Op = $B5);
          if V.Kind = TVKind.UninitializedThis then
          begin
            if ClassName <> FMethod.Owner.Name then
              Fail('putfield on uninitialized this must name its own class');
            Found := False;
            for var Field in FMethod.Owner.Fields do
              Found := Found or ((Field.Name = Name) and (Field.Descriptor = Descriptor));
            if not Found then
              Fail('putfield on uninitialized this must refer to a declared field');
          end
          else
          begin
            Expect(V, Reference(ClassName));
            ProtectedReceiver(ClassName, Name, Descriptor, V, True);
          end;
        end;
        if Op in [$B2, $B4] then
          Push(Expected);
      end;
    $B6..$B9:
      begin
        Index := U2;
        if Op = $B9 then
          FMethod.Owner.Constant(Index, 11)
        else
          FMethod.Owner.Constant(Index, 10);
        FMethod.Owner.MemberRef(Index, ClassName, Name, Descriptor);
        Signature := JVMMethodType(Descriptor);
        if Op = $B9 then
        begin
          I := U1;
          J := U1;
          if (I <> Signature.ArgumentSlots + 1) or (J <> 0) then
            Fail('Incorrect invokeinterface count');
        end;
        for I := High(Signature.Arguments) downto 0 do
          Expect(Pop, FromDescriptor(Signature.Arguments[I]));
        if Op <> $B8 then
        begin
          V := Take(TVKind.Reference, (Op = $B7) and (Name = '<init>'));
          if Name = '<init>' then
          begin
            if (Op <> $B7) or (Signature.ReturnType <> 'V') then
              Fail('Invalid initializer invocation');
            if V.Kind = TVKind.UninitializedThis then
            begin
              if (ClassName <> FMethod.Owner.Name) and (ClassName <> FMethod.Owner.SuperName) then
                Fail('Constructor calls unrelated initializer');
              InitializeAliases(V, FMethod.Owner.Name);
            end
            else if V.Kind = TVKind.Uninitialized then
            begin
              if V.Name <> ClassName then
                Fail('new and constructor class do not match');
              InitializeAliases(V, V.Name);
            end
            else
              Fail('Constructor receiver is already initialized');
          end
          else
          begin
            if Op = $B7 then
            begin
              if not StrictAssignable(FMethod.Owner.Name, ClassName) then
                Fail('invokespecial names an unrelated class');
              Expect(V, Reference(FMethod.Owner.Name));
            end
            else
              Expect(V, Reference(ClassName));
            if Op in [$B6, $B7] then
              ProtectedReceiver(ClassName, Name, Descriptor, V, False);
          end;
        end
        else if Name = '<init>' then
          Fail('Static constructor invocation');
        if Signature.ReturnType <> 'V' then
          Push(FromDescriptor(Signature.ReturnType));
      end;
    $BB:
      begin
        ClassName := FMethod.Owner.ClassName(U2);
        JVMClassName(ClassName, False);
        V := TVType.Make(TVKind.Uninitialized, ClassName, FStart);
        for A in FFrame.Stack do
          if A.Same(V) then
            Fail('Repeated new with a live uninitialized stack alias');
        for I := 0 to High(FFrame.Locals) do
          if FFrame.Locals[I].Same(V) then
            FFrame.Locals[I] := TVType.Make(TVKind.Top);
        Push(V);
      end;
    $BC, $BD:
      begin
        if Op = $BC then
        begin
          case U1 of
            4:
              Descriptor := '[Z';
            5:
              Descriptor := '[C';
            6:
              Descriptor := '[F';
            7:
              Descriptor := '[D';
            8:
              Descriptor := '[B';
            9:
              Descriptor := '[S';
            10:
              Descriptor := '[I';
            11:
              Descriptor := '[J';
          else
            Fail('Invalid newarray type');
          end;
        end
        else
        begin
          ClassName := FMethod.Owner.ClassName(U2);
          if ClassName.StartsWith('[') then
            Descriptor := '[' + ClassName
          else
            Descriptor := '[L' + ClassName + ';';
          JVMFieldType(Descriptor);
        end;
        Take(TVKind.Int);
        Push(Reference(Descriptor));
      end;
    $BE:
      begin
        V := Take(TVKind.Reference);
        if (V.Kind <> TVKind.Null) and not V.Name.StartsWith('[') then
          Fail('arraylength on non-array');
        Push(TVType.Make(TVKind.Int));
      end;
    $BF:
      begin
        Expect(Take(TVKind.Reference), Reference('java/lang/Throwable'));
        FallsThrough := False;
      end;
    $C0, $C1:
      begin
        ClassName := FMethod.Owner.ClassName(U2);
        Take(TVKind.Reference);
        if Op = $C0 then
          Push(Reference(ClassName))
        else
          Push(TVType.Make(TVKind.Int));
      end;
    $C2, $C3:
      Take(TVKind.Reference);
    $C4:
      begin
        SubOp := U1;
        Index := U2;
        case SubOp of
          $15..$19:
            LocalLoad(Index, SubOp - $15);
          $36..$3A:
            LocalStore(Index, SubOp - $36);
          $84:
            begin
              U2;
              Increment(Index);
            end;
          $A9:
            Ret(Index);
        else
          Fail('Invalid wide opcode');
        end;
      end;
    $C5:
      begin
        ClassName := FMethod.Owner.ClassName(U2);
        Count := U1;
        I := 1;
        while (I <= Length(ClassName)) and (ClassName[I] = '[') do
          Inc(I);
        if (Count < 1) or (Count >= I) then
          Fail('Invalid multianewarray dimension count');
        for J := 1 to Count do
          Take(TVKind.Int);
        Push(Reference(ClassName));
      end;
    $C8:
      begin
        Offset := S4;
        Edge(Int64(FStart) + Offset);
        FallsThrough := False;
      end;
    $C9:
      begin
        Offset := S4;
        Jsr(FStart + Offset);
      end;
  else
    Fail('Unsupported instruction in verifier');
  end;
  if FallsThrough then
    Flow(FPC, FFrame);
end;

procedure TVChecker.RequireMap(PC: Integer);
begin
  if (FMethod.Owner.Major >= 51) and (PC <> 0) and not FMaps.ContainsKey(PC) then
    Fail('Missing StackMapTable frame at control-flow target');
end;

procedure TVChecker.StaticInstructions;
var
  Op: Byte;
  I, Index, NextPC: Integer;
  CP: TJVMConstant;
  C, N, D: string;
begin
  for I := 0 to High(FMethod.Code) do
    if FMethod.InstructionStarts[I] then
    begin
      FStart := I;
      FPC := I + 1;
      Op := FMethod.Code[I];
      case Op of
        $12..$14:
          begin
            if Op = $12 then
              Index := U1
            else
              Index := U2;
            CP := FMethod.Owner.Constant(Index);
            if Op = $14 then
            begin
              if not (CP.Tag in [5, 6]) then
                Fail('ldc2_w requires long/double');
            end
            else if not (CP.Tag in [3, 4, 7, 8]) then
              Fail('Invalid ldc constant');
            if (CP.Tag = 7) and (FMethod.Owner.Major <> 0) and (FMethod.Owner.Major < 49) then
              Fail('Class literal requires class version 49');
          end;
        $B2..$B5:
          FMethod.Owner.Constant(U2, 9);
        $B6..$B9:
          begin
            Index := U2;
            if Op = $B9 then
              FMethod.Owner.Constant(Index, 11)
            else
              FMethod.Owner.Constant(Index, 10);
            FMethod.Owner.MemberRef(Index, C, N, D);
            if (N = '<init>') and (Op <> $B7) then
              Fail('Initializer requires invokespecial');
            if Op = $B9 then
            begin
              Index := U1;
              if (Index <> JVMMethodType(D).ArgumentSlots + 1) or (U1 <> 0) then
                Fail('Invalid invokeinterface operands');
            end;
          end;
        $BB, $BD, $C0, $C1, $C5:
          begin
            C := FMethod.Owner.ClassName(U2);
            JVMClassName(C, Op <> $BB);
            if Op = $C5 then
            begin
              Index := U1;
              NextPC := 1;
              while (NextPC <= Length(C)) and (C[NextPC] = '[') do
                Inc(NextPC);
              if (Index = 0) or (Index >= NextPC) then
                Fail('Invalid multianewarray type');
            end;
          end;
        $BC:
          begin
            Index := U1;
            if (Index < 4) or (Index > 11) then
              Fail('Invalid newarray atype');
          end;
        $A8, $A9, $C9:
          if FMethod.Owner.Major >= 51 then
            Fail('Legacy subroutine in class version 51');
        $BA:
          raise EJVMUnsupported.Create('invokedynamic verification is not implemented');
      end;
      if (FMethod.Owner.Major >= 51) and (Op in [$A7, $AA, $AB, $AC..$B1, $BF, $C8]) then
      begin
        NextPC := I + 1;
        while (NextPC < Length(FMethod.Code)) and not FMethod.InstructionStarts[NextPC] do
          Inc(NextPC);
        if NextPC < Length(FMethod.Code) then
          RequireMap(NextPC);
      end;
    end;
end;

procedure TVChecker.Run;
var
  Initial, Before, State: TVFrame;
  StateKey: string;
begin
  if (FMethod.Access and (JVM_ACC_NATIVE or JVM_ACC_ABSTRACT)) <> 0 then
    Exit;
  if Length(FMethod.Code) = 0 then
    Fail('Empty method code');
  FMethod.InstructionStarts := JVMInstructionMap(FMethod.Code, FMethod.MaxLocals);
  for var H in FMethod.Handlers do
    if (H.CatchType <> 0) and not StrictAssignable(FMethod.Owner.ClassName(H.CatchType), 'java/lang/Throwable') then
      Fail('Exception handler type is not Throwable');
  ReadMaps;
  StaticInstructions;
  Initial := InitialFrame;
  try
    Flow(0, Initial);
  finally
    Initial.Free;
  end;
  // Declared stack-map blocks must be type safe even when entry flow cannot reach them.
  for State in FMaps.Values do
  begin
    Initial := State.Clone;
    try
      for var Value in Initial.Locals do
        if Value.Kind = TVKind.UninitializedThis then
          Initial.ThisPending := True;
      Flow(State.PC, Initial);
    finally
      Initial.Free;
    end;
  end;
  while FQueue.Count <> 0 do
  begin
    StateKey := FQueue.Dequeue;
    State := FStates[StateKey];
    State.Queued := False;
    FFrame.Free;
    FFrame := State.Clone;
    Before := FFrame.Clone;
    try
      FPC := FFrame.PC;
      FStart := FPC;
      FHasConstructorToken := False;
      Instruction;
      ExceptionEdges(Before);
    finally
      Before.Free;
    end;
  end;
end;

procedure JVMVerifyMethod(Method: TJVMMethod; const Resolve: TJVMVerificationResolver);
var
  Checker: TVChecker;
begin
  Checker := TVChecker.Create(Method, Resolve);
  try
    try
      Checker.Run;
    except
      on E: EJVMFormatError do
        Checker.Fail(E.Message);
    end;
  finally
    Checker.Free;
  end;
end;

end.

