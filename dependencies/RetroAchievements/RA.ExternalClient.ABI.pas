unit RA.ExternalClient.ABI;

interface

{$ALIGN 8}
{$SCOPEDENUMS ON}

uses
  RA.Errors;

const
  RAExternalClientABIVersion = 7;
  RAExternalOK = RAErrorOK;
  RAExternalInvalidState = RAErrorInvalidState;
  RAExternalAPIFailure = RAErrorAPIFailure;
  RAExternalLoginRequired = RAErrorLoginRequired;
  RAExternalNoGameLoaded = RAErrorNoGameLoaded;
  RAExternalHardcoreDisabled = RAErrorHardcoreDisabled;
  RAExternalAborted = RAErrorAborted;
  RAExternalAccessDenied = RAErrorAccessDenied;
  RAExternalInvalidCredentials = RAErrorInvalidCredentials;
  RAExternalExpiredToken = RAErrorExpiredToken;
  RAExternalInsufficientBuffer = RAErrorInsufficientBuffer;
  RAExternalNotFound = RAErrorNotFound;

const
  RAExternalEventAchievementTriggered = 1;
  RAExternalEventLeaderboardStarted = 2;
  RAExternalEventLeaderboardFailed = 3;
  RAExternalEventLeaderboardSubmitted = 4;
  RAExternalEventChallengeShow = 5;
  RAExternalEventChallengeHide = 6;
  RAExternalEventProgressShow = 7;
  RAExternalEventProgressHide = 8;
  RAExternalEventProgressUpdate = 9;
  RAExternalEventTrackerShow = 10;
  RAExternalEventTrackerHide = 11;
  RAExternalEventTrackerUpdate = 12;
  RAExternalEventScoreboard = 13;
  RAExternalEventReset = 14;
  RAExternalEventGameCompleted = 15;
  RAExternalEventServerError = 16;
  RAExternalEventDisconnected = 17;
  RAExternalEventReconnected = 18;
  RAExternalEventSubsetCompleted = 19;

type
  // rcheevos uses 64-bit time_t with MSVC on Win32/Win64 and on 64-bit Unix.
  TRAExternalTime = Int64;

  PRAExternalUserV1 = ^TRAExternalUserV1;

  TRAExternalUserV1 = record
    DisplayName, UserName, Token: PAnsiChar;
    Score, SoftcoreScore, UnreadMessages: Cardinal;
  end;

  PRAExternalUserV3 = ^TRAExternalUserV3;

  TRAExternalUserV3 = record
    Data: TRAExternalUserV1;
    AvatarURL: PAnsiChar;
  end;

  PRAExternalUserV124 = ^TRAExternalUserV124;

  TRAExternalUserV124 = record
    Data: TRAExternalUserV3;
    AvatarUpdated: TRAExternalTime;
  end;

  PRAExternalGameV1 = ^TRAExternalGameV1;

  TRAExternalGameV1 = record
    ID, ConsoleID: Cardinal;
    Title, Hash, BadgeName: PAnsiChar;
  end;

  PRAExternalGameV3 = ^TRAExternalGameV3;

  TRAExternalGameV3 = record
    Data: TRAExternalGameV1;
    BadgeURL: PAnsiChar;
  end;

  PRAExternalSubsetV1 = ^TRAExternalSubsetV1;

  TRAExternalSubsetV1 = record
    ID: Cardinal;
    Title: PAnsiChar;
    BadgeName: array[0..15] of AnsiChar;
    AchievementCount, LeaderboardCount: Cardinal;
  end;

  PRAExternalSubsetV3 = ^TRAExternalSubsetV3;

  TRAExternalSubsetV3 = record
    Data: TRAExternalSubsetV1;
    BadgeURL: PAnsiChar;
  end;

  PRAExternalAchievementV1 = ^TRAExternalAchievementV1;

  TRAExternalAchievementV1 = record
    Title, Description: PAnsiChar;
    BadgeName: array[0..7] of AnsiChar;
    MeasuredProgress: array[0..23] of AnsiChar;
    MeasuredPercent: Single;
    ID, Points: Cardinal;
    UnlockTime: TRAExternalTime;
    State, Category, Bucket, Unlocked: Byte;
    Rarity, RarityHardcore: Single;
    Kind: Byte;
  end;

  PRAExternalAchievementV3 = ^TRAExternalAchievementV3;

  TRAExternalAchievementV3 = record
    Data: TRAExternalAchievementV1;
    BadgeURL, BadgeLockedURL: PAnsiChar;
  end;

  TRAExternalUserGameSummaryV1 = record
    CoreAchievements, UnofficialAchievements, UnlockedAchievements, UnsupportedAchievements: Cardinal;
    CorePoints, UnlockedPoints: Cardinal;
  end;

  TRAExternalUserGameSummaryV5 = record
    Data: TRAExternalUserGameSummaryV1;
    BeatenTime, CompletedTime: TRAExternalTime;
  end;

  PRAExternalLeaderboard = ^TRAExternalLeaderboard;

  TRAExternalLeaderboard = record
    Title, Description, TrackerValue: PAnsiChar;
    ID: Cardinal;
    State, Format, LowerIsBetter: Byte;
  end;

  PRAExternalLeaderboardTracker = ^TRAExternalLeaderboardTracker;

  TRAExternalLeaderboardTracker = record
    Display: array[0..23] of AnsiChar;
    ID: Cardinal;
  end;

  PRAExternalScoreboardEntry = ^TRAExternalScoreboardEntry;

  TRAExternalScoreboardEntry = record
    UserName: PAnsiChar;
    Rank: Cardinal;
    Score: array[0..23] of AnsiChar;
  end;

  PRAExternalScoreboard = ^TRAExternalScoreboard;

  TRAExternalScoreboard = record
    LeaderboardID: Cardinal;
    SubmittedScore, BestScore: array[0..23] of AnsiChar;
    Rank, EntryCount: Cardinal;
    TopEntries: PRAExternalScoreboardEntry;
    TopEntryCount: Cardinal;
  end;

  PRAExternalServerError = ^TRAExternalServerError;

  TRAExternalServerError = record
    MessageText, API: PAnsiChar;
    ResultCode: Integer;
    RelatedID: Cardinal;
  end;

  PRAExternalEvent = ^TRAExternalEvent;

  TRAExternalEvent = record
    Kind: Cardinal;
    Achievement: PRAExternalAchievementV1;
    Leaderboard: PRAExternalLeaderboard;
    Tracker: PRAExternalLeaderboardTracker;
    Scoreboard: PRAExternalScoreboard;
    ServerError: PRAExternalServerError;
    Subset: PRAExternalSubsetV1;
  end;

  // Buckets use the same layout for V1 and V3, with a pointer array of the corresponding record.
  TRAExternalCatalogEntries = ^Pointer;

  PRAExternalCatalogBucket = ^TRAExternalCatalogBucket;

  TRAExternalCatalogBucket = record
    Entries: TRAExternalCatalogEntries;
    Count: Cardinal;
    LabelText: PAnsiChar;
    SubsetID: Cardinal;
    Kind: Byte;
  end;

  TRAExternalDestroyList = procedure(List: Pointer); cdecl;

  PRAExternalBucketList = ^TRAExternalBucketList;

  TRAExternalBucketList = record
    Buckets: PRAExternalCatalogBucket;
    Count: Cardinal;
    Destroy: TRAExternalDestroyList;
  end;

  PRAExternalSubsetList = ^TRAExternalSubsetList;

  TRAExternalSubsetList = record
    Entries: TRAExternalCatalogEntries;
    Count: Cardinal;
    Destroy: TRAExternalDestroyList;
  end;

  TRAExternalAction = procedure; cdecl;

  TRAExternalBoolean = function: Integer; cdecl;

  TRAExternalSetBoolean = procedure(Value: Integer); cdecl;

  TRAExternalCopyText = function(Buffer: PAnsiChar; Size: NativeUInt): NativeUInt; cdecl;

  TRAExternalGetUserV1 = function: PRAExternalUserV1; cdecl;

  TRAExternalGetUserV3 = function: PRAExternalUserV3; cdecl;

  TRAExternalGetGameV1 = function: PRAExternalGameV1; cdecl;

  TRAExternalGetGameV3 = function: PRAExternalGameV3; cdecl;

  TRAExternalGetSubsetV1 = function(ID: Cardinal): PRAExternalSubsetV1; cdecl;

  TRAExternalGetSubsetV3 = function(ID: Cardinal): PRAExternalSubsetV3; cdecl;

  TRAExternalGetAchievementV1 = function(ID: Cardinal): PRAExternalAchievementV1; cdecl;

  TRAExternalGetAchievementV3 = function(ID: Cardinal): PRAExternalAchievementV3; cdecl;

  TRAExternalGetNextAchievement = function(ID: Cardinal; Bucket: Integer): PRAExternalAchievementV3; cdecl;

  TRAExternalGetLeaderboard = function(ID: Cardinal): PRAExternalLeaderboard; cdecl;

  TRAExternalGetGameSummaryV1 = procedure(var Summary: TRAExternalUserGameSummaryV1); cdecl;

  TRAExternalGetGameSummaryV5 = procedure(var Summary: TRAExternalUserGameSummaryV5); cdecl;

  TRAExternalGetSubsetSummary = procedure(ID: Cardinal; var Summary: TRAExternalUserGameSummaryV5); cdecl;

  TRAExternalCreateAchievementList = function(Category, Grouping: Integer): PRAExternalBucketList; cdecl;

  TRAExternalCreateLeaderboardList = function(Grouping: Integer): PRAExternalBucketList; cdecl;

  TRAExternalCreateSubsetList = function: PRAExternalSubsetList; cdecl;

  TRAExternalCanPause = function(var Frames: Cardinal): Integer; cdecl;

  TRAExternalProgressSize = function: NativeUInt; cdecl;

  TRAExternalProgressBuffer = function(Buffer: PByte; Size: NativeUInt): Integer; cdecl;

  TRAExternalAddGameHash = procedure(Hash: PAnsiChar; GameID: Cardinal); cdecl;

  TRAExternalSetText = procedure(Value: PAnsiChar); cdecl;

  TRAExternalLogCallback = procedure(Message: PAnsiChar; Client: Pointer); cdecl;

  TRAExternalEventCallback = procedure(Event: PRAExternalEvent; Client: Pointer); cdecl;

  TRAExternalMemoryCallback = function(Address: Cardinal; Buffer: PByte; Count: Cardinal; Client: Pointer): Cardinal; cdecl;

  TRAExternalClockCallback = function(Client: Pointer): UInt64; cdecl;

  TRAExternalEnableLogging = procedure(Client: Pointer; Level: Integer; Handler: TRAExternalLogCallback); cdecl;

  TRAExternalSetEventHandler = procedure(Client: Pointer; Handler: TRAExternalEventCallback); cdecl;

  TRAExternalSetReadMemory = procedure(Client: Pointer; Handler: TRAExternalMemoryCallback); cdecl;

  TRAExternalSetClock = procedure(Client: Pointer; Handler: TRAExternalClockCallback); cdecl;

  PRAExternalLeaderboardEntry = ^TRAExternalLeaderboardEntry;

  TRAExternalLeaderboardEntry = record
    UserName: PAnsiChar;
    Display: array[0..23] of AnsiChar;
    Submitted: TRAExternalTime;
    Rank, Index: Cardinal;
  end;

  PRAExternalLeaderboardEntryList = ^TRAExternalLeaderboardEntryList;

  TRAExternalLeaderboardEntryList = record
    Entries: PRAExternalLeaderboardEntry;
    Count, TotalEntries: Cardinal;
    UserIndex: Integer;
    Destroy: TRAExternalDestroyList;
  end;

  TRAExternalAsyncCallback = procedure(Code: Integer; Message: PAnsiChar; Client, Data: Pointer); cdecl;

  TRAExternalEntriesCallback = procedure(Code: Integer; Message: PAnsiChar; List: PRAExternalLeaderboardEntryList; Client, Data: Pointer); cdecl;

  TRAExternalAbortAsync = procedure(Handle: Pointer); cdecl;

  TRAExternalBeginLogin = function(Client: Pointer; UserName, Secret: PAnsiChar; Callback: TRAExternalAsyncCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginIdentifyGame = function(Client: Pointer; ConsoleID: Cardinal; Path: PAnsiChar; Data: PByte; Size: NativeUInt; Callback: TRAExternalAsyncCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginHash = function(Client: Pointer; Hash: PAnsiChar; Callback: TRAExternalAsyncCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginLoadSubset = function(Client: Pointer; SubsetID: Cardinal; Callback: TRAExternalAsyncCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginIdentifyMedia = function(Client: Pointer; Path: PAnsiChar; Data: PByte; Size: NativeUInt; Callback: TRAExternalAsyncCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginEntries = function(Client: Pointer; ID, FirstEntry, Count: Cardinal; Callback: TRAExternalEntriesCallback; Context: Pointer): Pointer; cdecl;

  TRAExternalBeginEntriesAroundUser = function(Client: Pointer; ID, Count: Cardinal; Callback: TRAExternalEntriesCallback; Context: Pointer): Pointer; cdecl;

  PRAExternalClientTable = ^TRAExternalClientTable;

  TRAExternalClientTable = record
    Destroy: TRAExternalAction;

    EnableLogging: TRAExternalEnableLogging;
    SetEventHandler: TRAExternalSetEventHandler;
    SetReadMemory: TRAExternalSetReadMemory;
    SetGetTimeMillisecs: TRAExternalSetClock;
    SetHost: TRAExternalSetText;
    GetUserAgentClause: TRAExternalCopyText;

    SetHardcoreEnabled: TRAExternalSetBoolean;
    GetHardcoreEnabled: TRAExternalBoolean;
    SetUnofficialEnabled: TRAExternalSetBoolean;
    GetUnofficialEnabled: TRAExternalBoolean;
    SetEncoreModeEnabled: TRAExternalSetBoolean;
    GetEncoreModeEnabled: TRAExternalBoolean;
    SetSpectatorModeEnabled: TRAExternalSetBoolean;
    GetSpectatorModeEnabled: TRAExternalBoolean;

    AbortAsync: TRAExternalAbortAsync;
    BeginLoginWithPassword, BeginLoginWithToken: TRAExternalBeginLogin;
    Logout: TRAExternalAction;
    GetUserInfo: TRAExternalGetUserV1;

    BeginIdentifyAndLoadGame: TRAExternalBeginIdentifyGame;
    BeginLoadGame: TRAExternalBeginHash;
    GetGameInfo: TRAExternalGetGameV1;
    BeginLoadSubset: TRAExternalBeginLoadSubset; // Deprecated by rcheevos.
    GetSubsetInfo: TRAExternalGetSubsetV1;
    UnloadGame: TRAExternalAction;
    GetUserGameSummary: TRAExternalGetGameSummaryV1;
    BeginIdentifyAndChangeMedia: TRAExternalBeginIdentifyMedia;
    BeginChangeMedia: TRAExternalBeginHash;

    CreateAchievementList: TRAExternalCreateAchievementList;
    HasAchievements: TRAExternalBoolean;
    GetAchievementInfo: TRAExternalGetAchievementV1;
    CreateLeaderboardList: TRAExternalCreateLeaderboardList;
    HasLeaderboards: TRAExternalBoolean;
    GetLeaderboardInfo: TRAExternalGetLeaderboard;
    BeginFetchLeaderboardEntries: TRAExternalBeginEntries;
    BeginFetchLeaderboardEntriesAroundUser: TRAExternalBeginEntriesAroundUser;

    GetRichPresenceMessage: TRAExternalCopyText;
    HasRichPresence: TRAExternalBoolean;
    DoFrame, Idle: TRAExternalAction;
    IsProcessingRequired: TRAExternalBoolean;
    CanPause: TRAExternalCanPause;
    Reset: TRAExternalAction;

    ProgressSize: TRAExternalProgressSize;
    SerializeProgress, DeserializeProgress: TRAExternalProgressBuffer;

    // V2
    AddGameHash: TRAExternalAddGameHash;
    LoadUnknownGame: TRAExternalSetText;

    // V3
    GetUserInfoV3: TRAExternalGetUserV3;
    GetGameInfoV3: TRAExternalGetGameV3;
    GetSubsetInfoV3: TRAExternalGetSubsetV3;
    GetAchievementInfoV3: TRAExternalGetAchievementV3;
    CreateAchievementListV3: TRAExternalCreateAchievementList;

    // V4
    SetAllowBackgroundMemoryReads: TRAExternalSetBoolean;

    // V5
    GetUserGameSummaryV5: TRAExternalGetGameSummaryV5;
    GetUserSubsetSummary: TRAExternalGetSubsetSummary;

    // V6
    CreateSubsetList: TRAExternalCreateSubsetList;

    // V7
    GetNextAchievementInfo: TRAExternalGetNextAchievement;
  end;

function RAExternalClientTableSize(Version: Cardinal): NativeUInt;

implementation

function RAExternalClientTableSize(Version: Cardinal): NativeUInt;
var
  Table: TRAExternalClientTable;
begin
  // Return the byte offset of the first slot belonging to the following version.
  case Version of
    1:
      Result := NativeUInt(@@Table.AddGameHash) - NativeUInt(@Table);
    2:
      Result := NativeUInt(@@Table.GetUserInfoV3) - NativeUInt(@Table);
    3:
      Result := NativeUInt(@@Table.SetAllowBackgroundMemoryReads) - NativeUInt(@Table);
    4:
      Result := NativeUInt(@@Table.GetUserGameSummaryV5) - NativeUInt(@Table);
    5:
      Result := NativeUInt(@@Table.CreateSubsetList) - NativeUInt(@Table);
    6:
      Result := NativeUInt(@@Table.GetNextAchievementInfo) - NativeUInt(@Table);
    7:
      Result := SizeOf(Table);
  else
    Result := 0;
  end;
end;

end.

