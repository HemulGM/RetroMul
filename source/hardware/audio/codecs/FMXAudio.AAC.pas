unit FMXAudio.AAC;

// AAC-LC scalar decoder adapted from FFmpeg n7.1 aacdec.c/proc/dsp.
// Copyright (c) 2005-2006 Oded Shimon; 2006-2007 Maxim Gavrilov;
// 2008-2013 Alex Converse. LGPL-2.1-or-later; see reference originals.

interface

uses Core.Bitstream,
  System.SysUtils, System.Generics.Collections, FMXAudio.Types,
  FMXAudio.Bitstream, FMXAudio.Transform, FMXAudio.AAC.SBR, FMXAudio.AAC.SSR,
  FMXAudio.AAC.LD, FMXAudio.AAC.ER, FMXAudio.AAC.USAC, FMXAudio.AAC.USAC.LPD;

type
  TAACChannelElement = record
    Kind, Tag, Position, FirstChannel, ChannelCount: Integer;
    SBR: TAACSBR;
  end;

  TAACProgram = TArray<TAACChannelElement>;

  TAACDecoder = class(TInterfacedObject, IAudioDecoder, IAudioSeekHistory)
  private
    type
      TCouplingTarget = record
        Kind, Tag, Selection, GainIndex: Integer;
      end;

      TCoupling = record
        Present: Boolean;
        Point, Count, Channel: Integer;
        Targets: array[0..7] of TCouplingTarget;
        Gains: array[0..15, 0..119] of Double;
      end;

      TCRCRegion = record
        Start, Actual, ProtectedCount: Integer;
      end;

      TTNSFilter = record
        Length, Order, Direction: Integer;
        Coeff: array[0..19] of Double;
      end;

      TPredictor = record
        R0, R1, Cor0, Cor1, Var0, Var1: Single;
      end;

      TICS = record
        Gain: TSSRGainData;
        LTPPresent: Boolean;
        LTPLag: Integer;
        LTPCoefficient: Double;
        LTPUsed: array[0..39] of Boolean;
        PredictorPresent: Boolean;
        ResetGroup: Integer;
        PredictionUsed: array[0..63] of Boolean;
        Sequence, Shape, MaxSFB, Groups, Windows: Integer;
        GroupLength: array[0..7] of Integer;
        Offsets: TArray<Word>;
        BandType: array[0..119] of Integer;
        Scale: array[0..119] of Integer;
        Quantized: array[0..1023] of Integer;
        Spectrum: array[0..1023] of Double;
        TNSCount: array[0..7] of Integer;
        TNS: array[0..7, 0..2] of TTNSFilter;
      end;
  private
    FCouplings: array[0..15] of TCoupling;
    FCouplingSBR: array[0..15] of TAACSBR;
    FSSR: TArray<TAACSSR>;
    FElements, FInitialElements: TAACProgram;
    FDownmix: array[0..95, 0..1] of Double;
    FObjectType, FFrameLength, FShortLength: Integer;
    FErrorResilient, FSectionResilience, FSFResilience, FSpectralResilience: Boolean;
    FELDHistory: TArray<TFloatSamples>;
    FUSACElements: TArray<TUSACElement>;
    FUSACArith: TArray<TAACArithState>;
    FUSACNoise: TArray<Cardinal>;
    FUSACStereo: TArray<TUSACStereoState>;
    FUSACLPD: TArray<TUSACLPD>;
    FUSACTime: TArray<TFloatSamples>;
    FUSACCoreMode, FUSACPreviousLPD: TArray<Boolean>;
    FUSACRawOverlap: TArray<TFloatSamples>;
    FUSACConfig: TBytes;
    FUSACConfigBits, FUSACPrerollDepth: Integer;
    FUSACFragments: TArray<TBytes>;
    FLTPState: TArray<TArray<Double>>;
    FPredictors: TArray<TArray<TPredictor>>;
    FRate, FRateIndex, FChannels, FElementTag, FInitialElementTag: Integer;
    FPacketData: TBytes;
    FCRCRegions: TArray<TCRCRegion>;
    FSBR: TAACSBR;
    FOutputRate: Integer;
    FBits: TBitReader;
    FVLC: array[0..11] of TVLCTable;
    FICS: TArray<TICS>;
    FPreviousShape: TArray<Integer>;
    FOverlap: TArray<TArray<Double>>;
    FLong, FShort: TInverseMDCT;
    FWindows: array[0..1, 0..1] of TFloatSamples;
    FOutput: TQueue<TAudioFrame>;
    FRandom: Cardinal;
    procedure EnsureChannels(Count: Integer);
    procedure ConfigureUSAC;
    procedure ReadUSACFrame;
    procedure ReadUSACPreroll(const Data: TBytes);
    procedure ConfigureProgram(const ProgramConfig: TAACProgram);
    procedure DefaultProgram(Config: Integer);
    procedure AddCRCRegion(Start, Actual, ProtectedCount: Integer);
    procedure ReadInfo(var ICS: TICS);
    procedure ReadChannel(var ICS: TICS; Common: Boolean);
    function ReadSpectral(Codebook: Integer): Integer;
    procedure ReadSpectrum(var ICS: TICS);
    procedure ReadTNS(var ICS: TICS);
    procedure ReadCoupling(Tag: Integer);
    procedure CoupleSpectrum(Source, Target, GainIndex: Integer);
    procedure ReadLTP(var ICS: TICS);
    procedure ApplyLTP(Channel: Integer);
    procedure ApplyPrediction(Channel: Integer);
    procedure ApplyTNS(var ICS: TICS; Inverse: Boolean = False);
    procedure Synthesize(Channel: Integer; out Samples: TFloatSamples);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ConfigureADTS(Profile, RateIndex, Config: Integer; const FirstBlock: TBytes);
    procedure Configure(const Track: TTrackInfo);
    procedure Send(const Packet: TMediaPacket);
    function Receive(out Frame: TAudioFrame): Boolean;
    procedure Flush;
    procedure Reset;
    function RequiresFullPreroll: Boolean;
    function PacketBytesConsumed: Integer;
    function ProtectedCRC(Initial: Word): Word;
    function OutputChannels: Integer;
    property OutputRate: Integer read FOutputRate;
  end;

function AACCRC16(const Data: TBytes; Start, Count: Integer; Initial: Word): Word;

function ReadAACProgramConfig(var Bits: TBitReader; RateIndex: Integer; out ElementTag: Integer): Integer;

implementation

uses
  System.Math, FMXAudio.AAC.Tables;

const
  RATES: array[0..12] of Integer =
    (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);

function AACCRC16(const Data: TBytes; Start, Count: Integer; Initial: Word): Word;
var
  Value: Cardinal;
begin
  Result := Initial;
  for var i := Start to Start + Count - 1 do
  begin
    Value := (Data[i div 8] shr (7 - i mod 8)) and 1;
    if ((Result shr 15) xor Value) <> 0 then
      Result := Word((Cardinal(Result) shl 1) xor $8005)
    else
      Result := Word(Cardinal(Result) shl 1);
  end;
end;

function ParseAACProgram(var Bits: TBitReader; RateIndex: Integer; out Core: Integer; out ProgramConfig: TAACProgram): Integer;
var
  Counts: array[0..3] of Integer;
  Assoc, CC, n, Position, Kind, Tag: Integer;
begin
  ProgramConfig := nil;
  Bits.Skip(4);
  Core := Integer(Bits.ReadBits(2)) + 1;
  if Bits.ReadBits(4) <> Cardinal(RateIndex) then
    raise EPlayerFormat.Create('AAC PCE sample rate mismatch');
  for n := 0 to 2 do
    Counts[n] := Bits.ReadBits(4);
  Counts[3] := Bits.ReadBits(2);
  Assoc := Bits.ReadBits(3);
  CC := Bits.ReadBits(4);
  if Bits.ReadBit then
    Bits.Skip(4);
  if Bits.ReadBit then
    Bits.Skip(4);
  if Bits.ReadBit then
    Bits.Skip(3);
  Result := 0;
  for Position := 0 to 3 do
    for n := 1 to Counts[Position] do
    begin
      if Position = 3 then
        Kind := 3
      else
        Kind := Ord(Bits.ReadBit);
      Tag := Bits.ReadBits(4);
      for var Existing in ProgramConfig do
        if (Existing.Kind = Kind) and (Existing.Tag = Tag) then
          raise EPlayerFormat.Create('Duplicate AAC PCE element');
      SetLength(ProgramConfig, Length(ProgramConfig) + 1);
      ProgramConfig[High(ProgramConfig)].Kind := Kind;
      with ProgramConfig[High(ProgramConfig)] do
      begin
        FirstChannel := Result;
        ChannelCount := 1 + Ord(ProgramConfig[High(ProgramConfig)].Kind = 1);
        Inc(Result, ChannelCount);
      end;
      ProgramConfig[High(ProgramConfig)].Kind := Kind;
      ProgramConfig[High(ProgramConfig)].Tag := Tag;
      ProgramConfig[High(ProgramConfig)].Position := Position;
    end;
  Bits.Skip(Assoc * 4);
  Bits.Skip(CC * 5);
  Bits.Align;
  Bits.Skip(Bits.ReadBits(8) * 8);
  if Result = 0 then
    raise EPlayerFormat.Create('Empty AAC PCE');
end;

function ReadAACProgramConfig(var Bits: TBitReader; RateIndex: Integer; out ElementTag: Integer): Integer;
var
  ProgramConfig: TAACProgram;
  Core: Integer;
begin
  Result := ParseAACProgram(Bits, RateIndex, Core, ProgramConfig);
  ElementTag := ProgramConfig[0].Tag;
end;

procedure TAACDecoder.EnsureChannels(Count: Integer);
var
  Previous: Integer;
begin
  if Count > 128 then
    raise EPlayerFormat.Create('AAC channel state limit exceeded');
  Previous := Length(FICS);
  if Count <= Previous then
    Exit;
  SetLength(FICS, Count);
  SetLength(FPreviousShape, Count);
  SetLength(FOverlap, Count);
  SetLength(FPredictors, Count);
  SetLength(FLTPState, Count);
  SetLength(FSSR, Count);
  for var Channel := Previous to Count - 1 do
  begin
    SetLength(FOverlap[Channel], FFrameLength);
    if FObjectType = 1 then
    begin
      SetLength(FPredictors[Channel], 1024);
      for var Bin := 0 to 1023 do
      begin
        FPredictors[Channel, Bin].Var0 := 1;
        FPredictors[Channel, Bin].Var1 := 1;
      end;
    end;
    if FObjectType in [4, 19, 23] then
      SetLength(FLTPState[Channel], FFrameLength * IfThen(FObjectType = 23, 5, 3));
  end;
end;

procedure TAACDecoder.ConfigureProgram(const ProgramConfig: TAACProgram);
var
  Norm, Sum: Double;
begin
  for var n := 0 to High(FCouplingSBR) do
    FreeAndNil(FCouplingSBR[n]);
  for var LPD in FUSACLPD do
    LPD.Free;
  FUSACLPD := nil;
  for var Element in FElements do
    Element.SBR.Free;
  FElements := Copy(ProgramConfig);
  FChannels := 0;
  FillChar(FDownmix, SizeOf(FDownmix), 0);
  for var n := 0 to High(FElements) do
  begin
    FElements[n].SBR := nil;
    FElements[n].FirstChannel := FChannels;
    Inc(FChannels, FElements[n].ChannelCount);
    if FChannels > Length(FDownmix) then
      raise EPlayerFormat.Create('AAC channel limit exceeded');
    var First := FElements[n].FirstChannel;
    if FElements[n].Kind = 1 then
    begin
      var Weight := 1.0;
      if FElements[n].Position <> 0 then
        Weight := Sqrt(0.5);
      FDownmix[First, 0] := Weight;
      FDownmix[First + 1, 1] := Weight;
    end
    else
    begin
      var Weight := Sqrt(0.5);
      if FElements[n].Position in [2, 3] then
        Weight := 0.5;
      FDownmix[First, 0] := Weight;
      FDownmix[First, 1] := Weight;
    end;
  end;
  Norm := 1;
  for var c := 0 to 1 do
  begin
    Sum := 0;
    for var n := 0 to FChannels - 1 do
      Sum := Sum + Abs(FDownmix[n, c]);
    Norm := Max(Norm, Sum);
  end;
  for var n := 0 to FChannels - 1 do
    for var c := 0 to 1 do
      FDownmix[n, c] := FDownmix[n, c] / Norm;
  for var SSR in FSSR do
    SSR.Free;
  FSSR := nil;
  FICS := nil;
  FOverlap := nil;
  FPredictors := nil;
  FLTPState := nil;
  FPreviousShape := nil;
  EnsureChannels(FChannels);
  FInitialElements := Copy(FElements);
end;

procedure TAACDecoder.DefaultProgram(Config: Integer);
var
  ProgramConfig: TAACProgram;

  procedure Add(Kind, Tag, Position: Integer);
  begin
    SetLength(ProgramConfig, Length(ProgramConfig) + 1);
    ProgramConfig[High(ProgramConfig)].ChannelCount := 1 + Ord(Kind = 1);
    ProgramConfig[High(ProgramConfig)].Kind := Kind;
    ProgramConfig[High(ProgramConfig)].Tag := Tag;
    ProgramConfig[High(ProgramConfig)].Position := Position;
  end;

begin
  case Config of
    1:
      Add(0, 0, 0);
    2:
      Add(1, 0, 0);
    13:
      begin
        Add(0, 0, 0);
        Add(1, 0, 0);
        Add(1, 1, 0);
        Add(1, 2, 2);
        Add(1, 3, 2);
        Add(0, 1, 2);
        Add(3, 0, 3);
        Add(3, 1, 3);
        Add(0, 2, 0);
        Add(1, 4, 0);
        Add(1, 5, 1);
        Add(0, 3, 1);
        Add(1, 6, 2);
        Add(0, 4, 2);
        Add(0, 5, 0);
        Add(1, 7, 0);
      end;
    3..7, 11, 12, 14:
      begin
        Add(0, 0, 0);
        Add(1, 0, 0);
        if Config = 4 then
          Add(0, 1, 2);
        if Config in [5, 6, 7, 11, 12, 14] then
        begin
          if Config = 7 then
            Add(1, 1, 0)
          else
            Add(1, 1, 2);
        end;
        if Config = 7 then
          Add(1, 2, 2);
        if Config = 11 then
          Add(0, 1, 2);
        if Config = 12 then
          Add(1, 2, 2);
        if Config in [6, 7, 11, 12, 14] then
          Add(3, 0, 3);
        if Config = 14 then
          Add(1, 2, 0);
      end;
  else
    raise EPlayerUnsupported.Create('Reserved AAC channel configuration');
  end;
  ConfigureProgram(ProgramConfig);
end;

procedure TAACDecoder.ConfigureADTS(Profile, RateIndex, Config: Integer; const FirstBlock: TBytes);
var
  Track: TTrackInfo;
  ProgramConfig: TAACProgram;
  Core: Integer;
begin
  Track := Default(TTrackInfo);
  Track.Codec := 'mp4a';
  var TemporaryConfig := Config;
  if Config = 0 then
    TemporaryConfig := 1;
  Track.CodecConfig :=
    TBytes.Create((Profile shl 3) or (RateIndex shr 1), ((RateIndex and 1) shl 7) or (TemporaryConfig shl 3));
  Configure(Track);
  if Config = 0 then
  begin
    FBits.Init(FirstBlock);
    if FBits.ReadBits(3) <> 5 then
      raise EPlayerFormat.Create('ADTS requires initial PCE');
    ParseAACProgram(FBits, RateIndex, Core, ProgramConfig);
    if Core <> Profile then
      raise EPlayerFormat.Create('AAC PCE profile mismatch');
    ConfigureProgram(ProgramConfig);
    Reset;
  end;
end;

procedure TAACDecoder.AddCRCRegion(Start, Actual, ProtectedCount: Integer);
var
  Index: Integer;
begin
  Index := Length(FCRCRegions);
  SetLength(FCRCRegions, Index + 1);
  FCRCRegions[Index].Start := Start;
  FCRCRegions[Index].Actual := Min(Actual, ProtectedCount);
  FCRCRegions[Index].ProtectedCount := ProtectedCount;
end;

function TAACDecoder.ProtectedCRC(Initial: Word): Word;
var
  Zero: TBytes;
begin
  Result := Initial;
  SetLength(Zero, 24);
  for var Region in FCRCRegions do
  begin
    Result := AACCRC16(FPacketData, Region.Start, Region.Actual, Result);
    Result := AACCRC16(Zero, 0, Region.ProtectedCount - Region.Actual, Result);
  end;
end;

constructor TAACDecoder.Create;
var
  i: Integer;
begin
  inherited;
  FOutput := TQueue<TAudioFrame>.Create;
  FVLC[0].Build(FF_AAC_SCALEFACTOR_CODE, FF_AAC_SCALEFACTOR_BITS);
  FVLC[1].Build(CODES1, BITS1);
  FVLC[2].Build(CODES2, BITS2);
  FVLC[3].Build(CODES3, BITS3);
  FVLC[4].Build(CODES4, BITS4);
  FVLC[5].Build(CODES5, BITS5);
  FVLC[6].Build(CODES6, BITS6);
  FVLC[7].Build(CODES7, BITS7);
  FVLC[8].Build(CODES8, BITS8);
  FVLC[9].Build(CODES9, BITS9);
  FVLC[10].Build(CODES10, BITS10);
  FVLC[11].Build(CODES11, BITS11);

  FFrameLength := 1024;
  FShortLength := 128;
  FLong := TInverseMDCT.Create(1024);
  FShort := TInverseMDCT.Create(128);
  for i := 0 to 1 do
  begin
    FWindows[i, 0] := AACWindow(1024, i = 1);
    FWindows[i, 1] := AACWindow(128, i = 1)
  end;
  Reset;
end;

destructor TAACDecoder.Destroy;
begin
  for var LPD in FUSACLPD do
    LPD.Free;
  for var SBR in FCouplingSBR do
    SBR.Free;
  for var Element in FElements do
    Element.SBR.Free;
  for var SSR in FSSR do
    SSR.Free;
  FSBR := nil;
  FLong.Free;
  FShort.Free;
  FOutput.Free;
  inherited;
end;

procedure TAACDecoder.ConfigureUSAC;
const
  USAC_RATES: array[0..30] of Integer = (
    96000,
    88200,
    64000,
    48000,
    44100,
    32000,
    24000,
    22050,
    16000,
    12000,
    11025,
    8000,
    7350,
    -1,
    -1,
    57600,
    51200,
    40000,
    38400,
    34150,
    28800,
    25600,
    20000,
    19200,
    17075,
    14400,
    12800,
    9600,
    -1,
    -1,
    -1
  );
var
  Rate, CoreRate, Index, FrameIndex, Config, Channels, AudioCount, Kind, ExtLength, Count: Integer;
  Layout: TAACProgram;
  Elements: TArray<TUSACElement>;
  Track: TTrackInfo;
  ConfigStart: TBitReader;
  ConfigData: TBytes;
  ConfigBits: Integer;
begin
  ConfigStart := FBits;
  Index := FBits.ReadBits(5);
  if Index = 31 then
    Rate := FBits.ReadBits(24)
  else
    Rate := USAC_RATES[Index];
  if Rate <= 0 then
    raise EPlayerFormat.Create('Invalid USAC sampling frequency');
  FrameIndex := FBits.ReadBits(3);
  if FrameIndex > 4 then
    raise EPlayerFormat.Create('Reserved USAC frame length index');
  if FrameIndex in [2, 4] then
    raise EPlayerUnsupported.Create('USAC non-dual SBR ratios are not implemented');
  CoreRate := Rate;
  if FrameIndex = 3 then
    CoreRate := Rate div 2;
  Config := FBits.ReadBits(5);
  if Config = 0 then
  begin
    Channels := USACEscapedValue(FBits, 5, 8, 16);
    if (Channels < 1) or (Channels > 64) then
      raise EPlayerFormat.Create('Invalid USAC channel count');
    for var i := 0 to Channels - 1 do
      FBits.Skip(5);
  end
  else
  begin
    DefaultProgram(Config);
    Layout := Copy(FElements);
    Channels := FChannels;
  end;
  Count := USACEscapedValue(FBits, 4, 8, 16) + 1;
  if Count > 64 then
    raise EPlayerFormat.Create('Too many USAC elements');
  SetLength(Elements, Count);
  AudioCount := 0;
  for var i := 0 to Count - 1 do
  begin
    Kind := FBits.ReadBits(2);
    Elements[i].Kind := Kind;
    Elements[i].AudioElement := AudioCount;
    if Kind = 3 then
    begin
      Elements[i].ExtensionType := USACEscapedValue(FBits, 4, 8, 16);
      ExtLength := USACEscapedValue(FBits, 4, 8, 16);
      if FBits.ReadBit then
        Elements[i].DefaultLength := USACEscapedValue(FBits, 8, 16, 0) + 1;
      Elements[i].Fragmented := FBits.ReadBit;
      FBits.Skip(ExtLength * 8);
    end
    else
    begin
      if Config = 0 then
      begin
        SetLength(Layout, AudioCount + 1);
        Layout[AudioCount].Kind := Kind;
        if Kind = 2 then
          Layout[AudioCount].Kind := 3;
        Layout[AudioCount].Tag := AudioCount;
        Layout[AudioCount].ChannelCount := 1 + Ord(Kind = 1);
        Layout[AudioCount].Position := IfThen(Kind = 2, 3, 0);
      end
      else if (AudioCount >= Length(Layout))
        or ((Kind <> Layout[AudioCount].Kind) and not ((Kind = 2) and (Layout[AudioCount].Kind = 3))) then
        raise EPlayerFormat.Create('USAC element disagrees with channel configuration');
      if Kind <> 2 then
      begin
        Elements[i].TimeWarping := FBits.ReadBit;
        Elements[i].NoiseFilling := FBits.ReadBit;
        if FrameIndex = 3 then
        begin
          Elements[i].SBRRatio := 2;
          ReadUSACSBRConfig(FBits, Elements[i].SBRConfig);
          if Kind = 1 then
          begin
            Elements[i].StereoConfig := FBits.ReadBits(2);
            if Elements[i].StereoConfig <> 0 then
              raise EPlayerUnsupported.Create('USAC MPS212 is not implemented');
          end;
        end;
      end;
      Inc(AudioCount);
    end;
  end;
  if AudioCount <> Length(Layout) then
    raise EPlayerFormat.Create('USAC channel layout is incomplete');
  if FBits.ReadBit then
  begin
    Count := USACEscapedValue(FBits, 2, 4, 8) + 1;
    for var i := 0 to Count - 1 do
    begin
      USACEscapedValue(FBits, 4, 8, 16);
      ExtLength := USACEscapedValue(FBits, 4, 8, 16);
      FBits.Skip(ExtLength * 8);
    end;
  end;
  Index := 0;
  ConfigBits := FBits.Position - ConfigStart.Position;
  SetLength(ConfigData, (ConfigBits + 7) div 8);
  for var i := 0 to ConfigBits - 1 do
    if ConfigStart.ReadBit then
      ConfigData[i div 8] := ConfigData[i div 8] or ($80 shr (i mod 8));
  while (Index < High(RATES)) and (CoreRate < (RATES[Index] + RATES[Index + 1]) div 2) do
    Inc(Index);
  Track := Default(TTrackInfo);
  Track.Codec := 'mp4a';
  Track.CodecConfig := TBytes.Create((2 shl 3) or (Index shr 1), ((Index and 1) shl 7) or (1 shl 3));
  Configure(Track);
  ConfigureProgram(Layout);
  if FChannels <> Channels then
    raise EPlayerFormat.Create('USAC channel count mismatch');
  FObjectType := 42;
  FErrorResilient := False;
  FUSACElements := Elements;
  FUSACConfig := ConfigData;
  FUSACConfigBits := ConfigBits;
  FRate := CoreRate;
  FOutputRate := Rate;
  if FrameIndex = 0 then
    FFrameLength := 768
  else
    FFrameLength := 1024;
  FShortLength := FFrameLength div 8;
  FreeAndNil(FLong);
  FreeAndNil(FShort);
  FLong := TInverseMDCT.Create(FFrameLength);
  FShort := TInverseMDCT.Create(FShortLength);
  for var Shape := 0 to 1 do
  begin
    FWindows[Shape, 0] := AACWindow(FFrameLength, Shape = 1);
    FWindows[Shape, 1] := AACWindow(FShortLength, Shape = 1);
  end;
  if FrameIndex = 3 then
    for var i := 0 to High(FElements) do
      FElements[i].SBR := TAACSBR.Create(FOutputRate, FElements[i].ChannelCount, False, FFrameLength);
  Reset;
end;

procedure TAACDecoder.ReadUSACPreroll(const Data: TBytes);
var
  R, ParentBits, ConfigReader: TBitReader;
  ParentData: TBytes;
  ParentOutput: TQueue<TAudioFrame>;
  Config, AU: TBytes;
  Packet: TMediaPacket;
  ConfigLength, Frames, LengthValue: Integer;
  SameConfig: Boolean;
begin
  R.Init(Data);
  ConfigLength := USACEscapedValue(R, 4, 4, 8);
  SetLength(Config, ConfigLength);
  for var i := 0 to ConfigLength - 1 do
    Config[i] := R.ReadBits(8);
  SameConfig := ConfigLength = 0;
  if ConfigLength * 8 >= FUSACConfigBits then
  begin
    ConfigReader.Init(Config);
    SameConfig := True;
    for var i := 0 to FUSACConfigBits - 1 do
      SameConfig :=
        (ConfigReader.ReadBits(1) = Cardinal((FUSACConfig[i div 8] shr (7 - i mod 8)) and 1)) and SameConfig;
  end;
  // With an unchanged config the running stream already has the required
  // state. Replaying these frames would duplicate recursive history.
  if SameConfig then
    Exit;
  if FUSACPrerollDepth >= 4 then
    raise EPlayerFormat.Create('Recursive USAC audio preroll');
  Inc(FUSACPrerollDepth);
  ParentBits := FBits;
  ParentData := FPacketData;
  ParentOutput := FOutput;
  FOutput := TQueue<TAudioFrame>.Create;
  try
    FBits.Init(Config);
    ConfigureUSAC;
    R.Skip(2); // applyCrossfade and reserved; PCM crossfade is a presentation tool.
    Frames := USACEscapedValue(R, 2, 4, 0);
    for var i := 0 to Frames - 1 do
    begin
      LengthValue := USACEscapedValue(R, 16, 16, 0);
      if LengthValue > R.Remaining div 8 then
        raise EPlayerFormat.Create('Truncated USAC preroll access unit');
      SetLength(AU, LengthValue);
      for var j := 0 to LengthValue - 1 do
        AU[j] := R.ReadBits(8);
      Packet := Default(TMediaPacket);
      Packet.Data := AU;
      Packet.SourceTimeScale := FRate;
      Send(Packet);
      FOutput.Clear;
    end;
  finally
    FBits := ParentBits;
    FPacketData := ParentData;
    FOutput.Free;
    FOutput := ParentOutput;
    Dec(FUSACPrerollDepth);
  end;
end;

procedure TAACDecoder.ReadUSACFrame;
var
  Independent, Common, TNSActive, TNSOnLR, CommonTNS, CommonTW, ResetArith: Boolean;
  TNSPresent: array[0..1] of Boolean;
  CoreMode: array[0..1] of Boolean;
  Mask: array[0..119] of Boolean;
  First, ChannelCount, StereoMode, MaxSFB, Gain, NoiseLevel, NoiseOffset, Offset, Count, Base: Integer;
  Spectrum: TFloatSamples;
begin
  Independent := FBits.ReadBit;
  var ElementIndex := 0;
  while ElementIndex < Length(FUSACElements) do
  begin
    var Element := FUSACElements[ElementIndex];
    Inc(ElementIndex);
    if Element.Kind = 3 then
    begin
      if FBits.ReadBit then
      begin
        if FBits.ReadBit then
          Count := Element.DefaultLength
        else
        begin
          Count := FBits.ReadBits(8);
          if Count = 255 then
            Inc(Count, Integer(FBits.ReadBits(16)) - 2);
        end;
        if Count > 0 then
        begin
          var StartFragment := True;
          var EndFragment := True;
          if Element.Fragmented then
          begin
            StartFragment := FBits.ReadBit;
            EndFragment := FBits.ReadBit;
          end;
          if Count > FBits.Remaining div 8 then
            raise EPlayerFormat.Create('Truncated USAC extension');
          var Data: TBytes;
          SetLength(Data, Count);
          for var i := 0 to Count - 1 do
            Data[i] := FBits.ReadBits(8);
          if StartFragment then
            FUSACFragments[ElementIndex - 1] := nil;
          if Length(FUSACFragments[ElementIndex - 1]) + Count > 8 * 1024 * 1024 then
            raise EPlayerFormat.Create('USAC fragmented extension exceeds resource limit');
          FUSACFragments[ElementIndex - 1] := FUSACFragments[ElementIndex - 1] + Data;
          if EndFragment then
          begin
            Data := FUSACFragments[ElementIndex - 1];
            FUSACFragments[ElementIndex - 1] := nil;
            if Element.ExtensionType = 3 then
              ReadUSACPreroll(Data);
          end;
        end;
      end;
      Continue;
    end;
    First := FElements[Element.AudioElement].FirstChannel;
    ChannelCount := FElements[Element.AudioElement].ChannelCount;
    for var c := 0 to ChannelCount - 1 do
    begin
      CoreMode[c] := FBits.ReadBit;
      FUSACPreviousLPD[First + c] := FUSACCoreMode[First + c];
      FUSACCoreMode[First + c] := CoreMode[c];
      FICS[First + c].LTPPresent := False;
      TNSPresent[c] := False;
      FillChar(FICS[First + c].TNSCount, SizeOf(FICS[First + c].TNSCount), 0);
    end;
    FillChar(FUSACStereo[Element.AudioElement].AlphaReal, SizeOf(FUSACStereo[Element.AudioElement].AlphaReal), 0);
    FillChar(FUSACStereo[Element.AudioElement].AlphaImag, SizeOf(FUSACStereo[Element.AudioElement].AlphaImag), 0);
    Common := False;
    CommonTW := False;
    TNSOnLR := True;
    StereoMode := 0;
    MaxSFB := 0;
    FillChar(Mask, SizeOf(Mask), 0);
    if (ChannelCount = 2) and not CoreMode[0] and not CoreMode[1] then
    begin
      TNSActive := FBits.ReadBit;
      Common := FBits.ReadBit;
      if not Common or Independent then
      begin
        FillChar(
          FUSACStereo[Element.AudioElement].PreviousReal,
          SizeOf(FUSACStereo[Element.AudioElement].PreviousReal),
          0
        );
        FillChar(
          FUSACStereo[Element.AudioElement].PreviousImag,
          SizeOf(FUSACStereo[Element.AudioElement].PreviousImag),
          0
        );
      end;
      if Common then
      begin
        ReadInfo(FICS[First]);
        FICS[First + 1] := FICS[First];
        if not FBits.ReadBit then
          if FICS[First].Sequence = 2 then
            FICS[First + 1].MaxSFB := FBits.ReadBits(4)
          else
            FICS[First + 1].MaxSFB := FBits.ReadBits(6);
        if FICS[First + 1].MaxSFB >= Length(FICS[First + 1].Offsets) then
          raise EPlayerFormat.Create('USAC right max_sfb exceeds bands');
        MaxSFB := Max(FICS[First].MaxSFB, FICS[First + 1].MaxSFB);
        StereoMode := FBits.ReadBits(2);
        if StereoMode = 3 then
          USACReadStereoPrediction(
            FBits,
            FUSACStereo[Element.AudioElement],
            FICS[First].Groups,
            MaxSFB,
            FICS[First].Sequence,
            Independent,
            FVLC[0]
          );
        for var i := 0 to FICS[First].Groups * MaxSFB - 1 do
          if StereoMode = 1 then
            Mask[i] := FBits.ReadBit
          else
            Mask[i] := StereoMode = 2;
      end;
      if Element.TimeWarping then
      begin
        CommonTW := FBits.ReadBit;
        if CommonTW and FBits.ReadBit then
          raise EPlayerUnsupported.Create('USAC time-warped MDCT is not implemented');
      end;
      if TNSActive then
      begin
        CommonTNS := Common and FBits.ReadBit;
        TNSOnLR := FBits.ReadBit;
        if CommonTNS then
        begin
          ReadTNS(FICS[First]);
          FICS[First + 1].TNSCount := FICS[First].TNSCount;
          FICS[First + 1].TNS := FICS[First].TNS;
        end
        else if FBits.ReadBit then
        begin
          TNSPresent[0] := True;
          TNSPresent[1] := True;
        end
        else
        begin
          TNSPresent[1] := FBits.ReadBit;
          TNSPresent[0] := not TNSPresent[1];
        end;
      end;
    end;
    for var c := 0 to ChannelCount - 1 do
    begin
      var Channel := First + c;
      if CoreMode[c] then
      begin
        if FUSACLPD[Channel] = nil then
          FUSACLPD[Channel] := TUSACLPD.Create(FFrameLength, FRate);
        FUSACLPD[Channel]
          .Decode(
            FBits,
            FUSACArith[Channel],
            Independent,
            FUSACNoise[Channel],
            FUSACRawOverlap[Channel],
            FICS[Channel].Sequence = 2,
            FUSACTime[Channel]);
        FICS[Channel].Sequence := 2;
        FPreviousShape[Channel] := 0;
        Continue;
      end;
      if (ChannelCount = 1) or (CoreMode[0] <> CoreMode[1]) then
        TNSPresent[c] := FBits.ReadBit;
      Gain := FBits.ReadBits(8);
      NoiseLevel := 0;
      NoiseOffset := 0;
      if Element.NoiseFilling then
      begin
        NoiseLevel := FBits.ReadBits(3);
        NoiseOffset := Integer(FBits.ReadBits(5)) - 16;
      end;
      if not Common then
        ReadInfo(FICS[Channel]);
      MaxSFB := Max(MaxSFB, FICS[Channel].MaxSFB);
      if Element.TimeWarping and not CommonTW then
        if FBits.ReadBit then
          raise EPlayerUnsupported.Create('USAC time-warped MDCT is not implemented');
      Offset := Gain;
      for var i := 0 to FICS[Channel].Groups * FICS[Channel].MaxSFB - 1 do
      begin
        if i <> 0 then
          Inc(Offset, FBits.ReadVLC(FVLC[0]) - 60);
        if (Offset < 0) or (Offset > 255) then
          raise EPlayerFormat.Create('USAC scalefactor range');
        FICS[Channel].Scale[i] := Offset - 100;
        FICS[Channel].BandType[i] := 11;
      end;
      if TNSPresent[c] then
        ReadTNS(FICS[Channel]);
      ResetArith := Independent or FBits.ReadBit;
      FillChar(FICS[Channel].Spectrum, SizeOf(FICS[Channel].Spectrum), 0);
      var WindowLength := IfThen(FICS[Channel].Sequence = 2, FShortLength, FFrameLength);
      for var w := 0 to FICS[Channel].Windows - 1 do
      begin
        USACDecodeSpectrum(
          FBits,
          FUSACArith[Channel],
          ResetArith and (w = 0),
          FICS[Channel].Offsets[FICS[Channel].MaxSFB],
          WindowLength,
          Spectrum
        );
        Move(Spectrum[0], FICS[Channel].Spectrum[w * WindowLength], WindowLength * SizeOf(Double));
      end;
      if FUSACLPD[Channel] = nil then
        FUSACLPD[Channel] := TUSACLPD.Create(FFrameLength, FRate);
      FUSACLPD[Channel].ReadFDTransition(FBits, FICS[Channel].Sequence = 2);
      Base := 0;
      for var g := 0 to FICS[Channel].Groups - 1 do
      begin
        for var b := 0 to FICS[Channel].MaxSFB - 1 do
        begin
          var Band := g * FICS[Channel].MaxSFB + b;
          var AllZero := True;
          for var w := 0 to FICS[Channel].GroupLength[g] - 1 do
            for var k := FICS[Channel].Offsets[b] to FICS[Channel].Offsets[b + 1] - 1 do
              AllZero := AllZero and (FICS[Channel].Spectrum[(Base + w) * WindowLength + k] = 0);
          var NoiseStart := IfThen(WindowLength = FFrameLength, 160, 20);
          if FFrameLength = 768 then
            NoiseStart := IfThen(WindowLength = FFrameLength, 120, 15);
          if (NoiseLevel <> 0) and (FICS[Channel].Offsets[b] >= NoiseStart) then
          begin
            if AllZero then
              FICS[Channel].Scale[Band] := Max(-200, FICS[Channel].Scale[Band] + NoiseOffset);
            for var w := 0 to FICS[Channel].GroupLength[g] - 1 do
              for var k := FICS[Channel].Offsets[b] to FICS[Channel].Offsets[b + 1] - 1 do
              begin
                var Position := (Base + w) * WindowLength + k;
                if FICS[Channel].Spectrum[Position] = 0 then
                begin
                  FUSACNoise[Channel] := Cardinal((UInt64(FUSACNoise[Channel]) * 69069 + 5) and $FFFFFFFF);
                  var Sign := 1.0;
                  if FUSACNoise[Channel] and $10000 <> 0 then
                    Sign := -1;
                  FICS[Channel].Spectrum[Position] := Sign * Power(2, (NoiseLevel - 14) / 3);
                end;
              end;
          end;
          var Scale := Power(2, FICS[Channel].Scale[Band] / 4);
          for var w := 0 to FICS[Channel].GroupLength[g] - 1 do
            for var k := FICS[Channel].Offsets[b] to FICS[Channel].Offsets[b + 1] - 1 do
            begin
              var Position := (Base + w) * WindowLength + k;
              FICS[Channel].Spectrum[Position] := FICS[Channel].Spectrum[Position] * Scale;
            end;
        end;
        Inc(Base, FICS[Channel].GroupLength[g]);
      end;
    end;
    if Element.SBRRatio <> 0 then
      FElements[Element.AudioElement].SBR.ReadUSAC(FBits, Element.SBRConfig, Independent);
    if Common then
    begin
      if not TNSOnLR then
        for var c := 0 to 1 do
        begin
          ApplyTNS(FICS[First + c]);
          FillChar(FICS[First + c].TNSCount, SizeOf(FICS[First + c].TNSCount), 0);
        end;
      if StereoMode = 3 then
        USACApplyStereoPrediction(
          FUSACStereo[Element.AudioElement],
          FICS[First].Spectrum,
          FICS[First + 1].Spectrum,
          FFrameLength,
          FICS[First].Groups,
          MaxSFB,
          FICS[First].Sequence,
          FICS[First].Shape,
          FPreviousShape[First],
          FICS[First].GroupLength,
          FICS[First].Offsets
        );
      Base := 0;
      for var g := 0 to FICS[First].Groups - 1 do
      begin
        for var b := 0 to Min(FICS[First].MaxSFB, FICS[First + 1].MaxSFB) - 1 do
          if Mask[g * MaxSFB + b] then
            for var w := 0 to FICS[First].GroupLength[g] - 1 do
              for var k := FICS[First].Offsets[b] to FICS[First].Offsets[b + 1] - 1 do
              begin
                var Position := (Base + w) * IfThen(FICS[First].Sequence = 2, FShortLength, FFrameLength) + k;
                var Left := FICS[First].Spectrum[Position];
                var Right := FICS[First + 1].Spectrum[Position];
                FICS[First].Spectrum[Position] := Left + Right;
                FICS[First + 1].Spectrum[Position] := Left - Right;
              end;
        Inc(Base, FICS[First].GroupLength[g]);
      end;
    end;
    if ChannelCount = 2 then
    begin
      var State := FUSACStereo[Element.AudioElement];
      State.Sequence := FICS[First].Sequence;
      State.Groups := FICS[First].Groups;
      State.Bands := MaxSFB;
      State.PreviousReal := State.AlphaReal;
      State.PreviousImag := State.AlphaImag;
      for var c := 0 to 1 do
        Move(FICS[First + c].Spectrum, State.PreviousSpectrum[c], SizeOf(FICS[First + c].Spectrum));
      FUSACStereo[Element.AudioElement] := State;
    end;
  end;
end;

procedure TAACDecoder.Configure(const Track: TTrackInfo);
var
  ObjectType, Rate, Channels, OutputRate: Integer;
  SBR, PS: Boolean;
  ProgramConfig: TAACProgram;
  Core: Integer;

  function ReadRate: Integer;
  var
    Index: Integer;
  begin
    Index := FBits.ReadBits(4);
    if Index = 15 then
      Result := FBits.ReadBits(24)
    else if Index <= High(RATES) then
      Result := RATES[Index]
    else
      raise EPlayerFormat.Create('Reserved AAC sample rate index');
  end;

  function ReadObjectType: Integer;
  begin
    Result := FBits.ReadBits(5);
    if Result = 31 then
      Result := 32 + Integer(FBits.ReadBits(6))
  end;

begin
  if Track.Codec <> 'mp4a' then
    raise EPlayerUnsupported.Create('AAC decoder requires mp4a');
  FBits.Init(Track.CodecConfig);
  ObjectType := ReadObjectType;
  Rate := ReadRate;
  FRateIndex := -1;
  for var i := 0 to High(RATES) do
    if RATES[i] = Rate then
      FRateIndex := i;
  if ((FRateIndex < 0) or (FRateIndex > High(RATES))) and (ObjectType <> 42) then
    raise EPlayerUnsupported.Create('Unsupported AAC sample rate');
  Channels := FBits.ReadBits(4);
  if ObjectType = 42 then
  begin
    ConfigureUSAC;
    Exit;
  end;
  PS := ObjectType = 29;
  SBR := ObjectType in [5, 29];
  OutputRate := Rate;
  if SBR then
  begin
    OutputRate := ReadRate;
    ObjectType := ReadObjectType
  end;
  if not (ObjectType in [1, 2, 3, 4, 17, 19, 23, 39]) then
    raise EPlayerUnsupported.CreateFmt('Unsupported AAC core object type %d', [ObjectType]);
  if FBits.ReadBit then
    FFrameLength := 960
  else
    FFrameLength := 1024;
  if ObjectType in [23, 39] then
    FFrameLength := FFrameLength div 2;
  FShortLength := FFrameLength div 8;
  FObjectType := ObjectType;
  FErrorResilient := ObjectType in [17, 19, 23, 39];
  FSectionResilience := False;
  FSFResilience := False;
  FSpectralResilience := False;
  FreeAndNil(FLong);
  FreeAndNil(FShort);
  FLong := TInverseMDCT.Create(FFrameLength);
  FShort := TInverseMDCT.Create(FShortLength);
  for var Shape := 0 to 1 do
  begin
    FWindows[Shape, 0] := AACWindow(FFrameLength, Shape = 1);
    FWindows[Shape, 1] := AACWindow(FShortLength, Shape = 1);
  end;
  var ExtensionFlag := False;
  if FObjectType <> 39 then
  begin
    if FBits.ReadBit then
      FBits.Skip(14);
    ExtensionFlag := FBits.ReadBit;
  end;
  FElementTag := 0;
  if Channels = 0 then
  begin
    ParseAACProgram(FBits, FRateIndex, Core, ProgramConfig);
    if Core <> FObjectType then
      raise EPlayerFormat.Create('AAC PCE profile mismatch');
    ConfigureProgram(ProgramConfig);
  end
  else
    DefaultProgram(Channels);
  if (ExtensionFlag and FErrorResilient) or (FObjectType = 39) then
  begin
    FSectionResilience := FBits.ReadBit;
    FSFResilience := FBits.ReadBit;
    FSpectralResilience := FBits.ReadBit;
  end;
  if FObjectType = 39 then
  begin
    if FBits.ReadBit then
      raise EPlayerUnsupported.Create('AAC ELD low-delay SBR is not implemented');
    while FBits.ReadBits(4) <> 0 do
    begin
      var Bytes := Integer(FBits.ReadBits(4));
      if Bytes = 15 then
        Inc(Bytes, FBits.ReadBits(8));
      if Bytes = 270 then
        Inc(Bytes, FBits.ReadBits(16));
      FBits.Skip(Bytes * 8);
    end;
  end;
  if ExtensionFlag and FBits.ReadBit then
    raise EPlayerUnsupported.Create('AAC extensionFlag3 is reserved');
  if FErrorResilient then
    if FBits.ReadBits(2) <> 0 then
      raise EPlayerUnsupported.Create('AAC external error-protection configuration is not implemented');
  if FObjectType = 23 then
    FWindows[1, 0] := AACLowOverlapWindow(FFrameLength);
  FInitialElementTag := FElementTag;
  // Backward-compatible ASC may carry the SBR sync extension after GASpecificConfig.
  if not SBR and (FBits.Remaining >= 16) then
    if FBits.ReadBits(11) = $2B7 then
    begin
      ObjectType := ReadObjectType;
      if (ObjectType = 5) and FBits.ReadBit then
      begin
        SBR := True;
        OutputRate := ReadRate
      end;
    end;
  if SBR and (FChannels = 1) then
  begin
    PS := True;
    if FBits.Remaining >= 12 then
      if FBits.ReadBits(11) = $548 then
        PS := FBits.ReadBit;
  end;
  if SBR and (OutputRate <> 2 * Rate) and (OutputRate <> Rate) then
    raise EPlayerUnsupported.Create('Only dual-rate HE-AAC SBR is supported');
  FSBR := nil;
  FRate := Rate;
  FOutputRate := OutputRate;
  if SBR then
    for var n := 0 to High(FElements) do
    begin
      FElements[n].SBR := TAACSBR.Create(FRate * 2, FElements[n].ChannelCount, FOutputRate = FRate, FFrameLength);
      if PS then
        FElements[n].SBR.EnablePS;
    end;
  Reset;
end;

procedure TAACDecoder.Reset;
begin
  EnsureChannels(FChannels);
  SetLength(FELDHistory, Length(FICS));
  SetLength(FUSACLPD, FChannels);
  SetLength(FUSACTime, FChannels);
  SetLength(FUSACCoreMode, FChannels);
  SetLength(FUSACPreviousLPD, FChannels);
  SetLength(FUSACRawOverlap, FChannels);
  for var c := 0 to FChannels - 1 do
  begin
    if FUSACLPD[c] <> nil then
      FUSACLPD[c].Reset;
    FUSACTime[c] := nil;
    FUSACCoreMode[c] := False;
    FUSACPreviousLPD[c] := False;
    SetLength(FUSACRawOverlap[c], FFrameLength);
    FillChar(FUSACRawOverlap[c][0], FFrameLength * SizeOf(Double), 0);
  end;
  SetLength(FUSACArith, FChannels);
  SetLength(FUSACNoise, FChannels);
  SetLength(FUSACStereo, Length(FElements));
  SetLength(FUSACFragments, Length(FUSACElements));
  for var i := 0 to High(FUSACFragments) do
    FUSACFragments[i] := nil;
  for var i := 0 to High(FUSACStereo) do
    FUSACStereo[i] := Default(TUSACStereoState);
  for var Channel := 0 to FChannels - 1 do
  begin
    FUSACArith[Channel] := Default(TAACArithState);
    if Odd(Channel) then
      FUSACNoise[Channel] := $10932
    else
      FUSACNoise[Channel] := $3039;
  end;
  for var Channel := 0 to High(FICS) do
  begin
    FELDHistory[Channel] := nil;
    FICS[Channel] := Default(TICS);
    FPreviousShape[Channel] := 0;
    SetLength(FOverlap[Channel], FFrameLength);
    FillChar(FOverlap[Channel, 0], FFrameLength * SizeOf(Double), 0);
    if FObjectType in [4, 19, 23] then
    begin
      SetLength(FLTPState[Channel], FFrameLength * IfThen(FObjectType = 23, 5, 3));
      FillChar(FLTPState[Channel, 0], Length(FLTPState[Channel]) * SizeOf(Double), 0);
    end
    else
      FLTPState[Channel] := nil;
    if FObjectType = 1 then
    begin
      SetLength(FPredictors[Channel], 1024);
      for var Bin := 0 to 1023 do
      begin
        FPredictors[Channel, Bin] := Default(TPredictor);
        FPredictors[Channel, Bin].Var0 := 1;
        FPredictors[Channel, Bin].Var1 := 1;
      end;
    end
    else
      FPredictors[Channel] := nil;
  end;
  // Match FFmpeg's deterministic AAC PNS sequence as well as its LCG.
  for var SSR in FSSR do
    if SSR <> nil then
      SSR.Reset;
  FRandom := $1F2E3D4C;
  FElementTag := FInitialElementTag;
  FPacketData := nil;
  FCRCRegions := nil;
  FOutput.Clear;
  for var SBR in FCouplingSBR do
    if SBR <> nil then
      SBR.Reset;
  for var n := 0 to High(FElements) do
  begin
    FElements[n].Tag := FInitialElements[n].Tag;
    if FElements[n].SBR <> nil then
      FElements[n].SBR.Reset;
  end;
  FSBR := nil;
end;

procedure TAACDecoder.Flush;
begin
  // Every AAC-LC access unit produces 1024 samples, including its overlap tail.
  // Extra overlap is encoder padding and must not be appended beyond the MP4 edit duration.
end;

function TAACDecoder.OutputChannels: Integer;
begin
  Result := Min(2, FChannels);
  if (Length(FElements) > 0) and (FElements[0].SBR <> nil) and FElements[0].SBR.ParametricStereo then
    Result := 2;
end;

function TAACDecoder.RequiresFullPreroll: Boolean;
begin
  // SBR headers, delta envelopes, chirp and QMF history are not random-access
  // at an arbitrary video keyframe. Decode old packets and trim their PCM.
  Result := True;
end;

function TAACDecoder.Receive(out Frame: TAudioFrame): Boolean;
begin
  Result := FOutput.Count > 0;
  if Result then
    Frame := FOutput.Dequeue
  else
    Frame := Default(TAudioFrame);
end;

procedure TAACDecoder.ReadInfo(var ICS: TICS);
var
  i, PreviousSequence: Integer;

  procedure SetOffsets(const Values: array of Word);
  begin
    SetLength(ICS.Offsets, Length(Values));
    Move(Values[0], ICS.Offsets[0], Length(Values) * SizeOf(Word));
  end;

begin
  PreviousSequence := ICS.Sequence;
  ICS.PredictorPresent := False;
  if FObjectType = 39 then
  begin
    ICS.Sequence := 0;
    ICS.Shape := 0;
  end
  else
  begin
    if (FObjectType <> 42) and FBits.ReadBit then
      raise EPlayerFormat.Create('AAC reserved ICS bit is set');
    ICS.Sequence := FBits.ReadBits(2);
    if (FObjectType = 42) and (ICS.Sequence = 1) and (PreviousSequence in [1, 2, 4]) then
      ICS.Sequence := 4;
    ICS.Shape := FBits.ReadBits(1);
    if (FObjectType = 23) and (ICS.Sequence <> 0) then
      raise EPlayerFormat.Create('AAC LD requires long windows');
  end;
  ICS.LTPPresent := False;
  ICS.Groups := 1;
  ICS.GroupLength[0] := 1;
  if ICS.Sequence = 2 then
  begin
    ICS.PredictorPresent := False;
    ICS.ResetGroup := 0;
    ICS.Windows := 8;
    ICS.MaxSFB := FBits.ReadBits(4);
    for i := 0 to 6 do
      if FBits.ReadBit then
        Inc(ICS.GroupLength[ICS.Groups - 1])
      else
      begin
        ICS.GroupLength[ICS.Groups] := 1;
        Inc(ICS.Groups)
      end;
    case FRateIndex of
      0..2:
        SetOffsets(SWB_OFFSET_128_96);
      3..5:
        SetOffsets(SWB_OFFSET_128_48);
      6..7:
        SetOffsets(SWB_OFFSET_128_24);
      8..10:
        SetOffsets(SWB_OFFSET_128_16);
      11..12:
        SetOffsets(SWB_OFFSET_128_8);
    end;
  end
  else
  begin
    ICS.Windows := 1;
    ICS.MaxSFB := FBits.ReadBits(6);
    case FRateIndex of
      0..1:
        SetOffsets(SWB_OFFSET_1024_96);
      2:
        SetOffsets(SWB_OFFSET_1024_64);
      3..4:
        SetOffsets(SWB_OFFSET_1024_48);
      5:
        SetOffsets(SWB_OFFSET_1024_32);
      6..7:
        SetOffsets(SWB_OFFSET_1024_24);
      8..10:
        SetOffsets(SWB_OFFSET_1024_16);
      11..12:
        SetOffsets(SWB_OFFSET_1024_8);
    end;
    if not (FObjectType in [39, 42]) then
      ICS.PredictorPresent := FBits.ReadBit;
    ICS.ResetGroup := 0;
    FillChar(ICS.PredictionUsed, SizeOf(ICS.PredictionUsed), 0);
    if ICS.PredictorPresent then
    begin
      if FObjectType in [4, 19, 23] then
      begin
        ICS.LTPPresent := FBits.ReadBit;
        if ICS.LTPPresent then
          ReadLTP(ICS);
      end
      else if FObjectType = 1 then
      begin
        if FBits.ReadBit then
        begin
          ICS.ResetGroup := FBits.ReadBits(5);
          if not (ICS.ResetGroup in [1..30]) then
            raise EPlayerFormat.Create('Invalid AAC Main predictor reset group');
        end;
        for i := 0 to Min(ICS.MaxSFB, AAC_PRED_SFB_MAX[FRateIndex]) - 1 do
          ICS.PredictionUsed[i] := FBits.ReadBit;
      end
      else
        raise EPlayerFormat.Create('Predictor is not allowed in AAC-LC');
    end;
  end;
  if FFrameLength = 960 then
    if ICS.Sequence = 2 then
      case FRateIndex of
        0..2:
          SetOffsets(SWB_OFFSET_120_96);
        3..5:
          SetOffsets(SWB_OFFSET_120_48);
        6..7:
          SetOffsets(SWB_OFFSET_120_24);
        8..10:
          SetOffsets(SWB_OFFSET_120_16);
        11..12:
          SetOffsets(SWB_OFFSET_120_8);
      end
    else
      case FRateIndex of
        0..1:
          SetOffsets(SWB_OFFSET_960_96);
        2:
          SetOffsets(SWB_OFFSET_960_64);
        3..5:
          SetOffsets(SWB_OFFSET_960_48);
        6..7:
          SetOffsets(SWB_OFFSET_960_24);
        8..10:
          SetOffsets(SWB_OFFSET_960_16);
        11..12:
          SetOffsets(SWB_OFFSET_960_8);
      end;
  if FObjectType in [23, 39] then
    ICS.Offsets := AACLowDelayOffsets(FFrameLength, FRateIndex);
  if (FObjectType = 42) and (FFrameLength = 768) then
    ICS.Offsets := USACBandOffsets(FFrameLength, FRateIndex, ICS.Sequence = 2);
  if ICS.MaxSFB >= Length(ICS.Offsets) then
    raise EPlayerFormat.Create('AAC max_sfb exceeds scalefactor bands');
end;

function TAACDecoder.ReadSpectral(Codebook: Integer): Integer;
begin
  if (Codebook < 1) or (Codebook > 11) then
    raise EPlayerFormat.Create('Invalid AAC spectral codebook');
  Result := FBits.ReadVLC(FVLC[Codebook]);
end;

procedure TAACDecoder.ReadTNS(var ICS: TICS);
var
  w, f, i, Res, Compress, Value, Bits, MaxOrder: Integer;
  T: TTNSFilter;
begin
  FillChar(ICS.TNSCount, SizeOf(ICS.TNSCount), 0);
  for w := 0 to ICS.Windows - 1 do
  begin
    ICS.TNSCount[w] := FBits.ReadBits(2 - Ord(ICS.Sequence = 2));
    if ICS.TNSCount[w] = 0 then
      Continue;
    Res := FBits.ReadBits(1) + 3;
    for f := 0 to ICS.TNSCount[w] - 1 do
    begin
      T := Default(TTNSFilter);
      T.Length := FBits.ReadBits(6 - 2 * Ord(ICS.Sequence = 2));
      if FObjectType = 42 then
        T.Order := FBits.ReadBits(4 - Ord(ICS.Sequence = 2))
      else
        T.Order := FBits.ReadBits(5 - 2 * Ord(ICS.Sequence = 2));
      if ICS.Sequence = 2 then
        MaxOrder := 7
      else
        MaxOrder := 12 + 8 * Ord(FObjectType = 1);
      if FObjectType = 42 then
        MaxOrder := 15;
      if T.Order > MaxOrder then
        raise EPlayerFormat.Create('AAC TNS order exceeds limit');
      if T.Order > 0 then
      begin
        T.Direction := FBits.ReadBits(1);
        Compress := FBits.ReadBits(1);
        Bits := Res - Compress;
        for i := 0 to T.Order - 1 do
        begin
          Value := FBits.ReadBits(Bits);
          if Value and (1 shl (Bits - 1)) <> 0 then
            Dec(Value, 1 shl Bits);
          if Value >= 0 then
            T.Coeff[i] := -Sin(Value * Pi / ((1 shl Res) - 1))
          else
            T.Coeff[i] := -Sin(Value * Pi / ((1 shl Res) + 1));
        end;
      end;
      ICS.TNS[w, f] := T;
    end;
  end;
end;

procedure TAACDecoder.ReadSpectrum(var ICS: TICS);
var
  g, b, w, k, i, Base, Start, Stop, Book, Dim, Radix, Bias, Code, Val, Escape, Index: Integer;
  Values: array[0..3] of Integer;
  Scale, Energy, V: Double;
begin
  if not FSpectralResilience then
    FillChar(ICS.Quantized, SizeOf(ICS.Quantized), 0);
  FillChar(ICS.Spectrum, SizeOf(ICS.Spectrum), 0);
  Base := 0;
  for g := 0 to ICS.Groups - 1 do
  begin
    for b := 0 to ICS.MaxSFB - 1 do
    begin
      Index := g * ICS.MaxSFB + b;
      Book := ICS.BandType[Index];
      if Book >= 16 then
        Book := 11;
      if (Book = 0) or (Book >= 14) then
        Continue;
      Scale := Power(2, ICS.Scale[Index] / 4);
      for w := 0 to ICS.GroupLength[g] - 1 do
      begin
        Start := (Base + w) * FShortLength + ICS.Offsets[b];
        Stop := (Base + w) * FShortLength + ICS.Offsets[b + 1];
        if Book = 13 then
        begin
          Energy := 0;
          for k := Start to Stop - 1 do
          begin
            FRandom := Cardinal(UInt64(FRandom) * 1664525 + 1013904223);
            V := Integer(FRandom);
            ICS.Spectrum[k] := V;
            Energy := Energy + V * V;
          end;
          if Energy > 0 then
          begin
            V := Scale / Sqrt(Energy);
            for k := Start to Stop - 1 do
              ICS.Spectrum[k] := ICS.Spectrum[k] * V;
          end;
          Continue;
        end;
        Dim := 2;
        Radix := 17;
        Bias := 0;
        if Book <= 4 then
        begin
          Dim := 4;
          Radix := 3;
          if Book <= 2 then
            Bias := 1
        end
        else if Book <= 6 then
        begin
          Radix := 9;
          Bias := 4
        end
        else if Book <= 8 then
          Radix := 8
        else if Book <= 10 then
          Radix := 13;
        k := Start;
        while k < Stop do
        begin
          if FSpectralResilience then
          begin
            for i := 0 to Dim - 1 do
              Values[i] := ICS.Quantized[k + i];
          end
          else
          begin
            Code := ReadSpectral(Book);
            for i := Dim - 1 downto 0 do
            begin
              Values[i] := Code mod Radix - Bias;
              Code := Code div Radix
            end;
            if Bias = 0 then
              for i := 0 to Dim - 1 do
                if Values[i] <> 0 then
                  if FBits.ReadBit then
                    Values[i] := -Values[i];
            if Book = 11 then
              for i := 0 to 1 do
                if Abs(Values[i]) = 16 then
                begin
                  Escape := 4;
                  while FBits.ReadBit do
                  begin
                    Inc(Escape);
                    if Escape > 12 then
                      raise EPlayerFormat.Create('AAC escape exceeds limit')
                  end;
                  Val := (1 shl Escape) + Integer(FBits.ReadBits(Escape));
                  if Values[i] < 0 then
                    Val := -Val;
                  Values[i] := Val;
                end;
          end;
          if k + Dim > Stop then
            raise EPlayerFormat.Create('AAC spectral tuple crosses band');
          for i := 0 to Dim - 1 do
          begin
            Val := Values[i];
            ICS.Quantized[k] := Val;
            V := Power(Abs(Val), 4 / 3) * Scale;
            if Val < 0 then
              V := -V;
            ICS.Spectrum[k] := V;
            Inc(k);
          end;
        end;
      end;
    end;
    Inc(Base, ICS.GroupLength[g]);
  end;
end;

procedure TAACDecoder.ReadChannel(var ICS: TICS; Common: Boolean);
var
  Gain, g, b, Book, Count, Part, Esc, Offset, Noise, Intensity, Index, i, PulseCount, PulseBand, Pos: Integer;
  PulsePos, PulseAmp: array[0..3] of Integer;
  NoiseFirst: Boolean;
  RVLC: TAACRVLCInfo;
  ReorderedLength, LongestCodeword: Integer;
  V, Scale: Double;
begin
  Gain := FBits.ReadBits(8);
  if not Common then
    ReadInfo(ICS);
  if ICS.Sequence = 2 then
    Esc := 7
  else
    Esc := 31;
  for g := 0 to ICS.Groups - 1 do
  begin
    b := 0;
    while b < ICS.MaxSFB do
    begin
      if FSectionResilience then
        Book := FBits.ReadBits(5)
      else
        Book := FBits.ReadBits(4);
      if Book = 12 then
        raise EPlayerFormat.Create('Reserved AAC codebook');
      if FSectionResilience and ((Book = 11) or (Book >= 16)) then
        Count := 1
      else
      begin
        Count := 0;
        repeat
          if ICS.Sequence = 2 then
            Part := FBits.ReadBits(3)
          else
            Part := FBits.ReadBits(5);
          Inc(Count, Part);
          if Count > ICS.MaxSFB - b then
            raise EPlayerFormat.Create('AAC section exceeds bands');
        until Part <> Esc;
      end;
      if Count = 0 then
        raise EPlayerFormat.Create('Empty AAC section');
      for i := b to b + Count - 1 do
        ICS.BandType[g * ICS.MaxSFB + i] := Book;
      Inc(b, Count);
    end;
  end;
  if FSFResilience then
    AACReadRVLCHeader(FBits, ICS.BandType, ICS.Groups * ICS.MaxSFB, ICS.Sequence = 2, RVLC)
  else
  begin
    Offset := Gain;
    Noise := Gain - 90;
    Intensity := 0;
    NoiseFirst := True;
    for Index := 0 to ICS.Groups * ICS.MaxSFB - 1 do
    begin
      Book := ICS.BandType[Index];
      case Book of
        0:
          ICS.Scale[Index] := 0;
        14, 15:
          begin
            Inc(Intensity, FBits.ReadVLC(FVLC[0]) - 60);
            ICS.Scale[Index] := EnsureRange(Intensity, -155, 100);
          end;
        13:
          begin
            if NoiseFirst then
            begin
              Inc(Noise, Integer(FBits.ReadBits(9)) - 256);
              NoiseFirst := False
            end
            else
              Inc(Noise, FBits.ReadVLC(FVLC[0]) - 60);
            ICS.Scale[Index] := EnsureRange(Noise, -100, 155);
          end;
      else
        Inc(Offset, FBits.ReadVLC(FVLC[0]) - 60);
        if (Offset < 0) or (Offset > 255) then
          raise EPlayerFormat.Create('AAC scalefactor outside range');
        ICS.Scale[Index] := Offset - 100;
      end;
    end;
  end;
  PulseCount := 0;
  if (FObjectType <> 39) and FBits.ReadBit then
  begin
    if ICS.Sequence = 2 then
      raise EPlayerFormat.Create('AAC pulse tool in short window');
    PulseCount := FBits.ReadBits(2) + 1;
    PulseBand := FBits.ReadBits(6);
    if PulseBand >= Length(ICS.Offsets) - 1 then
      raise EPlayerFormat.Create('Invalid AAC pulse band');
    Pos := ICS.Offsets[PulseBand];
    for i := 0 to PulseCount - 1 do
    begin
      Inc(Pos, FBits.ReadBits(5));
      if Pos >= FFrameLength then
        raise EPlayerFormat.Create('Invalid AAC pulse position');
      PulsePos[i] := Pos;
      PulseAmp[i] := FBits.ReadBits(4);
    end;
  end;
  FillChar(ICS.TNSCount, SizeOf(ICS.TNSCount), 0);
  var TNSPresent := FBits.ReadBit;
  if TNSPresent and not FErrorResilient then
    ReadTNS(ICS);
  ICS.Gain := Default(TSSRGainData);
  if (FObjectType <> 39) and FBits.ReadBit then
  begin
    if FObjectType <> 3 then
      raise EPlayerFormat.Create('Gain control is only valid in AAC SSR');
    ReadAACSSRControl(FBits, ICS.Sequence, ICS.Gain);
  end;
  ReorderedLength := 0;
  LongestCodeword := 0;
  if FSpectralResilience then
  begin
    ReorderedLength := FBits.ReadBits(14);
    LongestCodeword := FBits.ReadBits(6);
    if ReorderedLength > 12288 then
      raise EPlayerFormat.Create('AAC HCR length exceeds channel budget');
  end;
  if FSFResilience then
    AACReadRVLCData(FBits, RVLC, ICS.BandType, ICS.Groups * ICS.MaxSFB, Gain, ICS.Scale);
  if TNSPresent and FErrorResilient then
    ReadTNS(ICS);
  if FSpectralResilience then
    AACReadHCR(
      FBits,
      ReorderedLength,
      LongestCodeword,
      FFrameLength,
      ICS.Groups,
      ICS.MaxSFB,
      IfThen(ICS.Sequence = 2, FShortLength, FFrameLength),
      ICS.GroupLength,
      ICS.BandType,
      ICS.Offsets,
      FVLC,
      ICS.Quantized
    );
  ReadSpectrum(ICS);
  for i := 0 to PulseCount - 1 do
  begin
    Pos := PulsePos[i];
    b := 0;
    while (b < ICS.MaxSFB) and (ICS.Offsets[b + 1] <= Pos) do
      Inc(b);
    if b >= ICS.MaxSFB then
      raise EPlayerFormat.Create('AAC pulse outside coded bands');
    if ICS.BandType[b] in [13, 14, 15] then
      raise EPlayerFormat.Create('AAC pulse in non-spectral band');
    Offset := ICS.Quantized[Pos];
    if Offset > 0 then
      Inc(Offset, PulseAmp[i])
    else
      Dec(Offset, PulseAmp[i]);
    Scale := Power(2, ICS.Scale[b] / 4);
    V := Power(Abs(Offset), 4 / 3) * Scale;
    if Offset < 0 then
      V := -V;
    ICS.Spectrum[Pos] := V;
  end;
end;

procedure TAACDecoder.ReadCoupling(Tag: Integer);
const
  EXPONENTS: array[0..3] of Double = (0.125, 0.25, 0.5, 1.0);
var
  GainCount, Index, Gain, Value, Sign: Integer;
  Point, GlobalGain, Signs: Boolean;
  Scale, Cache: Double;
  C: ^TCoupling;
begin
  C := @FCouplings[Tag];
  if C.Present then
    raise EPlayerFormat.Create('Duplicate AAC coupling element');
  C.Present := True;
  C.Channel := Max(2, FChannels) + Tag;
  EnsureChannels(C.Channel + 1);
  C.Point := 2 * Integer(FBits.ReadBits(1));
  C.Count := Integer(FBits.ReadBits(3)) + 1;
  GainCount := 0;
  for var n := 0 to C.Count - 1 do
  begin
    C.Targets[n].Kind := Ord(FBits.ReadBit);
    C.Targets[n].Tag := FBits.ReadBits(4);
    C.Targets[n].Selection := 2;
    if C.Targets[n].Kind = 1 then
      C.Targets[n].Selection := FBits.ReadBits(2);
    C.Targets[n].GainIndex := GainCount;
    Inc(GainCount, 1 + Ord(C.Targets[n].Selection = 3));
  end;
  Point := FBits.ReadBit;
  if Point or (C.Point = 2) then
    Inc(C.Point);
  Signs := FBits.ReadBit;
  Scale := EXPONENTS[FBits.ReadBits(2)];
  ReadChannel(FICS[C.Channel], False);
  if FObjectType = 1 then
    ApplyPrediction(C.Channel);
  for var n := 0 to GainCount - 1 do
  begin
    Gain := 0;
    Cache := 1;
    GlobalGain := True;
    if n > 0 then
    begin
      if C.Point <> 3 then
        GlobalGain := FBits.ReadBit;
      if GlobalGain then
        Gain := FBits.ReadVLC(FVLC[0]) - 60;
      Cache := Power(2, -Scale * Gain);
    end;
    if C.Point = 3 then
      C.Gains[n, 0] := Cache
    else
    begin
      Index := 0;
      for var g := 0 to FICS[C.Channel].Groups - 1 do
        for var b := 0 to FICS[C.Channel].MaxSFB - 1 do
        begin
          if FICS[C.Channel].BandType[Index] <> 0 then
          begin
            if not GlobalGain then
            begin
              Value := FBits.ReadVLC(FVLC[0]) - 60;
              if Value <> 0 then
              begin
                Inc(Gain, Value);
                Value := Gain;
                Sign := 1;
                if Signs then
                begin
                  Sign := 1 - 2 * (Value and 1);
                  if Value < 0 then
                    Value := -((-Value + 1) div 2)
                  else
                    Value := Value div 2;
                end;
                if Abs(Scale * Value) > 1000 then
                  raise EPlayerFormat.Create('AAC coupling gain overflow');
                Cache := Power(2, -Scale * Value) * Sign;
              end;
            end;
            C.Gains[n, Index] := Cache;
          end;
          Inc(Index);
        end;
    end;
  end;
end;

procedure TAACDecoder.CoupleSpectrum(Source, Target, GainIndex: Integer);
var
  Base, Index, Start, Stop: Integer;
  Gain: Double;
begin
  if FICS[Source].Sequence <> FICS[Target].Sequence then
    raise EPlayerFormat.Create('AAC dependent coupling window mismatch');
  Base := 0;
  Index := 0;
  for var g := 0 to FICS[Source].Groups - 1 do
  begin
    for var b := 0 to FICS[Source].MaxSFB - 1 do
    begin
      if FICS[Source].BandType[Index] <> 0 then
      begin
        Gain := FCouplings[Source - Max(2, FChannels)].Gains[GainIndex, Index];
        for var w := 0 to FICS[Source].GroupLength[g] - 1 do
        begin
          Start := (Base + w) * FShortLength + FICS[Source].Offsets[b];
          Stop := (Base + w) * FShortLength + FICS[Source].Offsets[b + 1];
          for var k := Start to Stop - 1 do
            FICS[Target].Spectrum[k] := FICS[Target].Spectrum[k] + Gain * FICS[Source].Spectrum[k];
        end;
      end;
      Inc(Index);
    end;
    Inc(Base, FICS[Source].GroupLength[g]);
  end;
end;

procedure TAACDecoder.ReadLTP(var ICS: TICS);
const
  COEFFICIENTS: array[0..7] of Double =
    (0.570829, 0.696616, 0.813004, 0.911304, 0.984900, 1.067894, 1.194601, 1.369533);
begin
  if FObjectType = 23 then
  begin
    if FBits.ReadBit then
      ICS.LTPLag := FBits.ReadBits(10);
  end
  else
    ICS.LTPLag := FBits.ReadBits(11);
  if (FObjectType <> 23) and (ICS.LTPLag > FFrameLength * 2) then
    raise EPlayerFormat.Create('Invalid AAC LTP lag');
  ICS.LTPCoefficient := COEFFICIENTS[FBits.ReadBits(3)];
  FillChar(ICS.LTPUsed, SizeOf(ICS.LTPUsed), 0);
  for var b := 0 to Min(ICS.MaxSFB, 40) - 1 do
    ICS.LTPUsed[b] := FBits.ReadBit;
end;

procedure TAACDecoder.ApplyLTP(Channel: Integer);
var
  Time, Frequency: TFloatSamples;
  Predicted: TICS;
  Count, Sequence, Shape, Previous, Flat: Integer;
  Value: Double;
begin
  if not FICS[Channel].LTPPresent or (FICS[Channel].Sequence = 2) then
    Exit;
  if FObjectType = 23 then
    Count := FFrameLength * 2
  else
    Count := Min(FFrameLength * 2, FFrameLength + FICS[Channel].LTPLag);
  SetLength(Time, FFrameLength * 2);
  Sequence := FICS[Channel].Sequence;
  Shape := FICS[Channel].Shape;
  Previous := FPreviousShape[Channel];
  Flat := (FFrameLength - FShortLength) div 2;
  for var n := 0 to Count - 1 do
  begin
    Value := 1;
    if n < FFrameLength then
    begin
      if Sequence <> 3 then
        Value := FWindows[Previous, 0][n]
      else if n < Flat then
        Value := 0
      else if n < Flat + FShortLength then
        Value := FWindows[Previous, 1][n - Flat];
    end
    else
    begin
      if Sequence <> 1 then
        Value := FWindows[Shape, 0][FFrameLength * 2 - 1 - n]
      else if n >= FFrameLength + Flat + FShortLength then
        Value := 0
      else if n >= FFrameLength + Flat then
        Value := FWindows[Shape, 1][FFrameLength + Flat + FShortLength - 1 - n];
    end;
    var HistoryIndex := n + FFrameLength * IfThen(FObjectType = 23, 3, 2) - FICS[Channel].LTPLag;
    Time[n] := FLTPState[Channel, HistoryIndex] * FICS[Channel].LTPCoefficient * Value;
  end;
  FLong.forward(Time, Frequency);
  Predicted := FICS[Channel];
  for var n := 0 to FFrameLength - 1 do
    Predicted.Spectrum[n] := Frequency[n] * 2;
  ApplyTNS(Predicted, True);
  for var b := 0 to Min(FICS[Channel].MaxSFB, 40) - 1 do
    if FICS[Channel].LTPUsed[b] then
      for var n := FICS[Channel].Offsets[b] to FICS[Channel].Offsets[b + 1] - 1 do
        FICS[Channel].Spectrum[n] := FICS[Channel].Spectrum[n] + Predicted.Spectrum[n];
end;

function PredictorFloat16(Value: Single; Mode: Integer): Single;
var
  Bits: Cardinal;
begin
  Move(Value, Bits, SizeOf(Bits));
  case Mode of
    1:
      Bits := Cardinal((UInt64(Bits) + $8000) and $FFFF0000);
    2:
      Bits := Cardinal((UInt64(Bits) + $7FFF + (Bits and 1)) and $FFFF0000);
  else
    Bits := Bits and $FFFF0000;
  end;
  Move(Bits, Result, SizeOf(Result));
end;

procedure TAACDecoder.ApplyPrediction(Channel: Integer);
var
  Band, Bin, Start, Stop: Integer;
  K1, K2, Prediction, E0, E1, Value: Single;
  P: ^TPredictor;
begin
  if FICS[Channel].Sequence = 2 then
  begin
    for Bin := 0 to 1023 do
    begin
      FPredictors[Channel, Bin] := Default(TPredictor);
      FPredictors[Channel, Bin].Var0 := 1;
      FPredictors[Channel, Bin].Var1 := 1;
    end;
    Exit;
  end;
  for Band := 0 to Min(AAC_PRED_SFB_MAX[FRateIndex], Length(FICS[Channel].Offsets) - 1) - 1 do
  begin
    Start := FICS[Channel].Offsets[Band];
    Stop := FICS[Channel].Offsets[Band + 1];
    for Bin := Start to Stop - 1 do
    begin
      P := @FPredictors[Channel, Bin];
      K1 := 0;
      K2 := 0;
      if P.Var0 > 1 then
        K1 := P.Cor0 * PredictorFloat16(0.953125 / P.Var0, 2);
      if P.Var1 > 1 then
        K2 := P.Cor1 * PredictorFloat16(0.953125 / P.Var1, 2);
      Value := K1 * P.R0 + K2 * P.R1;
      Prediction := PredictorFloat16(Value, 1);
      Value := FICS[Channel].Spectrum[Bin];
      if FICS[Channel].PredictorPresent and FICS[Channel].PredictionUsed[Band] then
        Value := Value + Prediction;
      FICS[Channel].Spectrum[Bin] := Value;
      E0 := Value;
      E1 := E0 - K1 * P.R0;
      P.Cor1 := PredictorFloat16(0.90625 * P.Cor1 + P.R1 * E1, 0);
      P.Var1 := PredictorFloat16(0.90625 * P.Var1 + 0.5 * (P.R1 * P.R1 + E1 * E1), 0);
      P.Cor0 := PredictorFloat16(0.90625 * P.Cor0 + P.R0 * E0, 0);
      P.Var0 := PredictorFloat16(0.90625 * P.Var0 + 0.5 * (P.R0 * P.R0 + E0 * E0), 0);
      P.R1 := PredictorFloat16(0.953125 * (P.R0 - K1 * E0), 0);
      P.R0 := PredictorFloat16(0.953125 * E0, 0);
    end;
  end;
  if FICS[Channel].ResetGroup <> 0 then
  begin
    Bin := FICS[Channel].ResetGroup - 1;
    while Bin < 672 do
    begin
      FPredictors[Channel, Bin] := Default(TPredictor);
      FPredictors[Channel, Bin].Var0 := 1;
      FPredictors[Channel, Bin].Var1 := 1;
      Inc(Bin, 30);
    end;
  end;
end;

procedure TAACDecoder.ApplyTNS(var ICS: TICS; Inverse: Boolean);
var
  w, f, i, j, Top, Bottom, MaxBand, Start, Stop, Step, Pos: Integer;
  LPC, Previous: array[0..19] of Double;
  Original: array[0..1023] of Double;
  T: TTNSFilter;
begin
  if ICS.Sequence = 2 then
    MaxBand := FF_TNS_MAX_BANDS_128[FRateIndex]
  else
    MaxBand := FF_TNS_MAX_BANDS_1024[FRateIndex];
  if (FObjectType = 42) and (FRateIndex >= 6) then
    Inc(MaxBand);
  if FObjectType in [23, 39] then
    case FRateIndex of
      0..3:
        MaxBand := 31;
      4:
        MaxBand := 32;
      5:
        MaxBand := 37;
    else
      MaxBand := IfThen(FFrameLength = 480, 30, 31);
    end;
  MaxBand := Min(MaxBand, ICS.MaxSFB);
  for w := 0 to ICS.Windows - 1 do
  begin
    Bottom := Length(ICS.Offsets) - 1;
    for f := 0 to ICS.TNSCount[w] - 1 do
    begin
      T := ICS.TNS[w, f];
      Top := Bottom;
      Bottom := Max(0, Top - T.Length);
      if T.Order = 0 then
        Continue;
      FillChar(LPC, SizeOf(LPC), 0);
      for i := 0 to T.Order - 1 do
      begin
        Previous := LPC;
        // TNS reflection coefficients use r=-coef in the LPC step-up
        // recursion; the all-pole filter below then subtracts the LPC taps.
        for j := 0 to i - 1 do
          LPC[j] := Previous[j] - T.Coeff[i] * Previous[i - j - 1];
        LPC[i] := -T.Coeff[i];
      end;
      Start := ICS.Offsets[Min(Bottom, MaxBand)];
      Stop := ICS.Offsets[Min(Top, MaxBand)];
      Step := 1;
      Pos := Start + w * FShortLength;
      if T.Direction <> 0 then
      begin
        Step := -1;
        Pos := Stop - 1 + w * FShortLength
      end;
      if Inverse then
        Move(ICS.Spectrum, Original, SizeOf(Original));
      for i := 0 to Stop - Start - 1 do
      begin
        for j := 1 to Min(i, T.Order) do
          if Inverse then
            ICS.Spectrum[Pos] := ICS.Spectrum[Pos] + LPC[j - 1] * Original[Pos - j * Step]
          else
            ICS.Spectrum[Pos] := ICS.Spectrum[Pos] - LPC[j - 1] * ICS.Spectrum[Pos - j * Step];
        Inc(Pos, Step);
      end;
    end;
  end;
end;

procedure TAACDecoder.Synthesize(Channel: Integer; out Samples: TFloatSamples);
var
  Full, Temp: TFloatSamples;
  i, w, Sequence, Shape, Previous, Start: Integer;
  Value: Double;
begin
  if (FObjectType = 42) and FUSACCoreMode[Channel] then
  begin
    Samples := FUSACTime[Channel];
    Exit;
  end;
  if (FObjectType = 42) and FUSACPreviousLPD[Channel] then
  begin
    var Spectrum: TFloatSamples;
    SetLength(Spectrum, FFrameLength);
    Move(FICS[Channel].Spectrum[0], Spectrum[0], FFrameLength * SizeOf(Double));
    FUSACLPD[Channel].SynthesizeFD(Spectrum, FICS[Channel].Sequence, FICS[Channel].Shape, Samples, FOverlap[Channel]);
    if FICS[Channel].Sequence = 2 then
    begin
      FUSACRawOverlap[Channel] := Copy(FOverlap[Channel]);
      for var j := 0 to FShortLength - 1 do
        FUSACRawOverlap[Channel][(FFrameLength - FShortLength) div 2 + j] :=
          FUSACRawOverlap[Channel][(FFrameLength - FShortLength) div 2 + j]
          / FWindows[FICS[Channel].Shape, 1][FShortLength - 1 - j];
    end
    else
    begin
      FLong.Execute(FICS[Channel].Spectrum, 0, Temp);
      for var j := 0 to FFrameLength - 1 do
        FUSACRawOverlap[Channel][j] := Temp[FFrameLength + j] / FFrameLength;
    end;
    FPreviousShape[Channel] := FICS[Channel].Shape;
    Exit;
  end;
  if FObjectType = 39 then
  begin
    AACELDSynthesize(FICS[Channel].Spectrum, FLong, FFrameLength, FELDHistory[Channel], Samples);
    Exit;
  end;
  if FObjectType = 3 then
  begin
    if FSSR[Channel] = nil then
      FSSR[Channel] := TAACSSR.Create(FFrameLength);
    FSSR[Channel]
      .Synthesize(FICS[Channel].Spectrum, FICS[Channel].Sequence, FICS[Channel].Shape, FICS[Channel].Gain, Samples);
    Exit;
  end;
  Sequence := FICS[Channel].Sequence;
  Shape := FICS[Channel].Shape;
  Previous := FPreviousShape[Channel];
  SetLength(Full, (2 * FFrameLength));
  if Sequence = 2 then
  begin
    for w := 0 to 7 do
    begin
      FShort.Execute(FICS[Channel].Spectrum, w * FShortLength, Temp);
      Start := ((FFrameLength - FShortLength) div 2) + w * FShortLength;
      for i := 0 to (FShortLength - 1) do
      begin
        if w = 0 then
          Value := FWindows[Previous, 1][i]
        else
          Value := FWindows[Shape, 1][i];
        Full[Start + i] := Full[Start + i] + Temp[i] * Value / FShortLength;
        Full[Start + FShortLength + i] :=
          Full[Start + FShortLength + i]
          + Temp[FShortLength + i] * FWindows[Shape, 1][(FShortLength - 1) - i] / FShortLength;
      end;
    end;
  end
  else
  begin
    FLong.Execute(FICS[Channel].Spectrum, 0, Full);
    if FObjectType = 42 then
      for var j := 0 to FFrameLength - 1 do
        FUSACRawOverlap[Channel][j] := Full[FFrameLength + j] / FFrameLength;
    for i := 0 to (FFrameLength - 1) do
    begin
      Value := FWindows[Previous, 0][i];
      if Sequence in [3, 4] then
      begin
        if i < ((FFrameLength - FShortLength) div 2) then
          Value := 0
        else if i < ((FFrameLength + FShortLength) div 2) then
          Value := FWindows[Previous, 1][i - ((FFrameLength - FShortLength) div 2)]
        else
          Value := 1;
      end;
      Full[i] := Full[i] * Value / FFrameLength;
      Value := FWindows[Shape, 0][(FFrameLength - 1) - i];
      if Sequence in [1, 4] then
      begin
        if i < ((FFrameLength - FShortLength) div 2) then
          Value := 1
        else if i < ((FFrameLength + FShortLength) div 2) then
          Value := FWindows[Shape, 1][((FFrameLength + FShortLength) div 2 - 1) - i]
        else
          Value := 0;
      end;
      Full[FFrameLength + i] := Full[FFrameLength + i] * Value / FFrameLength;
    end;
  end;
  SetLength(Samples, FFrameLength);
  for i := 0 to (FFrameLength - 1) do
  begin
    Samples[i] := Full[i] + FOverlap[Channel, i];
    FOverlap[Channel, i] := Full[FFrameLength + i]
  end;
  if (FObjectType = 42) and (Sequence = 2) then
  begin
    FUSACRawOverlap[Channel] := Copy(FOverlap[Channel]);
    for var j := 0 to FShortLength - 1 do
      FUSACRawOverlap[Channel][(FFrameLength - FShortLength) div 2 + j] :=
        FUSACRawOverlap[Channel][(FFrameLength - FShortLength) div 2 + j] / FWindows[Shape, 1][FShortLength - 1 - j];
  end;
  if FObjectType in [4, 19, 23] then
  begin
    var PastFrames := IfThen(FObjectType = 23, 3, 1);
    Move(FLTPState[Channel, FFrameLength], FLTPState[Channel, 0], FFrameLength * PastFrames * SizeOf(Double));
    Move(Samples[0], FLTPState[Channel, FFrameLength * PastFrames], FFrameLength * SizeOf(Double));
    Move(FOverlap[Channel, 0], FLTPState[Channel, FFrameLength * (PastFrames + 1)], FFrameLength * SizeOf(Double));
  end;
  FPreviousShape[Channel] := Shape;
end;

function TAACDecoder.PacketBytesConsumed: Integer;
begin
  Result := (FBits.Position + 7) div 8
end;

procedure TAACDecoder.Send(const Packet: TMediaPacket);
var
  TypeCode, Count, Seen, Tag, c, i, g, b, w, k, Index, Base, Start, Stop, MS: Integer;
  ElementStart, SecondICS, ElementEnd, ElementIndex, ChannelBase, LastElement, Core: Integer;
  ProgramConfig: TAACProgram;
  Visited: array[0..95] of Boolean;
  Mixed: Double;
  Common, Align: Boolean;
  Mask: array[0..119] of Boolean;
  L, R, Scale: Double;
  Samples: array[0..127] of TFloatSamples;
  Frame: TAudioFrame;

  procedure ApplyCouplings(Point: Integer);
  var
    Target, GainIndex, First, Last: Integer;
  begin
    for var Coupling in FCouplings do
      if Coupling.Present and (Coupling.Point = Point) then
        for var n := 0 to Coupling.Count - 1 do
        begin
          Target := -1;
          for var e := 0 to High(FElements) do
            if (FElements[e].Kind = Coupling.Targets[n].Kind) and (FElements[e].Tag = Coupling.Targets[n].Tag) then
              Target := e;
          if Target < 0 then
            raise EPlayerFormat.Create('AAC coupling targets an absent element');
          GainIndex := Coupling.Targets[n].GainIndex;
          First := FElements[Target].FirstChannel;
          Last := First + FElements[Target].ChannelCount - 1;
          if Coupling.Targets[n].Selection = 1 then
            Inc(First);
          if Coupling.Targets[n].Selection = 2 then
            Last := First;
          for var Channel := First to Last do
          begin
            if Point = 3 then
            begin
              if Length(Samples[Channel]) <> Length(Samples[Coupling.Channel]) then
                raise EPlayerFormat.Create('AAC coupling sample rate mismatch');
              for var j := 0 to High(Samples[Channel]) do
                Samples[Channel, j] :=
                  Samples[Channel, j] + Coupling.Gains[GainIndex, 0] * Samples[Coupling.Channel, j];
            end
            else
              CoupleSpectrum(Coupling.Channel, Channel, GainIndex);
            if Coupling.Targets[n].Selection = 3 then
              Inc(GainIndex);
          end;
        end;
  end;
{$IFDEF PLAYER_AAC_TRACE}

  procedure Trace;
  var
    Channel, Band, Window, Filter, Noise, Intensity, TNS: Integer;
  begin
    Write('aac_diag=', Frame.SamplePosition);
    for Channel := 0 to FChannels - 1 do
    begin
      Noise := 0;
      Intensity := 0;
      TNS := 0;
      for Band := 0 to FICS[Channel].Groups * FICS[Channel].MaxSFB - 1 do
      begin
        if FICS[Channel].BandType[Band] = 13 then
          Inc(Noise);
        if FICS[Channel].BandType[Band] in [14, 15] then
          Inc(Intensity);
      end;
      for Window := 0 to FICS[Channel].Windows - 1 do
        for Filter := 0 to FICS[Channel].TNSCount[Window] - 1 do
          Inc(TNS, FICS[Channel].TNS[Window, Filter].Order);
      Write(',', FICS[Channel].Sequence, ',', FICS[Channel].Shape, ',', Noise, ',', Intensity, ',', TNS);
    end;
    Writeln;
  end;
{$ENDIF}



begin
  if FRate = 0 then
    raise EPlayerError.Create('Configure AAC decoder first');
  if FOutput.Count >= 16 then
    raise EPlayerError.Create('Drain AAC output before sending more packets');
  FPacketData := Packet.Data;
  FCRCRegions := nil;
  FillChar(FCouplings, SizeOf(FCouplings), 0);
  FBits.Init(Packet.Data);
  Seen := 0;
  FillChar(Visited, SizeOf(Visited), 0);
  LastElement := -1;
  for var Element in FElements do
    if Element.SBR <> nil then
      Element.SBR.BeginFrame;
  if FObjectType = 42 then
  begin
    ReadUSACFrame;
    Seen := FChannels;
  end
  else
    repeat
      if FErrorResilient then
      begin
        if LastElement + 1 >= Length(FElements) then
          Break;
        TypeCode := FElements[LastElement + 1].Kind;
      end
      else
        TypeCode := FBits.ReadBits(3);
      case TypeCode of
        7:
          Break;
        0, 1, 3:
          begin
            ElementStart := FBits.Position;
            if FErrorResilient then
            begin
              Tag := FElements[LastElement + 1].Tag;
              if FObjectType <> 39 then
                FBits.Skip(4);
            end
            else
              Tag := FBits.ReadBits(4);
            ElementIndex := -1;
            for var n := 0 to High(FElements) do
              if (FElements[n].Kind = TypeCode) and (FElements[n].Tag = Tag) then
                ElementIndex := n;
            if ElementIndex < 0 then
              raise EPlayerFormat.Create('AAC element absent from channel configuration');
            ChannelBase := FElements[ElementIndex].FirstChannel;
            if Visited[ChannelBase] then
              raise EPlayerFormat.Create('Duplicate AAC channel element');
            Visited[ChannelBase] := True;
            LastElement := ElementIndex;
            FSBR := FElements[ElementIndex].SBR;
            if TypeCode <> 1 then
            begin
              ReadChannel(FICS[ChannelBase], False);
              AddCRCRegion(ElementStart, FBits.Position - ElementStart, 192);
              if FObjectType = 1 then
                ApplyPrediction(ChannelBase);
              Inc(Seen);
            end
            else
            begin
              Common := (FObjectType = 39) or FBits.ReadBit;
              FillChar(Mask, SizeOf(Mask), 0);
              if Common then
              begin
                ReadInfo(FICS[ChannelBase]);
                var RightLag := FICS[ChannelBase + 1].LTPLag;
                FICS[ChannelBase + 1] := FICS[ChannelBase];
                FICS[ChannelBase + 1].LTPLag := RightLag;
                if (FObjectType in [4, 19, 23]) and FICS[ChannelBase].PredictorPresent then
                begin
                  FICS[ChannelBase + 1].LTPPresent := FBits.ReadBit;
                  if FICS[ChannelBase + 1].LTPPresent then
                    ReadLTP(FICS[ChannelBase + 1]);
                end;
                MS := FBits.ReadBits(2);
                if MS = 3 then
                  raise EPlayerFormat.Create('Reserved AAC MS mode');
                for i := 0 to FICS[ChannelBase].Groups * FICS[ChannelBase].MaxSFB - 1 do
                  if MS = 1 then
                    Mask[i] := FBits.ReadBit
                  else
                    Mask[i] := MS = 2;
              end;
              ReadChannel(FICS[ChannelBase], Common);
              SecondICS := FBits.Position;
              ReadChannel(FICS[ChannelBase + 1], Common);
              ElementEnd := FBits.Position;
              AddCRCRegion(ElementStart, ElementEnd - ElementStart, 192);
              AddCRCRegion(SecondICS, ElementEnd - SecondICS, 128);
              if Common then
              begin
                Base := 0;
                for g := 0 to FICS[ChannelBase].Groups - 1 do
                begin
                  for b := 0 to FICS[ChannelBase].MaxSFB - 1 do
                  begin
                    Index := g * FICS[ChannelBase].MaxSFB + b;
                    for w := 0 to FICS[ChannelBase].GroupLength[g] - 1 do
                    begin
                      Start := (Base + w) * FShortLength + FICS[ChannelBase].Offsets[b];
                      Stop := (Base + w) * FShortLength + FICS[ChannelBase].Offsets[b + 1];
                      if Mask[Index]
                        and not (FICS[ChannelBase].BandType[Index] in [13, 14, 15])
                        and not (FICS[ChannelBase + 1].BandType[Index] in [13, 14, 15]) then
                        for k := Start to Stop - 1 do
                        begin
                          L := FICS[ChannelBase].Spectrum[k];
                          R := FICS[ChannelBase + 1].Spectrum[k];
                          FICS[ChannelBase].Spectrum[k] := L + R;
                          FICS[ChannelBase + 1].Spectrum[k] := L - R
                        end;
                    end;
                  end;
                  Inc(Base, FICS[ChannelBase].GroupLength[g]);
                end;
              end;
              if FObjectType = 1 then
              begin
                ApplyPrediction(ChannelBase);
                ApplyPrediction(ChannelBase + 1);
              end;
              if Common then
              begin
                Base := 0;
                for g := 0 to FICS[ChannelBase].Groups - 1 do
                begin
                  for b := 0 to FICS[ChannelBase].MaxSFB - 1 do
                  begin
                    Index := g * FICS[ChannelBase].MaxSFB + b;
                    for w := 0 to FICS[ChannelBase].GroupLength[g] - 1 do
                    begin
                      Start := (Base + w) * FShortLength + FICS[ChannelBase].Offsets[b];
                      Stop := (Base + w) * FShortLength + FICS[ChannelBase].Offsets[b + 1];
                      if FICS[ChannelBase + 1].BandType[Index] in [14, 15] then
                      begin
                        Scale :=
                          Power(2, -FICS[ChannelBase + 1].Scale[Index] / 4)
                          * (2 * (FICS[ChannelBase + 1].BandType[Index] - 14) - 1);
                        if Mask[Index] then
                          Scale := -Scale;
                        for k := Start to Stop - 1 do
                          FICS[ChannelBase + 1].Spectrum[k] := FICS[ChannelBase].Spectrum[k] * Scale;
                      end;
                    end;
                  end;
                  Inc(Base, FICS[ChannelBase].GroupLength[g]);
                end;
              end;
              Inc(Seen, 2);
            end;
          end;
        2:
          begin
            ElementStart := FBits.Position;
            Tag := FBits.ReadBits(4);
            ReadCoupling(Tag);
            LastElement := -2 - Tag;
            FSBR := FCouplingSBR[Tag];
            AddCRCRegion(ElementStart, FBits.Position - ElementStart, 192);
          end;
        4:
          begin // data_stream_element
            ElementStart := FBits.Position;
            FBits.Skip(4);
            Align := FBits.ReadBit;
            Count := FBits.ReadBits(8);
            if Count = 255 then
              Inc(Count, FBits.ReadBits(8));
            if Align then
              FBits.Align;
            FBits.Skip(Count * 8);
            AddCRCRegion(ElementStart, FBits.Position - ElementStart, FBits.Position - ElementStart);
          end;
        5:
          begin
            if Seen <> 0 then
              raise EPlayerFormat.Create('AAC PCE follows channel element');
            ElementStart := FBits.Position;
            ParseAACProgram(FBits, FRateIndex, Core, ProgramConfig);
            if (Core <> FObjectType) or (Length(ProgramConfig) <> Length(FElements)) then
              raise EPlayerFormat.Create('AAC PCE disagrees with configured program');
            for var n := 0 to High(FElements) do
            begin
              if (FElements[n].Kind <> ProgramConfig[n].Kind) or (FElements[n].Position <> ProgramConfig[n].Position) then
                raise EPlayerFormat.Create('AAC PCE changes channel layout');
              FElements[n].Tag := ProgramConfig[n].Tag;
            end;
            AddCRCRegion(ElementStart, FBits.Position - ElementStart, FBits.Position - ElementStart);
          end;
        6:
          begin // fill_element
            Count := FBits.ReadBits(4);
            if Count = 15 then
              Count := Count + Integer(FBits.ReadBits(8)) - 1;
            if Count > 0 then
            begin
              i := FBits.ReadBits(4);
              if i in [13, 14] then
              begin
                if LastElement = -1 then
                  raise EPlayerFormat.Create('SBR extension precedes AAC channel element');
                if FSBR = nil then
                begin
                  var ConfiguredSBR := False;
                  for var Element in FElements do
                    ConfiguredSBR := ConfiguredSBR or (Element.SBR <> nil);
                  if not ConfiguredSBR then
                    FOutputRate := FRate * 2;
                  if LastElement < -1 then
                  begin
                    FSBR := TAACSBR.Create(FRate * 2, 1, FOutputRate = FRate, FFrameLength);
                    FCouplingSBR[-2 - LastElement] := FSBR;
                  end
                  else
                  begin
                    FSBR :=
                      TAACSBR.Create(FRate * 2, FElements[LastElement].ChannelCount, FOutputRate = FRate, FFrameLength);
                    if FChannels = 1 then
                      FSBR.EnablePS;
                    FElements[LastElement].SBR := FSBR;
                  end;
                end;
                FSBR.ReadExtension(FBits, Count, i = 14);
              end
              else
                FBits.Skip(Count * 8 - 4);
            end;
          end;
      else
        raise EPlayerUnsupported.CreateFmt('AAC element %d is not supported', [TypeCode]);
      end;
    until False;
  if Seen <> FChannels then
    raise EPlayerFormat.Create('AAC packet has no complete channel element');
  if FOutputRate <> FRate then
    for var n := 0 to High(FElements) do
      if FElements[n].SBR = nil then
        FElements[n].SBR := TAACSBR.Create(FRate * 2, FElements[n].ChannelCount, FOutputRate = FRate, FFrameLength);
  Frame := Default(TAudioFrame);
  Frame.SampleRate := FOutputRate;
  Frame.Channels := Min(2, FChannels);
  for var Element in FElements do
    if (Element.SBR <> nil) and Element.SBR.ParametricStereo then
      Frame.Channels := 2;
  Frame.Frames := FFrameLength;
  Frame.PTS := Packet.PTS;
  if FOutputRate <> FRate then
    Frame.Frames := FFrameLength * 2;
  Frame.SamplePosition := RescaleTime(Packet.SourcePTS, Packet.SourceTimeScale, FOutputRate);
{$IFDEF PLAYER_AAC_TRACE}
  Trace;
{$ENDIF}
  SetLength(Frame.Samples, Frame.Frames * Frame.Channels);
  for var Coupling in FCouplings do
    if Coupling.Present then
    begin
      if FObjectType in [4, 19, 23] then
        ApplyLTP(Coupling.Channel);
      ApplyTNS(FICS[Coupling.Channel]);
      if Coupling.Point = 3 then
        Synthesize(Coupling.Channel, Samples[Coupling.Channel]);
    end;
  ApplyCouplings(0);
  for c := 0 to FChannels - 1 do
  begin
    if FObjectType in [4, 19, 23] then
      ApplyLTP(c);
    ApplyTNS(FICS[c]);
  end;
  ApplyCouplings(1);
  for c := 0 to FChannels - 1 do
    Synthesize(c, Samples[c]);
  for var Element in FElements do
    if Element.SBR <> nil then
    begin
      if Element.SBR.ParametricStereo then
        Element.SBR.ProcessStereo(Samples[Element.FirstChannel], Samples[Element.FirstChannel + 1])
      else
        for c := 0 to Element.ChannelCount - 1 do
          Element.SBR.Process(c, Samples[Element.FirstChannel + c]);
    end;
  for var n := 0 to High(FCouplings) do
    if FCouplings[n].Present and (FCouplings[n].Point = 3) then
    begin
      var HasSBR := FOutputRate <> FRate;
      for var Element in FElements do
        HasSBR := HasSBR or (Element.SBR <> nil);
      if HasSBR then
      begin
        if FCouplingSBR[n] = nil then
          FCouplingSBR[n] := TAACSBR.Create(FRate * 2, 1, FOutputRate = FRate, FFrameLength);
        FCouplingSBR[n].Process(0, Samples[FCouplings[n].Channel]);
      end;
    end;
  ApplyCouplings(3);
  for i := 0 to Frame.Frames - 1 do
    for var OutputChannel := 0 to Frame.Channels - 1 do
    begin
      if FChannels <= 2 then
        Mixed := Samples[OutputChannel][i]
      else
      begin
        Mixed := 0;
        for c := 0 to FChannels - 1 do
          Mixed := Mixed + Samples[c][i] * FDownmix[c, OutputChannel];
      end;
      Frame.Samples[i * Frame.Channels + OutputChannel] := Round(EnsureRange(Mixed, -32768.0, 32767.0));
    end;
  FOutput.Enqueue(Frame);
end;

end.

