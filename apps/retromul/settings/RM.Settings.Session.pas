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
    FDrafts: TObjectDictionary<string, TMemIniFile>;
    FPageOrder: TList<string>;
    function GetDraft(const PageId: string): TMemIniFile;
  public
    constructor Create(const Storage: IStorage);
    destructor Destroy; override;
    procedure Open(const PageId, SettingsId: string);
    procedure Save;
    property Drafts[const PageId: string]: TMemIniFile read GetDraft;
  end;

implementation

uses System.Generics.Defaults;

constructor TSettingsSession.Create(const Storage: IStorage);
begin
  inherited Create;
  FStorage := Storage;
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
  var Draft := FStorage.ReadConfig(FStorage.ConfigFile(SettingsId));
  try
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

procedure TSettingsSession.Save;
begin
  // Validate all pages before calling Save. Keep writes in declaration order,
  // independent of dictionary iteration order; the view opens main first.
  for var PageId in FPageOrder do FStorage.WriteConfig(FDrafts[PageId]);
end;

end.
