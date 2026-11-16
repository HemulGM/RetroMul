unit Java.Floating.Text;

interface

function JavaFloatingText(Bits: UInt64; SinglePrecision: Boolean): string;

implementation

uses
  System.SysUtils;

{$Q-}{$R-}

type
  TTextInteger = record
    Words: TArray<Cardinal>;
    class function From(Value: UInt64): TTextInteger; static;
    function Clone: TTextInteger;
    procedure Normalize;
    procedure Multiply(Factor: Cardinal);
    procedure Shift(Count: Integer);
    function Compare(const Other: TTextInteger): Integer;
    procedure Subtract(const Other: TTextInteger);
    function BitLength: Integer;
    function Low64: UInt64;
  end;

class function TTextInteger.From(Value: UInt64): TTextInteger;
begin
  SetLength(Result.Words, 2);
  Result.Words[0] := Cardinal(Value);
  Result.Words[1] := Cardinal(Value shr 32);
  Result.Normalize;
end;

function TTextInteger.Clone: TTextInteger;
begin
  Result.Words := Copy(Words);
end;

procedure TTextInteger.Normalize;
begin
  var Count := Length(Words);
  while (Count > 1) and (Words[Count - 1] = 0) do
    Dec(Count);
  if Count <> Length(Words) then
    SetLength(Words, Count);
end;

procedure TTextInteger.Multiply(Factor: Cardinal);
begin
  var Carry := UInt64(0);
  for var I := 0 to High(Words) do
  begin
    var Value := UInt64(Words[I]) * Factor + Carry;
    Words[I] := Cardinal(Value);
    Carry := Value shr 32;
  end;
  if Carry <> 0 then
  begin
    SetLength(Words, Length(Words) + 1);
    Words[High(Words)] := Cardinal(Carry);
  end;
end;

procedure TTextInteger.Shift(Count: Integer);
begin
  if Count = 0 then
    Exit;
  var Whole := Count div 32;
  var Part := Count mod 32;
  var Previous := Length(Words);
  SetLength(Words, Previous + Whole + 1);
  for var I := Previous - 1 downto 0 do
    Words[I + Whole] := Words[I];
  for var I := 0 to Whole - 1 do
    Words[I] := 0;
  var Carry := UInt64(0);
  for var I := Whole to Previous + Whole - 1 do
  begin
    var Value := (UInt64(Words[I]) shl Part) or Carry;
    Words[I] := Cardinal(Value);
    Carry := Value shr 32;
  end;
  Words[Previous + Whole] := Cardinal(Carry);
  Normalize;
end;

function TTextInteger.Compare(const Other: TTextInteger): Integer;
begin
  if Length(Words) < Length(Other.Words) then
    Exit(-1);
  if Length(Words) > Length(Other.Words) then
    Exit(1);
  for var I := High(Words) downto 0 do
  begin
    if Words[I] < Other.Words[I] then
      Exit(-1);
    if Words[I] > Other.Words[I] then
      Exit(1);
  end;
  Result := 0;
end;

procedure TTextInteger.Subtract(const Other: TTextInteger);
begin
  var Borrow := UInt64(0);
  for var I := 0 to High(Words) do
  begin
    var Part := UInt64(0);
    if I < Length(Other.Words) then
      Part := Other.Words[I];
    var Value := UInt64(Words[I]) - Part - Borrow;
    Words[I] := Cardinal(Value);
    Borrow := Value shr 63;
  end;
  Normalize;
end;

function TTextInteger.BitLength: Integer;
begin
  Result := (Length(Words) - 1) * 32;
  var Top := Words[High(Words)];
  while Top <> 0 do
  begin
    Inc(Result);
    Top := Top shr 1;
  end;
end;

function TTextInteger.Low64: UInt64;
begin
  Result := Words[0];
  if Length(Words) > 1 then
    Result := Result or (UInt64(Words[1]) shl 32);
end;

function Power5(Exponent: Integer): TTextInteger;
begin
  Result := TTextInteger.From(1);
  for var I := 1 to Exponent do
    Result.Multiply(5);
end;

function BitLength(Value: UInt64): Integer;
begin
  Result := 0;
  while Value <> 0 do
  begin
    Inc(Result);
    Value := Value shr 1;
  end;
end;

function MultiplyShift52(A, B: UInt64; out HasRemainder: Boolean): UInt64;
begin
  // A two-word product, used only to choose the decimal scale. No floating-point
  // arithmetic or caller-dependent rounding enters the digit calculation.
  var Low := UInt64(Cardinal(A)) * Cardinal(B);
  var CrossA := (A shr 32) * Cardinal(B);
  var CrossB := UInt64(Cardinal(A)) * (B shr 32);
  var Middle := (Low shr 32) + Cardinal(CrossA) + UInt64(Cardinal(CrossB));
  var Upper := (A shr 32) * (B shr 32) + (CrossA shr 32) + (CrossB shr 32) + (Middle shr 32);
  Low := (Middle shl 32) or Cardinal(Low);
  HasRemainder := (Low and ((UInt64(1) shl 52) - 1)) <> 0;
  Result := (Upper shl 12) or (Low shr 52);
end;

function DecimalScale(Mantissa: UInt64; BinaryExponent: Integer): Integer;
const
  // Fixed-point log10 tangent at 3/2, independently derived at 80-digit
  // precision: log10(2), log10(3/2), 2/(3 ln(10)), scaled by 2^52.
  LogTwo = Int64(1355718576299648);
  LogMiddle = Int64(793044528666368);
  LogSlope = UInt64(1303925644579032);
begin
  var Normal := Mantissa shl (53 - BitLength(Mantissa));
  var Delta := Int64(Normal) - 3 * (Int64(1) shl 51);
  var Remainder: Boolean;
  var Term: Int64;
  if Delta >= 0 then
    Term := Int64(MultiplyShift52(UInt64(Delta), LogSlope, Remainder))
  else
  begin
    Term := -Int64(MultiplyShift52(UInt64(-Delta), LogSlope, Remainder));
    if Remainder then
      Dec(Term);
  end;
  var Estimate := LogMiddle + Term + Int64(BinaryExponent) * LogTwo;
  if Estimate >= 0 then
    Result := Integer(UInt64(Estimate) shr 52)
  else
    Result := -Integer((UInt64(-Estimate) + (UInt64(1) shl 52) - 1) shr 52);
end;

function Render(Digits: string; Exponent: Integer; Negative: Boolean): string;
begin
  var Last := Length(Digits);
  while (Last > 1) and (Digits[Last] = '0') do
    Dec(Last);
  SetLength(Digits, Last);
  var Point := Exponent + 1;
  if (Point > 0) and (Point < 8) then
  begin
    if Last <= Point then
      Result := Digits + StringOfChar('0', Point - Last) + '.0'
    else
      Result := Copy(Digits, 1, Point) + '.' + Copy(Digits, Point + 1, MaxInt);
  end
  else if (Point > -3) and (Point <= 0) then
    Result := '0.' + StringOfChar('0', -Point) + Digits
  else
  begin
    var Tail := Copy(Digits, 2, MaxInt);
    if Tail = '' then
      Tail := '0';
    Result := Digits[1] + '.' + Tail + 'E' + IntToStr(Exponent);
  end;
  if Negative then
    Result := '-' + Result;
end;

function JavaFloatingText(Bits: UInt64; SinglePrecision: Boolean): string;
var
  Numerator, Denominator, Margin, TenDenominator: TTextInteger;
  WordSize: Integer;
  WordMargin: UInt64;
  Low, High: Boolean;

  function Digit: Integer;
  begin
    Result := 0;
    while Numerator.Compare(Denominator) >= 0 do
    begin
      Numerator.Subtract(Denominator);
      Inc(Result);
    end;
    if Result > 9 then
      raise EConvertError.Create('Floating decimal scale');
    Numerator.Multiply(10);
    if WordSize <> 0 then
    begin
      // Preserve classic Java's bounded 32/64-bit margin arithmetic. This also
      // preserves its spelling of integral/boundary cases rather than silently
      // switching to a different shortest-roundtrip formatting convention.
      WordMargin := WordMargin * 10;
      if WordSize = 32 then
        WordMargin := Cardinal(WordMargin);
      var Sign := UInt64(1) shl (WordSize - 1);
      if (WordMargin = 0) or ((WordMargin and Sign) <> 0) then
      begin
        Low := True;
        High := True;
      end
      else
      begin
        var Rest := Numerator.Low64;
        Low := Rest < WordMargin;
        var Sum := Rest + WordMargin;
        if WordSize = 32 then
          Sum := Cardinal(Sum);
        High := ((Sum and Sign) = 0) and (Sum > TenDenominator.Low64);
      end;
    end
    else
    begin
      Margin.Multiply(10);
      Low := Numerator.Compare(Margin) < 0;
      var Sum := Numerator.Clone;
      // Compare numerator+margin with ten times the denominator without a
      // general division operation. All values are nonnegative integers.
      var Carry := UInt64(0);
      var Count := Length(Sum.Words);
      if Count < Length(Margin.Words) then
        Count := Length(Margin.Words);
      SetLength(Sum.Words, Count + 1);
      for var I := 0 to Count - 1 do
      begin
        var Part := UInt64(0);
        if I < Length(Margin.Words) then
          Part := Margin.Words[I];
        var Value := UInt64(Sum.Words[I]) + Part + Carry;
        Sum.Words[I] := Cardinal(Value);
        Carry := Value shr 32;
      end;
      Sum.Words[Count] := Cardinal(Carry);
      Sum.Normalize;
      High := Sum.Compare(TenDenominator) >= 0;
    end;
  end;

begin
  var FractionBits := 52;
  var Bias := 1023;
  var Sign := UInt64(1) shl 63;
  var Infinity := UInt64($7FF0000000000000);
  if SinglePrecision then
  begin
    Bits := Cardinal(Bits);
    FractionBits := 23;
    Bias := 127;
    Sign := $80000000;
    Infinity := $7F800000;
  end;
  var Negative := (Bits and Sign) <> 0;
  Bits := Bits and not Sign;
  if Bits > Infinity then
    Exit('NaN');
  if Bits = Infinity then
  begin
    if Negative then
      Exit('-Infinity')
    else
      Exit('Infinity');
  end;
  if Bits = 0 then
  begin
    if Negative then
      Exit('-0.0')
    else
      Exit('0.0');
  end;
  var EncodedExponent := Integer(Bits shr FractionBits);
  var Mantissa := Bits and ((UInt64(1) shl FractionBits) - 1);
  var Significant := FractionBits + 1;
  if EncodedExponent = 0 then
  begin
    EncodedExponent := 1;
    Significant := BitLength(Mantissa);
  end
  else
    Mantissa := Mantissa or (UInt64(1) shl FractionBits);
  var BinaryPower := EncodedExponent - Bias - FractionBits;
  var BinaryExponent := BinaryPower + BitLength(Mantissa) - 1;
  var Odd := Mantissa;
  var Zeros := 0;
  while (Odd and 1) = 0 do
  begin
    Odd := Odd shr 1;
    Inc(Zeros);
  end;
  if (BinaryPower + Zeros >= 0) and (BinaryExponent <= 62) then
  begin
    var Number := Odd shl (BinaryPower + Zeros);
    var Insignificant := 0;
    if BinaryExponent > Significant then
      Insignificant := Length(UIntToStr(UInt64(1) shl (BinaryExponent - Significant - 1))) - 1;
    var UnitValue := UInt64(1);
    for var I := 1 to Insignificant do
      UnitValue := UnitValue * 10;
    if Insignificant <> 0 then
      Number := ((Number + UnitValue div 2) div UnitValue) * UnitValue;
    var IntegralDigits := UIntToStr(Number);
    Exit(Render(IntegralDigits, Length(IntegralDigits) - 1, Negative));
  end;
  var Exponent := DecimalScale(Mantissa, BinaryExponent);
  var FractionCount := BitLength(Odd);
  var Tiny := FractionCount - BinaryExponent - 1;
  if Tiny < 0 then
    Tiny := 0;
  var B5 := 0;
  if Exponent < 0 then
    B5 := -Exponent;
  var S5 := 0;
  if Exponent > 0 then
    S5 := Exponent;
  var B2 := B5 + Tiny + BinaryExponent;
  var S2 := S5 + Tiny;
  var M2 := B2 - Significant;
  Dec(B2, FractionCount - 1);
  var Common := B2;
  if Common > S2 then
    Common := S2;
  Dec(B2, Common);
  Dec(S2, Common);
  Dec(M2, Common);
  if FractionCount = 1 then
    Dec(M2);
  if M2 < 0 then
  begin
    Dec(B2, M2);
    Dec(S2, M2);
    M2 := 0;
  end;
  Margin := Power5(B5);
  var BCost := FractionCount + B2;
  if B5 > 0 then
    Inc(BCost, Margin.BitLength);
  Denominator := Power5(S5);
  var Scaled5 := Denominator.Clone;
  Scaled5.Multiply(5);
  var SCost := S2 + 1 + Scaled5.BitLength;
  WordSize := 0;
  if (BCost < 32) and (SCost < 32) then
    WordSize := 32
  else if (BCost < 64) and (SCost < 64) then
    WordSize := 64;
  Numerator := TTextInteger.From(Odd);
  for var I := 1 to B5 do
    Numerator.Multiply(5);
  Numerator.Shift(B2);
  Denominator.Shift(S2);
  Margin.Shift(M2);
  TenDenominator := Denominator.Clone;
  TenDenominator.Multiply(10);
  WordMargin := Margin.Low64;
  var Q := Digit;
  var Digits := '';
  if (Q = 0) and not High then
    Dec(Exponent)
  else
    Digits := Char(Ord('0') + Q);
  repeat
    Q := Digit;
    Digits := Digits + Char(Ord('0') + Q);
    if Length(Digits) > 20 then
      raise EConvertError.Create('Floating decimal precision');
  until Low or High;
  var Difference: Integer;
  if WordSize <> 0 then
  begin
    var Delta := Numerator.Low64 * 2 - TenDenominator.Low64;
    if WordSize = 32 then
      Delta := UInt64(Int64(Integer(Cardinal(Delta))));
    Difference := 0;
    if Int64(Delta) < 0 then
      Difference := -1
    else if Int64(Delta) > 0 then
      Difference := 1;
  end
  else
  begin
    var Twice := Numerator.Clone;
    Twice.Multiply(2);
    Difference := Twice.Compare(TenDenominator);
  end;
  if High and (not Low or (Difference > 0) or ((Difference = 0) and ((Q and 1) <> 0))) then
  begin
    var At := Length(Digits);
    while (At > 0) and (Digits[At] = '9') do
    begin
      Digits[At] := '0';
      Dec(At);
    end;
    if At = 0 then
    begin
      Digits[1] := '1';
      Inc(Exponent);
    end
    else
      Digits[At] := Char(Ord(Digits[At]) + 1);
  end;
  Result := Render(Digits, Exponent, Negative);
end;

end.

