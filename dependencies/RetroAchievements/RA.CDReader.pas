unit RA.CDReader;

interface

{$SCOPEDENUMS ON}

uses
  System.Classes, RA.ArchiveHash, RA.DiscHash;

// The caller owns the returned stream. A custom opener supplies files and companions.
function OpenRAHashFile(const Path: string; const OpenFile: TRAOpenArchive): TStream;

// Opens the tracks named by a CUE or GDI descriptor.
function CreateRADescriptorDiscReader(const Path: string; const OpenFile: TRAOpenArchive = nil): TRAOpenDiscTrack;

// The stream is borrowed for the entire life of the returned track.
function TryOpenRARawDiscTrack(Stream: TStream; Number: Cardinal; out Track: TRADiscTrack): Boolean;

implementation

uses
  System.Generics.Collections, System.Math, System.SysUtils, RA.Streams;

type
  TRATrackLayout = record
    Number, Session: Cardinal;
    FileIndex, SectorSize, PayloadOffset, PayloadSize: Integer;
    FileName: string;
    FileOffset, FileEndOffset, FirstIndex, DataIndex, FirstSector, SectorCount: Int64;
    Data, RequireDetectedGeometry: Boolean;
    function LimitFileSize(Size: Int64): Int64;
  end;

  IRAReadTrack = interface
    ['{9791BF95-8FF3-48D2-BF8F-D44C269361A6}']
    function Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

  TRAReadTrack = class(TInterfacedObject, IRAReadTrack)
  private
    FStream: TStream;
    FOwnsStream: Boolean;
    FStart, FLimit: Int64;
    FLayout: TRATrackLayout;
    function DetectGeometry(Pregap: Int64; KeepFirstSector: Boolean): Boolean;
  public
    constructor Create(Stream: TStream; OwnsStream: Boolean; const Layout: TRATrackLayout);
    destructor Destroy; override;
    function Open(KeepFirstSector, Raw: Boolean; out Track: TRADiscTrack): Boolean;
    function Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
  end;

  IRAFileDisc = interface
    ['{60755DD9-8787-4163-9ED0-07B4094A526A}']
    function OpenTrack(Number: Cardinal; out Track: TRADiscTrack): Boolean;
  end;

  TRAFileDisc = class(TInterfacedObject, IRAFileDisc)
  private
    FOpenFile: TRAOpenArchive;
    FTracks: TArray<TRATrackLayout>;
    FGDI, FIncompleteDescriptor: Boolean;
    function ReadCUE(const Path: string; Lines: TStrings): Boolean;
    function ReadGDI(const Path: string; Lines: TStrings): Boolean;
    function FileSize(const Path: string): Int64;
    function CueSectorCount(const Track: TRATrackLayout): Int64;
    function ResolveCueStart(Index: Integer; var Layout: TRATrackLayout): Boolean;
    function SelectTrack(Number: Cardinal): Integer;
  public
    constructor Create(const Path: string; const OpenFile: TRAOpenArchive);
    function OpenTrack(Number: Cardinal; out Track: TRADiscTrack): Boolean;
  end;

function OpenRAHashFile(const Path: string; const OpenFile: TRAOpenArchive): TStream;
begin
  if Path = '' then
    Exit(nil);
  if Assigned(OpenFile) then
    Exit(OpenFile(Path));

  try
    Result := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    on EFOpenError do
      Result := nil;
  end;
end;

function TrackPath(const Descriptor, Name: string): string;
begin
  if Name.StartsWith('/') or Name.StartsWith('\') or Name.Contains(':/') or Name.Contains(':\') then
    Exit(Name);
  Result := Copy(Descriptor, 1, LastDelimiter('/\', Descriptor)) + Name;
end;

function ReadFields(const Line: string): TArray<string>;
var
  Index, Start: Integer;
begin
  Result := nil;
  Index := 1;
  while Index <= Length(Line) do
  begin
    if Line[Index] <= ' ' then
    begin
      Inc(Index);
      Continue;
    end;
    if Line[Index] = '"' then
    begin
      Inc(Index);
      Start := Index;
      while (Index <= Length(Line)) and (Line[Index] <> '"') do
        Inc(Index);
      if Index > Length(Line) then
        Exit(nil);
      Result := Result + [Copy(Line, Start, Index - Start)];
    end
    else
    begin
      Start := Index;
      while (Index <= Length(Line)) and (Line[Index] > ' ') do
        Inc(Index);
      Result := Result + [Copy(Line, Start, Index - Start)];
    end;
    Inc(Index);
  end;
end;

function TryCueSector(const Text: string; out Sector: Int64): Boolean;
var
  Fields: TArray<string>;
  Minutes, Seconds, Frames: Integer;
begin
  Fields := Text.Split([':']);
  Result := (Length(Fields) = 3) and TryStrToInt(Fields[0], Minutes) and TryStrToInt(Fields[1], Seconds) and
    TryStrToInt(Fields[2], Frames) and (Minutes >= 0) and (Seconds >= 0) and (Seconds < 60) and
    (Frames >= 0) and (Frames < 75);
  if Result then
    Sector := (Int64(Minutes) * 60 + Seconds) * 75 + Frames;
end;

function SetCueMode(const Mode: string; var Track: TRATrackLayout): Boolean;
begin
  Track.Data := Mode <> 'AUDIO';
  Track.PayloadSize := 2048;
  if (Mode = 'MODE1/2048') or (Mode = 'MODE2/2048') then
  begin
    Track.SectorSize := 2048;
    // Upstream opens MODE2/2048 only when it recognizes the track geometry.
    Track.RequireDetectedGeometry := Mode = 'MODE2/2048';
  end
  else if Mode = 'MODE2/2336' then
  begin
    Track.SectorSize := 2336;
    Track.PayloadOffset := 8;
  end
  else if Mode = 'MODE1/2352' then
  begin
    Track.SectorSize := 2352;
    Track.PayloadOffset := 16;
  end
  else if Mode = 'MODE2/2352' then
  begin
    Track.SectorSize := 2352;
    Track.PayloadOffset := 24;
  end
  else if Mode = 'AUDIO' then
  begin
    Track.SectorSize := 2352;
    Track.PayloadSize := 2352;
  end
  else if (Mode.StartsWith('MODE1/') or Mode.StartsWith('MODE2/')) and
    TryStrToInt(Copy(Mode, 7, MaxInt), Track.SectorSize) and (Track.SectorSize > 0) and (Track.SectorSize <= High(Word)) then
    // The declared stride locates the track, but only detected geometry can open it.
    Track.RequireDetectedGeometry := True
  else
    Exit(False);
  Result := True;
end;

function TRATrackLayout.LimitFileSize(Size: Int64): Int64;
begin
  Result := Size;
  if FileEndOffset > 0 then
    Result := Min(Size, FileEndOffset);
end;

constructor TRAReadTrack.Create(Stream: TStream; OwnsStream: Boolean; const Layout: TRATrackLayout);
begin
  inherited Create;
  FStream := Stream;
  FOwnsStream := OwnsStream;
  FStart := Stream.Position;
  FLimit := Layout.LimitFileSize(Stream.Size - FStart);
  FLayout := Layout;
end;

destructor TRAReadTrack.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

function FromBCD(Value: Byte): Integer;
begin
  Result := (Value shr 4) * 10 + (Value and $F);
end;

function TRAReadTrack.DetectGeometry(Pregap: Int64; KeepFirstSector: Boolean): Boolean;
const
  Sync: array[0..11] of Byte = (0, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, 0);
  PVD: AnsiString = 'CD001';
  RawSizes: array[0..1] of Integer = (2352, 2336);
var
  Header: array[0..31] of Byte;
  TableSector: Int64;

  function ReadHeader(Stride: Integer): Boolean;
  var
    Position: Int64;
  begin
    if TableSector > (FLimit - FLayout.FileOffset) div Stride then
      Exit(False);
    Position := FLayout.FileOffset + TableSector * Stride;
    if FLimit - Position < SizeOf(Header) then
      Exit(False);
    FStream.Position := FStart + Position;
    Result := ReadRAStream(FStream, Header, SizeOf(Header)) = SizeOf(Header);
  end;

begin
  TableSector := 16 + Pregap;
  for var Stride in RawSizes do
    if ReadHeader(Stride) and CompareMem(@Header[0], @Sync[0], SizeOf(Sync)) then
    begin
      FLayout.SectorSize := Stride;
      FLayout.PayloadSize := 2048;
      if CompareMem(@Header[25], PAnsiChar(PVD), Length(PVD)) then
        FLayout.PayloadOffset := 24
      else
        FLayout.PayloadOffset := 16;
      if not KeepFirstSector then
        FLayout.FirstSector := (FromBCD(Header[12]) * 60 + FromBCD(Header[13])) * 75 +
          FromBCD(Header[14]) - 150 - TableSector;
      Exit(True);
    end;

  Result := ReadHeader(2048) and CompareMem(@Header[1], PAnsiChar(PVD), Length(PVD));
  if Result then
  begin
    FLayout.SectorSize := 2048;
    FLayout.PayloadOffset := 0;
    FLayout.PayloadSize := 2048;
  end;
end;

function TRAReadTrack.Open(KeepFirstSector, Raw: Boolean; out Track: TRADiscTrack): Boolean;
var
  Pregap, DataSector, Size: Int64;
  DetectedGeometry: Boolean;
  Reader: IRAReadTrack;
begin
  Track := Default(TRADiscTrack);
  Size := FLimit - FLayout.FileOffset;
  if (Size <= 0) or (FLayout.FileOffset < 0) then
    Exit(False);
  Pregap := FLayout.DataIndex - FLayout.FirstIndex;
  DetectedGeometry := DetectGeometry(Pregap, KeepFirstSector);
  if FLayout.RequireDetectedGeometry and not DetectedGeometry then
    Exit(False);
  if Raw and not DetectedGeometry then
  begin
    FLayout.PayloadSize := 2048;
    if Size mod 2352 = 0 then
    begin
      FLayout.SectorSize := 2352;
      FLayout.PayloadOffset := 24;
    end
    else if Size mod 2048 = 0 then
      FLayout.SectorSize := 2048
    else if Size mod 2336 = 0 then
    begin
      FLayout.SectorSize := 2336;
      FLayout.PayloadOffset := 8;
    end
    else
      Exit(False);
  end;

  DataSector := FLayout.FirstSector + Pregap;
  if (DataSector < 0) or (DataSector > High(Cardinal)) or (FLayout.SectorSize = 0) then
    Exit(False);

  Reader := Self;
  Track.FirstSector := Cardinal(DataSector);
  Track.Read :=
    function(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
    begin
      Result := Reader.Read(Sector, Buffer, Count);
    end;
  Result := True;
end;

function TRAReadTrack.Read(Sector: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
var
  Index, Position: Int64;
  Chunk, ReadCount: Integer;
begin
  Result := 0;
  Index := Int64(Sector) - FLayout.FirstSector;
  if (Index < 0) or (Buffer = nil) or (Index > (FLimit - FLayout.FileOffset) div FLayout.SectorSize) then
    Exit;

  Position := FLayout.FileOffset + Index * FLayout.SectorSize;
  if FLayout.PayloadOffset >= FLimit - Position then
    Exit;
  Inc(Position, FLayout.PayloadOffset);
  while (Count <> 0) and (Position < FLimit) do
  begin
    Chunk := Integer(Min(UInt64(Count), UInt64(FLayout.PayloadSize)));
    Chunk := Integer(Min(Int64(Chunk), FLimit - Position));
    FStream.Position := FStart + Position;
    ReadCount := ReadRAStream(FStream, Buffer^, Chunk);
    if ReadCount <= 0 then
      Exit;
    Inc(Result, Cardinal(ReadCount));
    Inc(Buffer, ReadCount);
    Dec(Count, Cardinal(ReadCount));
    if (ReadCount < Chunk) or (FLimit - Position <= FLayout.SectorSize) then
      Exit;
    Inc(Position, FLayout.SectorSize);
  end;
end;

function TryOpenRARawDiscTrack(Stream: TStream; Number: Cardinal; out Track: TRADiscTrack): Boolean;
var
  Reader: TRAReadTrack;
  Owner: IRAReadTrack;
begin
  Track := Default(TRADiscTrack);
  if (Stream = nil) or ((Number > 1) and (Number <> RAFirstDataTrack) and
    (Number <> RALargestTrack) and (Number <> RALastTrack)) then
    Exit(False);
  Reader := TRAReadTrack.Create(Stream, False, Default(TRATrackLayout));
  Owner := Reader;
  Result := Reader.Open(False, True, Track);
end;

function TRAFileDisc.FileSize(const Path: string): Int64;
var
  Stream: TStream;
begin
  Stream := OpenRAHashFile(Path, FOpenFile);
  if Stream = nil then
    Exit(0);
  try
    Result := Stream.Size - Stream.Position;
  finally
    Stream.Free;
  end;
end;

function TRAFileDisc.ReadCUE(const Path: string; Lines: TStrings): Boolean;
var
  Tracks: TList<TRATrackLayout>;
  Current, Previous: TRATrackLayout;
  ValidCount: Integer;
  Offset: Int64;

  function ReadCueLines: Boolean;
  var
    Current: TRATrackLayout;
    Name: string;
    Fields: TArray<string>;
    FileIndex, CurrentIndex, Marker: Integer;
    Session: Cardinal;
    IndexSector: Int64;
  begin
    Result := False;
    Name := '';
    FileIndex := 0;
    Session := 1;
    CurrentIndex := -1;
    for var Line in Lines do
    begin
      Fields := ReadFields(Line);
      if Length(Fields) = 0 then
        Continue;
      if SameText(Fields[0], 'FILE') then
      begin
        if (Length(Fields) < 3) or (Fields[1] = '') then
          Exit;
        Name := TrackPath(Path, Fields[1]);
        Inc(FileIndex);
        CurrentIndex := -1;
      end
      else if SameText(Fields[0], 'TRACK') then
      begin
        Current := Default(TRATrackLayout);
        if (Name = '') or (Length(Fields) < 3) or not TryStrToUInt(Fields[1], Current.Number) or
          (Current.Number = 0) or not SetCueMode(UpperCase(Fields[2]), Current) then
          Exit;
        if (Tracks.Count <> 0) and (Current.Number <= Tracks.Last.Number) then
          Exit;
        Current.FileIndex := FileIndex;
        Current.FileName := Name;
        Current.Session := Session;
        Current.FirstIndex := -1;
        Current.DataIndex := -1;
        CurrentIndex := Tracks.Add(Current);
      end
      else if SameText(Fields[0], 'INDEX') then
      begin
        if (CurrentIndex < 0) or (Length(Fields) < 3) or not TryStrToInt(Fields[1], Marker) or
          not TryCueSector(Fields[2], IndexSector) then
          Exit;
        Current := Tracks[CurrentIndex];
        if Current.FirstIndex < 0 then
          Current.FirstIndex := IndexSector;
        if Marker = 1 then
        begin
          Current.DataIndex := IndexSector;
          Current.Session := Session;
        end;
        Tracks[CurrentIndex] := Current;
      end
      else if SameText(Fields[0], 'REM') and (Length(Fields) >= 3) and SameText(Fields[1], 'SESSION') then
      begin
        if not TryStrToUInt(Fields[2], Session) or (Session = 0) then
          Exit;
      end;
    end;
    Result := True;
  end;

begin
  Tracks := TList<TRATrackLayout>.Create;
  try
    FIncompleteDescriptor := not ReadCueLines;
    Offset := 0;
    ValidCount := 0;
    Previous := Default(TRATrackLayout);
    SetLength(FTracks, Tracks.Count);
    for var Index := 0 to Tracks.Count - 1 do
    begin
      Current := Tracks[Index];
      if (Current.FirstIndex < 0) or (Current.DataIndex < Current.FirstIndex) then
      begin
        FIncompleteDescriptor := True;
        Break;
      end;
      if Current.FileIndex <> Previous.FileIndex then
      begin
        Offset := 0;
        // A repeated FILE still advances the disc timeline, but continues reading the same binary.
        if Current.FileName = Previous.FileName then
          Offset := (Current.FirstIndex - Previous.FirstIndex) * Previous.SectorSize;
      end
      else if Previous.SectorCount >= 0 then
        Inc(Offset, Previous.SectorCount * Previous.SectorSize)
      else
        Break;

      Current.FileOffset := Offset;
      Current.SectorCount := -1;
      if (Index < Tracks.Count - 1) and (Tracks[Index + 1].FileIndex = Current.FileIndex) and
        (Tracks[Index + 1].FirstIndex >= Current.FirstIndex) then
        Current.SectorCount := Tracks[Index + 1].FirstIndex - Current.FirstIndex;
      FTracks[ValidCount] := Current;
      Inc(ValidCount);
      Previous := Current;
    end;
    FIncompleteDescriptor := FIncompleteDescriptor or (ValidCount <> Tracks.Count);
    SetLength(FTracks, ValidCount);
    Result := ValidCount <> 0;
  finally
    Tracks.Free;
  end;
end;

function TRAFileDisc.ReadGDI(const Path: string; Lines: TStrings): Boolean;
var
  Fields: TArray<string>;
  Tracks: TList<TRATrackLayout>;
  Current: TRATrackLayout;
  Total, Kind, Stride: Integer;
begin
  Result := False;
  if (Lines.Count < 2) or not TryStrToInt(Trim(Lines[0]), Total) or (Total <= 0) then
    Exit;
  Tracks := TList<TRATrackLayout>.Create;
  try
    for var Index := 1 to Lines.Count - 1 do
    begin
      Fields := ReadFields(Lines[Index]);
      if (Length(Fields) = 0) and (Trim(Lines[Index]) = '') then
        Continue;
      Current := Default(TRATrackLayout);
      if (Tracks.Count >= Total) or (Length(Fields) < 5) or not TryStrToUInt(Fields[0], Current.Number) or
        (Current.Number <> Cardinal(Tracks.Count) + 1) or not TryStrToInt64(Fields[1], Current.FirstSector) or
        (Current.FirstSector < 0) or (Current.FirstSector > High(Cardinal)) or
        not TryStrToInt(Fields[2], Kind) or not TryStrToInt(Fields[3], Stride) or
        ((Stride <> 2048) and (Stride <> 2336) and (Stride <> 2352)) or
        (Fields[4] = '') or ((Length(Fields) > 5) and
        (not TryStrToInt64(Fields[5], Current.FileOffset) or (Current.FileOffset < 0))) then
      begin
        FIncompleteDescriptor := True;
        Break;
      end;

      case Stride of
        2048:
          SetCueMode('MODE1/2048', Current);
        2336:
          SetCueMode('MODE2/2336', Current);
        2352:
          if Kind = 4 then
            SetCueMode('MODE1/2352', Current)
          else
            SetCueMode('AUDIO', Current);
      end;
      Current.Data := Kind = 4;
      Current.FileName := TrackPath(Path, Fields[4]);
      Current.Session := 1;
      if Current.FirstSector >= 45000 then
        Current.Session := 2;
      Tracks.Add(Current);
    end;
    FIncompleteDescriptor := FIncompleteDescriptor or (Tracks.Count <> Total);
    FTracks := Tracks.ToArray;
    // The next byte offset in the same file ends this track, regardless of its LBA.
    for var Index := 0 to High(FTracks) do
    begin
      Current := FTracks[Index];
      for var Other in FTracks do
        if (Current.FileName = Other.FileName) and (Other.FileOffset > Current.FileOffset) and
          ((Current.FileEndOffset = 0) or (Other.FileOffset < Current.FileEndOffset)) then
          Current.FileEndOffset := Other.FileOffset;
      FTracks[Index] := Current;
    end;
    Result := Tracks.Count <> 0;
  finally
    Tracks.Free;
  end;
end;

constructor TRAFileDisc.Create(const Path: string; const OpenFile: TRAOpenArchive);
var
  Stream: TStream;
  Lines: TStringList;
begin
  inherited Create;
  FOpenFile := OpenFile;
  FGDI := SameText(ExtractFileExt(Path), '.gdi');
  Stream := OpenRAHashFile(Path, OpenFile);
  if Stream = nil then
    Exit;
  try
    Lines := TStringList.Create;
    try
      Lines.LoadFromStream(Stream, TEncoding.UTF8);
      if FGDI then
        ReadGDI(Path, Lines)
      else
        ReadCUE(Path, Lines);
    finally
      Lines.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function TRAFileDisc.CueSectorCount(const Track: TRATrackLayout): Int64;
begin
  Result := Track.SectorCount;
  if Result < 0 then
    // rcheevos derives the end of a FILE group from its final track's sector size and first index.
    Result := Max(FileSize(Track.FileName) div Track.SectorSize - Track.FirstIndex, 0);
end;

function TRAFileDisc.ResolveCueStart(Index: Integer; var Layout: TRATrackLayout): Boolean;
var
  First, FileEnd: Int64;
begin
  // Only preceding FILE groups contribute to the absolute sector of the requested track.
  First := Layout.FirstIndex;
  for var I := 0 to Index - 1 do
    if FTracks[I].FileIndex <> FTracks[I + 1].FileIndex then
    begin
      FileEnd := FTracks[I].FirstIndex + CueSectorCount(FTracks[I]);
      if FileEnd > High(Cardinal) - First then
        Exit(False);
      Inc(First, FileEnd);
    end;
  Layout.FirstSector := First;
  Result := First <= High(Cardinal);
end;

function TRAFileDisc.SelectTrack(Number: Cardinal): Integer;
var
  Size, Largest: Int64;
begin
  Result := -1;
  if FIncompleteDescriptor and ((Number = RALastTrack) or (Number = RALargestTrack) or (Number = 0)) then
    Exit;
  if Number = RALastTrack then
    Exit(High(FTracks));

  Largest := 0;
  for var Index := 0 to High(FTracks) do
  begin
    var Track := FTracks[Index];
    if (Track.Number = Number) or ((Number = RAFirstDataTrack) and Track.Data) or
      ((Number = RASecondSessionTrack) and (Track.Session = 2)) then
      Exit(Index);

    if ((Number <> RALargestTrack) and (Number <> 0)) or not Track.Data then
      Continue;
    if FGDI then
      Size := Track.LimitFileSize(FileSize(Track.FileName)) - Track.FileOffset
    else
      Size := CueSectorCount(Track);
    if (Size > Largest) or ((not FGDI) and (Size = Largest) and (Index = High(FTracks)) and (Size > 0)) then
    begin
      Largest := Size;
      Result := Index;
    end;
  end;
end;

function TRAFileDisc.OpenTrack(Number: Cardinal; out Track: TRADiscTrack): Boolean;
var
  Index: Integer;
  Stream: TStream;
  Reader: TRAReadTrack;
  Owner: IRAReadTrack;
  Layout: TRATrackLayout;
begin
  Track := Default(TRADiscTrack);
  Index := SelectTrack(Number);
  if Index < 0 then
    Exit(False);
  Layout := FTracks[Index];
  if not FGDI and not ResolveCueStart(Index, Layout) then
    Exit(False);
  Stream := OpenRAHashFile(Layout.FileName, FOpenFile);
  if Stream = nil then
    Exit(False);
  Reader := TRAReadTrack.Create(Stream, True, Layout);
  Owner := Reader;
  Result := Reader.Open(FGDI, False, Track);
end;

function CreateRADescriptorDiscReader(const Path: string; const OpenFile: TRAOpenArchive): TRAOpenDiscTrack;
var
  Disc: IRAFileDisc;
begin
  Disc := TRAFileDisc.Create(Path, OpenFile);
  Result :=
    function(Number: Cardinal; out Track: TRADiscTrack): Boolean
    begin
      Result := Disc.OpenTrack(Number, Track);
    end;
end;

end.

