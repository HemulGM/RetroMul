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

begin
  try
    var Bus := TTestBus.Create;
    var Cop2 := TEECop2.Create;
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
