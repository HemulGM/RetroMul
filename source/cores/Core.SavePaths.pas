unit Core.SavePaths;

interface

// An empty extension selects a snapshot directory; '.sav' selects a battery file.
// Existing paths are reused by hash alone, including legacy hash-only names.

function GetDocumentsDirectory: string;

function GetSaveDirectory: string;

function GetSnapshotDirectory: string;

function ResolveGameSavePath(const Root, RomFileName, Hash, Extension: string): string;

implementation

uses
  System.SysUtils, System.IOUtils, System.StrUtils;

function GetDocumentsDirectory: string;
begin
  // Linux may have no XDG Documents entry. Never turn that into a path
  // relative to the executable: It can then collide with the binary.
  var Root := TPath.GetDocumentsPath;
  if (Root = '') or not TPath.IsPathRooted(Root) then
    Root := TPath.GetHomePath;
  if (Root = '') or not TPath.IsPathRooted(Root) then
    raise EInOutError.Create('Cannot determine an absolute save directory');
  Result := TPath.Combine(Root, 'RetroMul');
end;

function GetSnapshotDirectory: string;
begin
  Result := TPath.Combine(GetDocumentsDirectory, 'snapshots');
end;

function GetSaveDirectory: string;
begin
  Result := TPath.Combine(GetDocumentsDirectory, 'saves');
end;

function ResolveGameSavePath(const Root, RomFileName, Hash, Extension: string): string;
begin
  Result := '';
  if TDirectory.Exists(Root) then
  begin
    var Candidates: TArray<string>;
    if Extension = '' then
      Candidates := TDirectory.GetDirectories(Root)
    else
      Candidates := TDirectory.GetFiles(Root);
    for var Path in Candidates do
    begin
      var Name := ExtractFileName(Path);
      if SameText(Name, Hash + Extension) or EndsText('_' + Hash + Extension, Name) then
      begin
        if Result <> '' then
          raise EInOutError.CreateFmt('Multiple saves for ROM %s in %s', [Hash, Root]);
        Result := Path;
      end;
    end;
  end;
  if Result <> '' then
    Exit;
  var Title := ChangeFileExt(ExtractFileName(RomFileName), '').Trim;
  // Use portable names even when moving saves between Android/Linux and Windows.
  for var i := 1 to Length(Title) do
    if (Ord(Title[i]) < 32) or CharInSet(Title[i], ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Title[i] := '_';
  Title := Copy(Title, 1, 80).Trim;
  if Title = '' then
    Title := 'Game';
  Result := TPath.Combine(Root, Title + '_' + Hash + Extension);
end;

end.

