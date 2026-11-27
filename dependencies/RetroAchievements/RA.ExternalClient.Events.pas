unit RA.ExternalClient.Events;

interface

{$SCOPEDENUMS ON}
{$POINTERMATH ON}

uses
  RA.ExternalClient.ABI, RA.Runtime;

function ReadExternalText(Value: PAnsiChar): string; overload;

function ReadExternalText(Value: PAnsiChar; Limit: Integer): string; overload;

function CheckedExternalCount(Count: Cardinal; Data: Pointer): Integer;

function TryConvertExternalEvent(Source: PRAExternalEvent; out Event: TRARuntimeEvent): Boolean;

implementation

uses
  System.SysUtils, RA.Errors, RA.Protocol;

function ReadExternalText(Value: PAnsiChar): string;
begin
  if Value = nil then
    Exit('');
  Result := UTF8ToString(Value);
end;

function ReadExternalText(Value: PAnsiChar; Limit: Integer): string;
var
  Text: UTF8String;
  Count: Integer;
begin
  Count := 0;
  while (Count < Limit) and (Value[Count] <> #0) do
    Inc(Count);
  SetString(Text, Value, Count);
  Result := UTF8ToString(Text);
end;

function CheckedExternalCount(Count: Cardinal; Data: Pointer): Integer;
begin
  if (Count > Cardinal(MaxInt)) or ((Count <> 0) and (Data = nil)) then
    raise ERAProtocolError.Create('Invalid RetroAchievements external list');
  Result := Integer(Count);
end;

function ConvertScoreboard(Source: PRAExternalScoreboard): TRARuntimeScoreboard;
begin
  Result.Submitted := ReadExternalText(@Source.SubmittedScore[0], Length(Source.SubmittedScore));
  Result.PersonalBest := ReadExternalText(@Source.BestScore[0], Length(Source.BestScore));
  Result.Rank := Source.Rank;
  Result.EntryCount := Source.EntryCount;
  SetLength(Result.TopEntries, CheckedExternalCount(Source.TopEntryCount, Source.TopEntries));
  for var Index := 0 to High(Result.TopEntries) do
  begin
    var Entry: PRAExternalScoreboardEntry := @Source.TopEntries[Index];
    Result.TopEntries[Index].UserName := ReadExternalText(Entry.UserName);
    Result.TopEntries[Index].Rank := Entry.Rank;
    Result.TopEntries[Index].Display := ReadExternalText(@Entry.Score[0], Length(Entry.Score));
  end;
end;

function TryConvertExternalEvent(Source: PRAExternalEvent; out Event: TRARuntimeEvent): Boolean;
const
  LeaderboardEvents: array[RAExternalEventLeaderboardStarted..RAExternalEventLeaderboardSubmitted] of TRARuntimeEventKind =
    (TRARuntimeEventKind.LeaderboardStarted, TRARuntimeEventKind.LeaderboardCanceled, TRARuntimeEventKind.LeaderboardTriggered);
  TrackerEvents: array[RAExternalEventTrackerShow..RAExternalEventTrackerUpdate] of TRARuntimeEventKind =
    (TRARuntimeEventKind.LeaderboardTrackerShow, TRARuntimeEventKind.LeaderboardTrackerHide,
    TRARuntimeEventKind.LeaderboardTrackerUpdate);
  AchievementEvents: array[RAExternalEventChallengeShow..RAExternalEventProgressUpdate] of TRARuntimeEventKind =
    (TRARuntimeEventKind.AchievementChallengeShow, TRARuntimeEventKind.AchievementChallengeHide,
    TRARuntimeEventKind.AchievementProgressShow, TRARuntimeEventKind.AchievementProgressHide,
    TRARuntimeEventKind.AchievementProgressUpdate);
begin
  Event := Default(TRARuntimeEvent);
  if Source = nil then
    Exit(False);
  case Source.Kind of
    RAExternalEventAchievementTriggered:
      begin
        if Source.Achievement = nil then
          Exit(False);
        Event.Kind := TRARuntimeEventKind.AchievementTriggered;
        Event.ID := Source.Achievement.ID;
        Event.Display := ReadExternalText(Source.Achievement.Title);
      end;
    RAExternalEventLeaderboardStarted..RAExternalEventLeaderboardSubmitted:
      begin
        if Source.Leaderboard = nil then
          Exit(False);
        Event.Kind := LeaderboardEvents[Source.Kind];
        Event.ID := Source.Leaderboard.ID;
        Event.Display := ReadExternalText(Source.Leaderboard.TrackerValue);
      end;
    RAExternalEventChallengeShow..RAExternalEventProgressUpdate:
      begin
        Event.Kind := AchievementEvents[Source.Kind];
        if Source.Achievement = nil then
          Exit(Source.Kind = RAExternalEventProgressHide);
        Event.ID := Source.Achievement.ID;
        if Source.Kind in [RAExternalEventProgressShow, RAExternalEventProgressUpdate] then
          Event.Display := ReadExternalText(@Source.Achievement.MeasuredProgress[0], Length(Source.Achievement.MeasuredProgress));
      end;
    RAExternalEventTrackerShow..RAExternalEventTrackerUpdate:
      begin
        if Source.Tracker = nil then
          Exit(False);
        Event.Kind := TrackerEvents[Source.Kind];
        Event.ID := Source.Tracker.ID;
        Event.Display := ReadExternalText(@Source.Tracker.Display[0], Length(Source.Tracker.Display));
      end;
    RAExternalEventScoreboard:
      begin
        if Source.Scoreboard = nil then
          Exit(False);
        Event.Kind := TRARuntimeEventKind.LeaderboardScoreboard;
        Event.ID := Source.Scoreboard.LeaderboardID;
        Event.Scoreboard := ConvertScoreboard(Source.Scoreboard);
        Event.Display := Event.Scoreboard.Submitted;
      end;
    RAExternalEventReset:
      Event.Kind := TRARuntimeEventKind.ResetRequested;
    RAExternalEventGameCompleted, RAExternalEventSubsetCompleted:
      begin
        if Source.Kind = RAExternalEventGameCompleted then
          Event.Kind := TRARuntimeEventKind.GameCompleted
        else
          Event.Kind := TRARuntimeEventKind.SubsetCompleted;
        if Source.Subset <> nil then
        begin
          Event.ID := Source.Subset.ID;
          Event.Display := ReadExternalText(Source.Subset.Title);
        end;
      end;
    RAExternalEventServerError:
      begin
        if Source.ServerError = nil then
          Exit(False);
        Event.Kind := TRARuntimeEventKind.ServerError;
        Event.ID := Source.ServerError.RelatedID;
        Event.Value := Source.ServerError.ResultCode;
        Event.Display := ReadExternalText(Source.ServerError.MessageText);
        if Event.Display = '' then
          Event.Display := RAErrorMessage(Event.Value);
        Event.API := ReadExternalText(Source.ServerError.API);
      end;
    RAExternalEventDisconnected:
      Event.Kind := TRARuntimeEventKind.Disconnected;
    RAExternalEventReconnected:
      Event.Kind := TRARuntimeEventKind.Reconnected;
  else
    Exit(False);
  end;
  Result := True;
end;

end.

