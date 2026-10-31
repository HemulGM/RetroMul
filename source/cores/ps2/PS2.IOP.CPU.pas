unit PS2.IOP.CPU;

// The IOP's R3000A-compatible core for IOP modules (IRX) running under the
// high-level IOP kernel: a plain interpreter with branch and load delay
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
    procedure Execute(Op: Cardinal);
    procedure ExecuteSpecial(Op: Cardinal);
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

procedure TIOPCPU.ExecuteSpecial(Op: Cardinal);
begin
  var Rs := (Op shr 21) and 31;
  var Rt := (Op shr 16) and 31;
  var Rd := (Op shr 11) and 31;
  var Sa := (Op shr 6) and 31;
  case Op and 63 of
    $00: SetR(Rd, R[Rt] shl Sa);
    $02: SetR(Rd, R[Rt] shr Sa);
    $03: SetR(Rd, Sar32(R[Rt], Sa));
    $04: SetR(Rd, R[Rt] shl (R[Rs] and 31));
    $06: SetR(Rd, R[Rt] shr (R[Rs] and 31));
    $07: SetR(Rd, Sar32(R[Rt], R[Rs] and 31));
    $08: Jump(R[Rs]);
    $09:
      begin
        var Target := R[Rs];
        SetR(Rd, Add32(FCurrentPC, 8));
        Jump(Target);
      end;
    $0C:
      if Hardware then
        Enter(8, FCurrentPC, FInDelay)
      else if Assigned(OnException) then
        OnException(8, FCurrentPC);
    $0D:
      if Hardware then
        Enter(9, FCurrentPC, FInDelay)
      else if Assigned(OnException) then
        OnException(9, FCurrentPC);
    $10: SetR(Rd, HI);
    $11: HI := R[Rs];
    $12: SetR(Rd, LO);
    $13: LO := R[Rs];
    $18:
      begin
        var P := Int64(Integer(R[Rs])) * Int64(Integer(R[Rt]));
        LO := Cardinal(P and $FFFFFFFF);
        HI := Cardinal((P shr 32) and $FFFFFFFF);
      end;
    $19:
      begin
        var P := UInt64(R[Rs]) * UInt64(R[Rt]);
        LO := Cardinal(P and $FFFFFFFF);
        HI := Cardinal(P shr 32);
      end;
    $1A:
      begin
        var N := Integer(R[Rs]);
        var D := Integer(R[Rt]);
        if D = 0 then
        begin
          HI := Cardinal(N);
          if N >= 0 then
            LO := $FFFFFFFF
          else
            LO := 1;
        end
        else if (Cardinal(N) = $80000000) and (D = -1) then
        begin
          LO := $80000000;
          HI := 0;
        end
        else
        begin
          LO := Cardinal(N div D);
          HI := Cardinal(N mod D);
        end;
      end;
    $1B:
      begin
        var N := R[Rs];
        var D := R[Rt];
        if D = 0 then
        begin
          LO := $FFFFFFFF;
          HI := N;
        end
        else
        begin
          LO := N div D;
          HI := N mod D;
        end;
      end;
    $20:
      if Hardware and AddOverflows(R[Rs], R[Rt]) then
        Enter(12, FCurrentPC, FInDelay)
      else
        SetR(Rd, Add32(R[Rs], R[Rt]));
    $21: SetR(Rd, Add32(R[Rs], R[Rt]));
    $22:
      if Hardware and SubOverflows(R[Rs], R[Rt]) then
        Enter(12, FCurrentPC, FInDelay)
      else
        SetR(Rd, Sub32(R[Rs], R[Rt]));
    $23: SetR(Rd, Sub32(R[Rs], R[Rt]));
    $24: SetR(Rd, R[Rs] and R[Rt]);
    $25: SetR(Rd, R[Rs] or R[Rt]);
    $26: SetR(Rd, R[Rs] xor R[Rt]);
    $27: SetR(Rd, not (R[Rs] or R[Rt]));
    $2A: SetR(Rd, Ord(Integer(R[Rs]) < Integer(R[Rt])));
    $2B: SetR(Rd, Ord(R[Rs] < R[Rt]));
  else
    if Hardware then
      Enter(10, FCurrentPC, FInDelay)
    else if Assigned(OnException) then
      OnException(10, FCurrentPC);
  end;
end;

procedure TIOPCPU.Execute(Op: Cardinal);
begin
  var Rs := (Op shr 21) and 31;
  var Rt := (Op shr 16) and 31;
  var Imm := Op and $FFFF;
  var SImm := SX16To32(Imm);
  case Op shr 26 of
    $00: ExecuteSpecial(Op);
    $01:
      begin
        var Taken: Boolean;
        if (Rt and 1) = 0 then
          Taken := Integer(R[Rs]) < 0
        else
          Taken := Integer(R[Rs]) >= 0;
        // BLTZAL/BGEZAL link even when not taken.
        if (Rt and $1E) = $10 then
          SetR(31, Add32(FCurrentPC, 8));
        if Taken then
          Jump(Add32(Add32(FCurrentPC, 4), SImm shl 2));
      end;
    $02: Jump((Add32(FCurrentPC, 4) and $F0000000) or ((Op and $3FFFFFF) shl 2));
    $03:
      begin
        SetR(31, Add32(FCurrentPC, 8));
        Jump((Add32(FCurrentPC, 4) and $F0000000) or ((Op and $3FFFFFF) shl 2));
      end;
    $04: if R[Rs] = R[Rt] then Jump(Add32(Add32(FCurrentPC, 4), SImm shl 2));
    $05: if R[Rs] <> R[Rt] then Jump(Add32(Add32(FCurrentPC, 4), SImm shl 2));
    $06: if Integer(R[Rs]) <= 0 then Jump(Add32(Add32(FCurrentPC, 4), SImm shl 2));
    $07: if Integer(R[Rs]) > 0 then Jump(Add32(Add32(FCurrentPC, 4), SImm shl 2));
    $08:
      if Hardware and AddOverflows(R[Rs], SImm) then
        Enter(12, FCurrentPC, FInDelay)
      else
        SetR(Rt, Add32(R[Rs], SImm));
    $09: SetR(Rt, Add32(R[Rs], SImm));
    $0A: SetR(Rt, Ord(Integer(R[Rs]) < Integer(SImm)));
    $0B: SetR(Rt, Ord(R[Rs] < SImm));
    $0C: SetR(Rt, R[Rs] and Imm);
    $0D: SetR(Rt, R[Rs] or Imm);
    $0E: SetR(Rt, R[Rs] xor Imm);
    $0F: SetR(Rt, Imm shl 16);
    $10:
      begin
        // COP0: MFC0, MTC0, RFE.
        var Rd := (Op shr 11) and 31;
        case Rs of
          0:
            case Rd of
              3, 5, 6, 7, 9, 11: LoadDelayed(Rt, Debug[Rd]);
              8: LoadDelayed(Rt, BadVAddr);
              12: LoadDelayed(Rt, SR);
              13: LoadDelayed(Rt, Cause or (Cardinal(Ord(IntLine and Hardware)) shl 10));
              14: LoadDelayed(Rt, EPC);
              15: LoadDelayed(Rt, $1F);
            else
              LoadDelayed(Rt, 0);
            end;
          4:
            case Rd of
              3, 5, 6, 7, 9, 11: Debug[Rd] := R[Rt];
              12: SR := R[Rt];
              13: Cause := (Cause and not $300) or (R[Rt] and $300);
              14: EPC := R[Rt];
            end;
          16:
            if (Op and 63) = $10 then
              SR := (SR and not $F) or ((SR shr 2) and $F);
        end;
      end;
    $20: LoadDelayed(Rt, Cardinal(Integer(ShortInt(Byte(ReadMem(Add32(R[Rs], SImm), 1))))));
    $21:
      if Hardware and Misaligned(Add32(R[Rs], SImm), 1, 4) then
      else
        LoadDelayed(Rt, SX16To32(ReadMem(Add32(R[Rs], SImm) and not 1, 2)));
    $22, $26:
      begin
        // LWL/LWR merge with a value still in the load delay slot.
        var A := Add32(R[Rs], SImm);
        var Cur := R[Rt];
        if FDelayReg = Integer(Rt) then
          Cur := FDelayValue;
        var W := ReadMem(A and not 3, 4);
        var Sh := (A and 3) * 8;
        var V: Cardinal;
        if (Op shr 26) = $22 then
          V := (Cur and ($00FFFFFF shr Sh)) or (W shl (24 - Sh))
        else
          V := (Cur and not ($FFFFFFFF shr Sh)) or (W shr Sh);
        LoadDelayed(Rt, V);
      end;
    $23:
      if Hardware and Misaligned(Add32(R[Rs], SImm), 3, 4) then
      else
        LoadDelayed(Rt, ReadMem(Add32(R[Rs], SImm) and not 3, 4));
    $24: LoadDelayed(Rt, ReadMem(Add32(R[Rs], SImm), 1));
    $25:
      if Hardware and Misaligned(Add32(R[Rs], SImm), 1, 4) then
      else
        LoadDelayed(Rt, ReadMem(Add32(R[Rs], SImm) and not 1, 2));
    $28: WriteMem(Add32(R[Rs], SImm), R[Rt] and $FF, 1);
    $29:
      if Hardware and Misaligned(Add32(R[Rs], SImm), 1, 5) then
      else
        WriteMem(Add32(R[Rs], SImm) and not 1, R[Rt] and $FFFF, 2);
    $2A, $2E:
      begin
        var A := Add32(R[Rs], SImm);
        var W := ReadMem(A and not 3, 4);
        var Sh := (A and 3) * 8;
        if (Op shr 26) = $2A then
          W := (W and not ($FFFFFFFF shr (24 - Sh))) or (R[Rt] shr (24 - Sh))
        else
          W := (W and not ($FFFFFFFF shl Sh)) or (R[Rt] shl Sh);
        WriteMem(A and not 3, W, 4);
      end;
    $2B:
      if Hardware and Misaligned(Add32(R[Rs], SImm), 3, 5) then
      else
        WriteMem(Add32(R[Rs], SImm) and not 3, R[Rt], 4);
    IOPTrapOpcode:
      if Assigned(OnTrap) then
        OnTrap(Op and $3FFFFFF);
  else
    // COP2 and the rest: not present on the IOP.
    if Hardware then
      Enter(10, FCurrentPC, FInDelay)
    else if Assigned(OnException) then
      OnException(10, FCurrentPC);
  end;
end;

procedure TIOPCPU.Run(Target: Int64);
begin
  FStop := False;
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
    Execute(Op);
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

end.
