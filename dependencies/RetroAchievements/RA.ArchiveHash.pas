unit RA.ArchiveHash;

interface

uses
  System.Classes;

type
  // Return a stream owned by the caller of this callback, or nil if the file is absent.
  TRAOpenArchive = reference to function(const Path: string): TStream;

// The current stream position is the start of the archive and is preserved.
function TryHashRAArduboyFX(Stream: TStream; out Digest: string): Boolean;

function TryHashRADOSZ(const Path: string; out Digest: string; const OpenArchive: TRAOpenArchive = nil): Boolean; overload;

// The stream belongs to the caller. OpenArchive supplies any parents and overlays.
function TryHashRADOSZ(const Path: string; Stream: TStream; out Digest: string; const OpenArchive: TRAOpenArchive = nil): Boolean; overload;

implementation

uses
  System.Generics.Collections, System.Generics.Defaults, System.Hash,
  System.Math, System.SysUtils, RA.Streams;

{$SCOPEDENUMS ON}

const
  EndSignature = $06054B50;
  Locator64Signature = $07064B50;
  End64Signature = $06064B50;
  FileSignature = $02014B50;
  EndSize = 22;
  Locator64Size = 20;
  End64Size = 56;
  FileHeaderSize = 46;
  LocalHeaderSize = 30;
  MaxDirectorySize = $10000000;

type
  TRAArchiveKind = (ArduboyFX, DOSZ, DOSC);

  TRAZipHashEntry = record
    Offset, Size: Integer;
  end;

  TRAZipArchive = record
    Data: TBytes;
    Entries: TArray<TRAZipHashEntry>;
    ParentName: string;
  end;

function ReadLE16(P: PByte): Word;
begin
  Result := Word(P[0]) or (Word(P[1]) shl 8);
end;

function ReadLE32(P: PByte): Cardinal;
begin
  Result := Cardinal(ReadLE16(P)) or (Cardinal(ReadLE16(P + 2)) shl 16);
end;

function ReadLE64(P: PByte): UInt64;
begin
  Result := UInt64(ReadLE32(P)) or (UInt64(ReadLE32(P + 4)) shl 32);
end;

procedure WriteLE(P: PByte; Value: UInt64; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    P[I] := Byte(Value and $FF);
    Value := Value shr 8;
  end;
end;

function DirectRead(Stream: TStream; Position: Int64; var Buffer; Count: Integer): Boolean;
begin
  Stream.Position := Position;
  Result := ReadRAStream(Stream, Buffer, Count) = Count;
end;

function FindDirectory(Stream: TStream; Start, ArchiveSize: Int64; out Offset, Size, Count: UInt64): Boolean;
var
  Buffer: array[0..2047] of Byte;
  EndOffset, Scan: Int64;
  Index, ReadSize: Integer;
  End64Offset: UInt64;
begin
  if ArchiveSize < EndSize then
    Exit(False);

  Scan := Max(Int64(0), ArchiveSize - SizeOf(Buffer));
  ReadSize := Integer(Min(ArchiveSize, Int64(SizeOf(Buffer))));
  repeat
    if not DirectRead(Stream, Start + Scan, Buffer, ReadSize) then
      Exit(False);
    Index := ReadSize - SizeOf(Cardinal);
    while (Index >= 0) and (ReadLE32(@Buffer[Index]) <> EndSignature) do
      Dec(Index);
    if Index >= 0 then
      Break;

    if (Scan = 0) or (ArchiveSize - Scan >= $FFFF + EndSize) then
      Exit(False);
    Scan := Max(Int64(0), Scan - (SizeOf(Buffer) - 3));
  until False;

  EndOffset := Scan + Index;
  if (EndOffset > ArchiveSize - EndSize) or
    not DirectRead(Stream, Start + EndOffset, Buffer, EndSize) then
    Exit(False);
  Count := ReadLE16(@Buffer[$0A]);
  Size := ReadLE32(@Buffer[$0C]);
  Offset := ReadLE32(@Buffer[$10]);

  if ((Count = High(Word)) or (Size = High(Cardinal)) or (Offset = High(Cardinal))) and
    (EndOffset >= Locator64Size + End64Size) and
    DirectRead(Stream, Start + EndOffset - Locator64Size, Buffer, Locator64Size) and
    (ReadLE32(@Buffer[0]) = Locator64Signature) then
  begin
    End64Offset := ReadLE64(@Buffer[$08]);
    if (End64Offset <= UInt64(ArchiveSize - End64Size)) and
      DirectRead(Stream, Start + Int64(End64Offset), Buffer, End64Size) and
      (ReadLE32(@Buffer[0]) = End64Signature) then
    begin
      Count := ReadLE64(@Buffer[$20]);
      Size := ReadLE64(@Buffer[$28]);
      Offset := ReadLE64(@Buffer[$30]);
    end;
  end;

  Result := (Size < MaxDirectorySize) and (Count <= Size div FileHeaderSize) and
    (Offset <= UInt64(ArchiveSize)) and (Size <= UInt64(ArchiveSize) - Offset);
end;

function ReadZip64Extra(P: PByte; ExtraSize: Integer; var FileSize, CompressedSize, LocalOffset: UInt64): Boolean;

  function ReadFieldValue(var Field: PByte; var Remaining: Integer; var Value: UInt64): Boolean;
  begin
    if Value <> High(Cardinal) then
      Exit(True);
    if Remaining < SizeOf(UInt64) then
      Exit(False);
    Value := ReadLE64(Field);
    Inc(Field, SizeOf(UInt64));
    Dec(Remaining, SizeOf(UInt64));
    Result := True;
  end;

var
  Tag: Word;
  FieldSize: Integer;
begin
  if (FileSize <> High(Cardinal)) and (CompressedSize <> High(Cardinal)) and
    (LocalOffset <> High(Cardinal)) then
    Exit(True);

  while ExtraSize > 4 do
  begin
    Tag := ReadLE16(P);
    FieldSize := ReadLE16(P + 2);
    Inc(P, 4);
    Dec(ExtraSize, 4);
    if FieldSize > ExtraSize then
      Break;
    if Tag = 1 then
      Exit(ReadFieldValue(P, FieldSize, FileSize) and ReadFieldValue(P, FieldSize, CompressedSize) and
        ReadFieldValue(P, FieldSize, LocalOffset));
    Inc(P, FieldSize);
    Dec(ExtraSize, FieldSize);
  end;
  Result := True;
end;

function LowerASCII(Value: Byte): Byte;
begin
  if Value in [Ord('A')..Ord('Z')] then
    Result := Value or $20
  else
    Result := Value;
end;

function HasSuffix(Name: PByte; NameSize: Integer; const Suffix: AnsiString): Boolean;
begin
  if NameSize <= Length(Suffix) then
    Exit(False);
  Inc(Name, NameSize - Length(Suffix));
  for var I := 0 to Length(Suffix) - 1 do
    if LowerASCII(Name[I]) <> Byte(Suffix[I + 1]) then
      Exit(False);
  Result := True;
end;

function IsParentMarker(Name: PByte; NameSize: Integer; FileSize: UInt64): Boolean;
begin
  if (FileSize <> 0) or not HasSuffix(Name, NameSize, '.parent') then
    Exit(False);
  for var I := 0 to NameSize - 1 do
    if Name[I] in [Ord('/'), Ord('\')] then
      Exit(False);
  Result := True;
end;

function ReadDirectory(Stream: TStream; Kind: TRAArchiveKind; out Archive: TRAZipArchive): Boolean;
var
  Start, ArchiveSize: Int64;
  Offset, Size, Count, FileSize, CompressedSize, LocalOffset: UInt64;
  Index, SourceOffset, DestOffset, UsedCount, NameSize, ExtraSize, EntrySize: Integer;
  Header, Name, Dest: PByte;
  CRC: Cardinal;
  Parent: UTF8String;
begin
  if Stream = nil then
    Exit(False);
  Start := Stream.Position;
  try
    try
      ArchiveSize := Stream.Size - Start;
      if not FindDirectory(Stream, Start, ArchiveSize, Offset, Size, Count) then
        Exit(False);

      SetLength(Archive.Data, Integer(Size));
      SetLength(Archive.Entries, Integer(Count));
      if Size <> 0 then
        if not DirectRead(Stream, Start + Int64(Offset), Archive.Data[0], Integer(Size)) then
          Exit(False);

      SourceOffset := 0;
      DestOffset := 0;
      UsedCount := 0;
      for Index := 0 to Integer(Count) - 1 do
      begin
        if SourceOffset > Integer(Size) - FileHeaderSize then
          Break;
        Header := @Archive.Data[SourceOffset];
        if ReadLE32(Header) <> FileSignature then
          Break;
        NameSize := ReadLE16(Header + $1C);
        ExtraSize := ReadLE16(Header + $1E);
        EntrySize := FileHeaderSize + NameSize + ExtraSize + ReadLE16(Header + $20);
        if EntrySize > Integer(Size) - SourceOffset then
          Exit(False);
        Inc(SourceOffset, EntrySize);

        Name := Header + FileHeaderSize;
        if (NameSize = 0) or (Name[NameSize - 1] in [Ord('/'), Ord('\')]) or
          ((ReadLE16(Header + $26) and $10) <> 0) then
          Continue;

        CRC := ReadLE32(Header + $10);
        CompressedSize := ReadLE32(Header + $14);
        FileSize := ReadLE32(Header + $18);
        LocalOffset := ReadLE32(Header + $2A);
        if not ReadZip64Extra(Name + NameSize, ExtraSize, FileSize, CompressedSize, LocalOffset) then
          Exit(False);
        if ((ReadLE16(Header + $0A) = 0) and (FileSize <> CompressedSize)) or
          ((FileSize <> 0) and (CompressedSize = 0)) or (ArchiveSize < LocalHeaderSize) or
          (LocalOffset > UInt64(ArchiveSize - LocalHeaderSize)) or
          (CompressedSize > UInt64(ArchiveSize - LocalHeaderSize) - LocalOffset) then
          Exit(False);

        case Kind of
          TRAArchiveKind.ArduboyFX:
            if not HasSuffix(Name, NameSize, '.hex') and not HasSuffix(Name, NameSize, '.bin') then
              Continue;
          TRAArchiveKind.DOSZ:
            if IsParentMarker(Name, NameSize, FileSize) then
            begin
              if Archive.ParentName <> '' then
                Exit(False);
              SetString(Parent, PAnsiChar(Name), NameSize - Length('.parent'));
              Archive.ParentName := UTF8ToString(Parent);
              if (Archive.ParentName = '') or Archive.ParentName.Contains(#0) then
                Exit(False);
              Continue;
            end;
        end;

        // Compact each entry to the bytes rcheevos hashes. The result fits before the next header.
        Dest := @Archive.Data[DestOffset];
        for var I := 0 to NameSize - 1 do
          if Name[I] = Ord('\') then
            Dest[I] := Ord('/')
          else
            Dest[I] := LowerASCII(Name[I]);
        Dest[NameSize] := 0;
        WriteLE(Dest + NameSize + 1, CRC, SizeOf(CRC));
        WriteLE(Dest + NameSize + 1 + SizeOf(CRC), FileSize, SizeOf(FileSize));
        Archive.Entries[UsedCount].Offset := DestOffset;
        Archive.Entries[UsedCount].Size := NameSize + 1 + SizeOf(CRC) + SizeOf(FileSize);
        Inc(DestOffset, Archive.Entries[UsedCount].Size);
        Inc(UsedCount);
      end;

      SetLength(Archive.Entries, UsedCount);
      SetLength(Archive.Data, DestOffset);
      Result := True;
    except
      on EStreamError do
        Result := False;
    end;
  finally
    Stream.Position := Start;
  end;
end;

procedure AppendDirectory(var Archive: TRAZipArchive; var Hash: THashMD5);
var
  Data: TBytes;
begin
  Data := Archive.Data;
  TArray.Sort<TRAZipHashEntry>(Archive.Entries, TComparer<TRAZipHashEntry>.Construct(
    function(const Left, Right: TRAZipHashEntry): Integer
    begin
      for var I := 0 to Min(Left.Size, Right.Size) - 1 do
        if Data[Left.Offset + I] <> Data[Right.Offset + I] then
          Exit(Integer(Data[Left.Offset + I]) - Integer(Data[Right.Offset + I]));
      Result := 0;
    end));
  for var Entry in Archive.Entries do
    Hash.Update(Data[Entry.Offset], Entry.Size);
end;

function OpenFile(const Path: string; const OpenArchive: TRAOpenArchive): TStream;
begin
  try
    if Assigned(OpenArchive) then
      Result := OpenArchive(Path)
    else
      Result := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  except
    on EFOpenError do
      Result := nil;
  end;
end;

function AppendOverlay(const Path: string; const OpenArchive: TRAOpenArchive; var Hash: THashMD5): Boolean;
var
  OverlayPath: string;
  Stream: TStream;
  Archive: TRAZipArchive;
begin
  if Path.EndsWith('z') then
    OverlayPath := Copy(Path, 1, Length(Path) - 1) + 'c'
  else if Path.EndsWith('Z') then
    OverlayPath := Copy(Path, 1, Length(Path) - 1) + 'C'
  else
    Exit(True);

  Stream := OpenFile(OverlayPath, OpenArchive);
  if Stream = nil then
    Exit(True);
  try
    Result := ReadDirectory(Stream, TRAArchiveKind.DOSC, Archive);
    if Result then
      AppendDirectory(Archive, Hash);
  finally
    Stream.Free;
  end;
end;

function TryHashRAArduboyFX(Stream: TStream; out Digest: string): Boolean;
var
  Archive: TRAZipArchive;
  Hash: THashMD5;
begin
  Digest := '';
  if not ReadDirectory(Stream, TRAArchiveKind.ArduboyFX, Archive) then
    Exit(False);
  Hash := THashMD5.Create;
  AppendDirectory(Archive, Hash);
  Digest := LowerCase(Hash.HashAsString);
  Result := True;
end;

function TryHashRADOSZ(const Path: string; Stream: TStream; out Digest: string; const OpenArchive: TRAOpenArchive): Boolean;
var
  Archive, Parent: TRAZipArchive;
  ParentPath: string;
  ParentStream: TStream;
  Hash: THashMD5;
begin
  Digest := '';
  if not ReadDirectory(Stream, TRAArchiveKind.DOSZ, Archive) then
    Exit(False);

  Hash := THashMD5.Create;
  if Archive.ParentName <> '' then
  begin
    ParentPath := Copy(Path, 1, LastDelimiter('/\', Path)) + Archive.ParentName;
    if ParentPath = Path then
      Exit(False);
    ParentStream := OpenFile(ParentPath, OpenArchive);
    if ParentStream = nil then
      Exit(False);
    try
      // rcheevos v12.5.0 copies the parent count into the parent archive's state.
      if not ReadDirectory(ParentStream, TRAArchiveKind.DOSZ, Parent) or (Parent.ParentName <> '') then
        Exit(False);
      AppendDirectory(Parent, Hash);
    finally
      ParentStream.Free;
    end;
    if not AppendOverlay(ParentPath, OpenArchive, Hash) then
      Exit(False);
  end;

  AppendDirectory(Archive, Hash);
  if not AppendOverlay(Path, OpenArchive, Hash) then
    Exit(False);
  Digest := LowerCase(Hash.HashAsString);
  Result := True;
end;

function TryHashRADOSZ(const Path: string; out Digest: string; const OpenArchive: TRAOpenArchive): Boolean;
var
  Stream: TStream;
begin
  Stream := OpenFile(Path, OpenArchive);
  try
    Result := TryHashRADOSZ(Path, Stream, Digest, OpenArchive);
  finally
    Stream.Free;
  end;
end;

end.

