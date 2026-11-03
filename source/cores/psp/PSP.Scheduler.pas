unit PSP.Scheduler;

// The master clock: guest nanoseconds since power-on. Devices own one event
// slot each; ties are broken by declaration order. The CPU converts cycles at
// the current clock (MHz) with an exact remainder, so the timeline does not
// depend on how runs are sliced.
{$IFDEF PSP_CHECKED}{$Q-}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

const
  PSPNever = High(Int64);
  // The system has been up a while when a game starts.
  PSPBootNs = Int64(2000000000);

type
  TPSPEvent = (VBlank, HBlank, Kernel, Audio, GE, IO, Media, Utility, Frame);

  TPSPScheduler = class
  private
    FDue: array[TPSPEvent] of Int64;
    FNextDue: Int64;
    FMHz: Cardinal;
    FRemainder: Int64;
    procedure UpdateNext;
    procedure SetMHz(Value: Cardinal);
  public
    Now: Int64;
    constructor Create;
    procedure Reset;
    procedure Schedule(Event: TPSPEvent; At: Int64);
    procedure Cancel(Event: TPSPEvent);
    function Due(Event: TPSPEvent): Int64; inline;
    function Pending(Event: TPSPEvent): Boolean; inline;
    function TakeDue(out Event: TPSPEvent): Boolean;
    // Moves Now forward by CPU cycles at the current clock.
    procedure AddCycles(Cycles: Int64);
    // Cycles the CPU may run before Now reaches At (at least 1 when At > Now).
    function CyclesUntil(At: Int64): Int64;
    procedure AdvanceTo(At: Int64);
    function Microseconds: Int64; inline;
    property NextDue: Int64 read FNextDue;
    property MHz: Cardinal read FMHz write SetMHz;
    property Remainder: Int64 read FRemainder;
  end;

implementation

constructor TPSPScheduler.Create;
begin
  inherited Create;
  Reset;
end;

procedure TPSPScheduler.Reset;
begin
  Now := PSPBootNs;
  FRemainder := 0;
  FMHz := 222;
  for var E := Low(TPSPEvent) to High(TPSPEvent) do
    FDue[E] := PSPNever;
  FNextDue := PSPNever;
end;

procedure TPSPScheduler.SetMHz(Value: Cardinal);
begin
  if Value = 0 then
    Value := 1;
  if Value = FMHz then
    Exit;
  // Drop the sub-nanosecond remainder at a clock change; it belongs to the old rate.
  FRemainder := 0;
  FMHz := Value;
end;

procedure TPSPScheduler.UpdateNext;
begin
  var Next := PSPNever;
  for var E := Low(TPSPEvent) to High(TPSPEvent) do
    if FDue[E] < Next then
      Next := FDue[E];
  FNextDue := Next;
end;

procedure TPSPScheduler.Schedule(Event: TPSPEvent; At: Int64);
begin
  if At < Now then
    At := Now;
  var Old := FDue[Event];
  FDue[Event] := At;
  if At <= FNextDue then
    FNextDue := At
  else if Old = FNextDue then
    UpdateNext;
end;

procedure TPSPScheduler.Cancel(Event: TPSPEvent);
begin
  var Old := FDue[Event];
  if Old = PSPNever then
    Exit;
  FDue[Event] := PSPNever;
  if Old = FNextDue then
    UpdateNext;
end;

function TPSPScheduler.Due(Event: TPSPEvent): Int64;
begin
  Result := FDue[Event];
end;

function TPSPScheduler.Pending(Event: TPSPEvent): Boolean;
begin
  Result := FDue[Event] <> PSPNever;
end;

function TPSPScheduler.TakeDue(out Event: TPSPEvent): Boolean;
begin
  Event := Low(TPSPEvent);
  if FNextDue > Now then
    Exit(False);
  var At := PSPNever;
  for var E := Low(TPSPEvent) to High(TPSPEvent) do
    if FDue[E] < At then
    begin
      At := FDue[E];
      Event := E;
    end;
  if At > Now then
    Exit(False);
  FDue[Event] := PSPNever;
  UpdateNext;
  Result := True;
end;

procedure TPSPScheduler.AddCycles(Cycles: Int64);
begin
  var Total := Cycles * 1000 + FRemainder;
  Inc(Now, Total div FMHz);
  FRemainder := Total mod FMHz;
end;

function TPSPScheduler.CyclesUntil(At: Int64): Int64;
begin
  if At <= Now then
    Exit(0);
  if At = PSPNever then
    Exit(High(Integer));
  // Smallest N with Now + (N*1000 + R) div MHz >= At.
  var Need := (At - Now) * FMHz - FRemainder;
  Result := (Need + 999) div 1000;
  if Result < 1 then
    Result := 1;
  if Result > High(Integer) then
    Result := High(Integer);
end;

procedure TPSPScheduler.AdvanceTo(At: Int64);
begin
  if At > Now then
  begin
    Now := At;
    FRemainder := 0;
  end;
end;

function TPSPScheduler.Microseconds: Int64;
begin
  Result := Now div 1000;
end;

end.
