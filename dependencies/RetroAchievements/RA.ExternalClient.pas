unit RA.ExternalClient;

interface

{$SCOPEDENUMS ON}
{$POINTERMATH ON}

uses
  System.Generics.Collections, System.SyncObjs, System.SysUtils,
  RA.ExternalClient.ABI, RA.ExternalClient.Async, RA.GameData, RA.Info,
  RA.MediaHash, RA.Memory, RA.Protocol, RA.Runtime, RA.Session;

type
  TRAExternalClientSession = class(TRASession)
  private
    type
      TAccountSource = (Provider, Native, LoggedOut);
  private
    FTable: TRAExternalClientTable;
    FHasAvatarTimestamp: Boolean;
    FAccountSource: TAccountSource;
    FAccountEpoch: UInt64;
    FCallbacksInstalled, FProviderAllowsBackgroundReads: Boolean;
    FProviderLock, FEventLock: TCriticalSection;
    FEvents: TList<TRARuntimeEvent>;
    FConnectionEvents: TQueue<TRARuntimeEvent>;
    FAsyncRequests: TRAExternalAsyncRequests;
    FOffline, FResetRequested: Boolean;
    FExternalLog: TRAClientLog;
    FExternalLogLevel: TRAClientLogLevel;
    procedure InitializeExternal(Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string; HasAvatarTimestamp: Boolean);
    class procedure ReceiveEvent(Event: PRAExternalEvent; Client: Pointer); cdecl; static;
    class procedure ReceiveLog(Message: PAnsiChar; Client: Pointer); cdecl; static;
    class function ReceiveMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer): Cardinal; cdecl; static;
    class function ReceiveClock(Client: Pointer): UInt64; cdecl; static;
    class procedure ReceiveAsync(Code: Integer; Message: PAnsiChar; Client, Data: Pointer); cdecl; static;
    class procedure ReceiveIdentification(Code: Integer; Message: PAnsiChar; Client, Data: Pointer); cdecl; static;
    class procedure FinishCRequest(Code: Integer; Message: PAnsiChar; Client, Token: Pointer; CandidateUnrecognized: Boolean); static;
    class procedure ReceiveEntries(Code: Integer; Message: PAnsiChar; List: PRAExternalLeaderboardEntryList; Client, Data: Pointer); cdecl; static;
    function QueueLogin(StartLogin: TRAExternalBeginLogin; const UserName, Secret: string; TokenLogin: Boolean; const Completed: TRAClientLoginCompleted): IRALogin;
    function ReadProviderUser(out User: TRALoginInfo): Boolean;
    procedure UseNativeAccount;
    function GameLoadCallback(ConsoleID: Cardinal; const Hash: string; const Completed: TRAGameLoaded): TRAExternalRequestCompleted;
    function BeginHashLoad(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; HashRevision: UInt64; const Completed: TRAGameLoaded; const InitialHash: string = ''): IRAGameLoad;
    function ResolveExternalHash(const Hash: string; out GameID: Cardinal): TRAExternalAsyncResult;
    function RetryExternalHashAfterHostChange(HostRevision: UInt64; Context: Pointer): Boolean;
    function QueueExternalMediaChange(const InitialHash, Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Hasher: TRAMediaHasher; HashRevision: UInt64; const Completed: TRAMediaChanged): IRAMediaChange;
    procedure CompleteMediaChange(const Hash: string; const Data: TRAExternalAsyncResult; const Completed: TRAMediaChanged);
    function DescribeExternalMedia(const Hash: string; LoadedGameID: Cardinal): TRAMediaInfo;
    function QueueExternalEntries(ID: Cardinal; const Start: TRAExternalRequestStart; const Completed: TRALeaderboardEntriesReceived; Kind: TRAExternalRequestKind = TRAExternalRequestKind.Normal): IRALeaderboardEntriesRequest;
    procedure QueueEvent(const Event: TRARuntimeEvent);
    procedure ProcessProvider(const ReadMemory: TRAMemoryRead; RunFrame: Boolean);
    function DrainEvents: TArray<TRARuntimeEvent>;
    function ReadProviderFlag(GetFlag: TRAExternalBoolean): Boolean;
    procedure WriteProviderFlag(SetFlag: TRAExternalSetBoolean; Enabled: Boolean);
    function CopyProviderText(GetText: TRAExternalCopyText): string;
    function ReadGame: TRAGameData;
    function ReadLoadedGame(const RequestedHash: string): TRAGameData;
    function ImageURL(Kind: TRAImageKind; const Name: string; URL: PAnsiChar; Legacy: Boolean = False): string;
    function ConvertAchievement(Source: PRAExternalAchievementV1; Legacy: Boolean = True): TRAClientAchievement; overload;
    function ConvertAchievement(Source: PRAExternalAchievementV3): TRAClientAchievement; overload;
    function ConvertSubset(Source: PRAExternalSubsetV1): TRASubsetInfo; overload;
    function ConvertSubset(Source: PRAExternalSubsetV3): TRASubsetInfo; overload;
  protected
    function PumpNetworkCore(out Submission: TRASubmission): Boolean; override;
    procedure MemoryAccessChanged; override;
    function SynchronizeQueryAccount: Boolean; override;
    function GetGame: TRAGameData; override;
    function GetGameLoaded: Boolean; override;
    function GetGameLoadPhase: TRAGameLoadPhase; override;
    function GetGameLoadState: TRAGameLoadState; override;
    function GetCurrentMedia: TRAMediaInfo; override;
    function GetHardcoreEnabled: Boolean; override;
    function GetEncoreModeEnabled: Boolean; override;
    function GetUnofficialEnabled: Boolean; override;
    function GetSpectatorMode: TRASpectatorMode; override;
    function GetResetRequired: Boolean; override;
    function GetDisconnected: Boolean; override;
  public
    // The table must contain the advertised version's prefix. Its callbacks remain callable until Destroy.
    constructor Create(const Post: TRAPost; Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string = RAMediaHost; HasAvatarTimestamp: Boolean = False; const Clock: TRAClock = nil); reintroduce;
    constructor CreateHosted(const Post: TRAHostedPost; Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string = RAMediaHost; HasAvatarTimestamp: Boolean = False; const Clock: TRAClock = nil); reintroduce;
    destructor Destroy; override;
    function BeginLoginWithPassword(const UserName, Password: string; const Completed: TRAClientLoginCompleted = nil): IRALogin; override;
    function BeginLoginWithToken(const Credentials: TRACredentials; const Completed: TRAClientLoginCompleted = nil): IRALogin; override;
    function BeginLoadGame(const GameHash: string; ConsoleID: Cardinal; const Completed: TRAGameLoaded = nil): IRAGameLoad; override;
    function BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAGameLoaded = nil): IRAGameLoad; overload; override;
    function BeginChangeMedia(const GameHash: string; const Completed: TRAMediaChanged = nil): IRAMediaChange; override;
    function BeginIdentifyAndChangeMedia(const Path: string; const Hasher: TRAMediaHasher; const Completed: TRAMediaChanged = nil): IRAMediaChange; overload; override;
    function BeginIdentifyAndChangeMedia(const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAMediaChanged = nil): IRAMediaChange; overload; override;
    function BeginFetchLeaderboardEntries(ID, FirstEntry, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest; override;
    function BeginFetchLeaderboardEntriesAroundUser(ID, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest; override;
    procedure SetHost(const Host: string); override;
    function GetUserAgentClause: string; overload; override;
    function TryGetUserInfo(out User: TRALoginInfo): Boolean; override;
    function TryGetSubsetInfo(SubsetID: Cardinal; out Info: TRASubsetInfo): Boolean; override;
    function CreateSubsetList: TArray<TRASubsetInfo>; override;
    function GetUserGameSummary: TRAUserGameSummary; override;
    function GetUserSubsetSummary(SubsetID: Cardinal): TRAUserGameSummary; override;
    function TryGetAchievementInfo(ID: Cardinal; out Info: TRAClientAchievement): Boolean; override;
    function TryGetNextAchievementInfo(AfterID: Cardinal; Bucket: TRAAchievementBucketKind; out Info: TRAClientAchievement): Boolean; override;
    function HasAchievements: Boolean; override;
    function CreateAchievementList(Categories: TRAAchievementCategories; Grouping: TRAAchievementGrouping): TArray<TRAAchievementBucket>; override;
    function TryGetLeaderboardInfo(ID: Cardinal; out Info: TRAClientLeaderboard): Boolean; override;
    function HasLeaderboards: Boolean; override;
    function CreateLeaderboardList(Grouping: TRALeaderboardGrouping): TArray<TRALeaderboardBucket>; override;
    procedure SetHardcoreEnabled(Enabled: Boolean); override;
    procedure SetEncoreModeEnabled(Enabled: Boolean); override;
    procedure SetUnofficialEnabled(Enabled: Boolean); override;
    function SetSpectatorModeEnabled(Enabled: Boolean): Boolean; override;
    function CanPause(out FramesRemaining: Cardinal): Boolean; override;
    procedure EnableLogging(Level: TRAClientLogLevel; const Callback: TRAClientLog); override;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead = nil): TArray<TRARuntimeEvent>; override;
    procedure Idle(const ReadMemory: TRAMemoryRead = nil); override;
    function PollIndicatorEvents: TArray<TRARuntimeEvent>; override;
    function TryPollConnectionEvent(out Event: TRARuntimeEvent): Boolean; override;
    function IsProcessingRequired: Boolean; override;
    function HasRichPresence: Boolean; override;
    function GetRichPresenceMessage: string; overload; override;
    function GetRichPresenceMessage(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload; override;
    function ProgressSize: NativeUInt; override;
    function SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer; override;
    function DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer; override;
    function CaptureProgress: TBytes; override;
    function RestoreProgress(const Data: TBytes): Boolean; override;
    procedure AddGameHash(const Hash: string; GameID: Cardinal); override;
    procedure LoadUnknownGame(const TriedHashes: string; ConsoleID: Cardinal = 0); override;
    procedure Logout; override;
    procedure UnloadGame; override;
    procedure Reset; override;
  end;

implementation

uses
  System.JSON, RA.ExternalClient.Events, RA.Utils;

type
  PRAExternalMemoryFrame = ^TRAExternalMemoryFrame;

  TRAExternalMemoryFrame = record
    Session: TRAExternalClientSession;
    Reader: TRAMemoryRead;
  end;

threadvar
  ExternalMemoryFrame: PRAExternalMemoryFrame;

const
  RAExternalUnhashableMedia = '[NO HASH]';
  RABadgeFallback = '00000';
  HostChangedMessage = 'RetroAchievements server changed during request';

function ConvertBucket(Value: Byte): TRAAchievementBucketKind;
begin
  Result := TRAAchievementBucketKind.Unknown;
  if Value <= Byte(High(TRAAchievementBucketKind)) then
    Result := TRAAchievementBucketKind(Value);
end;

function ConvertSummary(const Source: TRAExternalUserGameSummaryV5): TRAUserGameSummary;
begin
  Result.CoreAchievements := Source.Data.CoreAchievements;
  Result.UnofficialAchievements := Source.Data.UnofficialAchievements;
  Result.UnlockedAchievements := Source.Data.UnlockedAchievements;
  Result.UnsupportedAchievements := Source.Data.UnsupportedAchievements;
  Result.CorePoints := Source.Data.CorePoints;
  Result.UnlockedPoints := Source.Data.UnlockedPoints;
  Result.BeatenTime := Source.BeatenTime;
  Result.CompletedTime := Source.CompletedTime;
end;

function ConvertLeaderboard(Source: PRAExternalLeaderboard): TRAClientLeaderboard;
begin
  Result := Default(TRAClientLeaderboard);
  if Source = nil then
    Exit;
  Result.ID := Source.ID;
  Result.Title := ReadExternalText(Source.Title);
  Result.Description := ReadExternalText(Source.Description);
  Result.TrackerValue := ReadExternalText(Source.TrackerValue);
  if Source.State <= Byte(High(TRAClientLeaderboardState)) then
    Result.State := TRAClientLeaderboardState(Source.State);
  if Source.Format <= Byte(High(TRAClientLeaderboardFormat)) then
    Result.Format := TRAClientLeaderboardFormat(Source.Format);
  Result.LowerIsBetter := Source.LowerIsBetter <> 0;
end;

constructor TRAExternalClientSession.Create(const Post: TRAPost; Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string; HasAvatarTimestamp: Boolean; const Clock: TRAClock);
begin
  inherited Create(Post, Default(TRACredentials), False, Clock);
  InitializeExternal(Table, Version, ImageHost, HasAvatarTimestamp);
end;

constructor TRAExternalClientSession.CreateHosted(const Post: TRAHostedPost; Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string; HasAvatarTimestamp: Boolean; const Clock: TRAClock);
begin
  inherited CreateHosted(Post, Default(TRACredentials), False, Clock);
  InitializeExternal(Table, Version, ImageHost, HasAvatarTimestamp);
end;

procedure TRAExternalClientSession.InitializeExternal(Table: PRAExternalClientTable; Version: Cardinal; const ImageHost: string; HasAvatarTimestamp: Boolean);
var
  Size: NativeUInt;
begin
  Size := RAExternalClientTableSize(Version);
  if (Table = nil) or (Size = 0) then
    raise EArgumentException.Create('Unsupported RetroAchievements external client table');
  Move(Table^, FTable, Size);
  if not SameText(ImageHost, RAMediaHost) then
    SetImageHost(ImageHost);
  FHasAvatarTimestamp := HasAvatarTimestamp;
  FProviderLock := TCriticalSection.Create;
  FEventLock := TCriticalSection.Create;
  FEvents := TList<TRARuntimeEvent>.Create;
  FConnectionEvents := TQueue<TRARuntimeEvent>.Create;
  FAsyncRequests := TRAExternalAsyncRequests.Create(Self, FTable.AbortAsync);
  FCallbacksInstalled := True;
  if Assigned(FTable.SetAllowBackgroundMemoryReads) then
    FTable.SetAllowBackgroundMemoryReads(0);
  if Assigned(FTable.SetReadMemory) then
    FTable.SetReadMemory(Self, ReceiveMemory);
  if Assigned(FTable.SetGetTimeMillisecs) then
    FTable.SetGetTimeMillisecs(Self, ReceiveClock);
  if Assigned(FTable.SetEventHandler) then
    FTable.SetEventHandler(Self, ReceiveEvent);
end;

destructor TRAExternalClientSession.Destroy;
begin
  try
    try
      if FAsyncRequests <> nil then
        FAsyncRequests.Close;
      if FCallbacksInstalled then
      begin
        if Assigned(FTable.EnableLogging) then
          FTable.EnableLogging(Self, 0, nil);
        if Assigned(FTable.SetEventHandler) then
          FTable.SetEventHandler(Self, nil);
        if Assigned(FTable.SetReadMemory) then
          FTable.SetReadMemory(Self, nil);
        if Assigned(FTable.SetGetTimeMillisecs) then
          FTable.SetGetTimeMillisecs(Self, nil);
      end;
    finally
      if Assigned(FTable.Destroy) then
        FTable.Destroy;
    end;
  finally
    FAsyncRequests.Free;
    FConnectionEvents.Free;
    FEvents.Free;
    FEventLock.Free;
    FProviderLock.Free;
    inherited;
  end;
end;

class procedure TRAExternalClientSession.ReceiveEvent(Event: PRAExternalEvent; Client: Pointer);
var
  Converted: TRARuntimeEvent;
begin
  try
    if (Client <> nil) and TryConvertExternalEvent(Event, Converted) then
      TRAExternalClientSession(Client).QueueEvent(Converted);
  except
    on Exception do
      Exit;
  end;
end;

class procedure TRAExternalClientSession.ReceiveLog(Message: PAnsiChar; Client: Pointer);
var
  Session: TRAExternalClientSession;
  Callback: TRAClientLog;
  Level: TRAClientLogLevel;
begin
  if (Client = nil) or (Message = nil) then
    Exit;
  try
    Session := TRAExternalClientSession(Client);
    Session.FEventLock.Acquire;
    try
      Callback := Session.FExternalLog;
      Level := Session.FExternalLogLevel;
    finally
      Session.FEventLock.Release;
    end;
    if Assigned(Callback) then
      Callback(Level, ReadExternalText(Message));
  except
    on Exception do
      Exit;
  end;
end;

class function TRAExternalClientSession.ReceiveMemory(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer): Cardinal;
var
  Frame: PRAExternalMemoryFrame;
  Reader: TRAMemoryRead;
begin
  if (Client = nil) or (Buffer = nil) or (Count = 0) then
    Exit(0);

  try
    Frame := ExternalMemoryFrame;
    if (Frame <> nil) and (Pointer(Frame.Session) = Client) then
      Reader := Frame.Reader
    else
      Reader := TRAExternalClientSession(Client).GetMemoryReader(True);
    if not Assigned(Reader) then
      Exit(0);
    Result := Reader(Address, Buffer, Count);
    if Result > Count then
      Result := Count;
  except
    on Exception do
      Result := 0;
  end;
end;

class function TRAExternalClientSession.ReceiveClock(Client: Pointer): UInt64;
begin
  Result := 0;
  try
    if Client <> nil then
      Result := TRAExternalClientSession(Client).NowMilliseconds;
  except
    on Exception do
      Result := 0;
  end;
end;

procedure TRAExternalClientSession.QueueEvent(const Event: TRARuntimeEvent);
var
  Offline: Boolean;
begin
  FEventLock.Acquire;
  try
    case Event.Kind of
      TRARuntimeEventKind.Disconnected, TRARuntimeEventKind.Reconnected:
        begin
          Offline := Event.Kind = TRARuntimeEventKind.Disconnected;
          if FOffline <> Offline then
          begin
            FOffline := Offline;
            FConnectionEvents.Enqueue(Event);
            QueueClientEvent(Event);
          end;
          Exit;
        end;
      TRARuntimeEventKind.ResetRequested:
        FResetRequested := True;
    end;
    FEvents.Add(Event);
    QueueClientEvent(Event);
  finally
    FEventLock.Release;
  end;
end;

function TRAExternalClientSession.DrainEvents: TArray<TRARuntimeEvent>;
begin
  FEventLock.Acquire;
  try
    Result := FEvents.ToArray;
    FEvents.Clear;
  finally
    FEventLock.Release;
  end;
end;

procedure TRAExternalClientSession.EnableLogging(Level: TRAClientLogLevel; const Callback: TRAClientLog);
var
  Previous: TRAClientLog;
begin
  inherited;
  if not Assigned(FTable.EnableLogging) then
    Exit;
  FEventLock.Acquire;
  try
    Previous := FExternalLog;
    FExternalLog := nil;
    FExternalLogLevel := TRAClientLogLevel.None;
    if (Level <> TRAClientLogLevel.None) and Assigned(Callback) then
    begin
      FExternalLog := Callback;
      FExternalLogLevel := Level;
    end;
  finally
    FEventLock.Release;
  end;
  Previous := nil;
  FProviderLock.Acquire;
  try
    if (Level <> TRAClientLogLevel.None) and Assigned(Callback) then
      FTable.EnableLogging(Self, Ord(Level), ReceiveLog)
    else
      FTable.EnableLogging(Self, 0, nil);
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.MemoryAccessChanged;
var
  Reader: TRAMemoryRead;
  Allowed: Boolean;
begin
  if not Assigned(FTable.SetAllowBackgroundMemoryReads) or not Assigned(FTable.SetReadMemory) then
    Exit;

  FProviderLock.Acquire;
  try
    Reader := GetMemoryReader(True);
    Allowed := Assigned(Reader);
    if Allowed <> FProviderAllowsBackgroundReads then
    begin
      FTable.SetAllowBackgroundMemoryReads(Ord(Allowed));
      FProviderAllowsBackgroundReads := Allowed;
    end;
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.ProcessProvider(const ReadMemory: TRAMemoryRead; RunFrame: Boolean);
var
  Frame: TRAExternalMemoryFrame;
  Previous: PRAExternalMemoryFrame;
begin
  Frame.Session := Self;
  Frame.Reader := FrameMemoryReader(ReadMemory);
  Previous := ExternalMemoryFrame;
  ExternalMemoryFrame := @Frame;
  try
    if RunFrame then
      FTable.DoFrame();
    if Assigned(FTable.Idle) and
      (not RunFrame or (MemoryReadsRequireEmulationThread and FAsyncRequests.HasRunningLoad)) then
      FTable.Idle();
  finally
    ExternalMemoryFrame := Previous;
  end;
end;

function TRAExternalClientSession.EvaluateFrame(const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
begin
  FProviderLock.Acquire;
  try
    if Assigned(FTable.DoFrame) then
      ProcessProvider(ReadMemory, True)
    else if Assigned(FTable.Idle) and MemoryReadsRequireEmulationThread and FAsyncRequests.HasRunningLoad then
      ProcessProvider(ReadMemory, False);
    Result := DrainEvents;
  finally
    FProviderLock.Release;
  end;
  if Assigned(FTable.DoFrame) then
    DispatchClientEvents
  else
    Result := inherited EvaluateFrame(ReadMemory) + Result;
end;

procedure TRAExternalClientSession.Idle(const ReadMemory: TRAMemoryRead);
begin
  FProviderLock.Acquire;
  try
    if Assigned(FTable.Idle) then
      ProcessProvider(ReadMemory, False);
  finally
    FProviderLock.Release;
  end;
  inherited Idle(ReadMemory);
end;

function TRAExternalClientSession.PumpNetworkCore(out Submission: TRASubmission): Boolean;
begin
  FProviderLock.Acquire;
  try
    FAsyncRequests.PumpProvider;
    if Assigned(FTable.Idle) and not MemoryReadsRequireEmulationThread then
      FTable.Idle();
  finally
    FProviderLock.Release;
  end;
  FAsyncRequests.Deliver;
  Result := inherited PumpNetworkCore(Submission);
end;

function TRAExternalClientSession.PollIndicatorEvents: TArray<TRARuntimeEvent>;
begin
  FProviderLock.Acquire;
  try
    Result := TakeNativeIndicatorEvents + DrainEvents;
  finally
    FProviderLock.Release;
  end;
  DispatchClientEvents;
end;

function TRAExternalClientSession.TryPollConnectionEvent(out Event: TRARuntimeEvent): Boolean;
begin
  try
    FEventLock.Acquire;
    try
      if FConnectionEvents.Count <> 0 then
      begin
        Event := FConnectionEvents.Dequeue;
        Exit(True);
      end;
    finally
      FEventLock.Release;
    end;
    Result := inherited TryPollConnectionEvent(Event);
  finally
    DispatchClientEvents;
  end;
end;

function TRAExternalClientSession.GetDisconnected: Boolean;
begin
  FEventLock.Acquire;
  try
    if FOffline then
      Exit(True);
  finally
    FEventLock.Release;
  end;
  Result := inherited GetDisconnected;
end;

function TRAExternalClientSession.GetResetRequired: Boolean;
begin
  FEventLock.Acquire;
  try
    if FResetRequested then
      Exit(True);
  finally
    FEventLock.Release;
  end;
  Result := inherited GetResetRequired;
end;

function TRAExternalClientSession.ImageURL(Kind: TRAImageKind; const Name: string; URL: PAnsiChar; Legacy: Boolean): string;
const
  LegacyBadgeBytes = 63;
  LegacyAvatarBytes = 79;
begin
  Result := ReadExternalText(URL);
  if (URL <> nil) or (Name = '') then
    Exit;
  Result := BuildRAImageURL(Kind, Name, GetImageHost);
  if Legacy then
    if Kind = TRAImageKind.User then
      Result := TruncateRAUTF8(Result, LegacyAvatarBytes)
    else
      Result := TruncateRAUTF8(Result, LegacyBadgeBytes);
end;

procedure TRAExternalClientSession.SetHost(const Host: string);
var
  HostText: UTF8String;
begin
  FProviderLock.Acquire;
  try
    inherited;
    if Assigned(FTable.SetHost) then
    begin
      HostText := UTF8String(GetHost);
      FTable.SetHost(PAnsiChar(HostText));
    end;
  finally
    FProviderLock.Release;
  end;
end;

class procedure TRAExternalClientSession.FinishCRequest(Code: Integer; Message: PAnsiChar; Client, Token: Pointer; CandidateUnrecognized: Boolean);
var
  Data: TRAExternalAsyncResult;
begin
  try
    if Client = nil then
      Exit;
    Data := ExternalRequestResult(Code, ReadExternalText(Message));
    Data.CandidateUnrecognized := CandidateUnrecognized;
    TRAExternalClientSession(Client).FAsyncRequests.Finish(Token, Data);
  except
    on Exception do
      Exit;
  end;
end;

class procedure TRAExternalClientSession.ReceiveAsync(Code: Integer; Message: PAnsiChar; Client, Data: Pointer);
begin
  FinishCRequest(Code, Message, Client, Data, False);
end;

class procedure TRAExternalClientSession.ReceiveIdentification(Code: Integer; Message: PAnsiChar; Client, Data: Pointer);
begin
  FinishCRequest(Code, Message, Client, Data, (Code = RAExternalNoGameLoaded) or (Code = RAExternalNotFound));
end;

class procedure TRAExternalClientSession.ReceiveEntries(Code: Integer; Message: PAnsiChar; List: PRAExternalLeaderboardEntryList; Client, Data: Pointer);
var
  Response: TRAExternalAsyncResult;
begin
  try
    try
      if Client = nil then
        Exit;
      Response := ExternalRequestResult(Code, ReadExternalText(Message));
      if Code = RAExternalOK then
      try
        CopyExternalLeaderboardEntries(List, Response);
      except
        on Error: Exception do
          Response := ExternalRequestResult(RAExternalInvalidState, Error.Message);
      end;
      TRAExternalClientSession(Client).FAsyncRequests.Finish(Data, Response);
    finally
      if (List <> nil) and Assigned(List.Destroy) then
        List.Destroy(List);
    end;
  except
    on Exception do
      Exit;
  end;
end;

procedure RequireExternalText(const Value, Name: string);
begin
  if (Value = '') or (Pos(#0, Value) <> 0) then
    raise EArgumentException.CreateFmt('Invalid RetroAchievements %s', [Name]);
end;

procedure RequireExternalMedia(const Path: string; const Data: TBytes);
begin
  if ((Path = '') and (Length(Data) = 0)) or (Pos(#0, Path) <> 0) then
    raise EArgumentException.Create('A RetroAchievements media path or buffer is required');
end;

function TRAExternalClientSession.QueueLogin(StartLogin: TRAExternalBeginLogin; const UserName, Secret: string; TokenLogin: Boolean; const Completed: TRAClientLoginCompleted): IRALogin;
var
  UserText, SecretText: UTF8String;
  AccountEpoch, HostRevision: UInt64;
begin
  RequireExternalText(UserName, 'user name');
  RequireExternalText(Secret, 'credentials');
  UserText := UTF8String(UserName);
  SecretText := UTF8String(Secret);
  FProviderLock.Acquire;
  try
    AccountEpoch := FAccountEpoch;
    HostRevision := GetHostRevision;
    Result := FAsyncRequests.Enqueue(
      function(Client, Context: Pointer): Pointer
      begin
        if HostRevision <> GetHostRevision then
        begin
          FAsyncRequests.Finish(Context, ExternalRequestResult(RAExternalAborted, HostChangedMessage));
          Exit(nil);
        end;
        Result := StartLogin(Client, PAnsiChar(UserText), PAnsiChar(SecretText), ReceiveAsync, Context);
      end,
      procedure(const Data: TRAExternalAsyncResult)
      var
        Login: TRAClientLoginResult;
      begin
        Login := Default(TRAClientLoginResult);
        Login.Status := ExternalRequestStatus(Data);
        FProviderLock.Acquire;
        try
          if AccountEpoch <> FAccountEpoch then
            Exit;
          if HostRevision <> GetHostRevision then
          begin
            if Login.Status.Success and (FAccountSource = TAccountSource.Provider) then
            begin
              // The provider may already have installed the obsolete credentials internally.
              FAccountSource := TAccountSource.LoggedOut;
              UpdateQueryAccount(Default(TRALoginInfo));
              FAsyncRequests.CancelRequests([TRAExternalRequestKind.AccountQuery]);
            end;
            Login.Status := ExternalRequestStatus(ExternalRequestResult(RAExternalAborted, HostChangedMessage));
          end
          else if Login.Status.Success then
          begin
            FAccountSource := TAccountSource.Provider;
            if Assigned(FTable.GetUserInfo) or Assigned(FTable.GetUserInfoV3) then
              ReadProviderUser(Login.User)
            else if TokenLogin then
            begin
              Login.User.Credentials.UserName := UserName;
              Login.User.Credentials.Token := Secret;
              Login.User.DisplayName := UserName;
              Login.User.AvatarURL := ImageURL(TRAImageKind.User, UserName, nil);
            end;
            if UpdateQueryAccount(Login.User) then
              FAsyncRequests.CancelRequests([TRAExternalRequestKind.AccountQuery]);
          end;
        finally
          FProviderLock.Release;
        end;
        if Assigned(Completed) then
          Completed(Login);
      end, TRAGameLoadPhase.Idle, False, TRAExternalRequestKind.Login);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.BeginLoginWithPassword(const UserName, Password: string; const Completed: TRAClientLoginCompleted): IRALogin;
begin
  if Assigned(FTable.BeginLoginWithPassword) then
    Exit(QueueLogin(FTable.BeginLoginWithPassword, UserName, Password, False, Completed));
  Result := inherited BeginLoginWithPassword(UserName, Password, Completed);
  UseNativeAccount;
end;

function TRAExternalClientSession.BeginLoginWithToken(const Credentials: TRACredentials; const Completed: TRAClientLoginCompleted): IRALogin;
begin
  if Assigned(FTable.BeginLoginWithToken) then
    Exit(QueueLogin(FTable.BeginLoginWithToken, Credentials.UserName, Credentials.Token, True, Completed));
  Result := inherited BeginLoginWithToken(Credentials, Completed);
  UseNativeAccount;
end;

function TRAExternalClientSession.GameLoadCallback(ConsoleID: Cardinal; const Hash: string; const Completed: TRAGameLoaded): TRAExternalRequestCompleted;
begin
  Result :=
    procedure(const Data: TRAExternalAsyncResult)
    var
      Load: TRAGameLoadResult;
      Status: TRAQueryStatus;
    begin
      Load := Default(TRAGameLoadResult);
      Status := ExternalRequestStatus(Data);
      Load.Success := Status.Success;
      Load.ErrorMessage := Status.ErrorMessage;
      Load.ServerCode := Status.ServerCode;
      Load.HTTPStatus := Status.HTTPStatus;
      Load.ResultCode := Status.ResultCode;
      Load.GameHash := Hash;
      Load.HashConsoleID := ConsoleID;
      if Load.Success then
        Load.Game := ReadLoadedGame(Hash)
      else if (Data.Code = RAExternalNoGameLoaded) or (Data.Code = RAExternalNotFound) then
      begin
        Load.Game := GetGame;
        if (Hash <> '') and
          ((Load.Game.ID <> 0) or (Load.Game.Title = '') or not SameText(Load.Game.Hash, Hash)) then
        begin
          LoadUnknownGame(Hash, ConsoleID);
          Load.Game := GetGame;
        end;
        if Load.Game.ID <> 0 then
          Load.Game := Default(TRAGameData);
      end;
      if Load.Game.Hash <> '' then
        Load.GameHash := Load.Game.Hash;
      if Load.Game.ConsoleID <> 0 then
        Load.HashConsoleID := Load.Game.ConsoleID;
      if Load.GameHash <> '' then
        Load.TriedHashes := Load.GameHash.Split([',']);
      if Assigned(Completed) then
        Completed(Load);
    end;
end;

function TRAExternalClientSession.BeginLoadGame(const GameHash: string; ConsoleID: Cardinal; const Completed: TRAGameLoaded): IRAGameLoad;
var
  Hash: UTF8String;
begin
  if not Assigned(FTable.BeginLoadGame) then
    Exit(inherited BeginLoadGame(GameHash, ConsoleID, Completed));
  RequireExternalText(GameHash, 'game hash');
  if Assigned(FTable.AddGameHash) then
    Exit(BeginHashLoad(ConsoleID, '', nil, Default(TRAMediaHashOptions), 0, Completed, GameHash));
  Hash := UTF8String(GameHash);
  Result := FAsyncRequests.Enqueue(
    function(Client, Context: Pointer): Pointer
    begin
      Result := FTable.BeginLoadGame(Client, PAnsiChar(Hash), ReceiveAsync, Context);
    end,
        GameLoadCallback(ConsoleID, GameHash, Completed), TRAGameLoadPhase.FetchingGame);
end;

function TRAExternalClientSession.BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAGameLoaded): IRAGameLoad;
var
  OwnedData: TBytes;
  PathText: UTF8String;
  EffectiveOptions: TRAMediaHashOptions;
  HashRevision: UInt64;
begin
  EffectiveOptions := ResolveHashCallbacks(Options, HashRevision);
  if Assigned(FTable.BeginIdentifyAndLoadGame) and
    (not Assigned(FTable.BeginLoadGame) or (not Assigned(FTable.AddGameHash) and not EffectiveOptions.HasCallbacks)) then
  begin
    RequireExternalMedia(Path, Data);
    OwnedData := Copy(Data);
    PathText := UTF8String(Path);
    Exit(FAsyncRequests.Enqueue(
      function(Client, Context: Pointer): Pointer
      begin
        Result := FTable.BeginIdentifyAndLoadGame(Client, ConsoleID, Pointer(PathText), PByte(OwnedData), Length(OwnedData),
          ReceiveAsync, Context);
      end,
          GameLoadCallback(ConsoleID, '', Completed), TRAGameLoadPhase.IdentifyingGame));
  end;
  if Assigned(FTable.BeginLoadGame) then
    Exit(BeginHashLoad(ConsoleID, Path, Data, EffectiveOptions, HashRevision, Completed));
  Result := inherited BeginIdentifyAndLoadGame(ConsoleID, Path, Data, Options, Completed);
end;

function TRAExternalClientSession.ResolveExternalHash(const Hash: string; out GameID: Cardinal): TRAExternalAsyncResult;
var
  Response: TJSONObject;
  HostRevision: UInt64;
begin
  GameID := 0;
  HostRevision := GetHostRevision;
  Result := ExternalRequestResult(RAExternalOK, '');
  try
    Response := PostRequest(TRARequest.ResolveHash(Hash), GetHost);
    try
      GameID := ReadRAGameID(Response);
    finally
      Response.Free;
    end;
    Result.CandidateUnrecognized := GameID = 0;
  except
    on Error: ERAServerError do
    begin
      Result := ExternalRequestResult(Error.ResultCode, Error.Message);
      Result.HTTPStatus := Error.StatusCode;
      Result.ServerCode := Error.Code;
      Result.CandidateUnrecognized := Result.Code = RAExternalNotFound;
    end;
    on Error: Exception do
      Result := ExternalRequestResult(RequestErrorResultCode(Error), Error.Message);
  end;

  // The hosted transport may call SetHost on this worker before returning.
  if HostRevision <> GetHostRevision then
  begin
    GameID := 0;
    Result := ExternalRequestResult(RAExternalAborted, 'RetroAchievements server changed during media lookup');
  end;
end;

function TRAExternalClientSession.RetryExternalHashAfterHostChange(HostRevision: UInt64; Context: Pointer): Boolean;
var
  Data: TRAExternalAsyncResult;
begin
  Result := HostRevision <> GetHostRevision;
  if Result then
  begin
    Data := ExternalRequestResult(RAExternalAborted, HostChangedMessage);
    Data.CandidateUnrecognized := True;
    FAsyncRequests.Finish(Context, Data);
  end;
end;

function TRAExternalClientSession.BeginHashLoad(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; HashRevision: UInt64; const Completed: TRAGameLoaded; const InitialHash: string): IRAGameLoad;
var
  OwnedData: TBytes;
  Iterator: IRAMediaHashIterator;
  Cursor: Integer;
  Candidate: TRAMediaHashCandidate;
  LastConsoleID: Cardinal;
  HostRevision: UInt64;
  TriedHashes: TArray<string>;
  Hash: UTF8String;
  Exhausted: Boolean;
  Phase: TRAGameLoadPhase;
  CompleteDirect: TRAExternalRequestCompleted;
begin
  if InitialHash = '' then
  begin
    RequireExternalMedia(Path, Data);
    Phase := TRAGameLoadPhase.IdentifyingGame;
  end
  else
  begin
    Phase := TRAGameLoadPhase.FetchingGame;
    CompleteDirect := GameLoadCallback(ConsoleID, InitialHash, Completed);
  end;
  OwnedData := Copy(Data);
  Cursor := 0;
  LastConsoleID := ConsoleID;
  Exhausted := False;
  HostRevision := GetHostRevision;
  Result := FAsyncRequests.Enqueue(
    function(Client, Context: Pointer): Pointer
    var
      Resolution: TRAExternalAsyncResult;
      GameID, RegisteredID: Cardinal;
      HasCandidate: Boolean;
    begin
      Result := nil;
      var CurrentRevision := GetHostRevision;
      if HostRevision <> CurrentRevision then
      begin
        // Rejections from the previous server do not apply to this search.
        HostRevision := CurrentRevision;
        Iterator := nil;
        Cursor := 0;
        LastConsoleID := ConsoleID;
        TriedHashes := nil;
      end;
      if InitialHash = '' then
      begin
        if Iterator = nil then
          Iterator := CreateRAMediaHashIterator(ConsoleID, Path, OwnedData, HashCallbacksWithLogging(Options));
        HasCandidate := TryNextUniqueRAMediaHash(Iterator, Cursor, TriedHashes, Candidate);
      end
      else
      begin
        HasCandidate := Length(TriedHashes) = 0;
        Candidate.Hash := InitialHash;
        Candidate.ConsoleID := ConsoleID;
      end;
      if FAsyncRequests.IsCanceled(Context) or RetryExternalHashAfterHostChange(HostRevision, Context) then
        Exit;

      if not HasCandidate then
      begin
        GameID := 0;
        if Assigned(FTable.AddGameHash) and (Length(TriedHashes) = 1) then
          GameID := IdentifyUnknownHash(LastConsoleID, TriedHashes[0]);
        if FAsyncRequests.IsCanceled(Context) or RetryExternalHashAfterHostChange(HostRevision, Context) then
          Exit;
        Exhausted := GameID = 0;
        if Exhausted and (Assigned(FTable.LoadUnknownGame) or not Assigned(FTable.AddGameHash) or
          (Length(TriedHashes) = 0)) then
        begin
          FAsyncRequests.Finish(Context, ExternalRequestResult(RAExternalNoGameLoaded, ''));
          Exit;
        end;
        AddGameHash(TriedHashes[High(TriedHashes)], GameID);
      end
      else
      begin
        LastConsoleID := Candidate.ConsoleID;
        TriedHashes := TriedHashes + [Candidate.Hash];
        Hash := UTF8String(Candidate.Hash);
        if not Assigned(FTable.AddGameHash) then
          Exit(FTable.BeginLoadGame(Client, PAnsiChar(Hash), ReceiveIdentification, Context));

        if not TryGetMediaGameID(Candidate.Hash, GameID) then
        begin
          Resolution := ResolveExternalHash(Candidate.Hash, GameID);
          if FAsyncRequests.IsCanceled(Context) then
            Exit;
          if (Resolution.Code <> RAExternalOK) and not Resolution.CandidateUnrecognized then
          begin
            FAsyncRequests.Finish(Context, Resolution);
            Exit;
          end;
          // Registration may have happened inside the hosted transport.
          if TryGetMediaGameID(Candidate.Hash, RegisteredID) then
            GameID := RegisteredID
          else if GameID = 0 then
            inherited AddGameHash(Candidate.Hash, 0)
          else
            AddGameHash(Candidate.Hash, GameID);
        end;
        if GameID = 0 then
        begin
          Resolution := ExternalRequestResult(RAExternalNotFound, '');
          Resolution.CandidateUnrecognized := True;
          FAsyncRequests.Finish(Context, Resolution);
          Exit;
        end;
      end;
      if not FAsyncRequests.IsCanceled(Context) then
        Result := FTable.BeginLoadGame(Client, PAnsiChar(Hash), ReceiveAsync, Context);
    end,
    procedure(const Data: TRAExternalAsyncResult)
    var
      Load: TRAGameLoadResult;
      Status: TRAQueryStatus;
      PlaceholderConsoleID: Cardinal;

    begin
      if Assigned(CompleteDirect) and not Exhausted then
      begin
        CompleteDirect(Data);
        Exit;
      end;

      Load := Default(TRAGameLoadResult);
      Load.HashConsoleID := LastConsoleID;
      Load.TriedHashes := TriedHashes;
      if Length(TriedHashes) <> 0 then
        Load.GameHash := TriedHashes[High(TriedHashes)];

      if Exhausted and ((Data.Code = RAExternalNoGameLoaded) or (Data.Code = RAExternalNotFound)) then
      begin
        if Length(TriedHashes) = 0 then
        begin
          Load.ResultCode := RAExternalInvalidState;
          Load.ServerCode := 'hash_failed';
          Load.ErrorMessage := 'RetroAchievements could not generate a hash for this media';
        end
        else
        begin
          PlaceholderConsoleID := 0;
          if Length(TriedHashes) = 1 then
            PlaceholderConsoleID := LastConsoleID;
          LoadUnknownGame(string.Join(',', TriedHashes), PlaceholderConsoleID);
          Load.Game := GetGame;
          Load.ResultCode := RAExternalNoGameLoaded;
          Load.ServerCode := 'unknown_game';
          Load.ErrorMessage := 'RetroAchievements did not recognize any hash for this media';
        end;
      end
      else
      begin
        Status := ExternalRequestStatus(Data);
        Load.Success := Status.Success;
        Load.ErrorMessage := Status.ErrorMessage;
        Load.ServerCode := Status.ServerCode;
        Load.HTTPStatus := Status.HTTPStatus;
        Load.ResultCode := Status.ResultCode;
        if Load.Success then
        begin
          Load.Game := ReadLoadedGame(Load.GameHash);
          if (Path <> '') and (OwnedData = nil) and (Load.Game.ID <> 0) then
            CacheMediaPathHash(Path, Load.GameHash, HashRevision, Options, nil, True);
        end;
      end;
      if Assigned(Completed) then
        Completed(Load);
    end, Phase, True);
end;

function TRAExternalClientSession.GetGameLoadPhase: TRAGameLoadPhase;
begin
  Result := FAsyncRequests.GetLoadPhase;
  if Result = TRAGameLoadPhase.Idle then
    Result := inherited GetGameLoadPhase;
end;

function TRAExternalClientSession.GetGameLoadState: TRAGameLoadState;
var
  Phase: TRAGameLoadPhase;
  Game: TRAGameData;
begin
  Phase := GetGameLoadPhase;
  if Phase <> TRAGameLoadPhase.Idle then
    Exit(DescribeGameLoadState(Phase, False));

  FProviderLock.Acquire;
  try
    Game := ReadGame;
    Result := DescribeGameLoadState(Phase, (Game.ID <> 0) or (Game.Title <> '') or (Game.Hash <> ''));
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.CompleteMediaChange(const Hash: string; const Data: TRAExternalAsyncResult; const Completed: TRAMediaChanged);
var
  Change: TRAMediaChangeResult;
  Status: TRAQueryStatus;
  LoadedGame: TRAGameData;
  MediaHash: string;
begin
  Change := Default(TRAMediaChangeResult);
  Status := ExternalRequestStatus(Data);
  Change.ErrorMessage := Status.ErrorMessage;
  Change.ServerCode := Status.ServerCode;
  Change.HTTPStatus := Status.HTTPStatus;
  Change.ResultCode := Status.ResultCode;
  case Data.Code of
    RAExternalOK:
      Change.State := TRAMediaChangeState.Changed;
    RAExternalNoGameLoaded:
      Change.State := TRAMediaChangeState.NoGameLoaded;
    RAExternalAborted:
      Change.State := TRAMediaChangeState.Aborted;
    RAExternalHardcoreDisabled:
      Change.State := TRAMediaChangeState.HardcoreDisabled;
  else
    Change.State := TRAMediaChangeState.Failed;
  end;
  if Change.State in [TRAMediaChangeState.Changed, TRAMediaChangeState.HardcoreDisabled] then
  begin
    FProviderLock.Acquire;
    try
      LoadedGame := ReadGame;
      MediaHash := LoadedGame.Hash;
      if (Hash <> '') and not SameText(Hash, MediaHash) then
        MediaHash := Hash;
      if (Change.State = TRAMediaChangeState.HardcoreDisabled) and (MediaHash <> '') then
        inherited AddGameHash(MediaHash, 0);
      Change.Media := DescribeExternalMedia(MediaHash, LoadedGame.ID);
    finally
      FProviderLock.Release;
    end;
  end;
  if Assigned(Completed) then
    Completed(Change);
end;

function TRAExternalClientSession.QueueExternalMediaChange(const InitialHash, Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Hasher: TRAMediaHasher; HashRevision: UInt64; const Completed: TRAMediaChanged): IRAMediaChange;
var
  Digest: string;
  HashText: UTF8String;
begin
  Digest := InitialHash;
  Result := FAsyncRequests.Enqueue(
    function(Client, Context: Pointer): Pointer
    var
      LoadedGame: TRAGameData;
      GameID, ResolvedID: Cardinal;
      Resolution: TRAExternalAsyncResult;
      IdentifyMedia, CachePath, HasHash: Boolean;
    begin
      Result := nil;
      IdentifyMedia := InitialHash = '';
      if IdentifyMedia or Assigned(FTable.AddGameHash) then
        LoadedGame := GetGame;
      if IdentifyMedia then
      begin
        if LoadedGame.ID = 0 then
        begin
          ReceiveAsync(RAExternalNoGameLoaded, 'No game loaded', Client, Context);
          Exit;
        end;
        CachePath := (Path <> '') and (Data = nil);
        if not CachePath or not TryGetMediaPathHash(Path, HashRevision, Options, Hasher, Digest) then
        begin
          if Assigned(Hasher) then
            HasHash := Hasher(LoadedGame.ConsoleID, Path, Digest)
          else
            HasHash := TryHashRAMedia(LoadedGame.ConsoleID, Path, Data, HashCallbacksWithLogging(Options), Digest);
          if not HasHash or (Digest = '') or (Pos(#0, Digest) <> 0) then
            Digest := RAExternalUnhashableMedia;
          if FAsyncRequests.IsCanceled(Context) then
            Exit;
          if CachePath then
            CacheMediaPathHash(Path, Digest, HashRevision, Options, Hasher);
        end;
      end;
      if FAsyncRequests.IsCanceled(Context) then
        Exit;
      if Assigned(FTable.AddGameHash) and (LoadedGame.ID <> 0) and not Digest.StartsWith('[') and
        not TryGetMediaGameID(Digest, GameID) then
      begin
        Resolution := ResolveExternalHash(Digest, ResolvedID);
        if FAsyncRequests.IsCanceled(Context) then
          Exit;
        if Resolution.Code <> RAExternalOK then
        begin
          FAsyncRequests.Finish(Context, Resolution);
          Exit;
        end;
        // A manual registration may have taken place inside the hosted transport.
        if not TryGetMediaGameID(Digest, GameID) then
          AddGameHash(Digest, ResolvedID);
      end;
      if FAsyncRequests.IsCanceled(Context) then
        Exit;
      HashText := UTF8String(Digest);
      Result := FTable.BeginChangeMedia(Client, PAnsiChar(HashText), ReceiveAsync, Context);
    end,
    procedure(const Data: TRAExternalAsyncResult)
    begin
      CompleteMediaChange(Digest, Data, Completed);
    end, TRAGameLoadPhase.Idle, False, TRAExternalRequestKind.MediaChange);
end;

function TRAExternalClientSession.BeginChangeMedia(const GameHash: string; const Completed: TRAMediaChanged): IRAMediaChange;
begin
  if not Assigned(FTable.BeginChangeMedia) then
    Exit(inherited BeginChangeMedia(GameHash, Completed));
  RequireExternalText(GameHash, 'media hash');
  Result := QueueExternalMediaChange(GameHash, '', nil, Default(TRAMediaHashOptions), nil, 0, Completed);
end;

function TRAExternalClientSession.BeginIdentifyAndChangeMedia(const Path: string; const Hasher: TRAMediaHasher; const Completed: TRAMediaChanged): IRAMediaChange;
var
  HashRevision: UInt64;
begin
  if not Assigned(FTable.BeginChangeMedia) then
    Exit(inherited BeginIdentifyAndChangeMedia(Path, Hasher, Completed));
  if not Assigned(Hasher) then
    raise EArgumentNilException.Create('A RetroAchievements media reader is required');
  if Pos(#0, Path) <> 0 then
    raise EArgumentException.Create('Invalid RetroAchievements media path');
  ResolveHashCallbacks(Default(TRAMediaHashOptions), HashRevision);
  Result := QueueExternalMediaChange('', Path, nil, Default(TRAMediaHashOptions), Hasher, HashRevision, Completed);
end;

function TRAExternalClientSession.BeginIdentifyAndChangeMedia(const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAMediaChanged): IRAMediaChange;
var
  OwnedData: TBytes;
  PathText: UTF8String;
  EffectiveOptions: TRAMediaHashOptions;
  HashRevision: UInt64;
begin
  if not Assigned(FTable.BeginChangeMedia) and not Assigned(FTable.BeginIdentifyAndChangeMedia) then
    Exit(inherited BeginIdentifyAndChangeMedia(Path, Data, Options, Completed));
  RequireExternalMedia(Path, Data);
  OwnedData := Copy(Data);
  if Assigned(FTable.BeginChangeMedia) then
  begin
    EffectiveOptions := ResolveHashCallbacks(Options, HashRevision);
    Exit(QueueExternalMediaChange('', Path, OwnedData, EffectiveOptions, nil, HashRevision, Completed));
  end;
  PathText := UTF8String(Path);
  Result := FAsyncRequests.Enqueue(
    function(Client, Context: Pointer): Pointer
    begin
      Result := FTable.BeginIdentifyAndChangeMedia(Client, Pointer(PathText), PByte(OwnedData), Length(OwnedData),
        ReceiveAsync, Context);
    end,
    procedure(const Result: TRAExternalAsyncResult)
    begin
      CompleteMediaChange('', Result, Completed);
    end, TRAGameLoadPhase.Idle, False, TRAExternalRequestKind.MediaChange);
end;

function TRAExternalClientSession.QueueExternalEntries(ID: Cardinal; const Start: TRAExternalRequestStart; const Completed: TRALeaderboardEntriesReceived; Kind: TRAExternalRequestKind): IRALeaderboardEntriesRequest;
var
  HostRevision: UInt64;
begin
  HostRevision := GetHostRevision;
  Result := FAsyncRequests.Enqueue(
    function(Client, Context: Pointer): Pointer
    begin
      if HostRevision <> GetHostRevision then
      begin
        FAsyncRequests.Finish(Context, ExternalRequestResult(RAExternalAborted, HostChangedMessage));
        Exit(nil);
      end;
      Result := Start(Client, Context);
    end,
    procedure(const Data: TRAExternalAsyncResult)
    var
      Entries: TRALeaderboardEntriesResult;
      Status: TRAQueryStatus;
    begin
      if not Assigned(Completed) then
        Exit;
      Entries := Default(TRALeaderboardEntriesResult);
      Entries.LeaderboardID := ID;
      Entries.UserIndex := -1;
      if HostRevision <> GetHostRevision then
        Status := ExternalRequestStatus(ExternalRequestResult(RAExternalAborted, HostChangedMessage))
      else
      begin
        Status := ExternalRequestStatus(Data);
        Entries.TotalEntries := Data.TotalEntries;
        Entries.UserIndex := Data.UserIndex;
        Entries.Entries := Data.Entries;
        for var Index := 0 to High(Entries.Entries) do
          Entries.Entries[Index].AvatarURL := ImageURL(TRAImageKind.User, Entries.Entries[Index].UserName, nil);
      end;
      Entries.Success := Status.Success;
      Entries.ResultCode := Status.ResultCode;
      Entries.HTTPStatus := Status.HTTPStatus;
      Entries.ServerCode := Status.ServerCode;
      Entries.ErrorMessage := Status.ErrorMessage;
      Completed(Entries);
    end, TRAGameLoadPhase.Idle, False, Kind);
end;

function TRAExternalClientSession.BeginFetchLeaderboardEntries(ID, FirstEntry, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
begin
  if not Assigned(FTable.BeginFetchLeaderboardEntries) then
    Exit(inherited BeginFetchLeaderboardEntries(ID, FirstEntry, Count, Completed));
  Result := QueueExternalEntries(ID,
    function(Client, Context: Pointer): Pointer
    begin
      Result := FTable.BeginFetchLeaderboardEntries(Client, ID, FirstEntry, Count, ReceiveEntries, Context);
    end, Completed);
end;

function TRAExternalClientSession.BeginFetchLeaderboardEntriesAroundUser(ID, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
begin
  FProviderLock.Acquire;
  try
    if (FAccountSource <> TAccountSource.Provider) or not Assigned(FTable.BeginFetchLeaderboardEntriesAroundUser) then
      Exit(inherited BeginFetchLeaderboardEntriesAroundUser(ID, Count, Completed));
    SynchronizeQueryAccount;
    Result := QueueExternalEntries(ID,
      function(Client, Context: Pointer): Pointer
      begin
        Result := FTable.BeginFetchLeaderboardEntriesAroundUser(Client, ID, Count, ReceiveEntries, Context);
      end, Completed, TRAExternalRequestKind.AccountQuery);
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.UseNativeAccount;
begin
  FProviderLock.Acquire;
  try
    Inc(FAccountEpoch);
    FAccountSource := TAccountSource.Native;
    FAsyncRequests.CancelRequests([TRAExternalRequestKind.Login, TRAExternalRequestKind.AccountQuery]);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.SynchronizeQueryAccount: Boolean;
var
  User: TRALoginInfo;
begin
  FProviderLock.Acquire;
  try
    Result := not FAsyncRequests.HasPendingLogin;
    if not Result or (FAccountSource = TAccountSource.Native) then
      Exit;
    if FAccountSource = TAccountSource.LoggedOut then
      UpdateQueryAccount(Default(TRALoginInfo))
    else if Assigned(FTable.GetUserInfo) or Assigned(FTable.GetUserInfoV3) then
    begin
      ReadProviderUser(User);
      if UpdateQueryAccount(User) then
        FAsyncRequests.CancelRequests([TRAExternalRequestKind.AccountQuery]);
    end;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.TryGetUserInfo(out User: TRALoginInfo): Boolean;
begin
  FProviderLock.Acquire;
  try
    if FAccountSource = TAccountSource.LoggedOut then
    begin
      User := Default(TRALoginInfo);
      Exit(False);
    end;
    if FAccountSource = TAccountSource.Provider then
    begin
      if FAsyncRequests.HasPendingLogin then
      begin
        User := Default(TRALoginInfo);
        Exit(False);
      end;
      if Assigned(FTable.GetUserInfo) or Assigned(FTable.GetUserInfoV3) then
        Exit(ReadProviderUser(User));
    end;
  finally
    FProviderLock.Release;
  end;
  Result := inherited TryGetUserInfo(User);
end;

function TRAExternalClientSession.ReadProviderUser(out User: TRALoginInfo): Boolean;
var
  Source: PRAExternalUserV1;
  Modern: PRAExternalUserV3;
  AvatarURL: PAnsiChar;
begin
  Modern := nil;
  AvatarURL := nil;
  if Assigned(FTable.GetUserInfoV3) then
  begin
    Modern := FTable.GetUserInfoV3();
    Source := PRAExternalUserV1(Modern);
    if Modern <> nil then
      AvatarURL := Modern.AvatarURL;
  end
  else if Assigned(FTable.GetUserInfo) then
    Source := FTable.GetUserInfo()
  else
    Source := nil;

  User := Default(TRALoginInfo);
  Result := Source <> nil;
  if not Result then
    Exit;
  User.DisplayName := ReadExternalText(Source.DisplayName);
  User.Credentials.UserName := ReadExternalText(Source.UserName);
  User.Credentials.Token := ReadExternalText(Source.Token);
  User.Score := Source.Score;
  User.SoftcoreScore := Source.SoftcoreScore;
  User.UnreadMessages := Source.UnreadMessages;
  if AvatarURL <> nil then
    User.SetAvatarURL(ReadExternalText(AvatarURL))
  else if Modern = nil then
    User.AvatarURL := ImageURL(TRAImageKind.User, User.Credentials.UserName, nil, True)
  else
    User.AvatarURL := ImageURL(TRAImageKind.User, User.DisplayName, nil);
  if (Modern <> nil) and FHasAvatarTimestamp then
    User.AvatarUpdated := PRAExternalUserV124(Modern).AvatarUpdated;
end;

function TRAExternalClientSession.ReadGame: TRAGameData;
var
  Source: PRAExternalGameV1;
  Modern: PRAExternalGameV3;
  BadgeURL: PAnsiChar;
begin
  Result := inherited GetGame;
  if (Result.ID = 0) and (Result.Title <> '') then
    Exit;
  Modern := nil;
  BadgeURL := nil;
  if Assigned(FTable.GetGameInfoV3) then
  begin
    Modern := FTable.GetGameInfoV3();
    Source := PRAExternalGameV1(Modern);
    if Modern <> nil then
      BadgeURL := Modern.BadgeURL;
  end
  else if Assigned(FTable.GetGameInfo) then
    Source := FTable.GetGameInfo()
  else
    Exit;

  Result := Default(TRAGameData);
  if Source = nil then
    Exit;
  Result.ID := Source.ID;
  Result.ConsoleID := Source.ConsoleID;
  Result.Title := ReadExternalText(Source.Title);
  Result.ImageName := ReadExternalText(Source.BadgeName);
  if BadgeURL <> nil then
    Result.SetImageURL(ReadExternalText(BadgeURL))
  else
    Result.ImageURL := ImageURL(TRAImageKind.Game, Result.ImageName, nil, Modern = nil);
  Result.Hash := ReadExternalText(Source.Hash);
end;

function TRAExternalClientSession.ReadLoadedGame(const RequestedHash: string): TRAGameData;
begin
  FProviderLock.Acquire;
  try
    UnloadNativeGame;
    Result := ReadGame;
    if Result.Hash = '' then
      Result.Hash := RequestedHash;
    if (Result.ID <> 0) and (Result.Hash <> '') then
      inherited AddGameHash(Result.Hash, Result.ID);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.GetGame: TRAGameData;
begin
  FProviderLock.Acquire;
  try
    Result := ReadGame;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.GetGameLoaded: Boolean;
begin
  Result := GetGame.ID <> 0;
end;

function TRAExternalClientSession.DescribeExternalMedia(const Hash: string; LoadedGameID: Cardinal): TRAMediaInfo;
var
  GameID: Cardinal;
begin
  if (LoadedGameID = 0) or Hash.StartsWith('[') then
    GameID := 0
  else if not TryGetMediaGameID(Hash, GameID) then
    GameID := LoadedGameID;
  Result := DescribeMedia(Hash, GameID, LoadedGameID);
end;

function TRAExternalClientSession.GetCurrentMedia: TRAMediaInfo;
var
  Game: TRAGameData;
begin
  if not Assigned(FTable.GetGameInfo) and not Assigned(FTable.GetGameInfoV3) then
    Exit(inherited GetCurrentMedia);
  FProviderLock.Acquire;
  try
    Game := ReadGame;
    Result := DescribeExternalMedia(Game.Hash, Game.ID);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.ConvertSubset(Source: PRAExternalSubsetV1): TRASubsetInfo;
begin
  Result := Default(TRASubsetInfo);
  if Source = nil then
    Exit;
  Result.ID := Source.ID;
  Result.Title := ReadExternalText(Source.Title);
  Result.BadgeName := ReadExternalText(@Source.BadgeName[0], Length(Source.BadgeName));
  Result.BadgeURL := ImageURL(TRAImageKind.Game, Result.BadgeName, nil, True);
  Result.AchievementCount := Source.AchievementCount;
  Result.LeaderboardCount := Source.LeaderboardCount;
end;

function TRAExternalClientSession.ConvertSubset(Source: PRAExternalSubsetV3): TRASubsetInfo;
begin
  Result := ConvertSubset(PRAExternalSubsetV1(Source));
  if Source <> nil then
    Result.BadgeURL := ImageURL(TRAImageKind.Game, Result.BadgeName, Source.BadgeURL);
end;

function TRAExternalClientSession.TryGetSubsetInfo(SubsetID: Cardinal; out Info: TRASubsetInfo): Boolean;
var
  Legacy: PRAExternalSubsetV1;
  Modern: PRAExternalSubsetV3;
begin
  FProviderLock.Acquire;
  try
    if Assigned(FTable.GetSubsetInfoV3) then
    begin
      Modern := FTable.GetSubsetInfoV3(SubsetID);
      Info := ConvertSubset(Modern);
      Exit(Modern <> nil);
    end;
    if Assigned(FTable.GetSubsetInfo) then
    begin
      Legacy := FTable.GetSubsetInfo(SubsetID);
      Info := ConvertSubset(Legacy);
      Exit(Legacy <> nil);
    end;
  finally
    FProviderLock.Release;
  end;
  Result := inherited TryGetSubsetInfo(SubsetID, Info);
end;

function TRAExternalClientSession.CreateSubsetList: TArray<TRASubsetInfo>;
var
  List: PRAExternalSubsetList;
begin
  if not Assigned(FTable.CreateSubsetList) then
    Exit(inherited CreateSubsetList);
  FProviderLock.Acquire;
  try
    List := FTable.CreateSubsetList();
    if List = nil then
      Exit(nil);
    try
      SetLength(Result, CheckedExternalCount(List.Count, List.Entries));
      for var Index := 0 to High(Result) do
        Result[Index] := ConvertSubset(PRAExternalSubsetV3(List.Entries[Index]));
    finally
      if Assigned(List.Destroy) then
        List.Destroy(List);
    end;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.GetUserGameSummary: TRAUserGameSummary;
var
  Summary: TRAExternalUserGameSummaryV5;
begin
  if not Assigned(FTable.GetUserGameSummaryV5) and not Assigned(FTable.GetUserGameSummary) then
    Exit(inherited GetUserGameSummary);
  Summary := Default(TRAExternalUserGameSummaryV5);
  FProviderLock.Acquire;
  try
    if Assigned(FTable.GetUserGameSummaryV5) then
      FTable.GetUserGameSummaryV5(Summary)
    else
      FTable.GetUserGameSummary(Summary.Data);
  finally
    FProviderLock.Release;
  end;
  Result := ConvertSummary(Summary);
end;

function TRAExternalClientSession.GetUserSubsetSummary(SubsetID: Cardinal): TRAUserGameSummary;
var
  Summary: TRAExternalUserGameSummaryV5;
begin
  if not Assigned(FTable.GetUserSubsetSummary) then
    Exit(inherited GetUserSubsetSummary(SubsetID));
  Summary := Default(TRAExternalUserGameSummaryV5);
  if SubsetID <> 0 then
  begin
    FProviderLock.Acquire;
    try
      FTable.GetUserSubsetSummary(SubsetID, Summary);
    finally
      FProviderLock.Release;
    end;
  end;
  Result := ConvertSummary(Summary);
end;

function TRAExternalClientSession.ConvertAchievement(Source: PRAExternalAchievementV1; Legacy: Boolean): TRAClientAchievement;
var
  Badge: string;
begin
  Result := Default(TRAClientAchievement);
  if Source = nil then
    Exit;
  Result.ID := Source.ID;
  Result.Title := ReadExternalText(Source.Title);
  Result.Description := ReadExternalText(Source.Description);
  Result.BadgeName := ReadExternalText(@Source.BadgeName[0], Length(Source.BadgeName));
  Badge := Result.BadgeName;
  if Badge = '' then
    Badge := RABadgeFallback;
  Result.BadgeURL := ImageURL(TRAImageKind.Achievement, Badge, nil, Legacy);
  Result.BadgeLockedURL := ImageURL(TRAImageKind.LockedAchievement, Badge, nil, Legacy);
  Result.MeasuredProgress := ReadExternalText(@Source.MeasuredProgress[0], Length(Source.MeasuredProgress));
  Result.MeasuredPercent := Source.MeasuredPercent;
  Result.Points := Source.Points;
  Result.UnlockTime := Source.UnlockTime;
  Result.Rarity := Source.Rarity;
  Result.RarityHardcore := Source.RarityHardcore;
  if Source.State <= Byte(High(TRAClientAchievementState)) then
    Result.State := TRAClientAchievementState(Source.State);
  if (Source.Category and 2) <> 0 then
    Result.Category := TRAAchievementCategory.Unofficial;
  Result.Bucket := ConvertBucket(Source.Bucket);
  if (Source.Unlocked and 1) <> 0 then
    Include(Result.Unlocks, TRAAchievementUnlock.Casual);
  if (Source.Unlocked and 2) <> 0 then
    Include(Result.Unlocks, TRAAchievementUnlock.Hardcore);
  if Source.Kind <= Byte(High(TRAAchievementKind)) then
    Result.Kind := TRAAchievementKind(Source.Kind);
end;

function TRAExternalClientSession.ConvertAchievement(Source: PRAExternalAchievementV3): TRAClientAchievement;
begin
  Result := ConvertAchievement(PRAExternalAchievementV1(Source), False);
  if Source = nil then
    Exit;
  if Source.BadgeURL <> nil then
    Result.SetImageURL(TRAClientAchievementState.Unlocked, ReadExternalText(Source.BadgeURL));
  if Source.BadgeLockedURL <> nil then
    Result.SetImageURL(TRAClientAchievementState.Active, ReadExternalText(Source.BadgeLockedURL));
end;

function TRAExternalClientSession.TryGetAchievementInfo(ID: Cardinal; out Info: TRAClientAchievement): Boolean;
var
  Modern: PRAExternalAchievementV3;
  Legacy: PRAExternalAchievementV1;
begin
  FProviderLock.Acquire;
  try
    if Assigned(FTable.GetAchievementInfoV3) then
    begin
      Modern := FTable.GetAchievementInfoV3(ID);
      Info := ConvertAchievement(Modern);
      Exit(Modern <> nil);
    end;
    if Assigned(FTable.GetAchievementInfo) then
    begin
      Legacy := FTable.GetAchievementInfo(ID);
      Info := ConvertAchievement(Legacy);
      Exit(Legacy <> nil);
    end;
  finally
    FProviderLock.Release;
  end;
  Result := inherited TryGetAchievementInfo(ID, Info);
end;

function TRAExternalClientSession.TryGetNextAchievementInfo(AfterID: Cardinal; Bucket: TRAAchievementBucketKind; out Info: TRAClientAchievement): Boolean;
var
  Source: PRAExternalAchievementV3;
begin
  if not Assigned(FTable.GetNextAchievementInfo) then
    Exit(inherited TryGetNextAchievementInfo(AfterID, Bucket, Info));
  FProviderLock.Acquire;
  try
    Source := FTable.GetNextAchievementInfo(AfterID, Ord(Bucket));
    Info := ConvertAchievement(Source);
    Result := Source <> nil;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.ReadProviderFlag(GetFlag: TRAExternalBoolean): Boolean;
begin
  FProviderLock.Acquire;
  try
    Result := GetFlag() <> 0;
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.WriteProviderFlag(SetFlag: TRAExternalSetBoolean; Enabled: Boolean);
begin
  FProviderLock.Acquire;
  try
    SetFlag(Ord(Enabled));
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.HasAchievements: Boolean;
begin
  if Assigned(FTable.HasAchievements) then
    Exit(ReadProviderFlag(FTable.HasAchievements));
  Result := inherited HasAchievements;
end;

function TRAExternalClientSession.CreateAchievementList(Categories: TRAAchievementCategories; Grouping: TRAAchievementGrouping): TArray<TRAAchievementBucket>;
var
  List: PRAExternalBucketList;
  Source: PRAExternalCatalogBucket;
  Modern: Boolean;
  Mask: Integer;
begin
  Mask := 0;
  if TRAAchievementCategory.Core in Categories then
    Mask := Mask or 1;
  if TRAAchievementCategory.Unofficial in Categories then
    Mask := Mask or 2;

  Modern := Assigned(FTable.CreateAchievementListV3);
  if not Modern and not Assigned(FTable.CreateAchievementList) then
    Exit(inherited CreateAchievementList(Categories, Grouping));
  FProviderLock.Acquire;
  try
    if Modern then
      List := FTable.CreateAchievementListV3(Mask, Ord(Grouping))
    else
      List := FTable.CreateAchievementList(Mask, Ord(Grouping));
    if List = nil then
      Exit(nil);

    try
      SetLength(Result, CheckedExternalCount(List.Count, List.Buckets));
      for var Index := 0 to High(Result) do
      begin
        Source := @List.Buckets[Index];
        Result[Index].Kind := ConvertBucket(Source.Kind);
        Result[Index].SubsetID := Source.SubsetID;
        Result[Index].LabelText := ReadExternalText(Source.LabelText);
        SetLength(Result[Index].Achievements, CheckedExternalCount(Source.Count, Source.Entries));
        for var Asset := 0 to High(Result[Index].Achievements) do
          if Modern then
            Result[Index].Achievements[Asset] := ConvertAchievement(PRAExternalAchievementV3(Source.Entries[Asset]))
          else
            Result[Index].Achievements[Asset] := ConvertAchievement(PRAExternalAchievementV1(Source.Entries[Asset]));
      end;
    finally
      if Assigned(List.Destroy) then
        List.Destroy(List);
    end;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.TryGetLeaderboardInfo(ID: Cardinal; out Info: TRAClientLeaderboard): Boolean;
var
  Source: PRAExternalLeaderboard;
begin
  if not Assigned(FTable.GetLeaderboardInfo) then
    Exit(inherited TryGetLeaderboardInfo(ID, Info));
  FProviderLock.Acquire;
  try
    Source := FTable.GetLeaderboardInfo(ID);
    Info := ConvertLeaderboard(Source);
    Result := Source <> nil;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.HasLeaderboards: Boolean;
begin
  if Assigned(FTable.HasLeaderboards) then
    Exit(ReadProviderFlag(FTable.HasLeaderboards));
  Result := inherited HasLeaderboards;
end;

function TRAExternalClientSession.CreateLeaderboardList(Grouping: TRALeaderboardGrouping): TArray<TRALeaderboardBucket>;
var
  List: PRAExternalBucketList;
  Source: PRAExternalCatalogBucket;
begin
  if not Assigned(FTable.CreateLeaderboardList) then
    Exit(inherited CreateLeaderboardList(Grouping));
  FProviderLock.Acquire;
  try
    List := FTable.CreateLeaderboardList(Ord(Grouping));
    if List = nil then
      Exit(nil);

    try
      SetLength(Result, CheckedExternalCount(List.Count, List.Buckets));
      for var Index := 0 to High(Result) do
      begin
        Source := @List.Buckets[Index];
        if (Source.Kind > 0) and (Source.Kind <= Byte(Ord(High(TRALeaderboardBucketKind)) + 1)) then
          Result[Index].Kind := TRALeaderboardBucketKind(Source.Kind - 1);
        Result[Index].SubsetID := Source.SubsetID;
        Result[Index].LabelText := ReadExternalText(Source.LabelText);
        SetLength(Result[Index].Leaderboards, CheckedExternalCount(Source.Count, Source.Entries));
        for var Asset := 0 to High(Result[Index].Leaderboards) do
          Result[Index].Leaderboards[Asset] := ConvertLeaderboard(PRAExternalLeaderboard(Source.Entries[Asset]));
      end;
    finally
      if Assigned(List.Destroy) then
        List.Destroy(List);
    end;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.GetHardcoreEnabled: Boolean;
begin
  if Assigned(FTable.GetHardcoreEnabled) then
    Exit(ReadProviderFlag(FTable.GetHardcoreEnabled));
  Result := inherited GetHardcoreEnabled;
end;

procedure TRAExternalClientSession.SetHardcoreEnabled(Enabled: Boolean);
begin
  if not Assigned(FTable.SetHardcoreEnabled) then
  begin
    inherited;
    Exit;
  end;
  WriteProviderFlag(FTable.SetHardcoreEnabled, Enabled);
  DispatchClientEvents;
end;

function TRAExternalClientSession.GetEncoreModeEnabled: Boolean;
begin
  if Assigned(FTable.GetEncoreModeEnabled) then
    Exit(ReadProviderFlag(FTable.GetEncoreModeEnabled));
  Result := inherited GetEncoreModeEnabled;
end;

procedure TRAExternalClientSession.SetEncoreModeEnabled(Enabled: Boolean);
begin
  if Assigned(FTable.SetEncoreModeEnabled) then
    WriteProviderFlag(FTable.SetEncoreModeEnabled, Enabled)
  else
    inherited;
end;

function TRAExternalClientSession.GetUnofficialEnabled: Boolean;
begin
  if Assigned(FTable.GetUnofficialEnabled) then
    Exit(ReadProviderFlag(FTable.GetUnofficialEnabled));
  Result := inherited GetUnofficialEnabled;
end;

procedure TRAExternalClientSession.SetUnofficialEnabled(Enabled: Boolean);
begin
  if Assigned(FTable.SetUnofficialEnabled) then
    WriteProviderFlag(FTable.SetUnofficialEnabled, Enabled)
  else
    inherited;
end;

function TRAExternalClientSession.GetSpectatorMode: TRASpectatorMode;
begin
  if not Assigned(FTable.GetSpectatorModeEnabled) then
    Exit(inherited GetSpectatorMode);
  if ReadProviderFlag(FTable.GetSpectatorModeEnabled) then
    Exit(TRASpectatorMode.Enabled);
  Result := TRASpectatorMode.Disabled;
end;

function TRAExternalClientSession.SetSpectatorModeEnabled(Enabled: Boolean): Boolean;
begin
  if not Assigned(FTable.SetSpectatorModeEnabled) then
    Exit(inherited SetSpectatorModeEnabled(Enabled));
  FProviderLock.Acquire;
  try
    FTable.SetSpectatorModeEnabled(Ord(Enabled));
    Result := not Assigned(FTable.GetSpectatorModeEnabled) or ((FTable.GetSpectatorModeEnabled() <> 0) = Enabled);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.CanPause(out FramesRemaining: Cardinal): Boolean;
begin
  if not Assigned(FTable.CanPause) then
    Exit(inherited CanPause(FramesRemaining));
  FramesRemaining := 0;
  FProviderLock.Acquire;
  try
    Result := FTable.CanPause(FramesRemaining) <> 0;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.IsProcessingRequired: Boolean;
begin
  if MemoryReadsRequireEmulationThread and FAsyncRequests.HasRunningLoad then
    Exit(True);
  if Assigned(FTable.IsProcessingRequired) then
    Exit(ReadProviderFlag(FTable.IsProcessingRequired));
  Result := inherited IsProcessingRequired;
end;

function TRAExternalClientSession.HasRichPresence: Boolean;
begin
  if Assigned(FTable.HasRichPresence) then
    Exit(ReadProviderFlag(FTable.HasRichPresence));
  Result := inherited HasRichPresence;
end;

function TRAExternalClientSession.CopyProviderText(GetText: TRAExternalCopyText): string;
var
  Buffer: TBytes;
  Size: NativeUInt;
begin
  SetLength(Buffer, 256);
  FProviderLock.Acquire;
  try
    Size := GetText(PAnsiChar(@Buffer[0]), Length(Buffer));
    if Size = 0 then
      Exit('');
    if Size >= NativeUInt(MaxInt) then
      raise ERAProtocolError.Create('External RetroAchievements text is too long');
    if Size >= NativeUInt(Length(Buffer)) then
    begin
      SetLength(Buffer, Size + 1);
      GetText(PAnsiChar(@Buffer[0]), Length(Buffer));
    end;
  finally
    FProviderLock.Release;
  end;
  Result := ReadExternalText(PAnsiChar(@Buffer[0]), Length(Buffer));
end;

function TRAExternalClientSession.GetRichPresenceMessage: string;
begin
  if not Assigned(FTable.GetRichPresenceMessage) then
    Exit(inherited GetRichPresenceMessage);
  Result := CopyProviderText(FTable.GetRichPresenceMessage);
end;

function TRAExternalClientSession.GetRichPresenceMessage(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(0);
  if not Assigned(FTable.GetRichPresenceMessage) then
    Exit(inherited GetRichPresenceMessage(Buffer, BufferSize));
  FProviderLock.Acquire;
  try
    Result := FTable.GetRichPresenceMessage(Buffer, BufferSize);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.GetUserAgentClause: string;
begin
  if Assigned(FTable.GetUserAgentClause) then
  begin
    Result := CopyProviderText(FTable.GetUserAgentClause);
    if Result <> '' then
      Exit(Result + ' rc_client/' + RAProtocolVersion);
  end;
  Result := inherited GetUserAgentClause;
end;

function TRAExternalClientSession.ProgressSize: NativeUInt;
begin
  if not Assigned(FTable.ProgressSize) then
    Exit(inherited ProgressSize);
  FProviderLock.Acquire;
  try
    Result := FTable.ProgressSize();
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  if not Assigned(FTable.SerializeProgress) then
    Exit(inherited SerializeProgressSized(Buffer, BufferSize));
  FProviderLock.Acquire;
  try
    Result := FTable.SerializeProgress(Buffer, BufferSize);
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  if not Assigned(FTable.DeserializeProgress) then
    Exit(inherited DeserializeProgressSized(Buffer, BufferSize));
  FProviderLock.Acquire;
  try
    Result := FTable.DeserializeProgress(Buffer, BufferSize);
  finally
    FProviderLock.Release;
  end;
  DispatchClientEvents;
end;

function TRAExternalClientSession.CaptureProgress: TBytes;
var
  Size: NativeUInt;
begin
  if not Assigned(FTable.ProgressSize) or not Assigned(FTable.SerializeProgress) then
    Exit(inherited CaptureProgress);
  FProviderLock.Acquire;
  try
    Size := FTable.ProgressSize();
    if (Size = 0) or (Size > NativeUInt(MaxInt)) then
      Exit(nil);
    SetLength(Result, Size);
    if FTable.SerializeProgress(@Result[0], Size) <> RAExternalOK then
      Result := nil;
  finally
    FProviderLock.Release;
  end;
end;

function TRAExternalClientSession.RestoreProgress(const Data: TBytes): Boolean;
begin
  if not Assigned(FTable.DeserializeProgress) then
    Exit(inherited RestoreProgress(Data));
  Result := DeserializeProgressSized(PByte(Data), Length(Data)) = RAExternalOK;
end;

procedure TRAExternalClientSession.AddGameHash(const Hash: string; GameID: Cardinal);
var
  Text: UTF8String;
begin
  FProviderLock.Acquire;
  try
    inherited;
    if Assigned(FTable.AddGameHash) then
    begin
      Text := UTF8String(Hash);
      FTable.AddGameHash(PAnsiChar(Text), GameID);
    end;
  finally
    FProviderLock.Release;
  end;
end;

procedure TRAExternalClientSession.LoadUnknownGame(const TriedHashes: string; ConsoleID: Cardinal);
var
  HashText: UTF8String;
begin
  inherited;
  FProviderLock.Acquire;
  try
    FAsyncRequests.CancelRequests([TRAExternalRequestKind.GameLoad, TRAExternalRequestKind.MediaChange]);
    if Assigned(FTable.LoadUnknownGame) then
    begin
      HashText := UTF8String(TriedHashes);
      FTable.LoadUnknownGame(PAnsiChar(HashText));
    end
    else if Assigned(FTable.UnloadGame) then
      FTable.UnloadGame();
  finally
    FProviderLock.Release;
  end;
  DispatchClientEvents;
end;

procedure TRAExternalClientSession.Logout;
begin
  FProviderLock.Acquire;
  try
    Inc(FAccountEpoch);
    FAccountSource := TAccountSource.LoggedOut;
    FAsyncRequests.CancelRequests([TRAExternalRequestKind.GameLoad, TRAExternalRequestKind.MediaChange,
        TRAExternalRequestKind.Login, TRAExternalRequestKind.AccountQuery]);
    if Assigned(FTable.Logout) then
      FTable.Logout();
  finally
    FProviderLock.Release;
  end;
  inherited;
end;

procedure TRAExternalClientSession.UnloadGame;
begin
  FProviderLock.Acquire;
  try
    FAsyncRequests.CancelRequests([TRAExternalRequestKind.GameLoad, TRAExternalRequestKind.MediaChange]);
    if Assigned(FTable.UnloadGame) then
      FTable.UnloadGame();
  finally
    FProviderLock.Release;
  end;
  inherited;
end;

procedure TRAExternalClientSession.Reset;
begin
  FProviderLock.Acquire;
  try
    FEventLock.Acquire;
    try
      FResetRequested := False;
    finally
      FEventLock.Release;
    end;
    if Assigned(FTable.Reset) then
      FTable.Reset();
  finally
    FProviderLock.Release;
  end;
  if Assigned(FTable.Reset) then
    DispatchClientEvents
  else
    inherited;
end;

end.

