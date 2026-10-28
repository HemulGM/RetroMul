unit N64.Timing;
// Runs without range and overflow checks (every index is masked and all
// guest arithmetic wraps explicitly); N64_CHECKED builds them in, for the
// tests.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  TN64EventKind = (VIHalfLine, OutputSample, AIConsume, SPTransfer,
    PITransfer, SITransfer, RSPClock, DPInterrupt);

  TN64Event = record
    Due, Sequence: UInt64;
    Kind: TN64EventKind;
  end;

  TN64EventArray = array[0..31] of TN64Event;

  TN64Timeline = class
  private
    FNow, FSequence: UInt64;
    FCount: Integer;
    // Stored latest-first, so the next queued event is FEvents[FCount - 1].
    // Equal due times keep scheduling order: the earlier sequence pops first.
    // Snapshots use the earliest-first layout (see SerializeState).
    FEvents: TN64EventArray;
    // The RSP clock is rescheduled every one or two PClocks; it lives in a
    // dedicated slot ordered against FEvents by (Due, Sequence).
    FFast: TN64Event;
    FFastActive: Boolean;
    // Queued events per kind, including the fast slot.
    FKindCount: array[TN64EventKind] of Integer;
    // RSP run-ahead: the next FAheadLeft RSP clocks of the fast slot were
    // already executed by the console. The timeline handles them itself
    // (Materialize), in their place in event order, exactly as the console's
    // RSPClock handler would: the next clock is scheduled one or two PClocks
    // later with the next sequence number. FHorizon is the clock after them.
    FAheadLeft, FAheadDone: Integer;
    FHorizon: UInt64;
    FMaterialized: UInt64;
    // Between Pop returning an event and the next AdvanceTo or failed Pop:
    // that event is being handled, so RSP clocks after it in order are not
    // yet due. Otherwise every RSP clock due up to Now precedes the caller.
    FInEvent: Boolean;
    // NextDue, kept up to date by every change of the queue or the fast slot;
    // FNextHard likewise, SP DMA beats aside.
    FNextDue, FNextHard: UInt64;
    class procedure RaiseBackwards; static;
    class procedure RaiseFull; static;
    procedure CountKinds;
    function FastFirst: Boolean; inline;
    procedure MaterializeOne;
    procedure MaterializeTo(Limit: UInt64);
    procedure MaterializeCurrent; inline;
    procedure UpdateNext; inline;
  public
    procedure Reset;
    procedure Schedule(Kind: TN64EventKind; Delay: UInt64);
    procedure Cancel(Kind: TN64EventKind);
    function Pending(Kind: TN64EventKind): Boolean; inline;
    function Count(Kind: TN64EventKind): Integer; inline;
    // The first queued event of Kind in handling order (False: none).
    function FirstOf(Kind: TN64EventKind; out Event: TN64Event): Boolean;
    function NextDue: UInt64; inline;
    // The next event due other than an SP DMA beat (those may wait: the
    // console runs them when anything could tell).
    function NextHard: UInt64; inline;
    procedure AdvanceTo(Tick: UInt64); inline;
    function Pop(out Event: TN64Event): Boolean;
    procedure SerializeState(State: TStateArchive);
    // The next RSP clock, queued in the fast slot (Pending(RSPClock)).
    function RSPDue: UInt64; inline;
    // RSP run-ahead. SetAhead: the console executed the next Clocks RSP clocks
    // (0 ends run-ahead). SyncAhead: the clocks among them that precede the
    // caller are handled; returns how many of the run-ahead clocks that is.
    // EndAhead: no further clock counts as executed (the console rewound the
    // RSP to the current point). The handled clock count feeds the RSP phase.
    procedure SetAhead(Clocks: Integer);
    function SyncAhead: Integer; inline;
    procedure EndAhead;
    function AheadLeft: Integer; inline;
    function TakeMaterialized: UInt64;
    property Now: UInt64 read FNow;
  end;

// The PClock after Tick at which the next RCP-clock event is due: RCP clocks
// run at two thirds of the CPU clock (one or two PClocks apart). After any
// tick, the following ones are exactly the PClocks T with T mod 3 <> 1.
function NextRCPClock(Tick: UInt64): UInt64; inline;
// X mod 3, without a division.

function Mod3(X: UInt64): Cardinal; inline;
// RCP ticks in (A, B] (B >= A), and the Count-th tick after A (Count >= 1).

function RCPTicksBetween(A, B: UInt64): UInt64; inline;

function RCPTickAfter(A, Count: UInt64): UInt64;

implementation

function Mod3(X: UInt64): Cardinal;
begin
  // 2^16 = 1 (mod 3): the sum of the 16-bit parts (below 2^18), folded once
  // more (below 65539), then the quotient by a multiply (exact below 98304).
  var S := Cardinal(X and $FFFF) + Cardinal((X shr 16) and $FFFF) + Cardinal((X shr 32) and $FFFF) + Cardinal(X shr 48);
  S := (S and $FFFF) + (S shr 16);
  Result := S - 3 * ((S * $AAAB) shr 17);
end;

function NextRCPClock(Tick: UInt64): UInt64;
begin
  if Mod3(Tick) = 0 then
    Result := Tick + 2
  else
    Result := Tick + 1;
end;

function RCPTicksBetween(A, B: UInt64): UInt64;
begin
  // (B - A) PClocks less those with T mod 3 = 1, of which there are
  // (X + 2) div 3 in 0..X: with A = 3Q + R, (R + D + 2) div 3 less
  // (R + 2) div 3 of them in (A, A + D] (a 32-bit quotient by a multiply
  // when D is small).
  var D := B - A;
  if D < $80000000 then
  begin
    var R := Mod3(A);
    Result := D + Cardinal(Ord(R >= 1)) - ((UInt64(Cardinal(D) + R + 2) * $AAAAAAAB) shr 33);
  end
  else
    Result := D - ((B + 2) div 3 - (A + 2) div 3);
end;

function RCPTickAfter(A, Count: UInt64): UInt64;
const
  // The PClocks of the first and second tick after A, from A, by A mod 3.
  Offsets: array[0..2, 1..2] of Byte = ((2, 3), (1, 2), (1, 3));
begin
  // Every three PClocks after A hold two ticks, the same way each time: the
  // (2Q + S)-th tick (S = 1, 2) is 3Q PClocks after the S-th.
  if Count > (High(UInt64) - A) div 2 then
    raise ERangeError.Create('N64 guest timeline exceeds representable time');
  var Q := (Count - 1) shr 1;
  Result := A + Q * 3 + Offsets[Mod3(A), Count - Q * 2];
end;

procedure TN64Timeline.UpdateNext;
begin
  var Next := High(UInt64);
  if FCount > 0 then
    Next := FEvents[FCount - 1].Due;
  var Hard := High(UInt64);
  var I := FCount - 1;
  while (I >= 0) and (FEvents[I].Kind = TN64EventKind.SPTransfer) do
    Dec(I);
  if I >= 0 then
    Hard := FEvents[I].Due;
  // Run-ahead clocks need no handler: the first one that does is the horizon.
  if FAheadLeft > 0 then
  begin
    if FHorizon < Next then
      Next := FHorizon;
    if FHorizon < Hard then
      Hard := FHorizon;
  end
  else if FFastActive then
  begin
    if FFast.Due < Next then
      Next := FFast.Due;
    if FFast.Due < Hard then
      Hard := FFast.Due;
  end;
  FNextDue := Next;
  FNextHard := Hard;
end;

procedure TN64Timeline.Reset;
begin
  FNow := 0;
  FSequence := 0;
  FCount := 0;
  for var I := 0 to High(FEvents) do
    FEvents[I] := Default(TN64Event);
  FFast := Default(TN64Event);
  FFastActive := False;
  FAheadLeft := 0;
  FAheadDone := 0;
  FHorizon := 0;
  FMaterialized := 0;
  FInEvent := False;
  CountKinds;
  UpdateNext;
end;

class procedure TN64Timeline.RaiseFull;
begin
  raise ERangeError.Create('N64 guest timeline exceeds representable time');
end;

function TN64Timeline.RSPDue: UInt64;
begin
  Result := FFast.Due;
end;

function TN64Timeline.AheadLeft: Integer;
begin
  Result := FAheadLeft;
end;

procedure TN64Timeline.SetAhead(Clocks: Integer);
begin
  // The fast slot holds the RSP clock that follows the one being handled.
  if (Clocks < 0) or ((Clocks > 0) and (not FFastActive or (FFast.Kind <> TN64EventKind.RSPClock) or (FAheadLeft <> 0))) then
    raise EInvalidOpException.Create('N64 RSP run-ahead without a queued RSP clock');
  FAheadLeft := Clocks;
  FAheadDone := 0;
  FHorizon := FFast.Due;
  if Clocks > 0 then
    FHorizon := RCPTickAfter(FFast.Due, UInt64(Clocks));
  UpdateNext;
end;

procedure TN64Timeline.MaterializeOne;
begin
  // What Pop + the RSPClock handler + ScheduleRSP do for an executed clock.
  if (FFast.Due >= High(UInt64) - 2) or (FSequence = High(UInt64)) then
    RaiseFull;
  FFast.Due := NextRCPClock(FFast.Due);
  FFast.Sequence := FSequence;
  Inc(FSequence);
  Dec(FAheadLeft);
  Inc(FAheadDone);
  Inc(FMaterialized);
  // The exposed deadline stays FHorizon, including when the last
  // executed clock reaches it. Neither NextDue nor NextHard changes.
end;

procedure TN64Timeline.MaterializeTo(Limit: UInt64);
begin
  // The run-ahead clocks due by Limit, at once: each would have scheduled the
  // next tick with the next sequence number.
  if (FAheadLeft = 0) or (FFast.Due > Limit) then
    Exit;
  // SP DMA beats often leave exactly one executed RSP clock due.
  // Avoid the general tick-count and tick-position arithmetic for it.
  if (FAheadLeft = 1) or (Limit < NextRCPClock(FFast.Due)) then
  begin
    MaterializeOne;
    Exit;
  end;
  var Count := 1 + RCPTicksBetween(FFast.Due, Limit);
  if Count > UInt64(FAheadLeft) then
    Count := UInt64(FAheadLeft);
  if FSequence > High(UInt64) - Count then
    RaiseFull;
  FFast.Due := RCPTickAfter(FFast.Due, Count);
  FFast.Sequence := FSequence + Count - 1;
  Inc(FSequence, Count);
  Dec(FAheadLeft, Integer(Count));
  Inc(FAheadDone, Integer(Count));
  Inc(FMaterialized, Count);
  // The exposed deadline stays FHorizon, including when the last
  // executed clock reaches it. Neither NextDue nor NextHard changes.
end;

procedure TN64Timeline.MaterializeCurrent;
begin
  // Outside a handler every RSP clock due by Now precedes the caller.
  if not FInEvent then
    MaterializeTo(FNow);
end;

function TN64Timeline.SyncAhead: Integer;
begin
  MaterializeCurrent;
  Result := FAheadDone;
end;

procedure TN64Timeline.EndAhead;
begin
  FAheadLeft := 0;
  FAheadDone := 0;
  FHorizon := FFast.Due;
  UpdateNext;
end;

function TN64Timeline.TakeMaterialized: UInt64;
begin
  Result := FMaterialized;
  FMaterialized := 0;
end;

procedure TN64Timeline.CountKinds;
begin
  for var Kind := Low(TN64EventKind) to High(TN64EventKind) do
    FKindCount[Kind] := 0;
  for var I := 0 to FCount - 1 do
    Inc(FKindCount[FEvents[I].Kind]);
  if FFastActive then
    Inc(FKindCount[FFast.Kind]);
end;

function TN64Timeline.FastFirst: Boolean;
begin
  // True when the fast slot is the earliest queued event.
  Result := FFastActive and ((FCount = 0) or (FFast.Due < FEvents[FCount - 1].Due) or
    ((FFast.Due = FEvents[FCount - 1].Due) and (FFast.Sequence < FEvents[FCount - 1].Sequence)));
end;

procedure TN64Timeline.Schedule(Kind: TN64EventKind; Delay: UInt64);
begin
  // Run-ahead RSP clocks before the caller take their sequence numbers first.
  if FAheadLeft > 0 then
    MaterializeCurrent;
  if (Delay >= High(UInt64) - FNow) or (FSequence = High(UInt64)) then
    raise ERangeError.Create('N64 guest timeline exceeds representable time');
  if FCount + Ord(FFastActive) = Length(FEvents) then
    raise ERangeError.Create('N64 event queue is full');
  Inc(FKindCount[Kind]);
  if (Kind = TN64EventKind.RSPClock) and FFastActive then
    raise EInvalidOpException.Create('N64 RSP clock scheduled twice');
  if (Kind = TN64EventKind.RSPClock) and not FFastActive then
  begin
    // An inactive slot is all zero (Reset/Pop/Cancel), padding included.
    FFast.Due := FNow + Delay;
    FFast.Sequence := FSequence;
    FFast.Kind := Kind;
    FFastActive := True;
    Inc(FSequence);
    if FFast.Due < FNextDue then
      FNextDue := FFast.Due;
    if FFast.Due < FNextHard then
      FNextHard := FFast.Due;
    Exit;
  end;
  var Due := FNow + Delay;
  if (FCount = 0) or (Due < FEvents[FCount - 1].Due) then
  begin
    // The inactive tail is zeroed by Reset/Pop/Cancel/load. The usual
    // next DMA beat goes straight there without a temporary record/Move.
    FEvents[FCount].Due := Due;
    FEvents[FCount].Sequence := FSequence;
    FEvents[FCount].Kind := Kind;
    Inc(FSequence);
    Inc(FCount);
    if Due < FNextDue then
      FNextDue := Due;
    if (Kind <> TN64EventKind.SPTransfer) and (Due < FNextHard) then
      FNextHard := Due;
    Exit;
  end;
  var E := Default(TN64Event);
  E.Due := FNow + Delay;
  E.Sequence := FSequence;
  E.Kind := Kind;
  Inc(FSequence);
  // The new event has the largest sequence, so it pops after every queued
  // event due at the same time and goes below them in this latest-first array.
  var I := FCount;
  while (I > 0) and (FEvents[I - 1].Due <= E.Due) do
  begin
    FEvents[I] := FEvents[I - 1];
    Dec(I)
  end;
  FEvents[I] := E;
  Inc(FCount);
  // Insertion can only lower the cached deadlines. SP beats are omitted
  // from NextHard, so adding one never requires rescanning that deadline.
  if E.Due < FNextDue then
    FNextDue := E.Due;
  if (Kind <> TN64EventKind.SPTransfer) and (E.Due < FNextHard) then
    FNextHard := E.Due;
end;

procedure TN64Timeline.Cancel(Kind: TN64EventKind);
begin
  if FAheadLeft > 0 then
  begin
    MaterializeCurrent;
    if (Kind = TN64EventKind.RSPClock) and (FAheadLeft > 0) then
      raise EInvalidOpException.Create('N64 RSP clock cancelled during run-ahead');
  end;
  if FKindCount[Kind] = 0 then
    Exit;
  if FFastActive and (FFast.Kind = Kind) then
  begin
    FFast := Default(TN64Event);
    FFastActive := False;
  end;
  var N := 0;
  for var I := 0 to FCount - 1 do
    if FEvents[I].Kind <> Kind then
    begin
      FEvents[N] := FEvents[I];
      Inc(N)
    end;
  for var I := N to FCount - 1 do
    FEvents[I] := Default(TN64Event);
  FCount := N;
  FKindCount[Kind] := 0;
  UpdateNext;
end;

function TN64Timeline.Pending(Kind: TN64EventKind): Boolean;
begin
  Result := FKindCount[Kind] > 0;
end;

function TN64Timeline.Count(Kind: TN64EventKind): Integer;
begin
  Result := FKindCount[Kind];
end;

function TN64Timeline.FirstOf(Kind: TN64EventKind; out Event: TN64Event): Boolean;
begin
  Event := Default(TN64Event);
  Result := False;
  if FFastActive and (FFast.Kind = Kind) then
  begin
    Event := FFast;
    Result := True;
  end;
  for var I := 0 to FCount - 1 do
    if (FEvents[I].Kind = Kind) and (not Result or (FEvents[I].Due < Event.Due) or
      ((FEvents[I].Due = Event.Due) and (FEvents[I].Sequence < Event.Sequence))) then
    begin
      Event := FEvents[I];
      Result := True;
    end;
end;

function TN64Timeline.NextDue: UInt64;
begin
  Result := FNextDue;
end;

function TN64Timeline.NextHard: UInt64;
begin
  Result := FNextHard;
end;

class procedure TN64Timeline.RaiseBackwards;
begin
  raise ERangeError.Create('N64 timeline cannot run backwards');
end;

procedure TN64Timeline.AdvanceTo(Tick: UInt64);
begin
  if Tick < FNow then
    RaiseBackwards;
  FNow := Tick;
  FInEvent := False;
end;

function TN64Timeline.Pop(out Event: TN64Event): Boolean;
begin
  if FAheadLeft > 0 then
  begin
    // Handle the run-ahead RSP clocks that precede the first queued event:
    // all those due before it at once, then one due with it if it was
    // scheduled first.
    var Limit := FNow;
    if (FCount > 0) and (FEvents[FCount - 1].Due <= Limit) then
      if FEvents[FCount - 1].Due = 0 then
        Limit := 0
      else
        Limit := FEvents[FCount - 1].Due - 1;
    if (FCount = 0) or (FEvents[FCount - 1].Due > 0) then
      MaterializeTo(Limit);
    while (FAheadLeft > 0) and (FFast.Due <= FNow) and ((FCount = 0) or (FFast.Due < FEvents[FCount - 1].Due) or
        ((FFast.Due = FEvents[FCount - 1].Due) and (FFast.Sequence < FEvents[FCount - 1].Sequence))) do
      MaterializeOne;
    if FAheadLeft > 0 then
    begin
      // The fast slot is a run-ahead clock after the first queued event.
      Result := (FCount > 0) and (FEvents[FCount - 1].Due <= FNow);
      if not Result then
      begin
        Event := Default(TN64Event);
        FInEvent := False;
        Exit
      end;
      Dec(FCount);
      Event := FEvents[FCount];
      FEvents[FCount] := Default(TN64Event);
      Dec(FKindCount[Event.Kind]);
      FInEvent := True;
      if Event.Kind = TN64EventKind.SPTransfer then
      begin
        FNextDue := FNextHard;
        if (FCount > 0) and (FEvents[FCount - 1].Due < FNextDue) then
          FNextDue := FEvents[FCount - 1].Due;
      end
      else
        UpdateNext;
      Exit;
    end;
  end;
  if FastFirst then
  begin
    Result := FFast.Due <= FNow;
    if not Result then
    begin
      Event := Default(TN64Event);
      FInEvent := False;
      Exit
    end;
    Event := FFast;
    FFast.Due := 0;
    FFast.Sequence := 0;
    FFast.Kind := Low(TN64EventKind);
    FFastActive := False;
  end
  else
  begin
    Result := (FCount > 0) and (FEvents[FCount - 1].Due <= FNow);
    if not Result then
    begin
      Event := Default(TN64Event);
      FInEvent := False;
      Exit
    end;
    Dec(FCount);
    Event := FEvents[FCount];
    FEvents[FCount] := Default(TN64Event);
  end;
  Dec(FKindCount[Event.Kind]);
  FInEvent := True;
  if Event.Kind = TN64EventKind.SPTransfer then
  begin
    FNextDue := FNextHard;
    if (FCount > 0) and (FEvents[FCount - 1].Due < FNextDue) then
      FNextDue := FEvents[FCount - 1].Due;
  end
  else
    UpdateNext;
end;

procedure TN64Timeline.SerializeState(State: TStateArchive);
begin
  // The console rewinds RSP run-ahead first: no clock may be executed early.
  if FAheadLeft > 0 then
    MaterializeCurrent;
  if FAheadLeft > 0 then
    raise EInvalidOpException.Create('N64 timeline saved during RSP run-ahead');
  var Ordered: TN64EventArray;
  for var I := 0 to High(Ordered) do
    Ordered[I] := Default(TN64Event);
  var Total := FCount;
  if not State.Loading then
  begin
    // Earliest first; the fast slot takes its (Due, Sequence) position.
    var N := 0;
    var FastPending := FFastActive;
    for var I := FCount - 1 downto 0 do
    begin
      if FastPending and ((FFast.Due < FEvents[I].Due) or
        ((FFast.Due = FEvents[I].Due) and (FFast.Sequence < FEvents[I].Sequence))) then
      begin
        Ordered[N] := FFast;
        Inc(N);
        FastPending := False;
      end;
      Ordered[N] := FEvents[I];
      Inc(N);
    end;
    if FastPending then
    begin
      Ordered[N] := FFast;
      Inc(N)
    end;
    Total := N;
  end;
  State.Field(FNow, SizeOf(FNow));
  State.Field(FSequence, SizeOf(FSequence));
  State.Field(Total, SizeOf(Total));
  State.Field(Ordered, SizeOf(Ordered));
  if State.Loading then
  begin
    if (Total < 0) or (Total > Length(Ordered)) then
      raise EReadError.Create('Invalid N64 event count');
    for var I := 0 to Total - 1 do
    begin
      var KindValue: Cardinal := 0;
      Move(Ordered[I].Kind, KindValue, SizeOf(Ordered[I].Kind));
      if (KindValue > Cardinal(Ord(High(TN64EventKind)))) or
        (Ordered[I].Due < FNow) or (Ordered[I].Due = High(UInt64)) or
        (Ordered[I].Sequence >= FSequence) then
        raise EReadError.Create('Invalid N64 event');
      for var J := 0 to I - 1 do
        if Ordered[I].Sequence = Ordered[J].Sequence then
          raise EReadError.Create('Duplicate N64 event sequence');
      if I > 0 then
        if (Ordered[I].Due < Ordered[I - 1].Due) or
          ((Ordered[I].Due = Ordered[I - 1].Due) and
          (Ordered[I].Sequence <= Ordered[I - 1].Sequence)) then
          raise EReadError.Create('Invalid N64 event order');
    end;
    // Restored events all go to the queue; the next RSP clock refills the slot.
    FCount := Total;
    for var I := 0 to High(FEvents) do
      FEvents[I] := Default(TN64Event);
    for var I := 0 to FCount - 1 do
      FEvents[I] := Ordered[FCount - 1 - I];
    FFast := Default(TN64Event);
    FFastActive := False;
    FAheadLeft := 0;
    FAheadDone := 0;
    FHorizon := 0;
    FMaterialized := 0;
    FInEvent := False;
    CountKinds;
    UpdateNext;
  end;
end;

end.

