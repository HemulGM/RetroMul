unit SWF.Sound;

interface

uses
  System.SysUtils, System.Classes, SWF.Reader, Audio.MP3.Layer3;

const
  SWFSoundRate = 44100;
  SWFMovieSoundSampleLimit = 16 * 1024 * 1024;

type
  ESWFSoundUnsupported = class(ESWFError);

  ESWFSoundLimit = class(ESWFError);

  TSWFSound = class
  public
    SampleRate, Channels: Integer;
    Samples: TArray<SmallInt>;
    function FrameCount: Integer;
  end;

  TSWFStreamFormat = record
    Codec, SampleRate, Channels, AverageFrames, Latency: Integer;
    Wide: Boolean;
  end;

  TSWFStreamDecoder = class
  private
    FFormat: TSWFStreamFormat;
    FMaxSamples, FSampleCount: Integer;
    FSound: TSWFSound;
    FMP3: TMP3Layer3Decoder;
    FReservoir: TBytes;
    procedure Reserve(AdditionalSamples: Integer);
    procedure AppendMP3(Stream: TStream);
    function GetFrameCount: Integer;
  public
    constructor Create(const Format: TSWFStreamFormat; MaxSamples: Integer);
    destructor Destroy; override;
    function AddBlock(R: TSWFReader; FirstBlock: Boolean; out Position, DeclaredFrames: Integer): Boolean;
    function Finish: TSWFSound;
    property Sound: TSWFSound read FSound;
    property FrameCount: Integer read GetFrameCount;
  end;

  TSWFSoundEnvelope = record
    Position: Cardinal;
    LeftGain, RightGain: Word;
  end;

  TSWFSoundInfo = record
    Stop, NoMultiple, HasEnd: Boolean;
    First, Last: Cardinal;
    Loops: Integer;
    Envelope: TArray<TSWFSoundEnvelope>;
  end;

  TSWFSoundEvent = record
    Id: Word;
    Info: TSWFSoundInfo;
  end;

function ReadSWFSound(R: TSWFReader; MaxSamples: Integer): TSWFSound;

function ReadSWFSoundEvent(R: TSWFReader): TSWFSoundEvent;

function ReadSWFStreamFormat(R: TSWFReader): TSWFStreamFormat;

function ReadMP3File(const Data: TBytes; AudioOffset, AudioEnd, MaxSamples: Integer): TSWFSound;

implementation

uses
  System.Math, Audio.MP3.Types, Audio.MP3.Frame, Audio.MP3.BitStream;

const
  Rates: array[0..3] of Integer = (5512, 11025, 22050, 44100);

function TSWFSound.FrameCount: Integer;
begin
  Result := Length(Samples) div Channels;
end;

procedure ReadPCM(R: TSWFReader; var Samples: TArray<SmallInt>; Offset, SampleCount: Integer; Wide: Boolean);
var
  I, BytesPerSample: Integer;
begin
  BytesPerSample := 1 + Ord(Wide);
  if R.Remaining <> SampleCount * BytesPerSample then
    raise ESWFError.Create('Invalid SWF PCM sound length');
  if Wide then
    for I := Offset to Offset + SampleCount - 1 do
      Samples[I] := R.S16
  else
    for I := Offset to Offset + SampleCount - 1 do
      Samples[I] := (Integer(R.U8) - 128) * 256;
end;

procedure ReadADPCM(R: TSWFReader; var Samples: TArray<SmallInt>; Offset, FrameCount, Channels, Bits: Integer);
const
  Steps: array[0..88] of Integer = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73,
    80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
    494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
    8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
    27086, 29794, 32767);
  Adjust: array[2..5, 0..15] of ShortInt = (
    (-1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (-1, -1, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (-1, -1, -1, -1, 2, 4, 6, 8, 0, 0, 0, 0, 0, 0, 0, 0),
    (-1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16));
var
  Frame, Ch, SignBit, Code, Magnitude, Bit, Step, Delta: Integer;
  Sample, Index: array[0..1] of Integer;
begin
  SignBit := 1 shl (Bits - 1);
  for Frame := 0 to FrameCount - 1 do
  begin
    for Ch := 0 to Channels - 1 do
    begin
      if (Frame and $FFF) = 0 then
      begin
        Sample[Ch] := R.SignedBits(16);
        Index[Ch] := R.Bits(6);
      end
      else
      begin
        Code := R.Bits(Bits);
        Magnitude := Code and (SignBit - 1);
        Step := Steps[Index[Ch]];
        Delta := Step shr (Bits - 1);
        for Bit := 0 to Bits - 2 do
          if (Magnitude and (1 shl Bit)) <> 0 then
            Inc(Delta, Step shr (Bits - 2 - Bit));
        if (Code and SignBit) <> 0 then
          Delta := -Delta;
        Sample[Ch] := EnsureRange(Sample[Ch] + Delta, -32768, 32767);
        Index[Ch] := EnsureRange(Index[Ch] + Adjust[Bits, Magnitude], 0, High(Steps));
      end;
      Samples[Offset + Frame * Channels + Ch] := SmallInt(Sample[Ch]);
    end;
  end;
end;

function ReadMP3Frame(Stream: TStream; Decoder: TMP3Layer3Decoder; SampleRate, Channels: Integer; var Reservoir: TBytes; out Left, Right: TArray<Single>; AllowMissingHistory: Boolean = False): Boolean;
var
  Reader: TMP3BitStream;
  Header: TMP3FrameHeader;
  Side: TMP3SideInfo;
  Main, Payload, SideBytes: TBytes;
  FrameEnd: Int64;
  SideSize, MainSize, Needed, Granule, Channel: Integer;
begin
  Result := TMP3FrameParser.ParseHeader(Stream, Header);
  if not Result then
    Exit;
  FrameEnd := Stream.Position - 4 + Header.FrameSize;
  if HDR_IS_CRC(Header.hdr) then
    Stream.Seek(2, soCurrent);
  SideSize := TMP3FrameParser.SideInfoSize(Header);
  if (FrameEnd > Stream.Size) or (Stream.Position + SideSize > FrameEnd) then
    raise ESWFError.Create('Truncated SWF MP3 frame');
  if (Header.SampleRate <> SampleRate) or (Header.Channels <> Channels) then
    raise ESWFError.Create('SWF MP3 header does not match its sound format');
  SetLength(SideBytes, SideSize);
  Stream.ReadBuffer(SideBytes[0], SideSize);
  Reader := TMP3BitStream.Create(SideBytes);
  try
    if not TMP3FrameParser.ParseSideInfo(Reader, Header, Side) then
      raise ESWFError.Create('Invalid SWF MP3 side information');
  finally
    Reader.Free;
  end;
  MainSize := Integer(FrameEnd - Stream.Position);
  SetLength(Main, MainSize);
  if MainSize > 0 then
    Stream.ReadBuffer(Main[0], MainSize);
  Needed := 0;
  for Granule := 0 to Ord(HDR_TEST_MPEG1(Header.hdr)) do
    for Channel := 0 to Channels - 1 do
      Inc(Needed, Side.Granules[Granule, Channel].Part2_3_Length);
  if Needed > (Side.MainDataBegin + MainSize) * 8 then
    raise ESWFError.Create('Invalid SWF MP3 sample reservoir');
  if Side.MainDataBegin > Length(Reservoir) then
  begin
    if not AllowMissingHistory then
      raise ESWFError.Create('Invalid SWF MP3 sample reservoir');
    // A cropped event sound may begin before its bit reservoir is available.
    // Keep the sample positions and retain this frame's data for following frames.
    SetLength(Left, 576 * (1 + Ord(HDR_TEST_MPEG1(Header.hdr))));
    if Channels = 2 then
      SetLength(Right, Length(Left));
  end
  else
  begin
    Payload := Copy(Reservoir, Length(Reservoir) - Side.MainDataBegin, Side.MainDataBegin) + Main;
    SetLength(Payload, Length(Payload) + 16);
    Decoder.DecodeFrame(Header, Side, Payload, 0, Left, Right);
    if (Channels = 2) and (Length(Right) <> Length(Left)) then
      raise ESWFError.Create('Invalid SWF MP3 stereo frame');
  end;
  Reservoir := Reservoir + Main;
  if Length(Reservoir) > 511 then
    Reservoir := Copy(Reservoir, Length(Reservoir) - 511, 511);
end;

function MP3SampleToPCM(Value: Single): SmallInt;
begin
  if IsNan(Value) then
    Exit(0);
  Result := SmallInt(Round(EnsureRange(Value * 32768.0, -32768.0, 32767.0)));
end;

procedure ReadMP3(R: TSWFReader; Sound: TSWFSound);
var
  Stream: TBytesStream;
  Decoder: TMP3Layer3Decoder;
  Reservoir: TBytes;
  Left, Right: TArray<Single>;
  Index, Output, Skip: Integer;
begin
  Skip := R.U16;
  Stream := TBytesStream.Create(R.Bytes(R.Remaining));
  Decoder := nil;
  Output := 0;
  try
    Decoder := TMP3Layer3Decoder.Create;
    while (Output < Length(Sound.Samples)) and
      ReadMP3Frame(Stream, Decoder, Sound.SampleRate, Sound.Channels, Reservoir, Left, Right, True) do
    begin
      for Index := 0 to High(Left) do
      begin
        if Skip > 0 then
        begin
          Dec(Skip);
          Continue;
        end;
        if Output >= Length(Sound.Samples) then
          Break;
        Sound.Samples[Output] := MP3SampleToPCM(Left[Index]);
        Inc(Output);
        if Sound.Channels = 2 then
        begin
          Sound.Samples[Output] := MP3SampleToPCM(Right[Index]);
          Inc(Output);
        end;
      end;
    end;
    SetLength(Sound.Samples, Output);
  finally
    Decoder.Free;
    Stream.Free;
  end;
end;

function ReadSWFSound(R: TSWFReader; MaxSamples: Integer): TSWFSound;
var
  Flags, Codec, Channels: Integer;
  Frames: Cardinal;
  Sound: TSWFSound;
begin
  Flags := R.U8;
  Codec := Flags shr 4;
  Frames := R.U32;
  Channels := (Flags and 1) + 1;
  if not (Codec in [0, 1, 2, 3]) then
    raise ESWFSoundUnsupported.CreateFmt('Unsupported SWF audio format %d', [Codec]);
  if (MaxSamples < 0) or (UInt64(Frames) * Cardinal(Channels) > UInt64(MaxSamples)) then
    raise ESWFSoundLimit.Create('SWF decoded sound limit');
  Sound := TSWFSound.Create;
  try
    Sound.SampleRate := Rates[(Flags shr 2) and 3];
    Sound.Channels := Channels;
    SetLength(Sound.Samples, Integer(Frames) * Channels);
    if Frames <> 0 then
      case Codec of
        0, 3:
          ReadPCM(R, Sound.Samples, 0, Length(Sound.Samples), (Flags and 2) <> 0);
        1:
          ReadADPCM(R, Sound.Samples, 0, Frames, Channels, R.Bits(2) + 2);
        2:
          ReadMP3(R, Sound);
      end;
    Result := Sound;
  except
    Sound.Free;
    raise;
  end;
end;

function ReadSWFStreamFormat(R: TSWFReader): TSWFStreamFormat;
var
  Flags: Integer;
begin
  Result := Default(TSWFStreamFormat);
  R.U8; // Playback format is advisory. Decode using the actual stream format.
  Flags := R.U8;
  Result.Codec := Flags shr 4;
  Result.SampleRate := Rates[(Flags shr 2) and 3];
  Result.Channels := (Flags and 1) + 1;
  Result.Wide := (Flags and 2) <> 0;
  Result.AverageFrames := R.U16;
  if Result.Codec = 2 then
    Result.Latency := R.S16;
end;

constructor TSWFStreamDecoder.Create(const Format: TSWFStreamFormat; MaxSamples: Integer);
begin
  if not (Format.Codec in [0, 1, 2, 3]) then
    raise ESWFSoundUnsupported.CreateFmt('Unsupported SWF stream audio format %d', [Format.Codec]);
  inherited Create;
  FFormat := Format;
  FMaxSamples := MaxSamples;
  FSound := TSWFSound.Create;
  FSound.SampleRate := Format.SampleRate;
  FSound.Channels := Format.Channels;
  if Format.Codec = 2 then
    FMP3 := TMP3Layer3Decoder.Create;
end;

destructor TSWFStreamDecoder.Destroy;
begin
  FMP3.Free;
  FSound.Free;
  inherited;
end;

procedure TSWFStreamDecoder.Reserve(AdditionalSamples: Integer);
var
  Required: Integer;
begin
  if AdditionalSamples > FMaxSamples - FSampleCount then
    raise ESWFSoundLimit.Create('SWF decoded sound limit');
  Required := FSampleCount + AdditionalSamples;
  if Required > Length(FSound.Samples) then
    SetLength(FSound.Samples, Min(FMaxSamples, Max(Required, Max(4096, 2 * Length(FSound.Samples)))));
end;

function ADPCMStreamFrames(BlockBits, Bits: Integer; const Format: TSWFStreamFormat): Integer;
var
  PredictorBits, DeltaBits, PacketBits, TailBits, AverageBits, FullPackets: Integer;
begin
  PredictorBits := 22 * Format.Channels;
  DeltaBits := Bits * Format.Channels;
  PacketBits := PredictorBits + 4095 * DeltaBits;
  Dec(BlockBits, 2); // The code-size field precedes the first predictor.
  FullPackets := BlockBits div PacketBits;
  TailBits := BlockBits mod PacketBits;
  Result := FullPackets * 4096;
  if TailBits >= PredictorBits then
    Inc(Result, 1 + (TailBits - PredictorBits) div DeltaBits)
  else if TailBits > 7 then
    raise ESWFError.Create('Truncated SWF ADPCM stream predictor');
  if Result = 0 then
    raise ESWFError.Create('Empty SWF ADPCM stream packet');
  // In short mono packets the byte padding can look like extra deltas.
  // Use the advertised frame count when both lengths fit the same bytes.
  if (Format.AverageFrames > 0) and (Format.AverageFrames <= Result) then
  begin
    FullPackets := (Format.AverageFrames + 4095) div 4096;
    AverageBits := FullPackets * PredictorBits + (Format.AverageFrames - FullPackets) * DeltaBits;
    if BlockBits - AverageBits <= 7 then
      Result := Format.AverageFrames;
  end;
end;

function TSWFStreamDecoder.AddBlock(R: TSWFReader; FirstBlock: Boolean; out Position, DeclaredFrames: Integer): Boolean;
var
  Stream: TBytesStream;
  SampleCount, Bits, BlockBits, Checkpoint: Integer;
begin
  Position := FSampleCount div FFormat.Channels;
  DeclaredFrames := 0;
  Checkpoint := FSampleCount;
  try
    case FFormat.Codec of
      0, 3:
        begin
          SampleCount := R.Remaining div (1 + Ord(FFormat.Wide));
          if SampleCount mod FFormat.Channels <> 0 then
            raise ESWFError.Create('Unaligned SWF PCM stream block');
          Reserve(SampleCount);
          ReadPCM(R, FSound.Samples, FSampleCount, SampleCount, FFormat.Wide);
          Inc(FSampleCount, SampleCount);
        end;
      1:
        if R.Remaining > 0 then
        begin
          BlockBits := R.Remaining * 8;
          Bits := R.Bits(2) + 2;
          DeclaredFrames := ADPCMStreamFrames(BlockBits, Bits, FFormat);
          SampleCount := DeclaredFrames * FFormat.Channels;
          Reserve(SampleCount);
          ReadADPCM(R, FSound.Samples, FSampleCount, DeclaredFrames, FFormat.Channels, Bits);
          Inc(FSampleCount, SampleCount);
        end;
      2:
        begin
          DeclaredFrames := R.U16;
          Inc(Position, R.S16);
          if not FirstBlock then
            Inc(Position, FFormat.Latency);
          Stream := TBytesStream.Create(R.Bytes(R.Remaining));
          try
            AppendMP3(Stream);
            if Stream.Position <> Stream.Size then
              raise ESWFError.Create('Partial MPEG frame in SWF stream block');
          finally
            Stream.Free;
          end;
        end;
    end;
    Result := FSampleCount > Checkpoint;
  except
    FSampleCount := Checkpoint;
    raise;
  end;
end;

procedure TSWFStreamDecoder.AppendMP3(Stream: TStream);
var
  Left, Right: TArray<Single>;
  Index: Integer;
begin
  while ReadMP3Frame(Stream, FMP3, FFormat.SampleRate, FFormat.Channels,
    FReservoir, Left, Right) do
  begin
    Reserve(Length(Left) * FFormat.Channels);
    for Index := 0 to High(Left) do
    begin
      FSound.Samples[FSampleCount] := MP3SampleToPCM(Left[Index]);
      Inc(FSampleCount);
      if FFormat.Channels = 2 then
      begin
        FSound.Samples[FSampleCount] := MP3SampleToPCM(Right[Index]);
        Inc(FSampleCount);
      end;
    end;
  end;
end;

function TSWFStreamDecoder.Finish: TSWFSound;
begin
  SetLength(FSound.Samples, FSampleCount);
  Result := FSound;
  FSound := nil;
end;

function TSWFStreamDecoder.GetFrameCount: Integer;
begin
  Result := FSampleCount div FFormat.Channels;
end;

function ReadMP3File(const Data: TBytes; AudioOffset, AudioEnd, MaxSamples: Integer): TSWFSound;
var
  Stream: TBytesStream;
  Decoder: TSWFStreamDecoder;
  Header: TMP3FrameHeader;
  Format: TSWFStreamFormat;
begin
  if (AudioOffset < 0) or (AudioEnd > Length(Data)) or (AudioEnd <= AudioOffset) then
    raise ESWFError.Create('MP3 has no audio payload');
  if (AudioOffset = 0) and (AudioEnd = Length(Data)) then
    Stream := TBytesStream.Create(Data)
  else
    Stream := TBytesStream.Create(Copy(Data, AudioOffset, AudioEnd - AudioOffset));
  try
    if not TMP3FrameParser.ParseHeader(Stream, Header) then
      raise ESWFError.Create('No MPEG Layer III frame found');
    Stream.Position := Stream.Position - 4;
    Format := Default(TSWFStreamFormat);
    Format.Codec := 2;
    Format.SampleRate := Header.SampleRate;
    Format.Channels := Header.Channels;
    Decoder := TSWFStreamDecoder.Create(Format, MaxSamples);
    try
      Decoder.AppendMP3(Stream);
      if Decoder.FrameCount = 0 then
        raise ESWFError.Create('MP3 has no decoded samples');
      Result := Decoder.Finish;
    finally
      Decoder.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function ReadSWFSoundEvent(R: TSWFReader): TSWFSoundEvent;
var
  Flags, I: Integer;
begin
  Result := Default(TSWFSoundEvent);
  Result.Id := R.U16;
  if Result.Id = 0 then
    Exit;
  Flags := R.U8;
  Result.Info.Stop := (Flags and $20) <> 0;
  Result.Info.NoMultiple := (Flags and $10) <> 0;
  if (Flags and 1) <> 0 then
    Result.Info.First := R.U32;
  Result.Info.HasEnd := (Flags and 2) <> 0;
  if Result.Info.HasEnd then
    Result.Info.Last := R.U32;
  Result.Info.Loops := 1;
  if (Flags and 4) <> 0 then
    Result.Info.Loops := R.U16;
  if (Flags and 8) <> 0 then
  begin
    SetLength(Result.Info.Envelope, R.U8);
    for I := 0 to High(Result.Info.Envelope) do
    begin
      Result.Info.Envelope[I].Position := R.U32;
      Result.Info.Envelope[I].LeftGain := R.U16;
      Result.Info.Envelope[I].RightGain := R.U16;
    end;
  end;
end;

end.

