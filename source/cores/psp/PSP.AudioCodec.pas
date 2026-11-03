unit PSP.AudioCodec;

// sceAudiocodec: the Media Engine's frame decoders driven through a 128-byte
// context the caller owns. CheckNeedMem, GetEDRAM and Init fill the context
// the way avcodec.prx does; Decode takes one frame from inBuf and writes PCM
// to outBuf. ATRAC3 is set up by a parameter index, ATRAC3+ by the two format
// bytes of its RIFF header, MP3 from each frame header, AAC by sample rate.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.Scheduler, PSP.Service, Audio.ATRAC3,
  Audio.ATRAC3Plus, FMXAudio.Types, FMXAudio.AAC, PSP.MP3;

type
  TPSPAudioCodecState = class
  public
    Codec: Integer;
    At3: TATRAC3Decoder;
    At3Param: Integer;
    At3Plus: TATRAC3PlusDecoder;
    At3PlusChannels: Integer;
    Aac: TAACDecoder;
    AacIntf: IAudioDecoder;
    Mp3: TPSPMp3FrameDecoder;
    Frames: Integer;
    destructor Destroy; override;
  end;

  TPSPAudioCodec = class(TPSPService)
  private
    FScheduler: TPSPScheduler;
    FStates: TObjectDictionary<Cardinal, TPSPAudioCodecState>;
    function R32(Ctx, Off: Cardinal): Cardinal; inline;
    procedure W32(Ctx, Off, Value: Cardinal); inline;
    procedure ShortWait(Result: Cardinal);
    function State(Ctx: Cardinal; Codec: Integer): TPSPAudioCodecState;
    procedure Fail(Ctx, Err: Cardinal);
    function At3PlusCheck(Ctx: Cardinal; WriteFields: Boolean): Cardinal;
    function InitAt3Plus(Ctx: Cardinal; Mono: Boolean): Cardinal;
    function InitAt3(Ctx: Cardinal; Mono: Boolean): Cardinal;
    function DecodeAt3(Ctx: Cardinal): Cardinal;
    function DecodeAt3Plus(Ctx: Cardinal): Cardinal;
    function DecodeMp3(Ctx: Cardinal): Cardinal;
    function DecodeAac(Ctx: Cardinal): Cardinal;
    function ReadMp3Header(Ctx, Address: Cardinal; out Info: TPSPMp3Header): Boolean;
    procedure hCheckNeedMem;
    procedure hGetEDRAM;
    procedure hReleaseEDRAM;
    procedure hInit;
    procedure hInitMono;
    procedure hDecode;
    procedure hGetInfo;
    procedure hGetBlockSize;
  public
    constructor Create(System: TPSPSystem); override;
    destructor Destroy; override;
    procedure Reset; override;
    procedure Register; override;
  end;

// ATRAC3 codec parameters: whole frame bytes, channels and joint stereo.
function PSPAtrac3Param(Param: Integer; out FrameBytes, Channels: Integer; out Joint: Boolean): Boolean;
// The parameter libatrac3plus picks for a frame size and joint stereo flag.

function PSPAtrac3ParamFor(FrameBytes: Integer; Joint: Boolean; Channels: Integer): Integer;

implementation

uses
  System.Math;

const
  CODEC_AT3PLUS = $1000;
  CODEC_AT3 = $1001;
  CODEC_MP3 = $1002;
  CODEC_AAC = $1003;
  ERROR_AVCODEC_INVALID_DATA = Cardinal($807F00FD);
  ERROR_AVCODEC_INVALID_PARAM = Cardinal($807F00FF);
  SCE_ERROR_NOT_SUPPORTED_4 = Cardinal($80000004);
  CodecMagic = $05100601;
  EdramAddr = $0018EAC0;
  EdramAddr2 = $0018EA90;

  // Off: the per-codec part of the context.
  OffMagic = $00;
  OffErr = $08;
  OffEdram = $0C;
  OffNeededMem = $10;
  OffInited = $14;
  OffInBuf = $18;
  OffRead = $1C;
  OffOutBuf = $20;
  OffWritten = $24;
  OffEdram2 = $68;
  At3PlusNeededMem: array[1..7] of Cardinal = ($4340, $7BC0, $BE40, $100C0, $17BC0, $1BE40, $1F6C0);
  At3PlusOutChannels: array[1..7] of Integer = (1, 2, 3, 4, 6, 7, 8);
  At3PlusRates: array[0..2] of Integer = (32000, 44100, 48000);

type
  TAt3ParamEntry = record
    Bytes, Channels: Integer;
    Joint: Boolean;
  end;

const
  At3Params: array[0..15] of TAt3ParamEntry = (
    (Bytes: $200; Channels: 2; Joint: False), (Bytes: $1E0; Channels: 2; Joint: False),
    (Bytes: $1C0; Channels: 2; Joint: False), (Bytes: $1A8; Channels: 2; Joint: False),
    (Bytes: $180; Channels: 2; Joint: False), (Bytes: $160; Channels: 2; Joint: False),
    (Bytes: $130; Channels: 2; Joint: False), (Bytes: $120; Channels: 2; Joint: False),
    (Bytes: $118; Channels: 2; Joint: False), (Bytes: $110; Channels: 2; Joint: True),
    (Bytes: $E8; Channels: 2; Joint: True), (Bytes: $C0; Channels: 2; Joint: True),
    (Bytes: $88; Channels: 2; Joint: True), (Bytes: $60; Channels: 2; Joint: True),
    (Bytes: $C0; Channels: 1; Joint: False), (Bytes: $98; Channels: 1; Joint: False));
  AacRates: array[0..10] of Integer = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 11025, 8000);
  AacRateIndex: array[0..10] of Integer = (0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11);

function PSPAtrac3Param(Param: Integer; out FrameBytes, Channels: Integer; out Joint: Boolean): Boolean;
begin
  Result := (Param >= 0) and (Param <= High(At3Params));
  if not Result then
  begin
    FrameBytes := 0;
    Channels := 0;
    Joint := False;
    Exit;
  end;
  FrameBytes := At3Params[Param].Bytes;
  Channels := At3Params[Param].Channels;
  Joint := At3Params[Param].Joint;
end;

function PSPAtrac3ParamFor(FrameBytes: Integer; Joint: Boolean; Channels: Integer): Integer;
begin
  // The frame size and joint stereo decide; the header's channel count does not.
  for var I := 0 to High(At3Params) do
    if (At3Params[I].Bytes = FrameBytes) and (At3Params[I].Joint = Joint) and (At3Params[I].Channels = 2) and Joint then
      Exit(I);
  if not Joint then
  begin
    for var I := High(At3Params) downto 0 do
      if (At3Params[I].Bytes = FrameBytes) and not At3Params[I].Joint and (At3Params[I].Channels = 1) then
        Exit(I);
    for var I := 0 to High(At3Params) do
      if (At3Params[I].Bytes = FrameBytes) and not At3Params[I].Joint then
        Exit(I);
  end;
  Result := -1;
end;

{ TPSPAudioCodecState }

destructor TPSPAudioCodecState.Destroy;
begin
  At3.Free;
  At3Plus.Free;
  AacIntf := nil;
  Mp3.Free;
  inherited;
end;

{ TPSPAudioCodec }

constructor TPSPAudioCodec.Create(System: TPSPSystem);
begin
  inherited Create(System);
  FScheduler := System.Scheduler;
  FStates := TObjectDictionary<Cardinal, TPSPAudioCodecState>.Create([doOwnsValues]);
end;

destructor TPSPAudioCodec.Destroy;
begin
  FStates.Free;
  inherited;
end;

procedure TPSPAudioCodec.Reset;
begin
  FStates.Clear;
end;

function TPSPAudioCodec.R32(Ctx, Off: Cardinal): Cardinal;
begin
  Result := FMemory.Read32(Ctx + Off);
end;

procedure TPSPAudioCodec.W32(Ctx, Off, Value: Cardinal);
begin
  FMemory.Write32(Ctx + Off, Value);
end;

procedure TPSPAudioCodec.ShortWait(Result: Cardinal);
begin
  FHLE.Result(Result);
  if not FKernel.CanWait then
    Exit;
  var T := FKernel.Current;
  FKernel.BeginWait(PSPWaitDelay, nil, 0, 0, False, nil, nil, 'audiocodec');
  FKernel.AddWakeTimer(FScheduler.Now + 60000, T, 'audiocodec', Result);
end;

function TPSPAudioCodec.State(Ctx: Cardinal; Codec: Integer): TPSPAudioCodecState;
begin
  if not FStates.TryGetValue(Ctx, Result) or (Result.Codec <> Codec) then
  begin
    Result := TPSPAudioCodecState.Create;
    Result.Codec := Codec;
    FStates.AddOrSetValue(Ctx, Result);
  end;
end;

procedure TPSPAudioCodec.Fail(Ctx, Err: Cardinal);
begin
  W32(Ctx, OffErr, Err);
  W32(Ctx, OffRead, 0);
  W32(Ctx, OffWritten, 0);
end;

function TPSPAudioCodec.At3PlusCheck(Ctx: Cardinal; WriteFields: Boolean): Cardinal;
begin
  var B1 := FMemory.Read8(Ctx + $28);
  var B2 := FMemory.Read8(Ctx + $29);
  var Config := (B1 shr 2) and 7;
  var RateIndex := B1 shr 5;
  if WriteFields and (Config <> 0) then
    W32(Ctx, $3C, Config);
  if RateIndex > 2 then
    Exit(ERROR_AVCODEC_INVALID_DATA);
  if WriteFields then
  begin
    W32(Ctx, $34, At3PlusRates[RateIndex]);
    W32(Ctx, $40, (((B1 and 3) shl 8) or B2) * 8 + 8);
  end;
  if Config = 0 then
  begin
    W32(Ctx, OffErr, $20F);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  if WriteFields then
    W32(Ctx, OffNeededMem, At3PlusNeededMem[Config]);
  Result := 0;
end;

function TPSPAudioCodec.InitAt3Plus(Ctx: Cardinal; Mono: Boolean): Cardinal;
begin
  var B1 := FMemory.Read8(Ctx + $28);
  var B2 := FMemory.Read8(Ctx + $29);
  var Config := (B1 shr 2) and 7;
  var RateIndex := B1 shr 5;
  if RateIndex > 2 then
    Exit(ERROR_AVCODEC_INVALID_DATA);
  if Mono and (Config <> 1) then
    Exit(ERROR_AVCODEC_INVALID_PARAM);
  if Config = 0 then
  begin
    W32(Ctx, OffErr, $202);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  // Init asks for stereo out of a mono stream; InitMono for mono.
  var OutCh := At3PlusOutChannels[Config];
  if (Config = 1) and not Mono then
    OutCh := 2;
  W32(Ctx, $48, OutCh);
  if RateIndex = 0 then
  begin
    W32(Ctx, OffErr, $201);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  var Size := (((B1 and 3) shl 8) or B2) * 8 + 8;
  if Size > $1000 then
  begin
    W32(Ctx, OffErr, $203);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  W32(Ctx, $44, Cardinal(Int64(Size) * 8 * At3PlusRates[RateIndex] div 2048000));
  if R32(Ctx, OffInited) <> 1 then
  begin
    W32(Ctx, OffErr, $8001);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  var S := State(Ctx, CODEC_AT3PLUS);
  FreeAndNil(S.At3Plus);
  S.At3PlusChannels := Min(At3PlusOutChannels[Config], 2);
  try
    S.At3Plus := TATRAC3PlusDecoder.Create(S.At3PlusChannels, 2);
  except
    S.At3Plus := nil;
  end;
  S.Frames := 0;
  Result := 0;
end;

function TPSPAudioCodec.InitAt3(Ctx: Cardinal; Mono: Boolean): Cardinal;
begin
  var Param := Integer(R32(Ctx, $28));
  var Bytes, Channels: Integer;
  var Joint: Boolean;
  if not PSPAtrac3Param(Param, Bytes, Channels, Joint) then
  begin
    if Mono then
      Exit(ERROR_AVCODEC_INVALID_PARAM);
    W32(Ctx, OffErr, $186);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  if Mono and (Channels <> 1) then
    Exit(ERROR_AVCODEC_INVALID_PARAM);
  W32(Ctx, $2C, 44100);
  W32(Ctx, $30, Cardinal(Bytes div Channels));
  if Channels = 1 then
  begin
    if Mono then
      W32(Ctx, $34, 1)
    else
      W32(Ctx, $34, 2);
  end;
  var S := State(Ctx, CODEC_AT3);
  FreeAndNil(S.At3);
  S.At3Param := Param;
  try
    S.At3 := TATRAC3Decoder.Create(Bytes, Channels, 2, Ord(Joint));
  except
    S.At3 := nil;
  end;
  S.Frames := 0;
  Result := 0;
end;

function TPSPAudioCodec.DecodeAt3(Ctx: Cardinal): Cardinal;
begin
  var S := State(Ctx, CODEC_AT3);
  var Bytes, Channels: Integer;
  var Joint: Boolean;
  if not PSPAtrac3Param(S.At3Param, Bytes, Channels, Joint) or (S.At3 = nil) then
  begin
    Fail(Ctx, $186);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  var Frame: TBytes;
  SetLength(Frame, Bytes);
  FMemory.ReadBytes(R32(Ctx, OffInBuf), Frame[0], Bytes);
  // Each channel's sound unit starts with its id (joint stereo's second one
  // is stored reversed at the end of the frame; the decoder checks it).
  var Err: Cardinal := 0;
  if (Frame[0] and $FC) <> $A0 then
    Err := $182
  else if (Channels = 2) and not Joint and ((Frame[Bytes div 2] and $FC) <> $A0) then
    Err := $182;
  var PCM: TArray<SmallInt>;
  if Err = 0 then
  try
    PCM := S.At3.Decode(Frame);
  except
      // Past the first unit's id, a joint stereo frame fails on its second unit.
    if Joint then
      Err := $183
    else
      Err := $182;
    S.At3.Reset;
  end;
  if Err <> 0 then
  begin
    Fail(Ctx, Err);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  var OutCh := 2;
  if (Channels = 1) and (R32(Ctx, $34) <> 2) then
    OutCh := 1;
  var out := R32(Ctx, OffOutBuf);
  if OutCh = 2 then
    FMemory.WriteBytes(out, PCM[0], 1024 * 4)
  else
    for var I := 0 to 1023 do
      FMemory.Write16(out + Cardinal(I) * 2, Word(PCM[I * 2]));
  W32(Ctx, OffErr, 0);
  W32(Ctx, OffRead, Cardinal(Bytes));
  W32(Ctx, OffWritten, Cardinal(1024 * 2 * OutCh));
  Result := 0;
end;

function TPSPAudioCodec.DecodeAt3Plus(Ctx: Cardinal): Cardinal;
begin
  var S := State(Ctx, CODEC_AT3PLUS);
  var In_ := R32(Ctx, OffInBuf);
  var B1 := FMemory.Read8(Ctx + $28);
  var B2 := FMemory.Read8(Ctx + $29);
  var Header := 0;
  if R32(Ctx, $30) <> 0 then
  begin
    // Frames carry an 8-byte header (0F D0 and the format bytes), as PSMF streams do.
    if (FMemory.Read8(In_) <> $0F) or (FMemory.Read8(In_ + 1) <> $D0) then
    begin
      Fail(Ctx, $211);
      Exit(ERROR_AVCODEC_INVALID_DATA);
    end;
    B1 := FMemory.Read8(In_ + 2);
    B2 := FMemory.Read8(In_ + 3);
    if ((B1 shr 2) and 7) = 0 then
    begin
      Fail(Ctx, $213);
      Exit(ERROR_AVCODEC_INVALID_DATA);
    end;
    Header := 8;
  end;
  var Size := (((B1 and 3) shl 8) or B2) * 8 + 8;
  var Frame: TBytes;
  SetLength(Frame, Size);
  FMemory.ReadBytes(In_ + Cardinal(Header), Frame[0], Size);
  var PCM: TArray<SmallInt>;
  var Ok := S.At3Plus <> nil;
  if Ok then
  try
    PCM := S.At3Plus.Decode(Frame);
  except
    Ok := False;
  end;
  if not Ok then
  begin
    Fail(Ctx, $20A);
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  W32(Ctx, OffErr, 0);
  W32(Ctx, OffRead, Cardinal(Size) + Cardinal(Header));
  Inc(S.Frames);
  // The first frame decoded only primes the overlap: nothing comes out.
  if S.Frames = 1 then
  begin
    W32(Ctx, OffWritten, 0);
    Exit(0);
  end;
  var OutCh := Integer(R32(Ctx, $48));
  var out := R32(Ctx, OffOutBuf);
  if OutCh = 1 then
  begin
    for var I := 0 to 2047 do
      FMemory.Write16(out + Cardinal(I) * 2, Word(SmallInt((Integer(PCM[I * 2]) + PCM[I * 2 + 1]) div 2)));
    W32(Ctx, OffWritten, 2048 * 2);
  end
  else
  begin
    FMemory.WriteBytes(out, PCM[0], 2048 * 4);
    W32(Ctx, OffWritten, 2048 * 4);
  end;
  Result := 0;
end;

function TPSPAudioCodec.ReadMp3Header(Ctx, Address: Cardinal; out Info: TPSPMp3Header): Boolean;
begin
  var H: array[0..3] of Byte;
  FMemory.ReadBytes(Address, H, 4);
  Result := PSPMp3ParseHeader(H, Info);
  if not Result then
    Exit;
  var Version := (H[1] shr 3) and 3;
  case Version of
    3:
      W32(Ctx, $38, 1);
    2:
      W32(Ctx, $38, 0);
  else
    W32(Ctx, $38, 2);
  end;
  W32(Ctx, $3C, 4 - ((H[1] shr 1) and 3));
  W32(Ctx, $40, Ord((H[1] and 1) = 0));
  W32(Ctx, $44, H[2] shr 4);
  W32(Ctx, $48, (H[2] shr 2) and 3);
  W32(Ctx, $4C, (H[2] shr 1) and 1);
  W32(Ctx, $50, H[2] and 1);
  W32(Ctx, $54, H[3] shr 6);
  W32(Ctx, $58, (H[3] shr 4) and 3);
  W32(Ctx, $5C, (H[3] shr 3) and 1);
  W32(Ctx, $60, (H[3] shr 2) and 1);
  W32(Ctx, $64, H[3] and 3);
end;

function TPSPAudioCodec.DecodeMp3(Ctx: Cardinal): Cardinal;
begin
  var S := State(Ctx, CODEC_MP3);
  if S.Mp3 = nil then
    S.Mp3 := TPSPMp3FrameDecoder.Create;
  var In_ := R32(Ctx, OffInBuf);
  var Info: TPSPMp3Header;
  if not ReadMp3Header(Ctx, In_, Info) then
  begin
    Fail(Ctx, Cardinal(-2));
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  var Frame: TBytes;
  SetLength(Frame, Info.FrameSize);
  FMemory.ReadBytes(In_, Frame[0], Info.FrameSize);
  var PCM: TArray<SmallInt>;
  var Channels: Integer;
  var Samples := S.Mp3.Decode(Frame, PCM, Channels);
  if Samples = 0 then
  begin
    Samples := Info.SamplesPerFrame;
    SetLength(PCM, Samples * 2);
  end;
  FMemory.WriteBytes(R32(Ctx, OffOutBuf), PCM[0], Samples * 4);
  W32(Ctx, OffErr, 0);
  W32(Ctx, OffRead, Cardinal(Info.FrameSize));
  W32(Ctx, OffWritten, Cardinal(Samples * 4));
  W32(Ctx, $30, Cardinal(Info.Channels));
  if Info.Version = 3 then
    W32(Ctx, $34, 2)
  else
    W32(Ctx, $34, 1);
  Result := 0;
end;

function TPSPAudioCodec.DecodeAac(Ctx: Cardinal): Cardinal;
begin
  var S := State(Ctx, CODEC_AAC);
  var In_ := R32(Ctx, OffInBuf);
  // The access unit's length is not given: the decoder finds where it ends.
  var Data: TBytes;
  SetLength(Data, $2000);
  FMemory.ReadBytes(In_, Data[0], Length(Data));
  if S.AacIntf = nil then
  begin
    var Rate := Integer(R32(Ctx, $28));
    var Index := 4;
    for var I := 0 to High(AacRates) do
      if AacRates[I] = Rate then
        Index := AacRateIndex[I];
    S.Aac := TAACDecoder.Create;
    S.AacIntf := S.Aac;
    var Track := Default(TTrackInfo);
    Track.Kind := TTrackKind.Audio;
    Track.Codec := 'mp4a';
    Track.SampleRate := Rate;
    Track.TimeScale := Rate;
    Track.Channels := 2;
    Track.CodecConfig := TBytes.Create((2 shl 3) or (Index shr 1), ((Index and 1) shl 7) or (2 shl 3));
    try
      S.Aac.Configure(Track);
    except
      Fail(Ctx, $FFFF);
      Exit(ERROR_AVCODEC_INVALID_DATA);
    end;
  end;
  var Packet := Default(TMediaPacket);
  Packet.Data := Data;
  Packet.SourceTimeScale := Cardinal(Max(1, Integer(R32(Ctx, $28))));
  var Frame: TAudioFrame;
  var Got: Boolean;
  var Consumed: Integer;
  try
    S.Aac.Send(Packet);
    Consumed := S.Aac.PacketBytesConsumed;
    Got := S.Aac.Receive(Frame);
  except
    Fail(Ctx, $FFFF);
    S.AacIntf := nil;
    S.Aac := nil;
    Exit(ERROR_AVCODEC_INVALID_DATA);
  end;
  W32(Ctx, OffErr, 0);
  W32(Ctx, OffRead, Cardinal(Consumed));
  Inc(S.Frames);
  // The first two access units fill the decoder's delay.
  if not Got or (S.Frames <= 2) then
  begin
    W32(Ctx, OffWritten, 0);
    Exit(0);
  end;
  var out := R32(Ctx, OffOutBuf);
  var N := Min(Frame.Frames, 1024);
  for var I := 0 to N - 1 do
  begin
    var L := Frame.Samples[I * Frame.Channels];
    var R := L;
    if Frame.Channels > 1 then
      R := Frame.Samples[I * Frame.Channels + 1];
    FMemory.Write16(out + Cardinal(I) * 4, Word(L));
    FMemory.Write16(out + Cardinal(I) * 4 + 2, Word(R));
  end;
  W32(Ctx, OffWritten, Cardinal(N * 4));
  Result := 0;
end;

{ HLE }

procedure TPSPAudioCodec.hCheckNeedMem;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  case Codec of
    CODEC_AT3PLUS:
      begin
        W32(Ctx, OffMagic, CodecMagic);
        ShortWait(At3PlusCheck(Ctx, True));
      end;
    CODEC_AT3:
      begin
        W32(Ctx, OffMagic, CodecMagic);
        W32(Ctx, OffNeededMem, $3DE0);
        ShortWait(0);
      end;
    CODEC_MP3:
      begin
        W32(Ctx, OffMagic, CodecMagic);
        W32(Ctx, OffNeededMem, $3B68);
        ShortWait(0);
      end;
    CODEC_AAC:
      begin
        W32(Ctx, OffMagic, CodecMagic);
        W32(Ctx, OffNeededMem, $658C);
        ShortWait(0);
      end;
    $1004:
      FHLE.Result(ERROR_AVCODEC_INVALID_PARAM);
    $1005:
      begin
        W32(Ctx, OffNeededMem, $80000003);
        FHLE.Result(0);
      end;
  else
    FHLE.Result(SCE_ERROR_NOT_SUPPORTED_4);
  end;
end;

procedure TPSPAudioCodec.hGetEDRAM;
begin
  var Ctx := FHLE.Arg(0);
  W32(Ctx, OffEdram, EdramAddr);
  W32(Ctx, OffEdram2, EdramAddr2);
  ShortWait(0);
end;

procedure TPSPAudioCodec.hReleaseEDRAM;
begin
  var Ctx := FHLE.Arg(0);
  W32(Ctx, OffEdram, 0);
  W32(Ctx, OffEdram2, 0);
  FStates.Remove(Ctx);
  ShortWait(0);
end;

procedure TPSPAudioCodec.hInit;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  case Codec of
    CODEC_AT3PLUS:
      ShortWait(InitAt3Plus(Ctx, False));
    CODEC_AT3:
      ShortWait(InitAt3(Ctx, False));
    CODEC_MP3:
      begin
        // The version stays unknown until a header is read.
        W32(Ctx, $38, 9999);
        var S := State(Ctx, CODEC_MP3);
        FreeAndNil(S.Mp3);
        S.Mp3 := TPSPMp3FrameDecoder.Create;
        ShortWait(0);
      end;
    CODEC_AAC:
      begin
        var Rate := Integer(R32(Ctx, $28) and $FFFF);
        var Ok := False;
        for var R in AacRates do
          if R = Integer(R32(Ctx, $28)) then
            Ok := True;
        if not Ok or (Rate = 0) then
        begin
          FHLE.Result(ERROR_AVCODEC_INVALID_PARAM);
          Exit;
        end;
        if (FMemory.Read8(Ctx + $2C) <> 0) or (FMemory.Read8(Ctx + $2D) <> 0) then
        begin
          ShortWait(ERROR_AVCODEC_INVALID_PARAM);
          Exit;
        end;
        var S := State(Ctx, CODEC_AAC);
        S.AacIntf := nil;
        S.Aac := nil;
        S.Frames := 0;
        ShortWait(0);
      end;
  else
    FHLE.Result(SCE_ERROR_NOT_SUPPORTED_4);
  end;
end;

procedure TPSPAudioCodec.hInitMono;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  case Codec of
    CODEC_AT3PLUS:
      ShortWait(InitAt3Plus(Ctx, True));
    CODEC_AT3:
      ShortWait(InitAt3(Ctx, True));
    CODEC_MP3:
      begin
        W32(Ctx, $38, 9999);
        FHLE.Result(ERROR_AVCODEC_INVALID_PARAM);
      end;
  else
    FHLE.Result(ERROR_AVCODEC_INVALID_PARAM);
  end;
end;

procedure TPSPAudioCodec.hDecode;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  case Codec of
    CODEC_AT3PLUS:
      ShortWait(DecodeAt3Plus(Ctx));
    CODEC_AT3:
      ShortWait(DecodeAt3(Ctx));
    CODEC_MP3:
      ShortWait(DecodeMp3(Ctx));
    CODEC_AAC:
      ShortWait(DecodeAac(Ctx));
  else
    FHLE.Result(SCE_ERROR_NOT_SUPPORTED_4);
  end;
end;

procedure TPSPAudioCodec.hGetInfo;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  if Codec <> CODEC_MP3 then
  begin
    ShortWait(0);
    Exit;
  end;
  var Info: TPSPMp3Header;
  var In_ := R32(Ctx, OffInBuf);
  if (In_ = 0) or not ReadMp3Header(Ctx, In_, Info) then
  begin
    W32(Ctx, OffErr, Cardinal(-2));
    W32(Ctx, $2C, $FFFFFFFF);
    var Off: Cardinal := $38;
    while Off <= $64 do
    begin
      W32(Ctx, Off, $FFFFFFFF);
      Inc(Off, 4);
    end;
    ShortWait(ERROR_AVCODEC_INVALID_DATA);
    Exit;
  end;
  ShortWait(0);
end;

procedure TPSPAudioCodec.hGetBlockSize;
begin
  var Ctx := FHLE.Arg(0);
  var Codec := FHLE.ArgInt(1);
  var OutPtr := FHLE.Arg(2);
  var N: Cardinal := 0;
  case Codec of
    CODEC_AT3PLUS:
      N := 2048 * 2 * R32(Ctx, $48);
    CODEC_AT3:
      begin
        N := $1000;
        var Bytes, Channels: Integer;
        var Joint: Boolean;
        if PSPAtrac3Param(Integer(R32(Ctx, $28)), Bytes, Channels, Joint) and (Channels = 1) and
          (R32(Ctx, $34) <> 2) then
          N := $800;
      end;
    CODEC_MP3:
      begin
        var V := R32(Ctx, $38);
        if V = 9999 then
        begin
          W32(Ctx, OffErr, Cardinal(-21));
          ShortWait(ERROR_AVCODEC_INVALID_DATA);
          Exit;
        end;
        if V = 1 then
          N := 1152 * 4
        else
          N := 576 * 4;
      end;
    CODEC_AAC:
      begin
        N := $1000;
        if FMemory.Read8(Ctx + $2D) <> 0 then
          N := $2000;
      end;
  end;
  if OutPtr <> 0 then
    FMemory.Write32(OutPtr, N);
  FHLE.Result(0);
end;

procedure TPSPAudioCodec.Register;
begin
  var H := FHLE;
  const L = 'sceAudiocodec';
  H.Register(L, $70A703F8, 'sceAudiocodecDecode', hDecode);
  H.Register(L, $5B37EB1D, 'sceAudiocodecInit', hInit);
  H.Register(L, $8ACA11D5, 'sceAudiocodecGetInfo', hGetInfo);
  H.Register(L, $3A20A200, 'sceAudiocodecGetEDRAM', hGetEDRAM);
  H.Register(L, $29681260, 'sceAudiocodecReleaseEDRAM', hReleaseEDRAM);
  H.Register(L, $9D3F790C, 'sceAudiocodecCheckNeedMem', hCheckNeedMem);
  H.Register(L, $59176A0F, 'sceAudiocodecGetBlockSize', hGetBlockSize);
  H.Register(L, $3DD7EE1A, 'sceAudiocodecInitMono', hInitMono);
end;

initialization
  RegisterPSPService(TPSPAudioCodec);

end.

