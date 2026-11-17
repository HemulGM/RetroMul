unit RM.Settings.Session;

interface

uses
  System.SysUtils, System.IniFiles, System.Generics.Collections, Core.Storage;

type
  // Drafts are keyed by page ID; configuration paths still use SettingsId.
  // The session owns every whole INI and preserves keys not exposed by editors.
  TSettingsSession = class
  private
    FStorage: IStorage;
    FGameRomName, FGameSettingsId: string;
    FDrafts: TObjectDictionary<string, TMemIniFile>;
    FPageOrder: TList<string>;
    function IsGameDraft(Draft: TMemIniFile): Boolean;
    function GetDraft(const PageId: string): TMemIniFile;
  public
    constructor Create(const Storage: IStorage; const GameRomName: string = ''; const GameSettingsId: string = '');
    destructor Destroy; override;
    procedure Open(const PageId, SettingsId: string);
    function HasGameSettings: Boolean;
    procedure ResetGameSettings;
    procedure Save(OnlyForGame: Boolean = False);
    property Drafts[const PageId: string]: TMemIniFile read GetDraft;
  end;

implementation

uses
  System.Generics.Defaults, System.Classes, System.IOUtils, Core.InputConfig;

constructor TSettingsSession.Create(const Storage: IStorage; const GameRomName, GameSettingsId: string);
begin
  inherited Create;
  FStorage := Storage;
  FGameRomName := GameRomName;
  FGameSettingsId := GameSettingsId;
  FDrafts := TObjectDictionary<string, TMemIniFile>.Create([doOwnsValues], TIStringComparer.Ordinal);
  FPageOrder := TList<string>.Create;
end;

destructor TSettingsSession.Destroy;
begin
  FPageOrder.Free;
  FDrafts.Free;
  inherited;
end;

procedure TSettingsSession.Open(const PageId, SettingsId: string);
begin
  var Key := PageId.Trim.ToLower;
  if (Key = '') or (SettingsId = '') or FDrafts.ContainsKey(Key) then
    raise EArgumentException.Create('Invalid or duplicate settings session page: ' + PageId);
  var Path := FStorage.ConfigFile(SettingsId);
  if HasGameSettings and SameText(TPath.GetFileName(Path), TPath.GetFileName(FStorage.ConfigFile(FGameSettingsId))) then
    Path := GameConfigFile(FStorage, SettingsId, FGameRomName);
  var Draft := FStorage.ReadConfig(Path);
  try
    var Legacy: TMemIniFile;
    if FDrafts.TryGetValue('main', Legacy) then
      MigrateAnalogControlSettings(Draft, Legacy);
    FDrafts.Add(Key, Draft);
  except
    Draft.Free;
    raise;
  end;
  FPageOrder.Add(Key);
end;

function TSettingsSession.GetDraft(const PageId: string): TMemIniFile;
begin
  if not FDrafts.TryGetValue(PageId.Trim, Result) then
    raise EArgumentException.Create('Settings session page is not open: ' + PageId);
end;

function TSettingsSession.HasGameSettings: Boolean;
begin
  Result := (FGameRomName <> '') and (FGameSettingsId <> '') and
    FStorage.Exists(GameConfigFile(FStorage, FGameSettingsId, FGameRomName));
end;

function TSettingsSession.IsGameDraft(Draft: TMemIniFile): Boolean;
begin
  Result := (FGameRomName <> '') and (FGameSettingsId <> '') and
    SameText(TPath.GetFileName(Draft.FileName), TPath.GetFileName(FStorage.ConfigFile(FGameSettingsId)));
end;

procedure TSettingsSession.ResetGameSettings;
begin
  if not HasGameSettings then
    Exit;
  // Read the shared configuration before deleting the game file.
  var Shared := FStorage.ReadConfig(FStorage.ConfigFile(FGameSettingsId));
  var Lines := TStringList.Create;
  try
    Shared.GetStrings(Lines);
    FStorage.Delete(GameConfigFile(FStorage, FGameSettingsId, FGameRomName));
    for var Draft in FDrafts.Values do
      if IsGameDraft(Draft) then
      begin
        Draft.Clear;
        Draft.SetStrings(Lines);
        Draft.Rename(Shared.FileName, False);
      end;
  finally
    Lines.Free;
    Shared.Free;
  end;
end;

procedure TSettingsSession.Save(OnlyForGame: Boolean);
begin
  // Validate all pages before calling Save. Keep writes in declaration order,
  // independent of dictionary iteration order; the view opens main first.
  var GameOnly := OnlyForGame or HasGameSettings;
  for var PageId in FPageOrder do
  begin
    var Draft := FDrafts[PageId];
    if GameOnly and IsGameDraft(Draft) then
      Draft.Rename(GameConfigFile(FStorage, FGameSettingsId, FGameRomName), False);
    FStorage.WriteConfig(Draft);
  end;
end;

end.

