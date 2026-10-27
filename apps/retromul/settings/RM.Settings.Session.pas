unit RM.Settings.Session;

interface

uses
  System.SysUtils, System.IniFiles, Core.Storage;

type
  // The session owns drafts, independently of the lifetime of page controls.
  // An INI is loaded whole, so keys not exposed by an editor are preserved.
  TSettingsSession = class
  private
    FStorage: IStorage;
    FDrafts: TArray<TMemIniFile>;
  public
    constructor Create(const Storage: IStorage; PageCount: Integer);
    destructor Destroy; override;
    procedure Open(Page: Integer; const SettingsId: string);
    procedure Save;
    property Drafts: TArray<TMemIniFile> read FDrafts;
  end;

implementation

constructor TSettingsSession.Create(const Storage: IStorage; PageCount: Integer);
begin
  inherited Create;
  FStorage := Storage;
  SetLength(FDrafts, PageCount);
end;

destructor TSettingsSession.Destroy;
begin
  for var Draft in FDrafts do
    Draft.Free;
  inherited;
end;

procedure TSettingsSession.Open(Page: Integer; const SettingsId: string);
begin
  if (Page < 0) or (Page >= Length(FDrafts)) or (FDrafts[Page] <> nil) then
    raise EArgumentException.Create('Invalid or duplicate settings session page');
  FDrafts[Page] := FStorage.ReadConfig(FStorage.ConfigFile(SettingsId));
end;

procedure TSettingsSession.Save;
begin
  // The caller validates every platform before starting any writes.
  for var Draft in FDrafts do
    if Draft <> nil then
      FStorage.WriteConfig(Draft);
end;

end.

