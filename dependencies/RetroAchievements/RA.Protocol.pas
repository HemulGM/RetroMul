unit RA.Protocol;

interface

{$SCOPEDENUMS ON}

uses
  System.JSON, System.SysUtils, RA.Format;

const
  RAAPIHost = 'https://retroachievements.org';
  RARequestPath = '/dorequest.php';
  RARequestURL = RAAPIHost + RARequestPath;
  RAMediaHost = 'https://media.retroachievements.org';
  RAFormContentType = 'application/x-www-form-urlencoded';
  RAServerResponseClientError = -1;
  RAServerResponseRetryableClientError = -2;
  // rcheevos version mirrored by this port. The wire format omits a zero patch.
  RACheevosVersionMajor = 12;
  RACheevosVersionMinor = 5;
  RACheevosVersionPatch = 0;
  RAProtocolVersion = '12.5';
  RAUserAgentClause = 'rcheevos/' + RAProtocolVersion;

type
  TRAImageKind = (Game, Achievement, LockedAchievement, User);

  TRAAchievementKind = (Standard, Missable, Progression, WinCondition);

  TRACredentials = record
    UserName: string;
    Token: string;
  end;

  TRAAwardResponse = record
    AchievementID, Score, SoftcoreScore, AchievementsRemaining: Cardinal;
    AlreadyAwarded, HasScore, HasSoftcoreScore: Boolean;
  end;

  TRALeaderboardEntry = record
    UserName: string;
    Rank: Cardinal;
    Score: Integer;
  end;

  TRALeaderboardResponse = record
    Score, BestScore: Integer;
    Rank, EntryCount: Cardinal;
    TopEntries: TArray<TRALeaderboardEntry>;
  end;

  ERAProtocolError = class(Exception)
  protected
    function GetResultCode: Integer; virtual;
  public
    property ResultCode: Integer read GetResultCode;
  end;

  ERAResponseFieldError = class(ERAProtocolError)
  protected
    function GetResultCode: Integer; override;
  public
    constructor Create(const FieldName: string); reintroduce;
  end;

  ERAServerError = class(ERAProtocolError)
  private
    FCode: string;
    FStatusCode, FResultCode: Integer;
    FRetryAfter: Cardinal;
    FHasResponseMessage: Boolean;
    FResponse: TJSONObject;
  protected
    function GetResultCode: Integer; override;
  public
    constructor Create(const ErrorMessage, Code: string; StatusCode: Integer; RetryAfter: Cardinal = 0); reintroduce;
    destructor Destroy; override;
    property Code: string read FCode;
    property StatusCode: Integer read FStatusCode;
    property RetryAfter: Cardinal read FRetryAfter;
    property HasResponseMessage: Boolean read FHasResponseMessage;
    // Borrowed for the lifetime of the exception, when the server returned JSON.
    property Response: TJSONObject read FResponse;
  end;

  ERAInvalidResponse = class(ERAServerError);

  TRARequest = record
  public
    class function LoginWithPassword(const UserName, Password: string): string; static;
    class function LoginWithToken(const Credentials: TRACredentials): string; static;
    class function ResolveHash(const GameHash: string): string; static;
    class function FetchGameData(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string = ''): string; static;
    class function FetchGameSets(const Credentials: TRACredentials; const GameHash: string): string; overload; static;
    class function FetchGameSets(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string = ''): string; overload; static;
    class function StartSession(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string; Hardcore: Boolean): string; static;
    class function Ping(const Credentials: TRACredentials; GameID: Cardinal; const GameHash, RichPresence: string; Hardcore: Boolean): string; static;
    class function AwardAchievement(const Credentials: TRACredentials; AchievementID: Cardinal; const GameHash: string; Hardcore: Boolean; SecondsSinceUnlock: Cardinal = 0): string; static;
    class function SubmitLeaderboard(const Credentials: TRACredentials; LeaderboardID: Cardinal; Score: Integer; const GameHash: string; SecondsSinceCompletion: Cardinal = 0): string; static;
    class function FetchAchievementInfo(const Credentials: TRACredentials; AchievementID, FirstEntry, Count: Cardinal; FriendsOnly: Boolean = False): string; static;
    class function FetchLeaderboardInfo(LeaderboardID, FirstEntry, Count: Cardinal; const UserName: string = ''): string; static;
    class function FetchLeaderboardInfoAroundUser(LeaderboardID, Count: Cardinal; const UserName: string): string; static;
    class function FetchGamesList(ConsoleID: Cardinal): string; static;
    class function FetchGameTitles(const GameIDs: array of Cardinal): string; static;
    class function FetchHashLibrary(ConsoleID: Cardinal = 0): string; static;
    class function FetchUserUnlocks(const Credentials: TRACredentials; GameID: Cardinal; Hardcore: Boolean): string; static;
    class function FetchFollowedUsers(const Credentials: TRACredentials): string; static;
    class function FetchAllUserProgress(const Credentials: TRACredentials; ConsoleID: Cardinal): string; static;
  end;

function RACheevosVersion: Cardinal;

function RACheevosVersionString: string;

// Legacy process-wide API settings. Empty clears only the selected override.
// Setting RAAPIHost, or calling ResetRADefaultHosts, also clears the media override.
procedure SetRADefaultAPIHost(const Host: string);

procedure SetRADefaultImageHost(const Host: string);

procedure ResetRADefaultHosts;

function GetRADefaultAPIHost: string;

function GetRADefaultRequestURL: string;

function GetRADefaultImageHost: string;

function NormalizeRAHost(const Host: string): string;

function BuildRARequestURL(const Host: string): string;

function RAImageHostForAPI(const Host: string; const ImageHost: string = ''): string;

function BuildRAImageURL(Kind: TRAImageKind; const ImageName: string; const ImageHost: string = ''): string;

// BufferSize is measured in bytes, including the terminating zero.
function CopyRAImageURL(const URL: string; Buffer: PAnsiChar; BufferSize: NativeUInt; AllowEmpty: Boolean = False): Integer; overload;

function CopyRAImageURL(Kind: TRAImageKind; const URL, ImageName: string; Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string = RAMediaHost): Integer; overload;

function RAImageName(const URL: string): string;

function ReadRAImageName(const Value: TJSONValue; const FieldName: string): string;

function RAAchievementKindName(Kind: TRAAchievementKind): string;

function ParseRAAchievementKind(const Name: string): TRAAchievementKind;

function EncodeRAFormValue(const Value: string): string;

procedure AppendRAFormField(var Form: string; const Key, Value: string);

function AuthenticatedRAForm(const Action: string; const Credentials: TRACredentials): string;

function TryReadRABoolean(Value: TJSONValue; out Flag: Boolean): Boolean;

function ReadRAString(const Value: TJSONValue; const FieldName: string): string;

// Reads the portion visible to consumers of the C API.
function ReadRACString(const Value: TJSONValue; const FieldName: string): string;

function ReadRAStringToken(const Value: TJSONValue): string;

function RAStringTokenMatches(const Value: TJSONValue; const Text: string): Boolean;

function ReadRALeaderboardFormat(const Value: TJSONValue; const FieldName: string): TRAValueFormat;

function TryReadRAUnsigned(Value: TJSONValue; out Number: Cardinal): Boolean;

function TryReadRASigned(Value: TJSONValue; out Number: Integer): Boolean;

function TryReadRATimestamp(Value: TJSONValue; out Timestamp: Int64): Boolean;

function ReadRALongPrefix(const Text: string): Cardinal;

// The caller owns the returned JSON object.
function ParseRAResponse(const Body: string; StatusCode: Integer; const RequestForm: string = ''; RetryAfter: Cardinal = 0): TJSONObject;

function ReadRACredentials(Response: TJSONObject): TRACredentials;

function ReadRAGameID(Response: TJSONObject): Cardinal;

function ReadRAAwardResponse(Response: TJSONObject; AchievementID: Cardinal): TRAAwardResponse;

function ReadRALeaderboardResponse(Response: TJSONObject): TRALeaderboardResponse;

implementation

uses
  System.Generics.Collections, System.Hash, System.Math, System.SyncObjs,
  RA.Errors, RA.Utils;

type
  TRALiteralJSONString = class(TJSONString)
  public
    Literal: string;
  end;

procedure RequireValue(const Value, FieldName: string);
begin
  if (Value = '') or (Pos(#0, Value) <> 0) then
    raise EArgumentException.CreateFmt('Invalid RetroAchievements %s', [FieldName]);
end;

const
  ImageFolders: array[TRAImageKind] of string = ('/Images/', '/Badge/', '/Badge/', '/UserPic/');
  AchievementKinds: array[TRAAchievementKind] of string = ('', 'missable', 'progression', 'win_condition');

var
  DefaultHostLock: TCriticalSection;
  DefaultAPIHost, DefaultImageHost: string;

function LegacyHostName(const Host: string): string;
var
  Terminator: Integer;
begin
  Terminator := Pos(#0, Host);
  if Terminator = 0 then
    Result := Host
  else
    Result := Copy(Host, 1, Terminator - 1);
end;

function LegacyHostOverride(const Host: string): string;
begin
  Result := Host;
  if (Result <> '') and not Result.Contains('://') then
    Result := 'http://' + Result;
end;

procedure SetRADefaultAPIHost(const Host: string);
var
  Name: string;
begin
  Name := LegacyHostName(Host);
  DefaultHostLock.Acquire;
  try
    if Name = RAAPIHost then
    begin
      DefaultAPIHost := '';
      DefaultImageHost := '';
    end
    else
    begin
      DefaultAPIHost := LegacyHostOverride(Name);
      if Name = 'http://retroachievements.org' then
        DefaultImageHost := 'http://media.retroachievements.org';
    end;
  finally
    DefaultHostLock.Release;
  end;
end;

procedure SetRADefaultImageHost(const Host: string);
var
  Name: string;
begin
  Name := LegacyHostOverride(LegacyHostName(Host));
  DefaultHostLock.Acquire;
  try
    DefaultImageHost := Name;
  finally
    DefaultHostLock.Release;
  end;
end;

procedure ResetRADefaultHosts;
begin
  DefaultHostLock.Acquire;
  try
    DefaultAPIHost := '';
    DefaultImageHost := '';
  finally
    DefaultHostLock.Release;
  end;
end;

function GetRADefaultAPIHost: string;
begin
  DefaultHostLock.Acquire;
  try
    Result := DefaultAPIHost;
  finally
    DefaultHostLock.Release;
  end;
  if Result = '' then
    Result := RAAPIHost;
end;

function GetRADefaultRequestURL: string;
begin
  Result := GetRADefaultAPIHost + RARequestPath;
end;

function GetRADefaultImageHost: string;
var
  Host: string;
begin
  DefaultHostLock.Acquire;
  try
    Result := DefaultImageHost;
    Host := DefaultAPIHost;
  finally
    DefaultHostLock.Release;
  end;
  if Result <> '' then
    Exit;
  if (Host = '') or (Host = RAAPIHost) then
    Result := RAMediaHost
  else if Host = 'http://retroachievements.org' then
    Result := 'http://media.retroachievements.org'
  else
    Result := Host;
end;

function RACheevosVersion: Cardinal;
begin
  Result := RACheevosVersionMajor * 1000000 + RACheevosVersionMinor * 1000 + RACheevosVersionPatch;
end;

function RACheevosVersionString: string;
begin
  Result := RAProtocolVersion;
end;

function NormalizeRAHost(const Host: string): string;
var
  AuthorityStart: Integer;
begin
  if Pos(#0, Host) <> 0 then
    raise EArgumentException.Create('Invalid RetroAchievements host');
  Result := Host.Trim;
  if Result = '' then
    Exit(RAAPIHost);
  if not Result.Contains('://') then
    Result := 'http://' + Result;
  Result := Result.TrimRight(['/']);
  AuthorityStart := Pos('://', Result) + 3;
  if not (Result.StartsWith('http://', True) or Result.StartsWith('https://', True)) or
    (AuthorityStart > Length(Result)) or (Result[AuthorityStart] = '/') or
    Result.Contains('?') or Result.Contains('#') then
    raise EArgumentException.Create('Invalid RetroAchievements host');
  for var Ch in Result do
    if Ch <= ' ' then
      raise EArgumentException.Create('Invalid RetroAchievements host');
end;

function BuildRARequestURL(const Host: string): string;
begin
  Result := NormalizeRAHost(Host) + RARequestPath;
end;

function RAImageHostForAPI(const Host, ImageHost: string): string;
begin
  if ImageHost <> '' then
    Exit(NormalizeRAHost(ImageHost));
  Result := NormalizeRAHost(Host);
  if SameText(Result, RAAPIHost) then
    Exit(RAMediaHost);
  if SameText(Result, 'http://retroachievements.org') then
    Result := 'http://media.retroachievements.org';
end;

function BuildRAImageURL(Kind: TRAImageKind; const ImageName, ImageHost: string): string;
var
  Host: string;
begin
  RequireValue(ImageName, 'image name');
  if ImageHost = '' then
    Host := GetRADefaultImageHost
  else
    Host := ImageHost.TrimRight(['/']);
  if not Host.Contains('://') then
    Host := 'http://' + Host;
  Result := Host + ImageFolders[Kind] + ImageName;
  if Kind = TRAImageKind.LockedAchievement then
    Result := Result + '_lock';
  Result := Result + '.png';
end;

function CopyRAImageURL(const URL: string; Buffer: PAnsiChar; BufferSize: NativeUInt; AllowEmpty: Boolean): Integer;
var
  Encoded: UTF8String;
  LengthBytes: NativeUInt;
begin
  if (Buffer = nil) or ((URL = '') and not AllowEmpty) or (Pos(#0, URL) <> 0) then
    Exit(RAErrorInvalidState);
  Encoded := UTF8String(URL);
  LengthBytes := Length(Encoded);
  if LengthBytes >= BufferSize then
    Exit(RAErrorInsufficientBuffer);
  if LengthBytes <> 0 then
    Move(PAnsiChar(Encoded)^, Buffer^, LengthBytes);
  Buffer[LengthBytes] := #0;
  Result := RAErrorOK;
end;

function CopyRAImageURL(Kind: TRAImageKind; const URL, ImageName: string; Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string): Integer;
begin
  if URL <> '' then
    Exit(CopyRAImageURL(URL, Buffer, BufferSize));
  if (Buffer = nil) or (ImageName = '') or (Pos(#0, ImageName) <> 0) then
    Exit(RAErrorInvalidState);
  Result := CopyRAImageURL(BuildRAImageURL(Kind, ImageName, ImageHost), Buffer, BufferSize);
end;

function RAImageName(const URL: string): string;
var
  Extension: Integer;
begin
  Result := URL.Substring(LastDelimiter('/', URL));
  Extension := Pos('.', Result);
  if Extension > 0 then
    SetLength(Result, Extension - 1);
end;

function ReadRAImageName(const Value: TJSONValue; const FieldName: string): string;
var
  Start, Stop: Integer;
  Literal: string;
begin
  if Value is TRALiteralJSONString then
  begin
    // rcheevos extracts the basename from the JSON token before reading it as a string.
    Literal := TRALiteralJSONString(Value).Literal;
    Stop := Length(Literal) - 1;
    Start := Stop;
    while (Start > 0) and not CharInSet(Literal[Start], ['/', '"']) do
    begin
      if Literal[Start] = '.' then
        Stop := Start - 1;
      Dec(Start);
    end;
    Result := Copy(Literal, Start + 1, Stop - Start);
  end
  else if Value is TJSONString then
    Result := RAImageName(Value.Value)
  else
    Exit(ReadRACString(Value, FieldName));
  if Result = 'null' then
    Result := '';
end;

function RAAchievementKindName(Kind: TRAAchievementKind): string;
begin
  Result := AchievementKinds[Kind];
end;

function ParseRAAchievementKind(const Name: string): TRAAchievementKind;
begin
  for var Kind := Low(TRAAchievementKind) to High(TRAAchievementKind) do
    if AchievementKinds[Kind] = Name then
      Exit(Kind);
  Result := TRAAchievementKind.Standard;
end;

function EncodeRAFormValue(const Value: string): string;
const
  Hex = '0123456789abcdef';
var
  Encoded: TStringBuilder;
  ValueByte: Byte;
begin
  Encoded := TStringBuilder.Create(Length(Value));
  try
    for ValueByte in TEncoding.UTF8.GetBytes(Value) do
      case ValueByte of
        Ord('a')..Ord('z'), Ord('A')..Ord('Z'), Ord('0')..Ord('9'), Ord('-'), Ord('_'), Ord('.'), Ord('~'):
          Encoded.Append(Char(ValueByte));
        Ord(' '):
          Encoded.Append('+');
      else
        Encoded.Append('%').Append(Hex[(ValueByte shr 4) + 1]).Append(Hex[(ValueByte and $F) + 1]);
      end;
    Result := Encoded.ToString;
  finally
    Encoded.Free;
  end;
end;

procedure AppendRAFormField(var Form: string; const Key, Value: string);
begin
  if Form <> '' then
    Form := Form + '&';
  Form := Form + Key + '=' + EncodeRAFormValue(Value);
end;

function AuthenticatedRAForm(const Action: string; const Credentials: TRACredentials): string;
begin
  RequireValue(Credentials.UserName, 'user name');
  RequireValue(Credentials.Token, 'token');
  Result := 'r=' + Action;
  AppendRAFormField(Result, 'u', Credentials.UserName);
  AppendRAFormField(Result, 't', Credentials.Token);
end;

function LoginForm(const UserName, CredentialField, Credential: string): string;
begin
  RequireValue(UserName, 'user name');
  RequireValue(Credential, 'login credential');
  Result := 'r=login2';
  AppendRAFormField(Result, 'u', UserName);
  AppendRAFormField(Result, CredentialField, Credential);
end;

procedure AppendGameID(var Form: string; GameID: Cardinal);
begin
  if GameID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements game ID');
  Form := Form + '&g=' + UIntToStr(GameID);
end;

function ModeValue(Hardcore: Boolean): string;
begin
  if Hardcore then
    Result := '1'
  else
    Result := '0';
end;

class function TRARequest.LoginWithPassword(const UserName, Password: string): string;
begin
  Result := LoginForm(UserName, 'p', Password);
end;

class function TRARequest.LoginWithToken(const Credentials: TRACredentials): string;
begin
  Result := LoginForm(Credentials.UserName, 't', Credentials.Token);
end;

class function TRARequest.ResolveHash(const GameHash: string): string;
begin
  RequireValue(GameHash, 'game hash');
  Result := 'r=gameid';
  AppendRAFormField(Result, 'm', GameHash);
end;

class function TRARequest.FetchGameData(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string): string;
begin
  Result := AuthenticatedRAForm('patch', Credentials);
  if GameID <> 0 then
    AppendGameID(Result, GameID)
  else
  begin
    RequireValue(GameHash, 'game hash');
    AppendRAFormField(Result, 'm', GameHash);
  end;
end;

class function TRARequest.FetchGameSets(const Credentials: TRACredentials; const GameHash: string): string;
begin
  Result := FetchGameSets(Credentials, 0, GameHash);
end;

class function TRARequest.FetchGameSets(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string): string;
begin
  Result := AuthenticatedRAForm('achievementsets', Credentials);
  if GameID <> 0 then
    AppendGameID(Result, GameID)
  else
  begin
    RequireValue(GameHash, 'game hash');
    AppendRAFormField(Result, 'm', GameHash);
  end;
end;

class function TRARequest.StartSession(const Credentials: TRACredentials; GameID: Cardinal; const GameHash: string; Hardcore: Boolean): string;
begin
  Result := AuthenticatedRAForm('startsession', Credentials);
  AppendGameID(Result, GameID);
  if GameHash <> '' then
  begin
    Result := Result + '&h=' + ModeValue(Hardcore);
    AppendRAFormField(Result, 'm', GameHash);
  end;
  Result := Result + '&l=' + RAProtocolVersion;
end;

class function TRARequest.Ping(const Credentials: TRACredentials; GameID: Cardinal; const GameHash, RichPresence: string; Hardcore: Boolean): string;
begin
  Result := AuthenticatedRAForm('ping', Credentials);
  AppendGameID(Result, GameID);
  if RichPresence <> '' then
    AppendRAFormField(Result, 'm', RichPresence);
  if GameHash <> '' then
  begin
    Result := Result + '&h=' + ModeValue(Hardcore);
    AppendRAFormField(Result, 'x', GameHash);
  end;
end;

class function TRARequest.AwardAchievement(const Credentials: TRACredentials; AchievementID: Cardinal; const GameHash: string; Hardcore: Boolean; SecondsSinceUnlock: Cardinal): string;
var
  ID, Mode, SignatureInput, Age: string;
  Signature: THashMD5;
begin
  if AchievementID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements achievement ID');

  ID := UIntToStr(AchievementID);
  Mode := ModeValue(Hardcore);
  Result := AuthenticatedRAForm('awardachievement', Credentials) + '&a=' + ID + '&h=' + Mode;
  if GameHash <> '' then
    AppendRAFormField(Result, 'm', GameHash);

  SignatureInput := ID + Credentials.UserName + Mode;
  if SecondsSinceUnlock <> 0 then
  begin
    Age := UIntToStr(SecondsSinceUnlock);
    Result := Result + '&o=' + Age;
    SignatureInput := SignatureInput + ID + Age;
  end;

  Signature := THashMD5.Create;
  Signature.Update(TEncoding.UTF8.GetBytes(SignatureInput));
  Result := Result + '&v=' + FormatRAMD5(Signature.HashAsBytes);
end;

class function TRARequest.SubmitLeaderboard(const Credentials: TRACredentials; LeaderboardID: Cardinal; Score: Integer; const GameHash: string; SecondsSinceCompletion: Cardinal): string;
var
  ID, ScoreText, Age: string;
  Signature: THashMD5;
begin
  if LeaderboardID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements leaderboard ID');
  ID := UIntToStr(LeaderboardID);
  ScoreText := IntToStr(Score);
  Result := AuthenticatedRAForm('submitlbentry', Credentials) + '&i=' + ID + '&s=' + ScoreText;
  if GameHash <> '' then
    AppendRAFormField(Result, 'm', GameHash);
  Age := '';
  if SecondsSinceCompletion <> 0 then
  begin
    Age := UIntToStr(SecondsSinceCompletion);
    Result := Result + '&o=' + Age;
  end;
  Signature := THashMD5.Create;
  Signature.Update(TEncoding.UTF8.GetBytes(ID + Credentials.UserName + ScoreText + Age));
  Result := Result + '&v=' + FormatRAMD5(Signature.HashAsBytes);
end;

class function TRARequest.FetchAchievementInfo(const Credentials: TRACredentials; AchievementID, FirstEntry, Count: Cardinal; FriendsOnly: Boolean): string;
begin
  if AchievementID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements achievement ID');
  Result := AuthenticatedRAForm('achievementwondata', Credentials) + '&a=' + UIntToStr(AchievementID);
  if FriendsOnly then
    Result := Result + '&f=1';
  if FirstEntry > 1 then
    Result := Result + '&o=' + UIntToStr(FirstEntry - 1);
  Result := Result + '&c=' + UIntToStr(Count);
end;

function LeaderboardInfoForm(LeaderboardID: Cardinal): string;
begin
  if LeaderboardID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements leaderboard ID');
  Result := 'r=lbinfo&i=' + UIntToStr(LeaderboardID);
end;

class function TRARequest.FetchLeaderboardInfo(LeaderboardID, FirstEntry, Count: Cardinal; const UserName: string): string;
begin
  if UserName <> '' then
    Exit(FetchLeaderboardInfoAroundUser(LeaderboardID, Count, UserName));
  Result := LeaderboardInfoForm(LeaderboardID);
  if FirstEntry > 1 then
    Result := Result + '&o=' + UIntToStr(FirstEntry - 1);
  Result := Result + '&c=' + UIntToStr(Count);
end;

class function TRARequest.FetchLeaderboardInfoAroundUser(LeaderboardID, Count: Cardinal; const UserName: string): string;
begin
  Result := LeaderboardInfoForm(LeaderboardID);
  AppendRAFormField(Result, 'u', UserName);
  Result := Result + '&c=' + UIntToStr(Count);
end;

class function TRARequest.FetchGamesList(ConsoleID: Cardinal): string;
begin
  if ConsoleID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements console ID');
  Result := 'r=systemgames&s=' + UIntToStr(ConsoleID);
end;

class function TRARequest.FetchGameTitles(const GameIDs: array of Cardinal): string;
var
  Form: TStringBuilder;
begin
  if Length(GameIDs) = 0 then
    raise EArgumentException.Create('RetroAchievements requires at least one game ID');
  Form := TStringBuilder.Create;
  try
    Form.Append('r=gameinfolist&g=').Append(UIntToStr(GameIDs[0]));
    for var Index := 1 to High(GameIDs) do
      Form.Append(',').Append(UIntToStr(GameIDs[Index]));
    Result := Form.ToString;
  finally
    Form.Free;
  end;
end;

class function TRARequest.FetchHashLibrary(ConsoleID: Cardinal): string;
begin
  Result := 'r=hashlibrary';
  if ConsoleID <> 0 then
    Result := Result + '&c=' + UIntToStr(ConsoleID);
end;

class function TRARequest.FetchUserUnlocks(const Credentials: TRACredentials; GameID: Cardinal; Hardcore: Boolean): string;
begin
  Result := AuthenticatedRAForm('unlocks', Credentials) +
    '&g=' + UIntToStr(GameID) + '&h=' + ModeValue(Hardcore);
end;

class function TRARequest.FetchFollowedUsers(const Credentials: TRACredentials): string;
begin
  Result := AuthenticatedRAForm('getfriendlist', Credentials);
end;

class function TRARequest.FetchAllUserProgress(const Credentials: TRACredentials; ConsoleID: Cardinal): string;
begin
  if ConsoleID = 0 then
    raise EArgumentException.Create('Invalid RetroAchievements console ID');
  Result := AuthenticatedRAForm('allprogress', Credentials) + '&c=' + UIntToStr(ConsoleID);
end;

function ERAProtocolError.GetResultCode: Integer;
begin
  Result := RAErrorAPIFailure;
end;

constructor ERAResponseFieldError.Create(const FieldName: string);
begin
  inherited CreateFmt('%s not found in response', [FieldName]);
end;

function ERAResponseFieldError.GetResultCode: Integer;
begin
  Result := RAErrorMissingValue;
end;

function ERAServerError.GetResultCode: Integer;
begin
  Result := FResultCode;
end;

function ServerResultCode(const Code: string; StatusCode: Integer): Integer;
begin
  if Code = 'access_denied' then
    Result := RAErrorAccessDenied
  else if Code = 'expired_token' then
    Result := RAErrorExpiredToken
  else if Code = 'invalid_credentials' then
    Result := RAErrorInvalidCredentials
  else if (Code = 'invalid_parameter') or (Code = 'missing_parameter') then
    Result := RAErrorInvalidState
  else if Code = 'not_found' then
    Result := RAErrorNotFound
  else if (Code = '') and (StatusCode <= 0) then
    Result := RAErrorNoResponse
  else
    Result := RAErrorAPIFailure;
end;

constructor ERAServerError.Create(const ErrorMessage, Code: string; StatusCode: Integer; RetryAfter: Cardinal);
begin
  inherited Create(ErrorMessage);
  FCode := Code;
  FStatusCode := StatusCode;
  FResultCode := ServerResultCode(Code, StatusCode);
  FRetryAfter := RetryAfter;
  FHasResponseMessage := ErrorMessage <> '';
end;

destructor ERAServerError.Destroy;
begin
  FResponse.Free;
  inherited;
end;

function AlreadyAwarded(Response: TJSONObject): Boolean;
var
  MessageText: string;
begin
  Result := Response.TryGetValue<string>('Error', MessageText) and MessageText.StartsWith('User already has');
end;

function ReadRAString(const Value: TJSONValue; const FieldName: string): string;
begin
  if Value = nil then
    raise ERAResponseFieldError.Create(FieldName);
  if Value is TJSONString then
    Exit(Value.Value);
  if Value is TJSONNull then
    Exit('');
  Result := Value.ToJSON;
end;

function ReadRACString(const Value: TJSONValue; const FieldName: string): string;
var
  Terminator: Integer;
begin
  Result := ReadRAString(Value, FieldName);
  Terminator := Pos(#0, Result);
  if Terminator > 0 then
    SetLength(Result, Terminator - 1);
end;

function ReadRAStringToken(const Value: TJSONValue): string;
begin
  if Value is TRALiteralJSONString then
  begin
    var Literal := TRALiteralJSONString(Value).Literal;
    Exit(Copy(Literal, 2, Length(Literal) - 2));
  end;
  if Value is TJSONString then
    Exit(Value.Value);
  Result := '';
end;

function RAStringTokenMatches(const Value: TJSONValue; const Text: string): Boolean;
var
  Token: string;
  TokenIndex, TextIndex: Integer;
  TokenChar: Char;
begin
  if Value = nil then
    Exit(False);
  if not (Value is TRALiteralJSONString) then
  begin
    if Value is TJSONString then
      Exit(Value.Value = Text);
    Exit(Value.ToJSON = Text);
  end;

  Token := ReadRAStringToken(Value);
  TokenIndex := 1;
  TextIndex := 1;
  while (TokenIndex <= Length(Token)) and (TextIndex <= Length(Text)) do
  begin
    TokenChar := Token[TokenIndex];
    if (TokenChar <> Text[TextIndex]) and (TokenChar = '\') then
    begin
      Inc(TokenIndex);
      if TokenIndex > Length(Token) then
        Exit(False);
      // The upstream comparison handles single-character escapes without decoding Unicode escapes.
      TokenChar := Token[TokenIndex];
      case TokenChar of
        'n':
          TokenChar := #10;
        'r':
          TokenChar := #13;
        't':
          TokenChar := #9;
      end;
    end;
    if TokenChar <> Text[TextIndex] then
      Exit(False);
    Inc(TokenIndex);
    Inc(TextIndex);
  end;
  Result := (TokenIndex > Length(Token)) and (TextIndex > Length(Text));
end;

function ReadRALeaderboardFormat(const Value: TJSONValue; const FieldName: string): TRAValueFormat;
begin
  if Value = nil then
    raise ERAResponseFieldError.Create(FieldName);
  Result := ParseRAFormat(ReadRAStringToken(Value));
end;

function TryReadRABoolean(Value: TJSONValue; out Flag: Boolean): Boolean;
var
  Text: string;
begin
  Flag := False;
  if Value is TJSONBool then
  begin
    Flag := TJSONBool(Value).AsBoolean;
    Exit(True);
  end;
  if not (Value is TJSONNumber) then
    Exit(False);

  Text := Value.Value;
  Result := (Length(Text) = 1) and CharInSet(Text[1], ['0'..'9']);
  if Result then
    Flag := Text[1] <> '0';
end;

function TryReadRAIntegerBits(Value: TJSONValue; AllowSign: Boolean; out Number: Cardinal): Boolean;
var
  Digits: UInt64;
  Text: string;
  FirstDigit: Integer;
begin
  Number := 0;
  if not (Value is TJSONNumber) then
    Exit(False);
  Text := Value.Value;
  if Text = '' then
    Exit(False);
  FirstDigit := 1;
  if AllowSign and CharInSet(Text[1], ['-', '+']) then
    Inc(FirstDigit);
  if (FirstDigit > Length(Text)) or not CharInSet(Text[FirstDigit], ['0'..'9']) then
    Exit(False);

  Digits := 0;
  for var Index := FirstDigit to Length(Text) do
  begin
    var Digit := Text[Index];
    if Digit = '.' then
      Break;
    if not CharInSet(Digit, ['0'..'9']) then
      Exit(False);
    // Keep the integer part at the width of the rcheevos response fields.
    Digits := (Digits * 10 + UInt64(Ord(Digit) - Ord('0'))) and High(Cardinal);
  end;
  if (FirstDigit = 2) and (Text[1] = '-') then
    Number := Cardinal((-Int64(Digits)) and High(Cardinal))
  else
    Number := Cardinal(Digits);
  Result := True;
end;

function TryReadRAUnsigned(Value: TJSONValue; out Number: Cardinal): Boolean;
begin
  Result := TryReadRAIntegerBits(Value, False, Number);
end;

function TryReadRASigned(Value: TJSONValue; out Number: Integer): Boolean;
var
  Bits: Cardinal;
begin
  Result := TryReadRAIntegerBits(Value, True, Bits);
  Number := Integer(Bits);
end;

function TryReadRATimestamp(Value: TJSONValue; out Timestamp: Int64): Boolean;
var
  Text: string;
  DecimalPoint: Integer;
begin
  Timestamp := 0;
  if not (Value is TJSONNumber) then
    Exit(False);
  Text := Value.Value;
  DecimalPoint := Pos('.', Text);
  if DecimalPoint > 0 then
    SetLength(Text, DecimalPoint - 1);
  Result := TryStrToInt64(Text, Timestamp);
  if not Result then
    Timestamp := 0;
end;

function UnstructuredResponseMessage(const Body: string; StatusCode: Integer): string;
const
  TitleStart = '<title>';
  TitleEnd = '</title>';
  MaxMessageLength = 200;
var
  Text: string;
  Start, Stop: Integer;
begin
  Text := Body.TrimLeft;
  if Text = '' then
  begin
    case StatusCode of
      504, 522, 524:
        Exit('Request has timed out.');
      521, 523:
        Exit('Could not connect to server.');
    end;
    Exit('');
  end;
  // A damaged JSON response can contain credentials in its fields.
  if CharInSet(Text[1], ['{', '[']) then
    Exit('');

  Start := Pos(TitleStart, Text);
  if Start > 0 then
  begin
    Inc(Start, Length(TitleStart));
    Stop := Pos(TitleEnd, Text, Start);
    if Stop > Start then
      Exit(Copy(Text, Start, Min(Stop - Start, MaxMessageLength)).Trim);
  end;

  Result := Copy(Text, 1, MaxMessageLength);
  Stop := Pos(#10, Result);
  if Stop > 0 then
    SetLength(Result, Stop - 1);
  Result := Result.Trim;
end;

procedure PreserveRALiterals(const Body: string; Obj: TJSONObject);
var
  Offset: Integer;

  procedure SkipWhitespace;
  begin
    while (Offset <= Length(Body)) and CharInSet(Body[Offset], [#9, #10, #13, ' ']) do
      Inc(Offset);
  end;

  function SkipString: Boolean;
  begin
    Result := False;
    Inc(Offset);
    while (Offset <= Length(Body)) and (Body[Offset] <> '"') do
    begin
      if Body[Offset] = '\' then
      begin
        Result := True;
        Inc(Offset);
      end;
      Inc(Offset);
    end;
    Inc(Offset);
  end;

  function CaptureLiteral(Value: TJSONString; Start: Integer): TRALiteralJSONString;
  begin
    Result := TRALiteralJSONString.Create(Value.Value);
    Result.Literal := Copy(Body, Start, Offset - Start);
  end;

  procedure Walk(Value: TJSONValue; Pair: TJSONPair);
  var
    Start: Integer;
    Child: TJSONPair;
    Name: string;
    PreserveKeys: Boolean;
  begin
    SkipWhitespace;
    if Value is TJSONObject then
    begin
      PreserveKeys := (Pair <> nil) and ((Pair.JsonString.Value = 'MD5List') or
        (Pair.JsonString.Value = 'Response'));
      Inc(Offset);
      for Child in TJSONObject(Value) do
      begin
        SkipWhitespace;
        Start := Offset;
        if SkipString and PreserveKeys then
          Child.JsonString := CaptureLiteral(Child.JsonString, Start);
        SkipWhitespace;
        Inc(Offset);
        Walk(Child.JsonValue, Child);
        SkipWhitespace;
        if Body[Offset] = ',' then
          Inc(Offset);
      end;
      SkipWhitespace;
      Inc(Offset);
    end
    else if Value is TJSONArray then
    begin
      Inc(Offset);
      for var Item in TJSONArray(Value) do
      begin
        Walk(Item, nil);
        SkipWhitespace;
        if Body[Offset] = ',' then
          Inc(Offset);
      end;
      SkipWhitespace;
      Inc(Offset);
    end
    else if (Offset <= Length(Body)) and (Body[Offset] = '"') then
    begin
      Start := Offset;
      if not SkipString or (Pair = nil) then
        Exit;
      Name := Pair.JsonString.Value;
      if (Name <> 'ImageIcon') and (Name <> 'ImageIconUrl') and
        (Name <> 'Type') and (Name <> 'Format') and (Name <> 'LBFormat') then
        Exit;
      Pair.JsonValue := CaptureLiteral(TJSONString(Value), Start);
    end
    else
      while (Offset <= Length(Body)) and
        not CharInSet(Body[Offset], [#9, #10, #13, ' ', ',', '}', ']']) do
        Inc(Offset);
  end;

begin
  // Without escapes, the decoded strings already match their source tokens.
  if Pos('\', Body) = 0 then
    Exit;
  Offset := 1;
  if Body[Offset] = #$FEFF then
    Inc(Offset);
  Walk(Obj, nil);
end;

function ParseRAResponse(const Body: string; StatusCode: Integer; const RequestForm: string; RetryAfter: Cardinal): TJSONObject;
var
  JSON: TJSONValue;
  Obj: TJSONObject;
  Rejection: ERAServerError;
  Success, HasSuccess, HttpSuccess, DuplicateAward, HasCode, HasError: Boolean;
  ErrorMessage, Code: string;

  function ReadErrorField(const Name: string; out Text: string): Boolean;
  var
    Field: TJSONValue;
  begin
    Field := Obj.GetValue(Name);
    Result := (Field <> nil) and not (Field is TJSONNull);
    if Result then
      Text := ReadRACString(Field, Name)
    else
      Text := '';
  end;

begin
  case StatusCode of
    RAServerResponseClientError, RAServerResponseRetryableClientError:
      raise ERAInvalidResponse.Create(Body, '', StatusCode, RetryAfter);
  end;
  JSON := TJSONObject.ParseJSONValue(Body, True);
  try
    if not (JSON is TJSONObject) then
    begin
      ErrorMessage := '';
      if JSON = nil then
        ErrorMessage := UnstructuredResponseMessage(Body, StatusCode);
      Rejection := ERAInvalidResponse.Create(ErrorMessage, '', StatusCode, RetryAfter);
      if (StatusCode <= 0) or (Body.Trim = '') then
        Rejection.FResultCode := RAErrorNoResponse
      else
        Rejection.FResultCode := RAErrorInvalidJSON;
      if ErrorMessage = '' then
        Rejection.Message := Format('Invalid RetroAchievements response (HTTP %d)', [StatusCode]);
      raise Rejection;
    end;
    Obj := TJSONObject(JSON);
    HttpSuccess := (StatusCode >= 200) and (StatusCode < 300);
    HasCode := ReadErrorField('Code', Code);
    HasError := ReadErrorField('Error', ErrorMessage);
    HasSuccess := TryReadRABoolean(Obj.GetValue('Success'), Success);
    if not HasSuccess then
      Success := not HasError;
    DuplicateAward := not Success and RequestForm.StartsWith('r=awardachievement&') and AlreadyAwarded(Obj);
    if HasCode or (not DuplicateAward and not (HttpSuccess and Success)) then
    begin
      Rejection := ERAServerError.Create(ErrorMessage, Code, StatusCode, RetryAfter);
      // A parsed refusal is an API error even if the transport supplied no HTTP status.
      if Rejection.FResultCode = RAErrorNoResponse then
        Rejection.FResultCode := RAErrorAPIFailure;
      Rejection.FHasResponseMessage := HasError;
      if ErrorMessage = '' then
        Rejection.Message := Format('RetroAchievements request failed (HTTP %d)', [StatusCode]);
      Rejection.FResponse := Obj;
      JSON := nil;
      raise Rejection;
    end;
    PreserveRALiterals(Body, Obj);
    Result := Obj;
    JSON := nil;
  finally
    JSON.Free;
  end;
end;

function ReadRACredentials(Response: TJSONObject): TRACredentials;

  function ReadCredential(const Name: string): string;
  begin
    Result := ReadRAString(Response.GetValue(Name), Name);
    if (Result = '') or (Pos(#0, Result) <> 0) then
      raise ERAResponseFieldError.Create(Name);
  end;

begin
  Result.UserName := ReadCredential('User');
  Result.Token := ReadCredential('Token');
end;

function ReadRAGameID(Response: TJSONObject): Cardinal;
begin
  if not TryReadRAUnsigned(Response.GetValue('GameID'), Result) then
    raise ERAProtocolError.Create('GameID not found in response');
end;

function ReadRank(Response: TJSONObject): Cardinal;
begin
  if not TryReadRAUnsigned(Response.GetValue('Rank'), Result) then
    raise ERAResponseFieldError.Create('Rank');
end;

function ReadScore(Response: TJSONObject; const Name: string): Integer;
begin
  if not TryReadRASigned(Response.GetValue(Name), Result) then
    raise ERAResponseFieldError.Create(Name);
end;

function ReadDecimalPrefix(const Text: string; PositiveLimit: UInt64): Cardinal;
var
  Digits: string;
  FirstDigit: Integer;
  Magnitude, Limit, DigitValue: UInt64;
  Bits: Int64;
  Negative: Boolean;
begin
  Digits := Text.TrimLeft([' ', #9, #10, #11, #12, #13]);
  Negative := Digits.StartsWith('-');
  FirstDigit := 1;
  if Negative or Digits.StartsWith('+') then
    Inc(FirstDigit);
  Limit := PositiveLimit + UInt64(Ord(Negative));
  Magnitude := 0;
  for var Index := FirstDigit to Length(Digits) do
  begin
    var Digit := Digits[Index];
    if not CharInSet(Digit, ['0'..'9']) then
      Break;
    DigitValue := UInt64(Ord(Digit) - Ord('0'));
    if Magnitude > (Limit - DigitValue) div 10 then
    begin
      Magnitude := Limit;
      Break;
    end;
    Magnitude := Magnitude * 10 + DigitValue;
  end;
  Bits := Int64(Magnitude and High(Cardinal));
  if Negative then
    Bits := -Bits;
  Result := Cardinal(Bits and High(Cardinal));
end;

function ReadRALongPrefix(const Text: string): Cardinal;
begin
  // Match the platform C long before converting to uint32_t.
  {$IF Defined(CPU64BITS) and not Defined(MSWINDOWS)}
  Result := ReadDecimalPrefix(Text, High(Int64));
  {$ELSE}
  Result := ReadDecimalPrefix(Text, High(Integer));
  {$IFEND}
end;

function ReadLeaderboardEntryCount(RankInfo: TJSONObject): Cardinal;
var
  Value: TJSONValue;
begin
  Value := RankInfo.GetValue('NumEntries');
  if (Value = nil) or (Value is TJSONNull) then
    raise ERAResponseFieldError.Create('NumEntries');

  // rcheevos calls atoi, which uses strtol before narrowing to int on glibc.
  Result := ReadRALongPrefix(ReadRACString(Value, 'NumEntries'));
end;

function ReadRAAwardResponse(Response: TJSONObject; AchievementID: Cardinal): TRAAwardResponse;
var
  ReturnedID: Cardinal;
begin
  if TryReadRAUnsigned(Response.GetValue('AchievementID'), ReturnedID) and
    (ReturnedID <> 0) and (ReturnedID <> AchievementID) then
    raise ERAProtocolError.Create('RetroAchievements confirmed a different achievement');
  Result.AchievementID := AchievementID;
  Result.HasScore := TryReadRAUnsigned(Response.GetValue('Score'), Result.Score);
  Result.HasSoftcoreScore := TryReadRAUnsigned(Response.GetValue('SoftcoreScore'), Result.SoftcoreScore);
  if not TryReadRAUnsigned(Response.GetValue('AchievementsRemaining'), Result.AchievementsRemaining) then
    Result.AchievementsRemaining := High(Cardinal);
  Result.AlreadyAwarded := AlreadyAwarded(Response);
end;

function ReadRALeaderboardResponse(Response: TJSONObject): TRALeaderboardResponse;
var
  Data, RankInfo, Entry: TJSONObject;
  Entries: TJSONArray;
begin
  if not Response.TryGetValue<TJSONObject>('Response', Data) then
    raise ERAResponseFieldError.Create('Response');
  Result.Score := ReadScore(Data, 'Score');
  Result.BestScore := ReadScore(Data, 'BestScore');
  if not Data.TryGetValue<TJSONObject>('RankInfo', RankInfo) then
    raise ERAResponseFieldError.Create('RankInfo');
  Result.Rank := ReadRank(RankInfo);
  Result.EntryCount := ReadLeaderboardEntryCount(RankInfo);
  if not Data.TryGetValue<TJSONArray>('TopEntries', Entries) then
    raise ERAResponseFieldError.Create('TopEntries');
  SetLength(Result.TopEntries, Entries.Count);
  for var Index := 0 to Entries.Count - 1 do
  begin
    if not (Entries.Items[Index] is TJSONObject) then
      raise ERAResponseFieldError.Create('TopEntries item');
    Entry := TJSONObject(Entries.Items[Index]);
    Result.TopEntries[Index].UserName := ReadRACString(Entry.GetValue('User'), 'User');
    Result.TopEntries[Index].Rank := ReadRank(Entry);
    Result.TopEntries[Index].Score := ReadScore(Entry, 'Score');
  end;
end;

initialization
  DefaultHostLock := TCriticalSection.Create;

finalization
  DefaultHostLock.Free;

end.

