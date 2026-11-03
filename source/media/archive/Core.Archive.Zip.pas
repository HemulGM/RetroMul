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
  TZipContainer = class(TArchiveContainer)
  private
    FPacked: string;
    FInput: TStream;
    FZip: TZipFile;
  protected
    procedure Extract(Index: Integer; Output: TStream); override;
  public
    constructor Create(Input: TStream; const Storage: IStorage);
    destructor Destroy; override;
  end;

function IsZipArchive(Input: TStream): Boolean;
begin
  Result := ArchiveSignatureMatches(Input, [$50, $4B, $03, $04]) or
    ArchiveSignatureMatches(Input, [$50, $4B, $05, $06]);
end;

// Bound central-directory allocations before RTL constructs its file array.
procedure CheckZipDirectory(Input: TStream);
const
  MaxDirectoryBytes = 64 * 1024 * 1024;
begin
  var TailSize := Input.Size;
  if TailSize > 65557 then TailSize := 65557;
  if TailSize < 22 then raise EReadError.Create('Truncated ZIP directory');
  var Tail: TBytes;
  SetLength(Tail, TailSize);
  Input.Position := Input.Size - TailSize;
  Input.ReadBuffer(Tail[0], Length(Tail));
  var Found := False;
  var EndHeader: TZipEndOfCentralHeader;
  var EndPosition: Int64 := 0;
  for var I := Length(Tail) - 22 downto 0 do
    if (Tail[I] = $50) and (Tail[I + 1] = $4B) and (Tail[I + 2] = $05) and (Tail[I + 3] = $06) then
    begin
      Move(Tail[I + 4], EndHeader, SizeOf(EndHeader));
      if I + 22 + EndHeader.CommentLength <> Length(Tail) then Continue;
      EndPosition := Input.Size - TailSize + I;
      Found := True;
      Break;
    end;
  if not Found then raise EReadError.Create('Missing ZIP directory');
  var Count := UInt64(EndHeader.CentralDirEntries);
  var Offset := UInt64(EndHeader.CentralDirOffset);
  var Bytes := UInt64(EndHeader.CentralDirSize);
  if (EndHeader.DiskNumber = $FFFF) or (EndHeader.CentralDirStartDisk = $FFFF) or
    (EndHeader.NumEntriesThisDisk = $FFFF) or (Count = $FFFF) or
    (Offset = $FFFFFFFF) or (Bytes = $FFFFFFFF) then
  begin
    if EndPosition < SizeOf(TZip64EndOfCentralHeader) then raise EReadError.Create('Truncated ZIP64 locator');
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
  var NameBytes: UInt64 := 0;
  Input.Position := Offset;
  for var I := UInt64(1) to Count do
  begin
    TStorage.CheckReadCancelled;
    var Fixed: array[0..45] of Byte;
    if UInt64(Input.Position) > Last then raise EReadError.Create('Invalid ZIP directory offset');
    if Last - UInt64(Input.Position) < SizeOf(Fixed) then raise EReadError.Create('Truncated ZIP member header');
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
    begin TrackCacheFile(Path); end);
  FInput := FStorage.OpenRead(FPacked);
  CheckZipDirectory(FInput);
  FZip := TZipFile.Create;
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

