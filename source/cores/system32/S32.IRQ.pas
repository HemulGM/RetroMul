unit S32.IRQ;

// Sega 315-5385 interrupt/timer block.
// The timer dividers follow the independently documented MAME clock wiring.
interface

uses
  Core.Snapshots;

type
  TS32Interrupts = class
  private
    FControl: array[0..15] of Byte;
    FDeadline: array[0..1] of Int64;
    FTime: Int64;
    function GetLine: Boolean;
    function GetVector: Byte;
    function GetNextEvent: Int64;
  public
    SoundIRQ: Boolean;
    constructor Create;
    procedure Reset;
    procedure Signal(Source: Integer);
    procedure RunUntil(Clock: Int64);
    function Read(Index: Integer): Byte;
    procedure Write(Index: Integer; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property IRQLine: Boolean read GetLine;
    property Vector: Byte read GetVector;
    property NextEvent: Int64 read GetNextEvent;
  end;

implementation

uses
  System.Classes, System.Math;

constructor TS32Interrupts.Create;
begin
  inherited;
  Reset;
end;

procedure TS32Interrupts.Reset;
begin
  FillChar(FControl, SizeOf(FControl), $FF);
  FDeadline[0] := -1;
  FDeadline[1] := -1;
  FTime := 0;
  SoundIRQ := False;
end;

procedure TS32Interrupts.Signal(Source: Integer);
begin
  // Registers select a source for each vector, not a vector for a source.
  // Duplicates route to the highest priority vector only.
  for var I := 0 to 4 do
    if FControl[I] and 7 = Source then
    begin
      FControl[7] := FControl[7] or (1 shl I);
      Break;
    end;
end;

function TS32Interrupts.GetLine: Boolean;
begin
  Result := FControl[7] and not FControl[6] and $1F <> 0;
end;

function TS32Interrupts.GetVector: Byte;
begin
  Result := 0;
  for var I := 0 to 4 do
    if FControl[7] and not FControl[6] and (1 shl I) <> 0 then
      Exit(I);
end;

function TS32Interrupts.GetNextEvent: Int64;
begin
  Result := High(Int64);
  for var I := 0 to 1 do
    if FDeadline[I] >= 0 then
      Result := Min(Result, FDeadline[I]);
end;

procedure TS32Interrupts.RunUntil(Clock: Int64);
begin
  FTime := Clock;
  for var I := 0 to 1 do
    if (FDeadline[I] >= 0) and (Clock >= FDeadline[I]) then
    begin
      FDeadline[I] := -1;
      Signal(3 + I);
    end;
end;

function TS32Interrupts.Read(Index: Integer): Byte;
begin
  Index := Index and 15;
  Result := $FF;
  if Index >= 12 then
    SoundIRQ := True;
  if Index in [8, 9, 10, 11] then
  begin
    var Timer := (Index - 8) shr 1;
    var Remaining: Int64 := $FFF;
    if FDeadline[Timer] >= 0 then
    begin
      var Delta := Max(Int64(0), FDeadline[Timer] - FTime);
      if Timer = 0 then
        Remaining := Max(Int64(0), (Delta + $7FF) div $800 - 1)
      else
        Remaining := Max(Int64(0), (Delta * 3125000 + Int64(256) * 16107950 - 1) div (Int64(256) * 16107950) - 1);
      Remaining := Min(Remaining, Int64($FFF));
    end;
    if Index and 1 = 0 then
      Result := Byte(Remaining)
    else
      Result := Byte(Remaining shr 8);
  end;
end;

procedure TS32Interrupts.Write(Index: Integer; Value: Byte);
begin
  Index := Index and 15;
  if Index = 7 then
    FControl[7] := FControl[7] and Value
  else
    FControl[Index] := Value;
  if Index >= 12 then
    SoundIRQ := True;
  if Index in [8, 9, 10, 11] then
  begin
    var Timer := (Index - 8) shr 1;
    var Ticks := 1 + FControl[8 + Timer * 2] + ((FControl[9 + Timer * 2] and 15) shl 8);
    // Inclusive down-count: even zero loads must produce an expiry. Carry
    // fractional timer-B clocks forward by scheduling at the first CPU tick
    // at or after the source-domain expiry, never before it.
    if Timer = 0 then
      FDeadline[Timer] := FTime + Int64(Ticks) * $800
    else
      FDeadline[Timer] := FTime + (Int64(Ticks) * 256 * 16107950 + 3124999) div 3125000;
  end;
end;

procedure TS32Interrupts.SerializeState(State: TStateArchive);
begin
  State.Field(FControl, SizeOf(FControl));
  State.Field(FDeadline, SizeOf(FDeadline));
  State.Field(FTime, SizeOf(FTime));
  State.Field(SoundIRQ, SizeOf(SoundIRQ));
  if (FTime < 0) or (FDeadline[0] < -1) or (FDeadline[1] < -1) then
    raise EReadError.Create('Invalid System 32 interrupt state');
end;

end.

