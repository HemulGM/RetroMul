unit PS2.IOP.Kernel;

// High-level IOP kernel for IOP modules (IRX) that run as code: threads with
// IOP priorities, semaphores, event flags, message boxes, memory pools,
// interrupt handlers, VBlank handlers, alarms and hardware-timer handlers
// (all run on the IOP CPU in an interrupt context with their own stack),
// module loading and start (loadcore/modload), library linking (guest
// export tables; system libraries become HLE traps) and the module side of
// SIF RPC (registered servers, request queues, sceSifRpcLoop) and SIF
// commands. The library calls themselves are in PS2.IOP.Libs.
// Behaviour follows Play! (BSD-2: IopBios, Iop_Thbase, Iop_SifCmd...) and
// the ps2sdk interfaces (AFL 2.0); no Sony code.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, PS2.Types,
  PS2.Scheduler, PS2.SIF, PS2.IOP.CPU, PS2.IOP.Hardware, PS2.IOP.HLE, PS2.IOP.FileIO, PS2.IOP.CDVD,
  PS2.IOP.Loader;

const
  IOPMaxThreads = 128;
  IOPMaxObjects = 128;
  // Kernel area: return traps, the interrupt stack, copied SIF commands.
  IOPTrapArea = $00001000;
  IOPIntrStackTop = $0000EFF0;
  IOPCmdCopies = $0000F000;

  // Return traps (kernel trap codes, bit 25 set).
  IOPTrapKernel = $2000000;
  IOPRetIntr = 0;
  IOPRetThreadExit = 1;
  IOPRetModuleStart = 2;
  IOPRetRpc = 3;

  // Thread states and waits.
  ThDormant = 0;
  ThReady = 1;
  ThWaiting = 2;
  WaitNone = 0;
  WaitSleep = 1;
  WaitDelay = 2;
  WaitSema = 3;
  WaitEvent = 4;
  WaitMbx = 5;
  WaitRpc = 6;
  WaitVblankStart = 7;
  WaitVblankEnd = 8;
  WaitCd = 9;
  WaitModule = 10;

  // Interrupt-context calls.
  CallIntr = 0;
  CallVblank = 1;
  CallAlarm = 2;
  CallTimer = 3;
  CallCd = 4;
  CallCmd = 5;

type
  TIOPThread = record
    Used: Boolean;
    State, Wait: Byte;
    IntrOff: Boolean;
    Attr, Option, Entry, StackBase, StackSize, GP: Cardinal;
    InitPriority, Priority: Integer;
    WaitId: Integer;
    WaitA, WaitB, WaitC: Cardinal;
    WakeAt: Int64;
    WakeupCount: Integer;
    ReadySeq: Int64;
    RpcQueue: Cardinal;
    RpcServer: Integer;
    RpcReturn: Cardinal;
    Module: Integer;
    Ctx: TIOPContext;
  end;

  PIOPThread = ^TIOPThread;

  TIOPSema = record
    Used: Boolean;
    Attr, Option: Cardinal;
    Count, Max, Init: Integer;
  end;

  TIOPEventFlag = record
    Used: Boolean;
    Attr, Option, Bits, Init: Cardinal;
  end;

  TIOPMbx = record
    Used: Boolean;
    Attr, Option, Head, Tail: Cardinal;
    Count: Integer;
  end;

  TIOPPool = record
    Used: Boolean;
    Attr, Option, BlockSize, Blocks: Cardinal;
  end;

  TIOPIntrHandler = record
    Registered, Enabled: Boolean;
    Mode, Handler, Arg: Cardinal;
  end;

  TIOPVblankHandler = record
    Used: Boolean;
    Edge, Priority: Integer;
    Handler, Arg: Cardinal;
  end;

  TIOPAlarm = record
    Used: Boolean;
    At: Int64;
    Handler, Arg, Clock: Cardinal;
  end;

  TIOPHardTimer = record
    Used, Running: Boolean;
    Source, Prescale, Compare, Handler, Arg: Cardinal;
    Next: Int64;
  end;

  TIOPLibrary = record
    Used: Boolean;
    Name: array[0..7] of AnsiChar;
    Table: Cardinal;
  end;

  TIOPModule = record
    Used, Started: Boolean;
    Name: array[0..47] of AnsiChar;
    Base, Size, Entry, GP, Args: Cardinal;
    Version: Word;
    Waiter: Integer;
    ResultPtr: Cardinal;
    Token: array[0..127] of Byte;
    TokenLen: Integer;
  end;

  PIOPModule = ^TIOPModule;

  TIOPServer = record
    Used: Boolean;
    SID, SD, Func, Buff, CFunc, CBuff, Queue: Cardinal;
  end;

  TIOPRequest = record
    Server: Integer;
    Busy: Boolean;
    Packet: array[0..63] of Byte;
  end;

  TIOPQueue = record
    Used: Boolean;
    QD: Cardinal;
    Thread: Integer;
  end;

  TIOPCmdHandler = record
    Used: Boolean;
    Cid, Handler, Data: Cardinal;
  end;

  TIOPCall = record
    Kind: Integer;
    Func, A0, A1, A2, A3, Tag: Cardinal;
  end;

  TPS2IOPModuleDone = procedure(const Token: TBytes; ModuleId, Result: Integer) of object;
  TPS2IOPMarkEE = procedure(Address, Size: Cardinal) of object;

  TPS2IOPKernel = class
  private
    FScheduler: TPS2Scheduler;
    FReadySeq: Int64;
    // A thread may be ready (cleared when a scan finds none).
    FMaybeReady: Boolean;
    FCmdSlot: Integer;
    FWarned: TDictionary<Cardinal, Boolean>;
    FBindRetries: TDictionary<Cardinal, Integer>;
    procedure Trap(Code: Cardinal);
    procedure KernelReturn(Kind: Integer);
    procedure CPUException(Code: Integer; PC: Cardinal);
    procedure WriteTraps;
    procedure StartCall(const C: TIOPCall);
    procedure FinishCall(const C: TIOPCall; Value: Cardinal);
    procedure LinkImports(Table: Cardinal);
    procedure RelinkPending;
    function FindLibrary(const Name: string): Integer;
    function ExportAddress(Lib, Fn: Integer): Cardinal;
    procedure ListField<T>(State: TStateArchive; L: TList<T>);
    procedure FindImportTables(Base, Size: Cardinal);
  public
    CPU: TIOPCPU;
    Hardware: TPS2IOPHardware;
    SIF: TPS2SIF;
    Allocator: TPS2IOPAllocator;
    IOMan: TPS2IOMan;
    DiscFS: TPS2DiscFileSystem;
    RAM, EERAM: PByte;
    Threads: array[1..IOPMaxThreads] of TIOPThread;
    Semas: array[1..IOPMaxObjects] of TIOPSema;
    Events: array[1..IOPMaxObjects] of TIOPEventFlag;
    Mbxs: array[1..IOPMaxObjects] of TIOPMbx;
    Pools: array[1..IOPMaxObjects] of TIOPPool;
    Intr: array[0..63] of TIOPIntrHandler;
    Vblanks: array[0..15] of TIOPVblankHandler;
    Alarms: array[0..63] of TIOPAlarm;
    Timers: array[0..5] of TIOPHardTimer;
    Libraries: array[0..63] of TIOPLibrary;
    Modules: array[1..64] of TIOPModule;
    Servers: array[0..63] of TIOPServer;
    Queues: array[0..31] of TIOPQueue;
    CmdHandlers: array[0..63] of TIOPCmdHandler;
    SifRegs: array[0..31] of Cardinal;
    Requests: TList<TIOPRequest>;
    Calls: TList<TIOPCall>;
    PendingImports: TList<Cardinal>;
    // Running context: thread id, 0 in an interrupt-context call, -1 idle.
    Current: Integer;
    InCall: Boolean;
    CurrentCall: TIOPCall;
    InVblank: Boolean;
    // CD: busy until CdDoneAt (EE cycles), then CdCallback.
    CdDoneAt: Int64;
    CdCallback: Cardinal;
    CdLastCommand: Integer;
    CdStreamLBA: Int64;
    DmaId: Cardinal;
    Log: TStrings;
    OnTTY: TProc<string>;
    OnModuleDone: TPS2IOPModuleDone;
    OnMarkEE: TPS2IOPMarkEE;
    constructor Create(Scheduler: TPS2Scheduler; ASIF: TPS2SIF; AAllocator: TPS2IOPAllocator; AIOMan: TPS2IOMan;
      ADiscFS: TPS2DiscFileSystem; AEERAM, AIOPRAM: PByte);
    destructor Destroy; override;
    procedure Reset;
    // Runs the IOP up to the EE time Target (EE cycles).
    procedure Run(Target: Int64);
    // Something to run (a ready thread or a pending interrupt-context call).
    function Active: Boolean;
    procedure TimerEvent;
    procedure ScheduleTimers;
    procedure VBlank(Start: Boolean);
    procedure RaiseInterrupt(Line: Integer);
    // Threads.
    function CreateThread(Attr, Entry, Priority, StackSize, Option, GP: Cardinal): Integer;
    procedure StartThread(Id: Integer; A0, A1: Cardinal);
    procedure MakeReady(Id: Integer);
    // Blocks the running thread (it continues at the trap's return address
    // with v0 set by Wake).
    procedure Block(Wait: Byte; WaitId: Integer = 0; A: Cardinal = 0; B: Cardinal = 0; C: Cardinal = 0);
    procedure Wake(Id: Integer; Value: Cardinal);
    procedure Reschedule;
    procedure DispatchCalls;
    procedure QueueCall(Kind: Integer; Func, A0, A1, A2, A3, Tag: Cardinal);
    function CurrentThread: Integer;
    procedure DeleteThread(Id: Integer);
    procedure CheckSemaWaiters(Id: Integer);
    procedure CheckEventWaiters(Id: Integer);
    procedure CheckMbxWaiters(Id: Integer);
    function EventMatches(Bits, Want, Mode: Cardinal): Boolean;
    // Memory helpers (IOP RAM, mirrored).
    function R8(A: Cardinal): Byte; inline;
    function R16(A: Cardinal): Word; inline;
    function R32(A: Cardinal): Cardinal; inline;
    procedure W8(A: Cardinal; V: Byte); inline;
    procedure W16(A: Cardinal; V: Word); inline;
    procedure W32(A: Cardinal; V: Cardinal); inline;
    function ReadString(A: Cardinal; Max: Integer = 1024): string;
    function Arg(Index: Integer): Cardinal;
    procedure Print(const Text: string);
    procedure Warn(const Text: string);
    // Modules.
    function IsHLEModule(const Path, Name: string): Boolean;
    // Loads an IRX image: the module index (>0) or an error (<0).
    function LoadModule(const Data: TBytes; const Path: string): Integer;
    // Starts a loaded module in a thread; on return the EE request (Token)
    // or the waiting IOP thread gets the result.
    procedure StartModule(Index: Integer; const Path: string; const Args: TBytes; const Token: TBytes;
      Waiter: Integer; ResultPtr: Cardinal);
    function RegisterLibrary(Table: Cardinal): Integer;
    // SIF, module side.
    function GuestBind(const P: TBytes): Boolean;
    procedure GuestCommand(Kind: Cardinal; const P: TBytes);
    procedure RegisterServer(SD, SID, Func, Buff, CFunc, CBuff, QD: Cardinal);
    function NextRequest(QD: Cardinal): Integer;
    procedure StartRequest(Thread, Index: Integer);
    // True when Key was logged before (marks it).
    function Logged(Key: Cardinal): Boolean;
    // An ELF image in IOP memory (extent from its headers).
    function ImageAt(Address: Cardinal): TBytes;
    procedure SetQueue(QD: Cardinal; Thread: Integer);
    // sceSifExecRequest: runs the taken request of server SD in the
    // current thread and returns to the caller.
    procedure ExecRequest(SD: Cardinal);
    function TakeRequest(QD: Cardinal): Cardinal;
    procedure CopyToEE(Src, Dest: Cardinal; Size: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

function IOPTrapWord(Kind: Cardinal): Cardinal;

implementation

uses
  PS2.IOP.Libs;

function IOPTrapWord(Kind: Cardinal): Cardinal;
begin
  Result := IOPTrapBase or IOPTrapKernel or Kind;
end;

function TrapAddress(Kind: Cardinal): Cardinal;
begin
  Result := IOPTrapArea + Kind * 8;
end;

{ TPS2IOPKernel }

constructor TPS2IOPKernel.Create(Scheduler: TPS2Scheduler; ASIF: TPS2SIF; AAllocator: TPS2IOPAllocator;
  AIOMan: TPS2IOMan; ADiscFS: TPS2DiscFileSystem; AEERAM, AIOPRAM: PByte);
begin
  inherited Create;
  FScheduler := Scheduler;
  SIF := ASIF;
  Allocator := AAllocator;
  IOMan := AIOMan;
  DiscFS := ADiscFS;
  EERAM := AEERAM;
  RAM := AIOPRAM;
  CPU := TIOPCPU.Create(RAM);
  CPU.OnTrap := Trap;
  CPU.OnException := CPUException;
  Hardware := TPS2IOPHardware.Create(Scheduler, RAM, @CPU.Cycles);
  Hardware.OnInterrupt := RaiseInterrupt;
  CPU.OnRead := Hardware.Read;
  CPU.OnWrite := Hardware.Write;
  Requests := TList<TIOPRequest>.Create;
  Calls := TList<TIOPCall>.Create;
  PendingImports := TList<Cardinal>.Create;
  FWarned := TDictionary<Cardinal, Boolean>.Create;
  FBindRetries := TDictionary<Cardinal, Integer>.Create;
  Reset;
end;

destructor TPS2IOPKernel.Destroy;
begin
  FBindRetries.Free;
  FWarned.Free;
  PendingImports.Free;
  Calls.Free;
  Requests.Free;
  Hardware.Free;
  CPU.Free;
  inherited;
end;

procedure TPS2IOPKernel.Reset;
begin
  var Cycles := CPU.Cycles;
  CPU.Reset;
  CPU.Cycles := Cycles;
  Hardware.Reset;
  FillChar(Threads, SizeOf(Threads), 0);
  FillChar(Semas, SizeOf(Semas), 0);
  FillChar(Events, SizeOf(Events), 0);
  FillChar(Mbxs, SizeOf(Mbxs), 0);
  FillChar(Pools, SizeOf(Pools), 0);
  FillChar(Intr, SizeOf(Intr), 0);
  FillChar(Vblanks, SizeOf(Vblanks), 0);
  FillChar(Alarms, SizeOf(Alarms), 0);
  FillChar(Timers, SizeOf(Timers), 0);
  FillChar(Libraries, SizeOf(Libraries), 0);
  FillChar(Modules, SizeOf(Modules), 0);
  FillChar(Servers, SizeOf(Servers), 0);
  FillChar(Queues, SizeOf(Queues), 0);
  FillChar(CmdHandlers, SizeOf(CmdHandlers), 0);
  FillChar(SifRegs, SizeOf(SifRegs), 0);
  Requests.Clear;
  Calls.Clear;
  PendingImports.Clear;
  FWarned.Clear;
  FBindRetries.Clear;
  Current := -1;
  InCall := False;
  InVblank := False;
  CdDoneAt := 0;
  CdCallback := 0;
  CdLastCommand := 0;
  CdStreamLBA := 0;
  DmaId := 1;
  FReadySeq := 0;
  FCmdSlot := 0;
  WriteTraps;
  FScheduler.Cancel(TPS2Event.IOPTimers);
end;

procedure TPS2IOPKernel.WriteTraps;
begin
  for var K := 0 to 7 do
  begin
    W32(TrapAddress(K), IOPTrapWord(K));
    W32(TrapAddress(K) + 4, 0);
  end;
end;

function TPS2IOPKernel.R8(A: Cardinal): Byte;
begin
  Result := RAM[A and PS2IOPRAMMask];
end;

function TPS2IOPKernel.R16(A: Cardinal): Word;
begin
  Result := PWord(RAM + (A and (PS2IOPRAMMask and not 1)))^;
end;

function TPS2IOPKernel.R32(A: Cardinal): Cardinal;
begin
  Result := PCardinal(RAM + (A and (PS2IOPRAMMask and not 3)))^;
end;

procedure TPS2IOPKernel.W8(A: Cardinal; V: Byte);
begin
  RAM[A and PS2IOPRAMMask] := V;
end;

procedure TPS2IOPKernel.W16(A: Cardinal; V: Word);
begin
  PWord(RAM + (A and (PS2IOPRAMMask and not 1)))^ := V;
end;

procedure TPS2IOPKernel.W32(A: Cardinal; V: Cardinal);
begin
  PCardinal(RAM + (A and (PS2IOPRAMMask and not 3)))^ := V;
end;

function TPS2IOPKernel.ReadString(A: Cardinal; Max: Integer): string;
begin
  var B: TBytes;
  SetLength(B, 0);
  for var K := 0 to Max - 1 do
  begin
    var C := R8(A + Cardinal(K));
    if C = 0 then
      Break;
    B := B + [C];
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

// Argument Index of the current call (O32: a0..a3, then the stack).
function TPS2IOPKernel.Arg(Index: Integer): Cardinal;
begin
  if Index < 4 then
    Result := CPU.R[IOPRegA0 + Index]
  else
    Result := R32(Add32(CPU.R[IOPRegSP], Cardinal(16 + (Index - 4) * 4)));
end;

procedure TPS2IOPKernel.Print(const Text: string);
begin
  if Assigned(OnTTY) then
    OnTTY(Text);
end;

procedure TPS2IOPKernel.Warn(const Text: string);
begin
  if Log <> nil then
    Log.Add('iop: ' + Text);
end;

procedure TPS2IOPKernel.CPUException(Code: Integer; PC: Cardinal);
begin
  Warn(Format('exception %d at %.8x (thread %d)', [Code, PC, Current]));
  // A broken context: park it.
  if Current > 0 then
  begin
    Threads[Current].State := ThDormant;
    Current := -1;
  end
  else if Current = 0 then
  begin
    InCall := False;
    Current := -1;
  end;
  CPU.Stop;
  Reschedule;
end;

function TPS2IOPKernel.CurrentThread: Integer;
begin
  if Current > 0 then
    Result := Current
  else
    Result := 0;
end;

function TPS2IOPKernel.Active: Boolean;
begin
  Result := (Current >= 0) or ((Calls.Count > 0) and not InCall) or FMaybeReady;
end;

procedure TPS2IOPKernel.Run(Target: Int64);
begin
  var IOPTarget := Target div 8;
  if CPU.Cycles >= IOPTarget then
    Exit;
  if (Current < 0) and (Calls.Count = 0) and not FMaybeReady then
  begin
    CPU.Cycles := IOPTarget;
    Exit;
  end;
  DispatchCalls;
  // Threads woken by timers, VBlank or the CD preempt the running one.
  Reschedule;
  while CPU.Cycles < IOPTarget do
  begin
    if Current < 0 then
    begin
      CPU.Cycles := IOPTarget;
      Break;
    end;
    CPU.Run(IOPTarget);
  end;
end;

{ Threads }

function TPS2IOPKernel.CreateThread(Attr, Entry, Priority, StackSize, Option, GP: Cardinal): Integer;
begin
  for var K := 1 to IOPMaxThreads do
    if not Threads[K].Used then
    begin
      var Stack := Allocator.Allocate(Max(StackSize, $400));
      if Stack = 0 then
        Exit(-400);
      Threads[K] := Default(TIOPThread);
      Threads[K].Used := True;
      Threads[K].State := ThDormant;
      Threads[K].Attr := Attr;
      Threads[K].Option := Option;
      Threads[K].Entry := Entry;
      Threads[K].StackBase := Stack;
      Threads[K].StackSize := (Max(StackSize, $400) + 255) and not Cardinal(255);
      Threads[K].GP := GP;
      Threads[K].InitPriority := Integer(Priority);
      Threads[K].Priority := Integer(Priority);
      Threads[K].RpcServer := -1;
      Threads[K].Module := 0;
      // Stacks start filled like the IOP kernel does (FFh).
      FillChar((RAM + (Stack and PS2IOPRAMMask))^, Threads[K].StackSize, $FF);
      Exit(K);
    end;
  Result := -400;
end;

procedure TPS2IOPKernel.StartThread(Id: Integer; A0, A1: Cardinal);
begin
  var T: PIOPThread := @Threads[Id];
  T.Ctx := Default(TIOPContext);
  T.Ctx.PC := T.Entry;
  T.Ctx.NextPC := 0;
  T.Ctx.R[IOPRegA0] := A0;
  T.Ctx.R[IOPRegA1] := A1;
  T.Ctx.R[IOPRegGP] := T.GP;
  T.Ctx.R[IOPRegSP] := T.StackBase + T.StackSize - 16;
  T.Ctx.R[IOPRegFP] := T.Ctx.R[IOPRegSP];
  T.Ctx.R[IOPRegRA] := TrapAddress(IOPRetThreadExit);
  T.Priority := T.InitPriority;
  T.Wait := WaitNone;
  T.WakeupCount := 0;
  T.IntrOff := False;
  MakeReady(Id);
end;

procedure TPS2IOPKernel.MakeReady(Id: Integer);
begin
  Threads[Id].State := ThReady;
  Threads[Id].Wait := WaitNone;
  FMaybeReady := True;
  Inc(FReadySeq);
  Threads[Id].ReadySeq := FReadySeq;
end;

procedure TPS2IOPKernel.Block(Wait: Byte; WaitId: Integer; A, B, C: Cardinal);
begin
  if Current <= 0 then
    Exit;
  var T: PIOPThread := @Threads[Current];
  T.State := ThWaiting;
  T.Wait := Wait;
  T.WaitId := WaitId;
  T.WaitA := A;
  T.WaitB := B;
  T.WaitC := C;
end;

procedure TPS2IOPKernel.Wake(Id: Integer; Value: Cardinal);
begin
  if (Id <= 0) or (Id > IOPMaxThreads) or not Threads[Id].Used or (Threads[Id].State <> ThWaiting) then
    Exit;
  Threads[Id].Ctx.R[IOPRegV0] := Value;
  MakeReady(Id);
end;

procedure TPS2IOPKernel.DeleteThread(Id: Integer);
begin
  if (Id <= 0) or (Id > IOPMaxThreads) or not Threads[Id].Used then
    Exit;
  Allocator.Release(Threads[Id].StackBase);
  Threads[Id].Used := False;
  Threads[Id].State := ThDormant;
end;

procedure TPS2IOPKernel.Reschedule;
begin
  if InCall then
    Exit;
  var Best := -1;
  for var K := 1 to IOPMaxThreads do
    if Threads[K].Used and (Threads[K].State = ThReady) then
      if (Best < 0) or (Threads[K].Priority < Threads[Best].Priority) or
        ((Threads[K].Priority = Threads[Best].Priority) and (Threads[K].ReadySeq < Threads[Best].ReadySeq)) then
        Best := K;
  if Best < 0 then
    FMaybeReady := False;
  // The running thread keeps the CPU against equal priorities.
  if (Current > 0) and (Best > 0) and (Best <> Current) and Threads[Current].Used and
    (Threads[Current].State = ThReady) and (Threads[Current].Priority <= Threads[Best].Priority) then
    Best := Current;
  if Best = Current then
  begin
    if Best < 0 then
      CPU.Stop;
    Exit;
  end;
  if (Current > 0) and Threads[Current].Used then
    CPU.SaveContext(Threads[Current].Ctx);
  Current := Best;
  if Best > 0 then
    CPU.LoadContext(Threads[Best].Ctx)
  else
    CPU.Stop;
end;

procedure TPS2IOPKernel.QueueCall(Kind: Integer; Func, A0, A1, A2, A3, Tag: Cardinal);
begin
  var C: TIOPCall;
  C.Kind := Kind;
  C.Func := Func;
  C.A0 := A0;
  C.A1 := A1;
  C.A2 := A2;
  C.A3 := A3;
  C.Tag := Tag;
  Calls.Add(C);
end;

procedure TPS2IOPKernel.DispatchCalls;
begin
  if InCall or (Calls.Count = 0) then
    Exit;
  if (Current > 0) and Threads[Current].IntrOff then
    Exit;
  if (Current > 0) and Threads[Current].Used then
    CPU.SaveContext(Threads[Current].Ctx);
  InCall := True;
  Current := 0;
  var C := Calls[0];
  Calls.Delete(0);
  StartCall(C);
end;

procedure TPS2IOPKernel.StartCall(const C: TIOPCall);
begin
  CurrentCall := C;
  CPU.SetPC(C.Func);
  CPU.R[IOPRegA0] := C.A0;
  CPU.R[IOPRegA1] := C.A1;
  CPU.R[IOPRegA2] := C.A2;
  CPU.R[IOPRegA3] := C.A3;
  CPU.R[IOPRegSP] := IOPIntrStackTop;
  CPU.R[IOPRegRA] := TrapAddress(IOPRetIntr);
end;

procedure TPS2IOPKernel.FinishCall(const C: TIOPCall; Value: Cardinal);
begin
  case C.Kind of
    CallVblank:
      // A handler returning 0 is removed.
      if (Value = 0) and (C.Tag <= High(Vblanks)) then
        Vblanks[C.Tag].Used := False;
    CallAlarm:
      if C.Tag <= High(Alarms) then
      begin
        if Value = 0 then
          Alarms[C.Tag].Used := False
        else
        begin
          Alarms[C.Tag].Clock := Value;
          Alarms[C.Tag].At := FScheduler.Now + Int64(Value) * 8;
        end;
        ScheduleTimers;
      end;
  end;
end;

procedure TPS2IOPKernel.KernelReturn(Kind: Integer);
begin
  case Kind of
    IOPRetIntr:
      begin
        FinishCall(CurrentCall, CPU.R[IOPRegV0]);
        if Calls.Count > 0 then
        begin
          var C := Calls[0];
          Calls.Delete(0);
          StartCall(C);
          Exit;
        end;
        InCall := False;
        Current := -1;
        Reschedule;
      end;
    IOPRetThreadExit:
      if Current > 0 then
      begin
        Threads[Current].State := ThDormant;
        Current := -1;
        Reschedule;
      end;
    IOPRetModuleStart:
      if Current > 0 then
      begin
        var Id := Current;
        var M := Threads[Id].Module;
        var Value := CPU.R[IOPRegV0];
        DeleteThread(Id);
        Current := -1;
        if (M > 0) and Modules[M].Used then
        begin
          Modules[M].Started := True;
          if Modules[M].Args <> 0 then
            Allocator.Release(Modules[M].Args);
          Modules[M].Args := 0;
          if (Value and 3) = 1 then
          begin
            // No resident end: the module goes away.
            Allocator.Release(Modules[M].Base);
            Modules[M].Used := False;
          end;
          if Modules[M].Waiter > 0 then
          begin
            if Modules[M].ResultPtr <> 0 then
              W32(Modules[M].ResultPtr, Value);
            Wake(Modules[M].Waiter, Cardinal(M));
          end
          else if (Modules[M].TokenLen > 0) and Assigned(OnModuleDone) then
          begin
            var Token: TBytes;
            SetLength(Token, Modules[M].TokenLen);
            Move(Modules[M].Token[0], Token[0], Modules[M].TokenLen);
            OnModuleDone(Token, M, Integer(Value));
          end;
          Modules[M].TokenLen := 0;
          Modules[M].Waiter := 0;
        end;
        Reschedule;
      end;
    IOPRetRpc:
      if Current > 0 then
      begin
        var T: PIOPThread := @Threads[Current];
        var S := T.RpcServer;
        if (S >= 0) and (Requests.Count > 0) then
        begin
          // The request being served is the first one for this server.
          for var K := 0 to Requests.Count - 1 do
            if Requests[K].Server = S then
            begin
              var Req := Requests[K];
              var P: TBytes;
              SetLength(P, 64);
              Move(Req.Packet[0], P[0], 64);
              Requests.Delete(K);
              var RecvSize := Integer(PacketU32(P, 44));
              var Reply: TBytes := nil;
              var Src := CPU.R[IOPRegV0];
              if (RecvSize > 0) and (Src <> 0) then
              begin
                SetLength(Reply, RecvSize);
                for var B := 0 to RecvSize - 1 do
                  Reply[B] := R8(Src + Cardinal(B));
              end;
              SIF.ReplyCall(P, Reply);
              Break;
            end;
        end;
        T.RpcServer := -1;
        if T.RpcQueue <> 0 then
        begin
          // sceSifRpcLoop: the next request or wait for one.
          var Next := NextRequest(T.RpcQueue);
          if Next >= 0 then
            StartRequest(Current, Next)
          else
          begin
            CPU.SaveContext(T.Ctx);
            Block(WaitRpc, 0, T.RpcQueue);
            Reschedule;
          end;
        end
        else
        begin
          CPU.R[IOPRegRA] := T.RpcReturn;
          CPU.SetPC(T.RpcReturn);
        end;
      end;
  end;
end;

procedure TPS2IOPKernel.Trap(Code: Cardinal);
begin
  if (Code and IOPTrapKernel) <> 0 then
    KernelReturn(Integer(Code and $FFFF))
  else
  begin
    IOPLibraryCall(Self, Integer((Code shr 16) and $1FF), Integer(Code and $FFFF));
    // A blocked thread continues at the return address once woken.
    if (Current > 0) and (Threads[Current].State <> ThReady) then
      CPU.SaveContext(Threads[Current].Ctx);
    Reschedule;
  end;
  if not InCall then
    DispatchCalls;
end;

{ Interrupts, VBlank, timers }

procedure TPS2IOPKernel.RaiseInterrupt(Line: Integer);
begin
  if (Line < 0) or (Line > High(Intr)) then
    Exit;
  if Intr[Line].Registered and Intr[Line].Enabled then
    QueueCall(CallIntr, Intr[Line].Handler, Intr[Line].Arg, 0, 0, 0, Cardinal(Line));
end;

procedure TPS2IOPKernel.VBlank(Start: Boolean);
begin
  InVblank := Start;
  for var K := 1 to IOPMaxThreads do
    if Threads[K].Used and (Threads[K].State = ThWaiting) then
      if (Start and (Threads[K].Wait = WaitVblankStart)) or (not Start and (Threads[K].Wait = WaitVblankEnd)) then
        Wake(K, 0);
  var Edge := Ord(not Start);
  for var K := 0 to High(Vblanks) do
    if Vblanks[K].Used and (Vblanks[K].Edge = Edge) then
      QueueCall(CallVblank, Vblanks[K].Handler, Vblanks[K].Arg, 0, 0, 0, Cardinal(K));
  if Start then
    RaiseInterrupt(IOPIntVBlank)
  else
    RaiseInterrupt(IOPIntEVBlank);
end;

procedure TPS2IOPKernel.ScheduleTimers;
begin
  var Next := PS2Never;
  for var K := 1 to IOPMaxThreads do
    if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitDelay) then
      Next := Min(Next, Threads[K].WakeAt);
  for var K := 0 to High(Alarms) do
    if Alarms[K].Used then
      Next := Min(Next, Alarms[K].At);
  for var K := 0 to High(Timers) do
    if Timers[K].Used and Timers[K].Running and (Timers[K].Handler <> 0) then
      Next := Min(Next, Timers[K].Next);
  if CdDoneAt > 0 then
    Next := Min(Next, CdDoneAt);
  if Next = PS2Never then
    FScheduler.Cancel(TPS2Event.IOPTimers)
  else
    FScheduler.Schedule(TPS2Event.IOPTimers, Next);
end;

procedure TPS2IOPKernel.TimerEvent;
begin
  var Now := FScheduler.Now;
  for var K := 1 to IOPMaxThreads do
    if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitDelay) and
      (Threads[K].WakeAt <= Now) then
      Wake(K, 0);
  for var K := 0 to High(Alarms) do
    if Alarms[K].Used and (Alarms[K].At <= Now) then
    begin
      // Until the handler returns the next interval.
      Alarms[K].At := PS2Never;
      QueueCall(CallAlarm, Alarms[K].Handler, Alarms[K].Arg, 0, 0, 0, Cardinal(K));
    end;
  for var K := 0 to High(Timers) do
    if Timers[K].Used and Timers[K].Running and (Timers[K].Handler <> 0) and (Timers[K].Next <= Now) then
    begin
      Timers[K].Next := Now + Int64(Max(Timers[K].Compare, 1)) * Max(Timers[K].Prescale, 1) * 8;
      QueueCall(CallTimer, Timers[K].Handler, Timers[K].Arg, 0, 0, 0, Cardinal(K));
    end;
  if (CdDoneAt > 0) and (CdDoneAt <= Now) then
  begin
    CdDoneAt := 0;
    for var K := 1 to IOPMaxThreads do
      if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitCd) then
        Wake(K, 0);
    if CdCallback <> 0 then
      QueueCall(CallCd, CdCallback, Cardinal(CdLastCommand), 0, 0, 0, 0);
    RaiseInterrupt(IOPIntCDVD);
  end;
  ScheduleTimers;
end;

{ Synchronization objects }

function TPS2IOPKernel.EventMatches(Bits, Want, Mode: Cardinal): Boolean;
begin
  // Mode bit 0: OR (any), else AND (all).
  if (Mode and 1) <> 0 then
    Result := (Bits and Want) <> 0
  else
    Result := (Bits and Want) = Want;
end;

procedure TPS2IOPKernel.CheckSemaWaiters(Id: Integer);
begin
  while Semas[Id].Count > 0 do
  begin
    var Best := -1;
    for var K := 1 to IOPMaxThreads do
      if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitSema) and
        (Threads[K].WaitId = Id) then
        if (Best < 0) or (((Semas[Id].Attr and 1) <> 0) and (Threads[K].Priority < Threads[Best].Priority)) then
          Best := K;
    if Best < 0 then
      Break;
    Dec(Semas[Id].Count);
    Wake(Best, 0);
  end;
end;

procedure TPS2IOPKernel.CheckEventWaiters(Id: Integer);
begin
  for var K := 1 to IOPMaxThreads do
    if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitEvent) and
      (Threads[K].WaitId = Id) and EventMatches(Events[Id].Bits, Threads[K].WaitA, Threads[K].WaitB) then
    begin
      if Threads[K].WaitC <> 0 then
        W32(Threads[K].WaitC, Events[Id].Bits);
      // Mode bit 4: clear the bits on release (all of them).
      if (Threads[K].WaitB and $10) <> 0 then
        Events[Id].Bits := 0;
      Wake(K, 0);
    end;
end;

procedure TPS2IOPKernel.CheckMbxWaiters(Id: Integer);
begin
  for var K := 1 to IOPMaxThreads do
  begin
    if Mbxs[Id].Count = 0 then
      Break;
    if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitMbx) and
      (Threads[K].WaitId = Id) then
    begin
      var Msg := Mbxs[Id].Head;
      Mbxs[Id].Head := R32(Msg);
      Dec(Mbxs[Id].Count);
      if Mbxs[Id].Count = 0 then
        Mbxs[Id].Tail := 0;
      if Threads[K].WaitA <> 0 then
        W32(Threads[K].WaitA, Msg);
      Wake(K, 0);
    end;
  end;
end;

{ Modules and libraries }

function TPS2IOPKernel.IsHLEModule(const Path, Name: string): Boolean;
const
  // Pad drivers built on SIO2 (SIO2MAN, DBCMAN, SIO2D, DS2U_D, MTAPMAN) run
  // as IOP code against the emulated SIO2; PADMAN stays high level.
  Files: array[0..40] of string = ('PADMAN', 'XPADMAN', 'MCMAN', 'MCSERV', 'XMCMAN', 'XMCSERV', 'MCMANO', 'CDVDMAN',
    'CDVDFSV', 'FILEIO', 'IOMAN', 'IOMANX', 'DEV9', 'ATAD', 'HDD', 'PFS', 'USBD', 'SMAP', 'INET', 'INETCTL',
    'NETCNF', 'NETCNFIF', 'PPP', 'PPPOE', 'SECRMAN', 'SECRSIF', 'EESYNC', 'RMMAN', 'RMMAN2', 'SYSCLIB', 'LOADCORE',
    'SIFMAN', 'SIFCMD', 'INTRMAN', 'SYSMEM', 'MODLOAD', 'TIMEMANI', 'USBHDFSD', 'CLEARSPU', 'XSIO2MAN', 'XMTAPMAN');
  Names: array[0..12] of string = ('padman', 'mcman', 'mcserv', 'cdvd_ee_driver', 'cdvd_driver',
    'IO/File_Manager', 'FILEIO_service', 'dev9', 'atad_driver', 'hdd_driver', 'pfs_driver', 'Smap_driver',
    'USB_driver');
begin
  var Base := ExtractFileName(Path.Replace('/', '\')).ToUpper;
  var Semi := Base.IndexOf(';');
  if Semi >= 0 then
    Base := Base.Substring(0, Semi);
  if Base.EndsWith('.IRX') then
    Base := Base.Substring(0, Length(Base) - 4);
  var Colon := Base.IndexOf(':');
  if Colon >= 0 then
    Base := Base.Substring(Colon + 1);
  for var F in Files do
    if Base = F then
      Exit(True);
  for var N in Names do
    if SameText(Name, N) then
      Exit(True);
  Result := False;
end;

function TPS2IOPKernel.FindLibrary(const Name: string): Integer;
begin
  for var K := 0 to High(Libraries) do
    if Libraries[K].Used and (string(Libraries[K].Name) = Name) then
      Exit(K);
  Result := -1;
end;

function TPS2IOPKernel.ExportAddress(Lib, Fn: Integer): Cardinal;
begin
  Result := R32(Libraries[Lib].Table + 20 + Cardinal(Fn) * 4);
end;

procedure TPS2IOPKernel.LinkImports(Table: Cardinal);
begin
  var Name := TableName(RAM, Table);
  var HLE := IOPLibraryIndex(Name);
  var Guest := -1;
  if HLE < 0 then
  begin
    Guest := FindLibrary(Name);
    if Guest < 0 then
    begin
      if not PendingImports.Contains(Table) then
        PendingImports.Add(Table);
      Warn('import ' + Name + ' waits for its library');
      Exit;
    end;
  end;
  var Stub := Table + 20;
  for var K := 0 to 1023 do
  begin
    var W0 := R32(Stub);
    var W1 := R32(Stub + 4);
    if (W0 = 0) and (W1 = 0) then
      Break;
    var Fn: Integer;
    if (W1 shr 16) = $2400 then
      Fn := Integer(W1 and $FFFF)
    else if (W1 shr 26) = IOPTrapOpcode then
      Fn := Integer(W1 and $FFFF)
    else
      Fn := -1;
    if Fn >= 0 then
    begin
      if HLE >= 0 then
      begin
        W32(Stub, IRXStubJrRa);
        W32(Stub + 4, IOPTrapBase or (Cardinal(HLE) shl 16) or Cardinal(Fn));
      end
      else
      begin
        var Target := ExportAddress(Guest, Fn);
        W32(Stub, $08000000 or ((Target shr 2) and $3FFFFFF));
        W32(Stub + 4, Cardinal(Fn) or $24000000);
      end;
    end;
    Inc(Stub, 8);
  end;
end;

procedure TPS2IOPKernel.RelinkPending;
begin
  var Pending := PendingImports.ToArray;
  PendingImports.Clear;
  for var T in Pending do
    LinkImports(T);
end;

function TPS2IOPKernel.RegisterLibrary(Table: Cardinal): Integer;
begin
  var Name := TableName(RAM, Table);
  if (Name = '') or (R32(Table) <> IRXExportMagic) then
    Exit(-1);
  var Slot := FindLibrary(Name);
  if Slot < 0 then
    for var K := 0 to High(Libraries) do
      if not Libraries[K].Used then
      begin
        Slot := K;
        Break;
      end;
  if Slot < 0 then
    Exit(-1);
  Libraries[Slot] := Default(TIOPLibrary);
  Libraries[Slot].Used := True;
  var B := TEncoding.ANSI.GetBytes(Name);
  for var K := 0 to Min(Length(B), 8) - 1 do
    Libraries[Slot].Name[K] := AnsiChar(B[K]);
  Libraries[Slot].Table := Table;
  Warn('library ' + Name + ' registered');
  RelinkPending;
  Result := 0;
end;

procedure TPS2IOPKernel.FindImportTables(Base, Size: Cardinal);
begin
  var A := Base;
  while A + 20 < Base + Size do
  begin
    if (R32(A) = IRXImportMagic) and (R32(A + 4) = 0) then
      LinkImports(A);
    Inc(A, 4);
  end;
end;

function TPS2IOPKernel.LoadModule(const Data: TBytes; const Path: string): Integer;
var
  Info: TIRXInfo;
begin
  if not ParseIRX(Data, Info) then
    Exit(-201);
  var Slot := 0;
  for var K := 1 to High(Modules) do
    if not Modules[K].Used then
    begin
      Slot := K;
      Break;
    end;
  if Slot = 0 then
    Exit(-400);
  var Base := Allocator.Allocate(Info.MemorySize);
  if Base = 0 then
    Exit(-400);
  LoadIRX(Data, Info, RAM, Base);
  Modules[Slot] := Default(TIOPModule);
  Modules[Slot].Used := True;
  var Name := Info.Name;
  if Name = '' then
    Name := ExtractFileName(Path.Replace('/', '\'));
  var B := TEncoding.ANSI.GetBytes(Name);
  for var K := 0 to Min(Length(B), 47) - 1 do
    Modules[Slot].Name[K] := AnsiChar(B[K]);
  Modules[Slot].Base := Base;
  Modules[Slot].Size := Info.MemorySize;
  Modules[Slot].Entry := Add32(Base, Info.Entry);
  Modules[Slot].GP := Add32(Base, Info.GP);
  Modules[Slot].Version := Info.Version;
  FindImportTables(Base, Info.TextSize + Info.DataSize);
  Warn(Format('module %s (%s) at %.6x size %x entry %.6x', [Name, Path, Base, Info.MemorySize,
    Modules[Slot].Entry]));
  Result := Slot;
end;

procedure TPS2IOPKernel.StartModule(Index: Integer; const Path: string; const Args: TBytes; const Token: TBytes;
  Waiter: Integer; ResultPtr: Cardinal);
begin
  // argv[0] is the path, then the NUL-separated arguments.
  var List := TList<TBytes>.Create;
  try
    List.Add(TEncoding.ANSI.GetBytes(Path));
    var Start := 0;
    for var K := 0 to Length(Args) - 1 do
      if Args[K] = 0 then
      begin
        if K > Start then
          List.Add(Copy(Args, Start, K - Start));
        Start := K + 1;
      end;
    if Start < Length(Args) then
      List.Add(Copy(Args, Start, Length(Args) - Start));
    var Total := (List.Count + 1) * 4;
    for var S in List do
      Inc(Total, Length(S) + 1);
    var Block := Allocator.Allocate(Cardinal(Total));
    var Strings := Block + Cardinal((List.Count + 1) * 4);
    for var K := 0 to List.Count - 1 do
    begin
      W32(Block + Cardinal(K) * 4, Strings);
      for var C := 0 to Length(List[K]) - 1 do
        W8(Strings + Cardinal(C), List[K][C]);
      W8(Strings + Cardinal(Length(List[K])), 0);
      Inc(Strings, Length(List[K]) + 1);
    end;
    W32(Block + Cardinal(List.Count) * 4, 0);
    var M: PIOPModule := @Modules[Index];
    M.Args := Block;
    M.Waiter := Waiter;
    M.ResultPtr := ResultPtr;
    M.TokenLen := Min(Length(Token), Length(M.Token));
    if M.TokenLen > 0 then
      Move(Token[0], M.Token[0], M.TokenLen);
    var Id := CreateThread($02000000, M.Entry, 8, $4000, 0, M.GP);
    if Id <= 0 then
      Exit;
    Threads[Id].Module := Index;
    StartThread(Id, Cardinal(List.Count), Block);
    Threads[Id].Ctx.R[IOPRegRA] := TrapAddress(IOPRetModuleStart);
  finally
    List.Free;
  end;
end;

{ SIF, module side }

procedure TPS2IOPKernel.CopyToEE(Src, Dest: Cardinal; Size: Integer);
begin
  if Size <= 0 then
    Exit;
  var D := Dest and PS2RAMMask;
  if D + Cardinal(Size) > PS2RAMSize then
    Size := Integer(PS2RAMSize - D);
  for var K := 0 to Size - 1 do
    EERAM[D + Cardinal(K)] := R8(Src + Cardinal(K));
  if Assigned(OnMarkEE) then
    OnMarkEE(D, Cardinal(Size));
end;

procedure TPS2IOPKernel.RegisterServer(SD, SID, Func, Buff, CFunc, CBuff, QD: Cardinal);
begin
  var Slot := -1;
  for var K := 0 to High(Servers) do
    if Servers[K].Used and (Servers[K].SD = SD) then
      Slot := K;
  if Slot < 0 then
    for var K := 0 to High(Servers) do
      if not Servers[K].Used then
      begin
        Slot := K;
        Break;
      end;
  if Slot < 0 then
    Exit;
  Servers[Slot].Used := True;
  Servers[Slot].SID := SID;
  Servers[Slot].SD := SD;
  Servers[Slot].Func := Func;
  Servers[Slot].Buff := Buff;
  Servers[Slot].CFunc := CFunc;
  Servers[Slot].CBuff := CBuff;
  Servers[Slot].Queue := QD;
  // SifRpcServerData_t: sid, func, buff, size, cfunc, cbuff ... base (64).
  W32(SD, SID);
  W32(SD + 4, Func);
  W32(SD + 8, Buff);
  W32(SD + 16, CFunc);
  W32(SD + 20, CBuff);
  W32(SD + 64, QD);
  SIF.RemoveStub(SID);
  Warn(Format('rpc server %.8x sd %.6x func %.6x buff %.6x', [SID, SD, Func, Buff]));
end;

procedure TPS2IOPKernel.SetQueue(QD: Cardinal; Thread: Integer);
begin
  for var K := 0 to High(Queues) do
    if Queues[K].Used and (Queues[K].QD = QD) then
    begin
      Queues[K].Thread := Thread;
      Exit;
    end;
  for var K := 0 to High(Queues) do
    if not Queues[K].Used then
    begin
      Queues[K].Used := True;
      Queues[K].QD := QD;
      Queues[K].Thread := Thread;
      Exit;
    end;
end;

function TPS2IOPKernel.NextRequest(QD: Cardinal): Integer;
begin
  for var K := 0 to Requests.Count - 1 do
    if not Requests[K].Busy and (Servers[Requests[K].Server].Queue = QD) then
      Exit(K);
  Result := -1;
end;

procedure TPS2IOPKernel.StartRequest(Thread, Index: Integer);
begin
  var Req := Requests[Index];
  Req.Busy := True;
  Requests[Index] := Req;
  var S := Servers[Req.Server];
  var T: PIOPThread := @Threads[Thread];
  T.RpcServer := Req.Server;
  var Fn := PCardinal(@Req.Packet[32])^;
  var Size := PCardinal(@Req.Packet[36])^;
  if Thread = Current then
  begin
    CPU.SetPC(S.Func);
    CPU.R[IOPRegA0] := Fn;
    CPU.R[IOPRegA1] := S.Buff;
    CPU.R[IOPRegA2] := Size;
    CPU.R[IOPRegRA] := TrapAddress(IOPRetRpc);
  end
  else
  begin
    T.Ctx.PC := S.Func;
    T.Ctx.NextPC := 0;
    T.Ctx.R[IOPRegA0] := Fn;
    T.Ctx.R[IOPRegA1] := S.Buff;
    T.Ctx.R[IOPRegA2] := Size;
    T.Ctx.R[IOPRegRA] := TrapAddress(IOPRetRpc);
    MakeReady(Thread);
  end;
end;

function TPS2IOPKernel.TakeRequest(QD: Cardinal): Cardinal;
begin
  var K := NextRequest(QD);
  if K < 0 then
    Exit(0);
  var Req := Requests[K];
  Req.Busy := True;
  Requests[K] := Req;
  Result := Servers[Req.Server].SD;
end;

procedure TPS2IOPKernel.ExecRequest(SD: Cardinal);
begin
  if Current <= 0 then
    Exit;
  for var K := 0 to Requests.Count - 1 do
    if Requests[K].Busy and (Servers[Requests[K].Server].SD = SD) then
    begin
      var T: PIOPThread := @Threads[Current];
      T.RpcQueue := 0;
      T.RpcReturn := CPU.PC;
      T.RpcServer := Requests[K].Server;
      var Req := Requests[K];
      var S := Servers[Req.Server];
      CPU.SetPC(S.Func);
      CPU.R[IOPRegA0] := PCardinal(@Req.Packet[32])^;
      CPU.R[IOPRegA1] := S.Buff;
      CPU.R[IOPRegA2] := PCardinal(@Req.Packet[36])^;
      CPU.R[IOPRegRA] := TrapAddress(IOPRetRpc);
      Exit;
    end;
end;

function TPS2IOPKernel.GuestBind(const P: TBytes): Boolean;
begin
  var SID := PacketU32(P, 32);
  for var K := 0 to High(Servers) do
    if Servers[K].Used and (Servers[K].SID = SID) then
    begin
      SIF.ReplyBind(P, Servers[K].SD, Servers[K].Buff, Servers[K].CBuff);
      Exit(True);
    end;
  // Modules still starting may register it soon: 'not yet' makes the EE
  // bind again.
  var Tries := 0;
  FBindRetries.TryGetValue(SID, Tries);
  if Active and (Tries < 5000) then
  begin
    FBindRetries.AddOrSetValue(SID, Tries + 1);
    SIF.ReplyBind(P, 0, 0, 0);
    Exit(True);
  end;
  Result := False;
end;

procedure TPS2IOPKernel.GuestCommand(Kind: Cardinal; const P: TBytes);
begin
  if Kind = SIFCmdRPCCall then
  begin
    var SD := PacketU32(P, 52);
    var Index := -1;
    for var K := 0 to High(Servers) do
      if Servers[K].Used and (Servers[K].SD = SD) then
        Index := K;
    if Index < 0 then
    begin
      SIF.ReplyCall(P, nil);
      Exit;
    end;
    if Log <> nil then
      Warn(Format('guest call %.8x fn %x', [Servers[Index].SID, PacketU32(P, 32)]));
    var Req: TIOPRequest;
    Req.Server := Index;
    Req.Busy := False;
    FillChar(Req.Packet, SizeOf(Req.Packet), 0);
    Move(P[0], Req.Packet[0], Min(Length(P), 64));
    Requests.Add(Req);
    var QD := Servers[Index].Queue;
    for var K := 1 to IOPMaxThreads do
      if Threads[K].Used and (Threads[K].State = ThWaiting) and (Threads[K].Wait = WaitRpc) and
        (Threads[K].RpcQueue = QD) then
      begin
        StartRequest(K, Requests.Count - 1);
        Exit;
      end;
    // A module polling with sceSifGetNextRequest sleeps between requests.
    for var Q := 0 to High(Queues) do
      if Queues[Q].Used and (Queues[Q].QD = QD) and (Queues[Q].Thread > 0) then
      begin
        var T := Queues[Q].Thread;
        if Threads[T].Used and (Threads[T].State = ThWaiting) and (Threads[T].Wait = WaitSleep) then
          Wake(T, 0)
        else if Threads[T].Used then
          Inc(Threads[T].WakeupCount);
      end;
    Exit;
  end;
  // Commands for handlers modules added (sceSifAddCmdHandler).
  var Cid := PacketU32(P, 8);
  for var K := 0 to High(CmdHandlers) do
    if CmdHandlers[K].Used and (CmdHandlers[K].Cid = Cid) then
    begin
      var Slot := IOPCmdCopies + Cardinal(FCmdSlot) * 128;
      FCmdSlot := (FCmdSlot + 1) and 15;
      for var B := 0 to Min(Length(P), 128) - 1 do
        W8(Slot + Cardinal(B), P[B]);
      QueueCall(CallCmd, CmdHandlers[K].Handler, Slot, CmdHandlers[K].Data, 0, 0, Cid);
      Exit;
    end;
  if Log <> nil then
    Warn(Format('sif command %.8x without handler', [Cid]));
end;

function TPS2IOPKernel.Logged(Key: Cardinal): Boolean;
begin
  Result := FWarned.ContainsKey(Key);
  if not Result then
    FWarned.Add(Key, True);
end;

function TPS2IOPKernel.ImageAt(Address: Cardinal): TBytes;
begin
  Address := Address and PS2IOPRAMMask;
  var Size: Int64 := 52;
  var PhOff := Int64(R32(Address + 28));
  var PhNum := R16(Address + 44);
  var PhSize := R16(Address + 42);
  for var I := 0 to Integer(PhNum) - 1 do
  begin
    var P := Cardinal((Address + PhOff + Int64(I) * PhSize) and PS2IOPRAMMask);
    Size := Max(Size, Int64(R32(P + 4)) + R32(P + 16));
  end;
  var ShOff := Int64(R32(Address + 32));
  var ShNum := R16(Address + 48);
  var ShSize := R16(Address + 46);
  Size := Max(Size, ShOff + Int64(ShNum) * ShSize);
  for var I := 0 to Integer(ShNum) - 1 do
  begin
    var S := Cardinal((Address + ShOff + Int64(I) * ShSize) and PS2IOPRAMMask);
    if R32(S + 4) <> 8 then
      Size := Max(Size, Int64(R32(S + 16)) + R32(S + 20));
  end;
  Size := Min(Size, Int64(PS2IOPRAMSize - Address));
  SetLength(Result, Size);
  for var I := 0 to Integer(Size) - 1 do
    Result[I] := R8(Address + Cardinal(I));
end;

{ Snapshots }

procedure TPS2IOPKernel.ListField<T>(State: TStateArchive; L: TList<T>);
begin
    var N := L.Count;
    State.Field(N, SizeOf(N));
    if State.Loading then
    begin
      if (N < 0) or (N > 65536) then
        raise EReadError.Create('PS2 snapshot IOP kernel list');
      L.Clear;
      for var K := 0 to N - 1 do
      begin
        var V: T;
        State.Field(V, SizeOf(T));
        L.Add(V);
      end;
    end
    else
      for var K := 0 to N - 1 do
      begin
        var V := L[K];
        State.Field(V, SizeOf(T));
      end;
end;

procedure TPS2IOPKernel.SerializeState(State: TStateArchive);
begin
  CPU.SerializeState(State);
  Hardware.SerializeState(State);
  State.Field(Threads, SizeOf(Threads));
  State.Field(Semas, SizeOf(Semas));
  State.Field(Events, SizeOf(Events));
  State.Field(Mbxs, SizeOf(Mbxs));
  State.Field(Pools, SizeOf(Pools));
  State.Field(Intr, SizeOf(Intr));
  State.Field(Vblanks, SizeOf(Vblanks));
  State.Field(Alarms, SizeOf(Alarms));
  State.Field(Timers, SizeOf(Timers));
  State.Field(Libraries, SizeOf(Libraries));
  State.Field(Modules, SizeOf(Modules));
  State.Field(Servers, SizeOf(Servers));
  State.Field(Queues, SizeOf(Queues));
  State.Field(CmdHandlers, SizeOf(CmdHandlers));
  State.Field(SifRegs, SizeOf(SifRegs));
  ListField<TIOPRequest>(State, Requests);
  ListField<TIOPCall>(State, Calls);
  ListField<Cardinal>(State, PendingImports);
  State.Field(Current, SizeOf(Current));
  State.Field(InCall, SizeOf(InCall));
  State.Field(CurrentCall, SizeOf(CurrentCall));
  State.Field(InVblank, SizeOf(InVblank));
  State.Field(CdDoneAt, SizeOf(CdDoneAt));
  State.Field(CdCallback, SizeOf(CdCallback));
  State.Field(CdLastCommand, SizeOf(CdLastCommand));
  State.Field(CdStreamLBA, SizeOf(CdStreamLBA));
  State.Field(DmaId, SizeOf(DmaId));
  State.Field(FReadySeq, SizeOf(FReadySeq));
  State.Field(FCmdSlot, SizeOf(FCmdSlot));
  if State.Loading then
    FMaybeReady := True;
end;

end.
