unit FMXAudio.AAC.USAC.LPD;

// USAC LPD synthesis, adapted from Android libxaac (Ittiam Systems).
// Copyright (C) 2018 The Android Open Source Project. Apache-2.0.

interface

uses Core.Bitstream,
  FMXAudio.Bitstream, FMXAudio.Transform, FMXAudio.AAC.USAC,
  FMXAudio.AAC.USAC.LPC;

type
  TUSACLPD = class
  private
    type
      TLPDFrame = record
        Modes, Noise, Gain, Energy: array[0..3] of Integer;
        ACB, Gains: array[0..3, 0..3] of Integer;
        Pulse: array[0..3, 0..3, 0..7] of Integer;
        PitchFilter: array[0..3, 0..3] of Boolean;
        TCX, FAC: array[0..3] of TFloatSamples;
        StartFAC: TFloatSamples;
        StartGain, CoreMode: Integer;
        FirstLPD, ShortFAC, BassFilter: Boolean;
        LPC: TUSACLSFRows;
      end;
  private
    FLength, FRate, FSubframe, FDelay, FPreviousMode: Integer;
    FLSF: TUSACLSF;
    FSynthHistory, FExcHistory, FAlias, FBassHistory: TFloatSamples;
    FSynth, FExc: TFloatSamples;
    FPitch: TArray<Integer>;
    FPitchGain: TFloatSamples;
    FPreviousLPC: array[0..1] of TUSACLPC;
    FGainThreshold, FFACGain: Double;
    FFACFrequency: TFloatSamples;
    FNoiseSeed: Cardinal;
    FBassActive: Boolean;
    FFDFAC: TFloatSamples;
    FFDFACGain: Integer;
    procedure ReadFrame(var Bits: TBitReader; var Arithmetic: TAACArithState; Independent: Boolean; out Frame: TLPDFrame);
    procedure SynthesizeTCX(const Frame: TLPDFrame; Block: Integer; const OldLSF, NewLSF: TUSACLSF);
    procedure SynthesizeACELP(const Frame: TLPDFrame; Block: Integer; const OldLSF, NewLSF: TUSACLSF);
    procedure BassFilter(const Frame: TLPDFrame; out Samples: TFloatSamples; LookaheadOverride: Integer = -1; ProcessBlocks: Integer = -1
);
  public
    constructor Create(FrameLength, Rate: Integer);
    procedure Reset;
    procedure ReadFDTransition(var Bits: TBitReader; ShortWindow: Boolean);
    procedure SynthesizeFD(const Spectrum: TFloatSamples; Sequence, Shape: Integer; out Samples, Overlap: TFloatSamples);
    procedure Decode(var Bits: TBitReader; var Arithmetic: TAACArithState; Independent: Boolean; var NoiseSeed: Cardinal; const FDOverlap: TFloatSamples; PreviousShort: Boolean; out Samples: TFloatSamples);
  end;

implementation

uses
  System.Math, System.SysUtils, FMXAudio.Types;

const
  PREFIX = 1024;
  CODE_BITS: array[0..7, 0..3] of Integer = (
    (5, 5, 5, 5),
    (9, 9, 5, 5),
    (9, 9, 9, 9),
    (13, 13, 9, 9),
    (13, 13, 13, 13),
    (16, 16, 16, 16),
    (1, 5, 1, 5),
    (1, 5, 5, 5)
  );
  ACELP_GAIN: array[0..255] of Double = (
    0.012445,
    0.215546,
    0.028326,
    0.965442,
    0.053042,
    0.525819,
    0.065409,
    1.495322,
    0.078212,
    2.323725,
    0.100504,
    0.751276,
    0.112617,
    3.427530,
    0.113124,
    0.309583,
    0.121763,
    1.140685,
    0.143515,
    7.519609,
    0.162430,
    0.568752,
    0.164940,
    1.904113,
    0.165429,
    4.947562,
    0.194985,
    0.855463,
    0.213527,
    1.281019,
    0.223544,
    0.414672,
    0.243135,
    2.781766,
    0.257180,
    1.659565,
    0.269488,
    0.636749,
    0.286539,
    1.003938,
    0.328124,
    2.225436,
    0.328761,
    0.330278,
    0.336807,
    11.500983,
    0.339794,
    3.805726,
    0.344454,
    1.494626,
    0.346165,
    0.738748,
    0.363605,
    1.141454,
    0.398729,
    0.517614,
    0.415276,
    2.928666,
    0.416282,
    0.862935,
    0.423421,
    1.873310,
    0.444151,
    0.202244,
    0.445842,
    1.301113,
    0.455671,
    5.519512,
    0.484764,
    0.387607,
    0.488696,
    0.967884,
    0.488730,
    0.666771,
    0.508189,
    1.516224,
    0.508792,
    2.348662,
    0.531504,
    3.883870,
    0.548649,
    1.112861,
    0.551182,
    0.514986,
    0.564397,
    1.742030,
    0.566598,
    0.796454,
    0.589255,
    3.081743,
    0.598816,
    1.271936,
    0.617654,
    0.333501,
    0.619073,
    2.040522,
    0.625282,
    0.950244,
    0.630798,
    0.594883,
    0.638918,
    4.863197,
    0.650102,
    1.464846,
    0.668412,
    0.747138,
    0.669490,
    2.583027,
    0.683757,
    1.125479,
    0.691216,
    1.739274,
    0.718441,
    3.297789,
    0.722608,
    0.902743,
    0.728827,
    2.194941,
    0.729586,
    0.633849,
    0.730907,
    7.432957,
    0.731017,
    0.431076,
    0.731543,
    1.387847,
    0.759183,
    1.045210,
    0.768606,
    1.789648,
    0.771245,
    4.085637,
    0.772613,
    0.778145,
    0.786483,
    1.283204,
    0.792467,
    2.412891,
    0.802393,
    0.544588,
    0.807156,
    0.255978,
    0.814280,
    1.544409,
    0.817839,
    0.938798,
    0.826959,
    2.910633,
    0.830453,
    0.684066,
    0.833431,
    1.171532,
    0.841208,
    1.908628,
    0.846440,
    5.333522,
    0.868280,
    0.841519,
    0.868662,
    1.435230,
    0.871449,
    3.675784,
    0.881317,
    2.245058,
    0.882020,
    0.480249,
    0.882476,
    1.105804,
    0.902856,
    0.684850,
    0.904419,
    1.682113,
    0.909384,
    2.787801,
    0.916558,
    7.500981,
    0.918444,
    0.950341,
    0.919721,
    1.296319,
    0.940272,
    4.682978,
    0.940273,
    1.991736,
    0.950291,
    3.507281,
    0.957455,
    1.116284,
    0.957723,
    0.793034,
    0.958217,
    1.497824,
    0.962628,
    2.514156,
    0.968507,
    0.588605,
    0.974739,
    0.339933,
    0.991738,
    1.750201,
    0.997210,
    0.936131,
    1.002422,
    1.250008,
    1.006040,
    2.167232,
    1.008848,
    3.129940,
    1.014404,
    5.842819,
    1.027798,
    4.287319,
    1.039404,
    1.489295,
    1.039628,
    8.947958,
    1.043214,
    0.765733,
    1.045089,
    2.537806,
    1.058994,
    1.031496,
    1.060415,
    0.478612,
    1.072132,
    12.8,
    1.074778,
    1.910049,
    1.076570,
    15.9999,
    1.107853,
    3.843067,
    1.110673,
    1.228576,
    1.110969,
    2.758471,
    1.140058,
    1.603077,
    1.155384,
    0.668935,
    1.176229,
    6.717108,
    1.179008,
    2.011940,
    1.187735,
    0.963552,
    1.199569,
    4.891432,
    1.206311,
    3.316329,
    1.215323,
    2.507536,
    1.223150,
    1.387102,
    1.296012,
    9.684225
  );
  ACELP_INTERPOL: array[0..64] of Double = (
    0.940000,
    0.856390,
    0.632268,
    0.337560,
    0.059072,
    -0.131059,
    -0.199393,
    -0.158569,
    -0.056359,
    0.047606,
    0.106749,
    0.103705,
    0.052062,
    -0.015182,
    -0.063705,
    -0.073660,
    -0.046497,
    -0.000983,
    0.038227,
    0.053143,
    0.040059,
    0.009308,
    -0.021674,
    -0.037767,
    -0.033186,
    -0.013028,
    0.010702,
    0.025901,
    0.026318,
    0.013821,
    -0.003645,
    -0.016813,
    -0.019855,
    -0.012766,
    -0.000530,
    0.010080,
    0.014122,
    0.010657,
    0.002594,
    -0.005363,
    -0.009344,
    -0.008101,
    -0.003182,
    0.002330,
    0.005635,
    0.005562,
    0.002844,
    -0.000627,
    -0.002993,
    -0.003362,
    -0.002044,
    -0.000116,
    0.001315,
    0.001692,
    0.001151,
    0.000259,
    -0.000417,
    -0.000618,
    -0.000434,
    -0.000133,
    0.000063,
    0.000098,
    0.000048,
    0.000007,
    0.000000
  );
  ACELP_BASS: array[0..12] of Double = (
    0.088250,
    0.086410,
    0.081074,
    0.072768,
    0.062294,
    0.050623,
    0.038774,
    0.027692,
    0.018130,
    0.010578,
    0.005221,
    0.001946,
    0.000385
  );

procedure ReadFAC(var Bits: TBitReader; Count: Integer; out Data: TFloatSamples);
var
  V: TUSACAVQ;
begin
  SetLength(Data, Count);
  for var i := 0 to Count div 8 - 1 do
  begin
    USACDecodeAVQ(Bits, V);
    for var j := 0 to 7 do
      Data[i * 8 + j] := V[j];
  end;
end;

procedure DCTIV(const Data: TFloatSamples; out Result: TFloatSamples);
var
  Transform: TInverseMDCT;
  Full, Coefficients: TFloatSamples;
begin
  Transform := TInverseMDCT.Create(Length(Data));
  SetLength(Coefficients, Length(Data));
  for var i := 0 to Length(Data) div 2 - 1 do
  begin
    Coefficients[i * 2] := Data[i];
    Coefficients[i * 2 + 1] := Data[Length(Data) - 1 - i];
  end;
  try
    Transform.Execute(Coefficients, 0, Full);
  finally
    Transform.Free;
  end;
  SetLength(Result, Length(Data));
  for var i := 0 to High(Result) do
    Result[i] := -Full[Length(Data) * 3 div 2 - 1 - i];
end;

procedure Weighted(const LPC: TUSACLPC; out A: TUSACLPC);
var
  Weight: Double;
begin
  Weight := 1;
  for var i := 0 to 16 do
  begin
    A[i] := LPC[i] * Weight;
    Weight := Weight * 0.92;
  end;
end;

procedure LPCGains(const A: TUSACLPC; Count: Integer; out Gains: TFloatSamples);
var
  Re, Im, Phase: Double;
begin
  SetLength(Gains, Count);
  for var k := 0 to Count - 1 do
  begin
    Re := 0;
    Im := 0;
    for var i := 0 to 16 do
    begin
      Phase := Pi * (k + 0.5) * i / Count;
      Re := Re + A[i] * Cos(Phase);
      Im := Im - A[i] * Sin(Phase);
    end;
    Gains[k] := 1 / (Sqrt(Re * Re + Im * Im) + 1.1920928955078125E-7);
  end;
end;

procedure PulseOne(Index, M, Offset, Track: Integer; var Code: TFloatSamples);
var
  Position: Integer;
begin
  Position := ((Index and ((1 shl M) - 1)) + Offset) * 4 + Track;
  if Index and (1 shl M) <> 0 then
    Code[Position] := Code[Position] - 1
  else
    Code[Position] := Code[Position] + 1;
end;

procedure PulseTwo(Index, M, Offset, Track: Integer; var Code: TFloatSamples);
var
  P0, P1, Sign: Integer;
begin
  P0 := ((Index shr M) and ((1 shl M) - 1)) + Offset;
  P1 := (Index and ((1 shl M) - 1)) + Offset;
  Sign := 1;
  if Index and (1 shl (2 * M)) <> 0 then
    Sign := -1;
  Code[4 * P0 + Track] := Code[4 * P0 + Track] + Sign;
  if P1 < P0 then
    Sign := -Sign;
  Code[4 * P1 + Track] := Code[4 * P1 + Track] + Sign;
end;

procedure PulseThree(Index, M, Offset, Track: Integer; var Code: TFloatSamples);
var
  Shift: Integer;
begin
  Shift := Offset;
  if Index and (1 shl (2 * M - 1)) <> 0 then
    Inc(Shift, 1 shl (M - 1));
  PulseTwo(Index and ((1 shl (2 * M - 1)) - 1), M - 1, Shift, Track, Code);
  PulseOne(Index shr (2 * M), M, Offset, Track, Code);
end;

procedure PulseFour(Index, Track: Integer; var Code: TFloatSamples);
var
  Offset, Shift: Integer;
begin
  case (Index shr 14) and 3 of
    0:
      begin
        Offset := 0;
        if Index and (1 shl 13) <> 0 then
          Offset := 8;
        Shift := Offset;
        if Index and 32 <> 0 then
          Inc(Shift, 4);
        PulseTwo(Index and 31, 2, Shift, Track, Code);
        PulseTwo((Index shr 6) and 127, 3, Offset, Track, Code);
      end;
    1:
      begin
        PulseOne(Index shr 10, 3, 0, Track, Code);
        PulseThree(Index, 3, 8, Track, Code);
      end;
    2:
      begin
        PulseTwo(Index shr 7, 3, 0, Track, Code);
        PulseTwo(Index, 3, 8, Track, Code);
      end;
    3:
      begin
        PulseThree(Index shr 4, 3, 0, Track, Code);
        PulseOne(Index, 3, 8, Track, Code);
      end;
  end;
end;

procedure LPCFromLSP(const LSP: TUSACLSF; out LPC: TUSACLPC);
var
  LSF: TUSACLSF;
begin
  for var i := 0 to 15 do
    LSF[i] := ArcCos(EnsureRange(LSP[i], -1.0, 1.0)) * 6400 / Pi;
  USACLSFToLPC(LSF, LPC);
end;

procedure Synthesis(const A: TUSACLPC; var Signal: TFloatSamples; Start, Count: Integer);
begin
  for var i := Start to Start + Count - 1 do
    for var j := 1 to 16 do
      Signal[i] := Signal[i] - A[j] * Signal[i - j];
end;

constructor TUSACLPD.Create(FrameLength, Rate: Integer);
begin
  inherited Create;
  if not ((FrameLength = 768) or (FrameLength = 1024)) then
    raise EPlayerFormat.Create('Invalid USAC LPD frame size');
  FLength := FrameLength;
  FRate := Rate;
  FSubframe := FLength div 4;
  FDelay := (FLength div 128 - 1) * 64;
  Reset;
end;

procedure TUSACLPD.Reset;
begin
  SetLength(FSynthHistory, PREFIX + FDelay);
  SetLength(FExcHistory, PREFIX);
  FillChar(FSynthHistory[0], Length(FSynthHistory) * SizeOf(Double), 0);
  FillChar(FExcHistory[0], Length(FExcHistory) * SizeOf(Double), 0);
  SetLength(FAlias, 1 + FSubframe);
  FillChar(FAlias[0], Length(FAlias) * SizeOf(Double), 0);
  SetLength(FBassHistory, 76);
  FillChar(FBassHistory[0], Length(FBassHistory) * SizeOf(Double), 0);
  SetLength(FPitch, FLength div 64 + FDelay div 64);
  SetLength(FPitchGain, Length(FPitch));
  for var i := 0 to High(FPitch) do
  begin
    FPitch[i] := 64;
    FPitchGain[i] := 0;
  end;
  for var i := 0 to 15 do
    FLSF[i] := (i + 1) * 6400 / 17;
  FPreviousMode := -1;
  FGainThreshold := 0;
  FFACGain := 0;
  FFACFrequency := nil;
  FillChar(FPreviousLPC, SizeOf(FPreviousLPC), 0);
  FNoiseSeed := $3039;
  FBassActive := False;
end;

procedure TUSACLPD.ReadFDTransition(var Bits: TBitReader; ShortWindow: Boolean);
begin
  FFDFAC := nil;
  if Bits.ReadBit then
  begin
    FFDFACGain := Bits.ReadBits(7);
    ReadFAC(Bits, IfThen(ShortWindow, FLength div 16, FLength div 8), FFDFAC);
  end;
end;

procedure TUSACLPD.SynthesizeFD(const Spectrum: TFloatSamples; Sequence, Shape: Integer; out Samples, Overlap: TFloatSamples);
var
  Transform: TInverseMDCT;
  Full, Temp, Window, PreviousWindow, Prior, PackedData, Signal, Correction: TFloatSamples;
  A: TUSACLPC;
  L, Flat, NShort, Start: Integer;
begin
  NShort := FLength div 8;
  L := IfThen(Sequence = 2, FLength div 16, FLength div 8);
  Flat := FLength div 2 - L;
  SetLength(Prior, FLength);
  for var i := 0 to FLength div 2 - 1 do
    Prior[i] := FSynthHistory[PREFIX - 64 + i];
  for var i := 0 to FSubframe - 1 do
    Prior[FLength div 2 - FSubframe div 2 + i] := FAlias[1 + i];
  SetLength(Full, 2 * FLength);
  Window := AACWindow(IfThen(Sequence = 2, NShort, FLength), Shape = 1);
  PreviousWindow := AACWindow(2 * L, False);
  if Sequence = 2 then
  begin
    Transform := TInverseMDCT.Create(NShort);
    try
      for var w := 0 to 7 do
      begin
        Transform.Execute(Spectrum, w * NShort, Temp);
        Start := (FLength - NShort) div 2 + w * NShort;
        for var i := 0 to NShort - 1 do
        begin
          Full[Start + i] := Full[Start + i] + Temp[i] * IfThen(w = 0, PreviousWindow[i], Window[i]) / NShort;
          Full[Start + NShort + i] := Full[Start + NShort + i] + Temp[NShort + i] * Window[NShort - 1 - i] / NShort;
        end;
      end;
    finally
      Transform.Free;
    end;
  end
  else
  begin
    Transform := TInverseMDCT.Create(FLength);
    try
      Transform.Execute(Spectrum, 0, Full);
    finally
      Transform.Free;
    end;
    for var i := 0 to FLength - 1 do
    begin
      if i < Flat then
        Full[i] := 0
      else if i < Flat + 2 * L then
        Full[i] := Full[i] * PreviousWindow[i - Flat] / FLength
      else
        Full[i] := Full[i] / FLength;
      if Sequence in [1, 4] then
      begin
        if i < (FLength - NShort) div 2 then
          Full[FLength + i] := Full[FLength + i] / FLength
        else if i < (FLength + NShort) div 2 then
          Full[FLength + i] :=
            Full[FLength + i] * AACWindow(NShort, Shape = 1)[(FLength + NShort) div 2 - 1 - i] / FLength
        else
          Full[FLength + i] := 0;
      end
      else
        Full[FLength + i] := Full[FLength + i] * Window[FLength - 1 - i] / FLength;
    end;
  end;
  if Length(FFDFAC) <> 0 then
  begin
    SetLength(PackedData, L);
    for var i := 0 to L div 2 - 1 do
    begin
      PackedData[i] := FFDFAC[2 * i];
      PackedData[L div 2 + i] := FFDFAC[L - 1 - 2 * i];
    end;
    DCTIV(PackedData, Signal);
    SetLength(Correction, 16 + 2 * L);
    for var i := 0 to L - 1 do
      Correction[16 + i] := Signal[i] * Power(10, FFDFACGain / 28);
    Weighted(FPreviousLPC[1], A);
    Synthesis(A, Correction, 16, 2 * L);
    for var i := 0 to L - 1 do
      Correction[16 + i] :=
        Correction[16 + i]
        + FAlias[1 + FSubframe div 2 + i] * (1 - Sqr(PreviousWindow[L + i]))
        + FAlias[FSubframe div 2 - 1 - i + 1] * PreviousWindow[L - 1 - i] * PreviousWindow[L + i];
    if Sequence <> 2 then
    begin
      Transform := TInverseMDCT.Create(FLength);
      try
        Transform.Execute(Spectrum, 0, Temp);
      finally
        Transform.Free;
      end;
      for var i := 0 to FLength div 2 - 1 do
        Full[i] := 0;
      for var i := FLength div 2 + L to FLength - 1 do
        Full[i] := Temp[i] / FLength;
    end
    else
      for var i := Flat to FLength div 2 - 1 do
        Full[i] := 0;
    for var i := 0 to FLength div 2 - 1 do
      Full[i] := Prior[i];
    for var i := 0 to 2 * L - 1 do
      Full[FLength div 2 + i] := Full[FLength div 2 + i] + Correction[16 + i];
  end
  else
  begin
    for var i := 0 to Flat - 1 do
      Full[i] := Full[i] + Prior[i];
    for var i := 0 to 2 * L - 1 do
      Full[Flat + i] := Full[Flat + i] + Prior[Flat + i] * PreviousWindow[2 * L - 1 - i];
  end;
  Samples := Copy(Full, 0, FLength);
  Overlap := Copy(Full, FLength, FLength);
  FSynth := Copy(FSynthHistory);
  SetLength(FSynth, PREFIX + FDelay + FLength + 256);
  for var i := 0 to FLength - 1 do
    FSynth[PREFIX - 64 + i] := Samples[i];
  if FPreviousMode = 0 then
  begin
    var Last := FDelay div 64;
    FPitch[Last] := FPitch[Last - 1];
    FPitchGain[Last] := FPitchGain[Last - 1];
    if Sequence <> 2 then
    begin
      FPitch[Last + 1] := FPitch[Last];
      FPitchGain[Last + 1] := FPitchGain[Last];
    end;
  end;
  var BPFFrame := Default(TLPDFrame);
  BPFFrame.BassFilter := True;
  BassFilter(BPFFrame, Samples, FLength div 2 - 256, FLength div 128 + 3);
end;

procedure TUSACLPD.ReadFrame(var Bits: TBitReader; var Arithmetic: TAACArithState; Independent: Boolean; out Frame: TLPDFrame);
var
  Mode, Block, LastMode, Count, Subframes: Integer;
  CoreLast, FACPresent, FirstTCX, ResetArithmetic: Boolean;
begin
  Frame := Default(TLPDFrame);
  Frame.CoreMode := Bits.ReadBits(3);
  Mode := Bits.ReadBits(5);
  if Mode > 25 then
    raise EPlayerFormat.Create('Reserved USAC LPD mode');
  if Mode = 25 then
    for var i := 0 to 3 do
      Frame.Modes[i] := 3
  else if Mode = 24 then
    for var i := 0 to 3 do
      Frame.Modes[i] := 2
  else if Mode >= 20 then
  begin
    Frame.Modes[0] := Mode and 1;
    Frame.Modes[1] := (Mode shr 1) and 1;
    Frame.Modes[2] := 2;
    Frame.Modes[3] := 2;
  end
  else if Mode >= 16 then
  begin
    Frame.Modes[0] := 2;
    Frame.Modes[1] := 2;
    Frame.Modes[2] := Mode and 1;
    Frame.Modes[3] := (Mode shr 1) and 1;
  end
  else
    for var i := 0 to 3 do
      Frame.Modes[i] := (Mode shr i) and 1;
  Frame.BassFilter := Bits.ReadBit;
  CoreLast := Bits.ReadBit;
  FACPresent := Bits.ReadBit;
  Frame.FirstLPD := not CoreLast;
  FirstTCX := True;
  Block := 0;
  LastMode := FPreviousMode;
  Subframes := FSubframe div 64;
  while Block < 4 do
  begin
    if ((Block = 0) and CoreLast and FACPresent) or ((Block > 0) and ((LastMode = 0) <> (Frame.Modes[Block] = 0))) then
      ReadFAC(Bits, FSubframe div 2, Frame.FAC[Block]);
    if Frame.Modes[Block] = 0 then
    begin
      Frame.Energy[Block] := Bits.ReadBits(2);
      for var sf := 0 to Subframes - 1 do
      begin
        if (sf = 0) or ((Subframes = 4) and (sf = 2)) then
          Frame.ACB[Block, sf] := Bits.ReadBits(9)
        else
          Frame.ACB[Block, sf] := Bits.ReadBits(6);
        Frame.PitchFilter[Block, sf] := Bits.ReadBit;
        if Frame.CoreMode = 5 then
        begin
          for var j := 0 to 3 do
            Frame.Pulse[Block, sf, j] := Bits.ReadBits(2);
          for var j := 4 to 7 do
            Frame.Pulse[Block, sf, j] := Bits.ReadBits(14);
        end
        else
          for var j := 0 to 3 do
            Frame.Pulse[Block, sf, j] := Bits.ReadBits(CODE_BITS[Frame.CoreMode, j]);
        Frame.Gains[Block, sf] := Bits.ReadBits(7);
      end;
      LastMode := 0;
      Inc(Block);
    end
    else
    begin
      Frame.Noise[Block] := Bits.ReadBits(3);
      Frame.Gain[Block] := Bits.ReadBits(7);
      ResetArithmetic := False;
      if FirstTCX then
        ResetArithmetic := Independent or Bits.ReadBit;
      Count := FSubframe shl (Frame.Modes[Block] - 1);
      USACDecodeSpectrum(Bits, Arithmetic, ResetArithmetic, Count, Count, Frame.TCX[Block], True);
      LastMode := Frame.Modes[Block];
      Inc(Block, 1 shl (Frame.Modes[Block] - 1));
      FirstTCX := False;
    end;
  end;
  USACReadLPC(Bits, Frame.FirstLPD, Frame.Modes, FLSF, Frame.LPC);
  if not CoreLast and FACPresent then
  begin
    Frame.ShortFAC := Bits.ReadBit;
    Frame.StartGain := Bits.ReadBits(7);
    ReadFAC(Bits, IfThen(Frame.ShortFAC, FLength div 16, FLength div 8), Frame.StartFAC);
  end;
end;

procedure TUSACLPD.SynthesizeTCX(const Frame: TLPDFrame; Block: Integer; const OldLSF, NewLSF: TUSACLSF);
var
  X, Gains, G1, G2, Shaped, DCT, Buffer, Window, PrevWindow, FACSignal, FACInput: TFloatSamples;
  OldLPC, NewLPC, A: TUSACLPC;
  N, FACLength, PreviousFAC, L, M, Start, ExcStart: Integer;
  Energy, Maximum, Factor, Gain, Noise, Previous, AShape, BShape: Double;
begin
  X := Copy(Frame.TCX[Block]);
  N := Length(X);
  FACLength := FSubframe div 2;
  PreviousFAC := FACLength;
  if FPreviousMode = -2 then
    PreviousFAC := FLength div 16;
  Window := AACWindow(2 * FACLength, False);
  PrevWindow := AACWindow(2 * PreviousFAC, False);
  if FPreviousMode > 0 then
    for var i := 0 to 2 * PreviousFAC - 1 do
      FAlias[FACLength - PreviousFAC + 1 + i] :=
        FAlias[FACLength - PreviousFAC + 1 + i] * PrevWindow[2 * PreviousFAC - 1 - i];
  for var i := 0 to FACLength - PreviousFAC - 1 do
    FAlias[i + FACLength + PreviousFAC + 1] := 0;
  Noise := (8 - Frame.Noise[Block]) / 16;
  var i := N div 6;
  while i < N do
  begin
    Energy := 0;
    for var j := i to Min(N - 1, i + 7) do
      Energy := Energy + Sqr(X[j]);
    if Energy = 0 then
      for var j := i to Min(N - 1, i + 7) do
      begin
        FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * 69069 + 5) and $FFFFFFFF);
        X[j] := Noise;
        if FNoiseSeed and $10000 <> 0 then
          X[j] := -X[j];
      end;
    Inc(i, 8);
  end;
  Maximum := 0.01;
  for var j := 0 to N div 32 - 1 do
  begin
    Energy := 0.01;
    for var k := 0 to 7 do
      Energy := Energy + Sqr(X[j * 8 + k]);
    Maximum := Max(Maximum, Energy);
  end;
  Factor := 0.1;
  SetLength(Gains, N div 32);
  for var j := 0 to N div 32 - 1 do
  begin
    Energy := 0.01;
    for var k := 0 to 7 do
      Energy := Energy + Sqr(X[j * 8 + k]);
    Factor := Max(Factor, Sqrt(Energy / Maximum));
    Gains[j] := Factor;
    for var k := 0 to 7 do
      X[j * 8 + k] := X[j * 8 + k] * Factor;
  end;
  USACLSFToLPC(OldLSF, OldLPC);
  USACLSFToLPC(NewLSF, NewLPC);
  Weighted(OldLPC, A);
  LPCGains(A, FSubframe div 4, G1);
  Weighted(NewLPC, A);
  LPCGains(A, FSubframe div 4, G2);
  Energy := 0.01;
  for var j := 0 to N - 1 do
    Energy := Energy + Sqr(X[j]);
  Gain := Power(10, Frame.Gain[Block] / 28) / (Sqrt(Energy) / N * 2);
  SetLength(Shaped, N);
  Previous := 0;
  AShape := 0;
  BShape := 0;
  for var j := 0 to N - 1 do
  begin
    var Index := j div (N div Length(G1));
    AShape := 2 * G1[Index] * G2[Index] / (G1[Index] + G2[Index]);
    BShape := (G2[Index] - G1[Index]) / (G1[Index] + G2[Index]);
    Shaped[j] := AShape * X[j] + BShape * Previous;
    Previous := Shaped[j];
  end;
  for var j := 0 to N div 2 - 1 do
  begin
    X[j] := Shaped[2 * j];
    X[N div 2 + j] := Shaped[N - 2 * j - 1];
  end;
  DCTIV(X, DCT);
  L := 2 * FACLength;
  M := N - L;
  SetLength(Buffer, N + L);
  for var j := 0 to M div 2 - 1 do
    Buffer[L + M div 2 - 1 - j] := -DCT[M div 2 + L div 2 + j];
  for var j := 0 to L div 2 - 1 do
  begin
    Buffer[j] := DCT[M + L div 2 + j];
    Buffer[L - 1 - j] := -Buffer[j];
  end;
  for var j := 0 to M div 2 - 1 do
    Buffer[L + M div 2 + j] := -DCT[M div 2 + L div 2 - 1 - j];
  for var j := 0 to L div 2 - 1 do
  begin
    Buffer[L + M + j] := -DCT[L div 2 - 1 - j];
    Buffer[2 * L + M - 1 - j] := Buffer[L + M + j];
  end;
  FFACGain := Gain * 0.5 * Sqrt(FACLength / N);
  SetLength(FFACFrequency, FACLength div 4);
  for var j := 0 to High(FFACFrequency) do
    FFACFrequency[j] := Gains[j * N div (8 * FACLength)];
  if FPreviousMode = 0 then
  begin
    SetLength(FACInput, FACLength);
    for var j := 0 to FACLength div 2 - 1 do
    begin
      FACInput[j] := FFACGain * Frame.FAC[Block][2 * j];
      FACInput[FACLength div 2 + j] := FFACGain * Frame.FAC[Block][FACLength - 1 - 2 * j];
    end;
    for var j := 0 to FACLength div 8 - 1 do
    begin
      FACInput[j] := FACInput[j] * FFACFrequency[2 * j];
      FACInput[FACLength - 1 - j] := FACInput[FACLength - 1 - j] * FFACFrequency[2 * j + 1];
    end;
    DCTIV(FACInput, DCT);
    SetLength(FACSignal, 16 + 2 * FACLength);
    for var j := 0 to FACLength - 1 do
      FACSignal[16 + j] := DCT[j] * 2 / FACLength;
    Weighted(OldLPC, A);
    Synthesis(A, FACSignal, 16, 2 * FACLength);
    for var j := 0 to FACLength - 1 do
      FACSignal[16 + j] :=
        FACSignal[16 + j]
        + FAlias[1 + FACLength + j] * (1 - Sqr(PrevWindow[FACLength + j]))
        + FAlias[FACLength - j] * PrevWindow[FACLength - 1 - j] * PrevWindow[FACLength + j];
  end;
  for var j := 0 to High(Buffer) do
    Buffer[j] := Buffer[j] * Gain * 2 / N;
  for var j := 0 to 2 * PreviousFAC - 1 do
    Buffer[j + FACLength - PreviousFAC] := Buffer[j + FACLength - PreviousFAC] * PrevWindow[j];
  for var j := 0 to FACLength - PreviousFAC - 1 do
    Buffer[j] := 0;
  for var j := FACLength - PreviousFAC to FACLength + PreviousFAC - 1 do
    if FPreviousMode <> 0 then
      Buffer[j] := Buffer[j] + FAlias[1 + j]
    else
      Buffer[j + FACLength] := Buffer[j + FACLength] + FACSignal[16 + j];
  Move(Buffer[N - 1], FAlias[0], Length(FAlias) * SizeOf(Double));
  for var j := 0 to 2 * FACLength - 1 do
    Buffer[N + j] := Buffer[N + j] * Window[2 * FACLength - 1 - j];
  Start := PREFIX + FDelay + Block * FSubframe;
  ExcStart := PREFIX + Block * FSubframe;
  if FPreviousMode <> 0 then
    for var j := 0 to PreviousFAC - 1 do
      FSynth[Start - PreviousFAC + j] := Buffer[FACLength - PreviousFAC + j];
  for var j := 0 to N - 1 do
    FSynth[Start + j] := Buffer[FACLength + j];
  // LPC excitation history is the residual of the pre-emphasized TCX output.
  var Temp := Copy(FSynth, Start - FACLength - 17, N + FACLength + 17);
  for var j := High(Temp) downto 1 do
    Temp[j] := Temp[j] - 0.68 * Temp[j - 1];
  for var j := -FACLength to N - 1 do
  begin
    var Value := Temp[FACLength + j + 17];
    var ResidualLPC := NewLPC;
    if j < 0 then
      ResidualLPC := FPreviousLPC[0];
    for var k := 1 to 16 do
      Value := Value + ResidualLPC[k] * Temp[FACLength + j + 17 - k];
    FExc[ExcStart + j] := Value;
  end;
  FPreviousLPC[0] := NewLPC;
  FPreviousLPC[1] := NewLPC;
end;

procedure TUSACLPD.SynthesizeACELP(const Frame: TLPDFrame; Block: Integer; const OldLSF, NewLSF: TUSACLSF);
var
  LSP, OldLSP, NewLSP: TUSACLSF;
  LPC: array[0..4] of TUSACLPC;
  Code, Adaptive, Processed, Syn: TFloatSamples;
  Stability, Delta, Weight, Energy, PitchEnergy, GainPitch, GainCode, RV, Smooth, CPE, Memory, Value: Double;
  Start, ExcStart, Offset, MinPitch, Fr2, MaxPitch, Lag, Fraction, LagMin, Index, Base, F, Position, PitchIndex, Tracks: Integer;
begin
  Start := PREFIX + FDelay + Block * FSubframe;
  ExcStart := PREFIX + Block * FSubframe;
  if FPreviousMode > 0 then
  begin
    Base := FSubframe div 2;
    SetLength(Code, Base);
    for var i := 0 to Base div 2 - 1 do
    begin
      Code[i] := FFACGain * Frame.FAC[Block][2 * i];
      Code[Base div 2 + i] := FFACGain * Frame.FAC[Block][Base - 2 * i - 1];
    end;
    for var i := 0 to Base div 8 - 1 do
    begin
      Code[i] := Code[i] * FFACFrequency[2 * i];
      Code[Base - i - 1] := Code[Base - i - 1] * FFACFrequency[2 * i + 1];
    end;
    DCTIV(Code, Processed);
    SetLength(Syn, 16 + 2 * Base);
    for var i := 0 to Base - 1 do
      Syn[16 + Base + i] := Processed[i] * 2 / Base;
    Weighted(FPreviousLPC[0], LPC[0]);
    Synthesis(LPC[0], Syn, 16 + Base, Base);
    for var i := 0 to 2 * Base - 1 do
      Syn[16 + i] := Syn[16 + i] + FSynth[Start - 2 * Base + i];
    for var i := 0 to Base - 1 do
      FSynth[Start - Base + i] := Syn[16 + Base + i];
    for var i := 16 + 2 * Base - 1 downto 17 do
      Syn[i] := Syn[i] - 0.68 * Syn[i - 1];
    for var i := 0 to Base - 1 do
    begin
      LPC[0] := FPreviousLPC[Ord(i >= (Base mod 64))];
      Value := Syn[16 + Base + i];
      for var j := 1 to 16 do
        Value := Value + LPC[0][j] * Syn[16 + Base + i - j];
      FExc[ExcStart - Base + i] := Value;
    end;
  end;
  Tracks := FSubframe div 64;
  Delta := 0;
  for var i := 0 to 15 do
  begin
    Delta := Delta + Sqr(NewLSF[i] - OldLSF[i]);
    OldLSP[i] := Cos(OldLSF[i] * Pi / 6400);
    NewLSP[i] := Cos(NewLSF[i] * Pi / 6400);
  end;
  Stability := EnsureRange(1.25 - Delta / 400000, 0.0, 1.0);
  for var sf := 0 to Tracks do
  begin
    Weight := Min((sf + 0.5) / Tracks, 1.0);
    for var i := 0 to 15 do
      LSP[i] := OldLSP[i] * (1 - Weight) + NewLSP[i] * Weight;
    LPCFromLSP(LSP, LPC[sf]);
  end;
  SetLength(Syn, 16 + FSubframe + 128);
  for var i := 0 to 15 do
    Syn[i] := FSynth[Start - 16 + i] - 0.68 * FSynth[Start - 17 + i];
  SetLength(Code, 64);
  SetLength(Adaptive, 65);
  SetLength(Processed, 64);
  Offset := (FRate * 34 + 6400) div 12800 - 34;
  MinPitch := 34 + Offset;
  Fr2 := 128 - Offset;
  MaxPitch := 231 + 6 * Offset;
  LagMin := MinPitch;
  for var sf := 0 to Tracks - 1 do
  begin
    Position := ExcStart + sf * 64;
    Index := Frame.ACB[Block, sf];
    if (sf = 0) or ((Tracks = 4) and (sf = 2)) then
    begin
      if Index < (Fr2 - MinPitch) * 4 then
      begin
        Lag := MinPitch + Index div 4;
        Fraction := Index mod 4;
      end
      else if Index < (Fr2 - MinPitch) * 4 + (160 - Fr2) * 2 then
      begin
        Dec(Index, (Fr2 - MinPitch) * 4);
        Lag := Fr2 + Index div 2;
        Fraction := (Index mod 2) * 2;
      end
      else
      begin
        Lag := Index + 160 - (Fr2 - MinPitch) * 4 - (160 - Fr2) * 2;
        Fraction := 0;
      end;
      LagMin := EnsureRange(Lag - 8, MinPitch, MaxPitch - 15);
    end
    else
    begin
      Lag := LagMin + Index div 4;
      Fraction := Index mod 4;
    end;
    Base := Position - Lag;
    F := -Fraction;
    if F < 0 then
    begin
      Inc(F, 4);
      Dec(Base);
    end;
    for var i := 0 to 64 do
    begin
      Value := 0;
      for var j := 0 to 15 do
        Value :=
          Value
          + FExc[Base + i - j] * ACELP_INTERPOL[F + 4 * j]
          + FExc[Base + i + 1 + j] * ACELP_INTERPOL[4 - F + 4 * j];
      FExc[Position + i] := Value;
    end;
    if not Frame.PitchFilter[Block, sf] then
    begin
      for var i := 0 to 63 do
        Adaptive[i] := 0.18 * FExc[Position + i - 1] + 0.64 * FExc[Position + i] + 0.18 * FExc[Position + i + 1];
      for var i := 0 to 63 do
        FExc[Position + i] := Adaptive[i];
    end;
    FillChar(Code[0], 64 * SizeOf(Double), 0);
    case Frame.CoreMode of
      0:
        for var t := 0 to 3 do
          PulseOne(Frame.Pulse[Block, sf, t], 4, 0, t, Code);
      1:
        for var t := 0 to 3 do
          if t < 2 then
            PulseTwo(Frame.Pulse[Block, sf, t], 4, 0, t, Code)
          else
            PulseOne(Frame.Pulse[Block, sf, t], 4, 0, t, Code);
      2:
        for var t := 0 to 3 do
          PulseTwo(Frame.Pulse[Block, sf, t], 4, 0, t, Code);
      3:
        for var t := 0 to 3 do
          if t < 2 then
            PulseThree(Frame.Pulse[Block, sf, t], 4, 0, t, Code)
          else
            PulseTwo(Frame.Pulse[Block, sf, t], 4, 0, t, Code);
      4:
        for var t := 0 to 3 do
          PulseThree(Frame.Pulse[Block, sf, t], 4, 0, t, Code);
      5:
        for var t := 0 to 3 do
          PulseFour((Frame.Pulse[Block, sf, t] shl 14) + Frame.Pulse[Block, sf, t + 4], t, Code);
      6:
        for var t := 0 to 1 do
          PulseOne(Frame.Pulse[Block, sf, t * 2 + 1], 4, 0, 2 * Frame.Pulse[Block, sf, t * 2] + t, Code);
      7:
        begin
          Index := 1;
          Base := 1;
          if Frame.Pulse[Block, sf, 0] <> 0 then
            Base := 3;
          for var t := 0 to 3 do
            if t <> Base then
            begin
              PulseOne(Frame.Pulse[Block, sf, Index], 4, 0, t, Code);
              Inc(Index);
            end;
        end;
    end;
    for var i := 63 downto 1 do
      Code[i] := Code[i] - 0.3 * Code[i - 1];
    Index := Lag;
    if Fraction > 2 then
      Inc(Index);
    for var i := Index to 63 do
      Code[i] := Code[i] + 0.85 * Code[i - Index];
    Energy := 0.01;
    PitchEnergy := 0;
    for var i := 0 to 63 do
    begin
      Energy := Energy + Sqr(Code[i]);
      PitchEnergy := PitchEnergy + Sqr(FExc[Position + i]);
    end;
    GainPitch := ACELP_GAIN[2 * Frame.Gains[Block, sf]];
    GainCode :=
      ACELP_GAIN[2 * Frame.Gains[Block, sf] + 1]
      * Power(10, 0.05 * (Frame.Energy[Block] * 12 + 18 - 10 * Log10(Energy / 64)));
    PitchEnergy := PitchEnergy * Sqr(GainPitch);
    Energy := Energy * Sqr(GainCode);
    RV := (PitchEnergy - Energy) / (PitchEnergy + Energy);
    Smooth := GainCode;
    if Smooth < FGainThreshold then
      Smooth := Min(Smooth * 1.19, FGainThreshold)
    else
      Smooth := Max(Smooth / 1.19, FGainThreshold);
    FGainThreshold := Smooth;
    Weight := Stability * 0.5 * (1 - RV);
    Smooth := Weight * Smooth + (1 - Weight) * GainCode;
    for var i := 0 to 63 do
    begin
      Processed[i] := GainPitch * FExc[Position + i];
      FExc[Position + i] := Processed[i] + GainCode * Code[i];
      Code[i] := Code[i] * Smooth;
    end;
    PitchIndex := FDelay div 64 + Block * Tracks + sf;
    FPitch[PitchIndex] := Min(Index, MaxPitch);
    FPitchGain[PitchIndex] := GainPitch;
    CPE := 0.125 * (1 + RV);
    for var i := 0 to 63 do
    begin
      Value := Processed[i] + Code[i];
      if i > 0 then
        Value := Value - CPE * Code[i - 1];
      if i < 63 then
        Value := Value - CPE * Code[i + 1];
      Syn[16 + sf * 64 + i] := Value;
    end;
    Synthesis(LPC[sf], Syn, 16 + sf * 64, 64);
  end;
  Memory := FSynth[Start - 1];
  for var i := 0 to FSubframe - 1 do
  begin
    Memory := Syn[16 + i] + 0.68 * Memory;
    FSynth[Start + i] := Memory;
  end;
  Synthesis(LPC[Tracks], Syn, 16 + FSubframe, 128);
  FPreviousLPC[0] := LPC[Tracks - 2];
  FPreviousLPC[1] := LPC[Tracks - 1];
  for var i := 0 to FSubframe div 2 do
    FAlias[i] := FSynth[Start + FSubframe - 1 - FSubframe div 2 + i];
  for var i := 0 to FSubframe div 2 - 1 do
  begin
    Memory := Syn[16 + FSubframe + i] + 0.68 * Memory;
    FAlias[1 + FSubframe div 2 + i] := Memory;
  end;
end;

procedure TUSACLPD.BassFilter(const Frame: TLPDFrame; out Samples: TFloatSamples; LookaheadOverride, ProcessBlocks: Integer);
var
  Noise: array[0..139] of Double;
  SavedGains: TFloatSamples;
  Lag, Lookahead, Count, Position: Integer;
  Gain, XEnergy, YEnergy, Cross, Value, Alpha: Double;
begin
  if not Frame.BassFilter then
    for var i := 0 to FLength div 64 - 1 do
      if not ((Frame.Modes[0] <> 0) and FBassActive and (i < 2)) then
        FPitchGain[FDelay div 64 + i] := 0;
  FBassActive := Frame.BassFilter;
  SavedGains := Copy(FPitchGain, FLength div 64, FDelay div 64);
  for var sf := 0 to FLength div 64 - 1 do
  begin
    if FPitchGain[sf] > 0 then
    begin
      Cross := 0;
      YEnergy := 1E-6;
      for var i := 0 to 63 do
      begin
        Cross := Cross + FSynth[PREFIX + sf * 64 + i] * FSynth[PREFIX + sf * 64 + i - FPitch[sf]];
        YEnergy := YEnergy + Sqr(FSynth[PREFIX + sf * 64 + i - FPitch[sf]]);
      end;
      FPitchGain[sf] := Cross / YEnergy;
    end;
  end;
  SetLength(Samples, FLength);
  for var i := 0 to FLength - 1 do
    Samples[i] := FSynth[PREFIX - 64 + i];
  Lookahead := FDelay;
  if Frame.Modes[3] <> 0 then
    Dec(Lookahead, FSubframe div 2);
  FillChar(Noise, SizeOf(Noise), 0);
  if LookaheadOverride >= 0 then
    Lookahead := LookaheadOverride;
  if ProcessBlocks < 0 then
    ProcessBlocks := FLength div 64;
  for var sf := 0 to ProcessBlocks - 1 do
  begin
    Lag := FPitch[sf];
    Gain := EnsureRange(FPitchGain[sf], 0.0, 1.0);
    Position := PREFIX + sf * 64;
    XEnergy := 0.01;
    YEnergy := 0.01;
    Cross := 0.01;
    for var i := -96 to 63 do
    begin
      XEnergy := XEnergy + Sqr(FSynth[Position + i]);
      YEnergy := YEnergy + Sqr(FSynth[Position + i - Lag div 2]);
      Cross := Cross + FSynth[Position + i] * FSynth[Position + i - Lag div 2];
    end;
    if Cross / Sqrt(XEnergy * YEnergy) > 0.95 then
      Lag := Lag div 2;
    Count := EnsureRange(FLength + Lookahead - Lag - sf * 64, 0, 64);
    if Gain > 0 then
    begin
      if Count > 0 then
      begin
        XEnergy := 0.01;
        YEnergy := 0.01;
        for var i := 0 to Count - 1 do
        begin
          XEnergy := XEnergy + Sqr(FSynth[Position + i]);
          YEnergy := YEnergy + Sqr(FSynth[Position + i + Lag]);
        end;
        Gain := Min(Gain, Sqrt(XEnergy / YEnergy));
      end;
      Alpha := Gain * 0.5;
      for var i := 0 to 63 do
        if i < Count then
          Noise[76 + i] :=
            Alpha * (FSynth[Position + i] - 0.5 * FSynth[Position + i - Lag] - 0.5 * FSynth[Position + i + Lag])
        else
          Noise[76 + i] := Alpha * (FSynth[Position + i] - FSynth[Position + i - Lag]);
    end
    else
      for var i := 0 to 63 do
        Noise[76 + i] := 0;
    for var i := 0 to 75 do
      Noise[i] := FBassHistory[i];
    for var i := 0 to 75 do
      FBassHistory[i] := Noise[64 + i];
    for var i := 0 to 63 do
    begin
      Value := ACELP_BASS[0] * Noise[12 + i];
      for var j := 1 to 12 do
        Value := Value + ACELP_BASS[j] * (Noise[12 + i - j] + Noise[12 + i + j]);
      Samples[sf * 64 + i] := Samples[sf * 64 + i] - Value;
    end;
  end;
  for var i := 0 to FDelay div 64 - 1 do
  begin
    FPitch[i] := FPitch[FLength div 64 + i];
    FPitchGain[i] := SavedGains[i];
  end;
  for var i := FDelay div 64 to High(FPitch) do
  begin
    FPitch[i] := 64;
    FPitchGain[i] := 0;
  end;
end;

procedure TUSACLPD.Decode(var Bits: TBitReader; var Arithmetic: TAACArithState; Independent: Boolean; var NoiseSeed: Cardinal; const FDOverlap: TFloatSamples; PreviousShort: Boolean; out Samples: TFloatSamples);
var
  Frame: TLPDFrame;
  OldLSF, NewLSF: TUSACLSF;
  Block, Step, FACLength, Offset: Integer;
  A: TUSACLPC;
  PackedData, Signal, History: TFloatSamples;
  Memory: Double;
  FDHistory: TFloatSamples;
begin
  FNoiseSeed := NoiseSeed;
  ReadFrame(Bits, Arithmetic, Independent, Frame);
  if Frame.FirstLPD then
  begin
    var PreviousNoiseSeed := FNoiseSeed;
    Reset;
    FNoiseSeed := PreviousNoiseSeed;
    FACLength := IfThen(PreviousShort, FLength div 16, FLength div 8);
    var W := AACWindow(2 * FACLength, False);
    SetLength(History, FLength);
    for var i := 0 to Min(High(FDOverlap), High(History)) do
      History[i] := FDOverlap[i];
    for var i := 0 to 2 * FACLength - 1 do
      History[FLength div 2 - FACLength + i] := History[FLength div 2 - FACLength + i] * W[2 * FACLength - 1 - i];
    for var i := FLength div 2 + FACLength to FLength - 1 do
      History[i] := 0;
    FDHistory := Copy(History);
    for var i := 0 to 2 * FACLength do
      FAlias[FSubframe div 2 - FACLength + i] := History[FLength div 2 - FACLength - 1 + i];
  end;
  SetLength(FSynth, PREFIX + FDelay + FLength + 256);
  FillChar(FSynth[0], Length(FSynth) * SizeOf(Double), 0);
  SetLength(FExc, PREFIX + FLength + 128);
  FillChar(FExc[0], Length(FExc) * SizeOf(Double), 0);
  Move(FSynthHistory[0], FSynth[0], Length(FSynthHistory) * SizeOf(Double));
  Move(FExcHistory[0], FExc[0], Length(FExcHistory) * SizeOf(Double));
  if Frame.FirstLPD then
  begin
    FPreviousMode := -1;
    if PreviousShort then
      FPreviousMode := -2;
    FLSF := Frame.LPC[0];
    if Length(History) >= 2 * FSubframe then
      Move(History[0], FSynth[PREFIX + FDelay - 2 * FSubframe], 2 * FSubframe * SizeOf(Double));
    USACLSFToLPC(FLSF, A);
    FPreviousLPC[0] := A;
    FPreviousLPC[1] := A;
    if (Frame.Modes[0] = 0) and (Length(Frame.StartFAC) <> 0) then
    begin
      FACLength := Length(Frame.StartFAC);
      SetLength(PackedData, FACLength);
      for var i := 0 to FACLength div 2 - 1 do
      begin
        PackedData[i] := Frame.StartFAC[2 * i];
        PackedData[FACLength div 2 + i] := Frame.StartFAC[FACLength - 1 - 2 * i];
      end;
      DCTIV(PackedData, Signal);
      SetLength(History, 16 + FACLength);
      FillChar(History[0], Length(History) * SizeOf(Double), 0);
      for var i := 0 to FACLength - 1 do
        History[16 + i] := Signal[i] * Power(10, Frame.StartGain / 28);
      Weighted(A, A);
      Synthesis(A, History, 16, FACLength);
      Offset := PREFIX + FDelay - FACLength;
      for var i := 0 to FACLength - 1 do
        FSynth[Offset + i] := FSynth[Offset + i] + History[16 + i];
    end;
    if (Frame.Modes[0] = 0) or (Frame.Modes[1] = 0) or ((FSubframe <> 256) and (Frame.Modes[2] = 0)) then
    begin
      USACLSFToLPC(FLSF, A);
      SetLength(History, 16 + 2 * FSubframe);
      FillChar(History[0], Length(History) * SizeOf(Double), 0);
      Memory := 0;
      for var i := 0 to 2 * FSubframe - 1 do
      begin
        History[16 + i] := FSynth[PREFIX + FDelay - 2 * FSubframe + i] - 0.68 * Memory;
        Memory := FSynth[PREFIX + FDelay - 2 * FSubframe + i];
      end;
      for var i := 0 to 2 * FSubframe - 1 do
      begin
        Memory := History[16 + i];
        for var j := 1 to 16 do
          Memory := Memory + A[j] * History[16 + i - j];
        FExc[PREFIX - 2 * FSubframe + i] := Memory;
      end;
    end;
  end;
  OldLSF := FLSF;
  Block := 0;
  while Block < 4 do
  begin
    Step := 1;
    if Frame.Modes[Block] > 0 then
      Step := 1 shl (Frame.Modes[Block] - 1);
    if (FPreviousMode = 0) and (Frame.Modes[Block] > 0) and ((Block <> 0) or FBassActive) then
    begin
      var PitchIndex := FDelay div 64 + Block * (FSubframe div 64);
      for var j := 0 to 1 do
      begin
        FPitch[PitchIndex + j] := FPitch[PitchIndex - 1];
        FPitchGain[PitchIndex + j] := FPitchGain[PitchIndex - 1];
      end;
    end;
    NewLSF := Frame.LPC[Block + Step];
    if Frame.Modes[Block] = 0 then
      SynthesizeACELP(Frame, Block, OldLSF, NewLSF)
    else
      SynthesizeTCX(Frame, Block, OldLSF, NewLSF);
    if (Frame.Modes[Block] = 0) and (FPreviousMode <> 0) and Frame.BassFilter then
    begin
      var PitchIndex := FDelay div 64 + Block * (FSubframe div 64);
      for var j := 1 to IfThen(FPreviousMode = -2, 1, 2) do
      begin
        FPitch[PitchIndex - j] := FPitch[PitchIndex];
        FPitchGain[PitchIndex - j] := FPitchGain[PitchIndex];
      end;
    end;
    FPreviousMode := Frame.Modes[Block];
    OldLSF := NewLSF;
    Inc(Block, Step);
  end;
  FLSF := Frame.LPC[4];
  Move(FSynth[FLength], FSynthHistory[0], Length(FSynthHistory) * SizeOf(Double));
  Move(FExc[FLength], FExcHistory[0], Length(FExcHistory) * SizeOf(Double));
  NoiseSeed := FNoiseSeed;
  BassFilter(Frame, Samples);
  if Frame.FirstLPD then
  begin
    FACLength := IfThen(PreviousShort, FLength div 16, FLength div 8);
    Offset := FLength div 2 - FACLength;
    if Frame.Modes[0] = 0 then
      Dec(Offset, 64);
    for var i := 0 to Offset - 1 do
      Samples[i] := FDHistory[i];
  end;
end;

end.

