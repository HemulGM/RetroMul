program PS2EEMMITest;

// Runs every EE multimedia instruction that has a whole-register kernel
// (EEMMIKernel) on random registers, with every shift amount and with
// sources and destination aliased, through the general handlers, the
// kernels and the recompiler, and compares the registers, HI, LO and SA.

{$APPTYPE CONSOLE}
{$Q-}{$R-} // The random generator wraps on purpose.

uses
  System.SysUtils, PS2.Types, PS2.EE.CPU;

type
  // 64 KiB of RAM at physical address 0, nothing else.
  TTestBus = class(TEEBus)
  public
    RAM: array[0..65535] of Byte;
    Gens: array[0..15] of Cardinal;
    function Read(Address: Cardinal; Size: Integer): UInt64; override;
    procedure Write(Address: Cardinal; Value: UInt64; Size: Integer); override;
    function PagePointer(Page: Cardinal; Writing: Boolean): PByte; override;
    function PageGeneration(Page: Cardinal): PCardinal; override;
  end;

function TTestBus.Read(Address: Cardinal; Size: Integer): UInt64;
begin
  Result := 0;
end;

procedure TTestBus.Write(Address: Cardinal; Value: UInt64; Size: Integer);
begin
end;

function TTestBus.PagePointer(Page: Cardinal; Writing: Boolean): PByte;
begin
  Result := nil;
  if Page < 16 then
    Result := @RAM[Page * 4096];
end;

function TTestBus.PageGeneration(Page: Cardinal): PCardinal;
begin
  Result := @Gens[Page and 15];
end;

var
  Seed: UInt64 = $9E3779B97F4A7C15;

function Rnd: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 7);
  Seed := Seed xor (Seed shl 17);
  Result := Cardinal(Seed);
end;

// Words with edge values in some lanes (saturation, sign, equal lanes).
function RndWord(Other: Cardinal): Cardinal;
begin
  case Rnd mod 8 of
    0: Result := $80008000;
    1: Result := $7FFF7FFF;
    2: Result := Other;
    3: Result := $FFFFFFFF;
    4: Result := Rnd and $80FF80FF;
  else
    Result := Rnd;
  end;
end;

type
  TSnapshot = record
    GPR: array[0..31] of TPS2Reg128;
    HI, LO: TPS2Reg128;
    SA: Cardinal;
  end;

var
  Now, Deadline: Int64;

type
  // VU0 idle: the recompiler writes the coprocessor transfers out.
  TTestCop2 = class(TEECop2)
  public
    Running: Boolean;
    function RunningFlag: PBoolean; override;
  end;

function TTestCop2.RunningFlag: PBoolean;
begin
  Result := @Running;
end;

type
  TState = record
    GPR: array[0..31] of TPS2Reg128;
    FPR: array[0..31] of Cardinal;
    VF: array[0..31] of TPS2Reg128;
    PC: Cardinal;
    RAM: array[0..8191] of Byte;
  end;

// Op at 80000000h (then a branch to itself), from Start, by the handlers or
// the recompiler: the registers, coprocessor registers, PC and RAM after.
procedure RunState(CPU: TEECPU; Bus: TTestBus; Cop2: TEECop2; Op: Cardinal; const Start: TState; Jit: Boolean;
  out Result: TState);
begin
  Move(Start.RAM, Bus.RAM[4096], SizeOf(Start.RAM));
  PCardinal(@Bus.RAM[0])^ := Op;
  PCardinal(@Bus.RAM[4])^ := $1000FFFF;
  PCardinal(@Bus.RAM[8])^ := 0;
  Inc(Bus.Gens[0]);
  CPU.UseJit := Jit;
  CPU.JitHeat := 1;
  CPU.InvalidateBlocks;
  for var K := 0 to 31 do
  begin
    CPU.S.GPR[K] := Start.GPR[K];
    CPU.S.FPR[K] := Start.FPR[K];
    Cop2.VF[K] := Start.VF[K];
  end;
  CPU.SetPC($80000000);
  Now := 0;
  Deadline := 1;
  CPU.Run;
  FillChar(Result, SizeOf(Result), 0);
  for var K := 0 to 31 do
  begin
    Result.GPR[K] := CPU.S.GPR[K];
    Result.FPR[K] := CPU.S.FPR[K];
    Result.VF[K] := Cop2.VF[K];
  end;
  Result.PC := CPU.S.PC;
  Move(Bus.RAM[4096], Result.RAM, SizeOf(Result.RAM));
end;

// The loads, stores and register moves the recompiler writes out (halfwords,
// ADDI, COP1 words, COP2 quadwords and QMFC2/QMTC2) against their handlers:
// aligned and not, overflowing, register 0 and aliases.
procedure CheckTransfers(CPU: TEECPU; Bus: TTestBus; Cop2: TEECop2);
const
  // LH, LHU, SH, ADDI, LWC1, SWC1, LQC2, SQC2 (opcode in the top 6 bits).
  Majors: array[0..7] of Cardinal = ($21, $25, $29, $08, $31, $39, $36, $3E);
begin
  var Runs := 0;
  for var Trial := 0 to 23999 do
  begin
    var Kind := Trial mod 12;
    var Rs := Rnd mod 32;
    var Rt := Rnd mod 32;
    var Rd := Rnd mod 32;
    if Trial mod 7 = 0 then Rt := Rs;
    if Trial mod 11 = 0 then Rt := 0;
    var Op: Cardinal;
    case Kind of
      0..7: Op := (Majors[Kind] shl 26) or Cardinal(Rs shl 21) or Cardinal(Rt shl 16) or (Rnd and $FFFF);
      8: Op := $44000000 or Cardinal(Rt shl 16) or Cardinal(Rd shl 11); // MFC1
      9: Op := $44800000 or Cardinal(Rt shl 16) or Cardinal(Rd shl 11); // MTC1
      10: Op := $48200000 or Cardinal(Rt shl 16) or Cardinal(Rd shl 11) or (Rnd and 1); // QMFC2
    else
      Op := $48A00000 or Cardinal(Rt shl 16) or Cardinal(Rd shl 11) or (Rnd and 1); // QMTC2
    end;
    var Start: TState;
    for var K := 0 to 31 do
    begin
      for var W := 0 to 3 do
      begin
        Start.GPR[K].UW[W] := RndWord(Rnd);
        Start.VF[K].UW[W] := Rnd;
      end;
      Start.FPR[K] := Rnd;
    end;
    Start.GPR[0] := Default(TPS2Reg128);
    // The base in the 8 KiB at 80001000h (sometimes far outside it), the
    // offset small; ADDI's operands near the 32-bit limits.
    if Kind < 8 then
    begin
      var Offset := Integer(Smallint(Op and $FFFF));
      if Kind = 3 then
        Start.GPR[Rs].Lo := UInt64(Int64(Integer(Rnd or Cardinal(Ord(Odd(Rnd)) shl 31))))
      else if Rnd mod 16 <> 0 then
      begin
        Op := (Op and $FFFF0000) or Cardinal(Word(Smallint(Integer(Rnd mod 64) - 32)));
        Offset := Integer(Smallint(Op and $FFFF));
        Start.GPR[Rs].Lo := UInt64(Int64(Integer($80001000 + Rnd mod 8000 - Offset + Rnd mod 33 - 16)));
      end;
    end;
    for var K := 0 to High(Start.RAM) do Start.RAM[K] := Byte(Rnd);
    var Expected, Got: TState;
    RunState(CPU, Bus, Cop2, Op, Start, False, Expected);
    RunState(CPU, Bus, Cop2, Op, Start, True, Got);
    if not CompareMem(@Got, @Expected, SizeOf(Got)) then
      raise Exception.CreateFmt('Recompiled transfer mismatch op=%.8x rs=%.16x', [Op, Start.GPR[Rs].Lo]);
    Inc(Runs);
  end;
  if CPU.JitCompiles = 0 then raise Exception.Create('Transfers not recompiled');
  Writeln(Format('%d halfword, ADDI, COP1 and COP2 transfers (recompiler) match the handlers', [Runs]));
end;

function RunOne(CPU: TEECPU; Bus: TTestBus; Op: Cardinal; const Start: TSnapshot; Kernels, Jit: Boolean): TSnapshot;
begin
  // The instruction, then a branch to itself and its delay slot.
  PCardinal(@Bus.RAM[0])^ := Op;
  PCardinal(@Bus.RAM[4])^ := $1000FFFF;
  PCardinal(@Bus.RAM[8])^ := 0;
  Inc(Bus.Gens[0]);
  CPU.MMIKernels := Kernels;
  CPU.UseJit := Jit;
  CPU.JitHeat := 1;
  CPU.InvalidateBlocks;
  for var K := 0 to 31 do
    CPU.S.GPR[K] := Start.GPR[K];
  CPU.S.HI := Start.HI;
  CPU.S.LO := Start.LO;
  CPU.S.SA := Start.SA;
  CPU.SetPC($80000000);
  Now := 0;
  Deadline := 1;
  CPU.Run;
  // (Padding too: snapshots are compared whole.)
  FillChar(Result, SizeOf(Result), 0);
  for var K := 0 to 31 do
    Result.GPR[K] := CPU.S.GPR[K];
  Result.HI := CPU.S.HI;
  Result.LO := CPU.S.LO;
  Result.SA := CPU.S.SA;
end;

// Random straight-line blocks over a few registers (values passed from one
// instruction to the next, handler calls between): integer arithmetic, logic, shifts, moves,
// aligned loads and stores, multimedia kernels, COP2 transfers and handler
// instructions (MULT, DIV) between them; registers, RAM and VU0 registers
// after the block against the handlers.
procedure CheckBlocks(CPU: TEECPU; Bus: TTestBus; Cop2: TEECop2);
const
  // SPECIAL functs (rd, rs, rt): ADDU SUBU DADDU DSUBU AND OR XOR NOR SLT SLTU MOVZ MOVN MULT DIV.
  Specials: array[0..13] of Cardinal = ($21, $23, $2D, $2F, $24, $25, $26, $27, $2A, $2B, $0A, $0B, $18, $1A);
  // Immediate ops (rt, rs, imm): ADDIU DADDIU SLTI SLTIU ANDI ORI XORI LUI.
  Immediates: array[0..7] of Cardinal = ($09, $19, $0A, $0B, $0C, $0D, $0E, $0F);
  // Loads and stores with their alignment: LB LBU LH LHU LW LWU LD LQ SB SH SW SD SQ.
  Memory: array[0..12] of Cardinal = ($20, $24, $21, $25, $23, $27, $37, $1E, $28, $29, $2B, $3F, $1F);
  Align: array[0..12] of Cardinal = (1, 1, 2, 2, 4, 4, 8, 16, 1, 2, 4, 8, 16);
  // SLL SRL SRA DSLL DSRL DSRA.
  Shifts: array[0..5] of Cardinal = ($00, $02, $03, $38, $3A, $3B);
begin
  var Runs := 0;
  for var Trial := 0 to 5999 do
  begin
    var Count := 4 + Rnd mod 20;
    // Registers 1..6 (and 7, the base: 80001000h).
    var R := function: Cardinal begin Result := 1 + Rnd mod 6; end;
    for var K := 0 to Count - 1 do
    begin
      var Op: Cardinal;
      case Rnd mod 9 of
        0, 1, 2: Op := Specials[Rnd mod 14] or (R() shl 21) or (R() shl 16) or (R() shl 11);
        3: Op := (R() shl 16) or (R() shl 11) or ((Rnd mod 32) shl 6) or Shifts[Rnd mod 6];
        4, 5: Op := (Immediates[Rnd mod 8] shl 26) or (R() shl 21) or (R() shl 16) or (Rnd and $FFFF);
        6, 7:
          begin
            var M := Rnd mod 13;
            Op := (Memory[M] shl 26) or (7 shl 21) or (R() shl 16) or ((Rnd mod 256) * Align[M]);
          end;
      else
        case Rnd mod 3 of
          0: Op := $70000000 or (R() shl 21) or (R() shl 16) or (R() shl 11) or ($12 shl 6) or $09; // PAND
          1: Op := $48200000 or (R() shl 16) or ((1 + Rnd mod 31) shl 11); // QMFC2
        else
          Op := $48A00000 or (R() shl 16) or ((1 + Rnd mod 31) shl 11); // QMTC2
        end;
      end;
      PCardinal(@Bus.RAM[K * 4])^ := Op;
    end;
    PCardinal(@Bus.RAM[Count * 4])^ := $1000FFFF;
    PCardinal(@Bus.RAM[Count * 4 + 4])^ := 0;
    var Start: TState;
    for var K := 0 to 31 do
    begin
      for var W := 0 to 3 do
      begin
        Start.GPR[K].UW[W] := RndWord(Rnd);
        Start.VF[K].UW[W] := Rnd;
      end;
      Start.FPR[K] := Rnd;
    end;
    Start.GPR[0] := Default(TPS2Reg128);
    Start.GPR[7].Lo := UInt64($FFFFFFFF80001000);
    for var K := 0 to High(Start.RAM) do Start.RAM[K] := Byte(Rnd);
    var Expected, Got: TState;
    for var Jit := False to True do
    begin
      Move(Start.RAM, Bus.RAM[4096], SizeOf(Start.RAM));
      Inc(Bus.Gens[0]);
      CPU.UseJit := Jit;
      CPU.JitHeat := 1;
      CPU.InvalidateBlocks;
      for var K := 0 to 31 do
      begin
        CPU.S.GPR[K] := Start.GPR[K];
        CPU.S.FPR[K] := Start.FPR[K];
        Cop2.VF[K] := Start.VF[K];
      end;
      CPU.SetPC($80000000);
      Now := 0;
      Deadline := 1;
      CPU.Run;
      var S: TState;
      FillChar(S, SizeOf(S), 0);
      for var K := 0 to 31 do
      begin
        S.GPR[K] := CPU.S.GPR[K];
        S.FPR[K] := CPU.S.FPR[K];
        S.VF[K] := Cop2.VF[K];
      end;
      S.PC := CPU.S.PC;
      Move(Bus.RAM[4096], S.RAM, SizeOf(S.RAM));
      if Jit then Got := S else Expected := S;
    end;
    if not CompareMem(@Got, @Expected, SizeOf(Got)) then
    begin
      for var K := 0 to Count - 1 do Write(IntToHex(PCardinal(@Bus.RAM[K * 4])^, 8), ' ');
      Writeln;
      for var K := 0 to 7 do
        if Got.GPR[K].Lo <> Expected.GPR[K].Lo then
          Writeln(Format('r%d expected %.16x got %.16x', [K, Expected.GPR[K].Lo, Got.GPR[K].Lo]));
      raise Exception.CreateFmt('Recompiled block mismatch, trial %d', [Trial]);
    end;
    Inc(Runs);
  end;
  Writeln(Format('%d random blocks over few registers (recompiler) match the handlers', [Runs]));
end;

begin
  try
    var Bus := TTestBus.Create;
    var Cop2 := TTestCop2.Create;
    var CPU := TEECPU.Create(Bus, Cop2, @Now, @Deadline);
    try
      CPU.RebuildMaps;
      var Ops := 0;
      var Runs: Int64 := 0;
      var JitOK := True;
      for var Funct := 0 to 63 do
        for var Sa := 0 to 31 do
        begin
          var Base := ($1C shl 26) or Cardinal(Sa shl 6) or Cardinal(Funct);
          if not Assigned(EEMMIKernel(Base)) then
            Continue;
          Inc(Ops);
          for var Trial := 0 to 199 do
          begin
            var Rs := Rnd mod 32;
            var Rt := Rnd mod 32;
            var Rd := Rnd mod 32;
            case Trial mod 8 of
              0: Rd := Rs;
              1: Rd := Rt;
              2: Rs := Rt;
              3: Rd := 0;
            end;
            var Op := Base or (Rs shl 21) or (Rt shl 16) or (Rd shl 11);
            var Start: TSnapshot;
            for var K := 0 to 31 do
              for var W := 0 to 3 do
                Start.GPR[K].UW[W] := RndWord(Rnd);
            Start.GPR[0] := Default(TPS2Reg128);
            for var W := 0 to 3 do
            begin
              Start.HI.UW[W] := Rnd;
              Start.LO.UW[W] := Rnd;
            end;
            Start.SA := Rnd and 15;
            var Expected := RunOne(CPU, Bus, Op, Start, False, False);
            for var Mode := 0 to 1 do
            begin
              var Got := RunOne(CPU, Bus, Op, Start, True, Mode = 1);
              if (Mode = 1) and (CPU.JitCompiles = 0) then
                JitOK := False;
              if not CompareMem(@Got, @Expected, SizeOf(Got)) then
              begin
                for var K := 0 to 31 do
                  if not CompareMem(@Got.GPR[K], @Expected.GPR[K], 16) then
                    Writeln(Format('gpr%d start %.16x%.16x expected %.16x%.16x got %.16x%.16x', [K, Start.GPR[K].Hi, Start.GPR[K].Lo, Expected.GPR[K].Hi, Expected.GPR[K].Lo, Got.GPR[K].Hi, Got.GPR[K].Lo]));
                Writeln(Format('rs %d rt %d rd %d; A %.16x%.16x B %.16x%.16x', [Rs, Rt, Rd, Start.GPR[Rs].Hi, Start.GPR[Rs].Lo, Start.GPR[Rt].Hi, Start.GPR[Rt].Lo]));
                raise Exception.CreateFmt('MMI kernel mismatch op=%.8x (funct %.2x sa %d) jit=%d', [Op, Funct, Sa, Mode]);
              end;
              Inc(Runs);
            end;
          end;
        end;
      if Ops = 0 then
        Writeln('no multimedia kernels on this host: nothing to compare')
      else
        Writeln(Format('%d multimedia kernel instructions, %d runs (interpreter and recompiler) match the general handlers%s',
          [Ops, Runs, Copy(' (recompiler unavailable)', 1, Ord(not JitOK) * 100)]));
      CheckTransfers(CPU, Bus, Cop2);
      CheckBlocks(CPU, Bus, Cop2);
    finally
      CPU.Free;
      Cop2.Free;
      Bus.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
