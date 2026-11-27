unit RA.Info;

interface

uses
  System.JSON, RA.Format, RA.Protocol;

type
  TRAAchievementWinner = record
    UserName, AvatarURL: string;
    Awarded: Int64;
  end;

  TRAAchievementInfo = record
    ID, GameID, NumAwarded, NumPlayers: Cardinal;
    RecentWinners: TArray<TRAAchievementWinner>;
  end;

  TRARankedEntry = record
    UserName, AvatarURL: string;
    Rank, Index: Cardinal;
    Score: Integer;
    Submitted: Int64;
  end;

  TRALeaderboardInfo = record
    ID, GameID, TotalEntries: Cardinal;
    LowerIsBetter: Boolean;
    ValueFormat: TRAValueFormat;
    Title, Description, Definition, Author: string;
    Created, Updated: Int64;
    Entries: TArray<TRARankedEntry>;
  end;

  TRAGameTitle = record
    ID: Cardinal;
    Title, ImageName, ImageURL: string;
  end;

  TRAGameListEntry = record
    Game: TRAGameTitle;
    NumAchievements, NumLeaderboards, Points: Cardinal;
    SupportedHashes, UnsupportedHashes: TArray<string>;
  end;

  TRAHashLibraryEntry = record
    Hash: string;
    GameID: Cardinal;
  end;

  TRALoginInfo = record
  private
    FHasExplicitAvatarURL: Boolean;
  public
    Credentials: TRACredentials;
    DisplayName, AvatarURL: string;
    Score, SoftcoreScore, UnreadMessages: Cardinal;
    AvatarUpdated: Int64;
    class operator Initialize(out Dest: TRALoginInfo);
    procedure SetAvatarURL(const URL: string);
    function CopyAvatarURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string = RAMediaHost): Integer;
  end;

  TRAUserActivity = record
    GameID: Cardinal;
    GameTitle, GameImageURL, Description: string;
    SeenAt: Int64;
  end;

  TRAFollowedUser = record
    DisplayName, AvatarURL: string;
    Score: Cardinal;
    AvatarUpdated: Int64;
    RecentActivity: TRAUserActivity;
  end;

  TRAUserGameProgress = record
    GameID, NumAchievements, NumUnlocked, NumHardcoreUnlocked: Cardinal;
  end;

// Readers take a response object accepted by ParseRAResponse. Timestamps are Unix seconds in UTC.
function ReadRAAchievementInfo(Response: TJSONObject; const ImageHost: string = ''): TRAAchievementInfo;

function ReadRALeaderboardInfo(Response: TJSONObject; const ImageHost: string = ''): TRALeaderboardInfo;

function ReadRAGamesList(Response: TJSONObject): TArray<TRAGameListEntry>;

function ReadRAGameTitles(Response: TJSONObject; const ImageHost: string = ''): TArray<TRAGameTitle>;

function ReadRAHashLibrary(Response: TJSONObject): TArray<TRAHashLibraryEntry>;

function ReadRALoginInfo(Response: TJSONObject; const ImageHost: string = ''): TRALoginInfo;

function ReadRAUserUnlocks(Response: TJSONObject): TArray<Cardinal>;

function ReadRAFollowedUsers(Response: TJSONObject): TArray<TRAFollowedUser>;

function ReadRAAllUserProgress(Response: TJSONObject): TArray<TRAUserGameProgress>;

implementation

uses
  System.DateUtils, System.Generics.Collections, System.SysUtils;

class operator TRALoginInfo.Initialize(out Dest: TRALoginInfo);
begin
  Dest.FHasExplicitAvatarURL := False;
end;

procedure TRALoginInfo.SetAvatarURL(const URL: string);
var
  Terminator: Integer;
begin
  FHasExplicitAvatarURL := True;
  AvatarURL := URL;
  Terminator := Pos(#0, AvatarURL);
  if Terminator > 0 then
    SetLength(AvatarURL, Terminator - 1);
end;

function TRALoginInfo.CopyAvatarURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string): Integer;
begin
  if FHasExplicitAvatarURL then
    Exit(CopyRAImageURL(AvatarURL, Buffer, BufferSize, True));
  Result := CopyRAImageURL(TRAImageKind.User, AvatarURL, DisplayName, Buffer, BufferSize, ImageHost);
end;

procedure InvalidField(const Name: string);
begin
  raise ERAResponseFieldError.Create(Name);
end;

function AsObject(Value: TJSONValue; const Name: string): TJSONObject;
begin
  if not (Value is TJSONObject) then
    InvalidField(Name);
  Result := TJSONObject(Value);
end;

function AsArray(Value: TJSONValue; const Name: string): TJSONArray;
begin
  if not (Value is TJSONArray) then
    InvalidField(Name);
  Result := TJSONArray(Value);
end;

function ReadMap(Response: TJSONObject; const Name: string): TJSONObject;
var
  Value: TJSONValue;
begin
  Value := Response.GetValue(Name);
  // Treat explicit null and an empty array as empty maps.
  if (Value is TJSONNull) or ((Value is TJSONArray) and (TJSONArray(Value).Count = 0)) then
    Exit(nil);
  Result := AsObject(Value, Name);
end;

function ReadStringField(Obj: TJSONObject; const Name: string; Required: Boolean = True): string;
var
  Value: TJSONValue;
begin
  Value := Obj.GetValue(Name);
  if (Value = nil) and not Required then
    Exit('');
  Result := ReadRACString(Value, Name);
end;

function ReadTimestamp(Obj: TJSONObject; const Name: string; Required: Boolean = True): Int64;
begin
  if not TryReadRATimestamp(Obj.GetValue(Name), Result) and Required then
    InvalidField(Name);
end;

function ReadUIntValue(Value: TJSONValue; const Name: string): Cardinal;
begin
  if not TryReadRAUnsigned(Value, Result) then
    InvalidField(Name);
end;

function ReadUInt(Obj: TJSONObject; const Name: string; Required: Boolean = True): Cardinal;
begin
  if not TryReadRAUnsigned(Obj.GetValue(Name), Result) and Required then
    InvalidField(Name);
end;

function ReadScore(Obj: TJSONObject): Integer;
begin
  if not TryReadRASigned(Obj.GetValue('Score'), Result) then
    InvalidField('Score');
end;

function ReadDate(Obj: TJSONObject; const Name: string): Int64;
const
  DateTimeLength = 19;
var
  Text: string;
  Date: TDateTime;
  Year, Month, Day, Hour, Minute, Second: Word;

  function ReadDigits(Start, Count: Integer): Word;
  begin
    Result := 0;
    for var Index := Start to Start + Count - 1 do
    begin
      var Digit := Text[Index];
      if not CharInSet(Digit, ['0'..'9']) then
        InvalidField(Name);
      Result := Result * 10 + Ord(Digit) - Ord('0');
    end;
  end;

  procedure ValidateSuffix;
  var
    Position, TextLength: Integer;
  begin
    TextLength := Length(Text);
    Position := DateTimeLength + 1;
    if Position > TextLength then
      Exit;
    if Text[Position] = '.' then
    begin
      Inc(Position);
      if (Position > TextLength) or not CharInSet(Text[Position], ['0'..'9']) then
        InvalidField(Name);
      while (Position <= TextLength) and CharInSet(Text[Position], ['0'..'9']) do
        Inc(Position);
      if Position > TextLength then
        Exit;
    end;
    if (Text[Position] = 'Z') and (Position = TextLength) then
      Exit;
    if (TextLength - Position <> 5) or not CharInSet(Text[Position], ['+', '-']) then
      InvalidField(Name);
    if (Text[Position + 3] <> ':') or (ReadDigits(Position + 1, 2) > 23) or
      (ReadDigits(Position + 4, 2) > 59) then
      InvalidField(Name);
  end;

begin
  Text := ReadRAString(Obj.GetValue(Name), Name);
  if Length(Text) < DateTimeLength then
    InvalidField(Name);
  if (Text[5] <> '-') or (Text[8] <> '-') or not CharInSet(Text[11], [' ', 'T']) or
    (Text[14] <> ':') or (Text[17] <> ':') then
    InvalidField(Name);
  Year := ReadDigits(1, 4);
  Month := ReadDigits(6, 2);
  Day := ReadDigits(9, 2);
  Hour := ReadDigits(12, 2);
  Minute := ReadDigits(15, 2);
  Second := ReadDigits(18, 2);
  if (Hour > 23) or (Minute > 59) or (Second > 59) or not TryEncodeDate(Year, Month, Day, Date) then
    InvalidField(Name);
  ValidateSuffix;
  // rcheevos validates the fraction and zone, then converts the main fields as UTC.
  Result := DateTimeToUnix(Date, True) + Hour * 3600 + Minute * 60 + Second;
end;

function ReadAvatarURL(Obj: TJSONObject; const UserName, ImageHost: string): string;
begin
  var Value := Obj.GetValue('AvatarUrl');
  if (Value <> nil) and not (Value is TJSONNull) then
    Exit(ReadRACString(Value, 'AvatarUrl'));
  Result := '';
  if UserName <> '' then
    Result := BuildRAImageURL(TRAImageKind.User, UserName, ImageHost);
end;

function ReadStringArray(Obj: TJSONObject; const Name: string; Required: Boolean): TArray<string>;
var
  Value: TJSONValue;
  Items: TJSONArray;
begin
  Value := Obj.GetValue(Name);
  if not Required and not (Value is TJSONArray) then
    Exit(nil);
  Items := AsArray(Value, Name);
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
    Result[Index] := ReadRACString(Items.Items[Index], Name);
end;

procedure ReadGameImage(Obj: TJSONObject; NeedURL: Boolean; const ImageHost: string; var Game: TRAGameTitle);
begin
  Game.ImageName := ReadRAImageName(Obj.GetValue('ImageIcon'), 'ImageIcon');
  Game.ImageURL := ReadStringField(Obj, 'ImageUrl', NeedURL);
  if not NeedURL and (Game.ImageURL = '') and (Game.ImageName <> '') then
    Game.ImageURL := BuildRAImageURL(TRAImageKind.Game, Game.ImageName, ImageHost);
end;

function ReadRAAchievementInfo(Response: TJSONObject; const ImageHost: string): TRAAchievementInfo;
var
  Data, Winner: TJSONObject;
  Items: TJSONArray;
begin
  Result.ID := ReadUInt(Response, 'AchievementID');
  Data := AsObject(Response.GetValue('Response'), 'Response');
  Result.NumAwarded := ReadUInt(Data, 'NumEarned');
  Result.NumPlayers := ReadUInt(Data, 'TotalPlayers');
  Result.GameID := ReadUInt(Data, 'GameID');
  Items := AsArray(Data.GetValue('RecentWinner'), 'RecentWinner');
  SetLength(Result.RecentWinners, Items.Count);
  for var Index := 0 to Items.Count - 1 do
  begin
    Winner := AsObject(Items.Items[Index], 'RecentWinner entry');
    Result.RecentWinners[Index].UserName := ReadRACString(Winner.GetValue('User'), 'User');
    Result.RecentWinners[Index].Awarded := ReadTimestamp(Winner, 'DateAwarded');
    Result.RecentWinners[Index].AvatarURL := ReadAvatarURL(Winner, Result.RecentWinners[Index].UserName, ImageHost);
  end;
end;

function ReadRALeaderboardInfo(Response: TJSONObject; const ImageHost: string): TRALeaderboardInfo;
var
  Data, Entry: TJSONObject;
  Items: TJSONArray;
begin
  Data := AsObject(Response.GetValue('LeaderboardData'), 'LeaderboardData');
  Result.ID := ReadUInt(Data, 'LBID');
  Result.LowerIsBetter := ReadUInt(Data, 'LowerIsBetter') <> 0;
  Result.Title := ReadRACString(Data.GetValue('LBTitle'), 'LBTitle');
  Result.Description := ReadRACString(Data.GetValue('LBDesc'), 'LBDesc');
  Result.Definition := ReadRACString(Data.GetValue('LBMem'), 'LBMem');
  Result.GameID := ReadUInt(Data, 'GameID');
  Result.Author := ReadRACString(Data.GetValue('LBAuthor'), 'LBAuthor');
  Result.Created := ReadDate(Data, 'LBCreated');
  Result.Updated := ReadDate(Data, 'LBUpdated');
  Result.TotalEntries := ReadUInt(Data, 'TotalEntries');
  Result.ValueFormat := ReadRALeaderboardFormat(Data.GetValue('LBFormat'), 'LBFormat');
  Items := AsArray(Data.GetValue('Entries'), 'Entries');
  SetLength(Result.Entries, Items.Count);
  for var Index := 0 to Items.Count - 1 do
  begin
    Entry := AsObject(Items.Items[Index], 'Entries item');
    Result.Entries[Index].UserName := ReadRACString(Entry.GetValue('User'), 'User');
    Result.Entries[Index].AvatarURL := ReadAvatarURL(Entry, Result.Entries[Index].UserName, ImageHost);
    Result.Entries[Index].Rank := ReadUInt(Entry, 'Rank');
    Result.Entries[Index].Index := ReadUInt(Entry, 'Index');
    Result.Entries[Index].Score := ReadScore(Entry);
    Result.Entries[Index].Submitted := ReadTimestamp(Entry, 'DateSubmitted');
  end;
end;

function ReadRAGamesList(Response: TJSONObject): TArray<TRAGameListEntry>;
var
  Items: TJSONArray;
  Game: TJSONObject;
begin
  Items := AsArray(Response.GetValue('Response'), 'Response');
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
  begin
    Game := AsObject(Items.Items[Index], 'game list entry');
    Result[Index].Game.ID := ReadUInt(Game, 'ID');
    Result[Index].Game.Title := ReadStringField(Game, 'Title');
    Result[Index].NumAchievements := ReadUInt(Game, 'NumAchievements');
    Result[Index].NumLeaderboards := ReadUInt(Game, 'NumLeaderboards');
    Result[Index].Points := ReadUInt(Game, 'Points');
    ReadGameImage(Game, True, '', Result[Index].Game);
    Result[Index].SupportedHashes := ReadStringArray(Game, 'SupportedHashes', True);
    Result[Index].UnsupportedHashes := ReadStringArray(Game, 'UnsupportedHashes', False);
  end;
end;

function ReadRAGameTitles(Response: TJSONObject; const ImageHost: string): TArray<TRAGameTitle>;
var
  Items: TJSONArray;
begin
  Items := AsArray(Response.GetValue('Response'), 'Response');
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
  begin
    var Game := AsObject(Items.Items[Index], 'game title entry');
    Result[Index].ID := ReadUInt(Game, 'ID');
    Result[Index].Title := ReadStringField(Game, 'Title');
    ReadGameImage(Game, False, ImageHost, Result[Index]);
  end;
end;

function ReadRAHashLibrary(Response: TJSONObject): TArray<TRAHashLibraryEntry>;
var
  Map: TJSONObject;
begin
  Map := ReadMap(Response, 'MD5List');
  if Map = nil then
    Exit(nil);
  SetLength(Result, Map.Count);
  for var Index := 0 to Map.Count - 1 do
  begin
    Result[Index].Hash := ReadRAStringToken(Map.Pairs[Index].JsonString);
    Result[Index].GameID := ReadUIntValue(Map.Pairs[Index].JsonValue, 'MD5List game ID');
  end;
end;

function ReadRALoginInfo(Response: TJSONObject; const ImageHost: string): TRALoginInfo;
var
  Avatar: TJSONValue;
begin
  Result := Default(TRALoginInfo);
  Result.Credentials := ReadRACredentials(Response);
  Result.DisplayName := Result.Credentials.UserName;
  Avatar := Response.GetValue('AvatarUrl');
  if (Avatar <> nil) and not (Avatar is TJSONNull) then
    Result.SetAvatarURL(ReadRAString(Avatar, 'AvatarUrl'))
  else
    Result.AvatarURL := ReadAvatarURL(Response, Result.DisplayName, ImageHost);
  Result.AvatarUpdated := ReadTimestamp(Response, 'AvatarUpdatedAt', False);
  Result.Score := ReadUInt(Response, 'Score', False);
  Result.SoftcoreScore := ReadUInt(Response, 'SoftcoreScore', False);
  Result.UnreadMessages := ReadUInt(Response, 'Messages', False);
end;

function ReadRAUserUnlocks(Response: TJSONObject): TArray<Cardinal>;
var
  Items: TJSONArray;
begin
  Items := AsArray(Response.GetValue('UserUnlocks'), 'UserUnlocks');
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
    Result[Index] := ReadUIntValue(Items.Items[Index], 'UserUnlocks achievement ID');
end;

function ReadRAFollowedUsers(Response: TJSONObject): TArray<TRAFollowedUser>;
var
  Items: TJSONArray;
  User: TJSONObject;
begin
  Items := AsArray(Response.GetValue('Friends'), 'Friends');
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
  begin
    User := AsObject(Items.Items[Index], 'Friends entry');
    Result[Index].DisplayName := ReadStringField(User, 'Friend');
    Result[Index].AvatarURL := ReadStringField(User, 'AvatarUrl');
    Result[Index].AvatarUpdated := ReadTimestamp(User, 'AvatarUpdatedAt', False);
    Result[Index].Score := ReadUInt(User, 'RAPoints');
    Result[Index].RecentActivity.GameID := ReadUInt(User, 'LastGameId', False);
    Result[Index].RecentActivity.GameTitle := ReadStringField(User, 'LastGameTitle', False);
    Result[Index].RecentActivity.GameImageURL := ReadStringField(User, 'LastGameIconUrl', False);
    Result[Index].RecentActivity.Description := ReadStringField(User, 'LastSeen', False);
    Result[Index].RecentActivity.SeenAt := ReadTimestamp(User, 'LastSeenTime', False);
  end;
end;

function ReadRAAllUserProgress(Response: TJSONObject): TArray<TRAUserGameProgress>;
var
  Map, Entry: TJSONObject;
  Pair: TJSONPair;
begin
  Map := ReadMap(Response, 'Response');
  if Map = nil then
    Exit(nil);
  SetLength(Result, Map.Count);
  for var Index := 0 to Map.Count - 1 do
  begin
    Pair := Map.Pairs[Index];
    Result[Index].GameID := ReadRALongPrefix(ReadRAStringToken(Pair.JsonString));
    Entry := AsObject(Pair.JsonValue, 'Response game progress');
    Result[Index].NumAchievements := ReadUInt(Entry, 'Achievements', False);
    Result[Index].NumUnlocked := ReadUInt(Entry, 'Unlocked', False);
    Result[Index].NumHardcoreUnlocked := ReadUInt(Entry, 'UnlockedHardcore', False);
  end;
end;

end.

