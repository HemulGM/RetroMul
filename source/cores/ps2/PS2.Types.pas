unit PS2.Types;
// Shared PlayStation 2 constants, the 128-bit register type and explicit guest
// arithmetic. Hot paths wrap explicitly; define PS2_CHECKED to enable range and
// overflow checks for diagnostics (tests). Keep hot paths optimized in
// application Debug builds as well.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

const
  PS2EEClock = 294912000;
  PS2BusClock = PS2EEClock div 2;
  PS2IOPClock = PS2EEClock div 8;
  PS2SPU2Rate = 48000;

  PS2RAMSize = $2000000;
  PS2RAMMask = PS2RAMSize - 1;
  PS2IOPRAMSize = $200000;
  PS2IOPRAMMask = PS2IOPRAMSize - 1;
  PS2BIOSSize = $400000;
  PS2BIOSMask = PS2BIOSSize - 1;
  PS2ScratchpadSize = $4000;
  PS2GSMemorySize = $400000;

  // EE cycles per field: NTSC 59.94 Hz (525 lines, 262.5 per field), PAL 50 Hz.
  PS2NTSCLines = 525;
  PS2PALLines = 625;

type
  EPS2Error = class(Exception);

  // A 128-bit EE register: Lo holds bits 0..63, Hi bits 64..127.
  TPS2Reg128 = record
    case Integer of
      0: (Lo, Hi: UInt64);
      1: (UD: array[0..1] of UInt64);
      2: (UW: array[0..3] of Cardinal);
      3: (UH: array[0..7] of Word);
      4: (UB: array[0..15] of Byte);
      5: (SD: array[0..1] of Int64);
      6: (SW: array[0..3] of Integer);
      7: (SH: array[0..7] of SmallInt);
      8: (SB: array[0..15] of ShortInt);
      9: (F: array[0..3] of Single);
  end;
  PPS2Reg128 = ^TPS2Reg128;

  // Register fields: 0..31, and 32 the sink that writes to $zero go to.
  TPS2RegIndex = 0..32;
  TPS2Field = 0..31;

  TPS2ClockTime = record
    Year, Month, Day, Hour, Minute, Second: Word;
  end;

function Add32(A, B: Cardinal): Cardinal; inline;
function Sub32(A, B: Cardinal): Cardinal; inline;
function Add64(A, B: UInt64): UInt64; inline;
function Sub64(A, B: UInt64): UInt64; inline;
function SX8(Value: UInt64): UInt64; inline;
function SX16(Value: UInt64): UInt64; inline;
function SX32(Value: UInt64): UInt64; inline;
function SX16To32(Value: Cardinal): Cardinal; inline;
function SignedLess(A, B: UInt64): Boolean; inline;
// The console's real-time clock EE cycles after power-on: 2004-01-01
// 12:00:00 plus emulated time. Never host time, so runs and snapshots repeat.
function PS2ClockAt(Cycles: Int64): TPS2ClockTime;
function PS2BCD(Value: Integer): Byte; inline;

implementation

function Add32(A, B: Cardinal): Cardinal;
begin
  {$IFDEF PS2_CHECKED}
  Result := Cardinal((UInt64(A) + B) and $FFFFFFFF);
  {$ELSE}
  Result := A + B;
  {$ENDIF}
end;

function Sub32(A, B: Cardinal): Cardinal;
begin
  {$IFDEF PS2_CHECKED}
  Result := Cardinal((UInt64(A) + (not B) + 1) and $FFFFFFFF);
  {$ELSE}
  Result := A - B;
  {$ENDIF}
end;

function Add64(A, B: UInt64): UInt64;
begin
  {$IFDEF PS2_CHECKED}
  if B > not A then
    Result := B - (not A) - 1
  else
    Result := A + B;
  {$ELSE}
  Result := A + B;
  {$ENDIF}
end;

function Sub64(A, B: UInt64): UInt64;
begin
  {$IFDEF PS2_CHECKED}
  if A >= B then
    Result := A - B
  else
    Result := A + (not B) + 1;
  {$ELSE}
  Result := A - B;
  {$ENDIF}
end;

function SX8(Value: UInt64): UInt64;
begin
  Result := UInt64(Int64(ShortInt(Byte(Value))));
end;

function SX16(Value: UInt64): UInt64;
begin
  Result := UInt64(Int64(SmallInt(Word(Value))));
end;

function SX32(Value: UInt64): UInt64;
begin
  Result := UInt64(Int64(Integer(Cardinal(Value))));
end;

function SX16To32(Value: Cardinal): Cardinal;
begin
  Result := Cardinal(Integer(SmallInt(Word(Value))));
end;

function SignedLess(A, B: UInt64): Boolean;
begin
  Result := Int64(A) < Int64(B);
end;

function PS2ClockAt(Cycles: Int64): TPS2ClockTime;
begin
  if Cycles < 0 then
    Cycles := 0;
  // Integer days and seconds: fractional TDateTime arithmetic can decode
  // an exact second as the previous one.
  var Secs := 12 * 3600 + Cycles div PS2EEClock;
  var Day := Secs mod 86400;
  DecodeDate(Trunc(EncodeDate(2004, 1, 1)) + Secs div 86400, Result.Year, Result.Month, Result.Day);
  Result.Hour := Word(Day div 3600);
  Result.Minute := Word((Day div 60) mod 60);
  Result.Second := Word(Day mod 60);
end;

function PS2BCD(Value: Integer): Byte;
begin
  Result := Byte((((Value div 10) mod 10) shl 4) or (Value mod 10));
end;

end.
