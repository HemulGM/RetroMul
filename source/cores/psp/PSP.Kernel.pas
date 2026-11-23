unit PSP.Kernel;

// Kernel objects, threads and the scheduler. One guest thread owns the CPU at a
// time; the others keep their context here. Waits are records on the thread
// plus a place in the waited object's queue; a timeout is a kernel timer.
// Guest code called by the kernel (callbacks, interrupt handlers, alarms, HLE
// continuations) runs in frames that end at the return trap.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults, PSP.Types, PSP.Memory, PSP.CPU, PSP.HLE,
  PSP.Scheduler, PSP.SysMem, PSP.State.Action, PSP.State.Graph;

const
  PSPThreadRunning = 1;
  PSPThreadReady = 2;
  PSPThreadWaiting = 4;
  PSPThreadSuspended = 8;
  PSPThreadDormant = 16;
  PSPThreadDead = 32;
  PSPInterruptGE = 25;
  PSPInterruptVBlank = 30;

  // Guest-visible wait types (sceKernelReferThreadStatus).
  PSPWaitNone = 0;
  PSPWaitSleep = 1;
  PSPWaitDelay = 2;
  PSPWaitSema = 3;
  PSPWaitEventFlag = 4;
  PSPWaitMbx = 5;
  PSPWaitVpl = 6;
  PSPWaitFpl = 7;
  PSPWaitMsgPipe = 8;
  PSPWaitThreadEnd = 9;
  PSPWaitEventHandler = 10;
  PSPWaitCallback = 11;
  PSPWaitMutex = 12;
  PSPWaitLwMutex = 13;
  PSPWaitTlspl = 14;

type
  TPSPKernel = class;

  TPSPThread = class;

  TPSPKernelObject = class
  public
    UID: Cardinal;
    Name: string;
    Kernel: TPSPKernel;
    // ThreadManForUser id type (sceKernelGetThreadmanIdType); 0 for others.
    class function IdType: Integer; virtual;
    // A waiting thread leaves this object's queue (timeout, cancel, delete).
    procedure RemoveWaiter(T: TPSPThread); virtual;
    // Puts a thread back in the queue after its callbacks ran.
    procedure AddWaiter(T: TPSPThread); virtual;
    // A waiter left on its own (timeout, release, terminate): the ones behind
    // it may be satisfiable now.
    procedure WaiterGone; virtual;
    destructor Destroy; override;
  end;

  TPSPKernelObjectClass = class of TPSPKernelObject;

  // Tries to satisfy a wait again (after callbacks ran on the thread). On
  // success it sets the thread's result and returns True.
  TPSPWaitRetry = function(T: TPSPThread): Boolean of object;
  // Called when a wait ends without the object (timeout, release, delete):
  // lets an HLE subsystem forget the thread.

  TPSPWaitAbort = procedure(T: TPSPThread) of object;

  TPSPWait = record
    Kind: Integer;
    Id: Cardinal;
    Obj: TPSPKernelObject;
    // When the timeout fires (ns); PSPNever for none.
    Deadline: Int64;
    // The end the caller asked for, for the time left written back.
    TimeoutEnd: Int64;
    TimeoutPtr: Cardinal;
    AllowCB: Boolean;
    Retry: TPSPWaitRetry;
    Abort: TPSPWaitAbort;
    Data: array[0..7] of Cardinal;
    HLETag: string;
    // The call returns an address: a wait that fails gives 0.
    FailAsZero: Boolean;
  end;

  TPSPCallback = class(TPSPKernelObject)
  public
    Thread: TPSPThread;
    Func, Common, GP: Cardinal;
    NotifyCount, NotifyArg: Cardinal;
    class function IdType: Integer; override;
  end;

  TPSPThreadEvent = record
    Kind, ThreadId: Cardinal;
    Handlers: TArray<Cardinal>;
  end;

  TPSPFrameKind = (fkCallback, fkHLE, fkInterrupt, fkThreadStart, fkThreadEvent);

  TPSPGuestReturn = reference to procedure(Value: Cardinal);

  TPSPFrame = record
    Kind: TPSPFrameKind;
    Saved: TPSPContext;
    SavedWait: TPSPWait;
    WasWaiting: Boolean;
    Callback: TPSPCallback;
    OnReturn: TPSPGuestReturn;
    ReturnState: IPSPStateAction;
    CallbacksRan: Integer;
    // Callbacks run on the way out of a call that did not wait: its result stays.
    KeepResult: Boolean;
  end;

  TPSPThread = class(TPSPKernelObject)
  public
    Ctx: TPSPContext;
    Status: Cardinal;
    Priority, InitPriority: Integer;
    Attr, Entry, StackBlock, StackSize, StackTop, GP: Cardinal;
    Wait: TPSPWait;
    WakeupCount: Integer;
    ExitStatus: Cardinal;
    RunClocks: Int64;
    Callbacks: TList<TPSPCallback>;
    Frames: TList<TPSPFrame>;
    EndWaiters: TList<TPSPThread>;
    // Stacks added by sceKernelExtendThreadStack, innermost last.
    ExtraStacks: TList<Cardinal>;
    ModuleId: Cardinal;
    CallbacksPending: Boolean;
    SuspendedWhileWaiting: Boolean;
    // The first wait after a start goes down a slower path.
    Fresh: Boolean;
    StackPartition: TPSPPartition;
    // The thread's block in each TLS pool, by the pool's slot.
    TlsSlots: array[0..15] of Cardinal;
    EventWorker: Boolean;
    ReleaseCount, PreemptCount, IntrPreemptCount: Cardinal;
    Seq: Int64;
    // Runs once when the thread exits or is terminated.
    OnExit: TProc<TPSPThread>;
    ExitState: IPSPStateAction;
    // Deleted as soon as it exits by itself (a module's start thread).
    DeleteOnExit: Boolean;
    // Kernel work a call left to do on the thread's time, where better
    // threads may preempt it, and where the thread goes on afterwards.
    BusyNs, BusyAt: Int64;
    BusyYieldEqual: Boolean;
    BusyPC, BusyNPC: Cardinal;
    // A device call's wait, begun when its CPU work is done, and what the
    // call returns.
    BusyWaitNs: Int64;
    BusyWaitResult: Cardinal;
    // What picking the work up again after a preemption costs (0: PSPBusyResumeNs).
    BusyResumeNs: Int64;
    // Or what the call does when its CPU work is done (SpendThen).
    BusyThen: IPSPStateAction;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    function IsWaiting: Boolean; inline;
    function IsDormant: Boolean; inline;
    function IsKernel: Boolean; inline;
    // Where a wait result goes: the thread's context, or the context a callback
    // frame will restore.
    procedure SetResult(Value: Cardinal);
    function HasPendingCallbacks: Boolean;
    function InCallback: Boolean;
    // A blocking CB wait inside a callback runs callbacks too, one level deep.
    function CallbackDepth: Integer;
  end;

  // Threads waiting on an object, FIFO or by priority.
  TPSPWaitQueue = class
  private
    FItems: TList<TPSPThread>;
    FByPriority: Boolean;
  public
    constructor Create(ByPriority: Boolean);
    destructor Destroy; override;
    procedure Add(T: TPSPThread);
    procedure Remove(T: TPSPThread);
    function First: TPSPThread;
    function Count: Integer;
    function Item(I: Integer): TPSPThread;
    function Contains(T: TPSPThread): Boolean;
    procedure Clear;
    property ByPriority: Boolean read FByPriority write FByPriority;
  end;

  // An object with one wait queue, ordered by priority when Attr has $100.
  TPSPWaitObject = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    Waiters: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
  end;

  TPSPSema = class(TPSPWaitObject)
  public
    Count, MaxCount, InitCount: Integer;
    class function IdType: Integer; override;
    function TryTake(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  TPSPEventFlag = class(TPSPWaitObject)
  public
    Pattern, InitPattern: Cardinal;
    class function IdType: Integer; override;
    function Matches(Bits, Mode: Cardinal): Boolean;
    function TryTake(T: TPSPThread): Boolean;
    procedure WakeWaiters;
  end;

  TPSPInterruptHandler = record
    Handler, Arg, GP: Cardinal;
    Enabled: Boolean;
  end;

  TPSPPendingInterrupt = record
    Func, A0, A1, A2, A3, GP: Cardinal;
    OnReturn: TPSPGuestReturn;
    ReturnState: IPSPStateAction;
    // Time the kernel spends before the handler starts.
    EntryNs: Int64;
    // The object it is for; dropped if that is deleted while pending.
    OwnerUID: Cardinal;
  end;

  TPSPTimerKind = (tkWait, tkCustom);

  TPSPTimerEvent = reference to procedure;

  TPSPTimer = record
    At: Int64;
    Seq: Int64;
    Kind: TPSPTimerKind;
    Thread: TPSPThread;
    Owner: TObject;
    Event: TPSPTimerEvent;
    Action: IPSPStateAction;
  end;

  TPSPExitEvent = procedure(Status: Cardinal) of object;

  TPSPTimeSync = procedure of object;

  TPSPKernel = class
  private
    FCPU: TPSPCPU;
    FMemory: TPSPMemory;
    FHLE: TPSPHLE;
    FScheduler: TPSPScheduler;
    FObjects: TDictionary<Cardinal, TPSPKernelObject>;
    FNextUID: Cardinal;
    FReady: array[0..127] of TList<TPSPThread>;
    // Bit P is set while FReady[P] has threads.
    FReadyMask: array[0..3] of Cardinal;
    FCurrent: TPSPThread;
    FThreads: TList<TPSPThread>;
    FTimers: TList<TPSPTimer>;
    FTimerSeq: Int64;
    FThreadSeq: Int64;
    FRescheduleNeeded: Boolean;
    FIntFrames: TList<TPSPFrame>;
    FPendingInts: TQueue<TPSPPendingInterrupt>;
    FSubIntr: array[0..66, 0..31] of TPSPInterruptHandler;
    // The virtual timer whose handler is running.
    FFiringVTimer: Cardinal;
    // Where threads go to spend long kernel calls.
    FBusyStub: Cardinal;
    // Main interrupt handlers; the firmware's drivers hold some from the start.
    FIntrHandlers: array[0..67] of TPSPInterruptHandler;
    FTrapBase: Cardinal;
    FIntStack: Cardinal;
    FDispatchSuspended: Boolean;
    FIntrSuspendLevel: Integer;
    FUserPartition, FKernelPartition, FVolatilePartition, FStackPartition: TPSPPartition;
    FBlocks: TDictionary<Cardinal, TPSPKernelObject>;
    FOnExit: TPSPExitEvent;
    FOnSyncTime: TPSPTimeSync;
    FExited: Boolean;
    FExitCallback: Cardinal;
    FCompiledSdkVersion, FCompilerVersion: Cardinal;
    FSdkVersionSet: Boolean;
    FDebugOut: TStringBuilder;
    FIdle: Boolean;
    FTrace: Boolean;
    FVolatileLocked: Boolean;
    FVolatileWaiters: TList<TPSPThread>;
    FEventHandlers: TList<TPSPKernelObject>;
    FThreadEvents: TQueue<TPSPThreadEvent>;
    FIdleThreadIds: array[0..1] of Cardinal;
    FTlsplCount: Integer;
    // How far into the next wait call its timeout is looked at (0: the usual).
    FWaitCheckNs: Int64;
    procedure T_(const Fmt: string; const Args: array of const);
    procedure ScheduleTimerEvent;
    procedure PushReady(T: TPSPThread; Front: Boolean);
    procedure RemoveReady(T: TPSPThread);
    function BestReady: TPSPThread;
    procedure SwitchTo(T: TPSPThread);
    procedure DispatchThread(T: TPSPThread);
    procedure StartCallbacks(T: TPSPThread; KeepResult: Boolean = False);
    function RunNextCallback(T: TPSPThread; var Frame: TPSPFrame): Boolean;
    procedure FinishCallbackFrame(T: TPSPThread);
    procedure ReturnTrap;
    procedure ThreadExitTrap;
    procedure StartNextInterrupt;
    procedure DropStaleInterrupts;
    procedure EnterGuest(Func, SP, GP: Cardinal; const Args: array of Cardinal);
    procedure WakeEndWaiters(T: TPSPThread);
    procedure KillThreadFrames(T: TPSPThread);
    procedure DropWaitTimer(T: TPSPThread);
    procedure RegisterAll;
    procedure RegisterKernelAliases;
    function InternalWait(T: TPSPThread): Boolean;
    procedure DeviceWait(T: TPSPThread; WaitNs: Int64; Value: Cardinal);
    function DeviceWaitRetry(T: TPSPThread): Boolean;
    procedure hKernelBusy;
    procedure StateWake(Action: TPSPStateAction; Value: Cardinal);
    procedure StateAlarmFire(Action: TPSPStateAction; Value: Cardinal);
    procedure StateAlarmReturn(Action: TPSPStateAction; Value: Cardinal);
    procedure StateVTimerFire(Action: TPSPStateAction; Value: Cardinal);
    procedure StateVTimerReturn(Action: TPSPStateAction; Value: Cardinal);
    // Spends the time as kernel work the scheduler may interrupt.
    procedure hCheckExitCallback;
    procedure hIoForKernel;
    function WaitDeadline(TimeoutPtr: Cardinal; out TimeoutEnd: Int64): Int64;
    procedure WriteRemaining(T: TPSPThread);
    procedure FreeThreadStacks(T: TPSPThread);
    procedure NotifyThreadEvent(Kind: Cardinal; T: TPSPThread);
    procedure DispatchThreadEvents;
    procedure StateThreadEventNext(Action: TPSPStateAction; Value: Cardinal);
    function ReadName(Ptr: Cardinal; out Name: string): Boolean;
    function ValidPriorityFor(P: Integer): Boolean;
    procedure YieldCurrent;
    function ValidUserAddress(Address: Cardinal): Boolean;
    function WriteInfo(Ptr: Cardinal; const Buf; StructSize: Cardinal): Boolean;
    // HLE handlers
    procedure hCreateThread;
    procedure hStartThread;
    procedure hExitThread;
    procedure hExitDeleteThread;
    procedure hDeleteThread;
    procedure hTerminateThread;
    procedure hTerminateDeleteThread;
    procedure hGetThreadId;
    procedure hGetThreadCurrentPriority;
    procedure hChangeThreadPriority;
    procedure hRotateThreadReadyQueue;
    procedure hReferThreadStatus;
    procedure hReferThreadRunStatus;
    procedure hGetThreadExitStatus;
    procedure hSleepThread;
    procedure hSleepThreadCB;
    procedure hWakeupThread;
    procedure hCancelWakeupThread;
    procedure hSuspendThread;
    procedure hResumeThread;
    procedure hWaitThreadEnd;
    procedure hWaitThreadEndCB;
    procedure hDelayThread;
    procedure hDelayThreadCB;
    procedure hDelaySysClockThread;
    procedure hDelaySysClockThreadCB;
    procedure hReleaseWaitThread;
    procedure hGetThreadStackFreeSize;
    procedure hCheckThreadStack;
    procedure hChangeCurrentThreadAttr;
    procedure hGetThreadmanIdType;
    procedure hGetThreadmanIdList;
    procedure hSuspendDispatchThread;
    procedure hResumeDispatchThread;
    procedure hReferSystemStatus;
    procedure hExtendThreadStack;
    procedure hReferThreadProfiler;
    procedure hDonateWakeupThread;
    procedure hCreateCallback;
    procedure hDeleteCallback;
    procedure hNotifyCallback;
    procedure hCancelCallback;
    procedure hGetCallbackCount;
    procedure hCheckCallback;
    procedure hReferCallbackStatus;
    procedure hCreateSema;
    procedure hDeleteSema;
    procedure hSignalSema;
    procedure hWaitSema;
    procedure hWaitSemaCB;
    procedure hPollSema;
    procedure hCancelSema;
    procedure hReferSemaStatus;
    procedure hCreateEventFlag;
    procedure hDeleteEventFlag;
    procedure hSetEventFlag;
    procedure hClearEventFlag;
    procedure hWaitEventFlag;
    procedure hWaitEventFlagCB;
    procedure hPollEventFlag;
    procedure hCancelEventFlag;
    procedure hReferEventFlagStatus;
    procedure WaitSemaCommon(AllowCB: Boolean);
    procedure WaitEventFlagCommon(AllowCB: Boolean);
    // Mutexes
    procedure hCreateMutex;
    procedure hDeleteMutex;
    procedure hLockMutex;
    procedure hLockMutexCB;
    procedure hTryLockMutex;
    procedure hUnlockMutex;
    procedure hCancelMutex;
    procedure hReferMutexStatus;
    procedure LockMutexCommon(AllowCB: Boolean);
    procedure hCreateLwMutex;
    procedure hDeleteLwMutex;
    procedure hLockLwMutex;
    procedure hLockLwMutexCB;
    procedure hTryLockLwMutex;
    procedure hTryLockLwMutex600;
    procedure hUnlockLwMutex;
    procedure hReferLwMutexStatus;
    procedure hReferLwMutexStatusByID;
    procedure LockLwMutexCommon(AllowCB, IsTry: Boolean; TryError: Cardinal);
    procedure ReferLwMutex(Obj: TPSPKernelObject; InfoPtr: Cardinal);
    procedure ReleaseMutexesOf(T: TPSPThread);
    // Message boxes and pipes
    procedure hCreateMbx;
    procedure hDeleteMbx;
    procedure hSendMbx;
    procedure hReceiveMbx;
    procedure hReceiveMbxCB;
    procedure hPollMbx;
    procedure hCancelReceiveMbx;
    procedure hReferMbxStatus;
    procedure ReceiveMbxCommon(AllowCB: Boolean);
    procedure hCreateMsgPipe;
    procedure hDeleteMsgPipe;
    procedure hSendMsgPipe;
    procedure hSendMsgPipeCB;
    procedure hTrySendMsgPipe;
    procedure hReceiveMsgPipe;
    procedure hReceiveMsgPipeCB;
    procedure hTryReceiveMsgPipe;
    procedure hCancelMsgPipe;
    procedure hReferMsgPipeStatus;
    function UserPartitionCheck(PartId: Integer): Cardinal;
    procedure SendMsgPipeCommon(Mode: Integer);
    procedure ReceiveMsgPipeCommon(Mode: Integer);
    // Pools
    procedure hCreateVpl;
    procedure hDeleteVpl;
    procedure hAllocateVpl;
    procedure hAllocateVplCB;
    procedure hTryAllocateVpl;
    procedure hFreeVpl;
    procedure hCancelVpl;
    procedure hReferVplStatus;
    function PoolPartition(PartId: Integer): TPSPPartition;
    function TlsplOf(Id: Cardinal): TPSPKernelObject;
    function TlsTake(Obj: TPSPKernelObject; out Addr: Cardinal): Boolean;
    procedure ReleaseTlsOf(T: TPSPThread);
    procedure AllocateVplCommon(Mode: Integer);
    procedure hCreateFpl;
    procedure hDeleteFpl;
    procedure hAllocateFpl;
    procedure hAllocateFplCB;
    procedure hTryAllocateFpl;
    procedure hFreeFpl;
    procedure hCancelFpl;
    procedure hReferFplStatus;
    procedure AllocateFplCommon(Mode: Integer);
    procedure hCreateTlspl;
    procedure hDeleteTlspl;
    procedure hGetTlsAddr;
    procedure hAllocateTlspl;
    procedure hFreeTlspl;
    procedure hReferTlsplStatus;
    // Alarms, virtual timers, thread event handlers
    procedure hSetAlarm;
    procedure hSetSysClockAlarm;
    procedure hCancelAlarm;
    procedure hReferAlarmStatus;
    procedure SetAlarmCommon(Us: UInt64);
    procedure ArmAlarm(Obj: TPSPKernelObject; FireAt: Int64);
    procedure ArmVTimer(Obj: TPSPKernelObject; FromCall: Boolean = True);
    function VTimerOf(Id: Cardinal): TPSPKernelObject;
    procedure SetVTimerTimeTo(Obj: TPSPKernelObject; Value: UInt64);
    procedure SetVTimerHandlerCommon(Schedule: UInt64; Handler, Common: Cardinal);
    procedure hCreateVTimer;
    procedure hDeleteVTimer;
    procedure hGetVTimerBase;
    procedure hGetVTimerBaseWide;
    procedure hGetVTimerTime;
    procedure hGetVTimerTimeWide;
    procedure hSetVTimerTime;
    procedure hSetVTimerTimeWide;
    procedure hStartVTimer;
    procedure hStopVTimer;
    procedure hSetVTimerHandler;
    procedure hSetVTimerHandlerWide;
    procedure hCancelVTimerHandler;
    procedure hReferVTimerStatus;
    procedure hRegisterThreadEventHandler;
    procedure hReleaseThreadEventHandler;
    procedure hReferThreadEventHandlerStatus;
    // Time
    procedure hGetSystemTime;
    procedure hGetSystemTimeWide;
    procedure hGetSystemTimeLow;
    procedure hUSec2SysClock;
    procedure hUSec2SysClockWide;
    procedure hSysClock2USec;
    procedure hSysClock2USecWide;
    // Interrupts
    procedure hCpuSuspendIntr;
    procedure hCpuResumeIntr;
    procedure hIsCpuIntrEnable;
    procedure hIsCpuIntrSuspended;
    procedure hRegisterSubIntrHandler;
    procedure hReleaseSubIntrHandler;
    procedure hEnableSubIntr;
    procedure hDisableSubIntr;
    procedure hSuspendSubIntr;
    procedure hResumeSubIntr;
    procedure hIsSubInterruptOccurred;
    procedure hRegisterUserSpaceIntrStack;
    procedure hQueryIntrHandlerInfo;
    function IntrHandlerCheck(I: Integer): Cardinal;
    procedure hEnableIntr;
    procedure hDisableIntr;
    procedure hRegisterIntrHandler;
    procedure hReleaseIntrHandler;
    // System memory
    procedure hAllocPartitionMemory;
    procedure hFreePartitionMemory;
    procedure hGetBlockHeadAddr;
    procedure hMaxFreeMemSize;
    procedure hTotalFreeMemSize;
    procedure hTotalMemSize;
    procedure hPartitionTotalFreeMemSize;
    procedure hQueryMemoryInfo;
    procedure hAllocMemoryBlock;
    procedure hFreeMemoryBlock;
    procedure hGetMemoryBlockPtr;
    procedure hDevkitVersion;
    procedure hSetCompiledSdkVersion;
    procedure hGetCompiledSdkVersion;
    procedure hSetCompilerVersion;
    procedure hPrintf;
    procedure hCreateHeap;
    procedure hDeleteHeap;
    procedure hAllocHeapMemory;
    procedure hAllocHeapMemoryWithOption;
    procedure hFreeHeapMemory;
    procedure hExitGame;
    procedure hRegisterExitCallback;
    procedure hVolatileMemLock;
    procedure hVolatileMemTryLock;
    procedure hVolatileMemUnlock;
    procedure hReturnZero;
    procedure hMemcpy;
    procedure hMemset;
    function VolatileRetry(T: TPSPThread): Boolean;
    function SleepRetry(T: TPSPThread): Boolean;
    function DelayRetry(T: TPSPThread): Boolean;
    function ThreadEndRetry(T: TPSPThread): Boolean;
    procedure DelayCurrent(Microseconds: Int64; AllowCB: Boolean);
    function SemaRetry(T: TPSPThread): Boolean;
    function EventFlagRetry(T: TPSPThread): Boolean;
    procedure EventFlagAbort(T: TPSPThread);
    function CheckCallbacksNow(KeepResult: Boolean = True): Boolean;
    function AllocPartitionBlock(PartId: Integer; const Name: string; Kind: Integer; Size, Addr: Cardinal; out Err: Cardinal): Cardinal;
  public
    // The kernel's own interrupt code holds the CPU until this time: no guest
    // thread runs (guest interrupt handlers still do).
    BusyUntil: Int64;
    constructor Create(CPU: TPSPCPU; Memory: TPSPMemory; HLE: TPSPHLE; Scheduler: TPSPScheduler);
    destructor Destroy; override;
    procedure Reset;
    // Objects
    function AddObject(Obj: TPSPKernelObject): Cardinal;
    procedure DeleteObject(Obj: TPSPKernelObject);
    function GetObject(UID: Cardinal; Cls: TPSPKernelObjectClass): TPSPKernelObject;
    function ThreadById(UID: Cardinal): TPSPThread;
    // Threads
    function CreateThread(const Name: string; Entry: Cardinal; Priority: Integer; StackSize, Attr, GP: Cardinal; ModuleId: Cardinal = 0): TPSPThread;
    procedure StartThread(T: TPSPThread; ArgSize, ArgPtr: Cardinal; const ArgData: TBytes = nil);
    procedure ExitCurrent(Status: Cardinal);
    procedure TerminateThread(T: TPSPThread; Status: Cardinal);
    procedure DeleteThread(T: TPSPThread);
    procedure ChangePriority(T: TPSPThread; Priority: Integer);
    // Waits. BeginWait blocks the current thread; the result is set at EndWait.
    procedure BeginWait(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean; Retry: TPSPWaitRetry; Abort: TPSPWaitAbort = nil; const Tag: string = '');
    // The same with wait data set before callbacks can run. Returns False when
    // the wait timed out at once (the result is set then).
    function BeginWaitData(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean; Retry: TPSPWaitRetry; const Data: array of Cardinal; Abort: TPSPWaitAbort = nil; const Tag: string = ''): Boolean;
    procedure EndWait(T: TPSPThread; Result: Cardinal);
    procedure WakeThread(T: TPSPThread);
    // A wait with an absolute deadline in ns (PSPNever for none).
    procedure SetWaitDeadline(T: TPSPThread; Deadline: Int64);
    // Sets a wait's data on the thread, or on the wait its callback frame keeps.
    procedure SetWaitData(T: TPSPThread; Index: Integer; Value: Cardinal);
    procedure Reschedule;
    procedure RequestReschedule; inline;
    procedure AfterSyscall;
    procedure EnableDispatch;
    function CanWait: Boolean;
    // Sets the error and returns True when the current context may not block.
    function RefuseWait: Boolean;
    // What a syscall leaves in at, a0-a3, t0-t9, hi and lo.
    procedure ScrambleCallerSaved;
    // Guest time the kernel spends in a call (ns), on the current CPU clock.
    procedure Spend(Ns: Int64);
    // CPU work can be interrupted by a better thread, but does not yield to a
    // worse one. Its ordinary continuation is stored on the guest thread.
    procedure SpendPreemptible(Ns: Int64; YieldEqual: Boolean = False);
    // A device call: the CPU work the driver does on the caller's time
    // (preemptible, as SpendPreemptible), then the caller's wait for the
    // device, which lets any thread run; the call returns Value. Where the
    // caller cannot wait, only the result.
    procedure SpendThenWait(BusyNs, WaitNs: Int64; Value: Cardinal);
    // CPU work as SpendPreemptible, then Next runs on the caller's thread
    // (it may begin a wait).
    procedure SpendThen(BusyNs: Int64; const Next: IPSPStateAction);
    class function MemoryFillTime(Bytes: Cardinal): Int64; static;
    // Timers in guest ns. Returns a handle (sequence number) for CancelTimer.
    function AddTimer(At: Int64; Owner: TObject; const Event: TPSPTimerEvent): Int64;
    function AddStateTimer(At: Int64; Owner: TObject; const Action: IPSPStateAction): Int64;
    function AddWakeTimer(At: Int64; Thread: TPSPThread; const Tag: string; Value: Cardinal; DataSlot: Integer = -1; Owner: TObject = nil): Int64;
    procedure CancelTimer(Handle: Int64);
    procedure CancelTimersOf(Owner: TObject);
    procedure OnTimerEvent;
    // Guest calls
    procedure CallGuest(Func: Cardinal; const Args: array of Cardinal; const OnReturn: TPSPGuestReturn; GP: Cardinal = 0; const ReturnState: IPSPStateAction = nil);
    procedure QueueInterrupt(Func: Cardinal; const Args: array of Cardinal; GP: Cardinal; const OnReturn: TPSPGuestReturn = nil; EntryNs: Int64 = 0; OwnerUID: Cardinal = 0; const ReturnState: IPSPStateAction = nil);
    procedure TriggerInterrupt(IntNo: Integer; SubNo: Integer = -1; Arg2: Cardinal = 0);
    // Queues the enabled sub-interrupt handlers of IntNo; Done runs after the
    // last one returns. Returns how many were queued (Done is not called for 0).
    function QueueSubInterrupts(IntNo: Integer; Arg2: Cardinal; const Done: TProc; const StateDone: IPSPStateAction = nil): Integer;
    procedure ProcessInterrupts;
    procedure Trap(Code: Cardinal);
    procedure NotifyCallback(CB: TPSPCallback; Arg: Cardinal);
    // Runs the current thread's pending callbacks now (CB variants of calls
    // that did not need to wait).
    function CheckCallbacks: Boolean;
    function InInterrupt: Boolean; inline;
    function HasRunnable: Boolean;
    function NowUs: Int64;
    // Memory
    function AllocUser(Size: Cardinal; High: Boolean; const Tag: string): Cardinal;
    function AllocKernel(Size: Cardinal; const Tag: string): Cardinal;
    function Partition(Id: Integer): TPSPPartition;
    procedure DebugWrite(const S: RawByteString);
    function TakeDebugOutput: string;
    function DescribeThreads: string;
    function DescribeStateTimers: string;
    property Current: TPSPThread read FCurrent;
    property CPU: TPSPCPU read FCPU;
    property Memory: TPSPMemory read FMemory;
    property HLE: TPSPHLE read FHLE;
    property Scheduler: TPSPScheduler read FScheduler;
    property Threads: TList<TPSPThread> read FThreads;
    property TrapReturnAddress: Cardinal read FTrapBase;
    property UserPartition: TPSPPartition read FUserPartition;
    property KernelPartition: TPSPPartition read FKernelPartition;
    property StackPartition: TPSPPartition read FStackPartition;
    property OnExit: TPSPExitEvent read FOnExit write FOnExit;
    property OnSyncTime: TPSPTimeSync read FOnSyncTime write FOnSyncTime;
    property Exited: Boolean read FExited;
    property CompiledSdkVersion: Cardinal read FCompiledSdkVersion;
    property ExitCallback: Cardinal read FExitCallback;
    property Idle: Boolean read FIdle;
    property Trace: Boolean read FTrace write FTrace;
  end;

function PSPThreadName(T: TPSPThread): string;

procedure RegisterPSPKernelStateTypes(Schema: TPSPGraphSchema);

implementation

{ PSP.Kernel: objects, queues, scheduler, waits, timers, guest calls. }

const
  // Time the thread manager spends (ns) where a test on hardware can see it.
  PSPSwitchNs = 4000;
  // A timeout never fires sooner than this after the call, and the woken thread
  // gets the CPU a little later still.
  PSPMinTimeoutUs = 205;
  PSPWaitLatencyNs = 28300;
  PSPDelayLatencyNs = 18400;
  // How far into a wait or delay call the kernel checks whether the time asked
  // for has already passed (then it returns at once, without blocking).
  PSPWaitCheckNs = 1700;
  PSPDelayCheckNs = 500;
  PSPFreshCheckNs = 1500;
  // The rest of that slower path, after the check, before the thread is off
  // the CPU.
  PSPFreshBlockNs = 20000;
  PSPPipeCheckNs = 2900;
  PSPThreadEndCheckNs = 2000;
  // Thread manager call costs (ns) as a test on hardware measures them.
  PSPCreateThreadNs = 185000;
  PSPStartThreadNs = 15000;
  PSPFirstRunNs = 13000;
  PSPExitThreadNs = 13000;
  PSPDeleteThreadNs = 65000;
  PSPTerminateThreadNs = 10000;
  PSPSyncCallNs = 2500;
  // Long calls are spent in slices this long.
  PSPBusyChunkNs = 10000;
  PSPBusyResumeNs = 20000;
  // A device driver's work (the memory stick's protocol) costs more to resume.
  PSPDriverResumeNs = 34000;
  PSPNotifyWakeNs = 8000;
  // Leaving an interrupt that ran a handler, and handing the CPU to another
  // thread from there.
  PSPIntrExitNs = 30000;
  PSPIntrDispatchNs = 20000;
  // Thread event handler kinds.
  PSPThreadEventCreate = 1;
  PSPThreadEventStart = 2;
  PSPThreadEventExit = 4;
  PSPThreadEventDelete = 8;

function PSPThreadName(T: TPSPThread): string;
begin
  if T = nil then
    Result := '(idle)'
  else
    Result := Format('%s(%x)', [T.Name, T.UID]);
end;

{ TPSPKernelObject }

class function TPSPKernelObject.IdType: Integer;
begin
  Result := 0;
end;

procedure TPSPKernelObject.RemoveWaiter(T: TPSPThread);
begin
end;

procedure TPSPKernelObject.AddWaiter(T: TPSPThread);
begin
end;

procedure TPSPKernelObject.WaiterGone;
begin
end;

destructor TPSPKernelObject.Destroy;
begin
  inherited;
end;

class function TPSPCallback.IdType: Integer;
begin
  Result := 8;
end;

{ TPSPWaitQueue }

constructor TPSPWaitQueue.Create(ByPriority: Boolean);
begin
  inherited Create;
  FItems := TList<TPSPThread>.Create;
  FByPriority := ByPriority;
end;

destructor TPSPWaitQueue.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TPSPWaitQueue.Add(T: TPSPThread);
begin
  if FItems.Contains(T) then
    Exit;
  if FByPriority then
  begin
    for var I := 0 to FItems.Count - 1 do
      if FItems[I].Priority > T.Priority then
      begin
        FItems.Insert(I, T);
        Exit;
      end;
  end;
  FItems.Add(T);
end;

procedure TPSPWaitQueue.Remove(T: TPSPThread);
begin
  FItems.Remove(T);
end;

function TPSPWaitQueue.First: TPSPThread;
begin
  if FItems.Count = 0 then
    Result := nil
  else
    Result := FItems[0];
end;

function TPSPWaitQueue.Count: Integer;
begin
  Result := FItems.Count;
end;

function TPSPWaitQueue.Item(I: Integer): TPSPThread;
begin
  Result := FItems[I];
end;

function TPSPWaitQueue.Contains(T: TPSPThread): Boolean;
begin
  Result := FItems.Contains(T);
end;

procedure TPSPWaitQueue.Clear;
begin
  FItems.Clear;
end;

{ TPSPWaitObject }

constructor TPSPWaitObject.Create;
begin
  inherited Create;
  Waiters := TPSPWaitQueue.Create(False);
end;

destructor TPSPWaitObject.Destroy;
begin
  Waiters.Free;
  inherited;
end;

procedure TPSPWaitObject.RemoveWaiter(T: TPSPThread);
begin
  Waiters.Remove(T);
end;

procedure TPSPWaitObject.AddWaiter(T: TPSPThread);
begin
  Waiters.Add(T);
end;

{ TPSPThread }

constructor TPSPThread.Create;
begin
  inherited Create;
  Callbacks := TList<TPSPCallback>.Create;
  Frames := TList<TPSPFrame>.Create;
  EndWaiters := TList<TPSPThread>.Create;
  ExtraStacks := TList<Cardinal>.Create;
end;

destructor TPSPThread.Destroy;
begin
  ExtraStacks.Free;
  EndWaiters.Free;
  Frames.Free;
  Callbacks.Free;
  inherited;
end;

class function TPSPThread.IdType: Integer;
begin
  Result := 1;
end;

procedure TPSPThread.RemoveWaiter(T: TPSPThread);
begin
  EndWaiters.Remove(T);
end;

procedure TPSPThread.AddWaiter(T: TPSPThread);
begin
  if not EndWaiters.Contains(T) then
    EndWaiters.Add(T);
end;

function TPSPThread.IsWaiting: Boolean;
begin
  Result := (Status and PSPThreadWaiting) <> 0;
end;

function TPSPThread.IsDormant: Boolean;
begin
  Result := (Status and PSPThreadDormant) <> 0;
end;

function TPSPThread.IsKernel: Boolean;
begin
  Result := (Attr and $80000000) = 0;
end;

procedure TPSPThread.SetResult(Value: Cardinal);
begin
  // A wait the thread is blocked in belongs to the level it runs at.
  if ((Status and PSPThreadWaiting) = 0) and (Frames.Count > 0) and (Frames.Last.Kind = fkCallback) and
    Frames.Last.WasWaiting then
  begin
    // The wait belongs to the context the callback frame restores.
    var F := Frames.Last;
    F.Saved.GPR[2] := Value;
    Frames[Frames.Count - 1] := F;
  end
  else if Kernel.Current = Self then
    Kernel.CPU.Ctx.GPR[2] := Value
  else
    Ctx.GPR[2] := Value;
end;

function TPSPThread.HasPendingCallbacks: Boolean;
begin
  for var CB in Callbacks do
    if CB.NotifyCount > 0 then
      Exit(True);
  Result := False;
end;

function TPSPThread.InCallback: Boolean;
begin
  Result := CallbackDepth > 0;
end;

function TPSPThread.CallbackDepth: Integer;
begin
  Result := 0;
  for var F in Frames do
    if F.Kind = fkCallback then
      Inc(Result);
end;

{ TPSPKernel }

constructor TPSPKernel.Create(CPU: TPSPCPU; Memory: TPSPMemory; HLE: TPSPHLE; Scheduler: TPSPScheduler);
begin
  inherited Create;
  FCPU := CPU;
  FMemory := Memory;
  FHLE := HLE;
  FScheduler := Scheduler;
  FObjects := TDictionary<Cardinal, TPSPKernelObject>.Create;
  FBlocks := TDictionary<Cardinal, TPSPKernelObject>.Create;
  for var I := 0 to 127 do
    FReady[I] := TList<TPSPThread>.Create;
  FThreads := TList<TPSPThread>.Create;
  FTimers := TList<TPSPTimer>.Create;
  FIntFrames := TList<TPSPFrame>.Create;
  FPendingInts := TQueue<TPSPPendingInterrupt>.Create;
  FVolatileWaiters := TList<TPSPThread>.Create;
  FEventHandlers := TList<TPSPKernelObject>.Create;
  FThreadEvents := TQueue<TPSPThreadEvent>.Create;
  FKernelPartition := TPSPPartition.Create(1, $08000000, $00400000);
  FVolatilePartition := TPSPPartition.Create(5, $08400000, $00400000);
  FUserPartition := TPSPPartition.Create(2, PSPUserBase, PSPUserEnd - PSPUserBase);
  // User thread stacks come from the memory above the user partition.
  FStackPartition := TPSPPartition.Create(2, $0A000000, $01E00000);
  FDebugOut := TStringBuilder.Create;
  Reset;
end;

destructor TPSPKernel.Destroy;
begin
  for var O in FObjects.Values do
    O.Free;
  FObjects.Free;
  FBlocks.Free;
  for var I := 0 to 127 do
    FReady[I].Free;
  FThreads.Free;
  FTimers.Free;
  FIntFrames.Free;
  FPendingInts.Free;
  FVolatileWaiters.Free;
  FThreadEvents.Free;
  FEventHandlers.Free;
  FKernelPartition.Free;
  FVolatilePartition.Free;
  FUserPartition.Free;
  FStackPartition.Free;
  FDebugOut.Free;
  inherited;
end;

procedure TPSPKernel.Reset;
begin
  for var O in FObjects.Values do
    O.Free;
  FObjects.Clear;
  FBlocks.Clear;
  for var I := 0 to 127 do
    FReady[I].Clear;
  FillChar(FReadyMask, SizeOf(FReadyMask), 0);
  FThreads.Clear;
  FTimers.Clear;
  FIntFrames.Clear;
  FPendingInts.Clear;
  FVolatileWaiters.Clear;
  FEventHandlers.Clear;
  FThreadEvents.Clear;
  FillChar(FSubIntr, SizeOf(FSubIntr), 0);
  FillChar(FIntrHandlers, SizeOf(FIntrHandlers), 0);
  // Audio, DMA, GE, VBlank, ME and the last one belong to firmware drivers.
  for var I in [10, 21, 25, 30, 31, 67] do
  begin
    FIntrHandlers[I].Handler := $88000000;
    FIntrHandlers[I].Enabled := True;
  end;
  FCurrent := nil;
  FNextUID := $00100001;
  FTimerSeq := 0;
  FThreadSeq := 0;
  FRescheduleNeeded := False;
  FDispatchSuspended := False;
  FIntrSuspendLevel := 0;
  FExited := False;
  FExitCallback := 0;
  FCompiledSdkVersion := 0;
  FCompilerVersion := 0;
  FSdkVersionSet := False;
  FVolatileLocked := False;
  FTlsplCount := 0;
  FIdle := True;
  BusyUntil := 0;
  FDebugOut.Clear;
  FKernelPartition.Reset;
  FVolatilePartition.Reset;
  FUserPartition.Reset;
  FStackPartition.Reset;
  FTrapBase := FKernelPartition.Alloc($100, akLow, 0, 256, 'traps');
  // Return trap, thread exit trap.
  FMemory.Write32(FTrapBase + 0, (PSPTrapReturn shl 6) or $0C);
  FMemory.Write32(FTrapBase + 4, 0);
  FMemory.Write32(FTrapBase + 8, (PSPTrapThreadExit shl 6) or $0C);
  FMemory.Write32(FTrapBase + 12, 0);
  FIntStack := FKernelPartition.Alloc($10000, akLow, 0, 256, 'interrupt stack') + $10000;
  // The first 16 KB of user memory belong to the kernel on hardware.
  FUserPartition.Alloc($4000, akAddress, PSPUserBase, 256, 'reserved');
  // The recording setup (PSPLink) keeps about 280 KB near the top of user
  // memory, under a 2 KB hole.
  FUserPartition.Alloc($45800, akAddress, PSPUserEnd - $46000, 256, 'psplink');
  // The two idle threads have ids of their own.
  FIdleThreadIds[0] := FNextUID;
  Inc(FNextUID, 2);
  FIdleThreadIds[1] := FNextUID;
  Inc(FNextUID, 2);
  FScheduler.Cancel(TPSPEvent.Kernel);
  FHLE.Clear;
  RegisterAll;
  FHLE.Register('PSPKernelInternal', $00000001, 'kernel busy', hKernelBusy);
  FBusyStub := FTrapBase + $10;
  FMemory.Write32(FBusyStub, (Cardinal(FHLE.Find('PSPKernelInternal', $00000001)) shl 6) or $0C);
  FMemory.Write32(FBusyStub + 4, 0);
end;

procedure TPSPKernel.ScrambleCallerSaved;
begin
  PSPClobberCallerSaved(FCPU.Ctx);
end;

procedure TPSPKernel.SpendPreemptible(Ns: Int64; YieldEqual: Boolean);
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt or (Ns <= PSPBusyChunkNs) then
  begin
    Spend(Ns);
    if YieldEqual then
      YieldCurrent;
    Exit;
  end;
  // The call returns through a stub that spends the time a slice at a time.
  T.BusyNs := Ns;
  T.BusyYieldEqual := YieldEqual;
  T.BusyAt := FScheduler.Now;
  T.BusyPC := FCPU.Ctx.PC;
  T.BusyNPC := FCPU.Ctx.NPC;
  FCPU.Ctx.PC := FBusyStub;
  FCPU.Ctx.NPC := FBusyStub + 4;
end;

procedure TPSPKernel.SpendThenWait(BusyNs, WaitNs: Int64; Value: Cardinal);
begin
  FHLE.Result(Value);
  var T := FCurrent;
  if (T = nil) or not CanWait then
    Exit;
  // Without a wait the driver's completion still hands the CPU to a ready
  // thread of the caller's priority (threads/scheduling/dispatch).
  if BusyNs > PSPBusyChunkNs then
  begin
    // The busy stub begins the wait when the work is done.
    T.BusyWaitNs := WaitNs;
    T.BusyWaitResult := Value;
    T.BusyResumeNs := PSPDriverResumeNs;
    SpendPreemptible(BusyNs, WaitNs <= 0);
    Exit;
  end;
  Spend(BusyNs);
  if WaitNs > 0 then
    DeviceWait(T, WaitNs, Value)
  else
    YieldCurrent;
end;

procedure TPSPKernel.SpendThen(BusyNs: Int64; const Next: IPSPStateAction);
begin
  var T := FCurrent;
  if (T <> nil) and not InInterrupt and (BusyNs > PSPBusyChunkNs) then
  begin
    T.BusyThen := Next;
    T.BusyResumeNs := PSPDriverResumeNs;
    SpendPreemptible(BusyNs);
    Exit;
  end;
  Spend(BusyNs);
  Next.Run(0);
end;

procedure TPSPKernel.DeviceWait(T: TPSPThread; WaitNs: Int64; Value: Cardinal);
begin
  if WaitNs <= 0 then
    Exit;
  BeginWait(PSPWaitEventFlag, nil, 0, 0, False, DeviceWaitRetry, nil, 'iodev');
  if T.Wait.HLETag <> 'iodev' then
    Exit;
  T.Wait.Data[0] := Value;
  AddWakeTimer(FScheduler.Now + WaitNs, T, 'iodev', Value, 0);
end;

function TPSPKernel.DeviceWaitRetry(T: TPSPThread): Boolean;
begin
  Result := False;
end;

class function TPSPKernel.MemoryFillTime(Bytes: Cardinal): Int64;
begin
  Result := ((Int64(Bytes) + 255) and not Int64(255)) * 42 div 10;
end;

procedure TPSPKernel.hKernelBusy;
begin
  // Registers stay as the call left them.
  var T := FCurrent;
  if T = nil then
    Exit;
  // Taken off the CPU in the middle, the call costs more to pick up again.
  if FScheduler.Now > T.BusyAt + 2000 then
    if T.BusyResumeNs > 0 then
      Spend(T.BusyResumeNs)
    else
      Spend(PSPBusyResumeNs);
  var Chunk := T.BusyNs;
  if Chunk > PSPBusyChunkNs then
    Chunk := PSPBusyChunkNs;
  Dec(T.BusyNs, Chunk);
  Spend(Chunk - Int64(FHLE.CycleCost) * 1000 div FScheduler.MHz);
  T.BusyAt := FScheduler.Now;
  if T.BusyNs > 0 then
  begin
    FCPU.Ctx.PC := FBusyStub;
    FCPU.Ctx.NPC := FBusyStub + 4;
  end
  else
  begin
    FCPU.Ctx.PC := T.BusyPC;
    FCPU.Ctx.NPC := T.BusyNPC;
    var Handoff := T.BusyYieldEqual;
    T.BusyYieldEqual := False;
    var WaitNs := T.BusyWaitNs;
    T.BusyWaitNs := 0;
    T.BusyResumeNs := 0;
    var Next := T.BusyThen;
    T.BusyThen := nil;
    if Next <> nil then
      Next.Run(0)
    else if WaitNs > 0 then
    begin
      FHLE.Result(T.BusyWaitResult);
      DeviceWait(T, WaitNs, T.BusyWaitResult);
    end
    else if Handoff then
      YieldCurrent;
  end;
end;

function TPSPKernel.AddObject(Obj: TPSPKernelObject): Cardinal;
begin
  Obj.Kernel := Self;
  Obj.UID := FNextUID;
  Inc(FNextUID, 2);
  FObjects.Add(Obj.UID, Obj);
  Result := Obj.UID;
end;

procedure TPSPKernel.DeleteObject(Obj: TPSPKernelObject);
begin
  FObjects.Remove(Obj.UID);
  CancelTimersOf(Obj);
  Obj.Free;
end;

function TPSPKernel.GetObject(UID: Cardinal; Cls: TPSPKernelObjectClass): TPSPKernelObject;
begin
  if not FObjects.TryGetValue(UID, Result) then
    Exit(nil);
  if (Cls <> nil) and not (Result is Cls) then
    Result := nil;
end;

function TPSPKernel.ThreadById(UID: Cardinal): TPSPThread;
begin
  if UID = 0 then
    Exit(FCurrent);
  Result := TPSPThread(GetObject(UID, TPSPThread));
end;

function TPSPKernel.NowUs: Int64;
begin
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  Result := FScheduler.Now div 1000;
end;

procedure TPSPKernel.Spend(Ns: Int64);
begin
  if Ns <= 0 then
    Exit;
  FCPU.AddCycles(Integer((Ns * FScheduler.MHz + 999) div 1000));
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
end;

function TPSPKernel.ReadName(Ptr: Cardinal; out Name: string): Boolean;
begin
  Name := '';
  if Ptr = 0 then
    Exit(False);
  Name := FMemory.ReadString(Ptr, 31);
  Result := True;
end;

function TPSPKernel.ValidUserAddress(Address: Cardinal): Boolean;
begin
  var A := Address and $3FFFFFFF;
  Result := ((A >= $08800000) and (A < $0C000000)) or ((A >= $04000000) and (A < $04800000)) or ((A >= $00010000) and
    (A < $00014000));
  if (Address and $80000000) <> 0 then
    Result := False;
end;

function TPSPKernel.WriteInfo(Ptr: Cardinal; const Buf; StructSize: Cardinal): Boolean;
begin
  // Refer* calls: a size of 0 leaves the struct alone; otherwise up to the
  // real size is written and the size field says what the struct is.
  Result := True;
  if Ptr = 0 then
    Exit(False);
  var Size := FMemory.Read32(Ptr);
  if Size = 0 then
    Exit;
  var Tmp: TBytes;
  SetLength(Tmp, StructSize);
  Move(Buf, Tmp[0], StructSize);
  PCardinal(@Tmp[0])^ := StructSize;
  if Size > StructSize then
    Size := StructSize;
  FMemory.WriteBytes(Ptr, Tmp[0], Size);
end;

{ Ready queue }

procedure TPSPKernel.PushReady(T: TPSPThread; Front: Boolean);
begin
  var P := T.Priority and 127;
  var Q := FReady[P];
  Q.Remove(T);
  if Front then
    Q.Insert(0, T)
  else
    Q.Add(T);
  FReadyMask[P shr 5] := FReadyMask[P shr 5] or (Cardinal(1) shl (P and 31));
end;

procedure TPSPKernel.RemoveReady(T: TPSPThread);
begin
  var P := T.Priority and 127;
  var Q := FReady[P];
  Q.Remove(T);
  if Q.Count = 0 then
    FReadyMask[P shr 5] := FReadyMask[P shr 5] and not (Cardinal(1) shl (P and 31));
end;

{$Q-}
function LowestBit(X: Cardinal): Integer;
const
  DeBruijn: array[0..31] of Byte = (0, 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8, 31, 27, 13, 23, 21, 19,
    16, 7, 26, 12, 18, 6, 11, 5, 10, 9);
begin
  Result := DeBruijn[((X and (not X + 1)) * $077CB531) shr 27];
end;
{$IFDEF PSP_CHECKED}{$Q+}{$ENDIF}

function TPSPKernel.BestReady: TPSPThread;
begin
  for var W := 0 to 3 do
    if FReadyMask[W] <> 0 then
      Exit(FReady[W * 32 + LowestBit(FReadyMask[W])][0]);
  Result := nil;
end;

procedure TPSPKernel.RequestReschedule;
begin
  FRescheduleNeeded := True;
end;

function TPSPKernel.InInterrupt: Boolean;
begin
  Result := FIntFrames.Count > 0;
end;

function TPSPKernel.HasRunnable: Boolean;
begin
  Result := (FCurrent <> nil) or (FIntFrames.Count > 0);
end;

function TPSPKernel.CanWait: Boolean;
begin
  Result := (FCurrent <> nil) and not InInterrupt and not FDispatchSuspended and FCPU.InterruptsEnabled;
end;

function TPSPKernel.RefuseWait: Boolean;
begin
  // A call that may block is turned away before it looks at anything else.
  Result := True;
  if InInterrupt or (FCurrent = nil) then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT)
  else if not CanWait then
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT)
  else
    Result := False;
end;

procedure TPSPKernel.T_(const Fmt: string; const Args: array of const);
begin
  if FTrace then
    FHLE.Log('%d %s: %s', [FScheduler.Now div 1000, PSPThreadName(FCurrent), Format(Fmt, Args)]);
end;

procedure TPSPKernel.SwitchTo(T: TPSPThread);
begin
  if (T = FCurrent) and (T <> nil) then
    Exit;
  if FTrace then
    T_('switch to %s (pending cb %s)', [PSPThreadName(T), BoolToStr((T <> nil) and T.CallbacksPending, True)]);
  if FCurrent <> nil then
  begin
    FCurrent.Ctx := FCPU.Ctx;
    if (FCurrent.Status and PSPThreadRunning) <> 0 then
    begin
      // Preempted while running: it stays first in its priority.
      FCurrent.Status := (FCurrent.Status and not PSPThreadRunning) or PSPThreadReady;
      Inc(FCurrent.PreemptCount);
      PushReady(FCurrent, True);
    end;
  end;
  FCurrent := T;
  if T <> nil then
  begin
    RemoveReady(T);
    T.Status := (T.Status and not PSPThreadReady) or PSPThreadRunning;
    FCPU.Ctx := T.Ctx;
    FIdle := False;
    Spend(PSPSwitchNs);
    if T.CallbacksPending then
    begin
      T.CallbacksPending := False;
      StartCallbacks(T);
    end;
  end
  else
  begin
    FIdle := True;
    FCPU.Stop;
  end;
end;

procedure TPSPKernel.DispatchThread(T: TPSPThread);
begin
  SwitchTo(T);
end;

procedure TPSPKernel.Reschedule;
begin
  if InInterrupt then
  begin
    FRescheduleNeeded := True;
    Exit;
  end;
  // Switching to a thread can run its callbacks, which may settle it back
  // into its wait: then choose again.
  var Rounds := 0;
  repeat
    FRescheduleNeeded := False;
    Inc(Rounds);
    var Running := (FCurrent <> nil) and ((FCurrent.Status and PSPThreadRunning) <> 0);
    // No dispatch while the running thread has interrupts or dispatch off.
    if Running and (FDispatchSuspended or not FCPU.InterruptsEnabled) then
      Exit;
    var Best := BestReady;
    if Running then
    begin
      if (Best <> nil) and (Best.Priority < FCurrent.Priority) then
        SwitchTo(Best);
    end
    else
    begin
      if FCurrent <> nil then
      begin
        FCurrent.Ctx := FCPU.Ctx;
        FCurrent := nil;
      end;
      SwitchTo(Best);
    end;
  until not FRescheduleNeeded or InInterrupt or (Rounds > 256);
end;

procedure TPSPKernel.AfterSyscall;
begin
  // An interrupt about to be taken runs first; the dispatch happens on its
  // way out.
  if FRescheduleNeeded and not ((FPendingInts.Count > 0) and (FIntFrames.Count = 0) and (FIntrSuspendLevel = 0) and
    FCPU.InterruptsEnabled) then
    Reschedule;
  if FThreadEvents.Count > 0 then
    DispatchThreadEvents;
end;

procedure TPSPKernel.EnableDispatch;
begin
  FDispatchSuspended := False;
  RequestReschedule;
end;

{ Waits }

function TPSPKernel.WaitDeadline(TimeoutPtr: Cardinal; out TimeoutEnd: Int64): Int64;
begin
  TimeoutEnd := PSPNever;
  if TimeoutPtr = 0 then
    Exit(PSPNever);
  var Us := Int64(FMemory.Read32(TimeoutPtr));
  TimeoutEnd := FScheduler.Now + Us * 1000;
  if Us < PSPMinTimeoutUs then
    Us := PSPMinTimeoutUs;
  Result := FScheduler.Now + Us * 1000;
end;

procedure TPSPKernel.BeginWait(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean; Retry: TPSPWaitRetry; Abort: TPSPWaitAbort; const Tag: string);
begin
  BeginWaitData(Kind, Obj, Id, TimeoutPtr, AllowCB, Retry, [], Abort, Tag);
end;

function TPSPKernel.BeginWaitData(Kind: Integer; Obj: TPSPKernelObject; Id, TimeoutPtr: Cardinal; AllowCB: Boolean; Retry: TPSPWaitRetry; const Data: array of Cardinal; Abort: TPSPWaitAbort; const Tag: string): Boolean;
begin
  var T := FCurrent;
  if T = nil then
    raise EPSPError.Create('PSP: wait without a current thread');
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  if FTrace then
    T_('wait kind %d id %x cb %s %s', [Kind, Id, BoolToStr(AllowCB, True), Tag]);
  Result := True;
  T.Wait := Default(TPSPWait);
  T.Wait.Kind := Kind;
  T.Wait.Obj := Obj;
  T.Wait.Id := Id;
  T.Wait.TimeoutPtr := TimeoutPtr;
  T.Wait.AllowCB := AllowCB;
  T.Wait.Retry := Retry;
  T.Wait.Abort := Abort;
  T.Wait.HLETag := Tag;
  for var I := 0 to High(Data) do
    if I <= High(T.Wait.Data) then
      T.Wait.Data[I] := Data[I];
  var Check: Int64 := PSPWaitCheckNs;
  if FWaitCheckNs <> 0 then
    Check := FWaitCheckNs;
  FWaitCheckNs := 0;
  var WasFresh := T.Fresh;
  if WasFresh then
    Check := PSPFreshCheckNs;
  T.Fresh := False;
  if (TimeoutPtr <> 0) and ((FScheduler.Now + Check) div 1000 > FScheduler.Now div 1000 +
    Int64(FMemory.Read32(TimeoutPtr))) then
  begin
    // A timeout that has run out by the time the kernel looks at it ends the
    // wait at once, without writing the time left back.
    if Obj <> nil then
      Obj.RemoveWaiter(T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_TIMEOUT);
    if Assigned(Abort) then
      Abort(T);
    T.Wait := Default(TPSPWait);
    if AllowCB then
      CheckCallbacksNow;
    Exit(False);
  end;
  T.Wait.Deadline := WaitDeadline(TimeoutPtr, T.Wait.TimeoutEnd);
  T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
  if T.Wait.Deadline <> PSPNever then
    SetWaitDeadline(T, T.Wait.Deadline);
  if AllowCB and T.HasPendingCallbacks and (T.CallbackDepth < 2) then
  begin
    // Callbacks run before the thread settles into its wait.
    T.Status := (T.Status and not PSPThreadWaiting) or PSPThreadRunning;
    StartCallbacks(T);
    Exit;
  end;
  if WasFresh then
    Spend(PSPFreshBlockNs);
  RequestReschedule;
end;

procedure TPSPKernel.SetWaitData(T: TPSPThread; Index: Integer; Value: Cardinal);
begin
  if T.Wait.Kind <> PSPWaitNone then
    T.Wait.Data[Index] := Value
  else if (T.Frames.Count > 0) and T.Frames.Last.WasWaiting then
  begin
    var F := T.Frames.Last;
    F.SavedWait.Data[Index] := Value;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPKernel.DropWaitTimer(T: TPSPThread);
begin
  var Changed := False;
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Kind = tkWait) and (FTimers[I].Thread = T) then
    begin
      FTimers.Delete(I);
      Changed := True;
    end;
  if Changed then
    ScheduleTimerEvent;
end;

procedure TPSPKernel.SetWaitDeadline(T: TPSPThread; Deadline: Int64);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Kind = tkWait) and (FTimers[I].Thread = T) then
      FTimers.Delete(I);
  T.Wait.Deadline := Deadline;
  if Deadline = PSPNever then
  begin
    ScheduleTimerEvent;
    Exit;
  end;
  var E := Default(TPSPTimer);
  E.At := Deadline;
  Inc(FTimerSeq);
  E.Seq := FTimerSeq;
  E.Kind := tkWait;
  E.Thread := T;
  var I := FTimers.Count;
  while (I > 0) and (FTimers[I - 1].At > Deadline) do
    Dec(I);
  FTimers.Insert(I, E);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.WriteRemaining(T: TPSPThread);
begin
  if T.Wait.TimeoutPtr = 0 then
    Exit;
  if T.Wait.TimeoutEnd = PSPNever then
    Exit;
  var Left := (T.Wait.TimeoutEnd - FScheduler.Now) div 1000;
  if Left < 0 then
    Left := 0;
  FMemory.Write32(T.Wait.TimeoutPtr, Cardinal(Left));
end;

procedure TPSPKernel.EndWait(T: TPSPThread; Result: Cardinal);
begin
  if FTrace then
    T_('end wait of %s kind %d result %.8x status %x', [PSPThreadName(T), T.Wait.Kind, Result, T.Status]);
  if (T.Status and PSPThreadWaiting) = 0 then
  begin
    // A thread running its callbacks: the result goes to the saved wait.
    if (T.Frames.Count > 0) and T.Frames.Last.WasWaiting then
    begin
      var F := T.Frames.Last;
      F.WasWaiting := False;
      F.Saved.GPR[2] := Result;
      F.SavedWait.Kind := PSPWaitNone;
      T.Frames[T.Frames.Count - 1] := F;
    end;
    Exit;
  end;
  if T.Wait.Obj <> nil then
    T.Wait.Obj.RemoveWaiter(T);
  if Result = SCE_KERNEL_ERROR_WAIT_TIMEOUT then
  begin
    if T.Wait.TimeoutPtr <> 0 then
      FMemory.Write32(T.Wait.TimeoutPtr, 0);
  end
  else
    WriteRemaining(T);
  DropWaitTimer(T);
  if (Result <> 0) and Assigned(T.Wait.Abort) then
    T.Wait.Abort(T);
  if (Result <> 0) and T.Wait.FailAsZero then
    Result := 0;
  T.Wait := Default(TPSPWait);
  T.CallbacksPending := False;
  T.SetResult(Result);
  T.Status := T.Status and not PSPThreadWaiting;
  if (T.Status and PSPThreadSuspended) = 0 then
  begin
    T.Status := T.Status or PSPThreadReady;
    PushReady(T, False);
  end;
  RequestReschedule;
end;

procedure TPSPKernel.WakeThread(T: TPSPThread);
begin
  EndWait(T, 0);
end;

{ Timers }

procedure TPSPKernel.ScheduleTimerEvent;
begin
  if FTimers.Count = 0 then
    FScheduler.Cancel(TPSPEvent.Kernel)
  else
    FScheduler.Schedule(TPSPEvent.Kernel, FTimers[0].At);
end;

function TPSPKernel.AddTimer(At: Int64; Owner: TObject; const Event: TPSPTimerEvent): Int64;
begin
  if Assigned(Event) then
    raise EInvalidOpException.Create('PSP timers require an explicit state action');
  Result := AddStateTimer(At, Owner, nil);
end;

function TPSPKernel.AddStateTimer(At: Int64; Owner: TObject; const Action: IPSPStateAction): Int64;
begin
  var E := Default(TPSPTimer);
  E.At := At;
  Inc(FTimerSeq);
  E.Seq := FTimerSeq;
  E.Kind := tkCustom;
  E.Owner := Owner;
  E.Action := Action;
  var I := FTimers.Count;
  while (I > 0) and (FTimers[I - 1].At > At) do
    Dec(I);
  FTimers.Insert(I, E);
  ScheduleTimerEvent;
  Result := E.Seq;
end;

function TPSPKernel.AddWakeTimer(At: Int64; Thread: TPSPThread; const Tag: string; Value: Cardinal; DataSlot: Integer; Owner: TObject): Int64;
begin
  if Owner = nil then
    Owner := Thread;
  Result := AddStateTimer(At, Owner, TPSPStateAction.Create(StateWake, [Thread], [Value, DataSlot], Tag));
end;

procedure TPSPKernel.StateWake(Action: TPSPStateAction; Value: Cardinal);
begin
  var T := TPSPThread(Action.Obj(0));
  if T.IsWaiting and (T.Wait.HLETag = Action.Text) then
  begin
    var Slot := Action.Arg(1);
    if Slot >= 0 then
    begin
      if Slot > High(T.Wait.Data) then
        raise EReadError.Create('Invalid state wake data slot');
      EndWait(T, T.Wait.Data[Slot]);
    end
    else
      EndWait(T, Cardinal(Action.Arg(0)));
  end;
end;

procedure TPSPKernel.CancelTimer(Handle: Int64);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if FTimers[I].Seq = Handle then
    begin
      FTimers.Delete(I);
      Break;
    end;
  ScheduleTimerEvent;
end;

procedure TPSPKernel.CancelTimersOf(Owner: TObject);
begin
  for var I := FTimers.Count - 1 downto 0 do
    if (FTimers[I].Owner = Owner) or (FTimers[I].Thread = Owner) then
      FTimers.Delete(I);
  ScheduleTimerEvent;
end;

procedure TPSPKernel.OnTimerEvent;
begin
  while (FTimers.Count > 0) and (FTimers[0].At <= FScheduler.Now) do
  begin
    var E := FTimers[0];
    FTimers.Delete(0);
    case E.Kind of
      tkWait:
        if (E.Thread <> nil) and E.Thread.IsWaiting then
        begin
          // The timer interrupt and the wakeup take the CPU a while, from
          // whatever was running.
          if E.Thread.Wait.Kind = PSPWaitDelay then
          begin
            Spend(PSPDelayLatencyNs);
            EndWait(E.Thread, 0);
          end
          else
          begin
            Spend(PSPWaitLatencyNs);
            var Obj := E.Thread.Wait.Obj;
            EndWait(E.Thread, SCE_KERNEL_ERROR_WAIT_TIMEOUT);
            if (Obj <> nil) and FObjects.ContainsKey(Obj.UID) then
              Obj.WaiterGone;
          end;
        end;
      tkCustom:
        if E.Action <> nil then
          E.Action.Run
        else if Assigned(E.Event) then
          E.Event();
    end;
  end;
  ScheduleTimerEvent;
end;

{ Guest calls }

procedure TPSPKernel.EnterGuest(Func, SP, GP: Cardinal; const Args: array of Cardinal);
begin
  for var I := 0 to High(Args) do
    if I < 8 then
      FCPU.Ctx.GPR[4 + I] := Args[I];
  FCPU.Ctx.GPR[29] := SP;
  if GP <> 0 then
    FCPU.Ctx.GPR[28] := GP;
  FCPU.Ctx.GPR[31] := FTrapBase;
  FCPU.SetPC(Func);
end;

procedure TPSPKernel.CallGuest(Func: Cardinal; const Args: array of Cardinal; const OnReturn: TPSPGuestReturn; GP: Cardinal; const ReturnState: IPSPStateAction);
begin
  if Assigned(OnReturn) then
    raise EInvalidOpException.Create('PSP guest returns require an explicit state action');
  if InInterrupt then
  begin
    // Nested call inside an interrupt handler.
    var F := Default(TPSPFrame);
    F.Kind := fkInterrupt;
    F.Saved := FCPU.Ctx;
    F.OnReturn := OnReturn;
    F.ReturnState := ReturnState;
    FIntFrames.Add(F);
    EnterGuest(Func, (FCPU.Ctx.GPR[29] - 64) and not Cardinal(15), GP, Args);
    Exit;
  end;
  var T := FCurrent;
  if T = nil then
    raise EPSPError.Create('PSP: guest call without a thread');
  var F := Default(TPSPFrame);
  F.Kind := fkHLE;
  F.Saved := FCPU.Ctx;
  F.OnReturn := OnReturn;
  F.ReturnState := ReturnState;
  T.Frames.Add(F);
  EnterGuest(Func, (FCPU.Ctx.GPR[29] - 64) and not Cardinal(15), GP, Args);
end;

procedure TPSPKernel.StartCallbacks(T: TPSPThread; KeepResult: Boolean);
begin
  if FTrace then
    T_('callbacks start, wait kind %d', [T.Wait.Kind]);
  // T is current. Saves the context (and wait) and runs the first pending callback.
  var F := Default(TPSPFrame);
  F.Kind := fkCallback;
  F.KeepResult := KeepResult;
  F.Saved := FCPU.Ctx;
  F.SavedWait := T.Wait;
  F.WasWaiting := T.Wait.Kind <> PSPWaitNone;
  if F.WasWaiting then
  begin
    if T.Wait.Obj <> nil then
      T.Wait.Obj.RemoveWaiter(T);
    DropWaitTimer(T);
  end;
  T.Wait := Default(TPSPWait);
  T.Status := (T.Status and not PSPThreadWaiting) or PSPThreadRunning;
  if not RunNextCallback(T, F) then
  begin
    // Nothing to run after all: settle back.
    FCPU.Ctx := F.Saved;
    T.Wait := F.SavedWait;
    if F.WasWaiting then
    begin
      T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
      if T.Wait.Obj <> nil then
        T.Wait.Obj.AddWaiter(T);
      if T.Wait.Deadline <> PSPNever then
        SetWaitDeadline(T, T.Wait.Deadline);
      RequestReschedule;
    end;
    Exit;
  end;
  T.Frames.Add(F);
end;

function TPSPKernel.RunNextCallback(T: TPSPThread; var Frame: TPSPFrame): Boolean;
begin
  for var CB in T.Callbacks do
    if CB.NotifyCount > 0 then
    begin
      var Count := CB.NotifyCount;
      var Arg := CB.NotifyArg;
      CB.NotifyCount := 0;
      CB.NotifyArg := 0;
      Frame.Callback := CB;
      Inc(Frame.CallbacksRan);
      FCPU.Ctx := Frame.Saved;
      EnterGuest(CB.Func, (Frame.Saved.GPR[29] - 64) and not Cardinal(15), CB.GP, [Count, Arg, CB.Common]);
      Exit(True);
    end;
  Result := False;
end;

procedure TPSPKernel.FinishCallbackFrame(T: TPSPThread);
begin
  var F := T.Frames.Last;
  var Ret := FCPU.Ctx.GPR[2];
  if (F.Callback <> nil) and (Ret <> 0) and FObjects.ContainsKey(F.Callback.UID) then
  begin
    T.Callbacks.Remove(F.Callback);
    DeleteObject(F.Callback);
  end;
  F.Callback := nil;
  if RunNextCallback(T, F) then
  begin
    T.Frames[T.Frames.Count - 1] := F;
    Exit;
  end;
  T.Frames.Delete(T.Frames.Count - 1);
  FCPU.Ctx := F.Saved;
  if FTrace then
    T_('callbacks done, was waiting %s kind %d', [BoolToStr(F.WasWaiting, True), F.SavedWait.Kind]);
  if F.WasWaiting then
  begin
    T.Wait := F.SavedWait;
    var Done := False;
    if (T.Wait.Deadline <> PSPNever) and (T.Wait.Deadline <= FScheduler.Now) then
    begin
      if T.Wait.Kind = PSPWaitDelay then
        FCPU.Ctx.GPR[2] := 0
      else
      begin
        FCPU.Ctx.GPR[2] := SCE_KERNEL_ERROR_WAIT_TIMEOUT;
        if T.Wait.TimeoutPtr <> 0 then
          FMemory.Write32(T.Wait.TimeoutPtr, 0);
        if Assigned(T.Wait.Abort) then
          T.Wait.Abort(T);
        T.Wait.TimeoutPtr := 0;
      end;
      Done := True;
    end
    else if Assigned(T.Wait.Retry) and T.Wait.Retry(T) then
      Done := True;
    if Done then
    begin
      WriteRemaining(T);
      T.Wait := Default(TPSPWait);
    end
    else
    begin
      T.Status := (T.Status and not PSPThreadRunning) or PSPThreadWaiting;
      if T.Wait.Obj <> nil then
        T.Wait.Obj.AddWaiter(T);
      if T.Wait.Deadline <> PSPNever then
        SetWaitDeadline(T, T.Wait.Deadline);
      RequestReschedule;
    end;
  end
  else if not F.KeepResult then
    // sceKernelCheckCallback returns whether callbacks ran.
    FCPU.Ctx.GPR[2] := Ord(F.CallbacksRan > 0);
end;

function TPSPKernel.CheckCallbacksNow(KeepResult: Boolean): Boolean;
begin
  var T := FCurrent;
  // One level of callbacks inside a callback, as with blocking CB waits.
  if (T = nil) or not T.HasPendingCallbacks or (T.CallbackDepth >= 2) then
    Exit(False);
  StartCallbacks(T, KeepResult);
  Result := True;
end;

function TPSPKernel.CheckCallbacks: Boolean;
begin
  if InInterrupt then
    Exit(False);
  Result := CheckCallbacksNow;
end;

procedure TPSPKernel.NotifyCallback(CB: TPSPCallback; Arg: Cardinal);
begin
  if FTrace then
    T_('notify %s of %s', [CB.Name, PSPThreadName(CB.Thread)]);
  Inc(CB.NotifyCount);
  CB.NotifyArg := Arg;
  var T := CB.Thread;
  if (T <> nil) and T.IsWaiting and T.Wait.AllowCB and not T.CallbacksPending and (T.CallbackDepth < 2) then
  begin
    // Leave the wait queue; run callbacks when dispatched, then wait again.
    T.CallbacksPending := True;
    if T.Wait.Obj <> nil then
      T.Wait.Obj.RemoveWaiter(T);
    DropWaitTimer(T);
    T.Ctx.GPR[2] := 0;
    // The saved wait is restored by StartCallbacks through T.Wait.
    T.Status := (T.Status and not PSPThreadWaiting);
    if (T.Status and PSPThreadSuspended) = 0 then
    begin
      T.Status := T.Status or PSPThreadReady;
      PushReady(T, False);
    end;
    RequestReschedule;
  end;
end;

procedure TPSPKernel.ReturnTrap;
begin
  if FIntFrames.Count > 0 then
  begin
    var F := FIntFrames.Last;
    FIntFrames.Delete(FIntFrames.Count - 1);
    var Ret := FCPU.Ctx.GPR[2];
    FCPU.Ctx := F.Saved;
    if Assigned(F.OnReturn) then
      F.OnReturn(Ret);
    if F.ReturnState <> nil then
      F.ReturnState.Run(Ret);
    if FIntFrames.Count = 0 then
    begin
      DropStaleInterrupts;
      if FPendingInts.Count > 0 then
        StartNextInterrupt
      else
      begin
        Spend(PSPIntrExitNs);
        var Best := BestReady;
        if (Best <> nil) and ((FCurrent = nil) or (Best.Priority < FCurrent.Priority)) and not FDispatchSuspended then
          Spend(PSPIntrDispatchNs);
        if FCurrent = nil then
        begin
          FIdle := True;
          FCPU.Stop;
        end;
        if FRescheduleNeeded then
          Reschedule;
      end;
    end;
    Exit;
  end;
  var T := FCurrent;
  if (T = nil) or (T.Frames.Count = 0) then
    raise EPSPGuestFault.CreateFmt('PSP: return trap without a frame (thread %s)', [PSPThreadName(T)]);
  var F := T.Frames.Last;
  case F.Kind of
    fkCallback:
      FinishCallbackFrame(T);
    fkHLE, fkThreadEvent:
      begin
        T.Frames.Delete(T.Frames.Count - 1);
        var Ret := FCPU.Ctx.GPR[2];
        FCPU.Ctx := F.Saved;
        if Assigned(F.OnReturn) then
          F.OnReturn(Ret);
        if F.ReturnState <> nil then
          F.ReturnState.Run(Ret);
      end;
  else
    T.Frames.Delete(T.Frames.Count - 1);
  end;
  if FRescheduleNeeded then
    Reschedule;
end;

procedure TPSPKernel.ThreadExitTrap;
begin
  Spend(PSPExitThreadNs);
  var T := FCurrent;
  ExitCurrent(FCPU.Ctx.GPR[2]);
  if (T <> nil) and T.DeleteOnExit and (FCurrent = T) then
  begin
    T.Ctx := FCPU.Ctx;
    FCurrent := nil;
    DeleteThread(T);
    Reschedule;
  end;
end;

procedure TPSPKernel.Trap(Code: Cardinal);
begin
  case Code of
    PSPTrapReturn:
      ReturnTrap;
    PSPTrapThreadExit:
      ThreadExitTrap;
  else
    raise EPSPGuestFault.CreateFmt('PSP: unknown kernel trap %d', [Code]);
  end;
end;

{ Interrupts }

procedure TPSPKernel.QueueInterrupt(Func: Cardinal; const Args: array of Cardinal; GP: Cardinal; const OnReturn: TPSPGuestReturn; EntryNs: Int64; OwnerUID: Cardinal; const ReturnState: IPSPStateAction);
begin
  if Assigned(OnReturn) then
    raise EInvalidOpException.Create('PSP interrupt returns require an explicit state action');
  var P := Default(TPSPPendingInterrupt);
  P.Func := Func;
  if Length(Args) > 0 then
    P.A0 := Args[0];
  if Length(Args) > 1 then
    P.A1 := Args[1];
  if Length(Args) > 2 then
    P.A2 := Args[2];
  if Length(Args) > 3 then
    P.A3 := Args[3];
  P.GP := GP;
  P.OnReturn := OnReturn;
  P.ReturnState := ReturnState;
  P.EntryNs := EntryNs;
  P.OwnerUID := OwnerUID;
  FPendingInts.Enqueue(P);
  FCPU.Stop;
end;

procedure TPSPKernel.TriggerInterrupt(IntNo, SubNo: Integer; Arg2: Cardinal);
begin
  if (IntNo < 0) or (IntNo > High(FSubIntr)) then
    Exit;
  for var S := 0 to 31 do
  begin
    if (SubNo >= 0) and (S <> SubNo) then
      Continue;
    var H := FSubIntr[IntNo, S];
    if H.Enabled and (H.Handler <> 0) then
      QueueInterrupt(H.Handler, [Cardinal(S), H.Arg, Arg2], H.GP);
  end;
end;

function TPSPKernel.QueueSubInterrupts(IntNo: Integer; Arg2: Cardinal; const Done: TProc; const StateDone: IPSPStateAction): Integer;
begin
  if Assigned(Done) then
    raise EInvalidOpException.Create('PSP sub-interrupt completion requires an explicit state action');
  Result := 0;
  if (IntNo < 0) or (IntNo > High(FSubIntr)) then
    Exit;
  var Last := -1;
  for var S := 0 to 31 do
    if FSubIntr[IntNo, S].Enabled and (FSubIntr[IntNo, S].Handler <> 0) then
      Last := S;
  for var S := 0 to Last do
  begin
    var H := FSubIntr[IntNo, S];
    if not H.Enabled or (H.Handler = 0) then
      Continue;
    Inc(Result);
    if S = Last then
    begin
      QueueInterrupt(H.Handler, [Cardinal(S), H.Arg, Arg2], H.GP, nil, 0, 0, StateDone);
    end
    else
      QueueInterrupt(H.Handler, [Cardinal(S), H.Arg, Arg2], H.GP);
  end;
end;

procedure TPSPKernel.DropStaleInterrupts;
begin
  // Handlers of alarms and timers deleted while they were pending never run.
  while (FPendingInts.Count > 0) and (FPendingInts.Peek.OwnerUID <> 0) and
        not FObjects.ContainsKey(FPendingInts.Peek.OwnerUID) do
    FPendingInts.Dequeue;
end;

procedure TPSPKernel.StartNextInterrupt;
begin
  var P := FPendingInts.Dequeue;
  var F := Default(TPSPFrame);
  F.Kind := fkInterrupt;
  F.Saved := FCPU.Ctx;
  F.OnReturn := P.OnReturn;
  F.ReturnState := P.ReturnState;
  FIntFrames.Add(F);
  FIdle := False;
  if FCurrent <> nil then
    Inc(FCurrent.IntrPreemptCount);
  if P.EntryNs > 0 then
    Spend(P.EntryNs);
  EnterGuest(P.Func, FIntStack - 64, P.GP, [P.A0, P.A1, P.A2, P.A3]);
end;

procedure TPSPKernel.ProcessInterrupts;
begin
  DropStaleInterrupts;
  if (FPendingInts.Count = 0) or (FIntFrames.Count > 0) then
    Exit;
  if (FIntrSuspendLevel > 0) or not FCPU.InterruptsEnabled then
    Exit;
  StartNextInterrupt;
end;

{ Memory }

function TPSPKernel.AllocUser(Size: Cardinal; High: Boolean; const Tag: string): Cardinal;
begin
  if High then
    Result := FUserPartition.Alloc(Size, akHigh, 0, 256, Tag)
  else
    Result := FUserPartition.Alloc(Size, akLow, 0, 256, Tag);
end;

function TPSPKernel.AllocKernel(Size: Cardinal; const Tag: string): Cardinal;
begin
  Result := FKernelPartition.Alloc(Size, akLow, 0, 256, Tag);
end;

function TPSPKernel.Partition(Id: Integer): TPSPPartition;
begin
  case Id of
    1, 3, 4:
      Result := FKernelPartition;
    2, 6:
      Result := FUserPartition;
    5:
      Result := FVolatilePartition;
  else
    Result := nil;
  end;
end;

procedure TPSPKernel.DebugWrite(const S: RawByteString);
begin
  FDebugOut.Append(string(S));
end;

function TPSPKernel.TakeDebugOutput: string;
begin
  Result := FDebugOut.ToString;
  FDebugOut.Clear;
end;

function TPSPKernel.DescribeThreads: string;
begin
  Result := '';
  for var T in FThreads do
    Result := Result + Format('%s st=%x prio=%d wait=%d/%s pc=%.8x'#10,
      [PSPThreadName(T), T.Status, T.Priority, T.Wait.Kind, T.Wait.HLETag, T.Ctx.PC]);
end;

{ PSP.Kernel: threads and callbacks. }

function TPSPKernel.CreateThread(const Name: string; Entry: Cardinal; Priority: Integer; StackSize, Attr, GP, ModuleId: Cardinal): TPSPThread;
begin
  StackSize := AlignUp(StackSize, 256);
  var Part := FStackPartition;
  if (Attr and $80000000) = 0 then
    Part := FKernelPartition
  else if (Attr and $00400000) <> 0 then
    Part := FUserPartition;
  var Stack: Cardinal;
  if Part = FUserPartition then
    Stack := Part.Alloc(StackSize, akLow, 0, 256, 'stack:' + Name)
  else
    Stack := Part.Alloc(StackSize, akHigh, 0, 256, 'stack:' + Name);
  if Stack = 0 then
    Exit(nil);
  var T := TPSPThread.Create;
  T.Name := Name;
  T.Entry := Entry;
  T.Priority := Priority;
  T.InitPriority := Priority;
  if (Attr and $80000000) <> 0 then
    Attr := Attr or $FF;
  T.Attr := Attr;
  T.StackBlock := Stack;
  T.StackSize := StackSize;
  T.StackTop := Stack + StackSize;
  T.StackPartition := Part;
  T.GP := GP;
  T.ModuleId := ModuleId;
  T.Status := PSPThreadDormant;
  T.ExitStatus := SCE_KERNEL_ERROR_DORMANT;
  if (Attr and $00100000) = 0 then
    FMemory.Fill(Stack, $FF, StackSize);
  AddObject(T);
  // The bottom of the stack holds the owner's id.
  FMemory.Write32(Stack, T.UID);
  FThreads.Add(T);
  Result := T;
end;

procedure TPSPKernel.StartThread(T: TPSPThread; ArgSize, ArgPtr: Cardinal; const ArgData: TBytes);
begin
  var C := Default(TPSPContext);
  // A new thread's VFPU registers read as NaN.
  for var I := 0 to High(C.V) do
    C.V[I] := $7F800001;
  // What the kernel leaves in a new thread's registers.
  for var I := 1 to 31 do
    C.GPR[I] := $DEADBEEF;
  C.GPR[27] := 0;
  C.HI := $DEADBEEF;
  C.LO := $DEADBEEF;
  for var I := 0 to 31 do
    C.FPR[I] := $7F800001;
  C.FCR31 := $00000E00;
  C.VC := FCPU.Ctx.VC;
  C.VC[VFPU_PFXS] := $E4;
  C.VC[VFPU_PFXT] := $E4;
  C.VC[VFPU_PFXD] := 0;
  C.VC[VFPU_CC] := $3F;
  var Top := T.StackTop;
  // The kernel keeps the thread's id at the stack top; k0 points there.
  var K0 := Top - $100;
  FMemory.Fill(K0, 0, $100);
  FMemory.Write32(K0 + $C0, T.UID);
  FMemory.Write32(K0 + $C8, T.StackBlock);
  FMemory.Write32(K0 + $F8, $FFFFFFFF);
  FMemory.Write32(K0 + $FC, $FFFFFFFF);
  var SP := K0;
  var A1: Cardinal := 0;
  if Length(ArgData) > 0 then
  begin
    SP := (SP - Cardinal(Length(ArgData))) and not Cardinal(15);
    FMemory.WriteBytes(SP, ArgData[0], Length(ArgData));
    A1 := SP;
    ArgSize := Length(ArgData);
  end
  else if (ArgPtr <> 0) and (ArgSize > 0) then
  begin
    SP := (SP - ArgSize) and not Cardinal(15);
    FMemory.Copy(SP, ArgPtr, ArgSize);
    A1 := SP;
  end
  else
    ArgSize := 0;
  SP := SP - 64;
  C.GPR[4] := ArgSize;
  C.GPR[5] := A1;
  C.GPR[26] := K0;
  C.GPR[28] := T.GP;
  C.GPR[29] := SP;
  C.GPR[31] := FTrapBase + 8;
  C.PC := T.Entry;
  C.NPC := T.Entry + 4;
  T.Ctx := C;
  T.ExitStatus := SCE_KERNEL_ERROR_NOT_DORMANT;
  T.WakeupCount := 0;
  T.Priority := T.InitPriority;
  T.Wait := Default(TPSPWait);
  T.Frames.Clear;
  T.BusyNs := 0;
  T.BusyYieldEqual := False;
  T.Fresh := True;
  T.Status := PSPThreadReady;
  Inc(FThreadSeq);
  T.Seq := FThreadSeq;
  PushReady(T, False);
  RequestReschedule;
end;

procedure TPSPKernel.KillThreadFrames(T: TPSPThread);
begin
  T.Frames.Clear;
  T.CallbacksPending := False;
  DropWaitTimer(T);
  while T.ExtraStacks.Count > 0 do
  begin
    var Block := T.ExtraStacks.Last;
    T.ExtraStacks.Delete(T.ExtraStacks.Count - 1);
    T.StackPartition.FreeBlock(Block);
  end;
end;

procedure TPSPKernel.WakeEndWaiters(T: TPSPThread);
begin
  while T.EndWaiters.Count > 0 do
  begin
    var W := T.EndWaiters[0];
    T.EndWaiters.Delete(0);
    if W.IsWaiting and (W.Wait.Obj = T) then
      EndWait(W, T.ExitStatus);
  end;
end;

procedure TPSPKernel.ExitCurrent(Status: Cardinal);
begin
  var T := FCurrent;
  if T = nil then
    Exit;
  T.ExitStatus := Status;
  T.Status := PSPThreadDormant;
  KillThreadFrames(T);
  WakeEndWaiters(T);
  ReleaseMutexesOf(T);
  ReleaseTlsOf(T);
  NotifyThreadEvent(PSPThreadEventExit, T);
  if Assigned(T.OnExit) then
  begin
    var Hook := T.OnExit;
    T.OnExit := nil;
    Hook(T);
  end;
  if T.ExitState <> nil then
  begin
    var Hook := T.ExitState;
    T.ExitState := nil;
    Hook.Run(T.ExitStatus);
  end;
  RequestReschedule;
end;

procedure TPSPKernel.TerminateThread(T: TPSPThread; Status: Cardinal);
begin
  var Obj: TPSPKernelObject := nil;
  if T.IsWaiting then
  begin
    Obj := T.Wait.Obj;
    if Obj <> nil then
      Obj.RemoveWaiter(T);
    if Assigned(T.Wait.Abort) then
      T.Wait.Abort(T);
  end;
  RemoveReady(T);
  T.Wait := Default(TPSPWait);
  T.ExitStatus := Status;
  T.Status := PSPThreadDormant;
  KillThreadFrames(T);
  // The threads waiting for the end are made ready, but nothing is dispatched.
  var Pending := FRescheduleNeeded;
  WakeEndWaiters(T);
  ReleaseMutexesOf(T);
  ReleaseTlsOf(T);
  if Obj <> nil then
    Obj.WaiterGone;
  FRescheduleNeeded := Pending;
  if Assigned(T.OnExit) then
  begin
    var Hook := T.OnExit;
    T.OnExit := nil;
    Hook(T);
  end;
  if T.ExitState <> nil then
  begin
    var Hook := T.ExitState;
    T.ExitState := nil;
    Hook.Run(T.ExitStatus);
  end;
end;

procedure TPSPKernel.FreeThreadStacks(T: TPSPThread);
begin
  if T.StackBlock = 0 then
    Exit;
  if (T.Attr and $00200000) <> 0 then
    FMemory.Fill(T.StackBlock, 0, T.StackSize);
  T.StackPartition.FreeBlock(T.StackBlock);
  T.StackBlock := 0;
end;

procedure TPSPKernel.DeleteThread(T: TPSPThread);
begin
  NotifyThreadEvent(PSPThreadEventDelete, T);
  RemoveReady(T);
  KillThreadFrames(T);
  for var CB in T.Callbacks.ToArray do
    DeleteObject(CB);
  T.Callbacks.Clear;
  FreeThreadStacks(T);
  FThreads.Remove(T);
  if FCurrent = T then
    FCurrent := nil;
  DeleteObject(T);
end;

procedure TPSPKernel.ChangePriority(T: TPSPThread; Priority: Integer);
begin
  if (T.Status and PSPThreadReady) <> 0 then
  begin
    RemoveReady(T);
    T.Priority := Priority;
    PushReady(T, False);
  end
  else
    T.Priority := Priority;
  if T.IsWaiting and (T.Wait.Obj is TPSPWaitObject) then
  begin
    var Q := TPSPWaitObject(T.Wait.Obj).Waiters;
    if Q.ByPriority and Q.Contains(T) then
    begin
      Q.Remove(T);
      Q.Add(T);
    end;
  end;
  RequestReschedule;
end;

{ HLE: threads }

function ValidUserPriority(P: Integer): Boolean; inline;
begin
  Result := (P >= 8) and (P <= 119);
end;

function TPSPKernel.ValidPriorityFor(P: Integer): Boolean;
begin
  if (FCurrent <> nil) and FCurrent.IsKernel then
    Result := (P >= 1) and (P <= 126)
  else
    Result := ValidUserPriority(P);
end;

procedure TPSPKernel.hCreateThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var NamePtr := FHLE.Arg(0);
  var Entry := FHLE.Arg(1);
  var Prio := FHLE.ArgInt(2);
  var StackSize := FHLE.Arg(3);
  var Attr := FHLE.Arg(4);
  var Name: string;
  if not ReadName(NamePtr, Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var KernelCaller := (FCurrent <> nil) and FCurrent.IsKernel;
  if (Entry <> 0) and not KernelCaller and not ValidUserAddress(Entry) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if StackSize < $200 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE);
    Exit;
  end;
  if not ValidPriorityFor(Prio) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  if KernelCaller then
  begin
    if (Attr and $80000000) = 0 then
      Attr := Attr and not Cardinal($F0000000);
  end
  else
  begin
    if (Attr and $070F9F00) <> 0 then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
      Exit;
    end;
    Attr := (Attr and $00706000) or $80000000;
  end;
  if StackSize > $1E00000 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var ModuleId: Cardinal := 0;
  if FCurrent <> nil then
    ModuleId := FCurrent.ModuleId;
  var T := CreateThread(Name, Entry, Prio, StackSize, Attr, FCPU.Ctx.GPR[28], ModuleId);
  if T = nil then
  begin
    Spend(PSPCreateThreadNs);
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  // Filling the stack is most of it, and other threads may run meanwhile.
  SpendPreemptible(PSPCreateThreadNs + MemoryFillTime(StackSize));
  FHLE.Result(T.UID);
  // Creating a thread leaves dispatching enabled again.
  FDispatchSuspended := False;
  NotifyThreadEvent(PSPThreadEventCreate, T);
end;

procedure TPSPKernel.hStartThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Id := FHLE.Arg(0);
  if Id = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if not T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT);
    Exit;
  end;
  var Size := FHLE.Arg(1);
  var Ptr := FHLE.Arg(2);
  if Ptr <> 0 then
  begin
    // Nothing is copied from an address with no size.
    if (Integer(Size) < 0) or ((Size > 0) and not ValidUserAddress(Ptr) and
      not ((FCurrent <> nil) and FCurrent.IsKernel)) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
      Exit;
    end;
  end
  else
    Size := 0;
  Spend(PSPStartThreadNs);
  FHLE.Result(0);
  // Status bits other than dormant (a suspend) do not survive a start.
  T.Status := PSPThreadDormant;
  StartThread(T, Size, Ptr);
  NotifyThreadEvent(PSPThreadEventStart, T);
  // A better thread gets the CPU at once, ahead of anything else ready;
  // otherwise nothing is dispatched.
  FRescheduleNeeded := False;
  if (FCurrent <> nil) and (T.Priority < FCurrent.Priority) and not InInterrupt and FCPU.InterruptsEnabled then
  begin
    Spend(PSPFirstRunNs);
    SwitchTo(T);
  end;
end;

procedure TPSPKernel.hExitThread;
begin
  if (FCurrent = nil) or InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  Spend(PSPExitThreadNs);
  var T := FCurrent;
  ExitCurrent(FHLE.Arg(0));
  if T.DeleteOnExit and (FCurrent = T) then
  begin
    T.Ctx := FCPU.Ctx;
    FCurrent := nil;
    DeleteThread(T);
    Reschedule;
  end;
end;

procedure TPSPKernel.hExitDeleteThread;
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  Spend(PSPExitThreadNs);
  ExitCurrent(FHLE.Arg(0));
  T.Ctx := FCPU.Ctx;
  FCurrent := nil;
  DeleteThread(T);
  Reschedule;
end;

procedure TPSPKernel.hDeleteThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Id := FHLE.Arg(0);
  var T := ThreadById(Id);
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if (T = FCurrent) or not T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT);
    Exit;
  end;
  Spend(PSPDeleteThreadNs);
  DeleteThread(T);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateThread;
begin
  // Interrupt handlers of programs built before 3.x may still terminate a
  // thread (recorded up to 2.08); starting one is refused regardless.
  if InInterrupt and (FCompiledSdkVersion >= $03000000) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  if T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_DORMANT);
    Exit;
  end;
  Spend(PSPTerminateThreadNs);
  TerminateThread(T, SCE_KERNEL_ERROR_THREAD_TERMINATED);
  FHLE.Result(0);
end;

procedure TPSPKernel.hTerminateDeleteThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  Spend(PSPTerminateThreadNs + PSPDeleteThreadNs);
  if not T.IsDormant then
    TerminateThread(T, SCE_KERNEL_ERROR_THREAD_TERMINATED);
  DeleteThread(T);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadId;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if FCurrent = nil then
    FHLE.Result(0)
  else
    FHLE.Result(FCurrent.UID);
end;

procedure TPSPKernel.hGetThreadCurrentPriority;
begin
  if (FCurrent = nil) or InInterrupt then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT)
  else
    FHLE.Result(Cardinal(FCurrent.Priority));
end;

procedure TPSPKernel.hChangeThreadPriority;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  var P := FHLE.ArgInt(1);
  if P = 0 then
  begin
    if FCurrent = nil then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
      Exit;
    end;
    P := FCurrent.Priority;
  end;
  if not ValidPriorityFor(P) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  if T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_DORMANT);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if (T = FCurrent) and ((T.Status and PSPThreadRunning) <> 0) then
  begin
    // The running thread goes behind the others of its new priority.
    T.Priority := P;
    YieldCurrent;
    Exit;
  end;
  ChangePriority(T, P);
end;

procedure TPSPKernel.YieldCurrent;
begin
  var T := FCurrent;
  if (T = nil) or InInterrupt then
    Exit;
  var Best := BestReady;
  if (Best = nil) or (Best.Priority > T.Priority) then
    Exit;
  T.Ctx := FCPU.Ctx;
  T.Status := (T.Status and not PSPThreadRunning) or PSPThreadReady;
  PushReady(T, False);
  FCurrent := nil;
  SwitchTo(Best);
end;

procedure TPSPKernel.hRotateThreadReadyQueue;
begin
  var P := FHLE.ArgInt(0);
  if FCurrent = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  if P = 0 then
    P := FCurrent.Priority;
  if not ValidPriorityFor(P) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Exit;
  end;
  FHLE.Result(0);
  if P = FCurrent.Priority then
    // The current thread goes behind the others of its priority.
    YieldCurrent
  else if FReady[P].Count > 1 then
  begin
    var T := FReady[P][0];
    FReady[P].Delete(0);
    FReady[P].Add(T);
    RequestReschedule;
  end;
end;

function ThreadInfoStatus(K: TPSPKernel; T: TPSPThread): Cardinal;
begin
  Result := T.Status;
  if T = K.Current then
    Result := (Result and not (PSPThreadReady or PSPThreadWaiting)) or PSPThreadRunning;
end;

procedure TPSPKernel.hReferThreadStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  var P := FHLE.Arg(1);
  if P = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var Size := FMemory.Read32(P);
  var StructSize: Cardinal := $68;
  if FCompiledSdkVersion > $02060010 then
  begin
    StructSize := $6C;
    if Size > StructSize then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE);
      Exit;
    end;
  end;
  var Buf: array[0..$6B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var NameBytes := RawByteString(T.Name);
  if Length(NameBytes) > 31 then
    SetLength(NameBytes, 31);
  if NameBytes <> '' then
    Move(NameBytes[1], Buf[4], Length(NameBytes));
  PCardinal(@Buf[$24])^ := T.Attr;
  PCardinal(@Buf[$28])^ := ThreadInfoStatus(Self, T);
  PCardinal(@Buf[$2C])^ := T.Entry;
  PCardinal(@Buf[$30])^ := T.StackBlock;
  PCardinal(@Buf[$34])^ := T.StackSize;
  PCardinal(@Buf[$38])^ := T.GP;
  PCardinal(@Buf[$3C])^ := Cardinal(T.InitPriority);
  PCardinal(@Buf[$40])^ := Cardinal(T.Priority);
  if T.IsWaiting then
  begin
    PCardinal(@Buf[$44])^ := Cardinal(T.Wait.Kind);
    PCardinal(@Buf[$48])^ := T.Wait.Id;
  end;
  PCardinal(@Buf[$4C])^ := Cardinal(T.WakeupCount);
  PCardinal(@Buf[$50])^ := T.ExitStatus;
  PUInt64(@Buf[$54])^ := UInt64(T.RunClocks);
  PCardinal(@Buf[$5C])^ := T.IntrPreemptCount;
  PCardinal(@Buf[$60])^ := T.PreemptCount;
  PCardinal(@Buf[$64])^ := T.ReleaseCount;
  WriteInfo(P, Buf, StructSize);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadRunStatus;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  var P := FHLE.Arg(1);
  if P = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var Buf: array[0..$2B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[4])^ := ThreadInfoStatus(Self, T);
  PCardinal(@Buf[8])^ := Cardinal(T.Priority);
  if T.IsWaiting then
  begin
    PCardinal(@Buf[12])^ := Cardinal(T.Wait.Kind);
    PCardinal(@Buf[16])^ := T.Wait.Id;
  end;
  PCardinal(@Buf[20])^ := Cardinal(T.WakeupCount);
  PUInt64(@Buf[24])^ := UInt64(T.RunClocks);
  PCardinal(@Buf[32])^ := T.IntrPreemptCount;
  PCardinal(@Buf[36])^ := T.PreemptCount;
  PCardinal(@Buf[40])^ := T.ReleaseCount;
  WriteInfo(P, Buf, $2C);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadExitStatus;
begin
  var T := TPSPThread(GetObject(FHLE.Arg(0), TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if not T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_DORMANT);
    Exit;
  end;
  FHLE.Result(T.ExitStatus);
end;

function TPSPKernel.SleepRetry(T: TPSPThread): Boolean;
begin
  Result := T.WakeupCount > 0;
  if Result then
  begin
    Dec(T.WakeupCount);
    T.SetResult(0);
  end;
end;

procedure TPSPKernel.hSleepThread;
begin
  if RefuseWait then
    Exit;
  FHLE.Result(0);
  if FCurrent.WakeupCount > 0 then
  begin
    Dec(FCurrent.WakeupCount);
    Exit;
  end;
  BeginWait(PSPWaitSleep, nil, 0, 0, False, SleepRetry);
end;

procedure TPSPKernel.hSleepThreadCB;
begin
  if RefuseWait then
    Exit;
  FHLE.Result(0);
  if FCurrent.WakeupCount > 0 then
  begin
    Dec(FCurrent.WakeupCount);
    CheckCallbacksNow;
    Exit;
  end;
  BeginWait(PSPWaitSleep, nil, 0, 0, True, SleepRetry);
end;

procedure TPSPKernel.hWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_DORMANT);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then
    EndWait(T, 0)
  else
    Inc(T.WakeupCount);
end;

procedure TPSPKernel.hCancelWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  FHLE.Result(Cardinal(T.WakeupCount));
  T.WakeupCount := 0;
end;

procedure TPSPKernel.hDonateWakeupThread;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_DORMANT);
    Exit;
  end;
  FHLE.Result(0);
  if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then
    EndWait(T, 0)
  else
    Inc(T.WakeupCount);
end;

procedure TPSPKernel.hSuspendThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if T.IsDormant then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_DORMANT);
    Exit;
  end;
  if (T.Status and PSPThreadSuspended) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_SUSPEND);
    Exit;
  end;
  if (T.Status and PSPThreadReady) <> 0 then
  begin
    RemoveReady(T);
    T.Status := T.Status and not PSPThreadReady;
  end;
  T.Status := T.Status or PSPThreadSuspended;
  FHLE.Result(0);
end;

procedure TPSPKernel.hResumeThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if (T.Status and PSPThreadSuspended) = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_SUSPEND);
    Exit;
  end;
  T.Status := T.Status and not PSPThreadSuspended;
  if (T.Status and (PSPThreadWaiting or PSPThreadDormant)) = 0 then
  begin
    T.Status := T.Status or PSPThreadReady;
    PushReady(T, False);
    RequestReschedule;
  end;
  FHLE.Result(0);
end;

function TPSPKernel.ThreadEndRetry(T: TPSPThread): Boolean;
begin
  var Target := TPSPThread(T.Wait.Obj);
  Result := (Target = nil) or not FObjects.ContainsKey(T.Wait.Id) or Target.IsDormant;
  if Result then
  begin
    if (Target <> nil) and FObjects.ContainsKey(T.Wait.Id) then
      T.SetResult(Target.ExitStatus)
    else
      T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
  end;
end;

procedure WaitThreadEndCommon(K: TPSPKernel; AllowCB: Boolean);
begin
  var H := K.FHLE;
  var Id := H.Arg(0);
  if (Id = 0) or ((K.FCurrent <> nil) and (Id = K.FCurrent.UID)) then
  begin
    H.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(K.GetObject(Id, TPSPThread));
  if T = nil then
  begin
    H.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  if K.RefuseWait then
    Exit;
  if T.IsDormant then
  begin
    H.Result(T.ExitStatus);
    if AllowCB then
      K.CheckCallbacksNow;
    Exit;
  end;
  T.EndWaiters.Add(K.FCurrent);
  K.FWaitCheckNs := PSPThreadEndCheckNs;
  K.BeginWait(PSPWaitThreadEnd, T, Id, H.Arg(1), AllowCB, K.ThreadEndRetry);
end;

procedure TPSPKernel.hWaitThreadEnd;
begin
  WaitThreadEndCommon(Self, False);
end;

procedure TPSPKernel.hWaitThreadEndCB;
begin
  WaitThreadEndCommon(Self, True);
end;

function TPSPKernel.DelayRetry(T: TPSPThread): Boolean;
begin
  Result := T.Wait.Deadline <= FScheduler.Now;
  if Result then
    T.SetResult(0);
end;

procedure TPSPKernel.DelayCurrent(Microseconds: Int64; AllowCB: Boolean);
begin
  FHLE.Result(0);
  if RefuseWait then
    Exit;
  if Assigned(FOnSyncTime) then
    FOnSyncTime();
  if Microseconds < 0 then
    Microseconds := 0;
  var T := FCurrent;
  var Check: Int64 := PSPDelayCheckNs;
  var WasFresh := T.Fresh;
  if WasFresh then
    Check := PSPFreshCheckNs;
  T.Fresh := False;
  // A delay that is over by the time the kernel looks returns at once.
  if (FScheduler.Now + Check) div 1000 > FScheduler.Now div 1000 + Microseconds then
  begin
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  var Us := Microseconds;
  if Us < PSPMinTimeoutUs then
    Us := PSPMinTimeoutUs;
  var Deadline := FScheduler.Now + Us * 1000;
  BeginWait(PSPWaitDelay, nil, 0, 0, AllowCB, DelayRetry);
  if T.Wait.Kind = PSPWaitDelay then
  begin
    SetWaitDeadline(T, Deadline);
    if WasFresh then
      Spend(PSPFreshBlockNs);
  end
  else if T.Frames.Count > 0 then
  begin
    // Callbacks started first; the saved wait carries the deadline.
    var F := T.Frames.Last;
    F.SavedWait.Deadline := Deadline;
    T.Frames[T.Frames.Count - 1] := F;
  end;
end;

procedure TPSPKernel.hDelayThread;
begin
  DelayCurrent(FHLE.Arg(0), False);
end;

procedure TPSPKernel.hDelayThreadCB;
begin
  DelayCurrent(FHLE.Arg(0), True);
end;

procedure TPSPKernel.hDelaySysClockThread;
begin
  var P := FHLE.Arg(0);
  var Us := Int64(UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32));
  DelayCurrent(Us, False);
end;

procedure TPSPKernel.hDelaySysClockThreadCB;
begin
  var P := FHLE.Arg(0);
  var Us := Int64(UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32));
  DelayCurrent(Us, True);
end;

// The time a call spends in a codec, a driver or the module manager, modelled
// as a wait.
function TPSPKernel.InternalWait(T: TPSPThread): Boolean;
begin
  var Tag := T.Wait.HLETag;
  Result := (Tag <> '') and ((T.Wait.Kind = PSPWaitDelay) or (Tag = 'iodev') or (Tag = 'loadmodule') or
    (Tag = 'unloadmodule') or (Tag = 'module') or (Tag = 'font'));
end;

procedure TPSPKernel.hReleaseWaitThread;
begin
  var Id := FHLE.Arg(0);
  if (Id = 0) or ((FCurrent <> nil) and (Id = FCurrent.UID)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_THID);
    Exit;
  end;
  var T := TPSPThread(GetObject(Id, TPSPThread));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  // A thread inside a driver or a module load waits on the kernel's own
  // terms; user code cannot cut that short.
  if not T.IsWaiting or InternalWait(T) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_WAIT);
    Exit;
  end;
  Inc(T.ReleaseCount);
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  var Obj := T.Wait.Obj;
  EndWait(T, SCE_KERNEL_ERROR_RELEASE_WAIT);
  if Obj <> nil then
    Obj.WaiterGone;
end;

procedure TPSPKernel.hGetThreadStackFreeSize;
begin
  var T := ThreadById(FHLE.Arg(0));
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  // Counted from above the id word block at the bottom of the stack.
  var N: Cardinal := 0;
  while (N + $10 < T.StackSize) and (FMemory.Read8(T.StackBlock + $10 + N) = $FF) do
    Inc(N);
  FHLE.Result(N);
end;

procedure TPSPKernel.hCheckThreadStack;
begin
  if FCurrent = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var SP := FCPU.Ctx.GPR[29];
  if (SP >= FCurrent.StackBlock) and (SP <= FCurrent.StackBlock + FCurrent.StackSize) then
    FHLE.Result(SP - FCurrent.StackBlock)
  else
    FHLE.Result(0);
end;

procedure TPSPKernel.hExtendThreadStack;
begin
  var T := FCurrent;
  var Size := FHLE.Arg(0);
  var Func := FHLE.Arg(1);
  var Arg := FHLE.Arg(2);
  if (T = nil) or InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if Size < $200 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE);
    Exit;
  end;
  if Size > $1E00000 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  Size := AlignUp(Size, 256);
  var Block := T.StackPartition.Alloc(Size, akHigh, 0, 256, 'stack ext:' + T.Name);
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  FMemory.Fill(Block, $FF, Size);
  FMemory.Write32(Block, T.UID);
  var OldBlock := T.StackBlock;
  var OldSize := T.StackSize;
  T.ExtraStacks.Add(Block);
  T.StackBlock := Block;
  T.StackSize := Size;
  var K := Self;
  var F := Default(TPSPFrame);
  F.Kind := fkHLE;
  F.Saved := FCPU.Ctx;
  F.OnReturn :=
    procedure(Value: Cardinal)
    begin
      T.StackBlock := OldBlock;
      T.StackSize := OldSize;
      T.ExtraStacks.Remove(Block);
      T.StackPartition.FreeBlock(Block);
      K.CPU.Ctx.GPR[2] := Value;
    end;
  T.Frames.Add(F);
  EnterGuest(Func, Block + Size - 64, 0, [Arg]);
end;

procedure TPSPKernel.hChangeCurrentThreadAttr;
begin
  if (FCurrent = nil) or InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Clear := FHLE.Arg(0);
  var SetBits := FHLE.Arg(1);
  if ((Clear or SetBits) and not Cardinal($00004000)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  FCurrent.Attr := (FCurrent.Attr and not Clear) or SetBits;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetThreadmanIdType;
begin
  var O := GetObject(FHLE.Arg(0), nil);
  if (O = nil) or (O.IdType = 0) then
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT)
  else
    FHLE.Result(Cardinal(O.IdType));
end;

procedure TPSPKernel.hGetThreadmanIdList;
begin
  var Kind := FHLE.ArgInt(0);
  var Buf := FHLE.Arg(1);
  var Size := FHLE.ArgInt(2);
  var CountPtr := FHLE.Arg(3);
  if not (((Kind >= 1) and (Kind <= 14)) or ((Kind >= $40) and (Kind <= $43))) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_TYPE);
    Exit;
  end;
  if Size < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var Ids := TList<Cardinal>.Create;
  try
    if Kind >= $40 then
    begin
      for var T in FThreads do
        case Kind of
          $40:
            if T.IsWaiting and (T.Wait.Kind = PSPWaitSleep) then
              Ids.Add(T.UID);
          $41:
            if T.IsWaiting and (T.Wait.Kind = PSPWaitDelay) then
              Ids.Add(T.UID);
          $42:
            if (T.Status and PSPThreadSuspended) <> 0 then
              Ids.Add(T.UID);
          $43:
            if T.IsDormant then
              Ids.Add(T.UID);
        end;
    end
    else
    begin
      var Keys := FObjects.Keys.ToArray;
      TArray.Sort<Cardinal>(Keys);
      for var K in Keys do
        if FObjects[K].IdType = Kind then
          Ids.Add(K);
    end;
    var N := 0;
    for var I := 0 to Ids.Count - 1 do
      if (I < Size) and (Buf <> 0) then
      begin
        FMemory.Write32(Buf + Cardinal(I) * 4, Ids[I]);
        Inc(N);
      end;
    if CountPtr <> 0 then
      FMemory.Write32(CountPtr, Cardinal(Ids.Count));
    FHLE.Result(Cardinal(N));
  finally
    Ids.Free;
  end;
end;

procedure TPSPKernel.hSuspendDispatchThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FCPU.InterruptsEnabled then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CPUDI);
    Exit;
  end;
  FHLE.Result(Ord(not FDispatchSuspended));
  FDispatchSuspended := True;
end;

procedure TPSPKernel.hResumeDispatchThread;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  if not FCPU.InterruptsEnabled then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CPUDI);
    Exit;
  end;
  FDispatchSuspended := FHLE.Arg(0) = 0;
  FHLE.Result(0);
  if not FDispatchSuspended then
    RequestReschedule;
end;

procedure TPSPKernel.hReferSystemStatus;
begin
  var P := FHLE.Arg(0);
  var Buf: array[0..$1B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  WriteInfo(P, Buf, $1C);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadProfiler;
begin
  FHLE.Result(0);
end;

{ HLE: callbacks }

procedure TPSPKernel.hCreateCallback;
begin
  if (FCurrent = nil) or InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Func := FHLE.Arg(1);
  // Only a kernel address is refused.
  if ((Func and $80000000) <> 0) and not FCurrent.IsKernel then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var CB := TPSPCallback.Create;
  CB.Name := Name;
  CB.Func := Func;
  CB.Common := FHLE.Arg(2);
  CB.GP := FCPU.Ctx.GPR[28];
  CB.Thread := FCurrent;
  AddObject(CB);
  FCurrent.Callbacks.Add(CB);
  FHLE.Result(CB.UID);
end;

procedure TPSPKernel.hDeleteCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  if CB.Thread <> nil then
    CB.Thread.Callbacks.Remove(CB);
  DeleteObject(CB);
  FHLE.Result(0);
end;

procedure TPSPKernel.hNotifyCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  FHLE.Result(0);
  // Getting a waiting thread to its callbacks takes the kernel a while.
  var T := CB.Thread;
  if (T <> nil) and (T <> FCurrent) and T.IsWaiting and T.Wait.AllowCB and not T.CallbacksPending then
    Spend(PSPNotifyWakeNs);
  NotifyCallback(CB, FHLE.Arg(1));
end;

procedure TPSPKernel.hCancelCallback;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  CB.NotifyCount := 0;
  CB.NotifyArg := 0;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetCallbackCount;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  FHLE.Result(CB.NotifyCount);
end;

procedure TPSPKernel.hCheckCallback;
begin
  FHLE.Result(0);
  if InInterrupt or (FCurrent = nil) then
    Exit;
  if FCurrent.InCallback then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  CheckCallbacksNow(False);
end;

procedure TPSPKernel.hReferCallbackStatus;
begin
  var CB := TPSPCallback(GetObject(FHLE.Arg(0), TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(CB.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  if CB.Thread <> nil then
    PCardinal(@Buf[$24])^ := CB.Thread.UID;
  PCardinal(@Buf[$28])^ := CB.Func;
  PCardinal(@Buf[$2C])^ := CB.Common;
  PCardinal(@Buf[$30])^ := CB.NotifyCount;
  PCardinal(@Buf[$34])^ := CB.NotifyArg;
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ PSP.Kernel: semaphores and event flags. }

{ TPSPSema }

class function TPSPSema.IdType: Integer;
begin
  Result := 2;
end;

function TPSPSema.TryTake(T: TPSPThread): Boolean;
begin
  var Need := Integer(T.Wait.Data[0]);
  Result := (Count >= Need) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    Dec(Count, Need);
    T.SetResult(0);
  end;
end;

procedure TPSPSema.WaiterGone;
begin
  WakeWaiters;
end;

procedure TPSPSema.WakeWaiters;
begin
  while Waiters.Count > 0 do
  begin
    var T := Waiters.First;
    var Need := Integer(T.Wait.Data[0]);
    if Count < Need then
      Break;
    Dec(Count, Need);
    Kernel.EndWait(T, 0);
  end;
end;

{ TPSPEventFlag }

class function TPSPEventFlag.IdType: Integer;
begin
  Result := 3;
end;

function TPSPEventFlag.Matches(Bits, Mode: Cardinal): Boolean;
begin
  if (Mode and 1) <> 0 then
    Result := (Pattern and Bits) <> 0
  else
    Result := (Pattern and Bits) = Bits;
end;

function TPSPEventFlag.TryTake(T: TPSPThread): Boolean;
begin
  var Bits := T.Wait.Data[0];
  var Mode := T.Wait.Data[1];
  Result := Matches(Bits, Mode);
  if Result then
  begin
    if T.Wait.Data[2] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[2], Pattern);
    if (Mode and $10) <> 0 then
      Pattern := 0
    else if (Mode and $20) <> 0 then
      Pattern := Pattern and not Bits;
    T.SetResult(0);
  end;
end;

procedure TPSPEventFlag.WakeWaiters;
begin
  var I := 0;
  while I < Waiters.Count do
  begin
    var T := Waiters.Item(I);
    var Bits := T.Wait.Data[0];
    var Mode := T.Wait.Data[1];
    if Matches(Bits, Mode) then
    begin
      if T.Wait.Data[2] <> 0 then
        Kernel.Memory.Write32(T.Wait.Data[2], Pattern);
      if (Mode and $10) <> 0 then
        Pattern := 0
      else if (Mode and $20) <> 0 then
        Pattern := Pattern and not Bits;
      Kernel.EndWait(T, 0);
    end
    else
      Inc(I);
  end;
end;

{ HLE: semaphores }

function TPSPKernel.SemaRetry(T: TPSPThread): Boolean;
begin
  var S := TPSPSema(T.Wait.Obj);
  if (S = nil) or not FObjects.ContainsKey(T.Wait.Id) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := S.TryTake(T);
end;

procedure TPSPKernel.hCreateSema;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Attr := FHLE.Arg(1);
  if Attr >= $200 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var S := TPSPSema.Create;
  S.Name := Name;
  S.Attr := Attr;
  S.Count := FHLE.ArgInt(2);
  S.InitCount := S.Count;
  S.MaxCount := FHLE.ArgInt(3);
  S.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(S));
end;

procedure TPSPKernel.hDeleteSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  FHLE.Result(0);
  while S.Waiters.Count > 0 do
    EndWait(S.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(S);
end;

procedure TPSPKernel.hSignalSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  var N := FHLE.ArgInt(1);
  // What the waiters at the head take does not count against the maximum.
  var Left := Int64(S.Count) + N;
  for var I := 0 to S.Waiters.Count - 1 do
  begin
    var Need := Integer(S.Waiters.Item(I).Wait.Data[0]);
    if Left < Need then
      Break;
    Dec(Left, Need);
  end;
  if Left > S.MaxCount then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_SEMA_OVF);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  Inc(S.Count, N);
  FHLE.Result(0);
  S.WakeWaiters;
end;

procedure TPSPKernel.WaitSemaCommon(AllowCB: Boolean);
begin
  if RefuseWait then
    Exit;
  var Need := FHLE.ArgInt(1);
  if Need <= 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  if Need > S.MaxCount then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if (S.Count >= Need) and (S.Waiters.Count = 0) then
  begin
    Dec(S.Count, Need);
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  S.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitSema, S, S.UID, FHLE.Arg(2), AllowCB, SemaRetry, [Cardinal(Need)]);
end;

procedure TPSPKernel.hWaitSema;
begin
  WaitSemaCommon(False);
end;

procedure TPSPKernel.hWaitSemaCB;
begin
  WaitSemaCommon(True);
end;

procedure TPSPKernel.hPollSema;
begin
  var Need := FHLE.ArgInt(1);
  if Need <= 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  if (S.Count >= Need) and (S.Waiters.Count = 0) then
  begin
    Dec(S.Count, Need);
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_KERNEL_ERROR_SEMA_ZERO);
end;

procedure TPSPKernel.hCancelSema;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  var NewCount := FHLE.ArgInt(1);
  if NewCount > S.MaxCount then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(S.Waiters.Count));
  FHLE.Result(0);
  while S.Waiters.Count > 0 do
    EndWait(S.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  if NewCount < 0 then
    S.Count := S.InitCount
  else
    S.Count := NewCount;
end;

procedure TPSPKernel.hReferSemaStatus;
begin
  var S := TPSPSema(GetObject(FHLE.Arg(0), TPSPSema));
  if S = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_SEMID);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(S.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := S.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(S.InitCount);
  PCardinal(@Buf[$2C])^ := Cardinal(S.Count);
  PCardinal(@Buf[$30])^ := Cardinal(S.MaxCount);
  PCardinal(@Buf[$34])^ := Cardinal(S.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: event flags }

function TPSPKernel.EventFlagRetry(T: TPSPThread): Boolean;
begin
  var E := TPSPEventFlag(T.Wait.Obj);
  if (E = nil) or not FObjects.ContainsKey(T.Wait.Id) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    if T.Wait.Data[2] <> 0 then
      FMemory.Write32(T.Wait.Data[2], 0);
    Exit(True);
  end;
  Result := E.TryTake(T);
end;

procedure TPSPKernel.EventFlagAbort(T: TPSPThread);
begin
  // A wait that ends without the bits still reports the pattern, unless it
  // timed out before it began.
  var E := TPSPEventFlag(T.Wait.Obj);
  if T.Wait.Deadline = 0 then
    Exit;
  if (T.Wait.Data[2] <> 0) and (E <> nil) and FObjects.ContainsKey(T.Wait.Id) then
    FMemory.Write32(T.Wait.Data[2], E.Pattern);
end;

procedure TPSPKernel.hCreateEventFlag;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Attr := FHLE.Arg(1);
  if (Attr and $100) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  if Attr >= $300 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var E := TPSPEventFlag.Create;
  E.Name := Name;
  E.Attr := Attr;
  E.Pattern := FHLE.Arg(2);
  E.InitPattern := E.Pattern;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(E));
end;

procedure TPSPKernel.hDeleteEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  FHLE.Result(0);
  E.Pattern := 0;
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(E);
end;

procedure TPSPKernel.hSetEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  E.Pattern := E.Pattern or FHLE.Arg(1);
  E.WakeWaiters;
end;

procedure TPSPKernel.hClearEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  E.Pattern := E.Pattern and FHLE.Arg(1);
  FHLE.Result(0);
end;

function EventFlagModeError(Mode, Bits: Cardinal): Cardinal;
begin
  if ((Mode and not Cardinal($31)) <> 0) or ((Mode and $30) = $30) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_MODE
  else if Bits = 0 then
    Result := SCE_KERNEL_ERROR_EVF_ILPAT
  else
    Result := 0;
end;

procedure TPSPKernel.WaitEventFlagCommon(AllowCB: Boolean);
begin
  var Bits := FHLE.Arg(1);
  var Mode := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Err := EventFlagModeError(Mode, Bits);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if RefuseWait then
    Exit;
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if ((E.Attr and $200) = 0) and (E.Waiters.Count > 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_EVF_MULTI);
    Exit;
  end;
  if E.Matches(Bits, Mode) then
  begin
    if OutPtr <> 0 then
      FMemory.Write32(OutPtr, E.Pattern);
    if (Mode and $10) <> 0 then
      E.Pattern := 0
    else if (Mode and $20) <> 0 then
      E.Pattern := E.Pattern and not Bits;
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  E.Waiters.Add(FCurrent);
  if not BeginWaitData(PSPWaitEventFlag, E, E.UID, FHLE.Arg(4), AllowCB, EventFlagRetry,
    [Bits, Mode, OutPtr], EventFlagAbort) then
    Exit;
end;

procedure TPSPKernel.hWaitEventFlag;
begin
  WaitEventFlagCommon(False);
end;

procedure TPSPKernel.hWaitEventFlagCB;
begin
  WaitEventFlagCommon(True);
end;

procedure TPSPKernel.hPollEventFlag;
begin
  var Bits := FHLE.Arg(1);
  var Mode := FHLE.Arg(2);
  var OutPtr := FHLE.Arg(3);
  var Err := EventFlagModeError(Mode, Bits);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  if ((E.Attr and $200) = 0) and (E.Waiters.Count > 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_EVF_MULTI);
    Exit;
  end;
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, E.Pattern);
  if E.Matches(Bits, Mode) then
  begin
    if (Mode and $10) <> 0 then
      E.Pattern := 0
    else if (Mode and $20) <> 0 then
      E.Pattern := E.Pattern and not Bits;
    FHLE.Result(0);
  end
  else
    FHLE.Result(SCE_KERNEL_ERROR_EVF_COND);
end;

procedure TPSPKernel.hCancelEventFlag;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(E.Waiters.Count));
  FHLE.Result(0);
  E.Pattern := FHLE.Arg(1);
  while E.Waiters.Count > 0 do
    EndWait(E.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferEventFlagStatus;
begin
  var E := TPSPEventFlag(GetObject(FHLE.Arg(0), TPSPEventFlag));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_EVFID);
    Exit;
  end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(E.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := E.Attr;
  PCardinal(@Buf[$28])^ := E.InitPattern;
  PCardinal(@Buf[$2C])^ := E.Pattern;
  PCardinal(@Buf[$30])^ := Cardinal(E.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ PSP.Kernel: mutexes and lightweight mutexes. }

type
  TPSPMutex = class(TPSPWaitObject)
  public
    InitCount, LockCount: Integer;
    Owner: TPSPThread;
    class function IdType: Integer; override;
    function Recursive: Boolean; inline;
    function Retry(T: TPSPThread): Boolean;
    // Hands the mutex to the first waiter that can take it.
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  // The lock state lives in the guest's workarea:
  // +0 lock count, +4 owner, +8 attr, +12 waiting threads, +16 uid, +20..31 0.
  TPSPLwMutex = class(TPSPWaitObject)
  public
    Workarea: Cardinal;
    InitCount: Integer;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    procedure SyncWaiting;
    function Retry(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

const
  PSPMutexRecursive = $200;

{ TPSPMutex }

class function TPSPMutex.IdType: Integer;
begin
  Result := 12;
end;

function TPSPMutex.Recursive: Boolean;
begin
  Result := (Attr and PSPMutexRecursive) <> 0;
end;

function TPSPMutex.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := (Owner = nil) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    Owner := T;
    LockCount := Integer(T.Wait.Data[0]);
    T.SetResult(0);
  end;
end;

procedure TPSPMutex.WakeWaiters;
begin
  if (Owner <> nil) or (Waiters.Count = 0) then
    Exit;
  var T := Waiters.First;
  Owner := T;
  LockCount := Integer(T.Wait.Data[0]);
  Kernel.EndWait(T, 0);
end;

procedure TPSPMutex.WaiterGone;
begin
  WakeWaiters;
end;

{ TPSPLwMutex }

class function TPSPLwMutex.IdType: Integer;
begin
  Result := 13;
end;

procedure TPSPLwMutex.SyncWaiting;
begin
  // The workarea counts the threads waiting in the kernel.
  Kernel.Memory.Write32(Workarea + 12, Cardinal(Waiters.Count));
end;

procedure TPSPLwMutex.RemoveWaiter(T: TPSPThread);
begin
  inherited;
  SyncWaiting;
end;

procedure TPSPLwMutex.AddWaiter(T: TPSPThread);
begin
  inherited;
  SyncWaiting;
end;

function TPSPLwMutex.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  var M := Kernel.Memory;
  Result := (M.Read32(Workarea) = 0) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    M.Write32(Workarea, T.Wait.Data[0]);
    M.Write32(Workarea + 4, T.UID);
    T.SetResult(0);
  end;
end;

procedure TPSPLwMutex.WakeWaiters;
begin
  var M := Kernel.Memory;
  if (M.Read32(Workarea) <> 0) or (Waiters.Count = 0) then
    Exit;
  var T := Waiters.First;
  M.Write32(Workarea, T.Wait.Data[0]);
  M.Write32(Workarea + 4, T.UID);
  Kernel.EndWait(T, 0);
end;

procedure TPSPLwMutex.WaiterGone;
begin
  WakeWaiters;
end;

{ Mutex owners }

procedure TPSPKernel.ReleaseMutexesOf(T: TPSPThread);
begin
  // A thread that ends hands its kernel mutexes on.
  for var O in FObjects.Values.ToArray do
    if (O is TPSPMutex) and (TPSPMutex(O).Owner = T) then
    begin
      TPSPMutex(O).Owner := nil;
      TPSPMutex(O).LockCount := 0;
      TPSPMutex(O).WakeWaiters;
    end;
end;

{ HLE: mutexes }

procedure TPSPKernel.hCreateMutex;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Attr := FHLE.Arg(1);
  var Count := FHLE.ArgInt(2);
  if (Attr and not Cardinal($BFF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  if (Count < 0) or ((Count > 1) and ((Attr and PSPMutexRecursive) = 0)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  var M := TPSPMutex.Create;
  M.Name := Name;
  M.Attr := Attr;
  M.InitCount := Count;
  M.LockCount := Count;
  if Count > 0 then
    M.Owner := FCurrent;
  M.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(M));
end;

procedure TPSPKernel.hDeleteMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  FHLE.Result(0);
  while M.Waiters.Count > 0 do
    EndWait(M.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(M);
end;

function MutexCountError(M: TPSPMutex; Count: Integer): Cardinal;
begin
  if (Count <= 0) or ((Count > 1) and not M.Recursive) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_COUNT
  else
    Result := 0;
end;

procedure TPSPKernel.LockMutexCommon(AllowCB: Boolean);
begin
  if RefuseWait then
    Exit;
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  if M.Owner = FCurrent then
  begin
    if not M.Recursive then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_MUTEX_RECURSIVE_NOT_ALLOWED);
      Exit;
    end;
    if Int64(M.LockCount) + Count > High(Integer) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCK_OVERFLOW);
      Exit;
    end;
    Inc(M.LockCount, Count);
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if (M.Owner = nil) and (M.Waiters.Count = 0) then
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
    if AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  M.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitMutex, M, M.UID, FHLE.Arg(2), AllowCB, M.Retry, [Cardinal(Count)]);
end;

procedure TPSPKernel.hLockMutex;
begin
  LockMutexCommon(False);
end;

procedure TPSPKernel.hLockMutexCB;
begin
  LockMutexCommon(True);
end;

procedure TPSPKernel.hTryLockMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FHLE.Result(0);
  if M.Owner = FCurrent then
  begin
    if not M.Recursive then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_MUTEX_RECURSIVE_NOT_ALLOWED);
      Exit;
    end;
    if Int64(M.LockCount) + Count > High(Integer) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCK_OVERFLOW);
      Exit;
    end;
    Inc(M.LockCount, Count);
    Exit;
  end;
  if (M.Owner = nil) and (M.Waiters.Count = 0) then
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
    Exit;
  end;
  FHLE.Result(SCE_KERNEL_ERROR_MUTEX_LOCKED);
end;

procedure TPSPKernel.hUnlockMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  var Count := FHLE.ArgInt(1);
  var Err := MutexCountError(M, Count);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if (M.Owner = nil) or (M.Owner <> FCurrent) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_UNLOCKED);
    Exit;
  end;
  if Count > M.LockCount then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_UNLOCK_UNDERFLOW);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  Dec(M.LockCount, Count);
  if M.LockCount = 0 then
  begin
    M.Owner := nil;
    M.WakeWaiters;
  end;
end;

procedure TPSPKernel.hCancelMutex;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  var Count := FHLE.ArgInt(1);
  if (Count > 1) and not M.Recursive then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(M.Waiters.Count));
  FHLE.Result(0);
  while M.Waiters.Count > 0 do
    EndWait(M.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  if Count <= 0 then
  begin
    M.Owner := nil;
    M.LockCount := 0;
  end
  else
  begin
    M.Owner := FCurrent;
    M.LockCount := Count;
  end;
end;

procedure TPSPKernel.hReferMutexStatus;
begin
  var M := TPSPMutex(GetObject(FHLE.Arg(0), TPSPMutex));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MUTEX_NOT_FOUND);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(M.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := M.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(M.InitCount);
  PCardinal(@Buf[$2C])^ := Cardinal(M.LockCount);
  if M.Owner <> nil then
    PCardinal(@Buf[$30])^ := M.Owner.UID
  else
    PCardinal(@Buf[$30])^ := $FFFFFFFF;
  PCardinal(@Buf[$34])^ := Cardinal(M.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: lightweight mutexes }

procedure TPSPKernel.hCreateLwMutex;
begin
  var W := FHLE.Arg(0);
  var Name: string;
  if not ReadName(FHLE.Arg(1), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Attr := FHLE.Arg(2);
  var Count := FHLE.ArgInt(3);
  if (Attr and not Cardinal($3FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  if (Count < 0) or ((Count > 1) and ((Attr and PSPMutexRecursive) = 0)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  var L := TPSPLwMutex.Create;
  L.Name := Name;
  L.Attr := Attr;
  L.Workarea := W;
  L.InitCount := Count;
  L.Waiters.ByPriority := (Attr and $100) <> 0;
  AddObject(L);
  FMemory.Write32(W, Cardinal(Count));
  if (Count > 0) and (FCurrent <> nil) then
    FMemory.Write32(W + 4, FCurrent.UID)
  else
    FMemory.Write32(W + 4, 0);
  FMemory.Write32(W + 8, Attr);
  FMemory.Write32(W + 12, 0);
  FMemory.Write32(W + 16, L.UID);
  FMemory.Write32(W + 20, 0);
  FMemory.Write32(W + 24, 0);
  FMemory.Write32(W + 28, 0);
  FHLE.Result(0);
end;

procedure TPSPKernel.hDeleteLwMutex;
begin
  var W := FHLE.Arg(0);
  if (W = 0) or not ValidUserAddress(W) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if (L = nil) or (L.Workarea <> W) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  FHLE.Result(0);
  while L.Waiters.Count > 0 do
    EndWait(L.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  FMemory.Write32(W + 12, 0);
  FMemory.Write32(W + 16, $FFFFFFFF);
  DeleteObject(L);
end;

// Errors from the lock paths: TryLock before 6.00 reports every failure as
// MUTEX_LOCKED.
procedure TPSPKernel.LockLwMutexCommon(AllowCB, IsTry: Boolean; TryError: Cardinal);

  procedure Fail(Code: Cardinal);
  begin
    if IsTry and (TryError <> 0) then
      FHLE.Result(TryError)
    else
      FHLE.Result(Code);
  end;

begin
  if not IsTry and RefuseWait then
    Exit;
  var W := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var TimeoutPtr: Cardinal := 0;
  if not IsTry then
    TimeoutPtr := FHLE.Arg(2);
  var Attr := FMemory.Read32(W + 8);
  var Recursive := (Attr and PSPMutexRecursive) <> 0;
  if (Count <= 0) or ((Count > 1) and not Recursive) then
  begin
    Fail(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  if FMemory.Read32(W + 16) = $FFFFFFFF then
  begin
    Fail(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  var Level := Integer(FMemory.Read32(W));
  var Me: Cardinal := 0;
  if FCurrent <> nil then
    Me := FCurrent.UID;
  FHLE.Result(0);
  if Level = 0 then
  begin
    FMemory.Write32(W, Cardinal(Count));
    FMemory.Write32(W + 4, Me);
    Exit;
  end;
  if FMemory.Read32(W + 4) = Me then
  begin
    if not Recursive then
    begin
      Fail(SCE_KERNEL_ERROR_LWMUTEX_RECURSIVE_NOT_ALLOWED);
      Exit;
    end;
    if Int64(Level) + Count > High(Integer) then
    begin
      Fail(SCE_KERNEL_ERROR_LWMUTEX_LOCK_OVERFLOW);
      Exit;
    end;
    FMemory.Write32(W, Cardinal(Level + Count));
    Exit;
  end;
  if IsTry then
  begin
    Fail(SCE_KERNEL_ERROR_LWMUTEX_LOCKED);
    Exit;
  end;
  // Held by another thread: the kernel side waits on the object.
  Spend(PSPSyncCallNs);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  L.AddWaiter(FCurrent);
  BeginWaitData(PSPWaitLwMutex, L, L.UID, TimeoutPtr, AllowCB, L.Retry, [Cardinal(Count)]);
end;

procedure TPSPKernel.hLockLwMutex;
begin
  LockLwMutexCommon(False, False, 0);
end;

procedure TPSPKernel.hLockLwMutexCB;
begin
  LockLwMutexCommon(True, False, 0);
end;

procedure TPSPKernel.hTryLockLwMutex;
begin
  LockLwMutexCommon(False, True, SCE_KERNEL_ERROR_MUTEX_LOCKED);
end;

procedure TPSPKernel.hTryLockLwMutex600;
begin
  LockLwMutexCommon(False, True, 0);
end;

procedure TPSPKernel.hUnlockLwMutex;
begin
  var W := FHLE.Arg(0);
  var Count := FHLE.ArgInt(1);
  var Attr := FMemory.Read32(W + 8);
  var Recursive := (Attr and PSPMutexRecursive) <> 0;
  if (Count <= 0) or ((Count > 1) and not Recursive) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_COUNT);
    Exit;
  end;
  if FMemory.Read32(W + 16) = $FFFFFFFF then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  var Level := Integer(FMemory.Read32(W));
  var Me: Cardinal := 0;
  if FCurrent <> nil then
    Me := FCurrent.UID;
  if (Level = 0) or (FMemory.Read32(W + 4) <> Me) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_UNLOCKED);
    Exit;
  end;
  if Count > Level then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_UNLOCK_UNDERFLOW);
    Exit;
  end;
  FHLE.Result(0);
  Dec(Level, Count);
  FMemory.Write32(W, Cardinal(Level));
  if Level > 0 then
    Exit;
  FMemory.Write32(W + 4, 0);
  if FMemory.Read32(W + 12) = 0 then
    Exit;
  // Somebody waits: the kernel hands the lock on.
  Spend(PSPSyncCallNs);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L <> nil then
    L.WakeWaiters;
end;

procedure TPSPKernel.ReferLwMutex(Obj: TPSPKernelObject; InfoPtr: Cardinal);
begin
  var L := TPSPLwMutex(Obj);
  var Buf: array[0..$3F] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(L.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  var W := L.Workarea;
  var Level := FMemory.Read32(W);
  PCardinal(@Buf[$24])^ := L.Attr;
  PCardinal(@Buf[$28])^ := L.UID;
  PCardinal(@Buf[$2C])^ := W;
  PCardinal(@Buf[$30])^ := Cardinal(L.InitCount);
  PCardinal(@Buf[$34])^ := Level;
  if Level <> 0 then
    PCardinal(@Buf[$38])^ := FMemory.Read32(W + 4)
  else
    PCardinal(@Buf[$38])^ := $FFFFFFFF;
  PCardinal(@Buf[$3C])^ := FMemory.Read32(W + 12);
  WriteInfo(InfoPtr, Buf, $40);
end;

procedure TPSPKernel.hReferLwMutexStatus;
begin
  var W := FHLE.Arg(0);
  var L := TPSPLwMutex(GetObject(FMemory.Read32(W + 16), TPSPLwMutex));
  if L = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  ReferLwMutex(L, FHLE.Arg(1));
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferLwMutexStatusByID;
begin
  var L := TPSPLwMutex(GetObject(FHLE.Arg(0), TPSPLwMutex));
  if L = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_LWMUTEX_NOT_FOUND);
    Exit;
  end;
  ReferLwMutex(L, FHLE.Arg(1));
  FHLE.Result(0);
end;

{ PSP.Kernel: message boxes and message pipes. }

type
  // Messages stay in the guest: a ring linked through each packet's first word,
  // the box keeping the last one (whose next is the first).
  TPSPMbx = class(TPSPWaitObject)
  public
    Tail: Cardinal;
    Count: Integer;
    class function IdType: Integer; override;
    function First: Cardinal;
    function Retry(T: TPSPThread): Boolean;
    // Takes the first message: 0 when it worked, else the error.
    function Take(out Msg: Cardinal): Cardinal;
    // 0 if Msg is not linked in yet; the error when it is or the ring is broken.
    function CheckNew(Msg: Cardinal): Cardinal;
    procedure Put(Msg: Cardinal);
  end;

  TPSPMsgPipe = class(TPSPKernelObject)
  public
    Attr: Cardinal;
    PartitionId: Integer;
    Block: Cardinal;
    BufSize: Cardinal;
    Data: TBytes;
    Used: Cardinal;
    Senders, Receivers: TPSPWaitQueue;
    constructor Create;
    destructor Destroy; override;
    class function IdType: Integer; override;
    procedure RemoveWaiter(T: TPSPThread); override;
    procedure AddWaiter(T: TPSPThread); override;
    procedure WaiterGone; override;
    function FreeSize: Cardinal;
    procedure PushBytes(Src, N: Cardinal);
    procedure PopBytes(Dst, N: Cardinal);
    // Moves data between the buffer and the waiting threads until nothing
    // more can move; wakes those that are done.
    procedure Settle;
    function SendRetry(T: TPSPThread): Boolean;
    function ReceiveRetry(T: TPSPThread): Boolean;
    procedure WaitAbort(T: TPSPThread);
  end;

{ TPSPMbx }

class function TPSPMbx.IdType: Integer;
begin
  Result := 4;
end;

function TPSPMbx.First: Cardinal;
begin
  if Tail = 0 then
    Result := 0
  else
    Result := Kernel.Memory.Read32(Tail);
end;

function TPSPMbx.CheckNew(Msg: Cardinal): Cardinal;
begin
  if Tail = 0 then
    Exit(0);
  var P := First;
  for var I := 1 to Count do
  begin
    if P = 0 then
      Exit(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    if P = Msg then
      Exit(SCE_KERNEL_ERROR_MESSAGEBOX_DUPLICATE_MESSAGE);
    P := Kernel.Memory.Read32(P);
  end;
  Result := 0;
end;

procedure TPSPMbx.Put(Msg: Cardinal);
begin
  var M := Kernel.Memory;
  if Tail = 0 then
  begin
    M.Write32(Msg, Msg);
    Tail := Msg;
  end
  else if (Attr and $400) <> 0 then
  begin
    // By message priority, lower first; equal ones keep their order.
    var Prio := M.Read8(Msg + 4);
    var Prev := Tail;
    var P := M.Read32(Tail);
    var Placed := False;
    for var I := 1 to Count do
    begin
      if M.Read8(P + 4) > Prio then
      begin
        M.Write32(Msg, P);
        M.Write32(Prev, Msg);
        Placed := True;
        Break;
      end;
      if P = Tail then
        Break;
      Prev := P;
      P := M.Read32(P);
    end;
    if not Placed then
    begin
      M.Write32(Msg, M.Read32(Tail));
      M.Write32(Tail, Msg);
      Tail := Msg;
    end;
  end
  else
  begin
    M.Write32(Msg, M.Read32(Tail));
    M.Write32(Tail, Msg);
    Tail := Msg;
  end;
  Inc(Count);
end;

function TPSPMbx.Take(out Msg: Cardinal): Cardinal;
begin
  var M := Kernel.Memory;
  Msg := First;
  if Msg = 0 then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
  if Msg = Tail then
  begin
    if Count > 1 then
      Exit(SCE_KERNEL_ERROR_MESSAGEBOX_DUPLICATE_MESSAGE);
    Tail := 0;
  end
  else
    M.Write32(Tail, M.Read32(Msg));
  Dec(Count);
  Result := 0;
end;

function TPSPMbx.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := (Count > 0) and ((Waiters.Count = 0) or (Waiters.First = T));
  if Result then
  begin
    var Msg: Cardinal;
    var Err := Take(Msg);
    if (Err = 0) and (T.Wait.Data[0] <> 0) then
      Kernel.Memory.Write32(T.Wait.Data[0], Msg);
    T.SetResult(Err);
  end;
end;

{ TPSPMsgPipe }

constructor TPSPMsgPipe.Create;
begin
  inherited Create;
  Senders := TPSPWaitQueue.Create(False);
  Receivers := TPSPWaitQueue.Create(False);
end;

destructor TPSPMsgPipe.Destroy;
begin
  Senders.Free;
  Receivers.Free;
  inherited;
end;

class function TPSPMsgPipe.IdType: Integer;
begin
  Result := 7;
end;

procedure TPSPMsgPipe.RemoveWaiter(T: TPSPThread);
begin
  Senders.Remove(T);
  Receivers.Remove(T);
end;

procedure TPSPMsgPipe.AddWaiter(T: TPSPThread);
begin
  if T.Wait.Data[4] = 1 then
    Senders.Add(T)
  else
    Receivers.Add(T);
end;

procedure TPSPMsgPipe.WaiterGone;
begin
  Settle;
end;

function TPSPMsgPipe.FreeSize: Cardinal;
begin
  Result := BufSize - Used;
end;

procedure TPSPMsgPipe.PushBytes(Src, N: Cardinal);
begin
  if N = 0 then
    Exit;
  Kernel.Memory.ReadBytes(Src, Data[Used], N);
  Inc(Used, N);
end;

procedure TPSPMsgPipe.PopBytes(Dst, N: Cardinal);
begin
  if N = 0 then
    Exit;
  Kernel.Memory.WriteBytes(Dst, Data[0], N);
  if Used > N then
    Move(Data[N], Data[0], Used - N);
  Dec(Used, N);
end;

// Wait data: [0] buffer, [1] size, [2] mode, [3] done so far, [4] 1 = sending,
// [5] result pointer.

function PipeDone(T: TPSPThread): Boolean;
begin
  if T.Wait.Data[2] = 1 then
    Result := T.Wait.Data[3] > 0
  else
    Result := T.Wait.Data[3] >= T.Wait.Data[1];
end;

procedure PipeFinish(K: TPSPKernel; T: TPSPThread);
begin
  if T.Wait.Data[5] <> 0 then
    K.Memory.Write32(T.Wait.Data[5], T.Wait.Data[3]);
end;

procedure TPSPMsgPipe.Settle;
begin
  var M := Kernel.Memory;
  repeat
    var Moved := False;
    // Waiting receivers take from the buffer, first come first.
    while (Receivers.Count > 0) and (Used > 0) do
    begin
      var R := Receivers.First;
      var Want := R.Wait.Data[1] - R.Wait.Data[3];
      var N := Want;
      if N > Used then
        N := Used;
      PopBytes(R.Wait.Data[0] + R.Wait.Data[3], N);
      Inc(R.Wait.Data[3], N);
      Moved := Moved or (N > 0);
      if PipeDone(R) then
      begin
        PipeFinish(Kernel, R);
        Kernel.EndWait(R, 0);
      end
      else
        Break;
    end;
    // Then the waiting senders, straight to waiting receivers, then into the buffer.
    while Senders.Count > 0 do
    begin
      var S := Senders.First;
      var Left := S.Wait.Data[1] - S.Wait.Data[3];
      while (Left > 0) and (Receivers.Count > 0) and (Used = 0) do
      begin
        var R := Receivers.First;
        var N := R.Wait.Data[1] - R.Wait.Data[3];
        if N > Left then
          N := Left;
        var Tmp: TBytes;
        SetLength(Tmp, N);
        if N > 0 then
        begin
          M.ReadBytes(S.Wait.Data[0] + S.Wait.Data[3], Tmp[0], N);
          M.WriteBytes(R.Wait.Data[0] + R.Wait.Data[3], Tmp[0], N);
        end;
        Inc(S.Wait.Data[3], N);
        Inc(R.Wait.Data[3], N);
        Dec(Left, N);
        Moved := Moved or (N > 0);
        if PipeDone(R) then
        begin
          PipeFinish(Kernel, R);
          Kernel.EndWait(R, 0);
        end
        else
          Break;
      end;
      if Left > 0 then
      begin
        var N := FreeSize;
        if (S.Wait.Data[2] = 0) and (N < Left) then
          N := 0;
        if N > Left then
          N := Left;
        if N > 0 then
        begin
          PushBytes(S.Wait.Data[0] + S.Wait.Data[3], N);
          Inc(S.Wait.Data[3], N);
          Dec(Left, N);
          Moved := True;
        end;
      end;
      if (Left = 0) or ((S.Wait.Data[2] = 1) and (S.Wait.Data[3] > 0)) then
      begin
        PipeFinish(Kernel, S);
        Kernel.EndWait(S, 0);
      end
      else
        Break;
    end;
    if not Moved then
      Break;
  until False;
end;

function TPSPMsgPipe.SendRetry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if Senders.Count > 0 then
    Exit;
  var Left := T.Wait.Data[1] - T.Wait.Data[3];
  var N := FreeSize;
  if (T.Wait.Data[2] = 0) and (N < Left) then
    N := 0;
  if N > Left then
    N := Left;
  if N > 0 then
  begin
    PushBytes(T.Wait.Data[0] + T.Wait.Data[3], N);
    Inc(T.Wait.Data[3], N);
  end;
  Result := PipeDone(T);
  if Result then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(0);
    Settle;
  end;
end;

function TPSPMsgPipe.ReceiveRetry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if Receivers.Count > 0 then
    Exit;
  var N := T.Wait.Data[1] - T.Wait.Data[3];
  if N > Used then
    N := Used;
  if (T.Wait.Data[2] = 0) and (BufSize > 0) and (Used < T.Wait.Data[1] - T.Wait.Data[3]) then
    N := 0;
  if N > 0 then
  begin
    PopBytes(T.Wait.Data[0] + T.Wait.Data[3], N);
    Inc(T.Wait.Data[3], N);
  end;
  Result := PipeDone(T);
  if Result then
  begin
    PipeFinish(Kernel, T);
    T.SetResult(0);
    Settle;
  end;
end;

procedure TPSPMsgPipe.WaitAbort(T: TPSPThread);
begin
  PipeFinish(Kernel, T);
end;

{ HLE: message boxes }

procedure TPSPKernel.hCreateMbx;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Attr := FHLE.Arg(1);
  if (Attr and not Cardinal($5FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var B := TPSPMbx.Create;
  B.Name := Name;
  B.Attr := Attr;
  B.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hDeleteMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  FHLE.Result(0);
  while B.Waiters.Count > 0 do
    EndWait(B.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  DeleteObject(B);
end;

procedure TPSPKernel.hSendMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  var Msg := FHLE.Arg(1);
  Spend(PSPSyncCallNs);
  if B.Waiters.Count > 0 then
  begin
    // Straight to the first receiver; the packet is not linked.
    var T := B.Waiters.First;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], Msg);
    FHLE.Result(0);
    EndWait(T, 0);
    Exit;
  end;
  var Err := B.CheckNew(Msg);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  B.Put(Msg);
  FHLE.Result(0);
end;

procedure TPSPKernel.ReceiveMbxCommon(AllowCB: Boolean);
begin
  if RefuseWait then
    Exit;
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  var OutPtr := FHLE.Arg(1);
  Spend(PSPSyncCallNs);
  if B.Count > 0 then
  begin
    var Msg: Cardinal;
    var Err := B.Take(Msg);
    if (Err = 0) and (OutPtr <> 0) then
      FMemory.Write32(OutPtr, Msg);
    FHLE.Result(Err);
    if (Err = 0) and AllowCB then
      CheckCallbacksNow;
    Exit;
  end;
  FHLE.Result(0);
  B.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitMbx, B, B.UID, FHLE.Arg(2), AllowCB, B.Retry, [OutPtr]);
end;

procedure TPSPKernel.hReceiveMbx;
begin
  ReceiveMbxCommon(False);
end;

procedure TPSPKernel.hReceiveMbxCB;
begin
  ReceiveMbxCommon(True);
end;

procedure TPSPKernel.hPollMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  if B.Count = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_MBOX_NOMSG);
    Exit;
  end;
  var Msg: Cardinal;
  var Err := B.Take(Msg);
  if (Err = 0) and (FHLE.Arg(1) <> 0) then
    FMemory.Write32(FHLE.Arg(1), Msg);
  FHLE.Result(Err);
end;

procedure TPSPKernel.hCancelReceiveMbx;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(B.Waiters.Count));
  FHLE.Result(0);
  while B.Waiters.Count > 0 do
    EndWait(B.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferMbxStatus;
begin
  var B := TPSPMbx(GetObject(FHLE.Arg(0), TPSPMbx));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MBXID);
    Exit;
  end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(B.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := B.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(B.Waiters.Count);
  PCardinal(@Buf[$2C])^ := Cardinal(B.Count);
  PCardinal(@Buf[$30])^ := B.First;
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ HLE: message pipes }

function TPSPKernel.UserPartitionCheck(PartId: Integer): Cardinal;
begin
  // What a user module may create objects in.
  case PartId of
    2, 5, 6:
      Result := 0;
    1, 3, 4:
      if (FCurrent <> nil) and FCurrent.IsKernel then
        Result := 0
      else
        Result := SCE_KERNEL_ERROR_ILLEGAL_PERM;
  else
    Result := SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT;
  end;
end;

procedure TPSPKernel.hCreateMsgPipe;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($51FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var Size := FHLE.Arg(3);
  var P := Partition(PartId);
  if P = nil then
    P := FKernelPartition;
  var Block: Cardinal := 0;
  if Size > 0 then
  begin
    if Size > $7FFFFFFF then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
      Exit;
    end;
    if (Attr and $4000) <> 0 then
      Block := P.Alloc(Size, akHigh, 0, 256, 'msgpipe:' + Name)
    else
      Block := P.Alloc(Size, akLow, 0, 256, 'msgpipe:' + Name);
    if Block = 0 then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
      Exit;
    end;
  end;
  var MP := TPSPMsgPipe.Create;
  MP.Name := Name;
  MP.Attr := Attr;
  MP.PartitionId := PartId;
  MP.Block := Block;
  MP.BufSize := Size;
  SetLength(MP.Data, Size);
  MP.Senders.ByPriority := (Attr and $100) <> 0;
  MP.Receivers.ByPriority := (Attr and $1000) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(MP));
end;

procedure TPSPKernel.hDeleteMsgPipe;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID);
    Exit;
  end;
  FHLE.Result(0);
  while MP.Senders.Count > 0 do
    EndWait(MP.Senders.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  while MP.Receivers.Count > 0 do
    EndWait(MP.Receivers.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  if MP.Block <> 0 then
  begin
    var P := Partition(MP.PartitionId);
    if P = nil then
      P := FKernelPartition;
    P.FreeBlock(MP.Block);
  end;
  DeleteObject(MP);
end;

// Mode: 0 waits, 1 waits with callbacks, 2 does not wait.
procedure TPSPKernel.SendMsgPipeCommon(Mode: Integer);
begin
  var Buf := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  if Integer(Size) < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if (Mode <> 2) and RefuseWait then
    Exit;
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID);
    Exit;
  end;
  var WaitMode := FHLE.Arg(3);
  var ResultPtr := FHLE.Arg(4);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(5);
  if Integer(Size) < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if WaitMode > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE);
    Exit;
  end;
  if (MP.BufSize > 0) and (Size > MP.BufSize) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  var Done: Cardinal := 0;
  if MP.Senders.Count = 0 then
  begin
    // First straight to receivers already waiting, then into the buffer.
    while (Done < Size) and (MP.Receivers.Count > 0) and (MP.Used = 0) do
    begin
      var R := MP.Receivers.First;
      var N := R.Wait.Data[1] - R.Wait.Data[3];
      if N > Size - Done then
        N := Size - Done;
      if N > 0 then
        FMemory.Copy(R.Wait.Data[0] + R.Wait.Data[3], Buf + Done, N);
      Inc(R.Wait.Data[3], N);
      Inc(Done, N);
      if PipeDone(R) then
      begin
        PipeFinish(Self, R);
        EndWait(R, 0);
      end
      else
        Break;
    end;
    if Done < Size then
    begin
      var N := MP.FreeSize;
      if (WaitMode = 0) and (N < Size - Done) then
        N := 0;
      if N > Size - Done then
        N := Size - Done;
      if N > 0 then
      begin
        MP.PushBytes(Buf + Done, N);
        Inc(Done, N);
        MP.Settle;
      end;
    end;
  end;
  if (Done = Size) or ((WaitMode = 1) and (Done > 0)) then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(0);
    if Mode = 1 then
      CheckCallbacksNow;
    Exit;
  end;
  if Mode = 2 then
  begin
    // A try that fails leaves the count alone, unless it would take part.
    if (WaitMode = 1) and (ResultPtr <> 0) then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(SCE_KERNEL_ERROR_MPP_FULL);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  FHLE.Result(0);
  MP.Senders.Add(FCurrent);
  FWaitCheckNs := PSPPipeCheckNs;
  BeginWaitData(PSPWaitMsgPipe, MP, MP.UID, TimeoutPtr, Mode = 1, MP.SendRetry,
    [Buf, Size, WaitMode, Done, 1, ResultPtr], MP.WaitAbort);
end;

procedure TPSPKernel.hSendMsgPipe;
begin
  SendMsgPipeCommon(0);
end;

procedure TPSPKernel.hSendMsgPipeCB;
begin
  SendMsgPipeCommon(1);
end;

procedure TPSPKernel.hTrySendMsgPipe;
begin
  SendMsgPipeCommon(2);
end;

procedure TPSPKernel.ReceiveMsgPipeCommon(Mode: Integer);
begin
  var Buf := FHLE.Arg(1);
  var Size := FHLE.Arg(2);
  if Integer(Size) < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if (Mode <> 2) and RefuseWait then
    Exit;
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID);
    Exit;
  end;
  var WaitMode := FHLE.Arg(3);
  var ResultPtr := FHLE.Arg(4);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(5);
  if Integer(Size) < 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if WaitMode > 1 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MODE);
    Exit;
  end;
  if (MP.BufSize > 0) and (Size > MP.BufSize) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  var Done: Cardinal := 0;
  if MP.Receivers.Count = 0 then
  begin
    // The buffer first; senders waiting refill it as it empties.
    repeat
      var N := Size - Done;
      if N > MP.Used then
        N := MP.Used;
      if (WaitMode = 0) and (MP.BufSize > 0) and (Done = 0) and (MP.Used < Size) and (MP.Senders.Count = 0) then
        N := 0;
      if N > 0 then
      begin
        MP.PopBytes(Buf + Done, N);
        Inc(Done, N);
      end;
      if (Done < Size) and (MP.Senders.Count > 0) then
      begin
        var S := MP.Senders.First;
        var Progress: Boolean;
        if MP.BufSize = 0 then
        begin
          // No buffer: straight from each sender in turn.
          var M := Size - Done;
          if M > S.Wait.Data[1] - S.Wait.Data[3] then
            M := S.Wait.Data[1] - S.Wait.Data[3];
          if M > 0 then
            FMemory.Copy(Buf + Done, S.Wait.Data[0] + S.Wait.Data[3], M);
          Inc(S.Wait.Data[3], M);
          Inc(Done, M);
          Progress := M > 0;
          if PipeDone(S) then
          begin
            PipeFinish(Self, S);
            EndWait(S, 0);
          end;
        end
        else
        begin
          MP.Settle;
          Progress := MP.Used > 0;
        end;
        if not Progress then
          Break;
      end
      else
        Break;
    until Done >= Size;
    MP.Settle;
  end;
  if (Done = Size) or ((WaitMode = 1) and (Done > 0)) then
  begin
    if ResultPtr <> 0 then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(0);
    if Mode = 1 then
      CheckCallbacksNow;
    Exit;
  end;
  if Mode = 2 then
  begin
    // A try that fails leaves the count alone, unless it would take part.
    if (WaitMode = 1) and (ResultPtr <> 0) then
      FMemory.Write32(ResultPtr, Done);
    FHLE.Result(SCE_KERNEL_ERROR_MPP_EMPTY);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  FHLE.Result(0);
  MP.Receivers.Add(FCurrent);
  FWaitCheckNs := PSPPipeCheckNs;
  BeginWaitData(PSPWaitMsgPipe, MP, MP.UID, TimeoutPtr, Mode = 1, MP.ReceiveRetry,
    [Buf, Size, WaitMode, Done, 0, ResultPtr], MP.WaitAbort);
end;

procedure TPSPKernel.hReceiveMsgPipe;
begin
  ReceiveMsgPipeCommon(0);
end;

procedure TPSPKernel.hReceiveMsgPipeCB;
begin
  ReceiveMsgPipeCommon(1);
end;

procedure TPSPKernel.hTryReceiveMsgPipe;
begin
  ReceiveMsgPipeCommon(2);
end;

procedure TPSPKernel.hCancelMsgPipe;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(MP.Senders.Count));
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Cardinal(MP.Receivers.Count));
  FHLE.Result(0);
  while MP.Senders.Count > 0 do
    EndWait(MP.Senders.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  while MP.Receivers.Count > 0 do
    EndWait(MP.Receivers.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
  MP.Used := 0;
end;

procedure TPSPKernel.hReferMsgPipeStatus;
begin
  var MP := TPSPMsgPipe(GetObject(FHLE.Arg(0), TPSPMsgPipe));
  if MP = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MPPID);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(MP.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := MP.Attr;
  PCardinal(@Buf[$28])^ := MP.BufSize;
  PCardinal(@Buf[$2C])^ := MP.FreeSize;
  PCardinal(@Buf[$30])^ := Cardinal(MP.Senders.Count);
  PCardinal(@Buf[$34])^ := Cardinal(MP.Receivers.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ PSP.Kernel: variable and fixed pools, thread-local storage pools. }

type
  // The pool's bookkeeping lives at the start of its memory, as the kernel
  // keeps it: +0 start, +4 start, +8 start + 7, +12 size - 8, +16 units in
  // use, +20 rover (a free block), +24 first block. Blocks are 8-byte units
  // with an 8-byte header (next, units); free blocks form a ring in address
  // order with a zero-sized block at the top that never merges. A used
  // block's next points at +8.
  TPSPVpl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Block, Size, PoolSize: Cardinal;
    class function IdType: Integer; override;
    procedure Init;
    // Returns the user address, 0 when nothing fits.
    function Alloc(Bytes: Cardinal): Cardinal;
    function FreeBlock(Addr: Cardinal): Boolean;
    function FreeSize: Cardinal;
    function Retry(T: TPSPThread): Boolean;
    function MayAlloc(T: TPSPThread): Boolean;
    procedure WakeWaiters;
    procedure WaiterGone; override;
  end;

  TPSPFpl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Block, BlockSize, Stride: Cardinal;
    Count, Next: Integer;
    Used: TArray<Boolean>;
    class function IdType: Integer; override;
    function Alloc(out Addr: Cardinal): Boolean;
    function FreeCount: Integer;
    function Retry(T: TPSPThread): Boolean;
  end;

  TPSPTlspl = class(TPSPWaitObject)
  public
    PartitionId: Integer;
    Index: Integer;
    Block, BlockSize, Stride: Cardinal;
    Count, Next: Integer;
    Owner: TArray<TPSPThread>;
    class function IdType: Integer; override;
    function Find(T: TPSPThread): Integer;
    function Alloc(T: TPSPThread; out Addr: Cardinal): Boolean;
    function FreeCount: Integer;
    function Retry(T: TPSPThread): Boolean;
    procedure Release(T: TPSPThread);
  end;

const
  PSPErrorUnknownTlsplId = Cardinal($800201D0);
  PSPErrorTlsplFull = Cardinal($800201D1);
  PSPErrorTlsplBusy = Cardinal($800201D2);

{ TPSPVpl }

class function TPSPVpl.IdType: Integer;
begin
  Result := 5;
end;

procedure TPSPVpl.Init;
begin
  var M := Kernel.Memory;
  var B := Block;
  var Top := B + Size - 8;
  M.Write32(B, B);
  M.Write32(B + 4, B);
  M.Write32(B + 8, B + 7);
  M.Write32(B + 12, Size - 8);
  M.Write32(B + 16, 0);
  M.Write32(B + 20, B + 24);
  M.Write32(B + 24, Top);
  M.Write32(B + 28, (Top - (B + 24)) div 8);
  M.Write32(Top, B + 24);
  M.Write32(Top + 4, 0);
end;

function TPSPVpl.Alloc(Bytes: Cardinal): Cardinal;
begin
  var M := Kernel.Memory;
  var Units := (Bytes + 7) div 8 + 1;
  var Prev := M.Read32(Block + 20);
  var Start := Prev;
  var P := M.Read32(Prev);
  for var Guard := 0 to 100000 do
  begin
    var PSize := M.Read32(P + 4);
    if PSize >= Units then
    begin
      if PSize = Units then
        M.Write32(Prev, M.Read32(P))
      else
      begin
        M.Write32(P + 4, PSize - Units);
        P := P + (PSize - Units) * 8;
        M.Write32(P + 4, Units);
      end;
      M.Write32(P, Block + 8);
      M.Write32(Block + 20, Prev);
      M.Write32(Block + 16, M.Read32(Block + 16) + Units);
      Exit(P + 8);
    end;
    if P = Start then
      Break;
    Prev := P;
    P := M.Read32(P);
  end;
  Result := 0;
end;

function TPSPVpl.FreeBlock(Addr: Cardinal): Boolean;
begin
  var M := Kernel.Memory;
  if (Addr < Block + 32) or (Addr >= Block + Size) or ((Addr and 7) <> 0) then
    Exit(False);
  var Bp := Addr - 8;
  if M.Read32(Bp) <> Block + 8 then
    Exit(False);
  var BpSize := M.Read32(Bp + 4);
  var Units := BpSize;
  var P := M.Read32(Block + 20);
  for var Guard := 0 to 100000 do
  begin
    var PNext := M.Read32(P);
    if (Bp > P) and (Bp < PNext) then
      Break;
    if (P >= PNext) and ((Bp > P) or (Bp < PNext)) then
      Break;
    P := PNext;
  end;
  var PNext := M.Read32(P);
  if (Bp + BpSize * 8 = PNext) and (M.Read32(PNext + 4) <> 0) then
  begin
    Inc(BpSize, M.Read32(PNext + 4));
    M.Write32(Bp + 4, BpSize);
    M.Write32(Bp, M.Read32(PNext));
  end
  else
    M.Write32(Bp, PNext);
  var PSize := M.Read32(P + 4);
  if P + PSize * 8 = Bp then
  begin
    M.Write32(P + 4, PSize + BpSize);
    M.Write32(P, M.Read32(Bp));
  end
  else
    M.Write32(P, Bp);
  M.Write32(Block + 20, P);
  M.Write32(Block + 16, M.Read32(Block + 16) - Units);
  Result := True;
end;

function TPSPVpl.FreeSize: Cardinal;
begin
  Result := PoolSize - Kernel.Memory.Read32(Block + 16) * 8;
end;

function TPSPVpl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) and ((Attr and $200) = 0) then
    Exit;
  var A := Alloc(T.Wait.Data[0]);
  if A <> 0 then
  begin
    if T.Wait.Data[1] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[1], A);
    T.SetResult(0);
    Result := True;
  end;
end;

function TPSPVpl.MayAlloc(T: TPSPThread): Boolean;
begin
  // A newcomer goes first when it would head the queue; with attr $200 the
  // queue does not hold anyone back.
  Result := (Waiters.Count = 0) or ((Attr and $200) <> 0) or
    (Waiters.ByPriority and (T.Priority < Waiters.First.Priority));
end;

procedure TPSPVpl.WakeWaiters;
begin
  // Waiters are served in queue order; normally the first that does not fit
  // stops the rest, with attr $200 the later ones still get their turn.
  var I := 0;
  while I < Waiters.Count do
  begin
    var T := Waiters.Item(I);
    var A := Alloc(T.Wait.Data[0]);
    if A = 0 then
    begin
      if (Attr and $200) = 0 then
        Break;
      Inc(I);
      Continue;
    end;
    if T.Wait.Data[1] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[1], A);
    Kernel.EndWait(T, 0);
  end;
end;

procedure TPSPVpl.WaiterGone;
begin
  WakeWaiters;
end;

{ TPSPFpl }

class function TPSPFpl.IdType: Integer;
begin
  Result := 6;
end;

function TPSPFpl.Alloc(out Addr: Cardinal): Boolean;
begin
  // The search starts after the block handed out last.
  for var I := 0 to Count - 1 do
  begin
    var N := (Next + I) mod Count;
    if not Used[N] then
    begin
      Used[N] := True;
      Next := (N + 1) mod Count;
      Addr := Block + Cardinal(N) * Stride;
      Exit(True);
    end;
  end;
  Addr := 0;
  Result := False;
end;

function TPSPFpl.FreeCount: Integer;
begin
  Result := 0;
  for var U in Used do
    if not U then
      Inc(Result);
end;

function TPSPFpl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) then
    Exit;
  var A: Cardinal;
  if Alloc(A) then
  begin
    if T.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[0], A);
    T.SetResult(0);
    Result := True;
  end;
end;

{ TPSPTlspl }

class function TPSPTlspl.IdType: Integer;
begin
  Result := 14;
end;

function TPSPTlspl.Find(T: TPSPThread): Integer;
begin
  for var I := 0 to Count - 1 do
    if Owner[I] = T then
      Exit(I);
  Result := -1;
end;

function TPSPTlspl.Alloc(T: TPSPThread; out Addr: Cardinal): Boolean;
begin
  for var I := 0 to Count - 1 do
  begin
    var N := (Next + I) mod Count;
    if Owner[N] = nil then
    begin
      Owner[N] := T;
      Next := (N + 1) mod Count;
      Addr := Block + Cardinal(N) * Stride;
      // A block is cleared when a thread gets it and when it gives it back.
      Kernel.Memory.Fill(Addr, 0, BlockSize);
      T.TlsSlots[Index] := Addr;
      Exit(True);
    end;
  end;
  Addr := 0;
  Result := False;
end;

function TPSPTlspl.FreeCount: Integer;
begin
  Result := 0;
  for var O in Owner do
    if O = nil then
      Inc(Result);
end;

function TPSPTlspl.Retry(T: TPSPThread): Boolean;
begin
  if not Kernel.FObjects.ContainsKey(UID) or (T.Wait.Obj <> Self) then
  begin
    T.SetResult(SCE_KERNEL_ERROR_WAIT_DELETE);
    Exit(True);
  end;
  Result := False;
  if (Waiters.Count > 0) and (Waiters.First <> T) then
    Exit;
  var A: Cardinal;
  if Alloc(T, A) then
  begin
    if T.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(T.Wait.Data[0], A);
    if T.Wait.Data[1] <> 0 then
      T.SetResult(A)
    else
      T.SetResult(0);
    Result := True;
  end;
end;

procedure TPSPTlspl.Release(T: TPSPThread);
begin
  var I := Find(T);
  if I < 0 then
    Exit;
  Owner[I] := nil;
  T.TlsSlots[Index] := 0;
  Kernel.Memory.Fill(Block + Cardinal(I) * Stride, 0, BlockSize);
  while Waiters.Count > 0 do
  begin
    var W := Waiters.First;
    var A: Cardinal;
    if not Alloc(W, A) then
      Break;
    if W.Wait.Data[0] <> 0 then
      Kernel.Memory.Write32(W.Wait.Data[0], A);
    var IsGet := W.Wait.Data[1] <> 0;
    Kernel.EndWait(W, 0);
    if IsGet then
      W.SetResult(A);
  end;
end;

{ Pool memory }

function TPSPKernel.PoolPartition(PartId: Integer): TPSPPartition;
begin
  Result := Partition(PartId);
  if Result = nil then
    Result := FKernelPartition;
end;

{ HLE: variable pools }

procedure TPSPKernel.hCreateVpl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($43FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var Size := FHLE.Arg(3);
  if Size = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  if Size > $7FFFFFF0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  Size := AlignUp(Size, 8);
  if Size <= $30 then
    Size := $1000;
  var P := PoolPartition(PartId);
  var Block: Cardinal;
  if (Attr and $4000) <> 0 then
    Block := P.Alloc(Size, akHigh, 0, 256, 'vpl:' + Name)
  else
    Block := P.Alloc(Size, akLow, 0, 256, 'vpl:' + Name);
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var V := TPSPVpl.Create;
  V.Name := Name;
  V.Attr := Attr;
  V.PartitionId := PartId;
  V.Block := Block;
  V.Size := Size;
  V.PoolSize := Size - $20;
  V.Waiters.ByPriority := (Attr and $100) <> 0;
  AddObject(V);
  V.Init;
  Spend(PSPSyncCallNs);
  FHLE.Result(V.UID);
end;

procedure TPSPKernel.hDeleteVpl;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID);
    Exit;
  end;
  FHLE.Result(0);
  while V.Waiters.Count > 0 do
    EndWait(V.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  PoolPartition(V.PartitionId).FreeBlock(V.Block);
  DeleteObject(V);
end;

// Mode: 0 waits, 1 waits with callbacks, 2 does not wait.
procedure TPSPKernel.AllocateVplCommon(Mode: Integer);
begin
  if (Mode <> 2) and RefuseWait then
    Exit;
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID);
    Exit;
  end;
  var Bytes := FHLE.Arg(1);
  var OutPtr := FHLE.Arg(2);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(3);
  if (Bytes = 0) or (Bytes > V.PoolSize) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  // Trying never minds the queue.
  if (Mode = 2) or V.MayAlloc(FCurrent) then
  begin
    var A := V.Alloc(Bytes);
    if A <> 0 then
    begin
      if OutPtr <> 0 then
        FMemory.Write32(OutPtr, A);
      FHLE.Result(0);
      if Mode = 1 then
        CheckCallbacksNow;
      Exit;
    end;
  end;
  if Mode = 2 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  FHLE.Result(0);
  V.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitVpl, V, V.UID, TimeoutPtr, Mode = 1, V.Retry, [Bytes, OutPtr]);
end;

procedure TPSPKernel.hAllocateVpl;
begin
  AllocateVplCommon(0);
end;

procedure TPSPKernel.hAllocateVplCB;
begin
  AllocateVplCommon(1);
end;

procedure TPSPKernel.hTryAllocateVpl;
begin
  AllocateVplCommon(2);
end;

procedure TPSPKernel.hFreeVpl;
begin
  var Addr := FHLE.Arg(1);
  if (Addr and $80000000) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID);
    Exit;
  end;
  if not V.FreeBlock(Addr) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  V.WakeWaiters;
end;

procedure TPSPKernel.hCancelVpl;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(V.Waiters.Count));
  FHLE.Result(0);
  while V.Waiters.Count > 0 do
    EndWait(V.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferVplStatus;
begin
  var V := TPSPVpl(GetObject(FHLE.Arg(0), TPSPVpl));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VPLID);
    Exit;
  end;
  var Buf: array[0..$33] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(V.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := V.Attr;
  PCardinal(@Buf[$28])^ := V.PoolSize;
  PCardinal(@Buf[$2C])^ := V.FreeSize;
  PCardinal(@Buf[$30])^ := Cardinal(V.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ HLE: fixed pools }

function ValidPoolAlignment(A: Cardinal): Boolean;
begin
  Result := (A = 0) or ((A and (A - 1)) = 0) and (A <= $10000000);
end;

procedure TPSPKernel.hCreateFpl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($41FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var BlockSize := FHLE.Arg(3);
  var Count := FHLE.Arg(4);
  if (BlockSize = 0) or (Integer(BlockSize) < 0) or (Count = 0) or (Integer(Count) < 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  var Align: Cardinal := 4;
  var Opt := FHLE.Arg(5);
  if (Opt <> 0) and (FMemory.Read32(Opt) >= 8) then
  begin
    var A := FMemory.Read32(Opt + 4);
    if not ValidPoolAlignment(A) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
      Exit;
    end;
    if A > Align then
      Align := A;
  end;
  var Stride := AlignUp(BlockSize, Align);
  // The size is worked out in 32 bits: one that wraps to nothing is refused.
  var Total := Cardinal(UInt64(Stride) * Count);
  if Total = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  var P := PoolPartition(PartId);
  var Block: Cardinal := 0;
  if UInt64(Stride) * Count <= $7FFFFFFF then
    if (Attr and $4000) <> 0 then
      Block := P.Alloc(Total, akHigh, 0, 256, 'fpl:' + Name)
    else
      Block := P.Alloc(Total, akLow, 0, 256, 'fpl:' + Name);
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var F := TPSPFpl.Create;
  F.Name := Name;
  F.Attr := Attr;
  F.PartitionId := PartId;
  F.Block := Block;
  F.BlockSize := BlockSize;
  F.Stride := Stride;
  F.Count := Integer(Count);
  SetLength(F.Used, Count);
  F.Waiters.ByPriority := (Attr and $100) <> 0;
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(F));
end;

procedure TPSPKernel.hDeleteFpl;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID);
    Exit;
  end;
  FHLE.Result(0);
  while F.Waiters.Count > 0 do
    EndWait(F.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  PoolPartition(F.PartitionId).FreeBlock(F.Block);
  DeleteObject(F);
end;

procedure TPSPKernel.AllocateFplCommon(Mode: Integer);
begin
  if (Mode <> 2) and RefuseWait then
    Exit;
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID);
    Exit;
  end;
  var OutPtr := FHLE.Arg(1);
  var TimeoutPtr: Cardinal := 0;
  if Mode <> 2 then
    TimeoutPtr := FHLE.Arg(2);
  Spend(PSPSyncCallNs);
  if F.Waiters.Count = 0 then
  begin
    var A: Cardinal;
    if F.Alloc(A) then
    begin
      if OutPtr <> 0 then
        FMemory.Write32(OutPtr, A);
      FHLE.Result(0);
      if Mode = 1 then
        CheckCallbacksNow;
      Exit;
    end;
  end;
  if Mode = 2 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  FHLE.Result(0);
  F.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitFpl, F, F.UID, TimeoutPtr, Mode = 1, F.Retry, [OutPtr]);
end;

procedure TPSPKernel.hAllocateFpl;
begin
  AllocateFplCommon(0);
end;

procedure TPSPKernel.hAllocateFplCB;
begin
  AllocateFplCommon(1);
end;

procedure TPSPKernel.hTryAllocateFpl;
begin
  AllocateFplCommon(2);
end;

procedure TPSPKernel.hFreeFpl;
begin
  var Addr := FHLE.Arg(1);
  if (Addr and $80000000) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID);
    Exit;
  end;
  if (Addr < F.Block) or ((Addr - F.Block) mod F.Stride <> 0) or (Integer((Addr - F.Block) div F.Stride) >= F.Count) or
    not F.Used[(Addr - F.Block) div F.Stride] then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK);
    Exit;
  end;
  Spend(PSPSyncCallNs);
  FHLE.Result(0);
  var Index := (Addr - F.Block) div F.Stride;
  if F.Waiters.Count > 0 then
  begin
    // Straight to the first waiter.
    var T := F.Waiters.First;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], Addr);
    EndWait(T, 0);
    Exit;
  end;
  F.Used[Index] := False;
end;

procedure TPSPKernel.hCancelFpl;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), Cardinal(F.Waiters.Count));
  FHLE.Result(0);
  while F.Waiters.Count > 0 do
    EndWait(F.Waiters.First, SCE_KERNEL_ERROR_WAIT_CANCEL);
end;

procedure TPSPKernel.hReferFplStatus;
begin
  var F := TPSPFpl(GetObject(FHLE.Arg(0), TPSPFpl));
  if F = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_FPLID);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(F.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := F.Attr;
  PCardinal(@Buf[$28])^ := F.BlockSize;
  PCardinal(@Buf[$2C])^ := Cardinal(F.Count);
  PCardinal(@Buf[$30])^ := Cardinal(F.FreeCount);
  PCardinal(@Buf[$34])^ := Cardinal(F.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $38);
  FHLE.Result(0);
end;

{ HLE: thread-local storage pools }

function TPSPKernel.TlsplOf(Id: Cardinal): TPSPKernelObject;
begin
  // Ids carry the pool's slot in bits 3..6; that is what the lookup uses.
  var Index := Integer((Id shr 3) and $F);
  for var O in FObjects.Values do
    if (O is TPSPTlspl) and (TPSPTlspl(O).Index = Index) then
      Exit(O);
  Result := nil;
end;

procedure TPSPKernel.hCreateTlspl;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var PartId := FHLE.ArgInt(1);
  var Err := UserPartitionCheck(PartId);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var Attr := FHLE.Arg(2);
  if (Attr and not Cardinal($41FF)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ATTR);
    Exit;
  end;
  var BlockSize := FHLE.Arg(3);
  var Count := FHLE.Arg(4);
  if (BlockSize = 0) or (Integer(BlockSize) < 0) or (Count = 0) or (Integer(Count) < 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  var Align: Cardinal := 4;
  var Opt := FHLE.Arg(5);
  if (Opt <> 0) and (FMemory.Read32(Opt) >= 8) then
  begin
    var A := FMemory.Read32(Opt + 4);
    if not ValidPoolAlignment(A) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
      Exit;
    end;
    if A > Align then
      Align := A;
  end;
  var Used: array[0..15] of Boolean;
  FillChar(Used, SizeOf(Used), 0);
  for var O in FObjects.Values do
    if O is TPSPTlspl then
      Used[TPSPTlspl(O).Index] := True;
  var Index := -1;
  for var I := 0 to 15 do
    if not Used[I] then
    begin
      Index := I;
      Break;
    end;
  if Index < 0 then
  begin
    FHLE.Result(PSPErrorTlsplFull);
    Exit;
  end;
  var Stride := AlignUp(BlockSize, Align);
  var Total := UInt64(Stride) * Count;
  if Total > $7FFFFFFF then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMSIZE);
    Exit;
  end;
  var P := PoolPartition(PartId);
  var Block: Cardinal;
  if (Attr and $4000) <> 0 then
    Block := P.Alloc(Cardinal(Total), akHigh, 0, 256, 'tlspl:' + Name)
  else
    Block := P.Alloc(Cardinal(Total), akLow, 0, 256, 'tlspl:' + Name);
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var L := TPSPTlspl.Create;
  L.Name := Name;
  L.Attr := Attr;
  L.PartitionId := PartId;
  L.Index := Index;
  L.Block := Block;
  L.BlockSize := BlockSize;
  L.Stride := Stride;
  L.Count := Integer(Count);
  SetLength(L.Owner, Count);
  L.Waiters.ByPriority := (Attr and $100) <> 0;
  // Pick an id whose slot bits say which pool it is.
  while ((FNextUID shr 3) and $F) <> Cardinal(Index) do
    Inc(FNextUID, 2);
  Spend(PSPSyncCallNs);
  FHLE.Result(AddObject(L));
end;

procedure TPSPKernel.hDeleteTlspl;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
  begin
    FHLE.Result(PSPErrorUnknownTlsplId);
    Exit;
  end;
  // Blocks other threads still hold keep the pool alive.
  for var O in L.Owner do
    if (O <> nil) and (O <> FCurrent) then
    begin
      FHLE.Result(PSPErrorTlsplBusy);
      Exit;
    end;
  FHLE.Result(0);
  while L.Waiters.Count > 0 do
    EndWait(L.Waiters.First, SCE_KERNEL_ERROR_WAIT_DELETE);
  for var O in L.Owner do
    if O <> nil then
      O.TlsSlots[L.Index] := 0;
  PoolPartition(L.PartitionId).FreeBlock(L.Block);
  DeleteObject(L);
end;

// The thread's own block, or a free one; False when it has to wait.
function TPSPKernel.TlsTake(Obj: TPSPKernelObject; out Addr: Cardinal): Boolean;
begin
  var L := TPSPTlspl(Obj);
  var I := L.Find(FCurrent);
  if I >= 0 then
  begin
    Addr := L.Block + Cardinal(I) * L.Stride;
    Exit(True);
  end;
  Result := (L.Waiters.Count = 0) and L.Alloc(FCurrent, Addr);
end;

procedure TPSPKernel.hGetTlsAddr;
begin
  // The library keeps each thread's block by the pool's slot (bits 3..6 of
  // the id) and only asks the kernel when it has none.
  if (FCurrent = nil) or InInterrupt then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var Cached := FCurrent.TlsSlots[(FHLE.Arg(0) shr 3) and $F];
  if Cached <> 0 then
  begin
    FHLE.Result(Cached);
    Exit;
  end;
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if (L = nil) or not CanWait then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var A: Cardinal;
  if TlsTake(L, A) then
  begin
    FHLE.Result(A);
    Exit;
  end;
  FHLE.Result(0);
  L.Waiters.Add(FCurrent);
  if BeginWaitData(PSPWaitTlspl, L, L.UID, 0, False, L.Retry, [0, 1]) then
    FCurrent.Wait.FailAsZero := True;
end;

procedure TPSPKernel.hAllocateTlspl;
begin
  var OutPtr := FHLE.Arg(1);
  var TimeoutPtr := FHLE.Arg(2);
  if RefuseWait then
    Exit;
  if ((OutPtr and $80000000) <> 0) or ((TimeoutPtr and $80000000) <> 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
  begin
    FHLE.Result(PSPErrorUnknownTlsplId);
    Exit;
  end;
  var A: Cardinal;
  if TlsTake(L, A) then
  begin
    if OutPtr <> 0 then
      FMemory.Write32(OutPtr, A);
    FHLE.Result(0);
    Exit;
  end;
  FHLE.Result(0);
  L.Waiters.Add(FCurrent);
  BeginWaitData(PSPWaitTlspl, L, L.UID, TimeoutPtr, False, L.Retry, [OutPtr, 0]);
end;

procedure TPSPKernel.hFreeTlspl;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
  begin
    FHLE.Result(PSPErrorUnknownTlsplId);
    Exit;
  end;
  FHLE.Result(0);
  if FCurrent <> nil then
    L.Release(FCurrent);
end;

procedure TPSPKernel.hReferTlsplStatus;
begin
  var L := TPSPTlspl(GetObject(FHLE.Arg(0), TPSPTlspl));
  if L = nil then
  begin
    FHLE.Result(PSPErrorUnknownTlsplId);
    Exit;
  end;
  var Buf: array[0..$3B] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(L.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := L.Attr;
  PCardinal(@Buf[$28])^ := Cardinal(L.Index);
  PCardinal(@Buf[$2C])^ := L.BlockSize;
  PCardinal(@Buf[$30])^ := Cardinal(L.Count);
  PCardinal(@Buf[$34])^ := Cardinal(L.FreeCount);
  PCardinal(@Buf[$38])^ := Cardinal(L.Waiters.Count);
  WriteInfo(FHLE.Arg(1), Buf, $3C);
  FHLE.Result(0);
end;

procedure TPSPKernel.ReleaseTlsOf(T: TPSPThread);
begin
  for var O in FObjects.Values.ToArray do
    if O is TPSPTlspl then
      TPSPTlspl(O).Release(T);
end;

{ PSP.Kernel: alarms, virtual timers, thread event handlers. }

type
  TPSPAlarm = class(TPSPKernelObject)
  public
    Handler, Common, GP: Cardinal;
    // When it is due (system time, us) and when the handler really runs (ns).
    Schedule: UInt64;
    TimerHandle: Int64;
    class function IdType: Integer; override;
  end;

  TPSPVTimer = class(TPSPKernelObject)
  public
    Active: Boolean;
    // Time counted while stopped, and the system time (us) it last started at.
    Accumulated: UInt64;
    StartedAt: UInt64;
    Handler, Common, GP: Cardinal;
    Schedule: UInt64;
    TimerHandle: Int64;
    class function IdType: Integer; override;
    function Current(NowUs: UInt64): UInt64;
  end;

  TPSPThreadEventHandler = class(TPSPKernelObject)
  public
    ThreadId, Mask, Handler, Common, GP: Cardinal;
    class function IdType: Integer; override;
  end;

const
  PSPErrorIllegalVTimer = Cardinal($800201BF);
  // The thread manager arms its timer no sooner than this after the call, and
  // the handler starts a while after the timer goes off.
  PSPAlarmMinUs = 215;
  PSPAlarmLatencyNs = 41000;
  PSPSetAlarmNs = 42000;

// Guest clock values wrap like the 64-bit counters they are.
{$Q-}
function WrapAdd(A, B: UInt64): UInt64;
begin
  Result := A + B;
end;

function WrapSub(A, B: UInt64): UInt64;
begin
  Result := A - B;
end;
{$IFDEF PSP_CHECKED}{$Q+}{$ENDIF}

class function TPSPAlarm.IdType: Integer;
begin
  Result := 10;
end;

class function TPSPVTimer.IdType: Integer;
begin
  Result := 11;
end;

function TPSPVTimer.Current(NowUs: UInt64): UInt64;
begin
  Result := Accumulated;
  if Active then
    Result := WrapAdd(Result, WrapSub(NowUs, StartedAt));
end;

class function TPSPThreadEventHandler.IdType: Integer;
begin
  Result := 9;
end;

{ Alarms }

procedure TPSPKernel.ArmAlarm(Obj: TPSPKernelObject; FireAt: Int64);
begin
  var A := TPSPAlarm(Obj);
  A.TimerHandle := AddStateTimer(FireAt, A, TPSPStateAction.Create(StateAlarmFire, [], [A.UID]));
end;

procedure TPSPKernel.StateAlarmFire(Action: TPSPStateAction; Value: Cardinal);
begin
  var A := TPSPAlarm(GetObject(Cardinal(Action.Arg(0)), TPSPAlarm));
  if A = nil then
    Exit;
  A.TimerHandle := 0;
  QueueInterrupt(A.Handler, [A.Common], A.GP, nil, PSPAlarmLatencyNs, A.UID, TPSPStateAction.Create(StateAlarmReturn,
      [], [A.UID]));
end;

procedure TPSPKernel.StateAlarmReturn(Action: TPSPStateAction; Value: Cardinal);
begin
  var A := TPSPAlarm(GetObject(Cardinal(Action.Arg(0)), TPSPAlarm));
  if A = nil then
    Exit;
  if Value = 0 then
    DeleteObject(A)
  else
  begin
    var NowUs := UInt64(FScheduler.Now div 1000);
    A.Schedule := WrapAdd(A.Schedule, Value);
    if A.Schedule <= NowUs then
      A.Schedule := NowUs + Value;
    if A.Schedule < UInt64(High(Int64) div 4000) then
      ArmAlarm(A, Int64(A.Schedule) * 1000);
  end;
end;

procedure TPSPKernel.SetAlarmCommon(Us: UInt64);
begin
  var Handler := FHLE.Arg(1);
  if (Handler = 0) or not ValidUserAddress(Handler) and not ((FCurrent <> nil) and FCurrent.IsKernel) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var Start := FScheduler.Now;
  var A := TPSPAlarm.Create;
  A.Name := 'alarm';
  A.Handler := Handler;
  A.Common := FHLE.Arg(2);
  A.GP := FCPU.Ctx.GPR[28];
  A.Schedule := WrapAdd(UInt64(Start div 1000), Us);
  AddObject(A);
  var Wait := Us;
  if Wait < PSPAlarmMinUs then
    Wait := PSPAlarmMinUs;
  var FireAt: Int64 := PSPNever;
  if Wait < UInt64(High(Int64) div 4000) then
    FireAt := Start + Int64(Wait) * 1000;
  if FireAt <> PSPNever then
    ArmAlarm(A, FireAt);
  Spend(PSPSetAlarmNs);
  FHLE.Result(A.UID);
end;

procedure TPSPKernel.hSetAlarm;
begin
  SetAlarmCommon(FHLE.Arg(0));
end;

procedure TPSPKernel.hSetSysClockAlarm;
begin
  var P := FHLE.Arg(0);
  var Us := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetAlarmCommon(Us);
end;

procedure TPSPKernel.hCancelAlarm;
begin
  var A := TPSPAlarm(GetObject(FHLE.Arg(0), TPSPAlarm));
  if A = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_ALMID);
    Exit;
  end;
  DeleteObject(A);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferAlarmStatus;
begin
  var A := TPSPAlarm(GetObject(FHLE.Arg(0), TPSPAlarm));
  if A = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_ALMID);
    Exit;
  end;
  var Buf: array[0..$13] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PUInt64(@Buf[4])^ := A.Schedule;
  PCardinal(@Buf[$C])^ := A.Handler;
  PCardinal(@Buf[$10])^ := A.Common;
  WriteInfo(FHLE.Arg(1), Buf, $14);
  FHLE.Result(0);
end;

{ Virtual timers }

procedure TPSPKernel.ArmVTimer(Obj: TPSPKernelObject; FromCall: Boolean);
begin
  var V := TPSPVTimer(Obj);
  if V.TimerHandle <> 0 then
  begin
    CancelTimer(V.TimerHandle);
    V.TimerHandle := 0;
  end;
  if not V.Active or (V.Handler = 0) then
    Exit;
  var NowUs := UInt64(FScheduler.Now div 1000);
  var Cur := V.Current(NowUs);
  var Delta: UInt64 := 0;
  if V.Schedule > Cur then
    Delta := V.Schedule - Cur;
  // Armed by a call, it goes off no sooner than an alarm would.
  if FromCall and (Delta < PSPAlarmMinUs) then
    Delta := PSPAlarmMinUs;
  if Delta > UInt64(High(Int64) div 4000) then
    Exit;
  var At := FScheduler.Now + Int64(Delta) * 1000 + PSPAlarmLatencyNs;
  V.TimerHandle := AddStateTimer(At, V, TPSPStateAction.Create(StateVTimerFire, [], [V.UID]));
end;

procedure TPSPKernel.StateVTimerFire(Action: TPSPStateAction; Value: Cardinal);
begin
  var V := TPSPVTimer(GetObject(Cardinal(Action.Arg(0)), TPSPVTimer));
  if V = nil then
    Exit;
  V.TimerHandle := 0;
  if not V.Active or (V.Handler = 0) then
    Exit;
  var Args := FIntStack - $200;
  var Real := V.Current(UInt64(FScheduler.Now div 1000));
  FMemory.Write32(Args, Cardinal(V.Schedule));
  FMemory.Write32(Args + 4, Cardinal(V.Schedule shr 32));
  FMemory.Write32(Args + 8, Cardinal(Real));
  FMemory.Write32(Args + 12, Cardinal(Real shr 32));
  FFiringVTimer := V.UID;
  QueueInterrupt(V.Handler, [V.UID, Args, Args + 8, V.Common], V.GP, nil, 0, V.UID,
    TPSPStateAction.Create(StateVTimerReturn, [], [V.UID]));
end;

procedure TPSPKernel.StateVTimerReturn(Action: TPSPStateAction; Value: Cardinal);
begin
  FFiringVTimer := 0;
  var V := TPSPVTimer(GetObject(Cardinal(Action.Arg(0)), TPSPVTimer));
  if V = nil then
    Exit;
  if Value = 0 then
    V.Handler := 0
  else
  begin
    V.Schedule := WrapAdd(V.Schedule, Value);
    ArmVTimer(V, False);
  end;
end;

procedure TPSPKernel.hCreateVTimer;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var V := TPSPVTimer.Create;
  V.Name := Name;
  FHLE.Result(AddObject(V));
end;

function TPSPKernel.VTimerOf(Id: Cardinal): TPSPKernelObject;
begin
  Result := GetObject(Id, TPSPVTimer);
end;

procedure TPSPKernel.hDeleteVTimer;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  DeleteObject(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerBase;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  var P := FHLE.Arg(1);
  var Base: UInt64 := 0;
  if V.Active then
    Base := V.StartedAt;
  FMemory.Write32(P, Cardinal(Base));
  FMemory.Write32(P + 4, Cardinal(Base shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerBaseWide;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result64(UInt64(-1));
    Exit;
  end;
  if V.Active then
    FHLE.Result64(V.StartedAt)
  else
    FHLE.Result64(0);
end;

procedure TPSPKernel.hGetVTimerTime;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  var P := FHLE.Arg(1);
  var T := V.Current(UInt64(NowUs));
  FMemory.Write32(P, Cardinal(T));
  FMemory.Write32(P + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetVTimerTimeWide;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result64(UInt64(-1));
    Exit;
  end;
  FHLE.Result64(V.Current(UInt64(NowUs)));
end;

procedure TPSPKernel.SetVTimerTimeTo(Obj: TPSPKernelObject; Value: UInt64);
begin
  var V := TPSPVTimer(Obj);
  var NowU := UInt64(NowUs);
  V.Accumulated := Value;
  if V.Active then
    V.StartedAt := NowU;
  ArmVTimer(V);
end;

procedure TPSPKernel.hSetVTimerTime;
begin
  if InInterrupt then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  var P := FHLE.Arg(1);
  var Old := V.Current(UInt64(NowUs));
  var Value := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetVTimerTimeTo(V, Value);
  FMemory.Write32(P, Cardinal(Old));
  FMemory.Write32(P + 4, Cardinal(Old shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hSetVTimerTimeWide;
begin
  if InInterrupt then
  begin
    FHLE.Result64(UInt64(-1));
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result64(UInt64(-1));
    Exit;
  end;
  var Old := V.Current(UInt64(NowUs));
  SetVTimerTimeTo(V, FHLE.Arg64(2));
  FHLE.Result64(Old);
end;

procedure TPSPKernel.hStartVTimer;
begin
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(PSPErrorIllegalVTimer);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  if V.Active then
  begin
    FHLE.Result(1);
    Exit;
  end;
  V.Active := True;
  V.StartedAt := UInt64(NowUs);
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hStopVTimer;
begin
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(PSPErrorIllegalVTimer);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  if not V.Active then
  begin
    FHLE.Result(0);
    Exit;
  end;
  V.Accumulated := V.Current(UInt64(NowUs));
  V.Active := False;
  ArmVTimer(V);
  FHLE.Result(1);
end;

procedure TPSPKernel.SetVTimerHandlerCommon(Schedule: UInt64; Handler, Common: Cardinal);
begin
  if FHLE.Arg(0) = 0 then
  begin
    FHLE.Result(PSPErrorIllegalVTimer);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  FHLE.Result(0);
  // No handler only takes the old one away.
  if Handler = 0 then
  begin
    V.Handler := 0;
    ArmVTimer(V);
    Exit;
  end;
  V.Handler := Handler;
  V.Common := Common;
  V.GP := FCPU.Ctx.GPR[28];
  V.Schedule := Schedule;
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hSetVTimerHandler;
begin
  var P := FHLE.Arg(1);
  var Sched: UInt64 := 0;
  if P <> 0 then
    Sched := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  SetVTimerHandlerCommon(Sched, FHLE.Arg(2), FHLE.Arg(3));
end;

procedure TPSPKernel.hSetVTimerHandlerWide;
begin
  SetVTimerHandlerCommon(FHLE.Arg64(2), FHLE.Arg(4), FHLE.Arg(5));
end;

procedure TPSPKernel.hCancelVTimerHandler;
begin
  // Outside a handler 0 is refused; inside one, the timer being handled is.
  var Id := FHLE.Arg(0);
  if (not InInterrupt and (Id = 0)) or (InInterrupt and (FFiringVTimer <> 0) and (Id = FFiringVTimer)) then
  begin
    FHLE.Result(PSPErrorIllegalVTimer);
    Exit;
  end;
  var V := TPSPVTimer(VTimerOf(Id));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  // The schedule and the common value stay.
  V.Handler := 0;
  ArmVTimer(V);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferVTimerStatus;
begin
  var V := TPSPVTimer(VTimerOf(FHLE.Arg(0)));
  if V = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_VTID);
    Exit;
  end;
  var Buf: array[0..$47] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(V.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  var NowU := UInt64(NowUs);
  PCardinal(@Buf[$24])^ := Ord(V.Active);
  if V.Active then
    PUInt64(@Buf[$28])^ := V.StartedAt;
  PUInt64(@Buf[$30])^ := V.Current(NowU);
  PUInt64(@Buf[$38])^ := V.Schedule;
  PCardinal(@Buf[$40])^ := V.Handler;
  PCardinal(@Buf[$44])^ := V.Common;
  WriteInfo(FHLE.Arg(1), Buf, $48);
  FHLE.Result(0);
end;

{ Thread event handlers }

procedure TPSPKernel.NotifyThreadEvent(Kind: Cardinal; T: TPSPThread);
begin
  if (FEventHandlers.Count = 0) or T.EventWorker then
    Exit;
  var Event := Default(TPSPThreadEvent);
  Event.Kind := Kind;
  Event.ThreadId := T.UID;
  for var Obj in FEventHandlers do
  begin
    var E := TPSPThreadEventHandler(Obj);
    if ((E.Mask and Kind) <> 0) and ((E.ThreadId = T.UID) or
      (E.ThreadId = $FFFFFFFF) or ((E.ThreadId = $FFFFFFF0) and not T.IsKernel) or
      ((E.ThreadId = $FFFFFFF8) and T.IsKernel)) then
      Event.Handlers := Event.Handlers + [E.UID];
  end;
  if Length(Event.Handlers) > 0 then
  begin
    // Keep IDs, not borrowed objects: the notifying thread or a handler may
    // be deleted before execution. Dispatch at the next syscall boundary.
    FThreadEvents.Enqueue(Event);
    FCPU.Stop;
  end;
end;

procedure TPSPKernel.DispatchThreadEvents;
begin
  if InInterrupt or (FThreadEvents.Count = 0) then
    Exit;
  if FCurrent <> nil then
    for var Frame in FCurrent.Frames do
      if Frame.Kind = fkThreadEvent then
        Exit;
  if FCurrent = nil then
  begin
    // Exit/delete of the last runnable thread still has to deliver its
    // notifications. This internal thread exits when its guest frames end.
    var Worker := CreateThread('SceThreadEvent', FTrapBase + 8, 8, $1000, 0, 0);
    if Worker = nil then
      raise EPSPError.Create('PSP: no stack for thread event notifications');
    Worker.DeleteOnExit := True;
    Worker.EventWorker := True;
    StartThread(Worker, 0, 0);
    Reschedule;
  end;
  if (FCurrent = nil) or ((FCurrent.Status and PSPThreadRunning) = 0) then
    Exit;
  var Event := FThreadEvents.Dequeue;
  var Action := TPSPStateAction.Create(StateThreadEventNext, [], [Event.Kind, Event.ThreadId, 0]);
  var KeepAlive: IPSPStateAction := Action;
  SetLength(Action.Arrays, 1);
  Action.Arrays[0] := Event.Handlers;
  Action.Run;
end;

procedure TPSPKernel.StateThreadEventNext(Action: TPSPStateAction; Value: Cardinal);
begin
  while Action.Arg(2) < Length(Action.Arrays[0]) do
  begin
    var Id := Action.Arrays[0][Action.Arg(2)];
    Inc(Action.Values[2]);
    var E := TPSPThreadEventHandler(GetObject(Id, TPSPThreadEventHandler));
    if E = nil then
      Continue;
    CallGuest(E.Handler, [Cardinal(Action.Arg(0)), Cardinal(Action.Arg(1)), E.Common], nil, E.GP, Action);
    FCPU.Ctx.GPR[28] := E.GP;
    var Frame := FCurrent.Frames.Last;
    Frame.Kind := fkThreadEvent;
    FCurrent.Frames[FCurrent.Frames.Count - 1] := Frame;
    Exit;
  end;
end;

procedure TPSPKernel.hRegisterThreadEventHandler;
begin
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Tid := FHLE.Arg(1);
  if Tid = 0 then
  begin
    if FCurrent = nil then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_CONTEXT);
      Exit;
    end;
    Tid := FCurrent.UID;
  end;
  if (FHLE.Arg(2) and not Cardinal($F)) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MASK);
    Exit;
  end;
  if (FHLE.Arg(3) = 0) or not FMemory.Valid(FHLE.Arg(3), 4) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if (Tid <> $FFFFFFFF) and (Tid <> $FFFFFFF0) and (Tid <> $FFFFFFF8) and (GetObject(Tid, TPSPThread) = nil) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_THID);
    Exit;
  end;
  var E := TPSPThreadEventHandler.Create;
  E.Name := Name;
  E.ThreadId := Tid;
  E.Mask := FHLE.Arg(2);
  E.Handler := FHLE.Arg(3);
  E.Common := FHLE.Arg(4);
  E.GP := FCPU.Ctx.GPR[28];
  FEventHandlers.Add(E);
  FHLE.Result(AddObject(E));
end;

procedure TPSPKernel.hReleaseThreadEventHandler;
begin
  var E := TPSPThreadEventHandler(GetObject(FHLE.Arg(0), TPSPThreadEventHandler));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_TEID);
    Exit;
  end;
  FEventHandlers.Remove(E);
  DeleteObject(E);
  FHLE.Result(0);
end;

procedure TPSPKernel.hReferThreadEventHandlerStatus;
begin
  var E := TPSPThreadEventHandler(GetObject(FHLE.Arg(0), TPSPThreadEventHandler));
  if E = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_TEID);
    Exit;
  end;
  var Buf: array[0..$37] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  var N := RawByteString(E.Name);
  if N <> '' then
    Move(N[1], Buf[4], Length(N));
  PCardinal(@Buf[$24])^ := E.ThreadId;
  PCardinal(@Buf[$28])^ := E.Mask;
  PCardinal(@Buf[$2C])^ := E.Handler;
  PCardinal(@Buf[$30])^ := E.Common;
  WriteInfo(FHLE.Arg(1), Buf, $34);
  FHLE.Result(0);
end;

{ PSP.Kernel: time, interrupts, system memory, registration. }

type
  TPSPMemBlock = class(TPSPKernelObject)
  public
    PartitionId: Integer;
    Address, Size: Cardinal;
  end;

  // A kernel heap (SysMemForKernel): blocks carved from one partition block.
  TPSPHeap = class(TPSPKernelObject)
  public
    PartitionId: Integer;
    Block, Size: Cardinal;
    Area: TPSPPartition;
    destructor Destroy; override;
  end;

destructor TPSPHeap.Destroy;
begin
  Area.Free;
  inherited;
end;

procedure TPSPKernel.hGetSystemTime;
begin
  var P := FHLE.Arg(0);
  var T := UInt64(NowUs);
  FMemory.Write32(P, Cardinal(T));
  FMemory.Write32(P + 4, Cardinal(T shr 32));
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetSystemTimeWide;
begin
  FHLE.Result64(UInt64(NowUs));
end;

procedure TPSPKernel.hGetSystemTimeLow;
begin
  FHLE.Result(Cardinal(NowUs));
end;

procedure TPSPKernel.hUSec2SysClock;
begin
  var P := FHLE.Arg(1);
  FMemory.Write32(P, FHLE.Arg(0));
  FMemory.Write32(P + 4, 0);
  FHLE.Result(0);
end;

procedure TPSPKernel.hUSec2SysClockWide;
begin
  FHLE.Result64(FHLE.Arg(0));
end;

procedure TPSPKernel.hSysClock2USec;
begin
  var P := FHLE.Arg(0);
  var Clock := UInt64(FMemory.Read32(P)) or (UInt64(FMemory.Read32(P + 4)) shl 32);
  var SecPtr := FHLE.Arg(1);
  var UsPtr := FHLE.Arg(2);
  if SecPtr <> 0 then
  begin
    FMemory.Write32(SecPtr, Cardinal(Clock div 1000000));
    if UsPtr <> 0 then
      FMemory.Write32(UsPtr, Cardinal(Clock mod 1000000));
  end
  else if UsPtr <> 0 then
    FMemory.Write32(UsPtr, Cardinal(Clock));
  FHLE.Result(0);
end;

procedure TPSPKernel.hSysClock2USecWide;
begin
  var Clock := FHLE.Arg64(0);
  var SecPtr := FHLE.Arg(2);
  var UsPtr := FHLE.Arg(3);
  if SecPtr <> 0 then
  begin
    FMemory.Write32(SecPtr, Cardinal(Clock div 1000000));
    if UsPtr <> 0 then
      FMemory.Write32(UsPtr, Cardinal(Clock mod 1000000));
  end
  else if UsPtr <> 0 then
    FMemory.Write32(UsPtr, Cardinal(Clock));
  FHLE.Result(0);
end;

{ Interrupts }

procedure TPSPKernel.hCpuSuspendIntr;
begin
  FHLE.Result(Ord(FCPU.InterruptsEnabled));
  FCPU.InterruptsEnabled := False;
end;

procedure TPSPKernel.hCpuResumeIntr;
begin
  // It is mtic a0, $0: only bit 0 counts.
  FCPU.InterruptsEnabled := (FHLE.Arg(0) and 1) <> 0;
  FHLE.Result(0);
  if FCPU.InterruptsEnabled then
  begin
    if FPendingInts.Count > 0 then
      FCPU.Stop;
    // What became ready while dispatch was held gets the CPU now.
    RequestReschedule;
  end;
end;

procedure TPSPKernel.hIsCpuIntrEnable;
begin
  FHLE.Result(Ord(FCPU.InterruptsEnabled));
end;

procedure TPSPKernel.hIsCpuIntrSuspended;
begin
  FHLE.Result(Ord(FHLE.Arg(0) = 0));
end;

const
  // Interrupts with a sub-interrupt table user code may use.
  PSPSubIntrHosts =[ 25,  30];
  // Interrupts user code may not touch at all, and ones it may only release.
  PSPIntrUserDenied =[ 7,  10,  12,  15.. 20,  22.. 24,  26,  31,  36,  50,  56.. 61,  65];
  PSPIntrRegisterDenied =[ 4,  6,  21];
  // VBlank sub-interrupts the firmware's drivers hold.
  PSPVBlankFirmwareSubs =[ 18.. 20,  24.. 26];

// 0 when the interrupt has a sub-interrupt table this caller may use.
function SubIntrCheck(I, S: Integer; Registering: Boolean): Cardinal;
begin
  if (I < 0) or (I > 66) or (I in PSPIntrUserDenied) or (Registering and (I in PSPIntrRegisterDenied)) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
  if not (I in PSPSubIntrHosts) then
    Exit(SCE_KERNEL_ERROR_NOTFOUND_HANDLER);
  if (S < 0) or (S > 31) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
  Result := 0;
end;

procedure TPSPKernel.hRegisterSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, True);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if (FSubIntr[I, S].Handler <> 0) or ((I = 30) and (S in PSPVBlankFirmwareSubs)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_FOUND_HANDLER);
    Exit;
  end;
  // The upper half of the table is the firmware's.
  if S > 15 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
    Exit;
  end;
  // A null handler is taken but leaves the slot free; an enable made before
  // the handler came stays.
  FSubIntr[I, S].Handler := FHLE.Arg(2);
  FSubIntr[I, S].Arg := FHLE.Arg(3);
  FSubIntr[I, S].GP := FCPU.Ctx.GPR[28];
  FHLE.Result(0);
end;

procedure TPSPKernel.hReleaseSubIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if FSubIntr[I, S].Handler = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOTFOUND_HANDLER);
    Exit;
  end;
  FSubIntr[I, S] := Default(TPSPInterruptHandler);
  FHLE.Result(0);
end;

procedure TPSPKernel.hEnableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FSubIntr[I, S].Enabled := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hDisableSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hSuspendSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), Ord(FSubIntr[I, S].Enabled));
  FSubIntr[I, S].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hResumeSubIntr;
begin
  var I := FHLE.ArgInt(0);
  var S := FHLE.ArgInt(1);
  var Err := SubIntrCheck(I, S, False);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FSubIntr[I, S].Enabled := FHLE.Arg(2) <> 0;
  FHLE.Result(0);
end;

procedure TPSPKernel.hIsSubInterruptOccurred;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterUserSpaceIntrStack;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hQueryIntrHandlerInfo;
begin
  FHLE.Result(0);
end;

// Checks an interrupt number and that something handles it; 0 when it does.
function TPSPKernel.IntrHandlerCheck(I: Integer): Cardinal;
begin
  if (I < 0) or (I > High(FIntrHandlers)) then
    Result := SCE_KERNEL_ERROR_ILLEGAL_INTRCODE
  else if FIntrHandlers[I].Handler = 0 then
    Result := SCE_KERNEL_ERROR_NOTFOUND_HANDLER
  else
    Result := 0;
end;

procedure TPSPKernel.hEnableIntr;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FIntrHandlers[I].Enabled := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hDisableIntr;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FIntrHandlers[I].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterIntrHandler;
begin
  // (intno, no, handler, arg1, arg2)
  var I := FHLE.ArgInt(0);
  if (I < 0) or (I > High(FIntrHandlers)) or (FHLE.Arg(2) = 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_INTRCODE);
    Exit;
  end;
  if FIntrHandlers[I].Handler <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_FOUND_HANDLER);
    Exit;
  end;
  FIntrHandlers[I].Handler := FHLE.Arg(2);
  FIntrHandlers[I].Arg := FHLE.Arg(3);
  FIntrHandlers[I].GP := FCPU.Ctx.GPR[28];
  FIntrHandlers[I].Enabled := False;
  FHLE.Result(0);
end;

procedure TPSPKernel.hReleaseIntrHandler;
begin
  var I := FHLE.ArgInt(0);
  var Err := IntrHandlerCheck(I);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  FIntrHandlers[I] := Default(TPSPInterruptHandler);
  FHLE.Result(0);
end;

{ System memory }

function TPSPKernel.AllocPartitionBlock(PartId: Integer; const Name: string; Kind: Integer; Size, Addr: Cardinal; out Err: Cardinal): Cardinal;
begin
  Result := 0;
  Err := 0;
  var P := Partition(PartId);
  if P = nil then
  begin
    Err := SCE_KERNEL_ERROR_ILLEGAL_PARTITION;
    Exit;
  end;
  if (Kind < 0) or (Kind > 4) then
  begin
    Err := SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE;
    Exit;
  end;
  if (Size = 0) or (Size > $7FFFFFFF) then
  begin
    Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED;
    Exit;
  end;
  case Kind of
    0:
      Result := P.Alloc(Size, akLow, 0, 256, Name);
    1:
      Result := P.Alloc(Size, akHigh, 0, 256, Name);
    2:
      begin
        if (Addr < P.Base) or (Addr - P.Base >= P.Size) then
        begin
          Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED;
          Exit;
        end;
        Result := P.Alloc(Size, akAddress, Addr, 256, Name);
      end;
    3, 4:
      begin
        if (Addr = 0) or ((Addr and (Addr - 1)) <> 0) then
        begin
          Err := SCE_KERNEL_ERROR_ILLEGAL_ALIGNMENT_SIZE;
          Exit;
        end;
        if Kind = 3 then
          Result := P.Alloc(Size, akLow, 0, Addr, Name)
        else
          Result := P.Alloc(Size, akHigh, 0, Addr, Name);
      end;
  end;
  if Result = 0 then
    Err := SCE_KERNEL_ERROR_MEMBLOCK_ALLOC_FAILED;
end;

procedure TPSPKernel.hAllocPartitionMemory;
begin
  var PartId := FHLE.ArgInt(0);
  var NamePtr := FHLE.Arg(1);
  var Kind := FHLE.ArgInt(2);
  var Size := FHLE.Arg(3);
  var Addr := FHLE.Arg(4);
  var KernelCaller := (FCurrent <> nil) and FCurrent.IsKernel;
  if (PartId < 1) or (PartId > 6) then
  begin
    if KernelCaller then
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION)
    else
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  if not KernelCaller and (PartId in [1, 3, 4]) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION);
    Exit;
  end;
  if (Kind < 0) or (Kind > 4) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE);
    Exit;
  end;
  var Name: string;
  if not ReadName(NamePtr, Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Err: Cardinal;
  var A := AllocPartitionBlock(PartId, Name, Kind, Size, Addr, Err);
  if A = 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var B := TPSPMemBlock.Create;
  B.Name := Name;
  B.PartitionId := PartId;
  B.Address := A;
  B.Size := Size;
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hFreePartitionMemory;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  if B = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID);
    Exit;
  end;
  Partition(B.PartitionId).FreeBlock(B.Address);
  DeleteObject(B);
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetBlockHeadAddr;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  if B = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  FHLE.Result(B.Address);
end;

procedure TPSPKernel.hMaxFreeMemSize;
begin
  FHLE.Result(FUserPartition.LargestFree);
end;

procedure TPSPKernel.hTotalFreeMemSize;
begin
  FHLE.Result(FUserPartition.FreeTotal);
end;

procedure TPSPKernel.hTotalMemSize;
begin
  FHLE.Result(FUserPartition.Size);
end;

procedure TPSPKernel.hPartitionTotalFreeMemSize;
begin
  var P := Partition(FHLE.ArgInt(0));
  if P = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION);
    Exit;
  end;
  FHLE.Result(P.FreeTotal);
end;

procedure TPSPKernel.hQueryMemoryInfo;
begin
  // (address, partition id out, block id out)
  var Addr := FHLE.Arg(0);
  for var O in FObjects.Values do
    if (O is TPSPMemBlock) and (Addr >= TPSPMemBlock(O).Address) and (Addr - TPSPMemBlock(O).Address <
      TPSPMemBlock(O).Size) then
    begin
      if FHLE.Arg(1) <> 0 then
        FMemory.Write32(FHLE.Arg(1), Cardinal(TPSPMemBlock(O).PartitionId));
      if FHLE.Arg(2) <> 0 then
        FMemory.Write32(FHLE.Arg(2), O.UID);
      FHLE.Result(0);
      Exit;
    end;
  FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
end;

procedure TPSPKernel.hAllocMemoryBlock;
begin
  // (name, type, size, options): type 0 low, 1 high, in the user partition.
  var Name: string;
  if not ReadName(FHLE.Arg(0), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Kind := FHLE.ArgInt(1);
  if (Kind < 0) or (Kind > 1) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCKTYPE);
    Exit;
  end;
  if (FHLE.Arg(3) <> 0) and (FMemory.Read32(FHLE.Arg(3)) <> 4) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  var Err: Cardinal;
  var A := AllocPartitionBlock(2, Name, Kind, FHLE.Arg(2), 0, Err);
  if A = 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var B := TPSPMemBlock.Create;
  B.Name := Name;
  B.PartitionId := 2;
  B.Address := A;
  B.Size := FHLE.Arg(2);
  FHLE.Result(AddObject(B));
end;

procedure TPSPKernel.hFreeMemoryBlock;
begin
  hFreePartitionMemory;
end;

procedure TPSPKernel.hGetMemoryBlockPtr;
begin
  var B := TPSPMemBlock(GetObject(FHLE.Arg(0), TPSPMemBlock));
  // An unknown block is not reported.
  if B = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), B.Address);
  FHLE.Result(0);
end;

procedure TPSPKernel.hCreateHeap;
begin
  // (partition, size, attr, name)
  var PartId := FHLE.ArgInt(0);
  var Size := FHLE.Arg(1);
  var P := Partition(PartId);
  if P = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_PARTITION);
    Exit;
  end;
  if Integer(Size) <= 0 then
  begin
    FHLE.Result($800200DC);
    Exit;
  end;
  var Name: string;
  if not ReadName(FHLE.Arg(3), Name) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ERROR);
    Exit;
  end;
  var Block := P.Alloc(Size, akLow, 0, 256, 'heap:' + Name);
  if Block = 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  var H := TPSPHeap.Create;
  H.Name := Name;
  H.PartitionId := PartId;
  H.Block := Block;
  H.Size := AlignUp(Size, 256);
  H.Area := TPSPPartition.Create(PartId, Block, H.Size);
  FHLE.Result(AddObject(H));
end;

procedure TPSPKernel.hDeleteHeap;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID);
    Exit;
  end;
  Partition(H.PartitionId).FreeBlock(H.Block);
  DeleteObject(H);
  FHLE.Result(0);
end;

procedure TPSPKernel.hAllocHeapMemory;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
  begin
    FHLE.Result(0);
    Exit;
  end;
  var Size := FHLE.Arg(1);
  if Size > $7FFFFFF0 then
  begin
    FHLE.Result(0);
    Exit;
  end;
  // Even nothing gets a block.
  if Size = 0 then
    Size := 1;
  var A := H.Area.Alloc(Size, akLow, 0, 8, '');
  // The heap grows with more of its partition.
  if A = 0 then
    A := Partition(H.PartitionId).Alloc(Size, akLow, 0, 256, 'heap ext:' + H.Name);
  FHLE.Result(A);
end;

procedure TPSPKernel.hAllocHeapMemoryWithOption;
begin
  // The option is (size, alignment); the alignment is 0 or a power of two
  // from 4 to 128.
  var Opt := FHLE.Arg(2);
  if Opt <> 0 then
  begin
    var Align := FMemory.Read32(Opt + 4);
    if (Align <> 0) and ((Align < 4) or (Align > $80) or ((Align and (Align - 1)) <> 0)) then
    begin
      FHLE.Result(0);
      Exit;
    end;
  end;
  hAllocHeapMemory;
end;

procedure TPSPKernel.hFreeHeapMemory;
begin
  var H := TPSPHeap(GetObject(FHLE.Arg(0), TPSPHeap));
  if H = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_UID);
    Exit;
  end;
  var A := FHLE.Arg(1);
  if H.Area.FreeBlock(A) or Partition(H.PartitionId).FreeBlock(A) then
    FHLE.Result(0)
  else
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_MEMBLOCK);
end;

procedure TPSPKernel.hDevkitVersion;
begin
  FHLE.Result($06060010);
end;

procedure TPSPKernel.hSetCompiledSdkVersion;
begin
  FCompiledSdkVersion := FHLE.Arg(0);
  FSdkVersionSet := True;
  FHLE.Result(0);
end;

procedure TPSPKernel.hGetCompiledSdkVersion;
begin
  FHLE.Result(FCompiledSdkVersion);
end;

procedure TPSPKernel.hSetCompilerVersion;
begin
  FCompilerVersion := FHLE.Arg(0);
  FHLE.Result(0);
end;

// A small printf: %d %i %u %x %X %p %s %c %%, flags 0 - +, width, l/ll ignored.
function GuestFormat(K: TPSPKernel; Fmt: RawByteString; FirstArg: Integer): RawByteString;
begin
  Result := '';
  var ArgIndex := FirstArg;
  var NextArg :=
    function: Cardinal
    begin
      if ArgIndex < 8 then
        Result := K.CPU.Ctx.GPR[4 + ArgIndex]
      else
        Result := K.Memory.Read32(K.CPU.Ctx.GPR[29] + Cardinal(ArgIndex - 8) * 4);
      Inc(ArgIndex);
    end;
  var I := 1;
  while I <= Length(Fmt) do
  begin
    var Ch := Fmt[I];
    if (Ch <> '%') or (I = Length(Fmt)) then
    begin
      Result := Result + Ch;
      Inc(I);
      Continue;
    end;
    Inc(I);
    var Flags: RawByteString := '';
    while (I <= Length(Fmt)) and (Fmt[I] in ['-', '0', '+', ' ', '#']) do
    begin
      Flags := Flags + Fmt[I];
      Inc(I);
    end;
    var Width := 0;
    while (I <= Length(Fmt)) and (Fmt[I] in ['0'..'9']) do
    begin
      Width := Width * 10 + Ord(Fmt[I]) - Ord('0');
      Inc(I);
    end;
    if (I <= Length(Fmt)) and (Fmt[I] = '.') then
    begin
      Inc(I);
      while (I <= Length(Fmt)) and (Fmt[I] in ['0'..'9']) do
        Inc(I);
    end;
    while (I <= Length(Fmt)) and (Fmt[I] in ['l', 'h', 'z']) do
      Inc(I);
    if I > Length(Fmt) then
      Break;
    var Conv := Fmt[I];
    Inc(I);
    var S: RawByteString;
    case Conv of
      'd', 'i':
        S := RawByteString(IntToStr(Integer(NextArg())));
      'u':
        S := RawByteString(UIntToStr(NextArg()));
      'x':
        S := RawByteString(LowerCase(IntToHex(NextArg(), 1)));
      'X':
        S := RawByteString(IntToHex(NextArg(), 1));
      'p':
        S := RawByteString(LowerCase(IntToHex(NextArg(), 8)));
      'c':
        S := AnsiChar(Byte(NextArg()));
      's':
        S := K.Memory.ReadAnsi(NextArg(), 4096);
      '%':
        S := '%';
    else
      S := RawByteString('%') + Conv;
    end;
    var Pad: AnsiChar := ' ';
    if (Pos('0', string(Flags)) > 0) and (Pos('-', string(Flags)) = 0) then
      Pad := '0';
    while Length(S) < Width do
      if Pos('-', string(Flags)) > 0 then
        S := S + ' '
      else
        S := Pad + S;
    Result := Result + S;
  end;
end;

procedure TPSPKernel.hPrintf;
begin
  DebugWrite(GuestFormat(Self, FMemory.ReadAnsi(FHLE.Arg(0), 4096), 1));
  FHLE.Result(0);
end;

procedure TPSPKernel.hExitGame;
begin
  FExited := True;
  if Assigned(FOnExit) then
    FOnExit(0);
  // Nothing else of the game runs.
  for var T in FThreads do
    if T <> FCurrent then
    begin
      RemoveReady(T);
      T.Status := PSPThreadDormant;
    end;
  if FCurrent <> nil then
    FCurrent.Status := PSPThreadDormant;
  FCurrent := nil;
  FIdle := True;
  FCPU.Stop;
  FHLE.Result(0);
end;

procedure TPSPKernel.hRegisterExitCallback;
begin
  var Id := FHLE.Arg(0);
  // Programs built with SDK 3.95 or later have the id checked.
  if (FCompiledSdkVersion >= $03090500) and (GetObject(Id, TPSPCallback) = nil) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  FExitCallback := Id;
  FHLE.Result(0);
end;

procedure TPSPKernel.hCheckExitCallback;
begin
  // LoadExecForUser_362A956B: checks the exit callback's argument block,
  // (kind 0-3, params, common) with the callback's common pointing at its
  // last word, and fills in the params (size >= 12, then two words).
  var CB := TPSPCallback(GetObject(FExitCallback, TPSPCallback));
  if CB = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_CBID);
    Exit;
  end;
  if (CB.Common = 0) or ((CB.Common and $80000000) <> 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  var Arg := CB.Common - 8;
  if FMemory.Read32(Arg) > 3 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ARGUMENT);
    Exit;
  end;
  var Params := FMemory.Read32(Arg + 4);
  if (Params = 0) or ((Params and $80000000) <> 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if FMemory.Read32(Params) < 12 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_SIZE);
    Exit;
  end;
  FMemory.Write32(Params + 4, 0);
  FMemory.Write32(Params + 8, $FFFFFFFF);
  FHLE.Result(0);
end;

{ Volatile memory }

function TPSPKernel.VolatileRetry(T: TPSPThread): Boolean;
begin
  Result := not FVolatileLocked;
  if Result then
  begin
    FVolatileLocked := True;
    if T.Wait.Data[0] <> 0 then
      FMemory.Write32(T.Wait.Data[0], $08400000);
    if T.Wait.Data[1] <> 0 then
      FMemory.Write32(T.Wait.Data[1], $00400000);
    T.SetResult(0);
  end;
end;

procedure TPSPKernel.hVolatileMemLock;
begin
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if RefuseWait then
    Exit;
  if not FVolatileLocked then
  begin
    FVolatileLocked := True;
    if FHLE.Arg(1) <> 0 then
      FMemory.Write32(FHLE.Arg(1), $08400000);
    if FHLE.Arg(2) <> 0 then
      FMemory.Write32(FHLE.Arg(2), $00400000);
    FHLE.Result(0);
    Exit;
  end;
  if not CanWait then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_CAN_NOT_WAIT);
    Exit;
  end;
  FHLE.Result(0);
  FVolatileWaiters.Add(FCurrent);
  BeginWaitData(PSPWaitEventFlag, nil, 0, 0, False, VolatileRetry, [FHLE.Arg(1), FHLE.Arg(2)], nil, 'volatile');
end;

procedure TPSPKernel.hVolatileMemTryLock;
begin
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if FVolatileLocked then
  begin
    FHLE.Result(Cardinal($802B0200));
    Exit;
  end;
  FVolatileLocked := True;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), $08400000);
  if FHLE.Arg(2) <> 0 then
    FMemory.Write32(FHLE.Arg(2), $00400000);
  FHLE.Result(0);
end;

procedure TPSPKernel.hVolatileMemUnlock;
begin
  if FHLE.Arg(0) <> 0 then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_INVALID_MODE);
    Exit;
  end;
  if not FVolatileLocked then
  begin
    FHLE.Result(Cardinal($802B0201));
    Exit;
  end;
  FVolatileLocked := False;
  FHLE.Result(0);
  while FVolatileWaiters.Count > 0 do
  begin
    var T := FVolatileWaiters[0];
    FVolatileWaiters.Delete(0);
    if T.IsWaiting and (T.Wait.HLETag = 'volatile') then
    begin
      VolatileRetry(T);
      EndWait(T, 0);
      Break;
    end;
  end;
end;

procedure TPSPKernel.hReturnZero;
begin
  FHLE.Result(0);
end;

procedure TPSPKernel.hMemcpy;
begin
  var Dst := FHLE.Arg(0);
  var Src := FHLE.Arg(1);
  var N := FHLE.Arg(2);
  if N > 0 then
    FMemory.Copy(Dst, Src, N);
  FHLE.Result(Dst);
end;

procedure TPSPKernel.hMemset;
begin
  var Dst := FHLE.Arg(0);
  var N := FHLE.Arg(2);
  if N > 0 then
    FMemory.Fill(Dst, Byte(FHLE.Arg(1)), N);
  FHLE.Result(Dst);
end;

procedure TPSPKernel.RegisterAll;
const
  T = 'ThreadManForUser';
  K = 'Kernel_Library';
  S = 'SysMemUserForUser';
  I = 'InterruptManager';
begin
  var H := FHLE;
  H.Register(T, $446D8DE6, 'sceKernelCreateThread', hCreateThread);
  H.Register(T, $F475845D, 'sceKernelStartThread', hStartThread);
  H.Register(T, $AA73C935, 'sceKernelExitThread', hExitThread);
  H.Register(T, $532A522E, '_sceKernelExitThread', hExitThread);
  H.Register(T, $809CE29B, 'sceKernelExitDeleteThread', hExitDeleteThread);
  H.Register(T, $9FA03CD3, 'sceKernelDeleteThread', hDeleteThread);
  H.Register(T, $616403BA, 'sceKernelTerminateThread', hTerminateThread);
  H.Register(T, $383F7BCC, 'sceKernelTerminateDeleteThread', hTerminateDeleteThread);
  H.Register(T, $293B45B8, 'sceKernelGetThreadId', hGetThreadId);
  H.Register(T, $94AA61EE, 'sceKernelGetThreadCurrentPriority', hGetThreadCurrentPriority);
  H.Register(T, $71BC9871, 'sceKernelChangeThreadPriority', hChangeThreadPriority);
  H.Register(T, $912354A7, 'sceKernelRotateThreadReadyQueue', hRotateThreadReadyQueue);
  H.Register(T, $17C1684E, 'sceKernelReferThreadStatus', hReferThreadStatus);
  H.Register(T, $FFC36A14, 'sceKernelReferThreadRunStatus', hReferThreadRunStatus);
  H.Register(T, $3B183E26, 'sceKernelGetThreadExitStatus', hGetThreadExitStatus);
  H.Register(T, $9ACE131E, 'sceKernelSleepThread', hSleepThread);
  H.Register(T, $82826F70, 'sceKernelSleepThreadCB', hSleepThreadCB);
  H.Register(T, $D59EAD2F, 'sceKernelWakeupThread', hWakeupThread);
  H.Register(T, $FCCFAD26, 'sceKernelCancelWakeupThread', hCancelWakeupThread);
  H.Register(T, $1AF94D03, 'sceKernelDonateWakeupThread', hDonateWakeupThread);
  H.Register(T, $9944F31F, 'sceKernelSuspendThread', hSuspendThread);
  H.Register(T, $75156E8F, 'sceKernelResumeThread', hResumeThread);
  H.Register(T, $278C0DF5, 'sceKernelWaitThreadEnd', hWaitThreadEnd);
  H.Register(T, $840E8133, 'sceKernelWaitThreadEndCB', hWaitThreadEndCB);
  H.Register(T, $CEADEB47, 'sceKernelDelayThread', hDelayThread);
  H.Register(T, $68DA9E36, 'sceKernelDelayThreadCB', hDelayThreadCB);
  H.Register(T, $BD123D9E, 'sceKernelDelaySysClockThread', hDelaySysClockThread);
  H.Register(T, $1181E963, 'sceKernelDelaySysClockThreadCB', hDelaySysClockThreadCB);
  H.Register(T, $2C34E053, 'sceKernelReleaseWaitThread', hReleaseWaitThread);
  H.Register(T, $52089CA1, 'sceKernelGetThreadStackFreeSize', hGetThreadStackFreeSize);
  H.Register(T, $D13BDE95, 'sceKernelCheckThreadStack', hCheckThreadStack);
  H.Register(T, $BC80EC7C, 'sceKernelExtendThreadStack', hExtendThreadStack);
  H.Register(T, $EA748E31, 'sceKernelChangeCurrentThreadAttr', hChangeCurrentThreadAttr);
  H.Register(T, $57CF62DD, 'sceKernelGetThreadmanIdType', hGetThreadmanIdType);
  H.Register(T, $94416130, 'sceKernelGetThreadmanIdList', hGetThreadmanIdList);
  H.Register(T, $3AD58B8C, 'sceKernelSuspendDispatchThread', hSuspendDispatchThread);
  H.Register(T, $27E22EC2, 'sceKernelResumeDispatchThread', hResumeDispatchThread);
  H.Register(T, $627E6F3A, 'sceKernelReferSystemStatus', hReferSystemStatus);
  H.Register(T, $64D4540E, 'sceKernelReferThreadProfiler', hReferThreadProfiler);
  H.Register(T, $8218B4DD, 'sceKernelReferGlobalProfiler', hReferThreadProfiler);
  H.Register(T, $E81CAF8F, 'sceKernelCreateCallback', hCreateCallback);
  H.Register(T, $EDBA5844, 'sceKernelDeleteCallback', hDeleteCallback);
  H.Register(T, $C11BA8C4, 'sceKernelNotifyCallback', hNotifyCallback);
  H.Register(T, $BA4051D6, 'sceKernelCancelCallback', hCancelCallback);
  H.Register(T, $2A3D44FF, 'sceKernelGetCallbackCount', hGetCallbackCount);
  H.Register(T, $349D6D6C, 'sceKernelCheckCallback', hCheckCallback);
  H.Register(T, $730ED8BC, 'sceKernelReferCallbackStatus', hReferCallbackStatus);
  H.Register(T, $D6DA4BA1, 'sceKernelCreateSema', hCreateSema);
  H.Register(T, $28B6489C, 'sceKernelDeleteSema', hDeleteSema);
  H.Register(T, $3F53E640, 'sceKernelSignalSema', hSignalSema);
  H.Register(T, $4E3A1105, 'sceKernelWaitSema', hWaitSema);
  H.Register(T, $6D212BAC, 'sceKernelWaitSemaCB', hWaitSemaCB);
  H.Register(T, $58B1F937, 'sceKernelPollSema', hPollSema);
  H.Register(T, $8FFDF9A2, 'sceKernelCancelSema', hCancelSema);
  H.Register(T, $BC6FEBC5, 'sceKernelReferSemaStatus', hReferSemaStatus);
  H.Register(T, $55C20A00, 'sceKernelCreateEventFlag', hCreateEventFlag);
  H.Register(T, $EF9E4C70, 'sceKernelDeleteEventFlag', hDeleteEventFlag);
  H.Register(T, $1FB15A32, 'sceKernelSetEventFlag', hSetEventFlag);
  H.Register(T, $812346E4, 'sceKernelClearEventFlag', hClearEventFlag);
  H.Register(T, $402FCF22, 'sceKernelWaitEventFlag', hWaitEventFlag);
  H.Register(T, $328C546A, 'sceKernelWaitEventFlagCB', hWaitEventFlagCB);
  H.Register(T, $30FD48F0, 'sceKernelPollEventFlag', hPollEventFlag);
  H.Register(T, $CD203292, 'sceKernelCancelEventFlag', hCancelEventFlag);
  H.Register(T, $A66B0120, 'sceKernelReferEventFlagStatus', hReferEventFlagStatus);
  H.Register(T, $B7D098C6, 'sceKernelCreateMutex', hCreateMutex);
  H.Register(T, $F8170FBE, 'sceKernelDeleteMutex', hDeleteMutex);
  H.Register(T, $B011B11F, 'sceKernelLockMutex', hLockMutex);
  H.Register(T, $5BF4DD27, 'sceKernelLockMutexCB', hLockMutexCB);
  H.Register(T, $0DDCD2C9, 'sceKernelTryLockMutex', hTryLockMutex);
  H.Register(T, $6B30100F, 'sceKernelUnlockMutex', hUnlockMutex);
  H.Register(T, $87D9223C, 'sceKernelCancelMutex', hCancelMutex);
  H.Register(T, $A9C2CB9A, 'sceKernelReferMutexStatus', hReferMutexStatus);
  H.Register(T, $19CFF145, 'sceKernelCreateLwMutex', hCreateLwMutex);
  H.Register(T, $60107536, 'sceKernelDeleteLwMutex', hDeleteLwMutex);
  H.Register(T, $4C145944, 'sceKernelReferLwMutexStatusByID', hReferLwMutexStatusByID);
  H.Register(T, $7CFF8CF3, '_sceKernelLockLwMutex', hLockLwMutex);
  H.Register(T, $31327F19, '_sceKernelLockLwMutexCB', hLockLwMutexCB);
  H.Register(T, $71040D5C, '_sceKernelTryLockLwMutex', hTryLockLwMutex600);
  H.Register(T, $BEED3A47, '_sceKernelUnlockLwMutex', hUnlockLwMutex);
  H.Register(K, $BEA46419, 'sceKernelLockLwMutex', hLockLwMutex);
  H.Register(K, $1FC64E09, 'sceKernelLockLwMutexCB', hLockLwMutexCB);
  H.Register(K, $DC692EE3, 'sceKernelTryLockLwMutex', hTryLockLwMutex);
  H.Register(K, $37431849, 'sceKernelTryLockLwMutex_600', hTryLockLwMutex600);
  H.Register(K, $15B6446B, 'sceKernelUnlockLwMutex', hUnlockLwMutex);
  H.Register(K, $C1734599, 'sceKernelReferLwMutexStatus', hReferLwMutexStatus);
  H.Register(T, $8125221D, 'sceKernelCreateMbx', hCreateMbx);
  H.Register(T, $86255ADA, 'sceKernelDeleteMbx', hDeleteMbx);
  H.Register(T, $E9B3061E, 'sceKernelSendMbx', hSendMbx);
  H.Register(T, $18260574, 'sceKernelReceiveMbx', hReceiveMbx);
  H.Register(T, $F3986382, 'sceKernelReceiveMbxCB', hReceiveMbxCB);
  H.Register(T, $0D81716A, 'sceKernelPollMbx', hPollMbx);
  H.Register(T, $87D4DD36, 'sceKernelCancelReceiveMbx', hCancelReceiveMbx);
  H.Register(T, $A8E8C846, 'sceKernelReferMbxStatus', hReferMbxStatus);
  H.Register(T, $7C0DC2A0, 'sceKernelCreateMsgPipe', hCreateMsgPipe);
  H.Register(T, $F0B7DA1C, 'sceKernelDeleteMsgPipe', hDeleteMsgPipe);
  H.Register(T, $876DBFAD, 'sceKernelSendMsgPipe', hSendMsgPipe);
  H.Register(T, $7C41F2C2, 'sceKernelSendMsgPipeCB', hSendMsgPipeCB);
  H.Register(T, $884C9F90, 'sceKernelTrySendMsgPipe', hTrySendMsgPipe);
  H.Register(T, $74829B76, 'sceKernelReceiveMsgPipe', hReceiveMsgPipe);
  H.Register(T, $FBFA697D, 'sceKernelReceiveMsgPipeCB', hReceiveMsgPipeCB);
  H.Register(T, $DF52098F, 'sceKernelTryReceiveMsgPipe', hTryReceiveMsgPipe);
  H.Register(T, $349B864D, 'sceKernelCancelMsgPipe', hCancelMsgPipe);
  H.Register(T, $33BE4024, 'sceKernelReferMsgPipeStatus', hReferMsgPipeStatus);
  H.Register(T, $56C039B5, 'sceKernelCreateVpl', hCreateVpl);
  H.Register(T, $89B3D48C, 'sceKernelDeleteVpl', hDeleteVpl);
  H.Register(T, $BED27435, 'sceKernelAllocateVpl', hAllocateVpl);
  H.Register(T, $EC0A693F, 'sceKernelAllocateVplCB', hAllocateVplCB);
  H.Register(T, $AF36D708, 'sceKernelTryAllocateVpl', hTryAllocateVpl);
  H.Register(T, $B736E9FF, 'sceKernelFreeVpl', hFreeVpl);
  H.Register(T, $1D371B8A, 'sceKernelCancelVpl', hCancelVpl);
  H.Register(T, $39810265, 'sceKernelReferVplStatus', hReferVplStatus);
  H.Register(T, $C07BB470, 'sceKernelCreateFpl', hCreateFpl);
  H.Register(T, $ED1410E0, 'sceKernelDeleteFpl', hDeleteFpl);
  H.Register(T, $D979E9BF, 'sceKernelAllocateFpl', hAllocateFpl);
  H.Register(T, $E7282CB6, 'sceKernelAllocateFplCB', hAllocateFplCB);
  H.Register(T, $623AE665, 'sceKernelTryAllocateFpl', hTryAllocateFpl);
  H.Register(T, $F6414A71, 'sceKernelFreeFpl', hFreeFpl);
  H.Register(T, $A8AA591F, 'sceKernelCancelFpl', hCancelFpl);
  H.Register(T, $D8199E4C, 'sceKernelReferFplStatus', hReferFplStatus);
  H.Register(T, $8DAFF657, 'sceKernelCreateTlspl', hCreateTlspl);
  H.Register(T, $32BF938E, 'sceKernelDeleteTlspl', hDeleteTlspl);
  H.Register(T, $65F54FFB, '_sceKernelAllocateTlspl', hAllocateTlspl);
  H.Register(T, $4A719FB2, 'sceKernelFreeTlspl', hFreeTlspl);
  H.Register(T, $721067F3, 'sceKernelReferTlsplStatus', hReferTlsplStatus);
  H.Register(K, $FA835CDE, 'sceKernelGetTlsAddr', hGetTlsAddr);
  H.Register(T, $6652B8CA, 'sceKernelSetAlarm', hSetAlarm);
  H.Register(T, $B2C25152, 'sceKernelSetSysClockAlarm', hSetSysClockAlarm);
  H.Register(T, $7E65B999, 'sceKernelCancelAlarm', hCancelAlarm);
  H.Register(T, $DAA3F564, 'sceKernelReferAlarmStatus', hReferAlarmStatus);
  H.Register(T, $20FFF560, 'sceKernelCreateVTimer', hCreateVTimer);
  H.Register(T, $328F9E52, 'sceKernelDeleteVTimer', hDeleteVTimer);
  H.Register(T, $B3A59970, 'sceKernelGetVTimerBase', hGetVTimerBase);
  H.Register(T, $B7C18B77, 'sceKernelGetVTimerBaseWide', hGetVTimerBaseWide);
  H.Register(T, $034A921F, 'sceKernelGetVTimerTime', hGetVTimerTime);
  H.Register(T, $C0B3FFD2, 'sceKernelGetVTimerTimeWide', hGetVTimerTimeWide);
  H.Register(T, $542AD630, 'sceKernelSetVTimerTime', hSetVTimerTime);
  H.Register(T, $FB6425C3, 'sceKernelSetVTimerTimeWide', hSetVTimerTimeWide);
  H.Register(T, $C68D9437, 'sceKernelStartVTimer', hStartVTimer);
  H.Register(T, $D0AEEE87, 'sceKernelStopVTimer', hStopVTimer);
  H.Register(T, $D8B299AE, 'sceKernelSetVTimerHandler', hSetVTimerHandler);
  H.Register(T, $53B00E9A, 'sceKernelSetVTimerHandlerWide', hSetVTimerHandlerWide);
  H.Register(T, $D2D615EF, 'sceKernelCancelVTimerHandler', hCancelVTimerHandler);
  H.Register(T, $5F32BEAA, 'sceKernelReferVTimerStatus', hReferVTimerStatus);
  H.Register(T, $0C106E53, 'sceKernelRegisterThreadEventHandler', hRegisterThreadEventHandler);
  H.Register(T, $72F3C145, 'sceKernelReleaseThreadEventHandler', hReleaseThreadEventHandler);
  H.Register(T, $369EEB6B, 'sceKernelReferThreadEventHandlerStatus', hReferThreadEventHandlerStatus);
  H.Register(T, $DB738F35, 'sceKernelGetSystemTime', hGetSystemTime);
  H.Register(T, $82BC5777, 'sceKernelGetSystemTimeWide', hGetSystemTimeWide);
  H.Register(T, $369ED59D, 'sceKernelGetSystemTimeLow', hGetSystemTimeLow);
  H.Register(T, $110DEC9A, 'sceKernelUSec2SysClock', hUSec2SysClock);
  H.Register(T, $C8CD158C, 'sceKernelUSec2SysClockWide', hUSec2SysClockWide);
  H.Register(T, $BA6B92E2, 'sceKernelSysClock2USec', hSysClock2USec);
  H.Register(T, $E1619D7C, 'sceKernelSysClock2USecWide', hSysClock2USecWide);
  H.Register(K, $092968F4, 'sceKernelCpuSuspendIntr', hCpuSuspendIntr);
  H.Register(K, $5F10D406, 'sceKernelCpuResumeIntr', hCpuResumeIntr);
  H.Register(K, $3B84732D, 'sceKernelCpuResumeIntrWithSync', hCpuResumeIntr);
  H.Register(K, $B55249D2, 'sceKernelIsCpuIntrEnable', hIsCpuIntrEnable);
  H.Register(K, $47A0B729, 'sceKernelIsCpuIntrSuspended', hIsCpuIntrSuspended);
  H.Register(K, $293B45B8, 'sceKernelGetThreadId', hGetThreadId);
  H.Register(K, $D13BDE95, 'sceKernelCheckThreadStack', hCheckThreadStack);
  H.Register(K, $1839852A, 'sceKernelMemcpy', hMemcpy);
  H.Register(K, $A089ECA4, 'sceKernelMemset', hMemset);
  H.Register(I, $CA04A2B9, 'sceKernelRegisterSubIntrHandler', hRegisterSubIntrHandler);
  H.Register(I, $D61E6961, 'sceKernelReleaseSubIntrHandler', hReleaseSubIntrHandler);
  H.Register(I, $FB8E22EC, 'sceKernelEnableSubIntr', hEnableSubIntr);
  H.Register(I, $8A389411, 'sceKernelDisableSubIntr', hDisableSubIntr);
  H.Register(I, $5CB5A78B, 'sceKernelSuspendSubIntr', hSuspendSubIntr);
  H.Register(I, $7860E0DC, 'sceKernelResumeSubIntr', hResumeSubIntr);
  H.Register(I, $FC4374B8, 'sceKernelIsSubInterruptOccurred', hIsSubInterruptOccurred);
  H.Register(I, $EEE43F47, 'sceKernelRegisterUserSpaceIntrStack', hRegisterUserSpaceIntrStack);
  H.Register(I, $D2E8363F, 'QueryIntrHandlerInfo', hQueryIntrHandlerInfo);
  H.Register(S, $237DBD4F, 'sceKernelAllocPartitionMemory', hAllocPartitionMemory);
  H.Register(S, $B6D61D02, 'sceKernelFreePartitionMemory', hFreePartitionMemory);
  H.Register(S, $9D9A5BA1, 'sceKernelGetBlockHeadAddr', hGetBlockHeadAddr);
  H.Register(S, $A291F107, 'sceKernelMaxFreeMemSize', hMaxFreeMemSize);
  H.Register(S, $F919F628, 'sceKernelTotalFreeMemSize', hTotalFreeMemSize);
  H.Register(S, $ACBD88CA, 'sceKernelTotalMemSize', hTotalMemSize);
  H.Register(S, $2A3E5280, 'sceKernelQueryMemoryInfo', hQueryMemoryInfo);
  H.Register(S, $FE707FDF, 'sceKernelAllocMemoryBlock', hAllocMemoryBlock);
  H.Register(S, $50F61D8A, 'sceKernelFreeMemoryBlock', hFreeMemoryBlock);
  H.Register(S, $DB83A952, 'sceKernelGetMemoryBlockPtr', hGetMemoryBlockPtr);
  H.Register(S, $3FC9AE6A, 'sceKernelDevkitVersion', hDevkitVersion);
  H.Register(S, $7591C7DB, 'sceKernelSetCompiledSdkVersion', hSetCompiledSdkVersion);
  H.Register(S, $FC114573, 'sceKernelGetCompiledSdkVersion', hGetCompiledSdkVersion);
  H.Register(S, $F77D77CB, 'sceKernelSetCompilerVersion', hSetCompilerVersion);
  H.Register(S, $13A5ABEF, 'sceKernelPrintf', hPrintf);
  for var NID in [Cardinal($342061E5), $315AD3A0, $EBD5C3E6, $057E7380, $91DE343C, $7893F79A, $35669D4C, $1B4217BC, $358CA1BB] do
    H.Register(S, NID, Format('sceKernelSetCompiledSdkVersion_%.8X', [NID]), hSetCompiledSdkVersion);
  H.Register('LoadExecForUser', $05572A5F, 'sceKernelExitGame', hExitGame);
  H.Register('LoadExecForUser', $2AC9954B, 'sceKernelExitGameWithStatus', hExitGame);
  H.Register('LoadExecForUser', $4AC57943, 'sceKernelRegisterExitCallback', hRegisterExitCallback);
  H.Register('LoadExecForUser', $362A956B, 'LoadExecForUser_362A956B', hCheckExitCallback);
  H.Register('LoadExecForKernel', $05572A5F, 'sceKernelExitGame', hExitGame);
  H.Register('sceSuspendForUser', $3E0271D3, 'sceKernelVolatileMemLock', hVolatileMemLock);
  H.Register('sceSuspendForUser', $A14F40B2, 'sceKernelVolatileMemTryLock', hVolatileMemTryLock);
  H.Register('sceSuspendForUser', $A569E425, 'sceKernelVolatileMemUnlock', hVolatileMemUnlock);
  H.Register('sceSuspendForUser', $EADB1BD7, 'sceKernelPowerLock', hReturnZero);
  H.Register('sceSuspendForUser', $3AEE7261, 'sceKernelPowerUnlock', hReturnZero);
  H.Register('sceSuspendForUser', $090CCB3F, 'sceKernelPowerTick', hReturnZero);
  RegisterKernelAliases;
end;

const
  PSPIoForwardNids: array[0..16] of Cardinal = ($109F50BC, $810C4BC3, $6A638D83, $42EC03AC, $27EB27B8, $68963324,
    $63632449, $54F5FB11, $B29DDF9C, $E3EB004C, $EB092469, $F27A9C51, $06A70004, $1117C65F, $779103A0, $ACE946E8,
    $B8A740F4);
  PSPIoForwardNames: array[0..16] of string = ('sceIoOpen', 'sceIoClose', 'sceIoRead', 'sceIoWrite', 'sceIoLseek',
    'sceIoLseek32', 'sceIoIoctl', 'sceIoDevctl', 'sceIoDopen', 'sceIoDread', 'sceIoDclose', 'sceIoRemove', 'sceIoMkdir',
    'sceIoRmdir', 'sceIoRename', 'sceIoGetstat', 'sceIoChstat');

// Kernel modules reach the file calls through IoFileMgrForKernel: the same
// calls as the user library, looked up when made.
procedure TPSPKernel.hIoForKernel;
begin
  var Name := FHLE.CurrentName;
  for var I := 0 to High(PSPIoForwardNames) do
    if PSPIoForwardNames[I] = Name then
    begin
      var F := FHLE.FunctionInfo(FHLE.Find('IoFileMgrForUser', PSPIoForwardNids[I]));
      if (F <> nil) and Assigned(F.Handler) then
        F.Handler()
      else
        FHLE.Unimplemented('IoFileMgrForKernel ' + Name);
      Exit;
    end;
  FHLE.Unimplemented('IoFileMgrForKernel ' + Name);
end;

procedure TPSPKernel.RegisterKernelAliases;
const
  TK = 'ThreadManForKernel';
  SK = 'SysMemForKernel';
  IK = 'InterruptManagerForKernel';
begin
  for var I := 0 to High(PSPIoForwardNids) do
    FHLE.Register('IoFileMgrForKernel', PSPIoForwardNids[I], PSPIoForwardNames[I], hIoForKernel);
  // Kernel modules import the same calls from the *ForKernel libraries.
  var H := FHLE;
  for var N in [Cardinal($446D8DE6), $F475845D, $AA73C935, $809CE29B, $9FA03CD3, $616403BA, $383F7BCC, $293B45B8, $94AA61EE, $71BC9871, $912354A7, $17C1684E, $FFC36A14, $3B183E26, $9ACE131E, $82826F70, $D59EAD2F, $FCCFAD26, $9944F31F, $75156E8F, $278C0DF5, $840E8133, $CEADEB47, $68DA9E36, $2C34E053, $52089CA1, $D13BDE95, $57CF62DD, $94416130, $3AD58B8C, $27E22EC2, $E81CAF8F, $EDBA5844, $C11BA8C4, $BA4051D6, $2A3D44FF, $349D6D6C, $D6DA4BA1, $28B6489C, $3F53E640, $4E3A1105, $6D212BAC, $58B1F937, $8FFDF9A2,
    $BC6FEBC5, $55C20A00, $EF9E4C70, $1FB15A32, $812346E4, $402FCF22, $328C546A, $30FD48F0, $CD203292, $A66B0120, $B7D098C6, $F8170FBE, $B011B11F, $5BF4DD27, $0DDCD2C9, $6B30100F, $87D9223C, $A9C2CB9A, $DB738F35, $82BC5777, $369ED59D, $110DEC9A, $C8CD158C, $BA6B92E2, $E1619D7C, $6652B8CA, $7E65B999, $8DAFF657, $32BF938E, $65F54FFB, $4A719FB2, $721067F3, $56C039B5, $89B3D48C, $BED27435, $AF36D708, $B736E9FF, $C07BB470, $ED1410E0, $D979E9BF, $623AE665, $F6414A71] do
  begin
    var Index := H.Find('ThreadManForUser', N);
    if Index >= 0 then
    begin
      var F := H.FunctionInfo(Index);
      H.Register(TK, N, F.Name, F.Handler);
    end;
  end;
  H.Register(TK, $FA835CDE, 'sceKernelGetTlsAddr', hGetTlsAddr);
  H.Register(SK, $237DBD4F, 'sceKernelAllocPartitionMemory', hAllocPartitionMemory);
  H.Register(SK, $B6D61D02, 'sceKernelFreePartitionMemory', hFreePartitionMemory);
  H.Register(SK, $9D9A5BA1, 'sceKernelGetBlockHeadAddr', hGetBlockHeadAddr);
  H.Register(SK, $9697CD32, 'sceKernelPartitionTotalFreeMemSize', hPartitionTotalFreeMemSize);
  H.Register(SK, $1C1FBFE7, 'sceKernelCreateHeap', hCreateHeap);
  H.Register(SK, $C9805775, 'sceKernelDeleteHeap', hDeleteHeap);
  H.Register(SK, $636C953B, 'sceKernelAllocHeapMemory', hAllocHeapMemory);
  H.Register(SK, $EB7A74DB, 'sceKernelAllocHeapMemoryWithOption', hAllocHeapMemoryWithOption);
  H.Register(SK, $7B749390, 'sceKernelFreeHeapMemory', hFreeHeapMemory);
  H.Register(IK, $092968F4, 'sceKernelCpuSuspendIntr', hCpuSuspendIntr);
  H.Register(IK, $5F10D406, 'sceKernelCpuResumeIntr', hCpuResumeIntr);
  H.Register(IK, $4D6E7305, 'sceKernelEnableIntr', hEnableIntr);
  H.Register(IK, $D774BA45, 'sceKernelDisableIntr', hDisableIntr);
  H.Register(IK, $58DD8978, 'sceKernelRegisterIntrHandler', hRegisterIntrHandler);
  H.Register(IK, $F987B1F0, 'sceKernelReleaseIntrHandler', hReleaseIntrHandler);
end;

procedure RegisterPSPKernelStateTypes(Schema: TPSPGraphSchema);
begin
  Schema.AddClass(TPSPMbx, []);
  Schema.AddClass(TPSPMsgPipe, []);
  Schema.AddClass(TPSPMutex, []);
  Schema.AddClass(TPSPLwMutex, []);
  Schema.AddClass(TPSPVpl, []);
  Schema.AddClass(TPSPFpl, []);
  Schema.AddClass(TPSPTlspl, []);
  Schema.AddClass(TPSPMemBlock, []);
  Schema.AddClass(TPSPHeap, []);
  Schema.AddClass(TPSPAlarm, []);
  Schema.AddClass(TPSPVTimer, []);
  Schema.AddClass(TPSPThreadEventHandler, []);
  Schema.Optional(TPSPThreadEventHandler, ['GP']);
  Schema.Optional(TPSPKernel, ['FThreadEvents']);
  Schema.Optional(TPSPThread, ['EventWorker']);
end;

function TPSPKernel.DescribeStateTimers: string;
begin
  Result := '';
  for var T in FTimers do
    if Assigned(T.Event) then
    begin
      var Owner := 'none';
      if T.Owner <> nil then
        Owner := T.Owner.ClassName;
      var Callback := T.Event as TObject;
      Result := Result + Format(' [%s: %s, due %d ns]', [Owner, Callback.ClassName, T.At - FScheduler.Now]);
    end;
end;

end.

