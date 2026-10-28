unit PS2.VU.Float;

// PS2 float arithmetic of the VU upper instructions, one field (PS2FloatMul;
// PS2FloatAdd is the FPU's, in PS2.EE.CPU) or four at once (PS2Mul4,
// PS2Add4) with the same results: products of the 24-bit mantissas and sums
// with the adder's single guard bit, both truncated; exponent 0 reads as
// zero, exponent 255 as an ordinary binade; overflow gives the largest value,
// underflow a signed zero. Win64 does four fields with SSE2 on doubles (every
// product of two mantissas, and every sum once the smaller operand has lost
// the bits below the guard bit, is exact in a double); other targets loop
// over the one-field routines.
//
// Four-field flags: bit K overflow and bit K + 4 underflow of field K.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  PS2.Types;

// A * B; Flags: 1 overflow, 2 underflow.
function PS2FloatMul(A, B: Cardinal; out Flags: Cardinal): Cardinal;
// R = A * B and R = A + B for four fields.
procedure PS2Mul4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
procedure PS2Add4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);

implementation

uses
  PS2.EE.CPU;

function PS2FloatMul(A, B: Cardinal; out Flags: Cardinal): Cardinal;
begin
  Flags := 0;
  if ((A and $7F800000) = 0) or ((B and $7F800000) = 0) then
    Exit((A xor B) and $80000000);
  var D := EEFloatIn(A) * EEFloatIn(B);
  var Bits := PUInt64(@D)^;
  var Sign := Cardinal(Bits shr 32) and $80000000;
  var E := Integer((Bits shr 52) and $7FF) - (1023 - 127);
  if E > 255 then
  begin
    Flags := 1;
    Exit(Sign or $7FFFFFFF);
  end;
  if E <= 0 then
  begin
    Flags := 2;
    Exit(Sign);
  end;
  Result := Sign or (Cardinal(E) shl 23) or (Cardinal(Bits shr 29) and $7FFFFF);
end;

{$IFDEF CPUX64}
{$IFDEF MSWINDOWS}
{$DEFINE PS2_VU_SSE}
{$ENDIF}
{$ENDIF}

{$IFDEF PS2_VU_SSE}

const
  CExpMask: array[0..3] of Cardinal = ($7F800000, $7F800000, $7F800000, $7F800000);
  CAbsMask: array[0..3] of Cardinal = ($7FFFFFFF, $7FFFFFFF, $7FFFFFFF, $7FFFFFFF);
  CSignMask: array[0..3] of Cardinal = ($80000000, $80000000, $80000000, $80000000);
  // 896 << 52: moves a float's exponent (shifted to bits 52..59) to a
  // double's bias.
  CBias: array[0..1] of UInt64 = (UInt64(896) shl 52, UInt64(896) shl 52);
  CAbs64: array[0..1] of UInt64 = ($7FFFFFFFFFFFFFFF, $7FFFFFFFFFFFFFFF);
  // Double exponents: results at or below 896 underflow, above 1151
  // overflow.
  CExpLow: array[0..3] of Integer = (897, 897, 897, 897);
  CExpHigh: array[0..3] of Integer = (1151, 1151, 1151, 1151);
  COne: array[0..3] of Integer = (1, 1, 1, 1);
  C23: array[0..3] of Integer = (23, 23, 23, 23);
  C127: array[0..3] of Integer = (127, 127, 127, 127);

procedure PS2Mul4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
var
  ZeroMask: TPS2Reg128;
asm
  .SAVENV XMM6
  .SAVENV XMM7
  // RCX = @A, RDX = @B, R8 = @R, R9 = @Flags
  movdqu  xmm0, [rcx]
  movdqu  xmm1, [rdx]
  pxor    xmm7, xmm7
  // Zero operands (exponent 0): a signed zero, no flags.
  movdqu  xmm2, [rip + CExpMask]
  movdqa  xmm3, xmm0
  pand    xmm3, xmm2
  pcmpeqd xmm3, xmm7
  movdqa  xmm4, xmm1
  pand    xmm4, xmm2
  pcmpeqd xmm4, xmm7
  por     xmm3, xmm4
  movdqu  ZeroMask, xmm3
  // Sign of the product.
  movdqa  xmm6, xmm0
  pxor    xmm6, xmm1
  movdqu  xmm2, [rip + CSignMask]
  pand    xmm6, xmm2
  // Magnitudes to doubles: (|f| << 29) + (896 << 52).
  movdqu  xmm2, [rip + CAbsMask]
  pand    xmm0, xmm2
  pand    xmm1, xmm2
  movdqu  xmm5, [rip + CBias]
  movdqa  xmm2, xmm0
  punpckldq xmm2, xmm7
  psllq   xmm2, 29
  paddq   xmm2, xmm5              // a0, a1
  punpckhdq xmm0, xmm7
  psllq   xmm0, 29
  paddq   xmm0, xmm5              // a2, a3
  movdqa  xmm3, xmm1
  punpckldq xmm3, xmm7
  psllq   xmm3, 29
  paddq   xmm3, xmm5              // b0, b1
  punpckhdq xmm1, xmm7
  psllq   xmm1, 29
  paddq   xmm1, xmm5              // b2, b3
  mulpd   xmm2, xmm3              // p0, p1 (exact)
  mulpd   xmm0, xmm1              // p2, p3
  // Exponents of the products.
  movdqa  xmm3, xmm2
  psrlq   xmm3, 52
  movdqa  xmm1, xmm0
  psrlq   xmm1, 52
  pshufd  xmm3, xmm3, $08
  pshufd  xmm1, xmm1, $08
  punpcklqdq xmm3, xmm1           // xmm3: exponents
  // Fields: (bits - (896 << 52)) >> 29.
  psubq   xmm2, xmm5
  psrlq   xmm2, 29
  psubq   xmm0, xmm5
  psrlq   xmm0, 29
  pshufd  xmm2, xmm2, $08
  pshufd  xmm0, xmm0, $08
  punpcklqdq xmm2, xmm0           // xmm2: fields
  movdqu  xmm4, [rip + CExpLow]
  pcmpgtd xmm4, xmm3              // xmm4: underflow
  movdqu  xmm1, [rip + CExpHigh]
  pcmpgtd xmm3, xmm1              // xmm3: overflow
  // Magnitude: 7FFFFFFF on overflow, 0 on underflow or a zero operand.
  movdqu  xmm1, [rip + CAbsMask]
  pand    xmm1, xmm3
  movdqa  xmm0, xmm3
  pandn   xmm0, xmm2
  por     xmm1, xmm0
  movdqu  xmm5, ZeroMask
  movdqa  xmm0, xmm4
  por     xmm0, xmm5
  pandn   xmm0, xmm1
  por     xmm0, xmm6
  movdqu  [r8], xmm0
  // Flags where no operand is zero.
  movdqa  xmm0, xmm5
  pandn   xmm0, xmm3              // overflow
  pandn   xmm5, xmm4              // underflow
  movmskps eax, xmm0
  movmskps edx, xmm5
  shl     edx, 4
  or      eax, edx
  mov     [r9], eax
end;

procedure PS2Add4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
var
  ZeroA, ZeroB, Larger, Smaller, SignL: TPS2Reg128;
asm
  .SAVENV XMM6
  .SAVENV XMM7
  // RCX = @A, RDX = @B, R8 = @R, R9 = @Flags
  movdqu  xmm0, [rcx]
  movdqu  xmm1, [rdx]
  pxor    xmm7, xmm7
  // Zero operands (exponent 0).
  movdqu  xmm2, [rip + CExpMask]
  movdqa  xmm3, xmm0
  pand    xmm3, xmm2
  pcmpeqd xmm3, xmm7
  movdqu  ZeroA, xmm3
  movdqa  xmm3, xmm1
  pand    xmm3, xmm2
  pcmpeqd xmm3, xmm7
  movdqu  ZeroB, xmm3
  // L: the larger magnitude (A when equal), M: the other.
  movdqu  xmm2, [rip + CAbsMask]
  movdqa  xmm3, xmm0
  pand    xmm3, xmm2
  movdqa  xmm4, xmm1
  pand    xmm4, xmm2
  pcmpgtd xmm4, xmm3              // |B| > |A|
  movdqa  xmm5, xmm4
  pand    xmm5, xmm1
  movdqa  xmm6, xmm4
  pandn   xmm6, xmm0
  por     xmm5, xmm6              // xmm5: L
  movdqa  xmm6, xmm4
  pand    xmm6, xmm0
  pandn   xmm4, xmm1
  por     xmm6, xmm4              // xmm6: M
  movdqu  Larger, xmm5
  movdqu  xmm2, [rip + CSignMask]
  pand    xmm2, xmm5
  movdqu  SignL, xmm2
  // c = EL - EM - 1: M loses its c lowest mantissa bits (all of it from 24).
  movdqa  xmm0, xmm5
  pslld   xmm0, 1
  psrld   xmm0, 24                // EL
  movdqa  xmm1, xmm6
  pslld   xmm1, 1
  psrld   xmm1, 24                // EM
  psubd   xmm0, xmm1
  movdqu  xmm1, [rip + COne]
  psubd   xmm0, xmm1              // c
  movdqa  xmm2, xmm0
  movdqu  xmm1, [rip + C23]
  pcmpgtd xmm2, xmm1              // xmm2: c > 23 (M' = 0)
  movdqa  xmm1, xmm0
  psrad   xmm1, 31
  pandn   xmm1, xmm0              // max(c, 0)
  movdqu  xmm3, [rip + C127]
  paddd   xmm1, xmm3
  pslld   xmm1, 23
  cvttps2dq xmm1, xmm1            // 2^c (c > 23: masked below)
  pxor    xmm3, xmm3
  psubd   xmm3, xmm1              // -2^c: keeps the bits from c up
  pand    xmm3, xmm6              // M'
  pandn   xmm2, xmm3              // c > 23: 0
  movdqu  Smaller, xmm2
  // L and M' as doubles; a zero M' gives 0.0.
  movdqu  xmm6, [rip + CBias]
  // L0, L1
  movdqu  xmm0, Larger
  movdqu  xmm1, [rip + CAbsMask]
  pand    xmm0, xmm1
  punpckldq xmm0, xmm7
  psllq   xmm0, 29
  paddq   xmm0, xmm6
  movdqu  xmm2, SignL
  punpckldq xmm2, xmm7
  psllq   xmm2, 32
  por     xmm0, xmm2
  // M'0, M'1
  movdqu  xmm3, Smaller
  movdqa  xmm4, xmm3
  pand    xmm4, xmm1
  movdqa  xmm5, xmm4
  pcmpeqd xmm5, xmm7              // M' magnitude zero
  punpckldq xmm4, xmm7
  psllq   xmm4, 29
  paddq   xmm4, xmm6
  punpckldq xmm5, xmm5
  pandn   xmm5, xmm4
  movdqu  xmm2, [rip + CSignMask]
  pand    xmm3, xmm2
  punpckldq xmm3, xmm7
  psllq   xmm3, 32
  por     xmm5, xmm3
  addpd   xmm0, xmm5              // S0, S1 (exact)
  // L2, L3
  movdqu  xmm4, Larger
  pand    xmm4, xmm1
  punpckhdq xmm4, xmm7
  psllq   xmm4, 29
  paddq   xmm4, xmm6
  movdqu  xmm2, SignL
  punpckhdq xmm2, xmm7
  psllq   xmm2, 32
  por     xmm4, xmm2
  // M'2, M'3
  movdqu  xmm3, Smaller
  movdqa  xmm2, xmm3
  pand    xmm2, xmm1
  movdqa  xmm5, xmm2
  pcmpeqd xmm5, xmm7
  punpckhdq xmm2, xmm7
  psllq   xmm2, 29
  paddq   xmm2, xmm6
  punpckhdq xmm5, xmm5
  pandn   xmm5, xmm2
  movdqu  xmm2, [rip + CSignMask]
  pand    xmm3, xmm2
  punpckhdq xmm3, xmm7
  psllq   xmm3, 32
  por     xmm5, xmm3
  addpd   xmm4, xmm5              // S2, S3
  // Magnitudes of the sums.
  movdqu  xmm1, [rip + CAbs64]
  pand    xmm0, xmm1
  pand    xmm4, xmm1
  // Zero sums: +0, no flags.
  movdqa  xmm1, xmm0
  pcmpeqd xmm1, xmm7
  pshufd  xmm2, xmm1, $B1
  pand    xmm1, xmm2
  movdqa  xmm2, xmm4
  pcmpeqd xmm2, xmm7
  pshufd  xmm3, xmm2, $B1
  pand    xmm2, xmm3
  pshufd  xmm1, xmm1, $08
  pshufd  xmm2, xmm2, $08
  punpcklqdq xmm1, xmm2           // xmm1: zero sum
  // Exponents.
  movdqa  xmm2, xmm0
  psrlq   xmm2, 52
  movdqa  xmm3, xmm4
  psrlq   xmm3, 52
  pshufd  xmm2, xmm2, $08
  pshufd  xmm3, xmm3, $08
  punpcklqdq xmm2, xmm3           // xmm2: exponents
  // Fields.
  psubq   xmm0, xmm6
  psrlq   xmm0, 29
  psubq   xmm4, xmm6
  psrlq   xmm4, 29
  pshufd  xmm0, xmm0, $08
  pshufd  xmm4, xmm4, $08
  punpcklqdq xmm0, xmm4           // xmm0: fields
  movdqu  xmm3, [rip + CExpLow]
  pcmpgtd xmm3, xmm2              // xmm3: small (zero sum or underflow)
  movdqu  xmm4, [rip + CExpHigh]
  pcmpgtd xmm2, xmm4              // xmm2: overflow
  // Magnitude: 7FFFFFFF on overflow, 0 when small.
  movdqu  xmm4, [rip + CAbsMask]
  pand    xmm4, xmm2
  movdqa  xmm5, xmm2
  pandn   xmm5, xmm0
  por     xmm4, xmm5
  movdqa  xmm5, xmm3
  pandn   xmm5, xmm4              // xmm5: magnitude
  // L's sign, except for zero sums.
  movdqu  xmm4, SignL
  movdqa  xmm6, xmm1
  pandn   xmm6, xmm4
  por     xmm5, xmm6              // xmm5: result
  pandn   xmm1, xmm3              // xmm1: underflow
  movdqu  Larger, xmm2            // (overflow)
  movdqu  Smaller, xmm1           // (underflow)
  // Zero operands: both -> A and B and sign; only B -> A; only A -> B.
  movdqu  xmm0, ZeroA
  movdqu  xmm3, ZeroB
  movdqu  xmm4, [rcx]
  movdqu  xmm6, [rdx]
  movdqa  xmm7, xmm0
  pand    xmm7, xmm3
  pand    xmm7, xmm4
  pand    xmm7, xmm6
  movdqu  xmm2, [rip + CSignMask]
  pand    xmm7, xmm2              // both zero
  movdqa  xmm4, xmm0
  pandn   xmm4, xmm3
  movdqu  xmm2, [rcx]
  pand    xmm4, xmm2              // only B zero: A
  por     xmm7, xmm4
  movdqa  xmm4, xmm3
  pandn   xmm4, xmm0
  pand    xmm4, xmm6              // only A zero: B
  por     xmm7, xmm4
  por     xmm0, xmm3              // xmm0: a zero operand
  movdqa  xmm4, xmm0
  pandn   xmm4, xmm5
  por     xmm4, xmm7
  movdqu  [r8], xmm4
  // Flags where no operand is zero.
  movdqu  xmm1, Larger
  movdqu  xmm2, Smaller
  movdqa  xmm3, xmm0
  pandn   xmm0, xmm1              // overflow
  pandn   xmm3, xmm2              // underflow
  movmskps eax, xmm0
  movmskps edx, xmm3
  shl     edx, 4
  or      eax, edx
  mov     [r9], eax
end;

{$ELSE}

procedure PS2Mul4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
begin
  Flags := 0;
  for var K := 0 to 3 do
  begin
    var F: Cardinal;
    R.UW[K] := PS2FloatMul(A.UW[K], B.UW[K], F);
    if (F and 1) <> 0 then
      Flags := Flags or (Cardinal(1) shl K);
    if (F and 2) <> 0 then
      Flags := Flags or (Cardinal(16) shl K);
  end;
end;

procedure PS2Add4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
begin
  Flags := 0;
  for var K := 0 to 3 do
  begin
    var F: Cardinal;
    R.UW[K] := PS2FloatAdd(A.UW[K], B.UW[K], F);
    if (F and 1) <> 0 then
      Flags := Flags or (Cardinal(1) shl K);
    if (F and 2) <> 0 then
      Flags := Flags or (Cardinal(16) shl K);
  end;
end;

{$ENDIF}

end.
