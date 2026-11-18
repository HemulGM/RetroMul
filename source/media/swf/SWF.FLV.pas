unit SWF.FLV;

interface

uses
  System.SysUtils, SWF.Video, SWF.Sound;

const
  FLVScriptTagLimit = 2 * 1024 * 1024;

type
  TFLVScriptTag = record
    Time: Int64;
    Data: TBytes;
  end;

  TFLVMovie = class
  private
    FVideo: TSWFVideoStream;
    FAudio: TSWFSound;
    FTimestamps: TArray<Int64>;
    FScripts: TArray<TFLVScriptTag>;
    FDuration, FAudioStart: Int64;
    FBytes: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    function FrameAt(Time: Int64): Integer;
    function SeekTime(Time: Int64): Int64;
    function MemorySize: Int64;
    function FirstScriptAt(Time: Int64): Integer;
    property Video: TSWFVideoStream read FVideo;
    property Audio: TSWFSound read FAudio;
    property Duration: Int64 read FDuration;
    property AudioStart: Int64 read FAudioStart;
    property Bytes: Integer read FBytes;
    property Scripts: TArray<TFLVScriptTag> read FScripts;
  end;

implementation

uses
  System.Classes, System.Math, System.Generics.Collections, SWF.Reader,
  SWF.FLV.AVC, SWF.FLV.AAC;

const
  FLVRates: array[0..3] of Integer = (5512, 11025, 22050, 44100);

function UInt24(const Data: TBytes; At: Integer): Integer;
begin
  Result := (Integer(Data[At]) shl 16) or (Integer(Data[At + 1]) shl 8) or Data[At + 2];
end;

function UInt32(const Data: TBytes; At: Integer): Cardinal;
begin
  Result := (Cardinal(Data[At]) shl 24) or Cardinal(UInt24(Data, At + 1));
end;

constructor TFLVMovie.Create(const Data: TBytes);
var
  Packets: TList<TBytes>;
  Times: TList<Int64>;
  Scripts: TList<TFLVScriptTag>;
  Script: TFLVScriptTag;
  MP3: TMemoryStream;
  AVC: TFLVAVCStream;
  AAC: TFLVAACTrack;
  Decoder: TSWFStreamDecoder;
  Reader: TSWFReader;
  Format: TSWFStreamFormat;
  Offset, Last, Payload, Size, Kind, Index, Flags, AudioFlags, AudioFormat, Frame, Declared: Integer;
  Time: Int64;
  VideoCodec: Integer;
  AudioBytes: TBytes;
  HasAudio: Boolean;

  procedure ReadAVCTag;
  var
    Composition: Integer;
  begin
    if Size < 5 then
      raise ESWFError.Create('Truncated FLV AVC header');
    Composition := UInt24(Data, Payload + 2);
    if Composition and $800000 <> 0 then
      Dec(Composition, $1000000);
    if AVC = nil then
    begin
      AVC := TFLVAVCStream.Create;
      FVideo := AVC;
    end;
    case Data[Payload + 1] of
      0:
        AVC.AddConfiguration(Copy(Data, Payload + 5, Size - 5));
      1:
        AVC.AddAccessUnit(Copy(Data, Payload + 5, Size - 5), Time, Time + Composition);
      2:
        ; // The container signals the end of the AVC sequence.
    else
      raise ESWFError.Create('Unknown FLV AVC packet type');
    end;
  end;

  procedure ReadAACTag;
  begin
    if AAC = nil then
      AAC := TFLVAACTrack.Create;
    case Data[Payload + 1] of
      0:
        AAC.AddConfiguration(Copy(Data, Payload + 2, Size - 2));
      1:
        AAC.AddAccessUnit(Copy(Data, Payload + 2, Size - 2), Time);
    else
      raise ESWFError.Create('Unknown FLV AAC packet type');
    end;
  end;

begin
  inherited Create;
  FBytes := Length(Data);
  if (FBytes < 13) or (FBytes > 64 * 1024 * 1024) or (Data[0] <> Ord('F')) or
    (Data[1] <> Ord('L')) or (Data[2] <> Ord('V')) or (Data[3] <> 1) then
    raise ESWFError.Create('Invalid FLV header');
  if (UInt32(Data, 5) < 9) or (UInt32(Data, 5) > Cardinal(FBytes - 4)) then
    raise ESWFError.Create('Invalid FLV data offset');
  Offset := UInt32(Data, 5);
  if UInt32(Data, Offset) <> 0 then
    raise ESWFError.Create('Invalid initial FLV tag size');
  Inc(Offset, 4);
  Packets := TList<TBytes>.Create;
  Times := TList<Int64>.Create;
  Scripts := TList<TFLVScriptTag>.Create;
  Decoder := nil;
  MP3 := nil;
  AVC := nil;
  AAC := nil;
  HasAudio := False;
  AudioFlags := 0;
  AudioFormat := 0;
  VideoCodec := 0;
  try
    while Offset < FBytes do
    begin
      if FBytes - Offset < 15 then
        raise ESWFError.Create('Truncated FLV tag');
      Kind := Data[Offset];
      Size := UInt24(Data, Offset + 1);
      Time := Int64(UInt24(Data, Offset + 4)) or (Int64(Data[Offset + 7]) shl 24);
      if UInt24(Data, Offset + 8) <> 0 then
        raise ESWFError.Create('Invalid FLV stream ID');
      Payload := Offset + 11;
      if Size > FBytes - Payload - 4 then
        raise ESWFError.Create('Truncated FLV payload');
      Last := Payload + Size;
      if UInt32(Data, Last) <> Cardinal(Size + 11) then
        raise ESWFError.Create('Invalid FLV previous tag size');
      Offset := Last + 4;
      if Kind and $20 <> 0 then
        raise ESWFError.Create('Encrypted FLV tags are unsupported');
      case Kind and 31 of
        18:
          if (Size > 0) and (Size <= FLVScriptTagLimit) and (Scripts.Count < 4096) then
          begin
            Script.Time := Time;
            if Scripts.Count > 0 then
              Script.Time := Max(Time, Scripts.Last.Time);
            Script.Data := Copy(Data, Payload, Size);
            Scripts.Add(Script);
          end;
        9:
          begin
            if Size = 0 then
              raise ESWFError.Create('Empty FLV video tag');
            Flags := Data[Payload];
            if Flags shr 4 = 5 then
              Continue;
            if not (Flags and 15 in [SWFSorensonSparkCodec, SWFScreenVideoCodec, SWFVP6Codec, SWFVP6AlphaCodec, SWFScreenVideo2Codec, SWFAVCCodec]) then
              raise ESWFError.CreateFmt('Unsupported FLV video codec %d', [Flags and 15]);
            if VideoCodec = 0 then
              VideoCodec := Flags and 15;
            if VideoCodec <> Flags and 15 then
              raise ESWFError.Create('FLV video codec changes midstream');
            if VideoCodec = SWFAVCCodec then
            begin
              ReadAVCTag;
              Continue;
            end;
            if (Packets.Count >= 65535) or ((Times.Count > 0) and (Time < Times.Last)) then
              raise ESWFError.Create('Invalid FLV video timestamp or frame count');
            if VideoCodec in [SWFVP6Codec, SWFVP6AlphaCodec] then
              Packets.Add(Copy(Data, Payload + 1, Size - 1))
            else
              Packets.Add(Copy(Data, Payload, Size));
            Times.Add(Time);
          end;
        8:
          begin
            if Size < 2 then
              Continue;
            Flags := Data[Payload];
            if not HasAudio then
            begin
              HasAudio := True;
              AudioFlags := Flags;
              AudioFormat := Flags shr 4;
              FAudioStart := Time;
              if AudioFormat in [0, 1, 3] then
              begin
                Format := Default(TSWFStreamFormat);
                Format.Codec := AudioFormat;
                Format.SampleRate := FLVRates[(Flags shr 2) and 3];
                Format.Channels := 1 + (Flags and 1);
                Format.Wide := Flags and 2 <> 0;
                Decoder := TSWFStreamDecoder.Create(Format, SWFMovieSoundSampleLimit);
              end
              else if AudioFormat in [2, 14] then
                MP3 := TMemoryStream.Create;
            end;
            if (Flags shr 4 <> AudioFormat) or ((AudioFormat <> 10) and (Flags <> AudioFlags)) then
              raise ESWFError.Create('FLV audio format changes midstream');
            if AudioFormat = 10 then
              ReadAACTag
            else if Decoder <> nil then
            begin
              Reader := TSWFReader.Create(Copy(Data, Payload + 1, Size - 1), 8);
              try
                Decoder.AddBlock(Reader, Decoder.FrameCount = 0, Frame, Declared);
              finally
                Reader.Free;
              end;
            end
            else if MP3 <> nil then
              MP3.WriteBuffer(Data[Payload + 1], Size - 1);
          end;
      end;
    end;
    if AVC <> nil then
      AVC.Finish(FTimestamps)
    else
    begin
      if Packets.Count = 0 then
        raise ESWFError.Create('FLV contains no supported video packets');
      FVideo := TSWFVideoStream.Create(0, 0, Packets.Count, VideoCodec, False);
      for Index := 0 to Packets.Count - 1 do
        FVideo.AddFrame(Index, Packets[Index], VideoCodec in [SWFVP6Codec, SWFVP6AlphaCodec, SWFScreenVideo2Codec]);
      FTimestamps := Times.ToArray;
    end;
    FScripts := Scripts.ToArray;
    Index := High(FTimestamps);
    FDuration := Max(Int64(1), FTimestamps[Index] + 1);
    if Index > 0 then
      FDuration := Max(FDuration, FTimestamps[Index] + Max(Int64(1), FTimestamps[Index] - FTimestamps[Index - 1]));
    if Scripts.Count > 0 then
      FDuration := Max(FDuration, Scripts.Last.Time + 1);
    if AAC <> nil then
      FAudio := AAC.Finish(FAudioStart);
    if Decoder <> nil then
      FAudio := Decoder.Finish;
    if (MP3 <> nil) and (MP3.Size > 0) then
    begin
      SetLength(AudioBytes, MP3.Size);
      MP3.Position := 0;
      MP3.ReadBuffer(AudioBytes[0], Length(AudioBytes));
      FAudio := ReadMP3File(AudioBytes, 0, Length(AudioBytes), SWFMovieSoundSampleLimit);
    end;
    if FAudio <> nil then
      FDuration := Max(FDuration, FAudioStart +
        (1000 * Int64(FAudio.FrameCount) + FAudio.SampleRate - 1) div FAudio.SampleRate);
  finally
    AAC.Free;
    MP3.Free;
    Decoder.Free;
    Scripts.Free;
    Times.Free;
    Packets.Free;
  end;
end;

destructor TFLVMovie.Destroy;
begin
  FAudio.Free;
  FVideo.Free;
  inherited;
end;

function TFLVMovie.FrameAt(Time: Int64): Integer;
var
  First, Last, Middle: Integer;
begin
  First := 0;
  Last := Length(FTimestamps);
  while First < Last do
  begin
    Middle := First + (Last - First) div 2;
    if FTimestamps[Middle] <= Time then
      First := Middle + 1
    else
      Last := Middle;
  end;
  Result := First - 1;
end;

function TFLVMovie.SeekTime(Time: Int64): Int64;
var
  Key: Integer;
begin
  Key := FVideo.KeyFrameBefore(FrameAt(Time));
  if Key >= 0 then
    Result := Max(Int64(0), Min(Time, FTimestamps[Key]))
  else
    Result := 0;
end;

function TFLVMovie.FirstScriptAt(Time: Int64): Integer;
var
  Last, Middle: Integer;
begin
  Result := 0;
  Last := Length(FScripts);
  while Result < Last do
  begin
    Middle := Result + (Last - Result) div 2;
    if FScripts[Middle].Time < Time then
      Result := Middle + 1
    else
      Last := Middle;
  end;
end;

function TFLVMovie.MemorySize: Int64;
begin
  Result := FBytes;
  if FVideo is TFLVAVCStream then
    Inc(Result, TFLVAVCStream(FVideo).MemorySize);
  if FAudio <> nil then
    Inc(Result, Int64(Length(FAudio.Samples)) * SizeOf(SmallInt));
end;

end.

