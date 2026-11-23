unit AVM1.Numeric;

interface

function AVMBinaryNumber(Op: Byte; Left, Right: Double): Double;

function AVMMathNumber(const Name: string; X, Y: Double): Double;

function AVMNumberInRadix(Value: Double; Radix: Integer): string;

implementation

uses
  System.SysUtils, System.Math, AVM1.Coercion, AVM1.Trigonometry;

function FloorDouble(Value: Double): Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Abs(Value) >= 4503599627370496.0) then
    Exit(Value);
  Result := Int(Value);
  if Value < Result then
    Result := Result - 1;
end;

function CeilDouble(Value: Double): Double;
begin
  Result := -FloorDouble(-Value);
end;

function RemainderDouble(X, Y: Double): Double;
var
  Divisor, Scaled: Double;
  Negative: Boolean;
begin
  if IsNan(X) or IsNan(Y) or IsInfinite(X) or (Y = 0) then
    Exit(NaN);
  if IsInfinite(Y) or (X = 0) then
    Exit(X);
  Negative := X < 0;
  Result := Abs(X);
  Divisor := Abs(Y);
  if Result < Divisor then
    Exit(X);
  { Binary long division. Unlike RTL FMod, this does not convert the quotient
    to Int64, and remains exact for every finite double exponent. }
  Scaled := Divisor;
  while Scaled <= Result / 2 do
    Scaled := Scaled * 2;
  while True do
  begin
    if Result >= Scaled then
      Result := Result - Scaled;
    if Scaled = Divisor then
      Break;
    Scaled := Scaled / 2;
  end;
  if Negative then
    Result := -Result;
end;

function AVMBinaryNumber(Op: Byte; Left, Right: Double): Double;
var
  SavedMask: TArithmeticExceptionMask;
begin
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
      exUnderflow, exPrecision]);
  try
    case Op of
      $0A:
        Result := Left + Right;
      $0B:
        Result := Left - Right;
      $0C:
        Result := Left * Right;
      $0D:
        Result := Left / Right;
      $3F:
        Result := RemainderDouble(Left, Right);
    else
      Result := NaN;
    end;
  finally
    ClearExceptions;
    SetExceptionMask(SavedMask);
  end;
end;

function RealPower(X, Y: Double): Double;
var
  Negative: Boolean;
  LogMagnitude: Double;
begin
  if (Y = 0) or (X = 1) then
    Exit(1);
  if IsNan(X) or IsNan(Y) then
    Exit(NaN);
  if IsInfinite(Y) then
  begin
    if Abs(X) = 1 then
      Exit(1);
    if (Abs(X) > 1) = (Y > 0) then
      Exit(Infinity);
    Exit(0);
  end;
  Negative := (X < 0) and (RemainderDouble(Abs(Y), 2) = 1);
  if IsInfinite(X) then
  begin
    if Y < 0 then
      Result := 0
    else
      Result := Infinity;
    if Negative then
      Result := -Result;
    Exit;
  end;
  if X = 0 then
  begin
    if Y < 0 then
      Result := Infinity
    else
      Result := 0;
    { Preserve the sign bit of negative zero for odd exponents. }
    if (ArcTan2(X, -1) < 0) and (RemainderDouble(Abs(Y), 2) = 1) then
      Result := -Result;
    Exit;
  end;
  if X < 0 then
  begin
    if Frac(Y) <> 0 then
      Exit(NaN);
    X := -X;
  end;
  LogMagnitude := Y * Ln(X);
  if LogMagnitude > 710 then
    Result := Infinity
  else if LogMagnitude < -746 then
    Result := 0
  else
    Result := Power(X, Y);
  if Negative then
    Result := -Result;
end;

function AVMMathNumber(const Name: string; X, Y: Double): Double;
var
  SavedMask: TArithmeticExceptionMask;
begin
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
      exUnderflow, exPrecision]);
  try
    if Name = 'floor' then
      Result := FloorDouble(X)
    else if Name = 'ceil' then
      Result := CeilDouble(X)
    else if Name = 'round' then
      Result := FloorDouble(X + 0.5)
    else if Name = 'abs' then
      Result := Abs(X)
    else if Name = 'sin' then
      Result := AVMTrig(0, X)
    else if Name = 'cos' then
      Result := AVMTrig(1, X)
    else if Name = 'tan' then
      Result := AVMTrig(2, X)
    else if Name = 'asin' then
      Result := ArcSin(X)
    else if Name = 'acos' then
      Result := ArcCos(X)
    else if Name = 'atan' then
      Result := ArcTan(X)
    else if Name = 'atan2' then
      Result := ArcTan2(X, Y)
    else if Name = 'sqrt' then
      Result := Sqrt(X)
    else if Name = 'pow' then
      Result := RealPower(X, Y)
    else if Name = 'log' then
      Result := Ln(X)
    else if Name = 'exp' then
    begin
      if X > 710 then
        Result := Infinity
      else if X < -746 then
        Result := 0
      else
        Result := Exp(X);
    end
    else if IsNan(X) or IsNan(Y) then
      Result := NaN
    else if Name = 'min' then
      Result := Min(X, Y)
    else if Name = 'max' then
      Result := Max(X, Y)
    else
      Result := NaN;
  finally
    ClearExceptions;
    SetExceptionMask(SavedMask);
  end;
end;

function AVMNumberInRadix(Value: Double; Radix: Integer): string;
var
  SignedValue, Digit: Integer;
  Magnitude: Int64;
  Negative: Boolean;
begin
  if (Radix < 2) or (Radix > 36) or (Radix = 10) then
    Exit(AVMNumberToString(Value));

  if (Value >= -2147483648.0) and (Value <= 2147483647.0) then
    SignedValue := Trunc(Value)
  else
    SignedValue := Low(Integer);
  if SignedValue = 0 then
    Exit('0');
  Negative := SignedValue < 0;
  Magnitude := SignedValue;

  if Negative and (SignedValue <> Low(Integer)) then
    Magnitude := -Magnitude;
  Result := '';
  repeat
    Digit := Magnitude mod Radix;
    Magnitude := Magnitude div Radix;
    if Digit < 10 then
      Result := Chr(Ord('0') + Digit) + Result
    else
      Result := Chr(Ord('a') + Digit - 10) + Result;
  until Magnitude = 0;
  if Negative then
    Result := '-' + Result;
end;

end.

