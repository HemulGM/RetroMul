unit AVM1.Coercion;

interface

function AVMParseInteger(const Text: string; HasRadix: Boolean; Radix: Integer): Double;

function AVMParseFloat(const Text: string; strict: Boolean): Double;

function AVMStringToNumber(const Text: string; SWFVersion: Byte): Double;

function AVMNumberToString(Value: Double): string;

function AVMToInt32(Value: Double): Integer;

implementation

uses
  System.SysUtils, System.Math;

function IsSpace(C: Char): Boolean;
begin
  Result := CharInSet(C, [#9, #10, #13, ' ']);
end;

function IsDigit(C: Char): Boolean;
begin
  Result := (C >= '0') and (C <= '9');
end;

function DigitValue(C: Char): Integer;
begin
  case C of
    '0'..'9':
      Result := Ord(C) - Ord('0');
    'a'..'z':
      Result := Ord(C) - Ord('a') + 10;
    'A'..'Z':
      Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function Wrap32(Value: Int64): Integer;
var
  Bits: Cardinal;
begin
  Bits := Cardinal(Value and $FFFFFFFF);
  Move(Bits, Result, SizeOf(Result));
end;

function AVMToInt32(Value: Double): Integer;
var
  Fraction, Remainder: Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Value = 0) then
    Exit(0);
  { Frac, unlike Trunc, also accepts finite values outside the Int64 range. }
  Remainder := Value - Frac(Value);
  Fraction := Frac(Remainder / 4294967296.0);
  Remainder := Fraction * 4294967296.0;
  Result := Wrap32(Trunc(Remainder));
end;

function DecimalShift(Value: Double; Exponent: Integer): Double;
var
  Base: Double;
  Magnitude: UInt64;
begin
  Base := 10;
  if Exponent > 0 then
    Magnitude := Exponent
  else
    Magnitude := UInt64(-Int64(Exponent));
  while Magnitude <> 0 do
  begin
    if (Magnitude and 1) <> 0 then
      if Exponent > 0 then
        Value := Value * Base
      else
        Value := Value / Base;
    Magnitude := Magnitude shr 1;
    Base := Base * Base;
  end;
  Result := Value;
end;

function AVMParseFloat(const Text: string; strict: Boolean): Double;
var
  Position, Start, I, Exponent, ExtraExponent: Integer;
  Negative, ExponentNegative: Boolean;
  SavedMask: TArithmeticExceptionMask;
begin
  Position := 1;
  while (Position <= Length(Text)) and IsSpace(Text[Position]) do
    Inc(Position);
  Negative := False;
  if (Position <= Length(Text)) and CharInSet(Text[Position], ['+', '-']) then
  begin
    Negative := Text[Position] = '-';
    Inc(Position);
  end;
  Start := Position;
  while (Position <= Length(Text)) and IsDigit(Text[Position]) do
    Inc(Position);
  Exponent := Position - Start - 1;
  if (Position <= Length(Text)) and (Text[Position] = '.') then
  begin
    Inc(Position);
    while (Position <= Length(Text)) and IsDigit(Text[Position]) do
      Inc(Position);
  end;
  if Position = Start then
    Exit(NaN);
  if (Position <= Length(Text)) and CharInSet(Text[Position], ['e', 'E']) then
  begin
    Inc(Position);
    ExponentNegative := False;
    if (Position <= Length(Text)) and CharInSet(Text[Position], ['+', '-']) then
    begin
      ExponentNegative := Text[Position] = '-';
      Inc(Position);
    end;
    ExtraExponent := 0;
    while (Position <= Length(Text)) and IsDigit(Text[Position]) do
    begin
      ExtraExponent := Wrap32(Int64(ExtraExponent) * 10 + Ord(Text[Position]) - Ord('0'));
      Inc(Position);
    end;
    if ExponentNegative then
      ExtraExponent := Wrap32(-Int64(ExtraExponent));
    Exponent := Wrap32(Int64(Exponent) + ExtraExponent);
  end;
  if strict and (Position <= Length(Text)) then
    Exit(NaN);
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
      exUnderflow, exPrecision]);
  try
    Result := 0;
    { Deliberately consume extra dots, as Flash does. The exponent was
      determined by validation of the first digit/dot/exponent sequence. }
    for I := Start to Length(Text) do
      if IsDigit(Text[I]) then
      begin
        Result := Result + DecimalShift(Ord(Text[I]) - Ord('0'), Exponent);
        Exponent := Wrap32(Int64(Exponent) - 1);
      end
      else if Text[I] <> '.' then
        Break;
    if Negative then
      Result := -Result;
  finally
    ClearExceptions;
    SetExceptionMask(SavedMask);
  end;
end;

function AVMParseInteger(const Text: string; HasRadix: Boolean; Radix: Integer): Double;
var
  Position, Offset, I, Digit: Integer;
  HasSign, Hex, Octal, IgnoreSign, Negative, Empty: Boolean;
  SavedMask: TArithmeticExceptionMask;
begin
  if HasRadix and ((Radix < 2) or (Radix > 36)) then
    Exit(NaN);
  HasSign := (Text <> '') and CharInSet(Text[1], ['+', '-']);
  Offset := 1;
  if HasSign then
    Inc(Offset);
  Hex := (Length(Text) > Offset) and (Text[Offset] = '0') and
    CharInSet(Text[Offset + 1], ['x', 'X']);
  Position := 1;
  IgnoreSign := False;
  if Hex then
  begin
    if HasSign then
    begin
      if not HasRadix or (Radix <= 33) then
        Exit(NaN);
      IgnoreSign := True;
    end
    else
    begin
      Position := 3;
      if not HasRadix then
        Radix := 16;
    end;
  end
  else if not HasRadix then
  begin
    Octal := (Length(Text) >= Offset) and (Text[Offset] = '0');
    for I := 2 to Length(Text) do
      if (Text[I] < '0') or (Text[I] > '7') then
        Octal := False;
    if Octal then
      Radix := 8
    else
      Radix := 10;
  end;
  while (Position <= Length(Text)) and IsSpace(Text[Position]) do
    Inc(Position);
  Negative := False;
  if (Position <= Length(Text)) and CharInSet(Text[Position], ['+', '-']) then
  begin
    Negative := (Text[Position] = '-') and not IgnoreSign;
    Inc(Position);
  end;
  Result := 0;
  Empty := True;
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
      exUnderflow, exPrecision]);
  try
    for I := Position to Length(Text) do
    begin
      Digit := DigitValue(Text[I]);
      if (Digit < 0) or (Digit >= Radix) then
        Break;
      Result := Result * Radix + Digit;
      Empty := False;
    end;
    if Empty then
      Result := NaN
    else if Negative then
      Result := -Result;
  finally
    ClearExceptions;
    SetExceptionMask(SavedMask);
  end;
end;

function AVMStringToNumber(const Text: string; SWFVersion: Byte): Double;
var
  Offset, Radix, I, Digit: Integer;
  Octal, Negative: Boolean;
  Bits: UInt64;
  SignedBits: Integer;
begin
  if SWFVersion >= 6 then
  begin
    Offset := 1;
    if (Text <> '') and CharInSet(Text[1], ['+', '-']) then
      Inc(Offset);
    Radix := 10;
    if (Length(Text) >= Offset) and (Text[Offset] = '0') then
    begin
      if (Length(Text) > Offset) and CharInSet(Text[Offset + 1], ['x', 'X']) then
        Radix := 16
      else
      begin
        Octal := True;
        for I := Offset + 1 to Length(Text) do
          if (Text[I] < '0') or (Text[I] > '7') then
            Octal := False;
        if Octal then
          Radix := 8;
      end;
    end;
    if Radix <> 10 then
    begin
      Offset := 1;
      if Radix = 16 then
        Offset := 3; { Includes Flash's signed hexadecimal prefix bug. }
      Negative := False;
      if (Length(Text) >= Offset) and CharInSet(Text[Offset], ['+', '-']) then
      begin
        Negative := Text[Offset] = '-';
        Inc(Offset);
      end;
      if Offset > Length(Text) then
        Exit(NaN);
      Bits := 0;
      for I := Offset to Length(Text) do
      begin
        Digit := DigitValue(Text[I]);
        if (Digit < 0) or (Digit >= Radix) then
          Exit(NaN);
        Bits := (Bits * UInt64(Radix) + UInt64(Digit)) and $FFFFFFFF;
      end;
      if Negative then
        SignedBits := Wrap32(-Int64(Bits))
      else
        SignedBits := Wrap32(Int64(Bits));
      Exit(SignedBits);
    end;
  end;
  Result := AVMParseFloat(Text, SWFVersion >= 5);
  if (SWFVersion < 5) and IsNan(Result) then
    Result := 0;
end;

function AVMNumberToString(Value: Double): string;
var
  Bits: UInt64;
  Exponent, BinaryExponent, I, Position: Integer;
  Scaled, Mantissa: Double;
  Negative: Boolean;
  SavedMask: TArithmeticExceptionMask;

  function NextDigit: Char;
  var
    Digit: Integer;
  begin
    Digit := Trunc(Mantissa);
    Mantissa := Mantissa - Digit;
    Mantissa := Mantissa * 10;
    Result := Chr(Ord('0') + Digit);
  end;

begin
  if IsNan(Value) then
    Exit('NaN');
  if IsInfinite(Value) then
  begin
    if Value < 0 then
      Exit('-Infinity');
    Exit('Infinity');
  end;
  if Value = 0 then
    Exit('0');
  if (Value >= -2147483648.0) and (Value <= 2147483647.0) and (Frac(Value) = 0) then
    Exit(IntToStr(Trunc(Value)));
  Negative := Value < 0;
  Result := '';
  if Negative then
  begin
    Result := '-';
    Value := -Value;
  end;
  Move(Value, Bits, SizeOf(Bits));
  BinaryExponent := Integer((Bits shr 52) and $7FF) - 1023;
  if BinaryExponent = -1023 then
  begin
    Scaled := Value * 1.801439850948198e16;
    Move(Scaled, Bits, SizeOf(Bits));
    BinaryExponent := Integer((Bits shr 52) and $7FF) - 1023 - 54;
  end;
  Scaled := BinaryExponent * 0.301029995663981;
  if Scaled < 0 then
    Exponent := -Trunc(-Scaled + 0.5)
  else
    Exponent := Trunc(Scaled + 0.5);
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
      exUnderflow, exPrecision]);
  try
    Mantissa := DecimalShift(Value, -Exponent);
    if Trunc(Mantissa) = 0 then
    begin
      Dec(Exponent);
      Mantissa := DecimalShift(Value, -Exponent);
    end;
    if Trunc(Mantissa) >= 10 then
    begin
      Inc(Exponent);
      Mantissa := DecimalShift(Value, -Exponent);
    end;
    if Exponent >= 15 then
    begin
      Result := Result + NextDigit + '.';
      for I := 1 to 14 do
        Result := Result + NextDigit;
    end
    else if Exponent >= 0 then
    begin
      Result := Result + '0';
      for I := 0 to Exponent do
        Result := Result + NextDigit;
      Result := Result + '.';
      for I := 1 to 14 - Exponent do
        Result := Result + NextDigit;
      Exponent := 0;
    end
    else if Exponent >= -5 then
    begin
      Result := Result + '00.' + StringOfChar('0', -Exponent - 1);
      for I := 1 to 15 do
        Result := Result + NextDigit;
      Exponent := 0;
    end
    else
    begin
      Result := Result + '0' + NextDigit + '.';
      for I := 1 to 14 do
        Result := Result + NextDigit;
    end;
    if NextDigit >= '5' then
      for I := Length(Result) downto 1 do
        if Result[I] = '9' then
          Result[I] := '0'
        else if Result[I] >= '0' then
        begin
          Result[I] := Chr(Ord(Result[I]) + 1);
          Break;
        end;
    while (Result <> '') and (Result[Length(Result)] = '0') do
      Delete(Result, Length(Result), 1);
    if (Result <> '') and (Result[Length(Result)] = '.') then
      Delete(Result, Length(Result), 1);
    if Exponent <> 0 then
    begin
      while (Result <> '') and (Result[1] = '0') do
        Delete(Result, 1, 1);
      if Result = '' then
      begin
        Result := '1';
        Inc(Exponent);
      end
      else
      begin
        Position := Length(Result);
        while (Position > 1) and (Result[Position] = '0') do
          Dec(Position);
        if Position = 1 then
        begin
          Inc(Exponent, Length(Result) - 1);
          SetLength(Result, 1);
        end;
      end;
      Result := Result + 'e';
      if Exponent >= 0 then
        Result := Result + '+';
      Result := Result + IntToStr(Exponent);
    end;
    Position := 1;
    if Negative then
      Inc(Position);
    if (Length(Result) >= Position) and (Result[Position] = '0') and
      ((Length(Result) = Position) or (Result[Position + 1] <> '.')) then
      Delete(Result, Position, 1);
  finally
    ClearExceptions;
    SetExceptionMask(SavedMask);
  end;
end;

end.

