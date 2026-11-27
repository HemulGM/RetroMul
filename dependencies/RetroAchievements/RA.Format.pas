unit RA.Format;

interface

{$SCOPEDENUMS ON}

uses
  RA.MemoryValues;

type
  TRAValueFormat = (Value, Frames, Centiseconds, Seconds, SecondsAsMinutes, Minutes, Score,
    Float1, Float2, Float3, Float4, Float5, Float6, Fixed1, Fixed2, Fixed3,
    Tens, Hundreds, Thousands, Unsigned, Unformatted);

function ParseRAFormat(const Name: string): TRAValueFormat;

function FormatRAValue(Value: Integer; ValueFormat: TRAValueFormat): string; overload;

function FormatRAValue(Value: Integer; ValueFormat: TRAValueFormat; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;

function FormatRAValue(const Value: TRAMemoryValue; ValueFormat: TRAValueFormat): string; overload;

implementation

uses
  System.Math, System.SysUtils, RA.Streams, RA.Value;

const
  FloatNames: array[TRAValueFormat.Float1..TRAValueFormat.Float6] of string =
    ('FLOAT1', 'FLOAT2', 'FLOAT3', 'FLOAT4', 'FLOAT5', 'FLOAT6');
  FixedNames: array[TRAValueFormat.Fixed1..TRAValueFormat.Fixed3] of string =
    ('FIXED1', 'FIXED2', 'FIXED3');
  FixedScale: array[TRAValueFormat.Fixed1..TRAValueFormat.Fixed3] of Integer = (10, 100, 1000);

function ParseRAFormat(const Name: string): TRAValueFormat;
begin
  if (Name = 'FRAMES') or (Name = 'TIME') then
    Exit(TRAValueFormat.Frames);
  if (Name = 'SECS') or (Name = 'TIMESECS') then
    Exit(TRAValueFormat.Seconds);
  if Name = 'MILLISECS' then
    Exit(TRAValueFormat.Centiseconds);
  if Name = 'MINUTES' then
    Exit(TRAValueFormat.Minutes);
  if Name = 'SECS_AS_MINS' then
    Exit(TRAValueFormat.SecondsAsMinutes);
  if (Name = 'SCORE') or (Name = 'POINTS') or (Name = 'OTHER') then
    Exit(TRAValueFormat.Score);
  if Name = 'TENS' then
    Exit(TRAValueFormat.Tens);
  if Name = 'HUNDREDS' then
    Exit(TRAValueFormat.Hundreds);
  if Name = 'THOUSANDS' then
    Exit(TRAValueFormat.Thousands);
  if Name = 'UNSIGNED' then
    Exit(TRAValueFormat.Unsigned);
  for var ValueFormat := TRAValueFormat.Float1 to TRAValueFormat.Float6 do
    if Name = FloatNames[ValueFormat] then
      Exit(ValueFormat);
  for var ValueFormat := TRAValueFormat.Fixed1 to TRAValueFormat.Fixed3 do
    if Name = FixedNames[ValueFormat] then
      Exit(ValueFormat);
  Result := TRAValueFormat.Value;
end;

function Padded(Value: UInt64; Digits: Integer): string;
begin
  Result := UIntToStr(Value);
  if Length(Result) < Digits then
    Result := StringOfChar('0', Digits - Length(Result)) + Result;
end;

function WithCommas(const Value: string): string;
var
  Start, Cursor: Integer;
begin
  Result := Value;
  Start := 1;
  if Value.StartsWith('-') then
    Inc(Start);
  Cursor := Start;
  while (Cursor <= Length(Value)) and CharInSet(Value[Cursor], ['0'..'9']) do
    Inc(Cursor);
  Dec(Cursor, 3);
  while Cursor > Start do
  begin
    Insert(',', Result, Cursor);
    Dec(Cursor, 3);
  end;
end;

function FormatTime(Seconds: Cardinal): string;
var
  Minutes: Cardinal;
begin
  Minutes := Seconds div 60;
  Result := Padded(Seconds mod 60, 2);
  if Minutes < 60 then
    Result := UIntToStr(Minutes) + ':' + Result
  else
    Result := UIntToStr(Minutes div 60) + 'h' + Padded(Minutes mod 60, 2) + ':' + Result;
end;

function SingleBits(const Value: Single): Cardinal;
begin
  Move(Value, Result, SizeOf(Result));
end;

function RoundBinaryFraction(Numerator: UInt64; Shift: Integer; Negative: Boolean): UInt64;
var
  Divisor, Fraction, Half: UInt64;
  Mode: TRoundingMode;
begin
  if Shift < 64 then
  begin
    Divisor := UInt64(1) shl Shift;
    Result := Numerator shr Shift;
    Fraction := Numerator and (Divisor - 1);
  end
  else
  begin
    Divisor := 0;
    Result := 0;
    Fraction := Numerator;
  end;
  if Fraction = 0 then
    Exit;

  Mode := GetRoundMode;
  case Mode of
    rmNearest:
      if Divisor <> 0 then
      begin
        Half := Divisor shr 1;
        if (Fraction > Half) or ((Fraction = Half) and ((Result and 1) <> 0)) then
          Inc(Result);
      end;
    rmUp, rmDown:
      if Negative = (Mode = rmDown) then
      begin
        {$IFDEF MSWINDOWS}
        // The Windows CRT rounds a value below one tenth of the last displayed digit to zero.
        if (Divisor = 0) or (Numerator * 10 < Divisor) then
          Exit;
        {$ENDIF}
        Inc(Result);
      end;
  end;
end;

function DecimalTimesPowerOfTwo(Value: UInt64; Shift: Integer): string;
var
  Digit, Carry: Integer;
begin
  if (Shift < 64) and (Value <= High(UInt64) shr Shift) then
    Exit(UIntToStr(Value shl Shift));

  // Large Single values are exact integers, but can exceed the range of UInt64.
  Result := UIntToStr(Value);
  for var Bit := 1 to Shift do
  begin
    Carry := 0;
    for var Index := Length(Result) downto 1 do
    begin
      Digit := (Ord(Result[Index]) - Ord('0')) * 2 + Carry;
      Result[Index] := Char(Ord('0') + Digit mod 10);
      Carry := Digit div 10;
    end;
    if Carry <> 0 then
      Result := '1' + Result;
  end;
end;

function FormatRAFloat(Bits: Cardinal; ValueFormat: TRAValueFormat; GroupDigits: Boolean = True): string;
const
  DecimalScale: array[1..6] of Cardinal = (10, 100, 1000, 10000, 100000, 1000000);
var
  Magnitude, Mantissa: Cardinal;
  Negative: Boolean;
  Exponent, Digits: Integer;
  Scaled: UInt64;
begin
  Negative := (Bits and $80000000) <> 0;
  Magnitude := Bits and $7FFFFFFF;
  if Magnitude >= $7F800000 then
  begin
    if Magnitude = $7F800000 then
      Result := 'inf'

    {$IFDEF MSWINDOWS}
    else if Bits = $FFC00000 then
      Result := 'nan(ind)'

    {$ENDIF}
    else
      Result := 'nan';
    if Negative then
      Result := '-' + Result;
    Exit;
  end;

  Digits := Ord(ValueFormat) - Ord(TRAValueFormat.Float1) + 1;
  Exponent := Integer(Magnitude shr 23);
  Mantissa := Magnitude and $007FFFFF;
  if Exponent = 0 then
    Exponent := -149
  else
  begin
    Mantissa := Mantissa or $00800000;
    Dec(Exponent, 150);
  end;

  Scaled := UInt64(Mantissa) * DecimalScale[Digits];
  if Exponent < 0 then
  begin
    Scaled := RoundBinaryFraction(Scaled, -Exponent, Negative);
    Exponent := 0;
  end;
  Result := DecimalTimesPowerOfTwo(Scaled, Exponent);
  if Length(Result) <= Digits then
    Result := StringOfChar('0', Digits + 1 - Length(Result)) + Result;
  Insert('.', Result, Length(Result) - Digits + 1);
  if Negative then
    Result := '-' + Result;
  if GroupDigits then
    Result := WithCommas(Result);
end;

function FormatRAValueCore(Value: Integer; UnsignedValue: Cardinal; ValueFormat: TRAValueFormat; GroupDigits: Boolean = True): string;
var
  Scale: Cardinal;
  Digits: Integer;
begin
  case ValueFormat of
    TRAValueFormat.Frames, TRAValueFormat.Centiseconds:
      begin
        if ValueFormat = TRAValueFormat.Frames then
          UnsignedValue := Cardinal((UInt64(UnsignedValue) * 10) and $FFFFFFFF) div 6;
        Result := FormatTime(UnsignedValue div 100) + '.' + Padded(UnsignedValue mod 100, 2);
      end;
    TRAValueFormat.Seconds:
      Result := FormatTime(UnsignedValue);
    TRAValueFormat.SecondsAsMinutes, TRAValueFormat.Minutes:
      begin
        if ValueFormat = TRAValueFormat.SecondsAsMinutes then
          UnsignedValue := UnsignedValue div 60;
        Result := UIntToStr(UnsignedValue div 60) + 'h' + Padded(UnsignedValue mod 60, 2);
      end;
    TRAValueFormat.Score:
      if Value < 0 then
        Exit('-' + Padded(UInt64(-Int64(Value)), 5))
      else
        Exit(Padded(UnsignedValue, 6));
    TRAValueFormat.Fixed1..TRAValueFormat.Fixed3:
      begin
        Digits := Ord(ValueFormat) - Ord(TRAValueFormat.Fixed1) + 1;
        Scale := FixedScale[ValueFormat];
        Result := IntToStr(Int64(Value) div Scale) + '.' + Padded(Abs(Int64(Value)) mod Scale, Digits);
      end;
    TRAValueFormat.Tens..TRAValueFormat.Thousands:
      begin
        Result := IntToStr(Value);
        if Value <> 0 then
          Result := Result + StringOfChar('0', Ord(ValueFormat) - Ord(TRAValueFormat.Tens) + 1);
      end;
    TRAValueFormat.Unsigned:
      Result := UIntToStr(UnsignedValue);
    TRAValueFormat.Unformatted:
      Exit(UIntToStr(UnsignedValue));
  else
    Result := IntToStr(Value);
  end;
  if GroupDigits then
    Result := WithCommas(Result);
end;

function FormatRAValue(Value: Integer; ValueFormat: TRAValueFormat): string;
begin
  if ValueFormat in [TRAValueFormat.Float1..TRAValueFormat.Float6] then
    Exit(FormatRAFloat(SingleBits(Value), ValueFormat));
  Result := FormatRAValueCore(Value, Cardinal(Value), ValueFormat);
end;

function FormatRAValue(Value: Integer; ValueFormat: TRAValueFormat; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
var
  Text, Grouped: string;
  VisibleLength: Integer;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(Length(FormatRAValue(Value, ValueFormat)));
  if ValueFormat in [TRAValueFormat.Float1..TRAValueFormat.Float6] then
    Text := FormatRAFloat(SingleBits(Value), ValueFormat, False)
  else
    Text := FormatRAValueCore(Value, Cardinal(Value), ValueFormat, False);
  Result := CopyRAUTF8Text(Text, Buffer, BufferSize);
  if ValueFormat in [TRAValueFormat.Score, TRAValueFormat.Unformatted] then
    Exit;

  // rcheevos inserts commas only after the initial write, and only if they fit.
  if Result >= BufferSize then
  begin
    VisibleLength := Integer(BufferSize - 1);
    Inc(Result, Length(WithCommas(Copy(Text, 1, VisibleLength))) - VisibleLength);
    Exit;
  end;
  Grouped := WithCommas(Text);
  Result := Length(Grouped);
  if (Grouped <> Text) and (Result < BufferSize) then
    CopyRAUTF8Text(Grouped, Buffer, BufferSize);
end;

function FormatRAValue(const Value: TRAMemoryValue; ValueFormat: TRAValueFormat): string;
var
  SignedValue: Integer;
  UnsignedValue: Cardinal;
begin
  if ValueFormat in [TRAValueFormat.Float1..TRAValueFormat.Float6] then
  begin
    if Value.IsFloat then
      Exit(FormatRAFloat(Value.Unsigned, ValueFormat));
    Exit(FormatRAFloat(SingleBits(Value.Unsigned), ValueFormat));
  end;
  if not Value.IsFloat then
    Exit(FormatRAValueCore(Integer(Value.Unsigned), Value.Unsigned, ValueFormat));

  UnsignedValue := Cardinal(RAValueAsInteger(Value));
  SignedValue := Integer(UnsignedValue);
  // The reference applies a signed conversion for score and value formats.
  if IsNan(Value.Float) or IsInfinite(Value.Float) or
    (Value.Float < -2147483648.0) or (Value.Float >= 2147483648.0) then
    SignedValue := Low(Integer);
  Result := FormatRAValueCore(SignedValue, UnsignedValue, ValueFormat);
end;

end.

