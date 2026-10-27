unit Core.CD.Disc;

interface

uses
  System.SysUtils, System.Classes, Core.Storage;

type
  TCDIndex = record
    Number, FileSector, LBA: Integer;
  end;

  TCDTrack = record
    Number, StartLBA, EndLBA, PregapLBA, FileSector, SectorSize, DataOffset: Integer;
    StoredPregap: Integer;
    Audio, LittleEndian, PregapAudio: Boolean;
    SourceName: string;
    Stream: TStream;
    ByteOffset, ByteSize: Int64;
    Indexes: TArray<TCDIndex>;
    SubStream: TStream;
    SubRaw: Boolean;
    SubchannelStored: Boolean;
    // Recording session (multi-session CD-R images); 1 otherwise.
    Session: Integer;
  end;

  // Immutable TOC; streams are owned here and accessed by the emulation worker.
  TCDDisc = class
  private
    FTracks: TArray<TCDTrack>;
    FLeadOut: Integer;
    FIdentity: TBytes;
    FCompressedHash: TBytes;
    FIdentityPending: Boolean;
    FHighDensity, FOverburn: Boolean;
    FArchiveDirectory: string;
    FSBIInvalidCRC: TArray<Integer>;
    procedure LoadGDI(Stream: TStream; const Storage: IStorage; const Location: string);
    procedure LoadCDI(const Storage: IStorage; const Location: string);
    procedure LoadSBI(const Storage: IStorage; const Location, SourceName: string);
    function SBIInvalidCRC(LBA: Integer): Boolean;
    procedure LoadZip(Stream: TStream; const Storage: IStorage);
    procedure LoadCHD(const Storage: IStorage; const Location: string);
    procedure LoadCue(Stream: TStream; const Storage: IStorage; const Location: string);
    procedure LoadMDS(Stream: TStream; const Storage: IStorage; const Location, FileName: string);
    procedure LoadNRG(const Storage: IStorage; const Location: string);
    procedure LoadRaw(const Storage: IStorage; const Location: string);
    procedure ValidateAndHash(HashContent: Boolean);
  public
    // Generic CD media: TOC, companion streams and sectors. Filesystem/boot
    // requirements are selected by the caller after construction.
    // DeferIdentity skips reading the whole image here; the first Identity
    // call does it instead, and must come before another thread reads sectors.
    constructor Create(Stream: TStream; const Storage: IStorage; const Location: string; DeferIdentity: Boolean = False);
    // Inspect ZIP directory metadata without loading cartridge/disc payloads.
    class function IsDiscZip(Stream: TStream): Boolean; static;
    procedure RequireISO9660;
    // Optional root-directory file; bounded to avoid trusting corrupt extents.
    function ReadISOFile(const Name: string; MaximumSize: Integer = 65536): TBytes;
    destructor Destroy; override;
    function TrackAt(LBA: Integer): Integer;
    function Track(Number: Integer): TCDTrack;
    function TrackCount: Integer;
    function LeadOut: Integer;
    function IsData(LBA: Integer): Boolean;
    procedure ReadData(LBA: Integer; var Sector: TBytes);
    procedure ReadAudio(LBA: Integer; var Sector: TBytes);
    function IndexAt(LBA: Integer): Integer;
    function HasIndexes(LBA: Integer): Boolean;
    procedure ReadRawData(LBA: Integer; var Sector: TBytes);
    // True for usable measured Q, or reconstructed Q outside SBI bad sectors.
    function ReadSubQ(LBA: Integer; var Q: TBytes): Boolean;
    function HasSubchannelQ: Boolean;
    function Identity: TBytes;
    // GD-ROM layout: a high-density area from LBA 45000.
    property HighDensity: Boolean read FHighDensity;
  end;

// UTF-8 playlist; paths are relative to its location. Nested playlists are rejected.
// SystemId names the ROM folder that resolves document (content://) locations.
function ReadCDPlaylist(Stream: TStream; const Storage: IStorage; const Location: string; const SystemId: string = 'ps1'): TArray<string>;

function CDSibling(const Storage: IStorage; const Location, Name: string): string;
// File names of the tracks a GDI lists (as written, relative to the GDI);
// malformed lines are skipped.

function ReadGDITrackNames(Stream: TStream): TArray<string>;
// A single-track raw image (.bin without a CUE): 2352-byte sectors starting
// with a Mode 1 or Mode 2 data sector. Restores the stream position.

function IsCDRawImage(Stream: TStream): Boolean;

function CDDataEDC(const Data: TBytes; Count: Integer): Cardinal;
// Correct isolated symbol errors using ECMA-130 P/Q parity; commit only on valid EDC.

function CDCorrectMode1(var Sector: TBytes): Boolean;

implementation

uses
  Core.Platforms, System.Hash, System.IOUtils, System.Math, System.StrUtils,
  System.Zip, System.Generics.Collections, Core.CD.CHD
  {$IFDEF ANDROID}, Core.Storage.Android{$ENDIF};

function CDSibling(const Storage: IStorage; const Location, Name: string): string;
begin
  // A CUE references files beside itself, never absolute paths or parent traversal.
  if (Name = '') or Name.Contains(':') or Name.Contains('/') or Name.Contains('\') or (Name = '.') or (Name = '..') then
    raise EReadError.Create('Invalid CD companion filename: ' + Name);

  if Location.StartsWith('content://', True) then
  begin
    // SAF document IDs are opaque. Find the source in the selected system
    // folder, then resolve by display name without constructing a URI.
    for var platform in TPlatformRegistry.All do
    begin
      var Folder := Storage.RomFolder(platform.Id);
      if Folder = '' then
        Continue;
      var Items: TArray<TStorageFile>;
      {$IFDEF ANDROID}
      Items := TAndroidStorage.Enumerate(Folder, True);
      {$ELSE}
      var Files := Storage.Files(Folder, True);
      SetLength(Items, Length(Files));
      for var i := 0 to High(Files) do
        Items[i] := Storage.Describe(Files[i]);
      {$ENDIF}
      for var i := 0 to High(Items) do
        if Items[i].RelativePath = '' then
          Items[i].RelativePath := Items[i].Name;
      var SourceIndex := -1;
      for var i := 0 to High(Items) do
        {$IFDEF ANDROID}
        if TAndroidStorage.SameDocument(Items[i].Location, Location) then
        {$ELSE}
          if Items[i].Location = Location then
        {$ENDIF}
            SourceIndex := i;
      if SourceIndex < 0 then
        Continue;
      var Relative := Items[SourceIndex].RelativePath;
      var Directory := Relative.Substring(0, Length(Relative) - Length(Items[SourceIndex].Name));
      for var Candidate in Items do
        if SameText(Candidate.Name, Name) and
          SameText(Candidate.RelativePath, Directory + Name) then
          Exit(Candidate.Location);

      Break;
    end;
    raise EReadError.Create('Missing CD companion in the selected ROM folder: ' + Name);
  end;

  Result := TPath.Combine(ExtractFilePath(Location.Replace('/', PathDelim)), Name);
  if not Storage.Exists(Result) then
  begin
    // CUE filenames often use a different case from a Linux filesystem.
    for var Candidate in Storage.Files(ExtractFilePath(Result)) do
      if SameText(ExtractFileName(Candidate), Name) then
        Exit(Candidate);

    raise EReadError.Create('Missing CD file: ' + Name);
  end;
end;

function ReadCDPlaylist(Stream: TStream; const Storage: IStorage; const Location, SystemId: string): TArray<string>;

  function RelativeName(const Name: string): string;
  begin
    var Parts := TList<string>.Create;
    try
      for var Part in Name.Replace('\', '/').Split(['/']) do
      begin
        if (Part = '') or (Part = '.') then
          Continue;
        if Part = '..' then
        begin
          if Parts.Count = 0 then
            raise EReadError.Create('M3U path leaves the ROM folder: ' + Name);
          Parts.Delete(Parts.Count - 1);
        end
        else
          Parts.Add(Part);
      end;
      Result := string.Join('/', Parts.ToArray);
    finally
      Parts.Free;
    end;
  end;

  function ResolveEntry(const Name: string): string;
  begin
    if Location.StartsWith('content://', True) then
    begin
      // Resolve SAF document IDs through folder metadata, never by editing a URI.
      if Name.Contains(':') or Name.StartsWith('/') or Name.StartsWith('\') then
        raise EReadError.Create('M3U requires relative paths in a document folder');
      var Folder := Storage.RomFolder(SystemId);
      var Items: TArray<TStorageFile>;
      {$IFDEF ANDROID}
      Items := TAndroidStorage.Enumerate(Folder, True);
      {$ELSE}
      var Files := Storage.Files(Folder, True);
      SetLength(Items, Length(Files));
      for var I := 0 to High(Files) do
        Items[I] := Storage.Describe(Files[I]);
      {$ENDIF}
      for var Source in Items do
      begin
        {$IFDEF ANDROID}
        if not TAndroidStorage.SameDocument(Source.Location, Location) then
          Continue;
        {$ELSE}
        if Source.Location <> Location then
          Continue;
        {$ENDIF}
        var Directory := Source.RelativePath.Substring(0, Length(Source.RelativePath) - Length(Source.Name));
        var Target := RelativeName(Directory + Name);
        for var Candidate in Items do
          if SameText(RelativeName(Candidate.RelativePath), Target) then
            Exit(Candidate.Location);
        Break;
      end;
      raise EReadError.Create('Missing M3U disc in the selected ROM folder: ' + Name);
    end;
    var NativeName := Name.Replace('\', PathDelim).Replace('/', PathDelim);
    if NativeName.Contains('://') then
      raise EReadError.Create('M3U expects a local disc image: ' + Name);
    Result := TPath.GetFullPath(TPath.Combine(ExtractFilePath(Location), NativeName));
    if not Storage.Exists(Result) then
      raise EReadError.Create('Missing M3U disc: ' + Name);
  end;

begin
  if (Stream.Size - Stream.Position > 1024 * 1024) then
    raise EReadError.Create('M3U playlist exceeds 1 MiB');
  var Entries := TList<string>.Create;
  var Reader := TStreamReader.Create(Stream, TEncoding.UTF8, True, 1024);
  try
    while not Reader.EndOfStream do
    begin
      TStorage.CheckReadCancelled;
      var Line := Reader.ReadLine.Trim;
      if (Line = '') or Line.StartsWith('#') then
        Continue;
      if (Length(Line) >= 2) and Line.StartsWith('"') and Line.EndsWith('"') then
        Line := Line.Substring(1, Length(Line) - 2);
      var Ext := ExtractFileExt(Line);
      if not MatchText(Ext, ['.cue', '.chd', '.iso', '.bin', '.zip', '.gdi', '.cdi', '.mds', '.nrg']) then
        raise EReadError.Create('M3U expects CUE, CHD, ISO, raw BIN, disc ZIP, GDI, CDI, MDS or NRG: ' + Line);
      if Entries.Count >= 99 then
        raise EReadError.Create('M3U playlist exceeds 99 discs');
      Entries.Add(ResolveEntry(Line));
    end;
    if Entries.Count = 0 then
      raise EReadError.Create('M3U playlist contains no discs');
    Result := Entries.ToArray;
  finally
    Reader.Free;
    Entries.Free;
  end;
end;

function CueTime(const Text: string): Integer;
begin
  var Parts := Text.Split([':']);
  if Length(Parts) <> 3 then
    raise EReadError.Create('Invalid CUE time: ' + Text);

  var M := StrToInt(Parts[0]);
  var S := StrToInt(Parts[1]);
  var F := StrToInt(Parts[2]);
  if (M < 0) or (M > 99) or (S < 0) or (S > 59) or (F < 0) or (F > 74) then
    raise EReadError.Create('Invalid CUE time: ' + Text);

  Result := (M * 60 + S) * 75 + F;
end;

procedure WaveRange(Stream: TStream; out Offset, Size: Int64);
var
  Header: array[0..11] of Byte;
  Chunk: array[0..7] of Byte;
  Format: array[0..15] of Byte;
begin
  Stream.Position := 0;
  Stream.ReadBuffer(Header, SizeOf(Header));
  if not CompareMem(@Header[0], PAnsiChar(AnsiString('RIFF')), 4) or not CompareMem(@Header[8], PAnsiChar(AnsiString('WAVE')), 4) then
    raise EReadError.Create('CD audio must be PCM WAV or BINARY');

  var ValidFormat := False;
  Offset := -1;
  Size := 0;
  while Stream.Position + 8 <= Stream.Size do
  begin
    Stream.ReadBuffer(Chunk, 8);
    var Count := Cardinal(Chunk[4]) or (Cardinal(Chunk[5]) shl 8) or
      (Cardinal(Chunk[6]) shl 16) or (Cardinal(Chunk[7]) shl 24);
    var Next := Stream.Position + Int64(Count) + (Count and 1);
    if Next > Stream.Size then
      raise EReadError.Create('Truncated CD audio WAV');

    if CompareMem(@Chunk[0], PAnsiChar(AnsiString('fmt ')), 4) then
    begin
      if Count < 16 then
        raise EReadError.Create('Invalid CD audio WAV format');

      Stream.ReadBuffer(Format, 16);
      ValidFormat := (Format[0] = 1) and (Format[1] = 0) and
        (Format[2] = 2) and (Format[3] = 0) and (Format[4] = $44) and
        (Format[5] = $AC) and (Format[6] = 0) and (Format[7] = 0) and
        (Format[12] = 4) and (Format[13] = 0) and (Format[14] = 16) and (Format[15] = 0);
    end
    else if CompareMem(@Chunk[0], PAnsiChar(AnsiString('data')), 4) then
    begin
      Offset := Stream.Position;
      Size := Count;
    end;
    Stream.Position := Next;
  end;

  if not ValidFormat or (Offset < 0) or (Size mod 4 <> 0) then
    raise EReadError.Create('CD audio WAV requires 44100 Hz, stereo, 16-bit PCM');
end;

constructor TCDDisc.Create(Stream: TStream; const Storage: IStorage; const Location: string; DeferIdentity: Boolean);
begin
  inherited Create;
  if (Stream = nil) or (Storage = nil) or (Location = '') then
    raise EArgumentException.Create('CD needs a source location and storage');

  var SourceName := Location;
  if Location.StartsWith('content://', True) then
    SourceName := Storage.Describe(Location).Name;
  if SameText(ExtractFileExt(SourceName), '.zip') then
  begin
    LoadZip(Stream, Storage);
    Exit;
  end
  else if SameText(ExtractFileExt(SourceName), '.cue') then
    LoadCue(Stream, Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.iso') then
  begin
    SetLength(FTracks, 1);
    FTracks[0].Number := 1;
    FTracks[0].SectorSize := 2048;
    FTracks[0].Stream := Storage.OpenRead(Location);
    FTracks[0].ByteSize := FTracks[0].Stream.Size;
    if (FTracks[0].ByteSize < 2048) or (FTracks[0].ByteSize > Int64(800) * 1024 * 1024) or (FTracks[0].ByteSize mod 2048 <> 0) then
      raise EReadError.Create('Invalid CD ISO size');

    FTracks[0].EndLBA := FTracks[0].ByteSize div 2048;
  end
  else if SameText(ExtractFileExt(SourceName), '.chd') then
    LoadCHD(Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.gdi') then
    LoadGDI(Stream, Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.cdi') then
    LoadCDI(Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.mds') then
    LoadMDS(Stream, Storage, Location, ExtractFileName(SourceName.Replace('/', PathDelim)))
  else if SameText(ExtractFileExt(SourceName), '.nrg') then
    LoadNRG(Storage, Location)
  else if SameText(ExtractFileExt(SourceName), '.bin') then
    LoadRaw(Storage, Location)
  else
    raise EReadError.Create('CD expects ISO, CUE, MDS, NRG, CHD, GDI, CDI, a raw BIN or a disc ZIP');

  if (FLeadOut = 0) and (Length(FTracks) > 0) then
    FLeadOut := FTracks[High(FTracks)].EndLBA;
  LoadSBI(Storage, Location, SourceName);
  ValidateAndHash(not DeferIdentity);
end;

destructor TCDDisc.Destroy;
begin
  for var Item in FTracks do
  begin
    Item.SubStream.Free;
    Item.Stream.Free;
  end;
  if (FArchiveDirectory <> '') and TDirectory.Exists(FArchiveDirectory) then
  try
    TDirectory.Delete(FArchiveDirectory, True);
  except
    // Cache cleanup must not mask a media error or interrupt shutdown.
  end;
  inherited;
end;

function DiscZipEntry(const Name: string): Boolean;
begin
  var Normalized := Name.Replace('\', '/');
  var Leaf := Normalized.Substring(Normalized.LastIndexOf('/') + 1);
  Result := not Normalized.StartsWith('__MACOSX/') and
    not Leaf.StartsWith('._') and
    MatchText(ExtractFileExt(Name), ['.cue', '.iso', '.chd', '.bin']);
end;

class function TCDDisc.IsDiscZip(Stream: TStream): Boolean;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');
  Result := False;
  var Position := Stream.Position;
  var Zip := TZipFile.Create;
  try
    Stream.Position := 0;
    var Magic: Cardinal;
    if (Stream.Read(Magic, SizeOf(Magic)) <> SizeOf(Magic)) or (Magic <> $04034B50) then
      Exit;
    Stream.Position := 0;
    Zip.Open(Stream, zmRead);
    // BIN is shared with cartridges. Require a descriptor/container, or raw
    // sector sync in a lone BIN, rather than routing every cartridge ZIP here.
    var BinIndex := -1;
    var BinCount := 0;
    for var i := 0 to Zip.FileCount - 1 do
    begin
      TStorage.CheckReadCancelled;
      if DiscZipEntry(Zip.FileNames[i]) then
      begin
        if not SameText(ExtractFileExt(Zip.FileNames[i]), '.bin') then
          Exit(True);
        Inc(BinCount);
        BinIndex := i;
      end;
    end;
    if BinCount = 1 then
    begin
      var Entry: TStream;
      var Header: TZipHeader;
      Zip.Read(BinIndex, Entry, Header);
      try
        var Probe: array[0..15] of Byte;
        FillChar(Probe, SizeOf(Probe), 0);
        if Entry.Read(Probe, SizeOf(Probe)) = SizeOf(Probe) then
          Result := (Probe[0] = 0) and (Probe[11] = 0) and (Probe[15] in [1, 2]);
        for var i := 1 to 10 do
          Result := Result and (Probe[i] = $FF);
      finally
        Entry.Free;
      end;
    end;
  finally
    Zip.Free;
    Stream.Position := Position;
  end;
end;

procedure TCDDisc.LoadZip(Stream: TStream; const Storage: IStorage);
const
  MaxArchiveSize = Int64(1024) * 1024 * 1024;
begin
  var Zip := TZipFile.Create;
  try
    Stream.Position := 0;
    Zip.Open(Stream, zmRead);
    if Zip.FileCount > 4096 then
      raise EReadError.Create('CD ZIP contains too many entries');
    var Selected := -1;
    var CueCount := 0;
    var ImageCount := 0;
    for var i := 0 to Zip.FileCount - 1 do
      if DiscZipEntry(Zip.FileNames[i]) then
      begin
        if SameText(ExtractFileExt(Zip.FileNames[i]), '.cue') then
        begin
          Inc(CueCount);
          Selected := i;
        end
        else
        begin
          Inc(ImageCount);
          if CueCount = 0 then
            Selected := i;
        end;
      end;
    if (Selected < 0) or (CueCount > 1) or ((CueCount = 0) and (ImageCount <> 1)) then
      raise EReadError.Create('CD ZIP must contain one CUE or one standalone disc image');

    var SelectedName := Zip.FileNames[Selected].Replace('\', '/');
    var Separator := SelectedName.LastIndexOf('/');
    var Prefix := SelectedName.Substring(0, Separator + 1);
    // Every extracted name is a validated leaf. Archive paths cannot escape
    // the unique cache directory or overwrite an existing user file.
    FArchiveDirectory := Storage.TemporaryFile('.disc');
    var LocalStorage: IStorage := TStorage.Create(Storage.Root);
    LocalStorage.EnsureFolder(FArchiveDirectory);
    var Names := TStringList.Create;
    try
      Names.CaseSensitive := False;
      Names.Sorted := True;
      var Total: Int64 := 0;
      for var i := 0 to Zip.FileCount - 1 do
      begin
        TStorage.CheckReadCancelled;
        var Name := Zip.FileNames[i].Replace('\', '/');
        var Split := Name.LastIndexOf('/');
        if not SameText(Name.Substring(0, Split + 1), Prefix) then
          Continue;
        var Leaf := Name.Substring(Split + 1);
        if (Leaf = '') or Leaf.StartsWith('._') or
          not MatchText(ExtractFileExt(Leaf), ['.cue', '.bin', '.iso', '.chd', '.wav', '.sub', '.sbi']) then
          Continue;
        if Leaf.Contains(':') or (Leaf = '.') or (Leaf = '..') then
          raise EReadError.Create('Invalid CD ZIP filename: ' + Name);
        if Names.IndexOf(Leaf) >= 0 then
          raise EReadError.Create('Duplicate CD ZIP filename: ' + Leaf);
        Names.Add(Leaf);
        var Size := Zip.FileInfo[i].UncompressedSize64;
        if Size > UInt64(MaxArchiveSize - Total) then
          raise EReadError.Create('CD ZIP unpacked data exceeds 1 GiB');
        Inc(Total, Int64(Size));
        var Input: TStream;
        var Header: TZipHeader;
        Zip.Read(i, Input, Header, True);
        try
          var Output := LocalStorage.OpenWrite(TPath.Combine(FArchiveDirectory, Leaf));
          try
            var Buffer: array[0..65535] of Byte;
            var Written: Int64 := 0;
            while True do
            begin
              TStorage.CheckReadCancelled;
              var Count := Input.Read(Buffer, SizeOf(Buffer));
              if Count = 0 then
                Break;
              Inc(Written, Count);
              if (Count < 0) or (Written > Int64(Size)) then
                raise EReadError.Create('CD ZIP entry exceeds its declared size');
              Output.WriteBuffer(Buffer, Count);
            end;
            if Written <> Int64(Size) then
              raise EReadError.Create('Truncated CD ZIP entry: ' + Leaf);
          finally
            Output.Free;
          end;
        finally
          Input.Free;
        end;
      end;
    finally
      Names.Free;
    end;
    var Path := TPath.Combine(FArchiveDirectory, SelectedName.Substring(Separator + 1));
    var Input := LocalStorage.OpenRead(Path);
    try
      var Disc := TCDDisc.Create(Input, LocalStorage, Path);
      try
        FTracks := Disc.FTracks;
        Disc.FTracks := nil;
        FLeadOut := Disc.FLeadOut;
        FIdentity := Disc.FIdentity;
        FCompressedHash := Disc.FCompressedHash;
        FSBIInvalidCRC := Disc.FSBIInvalidCRC;
      finally
        Disc.Free;
      end;
    finally
      Input.Free;
    end;
  finally
    Zip.Free;
  end;
end;

// SBI lists absolute BCD positions whose Q checksums were intentionally bad.
// The payload omits the CRC; the drive must retain its last valid position at
// these sectors, rather than expose the replacement MSF bytes (psx-spx).
procedure TCDDisc.LoadSBI(const Storage: IStorage; const Location, SourceName: string);

  function DecodeBCD(Value: Byte; Limit: Integer): Integer;
  begin
    Result := (Value shr 4) * 10 + (Value and 15);
    if ((Value shr 4) > 9) or ((Value and 15) > 9) or (Result >= Limit) then
      raise EReadError.Create('Invalid SBI sector position');
  end;

begin
  var Path: string;
  try
    var Name := SourceName.Replace('\', '/');
    Name := Name.Substring(Name.LastIndexOf('/') + 1);
    Path := CDSibling(Storage, Location, ChangeFileExt(Name, '.sbi'));
  except
    on E: EReadError do
      Exit; // The sidecar is optional.
  end;
  var Input := Storage.OpenRead(Path);
  try
    if (Input.Size < 4) or (Input.Size > 65536) then
      raise EReadError.Create('Invalid SBI file size');
    var Header: array[0..3] of Byte;
    Input.ReadBuffer(Header, 4);
    if (Header[0] <> Ord('S')) or (Header[1] <> Ord('B')) or
      (Header[2] <> Ord('I')) or (Header[3] <> 0) then
      raise EReadError.Create('Invalid SBI signature');
    while Input.Position < Input.Size do
    begin
      TStorage.CheckReadCancelled;
      if Input.Size - Input.Position < 4 then
        raise EReadError.Create('Truncated SBI sector entry');
      Input.ReadBuffer(Header, 4);
      var LBA := (DecodeBCD(Header[0], 100) * 60 + DecodeBCD(Header[1], 60)) * 75 +
        DecodeBCD(Header[2], 75) - 150;
      if (LBA < 0) or (LBA >= FLeadOut) then
        raise EReadError.Create('SBI sector outside disc');
      var Count: Integer;
      case Header[3] of
        1:
          Count := 10;
        2, 3:
          Count := 3;
      else
        raise EReadError.Create('Invalid SBI entry type');
      end;
      if Input.Size - Input.Position < Count then
        raise EReadError.Create('Truncated SBI subchannel data');
      Input.Seek(Count, soCurrent);
      var N := Length(FSBIInvalidCRC);
      SetLength(FSBIInvalidCRC, N + 1);
      FSBIInvalidCRC[N] := LBA;
    end;
    TArray.Sort<Integer>(FSBIInvalidCRC);
  finally
    Input.Free;
  end;
end;

function TCDDisc.SBIInvalidCRC(LBA: Integer): Boolean;
begin
  var Left := 0;
  var Right := High(FSBIInvalidCRC);
  while Left <= Right do
  begin
    var Middle := Left + (Right - Left) div 2;
    if FSBIInvalidCRC[Middle] = LBA then
      Exit(True);
    if FSBIInvalidCRC[Middle] < LBA then
      Left := Middle + 1
    else
      Right := Middle - 1;
  end;
  Result := False;
end;

function TCDDisc.HasSubchannelQ: Boolean;
begin
  Result := Length(FSBIInvalidCRC) <> 0;
  for var Item in FTracks do
    Result := Result or (Item.SubStream <> nil) or Item.SubchannelStored;
end;

procedure TCDDisc.LoadCue(Stream: TStream; const Storage: IStorage; const Location: string);
var
  Index0, Index1, Gaps, PostGaps: array[0..98] of Integer;
begin
  if Stream.Size - Stream.Position > 1024 * 1024 then
    raise EReadError.Create('CUE exceeds 1 MiB');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then
    Stream.ReadBuffer(Data[0], Length(Data));
  var Text := TEncoding.UTF8.GetString(Data).TrimLeft([#$FEFF]);
  var FileName := '';
  var FileType := '';
  var Current := -1;
  // Redump GD-ROM sheets mark the high-density area with a comment; its
  // first track starts at LBA 45000.
  var HighFirst := -1;
  for var Line in Text.Split([#10]) do
  begin
    var Value := Line.Trim;
    if Value = '' then
      Continue;

    var Tokens := Value.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
    var Command := Tokens[0].ToUpper;
    if Command = 'FILE' then
    begin
      if Value.Contains('"') then
      begin
        var First := Pos('"', Value);
        var Tail := Copy(Value, First + 1, MaxInt);
        var Last := Pos('"', Tail);
        if Last = 0 then
          raise EReadError.Create('Unterminated CUE filename');

        FileName := Copy(Tail, 1, Last - 1);
        FileType := Copy(Tail, Last + 1, MaxInt).Trim.ToUpper;
      end
      else
      begin
        if Length(Tokens) <> 3 then
          raise EReadError.Create('Invalid CUE FILE');

        FileName := Tokens[1];
        FileType := Tokens[2].ToUpper;
      end;
      if (FileType <> 'BINARY') and (FileType <> 'WAVE') then
        raise EReadError.Create('Unsupported CUE FILE type: ' + FileType);
    end
    else if Command = 'TRACK' then
    begin
      if (Length(Tokens) <> 3) or (FileName = '') or (Length(FTracks) >= 99) then
        raise EReadError.Create('Invalid CUE TRACK');

      Current := Length(FTracks);
      SetLength(FTracks, Current + 1);
      FTracks[Current].Number := StrToInt(Tokens[1]);
      if FTracks[Current].Number <> Current + 1 then
        raise EReadError.Create('CUE tracks must be numbered consecutively from 1');

      Index0[Current] := -1;
      Index1[Current] := -1;
      Gaps[Current] := 0;
      PostGaps[Current] := 0;
      var Kind := Tokens[2].ToUpper;
      FTracks[Current].Audio := Kind = 'AUDIO';
      FTracks[Current].SectorSize := 2352;
      if Kind = 'MODE1/2048' then
        FTracks[Current].SectorSize := 2048
      else if Kind = 'MODE1/2352' then
        FTracks[Current].DataOffset := 16
      else if Kind = 'MODE2/2352' then
        FTracks[Current].DataOffset := 24
      else if Kind <> 'AUDIO' then
        raise EReadError.Create('Unsupported CUE TRACK type: ' + Kind);

      FTracks[Current].SourceName := FileName;
      FTracks[Current].Stream := Storage.OpenRead(CDSibling(Storage, Location, FileName));
      FTracks[Current].ByteSize := FTracks[Current].Stream.Size;

      // CUE BINARY audio, like PCM WAV, stores little-endian samples.
      FTracks[Current].LittleEndian := True;
      if FTracks[Current].ByteSize > Int64(800) * 1024 * 1024 then
        raise EReadError.Create('CD track exceeds 800 MiB');

      if FileType = 'WAVE' then
      begin
        if not FTracks[Current].Audio then
          raise EReadError.Create('WAVE is only valid for AUDIO tracks');
        WaveRange(FTracks[Current].Stream, FTracks[Current].ByteOffset, FTracks[Current].ByteSize);
      end;
    end
    else if Command = 'INDEX' then
    begin
      if (Current < 0) or (Length(Tokens) <> 3) then
        raise EReadError.Create('Invalid CUE INDEX');

      var N := StrToInt(Tokens[1]);
      var Time := CueTime(Tokens[2]);
      if (N < 0) or (N > 99) then
        raise EReadError.Create('Invalid CUE index number');
      var Count := Length(FTracks[Current].Indexes);
      if (Count > 0) and ((N <= FTracks[Current].Indexes[Count - 1].Number) or
        (Time < FTracks[Current].Indexes[Count - 1].FileSector)) then
        raise EReadError.Create('CUE indexes must increase');
      SetLength(FTracks[Current].Indexes, Count + 1);
      FTracks[Current].Indexes[Count].Number := N;
      FTracks[Current].Indexes[Count].FileSector := Time;
      if N = 0 then
        Index0[Current] := Time
      else if N = 1 then
        Index1[Current] := Time;
    end
    else if Command = 'PREGAP' then
    begin
      if (Current < 0) or (Length(Tokens) <> 2) then
        raise EReadError.Create('Invalid CUE PREGAP');

      Gaps[Current] := CueTime(Tokens[1]);
    end
    else if Command = 'POSTGAP' then
    begin
      if (Current < 0) or (Length(Tokens) <> 2) then
        raise EReadError.Create('Invalid CUE POSTGAP');

      PostGaps[Current] := CueTime(Tokens[1]);
    end
    else if (Command = 'REM') and Value.ToUpper.Contains('HIGH-DENSITY AREA') then
      HighFirst := Length(FTracks)
    else if not ((Command = 'REM') or (Command = 'TITLE') or (Command = 'PERFORMER') or
      (Command = 'SONGWRITER') or (Command = 'CATALOG') or (Command = 'ISRC') or (Command = 'FLAGS')) then
      raise EReadError.Create('Unsupported CUE directive: ' + Command);
  end;
  var Cursor := 0;
  for var i := 0 to High(FTracks) do
  begin
    if (Index1[i] < 0) or ((Index0[i] >= 0) and (Index0[i] > Index1[i])) then
      raise EReadError.Create('CUE TRACK needs a valid INDEX 01');

    var EndSector := FTracks[i].ByteSize div FTracks[i].SectorSize;
    if (i < High(FTracks)) and SameText(FTracks[i].SourceName, FTracks[i + 1].SourceName) then
    begin
      if Index1[i + 1] <= Index1[i] then
        raise EReadError.Create('CUE indexes must increase within one FILE');

      begin
        EndSector := Index1[i + 1];
        if Index0[i + 1] >= 0 then
          EndSector := Index0[i + 1];
        if FTracks[i].SectorSize <> FTracks[i + 1].SectorSize then
          raise EReadError.Create('Mixed sector sizes in one CUE FILE');
      end;
    end;

    if EndSector <= Index1[i] then
      raise EReadError.Create('Invalid CUE track bounds');

    FTracks[i].FileSector := Index1[i];
    FTracks[i].PregapLBA := Cursor;
    if i > 0 then
    begin
      Inc(Cursor, PostGaps[i - 1]);
      Inc(Cursor, Gaps[i]);
      if Index0[i] >= 0 then
      begin
        FTracks[i].StoredPregap := Index1[i] - Index0[i];
        FTracks[i].PregapAudio := FTracks[i].Audio;
        Inc(Cursor, FTracks[i].StoredPregap);
      end;
    end;
    if (i = HighFirst) and (Cursor < 45000) then
    begin
      Inc(FTracks[i].PregapLBA, 45000 - Cursor);
      Cursor := 45000;
    end;
    if HighFirst >= 0 then
    begin
      FTracks[i].Session := 1;
      if i >= HighFirst then
        FTracks[i].Session := 2;
    end;
    FTracks[i].StartLBA := Cursor;
    Inc(Cursor, EndSector - Index1[i]);
    FTracks[i].EndLBA := Cursor;
    for var N := 0 to High(FTracks[i].Indexes) do
    begin
      var Position := FTracks[i].Indexes[N].FileSector;
      if (FTracks[i].Indexes[N].Number > 0) and ((Position < Index1[i]) or (Position >= EndSector)) then
        raise EReadError.Create('CUE index outside its track');
      FTracks[i].Indexes[N].LBA := FTracks[i].StartLBA + Position - Index1[i];
    end;
    var SubName := ChangeFileExt(FTracks[i].SourceName, '.sub');
    try
      var SubPath := CDSibling(Storage, Location, SubName);
      FTracks[i].SubStream := Storage.OpenRead(SubPath);
      FTracks[i].SubRaw := True;
      if FTracks[i].SubStream.Size div 96 < FTracks[i].ByteSize div FTracks[i].SectorSize then
        raise EReadError.Create('Truncated CD subchannel file');
    except
      on E: EReadError do
        if FTracks[i].SubStream <> nil then
          raise;
    end;
  end;
  if Length(FTracks) > 0 then
    FLeadOut := Cursor + PostGaps[High(FTracks)];
  FHighDensity := (HighFirst > 0) and (HighFirst <= High(FTracks));
end;

// Raw data sector: Mode 1 or Mode 2 header after the sync pattern.
function RawDataOffset(Stream: TStream; Position: Int64): Integer;
var
  Header: array[0..15] of Byte;
begin
  Result := 16;
  Stream.Position := Position;
  if (Stream.Read(Header, SizeOf(Header)) = SizeOf(Header)) and (Header[0] = 0) and (Header[1] = $FF) and
    (Header[11] = 0) and (Header[15] = 2) then
    Result := 24;
end;

function SegaBootSector(Stream: TStream; Position: Int64): Boolean;
var
  Text: array[0..15] of AnsiChar;
begin
  Stream.Position := Position;
  Result := (Stream.Read(Text, SizeOf(Text)) = SizeOf(Text)) and CompareMem(@Text[0], PAnsiChar(AnsiString('SEGA SEGAKATANA ')), 16);
end;

// A GDI track line: "number LBA type sectorsize file offset"; the file name
// may be quoted and contain spaces. Tokens holds the four numbers first.
function GDITrackLine(const Value: string; out Tokens: TArray<string>; out FileName: string): Boolean;
begin
  FileName := '';
  var Head := Value;
  var Quote := Pos('"', Value);
  if Quote > 0 then
  begin
    Head := Copy(Value, 1, Quote - 1);
    var Rest := Copy(Value, Quote + 1, MaxInt);
    var Close := Pos('"', Rest);
    if Close = 0 then
      Exit(False);
    FileName := Copy(Rest, 1, Close - 1);
  end;
  Tokens := Head.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  if Quote = 0 then
  begin
    if Length(Tokens) < 5 then
      Exit(False);
    FileName := Tokens[4];
  end
  else if Length(Tokens) < 4 then
    Exit(False);
  Result := FileName <> '';
end;

function ReadGDITrackNames(Stream: TStream): TArray<string>;
begin
  Result := nil;
  if Stream.Size - Stream.Position > 65536 then
    Exit;
  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then
    Stream.ReadBuffer(Data[0], Length(Data));
  var First := True;
  for var Line in TEncoding.UTF8.GetString(Data).TrimLeft([#$FEFF]).Split([#10]) do
  begin
    var Value := Line.Trim;
    if Value = '' then
      Continue;
    if First then
    begin
      First := False;
      Continue;
    end;
    var Tokens: TArray<string>;
    var FileName: string;
    if GDITrackLine(Value, Tokens, FileName) then
      Result := Result + [FileName];
  end;
end;

// GD-ROM track list: count, then "number LBA type sectorsize file offset".
procedure TCDDisc.LoadGDI(Stream: TStream; const Storage: IStorage; const Location: string);
begin
  if Stream.Size - Stream.Position > 65536 then
    raise EReadError.Create('GDI exceeds 64 KiB');
  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then
    Stream.ReadBuffer(Data[0], Length(Data));
  var Lines := TEncoding.UTF8.GetString(Data).TrimLeft([#$FEFF]).Split([#10]);
  var Count := -1;
  for var Line in Lines do
  begin
    var Value := Line.Trim;
    if Value = '' then
      Continue;
    if Count < 0 then
    begin
      Count := StrToIntDef(Value, -1);
      if (Count < 1) or (Count > 99) then
        raise EReadError.Create('Invalid GDI track count');
      Continue;
    end;
    var Tokens: TArray<string>;
    var FileName: string;
    if not GDITrackLine(Value, Tokens, FileName) then
      raise EReadError.Create('Invalid GDI track line');
    var Number := StrToInt(Tokens[0]);
    var Start := StrToInt(Tokens[1]);
    var Kind := StrToInt(Tokens[2]);
    var SectorSize := StrToInt(Tokens[3]);
    if (Number <> Length(FTracks) + 1) or (Start < 0) or (Start > 549150) or
      ((SectorSize <> 2352) and (SectorSize <> 2048)) or ((Kind <> 0) and (Kind <> 4)) then
      raise EReadError.Create('Invalid GDI track');
    var Item := Default(TCDTrack);
    Item.Number := Number;
    Item.Audio := Kind = 0;
    Item.SectorSize := SectorSize;
    Item.LittleEndian := True;
    Item.SourceName := FileName;
    Item.Stream := Storage.OpenRead(CDSibling(Storage, Location, FileName));
    Item.ByteSize := Item.Stream.Size;
    SetLength(FTracks, Length(FTracks) + 1);
    FTracks[High(FTracks)] := Item;
    if Item.ByteSize > Int64(1400) * 1024 * 1024 then
      raise EReadError.Create('GDI track exceeds 1400 MiB');
    if not Item.Audio and (SectorSize = 2352) then
      Item.DataOffset := RawDataOffset(Item.Stream, 0);
    // Some dumps keep the 150-sector pregap in the high-density data file.
    if not Item.Audio and (Start >= 45000) and (SectorSize = 2352) and
      not SegaBootSector(Item.Stream, Item.DataOffset) and SegaBootSector(Item.Stream, Int64(150) * 2352 + Item.DataOffset) then
      Item.FileSector := 150;
    Item.StartLBA := Start;
    Item.PregapLBA := Start;
    Item.EndLBA := Start + Integer(Item.ByteSize div SectorSize) - Item.FileSector;
    Item.Session := 1;
    if Start >= 45000 then
    begin
      Item.Session := 2;
      FHighDensity := True;
    end;
    if (Length(FTracks) > 1) and (Item.StartLBA < FTracks[High(FTracks) - 1].EndLBA) then
      raise EReadError.Create('GDI tracks overlap');
    FTracks[High(FTracks)] := Item;
  end;
  if (Count < 1) or (Length(FTracks) <> Count) then
    raise EReadError.Create('GDI track count does not match its tracks');
  FLeadOut := FTracks[High(FTracks)].EndLBA;
end;

// DiscJuggler image: track data in order from the file start, descriptors
// in a header located through the last eight bytes (version, offset).
procedure TCDDisc.LoadCDI(const Storage: IStorage; const Location: string);
const
  Mark: array[0..9] of Byte = (0, 0, 1, 0, 0, 0, $FF, $FF, $FF, $FF);
var
  Input: TStream;

  function U8: Byte;
  begin
    Input.ReadBuffer(Result, 1);
  end;

  function U16: Word;
  begin
    Input.ReadBuffer(Result, 2);
  end;

  function U32: Cardinal;
  begin
    Input.ReadBuffer(Result, 4);
  end;

  procedure Skip(Count: Integer);
  begin
    Input.Position := Input.Position + Count;
  end;

begin
  Input := Storage.OpenRead(Location);
  try
    var Size := Input.Size;
    if (Size < 1024) or (Size > Int64(1400) * 1024 * 1024) then
      raise EReadError.Create('Invalid CDI size');
    Input.Position := Size - 8;
    var Version := U32;
    var HeaderOffset := U32;
    var V2 := Version = $80000004;
    if ((Version <> $80000004) and (Version <> $80000005) and (Version <> $80000006)) or (HeaderOffset = 0) then
      raise EReadError.Create('Unsupported CDI version');
    // Version 3.5 stores the header offset from the end of the file.
    if Version = $80000006 then
      Input.Position := Size - HeaderOffset
    else
      Input.Position := HeaderOffset;
    if (Input.Position <= 0) or (Input.Position >= Size) then
      raise EReadError.Create('Invalid CDI header offset');
    var Sessions := U16;
    if (Sessions = 0) or (Sessions > 99) then
      raise EReadError.Create('Invalid CDI session count');
    var DataPosition: Int64 := 0;
    for var S := 1 to Sessions do
    begin
      var Tracks := U16;
      if Length(FTracks) + Tracks > 99 then
        raise EReadError.Create('Invalid CDI track count');
      for var T := 1 to Tracks do
      begin
        // Newer versions may prefix eight extra bytes.
        if U32 <> 0 then
          Skip(8);
        var Probe: array[0..9] of Byte;
        for var K := 0 to 1 do
        begin
          Input.ReadBuffer(Probe, 10);
          if not CompareMem(@Probe[0], @Mark[0], 10) then
            raise EReadError.Create('Invalid CDI track descriptor');
        end;
        Skip(4);
        Skip(U8);
        Skip(11 + 4 + 4);
        if U32 = $80000000 then
          Skip(8);
        Skip(2);
        var Pregap := Integer(U32);
        var Length_ := Integer(U32);
        Skip(6);
        var Mode := U32;
        Skip(12);
        var StartLBA := Integer(U32);
        var Total := Integer(U32);
        Skip(16);
        var SectorSize: Integer;
        case U32 of
          0:
            SectorSize := 2048;
          1:
            SectorSize := 2336;
          2:
            SectorSize := 2352;
          4:
            SectorSize := 2448;
        else
          raise EReadError.Create('Unsupported CDI sector size');
        end;
        if (Mode > 2) or (Pregap < 0) or (Length_ <= 0) or (Total < Pregap + Length_) or (StartLBA < 0) or
          (StartLBA > 560000) then
          raise EReadError.Create('Invalid CDI track');
        Skip(29);
        if not V2 then
        begin
          Skip(5);
          if U32 = $FFFFFFFF then
            Skip(78);
        end;
        var Item := Default(TCDTrack);
        Item.Number := Length(FTracks) + 1;
        Item.Session := S;
        Item.Audio := Mode = 0;
        Item.LittleEndian := True;
        Item.SectorSize := SectorSize;
        Item.SourceName := ExtractFileName(Location);
        Item.ByteOffset := DataPosition;
        Item.FileSector := Pregap;
        // CDI start addresses include the 150-sector lead-in offset.
        Item.PregapLBA := StartLBA;
        Item.StartLBA := StartLBA + Pregap - 150;
        if Item.StartLBA < 0 then
          Item.StartLBA := 0;
        Item.EndLBA := Item.StartLBA + Length_;
        if not Item.Audio then
          case SectorSize of
            2336:
              Item.DataOffset := 8;
            2352, 2448:
              if Mode = 2 then
                Item.DataOffset := 24
              else
                Item.DataOffset := 16;
          end;
        Item.Stream := Storage.OpenRead(Location);
        Item.ByteSize := Item.Stream.Size;
        Inc(DataPosition, Int64(Total) * SectorSize);
        if DataPosition > Size then
        begin
          Item.Stream.Free;
          raise EReadError.Create('Truncated CDI track');
        end;
        if (System.Length(FTracks) > 0) and (Item.StartLBA < FTracks[High(FTracks)].EndLBA) then
        begin
          Item.Stream.Free;
          raise EReadError.Create('CDI tracks overlap');
        end;
        SetLength(FTracks, System.Length(FTracks) + 1);
        FTracks[High(FTracks)] := Item;
      end;
      // Session trailer.
      Skip(12);
      if not V2 then
        Skip(1);
    end;
    if System.Length(FTracks) = 0 then
      raise EReadError.Create('CDI has no tracks');
    FLeadOut := FTracks[High(FTracks)].EndLBA;
    // Images of overburned CD-Rs may run past 99 minutes.
    FOverburn := True;
  finally
    Input.Free;
  end;
end;

// Alcohol 120% images (psx-spx "CDROM Disk Images MDS/MDF"). The binary .mds
// holds a block per session, a data block per TOC point (A0h..A2h, then the
// tracks) with an index block (INDEX 00 and INDEX 01 lengths) and the name
// of the sector file ("*.mdf" stands for the .mds name). The .mdf stores the
// sectors from 00:02:00 on, 2048 or 2352 bytes each; 2352-byte sectors may
// carry 96 interleaved P..W subchannel bytes. Pregaps are stored when the
// file continues seamlessly from the previous track of the same session;
// later sessions (multi-session CD-R) start after their lead-in.
procedure TCDDisc.LoadMDS(Stream: TStream; const Storage: IStorage; const Location, FileName: string);
var
  Data: TBytes;
  Pregaps: array[0..98] of Integer;
  Seen: array[0..98] of Boolean;

  procedure Need(Offset, Size: Int64);
  begin
    if (Offset < 0) or (Offset + Size > Length(Data)) then
      raise EReadError.Create('Truncated MDS file');
  end;

  function U8(Offset: Int64): Byte;
  begin
    Need(Offset, 1);
    Result := Data[Offset];
  end;

  function U16(Offset: Int64): Word;
  begin
    Need(Offset, 2);
    Result := Data[Offset] or (Word(Data[Offset + 1]) shl 8);
  end;

  function U32(Offset: Int64): Cardinal;
  begin
    Need(Offset, 4);
    Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
      (Cardinal(Data[Offset + 2]) shl 16) or (Cardinal(Data[Offset + 3]) shl 24);
  end;

  // Non-BCD minute, second and frame as an LBA (00:02:00 = 0).
  function BlockLBA(Block: Int64): Integer;
  begin
    if (U8(Block + 10) >= 60) or (U8(Block + 11) >= 75) then
      raise EReadError.Create('Invalid MDS track position');
    Result := U8(Block + 9) * 4500 + U8(Block + 10) * 75 + U8(Block + 11) - 150;
  end;

  function TrackFileName(Block: Int64): string;
  begin
    if U32(Block + $30) <> 1 then
      raise EReadError.Create('MDS tracks must name one image file');
    var NameBlock := Int64(U32(Block + $34));
    var Offset := Int64(U32(NameBlock));
    var Wide := U8(NameBlock + 4) = 1;
    Result := '';
    repeat
      var C: Word;
      if Wide then
      begin
        C := U16(Offset);
        Inc(Offset, 2);
      end
      else
      begin
        C := U8(Offset);
        Inc(Offset);
      end;
      if C = 0 then
        Break;
      Result := Result + Char(C);
    until Length(Result) > 255;
    if (Result = '') or (Length(Result) > 255) then
      raise EReadError.Create('Invalid MDS image file name');
    if Result.StartsWith('*') then
      Result := ChangeFileExt(FileName, '') + Copy(Result, 2, MaxInt);
  end;

begin
  if Stream.Size - Stream.Position > 1024 * 1024 then
    raise EReadError.Create('MDS exceeds 1 MiB');

  SetLength(Data, Stream.Size - Stream.Position);
  if Length(Data) > 0 then
    Stream.ReadBuffer(Data[0], Length(Data));
  Need(0, $58);
  if TEncoding.ASCII.GetString(Data, 0, 16) <> 'MEDIA DESCRIPTOR' then
    raise EReadError.Create('Not an Alcohol MDS file');
  if U16($12) >= $10 then
    raise EReadError.Create('MDS images of DVD media are not CD images');
  // Session blocks of 24 bytes; tracks are numbered on across sessions and the
  // last session's lead-out ends the disc.
  var Sessions := U16($14);
  if (Sessions < 1) or (Sessions > 99) then
    raise EReadError.Create('Invalid MDS session count');
  var SessionTable := Int64(U32($50));
  var LastTrack := 0;
  for var S := 0 to Sessions - 1 do
  begin
    var Session := SessionTable + Int64(S) * 24;
    var First := U16(Session + $0C);
    var Last := U16(Session + $0E);
    if (First <> LastTrack + 1) or (Last < First) or (Last > 99) then
      raise EReadError.Create('Invalid MDS track range');
    LastTrack := Last;
  end;

  SetLength(FTracks, LastTrack);
  FillChar(Seen, SizeOf(Seen), 0);
  var LeadOut := -1;
  for var S := 0 to Sessions - 1 do
  begin
    var Session := SessionTable + Int64(S) * 24;
    var Blocks := U8(Session + $0A);
    var FirstTrack := U16(Session + $0C);
    var SessionLast := U16(Session + $0E);
    var FirstBlock := Int64(U32(Session + $14));
    for var B := 0 to Blocks - 1 do
    begin
      var Block := FirstBlock + Int64(B) * $50;
      var Point := U8(Block + 4);
      if Point = $A2 then
        LeadOut := BlockLBA(Block);
      if (Point < FirstTrack) or (Point > SessionLast) then
        Continue;
      var I := Point - 1;
      if Seen[I] then
        raise EReadError.Create('Duplicate MDS track');
      Seen[I] := True;

      var Item := Default(TCDTrack);
      Item.Number := Point;
      Item.Audio := (U8(Block + 2) and 4) = 0;
      Item.LittleEndian := True;
      Item.StartLBA := BlockLBA(Block);
      // The PLBA counts from 00:02:00 (sometimes from 00:00:00).
      var Start := Integer(U32(Block + $24));
      if (Start <> Item.StartLBA) and (Start <> Item.StartLBA + 150) then
        raise EReadError.Create('Inconsistent MDS track start');

      var Size := U16(Block + $10);
      var Subchannels := U8(Block + 1);
      if not (((Subchannels = 0) and ((Size = 2352) or ((Size = 2048) and not Item.Audio))) or
        ((Subchannels = 8) and (Size = 2448))) then
        raise EReadError.CreateFmt('Unsupported MDS sector layout (%d bytes, %d subchannels)', [Size, Subchannels]);
      Item.SectorSize := Size;
      Item.SubchannelStored := Subchannels = 8;
      Item.SubRaw := Item.SubchannelStored;

      var Index := Int64(U32(Block + $0C));
      if Index = 0 then
        raise EReadError.Create('MDS track without index block');
      Pregaps[I] := Integer(U32(Index));
      var Length1 := Int64(U32(Index + 4));
      if (Pregaps[I] < 0) or (Pregaps[I] > 450000) or (Length1 <= 0) or (Length1 > 450000) then
        raise EReadError.Create('Invalid MDS track length');
      Item.EndLBA := Item.StartLBA + Integer(Length1);

      var Offset := Int64(U32(Block + $28)) or (Int64(U32(Block + $2C)) shl 32);
      if (Offset < 0) or (Offset mod Size <> 0) then
        raise EReadError.Create('Misaligned MDS track offset');
      Item.FileSector := Integer(Offset div Size);
      Item.SourceName := TrackFileName(Block);
      Item.Stream := Storage.OpenRead(CDSibling(Storage, Location, Item.SourceName));
      FTracks[I] := Item;
      FTracks[I].ByteSize := FTracks[I].Stream.Size;
      if FTracks[I].ByteSize > Int64(800) * 1024 * 1024 then
        raise EReadError.Create('CD track exceeds 800 MiB');

      // Raw data sectors: user data after the Mode 1 or Mode 2 header; the
      // track mode (low nibble Ah Mode 1, Bh..Dh Mode 2) when the header is
      // not readable.
      if not Item.Audio and (Size >= 2352) then
      begin
        var Mode: Byte := 0;
        if Offset + 16 <= FTracks[I].ByteSize then
        begin
          FTracks[I].Stream.Position := Offset + 15;
          FTracks[I].Stream.ReadBuffer(Mode, 1);
        end;
        if not (Mode in [1, 2]) then
          case U8(Block) and $0F of
            $A:
              Mode := 1;
            $B..$D:
              Mode := 2;
          else
            raise EReadError.Create('Unknown MDS data track mode');
          end;
        FTracks[I].DataOffset := 16;
        if Mode = 2 then
          FTracks[I].DataOffset := 24;
      end;
      FTracks[I].Session := Integer(U16(Session + 8));
    end;
  end;

  for var I := 0 to High(FTracks) do
  begin
    if not Seen[I] then
      raise EReadError.Create('MDS track table is incomplete');
    var PregapLBA := Max(0, FTracks[I].StartLBA - Pregaps[I]);
    if I > 0 then
    begin
      var Previous := FTracks[I - 1];
      if PregapLBA < Previous.EndLBA then
        raise EReadError.Create('Overlapping MDS tracks');
      // A new session follows its lead-in; nothing in between is recorded.
      if Previous.Session <> FTracks[I].Session then
      begin
        FTracks[I].PregapLBA := PregapLBA;
        Continue;
      end;
      // Sectors between the TOC entries belong to the previous track.
      FTracks[I - 1].EndLBA := PregapLBA;
      // In one continuous file the pregap lies between the previous track and
      // INDEX 01; the track offset may point at either end of it.
      var Gap := FTracks[I].StartLBA - PregapLBA;
      var Continues := Previous.FileSector + (PregapLBA - Previous.StartLBA);
      if SameText(Previous.SourceName, FTracks[I].SourceName) and
        (Previous.SectorSize = FTracks[I].SectorSize) and (Gap > 0) then
      begin
        if FTracks[I].FileSector = Continues then
          Inc(FTracks[I].FileSector, Gap);
        if FTracks[I].FileSector - Gap = Continues then
        begin
          FTracks[I].StoredPregap := Gap;
          FTracks[I].PregapAudio := FTracks[I].Audio;
        end;
      end;
    end;
    FTracks[I].PregapLBA := PregapLBA;
  end;
  FLeadOut := Max(LeadOut, FTracks[High(FTracks)].EndLBA);
end;

// Nero Burning ROM images. The sectors come first; a footer ("NER5" and a
// 64-bit offset, or "NERO" and a 32-bit one in version 1) points to big-endian
// chunks after them. Per disc-at-once session a CUEX (LBA) or CUES (MSF) cue
// sheet lists INDEX 00/01 positions and a DAOX or DAOI block, for each track,
// the sector size and mode and the file offsets of INDEX 00, INDEX 01 and the
// track end. Track-at-once sessions have an ETN2 or ETNF list (offset, length,
// mode, LBA) instead. Tracks are numbered on across sessions.
procedure TCDDisc.LoadNRG(const Storage: IStorage; const Location: string);
type
  TCuePoint = record
    Track, Index, LBA: Integer;
  end;
var
  Data: TBytes;
  Cues: TArray<TCuePoint>;
  LeadOut, Session: Integer;

  function BE(Offset, Size: Integer): Int64;
  begin
    if (Offset < 0) or (Offset + Size > Length(Data)) then
      raise EReadError.Create('Truncated NRG chunk');
    Result := 0;
    for var I := 0 to Size - 1 do
      Result := (Result shl 8) or Data[Offset + I];
  end;

  function FromBCD(Value: Integer): Integer;
  begin
    Result := (Value shr 4) * 10 + (Value and 15);
  end;

  function CueLBA(Track, Index: Integer; out LBA: Integer): Boolean;
  begin
    for var Cue in Cues do
      if (Cue.Track = Track) and (Cue.Index = Index) then
      begin
        LBA := Cue.LBA;
        Exit(True);
      end;
    Result := False;
  end;

  // Sector layout of a Nero mode code: size, user data offset, audio.
  procedure Layout(Mode: Integer; var Item: TCDTrack);
  begin
    Item.Audio := Mode in [$07, $10];
    case Mode of
      $00, $02:
        Item.SectorSize := 2048;
      $03:
        begin
          Item.SectorSize := 2336;
          Item.DataOffset := 8;
        end;
      $05, $06, $07:
        Item.SectorSize := 2352;
      $0F, $10, $11:
        begin
          Item.SectorSize := 2448;
          Item.SubchannelStored := True;
          Item.SubRaw := True;
        end;
    else
      raise EReadError.CreateFmt('Unsupported NRG track mode %.2xh', [Mode]);
    end;
    if Mode in [$05, $0F] then
      Item.DataOffset := 16
    else if Mode in [$06, $11] then
      Item.DataOffset := 24;
  end;

  procedure AddTrack(var Item: TCDTrack; PregapOffset, StartOffset, EndOffset: Int64; PregapLBA: Integer);
  begin
    var Size := Item.SectorSize;
    if (StartOffset < 0) or (EndOffset <= StartOffset) or (PregapOffset > StartOffset) or
      ((EndOffset - StartOffset) mod Size <> 0) or ((StartOffset - PregapOffset) mod Size <> 0) then
      raise EReadError.Create('Invalid NRG track offsets');
    Item.Number := Length(FTracks) + 1;
    Item.LittleEndian := True;
    Item.Session := Session;
    Item.EndLBA := Item.StartLBA + Integer((EndOffset - StartOffset) div Size);
    Item.PregapLBA := Max(0, Min(PregapLBA, Item.StartLBA));
    // Stored INDEX 00 sectors that lie on the disc (not in the lead-in).
    Item.StoredPregap := Integer(Min(Int64(Item.StartLBA - Item.PregapLBA), (StartOffset - PregapOffset) div Size));
    Item.PregapAudio := Item.Audio and (Item.StoredPregap > 0);
    Item.ByteOffset := StartOffset - Int64(Item.StoredPregap) * Size;
    Item.FileSector := Item.StoredPregap;
    Item.ByteSize := EndOffset - Item.ByteOffset;
    Item.SourceName := ExtractFileName(Location);
    if (Length(FTracks) > 0) and (Item.PregapLBA < FTracks[High(FTracks)].EndLBA) then
      raise EReadError.Create('Overlapping NRG tracks');
    Item.Stream := Storage.OpenRead(Location);
    SetLength(FTracks, Length(FTracks) + 1);
    FTracks[High(FTracks)] := Item;
    if EndOffset > FTracks[High(FTracks)].Stream.Size then
      raise EReadError.Create('Truncated NRG track');
  end;

begin
  var Input := Storage.OpenRead(Location);
  try
    var Size := Input.Size;
    if Size < 12 then
      raise EReadError.Create('Not a Nero NRG image');
    var Tail: array[0..11] of Byte;
    Input.Position := Size - 12;
    Input.ReadBuffer(Tail, 12);
    var V2 := CompareMem(@Tail[0], PAnsiChar(AnsiString('NER5')), 4);
    var Chunks: Int64 := 0;
    if V2 then
      for var I := 4 to 11 do
        Chunks := (Chunks shl 8) or Tail[I]
    else if CompareMem(@Tail[4], PAnsiChar(AnsiString('NERO')), 4) then
      for var I := 8 to 11 do
        Chunks := (Chunks shl 8) or Tail[I]
    else
      raise EReadError.Create('Not a Nero NRG image');
    if (Chunks <= 0) or (Chunks >= Size) or (Size - Chunks > 1024 * 1024) then
      raise EReadError.Create('Invalid NRG chunk offset');
    SetLength(Data, Size - Chunks);
    Input.Position := Chunks;
    Input.ReadBuffer(Data[0], Length(Data));
  finally
    Input.Free;
  end;

  LeadOut := 0;
  Session := 0;
  var Pos := 0;
  while Pos + 8 <= Length(Data) do
  begin
    var Id := TEncoding.ASCII.GetString(Data, Pos, 4);
    var Count := Integer(BE(Pos + 4, 4));
    var Body := Pos + 8;
    if (Count < 0) or (Body + Count > Length(Data)) then
      raise EReadError.Create('Truncated NRG chunk');
    if Id = 'END!' then
      Break;
    if (Id = 'CUEX') or (Id = 'CUES') then
    begin
      Cues := nil;
      var Entry := Body;
      while Entry + 8 <= Body + Count do
      begin
        var Cue: TCuePoint;
        Cue.Track := FromBCD(Data[Entry + 1]);
        if Data[Entry + 1] = $AA then
          Cue.Track := $AA;
        Cue.Index := FromBCD(Data[Entry + 2]);
        if Id = 'CUEX' then
          Cue.LBA := Integer(Cardinal(BE(Entry + 4, 4)))
        else
          Cue.LBA := (FromBCD(Data[Entry + 5]) * 60 + FromBCD(Data[Entry + 6])) * 75 + FromBCD(Data[Entry + 7]) - 150;
        Cues := Cues + [Cue];
        if Cue.Track = $AA then
          LeadOut := Max(LeadOut, Cue.LBA);
        Inc(Entry, 8);
      end;
    end
    else if (Id = 'DAOX') or (Id = 'DAOI') then
    begin
      Inc(Session);
      if Count < 22 then
        raise EReadError.Create('Invalid NRG session');
      var First := Data[Body + 20];
      var Last := Data[Body + 21];
      if (First < 1) or (Last < First) or (Last > 99) then
        raise EReadError.Create('Invalid NRG session');
      // Per track: ISRC, sector size, mode and three file offsets (64-bit in
      // DAOX, 32-bit in DAOI; some writers use 32-bit size and mode fields).
      var Entry := (Count - 22) div (Last - First + 1);
      var Wide: Integer;
      var Head := 18;
      case Entry of
        42:
          Wide := 8;
        30:
          Wide := 4;
        32:
          begin
            Wide := 4;
            Head := 20;
          end;
      else
        raise EReadError.Create('Invalid NRG track entry');
      end;
      for var T := First to Last do
      begin
        var Rec := Body + 22 + (T - First) * Entry;
        var Item := Default(TCDTrack);
        var SectorSize: Integer;
        var Mode: Integer;
        if Head = 18 then
        begin
          SectorSize := Integer(BE(Rec + 12, 2));
          Mode := Data[Rec + 14];
        end
        else
        begin
          SectorSize := Integer(BE(Rec + 12, 4));
          Mode := Data[Rec + 16];
        end;
        Layout(Mode, Item);
        if SectorSize <> Item.SectorSize then
          raise EReadError.Create('NRG sector size does not match the track mode');
        var Index0 := BE(Rec + Head, Wide);
        var Index1 := BE(Rec + Head + Wide, Wide);
        var Stop := BE(Rec + Head + 2 * Wide, Wide);
        var Pregap: Integer;
        if not CueLBA(T, 1, Item.StartLBA) then
          raise EReadError.Create('NRG cue sheet lacks a track start');
        if not CueLBA(T, 0, Pregap) then
          Pregap := Item.StartLBA;
        if T <> Length(FTracks) + 1 then
          raise EReadError.Create('NRG tracks are not numbered in order');
        AddTrack(Item, Index0, Index1, Stop, Pregap);
      end;
    end
    else if (Id = 'ETN2') or (Id = 'ETNF') then
    begin
      Inc(Session);
      var Entry := 20;
      if Id = 'ETN2' then
        Entry := 32;
      var Rec := Body;
      while Rec + Entry <= Body + Count do
      begin
        var Wide := 4;
        if Id = 'ETN2' then
          Wide := 8;
        var Offset := BE(Rec, Wide);
        var Bytes := BE(Rec + Wide, Wide);
        var Item := Default(TCDTrack);
        Layout(Integer(BE(Rec + 2 * Wide, 4)), Item);
        Item.StartLBA := Integer(BE(Rec + 2 * Wide + 4, 4));
        AddTrack(Item, Offset, Offset, Offset + Bytes, Item.StartLBA);
        Inc(Rec, Entry);
      end;
    end;
    Pos := Body + Count;
  end;
  if Length(FTracks) = 0 then
    raise EReadError.Create('NRG image has no tracks');
  FLeadOut := Max(LeadOut, FTracks[High(FTracks)].EndLBA);
end;

const
  CDSync: array[0..11] of Byte = ($00, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $00);

function IsCDRawImage(Stream: TStream): Boolean;
begin
  Result := False;
  var Size := Stream.Size;
  if (Size < 2352 * 16) or (Size mod 2352 <> 0) or (Size > Int64(800) * 1024 * 1024) then
    Exit;

  var Position := Stream.Position;
  try
    var Header: array[0..15] of Byte;
    Stream.Position := 0;
    if Stream.Read(Header, SizeOf(Header)) <> SizeOf(Header) then
      Exit;
    Result := CompareMem(@Header[0], @CDSync[0], SizeOf(CDSync)) and (Header[15] in [1, 2]);
  finally
    Stream.Position := Position;
  end;
end;

// One data track over the whole file; the mode comes from the first sector.
procedure TCDDisc.LoadRaw(const Storage: IStorage; const Location: string);
begin
  SetLength(FTracks, 1);
  FTracks[0].Number := 1;
  FTracks[0].SectorSize := 2352;
  FTracks[0].Stream := Storage.OpenRead(Location);
  FTracks[0].ByteSize := FTracks[0].Stream.Size;
  FTracks[0].SourceName := ExtractFileName(Location);
  if not IsCDRawImage(FTracks[0].Stream) then
    raise EReadError.Create('BIN without CUE must be a raw 2352-byte data track');

  var Header: array[0..15] of Byte;
  FTracks[0].Stream.Position := 0;
  FTracks[0].Stream.ReadBuffer(Header, SizeOf(Header));
  FTracks[0].DataOffset := 16;
  if Header[15] = 2 then
    FTracks[0].DataOffset := 24;
  FTracks[0].EndLBA := FTracks[0].ByteSize div 2352;
end;

procedure TCDDisc.LoadCHD(const Storage: IStorage; const Location: string);
begin
  // GD-ROM images (CHGD track metadata) may exceed a CD's size.
  var Source := OpenCHD(Storage.OpenRead(Location));
  var GDROM := Source.Metadata($43484744, 0) <> ''; // CHGD
  var Input := Storage.OpenRead(Location);
  try
    if (Input.Size > Int64(800) * 1024 * 1024) and not (GDROM and (Input.Size <= Int64(1600) * 1024 * 1024)) then
      raise EReadError.Create('CHD exceeds 800 MiB');

    var Hash := THashSHA2.Create;
    var Buffer: array[0..65535] of Byte;
    repeat
      var N := Input.Read(Buffer, SizeOf(Buffer));
      if N = 0 then
        Break;

      Hash.Update(Buffer, N);
    until False;

    FCompressedHash := Hash.HashAsBytes;
  finally
    Input.Free;
  end;
  FHighDensity := GDROM;
  var FileCursor := 0;
  var Cursor := 0;
  for var I := 0 to 98 do
  begin
    var Metadata := Source.Metadata($43485432, I); // CHT2
    if Metadata = '' then
      Metadata := Source.Metadata($43485452, I); // CHTR
    if Metadata = '' then
      Metadata := Source.Metadata($43484744, I); // CHGD
    if Metadata = '' then
      Break;

    var Number := 0;
    var Frames := 0;
    var Gap := 0;
    var PostGap := 0;
    var Kind := '';
    var GapKind := '';
    var SubKind := '';
    for var Token in Metadata.Split([' '], TStringSplitOptions.ExcludeEmpty) do
    begin
      var Pair := Token.Split([':']);
      if (Length(Pair) = 2) and (Pair[0] = 'SUBTYPE') then
        SubKind := Pair[1];
      if Length(Pair) <> 2 then
        raise EReadError.Create('Invalid CHD track metadata');

      case IndexStr(Pair[0], ['TRACK', 'TYPE', 'FRAMES', 'PREGAP', 'PGTYPE', 'POSTGAP']) of
        0:
          Number := StrToInt(Pair[1]);
        1:
          Kind := Pair[1];
        2:
          Frames := StrToInt(Pair[1]);
        3:
          Gap := StrToInt(Pair[1]);
        4:
          GapKind := Pair[1];
        5:
          PostGap := StrToInt(Pair[1]);
      end;
    end;
    if (Number <> I + 1) or (Frames <= 0) or (Frames > 450000) or
      (Gap < 0) or (Gap > 450000) or (PostGap < 0) or (PostGap > 450000) then
      raise EReadError.Create('Invalid CHD track bounds');

    var Audio := Kind = 'AUDIO';
    if not Audio and (Kind <> 'MODE1') and (Kind <> 'MODE1_RAW') and
      (Kind <> 'MODE1/2048') and (Kind <> 'MODE1/2352') and
      (Kind <> 'MODE2_RAW') and (Kind <> 'MODE2/2352') then
      raise EReadError.Create('Unsupported CHD track type: ' + Kind);

    FileCursor := (FileCursor + 3) and not 3; // CHD pads each track to four sectors.
    var StoredGap := 0;
    // Only the V prefix denotes pregap sectors physically stored in the CHD.
    if GapKind.StartsWith('V') then
      StoredGap := Gap;
    if Frames <= StoredGap then
      raise EReadError.Create('CHD track contains only a pregap');

    // The GD-ROM high-density area starts with track 3 at LBA 45000.
    if GDROM and (Number = 3) and (Cursor + Gap < 45000) then
      Cursor := 45000 - Gap;
    SetLength(FTracks, I + 1);
    var Item := Default(TCDTrack);
    Item.Number := Number;
    Item.Session := 1;
    if GDROM and (Number >= 3) then
      Item.Session := 2;
    Item.Audio := Audio;
    Item.SubRaw := SubKind = 'RW_RAW';
    Item.SubchannelStored := (SubKind = 'RW') or Item.SubRaw;
    Item.StoredPregap := StoredGap;
    Item.PregapAudio := GapKind = 'VAUDIO';
    Item.PregapLBA := Cursor;
    Inc(Cursor, Gap);
    Item.StartLBA := Cursor;
    Inc(Cursor, Frames - StoredGap);
    Item.EndLBA := Cursor;
    Inc(Cursor, PostGap);
    Item.FileSector := FileCursor + StoredGap;
    Inc(FileCursor, Frames);
    Item.SectorSize := 2448;
    if (Kind = 'MODE1_RAW') or (Kind = 'MODE1/2352') then
      Item.DataOffset := 16
    else if (Kind = 'MODE2_RAW') or (Kind = 'MODE2/2352') then
      Item.DataOffset := 24;
    Item.ByteSize := Source.Size;
    Item.Stream := TCHDStream.Create(Source);

    // CHD's CD audio is big-endian; BIN and WAV are little-endian.
    FTracks[I] := Item;
  end;
  FLeadOut := Cursor;
end;

procedure TCDDisc.ValidateAndHash(HashContent: Boolean);
begin
  if (Length(FTracks) = 0) or ((LeadOut > 100 * 60 * 75) and not (FHighDensity or FOverburn)) or (LeadOut > 560000) then
    raise EReadError.Create('CD requires a valid track table shorter than 100 minutes');

  if not HashContent then
  begin
    for var Item in FTracks do
    begin
      var FirstSector := Item.FileSector - Item.StoredPregap;
      var Remaining := Int64(Item.EndLBA - Item.StartLBA + Item.StoredPregap) * Item.SectorSize;
      if (FirstSector < 0) or (Remaining > Item.ByteSize - Int64(FirstSector) * Item.SectorSize) then
        raise EReadError.Create('Truncated CUE track');
    end;
    FIdentityPending := True;
    Exit;
  end;
  FIdentityPending := False;
  var Hash := THashSHA2.Create;
  var Buffer: array[0..65535] of Byte;
  for var Item in FTracks do
  begin
    Hash.Update(TEncoding.UTF8.GetBytes(Format('%d/%d/%d/%d/%d/%d/%d/%d',
          [Item.Number, Item.StartLBA, Item.EndLBA, Item.PregapLBA, Item.FileSector,
            Item.SectorSize, Ord(Item.Audio), Ord(Item.LittleEndian)])));
    for var Index in Item.Indexes do
      if Index.Number > 1 then
        Hash.Update(TEncoding.UTF8.GetBytes(Format('/index/%d/%d', [Index.Number, Index.LBA])));
    if Item.SubStream <> nil then
    begin
      Item.SubStream.Position := 0;
      repeat
        var N := Item.SubStream.Read(Buffer, SizeOf(Buffer));
        if N = 0 then
          Break;
        Hash.Update(Buffer, N);
      until False;
    end;

    // CHD's compressed hash already covers pregap content. CUE identities must
    // include the newly playable INDEX 00 bytes as well as INDEX 01.
    if (Item.StoredPregap > 0) and (Length(FCompressedHash) = 0) then
      Hash.Update(TEncoding.UTF8.GetBytes(Format('/pregap/%d/%d',
            [Item.StoredPregap, Ord(Item.PregapAudio)])));
    var FirstSector := Item.FileSector - Item.StoredPregap;
    var Remaining := Int64(Item.EndLBA - Item.StartLBA + Item.StoredPregap) * Item.SectorSize;
    if (FirstSector < 0) or (Remaining > Item.ByteSize - Int64(FirstSector) * Item.SectorSize) then
      raise EReadError.Create('Truncated CUE track');

    Item.Stream.Position := Item.ByteOffset + Int64(FirstSector) * Item.SectorSize;

    if Length(FCompressedHash) > 0 then
      Continue;

    while Remaining > 0 do
    begin
      var Count := Integer(Min(Int64(SizeOf(Buffer)), Remaining));
      Item.Stream.ReadBuffer(Buffer, Count);
      Hash.Update(Buffer, Count);
      Dec(Remaining, Count);
    end;
  end;
  Hash.Update(FCompressedHash);
  FIdentity := Hash.HashAsBytes;
end;

procedure TCDDisc.RequireISO9660;
begin
  for var Track in FTracks do
  begin
    if Track.Audio then
      Continue;
    if Track.EndLBA - Track.StartLBA < 17 then
      Break;
    var Sector: TBytes;
    ReadData(Track.StartLBA + 16, Sector);
    if (Sector[0] = 1) and CompareMem(@Sector[1], PAnsiChar(AnsiString('CD001')), 5) then
      Exit;
    Break;
  end;
  raise EReadError.Create('CD data track requires ISO 9660');
end;

function TCDDisc.ReadISOFile(const Name: string; MaximumSize: Integer): TBytes;

  function LE32(const Bytes: TBytes; Offset: Integer): Cardinal;
  begin
    Result := Cardinal(Bytes[Offset]) or (Cardinal(Bytes[Offset + 1]) shl 8) or
      (Cardinal(Bytes[Offset + 2]) shl 16) or (Cardinal(Bytes[Offset + 3]) shl 24);
  end;

begin
  Result := nil;
  if (MaximumSize <= 0) or (MaximumSize > 65536) or (Length(FTracks) = 0) or FTracks[0].Audio then
    Exit;
  var First := FTracks[0];
  var Sectors := First.EndLBA - First.StartLBA;
  if Sectors < 17 then
    Exit;
  var Sector: TBytes;
  ReadData(First.StartLBA + 16, Sector);
  if (Sector[0] <> 1) or not CompareMem(@Sector[1], PAnsiChar(AnsiString('CD001')), 5) then
    Exit;
  var Root := LE32(Sector, 158);
  var Size := LE32(Sector, 166);
  if (Size = 0) or (Size > 65536) or (Root >= Cardinal(Sectors)) or
    (Int64(Root) + (Int64(Size) + 2047) div 2048 > Sectors) then
    Exit;
  var Offset := 0;
  while Offset < Integer(Size) do
  begin
    ReadData(First.StartLBA + Integer(Root) + Offset div 2048, Sector);
    var Cursor := 0;
    var Remaining := Min(2048, Integer(Size) - Offset);
    while Cursor < Remaining do
    begin
      var RecordSize := Integer(Sector[Cursor]);
      if RecordSize = 0 then
        Break;
      if (RecordSize < 34) or (Cursor + RecordSize > Remaining) then
        Exit;
      var NameSize := Integer(Sector[Cursor + 32]);
      if NameSize > RecordSize - 33 then
        Exit;
      var Identifier := TEncoding.ASCII.GetString(Sector, Cursor + 33, NameSize);
      var Version := Pos(';', Identifier);
      if Version > 0 then
        Identifier := Copy(Identifier, 1, Version - 1);
      if SameText(Identifier, Name) and ((Sector[Cursor + 25] and $82) = 0) then
      begin
        var Extent := LE32(Sector, Cursor + 2);
        var FileSize := LE32(Sector, Cursor + 10);
        if (FileSize = 0) or (FileSize > Cardinal(MaximumSize)) or
          (Extent >= Cardinal(Sectors)) or
          (Int64(Extent) + (Int64(FileSize) + 2047) div 2048 > Sectors) then
          Exit;
        SetLength(Result, FileSize);
        var Copied := 0;
        while Copied < Integer(FileSize) do
        begin
          ReadData(First.StartLBA + Integer(Extent) + Copied div 2048, Sector);
          var Count := Min(2048, Integer(FileSize) - Copied);
          Move(Sector[0], Result[Copied], Count);
          Inc(Copied, Count);
        end;
        Exit;
      end;
      Inc(Cursor, RecordSize);
    end;
    Inc(Offset, 2048);
  end;
end;

function TCDDisc.TrackAt(LBA: Integer): Integer;
begin
  Result := -1;
  for var I := 0 to High(FTracks) do
    if (LBA >= FTracks[I].PregapLBA) and (LBA < FTracks[I].EndLBA) then
      Exit(I);
end;

function TCDDisc.Track(Number: Integer): TCDTrack;
begin
  if (Number < 1) or (Number > Length(FTracks)) then
    raise EReadError.Create('Invalid CD track number');

  Result := FTracks[Number - 1];
end;

function TCDDisc.TrackCount: Integer;
begin
  Result := Length(FTracks);
end;

function TCDDisc.LeadOut: Integer;
begin
  Result := FLeadOut;
end;

function TCDDisc.IsData(LBA: Integer): Boolean;
begin
  var i := TrackAt(LBA);
  Result := (i >= 0) and not FTracks[i].Audio and (LBA >= FTracks[i].StartLBA);
end;

procedure TCDDisc.ReadData(LBA: Integer; var Sector: TBytes);
begin
  var i := TrackAt(LBA);
  if (i < 0) or FTracks[i].Audio or (LBA < FTracks[i].StartLBA) then
    raise EReadError.Create('CD data read outside data track');

  var Item := FTracks[i];
  SetLength(Sector, 2048);
  Item.Stream.Position := Item.ByteOffset + Int64(Item.FileSector + LBA - Item.StartLBA) *
    Item.SectorSize + Item.DataOffset;
  Item.Stream.ReadBuffer(Sector[0], 2048);
end;

procedure TCDDisc.ReadAudio(LBA: Integer; var Sector: TBytes);
begin
  SetLength(Sector, 2352);
  FillChar(Sector[0], 2352, 0);
  var i := TrackAt(LBA);
  if (i < 0) or not FTracks[i].Audio then
    Exit;

  var Item := FTracks[i];
  // PREGAP/POSTGAP silence precedes any stored INDEX 00 audio.
  if (LBA < Item.StartLBA) and (not Item.PregapAudio or (LBA < Item.StartLBA - Item.StoredPregap)) then
    Exit;

  Item.Stream.Position := Item.ByteOffset + Int64(Item.FileSector + LBA - Item.StartLBA) * Item.SectorSize;
  Item.Stream.ReadBuffer(Sector[0], 2352);
  if not Item.LittleEndian then
    for var N := 0 to 1175 do
    begin
      var B := Sector[N * 2];
      Sector[N * 2] := Sector[N * 2 + 1];
      Sector[N * 2 + 1] := B;
    end;
end;

function CDDataEDC(const Data: TBytes; Count: Integer): Cardinal;
begin
  if (Count < 0) or (Count > Length(Data)) then
    raise EArgumentOutOfRangeException.Create('Invalid CD EDC range');
  Result := 0;
  for var I := 0 to Count - 1 do
  begin
    Result := Result xor Data[I];
    for var Bit := 0 to 7 do
      if (Result and 1) <> 0 then
        Result := (Result shr 1) xor $D8018001
      else
        Result := Result shr 1;
  end;
end;

function CDCorrectMode1(var Sector: TBytes): Boolean;
var
  ForwardGF, BackwardGF: array[0..255] of Byte;
  Work: TBytes;

  function CRCValid(const Data: TBytes): Boolean;
  begin
    Result := (Data[15] = 1) and (CDDataEDC(Data, 2064) =
      (Cardinal(Data[2064]) or (Cardinal(Data[2065]) shl 8) or
      (Cardinal(Data[2066]) shl 16) or (Cardinal(Data[2067]) shl 24)));
  end;

  function Multiply(A, B: Byte): Byte;
  begin
    Result := 0;
    while B <> 0 do
    begin
      if (B and 1) <> 0 then
        Result := Result xor A;
      A := ForwardGF[A];
      B := B shr 1;
    end;
  end;

  function Divide(A, B: Byte): Byte;
  begin
    // Inversion by Fermat: b^-1 = b^254 in GF(256).
    var Power: Byte := 1;
    var Base := B;
    var Exponent := 254;
    while Exponent > 0 do
    begin
      if Odd(Exponent) then
        Power := Multiply(Power, Base);
      Base := Multiply(Base, Base);
      Exponent := Exponent shr 1;
    end;
    Result := Multiply(A, Power);
  end;

  function Repair(MajorCount, MinorCount, MajorMult, MinorInc, Destination: Integer): Integer;
  var
    CoeffA, CoeffB: array[0..44] of Byte;
  begin
    Result := 0;
    for var Position := 0 to MinorCount - 1 do
    begin
      var A: Byte := 0;
      var B: Byte := 0;
      for var Minor := 0 to MinorCount - 1 do
      begin
        var Value := Byte(Ord(Minor = Position));
        A := ForwardGF[A xor Value];
        B := B xor Value;
      end;
      A := BackwardGF[ForwardGF[A] xor B];
      CoeffA[Position] := A;
      CoeffB[Position] := A xor B;
    end;
    CoeffA[MinorCount] := 1;
    CoeffB[MinorCount] := 0;
    CoeffA[MinorCount + 1] := 0;
    CoeffB[MinorCount + 1] := 1;
    var Size := MajorCount * MinorCount;
    for var Major := 0 to MajorCount - 1 do
    begin
      var Start := (Major shr 1) * MajorMult + (Major and 1);
      var Index := Start;
      var A: Byte := 0;
      var B: Byte := 0;
      for var Minor := 0 to MinorCount - 1 do
      begin
        var Value := Work[12 + Index];
        A := ForwardGF[A xor Value];
        B := B xor Value;
        Index := (Index + MinorInc) mod Size;
      end;
      A := BackwardGF[ForwardGF[A] xor B];
      var SA := Byte(Work[Destination + Major] xor A);
      var SB := Byte(Work[Destination + MajorCount + Major] xor A xor B);
      if (SA = 0) and (SB = 0) then
        Continue;
      for var Position := 0 to MinorCount + 1 do
      begin
        var Delta: Byte;
        if CoeffA[Position] <> 0 then
          Delta := Divide(SA, CoeffA[Position])
        else
          Delta := Divide(SB, CoeffB[Position]);
        if (Delta = 0) or (Multiply(Delta, CoeffA[Position]) <> SA) or
          (Multiply(Delta, CoeffB[Position]) <> SB) then
          Continue;
        var Address := Destination + Major;
        if Position < MinorCount then
          Address := 12 + (Start + Position * MinorInc) mod Size
        else if Position = MinorCount + 1 then
          Inc(Address, MajorCount);
        Work[Address] := Work[Address] xor Delta;
        Inc(Result);
        Break;
      end;
    end;
  end;

begin
  Result := False;
  if Length(Sector) <> 2352 then
    Exit;
  if CRCValid(Sector) then
    Exit(True);
  Work := Copy(Sector);
  for var I := 0 to 255 do
  begin
    var J := I shl 1;
    if (I and $80) <> 0 then
      J := J xor $11D;
    ForwardGF[I] := J;
    BackwardGF[I xor J] := I;
  end;
  for var Pass := 0 to 3 do
  begin
    var Changes := Repair(86, 24, 2, 86, 2076);
    Inc(Changes, Repair(52, 43, 86, 88, 2248));
    if CRCValid(Work) then
    begin
      Sector := Work;
      Exit(True);
    end;
    if Changes = 0 then
      Exit;
  end;
end;

function CDBCD(Value: Integer): Byte;
begin
  Result := (Value div 10) * 16 + Value mod 10;
end;

function CDQCRC(const Q: TBytes): Word;
begin
  var CRC: Cardinal := 0;
  for var I := 0 to 9 do
  begin
    CRC := CRC xor (Cardinal(Q[I]) shl 8);
    for var Bit := 0 to 7 do
      if (CRC and $8000) <> 0 then
        CRC := ((CRC shl 1) xor $1021) and $FFFF
      else
        CRC := (CRC shl 1) and $FFFF;
  end;
  Result := Word(CRC xor $FFFF);
end;

function TCDDisc.IndexAt(LBA: Integer): Integer;
begin
  var N := TrackAt(LBA);
  if N < 0 then
    Exit(1);
  var Item := FTracks[N];
  if LBA < Item.StartLBA then
    Exit(0);
  Result := 1;
  for var Index in Item.Indexes do
    if (Index.Number > 0) and (Index.LBA <= LBA) then
      Result := Index.Number;
end;

function TCDDisc.HasIndexes(LBA: Integer): Boolean;
begin
  Result := False;
  var N := TrackAt(LBA);
  if N < 0 then
    Exit;
  for var Index in FTracks[N].Indexes do
    if Index.Number > 1 then
      Exit(True);
end;

procedure TCDDisc.ReadRawData(LBA: Integer; var Sector: TBytes);
var
  ForwardGF, BackwardGF: array[0..255] of Byte;

  procedure Parity(MajorCount, MinorCount, MajorMult, MinorInc, Destination: Integer);
  begin
    var Size := MajorCount * MinorCount;
    for var Major := 0 to MajorCount - 1 do
    begin
      var Index := (Major shr 1) * MajorMult + (Major and 1);
      var A: Byte := 0;
      var B: Byte := 0;
      for var Minor := 0 to MinorCount - 1 do
      begin
        var Value := Sector[12 + Index];
        A := A xor Value;
        B := B xor Value;
        A := ForwardGF[A];
        Index := (Index + MinorInc) mod Size;
      end;
      A := BackwardGF[ForwardGF[A] xor B];
      Sector[Destination + Major] := A;
      Sector[Destination + MajorCount + Major] := A xor B;
    end;
  end;

begin
  var N := TrackAt(LBA);
  if not IsData(LBA) then
    raise EReadError.Create('CD raw read outside data track');
  var Item := FTracks[N];
  SetLength(Sector, 2352);
  if Item.DataOffset in [16, 24] then
  begin
    Item.Stream.Position := Item.ByteOffset + Int64(Item.FileSector + LBA - Item.StartLBA) * Item.SectorSize;
    Item.Stream.ReadBuffer(Sector[0], 2352);
    Exit; // Preserve the dumped header, parity and intentional errors.
  end;
  FillChar(Sector[0], Length(Sector), 0);
  for var I := 1 to 10 do
    Sector[I] := $FF;
  var Position := LBA + 150;
  Sector[12] := CDBCD(Position div 4500);
  Sector[13] := CDBCD((Position div 75) mod 60);
  Sector[14] := CDBCD(Position mod 75);
  Sector[15] := 1;
  var Data: TBytes;
  ReadData(LBA, Data);
  Move(Data[0], Sector[16], 2048);
  var EDC := CDDataEDC(Sector, 2064);
  for var I := 0 to 3 do
    Sector[2064 + I] := Byte(EDC shr (I * 8));
  // ECMA-130 Mode 1: P(26,24), then Q(45,43) including P parity.
  for var I := 0 to 255 do
  begin
    var J := I shl 1;
    if (I and $80) <> 0 then
      J := J xor $11D;
    ForwardGF[I] := J;
    BackwardGF[I xor J] := I;
  end;
  Parity(86, 24, 2, 86, 2076);
  Parity(52, 43, 86, 88, 2248);
end;

function TCDDisc.ReadSubQ(LBA: Integer; var Q: TBytes): Boolean;

  function ValidBCD(Value: Byte; Limit: Integer): Boolean;
  begin
    Result := ((Value and 15) <= 9) and ((Value shr 4) <= 9) and
      ((Value shr 4) * 10 + (Value and 15) < Limit);
  end;

begin
  SetLength(Q, 12);
  FillChar(Q[0], 12, 0);
  Result := False;
  var N := TrackAt(LBA);
  if N < 0 then
    Exit;
  var Item := FTracks[N];
  var FilePosition := Item.FileSector + LBA - Item.StartLBA;
  if (FilePosition >= 0) and (LBA >= Item.StartLBA - Item.StoredPregap) and
    ((Item.SubStream <> nil) or Item.SubchannelStored) then
  begin
    var Sub: array[0..95] of Byte;
    if Item.SubStream <> nil then
    begin
      Item.SubStream.Position := Int64(FilePosition) * 96;
      Item.SubStream.ReadBuffer(Sub, 96);
    end
    else
    begin
      Item.Stream.Position := Item.ByteOffset + Int64(FilePosition) * Item.SectorSize + 2352;
      Item.Stream.ReadBuffer(Sub, 96);
    end;
    if Item.SubRaw then
      for var I := 0 to 95 do
        Q[I div 8] := Q[I div 8] or (((Sub[I] shr 6) and 1) shl (7 - I mod 8))
    else
      Move(Sub[12], Q[0], 12);
    var CRC := CDQCRC(Q);
    Result := ((Q[0] and 15) = 1) and (Q[6] = 0) and
      (Q[10] = CRC shr 8) and (Q[11] = (CRC and $FF)) and
      ValidBCD(Q[1], 100) and ValidBCD(Q[2], 100) and
      ValidBCD(Q[3], 100) and ValidBCD(Q[4], 60) and ValidBCD(Q[5], 75) and
      ValidBCD(Q[7], 100) and ValidBCD(Q[8], 60) and ValidBCD(Q[9], 75) and
      not SBIInvalidCRC(LBA);
    Exit;
  end;
  // Reconstruct ordinary Q around the bad sectors recorded by SBI. Without
  // any SBI, False still distinguishes synthetic Q from a measured dump.
  Q[0] := $41;
  if Item.Audio then
    Q[0] := 1;
  Q[1] := CDBCD(Item.Number);
  Q[2] := CDBCD(IndexAt(LBA));
  var Relative := Abs(LBA - Item.StartLBA);
  Q[3] := CDBCD(Relative div 4500);
  Q[4] := CDBCD((Relative div 75) mod 60);
  Q[5] := CDBCD(Relative mod 75);
  var absolute := LBA + 150;
  Q[7] := CDBCD(absolute div 4500);
  Q[8] := CDBCD((absolute div 75) mod 60);
  Q[9] := CDBCD(absolute mod 75);
  var CRC := CDQCRC(Q);
  Q[10] := CRC shr 8;
  Q[11] := CRC and $FF;
  if SBIInvalidCRC(LBA) then
    Q[10] := Q[10] xor $80
  else
    Result := Length(FSBIInvalidCRC) <> 0;
end;

function TCDDisc.Identity: TBytes;
begin
  if FIdentityPending then
    ValidateAndHash(True);
  Result := Copy(FIdentity);
end;

end.

