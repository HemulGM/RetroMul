unit Audio.Format.ADTS;

interface

uses
  System.SysUtils, Audio.Types;

function OpenADTS(const Data: TBytes): IAudioSource;

implementation

uses
  System.Classes, System.Math, Audio.Decoder, Audio.Binary, Audio.AAC,
  Audio.MP3.Metadata, Media.Types;

type
  TADTSHeader = record
    Profile, RateIndex, Channels, Size, HeaderSize: Integer;
  end;

  TADTSSource = class(TAudioMusicSource)
  private
    FData: TBytes;
    FInfo: TAudioInfo;
    FStart, FEnd, FOffset, FRead: Integer;
    FHeader: TADTSHeader;
    FDecoder: TAACDecoder;
    FOwner: IAudioDecoder;
    FFrame: TAudioFrame;
    procedure DecodeFrame;
  public
    constructor Create(const Data: TBytes);
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

function ReadHeader(const Data: TBytes; Offset, Limit: Integer): TADTSHeader;
begin
  if (Limit - Offset < 7) or (Data[Offset] <> $FF) or ((Data[Offset + 1] and $F6) <> $F0) then
    raise EArgumentException.Create('Invalid AAC ADTS header');
  if (Data[Offset + 6] and 3) <> 0 then
    raise ENotSupportedException.Create('Multiple AAC blocks per ADTS packet are unsupported');
  Result.HeaderSize := 7;
  if (Data[Offset + 1] and 1) = 0 then
    Inc(Result.HeaderSize, 2);
  Result.Profile := (Data[Offset + 2] shr 6) + 1;
  Result.RateIndex := (Data[Offset + 2] shr 2) and 15;
  Result.Channels := ((Data[Offset + 2] and 1) shl 2) or (Data[Offset + 3] shr 6);
  Result.Size := ((Data[Offset + 3] and 3) shl 11) or (Integer(Data[Offset + 4]) shl 3) or
    (Data[Offset + 5] shr 5);
  if (Result.RateIndex > 12) or (Result.Size <= Result.HeaderSize) or (Result.Size > Limit - Offset) then
    raise EArgumentException.Create('Invalid AAC ADTS packet length or sample rate');
end;

constructor TADTSSource.Create(const Data: TBytes);
begin
  inherited Create;
  var Metadata := ReadMP3Metadata(Data);
  FData := Data;
  FStart := Metadata.AudioOffset;
  FEnd := Metadata.AudioEnd;
  FHeader := ReadHeader(Data, FStart, FEnd);
  var Count := 0;
  var Offset := FStart;
  while Offset < FEnd do
  begin
    var Header := ReadHeader(Data, Offset, FEnd);
    if (Header.Profile <> FHeader.Profile) or (Header.RateIndex <> FHeader.RateIndex) or
      (Header.Channels <> FHeader.Channels) then
      raise ENotSupportedException.Create('AAC ADTS changes its stream configuration');
    Inc(Count);
    Inc(Offset, Header.Size);
  end;
  FInfo.FormatName := 'AAC (ADTS)';
  FInfo.TrackCount := 1;
  for var Item in Metadata.TextFrames do
  begin
    if (Item.Id = 'TIT2') and (FInfo.Title = '') then
      FInfo.Title := Item.Text;
    if (Item.Id = 'TPE1') and (FInfo.Artist = '') then
      FInfo.Artist := Item.Text;
  end;
  SelectTrack(0);
  FInfo.SampleRate := FFrame.SampleRate;
  FInfo.Channels := FFrame.Channels;
  FInfo.TrackDurations := [Int64(Count) * FFrame.Frames / FInfo.SampleRate];
end;

procedure TADTSSource.DecodeFrame;
begin
  var Header := ReadHeader(FData, FOffset, FEnd);
  var Packet := Default(TMediaPacket);
  Packet.Data := Copy(FData, FOffset + Header.HeaderSize, Header.Size - Header.HeaderSize);
  Packet.SourceTimeScale := Cardinal(FDecoder.OutputRate);
  FOwner.Send(Packet);
  if not FOwner.Receive(FFrame) or (FFrame.Frames <= 0) then
    raise EReadError.Create('Empty AAC ADTS access unit');
  if Header.HeaderSize = 9 then
  begin
    var CRC := AACCRC16(Copy(FData, FOffset, 7), 0, 56, $FFFF);
    if FDecoder.ProtectedCRC(CRC) <> (Word(FData[FOffset + 7]) shl 8 or FData[FOffset + 8]) then
      raise EReadError.Create('AAC ADTS CRC mismatch');
  end;
  if (FInfo.SampleRate <> 0) and ((FFrame.SampleRate <> FInfo.SampleRate) or
    (FFrame.Channels <> FInfo.Channels)) then
    raise ENotSupportedException.Create('AAC ADTS changes its output format');
  Inc(FOffset, Header.Size);
  FRead := 0;
end;

function TADTSSource.GetInfo: TAudioInfo;
begin
  Result := FInfo;
end;

procedure TADTSSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('AAC ADTS track index');
  FOffset := FStart;
  FDecoder := TAACDecoder.Create;
  FOwner := FDecoder;
  FDecoder.ConfigureADTS(FHeader.Profile, FHeader.RateIndex, FHeader.Channels,
    Copy(FData, FStart + FHeader.HeaderSize, FHeader.Size - FHeader.HeaderSize));
  DecodeFrame;
end;

function TADTSSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FInfo.Channels);
  Result := 0;
  while Result < Frames do
  begin
    if FRead = FFrame.Frames then
    begin
      if FOffset = FEnd then
        Break;
      DecodeFrame;
    end;
    var Count := Min(Frames - Result, FFrame.Frames - FRead);
    Move(FFrame.Samples[FRead * FInfo.Channels], Samples[Result * FInfo.Channels],
      Count * FInfo.Channels * SizeOf(SmallInt));
    Inc(FRead, Count);
    Inc(Result, Count);
  end;
end;

function OpenADTS(const Data: TBytes): IAudioSource;
begin
  Result := TADTSSource.Create(Data);
end;

end.

