unit Core.SavePaths;

interface

// An empty extension selects a snapshot directory; '.sav' selects a battery file.
// Existing paths are reused by hash alone, including legacy hash-only names.

function GetDocumentsDirectory: string;

function ResolveDocumentsDirectory(const DocumentsPath, HomePath: string): string;

function GetSaveDirectory: string;

function GetSnapshotDirectory: string;

function ResolveGameSavePath(const Root, RomFileName, Hash, Extension: string): string;

implementation

uses
  Core.Storage, System.SysUtils, System.IOUtils, System.StrUtils;

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

