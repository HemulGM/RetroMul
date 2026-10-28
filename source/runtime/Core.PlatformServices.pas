unit Core.PlatformServices;

interface

uses System.SysUtils, Core.Emulation.Types;

type
  TLibraryFeature = (Playlists, CueTracks, GdiTracks);
  TLibraryFeatures = set of TLibraryFeature;
  TTerminalInputPolicy = record
    AllKeys: Boolean;
    ExitKey: Word;
  end;
  TTerminalInputProvider = reference to function(const Core: IEmulationCore): TTerminalInputPolicy;
  TPlatformDocumentSelection = record
    Title, FileFilter: string;
    AllowedExtensions: TArray<string>;
    function Accepts(const FileName: string): Boolean;
  end;
  TPlatformServices = record
    LibraryFeatures: TLibraryFeatures;
    UnprefixedSaveIdentity: Boolean;
    BackgroundExtensions: TArray<string>;
    TerminalInput: TTerminalInputProvider;
    DocumentSelection: TPlatformDocumentSelection;
  end;

procedure RegisterPlatformServices(const Id: string; const Services: TPlatformServices);
function PlatformServices(const Id: string): TPlatformServices;
function LoadMediaInBackground(const FileName: string): Boolean;
function PlatformDocumentSelection(const Id: string): TPlatformDocumentSelection;
function TerminalInputPolicy(const Core: IEmulationCore): TTerminalInputPolicy;

implementation

uses System.Generics.Collections, System.Generics.Defaults, System.StrUtils, Core.Platforms;

var Services: TDictionary<string, TPlatformServices>;

procedure RegisterPlatformServices(const Id: string; const Services: TPlatformServices);
begin
  if Id.Trim = '' then raise EArgumentException.Create('Empty platform service ID');
  var Value := Services;
  Value.BackgroundExtensions := Copy(Value.BackgroundExtensions);
  Value.DocumentSelection.AllowedExtensions := Copy(Value.DocumentSelection.AllowedExtensions);
  Core.PlatformServices.Services.Add(Id.Trim, Value);
end;

function PlatformServices(const Id: string): TPlatformServices;
begin
  if not Services.TryGetValue(TPlatformRegistry.CanonicalId(Id), Result) then Result := Default(TPlatformServices);
  Result.BackgroundExtensions := Copy(Result.BackgroundExtensions);
  Result.DocumentSelection.AllowedExtensions := Copy(Result.DocumentSelection.AllowedExtensions);
end;

function LoadMediaInBackground(const FileName: string): Boolean;
begin
  Result := False;
  for var Service in Services.Values do
    if MatchText(ExtractFileExt(FileName), Service.BackgroundExtensions) then Exit(True);
end;

function TPlatformDocumentSelection.Accepts(const FileName: string): Boolean;
begin
  Result := (Length(AllowedExtensions) = 0) or MatchText(ExtractFileExt(FileName), AllowedExtensions);
end;

function PlatformDocumentSelection(const Id: string): TPlatformDocumentSelection;
begin
  Result := PlatformServices(Id).DocumentSelection;
  if Result.Title = '' then Result.Title := 'Choose file';
  if Result.FileFilter = '' then Result.FileFilter := 'All files|*.*';
end;

function TerminalInputPolicy(const Core: IEmulationCore): TTerminalInputPolicy;
begin
  Result := Default(TTerminalInputPolicy);
  Result.ExitKey := $1B;
  if Core = nil then Exit;
  var Service := PlatformServices(Core.SystemId);
  if Assigned(Service.TerminalInput) then Result := Service.TerminalInput(Core);
end;

initialization
  Services := TDictionary<string, TPlatformServices>.Create(TIStringComparer.Ordinal);
finalization
  Services.Free;
end.
