unit RA.Runtime;

interface

{$SCOPEDENUMS ON}

uses
  System.Generics.Collections, System.SysUtils, RA.Leaderboards, RA.Memory,
  RA.MemoryValues, RA.Progress, RA.RCheevosProgress, RA.RichPresence, RA.Trigger;

type
  TRARuntimeEventKind = (AchievementActivated, AchievementPaused, AchievementReset,
    AchievementTriggered, AchievementPrimed, LeaderboardStarted, LeaderboardCanceled,
    LeaderboardUpdated, LeaderboardTriggered, AchievementDisabled, LeaderboardDisabled,
    AchievementUnprimed, AchievementProgressUpdated, GameCompleted, SubsetCompleted,
    Disconnected, Reconnected, AchievementChallengeShow, AchievementChallengeHide,
    AchievementProgressShow, AchievementProgressUpdate, AchievementProgressHide,
    LeaderboardTrackerShow, LeaderboardTrackerUpdate, LeaderboardTrackerHide,
    LeaderboardScoreboard, ResetRequested, ServerError, LeaderboardTrackerSample);

  TRARuntimeScoreboardEntry = record
    UserName, Display: string;
    Rank: Cardinal;
  end;

  TRARuntimeScoreboard = record
    Submitted, PersonalBest: string;
    Rank, EntryCount: Cardinal;
    TopEntries: TArray<TRARuntimeScoreboardEntry>;
  end;

  TRARuntimeEvent = record
    Kind: TRARuntimeEventKind;
    // Tracker events use the tracker ID. Achievement indicator events use the achievement ID.
    ID: Cardinal;
    Value: Integer;
    Display: string;
    API: string;
    Scoreboard: TRARuntimeScoreboard;
  end;

  TRARuntime = class
  private
    type
      TFrameRead = record
        Data: Cardinal;
        BytesRead: Cardinal;
      end;

      TFrameMemory = class
      private
        FReadMemory: TRAMemoryRead;
        FReads: TDictionary<UInt64, TFrameRead>;
        FLastFailure: Cardinal;
      public
        constructor Create;
        destructor Destroy; override;
        procedure BeginFrame(const ReadMemory: TRAMemoryRead);
        function Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
        property LastFailure: Cardinal read FLastFailure;
      end;

      TAchievement = class
      public
        ID, InvalidAddress: Cardinal;
        InvalidPending: Boolean;
        Definition: string;
        Trigger: TRATrigger;
        destructor Destroy; override;
      end;

      TLeaderboard = class
      public
        ID, InvalidAddress: Cardinal;
        InvalidPending: Boolean;
        Definition: string;
        Board: TRALeaderboard;
        Value: Integer;
        destructor Destroy; override;
      end;
  private
    FMemory: TFrameMemory;
    // Memory references keep their history for the lifetime of the runtime.
    FMemrefs: TRARuntimeMemrefs;
    FEvents: TList<TRARuntimeEvent>;
    FAchievements: TObjectList<TAchievement>;
    FLeaderboards: TObjectList<TLeaderboard>;
    FRichPresence: TRARichPresence;
    FRichPresenceScript, FRichPresenceText: string;
    FRichPresencePreviewPending: Boolean;
    function GetRichPresenceText: string;
    procedure LoadProgress(const Data: TBytes);
    function BuildRCProgressChunks: TArray<TRAProgressChunk>;
    function CollectRCProgressChunks(Chunks: TList<TRAProgressChunk>): NativeUInt;
    function ReadRCProgressBuffer(Buffer: PByte; BufferSize: NativeUInt): TRAProgressReadStatus;
    procedure QueueInvalidMemref(Memref: TRARuntimeMemref);
    function DisableInvalid(Achievement: TAchievement): Boolean; overload;
    function DisableInvalid(Leaderboard: TLeaderboard): Boolean; overload;
    procedure Emit(Kind: TRARuntimeEventKind; ID: Cardinal; Value: Integer = 0);
    procedure ClearProgress;
    function FindAchievement(ID: Cardinal): Integer;
    function FindLeaderboard(ID: Cardinal): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure ActivateAchievement(ID: Cardinal; const Definition: string);
    function ActivateAchievementWithStatus(ID: Cardinal; const Definition: string): Integer;
    procedure DeactivateAchievement(ID: Cardinal);
    procedure ActivateLeaderboard(ID: Cardinal; const Definition: string);
    function ActivateLeaderboardWithStatus(ID: Cardinal; const Definition: string): Integer;
    procedure DeactivateLeaderboard(ID: Cardinal; KeepOrder: Boolean = False);
    // Entries belong to the runtime and become invalid when replaced or deactivated.
    function GetAchievement(ID: Cardinal): TRATrigger;
    function GetLeaderboard(ID: Cardinal): TRALeaderboard;
    function HasAchievement(ID: Cardinal): Boolean;
    function HasLeaderboard(ID: Cardinal): Boolean;
    function TryGetLeaderboardState(ID: Cardinal; out State: TRALeaderboardState; out Value: Integer): Boolean;
    function TryGetLeaderboardTrackerKey(ID: Cardinal; out ValueHash: Cardinal; out ValueFromHits: Boolean): Boolean;
    procedure SetRichPresence(const Script: string);
    // Returns a rcheevos status and a one-based line for script errors.
    function ActivateRichPresence(const Script: string; out ErrorLine: Integer): Integer;
    function HasRichPresence: Boolean;
    function GetRichPresence: string; overload;
    function GetRichPresence(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;
    function IsProcessingRequired: Boolean;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead; ClientFrame: Boolean = False): TArray<TRARuntimeEvent>;
    function ValidateAddresses(const Validate: TRAAddressValidator): TArray<TRARuntimeEvent>;
    procedure InvalidateAddress(Address: Cardinal);
    function TryGetAchievementState(ID: Cardinal; out State: TRATriggerState; out Progress: TRAMeasuredProgress): Boolean;
    function TryGetMeasured(ID: Cardinal; out Progress: TRAMeasuredProgress): Boolean;
    function FormatMeasured(ID: Cardinal): string; overload;
    function FormatMeasured(ID: Cardinal; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;
    function CaptureProgress: TBytes;
    // rcheevos interchange format.
    function ProgressSize: NativeUInt;
    // Provide at least ProgressSize writable bytes or a complete trusted snapshot.
    function SerializeProgress(Buffer: PByte): Integer;
    function DeserializeProgress(Buffer: PByte): Integer;
    function SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
    function DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
    function TryCaptureRCProgress(out Data: TBytes): Boolean;
    // Validates the entire snapshot before applying any state.
    function ReadRCProgress(const Data: TBytes): TRAProgressReadStatus;
    function RestoreProgress(const Data: TBytes): Boolean;
    // The client refreshes visible trackers from VAL after a portable restore.
    procedure RefreshRestoredLeaderboardTrackers;
    procedure Reset;
    property RichPresenceText: string read GetRichPresenceText;
  end;

function FormatRAClientMeasured(const Progress: TRAMeasuredProgress): string; overload;

function FormatRAClientMeasured(const Progress: TRAMeasuredProgress; out Percentage: Single): string; overload;

function RAClientMeasuredPercent(const Progress: TRAMeasuredProgress): Single;

implementation

uses
  System.Classes, System.Math, RA.Conditions, RA.Errors, RA.Format, RA.Streams;

constructor TRARuntime.TFrameMemory.Create;
begin
  inherited;
  FReads := TDictionary<UInt64, TFrameRead>.Create;
end;

destructor TRARuntime.TFrameMemory.Destroy;
begin
  FReads.Free;
  inherited;
end;

procedure TRARuntime.TFrameMemory.BeginFrame(const ReadMemory: TRAMemoryRead);
begin
  FReadMemory := ReadMemory;
  FReads.Clear;
  FLastFailure := 0;
end;

function TRARuntime.TFrameMemory.Read(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
var
  Key: UInt64;
  Sample: TFrameRead;
begin
  if (Count = 0) or (Buffer = nil) then
    Exit(0);
  if Count > SizeOf(Sample.Data) then
    raise EArgumentOutOfRangeException.Create('Unexpected RetroAchievements memory read size');
  Key := (UInt64(Address) shl 32) or Count;
  if not FReads.TryGetValue(Key, Sample) then
  begin
    Sample := Default(TFrameRead);
    if Assigned(FReadMemory) then
      Sample.BytesRead := Min(FReadMemory(Address, @Sample.Data, Count), Count);
    FReads.Add(Key, Sample);
  end;
  if Sample.BytesRead < Count then
    FLastFailure := Address;
  if Sample.BytesRead <> 0 then
    Move(Sample.Data, Buffer^, Sample.BytesRead);
  Result := Sample.BytesRead;
end;

destructor TRARuntime.TAchievement.Destroy;
begin
  Trigger.Free;
  inherited;
end;

destructor TRARuntime.TLeaderboard.Destroy;
begin
  Board.Free;
  inherited;
end;

constructor TRARuntime.Create;
begin
  inherited;
  FMemory := TFrameMemory.Create;
  FMemrefs := TRARuntimeMemrefs.Create;
  FEvents := TList<TRARuntimeEvent>.Create;
  FAchievements := TObjectList<TAchievement>.Create;
  FLeaderboards := TObjectList<TLeaderboard>.Create;
end;

destructor TRARuntime.Destroy;
begin
  FRichPresence.Free;
  FLeaderboards.Free;
  FAchievements.Free;
  FEvents.Free;
  FMemrefs.Free;
  FMemory.Free;
  inherited;
end;

function TRARuntime.FindAchievement(ID: Cardinal): Integer;
begin
  for var Index := 0 to FAchievements.Count - 1 do
    if FAchievements[Index].ID = ID then
      Exit(Index);
  Result := -1;
end;

function TRARuntime.FindLeaderboard(ID: Cardinal): Integer;
begin
  for var Index := 0 to FLeaderboards.Count - 1 do
    if FLeaderboards[Index].ID = ID then
      Exit(Index);
  Result := -1;
end;

function TRARuntime.GetAchievement(ID: Cardinal): TRATrigger;
var
  Index: Integer;
begin
  Index := FindAchievement(ID);
  if Index < 0 then
    Exit(nil);
  Result := FAchievements[Index].Trigger;
end;

function TRARuntime.GetLeaderboard(ID: Cardinal): TRALeaderboard;
var
  Index: Integer;
begin
  Index := FindLeaderboard(ID);
  if Index < 0 then
    Exit(nil);
  Result := FLeaderboards[Index].Board;
end;

function TRARuntime.HasAchievement(ID: Cardinal): Boolean;
begin
  Result := FindAchievement(ID) >= 0;
end;

function TRARuntime.HasLeaderboard(ID: Cardinal): Boolean;
begin
  Result := FindLeaderboard(ID) >= 0;
end;

function TRARuntime.TryGetLeaderboardState(ID: Cardinal; out State: TRALeaderboardState; out Value: Integer): Boolean;
var
  Index: Integer;
begin
  Index := FindLeaderboard(ID);
  Result := Index >= 0;
  if Result then
  begin
    State := FLeaderboards[Index].Board.State;
    Value := FLeaderboards[Index].Value;
  end
  else
  begin
    State := TRALeaderboardState.Inactive;
    Value := 0;
  end;
end;

function TRARuntime.TryGetLeaderboardTrackerKey(ID: Cardinal; out ValueHash: Cardinal; out ValueFromHits: Boolean): Boolean;
var
  Board: TRALeaderboard;
begin
  Board := GetLeaderboard(ID);
  Result := Board <> nil;
  if Result then
  begin
    ValueHash := Board.ValueHash;
    ValueFromHits := Board.ValueFromHits;
  end
  else
  begin
    ValueHash := 0;
    ValueFromHits := False;
  end;
end;

procedure TRARuntime.ActivateAchievement(ID: Cardinal; const Definition: string);
var
  Index, Terminator, NextPosition: Integer;
  Entry: TAchievement;
  Source: string;
begin
  Source := Definition;
  Terminator := Pos(#0, Source);
  if Terminator <> 0 then
    SetLength(Source, Terminator - 1);
  Index := FindAchievement(ID);
  if (Index >= 0) and (FAchievements[Index].Definition = Source) then
  begin
    FAchievements[Index].Trigger.Reset;
    Exit;
  end;
  if Index >= 0 then
    DeactivateAchievement(ID);
  Entry := TAchievement.Create;
  try
    Entry.ID := ID;
    // The C runtime parses a trigger prefix and hashes the entire C string.
    Entry.Definition := Source;
    Entry.Trigger := TRATrigger.Create(TRATriggerDefinition.ParsePrefix(Source, NextPosition));
    Entry.Trigger.CollectRCMemrefs(FMemrefs, True);
    FAchievements.Add(Entry);
  except
    Entry.Free;
    raise;
  end;
end;

function TRARuntime.ActivateAchievementWithStatus(ID: Cardinal; const Definition: string): Integer;
begin
  try
    ActivateAchievement(ID, Definition);
    Result := RAErrorOK;
  except
    on E: ERAConditionError do
      Result := E.Code;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

procedure TRARuntime.DeactivateAchievement(ID: Cardinal);
var
  Index: Integer;
begin
  Index := FindAchievement(ID);
  if Index < 0 then
    Exit;
  if Index <> FAchievements.Count - 1 then
    FAchievements.Exchange(Index, FAchievements.Count - 1);
  FAchievements.Delete(FAchievements.Count - 1);
end;

procedure TRARuntime.ActivateLeaderboard(ID: Cardinal; const Definition: string);
var
  Index: Integer;
  Entry: TLeaderboard;
  Source: string;
begin
  Source := RALeaderboardDefinitionPrefix(Definition);
  Index := FindLeaderboard(ID);
  if (Index >= 0) and (FLeaderboards[Index].Definition = Source) then
  begin
    FLeaderboards[Index].Board.Reset;
    Exit;
  end;
  if Index >= 0 then
    DeactivateLeaderboard(ID);
  Entry := TLeaderboard.Create;
  try
    Entry.ID := ID;
    Entry.Definition := Source;
    Entry.Board := TRALeaderboard.Create(Source);
    Entry.Board.CollectRCMemrefs(FMemrefs, True);
    FLeaderboards.Add(Entry);
  except
    Entry.Free;
    raise;
  end;
end;

function TRARuntime.ActivateLeaderboardWithStatus(ID: Cardinal; const Definition: string): Integer;
begin
  try
    ActivateLeaderboard(ID, Definition);
    Result := RAErrorOK;
  except
    on E: ERAConditionError do
      Result := E.Code;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

procedure TRARuntime.DeactivateLeaderboard(ID: Cardinal; KeepOrder: Boolean);
var
  Index: Integer;
begin
  Index := FindLeaderboard(ID);
  if Index < 0 then
    Exit;
  if KeepOrder then
    FLeaderboards.Delete(Index)
  else
  begin
    if Index <> FLeaderboards.Count - 1 then
      FLeaderboards.Exchange(Index, FLeaderboards.Count - 1);
    FLeaderboards.Delete(FLeaderboards.Count - 1);
  end;
end;

procedure TRARuntime.SetRichPresence(const Script: string);
var
  Presence: TRARichPresence;
  Source: string;
begin
  Source := RARichPresenceScriptPrefix(Script);
  if (Source = FRichPresenceScript) and ((Source <> '') or (Script = '')) then
  begin
    if FRichPresence <> nil then
      FRichPresence.Reset;
    FRichPresenceText := '';
    FRichPresencePreviewPending := False;
    Exit;
  end;
  Presence := nil;
  if Script <> '' then
  begin
    Presence := TRARichPresence.Create(Source);
    try
      Presence.CollectRCMemrefs(FMemrefs, True);
    except
      Presence.Free;
      raise;
    end;
  end;
  FRichPresence.Free;
  FRichPresence := Presence;
  FRichPresenceScript := Source;
  FRichPresenceText := '';
  FRichPresencePreviewPending := False;
end;

function TRARuntime.ActivateRichPresence(const Script: string; out ErrorLine: Integer): Integer;
begin
  ErrorLine := 0;
  if Script = '' then
  begin
    ErrorLine := 1;
    Exit(RAErrorMissingDisplayString);
  end;
  try
    SetRichPresence(Script);
    Result := RAErrorOK;
  except
    on E: ERARichPresenceError do
    begin
      ErrorLine := E.Line;
      Result := E.Code;
    end;
    on EOutOfMemory do
      Result := RAErrorOutOfMemory;
  end;
end;

function TRARuntime.HasRichPresence: Boolean;
begin
  Result := FRichPresence <> nil;
end;

function TRARuntime.GetRichPresence: string;
begin
  if FRichPresence = nil then
    Exit('');
  Result := FRichPresence.GetDisplayString;
  FRichPresenceText := Result;
  FRichPresencePreviewPending := False;
end;

function TRARuntime.GetRichPresence(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  Result := CopyRAUTF8Text(GetRichPresence, Buffer, BufferSize);
end;

function TRARuntime.GetRichPresenceText: string;
begin
  if FRichPresencePreviewPending then
  begin
    FRichPresenceText := FRichPresence.PreviewDisplayString;
    FRichPresencePreviewPending := False;
  end;
  Result := FRichPresenceText;
end;

function TRARuntime.IsProcessingRequired: Boolean;
begin
  Result := (FAchievements.Count <> 0) or (FLeaderboards.Count <> 0) or HasRichPresence;
end;

function Percent(Value, Target: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(Value) * 100) div Target);
end;

procedure TRARuntime.Emit(Kind: TRARuntimeEventKind; ID: Cardinal; Value: Integer);
var
  Event: TRARuntimeEvent;
begin
  Event := Default(TRARuntimeEvent);
  Event.Kind := Kind;
  Event.ID := ID;
  Event.Value := Value;
  FEvents.Add(Event);
end;

procedure TRARuntime.QueueInvalidMemref(Memref: TRARuntimeMemref);
begin
  for var Achievement in FAchievements do
    if not Achievement.InvalidPending and Achievement.Trigger.ReferencesMemref(Memref) then
    begin
      Achievement.InvalidPending := True;
      Achievement.InvalidAddress := Memref.Address;
    end;
  for var Leaderboard in FLeaderboards do
    if not Leaderboard.InvalidPending and Leaderboard.Board.InvalidateMemref(Memref) then
    begin
      Leaderboard.InvalidPending := True;
      Leaderboard.InvalidAddress := Memref.Address;
    end;
end;

function TRARuntime.DisableInvalid(Achievement: TAchievement): Boolean;
begin
  Result := Achievement.InvalidPending;
  if not Result then
    Exit;
  Achievement.InvalidPending := False;
  Achievement.Trigger.Disable;
  Emit(TRARuntimeEventKind.AchievementDisabled, Achievement.ID, Integer(Achievement.InvalidAddress));
end;

function TRARuntime.DisableInvalid(Leaderboard: TLeaderboard): Boolean;
begin
  Result := Leaderboard.InvalidPending;
  if not Result then
    Exit;
  Leaderboard.InvalidPending := False;
  Leaderboard.Board.Disable;
  Emit(TRARuntimeEventKind.LeaderboardDisabled, Leaderboard.ID, Integer(Leaderboard.InvalidAddress));
end;

procedure TRARuntime.InvalidateAddress(Address: Cardinal);
begin
  FMemrefs.InvalidateAddress(Address, QueueInvalidMemref);
end;

function TRARuntime.ValidateAddresses(const Validate: TRAAddressValidator): TArray<TRARuntimeEvent>;
begin
  if not Assigned(Validate) then
    raise EArgumentNilException.Create('RetroAchievements address validator is required');
  if not FMemrefs.ValidateAddresses(Validate, QueueInvalidMemref) then
    Exit(nil);
  FEvents.Clear;
  for var Index := FAchievements.Count - 1 downto 0 do
    DisableInvalid(FAchievements[Index]);
  for var Index := FLeaderboards.Count - 1 downto 0 do
    DisableInvalid(FLeaderboards[Index]);
  Result := FEvents.ToArray;
end;

function TRARuntime.EvaluateFrame(const ReadMemory: TRAMemoryRead; ClientFrame: Boolean): TArray<TRARuntimeEvent>;
var
  ReadFrame: TRAMemoryRead;
  Achievement: TAchievement;
  Leaderboard: TLeaderboard;
  PreviousState: TRATriggerState;
  Frame: TRATriggerFrame;
  PreviousProgress, Progress: TRAMeasuredProgress;
  PreviousBoardState, BoardState: TRALeaderboardState;
  Value: Integer;
begin
  FEvents.Clear;
  try
    FMemory.BeginFrame(ReadMemory);
    ReadFrame := FMemory.Read;
    FMemrefs.Update(ReadFrame, QueueInvalidMemref);
    for var Index := FAchievements.Count - 1 downto 0 do
    begin
      Achievement := FAchievements[Index];
      if DisableInvalid(Achievement) then
        Continue;
      PreviousState := Achievement.Trigger.State;
      PreviousProgress := Achievement.Trigger.Measured;
      Frame := Achievement.Trigger.EvaluateFrame(ReadFrame);
      if Frame = TRATriggerFrame.Inactive then
        Continue;
      if Frame = TRATriggerFrame.Disabled then
      begin
        Emit(TRARuntimeEventKind.AchievementDisabled, Achievement.ID, Integer(FMemory.LastFailure));
        Continue;
      end;
      if Frame = TRATriggerFrame.Reset then
        Emit(TRARuntimeEventKind.AchievementReset, Achievement.ID);

      Progress := Achievement.Trigger.Measured;
      if PreviousProgress.Known and (PreviousProgress.Value <> High(Cardinal)) and Progress.Known and
        (PreviousProgress.Value <> Progress.Value) and (Progress.Target <> 0) and (Progress.Value <= Progress.Target) and
        not (Achievement.Trigger.State in [TRATriggerState.Waiting, TRATriggerState.Triggered]) then
      begin
        if not Progress.AsPercent then
          Emit(TRARuntimeEventKind.AchievementProgressUpdated, Achievement.ID, Integer(Progress.Value))
        else if Percent(Progress.Value, Progress.Target) <> Percent(PreviousProgress.Value, Progress.Target) then
          Emit(TRARuntimeEventKind.AchievementProgressUpdated, Achievement.ID,
            Integer(Percent(Progress.Value, Progress.Target)));
      end;
      if PreviousState = Achievement.Trigger.State then
        Continue;
      if PreviousState = TRATriggerState.Primed then
        Emit(TRARuntimeEventKind.AchievementUnprimed, Achievement.ID);
      case Achievement.Trigger.State of
        TRATriggerState.Triggered:
          Emit(TRARuntimeEventKind.AchievementTriggered, Achievement.ID);
        TRATriggerState.Paused:
          Emit(TRARuntimeEventKind.AchievementPaused, Achievement.ID);
        TRATriggerState.Primed:
          Emit(TRARuntimeEventKind.AchievementPrimed, Achievement.ID);
        TRATriggerState.Active:
          if PreviousState in [TRATriggerState.Waiting, TRATriggerState.Paused] then
            Emit(TRARuntimeEventKind.AchievementActivated, Achievement.ID);
      end;
    end;

    for var Offset := 0 to FLeaderboards.Count - 1 do
    begin
      if ClientFrame then
        Leaderboard := FLeaderboards[Offset]
      else
        Leaderboard := FLeaderboards[FLeaderboards.Count - 1 - Offset];
      if DisableInvalid(Leaderboard) then
        Continue;
      PreviousBoardState := Leaderboard.Board.State;
      BoardState := Leaderboard.Board.EvaluateFrame(ReadFrame, Value);
      case BoardState of
        TRALeaderboardState.Started:
          begin
            if PreviousBoardState <> BoardState then
              Emit(TRARuntimeEventKind.LeaderboardStarted, Leaderboard.ID, Value)
            else if Leaderboard.Value <> Value then
              Emit(TRARuntimeEventKind.LeaderboardUpdated, Leaderboard.ID, Value)
            else if ClientFrame then
              Emit(TRARuntimeEventKind.LeaderboardTrackerSample, Leaderboard.ID, Value);
            Leaderboard.Value := Value;
          end;
        TRALeaderboardState.Canceled:
          Emit(TRARuntimeEventKind.LeaderboardCanceled, Leaderboard.ID);
        TRALeaderboardState.Triggered:
          Emit(TRARuntimeEventKind.LeaderboardTriggered, Leaderboard.ID, Value);
        TRALeaderboardState.Disabled:
          Emit(TRARuntimeEventKind.LeaderboardDisabled, Leaderboard.ID, Integer(FMemory.LastFailure));
      end;
    end;

    if FRichPresence <> nil then
    begin
      FRichPresence.UpdateFrame(ReadFrame);
      FRichPresencePreviewPending := True;
    end;
    Result := FEvents.ToArray;
  finally
    FMemory.BeginFrame(nil);
  end;
end;

function TRARuntime.TryGetAchievementState(ID: Cardinal; out State: TRATriggerState; out Progress: TRAMeasuredProgress): Boolean;
var
  Trigger: TRATrigger;
begin
  Trigger := GetAchievement(ID);
  Result := Trigger <> nil;
  if Result then
  begin
    State := Trigger.State;
    Progress := Trigger.Measured;
    if not Progress.Known or (Progress.Value = High(Cardinal)) then
    begin
      // rcheevos reserves UINT32_MAX for an unknown measurement.
      Progress.Known := False;
      Progress.Value := 0;
    end;
  end
  else
  begin
    State := TRATriggerState.Waiting;
    Progress := Default(TRAMeasuredProgress);
  end;
end;

function TRARuntime.TryGetMeasured(ID: Cardinal; out Progress: TRAMeasuredProgress): Boolean;
var
  State: TRATriggerState;
begin
  Result := TryGetAchievementState(ID, State, Progress);
  if State in [TRATriggerState.Triggered, TRATriggerState.Disabled] then
    Progress := Default(TRAMeasuredProgress);
end;

function FormatRAClientMeasured(const Progress: TRAMeasuredProgress): string;
var
  Percentage: Single;
begin
  Result := FormatRAClientMeasured(Progress, Percentage);
end;

function RAClientMeasuredPercent(const Progress: TRAMeasuredProgress): Single;
var
  ScaledValue, Target: Single;
begin
  if not Progress.Known or (Progress.Value = 0) or (Progress.Target = 0) then
    Exit(0);
  // The client rounds its operands and scaled numerator to single precision.
  ScaledValue := Min(Progress.Value, Progress.Target);
  ScaledValue := ScaledValue * 100;
  Target := Progress.Target;
  Result := ScaledValue / Target;
end;

function FormatRAClientMeasured(const Progress: TRAMeasuredProgress; out Percentage: Single): string;
var
  Display: array[0..23] of AnsiChar;
  NumeratorLength: NativeUInt;
begin
  Result := '';
  Percentage := RAClientMeasuredPercent(Progress);
  if Percentage = 0 then
    Exit;
  if Progress.AsPercent then
  begin
    if Percentage >= 1 then
      Result := UIntToStr(Trunc(Percentage)) + '%';
  end
  else
  begin
    // rc_client reserves the separator and formats both numbers into measured_progress.
    NumeratorLength := FormatRAValue(Integer(Min(Progress.Value, Progress.Target)), TRAValueFormat.Unsigned,
      @Display[0], SizeOf(Display) - 1);
    Display[NumeratorLength] := '/';
    FormatRAValue(Integer(Progress.Target), TRAValueFormat.Unsigned, @Display[NumeratorLength + 1],
      SizeOf(Display) - NumeratorLength - 1);
    Result := string(AnsiString(PAnsiChar(@Display[0])));
  end;
end;

function TRARuntime.FormatMeasured(ID: Cardinal): string;
var
  Progress: TRAMeasuredProgress;
  Value: Cardinal;
begin
  if not TryGetMeasured(ID, Progress) or (Progress.Target = 0) then
    Exit('');
  Value := Min(Progress.Value, Progress.Target);
  if Progress.AsPercent then
    Result := UIntToStr(Percent(Value, Progress.Target)) + '%'
  else
    Result := UIntToStr(Value) + '/' + UIntToStr(Progress.Target);
end;

function TRARuntime.FormatMeasured(ID: Cardinal; Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(0);
  Result := CopyRAUTF8Text(FormatMeasured(ID), Buffer, BufferSize);
end;

procedure TRARuntime.Reset;
begin
  for var Achievement in FAchievements do
    Achievement.Trigger.Reset;
  for var Leaderboard in FLeaderboards do
    Leaderboard.Board.Reset;
  if FRichPresence <> nil then
    FRichPresence.Reset;
  FRichPresenceText := '';
  FRichPresencePreviewPending := False;
end;

const
  ProgressMagic = $31504152; // RAP1
  ProgressVersion = 3;

procedure TRARuntime.ClearProgress;
begin
  FMemrefs.ClearSamples;
  for var Achievement in FAchievements do
    Achievement.Trigger.ClearProgress;
  for var Leaderboard in FLeaderboards do
  begin
    Leaderboard.Board.ClearProgress;
    Leaderboard.Value := 0;
  end;
  if FRichPresence <> nil then
    FRichPresence.ClearProgress;
  FRichPresenceText := '';
  FRichPresencePreviewPending := False;
end;

function TRARuntime.CaptureProgress: TBytes;
var
  Stream, Section: TBytesStream;
  Writer, Part: TRAProgressIO;

  procedure BeginSection;
  begin
    Section.Size := 0;
    Section.Position := 0;
  end;

  procedure WriteSection;
  begin
    Writer.WriteBytes(Copy(Section.Bytes, 0, Section.Size));
  end;

begin
  Stream := TBytesStream.Create;
  try
    Section := TBytesStream.Create;
    try
      Writer := TRAProgressIO.Create(Stream);
      Part := TRAProgressIO.Create(Section);
      Writer.WriteUInt(ProgressMagic);
      Writer.WriteUInt(ProgressVersion);
      Writer.WriteUInt(FAchievements.Count);
      for var Achievement in FAchievements do
      begin
        Writer.WriteUInt(Achievement.ID);
        Writer.WriteString(Achievement.Definition);
        BeginSection;
        Achievement.Trigger.WriteProgress(Part);
        WriteSection;
      end;
      Writer.WriteUInt(FLeaderboards.Count);
      for var Leaderboard in FLeaderboards do
      begin
        Writer.WriteUInt(Leaderboard.ID);
        Writer.WriteString(Leaderboard.Definition);
        BeginSection;
        Part.WriteUInt(Cardinal(Leaderboard.Value));
        Leaderboard.Board.WriteProgress(Part);
        WriteSection;
      end;
      Writer.WriteFlag(FRichPresence <> nil);
      if FRichPresence <> nil then
      begin
        Writer.WriteString(FRichPresenceScript);
        BeginSection;
        Part.WriteString(GetRichPresenceText);
        FRichPresence.WriteProgress(Part);
        WriteSection;
      end;
      BeginSection;
      FMemrefs.WriteTo(Part);
      WriteSection;
      BeginSection;
      FMemrefs.WriteModifiedTo(Part);
      WriteSection;
      Result := Copy(Stream.Bytes, 0, Stream.Size);
    finally
      Section.Free;
    end;
  finally
    Stream.Free;
  end;
end;

procedure TRARuntime.LoadProgress(const Data: TBytes);
var
  Stream, Section: TBytesStream;
  Reader, Part: TRAProgressIO;
  Count, ID, Version: Cardinal;
  Index: Integer;
  Definition: string;
  Bytes: TBytes;
  Seen: TDictionary<Cardinal, Boolean>;

  function ReadCount: Cardinal;
  begin
    Result := Reader.ReadUInt;
    // Each entry has an ID and two length fields, even when both fields are empty.
    if UInt64(Result) * 12 > UInt64(Reader.Remaining) then
      raise ERAProgressError.Create('Invalid RetroAchievements progress entry count');
  end;

  procedure ReadEntry;
  begin
    ID := Reader.ReadUInt;
    if Seen.ContainsKey(ID) then
      raise ERAProgressError.Create('Duplicate RetroAchievements progress ID');
    Seen.Add(ID, True);
    Definition := Reader.ReadString;
    Bytes := Reader.ReadBytes;
  end;

begin
  Stream := TBytesStream.Create(Data);
  try
    Reader := TRAProgressIO.Create(Stream);
    Reader.ExpectUInt(ProgressMagic);
    Version := Reader.ReadUInt;
    if (Version < 1) or (Version > ProgressVersion) then
      raise ERAProgressError.Create('Unknown RetroAchievements progress version');
    Seen := TDictionary<Cardinal, Boolean>.Create;
    try
      Count := ReadCount;
      ClearProgress;
      while Count <> 0 do
      begin
        ReadEntry;
        Index := FindAchievement(ID);
        if (Index >= 0) and (FAchievements[Index].Definition = Definition) then
        begin
          Section := TBytesStream.Create(Bytes);
          try
            Part := TRAProgressIO.Create(Section);
            FAchievements[Index].Trigger.ReadProgress(Part);
            Part.ExpectEnd;
          finally
            Section.Free;
          end;
        end;
        Dec(Count);
      end;
      Seen.Clear;
      Count := ReadCount;
      while Count <> 0 do
      begin
        ReadEntry;
        Index := FindLeaderboard(ID);
        if (Index >= 0) and (FLeaderboards[Index].Definition = Definition) then
        begin
          Section := TBytesStream.Create(Bytes);
          try
            Part := TRAProgressIO.Create(Section);
            FLeaderboards[Index].Value := Integer(Part.ReadUInt);
            FLeaderboards[Index].Board.ReadProgress(Part);
            Part.ExpectEnd;
          finally
            Section.Free;
          end;
        end;
        Dec(Count);
      end;
    finally
      Seen.Free;
    end;
    if Reader.ReadFlag then
    begin
      Definition := Reader.ReadString;
      Bytes := Reader.ReadBytes;
      if (FRichPresence <> nil) and (RARichPresenceScriptPrefix(Definition) = FRichPresenceScript) then
      begin
        Section := TBytesStream.Create(Bytes);
        try
          Part := TRAProgressIO.Create(Section);
          FRichPresenceText := Part.ReadString;
          FRichPresence.ReadProgress(Part);
          Part.ExpectEnd;
        finally
          Section.Free;
        end;
      end;
    end;
    if Version >= 2 then
    begin
      Bytes := Reader.ReadBytes;
      Section := TBytesStream.Create(Bytes);
      try
        var Memrefs := TRARuntimeMemrefs.Create;
        try
          Memrefs.ReadFrom(TRAProgressIO.Create(Section));
          FMemrefs.RestoreSamples(Memrefs);
        finally
          Memrefs.Free;
        end;
      finally
        Section.Free;
      end;
    end;
    if Version >= 3 then
    begin
      Bytes := Reader.ReadBytes;
      Section := TBytesStream.Create(Bytes);
      try
        FMemrefs.ReadModifiedFrom(TRAProgressIO.Create(Section));
      finally
        Section.Free;
      end;
    end;
    Reader.ExpectEnd;
  finally
    Stream.Free;
  end;
end;

function TRARuntime.ProgressSize: NativeUInt;
begin
  Result := CollectRCProgressChunks(nil);
end;

function TRARuntime.SerializeProgress(Buffer: PByte): Integer;
begin
  Result := SerializeProgressSized(Buffer, High(Cardinal));
end;

function TRARuntime.DeserializeProgress(Buffer: PByte): Integer;
begin
  Result := DeserializeProgressSized(Buffer, High(Cardinal));
end;

function TRARuntime.SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  if Buffer = nil then
    Exit(RAErrorInvalidState);
  if BufferSize < RCProgressMinimumSize then
    Exit(RAErrorInsufficientBuffer);
  if not EncodeRCProgress(BuildRCProgressChunks, Buffer, BufferSize) then
    Exit(RAErrorInsufficientBuffer);
  Result := RAErrorOK;
end;

function TRARuntime.DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  case ReadRCProgressBuffer(Buffer, BufferSize) of
    TRAProgressReadStatus.Success:
      Result := RAErrorOK;
    TRAProgressReadStatus.InsufficientBuffer:
      Result := RAErrorInsufficientBuffer;
  else
    Result := RAErrorInvalidState;
  end;

  // Reset conditions after a failed import. Their memory history is independent.
  if Result <> RAErrorOK then
    Reset;
end;

function TRARuntime.TryCaptureRCProgress(out Data: TBytes): Boolean;
begin
  Data := EncodeRCProgress(BuildRCProgressChunks);
  Result := True;
end;

function TRARuntime.BuildRCProgressChunks: TArray<TRAProgressChunk>;
var
  Chunks: TList<TRAProgressChunk>;
begin
  Chunks := TList<TRAProgressChunk>.Create;
  try
    CollectRCProgressChunks(Chunks);
    Result := Chunks.ToArray;
  finally
    Chunks.Free;
  end;
end;

function TRARuntime.CollectRCProgressChunks(Chunks: TList<TRAProgressChunk>): NativeUInt;
var
  Stream: TBytesStream;
  IO: TRAProgressIO;
  Size, PayloadSize: UInt64;

  procedure FinishChunk(Kind: Cardinal; SkipEmpty: Boolean = False);
  begin
    if Stream <> nil then
      PayloadSize := UInt64(Stream.Size);
    if not SkipEmpty or (PayloadSize <> 0) then
    begin
      if PayloadSize > UInt64(High(Integer)) then
        raise ERAProgressError.Create('RetroAchievements progress section is too large');
      Inc(Size, 2 * SizeOf(Cardinal) + PayloadSize);
      if Size > High(Cardinal) then
        raise ERAProgressError.Create('RetroAchievements progress is too large');
      if Stream <> nil then
        Chunks.Add(TRAProgressChunk.Create(Kind, Copy(Stream.Bytes, 0, Integer(PayloadSize))));
    end;
    PayloadSize := 0;
    if Stream <> nil then
    begin
      Stream.Size := 0;
      Stream.Position := 0;
    end;
  end;

  procedure WriteFingerprint(const Definition: string);
  var
    Fingerprint: TRAProgressDigest;
  begin
    if Stream <> nil then
      Fingerprint := RAProgressDigest(Definition)
    else
      Fingerprint := Default(TRAProgressDigest);
    IO.WriteRaw(Fingerprint, SizeOf(Fingerprint));
  end;

begin
  Stream := nil;
  try
    if Chunks <> nil then
    begin
      Stream := TBytesStream.Create;
      IO := TRAProgressIO.Create(Stream);
    end
    else
      IO := TRAProgressIO.CreateCounter(PayloadSize);
    Size := RCProgressMinimumSize;
    FMemrefs.WriteTo(IO);
    FinishChunk(RCProgressMemrefs, True);

    if (FRichPresence <> nil) and FRichPresence.HasRCVariables then
    begin
      FRichPresence.WriteRCVariables(IO);
      FinishChunk(RCProgressVariables);
    end;

    for var Achievement in FAchievements do
    begin
      if Achievement.Trigger.State in [TRATriggerState.Disabled, TRATriggerState.Triggered] then
        Continue;
      IO.WriteUInt(Achievement.ID);
      WriteFingerprint(Achievement.Definition);
      Achievement.Trigger.WriteRCProgress(IO);
      FinishChunk(RCProgressAchievement);
    end;
    for var Leaderboard in FLeaderboards do
    begin
      if Leaderboard.Board.State in [TRALeaderboardState.Disabled, TRALeaderboardState.Inactive] then
        Continue;
      IO.WriteUInt(Leaderboard.ID);
      WriteFingerprint(Leaderboard.Definition);
      Leaderboard.Board.WriteRCProgress(IO);
      FinishChunk(RCProgressLeaderboard);
    end;
    if (FRichPresence <> nil) and FRichPresence.HasRCConditions then
    begin
      WriteFingerprint(FRichPresenceScript);
      FRichPresence.WriteRCConditions(IO);
      FinishChunk(RCProgressRichPresence);
    end;
    Result := NativeUInt(Size);
  finally
    Stream.Free;
  end;
end;

function TRARuntime.ReadRCProgress(const Data: TBytes): TRAProgressReadStatus;
begin
  Result := ReadRCProgressBuffer(PByte(Data), Length(Data));
end;

function TRARuntime.ReadRCProgressBuffer(Buffer: PByte; BufferSize: NativeUInt): TRAProgressReadStatus;
var
  Chunks: TArray<TRAProgressChunk>;
  MemrefChunks: TObjectList<TRARuntimeMemrefs>;

  procedure ReadEntries(Apply: Boolean);
  var
    Seen: TDictionary<UInt64, Boolean>;
    Stream: TBytesStream;
    IO: TRAProgressIO;
    ID: Cardinal;
    Index: Integer;
    Key: UInt64;
    Stored, Expected: TRAProgressDigest;
    Achievement: TAchievement;
    Leaderboard: TLeaderboard;
  begin
    Seen := TDictionary<UInt64, Boolean>.Create;
    try
      for var Chunk in Chunks do
      begin
        if (Chunk.Kind <> RCProgressAchievement) and (Chunk.Kind <> RCProgressLeaderboard) then
          Continue;
        Stream := TBytesStream.Create(Chunk.Data);
        try
          IO := TRAProgressIO.Create(Stream);
          ID := IO.ReadUInt;
          Key := (UInt64(Chunk.Kind) shl 32) or ID;
          if Seen.ContainsKey(Key) then
            Continue;
          Achievement := nil;
          Leaderboard := nil;
          if Chunk.Kind = RCProgressAchievement then
          begin
            Index := FindAchievement(ID);
            if Index < 0 then
              Continue;
            Achievement := FAchievements[Index];
            if Achievement.Trigger.State in [TRATriggerState.Disabled, TRATriggerState.Triggered] then
              Continue;
            Expected := RAProgressDigest(Achievement.Definition);
          end
          else
          begin
            Index := FindLeaderboard(ID);
            if Index < 0 then
              Continue;
            Leaderboard := FLeaderboards[Index];
            if Leaderboard.Board.State in [TRALeaderboardState.Disabled, TRALeaderboardState.Inactive] then
              Continue;
            Expected := RAProgressDigest(Leaderboard.Definition);
          end;
          IO.ReadRaw(Stored, SizeOf(Stored));
          if not CompareMem(@Expected, @Stored, SizeOf(Stored)) then
            Continue;
          if Achievement <> nil then
            Achievement.Trigger.ReadRCProgress(IO, Apply)
          else
            Leaderboard.Board.ReadRCProgress(IO, Apply);
          // rcheevos reads the known fields and resumes at the next chunk boundary.
          Seen.Add(Key, True);
        finally
          Stream.Free;
        end;
      end;
      if Apply then
      begin
        for var Entry in FAchievements do
          if not (Entry.Trigger.State in [TRATriggerState.Disabled, TRATriggerState.Triggered]) and
            not Seen.ContainsKey((UInt64(RCProgressAchievement) shl 32) or Entry.ID) then
            Entry.Trigger.Reset;
        for var Entry in FLeaderboards do
          if not (Entry.Board.State in [TRALeaderboardState.Disabled, TRALeaderboardState.Inactive]) and
            not Seen.ContainsKey((UInt64(RCProgressLeaderboard) shl 32) or Entry.ID) then
            Entry.Board.Reset;
      end;
    finally
      Seen.Free;
    end;
  end;

  procedure ReadPresence(Apply: Boolean);
  var
    Stream: TBytesStream;
    IO: TRAProgressIO;
    Expected, Stored: TRAProgressDigest;
    Matched: Boolean;
  begin
    if FRichPresence = nil then
      Exit;
    Matched := False;
    Expected := RAProgressDigest(FRichPresenceScript);
    for var Chunk in Chunks do
    begin
      if (Chunk.Kind <> RCProgressVariables) and (Chunk.Kind <> RCProgressRichPresence) then
        Continue;
      Stream := TBytesStream.Create(Chunk.Data);
      try
        IO := TRAProgressIO.Create(Stream);
        if Chunk.Kind = RCProgressVariables then
          FRichPresence.ReadRCVariables(IO, Apply)
        else
        begin
          IO.ReadRaw(Stored, SizeOf(Stored));
          Matched := CompareMem(@Expected, @Stored, SizeOf(Stored));
          if Matched then
            FRichPresence.ReadRCConditions(IO, Apply);
        end;
      finally
        Stream.Free;
      end;
    end;
    if Apply and not Matched then
      FRichPresence.ResetRCConditions;
  end;

var
  Stream: TBytesStream;
  IO: TRAProgressIO;
  Memrefs: TRARuntimeMemrefs;
begin
  Result := DecodeRCProgress(Buffer, BufferSize, Chunks);
  if Result <> TRAProgressReadStatus.Success then
    Exit;

  MemrefChunks := TObjectList<TRARuntimeMemrefs>.Create;
  try
    try
      for var Chunk in Chunks do
        if Chunk.Kind = RCProgressMemrefs then
        begin
          Memrefs := TRARuntimeMemrefs.Create;
          MemrefChunks.Add(Memrefs);
          Stream := TBytesStream.Create(Chunk.Data);
          try
            IO := TRAProgressIO.Create(Stream);
            Memrefs.ReadFrom(IO);
          finally
            Stream.Free;
          end;
        end;
      ReadEntries(False);
      ReadPresence(False);
    except
      on ERAProgressError do
        Exit(TRAProgressReadStatus.InvalidData);
    end;

    for var Samples in MemrefChunks do
    begin
      FMemrefs.RestoreSamples(Samples);
      FMemrefs.RestoreModifiedSamples;
    end;
    ReadEntries(True);
    if FRichPresence <> nil then
    begin
      ReadPresence(True);
      FRichPresenceText := FRichPresence.RestoreRCDisplay;
      FRichPresencePreviewPending := False;
    end;
  finally
    MemrefChunks.Free;
  end;
end;

procedure TRARuntime.RefreshRestoredLeaderboardTrackers;
begin
  for var Leaderboard in FLeaderboards do
    if Leaderboard.Board.State = TRALeaderboardState.Started then
      Leaderboard.Value := Leaderboard.Board.RCCurrentValue;
end;

function TRARuntime.RestoreProgress(const Data: TBytes): Boolean;
var
  Backup: TBytes;
begin
  if Length(Data) = 0 then
  begin
    ClearProgress;
    Exit(True);
  end;
  if IsRCProgress(Data) then
    Exit(ReadRCProgress(Data) = TRAProgressReadStatus.Success);
  Backup := CaptureProgress;
  try
    LoadProgress(Data);
    Result := True;
  except
    on ERAProgressError do
    begin
      LoadProgress(Backup);
      Result := False;
    end;
  end;
end;

end.

