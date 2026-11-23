unit Core.SavePaths;

interface

uses
  Core.Storage;

// An empty extension selects a snapshot directory; '.sav' selects a battery file.
// Existing paths are reused by hash alone, including legacy hash-only names.

const
  SNAPSHOT_EXTENSION = '.snapshot';
  SNAPSHOT_AUTOSAVE = 'autosave';

procedure ValidateSnapshotName(const Name: string);

function ResolveSnapshotPath(const Directory, Name: string): string;

function GetDocumentsDirectory: string;

function ResolveDocumentsDirectory(const DocumentsPath, HomePath: string): string;

function GetSaveDirectory: string;

function GetSnapshotDirectory: string;

function ResolveGameSavePath(const Root, RomFileName, Hash, Extension: string): string;

// Resolve a previously recorded game without opening its ROM or constructing a core.
function FindRecordedAutosave(const Storage: IStorage; const RomLocation: string): string;

procedure RecordGameSnapshotDirectory(const Storage: IStorage; const RomLocation, Directory: string);

function SnapshotDirectoryHasFiles(const Storage: IStorage; const Directory: string): Boolean;

implementation

uses
  System.SysUtils, System.IOUtils, System.StrUtils, System.Hash,
  Core.CD.Physical;

function SessionKey(const RomLocation: string): string;
begin
  var Location := RomLocation;
  if IsOpticalCDLocation(Location) then
    Exit(THashSHA2.GetHashString(Location.ToLower));
  if not Location.StartsWith('content://', True) then
  begin
    Location := ExpandFileName(Location);
    {$IFDEF MSWINDOWS}
    Location := LowerCase(Location);
    {$ENDIF}
  end;
  Result := THashSHA2.GetHashString(Location);
end;

function FindRecordedAutosave(const Storage: IStorage; const RomLocation: string): string;
begin
  Result := '';
  var Ini := Storage.ReadConfig(Storage.ConfigFile('sessions'));
  var Directory: string;
  var Recorded: Boolean;
  try
    Recorded := Ini.ValueExists('Snapshots', SessionKey(RomLocation));
    Directory := Ini.ReadString('Snapshots', SessionKey(RomLocation), '');
  finally
    Ini.Free;
  end;
  if not Recorded then
  begin
    // Existing libraries recorded this association before the session index.
    Ini := Storage.ReadConfig(Storage.ConfigFile('library'));
    try
      Directory := Ini.ReadString('Snapshots', THashSHA2.GetHashString(RomLocation), '');
    finally
      Ini.Free;
    end;
  end;
  if Directory = '' then
    Exit;
  var Path := ResolveSnapshotPath(Directory, SNAPSHOT_AUTOSAVE);
  if Storage.Exists(Path) then
    Result := Path;
end;

procedure RecordGameSnapshotDirectory(const Storage: IStorage; const RomLocation, Directory: string);
begin
  if RomLocation = '' then
    Exit;
  var Ini := Storage.ReadConfig(Storage.ConfigFile('sessions'));
  try
    var Key := SessionKey(RomLocation);
    if SnapshotDirectoryHasFiles(Storage, Directory) then
    begin
      if Ini.ReadString('Snapshots', Key, '') = Directory then
        Exit;
      Ini.WriteString('Snapshots', Key, Directory);
    end
    else
    begin
      if not Ini.ValueExists('Snapshots', Key) then
        Exit;
      Ini.DeleteKey('Snapshots', Key);
    end;
    Storage.WriteConfig(Ini);
  finally
    Ini.Free;
  end;
end;

function SnapshotDirectoryHasFiles(const Storage: IStorage; const Directory: string): Boolean;
begin
  Result := False;
  if (Directory = '') or not Storage.FolderExists(Directory) then
    Exit;
  for var FileName in Storage.Files(Directory) do
    if SameText(ExtractFileExt(FileName), SNAPSHOT_EXTENSION) and Storage.Exists(FileName) then
      Exit(True);
end;

procedure ValidateSnapshotName(const Name: string);
begin
  // File dialogs supply absolute paths; portable slot names stay in the game folder.
  if TPath.IsPathRooted(Name) then
  begin
    if not SameText(ExtractFileExt(Name), SNAPSHOT_EXTENSION) or not SameText(TPath.GetFullPath(Name), Name) then
      raise EArgumentException.Create('Invalid snapshot file path');

    Exit;
  end;

  if (Name = '') or (Length(Name) > 80) then
    raise EArgumentException.Create('Invalid snapshot name');

  for var C in Name do
    if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      raise EArgumentException.Create('Snapshot names use letters, digits, - and _');
end;

function ResolveSnapshotPath(const Directory, Name: string): string;
begin
  ValidateSnapshotName(Name);
  if TPath.IsPathRooted(Name) then
    Result := Name
  else
    Result := TPath.Combine(Directory, Name + SNAPSHOT_EXTENSION);
end;

function GetDocumentsDirectory: string;
begin
  Result := TStorage.Default.Root;
end;

function ResolveDocumentsDirectory(const DocumentsPath, HomePath: string): string;
begin
  // Linux may have no XDG Documents entry. Never turn that into a path
  // relative to the executable: It can then collide with the binary.
  var Root := DocumentsPath;
  if (Root = '') or not TPath.IsPathRooted(Root) then
    Root := HomePath;

  if (Root = '') or not TPath.IsPathRooted(Root) then
    raise EInOutError.Create('Cannot determine an absolute save directory');

  Result := TPath.Combine(Root, 'RetroMul');
end;

function GetSnapshotDirectory: string;
begin
  Result := TStorage.Default.SnapshotRoot;
end;

function GetSaveDirectory: string;
begin
  Result := TStorage.Default.SaveRoot;
end;

function ResolveGameSavePath(const Root, RomFileName, Hash, Extension: string): string;
begin
  Result := TStorage.Default.GamePath(Root, RomFileName, Hash, Extension);
end;

end.

