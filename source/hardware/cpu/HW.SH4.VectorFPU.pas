unit HW.SH4.VectorFPU;

// SH7091/SH7750 vector and approximation instructions. Integer arithmetic
// models the shared truncated Booth multipliers, alignment and rounding;
// host floating-point arithmetic is deliberately not used.
// Ported from sh4_fpu_approx.h by Stefanos Kornilios Mitsis Poiitidis:
// https://gist.github.com/skmp/4bd7b38149fc455978b5104201573236
// Reference revision 29f17b480213f063c6db998ecba5745d3f4ad4b3. The author
// validates the model against Dreamcast captures, including FPSCR and traps.
//
// Copyright (c) 2026 Stefanos Kornilios Mitsis Poiitidis
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

interface

{$Q-}{$R-}

type
  // Architectural register order, not the host double's word order.
  TSH4Vector = array[0..3] of Cardinal;
  TSH4Matrix = array[0..15] of Cardinal;
  PSH4Vector = ^TSH4Vector;
  PSH4Matrix = ^TSH4Matrix;

// True: an FPU exception; the destination stays unchanged. FPSCR causes are
// rewritten and flags are sticky. PR=1 leaves registers and FPSCR untouched,
// but the measured unconditional enables still cause an exception.
function SH4FIPR(const M, N: TSH4Vector; var FPSCR, Value: Cardinal): Boolean;
function SH4FTRV(const Matrix: TSH4Matrix; var Vector: TSH4Vector; var FPSCR: Cardinal): Boolean;
// The same on the register banks as the CPU stores them, each pair of
// registers swapped: FVm and FVn from FR(m) and FR(n) (multiples of 4) and
// XMTRX as the whole XF bank. FIPR's Value is then stored FR(n + 2).
function SH4FIPRBanks(const M, N: TSH4Vector; var FPSCR, Value: Cardinal): Boolean;
function SH4FTRVBanks(const XF: TSH4Matrix; var FV: TSH4Vector; var FPSCR: Cardinal): Boolean;
function SH4FSCA(Angle: Cardinal; var FPSCR, SinBits, CosBits: Cardinal): Boolean;
function SH4FSRRA(var Value, FPSCR: Cardinal): Boolean;
{$IFDEF SH4_FTRV_CACHE_STATS}
procedure SH4TransformCacheStats(out Hits, Misses: Int64);
procedure SH4DotCacheStats(out Hits, Misses: Int64);
{$ENDIF}

implementation

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
uses
  Winapi.Windows;
{$ENDIF}

type
  // Cache only the pure numeric output and cause, never FPSCR or the trap.
  // Every input word plus RZ/DN is compared, not just the hash. Enables,
  // sticky flags and PR are applied freshly by the public instruction.
  TTransformEntry = record
    // The matrix as a generation of TVectorCaches.Matrix (0: no entry).
    Generation: UInt64;
    Input, Output: TSH4Vector;
    Cause: Cardinal;
    Mode: Byte;
  end;
  PTransformEntry = ^TTransformEntry;

  TDotEntry = record
    M, N: TSH4Vector;
    Value, Cause: Cardinal;
    Mode: Byte;
    Valid: Boolean;
  end;
  PDotEntry = ^TDotEntry;

  TVectorCaches = record
    // FTRV's matrix rarely changes between instructions: entries name it by
    // the generation it was given when it last changed. Bank is it as stored
    // (pairs swapped), Matrix in architectural order. Entries hold vectors
    // as stored too.
    Bank, Matrix: TSH4Matrix;
    Generation: UInt64;
    Transforms: array[0..1023] of TTransformEntry;
    Dots: array[0..2047] of TDotEntry;
    {$IFDEF SH4_FTRV_CACHE_STATS}
    TransformHits, TransformMisses, DotHits, DotMisses: Int64;
    {$ENDIF}
  end;
  PVectorCaches = ^TVectorCaches;

threadvar
  // Pure results may be reused by CPUs on this thread and across a loaded
  // snapshot; no guest state or memory address is part of their meaning.
  VectorCaches: TVectorCaches;

{$IFDEF SH4_FTRV_CACHE_STATS}
procedure SH4TransformCacheStats(out Hits, Misses: Int64);
begin
  Hits := VectorCaches.TransformHits;
  Misses := VectorCaches.TransformMisses;
end;

procedure SH4DotCacheStats(out Hits, Misses: Int64);
begin
  Hits := VectorCaches.DotHits;
  Misses := VectorCaches.DotMisses;
end;
{$ENDIF}

// Architectural order from stored order and back: each pair swapped.
function Swapped(const V: TSH4Vector): TSH4Vector; inline;
begin
  Result[0] := V[1];
  Result[1] := V[0];
  Result[2] := V[3];
  Result[3] := V[2];
end;

function SameVector(const A, B: TSH4Vector): Boolean; inline;
begin
  Result := (PUInt64(@A[0])^ = PUInt64(@B[0])^) and (PUInt64(@A[2])^ = PUInt64(@B[2])^);
end;

function SameMatrix(const A, B: TSH4Matrix): Boolean;
begin
  for var K := 0 to 7 do
    if PUInt64(@A[K * 2])^ <> PUInt64(@B[K * 2])^ then
      Exit(False);
  Result := True;
end;

const
  QuietNaN = $7FBFFFFF;
  ProductRound = Int64(1) shl 19;
  PrecisionMode = $00080000;
  DenormalMode = $00040000;

function ASR(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

// Callers have already excluded zero; vector sums and fixed results fit
// 32 bits. Avoid normalizing them one bit at a time in the hot path.
function HighestBit(Value: Cardinal): Integer;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  BSR EAX, ECX
end;
{$ELSEIF Defined(CPUX86)}
asm
  BSR EAX, EAX
end;
{$ELSE}
begin
  Result := 0;
  if Value >= $10000 then
  begin
    Value := Value shr 16;
    Inc(Result, 16);
  end;
  if Value >= $100 then
  begin
    Value := Value shr 8;
    Inc(Result, 8);
  end;
  if Value >= $10 then
  begin
    Value := Value shr 4;
    Inc(Result, 4);
  end;
  if Value >= 4 then
  begin
    Value := Value shr 2;
    Inc(Result, 2);
  end;
  if Value >= 2 then
    Inc(Result);
end;
{$ENDIF}

function ProductArray(Recoded, Multiplicand: Int64): Int64;
var
  Rows: array[0..7] of Cardinal;
begin
  // Start with the full product and subtract exactly the bits discarded by
  // rows 0..8. A negative Booth row is d*mul - 1 before its shift, so each
  // such row also contributes its 2^(2*k) bias. Only low 17-bit row values
  // are needed for the remainders, majority carry and parity correction;
  // doing them in 32 bits avoids nine signed 64-bit shifts per product.
  var Low := Cardinal(Recoded) and $3FFFF;
  Result := Recoded * Multiplicand;
  if Low = 0 then
    Exit;
  var Bits := Low shl 1;
  var NegativeRows := (Bits shr 2) and not (Bits and (Bits shr 1)) and $15555;
  var M := Cardinal(Multiplicand);
  if (M and $1FFFF) = 0 then
  begin
    // Powers of two and similarly aligned mantissas are common in matrices
    // and homogeneous coordinates. All their positive remainders vanish;
    // a negative row contributes exactly 65536 after its bias is included.
    var N := (NegativeRows and $33333333) + ((NegativeRows shr 2) and $33333333);
    N := (N + (N shr 4)) and $0F0F0F0F;
    N := N + (N shr 8);
    N := (N + (N shr 16)) and $3F;
    var First := NegativeRows and $15;
    if (First and (First - 1)) <> 0 then
      Dec(N);
    if (((NegativeRows shr 12) xor (NegativeRows shr 14) xor (NegativeRows shr 16)) and 1) <> 0 then
      Inc(N);
    Dec(Result, Int64(N) * 65536);
    Exit;
  end;
  Rows[0] := 0;
  Rows[1] := M;
  Rows[2] := M;
  Rows[3] := M shl 1;
  Rows[4] := not (M shl 1);
  Rows[5] := not M;
  Rows[6] := not M;
  Rows[7] := 0;
  var R0 := Rows[Bits and 7];
  var R1 := Rows[(Bits shr 2) and 7] shl 2;
  var R2 := Rows[(Bits shr 4) and 7] shl 4;
  var R3 := Rows[(Bits shr 6) and 7] shl 6;
  var R4 := Rows[(Bits shr 8) and 7] shl 8;
  var R5 := Rows[(Bits shr 10) and 7] shl 10;
  var R6 := Rows[(Bits shr 12) and 7] shl 12;
  var R7 := Rows[(Bits shr 14) and 7] shl 14;
  var R8 := Rows[(Bits shr 16) and 7] shl 16;
  var Correction := NegativeRows +
    (R0 and $FFFF) + (R1 and $FFFF) + (R2 and $FFFF) + (R3 and $FFFF) +
    (R4 and $FFFF) + (R5 and $FFFF) + (R6 and $FFFF) + (R7 and $FFFF);
  if (((R0 shr 15) and 1) + ((R1 shr 15) and 1) + ((R2 shr 15) and 1)) >= 2 then
    Dec(Correction, 65536);
  if ((R6 xor R7 xor R8) and $10000) <> 0 then
    Inc(Correction, 65536);
  Dec(Result, Int64(Correction));
end;

function AlignProduct(Value: Int64; Count: Integer): Int64; inline;
begin
  // The aligner's negative input gets a hot one (not a plain ASR).
  if Value >= 0 then
    Result := Value shr Count
  else
    Result := -((not Value) shr Count);
end;

procedure UpdateFPSCR(var FPSCR: Cardinal; Cause: Cardinal); inline;
begin
  FPSCR := (FPSCR and not Cardinal($3F000)) or (Cause shl 12) or ((Cause and 31) shl 2);
end;

function RoundDotSum(Value, MaxExponent: Integer; RZ, DN: Boolean; out Cause: Cardinal): Cardinal;
begin
  Cause := 3;
  if Value = 0 then
    Exit(0);
  var Sign: Cardinal := 0;
  if Value < 0 then
  begin
    Sign := $80000000;
    Value := -Value;
  end;
  var Sum := Cardinal(Value);
  var Top := HighestBit(Sum);
  var Exponent := Top + MaxExponent - 153;
  var Shift := Top - 23;
  if (Exponent < 1) and not DN then
    Inc(Shift, 1 - Exponent);
  var Q: Cardinal;
  if Shift >= 32 then
    Q := 0
  else if Shift > 0 then
  begin
    Q := Sum shr Shift;
    var Remainder := Sum and ((Cardinal(1) shl Shift) - 1);
    var Half := Cardinal(1) shl (Shift - 1);
    if not RZ and ((Remainder > Half) or ((Remainder = Half) and ((Q and 1) <> 0))) then
      Inc(Q);
  end
  else
    Q := Sum shl (-Shift);
  if (Exponent < 1) and not DN then
    Exit(Sign or Q);
  if (Q shr 24) <> 0 then
  begin
    Q := Q shr 1;
    Inc(Exponent);
  end;
  if Exponent < 1 then
    Exit(Sign);
  if Exponent >= 255 then
  begin
    Cause := 5;
    if RZ then
      Exit(Sign or $7F7FFFFF)
    else
      Exit(Sign or $7F800000);
  end;
  Cause := 1;
  Result := Sign or (Cardinal(Exponent) shl 23) or (Q and $7FFFFF);
end;

function TryRoundInterval(LowSum, HighSum, MaxExponent: Integer; RZ, DN: Boolean;
  out Bits, Cause: Cardinal): Boolean;
begin
  // One normalization suffices in the common signed normal binade.
  var Sign: Cardinal := 0;
  var Lo: Cardinal;
  var Hi: Cardinal;
  if LowSum > 0 then
  begin
    Lo := Cardinal(LowSum);
    Hi := Cardinal(HighSum);
  end
  else if HighSum < 0 then
  begin
    Sign := $80000000;
    Lo := Cardinal(-HighSum);
    Hi := Cardinal(-LowSum);
  end
  else
  begin
    Lo := 0;
    Hi := 0;
  end;
  if Lo <> 0 then
  begin
    var Top := HighestBit(Lo);
    var Exponent := Top + MaxExponent - 153;
    var Shift := Top - 23;
    if (Cardinal(Exponent - 1) < 253) and ((Hi shr Top) = 1) and (Shift > 0) then
    begin
      var QLo := Lo shr Shift;
      var QHi := Hi shr Shift;
      if not RZ then
      begin
        var Bias := (Cardinal(1) shl (Shift - 1)) - 1;
        QLo := (Lo + Bias + (QLo and 1)) shr Shift;
        QHi := (Hi + Bias + (QHi and 1)) shr Shift;
      end;
      if QLo <> QHi then
        Exit(False);
      if (QLo shr 24) <> 0 then
      begin
        QLo := QLo shr 1;
        Inc(Exponent);
      end;
      Bits := Sign or (Cardinal(Exponent) shl 23) or (QLo and $7FFFFF);
      Cause := 1;
      Exit(True);
    end;
  end;
  Bits := RoundDotSum(LowSum, MaxExponent, RZ, DN, Cause);
  if LowSum = HighSum then
    Exit(True);
  var OtherCause: Cardinal;
  var Other := RoundDotSum(HighSum, MaxExponent, RZ, DN, OtherCause);
  Result := (Bits = Other) and (Cause = OtherCause);
end;

function TryNormalDot(const Mul, Rec: TSH4Vector; RZ, DN: Boolean;
  out Bits, Cause: Cardinal): Boolean;
var
  LowProduct, HighProduct: array[0..3] of Cardinal;
  Exponents: array[0..3] of Integer;
  Negative: array[0..3] of Boolean;
begin
  // Exact interval shortcut, not approximate arithmetic. ProductArray's
  // discarded-row correction C satisfies 0 <= C <= $90000:
  // rows 0..2 after their majority carry sum to at most 131051; rows 3..7
  // to 305856; negative-row biases to 87381; parity adds at most 65536.
  // Bound each 28-bit product using a full multiply. Alignment and signed
  // addition preserve the bounds. Only accept when BOTH ends round to the
  // same guest bits AND cause; otherwise use the complete Booth calculation.
  var MaxExponent := 0;
  for var K := 0 to 3 do
  begin
    var A := Mul[K];
    var B := Rec[K];
    var EA := Integer((A shr 23) and $FF);
    var EB := Integer((B shr 23) and $FF);
    if (EA = 255) or (EB = 255) then
      Exit(False);
    if not DN and (((EA = 0) and ((A and $7FFFFF) <> 0)) or
      ((EB = 0) and ((B and $7FFFFF) <> 0))) then
      Exit(False);
    LowProduct[K] := 0;
    HighProduct[K] := 0;
    Exponents[K] := 0;
    Negative[K] := ((A xor B) and $80000000) <> 0;
    if (EA = 0) or (EB = 0) or (EA + EB <= 75) then
      Continue;
    var M := (A and $7FFFFF) or $800000;
    var R := (B and $7FFFFF) or $800000;
    var P := UInt64(M) * UInt64(R);
    HighProduct[K] := Cardinal((P + $80000) shr 20);
    if (R and $3FFFF) = 0 then
      LowProduct[K] := HighProduct[K]
    else
      LowProduct[K] := Cardinal((P - $10000) shr 20);
    Exponents[K] := EA + EB;
    if EA + EB > MaxExponent then
      MaxExponent := EA + EB;
  end;
  var LowSum := 0;
  var HighSum := 0;
  for var K := 0 to 3 do
  begin
    var Distance := MaxExponent - Exponents[K];
    if Distance >= 28 then
      Continue;
    var Lo := Integer(LowProduct[K] shr Distance);
    var Hi := Integer(HighProduct[K] shr Distance);
    if Negative[K] then
    begin
      Dec(LowSum, Hi);
      Dec(HighSum, Lo);
    end
    else
    begin
      Inc(LowSum, Lo);
      Inc(HighSum, Hi);
    end;
  end;
  if TryRoundInterval(LowSum, HighSum, MaxExponent, RZ, DN, Bits, Cause) then
    Exit(True);

  // Classification and alignment are already known. Resolve only products
  // whose aligned interval still differs; equal endpoints prove the exact
  // aligned integer, even if the unaligned product was not yet determined.
  // Every remaining uncertain product uses the complete Booth multiplier.
  var Sum := 0;
  for var K := 0 to 3 do
  begin
    var Distance := MaxExponent - Exponents[K];
    if Distance >= 28 then
      Continue;
    var Lo := LowProduct[K] shr Distance;
    var Hi := HighProduct[K] shr Distance;
    var P: Integer;
    if Lo = Hi then
      P := Integer(Lo)
    else
    begin
      var M := (Mul[K] and $7FFFFF) or $800000;
      var R := (Rec[K] and $7FFFFF) or $800000;
      var Exact := (ProductArray(Int64(R), Int64(M)) + ProductRound) shr 20;
      P := Integer(Exact shr Distance);
    end;
    if Negative[K] then
      Dec(Sum, P)
    else
      Inc(Sum, P);
  end;
  Bits := RoundDotSum(Sum, MaxExponent, RZ, DN, Cause);
  Result := True;
end;

function DotExact(const Mul, Rec: TSH4Vector; RZ, DN: Boolean; out Cause: Cardinal): Cardinal;
var
  ProductSign, ProductExponent: array[0..3] of Integer;
  ProductValue: array[0..3] of Int64;
begin
  var NaN := False;
  var Invalid := False;
  var PositiveInfinity := 0;
  var NegativeInfinity := 0;
  var Count := 0;
  var Sign0 := (Mul[0] xor Rec[0]) shr 31;
  for var K := 0 to 3 do
  begin
    var A := Mul[K];
    var B := Rec[K];
    var FA := A and $7FFFFF;
    var FB := B and $7FFFFF;
    var EA := Integer((A shr 23) and $FF);
    var EB := Integer((B shr 23) and $FF);
    var Negative := Integer((A xor B) shr 31);
    if (Cardinal(EA - 1) < 254) and (Cardinal(EB - 1) < 254) then
    begin
      // The common normal operands need none of the special classification.
      if EA + EB <= 75 then
        Continue;
      var P := (ProductArray(Int64(FB or $800000), Int64(FA or $800000)) + ProductRound) shr 20;
      if P = 0 then
        Continue;
      ProductSign[Count] := Negative;
      ProductExponent[Count] := EA + EB;
      ProductValue[Count] := P;
      Inc(Count);
      Continue;
    end;
    if (((A and $7FFFFFFF) = 0) and (EB <> 255)) or
      (((B and $7FFFFFFF) = 0) and (EA <> 255)) then
      Continue;
    var ZA := (EA = 0) and (DN or (FA = 0));
    var ZB := (EB = 0) and (DN or (FB = 0));
    var IA := (EA = 255) and (FA = 0);
    var IB := (EB = 255) and (FB = 0);
    var NA := (EA = 255) and (FA <> 0);
    var NB := (EB = 255) and (FB <> 0);
    if NA or NB then
    begin
      NaN := True;
      Invalid := Invalid or (NA and ((FA and $400000) <> 0)) or (NB and ((FB and $400000) <> 0));
      Continue;
    end;
    if (IA and ZB) or (IB and ZA) then
    begin
      NaN := True;
      Invalid := True;
      Continue;
    end;
    if IA or IB then
    begin
      if Negative <> 0 then
        Inc(NegativeInfinity)
      else
        Inc(PositiveInfinity);
      Continue;
    end;
    if ZA or ZB then
      Continue;
    if EA = 0 then
      EA := 1
    else
      FA := FA or $800000;
    if EB = 0 then
      EB := 1
    else
      FB := FB or $800000;
    if EA + EB <= 75 then
      Continue;
    var P := (ProductArray(Int64(FB), Int64(FA)) + ProductRound) shr 20;
    if P = 0 then
      Continue;
    ProductSign[Count] := Negative;
    ProductExponent[Count] := EA + EB;
    ProductValue[Count] := P;
    Inc(Count);
  end;
  if (PositiveInfinity <> 0) and (NegativeInfinity <> 0) then
  begin
    NaN := True;
    Invalid := True;
  end;
  Cause := 0;
  if NaN then
  begin
    if Invalid then
      Cause := 16;
    Exit(QuietNaN);
  end;
  // Multiple infinities with the same sign take product zero's sign.
  if PositiveInfinity + NegativeInfinity >= 2 then
    Exit((Sign0 shl 31) or $7F800000);
  if PositiveInfinity <> 0 then
    Exit($7F800000);
  if NegativeInfinity <> 0 then
    Exit($FF800000);

  var MaxExponent := 0;
  for var K := 0 to Count - 1 do
    if ProductExponent[K] > MaxExponent then
      MaxExponent := ProductExponent[K];
  var Sum: Int64 := 0;
  for var K := 0 to Count - 1 do
  begin
    var Distance := MaxExponent - ProductExponent[K];
    var P: Int64 := 0;
    if Distance < 40 then
      P := ProductValue[K] shr Distance;
    if ProductSign[K] <> 0 then
      Dec(Sum, P)
    else
      Inc(Sum, P);
  end;
  // Four aligned 28-bit products sum to less than 2^30 in magnitude.
  Result := RoundDotSum(Integer(Sum), MaxExponent, RZ, DN, Cause);
end;

function DotNormalExact(const Mul, Rec: TSH4Vector; MaxExponent: Integer;
  RZ, DN: Boolean; out Cause: Cardinal): Cardinal;
begin
  // The transform bounds have already classified every operand and found
  // the row exponent. Reuse that proof instead of collecting/classifying
  // products again in DotExact. Zero/allowed DN operands contribute zero.
  var Sum := 0;
  for var K := 0 to 3 do
  begin
    var A := Mul[K];
    var B := Rec[K];
    var EA := Integer((A shr 23) and $FF);
    var EB := Integer((B shr 23) and $FF);
    if (EA = 0) or (EB = 0) or (EA + EB <= 75) then
      Continue;
    var Distance := MaxExponent - EA - EB;
    if Distance >= 28 then
      Continue;
    var M := (A and $7FFFFF) or $800000;
    var R := (B and $7FFFFF) or $800000;
    var Full := UInt64(M) * UInt64(R);
    var Hi := Cardinal((Full + $80000) shr 20) shr Distance;
    var Lo := Hi;
    if (R and $3FFFF) <> 0 then
      Lo := Cardinal((Full - $10000) shr 20) shr Distance;
    if Lo <> Hi then
      Lo := Cardinal((ProductArray(Int64(R), Int64(M)) + ProductRound) shr 20) shr Distance;
    if ((A xor B) and $80000000) <> 0 then
      Dec(Sum, Integer(Lo))
    else
      Inc(Sum, Integer(Lo));
  end;
  Result := RoundDotSum(Sum, MaxExponent, RZ, DN, Cause);
end;

function Dot(const Mul, Rec: TSH4Vector; RZ, DN: Boolean; out Cause: Cardinal): Cardinal;
begin
  if not TryNormalDot(Mul, Rec, RZ, DN, Result, Cause) then
    Result := DotExact(Mul, Rec, RZ, DN, Cause);
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
// Exact normal FTRV interval bounds, four matrix rows in parallel. No floating
// arithmetic: the scalar reference still rounds the bounds and resolves every
// ambiguous row with the full Booth calculation. Win64 volatile registers only.
type
  TBoundsVector = array[0..3] of Integer;
  TBoundsMatrix = array[0..3] of TBoundsVector;

const
  BoundsZero: TBoundsVector = (0, 0, 0, 0);
  BoundsFF: TBoundsVector = (255, 255, 255, 255);
  Bounds75: TBoundsVector = (75, 75, 75, 75);
  BoundsMantissa: TBoundsVector = ($7FFFFF, $7FFFFF, $7FFFFF, $7FFFFF);
  BoundsHidden: TBoundsVector = ($800000, $800000, $800000, $800000);
  BoundsLowMask: TBoundsVector = ($3FFFF, $3FFFF, $3FFFF, $3FFFF);
  BoundsRound: array[0..1] of UInt64 = ($80000, $80000);
  BoundsSubtract: array[0..1] of UInt64 = ($10000, $10000);

var
  UseAVX2Bounds: Boolean;

function TransformBoundsAVX2(const Matrix: TSH4Matrix; const Vector: TSH4Vector;
  DN: Boolean; out LowSums, HighSums, MaxExponents: TBoundsVector): Boolean;
var
  ProductsLo, ProductsHi, Exponents, Signs, Active: TBoundsMatrix;
  MaxE: TBoundsVector;
asm
  VPXOR XMM0, XMM0, XMM0
  VMOVDQU MaxE, XMM0
  XOR R10D, R10D
  XOR R11D, R11D
@Column:
  VPBROADCASTD XMM0, DWORD PTR [RDX + R10 * 4]
  VMOVDQU XMM1, [RCX + R11]
  VPSRLD XMM2, XMM0, 23
  VPAND XMM2, XMM2, BoundsFF
  VPSRLD XMM3, XMM1, 23
  VPAND XMM3, XMM3, BoundsFF
  VPCMPEQD XMM4, XMM2, BoundsFF
  VPCMPEQD XMM5, XMM3, BoundsFF
  VPOR XMM4, XMM4, XMM5
  VMOVMSKPS EAX, XMM4
  TEST EAX, EAX
  JNZ @Decline
  TEST R8B, R8B
  JNZ @ClassesOK
  VPSLLD XMM4, XMM0, 1
  VPCMPEQD XMM4, XMM4, BoundsZero
  VPCMPEQD XMM5, XMM2, BoundsZero
  VPANDN XMM4, XMM4, XMM5
  VMOVMSKPS EAX, XMM4
  TEST EAX, EAX
  JNZ @Decline
  VPSLLD XMM4, XMM1, 1
  VPCMPEQD XMM4, XMM4, BoundsZero
  VPCMPEQD XMM5, XMM3, BoundsZero
  VPANDN XMM4, XMM4, XMM5
  VMOVMSKPS EAX, XMM4
  TEST EAX, EAX
  JNZ @Decline
@ClassesOK:
  VPXOR XMM4, XMM0, XMM1
  VPSRAD XMM4, XMM4, 31
  LEA RAX, Signs
  VMOVDQU [RAX + R11], XMM4
  VPCMPEQD XMM4, XMM2, BoundsZero
  VPCMPEQD XMM5, XMM3, BoundsZero
  VPOR XMM4, XMM4, XMM5
  VPADDD XMM2, XMM2, XMM3
  VPCMPGTD XMM5, XMM2, Bounds75
  VPANDN XMM4, XMM4, XMM5
  LEA RAX, Active
  VMOVDQU [RAX + R11], XMM4
  VPAND XMM2, XMM2, XMM4
  LEA RAX, Exponents
  VMOVDQU [RAX + R11], XMM2
  VPMAXSD XMM2, XMM2, MaxE
  VMOVDQU MaxE, XMM2
  VPAND XMM0, XMM0, BoundsMantissa
  VPOR XMM0, XMM0, BoundsHidden
  VPAND XMM1, XMM1, BoundsMantissa
  VPOR XMM1, XMM1, BoundsHidden
  VPMULUDQ XMM2, XMM0, XMM1
  VPSRLDQ XMM3, XMM1, 4
  VPMULUDQ XMM4, XMM0, XMM3
  VPADDQ XMM3, XMM2, BoundsRound
  VPADDQ XMM5, XMM4, BoundsRound
  VPSRLQ XMM3, XMM3, 20
  VPSRLQ XMM5, XMM5, 20
  VPSHUFD XMM3, XMM3, $88
  VPSHUFD XMM5, XMM5, $88
  VPUNPCKLDQ XMM3, XMM3, XMM5
  LEA RAX, Active
  VPAND XMM3, XMM3, [RAX + R11]
  LEA RAX, ProductsHi
  VMOVDQU [RAX + R11], XMM3
  VPSUBQ XMM2, XMM2, BoundsSubtract
  VPSUBQ XMM4, XMM4, BoundsSubtract
  VPSRLQ XMM2, XMM2, 20
  VPSRLQ XMM4, XMM4, 20
  VPSHUFD XMM2, XMM2, $88
  VPSHUFD XMM4, XMM4, $88
  VPUNPCKLDQ XMM2, XMM2, XMM4
  VPAND XMM1, XMM1, BoundsLowMask
  VPCMPEQD XMM1, XMM1, BoundsZero
  VPANDN XMM2, XMM1, XMM2
  VPAND XMM3, XMM3, XMM1
  VPOR XMM2, XMM2, XMM3
  LEA RAX, Active
  VPAND XMM2, XMM2, [RAX + R11]
  LEA RAX, ProductsLo
  VMOVDQU [RAX + R11], XMM2
  INC R10D
  ADD R11D, 16
  CMP R10D, 4
  JL @Column
  VPXOR XMM0, XMM0, XMM0
  VPXOR XMM1, XMM1, XMM1
  VMOVDQU XMM2, MaxE
  LEA RCX, Exponents
  LEA RDX, ProductsLo
  LEA R10, ProductsHi
  LEA R8, Signs
  XOR R11D, R11D
@SumColumn:
  VPSUBD XMM3, XMM2, [RCX + R11]
  VMOVDQU XMM4, [RDX + R11]
  VPSRLVD XMM4, XMM4, XMM3
  VMOVDQU XMM5, [R10 + R11]
  VPSRLVD XMM5, XMM5, XMM3
  VPXOR XMM3, XMM4, XMM5
  VPAND XMM3, XMM3, [R8 + R11]
  VPXOR XMM4, XMM4, XMM3
  VPXOR XMM5, XMM5, XMM3
  VPXOR XMM4, XMM4, [R8 + R11]
  VPSUBD XMM4, XMM4, [R8 + R11]
  VPXOR XMM5, XMM5, [R8 + R11]
  VPSUBD XMM5, XMM5, [R8 + R11]
  VPADDD XMM0, XMM0, XMM4
  VPADDD XMM1, XMM1, XMM5
  ADD R11D, 16
  CMP R11D, 64
  JL @SumColumn
  VMOVDQU [R9], XMM0
  MOV RAX, HighSums
  VMOVDQU [RAX], XMM1
  MOV RAX, MaxExponents
  VMOVDQU [RAX], XMM2
  MOV EAX, 1
  JMP @Done
@Decline:
  XOR EAX, EAX
@Done:
  VZEROUPPER
end;
{$ENDIF}

function TryNormalTransform(const Matrix: TSH4Matrix; const Vector: TSH4Vector;
  RZ, DN: Boolean; out Output: TSH4Vector; out Cause: Cardinal): Boolean;
var
  Mantissa, Exponent, Sign: TSH4Vector;
  LowProduct, HighProduct: array[0..15] of Cardinal;
  ProductExponent: array[0..15] of Integer;
  Negative: array[0..15] of Boolean;
  MaxExponent: array[0..3] of Integer;
begin
  // FTRV shares one vector between four rows. Decode each operand once,
  // keep the column-major matrix in place, and only recompute ambiguous
  // rows with the full multiplier (without repeating their interval test).
  {$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if UseAVX2Bounds then
  begin
    var LowSums, HighSums, MaxExponents: TBoundsVector;
    if not TransformBoundsAVX2(Matrix, Vector, DN, LowSums, HighSums, MaxExponents) then
      Exit(False);
    Cause := 0;
    for var K := 0 to 3 do
    begin
      var C: Cardinal;
      if not TryRoundInterval(LowSums[K], HighSums[K], MaxExponents[K], RZ, DN, Output[K], C) then
      begin
        var Row: TSH4Vector;
        for var J := 0 to 3 do
          Row[J] := Matrix[K + J * 4];
        Output[K] := DotNormalExact(Vector, Row, MaxExponents[K], RZ, DN, C);
      end;
      Cause := Cause or C;
    end;
    Exit(True);
  end;
  {$ENDIF}
  for var J := 0 to 3 do
  begin
    var V := Vector[J];
    Exponent[J] := (V shr 23) and $FF;
    Mantissa[J] := V and $7FFFFF;
    if (Exponent[J] = 255) or (not DN and (Exponent[J] = 0) and (Mantissa[J] <> 0)) then
      Exit(False);
    Mantissa[J] := Mantissa[J] or $800000;
    Sign[J] := V and $80000000;
    MaxExponent[J] := 0;
  end;
  for var J := 0 to 3 do
    for var K := 0 to 3 do
    begin
      var V := Matrix[J * 4 + K];
      var E := Integer((V shr 23) and $FF);
      var M := V and $7FFFFF;
      if (E = 255) or (not DN and (E = 0) and (M <> 0)) then
        Exit(False);
      var Index := K * 4 + J;
      Negative[Index] := ((Sign[J] xor V) and $80000000) <> 0;
      LowProduct[Index] := 0;
      HighProduct[Index] := 0;
      ProductExponent[Index] := 0;
      if (E = 0) or (Exponent[J] = 0) then
        Continue;
      Inc(E, Integer(Exponent[J]));
      if E <= 75 then
        Continue;
      M := M or $800000;
      var P := UInt64(Mantissa[J]) * UInt64(M);
      HighProduct[Index] := Cardinal((P + $80000) shr 20);
      if (M and $3FFFF) = 0 then
        LowProduct[Index] := HighProduct[Index]
      else
        LowProduct[Index] := Cardinal((P - $10000) shr 20);
      ProductExponent[Index] := E;
      if E > MaxExponent[K] then
        MaxExponent[K] := E;
    end;
  Cause := 0;
  for var K := 0 to 3 do
  begin
    var LowSum := 0;
    var HighSum := 0;
    for var J := 0 to 3 do
    begin
      var Index := K * 4 + J;
      var Distance := MaxExponent[K] - ProductExponent[Index];
      if Distance >= 28 then
        Continue;
      var Lo := Integer(LowProduct[Index] shr Distance);
      var Hi := Integer(HighProduct[Index] shr Distance);
      if Negative[Index] then
      begin
        Dec(LowSum, Hi);
        Dec(HighSum, Lo);
      end
      else
      begin
        Inc(LowSum, Lo);
        Inc(HighSum, Hi);
      end;
    end;
    var C: Cardinal;
    if not TryRoundInterval(LowSum, HighSum, MaxExponent[K], RZ, DN, Output[K], C) then
    begin
      var Row: TSH4Vector;
      for var J := 0 to 3 do
        Row[J] := Matrix[K + J * 4];
      Output[K] := DotNormalExact(Vector, Row, MaxExponent[K], RZ, DN, C);
    end;
    Cause := Cause or C;
  end;
  Result := True;
end;

function SH4FIPRBanks(const M, N: TSH4Vector; var FPSCR, Value: Cardinal): Boolean;
begin
  var Enables := (FPSCR shr 7) and 31;
  if (FPSCR and PrecisionMode) <> 0 then
    Exit((Enables and 1) <> 0);
  var Mode := Byte(Ord((FPSCR and 3) = 1) or (Ord((FPSCR and DenormalMode) <> 0) shl 1));
  var Hash := M[0] xor (M[1] shl 3) xor (M[2] shl 7) xor M[3] xor (N[0] shl 11) xor (N[1] shl 1) xor
    (N[2] shl 5) xor N[3];
  Hash := Hash * Cardinal($9E3779B1);
  var Entry: PDotEntry := @VectorCaches.Dots[Hash shr 21];
  var Bits, Cause: Cardinal;
  if Entry.Valid and (Entry.Mode = Mode) and SameVector(Entry.M, M) and SameVector(Entry.N, N) then
  begin
    Bits := Entry.Value;
    Cause := Entry.Cause;
    {$IFDEF SH4_FTRV_CACHE_STATS}Inc(VectorCaches.DotHits);{$ENDIF}
  end
  else
  begin
    {$IFDEF SH4_FTRV_CACHE_STATS}Inc(VectorCaches.DotMisses);{$ENDIF}
    Bits := Dot(Swapped(M), Swapped(N), (FPSCR and 3) = 1, (FPSCR and DenormalMode) <> 0, Cause);
    Entry.M := M;
    Entry.N := N;
    Entry.Value := Bits;
    Entry.Cause := Cause;
    Entry.Mode := Mode;
    Entry.Valid := True;
  end;
  UpdateFPSCR(FPSCR, Cause);
  Result := ((Enables and 7) <> 0) or ((Enables and Cause and 16) <> 0);
  if not Result then
    Value := Bits;
end;

function SH4FIPR(const M, N: TSH4Vector; var FPSCR, Value: Cardinal): Boolean;
begin
  Result := SH4FIPRBanks(Swapped(M), Swapped(N), FPSCR, Value);
end;

function SH4FTRVBanks(const XF: TSH4Matrix; var FV: TSH4Vector; var FPSCR: Cardinal): Boolean;
begin
  Result := (((FPSCR shr 7) and 31) and 23) <> 0;
  if (FPSCR and PrecisionMode) <> 0 then
    Exit;
  var Output, Row: TSH4Vector;
  var Cause: Cardinal := 0;
  var Mode := Byte(Ord((FPSCR and 3) = 1) or (Ord((FPSCR and DenormalMode) <> 0) shl 1));
  var Caches: PVectorCaches := @VectorCaches;
  if (Caches.Generation = 0) or not SameMatrix(Caches.Bank, XF) then
  begin
    Caches.Bank := XF;
    for var K := 0 to 15 do
      Caches.Matrix[K] := XF[K xor 1];
    Inc(Caches.Generation);
  end;
  var Hash := FV[0] xor (FV[1] shl 5) xor (FV[1] shr 27) xor
    (FV[2] shl 13) xor (FV[2] shr 19) xor FV[3] xor Cardinal(Caches.Generation);
  Hash := Hash * Cardinal($9E3779B1);
  var Entry: PTransformEntry := @Caches.Transforms[Hash shr 22];
  if (Entry.Generation = Caches.Generation) and (Entry.Mode = Mode) and SameVector(Entry.Input, FV) then
  begin
    Output := Entry.Output;
    Cause := Entry.Cause;
    {$IFDEF SH4_FTRV_CACHE_STATS}Inc(Caches.TransformHits);{$ENDIF}
  end
  else
  begin
    {$IFDEF SH4_FTRV_CACHE_STATS}Inc(Caches.TransformMisses);{$ENDIF}
    var Vector := Swapped(FV);
    if not TryNormalTransform(Caches.Matrix, Vector, (FPSCR and 3) = 1, (FPSCR and DenormalMode) <> 0, Output,
      Cause) then
    begin
      Cause := 0;
      for var K := 0 to 3 do
      begin
        for var J := 0 to 3 do
          Row[J] := Caches.Matrix[K + J * 4];
        var C: Cardinal;
        Output[K] := Dot(Vector, Row, (FPSCR and 3) = 1, (FPSCR and DenormalMode) <> 0, C);
        Cause := Cause or C;
      end;
    end;
    Output := Swapped(Output);
    Entry.Generation := Caches.Generation;
    Entry.Input := FV;
    Entry.Output := Output;
    Entry.Cause := Cause;
    Entry.Mode := Mode;
  end;
  UpdateFPSCR(FPSCR, Cause);
  if not Result then
    FV := Output;
end;

function SH4FTRV(const Matrix: TSH4Matrix; var Vector: TSH4Vector; var FPSCR: Cardinal): Boolean;
var
  Bank: TSH4Matrix;
begin
  for var K := 0 to 15 do
    Bank[K] := Matrix[K xor 1];
  var FV := Swapped(Vector);
  Result := SH4FTRVBanks(Bank, FV, FPSCR);
  if not Result then
    Vector := Swapped(FV);
end;
type
  TFSCAWord = record
    C0, L: Cardinal;
    E: Integer;
    Q: Cardinal;
  end;

const
  FSCAROM: array[0..16] of TFSCAWord = (
    (C0: 0; L: $000000; E: 0; Q: $000),
    (C0: 6577819; L: $4ED47F; E: 3; Q: $103),
    (C0: 13092290; L: $4E7352; E: 2; Q: $204),
    (C0: 19480674; L: $74BAFB; E: 2; Q: $300),
    (C0: 25681450; L: $4CF16D; E: 1; Q: $3F5),
    (C0: 31634899; L: $5EC7AA; E: 1; Q: $4DF),
    (C0: 37283686; L: $6FB43B; E: 1; Q: $5BE),
    (C0: 42573411; L: $7F8D66; E: 1; Q: $68F),
    (C0: 47453131; L: $47160C; E: 0; Q: $74F),
    (C0: 51875851; L: $4DB624; E: 0; Q: $7FD),
    (C0: 55798982; L: $5396A4; E: 0; Q: $898),
    (C0: 59184735; L: $58A910; E: 0; Q: $91D),
    (C0: 62000504; L: $5CE0E5; E: 0; Q: $98C),
    (C0: 64219180; L: $6033BF; E: 0; Q: $9E4),
    (C0: 65819382; L: $62996B; E: 0; Q: $A23),
    (C0: 66785715; L: $640C00; E: 0; Q: $A49),
    (C0: 67108863; L: $6487ED; E: 0; Q: $A56));

function SineFixed(Angle: Cardinal): Int64;
begin
  var A := Angle and $FFFF;
  var Node := ((A + 512) shr 10) and 63;
  var R := Integer(Node and 15);
  var Quadrant := Node shr 4;
  var T := Integer((A + 512) and 1023) - 512;
  var Swap := (Quadrant and 1) <> 0;
  var M := R;
  if Swap then
    M := 16 - R;
  var W := FSCAROM[M];
  var X := FSCAROM[16 - M];
  var DX := Int64(T) * 8192;
  var Square := ASR(ProductArray(DX, DX) + ProductRound, 23);
  var T1 := AlignProduct(ProductArray(Int64(X.L), DX) + ProductRound, 23 + X.E);
  var A3 := ASR(ProductArray(Square, DX) + ProductRound, 23);
  var T3 := AlignProduct(ProductArray(Int64(X.Q) * 32, A3) + ProductRound, 26);
  var I1 := ASR(ProductArray($648340, DX) + ProductRound, 23);
  var J := ASR(ProductArray(DX, I1) + ProductRound, 23);
  var T2 := AlignProduct(ProductArray(Int64(W.L), J) + ProductRound, 27 + W.E);
  Result := Int64(W.C0) - T2;
  if Swap then
    Inc(Result, T3 - T1)
  else
    Inc(Result, T1 - T3);
  if (Quadrant and 2) <> 0 then
    Result := -Result;
end;

function FixedToFloat(Value: Int64; RZ: Boolean): Cardinal;
begin
  var Sign: Cardinal := 0;
  if Value < 0 then
  begin
    Sign := $80000000;
    Value := -Value;
  end;
  if Value = 0 then
    Exit(0);
  var Magnitude := UInt64(Value);
  var P := HighestBit(Cardinal(Magnitude));
  var Shift := P - 23;
  var Q: UInt64;
  if Shift <= 0 then
    Q := Magnitude shl (-Shift)
  else
  begin
    Q := Magnitude shr Shift;
    var Remainder := Magnitude and ((UInt64(1) shl Shift) - 1);
    var Half := UInt64(1) shl (Shift - 1);
    if not RZ and ((Remainder > Half) or ((Remainder = Half) and ((Q and 1) <> 0))) then
    begin
      Inc(Q);
      if (Q shr 24) <> 0 then
      begin
        Q := Q shr 1;
        Inc(P);
      end;
    end;
  end;
  Result := Sign or (Cardinal(127 - 26 + P) shl 23) or (Cardinal(Q) and $7FFFFF);
end;

function SH4FSCA(Angle: Cardinal; var FPSCR, SinBits, CosBits: Cardinal): Boolean;
begin
  Result := (FPSCR and $80) <> 0;
  if (FPSCR and PrecisionMode) <> 0 then
    Exit;
  UpdateFPSCR(FPSCR, 1);
  if Result then
    Exit;
  var RZ := (FPSCR and 3) = 1;
  SinBits := FixedToFloat(SineFixed(Angle), RZ);
  CosBits := FixedToFloat(SineFixed(Angle + $4000), RZ);
end;

type
  TFSRRAWord = record
    C0, Rec1: Cardinal;
    E1: Integer;
    C2F, C3F: Cardinal;
  end;

const
  FSRRAROM: array[0..33] of TFSRRAWord = (
    (C0: 67108864; Rec1: $400000; E1: 2; C2F: 12296; C3F: 320),
    (C0: 65105160; Rec1: $74DFA6; E1: 1; C2F: 10566; C3F: 260),
    (C0: 63270842; Rec1: $6B454D; E1: 1; C2F: 9159; C3F: 212),
    (C0: 61583317; Rec1: $62EA16; E1: 1; C2F: 8000; C3F: 176),
    (C0: 60023991; Rec1: $5B96DF; E1: 1; C2F: 7037; C3F: 148),
    (C0: 58577421; Rec1: $552032; E1: 1; C2F: 6228; C3F: 124),
    (C0: 57230630; Rec1: $4F6360; E1: 1; C2F: 5545; C3F: 106),
    (C0: 55972662; Rec1: $4A4474; E1: 1; C2F: 4962; C3F: 90),
    (C0: 54794160; Rec1: $45ACA4; E1: 1; C2F: 4460; C3F: 78),
    (C0: 53687088; Rec1: $418937; E1: 1; C2F: 4029; C3F: 68),
    (C0: 52644524; Rec1: $7B9555; E1: 0; C2F: 3651; C3F: 58),
    (C0: 51660427; Rec1: $74C814; E1: 0; C2F: 3323; C3F: 52),
    (C0: 50729532; Rec1: $6E94E4; E1: 0; C2F: 3035; C3F: 46),
    (C0: 49847212; Rec1: $68E955; E1: 0; C2F: 2779; C3F: 40),
    (C0: 49009384; Rec1: $63B5B8; E1: 0; C2F: 2553; C3F: 36),
    (C0: 48212432; Rec1: $5EEC9F; E1: 0; C2F: 2352; C3F: 32),
    (C0: 47453132; Rec1: $5A8279; E1: 0; C2F: 2174; C3F: 28),
    (C0: 47453132; Rec1: $5A8279; E1: 1; C2F: 8695; C3F: 226),
    (C0: 46036301; Rec1: $52A463; E1: 1; C2F: 7471; C3F: 183),
    (C0: 44739243; Rec1: $4BDA13; E1: 1; C2F: 6476; C3F: 151),
    (C0: 43545981; Rec1: $45F16B; E1: 1; C2F: 5658; C3F: 124),
    (C0: 42443371; Rec1: $40C371; E1: 1; C2F: 4976; C3F: 104),
    (C0: 41420491; Rec1: $7862D1; E1: 0; C2F: 4404; C3F: 87),
    (C0: 40468166; Rec1: $704598; E1: 0; C2F: 3921; C3F: 74),
    (C0: 39578650; Rec1: $6907AB; E1: 0; C2F: 3508; C3F: 63),
    (C0: 38745321; Rec1: $6288D1; E1: 0; C2F: 3154; C3F: 55),
    (C0: 37962507; Rec1: $5CAE91; E1: 0; C2F: 2847; C3F: 47),
    (C0: 37225301; Rec1: $5762F9; E1: 0; C2F: 2581; C3F: 41),
    (C0: 36529438; Rec1: $5293B8; E1: 0; C2F: 2350; C3F: 36),
    (C0: 35871196; Rec1: $4E3168; E1: 0; C2F: 2146; C3F: 32),
    (C0: 35247303; Rec1: $4A2F01; E1: 0; C2F: 1965; C3F: 28),
    (C0: 34654868; Rec1: $468169; E1: 0; C2F: 1805; C3F: 25),
    (C0: 34091336; Rec1: $431F22; E1: 0; C2F: 1664; C3F: 22),
    (C0: 33554432; Rec1: $400000; E1: 0; C2F: 1537; C3F: 20));

function ReciprocalFixed(Mantissa: Cardinal; Parity: Integer): Int64;
begin
  var M := Int64(Mantissa and $7FFFFF);
  var Node := (M + (Int64(1) shl 18)) shr 19;
  var T := M - Node * (Int64(1) shl 19);
  var W := FSRRAROM[Parity * 17 + Integer(Node)];
  var DX := T * 16;
  var Square := ASR(ProductArray(DX, DX) + ProductRound, 23);
  var T1 := AlignProduct(ProductArray(Int64(W.Rec1), DX) + ProductRound, 26 - W.E1);
  var T2 := AlignProduct(ProductArray(Int64(W.C2F) * 512, Square) + ProductRound, 29);
  var I := ASR(ProductArray(Int64(W.C3F) * 256, Square) + ProductRound, 23);
  var T3 := AlignProduct(ProductArray(DX, I) + ProductRound, 27);
  Result := Int64(W.C0) - T1 + T2 - T3;
end;

function Reciprocal(Value: Cardinal; RZ: Boolean): Cardinal;
begin
  var E := Integer((Value shr 23) and $FF) - 127;
  var Parity := E and 1;
  var K := (E - Parity) div 2;
  var W := UInt64(ReciprocalFixed(Value and $7FFFFF, Parity));
  var Top := 25;
  if (W shr 26) <> 0 then
    Top := 26;
  var Shift := Top - 23;
  var Q := W shr Shift;
  if not RZ then
  begin
    var Remainder := W and ((UInt64(1) shl Shift) - 1);
    var Half := UInt64(1) shl (Shift - 1);
    if (Remainder > Half) or ((Remainder = Half) and ((Q and 1) <> 0)) then
      Inc(Q);
    if (Q shr 24) <> 0 then
    begin
      Q := Q shr 1;
      Inc(Top);
    end;
  end;
  Result := (Cardinal(Top - 26 - K + 127) shl 23) or (Cardinal(Q) and $7FFFFF);
end;

function SH4FSRRA(var Value, FPSCR: Cardinal): Boolean;
begin
  if (FPSCR and PrecisionMode) <> 0 then
    Exit((FPSCR and $80) <> 0);
  var Sign := Value shr 31;
  var Exponent := (Value shr 23) and $FF;
  var Mantissa := Value and $7FFFFF;
  var Bits, Cause: Cardinal;
  if (Exponent = $FF) and (Mantissa <> 0) then
  begin
    Bits := QuietNaN;
    Cause := 0;
    if (Mantissa and $400000) <> 0 then
      Cause := 16;
  end
  else if Exponent = $FF then
  begin
    Bits := 0;
    Cause := 0;
    if Sign <> 0 then
    begin
      Bits := QuietNaN;
      Cause := 16;
    end;
  end
  else if (Exponent = 0) and ((Mantissa = 0) or ((FPSCR and DenormalMode) <> 0)) then
  begin
    Bits := (Sign shl 31) or $7F800000;
    Cause := 8;
  end
  else if Exponent = 0 then
  begin
    Bits := QuietNaN;
    if Sign <> 0 then
      Cause := 16
    else
      Cause := 32;
  end
  else if Sign <> 0 then
  begin
    Bits := QuietNaN;
    Cause := 16;
  end
  else
  begin
    Bits := Reciprocal(Value, (FPSCR and 3) = 1);
    Cause := 1;
  end;
  UpdateFPSCR(FPSCR, Cause);
  Result := ((Cause and 32) <> 0) or ((Cause and (FPSCR shr 7) and 31) <> 0) or ((FPSCR and $80) <> 0);
  if not Result then
    Value := Bits;
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
initialization
  // PF_AVX2_INSTRUCTIONS_AVAILABLE: the OS also checks usable AVX state.
  // Older Windows versions return false for unsupported feature queries.
  UseAVX2Bounds := IsProcessorFeaturePresent(40);
  {$IFDEF SH4_NO_AVX2}
  UseAVX2Bounds := False;
  {$ENDIF}
{$ENDIF}

end.
