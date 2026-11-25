unit PS2.VU;

// Vector units: the VU core shared by VU0 and VU1 (FMAC upper instructions,
// lower integer/load-store/branch/flag/EFU instructions, Q and P with their
// latencies, MAC/status/clip flags), micro-mode execution of 64-bit
// instruction pairs up to the E bit, VU0 as EE coprocessor 2 (macro mode,
// VCALLMS/VCALLMSR, control registers) and XGKICK to GIF PATH1 from VU1.
// Floats follow the PS2 rules of the FPU (no infinity/NaN, exponent 255 is a
// number, round toward zero, denormals as zero).
// References: VU User's Manual (PS2 Linux Kit), ps2tek.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, Core.Snapshots,
  PS2.Types, PS2.EE.CPU, PS2.VU.Float, HW.JIT, PS2.VU1Domain, PS2.VU.DiamondPlan;

const
  // VU1's straight-line block cap (VU0 keeps 32 in FindBlock). Retained
  // vector values and entry guards are amortized over a longer run.
  PS2VUBlockPairs = 48;
  // An entry is compiled (or its compiled version reused) the second time
  // a run starts a block there: re-uploaded microcode starts cold again.
  PS2VUCompileHeat = 2;
  // Compiled blocks a JIT generation holds at most (their code guards' slots).
  PS2VUMaxBlocks = 16384;
  // Code memory of a core's compiled blocks (VU0, VU1). When it is full all
  // of it is dropped and made again as it is needed: it should hold every
  // block of the programs a game goes through (VU1: tens of MiB in games
  // that upload many).
  PS2VUCodeBytes: array[0..1] of NativeInt = (32 * 1024 * 1024, 64 * 1024 * 1024);

var
  // A blocked VU0 program's known spin loop takes its turns' cycles without
  // running them (TPS2VU0.SpinKnown; tests compare both ways).
  SpinSkips: Boolean = True;
  // XGKICK payload spans at once; tests compare with one quadword at a time.
  PS2VUKickRuns: Boolean = True;

type
  TPS2VFArray = array[0..31] of TPS2Reg128;

  PPS2VFArray = ^TPS2VFArray;

  TPS2VIArray = array[0..31] of Cardinal;

  PPS2VIArray = ^TPS2VIArray;

  // An XGKICK packet as the GIF took it (Data) from VU memory at Address.
  TPS2VUKick = procedure(Address: Cardinal; Data: PByte) of object;

  TPS2VUState = record
    ACC: TPS2Reg128;
    Q, P, I, R: Cardinal;
    Status, MAC, Clip: Cardinal;
    TPC: Cardinal;
    // Pending Q/P results and the pairs until they land.
    PendingQ, PendingP: Cardinal;
    QDelay, PDelay: Integer;
    Running: Boolean;
    // Branch in flight (taken after the next pair) and E bit seen.
    BranchPending, EndPending: Boolean;
    BranchTarget: Cardinal;
    Cycles: Int64;
    // Clip flag as FC* instructions see it: CLIP results land four cycles
    // after issue (FMAC latency); queued until then.
    ClipBase: Cardinal;
    ClipQValue: array[0..3] of Cardinal;
    ClipQReady: array[0..3] of Int64;
    ClipQCount: Integer;
    // MAC and status flags as FM*/FS* instructions see them, the same way.
    MACBase, StatusBase: Cardinal;
    FlagQMAC, FlagQStatus: array[0..3] of Cardinal;
    FlagQReady: array[0..3] of Int64;
    FlagQCount: Integer;
    // A started program runs at once; the VU counts as busy until this EE
    // cycle: its start plus the cycles it took (VUs run at the EE clock).
    BusyUntil: Int64;
  end;

  PPS2VUState = ^TPS2VUState;

  // The VF registers an instruction writes and reads, with field masks.
  TPS2VURegUse = record
    Dest, S1, S2: Integer;
    DestMask, M1, M2: Cardinal;
  end;

  // A pair decoded once: its words (it is decoded again when they differ),
  // the registers its halves read and write (none for the lower half of an
  // I-bit pair) and whether its upper op sets the MAC and status flags.
  TPS2VUPair = record
    Lower, Upper: Cardinal;
    Valid, SetsFlags, NativeCandidate: Boolean;
    // A block was compiled from here since the code memory was last dropped
    // (kept when the pair is decoded again: see TPS2VUCore.Run).
    Entry: Boolean;
    VIWrite: Integer;
    U, L: TPS2VURegUse;
    Native: Pointer;
    Heat: Integer;
    // A scheduled run with flag reads entered here with incoming queues it
    // was not compiled for: those it was compiled for (flag queue offsets
    // in bits 0..3, clip queue's in 4..7; bit 8: noted), for the next.
    QueueHint: Integer;
  end;

  PPS2VUPair = ^TPS2VUPair;

  // Per Run call, shared by interpreted pairs and generated blocks. Nothing
  // here persists across calls or belongs in a save state.
  TPS2VURun = record
    Count, Limit: Integer;
    PC, Target: Cardinal;
    Pair: PPS2VUPair;
    Branching, Ending, Invalid: Boolean;
  end;

  PPS2VURun = ^TPS2VURun;

  // Uploaded programs repeatedly reuse addresses. Retain block versions in
  // the bounded code arena; a hash only selects candidates, all words and
  // the entry address must match before reusing one.
  TPS2VUCompiledBlock = record
    PC: Cardinal;
    PairCount, Next: Integer;
    Words: array[0..PS2VUBlockPairs * 2 - 1] of Cardinal;
    Native, Body: Pointer;
    Hash: UInt64;
  end;

  PPS2VUCompiledBlock = ^TPS2VUCompiledBlock;

  TPS2VUFastPlan = record
    Issue: array[0..PS2VUBlockPairs - 1] of Integer;
    // First external read's issue time and last internal write's issue time.
    ReadAt, WriteAt: array[0..31, 0..3] of Integer;
    WriteAny: array[0..31] of Integer;
  end;

  TPS2VURegionKey = record
    Peer: Pointer;
    Hash: UInt64;
    Target: Cardinal;
    Count: Integer;
  end;

  PPS2VURegionKey = ^TPS2VURegionKey;

  TPS2VURegionPlan = record
    Split, Arm: Integer;
    Target: Cardinal;
    Head, Tail: TPS2VUFastPlan;
    Decoded: array[0..PS2VUBlockPairs - 1] of TPS2VUPair;
  end;

  PPS2VURegionPlan = ^TPS2VURegionPlan;

  // Host-only block cache. Keep optional compilation data out of the VU's
  // live register/queue object; no extra object for cores without regions.
  TPS2VUBlockCache = class(TDictionary<UInt64, Integer>)
  public
    Hints: TDictionary<UInt64, Integer>;
    Regions: TArray<TPS2VURegionKey>;
    RestoredDeadline: Int64;
  end;

  TPS2VUMacroCode = record
    Op: Cardinal;
    Code: Pointer;
  end;

  PPS2VUMacroCode = ^TPS2VUMacroCode;

  TPS2VUFlagEvent = record
    Ready: Int64;
    MAC, Status: Cardinal;
  end;

  // A core between programs, kept to go back to (with the counts
  // measurements read).
  TPS2VUCoreSaved = record
    S: TPS2VUState;
    LoadReg, BranchReg: Integer;
    LoadOld, BranchOld, ClipVisible, JitClip, JitClipSet, JitLazyMAC: Cardinal;
    KickPending: Boolean;
    KickAddress: Cardinal;
    KickStart: Int64;
    KickCount, KickNextTag, KickEnd: Integer;
    KickBuf: TArray<TPS2Reg128>;
    Ready: array[0..31, 0..3] of Int64;
    ReadyAny: array[0..31] of Int64;
    Executed, JitRuns: Int64;
  end;

  TPS2VUCore = class
  private
    FIndex: Integer;
    FVF: PPS2VFArray;
    FVI: PPS2VIArray;
    FCode, FData: PByte;
    FCodeMask, FDataMask: Cardinal;
    FOnKick: TPS2VUKick;
    // A VI register the current pair's integer unit writes and its value
    // before; an unstalled branch in the next pair sees that older value
    // (FBranchReg, FBranchOld). A stall completes the write. -1: none.
    FLoadReg, FBranchReg: Integer;
    FLoadOld, FBranchOld: Cardinal;
    // XGKICK in progress: the GIF takes quadword K of the packet at
    // FKickStart + 2K (VU cycles; FKickStart includes the latency), into
    // FKickBuf; FKickNextTag is the next GIF tag's position, FKickEnd the
    // packet's length once its EOP tag is in (-1 before).
    FKickPending: Boolean;
    FKickAddress: Cardinal;
    FKickStart: Int64;
    FKickDue: Int64; // Next quadword's issue time, derived on restore.
    FKickCount, FKickNextTag, FKickEnd: Integer;
    FKickBuf: array of TPS2Reg128;
    // The clip flag the current pair's FC* instructions see.
    FClipVisible: Cardinal;
    // Cycle from which each VF register field (x..w) holds its pending result.
    FReady: array[0..31, 0..3] of Int64;
    // The latest of a register's four (nothing pending once S.Cycles reaches it).
    FReadyAny: array[0..31] of Int64;
    // Results of the current pair (written after both halves ran).
    FUpperReg, FLowerReg: Integer;
    FUpperValue, FLowerValue: TPS2Reg128;
    FUpperMask, FLowerMask: Cardinal;
    FPairs: array of TPS2VUPair;
    // Entry after the common native prologue, for guarded block chaining.
    FBodies: TArray<Pointer>;
    FBlockMap: TPS2VUBlockCache;
    FBlocks: TArray<TPS2VUCompiledBlock>;
    FBlockCount: Integer;
    FJit: TJitAsm;
    FUseJit: Boolean;
    FJitRuns: Int64;
    FJitBlocks: Int64;
    FJitCompiles, FJitResets, FJitCacheHits: Int64;
    // Temporary operands/results of generated arithmetic (not guest state).
    FJitOperand, FJitProduct: TPS2Reg128;
    FJitFlags, FJitProductFlags: Cardinal;
    // All ones in x, y and z, zero in w (the outer product's operand lanes).
    FLanesXYZ: TPS2Reg128;
    // The register-math routines generated code calls, for the host rounding
    // of the current Run (FMathMode).
    FMath: array[TPS2RegisterMath] of Pointer;
    FMathMode: TRoundingMode;
    // Runs between HoldMath(True) and HoldMath(False) take FMathMode as it is.
    FMathHeld: Integer;
    FJitClip: Cardinal;
    // The value of a scheduled run's last FCSET so far.
    FJitClipSet: Cardinal;
    // Compiled macro operations by opcode (MacroNative; nil: none yet).
    FMacroCode: array[0..1023] of TPS2VUMacroCode;
    FMacroMap: TDictionary<Cardinal, Pointer>;
    FMacroJit: TJitAsm;
    // FMath is for the host rounding the EE keeps while it runs (TPS2VU0).
    FMacroMathKnown: Boolean;
    FJitEvents: array[0..PS2VUBlockPairs - 1] of TPS2VUFlagEvent;
    // CLIP results of a scheduled run (their clip flags and when they land),
    // replayed into the queue by FinishFastFlags; FEmitClipSlot: the one the
    // pair being written makes (-1: not a scheduled run), issued at
    // FEmitClipIssue cycles into it.
    FJitClipEvents: array[0..PS2VUBlockPairs - 1] of record
      Value: Cardinal;
      Ready: Int64;
    end;
    FJitClipCount: Integer;
    FEmitClipSlot, FEmitClipIssue: Integer;
    // The address of the pair a scheduled run is writing (-1: none), which
    // its branches take as a constant.
    FEmitPC: Integer;
    // Where that pair's flag reads find the MAC, status and clip flags they
    // see (offsets in Self; -1: the general path's own fields).
    FEmitMACSrc, FEmitStatusSrc, FEmitClipSrc: Integer;
    // In a scheduled run: the MAC flags of the events nothing reads (their
    // status is not worked out), OR-ed; FEmitLazyFlags: the pair being
    // written makes such an event; FLazyPending: FJitLazyMAC may hold some
    // (see EmitLazyFlush).
    FJitLazyMAC: Cardinal;
    FEmitLazyFlags, FLazyPending: Boolean;
    FJitFastPairs: Int64;
    // Code-generation state only. Volatile vector results survive a lower
    // half only when that half has no helper call and data cannot alias us.
    FVectorMemorySafe, FEmitVectorResult, FAllowVectorResult: Boolean;
    // The pair's lower half wrote its VF result itself (EmitLowerStore).
    FLowerDirect: Boolean;
    // In a scheduled run being written: the VF registers (32: ACC) kept
    // vector registers hold copies of (FKeptReg[slot], FKeptSlot[reg]; -1:
    // none), FKeepCount slots (0: none kept); see KeepStart.
    FKeepCount, FKeepClock: Integer;
    FKeptReg, FKeptUse: array[0..15] of Integer;
    FKeptSlot: array[0..32] of Integer;
    FJitVectorOps: Int64;
    // Scheduled runs compiled to go round again within their code, and the
    // turns taken so (diagnostics).
    FJitSelfLoops, FJitLoopTurns: Int64;
    // Code memory's generation (NoteCodeWritten), and each compiled block's
    // as its code guards last found its pairs there (by block index): a
    // scheduled run compares its words with the code only after a change.
    FCodeGen: Cardinal;
    FBlockGens: TArray<Cardinal>;
    procedure ProfileMark(const Name: string);
    function FindBlock(PC: Cardinal; out Block: TPS2VUCompiledBlock; out Hash: UInt64): Pointer;
    function CachedBlock(PC: Cardinal): Pointer;
    function CompileBlock(PC: Cardinal): Pointer;
    procedure EmitPair(const P: TPS2VUPair);
    function EmitUpper(Op: Cardinal): Boolean;
    function EmitRegisterSelect(Op: Cardinal): Boolean;
    function EmitScalarUpper(Op: Cardinal): Boolean;
    function EmitRegisterUpper(Op: Cardinal): Boolean;
    procedure EmitRegisterFlags(Mask: Cardinal);
    function EmitLower(Op: Cardinal): Boolean;
    procedure EmitLowerStore(Ft: Integer; Mask: Cardinal; const Src: TJitOp; Rotate: Boolean);
    procedure KeepStart(Count: Integer);
    procedure KeepForget(Reg: Integer);
    function KeepSlot(Reg: Integer): Integer;
    function VFOperand(Reg: Integer): TJitOp;
    procedure EmitLoadVF(Dst: TJitVector; Reg: Integer);
    procedure EmitStoreVF(Reg: Integer; Src: TJitVector; Lanes: Byte);
    procedure EmitFlags(Mask: Cardinal);
    procedure EmitStatus;
    procedure EmitMACGroups;
    procedure EmitLazyFlush;
    procedure EmitPrepare(const P: TPS2VUPair);
    procedure EmitFinish(const P: TPS2VUPair);
    procedure EmitCommit(const P: TPS2VUPair);
    procedure EmitVIHistory(const P: TPS2VUPair);
    function PlanFast(const Block: TPS2VUCompiledBlock; out Plan: TPS2VUFastPlan; Pairs: PPS2VUPair = nil): Boolean;
    procedure EmitFast(const Block: TPS2VUCompiledBlock; const Plan: TPS2VUFastPlan; Slow, Stall, Stale, Chain: TJitLabel; Region: PPS2VURegionPlan = nil
    );
    procedure EmitGeneral(PC: Cardinal; Done, Stale: TJitLabel);
    procedure NoteQueues(PC: Cardinal; Queues, BlockIndex: Integer);
    procedure ResetJit;
    function MacroNative(Op: Cardinal): Boolean;
    function MacroCode(Op: Cardinal): Pointer;
    function CompileMacro(Op: Cardinal): Pointer;
    procedure FinishFastFlags(Count: Integer; LastIssue, ClipLast: Int64);
    procedure DrainClip(Cycle: Int64);
    procedure PreparePair(var Run: TPS2VURun); inline;
    procedure FinishPair(var Run: TPS2VURun); inline;
    procedure InterpretPair(var Context: TPS2VURun; PC: Cardinal; Pair: PPS2VUPair);
    function DecodedPair(PC, LowerOp, UpperOp: Cardinal): PPS2VUPair; inline;
    procedure DecodePair(var P: TPS2VUPair; LowerOp, UpperOp: Cardinal);
    procedure UpperRegs(Op: Cardinal; out R: TPS2VURegUse);
    procedure LowerRegs(Op: Cardinal; out R: TPS2VURegUse);
    function ReadyAt(Reg: Integer; Mask: Cardinal): Int64;
    function HazardStall(const P: TPS2VUPair): Integer;
    procedure NoteWrites(const P: TPS2VUPair);
    procedure AdvanceCycles(N: Integer);
    function UpperSetsFlags(Op: Cardinal): Boolean;
    procedure SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
    procedure Upper(Op: Cardinal; Micro: Boolean);
    procedure Lower(Op: Cardinal);
    procedure LowerSpecial(Op: Cardinal);
    procedure CommitVF(Reg: Integer; const V: TPS2Reg128; Dest: Cardinal);
    function DataAddress(Base: Cardinal): PPS2Reg128; inline;
    procedure StartKick(Address: Cardinal);
    procedure TakeKick(All: Boolean);
  public
    S: TPS2VUState;
    // Micro instructions executed (diagnostics).
    Executed: Int64;
    // Counts what may change the state (Reset, Start, Run, Macro, a
    // snapshot): VU0's probes (TPS2VU0) know nothing changed while it stays.
    Touched: UInt64;
    // Diagnostics: the last pairs of a run that hit its limit.
    LoopTrace: array[0..63] of Cardinal;
    // Diagnostics: when assigned, the PC and VI1-15 before each of the first
    // pairs of the current run (16 words per pair).
    RunTrace: TArray<Word>;
    RunTraceCount: Integer;
    // Optional host-profiler symbols for generated code (compile time only).
    JitProfile: TProc<Pointer, string>;
    // Diagnostics: called as RunProgram runs a started program (captures).
    OnRunProgram: TProc;
  private
    // The incoming flag queues a dropped version of a block met (as
    // TPS2VUPair.QueueHint), by the block's hash: for its next version.
    // (The last field: the others stay where they are, see VectorOffsets.)
    FFastGate: NativeUInt;
    // Optional combined-call MADD/MSUB routines for the current rounding.
    // Host-only fields go last, preserving S.ACC's cache-line placement.
    FAccMath: array[Boolean] of Pointer;
    procedure RefreshFastGate; inline;
    function DiamondShape(const Head: TPS2VUCompiledBlock; out Shape: TDiamondPlan): Boolean;
    function EmitDiamond(const Head: TPS2VUCompiledBlock; const HP: TPS2VUFastPlan; const Shape: TDiamondPlan; Regular, Chain: TJitLabel): Boolean;
    function EmitRegion(const Head: TPS2VUCompiledBlock; const HP: TPS2VUFastPlan; Regular, Chain: TJitLabel; Arm: Integer; Decoded: PPS2VUPair): Boolean;
    function RegionPeer(Info: PPS2VURegionKey; Actual: Pointer): NativeUInt;
    function RegionHorizon(Run: PPS2VURun): NativeUInt;
  public
    constructor Create(Index: Integer; VF: PPS2VFArray; VI: PPS2VIArray; Code, Data: PByte; CodeSize, DataSize: Cardinal);
    destructor Destroy; override;
    // Experimental block compiler; the interpreter remains the reference.
    property UseJit: Boolean read FUseJit write FUseJit;
    property JitRuns: Int64 read FJitRuns;
    property JitBlocks: Int64 read FJitBlocks;
    property JitCompiles: Int64 read FJitCompiles;
    property JitResets: Int64 read FJitResets;
    property JitCacheHits: Int64 read FJitCacheHits;
    property JitFastPairs: Int64 read FJitFastPairs;
    property JitVectorOps: Int64 read FJitVectorOps;
    property JitSelfLoops: Int64 read FJitSelfLoops;
    property JitLoopTurns: Int64 read FJitLoopTurns;
    // Code memory was written (by anything but this core: the VIF, the EE,
    // a snapshot, a test). Compiled blocks look at their pairs again.
    procedure NoteCodeWritten; inline;
    // One contiguous span of VIF1 MPG words. False leaves the scalar path
    // responsible for the entire span (including checked overflow).
    function TryUploadMicroWords(Offset: Cardinal; Source: PCardinal; Count: Integer): Boolean;
    // Select the portable generator model before running a differential test.
    procedure CheckMath;
    procedure UseJitModel;
    procedure Reset;
    // A macro instruction (VU0 COP2, bit 25 set): True when it is one.
    function Macro(Op: Cardinal): Boolean;
    // Starts a micro program at Address (in 8-byte units times 8) and runs
    // it to its end (at most MaxPairs pairs; False when it is still running).
    procedure Start(Address: Cardinal);
    function Run(MaxPairs: Integer): Boolean;
    function StraightPairs(StopTPC: Cardinal; Max: Integer): Integer;
    // Many runs under one host rounding (VU0's spin probes): the routines for
    // it chosen once (True), until False.
    procedure HoldMath(Held: Boolean);
    // Runs a started program to its end at EE cycle Now and keeps the VU
    // busy for the cycles it took (Unfinished: still running at the limit).
    procedure RunProgram(Now: Int64; MaxPairs: Integer);
    // The program is running or its busy window has not passed by Now.
    function Busy(Now: Int64): Boolean; inline;
    // Where the vectors generated code loads and stores whole lie in the
    // instance (diagnostics). S.ACC is kept on a 16-byte boundary: the
    // memory manager aligns instances so, and a 16-byte store across two
    // cache lines there cost a tenth of the speed. A field added before it
    // moves it: new fields go last (checked builds stop otherwise).
    function VectorOffsets: string;
    procedure SerializeState(State: TStateArchive);
    // Between programs: the state to go back to, and back to it (code
    // memory, which comes back with it, is looked at again).
    procedure SaveRun(out C: TPS2VUCoreSaved);
    procedure RestoreRun(const C: TPS2VUCoreSaved);
    property VF: PPS2VFArray read FVF;
    property VI: PPS2VIArray read FVI;
    property Data: PByte read FData;
    property Code: PByte read FCode;
    property OnKick: TPS2VUKick read FOnKick write FOnKick;
  end;

  // VU0 as coprocessor 2 of the EE.
  TPS2VU0 = class(TEECop2)
  private
    FCore: TPS2VUCore;
    FVU1: TPS2VUCore;
    FVU1Domain: TPS2VU1Domain;
    FCMSAR1Start: TProc<Cardinal>;
    // The micro program spins waiting for the EE; FBlockVF/FBlockVI are the
    // registers then (it stays blocked while they stay so).
    FBlocked: Boolean;
    FBlockVF: array[0..31] of TPS2Reg128;
    FBlockVI: array[0..15] of Cardinal;
    // The loop it spins in, where Spins' turn came back to the same state
    // without touching memory or anything pending (SpinKnown): the turn's
    // pairs (addresses, then words), their count and cycles, the core's
    // state after it (cycle count aside) and whether it neither reads nor
    // writes a VF register (VF00 aside).
    FSpinValid, FSpinVFFree: Boolean;
    FSpinPairs: Integer;
    FSpinCycles: Int64;
    FSpinState: TPS2VUState;
    FSpinLoadReg, FSpinBranchReg: Integer;
    FSpinLoadOld, FSpinBranchOld: Cardinal;
    FSpinPC: array[0..63] of Cardinal;
    FSpinWords: array[0..127] of Cardinal;
    FSkippedTurns: Int64;
    // The last probe found the known loop with VF as blocked (skipping its
    // turns; VFWritten cleared then), and the core's Touched and Touches
    // then. While neither changed, only VI and the VF registers written
    // since can differ from then (the loop's code aside).
    FProbeKnown: Boolean;
    FProbeTouched, FTouches, FProbeTouches: UInt64;
    procedure NoteProbe;
    function SpinCodeSame: Boolean;
    function KnownProbe: Boolean;
    procedure RunUntilBlocked;
    procedure RunUntilBlockedHeld;
    function Spins: Boolean;
    procedure NoteSpin(Pairs: Integer; const Before: TPS2VUState; LoadReg, BranchReg: Integer; LoadOld, BranchOld: Cardinal);
    function SpinKnown: Boolean;
    procedure SkipSpin(Turns: Integer);
    function Now: Int64; inline;
    function VU1Busy: Boolean;
    procedure ResetVU1;
  public
    // EE time, for the VUs' busy windows (VPU-STAT, CPCOND2).
    Clock: PInt64;
    constructor Create(Code, Data: PByte);
    destructor Destroy; override;
    procedure Reset; override;
    function ReadControl(Index: Integer): Cardinal; override;
    procedure WriteControl(Index: Integer; Value: Cardinal); override;
    function Execute(Op: Cardinal): Boolean; override;
    procedure Interlock; override;
    procedure Sync; override;
    function Condition: Boolean; override;
    procedure SerializeState(State: TStateArchive); override;
    procedure RunStarts; override;
    procedure RunEnds; override;
    function MacroRoutine(Op: Cardinal; out Target: Pointer; out Running: PBoolean): Pointer; override;
    function RunningFlag: PBoolean; override;
    property Core: TPS2VUCore read FCore;
    // Turns of known spin loops taken without running them (diagnostics).
    property SkippedTurns: Int64 read FSkippedTurns;
    property VU1: TPS2VUCore read FVU1 write FVU1;
    // VU1 belongs to this domain (reached inside it).
    property VU1Domain: TPS2VU1Domain read FVU1Domain write FVU1Domain;
    // CTC2 to CMSAR1 starts VU1.
    property OnStartVU1: TProc<Cardinal> read FCMSAR1Start write FCMSAR1Start;
  end;

  // VU1 with its own registers.
  TPS2VU1Saved = record
    VF: TPS2VFArray;
    VI: TPS2VIArray;
    Core: TPS2VUCoreSaved;
  end;

  TPS2VU1 = class
  private
    FVF: TPS2VFArray;
    FVI: TPS2VIArray;
    FCore: TPS2VUCore;
  public
    constructor Create(Code, Data: PByte);
    destructor Destroy; override;
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    procedure SaveDomain(out C: TPS2VU1Saved);
    procedure RestoreDomain(const C: TPS2VU1Saved);
    property Core: TPS2VUCore read FCore;
  end;

const
  VURegionEnabled = True;

implementation

uses
  HW.HostFPU;

const
  // dest bits: x = 8, y = 4, z = 2, w = 1 (instruction bits 24..21).
  DestX = 8;
  DestY = 4;
  DestZ = 2;
  DestW = 1;
  // VU cycles from an XGKICK to the GIF's first read of the packet: a store
  // to the packet in the next two pairs goes out with it, one in the third
  // pair does not.
  KickLatency = 3;

var
  // Four independent MAC nibbles reduced to the status Z/S/U/O bits. Kept
  // outside guest state; every possible 16-bit MAC value has an exact entry.
  MACGroups: array[0..65535] of Byte;

function FieldBit(K: Integer): Cardinal; inline;
begin
  // Field index 0..3 (x..w) to its dest bit.
  Result := Cardinal(8) shr K;
end;

// Operations with no callback and no read of the delayed flag queues.
// Boundaries (flag reads, division, EFU and XGKICK) retain the fully guarded
// per-pair path.
function FastPair(Lower, Upper: Cardinal): Boolean;
begin
  // (CLIP queues its flags as FMAC operations do: a scheduled run replays
  // them, FinishFastFlags.)
  // (Flag reads and FCSET but FSSET too: a scheduled run tracks the queues
  // they read, see TPS2VUQueueSim.)
  if (Upper and $80000000) <> 0 then
    Exit(True);
  if (Lower and $80000000) = 0 then
    Exit((Lower shr 25) in [$00, $01, $04, $05, $08, $09, $10..$14, $16..$18, $1A..$1C, $20, $21, $24, $25,
        $28, $29, $2C..$2F]);
  // (DIV/SQRT/RSQRT, WAITQ, the EFU ops and WAITP too: a scheduled run
  // follows Q and P through it.)
  if (Lower and $3F) < $3C then
    Exit((Lower and $3F) in [$30, $31, $32, $34, $35]);
  Result := (((Lower shr 4) and $7C) or (Lower and 3)) in
    [$30, $31, $34..$43, $64, $68, $69, $70..$7E];
end;

// A pair whose lower op is DIV, SQRT or RSQRT (its upper one as FastPair
// allows): a scheduled run may end with one (EmitFast lands the older Q
// first and leaves the new one pending).
function QPair(Lower, Upper: Cardinal): Boolean;
begin
  Result := ((Upper and $80000000) = 0) and ((Lower and $8000003C) = $8000003C) and
    ((((Lower shr 4) and $7C) or (Lower and 3)) in [$38..$3A]) and FastPair(0, Upper) and
    ((Upper and $40000000) = 0);
end;

// A pair a known spin loop may hold (TPS2VU0.SpinKnown): none touching
// memory or the VIF, ending the program or breaking. VFFree goes False for
// one that may read or write a VF register but VF00 (anything but an upper
// NOP and a lower integer, branch or flag op or an empty MOVE/MR32).
function SpinPair(Lower, Upper: Cardinal; var VFFree: Boolean): Boolean;
begin
  if (Upper and $78000000) <> 0 then
    Exit(False);
  if (Upper and $7FFFFFF) <> $2FF then
    VFFree := False;
  if (Upper and $80000000) <> 0 then
    Exit(True);
  if (Lower and $80000000) = 0 then
    Exit((Lower shr 25) in [$08, $09, $10..$18, $1A..$1C, $20, $21, $24, $25, $28, $29, $2C..$2F]);
  if (Lower and $3F) < $3C then
    Exit((Lower and $3F) in [$30, $31, $32, $34, $35]);
  case ((Lower shr 4) and $7C) or (Lower and 3) of
    $30, $31:
      if ((Lower shr 21) and $F) <> 0 then
        VFFree := False;
    $38..$3D, $40..$43, $64, $70..$7E:
      VFFree := False;
  else
    Exit(False);
  end;
  Result := True;
end;

function VectorLowerNoCall(Lower, Upper: Cardinal): Boolean;
begin
  if Upper and $80000000 <> 0 then
    Exit(True);
  if Lower and $80000000 = 0 then
    Exit((Lower shr 25) in [$00, $01, $04, $05, $08, $09, $10..$13, $1C,
        $20, $21, $24, $25, $28, $29, $2C..$2F]);
  if Lower and $3F < $3C then
    Exit((Lower and $3F) in [$30, $31, $32, $34, $35]);
  Result := (((Lower shr 4) and $7C) or (Lower and 3)) in
    [$30, $31, $34..$37, $3C..$3F, $64, $68, $69];
end;

function SeparateBuffers(A: Pointer; ASize: NativeUInt; B: Pointer; BSize: NativeUInt): Boolean;
begin
  Result := (NativeUInt(A) + ASize <= NativeUInt(B)) or (NativeUInt(B) + BSize <= NativeUInt(A));
end;

function VIWritten(Lower, Upper: Cardinal): Integer;
begin
  Result := -1;
  if (Upper and $80000000) <> 0 then
    Exit;
  if (Lower and $80000000) = 0 then
  begin
    if (Lower shr 25) in [$04, $08, $09] then
      Result := Integer((Lower shr 16) and 15);
  end
  else
    case Lower and $3F of
      $30, $31, $34, $35:
        Result := Integer((Lower shr 6) and 15);
      $32:
        Result := Integer((Lower shr 16) and 15);
      $3C..$3F:
        case ((Lower shr 4) and $7C) or (Lower and 3) of
          $3C, $3E, $35, $37:
            Result := Integer((Lower shr 16) and 15);
          $34, $36:
            Result := Integer((Lower shr 11) and 15);
        end;
    end;
  if Result = 0 then
    Result := -1;
end;

{ TPS2VUCore }

constructor TPS2VUCore.Create(Index: Integer; VF: PPS2VFArray; VI: PPS2VIArray; Code, Data: PByte; CodeSize, DataSize: Cardinal);
begin
  inherited Create;
  FIndex := Index;
  FLanesXYZ.UW[0] := $FFFFFFFF;
  FLanesXYZ.UW[1] := $FFFFFFFF;
  FLanesXYZ.UW[2] := $FFFFFFFF;
  FLanesXYZ.UW[3] := 0;
  FVF := VF;
  FVI := VI;
  FCode := Code;
  FData := Data;
  FCodeMask := CodeSize - 1;
  FDataMask := DataSize - 1;
  FEmitClipSlot := -1;
  FEmitPC := -1;
  FEmitMACSrc := -1;
  FEmitStatusSrc := -1;
  FEmitClipSrc := -1;
  KeepStart(0);
  FVectorMemorySafe :=
    SeparateBuffers(Data, DataSize, Code, CodeSize)
    and SeparateBuffers(Data, DataSize, VF, SizeOf(TPS2VFArray))
    and SeparateBuffers(Data, DataSize, VI, SizeOf(TPS2VIArray))
    and SeparateBuffers(Data, DataSize, Self, NativeUInt(InstanceSize))
    and SeparateBuffers(VF, SizeOf(TPS2VFArray), VI, SizeOf(TPS2VIArray))
    and SeparateBuffers(VF, SizeOf(TPS2VFArray), Code, CodeSize)
    and SeparateBuffers(VI, SizeOf(TPS2VIArray), Code, CodeSize)
    and SeparateBuffers(VF, SizeOf(TPS2VFArray), Self, NativeUInt(InstanceSize))
    and SeparateBuffers(VI, SizeOf(TPS2VIArray), Self, NativeUInt(InstanceSize))
    and SeparateBuffers(Code, CodeSize, Self, NativeUInt(InstanceSize));
  SetLength(FPairs, CodeSize div 8);
  SetLength(FBodies, CodeSize div 8);
{$IFDEF PS2_CHECKED}
  if ((NativeUInt(@S.ACC) - NativeUInt(Self)) and 15) <> 0 then
    raise Exception.Create('VU core: S.ACC is not on a 16-byte boundary of the instance (' + VectorOffsets + ')');
{$ENDIF}
  FBlockMap := TPS2VUBlockCache.Create;
  FBlockMap.Hints := TDictionary<UInt64, Integer>.Create;
  Reset;
end;

destructor TPS2VUCore.Destroy;
begin
  FJit.Free;
  if FBlockMap <> nil then
    FBlockMap.Hints.Free;
  FBlockMap.Free;
  FMacroMap.Free;
  FMacroJit.Free;
  inherited;
end;

procedure TPS2VUCore.UseJitModel;
begin
  FreeAndNil(FJit);
  FBlockMap.Clear;
  FBlockMap.Hints.Clear;
  FBlockCount := 0;
  for var K := 0 to High(FPairs) do
  begin
    FPairs[K].Native := nil;
    FPairs[K].Heat := 0;
    FPairs[K].Entry := False;
    FBodies[K] := nil;
  end;
  if VURegionEnabled and (FIndex = 1) and FVectorMemorySafe then
  begin
    FJit := CreateJitModel(64 * 1024 * 1024);
    FJit.ReserveAuxiliary(32 * 1024 * 1024);
  end
  else
    FJit := CreateJitModel(32 * 1024 * 1024);
  FUseJit := True;
end;

// All generated code dropped (none is running here). Re-uploaded
// microprograms may replace every pair, so the cache is bounded rather than
// retaining old code.
procedure TPS2VUCore.NoteCodeWritten;
begin
  Inc(FCodeGen);
end;

function TPS2VUCore.TryUploadMicroWords(Offset: Cardinal; Source: PCardinal; Count: Integer): Boolean;
begin
  Result := False;
  if (FIndex <> 1)
    or (FCodeMask <> $3FFF)
    or (FCode = nil)
    or (Source = nil)
    or ((Offset and 3) <> 0)
    or (Offset > FCodeMask)
    or (Count <= 0) then
    Exit;
  if (Cardinal(Count) > (FCodeMask + 1 - Offset) div 4) or (FCodeGen > High(Cardinal) - Cardinal(Count)) then
    Exit;
  var Bytes := NativeUInt(Count) * SizeOf(Cardinal);
  if (NativeUInt(Source) > High(NativeUInt) - Bytes) or (NativeUInt(FCode) > High(NativeUInt) - FCodeMask - 1) then
    Exit;
  // A synthetic input can read earlier code writes or the changing code
  // generation. Keep word-by-word order for all such sources/destinations.
  if not SeparateBuffers(Source, Bytes, FCode, FCodeMask + 1)
    or not SeparateBuffers(Source, Bytes, Self, NativeUInt(InstanceSize))
    or not SeparateBuffers(FCode, FCodeMask + 1, Self, NativeUInt(InstanceSize)) then
    Exit;
  Move(Source^, (FCode + Offset)^, Bytes);
  Inc(FCodeGen, Cardinal(Count));
  Result := True;
end;

procedure TPS2VUCore.ResetJit;
begin
  Inc(FJitResets);
  FJit.Reset;
  FBlockMap.Clear;
  FBlockMap.Hints.Clear;
  FBlockCount := 0;
  for var K := 0 to High(FPairs) do
  begin
    FPairs[K].Native := nil;
    FPairs[K].Entry := False;
    FBodies[K] := nil;
  end;
end;

// A COP2 macro arithmetic operation (Upper's register arithmetic: ADD,
// SUB, MUL, MADD, MSUB and their broadcast, Q, I and ACC forms) as generated
// code of its own (FMacroJit, never dropped: the EE's code calls it too),
// made once per opcode: the operands, the routines for the host rounding
// (FMath, which must be for it), the MAC/status flags and the masked write,
// as Macro does them. The code takes the core as its first argument. nil:
// not such an operation, or no room or generated code here.
function TPS2VUCore.MacroCode(Op: Cardinal): Pointer;
const
  // A slot's code for an opcode left to Macro's own path.
  Interpreted = Pointer(1);
begin
  var Slot: PPS2VUMacroCode := @FMacroCode[Cardinal(UInt64(Op) * $9E3779B1) shr 22];
  if (Slot.Op <> Op) or (Slot.Code = nil) then
  begin
    // (The table caches the dictionary: each opcode is compiled once.)
    if FMacroMap = nil then
      FMacroMap := TDictionary<Cardinal, Pointer>.Create;
    var Code: Pointer;
    if not FMacroMap.TryGetValue(Op, Code) then
    begin
      Code := Interpreted;
      var F := Op and $3F;
      if F >= $3C then
        F := ((Op shr 4) and $7C) or (Op and 3);
      // (EmitRegisterUpper's operations.)
      if FVectorMemorySafe and (PS2RegisterMathNative(vrmAdd) <> nil) and
        ((F <= $0F) or ((F >= $18) and (F <= $1C)) or (F in [$1E, $20..$2A, $2C, $2D])) then
      begin
        if FMacroJit = nil then
          FMacroJit := CreateJitAsm(1024 * 1024);
        if (FMacroJit <> nil) and FMacroJit.HasVectors and FMacroJit.Room(4096) then
          Code := CompileMacro(Op);
      end;
      FMacroMap.Add(Op, Code);
    end;
    Slot.Op := Op;
    Slot.Code := Code;
  end;
  Result := Slot.Code;
  if Result = Interpreted then
    Result := nil;
end;

function TPS2VUCore.MacroNative(Op: Cardinal): Boolean;
begin
  var Code := MacroCode(Op);
  if Code = nil then
    Exit(False);
  if not FMacroMathKnown then
    CheckMath;
  FMacroJit.Invoke(Code, NativeUInt(Self), 0, 0, 0);
  Result := True;
end;

function TPS2VUCore.CompileMacro(Op: Cardinal): Pointer;
begin
  // (The emitters write into FJit.)
  var Saved := FJit;
  FJit := FMacroJit;
  try
    var J := FJit;
    // The register written: fd, or ACC for the ACC forms.
    var Reg := Integer((Op shr 6) and 31);
    if (Op and $3F) >= $3C then
      Reg := 32;
    var Lanes: Byte := 0;
    for var K := 0 to 3 do
      if ((Op shr 21) and FieldBit(K)) <> 0 then
        Lanes := Lanes or (Byte(1) shl K);
    J.ForgetLabels;
    J.Align(16);
    Result := J.Here;
    J.Enter;
    J.Move(jw64, JS0, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
    FAllowVectorResult := True;
    if not EmitRegisterUpper(Op) then
      raise EInvalidOpException.Create('VU macro: no register arithmetic');
    if Reg = 32 then
      J.VectorStore(JMem(jrSelf, Integer(NativeInt(@S.ACC) - NativeInt(Self))), jv0, Lanes)
    else if Reg > 0 then
      J.VectorStore(JMem(jrS0, Reg * 16), jv0, Lanes);
    J.Leave(JImm(0));
    J.ForgetLabels;
    J.Flush;
  finally
    FJit := Saved;
  end;
end;
// A scheduled run with flag reads at PC found incoming queues it was not
// compiled for: its version is dropped, to be compiled again for those as
// well as Queues (once: then it takes the general path, see EmitFast).

procedure TPS2VUCore.NoteQueues(PC: Cardinal; Queues, BlockIndex: Integer);
begin
  FPairs[(PC and FCodeMask) shr 3].QueueHint := Queues or $100;
  if (BlockIndex >= 0) and (BlockIndex < FBlockCount) and (FBlocks[BlockIndex].PC = PC) then
  begin
    // (For the block's words too: the pair's hint goes when another program
    // is uploaded here before the block is compiled again.)
    FBlockMap.Hints.AddOrSetValue(FBlocks[BlockIndex].Hash, Queues or $100);
    FBlocks[BlockIndex].PC := Cardinal(-1);
  end;
end;

// One pair the general way, at PC (in the block being compiled).
procedure TPS2VUCore.EmitGeneral(PC: Cardinal; Done, Stale: TJitLabel);
begin
  var J := FJit;
  ProfileMark('guards');
  var LowerOp := PCardinal(FCode + PC)^;
  var UpperOp := PCardinal(FCode + PC + 4)^;
  var P := DecodedPair(PC, LowerOp, UpperOp);
  // Guard every pair, not just the block entry. A callback can replace
  // code while a block is running, and a small budget may end anywhere.
  J.Move(jw8, JT0, JMem(jrSelf, Integer(NativeInt(@S.Running) - NativeInt(Self))));
  J.Branch(jcEq, jw32, JT0, JImm(0), Done);
  J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count))));
  J.Branch(jcGe, jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit))), Done);
  J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.TPC) - NativeInt(Self))));
  J.Alu(jaAnd, jw32, JT0, JImm(FCodeMask));
  J.Branch(jcNe, jw32, JT0, JImm(PC), Done);
  J.Move(jw64, JT0, JMem(jrSelf, Integer(NativeInt(@FCode) - NativeInt(Self))));
  J.Branch(jcNe, jw32, JMem(jrT0, Integer(PC)), JImm(LowerOp), Stale);
  J.Branch(jcNe, jw32, JMem(jrT0, Integer(PC + 4)), JImm(UpperOp), Stale);
  J.Move(jw64, JT1, JImm(NativeInt(P)));
  // Another block may have decoded this address since this one was
  // compiled. Its cached hazard/flag metadata must agree as well.
  J.Branch(jcNe, jw32, JMem(jrT1, Integer(NativeUInt(@PPS2VUPair(nil).Lower))), JImm(LowerOp), Stale);
  J.Branch(jcNe, jw32, JMem(jrT1, Integer(NativeUInt(@PPS2VUPair(nil).Upper))), JImm(UpperOp), Stale);
  J.Move(jw32, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))), JImm(PC));
  J.Move(jw64, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Pair))), JT1);
  ProfileMark('prepare');
  EmitPrepare(P^);
  EmitPair(P^);
  EmitFinish(P^);
end;

// The block starting at PC as the code memory has it now (its pairs, their
// hash with the address) and the version compiled for exactly that which is
// kept (nil: none).
function TPS2VUCore.FindBlock(PC: Cardinal; out Block: TPS2VUCompiledBlock; out Hash: UInt64): Pointer;
begin
  Result := nil;
  Block := Default(TPS2VUCompiledBlock);
  Block.PC := PC;
  Hash := UInt64(PC);
  var Address := PC;
  var EndAfterPair := False;
  var PairLimit := PS2VUBlockPairs;
  if FIndex = 0 then
    PairLimit := 32;
  for var K := 0 to PairLimit - 1 do
  begin
    var Lo := PCardinal(FCode + Address)^;
    var Hi := PCardinal(FCode + Address + 4)^;
    // (A DIV/SQRT/RSQRT pair may end it, see QPair.)
    var QLast := (K > 0) and not EndAfterPair and not FastPair(Lo, Hi) and QPair(Lo, Hi);
    if (K > 0) and not EndAfterPair and not FastPair(Lo, Hi) and not QLast then
      Break;
    Block.Words[K * 2] := Lo;
    Block.Words[K * 2 + 1] := Hi;
    Inc(Block.PairCount);
    Hash := ((Hash shl 7) or (Hash shr 57)) xor Lo;
    Hash := ((Hash shl 11) or (Hash shr 53)) xor Hi;
    // Cached native guards also consult the decoded metadata. Refresh it
    // on a version hit exactly as a fresh compilation would.
    DecodedPair(Address, Lo, Hi);
    if EndAfterPair or QLast then
      Break;
    EndAfterPair := (Hi and $40000000) <> 0;
    if (Hi and $80000000) = 0 then
      EndAfterPair := EndAfterPair or ((Lo shr 25) in [$20, $21, $24, $25, $28, $29, $2C..$2F]);
    if (K = 0) and not EndAfterPair and not FastPair(Lo, Hi) then
      Break;
    Address := (Address + 8) and FCodeMask;
  end;
  var Version: Integer;
  if FBlockMap.TryGetValue(Hash, Version) then
    while Version >= 0 do
    begin
      var Cached: PPS2VUCompiledBlock := @FBlocks[Version];
      if (Cached.PC = PC)
        and (Cached.PairCount = Block.PairCount)
        and CompareMem(@Cached.Words, @Block.Words, Block.PairCount * 8) then
      begin
        FBodies[PC shr 3] := Cached.Body;
        Inc(FJitCacheHits);
        Exit(Cached.Native);
      end;
      Version := Cached.Next;
    end;
end;

// (Apart from Run: its frame stays small.)
function TPS2VUCore.CachedBlock(PC: Cardinal): Pointer;
begin
  var Block: TPS2VUCompiledBlock;
  var Hash: UInt64;
  Result := FindBlock(PC, Block, Hash);
end;

// Admit an edge only when the ordinary first block ends in a conditional
// branch whose sources are not written in its prefix. The observed image
// suggests a trace; the live predicate and both code ranges guard execution.
function TPS2VUCore.DiamondShape(const Head: TPS2VUCompiledBlock; out Shape: TDiamondPlan): Boolean;
begin
  Result := False;
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  if (Head.PairCount < 5)
    or (Head.PairCount > DiamondPairLimit - 4)
    or (Head.Words[2 * (Head.PairCount - 2)] shr 25 <> $2D)
    or (Head.PC > FCodeMask + 1 - DiamondPairLimit * 8) then
    Exit;
  var Window: array[0..DiamondPairLimit * 2 - 1] of Cardinal;
  Move((FCode + Head.PC)^, Window, SizeOf(Window));
  Result := TryPlanDiamond(Window, Shape) and (Shape.SignBranch + 2 = Head.PairCount);
{$ENDIF}
end;

// A normal scheduled head retires the load, first branch and its delay
// slot. The sign chooses a scheduled mid+tail from its actual live TPC.
function TPS2VUCore.EmitDiamond(const Head: TPS2VUCompiledBlock; const HP: TPS2VUFastPlan; const Shape: TDiamondPlan; Regular, Chain: TJitLabel): Boolean;
var
  Mid: TPS2VUCompiledBlock;
  MD: array[0..PS2VUBlockPairs - 1] of TPS2VUPair;
  MP: TPS2VUFastPlan;
begin
  var J := FJit;
  var Select := J.NewLabel;
  var Negative := J.NewLabel;
  var Positive := J.NewLabel;
  EmitFast(Head, HP, Regular, Regular, Regular, Select);
  J.Bind(Select);
  J.Branch(jcNe, jw32, JMem(jrS3, 0), JImm(0), Chain);
  J.Move(jw32, JT0, JMem(jrS3, Shape.SelectorVI * 4));
  J.Shift(jsShl, jw32, jrT0, 16);
  J.Branch(jcLt, jw32, JT0, JImm(0), Negative);
  J.Branch(jcGt, jw32, JT0, JImm(0), Positive);
  Result := False;
  for var Arm := 0 to 2 do
  begin
    if Arm = 1 then
      J.Bind(Negative)
    else if Arm = 2 then
      J.Bind(Positive);
    var Start := Shape.SignBranch + 2 + Ord(Arm = 2);
    Mid := Default(TPS2VUCompiledBlock);
    Mid.PC := Head.PC + Cardinal(Start * 8);
    Mid.PairCount := Shape.NonzeroBranch + 2 - Start;
    Mid.Hash := Mid.PC;
    for var K := 0 to Mid.PairCount - 1 do
    begin
      var AtPC := Mid.PC + Cardinal(K * 8);
      var Lo := PCardinal(FCode + AtPC)^;
      var Hi := PCardinal(FCode + AtPC + 4)^;
      Mid.Words[2 * K] := Lo;
      Mid.Words[2 * K + 1] := Hi;
      Mid.Hash := ((Mid.Hash shl 7) or (Mid.Hash shr 57)) xor Lo;
      Mid.Hash := ((Mid.Hash shl 11) or (Mid.Hash shr 53)) xor Hi;
      MD[K] := Default(TPS2VUPair);
      DecodePair(MD[K], Lo, Hi);
    end;
    if PlanFast(Mid, MP, @MD[0]) and EmitRegion(Mid, MP, Chain, Chain, Arm, @MD[0]) then
      Result := True;
    J.Jump(Chain);
  end;
end;

function TPS2VUCore.EmitRegion(const Head: TPS2VUCompiledBlock; const HP: TPS2VUFastPlan; Regular, Chain: TJitLabel; Arm: Integer; Decoded: PPS2VUPair): Boolean;
var
  T: TPS2VURegionPlan;
  All, Tail: TPS2VUCompiledBlock;
  Joint: TPS2VUFastPlan;

  function Plain(Lo, Hi: Cardinal): Boolean;
  begin
    Result :=
      FastPair(Lo, Hi)
      and not (((Hi and $3F) >= $3C) and ((((Hi shr 4) and $7C) or (Hi and 3)) = $1F))
      and (((Hi and $80000000) <> 0) or not ((Lo shr 25) in [$10..$1C]));
  end;

  function IsBranch(Lo, Hi: Cardinal): Boolean;
  begin
    Result := ((Hi and $80000000) = 0) and ((Lo shr 25) in [$20, $21, $24, $25, $28, $29, $2C..$2F]);
  end;

begin
  Result := False;
  if not VURegionEnabled
    or (FIndex <> 1)
    or not FVectorMemorySafe
    or (Head.PairCount < 4)
    or (Head.PairCount > PS2VUBlockPairs - 4)
    or (UInt64(Head.PC) + Cardinal(Head.PairCount * 8) > UInt64(FCodeMask) + 1) then
    Exit;
  var Last := Head.PairCount - 2;
  var Branch := Head.Words[2 * Last];
  var Group := Branch shr 25;
  if not IsBranch(Branch, Head.Words[2 * Last + 1]) or not (Group in [$28, $29, $2C..$2F]) then
    Exit;
  var A := Integer((Branch shr 11) and 15);
  var B := Integer((Branch shr 16) and 15);
  if (Group <> $29) or (B <> 0) then
    Exit;
  T.Arm := Arm;
  All := Head;
  for var I := 0 to Head.PairCount - 1 do
  begin
    var L := Head.Words[2 * I];
    var H := Head.Words[2 * I + 1];
    if not Plain(L, H) or ((H and $40000000) <> 0) or ((I <> Last) and IsBranch(L, H)) then
      Exit;
    if I < Last then
    begin
      var W := VIWritten(L, H);
      if ((H and $80000000) = 0)
        and ((L and $8000003C) = $8000003C)
        and ((((L shr 4) and $7C) or (L and 3)) in [$68, $69]) then
        W := Integer((L shr 16) and 15);
      if (W > 0) and ((W = A) or ((Group in [$28, $29]) and (W = B))) then
        Exit;
    end;
    T.Decoded[I] := Decoded[I];
  end;
  var Imm := Integer(Branch and $7FF);
  if Imm >= $400 then
    Dec(Imm, $800);
  var Target := Cardinal(Integer(Head.PC) + 8 * (Last + 1 + Imm)) and FCodeMask;
  var HeadEnd := Head.PC + Cardinal(Head.PairCount * 8);
  if Target = (HeadEnd and FCodeMask) then
    Exit;
  if Arm = 0 then
    Target := HeadEnd and FCodeMask;
  T.Split := Head.PairCount;
  T.Target := Target;
  T.Head := HP;
  Tail := Default(TPS2VUCompiledBlock);
  Tail.PC := Target;
  var Ends := False;
  var Complete := False;
  var TailHash := UInt64(Target);
  for var I := 0 to PS2VUBlockPairs - Head.PairCount - 1 do
  begin
    var PC := Target + Cardinal(I * 8);
    if (PC > FCodeMask - 7) or ((PC >= Head.PC) and (PC < HeadEnd)) then
      Exit;
    var L := PCardinal(FCode + PC)^;
    var H := PCardinal(FCode + PC + 4)^;
    if not Plain(L, H) then
      Exit;
    if Ends and IsBranch(L, H) then
      Exit;
    Tail.Words[2 * I] := L;
    Tail.Words[2 * I + 1] := H;
    Inc(Tail.PairCount);
    TailHash := ((TailHash shl 7) or (TailHash shr 57)) xor L;
    TailHash := ((TailHash shl 11) or (TailHash shr 53)) xor H;
    var N := T.Split + I;
    All.Words[2 * N] := L;
    All.Words[2 * N + 1] := H;
    T.Decoded[N] := Default(TPS2VUPair);
    DecodePair(T.Decoded[N], L, H);
    if Ends then
    begin
      Complete := True;
      Break;
    end;
    Ends := IsBranch(L, H) or ((H and $40000000) <> 0);
  end;
  if not Complete or (Tail.PairCount < 4) then
    Exit;
  Inc(All.PairCount, Tail.PairCount);
  if not PlanFast(Tail, T.Tail, @T.Decoded[T.Split]) or not PlanFast(All, Joint, @T.Decoded[0]) then
    Exit;
  var HeadClocks := HP.Issue[T.Split - 1] + 1;
  for var I := 0 to Tail.PairCount - 1 do
    if Joint.Issue[T.Split + I] <> HeadClocks + T.Tail.Issue[I] then
      Exit;
  // A complete fast+fast trace needs a compatible live tail and the ordinary
  // root/exit history. This prototype leaves congested code arenas alone.
  if Length(FBlockMap.Regions) = 0 then
    SetLength(FBlockMap.Regions, PS2VUMaxBlocks * 6);
  var Info: PPS2VURegionKey := @FBlockMap.Regions[FBlockCount * 6 + 2 * Arm];
  var MidInfo: PPS2VURegionKey := @FBlockMap.Regions[FBlockCount * 6 + 2 * Arm + 1];
  MidInfo.Peer := nil;
  MidInfo.Target := Head.PC;
  MidInfo.Count := Head.PairCount;
  MidInfo.Hash := Head.Hash;
  Info.Peer := nil;
  Info.Target := Target;
  Info.Count := Tail.PairCount;
  Info.Hash := TailHash;
  var J := FJit;
  // No handoff, trace-window write, exceptional float exit or partial
  // budget may expose the eliminated boundary. All declines precede effects.
  J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count))));
  J.Alu(jaAdd, jw64, JT0, JImm(All.PairCount + 64));
  J.Move(jw32, JT1, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit))));
  J.Branch(jcAbove, jw64, JT0, JT1, Regular);
  J.Branch(jcNe, jw8, JMem(jrSelf, Integer(NativeInt(@FKickPending) - NativeInt(Self))), JImm(0), Regular);
  J.Branch(jcNe, jw32, JMem(jrSelf, Integer(NativeInt(@FJitLazyMAC) - NativeInt(Self))), JImm(0), Regular);
  // The earlier head actually retired, including the first delayed branch.
  // Validate just the successor dependencies that can still stall at its
  // own entry. All normal writes in the mid are already in the joint plan.
  J.Call(@TPS2VUCore.RegionHorizon, [JSelf, JCtx]);
  J.Branch(jcEq, jw32, JT0, JImm(0), Regular);
  J.Move(jw64, JT0, JMem(jrSelf, Integer(NativeInt(@S.Cycles) - NativeInt(Self))));
  J.Alu(jaAdd, jw64, JT0, JImm(HeadClocks));
  for var R := 1 to 31 do
    for var K := 0 to 3 do
      if (T.Tail.ReadAt[R, K] >= 0) and (T.Tail.ReadAt[R, K] < 3) then
        J.Branch(jcGt, jw64, JMem(jrSelf, Integer(NativeInt(@FReady[R, K]) - NativeInt(Self))), JT0, Regular);
  // A stale/missing dispatch target must get the same opportunity to
  // decode/compile as on the ordinary path. Rebind only to identical words.
  J.Move(jw64, JT0, JMem(jrSelf, Integer(NativeInt(@FBodies) - NativeInt(Self))));
  J.Move(jw64, JT0, JMem(jrT0, Integer(Head.PC shr 3) * SizeOf(Pointer)));
  J.Branch(jcEq, jw64, JT0, JImm(0), Regular);
  J.Move(jw64, JT1, JImm(NativeInt(MidInfo)));
  var MidBound := J.NewLabel;
  J.Branch(jcEq, jw64, JT0, JMem(jrT1, 0), MidBound);
  J.Call(@TPS2VUCore.RegionPeer, [JSelf, JT1, JT0]);
  J.Branch(jcEq, jw32, JT0, JImm(0), Regular);
  J.Bind(MidBound);
  J.Move(jw64, JT0, JMem(jrSelf, Integer(NativeInt(@FBodies) - NativeInt(Self))));
  J.Move(jw64, JT0, JMem(jrT0, Integer(Target shr 3) * SizeOf(Pointer)));
  J.Branch(jcEq, jw64, JT0, JImm(0), Regular);
  J.Move(jw64, JT1, JImm(NativeInt(Info)));
  var Bound := J.NewLabel;
  J.Branch(jcEq, jw64, JT0, JMem(jrT1, 0), Bound);
  J.Call(@TPS2VUCore.RegionPeer, [JSelf, JT1, JT0]);
  J.Branch(jcEq, jw32, JT0, JImm(0), Regular);
  J.Bind(Bound);

  EmitFast(All, Joint, Regular, Regular, Regular, Chain, @T);
  Result := True;
end;

function TPS2VUCore.RegionPeer(Info: PPS2VURegionKey; Actual: Pointer): NativeUInt;
begin
  Result := 0;
  var I: Integer;
  if FBlockMap.TryGetValue(Info.Hash, I) then
    while I >= 0 do
    begin
      var B: PPS2VUCompiledBlock := @FBlocks[I];
      if (B.PC = Info.Target)
        and (B.PairCount = Info.Count)
        and (B.Body = Actual)
        and CompareMem(@B.Words, FCode + Info.Target, B.PairCount * 8) then
      begin
        Info.Peer := Actual;
        Exit(1);
      end;
      I := B.Next;
    end;
end;

// Ordinary scheduled entries need a full trace or a restored result beyond
// their three-cycle input horizon to take the existing general native path.
procedure TPS2VUCore.RefreshFastGate;
begin
  FFastGate := NativeUInt(Pointer(RunTrace));
  if FBlockMap.RestoredDeadline <> 0 then
  begin
    if S.Cycles < FBlockMap.RestoredDeadline then
      FFastGate := 1
    else
      FBlockMap.RestoredDeadline := 0;
  end;
end;

function TPS2VUCore.RegionHorizon(Run: PPS2VURun): NativeUInt;
begin
  Result := 0;
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  if (S.Cycles < 0) or (Run.Limit < 1) or (S.Cycles > High(Int64) - Int64(Run.Limit) * 4 - 4) then
    Exit;
  if (ReadHostMXCSR and $1F80) = $1F80 then
    Result := 1;
{$ENDIF}
end;

function TPS2VUCore.CompileBlock(PC: Cardinal): Pointer;
begin
  var Block: TPS2VUCompiledBlock;
  var Hash: UInt64;
  Result := FindBlock(PC, Block, Hash);
  if Result <> nil then
    Exit;
  if FJit = nil then
  begin
    var Bytes := PS2VUCodeBytes[FIndex and 1];
    if VURegionEnabled and (FIndex = 1) and FVectorMemorySafe then
    begin
      FJit := CreateJitAsm(Bytes + 32 * 1024 * 1024);
      if FJit <> nil then
        FJit.ReserveAuxiliary(Bytes);
    end
    else
      FJit := CreateJitAsm(Bytes);
  end;
  if FJit = nil then
    Exit;
  if not FJit.Room(PS2VUBlockPairs * 4096) or (FBlockCount >= PS2VUMaxBlocks) then
    ResetJit;
  var Hint: Integer;
  if FBlockMap.Hints.TryGetValue(Hash, Hint) then
    FPairs[PC shr 3].QueueHint := Hint;
  var J := FJit;
  Inc(FJitCompiles);
  FEmitPC := -1;
  FEmitMACSrc := -1;
  FEmitStatusSrc := -1;
  FEmitClipSrc := -1;
  J.ForgetLabels;
  J.Align(16);
  Result := J.Here;
  ProfileMark('prologue');
  J.Enter;
  J.Move(jw64, JS0, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
  J.Move(jw64, JS3, JMem(jrSelf, Integer(NativeInt(@FVI) - NativeInt(Self))));
  J.Move(jw64, JS2, JMem(jrSelf, Integer(NativeInt(@FData) - NativeInt(Self))));
  var Done := J.NewLabel;
  var Stale := J.NewLabel;
  var EntryPC := PC;
  var Body := J.Here;
  var Ordinary := J.NewLabel;
  J.Bind(Ordinary);
  var Slow := J.NewLabel;
  var Stall := J.NewLabel;
  var Chain := J.NewLabel;
  var Plan: TPS2VUFastPlan;
  var HasPlan := PlanFast(Block, Plan);
  if HasPlan then
  begin
    EmitFast(Block, Plan, Slow, Stall, Stale, Chain);
    // An input still in the pipeline: the first pair alone the general way
    // (it waits for it, or a later pair does), then on to the successor
    // (scheduled again once ready).
    J.Bind(Stall);
    EmitGeneral(PC, Done, Stale);
    J.Jump(Chain);
  end;
  J.Bind(Slow);
  var Last := False;
  for var K := 0 to Block.PairCount - 1 do
  begin
    var LowerOp := PCardinal(FCode + PC)^;
    var UpperOp := PCardinal(FCode + PC + 4)^;
    EmitGeneral(PC, Done, Stale);
    if Last then
      Break;
    // End after the delay pair of a branch or E-bit pair. Conditional
    // branches return to the dispatcher on either outcome.
    Last := (UpperOp and $40000000) <> 0;
    if (UpperOp and $80000000) = 0 then
      Last := Last or ((LowerOp shr 25) in [$20, $21, $24, $25, $28, $29, $2C..$2F]);
    PC := (PC + 8) and FCodeMask;
  end;
  J.Bind(Chain);
  // Chain to a compiled successor without leaving the common native frame.
  // The successor runs all its running/budget/code guards. Nothing points
  // directly into cached code: invalidation clears this indirection table.
  ProfileMark('chain');
  J.Move(jw8, JT0, JMem(jrSelf, Integer(NativeInt(@FUseJit) - NativeInt(Self))));
  J.Branch(jcEq, jw32, JT0, JImm(0), Done);
  J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.TPC) - NativeInt(Self))));
  // A VU pair and a 64-bit table entry occupy the same number of bytes.
  J.Alu(jaAnd, jw32, JT0, JImm(FCodeMask and not Cardinal(7)));
  if SizeOf(Pointer) = 4 then
    J.Shift(jsShr, jw32, jrT0, 1);
  J.Move(jw64, JT1, JMem(jrSelf, Integer(NativeInt(@FBodies) - NativeInt(Self))));
  J.Alu(jaAdd, jw64, JT1, JT0);
  J.Move(jw64, JT0, JMem(jrT1, 0));
  J.Branch(jcEq, jw64, JT0, JImm(0), Done);
  J.JumpIndirect(JT0);
  J.Jump(Done);
  J.Bind(Stale);
  J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Invalid))), JImm(1));
  J.Bind(Done);
  J.Leave(JImm(0));
  var Shape: TDiamondPlan;
  if HasPlan
    and VURegionEnabled
    and (FIndex = 1)
    and FVectorMemorySafe
    and DiamondShape(Block, Shape)
    and J.BeginAuxiliary(PS2VUBlockPairs * 32768) then
  try
    var Extra := J.Here;
    if EmitDiamond(Block, Plan, Shape, Ordinary, Chain) then
      Body := Extra;
  finally
    J.EndAuxiliary;
  end;
  J.ForgetLabels;
  J.Flush;
  FBodies[EntryPC shr 3] := Body;
  FPairs[EntryPC shr 3].Entry := True;
  Block.Hash := Hash;
  Block.Native := Result;
  Block.Body := Body;
  if not FBlockMap.TryGetValue(Hash, Block.Next) then
    Block.Next := -1;
  if FBlockCount >= Length(FBlocks) then
    SetLength(FBlocks, Length(FBlocks) + 256);
  FBlocks[FBlockCount] := Block;
  FBlockMap.AddOrSetValue(Hash, FBlockCount);
  Inc(FBlockCount);
end;

procedure TPS2VUCore.ProfileMark(const Name: string);
begin
  if Assigned(JitProfile) then
    JitProfile(FJit.Here, Name);
end;

function TPS2VUCore.PlanFast(const Block: TPS2VUCompiledBlock; out Plan: TPS2VUFastPlan; Pairs: PPS2VUPair): Boolean;
var
  Cycle: Integer;

  procedure Need(Reg: Integer; Mask: Cardinal);
  begin
    if Reg <= 0 then
      Exit;
    for var K := 0 to 3 do
      if ((Mask and FieldBit(K)) <> 0) and (Plan.WriteAt[Reg, K] >= 0) then
        Cycle := Max(Cycle, Plan.WriteAt[Reg, K] + 4);
  end;

  procedure ReadExternal(Reg: Integer; Mask: Cardinal);
  begin
    if Reg <= 0 then
      Exit;
    for var K := 0 to 3 do
      if ((Mask and FieldBit(K)) <> 0) and (Plan.WriteAt[Reg, K] < 0) then
        if Plan.ReadAt[Reg, K] < 0 then
          Plan.ReadAt[Reg, K] := Cycle;
  end;

  procedure Write(const R: TPS2VURegUse);
  begin
    if (R.Dest <= 0) or (R.DestMask = 0) then
      Exit;
    for var K := 0 to 3 do
      if (R.DestMask and FieldBit(K)) <> 0 then
        Plan.WriteAt[R.Dest, K] := Cycle;
    Plan.WriteAny[R.Dest] := Cycle;
  end;

begin
  Result := False;
  // (Two pairs at least: a branch and its delay slot, or the E bit's.)
  if Block.PairCount < 2 then
    Exit;
  // The hardware has separate code and data RAM. Preserve per-pair code
  // guards for synthetic callers that deliberately alias the two buffers.
  if (NativeUInt(FData) < NativeUInt(FCode) + FCodeMask + 1)
    and (NativeUInt(FCode) < NativeUInt(FData) + FDataMask + 1) then
    Exit;
  FillChar(Plan, SizeOf(Plan), $FF);
  Cycle := 0;
  var PC := Block.PC;
  for var I := 0 to Block.PairCount - 1 do
  begin
    if not FastPair(Block.Words[I * 2], Block.Words[I * 2 + 1])
      and not ((I = Block.PairCount - 1) and QPair(Block.Words[I * 2], Block.Words[I * 2 + 1])) then
      Exit;
    var P: PPS2VUPair := @FPairs[PC shr 3];
    if Pairs <> nil then
      P := Pairs + I;
    Need(P.U.S1, P.U.M1);
    Need(P.U.S2, P.U.M2);
    Need(P.L.S1, P.L.M1);
    Need(P.L.S2, P.L.M2);
    ReadExternal(P.U.S1, P.U.M1);
    ReadExternal(P.U.S2, P.U.M2);
    ReadExternal(P.L.S1, P.L.M1);
    ReadExternal(P.L.S2, P.L.M2);
    Plan.Issue[I] := Cycle;
    Write(P.U);
    Write(P.L);
    Inc(Cycle);
    PC := (PC + 8) and FCodeMask;
  end;
  Result := True;
end;

// Reproduce the reference queues at an observable block boundary. No flag
// instruction or callback runs while events are deferred. Keep even unused
// tail slots identical, so snapshots and later interpreter execution agree.
procedure TPS2VUCore.FinishFastFlags(Count: Integer; LastIssue, ClipLast: Int64);

  procedure Drain(Cycle: Int64);
  begin
    while (S.FlagQCount > 0) and (S.FlagQReady[0] <= Cycle) do
    begin
      S.MACBase := S.FlagQMAC[0];
      S.StatusBase := S.FlagQStatus[0];
      for var K := 1 to S.FlagQCount - 1 do
      begin
        S.FlagQMAC[K - 1] := S.FlagQMAC[K];
        S.FlagQStatus[K - 1] := S.FlagQStatus[K];
        S.FlagQReady[K - 1] := S.FlagQReady[K];
      end;
      Dec(S.FlagQCount);
    end;
  end;

begin
  for var I := 0 to Count - 1 do
  begin
    Drain(FJitEvents[I].Ready - 4);
    if S.FlagQCount < 4 then
    begin
      S.FlagQMAC[S.FlagQCount] := FJitEvents[I].MAC;
      S.FlagQStatus[S.FlagQCount] := FJitEvents[I].Status;
      S.FlagQReady[S.FlagQCount] := FJitEvents[I].Ready;
      Inc(S.FlagQCount);
    end;
  end;
  Drain(LastIssue);
  // The run's CLIP results, as each pair drained the clip queue to its issue
  // and then queued its own; then the queue as the last pair left it.
  for var I := 0 to FJitClipCount - 1 do
  begin
    DrainClip(FJitClipEvents[I].Ready - 4);
    if S.ClipQCount < 4 then
    begin
      S.ClipQValue[S.ClipQCount] := FJitClipEvents[I].Value;
      S.ClipQReady[S.ClipQCount] := FJitClipEvents[I].Ready;
      Inc(S.ClipQCount);
    end;
  end;
  FJitClipCount := 0;
  DrainClip(ClipLast);
  FClipVisible := S.ClipBase;
end;

procedure TPS2VUCore.DrainClip(Cycle: Int64);
begin
  while (S.ClipQCount > 0) and (S.ClipQReady[0] <= Cycle) do
  begin
    S.ClipBase := S.ClipQValue[0];
    for var K := 1 to S.ClipQCount - 1 do
    begin
      S.ClipQValue[K - 1] := S.ClipQValue[K];
      S.ClipQReady[K - 1] := S.ClipQReady[K];
    end;
    Dec(S.ClipQCount);
  end;
  FClipVisible := S.ClipBase;
end;

type
  // The flag (or clip) queue through a scheduled run, worked out when it is
  // compiled for an incoming queue of Count0 entries landing Off[K] cycles
  // into the run. What each slot and the base hold: -1 the base as it was
  // (not a slot), K < 4 incoming slot K's entry, EventSym + E the run's event E
  // (landing EvReady[E] cycles in). The run checks the incoming queue is so.
  TPS2VUQueueSim = record
    Valid: Boolean;
    Count0, Count, Base: Integer;
    Off, Slots: array[0..3] of Integer;
    // The base each pair's flag reads see (after its pipeline step).
    Visible: array[0..PS2VUBlockPairs - 1] of Integer;
    EvReady: array[0..PS2VUBlockPairs - 1] of Integer;
  end;

const
  // Queue symbols (TPS2VUQueueSim) of a run's event E, and of FCSET's value.
  EventSym = 64;
  ClipSetSym = 128;

// A scheduled run with no observation inside it. Validate all code and all
// external dependency deadlines before any guest change. Short budgets,
// trace capture, pending branches/ends/kicks and unexpected input latencies
// use the general path. Internal stalls and final ready times are constants.
procedure TPS2VUCore.EmitFast(const Block: TPS2VUCompiledBlock; const Plan: TPS2VUFastPlan; Slow, Stall, Stale, Chain: TJitLabel; Region: PPS2VURegionPlan);
var
  J: TJitAsm;
  EventReady: array[0..PS2VUBlockPairs - 1] of Integer;
  Slots: array[0..3] of Integer;
  EventCount, PrefixCount, LiveCount, BaseEvent: Integer;

  function NextPC(PC: Cardinal; Next: Integer): Cardinal;
  begin
    if (Region <> nil) and (Next = Region.Split) then
      Exit(Region.Target);
    Result := (PC + 8) and FCodeMask;
  end;

  function PairAt(PC: Cardinal; I: Integer): PPS2VUPair;
  begin
    if Region <> nil then
      Exit(@Region.Decoded[I]);
    Result := @FPairs[PC shr 3];
  end;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

  function InputDeadline(Cycle: Integer): TJitOp;
  begin
    case Cycle of
      1:
        Result := JT4;
      2:
        Result := JT5;
    else
      Result := JS1;
    end;
  end;

  function IsClip(Upper: Cardinal): Boolean;
  begin
    Result := ((Upper and $3F) >= $3C) and ((((Upper shr 4) and $7C) or (Upper and 3)) = $1F);
  end;

  // The queue as the general path leaves it after each pair: entries
  // landed by a pair's issue move to the base before it runs; its event
  // (MAC/status, or CLIP) joins the queue after, unless the queue is full.
  procedure Simulate(var Q: TPS2VUQueueSim; Clip: Boolean);
  var
    Ready: array[0..3] of Integer;
  begin
    for var K := 0 to 3 do
    begin
      Q.Slots[K] := K;
      Ready[K] := Q.Off[K];
    end;
    Q.Base := -1;
    Q.Count := Q.Count0;
    var E := 0;
    var PC := Block.PC;
    for var I := 0 to Block.PairCount - 1 do
    begin
      var P := PairAt(PC, I);
      var T := Plan.Issue[I];
      while (Q.Count > 0) and (Ready[0] <= T) do
      begin
        Q.Base := Q.Slots[0];
        for var K := 1 to Q.Count - 1 do
        begin
          Q.Slots[K - 1] := Q.Slots[K];
          Ready[K - 1] := Ready[K];
        end;
        Dec(Q.Count);
      end;
      Q.Visible[I] := Q.Base;
      if (Clip and IsClip(P.Upper)) or (not Clip and P.SetsFlags) then
      begin
        Q.EvReady[E] := T + 4;
        if Q.Count < 4 then
        begin
          Q.Slots[Q.Count] := EventSym + E;
          Ready[Q.Count] := T + 4;
          Inc(Q.Count);
        end;
        Inc(E);
      end;
      // FCSET (after the pair's CLIP): the base is its value (FJitClipSet
      // holds it), the queue empty.
      if Clip and ((P.Upper and $80000000) = 0) and ((P.Lower shr 25) = $11) then
      begin
        Q.Base := ClipSetSym;
        Q.Count := 0;
      end;
      PC := NextPC(PC, I + 1);
    end;
  end;

  // The incoming queue as it is now (the compiler runs as the block is
  // entered), if it is one a run can take (see QueueShape).
  procedure Observed(var Q: TPS2VUQueueSim; Clip: Boolean);
  begin
    Q := Default(TPS2VUQueueSim);
    var Count := S.FlagQCount;
    if Clip then
      Count := S.ClipQCount;
    if (Count < 0) or (Count > 4) then
      Exit;
    Q.Count0 := Count;
    for var K := 0 to Count - 1 do
    begin
      var R := S.FlagQReady[K];
      if Clip then
        R := S.ClipQReady[K];
      Dec(R, S.Cycles);
      if (R < 0) or (R > 3) or ((K > 0) and (R <= Q.Off[K - 1])) then
        Exit;
      Q.Off[K] := Integer(R);
    end;
    Q.Valid := True;
    Simulate(Q, Clip);
  end;

  function SameQueue(const A, B: TPS2VUQueueSim): Boolean;
  begin
    Result := A.Count0 = B.Count0;
    for var K := 0 to A.Count0 - 1 do
      Result := Result and (A.Off[K] = B.Off[K]);
  end;
  // The incoming entries' offsets as bits (see TPS2VUPair.QueueHint), and
  // the queue they make.

  function QueueMask(const Q: TPS2VUQueueSim): Integer;
  begin
    Result := 0;
    for var K := 0 to Q.Count0 - 1 do
      Result := Result or (1 shl Q.Off[K]);
  end;

  procedure FromMask(var Q: TPS2VUQueueSim; Mask: Integer; Clip: Boolean);
  begin
    Q := Default(TPS2VUQueueSim);
    for var O := 0 to 3 do
      if (Mask and (1 shl O)) <> 0 then
      begin
        Q.Off[Q.Count0] := O;
        Inc(Q.Count0);
      end;
    Q.Valid := True;
    Simulate(Q, Clip);
  end;

  // The incoming queue is Q's, else on to Fail.
  procedure CheckQueue(const Q: TPS2VUQueueSim; Clip: Boolean; Fail: TJitLabel);
  begin
    var Count := M(@S.FlagQCount);
    var Ready := M(@S.FlagQReady[0]);
    if Clip then
    begin
      Count := M(@S.ClipQCount);
      Ready := M(@S.ClipQReady[0]);
    end;
    J.Branch(jcNe, jw32, Count, JImm(Q.Count0), Fail);
    for var K := 0 to Q.Count0 - 1 do
    begin
      J.Move(jw64, JT0, JS1);
      J.Alu(jaAdd, jw64, JT0, JImm(Q.Off[K]));
      J.Branch(jcNe, jw64, JMem(jrSelf, Ready.Disp + K * 8), JT0, Fail);
    end;
  end;

  // Where a symbol's MAC, status or clip flag is (see TPS2VUQueueSim).
  function SymbolMAC(Sym: Integer): Integer;
  begin
    if Sym >= EventSym then
      Result := M(@FJitEvents[Sym - EventSym].MAC).Disp
    else if Sym >= 0 then
      Result := M(@S.FlagQMAC[Sym]).Disp
    else
      Result := M(@S.MACBase).Disp;
  end;

  function SymbolStatus(Sym: Integer): Integer;
  begin
    if Sym >= EventSym then
      Result := M(@FJitEvents[Sym - EventSym].Status).Disp
    else if Sym >= 0 then
      Result := M(@S.FlagQStatus[Sym]).Disp
    else
      Result := M(@S.StatusBase).Disp;
  end;

  function SymbolClip(Sym: Integer): Integer;
  begin
    if Sym >= ClipSetSym then
      Result := M(@FJitClipSet).Disp
    else if Sym >= EventSym then
      Result := M(@FJitClipEvents[Sym - EventSym].Value).Disp
    else if Sym >= 0 then
      Result := M(@S.ClipQValue[Sym]).Disp
    else
      Result := M(@S.ClipBase).Disp;
  end;

  procedure Copy32(Dst, Src: Integer);
  begin
    J.Move(jw32, JT0, JMem(jrSelf, Src));
    J.Move(jw32, JMem(jrSelf, Dst), JT0);
  end;

  // The queue as Q leaves it: the base first, then the slots in order (a
  // slot only takes an entry from one above it, still unwritten).
  procedure Materialize(const Q: TPS2VUQueueSim; Clip: Boolean);
  begin
    if Clip then
    begin
      if Q.Base <> -1 then
        Copy32(M(@S.ClipBase).Disp, SymbolClip(Q.Base));
      for var K := 0 to 3 do
      begin
        var Sym := Q.Slots[K];
        if Sym = K then
          Continue;
        Copy32(M(@S.ClipQValue[K]).Disp, SymbolClip(Sym));
        if Sym >= EventSym then
        begin
          J.Move(jw64, JT0, JS1);
          J.Alu(jaAdd, jw64, JT0, JImm(Q.EvReady[Sym - EventSym]));
        end
        else
          J.Move(jw64, JT0, M(@S.ClipQReady[Sym]));
        J.Move(jw64, M(@S.ClipQReady[K]), JT0);
      end;
      if Q.Count <> Q.Count0 then
        J.Move(jw32, M(@S.ClipQCount), JImm(Q.Count));
      Copy32(M(@FClipVisible).Disp, M(@S.ClipBase).Disp);
      Exit;
    end;
    if Q.Base <> -1 then
    begin
      Copy32(M(@S.MACBase).Disp, SymbolMAC(Q.Base));
      Copy32(M(@S.StatusBase).Disp, SymbolStatus(Q.Base));
    end;
    for var K := 0 to 3 do
    begin
      var Sym := Q.Slots[K];
      if Sym = K then
        Continue;
      Copy32(M(@S.FlagQMAC[K]).Disp, SymbolMAC(Sym));
      Copy32(M(@S.FlagQStatus[K]).Disp, SymbolStatus(Sym));
      if Sym >= EventSym then
      begin
        J.Move(jw64, JT0, JS1);
        J.Alu(jaAdd, jw64, JT0, JImm(Q.EvReady[Sym - EventSym]));
      end
      else
        J.Move(jw64, JT0, M(@S.FlagQReady[Sym]));
      J.Move(jw64, M(@S.FlagQReady[K]), JT0);
    end;
    if Q.Count <> Q.Count0 then
      J.Move(jw32, M(@S.FlagQCount), JImm(Q.Count));
  end;

  // Until a read, a pending Q/P need not be materialized. At the end,
  // account for every elapsed cycle, including scheduled hazard stalls.
  procedure Land(DelayAddress, PendingAddress, ValueAddress: Pointer; Elapsed: Integer; Final: Boolean);
  begin
    var Done := J.NewLabel;
    var Pending := J.NewLabel;
    J.Move(jw32, JT0, M(DelayAddress));
    J.Branch(jcLe, jw32, JT0, JImm(0), Done);
    J.Branch(jcGt, jw32, JT0, JImm(Elapsed), Pending);
    J.Move(jw32, JT1, M(PendingAddress));
    J.Move(jw32, M(ValueAddress), JT1);
    J.Move(jw32, M(DelayAddress), JImm(0));
    J.Jump(Done);
    J.Bind(Pending);
    if Final then
      J.Alu(jaSub, jw32, M(DelayAddress), JImm(Elapsed));
    J.Bind(Done);
  end;

  // An XGKICK in progress takes the quadwords due by the pair issued at
  // Issue (as the general path does before each pair). Only VU stores
  // change what it reads: before each of them and after the last pair.
  procedure KickProgress(Issue: Integer);
  begin
    if Region <> nil then
      Exit; // no kick on trace entry or in either span
    var NoKick := J.NewLabel;
    J.Move(jw8, JT0, M(@FKickPending));
    J.Branch(jcEq, jw32, JT0, JImm(0), NoKick);
    J.Move(jw64, JT0, JS1);
    J.Alu(jaAdd, jw64, JT0, JImm(Issue));
    J.Branch(jcLt, jw64, JT0, M(@FKickDue), NoKick);
    J.Move(jw64, M(@S.Cycles), JT0);
    J.Call(@TPS2VUCore.TakeKick, [JSelf, JImm(0)]);
    J.Bind(NoKick);
  end;

  procedure QueueShape(CountAddress, ReadyAddress: Pointer);
  begin
    var Done := J.NewLabel;
    J.Move(jw32, JT0, M(CountAddress));
    J.Branch(jcAbove, jw32, JT0, JImm(4), Slow);
    J.Branch(jcEq, jw32, JT0, JImm(0), Done);
    J.Move(jw64, JT2, JS1);
    J.Alu(jaAdd, jw64, JT2, JImm(3));
    for var K := 0 to 3 do
    begin
      var Last := J.NewLabel;
      J.Move(jw64, JT1, JMem(jrSelf, M(ReadyAddress).Disp + K * 8));
      if K > 0 then
        J.Branch(jcLe, jw64, JT1, JMem(jrSelf, M(ReadyAddress).Disp + (K - 1) * 8), Slow);
      J.Branch(jcNe, jw32, JT0, JImm(K + 1), Last);
      J.Branch(jcGt, jw64, JT1, JT2, Slow);
      J.Jump(Done);
      J.Bind(Last);
    end;
    J.Bind(Done);
  end;

  // A run's event a queue symbol stands for (see TPS2VUQueueSim) is read.
  procedure NeedSymbol(var Needed: array of Boolean; Sym: Integer);
  begin
    if (Sym >= EventSym) and (Sym < EventSym + Length(Needed)) then
      Needed[Sym - EventSym] := True;
  end;

  procedure NeedQueue(var Needed: array of Boolean; const Q: TPS2VUQueueSim);
  begin
    if not Q.Valid then
      Exit;
    NeedSymbol(Needed, Q.Base);
    for var K := 0 to 3 do
      NeedSymbol(Needed, Q.Slots[K]);
  end;

  // Once three cycles have elapsed all incoming events have landed. The
  // remaining queue evolution is entirely compile-time: symbols identify
  // captured MAC/status values, -1 leaves that physical tail slot untouched.
  procedure DrainSymbols(Cycle: Integer);
  begin
    while (LiveCount > 0) and (EventReady[Slots[0]] <= Cycle) do
    begin
      BaseEvent := Slots[0];
      for var K := 1 to LiveCount - 1 do
        Slots[K - 1] := Slots[K];
      Dec(LiveCount);
    end;
  end;

  // The run's pairs and its end, for incoming queues FlagQ and ClipQ: known
  // on entry (Fixed: checked there), else checked at the end.
  // The queue Q (simulated through the run) leaves, as offsets from the
  // next run's start (the run ends after LastCycle) equal to the ones it
  // was simulated from.
  function LeavesAsFound(const Q: TPS2VUQueueSim; LastCycle: Integer): Boolean;
  begin
    Result := Q.Valid and (Q.Count = Q.Count0);
    for var K := 0 to Q.Count - 1 do
    begin
      if not Result then
        Exit;
      var Sym := Q.Slots[K];
      Result := (Sym >= EventSym) and (Sym < ClipSetSym) and (Q.EvReady[Sym - EventSym] - (LastCycle + 1) = Q.Off[K]);
    end;
  end;

  procedure StoreReady(const Schedule: TPS2VUFastPlan; LastCycle, Offset: Integer);
  begin
    var Pending := Max(LastCycle - 3, -1);
    for var R := 1 to 31 do
      if Schedule.WriteAny[R] > Pending then
      begin
        for var K := 0 to 3 do
          if Schedule.WriteAt[R, K] > Pending then
          begin
            J.Move(jw64, JT0, JS1);
            J.Alu(jaAdd, jw64, JT0, JImm(Schedule.WriteAt[R, K] + Offset + 4));
            J.Move(jw64, M(@FReady[R, K]), JT0);
          end;
        J.Move(jw64, JT0, JS1);
        J.Alu(jaAdd, jw64, JT0, JImm(Schedule.WriteAny[R] + Offset + 4));
        J.Move(jw64, M(@FReadyAny[R]), JT0);
      end;
  end;

  procedure EmitBody(const FlagQ, ClipQ: TPS2VUQueueSim; Fixed: Boolean);
  begin
    // (Where a run that branches back to its start goes round again.)
    var BodyStart := J.NewLabel;
    J.Bind(BodyStart);
    var Count := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count)));
    var Limit := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit)));
    var FlagEmpty := Default(TPS2VUQueueSim);
    FlagEmpty.Valid := True;
    Simulate(FlagEmpty, False);
    var ClipEmpty := Default(TPS2VUQueueSim);
    ClipEmpty.Valid := True;
    Simulate(ClipEmpty, True);
    EventCount := 0;
    PrefixCount := 0;
    var PC := Block.PC;
    for var I := 0 to Block.PairCount - 1 do
    begin
      if PairAt(PC, I).SetsFlags then
      begin
        EventReady[EventCount] := Plan.Issue[I] + 4;
        Inc(EventCount);
        if Plan.Issue[I] <= 3 then
          Inc(PrefixCount);
      end;
      PC := NextPC(PC, I + 1);
    end;
    FillChar(Slots, SizeOf(Slots), $FF);
    for var I := 0 to PrefixCount - 1 do
      Slots[I] := I;
    LiveCount := PrefixCount;
    BaseEvent := -1;
    for var I := PrefixCount to EventCount - 1 do
    begin
      DrainSymbols(EventReady[I] - 4);
      if LiveCount < 4 then
      begin
        Slots[LiveCount] := I;
        Inc(LiveCount);
      end;
    end;
    var LastCycle := Plan.Issue[Block.PairCount - 1];
    DrainSymbols(LastCycle);
    // A run shorter than the four cycles events take to land leaves incoming
    // events in the queue: every event is replayed at run time (Generic).
    var Generic := LastCycle < 3;
    // A run whose branch (in its last pair but one) goes back to its own start
    // may go round again within its code, without the entry's checks, where
    // they would all pass then: no end, its pipeline inputs ready again (the
    // results its last cycles issue too), the queues it leaves the ones it was
    // compiled for (with flag reads; any otherwise, and incoming entries all
    // landed, not Generic), and nothing else changed (no callback runs inside
    // a scheduled run). The branch, the budget and its trace window, and a kick
    // are looked at each time.
    var SelfLoop :=
      (Region = nil)
      and not Generic
      and ((Block.Words[(Block.PairCount - 2) * 2 + 1] and $40000000) = 0)
      and ((Block.Words[(Block.PairCount - 1) * 2 + 1] and $40000000) = 0);
    if SelfLoop then
    begin
      var BranchLo := Block.Words[(Block.PairCount - 2) * 2];
      var BranchHi := Block.Words[(Block.PairCount - 2) * 2 + 1];
      SelfLoop := ((BranchHi and $80000000) = 0) and ((BranchLo shr 25) in [$20, $21, $28, $29, $2C..$2F]);
      if SelfLoop then
      begin
        var Imm := Integer(BranchLo and $7FF);
        if Imm >= $400 then
          Dec(Imm, $800);
        SelfLoop := (Cardinal(Integer(Block.PC) + (Block.PairCount - 2) * 8 + 8 + Imm * 8) and FCodeMask) = Block.PC;
      end;
      for var R := 1 to 31 do
        for var K := 0 to 3 do
          if (Plan.ReadAt[R, K] >= 0)
            and (Plan.ReadAt[R, K] < 3)
            and (Plan.WriteAt[R, K] >= 0)
            and (Plan.WriteAt[R, K] + 4 > LastCycle + 1 + Plan.ReadAt[R, K]) then
            SelfLoop := False;
      if Fixed and not (LeavesAsFound(FlagQ, LastCycle) and LeavesAsFound(ClipQ, LastCycle)) then
        SelfLoop := False;
    end;
    var WholeQueueKnown := (BaseEvent >= 0) and not Generic;
    for var I := 0 to 3 do
      WholeQueueKnown := WholeQueueKnown and (Slots[I] >= 0);
    // The events whose MAC flag and status are read: by flag reads, into the
    // queue the run leaves (each way it may, see below) and S.MAC/S.Status
    // (the last). The others' only add sticky status bits (EmitLazyFlush).
    var Needed: array[0..PS2VUBlockPairs - 1] of Boolean;
    FillChar(Needed, SizeOf(Needed), Ord(Generic));
    if EventCount > 0 then
      Needed[EventCount - 1] := True;
    NeedQueue(Needed, FlagQ);
    if not Fixed then
      NeedQueue(Needed, FlagEmpty);
    for var K := 0 to 3 do
      if Slots[K] >= 0 then
        Needed[Slots[K]] := True;
    if BaseEvent >= 0 then
      Needed[BaseEvent] := True;
    if not WholeQueueKnown then
      for var E := 0 to PrefixCount - 1 do
        Needed[E] := True;
    PC := Block.PC;
    var Lazy := False;
    for var I := 0 to Block.PairCount - 1 do
    begin
      var P := PairAt(PC, I);
      if ((P.Upper and $80000000) = 0)
        and ((P.Lower and $80000000) = 0)
        and ((P.Lower shr 25) in [$14, $16..$18, $1A, $1B]) then
        NeedSymbol(Needed, FlagQ.Visible[I]);
      PC := NextPC(PC, I + 1);
    end;
    for var K := 0 to EventCount - 1 do
      Lazy := Lazy or not Needed[K];
    FLazyPending := False;
    if Lazy then
      J.Move(jw32, M(@FJitLazyMAC), JImm(0));
    if FVectorMemorySafe and J.HasVectors then
      KeepStart(J.VectorKeepCount);
    var Events := 0;
    var QBase := -1;
    var PBase := -1;
    var ClipEvents := 0;
    PC := Block.PC;
    for var I := 0 to Block.PairCount - 1 do
    begin
      ProfileMark('fast-pair');
      var P := PairAt(PC, I);
      var F := P.Upper and $3F;
      if F >= $3C then
        F := ((P.Upper shr 4) and $7C) or (P.Upper and 3);
      var Special := -1;
      if ((P.Upper and $80000000) = 0) and ((P.Lower and $8000003C) = $8000003C) then
        Special := Integer(((P.Lower shr 4) and $7C) or (P.Lower and 3));
      // Q and P as each pair's preparation leaves them: what was pending
      // when the run started (Base -1) or since the DIV/SQRT/RSQRT or EFU op
      // issued at Base lands after its latency; WAITQ/WAITP land it at once.
      // (A new DIV first lands the older Q itself; a new EFU op replaces a
      // P still pending.)
      if Special = $3B then
        Land(@S.QDelay, @S.PendingQ, @S.Q, MaxInt, False)
      else if F in [$1C, $20, $21, $24, $25] then
        Land(@S.QDelay, @S.PendingQ, @S.Q, Plan.Issue[I] - QBase, False);
      if Special = $7B then
        Land(@S.PDelay, @S.PendingP, @S.P, MaxInt, False)
      else if (Special = $64) or ((Special >= $70) and (Special <= $7E)) then
        Land(@S.PDelay, @S.PendingP, @S.P, Plan.Issue[I] - PBase, False);
      if (Special >= $38) and (Special <= $3A) then
        QBase := Plan.Issue[I];
      if (Special >= $70) and (Special <= $7E) and (Special <> $7B) then
        PBase := Plan.Issue[I];
      // (Branches take the pair's address as a constant. A branch is only in
      // the last pair but one: the pending flag, clear on entry, is cleared
      // again only after it.)
      FEmitPC := Integer(PC);
      if (I = Block.PairCount - 1) or ((Region <> nil) and (I = Region.Split - 1)) then
      begin
        J.Move(jw32, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))), JImm(PC));
        J.Move(jw8, JT0, M(@S.BranchPending));
        J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Branching))), JT0);
        J.Move(jw32, JT0, M(@S.BranchTarget));
        J.Move(jw32, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Target))), JT0);
        J.Move(jw8, M(@S.BranchPending), JImm(0));
      end;
      if ((P.Upper and $80000000) = 0)
        and (((P.Lower shr 25) in [$01, $05])
        or (((P.Lower and $8000003C) = $8000003C)
        and ((((P.Lower shr 4) and $7C) or (P.Lower and 3)) in [$35, $37, $3F]))) then
        KickProgress(Plan.Issue[I]);
      // (The integer history is read by a branch, at most in the last pair but
      // one, and left as the last two pairs make it: the earlier updates are
      // overwritten unread.)
      if (I >= Block.PairCount - 3) or ((Region <> nil) and (I >= Region.Split - 3) and (I < Region.Split)) then
      begin
        // Scheduled stalls retire the same VI history as AdvanceCycles.
        if (I > 0) and (Plan.Issue[I] > Plan.Issue[I - 1] + 1) then
          J.Move(jw32, M(@FLoadReg), JImm(-1));
        EmitVIHistory(P^);
      end;
      FEmitClipSlot := -1;
      // (An I-bit pair's upper op is a CLIP all the same.)
      if ((P.Upper and $3F) >= $3C) and ((((P.Upper shr 4) and $7C) or (P.Upper and 3)) = $1F) then
      begin
        FEmitClipSlot := ClipEvents;
        FEmitClipIssue := Plan.Issue[I];
        Inc(ClipEvents);
      end;
      if Fixed then
      begin
        FEmitMACSrc := SymbolMAC(FlagQ.Visible[I]);
        FEmitStatusSrc := SymbolStatus(FlagQ.Visible[I]);
        FEmitClipSrc := SymbolClip(ClipQ.Visible[I]);
      end;
      FEmitLazyFlags := P.SetsFlags and not Needed[Events];
      EmitPair(P^);
      FEmitLazyFlags := False;
      FEmitMACSrc := -1;
      FEmitStatusSrc := -1;
      FEmitClipSrc := -1;
      FEmitClipSlot := -1;
      EmitCommit(P^);
      if P.SetsFlags and not Needed[Events] then
        Inc(Events)
      else if P.SetsFlags then
      begin
        J.Move(jw32, JT0, M(@S.MAC));
        J.Move(jw32, M(@FJitEvents[Events].MAC), JT0);
        J.Move(jw32, JT0, M(@S.Status));
        J.Move(jw32, M(@FJitEvents[Events].Status), JT0);
        if Generic or (not WholeQueueKnown and (Events < PrefixCount)) then
        begin
          J.Move(jw64, JT0, JS1);
          J.Alu(jaAdd, jw64, JT0, JImm(Plan.Issue[I] + 4));
          J.Move(jw64, M(@FJitEvents[Events].Ready), JT0);
        end;
        Inc(Events);
      end;
      if (Region <> nil) and (I = Region.Split - 1) then
      begin
        StoreReady(Region.Head, Region.Head.Issue[I], 0);
        J.Move(jw32, M(@S.TPC), JImm(Region.Target));
      end;
      PC := NextPC(PC, I + 1);
    end;
    FEmitPC := -1;
    KeepStart(0);
    // (Nothing left: the last event is worked out.)
    EmitLazyFlush;
    KickProgress(Plan.Issue[Block.PairCount - 1]);
    ProfileMark('fast-output');
    // Ready times of results still in the pipeline after the run. One issued
    // three cycles before the last pair or earlier is ready after it, and so
    // is what its field held before (ready three cycles into the run, see
    // SerializeState): that write would change nothing.
    // (-1: not written at all.)
    if Region = nil then
      StoreReady(Plan, LastCycle, 0)
    else
      StoreReady(Region.Tail, Region.Tail.Issue[Block.PairCount - Region.Split - 1], Plan.Issue[Region.Split - 1] + 1);
    Land(@S.QDelay, @S.PendingQ, @S.Q, LastCycle - QBase, True);
    Land(@S.PDelay, @S.PendingP, @S.P, LastCycle - PBase, True);
    ProfileMark('fast-replay-flags');
    // The queues as worked out for the incoming ones found (see above), else
    // replayed at run time.
    var Tail := J.NewLabel;
    var dynamic := J.NewLabel;
    var FlagDone := J.NewLabel;
    if Fixed then
      Materialize(FlagQ, False)
    else
    begin
      for var V := 0 to 1 do
      begin
        var Q := FlagQ;
        if V = 1 then
        begin
          if FlagQ.Valid and SameQueue(FlagQ, FlagEmpty) then
            Break;
          Q := FlagEmpty;
        end;
        if not Q.Valid then
          Continue;
        var Next := J.NewLabel;
        CheckQueue(Q, False, Next);
        Materialize(Q, False);
        J.Jump(FlagDone);
        J.Bind(Next);
      end;
      J.Jump(dynamic);
    end;
    J.Bind(FlagDone);
    if Fixed then
      Materialize(ClipQ, True)
    else
    begin
      for var V := 0 to 1 do
      begin
        var Q := ClipQ;
        if V = 1 then
        begin
          if ClipQ.Valid and SameQueue(ClipQ, ClipEmpty) then
            Break;
          Q := ClipEmpty;
        end;
        if not Q.Valid then
          Continue;
        var Next := J.NewLabel;
        CheckQueue(Q, True, Next);
        Materialize(Q, True);
        J.Jump(Tail);
        J.Bind(Next);
      end;
      // (The flag queue is final: no entry of it lands by the last issue.)
      if ClipEvents > 0 then
        J.Move(jw32, M(@FJitClipCount), JImm(ClipEvents));
      J.Move(jw64, JT5, JS1);
      J.Alu(jaAdd, jw64, JT5, JImm(LastCycle));
      J.Call(@TPS2VUCore.FinishFastFlags, [JSelf, JImm(0), JT5, JT5]);
    end;
    J.Jump(Tail);
    J.Bind(dynamic);
    // (The clip queue as the last pair leaves it: drained to its issue.)
    if ClipEvents > 0 then
      J.Move(jw32, M(@FJitClipCount), JImm(ClipEvents));
    J.Move(jw64, JT5, JS1);
    J.Alu(jaAdd, jw64, JT5, JImm(LastCycle));
    if Generic then
    begin
      J.Move(jw64, JT0, JS1);
      J.Alu(jaAdd, jw64, JT0, JImm(LastCycle));
      J.Call(@TPS2VUCore.FinishFastFlags, [JSelf, JImm(EventCount), JT0, JT5]);
    end
    else if WholeQueueKnown then
    begin
      var NoClip := J.NewLabel;
      if ClipEvents = 0 then
        J.Branch(jcEq, jw32, M(@S.ClipQCount), JImm(0), NoClip);
      J.Move(jw64, JT0, JS1);
      J.Alu(jaAdd, jw64, JT0, JImm(LastCycle));
      J.Call(@TPS2VUCore.FinishFastFlags, [JSelf, JImm(0), JT0, JT5]);
      J.Bind(NoClip);
      J.Move(jw32, JT0, M(@S.ClipBase));
      J.Move(jw32, M(@FClipVisible), JT0);
    end
    else
    begin
      J.Move(jw64, JT0, JS1);
      J.Alu(jaAdd, jw64, JT0, JImm(3));
      J.Call(@TPS2VUCore.FinishFastFlags, [JSelf, JImm(PrefixCount), JT0, JT5]);
    end;
    // (Generic: FinishFastFlags left the whole queue.)
    if not Generic then
    begin
      for var K := 0 to 3 do
        if Slots[K] >= 0 then
        begin
          // The state keeps MAC and status in separate arrays, not interleaved.
          J.Move(jw32, JT0, M(@FJitEvents[Slots[K]].MAC));
          J.Move(jw32, M(@S.FlagQMAC[K]), JT0);
          J.Move(jw32, JT0, M(@FJitEvents[Slots[K]].Status));
          J.Move(jw32, M(@S.FlagQStatus[K]), JT0);
          J.Move(jw64, JT0, JS1);
          J.Alu(jaAdd, jw64, JT0, JImm(EventReady[Slots[K]]));
          J.Move(jw64, M(@S.FlagQReady[K]), JT0);
        end;
      if BaseEvent >= 0 then
      begin
        J.Move(jw32, JT0, M(@FJitEvents[BaseEvent].MAC));
        J.Move(jw32, M(@S.MACBase), JT0);
        J.Move(jw32, JT0, M(@FJitEvents[BaseEvent].Status));
        J.Move(jw32, M(@S.StatusBase), JT0);
      end;
      J.Move(jw32, M(@S.FlagQCount), JImm(LiveCount));
    end;
    J.Bind(Tail);

    J.Move(jw64, JT0, JS1);
    J.Alu(jaAdd, jw64, JT0, JImm(LastCycle + 1));
    J.Move(jw64, M(@S.Cycles), JT0);
    J.Alu(jaAdd, jw64, M(@Executed), JImm(Block.PairCount));
    J.Alu(jaAdd, jw64, M(@FJitFastPairs), JImm(Block.PairCount));
    J.Alu(jaAdd, jw32, Count, JImm(Block.PairCount));
    J.Move(jw32, JT0, JImm(PC));
    var Sequential := J.NewLabel;
    J.Move(jw8, JT1, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Branching))));
    J.Branch(jcEq, jw32, JT1, JImm(0), Sequential);
    J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Target))));
    J.Bind(Sequential);
    J.Move(jw32, M(@S.TPC), JT0);
    var Ending := (Block.Words[(Block.PairCount - 2) * 2 + 1] and $40000000) <> 0;
    J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Ending))), JImm(Ord(Ending)));
    if Ending then
    begin
      J.Move(jw8, M(@S.Running), JImm(0));
      J.Move(jw8, M(@S.EndPending), JImm(0));
    end
    else if (Block.Words[(Block.PairCount - 1) * 2 + 1] and $40000000) <> 0 then
      J.Move(jw8, M(@S.EndPending), JImm(1));
    if SelfLoop then
    begin
      // Round again: back to the start (T0: TPC), the whole run within the
      // budget and before its trace window, no kick in progress.
      J.Branch(jcNe, jw32, JT0, JImm(Block.PC), Chain);
      J.Move(jw32, JT1, Count);
      J.Alu(jaAdd, jw32, JT1, JImm(Block.PairCount + 64));
      J.Branch(jcGt, jw32, JT1, Limit, Chain);
      J.Move(jw8, JT1, M(@FKickPending));
      J.Branch(jcNe, jw32, JT1, JImm(0), Chain);
      Inc(FJitSelfLoops);
      J.Alu(jaAdd, jw64, M(@FJitLoopTurns), JImm(1));
      J.Move(jw64, JS1, M(@S.Cycles));
      J.Jump(BodyStart);
    end;
    J.Jump(Chain);
  end;

begin
  J := FJit;
  ProfileMark('fast-entry');
  var Count := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count)));
  var Limit := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit)));
  // The whole block within the budget. A run's last 64 pairs are recorded
  // in LoopTrace: the block's pairs all (below) or none of them, else the
  // general path records them pair by pair.
  J.Move(jw32, JT0, Limit);
  J.Alu(jaSub, jw32, JT0, Count);
  J.Branch(jcLt, jw32, JT0, JImm(Block.PairCount), Slow);
  var WholeTrace := J.NewLabel;
  J.Branch(jcLe, jw32, JT0, JImm(64), WholeTrace);
  J.Branch(jcLt, jw32, JT0, JImm(64 + Block.PairCount), Slow);
  J.Bind(WholeTrace);
  J.Branch(jcNe, jw64, M(@FFastGate), JImm(0), Slow);
  // Running, no branch or end pending (adjacent bytes: one look).
  if (NativeInt(@S.BranchPending) = NativeInt(@S.Running) + 1)
    and (NativeInt(@S.EndPending) = NativeInt(@S.Running) + 2) then
  begin
    J.Move(jw32, JT0, M(@S.Running));
    J.Alu(jaAnd, jw32, JT0, JImm($FFFFFF));
    J.Branch(jcNe, jw32, JT0, JImm(1), Slow);
  end
  else
  begin
    J.Move(jw8, JT0, M(@S.Running));
    J.Branch(jcEq, jw32, JT0, JImm(0), Slow);
    J.Move(jw8, JT0, M(@S.BranchPending));
    J.Branch(jcNe, jw32, JT0, JImm(0), Slow);
    J.Move(jw8, JT0, M(@S.EndPending));
    J.Branch(jcNe, jw32, JT0, JImm(0), Slow);
  end;
  // (A kick in progress takes its quadwords as the general path does, see
  // KickProgress.)
  J.Move(jw32, JT0, M(@S.TPC));
  J.Alu(jaAnd, jw32, JT0, JImm(FCodeMask));
  J.Branch(jcNe, jw32, JT0, JImm(Block.PC), Slow);
  J.Move(jw64, JS1, M(@S.Cycles));
  ProfileMark('fast-inputs');
  // A kick in progress must not complete inside the run (its callback may
  // change the code): its last quadword, or the next GIF tag that could
  // end it, is due after the last pair's issue.
  var KickOK := J.NewLabel;
  var KickEnd := J.NewLabel;
  var KickDue := J.NewLabel;
  var KickQuads := Integer((FDataMask + 1) div 16);
  J.Move(jw8, JT0, M(@FKickPending));
  J.Branch(jcEq, jw32, JT0, JImm(0), KickOK);
  J.Move(jw32, JT0, M(@FKickEnd));
  J.Branch(jcGe, jw32, JT0, JImm(0), KickEnd);
  J.Move(jw32, JT0, M(@FKickNextTag));
  J.Alu(jaAdd, jw32, JT0, JImm(1));
  J.Bind(KickEnd);
  J.Alu(jaSub, jw32, JT0, JImm(1));
  J.Branch(jcLe, jw32, JT0, JImm(KickQuads - 1), KickDue);
  J.Move(jw32, JT0, JImm(KickQuads - 1));
  J.Bind(KickDue);
  J.Shift(jsShl, jw64, jrT0, 1);
  J.Alu(jaAdd, jw64, JT0, M(@FKickStart));
  J.Move(jw64, JT1, JS1);
  J.Alu(jaAdd, jw64, JT1, JImm(Plan.Issue[Block.PairCount - 1]));
  J.Branch(jcLe, jw64, JT0, JT1, Slow);
  J.Bind(KickOK);
  // Flag reads see the queues through the run as the compiler found them
  // on entry: such a run needs them so. Other runs check at their end
  // whether they were so (or empty), to leave them without a replay.
  var HasFlagReads := False;
  var PC := Block.PC;
  for var I := 0 to Block.PairCount - 1 do
  begin
    var P := PairAt(PC, I);
    if ((P.Upper and $80000000) = 0)
      and ((P.Lower and $80000000) = 0)
      and ((P.Lower shr 25) in [$10..$14, $16..$18, $1A..$1C]) then
      HasFlagReads := True;
    PC := NextPC(PC, I + 1);
  end;
  var FlagSeen, ClipSeen, FlagHint, ClipHint: TPS2VUQueueSim;
  Observed(FlagSeen, False);
  Observed(ClipSeen, True);
  // Other incoming queues met here before (NoteQueues): a second version.
  var Hint := FPairs[Block.PC shr 3].QueueHint;
  FromMask(FlagHint, Hint and 15, False);
  FromMask(ClipHint, (Hint shr 4) and 15, True);
  var HaveHint :=
    HasFlagReads
    and ((Hint and $100) <> 0)
    and FlagSeen.Valid
    and ClipSeen.Valid
    and not (SameQueue(FlagHint, FlagSeen) and SameQueue(ClipHint, ClipSeen));
  if HasFlagReads then
  begin
    if not (FlagSeen.Valid and ClipSeen.Valid) then
    begin
      J.Jump(Slow);
      Exit;
    end;
    var Known := J.NewLabel;
    var Other := J.NewLabel;
    CheckQueue(FlagSeen, False, Other);
    CheckQueue(ClipSeen, True, Other);
    J.Jump(Known);
    J.Bind(Other);
    if HaveHint then
    begin
      var Miss := J.NewLabel;
      CheckQueue(FlagHint, False, Miss);
      CheckQueue(ClipHint, True, Miss);
      J.Jump(Known);
      J.Bind(Miss);
    end;
    // Others: noted once (this version is dropped, its successor takes
    // both), then the general path.
    // The exact incoming-queue checks above already prove shape on a hit.
    // Only a miss needs the general shape validation before it is noted.
    QueueShape(@S.FlagQCount, @S.FlagQReady[0]);
    QueueShape(@S.ClipQCount, @S.ClipQReady[0]);
    if (Hint and $100) = 0 then
    begin
      J.Call(
        @TPS2VUCore.NoteQueues,
        [JSelf, JImm(Block.PC), JImm(QueueMask(FlagSeen) or (QueueMask(ClipSeen) shl 4)), JImm(FBlockCount)]
      );
      J.Jump(Stale);
    end
    else
      J.Jump(Stall);
    J.Bind(Known);
  end
  else
  begin
    QueueShape(@S.FlagQCount, @S.FlagQReady[0]);
    QueueShape(@S.ClipQCount, @S.ClipQReady[0]);
  end;
  // All external dependencies are first read at cycle 0, 1 or 2. Work out
  // those deadlines once rather than reloading/adding the same cycle for
  // every field. No call runs between here and the last dependency check.
  var NeedCycle1 := False;
  var NeedCycle2 := False;
  for var R := 1 to 31 do
    for var K := 0 to 3 do
    begin
      NeedCycle1 := NeedCycle1 or (Plan.ReadAt[R, K] = 1);
      NeedCycle2 := NeedCycle2 or (Plan.ReadAt[R, K] = 2);
    end;
  if NeedCycle1 then
  begin
    J.Move(jw64, JT4, JS1);
    J.Alu(jaAdd, jw64, JT4, JImm(1));
  end;
  if NeedCycle2 then
  begin
    J.Move(jw64, JT5, JS1);
    J.Alu(jaAdd, jw64, JT5, JImm(2));
  end;
  for var R := 1 to 31 do
  begin
    // A register whose latest result is ready by its first read needs no
    // look at its fields (FReadyAny is the latest of them). Every result
    // already issued is ready three cycles in (see SerializeState): only
    // the first reads before need a look.
    var First := -1;
    var Fields := 0;
    for var K := 0 to 3 do
      if (Plan.ReadAt[R, K] >= 0) and (Plan.ReadAt[R, K] < 3) then
      begin
        Inc(Fields);
        if (First < 0) or (Plan.ReadAt[R, K] < First) then
          First := Plan.ReadAt[R, K];
      end;
    if First < 0 then
      Continue;
    var Ready := J.NewLabel;
    if Fields > 1 then
    begin
      J.Branch(jcLe, jw64, M(@FReadyAny[R]), InputDeadline(First), Ready);
    end;
    for var K := 0 to 3 do
      if (Plan.ReadAt[R, K] >= 0) and (Plan.ReadAt[R, K] < 3) then
      begin
        J.Branch(jcGt, jw64, M(@FReady[R, K]), InputDeadline(Plan.ReadAt[R, K]), Stall);
      end;
    J.Bind(Ready);
  end;
  ProfileMark('fast-code-guards');
  // The pairs as compiled, looked at only when code memory changed since
  // they were found so (this block's generation slot, FBlockGens).
  var CodeKnown := J.NewLabel;
  if Length(FBlockGens) = 0 then
    SetLength(FBlockGens, PS2VUMaxBlocks * 4);
  var GenIndex := FBlockCount;
  if Region <> nil then
    Inc(GenIndex, PS2VUMaxBlocks * (1 + Region.Arm));
  FBlockGens[GenIndex] := FCodeGen;
  J.Move(jw64, JT1, M(@FBlockGens));
  var GenSlot := JMem(jrT1, GenIndex * 4);
  J.Move(jw32, JT0, M(@FCodeGen));
  J.Branch(jcEq, jw32, JT0, GenSlot, CodeKnown);
  J.Move(jw64, JT2, M(@FCode));
  PC := Block.PC;
  for var I := 0 to Block.PairCount - 1 do
  begin
    // Both words at once (lower, then upper). (A scheduled run takes all it
    // knows of its pairs from when it was compiled, not their decoded
    // metadata, which the general path checks for itself.)
    J.Move(jw64, JT3, JImm(Int64(UInt64(Block.Words[I * 2]) or (UInt64(Block.Words[I * 2 + 1]) shl 32))));
    J.Branch(jcNe, jw64, JMem(jrT2, Integer(PC)), JT3, Stale);
    PC := NextPC(PC, I + 1);
  end;
  J.Move(jw32, GenSlot, JT0);
  J.Bind(CodeKnown);
  // In the trace window (see the budget check): pair K at LoopTrace
  // [Count + 64 - Limit + K].
  var NoTrace := J.NewLabel;
  J.Move(jw32, JT0, Count);
  J.Alu(jaAdd, jw32, JT0, JImm(64));
  J.Alu(jaSub, jw32, JT0, Limit);
  J.Branch(jcLt, jw32, JT0, JImm(0), NoTrace);
  J.Shift(jsShl, jw64, jrT0, 2);
  J.Alu(jaAdd, jw64, JT0, JSelf);
  PC := Block.PC;
  for var I := 0 to Block.PairCount - 1 do
  begin
    J.Move(jw32, JMem(jrT0, M(@LoopTrace[0]).Disp + I * 4), JImm(PC));
    PC := NextPC(PC, I + 1);
  end;
  J.Bind(NoTrace);
  // (Flag reads: for the queues found on entry, else the general path.)
  if HasFlagReads and HaveHint then
  begin
    var Second := J.NewLabel;
    CheckQueue(FlagSeen, False, Second);
    CheckQueue(ClipSeen, True, Second);
    EmitBody(FlagSeen, ClipSeen, True);
    J.Bind(Second);
    EmitBody(FlagHint, ClipHint, True);
  end
  else
    EmitBody(FlagSeen, ClipSeen, HasFlagReads);
end;

// Compile-time selection of the upper arithmetic. The exact PS2 SIMD
// routines are shared with the interpreter, not the opcode decoder.
function TPS2VUCore.EmitUpper(Op: Cardinal): Boolean;
begin
  if FAllowVectorResult then
  begin
    if (FIndex = 1) and ((Op and $3F) >= $3C) then
    begin
      var Special := ((Op shr 4) and $7C) or (Op and 3);
      if Special in [$10..$17] then
      begin
        var Native, Model, Params: Pointer;
        if PS2RegisterFixed(Special, Native, Model, Params) then
        begin
          EmitLoadVF(jv0, Integer((Op shr 11) and 31));
          FJit.VectorCall(Native, Model, JImm(Int64(NativeUInt(Params))));
          FEmitVectorResult := True;
          Inc(FJitVectorOps);
          Exit(True);
        end;
      end;
    end;
    if EmitRegisterSelect(Op) then
    begin
      FEmitVectorResult := True;
      Exit(True);
    end;
    if EmitRegisterUpper(Op) then
    begin
      FEmitVectorResult := True;
      Exit(True);
    end;
  end;
  Result := EmitScalarUpper(Op);
end;

function TPS2VUCore.EmitRegisterSelect(Op: Cardinal): Boolean;
begin
  Result := False;
  var F := Op and $3F;
  var Maximum := F in [$10..$13, $1D, $2B];
  if not Maximum and not (F in [$14..$17, $1F, $2F]) then
    Exit;
  var Routine := PS2RegisterSelectNative(Maximum);
  if Routine = nil then
    Exit;
  var J := FJit;
  EmitLoadVF(jv0, Integer((Op shr 11) and 31));
  if F <= $17 then
  begin
    EmitLoadVF(jv1, Integer((Op shr 16) and 31));
    J.VectorShuffle(jv1, jv1, Byte((F and 3) * $55));
  end
  else if F in [$1D, $1F] then
    J.VectorBroadcast(jv1, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))))
  else
    EmitLoadVF(jv1, Integer((Op shr 16) and 31));
  J.VectorCall(Routine, PS2RegisterSelectModel(Maximum), JImm(0));
  // Select instructions do not set MAC/status. The existing pair/commit
  // machinery supplies masks and upper-over-lower precedence unchanged.
  Inc(FJitVectorOps);
  Result := True;
end;

function TPS2VUCore.EmitRegisterUpper(Op: Cardinal): Boolean;
type
  TKind = (rkAdd, rkSub, rkMul, rkMadd, rkMsub, rkOpMula, rkOpMsub);
var
  Kind: TKind;
begin
  Result := False;
  var F := Op and $3F;
  var Acc := F >= $3C;
  if Acc then
    F := ((Op shr 4) and $7C) or (Op and 3);
  case F of
    $00..$03, $20, $22, $28:
      Kind := rkAdd;
    $04..$07, $24, $26, $2C:
      Kind := rkSub;
    $08..$0B, $21, $23, $29:
      Kind := rkMadd;
    $0C..$0F, $25, $27, $2D:
      Kind := rkMsub;
    $18..$1C, $1E, $2A:
      Kind := rkMul;
    $2E:
      if Acc then
        Kind := rkOpMula
      else
        Kind := rkOpMsub;
  else
    Exit;
  end;
  var J := FJit;
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Mask := (Op shr 21) and 15;
  EmitLoadVF(jv0, Fs);
  if Kind in [rkOpMula, rkOpMsub] then
  begin
    // The outer product's operands as EmitScalarUpper builds them: Fs.yzx
    // times Ft.zxy, w zero in both (it is not written: x, y and z only).
    J.VectorShuffle(jv0, jv0, $C9);
    EmitLoadVF(jv1, Ft);
    J.VectorShuffle(jv1, jv1, $D2);
    J.VectorLoad(jv2, JMem(jrSelf, Integer(NativeInt(@FLanesXYZ) - NativeInt(Self))));
    J.VectorAlu(jvaAnd, jv0, jv2);
    J.VectorAlu(jvaAnd, jv1, jv2);
    Mask := Mask and $E;
  end
  else if F <= $1B then
  begin
    EmitLoadVF(jv1, Ft);
    J.VectorShuffle(jv1, jv1, Byte((Op and 3) * $55));
  end
  else if F in [$1C, $20, $21, $24, $25] then
    J.VectorBroadcast(jv1, JMem(jrSelf, Integer(NativeInt(@S.Q) - NativeInt(Self))))
  else if F in [$1E, $22, $23, $26, $27] then
    J.VectorBroadcast(jv1, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))))
  else
    EmitLoadVF(jv1, Ft);
  if Kind = rkSub then
  begin
    J.Move(jw32, JT0, JImm($80000000));
    J.VectorBroadcast(jv2, JT0);
    J.VectorAlu(jvaXor, jv1, jv2);
  end;
  if (FIndex = 1) and (Kind in [rkMadd, rkMsub, rkOpMsub]) and PS2VectorAVX512 then
  begin
    var Subtract := Kind in [rkMsub, rkOpMsub];
    J.VectorCallAt(
      JMem(jrSelf, Integer(NativeInt(@FAccMath[Subtract]) - NativeInt(Self))),
      PS2RegisterAccModel(Subtract),
      JAddr(jrSelf, Integer(NativeInt(@S.ACC) - NativeInt(Self)))
    );
  end
  else
  begin
    var Math := vrmAdd;
    if Kind in [rkMul, rkMadd, rkMsub, rkOpMula, rkOpMsub] then
      Math := vrmMul;
    J.VectorCallAt(
      JMem(jrSelf, Integer(NativeInt(@FMath[Math]) - NativeInt(Self))),
      PS2RegisterMathModel(Math),
      JImm(0)
    );
    if Kind in [rkMadd, rkMsub, rkOpMsub] then
    begin
      J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FJitProductFlags) - NativeInt(Self))), JT0);
      if Kind in [rkMsub, rkOpMsub] then
      begin
        J.Move(jw32, JT1, JImm($80000000));
        J.VectorBroadcast(jv2, JT1);
        J.VectorAlu(jvaXor, jv0, jv2);
      end;
      J.VectorShuffle(jv1, jv0, $E4); // retain the rounded product, never FMA
      EmitLoadVF(jv0, 32);
      J.VectorCallAt(
        JMem(jrSelf, Integer(NativeInt(@FMath[vrmAdd]) - NativeInt(Self))),
        PS2RegisterMathModel(vrmAdd),
        JImm(0)
      );
      J.Alu(jaOr, jw32, JT0, JMem(jrSelf, Integer(NativeInt(@FJitProductFlags) - NativeInt(Self))));
    end;
  end;
  EmitRegisterFlags(Mask);
  Inc(FJitVectorOps);
  Result := True;
end;

procedure TPS2VUCore.EmitRegisterFlags(Mask: Cardinal);
begin
  var J := FJit;
  ProfileMark('register-mac-status');
  if Mask = 0 then
    J.Move(jw32, JT3, JImm(0))
  else
  begin
    var Lanes := Mask;
    if FEmitLazyFlags then
    begin
      // Only sticky groups survive this event: lane order within them does
      // not matter, so keep x in the lowest bit (EmitLazyFlush).
      Lanes := ((Mask and 8) shr 3) or ((Mask and 4) shr 1) or ((Mask and 2) shl 1) or ((Mask and 1) shl 3);
      J.VectorMask(jvmSign, jrT1, jv0);
      J.VectorMask(jvmZero, jrT3, jv0);
    end
    else
    begin
      J.VectorShuffle(jv2, jv0, $1B); // MAC field order: w,z,y,x
      J.VectorMask(jvmSign, jrT1, jv2);
      J.VectorMask(jvmZero, jrT3, jv2);
    end;
    J.Shift(jsShl, jw32, jrT1, 4);
    J.Alu(jaOr, jw32, JT3, JT1);
    J.Alu(jaOr, jw32, JT3, JT0);
    // Sign/zero masks have only four bits; the math routine returns only
    // underflow/overflow groups. One mask covers all groups, none for xyzw.
    if Mask <> 15 then
      J.Alu(jaAnd, jw32, JT3, JImm(Lanes or (Lanes shl 4) or (Mask shl 8) or (Mask shl 12)));
  end;
  if FEmitLazyFlags then
  begin
    J.Alu(jaOr, jw32, JMem(jrSelf, Integer(NativeInt(@FJitLazyMAC) - NativeInt(Self))), JT3);
    FLazyPending := True;
    Exit;
  end;
  J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@S.MAC) - NativeInt(Self))), JT3);
  EmitStatus;
end;

function TPS2VUCore.EmitScalarUpper(Op: Cardinal): Boolean;
type
  TArithmetic = (akAdd, akSub, akMul, akMadd, akMsub, akOpMula, akOpMsub);
var
  Kind: TArithmetic;
begin
  Result := False;
  var F := Op and $3F;
  var Target := Integer((Op shr 6) and 31);
  var Acc := F >= $3C;
  if Acc then
  begin
    F := ((Op shr 4) and $7C) or (Op and 3);
    Target := 32;
    if F = $2F then
      Exit(True); // NOP
  end;
  case F of
    $00..$03, $20, $22, $28:
      Kind := akAdd;
    $04..$07, $24, $26, $2C:
      Kind := akSub;
    $08..$0B, $21, $23, $29:
      Kind := akMadd;
    $0C..$0F, $25, $27, $2D:
      Kind := akMsub;
    $18..$1C, $1E, $2A:
      Kind := akMul;
    $2E:
      if Acc then
        Kind := akOpMula
      else
        Kind := akOpMsub;
  else
    Exit;
  end;
  var J := FJit;
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Mask := (Op shr 21) and 15;
  var Operand := JAddr(jrSelf, Integer(NativeInt(@FJitOperand) - NativeInt(Self)));
  var Product := JAddr(jrSelf, Integer(NativeInt(@FJitProduct) - NativeInt(Self)));
  var Value := JAddr(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self)));
  var Flags := JAddr(jrSelf, Integer(NativeInt(@FJitFlags) - NativeInt(Self)));
  var ProductFlags := JAddr(jrSelf, Integer(NativeInt(@FJitProductFlags) - NativeInt(Self)));
  var A := JAddr(jrS0, Fs * 16);
  var B := JAddr(jrS0, Ft * 16);
  if Kind in [akOpMula, akOpMsub] then
  begin
    Mask := Mask and $E;
    for var K := 0 to 3 do
    begin
      if K = 3 then
        J.Move(jw32, JT0, JImm(0))
      else
        J.Move(jw32, JT0, JMem(jrS0, Fs * 16 + ((K + 1) mod 3) * 4));
      J.Move(jw32, JMem(jrSelf, Operand.Disp + K * 4), JT0);
      if K < 3 then
        J.Move(jw32, JT0, JMem(jrS0, Ft * 16 + ((K + 2) mod 3) * 4));
      J.Move(jw32, JMem(jrSelf, Value.Disp + K * 4), JT0);
    end;
    A := Operand;
    B := Value;
  end
  else if (F <= $1B) or (F = $1C) or (F = $1E) or (F in [$20..$27]) then
  begin
    if (F = $1C) or (F in [$20, $21, $24, $25]) then
      J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.Q) - NativeInt(Self))))
    else if (F = $1E) or (F in [$22, $23, $26, $27]) then
      J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))))
    else
      J.Move(jw32, JT0, JMem(jrS0, Ft * 16 + Integer(Op and 3) * 4));
    J.Move(jw64, JT1, JT0);
    J.Shift(jsShl, jw64, jrT1, 32);
    J.Alu(jaOr, jw64, JT0, JT1);
    J.Move(jw64, JMem(jrSelf, Operand.Disp), JT0);
    J.Move(jw64, JMem(jrSelf, Operand.Disp + 8), JT0);
    B := Operand;
  end;
  case Kind of
    akAdd:
      J.Call(@PS2Add4, [A, B, Value, Flags]);
    akSub:
      begin
        for var K := 0 to 1 do
        begin
          J.Move(jw64, JT0, JMem(B.Reg, B.Disp + K * 8));
          J.Move(jw64, JT1, JImm(Int64($8000000080000000)));
          J.Alu(jaXor, jw64, JT0, JT1);
          J.Move(jw64, JMem(jrSelf, Operand.Disp + K * 8), JT0);
        end;
        J.Call(@PS2Add4, [A, Operand, Value, Flags]);
      end;
    akMul:
      J.Call(@PS2Mul4, [A, B, Value, Flags]);
    akMadd, akMsub, akOpMula, akOpMsub:
      begin
        J.Call(@PS2Mul4, [A, B, Product, ProductFlags]);
        if Kind = akOpMula then
        begin
          for var K := 0 to 1 do
          begin
            J.Move(jw64, JT0, JMem(jrSelf, Product.Disp + K * 8));
            J.Move(jw64, JMem(jrSelf, Value.Disp + K * 8), JT0);
          end;
          J.Move(jw32, JT0, JMem(jrSelf, ProductFlags.Disp));
          J.Move(jw32, JMem(jrSelf, Flags.Disp), JT0);
        end
        else
        begin
          if Kind <> akMadd then
            for var K := 0 to 1 do
            begin
              J.Move(jw64, JT0, JMem(jrSelf, Product.Disp + K * 8));
              J.Move(jw64, JT1, JImm(Int64($8000000080000000)));
              J.Alu(jaXor, jw64, JT0, JT1);
              J.Move(jw64, JMem(jrSelf, Product.Disp + K * 8), JT0);
            end;
          J.Call(@PS2Add4, [JAddr(jrSelf, Integer(NativeInt(@S.ACC) - NativeInt(Self))), Product, Value, Flags]);
          J.Move(jw32, JT0, JMem(jrSelf, ProductFlags.Disp));
          J.Alu(jaOr, jw32, JMem(jrSelf, Flags.Disp), JT0);
        end;
      end;
  end;
  ProfileMark('mac-status');
  EmitFlags(Mask);
  J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperReg) - NativeInt(Self))), JImm(Target));
  J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperMask) - NativeInt(Self))), JImm(Mask));
  Result := True;
end;

// MAC/status updates with a compile-time field mask. No work or flags from
// an unwritten field may leak into them.
procedure TPS2VUCore.EmitFlags(Mask: Cardinal);
begin
  var J := FJit;
  J.Move(jw32, JT3, JImm(0));
  for var K := 0 to 3 do
    if (Mask and FieldBit(K)) <> 0 then
    begin
      var NonZero := J.NewLabel;
      J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self)) + K * 4));
      J.Move(jw32, JT1, JT0);
      J.Shift(jsShr, jw32, jrT1, 31);
      J.Shift(jsShl, jw32, jrT1, 7 - K);
      J.Alu(jaOr, jw32, JT3, JT1);
      J.Alu(jaAnd, jw32, JT0, JImm($7FFFFFFF));
      J.Branch(jcNe, jw32, JT0, JImm(0), NonZero);
      J.Alu(jaOr, jw32, JT3, JImm(FieldBit(K)));
      J.Bind(NonZero);
      J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@FJitFlags) - NativeInt(Self))));
      J.Move(jw32, JT1, JT0);
      J.Alu(jaAnd, jw32, JT0, JImm(1 shl K));
      J.Shift(jsShl, jw32, jrT0, 15 - 2 * K);
      J.Alu(jaOr, jw32, JT3, JT0);
      J.Alu(jaAnd, jw32, JT1, JImm(16 shl K));
      J.Shift(jsShl, jw32, jrT1, 7 - 2 * K);
      J.Alu(jaOr, jw32, JT3, JT1);
    end;
  if FEmitLazyFlags then
  begin
    J.Alu(jaOr, jw32, JMem(jrSelf, Integer(NativeInt(@FJitLazyMAC) - NativeInt(Self))), JT3);
    FLazyPending := True;
    Exit;
  end;
  J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@S.MAC) - NativeInt(Self))), JT3);
  EmitStatus;
end;


// S.Status from the MAC flag in T3 (EmitFlags's, EmitRegisterFlags's): each
// group (Z, S, U, O) with a field set sets its bit and its sticky bit, six
// above; I, D and the sticky bits stay. Without branches (results' signs and
// zeros change from one vertex to the next): the exact MAC lookup gives
// each group's nonzero bit in bits 0..3 of T1.
procedure TPS2VUCore.EmitStatus;
begin
  var J := FJit;
  EmitLazyFlush;
  J.Move(jw32, JT1, JT3);
  EmitMACGroups;
  J.Move(jw32, JT0, JT1);
  J.Shift(jsShl, jw32, jrT0, 6);
  J.Alu(jaOr, jw32, JT1, JT0);
  J.Move(jw32, JT0, JMem(jrSelf, Integer(NativeInt(@S.Status) - NativeInt(Self))));
  J.Alu(jaAnd, jw32, JT0, JImm($FF0));
  J.Alu(jaOr, jw32, JT0, JT1);
  J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@S.Status) - NativeInt(Self))), JT0);
end;

// JT1's four MAC groups to status bits 0..3. Only JT0 is clobbered; mask the
// index as the old reduction did, including synthetic aliased callers.
procedure TPS2VUCore.EmitMACGroups;
begin
  var J := FJit;
  J.Alu(jaAnd, jw32, JT1, JImm($FFFF));
  J.Move(jw64, JT0, JImm(NativeInt(@MACGroups[0])));
  J.Alu(jaAdd, jw64, JT0, JT1);
  J.Move(jw8, JT1, JMem(jrT0, 0));
end;
// The sticky bits of the events since the last worked-out status whose own
// status nothing reads (FJitLazyMAC, see EmitBody) into S.Status: before the
// next status is worked out or a helper may look at it. Their Z, S, U and O
// bits are only seen replaced by a later event's, and I and D are DIV's, as
// those sticky bits are. (T3 and T2 kept.)

procedure TPS2VUCore.EmitLazyFlush;
begin
  if not FLazyPending then
    Exit;
  FLazyPending := False;
  var J := FJit;
  var Lazy := JMem(jrSelf, Integer(NativeInt(@FJitLazyMAC) - NativeInt(Self)));
  J.Move(jw32, JT1, Lazy);
  EmitMACGroups;
  J.Shift(jsShl, jw32, jrT1, 6);
  J.Alu(jaOr, jw32, JMem(jrSelf, Integer(NativeInt(@S.Status) - NativeInt(Self))), JT1);
  J.Move(jw32, Lazy, JImm(0));
end;

// Pipeline bookkeeping with the pair's operands already known. Calls only
// on stalls, an in-flight XGKICK or the diagnostic trace path.
procedure TPS2VUCore.EmitPrepare(const P: TPS2VUPair);
var
  J: TJitAsm;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

  procedure Source(Reg: Integer; Mask: Cardinal);
  begin
    if (Reg <= 0) or (Mask = 0) then
      Exit;
    if Mask = $F then
    begin
      var Ready := J.NewLabel;
      J.Move(jw64, JT1, M(@FReadyAny[Reg]));
      J.Branch(jcLe, jw64, JT1, JT0, Ready);
      J.Move(jw64, JT0, JT1);
      J.Bind(Ready);
      Exit;
    end;
    for var K := 0 to 3 do
      if (Mask and FieldBit(K)) <> 0 then
      begin
        var Ready := J.NewLabel;
        J.Move(jw64, JT1, M(@FReady[Reg, K]));
        J.Branch(jcLe, jw64, JT1, JT0, Ready);
        J.Move(jw64, JT0, JT1);
        J.Bind(Ready);
      end;
  end;

  procedure Drain(Clip: Boolean);
  var
    Count, Ready, Base, Values, StatusValues, StatusBase: TJitOp;
  begin
    if Clip then
    begin
      Count := M(@S.ClipQCount);
      Ready := M(@S.ClipQReady[0]);
      Base := M(@S.ClipBase);
      Values := M(@S.ClipQValue[0]);
    end
    else
    begin
      Count := M(@S.FlagQCount);
      Ready := M(@S.FlagQReady[0]);
      Base := M(@S.MACBase);
      Values := M(@S.FlagQMAC[0]);
      StatusValues := M(@S.FlagQStatus[0]);
      StatusBase := M(@S.StatusBase);
    end;
    var Again := J.NewLabel;
    var Done := J.NewLabel;
    J.Bind(Again);
    J.Move(jw32, JT0, Count);
    J.Branch(jcLe, jw32, JT0, JImm(0), Done);
    J.Move(jw64, JT1, Ready);
    J.Branch(jcGt, jw64, JT1, M(@S.Cycles), Done);
    J.Move(jw32, JT1, Values);
    J.Move(jw32, Base, JT1);
    if not Clip then
    begin
      J.Move(jw32, JT1, StatusValues);
      J.Move(jw32, StatusBase, JT1);
    end;
    for var K := 1 to 3 do
    begin
      var Keep := J.NewLabel;
      J.Branch(jcLe, jw32, JT0, JImm(K), Keep);
      J.Move(jw32, JT1, JMem(jrSelf, Values.Disp + K * 4));
      J.Move(jw32, JMem(jrSelf, Values.Disp + (K - 1) * 4), JT1);
      J.Move(jw64, JT1, JMem(jrSelf, Ready.Disp + K * 8));
      J.Move(jw64, JMem(jrSelf, Ready.Disp + (K - 1) * 8), JT1);
      if not Clip then
      begin
        J.Move(jw32, JT1, JMem(jrSelf, StatusValues.Disp + K * 4));
        J.Move(jw32, JMem(jrSelf, StatusValues.Disp + (K - 1) * 4), JT1);
      end;
      J.Bind(Keep);
    end;
    J.Alu(jaSub, jw32, Count, JImm(1));
    J.Jump(Again);
    J.Bind(Done);
  end;

  procedure Delay(DelayAddress, PendingAddress, ValueAddress: Pointer; Wait: Boolean);
  begin
    var Done := J.NewLabel;
    J.Move(jw32, JT0, M(DelayAddress));
    J.Branch(jcLe, jw32, JT0, JImm(0), Done);
    J.Alu(jaSub, jw32, JT0, JImm(1));
    J.Move(jw32, M(DelayAddress), JT0);
    if not Wait then
      J.Branch(jcNe, jw32, JT0, JImm(0), Done);
    if Wait then
      J.Move(jw32, M(DelayAddress), JImm(0));
    J.Move(jw32, JT1, M(PendingAddress));
    J.Move(jw32, M(ValueAddress), JT1);
    J.Bind(Done);
  end;

begin
  J := FJit;
  var Done := J.NewLabel;
  var Normal := J.NewLabel;
  J.Branch(jcEq, jw64, M(@RunTrace), JImm(0), Normal);
  J.Call(@TPS2VUCore.PreparePair, [JSelf, JCtx]);
  J.Jump(Done);
  J.Bind(Normal);
  ProfileMark('hazards');
  J.Move(jw64, JT0, M(@S.Cycles));
  Source(P.U.S1, P.U.M1);
  Source(P.U.S2, P.U.M2);
  Source(P.L.S1, P.L.M1);
  Source(P.L.S2, P.L.M2);
  var NoStall := J.NewLabel;
  J.Branch(jcLe, jw64, JT0, M(@S.Cycles), NoStall);
  J.Alu(jaSub, jw64, JT0, M(@S.Cycles));
  J.Call(@TPS2VUCore.AdvanceCycles, [JSelf, JT0]);
  J.Bind(NoStall);
  var NoKick := J.NewLabel;
  J.Move(jw8, JT0, M(@FKickPending));
  J.Branch(jcEq, jw32, JT0, JImm(0), NoKick);
  J.Move(jw64, JT0, M(@S.Cycles));
  J.Branch(jcLt, jw64, JT0, M(@FKickDue), NoKick);
  J.Call(@TPS2VUCore.TakeKick, [JSelf, JImm(0)]);
  J.Bind(NoKick);
  ProfileMark('clip-queue');
  Drain(True);
  J.Move(jw32, JT0, M(@S.ClipBase));
  J.Move(jw32, M(@FClipVisible), JT0);
  ProfileMark('flag-queue');
  Drain(False);
  ProfileMark('prepare-control');
  J.Move(jw8, JT0, M(@S.BranchPending));
  J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Branching))), JT0);
  J.Move(jw32, JT0, M(@S.BranchTarget));
  J.Move(jw32, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Target))), JT0);
  J.Move(jw8, JT0, M(@S.EndPending));
  J.Move(jw8, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Ending))), JT0);
  J.Move(jw8, M(@S.BranchPending), JImm(0));
  var Immediate := (P.Upper and $80000000) <> 0;
  Delay(@S.QDelay, @S.PendingQ, @S.Q, not Immediate and ((P.Lower and $FE0007FF) = $800003BF));
  Delay(@S.PDelay, @S.PendingP, @S.P, not Immediate and ((P.Lower and $FE0007FF) = $800007BF));
  EmitVIHistory(P);
  J.Move(jw32, M(@FUpperReg), JImm(-1));
  J.Move(jw32, M(@FLowerReg), JImm(-1));
  J.Bind(Done);
end;

procedure TPS2VUCore.EmitVIHistory(const P: TPS2VUPair);
var
  J: TJitAsm;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

begin
  J := FJit;
  J.Move(jw32, JT0, M(@FLoadReg));
  J.Move(jw32, M(@FBranchReg), JT0);
  J.Move(jw32, JT0, M(@FLoadOld));
  J.Move(jw32, M(@FBranchOld), JT0);
  var Reg := P.VIWrite;
  J.Move(jw32, M(@FLoadReg), JImm(Reg));
  if Reg >= 0 then
  begin
    J.Move(jw32, JT0, JMem(jrS3, Reg * 4));
    J.Move(jw32, M(@FLoadOld), JT0);
  end;
end;

procedure TPS2VUCore.EmitCommit(const P: TPS2VUPair);
var
  J: TJitAsm;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

  // Destination and mask are constants, including helper-backed operations.
  // Commit lower first: the upper half wins overlapping fields.
  procedure Commit(Upper: Boolean);
  var
    Reg: Integer;
    Mask: Cardinal;
    Value: TJitOp;
  begin
    if not Upper and FLowerDirect then
      Exit;
    if Upper then
    begin
      Value := M(@FUpperValue);
      Mask := (P.Upper shr 21) and 15;
      Reg := Integer((P.Upper shr 6) and 31);
      var F := P.Upper and $3F;
      if F >= $3C then
      begin
        F := ((P.Upper shr 4) and $7C) or (P.Upper and 3);
        case F of
          $00..$0F, $18..$1C, $1E, $20..$2A, $2C..$2E:
            Reg := 32;
          $10..$17, $1D:
            Reg := Integer((P.Upper shr 16) and 31);
        else
          Reg := -1;
        end;
        if F = $2E then
          Mask := Mask and $E;
      end
      else
      begin
        if F > $2F then
          Reg := -1;
        if F = $2E then
          Mask := Mask and $E;
      end;
    end
    else
    begin
      Value := M(@FLowerValue);
      Mask := (P.Lower shr 21) and 15;
      Reg := -1;
      if (P.Upper and $80000000) = 0 then
      begin
        if (P.Lower shr 25) = 0 then
          Reg := Integer((P.Lower shr 16) and 31)
        else if (P.Lower and $8000003C) = $8000003C then
          if (((P.Lower shr 4) and $7C) or (P.Lower and 3)) in [$30, $31, $34, $36, $3D, $40, $41, $64] then
            Reg := Integer((P.Lower shr 16) and 31);
      end;
    end;
    if (Reg <= 0) or (Mask = 0) then
      Exit;
    var Target := VFOperand(Reg);
    if Upper and FEmitVectorResult then
    begin
      var Lanes: Byte := 0;
      for var K := 0 to 3 do
        if Mask and FieldBit(K) <> 0 then
          Lanes := Lanes or (Byte(1) shl K);
      EmitStoreVF(Reg, jv0, Lanes);
      Exit;
    end;
    KeepForget(Reg);
    // (Field by field: the staged value was often just written a field at a
    // time, and a wider load of it would wait for those stores.)
    for var K := 0 to 3 do
    begin
      if (Mask and FieldBit(K)) = 0 then
        Continue;
      J.Move(jw32, JT0, JMem(jrSelf, Value.Disp + K * 4));
      J.Move(jw32, JMem(Target.Reg, Target.Disp + K * 4), JT0);
    end;
  end;

begin
  J := FJit;
  ProfileMark('commit');
  Commit(False);
  Commit(True);
end;

procedure TPS2VUCore.EmitFinish(const P: TPS2VUPair);
var
  J: TJitAsm;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

  procedure Note(const R: TPS2VURegUse);
  begin
    if (R.Dest <= 0) or (R.DestMask = 0) then
      Exit;
    for var K := 0 to 3 do
      if (R.DestMask and FieldBit(K)) <> 0 then
        J.Move(jw64, M(@FReady[R.Dest, K]), JT4);
    J.Move(jw64, M(@FReadyAny[R.Dest]), JT4);
  end;

begin
  J := FJit;
  EmitCommit(P);
  ProfileMark('ready-writes');
  J.Move(jw64, JT4, M(@S.Cycles));
  J.Alu(jaAdd, jw64, JT4, JImm(4));
  Note(P.U);
  Note(P.L);
  ProfileMark('flag-enqueue');
  if P.SetsFlags then
  begin
    var Full := J.NewLabel;
    J.Move(jw32, JT0, M(@S.FlagQCount));
    J.Branch(jcGe, jw32, JT0, JImm(4), Full);
    J.Move(jw64, JT2, JT0);
    J.Shift(jsShl, jw64, jrT2, 2);
    J.Alu(jaAdd, jw64, JT2, JSelf);
    J.Move(jw32, JT1, M(@S.MAC));
    J.Move(jw32, JMem(jrT2, M(@S.FlagQMAC[0]).Disp), JT1);
    J.Move(jw32, JT1, M(@S.Status));
    J.Move(jw32, JMem(jrT2, M(@S.FlagQStatus[0]).Disp), JT1);
    J.Shift(jsShl, jw32, jrT0, 3);
    J.Move(jw64, JT2, JSelf);
    J.Alu(jaAdd, jw64, JT2, JT0);
    J.Move(jw64, JMem(jrT2, M(@S.FlagQReady[0]).Disp), JT4);
    J.Alu(jaAdd, jw32, M(@S.FlagQCount), JImm(1));
    J.Bind(Full);
  end;
  ProfileMark('finish-control');
  J.Alu(jaAdd, jw64, M(@Executed), JImm(1));
  J.Alu(jaAdd, jw64, M(@S.Cycles), JImm(1));
  var Count := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Count)));
  var Limit := JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Limit)));
  J.Alu(jaAdd, jw32, Count, JImm(1));
  var NoTrace := J.NewLabel;
  J.Move(jw32, JT0, Count);
  J.Alu(jaSub, jw32, JT0, Limit);
  J.Alu(jaAdd, jw32, JT0, JImm(63));
  J.Branch(jcLt, jw32, JT0, JImm(0), NoTrace);
  J.Shift(jsShl, jw32, jrT0, 2);
  J.Move(jw64, JT2, JSelf);
  J.Alu(jaAdd, jw64, JT2, JT0);
  J.Move(jw32, JT1, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))));
  J.Move(jw32, JMem(jrT2, M(@LoopTrace[0]).Disp), JT1);
  J.Bind(NoTrace);
  J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))));
  J.Alu(jaAdd, jw32, JT0, JImm(8));
  J.Alu(jaAnd, jw32, JT0, JImm(FCodeMask));
  var Sequential := J.NewLabel;
  J.Move(jw8, JT1, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Branching))));
  J.Branch(jcEq, jw32, JT1, JImm(0), Sequential);
  J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Target))));
  J.Bind(Sequential);
  J.Move(jw32, M(@S.TPC), JT0);
  var NotEnding := J.NewLabel;
  var Done := J.NewLabel;
  J.Move(jw8, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).Ending))));
  J.Branch(jcEq, jw32, JT0, JImm(0), NotEnding);
  J.Move(jw8, M(@S.Running), JImm(0));
  J.Move(jw8, M(@S.EndPending), JImm(0));
  J.Jump(Done);
  J.Bind(NotEnding);
  if (P.Upper and $40000000) <> 0 then
    J.Move(jw8, M(@S.EndPending), JImm(1));
  J.Bind(Done);
end;

function EFULength(V: PPS2Reg128): Cardinal; forward;

function EFUInverseLength(V: PPS2Reg128): Cardinal; forward;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// The DIV datapath. Unlike host Singles the VU uses exponent 255 for
// finite values and treats exponent 0 as signed zero. The ordinary inputs
// convert exactly to Double. Keep both original host rounding operations.
function VUScalarQuotient(A, B, Status: PCardinal): Cardinal;
asm
        .       NOFRAME
        mov     eax, [rcx]
        mov     r9d, [rdx]
        mov     ecx, eax
        mov     edx, r9d
        AND     ecx, $7F800000
        AND     edx, $7F800000
        jz      @@ZeroDenom
        test    ecx, ecx
        jz      @@ZeroNumer
        cmp     ecx, $7F800000
        je      @@Wide
        cmp     edx, $7F800000
        je      @@Wide
        movd    xmm4, eax
        movd    xmm5, r9d
        cvtss2sd xmm4, xmm4
        cvtss2sd xmm5, xmm5

@@Divide:
        divsd   xmm4, xmm5
        cvtsd2ss xmm4, xmm4
        movd    eax, xmm4
        ret

@@ZeroDenom:
        test    ecx, ecx
        jnz     @@NonzeroNumer
        OR      dword ptr[r8], $410
        jmp     @@Saturate

@@NonzeroNumer:
        OR      dword ptr[r8], $820

@@Saturate:
        XOR     eax, r9d
        OR      eax, $7FFFFFFF
        ret

@@ZeroNumer:
        XOR     eax, r9d
        AND     eax, $80000000
        ret

@@Wide:
  // Both exponents are nonzero. Expand the magnitude and add the
  // difference between exponent biases, then supply the original sign.
        mov     r11, $3800000000000000
        mov     ecx, eax
        AND     ecx, $7FFFFFFF
        SHL     rcx, 29
        add     rcx, r11
        AND     eax, $80000000
        SHL     rax, 32
        OR      rcx, rax
        movq    xmm4, rcx
        mov     edx, r9d
        AND     edx, $7FFFFFFF
        SHL     rdx, 29
        add     rdx, r11
        AND     r9d, $80000000
        SHL     r9, 32
        OR      rdx, r9
        movq    xmm5, rdx
        jmp     @@Divide
end;
{$ENDIF}

function TPS2VUCore.EmitLower(Op: Cardinal): Boolean;
var
  J: TJitAsm;

  function M(Address: Pointer): TJitOp;
  begin
    Result := JMem(jrSelf, Integer(NativeInt(Address) - NativeInt(Self)));
  end;

  procedure BranchOperand(Reg: Integer; Dst: TJitReg);
  begin
    var Current := J.NewLabel;
    J.Move(jw32, JReg(Dst), JMem(jrS3, Reg * 4));
    J.Branch(jcNe, jw32, M(@FBranchReg), JImm(Reg), Current);
    J.Move(jw32, JReg(Dst), M(@FBranchOld));
    J.Bind(Current);
    J.Shift(jsShl, jw32, Dst, 16);
    J.Shift(jsSar, jw32, Dst, 16);
  end;

begin
  Result := True;
  J := FJit;
  var It := Integer((Op shr 16) and 15);
  var Is_ := Integer((Op shr 11) and 15);
  var Group := Op shr 25;
  if (Op and $80000000) = 0 then
  begin
    if Group in [$20, $21, $24, $25, $28, $29, $2C..$2F] then
    begin
      var Skip := J.NewLabel;
      if Group in [$28, $29, $2C..$2F] then
      begin
        BranchOperand(Is_, jrT0);
        if Group in [$28, $29] then
          BranchOperand(It, jrT1);
        case Group of
          $28:
            J.Branch(jcNe, jw32, JT0, JT1, Skip);
          $29:
            J.Branch(jcEq, jw32, JT0, JT1, Skip);
          $2C:
            J.Branch(jcGe, jw32, JT0, JImm(0), Skip);
          $2D:
            J.Branch(jcLe, jw32, JT0, JImm(0), Skip);
          $2E:
            J.Branch(jcGt, jw32, JT0, JImm(0), Skip);
          $2F:
            J.Branch(jcLt, jw32, JT0, JImm(0), Skip);
        end;
      end;
      if Group in [$24, $25] then
      begin
        J.Move(jw32, JT2, JMem(jrS3, Is_ * 4));
        J.Shift(jsShl, jw32, jrT2, 3);
        J.Alu(jaAnd, jw32, JT2, JImm(FCodeMask));
      end
      else
      begin
        var Imm := Integer(Op and $7FF);
        if Imm >= $400 then
          Dec(Imm, $800);
        if FEmitPC >= 0 then
          J.Move(jw32, JT2, JImm((FEmitPC + 8 + Imm * 8) and Integer(FCodeMask)))
        else
        begin
          J.Move(jw32, JT2, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))));
          J.Alu(jaAdd, jw32, JT2, JImm(8 + Imm * 8));
          J.Alu(jaAnd, jw32, JT2, JImm(FCodeMask));
        end;
      end;
      if (Group in [$21, $25]) and (It <> 0) then
      begin
        if FEmitPC >= 0 then
          J.Move(jw32, JT0, JImm(FEmitPC))
        else
          J.Move(jw32, JT0, JMem(jrCtx, Integer(NativeUInt(@PPS2VURun(nil).PC))));
        J.Alu(jaAdd, jw32, JT0, JImm(16));
        J.Shift(jsShr, jw32, jrT0, 3);
        J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
        J.Move(jw32, JMem(jrS3, It * 4), JT0);
      end;
      J.Move(jw8, M(@S.BranchPending), JImm(1));
      J.Move(jw32, M(@S.BranchTarget), JT2);
      J.Bind(Skip);
      Exit;
    end;
    // CLIP flag reads write VI1 (their opcode's apparent it field is part
    // of the immediate, not a register).
    if Group in [$10..$13, $1C] then
    begin
      if (Group = $11) and (FEmitClipSrc >= 0) then
      begin
        // (A scheduled run leaves the clip queue and its base as it worked
        // them out, see TPS2VUQueueSim.)
        J.Move(jw32, M(@S.Clip), JImm(Op and $FFFFFF));
        J.Move(jw32, M(@FJitClipSet), JImm(Op and $FFFFFF));
        Exit;
      end;
      if Group = $11 then
      begin
        J.Move(jw32, M(@S.Clip), JImm(Op and $FFFFFF));
        J.Move(jw32, M(@S.ClipBase), JImm(Op and $FFFFFF));
        J.Move(jw32, M(@S.ClipQCount), JImm(0));
        J.Move(jw32, M(@FClipVisible), JImm(Op and $FFFFFF));
        Exit;
      end;
      if (Group = $1C) and (It = 0) then
        Exit;
      if FEmitClipSrc >= 0 then
        J.Move(jw32, JT0, JMem(jrSelf, FEmitClipSrc))
      else
        J.Move(jw32, JT0, M(@FClipVisible));
      if Group = $1C then
      begin
        J.Alu(jaAnd, jw32, JT0, JImm($FFF));
        J.Move(jw32, JMem(jrS3, It * 4), JT0);
        Exit;
      end;
      var Zero := J.NewLabel;
      J.Move(jw32, JMem(jrS3, 4), JImm(0));
      case Group of
        $10:
          begin
            J.Alu(jaAnd, jw32, JT0, JImm($FFFFFF));
            J.Branch(jcNe, jw32, JT0, JImm(Op and $FFFFFF), Zero);
          end;
        $12:
          J.BranchTest(jcEq, jw32, JT0, JImm(Op and $FFFFFF), Zero);
        $13:
          begin
            J.Alu(jaOr, jw32, JT0, JImm(Op and $FFFFFF));
            J.Alu(jaAnd, jw32, JT0, JImm($FFFFFF));
            J.Branch(jcNe, jw32, JT0, JImm($FFFFFF), Zero);
          end;
      end;
      J.Move(jw32, JMem(jrS3, 4), JImm(1));
      J.Bind(Zero);
      Exit;
    end;
    // Status (FSEQ/FSAND/FSOR) and MAC (FMEQ/FMAND/FMOR) reads where a
    // scheduled run says where the flags they see are.
    if (FEmitMACSrc >= 0) and (Group in [$14, $16, $17, $18, $1A, $1B]) then
    begin
      if It = 0 then
        Exit;
      var Imm12 := Integer(((Op shr 10) and $800) or (Op and $7FF));
      if Group in [$14, $16, $17] then
        J.Move(jw32, JT0, JMem(jrSelf, FEmitStatusSrc))
      else
      begin
        J.Move(jw32, JT0, JMem(jrSelf, FEmitMACSrc));
        J.Move(jw32, JT1, JMem(jrS3, Is_ * 4));
      end;
      case Group of
        $14, $18:
          begin
            var Differ := J.NewLabel;
            if Group = $14 then
              J.Alu(jaAnd, jw32, JT0, JImm($FFF))
            else
            begin
              J.Alu(jaXor, jw32, JT0, JT1);
              J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
            end;
            J.Move(jw32, JT2, JImm(0));
            if Group = $14 then
              J.Branch(jcNe, jw32, JT0, JImm(Imm12), Differ)
            else
              J.Branch(jcNe, jw32, JT0, JImm(0), Differ);
            J.Move(jw32, JT2, JImm(1));
            J.Bind(Differ);
            J.Move(jw32, JMem(jrS3, It * 4), JT2);
            Exit;
          end;
        $16:
          J.Alu(jaAnd, jw32, JT0, JImm(Imm12));
        $17:
          begin
            J.Alu(jaOr, jw32, JT0, JImm(Imm12));
            J.Alu(jaAnd, jw32, JT0, JImm($FFF));
          end;
        $1A:
          begin
            J.Alu(jaAnd, jw32, JT0, JT1);
            J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
          end;
        $1B:
          begin
            J.Alu(jaOr, jw32, JT0, JT1);
            J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
          end;
      end;
      J.Move(jw32, JMem(jrS3, It * 4), JT0);
      Exit;
    end;
    Exit(False);
  end;
  if (Op and $3F) < $3C then
    Exit(False);
  var Index := ((Op shr 4) and $7C) or (Op and 3);
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Mask := (Op shr 21) and $F;
  case Index of
    $30, $31: // MOVE, MR32 (nothing written for VF00 or no fields: the lower NOP is MOVE)
      EmitLowerStore(Ft, Mask, JMem(jrS0, Fs * 16), Index = $31);
    $34..$37, $3E, $3F: // LQI/LQD/SQI/SQD, ILWR/ISWR
      begin
        var Base := Is_;
        if Index in [$35, $37] then
          Base := It;
        if (Index in [$36, $37]) and (Base <> 0) then
        begin
          J.Move(jw32, JT0, JMem(jrS3, Base * 4));
          J.Alu(jaSub, jw32, JT0, JImm(1));
          J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
          J.Move(jw32, JMem(jrS3, Base * 4), JT0);
        end;
        J.Move(jw32, JT0, JMem(jrS3, Base * 4));
        J.Shift(jsShl, jw32, jrT0, 4);
        J.Alu(jaAnd, jw32, JT0, JImm(FDataMask));
        J.Move(jw64, JT2, JS2);
        J.Alu(jaAdd, jw64, JT2, JT0);
        if Index in [$34, $36] then
        begin
          EmitLowerStore(Ft, Mask, JMem(jrT2, 0), False)
        end
        else if Index = $3E then
        begin
          if It > 0 then
            for var K := 0 to 3 do
              if (Mask and FieldBit(K)) <> 0 then
              begin
                J.Move(jw32, JT0, JMem(jrT2, K * 4));
                J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
                J.Move(jw32, JMem(jrS3, It * 4), JT0);
                Break;
              end;
        end
        else
        begin
          if Index = $3F then
          begin
            J.Move(jw32, JT0, JMem(jrS3, It * 4));
            J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
          end;
          for var K := 0 to 3 do
            if (Mask and FieldBit(K)) <> 0 then
            begin
              if Index <> $3F then
                J.Move(jw32, JT0, JMem(jrS0, Fs * 16 + K * 4));
              J.Move(jw32, JMem(jrT2, K * 4), JT0);
            end;
        end;
        if (Index in [$34, $35]) and (Base <> 0) then
        begin
          J.Move(jw32, JT0, JMem(jrS3, Base * 4));
          J.Alu(jaAdd, jw32, JT0, JImm(1));
          J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
          J.Move(jw32, JMem(jrS3, Base * 4), JT0);
        end;
      end;
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
      $38: // DIV: the fields are fixed in this decoded pair
      begin
        if (FIndex <> 1) or not FVectorMemorySafe or (Group <> $40) then
          Exit(False);

        EmitLazyFlush;
        J.Move(jw32, M(@FLowerReg), JImm(-1));
        var Ready := J.NewLabel;
        J.Branch(jcLe, jw32, M(@S.QDelay), JImm(0), Ready);
        J.Move(jw32, JT0, M(@S.PendingQ));
        J.Move(jw32, M(@S.Q), JT0);
        J.Move(jw32, M(@S.QDelay), JImm(0));
        J.Bind(Ready);
        J.Alu(jaAnd, jw32, M(@S.Status), JImm(Int64(Cardinal($FFFFFFCF))));
        J.Call(
          @VUScalarQuotient,
          [
            JAddr(jrS0, Fs * 16 + Integer((Op shr 21) and 3) * 4),
            JAddr(jrS0, Ft * 16 + Integer((Op shr 23) and 3) * 4),
            JAddr(jrSelf, M(@S.Status).Disp)
          ]
        );
        J.Move(jw32, M(@S.PendingQ), JT0);
        J.Move(jw32, M(@S.QDelay), JImm(7));
      end;
{$ENDIF}
      $3C: // MTIR
      if It > 0 then
      begin
        J.Move(jw32, JT0, JMem(jrS0, Fs * 16 + Integer((Op shr 21) and 3) * 4));
        J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
        J.Move(jw32, JMem(jrS3, It * 4), JT0);
      end;
    $3D, $64: // MFIR, MFP
      begin
        if Index = $64 then
          J.Move(jw32, JT0, M(@S.P))
        else
        begin
          J.Move(jw32, JT0, JMem(jrS3, Is_ * 4));
          J.Shift(jsShl, jw32, jrT0, 16);
          J.Shift(jsSar, jw32, jrT0, 16);
        end;
      // (Straight to the register, as EmitLowerStore.)
        FLowerDirect := True;
        KeepForget(Ft);
        if Ft > 0 then
          for var K := 0 to 3 do
            if (Mask and FieldBit(K)) <> 0 then
              J.Move(jw32, JMem(jrS0, Ft * 16 + K * 4), JT0);
      end;
    $72, $73: // ELENG, ERLENG
      begin
        if (FIndex <> 1) or not FVectorMemorySafe or (Group <> $40) then
          Exit(False);
      // Keep the helper boundary: upper operands/results and pending MAC
      // events have the same visibility as in LowerSpecial.
        EmitLazyFlush;
        J.Move(jw32, M(@FLowerReg), JImm(-1));
        if Index = $72 then
          J.Call(@EFULength, [JAddr(jrS0, Fs * 16)])
        else
          J.Call(@EFUInverseLength, [JAddr(jrS0, Fs * 16)]);
        J.Move(jw32, M(@S.PendingP), JT0);
        J.Move(jw32, M(@S.PDelay), JImm(12));
      end;
    $68, $69: // XTOP, XITOP
      if It > 0 then
      begin
        J.Move(jw32, JT0, JMem(jrS3, (26 + Integer(Index - $68)) * 4));
        J.Move(jw32, JMem(jrS3, It * 4), JT0);
      end;
    $3B, $7B: // WAITQ, WAITP: a scheduled run lands Q/P before the pair
      if FEmitPC < 0 then
        Exit(False);
  else
    Exit(False);
  end;
end;

// A lower half's VF result (Mask's fields of the 16 bytes at Src, rotated one
// field for MR32) straight to VF[Ft] rather than staged for EmitCommit. Both
// halves have read their operands by then, and the upper result, still
// staged, commits after it, winning shared fields. (Every field is read
// before any is written.)
procedure TPS2VUCore.EmitLowerStore(Ft: Integer; Mask: Cardinal; const Src: TJitOp; Rotate: Boolean);
const
  Temps: array[0..3] of TJitReg = (jrT0, jrT1, jrT4, jrT5);
var
  Widths: array[0..3] of TJitWidth;
  Lanes: array[0..3] of Integer;
begin
  var J := FJit;
  FLowerDirect := True;
  if (Ft <= 0) or (Mask = 0) then
    Exit;
  KeepForget(Ft);
  var Count := 0;
  var K := 0;
  while K < 4 do
  begin
    if (Mask and FieldBit(K)) = 0 then
    begin
      Inc(K);
      Continue;
    end;
    Lanes[Count] := K;
    if not Rotate and not Odd(K) and ((Mask and FieldBit(K + 1)) <> 0) then
    begin
      Widths[Count] := jw64;
      J.Move(jw64, JReg(Temps[Count]), JMem(Src.Reg, Src.Disp + K * 4));
      Inc(K, 2);
    end
    else
    begin
      var C := K;
      if Rotate then
        C := (K + 1) and 3;
      Widths[Count] := jw32;
      J.Move(jw32, JReg(Temps[Count]), JMem(Src.Reg, Src.Disp + C * 4));
      Inc(K);
    end;
    Inc(Count);
  end;
  for var N := 0 to Count - 1 do
    J.Move(Widths[N], JMem(jrS0, Ft * 16 + Lanes[N] * 4), JReg(Temps[N]));
end;

// In a scheduled run, kept vector registers (see TJitAsm.VectorKeep) hold
// copies of the VF registers and ACC it read or wrote last, so that reading
// them again takes no load, nor waits for the store before it. Memory has
// every value too: a write anything else makes to a register drops its copy
// (KeepForget). Count: the slots (0: none).
procedure TPS2VUCore.KeepStart(Count: Integer);
begin
  FKeepCount := Min(Count, Length(FKeptReg));
  FKeepClock := 0;
  for var K := 0 to High(FKeptReg) do
    FKeptReg[K] := -1;
  for var R := 0 to High(FKeptSlot) do
    FKeptSlot[R] := -1;
end;

procedure TPS2VUCore.KeepForget(Reg: Integer);
begin
  if (Reg < 0) or (Reg > High(FKeptSlot)) then
    Exit;
  var Slot := FKeptSlot[Reg];
  if Slot < 0 then
    Exit;
  FKeptSlot[Reg] := -1;
  FKeptReg[Slot] := -1;
end;

// Reg's slot: its own, else a free one or the least recently used.
function TPS2VUCore.KeepSlot(Reg: Integer): Integer;
begin
  Result := FKeptSlot[Reg];
  if Result < 0 then
  begin
    for var K := 0 to FKeepCount - 1 do
      if FKeptReg[K] < 0 then
      begin
        Result := K;
        Break;
      end;
    if Result < 0 then
    begin
      Result := 0;
      for var K := 1 to FKeepCount - 1 do
        if FKeptUse[K] < FKeptUse[Result] then
          Result := K;
      FKeptSlot[FKeptReg[Result]] := -1;
    end;
    FKeptReg[Result] := Reg;
    FKeptSlot[Reg] := Result;
  end;
  Inc(FKeepClock);
  FKeptUse[Result] := FKeepClock;
end;

// VF[Reg] in memory (32: ACC).
function TPS2VUCore.VFOperand(Reg: Integer): TJitOp;
begin
  if Reg = 32 then
    Result := JMem(jrSelf, Integer(NativeInt(@S.ACC) - NativeInt(Self)))
  else
    Result := JMem(jrS0, Reg * 16);
end;

procedure TPS2VUCore.EmitLoadVF(Dst: TJitVector; Reg: Integer);
begin
  var J := FJit;
  if FKeepCount = 0 then
  begin
    J.VectorLoad(Dst, VFOperand(Reg));
    Exit;
  end;
  var Slot := FKeptSlot[Reg];
  if Slot >= 0 then
  begin
    Inc(FKeepClock);
    FKeptUse[Slot] := FKeepClock;
    J.VectorTake(Dst, Slot);
  end
  else
  begin
    J.VectorLoad(Dst, VFOperand(Reg));
    J.VectorKeep(KeepSlot(Reg), Dst);
  end;
end;

// Src's lanes in Lanes (bit K: lane K) to VF[Reg] (32: ACC), its copy the
// whole new value. (Src not jv1, which it may change.)
procedure TPS2VUCore.EmitStoreVF(Reg: Integer; Src: TJitVector; Lanes: Byte);
begin
  var J := FJit;
  var Target := VFOperand(Reg);
  if FKeepCount = 0 then
  begin
    J.VectorStore(Target, Src, Lanes);
    Exit;
  end;
  if Lanes <> 15 then
  begin
    var Slot := FKeptSlot[Reg];
    if Slot >= 0 then
      J.VectorTake(jv1, Slot)
    else
      J.VectorLoad(jv1, Target);
    J.VectorBlend(jv1, Src, Lanes);
    Src := jv1;
  end;
  J.VectorStore(Target, Src);
  J.VectorKeep(KeepSlot(Reg), Src);
end;

procedure TPS2VUCore.EmitPair(const P: TPS2VUPair);
begin
  var J := FJit;
  FEmitVectorResult := False;
  FLowerDirect := False;
  FAllowVectorResult := False;

  FAllowVectorResult := FVectorMemorySafe and J.HasVectors and (PS2RegisterMathNative(vrmAdd) <> nil);

  // A lower half calling a helper (which may change every vector register)
  // takes a register result from memory.
  var Spill :=
    not (VectorLowerNoCall(P.Lower, P.Upper)
    or ((FEmitMACSrc >= 0) and ((P.Lower and $80000000) = 0) and ((P.Lower shr 25) in [$14, $16..$18, $1A, $1B])));
  ProfileMark('upper');
  // Arithmetic calls the PS2 SIMD routines directly, without dispatching
  // an upper opcode on each visit. Both halves still read before commits.
  var U := P.Upper;
  var Funct := U and $3F;
  var Special := ((U shr 4) and $7C) or (U and 3);
  var IsAbs := (Funct >= $3C) and (Special = $1D);
  var IsMax := (Funct in [$10..$13, $1D, $2B]);
  var IsMin := (Funct in [$14..$17, $1F, $2F]);
  if EmitUpper(U) then
  begin
    // Upper arithmetic and NOP are fully accounted for.
    if FEmitVectorResult and Spill then
    begin
      J.VectorStore(JMem(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self))), jv0);
      FEmitVectorResult := False;
    end;
  end
  else if (Funct >= $3C) and (Special in [$10..$17]) then
  begin
    var Fs := Integer((U shr 11) and 31);
    var Ft := Integer((U shr 16) and 31);
    var Shift := 0;
    case Special and 3 of
      1:
        Shift := 4;
      2:
        Shift := 12;
      3:
        Shift := 15;
    end;
    var Value := JAddr(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self)));
    if Special < $14 then
      J.Call(@PS2Itof4, [JAddr(jrS0, Fs * 16), JImm(Shift), Value])
    else
      J.Call(@PS2Ftoi4, [JAddr(jrS0, Fs * 16), JImm(Shift), Value]);
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperReg) - NativeInt(Self))), JImm(Ft));
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperMask) - NativeInt(Self))), JImm((U shr 21) and 15));
  end
  else if (Funct >= $3C) and (Special = $1F) then
  begin
    var Fs := Integer((U shr 11) and 31);
    var Ft := Integer((U shr 16) and 31);
    var Clip := Integer(NativeInt(@S.Clip) - NativeInt(Self));
    var Count := Integer(NativeInt(@S.ClipQCount) - NativeInt(Self));
    J.Call(
      @PS2Clip3,
      [JAddr(jrS0, Fs * 16), JAddr(jrS0, Ft * 16), JAddr(jrSelf, Integer(NativeInt(@FJitClip) - NativeInt(Self)))]
    );
    J.Move(jw32, JT0, JMem(jrSelf, Clip));
    J.Shift(jsShl, jw32, jrT0, 6);
    J.Alu(jaOr, jw32, JT0, JMem(jrSelf, Integer(NativeInt(@FJitClip) - NativeInt(Self))));
    J.Alu(jaAnd, jw32, JT0, JImm($FFFFFF));
    J.Move(jw32, JMem(jrSelf, Clip), JT0);
    if FEmitClipSlot >= 0 then
    begin
      // In a scheduled run: the result and when it lands, for FinishFastFlags.
      J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FJitClipEvents[FEmitClipSlot].Value) - NativeInt(Self))), JT0);
      J.Move(jw64, JT3, JS1);
      J.Alu(jaAdd, jw64, JT3, JImm(FEmitClipIssue + 4));
      J.Move(jw64, JMem(jrSelf, Integer(NativeInt(@FJitClipEvents[FEmitClipSlot].Ready) - NativeInt(Self))), JT3);
    end
    else
    begin
      // The same four-cycle queue as the flags.
      var Full := J.NewLabel;
      J.Move(jw32, JT1, JMem(jrSelf, Count));
      J.Branch(jcGe, jw32, JT1, JImm(4), Full);
      J.Move(jw64, JT2, JT1);
      J.Shift(jsShl, jw64, jrT2, 2);
      J.Alu(jaAdd, jw64, JT2, JSelf);
      J.Move(jw32, JMem(jrT2, Integer(NativeInt(@S.ClipQValue[0]) - NativeInt(Self))), JT0);
      J.Move(jw64, JT3, JMem(jrSelf, Integer(NativeInt(@S.Cycles) - NativeInt(Self))));
      J.Alu(jaAdd, jw64, JT3, JImm(4));
      J.Shift(jsShl, jw32, jrT1, 3);
      J.Move(jw64, JT2, JSelf);
      J.Alu(jaAdd, jw64, JT2, JT1);
      J.Move(jw64, JMem(jrT2, Integer(NativeInt(@S.ClipQReady[0]) - NativeInt(Self))), JT3);
      J.Alu(jaAdd, jw32, JMem(jrSelf, Count), JImm(1));
      J.Bind(Full);
    end;
  end
  else if IsAbs or IsMax or IsMin then
  begin
    var Fs := Integer((U shr 11) and 31);
    var Ft := Integer((U shr 16) and 31);
    var Target := Integer((U shr 6) and 31);
    if IsAbs then
      Target := Ft;
    J.Move(jw64, JT6, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
    for var K := 0 to 3 do
    begin
      J.Move(jw32, JT0, JMem(jrT6, Fs * 16 + K * 4));
      if IsAbs then
        J.Alu(jaAnd, jw32, JT0, JImm($7FFFFFFF))
      else
      begin
        if Funct in [$1D, $1F] then
          J.Move(jw32, JT1, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))))
        else if Funct in [$2B, $2F] then
          J.Move(jw32, JT1, JMem(jrT6, Ft * 16 + K * 4))
        else
          J.Move(jw32, JT1, JMem(jrT6, Ft * 16 + Integer(U and 3) * 4));
        // PS2FloatKey: invert the magnitude of negative values, retaining
        // their sign bit. Signed comparison also distinguishes -0 from +0.
        J.Move(jw32, JT2, JT0);
        J.Move(jw32, JT3, JT1);
        var PositiveA := J.NewLabel;
        var PositiveB := J.NewLabel;
        var Selected := J.NewLabel;
        J.Branch(jcGe, jw32, JT2, JImm(0), PositiveA);
        J.Alu(jaXor, jw32, JT2, JImm($7FFFFFFF));
        J.Bind(PositiveA);
        J.Branch(jcGe, jw32, JT3, JImm(0), PositiveB);
        J.Alu(jaXor, jw32, JT3, JImm($7FFFFFFF));
        J.Bind(PositiveB);
        if IsMax then
          J.Branch(jcGe, jw32, JT2, JT3, Selected)
        else
          J.Branch(jcLe, jw32, JT2, JT3, Selected);
        J.Move(jw32, JT0, JT1);
        J.Bind(Selected);
      end;
      J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperValue) - NativeInt(Self)) + K * 4), JT0);
    end;
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperReg) - NativeInt(Self))), JImm(Target));
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@FUpperMask) - NativeInt(Self))), JImm((U shr 21) and 15));
  end
  else if not ((Funct >= $3C) and (Special = $2F)) then
  begin
    // (The helper works out the status from S.Status: an event it makes is
    // not lazy, see EmitBody.)
    EmitLazyFlush;
    J.Call(@TPS2VUCore.Upper, [JSelf, JImm(U), JImm(1)]);
  end;
  ProfileMark('lower');
  if (U and $80000000) <> 0 then
    J.Move(jw32, JMem(jrSelf, Integer(NativeInt(@S.I) - NativeInt(Self))), JImm(P.Lower))
  else
  begin
    var Op := P.Lower;
    if EmitLower(Op) then
      Exit;
    var D := -1;
    var Is_ := Integer((Op shr 11) and 15);
    var It := Integer((Op shr 16) and 15);
    var Id := Integer((Op shr 6) and 15);
    var Alu := jaAdd;
    var Imm := 0;
    var Immediate := False;
    var Truncate16 := True;
    if (Op and $80000000) <> 0 then
      case Op and $3F of
        $30:
          D := Id;
        $31:
          begin
            D := Id;
            Alu := jaSub;
          end;
        $32:
          begin
            D := It;
            Immediate := True;
            Imm := Integer((Op shr 6) and 31);
            if Imm >= 16 then
              Dec(Imm, 32);
          end;
        $34:
          begin
            D := Id;
            Alu := jaAnd;
            Truncate16 := False;
          end;
        $35:
          begin
            D := Id;
            Alu := jaOr;
            Truncate16 := False;
          end;
      end
    else if (Op shr 25) in [$08, $09] then
    begin
      D := It;
      Immediate := True;
      Imm := Integer((Op and $7FF) or ((Op shr 10) and $7800));
      if (Op shr 25) = $09 then
        Alu := jaSub;
    end;
    if D > 0 then
    begin
      J.Move(jw64, JT2, JMem(jrSelf, Integer(NativeInt(@FVI) - NativeInt(Self))));
      J.Move(jw32, JT0, JMem(jrT2, Is_ * 4));
      if Immediate then
        J.Alu(Alu, jw32, JT0, JImm(Imm))
      else
        J.Alu(Alu, jw32, JT0, JMem(jrT2, It * 4));
      if Truncate16 then
        J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
      J.Move(jw32, JMem(jrT2, D * 4), JT0);
    end
    else if (D < 0) and ((Op shr 25) in [$00, $01, $04, $05]) then
    begin
      var Kind := Op shr 25;
      // (LQ to VF00 or of no fields, SQ/ISW of no fields, ILW to VI00: no
      // effect at all.)
      if ((Kind = $00) and ((((Op shr 16) and 31) = 0) or (((Op shr 21) and 15) = 0)))
        or ((Kind in [$01, $05]) and (((Op shr 21) and 15) = 0))
        or ((Kind = $04) and (It = 0)) then
        Exit;
      var Base := Is_;
      if Kind = $01 then
        Base := It;
      var Imm11 := Integer(Op and $7FF);
      if Imm11 >= $400 then
        Dec(Imm11, $800);
      J.Move(jw64, JT2, JMem(jrSelf, Integer(NativeInt(@FVI) - NativeInt(Self))));
      J.Move(jw32, JT0, JMem(jrT2, Base * 4));
      J.Alu(jaAdd, jw32, JT0, JImm(Imm11));
      J.Shift(jsShl, jw32, jrT0, 4);
      J.Alu(jaAnd, jw32, JT0, JImm(FDataMask));
      J.Move(jw64, JT3, JMem(jrSelf, Integer(NativeInt(@FData) - NativeInt(Self))));
      J.Alu(jaAdd, jw64, JT3, JT0);
      var Mask := (Op shr 21) and 15;
      case Kind of
        $00:
          EmitLowerStore(Integer((Op shr 16) and 31), Mask, JMem(jrT3, 0), False);
        $01:
          begin
          // Disjoint register and data memory: copy the old VF before
          // the upper result in jv0 commits. Partial masks keep lane stores.
            if (FIndex = 1) and (Mask = $F) and FVectorMemorySafe and J.HasVectors then
            begin
              J.VectorLoad(jv2, JMem(jrS0, Integer((Op shr 11) and 31) * 16));
              J.VectorStore(JMem(jrT3, 0), jv2);
              Exit;
            end;
            J.Move(jw64, JT4, JMem(jrSelf, Integer(NativeInt(@FVF) - NativeInt(Self))));
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
              begin
                J.Move(jw32, JT0, JMem(jrT4, Integer((Op shr 11) and 31) * 16 + K * 4));
                J.Move(jw32, JMem(jrT3, K * 4), JT0);
              end;
          end;
        $04:
          if It <> 0 then
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
              begin
                J.Move(jw32, JT0, JMem(jrT3, K * 4));
                J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
                J.Move(jw32, JMem(jrT2, It * 4), JT0);
                Break;
              end;
        $05:
          begin
            J.Move(jw32, JT0, JMem(jrT2, It * 4));
            J.Alu(jaAnd, jw32, JT0, JImm($FFFF));
            for var K := 0 to 3 do
              if (Mask and (8 shr K)) <> 0 then
                J.Move(jw32, JMem(jrT3, K * 4), JT0);
          end;
      end;
    end
    else if D < 0 then
    begin
      // (DIV/SQRT/RSQRT change S.Status.)
      EmitLazyFlush;
      J.Call(@TPS2VUCore.Lower, [JSelf, JImm(Op)]);
    end;
  end;
end;

procedure TPS2VUCore.Reset;
begin
  NoteCodeWritten;
  Inc(Touched);
  S := Default(TPS2VUState);
  FillChar(FReady, SizeOf(FReady), 0);
  FillChar(FReadyAny, SizeOf(FReadyAny), 0);
  FBlockMap.RestoredDeadline := 0;
  FKickPending := False;
  S.Q := $3F800000;
  S.R := $3F800000;
  FVF[0].UW[0] := 0;
  FVF[0].UW[1] := 0;
  FVF[0].UW[2] := 0;
  FVF[0].UW[3] := $3F800000;
end;

procedure TPS2VUCore.SetFlags(const R: TPS2Reg128; Dest: Cardinal; Flags: Cardinal);
begin
  // MAC: Z bits 0..3, S 4..7, U 8..11, O 12..15; bit 3 of each group is x.
  // Flags: bit K overflow and bit K + 4 underflow of field K.
  var M: Cardinal := 0;
  for var K := 0 to 3 do
    if (Dest and FieldBit(K)) <> 0 then
    begin
      var V := R.UW[K];
      var B := Cardinal(3 - K);
      if (V and $7FFFFFFF) = 0 then
        M := M or (Cardinal(1) shl B);
      if (V and $80000000) <> 0 then
        M := M or (Cardinal(1) shl (B + 4));
      if (Flags and (Cardinal(16) shl K)) <> 0 then
        M := M or (Cardinal(1) shl (B + 8));
      if (Flags and (Cardinal(1) shl K)) <> 0 then
        M := M or (Cardinal(1) shl (B + 12));
    end;
  S.MAC := M;
  var St := S.Status and $FF0;
  if (M and $F) <> 0 then
    St := St or 1;
  if (M and $F0) <> 0 then
    St := St or 2;
  if (M and $F00) <> 0 then
    St := St or 4;
  if (M and $F000) <> 0 then
    St := St or 8;
  St := St or ((St and $F) shl 6);
  S.Status := St;
end;

procedure TPS2VUCore.CommitVF(Reg: Integer; const V: TPS2Reg128; Dest: Cardinal);
begin
  if Reg = 0 then
    Exit;
  for var K := 0 to 3 do
    if (Dest and FieldBit(K)) <> 0 then
      FVF[Reg].UW[K] := V.UW[K];
end;

// Upper (FMAC) instruction: computes into FUpperValue/FUpperReg; the ACC
// forms write ACC directly at commit time (register 32).
procedure TPS2VUCore.Upper(Op: Cardinal; Micro: Boolean);
type
  TKind = (ukInvalid, ukAdd, ukSub, ukMul, ukMadd, ukMsub, ukMax, ukMin, ukItof, ukFtoi, ukAbs, ukOpMula, ukOpMsub);
  // The second operand: ft's own field, ft's broadcast field, Q or I.

  TSource = (usVector, usBroadcast, usQ, usI);
var
  R: TPS2Reg128;
begin
  var Dest := (Op shr 21) and $F;
  var Ft := Integer((Op shr 16) and 31);
  var Fs := Integer((Op shr 11) and 31);
  var Fd := Integer((Op shr 6) and 31);
  FUpperReg := -1;
  var Funct := Op and $3F;
  var Target := Fd;
  var Kind := ukInvalid;
  var Source := usBroadcast;
  if Funct >= $3C then
  begin
    // Special: ACC forms and conversions; index = fd field << 2 | bc.
    Funct := ((Op shr 4) and $7C) or (Op and 3);
    Target := 32;
    case Funct of
      $00..$03:
        Kind := ukAdd;
      $04..$07:
        Kind := ukSub;
      $08..$0B:
        Kind := ukMadd;
      $0C..$0F:
        Kind := ukMsub;
      $10..$13:
        begin
          Kind := ukItof;
          Target := Ft;
        end;
      $14..$17:
        begin
          Kind := ukFtoi;
          Target := Ft;
        end;
      $18..$1B:
        Kind := ukMul;
      $1C:
        begin
          Kind := ukMul;
          Source := usQ;
        end;
      $1D:
        begin
          Kind := ukAbs;
          Target := Ft;
        end;
      $1E:
        begin
          Kind := ukMul;
          Source := usI;
        end;
      $1F:
        begin
          // CLIP: |fs.xyz| against |ft.w|.
          var W := Abs(EEFloatIn(FVF[Ft].UW[3]));
          var C: Cardinal := 0;
          for var K := 0 to 2 do
          begin
            var V := EEFloatIn(FVF[Fs].UW[K]);
            if V > W then
              C := C or (Cardinal(1) shl (K * 2));
            if V < -W then
              C := C or (Cardinal(2) shl (K * 2));
          end;
          S.Clip := ((S.Clip shl 6) or C) and $FFFFFF;
          if Micro and (S.ClipQCount < 4) then
          begin
            S.ClipQValue[S.ClipQCount] := S.Clip;
            S.ClipQReady[S.ClipQCount] := S.Cycles + 4;
            Inc(S.ClipQCount);
          end
          else if not Micro then
            S.ClipBase := S.Clip;
          Exit;
        end;
      $20, $22, $24, $26:
        begin
          if Funct >= $24 then
            Kind := ukSub
          else
            Kind := ukAdd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $21, $23, $25, $27:
        begin
          if Funct >= $24 then
            Kind := ukMsub
          else
            Kind := ukMadd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $28, $29, $2A, $2C, $2D:
        begin
          case Funct of
            $28:
              Kind := ukAdd;
            $29:
              Kind := ukMadd;
            $2A:
              Kind := ukMul;
            $2C:
              Kind := ukSub;
          else
            Kind := ukMsub;
          end;
          Source := usVector;
        end;
      $2E:
        begin
          // OPMULA: ACC.xyz = fs.yzx * ft.zxy
          Kind := ukOpMula;
          Dest := Dest and $E;
        end;
    end;
  end
  else
    case Funct of
      $00..$03:
        Kind := ukAdd;
      $04..$07:
        Kind := ukSub;
      $08..$0B:
        Kind := ukMadd;
      $0C..$0F:
        Kind := ukMsub;
      $10..$13:
        Kind := ukMax;
      $14..$17:
        Kind := ukMin;
      $18..$1B:
        Kind := ukMul;
      $1C:
        begin
          Kind := ukMul;
          Source := usQ;
        end;
      $1D:
        begin
          Kind := ukMax;
          Source := usI;
        end;
      $1E:
        begin
          Kind := ukMul;
          Source := usI;
        end;
      $1F:
        begin
          Kind := ukMin;
          Source := usI;
        end;
      $20, $22, $24, $26:
        begin
          if Funct >= $24 then
            Kind := ukSub
          else
            Kind := ukAdd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $21, $23, $25, $27:
        begin
          if Funct >= $24 then
            Kind := ukMsub
          else
            Kind := ukMadd;
          if (Funct and 2) = 0 then
            Source := usQ
          else
            Source := usI;
        end;
      $28..$2D:
        begin
          case Funct of
            $28:
              Kind := ukAdd;
            $29:
              Kind := ukMadd;
            $2A:
              Kind := ukMul;
            $2B:
              Kind := ukMax;
            $2C:
              Kind := ukSub;
          else
            Kind := ukMsub;
          end;
          Source := usVector;
        end;
      $2E:
        begin
          // OPMSUB: fd.xyz = ACC.xyz - fs.yzx * ft.zxy
          Kind := ukOpMsub;
          Dest := Dest and $E;
        end;
      $2F:
        begin
          Kind := ukMin;
          Source := usVector;
        end;
    end;
  // NOP and undefined instruction encodings have no upper result.
  if Kind = ukInvalid then
    Exit;
  // The arithmetic on all four fields at once (the fields not written are
  // dropped, with their flags); the rest field by field.
  var A := PPS2Reg128(@FVF[Fs]);
  var B := PPS2Reg128(@FVF[Ft]);
  var Other: TPS2Reg128;
  case Source of
    usVector:
      Other := B^;
    usBroadcast:
      begin
        var V := B.UW[Op and 3];
        Other.UW[0] := V;
        Other.UW[1] := V;
        Other.UW[2] := V;
        Other.UW[3] := V;
      end;
    usQ:
      begin
        Other.UW[0] := S.Q;
        Other.UW[1] := S.Q;
        Other.UW[2] := S.Q;
        Other.UW[3] := S.Q;
      end;
    usI:
      begin
        Other.UW[0] := S.I;
        Other.UW[1] := S.I;
        Other.UW[2] := S.I;
        Other.UW[3] := S.I;
      end;
  end;
  var F: Cardinal := 0;
  case Kind of
    ukAdd:
      PS2Add4(A^, Other, R, F);
    ukSub:
      begin
        Other.Lo := Other.Lo xor UInt64($8000000080000000);
        Other.Hi := Other.Hi xor UInt64($8000000080000000);
        PS2Add4(A^, Other, R, F);
      end;
    ukMul:
      PS2Mul4(A^, Other, R, F);
    ukMadd, ukMsub, ukOpMula, ukOpMsub:
      begin
        var M: TPS2Reg128;
        if Kind in [ukOpMula, ukOpMsub] then
        begin
          // fs.yzx * ft.zxy.
          var X: TPS2Reg128;
          X.UW[0] := A.UW[1];
          X.UW[1] := A.UW[2];
          X.UW[2] := A.UW[0];
          X.UW[3] := 0;
          Other.UW[0] := B.UW[2];
          Other.UW[1] := B.UW[0];
          Other.UW[2] := B.UW[1];
          Other.UW[3] := 0;
          PS2Mul4(X, Other, M, F);
        end
        else
          PS2Mul4(A^, Other, M, F);
        if Kind = ukOpMula then
          R := M
        else
        begin
          if Kind <> ukMadd then
          begin
            M.Lo := M.Lo xor UInt64($8000000080000000);
            M.Hi := M.Hi xor UInt64($8000000080000000);
          end;
          var F2: Cardinal;
          PS2Add4(S.ACC, M, R, F2);
          F := F or F2;
        end;
      end;
  else
    R := Default(TPS2Reg128);
    for var K := 0 to 3 do
    begin
      if (Dest and FieldBit(K)) = 0 then
        Continue;
      var V := Other.UW[K];
      case Kind of
        ukMax:
          if PS2FloatKey(A.UW[K]) >= PS2FloatKey(V) then
            R.UW[K] := A.UW[K]
          else
            R.UW[K] := V;
        ukMin:
          if PS2FloatKey(A.UW[K]) <= PS2FloatKey(V) then
            R.UW[K] := A.UW[K]
          else
            R.UW[K] := V;
        ukItof:
          begin
            // ITOF0/4/12/15: fixed point to float.
            var Scale: Double := 1;
            case Funct of
              $11:
                Scale := 1 / 16;
              $12:
                Scale := 1 / 4096;
              $13:
                Scale := 1 / 32768;
            end;
            var X: Single := A.SW[K] * Scale;
            R.UW[K] := PCardinal(@X)^;
          end;
        ukFtoi:
          begin
            var Scale: Double := 1;
            case Funct of
              $15:
                Scale := 16;
              $16:
                Scale := 4096;
              $17:
                Scale := 32768;
            end;
            var D := EEFloatIn(A.UW[K]) * Scale;
            if D >= 2147483647.0 then
              R.UW[K] := $7FFFFFFF
            else if D <= -2147483648.0 then
              R.UW[K] := $80000000
            else
              R.SW[K] := Trunc(D);
          end;
        ukAbs:
          R.UW[K] := A.UW[K] and $7FFFFFFF;
      end;
    end;
    FUpperReg := Target;
    FUpperValue := R;
    FUpperMask := Dest;
    Exit;
  end;
  SetFlags(R, Dest, F);
  FUpperReg := Target;
  FUpperValue := R;
  FUpperMask := Dest;
end;

function TPS2VUCore.DataAddress(Base: Cardinal): PPS2Reg128;
begin
  Result := PPS2Reg128(FData + ((Base shl 4) and FDataMask));
end;

function SignExt11(V: Cardinal): Integer; inline;
begin
  Result := Integer(V and $7FF);
  if (Result and $400) <> 0 then
    Result := Result - $800;
end;

// EFU arithmetic as ps2autotests' vu/lower/efu shows on hardware: sums and
// squares go through the PS2 multiplier and adder in order; roots and
// reciprocals round to nearest (the EE FPU's DIV.S/SQRT.S steps); a zero
// divisor gives the largest value. A few roots and reciprocals still differ
// from hardware by one unit in the last place.
function EFUSum(A, B: Cardinal): Cardinal; inline;
var
  Flags: Cardinal;
begin
  Result := PS2FloatAdd(A, B, Flags);
end;

function EFUSquares(const V: TPS2Reg128): Cardinal;
var
  Flags: Cardinal;
begin
  Result := EFUSum(EFUSum(PS2FloatMul(V.UW[0], V.UW[0], Flags), PS2FloatMul(V.UW[1], V.UW[1], Flags)),
    PS2FloatMul(V.UW[2], V.UW[2], Flags));
end;

// The square root of |V|; exponent-zero inputs give +0.
function EFURoot(V: Cardinal): Cardinal;
begin
  if (V and $7F800000) = 0 then
    Exit(0);
  Result := PS2FloatNearest(Sqrt(EEFloatIn(V and $7FFFFFFF)));
end;

// 1/V; a zero V gives the largest value, signed like V when Signed.
function EFUReciprocal(V: Cardinal; Signed: Boolean): Cardinal;
begin
  if (V and $7F800000) = 0 then
    if Signed then
      Exit((V and $80000000) or $7FFFFFFF)
    else
      Exit($7FFFFFFF);
  Result := PS2FloatNearest(1 / EEFloatIn(V));
end;

// Squaring a 24-bit significand never loses the multiplier's exceptional
// low bit: when the first mantissa is zero, the identical second operand
// has no negative digit. The 48-bit product gives the truncated square.
function EFUSquareLane(V: Cardinal): Cardinal; inline;
begin
  var E := Integer((V shr 23) and $FF);
  if E < 64 then
    Exit(0);
  if E > 191 then
    Exit($7FFFFFFF);
  var M := (V and $7FFFFF) or $800000;
  var Product := UInt64(M) * M;
  var Carry := Integer(Product shr 47);
  E := 2 * E - 127 + Carry;
  if E > 255 then
    Exit($7FFFFFFF);
  Result := (Cardinal(E) shl 23) or (Cardinal(Product shr (23 + Carry)) and $7FFFFF);
end;

// The inputs are canonical, nonnegative PS2 numbers. Only the smaller
// summand has bits below the larger one's unit; those bits cannot carry
// into the truncated sum, including when its significand overflows.
function EFUAddSquares(A, B: Cardinal): Cardinal; inline;
begin
  if B > A then
  begin
    var T := A;
    A := B;
    B := T;
  end;
  if B = 0 then
    Exit(A);
  var E := A shr 23;
  var Distance := E - (B shr 23);
  if Distance >= 24 then
    Exit(A);
  var M := ((A and $7FFFFF) or $800000) + (((B and $7FFFFF) or $800000) shr Distance);
  if M >= $1000000 then
  begin
    if E = 255 then
      Exit($7FFFFFFF);
    Inc(E);
    M := M shr 1;
  end;
  Result := (E shl 23) or (M and $7FFFFF);
end;

function EFUSquaredLength(const V: TPS2Reg128): Cardinal; inline;
begin
  var XY := EFUAddSquares(EFUSquareLane(V.UW[0]), EFUSquareLane(V.UW[1]));
  Result := EFUAddSquares(XY, EFUSquareLane(V.UW[2]));
end;

function EFULength(V: PPS2Reg128): Cardinal;
begin
  Result := EFURoot(EFUSquaredLength(V^));
end;

function EFUInverseLength(V: PPS2Reg128): Cardinal;
begin
  // Round the root to the guest format before taking its reciprocal.
  Result := EFUReciprocal(EFULength(V), False);
end;

// Lower instruction: integer results land at once; VF results in
// FLowerValue for the commit.
procedure TPS2VUCore.Lower(Op: Cardinal);
begin
  FLowerReg := -1;
  if (Op and $80000000) <> 0 then
  begin
    var Funct := Op and $3F;
    var It := Integer((Op shr 16) and 15);
    var Is_ := Integer((Op shr 11) and 15);
    var Id := Integer((Op shr 6) and 15);
    case Funct of
      $30:
        if Id <> 0 then
          FVI[Id] := Word(Integer(FVI[Is_]) + Integer(FVI[It]));
      $31:
        if Id <> 0 then
          FVI[Id] := Word(Integer(FVI[Is_]) - Integer(FVI[It]));
      $32:
        if It <> 0 then
        begin
          var Imm := Integer((Op shr 6) and 31);
          if (Imm and 16) <> 0 then
            Imm := Imm - 32;
          FVI[It] := Word(Integer(FVI[Is_]) + Imm);
        end;
      $34:
        if Id <> 0 then
          FVI[Id] := FVI[Is_] and FVI[It];
      $35:
        if Id <> 0 then
          FVI[Id] := FVI[Is_] or FVI[It];
      $3C..$3F:
        LowerSpecial(Op);
    end;
    Exit;
  end;
  var Dest := (Op shr 21) and $F;
  var It := Integer((Op shr 16) and 31);
  var Is_ := Integer((Op shr 11) and 31);
  var Imm11 := SignExt11(Op);
  case Op shr 25 of
    $00: // LQ
      begin
        FLowerValue := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11))^;
        FLowerReg := It;
        FLowerMask := Dest;
      end;
    $01: // SQ
      begin
        var P := DataAddress(Cardinal(Integer(FVI[It and 15]) + Imm11));
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVF[Is_].UW[K];
      end;
    $04: // ILW
      begin
        var P := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11));
        if (It and 15) <> 0 then
          for var K := 0 to 3 do
            if (Dest and FieldBit(K)) <> 0 then
            begin
              FVI[It and 15] := P.UW[K] and $FFFF;
              Break;
            end;
      end;
    $05: // ISW
      begin
        var P := DataAddress(Cardinal(Integer(FVI[Is_ and 15]) + Imm11));
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVI[It and 15] and $FFFF;
      end;
    $08, $09: // IADDIU, ISUBIU
      if (It and 15) <> 0 then
      begin
        var Imm := (Op and $7FF) or ((Op shr 10) and $7800);
        if (Op shr 25) = $08 then
          FVI[It and 15] := Word(Integer(FVI[Is_ and 15]) + Integer(Imm))
        else
          FVI[It and 15] := Word(Integer(FVI[Is_ and 15]) - Integer(Imm));
      end;
    $10:
      FVI[1] := Ord((FClipVisible and $FFFFFF) = (Op and $FFFFFF));
    $11:
      begin
        S.Clip := Op and $FFFFFF;
        S.ClipBase := S.Clip;
        S.ClipQCount := 0;
        FClipVisible := S.Clip;
      end;
    $12:
      FVI[1] := Ord((FClipVisible and Op and $FFFFFF) <> 0);
    $13:
      FVI[1] := Ord(((FClipVisible or Op) and $FFFFFF) = $FFFFFF);
    $14:
      if (It and 15) <> 0 then
        FVI[It and 15] := Ord((S.StatusBase and $FFF) = (((Op shr 10) and $800) or (Op and $7FF)));
    $15:
      begin
        var Sticky := (((Op shr 10) and $800) or (Op and $7FF)) and $FC0;
        S.Status := (S.Status and $3F) or Sticky;
        S.StatusBase := (S.StatusBase and $3F) or Sticky;
        for var K := 0 to S.FlagQCount - 1 do
          S.FlagQStatus[K] := (S.FlagQStatus[K] and $3F) or Sticky;
      end;
    $16:
      if (It and 15) <> 0 then
        FVI[It and 15] := S.StatusBase and (((Op shr 10) and $800) or (Op and $7FF));
    $17:
      if (It and 15) <> 0 then
        FVI[It and 15] := (S.StatusBase or (((Op shr 10) and $800) or (Op and $7FF))) and $FFF;
    $18:
      if (It and 15) <> 0 then
        FVI[It and 15] := Ord((S.MACBase and $FFFF) = (FVI[Is_ and 15] and $FFFF));
    $1A:
      if (It and 15) <> 0 then
        FVI[It and 15] := S.MACBase and FVI[Is_ and 15] and $FFFF;
    $1B:
      if (It and 15) <> 0 then
        FVI[It and 15] := (S.MACBase or FVI[Is_ and 15]) and $FFFF;
    $1C:
      if (It and 15) <> 0 then
        FVI[It and 15] := FClipVisible and $FFF;
    $20, $21, $28, $29, $2C, $2D, $2E, $2F:
      begin
        var Take: Boolean;
        var A := SmallInt(Word(FVI[Is_ and 15]));
        var B := SmallInt(Word(FVI[It and 15]));
        if (Is_ and 15) = FBranchReg then
          A := SmallInt(Word(FBranchOld));
        if (It and 15) = FBranchReg then
          B := SmallInt(Word(FBranchOld));
        case Op shr 25 of
          $20, $21:
            Take := True;
          $28:
            Take := Word(A) = Word(B);
          $29:
            Take := Word(A) <> Word(B);
          $2C:
            Take := A < 0;
          $2D:
            Take := A > 0;
          $2E:
            Take := A <= 0;
        else
          Take := A >= 0;
        end;
        if (Op shr 25) = $21 then
        begin
          if (It and 15) <> 0 then
            FVI[It and 15] := ((S.TPC + 16) shr 3) and $FFFF;
        end;
        if Take then
        begin
          S.BranchPending := True;
          S.BranchTarget := Cardinal(Integer(S.TPC) + 8 + Imm11 * 8) and FCodeMask;
        end;
      end;
    $24, $25: // JR, JALR
      begin
        var Target := (FVI[Is_ and 15] * 8) and FCodeMask;
        if ((Op shr 25) = $25) and ((It and 15) <> 0) then
          FVI[It and 15] := ((S.TPC + 16) shr 3) and $FFFF;
        S.BranchPending := True;
        S.BranchTarget := Target;
      end;
  end;
end;

procedure TPS2VUCore.LowerSpecial(Op: Cardinal);
begin
  var Index := ((Op shr 4) and $7C) or (Op and 3);
  var Dest := (Op shr 21) and $F;
  var Ft := Integer((Op shr 16) and 31);
  var Fs := Integer((Op shr 11) and 31);
  var Fsf := Integer((Op shr 21) and 3);
  var Ftf := Integer((Op shr 23) and 3);
  case Index of
    $30: // MOVE
      begin
        FLowerValue := FVF[Fs];
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $31: // MR32
      begin
        var A := FVF[Fs];
        FLowerValue.UW[0] := A.UW[1];
        FLowerValue.UW[1] := A.UW[2];
        FLowerValue.UW[2] := A.UW[3];
        FLowerValue.UW[3] := A.UW[0];
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $34, $36: // LQI, LQD (fs field holds the integer register)
      begin
        var R := Fs and 15;
        if Index = $36 then
        begin
          if R <> 0 then
            FVI[R] := Word(Integer(FVI[R]) - 1);
          FLowerValue := DataAddress(FVI[R])^;
        end
        else
        begin
          FLowerValue := DataAddress(FVI[R])^;
          if R <> 0 then
            FVI[R] := Word(Integer(FVI[R]) + 1);
        end;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $35, $37: // SQI, SQD: fs is the VF, ft the integer register
      begin
        var R := Ft and 15;
        if (Index = $37) and (R <> 0) then
          FVI[R] := Word(Integer(FVI[R]) - 1);
        var P := DataAddress(FVI[R]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVF[Fs].UW[K];
        if (Index = $35) and (R <> 0) then
          FVI[R] := Word(Integer(FVI[R]) + 1);
      end;
    $38, $39, $3A: // DIV, SQRT, RSQRT -> Q
      begin
        // The divider takes one operation at a time: a new one waits for
        // the previous result.
        if S.QDelay > 0 then
        begin
          S.Q := S.PendingQ;
          S.QDelay := 0;
        end;
        var A := FVF[Fs].UW[Fsf];
        var B := FVF[Ft].UW[Ftf];
        var R: Cardinal;
        S.Status := S.Status and not Cardinal($30);
        case Index of
          $38:
            if (B and $7F800000) = 0 then
            begin
              if (A and $7F800000) = 0 then
                S.Status := S.Status or $410
              else
                S.Status := S.Status or $820;
              R := ((A xor B) and $80000000) or $7FFFFFFF;
            end
            else
            begin
              var D := EEFloatIn(A) / EEFloatIn(B);
              var F: Single := D;
              R := PCardinal(@F)^;
              if (A and $7F800000) = 0 then
                R := (A xor B) and $80000000;
            end;
          $39:
            begin
              if (B and $80000000) <> 0 then
                S.Status := S.Status or $410;
              if (B and $7F800000) = 0 then
                R := 0
              else
              begin
                var F: Single := Sqrt(Abs(EEFloatIn(B)));
                R := PCardinal(@F)^;
              end;
            end;
        else
          begin
            if (B and $7F800000) = 0 then
            begin
              S.Status := S.Status or $820;
              R := (A and $80000000) or $7FFFFFFF;
            end
            else
            begin
              if (B and $80000000) <> 0 then
                S.Status := S.Status or $410;
              var F: Single := EEFloatIn(A) / Sqrt(Abs(EEFloatIn(B)));
              R := PCardinal(@F)^;
              if (A and $7F800000) = 0 then
                R := A and $80000000;
            end;
          end;
        end;
        S.PendingQ := R;
        if Index = $3A then
          S.QDelay := 13
        else
          S.QDelay := 7;
      end;
    $3B: // WAITQ
      if S.QDelay > 0 then
      begin
        S.Q := S.PendingQ;
        S.QDelay := 0;
      end;
    $3C: // MTIR
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVF[Fs].UW[Fsf] and $FFFF;
    $3D: // MFIR
      begin
        var V := Cardinal(Integer(SmallInt(Word(FVI[Fs and 15]))));
        for var K := 0 to 3 do
          FLowerValue.UW[K] := V;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $3E: // ILWR
      if (Ft and 15) <> 0 then
      begin
        var P := DataAddress(FVI[Fs and 15]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
          begin
            FVI[Ft and 15] := P.UW[K] and $FFFF;
            Break;
          end;
      end;
    $3F: // ISWR
      begin
        var P := DataAddress(FVI[Fs and 15]);
        for var K := 0 to 3 do
          if (Dest and FieldBit(K)) <> 0 then
            P.UW[K] := FVI[Ft and 15] and $FFFF;
      end;
    $40, $41: // RNEXT, RGET
      begin
        if Index = $40 then
        begin
          // 23-bit generator (x^23 + x^5 + 1 style feedback).
          var X := S.R and $7FFFFF;
          var Bit := ((X shr 4) xor (X shr 22)) and 1;
          S.R := $3F800000 or (((X shl 1) or Bit) and $7FFFFF);
        end;
        for var K := 0 to 3 do
          FLowerValue.UW[K] := S.R;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $42:
      S.R := $3F800000 or (FVF[Fs].UW[Fsf] and $7FFFFF);
    $43:
      S.R := $3F800000 or ((S.R xor FVF[Fs].UW[Fsf]) and $7FFFFF);
    $64: // MFP
      begin
        for var K := 0 to 3 do
          FLowerValue.UW[K] := S.P;
        FLowerReg := Ft;
        FLowerMask := Dest;
      end;
    $68: // XTOP
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVI[16 + 10];
    $69: // XITOP
      if (Ft and 15) <> 0 then
        FVI[Ft and 15] := FVI[16 + 11];
    $6C: // XGKICK
      if Assigned(FOnKick) then
        StartKick((FVI[Fs and 15] * 16) and FDataMask);
    $70..$7E: // EFU -> P
      begin
        var V := FVF[Fs];
        var F := V.UW[Fsf];
        var R: Cardinal := 0;
        case Index of
          $70:
            R := EFUSquares(V);                                // ESADD
            $71:
            R := EFUReciprocal(EFUSquares(V), False);          // ERSADD
            $72:
            R := EFURoot(EFUSquares(V));                       // ELENG
            $73:
            R := EFUReciprocal(EFURoot(EFUSquares(V)), False); // ERLENG
            $76:
            R := EFUSum(EFUSum(EFUSum(V.UW[0], V.UW[1]), V.UW[2]), V.UW[3]); // ESUM
            $78:
            R := EFURoot(F);                                   // ESQRT
            $79:
            R := EFUReciprocal(EFURoot(F), False);             // ERSQRT
            $7A:
            R := EFUReciprocal(F, True);                       // ERCPR
            $74, $75, $7C..$7E:
            begin
              // EATAN, ESIN and EEXP: host functions, not the EFU's series.
              var X := EEFloatIn(V.UW[0]);
              var D: Double := 0;
              case Index of
                $74:
                  if X <> 0 then
                    D := ArcTan(EEFloatIn(V.UW[1]) / X);
                $75:
                  if X <> 0 then
                    D := ArcTan(EEFloatIn(V.UW[2]) / X);
                $7C:
                  D := Sin(EEFloatIn(F));
                $7D:
                  D := ArcTan(EEFloatIn(F));
                $7E:
                  D := Exp(-EEFloatIn(F));
              end;
              var H: Single := D;
              R := PCardinal(@H)^;
            end;
        end;
        if Index = $7B then
        begin
          if S.PDelay > 0 then
          begin
            S.P := S.PendingP;
            S.PDelay := 0;
          end;
        end
        else
        begin
          S.PendingP := R;
          S.PDelay := 12;
        end;
      end;
  end;
end;

function TPS2VUCore.Macro(Op: Cardinal): Boolean;
begin
  // COP2 macro: upper-style operations and the lower ones VU0 offers.
  Inc(Touched);
  Result := True;
  if FUseJit and MacroNative(Op) then
    Exit;
  var Funct := Op and $3F;
  FUpperReg := -1;
  FLowerReg := -1;
  // Macro-mode Q results are available at once.
  case Funct of
    $30..$35:
      begin
        Lower(Op or $80000000);
        Exit;
      end;
    $38, $39:
      Exit(True);
    $3C..$3F:
      begin
        var Index := ((Op shr 4) and $7C) or (Op and 3);
        if Index >= $30 then
        begin
          LowerSpecial(Op);
          if S.QDelay > 0 then
          begin
            S.Q := S.PendingQ;
            S.QDelay := 0;
          end;
          if FLowerReg >= 0 then
            CommitVF(FLowerReg, FLowerValue, FLowerMask);
          Exit;
        end;
      end;
  end;
  Upper(Op, False);
  if FUpperReg = 32 then
  begin
    for var K := 0 to 3 do
      if (FUpperMask and FieldBit(K)) <> 0 then
        S.ACC.UW[K] := FUpperValue.UW[K];
  end
  else if FUpperReg >= 0 then
    CommitVF(FUpperReg, FUpperValue, FUpperMask);
end;

{ Pipeline timing }

// The VF registers an upper op reads and writes with their fields (x 8,
// y 4, z 2, w 1; register -1: none). Results going to ACC are not tracked:
// there are no hazard checks on ACC.
procedure TPS2VUCore.UpperRegs(Op: Cardinal; out R: TPS2VURegUse);
begin
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Fd := Integer((Op shr 6) and 31);
  var Mask := (Op shr 21) and $F;
  // Broadcast ops read one field of ft.
  var Bc := FieldBit(Integer(Op and 3));
  R.Dest := -1;
  R.DestMask := Mask;
  R.S1 := -1;
  R.S2 := -1;
  R.M1 := Mask;
  R.M2 := Mask;
  var F := Integer(Op and $3F);
  if F >= $3C then
  begin
    var X := (Integer((Op shr 6) and 31) shl 2) or (F and 3);
    case X of
      $00..$0F, $18..$1B:
        begin
          R.S1 := Fs;
          R.S2 := Ft;
          R.M2 := Bc;
        end;
      $28..$2D:
        begin
          R.S1 := Fs;
          R.S2 := Ft;
        end;
      $2E:
        begin
          // OPMULA: the cross product reads x, y and z of both.
          R.S1 := Fs;
          R.S2 := Ft;
          R.M1 := $E;
          R.M2 := $E;
        end;
      $10..$17, $1D:
        begin
          R.S1 := Fs;
          R.Dest := Ft;
        end;
      $1C, $1E, $20..$27:
        R.S1 := Fs;
      $1F:
        begin
          // CLIP: fs.xyz against ft.w.
          R.S1 := Fs;
          R.S2 := Ft;
          R.M1 := $E;
          R.M2 := 1;
        end;
    end;
    Exit;
  end;
  case F of
    $00..$1B:
      begin
        R.S1 := Fs;
        R.S2 := Ft;
        R.M2 := Bc;
        R.Dest := Fd;
      end;
    $28..$2D, $2F:
      begin
        R.S1 := Fs;
        R.S2 := Ft;
        R.Dest := Fd;
      end;
    $2E:
      begin
        // OPMSUB
        R.S1 := Fs;
        R.S2 := Ft;
        R.M1 := $E;
        R.M2 := $E;
        R.Dest := Fd;
      end;
    $1C..$27:
      begin
        R.S1 := Fs;
        R.Dest := Fd;
      end;
  end;
end;

// The VF registers a lower op reads and writes with their fields.
procedure TPS2VUCore.LowerRegs(Op: Cardinal; out R: TPS2VURegUse);
begin
  var Fs := Integer((Op shr 11) and 31);
  var Ft := Integer((Op shr 16) and 31);
  var Mask := (Op shr 21) and $F;
  // Single-field operands (DIV, SQRT, RSQRT, MTIR, EFU): fsf, ftf.
  var Fsf := FieldBit(Integer((Op shr 21) and 3));
  var Ftf := FieldBit(Integer((Op shr 23) and 3));
  R.Dest := -1;
  R.DestMask := Mask;
  R.S1 := -1;
  R.S2 := -1;
  R.M1 := Mask;
  R.M2 := Mask;
  case Op shr 25 of
    $00:
      R.Dest := Ft;
    $01:
      R.S1 := Fs;
    $40:
      if (Op and $3F) >= $3C then
        case (Integer((Op shr 6) and 31) shl 2) or Integer(Op and 3) of
          $30:
            begin
              R.S1 := Fs;
              R.Dest := Ft;
            end;
          $31:
            begin
              // MR32: x from y, y from z, z from w, w from x.
              R.S1 := Fs;
              R.M1 := ((Mask shr 1) and 7) or ((Mask and 1) shl 3);
              R.Dest := Ft;
            end;
          $34, $36, $3D, $64:
            R.Dest := Ft;
          $35, $37:
            R.S1 := Fs;
          $3C:
            begin
              R.S1 := Fs;
              R.M1 := Fsf;
            end;
          $70..$7E:
            begin
              R.S1 := Fs;
              R.M1 := $F;
            end;
          $38, $3A:
            begin
              R.S1 := Fs;
              R.M1 := Fsf;
              R.S2 := Ft;
              R.M2 := Ftf;
            end;
          $39:
            begin
              R.S1 := Ft;
              R.M1 := Ftf;
            end;
        end;
  end;
end;

function TPS2VUCore.ReadyAt(Reg: Integer; Mask: Cardinal): Int64;
begin
  Result := 0;
  if (Reg <= 0) or (FReadyAny[Reg] <= S.Cycles) then
    Exit;
  for var K := 0 to 3 do
    if ((Mask and FieldBit(K)) <> 0) and (FReady[Reg, K] > Result) then
      Result := FReady[Reg, K];
end;

// Cycles the pair waits for its source fields (hazard checks are per
// field; none on ACC, VF00, I, Q, P, R).
procedure TPS2VUCore.DecodePair(var P: TPS2VUPair; LowerOp, UpperOp: Cardinal);
begin
  P.Native := nil;
  P.Heat := 0;
  P.QueueHint := 0;
  // Every hot entry benefits from compiled pipeline bookkeeping, even when
  // an uncommon opcode inside it still calls a helper.
  P.NativeCandidate := True;
  P.Lower := LowerOp;
  P.Upper := UpperOp;
  P.VIWrite := VIWritten(LowerOp, UpperOp);
  UpperRegs(UpperOp, P.U);
  if (UpperOp and $80000000) = 0 then
    LowerRegs(LowerOp, P.L)
  else
  begin
    P.L := Default(TPS2VURegUse);
    P.L.Dest := -1;
    P.L.S1 := -1;
    P.L.S2 := -1;
  end;
  P.SetsFlags := UpperSetsFlags(UpperOp);
  P.Valid := True;
end;

function TPS2VUCore.DecodedPair(PC, LowerOp, UpperOp: Cardinal): PPS2VUPair;
begin
  Result := @FPairs[PC shr 3];
  if not Result.Valid or (Result.Lower <> LowerOp) or (Result.Upper <> UpperOp) then
  begin
    FBodies[PC shr 3] := nil;
    DecodePair(Result^, LowerOp, UpperOp);
  end;
end;

function TPS2VUCore.HazardStall(const P: TPS2VUPair): Integer;
begin
  var Need := Max(ReadyAt(P.U.S1, P.U.M1), ReadyAt(P.U.S2, P.U.M2));
  Need := Max(Need, Max(ReadyAt(P.L.S1, P.L.M1), ReadyAt(P.L.S2, P.L.M2)));
  Result := 0;
  if Need > S.Cycles then
    Result := Integer(Need - S.Cycles);
end;

// The pair's results are ready four cycles after issue.
procedure TPS2VUCore.NoteWrites(const P: TPS2VUPair);
begin
  if (P.U.Dest > 0) and (P.U.DestMask <> 0) then
  begin
    for var K := 0 to 3 do
      if (P.U.DestMask and FieldBit(K)) <> 0 then
        FReady[P.U.Dest, K] := S.Cycles + 4;
    FReadyAny[P.U.Dest] := S.Cycles + 4;
  end;
  if (P.L.Dest > 0) and (P.L.DestMask <> 0) then
  begin
    for var K := 0 to 3 do
      if (P.L.DestMask and FieldBit(K)) <> 0 then
        FReady[P.L.Dest, K] := S.Cycles + 4;
    FReadyAny[P.L.Dest] := S.Cycles + 4;
  end;
end;

// FMAC ops that update the MAC and status flags (not MAX/MINI, ITOF/FTOI,
// ABS, CLIP, NOP).
function TPS2VUCore.UpperSetsFlags(Op: Cardinal): Boolean;
begin
  var F := Integer(Op and $3F);
  if F >= $3C then
  begin
    var X := (Integer((Op shr 6) and 31) shl 2) or (F and 3);
    Result := not (X in [$10..$17, $1D, $1F, $2B, $2F]);
  end
  else
    Result := (F <= $2F) and not (F in [$10..$17, $1D, $1F, $2B, $2F]);
end;

procedure TPS2VUCore.AdvanceCycles(N: Integer);
begin
  // The preceding integer result is visible after an interlocked pair stalls.
  if N > 0 then
    FLoadReg := -1;
  Inc(S.Cycles, N);
  if S.QDelay > 0 then
  begin
    Dec(S.QDelay, N);
    if S.QDelay <= 0 then
    begin
      S.QDelay := 0;
      S.Q := S.PendingQ;
    end;
  end;
  if S.PDelay > 0 then
  begin
    Dec(S.PDelay, N);
    if S.PDelay <= 0 then
    begin
      S.PDelay := 0;
      S.P := S.PendingP;
    end;
  end;
end;

// XGKICK: the GIF starts reading the packet from VU memory a few cycles
// after the XGKICK (KickLatency) and then takes a quadword every two VU
// cycles while the program goes on, so stores the program makes to the
// packet right after the XGKICK still go out with it (programs kick a
// packet and write its GIF tag or its last quadword in the next pairs). A
// second XGKICK waits for the first transfer; the end of the program or of
// the run hands the rest over at once.
procedure TPS2VUCore.StartKick(Address: Cardinal);
begin
  if FKickPending then
    TakeKick(True);
  if Length(FKickBuf) = 0 then
    SetLength(FKickBuf, (FDataMask + 1) div 16);
  FKickPending := True;
  FKickAddress := Address;
  FKickStart := S.Cycles + KickLatency;
  FKickDue := FKickStart;
  FKickCount := 0;
  FKickNextTag := 0;
  FKickEnd := -1;
  TakeKick(False);
end;

procedure TPS2VUCore.TakeKick(All: Boolean);
begin
  var Limit := Length(FKickBuf);
  var Due := Limit;
  if not All then
  begin
    if S.Cycles < FKickDue then
      Exit;
    if (S.Cycles - FKickDue < 2) and (FKickCount < FKickNextTag) and (FKickCount + 1 < Limit) and
      ((FKickEnd < 0) or (FKickCount + 1 < FKickEnd)) then
    begin
      // A lone payload quadword cannot parse a tag or complete the packet.
      var Src := PUInt64(FData + ((FKickAddress + Cardinal(FKickCount) * 16) and FDataMask));
      FKickBuf[FKickCount].Lo := Src[0];
      FKickBuf[FKickCount].Hi := Src[1];
      Inc(FKickCount);
      Inc(FKickDue, 2);
      Exit;
    end;
    var N := (S.Cycles - FKickStart) div 2 + 1;
    if N < Limit then
      Due := Integer(N);
  end;
  while ((FKickEnd < 0) or (FKickCount < FKickEnd))
        and (FKickCount < Due) do
  begin
    if PS2VUKickRuns and (FKickCount < FKickNextTag) then
    begin
      // Only payload: stop before the next tag, the due time, the packet's
      // end and a VU-memory wrap. Stores/callbacks cannot run inside this
      // copy; their observation points are still the caller's original ones.
      var Last := Min(Due, FKickNextTag);
      if FKickEnd >= 0 then
        Last := Min(Last, FKickEnd);
      var At := (FKickAddress + Cardinal(FKickCount) * 16) and FDataMask;
      var N := Min(Last - FKickCount, Integer((FDataMask + 1 - At) div 16));
      if N > 1 then
      begin
        var Source := FData + At;
        var Target := @FKickBuf[FKickCount];
        var Bytes := NativeUInt(N * 16);
        // Aliased synthetic callers retain the old read/write order.
        if (NativeUInt(Source) >= NativeUInt(Target) + Bytes) or (NativeUInt(Target) >= NativeUInt(Source) + Bytes) then
        begin
          Move(Source^, Target^, N * 16);
          Inc(FKickCount, N);
          Continue;
        end;
      end;
    end;
    // (By halves: a 16-byte record copy is two string moves here.)
    var Src := PUInt64(FData + ((FKickAddress + Cardinal(FKickCount) * 16) and FDataMask));
    var Lo := Src[0];
    FKickBuf[FKickCount].Lo := Lo;
    FKickBuf[FKickCount].Hi := Src[1];
    if FKickCount = FKickNextTag then
    begin
      var NLoop := Integer(Lo and $7FFF);
      var Flg := Cardinal(Lo shr 58) and 3;
      var NReg := Integer(Lo shr 60);
      if NReg = 0 then
        NReg := 16;
      var Size: Integer;
      case Flg of
        0:
          Size := NLoop * NReg;
        1:
          Size := (NLoop * NReg + 1) div 2;
      else
        Size := NLoop;
      end;
      FKickNextTag := FKickCount + 1 + Size;
      if (Lo and $8000) <> 0 then
        FKickEnd := FKickNextTag;
    end;
    Inc(FKickCount);
  end;
  if ((FKickEnd >= 0) and (FKickCount >= FKickEnd)) or (FKickCount >= Limit) then
  begin
    FKickPending := False;
    if Assigned(FOnKick) then
    begin
      FOnKick(FKickAddress, @FKickBuf[0]);
      RefreshFastGate;
    end;
  end;
  FKickDue := FKickStart + Int64(2) * FKickCount;
end;

procedure TPS2VUCore.Start(Address: Cardinal);
begin
  Inc(Touched);
  FLoadReg := -1;
  S.TPC := Address and FCodeMask;
  S.Running := True;
  S.BranchPending := False;
  S.EndPending := False;
  S.ClipBase := S.Clip;
  S.ClipQCount := 0;
  S.MACBase := S.MAC;
  S.StatusBase := S.Status;
  S.FlagQCount := 0;
  FillChar(FReady, SizeOf(FReady), 0);
  FillChar(FReadyAny, SizeOf(FReadyAny), 0);
  FBlockMap.RestoredDeadline := 0;
end;

procedure TPS2VUCore.PreparePair(var Run: TPS2VURun);
begin
  var PC := Run.PC;
  var Pair := Run.Pair;
  var LowerOp := Pair.Lower;
  var UpperOp := Pair.Upper;
    // Registers still in the FMAC pipeline stall the pair; Q/P and the
    // clip flag move on meanwhile.
  var Stall := HazardStall(Pair^);
  if Stall > 0 then
    AdvanceCycles(Stall);
  if FKickPending and (S.Cycles >= FKickDue) then
    TakeKick(False);
  while (S.ClipQCount > 0) and (S.ClipQReady[0] <= S.Cycles) do
  begin
    S.ClipBase := S.ClipQValue[0];
    for var K := 1 to S.ClipQCount - 1 do
    begin
      S.ClipQValue[K - 1] := S.ClipQValue[K];
      S.ClipQReady[K - 1] := S.ClipQReady[K];
    end;
    Dec(S.ClipQCount);
  end;
  FClipVisible := S.ClipBase;
  while (S.FlagQCount > 0) and (S.FlagQReady[0] <= S.Cycles) do
  begin
    S.MACBase := S.FlagQMAC[0];
    S.StatusBase := S.FlagQStatus[0];
    for var K := 1 to S.FlagQCount - 1 do
    begin
      S.FlagQMAC[K - 1] := S.FlagQMAC[K];
      S.FlagQStatus[K - 1] := S.FlagQStatus[K];
      S.FlagQReady[K - 1] := S.FlagQReady[K];
    end;
    Dec(S.FlagQCount);
  end;
  Run.Branching := S.BranchPending;
  Run.Target := S.BranchTarget;
  Run.Ending := S.EndPending;
  S.BranchPending := False;
    // Q and P land after their latency.
  if S.QDelay > 0 then
  begin
    Dec(S.QDelay);
    if S.QDelay = 0 then
      S.Q := S.PendingQ;
  end;
  if S.PDelay > 0 then
  begin
    Dec(S.PDelay);
    if S.PDelay = 0 then
      S.P := S.PendingP;
  end;
    // WAITQ/WAITP stall the whole pair: its upper op sees the new Q/P.
  if (UpperOp and $80000000) = 0 then
    if ((LowerOp and $FE0007FF) = $800003BF) and (S.QDelay > 0) then
    begin
      S.Q := S.PendingQ;
      S.QDelay := 0;
    end
    else if ((LowerOp and $FE0007FF) = $800007BF) and (S.PDelay > 0) then
    begin
      S.P := S.PendingP;
      S.PDelay := 0;
    end;
  if (RunTrace <> nil) and ((RunTraceCount + 1) * 16 <= Length(RunTrace)) then
  begin
    RunTrace[RunTraceCount * 16] := Word(PC);
    for var K := 1 to 15 do
      RunTrace[RunTraceCount * 16 + K] := Word(FVI[K]);
    Inc(RunTraceCount);
  end;
    // An integer register written by the integer unit (ILW, ILWR, MTIR,
    // the integer ALU, LQI/LQD/SQI/SQD address updates) reaches a
    // conditional branch in the next pair only after it has read its
    // operands. Flag reads (FS*/FM*/FC*) reach it at once.
  FBranchReg := FLoadReg;
  FBranchOld := FLoadOld;
  FLoadReg := Pair.VIWrite;
  if FLoadReg >= 0 then
    FLoadOld := FVI[FLoadReg];
  FUpperReg := -1;
  FLowerReg := -1;
end;

procedure TPS2VUCore.FinishPair(var Run: TPS2VURun);
begin
  var PC := Run.PC;
  var Pair := Run.Pair;
  var UpperOp := Pair.Upper;
    // Lower writes first; the upper result wins on the same register.
  if FLowerReg >= 0 then
    CommitVF(FLowerReg, FLowerValue, FLowerMask);
  if FUpperReg = 32 then
  begin
    for var K := 0 to 3 do
      if (FUpperMask and FieldBit(K)) <> 0 then
        S.ACC.UW[K] := FUpperValue.UW[K];
  end
  else if FUpperReg >= 0 then
    CommitVF(FUpperReg, FUpperValue, FUpperMask);
  NoteWrites(Pair^);
  if Pair.SetsFlags and (S.FlagQCount < 4) then
  begin
    S.FlagQMAC[S.FlagQCount] := S.MAC;
    S.FlagQStatus[S.FlagQCount] := S.Status;
    S.FlagQReady[S.FlagQCount] := S.Cycles + 4;
    Inc(S.FlagQCount);
  end;
  Inc(Executed);
  Inc(S.Cycles);
  Inc(Run.Count);
  if Run.Count > Run.Limit - Length(LoopTrace) then
    LoopTrace[Run.Count - (Run.Limit - Length(LoopTrace)) - 1] := PC;
  S.TPC := (PC + 8) and FCodeMask;
  if Run.Branching then
    S.TPC := Run.Target;
  if Run.Ending then
  begin
    S.Running := False;
    S.EndPending := False;
    Exit;
  end;
  if (UpperOp and $40000000) <> 0 then
    S.EndPending := True;
end;

// Pairs from the TPC on, at most Max, after none of which but the last the
// TPC can be StopTPC or the program end: no branch or end takes effect
// before the last, and the TPC goes on straight past StopTPC's place. Run
// of them at once ends where running them one at a time, checking the TPC
// after each, would first find it at StopTPC (or the program ended).
function TPS2VUCore.StraightPairs(StopTPC: Cardinal; Max: Integer): Integer;
begin
  Result := 1;
  if S.BranchPending or S.EndPending or FKickPending then
    Exit;
  var PC := S.TPC and FCodeMask;
  StopTPC := StopTPC and FCodeMask;
  while Result < Max do
  begin
    var Lower := PCardinal(FCode + PC)^;
    var Upper := PCardinal(FCode + PC + 4)^;
    var Next := (PC + 8) and FCodeMask;
    if ((Upper and $40000000) <> 0) or (Next = StopTPC) then
      Exit;
    // A branch: its delay slot as well, after which the TPC may be anywhere.
    if ((Upper and $80000000) = 0) and ((Lower shr 25) >= $20) and ((Lower shr 25) <= $2F) then
      Exit(Min(Result + 1, Max));
    PC := Next;
    Inc(Result);
  end;
end;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// The host rounding (MXCSR RC), without the run-time library's call.
function HostRounding: TRoundingMode;
asm
        .       NOFRAME
        stmxcsr [rsp + 8]
        mov     eax, [rsp + 8]
        SHR     eax, 13
        AND     eax, 3
end;
{$ELSE}

function HostRounding: TRoundingMode;
begin
  Result := GetRoundMode;
end;
{$ENDIF}

procedure TPS2VUCore.CheckMath;
begin
  var Mode := HostRounding;
  if (Mode <> FMathMode) or (FMath[vrmAdd] = nil) then
  begin
    FMathMode := Mode;
    FMath[vrmAdd] := PS2RegisterMathNativeFor(vrmAdd, Mode);
    FMath[vrmMul] := PS2RegisterMathNativeFor(vrmMul, Mode);
    FAccMath[False] := PS2RegisterAccNative(False, Mode);
    FAccMath[True] := PS2RegisterAccNative(True, Mode);
  end;
end;

procedure TPS2VUCore.HoldMath(Held: Boolean);
begin
  if Held then
  begin
    // (While the EE runs, FMath is for its rounding already: TPS2VU0.)
    if (FMathHeld = 0) and not FMacroMathKnown then
      CheckMath;
    Inc(FMathHeld);
  end
  else
    Dec(FMathHeld);
end;

// One pair interpreted (apart from Run: its frame stays small for the
// generated code's short runs).
procedure TPS2VUCore.InterpretPair(var Context: TPS2VURun; PC: Cardinal; Pair: PPS2VUPair);
begin
  var LowerOp := Pair.Lower;
  var UpperOp := Pair.Upper;
  Context.PC := PC;
  Context.Pair := Pair;
  PreparePair(Context);
  Upper(UpperOp, True);
  if (UpperOp and $80000000) <> 0 then
    S.I := LowerOp
  else
    Lower(LowerOp);
  FinishPair(Context);
end;

function TPS2VUCore.Run(MaxPairs: Integer): Boolean;
begin
  // (The host rounding stays as it is for the whole run: the routines for
  // it, before generated code first runs.)
  Inc(Touched);
  var MathChecked := FMathHeld > 0;
  var Context := Default(TPS2VURun);
  Context.Limit := MaxPairs;
  RefreshFastGate;
  while S.Running and (Context.Count < Context.Limit) do
  begin
    var PC := S.TPC and FCodeMask;
    var LowerOp := PCardinal(FCode + PC)^;
    var UpperOp := PCardinal(FCode + PC + 4)^;
    var Pair := DecodedPair(PC, LowerOp, UpperOp);
    if FUseJit and Pair.NativeCandidate and (JitSupported or (FJit <> nil)) then
    begin
      if Pair.Native = nil then
      begin
        Inc(Pair.Heat);
        if Pair.Heat >= PS2VUCompileHeat then
          Pair.Native := CompileBlock(PC)
        else if Pair.Entry then
          // (Decoded again where a block was compiled: a program uploaded
          // again finds the block kept for its words at once.)
          Pair.Native := CachedBlock(PC);
      end;
    end;
    if FUseJit and (Pair.Native <> nil) then
    begin
      if not MathChecked then
      begin
        MathChecked := True;
        CheckMath;
      end;
      var Before := Context.Count;
      Context.Invalid := False;
      FJit.InvokeKeeping(Pair.Native, NativeUInt(Self), NativeUInt(@Context));
      Inc(FJitBlocks);
      Inc(FJitRuns, Context.Count - Before);
      if Context.Invalid then
      begin
        Pair.Native := nil;
        FBodies[PC shr 3] := nil;
        // A chained successor can have detected the stale pair.
        FBodies[(S.TPC and FCodeMask) shr 3] := nil;
        FPairs[(S.TPC and FCodeMask) shr 3].Native := nil;
      end;
      if Context.Count <> Before then
        Continue;
    end;
    InterpretPair(Context, PC, Pair);
  end;
  if FKickPending then
    TakeKick(True);
{$IFDEF PS2_CHECKED}
  if MathChecked and (GetRoundMode <> FMathMode) then
    raise Exception.Create('VU run changed the host rounding');
{$ENDIF}
  Result := not S.Running;
end;

procedure TPS2VUCore.RunProgram(Now: Int64; MaxPairs: Integer);
begin
  if Assigned(OnRunProgram) then
    OnRunProgram();
  var Before := S.Cycles;
  Run(MaxPairs);
  S.BusyUntil := Now + (S.Cycles - Before);
end;

function TPS2VUCore.VectorOffsets: string;
begin
  Result :=
    Format(
    'acc=%d upper=%d lower=%d operand=%d product=%d lanes=%d size=%d',
    [
      NativeUInt(@S.ACC) - NativeUInt(Self),
      NativeUInt(@FUpperValue) - NativeUInt(Self),
      NativeUInt(@FLowerValue) - NativeUInt(Self),
      NativeUInt(@FJitOperand) - NativeUInt(Self),
      NativeUInt(@FJitProduct) - NativeUInt(Self),
      NativeUInt(@FLanesXYZ) - NativeUInt(Self),
      InstanceSize
    ]
  );
end;

function TPS2VUCore.Busy(Now: Int64): Boolean;
begin
  Result := S.Running or (Now < S.BusyUntil);
end;

procedure TPS2VUCore.SerializeState(State: TStateArchive);
begin
  // (Code memory may come with the snapshot.)
  NoteCodeWritten;
  Inc(Touched);
  State.Field(S, SizeOf(S));
  if State.Loading then
  begin
    FLoadReg := -1;
    // (Results in the FMAC pipeline are not saved: none is pending. Every
    // ready time is then within three cycles of the cycle count, as after
    // any pair, which scheduled runs rely on.)
    FillChar(FReady, SizeOf(FReady), 0);
    FillChar(FReadyAny, SizeOf(FReadyAny), 0);
    FBlockMap.RestoredDeadline := 0;
  end;
end;

procedure TPS2VUCore.SaveRun(out C: TPS2VUCoreSaved);
begin
  C.S := S;
  C.LoadReg := FLoadReg;
  C.BranchReg := FBranchReg;
  C.LoadOld := FLoadOld;
  C.BranchOld := FBranchOld;
  C.ClipVisible := FClipVisible;
  C.JitClip := FJitClip;
  C.JitClipSet := FJitClipSet;
  C.JitLazyMAC := FJitLazyMAC;
  C.KickPending := FKickPending;
  C.KickAddress := FKickAddress;
  C.KickStart := FKickStart;
  C.KickCount := FKickCount;
  C.KickNextTag := FKickNextTag;
  C.KickEnd := FKickEnd;
  // (All of it: PATH1 in a tag an earlier packet left open takes quadwords
  // past those a kick copied, as the buffer has them.)
  C.KickBuf := Copy(FKickBuf);
  Move(FReady, C.Ready, SizeOf(FReady));
  Move(FReadyAny, C.ReadyAny, SizeOf(FReadyAny));
  C.Executed := Executed;
  C.JitRuns := FJitRuns;
end;

procedure TPS2VUCore.RestoreRun(const C: TPS2VUCoreSaved);
begin
  NoteCodeWritten;
  Inc(Touched);
  S := C.S;
  FLoadReg := C.LoadReg;
  FBranchReg := C.BranchReg;
  FLoadOld := C.LoadOld;
  FBranchOld := C.BranchOld;
  FClipVisible := C.ClipVisible;
  FJitClip := C.JitClip;
  FJitClipSet := C.JitClipSet;
  FJitLazyMAC := C.JitLazyMAC;
  FKickPending := C.KickPending;
  FKickAddress := C.KickAddress;
  FKickStart := C.KickStart;
  FKickCount := C.KickCount;
  FKickDue := FKickStart + Int64(2) * FKickCount;
  FKickNextTag := C.KickNextTag;
  FKickEnd := C.KickEnd;
  if Length(C.KickBuf) > 0 then
  begin
    if Length(FKickBuf) = 0 then
      SetLength(FKickBuf, (FDataMask + 1) div 16);
    Move(C.KickBuf[0], FKickBuf[0], Length(C.KickBuf) * SizeOf(TPS2Reg128));
  end;
  Move(C.Ready, FReady, SizeOf(FReady));
  Move(C.ReadyAny, FReadyAny, SizeOf(FReadyAny));
  FBlockMap.RestoredDeadline := 0;
  var Horizon := High(Int64);
  if S.Cycles < High(Int64) - 3 then
    Horizon := S.Cycles + 3;
  for var R := 1 to 31 do
    for var K := 0 to 3 do
      if (FReady[R, K] > Horizon) and (FReady[R, K] > FBlockMap.RestoredDeadline) then
        FBlockMap.RestoredDeadline := FReady[R, K];
  RefreshFastGate;
  Executed := C.Executed;
  FJitRuns := C.JitRuns;
end;

{ TPS2VU0 }

constructor TPS2VU0.Create(Code, Data: PByte);
begin
  FCore := TPS2VUCore.Create(0, @VF, @VI, Code, Data, $1000, $1000);
  inherited Create;
end;

destructor TPS2VU0.Destroy;
begin
  FCore.Free;
  inherited;
end;

procedure TPS2VU0.Reset;
begin
  Inc(FTouches);
  inherited Reset;
  if FCore <> nil then
    FCore.Reset;
  FBlocked := False;
  FSpinValid := False;
end;

function TPS2VU0.ReadControl(Index: Integer): Cardinal;
begin
  case Index of
    0..15:
      Result := VI[Index] and $FFFF;
    16:
      Result := FCore.S.Status;
    17:
      Result := FCore.S.MAC;
    18:
      Result := FCore.S.Clip;
    20:
      Result := FCore.S.R;
    21:
      Result := FCore.S.I;
    22:
      Result := FCore.S.Q;
    23:
      Result := FCore.S.P;
    26:
      Result := FCore.S.TPC shr 3;
    29:
      begin
      // VPU-STAT: VBS0 (VU0 busy) bit 0, VBS1 bit 8.
        Result := Ord(FCore.Busy(Now));
        if (FVU1 <> nil) and VU1Busy then
          Result := Result or $100;
      end;
  else
    Result := VI[Index and 31];
  end;
end;

procedure TPS2VU0.WriteControl(Index: Integer; Value: Cardinal);
begin
  // (VI too: compared whole by the probes.)
  if not (Index in [1..15]) then
    Inc(FTouches);
  case Index of
    0:
      ;
    1..15:
      VI[Index] := Value and $FFFF;
    16:
      FCore.S.Status := (FCore.S.Status and $3F) or (Value and $FC0);
    // MAC flags and the reserved registers ignore writes (ps2autotests
    // cpu/vu0_macro/transfer on hardware).
      17, 19, 23..25:
      ;
    18:
      FCore.S.Clip := Value and $FFFFFF;
    20:
      FCore.S.R := Value and $7FFFFF;
    21:
      FCore.S.I := Value;
    22:
      FCore.S.Q := Value;
    27:
      VI[27] := Value and $FFFF;
    28:
      begin
      // FBRST: reset VU0 (bit 1) / VU1 (bit 9).
        if (Value and 2) <> 0 then
          FCore.Reset;
        if ((Value and $200) <> 0) and (FVU1 <> nil) then
          ResetVU1;
      end;
    31:
      begin
      // CMSAR1 keeps the 16-bit address it starts VU1 at.
        VI[31] := Value and $FFFF;
        if Assigned(FCMSAR1Start) then
          FCMSAR1Start(Value);
      end;
  else
    VI[Index and 31] := Value;
  end;
end;

function TPS2VU0.Execute(Op: Cardinal): Boolean;
begin
  Inc(FTouches);
  case Op and $3F of
    $38, $39:
      begin
        // VCALLMS imm15 / VCALLMSR (CMSAR0): run the micro program now.
        var Address: Cardinal;
        if (Op and $3F) = $38 then
          Address := ((Op shr 6) and $7FFF) * 8
        else
          Address := (VI[27] and $FFFF) * 8;
        // A program still running is waited for first.
        Interlock;
        FBlocked := False;
        FCore.Start(Address);
        var Before := FCore.S.Cycles;
        RunUntilBlocked;
        FCore.S.BusyUntil := Now + (FCore.S.Cycles - Before);
        Exit(True);
      end;
  end;
  // Macro instructions wait for a running micro program.
  Interlock;
  Result := FCore.Macro(Op);
end;

// Whether Count 64-bit words at A and B are equal (CompareMem without the
// call, for the register files the spin checks compare).
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// (A multiple of four: 32 bytes a turn, SSE2.)
function SameWords4(A, B: PUInt64; Count: Integer): Boolean;
asm
        .       NOFRAME
        SHR     r8d, 2

@@Loop:
        movdqu  xmm0, [rcx]
        movdqu  xmm1, [rcx + 16]
        movdqu  xmm2, [rdx]
        movdqu  xmm3, [rdx + 16]
        pcmpeqb xmm0, xmm2
        pcmpeqb xmm1, xmm3
        pand    xmm0, xmm1
        pmovmskb eax, xmm0
        cmp     eax, $FFFF
        jne     @@Diff
        add     rcx, 32
        add     rdx, 32
        sub     r8d, 1
        jnz     @@Loop
        mov     eax, 1
        ret

@@Diff:
        XOR     eax, eax
end;
{$ENDIF}

function SameWords(A, B: PUInt64; Count: Integer): Boolean;
begin
  {$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  if (Count > 0) and ((Count and 3) = 0) then
    Exit(SameWords4(A, B, Count));
  {$ENDIF}
  var K := 0;
  while K + 4 <= Count do
  begin
    if ((A[K] xor B[K]) or (A[K + 1] xor B[K + 1]) or (A[K + 2] xor B[K + 2]) or (A[K + 3] xor B[K + 3])) <> 0 then
      Exit(False);
    Inc(K, 4);
  end;
  while K < Count do
  begin
    if A[K] <> B[K] then
      Exit(False);
    Inc(K);
  end;
  Result := True;
end;

// A micro program runs alongside the EE. Programs wait in loops on
// registers the EE writes (a VI flag released by CTC2, VF data handed over
// by QMTC2) and hand results back the same way, so the program runs as far
// as it can whenever the EE starts it or looks at VU0: to its end, or until
// it spins without changing anything (Spins). Once it spins, it is only
// probed again (one turn of the loop, which also sees VU memory the EE
// wrote) until the EE changes its registers. A loop that touches no memory
// and came back to the very same state (SpinKnown) is not run for that:
// its turns only take their cycles (SkipSpin), and VF data handed over
// cannot release one that reads no VF register either.
procedure TPS2VU0.RunUntilBlocked;
begin
  FCore.HoldMath(True);
  try
    RunUntilBlockedHeld;
  finally
    FCore.HoldMath(False);
  end;
end;

procedure TPS2VU0.RunUntilBlockedHeld;
begin
  if KnownProbe then
    Exit;
  if FBlocked and SameWords(@VI[0], @FBlockVI[0], SizeOf(FBlockVI) div 8) then
    if SameWords(@VF[0], @FBlockVF[0], SizeOf(FBlockVF) div 8) then
    begin
      // The probe's one turn.
      if SpinSkips and SpinKnown then
      begin
        SkipSpin(1);
        NoteProbe;
        Exit;
      end;
      if Spins then
        Exit;
    end
    else if SpinSkips and FSpinValid and FSpinVFFree and (16 mod FSpinPairs = 0) and SpinKnown then
    begin
      // The loop below's first run (16 pairs: whole turns) and Spins' turn.
      SkipSpin(16 div FSpinPairs + 1);
      Move(VF[0], FBlockVF[0], SizeOf(FBlockVF));
      NoteProbe;
      Exit;
    end;
  FBlocked := False;
  // Short runs first: a released program often goes back to waiting soon.
  var Chunk := 16;
  var Budget := 1000000;
  while FCore.S.Running and (Budget > 0) do
  begin
    FCore.Run(Chunk);
    Dec(Budget, Chunk);
    Chunk := Min(Chunk * 2, 4096);
    if FCore.S.Running and Spins then
    begin
      FBlocked := True;
      Move(VF[0], FBlockVF[0], SizeOf(FBlockVF));
      Move(VI[0], FBlockVI[0], SizeOf(FBlockVI));
      Break;
    end;
  end;
end;

// Runs up to 64 pairs: True when the program came back to the same TPC with
// the same registers (a loop that waits).
function TPS2VU0.Spins: Boolean;
var
  SavedVF: array[0..31] of TPS2Reg128;
  SavedVI: array[0..15] of Cardinal;
  Before: TPS2VUState;
begin
  FSpinValid := False;
  var TPC := FCore.S.TPC;
  var Acc := FCore.S.ACC;
  var Q := FCore.S.Q;
  var P := FCore.S.P;
  Move(VF[0], SavedVF[0], SizeOf(SavedVF));
  Move(VI[0], SavedVI[0], SizeOf(SavedVI));
  Before := FCore.S;
  var LoadReg := FCore.FLoadReg;
  var BranchReg := FCore.FBranchReg;
  var LoadOld := FCore.FLoadOld;
  var BranchOld := FCore.FBranchOld;
  // (Pairs one at a time, but straight-line ones together: the TPC cannot
  // be back before the last of them. Those of a run are the pairs from the
  // TPC on, see StraightPairs.)
  var Done := 0;
  while Done < 64 do
  begin
    var Step := FCore.StraightPairs(TPC, 64 - Done);
    for var K := 0 to Step - 1 do
      FSpinPC[Done + K] := (FCore.S.TPC + Cardinal(K) * 8) and FCore.FCodeMask;
    FCore.Run(Step);
    Inc(Done, Step);
    if not FCore.S.Running then
      Exit(False);
    if (FCore.S.TPC = TPC) and (FCore.S.Q = Q) and (FCore.S.P = P) and (FCore.S.ACC.Lo = Acc.Lo) and
      (FCore.S.ACC.Hi = Acc.Hi) and SameWords(@VF[0], @SavedVF[0], SizeOf(SavedVF) div 8) and
      SameWords(@VI[0], @SavedVI[0], SizeOf(SavedVI) div 8) then
    begin
      NoteSpin(Done, Before, LoadReg, BranchReg, LoadOld, BranchOld);
      Exit(True);
    end;
  end;
  Result := False;
end;

// Whether A and B are the same but for the cycle count (the words before and
// after it, their padding included).
function SameState(const A, B: TPS2VUState): Boolean;
begin
  // (Cycles is aligned to 8 bytes, the record's size a multiple of 8.)
  var Head := Integer(NativeInt(@PPS2VUState(nil).Cycles));
  var Tail := Head + SizeOf(Int64);
  Result := SameWords(PUInt64(@A), PUInt64(@B), Head div 8) and
    SameWords(PUInt64(PByte(@A) + Tail), PUInt64(PByte(@B) + Tail), (SizeOf(TPS2VUState) - Tail) div 8);
end;

// Spins' turn of Pairs pairs (FSpinPC) from state Before (and those integer
// unit fields) came back: a known loop (FSpinValid) if it left everything
// as it found it but the cycle count, with nothing pending before or after
// (flag, clip or Q/P results, end, XGKICK, VF results; a branch taken in
// the state is) and none of its pairs touching memory (SpinPair). Every
// turn from that state, at any cycle, then takes the same pairs and cycles
// back to it.
procedure TPS2VU0.NoteSpin(Pairs: Integer; const Before: TPS2VUState; LoadReg, BranchReg: Integer; LoadOld, BranchOld: Cardinal);
begin
  var C := FCore;
  if (C.S.FlagQCount <> 0) or (C.S.ClipQCount <> 0) or (C.S.QDelay <> 0) or (C.S.PDelay <> 0) or
    C.S.EndPending or C.FKickPending or (C.FLoadReg <> LoadReg) or
    (C.FBranchReg <> BranchReg) or (C.FLoadOld <> LoadOld) or (C.FBranchOld <> BranchOld) then
    Exit;
  if not SameState(Before, C.S) then
    Exit;
  // (No VF result was pending at the start; the latest ones the same after:
  // the turn wrote none.)
  for var R := 0 to 31 do
    if C.FReadyAny[R] > Before.Cycles then
      Exit;
  var VFFree := True;
  for var K := 0 to Pairs - 1 do
  begin
    var Lower := PCardinal(C.FCode + FSpinPC[K])^;
    var Upper := PCardinal(C.FCode + FSpinPC[K] + 4)^;
    if not SpinPair(Lower, Upper, VFFree) then
      Exit;
    FSpinWords[K * 2] := Lower;
    FSpinWords[K * 2 + 1] := Upper;
  end;
  FSpinPairs := Pairs;
  FSpinCycles := C.S.Cycles - Before.Cycles;
  FSpinState := C.S;
  FSpinLoadReg := LoadReg;
  FSpinBranchReg := BranchReg;
  FSpinLoadOld := LoadOld;
  FSpinBranchOld := BranchOld;
  FSpinVFFree := VFFree;
  FSpinValid := True;
end;

// The core is where the known loop's turn left it (the cycle count aside),
// with nothing pending and the loop's code unchanged: a turn now takes the
// same pairs and cycles back to the same state.
function TPS2VU0.SpinKnown: Boolean;
begin
  Result := False;
  if not FSpinValid then
    Exit;
  var C := FCore;
  if C.FKickPending or (C.FLoadReg <> FSpinLoadReg) or (C.FBranchReg <> FSpinBranchReg) or
    (C.FLoadOld <> FSpinLoadOld) or (C.FBranchOld <> FSpinBranchOld) or not SameState(C.S, FSpinState) then
    Exit;
  for var R := 0 to 31 do
    if C.FReadyAny[R] > C.S.Cycles then
      Exit;
  if not SpinCodeSame then
    Exit;
  Result := True;
end;

// The known loop's code as it was.
function TPS2VU0.SpinCodeSame: Boolean;
begin
  var Code := FCore.FCode;
  for var K := 0 to FSpinPairs - 1 do
    if (PCardinal(Code + FSpinPC[K])^ <> FSpinWords[K * 2]) or
      (PCardinal(Code + FSpinPC[K] + 4)^ <> FSpinWords[K * 2 + 1]) then
      Exit(False);
  Result := True;
end;

procedure TPS2VU0.NoteProbe;
begin
  FProbeKnown := True;
  FProbeTouched := FCore.Touched;
  FProbeTouches := FTouches;
  VFWritten := 0;
end;

// RunUntilBlockedHeld's probe where nothing but VI and VF registers the EE
// wrote can have changed since the last probe found the known loop (the
// core's state then, cycles aside, the known loop's): what the probe below
// would do when they leave it known, comparing VI and those registers only.
// False: the probe below runs.
function TPS2VU0.KnownProbe: Boolean;
begin
  Result := False;
  if not FProbeKnown or not FBlocked or not SpinSkips or not FSpinValid or (FProbeTouched <> FCore.Touched) or
    (FProbeTouches <> FTouches) or not SameWords(@VI[0], @FBlockVI[0], SizeOf(FBlockVI) div 8) or
    not SpinCodeSame then
    Exit;
  var Written := VFWritten;
  var Same := True;
  var R := 0;
  var Bits := Written;
  while Bits <> 0 do
  begin
    if (Bits and 1) <> 0 then
      if (VF[R].Lo <> FBlockVF[R].Lo) or (VF[R].Hi <> FBlockVF[R].Hi) then
      begin
        Same := False;
        Break;
      end;
    Bits := Bits shr 1;
    Inc(R);
  end;
  if Same then
    SkipSpin(1)
  else if FSpinVFFree and (16 mod FSpinPairs = 0) then
  begin
    SkipSpin(16 div FSpinPairs + 1);
    // (The others are as blocked.)
    for var K := 0 to 31 do
      if ((Written shr K) and 1) <> 0 then
        FBlockVF[K] := VF[K];
  end
  else
    Exit;
  VFWritten := 0;
  Result := True;
end;

// Turns of the known loop: their cycles and pairs (the state stays).
procedure TPS2VU0.SkipSpin(Turns: Integer);
begin
  Inc(FCore.S.Cycles, Turns * FSpinCycles);
  Inc(FCore.Executed, Turns * FSpinPairs);
  Inc(FSkippedTurns, Turns);
end;

procedure TPS2VU0.Interlock;
begin
  if FCore.S.Running then
    RunUntilBlocked;
end;

procedure TPS2VU0.Sync;
begin
  if FCore.S.Running then
    RunUntilBlocked;
end;

function TPS2VU0.VU1Busy: Boolean;
begin
  if FVU1Domain <> nil then
  begin
    // Running ahead: as the domain had VU1 at the EE time.
    if FVU1Domain.Ahead and Assigned(FVU1Domain.OnAheadBusy) and FVU1Domain.OnAheadBusy(Result) then
      Exit;
  end;
  FVU1Domain.Enter;
  try
    Result := FVU1.Busy(Now);
  finally
    FVU1Domain.Leave;
  end;
end;

procedure TPS2VU0.ResetVU1;
begin
  FVU1Domain.Enter;
  try
    FVU1.Reset;
  finally
    FVU1Domain.Leave;
  end;
end;

function TPS2VU0.Condition: Boolean;
begin
  // CPCOND2: VU0 runs a micro program (or is inside its busy window).
  Result := FCore.Busy(Now);
end;

function TPS2VU0.Now: Int64;
begin
  if Clock <> nil then
    Result := Clock^
  else
    Result := 0;
end;

procedure TPS2VU0.SerializeState(State: TStateArchive);
begin
  Inc(FTouches);
  inherited SerializeState(State);
  FCore.SerializeState(State);
end;

// (Macro operations then find the host rounding as the EE leaves it: the
// routines for it chosen once, not for each.)
procedure TPS2VU0.RunStarts;
begin
  FCore.CheckMath;
  FCore.FMacroMathKnown := True;
end;

procedure TPS2VU0.RunEnds;
begin
  FCore.FMacroMathKnown := False;
end;

// (The EE calls it while it runs: FMath is for its rounding then.)
function TPS2VU0.MacroRoutine(Op: Cardinal; out Target: Pointer; out Running: PBoolean): Pointer;
begin
  Target := FCore;
  Running := @FCore.S.Running;
  Result := nil;
  if FCore.UseJit then
    Result := FCore.MacroCode(Op);
end;

function TPS2VU0.RunningFlag: PBoolean;
begin
  Result := @FCore.S.Running;
end;

{ TPS2VU1 }

constructor TPS2VU1.Create(Code, Data: PByte);
begin
  inherited Create;
  FCore := TPS2VUCore.Create(1, @FVF, @FVI, Code, Data, $4000, $4000);
  Reset;
end;

destructor TPS2VU1.Destroy;
begin
  FCore.Free;
  inherited;
end;

procedure TPS2VU1.Reset;
begin
  FillChar(FVF, SizeOf(FVF), 0);
  FillChar(FVI, SizeOf(FVI), 0);
  FCore.Reset;
end;

procedure TPS2VU1.SaveDomain(out C: TPS2VU1Saved);
begin
  C.VF := FVF;
  C.VI := FVI;
  FCore.SaveRun(C.Core);
end;

procedure TPS2VU1.RestoreDomain(const C: TPS2VU1Saved);
begin
  FVF := C.VF;
  FVI := C.VI;
  FCore.RestoreRun(C.Core);
end;

procedure TPS2VU1.SerializeState(State: TStateArchive);
begin
  State.Field(FVF, SizeOf(FVF));
  State.Field(FVI, SizeOf(FVI));
  FCore.SerializeState(State);
end;

initialization
  for var MAC := 0 to High(MACGroups) do
  begin
    MACGroups[MAC] := Ord((MAC and $000F) <> 0) or
      (Ord((MAC and $00F0) <> 0) shl 1) or
      (Ord((MAC and $0F00) <> 0) shl 2) or
      (Ord((MAC and $F000) <> 0) shl 3);
    {$IFDEF PS2_CHECKED}
    // Exhaustively check against the former generated shift/OR reduction.
    var Fold := Cardinal(MAC);
    Fold := Fold or (Fold shr 1);
    Fold := Fold or (Fold shr 2);
    Fold := Fold and $1111;
    Fold := Fold or (Fold shr 3);
    Fold := Fold or (Fold shr 6);
    Fold := Fold and $F;
    if MACGroups[MAC] <> Fold then
      raise Exception.Create('MAC/status lookup differs from the reference reduction');
    {$ENDIF}
  end;

end.

