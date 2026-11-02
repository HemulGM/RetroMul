unit PSP.CPU.JIT;

// Allegrex blocks as generated code (HW.JIT), run in place of the
// interpreter's loop (TPSPCPU.Runner) with its accounting exactly.
//
// A block starts where the interpreter's PC is with NPC = PC + 4 and runs
// up to a branch and its delay slot, an instruction that calls the kernel
// (SYSCALL, BREAK, HALT, a reserved one), its page's end or MaxBlock words.
// It is made from the interpreter's decoded entries once it has been entered
// Hot times (until then the interpreter runs it). Its code takes all its
// cycles from the budget on entry where they fit (else the interpreter runs
// what is left of the budget) and gives back those of a likely branch's
// nullified delay slot. The common integer instructions, branches, jumps,
// FPR moves, VFPU scalar moves and scalar/quad loads and stores (aligned
// or not: RAM directly, the rest through the page table) are written out;
// every other instruction calls
// the interpreter's handler (DecodeOp), with PC, NPC and CurPC as the
// interpreter has them where it may read them, and the code stops after it
// where it stopped the run or used up the cycles left. A store that reaches
// a code page goes through TPSPMemory (which re-decodes); where it changed a
// block's word the block is dropped and the code stops after the store.
// After its last instruction a block goes on into the next block's code: by
// direct links (made the first time that way is taken) or, after JR/JALR,
// by a look-up of the block table; else back to Run. Blocks are dropped when
// their words change (CodeWritten; words that change often are left to the
// interpreter) or the decoded code is dropped (Flushed).
//
// PSPJIT=off (the interpreter), model (HW.JIT's model runs the code), stats
// (counts at the end); several with commas.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
// (Guest addresses wrap.)
{$Q-}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Generics.Collections, HW.JIT, PSP.Types, PSP.Memory,
  PSP.CPU;

const
  PSPJitMaxBlock = 128;

type
  PPSPJitBlock = ^TPSPJitBlock;
  PPSPJitExit = ^TPSPJitExit;

  // A way out of a block's code to a known PC: its jump (Site) goes to its
  // stub (back to Run) or, linked, into the code of the block at Target.
  TPSPJitExit = record
    Block: PPSPJitBlock;
    Target: Cardinal;
    Site, Stub: NativeInt;
    Linked: PPSPJitBlock;
  end;

  TPSPJitState = (bsCold, bsCompiled, bsNone, bsDead);

  TPSPJitBlock = record
    PC: Cardinal;
    Code: Pointer;
    Physical: Cardinal;
    // Instructions (all of them run: its cycles), entries since made.
    Count, Heat: Integer;
    State: TPSPJitState;
    Exits: TArray<PPSPJitExit>;
    Incoming: TList<PPSPJitExit>;
  end;

  // A JR or JALR's last target and its block (kept until all code goes).
  PPSPJitSlot = ^TPSPJitSlot;
  TPSPJitSlot = record
    PC: Cardinal;
    Block: PPSPJitBlock;
  end;

  PPSPJitPage = ^TPSPJitPage;
  TPSPJitPage = record
    Entries: array[0..(PSPPageSize div 4) - 1] of PPSPJitBlock;
    // Words that compiled blocks cover, and the instructions they were
    // made from (a store of the same word changes nothing).
    Covered: array[0..(PSPPageSize div 128) - 1] of Cardinal;
    Ops: array[0..(PSPPageSize div 4) - 1] of Cardinal;
    // Times a word's change dropped blocks (often: no block takes it).
    Changes: array[0..(PSPPageSize div 4) - 1] of Byte;
    Blocks: TList<PPSPJitBlock>;
  end;

  TPSPJitOption = (joModel, joStats);
  TPSPJitOptions = set of TPSPJitOption;

  // Where an instruction is, and the PC after it (Dynamic: in the Target
  // register) and the cycles given back when the code leaves after it.
  TPSPJitAt = record
    Addr, Next: Cardinal;
    Dynamic: Boolean;
    Refund: Integer;
  end;

  // An access's way out of line (no page, or a store into code).
  TPSPJitSlow = record
    // (Table: the way through the page table, -1 none.)
    Slow, Back, Hit, Table: TJitLabel;
    Routine: Pointer;
    Kind: Integer;
    Store: Boolean;
    // The register loaded or stored (a GPR or an FPR).
    Reg: TJitOp;
  end;

  TPSPJitHitExit = record
    L: TJitLabel;
    At: TPSPJitAt;
  end;

  TPSPRecompiler = class(TPSPRunner)
  private
    FCPU: TPSPCPU;
    FMemory: TPSPMemory;
    FJ: TJitAsm;
    FOptions: TPSPJitOptions;
    FEnabled: Boolean;
    // RAM is one host buffer (the code reaches it without the page table).
    FRamDirect: Boolean;
    // Set when a block is dropped (the code running leaves after the store).
    FHit: Byte;
    FInCode, FInRun, FResetPending: Boolean;
    FLastExit: PPSPJitExit;
    FPages: TArray<PPSPJitPage>;
    FAll: TList<PPSPJitBlock>;
    FAllExits: TList<PPSPJitExit>;
    FSlots: TList<PPSPJitSlot>;
    // (A slot's block before its first: no code.)
    FNoBlock: TPSPJitBlock;
    FEnter, FPrologue, FExit, FLookup: NativeInt;
    FCompiled, FInvokes, FInterpreted, FLinks, FKills, FResets: Int64;
    FDead: Integer;
    // While a block is written: what goes out of line.
    FSlow: TList<TPSPJitSlow>;
    FHitExits: TList<TPSPJitHitExit>;
    FStatic: TList<PPSPJitExit>;
    FBlock: PPSPJitBlock;
    function PageOf(PC: Cardinal): PPSPJitPage;
    function Lookup(PC: Cardinal): PPSPJitBlock;
    function Scan(PC: Cardinal): Integer;
    procedure Kill(B: PPSPJitBlock);
    procedure KillAll;
    procedure ResetCode;
    procedure Link(E: PPSPJitExit; B: PPSPJitBlock);
    procedure EmitShared;
    procedure Compile(B: PPSPJitBlock);
    procedure Execute(B: PPSPJitBlock);
    procedure RunBlocks(C: TPSPCPU);
    procedure Interpret(Steps: Integer);
    procedure SetEnabled(Value: Boolean);
    procedure Cover(Page: PPSPJitPage; B: PPSPJitBlock);
    procedure Recover(Page: PPSPJitPage);
    procedure WriteState(const At: TPSPJitAt);
    function HitExit(const At: TPSPJitAt): TJitLabel;
    procedure EmitCall(const At: TPSPJitAt; Op: Cardinal; Handler: Pointer; State: Boolean);
    procedure EmitHost(Kind: Integer; Store: Boolean; const Reg: TJitOp);
    procedure EmitTable(const S: TPSPJitSlow);
    procedure EmitAccess(var S: TPSPJitSlow; Op: Cardinal);
    procedure EmitQuad(const At: TPSPJitAt; Op: Cardinal; Store: Boolean; Handler: Pointer);
    procedure EmitLoad(Op: Cardinal; Kind: Integer; const Reg: TJitOp);
    procedure EmitStore(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; const Reg: TJitOp);
    function EmitInstr(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; Handler: Pointer): Boolean;
    procedure EmitStatic(Target, Last: Cardinal; Refund: Integer);
    procedure EmitDelay(A: Cardinal; Op: Cardinal; Kind: Integer; Handler: Pointer; Dynamic: Boolean; Next: Cardinal);
  public
    constructor Create(CPU: TPSPCPU; Options: TPSPJitOptions);
    destructor Destroy; override;
    procedure Run(C: TPSPCPU); override;
    procedure CodeWritten(Address, Size: Cardinal); override;
    procedure Flushed; override;
    // False: Run interprets (the blocks are kept).
    property Enabled: Boolean read FEnabled write SetEnabled;
    property Compiled: Int64 read FCompiled;
    property Invokes: Int64 read FInvokes;
    property Interpreted: Int64 read FInterpreted;
  end;

var
  // Entries before a block is compiled.
  PSPJitHot: Integer = 8;

// PSPJIT's options; Off when it says off.
function PSPJitOptions(out Off: Boolean): TPSPJitOptions;
// A recompiler for CPU as PSPJIT asks (nil: off, or no code generator here
// and no model asked for). It sets itself as CPU's runner.
function CreatePSPRecompiler(CPU: TPSPCPU): TPSPRecompiler;

implementation

uses
  System.Math, PSP.VFPU;

type
  TJitKind = (jkNop, jkHandler, jkPure, jkEnd, jkHBranch, jkLVS, jkSVS, jkLVQ, jkSVQ, jkMFV, jkMTV, jkSLL, jkSRL, jkSRA,
    jkROTR, jkMOVZ, jkMOVN, jkMFHI, jkMTHI, jkMFLO, jkMTLO, jkADDU, jkSUBU, jkAND, jkOR, jkXOR, jkNOR, jkSLT, jkSLTU,
    jkMAX, jkMIN, jkADDIU, jkSLTI, jkSLTIU, jkANDI, jkORI, jkXORI, jkLUI, jkMFC0, jkEXT, jkINS, jkWSBH, jkWSBW, jkSEB,
    jkSEH, jkLB, jkLH, jkLW, jkLBU, jkLHU, jkSB, jkSH, jkSW, jkLWC1, jkSWC1, jkMFC1, jkMTC1, jkJR, jkJALR, jkJ, jkJAL,
    jkB, jkBEQ, jkBNE, jkBLEZ, jkBGTZ, jkBLTZ, jkBGEZ, jkBLTZAL, jkBGEZAL, jkBEQL, jkBNEL, jkBLEZL, jkBGTZL, jkBLTZL,
    jkBGEZL, jkBLTZALL, jkBGEZALL);

const
  // An instruction of each kind the code writes out: its handler (DecodeOp)
  // is the kind's.
  KindSample: array[jkSLL..jkBGEZALL] of Cardinal = (
    $00000800, $00000802, $00000803, $00200802, $0000080A, $0000080B, $00000810, $00000011, $00000812, $00000013,
    $00000821, $00000823, $00000824, $00000825, $00000826, $00000827, $0000082A, $0000082B, $0000082C, $0000082D,
    $24010000, $28010000, $2C010000, $30010000, $34010000, $38010000, $3C010000, $40010000,
    $7C010000, $7C010004, $7C0008A0, $7C0008E0, $7C000C20, $7C000E20,
    $80010000, $84010000, $8C010000, $90010000, $94010000, $A0000000, $A4000000, $AC000000,
    $C4000000, $E4000000, $44010000, $44800000,
    $00000008, $00000009, $08000000, $0C000000, $10000000, $10200000, $14000000, $18000000, $1C000000,
    $04000000, $04010000, $04100000, $04110000,
    $50000000, $54000000, $58000000, $5C000000, $04020000, $04030000, $04120000, $04130000);
  // SYSCALL, BREAK, HALT.
  EndSample: array[0..2] of Cardinal = ($0000000C, $0000000D, $70000000);
  // Handlers of registers and memory alone (called as they are: no PC, NPC,
  // CurPC or budget for them, no stop, no kernel): SLLV, SRLV, ROTRV, SRAV,
  // CLZ, CLO, MULT, MULTU, DIV, DIVU, MADD, MADDU, MSUB, MSUBU, BITREV, LWL,
  // LWR, SWL, SWR, LL, SC.
  PureSample: array[0..20] of Cardinal = ($00000804, $00000806, $00000846, $00000807, $00000816, $00000817,
    $00000018, $00000019, $0000001A, $0000001B, $0000001C, $0000001D, $0000002E, $0000002F, $7C000D20,
    $88010000, $98010000, $A8000000, $B8000000, $C0010000, $E0010000);

  JitBufferSize = 64 * 1024 * 1024;
  MaxDead = 65536;
  MaxChanges = 8;

  // A host pointer's width (the model runs on 32-bit hosts too).
{$IFDEF CPU64BITS}
  JPtr = jw64;
  PtrShift = 3;
{$ELSE}
  JPtr = jw32;
  PtrShift = 2;
{$ENDIF}

  jrPages = jrS0;
  jrMarks = jrS1;
  jrTarget = jrS2;
  jrRAM = jrS3;
  JRAM: TJitOp = (Kind: okReg; Reg: jrRAM);
  JPages: TJitOp = (Kind: okReg; Reg: jrPages);
  JMarks: TJitOp = (Kind: okReg; Reg: jrMarks);
  JTarget: TJitOp = (Kind: okReg; Reg: jrTarget);

var
  KindHandler: array[jkSLL..jkBGEZALL] of Pointer;
  EndHandler: array[0..2] of Pointer;
  PureHandler: array[0..High(PureSample)] of Pointer;
  KindsReady: Boolean;
  OffGPR, OffFPR, OffHI, OffLO, OffPC, OffNPC, OffCurPC, OffCOP0, OffStopping, OffRemaining, OffHit, OffLastExit,
    OffBlockPC, OffBlockCode, OffSlotPC, OffSlotBlock, OffV: Integer;

function HandlerOf(Op: Cardinal): Pointer;
begin
  var H: TPSPOpHandler := DecodeOp(Op);
  Result := @H;
end;

procedure PrepareKinds;
begin
  if KindsReady then
    Exit;
  for var K := Low(KindSample) to High(KindSample) do
    KindHandler[K] := HandlerOf(KindSample[K]);
  for var I := 0 to High(EndSample) do
    EndHandler[I] := HandlerOf(EndSample[I]);
  for var I := 0 to High(PureSample) do
    PureHandler[I] := HandlerOf(PureSample[I]);
  OffGPR := Integer(NativeUInt(@TPSPCPU(nil).Ctx.GPR[0]));
  OffFPR := Integer(NativeUInt(@TPSPCPU(nil).Ctx.FPR[0]));
  OffHI := Integer(NativeUInt(@TPSPCPU(nil).Ctx.HI));
  OffLO := Integer(NativeUInt(@TPSPCPU(nil).Ctx.LO));
  OffPC := Integer(NativeUInt(@TPSPCPU(nil).Ctx.PC));
  OffNPC := Integer(NativeUInt(@TPSPCPU(nil).Ctx.NPC));
  OffCurPC := Integer(NativeUInt(@TPSPCPU(nil).CurPC));
  OffV := Integer(NativeUInt(@TPSPCPU(nil).Ctx.V[0]));
  OffCOP0 := Integer(NativeUInt(@TPSPCPU(nil).COP0[0]));
  OffStopping := Integer(NativeUInt(@TPSPCPU(nil).Stopping));
  OffRemaining := Integer(NativeUInt(@TPSPCPU(nil).FRemaining));
  OffHit := Integer(NativeUInt(@TPSPRecompiler(nil).FHit));
  OffLastExit := Integer(NativeUInt(@TPSPRecompiler(nil).FLastExit));
  OffBlockPC := Integer(NativeUInt(@PPSPJitBlock(nil).PC));
  OffBlockCode := Integer(NativeUInt(@PPSPJitBlock(nil).Code));
  OffSlotPC := Integer(NativeUInt(@PPSPJitSlot(nil).PC));
  OffSlotBlock := Integer(NativeUInt(@PPSPJitSlot(nil).Block));
  KindsReady := True;
end;

function Classify(Op: Cardinal; out Handler: Pointer): TJitKind;
begin
  Handler := HandlerOf(Op);
  if Handler = @OpNop then
    Exit(jkNop);
  if Handler = @OpReserved then
    Exit(jkEnd);
  for var I := 0 to High(EndHandler) do
    if Handler = EndHandler[I] then
      Exit(jkEnd);
  for var K := Low(KindHandler) to High(KindHandler) do
    if Handler = KindHandler[K] then
      Exit(K);
  // COP1 and VFPU branches (BC1x, BVx): their handlers decide.
  if ((Op shr 26) in [$11, $12]) and (((Op shr 21) and 31) = 8) then
    Exit(jkHBranch);
  for var I := 0 to High(PureHandler) do
    if Handler = PureHandler[I] then
      Exit(jkPure);
  // Only the installed VFPU decoder: tests and other users may install
  // handlers of their own, which must remain calls.
  var Decoder: TPSPVFPUDecoder := PSPVFPUDecoder;
  if @Decoder = @PSP.VFPU.DecodeVFPU then
    case Op shr 26 of
      $32:
        Exit(jkLVS);
      $3A:
        Exit(jkSVS);
      $36:
        Exit(jkLVQ);
      $3E:
        Exit(jkSVQ);
      $12:
        if (Op and $80) = 0 then
          case (Op shr 21) and 31 of
            3:
              Exit(jkMFV);
            7:
              Exit(jkMTV);
          end;
    end;
  Result := jkHandler;
end;

function IsBranch(K: TJitKind): Boolean; inline;
begin
  Result := (K = jkHBranch) or (K >= jkJR);
end;

function IsLikely(K: TJitKind): Boolean; inline;
begin
  Result := K >= jkBEQL;
end;

// Whether a handler of this instruction may store (the code then checks
// whether a block was rewritten).
function MayStore(Op: Cardinal): Boolean;
begin
  Result := not ((Op shr 26) in [$00, $10, $11, $1C, $1F, $20..$27, $30, $31, $32, $35, $36]);
end;

{ Slow accesses (the page table has no page, or a store reaches code) }

function JitRead8(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read8(A);
end;

function JitRead16(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read16(A);
end;

function JitRead32(M: TPSPMemory; A: Cardinal): NativeUInt;
begin
  Result := M.Read32(A);
end;

function JitWrite8(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write8(A, V);
  Result := R.FHit;
end;

function JitWrite16(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write16(A, V);
  Result := R.FHit;
end;

function JitWrite32(R: TPSPRecompiler; A, V: Cardinal): NativeUInt;
begin
  R.FMemory.Write32(A, V);
  Result := R.FHit;
end;

{ Writing a block's code. Registers: Self the CPU, Ctx the recompiler, S0
  the memory's page table, S1 its code marks, S2 a jump's target (JR, JALR, a
  handler's branch) across its delay slot, S3 RAM's host buffer. }

function G(R: Cardinal): TJitOp; inline;
begin
  Result := JMem(jrSelf, OffGPR + Integer(R) * 4);
end;

function F(R: Cardinal): TJitOp; inline;
begin
  Result := JMem(jrSelf, OffFPR + Integer(R) * 4);
end;

function ScalarV(R: Cardinal): TJitOp;
begin
  Result := JMem(jrSelf, OffV + Integer(((R shr 2) and 7) * 16 + (R and 3) * 4 + ((R shr 5) and 3)) * 4);
end;

function QuadV(Op, Lane: Cardinal): TJitOp;
begin
  var Matrix := (Op shr 18) and 7;
  var A := (Op shr 16) and 3;
  var Index := Matrix * 16;
  if (Op and 1) = 0 then
    Inc(Index, A * 4 + Lane)
  else
    Inc(Index, Lane * 4 + A);
  Result := JMem(jrSelf, OffV + Integer(Index) * 4);
end;

function FieldRS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 21) and 31;
end;

function FieldRT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and 31;
end;

function FieldRD(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 11) and 31;
end;

function FieldSA(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 6) and 31;
end;

function FieldSImm(Op: Cardinal): Integer; inline;
begin
  Result := SmallInt(Word(Op));
end;

procedure TPSPRecompiler.WriteState(const At: TPSPJitAt);
begin
  // PC, NPC and CurPC as the interpreter has them while (and after) it runs
  // the instruction.
  if At.Dynamic then
  begin
    FJ.Move(jw32, JMem(jrSelf, OffPC), JTarget);
    FJ.Move(jw32, JT0, JTarget);
    FJ.Alu(jaAdd, jw32, JT0, JImm(4));
    FJ.Move(jw32, JMem(jrSelf, OffNPC), JT0);
  end
  else
  begin
    FJ.Move(jw32, JMem(jrSelf, OffPC), JImm(At.Next));
    FJ.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(At.Next + 4)));
  end;
  FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(At.Addr));
end;

function TPSPRecompiler.HitExit(const At: TPSPJitAt): TJitLabel;
begin
  var H: TPSPJitHitExit;
  H.L := FJ.NewLabel;
  H.At := At;
  FHitExits.Add(H);
  Result := H.L;
end;

procedure TPSPRecompiler.EmitCall(const At: TPSPJitAt; Op: Cardinal; Handler: Pointer; State: Boolean);
begin
  // The handler: as the interpreter runs it (State) or a handler of
  // registers and memory alone.
  if not State then
  begin
    // (A handler of registers and memory, CurPC as every handler sees it:
    // where it stored into a block.)
    FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(At.Addr));
    FJ.Call(Handler, [JSelf, JImm(Op)]);
    if MayStore(Op) then
      FJ.BranchTest(jcNe, jw8, JMem(jrCtx, OffHit), JImm($FF), HitExit(At));
    Exit;
  end;
  // The budget as the interpreter has it while it runs (the block's later
  // instructions not taken yet).
  WriteState(At);
  var Rest := At.Refund;
  var Remaining := JMem(jrSelf, OffRemaining);
  if Rest <> 0 then
    FJ.Alu(jaAdd, jw32, Remaining, JImm(Rest));
  FJ.Call(Handler, [JSelf, JImm(Op)]);
  // Where it stopped the run, used up the cycles left, rewrote a block or
  // moved PC or NPC as a kernel call would: back to Run, from where the
  // handler left them.
  FJ.BranchTo(jcNe, jw8, JMem(jrSelf, OffStopping), JImm(0), FExit);
  if At.Dynamic then
  begin
    FJ.BranchTo(jcNe, jw32, JMem(jrSelf, OffPC), JTarget, FExit);
    FJ.Move(jw32, JT0, JTarget);
    FJ.Alu(jaAdd, jw32, JT0, JImm(4));
    FJ.BranchTo(jcNe, jw32, JMem(jrSelf, OffNPC), JT0, FExit);
  end
  else
  begin
    FJ.BranchTo(jcNe, jw32, JMem(jrSelf, OffPC), JImm(At.Next), FExit);
    FJ.BranchTo(jcNe, jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(At.Next + 4)), FExit);
  end;
  FJ.BranchTo(jcLt, jw32, Remaining, JImm(Rest), FExit);
  if MayStore(Op) then
    FJ.BranchTo(jcNe, jw8, JMem(jrCtx, OffHit), JImm(0), FExit);
  if Rest <> 0 then
    FJ.Alu(jaSub, jw32, Remaining, JImm(Rest));
end;

procedure TPSPRecompiler.EmitHost(Kind: Integer; Store: Boolean; const Reg: TJitOp);
begin
  // The access at host address T1: a load into T0, a store of Reg (through
  // T2). Halfwords as two bytes.
  var J := FJ;
  if Store then
  begin
    J.Move(jw32, JT2, Reg);
    case TJitKind(Kind) of
      jkSB:
        J.Move(jw8, JMem(jrT1, 0), JT2);
      jkSH:
        begin
          J.Move(jw8, JMem(jrT1, 0), JT2);
          J.Shift(jsShr, jw32, jrT2, 8);
          J.Move(jw8, JMem(jrT1, 1), JT2);
        end;
    else
      J.Move(jw32, JMem(jrT1, 0), JT2);
    end;
  end
  else
    case TJitKind(Kind) of
      jkLB, jkLBU:
        J.Move(jw8, JT0, JMem(jrT1, 0));
      jkLH, jkLHU:
        begin
          J.Move(jw8, JT0, JMem(jrT1, 0));
          J.Move(jw8, JT2, JMem(jrT1, 1));
          J.Shift(jsShl, jw32, jrT2, 8);
          J.Alu(jaOr, jw32, JT0, JT2);
        end;
    else
      J.Move(jw32, JT0, JMem(jrT1, 0));
    end;
end;

procedure TPSPRecompiler.EmitTable(const S: TPSPJitSlow);
begin
  // The address in T0 through the page table into T1 (no page: the slow
  // way), then the access.
  var J := FJ;
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, PSPPageShift - PtrShift);
  J.Alu(jaAdd, jw64, JT1, JPages);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, S.Slow);
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask));
  J.Alu(jaAdd, jw64, JT1, JT2);
  EmitHost(S.Kind, S.Store, S.Reg);
end;

procedure TPSPRecompiler.EmitAccess(var S: TPSPJitSlow; Op: Cardinal);
begin
  // T0 the address; RAM (one host buffer, as TPSPMemory maps it) here, the
  // rest through the page table out of line (a store: where its page holds
  // no code; else the slow way, TPSPMemory's).
  var J := FJ;
  S.Slow := J.NewLabel;
  S.Back := J.NewLabel;
  S.Table := -1;
  J.Move(jw32, JT0, G(FieldRS(Op)));
  if FieldSImm(Op) <> 0 then
    J.Alu(jaAdd, jw32, JT0, JImm(FieldSImm(Op)));
  if S.Store then
  begin
    J.Move(jw32, JT2, JT0);
    J.Alu(jaAnd, jw32, JT2, JImm($1FFFF000));
    J.Shift(jsShr, jw32, jrT2, PSPPageShift);
    J.Alu(jaAdd, jw64, JT2, JMarks);
    J.Move(jw8, JT2, JMem(jrT2, 0));
    J.BranchTest(jcNe, jw32, JT2, JT2, S.Slow);
  end;
  if FRamDirect then
  begin
    S.Table := J.NewLabel;
    J.Move(jw32, JT1, JT0);
    J.Alu(jaAnd, jw32, JT1, JImm($1FFFFFFF));
    J.Alu(jaSub, jw32, JT1, JImm(PSPRAMBase));
    J.Branch(jcAboveEq, jw32, JT1, JImm(PSPRAMSize), S.Table);
    J.Alu(jaAdd, jw64, JT1, JRAM);
    EmitHost(S.Kind, S.Store, S.Reg);
  end
  else
    EmitTable(S);
  J.Bind(S.Back);
end;

procedure TPSPRecompiler.EmitQuad(const At: TPSPJitAt; Op: Cardinal; Store: Boolean; Handler: Pointer);
begin
  // One page lookup for all four lanes; crossing a page or writing code
  // calls the whole handler, so even a self-rewriting SV.Q finishes its
  // four stores before any next instruction runs.
  var J := FJ;
  var Slow := J.NewLabel;
  var Mapped := J.NewLabel;
  var Host := J.NewLabel;
  var Done := J.NewLabel;
  J.Move(jw32, JT0, G(FieldRS(Op)));
  var Offset := FieldSImm(Op and not Cardinal(3));
  if Offset <> 0 then
    J.Alu(jaAdd, jw32, JT0, JImm(Offset));
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask));
  J.Branch(jcAbove, jw32, JT2, JImm(PSPPageSize - 16), Slow);
  if Store then
  begin
    J.Move(jw32, JT1, JT0);
    J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
    J.Shift(jsShr, jw32, jrT1, PSPPageShift);
    J.Alu(jaAdd, jw64, JT1, JMarks);
    J.Move(jw8, JT1, JMem(jrT1, 0));
    J.BranchTest(jcNe, jw32, JT1, JT1, Slow);
  end;
  if FRamDirect then
  begin
    J.Move(jw32, JT1, JT0);
    J.Alu(jaAnd, jw32, JT1, JImm($1FFFFFFF));
    J.Alu(jaSub, jw32, JT1, JImm(PSPRAMBase));
    J.Branch(jcAboveEq, jw32, JT1, JImm(PSPRAMSize), Mapped);
    J.Alu(jaAdd, jw64, JT1, JRAM);
    J.Jump(Host);
  end;
  J.Bind(Mapped);
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, PSPPageShift - PtrShift);
  J.Alu(jaAdd, jw64, JT1, JPages);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Slow);
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Bind(Host);
  for var I := 0 to 3 do
    if Store then
    begin
      J.Move(jw32, JT0, QuadV(Op, I));
      J.Move(jw32, JMem(jrT1, I * 4), JT0);
    end
    else
    begin
      J.Move(jw32, JT0, JMem(jrT1, I * 4));
      J.Move(jw32, QuadV(Op, I), JT0);
    end;
  J.Jump(Done);
  J.Bind(Slow);
  EmitCall(At, Op, Handler, False);
  J.Bind(Done);
end;

procedure TPSPRecompiler.EmitLoad(Op: Cardinal; Kind: Integer; const Reg: TJitOp);
begin
  // As TPSPMemory.ReadN: the page's host memory at the address's offset
  // (aligned or not), else the routine (no page).
  var J := FJ;
  var K := TJitKind(Kind);
  var S: TPSPJitSlow;
  S.Store := False;
  S.Kind := Kind;
  S.Reg := Reg;
  S.Hit := -1;
  case K of
    jkLB, jkLBU:
      S.Routine := @JitRead8;
    jkLH, jkLHU:
      S.Routine := @JitRead16;
  else
    S.Routine := @JitRead32;
  end;
  EmitAccess(S, Op);
  case K of
    jkLB:
      J.SignExtend(jw8, jrT0);
    jkLH:
      begin
        J.Shift(jsShl, jw32, jrT0, 16);
        J.Shift(jsSar, jw32, jrT0, 16);
      end;
  end;
  J.Move(jw32, Reg, JT0);
  FSlow.Add(S);
end;

procedure TPSPRecompiler.EmitStore(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; const Reg: TJitOp);
begin
  // As TPSPMemory.WriteN where the page is not code: its host memory; else
  // the routine (which re-decodes, and the block may have to stop).
  var K := TJitKind(Kind);
  var S: TPSPJitSlow;
  S.Store := True;
  S.Kind := Kind;
  S.Reg := Reg;
  S.Hit := HitExit(At);
  case K of
    jkSB:
      S.Routine := @JitWrite8;
    jkSH:
      S.Routine := @JitWrite16;
  else
    S.Routine := @JitWrite32;
  end;
  EmitAccess(S, Op);
  FSlow.Add(S);
end;

function TPSPRecompiler.EmitInstr(const At: TPSPJitAt; Op: Cardinal; Kind: Integer; Handler: Pointer): Boolean;
var
  J: TJitAsm;

  // GPR[D] := GPR[S] op GPR[T].
  procedure Three(A: TJitAlu);
  begin
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Alu(A, jw32, JT0, G(FieldRT(Op)));
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  // GPR[T] := GPR[S] op a constant.
  procedure WithImm(A: TJitAlu; Value: Int64);
  begin
    if FieldRS(Op) = FieldRT(Op) then
      J.Alu(A, jw32, G(FieldRT(Op)), JImm(Value))
    else
    begin
      J.Move(jw32, JT0, G(FieldRS(Op)));
      J.Alu(A, jw32, JT0, JImm(Value));
      J.Move(jw32, G(FieldRT(Op)), JT0);
    end;
  end;

  // R := Ord(GPR[S] Cond B).
  procedure SetIf(Cond: TJitCond; const B: TJitOp; R: Cardinal);
  begin
    var L := J.NewLabel;
    J.Move(jw32, JT1, G(FieldRS(Op)));
    J.Move(jw32, JT0, JImm(1));
    J.Branch(Cond, jw32, JT1, B, L);
    J.Move(jw32, JT0, JImm(0));
    J.Bind(L);
    J.Move(jw32, G(R), JT0);
  end;

  // GPR[D] := GPR[T] shifted.
  procedure ShiftBy(S: TJitShift);
  begin
    J.Move(jw32, JT0, G(FieldRT(Op)));
    if FieldSA(Op) <> 0 then
      J.Shift(S, jw32, jrT0, FieldSA(Op));
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  // GPR[D] := GPR[S] where GPR[T] meets Cond with 0.
  procedure MoveIf(Skip: TJitCond);
  begin
    var L := J.NewLabel;
    J.Branch(Skip, jw32, G(FieldRT(Op)), JImm(0), L);
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Move(jw32, G(FieldRD(Op)), JT0);
    J.Bind(L);
  end;

  // GPR[D] := the larger (Keep jcGt) or smaller (jcLt) of GPR[S], GPR[T].
  procedure Pick(Keep: TJitCond);
  begin
    var L := J.NewLabel;
    J.Move(jw32, JT0, G(FieldRS(Op)));
    J.Branch(Keep, jw32, JT0, G(FieldRT(Op)), L);
    J.Move(jw32, JT0, G(FieldRT(Op)));
    J.Bind(L);
    J.Move(jw32, G(FieldRD(Op)), JT0);
  end;

  procedure Copy(const Dst, Src: TJitOp);
  begin
    J.Move(jw32, JT0, Src);
    J.Move(jw32, Dst, JT0);
  end;

begin
  // One instruction (not a branch) as its handler does it; True: it ended
  // the block (its handler calls the kernel or raises), the code leaves.
  J := FJ;
  Result := False;
  case TJitKind(Kind) of
    jkNop:
      ;
    jkEnd:
      begin
        WriteState(At);
        J.Call(Handler, [JSelf, JImm(Op)]);
        J.JumpTo(FExit);
        Result := True;
      end;
    jkHandler:
      EmitCall(At, Op, Handler, True);
    jkPure:
      EmitCall(At, Op, Handler, False);
    jkSLL:
      ShiftBy(jsShl);
    jkSRL:
      ShiftBy(jsShr);
    jkSRA:
      ShiftBy(jsSar);
    jkROTR:
      begin
        var S := FieldSA(Op);
        if S = 0 then
          Copy(G(FieldRD(Op)), G(FieldRT(Op)))
        else
        begin
          J.Move(jw32, JT0, G(FieldRT(Op)));
          J.Move(jw32, JT1, JT0);
          J.Shift(jsShr, jw32, jrT0, S);
          J.Shift(jsShl, jw32, jrT1, 32 - S);
          J.Alu(jaOr, jw32, JT0, JT1);
          J.Move(jw32, G(FieldRD(Op)), JT0);
        end;
      end;
    jkMOVZ:
      MoveIf(jcNe);
    jkMOVN:
      MoveIf(jcEq);
    jkMFHI:
      Copy(G(FieldRD(Op)), JMem(jrSelf, OffHI));
    jkMTHI:
      Copy(JMem(jrSelf, OffHI), G(FieldRS(Op)));
    jkMFLO:
      Copy(G(FieldRD(Op)), JMem(jrSelf, OffLO));
    jkMTLO:
      Copy(JMem(jrSelf, OffLO), G(FieldRS(Op)));
    jkMFV:
      if FieldRT(Op) <> 0 then
        Copy(G(FieldRT(Op)), ScalarV(Op and $7F));
    jkMTV:
      Copy(ScalarV(Op and $7F), G(FieldRT(Op)));
    jkLVS:
      EmitLoad(Op and not Cardinal(3), Ord(jkLW), ScalarV(FieldRT(Op) or ((Op and 3) shl 5)));
    jkSVS:
      EmitStore(At, Op and not Cardinal(3), Ord(jkSW), ScalarV(FieldRT(Op) or ((Op and 3) shl 5)));
    jkLVQ:
      EmitQuad(At, Op, False, Handler);
    jkSVQ:
      EmitQuad(At, Op, True, Handler);
    jkADDU:
      Three(jaAdd);
    jkSUBU:
      Three(jaSub);
    jkAND:
      Three(jaAnd);
    jkOR:
      Three(jaOr);
    jkXOR:
      Three(jaXor);
    jkNOR:
      begin
        J.Move(jw32, JT0, G(FieldRS(Op)));
        J.Alu(jaOr, jw32, JT0, G(FieldRT(Op)));
        J.Alu(jaXor, jw32, JT0, JImm(-1));
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSLT:
      SetIf(jcLt, G(FieldRT(Op)), FieldRD(Op));
    jkSLTU:
      SetIf(jcBelow, G(FieldRT(Op)), FieldRD(Op));
    jkMAX:
      Pick(jcGt);
    jkMIN:
      Pick(jcLt);
    jkADDIU:
      WithImm(jaAdd, FieldSImm(Op));
    jkSLTI:
      SetIf(jcLt, JImm(FieldSImm(Op)), FieldRT(Op));
    jkSLTIU:
      SetIf(jcBelow, JImm(FieldSImm(Op)), FieldRT(Op));
    jkANDI:
      WithImm(jaAnd, Op and $FFFF);
    jkORI:
      WithImm(jaOr, Op and $FFFF);
    jkXORI:
      WithImm(jaXor, Op and $FFFF);
    jkLUI:
      J.Move(jw32, G(FieldRT(Op)), JImm(Cardinal(Op shl 16)));
    jkMFC0:
      Copy(G(FieldRT(Op)), JMem(jrSelf, OffCOP0 + Integer(FieldRD(Op)) * 4));
    jkEXT:
      begin
        var Pos := FieldSA(Op);
        var Size := FieldRD(Op) + 1;
        J.Move(jw32, JT0, G(FieldRS(Op)));
        if Pos <> 0 then
          J.Shift(jsShr, jw32, jrT0, Pos);
        if Size < 32 then
          J.Alu(jaAnd, jw32, JT0, JImm((Cardinal(1) shl Size) - 1));
        J.Move(jw32, G(FieldRT(Op)), JT0);
      end;
    jkINS:
      begin
        var Lsb := FieldSA(Op);
        var Msb := FieldRD(Op);
        if Msb >= Lsb then
        begin
          var Size := Msb - Lsb + 1;
          var Mask: Cardinal;
          if Size >= 32 then
            Mask := $FFFFFFFF
          else
            Mask := ((Cardinal(1) shl Size) - 1) shl Lsb;
          J.Move(jw32, JT0, G(FieldRS(Op)));
          if Lsb <> 0 then
            J.Shift(jsShl, jw32, jrT0, Lsb);
          J.Alu(jaAnd, jw32, JT0, JImm(Mask));
          J.Move(jw32, JT1, G(FieldRT(Op)));
          J.Alu(jaAnd, jw32, JT1, JImm(not Mask));
          J.Alu(jaOr, jw32, JT0, JT1);
          J.Move(jw32, G(FieldRT(Op)), JT0);
        end;
      end;
    jkWSBH:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.Move(jw32, JT1, JT0);
        J.Alu(jaAnd, jw32, JT0, JImm($00FF00FF));
        J.Shift(jsShl, jw32, jrT0, 8);
        J.Alu(jaAnd, jw32, JT1, JImm($FF00FF00));
        J.Shift(jsShr, jw32, jrT1, 8);
        J.Alu(jaOr, jw32, JT0, JT1);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkWSBW:
      begin
        J.Move(jw32, JT1, G(FieldRT(Op)));
        J.Move(jw32, JT0, JT1);
        J.Shift(jsShl, jw32, jrT0, 24);
        J.Move(jw32, JT2, JT1);
        J.Alu(jaAnd, jw32, JT2, JImm($FF00));
        J.Shift(jsShl, jw32, jrT2, 8);
        J.Alu(jaOr, jw32, JT0, JT2);
        J.Move(jw32, JT2, JT1);
        J.Shift(jsShr, jw32, jrT2, 8);
        J.Alu(jaAnd, jw32, JT2, JImm($FF00));
        J.Alu(jaOr, jw32, JT0, JT2);
        J.Shift(jsShr, jw32, jrT1, 24);
        J.Alu(jaOr, jw32, JT0, JT1);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSEB:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.SignExtend(jw8, jrT0);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkSEH:
      begin
        J.Move(jw32, JT0, G(FieldRT(Op)));
        J.Shift(jsShl, jw32, jrT0, 16);
        J.Shift(jsSar, jw32, jrT0, 16);
        J.Move(jw32, G(FieldRD(Op)), JT0);
      end;
    jkLB, jkLH, jkLW, jkLBU, jkLHU:
      EmitLoad(Op, Kind, G(FieldRT(Op)));
    jkSB, jkSH, jkSW:
      EmitStore(At, Op, Kind, G(FieldRT(Op)));
    jkLWC1:
      EmitLoad(Op, Ord(jkLW), F(FieldRT(Op)));
    jkSWC1:
      EmitStore(At, Op, Ord(jkSW), F(FieldRT(Op)));
    jkMFC1:
      Copy(G(FieldRT(Op)), F(FieldRD(Op)));
    jkMTC1:
      Copy(F(FieldRD(Op)), G(FieldRT(Op)));
  else
    raise EInvalidOpException.Create('PSP JIT: a branch as an instruction');
  end;
end;

procedure TPSPRecompiler.EmitStatic(Target, Last: Cardinal; Refund: Integer);
begin
  // The block's end towards Target (Last the instruction that ran last): a
  // jump that goes to its stub until linked.
  if Refund <> 0 then
    FJ.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(Refund));
  FJ.Move(jw32, JMem(jrSelf, OffCurPC), JImm(Last));
  var E: PPSPJitExit;
  New(E);
  E.Block := FBlock;
  E.Target := Target;
  E.Site := FJ.JumpSite(FExit);
  E.Stub := -1;
  E.Linked := nil;
  FStatic.Add(E);
  FAllExits.Add(E);
  FBlock.Exits := FBlock.Exits + [E];
end;

procedure TPSPRecompiler.EmitDelay(A: Cardinal; Op: Cardinal; Kind: Integer; Handler: Pointer; Dynamic: Boolean;
  Next: Cardinal);
begin
  // A branch's delay slot at A, then the block's end towards Next (or the
  // Target register).
  var At: TPSPJitAt;
  At.Addr := A;
  At.Next := Next;
  At.Dynamic := Dynamic;
  At.Refund := 0;
  if EmitInstr(At, Op, Kind, Handler) then
    Exit;
  if Dynamic then
  begin
    // The block it went to last time (its slot), else the look-up.
    var J := FJ;
    J.Move(jw32, JMem(jrSelf, OffCurPC), JImm(A));
    var Slot: PPSPJitSlot;
    New(Slot);
    Slot.PC := 0;
    Slot.Block := @FNoBlock;
    FSlots.Add(Slot);
    var Miss := J.NewLabel;
    J.Move(jw64, JT6, JImm(Int64(NativeUInt(Slot))));
    J.Branch(jcNe, jw32, JMem(jrT6, OffSlotPC), JTarget, Miss);
    J.Move(JPtr, JT1, JMem(jrT6, OffSlotBlock));
    J.Move(JPtr, JT1, JMem(jrT1, OffBlockCode));
    J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
    J.JumpIndirect(JT1);
    J.Bind(Miss);
    J.JumpTo(FLookup);
  end
  else
    EmitStatic(Next, A, 0);
end;

{ Blocks: made, linked, dropped, run. }

procedure TPSPRecompiler.EmitShared;
begin
  // The entry (Invoke'd with the CPU, the recompiler, the prologue and the
  // block's code), the prologue (the tables' registers), the way back to
  // Run, and the look-up of a jump's target (in S2) among the blocks.
  var J := FJ;
  J.ForgetLabels;
  J.Align(16);
  FEnter := J.Offset;
  J.EnterJump;
  J.Align(16);
  FPrologue := J.Offset;
  J.Move(jw64, JPages, JImm(Int64(NativeUInt(FMemory.PageTable))));
  J.Move(jw64, JMarks, JImm(Int64(NativeUInt(FMemory.CodeMarks))));
  J.Move(jw64, JRAM, JImm(Int64(NativeUInt(@FMemory.RAM[0]))));
  J.JumpIndirect(JT1);
  J.Align(16);
  FExit := J.Offset;
  J.Leave(JImm(0));
  J.Align(16);
  FLookup := J.Offset;
  var Miss := J.NewLabel;
  J.Move(jw32, JT0, JTarget);
  J.BranchTest(jcNe, jw32, JT0, JImm(3), Miss);
  J.Move(jw32, JT1, JT0);
  J.Alu(jaAnd, jw32, JT1, JImm($1FFFF000));
  J.Shift(jsShr, jw32, jrT1, PSPPageShift - PtrShift);
  J.Move(jw64, JT2, JImm(Int64(NativeUInt(@FPages[0]))));
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
  J.Move(jw32, JT2, JT0);
  J.Alu(jaAnd, jw32, JT2, JImm(PSPPageMask and not 3));
  if PtrShift > 2 then
    J.Shift(jsShl, jw32, jrT2, PtrShift - 2);
  J.Alu(jaAdd, jw64, JT1, JT2);
  J.Move(JPtr, JT1, JMem(jrT1, 0));
  J.BranchTest(jcEq, JPtr, JT1, JT1, Miss);
  J.Branch(jcNe, jw32, JMem(jrT1, OffBlockPC), JT0, Miss);
  J.Move(JPtr, JT2, JMem(jrT1, OffBlockCode));
  J.BranchTest(jcEq, JPtr, JT2, JT2, Miss);
  // (The jump's own slot, T6, keeps the block for its next time.)
  J.Move(jw32, JMem(jrT6, OffSlotPC), JT0);
  J.Move(JPtr, JMem(jrT6, OffSlotBlock), JT1);
  J.JumpIndirect(JT2);
  J.Bind(Miss);
  J.Move(jw32, JMem(jrSelf, OffPC), JTarget);
  J.Move(jw32, JT0, JTarget);
  J.Alu(jaAdd, jw32, JT0, JImm(4));
  J.Move(jw32, JMem(jrSelf, OffNPC), JT0);
  J.JumpTo(FExit);
  J.ForgetLabels;
  J.Flush;
end;

function TPSPRecompiler.PageOf(PC: Cardinal): PPSPJitPage;
begin
  var Index := (PC and $1FFFFFFF) shr PSPPageShift;
  Result := FPages[Index];
  if Result = nil then
  begin
    New(Result);
    FillChar(Result^, SizeOf(TPSPJitPage), 0);
    Result.Blocks := TList<PPSPJitBlock>.Create;
    FPages[Index] := Result;
  end;
end;

function TPSPRecompiler.Scan(PC: Cardinal): Integer;
begin
  // A block's instructions from PC: up to a branch and its delay slot (not
  // where the slot is on the next page or is a branch too: the block ends
  // before the branch), an instruction that ends one, the page's end.
  var Words := Integer((PSPPageSize - (PC and PSPPageMask)) div 4);
  // (Nor a word rewritten often: the interpreter runs it.)
  var P := FPages[(PC and $1FFFFFFF) shr PSPPageShift];
  if P <> nil then
  begin
    var First := Integer((PC and PSPPageMask) shr 2);
    for var W := 0 to Min(Words, PSPJitMaxBlock) - 1 do
      if P.Changes[First + W] >= MaxChanges then
      begin
        Words := W;
        Break;
      end;
  end;
  var H: Pointer;
  Result := 0;
  while (Result < Words) and (Result < PSPJitMaxBlock) do
  begin
    var K := Classify(FCPU.Decoded(PC + Cardinal(Result) * 4).Op, H);
    if IsBranch(K) then
    begin
      if (Result + 1 >= Words) or (Result + 2 > PSPJitMaxBlock) then
        Exit;
      if IsBranch(Classify(FCPU.Decoded(PC + Cardinal(Result + 1) * 4).Op, H)) then
        Exit;
      Exit(Result + 2);
    end;
    Inc(Result);
    if K = jkEnd then
      Exit;
  end;
end;

function TPSPRecompiler.Lookup(PC: Cardinal): PPSPJitBlock;
begin
  // The block at PC, made (cold) if there is none.
  var P := FPages[(PC and $1FFFFFFF) shr PSPPageShift];
  var Index := (PC and PSPPageMask) shr 2;
  if P <> nil then
  begin
    Result := P.Entries[Index];
    if (Result <> nil) and (Result.PC = PC) then
      Exit;
    if Result <> nil then
      Kill(Result);
  end;
  var Count := Scan(PC);
  P := PageOf(PC);
  New(Result);
  FillChar(Result^, SizeOf(TPSPJitBlock), 0);
  Result.PC := PC;
  Result.Physical := PC and $1FFFFFFF;
  Result.Count := Count;
  if Count = 0 then
    Result.State := bsNone
  else
    Result.State := bsCold;
  P.Entries[Index] := Result;
  P.Blocks.Add(Result);
  FAll.Add(Result);
end;

procedure TPSPRecompiler.Cover(Page: PPSPJitPage; B: PPSPJitBlock);
begin
  var First := Integer((B.Physical and PSPPageMask) shr 2);
  for var W := First to First + B.Count - 1 do
    Page.Covered[W shr 5] := Page.Covered[W shr 5] or (Cardinal(1) shl (W and 31));
end;

procedure TPSPRecompiler.Recover(Page: PPSPJitPage);
begin
  FillChar(Page.Covered, SizeOf(Page.Covered), 0);
  for var B in Page.Blocks do
    if B.State = bsCompiled then
      Cover(Page, B);
end;

procedure TPSPRecompiler.Link(E: PPSPJitExit; B: PPSPJitBlock);
begin
  FJ.Redirect(E.Site, NativeInt(NativeUInt(B.Code) - NativeUInt(FJ.Base)));
  E.Linked := B;
  if B.Incoming = nil then
    B.Incoming := TList<PPSPJitExit>.Create;
  B.Incoming.Add(E);
  Inc(FLinks);
end;

procedure TPSPRecompiler.Kill(B: PPSPJitBlock);
begin
  // B no longer runs: no jumps into it, no look-up finds it.
  if B.State = bsDead then
    Exit;
  if B.State = bsCompiled then
  begin
    if B.Incoming <> nil then
    begin
      for var E in B.Incoming do
        if E.Linked = B then
        begin
          FJ.Redirect(E.Site, E.Stub);
          E.Linked := nil;
        end;
      B.Incoming.Clear;
    end;
    for var E in B.Exits do
      if E.Linked <> nil then
      begin
        if E.Linked.Incoming <> nil then
          E.Linked.Incoming.Remove(E);
        E.Linked := nil;
      end;
    FHit := 1;
    Inc(FKills);
  end;
  var P := FPages[B.Physical shr PSPPageShift];
  var Index := (B.Physical and PSPPageMask) shr 2;
  if P.Entries[Index] = B then
    P.Entries[Index] := nil;
  P.Blocks.Remove(B);
  B.State := bsDead;
  B.Code := nil;
  Inc(FDead);
end;

procedure TPSPRecompiler.KillAll;
begin
  for var P in FPages do
    if P <> nil then
    begin
      for var I := P.Blocks.Count - 1 downto 0 do
        Kill(P.Blocks[I]);
      FillChar(P.Covered, SizeOf(P.Covered), 0);
    end;
end;

procedure TPSPRecompiler.ResetCode;
begin
  // All blocks and their code dropped (never while code runs).
  for var B in FAll do
  begin
    B.Incoming.Free;
    Dispose(B);
  end;
  FAll.Clear;
  for var E in FAllExits do
    Dispose(E);
  FAllExits.Clear;
  for var S in FSlots do
    Dispose(S);
  FSlots.Clear;
  for var I := 0 to High(FPages) do
    if FPages[I] <> nil then
    begin
      FPages[I].Blocks.Free;
      Dispose(FPages[I]);
      FPages[I] := nil;
    end;
  FResetPending := False;
  FDead := 0;
  if FJ <> nil then
  begin
    FJ.Reset;
    EmitShared;
    Inc(FResets);
  end;
end;

procedure TPSPRecompiler.CodeWritten(Address, Size: Cardinal);
begin
  // Blocks with a word in the range are dropped (FHit: the code running
  // stops after its store).
  if Size = 0 then
    Exit;
  var First := Address and $1FFFFFFF and not Cardinal(3);
  var Last := UInt64(Address and $1FFFFFFF) + Size - 1;
  if Last > $1FFFFFFF then
    Last := $1FFFFFFF;
  for var Page := First shr PSPPageShift to Cardinal(Last shr PSPPageShift) do
  begin
    var P := FPages[Page];
    if (P = nil) or (P.Blocks.Count = 0) then
      Continue;
    var Lo := 0;
    if Page = First shr PSPPageShift then
      Lo := Integer((First and PSPPageMask) shr 2);
    var Hi := PSPPageSize div 4 - 1;
    if Page = Cardinal(Last shr PSPPageShift) then
      Hi := Integer((Cardinal(Last) and PSPPageMask) shr 2);
    // The words blocks were made from that now hold another instruction.
    var Words := PCardinal(FMemory.PageBase(Page shl PSPPageShift));
    var CLo := MaxInt;
    var CHi := -1;
    for var W := Lo to Hi do
      if ((P.Covered[W shr 5] and (Cardinal(1) shl (W and 31))) <> 0) and ((Words = nil) or (Words[W] <> P.Ops[W])) then
      begin
        if CLo > W then
          CLo := W;
        CHi := W;
        if P.Changes[W] < 255 then
          Inc(P.Changes[W]);
      end;
    if CHi < 0 then
      Continue;
    for var I := P.Blocks.Count - 1 downto 0 do
    begin
      var B := P.Blocks[I];
      var BFirst := Integer((B.Physical and PSPPageMask) shr 2);
      if (B.State = bsCompiled) and (BFirst <= CHi) and (BFirst + B.Count - 1 >= CLo) then
        Kill(B);
    end;
    Recover(P);
  end;
end;

procedure TPSPRecompiler.Flushed;
begin
  if FInCode or FInRun then
  begin
    KillAll;
    FResetPending := True;
  end
  else
    ResetCode;
end;

procedure TPSPRecompiler.Compile(B: PPSPJitBlock);
var
  Ops: array[0..PSPJitMaxBlock - 1] of Cardinal;
  Kinds: array[0..PSPJitMaxBlock - 1] of TJitKind;
  Handlers: array[0..PSPJitMaxBlock - 1] of Pointer;
  J: TJitAsm;

  procedure Cond(K: TJitKind; Op, A: Cardinal; Taken: TJitLabel);
  begin
    // To Taken where the branch is taken (its registers as before its slot).
    var S := G(FieldRS(Op));
    case K of
      jkBEQ, jkBEQL, jkBNE, jkBNEL:
        begin
          J.Move(jw32, JT0, S);
          if K in [jkBEQ, jkBEQL] then
            J.Branch(jcEq, jw32, JT0, G(FieldRT(Op)), Taken)
          else
            J.Branch(jcNe, jw32, JT0, G(FieldRT(Op)), Taken);
        end;
      jkBLEZ, jkBLEZL:
        J.Branch(jcLe, jw32, S, JImm(0), Taken);
      jkBGTZ, jkBGTZL:
        J.Branch(jcGt, jw32, S, JImm(0), Taken);
      jkBLTZ, jkBLTZL:
        J.Branch(jcLt, jw32, S, JImm(0), Taken);
      jkBGEZ, jkBGEZL:
        J.Branch(jcGe, jw32, S, JImm(0), Taken);
      jkBLTZAL, jkBLTZALL, jkBGEZAL, jkBGEZALL:
        begin
          J.Move(jw32, JT0, S);
          J.Move(jw32, G(31), JImm(Cardinal(A + 8)));
          if K in [jkBLTZAL, jkBLTZALL] then
            J.Branch(jcLt, jw32, JT0, JImm(0), Taken)
          else
            J.Branch(jcGe, jw32, JT0, JImm(0), Taken);
        end;
    end;
  end;

  procedure EmitBranch(I: Integer; A: Cardinal);
  begin
    // The branch at A (step I), its slot (step I + 1) on each way.
    var Op := Ops[I];
    var K := Kinds[I];
    var DOp := Ops[I + 1];
    var DK := Ord(Kinds[I + 1]);
    var DH := Handlers[I + 1];
    var Slot := A + 4;
    var Taken := Cardinal(A + 4 + Cardinal(FieldSImm(Op) * 4));
    var Fall := Cardinal(A + 8);
    case K of
      jkJ, jkJAL:
        begin
          Taken := ((A + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
          if K = jkJAL then
            J.Move(jw32, G(31), JImm(Fall));
          EmitDelay(Slot, DOp, DK, DH, False, Taken);
        end;
      jkB:
        EmitDelay(Slot, DOp, DK, DH, False, Taken);
      jkJR, jkJALR:
        begin
          // (The target's low two bits ignored.)
          J.Move(jw32, JTarget, G(FieldRS(Op)));
          J.Alu(jaAnd, jw32, JTarget, JImm(-4));
          if (K = jkJALR) and (FieldRD(Op) <> 0) then
            J.Move(jw32, G(FieldRD(Op)), JImm(Fall));
          EmitDelay(Slot, DOp, DK, DH, True, 0);
        end;
      jkHBranch:
        begin
          // Its handler as the interpreter runs it; then where it left PC
          // and NPC: PC moved on (a likely branch not taken), or the slot
          // and NPC the next PC.
          var At: TPSPJitAt;
          At.Addr := A;
          At.Next := Slot;
          At.Dynamic := False;
          At.Refund := 1;
          WriteState(At);
          J.Call(Handlers[I], [JSelf, JImm(Op)]);
          var Nullified := J.NewLabel;
          J.Branch(jcNe, jw32, JMem(jrSelf, OffPC), JImm(Slot), Nullified);
          J.Move(jw32, JTarget, JMem(jrSelf, OffNPC));
          var Other := J.NewLabel;
          J.Branch(jcNe, jw32, JTarget, JImm(Taken), Other);
          EmitDelay(Slot, DOp, DK, DH, False, Taken);
          J.Bind(Other);
          EmitDelay(Slot, DOp, DK, DH, True, 0);
          J.Bind(Nullified);
          J.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(1));
          J.JumpTo(FExit);
        end;
    else
      begin
        var L := J.NewLabel;
        Cond(K, Op, A, L);
        if IsLikely(K) then
          EmitStatic(Fall, A, 1)
        else
          EmitDelay(Slot, DOp, DK, DH, False, Fall);
        J.Bind(L);
        EmitDelay(Slot, DOp, DK, DH, False, Taken);
      end;
    end;
  end;

begin
  // B's code (the room for it there).
  var Count := Scan(B.PC);
  B.Count := Count;
  if Count = 0 then
  begin
    B.State := bsNone;
    Exit;
  end;
  for var I := 0 to Count - 1 do
  begin
    Ops[I] := FCPU.Decoded(B.PC + Cardinal(I) * 4).Op;
    Kinds[I] := Classify(Ops[I], Handlers[I]);
  end;
  J := FJ;
  FBlock := B;
  FSlow.Clear;
  FHitExits.Clear;
  FStatic.Clear;
  J.ForgetLabels;
  J.Align(16);
  var Code := J.Here;
  var NoBudget := J.NewLabel;
  J.Branch(jcLt, jw32, JMem(jrSelf, OffRemaining), JImm(Count), NoBudget);
  J.Alu(jaSub, jw32, JMem(jrSelf, OffRemaining), JImm(Count));
  var Branchy := (Count >= 2) and IsBranch(Kinds[Count - 2]);
  var Body := Count;
  if Branchy then
    Body := Count - 2;
  var Ended := False;
  for var I := 0 to Body - 1 do
  begin
    var At: TPSPJitAt;
    At.Addr := B.PC + Cardinal(I) * 4;
    At.Next := At.Addr + 4;
    At.Dynamic := False;
    At.Refund := Count - I - 1;
    if EmitInstr(At, Ops[I], Ord(Kinds[I]), Handlers[I]) then
    begin
      Ended := True;
      Break;
    end;
  end;
  if Branchy then
    EmitBranch(Count - 2, B.PC + Cardinal(Count - 2) * 4)
  else if not Ended then
    EmitStatic(B.PC + Cardinal(Count) * 4, B.PC + Cardinal(Count - 1) * 4, 0);

  // Out of line: too few cycles left, the accesses' slow ways, the ways out
  // after a store that dropped a block, the stubs of the ends.
  J.Bind(NoBudget);
  J.Move(jw32, JMem(jrSelf, OffPC), JImm(B.PC));
  J.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(B.PC + 4)));
  J.JumpTo(FExit);
  for var S in FSlow do
  begin
    if S.Table >= 0 then
    begin
      J.Bind(S.Table);
      EmitTable(S);
      J.Jump(S.Back);
    end;
    J.Bind(S.Slow);
    if S.Store then
    begin
      J.Move(jw32, JT5, S.Reg);
      J.Call(S.Routine, [JCtx, JT0, JT5]);
      J.BranchTest(jcNe, jw32, JT0, JT0, S.Hit);
    end
    else
      J.Call(S.Routine, [JImm(Int64(NativeUInt(FMemory))), JT0]);
    J.Jump(S.Back);
  end;
  for var H in FHitExits do
  begin
    J.Bind(H.L);
    WriteState(H.At);
    if H.At.Refund <> 0 then
      J.Alu(jaAdd, jw32, JMem(jrSelf, OffRemaining), JImm(H.At.Refund));
    J.JumpTo(FExit);
  end;
  for var E in FStatic do
  begin
    E.Stub := J.Offset;
    J.Move(jw32, JMem(jrSelf, OffPC), JImm(E.Target));
    J.Move(jw32, JMem(jrSelf, OffNPC), JImm(Cardinal(E.Target + 4)));
    J.Move(jw64, JT0, JImm(Int64(NativeUInt(E))));
    J.Move(JPtr, JMem(jrCtx, OffLastExit), JT0);
    J.JumpTo(FExit);
  end;
  J.ForgetLabels;
  J.Flush;
  for var E in FStatic do
    J.Redirect(E.Site, E.Stub);
  B.Code := Code;
  B.State := bsCompiled;
  var Page := FPages[B.Physical shr PSPPageShift];
  Cover(Page, B);
  var First := Integer((B.Physical and PSPPageMask) shr 2);
  for var I := 0 to Count - 1 do
    Page.Ops[First + I] := Ops[I];
  Inc(FCompiled);
  // Into blocks there already.
  for var E in FStatic do
  begin
    var P := FPages[(E.Target and $1FFFFFFF) shr PSPPageShift];
    if P = nil then
      Continue;
    var T := P.Entries[(E.Target and PSPPageMask) shr 2];
    if (T <> nil) and (T.PC = E.Target) and (T.State = bsCompiled) then
      Link(E, T);
  end;
end;

procedure TPSPRecompiler.Execute(B: PPSPJitBlock);
begin
  FHit := 0;
  FLastExit := nil;
  FInCode := True;
  Inc(FInvokes);
  try
    FJ.Invoke(FJ.Base + FEnter, NativeUInt(FCPU), NativeUInt(Self), NativeUInt(FJ.Base + FPrologue),
      NativeUInt(B.Code));
  finally
    FInCode := False;
  end;
end;

procedure TPSPRecompiler.Interpret(Steps: Integer);
begin
  // The interpreter's loop (TPSPCPU.Run), Steps instructions at most.
  var C := FCPU;
  while (C.FRemaining > 0) and (Steps > 0) do
  begin
    var PC := C.Ctx.PC;
    var Entry := C.Decoded(PC);
    C.CurPC := PC;
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
    Dec(C.FRemaining);
    Inc(FInterpreted);
    Entry.Handler(C, Entry.Op);
    if C.Stopping then
      Break;
    Dec(Steps);
  end;
end;

procedure TPSPRecompiler.Run(C: TPSPCPU);
begin
  if not FEnabled then
  begin
    Interpret(MaxInt);
    Exit;
  end;
  if FResetPending then
    ResetCode;
  FInRun := True;
  try
    RunBlocks(C);
  finally
    FInRun := False;
  end;
end;

procedure TPSPRecompiler.RunBlocks(C: TPSPCPU);
begin
  // The exit the code left by last (to link once its target is code).
  var Pending: PPSPJitExit := nil;
  while C.FRemaining > 0 do
  begin
    // (Dropped blocks' records and code are freed all at once.)
    if FResetPending or (FDead > MaxDead) then
    begin
      ResetCode;
      Pending := nil;
    end;
    var PC := C.Ctx.PC;
    if (C.Ctx.NPC = PC + 4) and ((PC and 3) = 0) then
    begin
      var B := Lookup(PC);
      if B.State = bsCold then
      begin
        Inc(B.Heat);
        if B.Heat >= PSPJitHot then
        begin
          if not FJ.Room(8192 + B.Count * 1536) then
          begin
            ResetCode;
            Pending := nil;
            B := Lookup(PC);
          end;
          Compile(B);
        end;
      end;
      if B.State = bsCompiled then
      begin
        if B.Count > C.FRemaining then
        begin
          // The budget ends within it.
          Interpret(MaxInt);
          Break;
        end;
        if (Pending <> nil) and (Pending.Target = PC) and (Pending.Linked = nil) and (Pending.Block.State =
          bsCompiled) then
          Link(Pending, B);
        Execute(B);
        Pending := FLastExit;
        if C.Stopping then
          Break;
        Continue;
      end;
      Pending := nil;
      if B.State = bsCold then
      begin
        // Its instructions by the interpreter while they follow on.
        var Expected := PC;
        for var K := 1 to B.Count do
        begin
          if C.Ctx.PC <> Expected then
            Break;
          Interpret(1);
          if C.Stopping or (C.FRemaining <= 0) then
            Break;
          Inc(Expected, 4);
        end;
        if C.Stopping then
          Break;
        Continue;
      end;
    end
    else
      Pending := nil;
    Interpret(1);
    if C.Stopping then
      Break;
  end;
end;

procedure TPSPRecompiler.SetEnabled(Value: Boolean);
begin
  FEnabled := Value and (FJ <> nil);
end;

constructor TPSPRecompiler.Create(CPU: TPSPCPU; Options: TPSPJitOptions);
begin
  inherited Create;
  PrepareKinds;
  FCPU := CPU;
  FMemory := CPU.Memory;
  FOptions := Options;
  SetLength(FPages, PSPPageCount);
  FAll := TList<PPSPJitBlock>.Create;
  FAllExits := TList<PPSPJitExit>.Create;
  FSlots := TList<PPSPJitSlot>.Create;
  FSlow := TList<TPSPJitSlow>.Create;
  FHitExits := TList<TPSPJitHitExit>.Create;
  FStatic := TList<PPSPJitExit>.Create;
  if joModel in Options then
    FJ := CreateJitModel(JitBufferSize)
  else
    FJ := CreateJitAsm(JitBufferSize);
  FEnabled := FJ <> nil;
  FRamDirect := Cardinal(Length(FMemory.RAM)) = PSPRAMSize;
  if FRamDirect then
    for var Page := 0 to PSPRAMSize div PSPPageSize - 1 do
      if FMemory.PageBase(PSPRAMBase + Cardinal(Page) * PSPPageSize) <> @FMemory.RAM[Page * PSPPageSize] then
      begin
        FRamDirect := False;
        Break;
      end;
  if FJ <> nil then
    EmitShared;
  CPU.Runner := Self;
end;

destructor TPSPRecompiler.Destroy;
begin
  if (FCPU <> nil) and (FCPU.Runner = Self) then
    FCPU.Runner := nil;
  if (joStats in FOptions) and IsConsole then
    Writeln(ErrOutput, Format('PSP JIT: %d blocks compiled, %d runs of code, %d instructions interpreted, ' +
      '%d links, %d blocks dropped, %d resets',
      [FCompiled, FInvokes, FInterpreted, FLinks, FKills, FResets]));
  FInCode := False;
  ResetCode;
  FAll.Free;
  FAllExits.Free;
  FSlots.Free;
  FSlow.Free;
  FHitExits.Free;
  FStatic.Free;
  FJ.Free;
  inherited;
end;

function PSPJitOptions(out Off: Boolean): TPSPJitOptions;
begin
  Result := [];
  Off := False;
  for var S in GetEnvironmentVariable('PSPJIT').ToLower.Split([',', ' ', ';']) do
    if S = 'off' then
      Off := True
    else if S = 'model' then
      Include(Result, joModel)
    else if S = 'stats' then
      Include(Result, joStats);
end;

function CreatePSPRecompiler(CPU: TPSPCPU): TPSPRecompiler;
begin
  var Off: Boolean;
  var Options := PSPJitOptions(Off);
  if Off or (not JitSupported and not (joModel in Options)) then
    Exit(nil);
  Result := TPSPRecompiler.Create(CPU, Options);
  if Result.FJ = nil then
    FreeAndNil(Result);
end;

end.
