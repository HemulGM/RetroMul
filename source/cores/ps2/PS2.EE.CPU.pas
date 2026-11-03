unit PS2.EE.CPU;

// Emotion Engine core (Toshiba R5900): MIPS III/IV integer set with 128-bit
// GPRs and the multimedia instructions (MMI), HI1/LO1 pipeline, SA register,
// COP0 with 48-entry TLB, exceptions and interrupts, the single-precision FPU
// (COP1, not IEEE: no NaN/infinity, round toward zero, denormals as zero) and
// the COP2 transfer instructions to VU0 (TEECop2).
// Instructions are decoded once into blocks (up to a branch and its delay
// slot, the end of a 4 KiB page or an instruction that changes the machine
// state) and run through per-operation handler pointers; a block remembers its
// last two successors. Blocks are validated against write generations of
// their code pages.
// References: EE Core User's Manual, EE Core Instruction Set Manual (PS2
// Linux Kit), ps2tek. Define PS2_CHECKED for range/overflow checks.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections, Core.Snapshots, HW.JIT, PS2.Types;

const
  EEExcInterrupt = 0;
  EEExcMod = 1;
  EEExcTLBL = 2;
  EEExcTLBS = 3;
  EEExcAdEL = 4;
  EEExcAdES = 5;
  EEExcSyscall = 8;
  EEExcBreak = 9;
  EEExcReserved = 10;
  EEExcUnusable = 11;
  EEExcOverflow = 12;
  EEExcTrap = 13;

  C0Index = 0;
  C0Random = 1;
  C0EntryLo0 = 2;
  C0EntryLo1 = 3;
  C0Context = 4;
  C0PageMask = 5;
  C0Wired = 6;
  C0BadVAddr = 8;
  C0Count = 9;
  C0EntryHi = 10;
  C0Compare = 11;
  C0Status = 12;
  C0Cause = 13;
  C0EPC = 14;
  C0PRId = 15;
  C0Config = 16;
  C0BadPAddr = 23;
  C0Debug = 24;
  C0Perf = 25;
  C0TagLo = 28;
  C0TagHi = 29;
  C0ErrorEPC = 30;

  EESRIE = $00000001;
  EESREXL = $00000002;
  EESRERL = $00000004;
  EESRKSU = $00000018;
  EESRIM2 = $00000400;
  EESRIM3 = $00000800;
  EESRIM7 = $00008000;
  EESREIE = $00010000;
  EESREDI = $00020000;
  EESRBEV = $00400000;
  EECauseIP2 = $00000400;
  EECauseIP3 = $00000800;
  EECauseIP7 = $00008000;
  EECauseBD = $80000000;

  EEPageCount = $100000;

  // FCR31 flags.
  FCRCondition = $00800000;
  FCRInvalid = $00020000;
  FCRDivide = $00010000;
  FCROverflow = $00008000;
  FCRUnderflow = $00004000;
  FCRStickyInvalid = $00000040;
  FCRStickyDivide = $00000020;
  FCRStickyOverflow = $00000010;
  FCRStickyUnderflow = $00000008;

type
  TEECPU = class;

  // Physical accesses outside the direct pages (MMIO). Sizes 1, 2, 4, 8.
  TEEBus = class abstract
  public
    function Read(Address: Cardinal; Size: Integer): UInt64; virtual; abstract;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); virtual; abstract;
    procedure Read128(Address: Cardinal; out Value: TPS2Reg128); virtual;
    procedure Write128(Address: Cardinal; const Value: TPS2Reg128); virtual;
    // Host memory of physical 4 KiB page Page (nil: MMIO) and its write
    // generation counter (never nil).
    function PagePointer(Page: Cardinal; Writing: Boolean): PByte; virtual; abstract;
    function PageGeneration(Page: Cardinal): PCardinal; virtual; abstract;
    // The DMAC's CPCOND0 input for BC0F/BC0T.
    function CPCond0: Boolean; virtual;
  end;

  // VU0 as coprocessor 2: its registers and the macro instructions. The base
  // class keeps the registers only; PS2.VU executes the operations.
  TEECop2 = class
  public
    VF: array[0..31] of TPS2Reg128;
    VI: array[0..31] of Cardinal;
    // The VF registers written from outside the coprocessor's methods (the
    // EE's LQC2 and QMTC2: bit N for VF[N]) since it last cleared them.
    VFWritten: Cardinal;
    constructor Create;
    procedure Reset; virtual;
    function ReadControl(Index: Integer): Cardinal; virtual;
    procedure WriteControl(Index: Integer; Value: Cardinal); virtual;
    // A COP2 operation (bit 25 set); False: reserved instruction.
    function Execute(Op: Cardinal): Boolean; virtual;
    // Interlocked transfers wait for a running VU0 micro program.
    procedure Interlock; virtual;
    // Transfers without interlock, BC2F/BC2T and LQC2/SQC2 see a running
    // micro program as far as it can get: it runs alongside the EE.
    procedure Sync; virtual;
    // BC2F/BC2T condition.
    function Condition: Boolean; virtual;
    procedure SerializeState(State: TStateArchive); virtual;
    // The EE runs (rounding toward zero, which its operations keep) from
    // RunStarts to RunEnds.
    procedure RunStarts; virtual;
    procedure RunEnds; virtual;
    // A macro operation (Execute's Op) as generated code the EE's code may
    // call instead, with Target as its argument, while Running^ is False;
    // nil: none.
    function MacroRoutine(Op: Cardinal; out Target: Pointer; out Running: PBoolean): Pointer; virtual;
    // True while a micro program runs (the transfers' Sync and Interlock
    // then wait for it); nil: unknown (the EE's code calls the handlers).
    function RunningFlag: PBoolean; virtual;
  end;

  // Called for SYSCALL with the HLE kernel (PC is already past it), and for
  // the HLE trap instruction (opcode $3B, Index in the low 26 bits).
  TEESyscallHook = procedure(CPU: TEECPU) of object;
  TEETrapHook = procedure(CPU: TEECPU; Index: Cardinal) of object;

  TEETLBEntry = record
    PageMask, EntryHi, EntryLo0, EntryLo1: Cardinal;
  end;

  PEEInst = ^TEEInst;
  TEEHandler = function(CPU: TEECPU; I: PEEInst): Boolean;
  // A 128-bit multimedia operation on whole registers: R from A (rs) and B
  // (rt), Sa its shift amount (EEMMIKernel).
  TEEMMIKernel = procedure(A, B, R: PPS2Reg128; Sa: NativeUInt);

  TEEInst = record
    Handler: Pointer;
    Imm: Cardinal;
    Addr: Cardinal;
    Op: Cardinal;
    S, T, D: TPS2RegIndex;
    Sa: Byte;
    Flags: Byte;
  end;

  // A load of a polling block: from Address (Base -1) or GPR[Base] + Address.
  TEEPollLoad = record
    Base: ShortInt;
    Address: Cardinal;
  end;

  PEEBlock = ^TEEBlock;
  TEEBlock = record
    PC: Cardinal;
    Count: Integer;
    Insts: PEEInst;
    Code: PCardinal;
    GenPtr, GenPtr2: PCardinal;
    Gen, Gen2: Cardinal;
    Next: PEEBlock;
    Link: array[0..1] of PEEBlock;
    // Only NOPs and an unconditional branch back to PC with a NOP in its
    // delay slot: running it changes nothing but time.
    Spin: Boolean;
    // Its generated code (UseJit; nil: none yet), where blocks chained to it
    // enter that code, and how often it ran before.
    Native, NativeInner: Pointer;
    Heat: Integer;
    // The compiled blocks its code goes on to after its last instruction:
    // where its branch went (0), past its end (1).
    Chain: array[0..1] of PEEBlock;
    // Only polls (FindPoll): a conditional branch back to PC ends it, and a
    // turn computes the same from the same memory; its loads. With the block
    // before it (PollsWith): PollFirst, whether the two are such a turn
    // (their loads then in PollLoads).
    Poll, PollPair: Boolean;
    PollFirst: PEEBlock;
    PollLoadCount: Integer;
    PollLoads: array[0..3] of TEEPollLoad;
    // Only counts down to its exit (FindCountdown): CountKind 1, a register
    // (CountReg) by ADDIU or DADDIU (CountWide) of -1, before its branch or
    // in the delay slot (CountAfter); 2, a word at GPR[CountBase] +
    // CountOffset, loaded into CountReg, decremented, stored and loaded into
    // CountReg2 (ADDIU, before the branch). The branch goes on while the
    // counter (or CountReg2) is not GPR[CountCmp] (BNE), or is above zero
    // (BGTZ, CountCmp 255).
    CountKind, CountReg, CountReg2, CountBase, CountCmp: Byte;
    CountWide, CountAfter: Boolean;
    CountOffset: Cardinal;
  end;

  TEEPageMap = array[0..EEPageCount - 1] of PByte;
  PEEPageMap = ^TEEPageMap;
  TEEGenMap = array[0..EEPageCount - 1] of PCardinal;
  PEEGenMap = ^TEEGenMap;
  TEEPhysMap = array[0..EEPageCount - 1] of Cardinal;
  PEEPhysMap = ^TEEPhysMap;

  TEEState = record
    GPR: array[TPS2RegIndex] of TPS2Reg128;
    HI, LO: TPS2Reg128;
    SA: Cardinal;
    PC: Cardinal;
    COP0: array[0..31] of Cardinal;
    FPR: array[0..31] of Cardinal;
    ACC, FCR31: Cardinal;
    TLB: array[0..47] of TEETLBEntry;
    CountBase: Int64;
    PCCR, PCR0, PCR1: Cardinal;
    PerfBase: Int64;
  end;

  TEECPU = class
  private
    const
      BlockBuckets = 16384;
      BlockChunkSize = 1024;
      InstChunkSize = 16384;
      MaxBlockInsts = 256;
      {$IFDEF CPU64BITS}
      MaxBlocks = 131072;
      MaxInstChunks = 128;
      {$ELSE}
      MaxBlocks = 32768;
      MaxInstChunks = 32;
      {$ENDIF}
      // FPhys entries: physical page shl 12 or these flags.
      PhysPresent = 1;
      PhysValid = 2;
      PhysDirty = 4;
      PhysScratch = 8;
      // Stop codes of a handler that returned True.
      StopLeave = 1;
      StopPC = 2;
      StopSkip = 3;
      // TEEInst.Flags.
      IFSlot = 1;
      IFBranch = 2;
      IFEnd = 4;
      IFLikely = 8;
  private
    FBus: TEEBus;
    FCop2: TEECop2;
    FScratch: PByte;
    FScratchGen: array[0..3] of Cardinal;
    FReadMap, FWriteMap: PEEPageMap;
    FGenMap: PEEGenMap;
    FPhys: PEEPhysMap;
    FDummyGen: Cardinal;
    // An interrupt pending, an exit asked for, the code writer full (the
    // blocks are cleared at the next one) and a reset of the code owed (it
    // waits for the code running to return): together, which generated code
    // looks at after each block at once.
    FIntPending, FExitRequest, FJitFull, FJitResetPending: Boolean;
    // A newly pending interrupt is taken after one more block (code polling
    // INTC_STAT sees the cause bit before the handler acknowledges it).
    FIntDelay: Boolean;
    FInt0, FInt1: Boolean;
    FIntBlock: Boolean;
    FStop: Byte;
    FBranchTaken: Boolean;
    FBranchTarget: Cardinal;
    FHostRoundSaved: TRoundingMode;
    FHostMaskSaved: TArithmeticExceptionMask;
    FBlockHead: array[0..BlockBuckets - 1] of PEEBlock;
    FBlockChunks: TArray<TArray<TEEBlock>>;
    FInstChunks: TArray<TArray<TEEInst>>;
    FCodeChunks: TArray<TArray<Cardinal>>;
    FBlockCount, FInstChunk, FInstUsed, FCodeChunk, FCodeUsed: Integer;
    FBlockGen: Cardinal;
    FBlocksBuilt: Int64;
    FSingle: array[0..1] of TEEInst;
    FOnSyscall: TEESyscallHook;
    FOnTrap: TEETrapHook;
    // Blocks as generated code (HW.JIT, UseJit): the writer, whether code is
    // running (a reset of the code waits for it to return), no writer to be
    // had; whether the code made since the last reset leaves to RunBlocks
    // after each block for the diagnostics (WatchPtr, BlockProfile).
    FJit: TJitAsm;
    FUseJit, FInJit, FJitFailed, FJitDiagnostics: Boolean;
    // Multimedia operations decoded to their kernels (EEMMIKernel).
    FMMIKernels: Boolean;
    FJitBlocks, FJitCompiles, FJitResets: Int64;
    // The block whose code ran last (its predecessors' time is counted).
    FJitLast: PEEBlock;
    function JitCompile(B: PEEBlock): Pointer;
    procedure JitEmitChain(B: PEEBlock; K: Integer);
    function JitLink(B: PEEBlock; K: Integer): Pointer;
    function PollCode(const Blocks: array of PEEBlock; LoopPC: Cardinal; var Loads: array of TEEPollLoad;
      out LoadCount: Integer): Boolean;
    procedure FindPoll(B: PEEBlock);
    procedure FindCountdown(B: PEEBlock);
    procedure SkipCountdown(B: PEEBlock);
    function PollsWith(First, Second: PEEBlock): Boolean;
    function PollQuiet(B: PEEBlock): Boolean;
    function JitEmitOwn(I: PEEInst; Stop: TJitLabel): Boolean;
    procedure JitStop(I: PEEInst);
    procedure MapRange(VBase, Size, Phys: Cardinal; Flags: Cardinal);
    procedure UnmapRange(VBase, Size: Cardinal);
    procedure MapTLBEntry(Index: Integer);
    procedure EntryRange(const E: TEETLBEntry; out Base, Size: Cardinal);
    procedure RebuildTLBRange(Base, Size: Cardinal);
    procedure UpdateInterrupts; inline;
    function Decode(Op, Address: Cardinal; var I: TEEInst): Boolean;
    procedure ClearBlocks;
    function FindBlock(PC: Cardinal): PEEBlock;
    function BuildBlock(PC: Cardinal): PEEBlock;
    function BlockValid(B: PEEBlock): Boolean;
    function Execute(Insts: PEEInst; Count: Integer; out Next: Cardinal): Integer;
    procedure RunBlocks;
    procedure LogWatch(PC: Cardinal);
    procedure FetchFault(PC: Cardinal);
    function GetCount: Cardinal;
    function ReadCOP0(Index: Integer; Op: Cardinal): Cardinal;
    procedure WriteCOP0(Index: Integer; Op, Value: Cardinal);
    function PerfCounter(Which: Integer): Cardinal;
    procedure SetPerfCounter(Which: Integer; Value: Cardinal);
    // Exceptions: set COP0, PC and FStop; return True.
    function Raise_(I: PEEInst; Code: Cardinal): Boolean;
    function AddressFault(I: PEEInst; Address, Code: Cardinal): Boolean;
    function LoadSlow(I: PEEInst; A: Cardinal; Size: Integer; out V: UInt64): Boolean;
    function StoreSlow(I: PEEInst; A: Cardinal; Size: Integer; V: UInt64): Boolean;
    function Load128(I: PEEInst; A: Cardinal; out V: TPS2Reg128): Boolean;
    function Store128(I: PEEInst; A: Cardinal; const V: TPS2Reg128): Boolean;
    function Translate(I: PEEInst; A: Cardinal; Writing: Boolean; out Phys: Cardinal): Boolean;
    function FPUResult(D: Double; Overflow, Underflow: Cardinal): Cardinal;
    function FAdd(A, B: Cardinal): Cardinal;
    function FPUDivide(A, B: Cardinal): Cardinal;
    function FPURoot(V: Cardinal): Cardinal;
    function MultiplyAdd(I: PEEInst; Op: Cardinal): Boolean;
  public
    // Operation handlers (TEEHandler); True stops the block.
    function OpNOP(I: PEEInst): Boolean;
    function OpReserved(I: PEEInst): Boolean;
    function OpFetchFault(I: PEEInst): Boolean;
    function OpSLL(I: PEEInst): Boolean;
    function OpSRL(I: PEEInst): Boolean;
    function OpSRA(I: PEEInst): Boolean;
    function OpSLLV(I: PEEInst): Boolean;
    function OpSRLV(I: PEEInst): Boolean;
    function OpSRAV(I: PEEInst): Boolean;
    function OpDSLL(I: PEEInst): Boolean;
    function OpDSRL(I: PEEInst): Boolean;
    function OpDSRA(I: PEEInst): Boolean;
    function OpDSLLV(I: PEEInst): Boolean;
    function OpDSRLV(I: PEEInst): Boolean;
    function OpDSRAV(I: PEEInst): Boolean;
    function OpJR(I: PEEInst): Boolean;
    function OpJALR(I: PEEInst): Boolean;
    function OpMOVZ(I: PEEInst): Boolean;
    function OpMOVN(I: PEEInst): Boolean;
    function OpSYSCALL(I: PEEInst): Boolean;
    function OpBREAK(I: PEEInst): Boolean;
    function OpMFHI(I: PEEInst): Boolean;
    function OpMTHI(I: PEEInst): Boolean;
    function OpMFLO(I: PEEInst): Boolean;
    function OpMTLO(I: PEEInst): Boolean;
    function OpMULT(I: PEEInst): Boolean;
    function OpMULTU(I: PEEInst): Boolean;
    function OpDIV(I: PEEInst): Boolean;
    function OpDIVU(I: PEEInst): Boolean;
    function OpADD(I: PEEInst): Boolean;
    function OpADDU(I: PEEInst): Boolean;
    function OpSUB(I: PEEInst): Boolean;
    function OpSUBU(I: PEEInst): Boolean;
    function OpAND(I: PEEInst): Boolean;
    function OpOR(I: PEEInst): Boolean;
    function OpXOR(I: PEEInst): Boolean;
    function OpNOR(I: PEEInst): Boolean;
    function OpSLT(I: PEEInst): Boolean;
    function OpSLTU(I: PEEInst): Boolean;
    function OpDADD(I: PEEInst): Boolean;
    function OpDADDU(I: PEEInst): Boolean;
    function OpDSUB(I: PEEInst): Boolean;
    function OpDSUBU(I: PEEInst): Boolean;
    function OpTrapR(I: PEEInst): Boolean;
    function OpTrapI(I: PEEInst): Boolean;
    function OpMFSA(I: PEEInst): Boolean;
    function OpMTSA(I: PEEInst): Boolean;
    function OpMTSAB(I: PEEInst): Boolean;
    function OpMTSAH(I: PEEInst): Boolean;
    function OpBLTZ(I: PEEInst): Boolean;
    function OpBGEZ(I: PEEInst): Boolean;
    function OpBLTZL(I: PEEInst): Boolean;
    function OpBGEZL(I: PEEInst): Boolean;
    function OpBLTZAL(I: PEEInst): Boolean;
    function OpBGEZAL(I: PEEInst): Boolean;
    function OpBLTZALL(I: PEEInst): Boolean;
    function OpBGEZALL(I: PEEInst): Boolean;
    function OpJ(I: PEEInst): Boolean;
    function OpJAL(I: PEEInst): Boolean;
    function OpBEQ(I: PEEInst): Boolean;
    function OpBNE(I: PEEInst): Boolean;
    function OpBLEZ(I: PEEInst): Boolean;
    function OpBGTZ(I: PEEInst): Boolean;
    function OpBEQL(I: PEEInst): Boolean;
    function OpBNEL(I: PEEInst): Boolean;
    function OpBLEZL(I: PEEInst): Boolean;
    function OpBGTZL(I: PEEInst): Boolean;
    function OpADDI(I: PEEInst): Boolean;
    function OpADDIU(I: PEEInst): Boolean;
    function OpSLTI(I: PEEInst): Boolean;
    function OpSLTIU(I: PEEInst): Boolean;
    function OpANDI(I: PEEInst): Boolean;
    function OpORI(I: PEEInst): Boolean;
    function OpXORI(I: PEEInst): Boolean;
    function OpLUI(I: PEEInst): Boolean;
    function OpDADDI(I: PEEInst): Boolean;
    function OpDADDIU(I: PEEInst): Boolean;
    function OpLB(I: PEEInst): Boolean;
    function OpLBU(I: PEEInst): Boolean;
    function OpLH(I: PEEInst): Boolean;
    function OpLHU(I: PEEInst): Boolean;
    function OpLW(I: PEEInst): Boolean;
    function OpLWU(I: PEEInst): Boolean;
    function OpLD(I: PEEInst): Boolean;
    function OpLQ(I: PEEInst): Boolean;
    function OpLWL(I: PEEInst): Boolean;
    function OpLWR(I: PEEInst): Boolean;
    function OpLDL(I: PEEInst): Boolean;
    function OpLDR(I: PEEInst): Boolean;
    function OpSB(I: PEEInst): Boolean;
    function OpSH(I: PEEInst): Boolean;
    function OpSW(I: PEEInst): Boolean;
    function OpSD(I: PEEInst): Boolean;
    function OpSQ(I: PEEInst): Boolean;
    function OpSWL(I: PEEInst): Boolean;
    function OpSWR(I: PEEInst): Boolean;
    function OpSDL(I: PEEInst): Boolean;
    function OpSDR(I: PEEInst): Boolean;
    function OpLWC1(I: PEEInst): Boolean;
    function OpSWC1(I: PEEInst): Boolean;
    function OpLQC2(I: PEEInst): Boolean;
    function OpSQC2(I: PEEInst): Boolean;
    function OpCOP0(I: PEEInst): Boolean;
    function OpERET(I: PEEInst): Boolean;
    function OpEI(I: PEEInst): Boolean;
    function OpDI(I: PEEInst): Boolean;
    function OpBC0(I: PEEInst): Boolean;
    function OpMFC1(I: PEEInst): Boolean;
    function OpMTC1(I: PEEInst): Boolean;
    function OpCFC1(I: PEEInst): Boolean;
    function OpCTC1(I: PEEInst): Boolean;
    function OpBC1(I: PEEInst): Boolean;
    function OpFPU(I: PEEInst): Boolean;
    function OpFADD(I: PEEInst): Boolean;
    function OpFMUL(I: PEEInst): Boolean;
    function OpFMOV(I: PEEInst): Boolean;
    function OpCOP2(I: PEEInst): Boolean;
    function OpMMI(I: PEEInst): Boolean;
    function OpMMI0(I: PEEInst): Boolean;
    function OpMMI1(I: PEEInst): Boolean;
    function OpMMI2(I: PEEInst): Boolean;
    function OpMMI3(I: PEEInst): Boolean;
    function OpMMIKernel(I: PEEInst): Boolean;
    function OpTrapHLE(I: PEEInst): Boolean;
  public
    S: TEEState;
    // Advanced by executed instructions; the run loop stops at Deadline^.
    Now, Deadline: PInt64;
    InstructionsExecuted: Int64;
    // Let blocks that only spin (see TEEBlock.Spin) jump to the deadline
    // (BIOS boot: the kernel's idle thread), and the cycles that saved.
    SkipSpins: Boolean;
    SpinCycles: Int64;
    // Diagnostics: the cycles polling blocks were passed over in (exactly as
    // their turns would have run, see FindPoll).
    PollCycles: Int64;
    // Turns of counting-down loops are passed over (SkipCountdown), and the
    // cycles that took.
    SkipCountdowns: Boolean;
    CountdownCycles: Int64;
    // Diagnostics (BIOS boot): SYSCALLs taken to the guest kernel, interrupts
    // taken by line state (index: INT1 * 2 + INT0).
    SyscallLog: TStrings;
    InterruptsTaken: array[0..3] of Int64;
    // SifGetReg calls are logged from this cycle on.
    SyscallLogPolledFrom: Int64;
    // Diagnostics (not serialized): the instruction of the last MMIO access.
    SlowPC: Cardinal;
    ExceptionCount: Int64;
    LastExceptionPC, LastExceptionCode: Cardinal;
    ExceptionCodes: array[0..31] of Int64;
    // The last block starts (diagnostics).
    PCHistory: array[0..15] of Cardinal;
    PCHistoryPos: Integer;
    // Diagnostics: a RAM word checked at every block start; changes go to WatchLog.
    WatchPtr: PCardinal;
    WatchLast: Cardinal;
    WatchLog: TStrings;
    // Diagnostics: block starts by PC when assigned.
    BlockProfile: TDictionary<Cardinal, Int64>;
    // Runs of a block before its code is made (UseJit; tests: 1).
    JitHeat: Integer;
    constructor Create(Bus: TEEBus; Cop2: TEECop2; NowCounter, DeadlineCounter: PInt64);
    destructor Destroy; override;
    procedure Reset;
    // Runs blocks until Deadline^ (or an exit request) with the guest
    // floating-point mode set on this thread.
    procedure Run;
    procedure RequestExit; inline;
    // INTC (INT0, IP2) and DMAC (INT1, IP3) interrupt lines.
    procedure SetInt0(Active: Boolean);
    procedure SetInt1(Active: Boolean);
    function Int0: Boolean; inline;
    // Holds interrupts off whatever Status says (the HLE kernel while it
    // runs interrupt handlers, which may set EIE or rewrite Status).
    procedure SetIntBlock(Value: Boolean);
    // COP0 timer: the absolute cycle where Count reaches Compare next.
    function CompareDue: Int64;
    procedure CompareReached;
    // Takes an exception from outside an instruction (HLE kernel): EPC = PC.
    procedure EnterException(Code: Cardinal);
    procedure SetPC(Value: Cardinal);
    // TLB contents changed outside TLBWI/TLBWR (state load, HLE kernel).
    procedure RebuildMaps;
    procedure WriteTLB(Index: Integer; const E: TEETLBEntry);
    // Code at physical pages changed outside the CPU's direct stores.
    procedure InvalidateBlocks;
    // Guest memory access for the HLE kernel and loaders (no exceptions:
    // False when not mapped).
    function ReadVirtual(Address: Cardinal; Size: Integer; out Value: UInt64): Boolean;
    function WriteVirtual(Address: Cardinal; Size: Integer; Value: UInt64): Boolean;
    function HostPointer(Address: Cardinal): PByte;
    procedure SerializeState(State: TStateArchive);
    property OnSyscall: TEESyscallHook read FOnSyscall write FOnSyscall;
    property OnTrap: TEETrapHook read FOnTrap write FOnTrap;
    property Cop2: TEECop2 read FCop2;
    property Scratchpad: PByte read FScratch;
    property BlocksBuilt: Int64 read FBlocksBuilt;
    // Experimental: blocks run as generated code where HW.JIT has a backend.
    property UseJit: Boolean read FUseJit write FUseJit;
    property JitBlocks: Int64 read FJitBlocks;
    property JitCompiles: Int64 read FJitCompiles;
    property JitResets: Int64 read FJitResets;
    // Common multimedia operations run as whole-register kernels where the
    // host has them (the default; tests compare with the general handlers).
    // Takes effect for blocks decoded afterwards (InvalidateBlocks).
    property MMIKernels: Boolean read FMMIKernels write FMMIKernels;
    property Count: Cardinal read GetCount;
  end;

// Guest float helpers shared with VU code: inputs with exponent 0 read as
// signed zero and with exponent 255 as the largest finite value.
function EEFloatIn(V: Cardinal): Double; inline;
function PS2FloatAdd(A, B: Cardinal; out Flags: Cardinal): Cardinal;
// A quotient or square root of PS2 floats, rounded to nearest; overflow gives
// the largest value, underflow a signed zero.
function PS2FloatNearest(D: Double): Cardinal;
// Orders PS2 floats like the MAX/MIN instructions do.
function PS2FloatKey(V: Cardinal): Integer; inline;

// The bit the FPU's and the VUs' multiplier loses (the VU manuals: 1 * X may
// differ from X, X * 1 not). Hardware results (ps2autotests' cpu/ee_fpu muldiv,
// fobes.dev's list of 1 * X for X = 0.5 .. 249.5, PCSX2 issue 10519) all fit
// a radix-4 Booth multiplier that drops the low columns of its partial
// products: a negative digit of the multiplier B in its eight lowest places
// (bits 0..15 of B's mantissa) loses what reaches the product's low bits.
// Where the multiplicand A (fs) is a power of two that is all the product
// misses: A * B, both nonzero, in range (exponent 1..255), with such a digit
// is one unit less than the truncated product. With other multiplicands the
// loss also depends on how the partial products sum, which the data do not
// show: those products stay truncated. PS2MulLostBit False: always truncated.
var
  PS2MulLostBit: Boolean = True;
function PS2MulLosesBit(A, B: Cardinal): Boolean; inline;

// The kernel of MMI instruction Op (opcode $1C) where the host has one (nil:
// the general handler runs it).
function EEMMIKernel(Op: Cardinal): TEEMMIKernel;

implementation

// PS2 floats have no infinity or NaN: exponent 255 is an ordinary binade
// (the largest value is 7FFFFFFFh) and exponent 0 is zero. A double holds
// every such value exactly.
function EEFloatIn(V: Cardinal): Double;
var
  B: UInt64;
begin
  var E := (V shr 23) and $FF;
  if E = 0 then
    B := UInt64(V and $80000000) shl 32
  else
    B := (UInt64(V and $80000000) shl 32) or (UInt64(E + (1023 - 127)) shl 52) or (UInt64(V and $7FFFFF) shl 29);
  Result := PDouble(@B)^;
end;

function PS2MulLosesBit(A, B: Cardinal): Boolean;
begin
  Result := False;
  if not PS2MulLostBit or ((A and $7FFFFF) <> 0) then
    Exit;
  var EA := Integer((A shr 23) and $FF);
  var EB := Integer((B shr 23) and $FF);
  if (EA = 0) or (EB = 0) or (EA + EB - 127 < 1) or (EA + EB - 127 > 255) then
    Exit;
  // Digit I (bits 2I+1, 2I, 2I-1) is negative where bit 2I+1 is set and not
  // both bits below it.
  var X := B and $FFFF;
  Result := (X and not ((X and (X shl 1)) shl 1) and $AAAA) <> 0;
end;

// The FPU/VU adder aligns the smaller operand with a single guard bit and
// drops whatever is shifted out before adding; the sum is then truncated.
// Flags: 1 overflow, 2 underflow.
function PS2FloatAdd(A, B: Cardinal; out Flags: Cardinal): Cardinal;
begin
  Flags := 0;
  var EA := Integer((A shr 23) and $FF);
  var EB := Integer((B shr 23) and $FF);
  if EA = 0 then
  begin
    if EB = 0 then
      Exit(A and B and $80000000);
    Exit(B);
  end;
  if EB = 0 then
    Exit(A);
  if (B and $7FFFFFFF) > (A and $7FFFFFFF) then
  begin
    var T := A;
    A := B;
    B := T;
    var TE := EA;
    EA := EB;
    EB := TE;
  end;
  var Sign := A and $80000000;
  var MA := ((A and $7FFFFF) or $800000) shl 3;
  var MB := ((B and $7FFFFF) or $800000) shl 3;
  var Align := EA - EB;
  if Align > 0 then
  begin
    if Align < 32 then
      MB := (MB shr Align) and not Cardinal(3)
    else
      MB := 0;
  end;
  if ((A xor B) and $80000000) <> 0 then
  begin
    MA := MA - MB;
    if MA = 0 then
      Exit(0);
    while MA < ($800000 shl 3) do
    begin
      MA := MA shl 1;
      Dec(EA);
    end;
  end
  else
  begin
    MA := MA + MB;
    if (MA and ($800000 shl 4)) <> 0 then
    begin
      MA := MA shr 1;
      Inc(EA);
    end;
  end;
  if EA > 255 then
  begin
    Flags := 1;
    Exit(Sign or $7FFFFFFF);
  end;
  if EA <= 0 then
  begin
    Flags := 2;
    Exit(Sign);
  end;
  Result := Sign or (Cardinal(EA) shl 23) or ((MA shr 3) and $7FFFFF);
end;

function Sar32(V: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := V shr N;
  if Integer(V) < 0 then
    Result := Result or not (Cardinal($FFFFFFFF) shr N);
end;

function Sar64(V: UInt64; N: Integer): UInt64; inline;
begin
  Result := V shr N;
  if Int64(V) < 0 then
    Result := Result or not (UInt64($FFFFFFFFFFFFFFFF) shr N);
end;

{ TEEBus }

procedure TEEBus.Read128(Address: Cardinal; out Value: TPS2Reg128);
begin
  Value.Lo := Read(Address, 8);
  Value.Hi := Read(Address + 8, 8);
end;

procedure TEEBus.Write128(Address: Cardinal; const Value: TPS2Reg128);
begin
  Write(Address, Value.Lo, 8);
  Write(Address + 8, Value.Hi, 8);
end;

function TEEBus.CPCond0: Boolean;
begin
  Result := False;
end;

{ TEECop2 }

constructor TEECop2.Create;
begin
  inherited Create;
  Reset;
end;

procedure TEECop2.Reset;
begin
  FillChar(VF, SizeOf(VF), 0);
  FillChar(VI, SizeOf(VI), 0);
  VF[0].UW[3] := $3F800000;
end;

function TEECop2.ReadControl(Index: Integer): Cardinal;
begin
  Result := VI[Index and 31];
end;

procedure TEECop2.WriteControl(Index: Integer; Value: Cardinal);
begin
  if (Index and 31) <> 0 then
    VI[Index and 31] := Value;
end;

function TEECop2.Execute(Op: Cardinal): Boolean;
begin
  Result := False;
end;

procedure TEECop2.Interlock;
begin
end;

procedure TEECop2.Sync;
begin
end;

function TEECop2.Condition: Boolean;
begin
  Result := False;
end;

procedure TEECop2.SerializeState(State: TStateArchive);
begin
  State.Field(VF, SizeOf(VF));
  State.Field(VI, SizeOf(VI));
end;

procedure TEECop2.RunStarts;
begin
end;

procedure TEECop2.RunEnds;
begin
end;

function TEECop2.MacroRoutine(Op: Cardinal; out Target: Pointer; out Running: PBoolean): Pointer;
begin
  Target := nil;
  Running := nil;
  Result := nil;
end;

function TEECop2.RunningFlag: PBoolean;
begin
  Result := nil;
end;

{ TEECPU }

{ Multimedia kernels }

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// Each does what the general handler (OpMMI0..3, OpMMI's shifts) does for
// its operation, on whole registers with SSE2: A in RCX, B in RDX, R in R8,
// Sa in R9 (both read before R is written: R may be A or B).

procedure MMIPADDW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddd xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubd xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPCGTW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpgtd xmm0, xmm1
  movdqu [r8], xmm0
end;

// A where A > B, else B.
procedure MMIPMAXW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  movdqa xmm2, xmm0
  pcmpgtd xmm2, xmm1
  pand xmm0, xmm2
  pandn xmm2, xmm1
  por xmm0, xmm2
  movdqu [r8], xmm0
end;

procedure MMIPADDH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPCGTH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpgtw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPMAXH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pmaxsw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPADDB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPCGTB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpgtb xmm0, xmm1
  movdqu [r8], xmm0
end;

// B's words 0, 1 interleaved with A's.
procedure MMIPEXTLW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpckldq xmm0, xmm1
  movdqu [r8], xmm0
end;

// B's words 0, 2 then A's.
procedure MMIPPACW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  pshufd xmm0, xmm0, $08
  pshufd xmm1, xmm1, $08
  punpcklqdq xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPADDSH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddsw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBSH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubsw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPEXTLH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpcklwd xmm0, xmm1
  movdqu [r8], xmm0
end;

// B's even halfwords then A's: sign-extended words packed back without
// saturation.
procedure MMIPPACH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  pslld xmm0, 16
  psrad xmm0, 16
  pslld xmm1, 16
  psrad xmm1, 16
  packssdw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPADDSB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddsb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBSB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubsb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPEXTLB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpcklbw xmm0, xmm1
  movdqu [r8], xmm0
end;

// B's even bytes then A's: zero-extended halfwords packed back without
// saturation.
procedure MMIPPACB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  pcmpeqw xmm2, xmm2
  psrlw xmm2, 8
  pand xmm0, xmm2
  pand xmm1, xmm2
  packuswb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPCEQW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpeqd xmm0, xmm1
  movdqu [r8], xmm0
end;

// A where A < B, else B.
procedure MMIPMINW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  movdqa xmm2, xmm1
  pcmpgtd xmm2, xmm0
  pand xmm0, xmm2
  pandn xmm2, xmm1
  por xmm0, xmm2
  movdqu [r8], xmm0
end;

procedure MMIPCEQH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpeqw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPMINH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pminsw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPCEQB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pcmpeqb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPEXTUW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpckhdq xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPADDUH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddusw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBUH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubusw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPEXTUH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpckhwd xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPADDUB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  paddusb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSUBUB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  psubusb xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPEXTUB(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpckhbw xmm0, xmm1
  movdqu [r8], xmm0
end;

// B's low doubleword then A's.
procedure MMIPCPYLD(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  movdqu xmm1, [rcx]
  punpcklqdq xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPAND(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pand xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPXOR(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  pxor xmm0, xmm1
  movdqu [r8], xmm0
end;

// A's high doubleword then B's.
procedure MMIPCPYUD(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  punpckhqdq xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPOR(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  por xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPNOR(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqu xmm1, [rdx]
  por xmm0, xmm1
  pcmpeqd xmm2, xmm2
  pxor xmm0, xmm2
  movdqu [r8], xmm0
end;

// Shifts of B by Sa (halfwords: its low four bits).
procedure MMIPSLLH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 15
  movd xmm1, r9d
  psllw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSRLH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 15
  movd xmm1, r9d
  psrlw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSRAH(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 15
  movd xmm1, r9d
  psraw xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSLLW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 31
  movd xmm1, r9d
  pslld xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSRLW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 31
  movd xmm1, r9d
  psrld xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure MMIPSRAW(A, B, R: PPS2Reg128; Sa: NativeUInt);
asm
  .NOFRAME
  movdqu xmm0, [rdx]
  and r9d, 31
  movd xmm1, r9d
  psrad xmm0, xmm1
  movdqu [r8], xmm0
end;

type
  TEEMMIKernelEntry = record
    Funct, Sa: Byte;
    Kernel: TEEMMIKernel;
  end;

const
  // (Sa 255: the shifts, Sa their amount.)
  EEMMIKernels: array[0..44] of TEEMMIKernelEntry = (
    (Funct: $08; Sa: 0; Kernel: MMIPADDW), (Funct: $08; Sa: 1; Kernel: MMIPSUBW),
    (Funct: $08; Sa: 2; Kernel: MMIPCGTW), (Funct: $08; Sa: 3; Kernel: MMIPMAXW),
    (Funct: $08; Sa: 4; Kernel: MMIPADDH), (Funct: $08; Sa: 5; Kernel: MMIPSUBH),
    (Funct: $08; Sa: 6; Kernel: MMIPCGTH), (Funct: $08; Sa: 7; Kernel: MMIPMAXH),
    (Funct: $08; Sa: 8; Kernel: MMIPADDB), (Funct: $08; Sa: 9; Kernel: MMIPSUBB),
    (Funct: $08; Sa: 10; Kernel: MMIPCGTB), (Funct: $08; Sa: 18; Kernel: MMIPEXTLW),
    (Funct: $08; Sa: 19; Kernel: MMIPPACW), (Funct: $08; Sa: 20; Kernel: MMIPADDSH),
    (Funct: $08; Sa: 21; Kernel: MMIPSUBSH), (Funct: $08; Sa: 22; Kernel: MMIPEXTLH),
    (Funct: $08; Sa: 23; Kernel: MMIPPACH), (Funct: $08; Sa: 24; Kernel: MMIPADDSB),
    (Funct: $08; Sa: 25; Kernel: MMIPSUBSB), (Funct: $08; Sa: 26; Kernel: MMIPEXTLB),
    (Funct: $08; Sa: 27; Kernel: MMIPPACB),
    (Funct: $28; Sa: 2; Kernel: MMIPCEQW), (Funct: $28; Sa: 3; Kernel: MMIPMINW),
    (Funct: $28; Sa: 6; Kernel: MMIPCEQH), (Funct: $28; Sa: 7; Kernel: MMIPMINH),
    (Funct: $28; Sa: 10; Kernel: MMIPCEQB), (Funct: $28; Sa: 18; Kernel: MMIPEXTUW),
    (Funct: $28; Sa: 20; Kernel: MMIPADDUH), (Funct: $28; Sa: 21; Kernel: MMIPSUBUH),
    (Funct: $28; Sa: 22; Kernel: MMIPEXTUH), (Funct: $28; Sa: 24; Kernel: MMIPADDUB),
    (Funct: $28; Sa: 25; Kernel: MMIPSUBUB), (Funct: $28; Sa: 26; Kernel: MMIPEXTUB),
    (Funct: $09; Sa: 14; Kernel: MMIPCPYLD), (Funct: $09; Sa: 18; Kernel: MMIPAND),
    (Funct: $09; Sa: 19; Kernel: MMIPXOR),
    (Funct: $29; Sa: 14; Kernel: MMIPCPYUD), (Funct: $29; Sa: 18; Kernel: MMIPOR),
    (Funct: $29; Sa: 19; Kernel: MMIPNOR),
    (Funct: $34; Sa: 255; Kernel: MMIPSLLH), (Funct: $36; Sa: 255; Kernel: MMIPSRLH),
    (Funct: $37; Sa: 255; Kernel: MMIPSRAH), (Funct: $3C; Sa: 255; Kernel: MMIPSLLW),
    (Funct: $3E; Sa: 255; Kernel: MMIPSRLW), (Funct: $3F; Sa: 255; Kernel: MMIPSRAW));

function EEMMIKernelIndex(Op: Cardinal): Integer;
begin
  var Funct := Op and $3F;
  var Sa := (Op shr 6) and 31;
  for var K := 0 to High(EEMMIKernels) do
    if (EEMMIKernels[K].Funct = Funct) and ((EEMMIKernels[K].Sa = Sa) or (EEMMIKernels[K].Sa = 255)) then
      Exit(K);
  Result := -1;
end;
{$ELSE}
type
  TEEMMIKernelEntry = record
    Funct, Sa: Byte;
    Kernel: TEEMMIKernel;
  end;

var
  EEMMIKernels: array[0..0] of TEEMMIKernelEntry;

function EEMMIKernelIndex(Op: Cardinal): Integer;
begin
  Result := -1;
end;
{$ENDIF}

function EEMMIKernel(Op: Cardinal): TEEMMIKernel;
begin
  var K := EEMMIKernelIndex(Op);
  if K < 0 then
    Exit(nil);
  Result := EEMMIKernels[K].Kernel;
end;

constructor TEECPU.Create(Bus: TEEBus; Cop2: TEECop2; NowCounter, DeadlineCounter: PInt64);
begin
  inherited Create;
  if (Bus = nil) or (Cop2 = nil) or (NowCounter = nil) or (DeadlineCounter = nil) then
    raise EArgumentException.Create('EE CPU requires a bus, COP2 and time counters');
  FBus := Bus;
  FCop2 := Cop2;
  Now := NowCounter;
  Deadline := DeadlineCounter;
  FScratch := AllocMem(PS2ScratchpadSize);
  FReadMap := AllocMem(SizeOf(TEEPageMap));
  FWriteMap := AllocMem(SizeOf(TEEPageMap));
  FGenMap := AllocMem(SizeOf(TEEGenMap));
  FPhys := AllocMem(SizeOf(TEEPhysMap));
  JitHeat := 2;
  FMMIKernels := True;
  Reset;
end;

destructor TEECPU.Destroy;
begin
  FJit.Free;
  FreeMem(FScratch);
  FreeMem(FReadMap);
  FreeMem(FWriteMap);
  FreeMem(FGenMap);
  FreeMem(FPhys);
  inherited;
end;

procedure TEECPU.Reset;
begin
  S := Default(TEEState);
  S.PC := $BFC00000;
  S.COP0[C0Status] := EESRERL or EESRBEV;
  S.COP0[C0PRId] := $00002E20;
  S.COP0[C0Config] := $00000440;
  S.COP0[C0Random] := 47;
  S.FCR31 := $01000001;
  S.CountBase := Now^;
  S.PerfBase := Now^;
  FillChar(FScratch^, PS2ScratchpadSize, 0);
  FInt0 := False;
  FInt1 := False;
  FIntBlock := False;
  FExitRequest := False;
  FCop2.Reset;
  RebuildMaps;
  UpdateInterrupts;
end;

procedure TEECPU.RequestExit;
begin
  FExitRequest := True;
end;

procedure TEECPU.UpdateInterrupts;
begin
  var SR := S.COP0[C0Status];
  var Cause := S.COP0[C0Cause] and not Cardinal(EECauseIP2 or EECauseIP3);
  if FInt0 then
    Cause := Cause or EECauseIP2;
  if FInt1 then
    Cause := Cause or EECauseIP3;
  S.COP0[C0Cause] := Cause;
  var Was := FIntPending;
  FIntPending := not FIntBlock and ((SR and (EESRIE or EESREIE or EESREXL or EESRERL)) = (EESRIE or EESREIE)) and
    ((Cause and SR and $8C00) <> 0);
  if FIntPending and not Was then
    FIntDelay := True;
  if FIntPending then
    FExitRequest := True;
end;

procedure TEECPU.SetIntBlock(Value: Boolean);
begin
  if FIntBlock <> Value then
  begin
    FIntBlock := Value;
    UpdateInterrupts;
  end;
end;

procedure TEECPU.SetInt0(Active: Boolean);
begin
  if FInt0 <> Active then
  begin
    FInt0 := Active;
    UpdateInterrupts;
  end;
end;

function TEECPU.Int0: Boolean;
begin
  Result := FInt0;
end;

procedure TEECPU.SetInt1(Active: Boolean);
begin
  if FInt1 <> Active then
  begin
    FInt1 := Active;
    UpdateInterrupts;
  end;
end;

function TEECPU.GetCount: Cardinal;
begin
  Result := Cardinal(UInt64(Now^ - S.CountBase));
end;

function TEECPU.CompareDue: Int64;
begin
  var Distance := Int64(Cardinal(S.COP0[C0Compare] - GetCount));
  if Distance = 0 then
    Distance := $100000000;
  Result := Now^ + Distance;
end;

procedure TEECPU.CompareReached;
begin
  S.COP0[C0Cause] := S.COP0[C0Cause] or EECauseIP7;
  UpdateInterrupts;
end;

procedure TEECPU.SetPC(Value: Cardinal);
begin
  S.PC := Value;
end;

{ Address maps }

procedure TEECPU.MapRange(VBase, Size, Phys: Cardinal; Flags: Cardinal);
begin
  var Pages := Size shr 12;
  for var K := 0 to Integer(Pages) - 1 do
  begin
    var V := (VBase shr 12) + Cardinal(K);
    if V >= EEPageCount then
      Break;
    var P := Phys + Cardinal(K) shl 12;
    FPhys[V] := (P and $FFFFF000) or Flags;
    if (Flags and PhysValid) = 0 then
    begin
      FReadMap[V] := nil;
      FWriteMap[V] := nil;
      FGenMap[V] := @FDummyGen;
      Continue;
    end;
    if (Flags and PhysScratch) <> 0 then
    begin
      var Offset := (Cardinal(K) shl 12) and (PS2ScratchpadSize - 1);
      FReadMap[V] := FScratch + Offset;
      FWriteMap[V] := FScratch + Offset;
      FGenMap[V] := @FScratchGen[Offset shr 12];
      Continue;
    end;
    FReadMap[V] := FBus.PagePointer(P shr 12, False);
    if (Flags and PhysDirty) <> 0 then
      FWriteMap[V] := FBus.PagePointer(P shr 12, True)
    else
      FWriteMap[V] := nil;
    FGenMap[V] := FBus.PageGeneration(P shr 12);
  end;
end;

procedure TEECPU.UnmapRange(VBase, Size: Cardinal);
begin
  for var K := 0 to Integer(Size shr 12) - 1 do
  begin
    var V := (VBase shr 12) + Cardinal(K);
    if V >= EEPageCount then
      Break;
    FPhys[V] := 0;
    FReadMap[V] := nil;
    FWriteMap[V] := nil;
    FGenMap[V] := @FDummyGen;
  end;
end;

procedure TEECPU.EntryRange(const E: TEETLBEntry; out Base, Size: Cardinal);
begin
  var Mask := E.PageMask and $01FFE000;
  Size := (Mask + $2000);
  Base := E.EntryHi and not (Mask or $1FFF);
end;

procedure TEECPU.MapTLBEntry(Index: Integer);
begin
  var E := S.TLB[Index];
  var Base, Size: Cardinal;
  EntryRange(E, Base, Size);
  // Only KUSEG and KSEG3 go through the TLB.
  if (Base >= $80000000) and (Base < $C0000000) then
    Exit;
  if (E.EntryLo0 and $80000000) <> 0 then
  begin
    // Scratchpad: 16 KiB at the even page.
    MapRange(Base, PS2ScratchpadSize, 0, PhysPresent or PhysValid or PhysDirty or PhysScratch);
    Exit;
  end;
  var Half := Size shr 1;
  for var Part := 0 to 1 do
  begin
    var Lo := E.EntryLo0;
    if Part = 1 then
      Lo := E.EntryLo1;
    var Flags: Cardinal := PhysPresent;
    if (Lo and 2) <> 0 then
      Flags := Flags or PhysValid;
    if (Lo and 4) <> 0 then
      Flags := Flags or PhysDirty;
    var Phys := ((Lo shr 6) and $FFFFF) shl 12;
    MapRange(Base + Cardinal(Part) * Half, Half, Phys and not (Half - 1), Flags);
  end;
end;

procedure TEECPU.RebuildTLBRange(Base, Size: Cardinal);
begin
  if (Base >= $80000000) and (Base < $C0000000) then
    Exit;
  UnmapRange(Base, Size);
  // Entries overlapping the range, the lowest index last (it wins).
  for var K := 47 downto 0 do
  begin
    var B, Z: Cardinal;
    EntryRange(S.TLB[K], B, Z);
    if (UInt64(B) < UInt64(Base) + Size) and (UInt64(Base) < UInt64(B) + Z) and
      (((S.TLB[K].EntryLo0 or S.TLB[K].EntryLo1) and 2) <> 0) then
      MapTLBEntry(K);
  end;
end;

procedure TEECPU.RebuildMaps;
begin
  for var V := 0 to EEPageCount - 1 do
  begin
    FPhys[V] := 0;
    FReadMap[V] := nil;
    FWriteMap[V] := nil;
    FGenMap[V] := @FDummyGen;
  end;
  // KSEG0 and KSEG1: physical = virtual and $1FFFFFFF.
  MapRange($80000000, $20000000, 0, PhysPresent or PhysValid or PhysDirty);
  MapRange($A0000000, $20000000, 0, PhysPresent or PhysValid or PhysDirty);
  for var K := 47 downto 0 do
    if ((S.TLB[K].EntryLo0 or S.TLB[K].EntryLo1) and 2) <> 0 then
      MapTLBEntry(K);
  ClearBlocks;
end;

procedure TEECPU.WriteTLB(Index: Integer; const E: TEETLBEntry);
begin
  var OldBase, OldSize, NewBase, NewSize: Cardinal;
  EntryRange(S.TLB[Index], OldBase, OldSize);
  S.TLB[Index] := E;
  S.TLB[Index].PageMask := E.PageMask and $01FFE000;
  S.TLB[Index].EntryHi := E.EntryHi and $FFFFE0FF;
  S.TLB[Index].EntryLo0 := E.EntryLo0 and $8FFFFFFF;
  S.TLB[Index].EntryLo1 := E.EntryLo1 and $0FFFFFFF;
  EntryRange(S.TLB[Index], NewBase, NewSize);
  RebuildTLBRange(OldBase, OldSize);
  RebuildTLBRange(NewBase, NewSize);
  ClearBlocks;
end;

function TEECPU.HostPointer(Address: Cardinal): PByte;
begin
  Result := FReadMap[Address shr 12];
  if Result <> nil then
    Inc(Result, Address and $FFF);
end;

function TEECPU.ReadVirtual(Address: Cardinal; Size: Integer; out Value: UInt64): Boolean;
begin
  Value := 0;
  var P := FReadMap[Address shr 12];
  if (P <> nil) and (((Address and $FFF) + Cardinal(Size)) <= $1000) then
  begin
    Inc(P, Address and $FFF);
    case Size of
      1: Value := P^;
      2: Value := PWord(P)^;
      4: Value := PCardinal(P)^;
    else
      Value := PUInt64(P)^;
    end;
    Exit(True);
  end;
  var E := FPhys[Address shr 12];
  if (E and PhysValid) = 0 then
    Exit(False);
  Value := FBus.Read((E and $FFFFF000) or (Address and $FFF), Size);
  Result := True;
end;

function TEECPU.WriteVirtual(Address: Cardinal; Size: Integer; Value: UInt64): Boolean;
begin
  var P := FWriteMap[Address shr 12];
  if (P <> nil) and (((Address and $FFF) + Cardinal(Size)) <= $1000) then
  begin
    Inc(P, Address and $FFF);
    case Size of
      1: P^ := Byte(Value);
      2: PWord(P)^ := Word(Value);
      4: PCardinal(P)^ := Cardinal(Value);
    else
      PUInt64(P)^ := Value;
    end;
    Inc(FGenMap[Address shr 12]^);
    Exit(True);
  end;
  var E := FPhys[Address shr 12];
  if (E and PhysValid) = 0 then
    Exit(False);
  FBus.Write((E and $FFFFF000) or (Address and $FFF), Value, Size);
  Result := True;
end;

{ Exceptions }

function TEECPU.Raise_(I: PEEInst; Code: Cardinal): Boolean;
begin
  var PC := I.Addr;
  var InSlot := (I.Flags and IFSlot) <> 0;
  var Cause := S.COP0[C0Cause] and not Cardinal($8000007C);
  Cause := Cause or (Code shl 2);
  var SR := S.COP0[C0Status];
  var Vector: Cardinal := $80000180;
  if Code = EEExcInterrupt then
    Vector := $80000200;
  if (SR and EESREXL) = 0 then
  begin
    if InSlot then
    begin
      S.COP0[C0EPC] := PC - 4;
      Cause := Cause or EECauseBD;
    end
    else
      S.COP0[C0EPC] := PC;
    if ((Code = EEExcTLBL) or (Code = EEExcTLBS)) and ((FPhys[S.COP0[C0BadVAddr] shr 12] and PhysPresent) = 0) then
      Vector := $80000000;
  end;
  if (SR and EESRBEV) <> 0 then
    Vector := Vector - $80000000 + $BFC00200;
  S.COP0[C0Cause] := Cause;
  S.COP0[C0Status] := SR or EESREXL;
  S.PC := Vector;
  Inc(ExceptionCount);
  Inc(ExceptionCodes[Code and 31]);
  LastExceptionPC := PC;
  LastExceptionCode := Code;
  UpdateInterrupts;
  FStop := StopPC;
  Result := True;
end;

procedure TEECPU.EnterException(Code: Cardinal);
begin
  FSingle[0] := Default(TEEInst);
  FSingle[0].Addr := S.PC;
  Raise_(@FSingle[0], Code);
  FStop := 0;
end;

function TEECPU.AddressFault(I: PEEInst; Address, Code: Cardinal): Boolean;
begin
  S.COP0[C0BadVAddr] := Address;
  if (Code = EEExcTLBL) or (Code = EEExcTLBS) or (Code = EEExcMod) then
  begin
    S.COP0[C0EntryHi] := (Address and $FFFFE000) or (S.COP0[C0EntryHi] and $FF);
    S.COP0[C0Context] := (S.COP0[C0Context] and $FF800000) or ((Address shr 9) and $007FFFF0);
  end;
  Result := Raise_(I, Code);
end;

procedure TEECPU.FetchFault(PC: Cardinal);
begin
  FSingle[0] := Default(TEEInst);
  FSingle[0].Addr := PC;
  var Code: Cardinal := EEExcTLBL;
  if (PC and 3) <> 0 then
    Code := EEExcAdEL;
  AddressFault(@FSingle[0], PC, Code);
  FStop := 0;
end;

function TEECPU.Translate(I: PEEInst; A: Cardinal; Writing: Boolean; out Phys: Cardinal): Boolean;
begin
  var E := FPhys[A shr 12];
  if (E and PhysValid) = 0 then
  begin
    if Writing then
      Exit(AddressFault(I, A, EEExcTLBS))
    else
      Exit(AddressFault(I, A, EEExcTLBL));
  end;
  if Writing and ((E and PhysDirty) = 0) then
    Exit(AddressFault(I, A, EEExcMod));
  Phys := (E and $FFFFF000) or (A and $FFF);
  Result := False;
end;

function TEECPU.LoadSlow(I: PEEInst; A: Cardinal; Size: Integer; out V: UInt64): Boolean;
begin
  V := 0;
  if (A and Cardinal(Size - 1)) <> 0 then
    Exit(AddressFault(I, A, EEExcAdEL));
  var P := FReadMap[A shr 12];
  if P <> nil then
  begin
    Inc(P, A and $FFF);
    case Size of
      1: V := P^;
      2: V := PWord(P)^;
      4: V := PCardinal(P)^;
    else
      V := PUInt64(P)^;
    end;
    Exit(False);
  end;
  var Phys: Cardinal;
  if Translate(I, A, False, Phys) then
    Exit(True);
  SlowPC := I.Addr;
  V := FBus.Read(Phys, Size);
  Result := False;
end;

function TEECPU.StoreSlow(I: PEEInst; A: Cardinal; Size: Integer; V: UInt64): Boolean;
begin
  if (A and Cardinal(Size - 1)) <> 0 then
    Exit(AddressFault(I, A, EEExcAdES));
  var P := FWriteMap[A shr 12];
  if P <> nil then
  begin
    Inc(P, A and $FFF);
    case Size of
      1: P^ := Byte(V);
      2: PWord(P)^ := Word(V);
      4: PCardinal(P)^ := Cardinal(V);
    else
      PUInt64(P)^ := V;
    end;
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  var Phys: Cardinal;
  if Translate(I, A, True, Phys) then
    Exit(True);
  // ROM and other read-only physical pages ignore stores.
  if FReadMap[A shr 12] = nil then
    FBus.Write(Phys, V, Size);
  Result := FExitRequest;
  if Result then
    FStop := StopLeave;
end;

function TEECPU.Load128(I: PEEInst; A: Cardinal; out V: TPS2Reg128): Boolean;
begin
  A := A and not Cardinal(15);
  var P := FReadMap[A shr 12];
  if P <> nil then
  begin
    V := PPS2Reg128(P + (A and $FFF))^;
    Exit(False);
  end;
  var Phys: Cardinal;
  if Translate(I, A, False, Phys) then
  begin
    V := Default(TPS2Reg128);
    Exit(True);
  end;
  FBus.Read128(Phys, V);
  Result := False;
end;

function TEECPU.Store128(I: PEEInst; A: Cardinal; const V: TPS2Reg128): Boolean;
begin
  A := A and not Cardinal(15);
  var P := FWriteMap[A shr 12];
  if P <> nil then
  begin
    PPS2Reg128(P + (A and $FFF))^ := V;
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  var Phys: Cardinal;
  if Translate(I, A, True, Phys) then
    Exit(True);
  if FReadMap[A shr 12] = nil then
    FBus.Write128(Phys, V);
  Result := FExitRequest;
  if Result then
    FStop := StopLeave;
end;

{ Integer handlers }

function TEECPU.OpNOP(I: PEEInst): Boolean;
begin
  Result := False;
end;

function TEECPU.OpReserved(I: PEEInst): Boolean;
begin
  Result := Raise_(I, EEExcReserved);
end;

function TEECPU.OpFetchFault(I: PEEInst): Boolean;
begin
  Result := AddressFault(I, I.Addr, EEExcTLBL);
end;

function TEECPU.OpSLL(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Cardinal(S.GPR[I.T].Lo) shl I.Sa);
  Result := False;
end;

function TEECPU.OpSRL(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Cardinal(S.GPR[I.T].Lo) shr I.Sa);
  Result := False;
end;

function TEECPU.OpSRA(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Sar32(Cardinal(S.GPR[I.T].Lo), I.Sa));
  Result := False;
end;

function TEECPU.OpSLLV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Cardinal(S.GPR[I.T].Lo) shl (S.GPR[I.S].Lo and 31));
  Result := False;
end;

function TEECPU.OpSRLV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Cardinal(S.GPR[I.T].Lo) shr (S.GPR[I.S].Lo and 31));
  Result := False;
end;

function TEECPU.OpSRAV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Sar32(Cardinal(S.GPR[I.T].Lo), S.GPR[I.S].Lo and 31));
  Result := False;
end;

function TEECPU.OpDSLL(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.T].Lo shl I.Sa;
  Result := False;
end;

function TEECPU.OpDSRL(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.T].Lo shr I.Sa;
  Result := False;
end;

function TEECPU.OpDSRA(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Sar64(S.GPR[I.T].Lo, I.Sa);
  Result := False;
end;

function TEECPU.OpDSLLV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.T].Lo shl (S.GPR[I.S].Lo and 63);
  Result := False;
end;

function TEECPU.OpDSRLV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.T].Lo shr (S.GPR[I.S].Lo and 63);
  Result := False;
end;

function TEECPU.OpDSRAV(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Sar64(S.GPR[I.T].Lo, S.GPR[I.S].Lo and 63);
  Result := False;
end;

function TEECPU.OpJR(I: PEEInst): Boolean;
begin
  FBranchTarget := Cardinal(S.GPR[I.S].Lo);
  FBranchTaken := True;
  Result := False;
end;

function TEECPU.OpJALR(I: PEEInst): Boolean;
begin
  FBranchTarget := Cardinal(S.GPR[I.S].Lo);
  FBranchTaken := True;
  S.GPR[I.D].Lo := SX32(I.Addr + 8);
  Result := False;
end;

function TEECPU.OpMOVZ(I: PEEInst): Boolean;
begin
  if S.GPR[I.T].Lo = 0 then
    S.GPR[I.D].Lo := S.GPR[I.S].Lo;
  Result := False;
end;

function TEECPU.OpMOVN(I: PEEInst): Boolean;
begin
  if S.GPR[I.T].Lo <> 0 then
    S.GPR[I.D].Lo := S.GPR[I.S].Lo;
  Result := False;
end;

function TEECPU.OpSYSCALL(I: PEEInst): Boolean;
begin
  if not Assigned(FOnSyscall) then
  begin
    // SifGetReg (7Ah) is polled: left out.
    if (SyscallLog <> nil) and (SyscallLog.Count < 200000) and ((S.GPR[3].UW[0] <> $7A) or (Now^ > SyscallLogPolledFrom)) then
      SyscallLog.Add(Format('%d syscall %d a0 %.8x a1 %.8x pc %.8x ra %.8x', [Now^ div 4915200,
        Integer(S.GPR[3].UW[0]), S.GPR[4].UW[0], S.GPR[5].UW[0], I.Addr, S.GPR[31].UW[0]]));
    Exit(Raise_(I, EEExcSyscall));
  end;
  if ((I.Flags and IFSlot) <> 0) and FBranchTaken then
    S.PC := FBranchTarget
  else
    S.PC := I.Addr + 4;
  FOnSyscall(Self);
  // The kernel may have changed Status (thread switch, interrupt return).
  UpdateInterrupts;
  FStop := StopPC;
  Result := True;
end;

function TEECPU.OpTrapHLE(I: PEEInst): Boolean;
begin
  if not Assigned(FOnTrap) then
    Exit(Raise_(I, EEExcReserved));
  S.PC := I.Addr + 4;
  FOnTrap(Self, I.Op and $03FFFFFF);
  UpdateInterrupts;
  FStop := StopPC;
  Result := True;
end;

function TEECPU.OpBREAK(I: PEEInst): Boolean;
begin
  Result := Raise_(I, EEExcBreak);
end;

function TEECPU.OpMFHI(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.HI.Lo;
  Result := False;
end;

function TEECPU.OpMTHI(I: PEEInst): Boolean;
begin
  S.HI.Lo := S.GPR[I.S].Lo;
  Result := False;
end;

function TEECPU.OpMFLO(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.LO.Lo;
  Result := False;
end;

function TEECPU.OpMTLO(I: PEEInst): Boolean;
begin
  S.LO.Lo := S.GPR[I.S].Lo;
  Result := False;
end;

function TEECPU.OpMULT(I: PEEInst): Boolean;
begin
  var P := Int64(Integer(Cardinal(S.GPR[I.S].Lo))) * Int64(Integer(Cardinal(S.GPR[I.T].Lo)));
  S.LO.Lo := SX32(UInt64(P));
  S.HI.Lo := SX32(UInt64(P) shr 32);
  S.GPR[I.D].Lo := S.LO.Lo;
  Result := False;
end;

function TEECPU.OpMULTU(I: PEEInst): Boolean;
begin
  var P := UInt64(Cardinal(S.GPR[I.S].Lo)) * Cardinal(S.GPR[I.T].Lo);
  S.LO.Lo := SX32(P);
  S.HI.Lo := SX32(P shr 32);
  S.GPR[I.D].Lo := S.LO.Lo;
  Result := False;
end;

procedure DivideSigned(N, D: Integer; out Lo, Hi: UInt64); inline;
begin
  if D = 0 then
  begin
    Hi := SX32(Cardinal(N));
    if N < 0 then
      Lo := 1
    else
      Lo := UInt64($FFFFFFFFFFFFFFFF);
  end
  else if (N = Low(Integer)) and (D = -1) then
  begin
    Lo := SX32($80000000);
    Hi := 0;
  end
  else
  begin
    Lo := SX32(Cardinal(N div D));
    Hi := SX32(Cardinal(N mod D));
  end;
end;

procedure DivideUnsigned(N, D: Cardinal; out Lo, Hi: UInt64); inline;
begin
  if D = 0 then
  begin
    Lo := UInt64($FFFFFFFFFFFFFFFF);
    Hi := SX32(N);
  end
  else
  begin
    Lo := SX32(N div D);
    Hi := SX32(N mod D);
  end;
end;

function TEECPU.OpDIV(I: PEEInst): Boolean;
begin
  DivideSigned(Integer(Cardinal(S.GPR[I.S].Lo)), Integer(Cardinal(S.GPR[I.T].Lo)), S.LO.Lo, S.HI.Lo);
  Result := False;
end;

function TEECPU.OpDIVU(I: PEEInst): Boolean;
begin
  DivideUnsigned(Cardinal(S.GPR[I.S].Lo), Cardinal(S.GPR[I.T].Lo), S.LO.Lo, S.HI.Lo);
  Result := False;
end;

function TEECPU.OpADD(I: PEEInst): Boolean;
begin
  var Sum := Int64(Integer(Cardinal(S.GPR[I.S].Lo))) + Int64(Integer(Cardinal(S.GPR[I.T].Lo)));
  if (Sum < Low(Integer)) or (Sum > High(Integer)) then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.D].Lo := UInt64(Sum);
  Result := False;
end;

function TEECPU.OpADDU(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Add32(Cardinal(S.GPR[I.S].Lo), Cardinal(S.GPR[I.T].Lo)));
  Result := False;
end;

function TEECPU.OpSUB(I: PEEInst): Boolean;
begin
  var Diff := Int64(Integer(Cardinal(S.GPR[I.S].Lo))) - Int64(Integer(Cardinal(S.GPR[I.T].Lo)));
  if (Diff < Low(Integer)) or (Diff > High(Integer)) then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.D].Lo := UInt64(Diff);
  Result := False;
end;

function TEECPU.OpSUBU(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := SX32(Sub32(Cardinal(S.GPR[I.S].Lo), Cardinal(S.GPR[I.T].Lo)));
  Result := False;
end;

function TEECPU.OpAND(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.S].Lo and S.GPR[I.T].Lo;
  Result := False;
end;

function TEECPU.OpOR(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.S].Lo or S.GPR[I.T].Lo;
  Result := False;
end;

function TEECPU.OpXOR(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.GPR[I.S].Lo xor S.GPR[I.T].Lo;
  Result := False;
end;

function TEECPU.OpNOR(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := not (S.GPR[I.S].Lo or S.GPR[I.T].Lo);
  Result := False;
end;

function TEECPU.OpSLT(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Ord(Int64(S.GPR[I.S].Lo) < Int64(S.GPR[I.T].Lo));
  Result := False;
end;

function TEECPU.OpSLTU(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Ord(S.GPR[I.S].Lo < S.GPR[I.T].Lo);
  Result := False;
end;

function TEECPU.OpDADD(I: PEEInst): Boolean;
begin
  var A := S.GPR[I.S].Lo;
  var B := S.GPR[I.T].Lo;
  var R := Add64(A, B);
  if (((A xor R) and (B xor R)) shr 63) <> 0 then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.D].Lo := R;
  Result := False;
end;

function TEECPU.OpDADDU(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Add64(S.GPR[I.S].Lo, S.GPR[I.T].Lo);
  Result := False;
end;

function TEECPU.OpDSUB(I: PEEInst): Boolean;
begin
  var A := S.GPR[I.S].Lo;
  var B := S.GPR[I.T].Lo;
  var R := Sub64(A, B);
  if (((A xor B) and (A xor R)) shr 63) <> 0 then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.D].Lo := R;
  Result := False;
end;

function TEECPU.OpDSUBU(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := Sub64(S.GPR[I.S].Lo, S.GPR[I.T].Lo);
  Result := False;
end;

function TrapCondition(Kind: Cardinal; A, B: UInt64): Boolean;
begin
  case Kind of
    0: Result := Int64(A) >= Int64(B);
    1: Result := A >= B;
    2: Result := Int64(A) < Int64(B);
    3: Result := A < B;
    4: Result := A = B;
    6: Result := A <> B;
  else
    Result := False;
  end;
end;

function TEECPU.OpTrapR(I: PEEInst): Boolean;
begin
  if TrapCondition(I.Op and 7, S.GPR[I.S].Lo, S.GPR[I.T].Lo) then
    Exit(Raise_(I, EEExcTrap));
  Result := False;
end;

function TEECPU.OpTrapI(I: PEEInst): Boolean;
begin
  if TrapCondition((I.Op shr 16) and 7, S.GPR[I.S].Lo, SX32(I.Imm)) then
    Exit(Raise_(I, EEExcTrap));
  Result := False;
end;

function TEECPU.OpMFSA(I: PEEInst): Boolean;
begin
  S.GPR[I.D].Lo := S.SA;
  Result := False;
end;

function TEECPU.OpMTSA(I: PEEInst): Boolean;
begin
  S.SA := Cardinal(S.GPR[I.S].Lo) and $F;
  Result := False;
end;

function TEECPU.OpMTSAB(I: PEEInst): Boolean;
begin
  S.SA := (Cardinal(S.GPR[I.S].Lo) xor I.Imm) and $F;
  Result := False;
end;

function TEECPU.OpMTSAH(I: PEEInst): Boolean;
begin
  S.SA := ((Cardinal(S.GPR[I.S].Lo) xor I.Imm) and 7) * 2;
  Result := False;
end;

{ Branches: Imm holds the target. }

function TEECPU.OpBLTZ(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) < 0;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBGEZ(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) >= 0;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBLTZL(I: PEEInst): Boolean;
begin
  if Int64(S.GPR[I.S].Lo) < 0 then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBGEZL(I: PEEInst): Boolean;
begin
  if Int64(S.GPR[I.S].Lo) >= 0 then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBLTZAL(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) < 0;
  FBranchTarget := I.Imm;
  S.GPR[31].Lo := SX32(I.Addr + 8);
  Result := False;
end;

function TEECPU.OpBGEZAL(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) >= 0;
  FBranchTarget := I.Imm;
  S.GPR[31].Lo := SX32(I.Addr + 8);
  Result := False;
end;

function TEECPU.OpBLTZALL(I: PEEInst): Boolean;
begin
  var Taken := Int64(S.GPR[I.S].Lo) < 0;
  S.GPR[31].Lo := SX32(I.Addr + 8);
  if Taken then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBGEZALL(I: PEEInst): Boolean;
begin
  var Taken := Int64(S.GPR[I.S].Lo) >= 0;
  S.GPR[31].Lo := SX32(I.Addr + 8);
  if Taken then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpJ(I: PEEInst): Boolean;
begin
  FBranchTaken := True;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpJAL(I: PEEInst): Boolean;
begin
  FBranchTaken := True;
  FBranchTarget := I.Imm;
  S.GPR[31].Lo := SX32(I.Addr + 8);
  Result := False;
end;

function TEECPU.OpBEQ(I: PEEInst): Boolean;
begin
  FBranchTaken := S.GPR[I.S].Lo = S.GPR[I.T].Lo;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBNE(I: PEEInst): Boolean;
begin
  FBranchTaken := S.GPR[I.S].Lo <> S.GPR[I.T].Lo;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBLEZ(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) <= 0;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBGTZ(I: PEEInst): Boolean;
begin
  FBranchTaken := Int64(S.GPR[I.S].Lo) > 0;
  FBranchTarget := I.Imm;
  Result := False;
end;

function TEECPU.OpBEQL(I: PEEInst): Boolean;
begin
  if S.GPR[I.S].Lo = S.GPR[I.T].Lo then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBNEL(I: PEEInst): Boolean;
begin
  if S.GPR[I.S].Lo <> S.GPR[I.T].Lo then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBLEZL(I: PEEInst): Boolean;
begin
  if Int64(S.GPR[I.S].Lo) <= 0 then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

function TEECPU.OpBGTZL(I: PEEInst): Boolean;
begin
  if Int64(S.GPR[I.S].Lo) > 0 then
  begin
    FBranchTaken := True;
    FBranchTarget := I.Imm;
    Exit(False);
  end;
  FStop := StopSkip;
  Result := True;
end;

{ Immediate arithmetic: Imm is sign-extended to 32 bits, zero-extended for
  the logical operations, shifted for LUI. }

function TEECPU.OpADDI(I: PEEInst): Boolean;
begin
  var Sum := Int64(Integer(Cardinal(S.GPR[I.S].Lo))) + Int64(Integer(I.Imm));
  if (Sum < Low(Integer)) or (Sum > High(Integer)) then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.T].Lo := UInt64(Sum);
  Result := False;
end;

function TEECPU.OpADDIU(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := SX32(Add32(Cardinal(S.GPR[I.S].Lo), I.Imm));
  Result := False;
end;

function TEECPU.OpSLTI(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := Ord(Int64(S.GPR[I.S].Lo) < Int64(Integer(I.Imm)));
  Result := False;
end;

function TEECPU.OpSLTIU(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := Ord(S.GPR[I.S].Lo < SX32(I.Imm));
  Result := False;
end;

function TEECPU.OpANDI(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := S.GPR[I.S].Lo and I.Imm;
  Result := False;
end;

function TEECPU.OpORI(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := S.GPR[I.S].Lo or I.Imm;
  Result := False;
end;

function TEECPU.OpXORI(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := S.GPR[I.S].Lo xor I.Imm;
  Result := False;
end;

function TEECPU.OpLUI(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := SX32(I.Imm);
  Result := False;
end;

function TEECPU.OpDADDI(I: PEEInst): Boolean;
begin
  var A := S.GPR[I.S].Lo;
  var B := SX32(I.Imm);
  var R := Add64(A, B);
  if (((A xor R) and (B xor R)) shr 63) <> 0 then
    Exit(Raise_(I, EEExcOverflow));
  S.GPR[I.T].Lo := R;
  Result := False;
end;

function TEECPU.OpDADDIU(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := Add64(S.GPR[I.S].Lo, SX32(I.Imm));
  Result := False;
end;

{ Loads and stores }

function TEECPU.OpLB(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if P <> nil then
  begin
    S.GPR[I.T].Lo := SX8(P[A and $FFF]);
    Exit(False);
  end;
  Result := LoadSlow(I, A, 1, V);
  if not Result then
    S.GPR[I.T].Lo := SX8(V);
end;

function TEECPU.OpLBU(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if P <> nil then
  begin
    S.GPR[I.T].Lo := P[A and $FFF];
    Exit(False);
  end;
  Result := LoadSlow(I, A, 1, V);
  if not Result then
    S.GPR[I.T].Lo := Byte(V);
end;

function TEECPU.OpLH(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 1) = 0) then
  begin
    S.GPR[I.T].Lo := SX16(PWord(P + (A and $FFF))^);
    Exit(False);
  end;
  Result := LoadSlow(I, A, 2, V);
  if not Result then
    S.GPR[I.T].Lo := SX16(V);
end;

function TEECPU.OpLHU(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 1) = 0) then
  begin
    S.GPR[I.T].Lo := PWord(P + (A and $FFF))^;
    Exit(False);
  end;
  Result := LoadSlow(I, A, 2, V);
  if not Result then
    S.GPR[I.T].Lo := Word(V);
end;

function TEECPU.OpLW(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    S.GPR[I.T].Lo := SX32(PCardinal(P + (A and $FFF))^);
    Exit(False);
  end;
  Result := LoadSlow(I, A, 4, V);
  if not Result then
    S.GPR[I.T].Lo := SX32(V);
end;

function TEECPU.OpLWU(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    S.GPR[I.T].Lo := PCardinal(P + (A and $FFF))^;
    Exit(False);
  end;
  Result := LoadSlow(I, A, 4, V);
  if not Result then
    S.GPR[I.T].Lo := Cardinal(V);
end;

function TEECPU.OpLD(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 7) = 0) then
  begin
    S.GPR[I.T].Lo := PUInt64(P + (A and $FFF))^;
    Exit(False);
  end;
  Result := LoadSlow(I, A, 8, V);
  if not Result then
    S.GPR[I.T].Lo := V;
end;

function TEECPU.OpLQ(I: PEEInst): Boolean;
var
  V: TPS2Reg128;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm) and not Cardinal(15);
  var P := FReadMap[A shr 12];
  if P <> nil then
  begin
    S.GPR[I.T] := PPS2Reg128(P + (A and $FFF))^;
    Exit(False);
  end;
  Result := Load128(I, A, V);
  if not Result then
    S.GPR[I.T] := V;
end;

const
  LWLMask: array[0..3] of Cardinal = ($00FFFFFF, $0000FFFF, $000000FF, $00000000);
  LWRMask: array[0..3] of Cardinal = ($00000000, $FF000000, $FFFF0000, $FFFFFF00);
  SWLMask: array[0..3] of Cardinal = ($FFFFFF00, $FFFF0000, $FF000000, $00000000);
  SWRMask: array[0..3] of Cardinal = ($00000000, $000000FF, $0000FFFF, $00FFFFFF);

function TEECPU.OpLWL(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  Result := LoadSlow(I, A and not Cardinal(3), 4, V);
  if Result then
    Exit;
  var Shift := A and 3;
  var R := (Cardinal(S.GPR[I.T].Lo) and LWLMask[Shift]) or (Cardinal(V) shl (24 - Shift * 8));
  S.GPR[I.T].Lo := SX32(R);
end;

function TEECPU.OpLWR(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  Result := LoadSlow(I, A and not Cardinal(3), 4, V);
  if Result then
    Exit;
  var Shift := A and 3;
  var R := (Cardinal(S.GPR[I.T].Lo) and LWRMask[Shift]) or (Cardinal(V) shr (Shift * 8));
  if Shift = 0 then
    S.GPR[I.T].Lo := SX32(R)
  else
    S.GPR[I.T].Lo := (S.GPR[I.T].Lo and $FFFFFFFF00000000) or R;
end;

function TEECPU.OpLDL(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  Result := LoadSlow(I, A and not Cardinal(7), 8, V);
  if Result then
    Exit;
  var Shift := A and 7;
  S.GPR[I.T].Lo := (S.GPR[I.T].Lo and (UInt64($00FFFFFFFFFFFFFF) shr (Shift * 8))) or (V shl (56 - Shift * 8));
end;

function TEECPU.OpLDR(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  Result := LoadSlow(I, A and not Cardinal(7), 8, V);
  if Result then
    Exit;
  var Shift := A and 7;
  var Mask: UInt64 := 0;
  if Shift <> 0 then
    Mask := UInt64($FFFFFFFFFFFFFFFF) shl (64 - Shift * 8);
  S.GPR[I.T].Lo := (S.GPR[I.T].Lo and Mask) or (V shr (Shift * 8));
end;

function TEECPU.OpSB(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FWriteMap[A shr 12];
  if P <> nil then
  begin
    P[A and $FFF] := Byte(S.GPR[I.T].Lo);
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := StoreSlow(I, A, 1, S.GPR[I.T].Lo);
end;

function TEECPU.OpSH(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FWriteMap[A shr 12];
  if (P <> nil) and ((A and 1) = 0) then
  begin
    PWord(P + (A and $FFF))^ := Word(S.GPR[I.T].Lo);
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := StoreSlow(I, A, 2, S.GPR[I.T].Lo);
end;

function TEECPU.OpSW(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FWriteMap[A shr 12];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    PCardinal(P + (A and $FFF))^ := Cardinal(S.GPR[I.T].Lo);
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := StoreSlow(I, A, 4, S.GPR[I.T].Lo);
end;

function TEECPU.OpSD(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FWriteMap[A shr 12];
  if (P <> nil) and ((A and 7) = 0) then
  begin
    PUInt64(P + (A and $FFF))^ := S.GPR[I.T].Lo;
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := StoreSlow(I, A, 8, S.GPR[I.T].Lo);
end;

function TEECPU.OpSQ(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm) and not Cardinal(15);
  var P := FWriteMap[A shr 12];
  if P <> nil then
  begin
    PPS2Reg128(P + (A and $FFF))^ := S.GPR[I.T];
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := Store128(I, A, S.GPR[I.T]);
end;

function TEECPU.OpSWL(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var Base := A and not Cardinal(3);
  if (FPhys[Base shr 12] and PhysValid) = 0 then
    Exit(AddressFault(I, A, EEExcTLBS));
  Result := LoadSlow(I, Base, 4, V);
  if Result then
    Exit;
  var Shift := A and 3;
  var M := (Cardinal(S.GPR[I.T].Lo) shr (24 - Shift * 8)) or (Cardinal(V) and SWLMask[Shift]);
  Result := StoreSlow(I, Base, 4, M);
end;

function TEECPU.OpSWR(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var Base := A and not Cardinal(3);
  if (FPhys[Base shr 12] and PhysValid) = 0 then
    Exit(AddressFault(I, A, EEExcTLBS));
  Result := LoadSlow(I, Base, 4, V);
  if Result then
    Exit;
  var Shift := A and 3;
  var M := (Cardinal(S.GPR[I.T].Lo) shl (Shift * 8)) or (Cardinal(V) and SWRMask[Shift]);
  Result := StoreSlow(I, Base, 4, M);
end;

function TEECPU.OpSDL(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var Base := A and not Cardinal(7);
  if (FPhys[Base shr 12] and PhysValid) = 0 then
    Exit(AddressFault(I, A, EEExcTLBS));
  Result := LoadSlow(I, Base, 8, V);
  if Result then
    Exit;
  var Shift := A and 7;
  var Mask: UInt64 := 0;
  if Shift < 7 then
    Mask := UInt64($FFFFFFFFFFFFFFFF) shl ((Shift + 1) * 8);
  var M := (S.GPR[I.T].Lo shr (56 - Shift * 8)) or (V and Mask);
  Result := StoreSlow(I, Base, 8, M);
end;

function TEECPU.OpSDR(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var Base := A and not Cardinal(7);
  if (FPhys[Base shr 12] and PhysValid) = 0 then
    Exit(AddressFault(I, A, EEExcTLBS));
  Result := LoadSlow(I, Base, 8, V);
  if Result then
    Exit;
  var Shift := A and 7;
  var Mask: UInt64 := 0;
  if Shift > 0 then
    Mask := UInt64($FFFFFFFFFFFFFFFF) shr (64 - Shift * 8);
  var M := (S.GPR[I.T].Lo shl (Shift * 8)) or (V and Mask);
  Result := StoreSlow(I, Base, 8, M);
end;

function TEECPU.OpLWC1(I: PEEInst): Boolean;
var
  V: UInt64;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FReadMap[A shr 12];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    S.FPR[I.Op shr 16 and 31] := PCardinal(P + (A and $FFF))^;
    Exit(False);
  end;
  Result := LoadSlow(I, A, 4, V);
  if not Result then
    S.FPR[I.Op shr 16 and 31] := Cardinal(V);
end;

function TEECPU.OpSWC1(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  var P := FWriteMap[A shr 12];
  if (P <> nil) and ((A and 3) = 0) then
  begin
    PCardinal(P + (A and $FFF))^ := S.FPR[I.Op shr 16 and 31];
    Inc(FGenMap[A shr 12]^);
    Exit(False);
  end;
  Result := StoreSlow(I, A, 4, S.FPR[I.Op shr 16 and 31]);
end;

function TEECPU.OpLQC2(I: PEEInst): Boolean;
var
  V: TPS2Reg128;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  Result := Load128(I, A, V);
  if not Result and ((I.Op shr 16 and 31) <> 0) then
  begin
    FCop2.Sync;
    FCop2.VF[I.Op shr 16 and 31] := V;
    FCop2.VFWritten := FCop2.VFWritten or (Cardinal(1) shl (I.Op shr 16 and 31));
  end;
end;

function TEECPU.OpSQC2(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
  FCop2.Sync;
  Result := Store128(I, A, FCop2.VF[I.Op shr 16 and 31]);
end;

{ COP0 }

function TEECPU.PerfCounter(Which: Integer): Cardinal;
begin
  // Counters with event 1 (processor cycles) in any enabled mode count EE
  // cycles while PCCR.CTE is set.
  var Base := S.PCR0;
  var Ctl := S.PCCR;
  var Events := (Ctl shr 5) and $1F;
  var Modes := (Ctl shr 1) and $F;
  if Which = 1 then
  begin
    Base := S.PCR1;
    Events := (Ctl shr 15) and $1F;
    Modes := (Ctl shr 11) and $F;
  end;
  Result := Base;
  if ((Ctl and $80000000) <> 0) and (Events = 1) and (Modes <> 0) then
    Result := Cardinal(UInt64(Base) + UInt64(Now^ - S.PerfBase));
end;

procedure TEECPU.SetPerfCounter(Which: Integer; Value: Cardinal);
begin
  // Rebase the other counter to its current value.
  var Other := PerfCounter(1 - Which);
  if Which = 0 then
  begin
    S.PCR0 := Value;
    S.PCR1 := Other;
  end
  else
  begin
    S.PCR1 := Value;
    S.PCR0 := Other;
  end;
  S.PerfBase := Now^;
end;

function TEECPU.ReadCOP0(Index: Integer; Op: Cardinal): Cardinal;
begin
  case Index of
    C0Count: Result := GetCount;
    C0Debug: Result := 0;
    C0Perf:
      if (Op and 1) = 0 then
        Result := S.PCCR
      else
        Result := PerfCounter(Integer((Op shr 1) and 1));
  else
    Result := S.COP0[Index];
  end;
end;

procedure TEECPU.WriteCOP0(Index: Integer; Op, Value: Cardinal);
begin
  case Index of
    C0Index: S.COP0[C0Index] := Value and $8000003F;
    C0EntryLo0: S.COP0[C0EntryLo0] := Value and $8FFFFFFF;
    C0EntryLo1: S.COP0[C0EntryLo1] := Value and $0FFFFFFF;
    C0Context: S.COP0[C0Context] := (S.COP0[C0Context] and $007FFFF0) or (Value and $FF800000);
    C0PageMask: S.COP0[C0PageMask] := Value and $01FFE000;
    C0Wired: S.COP0[C0Wired] := Value and $3F;
    C0Count: S.CountBase := Now^ - Int64(Value);
    C0EntryHi: S.COP0[C0EntryHi] := Value and $FFFFE0FF;
    C0Compare:
      begin
        S.COP0[C0Compare] := Value;
        S.COP0[C0Cause] := S.COP0[C0Cause] and not Cardinal(EECauseIP7);
        UpdateInterrupts;
        FExitRequest := True;
      end;
    C0Status:
      begin
        S.COP0[C0Status] := Value and $F07BFC1F;
        UpdateInterrupts;
      end;
    C0Cause:
      begin
        S.COP0[C0Cause] := (S.COP0[C0Cause] and not Cardinal($300)) or (Value and $300);
        UpdateInterrupts;
      end;
    C0EPC, C0ErrorEPC, C0TagLo, C0TagHi, C0BadPAddr:
      S.COP0[Index] := Value;
    C0Config: S.COP0[C0Config] := (S.COP0[C0Config] and not Cardinal($7007)) or (Value and $7007);
    C0Debug: ;
    C0Perf:
      if (Op and 1) = 0 then
      begin
        if ((Op shr 1) and $1F) = 0 then
        begin
          var C0 := PerfCounter(0);
          var C1 := PerfCounter(1);
          S.PCR0 := C0;
          S.PCR1 := C1;
          S.PerfBase := Now^;
          S.PCCR := Value and $800FFBFE;
        end;
      end
      else
        SetPerfCounter(Integer((Op shr 1) and 1), Value);
  end;
end;

function TEECPU.OpCOP0(I: PEEInst): Boolean;
begin
  var Op := I.Op;
  var Rd := Integer((Op shr 11) and 31);
  case (Op shr 21) and 31 of
    0:
      S.GPR[I.T].Lo := SX32(ReadCOP0(Rd, Op));
    4:
      WriteCOP0(Rd, Op, Cardinal(S.GPR[I.T].Lo));
    16..31:
      case Op and $3F of
        1:
          begin
            var E := S.TLB[(S.COP0[C0Index] and 63) mod 48];
            S.COP0[C0PageMask] := E.PageMask;
            S.COP0[C0EntryHi] := E.EntryHi;
            S.COP0[C0EntryLo0] := E.EntryLo0;
            S.COP0[C0EntryLo1] := E.EntryLo1;
          end;
        2, 6:
          begin
            var E: TEETLBEntry;
            E.PageMask := S.COP0[C0PageMask];
            E.EntryHi := S.COP0[C0EntryHi];
            E.EntryLo0 := S.COP0[C0EntryLo0];
            E.EntryLo1 := S.COP0[C0EntryLo1];
            var Index := Integer(S.COP0[C0Index] and 63) mod 48;
            if (Op and $3F) = 6 then
            begin
              var R := Integer(S.COP0[C0Random]);
              if (R <= Integer(S.COP0[C0Wired])) or (R > 47) then
                R := 47
              else
                Dec(R);
              S.COP0[C0Random] := Cardinal(R);
              Index := R;
            end;
            WriteTLB(Index, E);
          end;
        8:
          begin
            var Found: Cardinal := $80000000;
            for var K := 0 to 47 do
            begin
              var Mask := S.TLB[K].PageMask or $1FFF;
              if ((S.TLB[K].EntryHi xor S.COP0[C0EntryHi]) and not Mask and $FFFFE000) = 0 then
              begin
                Found := Cardinal(K);
                Break;
              end;
            end;
            S.COP0[C0Index] := Found;
          end;
      end;
  end;
  FStop := StopLeave;
  Result := True;
end;

function TEECPU.OpERET(I: PEEInst): Boolean;
begin
  var SR := S.COP0[C0Status];
  if (SR and EESRERL) <> 0 then
  begin
    S.PC := S.COP0[C0ErrorEPC];
    S.COP0[C0Status] := SR and not Cardinal(EESRERL);
  end
  else
  begin
    S.PC := S.COP0[C0EPC];
    S.COP0[C0Status] := SR and not Cardinal(EESREXL);
  end;
  UpdateInterrupts;
  FStop := StopPC;
  Result := True;
end;

function TEECPU.OpEI(I: PEEInst): Boolean;
begin
  var SR := S.COP0[C0Status];
  if ((SR and (EESREXL or EESRERL)) <> 0) or ((SR and EESRKSU) = 0) or ((SR and EESREDI) <> 0) then
    S.COP0[C0Status] := SR or EESREIE;
  UpdateInterrupts;
  FStop := StopLeave;
  Result := True;
end;

function TEECPU.OpDI(I: PEEInst): Boolean;
begin
  var SR := S.COP0[C0Status];
  if ((SR and (EESREXL or EESRERL)) <> 0) or ((SR and EESRKSU) = 0) or ((SR and EESREDI) <> 0) then
    S.COP0[C0Status] := SR and not Cardinal(EESREIE);
  UpdateInterrupts;
  Result := False;
end;

function TEECPU.OpBC0(I: PEEInst): Boolean;
begin
  var Cond := FBus.CPCond0;
  if (I.Op and $10000) = 0 then
    Cond := not Cond;
  if (I.Op and $20000) <> 0 then
  begin
    if not Cond then
    begin
      FStop := StopSkip;
      Exit(True);
    end;
  end;
  FBranchTaken := Cond;
  FBranchTarget := I.Imm;
  Result := False;
end;

{ COP1: S = fs, T = ft (or the GPR rt for transfers), D = fd. }

// D was computed with the host rounding toward zero; the 24-bit result
// truncates its 53-bit mantissa, which composes to the same truncation.
function TEECPU.FPUResult(D: Double; Overflow, Underflow: Cardinal): Cardinal;
begin
  var B := PUInt64(@D)^;
  var Sign := Cardinal(B shr 32) and $80000000;
  if (B and $7FFFFFFFFFFFFFFF) = 0 then
    Exit(Sign);
  var E := Integer((B shr 52) and $7FF) - (1023 - 127);
  if E > 255 then
  begin
    S.FCR31 := S.FCR31 or Overflow;
    Exit(Sign or $7FFFFFFF);
  end;
  if E <= 0 then
  begin
    S.FCR31 := S.FCR31 or Underflow;
    Exit(Sign);
  end;
  Result := Sign or (Cardinal(E) shl 23) or (Cardinal(B shr 29) and $7FFFFF);
end;

// DIV.S, SQRT.S and the steps of RSQRT.S round to nearest, unlike the
// truncating adder and multiplier (hardware results in ps2autotests'
// cpu/ee_fpu). A quotient or root of 24-bit values is never exactly halfway
// and lies far enough from it that the host double, in any rounding mode,
// has the right first dropped bit; that bit decides. No O/U flags are set.
function PS2FloatNearest(D: Double): Cardinal;
begin
  var B := PUInt64(@D)^;
  var Sign := Cardinal(B shr 32) and $80000000;
  if (B and $7FFFFFFFFFFFFFFF) = 0 then
    Exit(Sign);
  var E := Integer((B shr 52) and $7FF) - (1023 - 127);
  if E > 255 then
    Exit(Sign or $7FFFFFFF);
  if E <= 0 then
    Exit(Sign);
  var Bits := (Cardinal(E) shl 23) or (Cardinal(B shr 29) and $7FFFFF);
  if (B and (UInt64(1) shl 28)) <> 0 then
    if Bits = $7FFFFFFF then
      Bits := $7FFFFFFF  // exponent 255 is the top of the range: saturate
    else
      Inc(Bits);         // a mantissa carry correctly raises the exponent
  Result := Sign or Bits;
end;

function TEECPU.FPUDivide(A, B: Cardinal): Cardinal;
begin
  Result := PS2FloatNearest(EEFloatIn(A) / EEFloatIn(B));
end;

// The square root of |V|; zero and exponent-zero inputs give +0.
function TEECPU.FPURoot(V: Cardinal): Cardinal;
begin
  if (V and $7F800000) = 0 then
    Exit(0);
  Result := PS2FloatNearest(Sqrt(EEFloatIn(V and $7FFFFFFF)));
end;

function TEECPU.FAdd(A, B: Cardinal): Cardinal;
var
  Flags: Cardinal;
begin
  Result := PS2FloatAdd(A, B, Flags);
  if (Flags and 1) <> 0 then
    S.FCR31 := S.FCR31 or FCROverflow or FCRStickyOverflow
  else if (Flags and 2) <> 0 then
    S.FCR31 := S.FCR31 or FCRUnderflow or FCRStickyUnderflow;
end;

function TEECPU.OpMFC1(I: PEEInst): Boolean;
begin
  S.GPR[I.T].Lo := SX32(S.FPR[I.S]);
  Result := False;
end;

function TEECPU.OpMTC1(I: PEEInst): Boolean;
begin
  S.FPR[I.S] := Cardinal(S.GPR[I.T].Lo);
  Result := False;
end;

function TEECPU.OpCFC1(I: PEEInst): Boolean;
begin
  // FCR0 answers for 0..15, FCR31 for 16..31.
  if I.S >= 16 then
    S.GPR[I.T].Lo := SX32(S.FCR31)
  else
    S.GPR[I.T].Lo := $2E30;
  Result := False;
end;

function TEECPU.OpCTC1(I: PEEInst): Boolean;
begin
  if I.S >= 16 then
    S.FCR31 := (Cardinal(S.GPR[I.T].Lo) and $0083C078) or $01000001;
  Result := False;
end;

function TEECPU.OpBC1(I: PEEInst): Boolean;
begin
  var Cond := (S.FCR31 and FCRCondition) <> 0;
  if (I.Op and $10000) = 0 then
    Cond := not Cond;
  if (I.Op and $20000) <> 0 then
  begin
    if not Cond then
    begin
      FStop := StopSkip;
      Exit(True);
    end;
  end;
  FBranchTaken := Cond;
  FBranchTarget := I.Imm;
  Result := False;
end;

const
  FlagsOU = FCROverflow or FCRUnderflow;
  SetO = FCROverflow or FCRStickyOverflow;
  SetU = FCRUnderflow or FCRStickyUnderflow;

function TEECPU.OpFADD(I: PEEInst): Boolean;
begin
  S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
  S.FPR[I.D] := FAdd(S.FPR[I.S], S.FPR[I.T]);
  Result := False;
end;

function TEECPU.OpFMUL(I: PEEInst): Boolean;
begin
  S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
  var Fs := S.FPR[I.S];
  var Ft := S.FPR[I.T];
  var P := FPUResult(EEFloatIn(Fs) * EEFloatIn(Ft), SetO, SetU);
  if PS2MulLosesBit(Fs, Ft) then
    Dec(P);
  S.FPR[I.D] := P;
  Result := False;
end;

function TEECPU.OpFMOV(I: PEEInst): Boolean;
begin
  S.FPR[I.D] := S.FPR[I.S];
  Result := False;
end;

function PS2FloatKey(V: Cardinal): Integer;
begin
  if (V and $80000000) <> 0 then
    Result := -Integer(V and $7FFFFFFF) - 1
  else
    Result := Integer(V);
end;

function TEECPU.MultiplyAdd(I: PEEInst; Op: Cardinal): Boolean;
begin
  S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
  var P := FPUResult(EEFloatIn(S.FPR[I.S]) * EEFloatIn(S.FPR[I.T]), SetO, SetU);
  if PS2MulLosesBit(S.FPR[I.S], S.FPR[I.T]) then
    Dec(P);
  if (Op and 1) <> 0 then
    P := P xor $80000000;
  var R: Cardinal;
  // An overflowing product is the result itself; ACC is not added to it
  // (ps2autotests cpu/ee_fpu muldiv on hardware).
  if (S.FCR31 and FCROverflow) <> 0 then
    R := P
  else
    R := FAdd(S.ACC, P);
  if (Op and 2) <> 0 then
    S.ACC := R
  else
    S.FPR[I.D] := R;
  Result := False;
end;

function TEECPU.OpFPU(I: PEEInst): Boolean;
begin
  var Op := I.Op;
  var Fs := S.FPR[I.S];
  var Ft := S.FPR[I.T];
  if ((Op shr 21) and 31) = $14 then
  begin
    // CVT.S.W
    if (Op and $3F) = $20 then
      S.FPR[I.D] := FPUResult(Integer(Fs), 0, 0)
    else
      Exit(Raise_(I, EEExcReserved));
    Exit(False);
  end;
  case Op and $3F of
    $00: Exit(OpFADD(I));
    $01:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
        S.FPR[I.D] := FAdd(Fs, Ft xor $80000000);
      end;
    $02: Exit(OpFMUL(I));
    $03:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FCRInvalid or FCRDivide);
        if (Ft and $7F800000) = 0 then
        begin
          if (Fs and $7F800000) = 0 then
            S.FCR31 := S.FCR31 or FCRInvalid or FCRStickyInvalid
          else
            S.FCR31 := S.FCR31 or FCRDivide or FCRStickyDivide;
          S.FPR[I.D] := ((Fs xor Ft) and $80000000) or $7FFFFFFF;
        end
        else
          S.FPR[I.D] := FPUDivide(Fs, Ft);
      end;
    $04:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FCRInvalid or FCRDivide);
        if ((Ft and $7F800000) <> 0) and ((Ft and $80000000) <> 0) then
          S.FCR31 := S.FCR31 or FCRInvalid or FCRStickyInvalid;
        S.FPR[I.D] := FPURoot(Ft);
      end;
    $05:
      begin
        S.FPR[I.D] := Fs and $7FFFFFFF;
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
      end;
    $06: S.FPR[I.D] := Fs;
    $07:
      begin
        S.FPR[I.D] := Fs xor $80000000;
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
      end;
    $16:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FCRInvalid or FCRDivide);
        if (Ft and $7F800000) = 0 then
        begin
          S.FCR31 := S.FCR31 or FCRDivide or FCRStickyDivide;
          S.FPR[I.D] := (Fs and $80000000) or $7FFFFFFF;
        end
        else
        begin
          if (Ft and $80000000) <> 0 then
            S.FCR31 := S.FCR31 or FCRInvalid or FCRStickyInvalid;
          // Fs times the reciprocal of the root: the root and reciprocal
          // round to nearest, the product truncates like MUL.S. This model
          // reproduces every hardware result in ps2autotests' sqrt test.
          S.FPR[I.D] := FPUResult(EEFloatIn(Fs) * EEFloatIn(FPUDivide($3F800000, FPURoot(Ft))), 0, 0);
        end;
      end;
    $18:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
        S.ACC := FAdd(Fs, Ft);
      end;
    $19:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
        S.ACC := FAdd(Fs, Ft xor $80000000);
      end;
    $1A:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
        S.ACC := FPUResult(EEFloatIn(Fs) * EEFloatIn(Ft), SetO, SetU);
        if PS2MulLosesBit(Fs, Ft) then
          Dec(S.ACC);
      end;
    $1C: Exit(MultiplyAdd(I, 0));
    $1D: Exit(MultiplyAdd(I, 1));
    $1E: Exit(MultiplyAdd(I, 2));
    $1F: Exit(MultiplyAdd(I, 3));
    $24:
      begin
        if ((Fs shr 23) and $FF) >= $9E then
        begin
          if (Fs and $80000000) <> 0 then
            S.FPR[I.D] := $80000000
          else
            S.FPR[I.D] := $7FFFFFFF;
        end
        else
          S.FPR[I.D] := Cardinal(Integer(Trunc(EEFloatIn(Fs))));
      end;
    $28:
      begin
        if PS2FloatKey(Fs) >= PS2FloatKey(Ft) then
          S.FPR[I.D] := Fs
        else
          S.FPR[I.D] := Ft;
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
      end;
    $29:
      begin
        if PS2FloatKey(Fs) <= PS2FloatKey(Ft) then
          S.FPR[I.D] := Fs
        else
          S.FPR[I.D] := Ft;
        S.FCR31 := S.FCR31 and not Cardinal(FlagsOU);
      end;
    $30: S.FCR31 := S.FCR31 and not Cardinal(FCRCondition);
    $32, $34, $36:
      begin
        var A := EEFloatIn(Fs);
        var B := EEFloatIn(Ft);
        var C: Boolean;
        case Op and $3F of
          $32: C := A = B;
          $34: C := A < B;
        else
          C := A <= B;
        end;
        if C then
          S.FCR31 := S.FCR31 or FCRCondition
        else
          S.FCR31 := S.FCR31 and not Cardinal(FCRCondition);
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  Result := False;
end;

{ COP2 transfers }

function TEECPU.OpCOP2(I: PEEInst): Boolean;
begin
  var Op := I.Op;
  var Fs := Integer((Op shr 11) and 31);
  case (Op shr 21) and 31 of
    1:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock
        else
          FCop2.Sync;
        S.GPR[I.T] := FCop2.VF[Fs];
      end;
    2:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock
        else
          FCop2.Sync;
        S.GPR[I.T].Lo := SX32(FCop2.ReadControl(Fs));
      end;
    5:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock
        else
          FCop2.Sync;
        if Fs <> 0 then
        begin
          FCop2.VF[Fs] := S.GPR[I.T];
          FCop2.VFWritten := FCop2.VFWritten or (Cardinal(1) shl Fs);
        end;
      end;
    6:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock
        else
          FCop2.Sync;
        FCop2.WriteControl(Fs, Cardinal(S.GPR[I.T].Lo));
        FStop := StopLeave;
        Exit(True);
      end;
    8:
      begin
        FCop2.Sync;
        var Cond := FCop2.Condition;
        if (Op and $10000) = 0 then
          Cond := not Cond;
        if ((Op and $20000) <> 0) and not Cond then
        begin
          FStop := StopSkip;
          Exit(True);
        end;
        FBranchTaken := Cond;
        FBranchTarget := I.Imm;
      end;
    16..31:
      begin
        if not FCop2.Execute(Op) then
          Exit(Raise_(I, EEExcReserved));
        if FExitRequest then
        begin
          FStop := StopLeave;
          Exit(True);
        end;
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  Result := False;
end;

{ MMI }

function SatS32(V: Int64): Cardinal; inline;
begin
  if V > High(Integer) then
    Result := $7FFFFFFF
  else if V < Low(Integer) then
    Result := $80000000
  else
    Result := Cardinal(Integer(V));
end;

function SatS16(V: Integer): Word; inline;
begin
  if V > 32767 then
    Result := $7FFF
  else if V < -32768 then
    Result := $8000
  else
    Result := Word(V);
end;

function SatS8(V: Integer): Byte; inline;
begin
  if V > 127 then
    Result := $7F
  else if V < -128 then
    Result := $80
  else
    Result := Byte(V);
end;

function LeadingSign(V: Cardinal): Cardinal;
begin
  if Integer(V) < 0 then
    V := not V;
  Result := 0;
  var Bit: Cardinal := $40000000;
  while (Bit <> 0) and ((V and Bit) = 0) do
  begin
    Inc(Result);
    Bit := Bit shr 1;
  end;
end;

procedure WordMulAcc(var Hi, Lo: UInt64; A, B: Integer; Accumulate, Subtract: Boolean; out Full: UInt64);
begin
  var P := Int64(A) * Int64(B);
  if Accumulate then
  begin
    var Acc := Int64((UInt64(Cardinal(Hi)) shl 32) or Cardinal(Lo));
    if Subtract then
      P := Int64(Sub64(UInt64(Acc), UInt64(P)))
    else
      P := Int64(Add64(UInt64(Acc), UInt64(P)));
  end;
  Lo := SX32(UInt64(P));
  Hi := SX32(UInt64(P) shr 32);
  Full := UInt64(P);
end;

function TEECPU.OpMMIKernel(I: PEEInst): Boolean;
begin
  EEMMIKernels[I.Imm].Kernel(@S.GPR[I.S], @S.GPR[I.T], @S.GPR[I.D], I.Sa);
  Result := False;
end;

function TEECPU.OpMMI(I: PEEInst): Boolean;
var
  R: TPS2Reg128;
begin
  var A := S.GPR[I.S];
  var B := S.GPR[I.T];
  case I.Op and $3F of
    $00, $01, $20, $21:
      begin
        var P: UInt64;
        if (I.Op and 1) = 0 then
          P := UInt64(Int64(Integer(A.UW[0])) * Int64(Integer(B.UW[0])))
        else
          P := UInt64(A.UW[0]) * B.UW[0];
        if (I.Op and $20) = 0 then
        begin
          var Acc := (UInt64(Cardinal(S.HI.Lo)) shl 32) or Cardinal(S.LO.Lo);
          Acc := Add64(Acc, P);
          S.LO.Lo := SX32(Acc);
          S.HI.Lo := SX32(Acc shr 32);
          S.GPR[I.D].Lo := S.LO.Lo;
        end
        else
        begin
          var Acc := (UInt64(Cardinal(S.HI.Hi)) shl 32) or Cardinal(S.LO.Hi);
          Acc := Add64(Acc, P);
          S.LO.Hi := SX32(Acc);
          S.HI.Hi := SX32(Acc shr 32);
          S.GPR[I.D].Lo := S.LO.Hi;
        end;
      end;
    $04:
      begin
        S.GPR[I.D].UW[0] := LeadingSign(A.UW[0]);
        S.GPR[I.D].UW[1] := LeadingSign(A.UW[1]);
      end;
    $08: Exit(OpMMI0(I));
    $09: Exit(OpMMI2(I));
    $10: S.GPR[I.D].Lo := S.HI.Hi;
    $11: S.HI.Hi := A.Lo;
    $12: S.GPR[I.D].Lo := S.LO.Hi;
    $13: S.LO.Hi := A.Lo;
    $18:
      begin
        var P := Int64(Integer(A.UW[0])) * Int64(Integer(B.UW[0]));
        S.LO.Hi := SX32(UInt64(P));
        S.HI.Hi := SX32(UInt64(P) shr 32);
        S.GPR[I.D].Lo := S.LO.Hi;
      end;
    $19:
      begin
        var P := UInt64(A.UW[0]) * B.UW[0];
        S.LO.Hi := SX32(P);
        S.HI.Hi := SX32(P shr 32);
        S.GPR[I.D].Lo := S.LO.Hi;
      end;
    $1A: DivideSigned(Integer(A.UW[0]), Integer(B.UW[0]), S.LO.Hi, S.HI.Hi);
    $1B: DivideUnsigned(A.UW[0], B.UW[0], S.LO.Hi, S.HI.Hi);
    $28: Exit(OpMMI1(I));
    $29: Exit(OpMMI3(I));
    $30:
      begin
        case I.Sa of
          0:
            begin
              R.UW[0] := S.LO.UW[0];
              R.UW[1] := S.HI.UW[0];
              R.UW[2] := S.LO.UW[2];
              R.UW[3] := S.HI.UW[2];
            end;
          1:
            begin
              R.UW[0] := S.LO.UW[1];
              R.UW[1] := S.HI.UW[1];
              R.UW[2] := S.LO.UW[3];
              R.UW[3] := S.HI.UW[3];
            end;
          2:
            begin
              R.UD[0] := SX32(SatS32(Int64((UInt64(S.HI.UW[0]) shl 32) or S.LO.UW[0])));
              R.UD[1] := SX32(SatS32(Int64((UInt64(S.HI.UW[2]) shl 32) or S.LO.UW[2])));
            end;
          3:
            begin
              R.UH[0] := S.LO.UH[0];
              R.UH[1] := S.LO.UH[2];
              R.UH[2] := S.HI.UH[0];
              R.UH[3] := S.HI.UH[2];
              R.UH[4] := S.LO.UH[4];
              R.UH[5] := S.LO.UH[6];
              R.UH[6] := S.HI.UH[4];
              R.UH[7] := S.HI.UH[6];
            end;
          4:
            begin
              R.UH[0] := SatS16(S.LO.SW[0]);
              R.UH[1] := SatS16(S.LO.SW[1]);
              R.UH[2] := SatS16(S.HI.SW[0]);
              R.UH[3] := SatS16(S.HI.SW[1]);
              R.UH[4] := SatS16(S.LO.SW[2]);
              R.UH[5] := SatS16(S.LO.SW[3]);
              R.UH[6] := SatS16(S.HI.SW[2]);
              R.UH[7] := SatS16(S.HI.SW[3]);
            end;
        else
          Exit(Raise_(I, EEExcReserved));
        end;
        S.GPR[I.D] := R;
      end;
    $31:
      if I.Sa = 0 then
      begin
        S.LO.UW[0] := A.UW[0];
        S.HI.UW[0] := A.UW[1];
        S.LO.UW[2] := A.UW[2];
        S.HI.UW[2] := A.UW[3];
      end
      else
        Exit(Raise_(I, EEExcReserved));
    $34:
      begin
        for var K := 0 to 7 do
          R.UH[K] := Word(B.UH[K] shl (I.Sa and 15));
        S.GPR[I.D] := R;
      end;
    $36:
      begin
        for var K := 0 to 7 do
          R.UH[K] := B.UH[K] shr (I.Sa and 15);
        S.GPR[I.D] := R;
      end;
    $37:
      begin
        for var K := 0 to 7 do
          R.UH[K] := Word(Sar32(Cardinal(Integer(B.SH[K])), I.Sa and 15));
        S.GPR[I.D] := R;
      end;
    $3C:
      begin
        for var K := 0 to 3 do
          R.UW[K] := B.UW[K] shl I.Sa;
        S.GPR[I.D] := R;
      end;
    $3E:
      begin
        for var K := 0 to 3 do
          R.UW[K] := B.UW[K] shr I.Sa;
        S.GPR[I.D] := R;
      end;
    $3F:
      begin
        for var K := 0 to 3 do
          R.UW[K] := Sar32(B.UW[K], I.Sa);
        S.GPR[I.D] := R;
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  Result := False;
end;

function TEECPU.OpMMI0(I: PEEInst): Boolean;
var
  R: TPS2Reg128;
begin
  var A := S.GPR[I.S];
  var B := S.GPR[I.T];
  case I.Sa of
    0: for var K := 0 to 3 do R.UW[K] := Add32(A.UW[K], B.UW[K]);
    1: for var K := 0 to 3 do R.UW[K] := Sub32(A.UW[K], B.UW[K]);
    2: for var K := 0 to 3 do R.UW[K] := Cardinal(-Ord(A.SW[K] > B.SW[K]));
    3: for var K := 0 to 3 do if A.SW[K] > B.SW[K] then R.UW[K] := A.UW[K] else R.UW[K] := B.UW[K];
    4: for var K := 0 to 7 do R.UH[K] := Word(Integer(A.UH[K]) + B.UH[K]);
    5: for var K := 0 to 7 do R.UH[K] := Word(Integer(A.UH[K]) - B.UH[K]);
    6: for var K := 0 to 7 do R.UH[K] := Word(-Ord(A.SH[K] > B.SH[K]));
    7: for var K := 0 to 7 do if A.SH[K] > B.SH[K] then R.UH[K] := A.UH[K] else R.UH[K] := B.UH[K];
    8: for var K := 0 to 15 do R.UB[K] := Byte(Integer(A.UB[K]) + B.UB[K]);
    9: for var K := 0 to 15 do R.UB[K] := Byte(Integer(A.UB[K]) - B.UB[K]);
    10: for var K := 0 to 15 do R.UB[K] := Byte(-Ord(A.SB[K] > B.SB[K]));
    16: for var K := 0 to 3 do R.UW[K] := SatS32(Int64(A.SW[K]) + B.SW[K]);
    17: for var K := 0 to 3 do R.UW[K] := SatS32(Int64(A.SW[K]) - B.SW[K]);
    18:
      begin
        R.UW[0] := B.UW[0];
        R.UW[1] := A.UW[0];
        R.UW[2] := B.UW[1];
        R.UW[3] := A.UW[1];
      end;
    19:
      begin
        R.UW[0] := B.UW[0];
        R.UW[1] := B.UW[2];
        R.UW[2] := A.UW[0];
        R.UW[3] := A.UW[2];
      end;
    20: for var K := 0 to 7 do R.UH[K] := SatS16(Integer(A.SH[K]) + B.SH[K]);
    21: for var K := 0 to 7 do R.UH[K] := SatS16(Integer(A.SH[K]) - B.SH[K]);
    22:
      for var K := 0 to 3 do
      begin
        R.UH[K * 2] := B.UH[K];
        R.UH[K * 2 + 1] := A.UH[K];
      end;
    23:
      for var K := 0 to 3 do
      begin
        R.UH[K] := B.UH[K * 2];
        R.UH[K + 4] := A.UH[K * 2];
      end;
    24: for var K := 0 to 15 do R.UB[K] := SatS8(Integer(A.SB[K]) + B.SB[K]);
    25: for var K := 0 to 15 do R.UB[K] := SatS8(Integer(A.SB[K]) - B.SB[K]);
    26:
      for var K := 0 to 7 do
      begin
        R.UB[K * 2] := B.UB[K];
        R.UB[K * 2 + 1] := A.UB[K];
      end;
    27:
      for var K := 0 to 7 do
      begin
        R.UB[K] := B.UB[K * 2];
        R.UB[K + 8] := A.UB[K * 2];
      end;
    30:
      for var K := 0 to 3 do
      begin
        var X := B.UW[K];
        R.UW[K] := ((X and $1F) shl 3) or (((X shr 5) and $1F) shl 11) or (((X shr 10) and $1F) shl 19) or
          (((X shr 15) and 1) shl 31);
      end;
    31:
      for var K := 0 to 3 do
      begin
        var X := B.UW[K];
        R.UW[K] := ((X shr 3) and $1F) or (((X shr 11) and $1F) shl 5) or (((X shr 19) and $1F) shl 10) or
          (((X shr 31) and 1) shl 15);
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  S.GPR[I.D] := R;
  Result := False;
end;

function TEECPU.OpMMI1(I: PEEInst): Boolean;
var
  R: TPS2Reg128;
begin
  var A := S.GPR[I.S];
  var B := S.GPR[I.T];
  case I.Sa of
    1:
      for var K := 0 to 3 do
        if B.UW[K] = $80000000 then
          R.UW[K] := $7FFFFFFF
        else if B.SW[K] < 0 then
          R.UW[K] := Cardinal(-B.SW[K])
        else
          R.UW[K] := B.UW[K];
    2: for var K := 0 to 3 do R.UW[K] := Cardinal(-Ord(A.UW[K] = B.UW[K]));
    3: for var K := 0 to 3 do if A.SW[K] < B.SW[K] then R.UW[K] := A.UW[K] else R.UW[K] := B.UW[K];
    4:
      begin
        for var K := 0 to 3 do
          R.UH[K] := Word(Integer(A.UH[K]) - B.UH[K]);
        for var K := 4 to 7 do
          R.UH[K] := Word(Integer(A.UH[K]) + B.UH[K]);
      end;
    5:
      for var K := 0 to 7 do
        if B.UH[K] = $8000 then
          R.UH[K] := $7FFF
        else
          R.UH[K] := Word(Abs(Integer(B.SH[K])));
    6: for var K := 0 to 7 do R.UH[K] := Word(-Ord(A.UH[K] = B.UH[K]));
    7: for var K := 0 to 7 do if A.SH[K] < B.SH[K] then R.UH[K] := A.UH[K] else R.UH[K] := B.UH[K];
    10: for var K := 0 to 15 do R.UB[K] := Byte(-Ord(A.UB[K] = B.UB[K]));
    16: for var K := 0 to 3 do R.UW[K] := Cardinal(Min(UInt64(A.UW[K]) + B.UW[K], UInt64($FFFFFFFF)));
    17: for var K := 0 to 3 do R.UW[K] := Cardinal(Max(Int64(A.UW[K]) - Int64(B.UW[K]), 0));
    18:
      begin
        R.UW[0] := B.UW[2];
        R.UW[1] := A.UW[2];
        R.UW[2] := B.UW[3];
        R.UW[3] := A.UW[3];
      end;
    20: for var K := 0 to 7 do R.UH[K] := Word(Min(Integer(A.UH[K]) + B.UH[K], $FFFF));
    21: for var K := 0 to 7 do R.UH[K] := Word(Max(Integer(A.UH[K]) - B.UH[K], 0));
    22:
      for var K := 0 to 3 do
      begin
        R.UH[K * 2] := B.UH[K + 4];
        R.UH[K * 2 + 1] := A.UH[K + 4];
      end;
    24: for var K := 0 to 15 do R.UB[K] := Byte(Min(Integer(A.UB[K]) + B.UB[K], $FF));
    25: for var K := 0 to 15 do R.UB[K] := Byte(Max(Integer(A.UB[K]) - B.UB[K], 0));
    26:
      for var K := 0 to 7 do
      begin
        R.UB[K * 2] := B.UB[K + 8];
        R.UB[K * 2 + 1] := A.UB[K + 8];
      end;
    27:
      begin
        // QFSRV: the low 128 bits of rs:rt shifted right by SA bytes.
        var Sh := Integer(S.SA and 15) * 8;
        if Sh = 0 then
          R := B
        else if Sh < 64 then
        begin
          R.Lo := (B.Lo shr Sh) or (B.Hi shl (64 - Sh));
          R.Hi := (B.Hi shr Sh) or (A.Lo shl (64 - Sh));
        end
        else if Sh = 64 then
        begin
          R.Lo := B.Hi;
          R.Hi := A.Lo;
        end
        else
        begin
          R.Lo := (B.Hi shr (Sh - 64)) or (A.Lo shl (128 - Sh));
          R.Hi := (A.Lo shr (Sh - 64)) or (A.Hi shl (128 - Sh));
        end;
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  S.GPR[I.D] := R;
  Result := False;
end;

// A halfword product added to (taken from) a LO/HI word, as PMADDH/PMSUBH.
function MulAccHalf(Old: Cardinal; A, B: SmallInt; Sub: Boolean): Cardinal; inline;
begin
  var P := Cardinal(Integer(A) * Integer(B));
  if Sub then
    Result := Sub32(Old, P)
  else
    Result := Add32(Old, P);
end;

function TEECPU.OpMMI2(I: PEEInst): Boolean;
var
  R: TPS2Reg128;
  Full: UInt64;
begin
  var A := S.GPR[I.S];
  var B := S.GPR[I.T];
  case I.Sa of
    0, 4:
      begin
        WordMulAcc(S.HI.Lo, S.LO.Lo, A.SW[0], B.SW[0], True, I.Sa = 4, Full);
        R.Lo := Full;
        WordMulAcc(S.HI.Hi, S.LO.Hi, A.SW[2], B.SW[2], True, I.Sa = 4, Full);
        R.Hi := Full;
      end;
    2:
      begin
        R.Lo := SX32(B.UW[0] shl (A.UW[0] and 31));
        R.Hi := SX32(B.UW[2] shl (A.UW[2] and 31));
      end;
    3:
      begin
        R.Lo := SX32(B.UW[0] shr (A.UW[0] and 31));
        R.Hi := SX32(B.UW[2] shr (A.UW[2] and 31));
      end;
    8: R := S.HI;
    9: R := S.LO;
    10:
      for var K := 0 to 3 do
      begin
        R.UH[K * 2] := B.UH[K];
        R.UH[K * 2 + 1] := A.UH[K + 4];
      end;
    12:
      begin
        WordMulAcc(S.HI.Lo, S.LO.Lo, A.SW[0], B.SW[0], False, False, Full);
        R.Lo := Full;
        WordMulAcc(S.HI.Hi, S.LO.Hi, A.SW[2], B.SW[2], False, False, Full);
        R.Hi := Full;
      end;
    13:
      begin
        DivideSigned(A.SW[0], B.SW[0], S.LO.Lo, S.HI.Lo);
        DivideSigned(A.SW[2], B.SW[2], S.LO.Hi, S.HI.Hi);
        Exit(False);
      end;
    14:
      begin
        R.Lo := B.Lo;
        R.Hi := A.Lo;
      end;
    16, 20:
      begin
        // Halfword k accumulates into LO/HI word slots 0,1 (LO), 0,1 (HI),
        // 2,3 (LO), 2,3 (HI). (Words put together into 64-bit halves: what
        // reads them next reads those.)
        var Sub := I.Sa = 20;
        var L0 := MulAccHalf(S.LO.UW[0], A.SH[0], B.SH[0], Sub);
        var L1 := MulAccHalf(S.LO.UW[1], A.SH[1], B.SH[1], Sub);
        var H0 := MulAccHalf(S.HI.UW[0], A.SH[2], B.SH[2], Sub);
        var H1 := MulAccHalf(S.HI.UW[1], A.SH[3], B.SH[3], Sub);
        var L2 := MulAccHalf(S.LO.UW[2], A.SH[4], B.SH[4], Sub);
        var L3 := MulAccHalf(S.LO.UW[3], A.SH[5], B.SH[5], Sub);
        var H2 := MulAccHalf(S.HI.UW[2], A.SH[6], B.SH[6], Sub);
        var H3 := MulAccHalf(S.HI.UW[3], A.SH[7], B.SH[7], Sub);
        S.LO.Lo := UInt64(L0) or (UInt64(L1) shl 32);
        S.LO.Hi := UInt64(L2) or (UInt64(L3) shl 32);
        S.HI.Lo := UInt64(H0) or (UInt64(H1) shl 32);
        S.HI.Hi := UInt64(H2) or (UInt64(H3) shl 32);
        S.GPR[I.D].Lo := UInt64(L0) or (UInt64(H0) shl 32);
        S.GPR[I.D].Hi := UInt64(L2) or (UInt64(H2) shl 32);
        Exit(False);
      end;
    17, 21:
      begin
        var P: array[0..7] of Integer;
        for var K := 0 to 7 do
          P[K] := Integer(A.SH[K]) * Integer(B.SH[K]);
        if I.Sa = 17 then
        begin
          S.LO.UW[0] := Add32(Cardinal(P[1]), Cardinal(P[0]));
          S.HI.UW[0] := Add32(Cardinal(P[3]), Cardinal(P[2]));
          S.LO.UW[2] := Add32(Cardinal(P[5]), Cardinal(P[4]));
          S.HI.UW[2] := Add32(Cardinal(P[7]), Cardinal(P[6]));
        end
        else
        begin
          S.LO.UW[0] := Sub32(Cardinal(P[1]), Cardinal(P[0]));
          S.HI.UW[0] := Sub32(Cardinal(P[3]), Cardinal(P[2]));
          S.LO.UW[2] := Sub32(Cardinal(P[5]), Cardinal(P[4]));
          S.HI.UW[2] := Sub32(Cardinal(P[7]), Cardinal(P[6]));
        end;
        S.LO.UW[1] := not Cardinal(P[1]);
        S.HI.UW[1] := not Cardinal(P[3]);
        S.LO.UW[3] := not Cardinal(P[5]);
        S.HI.UW[3] := not Cardinal(P[7]);
        if I.Sa = 17 then
        begin
          S.LO.UW[1] := Cardinal(P[1]);
          S.HI.UW[1] := Cardinal(P[3]);
          S.LO.UW[3] := Cardinal(P[5]);
          S.HI.UW[3] := Cardinal(P[7]);
        end;
        R.UW[0] := S.LO.UW[0];
        R.UW[1] := S.HI.UW[0];
        R.UW[2] := S.LO.UW[2];
        R.UW[3] := S.HI.UW[2];
      end;
    18:
      begin
        R.Lo := A.Lo and B.Lo;
        R.Hi := A.Hi and B.Hi;
      end;
    19:
      begin
        R.Lo := A.Lo xor B.Lo;
        R.Hi := A.Hi xor B.Hi;
      end;
    26:
      begin
        R.UH[0] := B.UH[2];
        R.UH[1] := B.UH[1];
        R.UH[2] := B.UH[0];
        R.UH[3] := B.UH[3];
        R.UH[4] := B.UH[6];
        R.UH[5] := B.UH[5];
        R.UH[6] := B.UH[4];
        R.UH[7] := B.UH[7];
      end;
    27:
      begin
        R.UH[0] := B.UH[3];
        R.UH[1] := B.UH[2];
        R.UH[2] := B.UH[1];
        R.UH[3] := B.UH[0];
        R.UH[4] := B.UH[7];
        R.UH[5] := B.UH[6];
        R.UH[6] := B.UH[5];
        R.UH[7] := B.UH[4];
      end;
    28:
      begin
        var P0 := Cardinal(Integer(A.SH[0]) * Integer(B.SH[0]));
        var P1 := Cardinal(Integer(A.SH[1]) * Integer(B.SH[1]));
        var P2 := Cardinal(Integer(A.SH[2]) * Integer(B.SH[2]));
        var P3 := Cardinal(Integer(A.SH[3]) * Integer(B.SH[3]));
        var P4 := Cardinal(Integer(A.SH[4]) * Integer(B.SH[4]));
        var P5 := Cardinal(Integer(A.SH[5]) * Integer(B.SH[5]));
        var P6 := Cardinal(Integer(A.SH[6]) * Integer(B.SH[6]));
        var P7 := Cardinal(Integer(A.SH[7]) * Integer(B.SH[7]));
        S.LO.Lo := UInt64(P0) or (UInt64(P1) shl 32);
        S.LO.Hi := UInt64(P4) or (UInt64(P5) shl 32);
        S.HI.Lo := UInt64(P2) or (UInt64(P3) shl 32);
        S.HI.Hi := UInt64(P6) or (UInt64(P7) shl 32);
        S.GPR[I.D].Lo := UInt64(P0) or (UInt64(P2) shl 32);
        S.GPR[I.D].Hi := UInt64(P4) or (UInt64(P6) shl 32);
        Exit(False);
      end;
    29:
      begin
        var D := Integer(B.SH[0]);
        for var K := 0 to 3 do
        begin
          var N := A.SW[K];
          if D = 0 then
          begin
            if N < 0 then
              S.LO.UW[K] := 1
            else
              S.LO.UW[K] := $FFFFFFFF;
            S.HI.UW[K] := Cardinal(N);
          end
          else if (N = Low(Integer)) and (D = -1) then
          begin
            S.LO.UW[K] := $80000000;
            S.HI.UW[K] := 0;
          end
          else
          begin
            S.LO.UW[K] := Cardinal(N div D);
            S.HI.UW[K] := Cardinal(N mod D);
          end;
        end;
        Exit(False);
      end;
    30:
      begin
        R.UW[0] := B.UW[2];
        R.UW[1] := B.UW[1];
        R.UW[2] := B.UW[0];
        R.UW[3] := B.UW[3];
      end;
    31:
      begin
        R.UW[0] := B.UW[1];
        R.UW[1] := B.UW[2];
        R.UW[2] := B.UW[0];
        R.UW[3] := B.UW[3];
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  S.GPR[I.D] := R;
  Result := False;
end;

function TEECPU.OpMMI3(I: PEEInst): Boolean;
var
  R: TPS2Reg128;
begin
  var A := S.GPR[I.S];
  var B := S.GPR[I.T];
  case I.Sa of
    0:
      begin
        var Acc := (UInt64(S.HI.UW[0]) shl 32) or S.LO.UW[0];
        Acc := Add64(Acc, UInt64(A.UW[0]) * B.UW[0]);
        S.LO.Lo := SX32(Acc);
        S.HI.Lo := SX32(Acc shr 32);
        R.Lo := Acc;
        Acc := (UInt64(S.HI.UW[2]) shl 32) or S.LO.UW[2];
        Acc := Add64(Acc, UInt64(A.UW[2]) * B.UW[2]);
        S.LO.Hi := SX32(Acc);
        S.HI.Hi := SX32(Acc shr 32);
        R.Hi := Acc;
      end;
    3:
      begin
        R.Lo := SX32(Sar32(B.UW[0], A.UW[0] and 31));
        R.Hi := SX32(Sar32(B.UW[2], A.UW[2] and 31));
      end;
    8:
      begin
        S.HI := A;
        Exit(False);
      end;
    9:
      begin
        S.LO := A;
        Exit(False);
      end;
    10:
      for var K := 0 to 3 do
      begin
        R.UH[K * 2] := B.UH[K * 2];
        R.UH[K * 2 + 1] := A.UH[K * 2];
      end;
    12:
      begin
        var P := UInt64(A.UW[0]) * B.UW[0];
        S.LO.Lo := SX32(P);
        S.HI.Lo := SX32(P shr 32);
        R.Lo := P;
        P := UInt64(A.UW[2]) * B.UW[2];
        S.LO.Hi := SX32(P);
        S.HI.Hi := SX32(P shr 32);
        R.Hi := P;
      end;
    13:
      begin
        DivideUnsigned(A.UW[0], B.UW[0], S.LO.Lo, S.HI.Lo);
        DivideUnsigned(A.UW[2], B.UW[2], S.LO.Hi, S.HI.Hi);
        Exit(False);
      end;
    14:
      begin
        R.Lo := A.Hi;
        R.Hi := B.Hi;
      end;
    18:
      begin
        R.Lo := A.Lo or B.Lo;
        R.Hi := A.Hi or B.Hi;
      end;
    19:
      begin
        R.Lo := not (A.Lo or B.Lo);
        R.Hi := not (A.Hi or B.Hi);
      end;
    26:
      begin
        R.UH[0] := B.UH[0];
        R.UH[1] := B.UH[2];
        R.UH[2] := B.UH[1];
        R.UH[3] := B.UH[3];
        R.UH[4] := B.UH[4];
        R.UH[5] := B.UH[6];
        R.UH[6] := B.UH[5];
        R.UH[7] := B.UH[7];
      end;
    27:
      begin
        for var K := 0 to 3 do
          R.UH[K] := B.UH[0];
        for var K := 4 to 7 do
          R.UH[K] := B.UH[4];
      end;
    30:
      begin
        R.UW[0] := B.UW[0];
        R.UW[1] := B.UW[2];
        R.UW[2] := B.UW[1];
        R.UW[3] := B.UW[3];
      end;
  else
    Exit(Raise_(I, EEExcReserved));
  end;
  S.GPR[I.D] := R;
  Result := False;
end;

{ Decoder }

function Dest(R: Cardinal): TPS2RegIndex; inline;
begin
  if R = 0 then
    Result := 32
  else
    Result := R;
end;

// Fills I for the instruction Op at Address; True when it is a branch with a
// delay slot.
function TEECPU.Decode(Op, Address: Cardinal; var I: TEEInst): Boolean;
var
  H: Pointer;
begin
  I := Default(TEEInst);
  I.Op := Op;
  I.Addr := Address;
  var Rs := (Op shr 21) and 31;
  var Rt := (Op shr 16) and 31;
  var Rd := (Op shr 11) and 31;
  var Sa := (Op shr 6) and 31;
  I.S := Rs;
  I.T := Rt;
  I.D := Dest(Rd);
  I.Sa := Sa;
  I.Imm := SX16To32(Op and $FFFF);
  var Target := Add32(Address + 4, I.Imm shl 2);
  Result := False;
  H := @TEECPU.OpReserved;
  case Op shr 26 of
    $00:
      case Op and $3F of
        $00:
          if Op = 0 then
            H := @TEECPU.OpNOP
          else
            H := @TEECPU.OpSLL;
        $02: H := @TEECPU.OpSRL;
        $03: H := @TEECPU.OpSRA;
        $04: H := @TEECPU.OpSLLV;
        $06: H := @TEECPU.OpSRLV;
        $07: H := @TEECPU.OpSRAV;
        $08:
          begin
            H := @TEECPU.OpJR;
            Result := True;
          end;
        $09:
          begin
            H := @TEECPU.OpJALR;
            Result := True;
          end;
        $0A: H := @TEECPU.OpMOVZ;
        $0B: H := @TEECPU.OpMOVN;
        $0C:
          begin
            H := @TEECPU.OpSYSCALL;
            I.Flags := IFEnd;
          end;
        $0D:
          begin
            H := @TEECPU.OpBREAK;
            I.Flags := IFEnd;
          end;
        $0F: H := @TEECPU.OpNOP;
        $10: H := @TEECPU.OpMFHI;
        $11: H := @TEECPU.OpMTHI;
        $12: H := @TEECPU.OpMFLO;
        $13: H := @TEECPU.OpMTLO;
        $14: H := @TEECPU.OpDSLLV;
        $16: H := @TEECPU.OpDSRLV;
        $17: H := @TEECPU.OpDSRAV;
        $18: H := @TEECPU.OpMULT;
        $19: H := @TEECPU.OpMULTU;
        $1A: H := @TEECPU.OpDIV;
        $1B: H := @TEECPU.OpDIVU;
        $20: H := @TEECPU.OpADD;
        $21: H := @TEECPU.OpADDU;
        $22: H := @TEECPU.OpSUB;
        $23: H := @TEECPU.OpSUBU;
        $24: H := @TEECPU.OpAND;
        $25: H := @TEECPU.OpOR;
        $26: H := @TEECPU.OpXOR;
        $27: H := @TEECPU.OpNOR;
        $28: H := @TEECPU.OpMFSA;
        $29: H := @TEECPU.OpMTSA;
        $2A: H := @TEECPU.OpSLT;
        $2B: H := @TEECPU.OpSLTU;
        $2C: H := @TEECPU.OpDADD;
        $2D: H := @TEECPU.OpDADDU;
        $2E: H := @TEECPU.OpDSUB;
        $2F: H := @TEECPU.OpDSUBU;
        $30, $31, $32, $33, $34, $36: H := @TEECPU.OpTrapR;
        $38: H := @TEECPU.OpDSLL;
        $3A: H := @TEECPU.OpDSRL;
        $3B: H := @TEECPU.OpDSRA;
        $3C:
          begin
            H := @TEECPU.OpDSLL;
            I.Sa := Sa + 32;
          end;
        $3E:
          begin
            H := @TEECPU.OpDSRL;
            I.Sa := Sa + 32;
          end;
        $3F:
          begin
            H := @TEECPU.OpDSRA;
            I.Sa := Sa + 32;
          end;
      end;
    $01:
      begin
        I.Imm := Target;
        case Rt of
          $00: H := @TEECPU.OpBLTZ;
          $01: H := @TEECPU.OpBGEZ;
          $02: H := @TEECPU.OpBLTZL;
          $03: H := @TEECPU.OpBGEZL;
          $10: H := @TEECPU.OpBLTZAL;
          $11: H := @TEECPU.OpBGEZAL;
          $12: H := @TEECPU.OpBLTZALL;
          $13: H := @TEECPU.OpBGEZALL;
          $08..$0C, $0E:
            begin
              I.Imm := SX16To32(Op and $FFFF);
              H := @TEECPU.OpTrapI;
            end;
          $18:
            begin
              I.Imm := Op and $FFFF;
              H := @TEECPU.OpMTSAB;
            end;
          $19:
            begin
              I.Imm := Op and $FFFF;
              H := @TEECPU.OpMTSAH;
            end;
        end;
        Result := Rt in [$00..$03, $10..$13];
      end;
    $02:
      begin
        H := @TEECPU.OpJ;
        I.Imm := ((Address + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
        Result := True;
      end;
    $03:
      begin
        H := @TEECPU.OpJAL;
        I.Imm := ((Address + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
        Result := True;
      end;
    $04, $05, $06, $07, $14, $15, $16, $17:
      begin
        I.Imm := Target;
        Result := True;
        case Op shr 26 of
          $04:
            if (Rs = 0) and (Rt = 0) then
              H := @TEECPU.OpJ
            else
              H := @TEECPU.OpBEQ;
          $05: H := @TEECPU.OpBNE;
          $06: H := @TEECPU.OpBLEZ;
          $07: H := @TEECPU.OpBGTZ;
          $14: H := @TEECPU.OpBEQL;
          $15: H := @TEECPU.OpBNEL;
          $16: H := @TEECPU.OpBLEZL;
          $17: H := @TEECPU.OpBGTZL;
        end;
      end;
    $08:
      begin
        H := @TEECPU.OpADDI;
        I.T := Dest(Rt);
      end;
    $09:
      begin
        H := @TEECPU.OpADDIU;
        I.T := Dest(Rt);
      end;
    $0A:
      begin
        H := @TEECPU.OpSLTI;
        I.T := Dest(Rt);
      end;
    $0B:
      begin
        H := @TEECPU.OpSLTIU;
        I.T := Dest(Rt);
      end;
    $0C:
      begin
        H := @TEECPU.OpANDI;
        I.T := Dest(Rt);
        I.Imm := Op and $FFFF;
      end;
    $0D:
      begin
        H := @TEECPU.OpORI;
        I.T := Dest(Rt);
        I.Imm := Op and $FFFF;
      end;
    $0E:
      begin
        H := @TEECPU.OpXORI;
        I.T := Dest(Rt);
        I.Imm := Op and $FFFF;
      end;
    $0F:
      begin
        H := @TEECPU.OpLUI;
        I.T := Dest(Rt);
        I.Imm := (Op and $FFFF) shl 16;
      end;
    $10:
      case Rs of
        0:
          begin
            H := @TEECPU.OpCOP0;
            I.T := Dest(Rt);
          end;
        4: H := @TEECPU.OpCOP0;
        8:
          begin
            H := @TEECPU.OpBC0;
            I.Imm := Target;
            Result := True;
          end;
        16..31:
          case Op and $3F of
            $18:
              begin
                H := @TEECPU.OpERET;
                I.Flags := IFEnd;
              end;
            $38: H := @TEECPU.OpEI;
            $39: H := @TEECPU.OpDI;
          else
            H := @TEECPU.OpCOP0;
          end;
      end;
    $11:
      begin
        I.S := Rd;
        I.T := Rt;
        I.D := Sa;
        case Rs of
          0:
            begin
              H := @TEECPU.OpMFC1;
              I.T := Dest(Rt);
            end;
          2:
            begin
              H := @TEECPU.OpCFC1;
              I.T := Dest(Rt);
            end;
          4: H := @TEECPU.OpMTC1;
          6: H := @TEECPU.OpCTC1;
          8:
            begin
              H := @TEECPU.OpBC1;
              I.Imm := Target;
              Result := True;
            end;
          $10:
            case Op and $3F of
              $00: H := @TEECPU.OpFADD;
              $02: H := @TEECPU.OpFMUL;
              $06: H := @TEECPU.OpFMOV;
            else
              H := @TEECPU.OpFPU;
            end;
          $14: H := @TEECPU.OpFPU;
        end;
      end;
    $12:
      begin
        H := @TEECPU.OpCOP2;
        if (Rs = 1) or (Rs = 2) then
          I.T := Dest(Rt);
        if Rs = 8 then
        begin
          I.Imm := Target;
          Result := True;
        end;
      end;
    $18:
      begin
        H := @TEECPU.OpDADDI;
        I.T := Dest(Rt);
      end;
    $19:
      begin
        H := @TEECPU.OpDADDIU;
        I.T := Dest(Rt);
      end;
    $1A:
      begin
        H := @TEECPU.OpLDL;
        I.T := Dest(Rt);
      end;
    $1B:
      begin
        H := @TEECPU.OpLDR;
        I.T := Dest(Rt);
      end;
    $1C:
      begin
        H := @TEECPU.OpMMI;
        var K := -1;
        if FMMIKernels then
          K := EEMMIKernelIndex(Op);
        if K >= 0 then
        begin
          // (The kernel's index where the immediate would be.)
          H := @TEECPU.OpMMIKernel;
          I.Imm := Cardinal(K);
        end;
      end;
    $1E:
      begin
        H := @TEECPU.OpLQ;
        I.T := Dest(Rt);
      end;
    $1F: H := @TEECPU.OpSQ;
    $20, $21, $22, $23, $24, $25, $26, $27:
      begin
        I.T := Dest(Rt);
        case Op shr 26 of
          $20: H := @TEECPU.OpLB;
          $21: H := @TEECPU.OpLH;
          $22: H := @TEECPU.OpLWL;
          $23: H := @TEECPU.OpLW;
          $24: H := @TEECPU.OpLBU;
          $25: H := @TEECPU.OpLHU;
          $26: H := @TEECPU.OpLWR;
          $27: H := @TEECPU.OpLWU;
        end;
      end;
    $28: H := @TEECPU.OpSB;
    $29: H := @TEECPU.OpSH;
    $2A: H := @TEECPU.OpSWL;
    $2B: H := @TEECPU.OpSW;
    $2C: H := @TEECPU.OpSDL;
    $2D: H := @TEECPU.OpSDR;
    $2E: H := @TEECPU.OpSWR;
    $2F: H := @TEECPU.OpNOP;
    $31: H := @TEECPU.OpLWC1;
    $33: H := @TEECPU.OpNOP;
    $36: H := @TEECPU.OpLQC2;
    $37:
      begin
        H := @TEECPU.OpLD;
        I.T := Dest(Rt);
      end;
    $39: H := @TEECPU.OpSWC1;
    $3B:
      begin
        H := @TEECPU.OpTrapHLE;
        I.Flags := IFEnd;
      end;
    $3E: H := @TEECPU.OpSQC2;
    $3F: H := @TEECPU.OpSD;
  end;
  // MMI writers of rd.
  if (Op shr 26) = $1C then
    I.D := Dest(Rd);
  I.Handler := H;
  if Result then
  begin
    I.Flags := I.Flags or IFBranch;
    case Op shr 26 of
      $14..$17:
        I.Flags := I.Flags or IFLikely;
      $01:
        if (Rt and 2) <> 0 then
          I.Flags := I.Flags or IFLikely;
      $10..$12:
        if (Op and $20000) <> 0 then
          I.Flags := I.Flags or IFLikely;
    end;
  end;
end;

{ Blocks }

procedure TEECPU.ClearBlocks;
begin
  // The blocks' code goes too: now, or once the code running returns.
  if FJit <> nil then
    if FInJit then
      FJitResetPending := True
    else
    begin
      FJit.Reset;
      Inc(FJitResets);
    end;
  FillChar(FBlockHead, SizeOf(FBlockHead), 0);
  FBlockCount := 0;
  FInstChunk := 0;
  FInstUsed := 0;
  FCodeChunk := 0;
  FCodeUsed := 0;
  Inc(FBlockGen);
end;

procedure TEECPU.InvalidateBlocks;
begin
  ClearBlocks;
end;

function TEECPU.FindBlock(PC: Cardinal): PEEBlock;
begin
  Result := FBlockHead[(PC shr 2) and (BlockBuckets - 1)];
  while (Result <> nil) and (Result.PC <> PC) do
    Result := Result.Next;
  if (Result <> nil) and ((Result.GenPtr^ <> Result.Gen) or (Result.GenPtr2^ <> Result.Gen2)) and
    not BlockValid(Result) then
  begin
    Result.PC := 1;
    Result := nil;
  end;
end;

function TEECPU.BlockValid(B: PEEBlock): Boolean;
begin
  var Address := B.PC;
  for var K := 0 to B.Count - 1 do
  begin
    var P := FReadMap[Address shr 12];
    if (P = nil) or (PCardinal(P + (Address and $FFF))^ <> B.Code[K]) then
      Exit(False);
    Inc(Address, 4);
  end;
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  Result := True;
end;

function TEECPU.BuildBlock(PC: Cardinal): PEEBlock;
begin
  Result := nil;
  if FInstUsed + MaxBlockInsts + 2 > InstChunkSize then
  begin
    Inc(FInstChunk);
    FInstUsed := 0;
  end;
  if FCodeUsed + MaxBlockInsts + 2 > InstChunkSize then
  begin
    Inc(FCodeChunk);
    FCodeUsed := 0;
  end;
  if (FBlockCount >= MaxBlocks) or (FInstChunk >= MaxInstChunks) or (FCodeChunk >= MaxInstChunks) then
    ClearBlocks;
  if FInstChunk >= Length(FInstChunks) then
  begin
    SetLength(FInstChunks, FInstChunk + 1);
    SetLength(FInstChunks[FInstChunk], InstChunkSize);
  end;
  if FCodeChunk >= Length(FCodeChunks) then
  begin
    SetLength(FCodeChunks, FCodeChunk + 1);
    SetLength(FCodeChunks[FCodeChunk], InstChunkSize);
  end;
  var Chunk := FBlockCount div BlockChunkSize;
  if Chunk >= Length(FBlockChunks) then
  begin
    SetLength(FBlockChunks, Chunk + 1);
    SetLength(FBlockChunks[Chunk], BlockChunkSize);
  end;
  var B: PEEBlock := @FBlockChunks[Chunk][FBlockCount mod BlockChunkSize];
  var Insts: PEEInst := @FInstChunks[FInstChunk][FInstUsed];
  var Code: PCardinal := @FCodeChunks[FCodeChunk][FCodeUsed];
  var Count := 0;
  var Address := PC;
  var Slot := False;
  while True do
  begin
    var Page := FReadMap[Address shr 12];
    if Page = nil then
    begin
      if Slot then
      begin
        // The delay slot cannot be fetched: it raises the fetch exception.
        Insts[Count] := Default(TEEInst);
        Insts[Count].Handler := @TEECPU.OpFetchFault;
        Insts[Count].Addr := Address;
        Insts[Count].Flags := IFSlot;
        Code[Count] := 0;
        Inc(Count);
      end;
      Break;
    end;
    var Op := PCardinal(Page + (Address and $FFF))^;
    var Branch := Decode(Op, Address, Insts[Count]);
    if Slot then
      Insts[Count].Flags := Insts[Count].Flags or IFSlot;
    Code[Count] := Op;
    Inc(Count);
    Inc(Address, 4);
    // A non-likely branch in a delay slot takes the next instruction as its
    // own delay slot, then the last taken branch wins (R5900 behavior).
    // (ps2autotests: so for BC1T in a BC1T slot; BEQ in a BEQ slot is classic.)
    if Slot and Branch and ((Insts[Count - 1].Flags and IFLikely) = 0) and ((Op shr 26) in [$10..$12]) and
      (Count < MaxBlockInsts) then
      Continue;
    if Slot or ((Insts[Count - 1].Flags and IFEnd) <> 0) then
      Break;
    Slot := Branch;
    if Slot then
      Continue;
    if (Count >= MaxBlockInsts) or ((Address and $FFF) = 0) then
      Break;
  end;
  if Count = 0 then
    Exit;
  Inc(FBlockCount);
  Inc(FInstUsed, Count);
  Inc(FCodeUsed, Count);
  Inc(FBlocksBuilt);
  B.PC := PC;
  B.Count := Count;
  B.Insts := Insts;
  B.Code := Code;
  B.GenPtr := FGenMap[PC shr 12];
  var Last := PC + Cardinal(Count - 1) * 4;
  B.GenPtr2 := FGenMap[Last shr 12];
  B.Gen := B.GenPtr^;
  B.Gen2 := B.GenPtr2^;
  B.Link[0] := nil;
  B.Link[1] := nil;
  B.Native := nil;
  B.NativeInner := nil;
  B.Chain[0] := nil;
  B.Chain[1] := nil;
  B.Heat := 0;
  FindPoll(B);
  FindCountdown(B);
  B.Spin := (Count >= 2) and (Code[Count - 1] = 0) and ((Code[Count - 2] and $FFFF0000) = $10000000) and
    (Add32(PC + Cardinal(Count - 2) * 4 + 4, SX16To32(Code[Count - 2] and $FFFF) shl 2) = PC);
  for var K := 0 to Count - 3 do
    if Code[K] <> 0 then
      B.Spin := False;
  var Bucket := (PC shr 2) and (BlockBuckets - 1);
  B.Next := FBlockHead[Bucket];
  FBlockHead[Bucket] := B;
  Result := B;
end;

function TEECPU.Execute(Insts: PEEInst; Count: Integer; out Next: Cardinal): Integer;
var
  I: PEEInst;
begin
  Result := 0;
  FBranchTaken := False;
  FStop := 0;
  I := Insts;
  while Result < Count do
  begin
    if TEEHandler(I.Handler)(Self, I) then
    begin
      Inc(Result);
      case FStop of
        StopPC: Next := S.PC;
        StopSkip: Next := I.Addr + 8;
      else
        if ((I.Flags and IFSlot) <> 0) and FBranchTaken then
          Next := FBranchTarget
        else
          Next := I.Addr + 4;
      end;
      FStop := 0;
      Exit;
    end;
    Inc(Result);
    Inc(I);
  end;
  Dec(I);
  if FBranchTaken then
    Next := FBranchTarget
  else
    Next := I.Addr + 4;
end;

procedure TEECPU.Run;
begin
  FHostMaskSaved := GetExceptionMask;
  FHostRoundSaved := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(rmTruncate);
  FCop2.RunStarts;
  try
    RunBlocks;
  finally
    FCop2.RunEnds;
    ClearExceptions(False);
    SetExceptionMask(FHostMaskSaved);
    SetRoundMode(FHostRoundSaved);
  end;
end;

{$I PS2.EE.Jit.inc}

// Diagnostics, apart from RunBlocks: no string temporaries there.
procedure TEECPU.LogWatch(PC: Cardinal);
begin
  if WatchLog.Count < 100000 then
    WatchLog.Add(Format('%d at block %.8x after %.8x: %.8x -> %.8x', [Now^, PC, PCHistory[(PCHistoryPos - 1) and 15],
      WatchLast, WatchPtr^]));
  WatchLast := WatchPtr^;
end;

procedure TEECPU.RunBlocks;
var
  Prev, B: PEEBlock;
  Next: Cardinal;
  Count: Integer;
  Gen: Cardinal;
begin
  // Kept apart from Run's exception frame so its variables stay in registers.
  // (Code made without the diagnostics' checks, or with them, is made again
  // when they are switched.)
  var Diagnostics := (WatchPtr <> nil) or (BlockProfile <> nil);
  if Diagnostics <> FJitDiagnostics then
  begin
    ClearBlocks;
    FJitDiagnostics := Diagnostics;
  end;
  FExitRequest := False;
  UpdateInterrupts;
  FExitRequest := False;
  Prev := nil;
  Gen := FBlockGen;
  while Now^ < Deadline^ do
  begin
    if FIntPending then
      if FIntDelay then
        FIntDelay := False
      else
      begin
        // Diagnostics: interrupts taken per line.
        Inc(InterruptsTaken[Ord(FInt1) * 2 + Ord(FInt0)]);
        EnterException(EEExcInterrupt);
        Prev := nil;
      end;
    var PC := S.PC;
    if (WatchPtr <> nil) and (WatchPtr^ <> WatchLast) then
      LogWatch(PC);
    if BlockProfile <> nil then
    begin
      var N: Int64;
      if not BlockProfile.TryGetValue(PC, N) then
        N := 0;
      BlockProfile.AddOrSetValue(PC, N + 1);
    end;
    PCHistory[PCHistoryPos and 15] := PC;
    Inc(PCHistoryPos);
    B := nil;
    if Prev <> nil then
    begin
      if Gen <> FBlockGen then
        Prev := nil
      else
      begin
        B := Prev.Link[0];
        if (B = nil) or (B.PC <> PC) then
        begin
          B := Prev.Link[1];
          if (B <> nil) and (B.PC <> PC) then
            B := nil;
        end;
        if (B <> nil) and ((B.GenPtr^ <> B.Gen) or (B.GenPtr2^ <> B.Gen2)) and not BlockValid(B) then
        begin
          B.PC := 1;
          B := nil;
        end;
      end;
    end;
    if B = nil then
    begin
      Gen := FBlockGen;
      if ((PC and 3) <> 0) or (FReadMap[PC shr 12] = nil) then
      begin
        FetchFault(PC);
        Inc(Now^);
        Prev := nil;
        Continue;
      end;
      B := FindBlock(PC);
      if B = nil then
        B := BuildBlock(PC);
      if (Prev <> nil) and (B <> nil) and (Gen = FBlockGen) then
      begin
        Prev.Link[1] := Prev.Link[0];
        Prev.Link[0] := B;
      end;
      Gen := FBlockGen;
    end;
    if FUseJit then
    begin
      if (B.Native = nil) and (B.Heat < JitHeat) then
      begin
        Inc(B.Heat);
        if B.Heat = JitHeat then
          B.Native := JitCompile(B);
      end;
      if B.Native <> nil then
      begin
        FInJit := True;
        Count := FJit.Invoke(B.Native, NativeUInt(Self), 0, 0, 0);
        FInJit := False;
        Inc(FJitBlocks);
        Next := S.PC;
        // (Blocks chained to: the last ran Count instructions, the others
        // are counted.)
        B := FJitLast;
        if FJitResetPending then
        begin
          FJitResetPending := False;
          FJit.Reset;
          Inc(FJitResets);
        end;
      end
      else
        Count := Execute(B.Insts, B.Count, Next);
    end
    else
      Count := Execute(B.Insts, B.Count, Next);
    S.PC := Next;
    Inc(InstructionsExecuted, Count);
    Inc(Now^, Count);
    // A polling block about to turn again: memory and registers stay as they
    // are until the next event (devices change them only then), so its turns
    // up to the deadline change nothing but time; they pass at once, as many
    // whole turns as would run.
    if B.Poll and (Next = B.PC) and not FIntPending and not FExitRequest and (Now^ < Deadline^) and
      (WatchPtr = nil) and (BlockProfile = nil) and PollQuiet(B) then
    begin
      var Turns := (Deadline^ - Now^ + B.Count - 1) div B.Count;
      Inc(Now^, Turns * B.Count);
      Inc(InstructionsExecuted, Turns * B.Count);
      Inc(PollCycles, Turns * B.Count);
      for var K := 1 to Min(Turns, Length(PCHistory)) do
      begin
        PCHistory[PCHistoryPos and 15] := B.PC;
        Inc(PCHistoryPos);
      end;
    end
    // The same for a turn of two blocks (the one before, then B): whole turns
    // that end before the deadline (the last, partial one runs as usual).
    else if (Prev <> nil) and (Next = Prev.PC) and not FIntPending and not FExitRequest and
      (WatchPtr = nil) and (BlockProfile = nil) and PollsWith(Prev, B) and PollQuiet(B) then
    begin
      var Turn := Prev.Count + B.Count;
      var Turns := (Deadline^ - Now^ - 1) div Turn;
      if Turns > 0 then
      begin
        Inc(Now^, Turns * Turn);
        Inc(InstructionsExecuted, Turns * Turn);
        Inc(PollCycles, Turns * Turn);
        for var K := 1 to Min(Turns, Length(PCHistory) div 2) do
        begin
          PCHistory[PCHistoryPos and 15] := Prev.PC;
          PCHistory[(PCHistoryPos + 1) and 15] := B.PC;
          Inc(PCHistoryPos, 2);
        end;
      end;
    end;
    // A loop that only counts down: its turns before the deadline (or before
    // its last one) pass at once, the counter as they would leave it.
    if (B.CountKind <> 0) and SkipCountdowns and (Next = B.PC) and not FIntPending and not FExitRequest and
      (Now^ < Deadline^) and (WatchPtr = nil) and (BlockProfile = nil) then
      SkipCountdown(B);
    // A spin that only waits: nothing changes until the next event, so the
    // time up to the deadline passes at once.
    if B.Spin and SkipSpins and (Next = B.PC) and not FIntPending and not FExitRequest and (Now^ < Deadline^) then
    begin
      Inc(SpinCycles, Deadline^ - Now^);
      Now^ := Deadline^;
    end;
    Prev := B;
    if FJitFull then
    begin
      // (The code writer is full: blocks and code start over.)
      FJitFull := False;
      ClearBlocks;
      Gen := FBlockGen;
      Prev := nil;
    end;
    if FExitRequest then
    begin
      FExitRequest := False;
      if not FIntPending then
        Break;
    end;
  end;
end;

// Whether a turn of a loop, the blocks in Blocks one after the other (each
// falling through to the next), only polls: the last ends with a non-likely
// conditional branch back to LoopPC, the others with none or a non-likely
// conditional branch (their delay slots run either way), and the other
// instructions are loads, register arithmetic and NOPs (no stores, traps,
// HI/LO, coprocessors) that read no register the turn writes unless the turn
// wrote it earlier. A turn then computes the same registers from the same
// memory and branches the same way. Its loads (Loads, Count) have addresses
// constant within the turn (LUI/ORI/ADDIU/XORI/ANDI from constants) or a
// register it never writes plus the offset.
function TEECPU.PollCode(const Blocks: array of PEEBlock; LoopPC: Cardinal; var Loads: array of TEEPollLoad;
  out LoadCount: Integer): Boolean;
var
  Known: array[0..32] of Boolean;
  Value: array[0..32] of Cardinal;
  Written, LiveIn, Dynamic: set of 0..32;

  procedure Read(R: Integer);
  begin
    if (R <> 0) and not (R in Written) then
      Include(LiveIn, R);
  end;

  // False: a write to GPR 0 through a field not mapped to the dummy (32).
  function Write(R: Integer): Boolean;
  begin
    Result := R <> 0;
    if R = 32 then
      Exit;
    Include(Written, R);
    Known[R] := False;
  end;

  function Conditional(H: Pointer): Boolean;
  begin
    Result := (H = @TEECPU.OpBEQ) or (H = @TEECPU.OpBNE) or (H = @TEECPU.OpBLEZ) or (H = @TEECPU.OpBGTZ) or
      (H = @TEECPU.OpBLTZ) or (H = @TEECPU.OpBGEZ);
  end;

begin
  Result := False;
  LoadCount := 0;
  Written := [];
  LiveIn := [];
  Dynamic := [];
  FillChar(Known, SizeOf(Known), 0);
  Known[0] := True;
  Value[0] := 0;
  for var N := 0 to High(Blocks) do
  begin
    var B := Blocks[N];
    // Where its branch is (-1: none, it runs on past its end).
    var BranchAt := -1;
    if (B.Count >= 2) and ((B.Insts[B.Count - 1].Flags and IFSlot) <> 0) then
      BranchAt := B.Count - 2;
    if N = High(Blocks) then
    begin
      if (BranchAt < 0) or not Conditional(B.Insts[BranchAt].Handler) or (B.Insts[BranchAt].Imm <> LoopPC) then
        Exit;
    end
    else if BranchAt >= 0 then
    begin
      if not Conditional(B.Insts[BranchAt].Handler) then
        Exit;
    end
    else if (B.Count > 0) and ((B.Insts[B.Count - 1].Flags and IFEnd) <> 0) then
      Exit;
    for var K := 0 to B.Count - 1 do
    begin
      var I := B.Insts + K;
      var H := I.Handler;
      if K = BranchAt then
      begin
        Read(I.S);
        if (H = @TEECPU.OpBEQ) or (H = @TEECPU.OpBNE) then
          Read(I.T);
      end
      else if H = @TEECPU.OpNOP then
      else if H = @TEECPU.OpLUI then
      begin
        if not Write(I.T) then Exit;
        Known[I.T] := True;
        Value[I.T] := I.Imm;
      end
      else if (H = @TEECPU.OpORI) or (H = @TEECPU.OpXORI) or (H = @TEECPU.OpANDI) or (H = @TEECPU.OpADDIU) then
      begin
        Read(I.S);
        var Was := Known[I.S];
        var V := Value[I.S];
        if not Write(I.T) then Exit;
        if Was then
        begin
          if H = @TEECPU.OpORI then V := V or I.Imm
          else if H = @TEECPU.OpXORI then V := V xor I.Imm
          else if H = @TEECPU.OpANDI then V := V and I.Imm
          else V := Add32(V, I.Imm);
          Known[I.T] := True;
          Value[I.T] := V;
        end;
      end
      else if (H = @TEECPU.OpSLTI) or (H = @TEECPU.OpSLTIU) or (H = @TEECPU.OpDADDIU) then
      begin
        Read(I.S);
        if not Write(I.T) then Exit;
      end
      else if (H = @TEECPU.OpADDU) or (H = @TEECPU.OpSUBU) or (H = @TEECPU.OpAND) or (H = @TEECPU.OpOR) or
        (H = @TEECPU.OpXOR) or (H = @TEECPU.OpNOR) or (H = @TEECPU.OpSLT) or (H = @TEECPU.OpSLTU) or
        (H = @TEECPU.OpDADDU) or (H = @TEECPU.OpDSUBU) then
      begin
        Read(I.S);
        Read(I.T);
        Write(I.D);
      end
      else if (H = @TEECPU.OpSLL) or (H = @TEECPU.OpSRL) or (H = @TEECPU.OpSRA) or (H = @TEECPU.OpDSLL) or
        (H = @TEECPU.OpDSRL) or (H = @TEECPU.OpDSRA) then
      begin
        Read(I.T);
        Write(I.D);
      end
      else if (H = @TEECPU.OpLB) or (H = @TEECPU.OpLBU) or (H = @TEECPU.OpLH) or (H = @TEECPU.OpLHU) or
        (H = @TEECPU.OpLW) or (H = @TEECPU.OpLWU) or (H = @TEECPU.OpLD) then
      begin
        if LoadCount > High(Loads) then
          Exit;
        Read(I.S);
        if Known[I.S] then
        begin
          Loads[LoadCount].Base := -1;
          Loads[LoadCount].Address := Add32(Value[I.S], I.Imm);
        end
        else
        begin
          Loads[LoadCount].Base := I.S;
          Loads[LoadCount].Address := I.Imm;
          Include(Dynamic, I.S);
        end;
        Inc(LoadCount);
        if not Write(I.T) then Exit;
      end
      else
        Exit;
    end;
  end;
  Result := (LiveIn * Written = []) and (Dynamic * Written = []);
end;

// A block that polls by itself (PollCode, a turn of one block).
procedure TEECPU.FindPoll(B: PEEBlock);
begin
  B.PollFirst := nil;
  B.PollPair := False;
  B.Poll := PollCode([B], B.PC, B.PollLoads, B.PollLoadCount);
end;

// Whether B is a loop that only counts down to its exit (see TEEBlock's
// Count fields): back to its start by its non-likely BNE or BGTZ, its other
// instructions NOPs and the counter's; registers it compares with that it
// does not write.
procedure TEECPU.FindCountdown(B: PEEBlock);
var
  Others: array[0..3] of Integer;
begin
  B.CountKind := 0;
  if (B.Count < 2) or ((B.Insts[B.Count - 1].Flags and IFSlot) = 0) then
    Exit;
  var Br := B.Insts + (B.Count - 2);
  if (Br.Imm <> B.PC) or ((Br.Handler <> @TEECPU.OpBNE) and (Br.Handler <> @TEECPU.OpBGTZ)) then
    Exit;
  var OtherCount := 0;
  for var K := 0 to B.Count - 1 do
    if (K <> B.Count - 2) and (B.Insts[K].Handler <> @TEECPU.OpNOP) then
    begin
      if OtherCount > High(Others) then
        Exit;
      Others[OtherCount] := K;
      Inc(OtherCount);
    end;
  // The register the branch tests (and the one it compares with).
  var Tested, Cmp: Integer;
  if Br.Handler = @TEECPU.OpBGTZ then
  begin
    Tested := Br.S;
    Cmp := 255;
  end
  else
  begin
    Tested := Br.S;
    Cmp := Br.T;
  end;
  if OtherCount = 1 then
  begin
    var I := B.Insts + Others[0];
    if ((I.Handler <> @TEECPU.OpADDIU) and (I.Handler <> @TEECPU.OpDADDIU)) or (I.Imm <> $FFFFFFFF) or
      (I.S <> I.T) or (I.T = 0) or (I.T > 31) then
      Exit;
    var C := Integer(I.T);
    if (Cmp <> 255) and (Tested <> C) then
    begin
      // BNE x, counter.
      Cmp := Tested;
      Tested := Br.T;
    end;
    if (Tested <> C) or (Cmp = C) or ((Cmp <> 255) and (Cmp > 31)) then
      Exit;
    B.CountKind := 1;
    B.CountReg := C;
    B.CountCmp := Cmp;
    B.CountWide := I.Handler = @TEECPU.OpDADDIU;
    B.CountAfter := Others[0] = B.Count - 1;
    Exit;
  end;
  if OtherCount <> 4 then
    Exit;
  var L1 := B.Insts + Others[0];
  var Add := B.Insts + Others[1];
  var St := B.Insts + Others[2];
  var L2 := B.Insts + Others[3];
  if (L1.Handler <> @TEECPU.OpLW) or (Add.Handler <> @TEECPU.OpADDIU) or (St.Handler <> @TEECPU.OpSW) or
    (L2.Handler <> @TEECPU.OpLW) or (Others[3] > B.Count - 3) then
    Exit;
  var A := Integer(L1.T);
  var V := Integer(L2.T);
  var Base := Integer(L1.S);
  if (A = 0) or (A > 31) or (V = 0) or (V > 31) or (Add.S <> A) or (Add.T <> A) or (Add.Imm <> $FFFFFFFF) or
    (St.T <> A) or (St.S <> Base) or (L2.S <> Base) or (Base = A) or (Base = V) or (L1.Imm <> St.Imm) or
    (L1.Imm <> L2.Imm) then
    Exit;
  if (Cmp <> 255) and (Tested <> V) then
  begin
    Cmp := Tested;
    Tested := Br.T;
  end;
  if (Tested <> V) or ((Cmp <> 255) and ((Cmp > 31) or (Cmp = A) or (Cmp = V))) then
    Exit;
  B.CountKind := 2;
  B.CountReg := A;
  B.CountReg2 := V;
  B.CountBase := Base;
  B.CountOffset := L1.Imm;
  B.CountCmp := Cmp;
  B.CountWide := False;
  B.CountAfter := False;
end;

// B (FindCountdown) about to turn again, nothing due before the deadline:
// the turns that would start before it, but its last one, pass at once.
// Turn J leaves the counter C0 - J; the branch goes on while it (before the
// decrement where that is in the delay slot) is not the compared register
// (equal as 64 bits: never unless that is a 32-bit value sign-extended, for
// a 32-bit counter) or above zero.
procedure TEECPU.SkipCountdown(B: PEEBlock);
const
  Never = High(Int64);
begin
  var Allowed := (Deadline^ - Now^ + B.Count - 1) div B.Count;
  var C0: Int64;
  var P: PByte := nil;
  var A: Cardinal := 0;
  if B.CountKind = 2 then
  begin
    A := Add32(Cardinal(S.GPR[B.CountBase].Lo), B.CountOffset);
    P := FReadMap[A shr 12];
    // (Not a word of the loop itself: its stores would change its code.)
    if (P = nil) or (FWriteMap[A shr 12] <> P) or ((A and 3) <> 0) or
      ((A - B.PC) < Cardinal(B.Count) * 4) then
      Exit;
    C0 := Integer(PCardinal(P + (A and $FFF))^);
  end
  else if B.CountWide then
    C0 := Int64(S.GPR[B.CountReg].Lo)
  else
  begin
    C0 := Integer(Cardinal(S.GPR[B.CountReg].Lo));
    if UInt64(C0) <> S.GPR[B.CountReg].Lo then
      Exit;
  end;
  // Turns up to and with the one that leaves the loop.
  var Turns: Int64;
  if B.CountCmp = 255 then
  begin
    if B.CountAfter then
    begin
      if C0 < 0 then
        Exit;
      Turns := C0 + 1;
    end
    else
    begin
      if C0 < 1 then
        Exit;
      Turns := C0;
    end;
  end
  else
  begin
    var X := Int64(S.GPR[B.CountCmp].Lo);
    if not B.CountWide and (X <> Integer(Cardinal(X))) then
      Turns := Never
    else
    begin
      var D: UInt64;
      if B.CountWide then
        D := UInt64(C0) - UInt64(X)
      else
        D := Cardinal(Cardinal(C0) - Cardinal(X));
      if B.CountAfter then
        Turns := Int64(Min(D, UInt64(Never - 1))) + 1
      else if D = 0 then
      begin
        if B.CountWide then Turns := Never else Turns := Int64(1) shl 32;
      end
      else
        Turns := Int64(Min(D, UInt64(Never)));
    end;
  end;
  var K := Min(Turns - 1, Allowed);
  if K <= 0 then
    Exit;
  if B.CountKind = 2 then
  begin
    var C := Cardinal(C0) - Cardinal(K);
    PCardinal(P + (A and $FFF))^ := C;
    Inc(FGenMap[A shr 12]^, Cardinal(K));
    S.GPR[B.CountReg].Lo := SX32(C);
    S.GPR[B.CountReg2].Lo := SX32(C);
  end
  else if B.CountWide then
    S.GPR[B.CountReg].Lo := UInt64(C0 - K)
  else
    S.GPR[B.CountReg].Lo := SX32(Cardinal(C0) - Cardinal(K));
  Inc(Now^, K * B.Count);
  Inc(InstructionsExecuted, K * B.Count);
  Inc(CountdownCycles, K * B.Count);
  for var J := 1 to Min(K, Length(PCHistory)) do
  begin
    PCHistory[PCHistoryPos and 15] := B.PC;
    Inc(PCHistoryPos);
  end;
end;

// Whether First then Second (the next block where First runs on past its
// end) are a turn of a polling loop back to First (PollCode); learned in
// Second.
function TEECPU.PollsWith(First, Second: PEEBlock): Boolean;
begin
  if (First = nil) or (Second = nil) or Second.Poll then
    Exit(False);
  if Second.PollFirst <> First then
  begin
    Second.PollFirst := First;
    Second.PollPair := (Second.PC = First.PC + Cardinal(First.Count) * 4) and not First.Spin and
      PollCode([First, Second], First.PC, Second.PollLoads, Second.PollLoadCount);
  end;
  Result := Second.PollPair;
end;
// Whether B's loads read memory that only changes at events: RAM and the
// other directly mapped pages, or INTC_STAT and INTC_MASK (read without
// side effects).
function TEECPU.PollQuiet(B: PEEBlock): Boolean;
begin
  for var K := 0 to B.PollLoadCount - 1 do
  begin
    var A := B.PollLoads[K].Address;
    if B.PollLoads[K].Base >= 0 then
      A := Add32(Cardinal(S.GPR[B.PollLoads[K].Base].Lo), A);
    if FReadMap[A shr 12] <> nil then
      Continue;
    var E := FPhys[A shr 12];
    if (E and PhysValid) = 0 then
      Exit(False);
    var Phys := (E and $FFFFF000) or (A and $FFF);
    if (Phys and not $13) <> $1000F000 then
      Exit(False);
  end;
  Result := True;
end;

procedure TEECPU.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
  FCop2.SerializeState(State);
  State.Field(FScratch^, PS2ScratchpadSize);
  State.Field(FInt0, SizeOf(FInt0));
  State.Field(FInt1, SizeOf(FInt1));
  State.Field(FIntDelay, SizeOf(FIntDelay));
  if State.Loading then
  begin
    S.GPR[0] := Default(TPS2Reg128);
    RebuildMaps;
    UpdateInterrupts;
  end;
end;

initialization
  EEJitWorkOutOffsets;

end.
