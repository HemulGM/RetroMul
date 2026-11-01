program VUFloatTest;

// Compares the four-field PS2 float routines with the one-field ones on
// random and edge-case operands, and times both.

{$APPTYPE CONSOLE}
// The random generator wraps on purpose (the units under test keep their own checks).
{$Q-}{$R-}

uses
  System.SysUtils, System.Diagnostics, System.Math, PS2.Types, PS2.EE.CPU, PS2.VU.Float;

var
  Seed: UInt64 = $123456789ABCDEF;

function Rnd: Cardinal;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 7);
  Seed := Seed xor (Seed shl 17);
  Result := Cardinal(Seed);
end;

// Random floats biased to interesting exponents and close magnitudes.
function RndFloat(Other: Cardinal): Cardinal;
begin
  var Mode := Rnd mod 10;
  case Mode of
    0: Result := Rnd and $807FFFFF;                       // exponent 0
    1: Result := (Rnd and $807FFFFF) or $7F800000;        // exponent 255
    2: Result := (Rnd and $80FFFFFF) or $00800000;        // tiny
    3: Result := Other xor (Rnd and $80000003);           // nearly equal
    4: Result := (Other and $FF800000) or (Rnd and $7FFFFF); // same exponent
    5: Result := (Other + ((Rnd mod 64) shl 23)) xor (Rnd and $80000000); // nearby exponents
    6: Result := (Other - ((Rnd mod 30) shl 23)) xor (Rnd and $80000000);
  else
    Result := Rnd;
  end;
end;

procedure Check;
var
  A, B, R: TPS2Reg128;
  F: Cardinal;
begin
  var Errors := 0;
  for var N := 1 to 5000000 do
  begin
    for var K := 0 to 3 do
    begin
      A.UW[K] := RndFloat(Rnd);
      B.UW[K] := RndFloat(A.UW[K]);
    end;
    PS2Mul4(A, B, R, F);
    if N mod 1024 = 0 then
    begin
      var Alias := A;
      var AF: Cardinal;
      PS2Mul4(Alias, B, Alias, AF);
      if not CompareMem(@Alias, @R, SizeOf(R)) or (AF <> F) then
        raise Exception.Create('In-place product mismatch');
    end;
    for var K := 0 to 3 do
    begin
      var SF: Cardinal;
      var S := PS2FloatMul(A.UW[K], B.UW[K], SF);
      var Want := ((SF and 1) shl K) or (((SF shr 1) and 1) shl (K + 4));
      if (S <> R.UW[K]) or (Want <> (F and ((Cardinal(1) shl K) or (Cardinal(16) shl K)))) then
      begin
        Inc(Errors);
        if Errors < 20 then
          Writeln(Format('MUL %.8x * %.8x: scalar %.8x f%d, four %.8x f%x', [A.UW[K], B.UW[K], S, SF, R.UW[K], F]));
      end;
    end;
    PS2Add4(A, B, R, F);
    if N mod 1024 = 0 then
    begin
      var Alias := B;
      var AF: Cardinal;
      PS2Add4(A, Alias, Alias, AF);
      if not CompareMem(@Alias, @R, SizeOf(R)) or (AF <> F) then
        raise Exception.Create('In-place sum mismatch');
    end;
    for var K := 0 to 3 do
    begin
      var SF: Cardinal;
      var S := PS2FloatAdd(A.UW[K], B.UW[K], SF);
      var Want := ((SF and 1) shl K) or (((SF shr 1) and 1) shl (K + 4));
      if (S <> R.UW[K]) or (Want <> (F and ((Cardinal(1) shl K) or (Cardinal(16) shl K)))) then
      begin
        Inc(Errors);
        if Errors < 40 then
          Writeln(Format('ADD %.8x + %.8x: scalar %.8x f%d, four %.8x f%x', [A.UW[K], B.UW[K], S, SF, R.UW[K], F]));
      end;
    end;
  end;
  Writeln('errors: ', Errors);
  if Errors > 0 then
    ExitCode := 1;
end;

procedure CheckConversions;
const
  Shifts: array[0..3] of Integer = (0, 4, 12, 15);
  Mantissas: array[0..5] of Cardinal = (0, 1, 3, $3FFFFF, $7FFFFE, $7FFFFF);
var
  A, B: TPS2Reg128;

  procedure Vector;
  var
    ExpectedI, ExpectedF, ActualI, ActualF: TPS2Reg128;
    Raw: array[0..63] of Byte;
  begin
    for var Shift in Shifts do
    begin
      var Scale: Double := Cardinal(1) shl Shift;
      for var K := 0 to 3 do
      begin
        var F: Single := A.SW[K] * (1 / Scale);
        ExpectedI.UW[K] := PCardinal(@F)^;
        var D := EEFloatIn(A.UW[K]) * Scale;
        if D >= 2147483647.0 then ExpectedF.UW[K] := $7FFFFFFF
        else if D <= -2147483648.0 then ExpectedF.UW[K] := $80000000
        else ExpectedF.SW[K] := Trunc(D);
      end;
      PS2Itof4(A, Shift, ActualI);
      PS2Ftoi4(A, Shift, ActualF);
      if not CompareMem(@ExpectedI, @ActualI, SizeOf(ActualI)) or
        not CompareMem(@ExpectedF, @ActualF, SizeOf(ActualF)) then
        raise Exception.CreateFmt('Fixed conversion mismatch shift=%d input=%.8x,%.8x,%.8x,%.8x',
          [Shift, A.UW[0], A.UW[1], A.UW[2], A.UW[3]]);
      if A.UW[0] and 255 = 0 then
      begin
        var Alias := A;
        PS2Itof4(Alias, Shift, Alias);
        if not CompareMem(@Alias, @ExpectedI, SizeOf(Alias)) then raise Exception.Create('ITOF alias mismatch');
        Alias := A;
        PS2Ftoi4(Alias, Shift, Alias);
        if not CompareMem(@Alias, @ExpectedF, SizeOf(Alias)) then raise Exception.Create('FTOI alias mismatch');
        Move(A, Raw[1], SizeOf(A));
        PS2Itof4(PPS2Reg128(@Raw[1])^, Shift, PPS2Reg128(@Raw[19])^);
        if not CompareMem(@Raw[19], @ExpectedI, SizeOf(ExpectedI)) then raise Exception.Create('ITOF unaligned mismatch');
        PS2Ftoi4(PPS2Reg128(@Raw[1])^, Shift, PPS2Reg128(@Raw[19])^);
        if not CompareMem(@Raw[19], @ExpectedF, SizeOf(ExpectedF)) then raise Exception.Create('FTOI unaligned mismatch');
      end;
    end;
    var W := Abs(EEFloatIn(B.UW[3]));
    var Expected: Cardinal := 0;
    for var K := 0 to 2 do
    begin
      var V := EEFloatIn(A.UW[K]);
      if V > W then Expected := Expected or (Cardinal(1) shl (K * 2));
      if V < -W then Expected := Expected or (Cardinal(2) shl (K * 2));
    end;
    var Actual: Cardinal;
    PS2Clip3(A, B, Actual);
    if Actual <> Expected then raise Exception.Create('Integer CLIP comparison mismatch');
  end;

begin
  for var E := 0 to 255 do
    for var M in Mantissas do
    begin
      A.UW[0] := (Cardinal(E) shl 23) or M;
      A.UW[1] := A.UW[0] xor $80000000;
      A.UW[2] := A.UW[0] + 1;
      A.UW[3] := A.UW[1] xor $7FFFFF;
      B := A;
      B.UW[3] := A.UW[0];
      Vector;
      B.UW[3] := A.UW[0] - 1;
      Vector;
    end;
  for var N := 0 to 99999 do
  begin
    for var K := 0 to 3 do begin A.UW[K] := Rnd; B.UW[K] := Rnd; end;
    if N mod 4 = 0 then B.UW[3] := A.UW[N mod 3];
    Vector;
  end;
  Writeln('ITOF/FTOI0/4/12/15 and CLIP: scalar results, saturation, exponent edges, alias/unaligned OK');
end;

procedure Directed;
const
  Mantissas: array[0..5] of Cardinal = (0, 1, 3, $3FFFFF, $7FFFFE, $7FFFFF);
var
  A, B, R: TPS2Reg128;
begin
  // All exponent pairs, near normalization/carry/cancellation boundaries.
  for var EA := 0 to 255 do
    for var EB := 0 to 255 do
      for var Mantissa in Mantissas do
      begin
        A.UW[0] := (Cardinal(EA) shl 23) or Mantissa;
        B.UW[0] := (Cardinal(EB) shl 23) or $7FFFFF;
        A.UW[1] := A.UW[0] or $80000000;
        B.UW[1] := B.UW[0] or $80000000;
        A.UW[2] := A.UW[0];
        B.UW[2] := B.UW[1];
        A.UW[3] := A.UW[1];
        B.UW[3] := B.UW[0];
        var Flags: Cardinal;
        PS2Add4(A, B, R, Flags);
        for var K := 0 to 3 do
        begin
          var SF: Cardinal;
          var Want := PS2FloatAdd(A.UW[K], B.UW[K], SF);
          var F := ((SF and 1) shl K) or (((SF shr 1) and 1) shl (K + 4));
          if (R.UW[K] <> Want) or ((Flags and ((Cardinal(17) shl K))) <> F) then
            raise Exception.CreateFmt('Directed ADD %.8x + %.8x: %.8x <> %.8x',
              [A.UW[K], B.UW[K], R.UW[K], Want]);
        end;
        PS2Mul4(A, B, R, Flags);
        for var K := 0 to 3 do
        begin
          var SF: Cardinal;
          var Want := PS2FloatMul(A.UW[K], B.UW[K], SF);
          var F := ((SF and 1) shl K) or (((SF shr 1) and 1) shl (K + 4));
          if (R.UW[K] <> Want) or ((Flags and (Cardinal(17) shl K)) <> F) then
            raise Exception.Create('Directed product/flags mismatch');
        end;
      end;
  Writeln('all exponent pairs, carry/cancellation boundaries: OK');
end;

procedure Time;
var
  A, B, R: TPS2Reg128;
  F: Cardinal;
begin
  for var K := 0 to 3 do
  begin
    A.UW[K] := $3F800000 + Rnd mod $1000000;
    B.UW[K] := $3F000000 + Rnd mod $1000000;
  end;
  var W := TStopwatch.StartNew;
  for var N := 1 to 10000000 do
  begin
    PS2Add4(A, B, R, F);
    A.UW[0] := A.UW[0] xor (R.UW[1] and 1);
  end;
  Writeln(Format('add4 %.1f ns', [W.Elapsed.TotalMilliseconds * 1E6 / 1E7]));
  W := TStopwatch.StartNew;
  for var N := 1 to 10000000 do
  begin
    PS2Mul4(A, B, R, F);
    A.UW[0] := A.UW[0] xor (R.UW[1] and 1);
  end;
  Writeln(Format('mul4 %.1f ns', [W.Elapsed.TotalMilliseconds * 1E6 / 1E7]));
  W := TStopwatch.StartNew;
  for var N := 1 to 10000000 do
  begin
    for var K := 0 to 3 do
      R.UW[K] := PS2FloatAdd(A.UW[K], B.UW[K], F);
    A.UW[0] := A.UW[0] xor (R.UW[1] and 1);
  end;
  Writeln(Format('add x4 scalar %.1f ns', [W.Elapsed.TotalMilliseconds * 1E6 / 1E7]));
  W := TStopwatch.StartNew;
  for var N := 1 to 10000000 do
  begin
    for var K := 0 to 3 do
      R.UW[K] := PS2FloatMul(A.UW[K], B.UW[K], F);
    A.UW[0] := A.UW[0] xor (R.UW[1] and 1);
  end;
  Writeln(Format('mul x4 scalar %.1f ns', [W.Elapsed.TotalMilliseconds * 1E6 / 1E7]));
end;

begin
  try
    SetExceptionMask(exAllArithmeticExceptions);
    Writeln('AVX2 backend=', PS2VectorAVX2);
    var ConversionOnly := FindCmdLineSwitch('conversionsonly');
    for var Mode := Low(TRoundingMode) to High(TRoundingMode) do
    begin
      SetRoundMode(Mode);
      Writeln('rounding=', Ord(Mode));
      CheckConversions;
      if not ConversionOnly then begin Check; Directed; end;
    end;
    if PS2VectorAVX2 or ConversionOnly then
    begin
      // The common hardware path must also agree with denormal-input and
      // flush-to-zero host modes: PS2 operands are sanitized explicitly.
      for var Mode in [rmTruncate, rmNearest] do
      begin
        SetRoundMode(Mode);
        var Saved := GetMXCSR;
        try
          SetMXCSR(Saved or $8040);
          Writeln('rounding=', Ord(Mode), ' FTZ/DAZ enabled');
          CheckConversions;
          if not ConversionOnly then begin Check; Directed; end;
        finally
          SetMXCSR(Saved);
        end;
      end;
    end;
    SetRoundMode(rmTruncate);
    if not ConversionOnly then Time;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
