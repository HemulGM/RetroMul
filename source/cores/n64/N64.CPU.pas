unit N64.CPU;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, N64.Types, N64.SoftFloat,
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
  end;

  TN64CPU = class
  private
    const
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
    procedure ClearBlocks;
    function BlockKey(EntryLoad, EntryFP: Integer; Mode: Byte; Physical: Cardinal): PN64CPUBlock;
    function BuildBlock(PC: UInt64; Physical: Cardinal; Mode: Byte): PN64CPUBlock;
    function BlockValid(B: PN64CPUBlock): Boolean; inline;
    function FastFloat(Op: Cardinal; A, B: UInt64; out R: TSoftFloatResult; out Cycles: Cardinal; out Target: Integer): Boolean;
    function RunBlocks(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
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
    constructor Create(Bus: TN64Bus);
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
  EGuestFault = class(Exception);

constructor TN64CPU.Create(Bus: TN64Bus);
begin
  inherited Create;
  FBus := Bus;
  FUseBlocks := True;
  FBlockLimit := MaxBlocks;
  FChunkLimit := MaxStepChunks;
  ClearBlocks;
  Reset;
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
  if (FBlockCount >= FBlockLimit) or (FStepChunk >= FChunkLimit) or (FWordChunk >= FChunkLimit) then
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

function TN64CPU.RunBlocks(MaxSteps: Integer; Limit: UInt64; Context: Cardinal; out Clocks: UInt64): Integer;
begin
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
  while (Result < MaxSteps) and not Stop do
  begin
    FSlowSafe := False;
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
    end;
    if B.Count = 0 then
    begin
      FSlowSafe := B.SlowSafe;
      Break;
    end;
    Inc(FBlocksRun);
    var Step := StepOf(B, First);
    var Last := StepOf(B, B.Count - 1);
    while True do
    begin
      var C: Cardinal := Step.Clocks;
      var Physical2: Cardinal := 0;
      var Cached := False;
      var Kind := Step.Kind;
      var FPA: UInt64 := 0;
      var FPB: UInt64 := 0;
      var FPResult: TSoftFloatResult;
      var FPCycles: Cardinal;
      var FPTarget: Integer;
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
          FPB := 0;
          if (BaseMode and ModeFR) <> 0 then
          begin
            FPA := FPR[Step.D];
            if Binary then FPB := FPR[Step.T];
            if F in [16, 20] then
            begin FPA := FPA and $FFFFFFFF; FPB := FPB and $FFFFFFFF end;
          end
          else
          begin
            FPA := FPBits(Integer(Step.D), F);
            if Binary then FPB := FPBits(Integer(Step.T), F);
          end;
          if Kind = KindCop1Compare then
          begin
            if SFIsNaN(FPA, F) or SFIsNaN(FPB, F) then
            begin
              FSlowSafe := True;
              Stop := True;
              Break;
            end;
          end
          else if not FastFloat(Step.Op, FPA, FPB, FPResult, FPCycles, FPTarget) then
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
      var PC2 := FPC;
      FInstructionPC := PC2;
      FInDelay := FDelay;
      FDelay := False;
      FPC := FNextPC;
      FNextPC := Add64(FNextPC, 4);
      var T := Integer(Step.T);
      var A := GPR[Step.S];
      case Kind of
        KindSpecial + 0:
          GPR[Step.D] := SX32(GPR[T] shl Step.N);
        KindSpecial + 2:
          GPR[Step.D] := SX32((GPR[T] and $FFFFFFFF) shr Step.N);
        KindSpecial + 3:
          GPR[Step.D] := SX32(SAR(GPR[T], Step.N, 32));
        KindSpecial + 4:
          GPR[Step.D] := SX32(GPR[T] shl (A and 31));
        KindSpecial + 6:
          GPR[Step.D] := SX32((GPR[T] and $FFFFFFFF) shr (A and 31));
        KindSpecial + 7:
          GPR[Step.D] := SX32(SAR(GPR[T], A and 31, 32));
        KindSpecial + 8:
          Branch(True, False, A);
        KindSpecial + 9:
          begin
            GPR[Step.D] := Add64(PC2, 8);
            Branch(True, False, A);
          end;
        KindSpecial + 15:
          ; // SYNC
          KindSpecial + 16:
          GPR[Step.D] := HI;
        KindSpecial + 17:
          HI := A;
        KindSpecial + 18:
          GPR[Step.D] := LO;
        KindSpecial + 19:
          LO := A;
        KindSpecial + 20:
          GPR[Step.D] := GPR[T] shl (A and 63);
        KindSpecial + 22:
          GPR[Step.D] := GPR[T] shr (A and 63);
        KindSpecial + 23:
          GPR[Step.D] := SAR(GPR[T], A and 63, 64);
        KindSpecial + 24, KindSpecial + 25:
          begin
            var BB := GPR[T];
            var V: UInt64;
            if Kind = KindSpecial + 24 then
              Multiply64(SX(A, 32), SX(BB, 32), True, HI, V)
            else
              V := (A and $FFFFFFFF) * (BB and $FFFFFFFF);
            LO := SX(V, 32);
            HI := SX(V shr 32, 32);
          end;
        KindSpecial + 26, KindSpecial + 27:
          begin
            var BB := GPR[T];
            if Kind = KindSpecial + 26 then
              Divide64(SX(A, 32), SX(BB, 32), True, HI, LO)
            else
              Divide64(A and $FFFFFFFF, BB and $FFFFFFFF, False, HI, LO);
            HI := SX(HI, 32);
            LO := SX(LO, 32);
          end;
        KindSpecial + 28, KindSpecial + 29:
          Multiply64(A, GPR[T], Kind = KindSpecial + 28, HI, LO);
        KindSpecial + 30, KindSpecial + 31:
          Divide64(A, GPR[T], Kind = KindSpecial + 30, HI, LO);
        KindSpecial + 33:
          GPR[Step.D] := SX32(Add64(A, GPR[T]));
        KindSpecial + 35:
          GPR[Step.D] := SX32(Sub64(A, GPR[T]));
        KindSpecial + 36:
          GPR[Step.D] := A and GPR[T];
        KindSpecial + 37:
          GPR[Step.D] := A or GPR[T];
        KindSpecial + 38:
          GPR[Step.D] := A xor GPR[T];
        KindSpecial + 39:
          GPR[Step.D] := not (A or GPR[T]);
        KindSpecial + 42:
          GPR[Step.D] := Ord(SignedLess(A, GPR[T]));
        KindSpecial + 43:
          GPR[Step.D] := Ord(A < GPR[T]);
        KindSpecial + 45:
          GPR[Step.D] := Add64(A, GPR[T]);
        KindSpecial + 47:
          GPR[Step.D] := Sub64(A, GPR[T]);
        KindSpecial + 56:
          GPR[Step.D] := GPR[T] shl Step.N;
        KindSpecial + 58:
          GPR[Step.D] := GPR[T] shr Step.N;
        KindSpecial + 59:
          GPR[Step.D] := SAR(GPR[T], Step.N, 64);
        KindSpecial + 60:
          GPR[Step.D] := GPR[T] shl (Step.N + 32);
        KindSpecial + 62:
          GPR[Step.D] := GPR[T] shr (Step.N + 32);
        KindSpecial + 63:
          GPR[Step.D] := SAR(GPR[T], Step.N + 32, 64);
        1:
          begin
            var Taken2 := SignedLess(A, 0);
            if (T and 1) <> 0 then
              Taken2 := not Taken2;
            if T >= 16 then
              GPR[31] := Add64(PC2, 8);
            Branch(Taken2, (T and 2) <> 0, Add64(FPC, Step.Value shl 2));
          end;
        2, 3:
          begin
            if Kind = 3 then
              GPR[31] := Add64(PC2, 8);
            Branch(True, False, (FPC and $FFFFFFFFF0000000) or ((Step.Op and $3FFFFFF) shl 2));
          end;
        4, 20:
          Branch(A = GPR[T], Kind = 20, Add64(FPC, Step.Value shl 2));
        5, 21:
          Branch(A <> GPR[T], Kind = 21, Add64(FPC, Step.Value shl 2));
        6, 22:
          Branch(not SignedLess(0, A), Kind = 22, Add64(FPC, Step.Value shl 2));
        7, 23:
          Branch(SignedLess(0, A), Kind = 23, Add64(FPC, Step.Value shl 2));
        9:
          GPR[T] := SX32(Add64(A, Step.Value));
        10:
          GPR[T] := Ord(SignedLess(A, Step.Value));
        11:
          GPR[T] := Ord(A < Step.Value);
        12:
          GPR[T] := A and (Step.Op and $FFFF);
        13:
          GPR[T] := A or (Step.Op and $FFFF);
        14:
          GPR[T] := A xor (Step.Op and $FFFF);
        15:
          GPR[T] := SX32((Step.Op and $FFFF) shl 16);
        KindLuiPair:
          begin
            // The ORI/ADDIU after the LUI: its Step as FastRun takes it.
            Inc(Result);
            Inc(Clk);
            FInstructionPC := FPC;
            FInDelay := False;
            FPC := FNextPC;
            FNextPC := Add64(FNextPC, 4);
            GPR[T] := Step.Value;
          end;
        32:
          GPR[T] := SX8(FBus.ReadRAM8(Physical2));
        33:
          GPR[T] := SX16(FBus.ReadRAM16(Physical2));
        35:
          GPR[T] := SX32(FBus.ReadRAM32(Physical2));
        36:
          GPR[T] := FBus.ReadRAM8(Physical2);
        37:
          GPR[T] := FBus.ReadRAM16(Physical2);
        39:
          GPR[T] := FBus.ReadRAM32(Physical2);
        49:
          SetFPBits(T, 16, FBus.ReadRAM32(Physical2));
        53:
          SetFPBits(T, 17, (UInt64(FBus.ReadRAM32(Physical2)) shl 32) or FBus.ReadRAM32(Physical2 + 4));
        55:
          GPR[T] := (UInt64(FBus.ReadRAM32(Physical2)) shl 32) or FBus.ReadRAM32(Physical2 + 4);
        63:
          begin
            var V := GPR[T];
            FBus.WriteRAM32(Physical2, Cardinal(V shr 32));
            FBus.WriteRAM32(Physical2 + 4, Cardinal(V and $FFFFFFFF));
          end;
        40:
          begin
            FBus.WriteRAM8(Physical2, Byte(GPR[T] and $FF));
          end;
        41:
          begin
            FBus.WriteRAM8(Physical2, Byte((GPR[T] shr 8) and $FF));
            FBus.WriteRAM8(Physical2 + 1, Byte(GPR[T] and $FF));
          end;
        43:
          begin
            FBus.WriteRAM32(Physical2, Cardinal(GPR[T] and $FFFFFFFF));
          end;
        57:
          begin
            var V := FPBits(T, 16);
            FBus.WriteRAM32(Physical2, Cardinal(V and $FFFFFFFF));
          end;
        61:
          begin
            var V := FPBits(T, 17);
            FBus.WriteRAM32(Physical2, Cardinal(V shr 32));
            FBus.WriteRAM32(Physical2 + 4, Cardinal(V and $FFFFFFFF));
          end;
        KindCop1Move + 0:
          GPR[T] := SX(FPBits(Step.D, 16), 32);
        KindCop1Move + 1:
          GPR[T] := FPBits(Step.D, 17);
        KindCop1Move + 4:
          SetFPBits(Step.D, 16, GPR[T]);
        KindCop1Move + 5:
          SetFPBits(Step.D, 17, GPR[T]);
        KindCop1Compare:
          begin
            var F := Integer(Step.S);
            var Fn := Integer(Step.Op and 63);
            FCR31 := FCR31 and not $3F000;
            Inc(C, FPClocks(FPA, FPB, F, Fn) - 1);
            var Unordered, Equal, Less: Boolean;
            SFCompare(FPA, FPB, F, Unordered, Equal, Less);
            FCR31 := FCR31 and not $800000;
            if (((Fn and 1) <> 0) and Unordered) or (((Fn and 2) <> 0) and Equal) or (((Fn and 4) <> 0) and Less) then
              FCR31 := FCR31 or $800000;
          end;
        KindCop1Arith:
          begin
            // As Cop1, which FastFloat found takes no special path.
            FCR31 := FCR31 and not $3F000;
            Inc(C, FPCycles - 1);
            // FPExceptions of the result's events (none traps).
            FCR31 := FCR31 or ((FPResult.Events and 31) shl 12);
            FCR31 := FCR31 or (((FPResult.Events and not (FCR31 shr 7)) and 31) shl 2);
            var D := Integer(Step.N);
            if (FPTarget in [16, 20]) and ((CP0[12] and $4000000) <> 0) then
              FPR[D] := FPResult.Bits and $FFFFFFFF
            else
              SetFPBits(D, FPTarget, FPResult.Bits);
            // A canonical NOP after successful arithmetic has no reads or
            // side effects beyond its PC, one clock and clearing FP hazards.
            // Retain the decoded NOP for exact budget/resume boundaries.
            if (Step <> Last) and (Clk + C < Limit) and (Result + 1 < MaxSteps) then
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
        KindCop1Mov:
          SetFPBits(Integer(Step.N), 17, FPBits(Integer(Step.D), 17));
        KindCop1Branch:
          begin
            FCR31 := FCR31 and not $3F000;
            Branch(((FCR31 and $800000) <> 0) = ((T and 1) <> 0), (T and 2) <> 0, Add64(FPC, Step.Value shl 2));
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
      (FBus.CodeGeneration(FIdlePhysical) = FIdleGeneration) then Exit(True);
    Result := (FBus.ReadRAM32(FIdlePhysical) = FIdleBranch) and (FBus.ReadRAM32(FIdlePhysical + 4) = FIdleSlot);
    if Result then FIdleGeneration := FBus.CodeGeneration(FIdlePhysical);
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

end.

