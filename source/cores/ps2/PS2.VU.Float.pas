unit PS2.VU.Float;

// PS2 float arithmetic of the VU upper instructions, one field (PS2FloatMul;
// PS2FloatAdd is the FPU's, in PS2.EE.CPU) or four at once (PS2Mul4,
// PS2Add4) with the same results: products of the 24-bit mantissas and sums
// with the adder's single guard bit, both truncated; exponent 0 reads as
// zero, exponent 255 as an ordinary binade; overflow gives the largest value,
// underflow a signed zero. Win64 uses AVX2 when CPU and OS support it:
// guarded normal-range operations can use hardware round-to-zero floats,
// with integer normalization for all other cases. Its SSE2 fallback uses
// doubles (each product and guard-bit sum is exact). Other targets loop over
// the one-field routines.
// Fixed-point conversions use exact SSE2 on Win64; CLIP compares normalized
// integer magnitudes. The scalar interpreter remains an independent reference.
//
// Four-field flags: bit K overflow and bit K + 4 underflow of field K.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.Math, PS2.Types;

type
  TPS2RegisterMath = (vrmAdd, vrmMul);

// A * B; Flags: 1 overflow, 2 underflow.
function PS2FloatMul(A, B: Cardinal; out Flags: Cardinal): Cardinal;
// R = A * B and R = A + B for four fields.
procedure PS2Mul4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
procedure PS2Add4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
// Fixed-point conversions, Shift = 0, 4, 12 or 15. ITOF follows the host
// rounding mode just like the reference Single assignment; FTOI truncates
// and saturates. Exponent 255 remains finite and exponent 0 reads as zero.
procedure PS2Itof4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
procedure PS2Ftoi4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
// Six CLIP comparison bits for A.xyz against abs(B.w), without host floats.
procedure PS2Clip3(const A, B: TPS2Reg128; out Bits: Cardinal);
// Host backend selected at initialization (CPUID and OS vector-state checks).
function PS2VectorAVX2: Boolean;
// Optional exact register ABI for HW.JIT.VectorCall: xmm0/xmm1 inputs,
// xmm0 result, return value = MAC-style underflow/overflow groups (8..15).
// All inputs/rounding modes are supported; the scalar path is unchanged.
function PS2RegisterMathNative(Kind: TPS2RegisterMath): Pointer;
// The same for the host rounding the caller runs under (truncation and
// rounding to nearest have fast paths, others the exact routine at once).
function PS2RegisterMathNativeFor(Kind: TPS2RegisterMath; Mode: TRoundingMode): Pointer;
function PS2RegisterMathModel(Kind: TPS2RegisterMath): Pointer;
// Whether the AVX-512 forms of the rounding-to-nearest fast paths are used
// (AVX-512F/DQ/VL and the OS's ZMM state; tests may turn them off).
function PS2VectorAVX512: Boolean;
procedure PS2UseAVX512(Value: Boolean);

implementation

uses
  PS2.EE.CPU;

var
  VectorAVX2, VectorFMA, VectorAVX512, HostHasAVX512: Boolean;

function PS2VectorAVX2: Boolean;
begin
  Result := VectorAVX2;
end;

function PS2VectorAVX512: Boolean;
begin
  Result := VectorAVX512;
end;

procedure PS2UseAVX512(Value: Boolean);
begin
  VectorAVX512 := Value and HostHasAVX512;
end;

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

procedure PS2Clip3(const A, B: TPS2Reg128; out Bits: Cardinal);
begin
  var Limit := B.UW[3] and $7FFFFFFF;
  if Limit and $7F800000 = 0 then Limit := 0;
  var Result: Cardinal := 0;
  for var K := 0 to 2 do
  begin
    var V := A.UW[K];
    if (V and $7F800000) = 0 then Continue;
    if (V and $7FFFFFFF) > Limit then
      Result := Result or (Cardinal(1) shl (K * 2 + Integer(V shr 31)));
  end;
  Bits := Result;
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
  CMantissa: array[0..3] of Cardinal = ($7FFFFF, $7FFFFF, $7FFFFF, $7FFFFF);
  CHidden: array[0..3] of Cardinal = ($800000, $800000, $800000, $800000);
  CNot3: array[0..3] of Cardinal = ($FFFFFFFC, $FFFFFFFC, $FFFFFFFC, $FFFFFFFC);
  C26: array[0..3] of Integer = (26, 26, 26, 26);
  C255: array[0..3] of Integer = (255, 255, 255, 255);
  C253: array[0..3] of Integer = (253, 253, 253, 253);
  C252: array[0..3] of Integer = (252, 252, 252, 252);
  // Exponent fields (shifted to bits 23..30).
  C252Field: array[0..3] of Cardinal = (252 shl 23, 252 shl 23, 252 shl 23, 252 shl 23);
  C64Field: array[0..3] of Cardinal = (64 shl 23, 64 shl 23, 64 shl 23, 64 shl 23);
  C64: array[0..3] of Integer = (64, 64, 64, 64);
  C254: array[0..3] of Integer = (254, 254, 254, 254);
  C25: array[0..3] of Integer = (25, 25, 25, 25);
  CShift23: array[0..1] of UInt64 = (23, 23);
  CIntMin: array[0..1] of Double = (-2147483648.0, -2147483648.0);
  CIntMax: array[0..1] of Double = (2147483647.0, 2147483647.0);

procedure PS2Itof4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
asm
  .NOFRAME
  // Integer -> Single rounding commutes with this exact power-of-two scale:
  // all supported results remain normal, including the smallest nonzero one.
  movdqu xmm0, [rcx]
  cvtdq2ps xmm0, xmm0
  mov eax, 127
  sub eax, edx
  shl eax, 23
  movd xmm1, eax
  pshufd xmm1, xmm1, 0
  mulps xmm0, xmm1
  movdqu [r8], xmm0
end;

procedure PS2Ftoi4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
asm
  .NOFRAME
  movdqu xmm0, [rcx]
  movdqa xmm1, xmm0
  movdqu xmm4, [rip + CAbsMask]
  pand xmm0, xmm4
  movdqu xmm4, [rip + CSignMask]
  pand xmm1, xmm4
  pxor xmm5, xmm5
  movdqa xmm2, xmm0
  punpckldq xmm2, xmm5
  punpckhdq xmm0, xmm5
  movdqa xmm3, xmm1
  punpckldq xmm3, xmm5
  punpckhdq xmm1, xmm5
  psllq xmm2, 29
  psllq xmm0, 29
  psllq xmm3, 32
  psllq xmm1, 32
  // Reconstruct exact finite doubles, including PS2 exponent 255. Scaling
  // changes only the exponent; no approximate host-float conversion is used.
  mov eax, edx
  add eax, 896
  shl rax, 52
  movq xmm4, rax
  punpcklqdq xmm4, xmm4
  paddq xmm2, xmm4
  paddq xmm0, xmm4
  por xmm2, xmm3
  por xmm0, xmm1
  movdqu xmm1, [rcx]
  movdqu xmm4, [rip + CExpMask]
  pand xmm1, xmm4
  pcmpeqd xmm1, xmm5
  movdqa xmm3, xmm1
  punpckldq xmm3, xmm3
  punpckhdq xmm1, xmm1
  pandn xmm3, xmm2
  pandn xmm1, xmm0
  movupd xmm4, [rip + CIntMin]
  maxpd xmm3, xmm4
  maxpd xmm1, xmm4
  movupd xmm4, [rip + CIntMax]
  minpd xmm3, xmm4
  minpd xmm1, xmm4
  cvttpd2dq xmm3, xmm3
  cvttpd2dq xmm1, xmm1
  punpcklqdq xmm3, xmm1
  movdqu [r8], xmm3
end;

procedure PS2Mul4SSE2(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
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

procedure PS2Add4SSE2(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
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

// AVX2 permits a different integer shift count in every field. Keep the
// PS2 mantissas as integers instead of expanding four fields to doubles.
procedure PS2Mul4AVX2(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .SAVENV XMM6
  .SAVENV XMM7
  .SAVENV XMM8
  .SAVENV XMM9
  // RCX = A, RDX = B, R8 = result, R9 = flags.
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpxor xmm9, xmm9, xmm9
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, xmm9
  vpcmpeqd xmm6, xmm3, xmm9
  vpor xmm4, xmm4, xmm6                // zero operand
  vpxor xmm5, xmm0, xmm1
  vpand xmm5, xmm5, [rip + CSignMask]
  vpand xmm0, xmm0, [rip + CMantissa]
  vpand xmm1, xmm1, [rip + CMantissa]
  vpor xmm0, xmm0, [rip + CHidden]
  vpor xmm1, xmm1, [rip + CHidden]
  vpmuludq xmm6, xmm0, xmm1            // exact 48-bit products, fields 0,2
  vpsrldq xmm0, xmm0, 4
  vpsrldq xmm1, xmm1, 4
  vpmuludq xmm0, xmm0, xmm1            // fields 1,3
  vpsrlq xmm7, xmm6, 47
  vpsrlq xmm1, xmm0, 47                // normalization carry
  vpaddq xmm8, xmm7, [rip + CShift23]
  vpaddq xmm9, xmm1, [rip + CShift23]
  vpsrlvq xmm6, xmm6, xmm8
  vpsrlvq xmm0, xmm0, xmm9
  vpsllq xmm0, xmm0, 32
  vpor xmm6, xmm6, xmm0                // four normalized mantissas
  vpsllq xmm1, xmm1, 32
  vpor xmm7, xmm7, xmm1                // four carries
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vpaddd xmm2, xmm2, xmm7              // result exponents
  vpand xmm6, xmm6, [rip + CMantissa]
  vpslld xmm3, xmm2, 23
  vpor xmm6, xmm6, xmm3
  vpcmpgtd xmm7, xmm2, [rip + C255]     // overflow
  vmovdqu xmm8, [rip + COne]
  vpcmpgtd xmm8, xmm8, xmm2            // underflow
  vpand xmm0, xmm7, [rip + CAbsMask]
  vpandn xmm1, xmm7, xmm6
  vpor xmm6, xmm0, xmm1                // saturate overflow
  vpor xmm9, xmm8, xmm4
  vpandn xmm6, xmm9, xmm6              // underflow/zero operand -> zero
  vpor xmm6, xmm6, xmm5                // signed, including signed zero
  vpandn xmm7, xmm4, xmm7
  vpandn xmm8, xmm4, xmm8              // zero operands do not set flags
  vmovdqu [r8], xmm6
  vmovmskps eax, xmm7
  vmovmskps edx, xmm8
  shl edx, 4
  or eax, edx
  mov [r9], eax
  vzeroupper
end;

procedure PS2Add4AVX2(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .SAVENV XMM6
  .SAVENV XMM7
  .SAVENV XMM8
  .SAVENV XMM9
  .SAVENV XMM10
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2            // |B| > |A|
  vpxor xmm4, xmm0, xmm1
  vpsrad xmm4, xmm4, 31               // opposite signs
  vpand xmm5, xmm3, xmm1
  vpandn xmm6, xmm3, xmm0
  vpor xmm5, xmm5, xmm6                // larger magnitude first (L)
  vpand xmm6, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm6, xmm6, xmm3                // smaller (M)
  vpslld xmm7, xmm5, 1
  vpsrld xmm7, xmm7, 24                // EL
  vpslld xmm8, xmm6, 1
  vpsrld xmm8, xmm8, 24                // EM
  vpand xmm9, xmm5, [rip + CSignMask]
  vpand xmm5, xmm5, [rip + CMantissa]
  vpand xmm6, xmm6, [rip + CMantissa]
  vpor xmm5, xmm5, [rip + CHidden]
  vpor xmm6, xmm6, [rip + CHidden]
  vpslld xmm5, xmm5, 3
  vpslld xmm6, xmm6, 3
  vpsubd xmm8, xmm7, xmm8
  vpsrlvd xmm6, xmm6, xmm8             // shifted-out bits are discarded
  vpand xmm6, xmm6, [rip + CNot3]      // one guard bit, no sticky bit
  vpaddd xmm8, xmm5, xmm6
  vpsubd xmm5, xmm5, xmm6
  vpand xmm5, xmm5, xmm4
  vpandn xmm4, xmm4, xmm8
  vpor xmm5, xmm5, xmm4                // unsigned magnitude of the sum
  vpxor xmm0, xmm0, xmm0
  vpcmpeqd xmm10, xmm5, xmm0           // exact cancellation

  // Find the leading bit. Integer-to-float conversion can round across a
  // power of two under some host rounding modes: detect and correct it.
  // No rounded mantissa is used in the result.
  vcvtdq2ps xmm6, xmm5
  vpsrld xmm6, xmm6, 23
  vpsubd xmm6, xmm6, [rip + C127]
  vmovdqu xmm8, [rip + COne]
  vpsllvd xmm8, xmm8, xmm6
  vpcmpgtd xmm8, xmm8, xmm5
  vpaddd xmm6, xmm6, xmm8              // subtract one if conversion carried
  vpsubd xmm6, xmm6, [rip + C26]
  vpaddd xmm7, xmm7, xmm6              // normalized exponent
  vpsubd xmm8, xmm0, xmm6
  vpsllvd xmm8, xmm5, xmm8
  vpsrlvd xmm5, xmm5, xmm6
  vpor xmm5, xmm5, xmm8                // normalize without losing guard bits
  vpsrld xmm5, xmm5, 3
  vpand xmm5, xmm5, [rip + CMantissa]
  vpslld xmm6, xmm7, 23
  vpor xmm5, xmm5, xmm6
  vpcmpgtd xmm8, xmm7, [rip + C255]     // overflow
  vmovdqu xmm6, [rip + COne]
  vpcmpgtd xmm6, xmm6, xmm7            // small exponent
  vpand xmm0, xmm8, [rip + CAbsMask]
  vpandn xmm5, xmm8, xmm5
  vpor xmm5, xmm5, xmm0
  vpor xmm0, xmm6, xmm10
  vpandn xmm5, xmm0, xmm5
  vpandn xmm0, xmm10, xmm9
  vpor xmm5, xmm5, xmm0                // cancellation is +0; underflow keeps sign
  vpandn xmm6, xmm10, xmm6             // cancellation does not underflow

  // Exponent-zero inputs are signed zeros, including their subnormal bits.
  // With only one zero operand, the other operand is returned unchanged.
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm2, xmm2, xmm4            // A zero
  vpcmpeqd xmm3, xmm3, xmm4            // B zero
  vpor xmm4, xmm2, xmm3               // either zero
  vpand xmm9, xmm2, xmm3
  vpand xmm9, xmm9, xmm0
  vpand xmm9, xmm9, xmm1
  vpand xmm9, xmm9, [rip + CSignMask]  // both zero
  vpandn xmm10, xmm3, xmm2
  vpand xmm10, xmm10, xmm1             // only A zero -> B
  vpandn xmm2, xmm2, xmm3
  vpand xmm2, xmm2, xmm0               // only B zero -> A
  vpor xmm9, xmm9, xmm10
  vpor xmm9, xmm9, xmm2
  vpandn xmm5, xmm4, xmm5
  vpor xmm5, xmm5, xmm9
  vpandn xmm6, xmm4, xmm6
  vpandn xmm8, xmm4, xmm8
  vmovdqu [r8], xmm5
  vmovmskps eax, xmm8
  vmovmskps edx, xmm6
  shl edx, 4
  or eax, edx
  mov [r9], eax
  vzeroupper
end;

// Common normal-range cases need no integer normalization: hardware
// operations rounded toward zero are exact PS2 operations once the smaller
// addend loses all bits below the PS2 guard bit. Coarse exponent guards
// exclude any possible overflow/underflow; exponent-zero inputs are first
// made signed zeros. Where the host rounds to nearest, the host result is
// corrected as in MulRegistersRN/AddRegistersRN. Other cases and roundings
// use the integer kernels above. These are leaf entries, so no nonvolatile
// vector registers need saving.
procedure PS2Mul4Common(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .NOFRAME
  stmxcsr [rsp + 8]                    // caller-provided Win64 shadow space
  mov eax, [rsp + 8]
  and eax, $6000
  cmp eax, $6000
  je @@RZ
  // Rounding to nearest: as MulRegistersRN (FMA3 for the product's error).
  test eax, eax
  jnz @@Slow
  cmp byte ptr [rip + VectorFMA], 0
  je @@Slow
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, [rip + C255]
  vpcmpeqd xmm5, xmm3, [rip + C255]
  vpor xmm4, xmm4, xmm5
  vptest xmm4, xmm4
  jnz @@Slow
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm5, xmm2, xmm4
  vpand xmm4, xmm5, [rip + CAbsMask]
  vpandn xmm0, xmm4, xmm0
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm4, xmm3, xmm4
  vpor xmm5, xmm5, xmm4
  vpand xmm4, xmm4, [rip + CAbsMask]
  vpandn xmm1, xmm4, xmm1
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vmovdqu xmm3, [rip + C64]
  vpcmpgtd xmm3, xmm3, xmm2
  vpcmpgtd xmm4, xmm2, [rip + C252]
  vpor xmm3, xmm3, xmm4
  vpandn xmm5, xmm5, xmm3
  vptest xmm5, xmm5
  jnz @@Slow
  vmulps xmm2, xmm0, xmm1
  vmovaps xmm3, xmm2
  vfmsub231ps xmm3, xmm0, xmm1         // error: A * B - product, exact
  vxorps xmm4, xmm3, xmm2
  vpsrad xmm4, xmm4, 31                // error and product of opposite signs
  vpand xmm5, xmm3, [rip + CAbsMask]
  vpxor xmm0, xmm0, xmm0
  vpcmpeqd xmm5, xmm5, xmm0
  vpandn xmm4, xmm5, xmm4              // ... and an error at all
  vpaddd xmm0, xmm2, xmm4              // one unit toward zero there
  vmovdqu [r8], xmm0
  mov dword ptr [r9], 0
  vzeroupper
  ret
@@RZ:
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, [rip + C255]
  vpcmpeqd xmm5, xmm3, [rip + C255]
  vpor xmm4, xmm4, xmm5
  vptest xmm4, xmm4
  jnz @@Slow                          // PS2 exponent 255 is not IEEE NaN/Inf
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm5, xmm2, xmm4
  vpandn xmm0, xmm5, xmm0
  vmovdqu xmm4, [rcx]
  vpand xmm4, xmm4, [rip + CSignMask]
  vpor xmm0, xmm0, xmm4                // A's subnormals -> signed zero
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm4, xmm3, xmm4
  vpor xmm5, xmm5, xmm4                // either input zero
  vpandn xmm1, xmm4, xmm1
  vmovdqu xmm4, [rdx]
  vpand xmm4, xmm4, [rip + CSignMask]
  vpor xmm1, xmm1, xmm4
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]      // exponent before normalization carry
  vmovdqu xmm3, [rip + COne]
  vpcmpgtd xmm3, xmm3, xmm2
  vpcmpgtd xmm4, xmm2, [rip + C253]
  vpor xmm3, xmm3, xmm4
  vpandn xmm5, xmm5, xmm3              // nonzero product outside safe range
  vptest xmm5, xmm5
  jnz @@Slow
  vmulps xmm0, xmm0, xmm1
  vmovdqu [r8], xmm0
  mov dword ptr [r9], 0
  vzeroupper
  ret
@@Slow:
  jmp PS2Mul4AVX2
end;

procedure PS2Add4Common(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .NOFRAME
  stmxcsr [rsp + 8]
  mov eax, [rsp + 8]
  and eax, $6000
  cmp eax, $6000
  je @@RZ
  // Rounding to nearest: as AddRegistersRN (Fast2Sum for the sum's error).
  test eax, eax
  jnz @@Slow
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpmaxsd xmm4, xmm2, xmm3
  vpcmpgtd xmm5, xmm4, [rip + C252]
  vptest xmm5, xmm5
  jnz @@Slow
  vmovdqu xmm5, [rip + C64]
  vpcmpgtd xmm5, xmm5, xmm4
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm2, xmm2, xmm3
  vpcmpeqd xmm2, xmm2, xmm4
  vpandn xmm5, xmm2, xmm5
  vptest xmm5, xmm5
  jnz @@Slow
  vpand xmm2, xmm0, [rip + CExpMask]
  vpcmpeqd xmm2, xmm2, xmm4
  vpand xmm2, xmm2, [rip + CAbsMask]
  vpandn xmm0, xmm2, xmm0
  vpand xmm3, xmm1, [rip + CExpMask]
  vpcmpeqd xmm3, xmm3, xmm4
  vpand xmm3, xmm3, [rip + CAbsMask]
  vpandn xmm1, xmm3, xmm1
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2
  vpand xmm2, xmm3, xmm1
  vpandn xmm4, xmm3, xmm0
  vpor xmm2, xmm2, xmm4
  vpand xmm4, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm3, xmm3, xmm4
  vpslld xmm0, xmm2, 1
  vpsrld xmm0, xmm0, 24
  vpslld xmm1, xmm3, 1
  vpsrld xmm1, xmm1, 24
  vpsubd xmm0, xmm0, xmm1
  vpsubd xmm0, xmm0, [rip + COne]
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm0, xmm0, xmm4
  vmovdqu xmm1, [rip + COne]
  vpsllvd xmm1, xmm1, xmm0
  vpsubd xmm1, xmm4, xmm1
  vpand xmm3, xmm3, xmm1
  vpcmpgtd xmm0, xmm0, [rip + C23]
  vpandn xmm3, xmm0, xmm3
  vaddps xmm0, xmm2, xmm3              // sum of the larger and the smaller
  vsubps xmm1, xmm0, xmm2
  vsubps xmm1, xmm3, xmm1              // error, exact (Fast2Sum)
  vxorps xmm4, xmm1, xmm0
  vpsrad xmm4, xmm4, 31
  vpand xmm5, xmm1, [rip + CAbsMask]
  vpxor xmm2, xmm2, xmm2
  vpcmpeqd xmm5, xmm5, xmm2
  vpandn xmm4, xmm5, xmm4
  vpaddd xmm0, xmm0, xmm4
  vmovdqu [r8], xmm0
  mov dword ptr [r9], 0
  vzeroupper
  ret
@@RZ:
  vmovdqu xmm0, [rcx]
  vmovdqu xmm1, [rdx]
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpmaxsd xmm4, xmm2, xmm3
  vpcmpgtd xmm5, xmm4, [rip + C253]
  vptest xmm5, xmm5
  jnz @@Slow                          // a sum may raise the exponent by one
  // The smallest nonzero cancellation is half an ulp of the larger input.
  // EL >= 25 guarantees it is normal. Two zero inputs are safe too.
  vmovdqu xmm5, [rip + C25]
  vpcmpgtd xmm5, xmm5, xmm4
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm2, xmm2, xmm3
  vpcmpeqd xmm2, xmm2, xmm4
  vpandn xmm5, xmm2, xmm5
  vptest xmm5, xmm5
  jnz @@Slow
  // Sanitize each zero-exponent operand, preserving its sign.
  vpand xmm2, xmm0, [rip + CExpMask]
  vpcmpeqd xmm2, xmm2, xmm4
  vpandn xmm0, xmm2, xmm0
  vmovdqu xmm2, [rcx]
  vpand xmm2, xmm2, [rip + CSignMask]
  vpor xmm0, xmm0, xmm2
  vpand xmm3, xmm1, [rip + CExpMask]
  vpcmpeqd xmm3, xmm3, xmm4
  vpandn xmm1, xmm3, xmm1
  vmovdqu xmm3, [rdx]
  vpand xmm3, xmm3, [rip + CSignMask]
  vpor xmm1, xmm1, xmm3
  // L = larger magnitude; M = smaller (A stays L when equal).
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2
  vpand xmm2, xmm3, xmm1
  vpandn xmm4, xmm3, xmm0
  vpor xmm2, xmm2, xmm4                // L
  vpand xmm4, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm3, xmm3, xmm4                // M
  vpslld xmm0, xmm2, 1
  vpsrld xmm0, xmm0, 24
  vpslld xmm1, xmm3, 1
  vpsrld xmm1, xmm1, 24
  vpsubd xmm0, xmm0, xmm1
  vpsubd xmm0, xmm0, [rip + COne]
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm0, xmm0, xmm4             // max(EL - EM - 1, 0)
  vmovdqu xmm1, [rip + COne]
  vpsllvd xmm1, xmm1, xmm0
  vpsubd xmm1, xmm4, xmm1              // -2^shift: mask below guard bit
  vpand xmm3, xmm3, xmm1
  vpcmpgtd xmm0, xmm0, [rip + C23]
  vpandn xmm3, xmm0, xmm3              // beyond the guard bit -> zero
  vaddps xmm2, xmm2, xmm3
  vmovdqu [r8], xmm2
  mov dword ptr [r9], 0
  vzeroupper
  ret
@@Slow:
  jmp PS2Add4AVX2
end;

function RegisterMulExact(Context: Pointer): NativeUInt; forward;
function RegisterAddExact(Context: Pointer): NativeUInt; forward;

// MulRegisters and AddRegisters where the host rounds toward zero (the
// caller has checked): the fast path's host arithmetic rounds as the PS2's.
function MulRegistersRZ(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, [rip + C255]
  vpcmpeqd xmm5, xmm3, [rip + C255]
  vpor xmm4, xmm4, xmm5
  vptest xmm4, xmm4
  jnz @@No
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm5, xmm2, xmm4
  vpand xmm4, xmm5, [rip + CAbsMask]
  vpandn xmm0, xmm4, xmm0
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm4, xmm3, xmm4
  vpor xmm5, xmm5, xmm4
  vpand xmm4, xmm4, [rip + CAbsMask]
  vpandn xmm1, xmm4, xmm1
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vmovdqu xmm3, [rip + COne]
  vpcmpgtd xmm3, xmm3, xmm2
  vpcmpgtd xmm4, xmm2, [rip + C253]
  vpor xmm3, xmm3, xmm4
  vpandn xmm5, xmm5, xmm3
  vptest xmm5, xmm5
  jnz @@No
  vmulps xmm0, xmm0, xmm1
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterMulExact
end;

function AddRegistersRZ(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpmaxsd xmm4, xmm2, xmm3
  vpcmpgtd xmm5, xmm4, [rip + C253]
  vptest xmm5, xmm5
  jnz @@No
  vmovdqu xmm5, [rip + C25]
  vpcmpgtd xmm5, xmm5, xmm4
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm2, xmm2, xmm3
  vpcmpeqd xmm2, xmm2, xmm4
  vpandn xmm5, xmm2, xmm5
  vptest xmm5, xmm5
  jnz @@No
  vpand xmm2, xmm0, [rip + CExpMask]
  vpcmpeqd xmm2, xmm2, xmm4
  vpand xmm2, xmm2, [rip + CAbsMask]
  vpandn xmm0, xmm2, xmm0
  vpand xmm3, xmm1, [rip + CExpMask]
  vpcmpeqd xmm3, xmm3, xmm4
  vpand xmm3, xmm3, [rip + CAbsMask]
  vpandn xmm1, xmm3, xmm1
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2
  vpand xmm2, xmm3, xmm1
  vpandn xmm4, xmm3, xmm0
  vpor xmm2, xmm2, xmm4
  vpand xmm4, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm3, xmm3, xmm4
  vpslld xmm0, xmm2, 1
  vpsrld xmm0, xmm0, 24
  vpslld xmm1, xmm3, 1
  vpsrld xmm1, xmm1, 24
  vpsubd xmm0, xmm0, xmm1
  vpsubd xmm0, xmm0, [rip + COne]
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm0, xmm0, xmm4
  vmovdqu xmm1, [rip + COne]
  vpsllvd xmm1, xmm1, xmm0
  vpsubd xmm1, xmm4, xmm1
  vpand xmm3, xmm3, xmm1
  vpcmpgtd xmm0, xmm0, [rip + C23]
  vpandn xmm3, xmm0, xmm3
  vaddps xmm0, xmm2, xmm3
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterAddExact
end;

// MulRegistersRZ and AddRegistersRZ where the host rounds to nearest: the
// host result, then one unit toward zero where it was rounded away from
// zero, is the truncated result. Exponents are kept where every value
// involved is normal and finite whatever FTZ/DAZ say (the rest: the exact
// routines). The product's error is exact by FMA (MulRegistersRN needs the
// host's FMA3), the sum's by Fast2Sum (the larger magnitude first).
function MulRegistersRN(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, [rip + C255]
  vpcmpeqd xmm5, xmm3, [rip + C255]
  vpor xmm4, xmm4, xmm5
  vptest xmm4, xmm4
  jnz @@No
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm5, xmm2, xmm4
  vpand xmm4, xmm5, [rip + CAbsMask]
  vpandn xmm0, xmm4, xmm0
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm4, xmm3, xmm4
  vpor xmm5, xmm5, xmm4
  vpand xmm4, xmm4, [rip + CAbsMask]
  vpandn xmm1, xmm4, xmm1
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vmovdqu xmm3, [rip + C64]
  vpcmpgtd xmm3, xmm3, xmm2
  vpcmpgtd xmm4, xmm2, [rip + C252]
  vpor xmm3, xmm3, xmm4
  vpandn xmm5, xmm5, xmm3
  vptest xmm5, xmm5
  jnz @@No
  vmulps xmm2, xmm0, xmm1
  vmovaps xmm3, xmm2
  vfmsub231ps xmm3, xmm0, xmm1         // error: A * B - product, exact
  vxorps xmm4, xmm3, xmm2
  vpsrad xmm4, xmm4, 31                // error and product of opposite signs
  vpand xmm5, xmm3, [rip + CAbsMask]
  vpxor xmm0, xmm0, xmm0
  vpcmpeqd xmm5, xmm5, xmm0
  vpandn xmm4, xmm5, xmm4              // ... and an error at all
  vpaddd xmm0, xmm2, xmm4              // one unit toward zero there
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterMulExact
end;

function AddRegistersRN(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpmaxsd xmm4, xmm2, xmm3
  vpcmpgtd xmm5, xmm4, [rip + C252]
  vptest xmm5, xmm5
  jnz @@No
  vmovdqu xmm5, [rip + C64]
  vpcmpgtd xmm5, xmm5, xmm4
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm2, xmm2, xmm3
  vpcmpeqd xmm2, xmm2, xmm4
  vpandn xmm5, xmm2, xmm5
  vptest xmm5, xmm5
  jnz @@No
  vpand xmm2, xmm0, [rip + CExpMask]
  vpcmpeqd xmm2, xmm2, xmm4
  vpand xmm2, xmm2, [rip + CAbsMask]
  vpandn xmm0, xmm2, xmm0
  vpand xmm3, xmm1, [rip + CExpMask]
  vpcmpeqd xmm3, xmm3, xmm4
  vpand xmm3, xmm3, [rip + CAbsMask]
  vpandn xmm1, xmm3, xmm1
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2
  vpand xmm2, xmm3, xmm1
  vpandn xmm4, xmm3, xmm0
  vpor xmm2, xmm2, xmm4
  vpand xmm4, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm3, xmm3, xmm4
  vpslld xmm0, xmm2, 1
  vpsrld xmm0, xmm0, 24
  vpslld xmm1, xmm3, 1
  vpsrld xmm1, xmm1, 24
  vpsubd xmm0, xmm0, xmm1
  vpsubd xmm0, xmm0, [rip + COne]
  vpxor xmm4, xmm4, xmm4
  vpmaxsd xmm0, xmm0, xmm4
  vmovdqu xmm1, [rip + COne]
  vpsllvd xmm1, xmm1, xmm0
  vpsubd xmm1, xmm4, xmm1
  vpand xmm3, xmm3, xmm1
  vpcmpgtd xmm0, xmm0, [rip + C23]
  vpandn xmm3, xmm0, xmm3
  vaddps xmm0, xmm2, xmm3              // sum of the larger and the smaller
  vsubps xmm1, xmm0, xmm2
  vsubps xmm1, xmm3, xmm1              // error, exact (Fast2Sum)
  vxorps xmm4, xmm1, xmm0
  vpsrad xmm4, xmm4, 31
  vpand xmm5, xmm1, [rip + CAbsMask]
  vpxor xmm2, xmm2, xmm2
  vpcmpeqd xmm5, xmm5, xmm2
  vpandn xmm4, xmm5, xmm4
  vpaddd xmm0, xmm0, xmm4
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterAddExact
end;
// MulRegistersRN and AddRegistersRN with AVX-512 (both still for a host
// rounding to nearest): the same fast-path tests, then the operation rounds
// toward zero itself (embedded rounding) rather than correcting the host's
// result; blends and three-input logic for the operand selection.
function MulRegistersRN512(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpcmpeqd xmm4, xmm2, [rip + CExpMask]
  vpcmpeqd xmm5, xmm3, [rip + CExpMask]
  vpor xmm4, xmm4, xmm5
  vptest xmm4, xmm4                    // an exponent 255
  jnz @@No
  vpxor xmm5, xmm5, xmm5
  vpcmpeqd xmm4, xmm2, xmm5            // exponent 0: zero, its sign kept
  vpternlogd xmm0, xmm4, [rip + CSignMask], $B0
  vpcmpeqd xmm5, xmm3, xmm5
  vpternlogd xmm1, xmm5, [rip + CSignMask], $B0
  vpor xmm4, xmm4, xmm5                // either operand zero
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vpcmpgtd xmm3, xmm2, [rip + C252]
  vmovdqu xmm5, [rip + C64]
  vpcmpgtd xmm5, xmm5, xmm2
  vpor xmm3, xmm3, xmm5
  vpandn xmm3, xmm4, xmm3              // the product's exponent out of range
  vptest xmm3, xmm3
  jnz @@No
  // vmulps zmm0, zmm0, zmm1, {rz-sae} (the assembler omits the rounding).
  db $62, $F1, $7C, $78, $59, $C1
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterMulExact
end;

function AddRegistersRN512(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpmaxud xmm4, xmm2, xmm3
  vpcmpud k1, xmm4, [rip + C252Field], 6   // the larger exponent above 252
  vptestmd k2, xmm4, xmm4
  vpcmpud k3, xmm4, [rip + C64Field], 1    // or below 64 (not both 0)
  kandw k3, k3, k2
  korw k1, k1, k3
  kortestw k1, k1
  jnz @@No
  vpxor xmm5, xmm5, xmm5
  vpcmpeqd xmm4, xmm2, xmm5            // exponent 0: zero, its sign kept
  vpternlogd xmm0, xmm4, [rip + CSignMask], $B0
  vpcmpeqd xmm4, xmm3, xmm5
  vpternlogd xmm1, xmm4, [rip + CSignMask], $B0
  vpand xmm4, xmm0, [rip + CAbsMask]
  vpand xmm5, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm5, xmm5, xmm4            // B the larger magnitude
  vblendvps xmm4, xmm0, xmm1, xmm5     // the larger, L
  vblendvps xmm0, xmm1, xmm0, xmm5     // the smaller, S
  vblendvps xmm1, xmm2, xmm3, xmm5     // their exponent fields
  vblendvps xmm2, xmm3, xmm2, xmm5
  vpsubd xmm1, xmm1, xmm2
  vpsrld xmm1, xmm1, 23
  vpsubd xmm1, xmm1, [rip + COne]
  vpxor xmm2, xmm2, xmm2
  vpmaxsd xmm1, xmm1, xmm2             // D: S's bits below L's guard bit
  vpcmpgtd xmm2, xmm1, [rip + C23]     // all of S where D > 23
  vpcmpeqd xmm3, xmm3, xmm3
  vpsllvd xmm3, xmm3, xmm1
  vpternlogd xmm0, xmm3, xmm2, $40     // S and (-1 shl D), not where D > 23
  // vaddps zmm0, zmm4, zmm0, {rz-sae}
  db $62, $F1, $5C, $78, $58, $C0
  xor eax, eax
  vzeroupper
  ret
@@No:
  vzeroupper
  jmp RegisterAddExact
end;

function MulRegisters(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  stmxcsr [rsp + 8]
  mov eax, [rsp + 8]
  and eax, $6000
  cmp eax, $6000
  jne @@No
  jmp MulRegistersRZ
@@No:
  jmp RegisterMulExact
end;

function AddRegisters(Context: Pointer): NativeUInt;
asm
  .NOFRAME
  stmxcsr [rsp + 8]
  mov eax, [rsp + 8]
  and eax, $6000
  cmp eax, $6000
  jne @@No
  jmp AddRegistersRZ
@@No:
  jmp RegisterAddExact
end;

function RegisterMulExact(Context: Pointer): NativeUInt;
asm
  .SAVENV XMM6
  .SAVENV XMM7
  .SAVENV XMM8
  .SAVENV XMM9
  vpxor xmm9, xmm9, xmm9
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpsrld xmm2, xmm2, 23
  vpsrld xmm3, xmm3, 23
  vpcmpeqd xmm4, xmm2, xmm9
  vpcmpeqd xmm6, xmm3, xmm9
  vpor xmm4, xmm4, xmm6
  vpxor xmm5, xmm0, xmm1
  vpand xmm5, xmm5, [rip + CSignMask]
  vpand xmm0, xmm0, [rip + CMantissa]
  vpand xmm1, xmm1, [rip + CMantissa]
  vpor xmm0, xmm0, [rip + CHidden]
  vpor xmm1, xmm1, [rip + CHidden]
  vpmuludq xmm6, xmm0, xmm1
  vpsrldq xmm0, xmm0, 4
  vpsrldq xmm1, xmm1, 4
  vpmuludq xmm0, xmm0, xmm1
  vpsrlq xmm7, xmm6, 47
  vpsrlq xmm1, xmm0, 47
  vpaddq xmm8, xmm7, [rip + CShift23]
  vpaddq xmm9, xmm1, [rip + CShift23]
  vpsrlvq xmm6, xmm6, xmm8
  vpsrlvq xmm0, xmm0, xmm9
  vpsllq xmm0, xmm0, 32
  vpor xmm6, xmm6, xmm0
  vpsllq xmm1, xmm1, 32
  vpor xmm7, xmm7, xmm1
  vpaddd xmm2, xmm2, xmm3
  vpsubd xmm2, xmm2, [rip + C127]
  vpaddd xmm2, xmm2, xmm7
  vpand xmm6, xmm6, [rip + CMantissa]
  vpslld xmm3, xmm2, 23
  vpor xmm6, xmm6, xmm3
  vpcmpgtd xmm7, xmm2, [rip + C255]
  vmovdqu xmm8, [rip + COne]
  vpcmpgtd xmm8, xmm8, xmm2
  vpand xmm0, xmm7, [rip + CAbsMask]
  vpandn xmm1, xmm7, xmm6
  vpor xmm6, xmm0, xmm1
  vpor xmm9, xmm8, xmm4
  vpandn xmm6, xmm9, xmm6
  vpor xmm6, xmm6, xmm5
  vpandn xmm7, xmm4, xmm7
  vpandn xmm8, xmm4, xmm8
  vmovdqa xmm0, xmm6
  vpshufd xmm7, xmm7, $1B
  vpshufd xmm8, xmm8, $1B
  vmovmskps eax, xmm7
  vmovmskps edx, xmm8
  shl eax, 12
  shl edx, 8
  or eax, edx
  vzeroupper
end;

function RegisterAddExact(Context: Pointer): NativeUInt;
asm
  .SAVENV XMM6
  .SAVENV XMM7
  .SAVENV XMM8
  .SAVENV XMM9
  .SAVENV XMM10
  vpand xmm2, xmm0, [rip + CAbsMask]
  vpand xmm3, xmm1, [rip + CAbsMask]
  vpcmpgtd xmm3, xmm3, xmm2
  vpxor xmm4, xmm0, xmm1
  vpsrad xmm4, xmm4, 31
  vpand xmm5, xmm3, xmm1
  vpandn xmm6, xmm3, xmm0
  vpor xmm5, xmm5, xmm6
  vpand xmm6, xmm3, xmm0
  vpandn xmm3, xmm3, xmm1
  vpor xmm6, xmm6, xmm3
  vmovdqa xmm2, xmm0                 // original A; original B stays in xmm1
  vpslld xmm7, xmm5, 1
  vpsrld xmm7, xmm7, 24
  vpslld xmm8, xmm6, 1
  vpsrld xmm8, xmm8, 24
  vpand xmm9, xmm5, [rip + CSignMask]
  vpand xmm5, xmm5, [rip + CMantissa]
  vpand xmm6, xmm6, [rip + CMantissa]
  vpor xmm5, xmm5, [rip + CHidden]
  vpor xmm6, xmm6, [rip + CHidden]
  vpslld xmm5, xmm5, 3
  vpslld xmm6, xmm6, 3
  vpsubd xmm8, xmm7, xmm8
  vpsrlvd xmm6, xmm6, xmm8
  vpand xmm6, xmm6, [rip + CNot3]
  vpaddd xmm8, xmm5, xmm6
  vpsubd xmm5, xmm5, xmm6
  vpand xmm5, xmm5, xmm4
  vpandn xmm4, xmm4, xmm8
  vpor xmm5, xmm5, xmm4
  vpxor xmm0, xmm0, xmm0
  vpcmpeqd xmm10, xmm5, xmm0
  vcvtdq2ps xmm6, xmm5
  vpsrld xmm6, xmm6, 23
  vpsubd xmm6, xmm6, [rip + C127]
  vmovdqu xmm8, [rip + COne]
  vpsllvd xmm8, xmm8, xmm6
  vpcmpgtd xmm8, xmm8, xmm5
  vpaddd xmm6, xmm6, xmm8
  vpsubd xmm6, xmm6, [rip + C26]
  vpaddd xmm7, xmm7, xmm6
  vpsubd xmm8, xmm0, xmm6
  vpsllvd xmm8, xmm5, xmm8
  vpsrlvd xmm5, xmm5, xmm6
  vpor xmm5, xmm5, xmm8
  vpsrld xmm5, xmm5, 3
  vpand xmm5, xmm5, [rip + CMantissa]
  vpslld xmm6, xmm7, 23
  vpor xmm5, xmm5, xmm6
  vpcmpgtd xmm8, xmm7, [rip + C255]
  vmovdqu xmm6, [rip + COne]
  vpcmpgtd xmm6, xmm6, xmm7
  vpand xmm0, xmm8, [rip + CAbsMask]
  vpandn xmm5, xmm8, xmm5
  vpor xmm5, xmm5, xmm0
  vpor xmm0, xmm6, xmm10
  vpandn xmm5, xmm0, xmm5
  vpandn xmm0, xmm10, xmm9
  vpor xmm5, xmm5, xmm0
  vpandn xmm6, xmm10, xmm6
  vmovdqa xmm0, xmm2
  vpand xmm2, xmm0, [rip + CExpMask]
  vpand xmm3, xmm1, [rip + CExpMask]
  vpxor xmm4, xmm4, xmm4
  vpcmpeqd xmm2, xmm2, xmm4
  vpcmpeqd xmm3, xmm3, xmm4
  vpor xmm4, xmm2, xmm3
  vpand xmm9, xmm2, xmm3
  vpand xmm9, xmm9, xmm0
  vpand xmm9, xmm9, xmm1
  vpand xmm9, xmm9, [rip + CSignMask]
  vpandn xmm10, xmm3, xmm2
  vpand xmm10, xmm10, xmm1
  vpandn xmm2, xmm2, xmm3
  vpand xmm2, xmm2, xmm0
  vpor xmm9, xmm9, xmm10
  vpor xmm9, xmm9, xmm2
  vpandn xmm5, xmm4, xmm5
  vpor xmm5, xmm5, xmm9
  vpandn xmm6, xmm4, xmm6
  vpandn xmm8, xmm4, xmm8
  vmovdqa xmm0, xmm5
  vpshufd xmm8, xmm8, $1B
  vpshufd xmm6, xmm6, $1B
  vmovmskps eax, xmm8
  vmovmskps edx, xmm6
  shl eax, 12
  shl edx, 8
  or eax, edx
  vzeroupper
end;

function HostAVX2: Boolean;
asm
  .NOFRAME
  mov r10, rbx                       // CPUID clobbers nonvolatile RBX
  xor eax, eax
  cpuid
  cmp eax, 7
  jb @@No
  mov eax, 1
  cpuid
  and ecx, $1C000000                 // XSAVE, OSXSAVE, AVX
  cmp ecx, $1C000000
  jne @@No
  xor ecx, ecx
  xgetbv
  and eax, 6                         // OS saves XMM and YMM state
  cmp eax, 6
  jne @@No
  mov eax, 7
  xor ecx, ecx
  cpuid
  shr ebx, 5                         // AVX2 in leaf 7, subleaf 0
  and ebx, 1
  mov eax, ebx
  jmp @@Done
@@No:
  xor eax, eax
@@Done:
  mov rbx, r10
end;

// AVX-512 F, DQ and VL, with the OS saving the opmask and ZMM state.
function HostAVX512: Boolean;
asm
  .NOFRAME
  mov r10, rbx
  mov eax, 1
  cpuid
  and ecx, $08000000                 // OSXSAVE
  jz @@No
  xor ecx, ecx
  xgetbv
  and eax, $E6                       // XMM, YMM, opmask, ZMM_Hi256, Hi16_ZMM
  cmp eax, $E6
  jne @@No
  mov eax, 7
  xor ecx, ecx
  cpuid
  and ebx, $80030000                 // AVX512F (16), DQ (17), VL (31)
  cmp ebx, $80030000
  jne @@No
  mov eax, 1
  jmp @@Done
@@No:
  xor eax, eax
@@Done:
  mov rbx, r10
end;

// FMA3 (with AVX2 present).
function HostFMA: Boolean;
asm
  .NOFRAME
  mov r10, rbx
  mov eax, 1
  cpuid
  shr ecx, 12
  and ecx, 1
  mov eax, ecx
  mov rbx, r10
end;

type
  TVectorProc = procedure(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);

var
  Mul4Proc, Add4Proc: TVectorProc;

procedure PS2Mul4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .NOFRAME
  jmp qword ptr [rip + Mul4Proc]
end;

procedure PS2Add4(const A, B: TPS2Reg128; out R: TPS2Reg128; out Flags: Cardinal);
asm
  .NOFRAME
  jmp qword ptr [rip + Add4Proc]
end;

{$ELSE}

procedure PS2Itof4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
begin
  var Scale: Double := 1;
  case Shift of
    4: Scale := 1 / 16;
    12: Scale := 1 / 4096;
    15: Scale := 1 / 32768;
  end;
  for var K := 0 to 3 do
  begin
    var V: Single := A.SW[K] * Scale;
    R.UW[K] := PCardinal(@V)^;
  end;
end;

procedure PS2Ftoi4(const A: TPS2Reg128; Shift: Integer; out R: TPS2Reg128);
begin
  var Scale: Double := 1;
  case Shift of
    4: Scale := 16;
    12: Scale := 4096;
    15: Scale := 32768;
  end;
  for var K := 0 to 3 do
  begin
    var V := EEFloatIn(A.UW[K]) * Scale;
    if V >= 2147483647.0 then R.UW[K] := $7FFFFFFF
    else if V <= -2147483648.0 then R.UW[K] := $80000000
    else R.SW[K] := Trunc(V);
  end;
end;

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

function RegisterOU(Flags: Cardinal): NativeUInt;
begin
  Result := 0;
  for var K := 0 to 3 do
  begin
    if Flags and (Cardinal(1) shl K) <> 0 then Result := Result or (NativeUInt(1) shl (15 - K));
    if Flags and (Cardinal(16) shl K) <> 0 then Result := Result or (NativeUInt(1) shl (11 - K));
  end;
end;

function ModelAddRegisters(const A, B: TPS2Reg128; Context: Pointer; out R: TPS2Reg128): NativeUInt;
begin
  var Flags: Cardinal;
  PS2Add4(A, B, R, Flags);
  Result := RegisterOU(Flags);
end;

function ModelMulRegisters(const A, B: TPS2Reg128; Context: Pointer; out R: TPS2Reg128): NativeUInt;
begin
  var Flags: Cardinal;
  PS2Mul4(A, B, R, Flags);
  Result := RegisterOU(Flags);
end;

function PS2RegisterMathNative(Kind: TPS2RegisterMath): Pointer;
begin
  Result := nil;
  {$IFDEF PS2_VU_SSE}
  if VectorAVX2 then
    case Kind of
      vrmAdd: Result := @AddRegisters;
      vrmMul: Result := @MulRegisters;
    end;
  {$ENDIF}
end;

function PS2RegisterMathNativeFor(Kind: TPS2RegisterMath; Mode: TRoundingMode): Pointer;
begin
  Result := nil;
  {$IFDEF PS2_VU_SSE}
  if VectorAVX2 then
    case Kind of
      vrmAdd:
        case Mode of
          rmTruncate: Result := @AddRegistersRZ;
          rmNearest: if VectorAVX512 then Result := @AddRegistersRN512 else Result := @AddRegistersRN;
        else
          Result := @RegisterAddExact;
        end;
      vrmMul:
        case Mode of
          rmTruncate: Result := @MulRegistersRZ;
          rmNearest:
            if VectorAVX512 then Result := @MulRegistersRN512
            else if VectorFMA then Result := @MulRegistersRN
            else Result := @RegisterMulExact;
        else
          Result := @RegisterMulExact;
        end;
    end;
  {$ENDIF}
end;

function PS2RegisterMathModel(Kind: TPS2RegisterMath): Pointer;
begin
  case Kind of
    vrmAdd: Result := @ModelAddRegisters;
    vrmMul: Result := @ModelMulRegisters;
  else
    Result := nil;
  end;
end;

initialization
  {$IFDEF PS2_VU_SSE}
  Mul4Proc := PS2Mul4SSE2;
  Add4Proc := PS2Add4SSE2;
  {$IFNDEF PS2_FORCE_SSE2}
  VectorAVX2 := HostAVX2;
  VectorFMA := VectorAVX2 and HostFMA;
  HostHasAVX512 := VectorFMA and HostAVX512;
  VectorAVX512 := HostHasAVX512;
  if VectorAVX2 then
  begin
    Mul4Proc := PS2Mul4Common;
    Add4Proc := PS2Add4Common;
  end;
  {$ENDIF}
  {$ENDIF}

end.
