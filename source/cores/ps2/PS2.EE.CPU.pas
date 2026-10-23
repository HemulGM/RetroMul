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
  System.SysUtils, System.Math, Core.Snapshots, PS2.Types;

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
    constructor Create;
    procedure Reset; virtual;
    function ReadControl(Index: Integer): Cardinal; virtual;
    procedure WriteControl(Index: Integer; Value: Cardinal); virtual;
    // A COP2 operation (bit 25 set); False: reserved instruction.
    function Execute(Op: Cardinal): Boolean; virtual;
    // Interlocked transfers wait for a running VU0 micro program.
    procedure Interlock; virtual;
    // BC2F/BC2T condition.
    function Condition: Boolean; virtual;
    procedure SerializeState(State: TStateArchive); virtual;
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

  TEEInst = record
    Handler: Pointer;
    Imm: Cardinal;
    Addr: Cardinal;
    Op: Cardinal;
    S, T, D: TPS2RegIndex;
    Sa: Byte;
    Flags: Byte;
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
    FIntPending: Boolean;
    FInt0, FInt1: Boolean;
    FExitRequest: Boolean;
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
    function OpTrapHLE(I: PEEInst): Boolean;
  public
    S: TEEState;
    // Advanced by executed instructions; the run loop stops at Deadline^.
    Now, Deadline: PInt64;
    InstructionsExecuted: Int64;
    // Diagnostics (not serialized).
    ExceptionCount: Int64;
    LastExceptionPC, LastExceptionCode: Cardinal;
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
    property Count: Cardinal read GetCount;
  end;

// Guest float helpers shared with VU code: inputs with exponent 0 read as
// signed zero and with exponent 255 as the largest finite value.
function EEFloatIn(V: Cardinal): Double; inline;
function PS2FloatAdd(A, B: Cardinal; out Flags: Cardinal): Cardinal;
// Orders PS2 floats like the MAX/MIN instructions do.
function PS2FloatKey(V: Cardinal): Integer; inline;

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

function TEECop2.Condition: Boolean;
begin
  Result := False;
end;

procedure TEECop2.SerializeState(State: TStateArchive);
begin
  State.Field(VF, SizeOf(VF));
  State.Field(VI, SizeOf(VI));
end;

{ TEECPU }

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
  Reset;
end;

destructor TEECPU.Destroy;
begin
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
  FIntPending := ((SR and (EESRIE or EESREIE or EESREXL or EESRERL)) = (EESRIE or EESREIE)) and
    ((Cause and SR and $8C00) <> 0);
  if FIntPending then
    FExitRequest := True;
end;

procedure TEECPU.SetInt0(Active: Boolean);
begin
  if FInt0 <> Active then
  begin
    FInt0 := Active;
    UpdateInterrupts;
  end;
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
    Exit(Raise_(I, EEExcSyscall));
  if ((I.Flags and IFSlot) <> 0) and FBranchTaken then
    S.PC := FBranchTarget
  else
    S.PC := I.Addr + 4;
  FOnSyscall(Self);
  FStop := StopPC;
  Result := True;
end;

function TEECPU.OpTrapHLE(I: PEEInst): Boolean;
begin
  if not Assigned(FOnTrap) then
    Exit(Raise_(I, EEExcReserved));
  S.PC := I.Addr + 4;
  FOnTrap(Self, I.Op and $03FFFFFF);
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
    FCop2.VF[I.Op shr 16 and 31] := V;
end;

function TEECPU.OpSQC2(I: PEEInst): Boolean;
begin
  var A := Add32(Cardinal(S.GPR[I.S].Lo), I.Imm);
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
  S.FPR[I.D] := FPUResult(EEFloatIn(S.FPR[I.S]) * EEFloatIn(S.FPR[I.T]), SetO, SetU);
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
  var R: Cardinal;
  if (Op and 1) = 0 then
    R := FAdd(S.ACC, P)
  else
    R := FAdd(S.ACC, P xor $80000000);
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
          S.FPR[I.D] := FPUResult(EEFloatIn(Fs) / EEFloatIn(Ft), 0, 0);
      end;
    $04:
      begin
        S.FCR31 := S.FCR31 and not Cardinal(FCRInvalid or FCRDivide);
        if (Ft and $7F800000) = 0 then
          S.FPR[I.D] := Ft and $80000000
        else
        begin
          if (Ft and $80000000) <> 0 then
            S.FCR31 := S.FCR31 or FCRInvalid or FCRStickyInvalid;
          S.FPR[I.D] := FPUResult(Sqrt(Abs(EEFloatIn(Ft))), 0, 0);
        end;
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
          var Root: Single := Sqrt(Abs(EEFloatIn(Ft)));
          S.FPR[I.D] := FPUResult(EEFloatIn(Fs) / Root, 0, 0);
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
          FCop2.Interlock;
        S.GPR[I.T] := FCop2.VF[Fs];
      end;
    2:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock;
        S.GPR[I.T].Lo := SX32(FCop2.ReadControl(Fs));
      end;
    5:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock;
        if Fs <> 0 then
          FCop2.VF[Fs] := S.GPR[I.T];
      end;
    6:
      begin
        if (Op and 1) <> 0 then
          FCop2.Interlock;
        FCop2.WriteControl(Fs, Cardinal(S.GPR[I.T].Lo));
        FStop := StopLeave;
        Exit(True);
      end;
    8:
      begin
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
        var Sub := I.Sa = 20;
        // Halfword k accumulates into LO/HI word slots 0,1 (LO), 0,1 (HI), 2,3 (LO), 2,3 (HI).
        for var K := 0 to 7 do
        begin
          var P := Integer(A.SH[K]) * Integer(B.SH[K]);
          var Slot := (K and 1) + (K shr 2) * 2;
          if ((K shr 1) and 1) = 0 then
          begin
            if Sub then
              S.LO.UW[Slot] := Sub32(S.LO.UW[Slot], Cardinal(P))
            else
              S.LO.UW[Slot] := Add32(S.LO.UW[Slot], Cardinal(P));
          end
          else if Sub then
            S.HI.UW[Slot] := Sub32(S.HI.UW[Slot], Cardinal(P))
          else
            S.HI.UW[Slot] := Add32(S.HI.UW[Slot], Cardinal(P));
        end;
        R.UW[0] := S.LO.UW[0];
        R.UW[1] := S.HI.UW[0];
        R.UW[2] := S.LO.UW[2];
        R.UW[3] := S.HI.UW[2];
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
        var P: array[0..7] of Cardinal;
        for var K := 0 to 7 do
          P[K] := Cardinal(Integer(A.SH[K]) * Integer(B.SH[K]));
        S.LO.UW[0] := P[0];
        S.LO.UW[1] := P[1];
        S.HI.UW[0] := P[2];
        S.HI.UW[1] := P[3];
        S.LO.UW[2] := P[4];
        S.LO.UW[3] := P[5];
        S.HI.UW[2] := P[6];
        S.HI.UW[3] := P[7];
        R.UW[0] := P[0];
        R.UW[1] := P[2];
        R.UW[2] := P[4];
        R.UW[3] := P[6];
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
    $1C: H := @TEECPU.OpMMI;
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
    if Slot and Branch and ((Insts[Count - 1].Flags and IFLikely) = 0) and (Count < MaxBlockInsts) then
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
  try
    RunBlocks;
  finally
    ClearExceptions(False);
    SetExceptionMask(FHostMaskSaved);
    SetRoundMode(FHostRoundSaved);
  end;
end;

procedure TEECPU.RunBlocks;
var
  Prev, B: PEEBlock;
  Next: Cardinal;
  Count: Integer;
  Gen: Cardinal;
begin
  // Kept apart from Run's exception frame so its variables stay in registers.
  FExitRequest := False;
  Prev := nil;
  Gen := FBlockGen;
  while Now^ < Deadline^ do
  begin
    if FIntPending then
    begin
      EnterException(EEExcInterrupt);
      Prev := nil;
    end;
    var PC := S.PC;
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
    Count := Execute(B.Insts, B.Count, Next);
    S.PC := Next;
    Inc(InstructionsExecuted, Count);
    Inc(Now^, Count);
    Prev := B;
    if FExitRequest then
    begin
      FExitRequest := False;
      if not FIntPending then
        Break;
    end;
  end;
end;

procedure TEECPU.SerializeState(State: TStateArchive);
begin
  State.Field(S, SizeOf(S));
  FCop2.SerializeState(State);
  State.Field(FScratch^, PS2ScratchpadSize);
  State.Field(FInt0, SizeOf(FInt0));
  State.Field(FInt1, SizeOf(FInt1));
  if State.Loading then
  begin
    S.GPR[0] := Default(TPS2Reg128);
    RebuildMaps;
    UpdateInterrupts;
  end;
end;

end.
