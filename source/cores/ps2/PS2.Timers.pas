unit PS2.Timers;

// EE timers 0..3 (1000_0000h + n * 800h): COUNT, MODE, COMP, HOLD. Counting is
// lazy: a counter keeps the cycle it last had a known value at; compare and
// overflow interrupts are scheduled events. Gates are not emulated.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, Core.Snapshots, PS2.Types, PS2.Scheduler;

type
  TPS2IRQRequest = procedure(Line: Integer) of object;

  TPS2TimerState = record
    Count, Mode, Comp, Hold: Cardinal;
    // Cycle at which Count was exact and the remainder of cycles below one tick.
    Base: Int64;
  end;

  TPS2Timers = class
  private
    FScheduler: TPS2Scheduler;
    FIRQ: TPS2IRQRequest;
    FLineCycles: Int64;
    procedure Sync(N: Integer);
    procedure Reschedule(N: Integer);
    function Divider(N: Integer): Int64;
  public
    T: array[0..3] of TPS2TimerState;
    constructor Create(Scheduler: TPS2Scheduler; IRQ: TPS2IRQRequest);
    procedure Reset;
    procedure SetLineCycles(Cycles: Int64);
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    // Timer N's event came due.
    procedure Event(N: Integer);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  ModeCUE = $80;
  ModeCMPE = $100;
  ModeOVFE = $200;
  ModeEQUF = $400;
  ModeOVFF = $800;
  ModeZRET = $40;
  TimerEvents: array[0..3] of TPS2Event = (TPS2Event.Timer0, TPS2Event.Timer1, TPS2Event.Timer2, TPS2Event.Timer3);

constructor TPS2Timers.Create(Scheduler: TPS2Scheduler; IRQ: TPS2IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  FLineCycles := 18743;
  Reset;
end;

procedure TPS2Timers.Reset;
begin
  for var N := 0 to 3 do
  begin
    T[N] := Default(TPS2TimerState);
    T[N].Base := FScheduler.Now;
    FScheduler.Cancel(TimerEvents[N]);
  end;
end;

procedure TPS2Timers.SetLineCycles(Cycles: Int64);
begin
  for var N := 0 to 3 do
    Sync(N);
  FLineCycles := Cycles;
  for var N := 0 to 3 do
    Reschedule(N);
end;

function TPS2Timers.Divider(N: Integer): Int64;
begin
  // EE cycles per tick: BUSCLK is EE / 2.
  case T[N].Mode and 3 of
    0: Result := 2;
    1: Result := 32;
    2: Result := 512;
  else
    Result := FLineCycles;
  end;
end;

procedure TPS2Timers.Sync(N: Integer);
begin
  var Now := FScheduler.Now;
  if (T[N].Mode and ModeCUE) = 0 then
  begin
    T[N].Base := Now;
    Exit;
  end;
  var D := Divider(N);
  var Ticks := (Now - T[N].Base) div D;
  if Ticks <= 0 then
    Exit;
  T[N].Base := T[N].Base + Ticks * D;
  var C := Int64(T[N].Count);
  var Target := Int64(T[N].Comp and $FFFF);
  // Compare: ZRET wraps to zero after reaching the compare value.
  if ((T[N].Mode and ModeZRET) <> 0) and (Target > 0) then
  begin
    if C + Ticks >= Target then
    begin
      T[N].Mode := T[N].Mode or ModeEQUF;
      C := (C + Ticks - Target) mod (Target + 1);
      if C < 0 then
        C := 0;
    end
    else
      C := C + Ticks;
  end
  else
  begin
    if (C < Target) and (C + Ticks >= Target) then
      T[N].Mode := T[N].Mode or ModeEQUF;
    C := C + Ticks;
    if C > $FFFF then
    begin
      T[N].Mode := T[N].Mode or ModeOVFF;
      C := C and $FFFF;
    end;
  end;
  T[N].Count := Cardinal(C);
end;

procedure TPS2Timers.Reschedule(N: Integer);
begin
  var Ev := TimerEvents[N];
  if ((T[N].Mode and ModeCUE) = 0) or ((T[N].Mode and (ModeCMPE or ModeOVFE)) = 0) then
  begin
    FScheduler.Cancel(Ev);
    Exit;
  end;
  var D := Divider(N);
  var C := Int64(T[N].Count);
  var Target := Int64(T[N].Comp and $FFFF);
  var Ticks: Int64 := $10000 - C;
  if ((T[N].Mode and ModeCMPE) <> 0) and (Target > C) then
    Ticks := Target - C;
  if Ticks <= 0 then
    Ticks := 1;
  FScheduler.Schedule(Ev, T[N].Base + Ticks * D);
end;

procedure TPS2Timers.Event(N: Integer);
begin
  var Before := T[N].Mode and (ModeEQUF or ModeOVFF);
  Sync(N);
  var After := T[N].Mode and (ModeEQUF or ModeOVFF);
  var Raised := After and not Before;
  if (((Raised and ModeEQUF) <> 0) and ((T[N].Mode and ModeCMPE) <> 0)) or
    (((Raised and ModeOVFF) <> 0) and ((T[N].Mode and ModeOVFE) <> 0)) then
    FIRQ(9 + N);
  Reschedule(N);
end;

function TPS2Timers.Read(Address: Cardinal): Cardinal;
begin
  var N := Integer((Address shr 11) and 3);
  case (Address shr 4) and $F of
    0:
      begin
        Sync(N);
        Result := T[N].Count;
      end;
    1: Result := T[N].Mode;
    2: Result := T[N].Comp;
    3: Result := T[N].Hold;
  else
    Result := 0;
  end;
end;

procedure TPS2Timers.Write(Address, Value: Cardinal);
begin
  var N := Integer((Address shr 11) and 3);
  Sync(N);
  case (Address shr 4) and $F of
    0: T[N].Count := Value and $FFFF;
    1:
      begin
        // EQUF and OVFF clear when written with 1.
        var Flags := T[N].Mode and (ModeEQUF or ModeOVFF) and not (Value and (ModeEQUF or ModeOVFF));
        T[N].Mode := (Value and $3FF) or Flags;
        T[N].Base := FScheduler.Now;
      end;
    2: T[N].Comp := Value and $FFFF;
    3: T[N].Hold := Value and $FFFF;
  end;
  Reschedule(N);
end;

procedure TPS2Timers.SerializeState(State: TStateArchive);
begin
  State.Field(T, SizeOf(T));
  State.Field(FLineCycles, SizeOf(FLineCycles));
end;

end.
