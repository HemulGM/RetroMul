unit JVM.Runtime;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile,
  JVM.Threading, JVM.Linker;

{$SCOPEDENUMS ON}

type
  TJVM = class;

  TJVMHost = class
  public
    function LoadClass(const Name: string): TBytes; virtual; abstract;
    function InvokeNative(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>): TJVMValue; virtual; abstract;
    function TimeMillis: Int64; virtual; abstract;
    function MonotonicMillis: Int64; virtual; abstract;
  end;

  TJVMState = (Idle, Running, Completed, Stopped, Faulted);

  TJVMHeapMemory = record
    UsedBytes, CapacityBytes: Int64;
  end;

  TJVMExecutionContext = class
  public
    Thread: TJVMThreadContext;
    State: TJVMState;
    Value: TJVMValue;
    Error: string;
    ExceptionRef: Integer;
  end;

  TJVMObject = class
  public
    ClassName, Text, ThrowableTrace: string;
    HasThrowableTrace: Boolean;
    Fields: TDictionary<string, TJVMValue>;
    Elements: TArray<TJVMValue>;
    IsArray, Marked: Boolean;
    constructor Create(const Name: string);
    destructor Destroy; override;
  end;

  TJVMFrame = class
  public
    Method: TJVMMethod;
    Locals, Stack: TArray<TJVMValue>;
    PC, InstructionPC, SP, StackSlots: Integer;
    Initializing: TJVMClass;
    NativeArguments: TArray<TJVMValue>;
    NativeResult, NativeContinuation, NativeGuestResult: TJVMValue;
    NativeEntered, NativeRetry, NativeAwaitingGuest, NativeGuestReady, DeadlineSet: Boolean;
    NativeDeadline: Int64;
    NativeInterruptClass: string;
    NativeRetryInterrupted: Boolean;
    SyncMonitor: Integer;
    SyncAcquired: Boolean;
    EntryInitialization: TJVMClass;
    InitPhase: Integer;
    procedure Push(const V: TJVMValue);
    function Pop: TJVMValue;
    function U1: Byte;
    function U2: Word;
    function S2: SmallInt;
    function S4: Integer;
    procedure Jump(Target: Int64);
    procedure Store(Index: Integer; const V: TJVMValue);
    function Load(Index: Integer): TJVMValue;
  end;

  EJVMThrown = class(EJVMError)
  public
    Reference: Integer;
    constructor Create(Ref: Integer);
  end;

  TJVM = class
  private
    FHost: TJVMHost; // Borrowed. Must outlive this VM.
    FClasses: TObjectDictionary<string, TJVMClass>;
    FLinker: TJVMClassLinker;
    FHeap: TObjectDictionary<Integer, TJVMObject>;
    FRoots: TDictionary<Integer, Integer>;
    FInterned: TDictionary<string, Integer>;
    FClassObjects: TDictionary<string, Integer>;
    FScheduler: TJVMScheduler;
    FMainThread, FCurrent: TJVMThreadContext;
    FThreadFrames: TObjectDictionary<Integer, TObjectList<TJVMFrame>>;
    FThreadErrors: TQueue<string>;
    FExceptionDiagnostics: TQueue<string>;
    FTraceExceptionDiagnostics: Boolean;
    FExceptionDiagnosticsDropped: UInt64;
    FContexts: TObjectDictionary<Integer, TJVMExecutionContext>;
    FFrames: TObjectList<TJVMFrame>;
    FNow: Int64;
    FNextRef, FNextGC, FMaxObjects, FMaxArrayLength, FQuantumScale: Integer;
    FStopRequested: Integer;
    FExitRequested: Boolean;
    FExitStatus: Integer;
    FHeapCapacity: Int64;
    FYieldToHost: Boolean;
    FState: TJVMState;
    FResult: TJVMValue;
    FError: string;
    FOutputData, FOutputChannels: TBytes;
    FOutputHead, FOutputCount: Integer;
    FOutputDropped: UInt64;
    FInstructions: UInt64;
    function Allocate(Obj: TJVMObject): Integer;
    procedure Mark(Ref: Integer; Pending: TList<Integer>);
    function ResolveField(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass): TJVMField;
    procedure PushCall(M: TJVMMethod; const Args: TArray<TJVMValue>);
    procedure ReturnFromCall(const Value: TJVMValue; HasValue: Boolean);
    function InitializeClass(C: TJVMClass): Boolean;
    procedure DispatchException(Ref: Integer);
    procedure Step;
    function ConstantValue(C: TJVMClass; Index: Integer): TJVMValue;
    function FieldKey(C: TJVMClass; F: TJVMField): string;
    function ArrayObject(Ref, Index: Integer): TJVMObject;
    procedure CheckValue(const Value: TJVMValue; const Descriptor: string);
    function FramesFor(Thread: TJVMThreadContext): TObjectList<TJVMFrame>;
    procedure ReleaseFrameMonitor(Frame: TJVMFrame);
    procedure InitializeStep(Frame: TJVMFrame);
    procedure VerifyClass(C: TJVMClass);
    procedure StopExecution;
  public
    constructor Create(Host: TJVMHost);
    destructor Destroy; override;
    procedure DefineClass(C: TJVMClass); // Takes ownership on success.
    function LoadClass(const Name: string): TJVMClass;
    function ResolveMethod(C: TJVMClass; const Name, Descriptor: string): TJVMMethod;
    function ResolveVirtualMethod(Receiver: Integer; Declaration: TJVMMethod): TJVMMethod;
    function IsAssignable(const Actual, Expected: string): Boolean;
    function NewObject(const ClassName: string): Integer;
    function NewArray(const Descriptor: string; Count: Integer): Integer;
    function InternString(const Value: string): Integer;
    function NewString(const Value: string): Integer;
    function CloneObject(Ref: Integer): Integer;
    function GetObject(Ref: Integer): TJVMObject;
    procedure AddRoot(Ref: Integer);
    procedure RemoveRoot(Ref: Integer);
    procedure CollectGarbage;
    procedure CaptureThrowableTrace(Ref: Integer; SkipConstructors: Boolean = False);
    procedure QueueOutput(const Data: TBytes; StandardError: Boolean);
    function TakeOutput(out Data: TBytes; out StandardError: Boolean): Boolean;
    property OutputDropped: UInt64 read FOutputDropped;
    procedure RaiseJava(const ClassName: string; const Message: string = '');
    procedure BeginCall(const ClassName, Name, Descriptor: string; const Arguments: array of TJVMValue);
    function CreateExecutionContext: Integer;
    procedure BeginContextCall(Context: Integer; const ClassName, Name, Descriptor: string; const Arguments: array of TJVMValue);
    function ExecutionContextState(Context: Integer): TJVMState;
    function ExecutionContextResult(Context: Integer): TJVMValue;
    function ExecutionContextError(Context: Integer): string;
    function Execute(Budget: Integer): TJVMState;
    procedure RequestStop;
    function StopRequested: Boolean; // Thread-safe query for cancellable host waits.
    procedure ExitApplication(Status: Integer); // Guest-native call; never returns.
    property ExitRequested: Boolean read FExitRequested;
    property ExitStatus: Integer read FExitStatus;
    function HeapMemory: TJVMHeapMemory;
    function HasRunnableWork: Boolean; // Pure scheduler query; does not advance time.
    function DescribeThreads(IncludeLocals: Boolean = False): string; // Read-only, on the VM executor.
    function ClassObject(const Name: string): Integer;
    function CurrentJavaThread: Integer;
    procedure InitializeJavaThread(Ref, Target: Integer; const Name: string);
    function JavaThread(Ref: Integer): TJVMThreadContext;
    procedure StartJavaThread(Ref: Integer);
    // RetryInterrupted leaves the interrupt visible to ClearInterrupted when
    // RetryNative resumes, so an embedder can cancel work and report progress.
    procedure SleepCurrent(Timeout: Int64; const InterruptedClass: string = 'java/lang/InterruptedException'; RetryInterrupted: Boolean = False);
    procedure WaitCurrent(Ref: Integer; Timeout: Int64);
    procedure NotifyCurrent(Ref: Integer; All: Boolean);
    procedure JoinJavaThread(Ref: Integer; Timeout: Int64);
    procedure InterruptJavaThread(Ref: Integer);
    procedure YieldCurrent;
    procedure YieldToHost;
    function ClearInterrupted: Boolean;
    function EnterMonitor(Ref: Integer): Boolean;
    procedure ExitMonitor(Ref: Integer);
    procedure InvokeGuest(Method: TJVMMethod; const Arguments: array of TJVMValue);
    procedure InvokeGuestResult(Method: TJVMMethod; const Arguments: array of TJVMValue);
    function TakeGuestResult(out Value: TJVMValue): Boolean;
    function NativeContinuation: TJVMValue;
    // Embedders can promptly retire a polled operation after its native call
    // unwinds (exception, interrupt or stop), without waiting for heap GC.
    function HasNativeContinuation(Ref: Integer): Boolean;
    procedure SetNativeContinuation(const Value: TJVMValue);
    procedure RetryNative;
    // Native library calls may trigger ordinary resumable class initialization.
    // A false return schedules/retries the current native frame after it finishes.
    function InitializeNativeClass(C: TJVMClass): Boolean;
    function NativeCallerClass: TJVMClass;
    procedure CheckNativeAccess(Owner: TJVMClass; Flags: Word);
    function TakeThreadError: string;
    function TakeExceptionDiagnostic(out Diagnostic: string): Boolean;
    property TraceExceptionDiagnostics: Boolean read FTraceExceptionDiagnostics write FTraceExceptionDiagnostics;
    property ExceptionDiagnosticsDropped: UInt64 read FExceptionDiagnosticsDropped;
    property Scheduler: TJVMScheduler read FScheduler;
    property CurrentThread: TJVMThreadContext read FCurrent;
    property Host: TJVMHost read FHost;
    property State: TJVMState read FState;
    property ReturnValue: TJVMValue read FResult;
    property Error: string read FError;
    property Instructions: UInt64 read FInstructions;
    property MaxObjects: Integer read FMaxObjects write FMaxObjects;
    property MaxArrayLength: Integer read FMaxArrayLength write FMaxArrayLength;
    property QuantumScale: Integer read FQuantumScale write FQuantumScale;
    function HeapCount: Integer;
    function IsObjectAlive(Reference: Integer): Boolean;
  end;

implementation

uses
  System.Math, System.SyncObjs, JVM.Verifier;

// Java integer arithmetic wraps. Guest indices and lengths are checked explicitly.
{$Q-}{$R-}

type
  EJVMExitSignal = class(Exception);

constructor TJVMObject.Create(const Name: string);
begin
  inherited Create;
  ClassName := Name;
  Fields := TDictionary<string, TJVMValue>.Create;
end;

destructor TJVMObject.Destroy;
begin
  Fields.Free;
  inherited;
end;

constructor EJVMThrown.Create(Ref: Integer);
begin
  inherited Create('Java exception');
  Reference := Ref;
end;

procedure TJVMFrame.Push(const V: TJVMValue);
begin
  if (SP >= Length(Stack)) or (StackSlots + V.Slots > Method.MaxStack) then
    raise EJVMFormatError.Create('Operand stack overflow');
  Stack[SP] := V;
  Inc(SP);
  Inc(StackSlots, V.Slots);
end;

function TJVMFrame.Pop: TJVMValue;
begin
  if SP = 0 then
    raise EJVMFormatError.Create('Operand stack underflow');
  Dec(SP);
  Result := Stack[SP];
  Stack[SP] := Default(TJVMValue);
  Dec(StackSlots, Result.Slots);
end;

function TJVMFrame.U1: Byte;
begin
  if (PC < 0) or (PC >= Length(Method.Code)) then
    raise EJVMFormatError.Create('Bytecode outside method');
  Result := Method.Code[PC];
  Inc(PC);
end;

function TJVMFrame.U2: Word;
var
  A: Byte;
begin
  A := U1;
  Result := (Word(A) shl 8) or U1;
end;

function TJVMFrame.S2: SmallInt;
begin
  Result := SmallInt(U2);
end;

function TJVMFrame.S4: Integer;
var
  A: Word;
begin
  A := U2;
  Result := Integer((UInt32(A) shl 16) or U2);
end;

procedure TJVMFrame.Jump(Target: Int64);
begin
  if (Target < 0) or (Target >= Length(Method.Code)) then
    raise EJVMFormatError.Create('Branch outside method');
  if not Method.InstructionStarts[Integer(Target)] then
    raise EJVMFormatError.Create('Branch enters an instruction operand');
  PC := Integer(Target);
end;

procedure TJVMFrame.Store(Index: Integer; const V: TJVMValue);
begin
  if (Index < 0) or (Index > Length(Locals) - V.Slots) then
    raise EJVMFormatError.Create('Local variable outside frame');
  if (Index > 0) and (Locals[Index - 1].Slots = 2) then
    Locals[Index - 1] := Default(TJVMValue);
  Locals[Index] := V;
  if V.Slots = 2 then
    Locals[Index + 1] := Default(TJVMValue);
end;

function TJVMFrame.Load(Index: Integer): TJVMValue;
begin
  if (Index < 0) or (Index >= Length(Locals)) then
    raise EJVMFormatError.Create('Local variable outside frame');
  Result := Locals[Index];
  if Result.Kind = TJVMKind.Empty then
    raise EJVMFormatError.Create('Uninitialized local variable');
end;

constructor TJVM.Create(Host: TJVMHost);
begin
  inherited Create;
  if Host = nil then
    raise EJVMError.Create('JVM host is required');
  FHost := Host;
  FClasses := TObjectDictionary<string, TJVMClass>.Create([doOwnsValues]);
  FLinker := TJVMClassLinker.Create(
    function(const Name: string): TJVMClass
    begin
      Result := LoadClass(Name);
    end);
  FHeap := TObjectDictionary<Integer, TJVMObject>.Create([doOwnsValues]);
  FRoots := TDictionary<Integer, Integer>.Create;
  FInterned := TDictionary<string, Integer>.Create;
  FClassObjects := TDictionary<string, Integer>.Create;
  FScheduler := TJVMScheduler.Create;
  FThreadFrames := TObjectDictionary<Integer, TObjectList<TJVMFrame>>.Create([doOwnsValues]);
  FThreadErrors := TQueue<string>.Create;
  FExceptionDiagnostics := TQueue<string>.Create;
  FContexts := TObjectDictionary<Integer, TJVMExecutionContext>.Create([doOwnsValues]);
  FMainThread := FScheduler.NewThread;
  FMainThread.State := TJVMThreadState.Idle;
  FCurrent := FMainThread;
  FFrames := FramesFor(FCurrent);
  FNextRef := 1;
  FNextGC := 1024;
  FMaxObjects := 65536;
  FMaxArrayLength := 1024 * 1024;
  FQuantumScale := 16;
  FHeapCapacity := 16 * 1024 * 1024;
end;

destructor TJVM.Destroy;
begin
  FExceptionDiagnostics.Free;
  FContexts.Free;
  FThreadErrors.Free;
  FThreadFrames.Free;
  FScheduler.Free;
  FClassObjects.Free;
  FInterned.Free;
  FRoots.Free;
  FHeap.Free;
  FLinker.Free;
  FClasses.Free;
  inherited;
end;

function TJVM.FramesFor(Thread: TJVMThreadContext): TObjectList<TJVMFrame>;
begin
  if not FThreadFrames.TryGetValue(Thread.ID, Result) then
  begin
    Result := TObjectList<TJVMFrame>.Create(True);
    FThreadFrames.Add(Thread.ID, Result);
  end;
end;

function TJVM.ClassObject(const Name: string): Integer;
begin
  if FClassObjects.TryGetValue(Name, Result) then
    Exit;
  FLinker.ResolveClass(Name);
  Result := NewObject('java/lang/Class');
  GetObject(Result).Text := Name;
  FClassObjects.Add(Name, Result);
end;

function TJVM.CurrentJavaThread: Integer;
begin
  if FCurrent.JavaObject = 0 then
  begin
    FCurrent.JavaObject := NewObject('java/lang/Thread');
    GetObject(FCurrent.JavaObject).Text := 'Host';
  end;
  Result := FCurrent.JavaObject;
end;

function TJVM.JavaThread(Ref: Integer): TJVMThreadContext;
begin
  if not IsAssignable(GetObject(Ref).ClassName, 'java/lang/Thread') then
    raise EJVMFormatError.Create('Expected Java Thread');
  Result := FScheduler.ThreadForObject(Ref);
  if Result = nil then
    RaiseJava('java/lang/IllegalThreadStateException', 'Uninitialized Thread');
end;

procedure TJVM.InitializeJavaThread(Ref, Target: Integer; const Name: string);
var
  Thread: TJVMThreadContext;
begin
  if FScheduler.ThreadForObject(Ref) <> nil then
    RaiseJava('java/lang/IllegalThreadStateException');
  Thread := FScheduler.NewThread;
  Thread.JavaObject := Ref;
  Thread.Target := Target;
  Thread.Priority := FCurrent.Priority;
  GetObject(Ref).Fields.AddOrSetValue('$target', TJVMValue.Ref(Target));
  GetObject(Ref).Text := Name;
end;

procedure TJVM.StartJavaThread(Ref: Integer);
var
  Thread, Previous: TJVMThreadContext;
  M: TJVMMethod;
begin
  Thread := JavaThread(Ref);
  if Thread.State <> TJVMThreadState.New then
    RaiseJava('java/lang/IllegalThreadStateException');
  if FScheduler.LiveCount >= 256 then
    RaiseJava('java/lang/OutOfMemoryError', 'Java thread limit');
  M := ResolveMethod(LoadClass(GetObject(Ref).ClassName), 'run', '()V');
  Previous := FCurrent;
  try
    FCurrent := Thread;
    FFrames := FramesFor(Thread);
    Thread.State := TJVMThreadState.Runnable;
    PushCall(M, TArray<TJVMValue>.Create(TJVMValue.Ref(Ref)));
    FFrames.Last.EntryInitialization := M.Owner;
  finally
    FCurrent := Previous;
    FFrames := FramesFor(Previous);
  end;
end;

procedure TJVM.YieldCurrent;
begin
  FCurrent.Quantum := 0;
end;

function TJVM.ClearInterrupted: Boolean;
begin
  Result := FCurrent.Interrupted;
  FCurrent.Interrupted := False;
end;

procedure TJVM.SleepCurrent(Timeout: Int64; const InterruptedClass: string; RetryInterrupted: Boolean);
begin
  if Timeout < 0 then
    RaiseJava('java/lang/IllegalArgumentException', 'Negative sleep timeout');
  if not RetryInterrupted and ClearInterrupted then
    RaiseJava(InterruptedClass);
  if FFrames.Count <> 0 then
  begin
    FFrames.Last.NativeInterruptClass := InterruptedClass;
    FFrames.Last.NativeRetryInterrupted := RetryInterrupted;
  end;
  YieldCurrent;
  if Timeout = 0 then
    Exit;
  FCurrent.State := TJVMThreadState.Sleeping;
  FCurrent.WakeAt := JVMDeadline(FNow, Timeout);
end;

function TJVM.EnterMonitor(Ref: Integer): Boolean;
begin
  GetObject(Ref);
  Result := FScheduler.Enter(FCurrent, Ref);
end;

procedure TJVM.ExitMonitor(Ref: Integer);
begin
  GetObject(Ref);
  if not FScheduler.ExitMonitor(FCurrent, Ref) then
    RaiseJava('java/lang/IllegalMonitorStateException');
end;

procedure TJVM.WaitCurrent(Ref: Integer; Timeout: Int64);
begin
  GetObject(Ref);
  if Timeout < 0 then
    RaiseJava('java/lang/IllegalArgumentException', 'Negative wait timeout');
  if not FScheduler.OwnsMonitor(FCurrent, Ref) then
    RaiseJava('java/lang/IllegalMonitorStateException');
  if ClearInterrupted then
    RaiseJava('java/lang/InterruptedException');
  FScheduler.Wait(FCurrent, Ref, Timeout, FNow);
end;

procedure TJVM.NotifyCurrent(Ref: Integer; All: Boolean);
begin
  GetObject(Ref);
  if not FScheduler.OwnsMonitor(FCurrent, Ref) then
    RaiseJava('java/lang/IllegalMonitorStateException');
  FScheduler.Notify(Ref, All);
end;

procedure TJVM.JoinJavaThread(Ref: Integer; Timeout: Int64);
var
  Thread: TJVMThreadContext;
  Frame: TJVMFrame;
  Remaining: Int64;
begin
  if Timeout < 0 then
    RaiseJava('java/lang/IllegalArgumentException', 'Negative join timeout');
  Thread := JavaThread(Ref);
  if Thread.State in [TJVMThreadState.New, TJVMThreadState.Terminated] then
    Exit;
  Frame := FFrames.Last;
  if not Frame.DeadlineSet then
  begin
    Frame.DeadlineSet := True;
    if Timeout <> 0 then
      Frame.NativeDeadline := JVMDeadline(FNow, Timeout);
  end;
  Remaining := 0;
  if Frame.NativeDeadline <> 0 then
  begin
    Remaining := Frame.NativeDeadline - FNow;
    if Remaining <= 0 then
      Exit;
  end;
  Frame.NativeRetry := True;
  WaitCurrent(Ref, Remaining);
end;

procedure TJVM.InterruptJavaThread(Ref: Integer);
begin
  FScheduler.Interrupt(JavaThread(Ref));
end;

procedure TJVM.InvokeGuest(Method: TJVMMethod; const Arguments: array of TJVMValue);
var
  Args: TArray<TJVMValue>;
begin
  if Method.Signature.ReturnType <> 'V' then
    raise EJVMUnsupported.Create('Native guest callbacks currently require a void method');
  SetLength(Args, Length(Arguments));
  for var I := 0 to High(Args) do
    Args[I] := Arguments[I];
  PushCall(Method, Args);
end;

procedure TJVM.InvokeGuestResult(Method: TJVMMethod; const Arguments: array of TJVMValue);
var
  Frame: TJVMFrame;
  Args: TArray<TJVMValue>;
begin
  Frame := FFrames.Last;
  if (Frame.Method = nil) or ((Frame.Method.Access and JVM_ACC_NATIVE) = 0) or Frame.NativeAwaitingGuest or Frame.NativeGuestReady then
    raise EJVMError.Create('Invalid native guest-result call');
  SetLength(Args, Length(Arguments));
  for var I := 0 to High(Args) do
    Args[I] := Arguments[I];
  PushCall(Method, Args);
  Frame.NativeAwaitingGuest := True;
  Frame.NativeRetry := True;
end;

function TJVM.TakeGuestResult(out Value: TJVMValue): Boolean;
var
  Frame: TJVMFrame;
begin
  Frame := FFrames.Last;
  Result := Frame.NativeGuestReady;
  Value := Default(TJVMValue);
  if Result then
  begin
    Value := Frame.NativeGuestResult;
    Frame.NativeGuestResult := Default(TJVMValue);
    Frame.NativeGuestReady := False;
  end;
end;

function TJVM.NativeContinuation: TJVMValue;
begin
  Result := FFrames.Last.NativeContinuation;
end;

function TJVM.HasNativeContinuation(Ref: Integer): Boolean;
begin
  if Ref = 0 then
    Exit(False);
  for var Frames in FThreadFrames.Values do
    for var Frame in Frames do
      if (Frame.NativeContinuation.Kind = TJVMKind.Reference) and (Frame.NativeContinuation.AsRef = Ref) then
        Exit(True);
  Result := False;
end;

procedure TJVM.SetNativeContinuation(const Value: TJVMValue);
begin
  FFrames.Last.NativeContinuation := Value;
end;

procedure TJVM.RetryNative;
begin
  FFrames.Last.NativeRetry := True;
  YieldToHost;
end;

function TJVM.InitializeNativeClass(C: TJVMClass): Boolean;
var
  Frame: TJVMFrame;
begin
  Frame := FFrames.Last;
  if (Frame.Method = nil) or ((Frame.Method.Access and JVM_ACC_NATIVE) = 0) then
    raise EJVMError.Create('Class initialization requires an active native frame');
  Result := InitializeClass(C);
  if not Result then
    Frame.NativeRetry := True;
end;

function TJVM.NativeCallerClass: TJVMClass;
begin
  Result := nil;
  for var I := FFrames.Count - 2 downto 0 do
    if FFrames[I].Method <> nil then
      Exit(FFrames[I].Method.Owner);
end;

procedure TJVM.CheckNativeAccess(Owner: TJVMClass; Flags: Word);
begin
  var Caller := NativeCallerClass;
  FLinker.ClassAccess(Caller, Owner);
  FLinker.MemberAccess(Caller, Owner, Flags, Owner.Name);
end;

function TJVM.TakeThreadError: string;
begin
  if FThreadErrors.Count = 0 then
    Result := ''
  else
    Result := FThreadErrors.Dequeue;
end;

procedure TJVM.DefineClass(C: TJVMClass);
begin
  if (C = nil) or (C.Name = '') then
    raise EJVMError.Create('Unnamed Java class');
  if FClasses.ContainsKey(C.Name) then
    raise EJVMError.Create('Duplicate Java class: ' + C.Name);
  FClasses.Add(C.Name, C);
end;

function TJVM.LoadClass(const Name: string): TJVMClass;
var
  Data: TBytes;
  C: TJVMClass;
begin
  if FClasses.TryGetValue(Name, Result) then
  begin
    if Result.LinkState = 3 then
      FLinker.Link(Result);
    Exit;
  end;
  JVMClassName(Name, False);
  if FClasses.Count >= 8192 then
    raise EJVMError.Create('Class count limit exceeded');
  Data := FHost.LoadClass(Name);
  if Length(Data) = 0 then
    raise EJVMClassMissing.Create(Name);
  try
    C := TJVMClass.Parse(Data);
  except
    on E: EJVMFormatError do
      raise EJVMClassFormatError.Create(E.Message);
  end;
  try
    if C.Name <> Name then
      JVMLinkFailure('NoClassDefFoundError', 'Wrong class name: ' + C.Name + ', expected ' + Name);
    DefineClass(C);
    Result := C;
    C := nil;
    FLinker.Link(Result);
  finally
    C.Free;
  end;
end;

function TJVM.ResolveMethod(C: TJVMClass; const Name, Descriptor: string): TJVMMethod;
begin
  Result := FLinker.Method(C, Name, Descriptor);
end;

function TJVM.ResolveVirtualMethod(Receiver: Integer; Declaration: TJVMMethod): TJVMMethod;
begin
  if Declaration = nil then
    raise EJVMError.Create('Missing virtual declaration');
  if (Declaration.Access and JVM_ACC_STATIC) <> 0 then
    JVMLinkFailure('IncompatibleClassChangeError', 'Static virtual declaration');
  var O := GetObject(Receiver);
  if not IsAssignable(O.ClassName, Declaration.Owner.Name) then
    JVMLinkFailure('IncompatibleClassChangeError', 'Invalid virtual receiver');
  var C: TJVMClass;
  if O.IsArray then
    C := LoadClass('java/lang/Object')
  else
    C := LoadClass(O.ClassName);
  Result := FLinker.VirtualMethod(C, Declaration, (Declaration.Owner.Access and $0200) <> 0);
end;

function TJVM.IsAssignable(const Actual, Expected: string): Boolean;

  function Match(const A, E: string; Depth: Integer): Boolean;
  var
    C: TJVMClass;
    S, AC, EC: string;
  begin
    if Depth > 256 then
      raise EJVMFormatError.Create('Cyclic/deep type hierarchy');
    if A = E then
      Exit(True);
    if (A = '') or (E = '') then
      Exit(False);
    if A[1] = '[' then
    begin
      if (E = 'java/lang/Object') or (E = 'java/lang/Cloneable') or
        (E = 'java/io/Serializable') then
        Exit(True);
      if E[1] <> '[' then
        Exit(False);
      AC := Copy(A, 2, MaxInt);
      EC := Copy(E, 2, MaxInt);
      if (Length(AC) = 1) or (Length(EC) = 1) then
        Exit(AC = EC);
      if AC[1] = 'L' then
        AC := Copy(AC, 2, Length(AC) - 2);
      if EC[1] = 'L' then
        EC := Copy(EC, 2, Length(EC) - 2);
      Exit(Match(AC, EC, Depth + 1));
    end;
    if E[1] = '[' then
      Exit(False);
    C := LoadClass(A);
    for S in C.Interfaces do
      if Match(S, E, Depth + 1) then
        Exit(True);
    Result := (C.SuperName <> '') and Match(C.SuperName, E, Depth + 1);
  end;

begin
  Result := Match(Actual, Expected, 0);
end;

function TJVM.ResolveField(C: TJVMClass; const Name, Descriptor: string; out Owner: TJVMClass): TJVMField;
begin
  Result := FLinker.Field(C, Name, Descriptor, Owner);
end;

function TJVM.FieldKey(C: TJVMClass; F: TJVMField): string;
begin
  Result := C.Name + '.' + F.Name + ':' + F.Descriptor;
end;

function TJVM.Allocate(Obj: TJVMObject): Integer;
begin
  try
    if (FHeap.Count >= FMaxObjects) or (FNextRef = MaxInt) then
      raise EJVMError.Create('Java heap object limit exceeded');
    Result := FNextRef;
    FHeap.Add(Result, Obj);
    Inc(FNextRef);
    Obj := nil;
  finally
    Obj.Free;
  end;
end;

function TJVM.NewObject(const ClassName: string): Integer;
var
  C: TJVMClass;
  O: TJVMObject;
  F: TJVMField;
  Depth: Integer;
begin
  C := LoadClass(ClassName);
  FLinker.Link(C);
  if (C.Access and (JVM_ACC_ABSTRACT or $0200)) <> 0 then
    RaiseJava('java/lang/InstantiationError', ClassName);
  O := TJVMObject.Create(ClassName);
  try
    Depth := 0;
    while C <> nil do
    begin
      for F in C.Fields do
        if (F.Access and JVM_ACC_STATIC) = 0 then
          O.Fields.Add(FieldKey(C, F), JVMDefaultValue(F.Descriptor));
      if C.SuperName = '' then
        Break;
      C := LoadClass(C.SuperName);
      Inc(Depth);
      if Depth > 256 then
        raise EJVMFormatError.Create('Cyclic/deep object hierarchy');
    end;
  except
    O.Free;
    raise;
  end;
  Result := Allocate(O);
end;

function TJVM.NewArray(const Descriptor: string; Count: Integer): Integer;
var
  O: TJVMObject;
  I: Integer;
  V: TJVMValue;
begin
  JVMFieldType(Descriptor);
  if Descriptor[1] <> '[' then
    raise EJVMFormatError.Create('Expected array descriptor');
  if Count < 0 then
    RaiseJava('java/lang/NegativeArraySizeException');
  if Count > FMaxArrayLength then
    raise EJVMError.Create('Java array length limit exceeded');
  V := JVMDefaultValue(Copy(Descriptor, 2, MaxInt));
  O := TJVMObject.Create(Descriptor);
  try
    O.IsArray := True;
    SetLength(O.Elements, Count);
    for I := 0 to Count - 1 do
      O.Elements[I] := V;
  except
    O.Free;
    raise;
  end;
  Result := Allocate(O);
end;

function TJVM.InternString(const Value: string): Integer;
begin
  if FInterned.TryGetValue(Value, Result) then
    Exit;
  Result := NewString(Value);
  FInterned.Add(Value, Result);
end;

function TJVM.NewString(const Value: string): Integer;
var
  O: TJVMObject;
begin
  LoadClass('java/lang/String');
  O := TJVMObject.Create('java/lang/String');
  O.Text := Value;
  Result := Allocate(O);
end;

function TJVM.CloneObject(Ref: Integer): Integer;
var
  Source, CopyObject: TJVMObject;
begin
  Source := GetObject(Ref);
  if not Source.IsArray and not IsAssignable(Source.ClassName, 'java/lang/Cloneable') then
    RaiseJava('java/lang/CloneNotSupportedException');
  CopyObject := TJVMObject.Create(Source.ClassName);
  try
    CopyObject.IsArray := Source.IsArray;
    CopyObject.Text := Source.Text;
    CopyObject.ThrowableTrace := Source.ThrowableTrace;
    CopyObject.HasThrowableTrace := Source.HasThrowableTrace;
    CopyObject.Elements := Copy(Source.Elements);
    for var Pair in Source.Fields do
      CopyObject.Fields.Add(Pair.Key, Pair.Value);
  except
    CopyObject.Free;
    raise;
  end;
  Result := Allocate(CopyObject);
end;

function TJVM.GetObject(Ref: Integer): TJVMObject;
begin
  if Ref = 0 then
    RaiseJava('java/lang/NullPointerException');
  if not FHeap.TryGetValue(Ref, Result) then
    raise EJVMError.Create('Invalid Java object reference');
end;

function TJVM.ArrayObject(Ref, Index: Integer): TJVMObject;
begin
  Result := GetObject(Ref);
  if not Result.IsArray then
    raise EJVMFormatError.Create('Expected Java array');
  if (Index < 0) or (Index >= Length(Result.Elements)) then
    RaiseJava('java/lang/ArrayIndexOutOfBoundsException', 'Index ' + IntToStr(Index) + ' for length ' + IntToStr(Length(Result.Elements)));
end;

procedure TJVM.CheckValue(const Value: TJVMValue; const Descriptor: string);
var
  Expected: TJVMValue;
begin
  Expected := JVMDefaultValue(Descriptor);
  if Expected.Kind <> Value.Kind then
    raise EJVMFormatError.Create('Java value does not match descriptor ' + Descriptor);
  // Reference type safety is established by verification; interface receivers
  // are checked by invokeinterface. Embedders must supply compatible arguments.
  if (Value.Kind = TJVMKind.Reference) and (Value.AsRef <> 0) then
    GetObject(Value.AsRef);
end;

procedure TJVM.AddRoot(Ref: Integer);
var
  N: Integer;
begin
  if Ref = 0 then
    Exit;
  GetObject(Ref);
  if not FRoots.TryGetValue(Ref, N) then
    N := 0;
  FRoots.AddOrSetValue(Ref, N + 1);
end;

procedure TJVM.RemoveRoot(Ref: Integer);
var
  N: Integer;
begin
  if Ref = 0 then
    Exit;
  if not FRoots.TryGetValue(Ref, N) then
    raise EJVMError.Create('Unbalanced Java GC root');
  if N = 1 then
    FRoots.Remove(Ref)
  else
    FRoots[Ref] := N - 1;
end;

procedure TJVM.Mark(Ref: Integer; Pending: TList<Integer>);
var
  O: TJVMObject;
begin
  if Ref = 0 then
    Exit;
  if not FHeap.TryGetValue(Ref, O) then
    raise EJVMError.Create('Dangling GC root');
  if not O.Marked then
  begin
    O.Marked := True;
    Pending.Add(Ref);
  end;
end;

procedure TJVM.CollectGarbage;
var
  Pending, Dead: TList<Integer>;
  O: TJVMObject;
  V: TJVMValue;
  C: TJVMClass;
  F: TJVMField;
  Frame: TJVMFrame;
  Ref, I: Integer;
  Frames: TObjectList<TJVMFrame>;
  Thread: TJVMThreadContext;

  procedure MarkValue(const Value: TJVMValue);
  begin
    if Value.Kind = TJVMKind.Reference then
      Mark(Value.AsRef, Pending);
  end;

begin
  Pending := TList<Integer>.Create;
  Dead := TList<Integer>.Create;
  try
    for O in FHeap.Values do
      O.Marked := False;
    for Ref in FRoots.Keys do
      Mark(Ref, Pending);
    for Ref in FInterned.Values do
      Mark(Ref, Pending);
    for Ref in FClassObjects.Values do
      Mark(Ref, Pending);
    for Ref in FScheduler.MonitorRoots do
      Mark(Ref, Pending);
    for Thread in FScheduler.Threads do
      if not (Thread.State in [TJVMThreadState.New, TJVMThreadState.Terminated]) then
        Mark(Thread.JavaObject, Pending);
    MarkValue(FResult);
    for var Context in FContexts.Values do
    begin
      MarkValue(Context.Value);
      Mark(Context.ExceptionRef, Pending);
    end;
    for C in FClasses.Values do
    begin
      Mark(C.InitFailure, Pending);
      for F in C.Fields do
        if (F.Access and JVM_ACC_STATIC) <> 0 then
          MarkValue(F.Value);
    end;
    for Frames in FThreadFrames.Values do
      for Frame in Frames do
      begin
        for V in Frame.Locals do
          MarkValue(V);
        for I := 0 to Frame.SP - 1 do
          MarkValue(Frame.Stack[I]);
        for V in Frame.NativeArguments do
          MarkValue(V);
        MarkValue(Frame.NativeResult);
        MarkValue(Frame.NativeContinuation);
        MarkValue(Frame.NativeGuestResult);
      end;
    while Pending.Count > 0 do
    begin
      Ref := Pending[Pending.Count - 1];
      Pending.Delete(Pending.Count - 1);
      O := FHeap[Ref];
      for V in O.Fields.Values do
        MarkValue(V);
      for V in O.Elements do
        MarkValue(V);
    end;
    for Ref in FHeap.Keys do
      if not FHeap[Ref].Marked then
        Dead.Add(Ref);
    for Ref in Dead do
    begin
      Thread := FScheduler.ThreadForObject(Ref);
      if Thread <> nil then
      begin
        if FCurrent = Thread then
        begin
          FCurrent := FMainThread;
          FFrames := FramesFor(FMainThread);
        end;
        FThreadFrames.Remove(Thread.ID);
      end;
      FScheduler.ForgetObject(Ref);
      FHeap.Remove(Ref);
    end;
    FNextGC := Min(FHeap.Count + 1024, FMaxObjects);
  finally
    Dead.Free;
    Pending.Free;
  end;
end;

function TJVM.HeapCount: Integer;
begin
  Result := FHeap.Count;
end;

procedure TJVM.CaptureThrowableTrace(Ref: Integer; SkipConstructors: Boolean);
var
  O: TJVMObject;
  Frame: TJVMFrame;
  First, Count: Integer;
  Trace: string;
begin
  O := GetObject(Ref);
  First := FFrames.Count - 1;
  Count := 0;
  Trace := '';
  if SkipConstructors then
    while First >= 0 do
    begin
      Frame := FFrames[First];
      if (Frame.Method = nil) or (Frame.Method.Name <> '<init>') or
        not IsAssignable(Frame.Method.Owner.Name, 'java/lang/Throwable') then
        Break;
      Dec(First);
    end;
  for var I := First downto 0 do
  begin
    Frame := FFrames[I];
    if Frame.Method = nil then
      Continue;
    Trace := Trace + #9 + 'at ' + Frame.Method.Owner.Name.Replace('/', '.') + '.' + Frame.Method.Name + Frame.Method.Descriptor;
    if (Frame.Method.Access and JVM_ACC_NATIVE) <> 0 then
      Trace := Trace + ' (native)'
    else
      Trace := Trace + ' pc=' + IntToStr(Frame.InstructionPC);
    Trace := Trace + #10;
    Inc(Count);
    if Count = 64 then
      Break;
  end;
  O.ThrowableTrace := Trace;
  O.HasThrowableTrace := True;
end;

procedure TJVM.QueueOutput(const Data: TBytes; StandardError: Boolean);
const
  Capacity = 65536;
begin
  if Length(Data) = 0 then
    Exit;
  if Length(FOutputData) = 0 then
  begin
    SetLength(FOutputData, Capacity);
    SetLength(FOutputChannels, Capacity);
  end;
  for var Value in Data do
  begin
    if FOutputCount = Capacity then
    begin
      FOutputHead := (FOutputHead + 1) mod Capacity;
      Dec(FOutputCount);
      Inc(FOutputDropped);
    end;
    var At := (FOutputHead + FOutputCount) mod Capacity;
    FOutputData[At] := Value;
    FOutputChannels[At] := Ord(StandardError);
    Inc(FOutputCount);
  end;
end;

function TJVM.TakeOutput(out Data: TBytes; out StandardError: Boolean): Boolean;
begin
  Data := nil;
  StandardError := False;
  Result := FOutputCount <> 0;
  if not Result then
    Exit;
  StandardError := FOutputChannels[FOutputHead] <> 0;
  var Count := 0;
  while (Count < FOutputCount) and (Count < 4096) and
    ((FOutputChannels[(FOutputHead + Count) mod Length(FOutputChannels)] <> 0) = StandardError) do
    Inc(Count);
  SetLength(Data, Count);
  for var I := 0 to Count - 1 do
    Data[I] := FOutputData[(FOutputHead + I) mod Length(FOutputData)];
  FOutputHead := (FOutputHead + Count) mod Length(FOutputData);
  Dec(FOutputCount, Count);
end;

procedure TJVM.RaiseJava(const ClassName, Message: string);
var
  Ref: Integer;
begin
  Ref := NewObject(ClassName);
  GetObject(Ref).Text := Message;
  CaptureThrowableTrace(Ref);
  raise EJVMThrown.Create(Ref);
end;

function TJVM.ConstantValue(C: TJVMClass; Index: Integer): TJVMValue;
var
  CP: TJVMConstant;
begin
  CP := C.Constant(Index);
  Result := Default(TJVMValue);
  case CP.Tag of
    3:
      Result := TJVMValue.Int(Integer(CP.Bits));
    4:
      begin
        Result.Kind := TJVMKind.Float;
        Result.Bits := CP.Bits;
      end;
    5:
      Result := TJVMValue.Long(CP.Bits);
    6:
      begin
        Result.Kind := TJVMKind.Double;
        Result.Bits := CP.Bits;
      end;
    8:
      Result := TJVMValue.Ref(InternString(C.UTF8(CP.A)));
    7:
      begin
        FLinker.ResolveClass(C.ClassName(Index), C);
        Result := TJVMValue.Ref(ClassObject(C.ClassName(Index)));
      end;
  else
    raise EJVMUnsupported.Create('Unsupported ldc constant');
  end;
end;

procedure TJVM.PushCall(M: TJVMMethod; const Args: TArray<TJVMValue>);
var
  Frame: TJVMFrame;
  I, P, Offset: Integer;
begin
  VerifyClass(M.Owner);
  if FFrames.Count >= 512 then
    raise EJVMError.Create('Java call depth limit exceeded');
  Offset := Ord((M.Access and JVM_ACC_STATIC) = 0);
  if Length(Args) <> Length(M.Signature.Arguments) + Offset then
    raise EJVMFormatError.Create('Wrong Java argument count');
  if Offset <> 0 then
    CheckValue(Args[0], 'L' + M.Owner.Name + ';');
  for I := 0 to High(M.Signature.Arguments) do
    CheckValue(Args[I + Offset], M.Signature.Arguments[I]);
  if (M.Access and JVM_ACC_ABSTRACT) <> 0 then
    RaiseJava('java/lang/AbstractMethodError');
  Frame := TJVMFrame.Create;
  try
    Frame.Method := M;
    if (M.Access and $0020) <> 0 then
    begin
      if Offset = 0 then
        Frame.SyncMonitor := ClassObject(M.Owner.Name)
      else
        Frame.SyncMonitor := Args[0].AsRef;
    end;
    if (M.Access and JVM_ACC_NATIVE) <> 0 then
      Frame.NativeArguments := Copy(Args)
    else
    begin
      SetLength(Frame.Locals, M.MaxLocals);
      SetLength(Frame.Stack, M.MaxStack);
      P := 0;
      for I := 0 to High(Args) do
      begin
        Frame.Store(P, Args[I]);
        Inc(P, Args[I].Slots);
      end;
    end;
    FFrames.Add(Frame);
    Frame := nil;
  finally
    Frame.Free;
  end;
end;

procedure TJVM.VerifyClass(C: TJVMClass);
begin
  FLinker.Link(C);
  if C.VerificationState = 3 then
    raise EJVMVerifyError.Create(C.VerificationError);
  if C.VerificationState <> 0 then
    Exit;
  C.VerificationState := 1;
  try
    for var M in C.Methods do
      if M.VerificationState <> 2 then
      begin
        JVMVerifyMethod(M,
          function(const Name: string): TJVMClass
          begin
            Result := LoadClass(Name);
          end);
        M.VerificationState := 2;
      end;
    C.VerificationState := 2;
  except
    on E: EJVMVerifyError do
    begin
      C.VerificationState := 3;
      C.VerificationError := E.Message;
      raise;
    end;
    on E: Exception do
    begin
      C.VerificationState := 0;
      raise;
    end;
  end;
end;

procedure TJVM.ReturnFromCall(const Value: TJVMValue; HasValue: Boolean);
var
  Frame: TJVMFrame;
  Context: TJVMExecutionContext;
begin
  Frame := FFrames.Last;
  if HasValue then
    CheckValue(Value, Frame.Method.Signature.ReturnType)
  else if Frame.Method.Signature.ReturnType <> 'V' then
    raise EJVMFormatError.Create('Missing Java return value');
  ReleaseFrameMonitor(Frame);
  FFrames.Delete(FFrames.Count - 1);
  if FFrames.Count = 0 then
  begin
    if FCurrent = FMainThread then
    begin
      FResult := Value;
      FState := TJVMState.Completed;
      FCurrent.State := TJVMThreadState.Idle;
    end
    else if FContexts.TryGetValue(FCurrent.ID, Context) then
    begin
      Context.Value := Value;
      Context.State := TJVMState.Completed;
      FCurrent.State := TJVMThreadState.Idle;
    end
    else
    begin
      FScheduler.Finish(FCurrent);
      FCurrent.Target := 0;
      if FCurrent.JavaObject <> 0 then
        GetObject(FCurrent.JavaObject).Fields.AddOrSetValue('$target', TJVMValue.Ref(0));
    end;
  end
  else if FFrames.Last.NativeAwaitingGuest then
  begin
    FFrames.Last.NativeAwaitingGuest := False;
    FFrames.Last.NativeGuestReady := True;
    FFrames.Last.NativeGuestResult := Value;
  end
  else if HasValue then
    FFrames.Last.Push(Value);
end;

procedure TJVM.ReleaseFrameMonitor(Frame: TJVMFrame);
begin
  if Frame.SyncAcquired then
  begin
    ExitMonitor(Frame.SyncMonitor);
    Frame.SyncAcquired := False;
  end;
end;

function TJVM.InitializeClass(C: TJVMClass): Boolean;
var
  F: TJVMField;
  Frame: TJVMFrame;
begin
  VerifyClass(C);
  if C.InitState = 3 then
  begin
    var Ref := NewObject('java/lang/NoClassDefFoundError');
    GetObject(Ref).Text := C.Name;
    GetObject(Ref).Fields.AddOrSetValue('$cause', TJVMValue.Ref(C.InitFailure));
    raise EJVMThrown.Create(Ref);
  end;
  if C.InitState = 2 then
    Exit(True);
  if C.InitState = 1 then
  begin
    if C.InitOwner = FCurrent.ID then
      Exit(True);
    FCurrent.State := TJVMThreadState.ClassInitialization;
    FCurrent.WaitClass := C.Name;
    YieldCurrent;
    Exit(False);
  end;
  C.InitState := 1;
  C.InitOwner := FCurrent.ID;
  for F in C.Fields do
    if ((F.Access and JVM_ACC_STATIC) <> 0) and (F.ConstantIndex <> 0) then
      F.Value := ConstantValue(C, F.ConstantIndex);
  if FFrames.Count >= 512 then
    raise EJVMError.Create('Java initialization depth limit exceeded');
  Frame := TJVMFrame.Create;
  Frame.Initializing := C;
  FFrames.Add(Frame);
  Result := False;
end;

procedure TJVM.InitializeStep(Frame: TJVMFrame);
var
  C: TJVMClass;
  M: TJVMMethod;
begin
  C := Frame.Initializing;
  if Frame.InitPhase = 0 then
  begin
    if ((C.Access and $0200) = 0) and (C.SuperName <> '') and
      not InitializeClass(LoadClass(C.SuperName)) then
      Exit;
    Frame.InitPhase := 1;
    M := C.FindMethod('<clinit>', '()V');
    if M <> nil then
    begin
      PushCall(M, nil);
      Exit;
    end;
  end;
  C.InitState := 2;
  C.InitOwner := 0;
  FScheduler.WakeClass(C.Name);
  FFrames.Delete(FFrames.Count - 1);
end;

function TJVM.TakeExceptionDiagnostic(out Diagnostic: string): Boolean;
begin
  Diagnostic := '';
  Result := FExceptionDiagnostics.Count <> 0;
  if Result then
    Diagnostic := FExceptionDiagnostics.Dequeue;
end;

procedure TJVM.DispatchException(Ref: Integer);
var
  Frame: TJVMFrame;
  H: TJVMExceptionHandler;
  O: TJVMObject;
  Wrapped: Integer;
  Context: TJVMExecutionContext;
  Trace: string;
begin
  O := GetObject(Ref);
  if not O.HasThrowableTrace then
    CaptureThrowableTrace(Ref);
  // Preserve a bounded throw-site trace before unwinding destroys the frames.
  // This is an embedding diagnostic, independent of guest Throwable APIs.
  Trace := '';
  for var I := FFrames.Count - 1 downto Max(0, FFrames.Count - 64) do
  begin
    Frame := FFrames[I];
    if Frame.Method <> nil then
    begin
      Trace := Trace + sLineBreak + '  at ' + Frame.Method.Owner.Name + '.' + Frame.Method.Name + Frame.Method.Descriptor;
      if (Frame.Method.Access and JVM_ACC_NATIVE) <> 0 then
        Trace := Trace + ' (native)'
      else
        Trace := Trace + ' pc=' + IntToStr(Frame.InstructionPC);
    end;
  end;
  if FTraceExceptionDiagnostics then
  begin
    if FExceptionDiagnostics.Count = 64 then
    begin
      FExceptionDiagnostics.Dequeue;
      Inc(FExceptionDiagnosticsDropped);
    end;
    FExceptionDiagnostics.Enqueue(Copy(Format('thread=%d instruction=%d %s: %s', [FCurrent.ID, FInstructions, O.ClassName, Copy(O.Text, 1, 512)]) + Trace, 1, 4096));
  end;
  while FFrames.Count > 0 do
  begin
    Frame := FFrames.Last;
    if Frame.Method <> nil then
      for H in Frame.Method.Handlers do
        if (Frame.InstructionPC >= H.StartPC) and (Frame.InstructionPC < H.EndPC) and
          ((H.CatchType = 0) or IsAssignable(O.ClassName, Frame.Method.Owner.ClassName(H.CatchType))) then
        begin
          Frame.SP := 0;
          Frame.StackSlots := 0;
          Frame.Push(TJVMValue.Ref(Ref));
          Frame.Jump(H.HandlerPC);
          Exit;
        end;
    if Frame.Initializing <> nil then
    begin
      if not IsAssignable(O.ClassName, 'java/lang/Error') then
      begin
        Wrapped := NewObject('java/lang/ExceptionInInitializerError');
        CaptureThrowableTrace(Wrapped);
        GetObject(Wrapped).Fields.AddOrSetValue('$cause', TJVMValue.Ref(Ref));
        GetObject(Wrapped).Text := O.Text;
        Ref := Wrapped;
        O := GetObject(Ref);
      end;
      Frame.Initializing.InitState := 3;
      Frame.Initializing.InitOwner := 0;
      Frame.Initializing.InitFailure := Ref;
      FScheduler.WakeClass(Frame.Initializing.Name);
    end;
    ReleaseFrameMonitor(Frame);
    FFrames.Delete(FFrames.Count - 1);
  end;
  if FCurrent = FMainThread then
  begin
    FError := 'Uncaught ' + O.ClassName + ': ' + O.Text + Trace;
    FState := TJVMState.Faulted;
    FResult := TJVMValue.Ref(Ref);
  end
  else if FContexts.TryGetValue(FCurrent.ID, Context) then
  begin
    Context.Error := 'Uncaught ' + O.ClassName + ': ' + O.Text + Trace;
    Context.ExceptionRef := Ref;
    Context.State := TJVMState.Faulted;
    FCurrent.State := TJVMThreadState.Idle;
  end
  else
  begin
    FThreadErrors.Enqueue('Uncaught ' + O.ClassName + ': ' + O.Text + Trace);
    FScheduler.Finish(FCurrent);
    FCurrent.Target := 0;
    GetObject(FCurrent.JavaObject).Fields.AddOrSetValue('$target', TJVMValue.Ref(0));
  end;
end;

procedure TJVM.BeginCall(const ClassName, Name, Descriptor: string; const Arguments: array of TJVMValue);
var
  Args: TArray<TJVMValue>;
  I: Integer;
  M: TJVMMethod;
begin
  if FState = TJVMState.Running then
    raise EJVMError.Create('JVM call is already running');
  if FState in [TJVMState.Faulted, TJVMState.Stopped] then
    raise EJVMError.Create('Create a new JVM after a fault or stop');
  FCurrent := FMainThread;
  FFrames := FramesFor(FMainThread);
  FFrames.Clear;
  FResult := Default(TJVMValue);
  FError := '';
  TInterlocked.Exchange(FStopRequested, 0);
  M := ResolveMethod(LoadClass(ClassName), Name, Descriptor);
  SetLength(Args, Length(Arguments));
  for I := 0 to High(Args) do
    Args[I] := Arguments[I];
  PushCall(M, Args);
  FState := TJVMState.Running;
  FFrames.Last.EntryInitialization := M.Owner;
  FCurrent.State := TJVMThreadState.Runnable;
  FCurrent.Quantum := 0;
end;

procedure TJVM.RequestStop;
begin
  TInterlocked.Exchange(FStopRequested, 1);
end;

function TJVM.StopRequested: Boolean;
begin
  Result := TInterlocked.CompareExchange(FStopRequested, 0, 0) <> 0;
end;

procedure TJVM.StopExecution;
begin
  for var Frames in FThreadFrames.Values do
    Frames.Clear;
  for var Thread in FScheduler.Threads do
    FScheduler.Finish(Thread);
  for var Context in FContexts.Values do
    if Context.State = TJVMState.Running then
      Context.State := TJVMState.Stopped;
  FState := TJVMState.Stopped;
end;

procedure TJVM.ExitApplication(Status: Integer);
begin
  if (FFrames.Count = 0) or (FFrames.Last.Method = nil) or
    ((FFrames.Last.Method.Access and JVM_ACC_NATIVE) = 0) then
    raise EJVMError.Create('Application exit requires an active native call');
  FExitRequested := True;
  FExitStatus := Status;
  raise EJVMExitSignal.Create('Guest application exit');
end;

function TJVM.HeapMemory: TJVMHeapMemory;
const
  Expansion = 1024 * 1024;
begin
  Result.UsedBytes := 0;
  for var O in FHeap.Values do
  begin
    // Stable interpreter storage estimate. Count shared strings conservatively
    // per object; allocator slack, class metadata, frames and host services are
    // outside this guest-heap estimate. Array values occupy tagged VM slots.
    Inc(Result.UsedBytes, 64 + Int64(Length(O.Elements)) * SizeOf(TJVMValue) +
      (Int64(Length(O.Text)) + Length(O.ThrowableTrace)) * SizeOf(Char));
    for var Pair in O.Fields do
      Inc(Result.UsedBytes, 32 + Int64(Length(Pair.Key)) * SizeOf(Char));
  end;
  // The logical heap can expand; its reported capacity is not a hard byte cap.
  // Object/array quotas and host allocation failures remain independent limits.
  if Result.UsedBytes > FHeapCapacity then
    FHeapCapacity :=
      ((Result.UsedBytes + Expansion - 1) div Expansion) * Expansion;
  Result.CapacityBytes := FHeapCapacity;
end;

function TJVM.HasRunnableWork: Boolean;
begin
  Result := False;
  if FState in [TJVMState.Stopped, TJVMState.Faulted] then
    Exit;
  for var Thread in FScheduler.Threads do
    if Thread.State = TJVMThreadState.Runnable then
      Exit(True);
end;

function TJVM.DescribeThreads(IncludeLocals: Boolean): string;
var
  Frames: TObjectList<TJVMFrame>;
begin
  Result := '';
  for var Thread in FScheduler.Threads do
  begin
    Result := Result + Format('thread=%d object=%d state=%d wake=%d monitor=%d class=%s',
      [Thread.ID, Thread.JavaObject, Ord(Thread.State), Thread.WakeAt, Thread.WaitMonitor, Copy(Thread.WaitClass, 1, 256)]);
    if (Thread.JavaObject <> 0) and IsObjectAlive(Thread.JavaObject) then
      Result := Result + ' name=' + Copy(GetObject(Thread.JavaObject).Text, 1, 128);
    Result := Result + #10;
    if FThreadFrames.TryGetValue(Thread.ID, Frames) then
      for var I := Frames.Count - 1 downto Max(0, Frames.Count - 16) do
      begin
        var Frame := Frames[I];
        if Frame.Method <> nil then
          Result := Result + '  ' + Copy(Frame.Method.Owner.Name + '.' + Frame.Method.Name + Frame.Method.Descriptor, 1, 512) + ' pc=' + IntToStr(Frame.PC) + #10
        else if Frame.Initializing <> nil then
          Result := Result + '  initialize ' + Copy(Frame.Initializing.Name, 1, 256) + #10;
        if IncludeLocals then
        begin
          var Values := Frame.Locals;
          if (Frame.Method <> nil) and ((Frame.Method.Access and JVM_ACC_NATIVE) <> 0) then
            Values := Frame.NativeArguments;
          for var J := 0 to Min(5, High(Values)) do
          begin
            var Value := Values[J];
            if Value.Kind <> TJVMKind.Reference then
              Continue;
            if (Value.AsRef = 0) or not IsObjectAlive(Value.AsRef) then
              Continue;
            var O := GetObject(Value.AsRef);
            Result := Result + Format('    local%d ref=%d %s elements=%d textUnits=%d', [J, Value.AsRef, Copy(O.ClassName, 1, 256), Length(O.Elements), Length(O.Text)]) + #10;
            var FieldCount := 0;
            for var Pair in O.Fields do
            begin
              Result := Result + '      ' + Copy(Pair.Key, 1, 256) + '=' + IntToStr(Pair.Value.Bits) + ' kind=' + IntToStr(Ord(Pair.Value.Kind)) + #10;
              Inc(FieldCount);
              if FieldCount = 16 then
                Break;
            end;
          end;
        end;
      end;
  end;
end;

function TJVM.CreateExecutionContext: Integer;
var
  Context: TJVMExecutionContext;
begin
  if FState in [TJVMState.Faulted, TJVMState.Stopped] then
    raise EJVMError.Create('Cannot create a context on a faulted/stopped VM');
  if FScheduler.LiveCount >= 256 then
    raise EJVMError.Create('Execution context/thread limit');
  Context := TJVMExecutionContext.Create;
  try
    Context.Thread := FScheduler.NewThread;
    Context.Thread.State := TJVMThreadState.Idle;
    Result := Context.Thread.ID;
    FContexts.Add(Result, Context);
    Context := nil;
  finally
    Context.Free;
  end;
end;

procedure TJVM.BeginContextCall(Context: Integer; const ClassName, Name, Descriptor: string; const Arguments: array of TJVMValue);
var
  Call: TJVMExecutionContext;
  Previous: TJVMThreadContext;
  M: TJVMMethod;
  Args: TArray<TJVMValue>;
begin
  if FState in [TJVMState.Faulted, TJVMState.Stopped] then
    raise EJVMError.Create('Cannot schedule on a faulted/stopped VM');
  Call := FContexts[Context];
  if Call.State = TJVMState.Running then
    raise EJVMError.Create('Execution context is busy');
  M := ResolveMethod(LoadClass(ClassName), Name, Descriptor);
  SetLength(Args, Length(Arguments));
  for var I := 0 to High(Args) do
    Args[I] := Arguments[I];
  Previous := FCurrent;
  try
    FCurrent := Call.Thread;
    FFrames := FramesFor(FCurrent);
    PushCall(M, Args);
    FFrames.Last.EntryInitialization := M.Owner;
    Call.Value := Default(TJVMValue);
    Call.Error := '';
    Call.ExceptionRef := 0;
    Call.State := TJVMState.Running;
    FCurrent.State := TJVMThreadState.Runnable;
    FCurrent.Quantum := 0;
  finally
    FCurrent := Previous;
    FFrames := FramesFor(Previous);
  end;
end;

function TJVM.ExecutionContextState(Context: Integer): TJVMState;
begin
  Result := FContexts[Context].State;
end;

function TJVM.ExecutionContextResult(Context: Integer): TJVMValue;
begin
  Result := FContexts[Context].Value;
end;

function TJVM.ExecutionContextError(Context: Integer): string;
begin
  Result := FContexts[Context].Error;
end;
{$WARN SYMBOL_PLATFORM OFF}

function TJVM.Execute(Budget: Integer): TJVMState;
var
  I: Integer;
  OldMask: TArithmeticExceptionMask;
  OldRound: TRoundingMode;
  C: TJVMClass;
  {$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}     OldCW: Word;
  OldMXCSR: UInt32; {$ENDIF}
  {$IF Defined(CPUARM)}
  OldFPSCR: UInt32; {$ENDIF}
  Next: TJVMThreadContext;
begin
  if Budget < 0 then
    raise EJVMError.Create('Negative instruction budget');
  OldMask := GetExceptionMask;
  OldRound := GetRoundMode;
  {$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}     OldCW := Get8087CW;
  OldMXCSR := GetMXCSR; {$ENDIF}
  {$IF Defined(CPUARM)}
  OldFPSCR := GetFPSCR; {$ENDIF}
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  SetRoundMode(rmNearest);
  {$IF Defined(MSWINDOWS) and Defined(CPUX86)}     SetPrecisionMode(pmDouble); {$ENDIF}
  {$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}
  // Java uses gradual underflow; an embedding renderer may have enabled DAZ/FTZ.
  SetMXCSR((GetMXCSR or $1F80) and not UInt32($E040));
  {$ENDIF}
  {$IF Defined(CPUARM)}     SetFPSCR(GetFPSCR and not UInt32($01080000)); {$ENDIF}
  try
    try
      FNow := FHost.MonotonicMillis;
      FYieldToHost := False;
      for I := 1 to Budget do
      begin
        if FState in [TJVMState.Faulted, TJVMState.Stopped] then
          Break;
        if TInterlocked.CompareExchange(FStopRequested, 0, 0) <> 0 then
        begin
          StopExecution;
          Break;
        end;
        if (FCurrent.State <> TJVMThreadState.Runnable) or (FCurrent.Quantum <= 0) then
        begin
          Next := FScheduler.NextRunnable(FCurrent.ID, FNow);
          if Next = nil then
            Break;
          FCurrent := Next;
          FFrames := FramesFor(Next);
          Next.Quantum := EnsureRange(FQuantumScale, 1, 100000) * Next.Priority;
        end;
        if FHeap.Count >= FNextGC then
          CollectGarbage;
        try
          try
            Step;
          except
            on E: EJVMVerifyError do
              RaiseJava('java/lang/VerifyError', E.Message);
            on E: EJVMClassFormatError do
              RaiseJava('java/lang/ClassFormatError', E.Message);
            on E: EJVMLinkError do
              RaiseJava(E.JavaClass, E.Message);
          end;
        except
          on E: EJVMThrown do
            DispatchException(E.Reference);
        end;
        Inc(FInstructions);
        Dec(FCurrent.Quantum);
        if FYieldToHost then
          Break;
      end;
    except
      on E: EJVMExitSignal do
        StopExecution;
      on E: Exception do
      begin
        FError := E.ClassName + ': ' + E.Message;
        if (FFrames.Count > 0) and (FFrames.Last.Method <> nil) then
          FError := FError + Format(' at %s.%s%s pc=%d',
            [FFrames.Last.Method.Owner.Name, FFrames.Last.Method.Name,
              FFrames.Last.Method.Descriptor, FFrames.Last.InstructionPC]);
        for C in FClasses.Values do
          if C.InitState = 1 then
            C.InitState := 3;
        FState := TJVMState.Faulted;
      end;
    end;
  finally
    SetRoundMode(OldRound);
    SetExceptionMask(OldMask);
    {$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}         Set8087CW(OldCW);
    SetMXCSR(OldMXCSR); {$ENDIF}
    {$IF Defined(CPUARM)}
    SetFPSCR(OldFPSCR); {$ENDIF}
  end;
  Result := FState;
end;
{$WARN SYMBOL_PLATFORM ON}

function RealToJavaLong(X: Double): Int64;
begin
  if IsNan(X) then
    Exit(0);
  if X >= 9223372036854775808.0 then
    Exit(High(Int64));
  if X <= -9223372036854775808.0 then
    Exit(Low(Int64));
  Result := Trunc(X);
end;

function RealToJavaInt(X: Double): Integer;
begin
  if IsNan(X) then
    Exit(0);
  if X >= High(Integer) then
    Exit(High(Integer));
  if X <= Low(Integer) then
    Exit(Low(Integer));
  Result := Trunc(X);
end;

procedure TJVM.Step;
var
  F: TJVMFrame;
  Op, SubOp: Byte;
  A, B, V, W: TJVMValue;
  I, J, K, Offset, LowKey, HighKey: Integer;
  L, R: Int64;
  X, Y, Z: Double;
  S: Single;
  Test: Boolean;
  ClassName, Name, Descriptor, Component: string;
  C, Owner: TJVMClass;
  Field: TJVMField;
  M: TJVMMethod;
  Args: TArray<TJVMValue>;
  O: TJVMObject;
  Dimensions: TArray<Integer>;

  procedure RequireCategory1(const Value: TJVMValue);
  begin
    if Value.Slots <> 1 then
      raise EJVMFormatError.Create('Expected category-1 value');
  end;

  procedure Branch(Condition: Boolean);
  var
    D: SmallInt;
  begin
    D := F.S2;
    if Condition then
      F.Jump(Int64(F.InstructionPC) + D);
  end;

  procedure CheckArrayOpcode(Code: Byte; Obj: TJVMObject);
  var
    Expected: string;
  begin
    case Code of
      $2E, $4F:
        Expected := '[I';
      $2F, $50:
        Expected := '[J';
      $30, $51:
        Expected := '[F';
      $31, $52:
        Expected := '[D';
      $32, $53:
        begin
          if (Length(Obj.ClassName) < 2) or not CharInSet(Obj.ClassName[2], ['L', '[']) then
            raise EJVMFormatError.Create('Expected reference array');
          Exit;
        end;
      $33, $54:
        begin
          if (Obj.ClassName <> '[B') and (Obj.ClassName <> '[Z') then
            raise EJVMFormatError.Create('Expected byte/boolean array');
          Exit;
        end;
      $34, $55:
        Expected := '[C';
      $35, $56:
        Expected := '[S';
    end;
    if Obj.ClassName <> Expected then
      raise EJVMFormatError.Create('Incorrect array opcode');
  end;

  function MultiArray(const ArrayType: string; Depth: Integer): Integer;
  var
    Ref, At: Integer;
    Obj: TJVMObject;
  begin
    Ref := NewArray(ArrayType, Dimensions[Depth]);
    if Depth + 1 < Length(Dimensions) then
    begin
      Obj := GetObject(Ref);
      for At := 0 to High(Obj.Elements) do
        Obj.Elements[At] := TJVMValue.Ref(MultiArray(Copy(ArrayType, 2, MaxInt), Depth + 1));
    end;
    Result := Ref;
  end;

  procedure CheckLocalKind(const Value: TJVMValue; Family: Integer; Storing: Boolean);
  var
    Expected: TJVMKind;
  begin
    case Family of
      0:
        Expected := TJVMKind.Int;
      1:
        Expected := TJVMKind.Long;
      2:
        Expected := TJVMKind.Float;
      3:
        Expected := TJVMKind.Double;
      4:
        Expected := TJVMKind.Reference;
    else
      raise EJVMFormatError.Create('Invalid local opcode family');
    end;
    if (Value.Kind <> Expected) and not (Storing and (Family = 4) and (Value.Kind = TJVMKind.ReturnAddress)) then
      raise EJVMFormatError.Create('Incorrect local value type');
  end;

begin
  F := FFrames.Last;
  if F.Initializing <> nil then
  begin
    InitializeStep(F);
    Exit;
  end;
  if F.EntryInitialization <> nil then
  begin
    if not InitializeClass(F.EntryInitialization) then
      Exit;
    F.EntryInitialization := nil;
  end;
  if (F.SyncMonitor <> 0) and not F.SyncAcquired then
  begin
    if not EnterMonitor(F.SyncMonitor) then
      Exit;
    F.SyncAcquired := True;
  end;
  if (F.Method.Access and JVM_ACC_NATIVE) <> 0 then
  begin
    if FCurrent.PendingInterrupted then
    begin
      FCurrent.PendingInterrupted := False;
      if F.NativeRetryInterrupted then
        FCurrent.Interrupted := True
      else
      begin
        FCurrent.Interrupted := False;
        var ExceptionClass := F.NativeInterruptClass;
        if ExceptionClass = '' then
          ExceptionClass := 'java/lang/InterruptedException';
        RaiseJava(ExceptionClass);
      end;
    end;
    if not F.NativeEntered or F.NativeRetry then
    begin
      F.NativeEntered := True;
      F.NativeRetry := False;
      F.NativeResult := FHost.InvokeNative(Self, F.Method, F.NativeArguments);
      if (FFrames.Last <> F) or (FCurrent.State <> TJVMThreadState.Runnable) or F.NativeRetry then
        Exit;
    end;
    ReturnFromCall(F.NativeResult, F.Method.Signature.ReturnType <> 'V');
    Exit;
  end;
  F.InstructionPC := F.PC;
  Op := F.U1;
  case Op of
    $00:
      ;
    $01:
      F.Push(TJVMValue.Ref(0));
    $02..$08:
      F.Push(TJVMValue.Int(Integer(Op) - 3));
    $09..$0A:
      F.Push(TJVMValue.Long(Op - $09));
    $0B..$0D:
      F.Push(TJVMValue.Float(Op - $0B));
    $0E..$0F:
      F.Push(TJVMValue.Double(Op - $0E));
    $10:
      F.Push(TJVMValue.Int(ShortInt(F.U1)));
    $11:
      F.Push(TJVMValue.Int(F.S2));
    $12..$14:
      begin
        if Op = $12 then
          I := F.U1
        else
          I := F.U2;
        V := ConstantValue(F.Method.Owner, I);
        if (V.Slots = 2) <> (Op = $14) then
          raise EJVMFormatError.Create('Incorrect ldc width');
        F.Push(V);
      end;
    $15..$19:
      begin
        V := F.Load(F.U1);
        CheckLocalKind(V, Op - $15, False);
        F.Push(V);
      end;
    $1A..$2D:
      begin
        V := F.Load((Op - $1A) mod 4);
        CheckLocalKind(V, (Op - $1A) div 4, False);
        F.Push(V);
      end;
    $2E..$35:
      begin
        I := F.Pop.AsInt;
        O := ArrayObject(F.Pop.AsRef, I);
        CheckArrayOpcode(Op, O);
        F.Push(O.Elements[I]);
      end;
    $36..$3A:
      begin
        I := F.U1;
        V := F.Pop;
        CheckLocalKind(V, Op - $36, True);
        F.Store(I, V);
      end;
    $3B..$4E:
      begin
        V := F.Pop;
        CheckLocalKind(V, (Op - $3B) div 4, True);
        F.Store((Op - $3B) mod 4, V);
      end;
    $4F..$56:
      begin
        V := F.Pop;
        I := F.Pop.AsInt;
        O := ArrayObject(F.Pop.AsRef, I);
        CheckArrayOpcode(Op, O);
        case Op of
          $53:
            begin
              J := V.AsRef;
              if J <> 0 then
              begin
                Component := Copy(O.ClassName, 2, MaxInt);
                if Component[1] = 'L' then
                  Component := Copy(Component, 2, Length(Component) - 2);
                if not IsAssignable(GetObject(J).ClassName, Component) then
                  RaiseJava('java/lang/ArrayStoreException');
              end;
            end;
          $54:
            if O.ClassName = '[Z' then
              V := TJVMValue.Int(V.AsInt and 1)
            else
              V := TJVMValue.Int(ShortInt(V.AsInt));
          $55:
            V := TJVMValue.Int(Word(V.AsInt));
          $56:
            V := TJVMValue.Int(SmallInt(V.AsInt));
        end;
        if V.Kind <> O.Elements[I].Kind then
          raise EJVMFormatError.Create('Incorrect array value type');
        O.Elements[I] := V;
      end;
    $57:
      begin
        V := F.Pop;
        RequireCategory1(V);
      end;
    $58:
      begin
        V := F.Pop;
        if V.Slots = 1 then
        begin
          V := F.Pop;
          RequireCategory1(V);
        end;
      end;
    $59:
      begin
        V := F.Pop;
        RequireCategory1(V);
        F.Push(V);
        F.Push(V);
      end;
    $5A:
      begin
        V := F.Pop;
        W := F.Pop;
        RequireCategory1(V);
        RequireCategory1(W);
        F.Push(V);
        F.Push(W);
        F.Push(V);
      end;
    $5B:
      begin
        V := F.Pop;
        W := F.Pop;
        RequireCategory1(V);
        if W.Slots = 2 then
        begin
          F.Push(V);
          F.Push(W);
          F.Push(V);
        end
        else
        begin
          A := F.Pop;
          RequireCategory1(A);
          F.Push(V);
          F.Push(A);
          F.Push(W);
          F.Push(V);
        end;
      end;
    $5C:
      begin
        V := F.Pop;
        if V.Slots = 2 then
        begin
          F.Push(V);
          F.Push(V);
        end
        else
        begin
          W := F.Pop;
          RequireCategory1(W);
          F.Push(W);
          F.Push(V);
          F.Push(W);
          F.Push(V);
        end;
      end;
    $5D:
      begin
        V := F.Pop;
        W := F.Pop;
        if V.Slots = 2 then
        begin
          RequireCategory1(W);
          F.Push(V);
          F.Push(W);
          F.Push(V);
        end
        else
        begin
          RequireCategory1(W);
          A := F.Pop;
          RequireCategory1(A);
          F.Push(W);
          F.Push(V);
          F.Push(A);
          F.Push(W);
          F.Push(V);
        end;
      end;
    $5E:
      begin
        V := F.Pop;
        W := F.Pop;
        if V.Slots = 2 then
        begin
          if W.Slots = 2 then
          begin
            F.Push(V);
            F.Push(W);
            F.Push(V);
          end
          else
          begin
            A := F.Pop;
            RequireCategory1(A);
            F.Push(V);
            F.Push(A);
            F.Push(W);
            F.Push(V);
          end;
        end
        else
        begin
          RequireCategory1(W);
          A := F.Pop;
          if A.Slots = 2 then
          begin
            F.Push(W);
            F.Push(V);
            F.Push(A);
            F.Push(W);
            F.Push(V);
          end
          else
          begin
            B := F.Pop;
            RequireCategory1(B);
            F.Push(W);
            F.Push(V);
            F.Push(B);
            F.Push(A);
            F.Push(W);
            F.Push(V);
          end;
        end;
      end;
    $5F:
      begin
        V := F.Pop;
        W := F.Pop;
        RequireCategory1(V);
        RequireCategory1(W);
        F.Push(V);
        F.Push(W);
      end;
    $60..$73:
      begin
        B := F.Pop;
        A := F.Pop;
        I := (Op - $60) div 4;
        J := (Op - $60) mod 4;
        if J <= 1 then
        begin
          if J = 0 then
          begin
            L := A.AsInt;
            R := B.AsInt;
          end
          else
          begin
            L := A.AsLong;
            R := B.AsLong;
          end;
          case I of
            0:
              L := L + R;
            1:
              L := L - R;
            2:
              L := L * R;
            3, 4:
              begin
                if R = 0 then
                  RaiseJava('java/lang/ArithmeticException', '/ by zero');
                if (R = -1) and (((J = 0) and (L = Low(Integer))) or ((J = 1) and (L = Low(Int64)))) then
                begin
                  if I = 4 then
                    L := 0;
                end
                else if I = 3 then
                  L := L div R
                else
                  L := L mod R;
              end;
          end;
          if J = 0 then
            F.Push(TJVMValue.Int(Integer(L)))
          else
            F.Push(TJVMValue.Long(L));
        end
        else
        begin
          if J = 2 then
          begin
            X := A.AsFloat;
            Y := B.AsFloat;
          end
          else
          begin
            X := A.AsDouble;
            Y := B.AsDouble;
          end;
          case I of
            0:
              Z := X + Y;
            1:
              Z := X - Y;
            2:
              Z := X * Y;
            3:
              Z := X / Y;
            4:
              if IsNan(X) or IsNan(Y) or IsInfinite(X) or (Y = 0) then
                Z := NaN
              else if IsInfinite(Y) then
                Z := X
              else
                Z := FMod(X, Y);
          else
            Z := 0;
          end;
          if J = 2 then
          begin
            S := Z;
            F.Push(TJVMValue.Float(S));
          end
          else
            F.Push(TJVMValue.Double(Z));
        end;
      end;
    $74..$77:
      begin
        V := F.Pop;
        case Op of
          $74:
            F.Push(TJVMValue.Int(-V.AsInt));
          $75:
            F.Push(TJVMValue.Long(-V.AsLong));
          $76:
            F.Push(TJVMValue.Float(-V.AsFloat));
          $77:
            F.Push(TJVMValue.Double(-V.AsDouble));
        end;
      end;
    $78..$7D:
      begin
        I := F.Pop.AsInt;
        A := F.Pop;
        if (Op and 1) = 0 then
        begin
          J := A.AsInt;
          I := I and 31;
          case Op of
            $78:
              J := Integer(UInt32(J) shl I);
            $7A:
              if J < 0 then
                J := Integer(not ((not UInt32(J)) shr I))
              else
                J := J shr I;
            $7C:
              J := Integer(UInt32(J) shr I);
          end;
          F.Push(TJVMValue.Int(J));
        end
        else
        begin
          L := A.AsLong;
          I := I and 63;
          case Op of
            $79:
              L := Int64(UInt64(L) shl I);
            $7B:
              if L < 0 then
                L := Int64(not ((not UInt64(L)) shr I))
              else
                L := L shr I;
            $7D:
              L := Int64(UInt64(L) shr I);
          end;
          F.Push(TJVMValue.Long(L));
        end;
      end;
    $7E..$83:
      begin
        B := F.Pop;
        A := F.Pop;
        if (Op and 1) = 0 then
        begin
          L := A.AsInt;
          R := B.AsInt;
        end
        else
        begin
          L := A.AsLong;
          R := B.AsLong;
        end;
        case Op of
          $7E, $7F:
            L := L and R;
          $80, $81:
            L := L or R;
          $82, $83:
            L := L xor R;
        end;
        if (Op and 1) = 0 then
          F.Push(TJVMValue.Int(Integer(L)))
        else
          F.Push(TJVMValue.Long(L));
      end;
    $84:
      begin
        I := F.U1;
        J := ShortInt(F.U1);
        F.Store(I, TJVMValue.Int(F.Load(I).AsInt + J));
      end;
    $85..$93:
      begin
        V := F.Pop;
        case Op of
          $85:
            V := TJVMValue.Long(V.AsInt);
          $86:
            V := TJVMValue.Float(V.AsInt);
          $87:
            V := TJVMValue.Double(V.AsInt);
          $88:
            V := TJVMValue.Int(Integer(V.AsLong));
          $89:
            V := TJVMValue.Float(V.AsLong);
          $8A:
            V := TJVMValue.Double(V.AsLong);
          $8B:
            V := TJVMValue.Int(RealToJavaInt(V.AsFloat));
          $8C:
            V := TJVMValue.Long(RealToJavaLong(V.AsFloat));
          $8D:
            V := TJVMValue.Double(V.AsFloat);
          $8E:
            V := TJVMValue.Int(RealToJavaInt(V.AsDouble));
          $8F:
            V := TJVMValue.Long(RealToJavaLong(V.AsDouble));
          $90:
            V := TJVMValue.Float(V.AsDouble);
          $91:
            V := TJVMValue.Int(ShortInt(V.AsInt));
          $92:
            V := TJVMValue.Int(Word(V.AsInt));
          $93:
            V := TJVMValue.Int(SmallInt(V.AsInt));
        end;
        F.Push(V);
      end;
    $94..$98:
      begin
        B := F.Pop;
        A := F.Pop;
        I := 0;
        if Op = $94 then
        begin
          L := A.AsLong;
          R := B.AsLong;
          if L < R then
            I := -1
          else if L > R then
            I := 1;
        end
        else
        begin
          if Op <= $96 then
          begin
            X := A.AsFloat;
            Y := B.AsFloat;
          end
          else
          begin
            X := A.AsDouble;
            Y := B.AsDouble;
          end;
          if IsNan(X) or IsNan(Y) then
          begin
            if Op in [$95, $97] then
              I := -1
            else
              I := 1;
          end
          else if X < Y then
            I := -1
          else if X > Y then
            I := 1;
        end;
        F.Push(TJVMValue.Int(I));
      end;
    $99..$9E:
      begin
        I := F.Pop.AsInt;
        Test := False;
        case Op of
          $99:
            Test := I = 0;
          $9A:
            Test := I <> 0;
          $9B:
            Test := I < 0;
          $9C:
            Test := I >= 0;
          $9D:
            Test := I > 0;
          $9E:
            Test := I <= 0;
        end;
        Branch(Test);
      end;
    $9F..$A6:
      begin
        B := F.Pop;
        A := F.Pop;
        Test := False;
        if Op >= $A5 then
        begin
          I := A.AsRef;
          J := B.AsRef;
        end
        else
        begin
          I := A.AsInt;
          J := B.AsInt;
        end;
        case Op of
          $9F, $A5:
            Test := I = J;
          $A0, $A6:
            Test := I <> J;
          $A1:
            Test := I < J;
          $A2:
            Test := I >= J;
          $A3:
            Test := I > J;
          $A4:
            Test := I <= J;
        end;
        Branch(Test);
      end;
    $A7:
      Branch(True);
    $A8:
      begin
        I := F.S2;
        V.Kind := TJVMKind.ReturnAddress;
        V.Bits := F.PC;
        F.Push(V);
        F.Jump(Int64(F.InstructionPC) + I);
      end;
    $A9:
      begin
        V := F.Load(F.U1);
        if V.Kind <> TJVMKind.ReturnAddress then
          raise EJVMFormatError.Create('ret requires a return address');
        F.Jump(V.Bits);
      end;
    $AA, $AB:
      begin
        while (F.PC and 3) <> 0 do
          F.U1;
        Offset := F.S4;
        I := F.Pop.AsInt;
        if Op = $AA then
        begin
          LowKey := F.S4;
          HighKey := F.S4;
          if (HighKey < LowKey) or (Int64(HighKey) - LowKey + 1 > (Length(F.Method.Code) - F.PC) div 4) then
            raise EJVMFormatError.Create('Invalid tableswitch');
          for J := LowKey to HighKey do
          begin
            K := F.S4;
            if I = J then
              Offset := K;
          end;
        end
        else
        begin
          J := F.S4;
          if (J < 0) or (J > (Length(F.Method.Code) - F.PC) div 8) then
            raise EJVMFormatError.Create('Invalid lookupswitch');
          LowKey := Low(Integer);
          for K := 1 to J do
          begin
            HighKey := F.S4;
            if (K > 1) and (HighKey <= LowKey) then
              raise EJVMFormatError.Create('Unsorted lookupswitch');
            LowKey := HighKey;
            HighKey := F.S4;
            if I = LowKey then
              Offset := HighKey;
          end;
        end;
        F.Jump(Int64(F.InstructionPC) + Offset);
      end;
    $AC..$B0:
      begin
        V := F.Pop;
        ReturnFromCall(V, True);
      end;
    $B1:
      ReturnFromCall(Default(TJVMValue), False);
    $B2..$B5:
      begin
        O := nil;
        F.Method.Owner.MemberRef(F.U2, ClassName, Name, Descriptor);
        C := FLinker.ResolveClass(ClassName, F.Method.Owner);
        Field := ResolveField(C, Name, Descriptor, Owner);
        FLinker.MemberAccess(F.Method.Owner, Owner, Field.Access);
        if ((Field.Access and JVM_ACC_STATIC) <> 0) <> (Op in [$B2, $B3]) then
          JVMLinkFailure('IncompatibleClassChangeError', 'Incorrect field access opcode');
        if (Op in [$B3, $B5]) and ((Field.Access and JVM_ACC_FINAL) <> 0) then
        begin
          if F.Method.Owner <> Owner then
            JVMLinkFailure('IllegalAccessError', 'Write to final field from another class');
        // Historical class files (including CLDC 45.3) permit same-class
        // helper methods to assign final fields. The initializer-only check
        // is enforced for class-file version 53 and later, as in OpenJDK.
          if (Owner.Major >= 53) and
            (((Op = $B3) and (F.Method.Name <> '<clinit>')) or
            ((Op = $B5) and (F.Method.Name <> '<init>'))) then
            JVMLinkFailure('IllegalAccessError', 'Write outside final field initializer');
        end;
        if (Op in [$B2, $B3]) and not InitializeClass(Owner) then
        begin
          F.PC := F.InstructionPC;
          Exit;
        end;
        if Op in [$B3, $B5] then
        begin
          V := F.Pop;
          CheckValue(V, Field.Descriptor);
          case Field.Descriptor[1] of
            'Z':
              V := TJVMValue.Int(V.AsInt and 1);
            'B':
              V := TJVMValue.Int(ShortInt(V.AsInt));
            'C':
              V := TJVMValue.Int(Word(V.AsInt));
            'S':
              V := TJVMValue.Int(SmallInt(V.AsInt));
          end;
        end;
        if Op in [$B4, $B5] then
        begin
          O := GetObject(F.Pop.AsRef);
          FLinker.MemberAccess(F.Method.Owner, Owner, Field.Access, O.ClassName);
        end;
        case Op of
          $B2:
            F.Push(Field.Value);
          $B3:
            Field.Value := V;
          $B4:
            F.Push(O.Fields[FieldKey(Owner, Field)]);
          $B5:
            O.Fields[FieldKey(Owner, Field)] := V;
        end;
      end;
    $B6..$B9:
      begin
        F.Method.Owner.MemberRef(F.U2, ClassName, Name, Descriptor);
        if Op = $B9 then
        begin
          I := F.U1;
          if (I = 0) or (F.U1 <> 0) then
            raise EJVMFormatError.Create('Invalid invokeinterface operands');
        end;
        C := FLinker.ResolveClass(ClassName, F.Method.Owner);
        M := FLinker.MethodReference(C, Name, Descriptor, Op = $B9);
        if not ((Name = 'clone') and ClassName.StartsWith('[')) then
          FLinker.MemberAccess(F.Method.Owner, M.Owner, M.Access);
        if ((M.Access and JVM_ACC_STATIC) <> 0) <> (Op = $B8) then
          JVMLinkFailure('IncompatibleClassChangeError', 'Incorrect method invocation opcode');
        if (Op = $B8) and not InitializeClass(M.Owner) then
        begin
          F.PC := F.InstructionPC;
          Exit;
        end;
        Offset := Ord(Op <> $B8);
        SetLength(Args, Length(M.Signature.Arguments) + Offset);
        for I := High(Args) downto 0 do
          Args[I] := F.Pop;
        if Offset <> 0 then
        begin
          O := GetObject(Args[0].AsRef);
          if not IsAssignable(O.ClassName, ClassName) then
            JVMLinkFailure('IncompatibleClassChangeError', 'Invalid invocation receiver');
          if not (O.IsArray and (Name = 'clone') and (M.Owner.Name = 'java/lang/Object')) then
            FLinker.MemberAccess(F.Method.Owner, M.Owner, M.Access, O.ClassName);
          if Op in [$B6, $B9] then
          begin
            if O.IsArray then
              C := LoadClass('java/lang/Object')
            else
              C := LoadClass(O.ClassName);
            M := FLinker.VirtualMethod(C, M, Op = $B9);
          end
          else if Op = $B7 then
            M := FLinker.SpecialMethod(F.Method.Owner, M);
        end;
        PushCall(M, Args);
      end;
    $BB:
      begin
        ClassName := F.Method.Owner.ClassName(F.U2);
        C := FLinker.ResolveClass(ClassName, F.Method.Owner);
        if not InitializeClass(C) then
        begin
          F.PC := F.InstructionPC;
          Exit;
        end;
        F.Push(TJVMValue.Ref(NewObject(ClassName)));
      end;
    $BC, $BD:
      begin
        if Op = $BC then
        begin
          case F.U1 of
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
            raise EJVMFormatError.Create('Invalid primitive array type');
          end;
        end
        else
        begin
          ClassName := F.Method.Owner.ClassName(F.U2);
          FLinker.ResolveClass(ClassName, F.Method.Owner);
          if ClassName.StartsWith('[') then
            Descriptor := '[' + ClassName
          else
            Descriptor := '[L' + ClassName + ';';
        end;
        F.Push(TJVMValue.Ref(NewArray(Descriptor, F.Pop.AsInt)));
      end;
    $BE:
      begin
        O := GetObject(F.Pop.AsRef);
        if not O.IsArray then
          raise EJVMFormatError.Create('Expected arraylength receiver');
        F.Push(TJVMValue.Int(Length(O.Elements)));
      end;
    $BF:
      begin
        I := F.Pop.AsRef;
        O := GetObject(I);
        if not IsAssignable(O.ClassName, 'java/lang/Throwable') then
          raise EJVMFormatError.Create('Expected Throwable');
        raise EJVMThrown.Create(I);
      end;
    $C0, $C1:
      begin
        ClassName := F.Method.Owner.ClassName(F.U2);
        V := F.Pop;
        I := V.AsRef;
        if I <> 0 then
          FLinker.ResolveClass(ClassName, F.Method.Owner);
        Test := (I <> 0) and IsAssignable(GetObject(I).ClassName, ClassName);
        if Op = $C1 then
          F.Push(TJVMValue.Int(Ord(Test)))
        else
        begin
          if (I <> 0) and not Test then
            RaiseJava('java/lang/ClassCastException');
          F.Push(V);
        end;
      end;
    $C2:
      begin
        V := F.Pop;
        if not EnterMonitor(V.AsRef) then
        begin
          F.Push(V);
          F.PC := F.InstructionPC;
        end;
      end;
    $C3:
      ExitMonitor(F.Pop.AsRef);
    $C4:
      begin
        SubOp := F.U1;
        I := F.U2;
        case SubOp of
          $15..$19:
            begin
              V := F.Load(I);
              CheckLocalKind(V, SubOp - $15, False);
              F.Push(V);
            end;
          $36..$3A:
            begin
              V := F.Pop;
              CheckLocalKind(V, SubOp - $36, True);
              F.Store(I, V);
            end;
          $84:
            begin
              J := F.S2;
              F.Store(I, TJVMValue.Int(F.Load(I).AsInt + J));
            end;
          $A9:
            begin
              V := F.Load(I);
              if V.Kind <> TJVMKind.ReturnAddress then
                raise EJVMFormatError.Create('wide ret requires a return address');
              F.Jump(V.Bits);
            end;
        else
          raise EJVMUnsupported.Create('Unsupported wide instruction');
        end;
      end;
    $C5:
      begin
        Descriptor := F.Method.Owner.ClassName(F.U2);
        I := F.U1;
        J := 1;
        FLinker.ResolveClass(Descriptor, F.Method.Owner);
        while (J <= Length(Descriptor)) and (Descriptor[J] = '[') do
          Inc(J);
        if (I = 0) or (I >= J) then
          raise EJVMFormatError.Create('Invalid multianewarray dimensions');
        SetLength(Dimensions, I);
        for K := I - 1 downto 0 do
        begin
          Dimensions[K] := F.Pop.AsInt;
          if Dimensions[K] < 0 then
            RaiseJava('java/lang/NegativeArraySizeException');
        end;
        F.Push(TJVMValue.Ref(MultiArray(Descriptor, 0)));
      end;
    $C6, $C7:
      begin
        I := F.Pop.AsRef;
        Branch((I = 0) = (Op = $C6));
      end;
    $C8:
      begin
        I := F.S4;
        F.Jump(Int64(F.InstructionPC) + I);
      end;
    $C9:
      begin
        I := F.S4;
        V.Kind := TJVMKind.ReturnAddress;
        V.Bits := F.PC;
        F.Push(V);
        F.Jump(Int64(F.InstructionPC) + I);
      end;
  else
    raise EJVMUnsupported.CreateFmt('Bytecode $%.2x is not implemented', [Op]);
  end;
end;

function TJVM.IsObjectAlive(Reference: Integer): Boolean;
begin
  Result := FHeap.ContainsKey(Reference);
end;

procedure TJVM.YieldToHost;
begin
  FYieldToHost := True;
end;

end.

