unit PS2.Scheduler;

// Event slots in EE cycles since power-on. Every device schedules at most one
// pending event in its own slot; ties are broken by declaration order, which
// is part of the emulated behavior. Deterministic and serialized.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

{$SCOPEDENUMS ON}

const
  PS2Never = High(Int64);

type
  TPS2Event = (
    Compare,
    HBlank,
    VBlankStart,
    VBlankEnd,
    Timer0,
    Timer1,
    Timer2,
    Timer3,
    DMAC,
    GIF,
    VIF0,
    VIF1,
    IPU,
    SIF,
    IOPSync,
    IOPTimers,
    IOPDMA,
    CDVD,
    SPU2,
    SIO2,
    Alarm,
    GSSignal,
    Kernel
    );

  // A scheduler's events and time, kept to go back to.
  TPS2SchedulerSaved = record
    Due: array[TPS2Event] of Int64;
    NextDue, Now, Deadline: Int64;
  end;

  TPS2Scheduler = class
  private
    FDue: array[TPS2Event] of Int64;
    FNextDue: Int64;
    FNextEvent: TPS2Event;
    // Empty slots outside this range are never needed to find the next event.
    // The VU1 scheduler normally uses only the DMAC/GIF/VIF1 slots.
    FFirstSlot, FLastSlot: Integer;
    procedure UpdateNext;
    procedure RebuildNext;
  public
    // Advanced by the EE and by stalls; never decreases.
    Now: Int64;
    // The EE run loop stops here: min(NextDue, the caller's slice end).
    Deadline: Int64;
    constructor Create;
    procedure Reset;
    procedure Schedule(Event: TPS2Event; At: Int64);
    // The same without moving At up to Now: the VU1 domain's events run at
    // their own time, which may lie before the EE's.
    procedure ScheduleAt(Event: TPS2Event; At: Int64);
    procedure Cancel(Event: TPS2Event);
    function Due(Event: TPS2Event): Int64; inline;
    function Pending(Event: TPS2Event): Boolean; inline;
    // Earliest pending event, also when the caller owns a separate clock.
    function TakeNext(out Event: TPS2Event; out At: Int64): Boolean;
    // Earliest due event not later than Now, in (time, declaration) order.
    function TakeDue(out Event: TPS2Event; out At: Int64): Boolean;
    procedure SerializeState(State: TStateArchive);
    procedure Save(out S: TPS2SchedulerSaved);
    procedure Restore(const S: TPS2SchedulerSaved);
    property NextDue: Int64 read FNextDue;
  end;

implementation

constructor TPS2Scheduler.Create;
begin
  inherited Create;
  Reset;
end;

procedure TPS2Scheduler.Reset;
begin
  Now := 0;
  Deadline := 0;
  for var E := Low(TPS2Event) to High(TPS2Event) do
    FDue[E] := PS2Never;
  FNextDue := PS2Never;
  FNextEvent := Low(TPS2Event);
  FFirstSlot := Ord(High(TPS2Event)) + 1;
  FLastSlot := Ord(Low(TPS2Event)) - 1;
end;

procedure TPS2Scheduler.UpdateNext;
begin
  var Next := PS2Never;
  var Event := Low(TPS2Event);
  for var Slot := FFirstSlot to FLastSlot do
  begin
    var E := TPS2Event(Slot);
    if FDue[E] < Next then
    begin
      Next := FDue[E];
      Event := E;
    end;
  end;
  FNextDue := Next;
  FNextEvent := Event;
  if Next < Deadline then
    Deadline := Next;
end;

procedure TPS2Scheduler.RebuildNext;
begin
  FFirstSlot := Ord(Low(TPS2Event));
  FLastSlot := Ord(High(TPS2Event));
  while (FFirstSlot <= FLastSlot) and (FDue[TPS2Event(FFirstSlot)] = PS2Never) do
    Inc(FFirstSlot);
  while (FFirstSlot <= FLastSlot) and (FDue[TPS2Event(FLastSlot)] = PS2Never) do
    Dec(FLastSlot);
  UpdateNext;
end;

procedure TPS2Scheduler.Schedule(Event: TPS2Event; At: Int64);
begin
  if At < Now then
    At := Now;
  ScheduleAt(Event, At);
end;

procedure TPS2Scheduler.ScheduleAt(Event: TPS2Event; At: Int64);
begin
  if At = PS2Never then
  begin
    Cancel(Event);
    Exit;
  end;
  var Slot := Ord(Event);
  if Slot < FFirstSlot then
    FFirstSlot := Slot;
  if Slot > FLastSlot then
    FLastSlot := Slot;
  FDue[Event] := At;
  if At <= FNextDue then
  begin
    if (At < FNextDue) or (Event < FNextEvent) then
      FNextEvent := Event;
    FNextDue := At;
    if At < Deadline then
      Deadline := At;
  end
  else if Event = FNextEvent then
    UpdateNext;
end;

procedure TPS2Scheduler.Cancel(Event: TPS2Event);
begin
  if FDue[Event] = PS2Never then
    Exit;
  FDue[Event] := PS2Never;
  if Event = FNextEvent then
    UpdateNext;
end;

function TPS2Scheduler.Due(Event: TPS2Event): Int64;
begin
  Result := FDue[Event];
end;

function TPS2Scheduler.Pending(Event: TPS2Event): Boolean;
begin
  Result := FDue[Event] <> PS2Never;
end;

function TPS2Scheduler.TakeNext(out Event: TPS2Event; out At: Int64): Boolean;
begin
  Event := FNextEvent;
  At := FNextDue;
  Result := At <> PS2Never;
  if Result then
  begin
    FDue[Event] := PS2Never;
    UpdateNext;
  end;
end;

function TPS2Scheduler.TakeDue(out Event: TPS2Event; out At: Int64): Boolean;
begin
  if FNextDue <= Now then
    Exit(TakeNext(Event, At));
  Event := Low(TPS2Event);
  At := PS2Never;
  Result := False;
end;

procedure TPS2Scheduler.Save(out S: TPS2SchedulerSaved);
begin
  Move(FDue, S.Due, SizeOf(FDue));
  S.NextDue := FNextDue;
  S.Now := Now;
  S.Deadline := Deadline;
end;

procedure TPS2Scheduler.Restore(const S: TPS2SchedulerSaved);
begin
  Move(S.Due, FDue, SizeOf(FDue));
  // The event and scan bounds are derived from the saved slots.
  RebuildNext;
  Now := S.Now;
  Deadline := S.Deadline;
end;

procedure TPS2Scheduler.SerializeState(State: TStateArchive);
begin
  State.Field(Now, SizeOf(Now));
  State.Field(FDue, SizeOf(FDue));
  if State.Loading then
  begin
    if Now < 0 then
      raise EReadError.Create('PS2 snapshot scheduler time');
    Deadline := Now;
    RebuildNext;
  end;
end;

end.

