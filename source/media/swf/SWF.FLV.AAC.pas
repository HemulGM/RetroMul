unit SWF.FLV.AAC;

interface

uses
  System.SysUtils, SWF.Sound, Audio.Types, Media.Types;

type
  TFLVAACTrack = class
  private
    FConfig: TBytes;
    FDecoder: IAudioDecoder;
    FSamples: TArray<SmallInt>;
    FStart, FLastTime: Int64;
    FRate, FChannels, FCount: Integer;
    procedure AppendFrame(const Frame: TAudioFrame; Time: Int64);
  public
    procedure AddConfiguration(const Config: TBytes);
    procedure AddAccessUnit(const Data: TBytes; Time: Int64);
    function Finish(out StartTime: Int64): TSWFSound;
  end;

implementation

uses
  System.Math, Audio.AAC, SWF.Reader;

procedure TFLVAACTrack.AddConfiguration(const Config: TBytes);
var
  Track: TTrackInfo;
  Decoder: IAudioDecoder;
begin
  if (Length(Config) = Length(FConfig)) and (FDecoder <> nil) and
    CompareMem(Pointer(Config), Pointer(FConfig), Length(Config)) then
    Exit;
  Track := Default(TTrackInfo);
  Track.Codec := 'mp4a';
  Track.CodecConfig := Config;
  Decoder := TAACDecoder.Create;
  try
    Decoder.Configure(Track);
  except
    on E: EPlayerError do
      raise ESWFError.Create('FLV AAC configuration: ' + E.Message);
  end;
  FDecoder := Decoder;
  FConfig := Config;
end;

procedure TFLVAACTrack.AppendFrame(const Frame: TAudioFrame; Time: Int64);
var
  AtFrame, CurrentFrames, DropFrames: Int64;
  AtSample, Needed, Skip, Written: Integer;
begin
  if (Frame.Frames <= 0) or (Frame.SampleRate <= 0) or not (Frame.Channels in [1, 2]) or
    (Length(Frame.Samples) <> Frame.Frames * Frame.Channels) then
    raise ESWFError.Create('Invalid FLV AAC PCM frame');
  if FRate = 0 then
  begin
    FRate := Frame.SampleRate;
    FChannels := Frame.Channels;
    FStart := Time;
  end;
  if (Frame.SampleRate <> FRate) or (Frame.Channels <> FChannels) then
    raise ESWFError.Create('FLV AAC output format changes midstream');
  CurrentFrames := FCount div FChannels;
  AtFrame := ((Time - FStart) * FRate + 500) div 1000;
  // FLV records times in milliseconds. Keep consecutive AAC blocks sample
  // aligned, with a tolerance for rounding the packet timestamp.
  if Abs(AtFrame - CurrentFrames) <= ((2 * FRate + 999) div 1000) then
    AtFrame := CurrentFrames;
  DropFrames := Max(Int64(0), CurrentFrames - AtFrame);
  if DropFrames >= Frame.Frames then
    Exit;
  AtFrame := Max(AtFrame, CurrentFrames);
  if (AtFrame + Frame.Frames - DropFrames) * FChannels > SWFMovieSoundSampleLimit then
    raise ESWFSoundLimit.Create('FLV AAC sample limit');
  AtSample := Integer(AtFrame) * FChannels;
  Skip := Integer(DropFrames) * FChannels;
  Written := Length(Frame.Samples) - Skip;
  Needed := AtSample + Written;
  if Needed > Length(FSamples) then
    SetLength(FSamples, Min(SWFMovieSoundSampleLimit, Max(Needed, Max(4096, Length(FSamples) * 2))));
  Move(Frame.Samples[Skip], FSamples[AtSample], Written * SizeOf(SmallInt));
  FCount := Needed;
end;

procedure TFLVAACTrack.AddAccessUnit(const Data: TBytes; Time: Int64);
var
  Packet: TMediaPacket;
  Frame: TAudioFrame;
begin
  if FDecoder = nil then
    raise ESWFError.Create('FLV AAC data precedes its configuration');
  if (Length(Data) = 0) or (Time < FLastTime) then
    raise ESWFError.Create('Invalid FLV AAC access unit or timestamp');
  Packet := Default(TMediaPacket);
  Packet.Data := Data;
  Packet.PTS := Time * 1000;
  Packet.DTS := Packet.PTS;
  Packet.SourcePTS := Time;
  Packet.SourceTimeScale := 1000;
  try
    FDecoder.Send(Packet);
    while FDecoder.Receive(Frame) do
      AppendFrame(Frame, Time);
  except
    on E: EPlayerError do
      raise ESWFError.Create('FLV AAC decode: ' + E.Message);
  end;
  FLastTime := Time;
end;

function TFLVAACTrack.Finish(out StartTime: Int64): TSWFSound;
begin
  StartTime := FStart;
  if FCount = 0 then
    Exit(nil);
  SetLength(FSamples, FCount);
  Result := TSWFSound.Create;
  Result.SampleRate := FRate;
  Result.Channels := FChannels;
  Result.Samples := FSamples;
end;

end.

