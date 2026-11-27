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

function FindAutosave(const Storage: IStorage; const Directory: string): string;

function SnapshotDirectoryHasFiles(const Storage: IStorage; const Directory: string): Boolean;

implementation

uses
  System.SysUtils, System.IOUtils;

function FindAutosave(const Storage: IStorage; const Directory: string): string;
begin
  Result := '';
  if Directory = '' then
    Exit;
  var Path := ResolveSnapshotPath(Directory, SNAPSHOT_AUTOSAVE);
  if Storage.Exists(Path) then
    Result := Path;
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

