unit RA.DiscHash;

interface

{$SCOPEDENUMS ON}

uses
  System.Classes;

type
  TRADiscConsole = (PlayStation, PlayStation2, PlayStationPortable, SegaCD, Saturn,
    Dreamcast, PCEngineCD, PCFX, NeoGeoCD, ThreeDO, JaguarCD, PlayStation3);

  // Read up to Count user bytes starting at Sector. Return the number actually read.
  TRADiscRead = reference to function(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;

  TRADiscTrack = record
    FirstSector: Cardinal;
    Read: TRADiscRead;
  end;

  // The selector accepts a track number or one of the values below.
  // Track.Read receives absolute sectors and exposes raw 2352-byte Jaguar CD sectors.
  TRAOpenDiscTrack = reference to function(TrackNumber: Cardinal; out Track: TRADiscTrack): Boolean;

const
  RAFirstDataTrack = High(Cardinal);
  RALastTrack = High(Cardinal) - 1;
  RALargestTrack = High(Cardinal) - 2;
  RASecondSessionTrack = High(Cardinal) - 3;

// Single-track input, with 2048-byte user sectors numbered from zero.
function TryHashRADisc(Console: TRADiscConsole; const ReadSector: TRADiscRead; out Digest: string): Boolean; overload;

function TryHashRADisc(Console: TRADiscConsole; const OpenTrack: TRAOpenDiscTrack; out Digest: string): Boolean; overload;

// Read a GameCube image from the current stream position and preserve that position.
function TryHashRAGameCube(Stream: TStream; out Digest: string): Boolean;

// Read a Wii disc image or a WiiWare WAD from the current stream position and preserve that position.
function TryHashRAWii(Stream: TStream; out Digest: string): Boolean;

implementation

uses
  System.Generics.Collections, System.Hash, System.Math, System.SysUtils,
  RA.Streams;

const
  SectorSize = 2048;
  MaxFileHashSize = 64 * 1024 * 1024;
  MaxDirectorySectors = 4096;

type
  TRASector = array[0..SectorSize - 1] of Byte;

  TRAExtent = record
    LBA, Size: Cardinal;
  end;

function ReadLE32(const Buffer: TRASector; Offset: Integer): Cardinal;
begin
  Result := Cardinal(Buffer[Offset]) or (Cardinal(Buffer[Offset + 1]) shl 8) or
    (Cardinal(Buffer[Offset + 2]) shl 16) or (Cardinal(Buffer[Offset + 3]) shl 24);
end;

function FindEntry(const ReadSector: TRADiscRead; DirectorySector, Sectors: Cardinal; const Name: AnsiString; out Entry: TRAExtent): Boolean;
var
  Buffer: TRASector;
  Offset, Count, LengthOfRecord, LengthOfName, NameLength: Integer;
  Sector, Received: Cardinal;
  EntryName: AnsiString;
begin
  if (Sectors > MaxDirectorySectors) or (UInt64(DirectorySector) + Sectors > High(Cardinal)) then
    Exit(False);
  NameLength := Length(Name);
  for Sector := DirectorySector to DirectorySector + Sectors - 1 do
  begin
    Received := ReadSector(Sector, @Buffer[0], SectorSize);
    if (Received = 0) or (Received > SectorSize) then
      Exit(False);
    Count := Integer(Received);
    Offset := 0;
    while Offset < Count do
    begin
      LengthOfRecord := Buffer[Offset];
      if LengthOfRecord = 0 then
        Break;
      if (LengthOfRecord < 33) or (LengthOfRecord > Count - Offset) then
        Exit(False);
      LengthOfName := Buffer[Offset + 32];
      if LengthOfName > LengthOfRecord - 33 then
        Exit(False);
      if (NameLength > 0) and (NameLength <= LengthOfName) and
        ((NameLength = LengthOfName) or (Buffer[Offset + 33 + NameLength] = Ord(';'))) then
      begin
        SetString(EntryName, PAnsiChar(@Buffer[Offset + 33]), NameLength);
        if SameText(string(EntryName), string(Name)) then
        begin
          Entry.LBA := ReadLE32(Buffer, Offset + 2) and $FFFFFF;
          Entry.Size := ReadLE32(Buffer, Offset + 10);
          Exit(Entry.LBA <> 0);
        end;
      end;
      Inc(Offset, LengthOfRecord);
    end;
  end;
  Result := False;
end;

function FindISOFile(const ReadSector: TRADiscRead; const Path: AnsiString; out Entry: TRAExtent; FirstSector: Cardinal = 0): Boolean;
const
  PVDPrefixSize = 256;
  RootRecordEnd = 170;
var
  Buffer: TRASector;
  PathParts: TArray<string>;
  PathStart: Integer;
  DirectorySector, Sectors, LogicalBlockSize, Received: Cardinal;
begin
  if FirstSector > High(Cardinal) - 16 then
    Exit(False);
  Received := ReadSector(FirstSector + 16, @Buffer[0], PVDPrefixSize);
  if (Received < RootRecordEnd) or (Received > PVDPrefixSize) then
    Exit(False);
  DirectorySector := ReadLE32(Buffer, 158) and $FFFFFF;
  if DirectorySector = 0 then
    Exit(False);
  LogicalBlockSize := Cardinal(Buffer[128]) or (Cardinal(Buffer[129]) shl 8);
  Sectors := 1;
  if LogicalBlockSize <> 0 then
    Sectors := Max(Cardinal(1), ReadLE32(Buffer, 166) div LogicalBlockSize);
  PathStart := 1;
  if (Path <> '') and (Path[1] = '\') then
    Inc(PathStart);
  PathParts := string(Copy(Path, PathStart, MaxInt)).Split(['\']);
  for var Part in PathParts do
  begin
    if not FindEntry(ReadSector, DirectorySector, Sectors, AnsiString(Part), Entry) then
      Exit(False);
    DirectorySector := Entry.LBA;
    // rcheevos only scans multiple sectors for the root directory.
    Sectors := 1;
  end;
  Result := True;
end;

function ReadBootName(const ReadSector: TRADiscRead; const Key, Prefix: AnsiString; out BootName: AnsiString; FirstSector: Cardinal): Boolean;
var
  Extent: TRAExtent;
  Buffer: TRASector;
  Text: AnsiString;
  Count, Position, NameStart: Integer;
begin
  BootName := '';
  if not FindISOFile(ReadSector, 'SYSTEM.CNF', Extent, FirstSector) then
    Exit(False);
  Count := ReadSector(Extent.LBA, @Buffer[0], SectorSize - 1);
  if (Count <= 0) or (Count > SectorSize - 1) then
    Exit(False);
  Buffer[Count] := 0;
  Text := AnsiString(PAnsiChar(@Buffer[0]));

  Position := 1;
  while Position <= Length(Text) do
  begin
    if Copy(Text, Position, Length(Key)) = Key then
    begin
      Inc(Position, Length(Key));
      while (Position <= Length(Text)) and CharInSet(Text[Position], [#9..#13, ' ']) do
        Inc(Position);
      if (Position <= Length(Text)) and (Text[Position] = '=') then
      begin
        Inc(Position);
        while (Position <= Length(Text)) and CharInSet(Text[Position], [#9..#13, ' ']) do
          Inc(Position);
        if Copy(Text, Position, Length(Prefix)) = Prefix then
          Inc(Position, Length(Prefix));
        while (Position <= Length(Text)) and (Text[Position] = '\') do
          Inc(Position);
        NameStart := Position;
        while (Position <= Length(Text)) and not CharInSet(Text[Position], [#9..#13, ' ', ';']) do
          Inc(Position);
        BootName := Copy(Text, NameStart, Min(63, Position - NameStart));
        Exit(BootName <> '');
      end;
    end;
    while (Position <= Length(Text)) and (Text[Position] <> #10) do
      Inc(Position);
    Inc(Position);
  end;
  Result := False;
end;

function AppendExtent(var Hash: THashMD5; const ReadSector: TRADiscRead; const Extent: TRAExtent; AllowPartialTail: Boolean = False): Boolean;
var
  Buffer: TRASector;
  Count, Requested, Remaining, Sector: Cardinal;
begin
  Remaining := Min(Extent.Size, Cardinal(MaxFileHashSize));
  Sector := Extent.LBA;
  // The shared CD file routine requires a full first sector, then hashes the bytes it can read.
  if AllowPartialTail then
    Requested := SectorSize
  else
    Requested := Min(Remaining, Cardinal(SectorSize));
  if Requested = 0 then
    Exit(True);
  Count := ReadSector(Sector, @Buffer[0], Requested);
  if Count <> Requested then
    Exit(False);

  while (Remaining <> 0) and (Count <> 0) do
  begin
    Count := Min(Count, Remaining);
    Hash.Update(Buffer[0], Count);
    Dec(Remaining, Count);
    if Remaining = 0 then
      Break;
    if Sector = High(Cardinal) then
      Exit(False);
    Inc(Sector);
    Requested := Min(Remaining, Cardinal(SectorSize));
    Count := ReadSector(Sector, @Buffer[0], Requested);
    if (Count > Requested) or (not AllowPartialTail and (Count <> Requested)) then
      Exit(False);
  end;
  Result := True;
end;

function HashPlayStation(var Hash: THashMD5; Console: TRADiscConsole; const Track: TRADiscTrack): Boolean;
var
  Name: AnsiString;
  Extent: TRAExtent;
  Header: TRASector;
  Size: Cardinal;
begin
  if Console = TRADiscConsole.PlayStation then
  begin
    if not ReadBootName(Track.Read, 'BOOT', 'cdrom:', Name, Track.FirstSector) or not FindISOFile(Track.Read, Name, Extent, Track.FirstSector) then
    begin
      Name := 'PSX.EXE';
      if not FindISOFile(Track.Read, Name, Extent, Track.FirstSector) then
        Exit(False);
    end;
    if Track.Read(Extent.LBA, @Header[0], 32) <> 32 then
      Exit(False);
    if CompareMem(@Header[0], PAnsiChar(AnsiString('PS-X EXE')), 7) then
    begin
      Size := ReadLE32(Header, 28);
      Extent.Size := Cardinal((UInt64(Size) + SectorSize) and High(Cardinal));
    end;
  end
  else
  begin
    if not ReadBootName(Track.Read, 'BOOT2', 'cdrom0:', Name, Track.FirstSector) or not FindISOFile(Track.Read, Name, Extent, Track.FirstSector) then
      Exit(False);
    if Track.Read(Extent.LBA, @Header[0], 4) <> 4 then
      Exit(False);
  end;
  Hash.Update(Name[1], Length(Name));
  Result := AppendExtent(Hash, Track.Read, Extent, True);
end;

function ReadBE24(Buffer: PByte; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(Buffer[Offset]) shl 16) or
    (Cardinal(Buffer[Offset + 1]) shl 8) or Buffer[Offset + 2];
end;

function ReadBE32(Buffer: PByte; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(Buffer[Offset]) shl 24) or ReadBE24(Buffer, Offset + 1);
end;

function OpenHashTrack(const OpenTrack: TRAOpenDiscTrack; Number: Cardinal; out Track: TRADiscTrack): Boolean;
begin
  Track := Default(TRADiscTrack);
  Result := OpenTrack(Number, Track) and Assigned(Track.Read);
end;

function ReadTrackHeader(const Track: TRADiscTrack; Offset: Cardinal; var Buffer: TRASector; Count: Cardinal): Boolean;
begin
  Result := (Offset <= High(Cardinal) - Track.FirstSector) and
    (Track.Read(Track.FirstSector + Offset, @Buffer[0], Count) = Count);
end;

function HashDreamcast(var Hash: THashMD5; const OpenTrack: TRAOpenDiscTrack): Boolean;
const
  Signature: AnsiString = 'SEGA SEGAKATANA ';
  HeaderSize = 256;
var
  Track: TRADiscTrack;
  Buffer: TRASector;
  Name: AnsiString;
  NameLength: Integer;
  ProgramFile: TRAExtent;
  Probe: Byte;

  function OpenHeader(Number: Cardinal): Boolean;
  var
    Count: Cardinal;
  begin
    if not OpenHashTrack(OpenTrack, Number, Track) then
      Exit(False);
    Count := Track.Read(Track.FirstSector, @Buffer[0], HeaderSize);
    Result := (Count <= HeaderSize) and
      CompareMem(@Buffer[0], PAnsiChar(Signature), Length(Signature));
  end;

begin
  // rcheevos starts with a zeroed buffer and reuses it for the first-data-track fallback.
  FillChar(Buffer[0], HeaderSize, 0);
  if not OpenHeader(3) and not OpenHeader(RAFirstDataTrack) then
    Exit(False);

  NameLength := 0;
  while (NameLength < 16) and (Buffer[96 + NameLength] > 32) do
    Inc(NameLength);
  if NameLength = 0 then
    Exit(False);
  SetString(Name, PAnsiChar(@Buffer[96]), NameLength);
  if not FindISOFile(Track.Read, Name, ProgramFile, Track.FirstSector) then
    Exit(False);

  Hash.Update(Buffer[0], HeaderSize);
  if (Track.Read(ProgramFile.LBA, @Probe, 1) <> 1) and not OpenHashTrack(OpenTrack, RALastTrack, Track) then
    Exit(False);
  Result := AppendExtent(Hash, Track.Read, ProgramFile, True);
end;

function AppendBufferedDiscData(var Hash: THashMD5; const Track: TRADiscTrack; Sector, Remaining: UInt64; var Buffer: TRASector): Boolean;
var
  Requested: Cardinal;
begin
  if (Remaining <> 0) and ((Sector > High(Cardinal)) or
    ((Remaining - 1) div SectorSize > High(Cardinal) - Sector)) then
    Exit(False);
  while Remaining <> 0 do
  begin
    Requested := Cardinal(Min(Remaining, UInt64(SectorSize)));
    if Track.Read(Cardinal(Sector), @Buffer[0], Requested) > Requested then
      Exit(False);
    // These rcheevos hashers retain the previous bytes beyond a short read.
    Hash.Update(Buffer[0], Requested);
    Inc(Sector);
    Dec(Remaining, Requested);
  end;
  Result := True;
end;

function IsPCEHeader(const Buffer: TRASector): Boolean;
const
  Signature: AnsiString = 'PC Engine CD-ROM SYSTEM';
begin
  Result := CompareMem(@Buffer[32], PAnsiChar(Signature), Length(Signature));
end;

function HashPCECD(var Hash: THashMD5; const Track: TRADiscTrack): Boolean;
var
  Buffer: TRASector;
  ProgramFile: TRAExtent;
begin
  Buffer := Default(TRASector);
  if not ReadTrackHeader(Track, 1, Buffer, 128) then
    Exit(False);
  if IsPCEHeader(Buffer) then
  begin
    Hash.Update(Buffer[106], 22);
    Buffer[128] := 0;
    Exit(AppendBufferedDiscData(Hash, Track, UInt64(Track.FirstSector) + ReadBE24(@Buffer[0], 0),
        UInt64(Buffer[3]) * SectorSize, Buffer));
  end;
  // GameExpress discs load BOOT.BIN from the disc filesystem.
  Result := FindISOFile(Track.Read, 'BOOT.BIN', ProgramFile, Track.FirstSector) and
    (ProgramFile.Size < MaxFileHashSize) and
    AppendBufferedDiscData(Hash, Track, ProgramFile.LBA, ProgramFile.Size, Buffer);
end;

function HashPCFX(var Hash: THashMD5; const OpenTrack: TRAOpenDiscTrack): Boolean;
const
  Signature: AnsiString = 'PC-FX:Hu_CD-ROM';
var
  Track: TRADiscTrack;
  Buffer: TRASector;

  function ReadMarker: Boolean;
  var
    Count: Cardinal;
  begin
    Count := Track.Read(Track.FirstSector, @Buffer[0], 32);
    Result := (Count >= Cardinal(Length(Signature))) and (Count <= 32) and
      CompareMem(@Buffer[0], PAnsiChar(Signature), Length(Signature));
  end;

begin
  Buffer := Default(TRASector);
  if not OpenHashTrack(OpenTrack, RALargestTrack, Track) then
    Exit(False);
  if not ReadMarker then
  begin
    if not OpenHashTrack(OpenTrack, 2, Track) then
      Exit(False);
    if not ReadMarker then
      Exit(ReadTrackHeader(Track, 1, Buffer, 128) and IsPCEHeader(Buffer) and HashPCECD(Hash, Track));
  end;
  if not ReadTrackHeader(Track, 1, Buffer, 128) then
    Exit(False);
  Hash.Update(Buffer[0], 128);
  Result := AppendBufferedDiscData(Hash, Track, UInt64(Track.FirstSector) + (ReadLE32(Buffer, 32) and $FFFFFF),
    UInt64(ReadLE32(Buffer, 36) and $FFFFFF) * SectorSize, Buffer);
end;

function HashNeoGeoCD(var Hash: THashMD5; const Track: TRADiscTrack): Boolean;
var
  Buffer: array[0..1023] of AnsiChar;
  ListFile, ProgramFile: TRAExtent;
  Name: AnsiString;
  Count: Cardinal;
  Position, NameStart, Limit: Integer;
begin
  if not FindISOFile(Track.Read, 'IPL.TXT', ListFile, Track.FirstSector) then
    Exit(False);
  Count := Track.Read(ListFile.LBA, @Buffer[0], SizeOf(Buffer));
  if (Count = 0) or (Count > SizeOf(Buffer)) then
    Exit(False);

  // The final byte is reserved for the terminator in rcheevos.
  Limit := Min(Integer(Count), High(Buffer));
  Position := 0;
  repeat
    NameStart := Position;
    while (Position < Limit) and not (Buffer[Position] in [#0, '.']) do
      Inc(Position);
    if (Position + 3 < Limit) and (Buffer[Position] = '.') and
      (UpCase(Buffer[Position + 1]) = 'P') and (UpCase(Buffer[Position + 2]) = 'R') and
      (UpCase(Buffer[Position + 3]) = 'G') then
    begin
      Inc(Position, 4);
      SetString(Name, PAnsiChar(@Buffer[NameStart]), Position - NameStart);
      // The C parser replaces the byte after .PRG with a terminator and advances past it.
      Inc(Position);
      if not FindISOFile(Track.Read, Name, ProgramFile, Track.FirstSector) or
        not AppendExtent(Hash, Track.Read, ProgramFile, True) then
        Exit(False);
    end;

    while (Position < Limit) and not (Buffer[Position] in [#0, #10]) do
      Inc(Position);
    if (Position >= Limit) or (Buffer[Position] <> #10) then
      Break;
    Inc(Position);
  until (Position >= Limit) or (Buffer[Position] in [#0, #26]);
  Result := True;
end;

function HashThreeDO(var Hash: THashMD5; const Track: TRADiscTrack): Boolean;
const
  Signature: array[0..6] of Byte = ($01, $5A, $5A, $5A, $5A, $5A, $01);
var
  Buffer: TRASector;
  BlockSize, NextBlock, Count: Cardinal;
  DirectoryPosition, Sector: UInt64;
  Offset, Stop, NameLength: Integer;
  Name: AnsiString;
  Visited: TList<Cardinal>;
begin
  Buffer := Default(TRASector);
  if (Track.Read(0, @Buffer[0], 132) <> 132) or not CompareMem(@Buffer[0], @Signature[0], Length(Signature)) then
    Exit(False);
  Hash.Update(Buffer[0], 132);
  BlockSize := ReadBE24(@Buffer[0], $4D);
  if BlockSize = 0 then
    Exit(False);
  DirectoryPosition := UInt64(ReadBE24(@Buffer[0], $65)) * BlockSize;
  Sector := DirectoryPosition div SectorSize;
  Visited := TList<Cardinal>.Create;
  try
    while (Sector <= High(Cardinal)) and (Visited.Count < MaxDirectorySectors) and
    not Visited.Contains(Cardinal(Sector)) do
    begin
      Visited.Add(Cardinal(Sector));
      Count := Track.Read(Cardinal(Sector), @Buffer[0], SectorSize);
      if (Count < $14) or (Count > SectorSize) then
        Exit(False);
      Offset := Buffer[$12] * 256 + Buffer[$13];
      Stop := Integer(ReadBE24(@Buffer[0], $0D));
      if (Offset > Stop) or (Stop > SectorSize) then
        Exit(False);
      while Offset < Stop do
      begin
        if (Offset > Integer(Count) - $48) or (Stop - Offset < $48) then
          Exit(False);
        if Buffer[Offset + 3] = 2 then
        begin
          NameLength := 0;
          while (NameLength < 32) and (Buffer[Offset + $20 + NameLength] <> 0) do
            Inc(NameLength);
          SetString(Name, PAnsiChar(@Buffer[Offset + $20]), NameLength);
          if SameText(string(Name), 'LaunchMe') then
          begin
            Sector := UInt64(ReadBE24(@Buffer[0], Offset + $45)) *
              ReadBE24(@Buffer[0], Offset + $0D) div SectorSize;
            var ProgramSize := ReadBE24(@Buffer[0], Offset + $11);
            Exit((ProgramSize <> 0) and AppendBufferedDiscData(Hash, Track, Sector, ProgramSize, Buffer));
          end;
        end;
        Inc(Offset, $48 + Buffer[Offset + $43] * 4);
      end;
      NextBlock := Cardinal(Buffer[2]) * 256 + Buffer[3];
      if NextBlock = $FFFF then
        Break;
      Sector := (DirectoryPosition + UInt64(NextBlock) * BlockSize) div SectorSize;
    end;
  finally
    Visited.Free;
  end;
  Result := False;
end;

function HashJaguarCD(const OpenTrack: TRAOpenDiscTrack; out Digest: string): Boolean;
const
  NormalHeader: AnsiString = 'ATARI APPROVED DATA HEADER ATRI ';
  SwappedHeader: AnsiString = 'TARA IPARPVODED TA AEHDAREA RT I';
  HomebrewMarker: AnsiString = 'RT!IRTKA';
  HomebrewLoaderHash = '254487b59ab21bc005338e85cbf9fd2f';
  RawSectorSize = 2352;
var
  Track: TRADiscTrack;
  Buffer: array[0..RawSectorSize - 1] of Byte;
  Offset, Size, BytesRead: Cardinal;
  Swapped: Boolean;

  function ReadSwappedSize(Position: Integer): Cardinal;
  begin
    Result := (Cardinal(Buffer[Position + 1]) shl 24) or (Cardinal(Buffer[Position]) shl 16) or
      (Cardinal(Buffer[Position + 3]) shl 8) or Buffer[Position + 2];
  end;

  function ReadFirstSector: Boolean;
  begin
    BytesRead := Track.Read(Track.FirstSector, @Buffer[0], SizeOf(Buffer));
    Result := (BytesRead <> 0) and (BytesRead <= SizeOf(Buffer));
  end;

  function HashProgram: string;
  var
    Hash: THashMD5;
    Sector, Count, Remaining: Cardinal;
    Temp: Byte;
  begin
    Result := '';
    Hash := THashMD5.Create;
    Sector := Track.FirstSector;
    Remaining := Min(Size, Cardinal(MaxFileHashSize));
    while Remaining <> 0 do
    begin
      Count := Min(Remaining, Cardinal(SizeOf(Buffer)) - Offset);
      if Swapped then
        BytesRead := BytesRead and not Cardinal(1);
      if Offset + Count > BytesRead then
        Exit;
      if Swapped then
        for var Pair := 0 to Integer(BytesRead div 2) - 1 do
        begin
          Temp := Buffer[Pair * 2];
          Buffer[Pair * 2] := Buffer[Pair * 2 + 1];
          Buffer[Pair * 2 + 1] := Temp;
        end;
      Hash.Update(Buffer[Offset], Count);
      Dec(Remaining, Count);
      Offset := 0;
      if Remaining = 0 then
        Break;
      if Sector = High(Cardinal) then
        Exit;
      Inc(Sector);
      BytesRead := Track.Read(Sector, @Buffer[0], SizeOf(Buffer));
      if BytesRead <> SizeOf(Buffer) then
        Exit;
    end;
    Result := LowerCase(Hash.HashAsString);
  end;

begin
  Digest := '';
  if not OpenHashTrack(OpenTrack, RASecondSessionTrack, Track) or not ReadFirstSector then
    Exit(False);
  Offset := 0;
  Size := 0;
  Swapped := False;
  for var Index := 64 to Min(SizeOf(Buffer) - 45, Integer(BytesRead) - 40) do
  begin
    Swapped := CompareMem(@Buffer[Index], PAnsiChar(SwappedHeader), Length(SwappedHeader));
    if not Swapped and not CompareMem(@Buffer[Index], PAnsiChar(NormalHeader), Length(NormalHeader)) then
      Continue;
    if Swapped then
      Size := ReadSwappedSize(Index + 36)
    else
      Size := ReadBE32(@Buffer[0], Index + 36);
    Offset := Index + 40;
    Break;
  end;
  if Size = 0 then
    Exit(False);

  var ProgramHash := HashProgram;
  if Swapped and (ProgramHash = HomebrewLoaderHash) then
  begin
    if not OpenHashTrack(OpenTrack, 2, Track) or not ReadFirstSector or (BytesRead < $AA) or
      not CompareMem(@Buffer[$5E], PAnsiChar(HomebrewMarker), Length(HomebrewMarker)) then
      Exit(False);
    Size := ReadSwappedSize($A6);
    Offset := $AA;
    ProgramHash := HashProgram;
  end;
  Digest := ProgramHash;
  Result := Digest <> '';
end;

function TryHashRADisc(Console: TRADiscConsole; const OpenTrack: TRAOpenDiscTrack; out Digest: string): Boolean;
var
  Hash: THashMD5;
  Track: TRADiscTrack;
  Extent: TRAExtent;
  Buffer: TRASector;
  TrackNumber: Cardinal;
begin
  Digest := '';
  if not Assigned(OpenTrack) then
    Exit(False);
  if Console = TRADiscConsole.JaguarCD then
    Exit(HashJaguarCD(OpenTrack, Digest));
  Hash := THashMD5.Create;
  case Console of
    TRADiscConsole.Dreamcast:
      if not HashDreamcast(Hash, OpenTrack) then
        Exit(False);
    TRADiscConsole.PCFX:
      if not HashPCFX(Hash, OpenTrack) then
        Exit(False);
  else
    if Console = TRADiscConsole.PCEngineCD then
      TrackNumber := RAFirstDataTrack
    else
      TrackNumber := 1;
    if not OpenHashTrack(OpenTrack, TrackNumber, Track) then
      Exit(False);

    case Console of
      TRADiscConsole.PlayStation, TRADiscConsole.PlayStation2:
        if not HashPlayStation(Hash, Console, Track) then
          Exit(False);
      TRADiscConsole.PlayStationPortable:
        if not FindISOFile(Track.Read, 'PSP_GAME\PARAM.SFO', Extent, Track.FirstSector) or
          not AppendExtent(Hash, Track.Read, Extent, True) or
          not FindISOFile(Track.Read, 'PSP_GAME\SYSDIR\EBOOT.BIN', Extent, Track.FirstSector) or
          not AppendExtent(Hash, Track.Read, Extent, True) then
          Exit(False);
      TRADiscConsole.PlayStation3:
        if not FindISOFile(Track.Read, 'PS3_GAME\PARAM.SFO', Extent, Track.FirstSector) or
          not AppendExtent(Hash, Track.Read, Extent, True) or
          not FindISOFile(Track.Read, 'PS3_GAME\USRDIR\EBOOT.BIN', Extent, Track.FirstSector) or
          not AppendExtent(Hash, Track.Read, Extent, True) then
          Exit(False);
      TRADiscConsole.SegaCD, TRADiscConsole.Saturn:
        begin
          if (Track.Read(0, @Buffer[0], 512) <> 512) or
            (not CompareMem(@Buffer[0], PAnsiChar(AnsiString('SEGADISCSYSTEM  ')), 16) and
            not CompareMem(@Buffer[0], PAnsiChar(AnsiString('SEGA SEGASATURN ')), 16)) then
            Exit(False);
          Hash.Update(Buffer[0], 512);
        end;
      TRADiscConsole.PCEngineCD:
        if not HashPCECD(Hash, Track) then
          Exit(False);
      TRADiscConsole.NeoGeoCD:
        if not HashNeoGeoCD(Hash, Track) then
          Exit(False);
      TRADiscConsole.ThreeDO:
        if not HashThreeDO(Hash, Track) then
          Exit(False);
    else
      Exit(False);
    end;
  end;
  Digest := LowerCase(Hash.HashAsString);
  Result := True;
end;

function TryHashRADisc(Console: TRADiscConsole; const ReadSector: TRADiscRead; out Digest: string): Boolean;
var
  OpenTrack: TRAOpenDiscTrack;
begin
  Digest := '';
  if not Assigned(ReadSector) then
    Exit(False);
  OpenTrack :=
    function(Number: Cardinal; out Track: TRADiscTrack): Boolean
    begin
      Result := (Number = 1) or (Number = 2) or (Number = RAFirstDataTrack) or
        (Number = RALargestTrack);
      if Result then
      begin
        Track.FirstSector := 0;
        Track.Read := ReadSector;
      end;
    end;
  Result := TryHashRADisc(Console, OpenTrack, Digest);
end;

type
  TRANintendoImageHash = record
  private
    FStream: TStream;
    FStart: Int64;
    FSize: UInt64;
    FHash: THashMD5;
    FBuffer: TBytes;
    function Contains(Offset, Count: UInt64): Boolean;
    function ReadAt(Offset: UInt64; Buffer: PByte; Count: Integer): Boolean;
    function Append(Offset, Count: UInt64): Boolean;
    function HashBootPartition(Offset: UInt64; AddressShift: Integer): Boolean;
    function HashWiiPartition(Offset: UInt64; Encrypted: Boolean): Boolean;
    function HashWiiDisc: Boolean;
    function HashWAD: Boolean;
  end;

function TRANintendoImageHash.Contains(Offset, Count: UInt64): Boolean;
begin
  Result := (Offset <= FSize) and (Count <= FSize - Offset);
end;

function TRANintendoImageHash.ReadAt(Offset: UInt64; Buffer: PByte; Count: Integer): Boolean;
begin
  if not Contains(Offset, UInt64(Count)) then
    Exit(False);
  FStream.Position := FStart + Int64(Offset);
  Result := ReadRAStream(FStream, Buffer^, Count) = Count;
end;

function TRANintendoImageHash.Append(Offset, Count: UInt64): Boolean;
const
  ChunkSize = 64 * 1024;
var
  Chunk, ReadCount: Integer;
begin
  if not Contains(Offset, Count) then
    Exit(False);
  if Count = 0 then
    Exit(True);
  if Length(FBuffer) = 0 then
    SetLength(FBuffer, ChunkSize);
  FStream.Position := FStart + Int64(Offset);
  while Count <> 0 do
  begin
    Chunk := Integer(Min(Count, UInt64(Length(FBuffer))));
    ReadCount := FStream.Read(FBuffer[0], Chunk);
    if ReadCount <= 0 then
      Exit(False);
    FHash.Update(FBuffer[0], Cardinal(ReadCount));
    Dec(Count, UInt64(ReadCount));
  end;
  Result := True;
end;

function TRANintendoImageHash.HashBootPartition(Offset: UInt64; AddressShift: Integer): Boolean;
const
  BaseHeaderSize = $2440;
  AppLoaderHeaderSize = $20;
  MaximumHeaderSize = 1024 * 1024;
  SegmentCount = 18;
var
  HeaderSize, DOLPosition, SegmentPosition, SegmentSize: UInt64;
  WordBytes: array[0..3] of Byte;
  AppLoaderSizes: array[0..7] of Byte;
  DOL: array[0..$D7] of Byte;
begin
  if not ReadAt(Offset + BaseHeaderSize + $14, @AppLoaderSizes[0], SizeOf(AppLoaderSizes)) or
    not ReadAt(Offset + $420, @WordBytes[0], SizeOf(WordBytes)) then
    Exit(False);
  HeaderSize := Min(UInt64(MaximumHeaderSize), UInt64(BaseHeaderSize + AppLoaderHeaderSize) +
    ReadBE32(@AppLoaderSizes[0], 0) + ReadBE32(@AppLoaderSizes[0], 4));
  DOLPosition := UInt64(ReadBE32(@WordBytes[0], 0)) shl AddressShift;
  if not Append(Offset, HeaderSize) or not ReadAt(Offset + DOLPosition, @DOL[0], SizeOf(DOL)) then
    Exit(False);

  for var Index := 0 to SegmentCount - 1 do
  begin
    SegmentSize := UInt64(ReadBE32(@DOL[0], $90 + Index * 4)) shl AddressShift;
    if SegmentSize = 0 then
      Continue;

    SegmentPosition := UInt64(ReadBE32(@DOL[0], Index * 4)) shl AddressShift;
    if not Append(Offset + SegmentPosition, SegmentSize) then
      Exit(False);
  end;
  Result := True;
end;

function TRANintendoImageHash.HashWiiPartition(Offset: UInt64; Encrypted: Boolean): Boolean;
const
  MetadataFields = $2A4;
  DataFields = $2B8;
  ClusterSize = $8000;
  ClusterHeaderSize = $400;
  ClusterPayloadSize = ClusterSize - ClusterHeaderSize;
  MaximumClusterCount = 1024;
var
  Fields: array[0..7] of Byte;
  MetadataSize, MetadataPosition, DataPosition, DataSize, ClusterCount: UInt64;
begin
  if not ReadAt(Offset + MetadataFields, @Fields[0], SizeOf(Fields)) then
    Exit(False);
  MetadataSize := Min(UInt64(ClusterPayloadSize), UInt64(ReadBE32(@Fields[0], 0)));
  MetadataPosition := Offset + (UInt64(ReadBE32(@Fields[0], 4)) shl 2);
  if not Append(MetadataPosition, MetadataSize) or
    not ReadAt(Offset + DataFields, @Fields[0], SizeOf(Fields)) then
    Exit(False);

  // rcheevos interprets the data field as an absolute word offset.
  DataPosition := UInt64(ReadBE32(@Fields[0], 0)) shl 2;
  if not Encrypted then
    Exit(HashBootPartition(DataPosition, 2));

  DataSize := UInt64(ReadBE32(@Fields[0], 4)) shl 2;
  ClusterCount := Min(DataSize div ClusterSize, UInt64(MaximumClusterCount));
  for var Index := 0 to Integer(ClusterCount) - 1 do
    if not Append(DataPosition + UInt64(Index) * ClusterSize + ClusterHeaderSize, ClusterPayloadSize) then
      Exit(False);
  Result := True;
end;

function TRANintendoImageHash.HashWiiDisc: Boolean;
const
  MainHeaderSize = $80;
  RegionCodeAddress = $4E000;
  PartitionInfoAddress = $40000;
  UpdatePartitionType = 1;
var
  Encrypted: Byte;
  Groups: array[0..31] of Byte;
  Entry: array[0..7] of Byte;
  Count: Cardinal;
  TableOffset, EntryOffset, PartitionOffset: UInt64;
  HadPartition: Boolean;
begin
  if not ReadAt($61, @Encrypted, 1) or not Append(0, MainHeaderSize) or
    not Append(RegionCodeAddress, 4) or not ReadAt(PartitionInfoAddress, @Groups[0], SizeOf(Groups)) then
    Exit(False);

  HadPartition := False;
  for var Group := 0 to 3 do
  begin
    Count := ReadBE32(@Groups[0], Group * 8);
    if Count = 0 then
      Continue;
    HadPartition := True;
    TableOffset := UInt64(ReadBE32(@Groups[0], Group * 8 + 4)) shl 2;
    if not Contains(TableOffset, UInt64(Count) * SizeOf(Entry)) then
      Exit(False);

    EntryOffset := TableOffset;
    while Count <> 0 do
    begin
      if not ReadAt(EntryOffset, @Entry[0], SizeOf(Entry)) then
        Exit(False);
      if ReadBE32(@Entry[0], 4) <> UpdatePartitionType then
      begin
        PartitionOffset := UInt64(ReadBE32(@Entry[0], 0)) shl 2;
        if not HashWiiPartition(PartitionOffset, Encrypted = 0) then
          Exit(False);
      end;
      Inc(EntryOffset, SizeOf(Entry));
      Dec(Count);
    end;
  end;
  Result := HadPartition;
end;

function TRANintendoImageHash.HashWAD: Boolean;
const
  WADAlignment = $40;
  AESAlignment = $10;
  MaxHashedSectionSize = 64 * 1024 * 1024;
  ContentCountOffset = $1DE;
  FirstContentRecord = $1E4;
  ContentRecordSize = $24;
  ContentSizeOffset = 8;
var
  Header: array[0..$17] of Byte;
  Fields: array[0..7] of Byte;
  TMDStart, TMDSize, DeclaredTMDSize, ContentStart, ContentSize: UInt64;
  ContentCount: Integer;

  function AlignTo(Size, Alignment: UInt64): UInt64;
  begin
    Result := (Size + Alignment - 1) and not (Alignment - 1);
  end;

begin
  if not ReadAt(0, @Header[0], SizeOf(Header)) then
    Exit(False);
  TMDStart := WADAlignment + AlignTo(ReadBE32(@Header[0], $08), WADAlignment) +
    AlignTo(ReadBE32(@Header[0], $10), WADAlignment);
  DeclaredTMDSize := ReadBE32(@Header[0], $14);
  TMDSize := Min(AlignTo(DeclaredTMDSize, WADAlignment), UInt64(MaxHashedSectionSize));
  if (DeclaredTMDSize < FirstContentRecord) or
    not ReadAt(TMDStart + ContentCountOffset, @Fields[0], 2) then
    Exit(False);
  ContentCount := (Integer(Fields[0]) shl 8) or Fields[1];
  if (UInt64(FirstContentRecord) + UInt64(ContentCount) * ContentRecordSize > DeclaredTMDSize) or
    not Append(TMDStart, TMDSize) then
    Exit(False);

  ContentStart := TMDStart + TMDSize;
  for var Index := 0 to ContentCount - 1 do
  begin
    if not ReadAt(TMDStart + FirstContentRecord + ContentSizeOffset + UInt64(Index) * ContentRecordSize,
      @Fields[0], SizeOf(Fields)) then
      Exit(False);
    if ReadBE32(@Fields[0], 0) = 0 then
      ContentSize := AlignTo(ReadBE32(@Fields[0], 4), AESAlignment)
    else
      ContentSize := MaxHashedSectionSize;
    if not Append(ContentStart, Min(ContentSize, UInt64(MaxHashedSectionSize))) then
      Exit(False);
    ContentStart := AlignTo(ContentStart + ContentSize, WADAlignment);
  end;
  Result := True;
end;

function TryHashNintendoImage(Stream: TStream; Wii: Boolean; out Digest: string): Boolean;
const
  GameCubeMagic = $C2339F3D;
  WiiMagic = $5D1C9EA3;
  WiiWADMagic = $49730000;
var
  Image: TRANintendoImageHash;
  Size: Int64;
  Magic: array[0..3] of Byte;
begin
  Digest := '';
  if Stream = nil then
    Exit(False);

  Image.FStream := Stream;
  Image.FStart := Stream.Position;
  Size := Stream.Size - Image.FStart;
  if Size < 0 then
    Exit(False);
  Image.FSize := UInt64(Size);
  Image.FHash := THashMD5.Create;
  try
    if not Wii then
      Result := Image.ReadAt($1C, @Magic[0], SizeOf(Magic)) and
        (ReadBE32(@Magic[0], 0) = GameCubeMagic) and Image.HashBootPartition(0, 0)
    else if Image.ReadAt($18, @Magic[0], SizeOf(Magic)) and (ReadBE32(@Magic[0], 0) = WiiMagic) then
      Result := Image.HashWiiDisc
    else
      Result := Image.ReadAt(4, @Magic[0], SizeOf(Magic)) and
        (ReadBE32(@Magic[0], 0) = WiiWADMagic) and Image.HashWAD;

    if Result then
      Digest := LowerCase(Image.FHash.HashAsString);
  finally
    Stream.Position := Image.FStart;
  end;
end;

function TryHashRAGameCube(Stream: TStream; out Digest: string): Boolean;
begin
  Result := TryHashNintendoImage(Stream, False, Digest);
end;

function TryHashRAWii(Stream: TStream; out Digest: string): Boolean;
begin
  Result := TryHashNintendoImage(Stream, True, Digest);
end;

end.

