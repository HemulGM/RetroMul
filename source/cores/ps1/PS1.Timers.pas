unit PS1.Timers;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types, PS1.Scheduler;

type
  // Continuous dot clock count at a CPU cycle, and the first cycle at which
  // the count reaches a value (assuming the current video mode persists).
  TPS1DotCount = function(Time: Int64): Int64 of object;

  TPS1DotTime = function(Count: Int64): Int64 of object;

  // Root counters 0..2. Counters advance lazily between synchronization
  // points: register accesses, blanking edges and scheduled IRQ reaches.
  TPS1Timers = class
  private
    type
      TTimer = record
        Counter, Mode, Target: Cardinal;
        Sync, DotSync: Int64;
        Paused, Fired, WaitBlank: Boolean;
      end;

      PTimer = ^TTimer;
  private
    FTimers: array[0..2] of TTimer;
    FScheduler: TPS1Scheduler;
    FIRQ: TPS1IRQRequest;
    FInHBlank, FInVBlank: Boolean;
    function UsesDots(Index: Integer): Boolean; inline;
    function UsesHBlankClock(Index: Integer): Boolean; inline;
    procedure Advance(Index: Integer; Ticks: Int64);
    procedure Reach(Index: Integer; TargetReaches, WrapReaches: Int64);
    procedure Sync(Index: Integer; Time: Int64);
    procedure UpdateGate(Index: Integer);
    procedure Reschedule(Index: Integer);
    procedure BlankEdge(Index: Integer; Active: Boolean; Time: Int64);
  public
    DotCount: TPS1DotCount;
    DotTime: TPS1DotTime;
    constructor Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
    procedure Reset;
    function Read(Address: Cardinal): Cardinal;
    procedure Write(Address, Value: Cardinal);
    procedure Event(Index: Integer; Time: Int64);
    // Blanking edges from the GPU. An HBlank start also clocks timer 1.
    procedure HBlank(Active: Boolean; Time: Int64);
    procedure VBlank(Active: Boolean; Time: Int64);
    // The GPU changed the dot clock rate; counts before Time stay valid.
    procedure DotClockChanged(Time: Int64);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  ModeSync = $0001;
  ModeZeroReturn = $0008;
  ModeIRQTarget = $0010;
  ModeIRQWrap = $0020;
  ModeRepeat = $0040;
  ModeToggle = $0080;
  ModeINTF = $0400;
  ModeReachedTarget = $0800;
  ModeReachedWrap = $1000;
  TimerEvents: array[0..2] of TPS1Event = (TPS1Event.Timer0, TPS1Event.Timer1, TPS1Event.Timer2);
  TimerIRQs: array[0..2] of TPS1IRQ = (TPS1IRQ.Timer0, TPS1IRQ.Timer1, TPS1IRQ.Timer2);

constructor TPS1Timers.Create(Scheduler: TPS1Scheduler; const IRQ: TPS1IRQRequest);
begin
  inherited Create;
  FScheduler := Scheduler;
  FIRQ := IRQ;
  Reset;
end;

procedure TPS1Timers.Reset;
begin
  for var I := 0 to 2 do
  begin
    FTimers[I] := Default(TTimer);
    FTimers[I].Mode := ModeINTF;
    FScheduler.Cancel(TimerEvents[I]);
  end;
  FInHBlank := False;
  FInVBlank := False;
end;

function TPS1Timers.UsesDots(Index: Integer): Boolean;
begin
  Result := (Index = 0) and ((FTimers[0].Mode and $100) <> 0) and Assigned(DotCount);
end;

function TPS1Timers.UsesHBlankClock(Index: Integer): Boolean;
begin
  Result := (Index = 1) and ((FTimers[1].Mode and $100) <> 0);
end;

// Counts how often the counter passes the target and FFFFh while advancing.
procedure TPS1Timers.Advance(Index: Integer; Ticks: Int64);
begin
  if Ticks <= 0 then
    Exit;

  var T: PTimer := @FTimers[Index];
  var Counter := Int64(T.Counter);
  var Target := Int64(T.Target);
  var TargetReaches: Int64 := 0;
  var WrapReaches: Int64 := 0;
  var ZeroReturn := (T.Mode and ModeZeroReturn) <> 0;
  if ZeroReturn and (Counter > Target) then
  begin
    // Above the target: run to FFFFh and wrap once before using the target.
    var ToWrap := $10000 - Counter;
    if Ticks < ToWrap then
    begin
      Inc(Counter, Ticks);
      if Counter = $FFFF then
        WrapReaches := 1;
      Ticks := 0;
    end
    else
    begin
      WrapReaches := Ord(Counter < $FFFF);
      Dec(Ticks, ToWrap);
      Counter := 0;
      if Target = 0 then
        Inc(TargetReaches);
    end;
  end;
  if Ticks > 0 then
  begin
    var Period: Int64 := $10000;
    if ZeroReturn then
      Period := Target + 1;
    // Visited values are Counter+1 .. Counter+Ticks modulo the period.
    var Last := Counter + Ticks;
    Inc(TargetReaches, (Last + Period - Target) div Period - (Counter + Period - Target) div Period);
    if Period = $10000 then
      Inc(WrapReaches, (Last + 1) div Period - (Counter + 1) div Period);
    Counter := Last mod Period;
  end;
  T.Counter := Cardinal(Counter);
  Reach(Index, TargetReaches, WrapReaches);
end;

procedure TPS1Timers.Reach(Index: Integer; TargetReaches, WrapReaches: Int64);
begin
  var T: PTimer := @FTimers[Index];
  if TargetReaches > 0 then
    T.Mode := T.Mode or ModeReachedTarget;
  if WrapReaches > 0 then
    T.Mode := T.Mode or ModeReachedWrap;
  var Requests: Int64 := 0;
  if (T.Mode and ModeIRQTarget) <> 0 then
    Inc(Requests, TargetReaches);
  if (T.Mode and ModeIRQWrap) <> 0 then
    Inc(Requests, WrapReaches);
  if (Requests = 0) or (T.Fired and ((T.Mode and ModeRepeat) = 0)) then
    Exit;

  if (T.Mode and ModeRepeat) = 0 then
    Requests := 1;
  T.Fired := True;
  if (T.Mode and ModeToggle) <> 0 then
  begin
    // Each request inverts INTF; the IRQ line follows INTF going low.
    var WasHigh := (T.Mode and ModeINTF) <> 0;
    if Odd(Requests) then
      T.Mode := T.Mode xor ModeINTF;
    if (T.Mode and ModeRepeat) = 0 then
      T.Mode := T.Mode and not ModeINTF;
    if WasHigh or (Requests >= 2) then
      FIRQ(TimerIRQs[Index]);
  end
  else
    // Pulse mode: INTF drops for a few cycles; it reads back as set.
    FIRQ(TimerIRQs[Index]);
end;

procedure TPS1Timers.Sync(Index: Integer; Time: Int64);
begin
  var T: PTimer := @FTimers[Index];
  if Time <= T.Sync then
    Exit;

  var Ticks: Int64;
  var Dots: Int64 := 0;
  if UsesDots(Index) then
  begin
    Dots := DotCount(Time);
    Ticks := Dots - T.DotSync;
  end
  else if UsesHBlankClock(Index) then
    Ticks := 0
  else if (Index = 2) and ((T.Mode and $200) <> 0) then
    Ticks := (Time div 8) - (T.Sync div 8)
  else
    Ticks := Time - T.Sync;
  T.Sync := Time;
  T.DotSync := Dots;
  if not T.Paused then
    Advance(Index, Ticks);
end;

procedure TPS1Timers.UpdateGate(Index: Integer);
begin
  var T: PTimer := @FTimers[Index];
  T.Paused := False;
  if (T.Mode and ModeSync) = 0 then
    Exit;

  var SyncMode := (T.Mode shr 1) and 3;
  if Index = 2 then
  begin
    T.Paused := SyncMode in [0, 3];
    Exit;
  end;
  var InBlank := FInHBlank;
  if Index = 1 then
    InBlank := FInVBlank;
  case SyncMode of
    0:
      T.Paused := InBlank;
    2:
      T.Paused := not InBlank;
    3:
      T.Paused := T.WaitBlank;
  end;
end;

procedure TPS1Timers.Reschedule(Index: Integer);
begin
  var T: PTimer := @FTimers[Index];
  FScheduler.Cancel(TimerEvents[Index]);
  if T.Paused or UsesHBlankClock(Index) or ((T.Mode and (ModeIRQTarget or ModeIRQWrap)) = 0) or
    (T.Fired and ((T.Mode and ModeRepeat) = 0)) then
    Exit;

  // Ticks until the next value that requests an IRQ.
  var Counter := Int64(T.Counter);
  var Target := Int64(T.Target);
  var Ticks: Int64 := High(Int64);
  if (T.Mode and ModeIRQTarget) <> 0 then
  begin
    if Counter < Target then
      Ticks := Target - Counter
    else if ((T.Mode and ModeZeroReturn) <> 0) and (Counter = Target) then
      Ticks := Target + 1
    else
      Ticks := $10000 - Counter + Target;
  end;
  if (T.Mode and ModeIRQWrap) <> 0 then
  begin
    var ToWrap: Int64 := $FFFF - Counter;
    if ((T.Mode and ModeZeroReturn) <> 0) and (Counter <= Target) and (Target <> $FFFF) then
      ToWrap := High(Int64)
    else if ToWrap = 0 then
      ToWrap := $10000;
    if ToWrap < Ticks then
      Ticks := ToWrap;
  end;
  if Ticks = High(Int64) then
    Exit;

  var At: Int64;
  if UsesDots(Index) then
  begin
    if not Assigned(DotTime) then
      Exit;
    At := DotTime(T.DotSync + Ticks);
  end
  else if (Index = 2) and ((T.Mode and $200) <> 0) then
    At := ((T.Sync div 8) + Ticks) * 8
  else
    At := T.Sync + Ticks;
  FScheduler.Schedule(TimerEvents[Index], At);
end;

procedure TPS1Timers.Event(Index: Integer; Time: Int64);
begin
  Sync(Index, Time);
  Reschedule(Index);
end;

function TPS1Timers.Read(Address: Cardinal): Cardinal;
begin
  var Index := Integer((Address shr 4) and 3);
  if Index > 2 then
    Exit(0);

  Sync(Index, FScheduler.Now);
  var T: PTimer := @FTimers[Index];
  case Address and $C of
    $0:
      Result := T.Counter;
    $4:
      begin
        Result := T.Mode;
        // Reached flags clear on read.
        T.Mode := T.Mode and not (ModeReachedTarget or ModeReachedWrap);
      end;
    $8:
      Result := T.Target;
  else
    Result := 0;
  end;
end;

procedure TPS1Timers.Write(Address, Value: Cardinal);
begin
  var Index := Integer((Address shr 4) and 3);
  if Index > 2 then
    Exit;

  Sync(Index, FScheduler.Now);
  var T: PTimer := @FTimers[Index];
  case Address and $C of
    $0:
      T.Counter := Value and $FFFF;
    $4:
      begin
        T.Mode := (T.Mode and (ModeReachedTarget or ModeReachedWrap)) or (Value and $3FF) or ModeINTF;
        T.Counter := 0;
        T.Fired := False;
        T.WaitBlank := (Index < 2) and ((T.Mode and ModeSync) <> 0) and (((T.Mode shr 1) and 3) = 3);
        if UsesDots(Index) then
          T.DotSync := DotCount(T.Sync);
        UpdateGate(Index);
      end;
    $8:
      T.Target := Value and $FFFF;
  end;
  Reschedule(Index);
end;

procedure TPS1Timers.BlankEdge(Index: Integer; Active: Boolean; Time: Int64);
begin
  var T: PTimer := @FTimers[Index];
  Sync(Index, Time);
  if Active and ((T.Mode and ModeSync) <> 0) then
  begin
    case (T.Mode shr 1) and 3 of
      1, 2:
        T.Counter := 0;
      3:
        T.WaitBlank := False;
    end;
  end;
  UpdateGate(Index);
  Reschedule(Index);
end;

procedure TPS1Timers.HBlank(Active: Boolean; Time: Int64);
begin
  FInHBlank := Active;
  BlankEdge(0, Active, Time);
  if Active and UsesHBlankClock(1) then
  begin
    Sync(1, Time);
    if not FTimers[1].Paused then
      Advance(1, 1);
  end;
end;

procedure TPS1Timers.VBlank(Active: Boolean; Time: Int64);
begin
  FInVBlank := Active;
  BlankEdge(1, Active, Time);
end;

procedure TPS1Timers.DotClockChanged(Time: Int64);
begin
  if UsesDots(0) then
  begin
    Sync(0, Time);
    FTimers[0].DotSync := DotCount(Time);
    Reschedule(0);
  end;
end;

procedure TPS1Timers.SerializeState(State: TStateArchive);
begin
  State.Field(FTimers, SizeOf(FTimers));
  State.Field(FInHBlank, SizeOf(FInHBlank));
  State.Field(FInVBlank, SizeOf(FInVBlank));
  if State.Loading then
    for var I := 0 to 2 do
      if (FTimers[I].Counter > $FFFF) or (FTimers[I].Target > $FFFF) then
        raise EReadError.Create('PS1 snapshot timer');
end;

end.

