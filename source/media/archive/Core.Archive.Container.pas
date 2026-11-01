unit Core.Archive.Container;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, Core.Storage;

const
  MaxArchiveBytes = Int64(4) * 1024 * 1024 * 1024;
  MaxArchiveEntries = 4096;

type
  TArchiveEntry = record
    Name: string;
    Size: UInt64;
    CRC32: Cardinal;
    HasCRC, IsDirectory: Boolean;
  end;

  IArchiveContainer = interface
    ['{47889AB6-DC38-421C-8F94-CF5134C14081}']
    function GetCount: Integer;
    function GetEntry(Index: Integer): TArchiveEntry;
    function GetNames: TArray<string>;
    // Returns a declared CRC when available, otherwise computes it on demand.
    function Checksum(Index: Integer): Cardinal;
    function FindName(const Name: string): Integer;
    function FindCRC(Value: Cardinal): Integer;
    function OpenRead(Index: Integer): TStream;
    procedure Read(Index: Integer; out Data: TBytes);
    property Count: Integer read GetCount;
    property Entries[Index: Integer]: TArchiveEntry read GetEntry;
    property Names: TArray<string> read GetNames;
  end;

  // Backends materialize members on demand. Solid readers may fill this cache
  // sequentially. Cache paths are generated independently of member names.
  TArchiveContainer = class(TInterfacedObject, IArchiveContainer)
  private
    FEntries: TArray<TArchiveEntry>;
    FFiles: TArray<string>;
    FReady: TArray<Boolean>;
    FCacheFiles: TList<string>;
    FTotal, FNameBytes: Int64;
    procedure CheckIndex(Index: Integer);
    procedure EnsureEntry(Index: Integer);
  protected
    FStorage: IStorage;
    procedure Extract(Index: Integer; Output: TStream); virtual;
    procedure AddEntry(const Entry: TArchiveEntry);
    function BeginEntry(Index: Integer): TStream;
    procedure TrackCacheFile(const Path: string);
    procedure CompleteEntry(Index: Integer; CRC: Cardinal);
    function GetCount: Integer;
    function GetEntry(Index: Integer): TArchiveEntry;
    function GetNames: TArray<string>;
  public
    constructor Create(const Storage: IStorage);
    destructor Destroy; override;
    // Returns a declared CRC when available, otherwise computes it on demand.
    function Checksum(Index: Integer): Cardinal;
    function FindName(const Name: string): Integer;
    function FindCRC(Value: Cardinal): Integer;
    function OpenRead(Index: Integer): TStream;
    procedure Read(Index: Integer; out Data: TBytes);
  end;

  // A read-only view of the original source with an already opened container.
  // The source remains caller-owned; entry streams independently retain caches.
  TArchiveSourceStream = class(TStream)
  private
    FSource: TStream;
    FContainer: IArchiveContainer;
  public
    constructor Create(Source: TStream; const Container: IArchiveContainer);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Container: IArchiveContainer read FContainer;
  end;

function CacheArchiveInput(Input: TStream; const Storage: IStorage; const Created: TProc<string> = nil): string;

procedure ReadArchiveBuffer(Input: TStream; var Buffer; Count: Integer);

function ArchiveSignatureMatches(Input: TStream; const Signature: array of Byte): Boolean;

function ArchiveCRC(Stream: TStream): Cardinal;

implementation

type
  TBoundedArchiveOutput = class(TStream)
  private
    FOutput: TStream;
    FRemaining: UInt64;
  public
    constructor Create(Output: TStream; Size: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TArchiveEntryStream = class(TStream)
  private
    FInput: TStream;
    FOwner: IArchiveContainer;
  public
    constructor Create(Input: TStream; const Owner: IArchiveContainer);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

var
  CRCTable: array[0..255] of Cardinal;

procedure ReadArchiveBuffer(Input: TStream; var Buffer; Count: Integer);
begin
  if Input = nil then
    raise EArgumentNilException.Create('Input');
  if Count < 0 then
    raise EArgumentOutOfRangeException.Create('Count');
  var Offset := 0;
  while Offset < Count do
  begin
    TStorage.CheckReadCancelled;
    var N := Input.Read(PByte(NativeUInt(@Buffer) + NativeUInt(Offset))^, Count - Offset);
    if (N <= 0) or (N > Count - Offset) then
      raise EReadError.Create('Truncated archive data');
    Inc(Offset, N);
  end;
end;

function ArchiveSignatureMatches(Input: TStream; const Signature: array of Byte): Boolean;
begin
  if Input = nil then
    raise EArgumentNilException.Create('Input');
  if Length(Signature) = 0 then
    Exit(False);
  var Saved := Input.Position;
  try
    Input.Position := 0;
    var Data: TBytes;
    SetLength(Data, Length(Signature));
    var Offset := 0;
    while Offset < Length(Data) do
    begin
      TStorage.CheckReadCancelled;
      var N := Input.Read(Data[Offset], Length(Data) - Offset);
      if N = 0 then
        Exit(False);
      if (N < 0) or (N > Length(Data) - Offset) then
        raise EReadError.Create('Invalid archive signature read');
      Inc(Offset, N);
    end;
    Result := (Length(Data) <> 0) and CompareMem(@Data[0], @Signature[0], Length(Data));
  finally
    Input.Position := Saved;
  end;
end;

function ArchiveCRC(Stream: TStream): Cardinal;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
  var Saved := Stream.Position;
  try
    Stream.Position := 0;
    Result := $FFFFFFFF;
    var Buffer: array[0..65535] of Byte;
    while True do
    begin
      TStorage.CheckReadCancelled;
      var N := Stream.Read(Buffer, SizeOf(Buffer));
      if N = 0 then
        Break;
      if (N < 0) or (N > SizeOf(Buffer)) then
        raise EReadError.Create('Invalid archive read');
      for var I := 0 to N - 1 do
        Result := (Result shr 8) xor CRCTable[(Result xor Buffer[I]) and $FF];
    end;
    Result := not Result;
  finally
    Stream.Position := Saved;
  end;
end;

function CacheArchiveInput(Input: TStream; const Storage: IStorage; const Created: TProc<string>): string;
begin
  if Input = nil then
    raise EArgumentNilException.Create('Input');
  if Storage = nil then
    raise EArgumentNilException.Create('Storage');
  var ReadFailed := False;
  Result := Storage.TemporaryFile('.archive-source');
  if Assigned(Created) then
    Created(Result);
  var Saved := Input.Position;
  try
    try
      try
        Input.Position := 0;
        var Output := Storage.OpenWrite(Result);
        try
          var Buffer: array[0..65535] of Byte;
          var Total: Int64 := 0;
          while True do
          begin
            TStorage.CheckReadCancelled;
            var N := Input.Read(Buffer, SizeOf(Buffer));
            if N = 0 then
              Break;
            if (N < 0) or (N > SizeOf(Buffer)) or (N > MaxArchiveBytes - Total) then
              raise EReadError.Create('Archive exceeds 4 GiB or returned an invalid read count');
            Output.WriteBuffer(Buffer, N);
            Inc(Total, N);
          end;
        finally
          Output.Free;
        end;
      except
        ReadFailed := True;
        raise;
      end;
    finally
      try
        Input.Position := Saved;
      except
        if not ReadFailed then
          raise;
      end;
    end;
  except
    try
      if Storage.Exists(Result) then
        Storage.Delete(Result);
    except
      // Preserve the original read/cancellation/seek error.
    end;
    raise;
  end;
end;

constructor TArchiveContainer.Create(const Storage: IStorage);
begin
  inherited Create;
  FCacheFiles := TList<string>.Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
end;

destructor TArchiveContainer.Destroy;
begin
  if FCacheFiles <> nil then
    for var Path in FCacheFiles do
      if Path <> '' then
      try
        FStorage.Delete(Path);
      except
      // Closing a core must not raise an exception during cache cleanup.
      end;
  FCacheFiles.Free;
  inherited;
end;

procedure TArchiveContainer.CheckIndex(Index: Integer);
begin
  if (Index < 0) or (Index >= Length(FEntries)) then
    raise EArgumentOutOfRangeException.Create('Archive member index');
end;

procedure TArchiveContainer.AddEntry(const Entry: TArchiveEntry);
begin
  if (Entry.Name = '') or Entry.Name.Contains(#0) then
    raise EReadError.Create('Invalid archive member name');
  if Length(FEntries) >= MaxArchiveEntries then
    raise EReadError.Create('Archive contains too many entries');
  if Entry.Size > UInt64(MaxArchiveBytes - FTotal) then
    raise EReadError.Create('Archive unpacked data exceeds 4 GiB');
  if (Length(Entry.Name) > 65535) or (Length(Entry.Name) * Int64(2) > 16 * 1024 * 1024 - FNameBytes) then
    raise EReadError.Create('Archive names exceed metadata limit');
  Inc(FTotal, Int64(Entry.Size));
  Inc(FNameBytes, Length(Entry.Name) * Int64(2));
  FEntries := FEntries + [Entry];
  SetLength(FFiles, Length(FEntries));
  SetLength(FReady, Length(FEntries));
end;

function TArchiveContainer.BeginEntry(Index: Integer): TStream;
begin
  CheckIndex(Index);
  if FFiles[Index] <> '' then
    raise EInvalidOperation.Create('Archive member already cached');
  FFiles[Index] := FStorage.TemporaryFile('.archive-entry');
  TrackCacheFile(FFiles[Index]);
  Result := FStorage.OpenWrite(FFiles[Index]);
end;

procedure TArchiveContainer.TrackCacheFile(const Path: string);
begin
  FCacheFiles.Add(Path);
end;

procedure TArchiveContainer.CompleteEntry(Index: Integer; CRC: Cardinal);
begin
  CheckIndex(Index);
  FEntries[Index].CRC32 := CRC;
  FEntries[Index].HasCRC := True;
  FReady[Index] := True;
end;

procedure TArchiveContainer.Extract(Index: Integer; Output: TStream);
begin
  raise EReadError.Create('Archive member is not available');
end;

procedure TArchiveContainer.EnsureEntry(Index: Integer);
begin
  TMonitor.Enter(Self);
  try
    CheckIndex(Index);
    if FEntries[Index].IsDirectory then
      raise EReadError.Create('Cannot open archive directory');
    if FReady[Index] then
      Exit;
    try
      var Output := BeginEntry(Index);
      try
        var Limited := TBoundedArchiveOutput.Create(Output, FEntries[Index].Size);
        try
          Extract(Index, Limited);
        finally
          Limited.Free;
        end;
      finally
        Output.Free;
      end;
      var Input := FStorage.OpenRead(FFiles[Index]);
      try
        if UInt64(Input.Size) <> FEntries[Index].Size then
          raise EReadError.Create('Archive member size mismatch: ' + FEntries[Index].Name);
        var CRC := ArchiveCRC(Input);
        if FEntries[Index].HasCRC and (CRC <> FEntries[Index].CRC32) then
          raise EReadError.Create('Archive member CRC mismatch: ' + FEntries[Index].Name);
        CompleteEntry(Index, CRC);
      finally
        Input.Free;
      end;
    except
      if FFiles[Index] <> '' then
      begin
        var FailedFile := FFiles[Index];
        FFiles[Index] := '';
        FReady[Index] := False;
        try
          FStorage.Delete(FailedFile);
        except
        end;
        // TrackCacheFile keeps failed deletions for a retry at destruction.
      end;
      raise;
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TArchiveContainer.GetCount: Integer;
begin
  Result := Length(FEntries);
end;

function TArchiveContainer.GetEntry(Index: Integer): TArchiveEntry;
begin
  TMonitor.Enter(Self);
  try
    CheckIndex(Index);
    Result := FEntries[Index];
  finally
    TMonitor.Exit(Self);
  end;
end;

function TArchiveContainer.GetNames: TArray<string>;
begin
  SetLength(Result, Length(FEntries));
  for var I := 0 to High(Result) do
    Result[I] := FEntries[I].Name;
end;

function TArchiveContainer.Checksum(Index: Integer): Cardinal;
begin
  TMonitor.Enter(Self);
  try
    CheckIndex(Index);
    if FEntries[Index].IsDirectory then
      Exit(0);
    if not FEntries[Index].HasCRC then
      EnsureEntry(Index);
    Result := FEntries[Index].CRC32;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TArchiveContainer.FindName(const Name: string): Integer;
begin
  Result := -1;
  for var I := 0 to High(FEntries) do
    if not FEntries[I].IsDirectory and
      SameText(FEntries[I].Name.Replace('\', '/'), Name.Replace('\', '/')) then
    begin
      if Result >= 0 then
        raise EReadError.Create('Ambiguous archive member: ' + Name);
      Result := I;
    end;
end;

function TArchiveContainer.FindCRC(Value: Cardinal): Integer;
begin
  for var I := 0 to High(FEntries) do
    if not FEntries[I].IsDirectory and (Checksum(I) = Value) then
      Exit(I);
  Result := -1;
end;

function TArchiveContainer.OpenRead(Index: Integer): TStream;
begin
  EnsureEntry(Index);
  Result := TArchiveEntryStream.Create(FStorage.OpenRead(FFiles[Index]), Self);
end;

procedure TArchiveContainer.Read(Index: Integer; out Data: TBytes);
begin
  if GetEntry(Index).Size > 512 * 1024 * 1024 then
    raise EReadError.Create('Archive member exceeds 512 MiB byte buffer limit');
  var Input := OpenRead(Index);
  try
    SetLength(Data, Input.Size);
    if Length(Data) <> 0 then
      Input.ReadBuffer(Data[0], Length(Data));
  finally
    Input.Free;
  end;
end;

constructor TBoundedArchiveOutput.Create(Output: TStream; Size: UInt64);
begin
  inherited Create;
  FOutput := Output;
  FRemaining := Size;
end;

function TBoundedArchiveOutput.Read(var Buffer; Count: Longint): Longint;
begin
  raise EReadError.Create('Archive extraction output is write-only');
end;

function TBoundedArchiveOutput.Write(const Buffer; Count: Longint): Longint;
begin
  TStorage.CheckReadCancelled;
  if (Count < 0) or (UInt64(Count) > FRemaining) then
    raise EReadError.Create('Archive member exceeds declared size');
  Result := FOutput.Write(Buffer, Count);
  if (Result < 0) or (Result > Count) then
    raise EWriteError.Create('Invalid archive cache write');
  Dec(FRemaining, UInt64(Result));
end;

function TBoundedArchiveOutput.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Exit(FOutput.Position);
  raise EStreamError.Create('Archive extraction output is sequential');
end;

constructor TArchiveEntryStream.Create(Input: TStream; const Owner: IArchiveContainer);
begin
  inherited Create;
  FInput := Input;
  FOwner := Owner;
end;

destructor TArchiveEntryStream.Destroy;
begin
  FInput.Free;
  FOwner := nil;
  inherited;
end;

function TArchiveEntryStream.Read(var Buffer; Count: Longint): Longint;
begin
  TStorage.CheckReadCancelled;
  Result := FInput.Read(Buffer, Count);
end;

function TArchiveEntryStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Archive members are read-only');
end;

function TArchiveEntryStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FInput.Seek(Offset, Origin);
end;

constructor TArchiveSourceStream.Create(Source: TStream; const Container: IArchiveContainer);
begin
  inherited Create;
  if Source = nil then
    raise EArgumentNilException.Create('Source');
  if Container = nil then
    raise EArgumentNilException.Create('Container');
  FSource := Source;
  FContainer := Container;
end;

function TArchiveSourceStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := FSource.Read(Buffer, Count);
end;

function TArchiveSourceStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Archive sources are read-only');
end;

function TArchiveSourceStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FSource.Seek(Offset, Origin);
end;

initialization
  for var I := 0 to 255 do
  begin
    var C := Cardinal(I);
    for var J := 0 to 7 do
      if C and 1 <> 0 then
        C := (C shr 1) xor $EDB88320
      else
        C := C shr 1;
    CRCTable[I] := C;
  end;

end.

