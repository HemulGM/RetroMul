unit RA.Connection;

interface

uses
  Core.Emulation.Types, Core.Storage, System.Classes,
  System.Generics.Collections, System.SyncObjs, System.SysUtils, RA.GameData,
  RA.Hash, RA.Http, RA.Protocol, RA.Runtime, RA.Session;

type
  IRAConnection = interface(IEmulationAchievementObserver)
    ['{9585C936-518D-4182-BB26-D3EE91071410}']
    function GameData: TRAGameData;
    function TryGetCoreAchievement(AchievementId: Cardinal; out Achievement: TRAClientAchievement): Boolean;
    procedure CacheUnlockDates(const Storage: IStorage; AchievementId: Cardinal = 0);
    function TakeRuntimeEvents: TArray<TRARuntimeEvent>;
    function TakeSubmissions: TArray<TRASubmission>;
    function TakeError: string;
    procedure SetShareRichPresence(Value: Boolean);
  end;

function TryHashRAFile(const Storage: IStorage; const SystemId, Location: string; const Media: IEmulationAchievementMedia; out Digest: string): Boolean;

// Loads catalog definitions without starting an emulation session.
function LoadRAGameAchievementCache(const Storage: IStorage; const Digest: string; ConsoleId: Cardinal; out GameIds: TArray<Cardinal>): TArray<TRAAchievementDefinition>;

function FetchRAGameAchievements(const Storage: IStorage; Client: TRAHttpClient; const Credentials: TRACredentials; const Digest: string; ConsoleId: Cardinal; out GameIds: TArray<Cardinal>): TArray<TRAAchievementDefinition>;

function LoadRAUnlockCache(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; out Unlocks: TArray<Cardinal>): Boolean;

procedure SaveRAUnlockCache(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; const Unlocks: TArray<Cardinal>);

function FetchRAAchievementUnlocks(Client: TRAHttpClient; const Credentials: TRACredentials; const GameIds: TArray<Cardinal>; const Active: TFunc<Boolean>; out Unlocks: TArray<Cardinal>): Boolean;

procedure LoadRAUnlockDates(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; const Dates: TDictionary<Cardinal, Int64>);

function LoadRABadgePNG(const Storage: IStorage; Client: TRAHttpClient; const URL: string): TBytes;

// Call on a background worker, then attach the returned observer on the frontend thread.
function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean = True): IRAConnection; overload;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost): IRAConnection; overload;

implementation

uses
  System.Hash, System.IOUtils, System.JSON, Core.EmulatorRegistry,
  Core.MediaArchive, RA.Info, RA.Memory;

function TryHashRAFile(const Storage: IStorage; const SystemId, Location: string; const Media: IEmulationAchievementMedia; out Digest: string): Boolean;
begin
  Digest := '';
  if Media = nil then
    Exit(False);
  var Stream := Storage.OpenRead(Location);
  try
    var Context := TCoreLoadContext.Create(Stream, Storage, Location);
    try
      if IsMediaArchive(Context.SourceName) then
      begin
        var Match := ResolveEmulationCore(Context, SystemId, '');
        try
          if (Match = nil) or (Match.PlatformId <> SystemId) or not Context.ArchiveEntry then
            Exit(False);
        finally
          Match.Free;
        end;
      end;
      var Input := Context.Stream;
      Input.Position := 0;
      Result := Media.AcceptsROM(Context.SourceName, Input) and
        TryHashRAEmulatedROM(TRARomConsole(Media.ConsoleId), Input, Digest);
    finally
      Context.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function RAAchievementCachePath(const Storage: IStorage; const Kind, Key: string): string;
begin
  Result := TPath.Combine(Storage.Root, 'retroachievements' + PathDelim + Kind + PathDelim +
    THashSHA2.GetHashString(Key) + '.json');
end;

function ReadRAAchievementCache(const Storage: IStorage; const Location: string): TJSONObject;
const
  MaxCacheBytes = 8 * 1024 * 1024;
begin
  Result := nil;
  if not Storage.Exists(Location) then
    Exit;
  var Input := Storage.OpenRead(Location);
  try
    if (Input.Size <= 0) or (Input.Size > MaxCacheBytes) then
      Exit;
    var Data: TBytes;
    SetLength(Data, Input.Size);
    Input.ReadBuffer(Data[0], Length(Data));
    var Value := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Data));
    if Value is TJSONObject then
      Result := TJSONObject(Value)
    else
      Value.Free;
  finally
    Input.Free;
  end;
end;

procedure WriteRAAchievementCache(const Storage: IStorage; const Location: string; const Data: TJSONObject);
begin
  try
    Storage.WriteBytes(Location, TEncoding.UTF8.GetBytes(Data.ToJSON));
  except
    // A read-only cache does not prevent showing data fetched this session.
  end;
end;

const
  FirstClientWarningId = 101000001;

function ReadRAGameAchievements(Response: TJSONObject; ConsoleId: Cardinal; out GameIds: TArray<Cardinal>): TArray<TRAAchievementDefinition>;
begin
  GameIds := nil;
  var Game := ReadRAGameData(Response);
  if (Game.ID = 0) or (Game.ConsoleID <> ConsoleId) then
    Exit(nil);
  var Seen := THashSet<Cardinal>.Create;
  var Games := THashSet<Cardinal>.Create;
  var Definitions := TList<TRAAchievementDefinition>.Create;
  try
    Games.Add(Game.ID);
    for var GameSet in Game.Sets do
      for var Achievement in GameSet.Achievements do
        if (Achievement.Category = RACoreAchievement) and (Achievement.ID < FirstClientWarningId) then
        begin
          if GameSet.GameID <> 0 then
            Games.Add(GameSet.GameID);
          if Seen.Add(Achievement.ID) then
            Definitions.Add(Achievement);
        end;
    Result := Definitions.ToArray;
    GameIds := Games.ToArray;
  finally
    Definitions.Free;
    Games.Free;
    Seen.Free;
  end;
end;

function LoadRAGameAchievementCache(const Storage: IStorage; const Digest: string; ConsoleId: Cardinal; out GameIds: TArray<Cardinal>): TArray<TRAAchievementDefinition>;
begin
  Result := nil;
  GameIds := nil;
  try
    var Response := ReadRAAchievementCache(Storage,
      RAAchievementCachePath(Storage, 'games', UIntToStr(ConsoleId) + ':' + Digest));
    if Response = nil then
      Exit;
    try
      Result := ReadRAGameAchievements(Response, ConsoleId, GameIds);
    finally
      Response.Free;
    end;
  except
    // A damaged cache can be refreshed over the network.
  end;
end;

function FetchRAGameAchievements(const Storage: IStorage; Client: TRAHttpClient; const Credentials: TRACredentials; const Digest: string; ConsoleId: Cardinal; out GameIds: TArray<Cardinal>): TArray<TRAAchievementDefinition>;
begin
  var Response := Client.Post(TRARequest.FetchGameSets(Credentials, Digest));
  try
    Result := ReadRAGameAchievements(Response, ConsoleId, GameIds);
    if Length(Result) > 0 then
      WriteRAAchievementCache(Storage,
        RAAchievementCachePath(Storage, 'games', UIntToStr(ConsoleId) + ':' + Digest), Response);
  finally
    Response.Free;
  end;
end;

function LoadRAUnlockCache(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; out Unlocks: TArray<Cardinal>): Boolean;
begin
  Result := False;
  Unlocks := nil;
  try
    var Response := ReadRAAchievementCache(Storage, RAAchievementCachePath(Storage, 'progress',
        UIntToStr(ConsoleId) + ':' + Digest + ':' + UserName.ToLowerInvariant));
    if Response = nil then
      Exit;
    try
      Unlocks := ReadRAUserUnlocks(Response);
      Result := True;
    finally
      Response.Free;
    end;
  except
    // The absence of a valid snapshot is distinct from zero unlocks.
  end;
end;

procedure SaveRAUnlockCache(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; const Unlocks: TArray<Cardinal>);
begin
  var Data := TJSONObject.Create;
  try
    var Ids := TJSONArray.Create;
    Data.AddPair('UserUnlocks', Ids);
    for var Id in Unlocks do
      Ids.AddElement(TJSONNumber.Create(Int64(Id)));
    WriteRAAchievementCache(Storage, RAAchievementCachePath(Storage, 'progress',
        UIntToStr(ConsoleId) + ':' + Digest + ':' + UserName.ToLowerInvariant), Data);
  finally
    Data.Free;
  end;
end;

function FetchRAAchievementUnlocks(Client: TRAHttpClient; const Credentials: TRACredentials; const GameIds: TArray<Cardinal>; const Active: TFunc<Boolean>; out Unlocks: TArray<Cardinal>): Boolean;
begin
  Result := True;
  Unlocks := nil;
  var Seen := THashSet<Cardinal>.Create;
  try
    for var GameId in GameIds do
      for var Hardcore := False to True do
      begin
        if not Active() then
          Exit(False);
        try
          var Response := Client.Post(TRARequest.FetchUserUnlocks(Credentials, GameId, Hardcore));
          try
            for var AchievementId in ReadRAUserUnlocks(Response) do
              Seen.Add(AchievementId);
          finally
            Response.Free;
          end;
        except
          Result := False;
        end;
      end;
    Unlocks := Seen.ToArray;
  finally
    Seen.Free;
  end;
end;

function RAUnlockDatesPath(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal): string;
begin
  Result := RAAchievementCachePath(Storage, 'unlock-dates',
    UIntToStr(ConsoleId) + ':' + Digest + ':' + UserName.ToLowerInvariant);
end;

procedure LoadRAUnlockDates(const Storage: IStorage; const Digest, UserName: string; ConsoleId: Cardinal; const Dates: TDictionary<Cardinal, Int64>);
begin
  Dates.Clear;
  if UserName = '' then
    Exit;
  try
    var Data := ReadRAAchievementCache(Storage, RAUnlockDatesPath(Storage, Digest, UserName, ConsoleId));
    try
      if Data = nil then
        Exit;
      for var Pair in Data do
      begin
        var Id: Cardinal;
        var Awarded: Int64;
        if TryStrToUInt(Pair.JsonString.Value, Id) and (Pair.JsonValue is TJSONNumber) and
          TryStrToInt64(Pair.JsonValue.Value, Awarded) and (Awarded > 0) and
          (Awarded <= 253402214399) then
          Dates.AddOrSetValue(Id, Awarded);
      end;
    finally
      Data.Free;
    end;
  except
    // The list still has the unlocked status when the dates cache is unreadable.
  end;
end;

function LoadRABadgePNG(const Storage: IStorage; Client: TRAHttpClient; const URL: string): TBytes;
begin
  Result := nil;
  if URL = '' then
    Exit;
  var Location := TPath.Combine(Storage.Root, 'retroachievements' + PathDelim + 'badges' + PathDelim +
    THashSHA2.GetHashString(URL) + '.png');
  try
    if Storage.Exists(Location) then
    begin
      var Input := Storage.OpenRead(Location);
      try
        var Size := Input.Size;
        if (Size > 0) and (Size <= RAMaxBadgeBytes) then
        begin
          var Cached: TBytes;
          SetLength(Cached, Size);
          Input.ReadBuffer(Cached[0], Length(Cached));
          if IsRABadgePNG(Cached) then
            Exit(Cached);
        end;
      finally
        Input.Free;
      end;
    end;
  except
    // Cache failures do not prevent downloading and showing the badge.
  end;
  Result := Client.GetBadgePNG(URL);
  if Length(Result) = 0 then
    Exit;
  try
    Storage.WriteBytes(Location, Result);
  except
    // The downloaded badge is still usable with a read-only profile.
  end;
end;

type
  TRAConnection = class(TInterfacedObject, IEmulationAchievementObserver, IRAConnection)
  private
    FHTTP: TRAHttpClient;
    FSession: TRASession;
    FNetwork: TThread;
    FWake: TEvent;
    FLock: TCriticalSection;
    FRuntimeEvents: TList<TRARuntimeEvent>;
    FSubmissions: TList<TRASubmission>;
    FError, FGameHash, FUserName: string;
    FConsoleId: Cardinal;
    FEmulationFailed: Boolean;
    procedure BeginSession(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost; ShareRichPresence: Boolean);
    procedure NetworkLoop;
    procedure ReportError(const Message: string);
  public
    constructor Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean); overload;
    constructor Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost); overload;
    destructor Destroy; override;
    procedure Frame(const ReadMemory: TEmulationAchievementRead);
    procedure Reset;
    function CaptureProgress: TBytes;
    procedure RestoreProgress(const Data: TBytes);
    function GameData: TRAGameData;
    function TryGetCoreAchievement(AchievementId: Cardinal; out Achievement: TRAClientAchievement): Boolean;
    procedure CacheUnlockDates(const Storage: IStorage; AchievementId: Cardinal = 0);
    function TakeRuntimeEvents: TArray<TRARuntimeEvent>;
    function TakeSubmissions: TArray<TRASubmission>;
    function TakeError: string;
    procedure SetShareRichPresence(Value: Boolean);
  end;

constructor TRAConnection.Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean);
begin
  inherited Create;
  FHTTP := TRAHttpClient.Create(UserAgent);
  BeginSession(Console, ROM, Credentials, nil, ShareRichPresence);
end;

constructor TRAConnection.Create(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost);
begin
  inherited Create;
  BeginSession(Console, ROM, Credentials, Post, True);
end;

procedure TRAConnection.BeginSession(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost; ShareRichPresence: Boolean);
begin
  if (Length(ROM) = 0) or not TryHashRARom(Console, ROM, FGameHash) then
    raise ERARomNotRecognized.Create('Could not identify the ROM for RetroAchievements');
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FUserName := Credentials.UserName;
  FConsoleId := Ord(Console);
  FRuntimeEvents := TList<TRARuntimeEvent>.Create;
  FSubmissions := TList<TRASubmission>.Create;
  if FHTTP <> nil then
    FSession := TRASession.CreateHosted(FHTTP.PostTo, Credentials, FGameHash, FConsoleId,
      False, nil, ShareRichPresence, False, nil, GetRADefaultAPIHost, GetRADefaultImageHost)
  else
    FSession := TRASession.Create(Post, Credentials, FGameHash, FConsoleId,
      False, nil, ShareRichPresence);
  FNetwork := TThread.CreateAnonymousThread(NetworkLoop);
  FNetwork.FreeOnTerminate := False;
  FNetwork.Start;
end;

destructor TRAConnection.Destroy;
begin
  if FNetwork <> nil then
  begin
    FNetwork.Terminate;
    FWake.SetEvent;
    FNetwork.WaitFor;
    FNetwork.Free;
  end;
  FSession.Free;
  FSubmissions.Free;
  FRuntimeEvents.Free;
  FWake.Free;
  FLock.Free;
  FHTTP.Free;
  inherited;
end;

procedure TRAConnection.NetworkLoop;
var
  Submission: TRASubmission;
begin
  while not TThread.CurrentThread.CheckTerminated do
  begin
    try
      if FSession.PumpNetwork(Submission) then
      begin
        FLock.Acquire;
        try
          FSubmissions.Add(Submission);
        finally
          FLock.Release;
        end;
        Continue;
      end;
    except
      on Error: Exception do
        ReportError(Error.Message);
    end;
    FWake.WaitFor(250);
  end;
end;

procedure TRAConnection.ReportError(const Message: string);
begin
  FLock.Acquire;
  try
    FError := Message;
  finally
    FLock.Release;
  end;
end;

procedure TRAConnection.Frame(const ReadMemory: TEmulationAchievementRead);
var
  Events: TArray<TRARuntimeEvent>;
  Reader: TRAMemoryRead;
begin
  if FEmulationFailed then
    Exit;
  try
    Reader :=
      function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
      begin
        Result := ReadMemory(Address, Buffer, Count);
      end;
    Events := FSession.EvaluateFrame(Reader);
    if Length(Events) <> 0 then
    begin
      FLock.Acquire;
      try
        FRuntimeEvents.AddRange(Events);
      finally
        FLock.Release;
      end;
      FWake.SetEvent;
    end;
  except
    on Error: Exception do
    begin
      FEmulationFailed := True;
      ReportError(Error.Message);
    end;
  end;
end;

procedure TRAConnection.Reset;
begin
  FSession.Reset;
  FEmulationFailed := False;
end;

function TRAConnection.CaptureProgress: TBytes;
begin
  Result := FSession.CaptureProgress;
end;

procedure TRAConnection.RestoreProgress(const Data: TBytes);
begin
  if not FSession.RestoreProgress(Data) then
    FSession.RestoreProgress(nil);
  FEmulationFailed := False;
end;

function TRAConnection.GameData: TRAGameData;
begin
  Result := FSession.Game;
end;

function TRAConnection.TryGetCoreAchievement(AchievementId: Cardinal; out Achievement: TRAClientAchievement): Boolean;
begin
  Result := (AchievementId < FirstClientWarningId) and
    FSession.TryGetAchievementInfo(AchievementId, Achievement) and
    (Achievement.Category = TRAAchievementCategory.Core);
end;

procedure TRAConnection.CacheUnlockDates(const Storage: IStorage; AchievementId: Cardinal);
begin
  var Dates := TDictionary<Cardinal, Int64>.Create;
  try
    LoadRAUnlockDates(Storage, FGameHash, FUserName, FConsoleId, Dates);
    if AchievementId = 0 then
    begin
      for var Bucket in FSession.CreateAchievementList([TRAAchievementCategory.Core], TRAAchievementGrouping.LockState) do
        for var Achievement in Bucket.Achievements do
          if Achievement.UnlockTime > 0 then
            Dates.AddOrSetValue(Achievement.ID, Achievement.UnlockTime);
    end
    else
    begin
      var Achievement: TRAClientAchievement;
      if not FSession.TryGetAchievementInfo(AchievementId, Achievement) or
        (Achievement.UnlockTime <= 0) then
        Exit;
      Dates.AddOrSetValue(AchievementId, Achievement.UnlockTime);
    end;
    if Dates.Count = 0 then
      Exit;
    var Data := TJSONObject.Create;
    try
      for var Pair in Dates do
        Data.AddPair(UIntToStr(Pair.Key), TJSONNumber.Create(Pair.Value));
      WriteRAAchievementCache(Storage, RAUnlockDatesPath(Storage, FGameHash, FUserName, FConsoleId), Data);
    finally
      Data.Free;
    end;
  finally
    Dates.Free;
  end;
end;

function TRAConnection.TakeRuntimeEvents: TArray<TRARuntimeEvent>;
begin
  FLock.Acquire;
  try
    Result := FRuntimeEvents.ToArray;
    FRuntimeEvents.Clear;
  finally
    FLock.Release;
  end;
end;

function TRAConnection.TakeSubmissions: TArray<TRASubmission>;
begin
  FLock.Acquire;
  try
    Result := FSubmissions.ToArray;
    FSubmissions.Clear;
  finally
    FLock.Release;
  end;
end;

procedure TRAConnection.SetShareRichPresence(Value: Boolean);
begin
  FSession.SetShareRichPresence(Value);
end;

function TRAConnection.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const UserAgent: string; ShareRichPresence: Boolean): IRAConnection;
begin
  Result := TRAConnection.Create(Console, ROM, Credentials, UserAgent, ShareRichPresence);
end;

function OpenRAConnection(Console: TRARomConsole; const ROM: TBytes; const Credentials: TRACredentials; const Post: TRAPost): IRAConnection;
begin
  Result := TRAConnection.Create(Console, ROM, Credentials, Post);
end;

end.

