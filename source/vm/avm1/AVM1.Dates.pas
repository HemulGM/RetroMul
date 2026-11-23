unit AVM1.Dates;

interface

uses
  System.SysUtils, AVM1.Runtime;

procedure RegisterAVMDate(VM: TAVM1; out PrototypeObject: TAVMObject);

function AVMDateCall(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>; Index: Integer): TAVMValue;

function AVMDateFunction(VM: TAVM1): TAVMValue;

implementation

uses
  System.Math, AVM1.Numeric, AVM1.Coercion, SWF.Reader;

const
  MSSecond = 1000;
  MSMinute = 60000;
  MSHour = 3600000;
  MSDay = 86400000;
  MonthOffsets: array[Boolean, 0..12] of Integer = (
    (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365),
    (0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366));
  LocalNames: array[0..20] of string = (
    'getFullYear', 'getYear', 'getMonth', 'getDate', 'getDay', 'getHours', 'getMinutes', 'getSeconds', 'getMilliseconds',
    'setFullYear', 'setMonth', 'setDate', 'setHours', 'setMinutes', 'setSeconds', 'setMilliseconds',
    'getTime', 'setTime', 'getTimezoneOffset', 'toString', 'setYear');

type
  TDateValue = record
    Time: Double;
    function Day: Double;
    function Year: Integer;
    function Month: Integer;
    function DayWithinYear: Integer;
    function Date: Integer;
    function WeekDay: Integer;
    function Hours: Integer;
    function Minutes: Integer;
    function Seconds: Integer;
    function Milliseconds: Integer;
    function local(VM: TAVM1): TDateValue;
    function UTC(VM: TAVM1): TDateValue;
    function TimezoneOffset(VM: TAVM1): Double;
    function Clip: TDateValue;
    function TimeWithinDay(Version: Byte): Double;
    function AsString(UTCTime: Double): string;
  end;

function FloorValue(Value: Double): Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Abs(Value) >= 4503599627370496.0) then
    Exit(Value);
  Result := Int(Value);
  if Value < Result then
    Result := Result - 1;
end;

function ClampInteger(Value: Double): Integer;
begin
  if IsNan(Value) or (Value < Low(Integer)) or (Value > High(Integer)) then
    Exit(Low(Integer));
  Result := Trunc(Value);
end;

function RoundClock(Value: Double): Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Value = 0) or (Abs(Value) >= 4503599627370496.0) then
    Exit(Value);
  if Value < 0 then
    Result := -FloorValue(-Value + 0.5)
  else
    Result := FloorValue(Value + 0.5);
end;

function Modulo(Value: Double; Divisor: Integer): Integer;
begin
  Result := ClampInteger(AVMBinaryNumber($3F, Value, Divisor));
  if Result < 0 then
    Inc(Result, Divisor);
end;

function Leap(Year: Integer): Boolean;
begin
  Result := (Year mod 4 = 0) and ((Year mod 100 <> 0) or (Year mod 400 = 0));
end;

function DayFromYear(Year: Double): Double;
begin
  Result := 365.0 * (Year - 1970.0) + FloorValue((Year - 1969.0) / 4.0)
    - FloorValue((Year - 1901.0) / 100.0) + FloorValue((Year - 1601.0) / 400.0);
end;

function MakeDay(Year, Month, Date: Double): Double;
var
  M, Y: Integer;
begin
  Year := FloorValue(Year);
  Month := FloorValue(Month);
  Date := FloorValue(Date);
  Year := Year + FloorValue(Month / 12.0);
  Month := AVMBinaryNumber($3F, Month, 12);
  if Month < 0 then
    Month := Month + 12;
  Y := ClampInteger(Year);
  M := ClampInteger(Month);
  if (M < 0) or (M > 11) then
    Exit(NaN);
  Result := DayFromYear(Y) + MonthOffsets[Leap(Y), M] + Date - 1.0;
end;

function MakeTime(Hours, Minutes, Seconds, Milliseconds: Double): Double;
begin
  Result := FloorValue(Hours) * MSHour + FloorValue(Minutes) * MSMinute +
    FloorValue(Seconds) * MSSecond + FloorValue(Milliseconds);
end;

function MakeDate(Day, Time: Double): TDateValue;
begin
  Result.Time := Day * MSDay + Time;
end;

function NewDate(Year, Month, Date, Hours, Minutes, Seconds, Milliseconds: Double): TDateValue;
begin
  if Year < 100 then
    Year := Year + 1900;
  Result := MakeDate(MakeDay(Year, Month, Date), MakeTime(Hours, Minutes, Seconds, Milliseconds));
end;

function TDateValue.Day: Double;
begin
  Result := FloorValue(Time / MSDay);
end;

function TDateValue.Year: Integer;
var
  Lower, Upper, Pivot: Integer;
  Days, FromYear, NextYear: Double;
begin
  Days := Day;
  if Time < 0 then
  begin
    Lower := AVMToInt32(ClampInteger(FloorValue(Days / 365.0)) + 1970.0);
    Upper := AVMToInt32(ClampInteger(-FloorValue(-Days / 366.0)) + 1970.0);
  end
  else
  begin
    Lower := AVMToInt32(ClampInteger(FloorValue(Days / 366.0)) + 1970.0);
    Upper := AVMToInt32(ClampInteger(-FloorValue(-Days / 365.0)) + 1970.0);
  end;
  while Lower < Upper do
  begin
    Pivot := ClampInteger((Double(Lower) + Upper) / 2.0);
    FromYear := MSDay * DayFromYear(Pivot);
    NextYear := MSDay * DayFromYear(Pivot + 1.0);
    if FromYear <= Time then
    begin
      if NextYear > Time then
        Exit(Pivot);
      Lower := AVMToInt32(Pivot + 1.0);
    end
    else
      Upper := AVMToInt32(Pivot - 1.0);
  end;
  Result := Lower;
end;

function TDateValue.DayWithinYear: Integer;
begin
  Result := ClampInteger(Day - DayFromYear(Year));
end;

function TDateValue.Month: Integer;
var
  I, D: Integer;
  IsLeap: Boolean;
begin
  D := DayWithinYear;
  IsLeap := Leap(Year);
  for I := 0 to 10 do
    if D < MonthOffsets[IsLeap, I + 1] then
      Exit(I);
  Result := 11;
end;

function TDateValue.Date: Integer;
begin
  Result := AVMToInt32(Double(DayWithinYear) - MonthOffsets[Leap(Year), Month] + 1);
end;

function TDateValue.WeekDay: Integer;
begin
  Result := Modulo(Day + 4.0, 7);
end;

function TDateValue.Hours: Integer;
var
  Adjusted: Double;
begin
  Adjusted := AVMBinaryNumber($0A, Time, 0.5);
  Result := Modulo(FloorValue(Adjusted / MSHour), 24);
end;

function TDateValue.Minutes: Integer;
begin
  Result := Modulo(FloorValue(Time / MSMinute), 60);
end;

function TDateValue.Seconds: Integer;
begin
  Result := Modulo(FloorValue(Time / MSSecond), 60);
end;

function TDateValue.Milliseconds: Integer;
begin
  Result := Modulo(Time, 1000);
end;

function TDateValue.local(VM: TAVM1): TDateValue;
begin
  Result.Time := Time + VM.DateTimezoneOffset(Time, True);
end;

function TDateValue.UTC(VM: TAVM1): TDateValue;
begin
  Result.Time := Time - VM.DateTimezoneOffset(Time, False);
end;

function TDateValue.TimezoneOffset(VM: TAVM1): Double;
begin
  Result := (Time - local(VM).Time) / MSMinute;
end;

function TDateValue.Clip: TDateValue;
begin
  Result.Time := NaN;
  if not IsNan(Time) and not IsInfinite(Time) and (Abs(Time) <= 8640000000000000.0) then
    Result.Time := FloorValue(Time);
end;

function TDateValue.TimeWithinDay(Version: Byte): Double;
begin
  Result := AVMBinaryNumber($3F, Time, MSDay);
  if (Version > 7) and (Result < 0) then
    Result := Result + MSDay;
end;

function TDateValue.AsString(UTCTime: Double): string;
const
  Days: array[0..6] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  Months: array[0..11] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  Offset: Integer;
  Sign: string;
begin
  if IsNan(Time) or IsInfinite(Time) then
    Exit('Invalid Date');
  Offset := ClampInteger((Time - UTCTime) / MSMinute);
  Sign := '+';
  if Offset < 0 then
    Sign := '-';
  Result := Days[WeekDay] + ' ' + Months[Month] + ' ' + IntToStr(Date) + ' ' + Format('%.2d:%.2d:%.2d',
      [Hours, Minutes, Seconds]) + ' GMT' + Sign + Format('%.2d%.2d', [Abs(Offset) div 60, Abs(Offset) mod 60]) + ' ' + IntToStr(Year);
end;

procedure RegisterAVMDate(VM: TAVM1; out PrototypeObject: TAVMObject);
var
  I: Integer;
  Name: string;
  ConstructorValue: TAVMValue;
begin
  PrototypeObject := VM.NewObject;
  ConstructorValue := VM.Get(VM.Global, 'Date');
  VM.Put(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  VM.Put(ConstructorValue.Obj, 'UTC', VM.NativeFunction('Date.257'));
  ConstructorValue.Obj.Attributes.AddOrSetValue('UTC', 7);
  VM.Put(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 3);
  for I := 0 to 20 do
  begin
    VM.Put(PrototypeObject, LocalNames[I], VM.NativeFunction('Date.' + IntToStr(I)));
    PrototypeObject.Attributes.AddOrSetValue(LocalNames[I], 3);
    if I <= 15 then
    begin
      if I <= 8 then
        Name := 'getUTC' + Copy(LocalNames[I], 4, MaxInt)
      else
        Name := 'setUTC' + Copy(LocalNames[I], 4, MaxInt);
      VM.Put(PrototypeObject, Name, VM.NativeFunction('Date.' + IntToStr(128 + I)));
      PrototypeObject.Attributes.AddOrSetValue(Name, 3);
    end;
  end;
  { Adobe exposes the same function object for both names. }
  VM.Put(PrototypeObject, 'valueOf', VM.Get(PrototypeObject, 'getTime'));
  PrototypeObject.Attributes.AddOrSetValue('valueOf', 3);
end;

function ExecuteDate(VM: TAVM1; O: TAVMObject; const Values: TArray<Double>; Index: Integer): TAVMValue;
var
  Date, NewValue: TDateValue;
  IsUTC, IsSetYear: Boolean;
  OriginalTime, Y, M, D, H, N, S, MS: Double;

  function Value(Position: Integer; Default: Double): Double;
  begin
    Result := Default;
    if Position < Length(Values) then
      Result := Values[Position];
  end;

  function Part(PartIndex: Integer; Default: Double): Double;
  begin
    Result := Default;
    if PartIndex < Index then
      Exit;
    if PartIndex = Index then
      Default := NaN;
    Result := Value(PartIndex - Index, Default);
  end;

  function Store(Day, Time: Double): TAVMValue;
  begin
    NewValue := MakeDate(Day, Time);
    if not IsUTC then
      NewValue := NewValue.UTC(VM);
    NewValue := NewValue.Clip;
    O.DateValue := NewValue.Time;
    Result := TAVMValue.Num(NewValue.Time);
  end;

begin
  Result := Default(TAVMValue);
  if (Index = 256) or (Index = 257) then
  begin
    if (Index = 257) and (Length(Values) < 2) then
      Exit;
    if Length(Values) = 0 then
    begin
      Date.Time := VM.UtcNowMilliseconds;
      if VM.SWFVersion > 7 then
        Date.Time := RoundClock(Date.Time);
    end
    else if Length(Values) = 1 then
      Date.Time := Values[0]
    else
    begin
      Date := NewDate(Values[0], Values[1], Value(2, 1), Value(3, 0), Value(4, 0), Value(5, 0), Value(6, 0));
      if Index = 256 then
        Date := Date.UTC(VM);
    end;
    if Index = 257 then
      Exit(TAVMValue.Num(Date.Time));
    if O = nil then
      Exit;
    O.IsDate := True;
    O.DateValue := Date.Time;
    O.IsBoxed := False;
    O.ColorData := nil;
    O.PrimitiveValue := Default(TAVMValue);
    O.IsTransform := False;
    O.TransformTarget := nil;
    O.TransformPath := '';
    Exit(TAVMValue.Ref(O));
  end;
  if (O = nil) or not O.IsDate then
    Exit;
  Date.Time := O.DateValue;
  OriginalTime := Date.Time;
  if Index = 16 then
    Exit(TAVMValue.Num(Date.Time));
  if Index = 17 then
  begin
    NewValue.Time := Value(0, NaN);
    NewValue := NewValue.Clip;
    O.DateValue := NewValue.Time;
    Exit(TAVMValue.Num(NewValue.Time));
  end;
  if Index = 18 then
    Exit(TAVMValue.Num(Date.TimezoneOffset(VM)));
  IsUTC := Index >= 128;
  if IsUTC then
    Dec(Index, 128);
  if (Index >= 0) and (Index <= 8) and IsNan(Date.Time) then
    Exit(TAVMValue.Num(NaN));
  IsSetYear := Index = 20;
  if IsSetYear then
    Index := 9;
  if not IsUTC then
    Date := Date.local(VM);
  case Index of
    0:
      Result := TAVMValue.Num(Date.Year);
    1:
      Result := TAVMValue.Num(AVMToInt32(Date.Year - 1900.0));
    2:
      Result := TAVMValue.Num(Date.Month);
    3:
      Result := TAVMValue.Num(Date.Date);
    4:
      Result := TAVMValue.Num(Date.WeekDay);
    5:
      Result := TAVMValue.Num(Date.Hours);
    6:
      Result := TAVMValue.Num(Date.Minutes);
    7:
      Result := TAVMValue.Num(Date.Seconds);
    8:
      Result := TAVMValue.Num(Date.Milliseconds);
    9..11:
      begin
        Y := Part(9, Date.Year);
        M := Part(10, Date.Month);
        D := Part(11, Date.Date);
        if IsSetYear and (Y >= 0) and (Y <= 99) then
          Y := Y + 1900;
        if (Index = 10) and IsNan(M) then
          M := 0;
        Result := Store(MakeDay(Y, M, D), Date.TimeWithinDay(VM.SWFVersion));
      end;
    12..15:
      begin
        H := Part(12, Date.Hours);
        N := Part(13, Date.Minutes);
        S := Part(14, Date.Seconds);
        MS := Part(15, Date.Milliseconds);
        if Index = 13 then
        begin
          N := ClampInteger(N);
          S := ClampInteger(S);
          MS := ClampInteger(MS);
        end;
        Result := Store(Date.Day, MakeTime(H, N, S, MS));
      end;
    19:
      Result := TAVMValue.Str(Date.AsString(OriginalTime));
  else
    raise ESWFError.Create('Unsupported AVM1 Date method ' + IntToStr(Index));
  end;
end;

function AVMDateCall(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>; Index: Integer): TAVMValue;
var
  Values: TArray<Double>;
  I, Count: Integer;
  SavedMask: TArithmeticExceptionMask;
begin
  Count := 0;
  SetLength(Values, Min(7, Length(Args)));
  for I := 0 to Length(Values) - 1 do
  begin
    if Args[I].Kind = avUndefined then
      Break;
    Values[Count] := VM.CoerceNumber(Args[I]);
    Inc(Count);
  end;
  SetLength(Values, Count);
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Result := ExecuteDate(VM, O, Values, Index);
  finally
    SetExceptionMask(SavedMask);
  end;
end;

function AVMDateFunction(VM: TAVM1): TAVMValue;
var
  Date: TDateValue;
  OriginalTime: Double;
  SavedMask: TArithmeticExceptionMask;
begin
  SavedMask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    OriginalTime := VM.UtcNowMilliseconds;
    Date.Time := OriginalTime;
    Date := Date.local(VM);
    Result := TAVMValue.Str(Date.AsString(OriginalTime));
  finally
    SetExceptionMask(SavedMask);
  end;
end;

end.

