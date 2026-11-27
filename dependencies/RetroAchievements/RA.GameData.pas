unit RA.GameData;

interface

uses
  System.JSON, RA.Format, RA.Protocol;

const
  RACoreAchievement = 3;
  RAUnofficialAchievement = 5;

type
  TRAAchievementDefinition = record
    ID, Category, Points: Cardinal;
    Title, Description, Definition, BadgeName, BadgeURL, BadgeLockedURL, Author: string;
    Kind: TRAAchievementKind;
    Created, Modified: Int64;
    Rarity, RarityHardcore: Single;
  end;

  TRALeaderboardDefinition = record
    ID: Cardinal;
    Title, Description, Definition: string;
    ValueFormat: TRAValueFormat;
    LowerIsBetter, Hidden: Boolean;
  end;

  TRAAchievementSet = record
    ID, GameID: Cardinal;
    Title, Kind, ImageURL, ImageName: string;
    Achievements: TArray<TRAAchievementDefinition>;
    Leaderboards: TArray<TRALeaderboardDefinition>;
  end;

  TRAGameData = record
  private
    FHasExplicitImageURL: Boolean;
  public
    ID, ConsoleID, RichPresenceGameID: Cardinal;
    Title, ImageURL, ImageName, RichPresence, Hash: string;
    Sets: TArray<TRAAchievementSet>;
    class operator Initialize(out Dest: TRAGameData);
    procedure SetImageURL(const URL: string);
    function Snapshot: TRAGameData;
    function CopyImageURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string = RAMediaHost): Integer;
  end;

  TRAUnlock = record
    AchievementID: Cardinal;
    Awarded: Int64;
  end;

  TRAStartSession = record
    Unlocks, HardcoreUnlocks: TArray<Cardinal>;
    UnlockDetails, HardcoreUnlockDetails: TArray<TRAUnlock>;
    ServerNow: Int64;
  end;

function ReadRAGameData(Response: TJSONObject; const ImageHost: string = ''): TRAGameData;

function ReadRAPatchData(Response: TJSONObject; const ImageHost: string = ''): TRAGameData;

function ReadRAStartSession(Response: TJSONObject): TRAStartSession;

implementation

uses
  System.Generics.Collections, System.SysUtils;

class operator TRAGameData.Initialize(out Dest: TRAGameData);
begin
  Dest.FHasExplicitImageURL := False;
end;

procedure TRAGameData.SetImageURL(const URL: string);
begin
  FHasExplicitImageURL := True;
  ImageURL := URL;
end;

function TRAGameData.Snapshot: TRAGameData;
begin
  Result := Self;
  Result.Sets := Copy(Sets);
  for var Index := 0 to High(Result.Sets) do
  begin
    Result.Sets[Index].Achievements := Copy(Sets[Index].Achievements);
    Result.Sets[Index].Leaderboards := Copy(Sets[Index].Leaderboards);
  end;
end;

function TRAGameData.CopyImageURL(Buffer: PAnsiChar; BufferSize: NativeUInt; const ImageHost: string): Integer;
begin
  if FHasExplicitImageURL then
    Exit(CopyRAImageURL(ImageURL, Buffer, BufferSize, True));
  Result := CopyRAImageURL(TRAImageKind.Game, ImageURL, ImageName, Buffer, BufferSize, ImageHost);
end;

function ReadID(Obj: TJSONObject; const Name: string): Cardinal;
begin
  if not TryReadRAUnsigned(Obj.GetValue(Name), Result) then
    raise ERAResponseFieldError.Create(Name);
end;

function ReadRequiredString(Obj: TJSONObject; const Name: string): string;
begin
  Result := ReadRACString(Obj.GetValue(Name), Name);
end;

function ReadOptionalString(Obj: TJSONObject; const Name: string): string;
var
  Value: TJSONValue;
begin
  Value := Obj.GetValue(Name);
  if Value = nil then
    Exit('');
  Result := ReadRACString(Value, Name);
end;

function JSONItem(List: TJSONArray; Index: Integer): TJSONObject;
begin
  if not (List.Items[Index] is TJSONObject) then
    raise ERAProtocolError.Create('Invalid object in RetroAchievements response');
  Result := TJSONObject(List.Items[Index]);
end;

function ReadTimestamp(Response: TJSONObject; const Field: string; Required: Boolean = True): Int64;
begin
  if not TryReadRATimestamp(Response.GetValue(Field), Result) and Required then
    raise ERAResponseFieldError.Create(Field);
end;

function ReadRarity(Item: TJSONObject; const Field: string): Single;
var
  Value: TJSONValue;
  Text: string;
  Whole, DecimalPoint, Fraction, Scale: Integer;
  WholeValue, FractionValue, ScaleValue: Single;
begin
  Value := Item.GetValue(Field);
  if not TryReadRASigned(Value, Whole) then
    Exit(100);

  WholeValue := Whole;
  Text := Value.Value;
  DecimalPoint := Pos('.', Text);
  if DecimalPoint = 0 then
    Exit(WholeValue);

  Fraction := 0;
  Scale := 1;
  // Nine fractional digits keep the C parser's integer arithmetic in range.
  for var Index := DecimalPoint + 1 to Length(Text) do
  begin
    if (Scale = 1000000000) or not CharInSet(Text[Index], ['0'..'9']) then
      Break;
    Fraction := Fraction * 10 + Ord(Text[Index]) - Ord('0');
    Scale := Scale * 10;
  end;

  // Upstream signs the fraction using the parsed whole part, including for -0.x.
  if Whole < 0 then
    Fraction := -Fraction;
  FractionValue := Fraction;
  ScaleValue := Scale;
  FractionValue := FractionValue / ScaleValue;
  Result := WholeValue + FractionValue;
end;

procedure ReadImageField(Value: TJSONValue; out ImageURL, ImageName: string);
begin
  if Value = nil then
  begin
    ImageURL := '';
    ImageName := '';
    Exit;
  end;
  ImageURL := ReadRACString(Value, 'ImageIconUrl');
  ImageName := ReadRAImageName(Value, 'ImageIconUrl');
end;

procedure ReadSetDefinitions(Obj: TJSONObject; var Definitions: TRAAchievementSet; const ImageHost: string);
var
  List: TJSONArray;
  Item: TJSONObject;
  Achievement: ^TRAAchievementDefinition;
  AuthorValue: TJSONValue;
  PreviousAuthorPresent: Boolean;
begin
  if not Obj.TryGetValue<TJSONArray>('Achievements', List) then
    raise ERAResponseFieldError.Create('Achievements');
  SetLength(Definitions.Achievements, List.Count);
  PreviousAuthorPresent := False;
  for var Index := 0 to List.Count - 1 do
  begin
    Item := JSONItem(List, Index);
    Achievement := @Definitions.Achievements[Index];
    Achievement.ID := ReadID(Item, 'ID');
    if Item.GetValue('Title') is TJSONNull then
      raise ERAResponseFieldError.Create('Title');
    Achievement.Title := ReadRequiredString(Item, 'Title');
    Achievement.Description := ReadRequiredString(Item, 'Description');
    Achievement.Category := ReadID(Item, 'Flags');
    Achievement.Points := ReadID(Item, 'Points');
    Achievement.Definition := ReadRequiredString(Item, 'MemAddr');
    Achievement.BadgeName := ReadRequiredString(Item, 'BadgeName');
    // The upstream parser reuses the empty author token until a non-null author is read.
    AuthorValue := Item.GetValue('Author');
    if (AuthorValue <> nil) or PreviousAuthorPresent then
      Achievement.Author := ReadRequiredString(Item, 'Author');
    PreviousAuthorPresent := (AuthorValue <> nil) and not (AuthorValue is TJSONNull);
    Achievement.Created := ReadTimestamp(Item, 'Created');
    Achievement.Modified := ReadTimestamp(Item, 'Modified');
    Achievement.Kind := ParseRAAchievementKind(ReadRAStringToken(Item.GetValue('Type')));
    if Achievement.Title.StartsWith('[m]') then
    begin
      Achievement.Title := Achievement.Title.Substring(3).TrimLeft([' ']);
      Achievement.Kind := TRAAchievementKind.Missable;
    end
    else if Achievement.Title.EndsWith('[m]') then
    begin
      Achievement.Title := Achievement.Title.Substring(0, Achievement.Title.Length - 3).TrimRight([' ']);
      Achievement.Kind := TRAAchievementKind.Missable;
    end;
    Achievement.Rarity := ReadRarity(Item, 'Rarity');
    Achievement.RarityHardcore := ReadRarity(Item, 'RarityHardcore');
    Achievement.BadgeURL := ReadOptionalString(Item, 'BadgeURL');
    Achievement.BadgeLockedURL := ReadOptionalString(Item, 'BadgeLockedURL');
    if Achievement.BadgeName <> '' then
    begin
      if Achievement.BadgeURL = '' then
        Achievement.BadgeURL := BuildRAImageURL(TRAImageKind.Achievement, Achievement.BadgeName, ImageHost);
      if Achievement.BadgeLockedURL = '' then
        Achievement.BadgeLockedURL := BuildRAImageURL(TRAImageKind.LockedAchievement, Achievement.BadgeName, ImageHost);
    end;
  end;

  if not Obj.TryGetValue<TJSONArray>('Leaderboards', List) then
    raise ERAResponseFieldError.Create('Leaderboards');
  SetLength(Definitions.Leaderboards, List.Count);
  for var Index := 0 to List.Count - 1 do
  begin
    Item := JSONItem(List, Index);
    Definitions.Leaderboards[Index].ID := ReadID(Item, 'ID');
    Definitions.Leaderboards[Index].Title := ReadRequiredString(Item, 'Title');
    Definitions.Leaderboards[Index].Description := ReadRequiredString(Item, 'Description');
    Definitions.Leaderboards[Index].Definition := ReadRequiredString(Item, 'Mem');
    Definitions.Leaderboards[Index].ValueFormat := ReadRALeaderboardFormat(Item.GetValue('Format'), 'Format');
    TryReadRABoolean(Item.GetValue('LowerIsBetter'), Definitions.Leaderboards[Index].LowerIsBetter);
    TryReadRABoolean(Item.GetValue('Hidden'), Definitions.Leaderboards[Index].Hidden);
  end;
end;

function ReadSet(Obj: TJSONObject; const Game: TRAGameData; CanShareImage: Boolean; const ImageHost: string): TRAAchievementSet;
var
  Image: TJSONValue;
begin
  Result.ID := ReadID(Obj, 'AchievementSetId');
  Result.GameID := ReadID(Obj, 'GameId');
  Result.Title := ReadRequiredString(Obj, 'Title');
  if Result.Title = '' then
    Result.Title := Game.Title;
  Result.Kind := ReadRAStringToken(Obj.GetValue('Type'));
  if not (Result.Kind = 'core') and not (Result.Kind = 'specialty') and not (Result.Kind = 'exclusive') then
    Result.Kind := 'bonus';
  Image := Obj.GetValue('ImageIconUrl');
  if Image = nil then
    raise ERAResponseFieldError.Create('ImageIconUrl');
  if CanShareImage and RAStringTokenMatches(Image, Game.ImageURL) then
  begin
    Result.ImageURL := Game.ImageURL;
    Result.ImageName := Game.ImageName;
  end
  else
    ReadImageField(Image, Result.ImageURL, Result.ImageName);
  ReadSetDefinitions(Obj, Result, ImageHost);
end;

function ReadRAGameData(Response: TJSONObject; const ImageHost: string): TRAGameData;
var
  List: TJSONArray;
  Image: TJSONValue;
  CanShareImage: Boolean;
begin
  Result := Default(TRAGameData);
  Result.ID := ReadID(Response, 'GameId');
  Result.Title := ReadRequiredString(Response, 'Title');
  Result.ConsoleID := ReadID(Response, 'ConsoleId');
  Image := Response.GetValue('ImageIconUrl');
  ReadImageField(Image, Result.ImageURL, Result.ImageName);
  CanShareImage := (Image <> nil) and not (Image is TJSONNull);
  Result.RichPresence := ReadOptionalString(Response, 'RichPresencePatch');
  if not TryReadRAUnsigned(Response.GetValue('RichPresenceGameId'), Result.RichPresenceGameID) then
    Result.RichPresenceGameID := Result.ID;
  if Response.TryGetValue<TJSONArray>('Sets', List) then
  begin
    SetLength(Result.Sets, List.Count);
    for var Index := 0 to List.Count - 1 do
      Result.Sets[Index] := ReadSet(JSONItem(List, Index), Result, CanShareImage, ImageHost);
  end;
  // Nested required-field failures take precedence over the top-level image error.
  if Image = nil then
    raise ERAProtocolError.Create('ImageIconUrl not found in response');
end;

function ReadRAPatchData(Response: TJSONObject; const ImageHost: string): TRAGameData;
var
  Patch: TJSONObject;
  Icon: TJSONValue;
begin
  Result := Default(TRAGameData);
  if not Response.TryGetValue<TJSONObject>('PatchData', Patch) then
    raise ERAResponseFieldError.Create('PatchData');
  Result.ID := ReadID(Patch, 'ID');
  Result.Title := ReadRequiredString(Patch, 'Title');
  Result.ConsoleID := ReadID(Patch, 'ConsoleID');
  Result.RichPresenceGameID := Result.ID;
  Icon := Patch.GetValue('ImageIcon');
  if Icon <> nil then
    Result.ImageName := ReadRAImageName(Icon, 'ImageIcon');
  Result.ImageURL := ReadOptionalString(Patch, 'ImageIconURL');
  if (Result.ImageURL = '') and (Result.ImageName <> '') then
    Result.ImageURL := BuildRAImageURL(TRAImageKind.Game, Result.ImageName, ImageHost);
  Result.RichPresence := ReadOptionalString(Patch, 'RichPresencePatch');
  // The legacy endpoint supplies a single set without a set ID.
  SetLength(Result.Sets, 1);
  Result.Sets[0].GameID := Result.ID;
  Result.Sets[0].Title := Result.Title;
  Result.Sets[0].Kind := 'core';
  Result.Sets[0].ImageName := Result.ImageName;
  Result.Sets[0].ImageURL := Result.ImageURL;
  ReadSetDefinitions(Patch, Result.Sets[0], ImageHost);
end;

function ReadUnlocks(Response: TJSONObject; const Field: string; out IDs: TArray<Cardinal>): TArray<TRAUnlock>;
var
  List: TJSONArray;
  Item: TJSONObject;
begin
  Result := nil;
  IDs := nil;
  if Response.TryGetValue<TJSONArray>(Field, List) then
  begin
    SetLength(Result, List.Count);
    SetLength(IDs, List.Count);
    for var Index := 0 to List.Count - 1 do
    begin
      Item := JSONItem(List, Index);
      IDs[Index] := ReadID(Item, 'ID');
      Result[Index].AchievementID := IDs[Index];
      Result[Index].Awarded := ReadTimestamp(Item, 'When');
    end;
  end;
end;

function ReadRAStartSession(Response: TJSONObject): TRAStartSession;
begin
  Result.UnlockDetails := ReadUnlocks(Response, 'Unlocks', Result.Unlocks);
  Result.HardcoreUnlockDetails := ReadUnlocks(Response, 'HardcoreUnlocks', Result.HardcoreUnlocks);
  Result.ServerNow := ReadTimestamp(Response, 'ServerNow', False);
end;

end.

