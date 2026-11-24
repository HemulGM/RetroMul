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
  System.SysUtils,
  System.Classes,
  Core.Snapshots;

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
    procedure UpdateNext;
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
end;

procedure TPS2Scheduler.UpdateNext;
begin
  var Next := PS2Never;
  for var E := Low(TPS2Event) to High(TPS2Event) do
    if FDue[E] < Next then
      Next := FDue[E];
  FNextDue := Next;
  if Next < Deadline then
    Deadline := Next;
end;

procedure TPS2Scheduler.Schedule(Event: TPS2Event; At: Int64);
begin
  if At < Now then
    At := Now;
  ScheduleAt(Event, At);
end;

procedure TPS2Scheduler.ScheduleAt(Event: TPS2Event; At: Int64);
begin
  var Old := FDue[Event];
  FDue[Event] := At;
  if At <= FNextDue then
  begin
    FNextDue := At;
    if At < Deadline then
      Deadline := At;
  end
  else if Old = FNextDue then
    UpdateNext;
end;

procedure TPS2Scheduler.Cancel(Event: TPS2Event);
begin
  if FDue[Event] = PS2Never then
    Exit;
  var Old := FDue[Event];
  FDue[Event] := PS2Never;
  if Old = FNextDue then
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

function TPS2Scheduler.TakeDue(out Event: TPS2Event; out At: Int64): Boolean;
begin
  Result := False;
  Event := Low(TPS2Event);
  At := PS2Never;
  if FNextDue > Now then
    Exit;
  for var E := Low(TPS2Event) to High(TPS2Event) do
    if FDue[E] < At then
    begin
      At := FDue[E];
      Event := E;
    end;
  if At > Now then
    Exit;
  FDue[Event] := PS2Never;
  UpdateNext;
  Result := True;
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
  FNextDue := S.NextDue;
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
    UpdateNext;
  end;
end;

end.
