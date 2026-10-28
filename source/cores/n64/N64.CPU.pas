unit N64.CPU;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Diagnostics, N64.Types, N64.SoftFloat, HW.JIT,
  Core.Snapshots;

type
  TN64TLBEntry = record
    Mask, Lo0, Lo1: Cardinal;
    EntryHi: UInt64;
  end;

  // Memoized first-match TLB search. Matching depends only on address bits
  // 13..39 and 62..63, the current ASID and the TLB contents (Generation).
  TN64TLBLookup = record
    Key: UInt64;
    ASID, Generation: Cardinal;
    Index: Integer;
  end;

  // A successful address translation of one 4 KB virtual page, valid while
  // the TLB generation and the context (Status mode bits and ASID) match.
  TN64PageEntry = record
    Page: UInt64;
    Physical: UInt64;
    Context, Generation: Cardinal;
    ReadOK, WriteOK, Cached: Boolean;
  end;

  // One instruction of a block (TN64CPU.RunBlocks), decoded once: what it
  // does (Kind), its fields, its PClocks with the stall behind the one
  // before it (both fixed in a block), and what it leaves for the next one's
  // hazards. A LUI joined with the ORI/ADDIU after it (Kind KindLuiPair)
  // stands for both; Value is then their result.
  TN64CPUStep = record
    Value: UInt64;
    Op: Cardinal;
    Kind, S, T, D, N, Clocks, Size, Flags: Byte;
    LoadAfter, FPAfter: ShortInt;
    // Its first code word's index in the block.
    Index: Byte;
  end;

  PN64CPUStep = ^TN64CPUStep;

  // Steps from one physical code address, for one entry state (the hazards
  // left by the instruction before, the Status bits fast steps depend on,
  // whether it starts in a delay slot): up to the delay slot of its first
  // branch (or a likely branch itself), before the first instruction fast
  // steps do not take, or the page's end. Its Words code words (from Word)
  // are compared with RDRAM as it is entered: whatever wrote them (the CPU,
  // DMA, the RDP), it is then worked out again.
  PN64CPUBlock = ^TN64CPUBlock;

  TN64CPUBlock = record
    Physical: Cardinal;
    EntryLoad, EntryFP: ShortInt;
    Mode: Byte;
    // No step: FSlowSafe for the instruction there (not COP0).
    SlowSafe: Boolean;
    // Its page's write count (TN64Bus.CodeGeneration) when last checked.
    Gen: Cardinal;
    Count, Words: Integer;
    // Its steps and code words (each in one chunk, one after another).
    Steps: PN64CPUStep;
    Code: PCardinal;
    // The next block from the same bucket.
    Next: PN64CPUBlock;
    // The block entered after this one ran to its end: [0] the next
    // instruction, [1] a branch taken; at LinkPC (nil: none yet).
    Link: array[0..1] of PN64CPUBlock;
    LinkPC: array[0..1] of UInt64;
    // Its generated code (HW.JIT; nil: none, or not yet if not JitTried): its
    // steps with a LUI pair counted twice (JitSteps), their PClocks without
    // stalls (JitClocks) and an upper bound of all its PClocks (JitMax).
    Native, NativeInner: Pointer;
    JitSteps, JitClocks, JitMax: Cardinal;
    // Blocks entered after this one on another page, at FarPC:
    // its code jumps to theirs as RunBlocks would enter them.
    Far: array[0..1] of PN64CPUBlock;
    FarPC: array[0..1] of UInt64;
    // Direct links in its code (JitLink): the jump after its last step, the
    // blocks it goes to directly and at which PCs.
    JitTail: NativeInt;
    JitLinks: Integer;
    JitLinkTo: array[0..3] of PN64CPUBlock;
    JitLinkPC: array[0..3] of UInt64;
    JitTried: Boolean;
    // The careful code (JitCompile), for where Native may not run.
    NativeCareful: Pointer;
    CarefulTried: Boolean;
    // Entries before its code (or careful code) is made: blocks that run
    // only a few times are not compiled (JitHot).
    JitHeat, CarefulHeat: Word;
  end;

  TN64CPU = class
  private type
    // The floating-point inputs RunBlocks works out for a COP1 step.
    TStepFP = record
      A, B: UInt64;
      Res: TSoftFloatResult;
      Cycles: Cardinal;
      Target: Integer;
    end;
    PStepFP = ^TStepFP;
    // A block step's routine by its Kind (FStepRoutines; RunBlocks calls it
    // with Self after doing what every step shares): the instruction itself.
    // Physical: its data access (Step.Size <> 0); FP: the COP1 inputs.
    // Returns PClocks to add to the step's own.
    TStepRoutine = function(CPU: TObject; Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    // What RunBlocks and a block's code exchange (JitRun): the totals and
    // limits, the page context and mode; JitData's results (FastData's);
    // when the code returns, the last block it entered, the steps of that one
    // it completed (Done), the PClocks of their stalls and FP operations
    // beyond the steps' own (Extra) and whether its last store was cached.
    TJitCtx = record
      // Totals as RunBlocks's Clocks and Result, with the limits.
      Clocks, Limit: UInt64;
      Count, MaxSteps: Integer;
      // The last block entered and its PC.
      Block: PN64CPUBlock;
      BlockPC: UInt64;
      Context: Cardinal;
      // (64 bits: a step's argument as it is.)
      Physical: UInt64;
      Cached: Boolean;
      PrevStore: Boolean;
      Done: Integer;
      Extra: Cardinal;
      // KernelMode (for KSEG0/KSEG1 code on another page).
      Kernel: Boolean;
      // Data accesses through KSEG0/KSEG1 go as FastData takes them without
      // asking it (the code's own check): Context allows them, RDRAM is
      // direct, no SP DMA beat may wait (none of which changes in a batch).
      Direct: Boolean;
      FP: TStepFP;
    end;
    PJitCtx = ^TJitCtx;
    // What JitCompile carries from step to step (JitEmitStep): about the step
    // before, whether Store is known to be 0, and (careful code) the steps
    // and their PClocks so far.
    TJitStepState = record
      PrevBranch, PrevStore, PrevCondition, StoreZero: Boolean;
      PrefixSteps, PrefixClk: Integer;
    end;
  private
    const
      JitBufferSize = 128 * 1024 * 1024;
      KSeg0Base = UInt64($FFFFFFFF80000000);
      KSeg1Base = UInt64($FFFFFFFFA0000000);
      KSeg2Base = UInt64($FFFFFFFFC0000000);
      TLBKeyMask = UInt64($C00000FFFFFFE000);
    // FCR31 bits that keep floating point off the host (SFQuick): the
    // rounding mode (anything but nearest) and the inexact enable. The other
    // enables do not: where SFQuick gives a result, it is the same as
    // SoftFloat's with the same events, and those never include overflow,
    // underflow, invalid or division by zero (GoldenEye runs with invalid
    // enabled). The inexact enable keeps it off by choice, not for
    // exactness: SFQuick's inexact is SoftFloat's, so it traps either way.
      HostFloatOff = $83;
    // Block pool chunks, and how many a CPU may have (then its blocks are
    // dropped): about 19 MB in all on 64-bit hosts, 5 MB on 32-bit ones.
      BlockChunkSize = 1024;
      StepChunkSize = 8192;
    {$IFDEF CPU64BITS}
      MaxBlocks = 65536;
      MaxStepChunks = 64;
    {$ELSE}
      MaxBlocks = 16384;
      MaxStepChunks = 16;
    {$ENDIF}
  private
    FBus: TN64Bus;
    FTLBGeneration: Cardinal;
    FTLBLookups: array[0..63] of TN64TLBLookup;
    FPages: array[0..1023] of TN64PageEntry;
    // The 4 KB virtual page of the last instruction fetched through the TLB
    // from RDRAM, and its physical base: valid while FCodeValid and the TLB
    // generation and the context are unchanged.
    FCodePage: UInt64;
    FCodePhysical, FCodeGeneration, FCodeContext: Cardinal;
    FCodeValid: Boolean;
    // Idle loop most recently validated by IdleLimit (physical, both words).
    FIdlePhysical, FIdleBranch, FIdleSlot: Cardinal;
    FIdleGeneration: Cardinal;
    FPC, FNextPC, FInstructionPC: UInt64;
    FCyclesConsumed: Cardinal;
    FOperationCycles: Cardinal;
    FCP0Latch, FCOP2Latch: UInt64;
    FPreviousLoad, FPreviousFP: Integer;
    FPreviousStore, FPreviousCondition, FPreviousException: Boolean;
    FExecutingInstruction, FDataCached: Boolean;
    FDelay, FInDelay: Boolean;
    // LL's bit (set by LL and LLD, cleared by ERET) and the physical address
    // it loaded (LLAddr; snapshots keep it, SC does not compare it).
    FLL: Boolean;
    FLLAddress: UInt64;
    FCountHalf: Integer;
    // RunBatch: PClocks of the batch's instructions before the current one,
    // and whether the current one accessed a device.
    FBatching, FBatchDevice: Boolean;
    FBatchElapsed: UInt64;
    // FastStep: the 4 KB code page fetched from last, in RDRAM from
    // FFastCodePhysical, while the context and the TLB are the same.
    FFastCodePage: UInt64;
    FFastCodePhysical, FFastCodeContext, FFastCodeGeneration: Cardinal;
    FFastCodeValid: Boolean;
    // Set by FastStep when it declines: whether the instruction could leave
    // what FastReady found unchanged (all but COP0 instructions, if they do
    // not fault).
    FSlowSafe: Boolean;
    // Floating-point results by the host where SFQuick can (HostFloat).
    FHostFloat: Boolean;
    // Blocks (TN64CPUBlock): buckets by physical address, the blocks, their
    // steps and code words in pools, all dropped when one is full.
    FUseBlocks: Boolean;
    FBlockHead: array[0..32767] of PN64CPUBlock;
    // The pools in chunks, allocated as blocks are made (up to the limits
    // for the platform; then all blocks are dropped and the chunks used
    // again): blocks, steps and code words used so far.
    FBlockChunks: TArray<TArray<TN64CPUBlock>>;
    FStepChunks: TArray<TArray<TN64CPUStep>>;
    FWordChunks: TArray<TArray<Cardinal>>;
    FBlockCount, FStepChunk, FStepUsed, FWordChunk, FWordUsed: Integer;
    FBlockLimit, FChunkLimit: Integer;
    FBlockGen: Cardinal;
    FBlocksBuilt, FBlocksRun: Int64;
    // Set by RunBlocks: it stopped where FastRun may go on.
    FPlainNext: Boolean;
    // Where the last RunBlocks left off, for the next one (while no block
    // was dropped since, FCarryGen): after a block that ran to its end
    // (FLastBlock, ending at FLastEnd: its links), or within one (step
    // FResumeStep of FResumeBlock, at FResumePC).
    FLastBlock, FResumeBlock: PN64CPUBlock;
    FLastEnd, FResumePC: UInt64;
    FResumeStep: Integer;
    FCarryGen: Cardinal;
    // Blocks as generated code (HW.JIT): its writer, whether to use it and
    // whether its buffer filled up (all blocks are dropped at the next
    // BuildBlock).
    FJit: TJitAsm;
    FUseJit, FJitFull: Boolean;
    // The code all blocks share in FJit (JitEmitShared; FJitChain 0: none
    // yet): their entry, their way back to RunBlocks, the chaining code.
    FJitEnter, FJitReturn, FJitChain, FJitChainIdle: NativeInt;
    FJitCompiled, FJitRuns: Int64;
    // (N64JIT=stats: why chains ended, by reason.)
    FJitExits: array[0..23] of Int64;
    // The routines the code calls (CallAt, near the fields it uses most):
    // the steps' by Kind, then JitData and JitFP.
    FJitCalls: array[0..257] of Pointer;
    FJitDbg: array[0..3] of UInt64;
    FJitResets: Integer;
    FJitCompileTicks: Int64;
    FJitStats: Boolean;
    FJitSlowOps: array[0..255] of Int64;
    // (N64JIT=stats: what the code at each offset in FJit does, ascending.)
    FJitMapOffset: TArray<NativeInt>;
    FJitMapKind: TArray<Integer>;
    FJitMapCount: Integer;
    // JitCompile's ways out of a block (their labels, the steps done, the
    // status), kept from block to block: making a block's code calls no
    // memory manager, whose locks the RSP thread's calls would make it wait
    // for (10 ms, the RTL's sleep on a lock held).
    FJitExitLabel: TArray<TJitLabel>;
    FJitExitDone, FJitExitStatus: TArray<Integer>;
    FJitExitCount: Integer;
    // Data accesses the code's own check does not take, asked of JitData
    // after the block's steps (JitEmitData): where from, back to, the step.
    FJitSlowLabel, FJitSlowBack, FJitSlowStep: TArray<Integer>;
    FJitSlowCount: Integer;
    function JitExitTo(Done, Status: Integer): TJitLabel;
    procedure JitMark(Kind: Integer);
    procedure ClearBlocks;
    function BlockKey(EntryLoad, EntryFP: Integer; Mode: Byte; Physical: Cardinal): PN64CPUBlock;
    function BuildBlock(PC: UInt64; Physical: Cardinal; Mode: Byte): PN64CPUBlock;
    function BlockValid(B: PN64CPUBlock): Boolean; inline;
    function FastFloat(Op: Cardinal; A, B: UInt64; out R: TSoftFloatResult; out Cycles: Cardinal; out Target: Integer): Boolean;
    function RunBlocks(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
    function JitFP(Step: PN64CPUStep; Ctx: PJitCtx): Cardinal;
    function JitData(Ctx: PJitCtx; Step: PN64CPUStep): Cardinal;
    function JitCompile(B: PN64CPUBlock; Careful: Boolean = False): Pointer;
    procedure JitMeasure(B: PN64CPUBlock);
    procedure JitEmitStep(B: PN64CPUBlock; I: Integer; Careful: Boolean; var State: TJitStepState);
    function JitEmitOwn(S: PN64CPUStep): Boolean;
    procedure JitEmitData(B: PN64CPUBlock; I: Integer; NeedCached: Boolean);
    function JitStepArg(B: PN64CPUBlock; I: Integer): TJitOp;
    procedure JitEmitEnd(B: PN64CPUBlock; Careful: Boolean);
    procedure JitEmitReturn(B: PN64CPUBlock; FallThrough: Boolean);
    procedure JitEmitShared;
    procedure JitEmitChain;
    procedure JitLink(From, B: PN64CPUBlock; PC: UInt64);
    function JitRun(Code: Pointer; var B: PN64CPUBlock; var PC: UInt64; Limit: UInt64; MaxSteps: Integer; var Count: Integer;
      var Clocks: UInt64; var Jit: TJitCtx): Integer;
    // Block step routines (TStepRoutine), by Kind.
    class var FStepRoutines: array[Byte] of Pointer;
    function StepNop(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSRL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSRA(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSRLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSRAV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepJR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepJALR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMFHI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMTHI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMFLO(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMTLO(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSLLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRAV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMULT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMULTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDIV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDIVU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDMULT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDMULTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDDIV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDDIVU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepADDU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSUBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepAND(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepXOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepNOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDADDU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSUBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSLL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRA(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSLL32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRL32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDSRA32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepRegimm(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepJ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepJAL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBEQ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBEQL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBNE(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBNEL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBLEZ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBLEZL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBGTZ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBGTZL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepADDIU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLTI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSLTIU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepANDI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepORI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepXORI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLUI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLB(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLH(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLW(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLHU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLWU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLWC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLDC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepLD(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSB(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSH(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSW(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSD(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSWC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepSDC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMFC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDMFC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepMTC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepDMTC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepFPCompare(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepFPArith(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepFPMov(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    function StepBC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
    procedure DeviceAccess; inline;
    function FastCode(PC: UInt64; Context: Cardinal): Boolean;
    function FastData(Address: UInt64; Size: Integer; Writing: Boolean; Context: Cardinal; out Physical: Cardinal; out Cached: Boolean): Boolean; inline;
    function FastReady(out Context: Cardinal; out UntilCompare: UInt64): Boolean;
    function FastRun(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
    function IdleHead: Boolean; inline;
    procedure FastFlush(Clocks: Cardinal; Count: Integer);
    procedure SetPCExact(Value: UInt64); inline;
    procedure ApplyStalls(Op: Cardinal);
    procedure ApplyInterlocks(Op: Cardinal); inline;
    function KernelMode: Boolean; inline;
    function FindTLB(Address: UInt64): Integer;
    function CachedAddressSlow(Address: UInt64): Boolean;
    function CachedAddress(Address: UInt64): Boolean; inline;
    function FPRegister(Index: Integer): Integer; inline;
    function GetIdleInstructionClocks: Cardinal; inline;
    function GetIdleCandidate: Boolean; inline;
    function FPClocks(A, B: UInt64; Format, Fn: Integer): Cardinal; inline;
    function TranslateSlow(Address: UInt64; Writing: Boolean): UInt64;
    function TranslateMapped(Address: UInt64; Writing: Boolean): UInt64;
    function PageContext: Cardinal; inline;
    function PageSlot(Page: UInt64): Integer; inline;
    function KernelFetchAddress(Address: UInt64; out Physical: Cardinal): Boolean;
    function Translate(Address: UInt64; Writing: Boolean): UInt64; inline;
    function TranslateData(Address: UInt64; Writing: Boolean; out Cached: Boolean): UInt64;
    function Fetch: Cardinal; inline;
    function Load(Address: UInt64; Size: Integer): UInt64;
    procedure Store(Address: UInt64; Size: Integer; Value: UInt64);
    procedure Fault(Code: Integer; Address: UInt64 = 0; Refill: Boolean = False; Cop: Integer = 0);
    procedure Branch(Taken, Likely: Boolean; Target: UInt64); inline;
    procedure ExecuteInstruction;
    procedure Special(Op: Cardinal); inline;
    procedure Cop0(Op: Cardinal); inline;
    // Not inline: ExecuteInstruction, every instruction's slow path, does
    // better without its bulk.
    procedure Cop1(Op: Cardinal);
    function FPBits(Index, Format: Integer): UInt64; inline;
    procedure SetFPBits(Index, Format: Integer; Value: UInt64); inline;
    procedure Cop2(Op: Cardinal); inline;
    procedure AdvanceClocks(Clocks: Cardinal); inline;
    procedure AdvanceCount(Clocks: Cardinal);
    procedure FPExceptions(Events: Cardinal; Unimplemented: Boolean = False); inline;
  public
    GPR: array[0..31] of UInt64;
    CP0: array[0..31] of UInt64;
    FPR: array[0..31] of UInt64;
    FCR31: Cardinal;
    HI, LO: UInt64;
    TLB: array[0..31] of TN64TLBEntry;
    // Set by whoever runs the CPU, on the thread that runs it: whether its
    // floating point suits SFQuick (SFHostReady). Exact either way.
    property HostFloat: Boolean read FHostFloat write FHostFloat;
    // Fast steps from blocks of decoded instructions (on by default; the same
    // steps either way).
    property UseBlocks: Boolean read FUseBlocks write FUseBlocks;
    property BlocksBuilt: Int64 read FBlocksBuilt;
    property BlocksRun: Int64 read FBlocksRun;
    // Tests: all blocks dropped once Blocks were made or Chunks chunks of
    // steps used (both at least 1).
    procedure LimitBlocks(Blocks, Chunks: Integer);
    // Blocks run as generated code where HW.JIT can make it (Win64, Linux
    // x64, Android ARM64; the same steps either way).
    property UseJit: Boolean read FUseJit write FUseJit;
    // Whether there is generated code here (a backend, not N64JIT=off).
    class function JitAvailable: Boolean; static;
    // Tests: blocks made generated code from their Hot+1th run on (0: their
    // first), by HW.JIT's model with Model (CPUs that make their first code
    // after this).
    class procedure JitForTests(Hot: Integer; Model: Boolean); static;
    property JitCompiled: Int64 read FJitCompiled;
    property JitRuns: Int64 read FJitRuns;
    // (N64JIT=stats) What generated code at Address does: a step kind, 1000+
    // block parts, 2000+ shared code; -1: not in the code.
    function JitWhat(Address: UInt64): Integer;
    constructor Create(Bus: TN64Bus);
    destructor Destroy; override;
    procedure Reset;
    procedure Step;
    // Up to MaxSteps Steps, stopping after the one that brought their
    // PClocks to Budget or more (an event is due by then), after one that
    // accessed a device (FBus.SyncDevice came first; the device may have
    // changed what comes next) and where IdleLimit may find an idle loop's
    // head. Returns how many ran; Cycles: their PClocks.
    function RunBatch(MaxSteps: Integer; Budget: UInt64; out Cycles: UInt64): Integer;
    function SkipIdle(MaxInstructions: Integer): Integer;
    // Idle-loop fast-forward across device events. IdleLimit validates the
    // loop at its head; ApplyIdle then stands for Count single steps, with
    // Pending the MI interrupt line seen by the last of them. The caller
    // stops when IdleWouldInterrupt or not IdleCodeIntact after an event.
    function IdleLimit: Integer;
    function IdleCodeIntact: Boolean;
    function IdleWouldInterrupt(Pending: Boolean): Boolean;
    procedure ApplyIdle(Count: Integer; Pending: Boolean);
    procedure SerializeState(State: TStateArchive);
    procedure SetPC(Value: UInt64);
    // Call after writing TLB entries directly instead of through TLBWI/TLBWR.
    procedure InvalidateTLBCache;
    property PC: UInt64 read FPC write SetPC;
    property CyclesConsumed: Cardinal read FCyclesConsumed;
    property IdleInstructionClocks: Cardinal read GetIdleInstructionClocks;
    // False when SkipIdle would certainly decline: it only examines delay slots.
    property IdleCandidate: Boolean read GetIdleCandidate;
  end;

implementation

type
  // N64JIT (debugging): off, stats (counts, and a map of the code for
  // profiles), nochain, hotN; no code for blocks with nobranch, nomem,
  // nostore, nofp, nolui; calls (every step by its routine, none written
  // out in the code); model (the code run by HW.JIT's model, for the
  // tests: much slower).
  TJitDebug = (jdOff, jdStats, jdNoChain, jdNoBranch, jdNoMem, jdNoStore, jdNoFP, jdNoLui, jdCalls, jdModel);

const
  JitDebugNames: array[TJitDebug] of string = ('off', 'stats', 'nochain', 'nobranch', 'nomem', 'nostore', 'nofp', 'nolui',
    'calls', 'model');
  // Blocks as generated code where HW.JIT has a backend (N64_NO_JIT: never).
  N64Jit = {$IFDEF N64_NO_JIT}False{$ELSE}JitSupported{$ENDIF};

var
  JitDebug: set of TJitDebug;
  // Entries of a block before its code is made (N64JIT=hotN sets it).
  JitHot: Integer = 16;

// (N64JIT=stats: time spent making blocks' code.)
function JitTicks: Int64;
begin
  Result := TStopwatch.GetTimeStamp;
end;

function JitTickRate: Double;
begin
  Result := TStopwatch.Frequency;
end;

type
  // A guest exception (Fault) leaving the instruction for Step. Its object is
  // its thread's buffer, not the memory manager's (GoldenEye raises some 160
  // a VI, and a memory manager call that finds the lock held sleeps 10 ms).
  EGuestFault = class(Exception)
  public
    class function NewInstance: TObject; override;
    procedure FreeInstance; override;
  end;

threadvar
  GuestFaultBuffer: array[0..31] of UInt64;
  GuestFaultBusy: Boolean;

class function EGuestFault.NewInstance: TObject;
begin
  // (One raised in a handler of another: from the memory manager.)
  if GuestFaultBusy or (InstanceSize > SizeOf(GuestFaultBuffer)) then
    Exit(inherited NewInstance);
  GuestFaultBusy := True;
  Result := InitInstance(@GuestFaultBuffer);
end;

procedure EGuestFault.FreeInstance;
begin
  if Pointer(Self) <> @GuestFaultBuffer then
  begin
    inherited;
    Exit;
  end;
  CleanupInstance;
  GuestFaultBusy := False;
end;

constructor TN64CPU.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  FUseBlocks := True;
  FUseJit := N64Jit and not (jdOff in JitDebug);
  FJitStats := jdStats in JitDebug;
  FBlockLimit := MaxBlocks;
  FChunkLimit := MaxStepChunks;
  ClearBlocks;
  Reset;
end;

destructor TN64CPU.Destroy;
const
  Names: array[0..22] of string = ('idle head', 'delay', 'PC unaligned', 'NextPC', 'other page', 'link PC 0', 'link PC 1',
    'no link', 'mode', 'entry load', 'entry FP', 'no code', 'code written', 'clocks', 'steps', 'decline', 'rewrite',
    'ran to end', 'not kernel', 'no page', 'past RAM', 'SP hazard', 'RDP work');
begin
  if IsConsole and (jdStats in JitDebug) then
  begin
    Writeln(ErrOutput, Format('JIT: %d blocks compiled, %d of %d block runs as code', [FJitCompiled, FJitRuns, FBlocksRun]));
    if FJit <> nil then
      Writeln(ErrOutput, Format('JIT: %d resets, %d bytes now, blocks built %d, first compiles %.1f ms', [FJitResets, FJit.Offset, FBlocksBuilt, FJitCompileTicks * 1000 / JitTickRate]));
    for var K := 0 to High(Names) do
      if FJitExits[K] <> 0 then
        Writeln(ErrOutput, Format('  exit %-12s %d', [Names[K], FJitExits[K]]));
    for var K := 0 to 255 do
      if FJitSlowOps[K] > 10000 then
        Writeln(ErrOutput, Format('  slow op %d: %d', [K, FJitSlowOps[K]]));
    if FJitDbg[2] <> 0 then
    begin
      var DB := PN64CPUBlock(FJitDbg[2]);
      Writeln(ErrOutput, Format('  last delay path: PC %x entry %x; block phys %x mode %d count %d words %d', [FJitDbg[0], FJitDbg[1], DB.Physical, DB.Mode, DB.Count, DB.Words]));
      for var I := 0 to DB.Count - 1 do
      begin
        var DS := PN64CPUStep(NativeUInt(DB.Steps) + NativeUInt(I) * SizeOf(TN64CPUStep));
        Writeln(ErrOutput, Format('    step %d kind %d flags %x index %d op %.8x', [I, DS.Kind, DS.Flags, DS.Index, DS.Op]));
      end;
    end;
  end;
  FJit.Free;
  inherited;
end;

procedure TN64CPU.SetPC(Value: UInt64);
begin
  // Public debugger/boot convenience accepts legacy 32-bit kernel addresses.
  // Architectural ERET and branch targets preserve the full virtual address.
  if Value <= $FFFFFFFF then
    Value := SX(Value, 32);
  SetPCExact(Value);
end;

procedure TN64CPU.SetPCExact(Value: UInt64);
begin
  FPC := Value;
  FNextPC := Add64(Value, 4);
  FDelay := False;
end;

procedure TN64CPU.AdvanceClocks(Clocks: Cardinal);
begin
  // COUNT runs at half the PClock; an odd half-tick needs no compare check.
  if (Clocks = 1) and (FCountHalf = 0) then
  begin
    FCountHalf := 1;
    CP0[9] := CP0[9] and $FFFFFFFF;
  end
  else
    AdvanceCount(Clocks);
end;

procedure TN64CPU.AdvanceCount(Clocks: Cardinal);
begin
  var Total := UInt64(Clocks) + Cardinal(FCountHalf);
  var Ticks := Total div 2;
  FCountHalf := Integer(Total and 1);
  var OldCount := CP0[9] and $FFFFFFFF;
  var Distance := (UInt64(CP0[11] and $FFFFFFFF) + UInt64($100000000) - OldCount) and $FFFFFFFF;
  if Distance = 0 then
    Distance := $100000000;
  if Ticks >= Distance then
    CP0[13] := CP0[13] or $8000;
  CP0[9] := (OldCount + Ticks) and $FFFFFFFF;
end;

procedure TN64CPU.InvalidateTLBCache;
begin
  FCodeValid := False;
  if FTLBGeneration = High(Cardinal) then
  begin
    for var I := 0 to High(FTLBLookups) do
      FTLBLookups[I] := Default(TN64TLBLookup);
    for var I := 0 to High(FPages) do
      FPages[I] := Default(TN64PageEntry);
    FTLBGeneration := 1;
  end
  else
    Inc(FTLBGeneration);
end;

function TN64CPU.PageContext: Cardinal;
begin
  // Everything besides the TLB that TranslateSlow and CachedAddressSlow read:
  // Status EXL, ERL, KSU, UX, SX, KX, and the current ASID.
  Result := Cardinal(CP0[12] and $FE) or (Cardinal(CP0[10] and $FF) shl 8);
end;

function TN64CPU.PageSlot(Page: UInt64): Integer;
begin
  Result := Integer((Page xor (Page shr 10)) and High(FPages));
end;

function TN64CPU.TranslateMapped(Address: UInt64; Writing: Boolean): UInt64;
begin
  // A minimum TLB page is 4 KB, so a 4 KB virtual page translates as one
  // block. Only successful translations are kept; faults take the full path.
  var Page := Address shr 12;
  var Slot := PageSlot(Page);
  var Context := PageContext;
  if (FPages[Slot].Page = Page) and (FPages[Slot].Generation = FTLBGeneration) and
    (FPages[Slot].Context = Context) and (FPages[Slot].WriteOK or (not Writing and FPages[Slot].ReadOK)) then
    Exit(FPages[Slot].Physical or (Address and $FFF));
  Result := TranslateSlow(Address, Writing);
  var Same := (FPages[Slot].Page = Page) and (FPages[Slot].Generation = FTLBGeneration) and
    (FPages[Slot].Context = Context);
  FPages[Slot].Page := Page;
  FPages[Slot].Generation := FTLBGeneration;
  FPages[Slot].Context := Context;
  FPages[Slot].Physical := Result and not UInt64($FFF);
  // A write that translates can read too; a read says nothing about writing.
  FPages[Slot].WriteOK := Writing or (Same and FPages[Slot].WriteOK);
  FPages[Slot].ReadOK := True;
  FPages[Slot].Cached := CachedAddressSlow(Address);
end;

function TN64CPU.KernelMode: Boolean;
begin
  // Matches Translate's mode decode: EXL/ERL or KSU=0 select kernel mode.
  Result := ((CP0[12] and 6) <> 0) or ((CP0[12] and $18) = 0);
end;

function TN64CPU.FindTLB(Address: UInt64): Integer;
begin
  var Key := Address and TLBKeyMask;
  var ASID := Cardinal(CP0[10] and $FF);
  var Slot := Integer((Key shr 13) and High(FTLBLookups));
  if (FTLBLookups[Slot].Generation = FTLBGeneration) and (FTLBLookups[Slot].Key = Key) and
    (FTLBLookups[Slot].ASID = ASID) then
    Exit(FTLBLookups[Slot].Index);
  Result := -1;
  for var I := 0 to 31 do
  begin
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var MatchMask: UInt64 := TLBKeyMask and not Mask;
    if ((Address and MatchMask) = (TLB[I].EntryHi and MatchMask)) and
      (((TLB[I].Lo0 and TLB[I].Lo1 and 1) <> 0) or
      ((TLB[I].EntryHi and $FF) = ASID)) then
    begin
      Result := I;
      Break;
    end;
  end;
  FTLBLookups[Slot].Key := Key;
  FTLBLookups[Slot].ASID := ASID;
  FTLBLookups[Slot].Generation := FTLBGeneration;
  FTLBLookups[Slot].Index := Result;
end;

procedure TN64CPU.Reset;
begin
  for var I := 0 to 31 do
  begin
    GPR[I] := 0;
    CP0[I] := 0;
    FPR[I] := 0;
    TLB[I] := Default(TN64TLBEntry);
  end;
  InvalidateTLBCache;
  HI := 0;
  LO := 0;
  FCR31 := 0;
  FLL := False;
  FCountHalf := 0;
  FCyclesConsumed := 0;
  FOperationCycles := 1;
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousStore := False;
  FPreviousCondition := False;
  FPreviousException := False;
  FExecutingInstruction := False;
  FDataCached := False;
  FCP0Latch := 0;
  FCOP2Latch := 0;
  CP0[1] := 31;
  CP0[12] := $34000000;
  CP0[15] := $B22;
  CP0[16] := $7006E463;
  GPR[6] := SX($A4001F0C, 32);
  GPR[7] := SX($A4001F08, 32);
  GPR[8] := $C0;
  GPR[10] := $40;
  GPR[11] := SX($A4000040, 32);
  GPR[20] := 1;
  GPR[22] := $3F;
  GPR[29] := SX($A4001FF0, 32);
  GPR[31] := SX($A4001550, 32);
  SetPC($A4000040);
end;

procedure TN64CPU.Fault(Code: Integer; Address: UInt64; Refill: Boolean; Cop: Integer);
begin
  // NEC VR4300 UM pipeline exception: abort and stall for two PClocks.
  // Aborted instructions do not retain their speculative interlock requests.
  FCyclesConsumed := FOperationCycles + 2;
  if Code = 0 then
    FCyclesConsumed := 2;
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousStore := False;
  FPreviousCondition := False;
  FPreviousException := True;
  var KeepCause := CP0[13] and $FF00;
  if (CP0[12] and 2) <> 0 then
    KeepCause := KeepCause or (CP0[13] and $80000000);
  CP0[13] := KeepCause or Cardinal(Code shl 2) or Cardinal(Cop shl 28);
  if (CP0[12] and 2) = 0 then
  begin
    CP0[14] := FInstructionPC;
    if FInDelay then
    begin
      CP0[14] := Sub64(FInstructionPC, 4);
      CP0[13] := CP0[13] or $80000000;
    end;
  end
  else
    Refill := False;
  // TLB exceptions and address errors alike: BadVAddr, and its page in
  // Context, XContext and EntryHi (ASID kept).
  if Code in [1, 2, 3, 4, 5] then
  begin
    CP0[8] := Address;
    CP0[4] := (CP0[4] and $FFFFFFFFFF800000) or ((Address shr 9) and $007FFFF0);
    CP0[20] := (CP0[20] and $FFFFFFFE00000000) or
      ((Address shr 31) and $180000000) or ((Address shr 9) and $7FFFFFF0);
    CP0[10] := (Address and $C00000FFFFFFE000) or (CP0[10] and $FF);
  end;
  CP0[12] := CP0[12] or 2;
  if FBus.TraceEnabled then
    FBus.Trace(GuestException, FInstructionPC, Address, CP0[13]);
  var Vector: UInt64 := $FFFFFFFF80000180;
  if Refill then
  begin
    Vector := $FFFFFFFF80000000;
    if (Address <> SX(Address, 32)) and (Vector = $FFFFFFFF80000000) then
      Vector := $FFFFFFFF80000080;
  end;
  if (CP0[12] and $400000) <> 0 then
    if Refill then
    begin
      Vector := $FFFFFFFFBFC00200;
      if Address <> SX(Address, 32) then
        Vector := $FFFFFFFFBFC00280;
    end
    else
      Vector := $FFFFFFFFBFC00380;
  SetPC(Vector);
  raise EGuestFault.Create('');
end;

function TN64CPU.TranslateData(Address: UInt64; Writing: Boolean; out Cached: Boolean): UInt64;
begin
  // Translate and CachedAddress in one page lookup: a mapped translation
  // leaves its page's entry in this context, which is what CachedAddress
  // reads.
  if (Address >= KSeg0Base) and (Address < KSeg2Base) then
  begin
    Cached := Address < KSeg1Base;
    if KernelMode then
      Exit(Address and $1FFFFFFF);
    Exit(TranslateMapped(Address, Writing));
  end;
  var Page := Address shr 12;
  var Slot := PageSlot(Page);
  if (FPages[Slot].Page = Page) and (FPages[Slot].Generation = FTLBGeneration) and
    (FPages[Slot].Context = PageContext) and (FPages[Slot].WriteOK or (not Writing and FPages[Slot].ReadOK)) then
  begin
    Cached := FPages[Slot].Cached;
    Exit(FPages[Slot].Physical or (Address and $FFF));
  end;
  Result := TranslateMapped(Address, Writing);
  Cached := FPages[Slot].Cached;
end;

function TN64CPU.Translate(Address: UInt64; Writing: Boolean): UInt64;
begin
  // Kernel KSEG0/KSEG1 is unmapped; every other case takes the full decoder.
  if (Address >= KSeg0Base) and (Address < KSeg2Base) and KernelMode then
    Result := Address and $1FFFFFFF
  else
    Result := TranslateMapped(Address, Writing);
end;

function TN64CPU.TranslateSlow(Address: UInt64; Writing: Boolean): UInt64;
begin
  var Status := CP0[12];
  var Mode := Integer((Status shr 3) and 3);
  if (Status and 6) <> 0 then
    Mode := 0;
  var Extended := (Status and (UInt64($80) shr Mode)) <> 0;
  var Canonical32 := Address = SX(Address, 32);
  var Low := Cardinal(Address and $FFFFFFFF);
  var InvalidAddress := not Canonical32 and not Extended;
  if Canonical32 then
  begin
    if ((Status and 4) <> 0) and (Low < $80000000) then
      Exit(Low);
    if (Mode = 2) and (Low >= $80000000) then
      InvalidAddress := True;
    if (Mode = 1) and (Low >= $80000000) and (Low < $C0000000) then
      InvalidAddress := True;
    if (Mode = 1) and (Low >= $E0000000) then
      InvalidAddress := True;
    if not InvalidAddress and (Low >= $80000000) and (Low < $C0000000) then
      Exit(Low and $1FFFFFFF);
  end
  else
  begin
    var Region := Address shr 62;
    if (Mode = 2) and (Region <> 0) then
      InvalidAddress := True;
    if (Mode = 1) and (Region > 1) then
      InvalidAddress := True;
    if Region = 2 then
    begin
      if (Mode <> 0) or ((Address and $07FFFFFF00000000) <> 0) then
        InvalidAddress := True;
      if not InvalidAddress then
        Exit(Address and $FFFFFFFF);
    end
    else if (Address and $3FFFFF0000000000) <> 0 then
      InvalidAddress := True;
  end;
  if InvalidAddress then
    if Writing then
      Fault(5, Address)
    else
      Fault(4, Address);
  var I := FindTLB(Address);
  if I >= 0 then
  begin
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var HalfMask := (Mask shr 1) + 1;
    var L := TLB[I].Lo0;
    if (Address and HalfMask) <> 0 then
      L := TLB[I].Lo1;
    if (L and 2) = 0 then
      if Writing then
        Fault(3, Address)
      else
        Fault(2, Address);
    if Writing and ((L and 4) = 0) then
      Fault(1, Address);
    Exit(((UInt64(L shr 6) shl 12) and not (HalfMask - 1)) or (Address and (HalfMask - 1)));
  end;
  if Writing then
    Fault(3, Address, True)
  else
    Fault(2, Address, True);
  Result := 0;
end;

function TN64CPU.FPRegister(Index: Integer): Integer;
begin
  if (CP0[12] and $4000000) = 0 then
    Index := Index and 30;
  Result := Index + 32;
end;

function TN64CPU.GetIdleInstructionClocks: Cardinal;
begin
  Result := 1;
end;

function TN64CPU.GetIdleCandidate: Boolean;
begin
  Result := FInDelay and not FDelay;
end;

function TN64CPU.CachedAddress(Address: UInt64): Boolean;
begin
  // KSEG0 is cached and KSEG1 uncached in every mode (see CachedAddressSlow).
  if (Address >= KSeg0Base) and (Address < KSeg2Base) then
    Result := Address < KSeg1Base
  else
  begin
    // A page translated in this context knows its cache attribute.
    var Page := Address shr 12;
    var Slot := PageSlot(Page);
    if (FPages[Slot].Page = Page) and (FPages[Slot].Generation = FTLBGeneration) and
      (FPages[Slot].Context = PageContext) then
      Result := FPages[Slot].Cached
    else
      Result := CachedAddressSlow(Address);
  end;
end;

function TN64CPU.CachedAddressSlow(Address: UInt64): Boolean;
begin
  Result := False;
  if Address = SX(Address, 32) then
  begin
    var Low := Cardinal(Address and $FFFFFFFF);
    if ((CP0[12] and 4) <> 0) and (Low < $80000000) then
      Exit;
    if (Low >= $80000000) and (Low < $A0000000) then
      Exit(True);
    if (Low >= $A0000000) and (Low < $C0000000) then
      Exit;
  end
  else if (Address shr 62) = 2 then
    Exit(((Address shr 59) and 7) <> 2);
  var I := FindTLB(Address);
  if I >= 0 then
  begin
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var L := TLB[I].Lo0;
    if (Address and ((Mask shr 1) + 1)) <> 0 then
      L := TLB[I].Lo1;
    Result := ((L shr 3) and 7) <> 2;
  end;
end;

const
  // ApplyStalls: the registers an instruction reads (bit 0 rs, bit 1 rt,
  // bit 3 the FP register named by rt) and whether it accesses memory
  // (bit 2); by opcode, and SPECIAL by function. COP0, COP1 and COP2 are
  // decoded in ApplyStalls.
  OpReads: array[0..63] of Byte = (
    0, 1, 0, 0, 3, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 3, 3, 1, 1, 1, 1, 7, 7, 0, 0, 0, 0,
    5, 5, 7, 5, 5, 5, 7, 5, 7, 7, 7, 7, 7, 7, 7, 0,
    5, 5, 5, 5, 5, 5, 5, 5, 7, 13, 5, 5, 7, 13, 5, 5);
  SpecialReads: array[0..63] of Byte = (
    2, 0, 2, 2, 3, 0, 3, 3, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 1, 0, 1, 3, 0, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 0, 2, 0, 2, 2, 2, 0, 2, 2);

procedure TN64CPU.ApplyStalls(Op: Cardinal);
begin
  var Code := Op shr 26;
  var S := Integer((Op shr 21) and 31);
  var T := Integer((Op shr 16) and 31);
  var Fn := Integer(Op and 63);
  var RS := -1;
  var RT := -1;
  var FS := -1;
  var FT := -1;
  var Reads: Byte;
  case Code of
    0:
      Reads := SpecialReads[Fn];
    16, 18:
      begin
        Reads := 0;
        if S in [4..6] then
          RT := T;
      end;
    17:
      begin
        Reads := 0;
        if S in [4..6] then
          RT := T;
        if S in [0, 1] then
          FS := FPRegister(Integer((Op shr 11) and 31));
        if S in [16, 17, 20, 21] then
        begin
          FS := FPRegister(Integer((Op shr 11) and 31));
          if (Fn <= 3) or (Fn >= 48) then
            FT := FPRegister(T);
        end;
      end;
  else
    Reads := OpReads[Code];
  end;
  if (Reads and 1) <> 0 then
    RS := S;
  if (Reads and 2) <> 0 then
    RT := T;
  if (Reads and 8) <> 0 then
    FS := FPRegister(T);
  var Memory := (Reads and 4) <> 0;
  if ((FPreviousLoad >= 0) and ((FPreviousLoad = RS) or (FPreviousLoad = RT) or
    (FPreviousLoad = FS) or (FPreviousLoad = FT))) then
    Inc(FCyclesConsumed);
  if (Code = 17) and (S in [16, 17, 20, 21]) and (FPreviousFP >= 0) and
    ((FPreviousFP = FS) or (FPreviousFP = FT)) then
    Inc(FCyclesConsumed);
  if FPreviousCondition and (Code = 17) and (S = 8) then
    Inc(FCyclesConsumed);
  if FPreviousException and (Code = 16) and (S in [0, 1]) then
    Inc(FCyclesConsumed);
  if FPreviousStore and Memory and CachedAddress(Add64(GPR[S], SX16(Op))) then
    Inc(FCyclesConsumed);
end;

procedure TN64CPU.ApplyInterlocks(Op: Cardinal);
begin
  // Stalls only depend on the previous instruction's hazard records.
  if (FPreviousLoad >= 0) or (FPreviousFP >= 0) or FPreviousCondition or
    FPreviousException or FPreviousStore then
    ApplyStalls(Op);
  FPreviousLoad := -1;
  FPreviousFP := -1;
  FPreviousCondition := False;
  FPreviousException := False;
  FPreviousStore := False;
  var Code := Op shr 26;
  var Wide := False;
  case Code of
    0:
      Wide := (Op and 63) in [20, 22, 23, 28..31, 44..47, 56, 58..60, 62, 63];
    16, 18:
      Wide := ((Op shr 21) and 31) in [1, 5];
    17:
      begin
        var S := (Op shr 21) and 31;
        if S in [16, 17, 20, 21] then
          if (Op and 63) >= 48 then
            FPreviousCondition := True
          else
            FPreviousFP := FPRegister(Integer((Op shr 6) and 31));
        if S >= 16 then
          Wide := (S = 21) or ((Op and 63) in [8..11, 37])
        else
          Wide := S in [1, 5];
      end;
    24, 25:
      Wide := True;
    26, 27, 52, 55:
      begin
        var T := Integer((Op shr 16) and 31);
        if T <> 0 then
          FPreviousLoad := T;
        Wide := True;
      end;
    32..39, 48:
      begin
        var T := Integer((Op shr 16) and 31);
        if T <> 0 then
          FPreviousLoad := T;
      end;
    49, 53:
      FPreviousLoad := FPRegister(Integer((Op shr 16) and 31));
    40..46, 56, 57, 61:
      FPreviousStore := CachedAddress(Add64(GPR[(Op shr 21) and 31], SX16(Op)));
    60, 63:
      begin
        FPreviousStore := CachedAddress(Add64(GPR[(Op shr 21) and 31], SX16(Op)));
        Wide := True;
      end;
  end;
  if Wide then
  begin
    var Mode := Integer((CP0[12] shr 3) and 3);
    if ((CP0[12] and 6) <> 0) then
      Mode := 0;
    if (Mode <> 0) and ((CP0[12] and (UInt64($80) shr Mode)) = 0) then
      Fault(10);
  end;
end;

function TN64CPU.FPClocks(A, B: UInt64; Format, Fn: Integer): Cardinal;
begin
  // NEC U10504EJ7V0UMJ1: tables 7-13/7-14 and section 7.5.6.
  Result := 1;
  case Fn of
    0, 1:
      Result := 3;
    2:
      if Format = 16 then
        Result := 5
      else
        Result := 8;
    3, 4:
      if Format = 16 then
        Result := 29
      else
        Result := 58;
    8..15, 36, 37:
      Result := 5;
    32:
      if Format = 17 then
        Result := 2
      else
        Result := 5;
    33:
      if Format = 16 then
        Result := 1
      else
        Result := 5;
  end;
  if Result <= 2 then
    Exit;
  if Format in [20, 21] then
  begin
    if A = 0 then
      Result := 2;
    Exit;
  end;
  var Exponent: UInt64 := $7FF0000000000000;
  var Fraction: UInt64 := $FFFFFFFFFFFFF;
  var Sign: UInt64 := UInt64(1) shl 63;
  if Format = 16 then
  begin
    Exponent := $7F800000;
    Fraction := $7FFFFF;
    Sign := $80000000;
  end;
  var SimpleA := ((A and not Sign) = 0) or ((A and Exponent) = Exponent) or SFIsSubnormal(A, Format);
  var SimpleB := ((B and not Sign) = 0) or ((B and Exponent) = Exponent) or SFIsSubnormal(B, Format);
  if SimpleA or ((Fn <= 3) and SimpleB) then
    Result := 2;
  if (Fn = 4) and ((A and Sign) <> 0) then
    Result := 2;
  if (Fn = 2) and (((A and Fraction) = 0) or ((B and Fraction) = 0)) then
    Result := 2;
end;

function TN64CPU.Fetch: Cardinal;
begin
  // Aligned kernel KSEG0/KSEG1 code in RDRAM, aligned code in the mapped
  // RDRAM page fetched last; Load handles everything else (an instruction
  // fetch has none of its data-access side effects).
  // (SP DMA beats that may have waited and would write the code run first.)
  var Address := FPC;
  if (Address >= KSeg0Base) and (Address < KSeg2Base) and ((Address and 3) = 0) and KernelMode and
    ((Address and $1FFFFFFF) + 4 <= FBus.RAMSize) then
  begin
    if FBus.SPReadHazard(Cardinal(Address and $1FFFFFFF)) then
      DeviceAccess;
    Exit(FBus.ReadRAM32(Cardinal(Address and $1FFFFFFF)));
  end;
  if (Address and 3) = 0 then
  begin
    if FCodeValid and ((Address shr 12) = FCodePage) and (FCodeGeneration = FTLBGeneration) and
      (FCodeContext = PageContext) then
    begin
      if FBus.SPReadHazard(FCodePhysical) then
        DeviceAccess;
      Exit(FBus.ReadRAM32(FCodePhysical or Cardinal(Address and $FFF)));
    end;
    // Translate faults just as Load's would.
    var Physical := Translate(Address, False);
    if Physical + 4 <= FBus.RAMSize then
    begin
      // A whole 4 KB page: RDRAM ends on a page boundary.
      if not ((Address >= KSeg0Base) and (Address < KSeg2Base) and KernelMode) then
      begin
        FCodePage := Address shr 12;
        FCodePhysical := Cardinal(Physical and not UInt64($FFF));
        FCodeGeneration := FTLBGeneration;
        FCodeContext := PageContext;
        FCodeValid := True;
      end;
      if FBus.SPReadHazard(Cardinal(Physical)) then
        DeviceAccess;
      Exit(FBus.ReadRAM32(Cardinal(Physical)));
    end;
  end;
  Result := Cardinal(Load(Address, 4));
end;

function TN64CPU.Load(Address: UInt64; Size: Integer): UInt64;
begin
  if (Address and Cardinal(Size - 1)) <> 0 then
    Fault(4, Address);
  var Cached: Boolean;
  var Physical := TranslateData(Address, False, Cached);
  if FExecutingInstruction then
    FDataCached := Cached;
  if Physical > $FFFFFFFF then
    Exit(0);
  // RDRAM reads have no side effects and are outside the traced MMIO window.
  // (SP DMA beats that may have waited and touch the page run first.)
  if Physical + Cardinal(Size) <= FBus.RAMSize then
  begin
    var P := Cardinal(Physical);
    if FBus.SPReadHazard(P) then
      DeviceAccess;
    case Size of
      1:
        Exit(FBus.ReadRAM8(P));
      2:
        Exit(FBus.ReadRAM16(P));
      4:
        Exit(FBus.ReadRAM32(P));
    else
      Exit((UInt64(FBus.ReadRAM32(P)) shl 32) or FBus.ReadRAM32(P + 4));
    end;
  end;
  DeviceAccess;
  if Size = 4 then
    Result := FBus.Read32(Cardinal(Physical))
  else
  begin
    var A := Cardinal(Physical);
    // A byte or a halfword from the PI's buses (the cartridge, its save
    // memory, the 64DD): the PI reads the 32-bit word from the halfword at A
    // on and the CPU takes the lane A selects in it, so bit 1 of A moves the
    // data two bytes on.
    if (A >= $05000000) and (A < $1FC00000) then
      Inc(A, A and 2);
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or FBus.Read8(Add32(A, Cardinal(I)));
  end;
  if FBus.TraceEnabled and (Physical >= $03F00000) and (Physical < $04A00000) then
    FBus.Trace(MMIORead, FInstructionPC, Physical, Result);
end;

procedure TN64CPU.Store(Address: UInt64; Size: Integer; Value: UInt64);
begin
  if (Address and Cardinal(Size - 1)) <> 0 then
    Fault(5, Address);
  var Cached: Boolean;
  var Physical := TranslateData(Address, True, Cached);
  if FExecutingInstruction then
    FDataCached := Cached;
  if Physical > $FFFFFFFF then
    Exit;
  // Same byte order and final hidden bits as the bus's byte/word RDRAM writes.
  if Physical + Cardinal(Size) <= FBus.RAMSize then
  begin
    var P := Cardinal(Physical);
    if FBus.SPWriteHazard(P) then
      DeviceAccess;
    case Size of
      1:
        FBus.WriteRAM8(P, Byte(Value and $FF));
      2:
        begin
          FBus.WriteRAM8(P, Byte((Value shr 8) and $FF));
          FBus.WriteRAM8(P + 1, Byte(Value and $FF));
        end;
      4:
        FBus.WriteRAM32(P, Cardinal(Value and $FFFFFFFF));
    else
      begin
        FBus.WriteRAM32(P, Cardinal(Value shr 32));
        FBus.WriteRAM32(P + 4, Cardinal(Value and $FFFFFFFF));
      end;
    end;
    Exit;
  end;
  DeviceAccess;
  if FBus.TraceEnabled and (Physical >= $03F00000) and (Physical < $04A00000) then
  begin
    var Written := Value;
    if Size < 8 then
      Written := Written and ((UInt64(1) shl (Size * 8)) - 1);
    FBus.Trace(MMIOWrite, FInstructionPC, Physical, Written);
  end;
  if Size = 4 then
    FBus.Write32(Cardinal(Physical), Cardinal(Value and $FFFFFFFF))
  else
    for var I := 0 to Size - 1 do
      FBus.Write8(Add32(Cardinal(Physical), Cardinal(I)), Byte((Value shr ((Size - 1 - I) * 8)) and $FF));
end;

procedure TN64CPU.Branch(Taken, Likely: Boolean; Target: UInt64);
begin
  if Taken then
    FNextPC := Target
  else if Likely then
  begin
    FPC := FNextPC;
    FNextPC := Add64(FNextPC, 4);
    Exit;
  end;
  FDelay := True;
end;

procedure TN64CPU.Special(Op: Cardinal);
begin
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  var N := (Op shr 6) and 31;
  var A := GPR[S];
  var B := GPR[T];
  var F := Op and 63;
  var V: UInt64 := 0;
  // NEC U10504EJ7 table 3-12. Integer multiply/divide stall the entire pipe.
  case F of
    24, 25:
      FOperationCycles := 5;
    26, 27:
      FOperationCycles := 37;
    28, 29:
      FOperationCycles := 8;
    30, 31:
      FOperationCycles := 69;
  end;
  Inc(FCyclesConsumed, FOperationCycles - 1);
  case F of
    0:
      V := SX32(B shl N);
    2:
      V := SX32((B and $FFFFFFFF) shr N);
    3:
      V := SX32(SAR(B, N, 32));
    4:
      V := SX32(B shl (A and 31));
    6:
      V := SX32((B and $FFFFFFFF) shr (A and 31));
    7:
      V := SX32(SAR(B, A and 31, 32));
    8, 9:
      begin
        if F = 9 then
          GPR[D] := Add64(FInstructionPC, 8);
        Branch(True, False, A);
        Exit;
      end;
    12:
      Fault(8);
    13:
      Fault(9);
    15:
      Exit; // SYNC: interpreter memory operations are ordered.
      16:
      V := HI;
    17:
      begin
        HI := A;
        Exit
      end;
    18:
      V := LO;
    19:
      begin
        LO := A;
        Exit
      end;
    20:
      V := B shl (A and 63);
    22:
      V := B shr (A and 63);
    23:
      V := SAR(B, A and 63, 64);
    24, 25:
      begin
        if F = 24 then
          V := UInt64(0) // handled through Multiply64 for signed values
        else
          V := (A and $FFFFFFFF) * (B and $FFFFFFFF);
        if F = 24 then
          Multiply64(SX(A, 32), SX(B, 32), True, HI, V);
        LO := SX(V, 32);
        HI := SX(V shr 32, 32);
        Exit;
      end;
    26, 27:
      begin
        if F = 26 then
          Divide64(SX(A, 32), SX(B, 32), True, HI, LO)
        else
          Divide64(A and $FFFFFFFF, B and $FFFFFFFF, False, HI, LO);
        HI := SX(HI, 32);
        LO := SX(LO, 32);
        Exit;
      end;
    28, 29:
      begin
        Multiply64(A, B, F = 28, HI, LO);
        Exit
      end;
    30, 31:
      begin
        Divide64(A, B, F = 30, HI, LO);
        Exit
      end;
    32, 33, 34, 35:
      begin
        if F in [32, 33] then
          V := SX32(Add64(A, B))
        else
          V := SX32(Sub64(A, B));
        if F = 32 then
          if (((not (A xor B)) and (A xor V)) and $80000000) <> 0 then
            Fault(12);
        if F = 34 then
          if (((A xor B) and (A xor V)) and $80000000) <> 0 then
            Fault(12);
      end;
    36:
      V := A and B;
    37:
      V := A or B;
    38:
      V := A xor B;
    39:
      V := not (A or B);
    42:
      V := Ord(SignedLess(A, B));
    43:
      V := Ord(A < B);
    44, 45, 46, 47:
      begin
        if F in [44, 45] then
          V := Add64(A, B)
        else
          V := Sub64(A, B);
        if F = 44 then
          if ((not (A xor B)) and (A xor V)) shr 63 <> 0 then
            Fault(12);
        if F = 46 then
          if ((A xor B) and (A xor V)) shr 63 <> 0 then
            Fault(12);
      end;
    48:
      begin
        if not SignedLess(A, B) then
          Fault(13);
        Exit
      end;
    49:
      begin
        if A >= B then
          Fault(13);
        Exit
      end;
    50:
      begin
        if SignedLess(A, B) then
          Fault(13);
        Exit
      end;
    51:
      begin
        if A < B then
          Fault(13);
        Exit
      end;
    52:
      begin
        if A = B then
          Fault(13);
        Exit
      end;
    54:
      begin
        if A <> B then
          Fault(13);
        Exit
      end;
    56:
      V := B shl N;
    58:
      V := B shr N;
    59:
      V := SAR(B, N, 64);
    60:
      V := B shl (N + 32);
    62:
      V := B shr (N + 32);
    63:
      V := SAR(B, N + 32, 64);
  else
    Fault(10);
  end;
  GPR[D] := V;
end;

procedure TN64CPU.Cop0(Op: Cardinal);
begin
  var Mode := (CP0[12] shr 3) and 3;
  if ((CP0[12] and 6) = 0) and (Mode <> 0) and ((CP0[12] and $10000000) = 0) then
    Fault(11, 0, False, 0);
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var D := (Op shr 11) and 31;
  case S of
    0, 1:
      begin
        var V := CP0[D];
        if D in [7, 21..25, 31] then
          V := FCP0Latch;
        if S = 0 then
          GPR[T] := SX(V, 32)
        else
          GPR[T] := V;
      end;
    4, 5:
      begin
        var V := GPR[T];
        if S = 4 then
          V := SX(V, 32);
        FCP0Latch := V;
        case D of
          1, 7, 8, 15, 21..25, 27:
            Exit;
          0:
            V := V and $8000003F;
          2, 3:
            V := V and $3FFFFFFF;
          4:
            V := (V and $FFFFFFFFFF800000) or (CP0[4] and $7FFFF0);
          5:
            V := V and $01FFE000;
          6:
            begin
              V := V and $3F;
              CP0[1] := 31;
            end;
          9:
            V := V and $FFFFFFFF;
          10:
            V := V and $C00000FFFFFFE0FF;
          11:
            begin
              V := V and $FFFFFFFF;
              CP0[13] := CP0[13] and not UInt64($8000);
            end;
          12:
            V := V and $FFF7FFFF;
          13:
            V := (CP0[13] and not UInt64($300)) or (V and $300);
          16:
            V := (V and $0F00800F) or (CP0[16] and $F0FF7FF0);
          17:
            V := V and $FFFFFFFF;
          20:
            V := (V and $FFFFFFFE00000000) or (CP0[20] and $1FFFFFFFF);
          26:
            V := V and $FF;
        end;
        CP0[D] := V;
      end;
    16..31:
      case Op and 63 of
        1:
          begin
            var E := TLB[CP0[0] and 31];
            CP0[5] := E.Mask;
            CP0[10] := E.EntryHi and not UInt64(E.Mask);
            CP0[2] := E.Lo0;
            CP0[3] := E.Lo1;
          end;
        2, 6:
          begin
            var I := CP0[0] and 31;
            if (Op and 63) = 6 then
              I := CP0[1] and 31;
            TLB[I].Mask := Cardinal(CP0[5] and $01554000);
            TLB[I].Mask := TLB[I].Mask or (TLB[I].Mask shr 1);
            TLB[I].EntryHi := CP0[10] and $C00000FFFFFFE0FF;
            TLB[I].Lo0 := Cardinal(CP0[2] and $03FFFFFF);
            TLB[I].Lo1 := Cardinal(CP0[3] and $03FFFFFF);
            if (TLB[I].Lo0 and TLB[I].Lo1 and 1) = 0 then
            begin
              TLB[I].Lo0 := TLB[I].Lo0 and not Cardinal(1);
              TLB[I].Lo1 := TLB[I].Lo1 and not Cardinal(1);
            end;
            InvalidateTLBCache;
          end;
        8:
          begin
            CP0[0] := $80000000;
            for var I := 0 to 31 do
            begin
              var M := UInt64(TLB[I].Mask or $1FFF);
              var MatchMask: UInt64 := $C00000FFFFFFE000 and not M;
              if ((TLB[I].EntryHi and MatchMask) = (CP0[10] and MatchMask)) and
                (((TLB[I].Lo0 and TLB[I].Lo1 and 1) <> 0) or
                ((TLB[I].EntryHi and $FF) = (CP0[10] and $FF))) then
              begin
                CP0[0] := I;
                Break;
              end;
            end;
          end;
        24:
          begin
            if (CP0[12] and 4) <> 0 then
            begin
              SetPCExact(CP0[30]);
              CP0[12] := CP0[12] and not UInt64(4);
            end
            else
            begin
              SetPCExact(CP0[14]);
              CP0[12] := CP0[12] and not UInt64(2);
            end;
            FLL := False;
          end;
      else
        Fault(10);
      end;
  else
    Fault(10);
  end;
end;

procedure TN64CPU.Cop2(Op: Cardinal);
begin
  if (CP0[12] and $40000000) = 0 then
    Fault(11, 0, False, 2);
  var S := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  case S of
    0, 2:
      GPR[T] := SX(FCOP2Latch, 32);
    1:
      GPR[T] := FCOP2Latch;
    4, 5, 6:
      FCOP2Latch := GPR[T];
  else
    Fault(10);
  end;
end;

function TN64CPU.FPBits(Index, Format: Integer): UInt64;
begin
  if (CP0[12] and $4000000) = 0 then
  begin
    Result := FPR[Index and 30];
    if (Format in [16, 20]) and Odd(Index) then
      Result := Result shr 32;
  end
  else
    Result := FPR[Index];
  if Format in [16, 20] then
    Result := Result and $FFFFFFFF;
end;

procedure TN64CPU.SetFPBits(Index, Format: Integer; Value: UInt64);
begin
  if (CP0[12] and $4000000) = 0 then
  begin
    if Format in [16, 20] then
    begin
      if Odd(Index) then
        FPR[Index and 30] := (FPR[Index and 30] and $FFFFFFFF) or ((Value and $FFFFFFFF) shl 32)
      else
        FPR[Index] := (FPR[Index] and $FFFFFFFF00000000) or (Value and $FFFFFFFF);
    end
    else
      FPR[Index and 30] := Value;
  end
  else if Format in [16, 20] then
    FPR[Index] := (FPR[Index] and $FFFFFFFF00000000) or (Value and $FFFFFFFF)
  else
    FPR[Index] := Value;
end;

procedure TN64CPU.FPExceptions(Events: Cardinal; Unimplemented: Boolean);
begin
  FCR31 := FCR31 or ((Events and 31) shl 12);
  FCR31 := FCR31 or (((Events and not (FCR31 shr 7)) and 31) shl 2);
  if Unimplemented then
    FCR31 := FCR31 or $20000;
  if Unimplemented or ((Events and (FCR31 shr 7) and 31) <> 0) then
    Fault(15);
end;

procedure TN64CPU.Cop1(Op: Cardinal);
begin
  if (CP0[12] and $20000000) = 0 then
    Fault(11, 0, False, 1);
  var F := (Op shr 21) and 31;
  var T := (Op shr 16) and 31;
  var S := (Op shr 11) and 31;
  var D := (Op shr 6) and 31;
  var Fn := Op and 63;
  case F of
    0:
      GPR[T] := SX(FPBits(S, 16), 32);
    1:
      GPR[T] := FPBits(S, 17);
    2:
      if S = 31 then
        GPR[T] := SX(FCR31, 32)
      else if S = 0 then
        GPR[T] := $A00
      else
        GPR[T] := 0;
    4:
      SetFPBits(S, 16, GPR[T]);
    5:
      SetFPBits(S, 17, GPR[T]);
    6:
      if S = 31 then
      begin
        FCR31 := Cardinal(GPR[T] and $0183FFFF);
        if ((FCR31 and $20000) <> 0) or (((FCR31 shr 12) and (FCR31 shr 7) and 31) <> 0) then
          Fault(15);
      end;
    8:
      begin
        FCR31 := FCR31 and not $3F000;
        Branch(((FCR31 and $800000) <> 0) = ((T and 1) <> 0), (T and 2) <> 0,
          Add64(FPC, SX(Op and $FFFF, 16) shl 2));
      end;
    16, 17, 20, 21:
      begin
        if (F in [20, 21]) and not (Fn in [32, 33]) then
          Fault(10);
        if Fn = 6 then
        begin
          SetFPBits(D, 17, FPBits(S, 17));
          Exit;
        end;
        FCR31 := FCR31 and not $3F000;
        var A := FPBits(S, F);
        var B := FPBits(T, F);
        FOperationCycles := FPClocks(A, B, F, Fn);
        Inc(FCyclesConsumed, FOperationCycles - 1);
        if (F = 21) and (Fn in [32, 33]) and ((A shr 55) <> 0) and ((A shr 55) <> $1FF) then
        begin
          FOperationCycles := 2;
          FPExceptions(0, True);
        end;
        var Binary := Fn in [0..3, 48..63];
        if F in [16, 17] then
        begin
          // VR4300 manual 8.2.7: compare accepts denormal operands.
          if (Fn < 48) and (SFIsSubnormal(A, F) or
            (Binary and SFIsSubnormal(B, F))) then
            FPExceptions(0, True);
          var NaN1 := SFIsNaN(A, F);
          var NaN2 := Binary and SFIsNaN(B, F);
          var Quiet: UInt64 := $8000000000000;
          if F = 16 then
            Quiet := $400000;
          if Fn >= 48 then
          begin
            var Unordered, Equal, Less: Boolean;
            SFCompare(A, B, F, Unordered, Equal, Less);
            if Unordered and (((Fn and 8) <> 0) or (NaN1 and ((A and Quiet) <> 0)) or
              (NaN2 and ((B and Quiet) <> 0))) then
              FPExceptions(sfInvalid);
            var Test := (((Fn and 1) <> 0) and Unordered) or
              (((Fn and 2) <> 0) and Equal) or (((Fn and 4) <> 0) and Less);
            FCR31 := FCR31 and not $800000;
            if Test then
              FCR31 := FCR31 or $800000;
            Exit;
          end;
          if NaN1 or NaN2 then
          begin
            if (Fn in [8..15, 36, 37]) or (NaN1 and ((A and Quiet) = 0)) or
              (NaN2 and ((B and Quiet) = 0)) then
              FPExceptions(0, True);
            FPExceptions(sfInvalid);
            var Target := Integer(F);
            if Fn = 32 then
              Target := 16
            else if Fn = 33 then
              Target := 17;
            var Bits: UInt64 := $7FF7FFFFFFFFFFFF;
            if Target = 16 then
              Bits := $7FBFFFFF;
            if (Target = 16) and ((CP0[12] and $4000000) <> 0) then
              FPR[D] := Bits
            else
              SetFPBits(D, Target, Bits);
            Exit;
          end;
        end;
        var R: TSoftFloatResult;
        var Target := Integer(F);
        case Fn of
          0..5, 7:
            // The host only for rounding to nearest with no exception enabled.
            if not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or (Fn > 4) or not SFQuick(A, B, F, Fn, R) then
              R := SFCalculate(A, B, F, Fn, FCR31 and 3);
          8..15, 36, 37:
            begin
              Target := 21;
              if Fn in [12..15, 36] then
                Target := 20;
              var Mode := Fn and 3;
              if Fn in [36, 37] then
                Mode := FCR31 and 3;
              // VR4300 conversion unit rejects magnitude >= 2^53 (all formats).
              var Magnitude := A and $7FFFFFFFFFFFFFFF;
              var Limit: UInt64 := $4340000000000000;
              if F = 16 then
              begin
                Magnitude := A and $7FFFFFFF;
                Limit := $5A000000;
              end;
              if Magnitude >= Limit then
              begin
                FOperationCycles := 2;
                FPExceptions(0, True);
              end;
              if not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or (Mode <> 0) or
                not SFQuickConvert(A, F, Target, Mode, R) then
                R := SFConvert(A, F, Target, Mode);
              if (R.Events and sfInvalid) <> 0 then
              begin
                FOperationCycles := 2;
                FPExceptions(0, True);
              end;
            end;
          32, 33:
            begin
              Target := 16;
              if Fn = 33 then
                Target := 17;
              if (Integer(F) = Target) then
                Fault(10);
              if not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or not SFQuickConvert(A, F, Target, 0, R) then
                R := SFConvert(A, F, Target, FCR31 and 3);
            end;
        else
          Fault(10);
          R := Default(TSoftFloatResult);
        end;
        if Target in [16, 17] then
        begin
          if SFIsSubnormal(R.Bits, Target) or ((R.Events and sfUnderflow) <> 0) then
          begin
            if ((FCR31 and $1000000) = 0) or ((FCR31 and $180) <> 0) then
              FPExceptions(0, True);
            var Sign: UInt64 := UInt64(1) shl 63;
            var MinNormal: UInt64 := $10000000000000;
            if Target = 16 then
            begin
              Sign := $80000000;
              MinNormal := $800000;
            end;
            R.Bits := R.Bits and Sign;
            var Mode := FCR31 and 3;
            if ((Mode = 2) and (R.Bits = 0)) or ((Mode = 3) and (R.Bits <> 0)) then
              R.Bits := R.Bits or MinNormal;
            R.Events := R.Events or sfUnderflow or sfInexact;
          end;
        end;
        FPExceptions(R.Events); // Trap before the destination register is written.
        if (Target in [16, 20]) and ((CP0[12] and $4000000) <> 0) then
          FPR[D] := R.Bits and $FFFFFFFF
        else
          SetFPBits(D, Target, R.Bits);
      end;
  else
    Fault(10);
  end;
end;

procedure TN64CPU.Step;
begin
  FCyclesConsumed := 1; // Filled VR4300 pipeline issues one instruction/PClock.
  FOperationCycles := 1;
  FExecutingInstruction := False;
  FDataCached := False;
  FInstructionPC := FPC;
  FInDelay := FDelay;
  FDelay := False;
  try
    ExecuteInstruction;
  except
    on E: EGuestFault do
      ;
  end;
  GPR[0] := 0;
  FExecutingInstruction := False;
  FPreviousStore := FPreviousStore and FDataCached;
  AdvanceClocks(FCyclesConsumed);
  if CP0[1] <= (CP0[6] and 31) then
    CP0[1] := 31
  else
    Dec(CP0[1]);
end;

procedure TN64CPU.DeviceAccess;
begin
  if FBatching then
  begin
    FBatchDevice := True;
    FBus.SyncDevice(FBatchElapsed);
  end;
end;

function TN64CPU.FastCode(PC: UInt64; Context: Cardinal): Boolean;
begin
  // The code page of PC in RDRAM, as Fetch would find it without faulting:
  // kernel KSEG0/KSEG1, or a page translated before in this context.
  Result := False;
  var Physical: UInt64;
  if (PC >= KSeg0Base) and (PC < KSeg2Base) then
  begin
    if not KernelMode then
      Exit;
    Physical := PC and $1FFFF000;
  end
  else
  begin
    var Page := PC shr 12;
    var Slot := PageSlot(Page);
    if (FPages[Slot].Page <> Page) or (FPages[Slot].Generation <> FTLBGeneration) or
      (FPages[Slot].Context <> Context) or not (FPages[Slot].WriteOK or FPages[Slot].ReadOK) then
      Exit;
    Physical := FPages[Slot].Physical;
  end;
  // RDRAM ends on a page boundary.
  if Physical + $1000 > FBus.RAMSize then
    Exit;
  FFastCodePage := PC shr 12;
  FFastCodePhysical := Cardinal(Physical);
  FFastCodeContext := Context;
  FFastCodeGeneration := FTLBGeneration;
  FFastCodeValid := True;
  Result := True;
end;

function TN64CPU.FastData(Address: UInt64; Size: Integer; Writing: Boolean; Context: Cardinal; out Physical: Cardinal; out Cached: Boolean): Boolean;
begin
  // A data access as Load or Store would make it without faulting and in
  // RDRAM: aligned, through kernel KSEG0/KSEG1 or a page translated before
  // in this context (for writing, by a write).
  Result := False;
  if (Address and UInt64(Size - 1)) <> 0 then
    Exit;
  var P: UInt64;
  if (Address >= KSeg0Base) and (Address < KSeg2Base) then
  begin
    // FastReady captured these Status bits; fast steps cannot change them.
    if ((Context and 6) = 0) and ((Context and $18) <> 0) then
      Exit;
    P := Address and $1FFFFFFF;
    Cached := Address < KSeg1Base;
  end
  else
  begin
    var Page := Address shr 12;
    var Slot := PageSlot(Page);
    if (FPages[Slot].Page <> Page) or (FPages[Slot].Generation <> FTLBGeneration) or
      (FPages[Slot].Context <> Context) or not (FPages[Slot].WriteOK or (not Writing and FPages[Slot].ReadOK)) then
      Exit;
    P := FPages[Slot].Physical or (Address and $FFF);
    Cached := FPages[Slot].Cached;
  end;
  if P + Cardinal(Size) > FBus.RAMSize then
    Exit;
  Physical := Cardinal(P);
  // Not where SP DMA beats that may have waited touch the page (Load and
  // Store run them first).
  if Writing then
  begin
    if FBus.SPWriteHazard(Physical) then
      Exit;
  end
  else if FBus.SPReadHazard(Physical) then
    Exit;
  Result := True;
end;

function TN64CPU.FastReady(out Context: Cardinal; out UntilCompare: UInt64): Boolean;
begin
  // Before fast steps: what Step checks before each instruction, which holds
  // for all of them until a full Step runs or COUNT reaches COMPARE (they
  // change no COP0 register and no TLB entry, and the interrupt line changes
  // only with device accesses and events, which end the batch). False: the
  // next instruction takes an interrupt (Step does), or Random is out of its
  // range (Step makes it 31). UntilCompare: PClocks before COUNT reaches
  // COMPARE.
  Result := False;
  Context := 0;
  UntilCompare := 0;
  if FBus.InterruptLine then
    CP0[13] := CP0[13] or $400
  else
    CP0[13] := CP0[13] and not UInt64($400);
  if ((CP0[12] and 7) = 1) and ((CP0[12] and CP0[13] and $FF00) <> 0) then
    Exit;
  if (CP0[1] < (CP0[6] and 31)) or (CP0[1] > 31) then
    Exit;
  Context := PageContext;
  var Distance := (UInt64(CP0[11] and $FFFFFFFF) + UInt64($100000000) - (CP0[9] and $FFFFFFFF)) and $FFFFFFFF;
  if Distance = 0 then
    Distance := $100000000;
  UntilCompare := Distance * 2 - Cardinal(FCountHalf);
  Result := True;
end;

procedure TN64CPU.FastFlush(Clocks: Cardinal; Count: Integer);
begin
  // The COUNT and Random updates of Count fast steps of Clocks PClocks, as
  // their Steps would have made them one by one (COUNT reached COMPARE at
  // most in the last).
  if Count = 0 then
    Exit;
  AdvanceCount(Clocks);
  var Wired := CP0[6] and 31;
  CP0[1] := 31 - ((31 - CP0[1] + Cardinal(Count)) mod (32 - Wired));
end;

function TN64CPU.IdleHead: Boolean;
begin
  // IdleLimit's first test: anywhere else it declines.
  Result := FInDelay and not FDelay and (FPC = Sub64(FInstructionPC, 4)) and (FNextPC = Add64(FPC, 4));
end;

function TN64CPU.FastRun(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
begin
  // Steps of the most common instructions from here on, exactly as Step
  // runs them (after FastReady), at most MaxSteps: up to the one that brings
  // their PClocks to Limit or more, or after which IdleLimit may find an idle
  // loop's head (as RunBatch), or before one that fetches or accesses data
  // other than in RDRAM through a known page, may fault, or is another one
  // (FSlowSafe tells whether Step would leave FastReady's findings). Their
  // COUNT and Random updates come at the end (FastFlush). Returns how many
  // ran; Clocks: their PClocks.
  Result := 0;
  Clocks := 0;
  // Fast steps change no COP0 register.
  var Status := CP0[12];
  var Cop1Usable := (Status and $20000000) <> 0;
  // A 64-bit operation outside kernel mode without its UX/SX/KX bit faults.
  var Mode := Integer((Status shr 3) and 3);
  if (Status and 6) <> 0 then
    Mode := 0;
  var WideOK := (Mode = 0) or ((Status and (UInt64($80) shr Mode)) <> 0);
  // The code page needs no RDP wait (checked at its first fetch here: no
  // RDP work is queued meanwhile).
  var CodeClean := False;
  while Result < MaxSteps do
  begin
    FSlowSafe := False;
    var PC := FPC;
    if (PC and 3) <> 0 then
      Break;
    if not FFastCodeValid or (FFastCodePage <> (PC shr 12)) or (FFastCodeContext <> Context) or
      (FFastCodeGeneration <> FTLBGeneration) then
    begin
      if not FastCode(PC, Context) then
        Break;
      CodeClean := False;
    end;
    // Not on a page SP DMA beats that may have waited write (Fetch runs
    // them first).
    if not CodeClean and FBus.SPReadHazard(FFastCodePhysical) then
      Break;
    var Op: Cardinal;
    if CodeClean then
      Op := FBus.PlainRAM32(FFastCodePhysical or Cardinal(PC and $FFF))
    else
    begin
      Op := FBus.ReadRAM32(FFastCodePhysical or Cardinal(PC and $FFF));
      CodeClean := FBus.RDPReadClean(FFastCodePhysical);
    end;
    var Code := Op shr 26;
    FSlowSafe := Code <> 16;
    var S := Integer((Op shr 21) and 31);
    var T := Integer((Op shr 16) and 31);
    var Fn := Integer(Op and 63);
    var A := GPR[S];
    var Imm := SX16(Op);
    var Reads: Byte;
    var Size := 0;
    var Physical: Cardinal := 0;
    var Cached := False;
    var Wide := False;
    // COP1: the format, the operands of an arithmetic one and its result.
    var FPF := 0;
    var FPA: UInt64 := 0;
    var FPB: UInt64 := 0;
    var FPResult: TSoftFloatResult;
    case Code of
      17:
        begin
          // Moves, and the arithmetic and compares of operands and results
          // that raise nothing that traps and need no exception: those the
          // host computes as SoftFloat does (SFQuick, as Cop1 allows it), and
          // compares without NaN. As Cop1 does them.
          if not Cop1Usable then
            Break;
          FPF := Integer((Op shr 21) and 31);
          case FPF of
            0, 1, 4, 5:
              Wide := (FPF and 1) <> 0;
            16, 17:
              begin
                FPA := FPBits(Integer((Op shr 11) and 31), FPF);
                FPB := FPBits(T, FPF);
                if Fn >= 48 then
                begin
                  if SFIsNaN(FPA, FPF) or SFIsNaN(FPB, FPF) then
                    Break;
                end
                else if (Fn > 4) or not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or
                  not SFQuick(FPA, FPB, FPF, Fn, FPResult) or ((FPResult.Events and (FCR31 shr 7) and 31) <> 0) then
                  // (No event of SFQuick's traps while the gate lets it run,
                  // inexact being its only one: the last test is a guard.)
                  Break;
              end;
          else
            Break;
          end;
          Reads := 0;
        end;
      0:
        begin
          case Fn of
            0, 2, 3, 4, 6, 7, 8, 9, 15..19, 24..27, 33, 35, 36..39, 42, 43:
              ;
            20, 22, 23, 28..31, 45, 47, 56, 58..60, 62, 63:
              Wide := True;
          else
            Break;
          end;
          Reads := SpecialReads[Fn];
        end;
      47:
        Reads := OpReads[Code];
      1:
        begin
          if not (T in [0..3, 16..19]) then
            Break;
          Reads := OpReads[Code];
        end;
      2..7, 9..15, 20..23:
        Reads := OpReads[Code];
      32, 33, 35..37, 39..41, 43, 49, 53, 55, 57, 61, 63:
        begin
          if (Code in [49, 53, 57, 61]) and not Cop1Usable then
            Break;
          Wide := Code in [55, 63];
          case Code of
            32, 36, 40:
              Size := 1;
            33, 37, 41:
              Size := 2;
            53, 55, 61, 63:
              Size := 8;
          else
            Size := 4;
          end;
          if not FastData(Add64(A, Imm), Size, Code in [40, 41, 43, 57, 61, 63], Context, Physical, Cached) then
            Break;
          Reads := OpReads[Code];
        end;
    else
      Break;
    end;
    if Wide and not WideOK then
      Break;
    // Step and ApplyInterlocks: the stall behind the previous instruction (none
    // of these is a COP0 or COP1 instruction, so only a load target it reads
    // and a cached store before an access count), then this one's hazards.
    var C: Cardinal := 1;
    if Code = 17 then
    begin
      // As ApplyStalls: a load target or (arithmetic) an FP result read.
      var RT := -1;
      var FS := -1;
      var FT := -1;
      if FPF >= 16 then
      begin
        FS := FPRegister(Integer((Op shr 11) and 31));
        if (Fn <= 3) or (Fn >= 48) then
          FT := FPRegister(T);
        if (FPreviousFP >= 0) and ((FPreviousFP = FS) or (FPreviousFP = FT)) then
          Inc(C);
      end
      else if FPF >= 4 then
        RT := T
      else
        FS := FPRegister(Integer((Op shr 11) and 31));
      if (FPreviousLoad >= 0) and ((FPreviousLoad = RT) or (FPreviousLoad = FS) or (FPreviousLoad = FT)) then
        Inc(C);
    end
    else if (FPreviousLoad >= 0) or FPreviousStore then
    begin
      if FPreviousLoad >= 0 then
        if (((Reads and 1) <> 0) and (FPreviousLoad = S)) or (((Reads and 2) <> 0) and (FPreviousLoad = T)) or
          (((Reads and 8) <> 0) and (FPreviousLoad = FPRegister(T))) then
          Inc(C);
      if FPreviousStore and ((Reads and 4) <> 0) and Cached then
        Inc(C);
    end;
    FPreviousLoad := -1;
    FPreviousFP := -1;
    FPreviousCondition := False;
    FPreviousException := False;
    FPreviousStore := False;
    case Code of
      32, 33, 35..37, 39, 55:
        if T <> 0 then
          FPreviousLoad := T;
      49, 53:
        FPreviousLoad := FPRegister(T);
      40, 41, 43, 57, 61, 63:
        FPreviousStore := Cached;
      17:
        if FPF >= 16 then
          if Fn >= 48 then
            FPreviousCondition := True
          else
            FPreviousFP := FPRegister(Integer((Op shr 6) and 31));
    end;
    FInstructionPC := PC;
    FInDelay := FDelay;
    FDelay := False;
    FPC := FNextPC;
    FNextPC := Add64(FNextPC, 4);
    case Code of
      0:
        begin
          var B := GPR[T];
          var D := Integer((Op shr 11) and 31);
          var N := Integer((Op shr 6) and 31);
          case Fn of
            0:
              GPR[D] := SX32(B shl N);
            2:
              GPR[D] := SX32((B and $FFFFFFFF) shr N);
            3:
              GPR[D] := SX32(SAR(B, N, 32));
            4:
              GPR[D] := SX32(B shl (A and 31));
            6:
              GPR[D] := SX32((B and $FFFFFFFF) shr (A and 31));
            7:
              GPR[D] := SX32(SAR(B, A and 31, 32));
            8, 9:
              begin
                if Fn = 9 then
                  GPR[D] := Add64(PC, 8);
                Branch(True, False, A);
              end;
            15:
              ; // SYNC
              16:
              GPR[D] := HI;
            17:
              HI := A;
            18:
              GPR[D] := LO;
            19:
              LO := A;
            20:
              GPR[D] := B shl (A and 63);
            22:
              GPR[D] := B shr (A and 63);
            23:
              GPR[D] := SAR(B, A and 63, 64);
            24, 25:
              begin
                // Multiply and divide stall the whole pipe (Special).
                Inc(C, 4);
                var V: UInt64;
                if Fn = 24 then
                  Multiply64(SX(A, 32), SX(B, 32), True, HI, V)
                else
                  V := (A and $FFFFFFFF) * (B and $FFFFFFFF);
                LO := SX(V, 32);
                HI := SX(V shr 32, 32);
              end;
            26, 27:
              begin
                Inc(C, 36);
                if Fn = 26 then
                  Divide64(SX(A, 32), SX(B, 32), True, HI, LO)
                else
                  Divide64(A and $FFFFFFFF, B and $FFFFFFFF, False, HI, LO);
                HI := SX(HI, 32);
                LO := SX(LO, 32);
              end;
            28, 29:
              begin
                Inc(C, 7);
                Multiply64(A, B, Fn = 28, HI, LO);
              end;
            30, 31:
              begin
                Inc(C, 68);
                Divide64(A, B, Fn = 30, HI, LO);
              end;
            45:
              GPR[D] := Add64(A, B);
            47:
              GPR[D] := Sub64(A, B);
            56:
              GPR[D] := B shl N;
            58:
              GPR[D] := B shr N;
            59:
              GPR[D] := SAR(B, N, 64);
            60:
              GPR[D] := B shl (N + 32);
            62:
              GPR[D] := B shr (N + 32);
            63:
              GPR[D] := SAR(B, N + 32, 64);
            33:
              GPR[D] := SX32(Add64(A, B));
            35:
              GPR[D] := SX32(Sub64(A, B));
            36:
              GPR[D] := A and B;
            37:
              GPR[D] := A or B;
            38:
              GPR[D] := A xor B;
            39:
              GPR[D] := not (A or B);
            42:
              GPR[D] := Ord(SignedLess(A, B));
            43:
              GPR[D] := Ord(A < B);
          end;
        end;
      1:
        begin
          var Target := Add64(FPC, Imm shl 2);
          var Taken := SignedLess(A, 0);
          if (T and 1) <> 0 then
            Taken := not Taken;
          if T >= 16 then
            GPR[31] := Add64(PC, 8);
          Branch(Taken, (T and 2) <> 0, Target);
        end;
      2, 3:
        begin
          if Code = 3 then
            GPR[31] := Add64(PC, 8);
          Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Op and $3FFFFFF) shl 2));
        end;
      4, 20:
        Branch(A = GPR[T], Code = 20, Add64(FPC, Imm shl 2));
      5, 21:
        Branch(A <> GPR[T], Code = 21, Add64(FPC, Imm shl 2));
      6, 22:
        Branch(not SignedLess(0, A), Code = 22, Add64(FPC, Imm shl 2));
      7, 23:
        Branch(SignedLess(0, A), Code = 23, Add64(FPC, Imm shl 2));
      9:
        GPR[T] := SX32(Add64(A, Imm));
      10:
        GPR[T] := Ord(SignedLess(A, Imm));
      11:
        GPR[T] := Ord(A < Imm);
      12:
        GPR[T] := A and (Op and $FFFF);
      13:
        GPR[T] := A or (Op and $FFFF);
      14:
        GPR[T] := A xor (Op and $FFFF);
      15:
        GPR[T] := SX32((Op and $FFFF) shl 16);
      32:
        GPR[T] := SX8(FBus.ReadRAM8(Physical));
      33:
        GPR[T] := SX16(FBus.ReadRAM16(Physical));
      35:
        GPR[T] := SX32(FBus.ReadRAM32(Physical));
      36:
        GPR[T] := FBus.ReadRAM8(Physical);
      37:
        GPR[T] := FBus.ReadRAM16(Physical);
      39:
        GPR[T] := FBus.ReadRAM32(Physical);
      49:
        SetFPBits(T, 16, FBus.ReadRAM32(Physical));
      53:
        SetFPBits(T, 17, (UInt64(FBus.ReadRAM32(Physical)) shl 32) or FBus.ReadRAM32(Physical + 4));
      55:
        GPR[T] := (UInt64(FBus.ReadRAM32(Physical)) shl 32) or FBus.ReadRAM32(Physical + 4);
      63:
        begin
          var V := GPR[T];
          FBus.WriteRAM32(Physical, Cardinal(V shr 32));
          FBus.WriteRAM32(Physical + 4, Cardinal(V and $FFFFFFFF));
        end;
      40:
        begin
          FBus.WriteRAM8(Physical, Byte(GPR[T] and $FF));
        end;
      41:
        begin
          FBus.WriteRAM8(Physical, Byte((GPR[T] shr 8) and $FF));
          FBus.WriteRAM8(Physical + 1, Byte(GPR[T] and $FF));
        end;
      43:
        begin
          FBus.WriteRAM32(Physical, Cardinal(GPR[T] and $FFFFFFFF));
        end;
      57:
        begin
          var V := FPBits(T, 16);
          FBus.WriteRAM32(Physical, Cardinal(V and $FFFFFFFF));
        end;
      61:
        begin
          var V := FPBits(T, 17);
          FBus.WriteRAM32(Physical, Cardinal(V shr 32));
          FBus.WriteRAM32(Physical + 4, Cardinal(V and $FFFFFFFF));
        end;
      17:
        begin
          var FS := Integer((Op shr 11) and 31);
          case FPF of
            0:
              GPR[T] := SX(FPBits(FS, 16), 32);
            1:
              GPR[T] := FPBits(FS, 17);
            4:
              SetFPBits(FS, 16, GPR[T]);
            5:
              SetFPBits(FS, 17, GPR[T]);
          else
            begin
              FCR31 := FCR31 and not $3F000;
              Inc(C, FPClocks(FPA, FPB, FPF, Fn) - 1);
              if Fn >= 48 then
              begin
                var Unordered, Equal, Less: Boolean;
                SFCompare(FPA, FPB, FPF, Unordered, Equal, Less);
                FCR31 := FCR31 and not $800000;
                if (((Fn and 1) <> 0) and Unordered) or (((Fn and 2) <> 0) and Equal) or (((Fn and 4) <> 0) and Less) then
                  FCR31 := FCR31 or $800000;
              end
              else
              begin
                // FPExceptions of the result's events (none traps).
                FCR31 := FCR31 or ((FPResult.Events and 31) shl 12);
                FCR31 := FCR31 or (((FPResult.Events and not (FCR31 shr 7)) and 31) shl 2);
                var D := Integer((Op shr 6) and 31);
                if (FPF = 16) and ((CP0[12] and $4000000) <> 0) then
                  FPR[D] := FPResult.Bits and $FFFFFFFF
                else
                  SetFPBits(D, FPF, FPResult.Bits);
              end;
            end;
          end;
        end;
    end;
    // Step's end: a store's hazard needs it cached (it is).
    GPR[0] := 0;
    if Size = 0 then
      FPreviousStore := False;
    Inc(Result);
    Inc(Clocks, C);
    if (Clocks >= Limit) or IdleHead then
      Break;
  end;
  FastFlush(Cardinal(Clocks), Result);
end;

const
  // Block step kinds besides the opcodes (1..63): SPECIAL functions, COP1
  // moves (by format), COP1 arithmetic and compares, a LUI pair.
  KindSpecial = 64;
  KindCop1Move = 128;
  KindCop1Arith = 136;
  KindCop1Compare = 137;
  KindCop1Branch = 138;
  KindCop1Mov = 139;
  KindLuiPair = 140;
  // Step flags.
  StepStore = 1;        // a store: FPreviousStore after it is its Cached
  StepMayIdle = 2;      // IdleHead may hold after it (a delay slot)
  StepMemoryHazard = 4; // reads memory: a cached store before it stalls it
  StepWriting = 8;      // its data access writes
  StepCondition = 16;   // leaves FPreviousCondition (a compare)
  StepBranch = 32;      // a branch or jump
  StepLikely = 64;      // a likely branch
  // Block modes: Cop1 usable, 64-bit operations allowed, FR, in a delay slot.
  ModeCop1 = 1;
  ModeWide = 2;
  ModeFR = 4;
  ModeDelay = 8;
  // At most this many steps in a block (the pools keep room for one).
  MaxBlockSteps = 48;

function StepOf(B: PN64CPUBlock; I: Integer): PN64CPUStep; inline;
begin
  Result := PN64CPUStep(NativeUInt(B.Steps) + NativeUInt(I) * SizeOf(TN64CPUStep));
end;

function TN64CPU.FastFloat(Op: Cardinal; A, B: UInt64; out R: TSoftFloatResult; out Cycles: Cardinal; out Target: Integer): Boolean;
begin
  // Cop1's result for arithmetic or a conversion (Op, operands A and B as
  // it reads them), worked out without changing anything: False where Cop1
  // would fault, trap, raise unimplemented, or take its NaN or tiny-result
  // paths (Step does those). Cycles: its FOperationCycles.
  Result := False;
  var F := Integer((Op shr 21) and 31);
  var Fn := Integer(Op and 63);
  Target := F;
  // SFQuick already rejects non-normal operands/results and reports only
  // inexact. Accept that common path before repeating the slow-path guards.
  if (F in [16, 17]) and (Fn <= 4) and FHostFloat and
    ((FCR31 and HostFloatOff) = 0) and SFQuick(A, B, F, Fn, R) then
  begin
    Cycles := FPClocks(A, B, F, Fn);
    Exit((R.Events and (FCR31 shr 7) and 31) = 0);
  end;
  Cycles := FPClocks(A, B, F, Fn);
  if F in [20, 21] then
  begin
    if not (Fn in [32, 33]) then
      Exit;
    if (F = 21) and ((A shr 55) <> 0) and ((A shr 55) <> $1FF) then
      Exit;
  end
  else
  begin
    var Binary := Fn <= 3;
    if SFIsSubnormal(A, F) or (Binary and SFIsSubnormal(B, F)) then
      Exit;
    if SFIsNaN(A, F) or (Binary and SFIsNaN(B, F)) then
      Exit;
  end;
  case Fn of
    0..5, 7:
      if not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or (Fn > 4) or not SFQuick(A, B, F, Fn, R) then
        R := SFCalculate(A, B, F, Fn, FCR31 and 3);
    8..15, 36, 37:
      begin
        Target := 21;
        if Fn in [12..15, 36] then
          Target := 20;
        var Mode := Fn and 3;
        if Fn in [36, 37] then
          Mode := FCR31 and 3;
        var Magnitude := A and $7FFFFFFFFFFFFFFF;
        var Limit: UInt64 := $4340000000000000;
        if F = 16 then
        begin
          Magnitude := A and $7FFFFFFF;
          Limit := $5A000000;
        end;
        if Magnitude >= Limit then
          Exit;
        // Float-to-integer conversion uses integer significand arithmetic:
        // all four rounding modes are exact here, independent of host FP.
        // Enabled exceptions are still checked against R.Events below.
        if not FHostFloat or not SFQuickConvert(A, F, Target, Mode, R) then
          R := SFConvert(A, F, Target, Mode);
        if (R.Events and sfInvalid) <> 0 then
          Exit;
      end;
    32, 33:
      begin
        Target := 16;
        if Fn = 33 then
          Target := 17;
        if F = Target then
          Exit;
        if not FHostFloat or ((FCR31 and HostFloatOff) <> 0) or not SFQuickConvert(A, F, Target, 0, R) then
          R := SFConvert(A, F, Target, FCR31 and 3);
      end;
  else
    Exit;
  end;
  if (Target in [16, 17]) and (SFIsSubnormal(R.Bits, Target) or ((R.Events and sfUnderflow) <> 0)) then
    Exit;
  Result := (R.Events and (FCR31 shr 7) and 31) = 0;
end;

procedure TN64CPU.LimitBlocks(Blocks, Chunks: Integer);
begin
  FBlockLimit := Max(1, Min(Blocks, MaxBlocks));
  FChunkLimit := Max(1, Min(Chunks, MaxStepChunks));
  ClearBlocks;
end;

procedure TN64CPU.ClearBlocks;
begin
  for var I := 0 to High(FBlockHead) do
    FBlockHead[I] := nil;
  FBlockCount := 0;
  FStepChunk := 0;
  FStepUsed := 0;
  FWordChunk := 0;
  FWordUsed := 0;
  Inc(FBlockGen);
  // Their code goes with them.
  if FJit <> nil then
  begin
    FJit.Reset;
    Inc(FJitResets);
    FJitMapCount := 0;
    FJitChain := 0;
  end;
  FJitFull := False;
end;

function TN64CPU.BlockValid(B: PN64CPUBlock): Boolean;
begin
  // Its code as it is in RDRAM (the page has no RDP work queued): compared
  // again only once the page was written.
  var Gen := FBus.CodeGeneration(B.Physical);
  if B.Gen = Gen then
    Exit(True);
  var Word := B.Code;
  for var I := 0 to B.Words - 1 do
  begin
    if FBus.PlainRAM32(B.Physical + Cardinal(I) * 4) <> Word^ then
      Exit(False);
    Inc(Word);
  end;
  B.Gen := Gen;
  Result := True;
end;

function TN64CPU.BlockKey(EntryLoad, EntryFP: Integer; Mode: Byte; Physical: Cardinal): PN64CPUBlock;
begin
  // The block for this entry state whose code is current, or nil.
  Result := FBlockHead[(Physical shr 2) and High(FBlockHead)];
  while Result <> nil do
  begin
    if (Result.Physical = Physical) and (Result.Mode = Mode) and (Result.EntryLoad = EntryLoad) and
      (Result.EntryFP = EntryFP) and BlockValid(Result) then
      Exit;
    Result := Result.Next;
  end;
end;

function TN64CPU.BuildBlock(PC: UInt64; Physical: Cardinal; Mode: Byte): PN64CPUBlock;
begin
  // The steps from Physical (PC) for the entry state as it is: those FastRun
  // takes, decoded as FastRun decodes them, with their stalls behind each
  // other as ApplyStalls finds them.
  // Room for a block of MaxBlockSteps steps and words: the next chunk if
  // this one has none, all dropped at the limit.
  if FStepUsed + MaxBlockSteps > StepChunkSize then
  begin
    Inc(FStepChunk);
    FStepUsed := 0;
  end;
  // (Two words for a step of a LUI pair, one for an empty block.)
  if FWordUsed + 2 * MaxBlockSteps + 1 > StepChunkSize then
  begin
    Inc(FWordChunk);
    FWordUsed := 0;
  end;
  if (FBlockCount >= FBlockLimit) or (FStepChunk >= FChunkLimit) or (FWordChunk >= FChunkLimit) or FJitFull then
    ClearBlocks;
  if FStepChunk >= Length(FStepChunks) then
  begin
    SetLength(FStepChunks, FStepChunk + 1);
    SetLength(FStepChunks[FStepChunk], StepChunkSize);
  end;
  if FWordChunk >= Length(FWordChunks) then
  begin
    SetLength(FWordChunks, FWordChunk + 1);
    SetLength(FWordChunks[FWordChunk], StepChunkSize);
  end;
  var BlockChunk := FBlockCount div BlockChunkSize;
  if BlockChunk >= Length(FBlockChunks) then
  begin
    SetLength(FBlockChunks, BlockChunk + 1);
    SetLength(FBlockChunks[BlockChunk], BlockChunkSize);
  end;
  Inc(FBlocksBuilt);
  Result := @FBlockChunks[BlockChunk][FBlockCount mod BlockChunkSize];
  Inc(FBlockCount);
  Result.Physical := Physical;
  Result.EntryLoad := ShortInt(FPreviousLoad);
  Result.EntryFP := ShortInt(FPreviousFP);
  Result.Mode := Mode;
  Result.SlowSafe := False;
  Result.Steps := @FStepChunks[FStepChunk][FStepUsed];
  Result.Code := @FWordChunks[FWordChunk][FWordUsed];
  var Words_: PCardinal := Result.Code;
  Result.Link[0] := nil;
  Result.Link[1] := nil;
  Result.Native := nil;
  Result.NativeInner := nil;
  Result.Far[0] := nil;
  Result.Far[1] := nil;
  Result.JitTried := False;
  Result.NativeCareful := nil;
  Result.CarefulTried := False;
  Result.JitHeat := 0;
  Result.CarefulHeat := 0;
  FBus.MarkCodePage(Physical);
  Result.Gen := FBus.CodeGeneration(Physical);
  var Bucket := (Physical shr 2) and High(FBlockHead);
  Result.Next := FBlockHead[Bucket];
  FBlockHead[Bucket] := Result;
  var Cop1Usable := (Mode and ModeCop1) <> 0;
  var WideOK := (Mode and ModeWide) <> 0;
  // FPRegister as the block's FR has it.
  var FRMask := 30;
  if (Mode and ModeFR) <> 0 then
    FRMask := 31;
  var PrevLoad := Integer(FPreviousLoad);
  var PrevFP := Integer(FPreviousFP);
  var Count := 0;
  var Words := 0;
  var AfterBranch := False;
  while Count < MaxBlockSteps do
  begin
    var Offset := (Physical and $FFF) + Cardinal(Words) * 4;
    if Offset > $FFC then
      Break;
    var Op := FBus.PlainRAM32((Physical and not Cardinal($FFF)) or Offset);
    var Code := Op shr 26;
    var S := Integer((Op shr 21) and 31);
    var T := Integer((Op shr 16) and 31);
    var D := Integer((Op shr 11) and 31);
    var Fn := Integer(Op and 63);
    var Kind := Integer(Code);
    var Reads: Byte := 0;
    var Wide := False;
    var Size := 0;
    var Flags: Byte := 0;
    var Extra := 0;
    var FPF := 0;
    var Eligible := True;
    // As FastRun's first case.
    case Code of
      0:
        begin
          case Fn of
            0, 2, 3, 4, 6, 7, 8, 9, 15..19, 24..27, 33, 35..39, 42, 43:
              ;
            20, 22, 23, 28..31, 45, 47, 56, 58..60, 62, 63:
              Wide := True;
          else
            Eligible := False;
          end;
          Reads := SpecialReads[Fn];
          Kind := KindSpecial + Fn;
          case Fn of
            8, 9:
              Flags := StepBranch;
            24, 25:
              Extra := 4;
            26, 27:
              Extra := 36;
            28, 29:
              Extra := 7;
            30, 31:
              Extra := 68;
          end;
        end;
      47:
        Reads := OpReads[Code];
      1:
        begin
          if not (T in [0..3, 16..19]) then
            Eligible := False;
          Reads := OpReads[Code];
          Flags := StepBranch;
          if (T and 2) <> 0 then
            Flags := Flags or StepLikely;
        end;
      2..7, 9..15, 20..23:
        begin
          Reads := OpReads[Code];
          if Code in [2..7, 20..23] then
            Flags := StepBranch;
          if Code >= 20 then
            Flags := Flags or StepLikely;
        end;
      32, 33, 35..37, 39..41, 43, 49, 53, 55, 57, 61, 63:
        begin
          if (Code in [49, 53, 57, 61]) and not Cop1Usable then
            Eligible := False;
          Wide := Code in [55, 63];
          case Code of
            32, 36, 40:
              Size := 1;
            33, 37, 41:
              Size := 2;
            53, 55, 61, 63:
              Size := 8;
          else
            Size := 4;
          end;
          if Code in [40, 41, 43, 57, 61, 63] then
            Flags := StepStore or StepWriting;
          Reads := OpReads[Code];
        end;
      17:
        begin
          if not Cop1Usable then
            Eligible := False;
          FPF := S;
          case FPF of
            0, 1, 4, 5:
              begin
                Wide := (FPF and 1) <> 0;
                Kind := KindCop1Move + FPF;
              end;
            8:
              begin
                Kind := KindCop1Branch;
                Flags := StepBranch;
                if (T and 2) <> 0 then
                  Flags := Flags or StepLikely;
              end;
            16, 17:
              begin
                if Fn >= 48 then
                  Kind := KindCop1Compare
                else if Fn = 6 then
                  Kind := KindCop1Mov
                else if Fn in [0..5, 7..15, 32, 33, 36, 37] then
                  Kind := KindCop1Arith
                else
                  Eligible := False;
                Wide := Fn in [8..11, 37];
              end;
            20, 21:
              if Fn in [32, 33] then
              begin
                Kind := KindCop1Arith;
                Wide := FPF = 21;
              end
              else
                Eligible := False;
          else
            Eligible := False;
          end;
        end;
    else
      Eligible := False;
    end;
    if Wide and not WideOK then
      Eligible := False;
    // A delay slot runs whatever it is (a block entered in one has it alone).
    if not Eligible then
    begin
      // No step: its word is checked too (SlowSafe holds for it alone).
      if Count = 0 then
      begin
        Result.SlowSafe := Code <> 16;
        Words_^ := Op;
        Words := 1;
      end;
      Break;
    end;
    // The stall behind the instruction before (fixed here), as FastRun and
    // ApplyStalls find it.
    var Clocks := 1 + Extra;
    if Code = 17 then
    begin
      var RT := -1;
      var FS := -1;
      var FT := -1;
      if FPF >= 16 then
      begin
        FS := (D and FRMask) + 32;
        if (Fn <= 3) or (Fn >= 48) then
          FT := (T and FRMask) + 32;
        if (PrevFP >= 0) and ((PrevFP = FS) or (PrevFP = FT)) then
          Inc(Clocks);
      end
      else if FPF >= 8 then
        // BC1: the condition (FPreviousCondition) as it runs.

      else if FPF >= 4 then
        RT := T
      else
        FS := (D and FRMask) + 32;
      if (PrevLoad >= 0) and ((PrevLoad = RT) or (PrevLoad = FS) or (PrevLoad = FT)) then
        Inc(Clocks);
    end
    else
    begin
      if (PrevLoad >= 0) and ((((Reads and 1) <> 0) and (PrevLoad = S)) or (((Reads and 2) <> 0) and (PrevLoad = T)) or
        (((Reads and 8) <> 0) and (PrevLoad = (T and FRMask) + 32))) then
        Inc(Clocks);
      if (Reads and 4) <> 0 then
        Flags := Flags or StepMemoryHazard;
    end;
    // What it leaves for the next one.
    var LoadAfter := -1;
    var FPAfter := -1;
    case Code of
      32, 33, 35..37, 39, 55:
        if T <> 0 then
          LoadAfter := T;
      49, 53:
        LoadAfter := (T and FRMask) + 32;
      17:
        if Kind in [KindCop1Arith, KindCop1Mov] then
          FPAfter := (Integer((Op shr 6) and 31) and FRMask) + 32
        else if Kind = KindCop1Compare then
          Flags := Flags or StepCondition;
    end;
    // IdleHead holds only after a delay slot.
    if ((Count = 0) and ((Mode and ModeDelay) <> 0)) or AfterBranch then
      Flags := Flags or StepMayIdle;
    var Step: PN64CPUStep := @FStepChunks[FStepChunk][FStepUsed + Count];
    Step.Op := Op;
    Step.Kind := Byte(Kind);
    Step.S := Byte(S);
    Step.T := Byte(T);
    Step.D := Byte(D);
    Step.N := Byte((Op shr 6) and 31);
    Step.Clocks := Byte(Clocks);
    Step.Size := Byte(Size);
    Step.Flags := Flags;
    Step.LoadAfter := ShortInt(LoadAfter);
    Step.FPAfter := ShortInt(FPAfter);
    Step.Index := Byte(Words);
    Step.Value := SX16(Op);
    PCardinal(NativeUInt(Words_) + NativeUInt(Words) * 4)^ := Op;
    Inc(Words);
    // A LUI the ORI/ADDIU after it adds to (both into one register): one
    // step for both (not in a delay slot, not where the block may idle).
    if (Code = 15) and (T <> 0) and ((Flags and StepMayIdle) = 0) and (Offset + 4 <= $FFC) then
    begin
      var Second := FBus.PlainRAM32((Physical and not Cardinal($FFF)) or (Offset + 4));
      if ((Second shr 26) in [9, 13]) and (Integer((Second shr 21) and 31) = T) and (Integer((Second shr 16) and 31) = T) then
      begin
        var Upper := SX32((Op and $FFFF) shl 16);
        if (Second shr 26) = 13 then
          Step.Value := Upper or (Second and $FFFF)
        else
          Step.Value := SX32(Add64(Upper, SX16(Second)));
        // Clocks stays the ORI/ADDIU's 1: the LUI's comes with it as it runs.
        Step.Kind := KindLuiPair;
        PCardinal(NativeUInt(Words_) + NativeUInt(Words) * 4)^ := Second;
        Inc(Words);
      end;
    end;
    Inc(Count);
    PrevLoad := LoadAfter;
    PrevFP := FPAfter;
    // A block entered in a delay slot has that one alone; a likely branch
    // ends one (its delay slot runs or not); a delay slot does.
    if ((Mode and ModeDelay) <> 0) or AfterBranch or ((Flags and StepLikely) <> 0) then
      Break;
    AfterBranch := (Flags and StepBranch) <> 0;
  end;
  Result.Count := Count;
  Result.Words := Words;
  Inc(FStepUsed, Count);
  Inc(FWordUsed, Words);
end;

// Block step routines: what RunBlocks's steps did by Kind, one routine each.
// RunBlocks has already moved the PC on (FInstructionPC is the step's own)
// and zeroes GPR[0] after; A is read before anything is written.

function TN64CPU.StepNop(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Result := 0;
end;

function TN64CPU.StepSLL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(GPR[Step.T] shl Step.N);
  Result := 0;
end;

function TN64CPU.StepSRL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32((GPR[Step.T] and $FFFFFFFF) shr Step.N);
  Result := 0;
end;

function TN64CPU.StepSRA(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(SAR(GPR[Step.T], Step.N, 32));
  Result := 0;
end;

function TN64CPU.StepSLLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(GPR[Step.T] shl (GPR[Step.S] and 31));
  Result := 0;
end;

function TN64CPU.StepSRLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32((GPR[Step.T] and $FFFFFFFF) shr (GPR[Step.S] and 31));
  Result := 0;
end;

function TN64CPU.StepSRAV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(SAR(GPR[Step.T], GPR[Step.S] and 31, 32));
  Result := 0;
end;

function TN64CPU.StepJR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(True, False, GPR[Step.S]);
  Result := 0;
end;

function TN64CPU.StepJALR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var A := GPR[Step.S];
  GPR[Step.D] := Add64(FInstructionPC, 8);
  Branch(True, False, A);
  Result := 0;
end;

function TN64CPU.StepMFHI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := HI;
  Result := 0;
end;

function TN64CPU.StepMTHI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  HI := GPR[Step.S];
  Result := 0;
end;

function TN64CPU.StepMFLO(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := LO;
  Result := 0;
end;

function TN64CPU.StepMTLO(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  LO := GPR[Step.S];
  Result := 0;
end;

function TN64CPU.StepDSLLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shl (GPR[Step.S] and 63);
  Result := 0;
end;

function TN64CPU.StepDSRLV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shr (GPR[Step.S] and 63);
  Result := 0;
end;

function TN64CPU.StepDSRAV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SAR(GPR[Step.T], GPR[Step.S] and 63, 64);
  Result := 0;
end;

function TN64CPU.StepMULT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var V: UInt64;
  Multiply64(SX(GPR[Step.S], 32), SX(GPR[Step.T], 32), True, HI, V);
  LO := SX(V, 32);
  HI := SX(V shr 32, 32);
  Result := 0;
end;

function TN64CPU.StepMULTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var V := (GPR[Step.S] and $FFFFFFFF) * (GPR[Step.T] and $FFFFFFFF);
  LO := SX(V, 32);
  HI := SX(V shr 32, 32);
  Result := 0;
end;

function TN64CPU.StepDIV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Divide64(SX(GPR[Step.S], 32), SX(GPR[Step.T], 32), True, HI, LO);
  HI := SX(HI, 32);
  LO := SX(LO, 32);
  Result := 0;
end;

function TN64CPU.StepDIVU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Divide64(GPR[Step.S] and $FFFFFFFF, GPR[Step.T] and $FFFFFFFF, False, HI, LO);
  HI := SX(HI, 32);
  LO := SX(LO, 32);
  Result := 0;
end;

function TN64CPU.StepDMULT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Multiply64(GPR[Step.S], GPR[Step.T], True, HI, LO);
  Result := 0;
end;

function TN64CPU.StepDMULTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Multiply64(GPR[Step.S], GPR[Step.T], False, HI, LO);
  Result := 0;
end;

function TN64CPU.StepDDIV(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Divide64(GPR[Step.S], GPR[Step.T], True, HI, LO);
  Result := 0;
end;

function TN64CPU.StepDDIVU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Divide64(GPR[Step.S], GPR[Step.T], False, HI, LO);
  Result := 0;
end;

function TN64CPU.StepADDU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(Add64(GPR[Step.S], GPR[Step.T]));
  Result := 0;
end;

function TN64CPU.StepSUBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SX32(Sub64(GPR[Step.S], GPR[Step.T]));
  Result := 0;
end;

function TN64CPU.StepAND(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.S] and GPR[Step.T];
  Result := 0;
end;

function TN64CPU.StepOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.S] or GPR[Step.T];
  Result := 0;
end;

function TN64CPU.StepXOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.S] xor GPR[Step.T];
  Result := 0;
end;

function TN64CPU.StepNOR(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := not (GPR[Step.S] or GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepSLT(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := Ord(SignedLess(GPR[Step.S], GPR[Step.T]));
  Result := 0;
end;

function TN64CPU.StepSLTU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := Ord(GPR[Step.S] < GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepDADDU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := Add64(GPR[Step.S], GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepDSUBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := Sub64(GPR[Step.S], GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepDSLL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shl Step.N;
  Result := 0;
end;

function TN64CPU.StepDSRL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shr Step.N;
  Result := 0;
end;

function TN64CPU.StepDSRA(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SAR(GPR[Step.T], Step.N, 64);
  Result := 0;
end;

function TN64CPU.StepDSLL32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shl (Step.N + 32);
  Result := 0;
end;

function TN64CPU.StepDSRL32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := GPR[Step.T] shr (Step.N + 32);
  Result := 0;
end;

function TN64CPU.StepDSRA32(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.D] := SAR(GPR[Step.T], Step.N + 32, 64);
  Result := 0;
end;

function TN64CPU.StepRegimm(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var T := Integer(Step.T);
  var Taken := SignedLess(GPR[Step.S], 0);
  if (T and 1) <> 0 then
    Taken := not Taken;
  if T >= 16 then
    GPR[31] := Add64(FInstructionPC, 8);
  Branch(Taken, (T and 2) <> 0, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepJ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Step.Op and $3FFFFFF) shl 2));
  Result := 0;
end;

function TN64CPU.StepJAL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[31] := Add64(FInstructionPC, 8);
  Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Step.Op and $3FFFFFF) shl 2));
  Result := 0;
end;

function TN64CPU.StepBEQ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(GPR[Step.S] = GPR[Step.T], False, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBEQL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(GPR[Step.S] = GPR[Step.T], True, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBNE(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(GPR[Step.S] <> GPR[Step.T], False, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBNEL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(GPR[Step.S] <> GPR[Step.T], True, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBLEZ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(not SignedLess(0, GPR[Step.S]), False, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBLEZL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(not SignedLess(0, GPR[Step.S]), True, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBGTZ(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(SignedLess(0, GPR[Step.S]), False, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepBGTZL(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  Branch(SignedLess(0, GPR[Step.S]), True, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

function TN64CPU.StepADDIU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX32(Add64(GPR[Step.S], Step.Value));
  Result := 0;
end;

function TN64CPU.StepSLTI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := Ord(SignedLess(GPR[Step.S], Step.Value));
  Result := 0;
end;

function TN64CPU.StepSLTIU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := Ord(GPR[Step.S] < Step.Value);
  Result := 0;
end;

function TN64CPU.StepANDI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := GPR[Step.S] and (Step.Op and $FFFF);
  Result := 0;
end;

function TN64CPU.StepORI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := GPR[Step.S] or (Step.Op and $FFFF);
  Result := 0;
end;

function TN64CPU.StepXORI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := GPR[Step.S] xor (Step.Op and $FFFF);
  Result := 0;
end;

function TN64CPU.StepLUI(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX32((Step.Op and $FFFF) shl 16);
  Result := 0;
end;

function TN64CPU.StepLB(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX8(FBus.ReadRAM8(Physical));
  Result := 0;
end;

function TN64CPU.StepLH(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX16(FBus.ReadRAM16(Physical));
  Result := 0;
end;

function TN64CPU.StepLW(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX32(FBus.ReadRAM32(Physical));
  Result := 0;
end;

function TN64CPU.StepLBU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := FBus.ReadRAM8(Physical);
  Result := 0;
end;

function TN64CPU.StepLHU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := FBus.ReadRAM16(Physical);
  Result := 0;
end;

function TN64CPU.StepLWU(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := FBus.ReadRAM32(Physical);
  Result := 0;
end;

function TN64CPU.StepLWC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  SetFPBits(Integer(Step.T), 16, FBus.ReadRAM32(Physical));
  Result := 0;
end;

function TN64CPU.StepLDC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  SetFPBits(Integer(Step.T), 17, (UInt64(FBus.ReadRAM32(Physical)) shl 32) or FBus.ReadRAM32(Physical + 4));
  Result := 0;
end;

function TN64CPU.StepLD(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := (UInt64(FBus.ReadRAM32(Physical)) shl 32) or FBus.ReadRAM32(Physical + 4);
  Result := 0;
end;

function TN64CPU.StepSB(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  FBus.WriteRAM8(Physical, Byte(GPR[Step.T] and $FF));
  Result := 0;
end;

function TN64CPU.StepSH(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  FBus.WriteRAM8(Physical, Byte((GPR[Step.T] shr 8) and $FF));
  FBus.WriteRAM8(Physical + 1, Byte(GPR[Step.T] and $FF));
  Result := 0;
end;

function TN64CPU.StepSW(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  FBus.WriteRAM32(Physical, Cardinal(GPR[Step.T] and $FFFFFFFF));
  Result := 0;
end;

function TN64CPU.StepSD(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var V := GPR[Step.T];
  FBus.WriteRAM32(Physical, Cardinal(V shr 32));
  FBus.WriteRAM32(Physical + 4, Cardinal(V and $FFFFFFFF));
  Result := 0;
end;

function TN64CPU.StepSWC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var V := FPBits(Integer(Step.T), 16);
  FBus.WriteRAM32(Physical, Cardinal(V and $FFFFFFFF));
  Result := 0;
end;

function TN64CPU.StepSDC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var V := FPBits(Integer(Step.T), 17);
  FBus.WriteRAM32(Physical, Cardinal(V shr 32));
  FBus.WriteRAM32(Physical + 4, Cardinal(V and $FFFFFFFF));
  Result := 0;
end;

function TN64CPU.StepMFC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := SX(FPBits(Step.D, 16), 32);
  Result := 0;
end;

function TN64CPU.StepDMFC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  GPR[Step.T] := FPBits(Step.D, 17);
  Result := 0;
end;

function TN64CPU.StepMTC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  SetFPBits(Step.D, 16, GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepDMTC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  SetFPBits(Step.D, 17, GPR[Step.T]);
  Result := 0;
end;

function TN64CPU.StepFPCompare(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var F := Integer(Step.S);
  var Fn := Integer(Step.Op and 63);
  FCR31 := FCR31 and not $3F000;
  Result := FPClocks(FP.A, FP.B, F, Fn) - 1;
  var Unordered, Equal, Less: Boolean;
  SFCompare(FP.A, FP.B, F, Unordered, Equal, Less);
  FCR31 := FCR31 and not $800000;
  if (((Fn and 1) <> 0) and Unordered) or (((Fn and 2) <> 0) and Equal) or (((Fn and 4) <> 0) and Less) then
    FCR31 := FCR31 or $800000;
end;

function TN64CPU.StepFPArith(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  // As Cop1, which FastFloat found takes no special path.
  FCR31 := FCR31 and not $3F000;
  Result := FP.Cycles - 1;
  // FPExceptions of the result's events (none traps).
  FCR31 := FCR31 or ((FP.Res.Events and 31) shl 12);
  FCR31 := FCR31 or (((FP.Res.Events and not (FCR31 shr 7)) and 31) shl 2);
  var D := Integer(Step.N);
  if (FP.Target in [16, 20]) and ((CP0[12] and $4000000) <> 0) then
    FPR[D] := FP.Res.Bits and $FFFFFFFF
  else
    SetFPBits(D, FP.Target, FP.Res.Bits);
end;

function TN64CPU.StepFPMov(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  SetFPBits(Integer(Step.N), 17, FPBits(Integer(Step.D), 17));
  Result := 0;
end;

function TN64CPU.StepBC1(Step: PN64CPUStep; Physical: Cardinal; FP: PStepFP): Cardinal;
begin
  var T := Integer(Step.T);
  FCR31 := FCR31 and not $3F000;
  Branch(((FCR31 and $800000) <> 0) = ((T and 1) <> 0), (T and 2) <> 0, Add64(FPC, Step.Value shl 2));
  Result := 0;
end;

// --- Blocks as generated code ------------------------------------------------
//
// HW.JIT (on targets with a code generator, N64Jit): a block's code
// runs its steps as RunBlocks's loop does, from its first, when their PClocks
// and count cannot reach Limit and MaxSteps before its last step (JitMax,
// JitSteps); else its careful code, which stops after any step that does. It
// leaves out what no step reads: the PC and pipeline bookkeeping of each
// step, its count and PClocks, the stop checks; it writes them for its last
// step (JitRun for a block left early). Steps up to a branch read no PC, so
// the code writes it only for a branch (from the PC on entry) and its delay
// slot (as RunBlocks does). Each step calls its routine (FStepRoutines): what
// a step does is its routine's alone, whatever compiled it. Memory steps call
// JitData (FastData) first, COP1 compares and arithmetic JitFP. After its
// last step a block goes on into the next block's code as RunBlocks would
// enter it: by direct links (JitLink) or the shared chaining code
// (JitEmitChain: links on its page, far links on others); else back to
// RunBlocks. The same steps either way: CPUTest and the suite's hashes
// compare them.
// The code is written in HW.JIT's operations; its registers by role: Self
// the CPU, Ctx the TJitCtx, and the kept S0..S3 as Block, Extra, Store, Entry.

const
  // The kept registers: the block being run, its stall and FP PClocks (32
  // bits), whether its last store was cached (a byte), its PC on entry.
  jrBlock = jrS0;
  jrExtra = jrS1;
  jrStore = jrS2;
  jrEntry = jrS3;
  JBlock: TJitOp = (Kind: okReg; Reg: jrBlock);
  JExtra: TJitOp = (Kind: okReg; Reg: jrExtra);
  JStore: TJitOp = (Kind: okReg; Reg: jrStore);
  JEntry: TJitOp = (Kind: okReg; Reg: jrEntry);
  // A block's code returns (with the steps done of the last block it ran): 0
  // all of them, 1 declined before step Done (FastData or FastFloat), 2 a
  // store wrote its own code, 3 careful code reached a limit (after Done).
  JitStatusDone = 0;
  JitStatusDecline = 1;
  JitStatusRewritten = 2;
  JitStatusStopped = 3;
  // (The order the code for its exits comes in.)
  JitExitOrder: array[0..2] of Integer = (JitStatusDecline, JitStatusStopped, JitStatusRewritten);
  // FJitCalls past the steps' routines.
  JitCallData = 256;
  JitCallFP = 257;
  // FPClocks at most: a compare or arithmetic step's PClocks beyond its own.
  JitFPExtraMax = 57;

type
  PN64PageEntryJit = ^TN64PageEntry;

  // Where the code reads and writes the CPU, its context, blocks and page
  // entries (offsets, worked out once).
  TJitOffsets = record
    GPR, HI, LO, PC, NextPC, InstrPC, Delay, InDelay, PrevStore, PrevCond, PrevLoad, PrevFP, PrevExc: Integer;
    BlocksRun, JitRuns, Exits, Calls, TLBGeneration, Pages: Integer;
    FastPage, FastPhysical, FastContext, FastGeneration, FastValid: Integer;
    CtxPhysical, CtxCached, CtxDone, CtxExtra, CtxPrevStore, CtxFP, CtxBlock, CtxBlockPC: Integer;
    CtxCount, CtxClocks, CtxLimit, CtxMaxSteps, CtxKernel, CtxDirect, CtxContext: Integer;
    BMode, BEntryLoad, BEntryFP, BGen, BWords, BPhysical, BSteps, BLink0, BLink1, BLinkPC0, BLinkPC1: Integer;
    BFar0, BFar1, BFarPC0, BFarPC1, BInner, BJitMax, BJitSteps: Integer;
    EPage, EPhysical, EContext, EGeneration, EReadOK, EWriteOK: Integer;
    // A page entry's size, as a shift.
    PageShift: Integer;
  end;

var
  JitOff: TJitOffsets;

procedure JitWorkOutOffsets;
type
  PCtx = TN64CPU.PJitCtx;
begin
  var O := Default(TJitOffsets);
  O.GPR := Integer(NativeUInt(@TN64CPU(nil).GPR[0]));
  O.HI := Integer(NativeUInt(@TN64CPU(nil).HI));
  O.LO := Integer(NativeUInt(@TN64CPU(nil).LO));
  O.PC := Integer(NativeUInt(@TN64CPU(nil).FPC));
  O.NextPC := Integer(NativeUInt(@TN64CPU(nil).FNextPC));
  O.InstrPC := Integer(NativeUInt(@TN64CPU(nil).FInstructionPC));
  O.Delay := Integer(NativeUInt(@TN64CPU(nil).FDelay));
  O.InDelay := Integer(NativeUInt(@TN64CPU(nil).FInDelay));
  O.PrevStore := Integer(NativeUInt(@TN64CPU(nil).FPreviousStore));
  O.PrevCond := Integer(NativeUInt(@TN64CPU(nil).FPreviousCondition));
  O.PrevLoad := Integer(NativeUInt(@TN64CPU(nil).FPreviousLoad));
  O.PrevFP := Integer(NativeUInt(@TN64CPU(nil).FPreviousFP));
  O.PrevExc := Integer(NativeUInt(@TN64CPU(nil).FPreviousException));
  O.BlocksRun := Integer(NativeUInt(@TN64CPU(nil).FBlocksRun));
  O.JitRuns := Integer(NativeUInt(@TN64CPU(nil).FJitRuns));
  O.Exits := Integer(NativeUInt(@TN64CPU(nil).FJitExits[0]));
  O.Calls := Integer(NativeUInt(@TN64CPU(nil).FJitCalls[0]));
  O.TLBGeneration := Integer(NativeUInt(@TN64CPU(nil).FTLBGeneration));
  O.Pages := Integer(NativeUInt(@TN64CPU(nil).FPages[0]));
  O.FastPage := Integer(NativeUInt(@TN64CPU(nil).FFastCodePage));
  O.FastPhysical := Integer(NativeUInt(@TN64CPU(nil).FFastCodePhysical));
  O.FastContext := Integer(NativeUInt(@TN64CPU(nil).FFastCodeContext));
  O.FastGeneration := Integer(NativeUInt(@TN64CPU(nil).FFastCodeGeneration));
  O.FastValid := Integer(NativeUInt(@TN64CPU(nil).FFastCodeValid));
  O.CtxPhysical := Integer(NativeUInt(@PCtx(nil).Physical));
  O.CtxCached := Integer(NativeUInt(@PCtx(nil).Cached));
  O.CtxDone := Integer(NativeUInt(@PCtx(nil).Done));
  O.CtxExtra := Integer(NativeUInt(@PCtx(nil).Extra));
  O.CtxPrevStore := Integer(NativeUInt(@PCtx(nil).PrevStore));
  O.CtxFP := Integer(NativeUInt(@PCtx(nil).FP));
  O.CtxBlock := Integer(NativeUInt(@PCtx(nil).Block));
  O.CtxBlockPC := Integer(NativeUInt(@PCtx(nil).BlockPC));
  O.CtxCount := Integer(NativeUInt(@PCtx(nil).Count));
  O.CtxClocks := Integer(NativeUInt(@PCtx(nil).Clocks));
  O.CtxLimit := Integer(NativeUInt(@PCtx(nil).Limit));
  O.CtxMaxSteps := Integer(NativeUInt(@PCtx(nil).MaxSteps));
  O.CtxKernel := Integer(NativeUInt(@PCtx(nil).Kernel));
  O.CtxDirect := Integer(NativeUInt(@PCtx(nil).Direct));
  O.CtxContext := Integer(NativeUInt(@PCtx(nil).Context));
  O.BMode := Integer(NativeUInt(@PN64CPUBlock(nil).Mode));
  O.BEntryLoad := Integer(NativeUInt(@PN64CPUBlock(nil).EntryLoad));
  O.BEntryFP := Integer(NativeUInt(@PN64CPUBlock(nil).EntryFP));
  O.BGen := Integer(NativeUInt(@PN64CPUBlock(nil).Gen));
  O.BWords := Integer(NativeUInt(@PN64CPUBlock(nil).Words));
  O.BPhysical := Integer(NativeUInt(@PN64CPUBlock(nil).Physical));
  O.BSteps := Integer(NativeUInt(@PN64CPUBlock(nil).Steps));
  O.BLink0 := Integer(NativeUInt(@PN64CPUBlock(nil).Link[0]));
  O.BLink1 := Integer(NativeUInt(@PN64CPUBlock(nil).Link[1]));
  O.BLinkPC0 := Integer(NativeUInt(@PN64CPUBlock(nil).LinkPC[0]));
  O.BLinkPC1 := Integer(NativeUInt(@PN64CPUBlock(nil).LinkPC[1]));
  O.BFar0 := Integer(NativeUInt(@PN64CPUBlock(nil).Far[0]));
  O.BFar1 := Integer(NativeUInt(@PN64CPUBlock(nil).Far[1]));
  O.BFarPC0 := Integer(NativeUInt(@PN64CPUBlock(nil).FarPC[0]));
  O.BFarPC1 := Integer(NativeUInt(@PN64CPUBlock(nil).FarPC[1]));
  O.BInner := Integer(NativeUInt(@PN64CPUBlock(nil).NativeInner));
  O.BJitMax := Integer(NativeUInt(@PN64CPUBlock(nil).JitMax));
  O.BJitSteps := Integer(NativeUInt(@PN64CPUBlock(nil).JitSteps));
  O.EPage := Integer(NativeUInt(@PN64PageEntryJit(nil).Page));
  O.EPhysical := Integer(NativeUInt(@PN64PageEntryJit(nil).Physical));
  O.EContext := Integer(NativeUInt(@PN64PageEntryJit(nil).Context));
  O.EGeneration := Integer(NativeUInt(@PN64PageEntryJit(nil).Generation));
  O.EReadOK := Integer(NativeUInt(@PN64PageEntryJit(nil).ReadOK));
  O.EWriteOK := Integer(NativeUInt(@PN64PageEntryJit(nil).WriteOK));
  while (1 shl O.PageShift) < SizeOf(TN64PageEntry) do
    Inc(O.PageShift);
  Assert((1 shl O.PageShift) = SizeOf(TN64PageEntry));
  JitOff := O;
end;

function TN64CPU.JitFP(Step: PN64CPUStep; Ctx: PJitCtx): Cardinal;
begin
  // As RunBlocks before a COP1 compare or arithmetic step (FT only for a
  // compare and arithmetic 0..3: a unary operation or conversion has 0); 1
  // where it goes on, 0 where it declines (32 bits: one test of the result).
  var F := Integer(Step.S);
  Ctx.FP.A := FPBits(Integer(Step.D), F);
  Ctx.FP.B := 0;
  if (Step.Kind = KindCop1Compare) or ((Step.Op and 63) <= 3) then
    Ctx.FP.B := FPBits(Integer(Step.T), F);
  if Step.Kind = KindCop1Compare then
    Result := Ord(not (SFIsNaN(Ctx.FP.A, F) or SFIsNaN(Ctx.FP.B, F)))
  else
    Result := Ord(FastFloat(Step.Op, Ctx.FP.A, Ctx.FP.B, Ctx.FP.Res, Ctx.FP.Cycles, Ctx.FP.Target));
end;

function TN64CPU.JitData(Ctx: PJitCtx; Step: PN64CPUStep): Cardinal;
begin
  // As RunBlocks before a memory step: FastData for its access (into Ctx:
  // its physical address and whether it is cached); 1 where it goes on, 0
  // where it declines.
  var Physical: Cardinal;
  var Cached: Boolean;
  Result := 0;
  if FastData(Add64(GPR[Step.S], Step.Value), Step.Size, (Step.Flags and StepWriting) <> 0, Ctx.Context,
    Physical, Cached) then
  begin
    Ctx.Physical := Physical;
    Ctx.Cached := Cached;
    Result := 1;
  end;
end;

// Whether step K of B writes GPR[0] (its routine; RunBlocks zeroes it after).
function WritesR0(S: PN64CPUStep): Boolean;
begin
  case S.Kind of
    KindSpecial + 0, KindSpecial + 2..KindSpecial + 4, KindSpecial + 6, KindSpecial + 7, KindSpecial + 9,
    KindSpecial + 16, KindSpecial + 18, KindSpecial + 20, KindSpecial + 22, KindSpecial + 23,
    KindSpecial + 33, KindSpecial + 35..KindSpecial + 39, KindSpecial + 42, KindSpecial + 43,
    KindSpecial + 45, KindSpecial + 47, KindSpecial + 56, KindSpecial + 58..KindSpecial + 60,
    KindSpecial + 62, KindSpecial + 63:
      Result := S.D = 0;
    9..15, 32, 33, 35..37, 39, 55, KindCop1Move + 0, KindCop1Move + 1, KindLuiPair:
      Result := S.T = 0;
  else
    Result := False;
  end;
end;

// Whether a block's code writes the PC and pipeline bookkeeping of its
// step I itself (a branch, or its delay slot), as RunBlocks's steps do.
function StepWritesPC(B: PN64CPUBlock; I: Integer): Boolean;
begin
  Result := ((StepOf(B, I).Flags and StepBranch) <> 0) or
    ((I >= 1) and ((StepOf(B, I - 1).Flags and StepBranch) <> 0)) or
    ((I = 0) and ((B.Mode and ModeDelay) <> 0));
end;

function TN64CPU.JitExitTo(Done, Status: Integer): TJitLabel;
begin
  // A way out of the block's code back to RunBlocks, after its first Done
  // steps (JitEmitReturn writes it).
  if FJitExitCount = Length(FJitExitLabel) then
  begin
    SetLength(FJitExitLabel, FJitExitCount * 2 + 64);
    SetLength(FJitExitDone, FJitExitCount * 2 + 64);
    SetLength(FJitExitStatus, FJitExitCount * 2 + 64);
  end;
  Result := FJit.NewLabel;
  FJitExitLabel[FJitExitCount] := Result;
  FJitExitDone[FJitExitCount] := Done;
  FJitExitStatus[FJitExitCount] := Status;
  Inc(FJitExitCount);
end;

procedure TN64CPU.JitMark(Kind: Integer);
begin
  if not FJitStats then
    Exit;
  if FJitMapCount = Length(FJitMapOffset) then
  begin
    SetLength(FJitMapOffset, FJitMapCount * 2 + 1024);
    SetLength(FJitMapKind, FJitMapCount * 2 + 1024);
  end;
  FJitMapOffset[FJitMapCount] := FJit.Offset;
  FJitMapKind[FJitMapCount] := Kind;
  Inc(FJitMapCount);
end;

class function TN64CPU.JitAvailable: Boolean;
begin
  Result := N64Jit and not (jdOff in JitDebug);
end;

class procedure TN64CPU.JitForTests(Hot: Integer; Model: Boolean);
begin
  JitHot := Hot;
  if Model then
    Include(JitDebug, jdModel)
  else
    Exclude(JitDebug, jdModel);
end;

function TN64CPU.JitWhat(Address: UInt64): Integer;
begin
  Result := -1;
  if (FJit = nil) or (Address < UInt64(FJit.Base)) or (Address >= UInt64(FJit.Base) + UInt64(FJit.Size)) then
    Exit;
  var Off := NativeInt(Address - UInt64(FJit.Base));
  var Lo := 0;
  var Hi := FJitMapCount - 1;
  while Lo <= Hi do
  begin
    var Mid := (Lo + Hi) div 2;
    if FJitMapOffset[Mid] <= Off then
    begin
      Result := FJitMapKind[Mid];
      Lo := Mid + 1;
    end
    else
      Hi := Mid - 1;
  end;
end;

procedure TN64CPU.JitMeasure(B: PN64CPUBlock);
begin
  // Its steps (a LUI pair counted twice) and their PClocks without stalls,
  // for JitRun and chaining; an upper bound of all its PClocks, for the
  // checks before entering it.
  var Steps: Cardinal := 0;
  var Clk: Cardinal := 0;
  var MaxClk: Cardinal := 0;
  for var I := 0 to B.Count - 1 do
  begin
    var S := StepOf(B, I);
    Inc(Steps);
    Inc(Clk, S.Clocks);
    if S.Kind = KindLuiPair then
    begin
      Inc(Steps);
      Inc(Clk);
    end;
    if (S.Size <> 0) and ((S.Flags and StepMemoryHazard) <> 0) then
      Inc(MaxClk);
    if S.Kind = KindCop1Branch then
      Inc(MaxClk);
    if S.Kind in [KindCop1Compare, KindCop1Arith] then
      Inc(MaxClk, JitFPExtraMax);
  end;
  B.JitSteps := Steps;
  B.JitClocks := Clk;
  B.JitMax := Clk + MaxClk;
end;

procedure TN64CPU.JitEmitShared;
begin
  // The code every block's code shares: the entry (Invoke'd with the CPU,
  // the TJitCtx, the block's code and the block; the frame, then to the
  // block's code with Block in T1; its result 0 all the last block's steps
  // ran (their totals added), 1 declined before step Done (FastData or
  // FastFloat), 2 a store wrote its own code (after Done), 3 careful code
  // reached a limit (after Done)), the way back to RunBlocks (T1 the
  // steps done shl 2 or the status; Extra, Store, Block and Entry as the
  // block's code left them), and the chaining code (JitEmitChain).
  var J := FJit;
  var O := JitOff;
  J.ForgetLabels;
  J.Align(16);
  JitMark(2000);
  FJitEnter := J.Offset;
  J.EnterJump;
  J.Align(16);
  FJitReturn := J.Offset;
  J.Move(jw32, JT0, JT1);
  J.Alu(jaAnd, jw32, JT0, JImm(3));
  J.Shift(jsShr, jw32, jrT1, 2);
  if FJitStats then
  begin
    // (Declines and rewrites counted.)
    var NotDecline := J.NewLabel;
    J.Branch(jcNe, jw32, JT0, JImm(JitStatusDecline), NotDecline);
    J.Alu(jaAdd, jw64, JMem(jrSelf, O.Exits + 15 * 8), JImm(1));
    J.Bind(NotDecline);
    var NotRewritten := J.NewLabel;
    J.Branch(jcNe, jw32, JT0, JImm(JitStatusRewritten), NotRewritten);
    J.Alu(jaAdd, jw64, JMem(jrSelf, O.Exits + 16 * 8), JImm(1));
    J.Bind(NotRewritten);
  end;
  J.Move(jw32, JMem(jrCtx, O.CtxDone), JT1);
  J.Move(jw32, JMem(jrCtx, O.CtxExtra), JExtra);
  J.Move(jw8, JMem(jrCtx, O.CtxPrevStore), JStore);
  J.Move(jw64, JMem(jrCtx, O.CtxBlock), JBlock);
  J.Move(jw64, JMem(jrCtx, O.CtxBlockPC), JEntry);
  J.Leave(JT0);
  J.ForgetLabels;
  JitEmitChain;
end;

procedure TN64CPU.JitEmitChain;
var
  // Where the chaining stops (N64JIT=stats: counted by reason).
  NoLabel: array[0..31] of TJitLabel;
  NoReason: array[0..31] of Integer;
  NoCount: Integer;

  function No(Reason: Integer): TJitLabel;
  begin
    Result := FJit.NewLabel;
    NoLabel[NoCount] := Result;
    NoReason[NoCount] := Reason;
    Inc(NoCount);
  end;

begin
  // The code every block's code jumps to after its last step: into the next
  // block's code as RunBlocks would enter it from there, else back to
  // RunBlocks (status 0: all steps ran). The next block: by link on this
  // page (its link PC, mode, entry state, code unchanged, steps within the
  // limits), or by far link on another page (also its page as FastCode and
  // RunBlocks's clean-code checks find it; it becomes the fast code page).
  // In: Self, Ctx, Block the block that ran, Entry its PC; the block's frame.
  // FJitChainIdle first stops where IdleHead holds.
  var J := FJit;
  var O := JitOff;
  var Info := FBus.JitInfo;
  NoCount := 0;
  J.ForgetLabels;

  // IdleHead (after a step that may leave it): RunBlocks stops.
  J.Align(16);
  JitMark(2000);
  FJitChainIdle := J.Offset;
  var NotIdle := J.NewLabel;
  J.Move(jw8, JT0, JMem(jrSelf, O.InDelay));
  J.BranchTest(jcEq, jw8, JT0, JT0, NotIdle);
  J.Move(jw8, JT0, JMem(jrSelf, O.Delay));
  J.BranchTest(jcNe, jw8, JT0, JT0, NotIdle);
  J.Move(jw64, JT0, JMem(jrSelf, O.InstrPC));
  J.Alu(jaAdd, jw64, JT0, JImm(-4));
  J.Branch(jcNe, jw64, JT0, JMem(jrSelf, O.PC), NotIdle);
  J.Move(jw64, JT0, JMem(jrSelf, O.PC));
  J.Alu(jaAdd, jw64, JT0, JImm(4));
  J.Branch(jcEq, jw64, JT0, JMem(jrSelf, O.NextPC), No(0));
  J.Bind(NotIdle);

  // T0: the PC (aligned); T6: the next block's mode.
  FJitChain := J.Offset;
  J.Move(jw64, JT0, JMem(jrSelf, O.PC));
  J.BranchTest(jcNe, jw8, JT0, JImm(3), No(2));
  J.Move(jw8, JT6, JMem(jrBlock, O.BMode));
  J.Alu(jaAnd, jw32, JT6, JImm(not ModeDelay));
  J.Move(jw8, JT1, JMem(jrSelf, O.Delay));
  var NotDelay := J.NewLabel;
  var PageCheck := J.NewLabel;
  J.BranchTest(jcEq, jw8, JT1, JT1, NotDelay);
  // In a delay slot (a likely branch taken, or a branch the page or the
  // block ended after): a block entered in one.
  J.Alu(jaOr, jw32, JT6, JImm(ModeDelay));
  J.Jump(PageCheck);
  J.Bind(NotDelay);
  // NextPC after the PC.
  J.Move(jw64, JT1, JT0);
  J.Alu(jaAdd, jw64, JT1, JImm(4));
  J.Branch(jcNe, jw64, JT1, JMem(jrSelf, O.NextPC), No(3));
  J.Bind(PageCheck);
  J.Move(jw64, JT1, JT0);
  J.Shift(jsShr, jw64, jrT1, 12);
  J.Move(jw64, JT2, JEntry);
  J.Shift(jsShr, jw64, jrT2, 12);
  var ToFar := J.NewLabel;
  J.Branch(jcNe, jw64, JT1, JT2, ToFar);

  // This page (T5 0): the link as RunBlocks takes it, [0] at the block's end;
  // T1 the block linked.
  J.Move(jw32, JT5, JImm(0));
  J.Move(jw32, JT1, JMem(jrBlock, O.BWords));
  J.Shift(jsShl, jw32, jrT1, 2);
  J.Alu(jaAdd, jw64, JT1, JEntry);
  var Taken := J.NewLabel;
  var HaveLink := J.NewLabel;
  J.Branch(jcNe, jw64, JT1, JT0, Taken);
  J.Branch(jcNe, jw64, JT0, JMem(jrBlock, O.BLinkPC0), No(5));
  J.Move(jw64, JT1, JMem(jrBlock, O.BLink0));
  J.Jump(HaveLink);
  J.Bind(Taken);
  J.Branch(jcNe, jw64, JT0, JMem(jrBlock, O.BLinkPC1), No(6));
  J.Move(jw64, JT1, JMem(jrBlock, O.BLink1));
  J.Bind(HaveLink);
  J.BranchTest(jcEq, jw64, JT1, JT1, No(7));
  // T3: its code page's count (the block's).
  J.Move(jw32, JT3, JMem(jrBlock, O.BPhysical));
  J.Shift(jsShr, jw32, jrT3, 12);
  J.Shift(jsShl, jw64, jrT3, 2);
  J.Move(jw64, JT4, JImm(Int64(NativeUInt(Info.CodeGen))));
  J.Alu(jaAdd, jw64, JT3, JT4);
  var Common := J.NewLabel;
  J.Jump(Common);

  // Another page, as FastCode finds it: KSEG0/KSEG1 in kernel mode, or a
  // page translated before in this context (FPages); all in RDRAM. T2: its
  // physical page; T5: the PC.
  J.Bind(ToFar);
  J.Move(jw64, JT5, JT0);
  J.Move(jw64, JT1, JImm($80000000));             // T1 := PC - KSeg0Base
  J.Alu(jaAdd, jw64, JT1, JT0);
  var Mapped := J.NewLabel;
  var HavePage := J.NewLabel;
  J.Branch(jcAboveEq, jw64, JT1, JImm($40000000), Mapped);
  J.Move(jw8, JT1, JMem(jrCtx, O.CtxKernel));
  J.BranchTest(jcEq, jw8, JT1, JT1, No(18));
  J.Move(jw64, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm($1FFFF000));
  J.Jump(HavePage);
  J.Bind(Mapped);
  J.Shift(jsShr, jw64, jrT0, 12);                  // the virtual page
  J.Move(jw64, JT1, JT0);
  J.Shift(jsShr, jw64, jrT1, 10);
  J.Alu(jaXor, jw64, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm(High(FPages)));
  J.Shift(jsShl, jw64, jrT1, O.PageShift);
  J.Alu(jaAdd, jw64, JT1, JSelf);                  // T1: Self + the slot's offset
  J.Branch(jcNe, jw64, JT0, JMem(jrT1, O.Pages + O.EPage), No(19));
  J.Move(jw32, JT3, JMem(jrSelf, O.TLBGeneration));
  J.Branch(jcNe, jw32, JT3, JMem(jrT1, O.Pages + O.EGeneration), No(19));
  J.Move(jw32, JT3, JMem(jrCtx, O.CtxContext));
  J.Branch(jcNe, jw32, JT3, JMem(jrT1, O.Pages + O.EContext), No(19));
  J.Move(jw8, JT0, JMem(jrT1, O.Pages + O.EReadOK));
  J.Move(jw8, JT3, JMem(jrT1, O.Pages + O.EWriteOK));
  J.Alu(jaOr, jw32, JT0, JT3);
  J.BranchTest(jcEq, jw8, JT0, JT0, No(19));
  J.Move(jw64, JT2, JMem(jrT1, O.Pages + O.EPhysical));
  J.Bind(HavePage);
  J.Branch(jcAbove, jw64, JT2, JImm(FBus.RAMSize - $1000), No(20));
  // No SP DMA beat may write it, no queued RDP work (SPReadHazard,
  // RDPReadClean).
  J.Move(jw64, JT3, JImm(Int64(NativeUInt(Info.SPMarked))));
  J.Move(jw64, JT0, JMem(jrT3, 0));
  J.Move(jw64, JT4, JImm(Int64(NativeUInt(Info.SPDoneCount))));
  J.Move(jw64, JT4, JMem(jrT4, 0));
  var NoSP := J.NewLabel;
  J.Branch(jcLe, jw64, JT0, JT4, NoSP);
  J.Move(jw64, JT3, JT2);
  J.Shift(jsShr, jw64, jrT3, 9);                   // (page shr 12) * 8
  J.Move(jw64, JT0, JImm(Int64(NativeUInt(Info.SPWrites))));
  J.Alu(jaAdd, jw64, JT3, JT0);
  J.Move(jw64, JT0, JMem(jrT3, 0));
  J.Branch(jcGt, jw64, JT0, JT4, No(21));
  J.Bind(NoSP);
  J.Move(jw64, JT3, JImm(Int64(NativeUInt(Info.RDPPending))));
  J.Move(jw8, JT0, JMem(jrT3, 0));
  var NoRDP := J.NewLabel;
  J.BranchTest(jcEq, jw8, JT0, JT0, NoRDP);
  J.Move(jw64, JT3, JT2);
  J.Shift(jsShr, jw64, jrT3, 9);
  J.Move(jw64, JT0, JImm(Int64(NativeUInt(Info.RDPWrites))));
  J.Alu(jaAdd, jw64, JT3, JT0);
  J.Move(jw64, JT0, JMem(jrT3, 0));
  J.Move(jw64, JT4, JImm(Int64(NativeUInt(Info.RDPDone))));
  J.Branch(jcAbove, jw64, JT0, JMem(jrT4, 0), No(22));
  J.Bind(NoRDP);
  // Its far link, at that physical address now.
  var Far1 := J.NewLabel;
  var HaveFar := J.NewLabel;
  J.Branch(jcNe, jw64, JT5, JMem(jrBlock, O.BFarPC0), Far1);
  J.Move(jw64, JT1, JMem(jrBlock, O.BFar0));
  J.Jump(HaveFar);
  J.Bind(Far1);
  J.Branch(jcNe, jw64, JT5, JMem(jrBlock, O.BFarPC1), No(7));
  J.Move(jw64, JT1, JMem(jrBlock, O.BFar1));
  J.Bind(HaveFar);
  J.BranchTest(jcEq, jw64, JT1, JT1, No(7));
  J.Move(jw64, JT0, JT5);
  J.Alu(jaAnd, jw32, JT0, JImm($FFF));
  J.Alu(jaOr, jw32, JT0, JT2);
  J.Branch(jcNe, jw32, JT0, JMem(jrT1, O.BPhysical), No(7));
  // T3: its code page's count.
  J.Move(jw64, JT3, JT2);
  J.Shift(jsShr, jw64, jrT3, 10);                  // (page shr 12) * 4
  J.Move(jw64, JT0, JImm(Int64(NativeUInt(Info.CodeGen))));
  J.Alu(jaAdd, jw64, JT3, JT0);
  J.Bind(Common);

  // Both: its mode, entry state, code and limits.
  J.Branch(jcNe, jw8, JMem(jrT1, O.BMode), JT6, No(8));
  J.Move(jw8, JT0, JMem(jrSelf, O.PrevLoad));
  J.Branch(jcNe, jw8, JMem(jrT1, O.BEntryLoad), JT0, No(9));
  J.Move(jw8, JT0, JMem(jrSelf, O.PrevFP));
  J.Branch(jcNe, jw8, JMem(jrT1, O.BEntryFP), JT0, No(10));
  J.Move(jw64, JT4, JMem(jrT1, O.BInner));
  J.BranchTest(jcEq, jw64, JT4, JT4, No(11));
  J.Move(jw32, JT0, JMem(jrT3, 0));
  J.Branch(jcNe, jw32, JT0, JMem(jrT1, O.BGen), No(12));
  J.Move(jw32, JT0, JMem(jrT1, O.BJitMax));
  J.Alu(jaAdd, jw64, JT0, JMem(jrCtx, O.CtxClocks));
  J.Branch(jcAboveEq, jw64, JT0, JMem(jrCtx, O.CtxLimit), No(13));
  J.Move(jw32, JT0, JMem(jrCtx, O.CtxCount));
  J.Alu(jaAdd, jw32, JT0, JMem(jrT1, O.BJitSteps));
  J.Branch(jcGe, jw32, JT0, JMem(jrCtx, O.CtxMaxSteps), No(14));
  // Another page: it becomes the fast code page (FastCode).
  var SamePage := J.NewLabel;
  J.BranchTest(jcEq, jw64, JT5, JT5, SamePage);
  J.Move(jw64, JT0, JT5);
  J.Shift(jsShr, jw64, jrT0, 12);
  J.Move(jw64, JMem(jrSelf, O.FastPage), JT0);
  J.Move(jw32, JMem(jrSelf, O.FastPhysical), JT2);
  J.Move(jw32, JT0, JMem(jrCtx, O.CtxContext));
  J.Move(jw32, JMem(jrSelf, O.FastContext), JT0);
  J.Move(jw32, JT0, JMem(jrSelf, O.TLBGeneration));
  J.Move(jw32, JMem(jrSelf, O.FastGeneration), JT0);
  J.Move(jw8, JMem(jrSelf, O.FastValid), JImm(1));
  J.Bind(SamePage);
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.BlocksRun), JImm(1));
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.JitRuns), JImm(1));
  J.JumpIndirect(JMem(jrT1, O.BInner));

  // Back to RunBlocks: status 0 (RunBlocks reads nothing else of it).
  var Back := J.NewLabel;
  for var K := 0 to NoCount - 1 do
  begin
    J.Bind(NoLabel[K]);
    if FJitStats then
    begin
      J.Alu(jaAdd, jw64, JMem(jrSelf, O.Exits + NoReason[K] * 8), JImm(1));
      J.Jump(Back);
    end;
  end;
  J.Bind(Back);
  J.Move(jw64, JMem(jrCtx, O.CtxBlock), JBlock);
  J.Move(jw64, JMem(jrCtx, O.CtxBlockPC), JEntry);
  J.Leave(JImm(JitStatusDone));
  J.ForgetLabels;
end;

procedure TN64CPU.JitLink(From, B: PN64CPUBlock; PC: UInt64);
begin
  // A direct jump from From's code to B's, for RunBlocks's way from From to
  // B at PC on this page (From's link). Its code checks what can change:
  // the PC, whether in a delay slot, B's code page unwritten since B was
  // checked, B's steps within the limits; IdleHead first after a step that
  // may leave it. Otherwise it goes on as before (the next direct link or
  // the shared chaining code).
  if not N64Jit or (From.Native = nil) or (B.NativeInner = nil) or (From.JitTail < 0) then
    Exit;
  if (Int64(PC) < -Int64($80000000)) or (Int64(PC) >= $80000000) or ((PC and 3) <> 0) then
    Exit;
  if (From.Physical shr 12) <> (B.Physical shr 12) then
    Exit;
  for var K := 0 to From.JitLinks - 1 do
    if (From.JitLinkTo[K] = B) and (From.JitLinkPC[K] = PC) then
      Exit;
  var Last := StepOf(From, From.Count - 1);
  if (B.EntryLoad <> Last.LoadAfter) or (B.EntryFP <> Last.FPAfter) or
    ((B.Mode and not ModeDelay) <> (From.Mode and not ModeDelay)) then
    Exit;
  if not FJit.Room(256) then
    Exit;
  var J := FJit;
  var O := JitOff;
  var MayIdle := (Last.Flags and StepMayIdle) <> 0;
  var Generic := FJitChain;
  if MayIdle then
    Generic := FJitChainIdle;
  // Where From's code went after its last step so far.
  var Before := J.SiteTarget(From.JitTail);

  J.Align(16);
  JitMark(2004);
  var Start := J.Offset;
  J.BranchTo(jcNe, jw64, JMem(jrSelf, O.PC), JImm(Int64(PC)), Before);
  if MayIdle then
  begin
    // FPC = FInstructionPC - 4: maybe IdleHead (the shared code decides).
    J.Move(jw64, JT0, JMem(jrSelf, O.InstrPC));
    J.Alu(jaAdd, jw64, JT0, JImm(-4));
    J.BranchTo(jcEq, jw64, JT0, JImm(Int64(PC)), Generic);
  end;
  J.BranchTo(jcNe, jw8, JMem(jrSelf, O.Delay), JImm(Ord((B.Mode and ModeDelay) <> 0)), Generic);
  J.Move(jw64, JT1, JImm(Int64(NativeUInt(B))));
  J.Move(jw32, JT0, JMem(jrT1, O.BGen));
  J.Move(jw64, JT3, JImm(Int64(NativeUInt(FBus.CodeGenerations) + NativeUInt(B.Physical shr 12) * 4)));
  J.BranchTo(jcNe, jw32, JT0, JMem(jrT3, 0), Generic);
  J.Move(jw64, JT0, JMem(jrCtx, O.CtxClocks));
  J.Alu(jaAdd, jw64, JT0, JImm(B.JitMax));
  J.BranchTo(jcAboveEq, jw64, JT0, JMem(jrCtx, O.CtxLimit), Generic);
  J.Move(jw32, JT0, JMem(jrCtx, O.CtxCount));
  J.Alu(jaAdd, jw32, JT0, JImm(B.JitSteps));
  J.BranchTo(jcGe, jw32, JT0, JMem(jrCtx, O.CtxMaxSteps), Generic);
  J.Alu(jaAdd, jw64, JMem(jrSelf, O.BlocksRun), JImm(1));
  if FJitStats then
    J.Alu(jaAdd, jw64, JMem(jrSelf, O.JitRuns), JImm(1));
  J.JumpTo(NativeInt(NativeUInt(B.NativeInner) - NativeUInt(J.Base)));
  J.Flush;
  // From's code goes here first.
  J.Redirect(From.JitTail, Start);
  From.JitLinkTo[From.JitLinks] := B;
  From.JitLinkPC[From.JitLinks] := PC;
  Inc(From.JitLinks);
end;

function TN64CPU.JitCompile(B: PN64CPUBlock; Careful: Boolean): Pointer;
begin
  Result := nil;
  // Careful: a second code for B (its first has been made) that stops
  // after any step that reaches Limit or MaxSteps, as RunBlocks's loop, for
  // where the first may not run; it chains to nothing.
  if Careful then
    B.CarefulTried := True
  else
  begin
    B.JitTried := True;
    B.Native := nil;
    B.NativeInner := nil;
    B.JitTail := -1;
    B.JitLinks := 0;
  end;
  if not FUseJit or (B.Count = 0) then
    Exit;
  // (Careful: not with a LUI pair, which RunBlocks splits where the pair
  // would not fit.)
  if Careful then
    for var I := 0 to B.Count - 1 do
      if StepOf(B, I).Kind = KindLuiPair then
        Exit;
  if JitDebug * [jdNoBranch, jdNoMem, jdNoStore, jdNoFP, jdNoLui] <> [] then
    for var I := 0 to B.Count - 1 do
    begin
      var S := StepOf(B, I);
      if ((jdNoBranch in JitDebug) and ((S.Flags and StepBranch) <> 0)) or
        ((jdNoMem in JitDebug) and (S.Size <> 0)) or
        ((jdNoStore in JitDebug) and ((S.Flags and StepStore) <> 0)) or
        ((jdNoFP in JitDebug) and (S.Kind >= KindCop1Move) and (S.Kind <> KindLuiPair)) or
        ((jdNoLui in JitDebug) and (S.Kind = KindLuiPair)) then
        Exit;
    end;
  if FJit = nil then
  begin
    if jdModel in JitDebug then
      FJit := CreateJitModel(JitBufferSize)
    else
      FJit := CreateJitAsm(JitBufferSize);
    if FJit = nil then
    begin
      FUseJit := False;
      Exit;
    end;
    // (Fields the code uses often past the others: the GPRs, the counts and
    // the routines it calls.)
    FJit.AddWindow(JitOff.BlocksRun);
    FJit.AddWindow(JitOff.GPR);
    FJit.AddWindow(JitOff.Calls);
    for var K := 0 to 255 do
      FJitCalls[K] := FStepRoutines[K];
    FJitCalls[JitCallData] := @TN64CPU.JitData;
    FJitCalls[JitCallFP] := @TN64CPU.JitFP;
  end;
  // (Room for the block's code.)
  if not FJit.Room(4096 + B.Count * 1024) then
  begin
    FJitFull := True;
    Exit;
  end;
  if FJitChain = 0 then
    JitEmitShared;
  JitMeasure(B);

  var J := FJit;
  var O := JitOff;
  J.ForgetLabels;
  FJitExitCount := 0;
  FJitSlowCount := 0;
  J.Align(16);
  JitMark(1000);
  // Entered with Self, Ctx and the frame as set (the shared entry, the
  // chaining code, a direct link), the block in T1: Block the block, Entry
  // its PC; S4 where there is one its steps. (Ctx's Block and BlockPC are
  // written on the way out.)
  Result := J.Here;
  if not Careful then
    B.NativeInner := J.Here;
  J.Move(jw64, JBlock, JT1);
  J.Move(jw64, JEntry, JMem(jrSelf, O.PC));
  if J.Has(jrS4) then
    J.Move(jw64, JS4, JMem(jrBlock, O.BSteps));
  J.Move(jw32, JExtra, JImm(0));
  // Store: the store before, if a step may stall behind it.
  var State := Default(TJitStepState);
  var First := StepOf(B, 0);
  if (First.Size <> 0) and ((First.Flags and StepMemoryHazard) <> 0) then
    J.Move(jw8, JStore, JMem(jrSelf, O.PrevStore))
  else
  begin
    J.Move(jw32, JStore, JImm(0));
    State.StoreZero := True;
  end;
  // (A block entered in a delay slot: its step is one.)
  State.PrevBranch := (B.Mode and ModeDelay) <> 0;
  for var I := 0 to B.Count - 1 do
    JitEmitStep(B, I, Careful, State);
  JitEmitEnd(B, Careful);
  JitEmitReturn(B, Careful or (jdNoChain in JitDebug));
  J.ForgetLabels;
  J.Flush;
  Inc(FJitCompiled);
end;

procedure TN64CPU.JitEmitStep(B: PN64CPUBlock; I: Integer; Careful: Boolean; var State: TJitStepState);
begin
  // Block B's step I as RunBlocks's loop runs it (but the bookkeeping no
  // step reads).
  var J := FJit;
  var O := JitOff;
  var S := StepOf(B, I);
  var Kind := Integer(S.Kind);
  var IsStore := (S.Flags and StepStore) <> 0;
  var IsFP := Kind in [KindCop1Compare, KindCop1Arith];
  var StepArg := JitStepArg(B, I);
  JitMark(3000 + Kind);

  // Before the step's bookkeeping: its data access or FP operands.
  if S.Size <> 0 then
  begin
    var Stall := ((S.Flags and StepMemoryHazard) <> 0) and ((I = 0) or State.PrevStore);
    JitEmitData(B, I, Stall or IsStore);
    // A cached store before stalls a cached access that needs it.
    if Stall then
    begin
      J.Move(jw8, JT0, JMem(jrCtx, O.CtxCached));
      J.Alu(jaAnd, jw32, JT0, JStore);
      J.Alu(jaAdd, jw32, JExtra, JT0);
    end;
  end
  else if Kind = KindCop1Branch then
  begin
    // ApplyStalls: BC1 right after a compare.
    if I = 0 then
    begin
      J.Move(jw8, JT0, JMem(jrSelf, O.PrevCond));
      J.Alu(jaAdd, jw32, JExtra, JT0);
    end
    else if State.PrevCondition then
      J.Alu(jaAdd, jw32, JExtra, JImm(1));
  end
  else if IsFP then
  begin
    J.CallAt(JMem(jrSelf, O.Calls + JitCallFP * 8), [JSelf, StepArg, JCtx]);
    J.BranchTest(jcEq, jw32, JT0, JT0, JitExitTo(I, JitStatusDecline));
  end;

  // The bookkeeping a branch and its delay slot read: a delay slot's (even
  // a branch in one) as RunBlocks does it, a branch's from the PC on entry.
  var IsBranch := (S.Flags and StepBranch) <> 0;
  if IsBranch and not State.PrevBranch then
  begin
    J.Move(jw64, JT0, JEntry);
    J.Alu(jaAdd, jw64, JT0, JImm(Integer(S.Index) * 4));
    J.Move(jw64, JMem(jrSelf, O.InstrPC), JT0);
    J.Alu(jaAdd, jw64, JT0, JImm(4));
    J.Move(jw64, JMem(jrSelf, O.PC), JT0);
    J.Alu(jaAdd, jw64, JT0, JImm(4));
    J.Move(jw64, JMem(jrSelf, O.NextPC), JT0);
    J.Move(jw8, JMem(jrSelf, O.InDelay), JImm(0));
    J.Move(jw8, JMem(jrSelf, O.Delay), JImm(0));
  end
  else if State.PrevBranch then
  begin
    J.Move(jw64, JT0, JMem(jrSelf, O.PC));
    J.Move(jw64, JMem(jrSelf, O.InstrPC), JT0);
    J.Move(jw8, JT0, JMem(jrSelf, O.Delay));
    J.Move(jw8, JMem(jrSelf, O.InDelay), JT0);
    J.Move(jw8, JMem(jrSelf, O.Delay), JImm(0));
    J.Move(jw64, JT0, JMem(jrSelf, O.NextPC));
    J.Move(jw64, JMem(jrSelf, O.PC), JT0);
    J.Alu(jaAdd, jw64, JT0, JImm(4));
    J.Move(jw64, JMem(jrSelf, O.NextPC), JT0);
  end;

  // The instruction: a LUI pair as RunBlocks does it, else its routine
  // (Self, the step, its physical address, its FP inputs).
  // (Own: written out here, JitEmitOwn; never GPR[0].)
  JitMark(Kind);
  var Own := False;
  if Kind = KindLuiPair then
  begin
    if (Int64(S.Value) >= -Int64($80000000)) and (Int64(S.Value) <= $7FFFFFFF) then
      J.Move(jw64, JMem(jrSelf, O.GPR + Integer(S.T) * 8), JImm(Int64(S.Value)))
    else
    begin
      J.Move(jw64, JT0, JImm(Int64(S.Value)));
      J.Move(jw64, JMem(jrSelf, O.GPR + Integer(S.T) * 8), JT0);
    end;
  end
  else if S.Size <> 0 then
    J.CallAt(JMem(jrSelf, O.Calls + Kind * 8), [JSelf, StepArg, JMem(jrCtx, O.CtxPhysical)])
  else if IsFP then
  begin
    J.CallAt(JMem(jrSelf, O.Calls + Kind * 8), [JSelf, StepArg, JImm(0), JAddr(jrCtx, O.CtxFP)]);
    J.Alu(jaAdd, jw32, JExtra, JT0);
  end
  else
  begin
    Own := not (jdCalls in JitDebug) and not IsBranch and JitEmitOwn(S);
    if not Own then
      J.CallAt(JMem(jrSelf, O.Calls + Kind * 8), [JSelf, StepArg]);
  end;
  JitMark(1003);
  if WritesR0(S) and not Own then
    J.Move(jw64, JMem(jrSelf, O.GPR), JImm(0));

  // What the next step's stall and JitRun read: the store's access.
  if IsStore then
  begin
    J.Move(jw8, JStore, JMem(jrCtx, O.CtxCached));
    State.StoreZero := False;
  end
  else if not State.StoreZero then
  begin
    J.Move(jw32, JStore, JImm(0));
    State.StoreZero := True;
  end;

  // A store into the block's own code ends it after the store: its first
  // byte from B.Physical - Size + 1 to the code's last (one unsigned
  // comparison).
  if IsStore then
  begin
    J.Move(jw32, JT0, JMem(jrCtx, O.CtxPhysical));
    J.Alu(jaSub, jw32, JT0, JImm(Int64(B.Physical) - S.Size + 1));
    J.Branch(jcBelow, jw32, JT0, JImm(Int64(B.Words) * 4 + S.Size - 1), JitExitTo(I + 1, JitStatusRewritten));
  end;

  // Careful: stop after it where RunBlocks would (not after the last: JitRun
  // checks that).
  if Careful then
  begin
    Inc(State.PrefixSteps);
    Inc(State.PrefixClk, S.Clocks);
    if Kind = KindLuiPair then
    begin
      Inc(State.PrefixSteps);
      Inc(State.PrefixClk);
    end;
    if I < B.Count - 1 then
    begin
      J.Move(jw64, JT0, JMem(jrCtx, O.CtxClocks));
      J.Alu(jaAdd, jw64, JT0, JImm(State.PrefixClk));
      J.Alu(jaAdd, jw64, JT0, JExtra);
      J.Branch(jcAboveEq, jw64, JT0, JMem(jrCtx, O.CtxLimit), JitExitTo(I + 1, JitStatusStopped));
      J.Move(jw32, JT0, JMem(jrCtx, O.CtxCount));
      J.Alu(jaAdd, jw32, JT0, JImm(State.PrefixSteps));
      J.Branch(jcGe, jw32, JT0, JMem(jrCtx, O.CtxMaxSteps), JitExitTo(I + 1, JitStatusStopped));
    end;
  end;

  State.PrevBranch := IsBranch;
  State.PrevStore := IsStore;
  State.PrevCondition := (S.Flags and StepCondition) <> 0;
end;

function TN64CPU.JitStepArg(B: PN64CPUBlock; I: Integer): TJitOp;
begin
  // Step I's address as a call's argument (from S4 where there is one).
  if FJit.Has(jrS4) then
    Result := JAddr(jrS4, I * SizeOf(TN64CPUStep))
  else
    Result := JImm(Int64(NativeUInt(StepOf(B, I))));
end;

procedure TN64CPU.JitEmitData(B: PN64CPUBlock; I: Integer; NeedCached: Boolean);
begin
  // Step I's access as FastData finds it, into Ctx's Physical (and Cached
  // where NeedCached: a stall or a store reads it). Through KSEG0/KSEG1 in
  // RDRAM, aligned, where Ctx.Direct: here. Anything else asks JitData
  // after the block's steps (JitEmitReturn) and comes back; JitData
  // declining leaves the block. (N64JIT=calls: JitData for every access.)
  var J := FJit;
  var O := JitOff;
  var S := StepOf(B, I);
  var Size := Integer(S.Size);
  var Ram := FBus.RAMSize;
  if (jdCalls in JitDebug) or (Ram < $1000) or ((Ram and (Ram - 1)) <> 0) then
  begin
    J.CallAt(JMem(jrSelf, O.Calls + JitCallData * 8), [JSelf, JCtx, JitStepArg(B, I)]);
    J.BranchTest(jcEq, jw32, JT0, JT0, JitExitTo(I, JitStatusDecline));
    Exit;
  end;
  if FJitSlowCount = Length(FJitSlowLabel) then
  begin
    SetLength(FJitSlowLabel, FJitSlowCount * 2 + 64);
    SetLength(FJitSlowBack, FJitSlowCount * 2 + 64);
    SetLength(FJitSlowStep, FJitSlowCount * 2 + 64);
  end;
  var Slow := J.NewLabel;
  var Back := J.NewLabel;
  FJitSlowLabel[FJitSlowCount] := Slow;
  FJitSlowBack[FJitSlowCount] := Back;
  FJitSlowStep[FJitSlowCount] := I;
  Inc(FJitSlowCount);
  J.Move(jw8, JT1, JMem(jrCtx, O.CtxDirect));
  J.BranchTest(jcEq, jw32, JT1, JT1, Slow);
  // T0: the address; T1: it xor KSeg0Base, whose bits 63..30 are clear in
  // KSEG0/KSEG1 (bit 29 set in KSEG1), bits 28..23 too in RDRAM (8 MB or
  // what it is, a power of two), the low ones too where aligned: one test.
  J.Move(jw64, JT0, JMem(jrSelf, O.GPR + Integer(S.S) * 8));
  J.Alu(jaAdd, jw64, JT0, JImm(Int64(S.Value)));
  J.Move(jw64, JT1, JT0);
  J.Alu(jaXor, jw64, JT1, JImm(-Int64($80000000)));
  J.BranchTest(jcNe, jw64, JT1, JImm(-Int64($40000000) or Int64($1FFFFFFF and not (Ram - 1)) or (Size - 1)), Slow);
  if NeedCached then
  begin
    J.Shift(jsShr, jw32, jrT1, 29);
    J.Alu(jaXor, jw32, JT1, JImm(1));
    J.Move(jw8, JMem(jrCtx, O.CtxCached), JT1);
  end;
  J.Alu(jaAnd, jw32, JT0, JImm($1FFFFFFF));
  J.Move(jw64, JMem(jrCtx, O.CtxPhysical), JT0);
  J.Bind(Back);
end;

function TN64CPU.JitEmitOwn(S: PN64CPUStep): Boolean;
var
  J: TJitAsm;
  O: TJitOffsets;

  function G(R: Integer): TJitOp;
  begin
    Result := JMem(jrSelf, O.GPR + R * 8);
  end;

  // GPR[R] := T0's low 32 bits sign-extended (SX32).
  procedure Put32(R: Integer);
  begin
    J.SignExtend(jw32, jrT0);
    J.Move(jw64, G(R), JT0);
  end;

  // GPR[R] := Ord(GPR[S.S] Cond B), 64 bits.
  procedure SetIf(Cond: TJitCond; const B: TJitOp; R: Integer);
  begin
    var L := J.NewLabel;
    J.Move(jw64, JT1, G(S.S));
    J.Move(jw32, JT0, JImm(1));
    J.Branch(Cond, jw64, JT1, B, L);
    J.Move(jw32, JT0, JImm(0));
    J.Bind(L);
    J.Move(jw64, G(R), JT0);
  end;

  // GPR[R] := GPR[S.S] Op Src (64 bits).
  procedure Logic(Op: TJitAlu; const Src: TJitOp; R: Integer);
  begin
    J.Move(jw64, JT0, G(S.S));
    J.Alu(Op, jw64, JT0, Src);
    J.Move(jw64, G(R), JT0);
  end;

  // GPR[R] := GPR[S.T] shifted by N (32 bits sign-extended, or 64).
  procedure ShiftBy(Op: TJitShift; W: TJitWidth; N, R: Integer);
  begin
    J.Move(W, JT0, G(S.T));
    if N <> 0 then
      J.Shift(Op, W, jrT0, N);
    if W = jw32 then
      Put32(R)
    else
      J.Move(jw64, G(R), JT0);
  end;

begin
  // A step written out as host instructions, as its routine does it (GPR[0]
  // reads 0: the code keeps it so); False: not one of these (its routine is
  // called). Writing GPR[0] does nothing, so neither does the code.
  J := FJit;
  O := JitOff;
  var Kind := Integer(S.Kind);
  var D := Integer(S.D);
  var T := Integer(S.T);
  var Imm16 := Int64(S.Op and $FFFF);
  case Kind of
    KindSpecial + 17:
      begin
        J.Move(jw64, JT0, G(S.S));                                   // MTHI
        J.Move(jw64, JMem(jrSelf, O.HI), JT0);
        Exit(True);
      end;
    KindSpecial + 19:
      begin
        J.Move(jw64, JT0, G(S.S));                                   // MTLO
        J.Move(jw64, JMem(jrSelf, O.LO), JT0);
        Exit(True);
      end;
    KindSpecial + 0, KindSpecial + 2, KindSpecial + 3, KindSpecial + 16, KindSpecial + 18,
    KindSpecial + 33, KindSpecial + 35..KindSpecial + 39, KindSpecial + 42, KindSpecial + 43,
    KindSpecial + 45, KindSpecial + 47, KindSpecial + 56, KindSpecial + 58..KindSpecial + 60,
    KindSpecial + 62, KindSpecial + 63:
      if D = 0 then
        Exit(True);
    9..15:
      if T = 0 then
        Exit(True);
  else
    // (A kind whose routine does nothing: CACHE, SYNC and the like.)
    Exit(FStepRoutines[Kind] = @TN64CPU.StepNop);
  end;
  case Kind of
    KindSpecial + 0:
      ShiftBy(jsShl, jw32, S.N, D);                                  // SLL
    KindSpecial + 2:
      ShiftBy(jsShr, jw32, S.N, D);                                  // SRL
    KindSpecial + 3:
      ShiftBy(jsSar, jw32, S.N, D);                                  // SRA
    KindSpecial + 56:
      ShiftBy(jsShl, jw64, S.N, D);                                  // DSLL
    KindSpecial + 58:
      ShiftBy(jsShr, jw64, S.N, D);                                  // DSRL
    KindSpecial + 59:
      ShiftBy(jsSar, jw64, S.N, D);                                  // DSRA
    KindSpecial + 60:
      ShiftBy(jsShl, jw64, S.N + 32, D);                             // DSLL32
    KindSpecial + 62:
      ShiftBy(jsShr, jw64, S.N + 32, D);                             // DSRL32
    KindSpecial + 63:
      ShiftBy(jsSar, jw64, S.N + 32, D);                             // DSRA32
    KindSpecial + 16, KindSpecial + 18:
      begin
        if Kind = KindSpecial + 16 then                              // MFHI, MFLO
          J.Move(jw64, JT0, JMem(jrSelf, O.HI))
        else
          J.Move(jw64, JT0, JMem(jrSelf, O.LO));
        J.Move(jw64, G(D), JT0);
      end;
    KindSpecial + 33, KindSpecial + 35:
      begin
        J.Move(jw32, JT0, G(S.S));                                   // ADDU, SUBU
        if Kind = KindSpecial + 33 then
          J.Alu(jaAdd, jw32, JT0, G(T))
        else
          J.Alu(jaSub, jw32, JT0, G(T));
        Put32(D);
      end;
    KindSpecial + 45:
      Logic(jaAdd, G(T), D);                                         // DADDU
    KindSpecial + 47:
      Logic(jaSub, G(T), D);                                         // DSUBU
    KindSpecial + 36:
      Logic(jaAnd, G(T), D);                                         // AND
    KindSpecial + 37:
      if T = 0 then
      begin
        J.Move(jw64, JT0, G(S.S));                                   // OR (a move)
        J.Move(jw64, G(D), JT0);
      end
      else
        Logic(jaOr, G(T), D);
    KindSpecial + 38:
      Logic(jaXor, G(T), D);                                         // XOR
    KindSpecial + 39:
      begin
        J.Move(jw64, JT0, G(S.S));                                   // NOR
        J.Alu(jaOr, jw64, JT0, G(T));
        J.Alu(jaXor, jw64, JT0, JImm(-1));
        J.Move(jw64, G(D), JT0);
      end;
    KindSpecial + 42:
      SetIf(jcLt, G(T), D);                                          // SLT
    KindSpecial + 43:
      SetIf(jcBelow, G(T), D);                                       // SLTU
    9:
      if S.S = 0 then
        J.Move(jw64, G(T), JImm(Int64(S.Value)))                     // ADDIU (a constant)
      else
      begin
        J.Move(jw32, JT0, G(S.S));
        J.Alu(jaAdd, jw32, JT0, JImm(Int64(S.Value)));
        Put32(T);
      end;
    10:
      SetIf(jcLt, JImm(Int64(S.Value)), T);                          // SLTI
    11:
      SetIf(jcBelow, JImm(Int64(S.Value)), T);                       // SLTIU
    12:
      begin
        J.Move(jw32, JT0, G(S.S));                                   // ANDI
        J.Alu(jaAnd, jw32, JT0, JImm(Imm16));
        J.Move(jw64, G(T), JT0);
      end;
    13:
      if S.S = 0 then
        J.Move(jw64, G(T), JImm(Imm16))                              // ORI (a constant)
      else
        Logic(jaOr, JImm(Imm16), T);
    14:
      Logic(jaXor, JImm(Imm16), T);                                  // XORI
    15:
      J.Move(jw64, G(T), JImm(Int64(Integer(Cardinal(Imm16) shl 16)))); // LUI
  end;
  Result := True;
end;

procedure TN64CPU.JitEmitEnd(B: PN64CPUBlock; Careful: Boolean);
begin
  // All steps ran: the last one's pipeline state and PC, the block's count
  // and PClocks into the totals; then the next block.
  var J := FJit;
  var O := JitOff;
  JitMark(1004);
  var Last := StepOf(B, B.Count - 1);
  J.Move(jw32, JMem(jrSelf, O.PrevLoad), JImm(Last.LoadAfter));
  J.Move(jw32, JMem(jrSelf, O.PrevFP), JImm(Last.FPAfter));
  J.Move(jw8, JMem(jrSelf, O.PrevCond), JImm(Ord((Last.Flags and StepCondition) <> 0)));
  J.Move(jw8, JMem(jrSelf, O.PrevExc), JImm(0));
  if (Last.Flags and StepStore) <> 0 then
    J.Move(jw8, JMem(jrSelf, O.PrevStore), JStore)
  else
    J.Move(jw8, JMem(jrSelf, O.PrevStore), JImm(0));
  if not StepWritesPC(B, B.Count - 1) then
  begin
    var Words := 1;
    if Last.Kind = KindLuiPair then
      Words := 2;
    J.Move(jw64, JT0, JEntry);
    J.Alu(jaAdd, jw64, JT0, JImm((Integer(Last.Index) + Words - 1) * 4));
    J.Move(jw64, JMem(jrSelf, O.InstrPC), JT0);
    J.Alu(jaAdd, jw64, JT0, JImm(4));
    J.Move(jw64, JMem(jrSelf, O.PC), JT0);
    J.Alu(jaAdd, jw64, JT0, JImm(4));
    J.Move(jw64, JMem(jrSelf, O.NextPC), JT0);
    J.Move(jw8, JMem(jrSelf, O.InDelay), JImm(0));
    J.Move(jw8, JMem(jrSelf, O.Delay), JImm(0));
  end;
  J.Alu(jaAdd, jw32, JMem(jrCtx, O.CtxCount), JImm(B.JitSteps));
  J.Move(jw64, JT0, JMem(jrCtx, O.CtxClocks));
  J.Alu(jaAdd, jw64, JT0, JImm(B.JitClocks));
  J.Alu(jaAdd, jw64, JT0, JExtra);
  J.Move(jw64, JMem(jrCtx, O.CtxClocks), JT0);

  // The next block: by the shared chaining code (JitEmitChain), whose jump
  // JitLink points to direct links it adds. (Careful code, N64JIT=nochain:
  // back to RunBlocks.)
  if not Careful and not (jdNoChain in JitDebug) then
    if (Last.Flags and StepMayIdle) <> 0 then
      B.JitTail := J.JumpSite(FJitChainIdle)
    else
      B.JitTail := J.JumpSite(FJitChain);
end;

procedure TN64CPU.JitEmitReturn(B: PN64CPUBlock; FallThrough: Boolean);
begin
  // Back to RunBlocks by the shared way (JitEmitShared), T1 the steps done
  // shl 2 or the status: from the end where the last step falls through to
  // here (status 0); the data accesses the steps' own checks did not take
  // (JitData, back into the steps); then the exits (declines, stops,
  // rewrites).
  var J := FJit;
  var O := JitOff;
  JitMark(1005);
  if FallThrough then
  begin
    J.Move(jw32, JT1, JImm(B.Count shl 2 or JitStatusDone));
    J.JumpTo(FJitReturn);
  end;
  for var K := 0 to FJitSlowCount - 1 do
  begin
    J.Bind(FJitSlowLabel[K]);
    J.CallAt(JMem(jrSelf, O.Calls + JitCallData * 8), [JSelf, JCtx, JitStepArg(B, FJitSlowStep[K])]);
    J.BranchTest(jcEq, jw32, JT0, JT0, JitExitTo(FJitSlowStep[K], JitStatusDecline));
    J.Jump(FJitSlowBack[K]);
  end;
  for var Status in JitExitOrder do
    for var K := 0 to FJitExitCount - 1 do
      if FJitExitStatus[K] = Status then
      begin
        J.Bind(FJitExitLabel[K]);
        J.Move(jw32, JT1, JImm(FJitExitDone[K] shl 2 or Status));
        J.JumpTo(FJitReturn);
      end;
end;

function TN64CPU.JitRun(Code: Pointer; var B: PN64CPUBlock; var PC: UInt64; Limit: UInt64; MaxSteps: Integer;
  var Count: Integer; var Clocks: UInt64; var Jit: TJitCtx): Integer;
begin
  // B's code from its first step and the blocks it chains to (RunBlocks
  // checked that B's steps cannot reach Limit or MaxSteps; the code checks
  // that for the others). Then what RunBlocks's loop does for the last step
  // that ran: B and PC become the last block's; Count and Clocks (RunBlocks's
  // Result and Clocks) include its steps; its pipeline state and PC where the
  // code did not write them; the stop checks. Returns 0: go on after the
  // block, 1: stop (RunBlocks sets Stop), 2: the block wrote its own code.
  Result := 0;
  Inc(FJitRuns);
  Jit.Count := Count;
  Jit.Clocks := Clocks;
  Jit.Limit := Limit;
  Jit.MaxSteps := MaxSteps;
  Jit.Kernel := KernelMode;
  // (FastData's KSEG0/KSEG1 checks that hold for the whole batch.)
  Jit.Direct := (((Jit.Context and 6) <> 0) or ((Jit.Context and $18) = 0)) and FBus.SPIdle;
  var Status := Integer(FJit.Invoke(FJit.Base + FJitEnter, NativeUInt(Self), NativeUInt(@Jit), NativeUInt(Code), NativeUInt(B)));
  B := Jit.Block;
  PC := Jit.BlockPC;
  Count := Jit.Count;
  Clocks := Jit.Clocks;
  var Done := Jit.Done;
  if Status <> 0 then
  begin
    // Part of the last block: its steps up to Done (the code added none).
    if Done > 0 then
    begin
      Inc(Count, Done);
      var Clk := Jit.Extra;
      for var I := 0 to Done - 1 do
      begin
        var T := StepOf(B, I);
        Inc(Clk, T.Clocks);
        if T.Kind = KindLuiPair then
        begin
          Inc(Count);
          Inc(Clk);
        end;
      end;
      Inc(Clocks, Clk);
      var S := StepOf(B, Done - 1);
      FPreviousLoad := S.LoadAfter;
      FPreviousFP := S.FPAfter;
      FPreviousCondition := (S.Flags and StepCondition) <> 0;
      FPreviousException := False;
      FPreviousStore := ((S.Flags and StepStore) <> 0) and Jit.PrevStore;
      var Words := 1;
      if S.Kind = KindLuiPair then
        Words := 2;
      var Branchy := StepWritesPC(B, Done - 1);
      if not Branchy then
      begin
        FInstructionPC := Add64(PC, Cardinal(S.Index + Words - 1) * 4);
        FInDelay := False;
        FDelay := False;
        FPC := Add64(PC, Cardinal(S.Index + Words) * 4);
        FNextPC := Add64(FPC, 4);
      end;
    end;
    if Status = 1 then
    begin
      // Declined before step Done, as RunBlocks's loop.
      FSlowSafe := True;
      Exit(1);
    end;
  end
  else
    Done := B.Count;
  // The stop checks after the last step that ran.
  var S := StepOf(B, Done - 1);
  if (Clocks >= Limit) or (Count >= MaxSteps) or (((S.Flags and StepMayIdle) <> 0) and IdleHead) then
  begin
    if Done < B.Count then
    begin
      FResumeBlock := B;
      FResumeStep := Done;
      FResumePC := FPC;
      FCarryGen := FBlockGen;
    end
    else
    begin
      FLastBlock := B;
      FLastEnd := Add64(PC, Cardinal(B.Words) * 4);
      FCarryGen := FBlockGen;
    end;
    Exit(1);
  end;
  if Status = 2 then
    Result := 2;
end;

function TN64CPU.RunBlocks(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
begin
  var FP: TStepFP;
  var Jit: TJitCtx;
  // FastRun's steps (after FastReady), exactly as it takes them, from blocks:
  // at most MaxSteps, up to the one that brings their PClocks to Limit or
  // more or after which IdleLimit may find an idle loop's head, or before
  // one FastRun would not take (FSlowSafe as it leaves it). FPlainNext: it
  // stopped where FastRun could go on (no block there: RDP work queued on
  // the code page, or an unusual PC). COUNT and Random updates at the end.
  Result := 0;
  // (Clocks at the end.)
  var Clk: UInt64 := 0;
  FPlainNext := False;
  var Status := CP0[12];
  var Cop1Usable := (Status and $20000000) <> 0;
  var Mode := Integer((Status shr 3) and 3);
  if (Status and 6) <> 0 then
    Mode := 0;
  var WideOK := (Mode = 0) or ((Status and (UInt64($80) shr Mode)) <> 0);
  var BaseMode: Byte := 0;
  if Cop1Usable then
    BaseMode := ModeCop1;
  if WideOK then
    BaseMode := BaseMode or ModeWide;
  if (Status and $4000000) <> 0 then
    BaseMode := BaseMode or ModeFR;
  var CodeClean := False;
  // The block before (it ran to its end) and which of its links applies.
  var Prev: PN64CPUBlock := nil;
  var PrevEnd: UInt64 := 0;
  // A block the last call stopped within, and the step it stopped before.
  var ResumeBlock: PN64CPUBlock := nil;
  var ResumeStep := 0;
  if FCarryGen = FBlockGen then
  begin
    if (FResumeBlock <> nil) and (FResumePC = FPC) then
    begin
      ResumeBlock := FResumeBlock;
      ResumeStep := FResumeStep;
    end
    else if FLastBlock <> nil then
    begin
      Prev := FLastBlock;
      PrevEnd := FLastEnd;
    end;
  end;
  FLastBlock := nil;
  FResumeBlock := nil;
  var Stop := False;
  var Rewritten := False;
  var FarFrom: PN64CPUBlock;
  while (Result < MaxSteps) and not Stop do
  begin
    FSlowSafe := False;
    FarFrom := nil;
    var PC := FPC;
    if ((PC and 3) <> 0) or (not FDelay and (FNextPC <> Add64(PC, 4))) then
    begin
      FPlainNext := True;
      Break;
    end;
    if not FFastCodeValid or (FFastCodePage <> (PC shr 12)) or (FFastCodeContext <> Context) or
      (FFastCodeGeneration <> FTLBGeneration) then
    begin
      if not FastCode(PC, Context) then
        Break;
      CodeClean := False;
      // (Blocks as generated code: the block before, for its far link.)
      FarFrom := Prev;
      Prev := nil;
      ResumeBlock := nil;
    end;
    if not CodeClean then
    begin
      // Not on a page SP DMA beats that may have waited write (Fetch runs
      // them first): neither block nor FastRun.
      if FBus.SPReadHazard(FFastCodePhysical) then
        Break;
      CodeClean := FBus.RDPReadClean(FFastCodePhysical);
      if not CodeClean then
      begin
        FPlainNext := True;
        Break;
      end;
    end;
    var Physical := FFastCodePhysical or Cardinal(PC and $FFF);
    var BlockMode := BaseMode;
    if FDelay then
      BlockMode := BlockMode or ModeDelay;
    var B: PN64CPUBlock := nil;
    var First := 0;
    if ResumeBlock <> nil then
    begin
      // Within the block where the last call stopped: the rest of its steps,
      // if they hold as they are (the same place and mode, the hazards its
      // step before left, a delay slot where it has one, its code unchanged).
      // Only the next call resumes, and anything run in between moves the
      // PC: the hazard and delay slot tests are guards.
      var R := StepOf(ResumeBlock, ResumeStep);
      var Before := StepOf(ResumeBlock, ResumeStep - 1);
      if (ResumeBlock.Mode = BaseMode) and (Physical = ResumeBlock.Physical + Cardinal(R.Index) * 4) and
        (FPreviousLoad = Before.LoadAfter) and (FPreviousFP = Before.FPAfter) and
        (FDelay = ((Before.Flags and StepBranch) <> 0)) and BlockValid(ResumeBlock) then
      begin
        B := ResumeBlock;
        First := ResumeStep;
        // (Where the block starts, for its end.)
        PC := Sub64(PC, Cardinal(R.Index) * 4);
      end;
      ResumeBlock := nil;
    end;
    var Taken := Ord(PC <> PrevEnd);
    // (Blocks as generated code: the block before, for a direct link, while no
    // block was dropped.)
    var LinkFrom := Prev;
    var LinkGen := FBlockGen;
    if (B = nil) and (Prev <> nil) then
    begin
      // (The entry hazards after Prev follow from Prev and the way it left;
      // compared as a guard.)
      B := Prev.Link[Taken];
      if (B <> nil) and ((Prev.LinkPC[Taken] <> PC) or (B.Mode <> BlockMode) or (B.EntryLoad <> FPreviousLoad) or
        (B.EntryFP <> FPreviousFP) or not BlockValid(B)) then
        B := nil;
    end;
    if B = nil then
    begin
      var Gen := FBlockGen;
      B := BlockKey(FPreviousLoad, FPreviousFP, BlockMode, Physical);
      if B = nil then
        B := BuildBlock(PC, Physical, BlockMode);
      if (Prev <> nil) and (FBlockGen = Gen) then
      begin
        Prev.Link[Taken] := B;
        Prev.LinkPC[Taken] := PC;
      end;
      // Entered from a block on another page that ran to its end: its far
      // link (its code checks the page as FastCode does).
      if (FarFrom <> nil) and (FBlockGen = Gen) then
      begin
        FarFrom.Far[1] := FarFrom.Far[0];
        FarFrom.FarPC[1] := FarFrom.FarPC[0];
        FarFrom.Far[0] := B;
        FarFrom.FarPC[0] := PC;
      end;
    end;
    if B.Count = 0 then
    begin
      FSlowSafe := B.SlowSafe;
      if FJitStats then
      begin
        var W := B.Code^;
        var K := Integer(W shr 26);
        if K = 0 then
          K := 64 + (W and 63)
        else if K in [16..18] then
          K := 128 + (K - 16) * 32 + Integer((W shr 21) and 31);
        Inc(FJitSlowOps[K and 255]);
      end;
      Break;
    end;
    Inc(FBlocksRun);
    var Step := StepOf(B, First);
    var Last := StepOf(B, B.Count - 1);
    // As generated code, from its first step, where its steps cannot reach
    // Limit or MaxSteps before the last (JitRun does the rest).
    var Native := False;
    if (First = 0) and FUseJit then
    begin
      if not B.JitTried and (B.JitHeat < JitHot) then
        Inc(B.JitHeat)
      else if not B.JitTried then
      begin
        var T0: Int64 := 0;
        if FJitStats then
          T0 := JitTicks;
        B.Native := JitCompile(B);
        if FJitStats then
          Inc(FJitCompileTicks, JitTicks - T0);
      end;
      if (LinkFrom <> nil) and (LinkGen = FBlockGen) and (B.Native <> nil) and (LinkFrom.Native <> nil) and
        (LinkFrom.JitLinks < Length(LinkFrom.JitLinkTo)) then
        JitLink(LinkFrom, B, PC);
      // Its code where its steps cannot reach Limit or MaxSteps before the
      // last; else its careful code.
      var Code: Pointer := nil;
      if B.Native <> nil then
        if (Clk + B.JitMax < Limit) and (Result + Integer(B.JitSteps) < MaxSteps) then
          Code := B.Native
        else
        begin
          if not B.CarefulTried and (B.CarefulHeat < JitHot) then
            Inc(B.CarefulHeat)
          else if not B.CarefulTried then
            B.NativeCareful := JitCompile(B, True);
          Code := B.NativeCareful;
        end;
      if Code <> nil then
      begin
        Native := True;
        Jit.Context := Context;
        case JitRun(Code, B, PC, Limit, MaxSteps, Result, Clk, Jit) of
          1:
            Stop := True;
          2:
            Rewritten := True;
        end;
      end;
    end;
    if not Native then
    while True do
    begin
      var C: Cardinal := Step.Clocks;
      var Physical2: Cardinal := 0;
      var Cached := False;
      var Kind := Step.Kind;
      if Step.Size <> 0 then
      begin
        if not FastData(Add64(GPR[Step.S], Step.Value), Step.Size, (Step.Flags and StepWriting) <> 0, Context,
          Physical2, Cached) then
        begin
          FSlowSafe := True;
          Stop := True;
          Break;
        end;
        if FPreviousStore and ((Step.Flags and StepMemoryHazard) <> 0) and Cached then
          Inc(C);
      end
      else if Kind >= KindCop1Arith then
      begin
        if Kind = KindLuiPair then
        begin
          // Room for both (else the LUI alone, as FastRun ends after it).
          if (Clk + 1 >= Limit) or (Result + 1 >= MaxSteps) then
            Kind := 15;
        end
        else if Kind = KindCop1Branch then
        begin
          // ApplyStalls: BC1 right after a compare.
          if FPreviousCondition then
            Inc(C);
        end
        else if Kind <> KindCop1Mov then
        begin
          var F := Integer(Step.S);
          // FR is fixed for this batch. A unary operation/conversion never
          // consumes FT; a compare and arithmetic 0..3 do.
          var Binary := (Kind = KindCop1Compare) or ((Step.Op and 63) <= 3);
          FP.B := 0;
          if (BaseMode and ModeFR) <> 0 then
          begin
            FP.A := FPR[Step.D];
            if Binary then FP.B := FPR[Step.T];
            if F in [16, 20] then
            begin FP.A := FP.A and $FFFFFFFF; FP.B := FP.B and $FFFFFFFF end;
          end
          else
          begin
            FP.A := FPBits(Integer(Step.D), F);
            if Binary then FP.B := FPBits(Integer(Step.T), F);
          end;
          if Kind = KindCop1Compare then
          begin
            if SFIsNaN(FP.A, F) or SFIsNaN(FP.B, F) then
            begin
              FSlowSafe := True;
              Stop := True;
              Break;
            end;
          end
          else if not FastFloat(Step.Op, FP.A, FP.B, FP.Res, FP.Cycles, FP.Target) then
          begin
            FSlowSafe := True;
            Stop := True;
            Break;
          end;
        end;
      end;
      // Its hazards for the next one, then the instruction.
      FPreviousLoad := Step.LoadAfter;
      FPreviousFP := Step.FPAfter;
      FPreviousCondition := (Step.Flags and StepCondition) <> 0;
      FPreviousException := False;
      FPreviousStore := ((Step.Flags and StepStore) <> 0) and Cached;
      FInstructionPC := FPC;
      FInDelay := FDelay;
      FDelay := False;
      FPC := FNextPC;
      FNextPC := Add64(FNextPC, 4);
      if Kind = KindLuiPair then
      begin
        // The ORI/ADDIU after the LUI: its Step as FastRun takes it.
        Inc(Result);
        Inc(Clk);
        FInstructionPC := FPC;
        FInDelay := False;
        FPC := FNextPC;
        FNextPC := Add64(FNextPC, 4);
        GPR[Step.T] := Step.Value;
      end
      else
      begin
        Inc(C, TStepRoutine(FStepRoutines[Kind])(Self, Step, Physical2, @FP));
        // A canonical NOP after successful arithmetic has no reads or
        // side effects beyond its PC, one clock and clearing FP hazards.
        // Retain the decoded NOP for exact budget/resume boundaries.
        if (Kind = KindCop1Arith) and (Step <> Last) and (Clk + C < Limit) and (Result + 1 < MaxSteps) then
        begin
          var Tail := PN64CPUStep(NativeUInt(Step) + SizeOf(TN64CPUStep));
          if (Tail.Op = 0) and (Tail.Flags = 0) and (Tail.Clocks = 1) then
          begin
            Inc(Result);
            Inc(C);
            Step := Tail;
            FPreviousFP := -1;
            FInstructionPC := FPC;
            FInDelay := False;
            FPC := FNextPC;
            FNextPC := Add64(FNextPC, 4);
          end;
        end;
      end;
      // (47, CACHE: nothing.)
      GPR[0] := 0;
      Inc(Result);
      Inc(Clk, C);
      if (Clk >= Limit) or (Result >= MaxSteps) or (((Step.Flags and StepMayIdle) <> 0) and IdleHead) then
      begin
        Stop := True;
        // The next call may go on here.
        if Step <> Last then
        begin
          FResumeBlock := B;
          FResumeStep := (NativeUInt(Step) - NativeUInt(B.Steps)) div SizeOf(TN64CPUStep) + 1;
          FResumePC := FPC;
          FCarryGen := FBlockGen;
        end
        else
        begin
          FLastBlock := B;
          FLastEnd := Add64(PC, Cardinal(B.Words) * 4);
          FCarryGen := FBlockGen;
        end;
        Break;
      end;
      // A store into this block's own code: the steps after it are no
      // longer what is there (the next block is checked as it is entered).
      if ((Step.Flags and StepStore) <> 0) and (Physical2 < B.Physical + Cardinal(B.Words) * 4) and
        (Physical2 + Step.Size > B.Physical) then
      begin
        Rewritten := True;
        Break;
      end;
      if Step = Last then
        Break;
      Inc(Step);
    end;
    if Stop then
      Break;
    // It ran to its end: the next one, by link if it came before.
    Prev := B;
    PrevEnd := Add64(PC, Cardinal(B.Words) * 4);
    if Rewritten then
    begin
      Prev := nil;
      Rewritten := False;
    end;
  end;
  Clocks := Clk;
  FastFlush(Cardinal(Clk), Result);
end;

function TN64CPU.RunBatch(MaxSteps: Integer; Budget: UInt64; out Cycles: UInt64): Integer;
begin
  Result := 0;
  var Elapsed: UInt64 := 0;
  FBatchElapsed := 0;
  FBatchDevice := False;
  FBatching := True;
  try
    // Ready: what FastReady checks holds, until a Step that may change it or
    // COUNT reaching COMPARE (UntilCompare PClocks on).
    var Ready := False;
    var Context: Cardinal := 0;
    var UntilCompare: UInt64 := 0;
    while Result < MaxSteps do
    begin
      if not Ready then
        Ready := FastReady(Context, UntilCompare);
      if Ready then
      begin
        var Limit := Budget - Elapsed;
        if UntilCompare < Limit then
          Limit := UntilCompare;
        var Clocks: UInt64;
        var N: Integer;
        if FUseBlocks then
        begin
          // From blocks; where none can run (RDP work queued on the code
          // page), FastRun takes over.
          N := RunBlocks(MaxSteps - Result, Limit, Context, Clocks);
          if FPlainNext and (Result + N < MaxSteps) and (Clocks < Limit) then
          begin
            var More: UInt64;
            Inc(N, FastRun(MaxSteps - Result - N, Limit - Clocks, Context, More));
            Inc(Clocks, More);
          end;
        end
        else
          N := FastRun(MaxSteps - Result, Limit, Context, Clocks);
        Inc(Result, N);
        Inc(Elapsed, Clocks);
        if N > 0 then
        begin
          if Clocks >= UntilCompare then
            Ready := False
          else
            Dec(UntilCompare, Clocks);
          if (Elapsed >= Budget) or (Result >= MaxSteps) or IdleHead then
            Break;
          if not Ready then
            Continue;
        end;
      end;
      // A full Step: of the instruction FastRun stopped before, or of any one
      // when not Ready.
      FBatchElapsed := Elapsed;
      FBatchDevice := False;
      Step;
      var C := FCyclesConsumed;
      // Still ready after an instruction that changed no COP0 register, no
      // TLB entry and not the interrupt line (no COP0 instruction, fault or
      // device access), if COUNT has not reached COMPARE.
      Ready := Ready and FSlowSafe and not FPreviousException and not FBatchDevice and (C < UntilCompare);
      if Ready then
        Dec(UntilCompare, C);
      Inc(Result);
      Inc(Elapsed, C);
      if FBatchDevice or (Elapsed >= Budget) or IdleHead then
        Break;
    end;
  finally
    FBatching := False;
  end;
  Cycles := Elapsed;
end;

procedure TN64CPU.ExecuteInstruction;
begin
  // Kept out of Step's exception frame so its locals can stay in registers.
  if FBus.InterruptLine then
    CP0[13] := CP0[13] or $400
  else
    CP0[13] := CP0[13] and not UInt64($400);
  if ((CP0[12] and 7) = 1) and ((CP0[12] and CP0[13] and $FF00) <> 0) then
    Fault(0);
  var Op := Fetch;
  if FBus.TraceEnabled then
    FBus.Trace(Instruction, FPC, FPC, Op);
  FExecutingInstruction := True;
  ApplyInterlocks(Op);
  FPC := FNextPC;
  FNextPC := Add64(FNextPC, 4);
  var Code := Op shr 26;
  var T := (Op shr 16) and 31;
  var A := GPR[(Op shr 21) and 31];
  var B := GPR[T];
  var Imm := SX16(Op);
  var V: UInt64;
  case Code of
    0:
      Special(Op);
    1:
      begin
        var Target := Add64(FPC, Imm shl 2);
        var Taken := SignedLess(A, 0);
        if (T and 1) <> 0 then
          Taken := not Taken;
        if T in [16..19] then
          GPR[31] := Add64(FInstructionPC, 8);
        if T in [0..3, 16..19] then
          Branch(Taken, (T and 2) <> 0, Target)
        else
          case T of
            8:
              if not SignedLess(A, Imm) then
                Fault(13);
            9:
              if A >= Imm then
                Fault(13);
            10:
              if SignedLess(A, Imm) then
                Fault(13);
            11:
              if A < Imm then
                Fault(13);
            12:
              if A = Imm then
                Fault(13);
            14:
              if A <> Imm then
                Fault(13);
          else
            Fault(10);
          end;
      end;
    2, 3:
      begin
        if Code = 3 then
          GPR[31] := Add64(FInstructionPC, 8);
        Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Op and $3FFFFFF) shl 2));
      end;
    4, 20:
      Branch(A = B, Code = 20, Add64(FPC, Imm shl 2));
    5, 21:
      Branch(A <> B, Code = 21, Add64(FPC, Imm shl 2));
    6, 22:
      Branch(not SignedLess(0, A), Code = 22, Add64(FPC, Imm shl 2));
    7, 23:
      Branch(SignedLess(0, A), Code = 23, Add64(FPC, Imm shl 2));
    9:
      GPR[T] := SX32(Add64(A, Imm));
    8, 24, 25:
      begin
        V := Add64(A, Imm);
        if Code = 8 then
          V := SX32(V);
        if Code = 8 then
          if (((not (A xor Imm)) and (A xor V)) and $80000000) <> 0 then
            Fault(12);
        if Code = 24 then
          if ((not (A xor Imm)) and (A xor V)) shr 63 <> 0 then
            Fault(12);
        GPR[T] := V;
      end;
    10:
      GPR[T] := Ord(SignedLess(A, Imm));
    11:
      GPR[T] := Ord(A < Imm);
    12:
      GPR[T] := A and (Op and $FFFF);
    13:
      GPR[T] := A or (Op and $FFFF);
    14:
      GPR[T] := A xor (Op and $FFFF);
    15:
      GPR[T] := SX32((Op and $FFFF) shl 16);
    16:
      Cop0(Op);
    17:
      Cop1(Op);
    18:
      Cop2(Op);
    32:
      GPR[T] := SX8(Load(Add64(A, Imm), 1));
    33:
      GPR[T] := SX16(Load(Add64(A, Imm), 2));
    35:
      GPR[T] := SX32(Load(Add64(A, Imm), 4));
    36:
      GPR[T] := Load(Add64(A, Imm), 1);
    37:
      GPR[T] := Load(Add64(A, Imm), 2);
    39:
      GPR[T] := Load(Add64(A, Imm), 4);
    55:
      GPR[T] := Load(Add64(A, Imm), 8);
    26, 27, 34, 38:
      begin
        var Address := Add64(A, Imm);
        var Size := 4;
        if Code in [26, 27] then
          Size := 8;
        var Offset := Integer(Address and Cardinal(Size - 1));
        var Base := Address and not UInt64(Size - 1);
        V := B;
        for var I := 0 to Size - 1 do
        begin
          var Pos := I;
          var J := I;
          if Code in [26, 34] then
            J := I + Offset
          else
            Pos := I + Size - 1 - Offset;
          if (J < Size) and (Pos < Size) then
          begin
            var Shift := (Size - 1 - Pos) * 8;
            var M := UInt64($FF) shl Shift;
            V := (V and not M) or (Load(Add64(Base, Cardinal(J)), 1) shl Shift);
          end;
        end;
        if Size = 4 then
          V := SX32(V);
        GPR[T] := V;
      end;
    40:
      Store(Add64(A, Imm), 1, B and $FF);
    41:
      Store(Add64(A, Imm), 2, B and $FFFF);
    43:
      Store(Add64(A, Imm), 4, B and $FFFFFFFF);
    63:
      Store(Add64(A, Imm), 8, B);
    42, 44, 45, 46:
      begin
        var Address := Add64(A, Imm);
        var Size := 4;
        if Code in [44, 45] then
          Size := 8;
        var Offset := Integer(Address and Cardinal(Size - 1));
        var Base := Address and not UInt64(Size - 1);
        for var I := 0 to Size - 1 do
        begin
          var Pos := I;
          var J := I;
          if Code in [42, 44] then
            J := I + Offset
          else
            Pos := I + Size - 1 - Offset;
          if (J < Size) and (Pos < Size) then
            Store(Add64(Base, Cardinal(J)), 1, (B shr ((Size - 1 - Pos) * 8)) and $FF);
        end;
      end;
    47:
      ; // CACHE: uncached interpreter, all writes immediately visible.
      48, 52:
      begin
        var Address := Add64(A, Imm);
        if Code = 48 then
          GPR[T] := SX32(Load(Address, 4))
        else
          GPR[T] := Load(Address, 8);
        FLLAddress := Translate(Address, False);
        CP0[17] := FLLAddress shr 4;
        FLL := True;
      end;
    56, 60:
      begin
        var Address := Add64(A, Imm);
        var Size := 4;
        if Code = 60 then
          Size := 8;
        if (Address and Cardinal(Size - 1)) <> 0 then
          Fault(5, Address);
        // The store happens while LL's bit is set, wherever it goes (no
        // address is compared; only ERET clears the bit: no other store, no
        // exception).
        var Success := FLL;
        if Success then
          Store(Address, Size, B)
        else
          Translate(Address, True);
        GPR[T] := Ord(Success);
      end;
    49, 53, 57, 61:
      begin
        if (CP0[12] and $20000000) = 0 then
          Fault(11, 0, False, 1);
        var Address := Add64(A, Imm);
        if Code = 49 then
          SetFPBits(T, 16, Load(Address, 4))
        else if Code = 53 then
          SetFPBits(T, 17, Load(Address, 8))
        else if Code = 57 then
          Store(Address, 4, FPBits(T, 16))
        else
          Store(Address, 8, FPBits(T, 17));
      end;
  else
    Fault(10);
  end;
end;

function TN64CPU.IdleLimit: Integer;
begin
  // Validates a taken branch-to-self. Conditional BEQ/BNE require a NOP:
  // their operands then stay unchanged until an interrupt. Unconditional
  // loops may also use an idle counter (ADDIU/DADDIU rt, rt, imm). Every instruction of such a
  // loop takes one PClock without interlocks, faults or memory accesses.
  // Returns how many instructions may be applied before COUNT reaches
  // COMPARE, or 0 when the CPU is not at the loop head.
  Result := 0;
  if FBus.TraceEnabled then
    Exit;
  if FDelay or not FInDelay or (FPC <> Sub64(FInstructionPC, 4)) or (FNextPC <> Add64(FPC, 4)) then
    Exit;
  if ((CP0[12] and 7) = 1) and
    (((CP0[12] and CP0[13] and $FF00) <> 0) or
    (((CP0[12] and $400) <> 0) and FBus.InterruptLine)) then
    Exit;
  // Only kernel mode: privilege faults and extended mappings always step.
  if ((CP0[12] and 6) = 0) and ((CP0[12] and $18) <> 0) then
    Exit;
  var P: Cardinal;
  if not KernelFetchAddress(FPC, P) or (P > $7FFFF8) then
    Exit;
  var Op := FBus.Read32(P);
  var Unconditional := (Op = $1000FFFF) or
    (Op = ($08000000 or Cardinal((FPC shr 2) and $03FFFFFF)));
  if not Unconditional then
  begin
    // Only ordinary BEQ/BNE with offset -1: no likely/link side effects.
    // Recheck the full 64-bit predicate, including after a code rewrite.
    if ((Op and $FFFF) <> $FFFF) or not ((Op shr 26) in [4, 5]) then
      Exit;
    var Equal := GPR[(Op shr 21) and 31] = GPR[(Op shr 16) and 31];
    if Equal <> ((Op shr 26) = 4) then
      Exit;
  end;
  var Slot := FBus.Read32(P + 4);
  // A useful slot could change a branch operand on the next iteration.
  if not Unconditional and (Slot <> 0) then
    Exit;
  var Counter := Integer((Slot shr 16) and 31);
  if (Slot <> 0) and (not ((Slot shr 26) in [9, 25]) or (Counter = 0) or
    (Integer((Slot shr 21) and 31) <> Counter)) then
    Exit;
  var Wired := CP0[6] and 31;
  if (CP0[1] < Wired) or (CP0[1] > 31) then
    Exit;
  var Distance := (UInt64(CP0[11] and $FFFFFFFF) + UInt64($100000000) - (CP0[9] and $FFFFFFFF)) and $FFFFFFFF;
  if Distance = 0 then
    Distance := $100000000;
  var UntilCompare := Distance * 2 - Cardinal(FCountHalf);
  FBus.MarkCodePage(P);
  FIdleGeneration := FBus.CodeGeneration(P);
  FIdlePhysical := P;
  FIdleBranch := Op;
  FIdleSlot := Slot;
  Result := Integer(Min(UntilCompare - 1, UInt64(High(Integer))));
end;

function TN64CPU.IdleCodeIntact: Boolean;
begin
  if UInt64(FIdlePhysical) + 8 <= FBus.RAMSize then
  begin
    // The watched code page tracks every CPU/DMA/RDP write. Never trust a
    // generation while a renderer may still write it, or across two pages.
    if ((FIdlePhysical and $FFF) <= $FF8) and FBus.RDPReadClean(FIdlePhysical) and
      (FBus.CodeGeneration(FIdlePhysical) = FIdleGeneration) then
      Exit(True);
    Result := (FBus.ReadRAM32(FIdlePhysical) = FIdleBranch) and (FBus.ReadRAM32(FIdlePhysical + 4) = FIdleSlot);
    if Result then
      FIdleGeneration := FBus.CodeGeneration(FIdlePhysical);
  end
  else
    Result := (FBus.Read32(FIdlePhysical) = FIdleBranch) and (FBus.Read32(FIdlePhysical + 4) = FIdleSlot);
end;

function TN64CPU.IdleWouldInterrupt(Pending: Boolean): Boolean;
begin
  var Cause := CP0[13];
  if Pending then
    Cause := Cause or $400
  else
    Cause := Cause and not UInt64($400);
  Result := ((CP0[12] and 7) = 1) and ((CP0[12] and Cause and $FF00) <> 0);
end;

procedure TN64CPU.ApplyIdle(Count: Integer; Pending: Boolean);
begin
  // Equivalent to Count single steps from the loop head validated by IdleLimit,
  // with Count below its limit. Pending is the MI line seen by the last one.
  if Pending then
    CP0[13] := CP0[13] or $400
  else
    CP0[13] := CP0[13] and not UInt64($400);
  FCyclesConsumed := Cardinal(Count);
  AdvanceClocks(FCyclesConsumed);
  var Wired := CP0[6] and 31;
  CP0[1] := 31 - ((31 - CP0[1] + Cardinal(Count)) mod (32 - Wired));
  var Slot := FIdleSlot;
  if (Slot <> 0) and (Count >= 2) then
  begin
    // Count div 2 delay-slot executions. |Imm| <= 2^15 and Count < 2^31, so
    // the product is exact; ADDIU keeps only the sign-extended low word.
    var Counter := Integer((Slot shr 16) and 31);
    var Executions := UInt64(Count div 2);
    var Imm := SX16(Slot);
    var Value: UInt64;
    if (Imm shr 63) <> 0 then
      Value := Sub64(GPR[Counter], Executions * Sub64(0, Imm))
    else
      Value := Add64(GPR[Counter], Executions * Imm);
    if (Slot shr 26) = 9 then
      Value := SX32(Value);
    GPR[Counter] := Value;
  end;
  if Odd(Count) then
  begin
    // The branch executed last; its delay slot is next (as after Step).
    var BranchPC := FPC;
    FInstructionPC := BranchPC;
    FInDelay := False;
    FPC := Add64(BranchPC, 4);
    FNextPC := BranchPC;
    FDelay := True;
  end;
end;

function TN64CPU.SkipIdle(MaxInstructions: Integer): Integer;
begin
  Result := 0;
  FCyclesConsumed := 0;
  if MaxInstructions < 2 then
    Exit;
  var Limit := IdleLimit;
  var Skip := Min(MaxInstructions and not 1, Limit and not 1);
  if Skip <= 0 then
    Exit;
  ApplyIdle(Skip, FBus.InterruptLine);
  Result := Skip;
end;

function TN64CPU.KernelFetchAddress(Address: UInt64; out Physical: Cardinal): Boolean;
begin
  // TranslateSlow for kernel mode, without faults: False instead of an exception.
  Result := False;
  Physical := 0;
  if Address <> SX32(Address) then
    Exit;
  var Low := Cardinal(Address and $FFFFFFFF);
  if (Low >= $80000000) and (Low < $C0000000) then
    Physical := Low and $1FFFFFFF
  else if ((CP0[12] and 4) <> 0) and (Low < $80000000) then
    Physical := Low
  else
  begin
    var I := FindTLB(Address);
    if I < 0 then
      Exit;
    var Mask := UInt64(TLB[I].Mask or $1FFF);
    var HalfMask := (Mask shr 1) + 1;
    var L := TLB[I].Lo0;
    if (Address and HalfMask) <> 0 then
      L := TLB[I].Lo1;
    if (L and 2) = 0 then
      Exit;
    var Mapped := ((UInt64(L shr 6) shl 12) and not (HalfMask - 1)) or (Address and (HalfMask - 1));
    if Mapped > $FFFFFFFF then
      Exit;
    Physical := Cardinal(Mapped);
  end;
  Result := True;
end;

procedure TN64CPU.SerializeState(State: TStateArchive);

  procedure ValidateBoolean(var Value: Boolean);
  begin
    // Do not use Ord(Value): a compiler may normalize a noncanonical Boolean.
    var Raw: Byte;
    Move(Value, Raw, SizeOf(Raw));
    if Raw > 1 then
      raise EReadError.Create('Invalid N64 CPU snapshot Boolean');
  end;

begin
  State.Field(GPR, SizeOf(GPR));
  State.Field(CP0, SizeOf(CP0));
  State.Field(FPR, SizeOf(FPR));
  State.Field(FCR31, SizeOf(FCR31));
  State.Field(HI, SizeOf(HI));
  State.Field(LO, SizeOf(LO));
  State.Field(TLB, SizeOf(TLB));
  if State.Loading then
    InvalidateTLBCache;
  State.Field(FPC, SizeOf(FPC));
  State.Field(FNextPC, SizeOf(FNextPC));
  State.Field(FDelay, SizeOf(FDelay));
  State.Field(FLL, SizeOf(FLL));
  State.Field(FLLAddress, SizeOf(FLLAddress));
  State.Field(FCountHalf, SizeOf(FCountHalf));
  State.Field(FCP0Latch, SizeOf(FCP0Latch));
  State.Field(FCOP2Latch, SizeOf(FCOP2Latch));
  State.Field(FPreviousLoad, SizeOf(FPreviousLoad));
  State.Field(FPreviousFP, SizeOf(FPreviousFP));
  State.Field(FPreviousStore, SizeOf(FPreviousStore));
  State.Field(FPreviousCondition, SizeOf(FPreviousCondition));
  State.Field(FPreviousException, SizeOf(FPreviousException));
  if State.Loading then
  begin
    ValidateBoolean(FDelay);
    ValidateBoolean(FLL);
    ValidateBoolean(FPreviousStore);
    ValidateBoolean(FPreviousCondition);
    ValidateBoolean(FPreviousException);
    FInDelay := False; // Idle-loop hint is not architectural snapshot state.
    FInstructionPC := FPC;
    FExecutingInstruction := False;
    FDataCached := False;
    FCyclesConsumed := 0;
    FOperationCycles := 1;
  end;
  if State.Loading and (((FCountHalf < 0) or (FCountHalf > 1)) or
    (FPreviousLoad < -1) or (FPreviousLoad > 63) or
    (FPreviousFP < -1) or (FPreviousFP > 63)) then
    raise EReadError.Create('Invalid N64 CPU snapshot');
end;

initialization
  // Block step routines by Kind (BuildBlock's kinds; any other does nothing,
  // as CACHE).
  for var K := 0 to 255 do
    TN64CPU.FStepRoutines[K] := @TN64CPU.StepNop;
  TN64CPU.FStepRoutines[KindSpecial + 0] := @TN64CPU.StepSLL;
  TN64CPU.FStepRoutines[KindSpecial + 2] := @TN64CPU.StepSRL;
  TN64CPU.FStepRoutines[KindSpecial + 3] := @TN64CPU.StepSRA;
  TN64CPU.FStepRoutines[KindSpecial + 4] := @TN64CPU.StepSLLV;
  TN64CPU.FStepRoutines[KindSpecial + 6] := @TN64CPU.StepSRLV;
  TN64CPU.FStepRoutines[KindSpecial + 7] := @TN64CPU.StepSRAV;
  TN64CPU.FStepRoutines[KindSpecial + 8] := @TN64CPU.StepJR;
  TN64CPU.FStepRoutines[KindSpecial + 9] := @TN64CPU.StepJALR;
  TN64CPU.FStepRoutines[KindSpecial + 16] := @TN64CPU.StepMFHI;
  TN64CPU.FStepRoutines[KindSpecial + 17] := @TN64CPU.StepMTHI;
  TN64CPU.FStepRoutines[KindSpecial + 18] := @TN64CPU.StepMFLO;
  TN64CPU.FStepRoutines[KindSpecial + 19] := @TN64CPU.StepMTLO;
  TN64CPU.FStepRoutines[KindSpecial + 20] := @TN64CPU.StepDSLLV;
  TN64CPU.FStepRoutines[KindSpecial + 22] := @TN64CPU.StepDSRLV;
  TN64CPU.FStepRoutines[KindSpecial + 23] := @TN64CPU.StepDSRAV;
  TN64CPU.FStepRoutines[KindSpecial + 24] := @TN64CPU.StepMULT;
  TN64CPU.FStepRoutines[KindSpecial + 25] := @TN64CPU.StepMULTU;
  TN64CPU.FStepRoutines[KindSpecial + 26] := @TN64CPU.StepDIV;
  TN64CPU.FStepRoutines[KindSpecial + 27] := @TN64CPU.StepDIVU;
  TN64CPU.FStepRoutines[KindSpecial + 28] := @TN64CPU.StepDMULT;
  TN64CPU.FStepRoutines[KindSpecial + 29] := @TN64CPU.StepDMULTU;
  TN64CPU.FStepRoutines[KindSpecial + 30] := @TN64CPU.StepDDIV;
  TN64CPU.FStepRoutines[KindSpecial + 31] := @TN64CPU.StepDDIVU;
  TN64CPU.FStepRoutines[KindSpecial + 33] := @TN64CPU.StepADDU;
  TN64CPU.FStepRoutines[KindSpecial + 35] := @TN64CPU.StepSUBU;
  TN64CPU.FStepRoutines[KindSpecial + 36] := @TN64CPU.StepAND;
  TN64CPU.FStepRoutines[KindSpecial + 37] := @TN64CPU.StepOR;
  TN64CPU.FStepRoutines[KindSpecial + 38] := @TN64CPU.StepXOR;
  TN64CPU.FStepRoutines[KindSpecial + 39] := @TN64CPU.StepNOR;
  TN64CPU.FStepRoutines[KindSpecial + 42] := @TN64CPU.StepSLT;
  TN64CPU.FStepRoutines[KindSpecial + 43] := @TN64CPU.StepSLTU;
  TN64CPU.FStepRoutines[KindSpecial + 45] := @TN64CPU.StepDADDU;
  TN64CPU.FStepRoutines[KindSpecial + 47] := @TN64CPU.StepDSUBU;
  TN64CPU.FStepRoutines[KindSpecial + 56] := @TN64CPU.StepDSLL;
  TN64CPU.FStepRoutines[KindSpecial + 58] := @TN64CPU.StepDSRL;
  TN64CPU.FStepRoutines[KindSpecial + 59] := @TN64CPU.StepDSRA;
  TN64CPU.FStepRoutines[KindSpecial + 60] := @TN64CPU.StepDSLL32;
  TN64CPU.FStepRoutines[KindSpecial + 62] := @TN64CPU.StepDSRL32;
  TN64CPU.FStepRoutines[KindSpecial + 63] := @TN64CPU.StepDSRA32;
  TN64CPU.FStepRoutines[1] := @TN64CPU.StepRegimm;
  TN64CPU.FStepRoutines[2] := @TN64CPU.StepJ;
  TN64CPU.FStepRoutines[3] := @TN64CPU.StepJAL;
  TN64CPU.FStepRoutines[4] := @TN64CPU.StepBEQ;
  TN64CPU.FStepRoutines[20] := @TN64CPU.StepBEQL;
  TN64CPU.FStepRoutines[5] := @TN64CPU.StepBNE;
  TN64CPU.FStepRoutines[21] := @TN64CPU.StepBNEL;
  TN64CPU.FStepRoutines[6] := @TN64CPU.StepBLEZ;
  TN64CPU.FStepRoutines[22] := @TN64CPU.StepBLEZL;
  TN64CPU.FStepRoutines[7] := @TN64CPU.StepBGTZ;
  TN64CPU.FStepRoutines[23] := @TN64CPU.StepBGTZL;
  TN64CPU.FStepRoutines[9] := @TN64CPU.StepADDIU;
  TN64CPU.FStepRoutines[10] := @TN64CPU.StepSLTI;
  TN64CPU.FStepRoutines[11] := @TN64CPU.StepSLTIU;
  TN64CPU.FStepRoutines[12] := @TN64CPU.StepANDI;
  TN64CPU.FStepRoutines[13] := @TN64CPU.StepORI;
  TN64CPU.FStepRoutines[14] := @TN64CPU.StepXORI;
  TN64CPU.FStepRoutines[15] := @TN64CPU.StepLUI;
  TN64CPU.FStepRoutines[32] := @TN64CPU.StepLB;
  TN64CPU.FStepRoutines[33] := @TN64CPU.StepLH;
  TN64CPU.FStepRoutines[35] := @TN64CPU.StepLW;
  TN64CPU.FStepRoutines[36] := @TN64CPU.StepLBU;
  TN64CPU.FStepRoutines[37] := @TN64CPU.StepLHU;
  TN64CPU.FStepRoutines[39] := @TN64CPU.StepLWU;
  TN64CPU.FStepRoutines[49] := @TN64CPU.StepLWC1;
  TN64CPU.FStepRoutines[53] := @TN64CPU.StepLDC1;
  TN64CPU.FStepRoutines[55] := @TN64CPU.StepLD;
  TN64CPU.FStepRoutines[40] := @TN64CPU.StepSB;
  TN64CPU.FStepRoutines[41] := @TN64CPU.StepSH;
  TN64CPU.FStepRoutines[43] := @TN64CPU.StepSW;
  TN64CPU.FStepRoutines[63] := @TN64CPU.StepSD;
  TN64CPU.FStepRoutines[57] := @TN64CPU.StepSWC1;
  TN64CPU.FStepRoutines[61] := @TN64CPU.StepSDC1;
  TN64CPU.FStepRoutines[KindCop1Move + 0] := @TN64CPU.StepMFC1;
  TN64CPU.FStepRoutines[KindCop1Move + 1] := @TN64CPU.StepDMFC1;
  TN64CPU.FStepRoutines[KindCop1Move + 4] := @TN64CPU.StepMTC1;
  TN64CPU.FStepRoutines[KindCop1Move + 5] := @TN64CPU.StepDMTC1;
  TN64CPU.FStepRoutines[KindCop1Compare] := @TN64CPU.StepFPCompare;
  TN64CPU.FStepRoutines[KindCop1Arith] := @TN64CPU.StepFPArith;
  TN64CPU.FStepRoutines[KindCop1Mov] := @TN64CPU.StepFPMov;
  TN64CPU.FStepRoutines[KindCop1Branch] := @TN64CPU.StepBC1;
  // N64JIT: words with or without commas between them (hot16, nochain).
  begin
    var Words := GetEnvironmentVariable('N64JIT').ToLower;
    for var D := Low(TJitDebug) to High(TJitDebug) do
      if Words.Contains(JitDebugNames[D]) then
        Include(JitDebug, D);
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
      JitHot := Min(N, 60000);
    end;
  end;
  JitWorkOutOffsets;
end.

