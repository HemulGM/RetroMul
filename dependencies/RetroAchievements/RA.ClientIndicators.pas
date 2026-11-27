unit RA.ClientIndicators;

interface

{$SCOPEDENUMS ON}

uses
  System.Generics.Collections, RA.Format, RA.GameData, RA.Runtime;

type
  TRAClientIndicators = class
  private
    type
      TLeaderboardAsset = record
        ValueFormat: TRAValueFormat;
        NotificationOrder: Integer;
      end;

      TLeaderboardTracker = record
        ValueHash: Cardinal;
        ValueFormat: TRAValueFormat;
        ValueFromHits: Boolean;
        Value, References: Integer;
        Visible, Changed: Boolean;
        Display: string;
      end;
  private
    FEvents: TList<TRARuntimeEvent>;
    FAnnouncedCount: Integer;
    FChallenges: TList<Cardinal>;
    FAchievementOrder: TDictionary<Cardinal, Integer>;
    FMeasuredPercents: TDictionary<Cardinal, Single>;
    FLeaderboardAssets: TDictionary<Cardinal, TLeaderboardAsset>;
    FSubsetOrder: TDictionary<Cardinal, Integer>;
    FTrackedBoards: TDictionary<Cardinal, Integer>;
    FLeaderboardTrackerSlots: TDictionary<Cardinal, Integer>;
    FTrackers: TList<TLeaderboardTracker>;
    FProgressID: Cardinal;
    FProgressDeadline: UInt64;
    FProgressVisible: Boolean;
    procedure Emit(Kind: TRARuntimeEventKind; ID: Cardinal; Value: Integer = 0; const Display: string = '');
    procedure SetChallenge(ID: Cardinal; Visible: Boolean);
    procedure SetTrackerValue(Index, Value: Integer);
    procedure TrackLeaderboard(const Runtime: TRARuntime; ID: Cardinal; Value: Integer);
    procedure UntrackLeaderboard(ID: Cardinal);
    procedure CollectTrackerEvents;
    procedure HideProgress(AchievementID: Cardinal);
    procedure ExpireProgress(Now: UInt64);
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetGame(const Game: TRAGameData);
    procedure EndGame;
    procedure HideAll;
    procedure ReconcileChallenges(const Runtime: TRARuntime; const Game: TRAGameData);
    procedure ReconcileLeaderboards(const Runtime: TRARuntime; const Game: TRAGameData);
    procedure Reconcile(const Runtime: TRARuntime; const Game: TRAGameData; HideProgressIndicator: Boolean);
    procedure ProcessFrame(var Events: TArray<TRARuntimeEvent>; const Runtime: TRARuntime; Now: UInt64; out BufferedEventCount: Integer);
    function FrameNotificationOrder(const Event: TRARuntimeEvent): Integer;
    function TakeNotifications(Now: UInt64 = 0): TArray<TRARuntimeEvent>;
    function Poll(Now: UInt64): TArray<TRARuntimeEvent>;
    function GetMeasuredPercent(ID: Cardinal): Single;
    procedure SetMeasuredPercent(ID: Cardinal; Value: Single);
    property AnnouncedCount: Integer read FAnnouncedCount;
    procedure GetLeaderboardTracker(ID: Cardinal; out TrackerID: Cardinal; out Display: string);
  end;

implementation

uses
  System.Generics.Defaults, RA.Leaderboards, RA.Trigger;

const
  ProgressDuration = 2000;

constructor TRAClientIndicators.Create;
begin
  inherited Create;
  FEvents := TList<TRARuntimeEvent>.Create;
  FChallenges := TList<Cardinal>.Create;
  FAchievementOrder := TDictionary<Cardinal, Integer>.Create;
  FMeasuredPercents := TDictionary<Cardinal, Single>.Create;
  FLeaderboardAssets := TDictionary<Cardinal, TLeaderboardAsset>.Create;
  FSubsetOrder := TDictionary<Cardinal, Integer>.Create;
  FTrackedBoards := TDictionary<Cardinal, Integer>.Create;
  FLeaderboardTrackerSlots := TDictionary<Cardinal, Integer>.Create;
  FTrackers := TList<TLeaderboardTracker>.Create;
end;

destructor TRAClientIndicators.Destroy;
begin
  FTrackers.Free;
  FLeaderboardTrackerSlots.Free;
  FTrackedBoards.Free;
  FSubsetOrder.Free;
  FLeaderboardAssets.Free;
  FMeasuredPercents.Free;
  FAchievementOrder.Free;
  FChallenges.Free;
  FEvents.Free;
  inherited;
end;

procedure TRAClientIndicators.SetGame(const Game: TRAGameData);
var
  Order: Integer;
  Board: TLeaderboardAsset;
begin
  FAchievementOrder.Clear;
  FMeasuredPercents.Clear;
  FLeaderboardAssets.Clear;
  FSubsetOrder.Clear;
  Order := 1;
  for var AchievementSet in Game.Sets do
  begin
    for var Achievement in AchievementSet.Achievements do
    begin
      FAchievementOrder.TryAdd(Achievement.ID, Order);
      // A challenge indicator is dispatched before the corresponding unlock.
      Inc(Order, 2);
    end;
    for var Leaderboard in AchievementSet.Leaderboards do
    begin
      Board.ValueFormat := Leaderboard.ValueFormat;
      Board.NotificationOrder := Order;
      FLeaderboardAssets.TryAdd(Leaderboard.ID, Board);
      Inc(Order);
    end;
    FSubsetOrder.TryAdd(AchievementSet.ID, Order);
    Inc(Order);
  end;
end;

function TRAClientIndicators.FrameNotificationOrder(const Event: TRARuntimeEvent): Integer;
var
  Order: Integer;
  Board: TLeaderboardAsset;
begin
  Result := High(Integer) - 1;
  case Event.Kind of
    TRARuntimeEventKind.LeaderboardTrackerShow, TRARuntimeEventKind.LeaderboardTrackerHide, TRARuntimeEventKind.LeaderboardTrackerUpdate:
      Result := 0;
    TRARuntimeEventKind.AchievementChallengeShow, TRARuntimeEventKind.AchievementChallengeHide, TRARuntimeEventKind.AchievementTriggered:
      if FAchievementOrder.TryGetValue(Event.ID, Order) then
      begin
        Result := Order;
        if Event.Kind = TRARuntimeEventKind.AchievementTriggered then
          Inc(Result);
      end;
    TRARuntimeEventKind.LeaderboardStarted, TRARuntimeEventKind.LeaderboardCanceled, TRARuntimeEventKind.LeaderboardTriggered:
      if FLeaderboardAssets.TryGetValue(Event.ID, Board) then
        Result := Board.NotificationOrder;
    TRARuntimeEventKind.GameCompleted, TRARuntimeEventKind.SubsetCompleted:
      if FSubsetOrder.TryGetValue(Event.ID, Order) then
        Result := Order;
    TRARuntimeEventKind.AchievementProgressShow, TRARuntimeEventKind.AchievementProgressHide, TRARuntimeEventKind.AchievementProgressUpdate:
      Result := High(Integer);
  end;
end;

procedure TRAClientIndicators.Emit(Kind: TRARuntimeEventKind; ID: Cardinal; Value: Integer; const Display: string);
var
  Event: TRARuntimeEvent;
begin
  Event := Default(TRARuntimeEvent);
  Event.Kind := Kind;
  Event.ID := ID;
  Event.Value := Value;
  Event.Display := Display;
  FEvents.Add(Event);
end;

procedure TRAClientIndicators.SetChallenge(ID: Cardinal; Visible: Boolean);
var
  Index: Integer;
begin
  Index := FChallenges.IndexOf(ID);
  if Visible and (Index < 0) then
  begin
    FChallenges.Add(ID);
    Emit(TRARuntimeEventKind.AchievementChallengeShow, ID);
  end
  else if not Visible and (Index >= 0) then
  begin
    FChallenges.Delete(Index);
    Emit(TRARuntimeEventKind.AchievementChallengeHide, ID);
  end;
end;

procedure TRAClientIndicators.SetTrackerValue(Index, Value: Integer);
var
  Tracker: TLeaderboardTracker;
begin
  Tracker := FTrackers[Index];
  if Tracker.Value <> Value then
  begin
    Tracker.Value := Value;
    Tracker.Changed := True;
    FTrackers[Index] := Tracker;
  end;
end;

procedure TRAClientIndicators.TrackLeaderboard(const Runtime: TRARuntime; ID: Cardinal; Value: Integer);
var
  Index, Available: Integer;
  Tracker: TLeaderboardTracker;
  ValueHash: Cardinal;
  ValueFromHits: Boolean;
  Board: TLeaderboardAsset;
begin
  if FTrackedBoards.TryGetValue(ID, Index) then
  begin
    SetTrackerValue(Index, Value);
    Exit;
  end;
  if not FLeaderboardAssets.TryGetValue(ID, Board) or
    not Runtime.TryGetLeaderboardTrackerKey(ID, ValueHash, ValueFromHits) then
    Exit;

  Available := -1;
  for Index := 0 to FTrackers.Count - 1 do
  begin
    Tracker := FTrackers[Index];
    if Tracker.References = 0 then
    begin
      if (Available < 0) and not Tracker.Visible and not Tracker.Changed then
        Available := Index;
      Continue;
    end;

    if (Tracker.ValueFormat <> Board.ValueFormat) or (Tracker.ValueHash <> ValueHash) or
      (Tracker.ValueFromHits and (Tracker.Value <> Value)) then
      Continue;

    Inc(Tracker.References);
    FTrackers[Index] := Tracker;
    SetTrackerValue(Index, Value);
    FTrackedBoards.Add(ID, Index);
    FLeaderboardTrackerSlots.AddOrSetValue(ID, Index);
    Exit;
  end;

  Tracker := Default(TLeaderboardTracker);
  Tracker.ValueHash := ValueHash;
  Tracker.ValueFormat := Board.ValueFormat;
  Tracker.ValueFromHits := ValueFromHits;
  Tracker.Value := Value;
  Tracker.References := 1;
  Tracker.Changed := True;
  if Available < 0 then
    Available := FTrackers.Add(Tracker)
  else
    FTrackers[Available] := Tracker;
  FTrackedBoards.Add(ID, Available);
  FLeaderboardTrackerSlots.AddOrSetValue(ID, Available);
end;

procedure TRAClientIndicators.UntrackLeaderboard(ID: Cardinal);
var
  Index: Integer;
  Tracker: TLeaderboardTracker;
begin
  if not FTrackedBoards.TryGetValue(ID, Index) then
    Exit;
  FTrackedBoards.Remove(ID);
  Tracker := FTrackers[Index];
  Dec(Tracker.References);
  FTrackers[Index] := Tracker;
end;

procedure TRAClientIndicators.CollectTrackerEvents;
var
  Tracker: TLeaderboardTracker;
  ID: Cardinal;
begin
  for var Index := 0 to FTrackers.Count - 1 do
  begin
    Tracker := FTrackers[Index];
    if not Tracker.Changed and (Tracker.Visible = (Tracker.References <> 0)) then
      Continue;
    ID := Cardinal(Index) + 1;
    if Tracker.Changed then
      Tracker.Display := FormatRAValue(Tracker.Value, Tracker.ValueFormat);
    if Tracker.References = 0 then
    begin
      if Tracker.Visible then
        Emit(TRARuntimeEventKind.LeaderboardTrackerHide, ID, Tracker.Value, Tracker.Display);
    end
    else if not Tracker.Visible then
      Emit(TRARuntimeEventKind.LeaderboardTrackerShow, ID, Tracker.Value, Tracker.Display)
    else
      Emit(TRARuntimeEventKind.LeaderboardTrackerUpdate, ID, Tracker.Value, Tracker.Display);
    Tracker.Visible := Tracker.References <> 0;
    Tracker.Changed := False;
    FTrackers[Index] := Tracker;
  end;
end;

procedure TRAClientIndicators.GetLeaderboardTracker(ID: Cardinal; out TrackerID: Cardinal; out Display: string);
var
  Index: Integer;
begin
  TrackerID := 0;
  Display := '';
  // The client keeps the display slot after the board releases its active tracker.
  if FLeaderboardTrackerSlots.TryGetValue(ID, Index) then
  begin
    if FTrackedBoards.ContainsKey(ID) then
      TrackerID := Cardinal(Index) + 1;
    Display := FTrackers[Index].Display;
  end;
end;

procedure TRAClientIndicators.HideProgress(AchievementID: Cardinal);
begin
  if FProgressVisible then
  begin
    Emit(TRARuntimeEventKind.AchievementProgressHide, AchievementID);
    FProgressVisible := False;
    FProgressID := 0;
    FProgressDeadline := 0;
  end;
end;

procedure TRAClientIndicators.ExpireProgress(Now: UInt64);
begin
  if FProgressVisible and (Now >= FProgressDeadline) then
    HideProgress(0);
end;

procedure TRAClientIndicators.HideAll;
var
  Tracker: TLeaderboardTracker;
begin
  FTrackedBoards.Clear;
  for var Index := 0 to FTrackers.Count - 1 do
  begin
    Tracker := FTrackers[Index];
    Tracker.References := 0;
    FTrackers[Index] := Tracker;
  end;
  CollectTrackerEvents;
  // Match the subset traversal used to clear indicators in rc_client_unload_game.
  if FChallenges.Count > 1 then
    FChallenges.Sort(TComparer<Cardinal>.Construct(
      function(const Left, Right: Cardinal): Integer
      begin
        Result := FAchievementOrder[Left] - FAchievementOrder[Right];
      end));
  for var ID in FChallenges do
    Emit(TRARuntimeEventKind.AchievementChallengeHide, ID);
  FChallenges.Clear;
  HideProgress(FProgressID);
end;

procedure TRAClientIndicators.EndGame;
begin
  HideAll;
  FTrackers.Clear;
  FLeaderboardTrackerSlots.Clear;
  FLeaderboardAssets.Clear;
  FSubsetOrder.Clear;
  FAchievementOrder.Clear;
  FMeasuredPercents.Clear;
end;

function TRAClientIndicators.GetMeasuredPercent(ID: Cardinal): Single;
begin
  FMeasuredPercents.TryGetValue(ID, Result);
end;

procedure TRAClientIndicators.SetMeasuredPercent(ID: Cardinal; Value: Single);
begin
  if Value = 0 then
    FMeasuredPercents.Remove(ID)
  else
    FMeasuredPercents.AddOrSetValue(ID, Value);
end;

procedure TRAClientIndicators.ReconcileLeaderboards(const Runtime: TRARuntime; const Game: TRAGameData);
var
  BoardState: TRALeaderboardState;
  Value: Integer;
begin
  for var AchievementSet in Game.Sets do
    for var Leaderboard in AchievementSet.Leaderboards do
      if Runtime.TryGetLeaderboardState(Leaderboard.ID, BoardState, Value) and
        (BoardState = TRALeaderboardState.Started) then
        TrackLeaderboard(Runtime, Leaderboard.ID, Value)
      else
        UntrackLeaderboard(Leaderboard.ID);

  CollectTrackerEvents;
end;

procedure TRAClientIndicators.ReconcileChallenges(const Runtime: TRARuntime; const Game: TRAGameData);
var
  State: TRATriggerState;
  Measured: TRAMeasuredProgress;
begin
  for var AchievementSet in Game.Sets do
    for var Achievement in AchievementSet.Achievements do
      SetChallenge(Achievement.ID, Runtime.TryGetAchievementState(Achievement.ID, State, Measured) and
        (State = TRATriggerState.Primed));
end;

procedure TRAClientIndicators.Reconcile(const Runtime: TRARuntime; const Game: TRAGameData; HideProgressIndicator: Boolean);
begin
  ReconcileLeaderboards(Runtime, Game);
  ReconcileChallenges(Runtime, Game);
  if HideProgressIndicator then
    HideProgress(FProgressID);
end;

procedure TRAClientIndicators.ProcessFrame(var Events: TArray<TRARuntimeEvent>; const Runtime: TRARuntime; Now: UInt64; out BufferedEventCount: Integer);
type
  TProgressCandidate = record
    Event: TRARuntimeEvent;
    Progress: TRAMeasuredProgress;
    Rank: Single;
    Order: Integer;
  end;
var
  Event, ProgressEvent: TRARuntimeEvent;
  Progress, BestProgress: TRAMeasuredProgress;
  State: TRATriggerState;
  MeasuredValue, MeasuredTarget, BestRank: Single;
  Candidates: TList<TProgressCandidate>;
  Candidate: TProgressCandidate;
  TrackerIndex, EventCount: Integer;
  Board: TLeaderboardAsset;
begin
  BufferedEventCount := FEvents.Count;
  for var BoardEvent in Events do
  begin
    case BoardEvent.Kind of
      TRARuntimeEventKind.LeaderboardStarted, TRARuntimeEventKind.LeaderboardUpdated:
        TrackLeaderboard(Runtime, BoardEvent.ID, BoardEvent.Value);
      TRARuntimeEventKind.LeaderboardTrackerSample:
        if FTrackedBoards.TryGetValue(BoardEvent.ID, TrackerIndex) then
          SetTrackerValue(TrackerIndex, BoardEvent.Value);
      TRARuntimeEventKind.LeaderboardTriggered:
        begin
          TrackLeaderboard(Runtime, BoardEvent.ID, BoardEvent.Value);
          UntrackLeaderboard(BoardEvent.ID);
        end;
      TRARuntimeEventKind.LeaderboardCanceled, TRARuntimeEventKind.LeaderboardDisabled:
        UntrackLeaderboard(BoardEvent.ID);
    end;
  end;
  CollectTrackerEvents;

  EventCount := 0;
  for var Index := 0 to High(Events) do
  begin
    Event := Events[Index];
    case Event.Kind of
      TRARuntimeEventKind.LeaderboardTrackerSample:
        Continue;
      TRARuntimeEventKind.LeaderboardStarted, TRARuntimeEventKind.LeaderboardCanceled, TRARuntimeEventKind.LeaderboardTriggered:
        if FLeaderboardTrackerSlots.TryGetValue(Event.ID, TrackerIndex) then
        begin
          Event.Display := FTrackers[TrackerIndex].Display;
          if Event.Kind = TRARuntimeEventKind.LeaderboardCanceled then
            Event.Value := FTrackers[TrackerIndex].Value;
        end;
      TRARuntimeEventKind.LeaderboardUpdated:
        if FLeaderboardAssets.TryGetValue(Event.ID, Board) then
          Event.Display := FormatRAValue(Event.Value, Board.ValueFormat);
    end;
    Events[EventCount] := Event;
    Inc(EventCount);
  end;
  if EventCount <> Length(Events) then
    SetLength(Events, EventCount);

  ProgressEvent := Default(TRARuntimeEvent);
  BestProgress := Default(TRAMeasuredProgress);
  BestRank := 0;
  Candidates := nil;
  try
    for var Index := High(Events) downto 0 do
    begin
      Event := Events[Index];
      case Event.Kind of
        TRARuntimeEventKind.AchievementPrimed, TRARuntimeEventKind.AchievementUnprimed:
          begin
            SetChallenge(Event.ID, Event.Kind = TRARuntimeEventKind.AchievementPrimed);
            if Runtime.TryGetAchievementState(Event.ID, State, Progress) and Progress.Known and (Progress.Target <> 0) then
              SetMeasuredPercent(Event.ID, RAClientMeasuredPercent(Progress));
          end;
        TRARuntimeEventKind.AchievementTriggered, TRARuntimeEventKind.AchievementDisabled:
          SetChallenge(Event.ID, False);
        TRARuntimeEventKind.AchievementProgressUpdated:
          if Runtime.TryGetAchievementState(Event.ID, State, Progress) and Progress.Known and
            (Progress.Value <> 0) and (Progress.Target <> 0) and FAchievementOrder.TryGetValue(Event.ID, Candidate.Order) then
          begin
            MeasuredValue := Progress.Value;
            MeasuredTarget := Progress.Target;
            Candidate.Rank := MeasuredValue / MeasuredTarget;
            Candidate.Event := Event;
            Candidate.Progress := Progress;
            if Candidates = nil then
              Candidates := TList<TProgressCandidate>.Create;
            Candidates.Add(Candidate);
          end;
      end;
    end;
    if Candidates <> nil then
    begin
      if Candidates.Count > 1 then
        Candidates.Sort(TComparer<TProgressCandidate>.Construct(
          function(const Left, Right: TProgressCandidate): Integer
          begin
            Result := Left.Order - Right.Order;
          end));
      // Even an interim leader updates its recorded progress, but only the final leader is shown.
      for Candidate in Candidates do
        if Candidate.Rank > BestRank then
        begin
          BestProgress := Candidate.Progress;
          ProgressEvent := Candidate.Event;
          BestRank := Candidate.Rank;
          SetMeasuredPercent(Candidate.Event.ID, RAClientMeasuredPercent(Candidate.Progress));
        end;
    end;
  finally
    Candidates.Free;
  end;

  if BestProgress.Target = 0 then
    ExpireProgress(Now);
  if FEvents.Count <> 0 then
  begin
    Events := FEvents.ToArray + Events;
    FEvents.Clear;
    FAnnouncedCount := 0;
  end;
  if BestProgress.Target <> 0 then
  begin
    if FProgressVisible then
      ProgressEvent.Kind := TRARuntimeEventKind.AchievementProgressUpdate
    else
      ProgressEvent.Kind := TRARuntimeEventKind.AchievementProgressShow;
    ProgressEvent.Display := FormatRAClientMeasured(BestProgress);
    Events := Events + [ProgressEvent];
    FProgressVisible := True;
    FProgressID := ProgressEvent.ID;
    FProgressDeadline := Now + ProgressDuration;
  end;
end;

function TRAClientIndicators.TakeNotifications(Now: UInt64): TArray<TRARuntimeEvent>;
begin
  ExpireProgress(Now);
  SetLength(Result, FEvents.Count - FAnnouncedCount);
  for var Index := 0 to High(Result) do
    Result[Index] := FEvents[FAnnouncedCount + Index];
  FAnnouncedCount := FEvents.Count;
end;

function TRAClientIndicators.Poll(Now: UInt64): TArray<TRARuntimeEvent>;
begin
  ExpireProgress(Now);
  Result := FEvents.ToArray;
  FEvents.Clear;
  FAnnouncedCount := 0;
end;

end.

