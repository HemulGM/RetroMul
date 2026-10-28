unit Core.ArchiveStorage;

interface

uses
  System.Classes, System.SysUtils, System.IniFiles, Core.Storage;
function ArchiveStorage(const Base: IStorage; const Location, Name: string; const Data: TBytes): IStorage;
implementation
type
  // For decoded archives only. All paths, configuration and save identities
  // remain attached to the original storage and original archive location.
  TArchiveStorage = class(TInterfacedObject, IStorage)
  private
    FBase: IStorage;
    FLocation, FName: string;
    FData: TBytes;
  public
    function GetRoot: string;
    function RomFolder(const SystemId: string): string;
    procedure SetRomFolder(const SystemId, Value: string);
    function DetectRomFolder(const Location, SystemId: string): string;
    function GetCheckRomFileSize: Boolean;
    procedure SetCheckRomFileSize(Value: Boolean);
    function GetMaxRomFileSize: Int64;
    procedure SetMaxRomFileSize(Value: Int64);
    function OpenRead(const Location: string): TStream;
    function OpenWrite(const Location: string): TStream;
    function Exists(const Location: string): Boolean;
    function ModifiedTime(const Location: string): TDateTime;
    function FolderExists(const Location: string): Boolean;
    procedure EnsureFolder(const Location: string);
    function Files(const Location: string; Recursive: Boolean = False): TArray<string>;
    function Folders(const Location: string): TArray<string>;
    procedure Delete(const Location: string);
    procedure Replace(const Source, Target: string);
    procedure WriteAtomic(const Location: string; Stream: TStream);
    function ReadBytes(const Location: string): TBytes;
    procedure WriteBytes(const Location: string; const Data: TBytes);
    function ReadText(const Location: string): string;
    function ConfigFile(const SystemId: string): string;
    function ReadConfig(const Location: string): TMemIniFile;
    procedure WriteConfig(Ini: TMemIniFile);
    function SaveRoot: string;
    function SnapshotRoot: string;
    function ScreenshotFile(const RomName: string): string;
    function TemporaryFile(const Extension: string): string;
    function GamePath(const Root, RomName, Identity, Extension: string): string;
    function GameSave(const SystemId, RomName, Identity: string): string;
    function GameSnapshots(const SystemId, RomName, Identity: string): string;
    function Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
    function Roms(const SystemId: string): TArray<TStorageFile>;
    function Describe(const Location: string): TStorageFile;
    procedure SelectRom(const Callback: TStorageSelectionCallback);
  end;

function ArchiveStorage(const Base: IStorage; const Location, Name: string; const Data: TBytes): IStorage;
begin
  var Value := TArchiveStorage.Create;
  Value.FBase := Base;
  Value.FLocation := Location;
  Value.FName := Name;
  Value.FData := Data;
  Result := Value;
end;

function TArchiveStorage.GetRoot: string;
begin
  Result := FBase.GetRoot;
end;

function TArchiveStorage.RomFolder(const SystemId: string): string;
begin
  Result := FBase.RomFolder(SystemId);
end;

procedure TArchiveStorage.SetRomFolder(const SystemId, Value: string);
begin
  FBase.SetRomFolder(SystemId, Value);
end;

function TArchiveStorage.DetectRomFolder(const Location, SystemId: string): string;
begin
  Result := FBase.DetectRomFolder(Location, SystemId);
end;

function TArchiveStorage.GetCheckRomFileSize: Boolean;
begin
  Result := FBase.GetCheckRomFileSize;
end;

procedure TArchiveStorage.SetCheckRomFileSize(Value: Boolean);
begin
  FBase.SetCheckRomFileSize(Value);
end;

function TArchiveStorage.GetMaxRomFileSize: Int64;
begin
  Result := FBase.GetMaxRomFileSize;
end;

procedure TArchiveStorage.SetMaxRomFileSize(Value: Int64);
begin
  FBase.SetMaxRomFileSize(Value);
end;

function TArchiveStorage.OpenRead(const Location: string): TStream;
begin
  if Location = FLocation then Exit(TBytesStream.Create(FData));
  Result := FBase.OpenRead(Location);
end;

function TArchiveStorage.OpenWrite(const Location: string): TStream;
begin
  Result := FBase.OpenWrite(Location);
end;

function TArchiveStorage.Exists(const Location: string): Boolean;
begin
  Result := FBase.Exists(Location);
end;

function TArchiveStorage.ModifiedTime(const Location: string): TDateTime;
begin
  Result := FBase.ModifiedTime(Location);
end;

function TArchiveStorage.FolderExists(const Location: string): Boolean;
begin
  Result := FBase.FolderExists(Location);
end;

procedure TArchiveStorage.EnsureFolder(const Location: string);
begin
  FBase.EnsureFolder(Location);
end;

function TArchiveStorage.Files(const Location: string; Recursive: Boolean): TArray<string>;
begin
  Result := FBase.Files(Location, Recursive);
end;

function TArchiveStorage.Folders(const Location: string): TArray<string>;
begin
  Result := FBase.Folders(Location);
end;

procedure TArchiveStorage.Delete(const Location: string);
begin
  FBase.Delete(Location);
end;

procedure TArchiveStorage.Replace(const Source, Target: string);
begin
  FBase.Replace(Source, Target);
end;

procedure TArchiveStorage.WriteAtomic(const Location: string; Stream: TStream);
begin
  FBase.WriteAtomic(Location, Stream);
end;

function TArchiveStorage.ReadBytes(const Location: string): TBytes;
begin
  if Location = FLocation then Exit(Copy(FData));
  Result := FBase.ReadBytes(Location);
end;

procedure TArchiveStorage.WriteBytes(const Location: string; const Data: TBytes);
begin
  FBase.WriteBytes(Location, Data);
end;

function TArchiveStorage.ReadText(const Location: string): string;
begin
  Result := FBase.ReadText(Location);
end;

function TArchiveStorage.ConfigFile(const SystemId: string): string;
begin
  Result := FBase.ConfigFile(SystemId);
end;

function TArchiveStorage.ReadConfig(const Location: string): TMemIniFile;
begin
  Result := FBase.ReadConfig(Location);
end;

procedure TArchiveStorage.WriteConfig(Ini: TMemIniFile);
begin
  FBase.WriteConfig(Ini);
end;

function TArchiveStorage.SaveRoot: string;
begin
  Result := FBase.SaveRoot;
end;

function TArchiveStorage.SnapshotRoot: string;
begin
  Result := FBase.SnapshotRoot;
end;

function TArchiveStorage.ScreenshotFile(const RomName: string): string;
begin
  Result := FBase.ScreenshotFile(RomName);
end;

function TArchiveStorage.TemporaryFile(const Extension: string): string;
begin
  Result := FBase.TemporaryFile(Extension);
end;

function TArchiveStorage.GamePath(const Root, RomName, Identity, Extension: string): string;
begin
  Result := FBase.GamePath(Root, RomName, Identity, Extension);
end;

function TArchiveStorage.GameSave(const SystemId, RomName, Identity: string): string;
begin
  Result := FBase.GameSave(SystemId, RomName, Identity);
end;

function TArchiveStorage.GameSnapshots(const SystemId, RomName, Identity: string): string;
begin
  Result := FBase.GameSnapshots(SystemId, RomName, Identity);
end;

function TArchiveStorage.Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
begin
  Result := FBase.Snapshots(SystemId, RomName, Identity);
end;

function TArchiveStorage.Roms(const SystemId: string): TArray<TStorageFile>;
begin
  Result := FBase.Roms(SystemId);
end;

function TArchiveStorage.Describe(const Location: string): TStorageFile;
begin
  Result := FBase.Describe(Location);
  if Location = FLocation then begin Result.Name := FName; Result.Size := Length(FData); end;
end;

procedure TArchiveStorage.SelectRom(const Callback: TStorageSelectionCallback);
begin
  FBase.SelectRom(Callback);
end;

end.
