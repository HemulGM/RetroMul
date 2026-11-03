unit PS2.IOP.CPU;

// The IOP's R3000A-compatible core for IOP modules (IRX) running under the
// high-level IOP kernel (or the BIOS's, Hardware): an interpreter (a table
// of procedures by opcode) with branch and load delay
// slots, 2 MiB of RAM (mirrored), the 1 KiB scratchpad and hardware
// registers through OnRead/OnWrite. Kernel services are reached through HLE
// trap words (major opcode 3Bh, an unused coprocessor 3 store) that the
// module loader writes into import stubs; OnTrap receives the low 26 bits.
// There is no cache, TLB or GTE; SYSCALL and BREAK go to OnException.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, Core.Snapshots, PS2.Types;

const
  IOPTrapOpcode = $3B;
  IOPTrapBase = Cardinal(IOPTrapOpcode) shl 26;
  IOPRegZero = 0;
  IOPRegV0 = 2;
  IOPRegV1 = 3;
  IOPRegA0 = 4;
  IOPRegA1 = 5;
  IOPRegA2 = 6;
  IOPRegA3 = 7;
  IOPRegT0 = 8;
  IOPRegGP = 28;
  IOPRegSP = 29;
  IOPRegFP = 30;
  IOPRegRA = 31;

type
  TIOPRead = function(Address: Cardinal; Size: Integer): Cardinal of object;
  TIOPWrite = procedure(Address, Value: Cardinal; Size: Integer) of object;
  TIOPTrap = procedure(Code: Cardinal) of object;
  // Code: 8 SYSCALL, 9 BREAK, 10 reserved instruction, 4/5 address error.
  TIOPException = procedure(Code: Integer; PC: Cardinal) of object;

  TIOPRegs = array[0..31] of Cardinal;

  TIOPContext = record
    R: TIOPRegs;
    HI, LO, PC: Cardinal;
    // The instruction after PC (a pending branch target when PC is a delay
    // slot); 0 means PC + 4.
    NextPC: Cardinal;
  end;

  TIOPCPU = class
  private
    FRAM: PByte;
    FStop: Boolean;
    // A load issued by the current instruction, and the one from the
    // previous instruction that lands after the current one.
    FLoadReg, FDelayReg: Integer;
    FLoadValue, FDelayValue: Cardinal;
    FBranch: Boolean;
    FInDelay: Boolean;
    FCurrentPC: Cardinal;
    // An exception taken by the current instruction (hardware exceptions).
    FExcepted: Boolean;
    function ReadMem(Address: Cardinal; Size: Integer): Cardinal;
    procedure Fault(Code: Integer; Address: Cardinal);
    function AddOverflows(A, B: Cardinal): Boolean; inline;
    function SubOverflows(A, B: Cardinal): Boolean; inline;
    // Raises address error Code when Address has bits of Mask set.
    function Misaligned(Address, Mask: Cardinal; Code: Integer): Boolean;
    procedure WriteMem(Address, Value: Cardinal; Size: Integer);
    procedure SetR(Index: Integer; Value: Cardinal); inline;
    procedure LoadDelayed(Index: Integer; Value: Cardinal); inline;
    procedure Jump(Target: Cardinal); inline;
  public
    R: TIOPRegs;
    HI, LO: Cardinal;
    PC, NextPC: Cardinal;
    SR, Cause, EPC: Cardinal;
    // IOP cycles executed (one per instruction, plus stalls charged by the
    // kernel).
    Cycles: Int64;
    Instructions: Int64;
    Scratchpad: array[0..1023] of Byte;
    OnRead: TIOPRead;
    OnWrite: TIOPWrite;
    OnTrap: TIOPTrap;
    OnException: TIOPException;
    // The IOP running its own kernel (BIOS boot): exceptions and interrupts
    // go to the exception vector (80000080h, BFC00180h with SR.BEV) instead
    // of OnException, ADD/ADDI/SUB trap on overflow, misaligned accesses
    // raise address errors and code runs from the BIOS ROM too.
    Hardware: Boolean;
    // The 4 MiB BIOS (code fetch from 1FC00000h).
    ROM: PByte;
    // The interrupt controller's line (Cause.IP2, bit 10).
    IntLine: Boolean;
    BadVAddr: Cardinal;
    // Cycles the idle loop skipped (hardware mode).
    SpinCycles: Int64;
    // COP0 debug registers (BPC, BDA, JUMPDEST, DCIC, BDAM, BPCM): kept.
    Debug: array[0..15] of Cardinal;
    constructor Create(RAM: PByte);
    // Takes exception Code (0 interrupt, 4/5 address error, 8 syscall, 9
    // break, 10 reserved instruction, 12 overflow) for the instruction at
    // InstrPC.
    procedure Enter(Code: Integer; InstrPC: Cardinal; InDelay: Boolean);
    procedure Reset;
    // Runs until Cycles reaches Target or Stop is called.
    procedure Run(Target: Int64);
    procedure Stop;
    // Continues at Value (also from a trap: replaces the pending jump).
    procedure SetPC(Value: Cardinal);
    procedure SaveContext(var C: TIOPContext);
    procedure LoadContext(const C: TIOPContext);
    function Read32(Address: Cardinal): Cardinal; inline;
    procedure Write32(Address, Value: Cardinal); inline;
    procedure SerializeState(State: TStateArchive);
    property RAM: PByte read FRAM;
  end;

// Physical IOP RAM offset of an address in RAM (mirrored), or -1.
function IOPRAMOffset(Address: Cardinal): Integer; inline;

implementation

function IOPRAMOffset(Address: Cardinal): Integer;
begin
  var P := Address and $1FFFFFFF;
  if P < $00800000 then
    Result := Integer(P and PS2IOPRAMMask)
  else
    Result := -1;
end;

// SRA/SRAV: the sign bit fills in (Delphi's shr is a logical shift).
function Sar32(V: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := V shr N;
  if Integer(V) < 0 then
    Result := Result or not (Cardinal($FFFFFFFF) shr N);
end;

{ TIOPCPU }

constructor TIOPCPU.Create(RAM: PByte);
begin
  inherited Create;
  FRAM := RAM;
  Reset;
end;

procedure TIOPCPU.Reset;
begin
  FillChar(R, SizeOf(R), 0);
  HI := 0;
  LO := 0;
  PC := 0;
  NextPC := 4;
  SR := 0;
  Cause := 0;
  EPC := 0;
  Cycles := 0;
  Instructions := 0;
  FLoadReg := 0;
  FLoadValue := 0;
  FDelayReg := 0;
  FDelayValue := 0;
  FBranch := False;
  FInDelay := False;
  FillChar(Scratchpad, SizeOf(Scratchpad), 0);
end;

procedure TIOPCPU.Stop;
begin
  FStop := True;
end;

procedure TIOPCPU.SetPC(Value: Cardinal);
begin
  PC := Value;
  NextPC := Add32(Value, 4);
  FBranch := False;
  FLoadReg := 0;
  FDelayReg := 0;
end;

procedure TIOPCPU.SaveContext(var C: TIOPContext);
begin
  if FDelayReg <> 0 then
  begin
    R[FDelayReg] := FDelayValue;
    FDelayReg := 0;
  end;
  C.R := R;
  C.HI := HI;
  C.LO := LO;
  C.PC := PC;
  C.NextPC := NextPC;
end;

procedure TIOPCPU.LoadContext(const C: TIOPContext);
begin
  R := C.R;
  R[0] := 0;
  HI := C.HI;
  LO := C.LO;
  SetPC(C.PC);
  if C.NextPC <> 0 then
    NextPC := C.NextPC;
end;

function TIOPCPU.Read32(Address: Cardinal): Cardinal;
begin
  Result := ReadMem(Address, 4);
end;

procedure TIOPCPU.Write32(Address, Value: Cardinal);
begin
  WriteMem(Address, Value, 4);
end;

function TIOPCPU.ReadMem(Address: Cardinal; Size: Integer): Cardinal;
begin
  var P := Address and $1FFFFFFF;
  if P < $00800000 then
  begin
    var A := P and PS2IOPRAMMask;
    case Size of
      1: Result := FRAM[A];
      2: Result := PWord(FRAM + A)^;
    else
      Result := PCardinal(FRAM + A)^;
    end;
  end
  else if (P >= $1F800000) and (P < $1F800400) then
  begin
    var A := P and $3FF;
    case Size of
      1: Result := Scratchpad[A];
      2: Result := PWord(@Scratchpad[A and $3FE])^;
    else
      Result := PCardinal(@Scratchpad[A and $3FC])^;
    end;
  end
  else if Assigned(OnRead) then
    Result := OnRead(P, Size)
  else
    Result := 0;
end;

procedure TIOPCPU.WriteMem(Address, Value: Cardinal; Size: Integer);
begin
  // Writes with the cache isolated (SR bit 16) go nowhere.
  if (SR and $10000) <> 0 then
    Exit;
  var P := Address and $1FFFFFFF;
  if P < $00800000 then
  begin
    var A := P and PS2IOPRAMMask;
    case Size of
      1: FRAM[A] := Byte(Value);
      2: PWord(FRAM + A)^ := Word(Value);
    else
      PCardinal(FRAM + A)^ := Value;
    end;
  end
  else if (P >= $1F800000) and (P < $1F800400) then
  begin
    var A := P and $3FF;
    case Size of
      1: Scratchpad[A] := Byte(Value);
      2: PWord(@Scratchpad[A and $3FE])^ := Word(Value);
    else
      PCardinal(@Scratchpad[A and $3FC])^ := Value;
    end;
  end
  else if Assigned(OnWrite) then
    OnWrite(P, Value, Size);
end;

procedure TIOPCPU.Enter(Code: Integer; InstrPC: Cardinal; InDelay: Boolean);
begin
  // The load of the previous instruction still lands.
  if FDelayReg <> 0 then
  begin
    R[FDelayReg] := FDelayValue;
    FDelayReg := 0;
  end;
  FLoadReg := 0;
  var C := Cause and not Cardinal($8000007C);
  C := C or (Cardinal(Code) shl 2);
  if InDelay then
  begin
    EPC := Sub32(InstrPC, 4);
    C := C or $80000000;
  end
  else
    EPC := InstrPC;
  Cause := C;
  // Push the kernel/user and interrupt-enable pairs (new ones: kernel,
  // interrupts off).
  SR := (SR and not Cardinal($3F)) or ((SR shl 2) and $3F);
  if (SR and $400000) <> 0 then
    PC := $BFC00180
  else
    PC := $80000080;
  NextPC := PC + 4;
  FBranch := False;
  FInDelay := False;
  FExcepted := True;
end;

// An address error (4 load or fetch, 5 store) at Address.
procedure TIOPCPU.Fault(Code: Integer; Address: Cardinal);
begin
  BadVAddr := Address;
  Enter(Code, FCurrentPC, FInDelay);
end;

function TIOPCPU.Misaligned(Address, Mask: Cardinal; Code: Integer): Boolean;
begin
  Result := (Address and Mask) <> 0;
  if Result then
    Fault(Code, Address);
end;

function TIOPCPU.AddOverflows(A, B: Cardinal): Boolean;
begin
  var S := Int64(Integer(A)) + Int64(Integer(B));
  Result := (S < Low(Integer)) or (S > High(Integer));
end;

function TIOPCPU.SubOverflows(A, B: Cardinal): Boolean;
begin
  var S := Int64(Integer(A)) - Int64(Integer(B));
  Result := (S < Low(Integer)) or (S > High(Integer));
end;

procedure TIOPCPU.SetR(Index: Integer; Value: Cardinal);
begin
  if Index <> 0 then
    R[Index] := Value;
  // A write cancels a pending load into the same register.
  if FDelayReg = Index then
    FDelayReg := 0;
end;

procedure TIOPCPU.LoadDelayed(Index: Integer; Value: Cardinal);
begin
  if Index = 0 then
    Exit;
  FLoadReg := Index;
  FLoadValue := Value;
end;

procedure TIOPCPU.Jump(Target: Cardinal);
begin
  NextPC := Target;
  FBranch := True;
end;

// The instructions, each a procedure of its own found through a table by
// its opcode (SPECIAL's by its function), as one case would decode them.
type
  TIOPOp = procedure(C: TIOPCPU; Op: Cardinal);

var
  IOPMain, IOPSpecial: array[0..63] of TIOPOp;

function OpRs(Op: Cardinal): Integer; inline;
begin
  Result := Integer((Op shr 21) and 31);
end;

function OpRt(Op: Cardinal): Integer; inline;
begin
  Result := Integer((Op shr 16) and 31);
end;

function OpRd(Op: Cardinal): Integer; inline;
begin
  Result := Integer((Op shr 11) and 31);
end;

function OpSa(Op: Cardinal): Integer; inline;
begin
  Result := Integer((Op shr 6) and 31);
end;

function OpSImm(Op: Cardinal): Cardinal; inline;
begin
  Result := SX16To32(Op and $FFFF);
end;

// A branch's target (the delay slot's address plus the offset).
function BranchTarget(C: TIOPCPU; Op: Cardinal): Cardinal; inline;
begin
  Result := Add32(Add32(C.FCurrentPC, 4), OpSImm(Op) shl 2);
end;

procedure OpReserved(C: TIOPCPU; Op: Cardinal);
begin
  // COP2 and the rest: not present on the IOP.
  if C.Hardware then
    C.Enter(10, C.FCurrentPC, C.FInDelay)
  else if Assigned(C.OnException) then
    C.OnException(10, C.FCurrentPC);
end;

{ SPECIAL }

procedure OpSLL(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRt(Op)] shl OpSa(Op));
end;

procedure OpSRL(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRt(Op)] shr OpSa(Op));
end;

procedure OpSRA(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Sar32(C.R[OpRt(Op)], OpSa(Op)));
end;

procedure OpSLLV(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRt(Op)] shl (C.R[OpRs(Op)] and 31));
end;

procedure OpSRLV(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRt(Op)] shr (C.R[OpRs(Op)] and 31));
end;

procedure OpSRAV(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Sar32(C.R[OpRt(Op)], C.R[OpRs(Op)] and 31));
end;

procedure OpJR(C: TIOPCPU; Op: Cardinal);
begin
  C.Jump(C.R[OpRs(Op)]);
end;

procedure OpJALR(C: TIOPCPU; Op: Cardinal);
begin
  var Target := C.R[OpRs(Op)];
  C.SetR(OpRd(Op), Add32(C.FCurrentPC, 8));
  C.Jump(Target);
end;

procedure OpSYSCALL(C: TIOPCPU; Op: Cardinal);
begin
  if C.Hardware then
    C.Enter(8, C.FCurrentPC, C.FInDelay)
  else if Assigned(C.OnException) then
    C.OnException(8, C.FCurrentPC);
end;

procedure OpBREAK(C: TIOPCPU; Op: Cardinal);
begin
  if C.Hardware then
    C.Enter(9, C.FCurrentPC, C.FInDelay)
  else if Assigned(C.OnException) then
    C.OnException(9, C.FCurrentPC);
end;

procedure OpMFHI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.HI);
end;

procedure OpMTHI(C: TIOPCPU; Op: Cardinal);
begin
  C.HI := C.R[OpRs(Op)];
end;

procedure OpMFLO(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.LO);
end;

procedure OpMTLO(C: TIOPCPU; Op: Cardinal);
begin
  C.LO := C.R[OpRs(Op)];
end;

procedure OpMULT(C: TIOPCPU; Op: Cardinal);
begin
  var P := Int64(Integer(C.R[OpRs(Op)])) * Int64(Integer(C.R[OpRt(Op)]));
  C.LO := Cardinal(P and $FFFFFFFF);
  C.HI := Cardinal((P shr 32) and $FFFFFFFF);
end;

procedure OpMULTU(C: TIOPCPU; Op: Cardinal);
begin
  var P := UInt64(C.R[OpRs(Op)]) * UInt64(C.R[OpRt(Op)]);
  C.LO := Cardinal(P and $FFFFFFFF);
  C.HI := Cardinal(P shr 32);
end;

procedure OpDIV(C: TIOPCPU; Op: Cardinal);
begin
  var N := Integer(C.R[OpRs(Op)]);
  var D := Integer(C.R[OpRt(Op)]);
  if D = 0 then
  begin
    C.HI := Cardinal(N);
    if N >= 0 then
      C.LO := $FFFFFFFF
    else
      C.LO := 1;
  end
  else if (Cardinal(N) = $80000000) and (D = -1) then
  begin
    C.LO := $80000000;
    C.HI := 0;
  end
  else
  begin
    C.LO := Cardinal(N div D);
    C.HI := Cardinal(N mod D);
  end;
end;

procedure OpDIVU(C: TIOPCPU; Op: Cardinal);
begin
  var N := C.R[OpRs(Op)];
  var D := C.R[OpRt(Op)];
  if D = 0 then
  begin
    C.LO := $FFFFFFFF;
    C.HI := N;
  end
  else
  begin
    C.LO := N div D;
    C.HI := N mod D;
  end;
end;

procedure OpADD(C: TIOPCPU; Op: Cardinal);
begin
  if C.Hardware and C.AddOverflows(C.R[OpRs(Op)], C.R[OpRt(Op)]) then
    C.Enter(12, C.FCurrentPC, C.FInDelay)
  else
    C.SetR(OpRd(Op), Add32(C.R[OpRs(Op)], C.R[OpRt(Op)]));
end;

procedure OpADDU(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Add32(C.R[OpRs(Op)], C.R[OpRt(Op)]));
end;

procedure OpSUB(C: TIOPCPU; Op: Cardinal);
begin
  if C.Hardware and C.SubOverflows(C.R[OpRs(Op)], C.R[OpRt(Op)]) then
    C.Enter(12, C.FCurrentPC, C.FInDelay)
  else
    C.SetR(OpRd(Op), Sub32(C.R[OpRs(Op)], C.R[OpRt(Op)]));
end;

procedure OpSUBU(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Sub32(C.R[OpRs(Op)], C.R[OpRt(Op)]));
end;

procedure OpAND(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRs(Op)] and C.R[OpRt(Op)]);
end;

procedure OpOR(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRs(Op)] or C.R[OpRt(Op)]);
end;

procedure OpXOR(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), C.R[OpRs(Op)] xor C.R[OpRt(Op)]);
end;

procedure OpNOR(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), not (C.R[OpRs(Op)] or C.R[OpRt(Op)]));
end;

procedure OpSLT(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Ord(Integer(C.R[OpRs(Op)]) < Integer(C.R[OpRt(Op)])));
end;

procedure OpSLTU(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRd(Op), Ord(C.R[OpRs(Op)] < C.R[OpRt(Op)]));
end;

{ Primary }

procedure OpSPECIAL(C: TIOPCPU; Op: Cardinal);
begin
  IOPSpecial[Op and 63](C, Op);
end;

procedure OpREGIMM(C: TIOPCPU; Op: Cardinal);
begin
  var Rs := OpRs(Op);
  var Rt := OpRt(Op);
  var Taken: Boolean;
  if (Rt and 1) = 0 then
    Taken := Integer(C.R[Rs]) < 0
  else
    Taken := Integer(C.R[Rs]) >= 0;
  // BLTZAL/BGEZAL link even when not taken.
  if (Rt and $1E) = $10 then
    C.SetR(31, Add32(C.FCurrentPC, 8));
  if Taken then
    C.Jump(BranchTarget(C, Op));
end;

procedure OpJ(C: TIOPCPU; Op: Cardinal);
begin
  C.Jump((Add32(C.FCurrentPC, 4) and $F0000000) or ((Op and $3FFFFFF) shl 2));
end;

procedure OpJAL(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(31, Add32(C.FCurrentPC, 8));
  C.Jump((Add32(C.FCurrentPC, 4) and $F0000000) or ((Op and $3FFFFFF) shl 2));
end;

procedure OpBEQ(C: TIOPCPU; Op: Cardinal);
begin
  if C.R[OpRs(Op)] = C.R[OpRt(Op)] then C.Jump(BranchTarget(C, Op));
end;

procedure OpBNE(C: TIOPCPU; Op: Cardinal);
begin
  if C.R[OpRs(Op)] <> C.R[OpRt(Op)] then C.Jump(BranchTarget(C, Op));
end;

procedure OpBLEZ(C: TIOPCPU; Op: Cardinal);
begin
  if Integer(C.R[OpRs(Op)]) <= 0 then C.Jump(BranchTarget(C, Op));
end;

procedure OpBGTZ(C: TIOPCPU; Op: Cardinal);
begin
  if Integer(C.R[OpRs(Op)]) > 0 then C.Jump(BranchTarget(C, Op));
end;

procedure OpADDI(C: TIOPCPU; Op: Cardinal);
begin
  if C.Hardware and C.AddOverflows(C.R[OpRs(Op)], OpSImm(Op)) then
    C.Enter(12, C.FCurrentPC, C.FInDelay)
  else
    C.SetR(OpRt(Op), Add32(C.R[OpRs(Op)], OpSImm(Op)));
end;

procedure OpADDIU(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), Add32(C.R[OpRs(Op)], OpSImm(Op)));
end;

procedure OpSLTI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), Ord(Integer(C.R[OpRs(Op)]) < Integer(OpSImm(Op))));
end;

procedure OpSLTIU(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), Ord(C.R[OpRs(Op)] < OpSImm(Op)));
end;

procedure OpANDI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), C.R[OpRs(Op)] and (Op and $FFFF));
end;

procedure OpORI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), C.R[OpRs(Op)] or (Op and $FFFF));
end;

procedure OpXORI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), C.R[OpRs(Op)] xor (Op and $FFFF));
end;

procedure OpLUI(C: TIOPCPU; Op: Cardinal);
begin
  C.SetR(OpRt(Op), (Op and $FFFF) shl 16);
end;

procedure OpCOP0(C: TIOPCPU; Op: Cardinal);
begin
  // MFC0, MTC0, RFE.
  var Rt := OpRt(Op);
  var Rd := OpRd(Op);
  case OpRs(Op) of
    0:
      case Rd of
        3, 5, 6, 7, 9, 11: C.LoadDelayed(Rt, C.Debug[Rd]);
        8: C.LoadDelayed(Rt, C.BadVAddr);
        12: C.LoadDelayed(Rt, C.SR);
        13: C.LoadDelayed(Rt, C.Cause or (Cardinal(Ord(C.IntLine and C.Hardware)) shl 10));
        14: C.LoadDelayed(Rt, C.EPC);
        15: C.LoadDelayed(Rt, $1F);
      else
        C.LoadDelayed(Rt, 0);
      end;
    4:
      case Rd of
        3, 5, 6, 7, 9, 11: C.Debug[Rd] := C.R[Rt];
        12: C.SR := C.R[Rt];
        13: C.Cause := (C.Cause and not $300) or (C.R[Rt] and $300);
        14: C.EPC := C.R[Rt];
      end;
    16:
      if (Op and 63) = $10 then
        C.SR := (C.SR and not $F) or ((C.SR shr 2) and $F);
  end;
end;

// Loads and stores reach RAM at once (KUSEG, KSEG0/1 and the mirrors below
// 8 MiB), the rest through ReadMem and WriteMem; misaligned ones fault as
// before with Hardware.

procedure OpLB(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  var P := A and $1FFFFFFF;
  var V: Cardinal;
  if P < $00800000 then
    V := C.FRAM[P and PS2IOPRAMMask]
  else
    V := C.ReadMem(A, 1);
  C.LoadDelayed(OpRt(Op), Cardinal(Integer(ShortInt(Byte(V)))));
end;

procedure OpLH(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  if C.Hardware and C.Misaligned(A, 1, 4) then
    Exit;
  var P := A and $1FFFFFFE;
  var V: Cardinal;
  if P < $00800000 then
    V := PWord(C.FRAM + (P and PS2IOPRAMMask))^
  else
    V := C.ReadMem(A and not 1, 2);
  C.LoadDelayed(OpRt(Op), SX16To32(V));
end;

procedure OpLWLR(C: TIOPCPU; Op: Cardinal);
begin
  // LWL/LWR merge with a value still in the load delay slot.
  var Rt := OpRt(Op);
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  var Cur := C.R[Rt];
  if C.FDelayReg = Rt then
    Cur := C.FDelayValue;
  var W := C.ReadMem(A and not 3, 4);
  var Sh := (A and 3) * 8;
  var V: Cardinal;
  if (Op shr 26) = $22 then
    V := (Cur and ($00FFFFFF shr Sh)) or (W shl (24 - Sh))
  else
    V := (Cur and not ($FFFFFFFF shr Sh)) or (W shr Sh);
  C.LoadDelayed(Rt, V);
end;

procedure OpLW(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  if C.Hardware and C.Misaligned(A, 3, 4) then
    Exit;
  var P := A and $1FFFFFFC;
  var V: Cardinal;
  if P < $00800000 then
    V := PCardinal(C.FRAM + (P and PS2IOPRAMMask))^
  else
    V := C.ReadMem(A and not 3, 4);
  C.LoadDelayed(OpRt(Op), V);
end;

procedure OpLBU(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  var P := A and $1FFFFFFF;
  var V: Cardinal;
  if P < $00800000 then
    V := C.FRAM[P and PS2IOPRAMMask]
  else
    V := C.ReadMem(A, 1);
  C.LoadDelayed(OpRt(Op), V);
end;

procedure OpLHU(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  if C.Hardware and C.Misaligned(A, 1, 4) then
    Exit;
  var P := A and $1FFFFFFE;
  var V: Cardinal;
  if P < $00800000 then
    V := PWord(C.FRAM + (P and PS2IOPRAMMask))^
  else
    V := C.ReadMem(A and not 1, 2);
  C.LoadDelayed(OpRt(Op), V);
end;

procedure OpSB(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  var V := C.R[OpRt(Op)] and $FF;
  // (Writes with the cache isolated go nowhere: WriteMem.)
  var P := A and $1FFFFFFF;
  if (P < $00800000) and ((C.SR and $10000) = 0) then
    C.FRAM[P and PS2IOPRAMMask] := Byte(V)
  else
    C.WriteMem(A, V, 1);
end;

procedure OpSH(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  if C.Hardware and C.Misaligned(A, 1, 5) then
    Exit;
  var V := C.R[OpRt(Op)] and $FFFF;
  var P := A and $1FFFFFFE;
  if (P < $00800000) and ((C.SR and $10000) = 0) then
    PWord(C.FRAM + (P and PS2IOPRAMMask))^ := Word(V)
  else
    C.WriteMem(A and not 1, V, 2);
end;

procedure OpSWLR(C: TIOPCPU; Op: Cardinal);
begin
  var Rt := OpRt(Op);
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  var W := C.ReadMem(A and not 3, 4);
  var Sh := (A and 3) * 8;
  if (Op shr 26) = $2A then
    W := (W and not ($FFFFFFFF shr (24 - Sh))) or (C.R[Rt] shr (24 - Sh))
  else
    W := (W and not ($FFFFFFFF shl Sh)) or (C.R[Rt] shl Sh);
  C.WriteMem(A and not 3, W, 4);
end;

procedure OpSW(C: TIOPCPU; Op: Cardinal);
begin
  var A := Add32(C.R[OpRs(Op)], OpSImm(Op));
  if C.Hardware and C.Misaligned(A, 3, 5) then
    Exit;
  var V := C.R[OpRt(Op)];
  var P := A and $1FFFFFFC;
  if (P < $00800000) and ((C.SR and $10000) = 0) then
    PCardinal(C.FRAM + (P and PS2IOPRAMMask))^ := V
  else
    C.WriteMem(A and not 3, V, 4);
end;

procedure OpTrap(C: TIOPCPU; Op: Cardinal);
begin
  if Assigned(C.OnTrap) then
    C.OnTrap(Op and $3FFFFFF);
end;

procedure InitIOPOps;
begin
  for var K := 0 to 63 do
  begin
    IOPMain[K] := OpReserved;
    IOPSpecial[K] := OpReserved;
  end;
  IOPSpecial[$00] := OpSLL;
  IOPSpecial[$02] := OpSRL;
  IOPSpecial[$03] := OpSRA;
  IOPSpecial[$04] := OpSLLV;
  IOPSpecial[$06] := OpSRLV;
  IOPSpecial[$07] := OpSRAV;
  IOPSpecial[$08] := OpJR;
  IOPSpecial[$09] := OpJALR;
  IOPSpecial[$0C] := OpSYSCALL;
  IOPSpecial[$0D] := OpBREAK;
  IOPSpecial[$10] := OpMFHI;
  IOPSpecial[$11] := OpMTHI;
  IOPSpecial[$12] := OpMFLO;
  IOPSpecial[$13] := OpMTLO;
  IOPSpecial[$18] := OpMULT;
  IOPSpecial[$19] := OpMULTU;
  IOPSpecial[$1A] := OpDIV;
  IOPSpecial[$1B] := OpDIVU;
  IOPSpecial[$20] := OpADD;
  IOPSpecial[$21] := OpADDU;
  IOPSpecial[$22] := OpSUB;
  IOPSpecial[$23] := OpSUBU;
  IOPSpecial[$24] := OpAND;
  IOPSpecial[$25] := OpOR;
  IOPSpecial[$26] := OpXOR;
  IOPSpecial[$27] := OpNOR;
  IOPSpecial[$2A] := OpSLT;
  IOPSpecial[$2B] := OpSLTU;
  IOPMain[$00] := OpSPECIAL;
  IOPMain[$01] := OpREGIMM;
  IOPMain[$02] := OpJ;
  IOPMain[$03] := OpJAL;
  IOPMain[$04] := OpBEQ;
  IOPMain[$05] := OpBNE;
  IOPMain[$06] := OpBLEZ;
  IOPMain[$07] := OpBGTZ;
  IOPMain[$08] := OpADDI;
  IOPMain[$09] := OpADDIU;
  IOPMain[$0A] := OpSLTI;
  IOPMain[$0B] := OpSLTIU;
  IOPMain[$0C] := OpANDI;
  IOPMain[$0D] := OpORI;
  IOPMain[$0E] := OpXORI;
  IOPMain[$0F] := OpLUI;
  IOPMain[$10] := OpCOP0;
  IOPMain[$20] := OpLB;
  IOPMain[$21] := OpLH;
  IOPMain[$22] := OpLWLR;
  IOPMain[$23] := OpLW;
  IOPMain[$24] := OpLBU;
  IOPMain[$25] := OpLHU;
  IOPMain[$26] := OpLWLR;
  IOPMain[$28] := OpSB;
  IOPMain[$29] := OpSH;
  IOPMain[$2A] := OpSWLR;
  IOPMain[$2B] := OpSW;
  IOPMain[$2E] := OpSWLR;
  IOPMain[IOPTrapOpcode] := OpTrap;
end;

procedure TIOPCPU.Run(Target: Int64);
begin
  FStop := False;
  if not Hardware then
  begin
    // The loop below without what only Hardware has: interrupts, the BIOS,
    // the idle loop, address errors (an instruction then always completes).
    while (Cycles < Target) and not FStop do
    begin
      var A := PC and $1FFFFFFF;
      if A >= $00800000 then
      begin
        if Assigned(OnException) then
          OnException(4, PC);
        Break;
      end;
      var Op := PCardinal(FRAM + (A and (PS2IOPRAMMask and not 3)))^;
      FCurrentPC := PC;
      FInDelay := FBranch;
      FBranch := False;
      PC := NextPC;
      NextPC := Add32(PC, 4);
      IOPMain[Op shr 26](Self, Op);
      if FDelayReg <> 0 then
        R[FDelayReg] := FDelayValue;
      FDelayReg := FLoadReg;
      FDelayValue := FLoadValue;
      FLoadReg := 0;
      Inc(Cycles);
      Inc(Instructions);
    end;
    Exit;
  end;
  while (Cycles < Target) and not FStop do
  begin
    // A pending interrupt (I_CTRL and I_STAT and I_MASK) is taken before the
    // next instruction when SR enables IP2 and IEc.
    if Hardware and IntLine and ((SR and $401) = $401) then
      Enter(0, PC, FBranch);
    var Op: Cardinal;
    var A := PC and $1FFFFFFF;
    if A < $00800000 then
      Op := PCardinal(FRAM + (A and (PS2IOPRAMMask and not 3)))^
    else if Hardware and (A >= $1FC00000) and (ROM <> nil) then
      Op := PCardinal(ROM + (A and (PS2BIOSMask and not 3)))^
    else if Hardware then
    begin
      // No memory to run from: an address error at the fetch.
      FCurrentPC := PC;
      FInDelay := FBranch;
      Fault(4, PC);
      FExcepted := False;
      Inc(Cycles);
      Continue;
    end
    else
    begin
      if Assigned(OnException) then
        OnException(4, PC);
      Break;
    end;
    // The kernel's idle loop (a jump or branch to itself with a NOP after
    // it) changes nothing until an interrupt: the time passes at once.
    if Hardware and not FBranch and (A < $00800000) and
      ((Op = ($08000000 or ((PC and $0FFFFFFF) shr 2))) or (Op = $1000FFFF)) and
      (PCardinal(FRAM + ((A + 4) and (PS2IOPRAMMask and not 3)))^ = 0) then
    begin
      Inc(SpinCycles, Target - Cycles);
      Cycles := Target;
      Break;
    end;
    if Hardware and ((PC and 3) <> 0) then
    begin
      FCurrentPC := PC;
      FInDelay := FBranch;
      Fault(4, PC);
      FExcepted := False;
      Inc(Cycles);
      Continue;
    end;
    FCurrentPC := PC;
    FInDelay := FBranch;
    FBranch := False;
    PC := NextPC;
    NextPC := Add32(PC, 4);
    FExcepted := False;
    IOPMain[Op shr 26](Self, Op);
    if FExcepted then
    begin
      // The faulting instruction does not complete; the exception already
      // landed the previous load.
      FExcepted := False;
      Inc(Cycles);
      Inc(Instructions);
      Continue;
    end;
    // The previous load lands after this instruction read its operands.
    if FDelayReg <> 0 then
      R[FDelayReg] := FDelayValue;
    FDelayReg := FLoadReg;
    FDelayValue := FLoadValue;
    FLoadReg := 0;
    Inc(Cycles);
    Inc(Instructions);
  end;
end;

procedure TIOPCPU.SerializeState(State: TStateArchive);
begin
  if FDelayReg <> 0 then
  begin
    R[FDelayReg] := FDelayValue;
    FDelayReg := 0;
  end;
  State.Field(R, SizeOf(R));
  State.Field(HI, SizeOf(HI));
  State.Field(LO, SizeOf(LO));
  State.Field(PC, SizeOf(PC));
  State.Field(NextPC, SizeOf(NextPC));
  State.Field(SR, SizeOf(SR));
  State.Field(Cause, SizeOf(Cause));
  State.Field(EPC, SizeOf(EPC));
  State.Field(Cycles, SizeOf(Cycles));
  State.Field(FBranch, SizeOf(FBranch));
  State.Field(Scratchpad, SizeOf(Scratchpad));
end;

initialization
  InitIOPOps;

end.
