unit Core.ArchiveStorage;

interface

uses
  System.Classes, System.SysUtils, System.IniFiles, Core.Storage,
  Core.Archive.Container;

// Read-only virtual media paths. Config/save paths stay on the base storage.
function ContainerStorage(const Base: IStorage; const Container: IArchiveContainer; const Root: string): IStorage;

implementation

uses
  System.IOUtils, System.Generics.Collections, System.Generics.Defaults;

type
  // Members are streams; archive names are never extracted as disk paths.
  TArchiveStorage = class(TInterfacedObject, IStorage)
  private
    FBase: IStorage;
    FContainer: IArchiveContainer;
    FMediaRoot: string;
    FMembers: TDictionary<string, Integer>;
    procedure CheckWritable(const Location: string);
    function MediaPath(const Location: string): string;
  public
    destructor Destroy; override;
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

function ContainerStorage(const Base: IStorage; const Container: IArchiveContainer; const Root: string): IStorage;
begin
  if (Base = nil) or (Container = nil) or (Root = '') then
    raise EArgumentException.Create('Container storage needs a base, container and virtual root');
  var Value := TArchiveStorage.Create;
  try
    Value.FBase := Base;
    Value.FContainer := Container;
    Value.FMediaRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(Root));
    Value.FMembers := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
    for var I := 0 to Container.Count - 1 do
    begin
      var Info := Container.Entries[I];
      if Info.IsDirectory then
        Continue;
      var Name := Info.Name.Replace('\', '/');
      if (Name = '') or Name.StartsWith('/') or Name.Contains(':') or Name.Contains(#0) then
        raise EReadError.Create('Invalid container media path: ' + Name);
      for var Part in Name.Split(['/']) do
        if Part = '..' then
          raise EReadError.Create('Invalid container media path: ' + Name);
      var Path := Value.MediaPath(TPath.Combine(Value.FMediaRoot, Name.Replace('/', PathDelim)));
      if Path = '' then
        raise EReadError.Create('Invalid container media path: ' + Name);
      if Value.FMembers.ContainsKey(Path) then
        raise EReadError.Create('Duplicate container media path: ' + Name);
      Value.FMembers.Add(Path, I);
    end;
  except
    Value.Free;
    raise;
  end;
  Result := Value;
end;

destructor TArchiveStorage.Destroy;
begin
  FMembers.Free;
  inherited;
end;

function TArchiveStorage.MediaPath(const Location: string): string;
begin
  Result := '';
  if (Location = '') or Location.Contains(#0) then Exit;
  try
    Result := TPath.GetFullPath(Location.Replace('/', PathDelim));
    if SameText(ExcludeTrailingPathDelimiter(Result), ExcludeTrailingPathDelimiter(FMediaRoot)) then
      Result := FMediaRoot
    else if not Result.StartsWith(FMediaRoot, True) then
      Result := '';
  except
    on E: EArgumentException do Result := '';
  end;
end;

procedure TArchiveStorage.CheckWritable(const Location: string);
begin
  raise EWriteError.Create('Container media storage is read-only: ' + Location);
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
  var Index: Integer;
  if not FMembers.TryGetValue(MediaPath(Location), Index) then
    raise EReadError.Create('Missing container member: ' + Location);
  Result := FContainer.OpenRead(Index);
end;

function TArchiveStorage.OpenWrite(const Location: string): TStream;
begin
  CheckWritable(Location);
  Result := FBase.OpenWrite(Location);
end;

function TArchiveStorage.Exists(const Location: string): Boolean;
begin
  Result := FMembers.ContainsKey(MediaPath(Location));
end;

function TArchiveStorage.ModifiedTime(const Location: string): TDateTime;
begin
  Result := 0;
end;

function TArchiveStorage.FolderExists(const Location: string): Boolean;
begin
  Result := False;
  var Prefix := MediaPath(Location);
  if Prefix = '' then Exit;
  Prefix := IncludeTrailingPathDelimiter(Prefix);
  if SameText(Prefix, FMediaRoot) then Exit(True);
  for var Path in FMembers.Keys do
    if Path.StartsWith(Prefix, True) then
      Exit(True);
end;

procedure TArchiveStorage.EnsureFolder(const Location: string);
begin
  if not FolderExists(Location) then CheckWritable(Location);
end;

function TArchiveStorage.Files(const Location: string; Recursive: Boolean): TArray<string>;
begin
  Result := nil;
  var Prefix := MediaPath(Location);
  if Prefix = '' then Exit;
  Prefix := IncludeTrailingPathDelimiter(Prefix);
  for var Path in FMembers.Keys do
    if Path.StartsWith(Prefix, True) and
      (Recursive or not Path.Substring(Length(Prefix)).Contains(PathDelim)) then
      Result := Result + [Path];
end;

function TArchiveStorage.Folders(const Location: string): TArray<string>;
begin
  Result := nil;
  var Prefix := MediaPath(Location);
  if Prefix = '' then Exit;
  Prefix := IncludeTrailingPathDelimiter(Prefix);
  var Seen := TStringList.Create;
  try
    Seen.CaseSensitive := False;
    for var Path in FMembers.Keys do
      if Path.StartsWith(Prefix, True) then
      begin
        var Tail := Path.Substring(Length(Prefix));
        var Split := Tail.IndexOf(PathDelim);
        if Split >= 0 then
        begin
          var Folder := Prefix + Tail.Substring(0, Split);
          if Seen.IndexOf(Folder) < 0 then
          begin
            Seen.Add(Folder);
            Result := Result + [Folder];
          end;
        end;
      end;
  finally
    Seen.Free;
  end;
end;

procedure TArchiveStorage.Delete(const Location: string);
begin
  CheckWritable(Location);
  FBase.Delete(Location);
end;

procedure TArchiveStorage.Replace(const Source, Target: string);
begin
  CheckWritable(Source);
  CheckWritable(Target);
  FBase.Replace(Source, Target);
end;

procedure TArchiveStorage.WriteAtomic(const Location: string; Stream: TStream);
begin
  CheckWritable(Location);
  FBase.WriteAtomic(Location, Stream);
end;

function TArchiveStorage.ReadBytes(const Location: string): TBytes;
begin
  var Input := OpenRead(Location);
  try
    if Input.Size > 256 * 1024 * 1024 then
      raise EReadError.Create('Container byte read exceeds 256 MiB');
    SetLength(Result, Input.Size);
    if Length(Result) <> 0 then
      Input.ReadBuffer(Result[0], Length(Result));
  finally
    Input.Free;
  end;
end;

procedure TArchiveStorage.WriteBytes(const Location: string; const Data: TBytes);
begin
  CheckWritable(Location);
  FBase.WriteBytes(Location, Data);
end;

function TArchiveStorage.ReadText(const Location: string): string;
begin
  var Data := ReadBytes(Location);
  var Offset := 0;
  if (Length(Data) >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
    Offset := 3;
  Result := TEncoding.UTF8.GetString(Data, Offset, Length(Data) - Offset);
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
  var Index: Integer;
  if not FMembers.TryGetValue(MediaPath(Location), Index) then
    raise EReadError.Create('Missing container member: ' + Location);
  var Info := FContainer.Entries[Index];
  Result := Default(TStorageFile);
  Result.Name := ExtractFileName(Info.Name.Replace('/', PathDelim));
  Result.Location := MediaPath(Location);
  Result.RelativePath := Info.Name;
  Result.Size := Info.Size;
end;

procedure TArchiveStorage.SelectRom(const Callback: TStorageSelectionCallback);
begin
  FBase.SelectRom(Callback);
end;

end.
