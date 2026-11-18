unit AVM1.Trigonometry;

interface

function AVMTrig(Which: Integer; Value: Double): Double;

implementation

uses
  System.Math;

const
  InvPiWords: array[0..49] of Cardinal = (
    $7BC08C6B, $A8C960E2, $1556CA73, $27310606, $D8804D73,
    $68408DFF, $855F14A0, $1B086599, $91615EE6, $361DA9E3,
    $BC209AF4, $6BABF0CF, $3046FC7B, $5D085603, $5FB11F8D,
    $92EA6BFB, $39F78A52, $F17B3D07, $BAC7EBE5, $EA2D7527,
    $3F669E5F, $09B74F46, $7ECF27CB, $6D1F6D36, $118B5A0A,
    $980FEF2F, $97FFDE05, $283B1FF8, $5F8BBDF9, $39F49C84,
    $D6398353, $7E413991, $7026B45F, $4484E99C, $35F52EBB,
    $A73EE882, $EB1CB129, $921CFE1D, $2EEA09D1, $D2E00649,
    $6E3A424D, $C561B724, $63ABDEBB, $9041FE51, $95993C43,
    $DDC0DB62, $57D1F534, $1529FC27, $836E4E44, $0000A2F9);

type
  TProduct = array[0..51] of Cardinal;

function BitAt(const Value: TProduct; BitIndex: Integer): Integer;
begin
  Result := 0;
  if (BitIndex < 0) or (BitIndex >= 1664) then
    Exit;
  Result := (Value[BitIndex div 32] shr (BitIndex mod 32)) and 1;
end;

procedure ReduceAngle(Value: Double; out Quadrant: Integer; out HighPart, LowPart: Double);
const
  PiOver2: Double = 1.57079632679489655800;
  PiOver2Tail: Double = 6.12323399573676603587e-17;
  Splitter: Double = 134217729.0;
var
  Bits, Mantissa, Carry, ProductValue, Digit, First, Second: UInt64;
  Product: TProduct;
  I, Exponent, Shift, Highest, WordIndex, BitIndex: Integer;
  RoundUp: Boolean;
  FracHigh, FracLow, P, T, AH, AL, BH, BL, ErrorValue, Tail: Double;
begin
  Move(Value, Bits, 8);
  Mantissa := (Bits and $FFFFFFFFFFFFF) or $10000000000000;
  Exponent := Integer((Bits shr 52) and $7FF) - 1023;
  Product := Default(TProduct);
  Carry := 0;
  for I := 0 to 49 do
  begin
    ProductValue := UInt64(InvPiWords[I]) * (Mantissa and $FFFFFFFF) + Carry;
    Product[I] := ProductValue and $FFFFFFFF;
    Carry := ProductValue shr 32;
  end;
  Product[50] := Carry;
  Carry := 0;
  for I := 0 to 49 do
  begin
    ProductValue := UInt64(InvPiWords[I]) * (Mantissa shr 32) + Product[I + 1] + Carry;
    Product[I + 1] := ProductValue and $FFFFFFFF;
    Carry := ProductValue shr 32;
  end;
  Product[51] := Carry;
  Shift := 1584 + 52 - Exponent;
  Quadrant := BitAt(Product, Shift) + 2 * BitAt(Product, Shift + 1);
  RoundUp := BitAt(Product, Shift - 1) <> 0;
  if RoundUp then
    Quadrant := (Quadrant + 1) and 3;
  { Keep the fractional numerator, then complement it if nearest integer rounds up. }
  WordIndex := Shift div 32;
  BitIndex := Shift mod 32;
  for I := WordIndex + 1 to High(Product) do
    Product[I] := 0;
  if BitIndex = 0 then
    Product[WordIndex] := 0
  else
    Product[WordIndex] := Product[WordIndex] and ((Cardinal(1) shl BitIndex) - 1);
  if RoundUp then
  begin
    Carry := 1;
    for I := 0 to WordIndex do
    begin
      ProductValue := UInt64(not Product[I]) + Carry;
      Product[I] := ProductValue and $FFFFFFFF;
      Carry := ProductValue shr 32;
    end;
    if BitIndex = 0 then
      Product[WordIndex] := 0
    else
      Product[WordIndex] := Product[WordIndex] and ((Cardinal(1) shl BitIndex) - 1);
  end;
  Highest := Shift - 1;
  while (Highest >= 0) and (BitAt(Product, Highest) = 0) do
    Dec(Highest);
  First := 0;
  Second := 0;
  for I := 0 to 52 do
  begin
    Digit := BitAt(Product, Highest - I);
    First := First * 2 + Digit;
  end;
  for I := 53 to 105 do
  begin
    Digit := BitAt(Product, Highest - I);
    Second := Second * 2 + Digit;
  end;
  FracHigh := Ldexp(Double(First), Highest - 52 - Shift);
  FracLow := Ldexp(Double(Second), Highest - 105 - Shift);
  if RoundUp then
  begin
    FracHigh := -FracHigh;
    FracLow := -FracLow;
  end;
  { Dekker product preserves the tail when the reduced angle is near zero. }
  P := FracHigh * PiOver2;
  T := Splitter * FracHigh;
  AH := T - (T - FracHigh);
  AL := FracHigh - AH;
  T := Splitter * PiOver2;
  BH := T - (T - PiOver2);
  BL := PiOver2 - BH;
  ErrorValue := ((AH * BH - P) + AH * BL + AL * BH) + AL * BL;
  Tail := ErrorValue + FracHigh * PiOver2Tail + FracLow * PiOver2;
  HighPart := P + Tail;
  LowPart := (P - HighPart) + Tail;
end;

function AVMTrig(Which: Integer; Value: Double): Double;
var
  Quadrant: Integer;
  HighPart, LowPart, S, C, SinValue, CosValue: Double;
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit(NaN);
  if Value = 0 then
  begin
    if Which = 1 then
      Exit(1);
    Exit(Value);
  end;
  if Abs(Value) < 1e-27 then
  begin
    if Which = 1 then
      Exit(1);
    Exit(Value);
  end;
  if Abs(Value) <= 0.78539816339744830962 then
  begin
    case Which of
      0:
        Result := Sin(Value);
      1:
        Result := Cos(Value);
    else
      Result := Tan(Value);
    end;
    Exit;
  end;
  ReduceAngle(Abs(Value), Quadrant, HighPart, LowPart);
  S := Sin(HighPart);
  C := Cos(HighPart);
  SinValue := S + LowPart * C;
  CosValue := C - LowPart * S;
  case Quadrant of
    0:
      begin
        S := SinValue;
        C := CosValue;
      end;
    1:
      begin
        S := CosValue;
        C := -SinValue;
      end;
    2:
      begin
        S := -SinValue;
        C := -CosValue;
      end;
  else
    S := -CosValue;
    C := SinValue;
  end;
  if Value < 0 then
    S := -S;
  case Which of
    0:
      Result := S;
    1:
      Result := C;
  else
    Result := S / C;
  end;
end;

end.

