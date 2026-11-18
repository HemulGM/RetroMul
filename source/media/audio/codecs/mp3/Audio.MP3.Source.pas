unit Audio.MP3.Source;

interface

uses
  System.SysUtils, Audio.Types;

function IsMP3Audio(const Data: TBytes): Boolean;

function OpenMP3(const Data: TBytes): IAudioSource;

implementation

uses
  System.Math, System.Generics.Collections, Audio.Decoder, Audio.MP3.Types,
  Audio.MP3.Metadata, Audio.MP3.Frame, Audio.MP3.BitStream, Audio.MP3.Layer3;

type
  TMP3Source = class(TAudioMusicSource, IAudioSeekSource)
  private
    FInfo: TAudioInfo;
    FData, FReservoir: TBytes;
    FOffsets: TArray<Integer>;
    FDecoder: TMP3Layer3Decoder;
    FPCM: TArray<SmallInt>;
    FFrameIndex, FBlockOffset, FSamplesPerFrame, FStartTrim, FSkip: Integer;
    FLength, FPosition: Int64;
    procedure DecodeNext;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
    function SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
  end;

function Tag(const Data: TBytes; Offset, Limit: Integer; const Name: AnsiString): Boolean;
begin
  Result := (Offset >= 0) and (Offset <= Limit - Length(Name)) and
    CompareMem(@Data[Offset], @Name[1], Length(Name));
end;

function FrameAt(const Data: TBytes; Offset, Limit: Integer; out Header: TMP3FrameHeader): Boolean;
begin
  Result := (Offset <= Limit - 4) and TMP3FrameParser.ParseHeader(Data, Offset, Header) and
    (Header.FrameSize <= Limit - Offset) and (Header.FrameSize >= 4 + 2 * Ord(HDR_IS_CRC(Header.hdr)) +
    TMP3FrameParser.SideInfoSize(Header));
end;

function SameFormat(const A, B: TMP3FrameHeader): Boolean;
begin
  Result := (A.Version = B.Version) and (A.SampleRate = B.SampleRate) and (A.Channels = B.Channels);
end;

function FindFirstFrame(const Data: TBytes; Start, Limit: Integer; out Header: TMP3FrameHeader): Integer;
const
  MaxLeadingJunk = 64 * 1024;
begin
  for var Offset := Start to Min(Limit - 4, Start + MaxLeadingJunk) do
  begin
    if (Data[Offset] <> $FF) or not FrameAt(Data, Offset, Limit, Header) then
      Continue;
    var Next := Offset + Header.FrameSize;
    var Following: TMP3FrameHeader;
    if (Next = Limit) or (FrameAt(Data, Next, Limit, Following) and SameFormat(Header, Following)) then
      Exit(Offset);
    // Some games occupy a fixed-size buffer with padding after their clip.
    if Data[Next] = 0 then
    begin
      var Tail := Next;
      while (Tail < Limit) and (Data[Tail] = 0) do
        Inc(Tail);
      if Tail = Limit then
        Exit(Offset);
    end;
  end;
  Result := -1;
end;

function IsMP3Audio(const Data: TBytes): Boolean;
begin
  var Metadata := ReadMP3Metadata(Data);
  var Header: TMP3FrameHeader;
  Result := FindFirstFrame(Data, Metadata.AudioOffset, Metadata.AudioEnd, Header) >= 0;
end;

function ReadBE32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  Result := (Cardinal(Data[Offset]) shl 24) or (Cardinal(Data[Offset + 1]) shl 16) or
    (Cardinal(Data[Offset + 2]) shl 8) or Data[Offset + 3];
end;

function SeekHeader(const Data: TBytes; Offset: Integer; const Header: TMP3FrameHeader; out FrameCount, Delay, Padding: Integer): Boolean;
begin
  FrameCount := 0;
  Delay := 0;
  Padding := 0;
  var Limit := Offset + Header.FrameSize;
  // Xing/Info is part of an ancillary metadata frame, outside the audio.
  var At := Offset + 4 + TMP3FrameParser.SideInfoSize(Header);
  if not (Tag(Data, At, Limit, 'Xing') or Tag(Data, At, Limit, 'Info')) then
    Exit(Tag(Data, Offset + 36, Limit, 'VBRI'));
  Result := True;
  Inc(At, 4);
  if At > Limit - 4 then
    Exit;
  var Flags := ReadBE32(Data, At);
  Inc(At, 4);
  if (Flags and 1) <> 0 then
  begin
    if (At > Limit - 4) or (ReadBE32(Data, At) > Cardinal(MaxInt)) then
      Exit;
    FrameCount := Integer(ReadBE32(Data, At));
    Inc(At, 4);
  end;
  Inc(At, 4 * Ord((Flags and 2) <> 0) + 100 * Ord((Flags and 4) <> 0) + 4 * Ord((Flags and 8) <> 0));
  if (At <= Limit - 24) and (Tag(Data, At, Limit, 'LAME') or Tag(Data, At, Limit, 'Lavc') or
    Tag(Data, At, Limit, 'Lavf')) then
  begin
    Delay := (Integer(Data[At + 21]) shl 4) or (Data[At + 22] shr 4);
    Padding := ((Data[At + 22] and $0F) shl 8) or Data[At + 23];
  end;
end;

function OpenMP3(const Data: TBytes): IAudioSource;
begin
  Result := TMP3Source.Create(Data);
end;

constructor TMP3Source.Create(const Data: TBytes);
const
  DecoderDelay = 529;
var
  First, Header: TMP3FrameHeader;
  Count, Delay, Padding: Integer;
begin
  inherited Create;
  var Metadata := ReadMP3Metadata(Data);
  var At := FindFirstFrame(Data, Metadata.AudioOffset, Metadata.AudioEnd, First);
  if At < 0 then
    raise EArgumentException.Create('MPEG Layer III audio was not found');
  if SeekHeader(Data, At, First, Count, Delay, Padding) then
    Inc(At, First.FrameSize);
  var Offsets := TList<Integer>.Create;
  try
    while FrameAt(Data, At, Metadata.AudioEnd, Header) do
    begin
      if not SameFormat(First, Header) then
        raise EArgumentException.Create('MP3 format changes within the stream');
      Offsets.Add(At);
      Inc(At, Header.FrameSize);
    end;
    FOffsets := Offsets.ToArray;
  finally
    Offsets.Free;
  end;
  if Length(FOffsets) = 0 then
    raise EArgumentException.Create('MP3 has no complete audio frames');

  FData := Data;
  FSamplesPerFrame := 576 * (1 + Ord(First.Version = 3));
  FLength := Int64(Length(FOffsets)) * FSamplesPerFrame;
  if (Count = Length(FOffsets)) and ((Delay <> 0) or (Padding <> 0)) and
    (Delay + DecoderDelay + Max(0, Padding - DecoderDelay) < FLength) then
  begin
    FStartTrim := Delay + DecoderDelay;
    Dec(FLength, FStartTrim + Max(0, Padding - DecoderDelay));
  end;
  FInfo.FormatName := 'MP3';
  FInfo.SampleRate := First.SampleRate;
  FInfo.Channels := First.Channels;
  FInfo.TrackCount := 1;
  FInfo.TrackDurations := [FLength / FInfo.SampleRate];
  for var Field in Metadata.TextFrames do
    if Field.Id = 'TIT2' then
      FInfo.Title := Field.Text
    else if Field.Id = 'TPE1' then
      FInfo.Artist := Field.Text
    else if Field.Id = 'TCOP' then
      FInfo.CopyrightText := Field.Text
    else if (Field.Id = 'TDRC') or (Field.Id = 'TYER') then
    begin
      var Index := Length(FInfo.Metadata);
      SetLength(FInfo.Metadata, Index + 1);
      FInfo.Metadata[Index].Name := Field.Id;
      FInfo.Metadata[Index].Value := Field.Text;
    end;
  SelectTrack(0);
end;

destructor TMP3Source.Destroy;
begin
  FDecoder.Free;
  inherited;
end;

function TMP3Source.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TMP3Source.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('MP3 track index');
  FreeAndNil(FDecoder);
  FDecoder := TMP3Layer3Decoder.Create;
  FFrameIndex := 0;
  FPosition := 0;
  FBlockOffset := 0;
  FSkip := FStartTrim;
  FPCM := nil;
  FReservoir := nil;
end;

function ToPCM(Value: Single): SmallInt;
begin
  if IsNan(Value) then
    Exit(0);
  Result := Round(EnsureRange(Value * 32768.0, -32768.0, 32767.0));
end;

procedure TMP3Source.DecodeNext;
const
  MaxReservoir = 511;
var
  Header: TMP3FrameHeader;
  Side: TMP3SideInfo;
  Left, Right: TArray<Single>;
begin
  var Start := FOffsets[FFrameIndex];
  Inc(FFrameIndex);
  if not TMP3FrameParser.ParseHeader(FData, Start, Header) then
    raise EArgumentException.Create('MP3 frame index is invalid');
  var At := Start + 4 + 2 * Ord(HDR_IS_CRC(Header.hdr));
  var SideSize := TMP3FrameParser.SideInfoSize(Header);
  var Bits := TMP3BitStream.Create(Copy(FData, At, SideSize));
  var Valid: Boolean;
  try
    Valid := TMP3FrameParser.ParseSideInfo(Bits, Header, Side);
  finally
    Bits.Free;
  end;
  Inc(At, SideSize);
  var Main := Copy(FData, At, Start + Header.FrameSize - At);
  if Valid and (Side.MainDataBegin <= Length(FReservoir)) then
  begin
    var RequiredBits := 0;
    for var Granule := 0 to Ord(Header.Version = 3) do
      for var Channel := 0 to Header.Channels - 1 do
        Inc(RequiredBits, Side.Granules[Granule, Channel].Part2_3_Length);
    if RequiredBits <= (Side.MainDataBegin + Length(Main)) * 8 then
    begin
      var Payload := Copy(FReservoir, Length(FReservoir) - Side.MainDataBegin, Side.MainDataBegin) + Main;
      SetLength(Payload, Length(Payload) + 16);
      FDecoder.DecodeFrame(Header, Side, Payload, 0, Left, Right);
    end;
  end;
  FReservoir := FReservoir + Main;
  if Length(FReservoir) > MaxReservoir then
    FReservoir := Copy(FReservoir, Length(FReservoir) - MaxReservoir, MaxReservoir);

  // A clip cut at a frame boundary may begin without its bit reservoir.
  // Keep its timeline until enough complete frames have arrived.
  SetLength(FPCM, FSamplesPerFrame * Header.Channels);
  if (Length(Left) = FSamplesPerFrame) and ((Header.Channels = 1) or (Length(Right) = FSamplesPerFrame)) then
    for var I := 0 to FSamplesPerFrame - 1 do
    begin
      FPCM[I * Header.Channels] := ToPCM(Left[I]);
      if Header.Channels = 2 then
        FPCM[I * 2 + 1] := ToPCM(Right[I]);
    end
  else
    FillChar(FPCM[0], Length(FPCM) * SizeOf(SmallInt), 0);
  FBlockOffset := Min(FSkip, FSamplesPerFrame);
  Dec(FSkip, FBlockOffset);
end;

function TMP3Source.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FInfo.Channels);
  Result := Min(Int64(Frames), FLength - FPosition);
  var Produced := 0;
  while Produced < Result do
  begin
    if FBlockOffset * FInfo.Channels >= Length(FPCM) then
    begin
      DecodeNext;
      if FBlockOffset = FSamplesPerFrame then
        Continue;
    end;
    var Count := Min(Result - Produced, FSamplesPerFrame - FBlockOffset);
    Move(FPCM[FBlockOffset * FInfo.Channels], Samples[Produced * FInfo.Channels],
      Count * FInfo.Channels * SizeOf(SmallInt));
    Inc(FBlockOffset, Count);
    Inc(Produced, Count);
  end;
  Inc(FPosition, Result);
end;

function TMP3Source.SeekFrame(Frame: Int64; const Cancelled: TFunc<Boolean>): Int64;
begin
  Frame := EnsureRange(Frame, Int64(0), FLength);
  if Frame < FPosition then
    SelectTrack(0);
  var Buffer: array[0..4095] of SmallInt;
  while FPosition < Frame do
  begin
    if Assigned(Cancelled) and Cancelled() then
      Break;
    Render(Buffer, Min(Int64(2048), Frame - FPosition));
  end;
  Result := FPosition;
end;

end.

