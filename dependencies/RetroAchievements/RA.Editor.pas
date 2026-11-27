unit RA.Editor;

interface

{$SCOPEDENUMS ON}

uses
  System.JSON, RA.Protocol;

type
  TRACodeNote = record
    Address: Cardinal;
    Author, Text: string;
  end;

  TRACodeNoteUpdate = record
    Address: Cardinal;
    Text: string;
  end;

  TRACodeNoteUpdateResult = record
    UpdatedAddresses, AccessDeniedAddresses: TArray<Cardinal>;
  end;

  TRAAchievementUpload = record
    ID, GameID, Points, Category: Cardinal;
    Kind: TRAAchievementKind;
    Title, Description, Badge, Trigger: string;
    IncludeEmptyBadge: Boolean;
  end;

  TRALeaderboardUpload = record
    ID, GameID: Cardinal;
    Title, Description, StartTrigger, SubmitTrigger, CancelTrigger, ValueDefinition, ValueFormat: string;
    LowerIsBetter: Boolean;
  end;

  TRABadgeRange = record
    FirstBadge, NextBadge: Cardinal;
  end;

  TRAEditorRequest = record
  public
    class function FetchCodeNotes(GameID: Cardinal): string; static;
    class function UpdateCodeNote(const Credentials: TRACredentials; GameID, Address: Cardinal; const Note: string): string; static;
    class function UpdateCodeNotes(const Credentials: TRACredentials; GameID: Cardinal; const Notes: array of TRACodeNoteUpdate): string; static;
    class function UpdateAchievement(const Credentials: TRACredentials; const Achievement: TRAAchievementUpload): string; static;
    class function UpdateLeaderboard(const Credentials: TRACredentials; const Leaderboard: TRALeaderboardUpload): string; static;
    class function UpdateRichPresence(const Credentials: TRACredentials; GameID: Cardinal; const Script: string): string; static;
    class function FetchBadgeRange: string; static;
    class function AddGameHash(const Credentials: TRACredentials; ConsoleID, GameID: Cardinal; const Hash, Title, Description: string; IncludeEmptyTitle: Boolean = False): string; static;
  end;

function ReadRACodeNotes(Response: TJSONObject): TArray<TRACodeNote>;

// A bulk update can partially succeed. Also accepts ERAServerError.Response for access_denied.
function ReadRACodeNoteUpdateResult(Response: TJSONObject): TRACodeNoteUpdateResult;

function ReadRAUpdatedAchievementID(Response: TJSONObject): Cardinal;

function ReadRAUpdatedLeaderboardID(Response: TJSONObject): Cardinal;

function ReadRABadgeRange(Response: TJSONObject): TRABadgeRange;

function ReadRAAddedGameHashID(Response: TJSONObject): Cardinal;

implementation

uses
  System.Generics.Collections, System.Hash, System.SysUtils;

procedure RequireEditorID(ID: Cardinal; const Name: string);
begin
  if ID = 0 then
    raise EArgumentException.CreateFmt('Invalid RetroAchievements %s', [Name]);
end;

procedure RequireEditorText(const Value, Name: string);
begin
  if (Value = '') or (Pos(#0, Value) <> 0) then
    raise EArgumentException.CreateFmt('Invalid RetroAchievements %s', [Name]);
end;

function UploadSignature(const UserName: string; ID: Cardinal; const Body: string): string;
var
  Hash: THashMD5;
begin
  Hash := THashMD5.Create;
  Hash.Update(TEncoding.UTF8.GetBytes(UserName + 'SECRET' + UIntToStr(ID) + 'SEC' + Body));
  Result := LowerCase(Hash.HashAsString);
end;

class function TRAEditorRequest.FetchCodeNotes(GameID: Cardinal): string;
begin
  RequireEditorID(GameID, 'game ID');
  Result := 'r=codenotes2&g=' + UIntToStr(GameID);
end;

class function TRAEditorRequest.UpdateCodeNote(const Credentials: TRACredentials; GameID, Address: Cardinal; const Note: string): string;
begin
  RequireEditorID(GameID, 'game ID');
  Result := AuthenticatedRAForm('submitcodenote', Credentials) + '&g=' + UIntToStr(GameID) +
    '&m=' + UIntToStr(Address);
  if Note <> '' then
    AppendRAFormField(Result, 'n', Note);
end;

class function TRAEditorRequest.UpdateCodeNotes(const Credentials: TRACredentials; GameID: Cardinal; const Notes: array of TRACodeNoteUpdate): string;
var
  Form: TStringBuilder;
  Escaped: string;
begin
  RequireEditorID(GameID, 'game ID');
  if Length(Notes) = 0 then
    raise EArgumentException.Create('RetroAchievements requires at least one code note');
  Form := TStringBuilder.Create;
  try
    Form.Append(AuthenticatedRAForm('submitcodenotes', Credentials)).Append('&g=').Append(UIntToStr(GameID))
      .Append('&n=');
    for var Note in Notes do
    begin
      // Delimiters separate notes. Preserve literal backslashes inside their text.
      Escaped := Note.Text.Replace('\', '\\').Replace(#13, '').Replace(#10, '\r\n');
      Form.Append(UIntToStr(Note.Address)).Append(':').Append(EncodeRAFormValue(Escaped)).Append('%0a');
    end;
    Result := Form.ToString;
  finally
    Form.Free;
  end;
end;

class function TRAEditorRequest.UpdateAchievement(const Credentials: TRACredentials; const Achievement: TRAAchievementUpload): string;
var
  SignatureBody: string;
begin
  RequireEditorID(Achievement.GameID, 'game ID');
  RequireEditorID(Achievement.Category, 'achievement category');
  RequireEditorText(Achievement.Title, 'achievement title');
  RequireEditorText(Achievement.Description, 'achievement description');
  RequireEditorText(Achievement.Trigger, 'achievement trigger');

  Result := AuthenticatedRAForm('uploadachievement', Credentials);
  if Achievement.ID <> 0 then
    Result := Result + '&a=' + UIntToStr(Achievement.ID);
  Result := Result + '&g=' + UIntToStr(Achievement.GameID);
  AppendRAFormField(Result, 'n', Achievement.Title);
  AppendRAFormField(Result, 'd', Achievement.Description);
  AppendRAFormField(Result, 'm', Achievement.Trigger);
  Result := Result + '&z=' + UIntToStr(Achievement.Points) + '&f=' + UIntToStr(Achievement.Category);
  if (Achievement.Badge <> '') or Achievement.IncludeEmptyBadge then
    AppendRAFormField(Result, 'b', Achievement.Badge);
  AppendRAFormField(Result, 'x', RAAchievementKindName(Achievement.Kind));
  SignatureBody := Achievement.Trigger + UIntToStr(Achievement.Points) + 'RE2' +
    UIntToStr((UInt64(Achievement.Points) * 3) and High(Cardinal));
  Result := Result + '&h=' + UploadSignature(Credentials.UserName, Achievement.ID, SignatureBody);
end;

class function TRAEditorRequest.UpdateLeaderboard(const Credentials: TRACredentials; const Leaderboard: TRALeaderboardUpload): string;
var
  SignatureBody: string;
begin
  RequireEditorID(Leaderboard.GameID, 'game ID');
  RequireEditorText(Leaderboard.Title, 'leaderboard title');
  RequireEditorText(Leaderboard.StartTrigger, 'leaderboard start trigger');
  RequireEditorText(Leaderboard.SubmitTrigger, 'leaderboard submit trigger');
  RequireEditorText(Leaderboard.CancelTrigger, 'leaderboard cancel trigger');
  RequireEditorText(Leaderboard.ValueDefinition, 'leaderboard value');
  RequireEditorText(Leaderboard.ValueFormat, 'leaderboard format');

  Result := AuthenticatedRAForm('uploadleaderboard', Credentials);
  if Leaderboard.ID <> 0 then
    Result := Result + '&i=' + UIntToStr(Leaderboard.ID);
  Result := Result + '&g=' + UIntToStr(Leaderboard.GameID);
  AppendRAFormField(Result, 'n', Leaderboard.Title);
  AppendRAFormField(Result, 'd', Leaderboard.Description);
  AppendRAFormField(Result, 's', Leaderboard.StartTrigger);
  AppendRAFormField(Result, 'b', Leaderboard.SubmitTrigger);
  AppendRAFormField(Result, 'c', Leaderboard.CancelTrigger);
  AppendRAFormField(Result, 'l', Leaderboard.ValueDefinition);
  Result := Result + '&w=' + IntToStr(Ord(Leaderboard.LowerIsBetter));
  AppendRAFormField(Result, 'f', Leaderboard.ValueFormat);
  SignatureBody := Leaderboard.StartTrigger + Leaderboard.SubmitTrigger +
    Leaderboard.CancelTrigger + Leaderboard.ValueDefinition + 'RE2' + Leaderboard.ValueFormat;
  Result := Result + '&h=' + UploadSignature(Credentials.UserName, Leaderboard.ID, SignatureBody);
end;

class function TRAEditorRequest.UpdateRichPresence(const Credentials: TRACredentials; GameID: Cardinal; const Script: string): string;
begin
  RequireEditorID(GameID, 'game ID');
  Result := AuthenticatedRAForm('submitrichpresence', Credentials) + '&g=' + UIntToStr(GameID);
  AppendRAFormField(Result, 'd', Script);
end;

class function TRAEditorRequest.FetchBadgeRange: string;
begin
  Result := 'r=badgeiter';
end;

class function TRAEditorRequest.AddGameHash(const Credentials: TRACredentials; ConsoleID, GameID: Cardinal; const Hash, Title, Description: string; IncludeEmptyTitle: Boolean): string;
begin
  RequireEditorID(ConsoleID, 'console ID');
  RequireEditorText(Hash, 'game hash');
  if GameID = 0 then
    RequireEditorText(Title, 'game title');
  Result := AuthenticatedRAForm('submitgametitle', Credentials) + '&c=' + UIntToStr(ConsoleID);
  AppendRAFormField(Result, 'm', Hash);
  if (Title <> '') or IncludeEmptyTitle then
    AppendRAFormField(Result, 'i', Title);
  if GameID <> 0 then
    Result := Result + '&g=' + UIntToStr(GameID);
  if Description <> '' then
    AppendRAFormField(Result, 'd', Description);
end;

function ReadEditorUInt(Value: TJSONValue; const Name: string): Cardinal;
begin
  if not TryReadRAUnsigned(Value, Result) then
    raise ERAResponseFieldError.Create(Name);
end;

function ReadCodeNoteAddress(Value: TJSONValue): Cardinal;
const
  {$IF Defined(CPU64BITS) and not Defined(MSWINDOWS)}
  Limit = High(UInt64);
  {$ELSE}
  Limit = UInt64(High(Cardinal));
  {$IFEND}
var
  Text: string;
  Index, Digit: Integer;
  Negative: Boolean;
  Address: UInt64;
begin
  if Value is TJSONNull then
    raise ERAResponseFieldError.Create('Address');
  Text := ReadRAString(Value, 'Address').TrimLeft([' ', #9, #10, #11, #12, #13]);
  Negative := Text.StartsWith('-');
  Index := 1;
  if Negative or Text.StartsWith('+') then
    Inc(Index);
  if SameText(Copy(Text, Index, 2), '0x') then
    Inc(Index, 2);

  // rcheevos reads a base-16 unsigned long, then narrows it to 32 bits.
  Address := 0;
  while Index <= Length(Text) do
  begin
    case Text[Index] of
      '0'..'9':
        Digit := Ord(Text[Index]) - Ord('0');
      'a'..'f':
        Digit := Ord(Text[Index]) - Ord('a') + 10;
      'A'..'F':
        Digit := Ord(Text[Index]) - Ord('A') + 10;
    else
      Break;
    end;
    if Address > (Limit - UInt64(Digit)) shr 4 then
      Exit(High(Cardinal));
    Address := (Address shl 4) or UInt64(Digit);
    Inc(Index);
  end;

  Result := Cardinal(Address and High(Cardinal));
  if Negative then
    Result := Cardinal(-Int64(Result) and High(Cardinal));
end;

function ReadRACodeNotes(Response: TJSONObject): TArray<TRACodeNote>;
var
  Notes: TJSONArray;
  Item: TJSONObject;
  Count: Integer;
  Note, Author: TJSONValue;
  AuthorCanBeOmitted: Boolean;
begin
  if not Response.TryGetValue<TJSONArray>('CodeNotes', Notes) then
    raise ERAResponseFieldError.Create('CodeNotes');
  SetLength(Result, Notes.Count);
  Count := 0;
  AuthorCanBeOmitted := True;
  for var Index := 0 to Notes.Count - 1 do
  begin
    if not (Notes.Items[Index] is TJSONObject) then
      raise ERAProtocolError.Create('Invalid RetroAchievements code note');
    Item := TJSONObject(Notes.Items[Index]);
    Note := Item.GetValue('Note');
    if (Note is TJSONString) and ((Note.Value = '') or (Note.Value = #39#39)) then
      Continue;
    if (Note <> nil) and not (Note is TJSONString) and (Length(Note.ToJSON) = 2) then
      Continue;
    Result[Count].Address := ReadCodeNoteAddress(Item.GetValue('Address'));
    Result[Count].Text := ReadRACString(Note, 'Note');
    Author := Item.GetValue('User');
    // The reference permits a missing author at the start or after a null author.
    if (Author <> nil) or not AuthorCanBeOmitted then
    begin
      Result[Count].Author := ReadRACString(Author, 'User');
      AuthorCanBeOmitted := Author is TJSONNull;
    end
    else
      Result[Count].Author := '';
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function ReadEditorUIntArray(Response: TJSONObject; const Name: string; Optional: Boolean): TArray<Cardinal>;
var
  Value: TJSONValue;
  Items: TJSONArray;
begin
  Value := Response.GetValue(Name);
  if not (Value is TJSONArray) then
  begin
    if Optional then
      Exit(nil);
    raise ERAResponseFieldError.Create(Name);
  end;
  Items := TJSONArray(Value);
  SetLength(Result, Items.Count);
  for var Index := 0 to Items.Count - 1 do
    if not TryReadRAUnsigned(Items.Items[Index], Result[Index]) then
    begin
      if not Optional then
        raise ERAResponseFieldError.Create(Name);
      SetLength(Result, Index);
      Break;
    end;
end;

function ReadRACodeNoteUpdateResult(Response: TJSONObject): TRACodeNoteUpdateResult;
begin
  Result.UpdatedAddresses := ReadEditorUIntArray(Response, 'SuccessfulAddresses', False);
  Result.AccessDeniedAddresses := ReadEditorUIntArray(Response, 'AccessDeniedAddresses', True);
end;

function ReadRAUpdatedAchievementID(Response: TJSONObject): Cardinal;
begin
  Result := ReadEditorUInt(Response.GetValue('AchievementID'), 'AchievementID');
end;

function ReadRAUpdatedLeaderboardID(Response: TJSONObject): Cardinal;
begin
  Result := ReadEditorUInt(Response.GetValue('LeaderboardID'), 'LeaderboardID');
end;

function ReadRABadgeRange(Response: TJSONObject): TRABadgeRange;
begin
  Result.FirstBadge := ReadEditorUInt(Response.GetValue('FirstBadge'), 'FirstBadge');
  Result.NextBadge := ReadEditorUInt(Response.GetValue('NextBadge'), 'NextBadge');
end;

function ReadRAAddedGameHashID(Response: TJSONObject): Cardinal;
var
  Data: TJSONObject;
begin
  if not Response.TryGetValue<TJSONObject>('Response', Data) then
    raise ERAResponseFieldError.Create('Response');
  Result := ReadEditorUInt(Data.GetValue('GameID'), 'GameID');
end;

end.

