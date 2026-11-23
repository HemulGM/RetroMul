unit Java.Dates;

interface

const
  JavaDayMillis = Int64(86400000);

type
  TJavaCivilDate = record
    Year: Int64;
    Month, Day, DayOfWeek, Hour, Minute, Second, Millisecond: Integer;
  end;

function JavaFloorDiv(A, B: Int64): Int64;

procedure JavaSplitMillis(Millis, Offset: Int64; out Day: Int64; out Time: Integer);

function JavaCivil(Day: Int64; Time: Integer): TJavaCivilDate;

function JavaDateDay(Year, Month, Day: Int64): Int64; // zero-based month; hybrid 1582 cutover.

function JavaDateMillis(Day, Time, Offset: Int64): Int64;

function JavaMonthDays(Year: Int64; Month: Integer): Integer;

implementation

{$Q-}{$R-}

function JavaFloorDiv(A, B: Int64): Int64;
begin
  Result := A div B;
  if (A < 0) and (A mod B <> 0) then
    Dec(Result);
end;

procedure JavaSplitMillis(Millis, Offset: Int64; out Day: Int64; out Time: Integer);
begin
  Day := JavaFloorDiv(Millis, JavaDayMillis);
  var T := Millis mod JavaDayMillis;
  if T < 0 then
    Inc(T, JavaDayMillis);
  Inc(T, Offset);
  Inc(Day, JavaFloorDiv(T, JavaDayMillis));
  T := T mod JavaDayMillis;
  if T < 0 then
    Inc(T, JavaDayMillis);
  Time := Integer(T);
end;

function JavaCivil(Day: Int64; Time: Integer): TJavaCivilDate;
var
  A, B, C, D, E, M, JDN: Int64;
begin
  var W := (Day + 4) mod 7;
  if W < 0 then
    Inc(W, 7);
  Result.DayOfWeek := Integer(W + 1);
  JDN := Day + 2440588;
  if JDN >= 2299161 then
  begin
    A := JDN + 32044;
    B := JavaFloorDiv(4 * A + 3, 146097);
    C := A - JavaFloorDiv(146097 * B, 4);
    D := JavaFloorDiv(4 * C + 3, 1461);
    E := C - JavaFloorDiv(1461 * D, 4);
    M := JavaFloorDiv(5 * E + 2, 153);
    Result.Day := Integer(E - JavaFloorDiv(153 * M + 2, 5) + 1);
    Result.Month := Integer(M + 3 - 12 * (M div 10));
    Result.Year := 100 * B + D - 4800 + M div 10;
  end
  else
  begin
    A := JDN + 32082;
    B := JavaFloorDiv(4 * A + 3, 1461);
    C := A - JavaFloorDiv(1461 * B, 4);
    M := JavaFloorDiv(5 * C + 2, 153);
    Result.Day := Integer(C - JavaFloorDiv(153 * M + 2, 5) + 1);
    Result.Month := Integer(M + 3 - 12 * (M div 10));
    Result.Year := B - 4800 + M div 10;
  end;
  Result.Hour := Time div 3600000;
  Result.Minute := Time div 60000 mod 60;
  Result.Second := Time div 1000 mod 60;
  Result.Millisecond := Time mod 1000;
end;

function JavaDateDay(Year, Month, Day: Int64): Int64;
begin
  Inc(Year, JavaFloorDiv(Month, 12));
  Month := Month mod 12;
  if Month < 0 then
    Inc(Month, 12);
  Inc(Month);
  var A := (14 - Month) div 12;
  var Y := Year + 4800 - A;
  var M := Month + 12 * A - 3;
  var Base := Day + (153 * M + 2) div 5 + 365 * Y + JavaFloorDiv(Y, 4);
  var Gregorian := Base - JavaFloorDiv(Y, 100) + JavaFloorDiv(Y, 400) - 32045;
  if Gregorian >= 2299161 then
    Result := Gregorian - 2440588
  else
    Result := Base - 32083 - 2440588;
end;

function JavaDateMillis(Day, Time, Offset: Int64): Int64;
begin
  Result := Int64(UInt64(Day) * UInt64(JavaDayMillis) + UInt64(Time) - UInt64(Offset));
end;

function JavaMonthDays(Year: Int64; Month: Integer): Integer;
const
  Lengths: array[0..11] of Integer = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
begin
  Result := Lengths[Month];
  if Month <> 1 then
    Exit;
  if (Year mod 4 = 0) and ((Year < 1582) or (Year mod 100 <> 0) or (Year mod 400 = 0)) then
    Inc(Result);
end;

end.

