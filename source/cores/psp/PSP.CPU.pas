unit PSP.CPU;

// Allegrex interpreter. Instructions are decoded once per address into a page
// of (handler, opcode) pairs; stores into a decoded page re-decode the touched
// words. Every handler is a plain procedure of (CPU, opcode): a recompiler
// calls the same routines, so it cannot disagree with the interpreter.
// Delay slots: PC is the next instruction, NPC the one after; a taken branch
// replaces NPC.
{$IFDEF PSP_CHECKED}{$Q-}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory;

const
  // VFPU control registers 128..143 as indices into TPSPContext.VC.
  VFPU_PFXS = 0;
  VFPU_PFXT = 1;
  VFPU_PFXD = 2;
  VFPU_CC = 3;
  VFPU_INF4 = 4;
  VFPU_REV = 7;
  VFPU_RCX0 = 8;

  FCR31_C = 1 shl 23;

type
  TPSPCPU = class;
  TPSPOpHandler = procedure(C: TPSPCPU; Op: Cardinal);
  TPSPSyscallEvent = procedure(C: TPSPCPU; Code: Cardinal) of object;

  // Everything a thread switch saves and restores.
  TPSPContext = record
    GPR: array[0..31] of Cardinal;
    HI, LO: Cardinal;
    PC, NPC: Cardinal;
    FPR: array[0..31] of Cardinal;
    FCR31: Cardinal;
    LLBit: Cardinal;
    V: array[0..127] of Cardinal;
    VC: array[0..15] of Cardinal;
    // Prefix state the VFPU keeps decoded between a prefix and its consumer.
    VPrefix: array[0..3] of Cardinal;
  end;
  PPSPContext = ^TPSPContext;

  TPSPDecoded = record
    Handler: TPSPOpHandler;
    Op: Cardinal;
  end;
  PPSPDecoded = ^TPSPDecoded;
  TPSPDecodedPage = array[0..(PSPPageSize div 4) - 1] of TPSPDecoded;
  PPSPDecodedPage = ^TPSPDecodedPage;

  // A recompiler (PSP.CPU.JIT) that Run hands its budget to, told when
  // decoded code is rewritten or dropped.
  TPSPRunner = class abstract
  public
    procedure Run(C: TPSPCPU); virtual; abstract;
    procedure CodeWritten(Address, Size: Cardinal); virtual; abstract;
    procedure Flushed; virtual; abstract;
  end;

  TPSPCPU = class
  private
    FDecoded: array of PPSPDecodedPage;
    FPages: TArray<PPSPDecodedPage>;
    FOnSyscall: TPSPSyscallEvent;
    FOnBreak: TPSPSyscallEvent;
    // The last FPU compare and the condition before it, for the branch behind it.
    FCmpPC, FCmpOld: Cardinal;
    function DecodePage(PC: Cardinal): PPSPDecodedPage;
    procedure CodeWrite(Address, Size: Cardinal);
    procedure Interpret;
  public
    // The run's budget (Run, TakeCycles, AddCycles), for a runner.
    FRunLength, FRemaining, FAccounted: Integer;
    Runner: TPSPRunner;
    Ctx: TPSPContext;
    // System control coprocessor registers, as kernel-mode code reads and writes them.
    COP0: array[0..31] of Cardinal;
    // VFPU condition hazards: where the last mtvc to CC and the last vcmp were, and the CC before each.
    VccWritePC, VccWriteOld, VcmpPC, VcmpOld: Cardinal;
    // The last value the VFPU's S prefix stage produced in each lane, which an
    // out-of-range swizzle replays for the integer unpack instructions.
    VLatch: array[0..3] of Cardinal;
    Memory: TPSPMemory;
    CurPC: Cardinal;
    Stopping: Boolean;
    ExtraCycles: Integer;
    InterruptsEnabled: Boolean;
    constructor Create(AMemory: TPSPMemory);
    destructor Destroy; override;
    procedure Reset;
    procedure FlushDecoded;
    // The entry the interpreter runs at PC (its page decoded first).
    function Decoded(PC: Cardinal): PPSPDecoded; inline;
    // Executes until MaxCycles have been used or Stop is called; returns the cycles used.
    function Run(MaxCycles: Integer): Integer;
    // Cycles used in the current run since the last call (HLE time sync).
    function TakeCycles: Integer;
    // Single instruction, for tests and differential runs.
    procedure Step;
    procedure Stop; inline;
    procedure AddCycles(Cycles: Integer); inline;
    procedure SetPC(Address: Cardinal); inline;
    function FPRSingle(Index: Integer): Single; inline;
    procedure SetFPRSingle(Index: Integer; Value: Single); inline;
    property OnSyscall: TPSPSyscallEvent read FOnSyscall write FOnSyscall;
    property OnBreak: TPSPSyscallEvent read FOnBreak write FOnBreak;
  end;

  // Installed by PSP.VFPU: returns the handler for a VFPU/COP2 opcode.
  TPSPVFPUDecoder = function(Op: Cardinal): TPSPOpHandler;

var
  PSPVFPUDecoder: TPSPVFPUDecoder = nil;

function DecodeOp(Op: Cardinal): TPSPOpHandler;
procedure OpReserved(C: TPSPCPU; Op: Cardinal);
procedure OpNop(C: TPSPCPU; Op: Cardinal);

implementation

{ Field helpers }

function Sar32(V, S: Cardinal): Cardinal; inline;
begin
  if (V and $80000000) <> 0 then
    Result := not ((not V) shr S)
  else
    Result := V shr S;
end;

function RS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 21) and 31;
end;

function RT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and 31;
end;

function RD(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 11) and 31;
end;

function SA(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 6) and 31;
end;

function SImm(Op: Cardinal): Cardinal; inline;
begin
  Result := Cardinal(Integer(SmallInt(Word(Op))));
end;

function UImm(Op: Cardinal): Cardinal; inline;
begin
  Result := Op and $FFFF;
end;

// Targets count from the branch's own address: a branch in the delay slot of
// a taken one (compilers emit runs of bvt to one label) still reaches its label.
procedure Branch(C: TPSPCPU; Op: Cardinal; Taken: Boolean); inline;
begin
  if Taken then
    C.Ctx.NPC := C.CurPC + 4 + (SImm(Op) shl 2);
end;

procedure BranchLikely(C: TPSPCPU; Op: Cardinal; Taken: Boolean); inline;
begin
  if Taken then
    C.Ctx.NPC := C.CurPC + 4 + (SImm(Op) shl 2)
  else
  begin
    // Not taken: the delay slot is nullified.
    C.Ctx.PC := C.Ctx.NPC;
    C.Ctx.NPC := C.Ctx.NPC + 4;
  end;
end;

{ Generic }

procedure OpNop(C: TPSPCPU; Op: Cardinal);
begin
end;

procedure OpReserved(C: TPSPCPU; Op: Cardinal);
begin
  raise EPSPGuestFault.CreateFmt('PSP: reserved instruction %.8x at %.8x', [Op, C.CurPC]);
end;

procedure OpDecode(C: TPSPCPU; Op: Cardinal); forward;

{ SPECIAL }

procedure OpSLL(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RT(Op)] shl SA(Op);
end;

procedure OpSRL(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RT(Op)] shr SA(Op);
end;

procedure OpROTR(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RT(Op)];
  var S := SA(Op);
  if S = 0 then
    C.Ctx.GPR[RD(Op)] := V
  else
    C.Ctx.GPR[RD(Op)] := (V shr S) or (V shl (32 - S));
end;

procedure OpSRA(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := Sar32(C.Ctx.GPR[RT(Op)], SA(Op));
end;

procedure OpSLLV(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RT(Op)] shl (C.Ctx.GPR[RS(Op)] and 31);
end;

procedure OpSRLV(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RT(Op)] shr (C.Ctx.GPR[RS(Op)] and 31);
end;

procedure OpROTRV(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RT(Op)];
  var S := C.Ctx.GPR[RS(Op)] and 31;
  if S = 0 then
    C.Ctx.GPR[RD(Op)] := V
  else
    C.Ctx.GPR[RD(Op)] := (V shr S) or (V shl (32 - S));
end;

procedure OpSRAV(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := Sar32(C.Ctx.GPR[RT(Op)], C.Ctx.GPR[RS(Op)] and 31);
end;

// The low two bits of a register jump target are ignored.
procedure OpJR(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.NPC := C.Ctx.GPR[RS(Op)] and $FFFFFFFC;
end;

procedure OpJALR(C: TPSPCPU; Op: Cardinal);
begin
  var Target := C.Ctx.GPR[RS(Op)] and $FFFFFFFC;
  var D := RD(Op);
  if D <> 0 then
    C.Ctx.GPR[D] := C.Ctx.NPC;
  C.Ctx.NPC := Target;
end;

procedure OpMOVZ(C: TPSPCPU; Op: Cardinal);
begin
  if C.Ctx.GPR[RT(Op)] = 0 then
    C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)];
end;

procedure OpMOVN(C: TPSPCPU; Op: Cardinal);
begin
  if C.Ctx.GPR[RT(Op)] <> 0 then
    C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)];
end;

procedure OpSYSCALL(C: TPSPCPU; Op: Cardinal);
begin
  // The exception return breaks a pending ll/sc.
  C.Ctx.LLBit := 0;
  if Assigned(C.FOnSyscall) then
    C.FOnSyscall(C, (Op shr 6) and $FFFFF)
  else
    raise EPSPGuestFault.CreateFmt('PSP: syscall %.5x without a kernel', [(Op shr 6) and $FFFFF]);
  C.Ctx.GPR[0] := 0;
end;

procedure OpBREAK(C: TPSPCPU; Op: Cardinal);
begin
  if Assigned(C.FOnBreak) then
    C.FOnBreak(C, (Op shr 6) and $FFFFF)
  else
    raise EPSPGuestFault.CreateFmt('PSP: break %.5x at %.8x', [(Op shr 6) and $FFFFF, C.CurPC]);
end;

procedure OpMFHI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.HI;
end;

procedure OpMTHI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.HI := C.Ctx.GPR[RS(Op)];
end;

procedure OpMFLO(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.LO;
end;

procedure OpMTLO(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.LO := C.Ctx.GPR[RS(Op)];
end;

function LeadingZeros(V: Cardinal): Cardinal;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  BSR EAX, ECX
  JNZ @Found
  MOV EAX, 63
@Found:
  XOR EAX, 31
end;
{$ELSEIF Defined(CPUX86)}
asm
  BSR EAX, EAX
  JNZ @Found
  MOV EAX, 63
@Found:
  XOR EAX, 31
end;
{$ELSE}
begin
  if V = 0 then
    Exit(32);
  Result := 31;
  if V >= $10000 then
  begin
    V := V shr 16;
    Dec(Result, 16);
  end;
  if V >= $100 then
  begin
    V := V shr 8;
    Dec(Result, 8);
  end;
  if V >= $10 then
  begin
    V := V shr 4;
    Dec(Result, 4);
  end;
  if V >= 4 then
  begin
    V := V shr 2;
    Dec(Result, 2);
  end;
  if V >= 2 then
    Dec(Result);
end;
{$ENDIF}

procedure OpCLZ(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RS(Op)];
  if (V and $80000000) <> 0 then
    C.Ctx.GPR[RD(Op)] := 0
  else
    C.Ctx.GPR[RD(Op)] := LeadingZeros(V);
end;

procedure OpCLO(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RS(Op)];
  var N: Cardinal := 0;
  while (N < 32) and ((V and ($80000000 shr N)) <> 0) do
    Inc(N);
  C.Ctx.GPR[RD(Op)] := N;
end;

procedure OpMULT(C: TPSPCPU; Op: Cardinal);
begin
  var R := Int64(Integer(C.Ctx.GPR[RS(Op)])) * Int64(Integer(C.Ctx.GPR[RT(Op)]));
  C.Ctx.LO := Cardinal(R);
  C.Ctx.HI := Cardinal(UInt64(R) shr 32);
end;

procedure OpMULTU(C: TPSPCPU; Op: Cardinal);
begin
  var R := UInt64(C.Ctx.GPR[RS(Op)]) * UInt64(C.Ctx.GPR[RT(Op)]);
  C.Ctx.LO := Cardinal(R);
  C.Ctx.HI := Cardinal(R shr 32);
end;

procedure OpDIV(C: TPSPCPU; Op: Cardinal);
begin
  var A := Integer(C.Ctx.GPR[RS(Op)]);
  var B := Integer(C.Ctx.GPR[RT(Op)]);
  if B = 0 then
  begin
    C.Ctx.HI := Cardinal(A);
    if A < 0 then
      C.Ctx.LO := 1
    else
      C.Ctx.LO := $FFFFFFFF;
  end
  else if (A = Integer($80000000)) and (B = -1) then
  begin
    C.Ctx.LO := $80000000;
    C.Ctx.HI := 0;
  end
  else
  begin
    C.Ctx.LO := Cardinal(A div B);
    C.Ctx.HI := Cardinal(A mod B);
  end;
end;

procedure OpDIVU(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.GPR[RS(Op)];
  var B := C.Ctx.GPR[RT(Op)];
  if B = 0 then
  begin
    C.Ctx.HI := A;
    if A <= $FFFF then
      C.Ctx.LO := $FFFF
    else
      C.Ctx.LO := $FFFFFFFF;
  end
  else
  begin
    C.Ctx.LO := A div B;
    C.Ctx.HI := A mod B;
  end;
end;

procedure OpMADD(C: TPSPCPU; Op: Cardinal);
begin
  var Acc := Int64((UInt64(C.Ctx.HI) shl 32) or C.Ctx.LO);
  Acc := Acc + Int64(Integer(C.Ctx.GPR[RS(Op)])) * Int64(Integer(C.Ctx.GPR[RT(Op)]));
  C.Ctx.LO := Cardinal(Acc);
  C.Ctx.HI := Cardinal(UInt64(Acc) shr 32);
end;

procedure OpMADDU(C: TPSPCPU; Op: Cardinal);
begin
  var Acc := (UInt64(C.Ctx.HI) shl 32) or C.Ctx.LO;
  Acc := Acc + UInt64(C.Ctx.GPR[RS(Op)]) * UInt64(C.Ctx.GPR[RT(Op)]);
  C.Ctx.LO := Cardinal(Acc);
  C.Ctx.HI := Cardinal(Acc shr 32);
end;

procedure OpMSUB(C: TPSPCPU; Op: Cardinal);
begin
  var Acc := Int64((UInt64(C.Ctx.HI) shl 32) or C.Ctx.LO);
  Acc := Acc - Int64(Integer(C.Ctx.GPR[RS(Op)])) * Int64(Integer(C.Ctx.GPR[RT(Op)]));
  C.Ctx.LO := Cardinal(Acc);
  C.Ctx.HI := Cardinal(UInt64(Acc) shr 32);
end;

procedure OpMSUBU(C: TPSPCPU; Op: Cardinal);
begin
  var Acc := (UInt64(C.Ctx.HI) shl 32) or C.Ctx.LO;
  Acc := Acc - UInt64(C.Ctx.GPR[RS(Op)]) * UInt64(C.Ctx.GPR[RT(Op)]);
  C.Ctx.LO := Cardinal(Acc);
  C.Ctx.HI := Cardinal(Acc shr 32);
end;

procedure OpADDU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)] + C.Ctx.GPR[RT(Op)];
end;

procedure OpSUBU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)] - C.Ctx.GPR[RT(Op)];
end;

procedure OpAND(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)] and C.Ctx.GPR[RT(Op)];
end;

procedure OpOR(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)] or C.Ctx.GPR[RT(Op)];
end;

procedure OpXOR(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := C.Ctx.GPR[RS(Op)] xor C.Ctx.GPR[RT(Op)];
end;

procedure OpNOR(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := not (C.Ctx.GPR[RS(Op)] or C.Ctx.GPR[RT(Op)]);
end;

procedure OpSLT(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := Ord(Integer(C.Ctx.GPR[RS(Op)]) < Integer(C.Ctx.GPR[RT(Op)]));
end;

procedure OpSLTU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := Ord(C.Ctx.GPR[RS(Op)] < C.Ctx.GPR[RT(Op)]);
end;

procedure OpMAX(C: TPSPCPU; Op: Cardinal);
begin
  var A := Integer(C.Ctx.GPR[RS(Op)]);
  var B := Integer(C.Ctx.GPR[RT(Op)]);
  if A > B then
    C.Ctx.GPR[RD(Op)] := Cardinal(A)
  else
    C.Ctx.GPR[RD(Op)] := Cardinal(B);
end;

procedure OpMIN(C: TPSPCPU; Op: Cardinal);
begin
  var A := Integer(C.Ctx.GPR[RS(Op)]);
  var B := Integer(C.Ctx.GPR[RT(Op)]);
  if A < B then
    C.Ctx.GPR[RD(Op)] := Cardinal(A)
  else
    C.Ctx.GPR[RD(Op)] := Cardinal(B);
end;

{ REGIMM }

procedure OpBLTZ(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, Integer(C.Ctx.GPR[RS(Op)]) < 0);
end;

procedure OpBGEZ(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, Integer(C.Ctx.GPR[RS(Op)]) >= 0);
end;

procedure OpBLTZL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, Integer(C.Ctx.GPR[RS(Op)]) < 0);
end;

procedure OpBGEZL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, Integer(C.Ctx.GPR[RS(Op)]) >= 0);
end;

procedure OpBLTZAL(C: TPSPCPU; Op: Cardinal);
begin
  var Taken := Integer(C.Ctx.GPR[RS(Op)]) < 0;
  C.Ctx.GPR[31] := C.Ctx.NPC;
  Branch(C, Op, Taken);
end;

procedure OpBGEZAL(C: TPSPCPU; Op: Cardinal);
begin
  var Taken := Integer(C.Ctx.GPR[RS(Op)]) >= 0;
  C.Ctx.GPR[31] := C.Ctx.NPC;
  Branch(C, Op, Taken);
end;

procedure OpBLTZALL(C: TPSPCPU; Op: Cardinal);
begin
  var Taken := Integer(C.Ctx.GPR[RS(Op)]) < 0;
  C.Ctx.GPR[31] := C.Ctx.NPC;
  BranchLikely(C, Op, Taken);
end;

procedure OpBGEZALL(C: TPSPCPU; Op: Cardinal);
begin
  var Taken := Integer(C.Ctx.GPR[RS(Op)]) >= 0;
  C.Ctx.GPR[31] := C.Ctx.NPC;
  BranchLikely(C, Op, Taken);
end;

{ Primary }

procedure OpJ(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.NPC := ((C.CurPC + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
end;

procedure OpJAL(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[31] := C.Ctx.NPC;
  C.Ctx.NPC := ((C.CurPC + 4) and $F0000000) or ((Op and $03FFFFFF) shl 2);
end;

procedure OpBEQ(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, C.Ctx.GPR[RS(Op)] = C.Ctx.GPR[RT(Op)]);
end;

procedure OpB(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.NPC := C.CurPC + 4 + (SImm(Op) shl 2);
end;

procedure OpBNE(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, C.Ctx.GPR[RS(Op)] <> C.Ctx.GPR[RT(Op)]);
end;

procedure OpBLEZ(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, Integer(C.Ctx.GPR[RS(Op)]) <= 0);
end;

procedure OpBGTZ(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, Integer(C.Ctx.GPR[RS(Op)]) > 0);
end;

procedure OpBEQL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, C.Ctx.GPR[RS(Op)] = C.Ctx.GPR[RT(Op)]);
end;

procedure OpBNEL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, C.Ctx.GPR[RS(Op)] <> C.Ctx.GPR[RT(Op)]);
end;

procedure OpBLEZL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, Integer(C.Ctx.GPR[RS(Op)]) <= 0);
end;

procedure OpBGTZL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, Integer(C.Ctx.GPR[RS(Op)]) > 0);
end;

procedure OpADDIU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.GPR[RS(Op)] + SImm(Op);
end;

procedure OpSLTI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := Ord(Integer(C.Ctx.GPR[RS(Op)]) < Integer(SImm(Op)));
end;

procedure OpSLTIU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := Ord(C.Ctx.GPR[RS(Op)] < SImm(Op));
end;

procedure OpANDI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.GPR[RS(Op)] and UImm(Op);
end;

procedure OpORI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.GPR[RS(Op)] or UImm(Op);
end;

procedure OpXORI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.GPR[RS(Op)] xor UImm(Op);
end;

procedure OpLUI(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := Op shl 16;
end;

procedure OpLB(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := SignExtend8(C.Memory.Read8(C.Ctx.GPR[RS(Op)] + SImm(Op)));
end;

procedure OpLH(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := SignExtend16(C.Memory.Read16(C.Ctx.GPR[RS(Op)] + SImm(Op)));
end;

procedure OpLW(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Memory.Read32(C.Ctx.GPR[RS(Op)] + SImm(Op));
end;

procedure OpLBU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Memory.Read8(C.Ctx.GPR[RS(Op)] + SImm(Op));
end;

procedure OpLHU(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Memory.Read16(C.Ctx.GPR[RS(Op)] + SImm(Op));
end;

procedure OpLWL(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.GPR[RS(Op)] + SImm(Op);
  var Shift := (A and 3) * 8;
  var W := C.Memory.Read32(A and not Cardinal(3));
  var T := RT(Op);
  C.Ctx.GPR[T] := (C.Ctx.GPR[T] and ($00FFFFFF shr Shift)) or (W shl (24 - Shift));
end;

procedure OpLWR(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.GPR[RS(Op)] + SImm(Op);
  var Shift := (A and 3) * 8;
  var W := C.Memory.Read32(A and not Cardinal(3));
  var T := RT(Op);
  C.Ctx.GPR[T] := (C.Ctx.GPR[T] and not ($FFFFFFFF shr Shift)) or (W shr Shift);
end;

procedure OpSB(C: TPSPCPU; Op: Cardinal);
begin
  C.Memory.Write8(C.Ctx.GPR[RS(Op)] + SImm(Op), C.Ctx.GPR[RT(Op)]);
end;

procedure OpSH(C: TPSPCPU; Op: Cardinal);
begin
  C.Memory.Write16(C.Ctx.GPR[RS(Op)] + SImm(Op), C.Ctx.GPR[RT(Op)]);
end;

procedure OpSW(C: TPSPCPU; Op: Cardinal);
begin
  C.Memory.Write32(C.Ctx.GPR[RS(Op)] + SImm(Op), C.Ctx.GPR[RT(Op)]);
end;

procedure OpSWL(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.GPR[RS(Op)] + SImm(Op);
  var Shift := (A and 3) * 8;
  var Aligned := A and not Cardinal(3);
  var W := C.Memory.Read32(Aligned);
  C.Memory.Write32(Aligned, (W and not ($FFFFFFFF shr (24 - Shift))) or (C.Ctx.GPR[RT(Op)] shr (24 - Shift)));
end;

procedure OpSWR(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.GPR[RS(Op)] + SImm(Op);
  var Shift := (A and 3) * 8;
  var Aligned := A and not Cardinal(3);
  var W := C.Memory.Read32(Aligned);
  C.Memory.Write32(Aligned, (W and not ($FFFFFFFF shl Shift)) or (C.Ctx.GPR[RT(Op)] shl Shift));
end;

procedure OpLL(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Memory.Read32(C.Ctx.GPR[RS(Op)] + SImm(Op));
  C.Ctx.LLBit := 1;
end;

// A successful sc leaves the link set: only an exception clears it.
procedure OpSC(C: TPSPCPU; Op: Cardinal);
begin
  var T := RT(Op);
  if C.Ctx.LLBit <> 0 then
    C.Memory.Write32(C.Ctx.GPR[RS(Op)] + SImm(Op), C.Ctx.GPR[T]);
  if T <> 0 then
    C.Ctx.GPR[T] := C.Ctx.LLBit;
end;

procedure OpLWC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[RT(Op)] := C.Memory.Read32(C.Ctx.GPR[RS(Op)] + SImm(Op));
end;

procedure OpSWC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Memory.Write32(C.Ctx.GPR[RS(Op)] + SImm(Op), C.Ctx.FPR[RT(Op)]);
end;

{ SPECIAL3 }

procedure OpEXT(C: TPSPCPU; Op: Cardinal);
begin
  var Pos := SA(Op);
  var Size := RD(Op) + 1;
  var V := C.Ctx.GPR[RS(Op)] shr Pos;
  if Size < 32 then
    V := V and ((Cardinal(1) shl Size) - 1);
  C.Ctx.GPR[RT(Op)] := V;
end;

procedure OpINS(C: TPSPCPU; Op: Cardinal);
begin
  var Lsb := SA(Op);
  var Msb := RD(Op);
  if Msb < Lsb then
    Exit;
  var Size := Msb - Lsb + 1;
  var Mask: Cardinal;
  if Size >= 32 then
    Mask := $FFFFFFFF
  else
    Mask := ((Cardinal(1) shl Size) - 1) shl Lsb;
  var T := RT(Op);
  C.Ctx.GPR[T] := (C.Ctx.GPR[T] and not Mask) or ((C.Ctx.GPR[RS(Op)] shl Lsb) and Mask);
end;

procedure OpWSBH(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RT(Op)];
  C.Ctx.GPR[RD(Op)] := ((V and $00FF00FF) shl 8) or ((V and $FF00FF00) shr 8);
end;

procedure OpWSBW(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RT(Op)];
  C.Ctx.GPR[RD(Op)] := (V shl 24) or ((V and $FF00) shl 8) or ((V shr 8) and $FF00) or (V shr 24);
end;

procedure OpSEB(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := SignExtend8(C.Ctx.GPR[RT(Op)]);
end;

procedure OpSEH(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RD(Op)] := SignExtend16(C.Ctx.GPR[RT(Op)]);
end;

procedure OpBITREV(C: TPSPCPU; Op: Cardinal);
begin
  var V := C.Ctx.GPR[RT(Op)];
  V := ((V shr 1) and $55555555) or ((V and $55555555) shl 1);
  V := ((V shr 2) and $33333333) or ((V and $33333333) shl 2);
  V := ((V shr 4) and $0F0F0F0F) or ((V and $0F0F0F0F) shl 4);
  V := ((V shr 8) and $00FF00FF) or ((V and $00FF00FF) shl 8);
  C.Ctx.GPR[RD(Op)] := (V shr 16) or (V shl 16);
end;

{ SPECIAL2 (Allegrex) }

procedure OpMFIC(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := Ord(C.InterruptsEnabled);
end;

procedure OpMTIC(C: TPSPCPU; Op: Cardinal);
begin
  // Only bit 0 is the enable flag.
  C.InterruptsEnabled := (C.Ctx.GPR[RT(Op)] and 1) <> 0;
end;

procedure OpHALT(C: TPSPCPU; Op: Cardinal);
begin
  C.Stop;
end;

{ COP0 }

const
  COP0_STATUS = 12;
  COP0_EPC = 14;
  COP0_ERROREPC = 30;

procedure OpMFC0(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.COP0[RD(Op)];
end;

procedure OpMTC0(C: TPSPCPU; Op: Cardinal);
begin
  C.COP0[RD(Op)] := C.Ctx.GPR[RT(Op)];
end;

// eret has no delay slot: ERL returns to ErrorEPC, otherwise EXL to EPC.
procedure OpERET(C: TPSPCPU; Op: Cardinal);
begin
  var S := C.COP0[COP0_STATUS];
  var Target: Cardinal;
  if (S and 4) <> 0 then
  begin
    Target := C.COP0[COP0_ERROREPC];
    C.COP0[COP0_STATUS] := S and not Cardinal(4);
  end
  else
  begin
    Target := C.COP0[COP0_EPC];
    C.COP0[COP0_STATUS] := S and not Cardinal(2);
  end;
  C.Ctx.LLBit := 0;
  C.Ctx.PC := Target;
  C.Ctx.NPC := Target + 4;
end;

{ COP1 }

// The FPU is IEEE single precision with gradual underflow, the four rounding
// modes of FCR31 and its flags. Each result is first rounded to nearest by the
// host, then corrected for the guest's mode from the sign of the error, which
// is computed exactly in double precision. With FCR31.FS set, results that are
// tiny before rounding become zero; denormal operands are still used.

const
  FCR31_FS = 1 shl 24;
  FCR31_WRITABLE = $0181FFFF;
  FX_I = 1;
  FX_U = 2;
  FX_O = 4;
  FX_Z = 8;
  FX_V = 16;
  FPU_NAN = $7FC00000;
  FLT_MIN_D: Double = 1.1754943508222875E-38;

function FS(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 11) and 31;
end;

function FT(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 16) and 31;
end;

function FD(Op: Cardinal): Cardinal; inline;
begin
  Result := (Op shr 6) and 31;
end;

function F(C: TPSPCPU; Index: Cardinal): Single; inline;
begin
  Result := PSingle(@C.Ctx.FPR[Index])^;
end;

function BitsOf(X: Single): Cardinal; inline;
begin
  Result := PCardinal(@X)^;
end;

function IsNaNBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) > $7F800000;
end;

function IsInfBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) = $7F800000;
end;

function IsZeroBits(X: Cardinal): Boolean; inline;
begin
  Result := (X and $7FFFFFFF) = 0;
end;

// A NaN operand comes out quieted, the first one if both are; a signalling one is invalid.
function NaNOut(A, B: Cardinal; var Flags: Cardinal): Cardinal; inline;
begin
  Flags := 0;
  if IsNaNBits(A) then
  begin
    if (A and $400000) = 0 then
      Flags := FX_V;
    Result := A or $400000;
    if IsNaNBits(B) and ((B and $400000) = 0) then
      Flags := FX_V;
  end
  else
  begin
    if (B and $400000) = 0 then
      Flags := FX_V;
    Result := B or $400000;
  end;
end;

procedure FpuDone(C: TPSPCPU; D, Bits, Flags: Cardinal); inline;
begin
  C.Ctx.FPR[D] := Bits;
  C.Ctx.FCR31 := (C.Ctx.FCR31 and not Cardinal($3F000)) or (Flags shl 12) or (Flags shl 2);
end;

function NextUp(R: Cardinal): Cardinal; inline;
begin
  if (R and $80000000) = 0 then
  begin
    if R < $7F800000 then
      Result := R + 1
    else
      Result := R;
  end
  else if R = $80000000 then
    Result := 1
  else
    Result := R - 1;
end;

function NextDown(R: Cardinal): Cardinal; inline;
begin
  if (R and $80000000) <> 0 then
  begin
    if R < $FF800000 then
      Result := R + 1
    else
      Result := R;
  end
  else if R = 0 then
    Result := $80000001
  else
    Result := R - 1;
end;

// R is the nearest single to the exact result; Dir is the sign of exact - R.
function FpuRound(R: Cardinal; Dir: Integer; Mode: Cardinal): Cardinal; inline;
begin
  Result := R;
  if Dir = 0 then
    Exit;
  case Mode of
    1:
      if (((R and $80000000) = 0) and (Dir < 0)) or (((R and $80000000) <> 0) and (Dir > 0)) then
        if (R and $7FFFFFFF) <> 0 then
          Result := R - 1;
    2:
      if Dir > 0 then
        Result := NextUp(R);
    3:
      if Dir < 0 then
        Result := NextDown(R);
  end;
end;

function SignOf(D: Double): Integer; inline;
begin
  if D > 0 then
    Result := 1
  else if D < 0 then
    Result := -1
  else
    Result := 0;
end;

// Flags for a non-flushed result; Nearest is the result before the mode's correction.
function ResultFlags(Nearest, R: Cardinal; Dir: Integer; Tiny: Boolean): Cardinal; inline;
begin
  Result := 0;
  if Dir <> 0 then
  begin
    Result := FX_I;
    if Tiny then
      Result := Result or FX_U;
  end;
  if IsInfBits(Nearest) or IsInfBits(R) then
    Result := Result or FX_O or FX_I;
end;

procedure FpuAdd(C: TPSPCPU; Op: Cardinal; NegB: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  B := B xor NegB;
  if IsInfBits(A) or IsInfBits(B) then
  begin
    if IsInfBits(A) and IsInfBits(B) and (((A xor B) and $80000000) <> 0) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else if IsInfBits(A) then
      FpuDone(C, D, A, 0)
    else
      FpuDone(C, D, B, 0);
    Exit;
  end;
  var Mode := C.Ctx.FCR31 and 3;
  var Flush := (C.Ctx.FCR31 and FCR31_FS) <> 0;
  if IsZeroBits(A) or IsZeroBits(B) then
  begin
    // A zero operand passes the other one through untouched.
    if IsZeroBits(A) and IsZeroBits(B) then
    begin
      if (A xor B) and $80000000 = 0 then
        FpuDone(C, D, A, 0)
      else if Mode = 3 then
        FpuDone(C, D, $80000000, 0)
      else
        FpuDone(C, D, 0, 0);
    end
    else if IsZeroBits(A) then
      FpuDone(C, D, B, 0)
    else
      FpuDone(C, D, A, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var RS: Single := X + Y;
  var R := BitsOf(RS);
  var S: Double := Double(X) + Double(Y);
  if (R and $7FFFFFFF) = 0 then
  begin
    if Mode = 3 then
      FpuDone(C, D, $80000000, 0)
    else
      FpuDone(C, D, 0, 0);
    Exit;
  end;
  var Gap := Integer(A and $7F800000) - Integer(B and $7F800000);
  var E := R and $7F800000;
  if (Mode = 0) and (E <> 0) and (E <> $7F800000) then
  begin
    FpuDone(C, D, R, Ord((S <> Double(RS)) or (Abs(Gap) >= (30 shl 23))));
    Exit;
  end;
  var Dir := SignOf(S - Double(RS));
  // With at most 29 exponent bits between operands the double sum is exact.
  // Otherwise the single is the larger operand and the error has the smaller's sign.
  if Dir = 0 then
    if Gap >= (30 shl 23) then
      Dir := 1 - Integer(B shr 31) * 2
    else if Gap <= -(30 shl 23) then
      Dir := 1 - Integer(A shr 31) * 2;
  var Tiny := ((R and $7F800000) = 0) and ((R and $7FFFFF) <> 0);
  if Tiny and Flush then
  begin
    FpuDone(C, D, R and $80000000, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, Mode);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpADDS(C: TPSPCPU; Op: Cardinal);
begin
  FpuAdd(C, Op, 0);
end;

procedure OpSUBS(C: TPSPCPU; Op: Cardinal);
begin
  FpuAdd(C, Op, $80000000);
end;

procedure OpMULS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  var Sign := (A xor B) and $80000000;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsInfBits(A) or IsInfBits(B) then
  begin
    if IsZeroBits(A) or IsZeroBits(B) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, 0);
    Exit;
  end;
  if IsZeroBits(A) or IsZeroBits(B) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var P: Double := Double(X) * Double(Y);
  var RS: Single := P;
  var R := BitsOf(RS);
  var E := R and $7F800000;
  if (C.Ctx.FCR31 and 3 = 0) and (E > $00800000) and (E <> $7F800000) then
  begin
    FpuDone(C, D, R, Ord(P <> Double(RS)));
    Exit;
  end;
  var Dir := SignOf(P - Double(RS));
  var Tiny := Abs(P) < FLT_MIN_D;
  if Tiny and ((C.Ctx.FCR31 and FCR31_FS) <> 0) then
  begin
    FpuDone(C, D, Sign, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpDIVS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var D := FD(Op);
  var Sign := (A xor B) and $80000000;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, B, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsInfBits(A) then
  begin
    if IsInfBits(B) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, 0);
    Exit;
  end;
  if IsInfBits(B) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  if IsZeroBits(B) then
  begin
    if IsZeroBits(A) then
      FpuDone(C, D, FPU_NAN, FX_V)
    else
      FpuDone(C, D, Sign or $7F800000, FX_Z);
    Exit;
  end;
  if IsZeroBits(A) then
  begin
    FpuDone(C, D, Sign, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var Y: Single := PSingle(@B)^;
  var RS: Single := X / Y;
  var R := BitsOf(RS);
  var Dir: Integer;
  if IsInfBits(R) then
  begin
    if Sign = 0 then
      Dir := -1
    else
      Dir := 1;
  end
  else
  begin
    var Diff: Double := Double(X) - Double(RS) * Double(Y);
    Dir := SignOf(Diff);
    if Y < 0 then
      Dir := -Dir;
  end;
  var Tiny := Abs(Double(X)) < Abs(Double(Y)) * FLT_MIN_D;
  if Tiny and ((C.Ctx.FCR31 and FCR31_FS) <> 0) then
  begin
    FpuDone(C, D, Sign, FX_U or FX_I);
    Exit;
  end;
  var RN := R;
  R := FpuRound(R, Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(RN, R, Dir, Tiny));
end;

procedure OpSQRTS(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var D := FD(Op);
  if IsNaNBits(A) then
  begin
    var NF: Cardinal;
    var N := NaNOut(A, A, NF);
    FpuDone(C, D, N, NF);
    Exit;
  end;
  if IsZeroBits(A) then
  begin
    FpuDone(C, D, A, 0);
    Exit;
  end;
  if (A and $80000000) <> 0 then
  begin
    FpuDone(C, D, FPU_NAN, FX_V);
    Exit;
  end;
  if A = $7F800000 then
  begin
    FpuDone(C, D, A, 0);
    Exit;
  end;
  var X: Single := PSingle(@A)^;
  var RS: Single := Sqrt(Double(X));
  var Dir := SignOf(Double(X) - Double(RS) * Double(RS));
  var R := FpuRound(BitsOf(RS), Dir, C.Ctx.FCR31 and 3);
  FpuDone(C, D, R, ResultFlags(R, R, Dir, False));
end;

procedure OpABSS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)] and $7FFFFFFF;
end;

procedure OpMOVS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)];
end;

procedure OpNEGS(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FD(Op)] := C.Ctx.FPR[FS(Op)] xor $80000000;
end;

// Float to word with the given rounding: 0 nearest even, 1 toward zero,
// 2 toward +inf, 3 toward -inf. NaN and positive overflow give 7FFFFFFF,
// negative overflow 80000000, both invalid.
function FloatToWord(X: Cardinal; Mode: Cardinal; var Flags: Cardinal): Cardinal;
begin
  Flags := 0;
  if IsNaNBits(X) then
  begin
    Flags := FX_V;
    Exit($7FFFFFFF);
  end;
  var Neg := (X and $80000000) <> 0;
  var E := Integer((X shr 23) and $FF);
  var M := UInt64(X and $7FFFFF);
  if E <> 0 then
    M := M or $800000
  else
    E := 1;
  if M = 0 then
    Exit(0);
  // Value = M * 2^(E - 150).
  var K := E - 150;
  var Mag: UInt64;
  if K >= 8 then
    Mag := UInt64(1) shl 32
  else if K >= 0 then
    Mag := M shl K
  else
  begin
    var Rem: UInt64;
    var Half: UInt64;
    if -K >= 40 then
    begin
      Mag := 0;
      Rem := M;
      Half := UInt64(1) shl 39;
    end
    else
    begin
      Mag := M shr (-K);
      Rem := M and ((UInt64(1) shl (-K)) - 1);
      Half := UInt64(1) shl (-K - 1);
    end;
    if Rem <> 0 then
    begin
      Flags := FX_I;
      case Mode of
        0:
          if (Rem > Half) or ((Rem = Half) and ((Mag and 1) <> 0)) then
            Inc(Mag);
        2:
          if not Neg then
            Inc(Mag);
        3:
          if Neg then
            Inc(Mag);
      end;
    end;
  end;
  if Neg then
  begin
    if Mag > UInt64($80000000) then
    begin
      Flags := FX_V;
      Exit($80000000);
    end;
    Result := Cardinal(-Int64(Mag));
  end
  else
  begin
    if Mag > UInt64($7FFFFFFF) then
    begin
      Flags := FX_V;
      Exit($7FFFFFFF);
    end;
    Result := Cardinal(Mag);
  end;
end;

procedure DoToWord(C: TPSPCPU; Op, Mode: Cardinal); inline;
begin
  var Flags: Cardinal;
  var R := FloatToWord(C.Ctx.FPR[FS(Op)], Mode, Flags);
  FpuDone(C, FD(Op), R, Flags);
end;

procedure OpROUNDWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 0);
end;

procedure OpTRUNCWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 1);
end;

procedure OpCEILWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 2);
end;

procedure OpFLOORWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, 3);
end;

procedure OpCVTWS(C: TPSPCPU; Op: Cardinal);
begin
  DoToWord(C, Op, C.Ctx.FCR31 and 3);
end;

procedure OpCVTSW(C: TPSPCPU; Op: Cardinal);
begin
  var I := Integer(C.Ctx.FPR[FS(Op)]);
  var RS: Single := I;
  var Dir := SignOf(Double(I) - Double(RS));
  var R := FpuRound(BitsOf(RS), Dir, C.Ctx.FCR31 and 3);
  var Flags: Cardinal := 0;
  if Dir <> 0 then
    Flags := FX_I;
  FpuDone(C, FD(Op), R, Flags);
end;

procedure OpCCOND(C: TPSPCPU; Op: Cardinal);
begin
  var A := C.Ctx.FPR[FS(Op)];
  var B := C.Ctx.FPR[FT(Op)];
  var Cond := Op and 15;
  var R: Boolean;
  var Flags: Cardinal := 0;
  if IsNaNBits(A) or IsNaNBits(B) then
  begin
    R := (Cond and 1) <> 0;
    if (Cond and 8) <> 0 then
      Flags := FX_V;
  end
  else
  begin
    var X: Single := PSingle(@A)^;
    var Y: Single := PSingle(@B)^;
    R := (((Cond and 2) <> 0) and (X = Y)) or (((Cond and 4) <> 0) and (X < Y));
  end;
  // A branch right behind the compare still sees the old condition.
  C.FCmpPC := C.CurPC;
  C.FCmpOld := C.Ctx.FCR31 and FCR31_C;
  var V := C.Ctx.FCR31 and not Cardinal($3F000);
  if R then
    V := V or FCR31_C
  else
    V := V and not FCR31_C;
  C.Ctx.FCR31 := V or (Flags shl 12) or (Flags shl 2);
end;

function FpuCond(C: TPSPCPU): Boolean; inline;
begin
  if C.CurPC = C.FCmpPC + 4 then
    Result := C.FCmpOld <> 0
  else
    Result := (C.Ctx.FCR31 and FCR31_C) <> 0;
end;

procedure OpMFC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.GPR[RT(Op)] := C.Ctx.FPR[FS(Op)];
end;

procedure OpCFC1(C: TPSPCPU; Op: Cardinal);
begin
  case FS(Op) of
    0:
      C.Ctx.GPR[RT(Op)] := $00003351;
    31:
      C.Ctx.GPR[RT(Op)] := C.Ctx.FCR31;
  else
    C.Ctx.GPR[RT(Op)] := 0;
  end;
end;

procedure OpMTC1(C: TPSPCPU; Op: Cardinal);
begin
  C.Ctx.FPR[FS(Op)] := C.Ctx.GPR[RT(Op)];
end;

procedure OpCTC1(C: TPSPCPU; Op: Cardinal);
begin
  if FS(Op) = 31 then
  begin
    C.Ctx.FCR31 := C.Ctx.GPR[RT(Op)] and FCR31_WRITABLE;
    C.FCmpPC := 0;
  end;
end;

procedure OpBC1F(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, not FpuCond(C));
end;

procedure OpBC1T(C: TPSPCPU; Op: Cardinal);
begin
  Branch(C, Op, FpuCond(C));
end;

procedure OpBC1FL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, not FpuCond(C));
end;

procedure OpBC1TL(C: TPSPCPU; Op: Cardinal);
begin
  BranchLikely(C, Op, FpuCond(C));
end;

procedure OpCACHE(C: TPSPCPU; Op: Cardinal);
begin
end;

{ Decoder }

function DecodeSpecial(Op: Cardinal): TPSPOpHandler;
begin
  var D := RD(Op);
  case Op and $3F of
    $00:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSLL;
    $02:
      if D = 0 then
        Result := OpNop
      else if (RS(Op) and 1) <> 0 then
        Result := OpROTR
      else
        Result := OpSRL;
    $03:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSRA;
    $04:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSLLV;
    $06:
      if D = 0 then
        Result := OpNop
      else if (SA(Op) and 1) <> 0 then
        Result := OpROTRV
      else
        Result := OpSRLV;
    $07:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSRAV;
    $08:
      Result := OpJR;
    $09:
      Result := OpJALR;
    $0A:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMOVZ;
    $0B:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMOVN;
    $0C:
      Result := OpSYSCALL;
    $0D:
      Result := OpBREAK;
    $0F:
      Result := OpNop;
    $10:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMFHI;
    $11:
      Result := OpMTHI;
    $12:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMFLO;
    $13:
      Result := OpMTLO;
    $16:
      if D = 0 then
        Result := OpNop
      else
        Result := OpCLZ;
    $17:
      if D = 0 then
        Result := OpNop
      else
        Result := OpCLO;
    $18:
      Result := OpMULT;
    $19:
      Result := OpMULTU;
    $1A:
      Result := OpDIV;
    $1B:
      Result := OpDIVU;
    $1C:
      Result := OpMADD;
    $1D:
      Result := OpMADDU;
    $20, $21:
      if D = 0 then
        Result := OpNop
      else
        Result := OpADDU;
    $22, $23:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSUBU;
    $24:
      if D = 0 then
        Result := OpNop
      else
        Result := OpAND;
    $25:
      if D = 0 then
        Result := OpNop
      else
        Result := OpOR;
    $26:
      if D = 0 then
        Result := OpNop
      else
        Result := OpXOR;
    $27:
      if D = 0 then
        Result := OpNop
      else
        Result := OpNOR;
    $2A:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSLT;
    $2B:
      if D = 0 then
        Result := OpNop
      else
        Result := OpSLTU;
    $2C:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMAX;
    $2D:
      if D = 0 then
        Result := OpNop
      else
        Result := OpMIN;
    $2E:
      Result := OpMSUB;
    $2F:
      Result := OpMSUBU;
  else
    Result := OpReserved;
  end;
end;

function DecodeRegImm(Op: Cardinal): TPSPOpHandler;
begin
  case RT(Op) of
    $00:
      Result := OpBLTZ;
    $01:
      Result := OpBGEZ;
    $02:
      Result := OpBLTZL;
    $03:
      Result := OpBGEZL;
    $10:
      Result := OpBLTZAL;
    $11:
      Result := OpBGEZAL;
    $12:
      Result := OpBLTZALL;
    $13:
      Result := OpBGEZALL;
  else
    Result := OpReserved;
  end;
end;

function DecodeSpecial3(Op: Cardinal): TPSPOpHandler;
begin
  var Dest := RT(Op);
  case Op and $3F of
    $00:
      if Dest = 0 then
        Result := OpNop
      else
        Result := OpEXT;
    $04:
      if Dest = 0 then
        Result := OpNop
      else
        Result := OpINS;
    $20:
      begin
        if RD(Op) = 0 then
        begin
          Result := OpNop;
          Exit;
        end;
        // The op is the sa field; only some of its bits are decoded.
        var S := SA(Op);
        if (S and $10) = 0 then
        begin
          if (S and 1) = 0 then
            Result := OpWSBH
          else
            Result := OpWSBW;
        end
        else
          case (S shr 2) and 3 of
            0:
              Result := OpSEB;
            2:
              Result := OpSEH;
          else
            Result := OpBITREV;
          end;
      end;
    $18:
      Result := OpNop;
  else
    Result := OpReserved;
  end;
end;

function DecodeCOP1(Op: Cardinal): TPSPOpHandler;
begin
  case RS(Op) of
    $00:
      if RT(Op) = 0 then
        Result := OpNop
      else
        Result := OpMFC1;
    $02:
      if RT(Op) = 0 then
        Result := OpNop
      else
        Result := OpCFC1;
    $04:
      Result := OpMTC1;
    $06:
      Result := OpCTC1;
    $08:
      case RT(Op) and 3 of
        0:
          Result := OpBC1F;
        1:
          Result := OpBC1T;
        2:
          Result := OpBC1FL;
      else
        Result := OpBC1TL;
      end;
    $10:
      case Op and $3F of
        $00:
          Result := OpADDS;
        $01:
          Result := OpSUBS;
        $02:
          Result := OpMULS;
        $03:
          Result := OpDIVS;
        $04:
          Result := OpSQRTS;
        $05:
          Result := OpABSS;
        $06:
          Result := OpMOVS;
        $07:
          Result := OpNEGS;
        $0C:
          Result := OpROUNDWS;
        $0D:
          Result := OpTRUNCWS;
        $0E:
          Result := OpCEILWS;
        $0F:
          Result := OpFLOORWS;
        $24:
          Result := OpCVTWS;
        $30..$3F:
          Result := OpCCOND;
      else
        Result := OpReserved;
      end;
    $14:
      if (Op and $3F) = $20 then
        Result := OpCVTSW
      else
        Result := OpReserved;
  else
    Result := OpReserved;
  end;
end;

function DecodeVFPU(Op: Cardinal): TPSPOpHandler;
begin
  if Assigned(PSPVFPUDecoder) then
    Result := PSPVFPUDecoder(Op)
  else
    Result := OpReserved;
end;

function DecodeOp(Op: Cardinal): TPSPOpHandler;
begin
  var T := RT(Op);
  case Op shr 26 of
    $00:
      Result := DecodeSpecial(Op);
    $01:
      Result := DecodeRegImm(Op);
    $02:
      Result := OpJ;
    $03:
      Result := OpJAL;
    $04:
      if (RS(Op) = 0) and (T = 0) then
        Result := OpB
      else
        Result := OpBEQ;
    $05:
      Result := OpBNE;
    $06:
      Result := OpBLEZ;
    $07:
      Result := OpBGTZ;
    $08, $09:
      if T = 0 then
        Result := OpNop
      else
        Result := OpADDIU;
    $0A:
      if T = 0 then
        Result := OpNop
      else
        Result := OpSLTI;
    $0B:
      if T = 0 then
        Result := OpNop
      else
        Result := OpSLTIU;
    $0C:
      if T = 0 then
        Result := OpNop
      else
        Result := OpANDI;
    $0D:
      if T = 0 then
        Result := OpNop
      else
        Result := OpORI;
    $0E:
      if T = 0 then
        Result := OpNop
      else
        Result := OpXORI;
    $0F:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLUI;
    $10:
      case RS(Op) of
        $00:
          if T = 0 then
            Result := OpNop
          else
            Result := OpMFC0;
        $04:
          Result := OpMTC0;
        $10:
          if (Op and $3F) = $18 then
            Result := OpERET
          else
            Result := OpNop;
      else
        Result := OpNop;
      end;
    $11:
      Result := DecodeCOP1(Op);
    $12, $18, $19, $1B, $32, $34, $35, $36, $37, $3A, $3C, $3D, $3E, $3F:
      Result := DecodeVFPU(Op);
    $14:
      Result := OpBEQL;
    $15:
      Result := OpBNEL;
    $16:
      Result := OpBLEZL;
    $17:
      Result := OpBGTZL;
    $1C:
      case Op and $3F of
        $00:
          Result := OpHALT;
        $24:
          if T = 0 then
            Result := OpNop
          else
            Result := OpMFIC;
        $26:
          Result := OpMTIC;
      else
        Result := OpReserved;
      end;
    $1F:
      Result := DecodeSpecial3(Op);
    $20:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLB;
    $21:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLH;
    $22:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLWL;
    $23:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLW;
    $24:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLBU;
    $25:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLHU;
    $26:
      if T = 0 then
        Result := OpNop
      else
        Result := OpLWR;
    $28:
      Result := OpSB;
    $29:
      Result := OpSH;
    $2A:
      Result := OpSWL;
    $2B:
      Result := OpSW;
    $2E:
      Result := OpSWR;
    $2F:
      Result := OpCACHE;
    $30:
      Result := OpLL;
    $31:
      Result := OpLWC1;
    $38:
      Result := OpSC;
    $39:
      Result := OpSWC1;
  else
    Result := OpReserved;
  end;
end;

procedure OpDecode(C: TPSPCPU; Op: Cardinal);
begin
  var PC := C.CurPC;
  var Page := C.FDecoded[(PC and $1FFFFFFF) shr PSPPageShift];
  var Entry: PPSPDecoded := @Page[(PC and PSPPageMask) shr 2];
  var Handler := DecodeOp(Op);
  Entry.Handler := Handler;
  Handler(C, Op);
end;

{ TPSPCPU }

constructor TPSPCPU.Create(AMemory: TPSPMemory);
begin
  inherited Create;
  Memory := AMemory;
  SetLength(FDecoded, PSPPageCount);
  Memory.OnCodeWrite := CodeWrite;
  Reset;
end;

destructor TPSPCPU.Destroy;
begin
  FlushDecoded;
  if (Memory <> nil) and (TMethod(Memory.OnCodeWrite).Data = Self) then
    Memory.OnCodeWrite := nil;
  inherited;
end;

procedure TPSPCPU.FlushDecoded;
begin
  for var P in FPages do
    Dispose(P);
  FPages := nil;
  if Length(FDecoded) > 0 then
    FillChar(FDecoded[0], Length(FDecoded) * SizeOf(Pointer), 0);
  if Memory <> nil then
    Memory.ClearCodeMarks;
  if Runner <> nil then
    Runner.Flushed;
end;

function TPSPCPU.Decoded(PC: Cardinal): PPSPDecoded;
begin
  var Page := FDecoded[(PC and $1FFFFFFF) shr PSPPageShift];
  if Page = nil then
    Page := DecodePage(PC);
  Result := @Page[(PC and PSPPageMask) shr 2];
end;

procedure TPSPCPU.Reset;
begin
  FlushDecoded;
  Ctx := Default(TPSPContext);
  FillChar(COP0, SizeOf(COP0), 0);
  FCmpPC := 0;
  VccWritePC := 0;
  VcmpPC := 0;
  FillChar(VLatch, SizeOf(VLatch), 0);
  Ctx.VC[VFPU_PFXS] := $E4;
  Ctx.VC[VFPU_PFXT] := $E4;
  Ctx.VC[VFPU_CC] := $3F;
  Ctx.VC[VFPU_INF4] := 0;
  Ctx.VC[VFPU_REV] := $7772CEAB;
  Ctx.VC[VFPU_RCX0] := $3F800001;
  for var I := 1 to 7 do
    Ctx.VC[VFPU_RCX0 + I] := $3F800000;
  CurPC := 0;
  Stopping := False;
  ExtraCycles := 0;
  InterruptsEnabled := True;
end;

function TPSPCPU.DecodePage(PC: Cardinal): PPSPDecodedPage;
begin
  var Index := (PC and $1FFFFFFF) shr PSPPageShift;
  var Source := Memory.PageBase(PC);
  if Source = nil then
    raise EPSPGuestFault.CreateFmt('PSP: execution outside memory at %.8x', [PC]);
  New(Result);
  for var I := 0 to High(TPSPDecodedPage) do
  begin
    Result[I].Handler := OpDecode;
    Result[I].Op := PCardinal(Source + I * 4)^;
  end;
  FDecoded[Index] := Result;
  FPages := FPages + [Result];
  Memory.MarkCode(PC);
end;

procedure TPSPCPU.CodeWrite(Address, Size: Cardinal);
begin
  var First := Address and not Cardinal(3);
  var Last := (Address + Size - 1) and not Cardinal(3);
  var A := First;
  while True do
  begin
    var Page := FDecoded[(A and $1FFFFFFF) shr PSPPageShift];
    if Page <> nil then
    begin
      var Entry: PPSPDecoded := @Page[(A and PSPPageMask) shr 2];
      Entry.Op := PCardinal(Memory.PageBase(A) + (A and PSPPageMask))^;
      Entry.Handler := OpDecode;
    end;
    if A >= Last then
      Break;
    Inc(A, 4);
  end;
  if Runner <> nil then
    Runner.CodeWritten(Address, Size);
end;

// Outside Run's FP-environment try/finally, the dispatch loop can keep its locals in registers.
procedure TPSPCPU.Interpret;
begin
  while FRemaining > 0 do
  begin
    var PC := Ctx.PC;
    var Page := FDecoded[(PC and $1FFFFFFF) shr PSPPageShift];
    if Page = nil then
      Page := DecodePage(PC);
    var Entry: PPSPDecoded := @Page[(PC and PSPPageMask) shr 2];
    CurPC := PC;
    Ctx.PC := Ctx.NPC;
    Ctx.NPC := Ctx.NPC + 4;
    Dec(FRemaining);
    Entry.Handler(Self, Entry.Op);
    if Stopping then
      Break;
  end;
end;

function TPSPCPU.Run(MaxCycles: Integer): Integer;
begin
  Stopping := False;
  ExtraCycles := 0;
  FRunLength := MaxCycles;
  FRemaining := MaxCycles;
  FAccounted := 0;
  // Guest float code needs IEEE defaults: no traps, round to nearest.
  var SavedMask := GetExceptionMask;
  var SavedRound := GetRoundMode;
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(rmNearest);
  try
    if Runner <> nil then
      Runner.Run(Self)
    else
      Interpret;
  finally
    SetExceptionMask(SavedMask);
    SetRoundMode(SavedRound);
  end;
  Result := TakeCycles;
  FRunLength := 0;
  FRemaining := 0;
  FAccounted := 0;
  ExtraCycles := 0;
end;

function TPSPCPU.TakeCycles: Integer;
begin
  var Done := FRunLength - FRemaining;
  Result := Done - FAccounted;
  FAccounted := Done;
end;

procedure TPSPCPU.Step;
begin
  Run(1);
end;

procedure TPSPCPU.Stop;
begin
  Stopping := True;
end;

procedure TPSPCPU.AddCycles(Cycles: Integer);
begin
  // Extra cost of the current instruction (HLE calls): it uses the run's budget.
  Dec(FRemaining, Cycles);
end;

procedure TPSPCPU.SetPC(Address: Cardinal);
begin
  Ctx.PC := Address;
  Ctx.NPC := Address + 4;
end;

function TPSPCPU.FPRSingle(Index: Integer): Single;
begin
  Result := PSingle(@Ctx.FPR[Index])^;
end;

procedure TPSPCPU.SetFPRSingle(Index: Integer; Value: Single);
begin
  PSingle(@Ctx.FPR[Index])^ := Value;
end;

end.
