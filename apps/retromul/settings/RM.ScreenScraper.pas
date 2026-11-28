unit RM.ScreenScraper;

interface

uses
  System.Classes, System.IniFiles, System.Generics.Collections, System.JSON,
  System.Net.HttpClient, Core.Storage;

const
  ScraperSection = 'ScreenScraper';

type
  TScraperOptions = record
    Enabled, Anonymous: Boolean;
    UserName, Password, Language: string;
    class function Read(Ini: TCustomIniFile): TScraperOptions; static;
    function SameAccount(const Other: TScraperOptions): Boolean;
    function SameSettings(const Other: TScraperOptions): Boolean;
  end;

  TScraperJob = record
    Key, Folder, XMLFile, SystemId, ScreenSystemId, Location, Name, RelativePath: string;
    Size: Int64;
  end;

  TScraperUpdate = record
    Job: TScraperJob;
    Found: Boolean;
    Title, Description, Developer, Genre, Players, Image, Thumbnail, Box: string;
  end;

  TScraperStatus = record
    Error: string;
    Checking: Boolean;
    HTTPStatusCode: Integer;
    Remaining, Limit, FailedRemaining, FailedLimit: Integer;
    class function Empty: TScraperStatus; static;
  end;

  TScreenScraperWorker = class(TThread)
  private
    FStorage: IStorage;
    FOptions: TScraperOptions;
    FJobs: TArray<TScraperJob>;
    FUpdates: TList<TScraperUpdate>;
    FHTTP: THTTPClient;
    FAuth: string;
    FStatus: TScraperStatus;
    FRetryAfter: Cardinal;
    procedure ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);
    procedure CheckCancelled;
    procedure PublishStatus;
    procedure ReadQuota(const Response: TJSONObject);
    function Request(const Endpoint, Params: string): TJSONObject;
    function Lookup(const Job: TScraperJob): TJSONObject;
    function Scrape(const Job: TScraperJob): TScraperUpdate;
  protected
    procedure Execute; override;
  public
    constructor Create(const Storage: IStorage; const Options: TScraperOptions; const Jobs: TArray<TScraperJob>);
    destructor Destroy; override;
    function TakeUpdates: TArray<TScraperUpdate>;
    function Cancelled: Boolean;
    property RetryAfter: Cardinal read FRetryAfter;
  end;

function ScreenScraperSystem(const SystemId, FileName: string): string;

function ScreenScraperStatus(const Options: TScraperOptions): TScraperStatus;

procedure WriteScraperPassword(Ini: TCustomIniFile; const UserName, Password: string);

procedure RefreshScreenScraperQuota(const Storage: IStorage; const Options: TScraperOptions);

function ScraperApplicationConfigured: Boolean;

function ScraperNativePath(const Folder, Value: string): string;

implementation

uses
  System.SysUtils, System.IOUtils, System.StrUtils, System.Math, System.Hash,
  System.NetEncoding, System.Net.URLClient, System.RegularExpressions,
  Xml.XMLIntf, Xml.XMLDoc, Xml.xmldom, Xml.OmniXMLDom, Core.MediaArchive,
  Core.Archive.Container
  {$IFDEF MSWINDOWS}, RA.Account{$ENDIF};

const
  APIBase = 'https://api.screenscraper.fr/api2/';
  ApplicationIdVariable = 'RETROMUL_SCREENSCRAPER_DEVID';
  ApplicationPasswordVariable = 'RETROMUL_SCREENSCRAPER_DEVPASSWORD';
  ApplicationCredentialsFile = 'ScreenScraper.Application.inc';

type
  EScraperHTTP = class(Exception)
    Code: Integer;
    constructor Create(Code: Integer);
  end;

var
  StatusLock: TObject;
  LastStatus: TScraperStatus;
  StatusOptions: TScraperOptions;
  HasStatus: Boolean;
  QuotaWorker: TScreenScraperWorker;
  LocalApplicationID, LocalApplicationPassword: string;

class function TScraperOptions.Read(Ini: TCustomIniFile): TScraperOptions;
begin
  Result.Enabled := Ini.ReadBool(ScraperSection, 'Enabled', False);
  Result.Anonymous := Ini.ReadBool(ScraperSection, 'Anonymous', True);
  Result.UserName := Ini.ReadString(ScraperSection, 'UserName', '').Trim;
  {$IFDEF MSWINDOWS}
  try
    Result.Password := UnprotectAccountSecret('ScreenScraper:' + Result.UserName,
      Ini.ReadString(ScraperSection, 'ProtectedPassword', ''));
  except
    on E: EConvertError do
      Result.Password := '';
  end;
  {$ELSE}
  Result.Password := Ini.ReadString(ScraperSection, 'Password', '');
  {$ENDIF}
  Result.Language := Ini.ReadString('General', 'Language', 'en');
end;

procedure WriteScraperPassword(Ini: TCustomIniFile; const UserName, Password: string);
begin
  {$IFDEF MSWINDOWS}
  if Password <> '' then
    Ini.WriteString(ScraperSection, 'ProtectedPassword', ProtectAccountSecret('ScreenScraper:' + UserName, Password))
  else
    Ini.DeleteKey(ScraperSection, 'ProtectedPassword');
  {$ELSE}
  Ini.WriteString(ScraperSection, 'Password', Password);
  {$ENDIF}
end;

function TScraperOptions.SameAccount(const Other: TScraperOptions): Boolean;
begin
  Result := (Anonymous = Other.Anonymous) and
    (Anonymous or ((UserName = Other.UserName) and (Password = Other.Password)));
end;

function TScraperOptions.SameSettings(const Other: TScraperOptions): Boolean;
begin
  Result := (Enabled = Other.Enabled) and (Language = Other.Language) and SameAccount(Other);
end;

class function TScraperStatus.Empty: TScraperStatus;
begin
  Result.Error := '';
  Result.Checking := False;
  Result.HTTPStatusCode := 0;
  Result.Remaining := -1;
  Result.Limit := -1;
  Result.FailedRemaining := -1;
  Result.FailedLimit := -1;
end;

function ScreenScraperStatus(const Options: TScraperOptions): TScraperStatus;
begin
  TMonitor.Enter(StatusLock);
  try
    if HasStatus and Options.SameAccount(StatusOptions) then
      Result := LastStatus
    else
      Result := TScraperStatus.Empty;
    Result.Checking := (QuotaWorker <> nil) and not QuotaWorker.Finished and
      Options.SameAccount(QuotaWorker.FOptions);
  finally
    TMonitor.Exit(StatusLock);
  end;
end;

procedure LoadLocalApplicationCredentials;

  function CredentialValue(const Source, Name: string): string;
  begin
    var Match := TRegEx.Match(Source, '^\s*' + Name + '\s*=\s*''((?:''''|[^''\r\n])*)''\s*;',
      [roMultiLine]);
    if Match.Success then
      Result := Match.Groups[1].Value.Replace('''''', '''')
    else
      Result := '';
  end;

begin
  var Directory := ExtractFileDir(ExpandFileName(ParamStr(0)));
  var RelativeFile := TPath.Combine('credentials', ApplicationCredentialsFile);
  var FileName := TPath.Combine(Directory, RelativeFile);
  if not TFile.Exists(FileName) then
  begin
    // Binaries built inside a checkout share its local credential file.
    var Project := TPath.Combine('apps', TPath.Combine('retromul', 'RetroMul.dproj'));
    while not TFile.Exists(TPath.Combine(Directory, Project)) do
    begin
      var Parent := TPath.GetDirectoryName(Directory);
      if (Parent = '') or (Parent = Directory) then
        Exit;
      Directory := Parent;
    end;
    FileName := TPath.Combine(Directory, RelativeFile);
  end;
  if not TFile.Exists(FileName) then
    Exit;
  try
    var Source := TFile.ReadAllText(FileName, TEncoding.UTF8);
    LocalApplicationID := CredentialValue(Source, 'ScreenScraperApplicationID');
    LocalApplicationPassword := CredentialValue(Source, 'ScreenScraperApplicationPassword');
  except
    // The settings page reports unavailable credentials for an unreadable file.
    LocalApplicationID := '';
    LocalApplicationPassword := '';
  end;
end;

procedure ReadApplicationCredentials(out ID, Password: string);
begin
  ID := GetEnvironmentVariable(ApplicationIdVariable);
  Password := GetEnvironmentVariable(ApplicationPasswordVariable);
  if (ID = '') or (Password = '') then
  begin
    ID := LocalApplicationID;
    Password := LocalApplicationPassword;
  end;
end;

function ScraperApplicationConfigured: Boolean;
begin
  var ID, Password: string;
  ReadApplicationCredentials(ID, Password);
  Result := (ID <> '') and (Password <> '');
end;

procedure RefreshScreenScraperQuota(const Storage: IStorage; const Options: TScraperOptions);
begin
  TMonitor.Enter(StatusLock);
  try
    if (QuotaWorker <> nil) and not QuotaWorker.Finished then
      Exit;
    FreeAndNil(QuotaWorker);
    QuotaWorker := TScreenScraperWorker.Create(Storage, Options, nil);
    QuotaWorker.Start;
  finally
    TMonitor.Exit(StatusLock);
  end;
end;

function ScreenScraperSystem(const SystemId, FileName: string): string;
const
  Systems: array[0..44] of string = ('md', 'sms', 'nes', 'snes', 'cps1', 'cps2', 'cps3',
    'gb', 'gbc', 'gba', 'n64', 'nds', 'sega32x', 'segacd', 'gg', 'saturn', 'dc',
    'ngp', 'at2600', 'jaguar', 'lynx', 'pce', 'at5200', 'at7800', 'ws', 'wsc',
    'colecovision', 'gw', 'ps1', 'ps2', 'psp', 'neogeocd', 'zx', 'ngpc', 'sgx',
    'fds', 'sg1000', 'msx1', 'pcecd', 'intellivision', 'msx2', 'msx2plus',
    'neogeo', 'jaguarcd', 'j2me');
  IDs: array[Low(Systems)..High(Systems)] of Integer = (1, 2, 3, 4, 6, 7, 8,
    9, 10, 12, 14, 15, 19, 20, 21, 22, 23, 25, 26, 27, 28, 31, 40, 41, 45, 46,
    48, 52, 57, 58, 61, 70, 76, 82, 105, 106, 109, 113, 114, 115, 116, 117, 142, 171, 302);
begin
  if SameText(SystemId, 'nes') and MatchText(ExtractFileExt(FileName), ['.fds', '.qd']) then
    Exit('106');
  if SameText(SystemId, 'atari800') then
    Exit('43');
  // ScreenScraper catalogs these titles under SG-1000.
  if MatchText(SystemId, ['omv', 'sc3000', 'sf7000']) then
    Exit('109');
  // The System Changer runs Atari 2600 cartridges.
  if SameText(SystemId, 'intv-system-changer') then
    Exit('26');
  if MatchText(SystemId, ['system16', 'system18', 'system32']) then
    Exit('147'); // Sega Classics
  var Index := IndexText(SystemId, Systems);
  if Index >= 0 then
    Result := IDs[Index].ToString
  else
    Result := '';
end;

function ScraperNativePath(const Folder, Value: string): string;
begin
  if Value.Trim = '' then
    Exit('');
  Result := TPath.Combine(Folder, Value.Replace('/', PathDelim).Replace('\', PathDelim));
end;

function JSONValue(Value: TJSONValue; const Path: string): TJSONValue;
begin
  if Value = nil then
    Exit(nil);
  Result := Value.FindValue(Path);
end;

function JSONText(Value: TJSONValue; const Path: string): string;
begin
  var Field := JSONValue(Value, Path);
  if Field is TJSONString then
    Exit(Field.Value);
  if Field is TJSONNumber then
    Exit(Field.Value);
  Result := '';
end;

function PickEntry(Value: TJSONValue; const List, Key, Priorities: string): TJSONValue;
begin
  Result := nil;
  var Entries := JSONValue(Value, List);
  if not (Entries is TJSONArray) then
    Exit;
  for var Priority in Priorities.Split([',']) do
    for var Entry in TJSONArray(Entries) do
      if ((List <> 'medias') or SameText(JSONText(Entry, 'type'), 'box-2D')) and
        ((Priority = '*') or SameText(JSONText(Entry, Key), Priority)) then
        Exit(Entry);
end;

function Encode(const Value: string): string;
begin
  Result := TNetEncoding.URL.Encode(Value);
end;

function CleanGameName(const Value: string): string;
begin
  Result := TRegEx.Replace(Value, '[\(\[].*?[\)\]]', '').Replace('_', ' ').Trim;
end;

function SafeRelativePath(const Value: string): string;
begin
  Result := Value.Replace('\', '/');
  if (Result = '') or TPath.IsPathRooted(Result) or Result.Contains(':') then
    Exit('');
  for var Part in Result.Split(['/']) do
    if (Part = '') or (Part = '.') or (Part = '..') then
      Exit('');
end;

function NodeText(const Node: IXMLNode; const Name: string): string;
begin
  if Node = nil then
    Exit('');
  var Field := Node.ChildNodes.FindNode(Name);
  if Field = nil then
    Exit('');
  Result := Field.Text;
end;

procedure FillField(const Node: IXMLNode; const Name, Value: string);
begin
  if (Value <> '') and (NodeText(Node, Name).Trim = '') then
  begin
    var Field := Node.ChildNodes.FindNode(Name);
    if Field = nil then
      Field := Node.AddChild(Name);
    Field.Text := Value;
  end;
end;

function LoadGameList(const Storage: IStorage; const FileName: string): IXMLDocument;
begin
  var Document := TXMLDocument.Create(nil);
  Result := Document;
  Document.DOMVendor := GetDOMVendor(sOmniXmlVendor);
  if Storage.Exists(FileName) then
  begin
    var Input := Storage.OpenRead(FileName);
    try
      Result.LoadFromStream(Input);
    finally
      Input.Free;
    end;
    if (Result.DocumentElement = nil) or (Result.DocumentElement.NodeName <> 'gameList') then
      raise EConvertError.Create('Invalid gamelist.xml');
  end
  else
  begin
    Result.Active := True;
    Result.Encoding := 'UTF-8';
    Result.AddChild('gameList');
  end;
end;

function FindGameNode(const Root: IXMLNode; const Job: TScraperJob): IXMLNode;
begin
  Result := nil;
  for var I := 0 to Root.ChildNodes.Count - 1 do
  begin
    var Candidate := Root.ChildNodes[I];
    if Candidate.NodeName <> 'game' then
      Continue;
    var Location := ScraperNativePath(Job.Folder, NodeText(Candidate, 'path'));
    if (Location <> '') and
      {$IFDEF MSWINDOWS} SameText(ExpandFileName(Location), ExpandFileName(Job.Location))

      {$ELSE} (ExpandFileName(Location) = ExpandFileName(Job.Location)) {$ENDIF} then
      Exit(Candidate);
  end;
end;

constructor EScraperHTTP.Create(Code: Integer);
begin
  inherited Create('ScreenScraper HTTP ' + Code.ToString);
  Self.Code := Code;
end;

constructor TScreenScraperWorker.Create(const Storage: IStorage; const Options: TScraperOptions; const Jobs: TArray<TScraperJob>);
begin
  inherited Create(True);
  FStorage := Storage;
  FOptions := Options;
  FJobs := Jobs;
  FUpdates := TList<TScraperUpdate>.Create;
  FStatus := ScreenScraperStatus(Options);
  FStatus.Error := '';
  FStatus.HTTPStatusCode := 0;
  FStatus.Checking := False;
end;

destructor TScreenScraperWorker.Destroy;
begin
  inherited;
  FUpdates.Free;
end;

function TScreenScraperWorker.Cancelled: Boolean;
begin
  Result := Terminated;
end;

function TScreenScraperWorker.TakeUpdates: TArray<TScraperUpdate>;
begin
  TMonitor.Enter(FUpdates);
  try
    Result := FUpdates.ToArray;
    FUpdates.Clear;
  finally
    TMonitor.Exit(FUpdates);
  end;
end;

procedure TScreenScraperWorker.ReceiveData(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean);
begin
  Abort := Terminated or (ReadCount > 16 * 1024 * 1024);
end;

procedure TScreenScraperWorker.CheckCancelled;
begin
  if Terminated then
    Abort;
end;

procedure TScreenScraperWorker.PublishStatus;
begin
  CheckCancelled;
  TMonitor.Enter(StatusLock);
  try
    StatusOptions := FOptions;
    HasStatus := True;
    LastStatus := FStatus;
  finally
    TMonitor.Exit(StatusLock);
  end;
end;

procedure TScreenScraperWorker.ReadQuota(const Response: TJSONObject);
var
  Account: TJSONValue;

  procedure ReadLimits(const UsedKey, LimitKey: string; var Remaining, Limit: Integer);
  begin
    var Used := StrToIntDef(JSONText(Account, UsedKey), -1);
    var Maximum := StrToIntDef(JSONText(Account, LimitKey), -1);
    if (Used >= 0) and (Maximum > 0) then
    begin
      Remaining := Max(0, Maximum - Used);
      Limit := Maximum;
    end;
  end;

begin
  Account := JSONValue(Response, 'response.ssuser');
  if Account = nil then
    Account := JSONValue(Response, 'ssuser');
  ReadLimits('requeststoday', 'maxrequestsperday', FStatus.Remaining, FStatus.Limit);
  ReadLimits('requestskotoday', 'maxrequestskoperday', FStatus.FailedRemaining, FStatus.FailedLimit);
  PublishStatus;
end;

function TScreenScraperWorker.Request(const Endpoint, Params: string): TJSONObject;
begin
  CheckCancelled;
  var Response := FHTTP.Get(APIBase + Endpoint + '?output=json' + FAuth + Params);
  CheckCancelled;
  if Endpoint = 'jeuInfos.php' then
  begin
    if FStatus.Remaining > 0 then
      Dec(FStatus.Remaining);
    if (Response.StatusCode = 404) and (FStatus.FailedRemaining > 0) then
      Dec(FStatus.FailedRemaining);
    PublishStatus;
  end;
  if (Response.StatusCode = 404) and (Endpoint = 'jeuInfos.php') then
    Exit(nil);
  if Response.StatusCode <> 200 then
    raise EScraperHTTP.Create(Response.StatusCode);
  var Parsed := TJSONObject.ParseJSONValue(Response.ContentAsString(TEncoding.UTF8));
  if not (Parsed is TJSONObject) then
  begin
    Parsed.Free;
    raise EConvertError.Create('Invalid ScreenScraper response');
  end;
  try
    ReadQuota(TJSONObject(Parsed));
  except
    Parsed.Free;
    raise;
  end;
  Result := TJSONObject(Parsed);
end;

function TScreenScraperWorker.Lookup(const Job: TScraperJob): TJSONObject;
const
  MaxHashSize = 32 * 1024 * 1024;

  function ROMHash(Input: TStream): string;
  var
    Buffer: array[0..65535] of Byte;
    Count: Integer;
  begin
    var MD5 := THashMD5.Create;
    repeat
      CheckCancelled;
      Count := Input.Read(Buffer, SizeOf(Buffer));
      if Count > 0 then
        MD5.Update(Buffer, Count);
    until Count = 0;
    Result := '&md5=' + MD5.HashAsString;
  end;

begin
  var Params := '&systemeid=' + Job.ScreenSystemId;
  var ROMName := Job.Name;
  var ROMSize := Job.Size;
  var Hash := '';
  if (ROMSize > 0) and (ROMSize <= MaxHashSize) then
  begin
    var Input := FStorage.OpenRead(Job.Location);
    try
      if SameText(Job.SystemId, 'omv') and IsMediaArchive(Job.Name) then
      begin
        var Archive := OpenMediaArchive(Input, Job.Name, FStorage);
        var Candidate := -1;
        for var I := 0 to Archive.Count - 1 do
        begin
          var Entry := Archive.Entries[I];
          if Entry.IsDirectory or not MatchText(ExtractFileExt(Entry.Name), ['.bin', '.mv']) then
            Continue;
          if Candidate <> -1 then
          begin
            Candidate := -1;
            Break;
          end;
          Candidate := I;
        end;
        if Candidate >= 0 then
        begin
          var Entry := Archive.Entries[Candidate];
          if (Entry.Size > 0) and (Entry.Size <= MaxHashSize) then
          begin
            var ROM := Archive.OpenRead(Candidate);
            try
              Hash := ROMHash(ROM);
              if Entry.HasCRC then
                Hash := Hash + '&crc=' + IntToHex(Entry.CRC32, 8);
              ROMName := ExtractFileName(Entry.Name.Replace('/', PathDelim).Replace('\', PathDelim));
              ROMSize := Entry.Size;
            finally
              ROM.Free;
            end;
          end;
        end;
        Archive := nil;
        Input.Position := 0;
      end;
      if Hash = '' then
        Hash := ROMHash(Input);
    finally
      Input.Free;
    end;
  end;
  Result := Request('jeuInfos.php', Params + '&romtype=rom&romnom=' + Encode(ROMName) +
    '&romtaille=' + ROMSize.ToString + Hash);
  if JSONValue(Result, 'response.jeu') is TJSONObject then
    Exit;
  FreeAndNil(Result);
  if (FStatus.Remaining = 0) or (FStatus.FailedRemaining = 0) then
    Exit;
  var Name := CleanGameName(ChangeFileExt(Job.Name, ''));
  if Name <> '' then
    Result := Request('jeuInfos.php', Params + '&romtype=jeu&romnom=' + Encode(Name));
end;

function TScreenScraperWorker.Scrape(const Job: TScraperJob): TScraperUpdate;
begin
  Result := Default(TScraperUpdate);
  Result.Job := Job;
  var Relative := SafeRelativePath(Job.RelativePath);
  if (Relative = '') or not FStorage.Exists(Job.Location) then
    Exit;

  // The list can change between the library scan and a queued lookup.
  var XML := LoadGameList(FStorage, Job.XMLFile);
  if FindGameNode(XML.DocumentElement, Job) <> nil then
    Exit;
  var Data: TMemoryStream := nil;
  var Response := Lookup(Job);
  try
    var Game := JSONValue(Response, 'response.jeu');
    if not (Game is TJSONObject) then
      Exit;
    var PreferredRegion := JSONText(Game, 'rom.romregions');
    var Regions := PreferredRegion.ToLower.Replace(' ', '').Trim([',']) + ',us,wor,eu,jp,*';
    var Languages := FOptions.Language + ',en,*';
    var Cover := '';
    var Media := PickEntry(Game, 'medias', 'region', Regions);
    var URL := JSONText(Media, 'url');
    var Format := JSONText(Media, 'format').ToLower;
    if URL.StartsWith('https://', True) and MatchText(Format, ['png', 'jpg', 'jpeg', 'webp']) then
    begin
      var URI := TURI.Create(URL);
      if SameText(URI.Host, 'screenscraper.fr') or URI.Host.EndsWith('.screenscraper.fr', True) then
      begin
        XML := LoadGameList(FStorage, Job.XMLFile);
        if FindGameNode(XML.DocumentElement, Job) <> nil then
          Exit;
        Data := TMemoryStream.Create;
        // The API may embed credentials in media URLs. Replace them with the active account.
        URL := TRegEx.Replace(URL, '([?&])(devid|devpassword|ssid|sspassword|softname)=[^&]*', '$1', [roIgnoreCase]);
        while URL.Contains('&&') do
          URL := URL.Replace('&&', '&');
        URL := URL.Replace('?&', '?').TrimRight(['?', '&']);
        if URL.Contains('?') then
          URL := URL + FAuth
        else
          URL := URL + '?' + FAuth.Substring(1);
        CheckCancelled;
        var Download := FHTTP.Get(URL, Data);
        CheckCancelled;
        if Download.StatusCode = 200 then
        begin
          if (Data.Size = 0) or (Data.Size > 16 * 1024 * 1024) or
            not Download.HeaderValue['Content-Type'].StartsWith('image/', True) then
            raise EConvertError.Create('Invalid ScreenScraper cover');
          Cover := './media/images/' + ChangeFileExt(Relative, '.' + Format);
          if FStorage.Exists(ScraperNativePath(Job.Folder, Cover)) then
            Cover := './media/images/' + Relative + '.' + Format;
        end
        else if Download.StatusCode <> 404 then
          raise EScraperHTTP.Create(Download.StatusCode);
      end;
    end;

    // Preserve any entry added by another writer during the network requests.
    CheckCancelled;
    XML := LoadGameList(FStorage, Job.XMLFile);
    if FindGameNode(XML.DocumentElement, Job) <> nil then
      Exit;
    var Node := XML.DocumentElement.AddChild('game');
    FillField(Node, 'path', './' + Relative);
    Node.Attributes['source'] := 'ScreenScraper';
    var ID := JSONText(Game, 'id');
    if ID <> '' then
      Node.Attributes['id'] := ID;
    var Title := JSONText(PickEntry(Game, 'noms', 'region', Regions), 'text');
    if Title = '' then
      Title := ChangeFileExt(Job.Name, '');
    FillField(Node, 'name', Title);
    FillField(Node, 'desc', JSONText(PickEntry(Game, 'synopsis', 'langue', Languages), 'text'));
    FillField(Node, 'developer', JSONText(Game, 'developpeur.text'));
    FillField(Node, 'publisher', JSONText(Game, 'editeur.text'));
    FillField(Node, 'players', JSONText(Game, 'joueurs.text'));
    var Date := JSONText(PickEntry(Game, 'dates', 'region', Regions), 'text').Replace('-', '');
    if Length(Date) = 4 then
      Date := Date + '0101'
    else if Length(Date) = 6 then
      Date := Date + '01';
    if Length(Date) = 8 then
      FillField(Node, 'releasedate', Date + 'T000000');
    var Score := JSONText(Game, 'note.text');
    if Score <> '' then
      FillField(Node, 'rating', FloatToStr(EnsureRange(StrToFloatDef(Score, 0, TFormatSettings.Invariant) / 20, 0.0, 1.0), TFormatSettings.Invariant));
    var Genres := JSONValue(Game, 'genres');
    if Genres is TJSONArray then
    begin
      var Genre := '';
      for var Entry in TJSONArray(Genres) do
      begin
        var Name := JSONText(PickEntry(Entry, 'noms', 'langue', Languages), 'text');
        if Name <> '' then
        begin
          if Genre <> '' then
            Genre := Genre + ', ';
          Genre := Genre + Name;
        end;
      end;
      FillField(Node, 'genre', Genre);
    end;
    FillField(Node, 'thumbnail', Cover);
    var Output := TMemoryStream.Create;
    try
      XML.SaveToStream(Output);
      CheckCancelled;
      if Cover <> '' then
        FStorage.WriteAtomic(ScraperNativePath(Job.Folder, Cover), Data);
      FStorage.WriteAtomic(Job.XMLFile, Output);
    finally
      Output.Free;
    end;
    Result.Found := True;
    Result.Title := NodeText(Node, 'name');
    Result.Description := NodeText(Node, 'desc');
    Result.Developer := NodeText(Node, 'developer');
    Result.Genre := NodeText(Node, 'genre');
    Result.Players := NodeText(Node, 'players');
    Result.Image := ScraperNativePath(Job.Folder, NodeText(Node, 'image'));
    Result.Thumbnail := ScraperNativePath(Job.Folder, NodeText(Node, 'thumbnail'));
    if (Result.Thumbnail <> '') and not FStorage.Exists(Result.Thumbnail) then
      Result.Thumbnail := '';
    Result.Box := ScraperNativePath(Job.Folder, NodeText(Node, 'box'));
    if (Result.Box <> '') and not FStorage.Exists(Result.Box) then
      Result.Box := '';
  finally
    Data.Free;
    Response.Free;
  end;
end;

procedure TScreenScraperWorker.Execute;
begin
  try
    var AppID, AppPassword: string;
    ReadApplicationCredentials(AppID, AppPassword);
    if (AppID = '') or (AppPassword = '') then
    begin
      FStatus.Error := 'ScreenScraper developer credentials are missing.';
      PublishStatus;
      Exit;
    end;
    if not FOptions.Anonymous and ((FOptions.UserName = '') or (FOptions.Password = '')) then
    begin
      FStatus.Error := 'Enter your ScreenScraper username and password.';
      PublishStatus;
      Exit;
    end;
    FAuth := '&devid=' + Encode(AppID) + '&devpassword=' + Encode(AppPassword) + '&softname=RetroMul';
    if not FOptions.Anonymous then
      FAuth := FAuth + '&ssid=' + Encode(FOptions.UserName) + '&sspassword=' + Encode(FOptions.Password);
    FHTTP := THTTPClient.Create;
    try
      FHTTP.HandleRedirects := False;
      FHTTP.ConnectionTimeout := 8000;
      FHTTP.ResponseTimeout := 12000;
      FHTTP.OnReceiveData := ReceiveData;
      // ScreenScraper can reject anonymous user-info requests while allowing
      // game lookups. Anonymous scraping obtains quota from the game response.
      var QuotaOnly := Length(FJobs) = 0;
      if not FOptions.Anonymous or QuotaOnly then
      begin
        var AccountParams := '';
        if FOptions.Anonymous then
          AccountParams := '&ssid=&sspassword=';
        if QuotaOnly then
          FStatus := TScraperStatus.Empty;
        var Account := Request('ssuserInfos.php', AccountParams);
        Account.Free;
        if QuotaOnly and (FStatus.Limit < 0) and (FStatus.FailedLimit < 0) then
        begin
          FStatus.Error := 'ScreenScraper did not report the daily quota.';
          PublishStatus;
        end;
      end;
      for var Job in FJobs do
      begin
        if (FStatus.Remaining = 0) or (FStatus.FailedRemaining = 0) then
          Break;
        var Update := Scrape(Job);
        TMonitor.Enter(FUpdates);
        try
          FUpdates.Add(Update);
        finally
          TMonitor.Exit(FUpdates);
        end;
      end;
      if (FStatus.Remaining = 0) or (FStatus.FailedRemaining = 0) then
        FRetryAfter := 60 * 60 * 1000;
    finally
      FHTTP.Free;
    end;
  except
    on E: EAbort do
      Exit;
    on E: Exception do
    begin
      if Terminated then
        Exit;
      // Network exceptions may include the request URI and its credentials.
      FRetryAfter := 5 * 60 * 1000;
      FStatus.Error := 'ScreenScraper or the ROM folder is unavailable.';
      if E is EScraperHTTP then
      begin
        var Code := EScraperHTTP(E).Code;
        FStatus.Error := E.Message;
        FStatus.HTTPStatusCode := Code;
        case Code of
          401, 403, 426:
            FRetryAfter := 0;
          430, 431:
            begin
              if Code = 430 then
                FStatus.Remaining := 0
              else
                FStatus.FailedRemaining := 0;
              FRetryAfter := 60 * 60 * 1000;
            end;
        end;
      end;
      PublishStatus;
    end;
  end;
end;

initialization
  LoadLocalApplicationCredentials;
  StatusLock := TObject.Create;

finalization
  if QuotaWorker <> nil then
    QuotaWorker.Terminate;
  QuotaWorker.Free;
  StatusLock.Free;

end.

