unit Core.PlatformServices;

interface

uses
  System.SysUtils, Core.Emulation.Types, Core.Storage;

type
  TLibraryFeature = (Playlists, CueTracks, GdiTracks);

  TLibraryFeatures = set of TLibraryFeature;

  TTerminalInputPolicy = record
    AllKeys: Boolean;
    ExitKey: Word;
  end;

  TTerminalInputProvider = reference to function(const Core: IEmulationCore): TTerminalInputPolicy;

  TPrepareArcadeAchievements = reference to procedure(const Storage: IStorage; const Location: string; out Companions: TArray<string>; out ResolveSet: TFunc<string>);

  TPlatformDocumentSelection = record
    Title, FileFilter: string;
    AllowedExtensions: TArray<string>;
    function Accepts(const FileName: string): Boolean;
  end;

  TPlatformServices = record
    LibraryFeatures: TLibraryFeatures;
    CompanionArchives, FirmwareFiles: TArray<string>;
    UnprefixedSaveIdentity: Boolean;
    TerminalInput: TTerminalInputProvider;
    AchievementMedia: IEmulationAchievementMedia;
    PrepareArcadeAchievements: TPrepareArcadeAchievements;
    DocumentSelection: TPlatformDocumentSelection;
  end;

procedure RegisterPlatformServices(const Id: string; const Services: TPlatformServices);

function PlatformServices(const Id: string): TPlatformServices;

function PlatformAchievementMedia(const Id: string): IEmulationAchievementMedia;

procedure RegisterPlatformAchievementMedia(const Id: string; ConsoleId: Cardinal; const Extensions: array of string; IsDisc: Boolean = False; const PrepareArcade: TPrepareArcadeAchievements = nil);

function PlatformDocumentSelection(const Id: string): TPlatformDocumentSelection;

function TerminalInputPolicy(const Core: IEmulationCore): TTerminalInputPolicy;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, System.StrUtils,
  System.Classes, Core.Platforms;

type
  TRegisteredAchievementMedia = class(TInterfacedObject, IEmulationAchievementMedia)
  private
    FConsoleId: Cardinal;
    FIsDisc: Boolean;
    FExtensions: TArray<string>;
  public
    constructor Create(ConsoleId: Cardinal; const Extensions: array of string; IsDisc: Boolean);
    function GetConsoleId: Cardinal;
    function IsDisc: Boolean;
    function AcceptsROM(const SourceName: string; Input: TStream): Boolean;
  end;

constructor TRegisteredAchievementMedia.Create(ConsoleId: Cardinal; const Extensions: array of string; IsDisc: Boolean);
begin
  inherited Create;
  FConsoleId := ConsoleId;
  FIsDisc := IsDisc;
  SetLength(FExtensions, Length(Extensions));
  for var Index := 0 to High(Extensions) do
    FExtensions[Index] := Extensions[Index];
end;

function TRegisteredAchievementMedia.GetConsoleId: Cardinal;
begin
  Result := FConsoleId;
end;

function TRegisteredAchievementMedia.IsDisc: Boolean;
begin
  Result := FIsDisc;
end;

function TRegisteredAchievementMedia.AcceptsROM(const SourceName: string; Input: TStream): Boolean;
begin
  Result := (Input.Size > 0) and MatchText(ExtractFileExt(SourceName), FExtensions);
end;

var
  Services: TDictionary<string, TPlatformServices>;

procedure RegisterPlatformServices(const Id: string; const Services: TPlatformServices);
begin
  if Id.Trim = '' then
    raise EArgumentException.Create('Empty platform service ID');
  var Value := Services;
  Value.DocumentSelection.AllowedExtensions := Copy(Value.DocumentSelection.AllowedExtensions);
  Value.CompanionArchives := Copy(Value.CompanionArchives);
  Value.FirmwareFiles := Copy(Value.FirmwareFiles);
  Core.PlatformServices.Services.Add(Id.Trim, Value);
end;

function PlatformServices(const Id: string): TPlatformServices;
begin
  if not Services.TryGetValue(TPlatformRegistry.CanonicalId(Id), Result) then
    Result := Default(TPlatformServices);
  Result.DocumentSelection.AllowedExtensions := Copy(Result.DocumentSelection.AllowedExtensions);
  Result.CompanionArchives := Copy(Result.CompanionArchives);
  Result.FirmwareFiles := Copy(Result.FirmwareFiles);
end;

function PlatformAchievementMedia(const Id: string): IEmulationAchievementMedia;
begin
  var Service: TPlatformServices;
  if not Services.TryGetValue(TPlatformRegistry.CanonicalId(Id), Service) then
    Exit(nil);
  Result := Service.AchievementMedia;
end;

procedure RegisterPlatformAchievementMedia(const Id: string; ConsoleId: Cardinal; const Extensions: array of string; IsDisc: Boolean; const PrepareArcade: TPrepareArcadeAchievements);
begin
  var Key := TPlatformRegistry.CanonicalId(Id);
  var Value := PlatformServices(Key);
  Value.AchievementMedia := TRegisteredAchievementMedia.Create(ConsoleId, Extensions, IsDisc);
  Value.PrepareArcadeAchievements := PrepareArcade;
  Services.AddOrSetValue(Key, Value);
end;

function TPlatformDocumentSelection.Accepts(const FileName: string): Boolean;
begin
  Result := (Length(AllowedExtensions) = 0) or MatchText(ExtractFileExt(FileName), AllowedExtensions);
end;

function PlatformDocumentSelection(const Id: string): TPlatformDocumentSelection;
begin
  Result := PlatformServices(Id).DocumentSelection;
  if Result.Title = '' then
    Result.Title := 'Choose file';
  if Result.FileFilter = '' then
    Result.FileFilter := 'All files|*.*';
end;

function TerminalInputPolicy(const Core: IEmulationCore): TTerminalInputPolicy;
begin
  Result := Default(TTerminalInputPolicy);
  Result.ExitKey := $1B;
  if Core = nil then
    Exit;
  var Service := PlatformServices(Core.SystemId);
  if Assigned(Service.TerminalInput) then
    Result := Service.TerminalInput(Core);
end;

initialization
  Services := TDictionary<string, TPlatformServices>.Create(TIStringComparer.Ordinal);

finalization
  Services.Free;

end.

