unit N64.RSP;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.SyncObjs, System.Classes, System.Math, N64.Types,
  Core.Snapshots, HW.JIT;

type
  // One vector register's eight lanes.
  TRSPLanes = array[0..7] of Word;

  PRSPLanes = ^TRSPLanes;
  // The eight lanes also as two 64-bit words (all at once: SWAR), 8-byte
  // aligned.
  // The accumulator's lanes.

  TRSPAccLanes = array[0..7] of Int64;

  PRSPAccLanes = ^TRSPAccLanes;

  TRSPQuadLanes = record
    case Integer of
      0:
        (Lanes: TRSPLanes);
      1:
        (Quads: array[0..1] of UInt64);
  end;

  PRSPQuadLanes = ^TRSPQuadLanes;

  TRSPTimingInfo = record
    Flags, RRead, RWrite, VRead, VWrite, VCRead, VCWrite, VFake: Cardinal;
  end;

  // What one issue clock reads and writes, for the hazard check and the
  // readiness update (an instruction alone, or a pair).
  TRSPIssueMasks = record
    Flags, Sources, Vectors, ScalarWrites, VectorWrites: Cardinal;
    external: Boolean;
  end;

  // A predecoded IMEM word; the pair entries hold for SecondOp at the next
  // slot.
  TRSPDecoded = record
    Op: Cardinal;
    PairValid, CanPair: Boolean;
    SecondOp: Cardinal;
    Info: TRSPTimingInfo;
    Single, Paired: TRSPIssueMasks;
  end;

  // The value an MFC0 of SP/DP register Index (0..15) reads at clock Clock
  // of a run-ahead window (1 = the first): False if it cannot be known yet.
  TRSPPrediction = function(Index, Clock: Integer; out Value: Cardinal): Boolean of object;
  // Whether an MTC0 of Value to SP/DP register Index at clock Clock of a
  // run-ahead window may be applied later, in its own clock (the console
  // does that).

  TRSPDeferral = function(Index, Clock: Integer; Value: Cardinal): Boolean of object;

  // Why a run-ahead window ended: its clock budget, MTC0, an MFC0 without a
  // prediction, BREAK or another instruction that may raise, a halt.
  // a DMEM access to a fenced line.
  TRSPAheadStop = (Budget, WriteCOP0, ReadCOP0, BreakOrRaise, Halt, Fence);

  // Called by Rewind before it runs clock Stops[Index] + 1 again.
  TRSPReplayStop = procedure(Index: Integer) of object;
  // Whether the console lifts fences for clock Clock of a run-ahead window,
  // which they stop (the DMA they guard expected done by then; checked in
  // that clock's turn). It lifts them only if the clock then runs
  // (TN64RSP.ClockFenced).

  TRSPFenceLift = function(Clock: Integer): Boolean of object;

  // A predicted MFC0, a deferred MTC0 (Write) or lifted fences (Lift) of a
  // run-ahead window.
  TRSPJournalEntry = record
    Clock, Index: Integer;
    Value: Cardinal;
    Write, Lift: Boolean;
  end;
  // The journal as it lies in memory (TN64RSP.Journal).

  TRSPJournal = array[0..16383] of TRSPJournalEntry; // TN64RSP.JournalCapacity

  PRSPJournal = ^TRSPJournal;

  // Everything an RSP clock can change besides DMEM (run-ahead checkpoint).
  TRSPCheckpoint = record
    Reg: array[0..31] of Cardinal;
    Vec: array[0..31, 0..7] of Word;
    Acc: array[0..7] of Int64;
    VCO, VCC, VCE: Word;
    NextPC, PC: Cardinal;
    Branch, DivisionHigh: Boolean;
    DivisionInput, DivisionResult: Word;
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
    SingleIssue: Byte;
    StalledSecondOpcode: Cardinal;
    HasStalledSecondOpcode: Boolean;
    LoadHistory, BranchBubble: Byte;
    StalledOpcode, StalledPC: Cardinal;
    HasStalledOpcode: Boolean;
  end;

  // One clock of a block: the words it issues (Second also unpaired: a
  // stall holds it), the clocks it stalls first and the pipeline after it.
  TRSPBlockStep = record
    // Each word's routine by its kind (TRSPIssueProc, nil for kind 0), and
    // what it is given (StepArg: the word, or for a branch the word with
    // its PC's part worked out).
    Issue, SecondIssue: Pointer;
    Arg, SecondArg: Cardinal;
    // The clocks from the block's start through this one, its stall
    // included.
    Clocks: Integer;
    Wait: Byte;
    Pair: Boolean;
    // What RunBlock checks before the clock but a stall (none mostly):
    // StepMemory, a load or store (the only instructions fences concern);
    // StepExternal, the clock's one external instruction is an MFC0 or MTC0
    // (journalled ahead as RunClocks does); StepGeneral, an instruction of
    // IssueInstruction's, or a branch or jump in a delay slot (the PC as
    // IssueKind moves it).
    Checks: Byte;
    // A branch's delay slot run by its routines: the PC goes where the
    // branch took it after the clock.
    Delay: Boolean;
    Op, Second: Cardinal;
    // How each word issues (TN64RSP.StepKind).
    Kind, SecondKind: Byte;
    LoadHistory, SingleIssue: Byte;
    // The clock's PC (the same each time: a block starts at one PC and
    // branches only after its last clock).
    PC: Word;
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
  end;

  PRSPBlockStep = ^TRSPBlockStep;

  // The clocks RunClocks takes from an IMEM slot and pipeline state (no
  // branch, stall or bubble pending, not single-stepping), worked out once:
  // up to the delay slot of the first branch, or before the first clock
  // with an external instruction other than one MFC0 or MTC0. Which words
  // issue, paired or not, and the
  // stalls depend on nothing else. Its Words IMEM words from the slot on
  // (all those the clocks looked at) are compared again once a word of the
  // IMEM eighths they lie in (Regions) changed after Checked.
  PRSPBlock = ^TRSPBlock;

  TRSPBlock = record
    ScalarLo, ScalarHi, VectorLo, VectorHi: Cardinal;
    LoadHistory, SingleIssue: Byte;
    Count, First, Words, FirstWord: Integer;
    // Its steps' clocks (the last one's TRSPBlockStep.Clocks; RunBlock stops
    // there: never above it, and below it a block would only end early,
    // RunClocks taking the rest).
    Clocks: Integer;
    Checked: UInt64;
    // The next block from the same slot, or -1; its own index (FBlocks).
    Next, Index: Integer;
    // The IMEM eighths (TN64Bus.IMemRegionStamp) of its first and last word.
    Regions: array[0..1] of Byte;
    // The blocks that came next after this one ran to its end, at LinkPC:
    // [0] with no branch taken, [1] after a taken one (and its bubble). The
    // pipeline there follows from this block, the branch and its target
    // alone, so the block found there then fits it again (nil: none yet).
    // The last one of each; all of them in FJumps.
    Link: array[0..1] of PRSPBlock;
    LinkPC: array[0..1] of Cardinal;
    // Its generated code (HW.JIT; nil: none, or not yet): its clocks as
    // RunBlock runs them where the budget left takes them all. Entries before
    // the code is made (JitHeat), whether it was tried.
    Native: Pointer;
    JitTried: Boolean;
    JitHeat: Word;
  end;

  // What RunBlock and the blocks' code exchange (TN64RSP.JitRun): the
  // budget (Stop: the clocks from which it may end at a block's end), the
  // clocks run, the checks of the run (Mask but StepMemory;
  // Fences: StepMemory too while DMEM has fences), RunBlock's Status and
  // Interrupt. When the code returns: the last block it ran to its end and
  // the PC after it (Outcome -1), or where a clock of its stopped the run as
  // RunBlock stops it there (Outcome its result; PC, Ran as it leaves them).
  // Slot: whether a branch was pending before a block's last clock run by
  // JitCheck (PC: as its words moved it).
  TRSPJitCtx = record
    Cycles, Stop, Ran, Outcome: Integer;
    PC: Cardinal;
    Mask, Fences, Slot: Byte;
    Block: PRSPBlock;
    Status, Interrupt: PCardinal;
  end;

  PRSPJitCtx = ^TRSPJitCtx;

  // After a block's clocks (tests): Clocks run so far in this call.
  TRSPBlockDone = procedure(Clocks: Integer) of object;

  // A block step's issue routine (TN64RSP.FKindIssue): a TN64RSP method
  // called with its Self first, as methods take it.
  TRSPIssueProc = procedure(RSP: TObject; Op: Cardinal);

  TN64RSP = class
  private
    const
      NotDecoded = High(UInt64);
  private
    class var
    // The issue routine of each step kind (StepKind) but 0.
      FKindIssue: array[Byte] of Pointer;
  private
    FBus: TN64Bus;
    FReg: array[0..31] of Cardinal;
    FVec: array[0..31, 0..7] of Word;
    // The 48-bit accumulator lanes, sign-extended (also their snapshot
    // form). The slices: bits 32..47 (AccHi), 16..31 (AccMid), 0..15 (AccLo).
    FAcc: array[0..7] of Int64;
    // Flag registers as lane masks: bit I (and I + 8) for lane I.
    FVCO, FVCC, FVCE: Word;
    FNextPC: Cardinal;
    FBranch: Boolean;
    FDivisionHigh: Boolean;
    FDivisionInput, FDivisionResult: Word;
    // Snapshot form of the readiness counters; the live pipeline uses planes.
    FScalarReady: array[0..31] of Byte;
    FVectorReady: array[0..31] of Byte;
    // Two bit-planes per register file encode readiness 0..3 (Lo + 2 * Hi).
    FScalarLo, FScalarHi, FVectorLo, FVectorHi: Cardinal;
    // IMEM predecoded per word; an entry is redone when the bus's stamp of
    // its word changes (every write to IMEM) or, without direct SP memory,
    // when the word read differs.
    FDec: array[0..1023] of TRSPDecoded;
    // The masks of the held words FStallOp/FStallSecond/FStallPair (a pure
    // function of them), for the clocks a stall repeats.
    FStallMasks: TRSPIssueMasks;
    FStallOp, FStallSecond: Cardinal;
    FStallPair, FStallKnown: Boolean;
    // The bus's IMEM stamp of each word when decoded; NotDecoded at first.
    FDecStamp: array[0..1023] of UInt64;
    FSingleIssue: Byte;
    FStalledSecondOpcode: Cardinal;
    FHasStalledSecondOpcode: Boolean;
    FLoadHistory, FBranchBubble: Byte;
    FStalledOpcode, FStalledPC: Cardinal;
    FHasStalledOpcode: Boolean;
    // Run-ahead: the state before the first clock run ahead, and the 64-byte
    // DMEM lines as they were before their first write in this run (a line
    // is saved when FLineRun differs from FRun).
    FAhead, FCheckpointed: Boolean;
    FCheckpoint: TRSPCheckpoint;
    FRun: Cardinal;
    // NewRun has started the next run (RunAhead does not again).
    FRunFresh: Boolean;
    FLineRun: array[0..63] of Cardinal;
    FLineBackup: array[0..4095] of Byte;
    // The window's predicted MFC0s and deferred MTC0s, in clock order
    // (FJournalCount used); a rewind replays them from FReplayPos on.
    // FReadPending: the MFC0 of the clock being issued reads FReadValue;
    // FWritePending: its MTC0 is left to the console.
    FPredict: TRSPPrediction;
    FDefer: TRSPDeferral;
    FDeferSilent: Cardinal;
    FLift: TRSPFenceLift;
    FJournal: TArray<TRSPJournalEntry>;
    FJournalCount, FReplayPos: Integer;
    FReplaying, FReadPending, FWritePending: Boolean;
    FReadValue: Cardinal;
    // Window clocks before the current RunClocks call (a replay runs in
    // parts).
    FClockBase: Integer;
    // Clocks the window being run has run so far (RunAhead, ContinueAhead).
    FAheadClocks: Integer;
    FAheadStop: TRSPAheadStop;
    // 8-byte groups of DMEM a run-ahead window must not read (bit 0) or
    // write (bit 1): DMA or the RDP uses them meanwhile. 512..515: groups
    // 0..3 again (the blocks' code reads past the end without wrapping).
    FFence: array[0..515] of Byte;
    FFenced: Boolean;
    FAheadStopIndex: Integer;
    // The instructions of the clock a fence stops (for ClockFenced).
    FFencedOp, FFencedSecond: Cardinal;
    FFencedPair: Boolean;
    // Blocks (TRSPBlock), chained per IMEM slot from FBlockHead; their steps
    // and words in pools, all dropped when one is full.
    FUseBlocks: Boolean;
    FBlockHead: array[0..1023] of Integer;
    FBlocks: TArray<TRSPBlock>;
    FBlockSteps: TArray<TRSPBlockStep>;
    FBlockWords: TArray<Cardinal>;
    FBlockCount, FStepCount, FWordCount: Integer;
    // Counts ClearBlocks (blocks from before are gone).
    FBlockGen: Cardinal;
    FBlocksBuilt, FBlocksRun, FBlockClocks: Int64;
    // The blocks that came next (TRSPBlock.Link) by the block, whether the
    // branch was taken and the PC (JumpKey; 0: none), hashed (JumpSlot): a
    // block ending in JR goes on at many PCs.
    FJumps: array[0..1023] of record
      Key: Cardinal;
      Block: PRSPBlock;
    end;
    FOnBlock: TRSPBlockDone;
    // Blocks as generated code (HW.JIT, as the CPU's): its writer, whether
    // to use it and whether its buffer filled up (until ClearBlocks drops
    // the code with the blocks); the code all blocks share (FJitEnter 0: none
    // yet): the entry, the start of a run, the way back, the chaining code.
    FJit: TJitAsm;
    FUseJit, FJitFull: Boolean;
    FJitEnter, FJitOuter, FJitReturn, FJitStop, FJitChain: NativeInt;
    // The routines the code calls (CallAt): the steps' by kind, then
    // JitCheck.
    FJitCalls: array[0..256] of Pointer;
    FJitCompiled, FJitRuns: Int64;
    // (N64RSPJIT=stats: why the chaining code went back, and why RunBlock
    // did not enter a block's code, by reason.)
    FJitBack: array[0..15] of Int64;
    FJitGen: array[0..255] of Int64;
    function JitCodeFor(B: PRSPBlock): Pointer;
    function JitCompile(B: PRSPBlock): Pointer;
    procedure JitEmitShared;
    function JitRun(var B: PRSPBlock; var PC, Status, Interrupt: Cardinal; var Ran: Integer; Cycles, Stop: Integer;
      Mask: Byte; Fences: Boolean): Integer;
    function JitCheck(Ctx: PRSPJitCtx; Step, Ran: Integer): Cardinal;
    procedure CountGeneral(S: PRSPBlockStep);
    procedure ClearBlocks;
    function BlockValid(B: PRSPBlock; Slot: Integer): Boolean; inline;
    function CheckBlock(B: PRSPBlock; Slot: Integer): Boolean;
    function NextBlock(B: PRSPBlock; Taken: Integer; PC: Cardinal): PRSPBlock;
    function FindBlock(PC: Cardinal): PRSPBlock;
    function BuildBlock(PC: Cardinal): PRSPBlock;

    function RunBlock(B: PRSPBlock; var PC, Status, Interrupt: Cardinal; Cycles, Stop: Integer; Ahead: Boolean;
      var Ran: Integer): Integer;
    function RunSteps(S: PRSPBlockStep; Mask: Byte; Room, Limit: Integer): PRSPBlockStep;
    function TouchesFence(Op: Cardinal): Boolean;
    procedure HoldStep(Done, S: PRSPBlockStep);
    procedure StopAtExternal(Op, Second: Cardinal);
    class function JournalStep(Op, Second: Cardinal; Pair: Boolean): Boolean; static;
    class function LoadStore(Op: Cardinal): Boolean; static;
    procedure SaveCheckpoint(PC: Cardinal);
    procedure SaveLine(Offset: Cardinal);
    function JournalCOP0(Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
    function LiftFence(PC, Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
    procedure AddJournal(Clock, Index: Integer; Value: Cardinal; Write, Lift: Boolean);
    procedure Decode(Slot: Integer; Op: Cardinal; Stamp: UInt64);
    procedure DecodePair(Slot: Integer);
    function DecodedSlot(Slot: Integer): Integer; inline;
    class procedure Combine(const A, B: TRSPTimingInfo; ExternalA, ExternalB: Boolean; out Masks: TRSPIssueMasks); static;
    class procedure MasksOf(const Info: TRSPTimingInfo; IsExternal: Boolean; out Masks: TRSPIssueMasks); static;
    procedure IssueCOP0(Op, Current: Cardinal);
    procedure IssueMoveCOP2(Op: Cardinal);
    procedure IssueLoadStore(Op, Address: Cardinal);
    class procedure Unsupported(const Kind: string; Op: Cardinal); static;
    function RunClocks(var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean; Least: Integer = 0): Integer;
    class function external(Op: Cardinal): Boolean; static;
    procedure AgePipeline; inline;
    procedure AgePipelineBy(Clocks: Integer); inline;
    function DMemRead(Offset: Cardinal): Byte; inline;
    procedure DMemWrite(Offset: Cardinal; Value: Byte); inline;
    function IMemRead32(PC: Cardinal): Cardinal; inline;
    procedure PlanesToArrays;
    procedure ArraysToPlanes;
    function InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
    function InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
    function InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
    function InfoSCC(Op: Cardinal): TRSPTimingInfo;
    function InfoVU(Op: Cardinal): TRSPTimingInfo;
    function InfoLWC2(Op: Cardinal): TRSPTimingInfo;
    function InfoSWC2(Op: Cardinal): TRSPTimingInfo;
    function CanPair(const A, B: TRSPTimingInfo): Boolean;
    procedure IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
    procedure Issue(Op: Cardinal; var PC, Status, Interrupt: Cardinal); inline;
    function AccHi(I: Integer): Word; inline;
    function AccMid(I: Integer): Word; inline;
    function AccLo(I: Integer): Word; inline;
    procedure SetAcc(I: Integer; Value: Int64); inline;
    procedure SetAccLo(I: Integer; Value: Word);
    {$IF Defined(CPU64BITS)}
    procedure SetAccLoQuads(Lo0, Lo1: UInt64); inline;
    procedure SelectQuads(Op: Cardinal; VS, VT: PRSPQuadLanes; T0, T1: UInt64);
    {$ENDIF} inline;
    function VTLanes(Op: Cardinal; var Copy: TRSPQuadLanes): PRSPLanes; inline;
    procedure VectorOp(Op: Cardinal);
    procedure VectorMulFrac(Op: Cardinal);
    procedure VectorRound(Op: Cardinal);
    procedure VectorMulQ(Op: Cardinal);
    procedure VectorMul(Op: Cardinal);
    procedure VectorMUDL(Op: Cardinal);
    procedure VectorMUDM(Op: Cardinal);
    procedure VectorMUDN(Op: Cardinal);
    procedure VectorMUDH(Op: Cardinal);
    procedure VectorMADL(Op: Cardinal);
    procedure VectorMADM(Op: Cardinal);
    procedure VectorMADN(Op: Cardinal);
    procedure VectorMADH(Op: Cardinal);
    procedure VectorMUDLOne(Op: Cardinal);
    procedure VectorMUDMOne(Op: Cardinal);
    procedure VectorMUDNOne(Op: Cardinal);
    procedure VectorMUDHOne(Op: Cardinal);
    procedure VectorMADLOne(Op: Cardinal);
    procedure VectorMADMOne(Op: Cardinal);
    procedure VectorMADNOne(Op: Cardinal);
    procedure VectorMADHOne(Op: Cardinal);

    procedure VectorAddSub(Op: Cardinal);
    procedure VectorAdd(Op: Cardinal);
    procedure VectorSub(Op: Cardinal);
    class function StepKind(Op: Cardinal): Byte; static;
    class function StepArg(Kind: Byte; Op, PC: Cardinal): Cardinal; static;
    procedure IssueKind(Kind: Byte; Op: Cardinal; var PC, Status, Interrupt: Cardinal);
    procedure IssueStep(Kind: Byte; Op: Cardinal); inline;
    // A block step's instructions by kind (StepKind, KindIssue): r0 zeroed
    // after a scalar one.
    procedure IssueADDI(Op: Cardinal);
    procedure IssueANDI(Op: Cardinal);
    procedure IssueORI(Op: Cardinal);
    procedure IssueXORI(Op: Cardinal);
    procedure IssueLUI(Op: Cardinal);
    procedure IssueSLL(Op: Cardinal);
    procedure IssueSRL(Op: Cardinal);
    procedure IssueSRA(Op: Cardinal);
    procedure IssueADD(Op: Cardinal);
    procedure IssueSUB(Op: Cardinal);
    procedure IssueAND(Op: Cardinal);
    procedure IssueOR(Op: Cardinal);
    procedure IssueXOR(Op: Cardinal);
    procedure IssueNOR(Op: Cardinal);
    procedure IssueSLT(Op: Cardinal);
    procedure IssueSLTU(Op: Cardinal);
    procedure IssueSLTI(Op: Cardinal);
    procedure IssueSLTIU(Op: Cardinal);
    procedure IssueLB(Op: Cardinal);
    procedure IssueLH(Op: Cardinal);
    procedure IssueLW(Op: Cardinal);
    procedure IssueLBU(Op: Cardinal);
    procedure IssueLHU(Op: Cardinal);
    procedure IssueSB(Op: Cardinal);
    procedure IssueSH(Op: Cardinal);
    procedure IssueSW(Op: Cardinal);
    procedure StoreBytes(Op: Cardinal; Size: Cardinal); inline;
    procedure VectorLoad(Op: Cardinal);
    procedure VectorStore(Op: Cardinal);
    procedure VectorLoadDirect(Op: Cardinal);
    procedure VectorStoreDirect(Op: Cardinal);
    procedure IssueUnexpected(Op: Cardinal);
    procedure IssueCOP2Move(Op: Cardinal);
    // Branches and jumps (Arg: StepArg's).
    procedure IssueBEQ(Arg: Cardinal);
    procedure IssueBNE(Arg: Cardinal);
    procedure IssueBLEZ(Arg: Cardinal);
    procedure IssueBGTZ(Arg: Cardinal);
    procedure IssueBLTZ(Arg: Cardinal);
    procedure IssueBGEZ(Arg: Cardinal);
    procedure IssueJ(Arg: Cardinal);
    procedure IssueJAL(Arg: Cardinal);
    procedure IssueJR(Arg: Cardinal);
    procedure VectorAbs(Op: Cardinal);
    procedure VectorCarry(Op: Cardinal);
    procedure VectorSar(Op: Cardinal);

    procedure VectorLT(Op: Cardinal);
    procedure VectorEQ(Op: Cardinal);
    procedure VectorNE(Op: Cardinal);
    procedure VectorGE(Op: Cardinal);
    procedure VectorClipLow(Op: Cardinal);
    procedure VectorCH(Op: Cardinal);
    procedure VectorCR(Op: Cardinal);
    procedure VectorMerge(Op: Cardinal);
    procedure VectorLogic(Op: Cardinal);
    procedure VectorReserved(Op: Cardinal);
    procedure VectorDivide(Op: Cardinal);
    procedure VectorMemory(Op: Cardinal; Writing: Boolean);
    procedure VectorMemoryDirect(Op: Cardinal; Writing: Boolean);
    function GetByte(R, Index: Integer): Byte;
    procedure SetByte(R, Index: Integer; Value: Byte);
  public
    constructor Create(Bus: TN64Bus);
    destructor Destroy; override;
    procedure Reset;
    // SP_PC writes discard pending branches and fetched instructions.
    procedure ResetPipeline;
    procedure Execute(var PC, Status, Interrupt: Cardinal);
    // The budget includes SU load interlocks and taken-branch bubbles. Each
    // stalled clock returns to the console before another instruction executes.
    function ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
    // Run-ahead. RunAhead executes up to Cycles clocks for as long as they
    // touch nothing outside the RSP but DMEM (no MTC0, no BREAK, nothing that
    // raises; an MFC0 only with a value from OnPredict, an MTC0 only if
    // OnDefer leaves it to the console; both go into the journal) and returns
    // how many it ran; Status is not changed (it must not halt or
    // single-step). Rewind returns to the state before them and runs Keep of
    // them again, with the journal's values for their MFC0s (and without
    // their MTC0s). EndAhead keeps them all. Both empty the journal.
    // With Least (1..Cycles), the clocks may end at any block's end from Least
    // on (as RunAhead or ContinueAhead with a smaller Cycles would end there),
    // fewer than Least only where the window stops.
    function RunAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer; Least: Integer = 0): Integer;
    // Starts the run of the next window now (RunAhead does it otherwise), so
    // that LineSaved can tell its saved lines while it runs elsewhere.
    procedure NewRun;
    // Whether the window being run has saved the 64-byte DMEM line at Offset
    // (before its first write to it). Safe on another thread: True means the
    // copy is complete.
    function LineSaved(Offset: Cardinal): Boolean;
    // Up to Cycles more clocks of the window RunAhead started (after it ran
    // all its clocks): one window run in parts, exactly as in one.
    function ContinueAhead(var PC: Cardinal; Status: Cardinal; Cycles: Integer; Least: Integer = 0): Integer;
    procedure Rewind(var PC: Cardinal; Keep: Integer); overload;
    // The same, calling OnStop(I) after the first Stops[I] clocks (in
    // ascending order, at most Keep): for outside writes to DMEM made while
    // the window ran, at their place among its clocks. OnStop(-1) comes after
    // the saved lines are restored, before the clocks run again.
    procedure Rewind(var PC: Cardinal; Keep: Integer; const Stops: array of Integer; OnStop: TRSPReplayStop); overload;
    procedure EndAhead;
    // Fences the 8-byte groups of Count bytes from Offset (wrapping in DMEM)
    // for the window being run, or the next one: for writes, and with Reads
    // also for reads. EndAhead lifts every fence.
    procedure AddFence(Offset, Count: Cardinal; Reads: Boolean; Source: Byte = 0);
    // Whether the window being run wrote DMEM lines of Count bytes from
    // Offset (wrapping in DMEM).
    function WroteAhead(Offset, Count: Cardinal): Boolean;
    // Whether a fence keeps the window from reading any of Count bytes from
    // Offset (wrapping in DMEM).
    function ReadFenced(Offset, Count: Cardinal): Boolean;
    // Lifts every fence (the window goes on).
    procedure ClearFences;
    // During OnLift: whether the clock is still stopped by a fence.
    function ClockFenced: Boolean;
    // A write to DMEM as one of the window's clocks makes it (a rewind
    // undoes it).
    procedure WriteAhead(Offset: Cardinal; Value: Byte);
    // The same for Count bytes at Offset (not past DMEM's end).
    procedure WriteAheadBytes(Offset: Cardinal; Source: PByte; Count: Cardinal);
    function JournalCount: Integer; inline;
    // The journal's entries, allocated once (JournalCapacity of them).
    function Journal: PRSPJournal;
    function JournalEntry(I: Integer): TRSPJournalEntry; inline;
    property OnPredict: TRSPPrediction read FPredict write FPredict;
    property OnDefer: TRSPDeferral read FDefer write FDefer;
    // The registers (a bit each) whose MTC0s ahead go into the journal
    // without a call to OnDefer (assigned): those it would leave to the
    // console as they are, its records of them kept up from the journal.
    property DeferSilent: Cardinal read FDeferSilent write FDeferSilent;
    property OnLift: TRSPFenceLift read FLift write FLift;
    // Whether clocks run from blocks where they can (on by default; the
    // same clocks either way).
    property UseBlocks: Boolean read FUseBlocks write FUseBlocks;
    property OnBlock: TRSPBlockDone read FOnBlock write FOnBlock;
    // Blocks worked out, and run (each time a clock loop took one), with the
    // clocks they took.
    property BlocksBuilt: Int64 read FBlocksBuilt;
    property BlocksRun: Int64 read FBlocksRun;
    property BlockClocks: Int64 read FBlockClocks;
    // Blocks run as generated code where HW.JIT can make it (the same clocks
    // either way); whether there is generated code here (a backend, not
    // N64RSPJIT=off).
    property UseJit: Boolean read FUseJit write FUseJit;
    class function JitAvailable: Boolean; static;
    // Tests: blocks made generated code from their Hot+1th entry on (0: their
    // first), by HW.JIT's model with Model (RSPs that make their first code
    // after this).
    class procedure JitForTests(Hot: Integer; Model: Boolean); static;
    // Blocks made generated code, and runs of it (each RunBlock entering it).
    property JitCompiled: Int64 read FJitCompiled;
    property JitRuns: Int64 read FJitRuns;
  public
    const
    // Journal entries one window may hold (the journal never grows, so the
    // console may read published entries while the window runs on).
      JournalCapacity = 16384;
  public
    // Why the last RunAhead ended.
    property AheadStop: TRSPAheadStop read FAheadStop;
    // The SP/DP register (0..15) of the COP0 access that ended it.
    property AheadStopIndex: Integer read FAheadStopIndex;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // Blocks as generated code where HW.JIT has a backend (N64_NO_JIT: never).
  RSPJit = {$IFDEF N64_NO_JIT}False{$ELSE}JitSupported{$ENDIF};

var
  // N64RSPJIT (debugging): off (no generated code), model (the code run by
  // HW.JIT's model, for the tests: much slower), stats (counts at the end),
  // hotN (entries of a block before its code is made).
  {$IF RSPJit}
  RSPJitOff, RSPJitModel: Boolean;
  {$ENDIF}
  RSPJitStats: Boolean;
  RSPJitHot: Integer = 16;

constructor TN64RSP.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  SetLength(FJournal, JournalCapacity);
  for var I := 0 to High(FDecStamp) do
    FDecStamp[I] := NotDecoded;
  FUseBlocks := True;
  {$IF RSPJit}
  FUseJit := not RSPJitOff;
  {$ENDIF}
  // (Whole 64-bit words of the vector registers are read and written.)
  if (NativeUInt(@FVec[0, 0]) and 7) <> 0 then
    raise EInvalidOpException.Create('RSP vector registers not 8-byte aligned');
  ClearBlocks;
  Reset
end;

destructor TN64RSP.Destroy;
const
  Names: array[0..15] of string = ('budget', 'bubble budget', 'branch pending', 'not linked', '-',
    'IMEM written', 'no code', 'checks', 'clocks', 'enter: checks', 'enter: clocks', 'enter: no code', 'enter: cold',
    '  of which gen.', '  of which ext.', '  of which mem.');
begin
  if IsConsole and RSPJitStats then
  begin
    Writeln(ErrOutput, Format('RSP JIT: %d blocks compiled, %d runs; %d blocks run, %d built', [FJitCompiled, FJitRuns,
      FBlocksRun, FBlocksBuilt]));
    for var K := 0 to High(Names) do
      if FJitBack[K] <> 0 then
        Writeln(ErrOutput, Format('  %-16s %d', [Names[K], FJitBack[K]]));
    for var K := 0 to 255 do
      if FJitGen[K] > 10000 then
        Writeln(ErrOutput, Format('  general op %d: %d', [K, FJitGen[K]]));
  end;
  FJit.Free;
  inherited;
end;

procedure TN64RSP.Reset;
begin
  for var I := 0 to 31 do
  begin
    FReg[I] := 0;
    for var J := 0 to 7 do
      FVec[I, J] := 0
  end;
  for var I := 0 to 7 do
    FAcc[I] := 0;
  FVCO := 0;
  FVCC := 0;
  FVCE := 0;
  FDivisionHigh := False;
  FDivisionInput := 0;
  FDivisionResult := 0;
  ResetPipeline;
  EndAhead;
end;

procedure TN64RSP.ResetPipeline;
begin
  FNextPC := 0;
  FBranch := False;
  for var I := 0 to 31 do
  begin
    FScalarReady[I] := 0;
    FVectorReady[I] := 0
  end;
  FScalarLo := 0;
  FScalarHi := 0;
  FVectorLo := 0;
  FVectorHi := 0;
  FSingleIssue := 0;
  FStalledSecondOpcode := 0;
  FHasStalledSecondOpcode := False;
  FLoadHistory := 0;
  FBranchBubble := 0;
  FStalledOpcode := 0;
  FStalledPC := 0;
  FHasStalledOpcode := False;
end;

function TN64RSP.DMemRead(Offset: Cardinal): Byte;
begin
  // Offset is already wrapped to DMEM. The bus contract makes SP memory exact.
  if FBus.DirectMemory then
    Result := FBus.ReadSP8(Offset)
  else
    Result := FBus.Read8($04000000 + Offset);
end;

procedure TN64RSP.DMemWrite(Offset: Cardinal; Value: Byte);
begin
  if FAhead and (FLineRun[Offset shr 6] <> FRun) then
    SaveLine(Offset);
  if FBus.DirectMemory then
    FBus.WriteSP8(Offset, Value)
  else
    FBus.Write8($04000000 + Offset, Value);
end;

function TN64RSP.IMemRead32(PC: Cardinal): Cardinal;
begin
  var Offset := $1000 + (PC and $FFC);
  if FBus.DirectMemory then
    Result := FBus.ReadSP32(Offset)
  else
    Result := FBus.Read32($04000000 + Offset);
end;

class procedure TN64RSP.MasksOf(const Info: TRSPTimingInfo; IsExternal: Boolean; out Masks: TRSPIssueMasks);
begin
  Masks.Flags := Info.Flags;
  Masks.Sources := Info.RRead;
  Masks.Vectors := Info.VRead;
  Masks.ScalarWrites := 0;
  if (Info.Flags and 32) = 0 then
    Masks.ScalarWrites := Info.RWrite;
  Masks.VectorWrites := Info.VWrite;
  Masks.external := IsExternal;
end;

class procedure TN64RSP.Combine(const A, B: TRSPTimingInfo; ExternalA, ExternalB: Boolean; out Masks: TRSPIssueMasks);
begin
  var Second: TRSPIssueMasks;
  MasksOf(A, ExternalA, Masks);
  MasksOf(B, ExternalB, Second);
  Masks.Flags := Masks.Flags or Second.Flags;
  Masks.Sources := Masks.Sources or Second.Sources;
  Masks.Vectors := Masks.Vectors or Second.Vectors;
  Masks.ScalarWrites := Masks.ScalarWrites or Second.ScalarWrites;
  Masks.VectorWrites := Masks.VectorWrites or Second.VectorWrites;
  Masks.external := Masks.external or Second.external;
end;

procedure TN64RSP.Decode(Slot: Integer; Op: Cardinal; Stamp: UInt64);
begin
  FDec[Slot].Op := Op;
  FDec[Slot].Info := InfoEXECUTE(Op);
  MasksOf(FDec[Slot].Info, external(Op), FDec[Slot].Single);
  FDec[Slot].PairValid := False;
  FDecStamp[Slot] := Stamp;
end;

procedure TN64RSP.DecodePair(Slot: Integer);
begin
  // Both slots are decoded.
  var Next := (Slot + 1) and 1023;
  FDec[Slot].SecondOp := FDec[Next].Op;
  FDec[Slot].CanPair := CanPair(FDec[Slot].Info, FDec[Next].Info);
  Combine(FDec[Slot].Info, FDec[Next].Info, FDec[Slot].Single.external, FDec[Next].Single.external, FDec[Slot].Paired);
  FDec[Slot].PairValid := True;
end;

function TN64RSP.DecodedSlot(Slot: Integer): Integer;
begin
  if FBus.DirectMemory then
  begin
    if FDecStamp[Slot] <> FBus.IMemStamp(Slot) then
      Decode(Slot, FBus.IMemWord(Slot), FBus.IMemStamp(Slot));
  end
  else
  begin
    // Without the bus's stamps: compare the word itself.
    var Op := IMemRead32(Cardinal(Slot) * 4);
    if (FDecStamp[Slot] = NotDecoded) or (FDec[Slot].Op <> Op) then
      Decode(Slot, Op, 0);
  end;
  Result := Slot;
end;

procedure TN64RSP.PlanesToArrays;
begin
  for var I := 0 to 31 do
  begin
    var Bit := Cardinal(1) shl I;
    FScalarReady[I] := Byte(Ord((FScalarLo and Bit) <> 0) + 2 * Ord((FScalarHi and Bit) <> 0));
    FVectorReady[I] := Byte(Ord((FVectorLo and Bit) <> 0) + 2 * Ord((FVectorHi and Bit) <> 0));
  end;
end;

procedure TN64RSP.ArraysToPlanes;
begin
  FScalarLo := 0;
  FScalarHi := 0;
  FVectorLo := 0;
  FVectorHi := 0;
  for var I := 0 to 31 do
  begin
    var Bit := Cardinal(1) shl I;
    if (FScalarReady[I] and 1) <> 0 then
      FScalarLo := FScalarLo or Bit;
    if (FScalarReady[I] and 2) <> 0 then
      FScalarHi := FScalarHi or Bit;
    if (FVectorReady[I] and 1) <> 0 then
      FVectorLo := FVectorLo or Bit;
    if (FVectorReady[I] and 2) <> 0 then
      FVectorHi := FVectorHi or Bit;
  end;
end;

function TN64RSP.GetByte(R, Index: Integer): Byte;
begin
  Index := Index and 15;
  if Odd(Index) then
    Result := Byte(FVec[R, Index div 2] and $FF)
  else
    Result := Byte(FVec[R, Index div 2] shr 8);
end;

procedure TN64RSP.SetByte(R, Index: Integer; Value: Byte);
begin
  Index := Index and 15;
  if Odd(Index) then
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF00) or Value
  else
    FVec[R, Index div 2] := (FVec[R, Index div 2] and $FF) or (Word(Value) shl 8);
end;

var
  // The divider's tables (VectorDivide, InitDivideTables): ReciprocalTable
  // by the 9 bits after the input's leading one, SquareRootTable by the 8 of
  // them it takes, the shift's parity in the lowest bit.
  ReciprocalTable, SquareRootTable: array[0..511] of Word;

function S16(Value: Word): Integer; inline;
begin
  Result := SmallInt(Value);
end;

function W16(Value: Int64): Word; inline;
begin
  Result := Word(Value and $FFFF)
end;

// Value clamped to 16 signed bits (compares here: EnsureRange is a call).
function ClampSigned(Value: Integer): Word; overload; inline;
begin
  if Value > 32767 then
    Result := $7FFF
  else if Value < -32768 then
    Result := $8000
  else
    Result := Word(Value and $FFFF);
end;

function ClampSigned(Value: Int64): Word; overload; inline;
begin
  if Value > 32767 then
    Result := $7FFF
  else if Value < -32768 then
    Result := $8000
  else
    Result := Word(Value and $FFFF);
end;

function TN64RSP.AccHi(I: Integer): Word;
begin
  Result := Word((FAcc[I] shr 32) and $FFFF);
end;

function TN64RSP.AccMid(I: Integer): Word;
begin
  Result := Word((FAcc[I] shr 16) and $FFFF);
end;

function TN64RSP.AccLo(I: Integer): Word;
begin
  Result := Word(FAcc[I] and $FFFF);
end;

function Wrap48(Value: Int64): Int64; inline;
begin
  // The low 48 bits (the guest's accumulator wraps there), sign-extended; a
  // sum of a lane and a product rarely leaves them.
  // In range: bits 47..63 all equal (no 64-bit constants in the check).
  Result := Value;
  if (((UInt64(Value) shr 47) + 1) and $1FFFF) > 1 then
    Result := ((Value and $FFFFFFFFFFFF) xor $800000000000) - $800000000000;
end;

procedure TN64RSP.SetAcc(I: Integer; Value: Int64);
begin
  // A sum of a lane and a product needs no other wrapping.
  FAcc[I] := Wrap48(Value);
end;

procedure TN64RSP.SetAccLo(I: Integer; Value: Word);
begin
  // The low slice only (bit 47, the sign, stays): its two bytes, the
  // lowest of the lane (little-endian hosts only), as in the routines below.
  PWord(@FAcc[I])^ := Value;
end;

function AccClampMid(Acc: Int64): Word; inline;
begin
  // The accumulator's bits 16..47 as a signed value, clamped to 16 bits.
  if UInt64(Acc + $80000000) <= $FFFFFFFF then
    Result := Word((Acc shr 16) and $FFFF)
  else if Acc < 0 then
    Result := $8000
  else
    Result := $7FFF;
end;

function AccClampLow(Acc: Int64): Word; inline;
begin
  // VMADL/VMADN: the low slice when the accumulator fits 32 signed bits,
  // else 0 below and $FFFF above.
  if UInt64(Acc + $80000000) <= $FFFFFFFF then
    Result := Word(Acc and $FFFF)
  else if Acc < 0 then
    Result := 0
  else
    Result := $FFFF;
end;

function TN64RSP.VTLanes(Op: Cardinal; var Copy: TRSPQuadLanes): PRSPLanes;
begin
  // Op's VT with its element applied: the register itself when that selects
  // lane I for lane I (an instruction reads lane I of its sources before it
  // writes lane I of VD, so VD may be VT), else Copy, filled four lanes at a
  // time (lane 0 lowest: little-endian hosts only).
  var T := Integer((Op shr 16) and 31);
  var E := Integer((Op shr 21) and 15);
  if E < 2 then
    Exit(@FVec[T]);
  if E >= 8 then
  begin
    // One lane for all.
    var Q := UInt64(FVec[T, E - 8]) * UInt64($0001000100010001);
    Copy.Quads[0] := Q;
    Copy.Quads[1] := Q;
  end
  else if E >= 4 then
  begin
    // Lane E - 4 for the first four, lane E for the others.
    Copy.Quads[0] := UInt64(FVec[T, E - 4]) * UInt64($0001000100010001);
    Copy.Quads[1] := UInt64(FVec[T, E]) * UInt64($0001000100010001);
  end
  else
  begin
    // Lane E - 2 (+ 2, 4, 6) for each pair.
    var A := E - 2;
    Copy.Quads[0] := (UInt64(FVec[T, A]) * $10001) or ((UInt64(FVec[T, A + 2]) * $10001) shl 32);
    Copy.Quads[1] := (UInt64(FVec[T, A + 4]) * $10001) or ((UInt64(FVec[T, A + 6]) * $10001) shl 32);
  end;
  Result := @Copy.Lanes;
end;

procedure TN64RSP.VectorOp(Op: Cardinal);
begin
  // Each family reads VS lane by lane before writing that VD lane, and VT
  // from a copy, so VD may be VS or VT.
  case Op and 63 of
    0, 1, 8, 9:
      VectorMulFrac(Op);
    2, 10:
      VectorRound(Op);
    3, 11:
      VectorMulQ(Op);
    4..7, 12..15:
      VectorMul(Op);
    16, 17:
      VectorAddSub(Op);
    19:
      VectorAbs(Op);
    20, 21:
      VectorCarry(Op);
    29:
      VectorSar(Op);
    32:
      VectorLT(Op);
    33:
      VectorEQ(Op);
    34:
      VectorNE(Op);
    35:
      VectorGE(Op);
    36:
      VectorClipLow(Op);
    37:
      VectorCH(Op);
    38:
      VectorCR(Op);
    39:
      VectorMerge(Op);
    40..45:
      VectorLogic(Op);
    48..54:
      VectorDivide(Op);
    55, 63:
      ; // VNULL encodings: no effect.
  else
    VectorReserved(Op);
  end;
end;

procedure TN64RSP.VectorMulFrac(Op: Cardinal);
begin
  // VMULF, VMULU (product * 2 + rounding), VMACF, VMACU (accumulate).
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var Fn := Op and 63;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(VS[I]) * S16(VT[I])) * 2;
    var Acc: Int64;
    if Fn < 8 then
      Acc := V + $8000
    else
      Acc := Wrap48(FAcc[I] + V);
    FAcc[I] := Acc;
    if (Fn and 1) = 0 then
      VD[I] := AccClampMid(Acc)
    else if Acc < 0 then
      VD[I] := 0
    else if Acc >= $80000000 then
      VD[I] := $FFFF
    else
      VD[I] := Word((Acc shr 16) and $FFFF);
  end;
end;

procedure TN64RSP.VectorRound(Op: Cardinal);
begin
  // VRNDP (if ACC >= 0), VRNDN (if ACC < 0): ACC += VT, shifted when VS is odd.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Negative := (Op and 63) = 10;
  for var I := 0 to 7 do
  begin
    var V := Int64(S16(VT[I]));
    if (S and 1) <> 0 then
      V := V * 65536;
    if (FAcc[I] < 0) = Negative then
      SetAcc(I, FAcc[I] + V);
    FVec[D, I] := AccClampMid(FAcc[I]);
  end;
end;

procedure TN64RSP.VectorMulQ(Op: Cardinal);
begin
  // VMULQ (product, biased when negative) and VMACQ (ACC_HI/MD rounded by 32).
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Accumulate := (Op and 63) = 11;
  for var I := 0 to 7 do
  begin
    var V: Int64;
    if Accumulate then
    begin
      // ACC bits 16..47, signed.
      V := Int64(Integer(Cardinal((FAcc[I] shr 16) and $FFFFFFFF)));
      if (V < -32) and ((V and 32) = 0) then
        Inc(V, 32)
      else if (V > 32) and ((V and 32) = 0) then
        Dec(V, 32);
      SetAcc(I, V * 65536 + AccLo(I));
    end
    else
    begin
      V := Int64(S16(FVec[S, I])) * S16(VT[I]);
      if V < 0 then
        Inc(V, 31);
      SetAcc(I, V * 65536);
    end;
    var Half := V div 2;
    if (V < 0) and Odd(V) then
      Dec(Half);
    FVec[D, I] := ClampSigned(Half) and $FFF0;
  end;
end;

procedure TN64RSP.VectorMul(Op: Cardinal);
begin
  // VMUDL/VMUDM/VMUDN/VMUDH set ACC to the product, VMADL/VMADM/VMADN/VMADH
  // add it; the products fit 32 bits. Each reads lane I of its sources
  // before it writes lane I of VD (VT from a copy when selected).
  case Op and 63 of
    4:
      VectorMUDL(Op);
    5:
      VectorMUDM(Op);
    6:
      VectorMUDN(Op);
    7:
      VectorMUDH(Op);
    12:
      VectorMADL(Op);
    13:
      VectorMADM(Op);
    14:
      VectorMADN(Op);
  else
    VectorMADH(Op);
  end;
end;

procedure TN64RSP.VectorMUDL(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var V := Word(((Cardinal(VS[I]) * VT[I]) shr 16) and $FFFF);
    A[I] := V;
    VD[I] := V;
  end;
end;

procedure TN64RSP.VectorMUDM(Op: Cardinal);
begin
  // The products fit the accumulator as they are.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(S16(VS[I]) * Integer(VT[I]));
    A[I] := Acc;
    VD[I] := AccClampMid(Acc);
  end;
end;

procedure TN64RSP.VectorMUDN(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(Integer(VS[I]) * S16(VT[I]));
    A[I] := Acc;
    VD[I] := Word(Acc and $FFFF);
  end;
end;

procedure TN64RSP.VectorMUDH(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var P := S16(VS[I]) * S16(VT[I]);
    A[I] := Int64(P) * 65536;
    VD[I] := ClampSigned(P);
  end;
end;

procedure TN64RSP.VectorMADL(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + ((Cardinal(VS[I]) * VT[I]) shr 16);
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampLow(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADM(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + S16(VS[I]) * Integer(VT[I]);
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc shr 16);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampMid(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADN(Op: Cardinal);
begin
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + Integer(VS[I]) * S16(VT[I]);
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampLow(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADH(Op: Cardinal);
begin
  // Bits 16..47 change only (a 32-bit sum, wrapped).
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + Int64(S16(VS[I]) * S16(VT[I])) * 65536;
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc shr 16);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampMid(Acc);
    end;
  end;
end;

// The multiplies with element 8..15, one VT lane for all (read before VD is
// written: VD may be VT), as the routines above.

procedure TN64RSP.VectorMUDLOne(Op: Cardinal);
begin
  var T := Cardinal(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var V := Word(((Cardinal(VS[I]) * T) shr 16) and $FFFF);
    A[I] := V;
    VD[I] := V;
  end;
end;

procedure TN64RSP.VectorMUDMOne(Op: Cardinal);
begin
  var T := Integer(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(S16(VS[I]) * T);
    A[I] := Acc;
    VD[I] := AccClampMid(Acc);
  end;
end;

procedure TN64RSP.VectorMUDNOne(Op: Cardinal);
begin
  var T := S16(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := Int64(Integer(VS[I]) * T);
    A[I] := Acc;
    VD[I] := Word(Acc and $FFFF);
  end;
end;

procedure TN64RSP.VectorMUDHOne(Op: Cardinal);
begin
  var T := S16(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var P := S16(VS[I]) * T;
    A[I] := Int64(P) * 65536;
    VD[I] := ClampSigned(P);
  end;
end;

procedure TN64RSP.VectorMADLOne(Op: Cardinal);
begin
  var T := Cardinal(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + ((Cardinal(VS[I]) * T) shr 16);
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampLow(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADMOne(Op: Cardinal);
begin
  var T := Integer(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + S16(VS[I]) * T;
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc shr 16);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampMid(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADNOne(Op: Cardinal);
begin
  var T := S16(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + Integer(VS[I]) * T;
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampLow(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorMADHOne(Op: Cardinal);
begin
  var T := S16(FVec[(Op shr 16) and 31, ((Op shr 21) and 15) - 8]);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
  begin
    var Acc := A[I] + Int64(S16(VS[I]) * T) * 65536;
    // (In 32 signed bits, as mostly: in 48 too, and no clamp.)
    if UInt64(Acc + $80000000) <= $FFFFFFFF then
    begin
      A[I] := Acc;
      VD[I] := Word(Acc shr 16);
    end
    else
    begin
      Acc := Wrap48(Acc);
      A[I] := Acc;
      VD[I] := AccClampMid(Acc);
    end;
  end;
end;

procedure TN64RSP.VectorAddSub(Op: Cardinal);
begin
  // VADD, VSUB with the VCO carry; clear VCO.
  if (Op and 63) = 17 then
    VectorSub(Op)
  else
    VectorAdd(Op);
end;

const
  // Four 16-bit lanes in a 64-bit word (SWAR): all but their sign bits,
  // their sign bits, a 1 in each.
  RSPLaneLow = UInt64($7FFF7FFF7FFF7FFF);
  RSPLaneSign = UInt64($8000800080008000);
  RSPLaneOne = UInt64($0001000100010001);

var
  // A 1 in lane K of four for bit K of a nibble (VCO's carries).
  RSPNibbleLanes: array[0..15] of UInt64;

function SatAdd4(A, B, C: UInt64; out Sum: UInt64): UInt64; inline;
begin
  // Four signed 16-bit lanes at once: A + B + C (C a lane's 0 or 1), wrapped
  // to 16 bits (Sum) and clamped to them (the result). The sign bits are
  // added apart, so that no carry crosses into the next lane; a lane
  // overflows where A and B have one sign and the sum the other, then is
  // $7FFF or $8000 by A's sign.
  var S := ((A and RSPLaneLow) + (B and RSPLaneLow)) xor ((A xor B) and RSPLaneSign);
  S := ((S and RSPLaneLow) + C) xor (S and RSPLaneSign);
  Sum := S;
  var M := ((((not (A xor B)) and (A xor S)) and RSPLaneSign) shr 15) * $FFFF;
  Result := (S and not M) or ((RSPLaneLow + ((A shr 15) and RSPLaneOne)) and M);
end;

{$IF Defined(CPU64BITS)}
procedure TN64RSP.SetAccLoQuads(Lo0, Lo1: UInt64);
begin
  // Each lane's ACC_LO from four lanes at a time (Lo0: lanes 0..3).
  PWord(@FAcc[0])^ := Word(Lo0);
  PWord(@FAcc[1])^ := Word(Lo0 shr 16);
  PWord(@FAcc[2])^ := Word(Lo0 shr 32);
  PWord(@FAcc[3])^ := Word(Lo0 shr 48);
  PWord(@FAcc[4])^ := Word(Lo1);
  PWord(@FAcc[5])^ := Word(Lo1 shr 16);
  PWord(@FAcc[6])^ := Word(Lo1 shr 32);
  PWord(@FAcc[7])^ := Word(Lo1 shr 48);
end;

// More of four lanes at a time: a 1 in a lane where it is equal, below
// (unsigned), less (signed); the wrapped difference and sum; a sum's carry
// out (a 1 in the lane); a lane's 1 widened to $FFFF; the four lanes' 1s as
// four bits (lane 0 lowest).

function LaneEqual4(A, B: UInt64): UInt64; inline;
begin
  var Z := A xor B;
  Result := (((((Z and RSPLaneLow) + RSPLaneLow) or Z) and RSPLaneSign) xor RSPLaneSign) shr 15;
end;

function LaneDiff4(A, B: UInt64): UInt64; inline;
begin
  Result := ((A or RSPLaneSign) - (B and RSPLaneLow)) xor ((A xor not B) and RSPLaneSign);
end;

function LaneBelow4(A, B: UInt64): UInt64; inline;
begin
  // A borrow out of the lane: B's top bit over A's, or equal top bits and a
  // borrow from below (the difference's top bit then).
  var D := LaneDiff4(A, B);
  Result := ((((not A) and B) or ((not (A xor B)) and D)) and RSPLaneSign) shr 15;
end;

function LaneLess4(A, B: UInt64): UInt64; inline;
begin
  Result := LaneBelow4(A xor RSPLaneSign, B xor RSPLaneSign);
end;

function LaneSum4(A, B: UInt64): UInt64; inline;
begin
  Result := ((A and RSPLaneLow) + (B and RSPLaneLow)) xor ((A xor B) and RSPLaneSign);
end;

function LaneCarry4(A, B, S: UInt64): UInt64; inline;
begin
  Result := (((A and B) or ((A or B) and not S)) and RSPLaneSign) shr 15;
end;

function LaneMask4(F: UInt64): UInt64; inline;
begin
  Result := (F shl 16) - F;
end;

function LaneNibble4(F: UInt64): Cardinal; inline;
begin
  Result := Cardinal((F or (F shr 15) or (F shr 30) or (F shr 45)) and 15);
end;

procedure TN64RSP.SelectQuads(Op: Cardinal; VS, VT: PRSPQuadLanes; T0, T1: UInt64);
begin
  // The compares' and VMRG's result: VS's lanes where T0, T1 (lanes 0..3,
  // 4..7) have a 1, else VT's, into VD and ACC_LO; VCO cleared.
  var R0 := VT.Quads[0] xor ((VS.Quads[0] xor VT.Quads[0]) and LaneMask4(T0));
  var R1 := VT.Quads[1] xor ((VS.Quads[1] xor VT.Quads[1]) and LaneMask4(T1));
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  SetAccLoQuads(R0, R1);
  FVCO := 0;
end;
{$ENDIF}

procedure TN64RSP.VectorAdd(Op: Cardinal);
begin
  // VADD with the VCO carries (VS + VT + carry, clamped; the sum wrapped
  // into ACC_LO); VCO cleared. 64-bit hosts four lanes at a time, 32-bit
  // ones (which split each 64-bit operation) a lane at a time.
  var Copy: TRSPQuadLanes;
  var Carry := Cardinal(FVCO);
  {$IF Defined(CPU64BITS)}
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  var Sum0, Sum1: UInt64;
  var R0 := SatAdd4(VS.Quads[0], VT.Quads[0], RSPNibbleLanes[Carry and 15], Sum0);
  var R1 := SatAdd4(VS.Quads[1], VT.Quads[1], RSPNibbleLanes[(Carry shr 4) and 15], Sum1);
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  SetAccLoQuads(Sum0, Sum1);
  {$ELSE}
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  for var I := 0 to 7 do
  begin
    var V := S16(VS[I]) + S16(VT[I]) + Integer(Carry and 1);
    Carry := Carry shr 1;
    PWord(@FAcc[I])^ := Word(V);
    VD[I] := ClampSigned(V);
  end;
  {$ENDIF}
  FVCO := 0;
end;

procedure TN64RSP.VectorSub(Op: Cardinal);
begin
  // VSUB: VS - VT - carry; 64-bit hosts as VS + not VT + (1 - carry), four
  // lanes at a time (as VectorAdd).
  var Copy: TRSPQuadLanes;
  var Carry := Cardinal(FVCO);
  {$IF Defined(CPU64BITS)}
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  var Sum0, Sum1: UInt64;
  var R0 := SatAdd4(VS.Quads[0], not VT.Quads[0], RSPLaneOne - RSPNibbleLanes[Carry and 15], Sum0);
  var R1 := SatAdd4(VS.Quads[1], not VT.Quads[1], RSPLaneOne - RSPNibbleLanes[(Carry shr 4) and 15], Sum1);
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  SetAccLoQuads(Sum0, Sum1);
  {$ELSE}
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  for var I := 0 to 7 do
  begin
    var V := S16(VS[I]) - S16(VT[I]) - Integer(Carry and 1);
    Carry := Carry shr 1;
    PWord(@FAcc[I])^ := Word(V);
    VD[I] := ClampSigned(V);
  end;
  {$ENDIF}
  FVCO := 0;
end;

procedure TN64RSP.VectorAbs(Op: Cardinal);
begin
  // VABS: VT negated, kept or zeroed by the sign of VS.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    var A := S16(FVec[S, I]);
    var V := 0;
    if A < 0 then
      V := -S16(VT[I])
    else if A > 0 then
      V := S16(VT[I]);
    SetAccLo(I, Word(V and $FFFF));
    FVec[D, I] := ClampSigned(V);
  end;
end;

procedure TN64RSP.VectorCarry(Op: Cardinal);
begin
  // VADDC (carry out), VSUBC (borrow and not-equal) into VCO.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  var R0, R1: UInt64;
  if (Op and 63) = 20 then
  begin
    R0 := LaneSum4(VS.Quads[0], VT.Quads[0]);
    R1 := LaneSum4(VS.Quads[1], VT.Quads[1]);
    FVCO := Word(LaneNibble4(LaneCarry4(VS.Quads[0], VT.Quads[0], R0)) or
      (LaneNibble4(LaneCarry4(VS.Quads[1], VT.Quads[1], R1)) shl 4));
  end
  else
  begin
    R0 := LaneDiff4(VS.Quads[0], VT.Quads[0]);
    R1 := LaneDiff4(VS.Quads[1], VT.Quads[1]);
    var Borrow := LaneNibble4(LaneBelow4(VS.Quads[0], VT.Quads[0])) or
      (LaneNibble4(LaneBelow4(VS.Quads[1], VT.Quads[1])) shl 4);
    var NotEqual := LaneNibble4(LaneEqual4(VS.Quads[0], VT.Quads[0]) xor RSPLaneOne) or
      (LaneNibble4(LaneEqual4(VS.Quads[1], VT.Quads[1]) xor RSPLaneOne) shl 4);
    FVCO := Word(Borrow or (NotEqual shl 8));
  end;
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  SetAccLoQuads(R0, R1);
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Carry: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var V: Integer;
    if (Op and 63) = 20 then
    begin
      V := Integer(FVec[S, I]) + VT[I];
      if V > $FFFF then
        Carry := Carry or (Cardinal(1) shl I);
    end
    else
    begin
      V := Integer(FVec[S, I]) - VT[I];
      if V < 0 then
        Carry := Carry or (Cardinal(1) shl I);
      if V <> 0 then
        Carry := Carry or (Cardinal(1) shl (I + 8));
    end;
    SetAccLo(I, Word(V and $FFFF));
    FVec[D, I] := Word(V and $FFFF);
  end;
  FVCO := Word(Carry);
  {$ENDIF}
end;

procedure TN64RSP.VectorSar(Op: Cardinal);
begin
  // VSAR: read one accumulator slice (E = 8, 9, 10), zero otherwise.
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
    case (Op shr 21) and 15 of
      8:
        FVec[D, I] := AccHi(I);
      9:
        FVec[D, I] := AccMid(I);
      10:
        FVec[D, I] := AccLo(I);
    else
      FVec[D, I] := 0;
    end;
end;

// VLT, VEQ, VNE, VGE: VS where the test holds, else VT, into VD and ACC_LO;
// VCC's low byte the tests, VCO cleared. The test per lane without
// branches (Test 0 or 1, the result picked by a mask).

procedure TN64RSP.VectorLT(Op: Cardinal);
begin
  // Less, or equal with VCO's carry and not-equal both set.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var Equal := Cardinal(FVCO) and (Cardinal(FVCO) shr 8);
  var T0 := LaneLess4(VS.Quads[0], VT.Quads[0]) or
    (LaneEqual4(VS.Quads[0], VT.Quads[0]) and RSPNibbleLanes[Equal and 15]);
  var T1 := LaneLess4(VS.Quads[1], VT.Quads[1]) or
    (LaneEqual4(VS.Quads[1], VT.Quads[1]) and RSPNibbleLanes[(Equal shr 4) and 15]);
  SelectQuads(Op, VS, VT, T0, T1);
  FVCC := Word(LaneNibble4(T0) or (LaneNibble4(T1) shl 4));
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var Equal := Cardinal(FVCO) and (Cardinal(FVCO) shr 8);
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var S := VS[I];
    var T := VT[I];
    var Test := Cardinal(Ord(S16(S) < S16(T))) or (Cardinal(Ord(S = T)) and (Equal shr I) and 1);
    Compare := Compare or (Test shl I);
    var R: Word := T xor ((S xor T) and Word(-Integer(Test)));
    PWord(@A[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  {$ENDIF}
end;

procedure TN64RSP.VectorEQ(Op: Cardinal);
begin
  // Equal, without VCO's not-equal.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var Kept := not (Cardinal(FVCO) shr 8);
  var T0 := LaneEqual4(VS.Quads[0], VT.Quads[0]) and RSPNibbleLanes[Kept and 15];
  var T1 := LaneEqual4(VS.Quads[1], VT.Quads[1]) and RSPNibbleLanes[(Kept shr 4) and 15];
  SelectQuads(Op, VS, VT, T0, T1);
  FVCC := Word(LaneNibble4(T0) or (LaneNibble4(T1) shl 4));
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var Kept := not (Cardinal(FVCO) shr 8);
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var S := VS[I];
    var T := VT[I];
    var Test := Cardinal(Ord(S = T)) and (Kept shr I) and 1;
    Compare := Compare or (Test shl I);
    var R: Word := T xor ((S xor T) and Word(-Integer(Test)));
    PWord(@A[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  {$ENDIF}
end;

procedure TN64RSP.VectorNE(Op: Cardinal);
begin
  // Not equal, or VCO's not-equal.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var NotEqual := Cardinal(FVCO) shr 8;
  var T0 := (LaneEqual4(VS.Quads[0], VT.Quads[0]) xor RSPLaneOne) or RSPNibbleLanes[NotEqual and 15];
  var T1 := (LaneEqual4(VS.Quads[1], VT.Quads[1]) xor RSPLaneOne) or RSPNibbleLanes[(NotEqual shr 4) and 15];
  SelectQuads(Op, VS, VT, T0, T1);
  FVCC := Word(LaneNibble4(T0) or (LaneNibble4(T1) shl 4));
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var NotEqual := Cardinal(FVCO) shr 8;
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var S := VS[I];
    var T := VT[I];
    var Test := Cardinal(Ord(S <> T)) or ((NotEqual shr I) and 1);
    Compare := Compare or (Test shl I);
    var R: Word := T xor ((S xor T) and Word(-Integer(Test)));
    PWord(@A[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  {$ENDIF}
end;

procedure TN64RSP.VectorGE(Op: Cardinal);
begin
  // Greater, or equal unless VCO's carry and not-equal are both set.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var Kept := not (Cardinal(FVCO) and (Cardinal(FVCO) shr 8));
  var T0 := LaneLess4(VT.Quads[0], VS.Quads[0]) or
    (LaneEqual4(VS.Quads[0], VT.Quads[0]) and RSPNibbleLanes[Kept and 15]);
  var T1 := LaneLess4(VT.Quads[1], VS.Quads[1]) or
    (LaneEqual4(VS.Quads[1], VT.Quads[1]) and RSPNibbleLanes[(Kept shr 4) and 15]);
  SelectQuads(Op, VS, VT, T0, T1);
  FVCC := Word(LaneNibble4(T0) or (LaneNibble4(T1) shl 4));
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var A: PRSPAccLanes := @FAcc;
  var Kept := not (Cardinal(FVCO) and (Cardinal(FVCO) shr 8));
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var S := VS[I];
    var T := VT[I];
    var Test := Cardinal(Ord(S16(S) > S16(T))) or (Cardinal(Ord(S = T)) and (Kept shr I) and 1);
    Compare := Compare or (Test shl I);
    var R: Word := T xor ((S xor T) and Word(-Integer(Test)));
    PWord(@A[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  {$ENDIF}
end;

procedure TN64RSP.VectorClipLow(Op: Cardinal);
begin
  // VCL: the clip compare continuing a VCH/VCR, from VCO, VCC and VCE; all
  // three cleared but for VCC's new flags.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var Acc: PRSPAccLanes := @FAcc;
  var CO := Cardinal(FVCO);
  var CC := Cardinal(FVCC);
  var CE := Cardinal(FVCE);
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var UA := Cardinal(VS[I]);
    var UB := Cardinal(VT[I]);
    var Low := (CC shr I) and 1;
    var High := (CC shr (I + 8)) and 1;
    var R: Word;
    if ((CO shr I) and 1) <> 0 then
    begin
      if ((CO shr (I + 8)) and 1) = 0 then
        if ((CE shr I) and 1) <> 0 then
          Low := Cardinal(Ord(UA + UB <= 65536))
        else
          Low := Cardinal(Ord(UA + UB = 0));
      // VT negated, or VS.
      R := Word(UA xor ((UA xor ((65536 - UB) and $FFFF)) and Word(-Integer(Low))));
    end
    else
    begin
      if ((CO shr (I + 8)) and 1) = 0 then
        High := Cardinal(Ord(UA >= UB));
      // VT, or VS.
      R := Word(UA xor ((UA xor UB) and Word(-Integer(High))));
    end;
    Compare := Compare or (Low shl I) or (High shl (I + 8));
    PWord(@Acc[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  FVCE := 0;
end;

procedure TN64RSP.VectorCH(Op: Cardinal);
begin
  // VCH: VCO, VCC and VCE for a following VCL.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var Acc: PRSPAccLanes := @FAcc;
  var Carry: Cardinal := 0;
  var Compare: Cardinal := 0;
  var Extension: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var A := S16(VS[I]);
    var UB := Cardinal(VT[I]);
    var B := S16(Word(UB));
    // VT's bits inverted, as a signed value.
    var NotB := S16(Word(UB xor $FFFF));
    var R := VS[I];
    var Low, High: Cardinal;
    // (Signs that differ keep the sum within 16 bits, equal ones the
    // difference.)
    if (A xor B) < 0 then
    begin
      var Sum := A + B;
      Low := Cardinal(Ord(Sum <= 0));
      High := Cardinal(Ord(B < 0));
      if Low <> 0 then
        R := Word((-B) and $FFFF);
      Carry := Carry or (Cardinal(1) shl I) or (Cardinal(Ord((Sum <> 0) and (A <> NotB))) shl (I + 8));
      Extension := Extension or (Cardinal(Ord(Sum = -1)) shl I);
    end
    else
    begin
      var Difference := A - B;
      Low := Cardinal(Ord(B < 0));
      High := Cardinal(Ord(Difference >= 0));
      if High <> 0 then
        R := Word(UB);
      Carry := Carry or (Cardinal(Ord((Difference <> 0) and (A <> NotB))) shl (I + 8));
    end;
    Compare := Compare or (Low shl I) or (High shl (I + 8));
    PWord(@Acc[I])^ := R;
    VD[I] := R;
  end;
  FVCO := Word(Carry);
  FVCC := Word(Compare);
  FVCE := Word(Extension);
end;

procedure TN64RSP.VectorCR(Op: Cardinal);
begin
  // VCR: VCC from the clip compare against VT (one's complement); VCO and
  // VCE cleared.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var VS: PRSPLanes := @FVec[(Op shr 11) and 31];
  var VD: PRSPLanes := @FVec[(Op shr 6) and 31];
  var Acc: PRSPAccLanes := @FAcc;
  var Compare: Cardinal := 0;
  for var I := 0 to 7 do
  begin
    var A := S16(VS[I]);
    var UB := Cardinal(VT[I]);
    var B := S16(Word(UB));
    var R := VS[I];
    var Low, High: Cardinal;
    if (A xor B) < 0 then
    begin
      Low := Cardinal(Ord(A + B + 1 <= 0));
      High := Cardinal(Ord(B < 0));
      if Low <> 0 then
        R := Word(UB xor $FFFF);
    end
    else
    begin
      Low := Cardinal(Ord(B < 0));
      High := Cardinal(Ord(A - B >= 0));
      if High <> 0 then
        R := Word(UB);
    end;
    Compare := Compare or (Low shl I) or (High shl (I + 8));
    PWord(@Acc[I])^ := R;
    VD[I] := R;
  end;
  FVCO := 0;
  FVCC := Word(Compare);
  FVCE := 0;
end;

procedure TN64RSP.VectorMerge(Op: Cardinal);
begin
  // VMRG: VS where VCC is set, else VT; clears VCO.
  {$IF Defined(CPU64BITS)}
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  SelectQuads(Op, VS, VT, RSPNibbleLanes[FVCC and 15], RSPNibbleLanes[(FVCC shr 4) and 15]);
  {$ELSE}
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    var R := VT[I];
    if ((FVCC shr I) and 1) <> 0 then
      R := FVec[S, I];
    SetAccLo(I, R);
    FVec[D, I] := R;
  end;
  FVCO := 0;
  {$ENDIF}
end;

procedure TN64RSP.VectorLogic(Op: Cardinal);
begin
  // VAND, VNAND, VOR, VNOR, VXOR, VNXOR: all lanes at once, as two 64-bit
  // words (the registers and the copy are 8-byte aligned); the result also
  // into each lane's ACC_LO.
  var Copy: TRSPQuadLanes;
  var VT := PRSPQuadLanes(VTLanes(Op, Copy));
  var VS := PRSPQuadLanes(@FVec[(Op shr 11) and 31]);
  var VD := PRSPQuadLanes(@FVec[(Op shr 6) and 31]);
  var R0, R1: UInt64;
  case Op and 7 of
    0:
      begin
        R0 := VS.Quads[0] and VT.Quads[0];
        R1 := VS.Quads[1] and VT.Quads[1];
      end;
    1:
      begin
        R0 := not (VS.Quads[0] and VT.Quads[0]);
        R1 := not (VS.Quads[1] and VT.Quads[1]);
      end;
    2:
      begin
        R0 := VS.Quads[0] or VT.Quads[0];
        R1 := VS.Quads[1] or VT.Quads[1];
      end;
    3:
      begin
        R0 := not (VS.Quads[0] or VT.Quads[0]);
        R1 := not (VS.Quads[1] or VT.Quads[1]);
      end;
    4:
      begin
        R0 := VS.Quads[0] xor VT.Quads[0];
        R1 := VS.Quads[1] xor VT.Quads[1];
      end;
  else
    R0 := not (VS.Quads[0] xor VT.Quads[0]);
    R1 := not (VS.Quads[1] xor VT.Quads[1]);
  end;
  VD.Quads[0] := R0;
  VD.Quads[1] := R1;
  {$IF Defined(CPU64BITS)}
  SetAccLoQuads(R0, R1);
  {$ELSE}
  for var I := 0 to 7 do
    PWord(@FAcc[I])^ := VD.Lanes[I];
  {$ENDIF}
end;

procedure TN64RSP.VectorReserved(Op: Cardinal);
begin
  // Reserved encodings still execute: VS + VT to ACC_LO, VD zeroed.
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  for var I := 0 to 7 do
  begin
    SetAccLo(I, Word((S16(FVec[S, I]) + S16(VT[I])) and $FFFF));
    FVec[D, I] := 0;
  end;
end;

procedure TN64RSP.VectorDivide(Op: Cardinal);
begin
  // VRCP, VRCPL, VRCPH, VMOV, VRSQ, VRSQL, VRSQH: one lane of VD; every
  // ACC_LO lane gets the selected VT.
  var E := (Op shr 21) and 15;
  var T := (Op shr 16) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  var DE := ((Op shr 11) and 31) and 7;
  var Copy: TRSPQuadLanes;
  var VT := VTLanes(Op, Copy);
  // The scalar divider always takes the raw E&7 lane of VT.
  var Source := FVec[T, E and 7];
  var A: PRSPAccLanes := @FAcc;
  for var I := 0 to 7 do
    PWord(@A[I])^ := VT[I];
  if Fn = 51 then
    FVec[D, DE] := VT[DE]
  else if Fn in [50, 54] then
  begin
    FVec[D, DE] := FDivisionResult;
    FDivisionInput := Source;
    FDivisionHigh := True;
  end
  else
  begin
    var Input := Integer(SignedValue(SX(Source, 16)));
    if FDivisionHigh and (Fn in [49, 53]) then
      Input := Integer(SignedValue(SX((Cardinal(FDivisionInput) shl 16) or Source, 32)));
    var Data: Cardinal;
    var SignMask: Cardinal := 0;
    if Input < 0 then
      SignMask := $FFFFFFFF;
    Data := Cardinal(Int64(Input) and $FFFFFFFF) xor SignMask;
    if (Input < 0) and (Input > -32768) then
      Inc(Data);
    var Value: Cardinal := $7FFFFFFF;
    if Input = -32768 then
      Value := $FFFF0000
    else if Data <> 0 then
    begin
      // Data's leading zeros, shifted out.
      var Shift := 0;
      if (Data and $FFFF0000) = 0 then
      begin
        Data := Data shl 16;
        Inc(Shift, 16);
      end;
      if (Data and $FF000000) = 0 then
      begin
        Data := Data shl 8;
        Inc(Shift, 8);
      end;
      if (Data and $F0000000) = 0 then
      begin
        Data := Data shl 4;
        Inc(Shift, 4);
      end;
      if (Data and $C0000000) = 0 then
      begin
        Data := Data shl 2;
        Inc(Shift, 2);
      end;
      if (Data and $80000000) = 0 then
      begin
        Data := Data shl 1;
        Inc(Shift);
      end;
      var Index := (Data shr 22) and 511;
      if Fn in [52, 53] then
        Value := (((Cardinal($10000) or SquareRootTable[(Index and 510) or Cardinal(Shift and 1)]) shl 14) shr
          ((31 - Shift) div 2)) xor SignMask
      else
        Value := (((Cardinal($10000) or ReciprocalTable[Index]) shl 14) shr (31 - Shift)) xor SignMask;
    end;
    FVec[D, DE] := Word(Value and $FFFF);
    FDivisionResult := Word(Value shr 16);
    FDivisionHigh := False;
  end;
end;

const
  // 64-bit hosts (x64, ARM64) load and store 8-byte words at any address;
  // 32-bit ones only aligned (ARM's LDRD, STRD).
  RSPUnaligned = {$IF Defined(CPU64BITS)}True{$ELSE}False{$ENDIF};

procedure TN64RSP.VectorMemoryDirect(Op: Cardinal; Writing: Boolean);
begin
  // VectorMemory's LBV, LSV, LLV, LDV, LQV and their stores with direct SP
  // memory: Size bytes from Address (LQV/SQV: up to the end of its 16-byte
  // line) to or from element E on, wrapping in DMEM. A load stops at element
  // 15, a store wraps around the elements.
  var Kind := Integer((Op shr 11) and 31);
  var E := Integer((Op shr 7) and 15);
  var Offset := Integer(Op and 63) - Integer(Op and 64);
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Cardinal(Offset * (1 shl Kind)) and $FFF)) and $FFF;
  var Size := 1 shl Kind;
  if Kind = 4 then
    Size := 16 - Integer(Address and 15);
  var SP := FBus.DMemBytes;
  var Lanes: PRSPLanes := @FVec[(Op shr 16) and 31];
  var I := 0;
  if Writing then
  begin
    if FAhead then
    begin
      // As DMemWrite before its first byte in a line (the 16 bytes at most
      // lie in the line of the first and of the last).
      var Last := (Address + Cardinal(Size) - 1) and $FFF;
      if FLineRun[Address shr 6] <> FRun then
        SaveLine(Address);
      if FLineRun[Last shr 6] <> FRun then
        SaveLine(Last);
    end;
    if not Odd(E) and (E + Size <= 16) and (Address + Cardinal(Size) <= $1000) then
    begin
      // Whole lanes to bytes that do not wrap: a 16-byte line in two
      // 8-byte words where the host takes them there (RSPUnaligned, else
      // aligned so; little-endian hosts only).
      var P := SP + Address;
      if (Size = 16) and (RSPUnaligned or ((NativeUInt(P) and 7) = 0)) then
      begin
        var Q := PRSPQuadLanes(Lanes);
        PUInt64(P)^ := ((Q.Quads[0] shr 8) and $00FF00FF00FF00FF) or ((Q.Quads[0] and $00FF00FF00FF00FF) shl 8);
        PUInt64(P + 8)^ := ((Q.Quads[1] shr 8) and $00FF00FF00FF00FF) or ((Q.Quads[1] and $00FF00FF00FF00FF) shl 8);
        I := 16;
      end
      else if (Size = 8) and (RSPUnaligned or ((NativeUInt(P) and 7) = 0)) then
      begin
        // SDV's four lanes in one 8-byte word.
        var L := E shr 1;
        var V := UInt64(Lanes[L]) or (UInt64(Lanes[L + 1]) shl 16) or (UInt64(Lanes[L + 2]) shl 32) or
          (UInt64(Lanes[L + 3]) shl 48);
        PUInt64(P)^ := ((V shr 8) and $00FF00FF00FF00FF) or ((V and $00FF00FF00FF00FF) shl 8);
        I := 8;
      end
      else
        while I + 1 < Size do
        begin
          var W := Lanes[(E + I) shr 1];
          P[I] := Byte(W shr 8);
          P[I + 1] := Byte(W and $FF);
          Inc(I, 2);
        end;
    end
    else if not Odd(E) then
      while I + 1 < Size do
      begin
        var W := Lanes[((E + I) and 15) shr 1];
        SP[(Address + Cardinal(I)) and $FFF] := Byte(W shr 8);
        SP[(Address + Cardinal(I + 1)) and $FFF] := Byte(W and $FF);
        Inc(I, 2);
      end;
    while I < Size do
    begin
      var Index := (E + I) and 15;
      if Odd(Index) then
        SP[(Address + Cardinal(I)) and $FFF] := Byte(Lanes[Index shr 1] and $FF)
      else
        SP[(Address + Cardinal(I)) and $FFF] := Byte(Lanes[Index shr 1] shr 8);
      Inc(I);
    end;
  end
  else
  begin
    Size := Min(Size, 16 - E);
    if not Odd(E) and (Address + Cardinal(Size) <= $1000) then
    begin
      // Whole lanes from bytes that do not wrap (as the store).
      var P := SP + Address;
      if (Size = 16) and (RSPUnaligned or ((NativeUInt(P) and 7) = 0)) then
      begin
        var Q := PRSPQuadLanes(Lanes);
        var Q0 := PUInt64(P)^;
        var Q1 := PUInt64(P + 8)^;
        Q.Quads[0] := ((Q0 shr 8) and $00FF00FF00FF00FF) or ((Q0 and $00FF00FF00FF00FF) shl 8);
        Q.Quads[1] := ((Q1 shr 8) and $00FF00FF00FF00FF) or ((Q1 and $00FF00FF00FF00FF) shl 8);
        I := 16;
      end
      else if (Size = 8) and (RSPUnaligned or ((NativeUInt(P) and 7) = 0)) then
      begin
        // LDV's four lanes from one 8-byte word.
        var L := E shr 1;
        var V := PUInt64(P)^;
        V := ((V shr 8) and $00FF00FF00FF00FF) or ((V and $00FF00FF00FF00FF) shl 8);
        Lanes[L] := Word(V);
        Lanes[L + 1] := Word(V shr 16);
        Lanes[L + 2] := Word(V shr 32);
        Lanes[L + 3] := Word(V shr 48);
        I := 8;
      end
      else
        while I + 1 < Size do
        begin
          Lanes[(E + I) shr 1] := (Word(P[I]) shl 8) or P[I + 1];
          Inc(I, 2);
        end;
    end
    else if not Odd(E) then
      while I + 1 < Size do
      begin
        Lanes[(E + I) shr 1] := (Word(SP[(Address + Cardinal(I)) and $FFF]) shl 8) or
          SP[(Address + Cardinal(I + 1)) and $FFF];
        Inc(I, 2);
      end;
    while I < Size do
    begin
      var Index := E + I;
      var B := SP[(Address + Cardinal(I)) and $FFF];
      if Odd(Index) then
        Lanes[Index shr 1] := (Lanes[Index shr 1] and $FF00) or B
      else
        Lanes[Index shr 1] := (Lanes[Index shr 1] and $FF) or (Word(B) shl 8);
      Inc(I);
    end;
  end;
end;

procedure TN64RSP.VectorMemory(Op: Cardinal; Writing: Boolean);
begin
  if (((Op shr 11) and 31) <= 4) and FBus.DirectMemory then
  begin
    VectorMemoryDirect(Op, Writing);
    Exit;
  end;
  var Base := (Op shr 21) and 31;
  var V := (Op shr 16) and 31;
  var Kind := (Op shr 11) and 31;
  var E := Integer((Op shr 7) and 15);
  var Offset := Integer(SignedValue(SX(Op and 127, 7)));
  var Size: Integer;
  case Kind of
    0..3:
      Size := 1 shl Kind;
    4, 5, 8..11:
      Size := 16;
    6, 7:
      Size := 8;
  else
    raise EN64Unsupported.CreateFmt('RSP vector memory opcode %d is not implemented', [Kind]);
  end;
  var Address := Cardinal(Add64(FReg[Base], SX(UInt64((Int64(Offset) * Size) and $FFFFFFFF), 32)) and $FFF);
  if Kind = 11 then
  begin
    var Start := Address and $FF8;
    var Position := (E + Integer(Address and 8)) and 15;
    if Writing then
      Position := (Integer(Address and 7) - (E and 14)) and 15;
    for var I := 0 to 7 do
      for var J := 0 to 1 do
      begin
        var R := Integer(V and 24) + ((E div 2 + I) and 7);
        var Element := I * 2 + J;
        if Writing then
        begin
          R := Integer(V and 24) + I;
          Element := (16 - (E and 14) + I * 2 + J) and 15
        end;
        var A := (Start + Cardinal(Position)) and $FFF;
        if Writing then
          DMemWrite(A, GetByte(R, Element))
        else
          SetByte(R, Element, DMemRead(A));
        Position := (Position + 1) and 15;
      end;
    Exit;
  end;
  if Kind = 10 then
  begin
    if not Writing then
      Exit; // LWV is a hardware no-op.
    var Start := Address and $FF8;
    var Position := Integer(Address and 7);
    for var I := 0 to 15 do
      DMemWrite(((Start + Cardinal((Position + I) and 15)) and $FFF), GetByte(V, E + I));
    Exit;
  end;
  if Kind in [8, 9] then
  begin
    var Start := Address and $FF8;
    var Position := Integer(Address and 7) - E;
    if Kind = 8 then
    begin
      for var I := 0 to 7 do
        if Writing then
        begin
          var Value := ((Cardinal(GetByte(V, E + I * 2)) shl 1) or (GetByte(V, E + I * 2 + 1) shr 7)) and $FF;
          DMemWrite(((Start + Cardinal((Integer(Address and 7) + I * 2) and 15)) and $FFF), Byte(Value));
        end
        else
          FVec[V, I] := Word(DMemRead(((Start + Cardinal((Position + I * 2) and 15)) and $FFF))) shl 7;
    end
    else if Writing then
    begin
      for var I := 0 to 3 do
      begin
        var Lane := -1;
        case E of
          0, 15:
            Lane := I;
          1:
            Lane := 4 + ((2 + I) and 3);
          4:
            Lane := (1 + I) and 3;
          5:
            Lane := 4 + ((3 + I) and 3);
          8:
            Lane := 4 + I;
          11:
            Lane := (3 + I) and 3;
          12:
            Lane := 4 + ((1 + I) and 3);
        end;
        var Value: Byte := 0;
        if Lane >= 0 then
          Value := Byte((FVec[V, Lane and 7] shr 7) and $FF);
        DMemWrite(((Start + Cardinal((Integer(Address and 7) + I * 4) and 15)) and $FFF), Value);
      end;
    end
    else
    begin
      var Temp: array[0..7] of Word;
      for var I := 0 to 3 do
      begin
        Temp[I] := Word(DMemRead(((Start + Cardinal((Position + I * 4) and 15)) and $FFF))) shl 7;
        Temp[I + 4] := Word(DMemRead(((Start + Cardinal((Position + I * 4 + 8) and 15)) and $FFF))) shl 7;
      end;
      for var I := E to Min(15, E + 7) do
        if (I and 1) = 0 then
          SetByte(V, I, Byte(Temp[I div 2] shr 8))
        else
          SetByte(V, I, Byte(Temp[I div 2] and $FF));
    end;
    Exit;
  end;
  if Kind = 4 then
    if Writing then
      Size := 16 - Integer(Address and 15)
    else
      Size := Min(16 - Integer(Address and 15), 16 - E);
  if Kind = 5 then
  begin
    Size := Integer(Address and 15);
    E := 16 - Size + E;
    Address := Address and $FF0;
    if not Writing then
      Size := Min(Size, 16 - E);
  end;
  if Kind in [6, 7] then
  begin
    for var I := 0 to 7 do
      if Writing then
      begin
        var Shift := 8;
        if (((E + I) and 15) >= 8) xor (Kind = 7) then
          Shift := 7;
        DMemWrite(((Address + Cardinal(I)) and $FFF), Byte((FVec[V, (E + I) and 7] shr Shift) and $FF));
      end
      else
      begin
        var Position := (Integer(Address and 7) - E + I) and 15;
        FVec[V, I] := Word(DMemRead((((Address and $FF8) + Cardinal(Position)) and $FFF))) shl (8 - Ord(Kind = 7));
      end;
  end
  else if FBus.DirectMemory then
  begin
    // The same bytes, a whole element at a time where an element's two
    // bytes are both moved. Run ahead, a store first saves the lines it
    // writes, as DMemWrite would before its first byte in each (at most 16
    // bytes: the line of the first and of the last).
    if Writing and FAhead and (Size > 0) then
    begin
      var First := Address and $FFF;
      var Last := (Address + Cardinal(Size) - 1) and $FFF;
      if FLineRun[First shr 6] <> FRun then
        SaveLine(First);
      if FLineRun[Last shr 6] <> FRun then
        SaveLine(Last);
    end;
    var I := 0;
    while I < Size do
    begin
      var Index := E + I;
      if Writing then
      begin
        if not Odd(Index) and (Index < 15) and (I + 1 < Size) then
        begin
          var Lane := FVec[V, Index div 2];
          FBus.WriteSP8((Address + Cardinal(I)) and $FFF, Byte(Lane shr 8));
          FBus.WriteSP8((Address + Cardinal(I + 1)) and $FFF, Byte(Lane and $FF));
          Inc(I, 2);
          Continue;
        end;
        FBus.WriteSP8((Address + Cardinal(I)) and $FFF, GetByte(V, Index));
      end
      else if Index < 16 then
      begin
        if not Odd(Index) and (Index < 15) and (I + 1 < Size) then
        begin
          FVec[V, Index div 2] := (Word(FBus.ReadSP8((Address + Cardinal(I)) and $FFF)) shl 8) or
            FBus.ReadSP8((Address + Cardinal(I + 1)) and $FFF);
          Inc(I, 2);
          Continue;
        end;
        SetByte(V, Index, FBus.ReadSP8((Address + Cardinal(I)) and $FFF));
      end;
      Inc(I);
    end;
  end
  else
    for var I := 0 to Size - 1 do
      if Writing then
        DMemWrite(((Address + Cardinal(I)) and $FFF), GetByte(V, E + I))
      else if E + I < 16 then
        SetByte(V, E + I, DMemRead(((Address + Cardinal(I)) and $FFF)));
end;

procedure TN64RSP.Execute(var PC, Status, Interrupt: Cardinal);
begin
  ExecuteCycles(PC, Status, Interrupt, 32);
end;

procedure TN64RSP.AgePipeline;
begin
  // Saturating decrement of every two-bit counter: 3->2, 2->1, 1->0, 0->0.
  var Lo := FScalarLo;
  FScalarLo := FScalarHi and not Lo;
  FScalarHi := FScalarHi and Lo;
  Lo := FVectorLo;
  FVectorLo := FVectorHi and not Lo;
  FVectorHi := FVectorHi and Lo;
  FLoadHistory := (FLoadHistory shl 1) and 3;
end;

procedure TN64RSP.AgePipelineBy(Clocks: Integer);
begin
  // AgePipeline Clocks (1 or more) times: every counter down by Clocks, to 0
  // at least.
  if Clocks = 1 then
    AgePipeline
  else if Clocks = 2 then
  begin
    // Only a 3 leaves anything (a 1).
    FScalarLo := FScalarHi and FScalarLo;
    FScalarHi := 0;
    FVectorLo := FVectorHi and FVectorLo;
    FVectorHi := 0;
    FLoadHistory := 0;
  end
  else
  begin
    FScalarLo := 0;
    FScalarHi := 0;
    FVectorLo := 0;
    FVectorHi := 0;
    FLoadHistory := 0;
  end;
end;

function TN64RSP.InfoEXECUTE(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 26 of
    $00:
      begin
        Exit(InfoSPECIAL(Op));
      end;
    $01:
      begin
        Exit(InfoREGIMM(Op));
      end;
    $02:
      begin
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $03:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $05:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $06:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $07:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $08:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $09:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0a:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0b:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0c:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0d:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0e:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $0f:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $10:
      begin
        Exit(InfoSCC(Op));
      end;
    $11:
      begin
        Exit;
      end;
    $12:
      begin
        Exit(InfoVU(Op));
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $21:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $22:
      begin
        Exit;
      end;
    $23:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $24:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $25:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $26:
      begin
        Exit;
      end;
    $27:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $28:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $29:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $2a:
      begin
        Exit;
      end;
    $2b:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
    $2d:
      begin
        Exit;
      end;
    $2e:
      begin
        Exit;
      end;
    $2f:
      begin
        Exit;
      end;
    $30:
      begin
        Exit;
      end;
    $31:
      begin
        Exit;
      end;
    $32:
      begin
        Exit(InfoLWC2(Op));
      end;
    $33:
      begin
        Exit;
      end;
    $34:
      begin
        Exit;
      end;
    $35:
      begin
        Exit;
      end;
    $36:
      begin
        Exit;
      end;
    $37:
      begin
        Exit;
      end;
    $38:
      begin
        Exit;
      end;
    $39:
      begin
        Exit;
      end;
    $3a:
      begin
        Exit(InfoSWC2(Op));
      end;
    $3b:
      begin
        Exit;
      end;
    $3c:
      begin
        Exit;
      end;
    $3d:
      begin
        Exit;
      end;
    $3e:
      begin
        Exit;
      end;
    $3f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSPECIAL(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  Result := Default(TRSPTimingInfo);
  case Op and $3f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $03:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $04:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $07:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Exit;
      end;
    $08:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $09:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Result.Flags := Result.Flags or 4;
        Result.Flags := Result.Flags or 128;
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
    $10:
      begin
        Exit;
      end;
    $11:
      begin
        Exit;
      end;
    $12:
      begin
        Exit;
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $21:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $22:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $23:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $24:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $25:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $26:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $27:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $28:
      begin
        Exit;
      end;
    $29:
      begin
        Exit;
      end;
    $2a:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $2b:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
    $2d:
      begin
        Exit;
      end;
    $2e:
      begin
        Exit;
      end;
    $2f:
      begin
        Exit;
      end;
    $30:
      begin
        Exit;
      end;
    $31:
      begin
        Exit;
      end;
    $32:
      begin
        Exit;
      end;
    $33:
      begin
        Exit;
      end;
    $34:
      begin
        Exit;
      end;
    $35:
      begin
        Exit;
      end;
    $36:
      begin
        Exit;
      end;
    $37:
      begin
        Exit;
      end;
    $38:
      begin
        Exit;
      end;
    $39:
      begin
        Exit;
      end;
    $3a:
      begin
        Exit;
      end;
    $3b:
      begin
        Exit;
      end;
    $3c:
      begin
        Exit;
      end;
    $3d:
      begin
        Exit;
      end;
    $3e:
      begin
        Exit;
      end;
    $3f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoREGIMM(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 16 and $1f of
    $00:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $01:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $02:
      begin
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
    $10:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $11:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl 31);
        Result.Flags := Result.Flags or 32;
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 4;
        Exit;
      end;
    $12:
      begin
        Exit;
      end;
    $13:
      begin
        Exit;
      end;
    $14:
      begin
        Exit;
      end;
    $15:
      begin
        Exit;
      end;
    $16:
      begin
        Exit;
      end;
    $17:
      begin
        Exit;
      end;
    $18:
      begin
        Exit;
      end;
    $19:
      begin
        Exit;
      end;
    $1a:
      begin
        Exit;
      end;
    $1b:
      begin
        Exit;
      end;
    $1c:
      begin
        Exit;
      end;
    $1d:
      begin
        Exit;
      end;
    $1e:
      begin
        Exit;
      end;
    $1f:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSCC(Op: Cardinal): TRSPTimingInfo;
begin
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var XT := Integer((Op shr 15) and 31);
  var XD := Integer((Op shr 20) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and $1f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        if ((D and 8) = 0) and ((D and 7) = 4) then
          Result.Flags := Result.Flags or 128;
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
  end;
  case Op and $3f of
    $20:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl XD);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $23:
      begin
        Result.Flags := Result.Flags or 256;
        Exit;
      end;
    $24:
      begin
        Result.Flags := Result.Flags or 256;
        Exit;
      end;
    $25:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $26:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Exit;
      end;
    $27:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $28:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Exit;
      end;
    $29:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XD);
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Result.RWrite := Result.RWrite or (Cardinal(1) shl XT);
        Result.Flags := Result.Flags or 32;
        Exit;
      end;
    $2a:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl XT);
        Exit;
      end;
    $2c:
      begin
        Exit;
      end;
  end;
end;

function TN64RSP.InfoVU(Op: Cardinal): TRSPTimingInfo;
begin
  var T := Integer((Op shr 16) and 31);
  var D := Integer((Op shr 11) and 31);
  var V := Integer((Op shr 6) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 21 and $1f of
    $00:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $01:
      begin
        Exit;
      end;
    $02:
      begin
        Result.RWrite := Result.RWrite or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $03:
      begin
        Exit;
      end;
    $04:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.VWrite := Result.VWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 16;
        Exit;
      end;
    $05:
      begin
        Exit;
      end;
    $06:
      begin
        Result.RRead := Result.RRead or (Cardinal(1) shl T);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl D);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 2;
        Exit;
      end;
    $07:
      begin
        Exit;
      end;
    $08:
      begin
        Exit;
      end;
    $09:
      begin
        Exit;
      end;
    $0a:
      begin
        Exit;
      end;
    $0b:
      begin
        Exit;
      end;
    $0c:
      begin
        Exit;
      end;
    $0d:
      begin
        Exit;
      end;
    $0e:
      begin
        Exit;
      end;
    $0f:
      begin
        Exit;
      end;
  end;
  case Op and $3f of
    $00:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $01:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $02:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $03:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $04:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $05:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $06:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $07:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $08:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $09:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0a:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0c:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0e:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $0f:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $10:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $11:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $12:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $13:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $14:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $15:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $16:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $17:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $18:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $19:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1a:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1b:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1c:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $1f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $20:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $21:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $22:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $23:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $24:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $25:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $26:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 2);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 2);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $27:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 0);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 0);
        Result.VCRead := Result.VCRead or (Cardinal(1) shl 1);
        Result.VCWrite := Result.VCWrite or (Cardinal(1) shl 1);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $28:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $29:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2a:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2c:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2d:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VRead := Result.VRead or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $2f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $30:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $31:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $32:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $33:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $34:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $35:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $36:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl V);
        Result.VFake := Result.VFake or (Cardinal(1) shl D);
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $37:
      begin
        Result.VFake := Result.VFake or (Cardinal(1) shl V);
        Result.Flags := Result.Flags or 8;
        Result.Flags := Result.Flags or 16;
        Exit;
      end;
    $38:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $39:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3a:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3b:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3c:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3d:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3e:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
    $3f:
      begin
        Result.Flags := Result.Flags or 8;
        Exit;
      end;
  end;
end;

function TN64RSP.InfoLWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and $1f of
    $00:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $01:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $02:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $03:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $04:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $05:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $06:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $07:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $08:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $09:
      begin
        Result.VWrite := Result.VWrite or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0b:
      begin
        Result.VWrite := Result.VWrite or (Cardinal($FF) shl (T and not 7));
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 1;
        Result.Flags := Result.Flags or 16;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
  end;
end;

function TN64RSP.InfoSWC2(Op: Cardinal): TRSPTimingInfo;
begin
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  Result := Default(TRSPTimingInfo);
  case Op shr 11 and $1f of
    $00:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $01:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $02:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $03:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $04:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $05:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $06:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $07:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $08:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $09:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0a:
      begin
        Result.VRead := Result.VRead or (Cardinal(1) shl T);
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
    $0b:
      begin
        Result.VRead := Result.VRead or (Cardinal($FF) shl (T and not 7));
        Result.RRead := Result.RRead or (Cardinal(1) shl S);
        Result.Flags := Result.Flags or 2;
        Result.Flags := Result.Flags or 64;
        Exit;
      end;
  end;
end;

function TN64RSP.CanPair(const A, B: TRSPTimingInfo): Boolean;
begin
  Result := (((A.Flags xor B.Flags) and 8) <> 0) and
    ((A.VWrite and (B.VRead or B.VWrite)) = 0) and
    ((A.VCWrite and (B.VCRead or B.VCWrite)) = 0) and
    not ((((A.Flags or not B.Flags) and 16) <> 0) and ((A.VWrite and B.VFake) <> 0));
end;

class procedure TN64RSP.Unsupported(const Kind: string; Op: Cardinal);
begin
  raise EN64Unsupported.CreateFmt('RSP %s %8.8x', [Kind, Op]);
end;

procedure TN64RSP.IssueCOP0(Op, Current: Cardinal);
begin
  // MFC0/MTC0: the SP registers, then the DP registers.
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var IOIndex := (Op shr 11) and 15;
  var IOAddress := $04040000 + IOIndex * 4;
  if IOIndex >= 8 then
    IOAddress := $04100000 + (IOIndex - 8) * 4;
  if S = 0 then
  begin
    if FReadPending then
    begin
      // Run ahead: the predicted (or, replayed, journalled) value.
      FReg[T] := FReadValue;
      FReadPending := False;
    end
    else
      FReg[T] := FBus.Read32(IOAddress);
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.MMIORead, $04001000 + Current, IOAddress, FReg[T]);
  end
  else if (S = 4) and FWritePending then
  begin
    // Run ahead: the console applies it in its own clock (or, replayed,
    // has applied it already).
    FWritePending := False;
  end
  else if S = 4 then
  begin
    var B := FReg[T];
    if FBus.TraceEnabled then
      FBus.Trace(TN64TraceKind.MMIOWrite, $04001000 + Current, IOAddress, B);
    FBus.Write32(IOAddress, B);
  end
  else
    Unsupported('COP0 opcode', Op);
end;

procedure TN64RSP.IssueMoveCOP2(Op: Cardinal);
begin
  // MFC2, CFC2, MTC2, CTC2.
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := Integer((Op shr 11) and 31);
  var E := Integer((Op shr 7) and 15);
  var B := FReg[T];
  case S of
    0:
      FReg[T] := Cardinal(SX((Word(GetByte(D, E)) shl 8) or GetByte(D, E + 1), 16) and $FFFFFFFF);
    2:
      case D and 3 of
        0:
          FReg[T] := Cardinal(SX(FVCO, 16) and $FFFFFFFF);
        1:
          FReg[T] := Cardinal(SX(FVCC, 16) and $FFFFFFFF);
      else
        FReg[T] := FVCE
      end;
    4:
      begin
        SetByte(D, E, Byte((B shr 8) and $FF));
        if E < 15 then
          SetByte(D, E + 1, Byte(B and $FF))
      end;
    6:
      case D and 3 of
        0:
          FVCO := Word(B and $FFFF);
        1:
          FVCC := Word(B and $FFFF);
      else
        FVCE := Word(B and $FF)
      end;
  else
    Unsupported('COP2 opcode', Op);
  end;
end;

procedure TN64RSP.IssueLoadStore(Op, Address: Cardinal);
begin
  // Scalar DMEM loads and stores; Address is already wrapped to DMEM.
  var Code := Op shr 26;
  var T := (Op shr 16) and 31;
  var Size := 1;
  if Code in [33, 37, 41] then
    Size := 2
  else if Code in [35, 39, 43] then
    Size := 4;
  if Code < 40 then
  begin
    var V: Cardinal := 0;
    for var I := 0 to Size - 1 do
      V := (V shl 8) or DMemRead(((Address + Cardinal(I)) and $FFF));
    if Code in [32, 33] then
      V := Cardinal(SX(V, Size * 8) and $FFFFFFFF);
    FReg[T] := V;
  end
  else
  begin
    var B := FReg[T];
    for var I := 0 to Size - 1 do
      DMemWrite(((Address + Cardinal(I)) and $FFF), Byte((B shr ((Size - 1 - I) * 8)) and $FF));
  end;
end;

procedure TN64RSP.IssueInstruction(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  if FBus.TraceEnabled then
    FBus.Trace(TN64TraceKind.Instruction, $04001000 + (PC and $FFC),
      $04001000 + (PC and $FFC), Op);
  var Current := PC;
  if FBranch then
  begin
    PC := FNextPC;
    FBranch := False
  end
  else
    PC := (PC + 4) and $FFC;
  var Code := Op shr 26;
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  var N := (Op shr 6) and 31;
  var A := FReg[S];
  var B := FReg[T];
  var Imm := SX16(Op);
  // Only the low 12 address bits survive, so the immediate's low bits suffice.
  var Address := ((A and $FFF) + (Op and $FFF)) and $FFF;
  var Target := ((Current + 4) + ((Op and $3FF) shl 2)) and $FFC;
  var Taken := False;
  case Code of
    0:
      case Op and 63 of
        0:
          FReg[D] := B shl N;
        2:
          FReg[D] := B shr N;
        3:
          FReg[D] := Cardinal(SAR(B, N, 32) and $FFFFFFFF);
        4:
          FReg[D] := B shl (A and 31);
        6:
          FReg[D] := B shr (A and 31);
        7:
          FReg[D] := Cardinal(SAR(B, A and 31, 32) and $FFFFFFFF);
        8, 9:
          begin
            if (Op and 63) = 9 then
              FReg[D] := (Current + 8) and $FFF;
            FNextPC := A and $FFC;
            FBranch := True
          end;
        13:
          begin
            Status := Status or 3;
            if (Status and $40) <> 0 then
              Interrupt := Interrupt or 1
          end;
        32, 33:
          FReg[D] := Add32(A, B);
        34, 35:
          FReg[D] := Cardinal(Sub64(A, B) and $FFFFFFFF);
        36:
          FReg[D] := A and B;
        37:
          FReg[D] := A or B;
        38:
          FReg[D] := A xor B;
        39:
          FReg[D] := not (A or B);
        42:
          FReg[D] := Ord(SignedLess(SX(A, 32), SX(B, 32)));
        43:
          FReg[D] := Ord(A < B);
      else
        Unsupported('scalar opcode', Op);
      end;
    1, 4..7:
      begin
        case Code of
          1:
            begin
              if not (T in [0, 1, 16, 17]) then
                Unsupported('REGIMM opcode', Op);
              Taken := SignedLess(SX(A, 32), 0);
              if (T and 1) <> 0 then
                Taken := not Taken;
              if (T and 16) <> 0 then
                FReg[31] := (Current + 8) and $FFF
            end;
          4:
            Taken := A = B;
          5:
            Taken := A <> B;
          6:
            Taken := not SignedLess(0, SX(A, 32));
          7:
            Taken := SignedLess(0, SX(A, 32));
        end;
        if Taken then
        begin
          FNextPC := Target;
          FBranch := True
        end;
      end;
    2, 3:
      begin
        if Code = 3 then
          FReg[31] := (Current + 8) and $FFF;
        FNextPC := (Op shl 2) and $FFC;
        FBranch := True
      end;
    8, 9:
      FReg[T] := Cardinal(Add64(A, Imm) and $FFFFFFFF);
    10:
      FReg[T] := Ord(SignedLess(SX(A, 32), Imm));
    11:
      FReg[T] := Ord(UInt64(A) < (Imm and $FFFFFFFF));
    12:
      FReg[T] := A and (Op and $FFFF);
    13:
      FReg[T] := A or (Op and $FFFF);
    14:
      FReg[T] := A xor (Op and $FFFF);
    15:
      FReg[T] := (Op and $FFFF) shl 16;
    16:
      IssueCOP0(Op, Current);
    18:
      if S >= 16 then
        VectorOp(Op)
      else
        IssueMoveCOP2(Op);
    32, 33, 35..37, 39, 40, 41, 43:
      IssueLoadStore(Op, Address);
    50:
      VectorMemory(Op, False);
    58:
      VectorMemory(Op, True);
  else
    Unsupported('opcode', Op);
  end;
  FReg[0] := 0;
end;

procedure TN64RSP.Issue(Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  // Vector instructions straight to their unit (nothing of the scalar
  // decode in IssueInstruction concerns them); traced, all go through it.
  if not FBus.TraceEnabled then
    case Op shr 26 of
      18, 50, 58:
        if ((Op shr 26) <> 18) or (((Op shr 21) and 31) >= 16) then
        begin
          if FBranch then
          begin
            PC := FNextPC;
            FBranch := False
          end
          else
            PC := (PC + 4) and $FFC;
          if (Op shr 26) = 18 then
            VectorOp(Op)
          else
            VectorMemory(Op, (Op shr 26) = 58);
          Exit;
        end;
    end;
  IssueInstruction(Op, PC, Status, Interrupt);
end;

function TN64RSP.RunClocks(var PC, Status, Interrupt: Cardinal; Cycles: Integer; Ahead: Boolean; Least: Integer): Integer;
begin
  // Ahead: stop before the first clock that is not free (see RunAhead); the
  // checkpoint is taken before the first clock that changes anything. Least
  // (1..Cycles): the clocks may end anywhere from Least on (blocks run to
  // their end there).
  var Stop := Cycles;
  if (Least > 0) and (Least < Cycles) then
    Stop := Least;
  Result := 0;
  while Result < Stop do
  begin
    if (Status and 1) <> 0 then
      Break;
    if FBranchBubble > 0 then
    begin
      if Ahead and not FCheckpointed then
        SaveCheckpoint(PC);
      Dec(FBranchBubble);
      AgePipeline;
      Inc(Result);
      // Nothing else happens in a bubble (Status stays): the next clock now.
      if Result >= Stop then
        Break;
    end;
    // A stalled opcode only counts at its own PC. Both outcomes below set
    // FHasStalledOpcode/FHasStalledSecondOpcode, so a stale one is dropped.
    var Stalled := FHasStalledOpcode and (FStalledPC = PC);
    if FUseBlocks and not Stalled and not FBranch and ((Status and $20) = 0) and (FCheckpointed or not Ahead) and
      FBus.DirectMemory and not FBus.TraceEnabled then
    begin
      // The clocks from here worked out before: run them as they are, and
      // the blocks after them.
      var Block := FindBlock(PC);
      if Block.Count > 0 then
      begin
        var Outcome := RunBlock(Block, PC, Status, Interrupt, Cycles, Stop, Ahead, Result);
        if Outcome = 2 then
          Break;
        if Outcome = 0 then
          Continue;
        // A stall longer than the budget left, or a clock no block takes:
        // the clock below (no stall is held after a block's clocks, no
        // bubble is pending).
      end;
    end;
    var Op, Second: Cardinal;
    var Pair: Boolean;
    // The clock's masks, where they are kept (Held: decoded here).
    var Masks: ^TRSPIssueMasks;
    var Held: TRSPIssueMasks;
    var FirstSlot := Integer((PC shr 2) and 1023);
    var SecondSlot := Integer(((PC shr 2) + 1) and 1023);
    if Stalled and FStallKnown and (FStallOp = FStalledOpcode) and (FStallSecond = FStalledSecondOpcode) and
      (FStallPair = FHasStalledSecondOpcode) then
    begin
      // The stall goes on: the same held words.
      Op := FStalledOpcode;
      Second := FStalledSecondOpcode;
      Pair := FHasStalledSecondOpcode;
      Masks := @FStallMasks;
    end
    else if Stalled then
    begin
      Op := FStalledOpcode;
      Second := FStalledSecondOpcode;
      Pair := FHasStalledSecondOpcode;
      DecodedSlot(FirstSlot);
      if Pair then
        DecodedSlot(SecondSlot);
      if (FDec[FirstSlot].Op = Op) and (not Pair or (FDec[SecondSlot].Op = Second)) then
      begin
        if not Pair then
          Masks := @FDec[FirstSlot].Single
        else
        begin
          if not FDec[FirstSlot].PairValid or (FDec[FirstSlot].SecondOp <> Second) then
            DecodePair(FirstSlot);
          Masks := @FDec[FirstSlot].Paired;
        end;
      end
      else
      begin
        // IMEM changed under the held words: decode them as held.
        if Pair then
          Combine(InfoEXECUTE(Op), InfoEXECUTE(Second), external(Op), external(Second), Held)
        else
          MasksOf(InfoEXECUTE(Op), external(Op), Held);
        Masks := @Held;
      end;
    end
    else
    begin
      DecodedSlot(FirstSlot);
      Op := FDec[FirstSlot].Op;
      Second := 0;
      Pair := False;
      if (FSingleIssue = 0) and ((Status and $20) = 0) and ((FDec[FirstSlot].Info.Flags and 4) = 0) then
      begin
        DecodedSlot(SecondSlot);
        if not FDec[FirstSlot].PairValid or (FDec[FirstSlot].SecondOp <> FDec[SecondSlot].Op) then
          DecodePair(FirstSlot);
        Pair := FDec[FirstSlot].CanPair;
        // Kept even without a pair: a stall holds it (FStalledSecondOpcode).
        Second := FDec[SecondSlot].Op;
      end;
      if Pair then
        Masks := @FDec[FirstSlot].Paired
      else
        Masks := @FDec[FirstSlot].Single;
    end;
    var Flags := Masks.Flags;
    var ScalarWrites := Masks.ScalarWrites;
    var VectorWrites := Masks.VectorWrites;
    var Loading := (Flags and 1) <> 0;
    var Storing := (Flags and 2) <> 0;
    if (Storing and ((FLoadHistory and 2) <> 0)) or
      ((Masks.Sources and (FScalarLo or FScalarHi)) <> 0) or ((Masks.Vectors and (FVectorLo or FVectorHi)) <> 0) then
    begin
      // The words wait until every register they read is ready (and a store
      // until the load before it is done), all those clocks at once: they
      // only age the pipeline, and are free ahead.
      if Ahead and not FCheckpointed then
        SaveCheckpoint(PC);
      FStalledOpcode := Op;
      FStalledPC := PC;
      FHasStalledOpcode := True;
      FStalledSecondOpcode := Second;
      FHasStalledSecondOpcode := Pair;
      var Sources := Masks.Sources;
      var Vectors := Masks.Vectors;
      // The longest wait: a counter is Lo + 2 * Hi.
      var Wait := 0;
      if (Sources and FScalarHi) <> 0 then
        Wait := 2 + Ord((Sources and FScalarHi and FScalarLo) <> 0)
      else if (Sources and FScalarLo) <> 0 then
        Wait := 1;
      if (Vectors and FVectorHi) <> 0 then
        Wait := Max(Wait, 2 + Ord((Vectors and FVectorHi and FVectorLo) <> 0))
      else if ((Vectors and FVectorLo) <> 0) and (Wait = 0) then
        Wait := 1;
      // A store also waits while a load two clocks back is in the history:
      // now (bit 1), or one clock on (bit 0), when its registers no longer
      // keep it waiting by then.
      if Wait = 0 then
        Wait := 1;
      if (Wait = 1) and Storing and ((FLoadHistory and 1) <> 0) then
        Wait := 2;
      if Wait >= Cycles - Result then
      begin
        // The stall goes on past this call, or ends with it: the next one
        // starts with the held words, so keep their masks.
        Wait := Cycles - Result;
        FStallMasks := Masks^;
        FStallOp := Op;
        FStallSecond := Second;
        FStallPair := Pair;
        FStallKnown := True;
        AgePipelineBy(Wait);
        Inc(Result, Wait);
        Break;
      end;
      AgePipelineBy(Wait);
      Inc(Result, Wait);
    end;
    if Ahead then
    begin
      // A replay re-runs clocks that already ran, with the fences set later.
      if FFenced and not FReplaying and (TouchesFence(Op) or (Pair and TouchesFence(Second))) and
        not LiftFence(PC, Op, Second, Pair, FClockBase + Result + 1) then
      begin
        FAheadStop := TRSPAheadStop.Fence;
        Break;
      end;
      if Masks.external and not JournalCOP0(Op, Second, Pair, FClockBase + Result + 1) then
      begin
        StopAtExternal(Op, Second);
        Break;
      end;
      if not FCheckpointed then
        SaveCheckpoint(PC);
    end;
    FHasStalledOpcode := False;
    FHasStalledSecondOpcode := False;
    var DelaySlot := FBranch;
    Issue(Op, PC, Status, Interrupt);
    if Pair and ((Status and 1) = 0) then
      Issue(Second, PC, Status, Interrupt);
    AgePipeline;
    // Scalar results become ready after two clocks, vector results after three.
    ScalarWrites := ScalarWrites and not Cardinal(1);
    FScalarHi := FScalarHi or ScalarWrites;
    FScalarLo := FScalarLo and not ScalarWrites;
    FVectorHi := FVectorHi or VectorWrites;
    FVectorLo := FVectorLo or VectorWrites;
    if Loading then
      FLoadHistory := FLoadHistory or 1;
    FSingleIssue := Byte(Ord((Flags and 4) <> 0));
    if DelaySlot then
    begin
      FBranchBubble := 1;
      if (PC and 4) <> 0 then
        FSingleIssue := 1;
    end;
    Inc(Result);
    if (Status and $20) <> 0 then
      Status := Status or 1;
  end;
end;

function TN64RSP.ExecuteCycles(var PC, Status, Interrupt: Cardinal; Cycles: Integer): Integer;
begin
  Result := RunClocks(PC, Status, Interrupt, Cycles, False);
end;

const
  // TRSPBlockStep.Checks.
  StepMemory = 2;
  // The kinds of branches and jumps (StepKind).
  FirstBranchKind = 55;
  LastBranchKind = 63;
  StepExternal = 4;
  StepGeneral = 8;

procedure TN64RSP.ClearBlocks;
begin
  for var I := 0 to High(FBlockHead) do
    FBlockHead[I] := -1;
  FBlockCount := 0;
  FStepCount := 0;
  FWordCount := 0;
  FillChar(FJumps, SizeOf(FJumps), 0);
  Inc(FBlockGen);
  // Their code goes with them.
  if FJit <> nil then
    FJit.Reset;
  FJitEnter := 0;
  FJitFull := False;
end;

function TN64RSP.BlockValid(B: PRSPBlock; Slot: Integer): Boolean;
begin
  // Whether block B (from Slot) holds for IMEM as it is: one whose IMEM
  // eighths changed after it was checked holds if its words are the same
  // again (code that comes back, or a word of the eighth not its own).
  var Checked := B.Checked;
  if (FBus.IMemRegionStamp(B.Regions[0]) <= Checked) and (FBus.IMemRegionStamp(B.Regions[1]) <= Checked) then
    Exit(True);
  Result := CheckBlock(B, Slot);
end;

function TN64RSP.CheckBlock(B: PRSPBlock; Slot: Integer): Boolean;
begin
  for var I := 0 to B.Words - 1 do
    if FBus.IMemWord((Slot + I) and 1023) <> FBlockWords[B.FirstWord + I] then
      Exit(False);
  B.Checked := FBus.IMemCounter;
  Result := True;
end;

function JumpKey(B: PRSPBlock; Taken: Integer; PC: Cardinal): Cardinal; inline;
begin
  Result := ((Cardinal(B.Index) shl 13) or (Cardinal(Taken) shl 12) or PC) + 1;
end;

function JumpSlot(B: PRSPBlock; Taken: Integer; PC: Cardinal): Integer; inline;
begin
  Result := Integer(((PC shr 2) xor Cardinal(B.Index) xor (Cardinal(Taken) shl 9)) and 1023);
end;

function TN64RSP.NextBlock(B: PRSPBlock; Taken: Integer; PC: Cardinal): PRSPBlock;
begin
  // The block after B ran to its end (its branch Taken or not), at PC with
  // the pipeline as it is: the one that came there before (B.Link, FJumps),
  // else found (FindBlock), and kept as B's link.
  var Slot := Integer((PC shr 2) and 1023);
  Result := B.Link[Taken];
  if (Result <> nil) and (B.LinkPC[Taken] = PC) and BlockValid(Result, Slot) then
    Exit;
  var J := JumpSlot(B, Taken, PC);
  var Key := JumpKey(B, Taken, PC);
  if FJumps[J].Key = Key then
  begin
    Result := FJumps[J].Block;
    if BlockValid(Result, Slot) then
    begin
      B.Link[Taken] := Result;
      B.LinkPC[Taken] := PC;
      Exit;
    end;
  end;
  var Gen := FBlockGen;
  Result := FindBlock(PC);
  // (Not if B went with the blocks dropped for room.)
  if FBlockGen = Gen then
  begin
    B.Link[Taken] := Result;
    B.LinkPC[Taken] := PC;
    FJumps[J].Key := Key;
    FJumps[J].Block := Result;
  end;
end;

function TN64RSP.FindBlock(PC: Cardinal): PRSPBlock;
begin
  // The block from PC's slot and the pipeline as it is, worked out if new.
  var Slot := Integer((PC shr 2) and 1023);
  var Index := FBlockHead[Slot];
  while Index >= 0 do
  begin
    Result := @FBlocks[Index];
    if (Result.ScalarLo = FScalarLo) and (Result.ScalarHi = FScalarHi) and (Result.VectorLo = FVectorLo) and
      (Result.VectorHi = FVectorHi) and (Result.LoadHistory = FLoadHistory) and (Result.SingleIssue = FSingleIssue) and
      BlockValid(Result, Slot) then
      Exit;
    Index := Result.Next;
  end;
  Result := BuildBlock(PC);
end;

function TN64RSP.BuildBlock(PC: Cardinal): PRSPBlock;
const
  // At most this many steps in a block (the pools keep room for one).
  MaxSteps = 64;
begin
  // The clocks RunClocks takes from PC and the pipeline as it is, without
  // issuing anything: the same decode, pairing, stalls and readiness.
  if FBlocks = nil then
  begin
    SetLength(FBlocks, 2048);
    SetLength(FBlockSteps, 32768);
    SetLength(FBlockWords, 65536);
  end;
  if (FBlockCount >= Length(FBlocks)) or (FStepCount + MaxSteps > Length(FBlockSteps)) or
    (FWordCount + 2 * MaxSteps + 1 > Length(FBlockWords)) then
    ClearBlocks;
  Inc(FBlocksBuilt);
  var Start := Integer((PC shr 2) and 1023);
  Result := @FBlocks[FBlockCount];
  Result.ScalarLo := FScalarLo;
  Result.ScalarHi := FScalarHi;
  Result.VectorLo := FVectorLo;
  Result.VectorHi := FVectorHi;
  Result.LoadHistory := FLoadHistory;
  Result.SingleIssue := FSingleIssue;
  Result.First := FStepCount;
  Result.FirstWord := FWordCount;
  Result.Checked := FBus.IMemCounter;
  Result.Link[0] := nil;
  Result.Link[1] := nil;
  Result.Native := nil;
  Result.JitTried := False;
  Result.JitHeat := 0;
  Result.Next := FBlockHead[Start];
  Result.Index := FBlockCount;
  FBlockHead[Start] := FBlockCount;
  Inc(FBlockCount);
  var SLo := FScalarLo;
  var SHi := FScalarHi;
  var VLo := FVectorLo;
  var VHi := FVectorHi;
  var LoadHistory := FLoadHistory;
  var SingleIssue := FSingleIssue;
  var Count := 0;
  // Words looked at from Start on.
  var Words := 0;
  var Branched := False;
  var Clocks := 0;
  while Count < MaxSteps do
  begin
    var Slot := Integer((PC shr 2) and 1023);
    var NextSlot := (Slot + 1) and 1023;
    DecodedSlot(Slot);
    Words := Max(Words, ((Slot - Start) and 1023) + 1);
    var Op := FDec[Slot].Op;
    var Second: Cardinal := 0;
    var Pair := False;
    var Masks: ^TRSPIssueMasks := @FDec[Slot].Single;
    if (SingleIssue = 0) and ((FDec[Slot].Info.Flags and 4) = 0) then
    begin
      DecodedSlot(NextSlot);
      Words := Max(Words, ((NextSlot - Start) and 1023) + 1);
      if not FDec[Slot].PairValid or (FDec[Slot].SecondOp <> FDec[NextSlot].Op) then
        DecodePair(Slot);
      Pair := FDec[Slot].CanPair;
      Second := FDec[NextSlot].Op;
      if Pair then
        Masks := @FDec[Slot].Paired;
    end;
    // Of the external instructions only a clock's one MFC0 or MTC0 (its
    // journal entry made as it runs); the others are RunClocks' business.
    if Masks.external and not JournalStep(Op, Second, Pair) then
      Break;
    var Flags := Masks.Flags;
    var Storing := (Flags and 2) <> 0;
    var Wait := 0;
    if (Storing and ((LoadHistory and 2) <> 0)) or ((Masks.Sources and (SLo or SHi)) <> 0) or
      ((Masks.Vectors and (VLo or VHi)) <> 0) then
    begin
      // As RunClocks (a scalar counter never reaches 3, a vector one does).
      var Sources := Masks.Sources;
      var Vectors := Masks.Vectors;
      if (Sources and SHi) <> 0 then
        Wait := 2 + Ord((Sources and SHi and SLo) <> 0)
      else if (Sources and SLo) <> 0 then
        Wait := 1;
      if (Vectors and VHi) <> 0 then
        Wait := Max(Wait, 2 + Ord((Vectors and VHi and VLo) <> 0))
      else if ((Vectors and VLo) <> 0) and (Wait = 0) then
        Wait := 1;
      if Wait = 0 then
        Wait := 1;
      if (Wait = 1) and Storing and ((LoadHistory and 1) <> 0) then
        Wait := 2;
      if Wait = 1 then
      begin
        var Lo := SLo;
        SLo := SHi and not Lo;
        SHi := SHi and Lo;
        Lo := VLo;
        VLo := VHi and not Lo;
        VHi := VHi and Lo;
        LoadHistory := (LoadHistory shl 1) and 3;
      end
      else if Wait = 2 then
      begin
        // As AgePipelineBy (what a 3 leaves, a 1, is gone after the issue
        // clock ages it again).
        SLo := SHi and SLo;
        SHi := 0;
        VLo := VHi and VLo;
        VHi := 0;
        LoadHistory := 0;
      end
      else
      begin
        SLo := 0;
        SHi := 0;
        VLo := 0;
        VHi := 0;
        LoadHistory := 0;
      end;
    end;
    var S: PRSPBlockStep := @FBlockSteps[FStepCount + Count];
    S.Op := Op;
    S.Second := Second;
    S.Pair := Pair;
    S.Wait := Wait;
    S.Kind := StepKind(Op);
    S.SecondKind := StepKind(Second);
    S.Issue := nil;
    if S.Kind <> 0 then
      S.Issue := FKindIssue[S.Kind];
    S.SecondIssue := nil;
    if S.SecondKind <> 0 then
      S.SecondIssue := FKindIssue[S.SecondKind];
    S.Arg := StepArg(S.Kind, Op, PC);
    S.SecondArg := StepArg(S.SecondKind, Second, (PC + 4) and $FFC);
    S.PC := Word(PC);
    Clocks := Clocks + Wait + 1;
    S.Clocks := Clocks;
    S.Checks := 0;
    if LoadStore(Op) or (Pair and LoadStore(Second)) then
      S.Checks := S.Checks or StepMemory;
    if Masks.external then
      S.Checks := S.Checks or StepExternal;
    // (IssueInstruction's kinds, and a branch or jump in a delay slot, take
    // the PC as each instruction moves it. An MFC0 or MTC0, the clock's
    // external instruction, is IssueInstruction's: the clock that may halt
    // the RSP is a general one.)
    S.Delay := False;
    if (S.Kind = 0) or (Pair and (S.SecondKind = 0)) or
      (Branched and ((S.Kind in [FirstBranchKind..LastBranchKind]) or
      (Pair and (S.SecondKind in [FirstBranchKind..LastBranchKind])))) then
      S.Checks := S.Checks or StepGeneral
    else
      S.Delay := Branched;

    // The issue clock.
    var Lo := SLo;
    SLo := SHi and not Lo;
    SHi := SHi and Lo;
    Lo := VLo;
    VLo := VHi and not Lo;
    VHi := VHi and Lo;
    LoadHistory := (LoadHistory shl 1) and 3;
    var ScalarWrites := Masks.ScalarWrites and not Cardinal(1);
    SHi := SHi or ScalarWrites;
    SLo := SLo and not ScalarWrites;
    VHi := VHi or Masks.VectorWrites;
    VLo := VLo or Masks.VectorWrites;
    if (Flags and 1) <> 0 then
      LoadHistory := LoadHistory or 1;
    SingleIssue := Byte(Ord((Flags and 4) <> 0));
    S.ScalarLo := SLo;
    S.ScalarHi := SHi;
    S.VectorLo := VLo;
    S.VectorHi := VHi;
    S.LoadHistory := LoadHistory;
    S.SingleIssue := SingleIssue;
    Inc(Count);
    // A branch's delay slot is the last clock: where the branch goes is
    // only known as it runs.
    if Branched then
      Break;
    Branched := (Flags and 4) <> 0;
    PC := (PC + 4 + 4 * Cardinal(Ord(Pair))) and $FFC;
  end;

  for var I := 0 to Words - 1 do
    FBlockWords[FWordCount + I] := FDec[(Start + I) and 1023].Op;
  Result.Words := Words;
  // (At most 2 * MaxSteps + 1 words: in two eighths at most.)
  Result.Regions[0] := Byte(Start shr 7);
  Result.Regions[1] := Byte(((Start + Words - 1) and 1023) shr 7);
  Inc(FWordCount, Words);
  Result.Count := Count;
  Result.Clocks := Clocks;
  Inc(FStepCount, Count);
end;

class function TN64RSP.StepArg(Kind: Byte; Op, PC: Cardinal): Cardinal;
begin
  // What the routine of Op's kind (StepKind) is given, Op at PC: the
  // target of a branch in its low 12 bits (in place of its offset), that of
  // a J or JAL, with what JAL links in bits 16..27; Op otherwise.
  Result := Op;
  case Kind of
    55..60:
      Result := (Op and $FFFF0000) or (((PC + 4) + ((Op and $3FF) shl 2)) and $FFC);
    61:
      Result := (Op shl 2) and $FFC;
    62:
      Result := ((Op shl 2) and $FFC) or (((PC + 8) and $FFF) shl 16);
  end;
end;

class function TN64RSP.StepKind(Op: Cardinal): Byte;
begin
  // How a block issues Op (IssueKind): the frequent vector instructions by
  // their own routines (kinds 4..19, 48..51; the multiplies with one VT lane
  // for all 64..71), other vector ones through
  // VectorOp (3), vector loads and
  // stores through VectorMemory, the frequent scalar ones by their own
  // routines (20..47), the moves to and from COP2 (54), the branches and
  // jumps but those that link a register of their own or r31 on a branch
  // (FirstBranchKind on), the rest through IssueInstruction (0).
  Result := 0;
  case Op shr 26 of
    0:
      case Op and 63 of
        8:
          Result := 63;
        0:
          Result := 25;
        2:
          Result := 26;
        3:
          Result := 27;
        32, 33:
          Result := 28;
        34, 35:
          Result := 29;
        36:
          Result := 30;
        37:
          Result := 31;
        38:
          Result := 32;
        39:
          Result := 33;
        42:
          Result := 34;
        43:
          Result := 35;
      end;
    1:
      case (Op shr 16) and 31 of
        0:
          Result := 59;
        1:
          Result := 60;
      end;
    2:
      Result := 61;
    3:
      Result := 62;
    4:
      Result := 55;
    5:
      Result := 56;
    6:
      Result := 57;
    7:
      Result := 58;
    8, 9:
      Result := 20;
    10:
      Result := 36;
    11:
      Result := 37;
    12:
      Result := 21;
    13:
      Result := 22;
    14:
      Result := 23;
    15:
      Result := 24;
    32:
      Result := 40;
    33:
      Result := 41;
    35:
      Result := 42;
    36:
      Result := 43;
    37:
      Result := 44;
    40:
      Result := 45;
    41:
      Result := 46;
    43:
      Result := 47;
    18:
      if ((Op shr 21) and 31) in [0, 2, 4, 6] then
        Result := 54
      else if ((Op shr 21) and 31) >= 16 then
        case Op and 63 of
          0, 1, 8, 9:
            Result := 14;
          4..7:
            if ((Op shr 21) and 15) >= 8 then
              Result := 64 + (Op and 3)
            else
              Result := 4 + (Op and 3);
          12..15:
            if ((Op shr 21) and 15) >= 8 then
              Result := 68 + (Op and 3)
            else
              Result := 8 + (Op and 3);
          16:
            Result := 12;
          17:
            Result := 13;
          20, 21:
            Result := 51;
          32:
            Result := 15;
          33:
            Result := 16;
          34:
            Result := 17;
          35:
            Result := 18;
          36:
            Result := 19;
          37:
            Result := 48;
          39:
            Result := 49;
          40..45:
            Result := 50;
        else
          Result := 3;
        end;
    // Vector loads and stores: those VectorMemory leaves to
    // VectorMemoryDirect (blocks run with direct SP memory) straight there.
        50:
      if ((Op shr 11) and 31) <= 4 then
        Result := 52
      else
        Result := 1;
    58:
      if ((Op shr 11) and 31) <= 4 then
        Result := 53
      else
        Result := 2;
  end;
end;

procedure InitDivideTables;
begin
  for var Index := 0 to 511 do
    ReciprocalTable[Index] := Word(Min(UInt64($FFFF), ((((UInt64(1) shl 34) div UInt64(Index + 512)) + 1) shr 8) -
          $10000));
  for var Key := 0 to 511 do
  begin
    // 1/sqrt by the largest square that fits.
    var Denominator := UInt64(512 + (Key and 510));
    if (Key and 1) = 0 then
      Denominator := Denominator * 2;
    var LowBound: UInt64 := 65536;
    var HighBound: UInt64 := 131071;
    while LowBound < HighBound do
    begin
      var Mid := (LowBound + HighBound + 1) div 2;
      if Mid * Mid * Denominator <= (UInt64(1) shl 43) then
        LowBound := Mid
      else
        HighBound := Mid - 1;
    end;
    SquareRootTable[Key] := Word(LowBound - 65536);
  end;
end;

procedure InitKindIssue;
begin
  for var K := 0 to 255 do
    TN64RSP.FKindIssue[K] := @TN64RSP.IssueUnexpected;
  TN64RSP.FKindIssue[1] := @TN64RSP.VectorLoad;
  TN64RSP.FKindIssue[2] := @TN64RSP.VectorStore;
  TN64RSP.FKindIssue[3] := @TN64RSP.VectorOp;
  TN64RSP.FKindIssue[4] := @TN64RSP.VectorMUDL;
  TN64RSP.FKindIssue[5] := @TN64RSP.VectorMUDM;
  TN64RSP.FKindIssue[6] := @TN64RSP.VectorMUDN;
  TN64RSP.FKindIssue[7] := @TN64RSP.VectorMUDH;
  TN64RSP.FKindIssue[8] := @TN64RSP.VectorMADL;
  TN64RSP.FKindIssue[9] := @TN64RSP.VectorMADM;
  TN64RSP.FKindIssue[10] := @TN64RSP.VectorMADN;
  TN64RSP.FKindIssue[11] := @TN64RSP.VectorMADH;
  TN64RSP.FKindIssue[12] := @TN64RSP.VectorAdd;
  TN64RSP.FKindIssue[13] := @TN64RSP.VectorSub;
  TN64RSP.FKindIssue[14] := @TN64RSP.VectorMulFrac;
  TN64RSP.FKindIssue[15] := @TN64RSP.VectorLT;
  TN64RSP.FKindIssue[16] := @TN64RSP.VectorEQ;
  TN64RSP.FKindIssue[17] := @TN64RSP.VectorNE;
  TN64RSP.FKindIssue[18] := @TN64RSP.VectorGE;
  TN64RSP.FKindIssue[19] := @TN64RSP.VectorClipLow;
  TN64RSP.FKindIssue[20] := @TN64RSP.IssueADDI;
  TN64RSP.FKindIssue[21] := @TN64RSP.IssueANDI;
  TN64RSP.FKindIssue[22] := @TN64RSP.IssueORI;
  TN64RSP.FKindIssue[23] := @TN64RSP.IssueXORI;
  TN64RSP.FKindIssue[24] := @TN64RSP.IssueLUI;
  TN64RSP.FKindIssue[25] := @TN64RSP.IssueSLL;
  TN64RSP.FKindIssue[26] := @TN64RSP.IssueSRL;
  TN64RSP.FKindIssue[27] := @TN64RSP.IssueSRA;
  TN64RSP.FKindIssue[28] := @TN64RSP.IssueADD;
  TN64RSP.FKindIssue[29] := @TN64RSP.IssueSUB;
  TN64RSP.FKindIssue[30] := @TN64RSP.IssueAND;
  TN64RSP.FKindIssue[31] := @TN64RSP.IssueOR;
  TN64RSP.FKindIssue[32] := @TN64RSP.IssueXOR;
  TN64RSP.FKindIssue[33] := @TN64RSP.IssueNOR;
  TN64RSP.FKindIssue[34] := @TN64RSP.IssueSLT;
  TN64RSP.FKindIssue[35] := @TN64RSP.IssueSLTU;
  TN64RSP.FKindIssue[36] := @TN64RSP.IssueSLTI;
  TN64RSP.FKindIssue[37] := @TN64RSP.IssueSLTIU;
  TN64RSP.FKindIssue[40] := @TN64RSP.IssueLB;
  TN64RSP.FKindIssue[41] := @TN64RSP.IssueLH;
  TN64RSP.FKindIssue[42] := @TN64RSP.IssueLW;
  TN64RSP.FKindIssue[43] := @TN64RSP.IssueLBU;
  TN64RSP.FKindIssue[44] := @TN64RSP.IssueLHU;
  TN64RSP.FKindIssue[45] := @TN64RSP.IssueSB;
  TN64RSP.FKindIssue[46] := @TN64RSP.IssueSH;
  TN64RSP.FKindIssue[47] := @TN64RSP.IssueSW;
  TN64RSP.FKindIssue[48] := @TN64RSP.VectorCH;
  TN64RSP.FKindIssue[49] := @TN64RSP.VectorMerge;
  TN64RSP.FKindIssue[50] := @TN64RSP.VectorLogic;
  TN64RSP.FKindIssue[51] := @TN64RSP.VectorCarry;
  TN64RSP.FKindIssue[52] := @TN64RSP.VectorLoadDirect;
  TN64RSP.FKindIssue[53] := @TN64RSP.VectorStoreDirect;
  TN64RSP.FKindIssue[54] := @TN64RSP.IssueCOP2Move;
  TN64RSP.FKindIssue[55] := @TN64RSP.IssueBEQ;
  TN64RSP.FKindIssue[56] := @TN64RSP.IssueBNE;
  TN64RSP.FKindIssue[57] := @TN64RSP.IssueBLEZ;
  TN64RSP.FKindIssue[58] := @TN64RSP.IssueBGTZ;
  TN64RSP.FKindIssue[59] := @TN64RSP.IssueBLTZ;
  TN64RSP.FKindIssue[60] := @TN64RSP.IssueBGEZ;
  TN64RSP.FKindIssue[61] := @TN64RSP.IssueJ;
  TN64RSP.FKindIssue[62] := @TN64RSP.IssueJAL;
  TN64RSP.FKindIssue[63] := @TN64RSP.IssueJR;
  TN64RSP.FKindIssue[64] := @TN64RSP.VectorMUDLOne;
  TN64RSP.FKindIssue[65] := @TN64RSP.VectorMUDMOne;
  TN64RSP.FKindIssue[66] := @TN64RSP.VectorMUDNOne;
  TN64RSP.FKindIssue[67] := @TN64RSP.VectorMUDHOne;
  TN64RSP.FKindIssue[68] := @TN64RSP.VectorMADLOne;
  TN64RSP.FKindIssue[69] := @TN64RSP.VectorMADMOne;
  TN64RSP.FKindIssue[70] := @TN64RSP.VectorMADNOne;
  TN64RSP.FKindIssue[71] := @TN64RSP.VectorMADHOne;
end;

procedure TN64RSP.IssueStep(Kind: Byte; Op: Cardinal);
begin
  // Op of kind Kind (not 0) by its routine, the PC left alone.
  TRSPIssueProc(FKindIssue[Kind])(Self, Op);
end;

procedure TN64RSP.IssueKind(Kind: Byte; Op: Cardinal; var PC, Status, Interrupt: Cardinal);
begin
  // Issue (untraced) for Op of kind Kind (StepKind), the PC as it takes it.
  if Kind = 0 then
    IssueInstruction(Op, PC, Status, Interrupt)
  else
  begin
    if FBranch then
    begin
      PC := FNextPC;
      FBranch := False
    end
    else
      PC := (PC + 4) and $FFC;
    IssueStep(Kind, Op);
  end;
end;

procedure TN64RSP.IssueUnexpected(Op: Cardinal);
begin
  raise EInvalidOpException.CreateFmt('RSP block step of no kind: %8.8x', [Op]);
end;

procedure TN64RSP.IssueCOP2Move(Op: Cardinal);
begin
  IssueMoveCOP2(Op);
  FReg[0] := 0;
end;

// Branches and jumps as IssueInstruction takes them: a taken one goes to
// its target after the delay slot (FNextPC), a branch not taken leaves
// nothing behind.

procedure TN64RSP.IssueBEQ(Arg: Cardinal);
begin
  if FReg[(Arg shr 21) and 31] = FReg[(Arg shr 16) and 31] then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueBNE(Arg: Cardinal);
begin
  if FReg[(Arg shr 21) and 31] <> FReg[(Arg shr 16) and 31] then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueBLEZ(Arg: Cardinal);
begin
  if Integer(FReg[(Arg shr 21) and 31]) <= 0 then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueBGTZ(Arg: Cardinal);
begin
  if Integer(FReg[(Arg shr 21) and 31]) > 0 then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueBLTZ(Arg: Cardinal);
begin
  if Integer(FReg[(Arg shr 21) and 31]) < 0 then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueBGEZ(Arg: Cardinal);
begin
  if Integer(FReg[(Arg shr 21) and 31]) >= 0 then
  begin
    FNextPC := Arg and $FFC;
    FBranch := True;
  end;
end;

procedure TN64RSP.IssueJ(Arg: Cardinal);
begin
  FNextPC := Arg;
  FBranch := True;
end;

procedure TN64RSP.IssueJAL(Arg: Cardinal);
begin
  FReg[31] := Arg shr 16;
  FNextPC := Arg and $FFC;
  FBranch := True;
end;

procedure TN64RSP.IssueJR(Arg: Cardinal);
begin
  FNextPC := FReg[(Arg shr 21) and 31] and $FFC;
  FBranch := True;
end;

// The frequent scalar instructions (StepKind 20..47), as IssueInstruction
// does them; arithmetic wraps without overflow checks.

procedure TN64RSP.IssueADDI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := Cardinal((UInt64(FReg[(Op shr 21) and 31]) + Cardinal(Integer(SmallInt(Op and $FFFF)))) and $FFFFFFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueANDI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := FReg[(Op shr 21) and 31] and (Op and $FFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueORI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := FReg[(Op shr 21) and 31] or (Op and $FFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueXORI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := FReg[(Op shr 21) and 31] xor (Op and $FFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueLUI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := (Op and $FFFF) shl 16;
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSLL(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := FReg[(Op shr 16) and 31] shl ((Op shr 6) and 31);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSRL(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := FReg[(Op shr 16) and 31] shr ((Op shr 6) and 31);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSRA(Op: Cardinal);
begin
  var B := FReg[(Op shr 16) and 31];
  var N := (Op shr 6) and 31;
  if (B and $80000000) <> 0 then
    B := (B shr N) or not (Cardinal($FFFFFFFF) shr N)
  else
    B := B shr N;
  FReg[(Op shr 11) and 31] := B;
  FReg[0] := 0;
end;

procedure TN64RSP.IssueADD(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := Cardinal((UInt64(FReg[(Op shr 21) and 31]) + FReg[(Op shr 16) and 31]) and $FFFFFFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSUB(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := Cardinal((UInt64(FReg[(Op shr 21) and 31]) + UInt64($100000000) - FReg[(Op shr 16) and 31]) and
      $FFFFFFFF);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueAND(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := FReg[(Op shr 21) and 31] and FReg[(Op shr 16) and 31];
  FReg[0] := 0;
end;

procedure TN64RSP.IssueOR(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := FReg[(Op shr 21) and 31] or FReg[(Op shr 16) and 31];
  FReg[0] := 0;
end;

procedure TN64RSP.IssueXOR(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := FReg[(Op shr 21) and 31] xor FReg[(Op shr 16) and 31];
  FReg[0] := 0;
end;

procedure TN64RSP.IssueNOR(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := not (FReg[(Op shr 21) and 31] or FReg[(Op shr 16) and 31]);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSLT(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := Ord(Integer(FReg[(Op shr 21) and 31]) < Integer(FReg[(Op shr 16) and 31]));
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSLTU(Op: Cardinal);
begin
  FReg[(Op shr 11) and 31] := Ord(FReg[(Op shr 21) and 31] < FReg[(Op shr 16) and 31]);
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSLTI(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := Ord(Integer(FReg[(Op shr 21) and 31]) < Integer(SmallInt(Op and $FFFF)));
  FReg[0] := 0;
end;

procedure TN64RSP.IssueSLTIU(Op: Cardinal);
begin
  FReg[(Op shr 16) and 31] := Ord(FReg[(Op shr 21) and 31] < Cardinal(Integer(SmallInt(Op and $FFFF))));
  FReg[0] := 0;
end;

// Loads and stores: big-endian bytes, each address wrapped in DMEM, straight
// in SP memory (blocks run with it direct); a store saves the lines of its
// first and last byte first, as DMemWrite does.

procedure TN64RSP.IssueLB(Op: Cardinal);
begin
  var M := FBus.DMemBytes;
  FReg[(Op shr 16) and 31] := Cardinal(Integer(ShortInt(M[((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF])));
  FReg[0] := 0;
end;

procedure TN64RSP.IssueLH(Op: Cardinal);
begin
  var M := FBus.DMemBytes;
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
  FReg[(Op shr 16) and 31] := Cardinal(Integer(SmallInt((Word(M[Address]) shl 8) or M[(Address + 1) and $FFF])));
  FReg[0] := 0;
end;

procedure TN64RSP.IssueLW(Op: Cardinal);
begin
  var M := FBus.DMemBytes;
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
  FReg[(Op shr 16) and 31] := (Cardinal(M[Address]) shl 24) or (Cardinal(M[(Address + 1) and $FFF]) shl 16) or
    (Cardinal(M[(Address + 2) and $FFF]) shl 8) or M[(Address + 3) and $FFF];
  FReg[0] := 0;
end;

procedure TN64RSP.IssueLBU(Op: Cardinal);
begin
  var M := FBus.DMemBytes;
  FReg[(Op shr 16) and 31] := M[((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF];
  FReg[0] := 0;
end;

procedure TN64RSP.IssueLHU(Op: Cardinal);
begin
  var M := FBus.DMemBytes;
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
  FReg[(Op shr 16) and 31] := (Cardinal(M[Address]) shl 8) or M[(Address + 1) and $FFF];
  FReg[0] := 0;
end;

procedure TN64RSP.StoreBytes(Op: Cardinal; Size: Cardinal);
begin
  var M := FBus.DMemBytes;
  var Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
  var V := FReg[(Op shr 16) and 31];
  if FAhead then
  begin
    if FLineRun[Address shr 6] <> FRun then
      SaveLine(Address);
    var Last := (Address + Size - 1) and $FFF;
    if FLineRun[Last shr 6] <> FRun then
      SaveLine(Last);
  end;
  for var I := 0 to Size - 1 do
    M[(Address + I) and $FFF] := Byte((V shr ((Size - 1 - I) * 8)) and $FF);
end;

procedure TN64RSP.IssueSB(Op: Cardinal);
begin
  StoreBytes(Op, 1);
end;

procedure TN64RSP.IssueSH(Op: Cardinal);
begin
  StoreBytes(Op, 2);
end;

procedure TN64RSP.IssueSW(Op: Cardinal);
begin
  StoreBytes(Op, 4);
end;

procedure TN64RSP.VectorLoad(Op: Cardinal);
begin
  VectorMemory(Op, False);
end;

procedure TN64RSP.VectorStore(Op: Cardinal);
begin
  VectorMemory(Op, True);
end;

procedure TN64RSP.VectorLoadDirect(Op: Cardinal);
begin
  VectorMemoryDirect(Op, False);
end;

procedure TN64RSP.VectorStoreDirect(Op: Cardinal);
begin
  VectorMemoryDirect(Op, True);
end;

function TN64RSP.RunBlock(B: PRSPBlock; var PC, Status, Interrupt: Cardinal; Cycles, Stop: Integer; Ahead: Boolean;
  var Ran: Integer): Integer;
begin
  // Block B's clocks as RunClocks takes them, then those of the blocks after
  // it, up to Cycles in all (Ran so far; none after a block's end from Stop
  // on): 0 when they ran as far as the
  // budget allows, 1 before a stall longer than the budget left, 3 before a
  // clock no block takes (RunClocks takes those), 2 when a fence stopped the
  // window (FAheadStop). The pipeline is set after the last clock run, and
  // before a fence as RunClocks leaves it there. The clocks run come from
  // the steps (TRSPBlockStep.Clocks), and so does the PC: PC is set before a
  // clock of IssueKind's (it moves it) and on the way out.
  //
  // The checks that concern this run (TRSPBlockStep.Checks): fences only
  // ahead and not replaying (a replay re-runs clocks that ran already, with
  // the fences set later), while there are any; journal entries ahead.
  var Fences := Ahead and not FReplaying;
  var Base: Byte := StepGeneral;
  if Ahead then
    Base := Base or StepExternal;
  while True do
  begin
    Result := 0;
    // The budget from the block's start (at least a clock).
    var Room := Cycles - Ran;
    var Mask := Base;
    if Fences and FFenced then
      Mask := Mask or StepMemory;
    // The last clock run (nil: none yet), and the block's last.
    var Done: PRSPBlockStep := nil;
    var Last: PRSPBlockStep;
    // Its generated code where the budget takes all of the block's clocks:
    // it runs them as below (its clocks that need a check by JitCheck), and
    // the blocks after it while the budget takes theirs; then B is the last
    // that ran to its end, as below, or a clock stopped the run as below.
    var Native: Pointer := nil;
    if FUseJit and (Room >= B.Clocks) and not Assigned(FOnBlock) then
    begin
      Native := B.Native;
      if (Native = nil) and not B.JitTried then
        Native := JitCodeFor(B);
    end;
    if RSPJitStats and FUseJit then
      if Room < B.Clocks then
        Inc(FJitBack[10])
      else if (Native = nil) and B.JitTried then
        Inc(FJitBack[11])
      else if Native = nil then
        Inc(FJitBack[12]);
    if Native <> nil then
    begin
      var Outcome := JitRun(B, PC, Status, Interrupt, Ran, Cycles, Stop, Base, Fences);
      if Outcome >= 0 then
        Exit(Outcome);
      Last := @FBlockSteps[B.First + B.Count - 1];
      Done := Last;
    end
    else
    begin
      Inc(FBlocksRun);
      var First: PRSPBlockStep := @FBlockSteps[B.First];
      var S := First;
      Last := @FBlockSteps[B.First + B.Count - 1];
      {$IFDEF N64_CHECKED}
      if First.PC <> PC then
        raise EInvalidOpException.Create('RSP block run at another PC');
      {$ENDIF}
      // Where the clocks stop: after the clock that reaches the budget or the
      // last one.
      var Limit := Min(Room, B.Clocks);
      // A branch is pending only before the last clock (its delay slot).
      var DelaySlot := False;
      // The last clock ran by its routines (the PC still to be set).
      var Plain := False;
      while True do
      begin
        // The clocks that need no check, then the one that does.
        var R := RunSteps(S, Mask, Room, Limit);
        if R <> First then
        begin
          Done := R;
          Dec(Done);
          if Done.Clocks >= Limit then
          begin
            Plain := True;
            Break;
          end;
        end;
        S := R;
        if (S.Wait <> 0) and (S.Clocks > Room) then
        begin
          // (The clocks before the stall.)
          Result := 1;
          PC := S.PC;
          Break;
        end;
        var Checks := S.Checks and Mask;
        // (The clocks before this one, its stall included.)
        var Before := Ran + S.Clocks - 1;
        if ((Checks and StepMemory) <> 0) and (TouchesFence(S.Op) or (S.Pair and TouchesFence(S.Second))) then
        begin
          HoldStep(Done, S);
          if not LiftFence(S.PC, S.Op, S.Second, S.Pair, FClockBase + Before + 1) then
          begin
            FAheadStop := TRSPAheadStop.Fence;
            Inc(FBlockClocks, S.Clocks - 1);
            PC := S.PC;
            Ran := Before;
            Exit(2);
          end;
          // (No fence left after the lift, no more checks: they would find
          // none. A lift sets no fence where there was none.)
          Mask := Base;
          if FFenced then
            Mask := Mask or StepMemory;
        end;
        if ((Checks and StepExternal) <> 0) and not JournalCOP0(S.Op, S.Second, S.Pair, FClockBase + Before + 1) then
        begin
          // The window ends before the clock, as RunClocks ends it. (No lift
          // came first: an MFC0 or MTC0 shares its clock with no load or
          // store, both being scalar-unit instructions.)
          HoldStep(Done, S);
          StopAtExternal(S.Op, S.Second);
          Inc(FBlockClocks, S.Clocks - 1);
          PC := S.PC;
          Ran := Before;
          Exit(2);
        end;
        if (Checks and StepGeneral) <> 0 then
        begin
          // A branch, COP0 or other instruction of IssueInstruction's, or a
          // delay slot: the PC as each instruction takes it.
          if RSPJitStats then
            CountGeneral(S);
          if S = Last then
            DelaySlot := FBranch;
          PC := S.PC;
          IssueKind(S.Kind, S.Arg, PC, Status, Interrupt);
          // (An MTC0 run here, not ahead, may halt the RSP: then not the
          // word paired with it, nor any clock after it.)
          var external := (S.Checks and StepExternal) <> 0;
          if S.Pair and (not external or ((Status and 1) = 0)) then
            IssueKind(S.SecondKind, S.SecondArg, PC, Status, Interrupt);
          Done := S;
          if external and ((Status and $21) <> 0) then
          begin
            if (Status and $20) <> 0 then
              Status := Status or 1;
            Break;
          end;
          // (A journal entry may have set fences.)
          Mask := Base;
          if Fences and FFenced then
            Mask := Mask or StepMemory;
          if S.Clocks >= Limit then
            Break;
          Inc(S);
          Continue;
        end;
        // A load or store let through: the clock's words by their routines.
        TRSPIssueProc(S.Issue)(Self, S.Arg);
        if S.Pair then
          TRSPIssueProc(S.SecondIssue)(Self, S.SecondArg);
        Done := S;
        if S.Clocks >= Limit then
        begin
          Plain := True;
          Break;
        end;
        Inc(S);
      end;
      if Plain then
      begin
        // The last clock ran by its routines: the PC after it, after a delay
        // slot where the branch took it (as IssueKind moves it).
        PC := (Cardinal(Done.PC) + 4 + 4 * Cardinal(Ord(Done.Pair))) and $FFC;
        if Done.Delay then
        begin
          // (A delay slot issues alone.)
          DelaySlot := FBranch;
          if FBranch then
          begin
            PC := FNextPC;
            FBranch := False;
          end;
        end;
      end;
      var Clocks := 0;
      if Done <> nil then
      begin
        Clocks := Done.Clocks;
        FScalarLo := Done.ScalarLo;
        FScalarHi := Done.ScalarHi;
        FVectorLo := Done.VectorLo;
        FVectorHi := Done.VectorHi;
        FLoadHistory := Done.LoadHistory;
        FSingleIssue := Done.SingleIssue;
        FHasStalledOpcode := False;
        FHasStalledSecondOpcode := False;
        if DelaySlot then
        begin
          FBranchBubble := 1;
          if (PC and 4) <> 0 then
            FSingleIssue := 1;
        end;
      end;
      Inc(FBlockClocks, Clocks);
      Inc(Ran, Clocks);
      if Assigned(FOnBlock) then
        FOnBlock(Ran);
    end;
    if (Result <> 0) or (Done <> Last) or (Ran >= Stop) or ((Status and 1) <> 0) then
      Exit;
    // The block ran to its end: its bubble, as RunClocks takes it (the
    // checkpoint is taken).
    var Taken := 0;
    if FBranchBubble > 0 then
    begin
      Taken := 1;
      Dec(FBranchBubble);
      AgePipeline;
      Inc(Ran);
      if Ran >= Stop then
        Exit;
    end;
    // A branch still pending (in the delay slot, or its delay slot external,
    // or the block cut at its longest): RunClocks.
    if FBranch then
      Exit(3);
    // The next block: the one that came here before, else found.
    var Next := NextBlock(B, Taken, PC);
    {$IFDEF N64_CHECKED}
    if (Next.ScalarLo <> FScalarLo) or (Next.ScalarHi <> FScalarHi) or (Next.VectorLo <> FVectorLo) or
      (Next.VectorHi <> FVectorHi) or (Next.LoadHistory <> FLoadHistory) or (Next.SingleIssue <> FSingleIssue) then
      raise EInvalidOpException.Create('RSP block linked to another pipeline state');
    {$ENDIF}
    if Next.Count = 0 then
      Exit(3);
    B := Next;
  end;
end;

// --- Blocks as generated code ------------------------------------------------
//
// HW.JIT, as the CPU's blocks (N64.CPU): a block's code runs its clocks as
// RunBlock does where the budget takes them all: each clock's stall noted,
// its words' routines called (FKindIssue: what a word does is its routine's
// alone), a clock that needs a check of the run by JitCheck (RunBlock's
// steps for it), then the block's plain end (the PC after it, the pipeline,
// the counts). Then the shared chaining code goes on as RunBlock does (the
// budget, the branch bubble, the link) into the next block's code where it
// is such a block too, else back to RunBlock with the last block that ran
// to its end (or where JitCheck stopped the run). The code is written in
// HW.JIT's operations; its registers by role: Self the RSP, Ctx the
// TRSPJitCtx, and the kept S0..S3 as Block, Ran (the clocks run), Slot (a
// delay slot's branch taken) and PC (after the block).

const
  jrRB = jrS0;
  jrRan = jrS1;
  jrSlot = jrS2;
  jrPC = jrS3;
  JRB: TJitOp = (Kind: okReg; Reg: jrRB);
  JRan: TJitOp = (Kind: okReg; Reg: jrRan);
  JSlot: TJitOp = (Kind: okReg; Reg: jrSlot);
  JPC: TJitOp = (Kind: okReg; Reg: jrPC);
  RSPJitBufferSize = 16 * 1024 * 1024;
  // FJitCalls past the kinds' routines.
  RSPJitCallCheck = 256;
  // JitCheck's Step: the step's index, whether it is its block's first,
  // last.
  RSPJitFirstStep = 1 shl 28;
  RSPJitLastStep = 1 shl 29;

type
  // Where the code reads and writes the RSP, its context and blocks
  // (offsets, worked out once).
  TRSPJitOffsets = record
    StalledOp, StalledPC, StalledSecond, HasStalled, HasStalledSecond: Integer;
    ScalarLo, ScalarHi, VectorLo, VectorHi, LoadHistory, SingleIssue: Integer;
    Branch, NextPC, BranchBubble, BlocksRun, BlockClocks, Calls, Back: Integer;
    CtxCycles, CtxStop, CtxRan, CtxPC, CtxFences, CtxSlot, CtxBlock: Integer;
    BClocks, BNative, BLink, BLinkPC, BChecked, BIndex, BRegions, Fenced, Fence, Reg: Integer;
    Jumps, JumpBlock: Integer;
  end;

var
  RSPOff: TRSPJitOffsets;

procedure RSPJitWorkOutOffsets;
begin
  var O := Default(TRSPJitOffsets);
  O.StalledOp := Integer(NativeUInt(@TN64RSP(nil).FStalledOpcode));
  O.StalledPC := Integer(NativeUInt(@TN64RSP(nil).FStalledPC));
  O.StalledSecond := Integer(NativeUInt(@TN64RSP(nil).FStalledSecondOpcode));
  O.HasStalled := Integer(NativeUInt(@TN64RSP(nil).FHasStalledOpcode));
  O.HasStalledSecond := Integer(NativeUInt(@TN64RSP(nil).FHasStalledSecondOpcode));
  O.ScalarLo := Integer(NativeUInt(@TN64RSP(nil).FScalarLo));
  O.ScalarHi := Integer(NativeUInt(@TN64RSP(nil).FScalarHi));
  O.VectorLo := Integer(NativeUInt(@TN64RSP(nil).FVectorLo));
  O.VectorHi := Integer(NativeUInt(@TN64RSP(nil).FVectorHi));
  O.LoadHistory := Integer(NativeUInt(@TN64RSP(nil).FLoadHistory));
  O.SingleIssue := Integer(NativeUInt(@TN64RSP(nil).FSingleIssue));
  O.Branch := Integer(NativeUInt(@TN64RSP(nil).FBranch));
  O.NextPC := Integer(NativeUInt(@TN64RSP(nil).FNextPC));
  O.BranchBubble := Integer(NativeUInt(@TN64RSP(nil).FBranchBubble));
  O.BlocksRun := Integer(NativeUInt(@TN64RSP(nil).FBlocksRun));
  O.BlockClocks := Integer(NativeUInt(@TN64RSP(nil).FBlockClocks));
  O.Calls := Integer(NativeUInt(@TN64RSP(nil).FJitCalls[0]));
  O.Back := Integer(NativeUInt(@TN64RSP(nil).FJitBack[0]));
  O.CtxCycles := Integer(NativeUInt(@PRSPJitCtx(nil).Cycles));
  O.CtxStop := Integer(NativeUInt(@PRSPJitCtx(nil).Stop));
  O.CtxRan := Integer(NativeUInt(@PRSPJitCtx(nil).Ran));
  O.CtxPC := Integer(NativeUInt(@PRSPJitCtx(nil).PC));
  O.CtxFences := Integer(NativeUInt(@PRSPJitCtx(nil).Fences));
  O.CtxSlot := Integer(NativeUInt(@PRSPJitCtx(nil).Slot));
  O.CtxBlock := Integer(NativeUInt(@PRSPJitCtx(nil).Block));
  O.BClocks := Integer(NativeUInt(@PRSPBlock(nil).Clocks));
  O.BNative := Integer(NativeUInt(@PRSPBlock(nil).Native));
  O.BLink := Integer(NativeUInt(@PRSPBlock(nil).Link[0]));
  O.BLinkPC := Integer(NativeUInt(@PRSPBlock(nil).LinkPC[0]));
  O.BChecked := Integer(NativeUInt(@PRSPBlock(nil).Checked));
  O.BIndex := Integer(NativeUInt(@PRSPBlock(nil).Index));
  O.BRegions := Integer(NativeUInt(@PRSPBlock(nil).Regions[0]));
  O.Jumps := Integer(NativeUInt(@TN64RSP(nil).FJumps[0].Key));
  O.JumpBlock := Integer(NativeUInt(@TN64RSP(nil).FJumps[0].Block)) - O.Jumps;
  O.Fenced := Integer(NativeUInt(@TN64RSP(nil).FFenced));
  O.Fence := Integer(NativeUInt(@TN64RSP(nil).FFence[0]));
  O.Reg := Integer(NativeUInt(@TN64RSP(nil).FReg[0]));
  RSPOff := O;
end;

class function TN64RSP.JitAvailable: Boolean;
begin
  {$IF RSPJit}
  Result := not RSPJitOff;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

class procedure TN64RSP.JitForTests(Hot: Integer; Model: Boolean);
begin
  RSPJitHot := Hot;
  {$IF RSPJit}
  RSPJitModel := Model;
  {$ENDIF}
end;

function TN64RSP.JitCodeFor(B: PRSPBlock): Pointer;
begin
  // B's code, made once B was entered RSPJitHot times (nil: none).
  Result := B.Native;
  if (Result <> nil) or B.JitTried then
    Exit;
  if B.JitHeat < RSPJitHot then
  begin
    Inc(B.JitHeat);
    Exit;
  end;
  Result := JitCompile(B);
  B.Native := Result;
end;

procedure TN64RSP.JitEmitShared;
var
  // Where the chaining code goes back (N64RSPJIT=stats: counted by reason).
  NoLabel: array[0..15] of TJitLabel;
  NoReason: array[0..15] of Integer;
  NoCount: Integer;

  function No(Reason: Integer): TJitLabel;
  begin
    Result := FJit.NewLabel;
    NoLabel[NoCount] := Result;
    NoReason[NoCount] := Reason;
    Inc(NoCount);
  end;

begin
  // The code every block's code shares: the entry (TJitAsm.EnterJump: the
  // frame, then the start of a run with the block in T1), the start of a
  // run (Block and Ran set, into the block's code), the ways back to
  // RunBlock (Block, Ran and PC into Ctx; or as JitCheck left Ctx), and the
  // chaining code: after a block ran to its end, as RunBlock goes on (the
  // budget, a branch bubble, no branch pending, the link at the PC, the
  // block found there valid as IMEM is) into the next block's code where
  // the budget takes all of that block's clocks; else back, nothing of that
  // done.
  var J := FJit;
  var O := RSPOff;
  var Info := FBus.JitInfo;
  J.ForgetLabels;
  J.Align(16);
  FJitEnter := J.Offset;
  J.EnterJump;
  J.Align(16);
  FJitOuter := J.Offset;
  J.Move(jw64, JRB, JT1);
  J.Move(jw32, JRan, JMem(jrCtx, O.CtxRan));
  J.JumpIndirect(JMem(jrRB, O.BNative));
  J.Align(16);
  FJitReturn := J.Offset;
  J.Move(jw32, JMem(jrCtx, O.CtxRan), JRan);
  J.Move(jw32, JMem(jrCtx, O.CtxPC), JPC);
  J.Move(jw64, JMem(jrCtx, O.CtxBlock), JRB);
  J.Leave(JImm(0));
  // Back where JitCheck stopped the run (it set Ctx).
  J.Align(16);
  FJitStop := J.Offset;
  J.Leave(JImm(0));

  J.Align(16);
  FJitChain := J.Offset;
  NoCount := 0;
  // T0: where the run may stop; the clocks run reach it.
  J.Move(jw32, JT0, JMem(jrCtx, O.CtxStop));
  J.Branch(jcGe, jw32, JRan, JT0, No(0));
  // T2: the bubble; T4: whether there is one (Taken); T1: the clocks run
  // after it, which reach the stop.
  J.Move(jw8, JT2, JMem(jrSelf, O.BranchBubble));
  J.Move(jw32, JT1, JRan);
  J.Move(jw32, JT4, JImm(0));
  var NoBubble := J.NewLabel;
  J.BranchTest(jcEq, jw32, JT2, JT2, NoBubble);
  J.Alu(jaAdd, jw32, JT1, JImm(1));
  J.Move(jw32, JT4, JImm(1));
  J.Bind(NoBubble);
  J.Branch(jcGe, jw32, JT1, JT0, No(1));
  // A branch still pending.
  J.Move(jw8, JT3, JMem(jrSelf, O.Branch));
  J.BranchTest(jcNe, jw32, JT3, JT3, No(2));
  // T5: the link Taken, at the PC; else the block FJumps has for it
  // (JumpKey, JumpSlot).
  var Lookup := J.NewLabel;
  var Linked := J.NewLabel;
  J.Move(jw64, JT5, JT4);
  J.Shift(jsShl, jw64, jrT5, 3);
  J.Alu(jaAdd, jw64, JT5, JRB);
  J.Move(jw64, JT5, JMem(jrT5, O.BLink));
  J.BranchTest(jcEq, jw64, JT5, JT5, Lookup);
  J.Move(jw64, JT6, JT4);
  J.Shift(jsShl, jw64, jrT6, 2);
  J.Alu(jaAdd, jw64, JT6, JRB);
  J.Branch(jcEq, jw32, JPC, JMem(jrT6, O.BLinkPC), Linked);
  J.Bind(Lookup);
  J.Move(jw32, JT3, JMem(jrRB, O.BIndex));
  J.Move(jw32, JT6, JT4);
  J.Shift(jsShl, jw32, jrT6, 9);
  J.Alu(jaXor, jw32, JT6, JT3);
  J.Move(jw32, JT5, JPC);
  J.Shift(jsShr, jw32, jrT5, 2);
  J.Alu(jaXor, jw32, JT5, JT6);
  J.Alu(jaAnd, jw32, JT5, JImm(1023));
  J.Shift(jsShl, jw64, jrT5, 4);
  J.Alu(jaAdd, jw64, JT5, JSelf);
  J.Shift(jsShl, jw32, jrT3, 13);
  J.Move(jw32, JT6, JT4);
  J.Shift(jsShl, jw32, jrT6, 12);
  J.Alu(jaOr, jw32, JT3, JT6);
  J.Alu(jaOr, jw32, JT3, JPC);
  J.Alu(jaAdd, jw32, JT3, JImm(1));
  J.Branch(jcNe, jw32, JT3, JMem(jrT5, O.Jumps), No(3));
  J.Move(jw64, JT5, JMem(jrT5, O.Jumps + O.JumpBlock));
  J.Bind(Linked);
  // Its IMEM eighths unchanged since it was checked (else RunBlock compares
  // its words).
  J.Move(jw64, JT6, JImm(Int64(NativeUInt(Info.IMemRegions))));
  for var K := 0 to 1 do
  begin
    J.Move(jw8, JT3, JMem(jrT5, O.BRegions + K));
    J.Shift(jsShl, jw64, jrT3, 3);
    J.Alu(jaAdd, jw64, JT3, JT6);
    J.Move(jw64, JT3, JMem(jrT3, 0));
    J.Branch(jcAbove, jw64, JT3, JMem(jrT5, O.BChecked), No(5));
  end;
  // Its code, its clocks within the budget left after the bubble.
  J.Move(jw64, JT6, JMem(jrT5, O.BNative));
  J.BranchTest(jcEq, jw64, JT6, JT6, No(6));
  J.Move(jw32, JT6, JMem(jrCtx, O.CtxCycles));
  J.Alu(jaSub, jw32, JT6, JT1);
  J.Branch(jcLt, jw32, JT6, JMem(jrT5, O.BClocks), No(8));
  // On: the bubble as RunBlock takes it, then the next block.
  J.Move(jw64, JRB, JT5);
  J.Move(jw32, JRan, JT1);
  var NoAge := J.NewLabel;
  J.BranchTest(jcEq, jw32, JT4, JT4, NoAge);
  J.Alu(jaSub, jw32, JT2, JImm(1));
  J.Move(jw8, JMem(jrSelf, O.BranchBubble), JT2);
  // AgePipeline: each counter (Lo + 2 * Hi) down by one, to 0 at least.
  for var K := 0 to 1 do
  begin
    var Lo := O.ScalarLo;
    var Hi := O.ScalarHi;
    if K = 1 then
    begin
      Lo := O.VectorLo;
      Hi := O.VectorHi;
    end;
    J.Move(jw32, JT3, JMem(jrSelf, Lo));
    J.Move(jw32, JT6, JMem(jrSelf, Hi));
    J.Move(jw32, JT5, JT6);
    J.Alu(jaAnd, jw32, JT5, JT3);
    J.Move(jw32, JMem(jrSelf, Hi), JT5);
    J.Alu(jaXor, jw32, JT3, JImm(-1));
    J.Alu(jaAnd, jw32, JT3, JT6);
    J.Move(jw32, JMem(jrSelf, Lo), JT3);
  end;
  J.Move(jw8, JT3, JMem(jrSelf, O.LoadHistory));
  J.Shift(jsShl, jw32, jrT3, 1);
  J.Alu(jaAnd, jw32, JT3, JImm(3));
  J.Move(jw8, JMem(jrSelf, O.LoadHistory), JT3);
  J.Bind(NoAge);
  J.JumpIndirect(JMem(jrRB, O.BNative));
  for var K := 0 to NoCount - 1 do
  begin
    J.Bind(NoLabel[K]);
    if RSPJitStats then
      J.Alu(jaAdd, jw64, JMem(jrSelf, O.Back + NoReason[K] * 8), JImm(1));
    J.JumpTo(FJitReturn);
  end;
  J.ForgetLabels;
  J.Flush;
end;

function TN64RSP.JitCompile(B: PRSPBlock): Pointer;
begin
  // B's code (nil: none): as RunBlock runs B's clocks with no check and the
  // budget taking them all (RunSteps through the last, then the plain end),
  // then on by the chaining code. Entered with Block and Ran set.
  Result := nil;
  B.JitTried := True;
  if not FUseJit or FJitFull or (B.Count = 0) then
    Exit;
  if FJit = nil then
  begin
    // (The chaining code takes FJumps' entries as 16 bytes.)
    if SizeOf(FJumps[0]) <> 16 then
    begin
      FUseJit := False;
      Exit;
    end;
    {$IF RSPJit}
    if RSPJitModel then
      FJit := CreateJitModel(RSPJitBufferSize)
    else
    {$ENDIF}
      FJit := CreateJitAsm(RSPJitBufferSize);
    if FJit = nil then
    begin
      FUseJit := False;
      Exit;
    end;
    // (Fields the code uses past the first ones: the pipeline's rest, the
    // counts, the routines it calls.)
    FJit.AddWindow(RSPOff.SingleIssue);
    FJit.AddWindow(RSPOff.Calls);
    for var K := 0 to 255 do
      FJitCalls[K] := FKindIssue[K];
    FJitCalls[RSPJitCallCheck] := @TN64RSP.JitCheck;
  end;
  if not FJit.Room(4096 + B.Count * 512) then
  begin
    FJitFull := True;
    Exit;
  end;
  if FJitEnter = 0 then
    JitEmitShared;
  var J := FJit;
  var O := RSPOff;
  J.ForgetLabels;
  J.Align(16);
  Result := J.Here;
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.BlocksRun), JImm(1));
  // A clock that needs a check of the run: by JitCheck (a general one
  // always; a load or store while the run has fences), back where it stops
  // the run.
  var Stop := J.NewLabel;
  for var I := 0 to B.Count - 1 do
  begin
    var S: PRSPBlockStep := @FBlockSteps[B.First + I];
    var Step := B.First + I;
    if I = 0 then
      Step := Step or RSPJitFirstStep;
    if I = B.Count - 1 then
      Step := Step or RSPJitLastStep;
    if S.Wait <> 0 then
    begin
      J.Move(jw32, JMem(jrSelf, O.StalledOp), JImm(S.Op));
      J.Move(jw32, JMem(jrSelf, O.StalledPC), JImm(S.PC));
      J.Move(jw32, JMem(jrSelf, O.StalledSecond), JImm(S.Second));
    end;
    if (S.Checks and StepGeneral) <> 0 then
    begin
      J.CallAt(JMem(jrSelf, O.Calls + RSPJitCallCheck * 8), [JSelf, JCtx, JImm(Step), JRan]);
      J.BranchTest(jcNe, jw32, JT0, JT0, Stop);
      Continue;
    end;
    var Next: TJitLabel := -1;
    if (S.Checks and StepMemory) <> 0 then
    begin
      // While the run has fences and DMEM has any: the groups the load or
      // store may touch (as TouchesFence finds them, the base register as
      // before the clock) tested here, JitCheck where one is fenced.
      var Plain := J.NewLabel;
      var Fenced := J.NewLabel;
      Next := J.NewLabel;
      J.Move(jw8, JT0, JMem(jrCtx, O.CtxFences));
      J.BranchTest(jcEq, jw32, JT0, JT0, Plain);
      J.Move(jw8, JT0, JMem(jrSelf, O.Fenced));
      J.BranchTest(jcEq, jw32, JT0, JT0, Plain);
      var W := S.Op;
      if not LoadStore(W) then
        W := S.Second;
      var Code := W shr 26;
      J.Move(jw32, JT0, JMem(jrSelf, O.Reg + Integer((W shr 21) and 31) * 4));
      var Flags: Cardinal := 1;
      if Code in [40..43, 58] then
        Flags := 2;
      if Code in [50, 58] then
      begin
        // 32 bytes from 16 below the 16-byte line: four groups (FFence's
        // copy of 0..3 past its end).
        var Kind := (W shr 11) and 31;
        var Size: Integer := 16;
        if Kind <= 3 then
          Size := 1 shl Kind
        else if Kind in [6, 7] then
          Size := 8;
        var Offset := Integer(SignedValue(SX(W and 127, 7)));
        J.Alu(jaAdd, jw32, JT0, JImm(Int64(Cardinal((Int64(Offset) * Size) and $FFFFFFFF))));
        J.Alu(jaAnd, jw32, JT0, JImm($FF0));
        J.Shift(jsShr, jw32, jrT0, 3);
        J.Alu(jaAdd, jw64, JT0, JSelf);
        J.Move(jw32, JT1, JMem(jrT0, O.Fence));
        J.BranchTest(jcNe, jw32, JT1, JImm(Flags * $01010101), Fenced);
      end
      else
      begin
        // Its first and last byte's groups.
        var Size := 1;
        if Code in [33, 37, 41] then
          Size := 2
        else if Code in [35, 39, 43] then
          Size := 4;
        J.Alu(jaAdd, jw32, JT0, JImm(W and $FFF));
        J.Alu(jaAnd, jw32, JT0, JImm($FFF));
        J.Move(jw32, JT1, JT0);
        J.Alu(jaAdd, jw32, JT1, JImm(Size - 1));
        J.Shift(jsShr, jw32, jrT0, 3);
        J.Shift(jsShr, jw32, jrT1, 3);
        J.Alu(jaAdd, jw64, JT0, JSelf);
        J.Alu(jaAdd, jw64, JT1, JSelf);
        J.Move(jw8, JT2, JMem(jrT0, O.Fence));
        J.Move(jw8, JT3, JMem(jrT1, O.Fence));
        J.Alu(jaOr, jw32, JT2, JT3);
        J.BranchTest(jcNe, jw32, JT2, JImm(Flags), Fenced);
      end;
      J.Jump(Plain);
      J.Bind(Fenced);
      J.CallAt(JMem(jrSelf, O.Calls + RSPJitCallCheck * 8), [JSelf, JCtx, JImm(Step), JRan]);
      J.BranchTest(jcNe, jw32, JT0, JT0, Stop);
      J.Jump(Next);
      J.Bind(Plain);
    end;
    J.CallAt(JMem(jrSelf, O.Calls + Integer(S.Kind) * 8), [JSelf, JImm(S.Arg)]);
    if S.Pair then
      J.CallAt(JMem(jrSelf, O.Calls + Integer(S.SecondKind) * 8), [JSelf, JImm(S.SecondArg)]);
    if Next >= 0 then
      J.Bind(Next);
  end;
  // The plain end: the PC after the last clock (after a delay slot where the
  // branch took it; as JitCheck left it after a general one), the pipeline
  // after it, a delay slot's bubble, the counts.
  var Last: PRSPBlockStep := @FBlockSteps[B.First + B.Count - 1];
  var LastGeneral := (Last.Checks and StepGeneral) <> 0;
  if LastGeneral then
  begin
    J.Move(jw32, JPC, JMem(jrCtx, O.CtxPC));
    J.Move(jw8, JSlot, JMem(jrCtx, O.CtxSlot));
  end
  else
    J.Move(jw32, JPC, JImm((Cardinal(Last.PC) + 4 + 4 * Cardinal(Ord(Last.Pair))) and $FFC));
  if Last.Delay and not LastGeneral then
  begin
    var NoBranch := J.NewLabel;
    J.Move(jw8, JSlot, JMem(jrSelf, O.Branch));
    J.BranchTest(jcEq, jw32, JSlot, JSlot, NoBranch);
    J.Move(jw32, JPC, JMem(jrSelf, O.NextPC));
    J.Move(jw8, JMem(jrSelf, O.Branch), JImm(0));
    J.Bind(NoBranch);
  end;
  J.Move(jw32, JMem(jrSelf, O.ScalarLo), JImm(Last.ScalarLo));
  J.Move(jw32, JMem(jrSelf, O.ScalarHi), JImm(Last.ScalarHi));
  J.Move(jw32, JMem(jrSelf, O.VectorLo), JImm(Last.VectorLo));
  J.Move(jw32, JMem(jrSelf, O.VectorHi), JImm(Last.VectorHi));
  J.Move(jw8, JMem(jrSelf, O.LoadHistory), JImm(Last.LoadHistory));
  J.Move(jw8, JMem(jrSelf, O.SingleIssue), JImm(Last.SingleIssue));
  J.Move(jw8, JMem(jrSelf, O.HasStalled), JImm(0));
  J.Move(jw8, JMem(jrSelf, O.HasStalledSecond), JImm(0));
  if Last.Delay or LastGeneral then
  begin
    var NoSlot := J.NewLabel;
    J.BranchTest(jcEq, jw32, JSlot, JSlot, NoSlot);
    J.Move(jw8, JMem(jrSelf, O.BranchBubble), JImm(1));
    J.BranchTest(jcEq, jw32, JPC, JImm(4), NoSlot);
    J.Move(jw8, JMem(jrSelf, O.SingleIssue), JImm(1));
    J.Bind(NoSlot);
  end;
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.BlockClocks), JImm(B.Clocks));
  J.Alu(jaAdd, jw32, JRan, JImm(B.Clocks));
  J.JumpTo(FJitChain);
  J.Bind(Stop);
  J.JumpTo(FJitStop);
  J.ForgetLabels;
  J.Flush;
  Inc(FJitCompiled);
end;

function TN64RSP.JitRun(var B: PRSPBlock; var PC, Status, Interrupt: Cardinal; var Ran: Integer; Cycles, Stop: Integer;
  Mask: Byte; Fences: Boolean): Integer;
begin
  // B's code and the blocks' it chains to (RunBlock found that the budget
  // takes all of B's clocks; Mask: the run's checks but StepMemory, Fences:
  // that too while DMEM has fences): then B is the last block that ran to
  // its end, PC the PC after it, Ran with all their clocks (and the bubbles
  // between them), the result -1; or a clock stopped the run as RunBlock
  // stops it there, the result RunBlock's (PC, Ran as it leaves them).
  var Ctx: TRSPJitCtx;
  Ctx.Cycles := Cycles;
  Ctx.Stop := Stop;
  Ctx.Ran := Ran;
  Ctx.Outcome := -1;
  Ctx.PC := PC;
  Ctx.Mask := Mask;
  Ctx.Fences := Ord(Fences);
  Ctx.Slot := 0;
  Ctx.Block := B;
  Ctx.Status := @Status;
  Ctx.Interrupt := @Interrupt;
  Inc(FJitRuns);
  FJit.Invoke(FJit.Base + FJitEnter, NativeUInt(Self), NativeUInt(@Ctx), NativeUInt(FJit.Base + FJitOuter), NativeUInt(B));
  B := Ctx.Block;
  PC := Ctx.PC;
  Ran := Ctx.Ran;
  Result := Ctx.Outcome;
end;

procedure TN64RSP.CountGeneral(S: PRSPBlockStep);
begin
  // (N64RSPJIT=stats: a general clock's instruction, by opcode; SPECIAL by
  // function, COP0 and COP2 by their rs.)
  var G := S.Op;
  if S.Kind <> 0 then
    G := S.Second;
  if (G shr 26) = 0 then
    Inc(FJitGen[64 + (G and 63)])
  else if (G shr 26) in [16, 18] then
    Inc(FJitGen[128 + ((G shr 26) - 16) * 16 + ((G shr 21) and 15)])
  else
    Inc(FJitGen[G shr 26]);
end;

function TN64RSP.JitCheck(Ctx: PRSPJitCtx; Step, Ran: Integer): Cardinal;
begin
  // (For a block's code.) Block clock Step (with RSPJitFirstStep and
  // RSPJitLastStep) that needs a check of the run, as RunBlock takes it, Ran
  // the clocks before its block: 0 when the code goes on after it (it ran);
  // 1 when it stopped the run as RunBlock stops it there (Ctx: Outcome, PC,
  // Ran as RunBlock leaves them). Ctx.PC: the PC as a general clock's words
  // moved it; Ctx.Slot: whether a branch was pending before them.
  var S: PRSPBlockStep := @FBlockSteps[Step and (RSPJitFirstStep - 1)];
  var Done: PRSPBlockStep := nil;
  if (Step and RSPJitFirstStep) = 0 then
  begin
    Done := S;
    Dec(Done);
  end;
  // (The clocks before this one, its stall included.)
  var Before := Ran + S.Clocks - 1;
  Result := 1;
  if ((S.Checks and StepMemory) <> 0) and (Ctx.Fences <> 0) and FFenced and
    (TouchesFence(S.Op) or (S.Pair and TouchesFence(S.Second))) then
  begin
    HoldStep(Done, S);
    if not LiftFence(S.PC, S.Op, S.Second, S.Pair, FClockBase + Before + 1) then
    begin
      FAheadStop := TRSPAheadStop.Fence;
      Inc(FBlockClocks, S.Clocks - 1);
      Ctx.Outcome := 2;
      Ctx.PC := S.PC;
      Ctx.Ran := Before;
      Exit;
    end;
  end;
  if ((S.Checks and Ctx.Mask and StepExternal) <> 0) and not JournalCOP0(S.Op, S.Second, S.Pair, FClockBase + Before + 1) then
  begin
    HoldStep(Done, S);
    StopAtExternal(S.Op, S.Second);
    Inc(FBlockClocks, S.Clocks - 1);
    Ctx.Outcome := 2;
    Ctx.PC := S.PC;
    Ctx.Ran := Before;
    Exit;
  end;
  if (S.Checks and StepGeneral) = 0 then
  begin
    // A load or store let through.
    TRSPIssueProc(S.Issue)(Self, S.Arg);
    if S.Pair then
      TRSPIssueProc(S.SecondIssue)(Self, S.SecondArg);
    Exit(0);
  end;
  if RSPJitStats then
    CountGeneral(S);
  Ctx.Slot := Ord(FBranch);
  var PC := Cardinal(S.PC);
  IssueKind(S.Kind, S.Arg, PC, Ctx.Status^, Ctx.Interrupt^);
  var external := (S.Checks and StepExternal) <> 0;
  if S.Pair and (not external or ((Ctx.Status^ and 1) = 0)) then
    IssueKind(S.SecondKind, S.SecondArg, PC, Ctx.Status^, Ctx.Interrupt^);
  Ctx.PC := PC;
  if not external or ((Ctx.Status^ and $21) = 0) then
    Exit(0);
  // Halted or single-stepping: the run ends after the clock.
  if (Ctx.Status^ and $20) <> 0 then
    Ctx.Status^ := Ctx.Status^ or 1;
  FScalarLo := S.ScalarLo;
  FScalarHi := S.ScalarHi;
  FVectorLo := S.VectorLo;
  FVectorHi := S.VectorHi;
  FLoadHistory := S.LoadHistory;
  FSingleIssue := S.SingleIssue;
  FHasStalledOpcode := False;
  FHasStalledSecondOpcode := False;
  if ((Step and RSPJitLastStep) <> 0) and (Ctx.Slot <> 0) then
  begin
    FBranchBubble := 1;
    if (PC and 4) <> 0 then
      FSingleIssue := 1;
  end;
  Inc(FBlockClocks, S.Clocks);
  Ctx.Outcome := 0;
  Ctx.Ran := Ran + S.Clocks;
end;

function TN64RSP.RunSteps(S: PRSPBlockStep; Mask: Byte; Room, Limit: Integer): PRSPBlockStep;
begin
  // A block's clocks from S on (RunBlock): up to the first that needs one of
  // Mask's checks or stalls past Room, the clocks the budget leaves from the
  // block's start (not run: the result is that clock), or through the one
  // that reaches Limit (the result is the step after it).
  while True do
  begin
    if S.Wait <> 0 then
    begin
      if S.Clocks > Room then
        Exit(S);
      FStalledOpcode := S.Op;
      FStalledPC := S.PC;
      FStalledSecondOpcode := S.Second;
    end;
    if (S.Checks and Mask) <> 0 then
      Exit(S);
    TRSPIssueProc(S.Issue)(Self, S.Arg);
    if S.Pair then
      TRSPIssueProc(S.SecondIssue)(Self, S.SecondArg);
    if S.Clocks >= Limit then
      Break;
    Inc(S);
  end;
  Inc(S);
  Result := S;
end;

procedure TN64RSP.HoldStep(Done, S: PRSPBlockStep);
begin
  // Before block clock S (Done: the clock before it, if any) a window
  // stops: the pipeline after its stall, its words held, as RunClocks
  // leaves it there.
  if Done <> nil then
  begin
    FScalarLo := Done.ScalarLo;
    FScalarHi := Done.ScalarHi;
    FVectorLo := Done.VectorLo;
    FVectorHi := Done.VectorHi;
    FLoadHistory := Done.LoadHistory;
    FSingleIssue := Done.SingleIssue;
    FHasStalledOpcode := False;
    FHasStalledSecondOpcode := False;
  end;
  if S.Wait > 0 then
  begin
    AgePipelineBy(S.Wait);
    FHasStalledOpcode := True;
    FHasStalledSecondOpcode := S.Pair;
  end;
end;

procedure TN64RSP.StopAtExternal(Op, Second: Cardinal);
begin
  // The window ended before the clock of Op (and Second) for its external
  // instruction: why.
  var Ext := Op;
  if not external(Op) then
    Ext := Second;
  FAheadStopIndex := Integer((Ext shr 11) and 15);
  if ((Ext shr 26) = 16) and (((Ext shr 21) and 31) = 4) then
    FAheadStop := TRSPAheadStop.WriteCOP0
  else if ((Ext shr 26) = 16) and (((Ext shr 21) and 31) = 0) then
    FAheadStop := TRSPAheadStop.ReadCOP0
  else
    FAheadStop := TRSPAheadStop.BreakOrRaise;
end;

class function TN64RSP.LoadStore(Op: Cardinal): Boolean;
begin
  // The instructions TouchesFence looks at.
  Result := (Op shr 26) in [32, 33, 35..37, 39, 40, 41, 43, 50, 58];
end;

class function TN64RSP.JournalStep(Op, Second: Cardinal; Pair: Boolean): Boolean;
begin
  // Whether a clock with an external instruction may be a block's: its one
  // external instruction (as JournalCOP0 finds it) is an MFC0 or MTC0, so
  // nothing in the block raises. (Two never pair, no vector-unit
  // instruction being external: a guard.)
  var Access := Op;
  if not external(Op) then
    Access := Second
  else if Pair and external(Second) then
    Exit(False);
  Result := ((Access shr 26) = 16) and (((Access shr 21) and 31) in [0, 4]);
end;

class function TN64RSP.external(Op: Cardinal): Boolean;
begin
  // Instructions that may touch state outside the RSP and DMEM, or raise.
  Result := True;
  case Op shr 26 of
    0:
      Result := not ((Op and 63) in [0, 2, 3, 4, 6, 7, 8, 9, 32..39, 42, 43]);
    1:
      Result := not (((Op shr 16) and 31) in [0, 1, 16, 17]);
    2..15, 32, 33, 35..37, 39..41, 43:
      Result := False;
    18:
      Result := not ((((Op shr 21) and 31) >= 16) or (((Op shr 21) and 31) in [0, 2, 4, 6]));
    50, 58:
      Result := ((Op shr 11) and 31) > 11;
  end;
end;

procedure TN64RSP.SaveCheckpoint(PC: Cardinal);
begin
  // Same element types and bounds: plain copies.
  Move(FReg, FCheckpoint.Reg, SizeOf(FReg));
  Move(FVec, FCheckpoint.Vec, SizeOf(FVec));
  Move(FAcc, FCheckpoint.Acc, SizeOf(FAcc));
  FCheckpoint.VCO := FVCO;
  FCheckpoint.VCC := FVCC;
  FCheckpoint.VCE := FVCE;
  FCheckpoint.NextPC := FNextPC;
  FCheckpoint.PC := PC;
  FCheckpoint.Branch := FBranch;
  FCheckpoint.DivisionHigh := FDivisionHigh;
  FCheckpoint.DivisionInput := FDivisionInput;
  FCheckpoint.DivisionResult := FDivisionResult;
  FCheckpoint.ScalarLo := FScalarLo;
  FCheckpoint.ScalarHi := FScalarHi;
  FCheckpoint.VectorLo := FVectorLo;
  FCheckpoint.VectorHi := FVectorHi;
  FCheckpoint.SingleIssue := FSingleIssue;
  FCheckpoint.StalledSecondOpcode := FStalledSecondOpcode;
  FCheckpoint.HasStalledSecondOpcode := FHasStalledSecondOpcode;
  FCheckpoint.LoadHistory := FLoadHistory;
  FCheckpoint.BranchBubble := FBranchBubble;
  FCheckpoint.StalledOpcode := FStalledOpcode;
  FCheckpoint.StalledPC := FStalledPC;
  FCheckpoint.HasStalledOpcode := FHasStalledOpcode;
  FCheckpointed := True;
  FAhead := True;
end;

procedure TN64RSP.SaveLine(Offset: Cardinal);
begin
  // The first write to this line in the run: keep the line as it was.
  var Line := Offset and $FC0;
  if FBus.DirectMemory then
    FBus.CopyFromSP(Line, FLineBackup, Integer(Line), 64)
  else
    for var I := 0 to 63 do
      FLineBackup[Line + Cardinal(I)] := DMemRead(Line + Cardinal(I));
  // After the copy (full barrier), for LineSaved on another thread.
  TInterlocked.Exchange(Integer(FLineRun[Offset shr 6]), Integer(FRun));
end;

procedure TN64RSP.NewRun;
begin
  // A new run: no DMEM line saved yet.
  if FRun = High(Cardinal) then
  begin
    for var I := 0 to High(FLineRun) do
      FLineRun[I] := 0;
    FRun := 0;
  end;
  Inc(FRun);
  FRunFresh := True;
end;

function TN64RSP.LineSaved(Offset: Cardinal): Boolean;
begin
  Result := Cardinal(TInterlocked.CompareExchange(Integer(FLineRun[(Offset and $FFF) shr 6]), 0, 0)) = FRun;
end;

function TN64RSP.JournalCOP0(Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
begin
  // A clock that issues an external instruction runs ahead only if that is
  // its one external instruction and an MFC0 whose value is known or an
  // MTC0 the console applies later: from the journal in a replay, else as
  // OnPredict or OnDefer allow (then journalled).
  Result := False;
  var Access := Op;
  if not external(Op) then
    Access := Second
  else if Pair and external(Second) then
    Exit;
  var Kind := (Access shr 21) and 31;
  if ((Access shr 26) <> 16) or not (Kind in [0, 4]) then
    Exit;
  var Index := Integer((Access shr 11) and 15);
  var Write := Kind = 4;
  var Value: Cardinal := 0;
  if FReplaying then
  begin
    // Lifted fences are not checked in a replay.
    while (FReplayPos < FJournalCount) and FJournal[FReplayPos].Lift do
      Inc(FReplayPos);
    if (FReplayPos >= FJournalCount) or (FJournal[FReplayPos].Clock <> Clock) or (FJournal[FReplayPos].Index <> Index) or
      (FJournal[FReplayPos].Write <> Write) then
      if FReplayPos >= FJournalCount then
        raise EInvalidOpException.CreateFmt('RSP rewind replay diverged from the journal: clock %d index %d write %s past its %d entries', [Clock, Index, BoolToStr(Write, True), FJournalCount])
      else
        raise EInvalidOpException.CreateFmt('RSP rewind replay diverged from the journal: clock %d index %d write %s, entry %d of %d: clock %d index %d write %s', [Clock, Index, BoolToStr(Write, True), FReplayPos, FJournalCount, FJournal[FReplayPos].Clock, FJournal[FReplayPos].Index, BoolToStr(FJournal[FReplayPos].Write, True)]);
    Value := FJournal[FReplayPos].Value;
    Inc(FReplayPos);
  end
  else
  begin
    // A full journal ends the window (room for a lift entry and this one).
    if FJournalCount >= JournalCapacity - 2 then
      Exit;
    if Write then
    begin
      // The MTC0 is its clock's one scalar-unit instruction: its source
      // register holds the value it writes.
      Value := FReg[(Access shr 16) and 31];
      if not Assigned(FDefer) or ((((FDeferSilent shr Index) and 1) = 0) and not FDefer(Index, Clock, Value)) then
        Exit;
    end
    else if not Assigned(FPredict) or not FPredict(Index, Clock, Value) then
      Exit;
    AddJournal(Clock, Index, Value, Write, False);
  end;
  if Write then
    FWritePending := True
  else
  begin
    FReadValue := Value;
    FReadPending := True;
  end;
  Result := True;
end;

procedure TN64RSP.AddFence(Offset, Count: Cardinal; Reads: Boolean; Source: Byte);
begin
  if Count = 0 then
    Exit;
  var Flags: Byte := 2 or (Source shl 2);
  if Reads then
    Flags := Flags or 1;
  for var Group := Integer(Offset shr 3) to Integer((Offset + Count - 1) shr 3) do
    FFence[Group and 511] := FFence[Group and 511] or Flags;
  for var Group := 0 to 3 do
    FFence[512 + Group] := FFence[Group];
  FFenced := True;
end;

function TN64RSP.WroteAhead(Offset, Count: Cardinal): Boolean;
begin
  Result := False;
  if not FAhead or (Count = 0) then
    Exit;
  for var Line := Integer(Offset shr 6) to Integer((Offset + Count - 1) shr 6) do
    if FLineRun[Line and 63] = FRun then
      Exit(True);
end;

function TN64RSP.ReadFenced(Offset, Count: Cardinal): Boolean;
begin
  Result := False;
  if not FFenced or (Count = 0) then
    Exit;
  for var Group := Integer(Offset shr 3) to Integer((Offset + Count - 1) shr 3) do
    if (FFence[Group and 511] and 1) <> 0 then
      Exit(True);
end;

function TN64RSP.TouchesFence(Op: Cardinal): Boolean;
begin
  // Whether a scalar or vector load or store may touch a fenced line: the
  // exact bytes of a scalar access; for a vector one, 32 bytes around its
  // address that hold every byte any form touches. A
  // load/store is the scalar unit's instruction of its clock, so the base
  // register is as before the clock.
  var Code := Op shr 26;
  var Address, Last: Cardinal;
  var Writing: Boolean;
  case Code of
    32, 33, 35..37, 39, 40, 41, 43:
      begin
        Address := ((FReg[(Op shr 21) and 31] and $FFF) + (Op and $FFF)) and $FFF;
        var Size: Cardinal := 1;
        if Code in [33, 37, 41] then
          Size := 2
        else if Code in [35, 39, 43] then
          Size := 4;
        Last := Address + Size - 1;
        Writing := Code >= 40;
      end;
    50, 58:
      begin
        var Kind := (Op shr 11) and 31;
        var Size: Integer := 16;
        if Kind <= 3 then
          Size := 1 shl Kind
        else if Kind in [6, 7] then
          Size := 8;
        var Offset := Integer(SignedValue(SX(Op and 127, 7)));
        // From 16 bytes below (LRV/SRV) to 16 above the 8-byte group.
        Address := Cardinal(Add64(FReg[(Op shr 21) and 31], SX(UInt64((Int64(Offset) * Size) and $FFFFFFFF), 32)) and $FF0);
        Last := Address + 31;
        Writing := Code = 58;
      end;
  else
    Exit(False);
  end;
  var Flags: Byte := 1;
  if Writing then
    Flags := 2;
  for var Group := Integer(Address shr 3) to Integer(Last shr 3) do
    if (FFence[Group and 511] and Flags) <> 0 then
    begin
      FAheadStopIndex := Flags or (FFence[Group and 511] and not Cardinal(3));
      Exit(True);
    end;
  Result := False;
end;

procedure TN64RSP.AddJournal(Clock, Index: Integer; Value: Cardinal; Write, Lift: Boolean);
begin
  if FJournalCount >= JournalCapacity then
    raise EInvalidOpException.Create('RSP journal full');
  FJournal[FJournalCount].Clock := Clock;
  FJournal[FJournalCount].Index := Index;
  FJournal[FJournalCount].Value := Value;
  FJournal[FJournalCount].Write := Write;
  FJournal[FJournalCount].Lift := Lift;
  Inc(FJournalCount);
end;

function TN64RSP.LiftFence(PC, Op, Second: Cardinal; Pair: Boolean; Clock: Integer): Boolean;
begin
  // A clock stopped by a fence: the console may lift the fences of DMA it
  // expects done by then (writing DMEM through WriteAhead, hence the
  // checkpoint first).
  Result := False;
  if not Assigned(FLift) or (FJournalCount >= JournalCapacity - 2) then
    Exit;
  if not FCheckpointed then
    SaveCheckpoint(PC);
  FFencedOp := Op;
  FFencedSecond := Second;
  FFencedPair := Pair;
  if not FLift(Clock) then
    Exit;
  if ClockFenced then
    raise EInvalidOpException.Create('RSP clock still fenced after a lift');
  AddJournal(Clock, -1, 0, False, True);
  Result := True;
end;

function TN64RSP.ClockFenced: Boolean;
begin
  Result := FFenced and (TouchesFence(FFencedOp) or (FFencedPair and TouchesFence(FFencedSecond)));
end;

procedure TN64RSP.WriteAhead(Offset: Cardinal; Value: Byte);
begin
  if not FAhead then
    raise EInvalidOpException.Create('RSP DMEM write ahead outside a window');
  DMemWrite(Offset and $FFF, Value);
end;

procedure TN64RSP.WriteAheadBytes(Offset: Cardinal; Source: PByte; Count: Cardinal);
begin
  if not FAhead then
    raise EInvalidOpException.Create('RSP DMEM write ahead outside a window');
  if Count = 0 then
    Exit;
  if Offset + Count > $1000 then
    raise ERangeError.Create('RSP DMEM write ahead past DMEM');
  // Every line the bytes touch is saved before any of them changes, as
  // DMemWrite does: a rewind to a wrong prediction may take a path that
  // reads them before the transfer has moved them.
  for var Line := Offset shr 6 to (Offset + Count - 1) shr 6 do
    if FLineRun[Line] <> FRun then
      SaveLine(Line shl 6);
  if FBus.DirectMemory then
    Move(Source^, PByte(NativeUInt(FBus.DMemBytes) + Offset)^, Count)
  else
    for var I := 0 to Count - 1 do
      FBus.Write8($04000000 + Offset + I, PByte(NativeUInt(Source) + I)^);
end;

procedure TN64RSP.ClearFences;
begin
  if FFenced then
  begin
    FillChar(FFence, SizeOf(FFence), 0);
    FFenced := False;
  end;
end;

function TN64RSP.Journal: PRSPJournal;
begin
  Result := PRSPJournal(@FJournal[0]);
end;

function TN64RSP.JournalCount: Integer;
begin
  Result := FJournalCount;
end;

function TN64RSP.JournalEntry(I: Integer): TRSPJournalEntry;
begin
  Result := FJournal[I];
end;

function TN64RSP.RunAhead(var PC: Cardinal; Status: Cardinal; Cycles, Least: Integer): Integer;
begin
  if (Status and $21) <> 0 then
    raise EInvalidOpException.Create('RSP run-ahead while halted or single-stepping');
  // The fences set for this window stay.
  if not FRunFresh then
    NewRun;
  FRunFresh := False;
  FAhead := False;
  FCheckpointed := False;
  FJournalCount := 0;
  FReadPending := False;
  FWritePending := False;
  var Interrupt: Cardinal := 0;
  FAheadStop := TRSPAheadStop.Budget;
  FClockBase := 0;
  Result := RunClocks(PC, Status, Interrupt, Cycles, True, Least);
  FAheadClocks := Result;
  if (FAheadStop = TRSPAheadStop.Budget) and (Result < Cycles) and ((Least <= 0) or (Result < Least)) then
    FAheadStop := TRSPAheadStop.Halt;
  // Without a clock run nothing was saved or changed.
  if Result = 0 then
    EndAhead;
end;

function TN64RSP.ContinueAhead(var PC: Cardinal; Status: Cardinal; Cycles, Least: Integer): Integer;
begin
  if not FAhead or (FAheadStop <> TRSPAheadStop.Budget) then
    raise EInvalidOpException.Create('RSP window continued after it stopped');
  var Interrupt: Cardinal := 0;
  FClockBase := FAheadClocks;
  Result := RunClocks(PC, Status, Interrupt, Cycles, True, Least);
  Inc(FAheadClocks, Result);
  if (FAheadStop = TRSPAheadStop.Budget) and (Result < Cycles) and ((Least <= 0) or (Result < Least)) then
    FAheadStop := TRSPAheadStop.Halt;
end;

procedure TN64RSP.Rewind(var PC: Cardinal; Keep: Integer);
begin
  Rewind(PC, Keep, [], nil);
end;

procedure TN64RSP.Rewind(var PC: Cardinal; Keep: Integer; const Stops: array of Integer; OnStop: TRSPReplayStop);
begin
  if not FCheckpointed then
    raise EInvalidOpException.Create('RSP rewind without a checkpoint');
  FAhead := False;
  for var Line := 0 to 63 do
    if FLineRun[Line] = FRun then
      if FBus.DirectMemory then
        FBus.CopyToSP(Cardinal(Line) * 64, FLineBackup, Line * 64, 64)
      else
        for var I := Line * 64 to Line * 64 + 63 do
          DMemWrite(Cardinal(I), FLineBackup[I]);
  Move(FCheckpoint.Reg, FReg, SizeOf(FReg));
  Move(FCheckpoint.Vec, FVec, SizeOf(FVec));
  Move(FCheckpoint.Acc, FAcc, SizeOf(FAcc));
  FVCO := FCheckpoint.VCO;
  FVCC := FCheckpoint.VCC;
  FVCE := FCheckpoint.VCE;
  FNextPC := FCheckpoint.NextPC;
  PC := FCheckpoint.PC;
  FBranch := FCheckpoint.Branch;
  FDivisionHigh := FCheckpoint.DivisionHigh;
  FDivisionInput := FCheckpoint.DivisionInput;
  FDivisionResult := FCheckpoint.DivisionResult;
  FScalarLo := FCheckpoint.ScalarLo;
  FScalarHi := FCheckpoint.ScalarHi;
  FVectorLo := FCheckpoint.VectorLo;
  FVectorHi := FCheckpoint.VectorHi;
  FSingleIssue := FCheckpoint.SingleIssue;
  FStalledSecondOpcode := FCheckpoint.StalledSecondOpcode;
  FHasStalledSecondOpcode := FCheckpoint.HasStalledSecondOpcode;
  FLoadHistory := FCheckpoint.LoadHistory;
  FBranchBubble := FCheckpoint.BranchBubble;
  FStalledOpcode := FCheckpoint.StalledOpcode;
  FStalledPC := FCheckpoint.StalledPC;
  FHasStalledOpcode := FCheckpoint.HasStalledOpcode;
  FCheckpointed := False;
  if Assigned(OnStop) then
    OnStop(-1);
  // The same free clocks again, up to the current point, with the reads
  // of the journal (all of them verified by then).
  var Status: Cardinal := 0;
  var Interrupt: Cardinal := 0;
  FReplaying := True;
  FReplayPos := 0;
  try
    var Done := 0;
    for var I := 0 to High(Stops) do
    begin
      if (Stops[I] < Done) or (Stops[I] > Keep) then
        raise EInvalidOpException.Create('RSP rewind stops out of order');
      FClockBase := Done;
      if RunClocks(PC, Status, Interrupt, Stops[I] - Done, True) <> Stops[I] - Done then
        raise EInvalidOpException.Create('RSP rewind replay diverged');
      Done := Stops[I];
      OnStop(I);
    end;
    FClockBase := Done;
    if RunClocks(PC, Status, Interrupt, Keep - Done, True) <> Keep - Done then
      raise EInvalidOpException.Create('RSP rewind replay diverged');
  finally
    FReplaying := False;
  end;
  EndAhead;
end;

procedure TN64RSP.EndAhead;
begin
  FAhead := False;
  FCheckpointed := False;
  FJournalCount := 0;
  FReadPending := False;
  FWritePending := False;
  ClearFences;
end;

procedure TN64RSP.SerializeState(State: TStateArchive);

  function CanonicalBoolean(const Value: Boolean): Boolean;
  begin
    // Delphi may eliminate Ord(Boolean)>1 as impossible: inspect storage.
    var Stored: Byte := 0;
    Move(Value, Stored, SizeOf(Stored));
    Result := Stored <= 1;
  end;

begin
  if not State.Loading then
    PlanesToArrays;
  State.Field(FReg, SizeOf(FReg));
  State.Field(FVec, SizeOf(FVec));
  State.Field(FAcc, SizeOf(FAcc));
  State.Field(FVCO, SizeOf(FVCO));
  State.Field(FVCC, SizeOf(FVCC));
  State.Field(FVCE, SizeOf(FVCE));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(FDivisionHigh, SizeOf(FDivisionHigh));
  State.Field(FDivisionInput, SizeOf(FDivisionInput));
  State.Field(FDivisionResult, SizeOf(FDivisionResult));
  State.Field(FScalarReady, SizeOf(FScalarReady));
  State.Field(FLoadHistory, SizeOf(FLoadHistory));
  State.Field(FBranchBubble, SizeOf(FBranchBubble));
  State.Field(FStalledOpcode, SizeOf(FStalledOpcode));
  State.Field(FStalledPC, SizeOf(FStalledPC));
  State.Field(FHasStalledOpcode, SizeOf(FHasStalledOpcode));
  State.Field(FVectorReady, SizeOf(FVectorReady));
  State.Field(FSingleIssue, SizeOf(FSingleIssue));
  State.Field(FStalledSecondOpcode, SizeOf(FStalledSecondOpcode));
  State.Field(FHasStalledSecondOpcode, SizeOf(FHasStalledSecondOpcode));
  if State.Loading then
  begin
    if (FNextPC > $FFC) or ((FNextPC and 3) <> 0) then
      raise EReadError.Create('Invalid RSP PC');
    if (FLoadHistory > 3) or (FBranchBubble > 1) or
      (FStalledPC > $FFC) or ((FStalledPC and 3) <> 0) or
      not CanonicalBoolean(FHasStalledOpcode) or not CanonicalBoolean(FBranch) or
      not CanonicalBoolean(FDivisionHigh) or (FScalarReady[0] <> 0) then
      raise EReadError.Create('Invalid RSP pipeline snapshot');
    for var I := 1 to 31 do
      if FScalarReady[I] > 2 then
        raise EReadError.Create('Invalid RSP scalar readiness');
    if (FSingleIssue > 1) or not CanonicalBoolean(FHasStalledSecondOpcode) or
      (FHasStalledSecondOpcode and not FHasStalledOpcode) then
      raise EReadError.Create('Invalid RSP pairing snapshot');
    for var I := 0 to 31 do
      if FVectorReady[I] > 3 then
        raise EReadError.Create('Invalid RSP vector readiness');
    for var I := 0 to 7 do
      if (FAcc[I] < -140737488355328) or (FAcc[I] > 140737488355327) then
        raise EReadError.Create('Invalid RSP accumulator');
    ArraysToPlanes;
  end;
end;

initialization
  for var N := 0 to 15 do
    for var K := 0 to 3 do
      if (N and (1 shl K)) <> 0 then
        RSPNibbleLanes[N] := RSPNibbleLanes[N] or (UInt64(1) shl (16 * K));
  InitKindIssue;
  InitDivideTables;
  RSPJitWorkOutOffsets;
  // N64RSPJIT: off, model, stats, hotN (where there is generated code).
  {$IF RSPJit}
  begin
    var Words := GetEnvironmentVariable('N64RSPJIT').ToLower;
    RSPJitOff := Words.Contains('off');
    RSPJitModel := Words.Contains('model');
    RSPJitStats := Words.Contains('stats');
    var P := Words.IndexOf('hot');
    if P >= 0 then
    begin
      var N := 0;
      var K := P + 3;
      while (K < Words.Length) and CharInSet(Words.Chars[K], ['0'..'9']) do
      begin
        N := N * 10 + Ord(Words.Chars[K]) - Ord('0');
        Inc(K);
      end;
      RSPJitHot := Min(N, 60000);
    end;
  end;
  {$ENDIF}

end.

