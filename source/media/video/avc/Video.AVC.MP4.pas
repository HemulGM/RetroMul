unit Video.AVC.MP4;

interface

uses
  System.SysUtils, Video.AVC.Types;

type
  TMP4Track = class
  private
    type
      TBox = record
        Tag: Cardinal;
        Start, Limit: Integer;
      end;

      TSample = record
        Offset, Size: Integer;
        DecodeTime, CompositionOffset, Duration: Int64;
        Sync: Boolean;
      end;
  private
    FData: TBytes;
    FInfo: TTrackInfo;
    FKind: TTrackKind;
    FRequiredAudioCodec: string;
    FAMRFramesPerSample: Integer;
    FSamples: TArray<TSample>;
    FMediaData: TArray<TBox>;
    FEditMediaTime, FEditDelay, FEditDuration: Int64;
    function ReadBox(var Offset: Integer; Limit: Integer): TBox;
    function Child(const Parent: TBox; Tag: Cardinal; Required: Boolean = True): TBox;
    procedure Need(const Box: TBox; At, Size: Integer);
    function Read32(At: Integer): Cardinal;
    function Read64(At: Integer): UInt64;
    function TimeScale(const Header: TBox): Cardinal;
    function Entries(const Box: TBox; HeaderSize, EntrySize: Integer): Integer;
    function FindMediaData(Offset: UInt64): Integer;
    function ReadAACConfig(const Box: TBox): TBytes;
    function ReadDescriptions(const Box, Info: TBox): Boolean;
    procedure ReadTiming(const Table: TBox);
    procedure ReadChunks(const Table: TBox);
    procedure ReadSyncSamples(const Table: TBox);
    procedure ReadEdit(const Movie, Track: TBox);
    function TrackHandler(const Track: TBox): Cardinal;
    function ReadTrack(const Movie, Track: TBox): Boolean;
    constructor CreateInspection(const Data: TBytes);
    function GetPacketCount: Integer;
  public
    constructor Create(const Data: TBytes; Kind: TTrackKind = TTrackKind.Video; const RequiredAudioCodec: string = '');
    class function IsAudioOnly(const Data: TBytes): Boolean; static;
    function Packet(Index: Integer): TMediaPacket;
    function SeekPacket(Time: Int64): Integer;
    function PresentationTimes: TArray<Int64>;
    property Info: TTrackInfo read FInfo;
    property AMRFramesPerSample: Integer read FAMRFramesPerSample;
    property EditDelay: Int64 read FEditDelay;
    property PacketCount: Integer read GetPacketCount;
  end;

  TMP4AVCTrack = TMP4Track;

implementation

uses
  System.Math, System.Generics.Collections, Video.H263.Picture;

const
  MaxSamples = 1024 * 1024;
  MaxFileSize = 256 * 1024 * 1024;
  MaxDurationSeconds = 7 * 24 * 60 * 60;
  MaxMediaDataBoxes = 4096;
  // Big-endian box identifiers.
  Moov = $6D6F6F76;
  Mdat = $6D646174;
  Moof = $6D6F6F66;
  Trak = $7472616B;
  Tkhd = $746B6864;
  Mdia = $6D646961;
  Hdlr = $68646C72;
  Vide = $76696465;
  Soun = $736F756E;
  Mp4a = $6D703461;
  Samr = $73616D72;
  Sawb = $73617762;
  Damr = $64616D72;
  Esds = $65736473;
  Mdhd = $6D646864;
  Minf = $6D696E66;
  Stbl = $7374626C;
  Stsd = $73747364;
  Stsz = $7374737A;
  Stts = $73747473;
  Ctts = $63747473;
  Stsc = $73747363;
  Stco = $7374636F;
  Co64 = $636F3634;
  Stss = $73747373;
  Avc1 = $61766331;
  Avc3 = $61766333;
  AvcC = $61766343;
  S263 = $73323633;
  D263 = $64323633;
  Dinf = $64696E66;
  Dref = $64726566;
  LocalURL = $75726C20;
  Edts = $65647473;
  Elst = $656C7374;
  Mvhd = $6D766864;

function TMP4Track.Read32(At: Integer): Cardinal;
begin
  Result := (Cardinal(FData[At]) shl 24) or (Cardinal(FData[At + 1]) shl 16) or
    (Cardinal(FData[At + 2]) shl 8) or FData[At + 3];
end;

function TMP4Track.Read64(At: Integer): UInt64;
begin
  Result := (UInt64(Read32(At)) shl 32) or Read32(At + 4);
end;

function TMP4Track.ReadBox(var Offset: Integer; Limit: Integer): TBox;
begin
  if Limit - Offset < 8 then
    raise EPlayerFormat.Create('Truncated MP4 box header');
  var Size: UInt64 := Read32(Offset);
  var Header := 8;
  Result.Tag := Read32(Offset + 4);
  if Size = 1 then
  begin
    if Limit - Offset < 16 then
      raise EPlayerFormat.Create('Truncated MP4 extended box header');
    Size := Read64(Offset + 8);
    Header := 16;
  end
  else if Size = 0 then
    Size := Limit - Offset;
  if (Size < UInt64(Header)) or (Size > UInt64(Limit - Offset)) then
    raise EPlayerFormat.Create('MP4 box exceeds its parent');
  Result.Start := Offset + Header;
  Inc(Offset, Integer(Size));
  Result.Limit := Offset;
end;

function TMP4Track.Child(const Parent: TBox; Tag: Cardinal; Required: Boolean): TBox;
begin
  Result := Default(TBox);
  var Offset := Parent.Start;
  while Offset < Parent.Limit do
  begin
    var Box := ReadBox(Offset, Parent.Limit);
    if Box.Tag = Tag then
    begin
      if Result.Tag <> 0 then
        raise EPlayerFormat.Create('Duplicate MP4 box: ' + IntToHex(Tag, 8));
      Result := Box;
    end;
  end;
  if Required and (Result.Tag = 0) then
    raise EPlayerFormat.Create('Missing MP4 box: ' + IntToHex(Tag, 8));
end;

procedure TMP4Track.Need(const Box: TBox; At, Size: Integer);
begin
  if (At < Box.Start) or (At > Box.Limit - Size) then
    raise EPlayerFormat.Create('Truncated MP4 box payload: ' + IntToHex(Box.Tag, 8));
end;

function TMP4Track.TimeScale(const Header: TBox): Cardinal;
begin
  Need(Header, Header.Start, 1);
  var Pos := Header.Start + 12;
  case FData[Header.Start] of
    0:
      ;
    1:
      Inc(Pos, 8);
  else
    raise EPlayerUnsupported.Create('Unsupported MP4 media header version');
  end;
  Need(Header, Pos, 4);
  Result := Read32(Pos);
  if Result = 0 then
    raise EPlayerFormat.Create('Zero MP4 timescale');
end;

function TMP4Track.Entries(const Box: TBox; HeaderSize, EntrySize: Integer): Integer;
begin
  Need(Box, Box.Start, HeaderSize);
  var Count := Read32(Box.Start + HeaderSize - 4);
  if (Count > MaxSamples) or
    (UInt64(Count) * UInt64(EntrySize) > UInt64(Box.Limit - Box.Start - HeaderSize)) then
    raise EPlayerFormat.Create('Invalid MP4 table size: ' + IntToHex(Box.Tag, 8));
  Result := Integer(Count);
end;

function TMP4Track.FindMediaData(Offset: UInt64): Integer;
begin
  var First := 0;
  var Last := High(FMediaData);
  while First <= Last do
  begin
    var Mid := First + (Last - First) div 2;
    if Offset < UInt64(FMediaData[Mid].Start) then
      Last := Mid - 1
    else if Offset >= UInt64(FMediaData[Mid].Limit) then
      First := Mid + 1
    else
      Exit(Mid);
  end;
  raise EPlayerFormat.Create('MP4 chunk points outside mdat');
end;

function TMP4Track.ReadAACConfig(const Box: TBox): TBytes;

  function Descriptor(var Pos: Integer; Limit: Integer; Tag: Byte): Integer;
  begin
    if (Pos >= Limit) or (FData[Pos] <> Tag) then
      raise EPlayerFormat.Create('Missing MP4 audio descriptor');
    Inc(Pos);
    var Size := 0;
    for var I := 1 to 4 do
    begin
      if Pos >= Limit then
        Break;
      var Part := FData[Pos];
      Inc(Pos);
      Size := (Size shl 7) or (Part and $7F);
      if (Part and $80) = 0 then
      begin
        if Size > Limit - Pos then
          Break;
        Exit(Pos + Size);
      end;
    end;
    raise EPlayerFormat.Create('Invalid MP4 audio descriptor length');
  end;

begin
  Need(Box, Box.Start, 4);
  if Read32(Box.Start) <> 0 then
    raise EPlayerUnsupported.Create('Unsupported MP4 audio descriptor version');
  var Pos := Box.Start + 4;
  var ESLimit := Descriptor(Pos, Box.Limit, 3);
  if ESLimit - Pos < 3 then
    raise EPlayerFormat.Create('Truncated MP4 elementary stream descriptor');
  var Flags := FData[Pos + 2];
  Inc(Pos, 3);
  if (Flags and $40) <> 0 then
    raise EPlayerUnsupported.Create('External MP4 elementary stream');
  if (Flags and $80) <> 0 then
    Inc(Pos, 2);
  if (Flags and $20) <> 0 then
    Inc(Pos, 2);
  var DecoderLimit := Descriptor(Pos, ESLimit, 4);
  if DecoderLimit - Pos < 13 then
    raise EPlayerFormat.Create('Truncated MP4 audio decoder descriptor');
  if (FData[Pos] <> $40) or (FData[Pos + 1] shr 2 <> 5) then
    raise EPlayerUnsupported.Create('Unsupported MP4 audio object type');
  Inc(Pos, 13);
  var ConfigLimit := Descriptor(Pos, DecoderLimit, 5);
  var Size := ConfigLimit - Pos;
  if (Size < 2) or (Size > 65536) then
    raise EPlayerFormat.Create('Invalid MP4 audio configuration size');
  Result := Copy(FData, Pos, Size);
end;

function TMP4Track.ReadDescriptions(const Box, Info: TBox): Boolean;
begin
  Need(Box, Box.Start, 8);
  var Count := Read32(Box.Start + 4);
  if Count = 0 then
    raise EPlayerFormat.Create('Empty MP4 sample description');
  var Offset := Box.Start + 8;
  var Desc := ReadBox(Offset, Box.Limit);
  var AudioCodec := '';
  if FKind = TTrackKind.Audio then
  begin
    case Desc.Tag of
      Mp4a:
        AudioCodec := 'mp4a';
      Samr:
        AudioCodec := 'samr';
      Sawb:
        AudioCodec := 'sawb';
    end;
    Result := (AudioCodec <> '') and
      ((FRequiredAudioCodec = '') or (AudioCodec = FRequiredAudioCodec));
  end
  else
    Result := (Desc.Tag = Avc1) or (Desc.Tag = Avc3) or (Desc.Tag = S263);
  if not Result then
    Exit;
  if (Count <> 1) or (Read32(Box.Start) <> 0) then
    raise EPlayerUnsupported.Create('Unsupported MP4 sample description table');
  Need(Desc, Desc.Start, 8);
  if (FData[Desc.Start + 6] <> 0) or (FData[Desc.Start + 7] <> 1) then
    raise EPlayerUnsupported.Create('Unsupported MP4 data reference index');

  var Ref := Child(Child(Info, Dinf), Dref);
  Need(Ref, Ref.Start, 8);
  if Read32(Ref.Start + 4) = 0 then
    raise EPlayerFormat.Create('Empty MP4 data reference');
  Offset := Ref.Start + 8;
  var Location := ReadBox(Offset, Ref.Limit);
  Need(Location, Location.Start, 4);
  if (Location.Tag <> LocalURL) or ((Read32(Location.Start) and 1) = 0) then
    raise EPlayerUnsupported.Create('External MP4 media data');

  if FKind = TTrackKind.Audio then
  begin
    Need(Desc, Desc.Start, 28);
    if (FData[Desc.Start + 8] <> 0) or (FData[Desc.Start + 9] <> 0) then
      raise EPlayerUnsupported.Create('Unsupported MP4 audio sample entry version');
    Inc(Desc.Start, 28);
    FInfo.Codec := AudioCodec;
    case Desc.Tag of
      Mp4a:
        FInfo.CodecConfig := ReadAACConfig(Child(Desc, Esds));
      Samr, Sawb:
        begin
          var Config := Child(Desc, Damr);
          if Config.Limit - Config.Start <> 9 then
            raise EPlayerFormat.Create('Invalid 3GP AMR decoder configuration');
          FAMRFramesPerSample := FData[Config.Start + 8];
          if (FAMRFramesPerSample < 1) or (FAMRFramesPerSample > 15) then
            raise EPlayerFormat.Create('Invalid 3GP AMR frames per sample');
          FInfo.Channels := 1;
          if Desc.Tag = Samr then
            FInfo.SampleRate := 8000
          else
            FInfo.SampleRate := 16000;
        end;
    end;
    Exit;
  end;

  Need(Desc, Desc.Start, 78);
  FInfo.Width := (Integer(FData[Desc.Start + 24]) shl 8) or FData[Desc.Start + 25];
  FInfo.Height := (Integer(FData[Desc.Start + 26]) shl 8) or FData[Desc.Start + 27];
  if (FInfo.Width = 0) or (FInfo.Height = 0) then
    raise EPlayerFormat.Create('Zero MP4 video dimensions');
  Inc(Desc.Start, 78);
  if Desc.Tag = S263 then
  begin
    var H263Config := Child(Desc, D263);
    var Payload := H263Config.Limit - H263Config.Start;
    if (Payload < 7) or (Payload > 65536) then
      raise EPlayerFormat.Create('Invalid 3GP H.263 decoder configuration size');
    FInfo.Codec := 's263';
    FInfo.CodecConfig := Copy(FData, H263Config.Start, Payload);
    Exit;
  end;
  var Config := Child(Desc, AvcC);
  var Bytes := Config.Limit - Config.Start;
  if (Bytes < 7) or (Bytes > 65536) then
    raise EPlayerFormat.Create('Invalid MP4 AVC configuration size');
  FInfo.CodecConfig := Copy(FData, Config.Start, Bytes);
  FInfo.Codec := 'avc1';
  if Desc.Tag = Avc3 then
    FInfo.Codec := 'avc3';
end;

procedure TMP4Track.ReadTiming(const Table: TBox);
begin
  var Timing := Child(Table, Stts);
  var Count := Entries(Timing, 8, 8);
  if Read32(Timing.Start) <> 0 then
    raise EPlayerUnsupported.Create('Unsupported MP4 decoding time table version');
  var Index := 0;
  var DTS: Int64 := 0;
  var Pos := Timing.Start + 8;
  for var Run := 0 to Count - 1 do
  begin
    var Samples := Read32(Pos);
    var Delta := Read32(Pos + 4);
    Inc(Pos, 8);
    if (Samples = 0) or (Samples > Cardinal(Length(FSamples) - Index)) then
      raise EPlayerFormat.Create('MP4 stts sample count mismatch');
    for var I := 1 to Integer(Samples) do
    begin
      FSamples[Index].DecodeTime := DTS;
      FSamples[Index].Duration := Delta;
      Inc(DTS, Int64(Delta));
      Inc(Index);
    end;
  end;
  if Index <> Length(FSamples) then
    raise EPlayerFormat.Create('Incomplete MP4 decoding time table');
  if DTS > Int64(FInfo.TimeScale) * MaxDurationSeconds then
    raise EPlayerUnsupported.Create('MP4 track duration limit');

  var Composition := Child(Table, Ctts, False);
  if Composition.Tag <> 0 then
  begin
    Count := Entries(Composition, 8, 8);
    var Version := FData[Composition.Start];
    if Version > 1 then
      raise EPlayerUnsupported.Create('Unsupported MP4 composition time table version');
    Index := 0;
    Pos := Composition.Start + 8;
    for var Run := 0 to Count - 1 do
    begin
      var Samples := Read32(Pos);
      var Delta: Int64 := Read32(Pos + 4);
      if Version = 1 then
        Delta := Int32(Delta);
      Inc(Pos, 8);
      if (Samples = 0) or (Samples > Cardinal(Length(FSamples) - Index)) then
        raise EPlayerFormat.Create('MP4 ctts sample count mismatch');
      for var I := 1 to Integer(Samples) do
      begin
        FSamples[Index].CompositionOffset := Delta;
        Inc(Index);
      end;
    end;
    if Index <> Length(FSamples) then
      raise EPlayerFormat.Create('Incomplete MP4 composition time table');
  end;
end;

procedure TMP4Track.ReadChunks(const Table: TBox);
begin
  var Offsets := Child(Table, Stco, False);
  var Offsets64 := Child(Table, Co64, False);
  if (Offsets.Tag = 0) = (Offsets64.Tag = 0) then
    raise EPlayerFormat.Create('MP4 track must specify one chunk offset table');
  var Width := 4;
  if Offsets64.Tag <> 0 then
  begin
    Width := 8;
    Offsets := Offsets64;
  end;
  var Chunks := Entries(Offsets, 8, Width);
  var Mapping := Child(Table, Stsc);
  var Runs := Entries(Mapping, 8, 12);
  if (Read32(Offsets.Start) <> 0) or (Read32(Mapping.Start) <> 0) then
    raise EPlayerUnsupported.Create('Unsupported MP4 chunk table version');
  if (Chunks = 0) or (Runs = 0) or (Read32(Mapping.Start + 8) <> 1) then
    raise EPlayerFormat.Create('Invalid MP4 sample-to-chunk table');

  var MapPos := Mapping.Start + 8;
  var Chunk := 1;
  var Index := 0;
  for var Run := 0 to Runs - 1 do
  begin
    var PerChunk := Read32(MapPos + 4);
    if Read32(MapPos + 8) <> 1 then
      raise EPlayerUnsupported.Create('MP4 sample description changes within the track');
    Inc(MapPos, 12);
    var NextChunk := Cardinal(Chunks + 1);
    if Run < Runs - 1 then
      NextChunk := Read32(MapPos);
    if (NextChunk <= Cardinal(Chunk)) or (NextChunk > Cardinal(Chunks + 1)) or (PerChunk = 0) then
      raise EPlayerFormat.Create('Invalid MP4 chunk mapping');
    while Chunk < Integer(NextChunk) do
    begin
      var Pos := Offsets.Start + 8 + (Chunk - 1) * Width;
      var Offset: UInt64;
      if Width = 8 then
        Offset := Read64(Pos)
      else
        Offset := Read32(Pos);
      var DataBox := FindMediaData(Offset);
      if PerChunk > Cardinal(Length(FSamples) - Index) then
        raise EPlayerFormat.Create('MP4 chunk exceeds sample count');
      for var I := 1 to Integer(PerChunk) do
      begin
        if Offset + UInt64(FSamples[Index].Size) > UInt64(FMediaData[DataBox].Limit) then
          raise EPlayerFormat.Create('MP4 sample exceeds mdat');
        FSamples[Index].Offset := Integer(Offset);
        Inc(Offset, UInt64(FSamples[Index].Size));
        Inc(Index);
      end;
      Inc(Chunk);
    end;
  end;
  if Index <> Length(FSamples) then
    raise EPlayerFormat.Create('Incomplete MP4 sample-to-chunk table');
end;

procedure TMP4Track.ReadSyncSamples(const Table: TBox);
begin
  var Sync := Child(Table, Stss, False);
  if Sync.Tag = 0 then
  begin
    for var I := 0 to High(FSamples) do
      FSamples[I].Sync := True;
    Exit;
  end;
  var Count := Entries(Sync, 8, 4);
  if Read32(Sync.Start) <> 0 then
    raise EPlayerUnsupported.Create('Unsupported MP4 sync sample table version');
  var Previous: Cardinal := 0;
  for var I := 0 to Count - 1 do
  begin
    var Number := Read32(Sync.Start + 8 + I * 4);
    if (Number <= Previous) or (Number > Cardinal(Length(FSamples))) then
      raise EPlayerFormat.Create('Invalid MP4 sync sample number');
    FSamples[Number - 1].Sync := True;
    Previous := Number;
  end;
end;

procedure TMP4Track.ReadEdit(const Movie, Track: TBox);
begin
  var Edit := Child(Track, Edts, False);
  if Edit.Tag = 0 then
    Exit;
  Edit := Child(Edit, Elst);
  Need(Edit, Edit.Start, 8);
  var Version := FData[Edit.Start];
  if Version > 1 then
    raise EPlayerUnsupported.Create('Unsupported MP4 edit list version');
  var FieldSize := 4 + 4 * Integer(Version);
  var Count := Entries(Edit, 8, FieldSize * 2 + 4);
  if (Count = 0) or (Count > 2) then
    raise EPlayerUnsupported.Create('Unsupported MP4 edit list');
  var Scale := TimeScale(Child(Movie, Mvhd));
  var Offset := Edit.Start + 8;
  for var I := 0 to Count - 1 do
  begin
    var Segment: UInt64;
    var MediaTime: Int64;
    if Version = 0 then
    begin
      Segment := Read32(Offset);
      MediaTime := Int32(Read32(Offset + 4));
    end
    else
    begin
      Segment := Read64(Offset);
      MediaTime := Int64(Read64(Offset + 8));
    end;
    if (Segment > UInt64(Scale) * MaxDurationSeconds) or (Read32(Offset + 2 * FieldSize) <> $00010000) then
      raise EPlayerUnsupported.Create('Unsupported MP4 edit duration or playback rate');
    var SegmentTime := RescaleTime(Int64(Segment), Scale, PlayerTimeBase);
    if (I = 0) and (Count = 2) and (MediaTime = -1) then
      FEditDelay := SegmentTime
    else if (I = Count - 1) and (MediaTime >= 0) and (MediaTime <= FSamples[High(FSamples)].DecodeTime + High(Cardinal)) then
    begin
      FEditMediaTime := MediaTime;
      FEditDuration := FEditDelay + SegmentTime;
    end
    else
      raise EPlayerUnsupported.Create('Unsupported MP4 media edit');
    Inc(Offset, FieldSize * 2 + 4);
  end;
end;

function TMP4Track.TrackHandler(const Track: TBox): Cardinal;
begin
  var Handler := Child(Child(Track, Mdia), Hdlr);
  Need(Handler, Handler.Start, 12);
  Result := Read32(Handler.Start + 8);
end;

constructor TMP4Track.CreateInspection(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
end;

class function TMP4Track.IsAudioOnly(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) > MaxFileSize then
    Exit;
  var Reader := TMP4Track.CreateInspection(Data);
  try
    try
      var Offset := 0;
      while Offset < Length(Data) do
      begin
        var Movie := Reader.ReadBox(Offset, Length(Data));
        if Movie.Tag <> Moov then
          Continue;
        var TrackOffset := Movie.Start;
        var Audio := False;
        while TrackOffset < Movie.Limit do
        begin
          var Track := Reader.ReadBox(TrackOffset, Movie.Limit);
          if Track.Tag <> Trak then
            Continue;
          case Reader.TrackHandler(Track) of
            Vide, $74657874, $7362746C, $73756274: // video and timed text handlers
              Exit;
            Soun:
              Audio := True;
          end;
        end;
        Exit(Audio);
      end;
    except
      on E: EPlayerError do
        Exit(False);
    end;
  finally
    Reader.Free;
  end;
end;

function TMP4Track.ReadTrack(const Movie, Track: TBox): Boolean;
begin
  var HandlerType := TrackHandler(Track);
  if ((FKind = TTrackKind.Video) and (HandlerType <> Vide)) or
    ((FKind = TTrackKind.Audio) and (HandlerType <> Soun)) then
    Exit(False);
  var Media := Child(Track, Mdia);
  var Info := Child(Media, Minf);
  var Table := Child(Info, Stbl);
  if not ReadDescriptions(Child(Table, Stsd), Info) then
    Exit(False);
  FInfo.Kind := FKind;
  FInfo.TimeScale := TimeScale(Child(Media, Mdhd));
  var Header := Child(Track, Tkhd);
  Need(Header, Header.Start, 1);
  var IDOffset := Header.Start + 12;
  case FData[Header.Start] of
    0:
      ;
    1:
      Inc(IDOffset, 8);
  else
    raise EPlayerUnsupported.Create('Unsupported MP4 track header version');
  end;
  Need(Header, IDOffset, 4);
  FInfo.ID := Read32(IDOffset);
  var Sizes := Child(Table, Stsz);
  Need(Sizes, Sizes.Start, 12);
  if Read32(Sizes.Start) <> 0 then
    raise EPlayerUnsupported.Create('Unsupported MP4 sample size table version');
  var SampleSize := Read32(Sizes.Start + 4);
  var SampleCount := Entries(Sizes, 12, 4 * Ord(SampleSize = 0));
  if SampleCount = 0 then
    raise EPlayerFormat.Create('Empty MP4 track');
  SetLength(FSamples, SampleCount);
  for var I := 0 to High(FSamples) do
  begin
    var Size := SampleSize;
    if Size = 0 then
      Size := Read32(Sizes.Start + 12 + I * 4);
    if (Size = 0) or (Size > Cardinal(Length(FData))) then
      raise EPlayerFormat.Create('Invalid MP4 packet size');
    FSamples[I].Size := Integer(Size);
  end;
  if (FKind = TTrackKind.Audio) and (Child(Table, Ctts, False).Tag <> 0) then
    raise EPlayerUnsupported.Create('MP4 audio composition offsets');
  ReadTiming(Table);
  ReadChunks(Table);
  ReadSyncSamples(Table);
  if FInfo.Codec = 's263' then
    // Some remuxers describe every H.263 packet as independently decodable.
    // Derive random-access points from the actual picture types.
    for var I := 0 to High(FSamples) do
      FSamples[I].Sync := H263IndependentPicture(FData, FSamples[I].Offset, FSamples[I].Size);
  ReadEdit(Movie, Track);

  var First := High(Int64);
  var Last := Low(Int64);
  for var Sample in FSamples do
  begin
    var PTS := Sample.DecodeTime + Sample.CompositionOffset - FEditMediaTime;
    First := Min(First, PTS);
    Last := Max(Last, PTS + Sample.Duration);
  end;
  FInfo.StartTime := Max(FEditDelay, RescaleTime(First, FInfo.TimeScale, PlayerTimeBase) + FEditDelay);
  FInfo.Duration := RescaleTime(Last, FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
  if (FKind = TTrackKind.Video) and (FInfo.Duration <= FInfo.StartTime) then
    raise EPlayerFormat.Create('MP4 edit has no visible video frames');
  if FEditDuration <> 0 then
    FInfo.Duration := FEditDuration;
  Result := True;
end;

constructor TMP4Track.Create(const Data: TBytes; Kind: TTrackKind; const RequiredAudioCodec: string);
begin
  inherited Create;
  if not (Kind in [TTrackKind.Video, TTrackKind.Audio]) then
    raise EArgumentException.Create('MP4 track kind');
  FKind := Kind;
  FRequiredAudioCodec := RequiredAudioCodec;
  if Length(Data) > MaxFileSize then
    raise EPlayerUnsupported.Create('MP4 file size limit');
  FData := Data;
  var Movie := Default(TBox);
  var Ranges := TList<TBox>.Create;
  try
    var Offset := 0;
    while Offset < Length(FData) do
    begin
      var Box := ReadBox(Offset, Length(FData));
      case Box.Tag of
        Moov:
          begin
            if Movie.Tag <> 0 then
              raise EPlayerFormat.Create('Duplicate MP4 movie box');
            Movie := Box;
          end;
        Mdat:
          begin
            if Ranges.Count >= MaxMediaDataBoxes then
              raise EPlayerUnsupported.Create('Too many MP4 media data boxes');
            Ranges.Add(Box);
          end;
        Moof:
          raise EPlayerUnsupported.Create('Fragmented MP4 is unsupported');
      end;
    end;
    FMediaData := Ranges.ToArray;
  finally
    Ranges.Free;
  end;
  if (Movie.Tag = 0) or (Length(FMediaData) = 0) then
    raise EPlayerFormat.Create('Missing MP4 movie or media data');
  var Offset := Movie.Start;
  while Offset < Movie.Limit do
  begin
    var Track := ReadBox(Offset, Movie.Limit);
    if (Track.Tag = Trak) and ReadTrack(Movie, Track) then
      Exit;
  end;
  if FKind = TTrackKind.Audio then
    raise EPlayerUnsupported.Create('No MPEG-4 audio track in MP4');
  raise EPlayerUnsupported.Create('No supported video track in MP4/3GP');
end;

function TMP4Track.GetPacketCount: Integer;
begin
  Result := Length(FSamples);
end;

function TMP4Track.SeekPacket(Time: Int64): Integer;
begin
  Result := 0;
  if FKind = TTrackKind.Audio then
  begin
    var Last := High(FSamples);
    while Result < Last do
    begin
      var Mid := (Result + Last + 1) div 2;
      var PTS := RescaleTime(FSamples[Mid].DecodeTime - FEditMediaTime, FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
      if PTS <= Time then
        Result := Mid
      else
        Last := Mid - 1;
    end;
    Exit;
  end;
  var Latest := Low(Int64);
  for var I := 0 to High(FSamples) do
    if FSamples[I].Sync then
    begin
      var PTS := FSamples[I].DecodeTime + FSamples[I].CompositionOffset - FEditMediaTime;
      PTS := RescaleTime(PTS, FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
      if (PTS <= Time) and (PTS >= Latest) then
      begin
        Latest := PTS;
        Result := I;
      end;
    end;
end;

function TMP4Track.PresentationTimes: TArray<Int64>;
begin
  if (Length(FSamples) = 0) or (FInfo.Duration <= FInfo.StartTime) then
    Exit(nil);
  SetLength(Result, Length(FSamples));
  for var I := 0 to High(FSamples) do
  begin
    var S := FSamples[I];
    Result[I] := RescaleTime(S.DecodeTime + S.CompositionOffset - FEditMediaTime,
        FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
  end;
  TArray.Sort<Int64>(Result);
  // Keep the picture already on screen when an edit starts within a frame.
  // Earlier samples may still be needed as decoder preroll.
  var First := 0;
  while (First < Length(Result)) and (Result[First] < FInfo.StartTime) do
    Inc(First);
  if (First > 0) and ((First = Length(Result)) or (Result[First] > FInfo.StartTime)) then
    Dec(First);
  var Last := Length(Result);
  while (Last > First) and (Result[Last - 1] >= FInfo.Duration) do
    Dec(Last);
  if (First = 0) and (Last = Length(Result)) and (Result[0] >= FInfo.StartTime) then
    Exit;
  if (Last > First) and (Result[First] < FInfo.StartTime) and (FInfo.StartTime < FInfo.Duration) then
    Result[First] := FInfo.StartTime;
  Result := Copy(Result, First, Last - First);
end;

function TMP4Track.Packet(Index: Integer): TMediaPacket;
begin
  if (Index < 0) or (Index >= Length(FSamples)) then
    raise EArgumentOutOfRangeException.Create('MP4 packet index');
  var S := FSamples[Index];
  Result := Default(TMediaPacket);
  Result.Data := Copy(FData, S.Offset, S.Size);
  Result.SourceTimeScale := FInfo.TimeScale;
  Result.SourcePTS := S.DecodeTime + S.CompositionOffset - FEditMediaTime;
  Result.PTS := RescaleTime(Result.SourcePTS, FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
  Result.DTS := RescaleTime(S.DecodeTime - FEditMediaTime, FInfo.TimeScale, PlayerTimeBase) + FEditDelay;
  Result.Duration := RescaleTime(Result.SourcePTS + S.Duration, FInfo.TimeScale, PlayerTimeBase) +
    FEditDelay - Result.PTS;
  Result.KeyFrame := S.Sync;
end;

end.

