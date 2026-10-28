unit N64.Console;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Math, System.Classes, System.SyncObjs,
  System.Diagnostics, System.UITypes, N64.Types, N64.CPU, N64.RSP, N64.RDP,
  N64.RDPWorker, N64.VI, N64.Timing, N64.Host, N64.SoftFloat, Core.Snapshots,
  Core.Emulation.Types;

type
  TN64SaveType = (Auto, EEPROM4K, EEPROM16K, SRAM, FlashRAM, None);

  // Threaded: the RDP draws on a worker thread (N64.RDPWorker). Synchronous:
  // it draws inside DP command processing. Verify: threaded, but every list
  // is waited for and its timing results compared. Stress: threaded, with
  // random stalls of both threads. All four give the same emulation.
  TN64RDPMode = (Threaded, Synchronous, Verify, Stress);

  // What a run-ahead window assumed for a journal entry, checked in its
  // clock: for a deferred DPC_END write, where its list starts (CURRENT, or
  // START if pending) and whether XBUS was set; for a deferred DMA start,
  // whether a transfer was active and one queued (the queue then ignores
  // it); for lifted fences, the SP DMA transfers completed by then.
  // (For a DMA start, From and RAM are the SP and RDRAM addresses it uses.)
  // For a DPC_END write with XBUS, the list's XBusCount bytes in DMEM as the
  // RDP reads them then, from XBusAt of the window's copies (none if 0).
  TN64RSPNote = record
    From, RAM: Cardinal;
    XBus, Busy, Full: Boolean;
    Serial: Int64;
    XBusAt, XBusCount: Integer;
  end;

  // An SP DMA beat into DMEM while the RSP ran ahead: its eight bytes from
  // Local (wrapping in DMEM), after Position of the window's clocks, and
  // the bytes it replaced if it wrote them (Applied; else the window had).
  // Unsaved: the window had not saved the line yet, so its saved copy may
  // hold this beat's bytes (a window on the RSP thread saves lines as the
  // beats come).
  TN64RSPBeat = record
    Position: Integer;
    local: Cardinal;
    Data, Old: array[0..7] of Byte;
    Applied, Unsaved: Boolean;
  end;

  TN64CycleCount = Int64;

  // A field for the VI thread (TN64Console.FVISlots).
  TN64VISlot = record
    Bus: TN64Bus;
    Start, Done: TEvent;
    Registers: array[0..13] of Cardinal;
    Frame: UInt64;
    Notify: Boolean;
    Output: TEmulatorFrame;
    Error: string;
  end;

  // The emulation thread's waits for the other threads (diagnostics,
  // TStopwatch ticks): the RDP bands (since the RDP worker last started)
  // and the VI thread. Its waits for the RSP thread are in
  // TN64RSPAheadStats.ThreadWaitTime.
  TN64WaitStats = record
    RDP, VI: Int64;
    // Fields whose freshly drawn lines the RDP bands copied for the VI
    // thread (RenderFrame).
    VICopies: Int64;
  end;

  // RSP run-ahead counts since the console was created (diagnostics).
  TN64RSPAheadStats = record
    // Windows run and their clocks; MFC0s run ahead with a predicted value,
    // and those whose value turned out different (rewound and run again);
    // windows a CPU access cut short, and the clocks they had run past it.
    Windows, Clocks, Predictions, Mispredictions, Cuts, CutClocks: Int64;
    // MTC0s run ahead and applied in their own clock.
    Deferred: Int64;
    // Fences lifted before their DMA was done; those whose DMA was not
    // complete by then after all; beats into DMEM whose RDRAM bytes changed
    // after they were read in advance.
    Lifts, LiftsWrong, BeatsChanged: Int64;
    // Windows run on the RSP thread, and the times this thread waited for
    // it.
    ThreadWindows, ThreadWaits: Int64;
    // Time (TStopwatch ticks) windows ran (on the RSP thread or here), and
    // this thread waited for the RSP thread.
    WindowTime, ThreadWaitTime: Int64;
    // The RSP thread's own CPU time in windows (QueryThreadCycleTime units,
    // Windows only; 0 elsewhere).
    ThreadCycles: TN64CycleCount;
    // Windows by how they ended (TRSPAheadStop).
    Stops: array[TRSPAheadStop] of Int64;
    // Windows ended by an MTC0 or MFC0, by SP/DP register.
    StopWrites, StopReads: array[0..15] of Int64;
    // Windows ended at a fence: [read 1 / write 2, SP DMA done by then].
    FenceStops: array[1..2, Boolean] of Int64;
    // [read 1 / write 2, source: in 1, out 2, XBUS 4 (or several)].
    FenceSources: array[1..2, 0..7] of Int64;
  end;

  TN64Pad = record
    Buttons: Word;
    StickX, StickY: ShortInt;
    Connected: Boolean;
  end;

  TN64Pads = array[0..3] of TN64Pad;

  TN64SPTransfer = record
    Active, Writing: Boolean;
    local, RAM, Size, Blocks, Skip, Position, Control: Cardinal;
  end;

  // An SP DMA transfer as a run-ahead window models it: Transfer as it is
  // when the window starts or starts it, Serial the count of completed
  // transfers once it completes, LastBeat when its last beat is due and
  // BeatFirst whether a beat precedes an RSP clock due with it. Lifted: the
  // window no longer keeps off its DMEM bytes, which Data holds in beat
  // order (into DMEM: read from RDRAM in advance and written by the window,
  // each beat checks RDRAM still holds them; out of DMEM: taken in advance,
  // the beats send them); Taken: the bytes the beats have had.
  // State: 0 free, 1 a beat of it is being run (emulation thread), 3 being
  // lifted, 2 lifted (by the thread running the window; the beats then use
  // Data). Beats: the beats run of it since Transfer's view; Data covers
  // those from DataFirst on (the ones not run when it was lifted).
  TN64RSPTransfer = record
    Transfer: TN64SPTransfer;
    Serial: Int64;
    LastBeat: UInt64;
    BeatFirst: Boolean;
    State, Beats, DataFirst: Integer;
    Data: TBytes;
  end;

  TN64PITransfer = record
    Active, Writing, Flash, FirstBlock: Boolean;
    RAM, Cart, Length, Position: Cardinal;
    FlashMode: Integer;
    FlashStatus: UInt64;
    BlockRAM, BlockLength, BlockRead, BlockWriteSize, BlockWritten: Cardinal;
    MaxBlockSize, Stage, Latency, PulseWidth, PageSize, ReleaseDuration, ClockPhase: Cardinal;
    Buffer: array[0..127] of Byte;
  end;

  TN64SITransfer = record
    Active, Writing: Boolean;
    RAM, Position: Cardinal;
    Data: array[0..63] of Byte;
  end;

  // A frame as rendered (TN64Console.OnFrame).
  TN64FrameNotify = reference to procedure(const Frame: TEmulatorFrame);

  TN64Console = class(TN64Bus)
  private
    const
    // Run-ahead window sizes in RSP clocks (StartRSPAhead): the largest
    // bounds the cost of one rewind.
      RSPWindowMin = 16;
      RSPWindowMax = 65536;
    // Windows run on the RSP thread once the last one had this many clocks
    // (shorter ones cost more to hand over than they save); the thread
    // publishes its clocks in parts of AheadPart. A 256-clock part keeps
    // the CPU/audio producer from waiting for a whole 1024-clock chunk in
    // busy scenes, without the block lookup overhead of 64-clock parts.
    // Real-time audio lets workers sleep between bursts. Keep short jobs
    // local: repeatedly waking the RSP thread costs more than these jobs.
      RSPThreadMin = 1024;
      AheadPart = 256;
    // SP DMA transfers one window may know of (the list never grows, so the
    // beats may read it while the window runs on another thread).
      RSPMaxTransfers = 4096;
    // Spins of the RSP handshake before a thread sleeps (the RSP thread for a
    // window, the emulation thread for its clocks). Short: a spinning thread
    // takes from the other one where both share a core (SMT), and they wait
    // for each other.
      SpinRounds = 1000;
  private
    type
    // Runs the windows the emulation thread requests (RunThreadedWindow).
      TRSPThread = class(TThread)
      private
        FOwner: TN64Console;
        FCPUs: TN64CPUSet;
        FPreferred: Integer;
      protected
        procedure Execute; override;
      public
        constructor Create(Owner: TN64Console; const CPUs: TN64CPUSet; Preferred: Integer);
      end;

    // Renders the VI fields RenderFrame hands it (VIThreaded).
      TVIThread = class(TThread)
      private
        FOwner: TN64Console;
      protected
        procedure Execute; override;
      public
        constructor Create(Owner: TN64Console);
      end;
  private
    FData, FPIF, FSave: TBytes;
    // VI fields rendered on a thread of their own (VIThreaded), in two slots
    // in turn: as a field ends, its registers go to the VI thread with the
    // RDRAM it reads copied to the slot's Bus; Start is set once that copy is
    // made, Done once the field is rendered. The VI (its noise and weave) is
    // the VI thread's until WaitVI. FVIBusy[S]: slot S is queued and not yet
    // waited for; FVIPut: the slot of the next field (the older one).
    FVIThreaded: Boolean;
    FVIBusy: array[0..1] of Boolean;
    FVIPut: Integer;
    FHostFloat: Boolean;
    FVIThread: TVIThread;
    FVISlots: array[0..1] of TN64VISlot;
    FOnFrame: TN64FrameNotify;
    // (WaitStats.VI, VICopies.)
    FVIWaitTime, FVICopies: Int64;
    FReg: array[0..7, 0..15] of Cardinal;
    FCPU: TN64CPU;
    FRSP: TN64RSP;
    FRDP: TN64RDP;
    // With a worker, FRDPTiming (a timing RDP) runs each list here for its
    // results and FRDP draws it on the worker. FRDPTimingStale: FRDP ran a
    // list itself, FRDPTiming must copy its state before the next one.
    FRDPTiming: TN64RDP;
    FRDPWorker: TN64RDPWorker;
    FRDPMode: TN64RDPMode;
    FRDPBands: Integer;
    FAdaptiveRDP: Boolean;
    FMaxRDPBands, FRDPBusyFields, FRDPQuietFields, FRDPThreadChanges: Integer;
    FRDPTuneWait: Int64;
    FRDPTimingStale: Boolean;
    // Queued lists run lazily on FRDPTiming (TN64RDP.Lazy). FRDPFollow trails
    // it by the latest list (FRDPLastWords, FRDPLastCount; FRDPLastPending: not
    // run yet) and gives that list's exact clocks where they are used
    // (ResolveRDPClocks). FRDPFollowStale: copy FRDPTiming's state first.
    FRDPFollow: TN64RDP;
    FRDPLastWords: TArray<Cardinal>;
    FRDPLastCount: Integer;
    FRDPLastPending, FRDPFollowStale: Boolean;
    // Diagnostics: False runs only the timing RDP (no pixels drawn).
    FRDPDrawing: Boolean;
    // UseRecompiler as last set (the CPU and the RSP give up generated code
    // they cannot make: not asked again until it changes).
    FUseRecompiler: Boolean;
    // Thread placement (see PlaceThreads): enabled, and the emulation thread
    // pinned (FPinnedThread) with what it could run on before.
    FPlacement, FPinned: Boolean;
    FPinnedThread: TThreadID;
    FUnpinned: TN64CPUSet;
    // The host's cores as first found, and where the RDP bands (and the VI
    // thread) run once placed.
    FCores: TArray<TN64HostCore>;
    FCoresFound: Boolean;
    FBandCPUs: TN64CPUSet;
    FHintAttempted, FHinted: Boolean;
    FPreviousIdeal: Integer;
    FHintedThread: TThreadID;
    FVI: TN64VI;
    FTimeline: TN64Timeline;
    FSPTransfer, FSPQueued: TN64SPTransfer;
    FPITransfer: TN64PITransfer;
    FSITransfer: TN64SITransfer;
    FPendingSPAddress, FPendingRAMAddress: Cardinal;
    FVIPhase, FAIDACPhase: UInt64;
    FAIAnchorTick: UInt64;
    FRSPPhase: Integer;
    // RSP run-ahead (see StartRSPAhead) and its test mode, which rewinds
    // the RSP at random instruction boundaries.
    FRSPAhead, FRSPStress: Boolean;
    FRSPNoise: Cardinal;
    // Clocks the next run-ahead window may take: halved towards the clocks
    // actually kept when the CPU cut a window short, doubled after a window
    // that was not (host heuristic; any size is exact).
    FRSPWindow: Integer;
    FRSPCut: Boolean;
    // The window being run ahead: FRSPRun clocks (0: none), of which the
    // first FRSPCommitted are handled. The timeline handles FRSPSegment
    // clocks after those, up to the next clock with a journal entry not
    // settled (FRSPNextCheck, see SettledRSPEntry); that clock comes as an
    // ordinary RSP clock event, which checks it. FRSPFirstDue: when the
    // window's first clock is due. The settled writes among the entries
    // before FRSPNextCheck from FRSPApplied on (FRSPSettledWrites of them)
    // are still to be applied (ApplySettledRSPWrites). FRSPMustHold: a
    // settled entry the test mode checks all the same.
    FRSPRun, FRSPCommitted, FRSPSegment, FRSPNextCheck, FRSPApplied, FRSPSettledWrites, FRSPMustHold: Integer;
    FRSPFirstDue: UInt64;
    // SP DMA transfers completed (host side, for the window's checks), and
    // how many when the window started.
    FSPDone, FRSPDoneBase: Int64;
    // A deferred write is being applied.
    FRSPApplying: Boolean;
    // When the CPU batch being run started (SyncDevice).
    FBatchStart: UInt64;
    // While a deferred kick is applied: the list's copy (FXBusCount bytes of
    // FRSPXBusData from FXBusAt) holds DMEM from FXBusStart on, for the RDP.
    FXBusAt, FXBusCount: Integer;
    FXBusStart: Cardinal;
    // By journal entry: what the window assumed (see TN64RSPNote).
    FRSPNotes: TArray<TN64RSPNote>;
    // What the window's callbacks know of the queued DP interrupt and RSP
    // clock when it starts (nothing else moves the timeline meanwhile).
    FRSPDP, FRSPFirstClock: TN64Event;
    FRSPHasDP, FRSPHasFirstClock: Boolean;
    // The RSP's journal (allocated once by it), read here without touching
    // the RSP's own fields.
    FRSPJournal: PRSPJournal;
    // A window run on the RSP thread (RSPThreaded): in flight while
    // FRSPInFlight, the timeline taking its clocks as they are published
    // (AdvanceThreadedWindow). FRSPLastWindow: the last window's clocks.
    FRSPThreaded, FRSPInFlight: Boolean;
    FRSPLastWindow: Integer;
    FRSPThread: TRSPThread;
    FRSPWake, FRSPProgress: TEvent;
  protected
    // The window's own state, which its callbacks change while it runs (on
    // the RSP thread, apart from what this thread writes).
    FWindowPad0: array[0..7] of Int64;
  private
    // The SP and DP registers (as RSPRegister) as the window's clocks will
    // find them: from the state at its start, its own deferred writes up to
    // journal entry FRSPShadowPos, and the RDP assumed to run each list it
    // kicks to the end without a Full Sync (checked like any prediction).
    FRSPShadow: array[0..15] of Cardinal;
    FRSPShadowPos: Integer;
    // The SP DMA transfers the window's clocks find, in order (FRSPDMACount
    // used; while there are any, SP_MEM/DRAM_ADDR and the lengths are not
    // predicted), the first FRSPLifted of them lifted, and the addresses for
    // the next one.
    FRSPDMAs: TArray<TN64RSPTransfer>;
    // FRSPFirstPending: those before it are complete at every clock asked
    // about since (the window asks in clock order).
    FRSPDMACount, FRSPLifted, FRSPFirstPending: Integer;
    // During LiftRSPTransfer: the lifted transfers out of DMEM whose RDRAM
    // bytes may overlap the transfer's (FRSPOverlapCount used).
    FRSPOverlap: TArray<Integer>;
    FRSPOverlapCount: Integer;
    // Which fences a window may lift (RSPLiftMode).
    FRSPLiftMode: Integer;
    FRSPDMAPending: array[0..1] of Cardinal;
    // The window's fences for RDP lists kicked with XBUS: offset and count
    // pairs (FRSPXBusCount pairs used).
    FRSPXBus: TArray<Cardinal>;
    FRSPXBusCount: Integer;
    // Copies of RDP lists kicked with XBUS (FRSPXBusUsed bytes used; never
    // grown, so they can be read while the window runs on).
    FRSPXBusData: TBytes;
    FRSPXBusUsed: Integer;
    FRSPWorkerNoise: Cardinal;
    // Fences the window lifted (added to FRSPStats as it ends).
    FRSPWindowLifts: Int64;
  protected
    // The handshake with the RSP thread, each side's fields on their own
    // cache lines.
    FAheadPad0: array[0..7] of Int64;
  private
    // Written by the emulation thread.
    [Volatile]
    FAheadRequest: Int64;
    FAheadBudget: Integer;
    FAheadStatus, FAheadPC: Cardinal;
    [Volatile]
    FAheadStopRequest: Integer;
    [Volatile]
    FAheadMainWaiting: Integer;
  protected
    FAheadPad1: array[0..7] of Int64;
  private
    // Written by the RSP thread: the clocks (high half) and journal entries
    // (low half) published, the request finished, where the RSP ended.
    [Volatile]
    FAheadProgress: Int64;
    [Volatile]
    FAheadFinished: Int64;
    FAheadPCOut: Cardinal;
    FAheadError: string;
    [Volatile]
    FAheadWorkerSleeping: Integer;
  protected
    FAheadPad2: array[0..7] of Int64;
  private
    // The SP DMA beats into DMEM since the window started (FRSPBeatCount
    // used): a rewind replays the window's clocks with them in place.
    FRSPBeats: TArray<TN64RSPBeat>;
    FRSPBeatCount: Integer;
    // (RewindRSPTo: the beats' positions.)
    FRSPStops: TArray<Integer>;
    FRSPStats: TN64RSPAheadStats;
    FLastLeft, FLastRight: SmallInt;
    FCurrentFrame: TEmulatorFrame;
    FVideoOutputEnabled: Boolean;
    FFrame: UInt64;
    FTick, FLine, FField: Integer;
    FSPPC: Cardinal;
    FInputs: TN64Pads;
    // The samples since TakeSamples: the first FSampleCount of FSample (kept
    // from frame to frame, as no memory manager call is made for each).
    FSample: TArray<SmallInt>;
    FSampleCount: Integer;
    FAIAddress, FAILength, FAIProgress, FAIPhase: Cardinal;
    FAINextAddress, FAINextLength: Cardinal;
    FAudioClock: Integer;
    FAIDACRemainder: Cardinal;
    FSaveDirty: Boolean;
    FSaveType: TN64SaveType;
    FDetectedSaveType: TN64SaveType;
    FFlashData: array[0..$1FFFF] of Byte;
    FFlashBuffer: array[0..127] of Byte;
    FFlashUsed, FFlashReady: Boolean;
    FFlashMode: Integer;
    FFlashOffset: Cardinal;
    FFlashStatus: UInt64;
    FDebugOutput: string;
    FDebugBuffer: array[0..511] of Byte;
    procedure SetInterrupts(Value: Cardinal);
    procedure UpdateInterruptLine;
    procedure AppendDebugOutput(Count: Cardinal);
    procedure SPDMA(Writing: Boolean; Value: Cardinal);
    procedure MarkSPTransfer(const Transfer: TN64SPTransfer; Number: Int64);
    procedure MarkSPTransfers;
    procedure PIDMA(Writing: Boolean; Value: Cardinal);
    procedure SIDMA(Writing: Boolean);
    procedure PIFCommand;
    procedure ReadPIFControllers;
    procedure CICChallenge;
    procedure FormatControllerPaks;
    procedure AudioTick;
    procedure ProcessRDP;
    function QueueRDP(out Consumed: Cardinal): Boolean;
    procedure ResolveRDPClocks;
    procedure DrainRDP;
    procedure RefreshRDP;
    procedure SetRDPMode(Value: TN64RDPMode);
    procedure SetRDPThreads(Value: Integer);
    procedure ResizeRDPThreads(Value: Integer);
    procedure SetRDPDrawing(Value: Boolean);
    procedure SetBilinearFiltering(Value: Boolean);
    function GetBilinearFiltering: Boolean;
    procedure SetUseRecompiler(Value: Boolean);
    function GetUseRecompiler: Boolean;
    procedure PlaceThreads(out BandCPUs: TN64CPUSet; out Preferred: TArray<Integer>);
    procedure UnplaceThreads;
    procedure SetPlacement(Value: Boolean);
    function GetRenderer: TN64RDP;
    procedure RunRSP;
    procedure FlashCommand(Value: Cardinal);
    function EEPROMSize: Integer;
    function HasFlash: Boolean;
    function VideoClock: Cardinal;
    procedure AdvanceTime(Cycles: Cardinal); inline;
    procedure ProcessEvents(Target: UInt64);
    class procedure RaiseClockOverflow; static;
    function RunIdle(Budget: Integer): Integer;
    procedure HandleEvent(Kind: TN64EventKind);
    procedure ScheduleVI;
    procedure ScheduleOutput;
    procedure ScheduleAI;
    procedure ScheduleRSP;
    procedure StartRSPAhead;
    procedure SyncRSP; inline;
    procedure RewindRSP;
    procedure FoldRSPPhase;
    procedure StressRSP;
    function StressNoise: Cardinal;
    function WindowNoise: Cardinal;
    procedure CountWindow(Clocks: Integer);
    procedure BeginThreadedWindow;
    procedure RunThreadedWindow;
    procedure PublishAhead(Clocks: Integer);
    function AdvanceThreadedWindow: Boolean;
    procedure WaitAhead(Need: Integer);
    procedure StopAhead;
    procedure EndThreadedWindow;
    function RacyRAM8(Address: Cardinal): Byte; inline;
    function XBusRead32(Offset: Cardinal): Cardinal;
    procedure StressPause;
    procedure StopRSPThread;
    procedure SetRSPThreaded(Value: Boolean);
    function PinEmulationThread(out Cores: TArray<TN64HostCore>): Boolean;
    procedure PlaceRSPThread(out CPUs: TN64CPUSet; out Preferred: Integer);
    procedure NextRSPSegment;
    function SettledRSPEntry(Index: Integer): Boolean;
    procedure ApplySettledRSPWrites(Last: Integer);
    procedure CheckRSPPrediction;
    function RSPRegister(Index: Integer): Cardinal;
    function PredictRSPRead(Index, Clock: Integer; out Value: Cardinal): Boolean;
    function DeferRSPWrite(Index, Clock: Integer; Value: Cardinal): Boolean;
    procedure UpdateRSPShadow;
    function RSPWindowTime(Clock: Integer): UInt64;
    function NewRSPNote: Integer;
    function RSPPendingAt(Time: UInt64): Integer;
    procedure AddRSPTransfer(const Transfer: TN64SPTransfer; Time: UInt64);
    procedure FenceRSPTransfer(const Transfer: TN64SPTransfer);
    procedure RefenceRSP;
    function LiftRSPFences(Clock: Integer): Boolean;
    procedure LiftRSPTransfer(Index: Integer);
    function AheadRDRAM(Address: Cardinal): Byte;
    class procedure RAMSpan(const Transfer: TN64SPTransfer; out Start, Count: Cardinal); static;
    class function RemainingBeats(const Transfer: TN64SPTransfer): Cardinal; static;
    class procedure StepSPTransfer(var Transfer: TN64SPTransfer); static;
    procedure RewindRSPTo(Keep: Integer);
    procedure ReplayRSPBeat(Index: Integer);

    procedure SPTransferBeat;
    procedure PITransferBeat;
    procedure SITransferBeat;
    function PIBeatCycles: Cardinal;
    procedure PreparePIBlock;
    procedure FinishPIBlock;
    procedure CompletePI;
    procedure ConsumeAI;
    procedure RenderFrame(ScanoutField: Integer; Notify: Boolean);
    procedure FrameRendered(Notify: Boolean);
    procedure WaitVI;
    procedure WaitVISlot(Slot: Integer);
    procedure CompleteVISlot(Slot: Integer);
    procedure SetVIThreaded(Value: Boolean);
    procedure ValidateState;
  protected
    procedure WaitRDP(List: UInt64); override;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset;
    function Read8(Address: Cardinal): Byte; override;
    procedure Write8(Address: Cardinal; Value: Byte); override;
    function Read32(Address: Cardinal): Cardinal; override;
    procedure Write32(Address, Value: Cardinal); override;
    function ReadHidden(Address: Cardinal): Byte; override;
    procedure WriteHidden(Address: Cardinal; Value: Byte); override;
    function GuestTick: UInt64; override;
    procedure SyncDevice(Elapsed: UInt64); override;
    function InterruptPending: Boolean; override;
    procedure RunInstructions(Count: Integer);
    procedure RunCycles(Cycles: Cardinal);
    procedure RunFrame;
    function GetFrame: TEmulatorFrame;
    // Polls completed VI slots without waiting; returns the latest complete
    // frame (possibly the same frame as the previous poll).
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    procedure SetInputs(const Inputs: TN64Pads);
    function TakeSamples: TArray<SmallInt>;
    function SaveBattery: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure ConfigureSaveType(Value: TN64SaveType);
    procedure SerializeState(State: TStateArchive);
    property CPU: TN64CPU read FCPU;
    // Optional command capture is configured by diagnostics, outside guest state.
    // Reading it waits for queued RDP work.
    property Renderer: TN64RDP read GetRenderer;
    property RDPMode: TN64RDPMode read FRDPMode write SetRDPMode;
    // Threads drawing RDP rows in bands (with a worker; 1 or more).
    // Called by a realtime frontend once per completed field. Explicitly
    // setting RDPThreads selects a fixed count and disables adaptation.
    procedure AdaptRDPThreads;
    property RDPThreadChanges: Integer read FRDPThreadChanges;
    property RDPThreads: Integer read FRDPBands write SetRDPThreads;
    // Diagnostics: False runs only the timing RDP on this thread: every DP
    // register, interrupt and timing as before, but no pixel is drawn (the
    // guest then sees stale images). Not to be switched back on.
    property RDPDrawing: Boolean read FRDPDrawing write SetRDPDrawing;
    property BilinearFiltering: Boolean read GetBilinearFiltering write SetBilinearFiltering;
    // The CPU's and the RSP's blocks as generated code where there is a code
    // generator (else always interpreted). Either way the same emulation, bit
    // for bit: it may change at any time (the emulation thread; the RSP
    // thread takes it at its next block).
    property UseRecompiler: Boolean read GetUseRecompiler write SetUseRecompiler;
    // The emulation thread on a core of its own (the fastest), each RDP band
    // on another: threads sharing a core (SMT) or on slow cores slow the
    // emulation thread down. Set when the RDP worker starts; the emulation
    // thread's previous affinity returns when this is switched off or the
    // console is destroyed on that thread. No effect on the emulation.
    property ThreadPlacement: Boolean read FPlacement write SetPlacement;
    // Diagnostics: the timing RDP (its OnPrimitive, ModeWords, LoadStats).
    property TimingRDP: TN64RDP read FRDPTiming;
    property FrameNumber: UInt64 read FFrame;
    property DebugOutput: string read FDebugOutput;
    // The RSP runs ahead of the CPU up to its next MTC0, BREAK or an MFC0
    // whose value is not known yet (exact; false runs it clock by clock with
    // the CPU).
    property RSPRunAhead: Boolean read FRSPAhead write FRSPAhead;
    property RSPStress: Boolean read FRSPStress write FRSPStress;
    property RSPAheadStats: TN64RSPAheadStats read FRSPStats;
    // The RSP thread's ID (diagnostics: 0 before its first window).
    function RSPThreadID: TThreadID;
    function WaitStats: TN64WaitStats;
    // Diagnostics: the fences of SP DMA a window may lift once the transfer
    // is expected done: 2 (default) all, 1 only of transfers out of DMEM, 0
    // none. Any mode is exact.
    property RSPLiftMode: Integer read FRSPLiftMode write FRSPLiftMode;
    // Diagnostics: the RSP itself (UseBlocks, block statistics).
    property RSP: TN64RSP read FRSP;
    // Run-ahead windows on a thread of their own while this thread goes on
    // (long windows only; exact either way). On by default with three
    // physical cores or more.
    property RSPThreaded: Boolean read FRSPThreaded write SetRSPThreaded;
    // VI fields rendered on a thread of their own: a field's frame is ready
    // shortly after it ends (GetFrame waits for it), the emulation goes on
    // meanwhile. Exact either way.
    property VIThreaded: Boolean read FVIThreaded write SetVIThreaded;
    // The CPU's floating point by the host where it can, when the thread
    // running the CPU allows (SFHostReady). On by default; exact either way.
    property HostFloat: Boolean read FHostFloat write FHostFloat;
    // Called with the frame of every field that ends (on the VI thread when
    // VIThreaded).
    property OnFrame: TN64FrameNotify read FOnFrame write FOnFrame;
    property SaveDirty: Boolean read FSaveDirty;
    // Raw hardware diagnostics can omit host display conversion. DMA, RDP,
    // guest VI registers/IRQs and audio clocks still execute normally.
    property VideoOutputEnabled: Boolean read FVideoOutputEnabled write FVideoOutputEnabled;
    function FramesPerSecond: Double;
    function RendererDescription: string;
  end;

implementation

{$IFDEF MSWINDOWS}
// (Diagnostics: TN64RSPAheadStats.ThreadCycles.)

function QueryThreadCycleTime(ThreadHandle: THandle; out CycleTime: UInt64): LongBool; stdcall; external 'kernel32.dll' name 'QueryThreadCycleTime';

function CurrentThreadHandle: THandle; stdcall; external 'kernel32.dll' name 'GetCurrentThread';
{$ENDIF}

type
  // RDRAM alone (a VI field's copy): no devices.
  TN64RAMBus = class(TN64Bus)
  public
    constructor Create;
    function Read8(Address: Cardinal): Byte; override;
    procedure Write8(Address: Cardinal; Value: Byte); override;
  end;

constructor TN64RAMBus.Create;
begin
  inherited Create;
  FDirectMemory := True;
end;

function TN64RAMBus.Read8(Address: Cardinal): Byte;
begin
  Result := 0;
end;

procedure TN64RAMBus.Write8(Address: Cardinal; Value: Byte);
begin
end;

function PhysicalCores: Integer;
begin
  // Physical cores this process may run on (N64.Host); where unknown,
  // assume two logical processors per core.
  Result := Length(HostCores);
  if Result = 0 then
    Result := Max(1, TThread.ProcessorCount div 2);
end;

// The handshake with the RSP thread: its counters and flags are read plainly
// where a plain read is atomic and ordered with the reads after it (x64),
// else through TInterlocked. Spinning on plain reads keeps the writer's
// cache line shared.
function SharedRead(const [ref] Value: Int64): Int64; overload; inline;
begin
  {$IFDEF CPUX64}
  Result := Value;
  {$ELSE}
  Result := TInterlocked.Read(PInt64(@Value)^);
  {$ENDIF}
end;

function SharedRead(const [ref] Value: Integer): Integer; overload; inline;
begin
  {$IFDEF CPUX64}
  Result := Value;
  {$ELSE}
  Result := TInterlocked.CompareExchange(PInteger(@Value)^, 0, 0);
  {$ENDIF}
end;

function DefaultRDPBands(RSPThread: Boolean): Integer;
begin
  // One band per physical core left to them by the emulation thread (and
  // the RSP thread), at most six. Bands beyond the free cores, or on SMT
  // siblings of busy ones, slow the emulation thread down more than they
  // draw: with two cores one band is fastest in GoldenEye, and three take a
  // third of its speed. With six cores four bands draw Command & Conquer 5%
  // faster than three (the emulation thread waited for them); with four
  // cores two and three tie.
  Result := Max(1, Min(6, PhysicalCores - 1 - Ord(RSPThread)));
end;

constructor TN64Console.Create(const Data: TBytes);
begin
  inherited Create;
  if (Length(Data) < $1000) or (Length(Data) > 64 * 1024 * 1024) or
    ((Length(Data) and 3) <> 0) then
    raise EReadError.Create('Invalid N64 ROM size');

  FData := Copy(Data);
  case Data[0] of
    $37:
      for var I := 0 to Length(Data) div 2 - 1 do
      begin
        FData[I * 2] := Data[I * 2 + 1];
        FData[I * 2 + 1] := Data[I * 2]
      end;
    $40:
      for var I := 0 to Length(Data) div 4 - 1 do
        for var J := 0 to 3 do
          FData[I * 4 + J] := Data[I * 4 + 3 - J];
  end;
  if (FData[0] <> $80) or (FData[1] <> $37) or (FData[2] <> $12) or (FData[3] <> $40) then
    raise EReadError.Create('Invalid N64 ROM signature');

  FDetectedSaveType := TN64SaveType.EEPROM4K;
  // Cartridge save hardware, by the region-independent product code.
  // Reference: ares mia/medium/nintendo-64.cpp (EEPROM/SRAM/Flash database).
  // Unknown/homebrew IDs keep the legacy EEPROM4K and Flash command probe.
  // Explicit frontend settings always override this detection.
  var ID := '|' + Char(FData[$3B]) + Char(FData[$3C]) + Char(FData[$3D]) + '|';
  if Pos(ID, '|NB7|NGT|NFU|NCW|NCZ|ND6|NDO|ND2|N3D|NMX|NGC|NIM|NNB|NMV|NM8|NEV|NPP|NUB|NPD|NRZ|NR7|NEP|NYS|') > 0 then
    FDetectedSaveType := TN64SaveType.EEPROM16K
  else if Pos(ID, '|NTE|NVB|NB5|NFZ|NSI|NG6|NGP|NYW|NHY|NIB|NPS|NPA|NP4|NJ5|NP6|NPE|NJG|NZL|NKG|NMF|NRI|NUT|NUM|NOB|NPM|NRE|NAL|NT3|NS4|NA2|NVP|NWL|NW2|NWX|CZL|CFZ|CPS|') > 0 then
    FDetectedSaveType := TN64SaveType.SRAM
  else if Pos(ID, '|NCC|NCV|NDA|NAF|NJF|NKJ|NZS|NM6|NCK|NMQ|NPN|NPF|NPO|CP2|NP3|NRH|NSQ|NT9|NW4|NDP|') > 0 then
    FDetectedSaveType := TN64SaveType.FlashRAM;
  SetLength(FPIF, 64);
  // EEPROM 16K, SRAM 32K, and four controller paks. Backends are indexed.
  SetLength(FSave, 2048 + 32768 + 4 * 32768);
  for var I := 0 to 2047 do
    FSave[I] := $FF;
  FormatControllerPaks;
  for var I := 0 to High(FFlashData) do
    FFlashData[I] := $FF;
  FInterruptLineKnown := True;
  FDirectMemory := True;
  FCPU := TN64CPU.Create(Self);
  FRSP := TN64RSP.Create(Self);
  FRDP := TN64RDP.Create(Self);
  FRDPTiming := TN64RDP.Create(Self, True);
  FRDPFollow := TN64RDP.Create(Self, True);
  FRDPFollow.ClocksOnly := True;
  FRDPFollowStale := True;
  FRDPDrawing := True;
  // Leave real-time scheduling to the host. Pinning the CPU/RSP to one
  // physical core each prevents migration when another application uses
  // that core, even while other fast cores are idle. Explicit placement
  // remains available for controlled/offline benchmarks.
  FPlacement := False;
  {$IFDEF DEBUG}
  FRDPMode := TN64RDPMode.Verify;
  {$ELSE}
  FRDPMode := TN64RDPMode.Threaded;
  {$ENDIF}
  FVI := TN64VI.Create(Self);
  FUseRecompiler := True;
  FHostFloat := True;
  // With three physical cores or more, VI fields on a thread of their own.
  SetVIThreaded(PhysicalCores >= 3);
  FTimeline := TN64Timeline.Create;
  FRSPAhead := True;
  FRSPNoise := $6C078965;
  FRSPWindow := RSPWindowMin;
  FRSP.OnPredict := PredictRSPRead;
  FRSP.OnDefer := DeferRSPWrite;
  // (The DMA addresses, the semaphore and DPC_START: DeferRSPWrite takes
  // them as they are, and UpdateRSPShadow notes them from the journal.)
  FRSP.DeferSilent := (1 shl 0) or (1 shl 1) or (1 shl 7) or (1 shl 8);
  FRSP.OnLift := LiftRSPFences;
  FRSPLiftMode := 2;
  // With a core for the emulation thread, one for the RSP thread and one
  // for the RDP bands.
  FRSPThreaded := PhysicalCores >= 3;
  FRDPBands := DefaultRDPBands(FRSPThreaded);
  FMaxRDPBands := Max(1, Min(16, PhysicalCores - 1 - Ord(FRSPThreaded)));
  FAdaptiveRDP := True;
  // Read by the emulation thread while the RSP thread adds to them.
  SetLength(FRSPNotes, TN64RSP.JournalCapacity);
  FRSPJournal := FRSP.Journal;
  SetLength(FRSPDMAs, RSPMaxTransfers);
  SetLength(FRSPXBusData, 65536);
  FRSPWake := TEvent.Create(nil, False, False, '');
  FRSPProgress := TEvent.Create(nil, False, False, '');
  FRSPWorkerNoise := $1F123BB5;
  FVideoOutputEnabled := True;
  Reset;
end;

destructor TN64Console.Destroy;
begin
  if FVIThread <> nil then
  begin
    FVIThread.Terminate;
    for var S := 0 to 1 do
      FVISlots[S].Start.SetEvent;
    FreeAndNil(FVIThread);
  end;
  // (Before the VI's copies and their events: a band may be making a copy.)
  FRDPWorker.Free; // stops the thread before the RDP goes
  for var S := 0 to 1 do
  begin
    FVISlots[S].Start.Free;
    FVISlots[S].Done.Free;
    FVISlots[S].Bus.Free;
  end;
  StopRSPThread;
  FRSPWake.Free;
  FRSPProgress.Free;
  UnplaceThreads;
  FCPU.Free;
  FRSP.Free;
  FRDP.Free;
  FRDPTiming.Free;
  FRDPFollow.Free;
  FVI.Free;
  FTimeline.Free;
  inherited;
end;

procedure TN64Console.Reset;
begin
  WaitVI;
  DrainRDP;
  // A window on the RSP thread ends; the RSP is reset anyway.
  StopAhead;
  FRSP.EndAhead;
  for var I := 0 to High(FRAM) do
    FRAM[I] := 0;
  RAMReplaced;
  for var I := 0 to High(FHiddenRAM) do
    FHiddenRAM[I] := 0;
  FTimeline.Reset;
  FSPTransfer := Default(TN64SPTransfer);
  FSPQueued := Default(TN64SPTransfer);
  FPITransfer := Default(TN64PITransfer);
  FSITransfer := Default(TN64SITransfer);
  FPendingSPAddress := 0;
  FPendingRAMAddress := 0;
  FVIPhase := 0;
  FAIDACPhase := 0;
  FAIAnchorTick := 0;
  FRSPPhase := 0;
  FRSPRun := 0;
  FSPDone := 0;
  MarkSPTransfers;
  FLastLeft := 0;
  FLastRight := 0;
  FCurrentFrame := Default(TEmulatorFrame);
  for var I := 0 to High(FSP) do
    FSP[I] := 0;
  for var I := 0 to 63 do
    FPIF[I] := 0;
  for var I := 0 to 7 do
    for var J := 0 to 15 do
      FReg[I, J] := 0;
  for var I := $40 to $FFF do
    FSP[I] := FData[I];
  SPLoaded;
  FReg[0, 4] := 1;
  FReg[5, 2] := $7F;
  FReg[5, 3] := $7F;
  FReg[2, 1] := $02020102;
  FReg[1, 3] := $80;
  FReg[3, 6] := 525;
  FReg[6, 0] := $E;
  FReg[6, 1] := $40;
  FReg[6, 3] := $14;
  FReg[6, 4] := $00063634;
  UpdateInterruptLine;
  FFrame := 0;
  FTick := 0;
  FLine := 0;
  FField := 0;
  FSPPC := 0;
  FSampleCount := 0;
  FAIAddress := 0;
  FAILength := 0;
  FAIProgress := 0;
  FAIPhase := 0;
  FAINextAddress := 0;
  FAINextLength := 0;
  FAudioClock := 0;
  FAIDACRemainder := 0;
  FDebugOutput := '';
  for var I := 0 to High(FDebugBuffer) do
    FDebugBuffer[I] := 0;
  FFlashMode := 0;
  FFlashOffset := 0;
  FFlashStatus := 0;
  FFlashReady := False;
  FCPU.Reset;
  FRSP.Reset;
  FRDP.Reset;
  FRDPTiming.Reset;
  // The other band RDPs and the timing RDP follow FRDP again.
  FRDPTimingStale := True;
  FVI.Reset;
  FReg[3, 7] := 3093;
  if FramesPerSecond = 50 then
  begin
    FReg[3, 6] := 625;
    FReg[3, 7] := 3177
  end;
  FReg[5, 5] := FData[3];
  FReg[5, 6] := FData[2];
  FReg[5, 7] := FData[1] and 15;
  FReg[5, 8] := (FData[1] shr 4) and 3;
  ScheduleVI;
  ScheduleOutput;
  // Post-PIF register seeds selected by the IPL3 word checksum used by Project64.
  var Sum: UInt64 := 0;
  for var I := $40 div 4 to $FFC div 4 do
    Sum := Sum + ((Cardinal(FData[I * 4]) shl 24) or (Cardinal(FData[I * 4 + 1]) shl 16) or
      (Cardinal(FData[I * 4 + 2]) shl 8) or FData[I * 4 + 3]);
  var CIC := 6102;
  if Sum = $D6497E414B then
    CIC := 6103
  else if Sum = $11A49F60E96 then
    CIC := 6105
  else if Sum = $D6D5BE5580 then
    CIC := 6106;
  FCPU.GPR[1] := 1;
  FCPU.GPR[2] := $0EBDA536;
  FCPU.GPR[3] := $0EBDA536;
  FCPU.GPR[4] := $A536;
  FCPU.GPR[5] := SX($C95973D5, 32);
  FCPU.GPR[12] := SX($ED10D0B3, 32);
  FCPU.GPR[13] := $1402A4CC;
  FCPU.GPR[14] := $2449A366;
  FCPU.GPR[15] := $3103E121;
  FCPU.GPR[24] := 3;
  FCPU.GPR[25] := SX($9DEBB54F, 32);
  if CIC = 6103 then
  begin
    FCPU.GPR[2] := $49A5EE96;
    FCPU.GPR[3] := $49A5EE96;
    FCPU.GPR[4] := $EE96;
    FCPU.GPR[5] := SX($95315A28, 32);
    FCPU.GPR[12] := SX($CE9DFBF7, 32);
    FCPU.GPR[13] := SX($CE9DFBF7, 32);
    FCPU.GPR[14] := $5BACA1DF;
    FCPU.GPR[15] := $18B63D28;
    FCPU.GPR[22] := $78;
    FCPU.GPR[25] := SX($825B21C9, 32);
  end
  else if CIC = 6105 then
  begin
    FCPU.GPR[1] := 0;
    FCPU.GPR[2] := SX($F58B0FBF, 32);
    FCPU.GPR[3] := SX($F58B0FBF, 32);
    FCPU.GPR[4] := $FBF;
    FCPU.GPR[5] := $5493FB9A;
    FCPU.GPR[12] := SX($9651F81E, 32);
    FCPU.GPR[13] := $2D42AAC5;
    FCPU.GPR[14] := SX($C2C20384, 32);
    FCPU.GPR[15] := $56584D60;
    FCPU.GPR[22] := $91;
    FCPU.GPR[25] := SX($CDCE565F, 32);
    Write32($04001000, $3C0DBFC0);
    Write32($04001004, $8DA807FC);
    Write32($04001008, $25AD07C0);
    Write32($0400100C, $31080080);
    Write32($04001010, $5500FFFC);
    Write32($04001014, $3C0DBFC0);
    Write32($04001018, $8DA80024);
    Write32($0400101C, $3C0BB000);
  end
  else if CIC = 6106 then
  begin
    FCPU.GPR[1] := 0;
    FCPU.GPR[2] := SX($A95930A4, 32);
    FCPU.GPR[3] := SX($A95930A4, 32);
    FCPU.GPR[4] := $30A4;
    FCPU.GPR[5] := SX($E067221F, 32);
    FCPU.GPR[12] := SX($BCB59510, 32);
    FCPU.GPR[13] := SX($BCB59510, 32);
    FCPU.GPR[14] := $5CD2B70F;
    FCPU.GPR[15] := $7A3C07F4;
    FCPU.GPR[22] := $85;
    FCPU.GPR[25] := $465E3F72;
  end;
  if FramesPerSecond = 50 then
  begin
    FCPU.GPR[20] := 0;
    FCPU.GPR[23] := 6;
    FCPU.GPR[24] := 0;
    FCPU.GPR[31] := SX($A4001554, 32);
    case CIC of
      6102:
        begin
          FCPU.GPR[5] := SX($C0F1D859, 32);
          FCPU.GPR[14] := $2DE108EA
        end;
      6103:
        begin
          FCPU.GPR[5] := SX($D4646273, 32);
          FCPU.GPR[14] := $1AF99984
        end;
      6105:
        begin
          FCPU.GPR[5] := SX($DECAAAD1, 32);
          FCPU.GPR[14] := $0CF85C13;
          FCPU.GPR[24] := 2;
          Write32($04001004, $BDA807FC)
        end;
      6106:
        begin
          FCPU.GPR[5] := SX($B04DC903, 32);
          FCPU.GPR[14] := $1AF99984;
          FCPU.GPR[24] := 2
        end;
    end;
  end;
  Write32($318, $800000);
  Write32($3F0, $800000);
end;

function TN64Console.Read8(Address: Cardinal): Byte;
begin
  if (Address >= $13FF0020) and (Address < $13FF0220) then
    Exit(FDebugBuffer[Address - $13FF0020]);
  if Address < $800000 then
    Exit(ReadRAM8(Address));
  if (Address >= $04000000) and (Address < $04002000) then
  begin
    SyncRSP;
    Exit(FSP[Address - $04000000]);
  end;
  if (Address >= $1FC007C0) and (Address < $1FC00800) then
    Exit(FPIF[Address - $1FC007C0]);
  if (Address >= $10000000) and (UInt64(Address) < UInt64($10000000) + Cardinal(Length(FData))) then
    Exit(FData[Address - $10000000]);
  if (Address >= $08000000) and (Address < $08020000) then
  begin
    if HasFlash then
      Exit(Byte((FFlashStatus shr ((7 - (Address and 7)) * 8)) and $FF));
    if (Address < $08008000) and (FSaveType in [TN64SaveType.Auto, TN64SaveType.SRAM]) then
      Exit(FSave[2048 + Address - $08000000]);
    Exit(0);
  end;
  Result := 0;
  if (Address >= $03F00000) and (Address < $04900040) then
    Result := Byte((Read32(Address and $FFFFFFFC) shr ((3 - (Address and 3)) * 8)) and $FF);
end;

procedure TN64Console.Write8(Address: Cardinal; Value: Byte);
begin
  if (Address >= $13FF0020) and (Address < $13FF0220) then
  begin
    FDebugBuffer[Address - $13FF0020] := Value;
    Exit
  end;
  if Address < $800000 then
    WriteRAM8(Address, Value)
  else if (Address >= $04000000) and (Address < $04002000) then
  begin
    SyncRSP;
    WriteSP8(Address - $04000000, Value)
  end
  else if (Address >= $1FC007C0) and (Address < $1FC00800) then
  begin
    FPIF[Address - $1FC007C0] := Value;
    if Address = $1FC007FF then
      PIFCommand;
  end
  else if (Address >= $08000000) and (Address < $08008000) then
    if not HasFlash and (FSaveType in [TN64SaveType.Auto, TN64SaveType.SRAM]) then
    begin
      FSave[2048 + Address - $08000000] := Value;
      FSaveDirty := True
    end;
end;

function TN64Console.Read32(Address: Cardinal): Cardinal;
begin
  // Only bypass the bus decoder when the entire word is in one memory bank.
  // Boundary reads and device registers retain their byte-wise side effects.
  if Address <= $7FFFFC then
    Exit(ReadRAM32(Address));
  if (Address >= $04000000) and (Address <= $04001FFC) then
  begin
    SyncRSP;
    var Offset := Address - $04000000;
    if FXBusCount > 0 then
      Exit(XBusRead32(Offset));
    Exit((Cardinal(FSP[Offset]) shl 24) or (Cardinal(FSP[Offset + 1]) shl 16) or
      (Cardinal(FSP[Offset + 2]) shl 8) or FSP[Offset + 3]);
  end;
  if (Address >= $10000000) and (Address <= $10000000 + Cardinal(Length(FData)) - 4) and
    not ((Address >= $13FF001D) and (Address < $13FF0220)) then
  begin
    var Offset := Address - $10000000;
    Exit((Cardinal(FData[Offset]) shl 24) or (Cardinal(FData[Offset + 1]) shl 16) or
      (Cardinal(FData[Offset + 2]) shl 8) or FData[Offset + 3]);
  end;
  if (Address >= $13FF0020) and (Address < $13FF0220) then
    Exit(inherited Read32(Address));
  Result := 0;
  if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
    (Address >= $08000000) then
  begin
    if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
      ((Address >= $08000000) and (Address < $08020000)) or
      ((Address >= $10000000) and (Address < $10000000 + Cardinal(Length(FData)))) or
      ((Address >= $1FC007C0) and (Address < $1FC00800)) then
      Exit(inherited Read32(Address));
  end;
  if (Address >= $04040000) and (Address < $04040020) then
  begin
    var I := (Address - $04040000) div 4;
    Result := FReg[0, I];
    if I = 7 then
      FReg[0, 7] := 1;
    Exit;
  end;
  if Address = $04080000 then
  begin
    SyncRSP;
    Exit(FSPPC);
  end;
  if (Address >= $04100000) and (Address < $04900000) then
  begin
    var Bank := (Address - $04000000) div $100000;
    if Bank = 2 then
      Exit;
    if Bank >= 3 then
      Dec(Bank);
    var I := (Address and $FFFFF) div 4;
    if I < 16 then
    begin
      if (Bank = 3) and (I = 4) then
        Exit(Cardinal((FLine and not 1) or FField));
      if (Bank = 4) and (I = 1) then
        Exit((FAILength - FAIProgress) and $3FFF8);
      if (Bank = 4) and (I = 3) then
      begin
        Result := 0;
        if FAILength > 0 then
          Result := $40000000;
        if FAINextLength > 0 then
          Result := Result or $80000000;
        Exit;
      end;
      Exit(FReg[Bank, I]);
    end;
  end;
  if (Address >= $03F00000) and (Address < $04000000) then
    case Address and $FF of
      0:
        Exit($B4190010);
      4:
        Exit(0);
      12:
        Exit($00000500);
    end;
  Result := 0;
end;

procedure TN64Console.Write32(Address, Value: Cardinal);
begin
  if Address <= $7FFFFC then
  begin
    WriteRAM32(Address, Value);
    Exit;
  end;
  if (Address >= $04000000) and (Address <= $04001FFC) then
  begin
    SyncRSP;
    var Offset := Address - $04000000;
    WriteSP8(Offset, Byte(Value shr 24));
    WriteSP8(Offset + 1, Byte((Value shr 16) and $FF));
    WriteSP8(Offset + 2, Byte((Value shr 8) and $FF));
    WriteSP8(Offset + 3, Byte(Value and $FF));
    Exit;
  end;
  if Address = $13FF0014 then
  begin
    AppendDebugOutput(Value);
    Exit;
  end;
  if (Address >= $13FF0020) and (Address < $13FF0220) then
  begin
    inherited Write32(Address, Value);
    Exit
  end;
  if Address = $08010000 then
  begin
    if FSaveType in [TN64SaveType.Auto, TN64SaveType.FlashRAM] then
      FlashCommand(Value);
    Exit;
  end;
  if (Address < $800000) or ((Address >= $04000000) and (Address < $04002000)) or
    ((Address >= $08000000) and (Address < $08008000)) or
    ((Address >= $1FC007C0) and (Address < $1FC00800)) then
  begin
    inherited Write32(Address, Value);
    Exit
  end;
  if Address = $04080000 then
  begin
    SyncRSP;
    FSPPC := Value and $FFC;
    FRSP.ResetPipeline;
    Exit
  end;
  if (Address >= $04040000) and (Address < $04040020) then
  begin
    // DMA starts, halts and single-stepping change what the RSP does next.
    SyncRSP;
    var I := (Address - $04040000) div 4;
    case I of
      0:
        FPendingSPAddress := Value and $1FFF;
      1:
        FPendingRAMAddress := Value and $FFFFFF;
      2, 3:
        SPDMA(I = 3, Value);
      4:
        begin
          var S := FReg[0, 4];
          if (Value and 3) = 1 then
            S := S and not 1;
          if (Value and 3) = 2 then
            S := S or 1;
          if (Value and 4) <> 0 then
            S := S and not 2;
          if (Value and $18) = 8 then
            SetInterrupts(FReg[2, 2] and not 1);
          if (Value and $18) = 16 then
            SetInterrupts(FReg[2, 2] or 1);
          for var J := 0 to 9 do
          begin
            var Flag := Cardinal(1) shl (J + 5);
            var Clear := Cardinal(1) shl (J * 2 + 5);
            if J < 2 then
              Flag := Cardinal(1) shl (J + 5);
            if (Value and (Clear or (Clear shl 1))) = Clear then
              S := S and not Flag;
            if (Value and (Clear or (Clear shl 1))) = (Clear shl 1) then
              S := S or Flag;
          end;
          FReg[0, 4] := S;
          if (S and 1) = 0 then
            ScheduleRSP
          else
            FTimeline.Cancel(TN64EventKind.RSPClock);
        end;
      7:
        FReg[0, 7] := 0;
    end;
    Exit;
  end;
  if (Address >= $04100000) and (Address < $04900000) then
  begin
    var Bank := (Address - $04000000) div $100000;
    if Bank = 2 then
      Exit;
    if Bank >= 3 then
      Dec(Bank);
    var I := (Address and $FFFFF) div 4;
    if I >= 16 then
      Exit;
    // RDP lists in DMEM (XBUS) read it now.
    if Bank = 1 then
      SyncRSP;
    case Bank of
      1:
        case I of
          0:
            if (FReg[1, 3] and $400) = 0 then
            begin
              FReg[1, 0] := Value and $FFFFF8;
              FReg[1, 3] := FReg[1, 3] or $400
            end;
          1:
            begin
              FReg[1, 1] := Value and $FFFFF8;
              if (FReg[1, 3] and $400) <> 0 then
              begin
                FReg[1, 2] := FReg[1, 0];
                FReg[1, 3] := FReg[1, 3] and not $400
              end;
              ProcessRDP;
            end;
          3:
            begin
              for var J := 0 to 2 do
              begin
                var Clear := (Value and (Cardinal(1) shl (J * 2))) <> 0;
                var SetFlag := (Value and (Cardinal(2) shl (J * 2))) <> 0;
                if Clear <> SetFlag then
                  if Clear then
                    FReg[1, 3] := FReg[1, 3] and not (Cardinal(1) shl J)
                  else
                    FReg[1, 3] := FReg[1, 3] or (Cardinal(1) shl J);
              end;
              if (Value and $40) <> 0 then
                FReg[1, 7] := 0;
              if (Value and $80) <> 0 then
                FReg[1, 6] := 0;
              if (Value and $100) <> 0 then
                FReg[1, 5] := 0;
              if (Value and $200) <> 0 then
                FReg[1, 4] := 0;
              if (FReg[1, 3] and 2) = 0 then
                ProcessRDP;
            end;
        end;
      2:
        case I of
          0:
            begin
              FReg[2, 0] := (FReg[2, 0] and not $7F) or (Value and $7F);
              if (Value and $800) <> 0 then
                SetInterrupts(FReg[2, 2] and not $20);
            end;
          3:
            begin
              for var J := 0 to 5 do
              begin
                if (Value and (Cardinal(1) shl (J * 2))) <> 0 then
                  FReg[2, 3] := FReg[2, 3] and not (Cardinal(1) shl J);
                if (Value and (Cardinal(2) shl (J * 2))) <> 0 then
                  FReg[2, 3] := FReg[2, 3] or (Cardinal(1) shl J);
              end;
              UpdateInterruptLine;
            end;
        end;
      3:
        if I = 4 then
          SetInterrupts(FReg[2, 2] and not 8)
        else
          FReg[3, I] := Value;
      4:
        case I of
          0:
            FReg[4, 0] := Value and $FFFFF8;
          1:
            if FAILength = 0 then
            begin
              FAIAddress := FReg[4, 0];
              FAILength := Value and $3FFF8;
              FAIProgress := 0;
              ScheduleAI;
            end
            else if FAINextLength = 0 then
            begin
              FAINextAddress := FReg[4, 0];
              FAINextLength := Value and $3FFF8;
            end;
          3:
            SetInterrupts(FReg[2, 2] and not 4);
          2:
            begin
              if (FReg[4, 2] and 1) = 0 then
                FAIAnchorTick := FTimeline.Now;
              FReg[4, 2] := Value and 1;
              if (Value and 1) = 0 then
                FTimeline.Cancel(TN64EventKind.AIConsume)
              else
                ScheduleAI;
            end;
          4:
            begin
              FReg[4, 4] := Value and $3FFF;
              FTimeline.Cancel(TN64EventKind.AIConsume);
              FAIDACPhase := 0;
              FAIAnchorTick := FTimeline.Now;
              ScheduleAI;
            end;
        else
          FReg[4, I] := Value;
        end;
      5:
        begin
          // Only PI_STATUS accepts writes while either DMA direction is busy.
          if (I <> 4) and FPITransfer.Active then
          begin
            FReg[5, 4] := FReg[5, 4] or 4;
            Exit
          end;
          case I of
            0:
              FReg[5, 0] := Value and $FFFFFE;
            1:
              FReg[5, 1] := Value and $FFFFFFFE;
            2, 3:
              PIDMA(I = 2, Value);
            4:
              begin
                if (Value and 2) <> 0 then
                begin
                  SetInterrupts(FReg[2, 2] and not $10);
                  FReg[5, 4] := FReg[5, 4] and not 8
                end;
                if (Value and 1) <> 0 then
                begin
                  FPITransfer := Default(TN64PITransfer);
                  FTimeline.Cancel(TN64EventKind.PITransfer);
                  FReg[5, 4] := FReg[5, 4] and not 5;
                end;
              end;
            5, 6, 9, 10:
              FReg[5, I] := Value and $FF;
            7, 11:
              FReg[5, I] := Value and 15;
            8, 12:
              FReg[5, I] := Value and 3;
          end;
        end;
      7:
        case I of
          1, 4:
            SIDMA(I = 4);
          6:
            begin
              SetInterrupts(FReg[2, 2] and not 2);
              FReg[7, 6] := FReg[7, 6] and not $1000;
            end;
        else
          FReg[7, I] := Value;
        end;
    else
      FReg[Bank, I] := Value;
    end;
  end;
end;

procedure TN64Console.AppendDebugOutput(Count: Cardinal);
begin
  // ISViewer is used by libdragon's emulator diagnostics. Bound both buffers.
  // Kept out of Write32: its string/array temporaries would give that hot
  // routine an implicit try/finally and keep its variables in memory.
  var Length8 := Integer(Min(Count, Cardinal(Length(FDebugBuffer))));
  var Data: TBytes;
  SetLength(Data, Length8);
  for var I := 0 to Length8 - 1 do
    Data[I] := FDebugBuffer[I];
  FDebugOutput := FDebugOutput + TEncoding.UTF8.GetString(Data);
  if Length(FDebugOutput) > 65536 then
    FDebugOutput := Copy(FDebugOutput, Length(FDebugOutput) - 65535, 65536);
end;

procedure TN64Console.UpdateInterruptLine;
begin
  FInterruptLine := (FReg[2, 2] and FReg[2, 3]) <> 0;
end;

procedure TN64Console.SetInterrupts(Value: Cardinal);
begin
  if FReg[2, 2] = Value then
    Exit;
  FReg[2, 2] := Value;
  UpdateInterruptLine;
  if TraceEnabled then
    Trace(TN64TraceKind.InterruptChange, FCPU.PC, $04300008, Value);
end;

procedure TN64Console.SPDMA(Writing: Boolean; Value: Cardinal);
begin
  if FSPQueued.Active then
    Exit;
  var Transfer := Default(TN64SPTransfer);
  Transfer.Active := True;
  Transfer.Writing := Writing;
  Transfer.Size := ((Value and $FFF) or 7) + 1;
  Transfer.Blocks := ((Value shr 12) and $FF) + 1;
  Transfer.Skip := (Value shr 20) and $FF8;
  Transfer.Control := Value;
  Transfer.local := FPendingSPAddress and $1FF8;
  Transfer.RAM := FPendingRAMAddress and $FFFFF8;
  MarkSPTransfer(Transfer, FSPDone + 1 + Ord(FSPTransfer.Active));
  if FSPTransfer.Active then
  begin
    FSPQueued := Transfer;
    FReg[0, 5] := 1;
    FReg[0, 4] := FReg[0, 4] or 8
  end
  else
  begin
    FSPTransfer := Transfer;
    FReg[0, 6] := 1;
    FReg[0, 4] := FReg[0, 4] or 4;
    FReg[0, 0] := Transfer.local;
    FReg[0, 1] := Transfer.RAM;
    FReg[0, 2 + Ord(Writing)] := Value;
    // SGI RSP programmer's guide p96: 6-12 RCP clocks setup, then 8 B/clock.
    // Use the documented minimum setup in this functional arbitration model.
    FTimeline.Schedule(TN64EventKind.SPTransfer, 11);
  end;
  if TraceEnabled then
    Trace(TN64TraceKind.DMAStart, FCPU.PC, $04040008 + Ord(Writing) * 4, Value);
end;

procedure TN64Console.PIDMA(Writing: Boolean; Value: Cardinal);
begin
  if FPITransfer.Active then
  begin
    FReg[5, 4] := FReg[5, 4] or 4;
    Exit
  end;
  FPITransfer := Default(TN64PITransfer);
  FPITransfer.Active := True;
  FPITransfer.Writing := Writing;
  FPITransfer.RAM := FReg[5, 0] and $FFFFFE;
  FPITransfer.Cart := FReg[5, 1] and $FFFFFFFE;
  FPITransfer.Length := (Value and $FFFFFF) + 1;
  FPITransfer.Flash := HasFlash and (FPITransfer.Cart >= $08000000) and (FPITransfer.Cart < $08020000);
  FPITransfer.FlashMode := FFlashMode;
  FPITransfer.FlashStatus := FFlashStatus;
  var Domain := 5;
  if (FPITransfer.Cart >= $05000000) and (FPITransfer.Cart < $10000000) then
    Domain := 9;
  FPITransfer.Latency := FReg[5, Domain] and $FF;
  FPITransfer.PulseWidth := FReg[5, Domain + 1] and $FF;
  FPITransfer.PageSize := FReg[5, Domain + 2] and 15;
  FPITransfer.ReleaseDuration := FReg[5, Domain + 3] and 3;
  FPITransfer.ClockPhase := 1; // ceil of cumulative RCP clocks * 3/2, without per-beat drift.
  FPITransfer.FirstBlock := True;
  FPITransfer.MaxBlockSize := 128;
  FPITransfer.BlockRAM := FPITransfer.RAM;
  if not Writing and not FPITransfer.Flash then
    PreparePIBlock;
  FReg[5, 2 + Ord(not Writing)] := Value and $FFFFFF;
  FReg[5, 4] := FReg[5, 4] or 1;
  FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
  if TraceEnabled then
    Trace(TN64TraceKind.DMAStart, FCPU.PC, $04600008 + Ord(not Writing) * 4, Value);
end;

function TN64Console.HasFlash: Boolean;
begin
  Result := (FSaveType = TN64SaveType.FlashRAM) or ((FSaveType = TN64SaveType.Auto) and
    (FFlashUsed or (FDetectedSaveType = TN64SaveType.FlashRAM)));
end;

procedure TN64Console.FlashCommand(Value: Cardinal);
begin
  if not (Value shr 24 in [0, $4B, $78, $A5, $B4, $D2, $E1, $F0]) then
    Exit;
  FFlashUsed := True;
  case Value shr 24 of
    $E1:
      begin
        FFlashMode := 4;
        FFlashStatus := $1111800100C2001E
      end;
    $F0, 0:
      begin
        FFlashMode := 3;
        FFlashStatus := $11118004F0000000
      end;
    $4B:
      FFlashOffset := (Value and $FFFF) * 128;
    $78:
      begin
        FFlashMode := 1;
        FFlashStatus := $1111800800C2001E
      end;
    $B4:
      begin
        FFlashMode := 2;
        FFlashReady := False
      end;
    $A5:
      begin
        FFlashOffset := (Value and $FFFF) * 128;
        FFlashStatus := $1111800400C2001E
      end;
    $D2:
      begin
        if UInt64(FFlashOffset) + 128 <= Cardinal(Length(FFlashData)) then
          if (FFlashMode = 1) or ((FFlashMode = 2) and FFlashReady) then
          begin
            for var I := 0 to 127 do
              if FFlashMode = 1 then
                FFlashData[FFlashOffset + Cardinal(I)] := $FF
              else
                FFlashData[FFlashOffset + Cardinal(I)] := FFlashBuffer[I];
            FSaveDirty := True;
          end;
        FFlashMode := 0;
        FFlashReady := False;
      end;
  end;
end;

procedure TN64Console.ConfigureSaveType(Value: TN64SaveType);
begin
  FSaveType := Value
end;

function TN64Console.EEPROMSize: Integer;
begin
  Result := 0;
  if FSaveType = TN64SaveType.Auto then
  begin
    if FDetectedSaveType = TN64SaveType.EEPROM4K then
      Result := 512;
    if FDetectedSaveType = TN64SaveType.EEPROM16K then
      Result := 2048;
  end;
  if FSaveType = TN64SaveType.EEPROM4K then
    Result := 512;
  if FSaveType = TN64SaveType.EEPROM16K then
    Result := 2048;
  if HasFlash then
    Result := 0;
end;

function PakCRC(const Data: TBytes; Offset: Integer): Byte;
begin
  var C: Cardinal := 0;
  for var I := 0 to 32 do
    for var B := 7 downto 0 do
    begin
      var Top := C and $80;
      C := (C shl 1) and $FF;
      if (I < 32) and ((Data[Offset + I] and (1 shl B)) <> 0) then
        C := C or 1;
      if Top <> 0 then
        C := C xor $85;
    end;
  Result := Byte(C);
end;

procedure TN64Console.FormatControllerPaks;
const
  Copies: array[0..3] of Integer = ($20, $60, $80, $C0);
begin
  for var Port := 0 to 3 do
  begin
    var Base := 2048 + 32768 + Port * 32768;
    var ID: array[0..31] of Byte;
    for var I := 0 to 27 do
      ID[I] := Byte((I * 17 + Port * 31) and $FF);
    ID[24] := $FF;
    ID[25] := $FF;
    ID[26] := 1;
    ID[27] := 0;
    var Sum: Cardinal := 0;
    var Inverse: Cardinal := 0;
    for var I := 0 to 13 do
    begin
      var Value := (Cardinal(ID[I * 2]) shl 8) or ID[I * 2 + 1];
      Sum := Sum + Value;
      Inverse := Inverse + (Value xor $FFFF);
    end;
    ID[28] := Byte((Sum shr 8) and $FF);
    ID[29] := Byte(Sum and $FF);
    ID[30] := Byte((Inverse shr 8) and $FF);
    ID[31] := Byte(Inverse and $FF);
    FSave[Base] := $81;
    for var I := 1 to 31 do
      FSave[Base + I] := Byte(I);
    for var Offset in Copies do
      for var I := 0 to 31 do
        FSave[Base + Offset + I] := ID[I];
    // Pages 1/2 contain matching inode tables; pages 5..127 are free (0003).
    for var Page := 1 to 2 do
    begin
      for var I := 5 to 127 do
        FSave[Base + Page * 256 + I * 2 + 1] := 3;
      FSave[Base + Page * 256 + 1] := (123 * 3) and $FF;
    end;
  end;
end;

procedure TN64Console.CICChallenge;
const
  Lookup: array[0..1, 0..15] of Byte = (
    (4, 7, 10, 7, 14, 5, 14, 1, 12, 15, 8, 15, 6, 3, 6, 9),
    (4, 1, 10, 7, 14, 5, 14, 1, 12, 9, 8, 5, 6, 3, 12, 9));
begin
  var Response: array[0..14] of Byte;
  for var I := 0 to 14 do
    Response[I] := 0;
  var Key := 11;
  var Table := 0;
  for var I := 0 to 29 do
  begin
    var Challenge := Integer(FPIF[48 + I div 2]);
    if not Odd(I) then
      Challenge := Challenge shr 4
    else
      Challenge := Challenge and 15;
    var Value := (Key + 5 * Challenge) and 15;
    if Odd(I) then
      Response[I div 2] := Response[I div 2] or Byte(Value)
    else
      Response[I div 2] := Byte(Value shl 4);
    Key := Lookup[Table, Value];
    var Sign := Value shr 3;
    var Magnitude := Value and 7;
    if Sign <> 0 then
      Magnitude := Magnitude xor 7;
    var Next := 1 - Sign;
    if Magnitude mod 3 = 1 then
      Next := Sign;
    if (Table = 1) and (Value in [1, 9]) then
      Next := 1;
    if (Table = 1) and (Value in [11, 14]) then
      Next := 0;
    Table := Next;
  end;
  FPIF[46] := 0;
  FPIF[47] := 0;
  for var I := 0 to 14 do
    FPIF[48 + I] := Response[I];
  FPIF[63] := 0;
end;

procedure TN64Console.PIFCommand;
begin
  if FPIF[63] > 1 then
  begin
    case FPIF[63] of
      2:
        CICChallenge;
      8:
        begin
          FPIF[63] := 0;
          FReg[7, 6] := $1000;
          SetInterrupts(FReg[2, 2] or 2)
        end;
      $10:
        FPIF[63] := 0;
      $30:
        FPIF[63] := $80;
      $C0:
        for var I := 0 to 63 do
          FPIF[I] := 0;
    end;
    Exit;
  end;
  if (FPIF[63] and 1) = 0 then
    Exit;
  var Pos := 0;
  var Port := 0;
  while Pos < 63 do
  begin
    var Tx := FPIF[Pos];
    if Tx in [$FD, $FE] then
      Break;
    if Tx in [$FF, $B4, $56, $B8] then
    begin
      Inc(Pos);
      Continue
    end;
    if Tx = 0 then
    begin
      Inc(Pos);
      Inc(Port);
      Continue
    end;
    if Pos + 2 >= 63 then
      Break;
    var Rx := FPIF[Pos + 1] and $3F;
    var Payload := Pos + 2;
    if (Tx > 63) or (Payload + Tx + Rx > 63) then
      Break;
    var Answer := Payload + Tx;
    var Command := FPIF[Payload];
    var Valid := False;
    if Port < 4 then
    begin
      if FInputs[Port].Connected then
        case Command of
          0, $FF:
            if (Tx = 1) and (Rx = 3) then
            begin
              FPIF[Answer] := 5;
              FPIF[Answer + 1] := 0;
              FPIF[Answer + 2] := 1;
              Valid := True
            end;
          1:
            if (Tx = 1) and (Rx = 4) then
            begin
              FPIF[Answer] := Byte(FInputs[Port].Buttons shr 8);
              FPIF[Answer + 1] := Byte(FInputs[Port].Buttons and $FF);
              FPIF[Answer + 2] := Byte((Integer(FInputs[Port].StickX) + 256) and $FF);
              FPIF[Answer + 3] := Byte((Integer(FInputs[Port].StickY) + 256) and $FF);
              Valid := True;
            end;
          2, 3:
            if (Tx >= 3) and (((Command = 2) and (Rx = 33)) or ((Command = 3) and (Tx = 35) and (Rx = 1))) then
            begin
              var Address := ((Integer(FPIF[Payload + 1]) shl 8) or FPIF[Payload + 2]) and $FFE0;
              var Offset := 2048 + 32768 + Port * 32768 + (Address and $7FFF);
              if Command = 2 then
              begin
                for var I := 0 to 31 do
                  if Address < $8000 then
                    FPIF[Answer + I] := FSave[Offset + I]
                  else
                    FPIF[Answer + I] := 0;
                FPIF[Answer + 32] := PakCRC(FPIF, Answer);
              end
              else
              begin
                if Address < $8000 then
                begin
                  for var I := 0 to 31 do
                    FSave[Offset + I] := FPIF[Payload + 3 + I];
                  FSaveDirty := True;
                end;
                FPIF[Answer] := PakCRC(FPIF, Payload + 3);
              end;
              Valid := True;
            end;
        end;
    end
    else if (Port = 4) and (EEPROMSize <> 0) then
      case Command of
        0, $FF:
          if (Tx = 1) and (Rx = 3) then
          begin
            FPIF[Answer] := 0;
            FPIF[Answer + 1] := $80;
            if EEPROMSize = 2048 then
              FPIF[Answer + 1] := $C0;
            FPIF[Answer + 2] := 0;
            Valid := True
          end;
        4:
          if (Tx = 2) and (Rx = 8) and (Integer(FPIF[Payload + 1]) * 8 < EEPROMSize) then
          begin
            for var I := 0 to 7 do
              FPIF[Answer + I] := FSave[FPIF[Payload + 1] * 8 + I];
            Valid := True
          end;
        5:
          if (Tx = 10) and (Rx = 1) and (Integer(FPIF[Payload + 1]) * 8 < EEPROMSize) then
          begin
            for var I := 0 to 7 do
              FSave[FPIF[Payload + 1] * 8 + I] := FPIF[Payload + 2 + I];
            FPIF[Answer] := 0;
            FSaveDirty := True;
            Valid := True
          end;
      end;
    if not Valid then
      FPIF[Pos + 1] := FPIF[Pos + 1] or $80;
    Pos := Answer + Rx;
    Inc(Port);
  end;
  FPIF[63] := 0;
end;

procedure TN64Console.ReadPIFControllers;
begin
  if FPIF[63] = 2 then
    Exit;
  var Pos := 0;
  var Port := 0;
  while Pos < 63 do
  begin
    var Tx := FPIF[Pos];
    if Tx in [$FD, $FE] then
      Break;
    if Tx in [$FF, $B4, $56, $B8] then
    begin
      Inc(Pos);
      Continue
    end;
    if Tx = 0 then
    begin
      Inc(Pos);
      Inc(Port);
      Continue
    end;
    if (Tx > 63) or (Pos + 2 >= 63) then
      Break;
    var Rx := FPIF[Pos + 1] and $3F;
    var Answer := Pos + 2 + Tx;
    if Answer + Rx > 63 then
      Break;
    // Polling must sample live input without replaying EEPROM/pak writes.
    if (Port < 4) and (Tx = 1) and (Rx = 4) and (FPIF[Pos + 2] = 1) then
    begin
      FPIF[Pos + 1] := Rx;
      if FInputs[Port].Connected then
      begin
        FPIF[Answer] := Byte(FInputs[Port].Buttons shr 8);
        FPIF[Answer + 1] := Byte(FInputs[Port].Buttons and $FF);
        FPIF[Answer + 2] := Byte((Integer(FInputs[Port].StickX) + 256) and $FF);
        FPIF[Answer + 3] := Byte((Integer(FInputs[Port].StickY) + 256) and $FF);
      end
      else
        FPIF[Pos + 1] := Rx or $80;
    end;
    Pos := Answer + Rx;
    Inc(Port);
  end;
end;

procedure TN64Console.SIDMA(Writing: Boolean);
begin
  if FSITransfer.Active then
  begin
    FReg[7, 6] := FReg[7, 6] or 8;
    Exit
  end;
  FSITransfer := Default(TN64SITransfer);
  FSITransfer.Active := True;
  FSITransfer.Writing := Writing;
  FSITransfer.RAM := FReg[7, 0] and $FFFFF8;
  if not Writing then
  begin
    ReadPIFControllers;
    for var I := 0 to 63 do
      FSITransfer.Data[I] := FPIF[I];
  end;
  FReg[7, 6] := FReg[7, 6] or 1;
  // Sixteen four-byte beats: timing model is explicit and deterministic.
  // PIF/joybus command execution is a separate action after the write DMA.
  FTimeline.Schedule(TN64EventKind.SITransfer, 256);
  if TraceEnabled then
    Trace(TN64TraceKind.DMAStart, FCPU.PC, $04800000, FSITransfer.RAM);
end;

function TN64Console.InterruptPending: Boolean;
begin
  Result := (FReg[2, 2] and FReg[2, 3]) <> 0;
end;

function TN64Console.ReadHidden(Address: Cardinal): Byte;
begin
  if Address < Cardinal(Length(FRAM)) then
    Result := ReadHiddenRAM(Address)
  else
    Result := 0;
end;

procedure TN64Console.WriteHidden(Address: Cardinal; Value: Byte);
begin
  if Address < Cardinal(Length(FRAM)) then
    WriteHiddenRAM(Address, Value);
end;

function TN64Console.GuestTick: UInt64;
begin
  if FTimeline = nil then
    Result := 0
  else
    Result := FTimeline.Now;
end;

function TN64Console.VideoClock: Cardinal;
begin
  Result := 48681812;
  if FData[$3E] = $42 then
    Result := 48628316
  else if FramesPerSecond = 50 then
    Result := 49656530;
end;

procedure TN64Console.ScheduleVI;
begin
  // H_SYNC is the video oscillator period, not a CPU instruction count.
  var Numerator := UInt64(93750000) * ((FReg[3, 7] and $FFF) + 1) + FVIPhase;
  var Denominator := UInt64(VideoClock) * 2;
  var Delay := Numerator div Denominator;
  FVIPhase := Numerator mod Denominator;
  if Delay = 0 then
    Delay := 1;
  FTimeline.Schedule(TN64EventKind.VIHalfLine, Delay);
end;

procedure TN64Console.ScheduleOutput;
begin
  Inc(FAudioClock, 93750000);
  var Delay := Cardinal(FAudioClock div 48000);
  FAudioClock := FAudioClock mod 48000;
  FTimeline.Schedule(TN64EventKind.OutputSample, Delay);
end;

procedure TN64Console.ScheduleAI;

  function AddMod(A, B, Modulus: UInt64): UInt64;
  begin
    if A >= Modulus - B then
      Result := A - (Modulus - B)
    else
      Result := A + B;
  end;

  function MultiplyMod(A: UInt64; B: Cardinal; Modulus: UInt64): UInt64;
  begin
    Result := 0;
    A := A mod Modulus;
    while B <> 0 do
    begin
      if (B and 1) <> 0 then
        Result := AddMod(Result, A, Modulus);
      A := AddMod(A, A, Modulus);
      B := B shr 1;
    end;
  end;

begin
  if ((FReg[4, 2] and 1) = 0) or FTimeline.Pending(TN64EventKind.AIConsume) then
    Exit;
  // An empty, silent FIFO has no observable completion event. Preserve the DAC
  // oscillator through its anchor instead of scheduling millions of empty ticks.
  if (FAILength = 0) and (FLastLeft = 0) and (FLastRight = 0) then
    Exit;
  var Period := UInt64(93750000) * ((FReg[4, 4] and $3FFF) + 1);
  var Phase := MultiplyMod(FTimeline.Now - FAIAnchorTick, VideoClock, Period);
  var Numerator := Period - Phase;
  var Delay := (Numerator + VideoClock - 1) div VideoClock;
  FTimeline.Schedule(TN64EventKind.AIConsume, Delay);
end;

procedure TN64Console.ScheduleRSP;
begin
  if ((FReg[0, 4] and 1) <> 0) or FTimeline.Pending(TN64EventKind.RSPClock) then
    Exit;
  FoldRSPPhase;
  FRSPPhase := FRSPPhase xor 1;
  // 62.5 MHz RCP versus 93.75 MHz CPU: alternate two and one CPU clocks.
  var Delay: Cardinal := 1;
  if Mod3(FTimeline.Now) = 0 then
    Delay := 2;
  FTimeline.Schedule(TN64EventKind.RSPClock, Delay);
end;

procedure TN64Console.ConsumeAI;
begin
  if (FReg[4, 2] and 1) = 0 then
    Exit;
  if FAILength = 0 then
  begin
    FLastLeft := 0;
    FLastRight := 0
  end
  else
  begin
    var Address := (FAIAddress + FAIProgress) and $FFFFFF;
    FLastLeft := SmallInt(SignedValue(SX((Cardinal(Read8(Address)) shl 8) or Read8(Address + 1), 16)));
    FLastRight := SmallInt(SignedValue(SX((Cardinal(Read8(Address + 2)) shl 8) or Read8(Address + 3), 16)));
    Inc(FAIProgress, 4);
    if FAIProgress = FAILength then
    begin
      SetInterrupts(FReg[2, 2] or 4);
      FAIAddress := FAINextAddress;
      FAILength := FAINextLength;
      FAINextLength := 0;
      FAIProgress := 0;
      if TraceEnabled then
        Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04500004, FAILength);
    end;
  end;
  ScheduleAI;
end;

procedure TN64Console.SPTransferBeat;
begin
  if not FSPTransfer.Active then
    Exit;
  // A transfer whose fences the window lifted moves the bytes it took then
  // (LiftRSPTransfer); into DMEM, only if RDRAM still holds them, else the
  // RSP goes back to this point first and the beat is an ordinary one.
  // A transfer of the window being run: while a beat of it runs here, a
  // window on the RSP thread cannot lift it (State 1).
  var Lifted := -1;
  var Window := -1;
  var Shared := FRSPInFlight;
  if FRSPRun > 0 then
  begin
    var I := Integer(FSPDone - FRSPDoneBase);
    if (I >= 0) and (I < FRSPDMACount) then
    begin
      Window := I;
      if not Shared then
      begin
        if FRSPDMAs[I].State <> 0 then
          Lifted := I;
      end
      // State 2 is the final handoff: Data is immutable and only this
      // thread advances Beats afterwards. No ownership CAS is needed.
      else if SharedRead(FRSPDMAs[I].State) = 2 then
        Lifted := I
      else if TInterlocked.CompareExchange(FRSPDMAs[I].State, 1, 0) <> 0 then
      begin
        // Lifted, or being lifted: acquire the final publication of Data.
        while SharedRead(FRSPDMAs[I].State) <> 2 do
          YieldProcessor;
        Lifted := I;
      end;
    end;
  end;
  // The beat's eight bytes are aligned (SPDMA, ValidateState): one 64-byte
  // line of SP memory and of RDRAM, without wrapping. RDRAM ends at 8 MB:
  // the rest of the 16 MB reads 0 and ignores writes.
  var local := (FSPTransfer.local and $1000) or ((FSPTransfer.local + FSPTransfer.Position) and $FFF);
  var RAM := (FSPTransfer.RAM + FSPTransfer.Position) and $FFFFFF;
  var Bytes: UInt64 := 0;
  if not FSPTransfer.Writing and (RAM < $800000) then
  begin
    // An aligned eight-byte beat cannot cross a page or the end of RDRAM.
    // Keep the same RDP fence as ReadRAMBytes, without its generic range
    // loop and variable-sized Move on every beat.
    if FRDPPending and (FRDPWrites[RAM shr RDPPageShift] > FRDPDone) then
      SyncRDPRead(RAM, 8);
    Bytes := PUInt64(@FRAM[RAM])^;
  end;
  if (Lifted >= 0) and not FSPTransfer.Writing then
  begin
    var Same := Bytes = PUInt64(@FRSPDMAs[Lifted].Data[(FRSPDMAs[Lifted].Beats - FRSPDMAs[Lifted].DataFirst) * 8])^;
    if FRSPStress and ((StressNoise and 63) = 0) then
      // Test mode: as if RDRAM had changed.
      Same := False;
    if not Same then
    begin
      Inc(FRSPStats.BeatsChanged);
      RewindRSP;
      Lifted := -1;
      Window := -1;
    end;
  end;
  var Logged := (FRSPRun > 0) and not FSPTransfer.Writing;
  if Logged then
  begin
    if FRSPBeatCount = Length(FRSPBeats) then
      SetLength(FRSPBeats, FRSPBeatCount * 2 + 16);
    FRSPBeats[FRSPBeatCount].Position := FRSPCommitted + FTimeline.SyncAhead;
    FRSPBeats[FRSPBeatCount].local := (FSPTransfer.local + FSPTransfer.Position) and $FFF;
    // Before its bytes change: the eight bytes lie in one line.
    FRSPBeats[FRSPBeatCount].Unsaved := not FRSP.LineSaved(FRSPBeats[FRSPBeatCount].local);
    // (Old keeps DMEM exact while a rewind's replay runs, a guard: the
    // replayed clocks never read these bytes, fenced while the transfer was
    // pending, and every logged beat is back by the replay's end.)
    PUInt64(@FRSPBeats[FRSPBeatCount].Old)^ := PUInt64(@FSP[FRSPBeats[FRSPBeatCount].local])^;
  end;
  // A lifted transfer's bytes as the window took them.
  var Taken: PByte := nil;
  if Lifted >= 0 then
    Taken := @FRSPDMAs[Lifted].Data[(FRSPDMAs[Lifted].Beats - FRSPDMAs[Lifted].DataFirst) * 8];
  if FSPTransfer.Writing then
  begin
    if Taken = nil then
      Taken := @FSP[local];
    if RAM < $800000 then
      WriteRAMBytes(RAM, Taken, 8);
  end
  else if Lifted < 0 then
    if local < $1000 then
      PUInt64(@FSP[local])^ := Bytes
    else
      WriteSPBytes(local, @Bytes, 8);
  if Logged then
  begin
    // Into DMEM while the RSP runs ahead (the window kept off these bytes,
    // or wrote them itself when it lifted the transfer's fences).
    if Lifted >= 0 then
      PUInt64(@FRSPBeats[FRSPBeatCount].Data)^ := PUInt64(Taken)^
    else
      PUInt64(@FRSPBeats[FRSPBeatCount].Data)^ := PUInt64(@FSP[FRSPBeats[FRSPBeatCount].local])^;
    FRSPBeats[FRSPBeatCount].Applied := Lifted < 0;
    Inc(FRSPBeatCount);
  end;
  if (Window >= 0) and (not Shared or (Lifted >= 0)) then
    Inc(FRSPDMAs[Window].Beats)
  else if Window >= 0 then
  begin
    // Counted before the transfer is free again.
    TInterlocked.Increment(FRSPDMAs[Window].Beats);
    if Lifted < 0 then
      TInterlocked.Exchange(FRSPDMAs[Window].State, 0);
  end;
  Inc(FSPTransfer.Position, 8);
  if FSPTransfer.Position = FSPTransfer.Size then
  begin
    FSPTransfer.local := (FSPTransfer.local and $1000) or ((FSPTransfer.local + FSPTransfer.Size) and $FFF);
    FSPTransfer.RAM := (FSPTransfer.RAM + FSPTransfer.Size) and $FFFFFF;
    Dec(FSPTransfer.Blocks);
    FSPTransfer.Position := 0;
    if FSPTransfer.Blocks > 0 then
      FSPTransfer.RAM := (FSPTransfer.RAM + FSPTransfer.Skip) and $FFFFFF;
  end;
  FReg[0, 0] := FSPTransfer.local;
  FReg[0, 1] := FSPTransfer.RAM;
  if FSPTransfer.Blocks = 0 then
  begin
    FReg[0, 2] := (FSPTransfer.Control and $FF800000) or $FF8;
    FReg[0, 3] := FReg[0, 2];
    if TraceEnabled then
      Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04040000, FSPTransfer.RAM);
    Inc(FSPDone);
    FSPDoneCount := FSPDone;
    FSPTransfer := FSPQueued;
    FSPQueued := Default(TN64SPTransfer);
    FReg[0, 5] := 0;
    FReg[0, 4] := FReg[0, 4] and not 8;
    if not FSPTransfer.Active then
    begin
      FReg[0, 6] := 0;
      FReg[0, 4] := FReg[0, 4] and not 4;
      Exit
    end;
    FReg[0, 0] := FSPTransfer.local;
    FReg[0, 1] := FSPTransfer.RAM;
    FReg[0, 2 + Ord(FSPTransfer.Writing)] := FSPTransfer.Control;
  end;
  // Indexed eight-byte DMA beats; bus arbitration remains a functional model.
  var Delay: Cardinal := 1;
  if Mod3(FTimeline.Now) = 0 then
    Delay := 2;
  FTimeline.Schedule(TN64EventKind.SPTransfer, Delay);
end;

procedure TN64Console.MarkSPTransfer(const Transfer: TN64SPTransfer; Number: Int64);
begin
  // Transfer (the Number-th, counting completed ones) marks the RDRAM pages
  // of the bytes it has yet to move and the skips between its blocks (the
  // address wrapping in 16 MB; beyond 8 MB there are none) until it
  // completes.
  var Start, Count: Cardinal;
  RAMSpan(Transfer, Start, Count);
  var At := Start;
  while Count > 0 do
  begin
    var Piece := Min(Count, $1000000 - At);
    if At < $800000 then
      for var Page := At shr RDPPageShift to (Min(At + Piece, Cardinal($800000)) - 1) shr RDPPageShift do
        if Transfer.Writing then
          FSPWrites[Page] := Number
        else
          FSPReads[Page] := Number;
    Dec(Count, Piece);
    At := (At + Piece) and $FFFFFF;
  end;
  if Number > FSPMarked then
    FSPMarked := Number;
end;

procedure TN64Console.MarkSPTransfers;
begin
  // The marks anew (reset, a state loaded): the transfers not complete.
  FillChar(FSPWrites, SizeOf(FSPWrites), 0);
  FillChar(FSPReads, SizeOf(FSPReads), 0);
  FSPDoneCount := FSPDone;
  FSPMarked := FSPDone;
  if FSPTransfer.Active then
    MarkSPTransfer(FSPTransfer, FSPDone + 1);
  if FSPQueued.Active then
    MarkSPTransfer(FSPQueued, FSPDone + 2);
end;

procedure TN64Console.PreparePIBlock;
begin
  // PI first fills a 128-byte cartridge buffer. RDRAM rows end at 0x800.
  // The first unaligned block shortens the write twice; these holes and the
  // following short block are visible in rasky's physical-hardware vectors.
  var Misalignment := FPITransfer.BlockRAM and 7;
  var RowRemaining := $800 - (FPITransfer.BlockRAM and $7FF);
  FPITransfer.BlockLength := Min(FPITransfer.Length - FPITransfer.Position,
    Min(FPITransfer.MaxBlockSize - Misalignment, RowRemaining));
  var Written := Integer(FPITransfer.BlockLength) - Integer(Misalignment);
  if Written < 0 then
    Written := 0;
  if not (FPITransfer.FirstBlock and (FPITransfer.BlockLength < 127 - Misalignment)) then
    Written := (Written + 1) and not 1;
  FPITransfer.BlockWriteSize := Cardinal(Written);
  FPITransfer.BlockRead := 0;
  FPITransfer.BlockWritten := 0;
  FPITransfer.Stage := 0;
end;

function TN64Console.PIBeatCycles: Cardinal;
begin
  var RCPCycles: Cardinal;
  if FPITransfer.Stage = 1 then
    RCPCycles := 1 // peak RDRAM write burst: 8 bytes/RCP clock
  else
  begin
    var Bytes := Min(Cardinal(8), FPITransfer.Length - FPITransfer.Position);
    if not FPITransfer.Writing and not FPITransfer.Flash then
      Bytes := Min(Cardinal(8), ((FPITransfer.BlockLength + 1) and not Cardinal(1)) - FPITransfer.BlockRead);
    RCPCycles := ((Bytes + 1) div 2) * (FPITransfer.PulseWidth + FPITransfer.ReleaseDuration + 2);
    var Page := Cardinal(1) shl (FPITransfer.PageSize + 2);
    for var I := 0 to Integer((Bytes + 1) div 2) - 1 do
    begin
      var Offset := FPITransfer.Position + Cardinal(I * 2);
      if (Offset = 0) or ((Add32(FPITransfer.Cart, Offset) and (Page - 1)) = 0) then
        Inc(RCPCycles, FPITransfer.Latency + 1);
    end;
  end;
  var Numerator := RCPCycles * 3 + FPITransfer.ClockPhase;
  Result := Numerator div 2;
  FPITransfer.ClockPhase := Numerator and 1;
  if Result = 0 then
    Result := 1;
end;

procedure TN64Console.CompletePI;
begin
  if FPITransfer.Flash and FPITransfer.Writing and (FPITransfer.FlashMode = 2) then
    FFlashReady := FPITransfer.Length >= 128;
  FPITransfer.Active := False;
  FReg[5, 4] := (FReg[5, 4] and not 1) or 8;
  SetInterrupts(FReg[2, 2] or $10);
  if TraceEnabled then
    Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04600000, FPITransfer.Length);
end;

procedure TN64Console.FinishPIBlock;
begin
  var Misalignment := FPITransfer.BlockRAM and 7;
  var RowRemaining := $800 - (FPITransfer.BlockRAM and $7FF);
  FPITransfer.BlockRAM := (FPITransfer.BlockRAM + FPITransfer.BlockWriteSize + 7) and $FFFFF8;
  FReg[5, 0] := FPITransfer.BlockRAM;
  if FPITransfer.BlockLength <= 8 then
    FReg[5, 3] := 127 - Misalignment
  else
    FReg[5, 3] := 127;
  FPITransfer.FirstBlock := False;
  if RowRemaining < 8 then
    FPITransfer.MaxBlockSize := 128 - Misalignment
  else
    FPITransfer.MaxBlockSize := 128;
  if FPITransfer.Position >= FPITransfer.Length then
    CompletePI
  else
    PreparePIBlock;
end;

procedure TN64Console.PITransferBeat;
begin
  if not FPITransfer.Active then
    Exit;
  if not FPITransfer.Writing and not FPITransfer.Flash then
  begin
    if FPITransfer.Stage = 0 then
    begin
      var Bytes := Min(Cardinal(8), ((FPITransfer.BlockLength + 1) and not Cardinal(1)) - FPITransfer.BlockRead);
      for var I := 0 to Integer(Bytes) - 1 do
        FPITransfer.Buffer[FPITransfer.BlockRead + Cardinal(I)] := Read8(Add32(FPITransfer.Cart, FPITransfer.Position + Cardinal(I)));
      Inc(FPITransfer.Position, Bytes);
      Inc(FPITransfer.BlockRead, Bytes);
      FReg[5, 1] := Add32(FPITransfer.Cart, FPITransfer.Position);
      if FPITransfer.BlockRead = ((FPITransfer.BlockLength + 1) and not Cardinal(1)) then
        if FPITransfer.BlockWriteSize = 0 then
          FinishPIBlock
        else
          FPITransfer.Stage := 1;
    end
    else
    begin
      var Bytes := Min(Cardinal(8), FPITransfer.BlockWriteSize - FPITransfer.BlockWritten);
      for var I := 0 to Integer(Bytes) - 1 do
        Write8((FPITransfer.BlockRAM + FPITransfer.BlockWritten + Cardinal(I)) and $FFFFFF,
          FPITransfer.Buffer[FPITransfer.BlockWritten + Cardinal(I)]);
      Inc(FPITransfer.BlockWritten, Bytes);
      FReg[5, 0] := (FPITransfer.BlockRAM + FPITransfer.BlockWritten) and $FFFFFF;
      if FPITransfer.BlockWritten = FPITransfer.BlockWriteSize then
        FinishPIBlock;
    end;
    if FPITransfer.Active then
      FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
    Exit;
  end;
  // Cartridge writes and Flash's status/data protocol retain their own path.
  var Bytes := Min(Cardinal(8), FPITransfer.Length - FPITransfer.Position);
  for var I := 0 to Integer(Bytes) - 1 do
  begin
    var Offset := FPITransfer.Position + Cardinal(I);
    var RAM := (FPITransfer.RAM + Offset) and $FFFFFF;
    var Cart := Add32(FPITransfer.Cart, Offset);
    if FPITransfer.Flash then
    begin
      if FPITransfer.Writing then
      begin
        if (FPITransfer.FlashMode = 2) and (Offset < 128) then
          FFlashBuffer[Offset] := Read8(RAM);
      end
      else
      begin
        var Value: Byte := 0;
        if FPITransfer.FlashMode = 4 then
          Value := Byte((FPITransfer.FlashStatus shr ((7 - (Offset and 7)) * 8)) and $FF)
        else if FPITransfer.FlashMode = 3 then
        begin
          var Address := UInt64(FPITransfer.Cart - $08000000) * 2 + Offset;
          if Address < Cardinal(Length(FFlashData)) then
            Value := FFlashData[Address]
          else
            Value := $FF;
        end;
        Write8(RAM, Value);
      end;
    end
    else
      Write8(Cart, Read8(RAM));
  end;
  Inc(FPITransfer.Position, Bytes);
  FReg[5, 0] := (FPITransfer.RAM + FPITransfer.Position) and $FFFFFF;
  FReg[5, 1] := Add32(FPITransfer.Cart, FPITransfer.Position);
  if FPITransfer.Position = FPITransfer.Length then
    CompletePI
  else
    FTimeline.Schedule(TN64EventKind.PITransfer, PIBeatCycles);
end;

procedure TN64Console.SITransferBeat;
begin
  if not FSITransfer.Active then
    Exit;
  for var I := 0 to 3 do
  begin
    var Offset := FSITransfer.Position + Cardinal(I);
    var RAM := (FSITransfer.RAM + Offset) and $FFFFFF;
    if FSITransfer.Writing then
      FSITransfer.Data[Offset] := Read8(RAM)
    else
      Write8(RAM, FSITransfer.Data[Offset]);
  end;
  Inc(FSITransfer.Position, 4);
  if FSITransfer.Position = 64 then
  begin
    if FSITransfer.Writing then
    begin
      for var I := 0 to 63 do
        FPIF[I] := FSITransfer.Data[I];
      PIFCommand
    end;
    FSITransfer.Active := False;
    FReg[7, 6] := (FReg[7, 6] and not 1) or $1000;
    SetInterrupts(FReg[2, 2] or 2);
    if TraceEnabled then
      Trace(TN64TraceKind.DMAComplete, FCPU.PC, $04800000, FSITransfer.RAM);
  end
  else
    FTimeline.Schedule(TN64EventKind.SITransfer, 256);
end;

procedure TN64Console.RenderFrame(ScanoutField: Integer; Notify: Boolean);
begin
  var Registers: array[0..13] of Cardinal;
  for var I := 0 to 13 do
    Registers[I] := FReg[3, I];
  Registers[4] := Cardinal((FLine and not 1) or ScanoutField);
  if FVIThreaded then
  begin
    // The slot's bus is the VI thread's until the field before last is
    // done. It gets the RDRAM the field reads, as RDP work queued so far
    // leaves it.
    var Slot := FVIPut;
    // (Only a VI thread two fields behind is still there: xbustest scene 7
    // does not get it that far, its CPU waiting for each copy.)
    WaitVISlot(Slot);
    Move(Registers, FVISlots[Slot].Registers, SizeOf(Registers));
    FVISlots[Slot].Frame := FFrame;
    FVISlots[Slot].Notify := Notify;
    FVISlots[Slot].Error := '';
    if FVIThread = nil then
      FVIThread := TVIThread.Create(Self);
    FVIBusy[Slot] := True;
    FVIPut := 1 - Slot;
    var Target := FVISlots[Slot].Bus;
    var Address, Count, First, Last: Cardinal;
    var Span := TN64VI.SourceSpan(Registers, Address, Count);
    if Span and (FRDPWorker <> nil) and RDPPendingRange(Address, Count, First, Last) then
    begin
      // RDP lists queued so far draw some lines of it: the rest is copied
      // now, and the bands copy those lines as soon as they are done with
      // the lists, before any list queued later, and start the VI thread.
      // Until then writes there wait for that copy (a list of its own that
      // reads the bytes).
      CopyRAMTo(Target, Address, First - Address);
      CopyRAMTo(Target, Last, Address + Count - Last);
      Inc(FRDPList);
      FRDPWorker.QueueCopy(Target, First, Last - First, FVISlots[Slot].Start);
      MarkRDPRead(First, Last - First);
      FRDPPending := True;
      Inc(FVICopies);
      Exit;
    end;
    if Span then
      CopyRAMTo(Target, Address, Count);
    FVISlots[Slot].Start.SetEvent;
    Exit;
  end;
  // Render returns a fresh array, so frames already handed out stay intact.
  FVI.Render(Registers, FCurrentFrame.Width, FCurrentFrame.Height, FCurrentFrame.Pixels);
  FCurrentFrame.FrameNumber := FFrame;
  FrameRendered(Notify);
end;

procedure TN64Console.FrameRendered(Notify: Boolean);
begin
  FCurrentFrame.FramesPerSecond := FramesPerSecond;
  if Notify and Assigned(FOnFrame) then
    FOnFrame(FCurrentFrame);
end;

procedure TN64Console.WaitVI;
begin
  // Both slots, the older first (the VI thread renders them in turn).
  WaitVISlot(FVIPut);
  WaitVISlot(1 - FVIPut);
end;

procedure TN64Console.WaitVISlot(Slot: Integer);
begin
  if not FVIBusy[Slot] then
    Exit;
  var Started := TStopwatch.GetTimeStamp;
  FVISlots[Slot].Done.WaitFor(INFINITE);
  Inc(FVIWaitTime, TStopwatch.GetTimeStamp - Started);
  CompleteVISlot(Slot);
end;

procedure TN64Console.CompleteVISlot(Slot: Integer);
begin
  FVIBusy[Slot] := False;
  if FVISlots[Slot].Error <> '' then
    raise EN64Unsupported.Create('VI thread: ' + FVISlots[Slot].Error);
  if FVISlots[Slot].Output.FrameNumber >= FCurrentFrame.FrameNumber then
    FCurrentFrame := FVISlots[Slot].Output;
end;

procedure TN64Console.SetVIThreaded(Value: Boolean);
begin
  if Value = FVIThreaded then
    Exit;
  WaitVI;
  if Value then
  begin
    for var S := 0 to 1 do
      if FVISlots[S].Bus = nil then
      begin
        FVISlots[S].Bus := TN64RAMBus.Create;
        FVISlots[S].Start := TEvent.Create(nil, False, False, '');
        FVISlots[S].Done := TEvent.Create(nil, False, False, '');
      end;
  end
  else
    FVI.Source := Self;
  FVIThreaded := Value;
end;

{ TN64Console.TVIThread }

constructor TN64Console.TVIThread.Create(Owner: TN64Console);
begin
  FOwner := Owner;
  inherited Create(False);
end;

procedure TN64Console.TVIThread.Execute;
begin
  // Made by the emulation thread: where that is pinned (Linux and Android
  // pass a thread's affinity on to the threads it starts), with the RDP
  // bands instead; before they are placed, off the emulation thread's core
  // and the RSP thread's.
  {$IF DEFINED(LINUX) or DEFINED(ANDROID)}
  if FOwner.FPinned then
  begin
    var CPUs := FOwner.FBandCPUs;
    if CPUs.IsEmpty then
    begin
      CPUs := FOwner.FUnpinned;
      for var C := 0 to Min(1, High(FOwner.FCores)) do
        for var W := 0 to High(CPUs.Bits) do
          CPUs.Bits[W] := CPUs.Bits[W] and not FOwner.FCores[C].CPUs.Bits[W];
    end;
    if not CPUs.IsEmpty then
    begin
      var Previous: TN64CPUSet;
      PinCurrentThread(CPUs, Previous);
    end;
  end;
  {$ENDIF}
  var Slot := 0;
  while True do
  begin
    FOwner.FVISlots[Slot].Start.WaitFor(INFINITE);
    if Terminated then
      Break;
    try
      FOwner.FVI.Source := FOwner.FVISlots[Slot].Bus;
      // Only this slot is written by VI. The emulation thread publishes it
      // after observing Done, so polling never races with a new scanout.
      FOwner.FVI.Render(FOwner.FVISlots[Slot].Registers,
        FOwner.FVISlots[Slot].Output.Width, FOwner.FVISlots[Slot].Output.Height,
        FOwner.FVISlots[Slot].Output.Pixels);
      FOwner.FVISlots[Slot].Output.FrameNumber := FOwner.FVISlots[Slot].Frame;
      FOwner.FVISlots[Slot].Output.FramesPerSecond := FOwner.FramesPerSecond;
      if FOwner.FVISlots[Slot].Notify and Assigned(FOwner.FOnFrame) then
        FOwner.FOnFrame(FOwner.FVISlots[Slot].Output);
    except
      on E: Exception do
        FOwner.FVISlots[Slot].Error := E.ClassName + ': ' + E.Message;
    end;
    FOwner.FVISlots[Slot].Done.SetEvent;
    Slot := 1 - Slot;
  end;
end;

procedure TN64Console.HandleEvent(Kind: TN64EventKind);
begin
  case Kind of
    TN64EventKind.VIHalfLine:
      begin
        Inc(FLine);
        if FLine >= Integer(Max(Cardinal(1), FReg[3, 6] and $3FF)) then
        begin
          // ORIGIN/scale describe the field just scanned. CURRENT must still
          // identify that physical field for VI destination parity, although
          // the guest register advances immediately into the next field.
          var CompletedPhysicalField := FField;
          FLine := 0;
          if (FReg[3, 0] and $40) <> 0 then
            FField := FField xor 1
          else
            FField := 0;
          FFrame := Add64(FFrame, 1);
          if FVideoOutputEnabled then
            RenderFrame(CompletedPhysicalField, True);
        end;
        if FLine = Integer(FReg[3, 3] and $3FF) then
          SetInterrupts(FReg[2, 2] or 8);
        ScheduleVI;
      end;
    TN64EventKind.OutputSample:
      begin
        AudioTick;
        ScheduleOutput
      end;
    TN64EventKind.AIConsume:
      ConsumeAI;
    TN64EventKind.SPTransfer:
      SPTransferBeat;
    TN64EventKind.PITransfer:
      PITransferBeat;
    TN64EventKind.SITransfer:
      SITransferBeat;
    TN64EventKind.RSPClock:
      begin
        // The window's clocks before this one are all handled (in order).
        if FRSPRun > 0 then
        begin
          Inc(FRSPCommitted, FRSPSegment);
          if FRSPInFlight then
          begin
            // The RSP thread ran this clock (checked or taken as it is), or
            // the window ended before it.
            if AdvanceThreadedWindow then
              Exit;
          end
          else if FRSPCommitted < FRSPRun then
          begin
            // The RSP ran this clock ahead with a predicted MFC0.
            CheckRSPPrediction;
            Exit;
          end;
          ApplySettledRSPWrites(FRSPCommitted);
          FRSPRun := 0;
        end;
        FRSP.EndAhead;
        // IMEM transfers own the instruction bank until their beat completes.
        if not (FSPTransfer.Active and not FSPTransfer.Writing and ((FSPTransfer.local and $1000) <> 0)) then
          RunRSP;
        ScheduleRSP;
        StartRSPAhead;
      end;
    TN64EventKind.DPInterrupt:
      begin
        SetInterrupts(FReg[2, 2] or $20);
        FReg[1, 3] := FReg[1, 3] and not $20
      end;
  end;
end;

procedure TN64Console.AdvanceTime(Cycles: Cardinal);
begin
  var Now := FTimeline.Now;
  if UInt64(Cycles) > High(UInt64) - Now then
    RaiseClockOverflow;
  var Target := Now + Cycles;
  if FTimeline.NextDue > Target then
    FTimeline.AdvanceTo(Target)
  else
    ProcessEvents(Target);
end;

class procedure TN64Console.RaiseClockOverflow;
begin
  raise ERangeError.Create('N64 guest clock overflow');
end;

procedure TN64Console.ProcessEvents(Target: UInt64);
begin
  // (No Pop once nothing is due: run-ahead RSP clocks it would hand over
  // take their sequence numbers before anything else does anyway.)
  while (FTimeline.NextDue <> High(UInt64)) and (FTimeline.NextDue <= Target) do
  begin
    FTimeline.AdvanceTo(FTimeline.NextDue);
    var Event: TN64Event;
    while (FTimeline.NextDue <= FTimeline.Now) and FTimeline.Pop(Event) do
      HandleEvent(Event.Kind);
  end;
  FTimeline.AdvanceTo(Target);
end;

procedure TN64Console.AudioTick;
begin
  // Guest DAC consumption has its own clock; this is only the 48 kHz sink.
  var N := FSampleCount;
  if N < 16384 then
  begin
    if N + 2 > Length(FSample) then
      SetLength(FSample, Max(N + 2, Length(FSample) * 2));
    FSample[N] := FLastLeft;
    FSample[N + 1] := FLastRight;
    FSampleCount := N + 2
  end;
end;

procedure TN64Console.RunInstructions(Count: Integer);
begin
  if Count < 0 then
    raise EArgumentOutOfRangeException.Create('Negative N64 instruction budget');
  // Once the RDP bands have caught up, RDRAM accesses skip their checks.
  if FRDPPending then
    RefreshRDP;
  // This thread's floating point may serve the CPU's (checked each time: the
  // caller's thread may change).
  FCPU.HostFloat := FHostFloat and SFHostReady;

  var Remaining := Count;
  while Remaining > 0 do
  begin
    if FRSPStress then
      StressRSP;
    if FTimeline.NextDue <= FTimeline.Now then
      AdvanceTime(0);
    var Executed := 0;
    if FCPU.IdleCandidate then
    begin
      Executed := RunIdle(Remaining);
      if Executed > 0 then
      begin
        Dec(Remaining, Executed);
        Continue;
      end;
    end;
    if (Executed = 0) and not FRSPStress and not TraceEnabled then
    begin
      // Instructions up to the next event (or a device access) in one go:
      // time passes as after each of them (SyncDevice sets it for an access).
      // SP DMA beats due meanwhile wait: nothing the instructions do can tell
      // (RDRAM pages a transfer not complete touches are as devices to them,
      // TN64Bus.SPReadHazard), and they run after the batch, in their places
      // among the events, as they would have before it went on.
      var Start := FTimeline.Now;
      FBatchStart := Start;
      var Cycles: UInt64;
      Executed := FCPU.RunBatch(Remaining, FTimeline.NextHard - Start, Cycles);
      AdvanceTime(Cardinal(Start + Cycles - FTimeline.Now));
      Dec(Remaining, Executed);
      Continue;
    end;
    if Executed = 0 then
    begin
      FCPU.Step;
      Executed := 1
    end;
    AdvanceTime(FCPU.CyclesConsumed);
    Dec(Remaining, Executed);
  end;
end;

function TN64Console.RunIdle(Budget: Integer): Integer;
begin
  // The CPU spins in an idle loop validated by IdleLimit: one instruction per
  // PClock, invisible to devices. Run the device events it would interleave
  // with, in order, and apply the elapsed instructions at the end. Stop where
  // the next instruction would react (interrupt) or the loop was overwritten.
  Result := 0;
  var Limit := FCPU.IdleLimit;
  if Limit > Budget then
    Limit := Budget;
  if Limit < 1 then
    Exit;
  var Start := FTimeline.Now;
  var Pending := FInterruptLine;
  var Elapsed: UInt64 := 0;
  while Elapsed < UInt64(Limit) do
  begin
    var Due := FTimeline.NextDue;
    Pending := FInterruptLine;
    if Due - Start > UInt64(Limit) then
    begin
      Elapsed := UInt64(Limit);
      FTimeline.AdvanceTo(Start + Elapsed);
      Break;
    end;
    FTimeline.AdvanceTo(Due);
    var Event: TN64Event;
    while FTimeline.Pop(Event) do
      HandleEvent(Event.Kind);
    Elapsed := Due - Start;
    // CP0 is static while idle; COUNT is bounded by IdleLimit. Devices can
    // only introduce a CPU interrupt by changing the MI interrupt line.
    if ((FInterruptLine <> Pending) and FCPU.IdleWouldInterrupt(FInterruptLine)) or
      not FCPU.IdleCodeIntact then
      Break;
  end;
  if Elapsed > 0 then
    FCPU.ApplyIdle(Integer(Elapsed), Pending);
  Result := Integer(Elapsed);
end;

procedure TN64Console.SyncDevice(Elapsed: UInt64);
begin
  // The SP DMA beats the batch ran past (the only events due within it)
  // first, in their places in time.
  ProcessEvents(FBatchStart + Elapsed);
end;

procedure TN64Console.RunCycles(Cycles: Cardinal);
begin
  if UInt64(Cycles) > High(UInt64) - FTimeline.Now then
    raise ERangeError.Create('N64 cycle budget overflow');
  var Finish := FTimeline.Now + Cycles;
  while FTimeline.Now < Finish do
    RunInstructions(1);
end;

procedure TN64Console.RunFrame;
begin
  var Start := FFrame;
  while FFrame = Start do
    RunInstructions(512);
end;

function TN64Console.FramesPerSecond: Double;
begin
  if FData[$3E] in [$44, $46, $48, $49, $4C, $50, $53, $55, $57, $58, $59, $5A] then
    Result := 50
  else
    Result := 60;
end;

function TN64Console.GetFrame: TEmulatorFrame;
begin
  WaitVI;
  if Length(FCurrentFrame.Pixels) = 0 then
  begin
    RenderFrame(FField, False);
    WaitVI;
  end;
  Result := FCurrentFrame;
end;

function TN64Console.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  // Older first, as in WaitVI. Each Done is consumed exactly once.
  for var I := 0 to 1 do
  begin
    var Slot := (FVIPut + I) mod 2;
    if FVIBusy[Slot] and (FVISlots[Slot].Done.WaitFor(0) = wrSignaled) then
      CompleteVISlot(Slot);
  end;
  Frame := FCurrentFrame;
  Result := Length(Frame.Pixels) <> 0;
end;

procedure TN64Console.SetInputs(const Inputs: TN64Pads);
begin
  FInputs := Inputs
end;

function TN64Console.TakeSamples: TArray<SmallInt>;
begin
  Result := Copy(FSample, 0, FSampleCount);
  FSampleCount := 0
end;

function TN64Console.SaveBattery: TBytes;
const
  Magic: AnsiString = 'RMN64F01';
begin
  if not FFlashUsed then
    Result := Copy(FSave)
  else
  begin
    SetLength(Result, 8 + Length(FSave) + Length(FFlashData));
    for var I := 0 to 7 do
      Result[I] := Ord(Magic[I + 1]);
    for var I := 0 to High(FSave) do
      Result[8 + I] := FSave[I];
    for var I := 0 to High(FFlashData) do
      Result[8 + Length(FSave) + I] := FFlashData[I];
  end;
  FSaveDirty := False;
end;

procedure TN64Console.LoadBattery(const Data: TBytes);
const
  Magic: AnsiString = 'RMN64F01';
begin
  if Length(Data) = Length(FSave) then
    FSave := Copy(Data)
  else
  begin
    if Length(Data) <> 8 + Length(FSave) + Length(FFlashData) then
      raise EReadError.Create('Invalid N64 save size');
    for var I := 0 to 7 do
      if Data[I] <> Ord(Magic[I + 1]) then
        raise EReadError.Create('Invalid N64 save header');
    for var I := 0 to High(FSave) do
      FSave[I] := Data[8 + I];
    for var I := 0 to High(FFlashData) do
      FFlashData[I] := Data[8 + Length(FSave) + I];
    FFlashUsed := True;
  end;
  FSaveDirty := False;
end;

procedure TN64Console.SerializeState(State: TStateArchive);
begin
  // Saved or loaded, the VI and its frame are those of the last field, RDRAM
  // and the RDP state those of a finished queue.
  WaitVI;
  DrainRDP;
  // Band RDPs count only their own rows' clocks; the timing RDP has them all.
  if (FRDPWorker <> nil) and not FRDPTimingStale then
  begin
    if FRDPTiming.LazyClocks then
      ResolveRDPClocks;
    FRDP.SetWorkClocks(FRDPTiming.WorkClocks);
  end;
  FCPU.SerializeState(State);
  // The RSP exactly at the current point (no clock run ahead), and its phase.
  RewindRSP;
  FoldRSPPhase;
  FRSP.SerializeState(State);
  if State.Loading then
    FRSP.EndAhead;
  FRDP.SerializeState(State);
  if State.Loading then
    FRDPTimingStale := True;
  FVI.SerializeState(State);
  FTimeline.SerializeState(State);
  State.Field(FHiddenRAM[0], Length(FHiddenRAM));
  State.Field(FSPTransfer, SizeOf(FSPTransfer));
  State.Field(FSPQueued, SizeOf(FSPQueued));
  State.Field(FPITransfer, SizeOf(FPITransfer));
  State.Field(FSITransfer, SizeOf(FSITransfer));
  State.Field(FPendingSPAddress, SizeOf(FPendingSPAddress));
  State.Field(FPendingRAMAddress, SizeOf(FPendingRAMAddress));
  State.Field(FVIPhase, SizeOf(FVIPhase));
  State.Field(FAIDACPhase, SizeOf(FAIDACPhase));
  State.Field(FAIAnchorTick, SizeOf(FAIAnchorTick));
  State.Field(FRSPPhase, SizeOf(FRSPPhase));
  State.Field(FLastLeft, SizeOf(FLastLeft));
  State.Field(FLastRight, SizeOf(FLastRight));
  State.Field(FCurrentFrame.Width, SizeOf(FCurrentFrame.Width));
  State.Field(FCurrentFrame.Height, SizeOf(FCurrentFrame.Height));
  State.Field(FCurrentFrame.FrameNumber, SizeOf(FCurrentFrame.FrameNumber));
  State.Field(FCurrentFrame.FramesPerSecond, SizeOf(FCurrentFrame.FramesPerSecond));
  // Length returns NativeInt; the v4 on-disk count is always signed 32-bit.
  var PixelCount: Integer := Length(FCurrentFrame.Pixels);
  State.Field(PixelCount, SizeOf(PixelCount));
  if State.Loading then
  begin
    if (PixelCount < 0) or (PixelCount > 1024 * 1024) or
      (FCurrentFrame.Width < 0) or (FCurrentFrame.Width > 1024) or
      (FCurrentFrame.Height < 0) or (FCurrentFrame.Height > 1024) or
      (Int64(FCurrentFrame.Width) * FCurrentFrame.Height <> PixelCount) then
      raise EReadError.Create('Invalid N64 cached VI raster');
    SetLength(FCurrentFrame.Pixels, PixelCount);
  end;
  if PixelCount > 0 then
    State.Field(FCurrentFrame.Pixels[0], PixelCount * SizeOf(Cardinal));
  State.Field(FRAM[0], Length(FRAM));
  State.Field(FSP[0], Length(FSP));
  if State.Loading then
  begin
    RAMReplaced;
    SPLoaded;
  end;
  State.Field(FPIF[0], Length(FPIF));
  State.Field(FSave[0], Length(FSave));
  State.Field(FReg, SizeOf(FReg));
  if State.Loading then
    UpdateInterruptLine;
  State.Field(FFrame, SizeOf(FFrame));
  State.Field(FTick, SizeOf(FTick));
  State.Field(FLine, SizeOf(FLine));
  State.Field(FField, SizeOf(FField));
  State.Field(FSPPC, SizeOf(FSPPC));
  State.Field(FAIAddress, SizeOf(FAIAddress));
  State.Field(FAILength, SizeOf(FAILength));
  State.Field(FAIProgress, SizeOf(FAIProgress));
  State.Field(FAIPhase, SizeOf(FAIPhase));
  State.Field(FAINextAddress, SizeOf(FAINextAddress));
  State.Field(FAINextLength, SizeOf(FAINextLength));
  State.Field(FAudioClock, SizeOf(FAudioClock));
  State.Field(FAIDACRemainder, SizeOf(FAIDACRemainder));
  State.Field(FSaveType, SizeOf(FSaveType));
  State.Field(FFlashData, SizeOf(FFlashData));
  State.Field(FFlashBuffer, SizeOf(FFlashBuffer));
  State.Field(FFlashUsed, SizeOf(FFlashUsed));
  State.Field(FFlashReady, SizeOf(FFlashReady));
  State.Field(FFlashMode, SizeOf(FFlashMode));
  State.Field(FFlashOffset, SizeOf(FFlashOffset));
  State.Field(FFlashStatus, SizeOf(FFlashStatus));
  State.Field(FDebugBuffer, SizeOf(FDebugBuffer));
  if State.Loading then
  begin
    FSampleCount := 0;
    FSaveDirty := True;
    if (FVIPhase >= UInt64(VideoClock) * 2) or (FAIDACPhase >= VideoClock) or
      (FAIAnchorTick > FTimeline.Now) or
      (FRSPPhase < 0) or (FRSPPhase > 1) or
      (FLine < 0) or (FLine > 1024) or
      (FField < 0) or (FField > 1) or (FAIProgress > FAILength) or
      (FSPPC > $FFC) or ((FSPPC and 3) <> 0) or (FAIPhase > $7FFF) or
      (FAILength > $3FFF8) or (FAINextLength > $3FFF8) or
      (FAIAddress > $FFFFFF) or (FAINextAddress > $FFFFFF) or (FAIDACRemainder >= 48000) or
      (FAudioClock < 0) or (FAudioClock >= 93750000) then
      raise EReadError.Create('Invalid N64 console snapshot');
    var SaveTypeValue: Cardinal := 0;
    Move(FSaveType, SaveTypeValue, SizeOf(FSaveType));
    if (SaveTypeValue > Cardinal(Ord(High(TN64SaveType)))) or (FFlashMode < 0) or (FFlashMode > 4) or
      (FFlashOffset > $FFFF * 128) or ((FFlashOffset and 127) <> 0) then
      raise EReadError.Create('Invalid N64 cartridge snapshot');
    ValidateState;
    MarkSPTransfers;
  end;
end;

procedure TN64Console.ValidateState;

  procedure ValidateSP(const T: TN64SPTransfer);
  begin
    var Flags: array[0..1] of Byte;
    Move(T, Flags, SizeOf(Flags));
    if (Flags[0] > 1) or (Flags[1] > 1) then
      raise EReadError.Create('Invalid N64 SP DMA Boolean');
    if not T.Active then
      Exit;
    if (T.local > $1FF8) or ((T.local and 7) <> 0) or
      (T.RAM > $FFFFF8) or ((T.RAM and 7) <> 0) or
      (T.Size < 8) or (T.Size > 4096) or ((T.Size and 7) <> 0) or
      (T.Blocks = 0) or (T.Blocks > 256) or (T.Position >= T.Size) or
      ((T.Position and 7) <> 0) or (T.Skip > $FF8) or ((T.Skip and 7) <> 0) or
      (T.Size <> ((T.Control and $FFF) or 7) + 1) or
      (T.Blocks > ((T.Control shr 12) and $FF) + 1) or
      (T.Skip <> ((T.Control shr 20) and $FF8)) then
      raise EReadError.Create('Invalid N64 SP DMA snapshot');
  end;

  procedure ExpectEvent(Kind: TN64EventKind; Expected: Boolean);
  begin
    if FTimeline.Count(Kind) <> Ord(Expected) then
      raise EReadError.Create('Inconsistent N64 device event snapshot');
  end;

begin
  ValidateSP(FSPTransfer);
  ValidateSP(FSPQueued);
  // Inspect stored bytes: the compiler may assume a Boolean is already 0/1
  // and eliminate an Ord(Boolean) range check on malformed snapshot data.
  var PIFlags: array[0..3] of Byte;
  var SIFlags: array[0..1] of Byte;
  var FlashUsed, FlashReady: Byte;
  Move(FPITransfer, PIFlags, SizeOf(PIFlags));
  Move(FSITransfer, SIFlags, SizeOf(SIFlags));
  Move(FFlashUsed, FlashUsed, 1);
  Move(FFlashReady, FlashReady, 1);
  if (PIFlags[0] > 1) or (PIFlags[1] > 1) or (PIFlags[2] > 1) or (PIFlags[3] > 1) or
    (SIFlags[0] > 1) or (SIFlags[1] > 1) or (FlashUsed > 1) or (FlashReady > 1) then
    raise EReadError.Create('Invalid N64 DMA/cartridge Boolean');
  if (FPendingSPAddress > $1FFF) or (FPendingRAMAddress > $FFFFFF) or
    (FSPQueued.Active and (not FSPTransfer.Active or (FSPQueued.Position <> 0))) or
    (FReg[0, 6] <> Cardinal(Ord(FSPTransfer.Active))) or
    (FReg[0, 5] <> Cardinal(Ord(FSPQueued.Active))) or
    (((FReg[0, 4] and 4) <> 0) <> FSPTransfer.Active) or
    (((FReg[0, 4] and 8) <> 0) <> FSPQueued.Active) then
    raise EReadError.Create('Inconsistent N64 SP DMA registers');
  if FPITransfer.Active then
    if (FPITransfer.Length = 0) or (FPITransfer.Length > $1000000) or
      (FPITransfer.Position > ((FPITransfer.Length + 1) and not Cardinal(1))) or
      ((FPITransfer.Position and 1) <> 0) or (FPITransfer.Stage > 1) or
      (FPITransfer.Latency > $FF) or (FPITransfer.PulseWidth > $FF) or
      (FPITransfer.PageSize > 15) or (FPITransfer.ReleaseDuration > 3) or
      (FPITransfer.ClockPhase > 1) or
      (FPITransfer.RAM > $FFFFFE) or ((FPITransfer.RAM and 1) <> 0) or
      ((FPITransfer.Cart and 1) <> 0) or (FPITransfer.FlashMode < 0) or
      (FPITransfer.FlashMode > 4) then
      raise EReadError.Create('Invalid N64 PI DMA snapshot');
  if FPITransfer.Active and FPITransfer.Flash and
    ((FPITransfer.Cart < $08000000) or (FPITransfer.Cart >= $08020000)) then
    raise EReadError.Create('Invalid N64 Flash DMA cartridge address');
  if FPITransfer.Active and (FPITransfer.Writing or FPITransfer.Flash) then
    if (FPITransfer.Position >= FPITransfer.Length) or ((FPITransfer.Position and 7) <> 0) or (FPITransfer.Stage <> 0) then
      raise EReadError.Create('Invalid N64 PI direct transfer phase');
  if FPITransfer.Active and not FPITransfer.Writing and not FPITransfer.Flash then
  begin
    if (FPITransfer.BlockRAM > $FFFFFE) or ((FPITransfer.BlockRAM and 1) <> 0) or
      (FPITransfer.MaxBlockSize < 122) or (FPITransfer.MaxBlockSize > 128) or
      ((FPITransfer.MaxBlockSize and 1) <> 0) or
      (FPITransfer.BlockLength = 0) or (FPITransfer.BlockLength > 128) or
      (FPITransfer.BlockRead > ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or
      ((FPITransfer.BlockRead and 1) <> 0) or (FPITransfer.BlockRead > FPITransfer.Position) or
      (FPITransfer.BlockWriteSize > FPITransfer.BlockLength + 1) or
      (FPITransfer.BlockWritten > FPITransfer.BlockWriteSize) then
      raise EReadError.Create('Invalid N64 PI buffer snapshot');
    var BlockStart := FPITransfer.Position - FPITransfer.BlockRead;
    if (BlockStart >= FPITransfer.Length) or
      (FPITransfer.BlockLength > FPITransfer.Length - BlockStart) then
      raise EReadError.Create('Invalid N64 PI block extent');
    var Misalignment := FPITransfer.BlockRAM and 7;
    var ExpectedWrite := Integer(FPITransfer.BlockLength) - Integer(Misalignment);
    if ExpectedWrite < 0 then
      ExpectedWrite := 0;
    if not (FPITransfer.FirstBlock and (FPITransfer.BlockLength < 127 - Misalignment)) then
      ExpectedWrite := (ExpectedWrite + 1) and not 1;
    if (FPITransfer.BlockWriteSize <> Cardinal(ExpectedWrite)) or
      (FReg[5, 0] <> ((FPITransfer.BlockRAM + FPITransfer.BlockWritten) and $FFFFFF)) or
      (FReg[5, 1] <> Add32(FPITransfer.Cart, FPITransfer.Position)) then
      raise EReadError.Create('Inconsistent N64 PI buffer readback');
    if ((FPITransfer.Stage = 0) and
      ((FPITransfer.BlockRead = ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or (FPITransfer.BlockWritten <> 0))) or
      ((FPITransfer.Stage = 1) and
      ((FPITransfer.BlockRead <> ((FPITransfer.BlockLength + 1) and not Cardinal(1))) or
      (FPITransfer.BlockWritten >= FPITransfer.BlockWriteSize))) then
      raise EReadError.Create('Inconsistent N64 PI buffer phase');
  end;
  if (((FReg[5, 4] and 1) <> 0) <> FPITransfer.Active) then
    raise EReadError.Create('Inconsistent N64 PI DMA registers');
  if FSITransfer.Active then
    if (FSITransfer.RAM > $FFFFF8) or ((FSITransfer.RAM and 7) <> 0) or
      (FSITransfer.Position >= 64) or ((FSITransfer.Position and 3) <> 0) then
      raise EReadError.Create('Invalid N64 SI DMA snapshot');
  if (((FReg[7, 6] and 1) <> 0) <> FSITransfer.Active) then
    raise EReadError.Create('Inconsistent N64 SI DMA registers');
  if ((FAILength and 7) <> 0) or ((FAINextLength and 7) <> 0) or
    ((FAIProgress and 3) <> 0) or ((FAIAddress and 7) <> 0) or
    ((FAINextAddress and 7) <> 0) or ((FAINextLength > 0) and (FAILength = 0)) then
    raise EReadError.Create('Invalid N64 AI FIFO snapshot');
  ExpectEvent(TN64EventKind.VIHalfLine, True);
  ExpectEvent(TN64EventKind.OutputSample, True);
  ExpectEvent(TN64EventKind.SPTransfer, FSPTransfer.Active);
  ExpectEvent(TN64EventKind.PITransfer, FPITransfer.Active);
  ExpectEvent(TN64EventKind.SITransfer, FSITransfer.Active);
  ExpectEvent(TN64EventKind.RSPClock, (FReg[0, 4] and 1) = 0);
  ExpectEvent(TN64EventKind.DPInterrupt, (FReg[1, 3] and $20) <> 0);
  ExpectEvent(TN64EventKind.AIConsume, ((FReg[4, 2] and 1) <> 0) and
    ((FAILength > 0) or (FLastLeft <> 0) or (FLastRight <> 0)));
  if (FCurrentFrame.FrameNumber > FFrame) or
    ((Length(FCurrentFrame.Pixels) > 0) and
    (IsNan(FCurrentFrame.FramesPerSecond) or IsInfinite(FCurrentFrame.FramesPerSecond) or
    (FCurrentFrame.FramesPerSecond <> FramesPerSecond))) then
    raise EReadError.Create('Invalid N64 cached VI frame metadata');
  for var B in FHiddenRAM do
    if B > 3 then
      raise EReadError.Create('Invalid N64 RDRAM hidden bits');
end;

procedure TN64Console.ProcessRDP;
begin
  if (FReg[1, 3] and 2) <> 0 then
    Exit;
  // END can temporarily precede CURRENT while the RSP switches its buffers.
  if FReg[1, 1] <= FReg[1, 2] then
    Exit;
  var Consumed: Cardinal;
  var FullSync: Boolean;
  var Clocks: UInt64;
  if not FRDPDrawing then
  begin
    if FRDPTimingStale then
    begin
      FRDPTiming.Assign(FRDP);
      FRDPTimingStale := False;
    end;
    FullSync := FRDPTiming.Execute(FReg[1, 2], FReg[1, 1], (FReg[1, 3] and 1) <> 0, Consumed);
    Clocks := FRDPTiming.WorkClocks;
    // (A list FRDPFollow did not see.)
    FRDPFollowStale := True;
  end
  // Command capture needs the drawing RDP on this thread.
  else if (FRDPMode <> TN64RDPMode.Synchronous) and not FRDP.Traced then
  begin
    FullSync := QueueRDP(Consumed);
    Clocks := FRDPTiming.WorkClocks;
  end
  else
  begin
    DrainRDP;
    FRDPTimingStale := True;
    FullSync := FRDP.Execute(FReg[1, 2], FReg[1, 1], (FReg[1, 3] and 1) <> 0, Consumed);
    Clocks := FRDP.WorkClocks;
  end;
  if FullSync then
  begin
    FReg[1, 3] := FReg[1, 3] or $20;
    var Delay := (Clocks * 3 + 1) div 2;
    if Delay = 0 then
      Delay := 1;
    if not FTimeline.Pending(TN64EventKind.DPInterrupt) then
      FTimeline.Schedule(TN64EventKind.DPInterrupt, Delay);
  end;
  FReg[1, 2] := Consumed;
end;

function TN64Console.QueueRDP(out Consumed: Cardinal): Boolean;
begin
  if FRDPWorker = nil then
  begin
    // Lists are numbered in the bus (FRDPList) and in the worker alike.
    var BandCPUs: TN64CPUSet;
    var Preferred: TArray<Integer>;
    PlaceThreads(BandCPUs, Preferred);
    FRDPWorker := TN64RDPWorker.Create(FRDP, Self, FRDPBands, Int64(FRDPList), FRDPMode = TN64RDPMode.Stress,
      BandCPUs, Preferred);
    FRDPTiming.OnWords := FRDPWorker.Put;
    FRDPTiming.OnDataOut := FRDPWorker.PutData;
  end;
  if FRDPTimingStale then
  begin
    // FRDP ran lists here, was reset or loaded (the bands are idle since):
    // everything continues from its state.
    FRDPTiming.Assign(FRDP);
    FRDPWorker.Resync;
    FRDPTimingStale := False;
    FRDPFollowStale := True;
  end;
  // FRDPFollow at the state before this list.
  if FRDPFollowStale then
    FRDPFollow.Assign(FRDPTiming)
  else if FRDPLastPending then
    FRDPFollow.Replay(FRDPLastWords, FRDPLastCount, False);
  FRDPLastPending := False;
  // (Until this list's words are kept: an exception leaves it behind.)
  FRDPFollowStale := True;
  FRDPDone := UInt64(FRDPWorker.Done);
  Inc(FRDPList);
  FRDPPending := True;
  FRDPWorker.BeginList;
  FRDPTiming.Lazy := True;
  FRDPTiming.Capture := True;
  try
    Result := FRDPTiming.Execute(FReg[1, 2], FReg[1, 1], (FReg[1, 3] and 1) <> 0, Consumed);
  finally
    FRDPTiming.Lazy := False;
    FRDPTiming.Capture := False;
    FRDPWorker.EndList;
  end;
  FRDPTiming.TakeCaptured(FRDPLastWords, FRDPLastCount);
  FRDPLastPending := True;
  FRDPFollowStale := False;
  // The clocks where they are used (a Full Sync's interrupt) or checked.
  if FRDPTiming.LazyClocks and (Result or (FRDPMode = TN64RDPMode.Verify)) then
    ResolveRDPClocks;
  if FRDPMode = TN64RDPMode.Verify then
  begin
    DrainRDP;
    // With several bands FRDP counts only its own rows' clocks.
    if ((FRDPBands = 1) and (FRDP.WorkClocks <> FRDPTiming.WorkClocks)) or
      (FRDP.PipelineCrashed <> FRDPTiming.PipelineCrashed) or (FRDP.PendingWords <> FRDPTiming.PendingWords) then
      raise EN64Unsupported.CreateFmt('RDP list %d: worker clocks/crash/pending %d/%s/%d, timing %d/%s/%d', [FRDPList, FRDP.WorkClocks, BoolToStr(FRDP.PipelineCrashed, True), FRDP.PendingWords, FRDPTiming.WorkClocks, BoolToStr(FRDPTiming.PipelineCrashed, True), FRDPTiming.PendingWords]);
  end;
end;

procedure TN64Console.ResolveRDPClocks;
begin
  // The latest queued list's exact clocks: FRDPFollow, at the state before
  // it, runs it again. (Not after an exception within it.)
  if not FRDPLastPending then
    Exit;
  FRDPTiming.ResolveClocks(FRDPFollow.Replay(FRDPLastWords, FRDPLastCount, True));
  FRDPLastPending := False;
end;

procedure TN64Console.DrainRDP;
begin
  if FRDPWorker = nil then
    Exit;
  FRDPWorker.Drain;
  FRDPWorker.MergeState;
  RefreshRDP;
end;

procedure TN64Console.RefreshRDP;
begin
  // The emulation thread's view of the completed lists (see TN64Bus).
  if FRDPWorker = nil then
    Exit;
  FRDPDone := UInt64(FRDPWorker.Done);
  FRDPPending := FRDPDone < FRDPList;
end;

procedure TN64Console.WaitRDP(List: UInt64);
begin
  // RDRAM access to a page of a queued list (see TN64Bus).
  if FRDPWorker = nil then
    Exit;
  FRDPWorker.WaitList(Int64(List));
  RefreshRDP;
end;

function TN64Console.GetBilinearFiltering: Boolean;
begin
  Result := FRDP.BilinearFiltering;
end;

function TN64Console.GetUseRecompiler: Boolean;
begin
  Result := FUseRecompiler;
end;

procedure TN64Console.SetUseRecompiler(Value: Boolean);
begin
  if Value = FUseRecompiler then
    Exit;
  FUseRecompiler := Value;
  FCPU.UseJit := Value and TN64CPU.JitAvailable;
  FRSP.UseJit := Value and TN64RSP.JitAvailable;
end;

procedure TN64Console.SetBilinearFiltering(Value: Boolean);
begin
  if FRDP.BilinearFiltering = Value then
    Exit;
  // Finish old work before changing the host preference. Fresh bands copy
  // the preference from FRDP; no worker can observe a partially changed list.
  DrainRDP;
  FreeAndNil(FRDPWorker);
  FRDPTiming.OnWords := nil;
  FRDPTiming.OnDataOut := nil;
  FRDP.BilinearFiltering := Value;
  FRDPTimingStale := True;
  FRDPTuneWait := 0;
  FRDPBusyFields := 0;
  FRDPQuietFields := 0;
end;

procedure TN64Console.SetRDPMode(Value: TN64RDPMode);
begin
  if Value = FRDPMode then
    Exit;
  DrainRDP;
  FRDPMode := Value;
  if FRDPWorker <> nil then
    FRDPWorker.Stress := Value = TN64RDPMode.Stress;
end;

procedure TN64Console.SetRDPThreads(Value: Integer);
begin
  FAdaptiveRDP := False;
  ResizeRDPThreads(Value);
end;

procedure TN64Console.AdaptRDPThreads;
begin
  if not FAdaptiveRDP or (FRDPWorker = nil) or not FRDPDrawing or
    (FRDPMode <> TN64RDPMode.Threaded) or FRDP.Traced then
    Exit;
  var Waited := FRDPWorker.WaitTime;
  var Delta := Waited - FRDPTuneWait;
  FRDPTuneWait := Waited;
  // A restarted worker has a fresh counter. Ignore the old sample window.
  if Delta < 0 then
  begin
    FRDPBusyFields := 0;
    FRDPQuietFields := 0;
    Exit
  end;
  var FieldBudget := TStopwatch.Frequency / FramesPerSecond;
  if Delta > FieldBudget * 0.20 then
    FRDPBusyFields := 1
  else
    FRDPBusyFields := 0;
  if Delta < FieldBudget * 0.02 then
    FRDPQuietFields := Min(120, FRDPQuietFields + 1)
  else
    FRDPQuietFields := 0;
  // Grow quickly enough for the audio reserve to cover the transition.
  // Shrink only after two seconds of quiet fields, avoiding oscillation.
  var Desired := FRDPBands;
  if FRDPBusyFields >= 1 then
    Desired := FMaxRDPBands
  else if FRDPQuietFields >= 120 then
    Desired := Max(Min(2, FMaxRDPBands), FRDPBands div 2);
  if Desired = FRDPBands then
    Exit;
  ResizeRDPThreads(Desired);
  Inc(FRDPThreadChanges);
end;

procedure TN64Console.ResizeRDPThreads(Value: Integer);
begin
  Value := Max(1, Min(16, Value));
  if Value = FRDPBands then
    Exit;
  // The next list starts a worker with the new number of bands.
  DrainRDP;
  FreeAndNil(FRDPWorker);
  FRDPTiming.OnWords := nil;
  FRDPTiming.OnDataOut := nil;
  FRDPBands := Value;
  FRDPTuneWait := 0;
  FRDPBusyFields := 0;
  FRDPQuietFields := 0;
  FRDPTimingStale := True;
end;

procedure TN64Console.PlaceThreads(out BandCPUs: TN64CPUSet; out Preferred: TArray<Integer>);
begin
  // On the emulation thread, as the RDP worker starts: this thread on the
  // fastest core (the one it runs on, among equals); the bands anywhere else,
  // each preferring one of the next fastest cores. Bands pinned one to a core
  // run a few percent faster on an idle machine, but cannot move away from
  // other programs.
  // With an RSP thread, that has the second fastest core to itself as well
  // (where there are cores left for the bands).
  BandCPUs.Clear;
  Preferred := nil;
  var Cores: TArray<TN64HostCore>;
  if not PinEmulationThread(Cores) then
    Exit;
  var First := 1;
  if FRSPThreaded and (Length(Cores) >= 3) then
    First := 2;
  for var C := First to High(Cores) do
    for var W := 0 to High(BandCPUs.Bits) do
      BandCPUs.Bits[W] := BandCPUs.Bits[W] or Cores[C].CPUs.Bits[W];
  FBandCPUs := BandCPUs;
  SetLength(Preferred, FRDPBands);
  for var I := 0 to FRDPBands - 1 do
  begin
    var Core := Cores[First + I mod (Length(Cores) - First)];
    Preferred[I] := 0;
    while not Core.CPUs.Contains(Preferred[I]) do
      Inc(Preferred[I]);
  end;
end;

function TN64Console.PinEmulationThread(out Cores: TArray<TN64HostCore>): Boolean;
begin
  // This thread on the fastest core (the one it runs on, among equals), once.
  Result := False;
  Cores := nil;
  if not FPlacement then
  begin
    if not FHintAttempted then
    begin
      FHintAttempted := True;
      var Available := HostCores;
      if Length(Available) > 0 then
      begin
        var Preferred := 0;
        while not Available[0].CPUs.Contains(Preferred) do
          Inc(Preferred);
        FPreviousIdeal := SuggestProcessor(Preferred);
        FHinted := FPreviousIdeal >= 0;
        FHintedThread := TThread.CurrentThread.ThreadID;
      end;
    end;
    Exit;
  end;
  // The cores found once, before this thread is pinned: on Linux and
  // Android HostCores sees the calling thread's own affinity.
  if not FCoresFound then
  begin
    FCores := HostCores;
    FCoresFound := True;
  end;
  Cores := FCores;
  if Length(Cores) < 2 then
    Exit;
  if not FPinned then
  begin
    var Previous: TN64CPUSet;
    if not PinCurrentThread(Cores[0].CPUs, Previous) then
      Exit;
    FPinned := True;
    FPinnedThread := TThread.CurrentThread.ThreadID;
    FUnpinned := Previous;
  end;
  Result := True;
end;

procedure TN64Console.PlaceRSPThread(out CPUs: TN64CPUSet; out Preferred: Integer);
begin
  // The RSP thread on the second fastest core, which the RDP bands leave to
  // it where there are more (PlaceThreads): sharing a core with a band costs
  // it a third of its speed.
  CPUs.Clear;
  Preferred := -1;
  var Cores: TArray<TN64HostCore>;
  if not PinEmulationThread(Cores) then
    Exit;
  if Length(Cores) >= 3 then
    CPUs := Cores[1].CPUs
  else
    for var C := 1 to High(Cores) do
      for var W := 0 to High(CPUs.Bits) do
        CPUs.Bits[W] := CPUs.Bits[W] or Cores[C].CPUs.Bits[W];
  Preferred := 0;
  while not Cores[1].CPUs.Contains(Preferred) do
    Inc(Preferred);
end;

procedure TN64Console.UnplaceThreads;
begin
  if FHinted and (TThread.CurrentThread.ThreadID = FHintedThread) then
  begin
    SuggestProcessor(FPreviousIdeal);
    FHinted := False;
  end;
  // Only the pinned thread can be given its affinity back.
  if FPinned and (TThread.CurrentThread.ThreadID = FPinnedThread) then
  begin
    var Ignored: TN64CPUSet;
    PinCurrentThread(FUnpinned, Ignored);
    FPinned := False;
  end;
end;

procedure TN64Console.SetPlacement(Value: Boolean);
begin
  if Value = FPlacement then
    Exit;
  // The next list starts a worker placed accordingly.
  DrainRDP;
  FreeAndNil(FRDPWorker);
  FRDPTiming.OnWords := nil;
  FRDPTiming.OnDataOut := nil;
  FRDPTimingStale := True;
  FPlacement := Value;
  // The next threaded window starts an RSP thread placed accordingly.
  StopRSPThread;
  if not Value then
    UnplaceThreads;
end;

procedure TN64Console.SetRDPDrawing(Value: Boolean);
begin
  if Value = FRDPDrawing then
    Exit;
  DrainRDP;
  FreeAndNil(FRDPWorker);
  FRDPTiming.OnWords := nil;
  FRDPTiming.OnDataOut := nil;
  FRDPTimingStale := True;
  FRDPDrawing := Value;
end;

function TN64Console.GetRenderer: TN64RDP;
begin
  DrainRDP;
  Result := FRDP;
end;

function TN64Console.RendererDescription: string;
begin
  DrainRDP;
  Result := FRDP.Describe
end;

procedure TN64Console.StartRSPAhead;
begin
  // After the RSP clock just handled, run the following clocks ahead of the
  // CPU for as long as they touch nothing but the RSP and DMEM. Nothing else
  // can see those clocks before the timeline reaches them: BREAK stops the
  // run, an MFC0 runs ahead only with a value the timeline predicts and an
  // MTC0 only if its effects can wait for its clock (both journalled and
  // handled in their own clock, in event order), the clocks keep off the
  // DMEM bytes SP DMA or an RDP list kicked with XBUS uses meanwhile
  // (fences), and every CPU access that could tell (SP memory, SP_PC, SP and
  // DP registers) first rewinds the RSP to its own point (SyncRSP).
  if not FRSPAhead or ((FReg[0, 4] and $21) <> 0) or TraceEnabled or
    not FTimeline.Pending(TN64EventKind.RSPClock) or (FTimeline.AheadLeft <> 0) or (FRSPRun <> 0) then
    Exit;
  // SP DMA under way: the window keeps off its DMEM bytes (fences); not
  // with IMEM, whose transfers also stop the RSP.
  if (FSPTransfer.Active and ((FSPTransfer.local and $1000) <> 0)) or
    (FSPQueued.Active and ((FSPQueued.local and $1000) <> 0)) then
    Exit;
  FRSPDMACount := 0;
  FRSPLifted := 0;
  FRSPFirstPending := 0;
  FRSPXBusCount := 0;
  FRSPXBusUsed := 0;
  FRSPDMAPending[0] := FPendingSPAddress;
  FRSPDMAPending[1] := FPendingRAMAddress;
  if FSPTransfer.Active then
  begin
    var Beat, Clock: TN64Event;
    if not FTimeline.FirstOf(TN64EventKind.SPTransfer, Beat) or not FTimeline.FirstOf(TN64EventKind.RSPClock, Clock) then
      raise EInvalidOpException.Create('N64 SP DMA or RSP clock not queued');
    // Every event reschedules itself as it is handled, so a beat and an RSP
    // clock due together keep the order of the first time they were: at the
    // next clock by sequence, else the clock first if the beat is due now
    // (it then reschedules after the clock did), else the beat first unless
    // it is the first beat, off the RCP clock (the next one then follows it).
    var R := Default(TN64RSPTransfer);
    R.Transfer := FSPTransfer;
    R.Serial := FSPDone + 1;
    R.LastBeat := 0;
    if Beat.Due = Clock.Due then
      R.BeatFirst := Beat.Sequence < Clock.Sequence
    else if Beat.Due < Clock.Due then
      R.BeatFirst := False
    else
      R.BeatFirst := Mod3(Beat.Due) <> 1;
    R.LastBeat := Beat.Due;
    if RemainingBeats(FSPTransfer) > 1 then
      R.LastBeat := RCPTickAfter(R.LastBeat, RemainingBeats(FSPTransfer) - 1);
    FRSPDoneBase := FSPDone;
    // (The slot's Data stays for its next transfer: see LiftRSPTransfer.)
    R.Data := FRSPDMAs[0].Data;
    FRSPDMAs[0] := R;
    FRSPDMACount := 1;
    if FSPQueued.Active then
      AddRSPTransfer(FSPQueued, 0);
  end;
  FRSPDoneBase := FSPDone;
  RefenceRSP;
  if FRSPCut then
    FRSPCut := False
  else
    FRSPWindow := Min(RSPWindowMax, FRSPWindow * 2);
  FRSPFirstDue := FTimeline.RSPDue;
  FRSPBeatCount := 0;
  for var I := 0 to 15 do
    FRSPShadow[I] := RSPRegister(I);
  FRSPShadowPos := 0;
  FRSPHasDP := FTimeline.FirstOf(TN64EventKind.DPInterrupt, FRSPDP);
  FRSPHasFirstClock := FTimeline.FirstOf(TN64EventKind.RSPClock, FRSPFirstClock);
  // In the test mode, also one short window in four.
  if FRSPThreaded and ((FRSPLastWindow >= RSPThreadMin) or (FRSPStress and ((StressNoise and 3) = 0))) then
  begin
    BeginThreadedWindow;
    Exit;
  end;
  var Started := TStopwatch.GetTimeStamp;
  var Clocks := FRSP.RunAhead(FSPPC, FReg[0, 4], FRSPWindow);
  Inc(FRSPStats.WindowTime, TStopwatch.GetTimeStamp - Started);
  FRSPLastWindow := Clocks;
  if Clocks = 0 then
    Exit;
  FRSPRun := Clocks;
  FRSPCommitted := 0;
  FRSPNextCheck := 0;
  FRSPApplied := 0;
  // (A count left by a window cut short would only cost time.)
  FRSPSettledWrites := 0;
  FRSPMustHold := -1;
  CountWindow(Clocks);
  NextRSPSegment;
end;

procedure TN64Console.CountWindow(Clocks: Integer);
begin
  Inc(FRSPStats.Lifts, FRSPWindowLifts);
  FRSPWindowLifts := 0;
  Inc(FRSPStats.Windows);
  Inc(FRSPStats.Clocks, Clocks);
  for var I := 0 to FRSP.JournalCount - 1 do
    if FRSP.JournalEntry(I).Write then
      Inc(FRSPStats.Deferred)
    else
      Inc(FRSPStats.Predictions);
  Inc(FRSPStats.Stops[FRSP.AheadStop]);
  if FRSP.AheadStop = TRSPAheadStop.WriteCOP0 then
    Inc(FRSPStats.StopWrites[FRSP.AheadStopIndex])
  else if FRSP.AheadStop = TRSPAheadStop.ReadCOP0 then
    Inc(FRSPStats.StopReads[FRSP.AheadStopIndex])
  else if FRSP.AheadStop = TRSPAheadStop.Fence then
  begin
    Inc(FRSPStats.FenceStops[FRSP.AheadStopIndex and 3, RSPPendingAt(RSPWindowTime(Clocks + 1)) = 0]);
    Inc(FRSPStats.FenceSources[FRSP.AheadStopIndex and 3, (FRSP.AheadStopIndex shr 2) and 7]);
  end;
end;

procedure TN64Console.NextRSPSegment;
begin
  // The timeline handles the clocks up to the next one with a journal entry,
  // or to the window's end (for a window on the RSP thread: as far as it has
  // published).
  var Clocks := FRSPRun;
  var Entries := FRSP.JournalCount;
  if FRSPInFlight then
  begin
    var Progress := SharedRead(FAheadProgress);
    Clocks := Integer(Progress shr 32);
    Entries := Integer(Progress and $FFFFFFFF);
  end;
  var Stop := Clocks + 1;
  // Settled entries need no clock of their own: they go with the segment.
  while (FRSPNextCheck < Entries) and SettledRSPEntry(FRSPNextCheck) do
  begin
    // Test mode: now and then one checked in its clock all the same, where
    // it must check right.
    if FRSPStress and ((StressNoise and 3) = 0) then
    begin
      FRSPMustHold := FRSPNextCheck;
      Break;
    end;
    if FRSPJournal[FRSPNextCheck].Write then
      Inc(FRSPSettledWrites);
    Inc(FRSPNextCheck);
  end;
  if FRSPNextCheck < Entries then
    Stop := Min(Stop, FRSPJournal[FRSPNextCheck].Clock);
  FRSPSegment := Max(0, Stop - 1 - FRSPCommitted);
  FTimeline.SetAhead(FRSPSegment);
end;

function TN64Console.SettledRSPEntry(Index: Integer): Boolean;
begin
  // Whether journal entry Index (the next to check, its clock not yet due)
  // checks right now and so in its own clock, where it would change
  // nothing the CPU or a device could tell before the next entry not
  // settled (CheckRSPPrediction): a predicted read of a register that
  // nothing changes by then, fences lifted with their transfers complete
  // now, or a write of a DMA address (read only by the DMA starts,
  // applied before those, see ApplySettledRSPWrites). Until the clock,
  // only CPU accesses that rewind the RSP first (SyncRSP), SP DMA beats
  // (the DMA registers), the DP interrupt (DPC_STATUS) and the entries
  // before it (settled: none of them changes a register) change the
  // registers the RSP reads; reading the semaphore sets it.
  var Entry := FRSPJournal[Index];
  if Entry.Write then
    Exit(Entry.Index in [0, 1]);
  // Lifted fences only with their transfers complete: until then a beat
  // may find RDRAM changed since the lift, and the RSP goes back to it
  // (SPTransferBeat), the clocks after the lift (run with the bytes it
  // took) included; the CPU must not have passed those (a beat may run
  // after the CPU's batch).
  if Entry.Lift then
    Exit(FSPDone >= FRSPNotes[Index].Serial);
  if (Entry.Index in [4..6]) and FSPTransfer.Active then
  begin
    // The transfers under way complete as their last beats run (one an RCP
    // clock from the next one due): by the clock, unless with it.
    var Beat: TN64Event;
    if not FTimeline.FirstOf(TN64EventKind.SPTransfer, Beat) then
      Exit(False);
    var LastCurrent := Beat.Due;
    var Beats := RemainingBeats(FSPTransfer);
    if Beats > 1 then
      LastCurrent := RCPTickAfter(LastCurrent, Beats - 1);
    var LastAll := LastCurrent;
    if FSPQueued.Active then
      LastAll := RCPTickAfter(LastCurrent, RemainingBeats(FSPQueued));
    var At := RSPWindowTime(Entry.Clock);
    if (At = LastCurrent) or (At = LastAll) then
      Exit(False);
    var Busy := Cardinal(Ord(At < LastAll));
    var Full := Cardinal(Ord(FSPQueued.Active and (At < LastCurrent)));
    case Entry.Index of
      4:
        Exit(Entry.Value = (FReg[0, 4] and not Cardinal($C)) or (Busy shl 2) or (Full shl 3));
      5:
        Exit(Entry.Value = Full);
    else
      Exit(Entry.Value = Busy);
    end;
  end;
  case Entry.Index of
    // (A guard: a window that knows of a transfer does not predict these,
    // PredictRSPRead.)
    0..3:
      if FSPTransfer.Active then
        Exit(False);
    7:
      Exit(False);
    11:
      if FTimeline.Pending(TN64EventKind.DPInterrupt) then
        Exit(False);
  end;
  Result := RSPRegister(Entry.Index) = Entry.Value;
end;

procedure TN64Console.ApplySettledRSPWrites(Last: Integer);
begin
  // The settled writes of the window's clocks up to Last, as Write32 would
  // have in their clocks: before an entry is checked, as the window ends,
  // and of the clocks a rewind keeps (the DMA starts that read them, the
  // RSP's and the CPU's, come after those; snapshots rewind first).
  if FRSPSettledWrites = 0 then
  begin
    FRSPApplied := FRSPNextCheck;
    Exit;
  end;
  while (FRSPApplied < FRSPNextCheck) and (FRSPJournal[FRSPApplied].Clock <= Last) do
  begin
    var Entry := FRSPJournal[FRSPApplied];
    if Entry.Write then
    begin
      if Entry.Index = 0 then
        FPendingSPAddress := Entry.Value and $1FFF
      else
        FPendingRAMAddress := Entry.Value and $FFFFFF;
      Dec(FRSPSettledWrites);
    end;
    Inc(FRSPApplied);
  end;
end;

function TN64Console.RSPRegister(Index: Integer): Cardinal;
begin
  // What an MFC0 of SP/DP register Index reads (the semaphore aside, which
  // reading also sets).
  if Index < 8 then
    Result := FReg[0, Index]
  else
    Result := FReg[1, Index - 8];
end;

function TN64Console.PredictRSPRead(Index, Clock: Integer; out Value: Cardinal): Boolean;
begin
  // The value an MFC0 at clock Clock of the window being run will read,
  // from the state now, the window's own deferred writes and the events
  // due before it: besides CPU writes (which rewind the RSP first) only SP
  // DMA, the RDP and the DP interrupt change these registers. False if the
  // value is not known (the window ends there). Checked in its clock.
  Result := False;
  Value := 0;
  UpdateRSPShadow;
  Value := FRSPShadow[Index];
  if (Index <= 6) and (FRSPDMACount > 0) then
  begin
    // The DMA registers move with the transfers; the busy and full flags
    // follow from when their last beats are due.
    if Index <= 3 then
      Exit;
    var Pending := RSPPendingAt(RSPWindowTime(Clock));
    case Index of
      4:
        Value := (Value and not Cardinal($C)) or (Cardinal(Ord(Pending >= 1)) shl 2) or (Cardinal(Ord(Pending >= 2)) shl 3);
      5:
        Value := Ord(Pending >= 2);
      6:
        Value := Ord(Pending >= 1);
    end;
  end;
  // Reading the semaphore sets it (in its own clock, see CheckRSPPrediction).
  if Index = 7 then
    FRSPShadow[7] := 1;
  if Index = 11 then
  begin
    // DPC_STATUS: the DP interrupt event clears bit 5. Due with the clock,
    // it comes first unless the clock is the one queued before it (the
    // window's other clocks are scheduled later).
    if FRSPHasDP then
    begin
      var At := RSPWindowTime(Clock);
      var Before := FRSPDP.Due < At;
      if FRSPDP.Due = At then
        Before := (Clock > 1) or not FRSPHasFirstClock or (FRSPDP.Sequence < FRSPFirstClock.Sequence);
      if Before then
        Value := Value and not Cardinal($20);
    end;
  end;
  if FRSPStress then
  begin
    // Test mode: now and then a wrong value, for the check to catch (half
    // of them in the eight lowest bits, where the flags are).
    var Noise := WindowNoise;
    if (Noise and 7) = 0 then
    begin
      var Bit := (Noise shr 3) and 31;
      if Odd(Noise shr 8) then
        Bit := Bit and 7;
      Value := Value xor (Cardinal(1) shl Bit);
    end;
  end;
  Result := True;
end;

function TN64Console.DeferRSPWrite(Index, Clock: Integer; Value: Cardinal): Boolean;
begin
  // MTC0s whose effects can wait for their own clock, the window after them
  // seeing them only through predicted reads (the shadow registers): the
  // DMA addresses, a DMA out of DMEM (the window then keeps from writing its
  // bytes), the semaphore, DPC_START and DPC_END (with XBUS the RDP reads the
  // list from DMEM at the kick: the window must not write those bytes after
  // it).
  UpdateRSPShadow;
  case Index of
    0, 1, 7, 8, 9:
      Result := True;
    2, 3:
      begin
        // A DMA start, applied at its clock (checked then: the transfers it
        // finds and its addresses). Started or queued, the window keeps off
        // its bytes from then on; ignored by a full queue, it is not.
        Result := False;
        var Time := RSPWindowTime(Clock);
        var Pending := RSPPendingAt(Time);
        var Transfer := Default(TN64SPTransfer);
        Transfer.Active := True;
        Transfer.Writing := Index = 3;
        Transfer.Size := ((Value and $FFF) or 7) + 1;
        Transfer.Blocks := ((Value shr 12) and $FF) + 1;
        Transfer.Skip := (Value shr 20) and $FF8;
        Transfer.Control := Value;
        Transfer.local := FRSPDMAPending[0] and $1FF8;
        Transfer.RAM := FRSPDMAPending[1] and $FFFFF8;
        if (Pending < 2) and (((Transfer.local and $1000) <> 0) or (FRSPDMACount = Length(FRSPDMAs))) then
          Exit;
        var N := NewRSPNote;
        FRSPNotes[N].From := FRSPDMAPending[0];
        FRSPNotes[N].RAM := FRSPDMAPending[1];
        FRSPNotes[N].Busy := Pending >= 1;
        FRSPNotes[N].Full := Pending >= 2;
        if FRSPStress and ((WindowNoise and 7) = 0) then
          // Test mode: a wrong guess, for the check to catch.
          FRSPNotes[N].Full := not FRSPNotes[N].Full;
        if Pending < 2 then
        begin
          AddRSPTransfer(Transfer, Time);
          FenceRSPTransfer(Transfer);
        end;
        Result := True;
      end;
  else
    Result := False;
  end;
  if Index = 9 then
  begin
    // The list's words that the kick runs: from CURRENT (START if a new one
    // is pending) up to the new END, below which it stops. The start is a
    // prediction, checked when the kick is applied (CheckRSPPrediction).
    var Current := FRSPShadow[10];
    if (FRSPShadow[11] and $400) <> 0 then
      Current := FRSPShadow[8];
    if FRSPStress and ((WindowNoise and 7) = 0) then
      Current := Current xor 8;
    var N := NewRSPNote;
    FRSPNotes[N].From := Current;
    FRSPNotes[N].XBus := (FRSPShadow[11] and 1) <> 0;
    var Finish := Value and $FFFFF8;
    var Start := Current and $FFF;
    var Count: Cardinal := 0;
    if Finish > Current then
      Count := Cardinal(Min(UInt64(Finish - Current), UInt64($1000)));
    if FRSPNotes[N].XBus and (Count > 0) and not FRSP.ReadFenced(Start, Count) and
      (FRSPXBusUsed + Integer(Count) <= Length(FRSPXBusData)) then
    begin
      // The RDP reads the list at the kick: its bytes as they are now go with
      // it (CheckRSPPrediction), and the window may write them meanwhile.
      for var I := 0 to Integer(Count) - 1 do
        FRSPXBusData[FRSPXBusUsed + I] := FSP[(Start + Cardinal(I)) and $FFF];
      FRSPNotes[N].XBusAt := FRSPXBusUsed;
      FRSPNotes[N].XBusCount := Integer(Count);
      Inc(FRSPXBusUsed, Integer(Count));
    end
    else if FRSPNotes[N].XBus and (Finish > Current) then
    begin
      // (Bytes DMA has yet to write, or no room: it keeps off them.)
      if 2 * FRSPXBusCount + 2 > Length(FRSPXBus) then
        SetLength(FRSPXBus, 4 * FRSPXBusCount + 16);
      FRSPXBus[2 * FRSPXBusCount] := Current and $FFF;
      FRSPXBus[2 * FRSPXBusCount + 1] := Cardinal(Min(UInt64(Finish - Current), UInt64($1000)));
      FRSP.AddFence(FRSPXBus[2 * FRSPXBusCount], FRSPXBus[2 * FRSPXBusCount + 1], False, 4);
      Inc(FRSPXBusCount);
    end;
  end;
end;

function TN64Console.RSPWindowTime(Clock: Integer): UInt64;
begin
  // When clock Clock (1 = the first) of the window being run is due.
  Result := FRSPFirstDue;
  if Clock > 1 then
    Result := RCPTickAfter(FRSPFirstDue, UInt64(Clock - 1));
end;

function TN64Console.NewRSPNote: Integer;
begin
  // The note of the journal entry the window's clock now being run adds.
  Result := FRSP.JournalCount;
  FRSPNotes[Result] := Default(TN64RSPNote);
end;

class function TN64Console.RemainingBeats(const Transfer: TN64SPTransfer): Cardinal;
begin
  Result := ((Transfer.Size - Transfer.Position) + (Transfer.Blocks - 1) * Transfer.Size) div 8;
end;

class procedure TN64Console.StepSPTransfer(var Transfer: TN64SPTransfer);
begin
  // The addresses after one beat, as SPTransferBeat moves them.
  Inc(Transfer.Position, 8);
  if Transfer.Position = Transfer.Size then
  begin
    Transfer.local := (Transfer.local and $1000) or ((Transfer.local + Transfer.Size) and $FFF);
    Transfer.RAM := (Transfer.RAM + Transfer.Size) and $FFFFFF;
    Dec(Transfer.Blocks);
    Transfer.Position := 0;
    if Transfer.Blocks > 0 then
      Transfer.RAM := (Transfer.RAM + Transfer.Skip) and $FFFFFF;
  end;
end;

function TN64Console.RSPPendingAt(Time: UInt64): Integer;
begin
  // The window's transfers not complete at the RSP clock due at Time (no
  // earlier than the clocks asked about before): they complete in order.
  while (FRSPFirstPending < FRSPDMACount) and ((FRSPDMAs[FRSPFirstPending].LastBeat < Time) or
        ((FRSPDMAs[FRSPFirstPending].LastBeat = Time) and FRSPDMAs[FRSPFirstPending].BeatFirst)) do
    Inc(FRSPFirstPending);
  Result := FRSPDMACount - FRSPFirstPending;
end;

procedure TN64Console.AddRSPTransfer(const Transfer: TN64SPTransfer; Time: UInt64);
begin
  // A transfer queued when the window starts (Time 0), or started or queued
  // by a write at Time: its beats follow the previous transfer's last one on
  // the next RCP clocks, keeping its order against the RSP clocks, or begin
  // 11 PClocks after the write (SPDMA); the clocks due with later beats were
  // scheduled after it, unless it is off the RCP clock (then the next beat is
  // scheduled after them).
  var R := Default(TN64RSPTransfer);
  R.Transfer := Transfer;
  R.Serial := FRSPDoneBase + FRSPDMACount + 1;
  var Beats := RemainingBeats(Transfer);
  if (Time = 0) or (RSPPendingAt(Time) > 0) then
  begin
    R.LastBeat := RCPTickAfter(FRSPDMAs[FRSPDMACount - 1].LastBeat, Beats);
    R.BeatFirst := FRSPDMAs[FRSPDMACount - 1].BeatFirst;
  end
  else
  begin
    R.LastBeat := Time + 11;
    R.BeatFirst := Mod3(R.LastBeat) <> 1;
    if Beats > 1 then
      R.LastBeat := RCPTickAfter(R.LastBeat, Beats - 1);
  end;
  if FRSPDMACount = Length(FRSPDMAs) then
    raise EInvalidOpException.Create('N64 RSP window knows too many transfers');
  R.Data := FRSPDMAs[FRSPDMACount].Data;
  FRSPDMAs[FRSPDMACount] := R;
  // Published with the clock that adds it (full barrier there).
  Inc(FRSPDMACount);
end;

procedure TN64Console.FenceRSPTransfer(const Transfer: TN64SPTransfer);
begin
  // Keeps the window off the DMEM bytes a transfer has yet to move: into
  // DMEM neither read nor written, out of DMEM not written. (A rewind puts
  // the bytes it writes back between the clocks again, see RewindRSPTo.)
  var Start := ((Transfer.local and $FFF) + Transfer.Position) and $FFF;
  var Count := Cardinal(Transfer.Blocks) * Transfer.Size - Transfer.Position;
  if Count > $1000 then
    Count := $1000;
  FRSP.AddFence(Start, Count, not Transfer.Writing, 1 + Ord(Transfer.Writing));
end;

procedure TN64Console.RefenceRSP;
begin
  // The fences of the transfers not lifted and of the XBUS lists.
  FRSP.ClearFences;
  for var I := FRSPLifted to FRSPDMACount - 1 do
    FenceRSPTransfer(FRSPDMAs[I].Transfer);
  for var I := 0 to FRSPXBusCount - 1 do
    FRSP.AddFence(FRSPXBus[2 * I], FRSPXBus[2 * I + 1], False, 4);
end;

function TN64Console.LiftRSPFences(Clock: Integer): Boolean;
begin
  // Clock is fenced. Transfers expected complete by then no longer need
  // their fences: their bytes are taken now instead (LiftRSPTransfer), and
  // the clock's turn checks that they did complete (CheckRSPPrediction).
  // Lifted only if the clock then runs.
  Result := False;
  var Time := RSPWindowTime(Clock);
  var Done := FRSPLifted;
  while (Done < FRSPDMACount) and (FRSPLiftMode > 0) and (FRSPDMAs[Done].Transfer.Writing or (FRSPLiftMode > 1)) and ((FRSPDMAs[Done].LastBeat < Time) or
    ((FRSPDMAs[Done].LastBeat = Time) and FRSPDMAs[Done].BeatFirst)) do
    Inc(Done);
  if Done = FRSPLifted then
    Exit;
  var Before := FRSPLifted;
  FRSPLifted := Done;
  RefenceRSP;
  if FRSP.ClockFenced then
  begin
    FRSPLifted := Before;
    RefenceRSP;
    Exit;
  end;
  // In order: a transfer out of DMEM sends what the ones before it left.
  for var I := Before to Done - 1 do
    LiftRSPTransfer(I);
  var N := NewRSPNote;
  FRSPNotes[N].Serial := FRSPDMAs[Done - 1].Serial;
  if FRSPStress and ((WindowNoise and 7) = 0) then
    // Test mode: demand one more, which may not be complete yet.
    Inc(FRSPNotes[N].Serial);
  Inc(FRSPWindowLifts);
  Result := True;
end;

class procedure TN64Console.RAMSpan(const Transfer: TN64SPTransfer; out Start, Count: Cardinal);
begin
  // The RDRAM bytes a transfer has yet to move lie in Count bytes from
  // Start (wrapping at 16 MB).
  Start := (Transfer.RAM + Transfer.Position) and $FFFFFF;
  Count := (Transfer.Size - Transfer.Position) + (Transfer.Blocks - 1) * (Transfer.Size + Transfer.Skip);
end;

function TN64Console.AheadRDRAM(Address: Cardinal): Byte;
begin
  // RDRAM byte Address as the transfer being lifted will find it: the lifted
  // transfers out of DMEM ahead of it (FRSPOverlap, the last first) send
  // their bytes only later. Address is within RDRAM (beyond it they write
  // nothing and it reads 0, see LiftRSPTransfer).
  for var J := FRSPOverlapCount - 1 downto 0 do
  begin
    var K := FRSPOverlap[J];
    var T := FRSPDMAs[K].Transfer;
    for var B := 1 to FRSPDMAs[K].DataFirst do
      StepSPTransfer(T);
    var Offset := 0;
    while T.Blocks > 0 do
    begin
      var Count := T.Size - T.Position;
      var Into := (Address + $1000000 - ((T.RAM + T.Position) and $FFFFFF)) and $FFFFFF;
      if Into < Count then
        Exit(FRSPDMAs[K].Data[Offset + Integer(Into)]);
      Inc(Offset, Count);
      T.RAM := (T.RAM + T.Size) and $FFFFFF;
      Dec(T.Blocks);
      T.Position := 0;
      if T.Blocks > 0 then
        T.RAM := (T.RAM + T.Skip) and $FFFFFF;
    end;
  end;
  if FRSPInFlight then
    Result := RacyRAM8(Address)
  else
    Result := Read8(Address);
end;

function TN64Console.XBusRead32(Offset: Cardinal): Cardinal;
begin
  // The RDP reading a list kicked by a window's deferred DPC_END write: its
  // bytes as they were at the kick (the window may have written them since).
  Result := 0;
  for var I := Cardinal(0) to 3 do
  begin
    var At := Offset + I;
    var Into := (At + $1000 - FXBusStart) and $FFF;
    var B: Byte;
    if (At < $1000) and (Into < Cardinal(FXBusCount)) then
      B := FRSPXBusData[FXBusAt + Integer(Into)]
    else
      B := FSP[At];
    Result := (Result shl 8) or B;
  end;
end;

function TN64Console.RacyRAM8(Address: Cardinal): Byte;
begin
  // RSP thread: RDRAM as Read8 reads it for an SP DMA address, without
  // waiting for queued RDP work and while other threads write it. Only for
  // lifted transfers into DMEM, whose every beat checks its bytes again.
  if Address < $800000 then
    Result := FRAM[Address]
  else
    Result := 0;
end;

procedure TN64Console.LiftRSPTransfer(Index: Integer);
begin
  // The bytes the transfer has yet to move, in beat order: into DMEM from
  // RDRAM as it will be (AheadRDRAM), written to DMEM as by the window (each
  // beat then checks RDRAM holds them); out of DMEM as it is now (the window
  // has not written them since the transfer started), for the beats to send.
  // First the transfer is taken from the beats (State 3, not while one of
  // them runs; 2 once Data is complete): the ones run so far moved their
  // bytes themselves.
  while TInterlocked.CompareExchange(FRSPDMAs[Index].State, 3, 0) <> 0 do
    YieldProcessor;
  var Transfer := FRSPDMAs[Index].Transfer;
  var Done := TInterlocked.CompareExchange(FRSPDMAs[Index].Beats, 0, 0);
  FRSPDMAs[Index].DataFirst := Done;
  var Beats := Integer(RemainingBeats(Transfer)) - Done;
  if Beats <= 0 then
  begin
    // All its beats have run.
    TInterlocked.Exchange(FRSPDMAs[Index].State, 2);
    Exit;
  end;
  for var B := 1 to Done do
    StepSPTransfer(Transfer);
  // Data: kept, at least DMEM's size, grown by doubling (no memory manager
  // call on the RSP thread once the slots are long enough; one could wait
  // 10 ms for a lock another thread holds).
  if Length(FRSPDMAs[Index].Data) < Beats * 8 then
    SetLength(FRSPDMAs[Index].Data, Max(Max(Beats * 8, $1000), Length(FRSPDMAs[Index].Data) * 2));
  FRSPOverlapCount := 0;
  if not Transfer.Writing then
  begin
    // The lifted transfers out of DMEM ahead of it that may write its RDRAM
    // bytes (circular ranges overlap if either starts inside the other).
    var Start, Count: Cardinal;
    RAMSpan(Transfer, Start, Count);
    for var K := 0 to Index - 1 do
      if FRSPDMAs[K].Transfer.Writing then
      begin
        var Other, Length_: Cardinal;
        RAMSpan(FRSPDMAs[K].Transfer, Other, Length_);
        if (((Other + $1000000 - Start) and $FFFFFF) < Count) or (((Start + $1000000 - Other) and $FFFFFF) < Length_) then
        begin
          if FRSPOverlapCount = System.Length(FRSPOverlap) then
            SetLength(FRSPOverlap, FRSPOverlapCount * 2 + 8);
          FRSPOverlap[FRSPOverlapCount] := K;
          Inc(FRSPOverlapCount);
        end;
      end;
  end;
  // In runs of bytes in a row in DMEM and in RDRAM (to the end of a block,
  // of DMEM, of RDRAM, of the 16 MB the address wraps in), each read and
  // written as a whole (every RDRAM page and DMEM line of the run checked).
  var At := 0;
  while At < Beats * 8 do
  begin
    var local := (Transfer.local + Transfer.Position) and $FFF;
    var RAM := (Transfer.RAM + Transfer.Position) and $FFFFFF;
    var Count := Min(Transfer.Size - Transfer.Position, $1000 - local);
    if RAM < $800000 then
      Count := Min(Count, $800000 - RAM)
    else
      Count := Min(Count, $1000000 - RAM);
    var Into: PByte := @FRSPDMAs[Index].Data[At];
    if Transfer.Writing then
      Move(FSP[local], Into^, Count)
    else
    begin
      if RAM >= $800000 then
        FillChar(Into^, Count, 0)
      else if FRSPOverlapCount > 0 then
        for var I := 0 to Integer(Count) - 1 do
          FRSPDMAs[Index].Data[At + I] := AheadRDRAM(RAM + Cardinal(I))
      else if FRSPInFlight then
        // As RacyRAM8.
        Move(FRAM[RAM], Into^, Count)
      else
        ReadRAMBytes(RAM, Into, Count);
      FRSP.WriteAheadBytes(local, Into, Count);
    end;
    Inc(At, Integer(Count));
    Inc(Transfer.Position, Count - 8);
    StepSPTransfer(Transfer);
  end;
  TInterlocked.Exchange(FRSPDMAs[Index].State, 2);
end;

procedure TN64Console.UpdateRSPShadow;
begin
  // The effects of the window's deferred writes journalled since the last
  // update, as Write32 will apply them.
  while FRSPShadowPos < FRSP.JournalCount do
  begin
    var Entry := FRSP.JournalEntry(FRSPShadowPos);
    Inc(FRSPShadowPos);
    if not Entry.Write then
      Continue;
    var V := Entry.Value;
    case Entry.Index of
      0:
        FRSPDMAPending[0] := V and $1FFF;
      1:
        FRSPDMAPending[1] := V and $FFFFFF;
      7:
        FRSPShadow[7] := 0;
      8:
        if (FRSPShadow[11] and $400) = 0 then
        begin
          FRSPShadow[8] := V and $FFFFF8;
          FRSPShadow[11] := FRSPShadow[11] or $400;
        end;
      9:
        begin
          FRSPShadow[9] := V and $FFFFF8;
          if (FRSPShadow[11] and $400) <> 0 then
          begin
            FRSPShadow[10] := FRSPShadow[8];
            FRSPShadow[11] := FRSPShadow[11] and not $400;
          end;
          // The list assumed to run to its end, without a Full Sync.
          if ((FRSPShadow[11] and 2) = 0) and (FRSPShadow[9] > FRSPShadow[10]) then
            FRSPShadow[10] := FRSPShadow[9];
        end;
    end;
  end;
end;

procedure TN64Console.CheckRSPPrediction;
begin
  // The RSP clock now due ran ahead with a journal entry: with every event
  // before it handled, a predicted MFC0 reads what the register holds now,
  // a deferred MTC0 takes effect now if what the window assumed about it
  // holds, and lifted fences need their transfers complete.
  var Entry := FRSPJournal[FRSPNextCheck];
  if Entry.Clock <> FRSPCommitted + 1 then
    raise EInvalidOpException.Create('N64 RSP journal out of step');
  ApplySettledRSPWrites(FRSPCommitted);
  // Entries without a note (predicted reads, most writes) never read it.
  var Note := Default(TN64RSPNote);
  if FRSPNextCheck < Length(FRSPNotes) then
    Note := FRSPNotes[FRSPNextCheck];
  var Right: Boolean;
  if Entry.Lift then
  begin
    Right := FSPDone >= Note.Serial;
    if not Right then
      Inc(FRSPStats.LiftsWrong);
  end
  else if Entry.Write then
  begin
    Right := True;
    if Entry.Index = 9 then
    begin
      // A kick: the window kept off the list where it predicted it.
      var From := FReg[1, 2];
      if (FReg[1, 3] and $400) <> 0 then
        From := FReg[1, 0];
      Right := (From = Note.From) and (((FReg[1, 3] and 1) <> 0) = Note.XBus);
    end
    else if Entry.Index in [2, 3] then
      // A DMA start: the transfers and the addresses it finds.
      Right := (FSPTransfer.Active = Note.Busy) and (FSPQueued.Active = Note.Full) and
        (FPendingSPAddress = Note.From) and (FPendingRAMAddress = Note.RAM);
    if Right then
    begin
      // A deferred MTC0 takes effect now, as in its own clock.
      var Address := $04040000 + Cardinal(Entry.Index) * 4;
      if Entry.Index >= 8 then
        Address := $04100000 + Cardinal(Entry.Index - 8) * 4;
      FRSPApplying := True;
      if (Entry.Index = 9) and (Note.XBusCount > 0) then
      begin
        FXBusAt := Note.XBusAt;
        FXBusStart := Note.From and $FFF;
        FXBusCount := Note.XBusCount;
      end;
      try
        Write32(Address, Entry.Value);
      finally
        FRSPApplying := False;
        FXBusCount := 0;
      end;
    end;
  end
  else
    Right := RSPRegister(Entry.Index) = Entry.Value;
  if not Right and (FRSPNextCheck = FRSPMustHold) then
    raise EInvalidOpException.Create('N64 RSP journal entry settled wrongly');
  if Right then
  begin
    // Reading the semaphore sets it.
    if not Entry.Write and not Entry.Lift and (Entry.Index = 7) then
      FReg[0, 7] := 1;
    // Right: the clock stands; the window goes on.
    Inc(FRSPCommitted);
    Inc(FRSPNextCheck);
    FRSPApplied := FRSPNextCheck;
    ScheduleRSP;
    if FRSPCommitted < FRSPRun then
      NextRSPSegment
    else
    begin
      FRSPRun := 0;
      FRSP.EndAhead;
      StartRSPAhead;
    end;
    Exit;
  end;
  // Wrong: back to the state before this clock, which then runs for real.
  Inc(FRSPStats.Mispredictions);
  StopAhead;
  RewindRSPTo(FRSPCommitted);
  FRSPWindow := Max(RSPWindowMin, Min(FRSPWindow div 2, FRSPCommitted * 2));
  FRSPCut := True;
  FRSPRun := 0;
  RunRSP;
  ScheduleRSP;
  StartRSPAhead;
end;

procedure TN64Console.SyncRSP;
begin
  // The window's own deferred writes need no rewind.
  if (FRSPRun > 0) and not FRSPApplying then
    RewindRSP;
end;

procedure TN64Console.RewindRSP;
begin
  // The run-ahead clocks before the caller stay; the RSP returns to the
  // state after them and the next clock becomes an ordinary event again.
  if FRSPRun = 0 then
    Exit;
  StopAhead;
  var Keep := FRSPCommitted + FTimeline.SyncAhead;
  ApplySettledRSPWrites(Keep);
  if Keep < FRSPRun then
  begin
    RewindRSPTo(Keep);
    Inc(FRSPStats.Cuts);
    Inc(FRSPStats.CutClocks, FRSPRun - Keep);
    // The clocks run ahead past this point are lost: smaller windows.
    FRSPWindow := Max(RSPWindowMin, Min(FRSPWindow div 2, Keep * 2));
    FRSPCut := True;
  end
  else
    FRSP.EndAhead;
  FTimeline.EndAhead;
  FRSPRun := 0;
end;

procedure TN64Console.RewindRSPTo(Keep: Integer);
begin
  // Back to the window's first Keep clocks, with the DMA beats into DMEM
  // that came between them: undone (the window's clocks before them may
  // have read the bytes they replaced), then done again in place
  // (ReplayRSPBeat). Their positions in FRSPStops, kept from rewind to
  // rewind (no memory manager call).
  if Length(FRSPStops) < FRSPBeatCount then
    SetLength(FRSPStops, Max(FRSPBeatCount, Length(FRSPStops) * 2));
  for var I := 0 to FRSPBeatCount - 1 do
    FRSPStops[I] := FRSPBeats[I].Position;
  if FRSPBeatCount = 0 then
    FRSP.Rewind(FSPPC, Keep, [], ReplayRSPBeat)
  else
    FRSP.Rewind(FSPPC, Keep, Slice(PIntegerArray(FRSPStops)^, FRSPBeatCount), ReplayRSPBeat);
  FRSPBeatCount := 0;
end;

procedure TN64Console.ReplayRSPBeat(Index: Integer);
begin
  if Index < 0 then
  begin
    // The saved lines are back as the window found them, but for beats
    // that came before a line was saved: those are undone, latest first. In
    // a line saved before, the saved copy is right (and the bytes the window
    // wrote since are its own, to be written again).
    for var K := FRSPBeatCount - 1 downto 0 do
      if FRSPBeats[K].Applied and FRSPBeats[K].Unsaved then
        for var I := 0 to 7 do
          WriteSP8((FRSPBeats[K].local + Cardinal(I)) and $FFF, FRSPBeats[K].Old[I]);
    Exit;
  end;
  for var I := 0 to 7 do
    WriteSP8((FRSPBeats[Index].local + Cardinal(I)) and $FFF, FRSPBeats[Index].Data[I]);
end;

procedure TN64Console.StressRSP;
begin
  // Test mode: rewind the RSP before about one CPU instruction in 64.
  if (StressNoise and 63) = 0 then
    SyncRSP;
end;

function TN64Console.StressNoise: Cardinal;
begin
  // xorshift32 for the test modes.
  FRSPNoise := FRSPNoise xor ((FRSPNoise shl 13) and $FFFFFFFF);
  FRSPNoise := FRSPNoise xor (FRSPNoise shr 17);
  FRSPNoise := FRSPNoise xor ((FRSPNoise shl 5) and $FFFFFFFF);
  Result := FRSPNoise;
end;

procedure TN64Console.FoldRSPPhase;
begin
  // Each RSP clock the timeline handled itself toggled the phase.
  if (FTimeline.TakeMaterialized and 1) <> 0 then
    FRSPPhase := FRSPPhase xor 1;
end;

function TN64Console.WindowNoise: Cardinal;
begin
  // Test-mode noise for the window's callbacks; on the RSP thread its own.
  if not FRSPInFlight then
    Exit(StressNoise);
  FRSPWorkerNoise := FRSPWorkerNoise xor ((FRSPWorkerNoise shl 13) and $FFFFFFFF);
  FRSPWorkerNoise := FRSPWorkerNoise xor (FRSPWorkerNoise shr 17);
  FRSPWorkerNoise := FRSPWorkerNoise xor ((FRSPWorkerNoise shl 5) and $FFFFFFFF);
  Result := FRSPWorkerNoise;
end;

procedure TN64Console.StressPause;
begin
  // RSP thread, test mode: random stalls, so that the emulation thread
  // sometimes catches up and sometimes finds the window far ahead.
  case WindowNoise and 63 of
    0..4:
      TThread.Yield;
    5..12:
      for var I := 0 to Integer(WindowNoise and 4095) do
        YieldProcessor;
  end;
end;

{ TN64Console.TRSPThread }

constructor TN64Console.TRSPThread.Create(Owner: TN64Console; const CPUs: TN64CPUSet; Preferred: Integer);
begin
  FOwner := Owner;
  FCPUs := CPUs;
  FPreferred := Preferred;
  inherited Create(False);
end;

procedure TN64Console.TRSPThread.Execute;
begin
  if not FCPUs.IsEmpty then
  begin
    var Previous: TN64CPUSet;
    PinCurrentThread(FCPUs, Previous);
  end;
  if FPreferred >= 0 then
    PreferProcessor(FPreferred);
  var Served: Int64 := 0;
  while not Terminated do
  begin
    if SharedRead(FOwner.FAheadRequest) <= Served then
    begin
      // Idle: spin a little, then sleep until a request or termination. The
      // flag is set before the last check, so a wake-up cannot be lost.
      var Spins := 0;
      while (Spins < SpinRounds) and (SharedRead(FOwner.FAheadRequest) <= Served) and not Terminated do
      begin
        Inc(Spins);
        YieldProcessor;
      end;
      TInterlocked.Exchange(FOwner.FAheadWorkerSleeping, 1);
      if not Terminated and (SharedRead(FOwner.FAheadRequest) <= Served) then
        FOwner.FRSPWake.WaitFor(INFINITE)
      else
        TInterlocked.Exchange(FOwner.FAheadWorkerSleeping, 0);
      Continue;
    end;
    Served := TInterlocked.Read(FOwner.FAheadRequest);
    var Started := TStopwatch.GetTimeStamp;
    {$IFDEF MSWINDOWS}
    var Cycles0: UInt64 := 0;
    QueryThreadCycleTime(CurrentThreadHandle, Cycles0);
    {$ENDIF}
    FOwner.RunThreadedWindow;
    {$IFDEF MSWINDOWS}
    var Cycles1: UInt64 := 0;
    QueryThreadCycleTime(CurrentThreadHandle, Cycles1);
    Inc(FOwner.FRSPStats.ThreadCycles, Int64(Cycles1 - Cycles0));
    {$ENDIF}
    Inc(FOwner.FRSPStats.WindowTime, TStopwatch.GetTimeStamp - Started);
    TInterlocked.Exchange(FOwner.FAheadFinished, Served);
    if (SharedRead(FOwner.FAheadMainWaiting) <> 0) and (TInterlocked.CompareExchange(FOwner.FAheadMainWaiting, 0, 1) = 1) then
      FOwner.FRSPProgress.SetEvent;
  end;
end;

procedure TN64Console.BeginThreadedWindow;
begin
  // The window runs on the RSP thread while this thread goes on; the
  // timeline takes its clocks as they are published (NextRSPSegment), each
  // segment's end coming as an RSP clock event (AdvanceThreadedWindow).
  // What the window's callbacks read is the window's own state, set up by
  // StartRSPAhead, RDRAM (RacyRAM8) and the transfers' State and Beats.
  if FRSPThread = nil then
  begin
    var CPUs: TN64CPUSet;
    var Preferred: Integer;
    PlaceRSPThread(CPUs, Preferred);
    FRSPThread := TRSPThread.Create(Self, CPUs, Preferred);
  end;
  FRSPInFlight := True;
  FRSPRun := High(Integer);
  FRSPCommitted := 0;
  FRSPNextCheck := 0;
  FRSPApplied := 0;
  FRSPSettledWrites := 0;
  FRSPMustHold := -1;
  Inc(FRSPStats.ThreadWindows);
  FAheadPC := FSPPC;
  FAheadStatus := FReg[0, 4];
  FAheadBudget := FRSPWindow;
  FAheadError := '';
  // The run is known here, for the beats (LineSaved).
  FRSP.NewRun;
  TInterlocked.Exchange(FAheadStopRequest, 0);
  TInterlocked.Exchange(FAheadProgress, 0);
  TInterlocked.Increment(FAheadRequest);
  if (SharedRead(FAheadWorkerSleeping) <> 0) and (TInterlocked.CompareExchange(FAheadWorkerSleeping, 0, 1) = 1) then
    FRSPWake.SetEvent;
  NextRSPSegment;
end;

procedure TN64Console.RunThreadedWindow;
begin
  // RSP thread: the requested window, in parts, each published as it ends
  // (a window run in parts is the same as one run at once): of AheadPart
  // clocks at least, to the end of the RSP block running then.
  var PC := FAheadPC;
  var Status := FAheadStatus;
  var Budget := FAheadBudget;
  var Done := 0;
  try
    var Part := Min(AheadPart, Budget);
    var Ran := FRSP.RunAhead(PC, Status, Budget, Part);
    Done := Ran;
    while (Ran >= Part) and (Done < Budget) and (FRSP.AheadStop = TRSPAheadStop.Budget) and
      (SharedRead(FAheadStopRequest) = 0) do
    begin
      PublishAhead(Done);
      if FRSPStress then
        StressPause;
      Part := Min(AheadPart, Budget - Done);
      Ran := FRSP.ContinueAhead(PC, Status, Budget - Done, Part);
      Inc(Done, Ran);
    end;
  except
    on E: Exception do
      FAheadError := E.ClassName + ': ' + E.Message;
  end;
  FAheadPCOut := PC;
  PublishAhead(Done);
end;

procedure TN64Console.PublishAhead(Clocks: Integer);
begin
  // RSP thread: the window's first Clocks clocks and the journal entries so
  // far are final (full barrier: after everything they wrote).
  TInterlocked.Exchange(FAheadProgress, (Int64(Clocks) shl 32) or Int64(FRSP.JournalCount));
  // (Its flag read after the full barrier above.)
  if (SharedRead(FAheadMainWaiting) <> 0) and (TInterlocked.CompareExchange(FAheadMainWaiting, 0, 1) = 1) then
    FRSPProgress.SetEvent;
end;

function TN64Console.AdvanceThreadedWindow: Boolean;
begin
  // The window's clock FRSPCommitted + 1 is due, the clocks before it
  // handled. True: the RSP thread ran it, and it is handled here (checked
  // with its journal entry, or taken as the timeline takes run-ahead
  // clocks). False: the window ended before it (the RSP thread is idle).
  var Need := FRSPCommitted + 1;
  while True do
  begin
    var Progress := SharedRead(FAheadProgress);
    if Need <= Integer(Progress shr 32) then
    begin
      if (FRSPNextCheck < Integer(Progress and $FFFFFFFF)) and (FRSPJournal[FRSPNextCheck].Clock = Need) then
        CheckRSPPrediction
      else
      begin
        Inc(FRSPCommitted);
        ScheduleRSP;
        NextRSPSegment;
      end;
      Exit(True);
    end;
    if SharedRead(FAheadFinished) = FAheadRequest then
    begin
      // Final now: published before it finished.
      if Need <= Integer(SharedRead(FAheadProgress) shr 32) then
        Continue;
      EndThreadedWindow;
      Exit(False);
    end;
    WaitAhead(Need);
  end;
end;

procedure TN64Console.WaitAhead(Need: Integer);
begin
  // Until the RSP thread has published clock Need or finished.
  Inc(FRSPStats.ThreadWaits);
  var Started := TStopwatch.GetTimeStamp;
  var Spins := 0;
  while (Integer(SharedRead(FAheadProgress) shr 32) < Need) and (SharedRead(FAheadFinished) <> FAheadRequest) do
  begin
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    TInterlocked.Exchange(FAheadMainWaiting, 1);
    if (Integer(SharedRead(FAheadProgress) shr 32) >= Need) or (SharedRead(FAheadFinished) = FAheadRequest) then
    begin
      TInterlocked.Exchange(FAheadMainWaiting, 0);
      Break;
    end;
    FRSPProgress.WaitFor(INFINITE);
  end;
  Inc(FRSPStats.ThreadWaitTime, TStopwatch.GetTimeStamp - Started);
end;

procedure TN64Console.StopAhead;
begin
  // Ends the window on the RSP thread where it is now: the timeline has
  // taken at most what it published. Then it is as a window run here.
  if not FRSPInFlight then
    Exit;
  TInterlocked.Exchange(FAheadStopRequest, 1);
  WaitAhead(High(Integer));
  EndThreadedWindow;
end;

procedure TN64Console.EndThreadedWindow;
begin
  // The RSP thread finished the window (and waits for the next request):
  // its length, and where the RSP got.
  var Clocks := Integer(SharedRead(FAheadProgress) shr 32);
  FRSPInFlight := False;
  FRSPRun := Clocks;
  FRSPLastWindow := Clocks;
  FSPPC := FAheadPCOut;
  if FAheadError <> '' then
    raise EN64Unsupported.Create('RSP thread: ' + FAheadError);
  if Clocks > 0 then
    CountWindow(Clocks);
end;

procedure TN64Console.StopRSPThread;
begin
  // Ends the window it runs, then the thread.
  StopAhead;
  if FRSPThread = nil then
    Exit;
  FRSPThread.Terminate;
  FRSPWake.SetEvent;
  FreeAndNil(FRSPThread); // waits for Execute to return
end;

procedure TN64Console.SetRSPThreaded(Value: Boolean);
begin
  if Value = FRSPThreaded then
    Exit;
  SyncRSP;
  FRSPThreaded := Value;
  if not Value then
    StopRSPThread;
  // The bands are placed anew (PlaceThreads) as the next list starts.
  DrainRDP;
  FreeAndNil(FRDPWorker);
  FRDPTiming.OnWords := nil;
  FRDPTiming.OnDataOut := nil;
  FRDPTimingStale := True;
end;

function TN64Console.WaitStats: TN64WaitStats;
begin
  Result.RDP := 0;
  if FRDPWorker <> nil then
    Result.RDP := FRDPWorker.WaitTime;
  Result.VI := FVIWaitTime;
  Result.VICopies := FVICopies;
end;

function TN64Console.RSPThreadID: TThreadID;
begin
  Result := 0;
  if FRSPThread <> nil then
    Result := FRSPThread.ThreadID;
end;

procedure TN64Console.RunRSP;
begin
  // RSP owns persistent scalar/vector state; scheduled in bounded slices.
  // BREAK reports its IRQ through the output argument. MTC0 can also change
  // MI bits through the bus, so do not write an unchanged local value back.
  var BeforeIRQ := FReg[2, 2];
  var IRQ := BeforeIRQ;
  FRSP.ExecuteCycles(FSPPC, FReg[0, 4], IRQ, 1);
  if IRQ <> BeforeIRQ then
    SetInterrupts(IRQ);
end;

end.

