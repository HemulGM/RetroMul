unit Core.Archive.Zip;

interface

uses
  System.Classes, Core.Storage, Core.Archive.Container;

function IsZipArchive(Input: TStream): Boolean;

function OpenZip(Input: TStream; const Storage: IStorage): IArchiveContainer;

implementation

uses
  System.SysUtils, System.Zip;

type
  TZipReadView = class(TStream)
  private
    FSource: TStream;
    FStart, FLength: Int64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(Source: TStream; Start, Length: Int64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TZipContainer = class(TArchiveContainer)
  private
    FPacked: string;
    FInput, FZipInput: TStream;
    FZip: TZipFile;
  protected
    procedure Extract(Index: Integer; Output: TStream); override;
  public
    constructor Create(Input: TStream; const Storage: IStorage);
    destructor Destroy; override;
  end;

constructor TZipReadView.Create(Source: TStream; Start, Length: Int64);
begin
  inherited Create;
  FSource := Source;
  FStart := Start;
  FLength := Length;
  FSource.Position := FStart;
end;

function TZipReadView.GetSize: Int64;
begin
  Result := FLength;
end;

function TZipReadView.Read(var Buffer; Count: Longint): Longint;
begin
  var Remaining := FLength - Position;
  if (Remaining <= 0) or (Count <= 0) then
    Exit(0);
  if Remaining < Count then
    Count := Longint(Remaining);
  Result := FSource.Read(Buffer, Count);
end;

function TZipReadView.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('Read-only ZIP view');
end;

function TZipReadView.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  var Base: Int64 := 0;
  case Origin of
    soCurrent:
      Base := FSource.Position - FStart;
    soEnd:
      Base := FLength;
  end;
  if (Offset < -Base) or (Offset > FLength - Base) then
    raise EReadError.Create('ZIP seek outside archive bounds');
  Result := FSource.Seek(FStart + Base + Offset, soBeginning) - FStart;
end;

function IsZipArchive(Input: TStream): Boolean;
begin
  Result := ArchiveSignatureMatches(Input, [$50, $4B, $03, $04]) or
    ArchiveSignatureMatches(Input, [$50, $4B, $05, $06]);
end;

function FindZipDirectoryEnd(Input: TStream; out EndHeader: TZipEndOfCentralHeader; out ArchiveEnd: Int64): Int64;
const
  MaxPadding = 32;
  EndHeaderSize = SizeOf(TZipEndOfCentralHeader) + SizeOf(UInt32);
  SearchSize = 65535 + EndHeaderSize + MaxPadding;
begin
  var TailSize := Input.Size;
  if TailSize > SearchSize then
    TailSize := SearchSize;
  if TailSize < 22 then
    raise EReadError.Create('Truncated ZIP directory');
  var Tail: TBytes;
  SetLength(Tail, TailSize);
  Input.Position := Input.Size - TailSize;
  Input.ReadBuffer(Tail[0], Length(Tail));
  // Old JAR files can carry a short NUL or line-ending suffix.
  var MinEnd := Length(Tail);
  while (MinEnd > 0) and (Length(Tail) - MinEnd < MaxPadding) and
    (Tail[MinEnd - 1] in [0, 10, 13]) do
    Dec(MinEnd);
  for var I := Length(Tail) - EndHeaderSize downto 0 do
    if (Tail[I] = $50) and (Tail[I + 1] = $4B) and (Tail[I + 2] = $05) and (Tail[I + 3] = $06) then
    begin
      Move(Tail[I + 4], EndHeader, SizeOf(EndHeader));
      var EndAt := I + EndHeaderSize + EndHeader.CommentLength;
      if (EndAt < MinEnd) or (EndAt > Length(Tail)) then
        Continue;
      // The RTL must see the same end record that we validated.
      for var J := I + 1 to EndAt - EndHeaderSize do
        if (Tail[J] = $50) and (Tail[J + 1] = $4B) and (Tail[J + 2] = $05) and (Tail[J + 3] = $06) then
          raise EReadError.Create('Ambiguous ZIP directory end');
      ArchiveEnd := Input.Size - TailSize + EndAt;
      Exit(Input.Size - TailSize + I);
    end;
  raise EReadError.Create('Missing ZIP directory');
end;

function ZipSignatureAt(Input: TStream; Offset: Int64; Signature: UInt32): Boolean;
begin
  Input.Position := Offset;
  var Value: UInt32;
  Result := (Input.Read(Value, SizeOf(Value)) = SizeOf(Value)) and (Value = Signature);
end;

// Bound central-directory allocations before RTL constructs its file array.
procedure CheckZipDirectory(Input: TStream; out ArchiveStart, ArchiveEnd: Int64);
const
  MaxDirectoryBytes = 64 * 1024 * 1024;
begin
  var EndHeader: TZipEndOfCentralHeader;
  var EndPosition := FindZipDirectoryEnd(Input, EndHeader, ArchiveEnd);
  ArchiveStart := 0;
  var Count := UInt64(EndHeader.CentralDirEntries);
  var Offset := UInt64(EndHeader.CentralDirOffset);
  var Bytes := UInt64(EndHeader.CentralDirSize);
  var IsZip64 := (EndHeader.DiskNumber = $FFFF) or (EndHeader.CentralDirStartDisk = $FFFF) or
    (EndHeader.NumEntriesThisDisk = $FFFF) or (Count = $FFFF) or
    (Offset = $FFFFFFFF) or (Bytes = $FFFFFFFF);
  if IsZip64 then
  begin
    if EndPosition < SizeOf(TZip64EndOfCentralHeader) then
      raise EReadError.Create('Truncated ZIP64 locator');
    var Locator: TZip64EndOfCentralHeader;
    Input.Position := EndPosition - SizeOf(Locator);
    Input.ReadBuffer(Locator, SizeOf(Locator));
    if (Locator.Signature <> $07064B50) or (Locator.CentralDirStartDisk <> 0) or
      (Locator.TotalNumberOfDisks <> 1) or
      (Locator.Zip64CentralDirOffset > UInt64(EndPosition - SizeOf(Locator))) or
      (UInt64(SizeOf(TZip64Header)) > UInt64(EndPosition - SizeOf(Locator)) - Locator.Zip64CentralDirOffset) then
      raise EReadError.Create('Invalid ZIP64 locator');
    var Header: TZip64Header;
    Input.Position := Locator.Zip64CentralDirOffset;
    Input.ReadBuffer(Header, SizeOf(Header));
    if (Header.Signature <> $06064B50) or (Header.HeaderSize < 44) or
      (Header.NumberOfDisks <> 0) or (Header.CentralDirStartDisk <> 0) or
      (Header.NumEntriesThisDisk <> Header.CentralDirEntries) then
      raise EReadError.Create('Invalid or split ZIP64 directory');
    Count := Header.CentralDirEntries;
    Offset := Header.CentralDirOffset;
    Bytes := Header.CentralDirSize;
    EndPosition := Locator.Zip64CentralDirOffset;
  end
  else if (EndHeader.DiskNumber <> 0) or (EndHeader.CentralDirStartDisk <> 0) or
    (EndHeader.NumEntriesThisDisk <> EndHeader.CentralDirEntries) then
    raise EReadError.Create('Split ZIP archives are unsupported');
  if (Count > MaxArchiveEntries) or (Bytes > MaxDirectoryBytes) or
    (Offset > UInt64(EndPosition)) or (Bytes > UInt64(EndPosition) - Offset) then
    raise EReadError.Create('ZIP directory exceeds archive limits');
  var Last := Offset + Bytes;
  // A complete ZIP can be appended with its original relative offsets.
  // Associate the final end record with the directory immediately before it.
  if not IsZip64 and (Count <> 0) and (Last < UInt64(EndPosition)) then
  begin
    var Start := EndPosition - Int64(Last);
    if ZipSignatureAt(Input, Start, $04034B50) and
      ZipSignatureAt(Input, Start + Int64(Offset), $02014B50) then
      ArchiveStart := Start;
  end;
  Inc(Last, UInt64(ArchiveStart));
  var NameBytes: UInt64 := 0;
  Input.Position := ArchiveStart + Int64(Offset);
  for var I := UInt64(1) to Count do
  begin
    TStorage.CheckReadCancelled;
    var Fixed: array[0..45] of Byte;
    if UInt64(Input.Position) > Last then
      raise EReadError.Create('Invalid ZIP directory offset');
    if Last - UInt64(Input.Position) < SizeOf(Fixed) then
      raise EReadError.Create('Truncated ZIP member header');
    Input.ReadBuffer(Fixed, SizeOf(Fixed));
    if (Fixed[0] <> $50) or (Fixed[1] <> $4B) or (Fixed[2] <> $01) or (Fixed[3] <> $02) then
      raise EReadError.Create('Invalid ZIP member header');
    var NameSize := Cardinal(Fixed[28]) or (Cardinal(Fixed[29]) shl 8);
    var ExtraSize := Cardinal(Fixed[30]) or (Cardinal(Fixed[31]) shl 8);
    var CommentSize := Cardinal(Fixed[32]) or (Cardinal(Fixed[33]) shl 8);
    Inc(NameBytes, NameSize);
    if (NameBytes > 16 * 1024 * 1024) or
      (UInt64(NameSize) + ExtraSize + CommentSize > Last - UInt64(Input.Position)) then
      raise EReadError.Create('ZIP member metadata exceeds directory limits');
    Input.Seek(Int64(NameSize) + ExtraSize + CommentSize, soCurrent);
  end;
  Input.Position := 0;
end;

constructor TZipContainer.Create(Input: TStream; const Storage: IStorage);
begin
  inherited Create(Storage);
  FPacked := CacheArchiveInput(Input, FStorage,
    procedure(Path: string)
    begin
      TrackCacheFile(Path);
    end);
  FInput := FStorage.OpenRead(FPacked);
  var ArchiveStart, ArchiveEnd: Int64;
  CheckZipDirectory(FInput, ArchiveStart, ArchiveEnd);
  if (ArchiveStart <> 0) or (ArchiveEnd <> FInput.Size) then
    FZipInput := TZipReadView.Create(FInput, ArchiveStart, ArchiveEnd - ArchiveStart);
  FZip := TZipFile.Create;
  if FZipInput <> nil then
    FZip.Open(FZipInput, zmRead)
  else
    FZip.Open(FInput, zmRead);
  for var I := 0 to FZip.FileCount - 1 do
  begin
    var Info := Default(TArchiveEntry);
    Info.Name := FZip.FileNames[I];
    Info.Size := FZip.FileInfo[I].UncompressedSize64;
    Info.CRC32 := FZip.FileInfo[I].CRC32;
    Info.HasCRC := True;
    Info.IsDirectory := Info.Name.EndsWith('/') or Info.Name.EndsWith('\');
    AddEntry(Info);
  end;
end;

destructor TZipContainer.Destroy;
begin
  FZip.Free;
  FZipInput.Free;
  FInput.Free;
  inherited;
end;

procedure TZipContainer.Extract(Index: Integer; Output: TStream);
begin
  var Input: TStream;
  var Header: TZipHeader;
  FZip.Read(Index, Input, Header, True);
  try
    var Buffer: array[0..65535] of Byte;
    var Total: UInt64 := 0;
    var Size := FZip.FileInfo[Index].UncompressedSize64;
    while True do
    begin
      TStorage.CheckReadCancelled;
      var N := Input.Read(Buffer, SizeOf(Buffer));
      if N = 0 then
        Break;
      if (N < 0) or (UInt64(N) > Size - Total) then
        raise EReadError.Create('ZIP member exceeds declared size');
      Output.WriteBuffer(Buffer, N);
      Inc(Total, N);
    end;
    if Total <> Size then
      raise EReadError.Create('Truncated ZIP member');
  finally
    Input.Free;
  end;
end;

function OpenZip(Input: TStream; const Storage: IStorage): IArchiveContainer;
begin
  Result := TZipContainer.Create(Input, Storage);
end;

end.

