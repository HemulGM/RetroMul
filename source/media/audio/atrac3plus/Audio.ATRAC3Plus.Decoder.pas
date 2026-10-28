unit Audio.ATRAC3Plus.Decoder;
// Delphi source translation of Jpcsp ATRAC3+ (FFmpeg, Maxim Poliakovski).
// GPL-3.0-or-later; see LICENSE.ATRAC3Plus.md. No Java runtime is used.
{$Q-}
{$B-}

interface

uses
  System.SysUtils, System.Math, Audio.ATRAC3Plus.Primitives,
  Audio.ATRAC3Plus.Tables;

const
  AT3P_ERROR = -1;
  ATRAC3P_FRAME_SAMPLES = 2048;
  ATRAC3P_SUBBANDS = 16;
  ATRAC3P_SUBBAND_SAMPLES = 128;
  ATRAC3P_PQF_FIR_LEN = 12;
  ATRAC3P_POWER_COMP_OFF = 15;
  CH_UNIT_STEREO = 1;

type
  TATIPQFChannelContext = class;

  TATAtracGainInfo = class;

  TATWaveEnvelope = class;

  TATWaveParam = class;

  TATWavesData = class;

  TATWaveSynthParams = class;

  TATChannel = class;

  TATChannelUnitContext = class;

  TATAtrac = class;

  TATAtrac3plusDsp = class;

  TATContext = class;

  TATChannelUnit = class;

  TATIPQFChannelContext = class
  public
    buf1: TArray<TArray<Single>>;
    buf2: TArray<TArray<Single>>;
    pos: Integer;
    constructor Create;
  end;

  TATAtracGainInfo = class
  public
    numPoints: Integer;
    levCode: TArray<Integer>;
    locCode: TArray<Integer>;
    constructor Create;
    procedure clear;
    procedure copy(Arg_SourceData: TATAtracGainInfo);
  end;

  TATWaveEnvelope = class
  public
    hasStartPoint: Boolean;
    hasStopPoint: Boolean;
    startPos: Integer;
    stopPos: Integer;
    constructor Create;
    procedure clear;
    procedure copy(Arg_SourceData: TATWaveEnvelope);
  end;

  TATWaveParam = class
  public
    freqIndex: Integer;
    ampSf: Integer;
    ampIndex: Integer;
    phaseIndex: Integer;
    constructor Create;
    procedure clear;
  end;

  TATWavesData = class
  public
    pendEnv: TATWaveEnvelope;
    currEnv: TATWaveEnvelope;
    numWavs: Integer;
    startIndex: Integer;
    constructor Create;
    procedure clear;
    procedure copy(Arg_SourceData: TATWavesData);
    destructor Destroy; override;
  end;

  TATWaveSynthParams = class
  public
    tonesPresent: Boolean;
    amplitudeMode: Integer;
    numToneBands: Integer;
    toneSharing: TArray<Boolean>;
    toneMaster: TArray<Boolean>;
    phaseShift: TArray<Boolean>;
    tonesIndex: Integer;
    waves: TArray<TATWaveParam>;
    constructor Create;
    destructor Destroy; override;
  end;

  TATChannel = class
  public
    chNum: Integer;
    numCodedVals: Integer;
    fillMode: Integer;
    splitPoint: Integer;
    tableType: Integer;
    quWordlen: TArray<Integer>;
    quSfIdx: TArray<Integer>;
    quTabIdx: TArray<Integer>;
    spectrum: TArray<Integer>;
    powerLevs: TArray<Integer>;
    wndShapeHist: TArray<TArray<Boolean>>;
    wndShape: TArray<Boolean>;
    wndShapePrev: TArray<Boolean>;
    gainDataHist: TArray<TArray<TATAtracGainInfo>>;
    gainData: TArray<TATAtracGainInfo>;
    gainDataPrev: TArray<TATAtracGainInfo>;
    numGainSubbands: Integer;
    tonesInfoHist: TArray<TArray<TATWavesData>>;
    tonesInfo: TArray<TATWavesData>;
    tonesInfoPrev: TArray<TATWavesData>;
    constructor Create(Arg_chNum: Integer);
    destructor Destroy; override;
  end;

  TATChannelUnitContext = class
  public
    unitType: Integer;
    numQuantUnits: Integer;
    numSubbands: Integer;
    usedQuantUnits: Integer;
    numCodedSubbands: Integer;
    muteFlag: Boolean;
    useFullTable: Boolean;
    noisePresent: Boolean;
    noiseLevelIndex: Integer;
    noiseTableIndex: Integer;
    swapChannels: TArray<Boolean>;
    negateCoeffs: TArray<Boolean>;
    channels: TArray<TATChannel>;
    waveSynthHist: TArray<TATWaveSynthParams>;
    wavesInfo: TATWaveSynthParams;
    wavesInfoPrev: TATWaveSynthParams;
    ipqfCtx: TArray<TATIPQFChannelContext>;
    prevBuf: TArray<TArray<Single>>;
    constructor Create;
    destructor Destroy; override;
  end;

  TATAtrac = class
  public
    gainTab1: TArray<Single>;
    gainTab2: TArray<Single>;
    id2expOffset: Integer;
    locScale: Integer;
    locSize: Integer;
    constructor Create;
    class procedure generateTables; static;
    procedure initGainCompensation(Arg_id2expOffset: Integer; Arg_locScale: Integer);
    procedure gainCompensation(Arg_InputData: TArray<Single>; Arg_inOffset: Integer; Arg_prev: TArray<Single>; Arg_prevOffset: Integer; Arg_gcNow: TATAtracGainInfo; Arg_gcNext: TATAtracGainInfo; Arg_numSamples: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer);
    class procedure iqmf(Arg_inlo: TArray<Single>; Arg_inloOffset: Integer; Arg_inhi: TArray<Single>; Arg_inhiOffset: Integer; Arg_nIn: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer; Arg_delayBuf: TArray<Single>; Arg_temp: TArray<Single>); static;
  end;

  TATAtrac3plusDsp = class
  public
    constructor Create;
    class function DEQUANT_PHASE(Arg_ph: Integer): Integer; static;
    procedure initImdct(Arg_mdctCtx: TATIMDCT);
    class procedure initWaveSynth; static;
    procedure powerCompensation(Arg_ctx: TATChannelUnitContext; Arg_chIndex: Integer; Arg_sp: TArray<Single>; Arg_rngIndex: Integer; Arg_sb: Integer);
    procedure imdct(Arg_mdctCtx: TATIMDCT; Arg_InputData: TArray<Single>; Arg_inOffset: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer; Arg_windId: Integer; Arg_sb: Integer);
    procedure wavesSynth(Arg_synthParams: TATWaveSynthParams; Arg_wavesInfo: TATWavesData; Arg_envelope: TATWaveEnvelope; Arg_phaseShift: Boolean; Arg_regOffset: Integer; Arg_OutputData: TArray<Single>);
    procedure generateTones(Arg_ctx: TATChannelUnitContext; Arg_chNum: Integer; Arg_sb: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer);
    procedure ipqf(Arg_dctCtx: TATIMDCT; Arg_hist: TATIPQFChannelContext; Arg_InputData: TArray<Single>; Arg_OutputData: TArray<Single>);
  end;

  TATContext = class
  public
    br: TATBits;
    dsp: TATAtrac3plusDsp;
    channelUnits: TArray<TATChannelUnit>;
    numChannelBlocks: Integer;
    outputChannels: Integer;
    gaincCtx: TATAtrac;
    mdctCtx: TATIMDCT;
    ipqfDctCtx: TATIMDCT;
    samples: TArray<TArray<Single>>;
    mdctBuf: TArray<TArray<Single>>;
    timeBuf: TArray<TArray<Single>>;
    outpBuf: TArray<TArray<Single>>;
    constructor Create;
    destructor Destroy; override;
  end;

  TATChannelUnit = class
  public
    ctx: TATChannelUnitContext;
    br: TATBits;
    dsp: TATAtrac3plusDsp;
    numChannels: Integer;
    constructor Create;
    class procedure init; static;
    class function buildCanonicalHuff(Arg_cb: TArray<Integer>; Arg_xlat: TArray<Integer>; Arg_vlc: TATVLC): Integer; static;
    procedure setBitReader(Arg_br: TATBits);
    procedure setDsp(Arg_dsp: TATAtrac3plusDsp);
    procedure setNumChannels(Arg_numChannels: Integer);
    function decode: Integer;
    function numCodedUnits(Arg_chan: TATChannel): Integer;
    function getDelta(Arg_deltaBits: Integer): Integer;
    procedure unpackVqShape(Arg_startVal: Integer; Arg_shapeVec: TArray<Integer>; Arg_dst: TArray<Integer>; Arg_numValues: Integer);
    procedure unpackSfVqShape(Arg_dst: TArray<Integer>; Arg_numValues: Integer);
    function addWordlenWeights(Arg_chan: TATChannel; Arg_weightIdx: Integer): Integer;
    function decodeChannelWordlen(Arg_chNum: Integer): Integer;
    function substractSfWeights(Arg_chan: TATChannel; Arg_wtabIdx: Integer): Integer;
    function decodeChannelSfIdx(Arg_chNum: Integer): Integer;
    function decodeQuantWordlen: Integer;
    function decodeScaleFactors: Integer;
    function getNumCtValues: Integer;
    function decodeChannelCodeTab(Arg_chNum: Integer): Integer;
    function decodeCodeTableIndexes: Integer;
    procedure decodeQuSpectra(Arg_tab: TATSpecCodeTab; Arg_vlcTab: TATVLC; Arg_OutputData: TArray<Integer>; Arg_outOffset: Integer; Arg_numSpecs: Integer);
    procedure decodeSpectrum;
    function getSubbandFlags(Arg_OutputData: TArray<Boolean>; Arg_numFlags: Integer): Boolean;
    procedure decodeWindowShape;
    function decodeGaincNPoints(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
    procedure gaincLevelMode1m(Arg_dst: TATAtracGainInfo);
    procedure gaincLevelMode3s(Arg_dst: TATAtracGainInfo; Arg_ref: TATAtracGainInfo);
    function decodeGaincLevels(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
    procedure gaincLocMode0(Arg_dst: TATAtracGainInfo; Arg_pos: Integer);
    procedure gaincLocMode1(Arg_dst: TATAtracGainInfo);
    function decodeGaincLocCodes(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
    function decodeGaincData: Integer;
    procedure decodeTonesEnvelope(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
    function decodeBandNumwavs(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>): Integer;
    procedure decodeTonesFrequency(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
    procedure decodeTonesAmplitude(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
    procedure decodeTonesPhase(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
    function decodeTonesInfo: Integer;
    procedure decodeResidualSpectrum(Arg_OutputData: TArray<TArray<Single>>);
    procedure reconstructFrame(Arg_at3pContext: TATContext);
    destructor Destroy; override;
  end;

var
  ff_atrac_sf_table: TArray<Single>;
  qmf_window: TArray<Single>;
  qmf_48tap_half: TArray<Single>;
  ATRAC3P_MDCT_SIZE: Integer;
  sine_table: TArray<Single>;
  hann_window: TArray<Single>;
  amp_sf_tab: TArray<Single>;
  TWOPI: Double;
  ff_atrac3p_qu_to_spec_pos: TArray<Integer>;
  ff_atrac3p_sf_tab: TArray<Single>;
  ff_atrac3p_mant_tab: TArray<Single>;
  subband_to_powgrp: TArray<Integer>;
  noise_tab: TArray<Single>;
  pwc_levs: TArray<Single>;
  subband_to_qu: TArray<Integer>;
  mod23_lut: TArray<Integer>;
  ipqf_coeffs1: TArray<TArray<Single>>;
  ipqf_coeffs2: TArray<TArray<Single>>;
  wl_vlc_tabs: TArray<TATVLC>;
  sf_vlc_tabs: TArray<TATVLC>;
  ct_vlc_tabs: TArray<TATVLC>;
  spec_vlc_tabs: TArray<TATVLC>;
  gain_vlc_tabs: TArray<TATVLC>;
  tone_vlc_tabs: TArray<TATVLC>;
  wl_nb_bits: TArray<Integer>;
  wl_nb_codes: TArray<Integer>;
  wl_bits: TArray<TArray<Integer>>;
  wl_codes: TArray<TArray<Integer>>;
  wl_xlats: TArray<TArray<Integer>>;
  ct_nb_bits: TArray<Integer>;
  ct_nb_codes: TArray<Integer>;
  ct_bits: TArray<TArray<Integer>>;
  ct_codes: TArray<TArray<Integer>>;
  ct_xlats: TArray<TArray<Integer>>;
  sf_nb_bits: TArray<Integer>;
  sf_nb_codes: TArray<Integer>;
  sf_bits: TArray<TArray<Integer>>;
  sf_codes: TArray<TArray<Integer>>;
  sf_xlats: TArray<TArray<Integer>>;
  gain_cbs: TArray<TArray<Integer>>;
  gain_xlats: TArray<TArray<Integer>>;
  tone_cbs: TArray<TArray<Integer>>;
  tone_xlats: TArray<TArray<Integer>>;
  ff_sine_64, ff_sine_128: TArray<Single>;
  ATTablesReady: Boolean;

implementation

function AvLog2(Value: Integer): Integer;
begin
  Result := 0;
  while Value > 1 do
  begin
    Value := Value shr 1;
    Inc(Result);
  end;
end;

procedure ATInitSineWindows;
begin
  SetLength(ff_sine_64, 64);
  SetLength(ff_sine_128, 128);
  for var I := 0 to 63 do
    ff_sine_64[I] := Sin((I + 0.5) * Pi / 128);
  for var I := 0 to 127 do
    ff_sine_128[I] := Sin((I + 0.5) * Pi / 256);
end;

procedure VectorFmul(const Dest: TATFloats; DestOffset: Integer; const A: TATFloats; AOffset: Integer; const B: TATFloats; BOffset, Count: Integer);
begin
  for var I := 0 to Count - 1 do
    Dest[DestOffset + I] := A[AOffset + I] * B[BOffset + I];
end;

procedure VectorFmulReverse(const Dest: TATFloats; DestOffset: Integer; const A: TATFloats; AOffset: Integer; const B: TATFloats; BOffset, Count: Integer);
begin
  for var I := 0 to Count - 1 do
    Dest[DestOffset + I] := A[AOffset + I] * B[BOffset + Count - 1 - I];
end;

constructor TATIPQFChannelContext.Create;
begin
  inherited Create;
  var Temporary1: TArray<TArray<Single>>;
  SetLength(Temporary1, (ATRAC3P_PQF_FIR_LEN * 2), 8);
  buf1 := Temporary1;
  var Temporary2: TArray<TArray<Single>>;
  SetLength(Temporary2, (ATRAC3P_PQF_FIR_LEN * 2), 8);
  buf2 := Temporary2;
end;

constructor TATAtracGainInfo.Create;
begin
  inherited Create;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 7);
  levCode := Temporary1;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 7);
  locCode := Temporary2;
end;

procedure TATAtracGainInfo.clear;
begin
  numPoints := 0;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 7) do
    begin
      begin
        levCode[V_i] := 0;
        locCode[V_i] := 0;
      end;
      Inc(V_i);
    end;
  end;
end;

procedure TATAtracGainInfo.copy(Arg_SourceData: TATAtracGainInfo);
begin
  Self.numPoints := Arg_SourceData.numPoints;
  ATCopy(Arg_SourceData.levCode, 0, Self.levCode, 0, Length(levCode));
  ATCopy(Arg_SourceData.locCode, 0, Self.locCode, 0, Length(locCode));
end;

constructor TATWaveEnvelope.Create;
begin
  inherited Create;
end;

procedure TATWaveEnvelope.clear;
begin
  hasStartPoint := False;
  hasStopPoint := False;
  startPos := 0;
  stopPos := 0;
end;

procedure TATWaveEnvelope.copy(Arg_SourceData: TATWaveEnvelope);
begin
  Self.hasStartPoint := Arg_SourceData.hasStartPoint;
  Self.hasStopPoint := Arg_SourceData.hasStopPoint;
  Self.startPos := Arg_SourceData.startPos;
  Self.stopPos := Arg_SourceData.stopPos;
end;

constructor TATWaveParam.Create;
begin
  inherited Create;
end;

procedure TATWaveParam.clear;
begin
  freqIndex := 0;
  ampSf := 0;
  ampIndex := 0;
  phaseIndex := 0;
end;

constructor TATWavesData.Create;
begin
  inherited Create;
  pendEnv := TATWaveEnvelope.Create();
  currEnv := TATWaveEnvelope.Create();
end;

procedure TATWavesData.clear;
begin
  pendEnv.clear;
  currEnv.clear;
  numWavs := 0;
  startIndex := 0;
end;

procedure TATWavesData.copy(Arg_SourceData: TATWavesData);
begin
  Self.pendEnv.copy(Arg_SourceData.pendEnv);
  Self.currEnv.copy(Arg_SourceData.currEnv);
  Self.numWavs := Arg_SourceData.numWavs;
  Self.startIndex := Arg_SourceData.startIndex;
end;

destructor TATWavesData.Destroy;
begin
  pendEnv.Free;
  currEnv.Free;
  inherited;
end;

constructor TATWaveSynthParams.Create;
begin
  inherited Create;
  var Temporary1: TArray<Boolean>;
  SetLength(Temporary1, ATRAC3P_SUBBANDS);
  toneSharing := Temporary1;
  var Temporary2: TArray<Boolean>;
  SetLength(Temporary2, ATRAC3P_SUBBANDS);
  toneMaster := Temporary2;
  var Temporary3: TArray<Boolean>;
  SetLength(Temporary3, ATRAC3P_SUBBANDS);
  phaseShift := Temporary3;
  var Temporary4: TArray<TATWaveParam>;
  SetLength(Temporary4, 48);
  waves := Temporary4;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(waves)) do
    begin
      begin
        waves[V_i] := TATWaveParam.Create();
      end;
      Inc(V_i);
    end;
  end;
end;

destructor TATWaveSynthParams.Destroy;
begin
  for var Item in waves do
    Item.Free;
  inherited;
end;

constructor TATChannel.Create(Arg_chNum: Integer);
begin
  inherited Create;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 32);
  quWordlen := Temporary1;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 32);
  quSfIdx := Temporary2;
  var Temporary3: TArray<Integer>;
  SetLength(Temporary3, 32);
  quTabIdx := Temporary3;
  var Temporary4: TArray<Integer>;
  SetLength(Temporary4, 2048);
  spectrum := Temporary4;
  var Temporary5: TArray<Integer>;
  SetLength(Temporary5, 5);
  powerLevs := Temporary5;
  Self.chNum := Arg_chNum;
  var Temporary6: TArray<TArray<Boolean>>;
  SetLength(Temporary6, 2, ATRAC3P_SUBBANDS);
  wndShapeHist := Temporary6;
  var Temporary7: TArray<TArray<TATAtracGainInfo>>;
  SetLength(Temporary7, 2, ATRAC3P_SUBBANDS);
  gainDataHist := Temporary7;
  var Temporary8: TArray<TArray<TATWavesData>>;
  SetLength(Temporary8, 2, ATRAC3P_SUBBANDS);
  tonesInfoHist := Temporary8;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 2) do
    begin
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ATRAC3P_SUBBANDS) do
          begin
            begin
              gainDataHist[V_i][V_sb] := TATAtracGainInfo.Create();
              tonesInfoHist[V_i][V_sb] := TATWavesData.Create();
            end;
            Inc(V_sb);
          end;
        end;
      end;
      Inc(V_i);
    end;
  end;
  wndShape := wndShapeHist[0];
  wndShapePrev := wndShapeHist[1];
  gainData := gainDataHist[0];
  gainDataPrev := gainDataHist[1];
  tonesInfo := tonesInfoHist[0];
  tonesInfoPrev := tonesInfoHist[1];
end;

destructor TATChannel.Destroy;
begin
  for var Row in gainDataHist do
    for var Item in Row do
      Item.Free;
  for var Row in tonesInfoHist do
    for var Item in Row do
      Item.Free;
  inherited;
end;

constructor TATChannelUnitContext.Create;
begin
  inherited Create;
  var Temporary1: TArray<Boolean>;
  SetLength(Temporary1, ATRAC3P_SUBBANDS);
  swapChannels := Temporary1;
  var Temporary2: TArray<Boolean>;
  SetLength(Temporary2, ATRAC3P_SUBBANDS);
  negateCoeffs := Temporary2;
  var Temporary3: TArray<TATChannel>;
  SetLength(Temporary3, 2);
  channels := Temporary3;
  var Temporary4: TArray<TATWaveSynthParams>;
  SetLength(Temporary4, 2);
  waveSynthHist := Temporary4;
  var Temporary5: TArray<TATIPQFChannelContext>;
  SetLength(Temporary5, 2);
  ipqfCtx := Temporary5;
  var Temporary6: TArray<TArray<Single>>;
  SetLength(Temporary6, 2, ATRAC3P_FRAME_SAMPLES);
  prevBuf := Temporary6;
  begin
    var V_ch: Integer;
    V_ch := 0;
    while (V_ch < Length(channels)) do
    begin
      begin
        channels[V_ch] := TATChannel.Create(V_ch);
      end;
      Inc(V_ch);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(waveSynthHist)) do
    begin
      begin
        waveSynthHist[V_i] := TATWaveSynthParams.Create();
      end;
      Inc(V_i);
    end;
  end;
  wavesInfo := waveSynthHist[0];
  wavesInfoPrev := waveSynthHist[1];
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(ipqfCtx)) do
    begin
      begin
        ipqfCtx[V_i] := TATIPQFChannelContext.Create();
      end;
      Inc(V_i);
    end;
  end;
end;

destructor TATChannelUnitContext.Destroy;
begin
  for var Item in channels do
    Item.Free;
  for var Item in waveSynthHist do
    Item.Free;
  for var Item in ipqfCtx do
    Item.Free;
  inherited;
end;

constructor TATAtrac.Create;
begin
  inherited Create;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, 16);
  gainTab1 := Temporary1;
  var Temporary2: TArray<Single>;
  SetLength(Temporary2, 31);
  gainTab2 := Temporary2;
end;

class procedure TATAtrac.generateTables;
begin
  if ((ff_atrac_sf_table[63] = 0.0)) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < 64) do
      begin
        begin
          ff_atrac_sf_table[V_i] := Single(Power(2.0, (((V_i - 15)) / 3.0)));
        end;
        Inc(V_i);
      end;
    end;
  end;
  if ((qmf_window[47] = 0.0)) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < 24) do
      begin
        begin
          var V_s: Single;
          V_s := (qmf_48tap_half[V_i] * 2.0);
          qmf_window[V_i] := V_s;
          qmf_window[(47 - V_i)] := V_s;
        end;
        Inc(V_i);
      end;
    end;
  end;
end;

procedure TATAtrac.initGainCompensation(Arg_id2expOffset: Integer; Arg_locScale: Integer);
begin
  Self.locScale := Arg_locScale;
  Self.locSize := Integer(Cardinal(1) shl Arg_locScale);
  Self.id2expOffset := Arg_id2expOffset;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 16) do
    begin
      begin
        gainTab1[V_i] := Single(Power(2, (Arg_id2expOffset - V_i)));
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := -15;
    while (V_i < 16) do
    begin
      begin
        gainTab2[(V_i + 15)] := Single(Power(2, ((-(1.0) / locSize) * V_i)));
      end;
      Inc(V_i);
    end;
  end;
end;

procedure TATAtrac.gainCompensation(Arg_InputData: TArray<Single>; Arg_inOffset: Integer; Arg_prev: TArray<Single>; Arg_prevOffset: Integer; Arg_gcNow: TATAtracGainInfo; Arg_gcNext: TATAtracGainInfo; Arg_numSamples: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer);
begin
  var V_gcScale: Single;
  var Temporary1: Single;
  if (Arg_gcNext.numPoints <> 0) then
  begin
    Temporary1 := gainTab1[Arg_gcNext.levCode[0]];
  end
  else
  begin
    Temporary1 := 1.0;
  end;
  V_gcScale := (Temporary1);
  if ((Arg_gcNow.numPoints = 0)) then
  begin
    begin
      var V_pos: Integer;
      V_pos := 0;
      while (V_pos < Arg_numSamples) do
      begin
        begin
          Arg_OutputData[(Arg_outOffset + V_pos)] := ((Arg_InputData[(Arg_inOffset + V_pos)] * V_gcScale) +
            Arg_prev[(Arg_prevOffset + V_pos)]);
        end;
        Inc(V_pos);
      end;
    end;
  end
  else
  begin
    var V_pos: Integer;
    V_pos := 0;
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < Arg_gcNow.numPoints) do
      begin
        begin
          var V_lastpos: Integer;
          V_lastpos := Integer(Cardinal(Arg_gcNow.locCode[V_i]) shl locScale);
          var V_lev: Single;
          V_lev := gainTab1[Arg_gcNow.levCode[V_i]];
          var V_gainInc: Single;
          var Temporary2: Integer;
          if ((V_i + 1) < Arg_gcNow.numPoints) then
          begin
            Temporary2 := Arg_gcNow.levCode[(V_i + 1)];
          end
          else
          begin
            Temporary2 := id2expOffset;
          end;
          V_gainInc := gainTab2[(((Temporary2) - Arg_gcNow.levCode[V_i]) + 15)];
          begin
            while (V_pos < V_lastpos) do
            begin
              begin
                Arg_OutputData[(Arg_outOffset + V_pos)] := ((((Arg_InputData[(Arg_inOffset + V_pos)] *
                  V_gcScale) + Arg_prev[(Arg_prevOffset + V_pos)])) * V_lev);
              end;
              Inc(V_pos);
            end;
          end;
          begin
            while (V_pos < (V_lastpos + locSize)) do
            begin
              begin
                Arg_OutputData[(Arg_outOffset + V_pos)] := ((((Arg_InputData[(Arg_inOffset + V_pos)] *
                  V_gcScale) + Arg_prev[(Arg_prevOffset + V_pos)])) * V_lev);
                V_lev := (V_lev * V_gainInc);
              end;
              Inc(V_pos);
            end;
          end;
        end;
        Inc(V_i);
      end;
    end;
    begin
      while (V_pos < Arg_numSamples) do
      begin
        begin
          Arg_OutputData[(Arg_outOffset + V_pos)] := ((Arg_InputData[(Arg_inOffset + V_pos)] * V_gcScale) +
            Arg_prev[(Arg_prevOffset + V_pos)]);
        end;
        Inc(V_pos);
      end;
    end;
  end;
  ATCopy(Arg_InputData, (Arg_inOffset + Arg_numSamples), Arg_prev, Arg_prevOffset, Arg_numSamples);
end;

class procedure TATAtrac.iqmf(Arg_inlo: TArray<Single>; Arg_inloOffset: Integer; Arg_inhi: TArray<Single>; Arg_inhiOffset: Integer; Arg_nIn: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer; Arg_delayBuf: TArray<Single>; Arg_temp: TArray<Single>);
begin
  ATCopy(Arg_delayBuf, 0, Arg_temp, 0, 46);
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Arg_nIn) do
    begin
      begin
        Arg_temp[((46 + (2 * V_i)) + 0)] := (Arg_inlo[(Arg_inloOffset + V_i)] + Arg_inhi[(Arg_inhiOffset +
            V_i)]);
        Arg_temp[((46 + (2 * V_i)) + 1)] := (Arg_inlo[(Arg_inloOffset + V_i)] - Arg_inhi[(Arg_inhiOffset +
            V_i)]);
        Arg_temp[((46 + (2 * V_i)) + 2)] := (Arg_inlo[((Arg_inloOffset + V_i) + 1)] +
          Arg_inhi[((Arg_inhiOffset + V_i) + 1)]);
        Arg_temp[((46 + (2 * V_i)) + 3)] := (Arg_inlo[((Arg_inloOffset + V_i) + 1)] -
          Arg_inhi[((Arg_inhiOffset + V_i) + 1)]);
      end;
      V_i := (V_i + 2);
    end;
  end;
  var V_p1: Integer;
  V_p1 := 0;
  begin
    var V_j: Integer;
    V_j := Arg_nIn;
    while (V_j <> 0) do
    begin
      begin
        var V_s1: Single;
        V_s1 := 0.0;
        var V_s2: Single;
        V_s2 := 0.0;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < 48) do
          begin
            begin
              V_s1 := (V_s1 + (Arg_temp[(V_p1 + V_i)] * qmf_window[V_i]));
              V_s2 := (V_s2 + (Arg_temp[((V_p1 + V_i) + 1)] * qmf_window[(V_i + 1)]));
            end;
            V_i := (V_i + 2);
          end;
        end;
        Arg_OutputData[(Arg_outOffset + 0)] := V_s2;
        Arg_OutputData[(Arg_outOffset + 1)] := V_s1;
        V_p1 := (V_p1 + 2);
        Arg_outOffset := (Arg_outOffset + 2);
      end;
      Dec(V_j);
    end;
  end;
  ATCopy(Arg_temp, (Arg_nIn * 2), Arg_delayBuf, 0, 46);
end;

constructor TATAtrac3plusDsp.Create;
begin
  inherited Create;
end;

class function TATAtrac3plusDsp.DEQUANT_PHASE(Arg_ph: Integer): Integer;
begin
  Exit(Integer(Cardinal(((Arg_ph and 31))) shl 6));
end;

procedure TATAtrac3plusDsp.initImdct(Arg_mdctCtx: TATIMDCT);
begin
  ATInitSineWindows;
  Arg_mdctCtx.mdctInit(8, True, -(1.0));
end;

class procedure TATAtrac3plusDsp.initWaveSynth;
begin
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 2048) do
    begin
      begin
        sine_table[V_i] := Single(Sin(((TWOPI * V_i) / 2048)));
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 256) do
    begin
      begin
        hann_window[V_i] := Single(((((1.0 - Cos(((TWOPI * V_i) / 256)))) * 0.5)));
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 64) do
    begin
      begin
        amp_sf_tab[V_i] := Single(Power(2.0, ((Double(((V_i - 3)))) / 4.0)));
      end;
      Inc(V_i);
    end;
  end;
end;

procedure TATAtrac3plusDsp.powerCompensation(Arg_ctx: TATChannelUnitContext; Arg_chIndex: Integer; Arg_sp: TArray<Single>; Arg_rngIndex: Integer; Arg_sb: Integer);
begin
  var V_pwcsp: TArray<Single>;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, ATRAC3P_SUBBAND_SAMPLES);
  V_pwcsp := Temporary1;
  var V_gcv: Integer;
  V_gcv := 0;
  var V_swapCh: Integer;
  var Temporary2: Integer;
  if ((Arg_ctx.unitType = CH_UNIT_STEREO) and Arg_ctx.swapChannels[Arg_sb]) then
  begin
    Temporary2 := 1;
  end
  else
  begin
    Temporary2 := 0;
  end;
  V_swapCh := (Temporary2);
  if ((Arg_ctx.channels[(Arg_chIndex xor V_swapCh)].powerLevs[subband_to_powgrp[Arg_sb]] =
    ATRAC3P_POWER_COMP_OFF)) then
  begin
    Exit;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < ATRAC3P_SUBBAND_SAMPLES) do
    begin
      begin
        V_pwcsp[V_i] := noise_tab[(Arg_rngIndex and 1023)];
      end;
      Inc(V_i);
      Inc(Arg_rngIndex);
    end;
  end;
  var V_g1: TATAtracGainInfo;
  V_g1 := Arg_ctx.channels[(Arg_chIndex xor V_swapCh)].gainData[Arg_sb];
  var V_g2: TATAtracGainInfo;
  V_g2 := Arg_ctx.channels[(Arg_chIndex xor V_swapCh)].gainDataPrev[Arg_sb];
  var V_gainLev: Integer;
  var Temporary3: Integer;
  if (V_g1.numPoints > 0) then
  begin
    Temporary3 := ((6 - V_g1.levCode[0]));
  end
  else
  begin
    Temporary3 := 0;
  end;
  V_gainLev := (Temporary3);
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < V_g2.numPoints) do
    begin
      begin
        V_gcv := Max(V_gcv, (V_gainLev - ((V_g2.levCode[V_i] - 6))));
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < V_g1.numPoints) do
    begin
      begin
        V_gcv := Max(V_gcv, (6 - V_g1.levCode[V_i]));
      end;
      Inc(V_i);
    end;
  end;
  var V_grpLev: Single;
  V_grpLev := (pwc_levs[Arg_ctx.channels[(Arg_chIndex xor V_swapCh)].powerLevs[subband_to_powgrp[Arg_sb]]] /
    (Integer(Cardinal(1) shl V_gcv)));
  begin
    var V_qu: Integer;
    var Temporary4: Integer;
    if (Arg_sb = 0) then
    begin
      Temporary4 := 2;
    end
    else
    begin
      Temporary4 := 0;
    end;
    V_qu := (subband_to_qu[Arg_sb] + (Temporary4));
    while (V_qu < subband_to_qu[(Arg_sb + 1)]) do
    begin
      begin
        if ((Arg_ctx.channels[Arg_chIndex].quWordlen[V_qu] <= 0)) then
        begin
          Inc(V_qu);
          Continue;
        end;
        var V_quLev: Single;
        V_quLev := (((ff_atrac3p_sf_tab[Arg_ctx.channels[Arg_chIndex].quSfIdx[V_qu]] *
          ff_atrac3p_mant_tab[Arg_ctx.channels[Arg_chIndex].quWordlen[V_qu]]) / (Integer(Cardinal(1) shl
            Arg_ctx.channels[Arg_chIndex].quWordlen[V_qu]))) * V_grpLev);
        var V_dst: Integer;
        V_dst := ff_atrac3p_qu_to_spec_pos[V_qu];
        var V_nsp: Integer;
        V_nsp := (ff_atrac3p_qu_to_spec_pos[(V_qu + 1)] - ff_atrac3p_qu_to_spec_pos[V_qu]);
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_nsp) do
          begin
            begin
              Arg_sp[(V_dst + V_i)] := (Arg_sp[(V_dst + V_i)] + (V_pwcsp[V_i] * V_quLev));
            end;
            Inc(V_i);
          end;
        end;
      end;
      Inc(V_qu);
    end;
  end;
end;

procedure TATAtrac3plusDsp.imdct(Arg_mdctCtx: TATIMDCT; Arg_InputData: TArray<Single>; Arg_inOffset: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer; Arg_windId: Integer; Arg_sb: Integer);
begin
  if ((((Arg_sb and 1)) <> 0)) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < (ATRAC3P_SUBBAND_SAMPLES div 2)) do
      begin
        begin
          var V_tmp: Single;
          V_tmp := Arg_InputData[(Arg_inOffset + V_i)];
          Arg_InputData[(Arg_inOffset + V_i)] := Arg_InputData[(((Arg_inOffset + ATRAC3P_SUBBAND_SAMPLES) - 1)
              - V_i)];
          Arg_InputData[(((Arg_inOffset + ATRAC3P_SUBBAND_SAMPLES) - 1) - V_i)] := V_tmp;
        end;
        Inc(V_i);
      end;
    end;
  end;
  Arg_mdctCtx.imdctCalc(Arg_OutputData, Arg_outOffset, Arg_InputData, Arg_inOffset);
  if ((((Arg_windId and 2)) <> 0)) then
  begin
    ATFill(Arg_OutputData, Arg_outOffset, (Arg_outOffset + 32), 0.0);
    vectorFmul(Arg_OutputData, (Arg_outOffset + 32), Arg_OutputData, (Arg_outOffset + 32), ff_sine_64, 0, 64);
  end
  else
  begin
    vectorFmul(Arg_OutputData, Arg_outOffset, Arg_OutputData, Arg_outOffset, ff_sine_128, 0,
      (ATRAC3P_MDCT_SIZE div 2));
  end;
  if ((((Arg_windId and 1)) <> 0)) then
  begin
    vectorFmulReverse(Arg_OutputData, (Arg_outOffset + 160), Arg_OutputData, (Arg_outOffset + 160),
      ff_sine_64, 0, 64);
    ATFill(Arg_OutputData, (Arg_outOffset + 224), ((Arg_outOffset + 224) + 32), 0.0);
  end
  else
  begin
    vectorFmulReverse(Arg_OutputData, (Arg_outOffset + 128), Arg_OutputData, (Arg_outOffset + 128),
      ff_sine_128, 0, (ATRAC3P_MDCT_SIZE div 2));
  end;
end;

procedure TATAtrac3plusDsp.wavesSynth(Arg_synthParams: TATWaveSynthParams; Arg_wavesInfo: TATWavesData; Arg_envelope: TATWaveEnvelope; Arg_phaseShift: Boolean; Arg_regOffset: Integer; Arg_OutputData: TArray<Single>);
begin
  var V_waveParam: Integer;
  V_waveParam := Arg_wavesInfo.startIndex;
  begin
    var V_wn: Integer;
    V_wn := 0;
    while (V_wn < Arg_wavesInfo.numWavs) do
    begin
      begin
        var V_amp: Double;
        var Temporary1: Single;
        if (Arg_synthParams.amplitudeMode = 0) then
        begin
          Temporary1 := (((Arg_synthParams.waves[V_waveParam].ampIndex + 1)) / 15.13);
        end
        else
        begin
          Temporary1 := 1.0;
        end;
        V_amp := (amp_sf_tab[Arg_synthParams.waves[V_waveParam].ampSf] * (Temporary1));
        var V_inc: Integer;
        V_inc := Arg_synthParams.waves[V_waveParam].freqIndex;
        var V_pos: Integer;
        V_pos := ((DEQUANT_PHASE(Arg_synthParams.waves[V_waveParam].phaseIndex) - (((Arg_regOffset xor 128)) *
          V_inc)) and 2047);
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < 128) do
          begin
            begin
              Arg_OutputData[V_i] := (Arg_OutputData[V_i] + (sine_table[V_pos] * V_amp));
              V_pos := (((V_pos + V_inc)) and 2047);
            end;
            Inc(V_i);
          end;
        end;
      end;
      Inc(V_wn);
      Inc(V_waveParam);
    end;
  end;
  if (Arg_phaseShift) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < 128) do
      begin
        begin
          Arg_OutputData[V_i] := -(Arg_OutputData[V_i]);
        end;
        Inc(V_i);
      end;
    end;
  end;
  if (Arg_envelope.hasStartPoint) then
  begin
    var V_pos: Integer;
    V_pos := ((Integer(Cardinal(Arg_envelope.startPos) shl 2)) - Arg_regOffset);
    if (((V_pos > 0) and (V_pos <= 128))) then
    begin
      ATFill(Arg_OutputData, 0, V_pos, 0.0);
      if ((not (Arg_envelope.hasStopPoint) or (Arg_envelope.startPos <> Arg_envelope.stopPos))) then
      begin
        Arg_OutputData[(V_pos + 0)] := (Arg_OutputData[(V_pos + 0)] * hann_window[0]);
        Arg_OutputData[(V_pos + 1)] := (Arg_OutputData[(V_pos + 1)] * hann_window[32]);
        Arg_OutputData[(V_pos + 2)] := (Arg_OutputData[(V_pos + 2)] * hann_window[64]);
        Arg_OutputData[(V_pos + 3)] := (Arg_OutputData[(V_pos + 3)] * hann_window[96]);
      end;
    end;
  end;
  if (Arg_envelope.hasStopPoint) then
  begin
    var V_pos: Integer;
    V_pos := ((Integer(Cardinal((Arg_envelope.stopPos + 1)) shl 2)) - Arg_regOffset);
    if (((V_pos > 0) and (V_pos <= 128))) then
    begin
      Arg_OutputData[(V_pos - 4)] := (Arg_OutputData[(V_pos - 4)] * hann_window[96]);
      Arg_OutputData[(V_pos - 3)] := (Arg_OutputData[(V_pos - 3)] * hann_window[64]);
      Arg_OutputData[(V_pos - 2)] := (Arg_OutputData[(V_pos - 2)] * hann_window[32]);
      Arg_OutputData[(V_pos - 1)] := (Arg_OutputData[(V_pos - 1)] * hann_window[0]);
      ATFill(Arg_OutputData, V_pos, 128, 0.0);
    end;
  end;
end;

procedure TATAtrac3plusDsp.generateTones(Arg_ctx: TATChannelUnitContext; Arg_chNum: Integer; Arg_sb: Integer; Arg_OutputData: TArray<Single>; Arg_outOffset: Integer);
begin
  var V_wavreg1: TArray<Single>;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, 128);
  V_wavreg1 := Temporary1;
  var V_wavreg2: TArray<Single>;
  var Temporary2: TArray<Single>;
  SetLength(Temporary2, 128);
  V_wavreg2 := Temporary2;
  var V_tonesNow: TATWavesData;
  V_tonesNow := Arg_ctx.channels[Arg_chNum].tonesInfoPrev[Arg_sb];
  var V_tonesNext: TATWavesData;
  V_tonesNext := Arg_ctx.channels[Arg_chNum].tonesInfo[Arg_sb];
  if ((V_tonesNext.pendEnv.hasStartPoint and (V_tonesNext.pendEnv.startPos < V_tonesNext.pendEnv.stopPos)))
    then
  begin
    V_tonesNext.currEnv.hasStartPoint := True;
    V_tonesNext.currEnv.startPos := (V_tonesNext.pendEnv.startPos + 32);
  end
  else if (V_tonesNow.pendEnv.hasStartPoint) then
  begin
    V_tonesNext.currEnv.hasStartPoint := True;
    V_tonesNext.currEnv.startPos := V_tonesNow.pendEnv.startPos;
  end
  else
  begin
    V_tonesNext.currEnv.hasStartPoint := False;
    V_tonesNext.currEnv.startPos := 0;
  end;
  if ((V_tonesNow.pendEnv.hasStopPoint and (V_tonesNow.pendEnv.stopPos >= V_tonesNext.currEnv.startPos))) then
  begin
    V_tonesNext.currEnv.hasStopPoint := True;
    V_tonesNext.currEnv.stopPos := V_tonesNow.pendEnv.stopPos;
  end
  else if (V_tonesNext.pendEnv.hasStopPoint) then
  begin
    V_tonesNext.currEnv.hasStopPoint := True;
    V_tonesNext.currEnv.stopPos := (V_tonesNext.pendEnv.stopPos + 32);
  end
  else
  begin
    V_tonesNext.currEnv.hasStopPoint := False;
    V_tonesNext.currEnv.stopPos := 64;
  end;
  var V_reg1EnvNonzero: Boolean;
  var Temporary3: Boolean;
  if (V_tonesNow.currEnv.stopPos < 32) then
  begin
    Temporary3 := False;
  end
  else
  begin
    Temporary3 := True;
  end;
  V_reg1EnvNonzero := (Temporary3);
  var V_reg2EnvNonzero: Boolean;
  var Temporary4: Boolean;
  if (V_tonesNext.currEnv.startPos >= 32) then
  begin
    Temporary4 := False;
  end
  else
  begin
    Temporary4 := True;
  end;
  V_reg2EnvNonzero := (Temporary4);
  if (((V_tonesNow.numWavs > 0) and V_reg1EnvNonzero)) then
  begin
    wavesSynth(Arg_ctx.wavesInfoPrev, V_tonesNow, V_tonesNow.currEnv,
      (Arg_ctx.wavesInfoPrev.phaseShift[Arg_sb] and ((Arg_chNum > 0))), 128, V_wavreg1);
  end;
  if (((V_tonesNext.numWavs > 0) and V_reg2EnvNonzero)) then
  begin
    wavesSynth(Arg_ctx.wavesInfo, V_tonesNext, V_tonesNext.currEnv, (Arg_ctx.wavesInfo.phaseShift[Arg_sb] and
      ((Arg_chNum > 0))), 0, V_wavreg2);
  end;
  if (((((V_tonesNow.numWavs > 0) and (V_tonesNext.numWavs > 0)) and V_reg1EnvNonzero) and V_reg2EnvNonzero))
    then
  begin
    vectorFmul(V_wavreg1, 0, V_wavreg1, 0, hann_window, 128, 128);
    vectorFmul(V_wavreg2, 0, V_wavreg2, 0, hann_window, 0, 128);
  end
  else
  begin
    if (((V_tonesNow.numWavs > 0) and not (V_tonesNow.currEnv.hasStopPoint))) then
    begin
      vectorFmul(V_wavreg1, 0, V_wavreg1, 0, hann_window, 128, 128);
    end;
    if (((V_tonesNext.numWavs > 0) and not (V_tonesNext.currEnv.hasStartPoint))) then
    begin
      vectorFmul(V_wavreg2, 0, V_wavreg2, 0, hann_window, 0, 128);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 128) do
    begin
      begin
        Arg_OutputData[(Arg_outOffset + V_i)] := (Arg_OutputData[(Arg_outOffset + V_i)] + (V_wavreg1[V_i] +
          V_wavreg2[V_i]));
      end;
      Inc(V_i);
    end;
  end;
end;

procedure TATAtrac3plusDsp.ipqf(Arg_dctCtx: TATIMDCT; Arg_hist: TATIPQFChannelContext; Arg_InputData: TArray<Single>; Arg_OutputData: TArray<Single>);
begin
  var V_idctIn: TArray<Single>;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, ATRAC3P_SUBBANDS);
  V_idctIn := Temporary1;
  var V_idctOut: TArray<Single>;
  var Temporary2: TArray<Single>;
  SetLength(Temporary2, ATRAC3P_SUBBANDS);
  V_idctOut := Temporary2;
  ATFill(Arg_OutputData, 0, ATRAC3P_FRAME_SAMPLES, 0.0);
  begin
    var V_s: Integer;
    V_s := 0;
    while (V_s < ATRAC3P_SUBBAND_SAMPLES) do
    begin
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ATRAC3P_SUBBANDS) do
          begin
            begin
              V_idctIn[V_sb] := Arg_InputData[((V_sb * ATRAC3P_SUBBAND_SAMPLES) + V_s)];
            end;
            Inc(V_sb);
          end;
        end;
        Arg_dctCtx.imdctHalf(V_idctOut, 0, V_idctIn, 0);
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < 8) do
          begin
            begin
              Arg_hist.buf1[Arg_hist.pos][V_i] := V_idctOut[(V_i + 8)];
              Arg_hist.buf2[Arg_hist.pos][V_i] := V_idctOut[(7 - V_i)];
            end;
            Inc(V_i);
          end;
        end;
        var V_posNow: Integer;
        V_posNow := Arg_hist.pos;
        var V_posNext: Integer;
        V_posNext := mod23_lut[(V_posNow + 2)];
        begin
          var V_t: Integer;
          V_t := 0;
          while (V_t < ATRAC3P_PQF_FIR_LEN) do
          begin
            begin
              begin
                var V_i: Integer;
                V_i := 0;
                while (V_i < 8) do
                begin
                  begin
                    Arg_OutputData[(((V_s * 16) + V_i) + 0)] := (Arg_OutputData[(((V_s * 16) + V_i) + 0)] +
                      ((Arg_hist.buf1[V_posNow][V_i] * ipqf_coeffs1[V_t][V_i]) + (Arg_hist.buf2[V_posNext][V_i] *
                      ipqf_coeffs2[V_t][V_i])));
                    Arg_OutputData[(((V_s * 16) + V_i) + 8)] := (Arg_OutputData[(((V_s * 16) + V_i) + 8)] +
                      ((Arg_hist.buf1[V_posNow][(7 - V_i)] * ipqf_coeffs1[V_t][(V_i + 8)]) + (Arg_hist.buf2[V_posNext][(7 -
                        V_i)] * ipqf_coeffs2[V_t][(V_i + 8)])));
                  end;
                  Inc(V_i);
                end;
              end;
              V_posNow := mod23_lut[(V_posNext + 2)];
              V_posNext := mod23_lut[(V_posNow + 2)];
            end;
            Inc(V_t);
          end;
        end;
        Arg_hist.pos := mod23_lut[Arg_hist.pos];
      end;
      Inc(V_s);
    end;
  end;
end;

constructor TATContext.Create;
begin
  inherited Create;
  var Temporary1: TArray<TATChannelUnit>;
  SetLength(Temporary1, 16);
  channelUnits := Temporary1;
  numChannelBlocks := 2;
  var Temporary2: TArray<TArray<Single>>;
  SetLength(Temporary2, 2, ATRAC3P_FRAME_SAMPLES);
  samples := Temporary2;
  var Temporary3: TArray<TArray<Single>>;
  SetLength(Temporary3, 2, (ATRAC3P_FRAME_SAMPLES + ATRAC3P_SUBBAND_SAMPLES));
  mdctBuf := Temporary3;
  var Temporary4: TArray<TArray<Single>>;
  SetLength(Temporary4, 2, ATRAC3P_FRAME_SAMPLES);
  timeBuf := Temporary4;
  var Temporary5: TArray<TArray<Single>>;
  SetLength(Temporary5, 2, ATRAC3P_FRAME_SAMPLES);
  outpBuf := Temporary5;
end;

destructor TATContext.Destroy;
begin
  dsp.Free;
  gaincCtx.Free;
  mdctCtx.Free;
  ipqfDctCtx.Free;
  for var Item in channelUnits do
    Item.Free;
  inherited;
end;

constructor TATChannelUnit.Create;
begin
  inherited Create;
  ctx := TATChannelUnitContext.Create();
end;

class procedure TATChannelUnit.init;
begin
  if ATTablesReady then
    Exit;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 4) do
    begin
      begin
        wl_vlc_tabs[V_i] := TATVLC.Create();
        wl_vlc_tabs[V_i].initVLCSparse(wl_nb_bits[V_i], wl_nb_codes[V_i], wl_bits[V_i], wl_codes[V_i],
            wl_xlats[V_i]);
        ct_vlc_tabs[V_i] := TATVLC.Create();
        ct_vlc_tabs[V_i].initVLCSparse(ct_nb_bits[V_i], ct_nb_codes[V_i], ct_bits[V_i], ct_codes[V_i],
            ct_xlats[V_i]);
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 8) do
    begin
      begin
        sf_vlc_tabs[V_i] := TATVLC.Create();
        sf_vlc_tabs[V_i].initVLCSparse(sf_nb_bits[V_i], sf_nb_codes[V_i], sf_bits[V_i], sf_codes[V_i],
            sf_xlats[V_i]);
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 112) do
    begin
      begin
        if ((atrac3p_spectra_tabs[V_i].cb <> nil)) then
        begin
          spec_vlc_tabs[V_i] := TATVLC.Create();
          buildCanonicalHuff(atrac3p_spectra_tabs[V_i].cb, atrac3p_spectra_tabs[V_i].xlat, spec_vlc_tabs[V_i]);
        end;
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 11) do
    begin
      begin
        gain_vlc_tabs[V_i] := TATVLC.Create();
        buildCanonicalHuff(gain_cbs[V_i], gain_xlats[V_i], gain_vlc_tabs[V_i]);
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 7) do
    begin
      begin
        tone_vlc_tabs[V_i] := TATVLC.Create();
        buildCanonicalHuff(tone_cbs[V_i], tone_xlats[V_i], tone_vlc_tabs[V_i]);
      end;
      Inc(V_i);
    end;
  end;
  ATTablesReady := True;
end;

class function TATChannelUnit.buildCanonicalHuff(Arg_cb: TArray<Integer>; Arg_xlat: TArray<Integer>; Arg_vlc: TATVLC): Integer;
begin
  var V_codes: TArray<Integer>;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 256);
  V_codes := Temporary1;
  var V_bits: TArray<Integer>;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 256);
  V_bits := Temporary2;
  var V_cbIndex: Integer;
  V_cbIndex := 0;
  var V_index: Integer;
  V_index := 0;
  var V_code: Integer;
  V_code := 0;
  var V_minLen: Integer;
  var Temporary3: Integer;
  Temporary3 := V_cbIndex;
  Inc(V_cbIndex);
  V_minLen := Arg_cb[Temporary3];
  var V_maxLen: Integer;
  var Temporary4: Integer;
  Temporary4 := V_cbIndex;
  Inc(V_cbIndex);
  V_maxLen := Arg_cb[Temporary4];
  begin
    var V_b: Integer;
    V_b := V_minLen;
    while (V_b <= V_maxLen) do
    begin
      begin
        begin
          var V_i: Integer;
          var Temporary5: Integer;
          Temporary5 := V_cbIndex;
          Inc(V_cbIndex);
          V_i := Arg_cb[Temporary5];
          while (V_i > 0) do
          begin
            begin
              V_bits[V_index] := V_b;
              var Temporary6: Integer;
              Temporary6 := V_code;
              Inc(V_code);
              V_codes[V_index] := Temporary6;
              Inc(V_index);
            end;
            Dec(V_i);
          end;
        end;
        V_code := Integer(Cardinal(V_code) shl 1);
      end;
      Inc(V_b);
    end;
  end;
  Exit(Arg_vlc.initVLCSparse(V_maxLen, V_index, V_bits, V_codes, Arg_xlat));
end;

procedure TATChannelUnit.setBitReader(Arg_br: TATBits);
begin
  Self.br := Arg_br;
end;

procedure TATChannelUnit.setDsp(Arg_dsp: TATAtrac3plusDsp);
begin
  Self.dsp := Arg_dsp;
end;

procedure TATChannelUnit.setNumChannels(Arg_numChannels: Integer);
begin
  Self.numChannels := Arg_numChannels;
end;

function TATChannelUnit.decode: Integer;
begin
  var V_ret: Integer;
  ctx.numQuantUnits := (br.read(5) + 1);
  if (((ctx.numQuantUnits > 28) and (ctx.numQuantUnits < 32))) then
  begin
    Exit(AT3P_ERROR);
  end;
  ctx.muteFlag := br.readBool;
  V_ret := decodeQuantWordlen;
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  ctx.numSubbands := (atrac3p_qu_to_subband[(ctx.numQuantUnits - 1)] + 1);
  var Temporary1: Integer;
  if (ctx.usedQuantUnits > 0) then
  begin
    Temporary1 := (atrac3p_qu_to_subband[(ctx.usedQuantUnits - 1)] + 1);
  end
  else
  begin
    Temporary1 := 0;
  end;
  ctx.numCodedSubbands := Temporary1;
  V_ret := decodeScaleFactors;
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  V_ret := decodeCodeTableIndexes;
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  decodeSpectrum;
  if ((numChannels = 2)) then
  begin
    getSubbandFlags(ctx.swapChannels, ctx.numCodedSubbands);
    getSubbandFlags(ctx.negateCoeffs, ctx.numCodedSubbands);
  end;
  decodeWindowShape;
  V_ret := decodeGaincData;
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  V_ret := decodeTonesInfo;
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  ctx.noisePresent := br.readBool;
  if (ctx.noisePresent) then
  begin
    ctx.noiseLevelIndex := br.read(4);
    ctx.noiseTableIndex := br.read(4);
  end;
  Exit(0);
end;

function TATChannelUnit.numCodedUnits(Arg_chan: TATChannel): Integer;
begin
  Arg_chan.fillMode := br.read(2);
  if ((Arg_chan.fillMode = 0)) then
  begin
    Arg_chan.numCodedVals := ctx.numQuantUnits;
  end
  else
  begin
    Arg_chan.numCodedVals := br.read(5);
    if ((Arg_chan.numCodedVals > ctx.numQuantUnits)) then
    begin
      Exit(AT3P_ERROR);
    end;
    if ((Arg_chan.fillMode = 3)) then
    begin
      Arg_chan.splitPoint := ((br.read(2) + (Integer(Cardinal(Arg_chan.chNum) shl 1))) + 1);
    end;
  end;
  Exit(0);
end;

function TATChannelUnit.getDelta(Arg_deltaBits: Integer): Integer;
begin
  var Temporary1: Integer;
  if (Arg_deltaBits <= 0) then
  begin
    Temporary1 := 0;
  end
  else
  begin
    Temporary1 := br.read(Arg_deltaBits);
  end;
  Exit(Temporary1);
end;

procedure TATChannelUnit.unpackVqShape(Arg_startVal: Integer; Arg_shapeVec: TArray<Integer>; Arg_dst: TArray<Integer>; Arg_numValues: Integer);
begin
  if ((Arg_numValues > 0)) then
  begin
    Arg_dst[0] := Arg_startVal;
    Arg_dst[1] := Arg_startVal;
    Arg_dst[2] := Arg_startVal;
    begin
      var V_i: Integer;
      V_i := 3;
      while (V_i < Arg_numValues) do
      begin
        begin
          Arg_dst[V_i] := (Arg_startVal - Arg_shapeVec[(atrac3p_qu_num_to_seg[V_i] - 1)]);
        end;
        Inc(V_i);
      end;
    end;
  end;
end;

procedure TATChannelUnit.unpackSfVqShape(Arg_dst: TArray<Integer>; Arg_numValues: Integer);
begin
  var V_startVal: Integer;
  V_startVal := br.read(6);
  unpackVqShape(V_startVal, atrac3p_sf_shapes[br.read(6)], Arg_dst, Arg_numValues);
end;

function TATChannelUnit.addWordlenWeights(Arg_chan: TATChannel; Arg_weightIdx: Integer): Integer;
begin
  var V_weigthsTab: TArray<Integer>;
  V_weigthsTab := atrac3p_wl_weights[(((Arg_chan.chNum * 3) + Arg_weightIdx) - 1)];
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < ctx.numQuantUnits) do
    begin
      begin
        Arg_chan.quWordlen[V_i] := (Arg_chan.quWordlen[V_i] + V_weigthsTab[V_i]);
        if (((Arg_chan.quWordlen[V_i] < 0) or (Arg_chan.quWordlen[V_i] > 7))) then
        begin
          Exit(AT3P_ERROR);
        end;
      end;
      Inc(V_i);
    end;
  end;
  Exit(0);
end;

function TATChannelUnit.decodeChannelWordlen(Arg_chNum: Integer): Integer;
begin
  var V_ret: Integer;
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  var V_weightIdx: Integer;
  V_weightIdx := 0;
  V_chan.fillMode := 0;
  case (br.read(2)) of
    0:
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < ctx.numQuantUnits) do
          begin
            begin
              V_chan.quWordlen[V_i] := br.read(3);
            end;
            Inc(V_i);
          end;
        end;
      end;
    1:
      begin
        if ((Arg_chNum > 0)) then
        begin
          V_ret := numCodedUnits(V_chan);
          if ((V_ret < 0)) then
          begin
            Exit(V_ret);
          end;
          if ((V_chan.numCodedVals > 0)) then
          begin
            var V_vlcTab: TATVLC;
            V_vlcTab := wl_vlc_tabs[br.read(2)];
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_chan.numCodedVals) do
              begin
                begin
                  var V_delta: Integer;
                  V_delta := V_vlcTab.getVLC2(br);
                  V_chan.quWordlen[V_i] := (((V_refChan.quWordlen[V_i] + V_delta)) and 7);
                end;
                Inc(V_i);
              end;
            end;
          end;
        end
        else
        begin
          V_weightIdx := br.read(2);
          V_ret := numCodedUnits(V_chan);
          if ((V_ret < 0)) then
          begin
            Exit(V_ret);
          end;
          if ((V_chan.numCodedVals > 0)) then
          begin
            var V_pos: Integer;
            V_pos := br.read(5);
            if ((V_pos > V_chan.numCodedVals)) then
            begin
              Exit(AT3P_ERROR);
            end;
            var V_deltaBits: Integer;
            V_deltaBits := br.read(2);
            var V_minVal: Integer;
            V_minVal := br.read(3);
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_pos) do
              begin
                begin
                  V_chan.quWordlen[V_i] := br.read(3);
                end;
                Inc(V_i);
              end;
            end;
            begin
              var V_i: Integer;
              V_i := V_pos;
              while (V_i < V_chan.numCodedVals) do
              begin
                begin
                  V_chan.quWordlen[V_i] := (((V_minVal + getDelta(V_deltaBits))) and 7);
                end;
                Inc(V_i);
              end;
            end;
          end;
        end;
      end;
    2:
      begin
        V_ret := numCodedUnits(V_chan);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
        if (((Arg_chNum > 0) and (V_chan.numCodedVals > 0))) then
        begin
          var V_vlcTab: TATVLC;
          V_vlcTab := wl_vlc_tabs[br.read(2)];
          var V_delta: Integer;
          V_delta := V_vlcTab.getVLC2(br);
          V_chan.quWordlen[0] := (((V_refChan.quWordlen[0] + V_delta)) and 7);
          begin
            var V_i: Integer;
            V_i := 1;
            while (V_i < V_chan.numCodedVals) do
            begin
              begin
                var V_diff: Integer;
                V_diff := (V_refChan.quWordlen[V_i] - V_refChan.quWordlen[(V_i - 1)]);
                V_delta := V_vlcTab.getVLC2(br);
                V_chan.quWordlen[V_i] := ((((V_chan.quWordlen[(V_i - 1)] + V_diff) + V_delta)) and 7);
              end;
              Inc(V_i);
            end;
          end;
        end
        else if ((V_chan.numCodedVals > 0)) then
        begin
          var V_flag: Boolean;
          V_flag := br.readBool;
          var V_vlcTab: TATVLC;
          V_vlcTab := wl_vlc_tabs[br.read(1)];
          var V_startVal: Integer;
          V_startVal := br.read(3);
          unpackVqShape(V_startVal, atrac3p_wl_shapes[V_startVal][br.read(4)], V_chan.quWordlen,
            V_chan.numCodedVals);
          if (not (V_flag)) then
          begin
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_chan.numCodedVals) do
              begin
                begin
                  var V_delta: Integer;
                  V_delta := V_vlcTab.getVLC2(br);
                  V_chan.quWordlen[V_i] := (((V_chan.quWordlen[V_i] + V_delta)) and 7);
                end;
                Inc(V_i);
              end;
            end;
          end
          else
          begin
            var V_i: Integer;
            begin
              V_i := 0;
              while (V_i < ((V_chan.numCodedVals and  - 2))) do
              begin
                begin
                  if (not (br.readBool)) then
                  begin
                    V_chan.quWordlen[V_i] := (((V_chan.quWordlen[V_i] + V_vlcTab.getVLC2(br))) and 7);
                    V_chan.quWordlen[(V_i + 1)] := (((V_chan.quWordlen[(V_i + 1)] + V_vlcTab.getVLC2(br))) and
                      7);
                  end;
                end;
                V_i := (V_i + 2);
              end;
            end;
            if ((((V_chan.numCodedVals and 1)) <> 0)) then
            begin
              V_chan.quWordlen[V_i] := (((V_chan.quWordlen[V_i] + V_vlcTab.getVLC2(br))) and 7);
            end;
          end;
        end;
      end;
    3:
      begin
        V_weightIdx := br.read(2);
        V_ret := numCodedUnits(V_chan);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
        if ((V_chan.numCodedVals > 0)) then
        begin
          var V_vlcTab: TATVLC;
          V_vlcTab := wl_vlc_tabs[br.read(2)];
          V_chan.quWordlen[0] := br.read(3);
          begin
            var V_i: Integer;
            V_i := 1;
            while (V_i < V_chan.numCodedVals) do
            begin
              begin
                var V_delta: Integer;
                V_delta := V_vlcTab.getVLC2(br);
                V_chan.quWordlen[V_i] := (((V_chan.quWordlen[(V_i - 1)] + V_delta)) and 7);
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
  end;
  if ((V_chan.fillMode = 2)) then
  begin
    begin
      var V_i: Integer;
      V_i := V_chan.numCodedVals;
      while (V_i < ctx.numQuantUnits) do
      begin
        begin
          var Temporary1: Integer;
          if (Arg_chNum > 0) then
          begin
            Temporary1 := br.read1;
          end
          else
          begin
            Temporary1 := 1;
          end;
          V_chan.quWordlen[V_i] := (Temporary1);
        end;
        Inc(V_i);
      end;
    end;
  end
  else if ((V_chan.fillMode = 3)) then
  begin
    var V_pos: Integer;
    var Temporary2: Integer;
    if (Arg_chNum > 0) then
    begin
      Temporary2 := (V_chan.numCodedVals + V_chan.splitPoint);
    end
    else
    begin
      Temporary2 := (ctx.numQuantUnits - V_chan.splitPoint);
    end;
    V_pos := (Temporary2);
    begin
      var V_i: Integer;
      V_i := V_chan.numCodedVals;
      while (V_i < V_pos) do
      begin
        begin
          V_chan.quWordlen[V_i] := 1;
        end;
        Inc(V_i);
      end;
    end;
  end;
  if ((V_weightIdx <> 0)) then
  begin
    Exit(addWordlenWeights(V_chan, V_weightIdx));
  end;
  Exit(0);
end;

function TATChannelUnit.substractSfWeights(Arg_chan: TATChannel; Arg_wtabIdx: Integer): Integer;
begin
  var V_weigthsTab: TArray<Integer>;
  V_weigthsTab := atrac3p_sf_weights[(Arg_wtabIdx - 1)];
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < ctx.usedQuantUnits) do
    begin
      begin
        Arg_chan.quSfIdx[V_i] := (Arg_chan.quSfIdx[V_i] - V_weigthsTab[V_i]);
        if (((Arg_chan.quSfIdx[V_i] < 0) or (Arg_chan.quSfIdx[V_i] > 63))) then
        begin
          Exit(AT3P_ERROR);
        end;
      end;
      Inc(V_i);
    end;
  end;
  Exit(0);
end;

function TATChannelUnit.decodeChannelSfIdx(Arg_chNum: Integer): Integer;
begin
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  var V_weightIdx: Integer;
  V_weightIdx := 0;
  V_chan.fillMode := 0;
  case (br.read(2)) of
    0:
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < ctx.usedQuantUnits) do
          begin
            begin
              V_chan.quSfIdx[V_i] := br.read(6);
            end;
            Inc(V_i);
          end;
        end;
      end;
    1:
      begin
        if ((Arg_chNum > 0)) then
        begin
          var V_vlcTab: TATVLC;
          V_vlcTab := sf_vlc_tabs[br.read(2)];
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < ctx.usedQuantUnits) do
            begin
              begin
                var V_delta: Integer;
                V_delta := V_vlcTab.getVLC2(br);
                V_chan.quSfIdx[V_i] := (((V_refChan.quSfIdx[V_i] + V_delta)) and 63);
              end;
              Inc(V_i);
            end;
          end;
        end
        else
        begin
          V_weightIdx := br.read(2);
          if ((V_weightIdx = 3)) then
          begin
            unpackSfVqShape(V_chan.quSfIdx, ctx.usedQuantUnits);
            var V_numLongVals: Integer;
            V_numLongVals := br.read(5);
            var V_deltaBits: Integer;
            V_deltaBits := br.read(2);
            var V_minVal: Integer;
            V_minVal := (br.read(4) - 7);
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_numLongVals) do
              begin
                begin
                  V_chan.quSfIdx[V_i] := ((((V_chan.quSfIdx[V_i] + br.read(4)) - 7)) and 63);
                end;
                Inc(V_i);
              end;
            end;
            begin
              var V_i: Integer;
              V_i := V_numLongVals;
              while (V_i < ctx.usedQuantUnits) do
              begin
                begin
                  V_chan.quSfIdx[V_i] := ((((V_chan.quSfIdx[V_i] + V_minVal) + getDelta(V_deltaBits))) and 63);
                end;
                Inc(V_i);
              end;
            end;
          end
          else
          begin
            var V_numLongVals: Integer;
            V_numLongVals := br.read(5);
            var V_deltaBits: Integer;
            V_deltaBits := br.read(3);
            var V_minVal: Integer;
            V_minVal := br.read(6);
            if (((V_numLongVals > ctx.usedQuantUnits) or (V_deltaBits = 7))) then
            begin
              Exit(AT3P_ERROR);
            end;
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_numLongVals) do
              begin
                begin
                  V_chan.quSfIdx[V_i] := br.read(6);
                end;
                Inc(V_i);
              end;
            end;
            begin
              var V_i: Integer;
              V_i := V_numLongVals;
              while (V_i < ctx.usedQuantUnits) do
              begin
                begin
                  V_chan.quSfIdx[V_i] := (((V_minVal + getDelta(V_deltaBits))) and 63);
                end;
                Inc(V_i);
              end;
            end;
          end;
        end;
      end;
    2:
      begin
        if ((Arg_chNum > 0)) then
        begin
          var V_vlcTab: TATVLC;
          V_vlcTab := sf_vlc_tabs[br.read(2)];
          var V_delta: Integer;
          V_delta := V_vlcTab.getVLC2(br);
          V_chan.quSfIdx[0] := (((V_refChan.quSfIdx[0] + V_delta)) and 63);
          begin
            var V_i: Integer;
            V_i := 1;
            while (V_i < ctx.usedQuantUnits) do
            begin
              begin
                var V_diff: Integer;
                V_diff := (V_refChan.quSfIdx[V_i] - V_refChan.quSfIdx[(V_i - 1)]);
                V_delta := V_vlcTab.getVLC2(br);
                V_chan.quSfIdx[V_i] := ((((V_chan.quSfIdx[(V_i - 1)] + V_diff) + V_delta)) and 63);
              end;
              Inc(V_i);
            end;
          end;
        end
        else if ((V_chan.numCodedVals > 0)) then
        begin
          var V_vlcTab: TATVLC;
          V_vlcTab := sf_vlc_tabs[(br.read(2) + 4)];
          unpackSfVqShape(V_chan.quSfIdx, ctx.usedQuantUnits);
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < ctx.usedQuantUnits) do
            begin
              begin
                var V_delta: Integer;
                V_delta := V_vlcTab.getVLC2(br);
                V_chan.quSfIdx[V_i] := (((V_chan.quSfIdx[V_i] + ATSigned(V_delta, 4))) and 63);
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
    3:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < ctx.usedQuantUnits) do
            begin
              begin
                V_chan.quSfIdx[V_i] := V_refChan.quSfIdx[V_i];
              end;
              Inc(V_i);
            end;
          end;
        end
        else
        begin
          V_weightIdx := br.read(2);
          var V_vlcSel: Integer;
          V_vlcSel := br.read(2);
          var V_vlcTab: TATVLC;
          V_vlcTab := sf_vlc_tabs[V_vlcSel];
          if ((V_weightIdx = 3)) then
          begin
            V_vlcTab := sf_vlc_tabs[(V_vlcSel + 4)];
            unpackSfVqShape(V_chan.quSfIdx, ctx.usedQuantUnits);
            var V_diff: Integer;
            V_diff := (((br.read(4) + 56)) and 63);
            V_chan.quSfIdx[0] := (((V_chan.quSfIdx[0] + V_diff)) and 63);
            begin
              var V_i: Integer;
              V_i := 1;
              while (V_i < ctx.usedQuantUnits) do
              begin
                begin
                  var V_delta: Integer;
                  V_delta := V_vlcTab.getVLC2(br);
                  V_diff := (((V_diff + ATSigned(V_delta, 4))) and 63);
                  V_chan.quSfIdx[V_i] := (((V_diff + V_chan.quSfIdx[V_i])) and 63);
                end;
                Inc(V_i);
              end;
            end;
          end
          else
          begin
            V_chan.quSfIdx[0] := br.read(6);
            begin
              var V_i: Integer;
              V_i := 1;
              while (V_i < ctx.usedQuantUnits) do
              begin
                begin
                  var V_delta: Integer;
                  V_delta := V_vlcTab.getVLC2(br);
                  V_chan.quSfIdx[V_i] := (((V_chan.quSfIdx[(V_i - 1)] + V_delta)) and 63);
                end;
                Inc(V_i);
              end;
            end;
          end;
        end;
      end;
  end;
  if (((V_weightIdx <> 0) and (V_weightIdx < 3))) then
  begin
    Exit(substractSfWeights(V_chan, V_weightIdx));
  end;
  Exit(0);
end;

function TATChannelUnit.decodeQuantWordlen: Integer;
begin
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        ATFill(ctx.channels[V_chNum].quWordlen, 0, Length(ctx.channels[V_chNum].quWordlen), 0);
        var V_ret: Integer;
        V_ret := decodeChannelWordlen(V_chNum);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
      end;
      Inc(V_chNum);
    end;
  end;
  var V_i: Integer;
  begin
    V_i := (ctx.numQuantUnits - 1);
    while (V_i >= 0) do
    begin
      begin
        if (((ctx.channels[0].quWordlen[V_i] <> 0) or (((numChannels = 2) and (ctx.channels[1].quWordlen[V_i]
          <> 0))))) then
        begin
          Break;
        end;
      end;
      Dec(V_i);
    end;
  end;
  ctx.usedQuantUnits := (V_i + 1);
  Exit(0);
end;

function TATChannelUnit.decodeScaleFactors: Integer;
begin
  if ((ctx.usedQuantUnits = 0)) then
  begin
    Exit(0);
  end;
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        ATFill(ctx.channels[V_chNum].quSfIdx, 0, Length(ctx.channels[V_chNum].quSfIdx), 0);
        var V_ret: Integer;
        V_ret := decodeChannelSfIdx(V_chNum);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
      end;
      Inc(V_chNum);
    end;
  end;
  Exit(0);
end;

function TATChannelUnit.getNumCtValues: Integer;
begin
  if (not (br.readBool)) then
  begin
    Exit(ctx.usedQuantUnits);
  end;
  var V_numCodedVals: Integer;
  V_numCodedVals := br.read(5);
  if ((V_numCodedVals > ctx.usedQuantUnits)) then
  begin
    Exit(AT3P_ERROR);
  end;
  Exit(V_numCodedVals);
end;

function TATChannelUnit.decodeChannelCodeTab(Arg_chNum: Integer): Integer;
begin
  var V_vlcTab: TATVLC;
  var V_numVals: Integer;
  var V_mask: Integer;
  var Temporary1: Integer;
  if ctx.useFullTable then
  begin
    Temporary1 := 7;
  end
  else
  begin
    Temporary1 := 3;
  end;
  V_mask := Temporary1;
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  V_chan.tableType := br.read(1);
  case (br.read(2)) of
    0:
      begin
        var V_numBits: Integer;
        var Temporary2: Integer;
        if ctx.useFullTable then
        begin
          Temporary2 := 3;
        end
        else
        begin
          Temporary2 := 2;
        end;
        V_numBits := Temporary2;
        V_numVals := getNumCtValues;
        if ((V_numVals < 0)) then
        begin
          Exit(V_numVals);
        end;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_numVals) do
          begin
            begin
              if ((V_chan.quWordlen[V_i] <> 0)) then
              begin
                V_chan.quTabIdx[V_i] := br.read(V_numBits);
              end
              else if (((Arg_chNum > 0) and (V_refChan.quWordlen[V_i] <> 0))) then
              begin
                V_chan.quTabIdx[V_i] := br.read1;
              end;
            end;
            Inc(V_i);
          end;
        end;
      end;
    1:
      begin
        var Temporary3: TATVLC;
        if ctx.useFullTable then
        begin
          Temporary3 := ct_vlc_tabs[1];
        end
        else
        begin
          Temporary3 := ct_vlc_tabs[0];
        end;
        V_vlcTab := Temporary3;
        V_numVals := getNumCtValues;
        if ((V_numVals < 0)) then
        begin
          Exit(V_numVals);
        end;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_numVals) do
          begin
            begin
              if ((V_chan.quWordlen[V_i] <> 0)) then
              begin
                V_chan.quTabIdx[V_i] := V_vlcTab.getVLC2(br);
              end
              else if (((Arg_chNum > 0) and (V_refChan.quWordlen[V_i] <> 0))) then
              begin
                V_chan.quTabIdx[V_i] := br.read1;
              end;
            end;
            Inc(V_i);
          end;
        end;
      end;
    2:
      begin
        var V_deltaVlc: TATVLC;
        if (ctx.useFullTable) then
        begin
          V_vlcTab := ct_vlc_tabs[1];
          V_deltaVlc := ct_vlc_tabs[2];
        end
        else
        begin
          V_vlcTab := ct_vlc_tabs[0];
          V_deltaVlc := ct_vlc_tabs[0];
        end;
        var V_pred: Integer;
        V_pred := 0;
        V_numVals := getNumCtValues;
        if ((V_numVals < 0)) then
        begin
          Exit(V_numVals);
        end;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_numVals) do
          begin
            begin
              if ((V_chan.quWordlen[V_i] <> 0)) then
              begin
                var Temporary4: Integer;
                if (V_i = 0) then
                begin
                  Temporary4 := V_vlcTab.getVLC2(br);
                end
                else
                begin
                  Temporary4 := (((V_pred + V_deltaVlc.getVLC2(br))) and V_mask);
                end;
                V_chan.quTabIdx[V_i] := (Temporary4);
                V_pred := V_chan.quTabIdx[V_i];
              end
              else if (((Arg_chNum > 0) and (V_refChan.quWordlen[V_i] <> 0))) then
              begin
                V_chan.quTabIdx[V_i] := br.read1;
              end;
            end;
            Inc(V_i);
          end;
        end;
      end;
    3:
      begin
        if ((Arg_chNum > 0)) then
        begin
          var Temporary5: TATVLC;
          if ctx.useFullTable then
          begin
            Temporary5 := ct_vlc_tabs[3];
          end
          else
          begin
            Temporary5 := ct_vlc_tabs[0];
          end;
          V_vlcTab := Temporary5;
          V_numVals := getNumCtValues;
          if ((V_numVals < 0)) then
          begin
            Exit(V_numVals);
          end;
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < V_numVals) do
            begin
              begin
                if ((V_chan.quWordlen[V_i] <> 0)) then
                begin
                  V_chan.quTabIdx[V_i] := (((V_refChan.quTabIdx[V_i] + V_vlcTab.getVLC2(br))) and V_mask);
                end
                else if (((Arg_chNum > 0) and (V_refChan.quWordlen[V_i] <> 0))) then
                begin
                  V_chan.quTabIdx[V_i] := br.read1;
                end;
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
  end;
  Exit(0);
end;

function TATChannelUnit.decodeCodeTableIndexes: Integer;
begin
  if ((ctx.usedQuantUnits = 0)) then
  begin
    Exit(0);
  end;
  ctx.useFullTable := br.readBool;
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        ATFill(ctx.channels[V_chNum].quTabIdx, 0, Length(ctx.channels[V_chNum].quTabIdx), 0);
        var V_ret: Integer;
        V_ret := decodeChannelCodeTab(V_chNum);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
      end;
      Inc(V_chNum);
    end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.decodeQuSpectra(Arg_tab: TATSpecCodeTab; Arg_vlcTab: TATVLC; Arg_OutputData: TArray<Integer>; Arg_outOffset: Integer; Arg_numSpecs: Integer);
begin
  var V_groupSize: Integer;
  V_groupSize := Arg_tab.groupSize;
  var V_numCoeffs: Integer;
  V_numCoeffs := Arg_tab.numCoeffs;
  var V_bits: Integer;
  V_bits := Arg_tab.bits;
  var V_isSigned: Boolean;
  V_isSigned := Arg_tab.isSigned;
  var V_mask: Integer;
  V_mask := ((Integer(Cardinal(1) shl V_bits)) - 1);
  begin
    var V_pos: Integer;
    V_pos := 0;
    while (V_pos < Arg_numSpecs) do
    begin
      begin
        if (((V_groupSize = 1) or br.readBool)) then
        begin
          begin
            var V_j: Integer;
            V_j := 0;
            while (V_j < V_groupSize) do
            begin
              begin
                var V_val: Integer;
                V_val := Arg_vlcTab.getVLC2(br);
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_numCoeffs) do
                  begin
                    begin
                      var V_cf: Integer;
                      V_cf := (V_val and V_mask);
                      if (V_isSigned) then
                      begin
                        V_cf := ATSigned(V_cf, V_bits);
                      end
                      else if (((V_cf <> 0) and br.readBool)) then
                      begin
                        V_cf := -(V_cf);
                      end;
                      Arg_OutputData[(Arg_outOffset + V_pos)] := V_cf;
                      Inc(V_pos);
                      V_val := ATSar(V_val, V_bits);
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_j);
            end;
          end;
        end
        else
        begin
          V_pos := (V_pos + (V_groupSize * V_numCoeffs));
        end;
      end;
    end;
  end;
end;

procedure TATChannelUnit.decodeSpectrum;
begin
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        var V_chan: TATChannel;
        V_chan := ctx.channels[V_chNum];
        ATFill(V_chan.spectrum, 0, Length(V_chan.spectrum), 0);
        ATFill(V_chan.powerLevs, 0, Length(V_chan.powerLevs), ATRAC3P_POWER_COMP_OFF);
        begin
          var V_qu: Integer;
          V_qu := 0;
          while (V_qu < ctx.usedQuantUnits) do
          begin
            begin
              var V_numSpecs: Integer;
              V_numSpecs := (ff_atrac3p_qu_to_spec_pos[(V_qu + 1)] - ff_atrac3p_qu_to_spec_pos[V_qu]);
              var V_wordlen: Integer;
              V_wordlen := V_chan.quWordlen[V_qu];
              var V_codetab: Integer;
              V_codetab := V_chan.quTabIdx[V_qu];
              if ((V_wordlen > 0)) then
              begin
                if (not (ctx.useFullTable)) then
                begin
                  V_codetab := atrac3p_ct_restricted_to_full[V_chan.tableType][(V_wordlen - 1)][V_codetab];
                end;
                var V_tabIndex: Integer;
                V_tabIndex := ((((((V_chan.tableType * 8) + V_codetab)) * 7) + V_wordlen) - 1);
                var V_tab: TATSpecCodeTab;
                V_tab := atrac3p_spectra_tabs[V_tabIndex];
                if ((V_tab.redirect >= 0)) then
                begin
                  V_tabIndex := V_tab.redirect;
                end;
                decodeQuSpectra(V_tab, spec_vlc_tabs[V_tabIndex], V_chan.spectrum,
                  ff_atrac3p_qu_to_spec_pos[V_qu], V_numSpecs);
              end
              else if ((((V_chNum > 0) and (ctx.channels[0].quWordlen[V_qu] <> 0)) and (V_codetab = 0))) then
              begin
                ATCopy(ctx.channels[0].spectrum, ff_atrac3p_qu_to_spec_pos[V_qu], V_chan.spectrum,
                  ff_atrac3p_qu_to_spec_pos[V_qu], V_numSpecs);
                V_chan.quWordlen[V_qu] := ctx.channels[0].quWordlen[V_qu];
              end;
            end;
            Inc(V_qu);
          end;
        end;
        if ((ctx.usedQuantUnits > 2)) then
        begin
          var V_numSpecs: Integer;
          V_numSpecs := atrac3p_subband_to_num_powgrps[(ctx.numCodedSubbands - 1)];
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < V_numSpecs) do
            begin
              begin
                V_chan.powerLevs[V_i] := br.read(4);
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
      Inc(V_chNum);
    end;
  end;
end;

function TATChannelUnit.getSubbandFlags(Arg_OutputData: TArray<Boolean>; Arg_numFlags: Integer): Boolean;
begin
  var V_result: Boolean;
  V_result := br.readBool;
  if (V_result) then
  begin
    if (br.readBool) then
    begin
      begin
        var V_i: Integer;
        V_i := 0;
        while (V_i < Arg_numFlags) do
        begin
          begin
            Arg_OutputData[V_i] := br.readBool;
          end;
          Inc(V_i);
        end;
      end;
    end
    else
    begin
      begin
        var V_i: Integer;
        V_i := 0;
        while (V_i < Arg_numFlags) do
        begin
          begin
            Arg_OutputData[V_i] := True;
          end;
          Inc(V_i);
        end;
      end;
    end;
  end
  else
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < Arg_numFlags) do
      begin
        begin
          Arg_OutputData[V_i] := False;
        end;
        Inc(V_i);
      end;
    end;
  end;
  Exit(V_result);
end;

procedure TATChannelUnit.decodeWindowShape;
begin
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < numChannels) do
    begin
      begin
        getSubbandFlags(ctx.channels[V_i].wndShape, ctx.numSubbands);
      end;
      Inc(V_i);
    end;
  end;
end;

function TATChannelUnit.decodeGaincNPoints(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
begin
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  case (br.read(2)) of
    0:
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < Arg_codedSubbands) do
          begin
            begin
              V_chan.gainData[V_i].numPoints := br.read(3);
            end;
            Inc(V_i);
          end;
        end;
      end;
    1:
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < Arg_codedSubbands) do
          begin
            begin
              V_chan.gainData[V_i].numPoints := gain_vlc_tabs[0].getVLC2(br);
            end;
            Inc(V_i);
          end;
        end;
      end;
    2:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < Arg_codedSubbands) do
            begin
              begin
                var V_delta: Integer;
                V_delta := gain_vlc_tabs[1].getVLC2(br);
                V_chan.gainData[V_i].numPoints := (((V_refChan.gainData[V_i].numPoints + V_delta)) and 7);
              end;
              Inc(V_i);
            end;
          end;
        end
        else
        begin
          V_chan.gainData[0].numPoints := gain_vlc_tabs[0].getVLC2(br);
          begin
            var V_i: Integer;
            V_i := 1;
            while (V_i < Arg_codedSubbands) do
            begin
              begin
                var V_delta: Integer;
                V_delta := gain_vlc_tabs[1].getVLC2(br);
                V_chan.gainData[V_i].numPoints := (((V_chan.gainData[(V_i - 1)].numPoints + V_delta)) and 7);
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
    3:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < Arg_codedSubbands) do
            begin
              begin
                V_chan.gainData[V_i].numPoints := V_refChan.gainData[V_i].numPoints;
              end;
              Inc(V_i);
            end;
          end;
        end
        else
        begin
          var V_deltaBits: Integer;
          V_deltaBits := br.read(2);
          var V_minVal: Integer;
          V_minVal := br.read(3);
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < Arg_codedSubbands) do
            begin
              begin
                V_chan.gainData[V_i].numPoints := (V_minVal + getDelta(V_deltaBits));
                if ((V_chan.gainData[V_i].numPoints > 7)) then
                begin
                  Exit(AT3P_ERROR);
                end;
              end;
              Inc(V_i);
            end;
          end;
        end;
      end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.gaincLevelMode1m(Arg_dst: TATAtracGainInfo);
begin
  if ((Arg_dst.numPoints > 0)) then
  begin
    Arg_dst.levCode[0] := gain_vlc_tabs[2].getVLC2(br);
  end;
  begin
    var V_i: Integer;
    V_i := 1;
    while (V_i < Arg_dst.numPoints) do
    begin
      begin
        var V_delta: Integer;
        V_delta := gain_vlc_tabs[3].getVLC2(br);
        Arg_dst.levCode[V_i] := (((Arg_dst.levCode[(V_i - 1)] + V_delta)) and 15);
      end;
      Inc(V_i);
    end;
  end;
end;

procedure TATChannelUnit.gaincLevelMode3s(Arg_dst: TATAtracGainInfo; Arg_ref: TATAtracGainInfo);
begin
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Arg_dst.numPoints) do
    begin
      begin
        var Temporary1: Integer;
        if (V_i >= Arg_ref.numPoints) then
        begin
          Temporary1 := 7;
        end
        else
        begin
          Temporary1 := Arg_ref.levCode[V_i];
        end;
        Arg_dst.levCode[V_i] := (Temporary1);
      end;
      Inc(V_i);
    end;
  end;
end;

function TATChannelUnit.decodeGaincLevels(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
begin
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  case (br.read(2)) of
    0:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < Arg_codedSubbands) do
          begin
            begin
              begin
                var V_i: Integer;
                V_i := 0;
                while (V_i < V_chan.gainData[V_sb].numPoints) do
                begin
                  begin
                    V_chan.gainData[V_sb].levCode[V_i] := br.read(4);
                  end;
                  Inc(V_i);
                end;
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    1:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_chan.gainData[V_sb].numPoints) do
                  begin
                    begin
                      var V_delta: Integer;
                      V_delta := gain_vlc_tabs[5].getVLC2(br);
                      var V_pred: Integer;
                      var Temporary1: Integer;
                      if (V_i >= V_refChan.gainData[V_sb].numPoints) then
                      begin
                        Temporary1 := 7;
                      end
                      else
                      begin
                        Temporary1 := V_refChan.gainData[V_sb].levCode[V_i];
                      end;
                      V_pred := (Temporary1);
                      V_chan.gainData[V_sb].levCode[V_i] := (((V_pred + V_delta)) and 15);
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                gaincLevelMode1m(V_chan.gainData[V_sb]);
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
    2:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                if ((V_chan.gainData[V_sb].numPoints > 0)) then
                begin
                  if (br.readBool) then
                  begin
                    gaincLevelMode1m(V_chan.gainData[V_sb]);
                  end
                  else
                  begin
                    gaincLevelMode3s(V_chan.gainData[V_sb], V_refChan.gainData[V_sb]);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          if ((V_chan.gainData[0].numPoints > 0)) then
          begin
            gaincLevelMode1m(V_chan.gainData[0]);
          end;
          begin
            var V_sb: Integer;
            V_sb := 1;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_chan.gainData[V_sb].numPoints) do
                  begin
                    begin
                      var V_delta: Integer;
                      V_delta := gain_vlc_tabs[4].getVLC2(br);
                      var V_pred: Integer;
                      var Temporary2: Integer;
                      if (V_i >= V_chan.gainData[(V_sb - 1)].numPoints) then
                      begin
                        Temporary2 := 7;
                      end
                      else
                      begin
                        Temporary2 := V_chan.gainData[(V_sb - 1)].levCode[V_i];
                      end;
                      V_pred := (Temporary2);
                      V_chan.gainData[V_sb].levCode[V_i] := (((V_pred + V_delta)) and 15);
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
    3:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                gaincLevelMode3s(V_chan.gainData[V_sb], V_refChan.gainData[V_sb]);
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          var V_deltaBits: Integer;
          V_deltaBits := br.read(2);
          var V_minVal: Integer;
          V_minVal := br.read(4);
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_chan.gainData[V_sb].numPoints) do
                  begin
                    begin
                      V_chan.gainData[V_sb].levCode[V_i] := (V_minVal + getDelta(V_deltaBits));
                      if ((V_chan.gainData[V_sb].levCode[V_i] > 15)) then
                      begin
                        Exit(AT3P_ERROR);
                      end;
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.gaincLocMode0(Arg_dst: TATAtracGainInfo; Arg_pos: Integer);
begin
  if (((Arg_pos = 0) or (Arg_dst.locCode[(Arg_pos - 1)] < 15))) then
  begin
    Arg_dst.locCode[Arg_pos] := br.read(5);
  end
  else if ((Arg_dst.locCode[(Arg_pos - 1)] >= 30)) then
  begin
    Arg_dst.locCode[Arg_pos] := 31;
  end
  else
  begin
    var V_deltaBits: Integer;
    V_deltaBits := (avLog2((30 - Arg_dst.locCode[(Arg_pos - 1)])) + 1);
    Arg_dst.locCode[Arg_pos] := ((Arg_dst.locCode[(Arg_pos - 1)] + br.read(V_deltaBits)) + 1);
  end;
end;

procedure TATChannelUnit.gaincLocMode1(Arg_dst: TATAtracGainInfo);
begin
  if ((Arg_dst.numPoints > 0)) then
  begin
    Arg_dst.locCode[0] := br.read(5);
    begin
      var V_i: Integer;
      V_i := 1;
      while (V_i < Arg_dst.numPoints) do
      begin
        begin
          var V_tab: TATVLC;
          var Temporary1: TATVLC;
          if (Arg_dst.levCode[V_i] <= Arg_dst.levCode[(V_i - 1)]) then
          begin
            Temporary1 := gain_vlc_tabs[7];
          end
          else
          begin
            Temporary1 := gain_vlc_tabs[9];
          end;
          V_tab := (Temporary1);
          Arg_dst.locCode[V_i] := (Arg_dst.locCode[(V_i - 1)] + V_tab.getVLC2(br));
        end;
        Inc(V_i);
      end;
    end;
  end;
end;

function TATChannelUnit.decodeGaincLocCodes(Arg_chNum: Integer; Arg_codedSubbands: Integer): Integer;
begin
  var V_chan: TATChannel;
  V_chan := ctx.channels[Arg_chNum];
  var V_refChan: TATChannel;
  V_refChan := ctx.channels[0];
  var V_codingMode: Integer;
  V_codingMode := br.read(2);
  case (V_codingMode) of
    0:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < Arg_codedSubbands) do
          begin
            begin
              begin
                var V_i: Integer;
                V_i := 0;
                while (V_i < V_chan.gainData[V_sb].numPoints) do
                begin
                  begin
                    gaincLocMode0(V_chan.gainData[V_sb], V_i);
                  end;
                  Inc(V_i);
                end;
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    1:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                if ((V_chan.gainData[V_sb].numPoints <= 0)) then
                begin
                  Inc(V_sb);
                  Continue;
                end;
                var V_dst: TATAtracGainInfo;
                V_dst := V_chan.gainData[V_sb];
                var V_ref: TATAtracGainInfo;
                V_ref := V_refChan.gainData[V_sb];
                var V_delta: Integer;
                V_delta := gain_vlc_tabs[10].getVLC2(br);
                var V_pred: Integer;
                var Temporary1: Integer;
                if (V_ref.numPoints > 0) then
                begin
                  Temporary1 := V_ref.locCode[0];
                end
                else
                begin
                  Temporary1 := 0;
                end;
                V_pred := Temporary1;
                V_dst.locCode[0] := (((V_pred + V_delta)) and 31);
                begin
                  var V_i: Integer;
                  V_i := 1;
                  while (V_i < V_dst.numPoints) do
                  begin
                    begin
                      var V_moreThanRef: Boolean;
                      V_moreThanRef := (V_i >= V_ref.numPoints);
                      if ((V_dst.levCode[V_i] > V_dst.levCode[(V_i - 1)])) then
                      begin
                        if (V_moreThanRef) then
                        begin
                          V_delta := gain_vlc_tabs[9].getVLC2(br);
                          V_dst.locCode[V_i] := (V_dst.locCode[(V_i - 1)] + V_delta);
                        end
                        else
                        begin
                          if (br.readBool) then
                          begin
                            gaincLocMode0(V_dst, V_i);
                          end
                          else
                          begin
                            V_dst.locCode[V_i] := V_ref.locCode[V_i];
                          end;
                        end;
                      end
                      else
                      begin
                        var V_tab: TATVLC;
                        var Temporary2: TATVLC;
                        if V_moreThanRef then
                        begin
                          Temporary2 := gain_vlc_tabs[7];
                        end
                        else
                        begin
                          Temporary2 := gain_vlc_tabs[10];
                        end;
                        V_tab := Temporary2;
                        V_delta := V_tab.getVLC2(br);
                        if (V_moreThanRef) then
                        begin
                          V_dst.locCode[V_i] := (V_dst.locCode[(V_i - 1)] + V_delta);
                        end
                        else
                        begin
                          V_dst.locCode[V_i] := (((V_ref.locCode[V_i] + V_delta)) and 31);
                        end;
                      end;
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                gaincLocMode1(V_chan.gainData[V_sb]);
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
    2:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                if ((V_chan.gainData[V_sb].numPoints <= 0)) then
                begin
                  Inc(V_sb);
                  Continue;
                end;
                var V_dst: TATAtracGainInfo;
                V_dst := V_chan.gainData[V_sb];
                var V_ref: TATAtracGainInfo;
                V_ref := V_refChan.gainData[V_sb];
                if (((V_dst.numPoints > V_ref.numPoints) or br.readBool)) then
                begin
                  gaincLocMode1(V_dst);
                end
                else
                begin
                  begin
                    var V_i: Integer;
                    V_i := 0;
                    while (V_i < V_chan.gainData[V_sb].numPoints) do
                    begin
                      begin
                        V_dst.locCode[V_i] := V_ref.locCode[V_i];
                      end;
                      Inc(V_i);
                    end;
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < V_chan.gainData[0].numPoints) do
            begin
              begin
                gaincLocMode0(V_chan.gainData[0], V_i);
              end;
              Inc(V_i);
            end;
          end;
          begin
            var V_sb: Integer;
            V_sb := 1;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                if ((V_chan.gainData[V_sb].numPoints <= 0)) then
                begin
                  Inc(V_sb);
                  Continue;
                end;
                var V_dst: TATAtracGainInfo;
                V_dst := V_chan.gainData[V_sb];
                var V_delta: Integer;
                V_delta := gain_vlc_tabs[6].getVLC2(br);
                var V_pred: Integer;
                var Temporary3: Integer;
                if (V_chan.gainData[(V_sb - 1)].numPoints > 0) then
                begin
                  Temporary3 := V_chan.gainData[(V_sb - 1)].locCode[0];
                end
                else
                begin
                  Temporary3 := 0;
                end;
                V_pred := Temporary3;
                V_dst.locCode[0] := (((V_pred + V_delta)) and 31);
                begin
                  var V_i: Integer;
                  V_i := 1;
                  while (V_i < V_dst.numPoints) do
                  begin
                    begin
                      var V_moreThanRef: Boolean;
                      V_moreThanRef := (V_i >= V_chan.gainData[(V_sb - 1)].numPoints);
                      var V_tab: TATVLC;
                      var Temporary4: Integer;
                      if (V_dst.levCode[V_i] > V_dst.levCode[(V_i - 1)]) then
                      begin
                        Temporary4 := 2;
                      end
                      else
                      begin
                        Temporary4 := 0;
                      end;
                      var Temporary5: Integer;
                      if V_moreThanRef then
                      begin
                        Temporary5 := 1;
                      end
                      else
                      begin
                        Temporary5 := 0;
                      end;
                      V_tab := gain_vlc_tabs[(((Temporary4) + (Temporary5)) + 6)];
                      V_delta := V_tab.getVLC2(br);
                      if (V_moreThanRef) then
                      begin
                        V_dst.locCode[V_i] := (V_dst.locCode[(V_i - 1)] + V_delta);
                      end
                      else
                      begin
                        V_dst.locCode[V_i] := (((V_chan.gainData[(V_sb - 1)].locCode[V_i] + V_delta)) and 31);
                      end;
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
    3:
      begin
        if ((Arg_chNum > 0)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_chan.gainData[V_sb].numPoints) do
                  begin
                    begin
                      if ((V_i >= V_refChan.gainData[V_sb].numPoints)) then
                      begin
                        gaincLocMode0(V_chan.gainData[V_sb], V_i);
                      end
                      else
                      begin
                        V_chan.gainData[V_sb].locCode[V_i] := V_refChan.gainData[V_sb].locCode[V_i];
                      end;
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end
        else
        begin
          var V_deltaBits: Integer;
          V_deltaBits := (br.read(2) + 1);
          var V_minVal: Integer;
          V_minVal := br.read(5);
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < Arg_codedSubbands) do
            begin
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_chan.gainData[V_sb].numPoints) do
                  begin
                    begin
                      V_chan.gainData[V_sb].locCode[V_i] := ((V_minVal + V_i) + br.read(V_deltaBits));
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end;
      end;
  end;
  begin
    var V_sb: Integer;
    V_sb := 0;
    while (V_sb < Arg_codedSubbands) do
    begin
      begin
        var V_dst: TATAtracGainInfo;
        V_dst := V_chan.gainData[V_sb];
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_chan.gainData[V_sb].numPoints) do
          begin
            begin
              if ((((V_dst.locCode[V_i] < 0) or (V_dst.locCode[V_i] > 31)) or (((V_i > 0) and
                (V_dst.locCode[V_i] <= V_dst.locCode[(V_i - 1)]))))) then
              begin
                Exit(AT3P_ERROR);
              end;
            end;
            Inc(V_i);
          end;
        end;
      end;
      Inc(V_sb);
    end;
  end;
  Exit(0);
end;

function TATChannelUnit.decodeGaincData: Integer;
begin
  var V_ret: Integer;
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < ATRAC3P_SUBBANDS) do
          begin
            begin
              ctx.channels[V_chNum].gainData[V_i].clear;
            end;
            Inc(V_i);
          end;
        end;
        if (br.readBool) then
        begin
          var V_codedSubbands: Integer;
          V_codedSubbands := (br.read(4) + 1);
          if (br.readBool) then
          begin
            ctx.channels[V_chNum].numGainSubbands := (br.read(4) + 1);
          end
          else
          begin
            ctx.channels[V_chNum].numGainSubbands := V_codedSubbands;
          end;
          V_ret := decodeGaincNPoints(V_chNum, V_codedSubbands);
          if ((V_ret < 0)) then
          begin
            Exit(V_ret);
          end;
          V_ret := decodeGaincLevels(V_chNum, V_codedSubbands);
          if ((V_ret < 0)) then
          begin
            Exit(V_ret);
          end;
          V_ret := decodeGaincLocCodes(V_chNum, V_codedSubbands);
          if ((V_ret < 0)) then
          begin
            Exit(V_ret);
          end;
          if ((V_codedSubbands > 0)) then
          begin
            begin
              var V_sb: Integer;
              V_sb := V_codedSubbands;
              while (V_sb < ctx.channels[V_chNum].numGainSubbands) do
              begin
                begin
                  ctx.channels[V_chNum].gainData[V_sb].copy(ctx.channels[V_chNum].gainData[(V_sb - 1)]);
                end;
                Inc(V_sb);
              end;
            end;
          end;
        end
        else
        begin
          ctx.channels[V_chNum].numGainSubbands := 0;
        end;
      end;
      Inc(V_chNum);
    end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.decodeTonesEnvelope(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
begin
  var V_dst: TArray<TATWavesData>;
  V_dst := ctx.channels[Arg_chNum].tonesInfo;
  var V_ref: TArray<TATWavesData>;
  V_ref := ctx.channels[0].tonesInfo;
  if (((Arg_chNum = 0) or not (br.readBool))) then
  begin
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if (not (Arg_bandHasTones[V_sb])) then
          begin
            Inc(V_sb);
            Continue;
          end;
          V_dst[V_sb].pendEnv.hasStartPoint := br.readBool;
          var Temporary1: Integer;
          if V_dst[V_sb].pendEnv.hasStartPoint then
          begin
            Temporary1 := br.read(5);
          end
          else
          begin
            Temporary1 := -1;
          end;
          V_dst[V_sb].pendEnv.startPos := (Temporary1);
          V_dst[V_sb].pendEnv.hasStopPoint := br.readBool;
          var Temporary2: Integer;
          if V_dst[V_sb].pendEnv.hasStopPoint then
          begin
            Temporary2 := br.read(5);
          end
          else
          begin
            Temporary2 := 32;
          end;
          V_dst[V_sb].pendEnv.stopPos := (Temporary2);
        end;
        Inc(V_sb);
      end;
    end;
  end
  else
  begin
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if (not (Arg_bandHasTones[V_sb])) then
          begin
            Inc(V_sb);
            Continue;
          end;
          V_dst[V_sb].pendEnv.copy(V_ref[V_sb].pendEnv);
        end;
        Inc(V_sb);
      end;
    end;
  end;
end;

function TATChannelUnit.decodeBandNumwavs(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>): Integer;
begin
  var V_dst: TArray<TATWavesData>;
  V_dst := ctx.channels[Arg_chNum].tonesInfo;
  var V_ref: TArray<TATWavesData>;
  V_ref := ctx.channels[0].tonesInfo;
  var V_mode: Integer;
  V_mode := br.read((Arg_chNum + 1));
  case (V_mode) of
    0:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if (Arg_bandHasTones[V_sb]) then
              begin
                V_dst[V_sb].numWavs := br.read(4);
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    1:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if (Arg_bandHasTones[V_sb]) then
              begin
                V_dst[V_sb].numWavs := tone_vlc_tabs[1].getVLC2(br);
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    2:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if (Arg_bandHasTones[V_sb]) then
              begin
                var V_delta: Integer;
                V_delta := tone_vlc_tabs[2].getVLC2(br);
                V_delta := ATSigned(V_delta, 3);
                V_dst[V_sb].numWavs := (((V_ref[V_sb].numWavs + V_delta)) and 15);
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    3:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if (Arg_bandHasTones[V_sb]) then
              begin
                V_dst[V_sb].numWavs := V_ref[V_sb].numWavs;
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
  end;
  begin
    var V_sb: Integer;
    V_sb := 0;
    while (V_sb < ctx.wavesInfo.numToneBands) do
    begin
      begin
        if (Arg_bandHasTones[V_sb]) then
        begin
          if (((ctx.wavesInfo.tonesIndex + V_dst[V_sb].numWavs) > 48)) then
          begin
            Exit(AT3P_ERROR);
          end;
          V_dst[V_sb].startIndex := ctx.wavesInfo.tonesIndex;
          ctx.wavesInfo.tonesIndex := (ctx.wavesInfo.tonesIndex + V_dst[V_sb].numWavs);
        end;
      end;
      Inc(V_sb);
    end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.decodeTonesFrequency(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
begin
  var V_dst: TArray<TATWavesData>;
  V_dst := ctx.channels[Arg_chNum].tonesInfo;
  var V_ref: TArray<TATWavesData>;
  V_ref := ctx.channels[0].tonesInfo;
  if (((Arg_chNum = 0) or not (br.readBool))) then
  begin
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
          begin
            Inc(V_sb);
            Continue;
          end;
          var V_iwav: Integer;
          V_iwav := V_dst[V_sb].startIndex;
          var V_direction: Boolean;
          var Temporary1: Boolean;
          if (V_dst[V_sb].numWavs > 1) then
          begin
            Temporary1 := br.readBool;
          end
          else
          begin
            Temporary1 := False;
          end;
          V_direction := (Temporary1);
          if (V_direction) then
          begin
            if ((V_dst[V_sb].numWavs > 0)) then
            begin
              ctx.wavesInfo.waves[((V_iwav + V_dst[V_sb].numWavs) - 1)].freqIndex := br.read(10);
            end;
            begin
              var V_i: Integer;
              V_i := (V_dst[V_sb].numWavs - 2);
              while (V_i >= 0) do
              begin
                begin
                  var V_nbits: Integer;
                  V_nbits := (avLog2(ctx.wavesInfo.waves[((V_iwav + V_i) + 1)].freqIndex) + 1);
                  ctx.wavesInfo.waves[(V_iwav + V_i)].freqIndex := br.read(V_nbits);
                end;
                Dec(V_i);
              end;
            end;
          end
          else
          begin
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < V_dst[V_sb].numWavs) do
              begin
                begin
                  if (((V_i = 0) or (ctx.wavesInfo.waves[((V_iwav + V_i) - 1)].freqIndex < 512))) then
                  begin
                    ctx.wavesInfo.waves[(V_iwav + V_i)].freqIndex := br.read(10);
                  end
                  else
                  begin
                    var V_nbits: Integer;
                    V_nbits := (avLog2((1023 - ctx.wavesInfo.waves[((V_iwav + V_i) - 1)].freqIndex)) + 1);
                    ctx.wavesInfo.waves[(V_iwav + V_i)].freqIndex := ((br.read(V_nbits) + 1024) -
                      (Integer(Cardinal(1) shl V_nbits)));
                  end;
                end;
                Inc(V_i);
              end;
            end;
          end;
        end;
        Inc(V_sb);
      end;
    end;
  end
  else
  begin
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
          begin
            Inc(V_sb);
            Continue;
          end;
          var V_iwav: Integer;
          V_iwav := V_ref[V_sb].startIndex;
          var V_owav: Integer;
          V_owav := V_dst[V_sb].startIndex;
          begin
            var V_i: Integer;
            V_i := 0;
            while (V_i < V_dst[V_sb].numWavs) do
            begin
              begin
                var V_delta: Integer;
                V_delta := tone_vlc_tabs[6].getVLC2(br);
                V_delta := ATSigned(V_delta, 8);
                var V_pred: Integer;
                var Temporary2: Integer;
                if (V_i < V_ref[V_sb].numWavs) then
                begin
                  Temporary2 := ctx.wavesInfo.waves[(V_iwav + V_i)].freqIndex;
                end
                else
                begin
                  var Temporary3: Integer;
                  if (V_ref[V_sb].numWavs > 0) then
                  begin
                    Temporary3 := ctx.wavesInfo.waves[((V_iwav + V_ref[V_sb].numWavs) - 1)].freqIndex;
                  end
                  else
                  begin
                    Temporary3 := 0;
                  end;
                  Temporary2 := (Temporary3);
                end;
                V_pred := (Temporary2);
                ctx.wavesInfo.waves[(V_owav + V_i)].freqIndex := (((V_pred + V_delta)) and 1023);
              end;
              Inc(V_i);
            end;
          end;
        end;
        Inc(V_sb);
      end;
    end;
  end;
end;

procedure TATChannelUnit.decodeTonesAmplitude(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
begin
  var V_dst: TArray<TATWavesData>;
  V_dst := ctx.channels[Arg_chNum].tonesInfo;
  var V_ref: TArray<TATWavesData>;
  V_ref := ctx.channels[0].tonesInfo;
  var V_refwaves: TArray<Integer>;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 48);
  V_refwaves := Temporary1;
  if ((Arg_chNum > 0)) then
  begin
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
          begin
            Inc(V_sb);
            Continue;
          end;
          var V_wsrc: Integer;
          V_wsrc := V_dst[V_sb].startIndex;
          var V_wref: Integer;
          V_wref := V_ref[V_sb].startIndex;
          begin
            var V_j: Integer;
            V_j := 0;
            while (V_j < V_dst[V_sb].numWavs) do
            begin
              begin
                var V_fi: Integer;
                V_fi := 0;
                var V_maxdiff: Integer;
                V_maxdiff := 1024;
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_ref[V_sb].numWavs) do
                  begin
                    begin
                      var V_diff: Integer;
                      V_diff := Abs((ctx.wavesInfo.waves[(V_wsrc + V_j)].freqIndex -
                        ctx.wavesInfo.waves[(V_wref + V_i)].freqIndex));
                      if ((V_diff < V_maxdiff)) then
                      begin
                        V_maxdiff := V_diff;
                        V_fi := V_i;
                      end;
                    end;
                    Inc(V_i);
                  end;
                end;
                if ((V_maxdiff < 8)) then
                begin
                  V_refwaves[(V_dst[V_sb].startIndex + V_j)] := (V_fi + V_ref[V_sb].startIndex);
                end
                else if ((V_j < V_ref[V_sb].numWavs)) then
                begin
                  V_refwaves[(V_dst[V_sb].startIndex + V_j)] := (V_j + V_ref[V_sb].startIndex);
                end
                else
                begin
                  V_refwaves[(V_dst[V_sb].startIndex + V_j)] := -1;
                end;
              end;
              Inc(V_j);
            end;
          end;
        end;
        Inc(V_sb);
      end;
    end;
  end;
  var V_mode: Integer;
  V_mode := br.read((Arg_chNum + 1));
  case (V_mode) of
    0:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
              begin
                Inc(V_sb);
                Continue;
              end;
              if ((ctx.wavesInfo.amplitudeMode <> 0)) then
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_dst[V_sb].numWavs) do
                  begin
                    begin
                      ctx.wavesInfo.waves[(V_dst[V_sb].startIndex + V_i)].ampSf := br.read(6);
                    end;
                    Inc(V_i);
                  end;
                end;
              end
              else
              begin
                ctx.wavesInfo.waves[V_dst[V_sb].startIndex].ampSf := br.read(6);
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    1:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
              begin
                Inc(V_sb);
                Continue;
              end;
              if ((ctx.wavesInfo.amplitudeMode <> 0)) then
              begin
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_dst[V_sb].numWavs) do
                  begin
                    begin
                      ctx.wavesInfo.waves[(V_dst[V_sb].startIndex + V_i)].ampSf := (tone_vlc_tabs[3].getVLC2(br)
                        + 20);
                    end;
                    Inc(V_i);
                  end;
                end;
              end
              else
              begin
                ctx.wavesInfo.waves[V_dst[V_sb].startIndex].ampSf := (tone_vlc_tabs[4].getVLC2(br) + 24);
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    2:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if ((not (Arg_bandHasTones[V_sb]) or (V_dst[V_sb].numWavs = 0))) then
              begin
                Inc(V_sb);
                Continue;
              end;
              begin
                var V_i: Integer;
                V_i := 0;
                while (V_i < V_dst[V_sb].numWavs) do
                begin
                  begin
                    var V_delta: Integer;
                    V_delta := tone_vlc_tabs[5].getVLC2(br);
                    V_delta := ATSigned(V_delta, 5);
                    var V_pred: Integer;
                    var Temporary2: Integer;
                    if (V_refwaves[(V_dst[V_sb].startIndex + V_i)] >= 0) then
                    begin
                      Temporary2 := ctx.wavesInfo.waves[V_refwaves[(V_dst[V_sb].startIndex + V_i)]].ampSf;
                    end
                    else
                    begin
                      Temporary2 := 34;
                    end;
                    V_pred := Temporary2;
                    ctx.wavesInfo.waves[(V_dst[V_sb].startIndex + V_i)].ampSf := (((V_pred + V_delta)) and 63);
                  end;
                  Inc(V_i);
                end;
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
    3:
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.wavesInfo.numToneBands) do
          begin
            begin
              if (not (Arg_bandHasTones[V_sb])) then
              begin
                Inc(V_sb);
                Continue;
              end;
              begin
                var V_i: Integer;
                V_i := 0;
                while (V_i < V_dst[V_sb].numWavs) do
                begin
                  begin
                    var Temporary3: Integer;
                    if (V_refwaves[(V_dst[V_sb].startIndex + V_i)] >= 0) then
                    begin
                      Temporary3 := ctx.wavesInfo.waves[V_refwaves[(V_dst[V_sb].startIndex + V_i)]].ampSf;
                    end
                    else
                    begin
                      Temporary3 := 32;
                    end;
                    ctx.wavesInfo.waves[(V_dst[V_sb].startIndex + V_i)].ampSf := Temporary3;
                  end;
                  Inc(V_i);
                end;
              end;
            end;
            Inc(V_sb);
          end;
        end;
      end;
  end;
end;

procedure TATChannelUnit.decodeTonesPhase(Arg_chNum: Integer; Arg_bandHasTones: TArray<Boolean>);
begin
  var V_dst: TArray<TATWavesData>;
  V_dst := ctx.channels[Arg_chNum].tonesInfo;
  begin
    var V_sb: Integer;
    V_sb := 0;
    while (V_sb < ctx.wavesInfo.numToneBands) do
    begin
      begin
        if (not (Arg_bandHasTones[V_sb])) then
        begin
          Inc(V_sb);
          Continue;
        end;
        var V_wparam: Integer;
        V_wparam := V_dst[V_sb].startIndex;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < V_dst[V_sb].numWavs) do
          begin
            begin
              ctx.wavesInfo.waves[(V_wparam + V_i)].phaseIndex := br.read(5);
            end;
            Inc(V_i);
          end;
        end;
      end;
      Inc(V_sb);
    end;
  end;
end;

function TATChannelUnit.decodeTonesInfo: Integer;
begin
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < ATRAC3P_SUBBANDS) do
          begin
            begin
              ctx.channels[V_chNum].tonesInfo[V_i].clear;
            end;
            Inc(V_i);
          end;
        end;
      end;
      Inc(V_chNum);
    end;
  end;
  ctx.wavesInfo.tonesPresent := br.readBool;
  if (not (ctx.wavesInfo.tonesPresent)) then
  begin
    Exit(0);
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(ctx.wavesInfo.waves)) do
    begin
      begin
        ctx.wavesInfo.waves[V_i].clear;
      end;
      Inc(V_i);
    end;
  end;
  ctx.wavesInfo.amplitudeMode := br.read1;
  if ((ctx.wavesInfo.amplitudeMode = 0)) then
  begin
    Exit(AT3P_ERROR);
  end;
  ctx.wavesInfo.numToneBands := (tone_vlc_tabs[0].getVLC2(br) + 1);
  if ((numChannels = 2)) then
  begin
    getSubbandFlags(ctx.wavesInfo.toneSharing, ctx.wavesInfo.numToneBands);
    getSubbandFlags(ctx.wavesInfo.toneMaster, ctx.wavesInfo.numToneBands);
    if (getSubbandFlags(ctx.wavesInfo.phaseShift, ctx.wavesInfo.numToneBands)) then
    begin
    end;
  end;
  ctx.wavesInfo.tonesIndex := 0;
  begin
    var V_chNum: Integer;
    V_chNum := 0;
    while (V_chNum < numChannels) do
    begin
      begin
        var V_bandHasTones: TArray<Boolean>;
        var Temporary1: TArray<Boolean>;
        SetLength(Temporary1, 16);
        V_bandHasTones := Temporary1;
        begin
          var V_i: Integer;
          V_i := 0;
          while (V_i < ctx.wavesInfo.numToneBands) do
          begin
            begin
              var Temporary2: Boolean;
              if (V_chNum = 0) then
              begin
                Temporary2 := True;
              end
              else
              begin
                Temporary2 := not (ctx.wavesInfo.toneSharing[V_i]);
              end;
              V_bandHasTones[V_i] := (Temporary2);
            end;
            Inc(V_i);
          end;
        end;
        decodeTonesEnvelope(V_chNum, V_bandHasTones);
        var V_ret: Integer;
        V_ret := decodeBandNumwavs(V_chNum, V_bandHasTones);
        if ((V_ret < 0)) then
        begin
          Exit(V_ret);
        end;
        decodeTonesFrequency(V_chNum, V_bandHasTones);
        decodeTonesAmplitude(V_chNum, V_bandHasTones);
        decodeTonesPhase(V_chNum, V_bandHasTones);
      end;
      Inc(V_chNum);
    end;
  end;
  if ((numChannels = 2)) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < ctx.wavesInfo.numToneBands) do
      begin
        begin
          if (ctx.wavesInfo.toneSharing[V_i]) then
          begin
            ctx.channels[1].tonesInfo[V_i].copy(ctx.channels[0].tonesInfo[V_i]);
          end;
          if (ctx.wavesInfo.toneMaster[V_i]) then
          begin
            var V_tmp: TATWavesData;
            V_tmp := TATWavesData.Create();
            try
              V_tmp.copy(ctx.channels[0].tonesInfo[V_i]);
              ctx.channels[0].tonesInfo[V_i].copy(ctx.channels[1].tonesInfo[V_i]);
              ctx.channels[1].tonesInfo[V_i].copy(V_tmp);
            finally
              V_tmp.Free;
            end;
          end;
        end;
        Inc(V_i);
      end;
    end;
  end;
  Exit(0);
end;

procedure TATChannelUnit.decodeResidualSpectrum(Arg_OutputData: TArray<TArray<Single>>);
begin
  var V_sbRNGindex: TArray<Integer>;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, ATRAC3P_SUBBANDS);
  V_sbRNGindex := Temporary1;
  if (ctx.muteFlag) then
  begin
    begin
      var V_ch: Integer;
      V_ch := 0;
      while (V_ch < numChannels) do
      begin
        begin
          ATFill(Arg_OutputData[V_ch], 0, Length(Arg_OutputData[V_ch]), 0.0);
        end;
        Inc(V_ch);
      end;
    end;
    Exit;
  end;
  var V_RNGindex: Integer;
  V_RNGindex := 0;
  begin
    var V_qu: Integer;
    V_qu := 0;
    while (V_qu < ctx.usedQuantUnits) do
    begin
      begin
        V_RNGindex := (V_RNGindex + (ctx.channels[0].quSfIdx[V_qu] + ctx.channels[1].quSfIdx[V_qu]));
      end;
      Inc(V_qu);
    end;
  end;
  begin
    var V_sb: Integer;
    V_sb := 0;
    while (V_sb < ctx.numCodedSubbands) do
    begin
      begin
        V_sbRNGindex[V_sb] := (V_RNGindex and 1020);
      end;
      Inc(V_sb);
      V_RNGindex := (V_RNGindex + 128);
    end;
  end;
  begin
    var V_ch: Integer;
    V_ch := 0;
    while (V_ch < numChannels) do
    begin
      begin
        ATFill(Arg_OutputData[V_ch], 0, ATRAC3P_FRAME_SAMPLES, 0.0);
        begin
          var V_qu: Integer;
          V_qu := 0;
          while (V_qu < ctx.usedQuantUnits) do
          begin
            begin
              var V_src: Integer;
              V_src := ff_atrac3p_qu_to_spec_pos[V_qu];
              var V_dst: Integer;
              V_dst := ff_atrac3p_qu_to_spec_pos[V_qu];
              var V_nspeclines: Integer;
              V_nspeclines := (ff_atrac3p_qu_to_spec_pos[(V_qu + 1)] - ff_atrac3p_qu_to_spec_pos[V_qu]);
              if ((ctx.channels[V_ch].quWordlen[V_qu] > 0)) then
              begin
                var V_q: Single;
                V_q := (ff_atrac3p_sf_tab[ctx.channels[V_ch].quSfIdx[V_qu]] *
                  ff_atrac3p_mant_tab[ctx.channels[V_ch].quWordlen[V_qu]]);
                begin
                  var V_i: Integer;
                  V_i := 0;
                  while (V_i < V_nspeclines) do
                  begin
                    begin
                      Arg_OutputData[V_ch][(V_dst + V_i)] := (ctx.channels[V_ch].spectrum[(V_src + V_i)] *
                        V_q);
                    end;
                    Inc(V_i);
                  end;
                end;
              end;
            end;
            Inc(V_qu);
          end;
        end;
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.numCodedSubbands) do
          begin
            begin
              dsp.powerCompensation(ctx, V_ch, Arg_OutputData[V_ch], V_sbRNGindex[V_sb], V_sb);
            end;
            Inc(V_sb);
          end;
        end;
      end;
      Inc(V_ch);
    end;
  end;
  if ((ctx.unitType = CH_UNIT_STEREO)) then
  begin
    var V_tmp: TArray<Single>;
    var Temporary2: TArray<Single>;
    SetLength(Temporary2, ATRAC3P_SUBBAND_SAMPLES);
    V_tmp := Temporary2;
    begin
      var V_sb: Integer;
      V_sb := 0;
      while (V_sb < ctx.numCodedSubbands) do
      begin
        begin
          if (ctx.swapChannels[V_sb]) then
          begin
            ATCopy(Arg_OutputData[0], (V_sb * ATRAC3P_SUBBAND_SAMPLES), V_tmp, 0, ATRAC3P_SUBBAND_SAMPLES);
            ATCopy(Arg_OutputData[1], (V_sb * ATRAC3P_SUBBAND_SAMPLES), Arg_OutputData[0], (V_sb *
              ATRAC3P_SUBBAND_SAMPLES), ATRAC3P_SUBBAND_SAMPLES);
            ATCopy(V_tmp, 0, Arg_OutputData[1], (V_sb * ATRAC3P_SUBBAND_SAMPLES), ATRAC3P_SUBBAND_SAMPLES);
          end;
          if (ctx.negateCoeffs[V_sb]) then
          begin
            begin
              var V_i: Integer;
              V_i := 0;
              while (V_i < ATRAC3P_SUBBAND_SAMPLES) do
              begin
                begin
                  Arg_OutputData[1][((V_sb * ATRAC3P_SUBBAND_SAMPLES) + V_i)] := -((Arg_OutputData[1][((V_sb *
                      ATRAC3P_SUBBAND_SAMPLES) + V_i)]));
                end;
                Inc(V_i);
              end;
            end;
          end;
        end;
        Inc(V_sb);
      end;
    end;
  end;
end;

procedure TATChannelUnit.reconstructFrame(Arg_at3pContext: TATContext);
begin
  begin
    var V_ch: Integer;
    V_ch := 0;
    while (V_ch < numChannels) do
    begin
      begin
        begin
          var V_sb: Integer;
          V_sb := 0;
          while (V_sb < ctx.numSubbands) do
          begin
            begin
              var Temporary1: Integer;
              if ctx.channels[V_ch].wndShapePrev[V_sb] then
              begin
                Temporary1 := 2;
              end
              else
              begin
                Temporary1 := 0;
              end;
              var Temporary2: Integer;
              if ctx.channels[V_ch].wndShape[V_sb] then
              begin
                Temporary2 := 1;
              end
              else
              begin
                Temporary2 := 0;
              end;
              dsp.imdct(Arg_at3pContext.mdctCtx, Arg_at3pContext.samples[V_ch], (V_sb *
                ATRAC3P_SUBBAND_SAMPLES), Arg_at3pContext.mdctBuf[V_ch], (V_sb * ATRAC3P_SUBBAND_SAMPLES), ((Temporary1) +
                (Temporary2)), V_sb);
              Arg_at3pContext.gaincCtx.gainCompensation(Arg_at3pContext.mdctBuf[V_ch], (V_sb *
                ATRAC3P_SUBBAND_SAMPLES), ctx.prevBuf[V_ch], (V_sb * ATRAC3P_SUBBAND_SAMPLES),
                ctx.channels[V_ch].gainDataPrev[V_sb], ctx.channels[V_ch].gainData[V_sb], ATRAC3P_SUBBAND_SAMPLES,
                Arg_at3pContext.timeBuf[V_ch], (V_sb * ATRAC3P_SUBBAND_SAMPLES));
            end;
            Inc(V_sb);
          end;
        end;
        ATFill(ctx.prevBuf[V_ch], (ctx.numSubbands * ATRAC3P_SUBBAND_SAMPLES), Length(ctx.prevBuf[V_ch]), 0.0);
        ATFill(Arg_at3pContext.timeBuf[V_ch], (ctx.numSubbands * ATRAC3P_SUBBAND_SAMPLES),
          Length(Arg_at3pContext.timeBuf[V_ch]), 0.0);
        if ((ctx.wavesInfo.tonesPresent or ctx.wavesInfoPrev.tonesPresent)) then
        begin
          begin
            var V_sb: Integer;
            V_sb := 0;
            while (V_sb < ctx.numSubbands) do
            begin
              begin
                if (((ctx.channels[V_ch].tonesInfo[V_sb].numWavs > 0) or
                  (ctx.channels[V_ch].tonesInfoPrev[V_sb].numWavs > 0))) then
                begin
                  dsp.generateTones(ctx, V_ch, V_sb, Arg_at3pContext.timeBuf[V_ch], (V_sb * 128));
                end;
              end;
              Inc(V_sb);
            end;
          end;
        end;
        dsp.ipqf(Arg_at3pContext.ipqfDctCtx, ctx.ipqfCtx[V_ch], Arg_at3pContext.timeBuf[V_ch],
          Arg_at3pContext.outpBuf[V_ch]);
      end;
      Inc(V_ch);
    end;
  end;
  begin
    var V_ch: Integer;
    V_ch := 0;
    while (V_ch < numChannels) do
    begin
      begin
        var V_tmp1: TArray<Boolean>;
        V_tmp1 := ctx.channels[V_ch].wndShape;
        ctx.channels[V_ch].wndShape := ctx.channels[V_ch].wndShapePrev;
        ctx.channels[V_ch].wndShapePrev := V_tmp1;
        var V_tmp2: TArray<TATAtracGainInfo>;
        V_tmp2 := ctx.channels[V_ch].gainData;
        ctx.channels[V_ch].gainData := ctx.channels[V_ch].gainDataPrev;
        ctx.channels[V_ch].gainDataPrev := V_tmp2;
        var V_tmp3: TArray<TATWavesData>;
        V_tmp3 := ctx.channels[V_ch].tonesInfo;
        ctx.channels[V_ch].tonesInfo := ctx.channels[V_ch].tonesInfoPrev;
        ctx.channels[V_ch].tonesInfoPrev := V_tmp3;
      end;
      Inc(V_ch);
    end;
  end;
  var V_tmp: TATWaveSynthParams;
  V_tmp := ctx.wavesInfo;
  ctx.wavesInfo := ctx.wavesInfoPrev;
  ctx.wavesInfoPrev := V_tmp;
end;

destructor TATChannelUnit.Destroy;
begin
  ctx.Free;
  inherited;
end;

initialization
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, 64);
  ff_atrac_sf_table := Temporary1;
  var Temporary2: TArray<Single>;
  SetLength(Temporary2, 48);
  qmf_window := Temporary2;
  qmf_48tap_half := TArray<Single>.Create(-(1.461907e-05), -(9.205479e-05), -(5.615757e-05), 0.0003011727,
    0.0002422519, -(0.000852939), -(0.0005205574), 0.002034017, 0.0007833389, -(0.004215386), -(0.0007561499),
    0.007840294, -(6.116992e-05), -(0.01344162), 0.002462682, 0.02173609, -(0.007801671), -(0.03409022),
    0.01880949, 0.05432601, -(0.04359638), -(0.09938437), 0.1320791, 0.4642416);
  ATRAC3P_MDCT_SIZE := (ATRAC3P_SUBBAND_SAMPLES * 2);
  var Temporary3: TArray<Single>;
  SetLength(Temporary3, 2048);
  sine_table := Temporary3;
  var Temporary4: TArray<Single>;
  SetLength(Temporary4, 256);
  hann_window := Temporary4;
  var Temporary5: TArray<Single>;
  SetLength(Temporary5, 64);
  amp_sf_tab := Temporary5;
  TWOPI := (2 * Pi);
  ff_atrac3p_qu_to_spec_pos := TArray<Integer>.Create(0, 16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
    288, 320, 352, 384, 448, 512, 576, 640, 704, 768, 896, 1024, 1152, 1280, 1408, 1536, 1664, 1792, 1920,
    2048);
  ff_atrac3p_sf_tab := TArray<Single>.Create(0.027852058, 0.0350914, 0.04421234, 0.055704117, 0.0701828,
    0.08842468, 0.11140823, 0.1403656, 0.17684937, 0.22281647, 0.2807312, 0.35369873, 0.44563293, 0.5614624,
    0.70739746, 0.89126587, 1.1229248, 1.4147949, 1.7825317, 2.2458496, 2.8295898, 3.5650635, 4.491699,
    5.6591797, 7.130127, 8.983398, 11.318359, 14.260254, 17.966797, 22.636719, 28.520508, 35.933594,
    45.273438, 57.041016, 71.86719, 90.546875, 114.08203, 143.73438, 181.09375, 228.16406, 287.46875,
    362.1875, 456.32812, 574.9375, 724.375, 912.65625, 1149.875, 1448.75, 1825.3125, 2299.75, 2897.5,
    3650.625, 4599.5, 5795.0, 7301.25, 9199.0, 11590.0, 14602.5, 18398.0, 23180.0, 29205.0, 36796.0, 46360.0,
    58410.0);
  ff_atrac3p_mant_tab := TArray<Single>.Create(0.0, 0.74801636, 0.44882202, 0.32058716, 0.20400238, 0.1496048,
    0.07239151, 0.035619736);
  subband_to_powgrp := TArray<Integer>.Create(0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4);
  noise_tab := TArray<Single>.Create(-(0.01358032), -(0.05593872), 0.01696777, -(0.14871216), -(0.26412964),
    -(0.09893799), 0.25723267, 0.02008057, -(0.7223511), -(0.44351196), -(0.2298584), 0.16833496, 0.46902466,
    0.05917358, -(0.15179443), 0.41299438, -(0.01287842), 0.13360596, 0.4355774, -(0.0953064), -(0.5842285),
    0.39266968, -(0.08343506), -(0.25604248), 0.2284851, 0.26013184, -(0.6558838), 0.17288208, -(0.08673096),
    -(0.05203247), 0.07299805, -(0.2866516), -(0.35806274), 0.06552124, -(0.09387207), 0.21099854,
    -(0.28347778), -(0.72402954), 0.05050659, -(0.10635376), -(0.1885376), 0.2972412, 0.20703125,
    -(0.2979126), -(0.37634277), 0.4797058, -(0.09976196), 0.32641602, -(0.29248047), -(0.28237915),
    0.26028442, -(0.36157227), 0.22042847, -(0.03222656), -(0.37268066), -(0.03759766), 0.09909058,
    0.23284912, 0.19320679, 0.14453125, -(0.02139282), -(0.19702148), 0.31533813, -(0.16741943), 0.35031128,
    -(0.35656738), -(0.6612854), -(0.00701904), 0.20898438, 0.26837158, -(0.33706665), -(0.04568481),
    0.12600708, 0.10284424, 0.07321167, -(0.1828003), 0.38101196, 0.2130127, 0.04541016, 0.01156616,
    -(0.26391602), -(0.02346802), -(0.22125244), 0.29760742, -(0.3623352), -(0.31314087), -(0.13967896),
    -(0.11276245), -(0.19433594), 0.34490967, 0.0234375, 0.21963501, -(0.027771), -(0.67678833),
    -(0.08999634), 0.14233398, -(0.27697754), 0.5142212, -(0.05047607), 0.48327637, 0.37167358, -(0.60806274),
    0.18728638, -(0.1519165), 0.00637817, 0.02832031, -(0.15618896), 0.6064453, 0.21826172, 0.06384277,
    -(0.31863403), 0.08816528, 0.15447998, -(0.07015991), -(0.08154297), -(0.40966797), -(0.39785767),
    -(0.11709595), 0.22052002, 0.18466187, -(0.1725769), 0.03759766, -(0.06195068), 0.0043335, 0.12176514,
    0.3401184, 0.25610352, -(0.052948), 0.41033936, 0.16854858, -(0.76187134), 0.13845825, -(0.19418335),
    -(0.21524048), -(0.4441223), -(0.081604), -(0.2819519), -(0.01873779), 0.15524292, -(0.37438965),
    -(0.4486084), 0.43096924, -(0.24746704), 0.49856567, 0.14859009, 0.3815918, 0.20541382, -(0.39175415),
    -(0.6585083), -(0.4371643), 0.1303711, -(0.05111694), 0.39956665, 0.21447754, -(0.0486145), 0.33654785,
    0.105896, -(0.8808594), -(0.30822754), 0.3857727, 0.30047607, 0.3883667, 0.09118652, -(0.3647766),
    -(0.01641846), -(0.23031616), 0.2605896, 0.18859863, -(0.21868896), -(0.17861938), -(0.2975464),
    0.09777832, 0.10806274, -(0.51605225), 0.00076294, 0.13259888, 0.11090088, -(0.24084473), 0.24957275,
    0.01379395, -(0.04141235), -(0.04937744), 0.5739441, 0.2741089, 0.2758789, 0.45013428, -(0.32592773),
    0.11160278, -(0.00970459), 0.29092407, 0.03356934, -(0.70925903), 0.04882812, 0.43499756, 0.07720947,
    -(0.2755432), -(0.01742554), -(0.08413696), -(0.0402832), -(0.5285034), -(0.07330322), 0.05181885,
    0.21362305, -(0.18765259), 0.07058716, -(0.03009033), 0.32662964, 0.27023315, -(0.2800293), 0.1756897,
    0.03338623, 0.3024292, -(0.03921509), 0.32174683, -(0.2373352), 0.08575439, -(0.38269043), 0.09194946,
    -(0.0723877), 0.17941284, -(0.51278687), -(0.25146484), 0.1979065, -(0.19195557), 0.16549683, 0.42456055,
    0.3912964, -(0.02868652), 0.17980957, 0.24902344, -(0.7658386), -(0.20959473), 0.61013794, 0.3701172,
    0.3685913, -(0.04486084), 0.10678101, -(0.15994263), -(0.05328369), 0.28463745, -(0.06420898),
    -(0.36987305), -(0.28009033), -(0.11764526), 0.04312134, -(0.0803833), 0.04885864, -(0.03067017),
    -(0.00042725), 0.3428955, -(0.0098877), 0.34838867, 0.3251648, -(0.16271973), 0.38269043, 0.03240967,
    0.12417603, -(0.14331055), -(0.34902954), -(0.18325806), 0.29421997, 0.44284058, 0.751709, -(0.67245483),
    -(0.12176514), 0.2791443, -(0.2980652), 0.19863892, 0.3008728, 0.22680664, -(0.366333), -(0.3253479),
    -(0.575531), -(0.16641235), 0.43811035, 0.08331299, 0.15942383, 0.26516724, -(0.24240112), -(0.11761475),
    -(0.16827393), -(0.14260864), 0.46343994, 0.11804199, -(0.55514526), -(0.02520752), -(0.14309692),
    0.00448608, 0.02749634, -(0.30545044), 0.70965576, 0.45108032, 0.6643982, -(0.68255615), -(0.12496948),
    0.09146118, -(0.21109009), -(0.23791504), 0.7994385, -(0.35205078), -(0.24963379), 0.18719482,
    -(0.1907959), 0.07458496, 0.07623291, -(0.28781128), -(0.37121582), -(0.19580078), -(0.01773071),
    -(0.1671753), 0.13040161, 0.14672852, 0.4237976, 0.03582764, 0.11431885, 0.05145264, 0.44702148,
    0.08963013, 0.01367188, -(0.54519653), -(0.1269226), 0.21176147, 0.04925537, 0.30670166, -(0.11029053),
    0.19555664, -(0.2774048), 0.23043823, 0.1555481, -(0.19299316), -(0.2572937), 0.17800903, -(0.03579712),
    -(0.05065918), -(0.06933594), -(0.09500122), -(0.07821655), 0.2388916, -(0.31900024), 0.0307312,
    -(0.00415039), 0.6131592, 0.37176514, -(0.13442993), -(0.15536499), -(0.19216919), -(0.3789978),
    0.19992065, 0.02630615, -(0.12573242), 0.25927734, -(0.0244751), 0.29629517, -(0.40731812), -(0.17333984),
    0.24310303, -(0.1060791), 0.14828491, 0.08792114, -(0.18743896), -(0.0557251), -(0.04833984), 0.10473633,
    -(0.2902832), -(0.6768799), -(0.28170776), -(0.41687012), 0.05413818, -(0.23284912), 0.09555054,
    -(0.08969116), -(0.15112305), 0.12738037, 0.35986328, 0.28948975, 0.30691528, 0.23956299, 0.06973267,
    -(0.3119812), -(0.18450928), 0.22280884, -(0.21600342), 0.23522949, -(0.6184082), -(0.13012695),
    0.26412964, 0.47320557, -(0.2644043), 0.38757324, 0.17352295, -(0.26104736), -(0.258667), -(0.1227417),
    -(0.29733276), 0.07687378, 0.18588257, -(0.08880615), 0.31185913, 0.0531311, -(0.1088562), -(0.14901733),
    -(0.22323608), -(0.08538818), 0.19812012, 0.19732666, -(0.18927002), 0.29058838, 0.2555542, -(0.48599243),
    0.1876831, 0.01345825, 0.34887695, 0.21530151, 0.19857788, 0.18661499, -(0.01394653), -(0.09063721),
    -(0.38781738), 0.27160645, -(0.20379639), -(0.3211975), -(0.2388916), 0.27096558, 0.24951172, 0.07922363,
    0.07479858, -(0.50946045), 0.10220337, 0.5836487, -(0.19503784), -(0.18560791), -(0.01165771), 0.47195435,
    0.2243042, -(0.38635254), -(0.037323), -(0.09179688), 0.06991577, 0.15106201, 0.20605469, -(0.05969238),
    -(0.4182129), 0.12231445, -(0.04672241), -(0.05117798), -(0.11523438), -(0.51849365), -(0.04077148),
    0.44284058, -(0.64086914), 0.17019653, 0.02236938, 0.2284851, -(0.23214722), -(0.32354736), -(0.14068604),
    -(0.29690552), -(0.19891357), 0.02774048, -(0.20965576), -(0.5219116), -(0.19299316), -(0.07290649),
    0.49053955, -(0.22302246), 0.056427, 0.13122559, -(0.20819092), -(0.835907), -(0.08181763), 0.26797485,
    -(0.00091553), -(0.09457397), 0.17089844, -(0.27020264), 0.30270386, 0.05496216, 0.09564209,
    -(0.08590698), 0.02130127, 0.35931396, 0.21728516, -(0.15396118), -(0.05053711), 0.02719116, 0.1630249,
    0.4321289, 0.10229492, -(0.40820312), 0.21646118, 0.08435059, -(0.1114502), -(0.3996277), -(0.05618286),
    -(0.10223389), -(0.60839844), 0.33724976, -(0.06341553), -(0.47369385), -(0.32852173), 0.0524292,
    0.1963501, -(0.19137573), -(0.6790161), 0.1618042, 0.05133057, -(0.22283936), 0.09646606, 0.2428894,
    -(0.45007324), 0.08804321, 0.14053345, 0.22619629, -(0.01000977), 0.3635559, -(0.19863892), -(0.3036499),
    -(0.24118042), -(0.5746155), 0.26498413, 0.04345703, -(0.09796143), -(0.47714233), -(0.23739624),
    0.18737793, 0.08926392, -(0.0279541), 0.00305176, -(0.08700562), -(0.38711548), 0.03222656, 0.10940552,
    -(0.41906738), -(0.01620483), -(0.47061157), 0.3798523, -(0.21624756), 0.47976685, -(0.20046997),
    -(0.6253357), -(0.2690735), -(0.02877808), 0.00671387, -(0.29071045), -(0.24685669), -(0.15722656),
    -(0.26055908), 0.29968262, 0.28225708, -(0.08990479), -(0.16748047), -(0.46759033), -(0.2506714),
    -(0.25183105), -(0.45932007), 0.05828857, 0.29006958, 0.23840332, -(0.17974854), 0.26931763, 0.10696411,
    -(0.06848145), -(0.17126465), -(0.10522461), -(0.5538635), -(0.4230652), -(0.07608032), 0.24380493,
    0.38586426, 0.16882324, 0.2675171, 0.17303467, 0.35809326, -(0.22094727), -(0.30703735), -(0.28497314),
    -(0.04321289), 0.15219116, -(0.17071533), -(0.39334106), 0.03439331, -(0.10809326), -(0.3059082),
    0.26449585, -(0.0741272), 0.13638306, -(0.01062012), 0.27996826, 0.04397583, -(0.05557251), -(0.56933594),
    0.03363037, -(0.00949097), 0.5264282, -(0.44329834), 0.28308105, -(0.05499268), -(0.23312378),
    -(0.29870605), -(0.05123901), 0.26831055, -(0.35238647), -(0.30993652), 0.34646606, -(0.1977539),
    0.44595337, 0.13769531, 0.45358276, 0.19961548, 0.42681885, 0.15722656, 0.00128174, 0.23757935, 0.4098816,
    0.25164795, -(0.00732422), -(0.12405396), -(0.4342041), -(0.00402832), 0.34243774, 0.36264038, 0.18807983,
    -(0.09301758), -(0.10296631), 0.05532837, -(0.31652832), 0.14337158, 0.35040283, 0.32540894, 0.05728149,
    -(0.12030029), -(0.25942993), -(0.203125), -(0.16491699), -(0.46051025), -(0.08004761), 0.50772095,
    0.16168213, 0.2843933, 0.08105469, -(0.19104004), 0.38589478, -(0.16400146), -(0.25454712), 0.20281982,
    -(0.20730591), -(0.06311035), 0.32937622, 0.15032959, -(0.05340576), 0.3048706, -(0.1164856), 0.38009644,
    -(0.20062256), 0.43466187, 0.01150513, 0.35754395, -(0.13146973), 0.67489624, 0.05212402, 0.2791443,
    -(0.39431763), 0.7530823, -(0.13366699), 0.24453735, 0.42248535, -(0.6590576), -(0.00546265),
    -(0.03491211), -(0.13659668), -(0.08294678), -(0.45666504), 0.2718811, 0.12731934, 0.6114807, 0.10449219,
    -(0.2883606), 0.00091553, 0.2461853, 0.13119507, 0.05685425, 0.17355347, 0.42034912, 0.08514404,
    0.24536133, 0.18951416, -(0.19107056), -(0.1503601), 0.02334595, 0.5498657, 0.32321167, -(0.16104126),
    -(0.0305481), 0.4359436, 0.1730957, 0.61053467, 0.24731445, 0.3333435, 0.15240479, 0.15588379, 0.3642578,
    -(0.30407715), -(0.13302612), 0.00427246, 0.04171753, -(0.3317871), 0.3421631, -(0.12463379),
    -(0.02764893), 0.05905151, -(0.31436157), 0.16531372, 0.34542847, -(0.03292847), 0.12527466,
    -(0.12313843), -(0.13171387), 0.0475769, -(0.45095825), -(0.19085693), 0.35342407, -(0.23239136),
    -(0.34387207), 0.11264038, -(0.15740967), 0.05273438, 0.74942017, 0.21505737, 0.08514404, -(0.42391968),
    -(0.1953125), 0.3529358, 0.25305176, 0.15731812, -(0.7032471), -(0.21591187), 0.35604858, 0.1413269,
    0.11724854, 0.15853882, -(0.24597168), 0.07019043, 0.02127075, 0.12658691, 0.06390381, -(0.1229248),
    0.15441895, -(0.4764099), 0.06195068, 0.58981323, -(0.15151978), -(0.03604126), -(0.45059204),
    -(0.01672363), -(0.4699707), 0.25750732, 0.18084717, 0.06661987, 0.13253784, 0.6782837, 0.1137085,
    0.11325073, -(0.04611206), -(0.07791138), -(0.365448), -(0.06747437), -(0.3159485), 0.16131592,
    0.41983032, 0.11071777, -(0.36889648), 0.30963135, -(0.37875366), 0.585083, 0.00393677, 0.12338257,
    0.03424072, -(0.21728516), -(0.12838745), -(0.46981812), 0.0586853, -(0.2501526), 0.27407837, 0.6524048,
    -(0.34429932), -(0.15179443), 0.14056396, 0.3350525, 0.28826904, 0.09921265, 0.3439026, 0.13656616,
    -(0.23608398), 0.00863647, 0.02627563, -(0.19119263), 0.1977539, -(0.07214355), 0.07809448, 0.0345459,
    -(0.03417969), 0.00033569, -(0.23095703), 0.18673706, 0.0579834, 0.03814697, -(0.04318237), 0.05487061,
    0.08633423, 0.5595093, -(0.06347656), 0.10333252, 0.25305176, 0.05853271, 0.12246704, -(0.25543213),
    -(0.34262085), -(0.36437988), -(0.21304321), -(0.05093384), 0.027771, 0.07620239, -(0.2121582),
    -(0.09326172), 0.19021606, -(0.40579224), -(0.01193237), 0.19845581, -(0.35336304), -(0.07397461),
    0.2010498, 0.08615112, -(0.4437561), 0.11419678, 0.24453735, -(0.16555786), -(0.05081177), -(0.0140686),
    0.27893066, -(0.18692017), 0.07473755, 0.03451538, -(0.39733887), 0.21548462, -(0.2253418), -(0.3965149),
    -(0.04989624), -(0.57662964), 0.06390381, 0.62020874, -(0.13470459), 0.04345703, -(0.21862793),
    -(0.02789307), 0.5169678, -(0.2758789), 0.39004517, 0.09857178, -(0.00738525), 0.3131714, 0.00048828,
    -(0.46572876), 0.2953186, -(0.10009766), -(0.27856445), 0.03594971, 0.25048828, -(0.7458496),
    -(0.25350952), -(0.03302002), 0.31188965, 0.01571655, 0.46710205, 0.21591187, 0.07260132, -(0.42132568),
    -(0.53900146), -(0.13674927), -(0.16571045), -(0.34454346), 0.12359619, -(0.11184692), 0.00967407,
    0.34576416, -(0.05761719), 0.34848022, 0.17645264, -(0.39395142), 0.10339355, 0.18215942, 0.20697021,
    0.591095, -(0.11560059), -(0.07385254), 0.10397339, 0.35437012, -(0.2286377), 0.01794434, 0.17559814,
    -(0.17495728), 0.12142944, 0.10928345, -(1.0), -(0.01379395), 0.21237183, -(0.27035522), 0.27319336,
    -(0.3706665), 0.4135437, -(0.4005432), 0.00689697, 0.2632141, 0.39266968, 0.6529846, 0.41625977,
    -(0.13909912), 0.78375244, -(0.30941772), 0.20169067, -(0.39367676), 0.94021606, -(0.24066162),
    0.05557251, -(0.24533081), -(0.05444336), -(0.7675476), -(0.1937561), -(0.1104126), -(0.17532349),
    0.1600647, 0.0218811, 0.1746521, -(0.04342651), -(0.56777954), -(0.4098816), 0.26687622, 0.11700439,
    -(0.00344849), -(0.05395508), 0.37426758, -(0.40719604), -(0.15032959), -(0.01660156), 0.04196167,
    -(0.04559326), -(0.1296997), 0.12011719, 0.084198, -(0.11199951), 0.3517456, 0.10275269, -(0.25686646),
    0.48446655, 0.03225708, 0.28408813, -(0.18701172), 0.3628235, -(0.0328064), 0.32302856, 0.17233276,
    0.48269653, 0.3111267, -(0.04946899), 0.12774658, 0.52685547, 0.10211182, 0.05953979, 0.05999756,
    0.20144653, 0.00744629, 0.27316284, 0.24377441, 0.39672852, 0.01702881, -(0.35513306), 0.11364746,
    -(0.13555908), 0.48880005, -(0.1541748), -(0.0914917), -(0.02615356), 0.46246338, -(0.72250366),
    0.22332764, 0.23849487, -(0.25686646), -(0.08514404), -(0.02062988), -(0.3449402), -(0.02297974),
    -(0.8038635), -(0.08074951), -(0.12689209), -(0.06896973), 0.24099731, -(0.35650635), -(0.09558105),
    0.2925415, 0.23132324, -(0.16726685), 0.0, -(0.2423706), 0.30899048, 0.29504395, -(0.20898438),
    0.17059326, -(0.07672119), -(0.14395142), 0.0557251, 0.20602417, -(0.5155029), -(0.03167725),
    -(0.48840332), -(0.20425415), 0.14144897, 0.07275391, -(0.7666931), -(0.22488403), 0.20651245, 0.03259277,
    0.00085449, 0.03039551, 0.47555542, 0.3835144);
  pwc_levs := TArray<Single>.Create(3.96875, 3.15625, 2.5, 2.0, 1.59375, 1.25, 1.0, 0.78125, 0.625, 0.5,
    0.40625, 0.3125, 0.25, 0.1875, 0.15625, 0.0);
  subband_to_qu := TArray<Integer>.Create(0, 8, 12, 16, 18, 20, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32);
  mod23_lut := TArray<Integer>.Create(23, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 0);
  ipqf_coeffs1 := TArray<TArray<Single>>.Create(TArray<Single>.Create(-(5.8336207e-07), -(8.060423e-07),
      -(4.200541e-07), -(4.4400572e-08), 3.226247e-08, 3.530856e-08, 1.2660377e-08, 1.0516783e-05,
      -(1.1838618e-05), 6.005389e-07, 1.4333754e-06, 2.3108685e-06, 3.2569742e-06, 4.619242e-06, 6.389426e-06,
      7.030297e-06), TArray<Single>.Create(-(9.162282e-06), -(1.0502935e-05), -(7.921279e-06), -(4.1712024e-06),
      -(2.633663e-06), -(1.5432918e-06), -(5.7168614e-07), 1.8111954e-06, 2.353085e-05, 2.780562e-05,
      3.2302323e-05, 3.696892e-05, 4.1575615e-05, 4.5337845e-05, 4.6043948e-05, 4.858558e-05),
    TArray<Single>.Create(-(6.446455e-05), -(6.830695e-05), -(7.308147e-05), -(7.612785e-05), -(7.485075e-05),
      -(7.020851e-05), -(6.228515e-05), -(5.827044e-05), -(5.629633e-05), -(4.988881e-05), -(3.5615325e-05),
      -(1.8532943e-05), 1.6657353e-06, 2.610587e-05, 5.3397067e-05, 8.079566e-05),
    TArray<Single>.Create(-(0.0005448855), -(0.0005253723), -(0.00049731287), -(0.00045778), -(0.00040612387),
      -(0.00034301577), -(0.00026866337), -(0.000182489), -(8.4307925e-05), 2.5081157e-05, 0.00014135583,
      0.00026649953, 0.00039945057, 0.0005392845, 0.00068422867, 0.0008309371),
    TArray<Single>.Create(-(0.0014771431), -(0.001283227), -(0.0010566821), -(0.00079780724),
      -(0.00050782406), -(0.00018855913), 0.00015771533, 0.00052769453, 0.0009186222, 0.001326357, 0.0017469483,
      0.0021754825, 0.0026067684, 0.0030352892, 0.0034549395, 0.0038591374),
    TArray<Single>.Create(-(0.0022995141), -(0.001443546), -(0.0004926657), 0.0005506899, 0.001682895,
      0.0028992873, 0.004194315, 0.005561474, 0.006993512, 0.008482357, 0.010018963, 0.011593862, 0.013196872,
      0.014817309, 0.016444042, 0.018065533), TArray<Single>.Create(-(0.034426283), -(0.034281436),
      -(0.033992987), -(0.03356325), -(0.032995768), -(0.032295227), -(0.031467363), -(0.030518902),
      -(0.02945766), -(0.028291954), -(0.027031265), -(0.025685543), -(0.024265358), -(0.022781773),
      -(0.021246184), -(0.019670162)), TArray<Single>.Create(-(0.0030586775), -(0.0037203205), -(0.0042847847),
      -(0.0047529764), -(0.0051268316), -(0.0054091476), -(0.0056034233), -(0.005714261), -(0.0057445862),
      -(0.0057025906), -(0.005592011), -(0.0054194843), -(0.0051914565), -(0.0049146507), -(0.0045959447),
      -(0.004241827)), TArray<Single>.Create(-(0.0016376863), -(0.0017651899), -(0.0018608454), -(0.0019252141),
      -(0.001959379), -(0.0019653172), -(0.0019450618), -(0.0018990048), -(0.00183808), -(0.0017501717),
      -(0.0016481078), -(0.0015320742), -(0.0014046903), -(0.0012685474), -(0.001125814), -(0.0009794373)),
    TArray<Single>.Create(-(0.0005543238), -(0.00055472925), -(0.0005478346), -(0.0005327692),
      -(0.0005113579), -(0.00048466062), -(0.00045358928), -(0.0004249969), -(0.0003694267), -(0.0003392619),
      -(0.00030001783), -(0.00025986304), -(0.0002197204), -(0.00018116167), -(0.00014691355),
      -(0.00011279432)), TArray<Single>.Create(-(6.414739e-05), -(6.174868e-05), -(5.4267788e-05),
      -(4.7133824e-05), -(4.2927582e-05), -(3.947731e-05), -(3.6340745e-05), -(2.9687517e-05), -(4.9787737e-05),
      -(4.157789e-05), -(3.3864744e-05), -(2.6534748e-05), -(1.9841305e-05), -(1.4789486e-05), -(1.3131184e-05),
      -(9.919887e-06)), TArray<Single>.Create(-(6.2990207e-06), -(7.270126e-06), -(1.1984052e-05),
      -(1.7348082e-05), -(1.9907106e-05), -(2.1348773e-05), -(2.1961965e-05), -(1.2203576e-05),
      -(1.0840992e-05), 4.6299544e-07, 5.2588763e-07, 2.7792686e-07, -(2.3649704e-07), -(1.0897784e-06),
      -(9.171448e-07), -(5.22682e-07)));
  ipqf_coeffs2 := TArray<TArray<Single>>.Create(TArray<Single>.Create(5.22682e-07, 9.171448e-07, 1.0897784e-06,
      2.3649704e-07, -(2.7792686e-07), -(5.2588763e-07), -(4.6299544e-07), 1.0840992e-05, -(1.2203576e-05),
      -(2.1961965e-05), -(2.1348773e-05), -(1.9907106e-05), -(1.7348082e-05), -(1.1984052e-05), -(7.270126e-06),
      -(6.2990207e-06)), TArray<Single>.Create(9.919887e-06, 1.3131184e-05, 1.4789486e-05, 1.9841305e-05,
      2.6534748e-05, 3.3864744e-05, 4.157789e-05, 4.9787737e-05, -(2.9687517e-05), -(3.6340745e-05),
      -(3.947731e-05), -(4.2927582e-05), -(4.7133824e-05), -(5.4267788e-05), -(6.174868e-05), -(6.414739e-05)),
    TArray<Single>.Create(0.00011279432, 0.00014691355, 0.00018116167, 0.0002197204, 0.00025986304,
      0.00030001783, 0.0003392619, 0.0003694267, -(0.0004249969), -(0.00045358928), -(0.00048466062),
      -(0.0005113579), -(0.0005327692), -(0.0005478346), -(0.00055472925), -(0.0005543238)),
    TArray<Single>.Create(0.0009794373, 0.001125814, 0.0012685474, 0.0014046903, 0.0015320742, 0.0016481078,
      0.0017501717, 0.00183808, -(0.0018990048), -(0.0019450618), -(0.0019653172), -(0.001959379),
      -(0.0019252141), -(0.0018608454), -(0.0017651899), -(0.0016376863)), TArray<Single>.Create(0.004241827,
      0.0045959447, 0.0049146507, 0.0051914565, 0.0054194843, 0.005592011, 0.0057025906, 0.0057445862,
      -(0.005714261), -(0.0056034233), -(0.0054091476), -(0.0051268316), -(0.0047529764), -(0.0042847847),
      -(0.0037203205), -(0.0030586775)), TArray<Single>.Create(0.019670162, 0.021246184, 0.022781773,
      0.024265358, 0.025685543, 0.027031265, 0.028291954, 0.02945766, -(0.030518902), -(0.031467363),
      -(0.032295227), -(0.032995768), -(0.03356325), -(0.033992987), -(0.034281436), -(0.034426283)),
    TArray<Single>.Create(-(0.018065533), -(0.016444042), -(0.014817309), -(0.013196872), -(0.011593862),
      -(0.010018963), -(0.008482357), -(0.006993512), 0.005561474, 0.004194315, 0.0028992873, 0.001682895,
      0.0005506899, -(0.0004926657), -(0.001443546), -(0.0022995141)), TArray<Single>.Create(-(0.0038591374),
      -(0.0034549395), -(0.0030352892), -(0.0026067684), -(0.0021754825), -(0.0017469483), -(0.001326357),
      -(0.0009186222), 0.00052769453, 0.00015771533, -(0.00018855913), -(0.00050782406), -(0.00079780724),
      -(0.0010566821), -(0.001283227), -(0.0014771431)), TArray<Single>.Create(-(0.0008309371),
      -(0.00068422867), -(0.0005392845), -(0.00039945057), -(0.00026649953), -(0.00014135583), -(2.5081157e-05),
      8.4307925e-05, -(0.000182489), -(0.00026866337), -(0.00034301577), -(0.00040612387), -(0.00045778),
      -(0.00049731287), -(0.0005253723), -(0.0005448855)), TArray<Single>.Create(-(8.079566e-05),
      -(5.3397067e-05), -(2.610587e-05), -(1.6657353e-06), 1.8532943e-05, 3.5615325e-05, 4.988881e-05,
      5.629633e-05, -(5.827044e-05), -(6.228515e-05), -(7.020851e-05), -(7.485075e-05), -(7.612785e-05),
      -(7.308147e-05), -(6.830695e-05), -(6.446455e-05)), TArray<Single>.Create(-(4.858558e-05),
      -(4.6043948e-05), -(4.5337845e-05), -(4.1575615e-05), -(3.696892e-05), -(3.2302323e-05), -(2.780562e-05),
      -(2.353085e-05), 1.8111954e-06, -(5.7168614e-07), -(1.5432918e-06), -(2.633663e-06), -(4.1712024e-06),
      -(7.921279e-06), -(1.0502935e-05), -(9.162282e-06)), TArray<Single>.Create(-(7.030297e-06),
      -(6.389426e-06), -(4.619242e-06), -(3.2569742e-06), -(2.3108685e-06), -(1.4333754e-06), -(6.005389e-07),
      1.1838618e-05, 1.0516783e-05, 1.2660377e-08, 3.530856e-08, 3.226247e-08, -(4.4400572e-08),
      -(4.200541e-07), -(8.060423e-07), -(5.8336207e-07)));
  var Temporary6: TArray<TATVLC>;
  SetLength(Temporary6, 4);
  wl_vlc_tabs := Temporary6;
  var Temporary7: TArray<TATVLC>;
  SetLength(Temporary7, 8);
  sf_vlc_tabs := Temporary7;
  var Temporary8: TArray<TATVLC>;
  SetLength(Temporary8, 4);
  ct_vlc_tabs := Temporary8;
  var Temporary9: TArray<TATVLC>;
  SetLength(Temporary9, 112);
  spec_vlc_tabs := Temporary9;
  var Temporary10: TArray<TATVLC>;
  SetLength(Temporary10, 11);
  gain_vlc_tabs := Temporary10;
  var Temporary11: TArray<TATVLC>;
  SetLength(Temporary11, 7);
  tone_vlc_tabs := Temporary11;
  wl_nb_bits := TArray<Integer>.Create(2, 3, 5, 5);
  wl_nb_codes := TArray<Integer>.Create(3, 5, 8, 8);
  wl_bits := TArray<TArray<Integer>>.Create(atrac3p_wl_huff_bits1, atrac3p_wl_huff_bits2, atrac3p_wl_huff_bits3,
    atrac3p_wl_huff_bits4);
  wl_codes := TArray<TArray<Integer>>.Create(atrac3p_wl_huff_code1, atrac3p_wl_huff_code2,
    atrac3p_wl_huff_code3, atrac3p_wl_huff_code4);
  wl_xlats := TArray<TArray<Integer>>.Create(atrac3p_wl_huff_xlat1, atrac3p_wl_huff_xlat2, nil, nil);
  ct_nb_bits := TArray<Integer>.Create(3, 4, 4, 4);
  ct_nb_codes := TArray<Integer>.Create(4, 8, 8, 8);
  ct_bits := TArray<TArray<Integer>>.Create(atrac3p_ct_huff_bits1, atrac3p_ct_huff_bits2, atrac3p_ct_huff_bits2,
    atrac3p_ct_huff_bits3);
  ct_codes := TArray<TArray<Integer>>.Create(atrac3p_ct_huff_code1, atrac3p_ct_huff_code2,
    atrac3p_ct_huff_code2, atrac3p_ct_huff_code3);
  ct_xlats := TArray<TArray<Integer>>.Create(nil, nil, atrac3p_ct_huff_xlat1, nil);
  sf_nb_bits := TArray<Integer>.Create(9, 9, 9, 9, 6, 6, 7, 7);
  sf_nb_codes := TArray<Integer>.Create(64, 64, 64, 64, 16, 16, 16, 16);
  sf_bits := TArray<TArray<Integer>>.Create(atrac3p_sf_huff_bits1, atrac3p_sf_huff_bits1, atrac3p_sf_huff_bits2,
    atrac3p_sf_huff_bits3, atrac3p_sf_huff_bits4, atrac3p_sf_huff_bits4, atrac3p_sf_huff_bits5,
    atrac3p_sf_huff_bits6);
  sf_codes := TArray<TArray<Integer>>.Create(atrac3p_sf_huff_code1, atrac3p_sf_huff_code1,
    atrac3p_sf_huff_code2, atrac3p_sf_huff_code3, atrac3p_sf_huff_code4, atrac3p_sf_huff_code4,
    atrac3p_sf_huff_code5, atrac3p_sf_huff_code6);
  sf_xlats := TArray<TArray<Integer>>.Create(atrac3p_sf_huff_xlat1, atrac3p_sf_huff_xlat2, nil, nil,
    atrac3p_sf_huff_xlat4, atrac3p_sf_huff_xlat5, nil, nil);
  gain_cbs := TArray<TArray<Integer>>.Create(atrac3p_huff_gain_npoints1_cb, atrac3p_huff_gain_npoints1_cb,
    atrac3p_huff_gain_lev1_cb, atrac3p_huff_gain_lev2_cb, atrac3p_huff_gain_lev3_cb,
    atrac3p_huff_gain_lev4_cb, atrac3p_huff_gain_loc3_cb, atrac3p_huff_gain_loc1_cb,
    atrac3p_huff_gain_loc4_cb, atrac3p_huff_gain_loc2_cb, atrac3p_huff_gain_loc5_cb);
  gain_xlats := TArray<TArray<Integer>>.Create(nil, atrac3p_huff_gain_npoints2_xlat,
    atrac3p_huff_gain_lev1_xlat, atrac3p_huff_gain_lev2_xlat, atrac3p_huff_gain_lev3_xlat,
    atrac3p_huff_gain_lev4_xlat, atrac3p_huff_gain_loc3_xlat, atrac3p_huff_gain_loc1_xlat,
    atrac3p_huff_gain_loc4_xlat, atrac3p_huff_gain_loc2_xlat, atrac3p_huff_gain_loc5_xlat);
  tone_cbs := TArray<TArray<Integer>>.Create(atrac3p_huff_tonebands_cb, atrac3p_huff_numwavs1_cb,
    atrac3p_huff_numwavs2_cb, atrac3p_huff_wav_ampsf1_cb, atrac3p_huff_wav_ampsf2_cb,
    atrac3p_huff_wav_ampsf3_cb, atrac3p_huff_freq_cb);
  tone_xlats := TArray<TArray<Integer>>.Create(nil, nil, atrac3p_huff_numwavs2_xlat,
    atrac3p_huff_wav_ampsf1_xlat, atrac3p_huff_wav_ampsf2_xlat, atrac3p_huff_wav_ampsf3_xlat,
    atrac3p_huff_freq_xlat);
  TATChannelUnit.Init;

finalization
  for var Item in wl_vlc_tabs do
    Item.Free;
  for var Item in sf_vlc_tabs do
    Item.Free;
  for var Item in ct_vlc_tabs do
    Item.Free;
  for var Item in spec_vlc_tabs do
    Item.Free;
  for var Item in gain_vlc_tabs do
    Item.Free;
  for var Item in tone_vlc_tabs do
    Item.Free;

end.

