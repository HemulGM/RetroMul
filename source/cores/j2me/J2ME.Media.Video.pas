unit J2ME.Media.Video;

interface

uses
  System.SysUtils, System.Types, Audio.Types, Video.AVC.MP4, Video.AVC.Types;

const
  MP4AudioContentType = 'audio/mp4';
  ThreeGPAudioContentType = 'audio/3gpp';
  J2MEVideoClockRate = 1000000;
  J2MEVideoSnapshotEncodings = 'encoding=jpeg encoding=png';
  J2MEVideoMaxDuration = 7 * Int64(86400000000);

type
  IJ2MEVideoSpeech = interface
    ['{CFE00D9F-65C3-4B61-99BE-18A392D77CB0}']
    procedure SelectTrack(Index: Integer);
    function NextPacket(out Frame: Audio.Types.TAudioFrame): Boolean;
  end;

  TJ2MEVideoStream = class
  private
    FTrack, FAudio: TMP4Track;
    FAudioDecoder: Audio.Types.IAudioDecoder;
    FSpeech: IJ2MEVideoSpeech;
    FSpeechCache: TArray<Audio.Types.TAudioFrame>;
    FSpeechFirst, FSpeechCount, FSpeechCachedBytes: Integer;
    FSpeechAtEnd: Boolean;
    FAudioStart, FAudioEnd: Int64;
    FAudioFrame: Audio.Types.TAudioFrame;
    FAudioRate, FAudioPacket: Integer;
    FNextAudioPosition: Int64;
    FAudioDelay: Int64;
    FDecoder: IVideoDecoder;
    FFrame, FNext: TVideoFrame;
    FFrameTimes: TArray<Int64>;
    FPacket: Integer;
    FLastTime: Int64;
    FFlushed: Boolean;
    procedure OpenAudio(const Data: TBytes);
    procedure OpenSpeechAudio(const Data: TBytes);
    function DecodeAudio: Boolean;
    procedure CacheSpeechFrame(const Frame: Audio.Types.TAudioFrame);
    function FindSpeechFrame(Sample: Int64; const Cancelled: TFunc<Boolean>): Boolean;
    function GetHasAudio: Boolean;
    function GetDuration: Int64;
    function GetFrameCount: Integer;
    function GetInfo: TTrackInfo;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Reset;
    procedure MixAudio(Position: Int64; Offset, Frames, Level: Integer; var Mix: TArray<Int64>; const Cancelled: TFunc<Boolean> = nil);
    function Advance(Time: Int64): Boolean;
    function FrameToTime(Index: Integer): Int64;
    function TimeToFrame(Time: Int64): Integer;
    function SnapshotReady(Time: Int64): Boolean;
    function EncodeSnapshot(const Format: string; Width, Height, Quality, Transform: Integer): TBytes;
    procedure Draw(var Pixels: TArray<UInt32>; Stride, X, Y, W, H, Transform: Integer; const Clip: TRect);
    property Info: TTrackInfo read GetInfo;
    property HasAudio: Boolean read GetHasAudio;
    property Duration: Int64 read GetDuration;
    property FrameCount: Integer read GetFrameCount;
  end;

function J2MEVideoContentType(const Name: string): Boolean;

function J2MEContainerAudioType(const Name: string): Boolean;

function OpenJ2MEContainerAudio(const Data: TBytes): IAudioSource;

function DetectJ2MEVideoType(const Data: TBytes): string;

implementation

uses
  System.Classes, System.Math, Media.Types, Audio.Decoder, Audio.AAC,
  Audio.Format.AMR, Video.AVC.H264, Video.H263.Decoder, J2ME.Image,
  Media.Image.PNG, Media.Image.JPEG;

const
  MixRate = 44100;
  ClockScale = Int64(J2MEVideoClockRate) * MixRate;
  SpeechCachePackets = 2048;
  SpeechCacheBytes = 1024 * 1024;

type
  TJ2MEContainerAudioSource = class(TAudioMusicSource, IJ2MEVideoSpeech)
  private
    FTrack: TMP4Track;
    FDecoder: Audio.Types.IAudioDecoder;
    FSpeech: IAudioSource;
    FSpeechFramesPerPacket: TArray<Byte>;
    FSpeechBuffer: TArray<SmallInt>;
    FFrame: Audio.Types.TAudioFrame;
    FRate, FChannels, FPacket: Integer;
    FPosition, FStart, FEnd, FDelay: Int64;
    procedure OpenSpeech;
    procedure DecodeFrame;
  public
    constructor Create(const Data: TBytes; const RequiredCodec: string = '');
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function NextPacket(out Frame: Audio.Types.TAudioFrame): Boolean;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

function ConfigureAAC(const Track: TMP4Track; out Rate, Channels: Integer): Audio.Types.IAudioDecoder;
begin
  var Info := Default(Media.Types.TTrackInfo);
  Info.Kind := Media.Types.TTrackKind.Audio;
  Info.Codec := Track.Info.Codec;
  Info.TimeScale := Track.Info.TimeScale;
  Info.CodecConfig := Track.Info.CodecConfig;
  var AAC := TAACDecoder.Create;
  Result := AAC;
  Result.Configure(Info);
  Rate := AAC.OutputRate;
  Channels := AAC.OutputChannels;
end;

procedure DecodeAACPacket(const Track: TMP4Track; const Decoder: Audio.Types.IAudioDecoder; Index, Rate: Integer; Delay: Int64; out Frame: Audio.Types.TAudioFrame);
begin
  var Source := Track.Packet(Index);
  var Packet := Default(Media.Types.TMediaPacket);
  Packet.Data := Source.Data;
  Packet.DTS := Source.DTS;
  Packet.PTS := Source.PTS;
  Packet.SourcePTS := Source.SourcePTS;
  Packet.SourceTimeScale := Source.SourceTimeScale;
  Packet.Duration := Source.Duration;
  Decoder.Send(Packet);
  if not Decoder.Receive(Frame) then
    raise EPlayerFormat.Create('Empty MP4 AAC access unit');
  if Frame.SampleRate <> Rate then
    raise EPlayerUnsupported.Create('MP4 AAC profile changes the sample rate');
  Inc(Frame.SamplePosition, Delay);
end;

constructor TJ2MEContainerAudioSource.Create(const Data: TBytes; const RequiredCodec: string);
begin
  inherited Create;
  FTrack := TMP4Track.Create(Data, Video.AVC.Types.TTrackKind.Audio, RequiredCodec);
  if FTrack.Info.Codec = 'mp4a' then
    FDecoder := ConfigureAAC(FTrack, FRate, FChannels)
  else
    OpenSpeech;
  if (FRate <= 0) or not (FChannels in [1, 2]) then
    raise EPlayerUnsupported.Create('Unsupported MP4 audio output format');
  var StartTime := FTrack.Info.StartTime;
  var EndTime := FTrack.Info.Duration;
  if (StartTime < 0) or (EndTime <= StartTime) or (EndTime > 86400 * Int64(J2MEVideoClockRate)) then
    raise EPlayerUnsupported.Create('Unsupported MP4 audio duration');
  // The demuxer transports timestamps in whole microseconds. Round back to
  // the nearest sample to avoid truncating an already truncated boundary.
  FStart := (StartTime * FRate + J2MEVideoClockRate div 2) div J2MEVideoClockRate;
  FEnd := (EndTime * FRate + J2MEVideoClockRate div 2) div J2MEVideoClockRate;
  FDelay := (FTrack.EditDelay * FRate + J2MEVideoClockRate div 2) div J2MEVideoClockRate;
  if FEnd <= FStart then
    raise EPlayerFormat.Create('Empty MP4 audio timeline');
end;

destructor TJ2MEContainerAudioSource.Destroy;
begin
  FTrack.Free;
  inherited;
end;

procedure TJ2MEContainerAudioSource.OpenSpeech;
const
  MaxSpeechBytes = 16 * 1024 * 1024;
begin
  var Kind := TAMRKind.Narrowband;
  var Header: AnsiString := '#!AMR'#10;
  if FTrack.Info.Codec = 'sawb' then
  begin
    Kind := TAMRKind.Wideband;
    Header := '#!AMR-WB'#10;
  end;
  FRate := FTrack.Info.SampleRate;
  FChannels := 1;
  SetLength(FSpeechFramesPerPacket, FTrack.PacketCount);
  // 3GPP TS 26.244 stores standard AMR frames without the file magic.
  // Keep the AMR frames in one stream to preserve decoder history.
  var Encoded := TBytesStream.Create;
  try
    Encoded.WriteBuffer(Header[1], Length(Header));
    for var Index := 0 to FTrack.PacketCount - 1 do
    begin
      var Packet := FTrack.Packet(Index);
      if Length(Packet.Data) > 61 * FTrack.AMRFramesPerSample then
        raise EPlayerFormat.Create('Oversized 3GP AMR sample');
      var Offset := 0;
      var Count := 0;
      while Offset < Length(Packet.Data) do
      begin
        var HeaderByte := Packet.Data[Offset];
        var Size := AMRFrameSize(HeaderByte, Kind);
        if ((HeaderByte and $83) <> 0) or (Size = 0) or (Size > Length(Packet.Data) - Offset) then
          raise EPlayerFormat.Create('Invalid 3GP AMR frame');
        Inc(Offset, Size);
        Inc(Count);
      end;
      // The final sample may be short, but the other samples must be full.
      if (Count = 0) or (Count > FTrack.AMRFramesPerSample) or
        ((Index < FTrack.PacketCount - 1) and (Count <> FTrack.AMRFramesPerSample)) then
        raise EPlayerFormat.Create('3GP AMR frame count differs from damr');
      if Encoded.Size + Length(Packet.Data) > MaxSpeechBytes then
        raise EPlayerUnsupported.Create('3GP AMR data limit');
      FSpeechFramesPerPacket[Index] := Byte(Count);
      Encoded.WriteBuffer(Packet.Data[0], Length(Packet.Data));
    end;
    FSpeech := OpenAMR(Copy(Encoded.Bytes, 0, Encoded.Size));
  finally
    Encoded.Free;
  end;
  SetLength(FSpeechBuffer, 4096);
end;

procedure TJ2MEContainerAudioSource.DecodeFrame;
begin
  if FDecoder <> nil then
    DecodeAACPacket(FTrack, FDecoder, FPacket, FRate, FDelay, FFrame)
  else
  begin
    var Packet := FTrack.Packet(FPacket);
    FFrame.SamplePosition := Media.Types.RescaleTime(Packet.SourcePTS, Packet.SourceTimeScale, FRate) + FDelay;
    FFrame.Frames := FSpeechFramesPerPacket[FPacket] * (FRate div 50);
    FFrame.Channels := FChannels;
    SetLength(FFrame.Samples, FFrame.Frames);
    var Offset := 0;
    while Offset < FFrame.Frames do
    begin
      var Wanted := Min(Length(FSpeechBuffer), FFrame.Frames - Offset);
      var Read := FSpeech.Render(FSpeechBuffer, Wanted);
      if (Read <= 0) or (Read > Wanted) then
        raise EPlayerFormat.Create('Truncated decoded 3GP AMR sample');
      Move(FSpeechBuffer[0], FFrame.Samples[Offset], Read * SizeOf(SmallInt));
      Inc(Offset, Read);
    end;
  end;
  Inc(FPacket);
  if FFrame.Channels <> FChannels then
    raise EPlayerUnsupported.Create('MP4 AAC profile changes the channel count');
end;

function TJ2MEContainerAudioSource.NextPacket(out Frame: Audio.Types.TAudioFrame): Boolean;
begin
  Result := FPacket < FTrack.PacketCount;
  if Result then
  begin
    DecodeFrame;
    Frame := FFrame;
  end;
end;

function TJ2MEContainerAudioSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.SampleRate := FRate;
  Result.Channels := FChannels;
  Result.TrackCount := 1;
  Result.TrackDurations := [FEnd / FRate];
end;

procedure TJ2MEContainerAudioSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('MP4 audio track index');
  if FDecoder <> nil then
    FDecoder.Reset
  else
    (FSpeech as IAudioTracks).SelectTrack(0);
  FFrame := Default(Audio.Types.TAudioFrame);
  FPacket := 0;
  FPosition := 0;
end;

function TJ2MEContainerAudioSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FChannels);
  Result := Integer(Min(Int64(Frames), FEnd - FPosition));
  if Result = 0 then
    Exit;
  FillChar(Samples[0], Result * FChannels * SizeOf(SmallInt), 0);
  var Limit := FPosition + Result;
  var Cursor := Max(FPosition, FStart);
  while Cursor < Limit do
  begin
    while (FFrame.Frames = 0) or (Cursor >= FFrame.SamplePosition + FFrame.Frames) do
    begin
      if FPacket = FTrack.PacketCount then
      begin
        FPosition := Limit;
        Exit;
      end;
      DecodeFrame;
    end;
    Cursor := Max(Cursor, FFrame.SamplePosition);
    if Cursor >= Limit then
      Break;
    var Count := Integer(Min(Limit, FFrame.SamplePosition + FFrame.Frames) - Cursor);
    var FromIndex := Integer(Cursor - FFrame.SamplePosition) * FChannels;
    var ToIndex := Integer(Cursor - FPosition) * FChannels;
    Move(FFrame.Samples[FromIndex], Samples[ToIndex], Count * FChannels * SizeOf(SmallInt));
    Inc(Cursor, Count);
  end;
  FPosition := Limit;
end;

function OpenJ2MEContainerAudio(const Data: TBytes): IAudioSource;
begin
  Result := TJ2MEContainerAudioSource.Create(Data);
end;

function J2MEContainerAudioType(const Name: string): Boolean;
begin
  Result := (Name = MP4AudioContentType) or (Name = ThreeGPAudioContentType);
end;

function J2MEVideoContentType(const Name: string): Boolean;
begin
  Result := (Name = 'video/mp4') or (Name = 'video/3gpp') or (Name = 'video/mpeg4-generic');
end;

function DetectJ2MEVideoType(const Data: TBytes): string;
begin
  Result := '';
  if (Length(Data) < 12) or (Data[4] <> Ord('f')) or (Data[5] <> Ord('t')) or
    (Data[6] <> Ord('y')) or (Data[7] <> Ord('p')) then
    Exit;
  var ThreeGP := (Data[8] = Ord('3')) and (Data[9] = Ord('g'));
  if TMP4Track.IsAudioOnly(Data) then
  begin
    if ThreeGP then
      Exit(ThreeGPAudioContentType);
    Exit(MP4AudioContentType);
  end;
  if ThreeGP then
    Result := 'video/3gpp'
  else
    Result := 'video/mp4';
end;

constructor TJ2MEVideoStream.Create(const Data: TBytes);
begin
  inherited Create;
  FTrack := TMP4Track.Create(Data);
  if (FTrack.Info.Width > 1024) or (FTrack.Info.Height > 1024) or
    (FTrack.Info.Duration < 1000) or (FTrack.Info.Duration > J2MEVideoMaxDuration) then
    raise EPlayerUnsupported.Create('Unsupported J2ME video dimensions or duration');
  FFrameTimes := FTrack.PresentationTimes;
  if Length(FFrameTimes) = 0 then
    raise EPlayerUnsupported.Create('MP4 has no visible video frames');
  if FTrack.Info.Codec = 's263' then
  begin
    FDecoder := CreateH263Decoder;
    FDecoder.Configure(FTrack.Info);
  end
  else
    FDecoder := TH264Decoder.Create(False, False, 1024 * 1024);
  FLastTime := -1;
  FNextAudioPosition := -1;
  OpenAudio(Data);
  if not HasAudio then
    OpenSpeechAudio(Data);
end;

destructor TJ2MEVideoStream.Destroy;
begin
  FDecoder := nil;
  FAudioDecoder := nil;
  FAudio.Free;
  FTrack.Free;
  inherited;
end;

function TJ2MEVideoStream.GetInfo: Video.AVC.Types.TTrackInfo;
begin
  Result := FTrack.Info;
end;

procedure TJ2MEVideoStream.OpenAudio(const Data: TBytes);
begin
  var Track: TMP4Track := nil;
  try
    try
      Track := TMP4Track.Create(Data, Video.AVC.Types.TTrackKind.Audio, 'mp4a');
      if (Track.Info.Duration <= Track.Info.StartTime) or (Track.Info.Duration > J2MEVideoMaxDuration) then
        Exit;
      var Config := Track.Info.CodecConfig;
      // LC overlap can be primed locally. Other profiles can require all prior
      // access units, notably when SBR headers are transmitted intermittently.
      if Config[0] shr 3 <> 2 then
        Exit;
      var Channels: Integer;
      var Decoder := ConfigureAAC(Track, FAudioRate, Channels);
      FAudioDelay := Media.Types.RescaleTime(Track.EditDelay, J2MEVideoClockRate, FAudioRate);
      FAudioDecoder := Decoder;
      FAudioStart := Track.Info.StartTime;
      FAudioEnd := Track.Info.Duration;
      FAudio := Track;
      Track := nil;
    except
      on E: Video.AVC.Types.EPlayerError do
        ; // The audio track is optional. Keep playing a supported picture.
    end;
  finally
    Track.Free;
  end;
end;

procedure TJ2MEVideoStream.OpenSpeechAudio(const Data: TBytes);
begin
  for var Kind in [TAMRKind.Narrowband, TAMRKind.Wideband] do
  begin
    var Codec := 'samr';
    if Kind = TAMRKind.Wideband then
      Codec := 'sawb';
    try
      var Source := TJ2MEContainerAudioSource.Create(Data, Codec);
      FSpeech := Source;
      FAudioRate := Source.FRate;
      FAudioStart := Source.FTrack.Info.StartTime;
      FAudioEnd := Source.FTrack.Info.Duration;
      Exit;
    except
      on E: EPlayerError do
        ;
      on E: EReadError do
        ;
      on E: ENotSupportedException do
        ;
    end;
  end;
end;

function TJ2MEVideoStream.GetHasAudio: Boolean;
begin
  Result := (FAudio <> nil) or (FSpeech <> nil);
end;

function TJ2MEVideoStream.GetDuration: Int64;
begin
  Result := FTrack.Info.Duration;
  if HasAudio then
    Result := Max(Result, FAudioEnd);
end;

function TJ2MEVideoStream.GetFrameCount: Integer;
begin
  Result := Length(FFrameTimes);
end;

function TJ2MEVideoStream.FrameToTime(Index: Integer): Int64;
begin
  if (Index < 0) or (Index >= Length(FFrameTimes)) then
    Exit(-1);
  Result := FFrameTimes[Index];
end;

function TJ2MEVideoStream.TimeToFrame(Time: Int64): Integer;
begin
  if Time = 0 then
    Exit(0);
  if (Time < FFrameTimes[0]) or (Time > Duration) then
    Exit(-1);
  Result := 0;
  var Last := High(FFrameTimes);
  while Result < Last do
  begin
    var Mid := (Result + Last + 1) div 2;
    if FFrameTimes[Mid] <= Time then
      Result := Mid
    else
      Last := Mid - 1;
  end;
end;

function TJ2MEVideoStream.DecodeAudio: Boolean;
begin
  Result := False;
  if FAudioPacket >= FAudio.PacketCount then
    Exit;
  DecodeAACPacket(FAudio, FAudioDecoder, FAudioPacket, FAudioRate, FAudioDelay, FAudioFrame);
  Inc(FAudioPacket);
  Result := True;
end;

procedure TJ2MEVideoStream.CacheSpeechFrame(const Frame: Audio.Types.TAudioFrame);
begin
  if Length(FSpeechCache) = 0 then
    SetLength(FSpeechCache, SpeechCachePackets);
  var Bytes := Length(Frame.Samples) * SizeOf(SmallInt);
  if Bytes > SpeechCacheBytes then
    raise EPlayerFormat.Create('Oversized decoded AMR frame');
  if FSpeechCount <> 0 then
  begin
    var Previous := FSpeechCache[(FSpeechFirst + FSpeechCount - 1) mod Length(FSpeechCache)];
    if Frame.SamplePosition + Frame.Frames < Previous.SamplePosition + Previous.Frames then
      raise EPlayerFormat.Create('Nonmonotonic AMR sample timeline');
  end;
  while (FSpeechCount = Length(FSpeechCache)) or (FSpeechCachedBytes + Bytes > SpeechCacheBytes) do
  begin
    Dec(FSpeechCachedBytes, Length(FSpeechCache[FSpeechFirst].Samples) * SizeOf(SmallInt));
    FSpeechCache[FSpeechFirst] := Default(Audio.Types.TAudioFrame);
    FSpeechFirst := (FSpeechFirst + 1) mod Length(FSpeechCache);
    Dec(FSpeechCount);
  end;
  FSpeechCache[(FSpeechFirst + FSpeechCount) mod Length(FSpeechCache)] := Frame;
  Inc(FSpeechCount);
  Inc(FSpeechCachedBytes, Bytes);
end;

function TJ2MEVideoStream.FindSpeechFrame(Sample: Int64; const Cancelled: TFunc<Boolean>): Boolean;
begin
  if FSpeechCount <> 0 then
  begin
    if Sample < FSpeechCache[FSpeechFirst].SamplePosition then
    begin
      // The decoder is stateful. Decode the prefix again only for a seek
      // outside the cached window, and discard packets from the old cursor.
      FSpeech.SelectTrack(0);
      FSpeechCache := nil;
      FSpeechFirst := 0;
      FSpeechCount := 0;
      FSpeechCachedBytes := 0;
      FSpeechAtEnd := False;
    end
    else
    begin
      var LowIndex := 0;
      var HighIndex := FSpeechCount;
      while LowIndex < HighIndex do
      begin
        var Middle := (LowIndex + HighIndex) div 2;
        var Frame := FSpeechCache[(FSpeechFirst + Middle) mod Length(FSpeechCache)];
        if Sample < Frame.SamplePosition + Frame.Frames then
          HighIndex := Middle
        else
          LowIndex := Middle + 1;
      end;
      if LowIndex < FSpeechCount then
      begin
        FAudioFrame := FSpeechCache[(FSpeechFirst + LowIndex) mod Length(FSpeechCache)];
        Exit(True);
      end;
    end;
  end;

  while not FSpeechAtEnd do
  begin
    if Assigned(Cancelled) and Cancelled() then
      raise EAbort.Create('Video audio decoding cancelled');
    if not FSpeech.NextPacket(FAudioFrame) then
    begin
      FSpeechAtEnd := True;
      Break;
    end;
    CacheSpeechFrame(FAudioFrame);
    if Sample < FAudioFrame.SamplePosition + FAudioFrame.Frames then
      Exit(True);
  end;
  Result := False;
end;

procedure TJ2MEVideoStream.MixAudio(Position: Int64; Offset, Frames, Level: Integer; var Mix: TArray<Int64>; const Cancelled: TFunc<Boolean>);
begin
  if not HasAudio or (Frames = 0) then
    Exit;
  if FNextAudioPosition <> Position then
  begin
    if FSpeech = nil then
    begin
      FAudioDecoder.Reset;
      FAudioFrame := Default(Audio.Types.TAudioFrame);
      FAudioPacket := Max(0, FAudio.SeekPacket(Position div MixRate) - 2);
    end
    else if Position < FNextAudioPosition then
      FAudioFrame := Default(Audio.Types.TAudioFrame);
  end;
  FNextAudioPosition := Position + Int64(Frames) * J2MEVideoClockRate;
  var First := FAudioStart * MixRate;
  var Last := FAudioEnd * MixRate;
  var Decoded := 0;
  for var I := 0 to Frames - 1 do
  begin
    var Current := Position + Int64(I) * J2MEVideoClockRate;
    if Current < First then
      Continue;
    if Current >= Last then
      Break;
    var Part := (Current mod ClockScale) * FAudioRate;
    var Sample := (Current div ClockScale) * FAudioRate + Part div ClockScale;
    while (FAudioFrame.Frames = 0) or (Sample >= FAudioFrame.SamplePosition + FAudioFrame.Frames) do
    begin
      if FSpeech <> nil then
      begin
        if not FindSpeechFrame(Sample, Cancelled) then
          Exit;
      end
      else
      begin
        if Assigned(Cancelled) and Cancelled() then
          raise EAbort.Create('Video audio decoding cancelled');
        if not DecodeAudio then
          Exit;
        Inc(Decoded);
        if Decoded > 64 then
          raise Video.AVC.Types.EPlayerFormat.Create('MP4 AAC packet timing exceeds render budget');
      end;
    end;
    var local := Sample - FAudioFrame.SamplePosition;
    if (local < 0) or (Level = 0) then
      Continue;
    var Index := Integer(local) * FAudioFrame.Channels;
    var Fraction := Part mod ClockScale;
    for var Channel := 0 to 1 do
    begin
      var At := Index + Min(Channel, FAudioFrame.Channels - 1);
      var Value := Int64(FAudioFrame.Samples[At]);
      if local + 1 < FAudioFrame.Frames then
        Inc(Value, (FAudioFrame.Samples[At + FAudioFrame.Channels] - Value) * Fraction div ClockScale);
      Inc(Mix[(Offset + I) * 2 + Channel], Value * Level div 100);
    end;
  end;
end;

procedure TJ2MEVideoStream.Reset;
begin
  FFrame := Default(TVideoFrame);
  FNext := Default(TVideoFrame);
  FFlushed := False;
  FLastTime := -1;
  FPacket := 0;
end;

function TJ2MEVideoStream.Advance(Time: Int64): Boolean;
begin
  Result := False;
  if Time < FFrameTimes[0] then
  begin
    Result := FFrame.Width <> 0;
    if Result then
      Reset;
    Exit;
  end;
  Time := Min(Time, FFrameTimes[High(FFrameTimes)]);
  if (FLastTime < 0) or (Time < FLastTime) or (Time - FLastTime > 500000) then
  begin
    Result := FFrame.Width <> 0;
    Reset;
    FDecoder.Configure(FTrack.Info);
    FPacket := FTrack.SeekPacket(Time);
  end;
  FLastTime := Time;
  var Submitted := 0;
  while True do
  begin
    if FNext.Width <> 0 then
    begin
      if FNext.PTS > Time then
        Exit;
      FFrame := FNext;
      FNext := Default(TVideoFrame);
      Result := True;
    end;
    if FDecoder.Receive(FNext) then
      Continue;
    if FPacket >= FTrack.PacketCount then
    begin
      if FFlushed then
        Exit;
      FDecoder.Flush;
      FFlushed := True;
      Continue;
    end;
    if Submitted >= 4 then
      Exit;
    FDecoder.Send(FTrack.Packet(FPacket));
    Inc(FPacket);
    Inc(Submitted);
  end;
end;

function TJ2MEVideoStream.SnapshotReady(Time: Int64): Boolean;
begin
  var FrameNumber := TimeToFrame(Time);
  Result := (FrameNumber >= 0) and (FFrame.Width <> 0) and
    ((FFrame.PTS >= FFrameTimes[FrameNumber]) or FFlushed or ((FNext.Width <> 0) and (FNext.PTS > Time)));
end;

function TJ2MEVideoStream.EncodeSnapshot(const Format: string; Width, Height, Quality, Transform: Integer): TBytes;
begin
  var SourceWidth := FFrame.Width;
  var SourceHeight := FFrame.Height;
  if Transform >= 4 then
  begin
    SourceWidth := FFrame.Height;
    SourceHeight := FFrame.Width;
  end;
  if (Width = 0) and (Height = 0) then
  begin
    Width := SourceWidth;
    Height := SourceHeight;
  end
  else if Width = 0 then
    Width := Max(1, Height * SourceWidth div SourceHeight)
  else if Height = 0 then
    Height := Max(1, Width * SourceHeight div SourceWidth);
  if (Width > 1024) or (Height > 1024) then
    raise Video.AVC.Types.EPlayerUnsupported.Create('Video snapshot dimensions exceed 1024 pixels');
  var Pixels: TArray<UInt32>;
  SetLength(Pixels, Width * Height);
  Draw(Pixels, Width, 0, 0, Width, Height, Transform, Rect(0, 0, Width, Height));
  var Stream := TMemoryStream.Create;
  try
    if Format = 'png' then
      WritePNGRGB(Stream, Width, Height, Width, @Pixels[0])
    else
      WriteJPEGRGB(Stream, Width, Height, Pixels, Quality);
    SetLength(Result, Stream.Size);
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

procedure TJ2MEVideoStream.Draw(var Pixels: TArray<UInt32>; Stride, X, Y, W, H, Transform: Integer; const Clip: TRect);
begin
  if (FFrame.Width = 0) or (W <= 0) or (H <= 0) then
    Exit;
  var Left := Max(Clip.Left, X);
  var Right := Integer(Min(Int64(Clip.Right), Int64(X) + W));
  var First := Max(Clip.Top, Y);
  var Last := Integer(Min(Int64(Clip.Bottom), Int64(Y) + H));
  var SourceWidth := FFrame.Width;
  var SourceHeight := FFrame.Height;
  var OrientedWidth := SourceWidth;
  var OrientedHeight := SourceHeight;
  if Transform >= 4 then
  begin
    OrientedWidth := SourceHeight;
    OrientedHeight := SourceWidth;
  end;
  var Converter: TAVCColorConverter;
  Converter.Configure(FFrame);
  for var DY := First to Last - 1 do
  begin
    var V := Integer((Int64(DY) - Y) * OrientedHeight div H);
    for var DX := Left to Right - 1 do
    begin
      var U := Integer((Int64(DX) - X) * OrientedWidth div W);
      var SX, SY: Integer;
      J2METransformSource(U, V, SourceWidth, SourceHeight, Transform, SX, SY);
      Pixels[DY * Stride + DX] := Converter.Pixel(FFrame, SX, SY);
    end;
  end;
end;

end.

