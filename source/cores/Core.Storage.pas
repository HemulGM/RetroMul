unit Core.Storage;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles;

type
  TStorageFile = record
    Name, Location, RelativePath: string;
    Size: Int64;
  end;

  TStorageSnapshot = record
    Name, Location, PreviewLocation: string;
    Modified: TDateTime;
  end;

  TStorageSelection = record
    Cancelled: Boolean;
    Location, Error: string;
  end;

  TStorageSelectionCallback = reference to procedure(const Selection: TStorageSelection);

  IStoragePicker = interface
    ['{5C59D789-BB3D-4E67-90B2-DF36C33C8488}']
    procedure Select(Folder: Boolean; const Callback: TStorageSelectionCallback);
  end;

  IStorage = interface
    ['{93F9CA56-A0BB-45A0-BBD2-F907BAF8CDA1}']
    function GetRoot: string;
    function GetRomFolder: string;
    procedure SetRomFolder(const Value: string);
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
    procedure SelectRomFolder(const Callback: TStorageSelectionCallback);
    procedure SelectRom(const Callback: TStorageSelectionCallback);
    property Root: string read GetRoot;
    property RomFolder: string read GetRomFolder write SetRomFolder;
    // Listing filter only; file contents are never read to check the size.
    property CheckRomFileSize: Boolean read GetCheckRomFileSize write SetCheckRomFileSize;
    property MaxRomFileSize: Int64 read GetMaxRomFileSize write SetMaxRomFileSize;
  end;

  TStorage = class(TInterfacedObject, IStorage)
  private
    FRoot, FRomFolder: string;
    FPicker: IStoragePicker;
    FCheckRomFileSize: Boolean;
    FMaxRomFileSize: Int64;
    function GetRoot: string;
    function GetRomFolder: string;
    function GetCheckRomFileSize: Boolean;
    procedure SetCheckRomFileSize(Value: Boolean);
    function GetMaxRomFileSize: Int64;
    procedure SetMaxRomFileSize(Value: Int64);
  public
    constructor Create(const Root: string = ''; const Picker: IStoragePicker = nil);
    class function Default: IStorage; static;
    procedure SetRomFolder(const Value: string);
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
    procedure SelectRomFolder(const Callback: TStorageSelectionCallback);
    procedure SelectRom(const Callback: TStorageSelectionCallback);
    property RomFolder: string read GetRomFolder write SetRomFolder;
    property CheckRomFileSize: Boolean read GetCheckRomFileSize write SetCheckRomFileSize;
    property MaxRomFileSize: Int64 read GetMaxRomFileSize write SetMaxRomFileSize;
  end;

implementation

uses
  System.IOUtils, System.StrUtils, System.Generics.Collections, Core.RomFormat,
  {$IFDEF ANDROID}
  Core.Storage.Android, {$ENDIF}
  {$IFDEF MSWINDOWS} Winapi.Windows, {$ELSE} Posix.Stdio, Posix.Unistd, {$ENDIF}
  System.Types;

function SafeName(const Value: string): string;
begin
  Result := Value.Trim;
  if (Result = '') or (Result = '.') or (Result = '..') or
    (Pos('/', Result) > 0) or (Pos('\', Result) > 0) or (Pos(':', Result) > 0) then
    raise EArgumentException.Create('Invalid storage name: ' + Value);
end;

{ TStorage }

constructor TStorage.Create(const Root: string; const Picker: IStoragePicker);
begin
  inherited Create;
  FCheckRomFileSize := True;
  FMaxRomFileSize := ROM_MAX_SIZE;
  FRoot := Root;
  if FRoot = '' then
  begin
    FRoot := TPath.GetDocumentsPath;
    if (FRoot = '') or not TPath.IsPathRooted(FRoot) then
      FRoot := TPath.GetHomePath;
    if (FRoot = '') or not TPath.IsPathRooted(FRoot) then
      raise EInOutError.Create('Cannot determine storage directory');

    FRoot := TPath.Combine(FRoot, 'RetroMul');
  end;
  FRoot := ExpandFileName(FRoot);
  FPicker := Picker;
  var Ini := ReadConfig(ConfigFile('storage'));
  try
    FRomFolder := Ini.ReadString('ROMs', 'Folder', '');
  finally
    Ini.Free;
  end;
end;

class function TStorage.Default: IStorage;
begin
  // Independent instances avoid mutable global settings shared between workers.
  Result := TStorage.Create;
end;

function TStorage.GetRoot: string;
begin
  Result := FRoot;
end;

function TStorage.GetRomFolder: string;
begin
  Result := FRomFolder;
end;

function TStorage.GetCheckRomFileSize: Boolean;
begin
  Result := FCheckRomFileSize;
end;

procedure TStorage.SetCheckRomFileSize(Value: Boolean);
begin
  FCheckRomFileSize := Value;
end;

function TStorage.GetMaxRomFileSize: Int64;
begin
  Result := FMaxRomFileSize;
end;

procedure TStorage.SetMaxRomFileSize(Value: Int64);
begin
  if Value <= 0 then
    raise EArgumentOutOfRangeException.Create('MaxRomFileSize must be positive (bytes)');
  FMaxRomFileSize := Value;
end;

procedure TStorage.SetRomFolder(const Value: string);
begin
  var Ini := ReadConfig(ConfigFile('storage'));
  try
    Ini.WriteString('ROMs', 'Folder', Value);
    WriteConfig(Ini);
    FRomFolder := Value;
  finally
    Ini.Free;
  end;
end;

function TStorage.OpenRead(const Location: string): TStream;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.OpenUri(Location));
  {$ENDIF}
  Result := TFileStream.Create(Location, fmOpenRead or fmShareDenyWrite);
end;

function TStorage.OpenWrite(const Location: string): TStream;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.OpenWriteUri(Location));
  {$ENDIF}
  EnsureFolder(ExtractFilePath(ExpandFileName(Location)));
  Result := TFileStream.Create(Location, fmCreate);
end;

function TStorage.Exists(const Location: string): Boolean;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Exists(Location));
  {$ENDIF}
  Result := TFile.Exists(Location);
end;

function TStorage.ModifiedTime(const Location: string): TDateTime;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.ModifiedTime(Location));
  {$ENDIF}
  Result := TFile.GetLastWriteTime(Location);
end;

function TStorage.FolderExists(const Location: string): Boolean;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Exists(Location));
  {$ENDIF}
  Result := TDirectory.Exists(Location);
end;

procedure TStorage.EnsureFolder(const Location: string);
begin
  TDirectory.CreateDirectory(Location);
end;

function TStorage.Files(const Location: string; Recursive: Boolean): TArray<string>;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
  begin
    var Items := TAndroidStorage.Enumerate(Location, Recursive);
    SetLength(Result, Length(Items));
    for var i := 0 to High(Items) do
      Result[i] := Items[i].Location;
    Exit;
  end;
  {$ENDIF}
  if not FolderExists(Location) then
    Exit(nil);
  var Option := TSearchOption.soTopDirectoryOnly;
  if Recursive then
    Option := TSearchOption.soAllDirectories;
  Result := TDirectory.GetFiles(Location, '*', Option);
end;

function TStorage.Folders(const Location: string): TArray<string>;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
  begin
    var Items := TAndroidStorage.Enumerate(Location, False, True);
    SetLength(Result, Length(Items));
    for var i := 0 to High(Items) do
      Result[i] := Items[i].Location;
    Exit;
  end;
  {$ENDIF}
  if not FolderExists(Location) then
    Exit(nil);
  Result := TDirectory.GetDirectories(Location);
end;

procedure TStorage.Delete(const Location: string);
begin
  if Exists(Location) then
    TFile.Delete(Location);
end;

procedure TStorage.Replace(const Source, Target: string);
begin
  {$IFDEF MSWINDOWS}
  if not MoveFileEx(PChar(Source), PChar(Target), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
  {$ELSE}
  var Src := UTF8String(Source);
  var Dst := UTF8String(Target);
  if Posix.Stdio.__rename(PAnsiChar(Src), PAnsiChar(Dst)) <> 0 then
    RaiseLastOSError;
  {$ENDIF}
end;

procedure TStorage.WriteAtomic(const Location: string; Stream: TStream);
begin
  if Location.StartsWith('content://') then
    raise ENotSupportedException.Create('Document providers do not guarantee atomic replacement; use OpenWrite for document export');

  // Keep the temporary basename short even for nested snapshot staging files.
  var Temporary := TPath.Combine(ExtractFilePath(Location),
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').Replace('-', '') + '.tmp');
  try
    var Output := OpenWrite(Temporary);
    try
      Stream.Position := 0;
      Output.CopyFrom(Stream, Stream.Size);
      {$IFDEF MSWINDOWS}
      if not FlushFileBuffers(TFileStream(Output).Handle) then
        RaiseLastOSError;
      {$ELSE}
      if fsync(TFileStream(Output).Handle) <> 0 then
        RaiseLastOSError;
      {$ENDIF}
    finally
      Output.Free;
    end;
    Replace(Temporary, Location);
  finally
    Delete(Temporary);
  end;
end;

function TStorage.ReadBytes(const Location: string): TBytes;
begin
  var Input := OpenRead(Location);
  try
    Result := ReadRomData(Input);
  finally
    Input.Free;
  end;
end;

procedure TStorage.WriteBytes(const Location: string; const Data: TBytes);
begin
  var Stream := TBytesStream.Create(Data);
  try
    WriteAtomic(Location, Stream);
  finally
    Stream.Free;
  end;
end;

function TStorage.ReadText(const Location: string): string;
begin
  var Data := ReadBytes(Location);
  var Encoding: TEncoding := nil;
  var Offset := TEncoding.GetBufferEncoding(Data, Encoding, TEncoding.UTF8);
  Result := Encoding.GetString(Data, Offset, Length(Data) - Offset);
end;

function TStorage.ConfigFile(const SystemId: string): string;
begin
  Result := TPath.Combine(FRoot, SafeName(SystemId) + '.ini');
end;

function TStorage.ReadConfig(const Location: string): TMemIniFile;
begin
  // TMemIniFile never reads/writes a physical file here: all I/O goes through storage.
  Result := TMemIniFile.Create('', TEncoding.UTF8);
  try
    Result.Rename(Location, False);
    if Exists(Location) then
    begin
      var Lines := TStringList.Create;
      try
        Lines.Text := ReadText(Location);
        Result.SetStrings(Lines);
      finally
        Lines.Free;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TStorage.WriteConfig(Ini: TMemIniFile);
begin
  var Lines := TStringList.Create;
  try
    Ini.GetStrings(Lines);
    WriteBytes(Ini.FileName, TEncoding.UTF8.GetBytes(Lines.Text));
  finally
    Lines.Free;
  end;
end;

function TStorage.SaveRoot: string;
begin
  Result := TPath.Combine(FRoot, 'saves');
end;

function TStorage.SnapshotRoot: string;
begin
  Result := TPath.Combine(FRoot, 'snapshots');
end;

function TStorage.ScreenshotFile(const RomName: string): string;
begin
  var Name := ChangeFileExt(ExtractFileName(RomName), '');
  for var i := 1 to Length(Name) do
    if (Ord(Name[i]) < 32) or CharInSet(Name[i], ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Name[i] := '_';
  if Name = '' then
    Name := 'Game';
  Result := TPath.Combine(TPath.Combine(FRoot, 'screenshots'), Copy(Name, 1, 80) + '_' +
    FormatDateTime('yyyymmdd_hhnnss_zzz', Now) + '_' + TGUID.NewGuid.ToString + '.png');
end;

function TStorage.TemporaryFile(const Extension: string): string;
begin
  if (Pos('/', Extension) > 0) or (Pos('\', Extension) > 0) then
    raise EArgumentException.Create('Invalid temporary file extension');

  Result := TPath.Combine(TPath.Combine(FRoot, 'cache'), TGUID.NewGuid.ToString + Extension);
end;

function TStorage.GamePath(const Root, RomName, Identity, Extension: string): string;
begin
  Result := '';
  var Candidates := Files(Root);
  if Extension = '' then
    Candidates := Folders(Root);
  for var Path in Candidates do
  begin
    var Name := ExtractFileName(Path);
    if SameText(Name, Identity + Extension) or EndsText('_' + Identity + Extension, Name) then
    begin
      if Result <> '' then
        raise EInOutError.Create('Multiple saves for game ' + Identity);

      Result := Path;
    end;
  end;
  if Result <> '' then
    Exit;

  var Title := ChangeFileExt(ExtractFileName(RomName), '').Trim;
  for var i := 1 to Length(Title) do
    if (Ord(Title[i]) < 32) or CharInSet(Title[i], ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Title[i] := '_';
  Title := Copy(Title, 1, 80).Trim;
  if Title = '' then
    Title := 'Game';
  Result := TPath.Combine(Root, Title + '_' + SafeName(Identity) + Extension);
end;

function GameIdentity(const SystemId, Identity: string): string;
begin
  Result := Identity;
  if not SameText(SystemId, ROM_SYSTEM_NES) and not StartsText(UpperCase(SystemId) + '-', Identity) then
    Result := UpperCase(SafeName(SystemId)) + '-' + Identity;
end;

function TStorage.GameSave(const SystemId, RomName, Identity: string): string;
begin
  Result := GamePath(SaveRoot, RomName, GameIdentity(SystemId, Identity), '.sav');
end;

function TStorage.GameSnapshots(const SystemId, RomName, Identity: string): string;
begin
  Result := GamePath(SnapshotRoot, RomName, GameIdentity(SystemId, Identity), '');
end;

function TStorage.Snapshots(const SystemId, RomName, Identity: string): TArray<TStorageSnapshot>;
begin
  var List := TList<TStorageSnapshot>.Create;
  try
    for var Path in Files(GameSnapshots(SystemId, RomName, Identity)) do
      if SameText(ExtractFileExt(Path), '.snapshot') then
      begin
        var Item := System.Default(TStorageSnapshot);
        Item.Name := ChangeFileExt(ExtractFileName(Path), '');
        Item.Location := Path;
        Item.PreviewLocation := ChangeFileExt(Path, '.bmp');
        if not Exists(Item.PreviewLocation) then
          Item.PreviewLocation := '';
        Item.Modified := ModifiedTime(Path);
        List.Add(Item);
      end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function TStorage.Describe(const Location: string): TStorageFile;
begin
  {$IFDEF ANDROID}
  if Location.StartsWith('content://') then
    Exit(TAndroidStorage.Describe(Location));
  {$ENDIF}
  Result := System.Default(TStorageFile);
  Result.Location := Location;
  Result.Name := ExtractFileName(Location);
  Result.Size := TFile.GetSize(Location);
end;

function TStorage.Roms(const SystemId: string): TArray<TStorageFile>;
begin
  if FRomFolder = '' then
    Exit(nil);

  var RomSystem := RomSystemFromId(LowerCase(SafeName(SystemId)));
  if RomSystem = TRomSystem.Unknown then
    Exit(nil);

  var FolderName := RomSystemFolder(RomSystem);
  var Extensions := RomExtensions(RomSystem);
  var Candidates: TArray<TStorageFile>;
  {$IFDEF ANDROID}
  if FRomFolder.StartsWith('content://') then
  begin
    // Query only root directories, then the selected system's direct children.
    for var Folder in TAndroidStorage.Enumerate(FRomFolder, False, True) do
      if SameText(Folder.Name, FolderName) then
      begin
        Candidates := TAndroidStorage.Enumerate(Folder.Location, False);
        Break;
      end;
  end
  else
  {$ENDIF}
  begin
    var List := TList<TStorageFile>.Create;
    try
      for var Path in Files(TPath.Combine(FRomFolder, FolderName)) do
      begin
        if not MatchText(ExtractFileExt(Path), Extensions) then
          Continue;

        var Item := Describe(Path);
        Item.RelativePath := ExtractRelativePath(IncludeTrailingPathDelimiter(FRomFolder), Path);
        List.Add(Item);
      end;
      Candidates := List.ToArray;
    finally
      List.Free;
    end;
  end;
  var Matches := TList<TStorageFile>.Create;
  try
    for var Item in Candidates do
    begin
      // Listing never opens ROM streams. Header validation belongs to loading.
      if (FCheckRomFileSize and (Item.Size > FMaxRomFileSize)) or not MatchText(ExtractFileExt(Item.Name), Extensions) then
        Continue;

      var Match := Item;
      Match.RelativePath := FolderName + '/' + Item.Name;
      Matches.Add(Match);
    end;
    Result := Matches.ToArray;
  finally
    Matches.Free;
  end;
end;

procedure TStorage.SelectRomFolder(const Callback: TStorageSelectionCallback);
begin
  if FPicker = nil then
    raise ENotSupportedException.Create('No storage picker is configured');

  var Storage: IStorage := Self;
  FPicker.Select(True,
    procedure(const Selection: TStorageSelection)
    begin
      var Result := Selection;
      if not Result.Cancelled and (Result.Error = '') then
      try
        Storage.RomFolder := Result.Location;
      except
        on E: Exception do
          Result.Error := E.Message;
      end;
      if Assigned(Callback) then
        Callback(Result);
    end);
end;

procedure TStorage.SelectRom(const Callback: TStorageSelectionCallback);
begin
  if FPicker = nil then
    raise ENotSupportedException.Create('No storage picker is configured');

  FPicker.Select(False, Callback);
end;

end.

