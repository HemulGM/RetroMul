unit PS1.Scheduler;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types;

const
  PS1Never = High(Int64);

type
  // Time is counted in CPU cycles since power-on. Every device schedules at
  // most one pending event in its own slot; all slots are serialized.
  TPS1Scheduler = class
  private
    FDue: array[TPS1Event] of Int64;
    FNextDue: Int64;
    procedure UpdateNext;
  public
    // Advanced by the CPU and by stalls; never decreases.
    Now: Int64;
    constructor Create;
    procedure Reset;
    procedure Schedule(Event: TPS1Event; At: Int64);
    procedure Cancel(Event: TPS1Event);
    function Due(Event: TPS1Event): Int64; inline;
    function Pending(Event: TPS1Event): Boolean; inline;
    // Earliest due event not later than Now, in (time, declaration) order,
    // and the cycle it was scheduled for.
    function TakeDue(out Event: TPS1Event; out At: Int64): Boolean;
    procedure SerializeState(State: TStateArchive);
    property NextDue: Int64 read FNextDue;
  end;

implementation

constructor TPS1Scheduler.Create;
begin
  inherited Create;
  Reset;
end;

procedure TPS1Scheduler.Reset;
begin
  Now := 0;
  for var E := Low(TPS1Event) to High(TPS1Event) do
    FDue[E] := PS1Never;
  FNextDue := PS1Never;
end;

procedure TPS1Scheduler.UpdateNext;
begin
  var Next := PS1Never;
  for var E := Low(TPS1Event) to High(TPS1Event) do
    if FDue[E] < Next then
      Next := FDue[E];
  FNextDue := Next;
end;

procedure TPS1Scheduler.Schedule(Event: TPS1Event; At: Int64);
begin
  if At < Now then
    At := Now;
  FDue[Event] := At;
  if At < FNextDue then
    FNextDue := At
  else
    UpdateNext;
end;

procedure TPS1Scheduler.Cancel(Event: TPS1Event);
begin
  if FDue[Event] = PS1Never then
    Exit;

  FDue[Event] := PS1Never;
  UpdateNext;
end;

function TPS1Scheduler.Due(Event: TPS1Event): Int64;
begin
  Result := FDue[Event];
end;

function TPS1Scheduler.Pending(Event: TPS1Event): Boolean;
begin
  Result := FDue[Event] <> PS1Never;
end;

function TPS1Scheduler.TakeDue(out Event: TPS1Event; out At: Int64): Boolean;
begin
  Result := False;
  Event := Low(TPS1Event);
  At := PS1Never;
  if FNextDue > Now then
    Exit;

  for var E := Low(TPS1Event) to High(TPS1Event) do
    if (FDue[E] < At) then
    begin
      At := FDue[E];
      Event := E;
    end;
  if At > Now then
    Exit;

  FDue[Event] := PS1Never;
  UpdateNext;
  Result := True;
end;

procedure TPS1Scheduler.SerializeState(State: TStateArchive);
begin
  State.Field(Now, SizeOf(Now));
  State.Field(FDue, SizeOf(FDue));
  if State.Loading then
  begin
    if Now < 0 then
      raise EReadError.Create('PS1 snapshot scheduler time');
    for var E := Low(TPS1Event) to High(TPS1Event) do
      if (FDue[E] <> PS1Never) and (FDue[E] < 0) then
        raise EReadError.Create('PS1 snapshot scheduler event');
    UpdateNext;
  end;
end;

end.

