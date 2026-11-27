unit RA.Session;

interface

{$SCOPEDENUMS ON}

uses
  System.Diagnostics, System.Generics.Collections, System.JSON, System.SyncObjs,
  System.SysUtils, RA.ClientIndicators, RA.Format, RA.GameData,
  RA.HashDiscReader, RA.Info, RA.MediaHash, RA.Memory, RA.Protocol, RA.Runtime;

type
  ERARomNotRecognized = class(ERAProtocolError);

  ERANoAchievementSets = class(ERAProtocolError);

  // Return a caller-owned response processed by ParseRAResponse, or raise an error.
  TRAPost = reference to function(const Form: string): TJSONObject;

  TRAHostedPost = reference to function(const URL, Form: string): TJSONObject;

  // Monotonic time in milliseconds. A custom clock must be safe on both workers.
  TRAClock = reference to function: UInt64;

  // UTC seconds since the Unix epoch. A custom clock must be safe on both workers.
  TRAUnixClock = reference to function: Int64;

  TRAClientLogLevel = (None, Error, Warning, Info, Verbose);

  TRAClientLog = reference to procedure(Level: TRAClientLogLevel; const Message: string);

  TRAClientEventHandler = reference to procedure(const Event: TRARuntimeEvent);

  TRAClientSubmissionFilter = reference to function(ID: Cardinal): Boolean;

  TRAGameSetsResponseHandler = reference to procedure(Response: TJSONObject; const Game: TRAGameData);

  TRARichPresenceOverride = reference to function(out MessageText: string): Boolean;

  TRASubmissionState = (Confirmed, Rejected, RetryScheduled);

  TRASubmission = record
    Event: TRARuntimeEvent;
    State: TRASubmissionState;
    ErrorMessage, ServerCode: string;
    HTTPStatus, ResultCode: Integer;
    Hardcore: Boolean;
    Award: TRAAwardResponse;
    Leaderboard: TRALeaderboardResponse;
  end;

  TRAClientAchievementState = (Inactive, Active, Unlocked, Disabled);

  TRAAchievementCategory = (Core, Unofficial);

  TRAAchievementCategories = set of TRAAchievementCategory;

  TRAAchievementUnlock = (Casual, Hardcore);

  TRAAchievementUnlocks = set of TRAAchievementUnlock;

  TRAAchievementGrouping = (LockState, Progress);

  TRAAchievementBucketKind = (Unknown, Locked, Unlocked, Unsupported, Unofficial,
    RecentlyUnlocked, ActiveChallenge, AlmostThere, Unsynced);

  TRAClientAchievement = record
  private
    FHasExplicitBadgeURL, FHasExplicitBadgeLockedURL: Boolean;
  public
    ID, Points: Cardinal;
    Title, Description, BadgeName, BadgeURL, BadgeLockedURL: string;
    State: TRAClientAchievementState;
    Category: TRAAchievementCategory;
    Kind: TRAAchievementKind;
    Bucket: TRAAchievementBucketKind;
    Unlocks: TRAAchievementUnlocks;
    UnlockTime: Int64;
    Rarity, RarityHardcore, MeasuredPercent: Single;
    MeasuredProgress: string;
    class operator Initialize(out Dest: TRAClientAchievement);
    procedure SetImageURL(ImageState: TRAClientAchievementState; const URL: string);
    function ImageURL(ImageState: TRAClientAchievementState; const ImageHost: string = RAMediaHost): string;
    function CopyImageURL(ImageState: TRAClientAchievementState; Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string = RAMediaHost): Integer;
  end;

  TRAAchievementBucket = record
    Kind: TRAAchievementBucketKind;
    SubsetID: Cardinal;
    LabelText: string;
    Achievements: TArray<TRAClientAchievement>;
  end;

  TRAClientLeaderboardState = (Inactive, Active, Tracking, Disabled);

  TRAClientLeaderboardFormat = (Time, Score, Value);

  TRALeaderboardGrouping = (None, Tracking);

  TRALeaderboardBucketKind = (Inactive, Active, Unsupported, All);

  TRAClientLeaderboard = record
    ID, TrackerID: Cardinal;
    Title, Description, TrackerValue: string;
    State: TRAClientLeaderboardState;
    Format: TRAClientLeaderboardFormat;
    LowerIsBetter: Boolean;
  end;

  TRALeaderboardBucket = record
    Kind: TRALeaderboardBucketKind;
    SubsetID: Cardinal;
    LabelText: string;
    Leaderboards: TArray<TRAClientLeaderboard>;
  end;

  TRAClientLeaderboardEntry = record
    UserName, AvatarURL, Display: string;
    Rank, Index: Cardinal;
    Score: Integer;
    Submitted: Int64;
    function CopyAvatarURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string = RAMediaHost): Integer;
  end;

  TRALeaderboardEntriesResult = record
    Success: Boolean;
    LeaderboardID, TotalEntries: Cardinal;
    UserIndex: Integer;
    Entries: TArray<TRAClientLeaderboardEntry>;
    ErrorMessage, ServerCode: string;
    HTTPStatus, ResultCode: Integer;
  end;

  TRALeaderboardEntriesReceived = reference to procedure(const Result: TRALeaderboardEntriesResult);

  TRAQueryStatus = record
    Success: Boolean;
    ErrorMessage, ServerCode: string;
    HTTPStatus, ResultCode: Integer;
  end;

  TRAIntegrationVersionReceived = reference to procedure(const Status: TRAQueryStatus; const MinimumVersion: string);

  TRAClientLoginResult = record
    Status: TRAQueryStatus;
    User: TRALoginInfo;
  end;

  TRAClientLoginCompleted = reference to procedure(const Result: TRAClientLoginResult);

  TRAListQueryResult<T> = record
    Status: TRAQueryStatus;
    Entries: TArray<T>;
  end;

  TRAListQueryCompleted<T> = reference to procedure(const Result: TRAListQueryResult<T>);

  TRASubsetInfo = record
    ID: Cardinal;
    Title, BadgeName, BadgeURL: string;
    AchievementCount, LeaderboardCount: Cardinal;
  end;

  TRAUserGameSummary = record
    CoreAchievements, UnofficialAchievements, UnlockedAchievements, UnsupportedAchievements: Cardinal;
    CorePoints, UnlockedPoints: Cardinal;
    BeatenTime, CompletedTime: Int64;
  end;

  TRAMediaKind = (LoadedGame, OtherGame, Unrecognized, Unhashable);

  TRAMediaInfo = record
    Hash: string;
    GameID: Cardinal;
    Kind: TRAMediaKind;
  end;

  TRAMediaChangeState = (Changed, NoGameLoaded, Aborted, Failed, HardcoreDisabled);

  TRAMediaChangeResult = record
    State: TRAMediaChangeState;
    Media: TRAMediaInfo;
    ErrorMessage, ServerCode: string;
    HTTPStatus, ResultCode: Integer;
  end;

  TRAMediaHasher = reference to function(ConsoleID: Cardinal; const Path: string; out Hash: string): Boolean;

  TRAMediaChanged = reference to procedure(const Change: TRAMediaChangeResult);

  IRAAsyncOperation = interface
    ['{E882B977-D002-4394-8AC1-2894CB1EA52D}']
    procedure Cancel;
  end;

  IRAMediaChange = IRAAsyncOperation;

  IRAGameLoad = IRAAsyncOperation;

  IRALogin = IRAAsyncOperation;

  IRAQuery = IRAAsyncOperation;

  IRALeaderboardEntriesRequest = IRAQuery;

  TRAGameLoadPhase = (Idle, FetchingGame, StartingSession, AwaitingLogin, IdentifyingGame);

  // Ordinals match RC_CLIENT_LOAD_GAME_STATE_*. FetchingGameData and Aborted are transient in upstream.
  TRAGameLoadState = (None, AwaitingLogin, IdentifyingGame, FetchingGameData, StartingSession, Done, Aborted);

  TRAGameLoadResult = record
    Success: Boolean;
    Game: TRAGameData;
    GameHash: string;
    HashConsoleID: Cardinal;
    TriedHashes: TArray<string>;
    ErrorMessage, ServerCode: string;
    HTTPStatus, ResultCode: Integer;
  end;

  TRAGameLoaded = reference to procedure(const Load: TRAGameLoadResult);

  TRAIdentifyUnknownHash = reference to function(ConsoleID: Cardinal; const Hash: string): Cardinal;

  TRASpectatorMode = (Disabled, Enabled, Locked);

  TRASession = class;

  IRAExternalSession = interface
    ['{2C777453-80DA-491E-BE49-F957A3E98A2D}']
    function GetSession: TRASession;
    // The provider keeps the returned session alive while this interface is referenced.
    property Session: TRASession read GetSession;
  end;

  TRASession = class
  private
    type
      TUnlockState = record
        Flags: Byte;
        CasualTime, HardcoreTime, PublicTime: Int64;
      end;

      TSubsetCompletion = (None, Pending, Shown);

      TPending = record
        Event: TRARuntimeEvent;
        CreatedAt, Generation: UInt64;
        GameHash: string;
        Hardcore: Boolean;
        Attempts: Cardinal;
        RetryAt, RetryOrder: UInt64;
      end;

      TPendingPing = record
        GameGeneration, AccountGeneration, HostRevision: UInt64;
        GameID: Cardinal;
        GameHash, Host: string;
        Hardcore, ShareRichPresence: Boolean;
        OverrideMessage: TRARichPresenceOverride;
      end;

      TAsyncOperation = class(TInterfacedObject, IRAAsyncOperation)
      private
        FState: Integer;
      public
        procedure Cancel;
        function Canceled: Boolean;
        function Finish: Boolean;
      end;

      TMediaPathHash = record
        Hash: string;
        Readers: TRAMediaHashOptions;
        Hasher: TRAMediaHasher;
        FromLoad: Boolean;
      end;

      TPendingMedia = record
        Hash, Path: string;
        Data: TBytes;
        HashOptions: TRAMediaHashOptions;
        Hasher: TRAMediaHasher;
        HashRevision: UInt64;
        Completed: TRAMediaChanged;
      // The interface keeps the ticket alive even if the caller releases its copy.
        Handle: IRAMediaChange;
        Ticket: TAsyncOperation;
        HadGame: Boolean;
        Generation: UInt64;
      end;

      TBuildQueryForm = reference to function(const Credentials: TRACredentials): string;

      TReadQuery = reference to procedure(Response: TJSONObject);

      TCompleteQuery = reference to procedure(const Status: TRAQueryStatus);

      TReadQueryList<T> = reference to function(Response: TJSONObject): TArray<T>;

      TPendingLogin = record
        HostRevision: UInt64;
        Form: string;
        Completed: TRAClientLoginCompleted;
        Handle: IRALogin;
        Ticket: TAsyncOperation;
      end;

      TPendingQuery = record
        AccountGeneration, HostRevision: UInt64;
        Form, ValidationError: string;
        BuildForm: TBuildQueryForm;
        Read: TReadQuery;
        Completed: TCompleteQuery;
        Handle: IRAQuery;
        Ticket: TAsyncOperation;
      end;

      TGameHashEntry = record
        Media: TRAMediaInfo;
        IdentifiedByClient: Boolean;
      end;

      TPendingLoad = record
        Hash, Path: string;
        ConsoleID, HashConsoleID: Cardinal;
        Identify: Boolean;
        Data: TBytes;
        HashOptions: TRAMediaHashOptions;
        HashRevision: UInt64;
        HashIterator: IRAMediaHashIterator;
        HashCursor: Integer;
        TriedHashes: TArray<string>;
        Generation, HostRevision: UInt64;
        Phase: TRAGameLoadPhase;
        Game: TRAGameData;
        Started: TRAStartSession;
        WaitingForMemory: Boolean;
        Completed: TRAGameLoaded;
        Handle: IRAGameLoad;
        Ticket: TAsyncOperation;
      end;
  private
    FPost: TRAPost;
    FHostedPost: TRAHostedPost;
    FHost, FImageHost: string;
    FHostRevision: UInt64;
    FExternalSession: IRAExternalSession;
    FExternalHost: TRASession;
    FReadMemory: TRAMemoryRead;
    FAllowBackgroundMemoryReads: Boolean;
    FLogLevel: TRAClientLogLevel;
    FLogCallback: TRAClientLog;
    FClientEventHandler: TRAClientEventHandler;
    FCanSubmitAchievement, FCanSubmitLeaderboard: TRAClientSubmissionFilter;
    FGameSetsResponseHandler: TRAGameSetsResponseHandler;
    FClientEvents: TQueue<TRARuntimeEvent>;
    FDispatchingClientEvents: Boolean;
    FClock, FHostClock: TRAClock;
    FClockConfigured: Boolean;
    FUserData: Pointer;
    FUnixClock: TRAUnixClock;
    FStopwatch: TStopwatch;
    FUser: TRALoginInfo;
    FLogin: TPendingLogin;
    FAccountGeneration: UInt64;
    FMedia: TRAMediaInfo;
    FGameLoaded, FUnknownGame: Boolean;
    FGameGeneration: UInt64;
    FLoad: TPendingLoad;
    FActivatingLoad: TAsyncOperation;
    FMediaDuringLoad: TPendingMedia;
    FMediaByHash: TDictionary<string, TGameHashEntry>;
    FIdentifyUnknownHash: TRAIdentifyUnknownHash;
    FHashByPath: TDictionary<string, TMediaPathHash>;
    FHashCallbacks: TRAMediaHashOptions;
    FHashCallbackRevision: UInt64;
    FPendingMedia: TQueue<TPendingMedia>;
    FQueries: TQueue<TPendingQuery>;
    FGame: TRAGameData;
    FRuntime: TRARuntime;
    FIndicators: TRAClientIndicators;
    FLock, FRuntimeLock: TCriticalSection;
    FAwarded: TDictionary<Cardinal, TUnlockState>;
    FSubsetCompletion: TArray<TSubsetCompletion>;
    FPending: TList<TPending>;
    FDelayedSubmissionCount: Integer;
    FReportedDisconnected: Boolean;
    FUnsupportedAchievements, FUnsupportedLeaderboards: TArray<Cardinal>;
    FInitialParseWarnings: TArray<string>;
    FNextPing, FNextPingOrder, FScheduledOrder, FNetworkRetryAt: UInt64;
    FNetworkPumping: Integer;
    FAllowLeaderboards, FPlayedSincePing, FShareRichPresence: Boolean;
    FRichPresenceOverride: TRARichPresenceOverride;
    FHardcoreEnabled, FWaitingForReset: Boolean;
    FEncoreModeEnabled, FUnofficialEnabled: Boolean;
    FSpectatorMode: TRASpectatorMode;
    FRequiredUnpausedFrames, FPauseDecay: Cardinal;
    function ExternalSession: IRAExternalSession;
    function DefaultClock: TRAClock;
    procedure ApplyHostClock(Host: TRASession; const Clock: TRAClock);
    function CanAttachExternalSession: Boolean;
    procedure Log(Level: TRAClientLogLevel; const MessageFormat: string; const Args: array of const);
    procedure LogRequestFailure(Level: TRAClientLogLevel; const Operation: string; HTTPStatus: Integer);
    function DescribeActiveGameSets: TArray<string>;
    function UnixTime: Int64;
    function NetworkRetryAt: UInt64;
    procedure DeferNetwork(Error: ERAServerError; AccountGeneration, HostRevision: UInt64);
    procedure SchedulePing(Deadline: UInt64);
    procedure RegisterGame(const Start: TRAStartSession; KeepInactiveAssets: Boolean);
    procedure RefreshModeAssets(InitialLoad: Boolean = False; KeepInactiveAssets: Boolean = False);
    function FindSubset(SubsetID: Cardinal): Integer;
    function DescribeAchievement(const Definition: TRAAchievementDefinition; RecentUnlockTime: Int64): TRAClientAchievement;
    function HasDelayedAward(ID: Cardinal): Boolean;
    function DescribeLeaderboard(const Definition: TRALeaderboardDefinition): TRAClientLeaderboard;
    function QueueLeaderboardEntries(ID, FirstEntry, Count: Cardinal; AroundUser: Boolean; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
    function QueueQuery(const Form, ValidationError: string; const Read: TReadQuery; const Completed: TCompleteQuery; AccountGeneration: UInt64 = 0; const BuildForm: TBuildQueryForm = nil): IRAQuery;
    function QueueListQuery<T>(const Form: string; const Read: TReadQueryList<T>; const Completed: TRAListQueryCompleted<T>; const ValidationError: string = ''; AccountGeneration: UInt64 = 0; const BuildForm: TBuildQueryForm = nil): IRAQuery;
    function ExecuteQuery(const Form, Host: string; const Read: TReadQuery; Ticket: TAsyncOperation; AccountGeneration, HostRevision: UInt64): TRAQueryStatus;
    procedure PumpQuery;
    function BeginLogin(const Form: string; const Completed: TRAClientLoginCompleted): IRALogin;
    function PumpLogin: Boolean;
    procedure ClearPendingSubmissions;
    procedure ClearAccount;
    function TakePendingLoadCallback: TRAGameLoaded;
    function SnapshotUser(out User: TRALoginInfo; out AccountGeneration: UInt64): Boolean;
    function Summarize(const AchievementSet: TRAAchievementSet): TRAUserGameSummary;
    procedure RecordSubsetCompletion(AchievementID: Cardinal);
    procedure AppendSubsetCompletionEvents(var Events: TArray<TRARuntimeEvent>);
    procedure QueuePendingGameEvents;
    function SelectGameAchievements(const Game: TRAGameData): TRAGameData;
    function TryFindAchievement(ID: Cardinal; out Definition: TRAAchievementDefinition): Boolean;
    function TryFindLeaderboard(ID: Cardinal; out Definition: TRALeaderboardDefinition): Boolean;
    function RecordLocalAward(ID: Cardinal): Boolean;
    procedure RememberAward(ID: Cardinal; Hardcore: Boolean; When: Int64; Historical: Boolean = False);
    function IsAwarded(ID: Cardinal): Boolean;
    procedure ApplyHardcoreMode(Enabled: Boolean);
    procedure AdvancePauseDelay;
    function QueueMediaChange(var Request: TPendingMedia): IRAMediaChange;
    procedure PumpMediaChange;
    function MediaHashKey(const Hash: string): string;
    function ResolveMedia(const Request: TPendingMedia; ConsoleID: Cardinal; HostRevision: UInt64): TRAMediaInfo;
    procedure MarkGameUnloaded;
    procedure SetUnknownGame(const TriedHashes: string; ConsoleID: Cardinal);
    procedure InitializeSession(const Post: TRAPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence: Boolean; const UnixClock: TRAUnixClock);
    procedure LoadInitialGame(const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; Hardcore: Boolean);
    function FetchGame(const Hash: string; ConsoleID: Cardinal; const Credentials: TRACredentials; Generation, HostRevision: UInt64; const Host: string; ClientGameID: Cardinal = 0): TRAGameData;
    procedure FetchPendingGame(var Load: TPendingLoad; var Loaded: TRAGameLoadResult; const Credentials: TRACredentials; const Host: string);
    function TryQueueClientIdentifiedLoad(const Load: TPendingLoad): Boolean;
    function QueueGameLoad(var Load: TPendingLoad): IRAGameLoad;
    function IsCurrentLoad(const Load: TPendingLoad): Boolean;
    procedure IdentifyGame(var Load: TPendingLoad; var Loaded: TRAGameLoadResult);
    function StartGame(const Game: TRAGameData; const Hash: string; Generation, HostRevision: UInt64; const Credentials: TRACredentials; const Host: string): TRAStartSession;
    procedure PrepareGame(const Game: TRAGameData; const Hash: string; const Started: TRAStartSession; NextPing: UInt64; ValidateMemory: Boolean = False);
    procedure PumpGameLoad;
    function DescribeLoad(const Load: TPendingLoad): TRAGameLoadResult;
    procedure ActivateWaitingGame(const ReadMemory: TRAMemoryRead);
    procedure ActivateLoadedGame(const Load: TPendingLoad; const Started: TRAStartSession; const ReadMemory: TRAMemoryRead);
    function ValidateLoadedAddresses(const Load: TPendingLoad; const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
    procedure MarkAssetUnsupported(const Event: TRARuntimeEvent);
    procedure LogInvalidAddress(const Event: TRARuntimeEvent);
    procedure FinishGameLoad(const Load: TPendingLoad; var Loaded: TRAGameLoadResult);
    function EvaluateFrameCore(const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
    procedure SendPing(const Ping: TPendingPing; const Credentials: TRACredentials);
    procedure ReconcileRestoredProgress;
    procedure QueueFrameEvents(const Events: TArray<TRARuntimeEvent>; First: Integer; FrameStart: Integer = -1);
    procedure QueueConnectionChange(WasDisconnected: Boolean);
    procedure QueueSubmissionEvent(const Pending: TPending; const Submission: TRASubmission);
    function TryBuildScoreboardEvent(ID: Cardinal; const Scores: TRALeaderboardResponse; out Event: TRARuntimeEvent): Boolean;
    function PollNativeEvents: TArray<TRARuntimeEvent>;
  protected
    class function DescribeMedia(const Hash: string; GameID, LoadedGameID: Cardinal): TRAMediaInfo; static;
    function TryGetMediaGameID(const Hash: string; out GameID: Cardinal): Boolean;
    function IdentifyUnknownHash(ConsoleID: Cardinal; const Hash: string): Cardinal;
    function GetHostRevision: UInt64;
    function PostRequest(const Form: string; const Host: string = ''): TJSONObject;
    class function RequestErrorResultCode(Error: Exception): Integer; static;
    procedure QueueClientEvent(const Event: TRARuntimeEvent);
    procedure DispatchClientEvents;
    function TakeNativeIndicatorEvents: TArray<TRARuntimeEvent>;
    procedure UnloadNativeGame;
    function NowMilliseconds: UInt64;
    function SynchronizeQueryAccount: Boolean; virtual;
    function UpdateQueryAccount(const User: TRALoginInfo): Boolean;
    function ReadRichPresenceMessage(out UsesGameTitle: Boolean): string;
    function ResolveHashCallbacks(const Overrides: TRAMediaHashOptions; out Revision: UInt64): TRAMediaHashOptions;
    function HashCallbacksWithLogging(const Options: TRAMediaHashOptions): TRAMediaHashOptions;
    function TryGetMediaPathHash(const Path: string; Revision: UInt64; const Readers: TRAMediaHashOptions; const Hasher: TRAMediaHasher; out Hash: string): Boolean;
    procedure CacheMediaPathHash(const Path, Hash: string; Revision: UInt64; const Readers: TRAMediaHashOptions; const Hasher: TRAMediaHasher; FromLoad: Boolean = False);
    function GetMemoryReader(Background: Boolean): TRAMemoryRead;
    function FrameMemoryReader(const ReadMemory: TRAMemoryRead): TRAMemoryRead;
    function MemoryReadsRequireEmulationThread: Boolean;
    function PumpNetworkCore(out Submission: TRASubmission): Boolean; virtual;
    procedure MemoryAccessChanged; virtual;
    function GetCurrentMedia: TRAMediaInfo; virtual;
    function GetDisconnected: Boolean; virtual;
    function GetEncoreModeEnabled: Boolean; virtual;
    function GetGame: TRAGameData; virtual;
    function GetGameLoadPhase: TRAGameLoadPhase; virtual;
    function GetGameLoadState: TRAGameLoadState; virtual;
    class function DescribeGameLoadState(Phase: TRAGameLoadPhase; HasGame: Boolean): TRAGameLoadState; static;
    function GetGameLoaded: Boolean; virtual;
    function GetHardcoreEnabled: Boolean; virtual;
    function GetResetRequired: Boolean; virtual;
    function GetSpectatorMode: TRASpectatorMode; virtual;
    function GetUnofficialEnabled: Boolean; virtual;
    function GetUnsupportedAchievements: TArray<Cardinal>; virtual;
    function GetUnsupportedLeaderboards: TArray<Cardinal>; virtual;
  public
    // Opening and pumping the network belong to a single network worker.
    constructor Create(const Post: TRAPost; const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; AllowCasualLeaderboards: Boolean = False; const Clock: TRAClock = nil; ShareRichPresence: Boolean = True; Hardcore: Boolean = False; const UnixClock: TRAUnixClock = nil); overload;
    constructor Create(const Post: TRAPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean = False; const Clock: TRAClock = nil; ShareRichPresence: Boolean = True; const UnixClock: TRAUnixClock = nil); overload;
    constructor CreateHosted(const Post: TRAHostedPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean = False; const Clock: TRAClock = nil; ShareRichPresence: Boolean = True; const UnixClock: TRAUnixClock = nil; const Host: string = ''; const ImageHost: string = ''); overload;
    constructor CreateHosted(const Post: TRAHostedPost; const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; AllowCasualLeaderboards: Boolean = False; const Clock: TRAClock = nil; ShareRichPresence: Boolean = True; Hardcore: Boolean = False; const UnixClock: TRAUnixClock = nil; const Host: string = ''; const ImageHost: string = ''); overload;
    // The caller owns data associated with this session.
    function GetUserData: Pointer;
    procedure SetUserData(Value: Pointer);
    // Switching clocks preserves existing timestamps. Use the same time base while a game or retry is active.
    // Passing nil uses the session's monotonic stopwatch.
    procedure SetGetTimeMillisecsFunction(const Clock: TRAClock);
    function GetHost: string;
    // Set the endpoint on the network worker. Hosted transports use it for subsequent requests.
    procedure SetHost(const Host: string); virtual;
    function GetImageHost: string;
    // Sets the fallback for image URLs resolved by subsequent operations. Empty uses the API host's default.
    procedure SetImageHost(const ImageHost: string);
    function GetUserAgentClause: string; overload; virtual;
    // Returns the full UTF-8 byte count, excluding the terminator.
    function GetUserAgentClause(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload;
    // Each queued hash operation keeps a snapshot. Non-nil per-operation callbacks override these defaults.
    procedure SetHashCallbacks(const Options: TRAMediaHashOptions); overload;
    procedure SetHashCallbacks(const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer = nil); overload;
    // Runs on the network worker for a single hash unrecognized by the server. Return zero to decline.
    procedure SetIdentifyUnknownHashHandler(const Handler: TRAIdentifyUnknownHash);
    function BeginLoadGame(const GameHash: string; ConsoleID: Cardinal; const Completed: TRAGameLoaded = nil): IRAGameLoad; virtual;
    function BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Completed: TRAGameLoaded = nil): IRAGameLoad; overload; virtual;
    function BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAGameLoaded = nil): IRAGameLoad; overload; virtual;
    destructor Destroy; override;
    // The callback runs synchronously on the caller or worker that emits the message.
    // Use a thread-safe callback. Its exceptions are isolated from session operations.
    procedure EnableLogging(Level: TRAClientLogLevel; const Callback: TRAClientLog); virtual;
    // The handler may run on the emulation or network worker and can still use the polling APIs.
    procedure SetEventHandler(const Handler: TRAClientEventHandler);
    // The native client calls the filters on the frame thread after updating local state.
    // Returning False or raising an exception prevents the server submission.
    procedure SetSubmissionFilters(const Achievement, Leaderboard: TRAClientSubmissionFilter);
    // The native client calls the handler on the thread fetching a valid game.
    // Response is borrowed for the call. Game contains a separate snapshot of the parsed data.
    procedure SetGameSetsResponseHandler(const Handler: TRAGameSetsResponseHandler);
    class function Login(const Post: TRAPost; const UserName, Password: string): TRACredentials; static;
    class function RenewLogin(const Post: TRAPost; const Credentials: TRACredentials): TRACredentials; static;
    function BeginLoginWithPassword(const UserName, Password: string; const Completed: TRAClientLoginCompleted = nil): IRALogin; virtual;
    function BeginLoginWithToken(const Credentials: TRACredentials; const Completed: TRAClientLoginCompleted = nil): IRALogin; virtual;
    function TryGetUserInfo(out User: TRALoginInfo): Boolean; virtual;
    function CanInitializeIntegration: Boolean;
    // Attach and detach on the network worker, before using the new session.
    function AttachExternalSession(const external: IRAExternalSession): Boolean;
    procedure DetachExternalSession(const external: IRAExternalSession);
    function BeginFetchIntegrationVersion(const Completed: TRAIntegrationVersionReceived): IRAQuery;
    // Aborts pending login and game loading callbacks on the calling thread.
    procedure Logout; virtual;
    // An overlapping or reentrant call returns False and leaves work queued.
    function PumpNetwork(out Submission: TRASubmission): Boolean; virtual;
    function PendingCount: Integer; virtual;
    // May be polled while emulation is paused or no game is loaded.
    function TryPollConnectionEvent(out Event: TRARuntimeEvent): Boolean; virtual;
    // EvaluateFrame also drains indicator events. Poll separately while emulation is paused.
    function PollIndicatorEvents: TArray<TRARuntimeEvent>; virtual;
    function TryGetSubsetInfo(SubsetID: Cardinal; out Info: TRASubsetInfo): Boolean; virtual;
    function CreateSubsetList: TArray<TRASubsetInfo>; virtual;
    function GetUserGameSummary: TRAUserGameSummary; virtual;
    function TryGetAchievementInfo(ID: Cardinal; out Info: TRAClientAchievement): Boolean; virtual;
    function TryGetNextAchievementInfo(AfterID: Cardinal; Bucket: TRAAchievementBucketKind; out Info: TRAClientAchievement): Boolean; virtual;
    function HasAchievements: Boolean; virtual;
    function CreateAchievementList(Categories: TRAAchievementCategories; Grouping: TRAAchievementGrouping): TArray<TRAAchievementBucket>; virtual;
    function TryGetLeaderboardInfo(ID: Cardinal; out Info: TRAClientLeaderboard): Boolean; virtual;
    function HasLeaderboards: Boolean; virtual;
    function CreateLeaderboardList(Grouping: TRALeaderboardGrouping): TArray<TRALeaderboardBucket>; virtual;
    // The network worker resolves queued requests and invokes completion callbacks.
    function BeginFetchLeaderboardEntries(ID, FirstEntry, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest; virtual;
    function BeginFetchLeaderboardEntriesAroundUser(ID, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest; virtual;
    function BeginFetchHashLibrary(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAHashLibraryEntry>): IRAQuery; virtual;
    function BeginFetchGameTitles(const GameIDs: array of Cardinal; const Completed: TRAListQueryCompleted<TRAGameTitle>): IRAQuery; virtual;
    function BeginFetchGameList(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAGameListEntry>): IRAQuery; virtual;
    function BeginFetchAllUserProgress(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAUserGameProgress>): IRAQuery; virtual;
    function GetUserSubsetSummary(SubsetID: Cardinal): TRAUserGameSummary; virtual;
    // The emulator acknowledges ResetRequired after resetting the emulated machine.
    procedure SetHardcoreEnabled(Enabled: Boolean); virtual;
    function SetSpectatorModeEnabled(Enabled: Boolean): Boolean; virtual;
    procedure SetEncoreModeEnabled(Enabled: Boolean); virtual;
    procedure SetUnofficialEnabled(Enabled: Boolean); virtual;
    function CanPause(out FramesRemaining: Cardinal): Boolean; virtual;
    procedure SetShareRichPresence(Value: Boolean); virtual;
    // Runs on the native network worker for pings while sharing is enabled.
    // Return False to keep the game's message, or True to use MessageText.
    procedure SetRichPresenceOverride(const Handler: TRARichPresenceOverride);
    function HasRichPresence: Boolean; virtual;
    // Returns the most recent emulation-thread text, with a title fallback when it is empty.
    function GetRichPresenceMessage: string; overload; virtual;
    // Returns the full script length, or the bytes copied for a game title fallback.
    function GetRichPresenceMessage(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt; overload; virtual;
    function IsProcessingRequired: Boolean; virtual;

    // The network worker resolves queued changes and invokes completion callbacks.
    function BeginChangeMedia(const GameHash: string; const Completed: TRAMediaChanged = nil): IRAMediaChange; virtual;
    function BeginIdentifyAndChangeMedia(const Path: string; const Hasher: TRAMediaHasher; const Completed: TRAMediaChanged = nil): IRAMediaChange; overload; virtual;
    function BeginIdentifyAndChangeMedia(const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAMediaChanged = nil): IRAMediaChange; overload; virtual;
    procedure AddGameHash(const Hash: string; GameID: Cardinal); virtual;
    procedure LoadUnknownGame(const TriedHashes: string; ConsoleID: Cardinal = 0); virtual;
    procedure UnloadGame; virtual;

    // Configure the reader and the background policy on the network worker.
    // The registered reader is used when EvaluateFrame or Idle has no frame-specific reader.
    procedure SetReadMemoryFunction(const ReadMemory: TRAMemoryRead);
    // The registered reader must be thread-safe when background reads are enabled.
    procedure SetAllowBackgroundMemoryReads(Allowed: Boolean);
    // The caller owns the emulation thread and must stop both workers before freeing the session.
    function EvaluateFrame(const ReadMemory: TRAMemoryRead = nil): TArray<TRARuntimeEvent>; virtual;
    // Run emulation-thread work, including deferred address validation, without advancing a frame.
    procedure Idle(const ReadMemory: TRAMemoryRead = nil); virtual;
    // These bounded operations use the rcheevos interchange format.
    function ProgressSize: NativeUInt; virtual;
    // Provide at least ProgressSize writable bytes or a complete trusted snapshot.
    function SerializeProgress(Buffer: PByte): Integer;
    function DeserializeProgress(Buffer: PByte): Integer;
    function SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer; virtual;
    function DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer; virtual;
    function CaptureProgress: TBytes; virtual;
    function RestoreProgress(const Data: TBytes): Boolean; virtual;
    procedure Reset; virtual;
    property UserData: Pointer read GetUserData write SetUserData;
    property Game: TRAGameData read GetGame;
    property GameLoaded: Boolean read GetGameLoaded;
    property Disconnected: Boolean read GetDisconnected;
    property HardcoreEnabled: Boolean read GetHardcoreEnabled;
    property ResetRequired: Boolean read GetResetRequired;
    property SpectatorMode: TRASpectatorMode read GetSpectatorMode;
    property EncoreModeEnabled: Boolean read GetEncoreModeEnabled write SetEncoreModeEnabled;
    property UnofficialEnabled: Boolean read GetUnofficialEnabled write SetUnofficialEnabled;
    property GameLoadPhase: TRAGameLoadPhase read GetGameLoadPhase;
    property GameLoadState: TRAGameLoadState read GetGameLoadState;
    property CurrentMedia: TRAMediaInfo read GetCurrentMedia;
    property UnsupportedAchievements: TArray<Cardinal> read GetUnsupportedAchievements;
    property UnsupportedLeaderboards: TArray<Cardinal> read GetUnsupportedLeaderboards;
  end;

  TRAExternalSession = class(TInterfacedObject, IRAExternalSession)
  private
    FSession: TRASession;
    function GetSession: TRASession;
  public
    // The wrapper takes ownership of Session.
    constructor Create(Session: TRASession);
    destructor Destroy; override;
  end;

implementation

uses
  System.DateUtils, System.Generics.Defaults, System.Math, System.Net.HttpClient,
  System.Net.URLClient, RA.Conditions, RA.Console, RA.Errors, RA.Leaderboards,
  RA.RCheevosProgress, RA.Streams, RA.Trigger, RA.Utils;

const
  MillisecondsPerSecond = 1000;
  InitialPingDelay = 30 * MillisecondsPerSecond;
  PingPeriod = 120 * MillisecondsPerSecond;
  MaxPingMessageBytes = 255;
  MaxAchievementBadgeNameBytes = 7;
  MaxSubsetBadgeNameBytes = 15;
  MaxGameTitleBadgeNameBytes = 15;
  MaxHashLibraryHashBytes = 32;

const
  SoftcoreUnlocked = 1;
  HardcoreUnlocked = 2;
  MinimumUnpausedFrames = 20;
  MaximumUnpausedFrames = 300;
  PauseDecayMultiplier = 4;
  RAClientWarningAchievement = 101000001;
  RecentUnlockDelay = 10 * 60;
  ImmediateRetryAttempts = 1;

constructor TRAExternalSession.Create(Session: TRASession);
begin
  inherited Create;
  if Session = nil then
    raise EArgumentNilException.Create('External RetroAchievements session is required');
  FSession := Session;
end;

destructor TRAExternalSession.Destroy;
begin
  FSession.Free;
  inherited;
end;

function TRAExternalSession.GetSession: TRASession;
begin
  Result := FSession;
end;

function TRASession.ExternalSession: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Result := FExternalSession;
  finally
    FLock.Release;
  end;
end;

function TRASession.CanAttachExternalSession: Boolean;
begin
  Result := (FExternalHost = nil) and (FExternalSession = nil) and not FGameLoaded and
    (FLoad.Phase = TRAGameLoadPhase.Idle) and (FLogin.Ticket = nil) and (FUser.Credentials.UserName = '');
end;

function TRASession.AttachExternalSession(const external: IRAExternalSession): Boolean;
var
  Backend: TRASession;
  Hardcore, Encore, Unofficial, Spectator, ShareRichPresence, AllowLeaderboards: Boolean;
  LogLevel: TRAClientLogLevel;
  LogCallback: TRAClientLog;
  ReadMemory: TRAMemoryRead;
  Clock: TRAClock;
  ClockConfigured: Boolean;
  HashCallbacks: TRAMediaHashOptions;
  UnknownHashHandler: TRAIdentifyUnknownHash;
  ClientEventHandler: TRAClientEventHandler;
  BackgroundReads: Boolean;
  Host, ImageHost: string;
begin
  Result := False;
  if external = nil then
    Exit;
  Backend := external.Session;
  if (Backend = nil) or (Backend = Self) or not CanInitializeIntegration then
    Exit;

  Backend.FLock.Acquire;
  try
    if (Backend.FExternalHost <> nil) or (Backend.FExternalSession <> nil) or Backend.FGameLoaded or
      (Backend.FLogin.Ticket <> nil) or (Backend.FLoad.Phase <> TRAGameLoadPhase.Idle) then
      Exit;
    Backend.FExternalHost := Self;
  finally
    Backend.FLock.Release;
  end;

  try
    FLock.Acquire;
    try
      if not CanAttachExternalSession then
        Exit;
      Hardcore := FHardcoreEnabled;
      Encore := FEncoreModeEnabled;
      Unofficial := FUnofficialEnabled;
      Spectator := FSpectatorMode <> TRASpectatorMode.Disabled;
      ShareRichPresence := FShareRichPresence;
      AllowLeaderboards := FAllowLeaderboards;
      LogLevel := FLogLevel;
      LogCallback := FLogCallback;
      ReadMemory := FReadMemory;
      Clock := FClock;
      ClockConfigured := FClockConfigured;
      HashCallbacks := FHashCallbacks;
      UnknownHashHandler := FIdentifyUnknownHash;
      ClientEventHandler := FClientEventHandler;
      BackgroundReads := FAllowBackgroundMemoryReads;
      Host := FHost;
      ImageHost := FImageHost;
    finally
      FLock.Release;
    end;

    Backend.FLock.Acquire;
    try
      Backend.FAllowLeaderboards := AllowLeaderboards;
    finally
      Backend.FLock.Release;
    end;
    if ClockConfigured then
    begin
      if not Assigned(Clock) then
        Clock := DefaultClock();
      Backend.ApplyHostClock(Self, Clock);
    end;
    Backend.SetHardcoreEnabled(Hardcore);
    Backend.SetEncoreModeEnabled(Encore);
    Backend.SetUnofficialEnabled(Unofficial);
    Backend.SetSpectatorModeEnabled(Spectator);
    Backend.SetShareRichPresence(ShareRichPresence);
    Backend.SetReadMemoryFunction(ReadMemory);
    Backend.SetHashCallbacks(HashCallbacks);
    Backend.SetIdentifyUnknownHashHandler(UnknownHashHandler);
    Backend.SetAllowBackgroundMemoryReads(BackgroundReads);
    if not SameText(Host, RAAPIHost) then
      Backend.SetHost(Host);
    if ImageHost <> '' then
      Backend.SetImageHost(ImageHost);
    Backend.EnableLogging(LogLevel, LogCallback);
    Backend.SetEventHandler(ClientEventHandler);

    FLock.Acquire;
    try
      if not CanAttachExternalSession then
        Exit;
      FExternalSession := external;
      Result := True;
    finally
      FLock.Release;
    end;
  finally
    if not Result then
    begin
      Backend.ApplyHostClock(Self, nil);
      Backend.SetIdentifyUnknownHashHandler(nil);
      Backend.FLock.Acquire;
      try
        Backend.FExternalHost := nil;
      finally
        Backend.FLock.Release;
      end;
    end;
  end;
end;

procedure TRASession.DetachExternalSession(const external: IRAExternalSession);
var
  Current: IRAExternalSession;
  Backend: TRASession;
begin
  if external = nil then
    Exit;
  FLock.Acquire;
  try
    if FExternalSession <> external then
      Exit;
    Current := FExternalSession;
    FExternalSession := nil;
  finally
    FLock.Release;
  end;
  Backend := Current.Session;
  try
    Backend.ApplyHostClock(Self, nil);
    Backend.SetEventHandler(nil);
    Backend.SetReadMemoryFunction(nil);
    Backend.SetHashCallbacks(Default(TRAMediaHashOptions));
    Backend.SetIdentifyUnknownHashHandler(nil);
    Backend.SetAllowBackgroundMemoryReads(False);
  finally
    Backend.FLock.Acquire;
    try
      Backend.FExternalHost := nil;
    finally
      Backend.FLock.Release;
    end;
  end;
end;

procedure TRASession.EnableLogging(Level: TRAClientLogLevel; const Callback: TRAClientLog);
var
  Previous: TRAClientLog;
begin
  FLock.Acquire;
  try
    Previous := FLogCallback;
    if (Level = TRAClientLogLevel.None) or not Assigned(Callback) then
    begin
      FLogLevel := TRAClientLogLevel.None;
      FLogCallback := nil;
    end
    else
    begin
      FLogLevel := Level;
      FLogCallback := Callback;
    end;
  finally
    FLock.Release;
  end;
  Previous := nil;
  var external := ExternalSession;
  if external <> nil then
    external.Session.EnableLogging(Level, Callback);
end;

procedure TRASession.SetEventHandler(const Handler: TRAClientEventHandler);
var
  Previous: TRAClientEventHandler;
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Previous := FClientEventHandler;
    FClientEventHandler := Handler;
    FClientEvents.Clear;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  Previous := nil;
  if external <> nil then
    external.Session.SetEventHandler(Handler);
end;

procedure TRASession.SetSubmissionFilters(const Achievement, Leaderboard: TRAClientSubmissionFilter);
var
  PreviousAchievement, PreviousLeaderboard: TRAClientSubmissionFilter;
begin
  FLock.Acquire;
  try
    PreviousAchievement := FCanSubmitAchievement;
    PreviousLeaderboard := FCanSubmitLeaderboard;
    FCanSubmitAchievement := Achievement;
    FCanSubmitLeaderboard := Leaderboard;
  finally
    FLock.Release;
  end;
  PreviousAchievement := nil;
  PreviousLeaderboard := nil;
end;

procedure TRASession.SetGameSetsResponseHandler(const Handler: TRAGameSetsResponseHandler);
var
  Previous: TRAGameSetsResponseHandler;
begin
  FLock.Acquire;
  try
    Previous := FGameSetsResponseHandler;
    FGameSetsResponseHandler := Handler;
  finally
    FLock.Release;
  end;
  Previous := nil;
end;

procedure TRASession.QueueClientEvent(const Event: TRARuntimeEvent);
var
  Notification: TRARuntimeEvent;
begin
  FLock.Acquire;
  try
    if not Assigned(FClientEventHandler) then
      Exit;
    Notification := Event;
    if Length(Event.Scoreboard.TopEntries) <> 0 then
      Notification.Scoreboard.TopEntries := Copy(Event.Scoreboard.TopEntries);
    FClientEvents.Enqueue(Notification);
  finally
    FLock.Release;
  end;
end;

procedure TRASession.DispatchClientEvents;
var
  Event: TRARuntimeEvent;
  Handler: TRAClientEventHandler;
begin
  FLock.Acquire;
  try
    if FDispatchingClientEvents or (FClientEvents.Count = 0) then
      Exit;
    FDispatchingClientEvents := True;
  finally
    FLock.Release;
  end;

  while True do
  begin
    FLock.Acquire;
    try
      if FClientEvents.Count = 0 then
      begin
        FDispatchingClientEvents := False;
        Exit;
      end;
      Event := FClientEvents.Dequeue;
      Handler := FClientEventHandler;
    finally
      FLock.Release;
    end;

    if Assigned(Handler) then
    try
      Handler(Event);
    except
      on Exception do
    end;
    Handler := nil;
  end;
end;

procedure TRASession.QueueFrameEvents(const Events: TArray<TRARuntimeEvent>; First, FrameStart: Integer);
type
  TOrderedEvent = record
    Order, Index: Integer;
    Event: TRARuntimeEvent;
  end;
var
  Event: TRARuntimeEvent;
  Achievement: TRAAchievementDefinition;
  OrderedEvent: TOrderedEvent;
  FrameEvents: TList<TOrderedEvent>;
begin
  if not Assigned(FClientEventHandler) then
    Exit;
  FrameEvents := nil;
  try
    for var Index := First to High(Events) do
    begin
      Event := Events[Index];
      case Event.Kind of
        TRARuntimeEventKind.AchievementTriggered:
          if TryFindAchievement(Event.ID, Achievement) then
            Event.Display := Achievement.Title;
        TRARuntimeEventKind.LeaderboardStarted, TRARuntimeEventKind.LeaderboardCanceled, TRARuntimeEventKind.LeaderboardTriggered, TRARuntimeEventKind.AchievementChallengeShow, TRARuntimeEventKind.AchievementChallengeHide, TRARuntimeEventKind.AchievementProgressShow, TRARuntimeEventKind.AchievementProgressHide, TRARuntimeEventKind.AchievementProgressUpdate, TRARuntimeEventKind.LeaderboardTrackerShow, TRARuntimeEventKind.LeaderboardTrackerHide, TRARuntimeEventKind.LeaderboardTrackerUpdate, TRARuntimeEventKind.GameCompleted, TRARuntimeEventKind.SubsetCompleted:
          ;
      else
        Continue;
      end;
      if (FrameStart < 0) or (Index < FrameStart) then
        QueueClientEvent(Event)
      else
      begin
        if FrameEvents = nil then
          FrameEvents := TList<TOrderedEvent>.Create;
        OrderedEvent.Order := FIndicators.FrameNotificationOrder(Event);
        OrderedEvent.Index := Index;
        OrderedEvent.Event := Event;
        FrameEvents.Add(OrderedEvent);
      end;
    end;
    if FrameEvents <> nil then
    begin
      if FrameEvents.Count > 1 then
        FrameEvents.Sort(TComparer<TOrderedEvent>.Construct(
          function(const Left, Right: TOrderedEvent): Integer
          begin
            Result := Left.Order - Right.Order;
            if Result = 0 then
              Result := Left.Index - Right.Index;
          end));
      for var Notification in FrameEvents do
        QueueClientEvent(Notification.Event);
    end;
  finally
    FrameEvents.Free;
  end;
end;

procedure TRASession.Log(Level: TRAClientLogLevel; const MessageFormat: string; const Args: array of const);
var
  Callback: TRAClientLog;
begin
  FLock.Acquire;
  try
    if Level > FLogLevel then
      Exit;
    Callback := FLogCallback;
  finally
    FLock.Release;
  end;
  if Assigned(Callback) then
  try
    Callback(Level, Format(MessageFormat, Args));
  except
    on Exception do
      Exit;
  end;
end;

procedure TRASession.LogRequestFailure(Level: TRAClientLogLevel; const Operation: string; HTTPStatus: Integer);
begin
  // The diagnostic stays independent of the request form and the server response body.
  if HTTPStatus <> 0 then
    Log(Level, '%s failed (HTTP %d)', [Operation, HTTPStatus])
  else
    Log(Level, '%s failed', [Operation]);
end;

function TRASession.GetUserData: Pointer;
begin
  FLock.Acquire;
  try
    Result := FUserData;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.SetUserData(Value: Pointer);
begin
  FLock.Acquire;
  try
    FUserData := Value;
  finally
    FLock.Release;
  end;
end;

function TRASession.DefaultClock: TRAClock;
var
  Stopwatch: TStopwatch;
begin
  Stopwatch := FStopwatch;
  Result :=
    function: UInt64
    begin
      Result := UInt64(Stopwatch.ElapsedMilliseconds);
    end;
end;

procedure TRASession.ApplyHostClock(Host: TRASession; const Clock: TRAClock);
var
  Previous: TRAClock;
begin
  FLock.Acquire;
  try
    if FExternalHost <> Host then
      Exit;
    Previous := FHostClock;
    FHostClock := Clock;
  finally
    FLock.Release;
  end;
  Previous := nil;
end;

procedure TRASession.SetGetTimeMillisecsFunction(const Clock: TRAClock);
var
  Previous: TRAClock;
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Previous := FClock;
    FClock := Clock;
    FClockConfigured := True;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  Previous := nil;
  if external <> nil then
  begin
    if Assigned(Clock) then
      external.Session.ApplyHostClock(Self, Clock)
    else
      external.Session.ApplyHostClock(Self, DefaultClock());
  end;
end;

function TRASession.NowMilliseconds: UInt64;
var
  Clock: TRAClock;
begin
  FLock.Acquire;
  try
    Clock := FHostClock;
    if not Assigned(Clock) then
      Clock := FClock;
  finally
    FLock.Release;
  end;
  if Assigned(Clock) then
    Result := Clock()
  else
    Result := UInt64(FStopwatch.ElapsedMilliseconds);
end;

function TRASession.UnixTime: Int64;
begin
  if Assigned(FUnixClock) then
    Result := FUnixClock()
  else
    Result := DateTimeToUnix(Now, False);
end;

function HostChangedStatus: TRAQueryStatus;
begin
  Result := Default(TRAQueryStatus);
  Result.ResultCode := RAErrorAborted;
  Result.ServerCode := 'aborted';
  Result.ErrorMessage := 'RetroAchievements server changed during request';
end;

class function TRASession.RequestErrorResultCode(Error: Exception): Integer;
begin
  if Error is ERAProtocolError then
    Exit(ERAProtocolError(Error).ResultCode);
  if Error is ENetException then
    Exit(RAErrorNoResponse);
  if Error is EArgumentException then
    Exit(RAErrorInvalidState);
  Result := RAErrorAPIFailure;
end;

function Retryable(Error: ERAServerError): Boolean;
begin
  Result := (Error.StatusCode = 0) or (Error.StatusCode = 408) or
    (Error.StatusCode = 429) or (Error.StatusCode >= 500) or
    ((Error is ERAInvalidResponse) and (Error.StatusCode >= 200) and (Error.StatusCode < 300));
end;

function RetryableSubmission(Error: ERAServerError): Boolean;
begin
  case Error.StatusCode of
    RAServerResponseClientError:
      Result := False;
    RAServerResponseRetryableClientError, 429, 502..504, 521..525:
      Result := True;
  else
    Result := not Error.HasResponseMessage;
  end;
end;

function TRASession.NetworkRetryAt: UInt64;
begin
  FLock.Acquire;
  try
    Result := FNetworkRetryAt;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.DeferNetwork(Error: ERAServerError; AccountGeneration, HostRevision: UInt64);
var
  Seconds: Cardinal;
  RetryAt: UInt64;
begin
  Seconds := Error.RetryAfter;
  if (Error.StatusCode = 429) and (Seconds = 0) then
    Seconds := 2;
  if (Seconds = 0) or not Retryable(Error) then
    Exit;
  RetryAt := NowMilliseconds + UInt64(Seconds) * MillisecondsPerSecond;
  FLock.Acquire;
  try
    if (AccountGeneration = FAccountGeneration) and (HostRevision = FHostRevision) then
      FNetworkRetryAt := Max(FNetworkRetryAt, RetryAt);
  finally
    FLock.Release;
  end;
end;

function RetryDelay(Attempts: Cardinal): UInt64;
begin
  case Attempts of
    2..8:
      Result := (UInt64(1) shl (Attempts - 2)) * MillisecondsPerSecond;
  else
    Result := 120 * MillisecondsPerSecond;
  end;
end;

procedure TRASession.InitializeSession(const Post: TRAPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence: Boolean; const UnixClock: TRAUnixClock);
begin
  if not Assigned(Post) and not Assigned(FHostedPost) then
    raise EArgumentNilException.Create('RetroAchievements transport is required');
  FPost := Post;
  if FHost = '' then
    FHost := RAAPIHost;
  if FImageHost <> '' then
    FImageHost := NormalizeRAHost(FImageHost);
  FClock := Clock;
  FClockConfigured := Assigned(Clock);
  FUnixClock := UnixClock;
  FStopwatch := TStopwatch.StartNew;
  FAccountGeneration := 1;
  if (Credentials.UserName <> '') and (Credentials.Token <> '') then
  begin
    FUser.Credentials := Credentials;
    FUser.DisplayName := Credentials.UserName;
    FUser.AvatarURL := BuildRAImageURL(TRAImageKind.User, Credentials.UserName, RAImageHostForAPI(FHost, FImageHost));
  end;
  FAllowLeaderboards := AllowCasualLeaderboards;
  FRequiredUnpausedFrames := MinimumUnpausedFrames;
  FShareRichPresence := ShareRichPresence;
  FLock := TCriticalSection.Create;
  FRuntimeLock := TCriticalSection.Create;
  FIndicators := TRAClientIndicators.Create;
  FClientEvents := TQueue<TRARuntimeEvent>.Create;
  FAwarded := TDictionary<Cardinal, TUnlockState>.Create;
  FPending := TList<TPending>.Create;
  FPendingMedia := TQueue<TPendingMedia>.Create;
  FQueries := TQueue<TPendingQuery>.Create;
  FMediaByHash := TDictionary<string, TGameHashEntry>.Create;
  FHashByPath := TDictionary<string, TMediaPathHash>.Create;
end;

constructor TRASession.Create(const Post: TRAPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence: Boolean; const UnixClock: TRAUnixClock);
begin
  inherited Create;
  InitializeSession(Post, Credentials, AllowCasualLeaderboards, Clock, ShareRichPresence, UnixClock);
end;

constructor TRASession.Create(const Post: TRAPost; const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence, Hardcore: Boolean; const UnixClock: TRAUnixClock);
begin
  inherited Create;
  InitializeSession(Post, Credentials, AllowCasualLeaderboards, Clock, ShareRichPresence, UnixClock);
  LoadInitialGame(Credentials, GameHash, ConsoleID, Hardcore);
end;

constructor TRASession.CreateHosted(const Post: TRAHostedPost; const Credentials: TRACredentials; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence: Boolean; const UnixClock: TRAUnixClock; const Host, ImageHost: string);
begin
  inherited Create;
  FHost := NormalizeRAHost(Host);
  FImageHost := ImageHost;
  FHostedPost := Post;
  InitializeSession(nil, Credentials, AllowCasualLeaderboards, Clock, ShareRichPresence, UnixClock);
end;

constructor TRASession.CreateHosted(const Post: TRAHostedPost; const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; AllowCasualLeaderboards: Boolean; const Clock: TRAClock; ShareRichPresence, Hardcore: Boolean; const UnixClock: TRAUnixClock; const Host, ImageHost: string);
begin
  inherited Create;
  FHost := NormalizeRAHost(Host);
  FImageHost := ImageHost;
  FHostedPost := Post;
  InitializeSession(nil, Credentials, AllowCasualLeaderboards, Clock, ShareRichPresence, UnixClock);
  LoadInitialGame(Credentials, GameHash, ConsoleID, Hardcore);
end;

function TRASession.GetHost: string;
begin
  FLock.Acquire;
  try
    Result := FHost;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetHostRevision: UInt64;
begin
  FLock.Acquire;
  try
    Result := FHostRevision;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetImageHost: string;
begin
  FLock.Acquire;
  try
    Result := RAImageHostForAPI(FHost, FImageHost);
  finally
    FLock.Release;
  end;
end;

procedure TRASession.SetImageHost(const ImageHost: string);
var
  URL: string;
  external: IRAExternalSession;
begin
  URL := ImageHost;
  if URL <> '' then
    URL := NormalizeRAHost(URL);
  FLock.Acquire;
  try
    FImageHost := URL;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  if external <> nil then
    external.Session.SetImageHost(URL);
end;

procedure TRASession.SetHost(const Host: string);
var
  URL: string;
  external: IRAExternalSession;
begin
  URL := NormalizeRAHost(Host);
  FLock.Acquire;
  try
    if FHost = URL then
      Exit;
    if SameText(URL, RAAPIHost) or SameText(URL, 'http://retroachievements.org') then
      FImageHost := '';
    FHost := URL;
    Inc(FHostRevision);
    FNetworkRetryAt := 0;
    ClearPendingSubmissions;
    if FLoad.Phase <> TRAGameLoadPhase.Idle then
    begin
      FLoad.HostRevision := FHostRevision;
      FLoad.Game := Default(TRAGameData);
      FLoad.Started := Default(TRAStartSession);
      FLoad.WaitingForMemory := False;
      if FLoad.Identify then
      begin
        FLoad.Hash := '';
        FLoad.HashConsoleID := 0;
        FLoad.HashCursor := 0;
        FLoad.HashIterator := nil;
        FLoad.TriedHashes := nil;
        if FLoad.Phase <> TRAGameLoadPhase.AwaitingLogin then
          FLoad.Phase := TRAGameLoadPhase.IdentifyingGame;
      end
      else if FLoad.Phase = TRAGameLoadPhase.StartingSession then
        FLoad.Phase := TRAGameLoadPhase.FetchingGame;
    end;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  if external <> nil then
    external.Session.SetHost(URL);
  DispatchClientEvents;
end;

function TRASession.GetUserAgentClause: string;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUserAgentClause);
  Result := RAUserAgentClause;
end;

function TRASession.GetUserAgentClause(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(0);
  Result := CopyRAUTF8Text(GetUserAgentClause, Buffer, BufferSize);
end;

function TRASession.PostRequest(const Form, Host: string): TJSONObject;
begin
  if Assigned(FHostedPost) then
  begin
    if Host = '' then
      Result := FHostedPost(BuildRARequestURL(GetHost), Form)
    else
      Result := FHostedPost(BuildRARequestURL(Host), Form);
  end
  else
    Result := FPost(Form);
  if Result = nil then
  begin
    var Error := ERAInvalidResponse.Create('', '', 0);
    Error.Message := RAErrorMessage(RAErrorNoResponse);
    raise Error;
  end;
end;

procedure TRASession.LoadInitialGame(const Credentials: TRACredentials; const GameHash: string; ConsoleID: Cardinal; Hardcore: Boolean);
var
  Game: TRAGameData;
  Started: TRAStartSession;
begin
  FHardcoreEnabled := Hardcore;
  try
    Game := FetchGame(GameHash, ConsoleID, Credentials, FGameGeneration, FHostRevision, FHost);
  except
    on Error: ERAServerError do
    begin
      if SameText(Error.Code, 'not_found') or SameText(Error.Code, 'unknown_game') then
        raise ERARomNotRecognized.Create('RetroAchievements does not recognize this ROM');
      raise;
    end;
  end;
  if Game.ID = 0 then
    raise ERARomNotRecognized.Create('RetroAchievements does not recognize this ROM');
  Started := StartGame(Game, GameHash, FGameGeneration, FHostRevision, Credentials, FHost);
  PrepareGame(Game, GameHash, Started, NowMilliseconds + InitialPingDelay);
  FGameLoaded := True;
end;

function TRASession.FetchGame(const Hash: string; ConsoleID: Cardinal; const Credentials: TRACredentials; Generation, HostRevision: UInt64; const Host: string; ClientGameID: Cardinal): TRAGameData;
var
  Response: TJSONObject;
  Handler: TRAGameSetsResponseHandler;
  Snapshot: TRAGameData;
begin
  if Credentials.UserName = '' then
    raise ERAProtocolError.Create('RetroAchievements login is required to load a game');
  Log(TRAClientLogLevel.Verbose, 'Fetching data for hash %s', [Hash]);
  Response := PostRequest(TRARequest.FetchGameSets(Credentials, ClientGameID, Hash), Host);
  try
    Result := ReadRAGameData(Response, GetImageHost);
    Result.Hash := Hash;
    if Result.ID = 0 then
      Exit;
    if (ClientGameID <> 0) and (Result.ID <> ClientGameID) then
      raise ERAProtocolError.Create('RetroAchievements returned a different game');
    if (ConsoleID <> 0) and (Result.ConsoleID <> ConsoleID) then
    begin
      Log(TRAClientLogLevel.Warning, 'Data for game %u is for console %u, expecting console %u',
        [Result.ID, Result.ConsoleID, ConsoleID]);
      raise ERAProtocolError.Create('RetroAchievements returned a different console');
    end;
    if Length(Result.Sets) = 0 then
      raise ERANoAchievementSets.Create('RetroAchievements response contained no achievement sets');
    Log(TRAClientLogLevel.Info, 'Identified game: %u "%s" (%s)', [Result.ID, Result.Title, Hash]);

    FLock.Acquire;
    try
      // Login can restart a pending load without changing its ticket or generation.
      if (Generation = FGameGeneration) and (HostRevision = FHostRevision) and (FLogin.Ticket = nil) and
        ((FLoad.Ticket = nil) or not FLoad.Ticket.Canceled) then
        Handler := FGameSetsResponseHandler;
    finally
      FLock.Release;
    end;
    if Assigned(Handler) then
    begin
      Snapshot := Result.Snapshot;
      try
        Handler(Response, Snapshot);
      except
        Log(TRAClientLogLevel.Warning, 'Game sets response handler for game %u failed', [Result.ID]);
      end;
    end;
  finally
    Response.Free;
  end;
end;

function TRASession.StartGame(const Game: TRAGameData; const Hash: string; Generation, HostRevision: UInt64; const Credentials: TRACredentials; const Host: string): TRAStartSession;
var
  Response: TJSONObject;
  Hardcore: Boolean;
begin
  FLock.Acquire;
  try
    if (Generation <> FGameGeneration) or (HostRevision <> FHostRevision) or (FLogin.Ticket <> nil) then
      Exit(Default(TRAStartSession));
    if FSpectatorMode <> TRASpectatorMode.Disabled then
    begin
      FSpectatorMode := TRASpectatorMode.Locked;
      Exit(Default(TRAStartSession));
    end;
    Hardcore := FHardcoreEnabled;
  finally
    FLock.Release;
  end;
  Log(TRAClientLogLevel.Verbose, 'Starting session for game %u', [Game.ID]);
  Response := PostRequest(TRARequest.StartSession(Credentials, Game.ID, Hash, Hardcore), Host);
  try
    Result := ReadRAStartSession(Response);
  finally
    Response.Free;
  end;
end;

procedure TRASession.PrepareGame(const Game: TRAGameData; const Hash: string; const Started: TRAStartSession; NextPing: UInt64; ValidateMemory: Boolean);
begin
  FreeAndNil(FRuntime);
  FRuntime := TRARuntime.Create;
  FGame := SelectGameAchievements(Game);
  FGame.ImageName := TruncateRAUTF8(FGame.Sets[0].ImageName, MaxSubsetBadgeNameBytes);
  FGame.ImageURL := FGame.Sets[0].ImageURL;
  FIndicators.SetGame(FGame);
  FSubsetCompletion := nil;
  SetLength(FSubsetCompletion, Length(FGame.Sets));
  FAwarded.Clear;
  FUnsupportedAchievements := nil;
  FUnsupportedLeaderboards := nil;
  FInitialParseWarnings := nil;
  RegisterGame(Started, ValidateMemory);
  FMedia := DescribeMedia(Hash, Game.ID, Game.ID);
  var Key := MediaHashKey(Hash);
  var Entry: TGameHashEntry;
  FMediaByHash.TryGetValue(Key, Entry);
  Entry.Media := FMedia;
  FMediaByHash.AddOrSetValue(Key, Entry);
  FHashByPath.Clear;
  FPlayedSincePing := False;
  FWaitingForReset := False;
  SchedulePing(NextPing);
end;

procedure TRASession.SetHashCallbacks(const Options: TRAMediaHashOptions);
var
  Previous: TRAMediaHashOptions;
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Previous := FHashCallbacks;
    FHashCallbacks := Options;
    Inc(FHashCallbackRevision);
    FHashByPath.Clear;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  Previous := Default(TRAMediaHashOptions);
  if external <> nil then
    external.Session.SetHashCallbacks(Options);
end;

procedure TRASession.SetHashCallbacks(const Callbacks: TRAHashIteratorCallbacks; UserData: Pointer);
var
  Options: TRAMediaHashOptions;
begin
  Options := Default(TRAMediaHashOptions);
  Options.SetCallbackTable(Callbacks, UserData);
  SetHashCallbacks(Options);
end;

procedure TRASession.SetIdentifyUnknownHashHandler(const Handler: TRAIdentifyUnknownHash);
var
  Previous: TRAIdentifyUnknownHash;
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Previous := FIdentifyUnknownHash;
    FIdentifyUnknownHash := Handler;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  Previous := nil;
  if external <> nil then
    external.Session.SetIdentifyUnknownHashHandler(Handler);
end;

function TRASession.IdentifyUnknownHash(ConsoleID: Cardinal; const Hash: string): Cardinal;
var
  Handler: TRAIdentifyUnknownHash;
begin
  FLock.Acquire;
  try
    Handler := FIdentifyUnknownHash;
  finally
    FLock.Release;
  end;
  if Assigned(Handler) then
    Exit(Handler(ConsoleID, Hash));
  Result := 0;
end;

function TRASession.ResolveHashCallbacks(const Overrides: TRAMediaHashOptions; out Revision: UInt64): TRAMediaHashOptions;
begin
  FLock.Acquire;
  try
    Result := FHashCallbacks;
    Revision := FHashCallbackRevision;
  finally
    FLock.Release;
  end;
  Result.ApplyOverrides(Overrides);
  Result := Result.WithDefaults;
end;

function TRASession.HashCallbacksWithLogging(const Options: TRAMediaHashOptions): TRAMediaHashOptions;
begin
  Result := Options;
  if not Assigned(Result.OnVerbose) then
    Result.OnVerbose :=
      procedure(const Path: string; ConsoleID: Cardinal; const Message: string)
      begin
        Log(TRAClientLogLevel.Verbose, '%s', [Message]);
      end;
  if not Assigned(Result.OnError) then
    Result.OnError :=
      procedure(const Path: string; ConsoleID: Cardinal; const Message: string)
      begin
        Log(TRAClientLogLevel.Error, '%s', [Message]);
      end;
end;

function TRASession.TryGetMediaPathHash(const Path: string; Revision: UInt64; const Readers: TRAMediaHashOptions; const Hasher: TRAMediaHasher; out Hash: string): Boolean;
var
  Entry: TMediaPathHash;
begin
  FLock.Acquire;
  try
    Result := (Revision = FHashCallbackRevision) and FHashByPath.TryGetValue(Path, Entry);
    // The custom-hasher overload falls back to hashing only when the launch path is unknown.
    if Result and not (Entry.FromLoad and Assigned(Hasher)) then
      Result := Entry.Readers.SameReaders(Readers) and TEqualityComparer<TRAMediaHasher>.Default.Equals(Entry.Hasher, Hasher);
    if Result then
      Hash := Entry.Hash
    else
      Hash := '';
  finally
    FLock.Release;
  end;
end;

procedure TRASession.CacheMediaPathHash(const Path, Hash: string; Revision: UInt64; const Readers: TRAMediaHashOptions; const Hasher: TRAMediaHasher; FromLoad: Boolean);
var
  Entry: TMediaPathHash;
begin
  FLock.Acquire;
  try
    if Revision <> FHashCallbackRevision then
      Exit;
    Entry.Hash := Hash;
    Entry.Readers := Readers;
    Entry.Readers.OnVerbose := nil;
    Entry.Readers.OnError := nil;
    Entry.Hasher := Hasher;
    Entry.FromLoad := FromLoad;
    FHashByPath.AddOrSetValue(Path, Entry);
  finally
    FLock.Release;
  end;
end;

function TRASession.BeginLoadGame(const GameHash: string; ConsoleID: Cardinal; const Completed: TRAGameLoaded): IRAGameLoad;
var
  Load: TPendingLoad;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginLoadGame(GameHash, ConsoleID, Completed));

  if (GameHash = '') or (Pos(#0, GameHash) <> 0) then
    raise EArgumentException.Create('A RetroAchievements game hash is required');
  Load := Default(TPendingLoad);
  Load.Hash := GameHash;
  Load.ConsoleID := ConsoleID;
  Load.HashConsoleID := ConsoleID;
  Load.Completed := Completed;
  Result := QueueGameLoad(Load);
end;

function TRASession.BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Completed: TRAGameLoaded): IRAGameLoad;
begin
  Result := BeginIdentifyAndLoadGame(ConsoleID, Path, Data, Default(TRAMediaHashOptions), Completed);
end;

function TRASession.BeginIdentifyAndLoadGame(ConsoleID: Cardinal; const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAGameLoaded): IRAGameLoad;
var
  Load: TPendingLoad;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginIdentifyAndLoadGame(ConsoleID, Path, Data, Options, Completed));

  if ((Path = '') and (Length(Data) = 0)) or (Pos(#0, Path) <> 0) then
    raise EArgumentException.Create('A RetroAchievements media path or buffer is required');
  Load := Default(TPendingLoad);
  Load.Identify := True;
  Load.Path := Path;
  Load.Data := Copy(Data);
  Load.HashOptions := ResolveHashCallbacks(Options, Load.HashRevision);
  Load.ConsoleID := ConsoleID;
  Load.Completed := Completed;
  Result := QueueGameLoad(Load);
  if Path <> '' then
    Log(TRAClientLogLevel.Info, 'Identifying game: %s', [Path])
  else
    Log(TRAClientLogLevel.Info, 'Identifying game: %d bytes', [Length(Data)]);
end;

function InitialLoadPhase(Identify: Boolean): TRAGameLoadPhase;
begin
  if Identify then
    Result := TRAGameLoadPhase.IdentifyingGame
  else
    Result := TRAGameLoadPhase.FetchingGame;
end;

function TRASession.QueueGameLoad(var Load: TPendingLoad): IRAGameLoad;
begin
  Load.Ticket := TAsyncOperation.Create;
  Load.Handle := Load.Ticket;
  Load.Phase := InitialLoadPhase(Load.Identify);
  FLock.Acquire;
  try
    MarkGameUnloaded;
    Load.Generation := FGameGeneration;
    Load.HostRevision := FHostRevision;
    if FLogin.Ticket <> nil then
      Load.Phase := TRAGameLoadPhase.AwaitingLogin;
    FLoad := Load;
  finally
    FLock.Release;
  end;
  Result := Load.Handle;
  DispatchClientEvents;
end;

function TRASession.IsCurrentLoad(const Load: TPendingLoad): Boolean;
begin
  Result := (Load.Generation = FGameGeneration) and (Load.HostRevision = FHostRevision) and (Load.Phase = FLoad.Phase);
end;

procedure TRASession.FinishGameLoad(const Load: TPendingLoad; var Loaded: TRAGameLoadResult);
var
  Notify: Boolean;
  ConsoleID: Cardinal;
begin
  FLock.Acquire;
  try
    if not IsCurrentLoad(Load) then
      Exit;
    Notify := Load.Ticket.Finish;
    MarkGameUnloaded;
    if Notify and
      ((Loaded.ServerCode = 'unknown_game') or SameText(Loaded.ServerCode, 'not_found')) and
      (Length(Loaded.TriedHashes) <> 0) then
    begin
      ConsoleID := 0;
      if Length(Loaded.TriedHashes) = 1 then
        ConsoleID := Loaded.HashConsoleID;
      SetUnknownGame(string.Join(',', Loaded.TriedHashes), ConsoleID);
      Loaded.Game := FGame;
    end;
  finally
    FLock.Release;
  end;
  if Notify then
  begin
    LogRequestFailure(TRAClientLogLevel.Error, 'Game load', Loaded.HTTPStatus);
    if Assigned(Load.Completed) then
      Load.Completed(Loaded);
  end;
end;

procedure TRASession.IdentifyGame(var Load: TPendingLoad; var Loaded: TRAGameLoadResult);
var
  Candidate: TRAMediaHashCandidate;
begin
  if Load.HashIterator = nil then
    Load.HashIterator := CreateRAMediaHashIterator(Load.ConsoleID, Load.Path, Load.Data,
      HashCallbacksWithLogging(Load.HashOptions));
  if not Load.Ticket.Canceled and
    TryNextUniqueRAMediaHash(Load.HashIterator, Load.HashCursor, Load.TriedHashes, Candidate) then
  begin
    FLock.Acquire;
    try
      if not IsCurrentLoad(Load) then
        Exit;
      if Load.Ticket.Canceled then
        MarkGameUnloaded
      else
      begin
        FLoad.HashIterator := Load.HashIterator;
        FLoad.HashCursor := Load.HashCursor;
        FLoad.Hash := Candidate.Hash;
        FLoad.HashConsoleID := Candidate.ConsoleID;
        FLoad.TriedHashes := Load.TriedHashes + [Candidate.Hash];
        FLoad.Phase := TRAGameLoadPhase.FetchingGame;
      end;
    finally
      FLock.Release;
    end;
    Exit;
  end;

  if Length(Load.TriedHashes) = 0 then
  begin
    Loaded.ResultCode := RAErrorInvalidState;
    Loaded.ServerCode := 'hash_failed';
    raise ERAProtocolError.Create('RetroAchievements could not generate a hash for this media');
  end;
  if (Length(Load.TriedHashes) = 1) and TryQueueClientIdentifiedLoad(Load) then
    Exit;
  Loaded.ResultCode := RAErrorNoGameLoaded;
  Loaded.ServerCode := 'unknown_game';
  raise ERAProtocolError.Create('RetroAchievements did not recognize any hash for this media');
end;

function TRASession.TryQueueClientIdentifiedLoad(const Load: TPendingLoad): Boolean;
var
  Key: string;
  GameID: Cardinal;
  Entry: TGameHashEntry;
begin
  FLock.Acquire;
  try
    if not IsCurrentLoad(Load) or Load.Ticket.Canceled then
      Exit(False);
    Key := MediaHashKey(Load.Hash);
  finally
    FLock.Release;
  end;
  GameID := IdentifyUnknownHash(Load.HashConsoleID, Load.Hash);
  if GameID = 0 then
    Exit(False);

  FLock.Acquire;
  try
    if not IsCurrentLoad(Load) or Load.Ticket.Canceled or (Key <> MediaHashKey(Load.Hash)) then
      Exit(False);
    Entry.Media := DescribeMedia(Load.Hash, GameID, FGame.ID);
    Entry.IdentifiedByClient := True;
    FMediaByHash.AddOrSetValue(Key, Entry);
    if not Load.Identify then
      FLoad.TriedHashes := [Load.Hash];
    FLoad.Phase := TRAGameLoadPhase.FetchingGame;
  finally
    FLock.Release;
  end;
  Log(TRAClientLogLevel.Info, 'Client says to load game %u for unidentified hash %s', [GameID, Load.Hash]);
  Result := True;
end;

procedure TRASession.FetchPendingGame(var Load: TPendingLoad; var Loaded: TRAGameLoadResult; const Credentials: TRACredentials; const Host: string);
var
  Key: string;
  Entry, Previous: TGameHashEntry;
  Game: TRAGameData;
  ConsoleID, ClientGameID: Cardinal;
  KnownHash, Unrecognized: Boolean;
begin
  FLock.Acquire;
  try
    if not IsCurrentLoad(Load) then
      Exit;
    Key := MediaHashKey(Load.Hash);
    KnownHash := FMediaByHash.TryGetValue(Key, Previous);
  finally
    FLock.Release;
  end;
  ClientGameID := 0;
  if KnownHash and Previous.IdentifiedByClient then
    ClientGameID := Previous.Media.GameID;
  Unrecognized := KnownHash and (Previous.Media.GameID = 0);
  Game := Default(TRAGameData);
  if not Unrecognized then
  begin
    ConsoleID := Load.ConsoleID;
    if Load.Identify then
      ConsoleID := 0;
    try
      Game := FetchGame(Load.Hash, ConsoleID, Credentials, Load.Generation, Load.HostRevision, Host, ClientGameID);
    except
      on Error: ERAServerError do
      begin
        if not SameText(Error.Code, 'not_found') then
          raise;
        Loaded.ErrorMessage := Error.Message;
        Loaded.ServerCode := Error.Code;
        Loaded.HTTPStatus := Error.StatusCode;
      end;
    end;
  end;
  FLock.Acquire;
  try
    if not IsCurrentLoad(Load) or (Key <> MediaHashKey(Load.Hash)) then
      Exit;
    if Load.Ticket.Canceled then
    begin
      MarkGameUnloaded;
      Exit;
    end;
    if Game.ID <> 0 then
    begin
      FLoad.Game := Game;
      FLoad.Phase := TRAGameLoadPhase.StartingSession;
      Exit;
    end;
    if not FMediaByHash.TryGetValue(Key, Entry) or
      ((Entry.Media.GameID = Previous.Media.GameID) and (Entry.IdentifiedByClient = Previous.IdentifiedByClient)) then
    begin
      Entry.Media := DescribeMedia(Load.Hash, 0, FGame.ID);
      Entry.IdentifiedByClient := False;
      FMediaByHash.AddOrSetValue(Key, Entry);
    end;
    if Load.Identify and (ClientGameID = 0) then
    begin
      FLoad.Phase := TRAGameLoadPhase.IdentifyingGame;
      Exit;
    end;
  finally
    FLock.Release;
  end;

  Loaded.TriedHashes := [Load.Hash];
  if (ClientGameID = 0) and TryQueueClientIdentifiedLoad(Load) then
    Exit;
  if Loaded.ServerCode = '' then
  begin
    Loaded.ServerCode := 'unknown_game';
    Loaded.ErrorMessage := 'RetroAchievements does not recognize this ROM';
  end;
  Loaded.ResultCode := RAErrorNoGameLoaded;
  FinishGameLoad(Load, Loaded);
end;

function TRASession.DescribeLoad(const Load: TPendingLoad): TRAGameLoadResult;
begin
  Result := Default(TRAGameLoadResult);
  Result.GameHash := Load.Hash;
  Result.HashConsoleID := Load.HashConsoleID;
  Result.TriedHashes := Load.TriedHashes;
end;

procedure TRASession.PumpGameLoad;
var
  Load: TPendingLoad;
  Loaded: TRAGameLoadResult;
  Started: TRAStartSession;
  Credentials: TRACredentials;
  Reader: TRAMemoryRead;
  AccountGeneration: UInt64;
  Host: string;
begin
  FLock.Acquire;
  try
    Load := FLoad;
    if (FActivatingLoad <> nil) or (Load.Phase in [TRAGameLoadPhase.Idle, TRAGameLoadPhase.AwaitingLogin]) then
      Exit;
    AccountGeneration := FAccountGeneration;
    Host := FHost;
    Credentials := FUser.Credentials;
    if Load.Ticket.Canceled then
    begin
      MarkGameUnloaded;
      Exit;
    end;
    if Load.WaitingForMemory then
    begin
      if Assigned(FReadMemory) and not FAllowBackgroundMemoryReads then
        Exit;
      Reader := FReadMemory;
    end;
  finally
    FLock.Release;
  end;

  if Load.WaitingForMemory then
  begin
    ActivateLoadedGame(Load, Load.Started, Reader);
    Exit;
  end;
  Loaded := DescribeLoad(Load);
  try
    if Load.Phase = TRAGameLoadPhase.IdentifyingGame then
    begin
      IdentifyGame(Load, Loaded);
      Exit;
    end;

    if Load.Phase = TRAGameLoadPhase.FetchingGame then
    begin
      FetchPendingGame(Load, Loaded, Credentials, Host);
      Exit;
    end;

    Started := StartGame(Load.Game, Load.Hash, Load.Generation, Load.HostRevision, Credentials, Host);
    FLock.Acquire;
    try
      if not IsCurrentLoad(Load) then
        Exit;
      if Load.Ticket.Canceled then
      begin
        MarkGameUnloaded;
        Exit;
      end;
      Reader := FReadMemory;
      if Assigned(Reader) and not FAllowBackgroundMemoryReads then
      begin
        FLoad.Started := Started;
        FLoad.WaitingForMemory := True;
        Exit;
      end;
    finally
      FLock.Release;
    end;
  except
    on Error: Exception do
    begin
      Loaded.ErrorMessage := Error.Message;
      if Loaded.ResultCode = RAErrorOK then
        Loaded.ResultCode := RequestErrorResultCode(Error);
      if Error is ERAServerError then
      begin
        Loaded.HTTPStatus := ERAServerError(Error).StatusCode;
        Loaded.ServerCode := ERAServerError(Error).Code;
        DeferNetwork(ERAServerError(Error), AccountGeneration, Load.HostRevision);
      end
      else if Error is ERANoAchievementSets then
      begin
        Loaded.ServerCode := 'no_achievement_sets';
        Loaded.ResultCode := RAErrorNotFound;
      end;
      FinishGameLoad(Load, Loaded);
      Exit;
    end;
  end;
  ActivateLoadedGame(Load, Started, Reader);
end;

function TRASession.ValidateLoadedAddresses(const Load: TPendingLoad; const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
var
  MaxAddress: Cardinal;
begin
  MaxAddress := RAConsoleMaxAddress(Load.Game.ConsoleID);
  Result := FRuntime.ValidateAddresses(
    function(Address: Cardinal): Boolean
    var
      Value: Byte;
    begin
      if Load.Ticket.Canceled or (Address > MaxAddress) then
        Exit(False);
      try
        Result := ReadMemory(Address, @Value, 1) <> 0;
      except
        on Exception do
          Result := False;
      end;
    end);
end;

function ContainsID(const IDs: TArray<Cardinal>; ID: Cardinal): Boolean;
begin
  for var Candidate in IDs do
    if Candidate = ID then
      Exit(True);
  Result := False;
end;

function TRASession.DescribeActiveGameSets: TArray<string>;
var
  SetInfo: TRAAchievementSet;
  CoreCount, ActiveCount, UnsupportedAchievements, UnsupportedLeaderboards: Integer;
  AchievementStatus, LeaderboardStatus: string;
begin
  // Capture counts while the caller holds the current game and runtime locks.
  if (FLogLevel < TRAClientLogLevel.Info) or not Assigned(FLogCallback) then
    Exit(nil);
  SetLength(Result, Length(FGame.Sets));
  for var Index := 0 to High(FGame.Sets) do
  begin
    SetInfo := FGame.Sets[Index];
    CoreCount := 0;
    ActiveCount := 0;
    UnsupportedAchievements := 0;
    UnsupportedLeaderboards := 0;
    for var Achievement in SetInfo.Achievements do
      if Achievement.Category = RACoreAchievement then
      begin
        Inc(CoreCount);
        if ContainsID(FUnsupportedAchievements, Achievement.ID) then
          Inc(UnsupportedAchievements)
        else if FRuntime.HasAchievement(Achievement.ID) then
          Inc(ActiveCount);
      end;

    for var Leaderboard in SetInfo.Leaderboards do
      if ContainsID(FUnsupportedLeaderboards, Leaderboard.ID) then
        Inc(UnsupportedLeaderboards);

    AchievementStatus := Format('%u/%u achievements active', [ActiveCount, CoreCount]);
    if UnsupportedAchievements > 0 then
      AchievementStatus := AchievementStatus + Format(' (%u unsupported)', [UnsupportedAchievements]);
    LeaderboardStatus := Format('%u leaderboards', [Length(SetInfo.Leaderboards)]);
    if UnsupportedLeaderboards > 0 then
      LeaderboardStatus := LeaderboardStatus + Format(' (%u unsupported)', [UnsupportedLeaderboards]);
    Result[Index] := Format('Set %u: %s, %s', [SetInfo.ID, AchievementStatus, LeaderboardStatus]);
  end;
end;

procedure TRASession.ActivateLoadedGame(const Load: TPendingLoad; const Started: TRAStartSession; const ReadMemory: TRAMemoryRead);
var
  Loaded: TRAGameLoadResult;
  NextPing: UInt64;
  InvalidAddresses: TArray<TRARuntimeEvent>;
  ParseWarnings, SetDescriptions: TArray<string>;
  Hardcore, Spectating: Boolean;
  Mode: string;
begin
  Loaded := DescribeLoad(Load);
  try
    NextPing := NowMilliseconds + InitialPingDelay;
    FRuntimeLock.Acquire;
    try
      FLock.Acquire;
      try
        if (FActivatingLoad <> nil) or not IsCurrentLoad(Load) or
          (Load.WaitingForMemory <> FLoad.WaitingForMemory) then
          Exit;
        if Load.Ticket.Canceled then
        begin
          MarkGameUnloaded;
          Exit;
        end;
        PrepareGame(Load.Game, Load.Hash, Started, NextPing, Assigned(ReadMemory));
        if Assigned(ReadMemory) then
        begin
          // The reader may query the candidate game's console or initiate a different load.
          FActivatingLoad := Load.Ticket;
          FLock.Release;
          try
            InvalidAddresses := ValidateLoadedAddresses(Load, ReadMemory);
          finally
            FLock.Acquire;
            FActivatingLoad := nil;
          end;
          if not IsCurrentLoad(Load) then
            Exit;
        end;
        ParseWarnings := FInitialParseWarnings;
        FInitialParseWarnings := nil;
        for var Event in InvalidAddresses do
          MarkAssetUnsupported(Event);
        if Assigned(ReadMemory) then
          RefreshModeAssets;
        SetDescriptions := DescribeActiveGameSets;
        if (Load.Path <> '') and (Load.Data = nil) then
          CacheMediaPathHash(Load.Path, Load.Hash, Load.HashRevision, Load.HashOptions, nil, True);
        if not Load.Ticket.Finish then
        begin
          MarkGameUnloaded;
          Exit;
        end;
        FLoad := Default(TPendingLoad);
        FGameLoaded := True;
        if FMediaDuringLoad.Ticket <> nil then
        begin
          FPendingMedia.Enqueue(FMediaDuringLoad);
          FMediaDuringLoad := Default(TPendingMedia);
        end;
        Loaded.Success := True;
        Loaded.Game := FGame.Snapshot;
        Hardcore := FHardcoreEnabled;
        Spectating := FSpectatorMode <> TRASpectatorMode.Disabled;
      finally
        FLock.Release;
      end;
    finally
      FRuntimeLock.Release;
    end;
  except
    on Error: Exception do
    begin
      Loaded.ErrorMessage := Error.Message;
      Loaded.ResultCode := RequestErrorResultCode(Error);
      FinishGameLoad(Load, Loaded);
      Exit;
    end;
  end;

  for var Event in InvalidAddresses do
    LogInvalidAddress(Event);
  for var Warning in ParseWarnings do
    Log(TRAClientLogLevel.Warning, '%s', [Warning]);
  if Hardcore then
    Mode := 'enabled'
  else
    Mode := 'disabled';
  if Spectating then
    Mode := Mode + ', spectator';
  Log(TRAClientLogLevel.Info, 'Game %u loaded, hardcore %s', [Loaded.Game.ID, Mode]);
  for var Description in SetDescriptions do
    Log(TRAClientLogLevel.Info, '%s', [Description]);
  if Assigned(Load.Completed) then
    Load.Completed(Loaded);
end;

destructor TRASession.Destroy;
begin
  if FExternalSession <> nil then
  begin
    var external := FExternalSession;
    DetachExternalSession(external);
  end;
  if FLogin.Ticket <> nil then
    FLogin.Ticket.Cancel;
  if FLoad.Ticket <> nil then
    FLoad.Ticket.Cancel;
  if FMediaDuringLoad.Ticket <> nil then
    FMediaDuringLoad.Ticket.Cancel;
  if FPendingMedia <> nil then
    for var Request in FPendingMedia do
      Request.Ticket.Cancel;
  if FQueries <> nil then
    for var Request in FQueries do
      Request.Ticket.Cancel;
  FQueries.Free;
  FPendingMedia.Free;
  FHashByPath.Free;
  FMediaByHash.Free;
  FPending.Free;
  FAwarded.Free;
  FClientEventHandler := nil;
  FCanSubmitAchievement := nil;
  FCanSubmitLeaderboard := nil;
  FGameSetsResponseHandler := nil;
  FRichPresenceOverride := nil;
  FClientEvents.Free;
  FRuntimeLock.Free;
  FLock.Free;
  FRuntime.Free;
  FIndicators.Free;
  inherited;
end;

class function TRASession.Login(const Post: TRAPost; const UserName, Password: string): TRACredentials;
var
  Response: TJSONObject;
begin
  Response := Post(TRARequest.LoginWithPassword(UserName, Password));
  try
    Result := ReadRACredentials(Response);
  finally
    Response.Free;
  end;
end;

class function TRASession.RenewLogin(const Post: TRAPost; const Credentials: TRACredentials): TRACredentials;
var
  Response: TJSONObject;
begin
  Response := Post(TRARequest.LoginWithToken(Credentials));
  try
    Result := ReadRACredentials(Response);
  finally
    Response.Free;
  end;
end;

function TRASession.BeginLogin(const Form: string; const Completed: TRAClientLoginCompleted): IRALogin;
var
  Login: TPendingLogin;
begin
  FLock.Acquire;
  try
    if FLogin.Ticket = nil then
    begin
      Login.HostRevision := FHostRevision;
      Login.Form := Form;
      Login.Completed := Completed;
      Login.Ticket := TAsyncOperation.Create;
      Login.Handle := Login.Ticket;
      FLogin := Login;
      if FLoad.Phase <> TRAGameLoadPhase.Idle then
      begin
        FLoad.Phase := TRAGameLoadPhase.AwaitingLogin;
        FLoad.Game := Default(TRAGameData);
        FLoad.Started := Default(TRAStartSession);
        FLoad.WaitingForMemory := False;
        if FLoad.Identify then
        begin
          FLoad.Hash := '';
          FLoad.HashConsoleID := 0;
          FLoad.HashCursor := 0;
          FLoad.TriedHashes := nil;
        end;
      end;
      Exit(Login.Handle);
    end;
  finally
    FLock.Release;
  end;

  Result := QueueQuery('', 'RetroAchievements login is already in progress', nil,
    procedure(const Status: TRAQueryStatus)
    var
      Loaded: TRAClientLoginResult;
    begin
      if not Assigned(Completed) then
        Exit;
      Loaded := Default(TRAClientLoginResult);
      Loaded.Status := Status;
      Completed(Loaded);
    end);
end;

function TRASession.BeginLoginWithPassword(const UserName, Password: string; const Completed: TRAClientLoginCompleted): IRALogin;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginLoginWithPassword(UserName, Password, Completed));

  Result := BeginLogin(TRARequest.LoginWithPassword(UserName, Password), Completed);
  Log(TRAClientLogLevel.Info, 'Attempting to log in %s (with password)', [UserName]);
end;

function TRASession.BeginLoginWithToken(const Credentials: TRACredentials; const Completed: TRAClientLoginCompleted): IRALogin;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginLoginWithToken(Credentials, Completed));

  Result := BeginLogin(TRARequest.LoginWithToken(Credentials), Completed);
  Log(TRAClientLogLevel.Info, 'Attempting to log in %s (with token)', [Credentials.UserName]);
end;

function TRASession.SynchronizeQueryAccount: Boolean;
begin
  Result := True;
end;

function TRASession.UpdateQueryAccount(const User: TRALoginInfo): Boolean;
begin
  FLock.Acquire;
  try
    Result := not SameText(FUser.Credentials.UserName, User.Credentials.UserName);
    if Result then
    begin
      ClearAccount;
      if FGameLoaded then
        MarkGameUnloaded;
    end;
    FUser := User;
  finally
    FLock.Release;
  end;
end;

function TRASession.SnapshotUser(out User: TRALoginInfo; out AccountGeneration: UInt64): Boolean;
begin
  Result := SynchronizeQueryAccount;
  FLock.Acquire;
  try
    Result := Result and (FLogin.Ticket = nil);
    User := FUser;
    AccountGeneration := FAccountGeneration;
  finally
    FLock.Release;
  end;
end;

function TRASession.TryGetUserInfo(out User: TRALoginInfo): Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryGetUserInfo(User));

  FLock.Acquire;
  try
    Result := (FLogin.Ticket = nil) and (FUser.Credentials.UserName <> '');
    if Result then
      User := FUser
    else
      User := Default(TRALoginInfo);
  finally
    FLock.Release;
  end;
end;

function TRASession.CanInitializeIntegration: Boolean;
begin
  FLock.Acquire;
  try
    Result := CanAttachExternalSession;
  finally
    FLock.Release;
  end;
end;

function TRASession.BeginFetchIntegrationVersion(const Completed: TRAIntegrationVersionReceived): IRAQuery;
var
  Version: string;
begin
  Result := QueueQuery('r=latestintegration', '',
    procedure(Response: TJSONObject)
    var
      Value: TJSONValue;
    begin
      Value := Response.GetValue('MinimumVersion');
      if Value is TJSONNull then
        raise ERAResponseFieldError.Create('MinimumVersion');
      Version := ReadRAString(Value, 'MinimumVersion');
    end,
    procedure(const Status: TRAQueryStatus)
    begin
      if not Status.Success then
        Version := '';
      if Assigned(Completed) then
        Completed(Status, Version);
    end);
end;

procedure TRASession.ClearPendingSubmissions;
var
  WasDisconnected: Boolean;
begin
  FPending.Clear;
  WasDisconnected := FDelayedSubmissionCount <> 0;
  FDelayedSubmissionCount := 0;
  QueueConnectionChange(WasDisconnected);
end;

procedure TRASession.ClearAccount;
var
  Request: TPendingQuery;
begin
  Inc(FAccountGeneration);
  FUser := Default(TRALoginInfo);
  ClearPendingSubmissions;
  for var Index := 1 to FQueries.Count do
  begin
    Request := FQueries.Dequeue;
    if Request.AccountGeneration = 0 then
      FQueries.Enqueue(Request)
    else
      Request.Ticket.Cancel;
  end;
end;

function TRASession.TakePendingLoadCallback: TRAGameLoaded;
begin
  Result := nil;
  if (FLoad.Ticket <> nil) and FLoad.Ticket.Finish then
    Result := FLoad.Completed;
end;

function TRASession.PumpLogin: Boolean;
var
  Login: TPendingLogin;
  Loaded: TRAClientLoginResult;
  GameLoad: TRAGameLoadResult;
  LoadCompleted: TRAGameLoaded;
  AccountGeneration: UInt64;
  Host: string;
  Notify, HostChanged: Boolean;
begin
  FLock.Acquire;
  try
    if FLogin.Ticket = nil then
      Exit(False);
    AccountGeneration := FAccountGeneration;
    Host := FHost;
    Login := FLogin;
    HostChanged := Login.HostRevision <> FHostRevision;
    FLogin.Form := '';
  finally
    FLock.Release;
  end;

  Result := True;
  Loaded := Default(TRAClientLoginResult);
  if not HostChanged and not Login.Ticket.Canceled then
    Loaded.Status := ExecuteQuery(Login.Form, Host,
      procedure(Response: TJSONObject)
      begin
        Loaded.User := ReadRALoginInfo(Response, GetImageHost);
      end, Login.Ticket, AccountGeneration, Login.HostRevision);

  FLock.Acquire;
  try
    if FLogin.Ticket <> Login.Ticket then
      Exit;
    Notify := Login.Ticket.Finish;
    FLogin := Default(TPendingLogin);
    HostChanged := Login.HostRevision <> FHostRevision;
    if HostChanged then
    begin
      Loaded := Default(TRAClientLoginResult);
      Loaded.Status := HostChangedStatus;
      if FLoad.Phase = TRAGameLoadPhase.AwaitingLogin then
      begin
        LoadCompleted := TakePendingLoadCallback();
        MarkGameUnloaded;
      end;
    end
    else if Notify and Loaded.Status.Success then
    begin
      UpdateQueryAccount(Loaded.User);
      if FLoad.Phase = TRAGameLoadPhase.AwaitingLogin then
        FLoad.Phase := InitialLoadPhase(FLoad.Identify);
    end
    else
    begin
      LoadCompleted := TakePendingLoadCallback();
      ClearAccount;
      MarkGameUnloaded;
    end;
  finally
    FLock.Release;
  end;

  try
    if HostChanged then
      Log(TRAClientLogLevel.Verbose, 'Login aborted after changing server', [])
    else if not Notify then
      Log(TRAClientLogLevel.Verbose, 'Login canceled', [])
    else if Loaded.Status.Success then
      Log(TRAClientLogLevel.Info, '%s logged in successfully', [Loaded.User.DisplayName])
    else
      LogRequestFailure(TRAClientLogLevel.Error, 'Login', Loaded.Status.HTTPStatus);

    if Notify and Assigned(Login.Completed) then
      Login.Completed(Loaded);
  finally
    if Assigned(LoadCompleted) then
    begin
      GameLoad := Default(TRAGameLoadResult);
      if HostChanged then
      begin
        GameLoad.ResultCode := Loaded.Status.ResultCode;
        GameLoad.ServerCode := Loaded.Status.ServerCode;
        GameLoad.ErrorMessage := Loaded.Status.ErrorMessage;
      end
      else if Notify then
      begin
        GameLoad.ResultCode := RAErrorLoginRequired;
        GameLoad.ServerCode := 'login_required';
        GameLoad.ErrorMessage := 'RetroAchievements login is required to load a game';
      end
      else
      begin
        GameLoad.ResultCode := RAErrorAborted;
        GameLoad.ServerCode := 'login_aborted';
        GameLoad.ErrorMessage := 'RetroAchievements login was canceled';
      end;
      LoadCompleted(GameLoad);
    end;
  end;
end;

procedure TRASession.Logout;
var
  LoginCompleted: TRAClientLoginCompleted;
  LoadCompleted: TRAGameLoaded;
  Login: TRAClientLoginResult;
  Load: TRAGameLoadResult;
  DisplayName: string;
  AbortedLogin: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.Logout;
    Exit;
  end;

  FLock.Acquire;
  try
    DisplayName := FUser.DisplayName;
    AbortedLogin := (FLogin.Ticket <> nil) and FLogin.Ticket.Finish;
    if AbortedLogin then
      LoginCompleted := FLogin.Completed;
    FLogin := Default(TPendingLogin);
    LoadCompleted := TakePendingLoadCallback();
    ClearAccount;
    MarkGameUnloaded;
  finally
    FLock.Release;
  end;

  DispatchClientEvents;
  try
    if AbortedLogin then
      Log(TRAClientLogLevel.Info, 'Aborting login', [])
    else if DisplayName <> '' then
      Log(TRAClientLogLevel.Info, 'Logging %s out', [DisplayName]);

    if Assigned(LoginCompleted) then
    begin
      Login := Default(TRAClientLoginResult);
      Login.Status.ResultCode := RAErrorAborted;
      Login.Status.ServerCode := 'login_aborted';
      Login.Status.ErrorMessage := 'RetroAchievements login was canceled';
      LoginCompleted(Login);
    end;
  finally
    if Assigned(LoadCompleted) then
    begin
      Load := Default(TRAGameLoadResult);
      Load.ResultCode := RAErrorAborted;
      Load.ServerCode := 'login_aborted';
      Load.ErrorMessage := 'RetroAchievements game load was canceled by logout';
      LoadCompleted(Load);
    end;
  end;
end;

function TRASession.SetSpectatorModeEnabled(Enabled: Boolean): Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.SetSpectatorModeEnabled(Enabled));

  FLock.Acquire;
  try
    if (FSpectatorMode <> TRASpectatorMode.Disabled) = Enabled then
      Exit(True);
    Result := FSpectatorMode <> TRASpectatorMode.Locked;
    if Result then
      if Enabled then
        FSpectatorMode := TRASpectatorMode.Enabled
      else
        FSpectatorMode := TRASpectatorMode.Disabled;
  finally
    FLock.Release;
  end;
  if not Result then
    Log(TRAClientLogLevel.Warning, 'Spectator mode cannot be disabled after loading a game in spectator mode', [])
  else if Enabled then
    Log(TRAClientLogLevel.Info, 'Spectator mode enabled', [])
  else
    Log(TRAClientLogLevel.Info, 'Spectator mode disabled', []);
end;

function TRASession.GetSpectatorMode: TRASpectatorMode;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetSpectatorMode);

  FLock.Acquire;
  try
    Result := FSpectatorMode;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.SetEncoreModeEnabled(Enabled: Boolean);
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.SetEncoreModeEnabled(Enabled);
    Exit;
  end;

  FLock.Acquire;
  try
    if FEncoreModeEnabled = Enabled then
      Exit;
    FEncoreModeEnabled := Enabled;
  finally
    FLock.Release;
  end;
  if Enabled then
    Log(TRAClientLogLevel.Info, 'Encore mode enabled', [])
  else
    Log(TRAClientLogLevel.Info, 'Encore mode disabled', []);
end;

function TRASession.GetEncoreModeEnabled: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetEncoreModeEnabled);

  FLock.Acquire;
  try
    Result := FEncoreModeEnabled;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.SetUnofficialEnabled(Enabled: Boolean);
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.SetUnofficialEnabled(Enabled);
    Exit;
  end;

  FLock.Acquire;
  try
    if FUnofficialEnabled = Enabled then
      Exit;
    FUnofficialEnabled := Enabled;
  finally
    FLock.Release;
  end;
  if Enabled then
    Log(TRAClientLogLevel.Info, 'Unofficial achievements enabled', [])
  else
    Log(TRAClientLogLevel.Info, 'Unofficial achievements disabled', []);
end;

function TRASession.GetUnofficialEnabled: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUnofficialEnabled);

  FLock.Acquire;
  try
    Result := FUnofficialEnabled;
  finally
    FLock.Release;
  end;
end;

function TRASession.SelectGameAchievements(const Game: TRAGameData): TRAGameData;
var
  Selected: TArray<TRAAchievementDefinition>;
  CoreIndex, OtherIndex, Index, Count: Integer;
begin
  Result := Game;
  Result.Sets := nil;
  SetLength(Result.Sets, Length(Game.Sets));
  OtherIndex := 0;
  for var AchievementSet in Game.Sets do
    if AchievementSet.Kind = 'core' then
      Inc(OtherIndex);
  CoreIndex := OtherIndex - 1;

  // Upstream makes the core set the first entry even if it arrives later in the response.
  for var AchievementSet in Game.Sets do
  begin
    if AchievementSet.Kind = 'core' then
    begin
      Index := CoreIndex;
      Dec(CoreIndex);
    end
    else
    begin
      Index := OtherIndex;
      Inc(OtherIndex);
    end;

    Result.Sets[Index] := AchievementSet;
    SetLength(Selected, Length(AchievementSet.Achievements));
    Count := 0;
    for var Achievement in AchievementSet.Achievements do
      if (Achievement.Category = RACoreAchievement) or FUnofficialEnabled then
      begin
        Selected[Count] := Achievement;
        if Achievement.Category <> RACoreAchievement then
          Selected[Count].Category := RAUnofficialAchievement;
        Inc(Count);
      end;
    SetLength(Selected, Count);
    Result.Sets[Index].Achievements := Selected;
    Selected := nil;
  end;
end;

function TRASession.TryFindAchievement(ID: Cardinal; out Definition: TRAAchievementDefinition): Boolean;
begin
  for var AchievementSet in FGame.Sets do
    for var Candidate in AchievementSet.Achievements do
      if Candidate.ID = ID then
      begin
        Definition := Candidate;
        Exit(True);
      end;
  Definition := Default(TRAAchievementDefinition);
  Result := False;
end;

function TRASession.RecordLocalAward(ID: Cardinal): Boolean;
var
  Definition: TRAAchievementDefinition;
begin
  RememberAward(ID, FHardcoreEnabled, UnixTime);
  if not TryFindAchievement(ID, Definition) then
    Exit(False);

  // rcheevos updates the provisional score with unsigned 32-bit addition.
  if FHardcoreEnabled then
    FUser.Score := Cardinal((UInt64(FUser.Score) + Definition.Points) and High(Cardinal))
  else
    FUser.SoftcoreScore := Cardinal((UInt64(FUser.SoftcoreScore) + Definition.Points) and High(Cardinal));
  Result := (FSpectatorMode = TRASpectatorMode.Disabled) and (ID < RAClientWarningAchievement) and
    (Definition.Category = RACoreAchievement);
end;

procedure TRASession.RememberAward(ID: Cardinal; Hardcore: Boolean; When: Int64; Historical: Boolean);
var
  Unlock: TUnlockState;
begin
  if not FAwarded.TryGetValue(ID, Unlock) then
    Unlock := Default(TUnlockState);
  Unlock.Flags := Unlock.Flags or SoftcoreUnlocked;
  if Hardcore then
  begin
    Unlock.Flags := Unlock.Flags or HardcoreUnlocked;
    Unlock.HardcoreTime := When;
    if Historical or (Unlock.CasualTime = 0) then
      Unlock.CasualTime := When;
  end
  else
    Unlock.CasualTime := When;
  if not Historical then
    Unlock.PublicTime := When
  else if not FEncoreModeEnabled then
  begin
    if FHardcoreEnabled then
      Unlock.PublicTime := Unlock.HardcoreTime
    else
      Unlock.PublicTime := Unlock.CasualTime;
  end;
  FAwarded.AddOrSetValue(ID, Unlock);
end;

function TRASession.IsAwarded(ID: Cardinal): Boolean;
var
  Unlock: TUnlockState;
  Mask: Byte;
begin
  if FHardcoreEnabled then
    Mask := HardcoreUnlocked
  else
    Mask := SoftcoreUnlocked;
  Result := FAwarded.TryGetValue(ID, Unlock) and ((Unlock.Flags and Mask) <> 0);
end;

procedure TRASession.RefreshModeAssets(InitialLoad, KeepInactiveAssets: Boolean);
var
  UseLeaderboards, Awarded: Boolean;
begin
  UseLeaderboards := FHardcoreEnabled or FAllowLeaderboards;
  for var AchievementSet in FGame.Sets do
  begin
    for var Achievement in AchievementSet.Achievements do
    begin
      Awarded := IsAwarded(Achievement.ID);
      if (InitialLoad or not Awarded) and not FRuntime.HasAchievement(Achievement.ID) and
        not ContainsID(FUnsupportedAchievements, Achievement.ID) then
      try
        FRuntime.ActivateAchievement(Achievement.ID, Achievement.Definition);
      except
        on Error: ERAConditionError do
        begin
          FUnsupportedAchievements := FUnsupportedAchievements + [Achievement.ID];
          if InitialLoad then
            FInitialParseWarnings := FInitialParseWarnings + [Format('Parse error %d processing achievement %u',
              [Error.Code, Achievement.ID])];
        end;
      end;
      if Awarded and not FEncoreModeEnabled and not KeepInactiveAssets then
        FRuntime.DeactivateAchievement(Achievement.ID);
    end;

    for var Leaderboard in AchievementSet.Leaderboards do
    begin
      if (InitialLoad or UseLeaderboards) and not FRuntime.HasLeaderboard(Leaderboard.ID) and
        not ContainsID(FUnsupportedLeaderboards, Leaderboard.ID) then
      try
        FRuntime.ActivateLeaderboard(Leaderboard.ID, Leaderboard.Definition);
      except
        on Error: ERAConditionError do
        begin
          FUnsupportedLeaderboards := FUnsupportedLeaderboards + [Leaderboard.ID];
          if InitialLoad then
            FInitialParseWarnings := FInitialParseWarnings + [Format('Parse error %d processing leaderboard %u',
              [Error.Code, Leaderboard.ID])];
        end;
      end;
      if not UseLeaderboards and not KeepInactiveAssets then
        FRuntime.DeactivateLeaderboard(Leaderboard.ID);
    end;
  end;
end;

procedure TRASession.RegisterGame(const Start: TRAStartSession; KeepInactiveAssets: Boolean);

  procedure ApplyUnlocks(const Unlocks: TArray<TRAUnlock>; Hardcore: Boolean);
  var
    First, Last: Integer;
  begin
    for var AchievementSet in FGame.Sets do
    begin
      First := 0;
      Last := High(AchievementSet.Achievements);
      for var Unlock in Unlocks do
      begin
        for var Index := First to Last do
        begin
          if AchievementSet.Achievements[Index].ID <> Unlock.AchievementID then
            Continue;
          RememberAward(Unlock.AchievementID, Hardcore, Unlock.Awarded, True);
          // The reference client narrows the remaining range after an edge match.
          if Index = First then
            Inc(First)
          else if Index = Last then
            Dec(Last);
          Break;
        end;
        if First > Last then
          Break;
      end;
    end;
  end;

begin
  if FSpectatorMode = TRASpectatorMode.Disabled then
  begin
    ApplyUnlocks(Start.HardcoreUnlockDetails, True);
    ApplyUnlocks(Start.UnlockDetails, False);
  end;
  RefreshModeAssets(True, KeepInactiveAssets);

  try
    FRuntime.SetRichPresence(FGame.RichPresence);
  except
    on Error: ERAConditionError do
    begin
      FInitialParseWarnings := FInitialParseWarnings + [Format('Parse error %d processing rich presence', [Error.Code])];
      FRuntime.SetRichPresence('');
    end;
  end;
end;

procedure TRASession.ApplyHardcoreMode(Enabled: Boolean);
var
  Event: TRARuntimeEvent;
  Unlock: TUnlockState;
begin
  if FHardcoreEnabled = Enabled then
    Exit;
  FHardcoreEnabled := Enabled;
  if FGameLoaded then
  begin
    // A switch to an unlocked mode publishes its timestamp; a locked mode keeps the previous one.
    for var Award in FAwarded.ToArray do
    begin
      Unlock := Award.Value;
      if Enabled and ((Unlock.Flags and HardcoreUnlocked) <> 0) then
        Unlock.PublicTime := Unlock.HardcoreTime
      else if not Enabled and ((Unlock.Flags and SoftcoreUnlocked) <> 0) then
        Unlock.PublicTime := Unlock.CasualTime
      else
        Continue;
      FAwarded[Award.Key] := Unlock;
    end;
    RefreshModeAssets;
    // A mode switch hides challenges before changing leaderboard trackers or requesting a reset.
    FIndicators.ReconcileChallenges(FRuntime, FGame);
    QueueFrameEvents(FIndicators.TakeNotifications, 0);
    FIndicators.ReconcileLeaderboards(FRuntime, FGame);
    if Enabled then
    begin
      FWaitingForReset := True;
      Event := Default(TRARuntimeEvent);
      Event.Kind := TRARuntimeEventKind.ResetRequested;
      QueueClientEvent(Event);
      QueueFrameEvents(FIndicators.TakeNotifications, 0);
    end
    else
      QueuePendingGameEvents;
  end;
end;

procedure TRASession.SetHardcoreEnabled(Enabled: Boolean);
var
  RequiresReset: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.SetHardcoreEnabled(Enabled);
    Exit;
  end;

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if FHardcoreEnabled = Enabled then
        Exit;
      ApplyHardcoreMode(Enabled);
      RequiresReset := FWaitingForReset;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
  DispatchClientEvents;
  if not Enabled then
    Log(TRAClientLogLevel.Info, 'Hardcore disabled', [])
  else if RequiresReset then
    Log(TRAClientLogLevel.Info, 'Hardcore enabled, waiting for reset', [])
  else
    Log(TRAClientLogLevel.Info, 'Hardcore enabled', []);
end;

function TRASession.GetHardcoreEnabled: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetHardcoreEnabled);

  FLock.Acquire;
  try
    Result := FHardcoreEnabled;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetResetRequired: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetResetRequired);

  FLock.Acquire;
  try
    Result := FGameLoaded and FWaitingForReset;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.AdvancePauseDelay;
begin
  FLock.Acquire;
  try
    if FPauseDecay = 0 then
      Exit;
    Dec(FPauseDecay);
    if (FPauseDecay = 0) and (FRequiredUnpausedFrames > MinimumUnpausedFrames) then
    begin
      FRequiredUnpausedFrames := Max(MinimumUnpausedFrames, FRequiredUnpausedFrames shr 1);
      FPauseDecay := FRequiredUnpausedFrames * (PauseDecayMultiplier - 1) - 1;
    end;
  finally
    FLock.Release;
  end;
end;

function TRASession.CanPause(out FramesRemaining: Cardinal): Boolean;
var
  DecayLimit: Cardinal;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.CanPause(FramesRemaining));

  FramesRemaining := 0;
  FLock.Acquire;
  try
    if not FHardcoreEnabled or (FPauseDecay = FRequiredUnpausedFrames * PauseDecayMultiplier) then
      Exit(True);

    DecayLimit := FRequiredUnpausedFrames * (PauseDecayMultiplier - 1);
    if FPauseDecay > DecayLimit then
    begin
      FramesRemaining := FPauseDecay - DecayLimit;
      Exit(False);
    end;

    if (FPauseDecay <> 0) and (FRequiredUnpausedFrames < MaximumUnpausedFrames) then
      Inc(FRequiredUnpausedFrames, MinimumUnpausedFrames);
    FPauseDecay := FRequiredUnpausedFrames * PauseDecayMultiplier;
    Result := True;
  finally
    FLock.Release;
  end;
end;

const
  RAMediaNoHash = '[NO HASH]';
  MediaPending = 0;
  MediaCanceled = 1;
  MediaFinished = 2;

procedure TRASession.TAsyncOperation.Cancel;
begin
  TInterlocked.CompareExchange(FState, MediaCanceled, MediaPending);
end;

function TRASession.TAsyncOperation.Canceled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, MediaPending, MediaPending) = MediaCanceled;
end;

function TRASession.TAsyncOperation.Finish: Boolean;
begin
  Result := TInterlocked.CompareExchange(FState, MediaFinished, MediaPending) = MediaPending;
end;

function TRASession.QueueMediaChange(var Request: TPendingMedia): IRAMediaChange;
begin
  Request.Ticket := TAsyncOperation.Create;
  Request.Handle := Request.Ticket;
  FLock.Acquire;
  try
    Request.Generation := FGameGeneration;
    if Assigned(Request.Hasher) then
      Request.HashRevision := FHashCallbackRevision;
    Request.HadGame := FGameLoaded or FUnknownGame or (FLoad.Phase <> TRAGameLoadPhase.Idle);
    if FLoad.Phase <> TRAGameLoadPhase.Idle then
    begin
      if FMediaDuringLoad.Ticket <> nil then
        FMediaDuringLoad.Ticket.Cancel;
      FMediaDuringLoad := Request;
    end
    else
      FPendingMedia.Enqueue(Request);
  finally
    FLock.Release;
  end;
  Result := Request.Handle;
end;

function TRASession.BeginChangeMedia(const GameHash: string; const Completed: TRAMediaChanged): IRAMediaChange;
var
  Request: TPendingMedia;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginChangeMedia(GameHash, Completed));

  if (GameHash = '') or (Pos(#0, GameHash) <> 0) then
    raise EArgumentException.Create('A RetroAchievements media hash is required');
  Request.Hash := GameHash;
  Request.Completed := Completed;
  Result := QueueMediaChange(Request);
end;

function TRASession.BeginIdentifyAndChangeMedia(const Path: string; const Hasher: TRAMediaHasher; const Completed: TRAMediaChanged): IRAMediaChange;
var
  Request: TPendingMedia;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginIdentifyAndChangeMedia(Path, Hasher, Completed));

  if not Assigned(Hasher) then
    raise EArgumentNilException.Create('A RetroAchievements media reader is required');
  if Pos(#0, Path) <> 0 then
    raise EArgumentException.Create('Invalid RetroAchievements media path');
  Request.Path := Path;
  Request.Hasher := Hasher;
  Request.Completed := Completed;
  Result := QueueMediaChange(Request);
end;

function TRASession.BeginIdentifyAndChangeMedia(const Path: string; const Data: TBytes; const Options: TRAMediaHashOptions; const Completed: TRAMediaChanged): IRAMediaChange;
var
  Request: TPendingMedia;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginIdentifyAndChangeMedia(Path, Data, Options, Completed));

  if ((Path = '') and (Length(Data) = 0)) or (Pos(#0, Path) <> 0) then
    raise EArgumentException.Create('A RetroAchievements media path or buffer is required');
  Request.Path := Path;
  Request.Data := Copy(Data);
  Request.HashOptions := ResolveHashCallbacks(Options, Request.HashRevision);
  Request.Completed := Completed;
  Result := QueueMediaChange(Request);
end;

class function TRASession.DescribeMedia(const Hash: string; GameID, LoadedGameID: Cardinal): TRAMediaInfo;
begin
  Result.Hash := Hash;
  Result.GameID := GameID;
  if (GameID <> 0) and (GameID = LoadedGameID) then
    Result.Kind := TRAMediaKind.LoadedGame
  else if GameID <> 0 then
    Result.Kind := TRAMediaKind.OtherGame
  else if Hash.StartsWith('[') then
    Result.Kind := TRAMediaKind.Unhashable
  else
    Result.Kind := TRAMediaKind.Unrecognized;
end;

function TRASession.MediaHashKey(const Hash: string): string;
begin
  Result := FHost + #0 + LowerCase(Hash);
end;

function TRASession.TryGetMediaGameID(const Hash: string; out GameID: Cardinal): Boolean;
var
  Entry: TGameHashEntry;
begin
  FLock.Acquire;
  try
    Result := FMediaByHash.TryGetValue(MediaHashKey(Hash), Entry);
    GameID := Entry.Media.GameID;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.AddGameHash(const Hash: string; GameID: Cardinal);
var
  Key, Spelling: string;
  Entry: TGameHashEntry;
  external: IRAExternalSession;
begin
  if (Hash = '') or (Pos(#0, Hash) <> 0) then
    raise EArgumentException.Create('A RetroAchievements media hash is required');
  FLock.Acquire;
  try
    Key := MediaHashKey(Hash);
    Spelling := Hash;
    if FMediaByHash.TryGetValue(Key, Entry) then
      Spelling := Entry.Media.Hash;
    Entry.Media := DescribeMedia(Spelling, GameID, FGame.ID);
    FMediaByHash.AddOrSetValue(Key, Entry);
    if (FGameLoaded or FUnknownGame) and SameText(FMedia.Hash, Spelling) then
      FMedia := Entry.Media;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  if external <> nil then
    external.Session.AddGameHash(Hash, GameID);
end;

function TRASession.ResolveMedia(const Request: TPendingMedia; ConsoleID: Cardinal; HostRevision: UInt64): TRAMediaInfo;
var
  Hash, Key, Host: string;
  Response: TJSONObject;
  GameID: Cardinal;
  CachePath, CacheNewHash, HasHash: Boolean;
  Entry: TGameHashEntry;
begin
  CacheNewHash := False;
  Hash := Request.Hash;
  if Hash = '' then
  begin
    CachePath := (Request.Path <> '') and (Request.Data = nil);
    if not CachePath or not TryGetMediaPathHash(Request.Path, Request.HashRevision, Request.HashOptions, Request.Hasher, Hash) then
    begin
      if Assigned(Request.Hasher) then
        HasHash := Request.Hasher(ConsoleID, Request.Path, Hash)
      else
        HasHash := TryHashRAMedia(ConsoleID, Request.Path, Request.Data, HashCallbacksWithLogging(Request.HashOptions), Hash);
      if not HasHash or (Hash = '') or (Pos(#0, Hash) <> 0) then
        Hash := RAMediaNoHash;
      CacheNewHash := CachePath;
    end;
  end;

  FLock.Acquire;
  try
    if HostRevision <> FHostRevision then
      raise ERAProtocolError.Create('RetroAchievements server changed during media lookup');
    // A file path is valid only for the game whose console was used to hash it.
    if Request.Generation <> FGameGeneration then
      Exit(Default(TRAMediaInfo));
    if CacheNewHash then
      CacheMediaPathHash(Request.Path, Hash, Request.HashRevision, Request.HashOptions, Request.Hasher);
    Host := FHost;
    Key := MediaHashKey(Hash);
    if FMediaByHash.TryGetValue(Key, Entry) then
      Exit(Entry.Media);
  finally
    FLock.Release;
  end;

  GameID := 0;
  if not Hash.StartsWith('[') then
  begin
    Response := PostRequest(TRARequest.ResolveHash(Hash), Host);
    try
      GameID := ReadRAGameID(Response);
    finally
      Response.Free;
    end;
  end;

  FLock.Acquire;
  try
    if HostRevision <> FHostRevision then
      raise ERAProtocolError.Create('RetroAchievements server changed during media lookup');
    // Keep the mapping if a caller registered it while the lookup was in flight.
    if not FMediaByHash.TryGetValue(Key, Entry) then
    begin
      Entry.Media := DescribeMedia(Hash, GameID, FGame.ID);
      Entry.IdentifiedByClient := False;
      // Successful lookups are reusable even if the current change was canceled.
      FMediaByHash.Add(Key, Entry);
    end;
    Result := Entry.Media;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.PumpMediaChange;
var
  Request: TPendingMedia;
  Change: TRAMediaChangeResult;
  Entry: TGameHashEntry;
  AccountGeneration, HostRevision: UInt64;
  ConsoleID: Cardinal;
  Loaded: Boolean;
begin
  FLock.Acquire;
  try
    if (FLoad.Phase <> TRAGameLoadPhase.Idle) or (FPendingMedia.Count = 0) then
      Exit;
    Request := FPendingMedia.Dequeue;
    AccountGeneration := FAccountGeneration;
    HostRevision := FHostRevision;
    Loaded := (FGameLoaded or FUnknownGame) and (Request.Generation = FGameGeneration);
    ConsoleID := FGame.ConsoleID;
  finally
    FLock.Release;
  end;
  if Request.Ticket.Canceled then
    Exit;

  Change := Default(TRAMediaChangeResult);
  if Loaded then
  begin
    try
      Change.Media := ResolveMedia(Request, ConsoleID, HostRevision);
    except
      on Error: ERAServerError do
      begin
        Change.State := TRAMediaChangeState.Failed;
        Change.ErrorMessage := Error.Message;
        Change.ServerCode := Error.Code;
        Change.HTTPStatus := Error.StatusCode;
        Change.ResultCode := Error.ResultCode;
        DeferNetwork(Error, AccountGeneration, HostRevision);
      end;
      on Error: Exception do
      begin
        Change.State := TRAMediaChangeState.Failed;
        Change.ErrorMessage := Error.Message;
        Change.ResultCode := RequestErrorResultCode(Error);
      end;
    end;
  end;

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not Request.Ticket.Finish then
        Exit;
      if not (FGameLoaded or FUnknownGame) or (Request.Generation <> FGameGeneration) then
      begin
        if Request.HadGame then
        begin
          Change.State := TRAMediaChangeState.Aborted;
          Change.ResultCode := RAErrorAborted;
          Change.ErrorMessage := 'The requested game is no longer active';
        end
        else
        begin
          Change.State := TRAMediaChangeState.NoGameLoaded;
          Change.ResultCode := RAErrorNoGameLoaded;
          Change.ErrorMessage := 'No game loaded';
        end;
        Change.ServerCode := '';
        Change.HTTPStatus := 0;
        Change.Media := Default(TRAMediaInfo);
      end
      else if HostRevision <> FHostRevision then
      begin
        Change := Default(TRAMediaChangeResult);
        Change.State := TRAMediaChangeState.Aborted;
        Change.ResultCode := RAErrorAborted;
        Change.ErrorMessage := 'RetroAchievements server changed during media lookup';
      end
      else if Change.State = TRAMediaChangeState.Changed then
      begin
        if FMediaByHash.TryGetValue(MediaHashKey(Change.Media.Hash), Entry) then
          Change.Media := Entry.Media;
        FMedia := DescribeMedia(Change.Media.Hash, Change.Media.GameID, FGame.ID);
        Change.Media := FMedia;
        if FGameLoaded and FHardcoreEnabled and (FMedia.Kind = TRAMediaKind.Unrecognized) then
        begin
          ApplyHardcoreMode(False);
          Change.State := TRAMediaChangeState.HardcoreDisabled;
          Change.ResultCode := RAErrorHardcoreDisabled;
          Change.ErrorMessage := 'Hardcore disabled. Unidentified media inserted.';
        end;
      end;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;

  case Change.State of
    TRAMediaChangeState.HardcoreDisabled:
      begin
        Log(TRAClientLogLevel.Warning, 'Disabling hardcore for unidentified media: %s', [Change.Media.Hash]);
        DispatchClientEvents;
      end;
    TRAMediaChangeState.Failed:
      LogRequestFailure(TRAClientLogLevel.Error, 'Media change', Change.HTTPStatus);
    TRAMediaChangeState.Aborted:
      Log(TRAClientLogLevel.Verbose, 'Media change aborted', []);
    TRAMediaChangeState.Changed:
      case Change.Media.Kind of
        TRAMediaKind.LoadedGame:
          Log(TRAClientLogLevel.Info, 'Switching to valid media for game %u: %s', [Change.Media.GameID, Change.Media.Hash]);
        TRAMediaKind.OtherGame:
          Log(TRAClientLogLevel.Info, 'Switching to known media for game %u: %s', [Change.Media.GameID, Change.Media.Hash]);
        TRAMediaKind.Unrecognized:
          Log(TRAClientLogLevel.Info, 'Switching to unrecognized media: %s', [Change.Media.Hash]);
        TRAMediaKind.Unhashable:
          Log(TRAClientLogLevel.Info, 'Switching to unknown media', []);
      end;
  end;

  if Assigned(Request.Completed) then
    Request.Completed(Change);
end;

function TRASession.GetGame: TRAGameData;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetGame);

  FLock.Acquire;
  try
    if FGameLoaded or FUnknownGame or ((FActivatingLoad <> nil) and (FActivatingLoad = FLoad.Ticket) and
      (FLoad.Phase = TRAGameLoadPhase.StartingSession)) then
    begin
      Result := FGame.Snapshot;
      Result.Hash := FMedia.Hash;
    end
    else
      Result := Default(TRAGameData);
  finally
    FLock.Release;
  end;
end;

function TRASession.GetGameLoaded: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetGameLoaded);

  FLock.Acquire;
  try
    Result := FGameLoaded;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetGameLoadPhase: TRAGameLoadPhase;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetGameLoadPhase);

  FLock.Acquire;
  try
    Result := FLoad.Phase;
  finally
    FLock.Release;
  end;
end;

class function TRASession.DescribeGameLoadState(Phase: TRAGameLoadPhase; HasGame: Boolean): TRAGameLoadState;
begin
  case Phase of
    TRAGameLoadPhase.AwaitingLogin:
      Result := TRAGameLoadState.AwaitingLogin;
    TRAGameLoadPhase.IdentifyingGame, TRAGameLoadPhase.FetchingGame:
      Result := TRAGameLoadState.IdentifyingGame;
    TRAGameLoadPhase.StartingSession:
      Result := TRAGameLoadState.StartingSession;
  else
    if HasGame then
      Result := TRAGameLoadState.Done
    else
      Result := TRAGameLoadState.None;
  end;
end;

function TRASession.GetGameLoadState: TRAGameLoadState;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GameLoadState);

  FLock.Acquire;
  try
    Result := DescribeGameLoadState(FLoad.Phase, FGameLoaded or FUnknownGame);
  finally
    FLock.Release;
  end;
end;

function TRASession.GetUnsupportedAchievements: TArray<Cardinal>;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUnsupportedAchievements);

  FLock.Acquire;
  try
    if FGameLoaded then
      Result := Copy(FUnsupportedAchievements)
    else
      Result := nil;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetUnsupportedLeaderboards: TArray<Cardinal>;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUnsupportedLeaderboards);

  FLock.Acquire;
  try
    if FGameLoaded then
      Result := Copy(FUnsupportedLeaderboards)
    else
      Result := nil;
  finally
    FLock.Release;
  end;
end;

function TRASession.GetCurrentMedia: TRAMediaInfo;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetCurrentMedia);

  FLock.Acquire;
  try
    Result := FMedia;
  finally
    FLock.Release;
  end;
end;

function TRASession.PollNativeEvents: TArray<TRARuntimeEvent>;
var
  Announced: Integer;
begin
  Announced := FIndicators.AnnouncedCount;
  Result := FIndicators.Poll(NowMilliseconds);
  QueueFrameEvents(Result, Announced);
end;

function TRASession.TakeNativeIndicatorEvents: TArray<TRARuntimeEvent>;
begin
  FLock.Acquire;
  try
    Result := PollNativeEvents;
  finally
    FLock.Release;
  end;
end;

function TRASession.PollIndicatorEvents: TArray<TRARuntimeEvent>;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.PollIndicatorEvents);
  Result := TakeNativeIndicatorEvents;
  DispatchClientEvents;
end;

procedure TRASession.MarkGameUnloaded;
begin
  Inc(FGameGeneration);
  FHashByPath.Clear;
  if FSpectatorMode = TRASpectatorMode.Locked then
    FSpectatorMode := TRASpectatorMode.Enabled;
  if FLoad.Ticket <> nil then
    FLoad.Ticket.Cancel;
  FLoad := Default(TPendingLoad);
  if FMediaDuringLoad.Ticket <> nil then
    FMediaDuringLoad.Ticket.Cancel;
  FMediaDuringLoad := Default(TPendingMedia);
  if FGameLoaded then
  begin
    FIndicators.EndGame;
    QueueFrameEvents(FIndicators.TakeNotifications, 0);
  end;
  FGameLoaded := False;
  FUnknownGame := False;
  FWaitingForReset := False;
  FMedia := Default(TRAMediaInfo);
  FPlayedSincePing := False;
end;

procedure TRASession.SetUnknownGame(const TriedHashes: string; ConsoleID: Cardinal);
begin
  FGame := Default(TRAGameData);
  FGame.Title := 'Unknown Game';
  FGame.Hash := TriedHashes;
  FGame.ConsoleID := ConsoleID;
  FGame.ImageURL := BuildRAImageURL(TRAImageKind.Game, '000001', RAImageHostForAPI(FHost, FImageHost));
  FUnknownGame := True;
  FMedia := DescribeMedia(TriedHashes, 0, FGame.ID);
end;

procedure TRASession.LoadUnknownGame(const TriedHashes: string; ConsoleID: Cardinal);
var
  Entry: TGameHashEntry;
begin
  if (TriedHashes = '') or (Pos(#0, TriedHashes) <> 0) then
    raise EArgumentException.Create('RetroAchievements requires at least one attempted hash');

  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.LoadUnknownGame(TriedHashes, ConsoleID);
    Exit;
  end;
  FLock.Acquire;
  try
    MarkGameUnloaded;
    SetUnknownGame(TriedHashes, ConsoleID);
    if Length(TriedHashes) = 32 then
    begin
      Entry.Media := FMedia;
      Entry.IdentifiedByClient := False;
      FMediaByHash.AddOrSetValue(MediaHashKey(TriedHashes), Entry);
    end;
  finally
    FLock.Release;
  end;
  DispatchClientEvents;
end;

procedure TRASession.UnloadGame;
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.UnloadGame;
    Exit;
  end;
  UnloadNativeGame;
  DispatchClientEvents;
end;

procedure TRASession.UnloadNativeGame;
var
  GameID: Cardinal;
begin
  GameID := 0;
  FLock.Acquire;
  try
    if FGameLoaded then
      GameID := FGame.ID;
    MarkGameUnloaded;
  finally
    FLock.Release;
  end;
  if GameID <> 0 then
    Log(TRAClientLogLevel.Info, 'Unloading game %u', [GameID]);
end;

function TRASession.GetMemoryReader(Background: Boolean): TRAMemoryRead;
begin
  FLock.Acquire;
  try
    if Background and not FAllowBackgroundMemoryReads then
      Result := nil
    else
      Result := FReadMemory;
  finally
    FLock.Release;
  end;
end;

function TRASession.FrameMemoryReader(const ReadMemory: TRAMemoryRead): TRAMemoryRead;
begin
  Result := ReadMemory;
  if not Assigned(Result) then
    Result := GetMemoryReader(False);
end;

function TRASession.MemoryReadsRequireEmulationThread: Boolean;
begin
  FLock.Acquire;
  try
    Result := Assigned(FReadMemory) and not FAllowBackgroundMemoryReads;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.MemoryAccessChanged;
begin
end;

procedure TRASession.SetReadMemoryFunction(const ReadMemory: TRAMemoryRead);
var
  Previous: TRAMemoryRead;
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    Previous := FReadMemory;
    FReadMemory := ReadMemory;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  Previous := nil;
  if external <> nil then
    external.Session.SetReadMemoryFunction(ReadMemory)
  else
    MemoryAccessChanged;
end;

procedure TRASession.SetAllowBackgroundMemoryReads(Allowed: Boolean);
var
  external: IRAExternalSession;
begin
  FLock.Acquire;
  try
    FAllowBackgroundMemoryReads := Allowed;
    external := FExternalSession;
  finally
    FLock.Release;
  end;
  if external <> nil then
    external.Session.SetAllowBackgroundMemoryReads(Allowed)
  else
    MemoryAccessChanged;
end;

procedure TRASession.ActivateWaitingGame(const ReadMemory: TRAMemoryRead);
var
  Load: TPendingLoad;
begin
  FLock.Acquire;
  try
    if not FLoad.WaitingForMemory then
      Exit;
    Load := FLoad;
  finally
    FLock.Release;
  end;
  ActivateLoadedGame(Load, Load.Started, ReadMemory);
end;

procedure TRASession.Idle(const ReadMemory: TRAMemoryRead);
begin
  var external := ExternalSession;
  if external <> nil then
    external.Session.Idle(ReadMemory)
  else
  begin
    ActivateWaitingGame(FrameMemoryReader(ReadMemory));
    FLock.Acquire;
    try
      QueueFrameEvents(FIndicators.TakeNotifications(NowMilliseconds), 0);
    finally
      FLock.Release;
    end;
    DispatchClientEvents;
  end;
end;

procedure TRASession.MarkAssetUnsupported(const Event: TRARuntimeEvent);
begin
  case Event.Kind of
    TRARuntimeEventKind.AchievementDisabled:
      begin
        if not ContainsID(FUnsupportedAchievements, Event.ID) then
          FUnsupportedAchievements := FUnsupportedAchievements + [Event.ID];
        FRuntime.DeactivateAchievement(Event.ID);
      end;
    TRARuntimeEventKind.LeaderboardDisabled:
      begin
        if not ContainsID(FUnsupportedLeaderboards, Event.ID) then
          FUnsupportedLeaderboards := FUnsupportedLeaderboards + [Event.ID];
        // The client evaluates trackers in set order, including after removing a disabled board.
        FRuntime.DeactivateLeaderboard(Event.ID, True);
      end;
  end;
end;

procedure TRASession.LogInvalidAddress(const Event: TRARuntimeEvent);
begin
  case Event.Kind of
    TRARuntimeEventKind.AchievementDisabled:
      Log(TRAClientLogLevel.Warning, 'Disabled achievement %u. Invalid address %.6x', [Event.ID, Cardinal(Event.Value)]);
    TRARuntimeEventKind.LeaderboardDisabled:
      Log(TRAClientLogLevel.Warning, 'Disabled leaderboard %u. Invalid address %.6x', [Event.ID, Cardinal(Event.Value)]);
  end;
end;

function TRASession.EvaluateFrame(const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.EvaluateFrame(ReadMemory));
  try
    Result := EvaluateFrameCore(ReadMemory);
  finally
    DispatchClientEvents;
  end;
  AdvancePauseDelay;
end;

function TRASession.EvaluateFrameCore(const ReadMemory: TRAMemoryRead): TArray<TRARuntimeEvent>;
type
  TSubmissionCandidate = record
    Pending: TPending;
    Filter: TRAClientSubmissionFilter;
    Submit: Boolean;
    Order, Sequence: Integer;
  end;
var
  Candidates: TArray<TSubmissionCandidate>;
  CandidateCount: Integer;
  Candidate: TSubmissionCandidate;
  Reader: TRAMemoryRead;
  FrameHash: string;
  Generation, AccountGeneration, HostRevision: UInt64;
  HasFilters: Boolean;
  Announced, BufferedEventCount: Integer;
begin
  Reader := FrameMemoryReader(ReadMemory);
  ActivateWaitingGame(Reader);

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded or FWaitingForReset then
        Exit(PollNativeEvents);
      FrameHash := FMedia.Hash;
      Generation := FGameGeneration;
      HostRevision := FHostRevision;
    finally
      FLock.Release;
    end;
    Result := FRuntime.EvaluateFrame(Reader, True);
    FLock.Acquire;
    try
      if Generation <> FGameGeneration then
        Exit(nil);
      FPlayedSincePing := True;
      AccountGeneration := FAccountGeneration;
      HasFilters := Assigned(FCanSubmitAchievement) or Assigned(FCanSubmitLeaderboard);
      CandidateCount := 0;
      for var Event in Result do
      begin
        Candidate := Default(TSubmissionCandidate);
        case Event.Kind of
          TRARuntimeEventKind.AchievementTriggered:
            begin
              Candidate.Submit := RecordLocalAward(Event.ID);
              FRuntime.DeactivateAchievement(Event.ID);
              if Event.ID < RAClientWarningAchievement then
                Candidate.Filter := FCanSubmitAchievement;
            end;
          TRARuntimeEventKind.AchievementDisabled, TRARuntimeEventKind.LeaderboardDisabled:
            MarkAssetUnsupported(Event);
          TRARuntimeEventKind.LeaderboardTriggered:
            if FHardcoreEnabled then
            begin
              Candidate.Submit := FSpectatorMode = TRASpectatorMode.Disabled;
              Candidate.Filter := FCanSubmitLeaderboard;
            end;
        end;

        if (HostRevision = FHostRevision) and (Candidate.Submit or Assigned(Candidate.Filter)) then
        begin
          Candidate.Pending.Event := Event;
          Candidate.Pending.CreatedAt := NowMilliseconds;
          Candidate.Pending.Generation := Generation;
          Candidate.Pending.GameHash := FrameHash;
          Candidate.Pending.Hardcore := FHardcoreEnabled;
          if Candidates = nil then
            SetLength(Candidates, Length(Result));
          Candidate.Order := FIndicators.FrameNotificationOrder(Event);
          Candidate.Sequence := CandidateCount;
          Candidates[CandidateCount] := Candidate;
          Inc(CandidateCount);
        end;
      end;
      // Use the same set and asset order as the client notifications.
      if CandidateCount > 1 then
        TArray.Sort<TSubmissionCandidate>(Candidates, TComparer<TSubmissionCandidate>.Construct(
          function(const Left, Right: TSubmissionCandidate): Integer
          begin
            Result := Left.Order - Right.Order;
            if Result = 0 then
              Result := Left.Sequence - Right.Sequence;
          end), 0, CandidateCount);
      if not HasFilters then
      begin
        for var Index := 0 to CandidateCount - 1 do
          FPending.Add(Candidates[Index].Pending);
        CandidateCount := 0;
      end;
      AppendSubsetCompletionEvents(Result);
      Announced := FIndicators.AnnouncedCount;
      FIndicators.ProcessFrame(Result, FRuntime, NowMilliseconds, BufferedEventCount);
      QueueFrameEvents(Result, Announced, BufferedEventCount);
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;

  for var Index := 0 to CandidateCount - 1 do
    if Assigned(Candidates[Index].Filter) then
    begin
      var ID := Candidates[Index].Pending.Event.ID;
      try
        if not Candidates[Index].Filter(ID) then
          Candidates[Index].Submit := False;
      except
        Candidates[Index].Submit := False;
        Log(TRAClientLogLevel.Warning, 'Submission filter for asset %u failed', [ID]);
      end;
    end;
  if CandidateCount <> 0 then
  begin
    FLock.Acquire;
    try
      // A filter can reenter the session and change the account or host.
      if (AccountGeneration = FAccountGeneration) and (HostRevision = FHostRevision) then
        for var Index := 0 to CandidateCount - 1 do
          if Candidates[Index].Submit then
            FPending.Add(Candidates[Index].Pending);
    finally
      FLock.Release;
    end;
  end;

  for var Event in Result do
    case Event.Kind of
      TRARuntimeEventKind.AchievementDisabled, TRARuntimeEventKind.LeaderboardDisabled:
        LogInvalidAddress(Event);
      TRARuntimeEventKind.LeaderboardStarted:
        Log(TRAClientLogLevel.Verbose, 'Leaderboard %u started', [Event.ID]);
      TRARuntimeEventKind.LeaderboardCanceled:
        Log(TRAClientLogLevel.Verbose, 'Leaderboard %u canceled', [Event.ID]);
    end;
end;

class operator TRAClientAchievement.Initialize(out Dest: TRAClientAchievement);
begin
  Dest.FHasExplicitBadgeURL := False;
  Dest.FHasExplicitBadgeLockedURL := False;
end;

procedure TRAClientAchievement.SetImageURL(ImageState: TRAClientAchievementState; const URL: string);
begin
  if ImageState = TRAClientAchievementState.Unlocked then
  begin
    FHasExplicitBadgeURL := True;
    BadgeURL := URL;
  end
  else
  begin
    FHasExplicitBadgeLockedURL := True;
    BadgeLockedURL := URL;
  end;
end;

function TRAClientAchievement.ImageURL(ImageState: TRAClientAchievementState; const ImageHost: string): string;
var
  ImageKind: TRAImageKind;
  ExplicitURL: Boolean;
begin
  if ImageState = TRAClientAchievementState.Unlocked then
  begin
    ImageKind := TRAImageKind.Achievement;
    Result := BadgeURL;
    ExplicitURL := FHasExplicitBadgeURL;
  end
  else
  begin
    ImageKind := TRAImageKind.LockedAchievement;
    Result := BadgeLockedURL;
    ExplicitURL := FHasExplicitBadgeLockedURL;
  end;

  if BadgeName = '' then
    Exit(BuildRAImageURL(ImageKind, '00000', ImageHost));
  if (Result = '') and not ExplicitURL then
    Result := BuildRAImageURL(ImageKind, BadgeName, ImageHost);
end;

function TRAClientAchievement.CopyImageURL(ImageState: TRAClientAchievementState; Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string): Integer;
begin
  if Pos(#0, BadgeName) <> 0 then
    Exit(RAErrorInvalidState);
  Result := CopyRAImageURL(ImageURL(ImageState, ImageHost), Buffer, BufferSize, True);
end;

function TRAClientLeaderboardEntry.CopyAvatarURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string): Integer;
begin
  // The client entry API builds this URL from the username. AvatarURL retains the response metadata.
  Result := CopyRAImageURL(TRAImageKind.User, '', UserName, Buffer, BufferSize, ImageHost);
end;

function TRASession.HasDelayedAward(ID: Cardinal): Boolean;
begin
  if FDelayedSubmissionCount = 0 then
    Exit(False);
  for var Pending in FPending do
    if (Pending.Attempts > ImmediateRetryAttempts) and (Pending.Generation = FGameGeneration) and
      (Pending.Event.Kind = TRARuntimeEventKind.AchievementTriggered) and (Pending.Event.ID = ID) then
      Exit(True);
  Result := False;
end;

function TRASession.DescribeAchievement(const Definition: TRAAchievementDefinition; RecentUnlockTime: Int64): TRAClientAchievement;
var
  Unlock: TUnlockState;
  Measured: TRAMeasuredProgress;
  TriggerState: TRATriggerState;
  Mask: Byte;
begin
  Result := Default(TRAClientAchievement);
  Result.ID := Definition.ID;
  Result.Points := Definition.Points;
  Result.Title := Definition.Title;
  Result.Description := Definition.Description;
  Result.BadgeName := TruncateRAUTF8(Definition.BadgeName, MaxAchievementBadgeNameBytes);
  Result.BadgeURL := Definition.BadgeURL;
  Result.BadgeLockedURL := Definition.BadgeLockedURL;
  Result.Kind := Definition.Kind;
  Result.Rarity := Definition.Rarity;
  Result.RarityHardcore := Definition.RarityHardcore;
  Result.MeasuredPercent := FIndicators.GetMeasuredPercent(Definition.ID);
  if Definition.Category = RAUnofficialAchievement then
    Result.Category := TRAAchievementCategory.Unofficial;

  if not FAwarded.TryGetValue(Definition.ID, Unlock) then
    Unlock := Default(TUnlockState);
  if (Unlock.Flags and SoftcoreUnlocked) <> 0 then
    Include(Result.Unlocks, TRAAchievementUnlock.Casual);
  if (Unlock.Flags and HardcoreUnlocked) <> 0 then
    Include(Result.Unlocks, TRAAchievementUnlock.Hardcore);
  Result.UnlockTime := Unlock.PublicTime;
  if FHardcoreEnabled then
    Mask := HardcoreUnlocked
  else
    Mask := SoftcoreUnlocked;

  if Result.Category = TRAAchievementCategory.Unofficial then
    Result.Bucket := TRAAchievementBucketKind.Unofficial
  else
    Result.Bucket := TRAAchievementBucketKind.Locked;

  if ContainsID(FUnsupportedAchievements, Definition.ID) then
  begin
    Result.State := TRAClientAchievementState.Disabled;
    Result.Bucket := TRAAchievementBucketKind.Unsupported;
  end
  else if FRuntime.TryGetAchievementState(Definition.ID, TriggerState, Measured) then
  begin
    Result.State := TRAClientAchievementState.Active;
    if Measured.Known and (Measured.Target <> 0) then
    begin
      Result.MeasuredProgress := FormatRAClientMeasured(Measured, Result.MeasuredPercent);
      FIndicators.SetMeasuredPercent(Definition.ID, Result.MeasuredPercent);
    end;

    if TriggerState = TRATriggerState.Primed then
      Result.Bucket := TRAAchievementBucketKind.ActiveChallenge
    else if Result.MeasuredPercent >= 80 then
      Result.Bucket := TRAAchievementBucketKind.AlmostThere;
  end
  else if (Unlock.Flags and Mask) <> 0 then
  begin
    Result.State := TRAClientAchievementState.Unlocked;
    if Result.UnlockTime >= RecentUnlockTime then
      Result.Bucket := TRAAchievementBucketKind.RecentlyUnlocked
    else if HasDelayedAward(Definition.ID) then
      Result.Bucket := TRAAchievementBucketKind.Unsynced
    else
      Result.Bucket := TRAAchievementBucketKind.Unlocked;
  end;
end;

function TRASession.TryGetAchievementInfo(ID: Cardinal; out Info: TRAClientAchievement): Boolean;
var
  Definition: TRAAchievementDefinition;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryGetAchievementInfo(ID, Info));

  Info := Default(TRAClientAchievement);
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      Result := FGameLoaded and TryFindAchievement(ID, Definition);
      if Result then
        Info := DescribeAchievement(Definition, UnixTime - RecentUnlockDelay);
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.TryGetNextAchievementInfo(AfterID: Cardinal; Bucket: TRAAchievementBucketKind; out Info: TRAClientAchievement): Boolean;
var
  Found: Boolean;
  RecentUnlockTime: Int64;
  Candidate: TRAClientAchievement;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryGetNextAchievementInfo(AfterID, Bucket, Info));

  Info := Default(TRAClientAchievement);
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(False);
      Found := AfterID = 0;
      RecentUnlockTime := UnixTime - RecentUnlockDelay;
      for var AchievementSet in FGame.Sets do
        for var Definition in AchievementSet.Achievements do
          if Found then
          begin
            Candidate := DescribeAchievement(Definition, RecentUnlockTime);
            if Candidate.Bucket = Bucket then
            begin
              Info := Candidate;
              Exit(True);
            end;
          end
          else if Definition.ID = AfterID then
            Found := True;
      Result := False;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.HasAchievements: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.HasAchievements);

  FLock.Acquire;
  try
    if FGameLoaded then
      for var AchievementSet in FGame.Sets do
        if Length(AchievementSet.Achievements) <> 0 then
          Exit(True);
    Result := False;
  finally
    FLock.Release;
  end;
end;

function TRASession.CreateAchievementList(Categories: TRAAchievementCategories; Grouping: TRAAchievementGrouping): TArray<TRAAchievementBucket>;
const
  BucketLabels: array[TRAAchievementBucketKind] of string = ('Unknown', 'Locked', 'Unlocked',
    'Unsupported', 'Unofficial', 'Recently Unlocked', 'Active Challenges', 'Almost There',
    'Unlocks Not Synced to Server');
  SharedOrder: array[0..3] of TRAAchievementBucketKind = (TRAAchievementBucketKind.ActiveChallenge,
    TRAAchievementBucketKind.RecentlyUnlocked, TRAAchievementBucketKind.AlmostThere, TRAAchievementBucketKind.Unsynced);
  SubsetOrder: array[0..3] of TRAAchievementBucketKind = (TRAAchievementBucketKind.Locked,
    TRAAchievementBucketKind.Unofficial, TRAAchievementBucketKind.Unsupported, TRAAchievementBucketKind.Unlocked);
var
  Buckets: TList<TRAAchievementBucket>;
  Entries: array[TRAAchievementBucketKind] of TList<TRAClientAchievement>;
  Info: TRAClientAchievement;
  GroupKind: TRAAchievementBucketKind;
  RecentUnlockTime: Int64;
  SharedCount: Integer;

  procedure AddBucket(Kind: TRAAchievementBucketKind; const AchievementSet: TRAAchievementSet; Shared: Boolean);
  var
    Bucket: TRAAchievementBucket;
    Group: TList<TRAClientAchievement>;
  begin
    Group := Entries[Kind];
    if Group = nil then
      Exit;
    if Group.Count = 0 then
      Exit;

    case Kind of
      TRAAchievementBucketKind.RecentlyUnlocked:
        Group.Sort(TComparer<TRAClientAchievement>.Construct(
          function(const Left, Right: TRAClientAchievement): Integer
          begin
            Result := CompareValue(Right.UnlockTime, Left.UnlockTime);
          end));
      TRAAchievementBucketKind.AlmostThere:
        Group.Sort(TComparer<TRAClientAchievement>.Construct(
          function(const Left, Right: TRAClientAchievement): Integer
          begin
            if Left.MeasuredPercent > Right.MeasuredPercent then
              Exit(-1);
            if Left.MeasuredPercent < Right.MeasuredPercent then
              Exit(1);
            Result := CompareValue(Int64(Left.ID), Int64(Right.ID));
          end));
    end;

    Bucket := Default(TRAAchievementBucket);
    Bucket.Kind := Kind;
    Bucket.LabelText := BucketLabels[Kind];
    if not Shared and (Length(FGame.Sets) > 1) then
    begin
      Bucket.SubsetID := AchievementSet.ID;
      Bucket.LabelText := AchievementSet.Title + ' - ' + Bucket.LabelText;
    end;
    Bucket.Achievements := Group.ToArray;

    if Shared then
    begin
      Buckets.Insert(SharedCount, Bucket);
      Inc(SharedCount);
    end
    else
      Buckets.Add(Bucket);
    Group.Clear;
  end;

begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.CreateAchievementList(Categories, Grouping));

  Result := nil;
  if Categories = [] then
    Exit;
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit;
      for var Kind := Low(TRAAchievementBucketKind) to High(TRAAchievementBucketKind) do
        Entries[Kind] := nil;
      Buckets := TList<TRAAchievementBucket>.Create;
      try
        RecentUnlockTime := UnixTime - RecentUnlockDelay;
        for var AchievementSet in FGame.Sets do
        begin
          for var Definition in AchievementSet.Achievements do
          begin
            if Definition.Category = RACoreAchievement then
            begin
              if not (TRAAchievementCategory.Core in Categories) then
                Continue;
            end
            else if not (TRAAchievementCategory.Unofficial in Categories) then
              Continue;

            Info := DescribeAchievement(Definition, RecentUnlockTime);
            GroupKind := Info.Bucket;
            if Grouping = TRAAchievementGrouping.LockState then
              case GroupKind of
                TRAAchievementBucketKind.RecentlyUnlocked, TRAAchievementBucketKind.Unsynced:
                  GroupKind := TRAAchievementBucketKind.Unlocked;
                TRAAchievementBucketKind.ActiveChallenge, TRAAchievementBucketKind.AlmostThere:
                  GroupKind := TRAAchievementBucketKind.Locked;
              end;
            if Entries[GroupKind] = nil then
              Entries[GroupKind] := TList<TRAClientAchievement>.Create;
            Entries[GroupKind].Add(Info);
          end;
          for var Kind in SubsetOrder do
            AddBucket(Kind, AchievementSet, False);
        end;
        SharedCount := 0;
        for var Kind in SharedOrder do
          AddBucket(Kind, Default(TRAAchievementSet), True);
        Result := Buckets.ToArray;
      finally
        for var Group in Entries do
          Group.Free;
        Buckets.Free;
      end;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.DescribeLeaderboard(const Definition: TRALeaderboardDefinition): TRAClientLeaderboard;
var
  State: TRALeaderboardState;
  Value: Integer;
begin
  Result := Default(TRAClientLeaderboard);
  Result.ID := Definition.ID;
  Result.Title := Definition.Title;
  Result.Description := Definition.Description;
  Result.LowerIsBetter := Definition.LowerIsBetter;
  case Definition.ValueFormat of
    TRAValueFormat.Frames, TRAValueFormat.Centiseconds, TRAValueFormat.Seconds, TRAValueFormat.SecondsAsMinutes, TRAValueFormat.Minutes:
      Result.Format := TRAClientLeaderboardFormat.Time;
    TRAValueFormat.Score:
      Result.Format := TRAClientLeaderboardFormat.Score;
  else
    Result.Format := TRAClientLeaderboardFormat.Value;
  end;

  FIndicators.GetLeaderboardTracker(Definition.ID, Result.TrackerID, Result.TrackerValue);
  if ContainsID(FUnsupportedLeaderboards, Definition.ID) then
    Result.State := TRAClientLeaderboardState.Disabled
  else if FRuntime.TryGetLeaderboardState(Definition.ID, State, Value) then
    case State of
      TRALeaderboardState.Disabled:
        Result.State := TRAClientLeaderboardState.Disabled;
      TRALeaderboardState.Started:
        begin
          Result.State := TRAClientLeaderboardState.Tracking;
          if Result.TrackerID = 0 then
            Result.TrackerValue := FormatRAValue(Value, Definition.ValueFormat);
        end;
      TRALeaderboardState.Inactive:
        Result.State := TRAClientLeaderboardState.Inactive;
    else
      Result.State := TRAClientLeaderboardState.Active;
    end;
end;

function TRASession.TryFindLeaderboard(ID: Cardinal; out Definition: TRALeaderboardDefinition): Boolean;
begin
  for var AchievementSet in FGame.Sets do
    for var Candidate in AchievementSet.Leaderboards do
      if Candidate.ID = ID then
      begin
        Definition := Candidate;
        Exit(True);
      end;
  Definition := Default(TRALeaderboardDefinition);
  Result := False;
end;

function TRASession.TryGetLeaderboardInfo(ID: Cardinal; out Info: TRAClientLeaderboard): Boolean;
var
  Definition: TRALeaderboardDefinition;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryGetLeaderboardInfo(ID, Info));

  Info := Default(TRAClientLeaderboard);
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      Result := FGameLoaded and TryFindLeaderboard(ID, Definition);
      if Result then
        Info := DescribeLeaderboard(Definition);
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.HasLeaderboards: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.HasLeaderboards);

  FLock.Acquire;
  try
    if FGameLoaded then
      for var AchievementSet in FGame.Sets do
        for var Definition in AchievementSet.Leaderboards do
          if not Definition.Hidden then
            Exit(True);
    Result := False;
  finally
    FLock.Release;
  end;
end;

function TRASession.CreateLeaderboardList(Grouping: TRALeaderboardGrouping): TArray<TRALeaderboardBucket>;
const
  BucketLabels: array[TRALeaderboardBucketKind] of string = ('Inactive', 'Active', 'Unsupported', 'All');
var
  Buckets: TList<TRALeaderboardBucket>;
  Tracking, Available, Unsupported: TList<TRAClientLeaderboard>;
  Info: TRAClientLeaderboard;
  AvailableKind: TRALeaderboardBucketKind;

  procedure AddBucket(Entries: TList<TRAClientLeaderboard>; Kind: TRALeaderboardBucketKind; const AchievementSet: TRAAchievementSet);
  var
    Bucket: TRALeaderboardBucket;
  begin
    if Entries.Count = 0 then
      Exit;
    Bucket := Default(TRALeaderboardBucket);
    Bucket.Kind := Kind;
    Bucket.LabelText := BucketLabels[Kind];
    Bucket.Leaderboards := Entries.ToArray;
    if Kind = TRALeaderboardBucketKind.Active then
      Buckets.Insert(0, Bucket)
    else
    begin
      if Length(FGame.Sets) > 1 then
      begin
        Bucket.SubsetID := AchievementSet.ID;
        Bucket.LabelText := AchievementSet.Title + ' - ' + Bucket.LabelText;
      end;
      Buckets.Add(Bucket);
    end;
    Entries.Clear;
  end;

begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.CreateLeaderboardList(Grouping));

  Result := nil;
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit;
      Buckets := nil;
      Tracking := nil;
      Available := nil;
      Unsupported := nil;
      try
        Buckets := TList<TRALeaderboardBucket>.Create;
        Tracking := TList<TRAClientLeaderboard>.Create;
        Available := TList<TRAClientLeaderboard>.Create;
        Unsupported := TList<TRAClientLeaderboard>.Create;
        if Grouping = TRALeaderboardGrouping.Tracking then
          AvailableKind := TRALeaderboardBucketKind.Inactive
        else
          AvailableKind := TRALeaderboardBucketKind.All;

        for var AchievementSet in FGame.Sets do
        begin
          for var Definition in AchievementSet.Leaderboards do
            if not Definition.Hidden then
            begin
              Info := DescribeLeaderboard(Definition);
              if Info.State = TRAClientLeaderboardState.Disabled then
                Unsupported.Add(Info)
              else if (Grouping = TRALeaderboardGrouping.Tracking) and
                (Info.State = TRAClientLeaderboardState.Tracking) then
                Tracking.Add(Info)
              else
                Available.Add(Info);
            end;
          AddBucket(Available, AvailableKind, AchievementSet);
          AddBucket(Unsupported, TRALeaderboardBucketKind.Unsupported, AchievementSet);
        end;
        AddBucket(Tracking, TRALeaderboardBucketKind.Active, Default(TRAAchievementSet));
        Result := Buckets.ToArray;
      finally
        Unsupported.Free;
        Available.Free;
        Tracking.Free;
        Buckets.Free;
      end;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.QueueQuery(const Form, ValidationError: string; const Read: TReadQuery; const Completed: TCompleteQuery; AccountGeneration: UInt64; const BuildForm: TBuildQueryForm): IRAQuery;
var
  Request: TPendingQuery;
begin
  Request.Form := Form;
  Request.AccountGeneration := AccountGeneration;
  Request.BuildForm := BuildForm;
  Request.ValidationError := ValidationError;
  Request.Read := Read;
  Request.Completed := Completed;
  Request.Ticket := TAsyncOperation.Create;
  Request.Handle := Request.Ticket;
  FLock.Acquire;
  try
    Request.HostRevision := FHostRevision;
    FQueries.Enqueue(Request);
  finally
    FLock.Release;
  end;
  Result := Request.Handle;
end;

function TRASession.QueueListQuery<T>(const Form: string; const Read: TReadQueryList<T>; const Completed: TRAListQueryCompleted<T>; const ValidationError: string; AccountGeneration: UInt64; const BuildForm: TBuildQueryForm): IRAQuery;
var
  Loaded: TRAListQueryResult<T>;
begin
  Loaded := Default(TRAListQueryResult<T>);
  Result := QueueQuery(Form, ValidationError,
    procedure(Response: TJSONObject)
    begin
      Loaded.Entries := Read(Response);
    end,
    procedure(const Status: TRAQueryStatus)
    begin
      Loaded.Status := Status;
      if not Status.Success then
        Loaded.Entries := nil;
      if Assigned(Completed) then
        Completed(Loaded);
    end, AccountGeneration, BuildForm);
end;

function TRASession.ExecuteQuery(const Form, Host: string; const Read: TReadQuery; Ticket: TAsyncOperation; AccountGeneration, HostRevision: UInt64): TRAQueryStatus;
var
  Response: TJSONObject;
begin
  Result := Default(TRAQueryStatus);
  try
    Response := PostRequest(Form, Host);
    try
      if Ticket.Canceled then
        Exit;
      FLock.Acquire;
      try
        if HostRevision <> FHostRevision then
          Exit(HostChangedStatus);
      finally
        FLock.Release;
      end;
      Read(Response);
      Result.Success := True;
    finally
      Response.Free;
    end;
  except
    on Error: Exception do
    begin
      Result.ErrorMessage := Error.Message;
      Result.ResultCode := RequestErrorResultCode(Error);
      if Error is ERAServerError then
      begin
        Result.ServerCode := ERAServerError(Error).Code;
        Result.HTTPStatus := ERAServerError(Error).StatusCode;
        DeferNetwork(ERAServerError(Error), AccountGeneration, HostRevision);
      end;
    end;
  end;
end;

procedure TRASession.PumpQuery;
var
  Request: TPendingQuery;
  Status: TRAQueryStatus;
  Credentials: TRACredentials;
  AccountGeneration: UInt64;
  Host: string;
  HostChanged: Boolean;
begin
  FLock.Acquire;
  try
    if (FQueries.Count = 0) or (FLogin.Ticket <> nil) then
      Exit;
  finally
    FLock.Release;
  end;
  if not SynchronizeQueryAccount then
    Exit;

  FLock.Acquire;
  try
    if (FQueries.Count = 0) or (FLogin.Ticket <> nil) then
      Exit;
    Request := FQueries.Dequeue;
    AccountGeneration := FAccountGeneration;
    HostChanged := Request.HostRevision <> FHostRevision;
    Host := FHost;
    Credentials := FUser.Credentials;
    if (Request.AccountGeneration <> 0) and (Request.AccountGeneration <> FAccountGeneration) then
      Request.Ticket.Cancel;
  finally
    FLock.Release;
  end;
  if Request.Ticket.Canceled then
    Exit;

  if HostChanged then
    Status := HostChangedStatus
  else if Request.ValidationError <> '' then
  begin
    Status := Default(TRAQueryStatus);
    Status.ResultCode := RAErrorInvalidState;
    Status.ErrorMessage := Request.ValidationError;
  end
  else
  try
    if Assigned(Request.BuildForm) then
      Request.Form := Request.BuildForm(Credentials);
    Status := ExecuteQuery(Request.Form, Host, Request.Read, Request.Ticket, AccountGeneration, Request.HostRevision);
  except
    on Error: EArgumentException do
    begin
      Status := Default(TRAQueryStatus);
      Status.ResultCode := RAErrorInvalidState;
      Status.ErrorMessage := Error.Message;
    end;
  end;

  if (Request.AccountGeneration <> 0) and not SynchronizeQueryAccount then
    Request.Ticket.Cancel;
  FLock.Acquire;
  try
    if (Request.AccountGeneration <> 0) and (Request.AccountGeneration <> FAccountGeneration) then
      Request.Ticket.Cancel;
    if not Request.Ticket.Finish then
      Exit;
    if Request.HostRevision <> FHostRevision then
      Status := HostChangedStatus;
  finally
    FLock.Release;
  end;
  if (Request.Form <> '') and not Status.Success and (Status.ResultCode <> RAErrorAborted) then
  begin
    var Separator := Pos('&', Request.Form);
    if Separator = 0 then
      Separator := Length(Request.Form) + 1;
    LogRequestFailure(TRAClientLogLevel.Error, 'Query ' + Copy(Request.Form, 3, Separator - 3), Status.HTTPStatus);
  end;
  Request.Completed(Status);
end;

function TRASession.QueueLeaderboardEntries(ID, FirstEntry, Count: Cardinal; AroundUser: Boolean; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
var
  Loaded: TRALeaderboardEntriesResult;
  User: TRALoginInfo;
  AccountGeneration: UInt64;
  Form, ValidationError, UserName: string;
begin
  AccountGeneration := 0;
  if AroundUser then
  begin
    SnapshotUser(User, AccountGeneration);
    UserName := User.Credentials.UserName;
  end;
  if AroundUser and (UserName = '') then
    ValidationError := 'RetroAchievements login is required to look up the player''s rank'
  else if ID = 0 then
    ValidationError := 'Invalid RetroAchievements leaderboard ID'
  else if AroundUser then
    Form := TRARequest.FetchLeaderboardInfoAroundUser(ID, Count, UserName)
  else
    Form := TRARequest.FetchLeaderboardInfo(ID, FirstEntry, Count);

  // Local validation has no account-scoped response to discard after login.
  if ValidationError <> '' then
    AccountGeneration := 0;

  Loaded := Default(TRALeaderboardEntriesResult);
  Loaded.LeaderboardID := ID;
  Loaded.UserIndex := -1;
  Result := QueueQuery(Form, ValidationError,
    procedure(Response: TJSONObject)
    var
      Info: TRALeaderboardInfo;
    begin
      Info := ReadRALeaderboardInfo(Response, GetImageHost);
      Loaded.LeaderboardID := Info.ID;
      Loaded.TotalEntries := Info.TotalEntries;
      SetLength(Loaded.Entries, Length(Info.Entries));
      for var Index := 0 to High(Info.Entries) do
      begin
        var Entry := Info.Entries[Index];
        Loaded.Entries[Index].UserName := Entry.UserName;
        Loaded.Entries[Index].AvatarURL := Entry.AvatarURL;
        Loaded.Entries[Index].Display := FormatRAValue(Entry.Score, Info.ValueFormat);
        Loaded.Entries[Index].Rank := Entry.Rank;
        Loaded.Entries[Index].Index := Entry.Index;
        Loaded.Entries[Index].Score := Entry.Score;
        Loaded.Entries[Index].Submitted := Entry.Submitted;
      end;
    end,
    procedure(const Status: TRAQueryStatus)
    var
      CurrentUser: TRALoginInfo;
    begin
      Loaded.Success := Status.Success;
      Loaded.ErrorMessage := Status.ErrorMessage;
      Loaded.ServerCode := Status.ServerCode;
      Loaded.HTTPStatus := Status.HTTPStatus;
      Loaded.ResultCode := Status.ResultCode;
      if AroundUser and (UserName = '') and (Status.ResultCode = RAErrorInvalidState) then
        Loaded.ResultCode := RAErrorLoginRequired;
      if not Status.Success then
      begin
        Loaded.Entries := nil;
        Loaded.LeaderboardID := ID;
        Loaded.TotalEntries := 0;
        Loaded.UserIndex := -1;
      end
      else if TryGetUserInfo(CurrentUser) and (CurrentUser.DisplayName <> '') then
        for var Index := 0 to High(Loaded.Entries) do
          if Loaded.Entries[Index].UserName = CurrentUser.DisplayName then
            Loaded.UserIndex := Index;
      if Assigned(Completed) then
        Completed(Loaded);
    end, AccountGeneration);
end;

function TRASession.BeginFetchLeaderboardEntries(ID, FirstEntry, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchLeaderboardEntries(ID, FirstEntry, Count, Completed));

  Result := QueueLeaderboardEntries(ID, FirstEntry, Count, False, Completed);
end;

function TRASession.BeginFetchLeaderboardEntriesAroundUser(ID, Count: Cardinal; const Completed: TRALeaderboardEntriesReceived): IRALeaderboardEntriesRequest;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchLeaderboardEntriesAroundUser(ID, Count, Completed));

  Result := QueueLeaderboardEntries(ID, 0, Count, True, Completed);
end;

function TRASession.BeginFetchHashLibrary(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAHashLibraryEntry>): IRAQuery;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchHashLibrary(ConsoleID, Completed));

  Result := QueueListQuery<TRAHashLibraryEntry>(TRARequest.FetchHashLibrary(ConsoleID),
    function(Response: TJSONObject): TArray<TRAHashLibraryEntry>
    begin
      Result := ReadRAHashLibrary(Response);
      for var Index := 0 to High(Result) do
        Result[Index].Hash := TruncateRAUTF8(Result[Index].Hash, MaxHashLibraryHashBytes);
    end, Completed);
end;

function TRASession.BeginFetchGameTitles(const GameIDs: array of Cardinal; const Completed: TRAListQueryCompleted<TRAGameTitle>): IRAQuery;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchGameTitles(GameIDs, Completed));

  if Length(GameIDs) = 0 then
    Exit(QueueListQuery<TRAGameTitle>('', nil, Completed, 'game_ids is required'));

  Result := QueueListQuery<TRAGameTitle>(TRARequest.FetchGameTitles(GameIDs),
    function(Response: TJSONObject): TArray<TRAGameTitle>
    begin
      Result := ReadRAGameTitles(Response, GetImageHost);
      for var Index := 0 to High(Result) do
        Result[Index].ImageName := TruncateRAUTF8(Result[Index].ImageName, MaxGameTitleBadgeNameBytes);
    end, Completed);
end;

function TRASession.BeginFetchGameList(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAGameListEntry>): IRAQuery;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchGameList(ConsoleID, Completed));

  if ConsoleID = 0 then
    Exit(QueueListQuery<TRAGameListEntry>('', nil, Completed, RAErrorMessage(RAErrorInvalidState)));

  Result := QueueListQuery<TRAGameListEntry>(TRARequest.FetchGamesList(ConsoleID), ReadRAGamesList, Completed);
end;

function TRASession.BeginFetchAllUserProgress(ConsoleID: Cardinal; const Completed: TRAListQueryCompleted<TRAUserGameProgress>): IRAQuery;
var
  User: TRALoginInfo;
  AccountGeneration: UInt64;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.BeginFetchAllUserProgress(ConsoleID, Completed));

  if not SnapshotUser(User, AccountGeneration) or (User.Credentials.UserName = '') then
    Exit(QueueListQuery<TRAUserGameProgress>('', ReadRAAllUserProgress, Completed,
        'client must be logged in'));
  if (ConsoleID = 0) or (User.Credentials.Token = '') then
    Exit(QueueListQuery<TRAUserGameProgress>('', ReadRAAllUserProgress, Completed,
        RAErrorMessage(RAErrorInvalidState)));
  Result := QueueListQuery<TRAUserGameProgress>('', ReadRAAllUserProgress, Completed, '', AccountGeneration,
    function(const Credentials: TRACredentials): string
    begin
      Result := TRARequest.FetchAllUserProgress(Credentials, ConsoleID);
    end);
end;

function TRASession.FindSubset(SubsetID: Cardinal): Integer;
begin
  if FGameLoaded then
    for var Index := 0 to High(FGame.Sets) do
      if FGame.Sets[Index].ID = SubsetID then
        Exit(Index);
  Result := -1;
end;

function DescribeSubset(const AchievementSet: TRAAchievementSet): TRASubsetInfo;
begin
  Result.ID := AchievementSet.ID;
  Result.Title := AchievementSet.Title;
  Result.BadgeName := TruncateRAUTF8(AchievementSet.ImageName, MaxSubsetBadgeNameBytes);
  Result.BadgeURL := AchievementSet.ImageURL;
  Result.AchievementCount := Length(AchievementSet.Achievements);
  Result.LeaderboardCount := Length(AchievementSet.Leaderboards);
end;

function TRASession.TryGetSubsetInfo(SubsetID: Cardinal; out Info: TRASubsetInfo): Boolean;
var
  Index: Integer;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryGetSubsetInfo(SubsetID, Info));

  FLock.Acquire;
  try
    Index := FindSubset(SubsetID);
    Result := (Index >= 0) or (FUnknownGame and (SubsetID = 0));
    if Index >= 0 then
      Info := DescribeSubset(FGame.Sets[Index])
    else
      Info := Default(TRASubsetInfo);
  finally
    FLock.Release;
  end;
end;

function TRASession.CreateSubsetList: TArray<TRASubsetInfo>;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.CreateSubsetList);

  Result := nil;
  FLock.Acquire;
  try
    if not FGameLoaded then
      Exit;
    SetLength(Result, Length(FGame.Sets));
    for var Index := 0 to High(Result) do
      Result[Index] := DescribeSubset(FGame.Sets[Index]);
  finally
    FLock.Release;
  end;
end;

function TRASession.Summarize(const AchievementSet: TRAAchievementSet): TRAUserGameSummary;
var
  Unlock: TUnlockState;
  Mask: Byte;
  ProgressionCount, UnlockedProgressionCount, WinCount: Cardinal;
  When, LastUnlock, LastProgression, FirstWin: Int64;
begin
  Result := Default(TRAUserGameSummary);
  ProgressionCount := 0;
  UnlockedProgressionCount := 0;
  WinCount := 0;
  LastUnlock := 0;
  LastProgression := 0;
  FirstWin := 0;
  if FHardcoreEnabled then
    Mask := HardcoreUnlocked
  else
    Mask := SoftcoreUnlocked;

  for var Achievement in AchievementSet.Achievements do
  begin
    if Achievement.Category = RAUnofficialAchievement then
      Inc(Result.UnofficialAchievements);
    if (Achievement.Category <> RACoreAchievement) or (Achievement.ID >= RAClientWarningAchievement) then
      Continue;

    Inc(Result.CoreAchievements);
    Inc(Result.CorePoints, Achievement.Points);
    if ContainsID(FUnsupportedAchievements, Achievement.ID) then
      Inc(Result.UnsupportedAchievements);
    case Achievement.Kind of
      TRAAchievementKind.Progression:
        Inc(ProgressionCount);
      TRAAchievementKind.WinCondition:
        Inc(WinCount);
    end;

    if not FAwarded.TryGetValue(Achievement.ID, Unlock) or ((Unlock.Flags and Mask) = 0) then
      Continue;
    Inc(Result.UnlockedAchievements);
    Inc(Result.UnlockedPoints, Achievement.Points);
    When := Unlock.PublicTime;
    LastUnlock := Max(LastUnlock, When);
    case Achievement.Kind of
      TRAAchievementKind.Progression:
        begin
          Inc(UnlockedProgressionCount);
          LastProgression := Max(LastProgression, When);
        end;
      TRAAchievementKind.WinCondition:
        if (FirstWin = 0) or (When < FirstWin) then
          FirstWin := When;
    end;
  end;

  if Result.UnlockedAchievements = Result.CoreAchievements then
    Result.CompletedTime := LastUnlock;
  if ((FirstWin <> 0) or (WinCount = 0)) and (UnlockedProgressionCount = ProgressionCount) then
    Result.BeatenTime := Max(FirstWin, LastProgression);
end;

function TRASession.GetUserGameSummary: TRAUserGameSummary;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUserGameSummary);

  FLock.Acquire;
  try
    if FGameLoaded and (Length(FGame.Sets) <> 0) then
      Exit(Summarize(FGame.Sets[0]));
    Result := Default(TRAUserGameSummary);
  finally
    FLock.Release;
  end;
end;

function TRASession.GetUserSubsetSummary(SubsetID: Cardinal): TRAUserGameSummary;
var
  Index: Integer;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetUserSubsetSummary(SubsetID));

  Result := Default(TRAUserGameSummary);
  if SubsetID = 0 then
    Exit;
  FLock.Acquire;
  try
    Index := FindSubset(SubsetID);
    if Index >= 0 then
      Result := Summarize(FGame.Sets[Index]);
  finally
    FLock.Release;
  end;
end;

procedure TRASession.RecordSubsetCompletion(AchievementID: Cardinal);
begin
  for var Index := 0 to High(FGame.Sets) do
    if FSubsetCompletion[Index] = TSubsetCompletion.None then
      for var Achievement in FGame.Sets[Index].Achievements do
        if Achievement.ID = AchievementID then
        begin
          FSubsetCompletion[Index] := TSubsetCompletion.Pending;
          Break;
        end;
end;

procedure TRASession.AppendSubsetCompletionEvents(var Events: TArray<TRARuntimeEvent>);
var
  Event: TRARuntimeEvent;
begin
  for var Index := 0 to High(FSubsetCompletion) do
    if FSubsetCompletion[Index] = TSubsetCompletion.Pending then
    begin
      Event := Default(TRARuntimeEvent);
      if Index = 0 then
        Event.Kind := TRARuntimeEventKind.GameCompleted
      else
        Event.Kind := TRARuntimeEventKind.SubsetCompleted;
      Event.ID := FGame.Sets[Index].ID;
      Event.Display := FGame.Sets[Index].Title;
      Events := Events + [Event];
      FSubsetCompletion[Index] := TSubsetCompletion.Shown;
    end;
end;

procedure TRASession.QueuePendingGameEvents;
var
  Events: TArray<TRARuntimeEvent>;
begin
  Events := FIndicators.TakeNotifications;
  // Without a callback, EvaluateFrame delivers the completion events to its caller.
  if Assigned(FClientEventHandler) then
    AppendSubsetCompletionEvents(Events);
  QueueFrameEvents(Events, 0, 0);
end;

function TRASession.GetDisconnected: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetDisconnected);

  FLock.Acquire;
  try
    Result := FDelayedSubmissionCount <> 0;
  finally
    FLock.Release;
  end;
end;

procedure TRASession.QueueConnectionChange(WasDisconnected: Boolean);
var
  Event: TRARuntimeEvent;
  IsDisconnected: Boolean;
begin
  IsDisconnected := FDelayedSubmissionCount <> 0;
  if IsDisconnected = WasDisconnected then
    Exit;
  Event := Default(TRARuntimeEvent);
  if IsDisconnected then
    Event.Kind := TRARuntimeEventKind.Disconnected
  else
    Event.Kind := TRARuntimeEventKind.Reconnected;
  QueueClientEvent(Event);
end;

function TRASession.TryPollConnectionEvent(out Event: TRARuntimeEvent): Boolean;
var
  Offline: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.TryPollConnectionEvent(Event));

  Event := Default(TRARuntimeEvent);
  FLock.Acquire;
  try
    Offline := FDelayedSubmissionCount <> 0;
    if Offline = FReportedDisconnected then
      Exit(False);

    FReportedDisconnected := Offline;
    if Offline then
      Event.Kind := TRARuntimeEventKind.Disconnected
    else
      Event.Kind := TRARuntimeEventKind.Reconnected;
    Result := True;
  finally
    FLock.Release;
  end;
end;

function TRASession.PendingCount: Integer;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.PendingCount);

  FLock.Acquire;
  try
    Result := FPending.Count;
  finally
    FLock.Release;
  end;
end;

function TRASession.HasRichPresence: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.HasRichPresence);

  FLock.Acquire;
  try
    Result := FGameLoaded and FRuntime.HasRichPresence;
  finally
    FLock.Release;
  end;
end;

function TRASession.ReadRichPresenceMessage(out UsesGameTitle: Boolean): string;
begin
  UsesGameTitle := False;
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not (FGameLoaded or FUnknownGame) then
        Exit('');
      Result := '';
      if FGameLoaded then
        Result := FRuntime.GetRichPresence;
      UsesGameTitle := Result = '';
      if UsesGameTitle then
        Result := 'Playing ' + FGame.Title;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.GetRichPresenceMessage: string;
var
  UsesGameTitle: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetRichPresenceMessage);
  Result := ReadRichPresenceMessage(UsesGameTitle);
end;

function TRASession.GetRichPresenceMessage(Buffer: PAnsiChar; BufferSize: NativeUInt): NativeUInt;
var
  UsesGameTitle: Boolean;
  MessageText: string;
begin
  if (Buffer = nil) or (BufferSize = 0) then
    Exit(0);
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.GetRichPresenceMessage(Buffer, BufferSize));

  MessageText := ReadRichPresenceMessage(UsesGameTitle);
  if MessageText = '' then
    Exit(0);
  Result := CopyRAUTF8Text(MessageText, Buffer, BufferSize);
  if UsesGameTitle and (Result >= BufferSize) then
    Result := BufferSize - 1;
end;

function TRASession.IsProcessingRequired: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.IsProcessingRequired);

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      Result := FLoad.WaitingForMemory or (FGameLoaded and FRuntime.IsProcessingRequired);
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

procedure TRASession.SetShareRichPresence(Value: Boolean);
begin
  FLock.Acquire;
  try
    FShareRichPresence := Value;
  finally
    FLock.Release;
  end;
  var external := ExternalSession;
  if external <> nil then
    external.Session.SetShareRichPresence(Value);
end;

procedure TRASession.SetRichPresenceOverride(const Handler: TRARichPresenceOverride);
var
  Previous: TRARichPresenceOverride;
begin
  FLock.Acquire;
  try
    Previous := FRichPresenceOverride;
    FRichPresenceOverride := Handler;
  finally
    FLock.Release;
  end;
  Previous := nil;
end;

function TRASession.PumpNetwork(out Submission: TRASubmission): Boolean;
begin
  Submission := Default(TRASubmission);
  if TInterlocked.CompareExchange(FNetworkPumping, 1, 0) <> 0 then
    Exit(False);
  try
    try
      Result := PumpNetworkCore(Submission);
    finally
      DispatchClientEvents;
    end;
  finally
    TInterlocked.Exchange(FNetworkPumping, 0);
  end;
end;

function TRASession.TryBuildScoreboardEvent(ID: Cardinal; const Scores: TRALeaderboardResponse; out Event: TRARuntimeEvent): Boolean;
var
  Board: TRALeaderboardDefinition;
begin
  Event := Default(TRARuntimeEvent);
  Result := TryFindLeaderboard(ID, Board);
  if not Result then
    Exit;

  Event.Kind := TRARuntimeEventKind.LeaderboardScoreboard;
  Event.ID := ID;
  Event.Scoreboard.Submitted := FormatRAValue(Scores.Score, Board.ValueFormat);
  Event.Scoreboard.PersonalBest := FormatRAValue(Scores.BestScore, Board.ValueFormat);
  Event.Scoreboard.Rank := Scores.Rank;
  Event.Scoreboard.EntryCount := Scores.EntryCount;
  Event.Display := Event.Scoreboard.Submitted;
  SetLength(Event.Scoreboard.TopEntries, Length(Scores.TopEntries));
  for var Index := 0 to High(Scores.TopEntries) do
  begin
    Event.Scoreboard.TopEntries[Index].UserName := Scores.TopEntries[Index].UserName;
    Event.Scoreboard.TopEntries[Index].Rank := Scores.TopEntries[Index].Rank;
    Event.Scoreboard.TopEntries[Index].Display := FormatRAValue(Scores.TopEntries[Index].Score, Board.ValueFormat);
  end;
end;

procedure TRASession.QueueSubmissionEvent(const Pending: TPending; const Submission: TRASubmission);
var
  Event: TRARuntimeEvent;
begin
  if not Assigned(FClientEventHandler) then
    Exit;
  if Submission.State = TRASubmissionState.Rejected then
  begin
    Event := Default(TRARuntimeEvent);
    Event.Kind := TRARuntimeEventKind.ServerError;
    Event.ID := Pending.Event.ID;
    Event.Display := Submission.ErrorMessage;
    Event.Value := Submission.ResultCode;
    if Pending.Event.Kind = TRARuntimeEventKind.LeaderboardTriggered then
      Event.API := 'submit_lboard_entry'
    else
      Event.API := 'award_achievement';
  end
  else if (Submission.State <> TRASubmissionState.Confirmed) or
    (Pending.Event.Kind <> TRARuntimeEventKind.LeaderboardTriggered) or
    (Pending.Attempts > ImmediateRetryAttempts) or
    not FGameLoaded or (Pending.Generation <> FGameGeneration) or
    not TryBuildScoreboardEvent(Pending.Event.ID, Submission.Leaderboard, Event) then
    Exit;
  QueueClientEvent(Event);
end;

function LimitPingMessage(const MessageText: string): string;
var
  Encoded: UTF8String;
  Count, Terminator: Integer;
begin
  Terminator := Pos(#0, MessageText);
  if Terminator = 0 then
    Result := MessageText
  else
    Result := Copy(MessageText, 1, Terminator - 1);
  Encoded := UTF8String(Result);
  if Length(Encoded) <= MaxPingMessageBytes then
    Exit;
  Count := MaxPingMessageBytes;
  while (Count > 0) and ((Byte(Encoded[Count + 1]) and $C0) = $80) do
    Dec(Count);
  SetLength(Encoded, Count);
  Result := UTF8ToString(Encoded);
end;

procedure TRASession.SendPing(const Ping: TPendingPing; const Credentials: TRACredentials);
var
  MessageText: string;
  Overridden: Boolean;
  Response: TJSONObject;
begin
  Overridden := False;
  if Assigned(Ping.OverrideMessage) then
  try
    Overridden := Ping.OverrideMessage(MessageText);
  except
    Log(TRAClientLogLevel.Warning, 'Rich Presence override failed', []);
  end;

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if (Ping.AccountGeneration <> FAccountGeneration) or (Ping.GameGeneration <> FGameGeneration) or
        (Ping.HostRevision <> FHostRevision) or not FGameLoaded or (FLogin.Ticket <> nil) then
        Exit;
      if not (Ping.ShareRichPresence and FShareRichPresence) then
        MessageText := ''
      else if not Overridden then
        MessageText := FRuntime.GetRichPresence;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;

  try
    Response := PostRequest(TRARequest.Ping(Credentials, Ping.GameID, Ping.GameHash,
        LimitPingMessage(MessageText), Ping.Hardcore), Ping.Host);
    Response.Free;
  except
    on Error: ERAServerError do
      LogRequestFailure(TRAClientLogLevel.Warning, 'Ping', Error.StatusCode);
    on ENetException do
      LogRequestFailure(TRAClientLogLevel.Warning, 'Ping', 0);
    on ERAProtocolError do
      LogRequestFailure(TRAClientLogLevel.Warning, 'Ping', 0);
  end;
end;

procedure TRASession.SchedulePing(Deadline: UInt64);
begin
  Inc(FScheduledOrder);
  FNextPing := Deadline;
  FNextPingOrder := FScheduledOrder;
end;

function TRASession.PumpNetworkCore(out Submission: TRASubmission): Boolean;
var
  Pending: TPending;
  Ping: TPendingPing;
  PendingIndex: Integer;
  PingDue, WasDisconnected: Boolean;
  Now, AccountGeneration, HostRevision, RetryAt: UInt64;
  Credentials: TRACredentials;
  Age: Cardinal;
  Form, Host, Operation: string;
  Response: TJSONObject;
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    if NowMilliseconds >= NetworkRetryAt then
      PumpQuery;
    external := ExternalSession;
    if external <> nil then
      Exit(external.Session.PumpNetwork(Submission));
    Exit(False);
  end;
  Now := NowMilliseconds;
  if Now < NetworkRetryAt then
    Exit(False);
  if PumpLogin then
    Exit(False);
  PumpGameLoad;
  Now := NowMilliseconds;
  if Now < NetworkRetryAt then
    Exit(False);
  PumpMediaChange;
  if NowMilliseconds < NetworkRetryAt then
    Exit(False);
  PumpQuery;
  external := ExternalSession;
  if external <> nil then
    Exit(external.Session.PumpNetwork(Submission));
  Now := NowMilliseconds;
  if Now < NetworkRetryAt then
    Exit(False);

  PendingIndex := -1;
  RetryAt := Now;
  PingDue := False;
  FLock.Acquire;
  try
    if FLogin.Ticket <> nil then
      Exit(False);
    AccountGeneration := FAccountGeneration;
    HostRevision := FHostRevision;
    Host := FHost;
    Credentials := FUser.Credentials;
    for var Index := 0 to FPending.Count - 1 do
    begin
      var DueAt := FPending[Index].RetryAt;
      if (DueAt > Now) or ((PendingIndex >= 0) and (DueAt >= RetryAt)) then
        Continue;
      PendingIndex := Index;
      Pending := FPending[Index];
      RetryAt := DueAt;
      if RetryAt = 0 then
        Break;
    end;

    // Delayed submissions and pings run by deadline, then in the order they were scheduled.
    if FGameLoaded and (FSpectatorMode <> TRASpectatorMode.Locked) and (FNextPing <= Now) and
      (not FPlayedSincePing or (PendingIndex < 0) or (Pending.Attempts <= ImmediateRetryAttempts) or
      (FNextPing < RetryAt) or ((FNextPing = RetryAt) and (FNextPingOrder < Pending.RetryOrder))) then
    begin
      SchedulePing(Now + PingPeriod);
      PingDue := FPlayedSincePing;
    end;
    if PingDue then
    begin
      Ping.GameGeneration := FGameGeneration;
      Ping.AccountGeneration := AccountGeneration;
      Ping.HostRevision := HostRevision;
      Ping.Host := Host;
      Ping.GameID := FGame.ID;
      Ping.GameHash := FMedia.Hash;
      Ping.Hardcore := FHardcoreEnabled;
      Ping.ShareRichPresence := FShareRichPresence;
      if Ping.ShareRichPresence then
        Ping.OverrideMessage := FRichPresenceOverride;
      FPlayedSincePing := False;
      PendingIndex := -1;
    end;
  finally
    FLock.Release;
  end;
  if PingDue then
    SendPing(Ping, Credentials);
  if PendingIndex < 0 then
    Exit(False);

  Submission.Event := Pending.Event;
  Submission.Hardcore := Pending.Hardcore;
  Submission.State := TRASubmissionState.Confirmed;
  Age := 0;
  if Now >= Pending.CreatedAt then
    Age := Cardinal(Min((Now - Pending.CreatedAt) div MillisecondsPerSecond, UInt64(High(Cardinal))));
  if Pending.Event.Kind = TRARuntimeEventKind.LeaderboardTriggered then
  begin
    Form := TRARequest.SubmitLeaderboard(Credentials, Pending.Event.ID, Pending.Event.Value, Pending.GameHash, Age);
    Operation := Format('Leaderboard %u submission', [Pending.Event.ID]);
  end
  else
  begin
    Form := TRARequest.AwardAchievement(Credentials, Pending.Event.ID, Pending.GameHash, Pending.Hardcore, Age);
    Operation := Format('Achievement %u award', [Pending.Event.ID]);
  end;
  try
    Response := PostRequest(Form, Host);
    try
      if Pending.Event.Kind = TRARuntimeEventKind.LeaderboardTriggered then
        Submission.Leaderboard := ReadRALeaderboardResponse(Response)
      else
        Submission.Award := ReadRAAwardResponse(Response, Pending.Event.ID);
    finally
      Response.Free;
    end;
  except
    on Error: ERAServerError do
    begin
      if RetryableSubmission(Error) then
      begin
        Submission.State := TRASubmissionState.RetryScheduled;
        DeferNetwork(Error, AccountGeneration, HostRevision);
      end
      else
        Submission.State := TRASubmissionState.Rejected;
      Submission.ErrorMessage := Error.Message;
      Submission.ServerCode := Error.Code;
      Submission.HTTPStatus := Error.StatusCode;
      Submission.ResultCode := Error.ResultCode;
    end;
    on Error: ENetException do
    begin
      if (Error is ENetHTTPClientException) or (Error is ENetHTTPRequestException) or
        (Error is ENetHTTPResponseException) or (Error is ENetHTTPException) then
        Submission.State := TRASubmissionState.RetryScheduled
      else
        Submission.State := TRASubmissionState.Rejected;
      Submission.ErrorMessage := Error.Message;
      Submission.ResultCode := RAErrorNoResponse;
    end;
    on Error: ERAProtocolError do
    begin
      Submission.State := TRASubmissionState.Rejected;
      Submission.ErrorMessage := Error.Message;
      Submission.ResultCode := Error.ResultCode;
    end;
  end;

  FLock.Acquire;
  try
    if (AccountGeneration <> FAccountGeneration) or (HostRevision <> FHostRevision) then
    begin
      Submission := Default(TRASubmission);
      Exit(False);
    end;
    // Within one account and host revision, only the network worker removes entries.
    WasDisconnected := FDelayedSubmissionCount <> 0;
    FPending.Delete(PendingIndex);
    if Pending.Attempts > ImmediateRetryAttempts then
      Dec(FDelayedSubmissionCount);
    if (Submission.State = TRASubmissionState.Confirmed) and
      (Pending.Event.Kind = TRARuntimeEventKind.AchievementTriggered) then
    begin
      if Submission.Award.HasScore then
        FUser.Score := Submission.Award.Score;
      if Submission.Award.HasSoftcoreScore then
        FUser.SoftcoreScore := Submission.Award.SoftcoreScore;
      if (Submission.Award.AchievementsRemaining = 0) and (Pending.Generation = FGameGeneration) then
        RecordSubsetCompletion(Pending.Event.ID);
    end;
    if Submission.State = TRASubmissionState.RetryScheduled then
    begin
      if Pending.Attempts < 9 then
        Inc(Pending.Attempts);
      if Pending.Attempts = ImmediateRetryAttempts then
        FPending.Insert(PendingIndex, Pending)
      else
      begin
        Pending.RetryAt := NowMilliseconds + RetryDelay(Pending.Attempts);
        Inc(FScheduledOrder);
        Pending.RetryOrder := FScheduledOrder;
        FPending.Add(Pending);
        Inc(FDelayedSubmissionCount);
      end;
    end;
    QueueSubmissionEvent(Pending, Submission);
    QueueConnectionChange(WasDisconnected);
  finally
    FLock.Release;
  end;
  case Submission.State of
    TRASubmissionState.Confirmed:
      Log(TRAClientLogLevel.Info, '%s completed', [Operation]);
    TRASubmissionState.Rejected:
      LogRequestFailure(TRAClientLogLevel.Error, Operation, Submission.HTTPStatus);
    TRASubmissionState.RetryScheduled:
      begin
        RetryAt := Max(Pending.RetryAt, NetworkRetryAt);
        Now := NowMilliseconds;
        if RetryAt <= Now then
          Log(TRAClientLogLevel.Error, '%s failed, retrying immediately', [Operation])
        else
          Log(TRAClientLogLevel.Error, '%s failed, retrying in %u seconds',
            [Operation, (RetryAt - Now - 1) div MillisecondsPerSecond + 1]);
      end;
  end;
  Result := True;
end;

function TRASession.ProgressSize: NativeUInt;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.ProgressSize);

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(0);
      Result := FRuntime.ProgressSize;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.SerializeProgress(Buffer: PByte): Integer;
begin
  Result := SerializeProgressSized(Buffer, High(Cardinal));
end;

function TRASession.DeserializeProgress(Buffer: PByte): Integer;
begin
  Result := DeserializeProgressSized(Buffer, High(Cardinal));
end;

function TRASession.SerializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.SerializeProgressSized(Buffer, BufferSize));

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(RAErrorNoGameLoaded);
      Result := FRuntime.SerializeProgressSized(Buffer, BufferSize);
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.DeserializeProgressSized(Buffer: PByte; BufferSize: NativeUInt): Integer;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.DeserializeProgressSized(Buffer, BufferSize));
  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(RAErrorNoGameLoaded);
      if Buffer = nil then
      begin
        FRuntime.Reset;
        Result := RAErrorOK;
      end
      else
      begin
        Result := FRuntime.DeserializeProgressSized(Buffer, BufferSize);
        if Result = RAErrorOK then
          FRuntime.RefreshRestoredLeaderboardTrackers;
      end;

      ReconcileRestoredProgress;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
  DispatchClientEvents;
end;

procedure TRASession.ReconcileRestoredProgress;
begin
  FIndicators.Reconcile(FRuntime, FGame, True);
  QueuePendingGameEvents;
end;

function TRASession.CaptureProgress: TBytes;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.CaptureProgress);

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(nil);
      Result := FRuntime.CaptureProgress;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
end;

function TRASession.RestoreProgress(const Data: TBytes): Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
    Exit(external.Session.RestoreProgress(Data));

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not FGameLoaded then
        Exit(False);
      Result := FRuntime.RestoreProgress(Data);
      if Result then
      begin
        if IsRCProgress(Data) then
          FRuntime.RefreshRestoredLeaderboardTrackers;
        ReconcileRestoredProgress;
      end;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
  DispatchClientEvents;
end;

procedure TRASession.Reset;
var
  Media: TRAMediaInfo;
  Entry: TGameHashEntry;
  KeepGame: Boolean;
begin
  var external := ExternalSession;
  if external <> nil then
  begin
    external.Session.Reset;
    Exit;
  end;

  FRuntimeLock.Acquire;
  try
    FLock.Acquire;
    try
      if not (FGameLoaded or FUnknownGame) then
        Exit;
      Media := FMedia;
      KeepGame := Media.GameID = FGame.ID;
      if FUnknownGame then
        KeepGame := KeepGame and (Media.Kind = TRAMediaKind.Unrecognized) and
          FMediaByHash.TryGetValue(MediaHashKey(Media.Hash), Entry) and (Entry.Media.GameID = 0);
      if KeepGame and FGameLoaded then
      begin
        FRuntime.Reset;
        FIndicators.Reconcile(FRuntime, FGame, True);
        FWaitingForReset := False;
        QueuePendingGameEvents;
      end
      else if not KeepGame then
        MarkGameUnloaded;
    finally
      FLock.Release;
    end;
  finally
    FRuntimeLock.Release;
  end;
  DispatchClientEvents;
  if KeepGame then
    Log(TRAClientLogLevel.Info, 'Resetting runtime', [])
  else
    Log(TRAClientLogLevel.Warning, 'Disabling runtime. Reset with non-game media loaded: %u (%s)',
      [Media.GameID, Media.Hash]);
end;

end.

