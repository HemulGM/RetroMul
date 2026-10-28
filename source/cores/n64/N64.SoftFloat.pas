unit N64.SoftFloat;
// Runs without range and overflow checks (every index is masked and all
// guest arithmetic wraps explicitly); N64_CHECKED builds them in, for the
// tests.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  N64.Types;

const
  sfInexact = 1;
  sfUnderflow = 2;
  sfOverflow = 4;
  sfDivideZero = 8;
  sfInvalid = 16;

type
  TSoftFloatResult = record
    Bits: UInt64;
    Events: Cardinal;
  end;

function SFCalculate(A, B: UInt64; Format, Operation, Rounding: Integer): TSoftFloatResult;

function SFConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer): TSoftFloatResult;

procedure SFCompare(A, B: UInt64; Format: Integer; out Unordered, Equal, Less: Boolean);

function SFIsNaN(A: UInt64; Format: Integer): Boolean; inline;

function SFIsSubnormal(A: UInt64; Format: Integer): Boolean; inline;

// Whether the calling thread's floating point suits SFQuick: rounding to
// nearest, inexact results raising nothing, and on x87 (Win32) a 53-bit
// significand. SFPrepareHost sets that up; a thread that runs the CPU calls
// it once. Only on x86 and x64 (tested there): False elsewhere (ARM).
function SFHostReady: Boolean;

procedure SFPrepareHost;

// SFCalculate(A, B, Format, Operation, 0) (round to nearest) for add, sub,
// mul, div and sqrt (Operation 0..4) of normal operands whose result is
// normal, or an exact zero, computed by the host (SFHostReady must hold):
// the same bits and events. False where it cannot tell (then SFCalculate).
function SFQuick(A, B: UInt64; Format, Operation: Integer; out R: TSoftFloatResult): Boolean;
// SFConvert for single <-> double and 32/64-bit integers to single or double
// (rounding to nearest, the host's where it rounds), and single or double to
// integers in any rounding mode, of normal values and zeros whose result is
// in range: the same bits and events. False where it cannot tell.

function SFQuickConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer; out R: TSoftFloatResult): Boolean;

implementation

uses
  System.Math;

type
  TNumber = record
    Negative: Boolean;
    Exponent: Integer;
    Significand: UInt64; // Normalized at bit 62; ten guard/sticky bits for binary64.
    Kind: Integer; // 0 finite, 1 infinity, 2 NaN.
  end;

function FractionBits(Format: Integer): Integer; inline;
begin
  if Format = 16 then
    Result := 23
  else
    Result := 52;
end;

function Bias(Format: Integer): Integer; inline;
begin
  if Format = 16 then
    Result := 127
  else
    Result := 1023;
end;

function SignMask(Format: Integer): UInt64; inline;
begin
  if Format = 16 then
    Result := $80000000
  else
    Result := UInt64(1) shl 63;
end;

function Infinity(Format: Integer): UInt64; inline;
begin
  if Format = 16 then
    Result := $7F800000
  else
    Result := $7FF0000000000000;
end;

function DefaultNaN(Format: Integer): UInt64;
begin
  // R4300 uses the pre-NaN2008 encoding (quiet bit clear).
  if Format = 16 then
    Result := $7FBFFFFF
  else
    Result := $7FF7FFFFFFFFFFFF;
end;

function SFIsNaN(A: UInt64; Format: Integer): Boolean;
begin
  if Format = 16 then
    Result := ((A and $7F800000) = $7F800000) and ((A and $7FFFFF) <> 0)
  else
    Result := ((A and $7FF0000000000000) = $7FF0000000000000) and ((A and $FFFFFFFFFFFFF) <> 0);
end;

function SFIsSubnormal(A: UInt64; Format: Integer): Boolean;
begin
  if Format = 16 then
    Result := ((A and $7F800000) = 0) and ((A and $7FFFFF) <> 0)
  else
    Result := ((A and $7FF0000000000000) = 0) and ((A and $FFFFFFFFFFFFF) <> 0);
end;

function ShiftJam(A: UInt64; N: Integer): UInt64;
begin
  if N <= 0 then
    Exit(A);
  if N >= 64 then
    Exit(Ord(A <> 0));
  Result := (A shr N) or UInt64(Ord((A shl (64 - N)) <> 0));
end;

procedure Product64(A, B: UInt64; out Hi, Lo: UInt64); inline;
begin
  // Four 32-bit products; carry sums are at most 34 bits. The high sum is
  // bounded by the true upper product, so every host addition is in range.
  var P0 := (A and $FFFFFFFF) * (B and $FFFFFFFF);
  var P1 := (A and $FFFFFFFF) * (B shr 32);
  var P2 := (A shr 32) * (B and $FFFFFFFF);
  var P3 := (A shr 32) * (B shr 32);
  var Middle := (P0 shr 32) + (P1 and $FFFFFFFF) + (P2 and $FFFFFFFF);
  Lo := ((Middle and $FFFFFFFF) shl 32) or (P0 and $FFFFFFFF);
  Hi := P3 + (P1 shr 32) + (P2 shr 32) + (Middle shr 32);
end;

function Decode(A: UInt64; Format: Integer): TNumber;
begin
  Result := Default(TNumber);
  Result.Negative := (A and SignMask(Format)) <> 0;
  var P := FractionBits(Format);
  var E := Integer((A and Infinity(Format)) shr P);
  var F := A and ((UInt64(1) shl P) - 1);
  if E = Bias(Format) * 2 + 1 then
  begin
    Result.Kind := 1 + Ord(F <> 0);
    Exit;
  end;
  Result.Exponent := E - Bias(Format);
  if E <> 0 then
    F := F or (UInt64(1) shl P)
  else
    Result.Exponent := 1 - Bias(Format);
  Result.Significand := F shl (62 - P);
  if F = 0 then
    Exit;
  while (Result.Significand and (UInt64(1) shl 62)) = 0 do
  begin
    Result.Significand := Result.Significand shl 1;
    Dec(Result.Exponent);
  end;
end;

function Pack(Negative: Boolean; Exponent: Integer; Sig: UInt64; Format, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  if Negative then
    Result.Bits := SignMask(Format);
  if Sig = 0 then
    Exit;
  if (Sig shr 63) <> 0 then
  begin
    Sig := ShiftJam(Sig, 1);
    Inc(Exponent);
  end;
  while (Sig and (UInt64(1) shl 62)) = 0 do
  begin
    Sig := Sig shl 1;
    Dec(Exponent);
  end;
  var B := Bias(Format);
  var P := FractionBits(Format);
  var Tiny := Exponent < 1 - B;
  if Tiny then
  begin
    Sig := ShiftJam(Sig, 1 - B - Exponent);
    Exponent := 1 - B;
  end;
  var Shift := 62 - P;
  var Remainder := Sig and ((UInt64(1) shl Shift) - 1);
  var Fraction := Sig shr Shift;
  var Increment := False;
  if Remainder <> 0 then
  begin
    Result.Events := sfInexact;
    case Rounding of
      0:
        Increment := (Remainder > (UInt64(1) shl (Shift - 1))) or
          ((Remainder = (UInt64(1) shl (Shift - 1))) and Odd(Fraction));
      2:
        Increment := not Negative;
      3:
        Increment := Negative;
    end;
  end;
  if Increment then
    Inc(Fraction);
  if Fraction >= (UInt64(1) shl (P + 1)) then
  begin
    Fraction := Fraction shr 1;
    Inc(Exponent);
  end;
  if Exponent > B then
  begin
    Result.Events := sfOverflow or sfInexact;
    var ToInfinity := (Rounding = 0) or ((Rounding = 2) and not Negative) or
      ((Rounding = 3) and Negative);
    if ToInfinity then
      Result.Bits := Result.Bits or Infinity(Format)
    else
      Result.Bits := Result.Bits or (Infinity(Format) - 1);
    Exit;
  end;
  var E := Exponent + B;
  if Fraction < (UInt64(1) shl P) then
    E := 0;
  if Tiny and (E = 0) and (Remainder <> 0) then
    Result.Events := Result.Events or sfUnderflow;
  Result.Bits := Result.Bits or (UInt64(E) shl P) or
    (Fraction and ((UInt64(1) shl P) - 1));
end;

function Invalid(Format: Integer): TSoftFloatResult;
begin
  Result.Bits := DefaultNaN(Format);
  Result.Events := sfInvalid;
end;

function SFCalculate(A, B: UInt64; Format, Operation, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  var X := Decode(A, Format);
  var Y := Decode(B, Format);
  if (X.Kind = 2) or ((Operation <= 3) and (Y.Kind = 2)) then
    Exit(Invalid(Format));
  if Operation = 1 then
    Y.Negative := not Y.Negative;
  var Negative := X.Negative xor Y.Negative;
  var Sig: UInt64;
  var E: Integer;
  case Operation of
    0, 1:
      begin
        if (X.Kind = 1) or (Y.Kind = 1) then
        begin
          if (X.Kind = 1) and (Y.Kind = 1) and (X.Negative <> Y.Negative) then
            Exit(Invalid(Format));
          if X.Kind <> 1 then
            X := Y;
          Result.Bits := Infinity(Format);
          if X.Negative then
            Result.Bits := Result.Bits or SignMask(Format);
          Exit;
        end;
        if (X.Exponent < Y.Exponent) or ((X.Exponent = Y.Exponent) and
          (X.Significand < Y.Significand)) then
        begin
          var Temp := X;
          X := Y;
          Y := Temp;
        end;
        Y.Significand := ShiftJam(Y.Significand, X.Exponent - Y.Exponent);
        if X.Negative = Y.Negative then
          Sig := X.Significand + Y.Significand
        else
          Sig := X.Significand - Y.Significand;
        Negative := X.Negative;
        if Sig = 0 then
          Negative := ((X.Negative = Y.Negative) and X.Negative) or
            ((X.Negative <> Y.Negative) and (Rounding = 3));
        Result := Pack(Negative, X.Exponent, Sig, Format, Rounding);
      end;
    2:
      begin
        if (X.Kind = 1) or (Y.Kind = 1) then
        begin
          if ((X.Kind = 0) and (X.Significand = 0)) or
            ((Y.Kind = 0) and (Y.Significand = 0)) then
            Exit(Invalid(Format));
          Result.Bits := Infinity(Format);
          if Negative then
            Result.Bits := Result.Bits or SignMask(Format);
          Exit;
        end;
        var Hi, Lo: UInt64;
        Product64(X.Significand shr 10, Y.Significand shr 10, Hi, Lo);
        E := X.Exponent + Y.Exponent;
        Sig := (Hi shl 22) or (Lo shr 42) or UInt64(Ord((Lo shl 22) <> 0));
        Result := Pack(Negative, E, Sig, Format, Rounding);
      end;
    3:
      begin
        if ((X.Kind = 1) and (Y.Kind = 1)) or ((X.Kind = 0) and (X.Significand = 0) and
          (Y.Kind = 0) and (Y.Significand = 0)) then
          Exit(Invalid(Format));
        if (X.Kind = 1) or ((Y.Kind = 0) and (Y.Significand = 0)) then
        begin
          Result.Bits := Infinity(Format);
          if X.Kind <> 1 then
            Result.Events := sfDivideZero;
        end
        else if (Y.Kind = 1) or (X.Significand = 0) then
          Result.Bits := 0
        else
        begin
          var R := X.Significand shr 10;
          var Divisor := Y.Significand shr 10;
          E := X.Exponent - Y.Exponent;
          if R < Divisor then
          begin
            R := R shl 1;
            Dec(E);
          end;
          Sig := 0;
          for var I := 62 downto 0 do
          begin
            if R >= Divisor then
            begin
              R := R - Divisor;
              Sig := Sig or (UInt64(1) shl I);
            end;
            R := R shl 1;
          end;
          if R <> 0 then
            Sig := Sig or 1;
          Exit(Pack(Negative, E, Sig, Format, Rounding));
        end;
        if Negative then
          Result.Bits := Result.Bits or SignMask(Format);
      end;
    4:
      begin
        if X.Negative and ((X.Kind = 1) or (X.Significand <> 0)) then
          Exit(Invalid(Format));
        if X.Kind = 1 then
        begin
          Result.Bits := A;
          Exit;
        end;
        if X.Significand = 0 then
        begin
          Result.Bits := A and SignMask(Format);
          Exit;
        end;
        E := X.Exponent;
        var OddExponent := Odd(E);
        if OddExponent then
          Dec(E);
        E := E div 2;
        // A 126-bit radicand and a 63-bit root. Trial squares avoid any
        // overflowing 65-bit remainder in a restoring square-root loop.
        var Shift := 72 + Ord(OddExponent);
        var RadHi := (X.Significand shr 10) shl (Shift - 64);
        var RadLo: UInt64 := 0;
        Sig := 0;
        for var I := 62 downto 0 do
        begin
          var Trial := Sig or (UInt64(1) shl I);
          var Hi, Lo: UInt64;
          Product64(Trial, Trial, Hi, Lo);
          if (Hi < RadHi) or ((Hi = RadHi) and (Lo <= RadLo)) then
            Sig := Trial;
        end;
        var Hi, Lo: UInt64;
        Product64(Sig, Sig, Hi, Lo);
        if (Hi <> RadHi) or (Lo <> RadLo) then
          Sig := Sig or 1;
        Result := Pack(False, E, Sig, Format, Rounding);
      end;
    5, 7:
      begin
        Result.Bits := A;
        if Operation = 5 then
          Result.Bits := A and not SignMask(Format)
        else
          Result.Bits := A xor SignMask(Format);
      end;
  end;
end;

function SFConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer): TSoftFloatResult;
begin
  Result := Default(TSoftFloatResult);
  if SourceFormat in [20, 21] then
  begin
    if SourceFormat = 20 then
      A := SX(A, 32);
    var Negative := (A shr 63) <> 0;
    if Negative then
      A := Sub64(0, A);
    var E := 62;
    if (A shr 63) <> 0 then
    begin
      A := ShiftJam(A, 1);
      Inc(E);
    end;
    Exit(Pack(Negative, E, A, TargetFormat, Rounding));
  end;
  var X := Decode(A, SourceFormat);
  if TargetFormat in [16, 17] then
  begin
    if X.Kind = 2 then
      Exit(Invalid(TargetFormat));
    if X.Kind = 1 then
    begin
      Result.Bits := Infinity(TargetFormat);
      if X.Negative then
        Result.Bits := Result.Bits or SignMask(TargetFormat);
      Exit;
    end;
    Exit(Pack(X.Negative, X.Exponent, X.Significand, TargetFormat, Rounding));
  end;
  var Width := 64;
  if TargetFormat = 20 then
    Width := 32;
  Result.Bits := UInt64(1) shl (Width - 1);
  if (X.Kind <> 0) or (X.Exponent > Width - 1) then
  begin
    Result.Events := sfInvalid;
    Exit;
  end;
  var Shift := 62 - X.Exponent;
  var Fraction: UInt64 := 0;
  var Remainder: UInt64 := X.Significand;
  var Half: UInt64 := 0;
  if Shift <= 0 then
  begin
    Fraction := X.Significand shl (-Shift);
    Remainder := 0;
  end
  else if Shift < 64 then
  begin
    Fraction := X.Significand shr Shift;
    Remainder := X.Significand and ((UInt64(1) shl Shift) - 1);
    Half := UInt64(1) shl (Shift - 1);
  end;
  var Increment := False;
  if Remainder <> 0 then
  begin
    Result.Events := sfInexact;
    case Rounding of
      0:
        Increment := (Half <> 0) and ((Remainder > Half) or ((Remainder = Half) and Odd(Fraction)));
      2:
        Increment := not X.Negative;
      3:
        Increment := X.Negative;
    end;
  end;
  if Increment then
    Fraction := Add64(Fraction, 1);
  var Limit := UInt64(1) shl (Width - 1);
  if (Fraction > Limit) or ((Fraction = Limit) and not X.Negative) then
  begin
    Result.Events := sfInvalid;
    Exit;
  end;
  if X.Negative then
    Fraction := Sub64(0, Fraction);
  if Width = 32 then
    Fraction := Fraction and $FFFFFFFF;
  Result.Bits := Fraction;
end;

procedure SFCompare(A, B: UInt64; Format: Integer; out Unordered, Equal, Less: Boolean);
begin
  Unordered := SFIsNaN(A, Format) or SFIsNaN(B, Format);
  Equal := False;
  Less := False;
  if Unordered then
    Exit;
  var Mask := SignMask(Format);
  if ((A and not Mask) = 0) and ((B and not Mask) = 0) then
  begin
    Equal := True;
    Exit;
  end;
  Equal := A = B;
  if ((A xor B) and Mask) <> 0 then
    Less := (A and Mask) <> 0
  else if (A and Mask) <> 0 then
    Less := A > B
  else
    Less := A < B;
end;

function SFHostReady: Boolean;
begin
  {$IF defined(CPUX64) or defined(CPUX86)}
  // Overflow, underflow, invalid operations and division by zero never
  // happen in SFQuick (it checks the ranges first); inexact results do.
  Result := (GetRoundMode = rmNearest) and (exPrecision in GetExceptionMask);
  {$IFDEF CPUX86}
  // x87: every result rounded to a double's 53 bits.
  Result := Result and ((Get8087CW and $0300) = $0200);
  {$ENDIF}
  {$ELSE}
  // Not tested on other hosts yet: SoftFloat alone.
  Result := False;
  {$ENDIF}
end;

procedure SFPrepareHost;
begin
  SetRoundMode(rmNearest);
  SetExceptionMask(GetExceptionMask + [exPrecision]);
  {$IFDEF CPUX86}
  Set8087CW((Get8087CW and not $0300) or $0200);
  {$ENDIF}
end;

function DoubleOf(Bits: UInt64): Double; inline;
begin
  Move(Bits, Result, SizeOf(Result));
end;

function BitsOf(Value: Double): UInt64; inline;
begin
  Move(Value, Result, SizeOf(Result));
end;

function SameProduct(M, N, Base: UInt64; Shift: Integer): Boolean;
begin
  // M * N = Base * 2^Shift (M, N, Base below 2^53; Shift 0..63).
  var Hi, Lo: UInt64;
  Product64(M, N, Hi, Lo);
  var TargetHi: UInt64 := 0;
  if Shift > 0 then
    TargetHi := Base shr (64 - Shift);
  Result := (Hi = TargetHi) and (Lo = (Base shl Shift));
end;

function HasZero(A, B: UInt64; Format, Operation: Integer): Boolean; inline;
begin
  var Magnitude := not SignMask(Format);
  Result := ((A and Magnitude) = 0) or ((Operation <= 3) and ((B and Magnitude) = 0));
end;

function NormalOrZero(A: UInt64; Format: Integer): Boolean;
begin
  var Field := A and Infinity(Format);
  Result := ((A and not SignMask(Format)) = 0) or ((Field <> 0) and (Field <> Infinity(Format)));
end;

function QuickZero(A, B: UInt64; Format, Operation: Integer; out R: TSoftFloatResult): Boolean;
begin
  // SFCalculate's exact results with a zero operand (the other one normal or
  // zero): a sum is the other operand, or a zero signed as IEEE rounding to
  // nearest has it; a product, a quotient of a zero, a root of a zero are
  // zeros. A division by zero raises: SFCalculate.
  R.Bits := 0;
  R.Events := 0;
  Result := False;
  var Sign := SignMask(Format);
  if not NormalOrZero(A, Format) or ((Operation <= 3) and not NormalOrZero(B, Format)) then
    Exit;
  var ZeroA := (A and not Sign) = 0;
  var ZeroB := (B and not Sign) = 0;
  case Operation of
    0, 1:
      begin
        if Operation = 1 then
          B := B xor Sign;
        if ZeroA and ZeroB then
          R.Bits := A and B and Sign
        else if ZeroA then
          R.Bits := B
        else
          R.Bits := A;
      end;
    2:
      R.Bits := (A xor B) and Sign;
    3:
      begin
        if ZeroB then
          Exit;
        R.Bits := (A xor B) and Sign;
      end;
    4:
      R.Bits := A;
  else
    Exit;
  end;
  Result := True;
end;

function SFQuick(A, B: UInt64; Format, Operation: Integer; out R: TSoftFloatResult): Boolean;
begin
  // Single: in double, where every operation here is exact, or (division,
  // square root) correctly rounded to 53 bits, which rounded once more to 24
  // gives the correctly rounded single (53 >= 2 * 24 + 2). Double: the host
  // rounds; whether it did is told exactly (TwoSum; integer products).
  Result := False;
  R.Bits := 0;
  R.Events := 0;
  var Inexact := False;
  if (Format <> 16) and (Format <> 17) then
    Exit;
  if Format = 16 then
  begin
    // SFCalculate reads a single's 32 bits only.
    A := A and $FFFFFFFF;
    B := B and $FFFFFFFF;
  end;
  if HasZero(A, B, Format, Operation) then
    Exit(QuickZero(A, B, Format, Operation, R));
  if Format = 16 then
  begin
    var EA := Integer((A shr 23) and $FF);
    var EB := Integer((B shr 23) and $FF);
    if (EA = 0) or (EA = 255) or ((Operation <= 3) and ((EB = 0) or (EB = 255))) then
      Exit;
    var SA, SB: Single;
    var CA := Cardinal(A and $FFFFFFFF);
    var CB := Cardinal(B and $FFFFFFFF);
    Move(CA, SA, 4);
    Move(CB, SB, 4);
    var X: Double := SA;
    var Y: Double := SB;
    var Z: Double;
    case Operation of
      0, 1:
        begin
          // Exact: 25 bits plus the exponent difference.
          if Abs(EA - EB) > 28 then
            Exit;
          if Operation = 0 then
            Z := X + Y
          else
            Z := X - Y;
        end;
      2:
        Z := X * Y;
      3:
        Z := X / Y;
      4:
        begin
          if (CA and $80000000) <> 0 then
            Exit;
          Z := Sqrt(X);
        end;
    else
      Exit;
    end;
    // Normal single results only (2^-126 up to below 2^127), or an exact 0.
    var M := Abs(Z);
    if (M <> 0) and ((M < 1.1754943508222875E-38) or (M >= 1.7014118346046923E+38)) then
      Exit;
    var S: Single := Z;
    var Back: Double := S;
    case Operation of
      3:
        Inexact := Back * Y <> X;
      4:
        Inexact := Back * Back <> X;
    else
      Inexact := Back <> Z;
    end;
    var Bits: Cardinal;
    Move(S, Bits, 4);
    R.Bits := Bits;
    if Inexact then
      R.Events := sfInexact;
    Exit(True);
  end;
  if Format <> 17 then
    Exit;
  var EA := Integer((A shr 52) and $7FF);
  var EB := Integer((B shr 52) and $7FF);
  if (EA = 0) or (EA = 2047) or ((Operation <= 3) and ((EB = 0) or (EB = 2047))) then
    Exit;
  var X := DoubleOf(A);
  var Y := DoubleOf(B);
  var Z: Double;
  case Operation of
    0, 1:
      begin
        // Operands from 2^-959 to below 2^1022: the sum finite, and TwoSum's
        // error term (a multiple of 2^-1011) exact.
        if (EA < 64) or (EB < 64) or (EA > 2044) or (EB > 2044) then
          Exit;
        if Operation = 1 then
          Y := -Y;
        Z := X + Y;
        var Part := Z - X;
        Inexact := (X - (Z - Part)) + (Y - Part) <> 0;
      end;
    2:
      begin
        // A product from 2^-1020 to below 2^1022.
        if (EA + EB < 1026) or (EA + EB > 3066) then
          Exit;
        Z := X * Y;
        var Hi, Lo: UInt64;
        Product64((A and $FFFFFFFFFFFFF) or $10000000000000, (B and $FFFFFFFFFFFFF) or $10000000000000, Hi, Lo);
        // Exact when the bits below the 53 the product keeps are 0.
        var Dropped := 52;
        if (Hi shr 41) <> 0 then
          Dropped := 53;
        Inexact := (Lo and ((UInt64(1) shl Dropped) - 1)) <> 0;
      end;
    3:
      begin
        // A quotient from 2^-1020 to below 2^1022.
        if (EA - EB < -1019) or (EA - EB > 1020) then
          Exit;
        Z := X / Y;
      end;
    4:
      begin
        if (A shr 63) <> 0 then
          Exit;
        Z := Sqrt(X);
      end;
  else
    Exit;
  end;
  var ZBits := BitsOf(Z);
  var EZ := Integer((ZBits shr 52) and $7FF);
  if (ZBits and $7FFFFFFFFFFFFFFF) = 0 then
  begin
    // An exact 0 (a sum).
    if Inexact then
      Exit;
  end
  else if (EZ = 0) or (EZ = 2047) then
    Exit
  else if Operation in [3, 4] then
  begin
    // Exact when the result times the divisor (itself) is the dividend
    // (the radicand), in integers: MZ * MB = MA * 2^Shift.
    var MZ := (ZBits and $FFFFFFFFFFFFF) or $10000000000000;
    var MA := (A and $FFFFFFFFFFFFF) or $10000000000000;
    var Shift: Integer;
    var Other: UInt64;
    if Operation = 3 then
    begin
      Shift := EA - EZ - EB + 1075;
      Other := (B and $FFFFFFFFFFFFF) or $10000000000000;
    end
    else
    begin
      Shift := EA - 2 * EZ + 1075;
      Other := MZ;
    end;
    Inexact := (Shift < 0) or (Shift > 63) or not SameProduct(MZ, Other, MA, Shift);
  end;
  R.Bits := ZBits;
  if Inexact then
    R.Events := sfInexact;
  Result := True;
end;

function SFQuickConvert(A: UInt64; SourceFormat, TargetFormat, Rounding: Integer; out R: TSoftFloatResult): Boolean;
begin
  R.Bits := 0;
  R.Events := 0;
  Result := False;
  if (SourceFormat = 16) or (SourceFormat = 17) then
  begin
    var P := FractionBits(SourceFormat);
    if SourceFormat = 16 then
      A := A and $FFFFFFFF;
    var Negative := (A and SignMask(SourceFormat)) <> 0;
    var Field := Integer((A and Infinity(SourceFormat)) shr P);
    var Fraction := A and ((UInt64(1) shl P) - 1);
    // Subnormals, infinities and NaNs: SFConvert.
    if ((Field = 0) and (Fraction <> 0)) or (Field = Bias(SourceFormat) * 2 + 1) then
      Exit;
    if (TargetFormat = 20) or (TargetFormat = 21) then
    begin
      // As SFConvert, with the significand at bit P instead of 62.
      var Width := 32;
      if TargetFormat = 21 then
        Width := 64;
      var Value: UInt64 := 0;
      var Remainder: UInt64 := 0;
      var Half: UInt64 := 0;
      if Field <> 0 then
      begin
        var E := Field - Bias(SourceFormat);
        if E >= Width - 1 then
          Exit;
        var M := Fraction or (UInt64(1) shl P);
        var S := P - E;
        if S <= 0 then
          Value := M shl (-S)
        else if S < 64 then
        begin
          Value := M shr S;
          Remainder := M and ((UInt64(1) shl S) - 1);
          Half := UInt64(1) shl (S - 1);
        end
        else
          Remainder := M;
      end;
      var Increment := False;
      if Remainder <> 0 then
      begin
        R.Events := sfInexact;
        case Rounding of
          0:
            Increment := (Half <> 0) and ((Remainder > Half) or ((Remainder = Half) and Odd(Value)));
          2:
            Increment := not Negative;
          3:
            Increment := Negative;
        end;
      end;
      if Increment then
        Inc(Value);
      // At the limit (or past it): SFConvert.
      if Value >= UInt64(1) shl (Width - 1) then
        Exit;
      if Negative then
        Value := Sub64(0, Value);
      if Width = 32 then
        Value := Value and $FFFFFFFF;
      R.Bits := Value;
      Exit(True);
    end;
    if (SourceFormat = 16) and (TargetFormat = 17) then
    begin
      // Exact.
      R.Bits := UInt64(Ord(Negative)) shl 63;
      if Field <> 0 then
        R.Bits := R.Bits or (UInt64(Field - 127 + 1023) shl 52) or (Fraction shl 29);
      Exit(True);
    end;
    if (SourceFormat = 17) and (TargetFormat = 16) then
    begin
      R.Bits := Cardinal(Ord(Negative)) shl 31;
      if Field = 0 then
        Exit(True);
      // A normal single (2^-126 up to below 2^127), rounded to nearest by
      // the host (or exact, in any mode).
      var D := DoubleOf(A);
      var M := Abs(D);
      if (M < 1.1754943508222875E-38) or (M >= 1.7014118346046923E+38) then
        Exit;
      var S: Single := D;
      var Back: Double := S;
      if Back <> D then
      begin
        if Rounding <> 0 then
          Exit;
        R.Events := sfInexact;
      end;
      var Bits: Cardinal;
      Move(S, Bits, 4);
      R.Bits := Bits;
      Exit(True);
    end;
    Exit;
  end;
  if ((SourceFormat <> 20) and (SourceFormat <> 21)) or ((TargetFormat <> 16) and (TargetFormat <> 17)) then
    Exit;
  var V: Int64;
  if SourceFormat = 20 then
    V := Int64(Integer(Cardinal(A and $FFFFFFFF)))
  else
    V := Int64(A);
  if V = 0 then
    Exit(True);
  // Up to 53 bits: exact in a double.
  if (V >= Int64(1) shl 53) or (V <= -(Int64(1) shl 53)) then
    Exit;
  var D: Double := V;
  if TargetFormat = 17 then
  begin
    R.Bits := BitsOf(D);
    Exit(True);
  end;
  var S: Single := D;
  var Back: Double := S;
  if Back <> D then
  begin
    if Rounding <> 0 then
      Exit;
    R.Events := sfInexact;
  end;
  var Bits: Cardinal;
  Move(S, Bits, 4);
  R.Bits := Bits;
  Result := True;
end;

end.

