program VUFloatTest;

// Compares the four-field PS2 float routines with the one-field ones on
// random and edge-case operands, and times both.

{$APPTYPE CONSOLE}
// The random generator wraps on purpose (the units under test keep their own checks).
{$Q-}{$R-}

uses
  System.SysUtils, System.Diagnostics, PS2.Types, PS2.EE.CPU, PS2.VU.Float;

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
    Check;
    Time;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
