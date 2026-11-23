unit J2ME.FileSystem.Store;

interface

uses
  System.SysUtils, System.Generics.Collections, Core.Storage;

const
  J2MEFileRoots: array[0..1] of string = ('c:', 'e:');
  J2MEVolumeBytes = 16 * 1024 * 1024;
  J2MEFileBytes = 1024 * 1024;
  J2MEFileEntries = 2048;
  J2MEPathChars = 1024;
  FileDirectory = 1;
  FileHidden = 2;
  FileUnreadable = 4;
  FileUnwritable = 8;

type
  EJ2MEFileIO = class(Exception);

  TJ2MEFileEntry = record
    Identity: string;
    Flags: Integer;
    Modified: Int64;
    Data: TBytes;
    function Has(Flag: Integer): Boolean;
  end;

  // A transaction holds the same OS lock from loading through atomic replace.
  TJ2MEFileStore = class
  private
    FStorage: IStorage;
    FPath: string;
    FLock: TObject;
    FEntries: TDictionary<string, TJ2MEFileEntry>;
    procedure Load;
  public
    constructor Create(const Storage: IStorage; const Path: string; const Cancelled: TFunc<Boolean>);
    destructor Destroy; override;
    procedure Commit;
    function BytesUnder(const Prefix: string; Recursive: Boolean): Int64;
    property Entries: TDictionary<string, TJ2MEFileEntry> read FEntries;
  end;

function J2MEFileRevision: Int64;

function J2MEFileLeaf(const Path: string): string;

function J2MEFileParent(const Path: string): string;

function J2MEFileRoot(const Path: string): Boolean;

function ValidJ2MEFileName(const Name: string; Pattern: Boolean = False): Boolean;

implementation

uses
  System.Classes, System.SyncObjs, JVM.StateIO, J2ME.RMS.Store;

const
  FileStoreTag = 'J2ME-VFS-1';
  MaxPathBytes = J2MEPathChars * 4;
  MaxImageBytes = 2 * J2MEVolumeBytes + J2MEFileEntries * (MaxPathBytes + 256) + 64;

var
  FileRevision: Int64;

function J2MEFileRevision: Int64;
begin
  Result := TInterlocked.Read(FileRevision);
end;

procedure InitializeFileRevision;
begin
  // Saved streams can outlive a process. Give its cache an independent epoch.
  var Session := TGUID.NewGuid;
  Move(Session, FileRevision, SizeOf(FileRevision));
end;

function TJ2MEFileEntry.Has(Flag: Integer): Boolean;
begin
  Result := (Flags and Flag) <> 0;
end;

function J2MEFileRoot(const Path: string): Boolean;
begin
  Result := (Path = J2MEFileRoots[0]) or (Path = J2MEFileRoots[1]);
end;

function J2MEFileLeaf(const Path: string): string;
begin
  Result := Copy(Path, LastDelimiter('/', Path) + 1, MaxInt);
end;

function J2MEFileParent(const Path: string): string;
begin
  Result := Copy(Path, 1, LastDelimiter('/', Path) - 1);
end;

function ValidJ2MEFileName(const Name: string; Pattern: Boolean): Boolean;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 255) or (Name = '.') or (Name = '..') then
    Exit;
  var PreviousHigh := False;
  for var Ch in Name do
  begin
    if PreviousHigh <> ((Ord(Ch) >= $DC00) and (Ord(Ch) <= $DFFF)) then
      Exit;
    PreviousHigh := (Ord(Ch) >= $D800) and (Ord(Ch) <= $DBFF);
    if (Ord(Ch) < 32) or (Ord(Ch) = 127) or CharInSet(Ch, ['\', '/', ':', '"', '?', '#', '<', '>', '|']) or
      ((Ch = '*') and not Pattern) then
      Exit;
  end;
  Result := not PreviousHigh;
end;

function ValidStoredPath(const Path: string): Boolean;
begin
  Result := False;
  if Length(Path) > J2MEPathChars then
    Exit;
  var Parts := Path.Split(['/']);
  if not J2MEFileRoot(Parts[0]) then
    Exit;
  for var I := 1 to High(Parts) do
    if not ValidJ2MEFileName(Parts[I]) then
      Exit;
  Result := True;
end;

constructor TJ2MEFileStore.Create(const Storage: IStorage; const Path: string; const Cancelled: TFunc<Boolean>);
begin
  inherited Create;
  FStorage := Storage;
  FPath := Path;
  FEntries := TDictionary<string, TJ2MEFileEntry>.Create;
  var Folder := ExtractFileDir(Path);
  if not FStorage.FolderExists(Folder) then
  try
    FStorage.EnsureFolder(Folder);
  except
    on E: Exception do
      if not FStorage.FolderExists(Folder) then
        raise;
  end;
  FLock := LockJ2MEDataFile(Path + '.lock', Cancelled);
  if FStorage.Exists(Path) then
    Load
  else
  begin
    var Entry := Default(TJ2MEFileEntry);
    Entry.Flags := FileDirectory;
    for var Root in J2MEFileRoots do
      FEntries.Add(Root, Entry);
    for var Name in ['photos', 'music', 'videos', 'recordings', 'private'] do
      FEntries.Add('c:/' + Name, Entry);
  end;
end;

destructor TJ2MEFileStore.Destroy;
begin
  FEntries.Free;
  FLock.Free;
  inherited;
end;

procedure TJ2MEFileStore.Load;
var
  Parent: TJ2MEFileEntry;
begin
  var Stream := FStorage.OpenRead(FPath);
  try
    if Stream.Size > MaxImageBytes then
      raise EJ2MEFileIO.Create('Virtual file system exceeds its capacity');
    var State := TJVMStateIO.Create(Stream, True);
    try
      State.Tag(FileStoreTag);
      var Count := 0;
      State.Count(Count, J2MEFileEntries);
      for var I := 1 to Count do
      begin
        var Key: TBytes := nil;
        var Entry := Default(TJ2MEFileEntry);
        State.Bytes(Key, MaxPathBytes);
        var Path := TEncoding.UTF8.GetString(Key);
        State.Text(Entry.Identity);
        State.Count(Entry.Flags, FileDirectory or FileHidden or FileUnreadable or FileUnwritable);
        State.Int64Value(Entry.Modified);
        State.Bytes(Entry.Data, J2MEFileBytes);
        if not ValidStoredPath(Path) or FEntries.ContainsKey(Path) or
          (Entry.Has(FileDirectory) and (Length(Entry.Data) <> 0)) or
          (not Entry.Has(FileDirectory) and (Length(Entry.Identity) <> 38)) then
          raise EJ2MEFileIO.Create('Invalid virtual file entry');
        FEntries.Add(Path, Entry);
      end;
      State.Finish;
    finally
      State.Free;
    end;
  finally
    Stream.Free;
  end;
  for var Root in J2MEFileRoots do
    if not FEntries.TryGetValue(Root, Parent) or (Parent.Flags <> FileDirectory) or
      (BytesUnder(Root + '/', True) > J2MEVolumeBytes) then
      raise EJ2MEFileIO.Create('Invalid virtual file volume');
  for var Entry in FEntries do
    if not J2MEFileRoot(Entry.Key) and
      (not FEntries.TryGetValue(J2MEFileParent(Entry.Key), Parent) or not Parent.Has(FileDirectory)) then
      raise EJ2MEFileIO.Create('Missing virtual parent directory');
end;

procedure TJ2MEFileStore.Commit;
begin
  var Stream := TMemoryStream.Create;
  try
    var State := TJVMStateIO.Create(Stream, False);
    try
      State.Tag(FileStoreTag);
      var Count := FEntries.Count;
      State.Count(Count, J2MEFileEntries);
      for var Pair in FEntries do
      begin
        var Key := TEncoding.UTF8.GetBytes(Pair.Key);
        var Entry := Pair.Value;
        State.Bytes(Key, MaxPathBytes);
        State.Text(Entry.Identity);
        State.Count(Entry.Flags, FileDirectory or FileHidden or FileUnreadable or FileUnwritable);
        State.Int64Value(Entry.Modified);
        State.Bytes(Entry.Data, J2MEFileBytes);
      end;
    finally
      State.Free;
    end;
    FStorage.WriteAtomic(FPath, Stream);
    TInterlocked.Increment(FileRevision);
  finally
    Stream.Free;
  end;
end;

function TJ2MEFileStore.BytesUnder(const Prefix: string; Recursive: Boolean): Int64;
begin
  Result := 0;
  for var Entry in FEntries do
    if Entry.Key.StartsWith(Prefix) and (Recursive or (LastDelimiter('/', Entry.Key) = Length(Prefix))) then
      Inc(Result, Length(Entry.Value.Data));
end;

initialization
  InitializeFileRevision;

end.

