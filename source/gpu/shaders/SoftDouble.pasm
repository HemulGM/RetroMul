module SoftDouble;

// Vendored from https://github.com/Fasday/PasToSPIRV (SoftDouble library,
// revision 16a4f63). MIT license: dependencies/PasToSPIRV/LICENSE.
// Correctly rounded IEEE 754 binary64 division in integer arithmetic.
// Results are bit-identical to x86-64 SSE2 DIVSD with the default MXCSR:
// round to nearest even, subnormal inputs and results kept (no FTZ/DAZ),
// exceptions masked. NaN rules follow DIVSD: a NaN dividend wins over a NaN
// divisor and is returned quieted; 0/0 and Inf/Inf give $FFF8000000000000.
// Native GPU double division is not required to be correctly rounded.
//
// Uses UInt64: the shader's Main needs [Vulkan12] (shaderInt64; the Double
// overload also needs shaderFloat64). Does not depend on float control modes.

// A / B on the bit patterns of two binary64 values.
function SoftDivBits(A, B: UInt64): UInt64;
const
  SignMask: UInt64 = $8000000000000000;
  FractionMask: UInt64 = $000FFFFFFFFFFFFF;
  HiddenBit: UInt64 = $0010000000000000;
  QuietBit: UInt64 = $0008000000000000;
  InfinityBits: UInt64 = $7FF0000000000000;
  DefaultNaN: UInt64 = $FFF8000000000000; // x86 "real indefinite"
var
  Sign, MA, MB, Q, R, Scaled, Mant: UInt64;
  EA, EB, E, Shift, Step, K: Integer;
  Digit: Cardinal;
  Recip, Estimate: Single;
  Sticky, RoundBit: Boolean;

  // Left shift that moves the highest set bit of M (0 < M < 2^52) to bit 52.
  function NormalizeShift(M: UInt64): Integer;
  var
    Upper: Cardinal;
  begin
    Upper := Cardinal(M shr 32);
    if Upper <> 0 then
      Result := 20 - FindMSB(Upper)
    else
      Result := 52 - FindMSB(Cardinal(M));
  end;

begin
  Sign := (A xor B) and SignMask;
  EA := Integer((A shr 52) and $7FF);
  EB := Integer((B shr 52) and $7FF);
  MA := A and FractionMask;
  MB := B and FractionMask;
  if (EA = $7FF) and (MA <> 0) then
    Exit(A or QuietBit);
  if (EB = $7FF) and (MB <> 0) then
    Exit(B or QuietBit);
  if EA = $7FF then
    Exit(if EB = $7FF then DefaultNaN else Sign or InfinityBits);
  if EB = $7FF then
    Exit(Sign);
  if (EB = 0) and (MB = 0) then
    Exit(if (EA = 0) and (MA = 0) then DefaultNaN else Sign or InfinityBits);
  if (EA = 0) and (MA = 0) then
    Exit(Sign);

  // Significands in [2^52, 2^53) with unbounded exponents (subnormals normalized).
  if EA = 0 then
  begin
    Shift := NormalizeShift(MA);
    MA := MA shl Shift;
    EA := 1 - Shift;
  end
  else MA := MA or HiddenBit;
  if EB = 0 then
  begin
    Shift := NormalizeShift(MB);
    MB := MB shl Shift;
    EB := 1 - Shift;
  end
  else MB := MB or HiddenBit;
  E := EA - EB + 1023;
  if MA < MB then
  begin
    MA := MA shl 1;
    Dec(E);
  end;

  // Q = floor(MA * 2^53 / MB): 54 bits, the significand and the round bit,
  // produced as one leading bit and six digits of 9 (last 8) bits. Invariant
  // R < MB < 2^53, so R shl 9 < 2^62 and Digit * MB < 2^63: every step is exact.
  // The digit estimate R/MB * 2^K from 24-bit Single values is off by less than
  // 2^-10 (Vulkan: 2.5 ULP division, exact conversions); it is lowered by 1/256,
  // so it is never too large and at most one correction step follows. The
  // corrections keep the digit exact for any estimate in 0..2^K-1.
  Q := 1;
  R := MA - MB;
  Recip := 1.0 / Single(Cardinal(MB shr 29)); // MB shr 29 is in [2^23, 2^24)
  for Step := 0 to 5 do
  begin
    K := if Step = 5 then 8 else 9;
    Estimate := Single(Cardinal(R shr 29)) * Recip * Single(Cardinal(1) shl K) - 0.00390625;
    Digit := if Estimate > 0 then Min(Cardinal(Estimate), (Cardinal(1) shl K) - 1) else 0;
    Scaled := (R shl K) - UInt64(Digit) * MB;
    // Guard only: an estimate above the true digit would wrap below zero.
    while (Scaled and SignMask) <> 0 do
    begin
      Dec(Digit);
      Scaled := Scaled + MB;
    end;
    while Scaled >= MB do
    begin
      Inc(Digit);
      Scaled := Scaled - MB;
    end;
    R := Scaled;
    Q := (Q shl K) or UInt64(Digit);
  end;
  Sticky := R <> 0;

  // Round to nearest even; subnormal results drop further bits into the sticky bit.
  Shift := 1;
  if E <= 0 then
  begin
    Shift := 2 - E;
    E := 0;
  end;
  if Shift >= 64 then
  begin
    Mant := 0;
    RoundBit := False;
    Sticky := True;
  end
  else
  begin
    Mant := Q shr Shift;
    RoundBit := ((Q shr (Shift - 1)) and 1) <> 0;
    if (Shift >= 2) and ((Q and ((UInt64(1) shl (Shift - 1)) - 1)) <> 0) then
      Sticky := True;
  end;
  if RoundBit and (Sticky or ((Mant and 1) <> 0)) then
    Inc(Mant);
  // A subnormal that rounds up to 2^52 is exactly the smallest normal number.
  if E = 0 then
    Exit(Sign or Mant);
  if Mant = HiddenBit shl 1 then
  begin
    Mant := Mant shr 1;
    Inc(E);
  end;
  if E >= $7FF then
    Exit(Sign or InfinityBits);
  Result := Sign or (UInt64(E) shl 52) or (Mant and FractionMask);
end;

// A / B for Double values (bit casts around SoftDivBits).
function SoftDiv(A, B: Double): Double;
begin
  Result := BitsToDouble(SoftDivBits(DoubleToBits(A), DoubleToBits(B)));
end;
