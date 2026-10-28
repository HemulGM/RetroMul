unit RM.Settings.platform;

interface

uses
  Core.Emulation.Types,
  RM.Platforms.Presentation, System.Classes, System.SysUtils, System.IniFiles,
  System.Generics.Collections, RM.Gamepad, Core.Platforms, RM.Settings.Builder;

const
  SETTINGS_CATEGORY_GENERAL = 0;
  SETTINGS_CATEGORY_LIBRARY = 1;
  SETTINGS_CATEGORY_VIDEO_AUDIO = 2;
  SETTINGS_CATEGORY_CONTROLS = 3;
  SETTINGS_CATEGORY_PERIPHERALS = 4;

type
  TSettingsPortOptions = record
    RowName, Caption, Description, Default: string;
    Labels, Values: TArray<string>;
    SingleLineDescription: Boolean;
  end;

  TSettingsPlatform = class
  public
    PageId: string;
    CoreId, Name, Brand, SearchTerms: string;
    Ports: Integer;
    constructor Create(const Info: TPlatformInfo);
    procedure Configuration(Context: TSettingsPageBuilder); virtual;
    procedure Video(Context: TSettingsPageBuilder); virtual;
    procedure Audio(Context: TSettingsPageBuilder); virtual;
    procedure Peripherals(Context: TSettingsPageBuilder); virtual;
    procedure Expansion(Context: TSettingsPageBuilder); virtual;
    procedure PrepareSave(Draft: TMemIniFile); virtual;
    procedure Validate(Draft: TMemIniFile); virtual;
    function HasConfiguration: Boolean; virtual;
    function ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean; virtual;
    function ConfigurationNotice(Draft: TMemIniFile): string; virtual;
    function PlayerCount(Draft: TMemIniFile): Integer; virtual;
    function PortOptions(Port: Integer): TSettingsPortOptions; virtual;
  end;

  TSettingsPlatformClass = class of TSettingsPlatform;

  TSettingsPlatformRegistry = class
  private
    FItems: TObjectList<TSettingsPlatform>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(SettingsPlatform: TSettingsPlatform);
    function Find(const PageId: string): TSettingsPlatform;
    function Require(const PageId: string): TSettingsPlatform;
    function Matching(const Query: string): TArray<TSettingsPlatform>;
    property Items: TObjectList<TSettingsPlatform> read FItems;
  end;

implementation

uses
  FMX.Types, System.Types, System.Generics.Defaults, RM.Icons;

constructor TSettingsPlatform.Create(const Info: TPlatformInfo);
begin
  inherited Create;
  var Presentation := PlatformPresentation(Info.Id);
  PageId := Presentation.SettingsPageId;
  CoreId := Info.SettingsCoreId;
  Name := Info.Name;
  Brand := Info.Manufacturer;
  SearchTerms := Info.SearchTerms;
  Ports := Info.Ports;
end;

procedure TSettingsPlatform.Configuration(Context: TSettingsPageBuilder);
begin
end;

procedure TSettingsPlatform.Video(Context: TSettingsPageBuilder);
begin
end;

procedure TSettingsPlatform.Audio(Context: TSettingsPageBuilder);
begin
end;

procedure TSettingsPlatform.Peripherals(Context: TSettingsPageBuilder);
begin
end;

procedure TSettingsPlatform.Expansion(Context: TSettingsPageBuilder);
begin
end;

procedure TSettingsPlatform.PrepareSave(Draft: TMemIniFile);
begin
end;

procedure TSettingsPlatform.Validate(Draft: TMemIniFile);
begin
end;

function TSettingsPlatform.HasConfiguration: Boolean;
begin
  Result := False;
end;

function TSettingsPlatform.ChangeConfiguration(Draft: TMemIniFile; const Section, Key: string): Boolean;
begin
  Result := False;
end;

function TSettingsPlatform.ConfigurationNotice(Draft: TMemIniFile): string;
begin
  Result := '';
end;

function TSettingsPlatform.PlayerCount(Draft: TMemIniFile): Integer;
begin
  Result := Ports;
end;

function TSettingsPlatform.PortOptions(Port: Integer): TSettingsPortOptions;
begin
  Result.SingleLineDescription := False;
  Result.RowName := 'RowConnecteddevice26Port' + IntToStr(Port + 1);
  if Ports = 1 then
    Result.RowName := 'RowControllerPort' + IntToStr(Port + 1);
  if Ports = 1 then
  begin
    Result.Caption := 'Controller';
    Result.Description := 'Use the console''s built-in buttons.';
  end
  else
  begin
    Result.Caption := 'Connected device';
    Result.Description := 'Controller connected to this port.';
  end;
  Result.Labels := ['Gamepad', 'None'];
  Result.Values := ['pad', 'none'];
  Result.Default := 'pad';
end;

constructor TSettingsPlatformRegistry.Create;
begin
  inherited;
  FItems := TObjectList<TSettingsPlatform>.Create;
end;

destructor TSettingsPlatformRegistry.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TSettingsPlatformRegistry.Add(SettingsPlatform: TSettingsPlatform);
begin
  try
    SettingsPlatform.PageId := SettingsPlatform.PageId.Trim.ToLower;
    if ((SettingsPlatform.PageId = '') or (SettingsPlatform.PageId = 'main')) or (SettingsPlatform.CoreId = '') or (SettingsPlatform.Brand = '') or
      (SettingsPlatform.Ports < 1) or (SettingsPlatform.Ports > EmulatorMaxPlayers) or (Find(SettingsPlatform.PageId) <> nil) then
      raise EArgumentException.Create('Invalid or duplicate settings platform: ' + SettingsPlatform.Name);

    for var Item in FItems do
      if SameText(Item.CoreId, SettingsPlatform.CoreId) then
        raise EArgumentException.Create('Duplicate settings core: ' + SettingsPlatform.CoreId);

    FItems.Add(SettingsPlatform);
  except
    SettingsPlatform.Free;
    raise;
  end;
end;

function TSettingsPlatformRegistry.Find(const PageId: string): TSettingsPlatform;
begin
  Result := nil;
  for var Item in FItems do
    if SameText(Item.PageId, PageId.Trim) then
      Exit(Item);
end;

function TSettingsPlatformRegistry.Require(const PageId: string): TSettingsPlatform;
begin
  Result := Find(PageId);
  if Result = nil then raise EArgumentException.Create('Unknown settings page: ' + PageId);
end;

function TSettingsPlatformRegistry.Matching(const Query: string): TArray<TSettingsPlatform>;
begin
  var Matches := TList<TSettingsPlatform>.Create;
  try
    var Search := Query.Trim.ToLower;
    for var Item in FItems do
      if (Search = '') or (Translate(Item.Name) + ' ' + Item.Name + ' ' + Item.Brand + ' ' + Item.CoreId + ' ' +
        Item.SearchTerms).ToLower.Contains(Search) then
        Matches.Add(Item);
    Matches.Sort(TComparer<TSettingsPlatform>.Construct(
      function(const A, B: TSettingsPlatform): Integer
      begin
        Result := CompareText(A.Brand, B.Brand);
        if Result = 0 then
          Result := CompareText(A.Name, B.Name);
      end));
    Result := Matches.ToArray;
  finally
    Matches.Free;
  end;
end;

end.
