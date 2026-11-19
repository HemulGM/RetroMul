unit Audio.Format.ATRAC;

interface

uses
  System.SysUtils, Audio.Types;

function OpenATRAC(const Data: TBytes): IAudioSource;

function OpenWaveAudio(const Data: TBytes): IAudioSource;

implementation

uses
  System.Math, Audio.Binary, Audio.Decoder, Audio.ATRAC3, Audio.ATRAC3Plus,
  Audio.Format.WAV;

const
  ATRAC3PlusGuid: TGUID = '{E923AABF-CB58-4471-A119-FFFA01E4CE62}';

type
  TATRACConfig = record
    Plus, Joint: Boolean;
    Channels, DecoderChannels, Rate, BlockSize, DataOffset, DataSize: Integer;
    InitialFrame, FrameCount: Int64;
  end;

  TATRACSource = class(TAudioMusicSource)
  private
    FData: TBytes;
    FConfig: TATRACConfig;
    FATRAC3: TATRAC3Decoder;
    FATRAC3Plus: TATRAC3PlusDecoder;
    FBlock: TArray<SmallInt>;
    FOffset, FRead: Integer;
    FSkip, FRemaining: Int64;
    procedure DecodeBlock;
  public
    constructor Create(const Data: TBytes; const Config: TATRACConfig);
    destructor Destroy; override;
    function GetInfo: TAudioInfo; override;
    procedure SelectTrack(Index: Integer); override;
    function Render(var Samples: array of SmallInt; Frames: Integer): Integer; override;
  end;

function BlockFrames(const Config: TATRACConfig): Integer;
begin
  if Config.Plus then
    Exit(2048);
  Result := 1024;
end;

procedure CompleteConfig(var Config: TATRACConfig; FactFrames, FactOffset: Int64);
begin
  if not (Config.Channels in [1, 2]) or (Config.Rate < 8000) or (Config.Rate > 96000) or
    (Config.BlockSize < 8) or (Config.BlockSize > 4096) then
    raise ENotSupportedException.Create('Unsupported ATRAC stream configuration');
  if (Config.DataSize < Config.BlockSize) or (Config.DataSize mod Config.BlockSize <> 0) then
    raise EArgumentException.Create('Truncated ATRAC packet data');

  Config.DecoderChannels := Config.Channels;
  // PSP ATRAC3 can label the mono 0x98/0xC0 non-joint modes as stereo.
  if not Config.Plus and not Config.Joint and (Config.BlockSize in [$98, $C0]) then
    Config.DecoderChannels := 1;

  // PSP files include a priming block and the codec delay. A standalone
  // WAVE with only a sample count can instead describe the full decoded span.
  var Total := Int64(Config.DataSize div Config.BlockSize) * BlockFrames(Config);
  if FactOffset >= 0 then
  begin
    if FactOffset = 0 then
      FactOffset := BlockFrames(Config);
    if Config.Plus then
      Inc(FactOffset, $170)
    else
      Inc(FactOffset, $45);
    Config.InitialFrame := FactOffset;
  end;
  Config.FrameCount := Total - Config.InitialFrame;
  if FactFrames > 0 then
    Config.FrameCount := FactFrames;
  if (Config.FrameCount <= 0) or (Config.InitialFrame + Config.FrameCount > Total) then
    raise EArgumentException.Create('Invalid ATRAC sample count or delay');
end;

function ReadWave(const Data: TBytes; out Config: TATRACConfig): Boolean;
const
  RIFF = $46464952;
  WAVE = $45564157;
  FMT = $20746D66;
  FACT = $74636166;
  DATA_ID = $61746164;
var
  Offset, Limit, Size, Body: Integer;
  FactFrames, FactOffset: Int64;
  FoundFormat: Boolean;
begin
  Result := False;
  Config := Default(TATRACConfig);
  if (Length(Data) < 12) or (LE32(Data, 0) <> RIFF) or (LE32(Data, 8) <> WAVE) then
    Exit;
  if LE32(Data, 4) > Cardinal(Length(Data) - 8) then
    Exit;
  Limit := Integer(LE32(Data, 4)) + 8;
  Offset := 12;
  FactFrames := -1;
  FactOffset := -1;
  FoundFormat := False;
  while Limit - Offset >= 8 do
  begin
    Body := Offset + 8;
    if LE32(Data, Offset + 4) > Cardinal(Limit - Body) then
    begin
      if not FoundFormat then
        Exit;
      raise EArgumentException.Create('Truncated WAVE chunk');
    end;
    Size := Integer(LE32(Data, Offset + 4));
    case LE32(Data, Offset) of
      FMT:
        if not FoundFormat then
        begin
          if Size < 16 then
            Exit;
          case LE16(Data, Body) of
            $0270:
              begin
                if Size < 32 then
                  raise EArgumentException.Create('Truncated ATRAC3 WAVE format');
                Config.Joint := LE16(Data, Body + 24) <> 0;
              end;
            $FFFE:
              begin
                if (Size < 40) or not CompareMem(@Data[Body + 24], @ATRAC3PlusGuid, SizeOf(TGUID)) then
                  Exit;
                Config.Plus := True;
              end;
          else
            Exit;
          end;
          Config.Channels := LE16(Data, Body + 2);
          if LE32(Data, Body + 4) > Cardinal(High(Integer)) then
            raise EArgumentException.Create('Invalid ATRAC rate');
          Config.Rate := Integer(LE32(Data, Body + 4));
          Config.BlockSize := LE16(Data, Body + 12);
          FoundFormat := True;
        end;
      FACT:
        begin
          if Size >= 4 then
            FactFrames := LE32(Data, Body);
          if Size >= 8 then
            FactOffset := LE32(Data, Body + 4);
        end;
      DATA_ID:
        if Config.DataOffset = 0 then
        begin
          Config.DataOffset := Body;
          Config.DataSize := Size;
        end;
    end;
    Offset := Body + Size;
    if Odd(Size) and (Offset < Limit) then
      Inc(Offset);
    if FoundFormat and (Config.DataOffset <> 0) then
      Break;
  end;
  if not FoundFormat then
    Exit;
  if Config.DataOffset = 0 then
    raise EArgumentException.Create('ATRAC data chunk is missing');
  CompleteConfig(Config, FactFrames, FactOffset);
  Result := True;
end;

function ReadOMA(const Data: TBytes): TATRACConfig;
const
  Rates: array[0..7] of Integer = (32000, 44100, 48000, 88200, 96000, 0, 0, 0);
var
  Offset, Params, Encryption: Integer;
begin
  Result := Default(TATRACConfig);
  RequireBytes(Data, 0, 10);
  Offset := 0;
  if (Data[0] = Ord('e')) and (Data[1] = Ord('a')) and (Data[2] = Ord('3')) then
  begin
    for var I := 6 to 9 do
    begin
      if Data[I] >= 128 then
        raise EArgumentException.Create('Invalid OMA tag size');
      Offset := (Offset shl 7) or Data[I];
    end;
    Inc(Offset, 10);
    if (Data[5] and $10) <> 0 then
      Inc(Offset, 10);
  end;
  RequireBytes(Data, Offset, 96);
  if (Data[Offset] <> Ord('E')) or (Data[Offset + 1] <> Ord('A')) or
    (Data[Offset + 2] <> Ord('3')) or (Data[Offset + 4] <> 0) or (Data[Offset + 5] <> 96) then
    raise EArgumentException.Create('Invalid ATRAC EA3 header');
  Encryption := (Integer(Data[Offset + 6]) shl 8) or Data[Offset + 7];
  if (Encryption <> $FFFF) and (Encryption <> $FF80) then
    raise ENotSupportedException.Create('Encrypted OMA is unsupported');
  Params := (Integer(Data[Offset + 33]) shl 16) or
    (Integer(Data[Offset + 34]) shl 8) or Data[Offset + 35];
  Result.Rate := Rates[(Params shr 13) and 7];
  Result.BlockSize := (Params and $3FF) * 8;
  case Data[Offset + 32] of
    0:
      begin
        Result.Channels := 2;
        Result.Joint := (Params and $20000) <> 0;
        if not Result.Joint and (Result.BlockSize in [$98, $C0]) then
          Result.Channels := 1;
      end;
    1:
      begin
        Result.Plus := True;
        Result.Channels := (Params shr 10) and 7;
        Inc(Result.BlockSize, 8);
      end;
  else
    raise ENotSupportedException.Create('OMA requires ATRAC3 or ATRAC3plus audio');
  end;
  Result.DataOffset := Offset + 96;
  Result.DataSize := Length(Data) - Result.DataOffset;
  CompleteConfig(Result, -1, 0);
end;

constructor TATRACSource.Create(const Data: TBytes; const Config: TATRACConfig);
begin
  inherited Create;
  FData := Data;
  FConfig := Config;
  if Config.Plus then
    FATRAC3Plus := TATRAC3PlusDecoder.Create(Config.Channels, Config.Channels)
  else
    FATRAC3 := TATRAC3Decoder.Create(Config.BlockSize, Config.DecoderChannels,
      Config.Channels, Ord(Config.Joint));
  FOffset := Config.DataOffset;
  FSkip := Config.InitialFrame;
  FRemaining := Config.FrameCount;
end;

destructor TATRACSource.Destroy;
begin
  FATRAC3.Free;
  FATRAC3Plus.Free;
  inherited;
end;

function TATRACSource.GetInfo: TAudioInfo;
begin
  Result := Default(TAudioInfo);
  Result.SampleRate := FConfig.Rate;
  Result.Channels := FConfig.Channels;
  Result.TrackCount := 1;
  Result.FormatName := 'ATRAC3';
  if FConfig.Plus then
    Result.FormatName := 'ATRAC3plus';
  Result.TrackDurations := [FConfig.FrameCount / FConfig.Rate];
end;

procedure TATRACSource.SelectTrack(Index: Integer);
begin
  if Index <> 0 then
    raise EArgumentOutOfRangeException.Create('ATRAC track index');
  if FATRAC3Plus <> nil then
    FATRAC3Plus.Reset
  else
    FATRAC3.Reset;
  FOffset := FConfig.DataOffset;
  FRead := 0;
  FBlock := nil;
  FSkip := FConfig.InitialFrame;
  FRemaining := FConfig.FrameCount;
end;

procedure TATRACSource.DecodeBlock;
begin
  var Packet := Copy(FData, FOffset, FConfig.BlockSize);
  if FATRAC3Plus <> nil then
    FBlock := FATRAC3Plus.Decode(Packet)
  else
    FBlock := FATRAC3.Decode(Packet);
  Inc(FOffset, FConfig.BlockSize);
  var Skip := Integer(Min(FSkip, Int64(BlockFrames(FConfig))));
  FRead := Skip * FConfig.Channels;
  Dec(FSkip, Skip);
end;

function TATRACSource.Render(var Samples: array of SmallInt; Frames: Integer): Integer;
begin
  ValidateRender(Length(Samples), Frames, FConfig.Channels);
  Result := 0;
  Frames := Integer(Min(Int64(Frames), FRemaining));
  while Result < Frames do
  begin
    if FRead = Length(FBlock) then
    begin
      DecodeBlock;
      Continue;
    end;
    var Count := Min(Frames - Result, (Length(FBlock) - FRead) div FConfig.Channels);
    Move(FBlock[FRead], Samples[Result * FConfig.Channels], Count * FConfig.Channels * SizeOf(SmallInt));
    Inc(FRead, Count * FConfig.Channels);
    Inc(Result, Count);
    Dec(FRemaining, Count);
  end;
end;

function OpenATRAC(const Data: TBytes): IAudioSource;
begin
  var Config: TATRACConfig;
  if not ReadWave(Data, Config) then
    Config := ReadOMA(Data);
  Result := TATRACSource.Create(Data, Config);
end;

function OpenWaveAudio(const Data: TBytes): IAudioSource;
begin
  var Config: TATRACConfig;
  if ReadWave(Data, Config) then
    Result := TATRACSource.Create(Data, Config)
  else
    Result := OpenWav(Data);
end;

end.

