unit DC.Scheduler;

{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, DC.Types;

type
  // Time counts SH-4 clocks since power-on. Each device owns one slot; the
  // SH-4 runs until NextDue, which drops as soon as an earlier event is
  // scheduled (the CPU checks it between blocks).
  TDCScheduler = class
  private
    FDue: array[TDCEvent] of Int64;
    procedure UpdateNext;
  public
    Now: Int64;
    NextDue: Int64;
    constructor Create;
    procedure Reset;
    procedure Schedule(Event: TDCEvent; At: Int64);
    procedure Cancel(Event: TDCEvent);
    function Due(Event: TDCEvent): Int64; inline;
    function Pending(Event: TDCEvent): Boolean; inline;
    // Earliest due event not later than Now, in (time, declaration) order.
    function TakeDue(out Event: TDCEvent; out At: Int64): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TDCScheduler.Create;
begin
  inherited Create;
  Reset;
end;

procedure TDCScheduler.Reset;
begin
  Now := 0;
  for var E := Low(TDCEvent) to High(TDCEvent) do
    FDue[E] := DCNever;
  NextDue := DCNever;
end;

procedure TDCScheduler.UpdateNext;
begin
  var Next := DCNever;
  for var E := Low(TDCEvent) to High(TDCEvent) do
    if FDue[E] < Next then
      Next := FDue[E];
  NextDue := Next;
end;

procedure TDCScheduler.Schedule(Event: TDCEvent; At: Int64);
begin
  if At < Now then
    At := Now;
  FDue[Event] := At;
  if At < NextDue then
    NextDue := At
  else
    UpdateNext;
end;

procedure TDCScheduler.Cancel(Event: TDCEvent);
begin
  if FDue[Event] = DCNever then
    Exit;
  FDue[Event] := DCNever;
  UpdateNext;
end;

function TDCScheduler.Due(Event: TDCEvent): Int64;
begin
  Result := FDue[Event];
end;

function TDCScheduler.Pending(Event: TDCEvent): Boolean;
begin
  Result := FDue[Event] <> DCNever;
end;

function TDCScheduler.TakeDue(out Event: TDCEvent; out At: Int64): Boolean;
begin
  Result := False;
  Event := Low(TDCEvent);
  At := DCNever;
  if NextDue > Now then
    Exit;
  for var E := Low(TDCEvent) to High(TDCEvent) do
    if FDue[E] < At then
    begin
      At := FDue[E];
      Event := E;
    end;
  if At > Now then
    Exit;
  FDue[Event] := DCNever;
  UpdateNext;
  Result := True;
end;

procedure TDCScheduler.SerializeState(State: TStateArchive);
begin
  State.Field(Now, SizeOf(Now));
  State.Field(FDue, SizeOf(FDue));
  if State.Loading then
  begin
    if Now < 0 then
      raise EReadError.Create('Dreamcast snapshot scheduler time');
    for var E := Low(TDCEvent) to High(TDCEvent) do
      if FDue[E] < 0 then
        raise EReadError.Create('Dreamcast snapshot scheduler event');
    UpdateNext;
  end;
end;

end.
