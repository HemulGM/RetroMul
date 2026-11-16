unit Audio.ATRAC3.Decoder;
// Native Delphi translation of Jpcsp ATRAC3, based on FFmpeg (Maxim
// Poliakovski, Benjamin Larsson). GPL-3.0-or-later; see LICENSE.ATRAC3.md.
{$Q-}{$R-}{$B-}

interface

uses
  System.SysUtils, System.Math, Audio.ATRAC3Plus.Primitives,
  Audio.ATRAC3Plus.Decoder;

const
  AT3_ERROR = -2;
  JOINT_STEREO = 18;
  STEREO = 2;
  SAMPLES_PER_FRAME = 1024;
  MDCT_SIZE = 512;

type
  TAT3TonalComponent = class;

  TAT3GainBlock = class;

  TAT3ChannelUnit = class;

  TAT3Context = class;

  TAT3Atrac3Decoder = class;

  TAT3TonalComponent = class
  public
    pos: Integer;
    numCoefs: Integer;
    coef: TArray<Single>;
    constructor Create;
  end;

  TAT3GainBlock = class
  public
    gBlock: TArray<TATAtracGainInfo>;
    constructor Create;
    destructor Destroy; override;
  end;

  TAT3ChannelUnit = class
  public
    bandsCoded: Integer;
    numComponents: Integer;
    prevFrame: TArray<Single>;
    gcBlkSwitch: Integer;
    components: TArray<TAT3TonalComponent>;
    gainBlock: TArray<TAT3GainBlock>;
    spectrum: TArray<Single>;
    imdctBuf: TArray<Single>;
    delayBuf1: TArray<Single>;
    delayBuf2: TArray<Single>;
    delayBuf3: TArray<Single>;
    constructor Create;
    destructor Destroy; override;
  end;

  TAT3Context = class
  public
    br: TATBits;
    codingMode: Integer;
    units: TArray<TAT3ChannelUnit>;
    channels: Integer;
    outputChannels: Integer;
    blockAlign: Integer;
    matrixCoeffIndexPrev: TArray<Integer>;
    matrixCoeffIndexNow: TArray<Integer>;
    matrixCoeffIndexNext: TArray<Integer>;
    weightingDelay: TArray<Integer>;
    tempBuf: TArray<Single>;
    gaincCtx: TATAtrac;
    mdctCtx: TATIMDCT;
    samples: TArray<TArray<Single>>;
    constructor Create;
    destructor Destroy; override;
  end;

  TAT3Atrac3Decoder = class
  public
    ctx: TAT3Context;
    br: TATBits;
    constructor Create;
    class procedure initStaticData; static;
    function init(Arg_blockAlign: Integer; Arg_channels: Integer; Arg_outputChannels: Integer; Arg_codingMode: Integer): Integer;
    procedure imlt(Arg_input: TArray<Single>; Arg_inputOffset: Integer; Arg_output: TArray<Single>; Arg_outputOffset: Integer; Arg_oddBand: Boolean);
    class procedure initImdctWindow; static;
    function decodeGainControl(Arg_block: TAT3GainBlock; Arg_numBands: Integer): Integer;
    function decodeTonalComponents(Arg_components: TArray<TAT3TonalComponent>; Arg_numBands: Integer): Integer;
    procedure readQuantSpectralCoeffs(Arg_selector: Integer; Arg_codingFlag: Integer; Arg_mantissas: TArray<Integer>; Arg_numCodes: Integer);
    function decodeSpectrum(Arg_output: TArray<Single>): Integer;
    function addTonalComponents(Arg_spectrum: TArray<Single>; Arg_numComponents: Integer; Arg_components: TArray<TAT3TonalComponent>): Integer;
    procedure reverseMatrixing(Arg_su1: TArray<Single>; Arg_su2: TArray<Single>; Arg_prevCode: TArray<Integer>; Arg_currCode: TArray<Integer>);
    procedure getChannelWeights(Arg_index: Integer; Arg_flag: Integer; Arg_ch: TArray<Single>);
    function INTERPOLATE(Arg_oldValue: Single; Arg_newValue: Single; Arg_nsample: Integer): Single;
    procedure channelWeighting(Arg_su1: TArray<Single>; Arg_su2: TArray<Single>; Arg_p3: TArray<Integer>);
    function decodeChannelSoundUnit(Arg_snd: TAT3ChannelUnit; Arg_output: TArray<Single>; Arg_channelNum: Integer; Arg_codingMode: Integer): Integer;
    function decodeFrame: Integer;
    destructor Destroy; override;
  end;

var
  mdct_window: TArray<Single>;
  spectral_coeff_tab: TArray<TATVLC>;
  staticInitDone: Boolean;
  huffcode1: TArray<Integer>;
  huffbits1: TArray<Integer>;
  huffcode2: TArray<Integer>;
  huffbits2: TArray<Integer>;
  huffcode3: TArray<Integer>;
  huffbits3: TArray<Integer>;
  huffcode4: TArray<Integer>;
  huffbits4: TArray<Integer>;
  huffcode5: TArray<Integer>;
  huffbits5: TArray<Integer>;
  huffcode6: TArray<Integer>;
  huffbits6: TArray<Integer>;
  huffcode7: TArray<Integer>;
  huffbits7: TArray<Integer>;
  huff_tab_sizes: TArray<Integer>;
  huff_codes: TArray<TArray<Integer>>;
  huff_bits: TArray<TArray<Integer>>;
  atrac3_vlc_offs: TArray<Integer>;
  clc_length_tab: TArray<Integer>;
  mantissa_clc_tab: TArray<Integer>;
  mantissa_vlc_tab: TArray<Integer>;
  inv_max_quant: TArray<Single>;
  subband_tab: TArray<Integer>;
  matrix_coeffs: TArray<Single>;

implementation

procedure VectorFmul(const Dest: TATFloats; DestOffset: Integer; const A: TATFloats; AOffset: Integer; const B: TATFloats; BOffset, Count: Integer);
begin
  for var I := 0 to Count - 1 do
    Dest[DestOffset + I] := A[AOffset + I] * B[BOffset + I]
end;

constructor TAT3TonalComponent.Create;
begin
  inherited Create;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, 8);
  coef := Temporary1;
end;

constructor TAT3GainBlock.Create;
begin
  inherited Create;
  var Temporary1: TArray<TATAtracGainInfo>;
  SetLength(Temporary1, 4);
  gBlock := Temporary1;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(gBlock)) do
    begin
      begin
        gBlock[V_i] := TATAtracGainInfo.Create();
      end;
      Inc(V_i);
    end;
  end;
end;

destructor TAT3GainBlock.Destroy;
begin
  for var Item in gBlock do
    Item.Free;
  inherited;
end;

constructor TAT3ChannelUnit.Create;
begin
  inherited Create;
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, SAMPLES_PER_FRAME);
  prevFrame := Temporary1;
  var Temporary2: TArray<TAT3TonalComponent>;
  SetLength(Temporary2, 64);
  components := Temporary2;
  var Temporary3: TArray<TAT3GainBlock>;
  SetLength(Temporary3, 2);
  gainBlock := Temporary3;
  var Temporary4: TArray<Single>;
  SetLength(Temporary4, SAMPLES_PER_FRAME);
  spectrum := Temporary4;
  var Temporary5: TArray<Single>;
  SetLength(Temporary5, SAMPLES_PER_FRAME);
  imdctBuf := Temporary5;
  var Temporary6: TArray<Single>;
  SetLength(Temporary6, 46);
  delayBuf1 := Temporary6;
  var Temporary7: TArray<Single>;
  SetLength(Temporary7, 46);
  delayBuf2 := Temporary7;
  var Temporary8: TArray<Single>;
  SetLength(Temporary8, 46);
  delayBuf3 := Temporary8;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(components)) do
    begin
      begin
        components[V_i] := TAT3TonalComponent.Create();
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(gainBlock)) do
    begin
      begin
        gainBlock[V_i] := TAT3GainBlock.Create();
      end;
      Inc(V_i);
    end;
  end;
end;

destructor TAT3ChannelUnit.Destroy;
begin
  for var Item in components do
    Item.Free;
  for var Item in gainBlock do
    Item.Free;
  inherited;
end;

constructor TAT3Context.Create;
begin
  inherited Create;
  var Temporary1: TArray<TAT3ChannelUnit>;
  SetLength(Temporary1, 2);
  units := Temporary1;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 4);
  matrixCoeffIndexPrev := Temporary2;
  var Temporary3: TArray<Integer>;
  SetLength(Temporary3, 4);
  matrixCoeffIndexNow := Temporary3;
  var Temporary4: TArray<Integer>;
  SetLength(Temporary4, 4);
  matrixCoeffIndexNext := Temporary4;
  var Temporary5: TArray<Integer>;
  SetLength(Temporary5, 6);
  weightingDelay := Temporary5;
  var Temporary6: TArray<Single>;
  SetLength(Temporary6, 1070);
  tempBuf := Temporary6;
  var Temporary7: TArray<TArray<Single>>;
  SetLength(Temporary7, 2, SAMPLES_PER_FRAME);
  samples := Temporary7;
end;

destructor TAT3Context.Destroy;
begin
  for var Item in units do
    Item.Free;
  gaincCtx.Free;
  mdctCtx.Free;
  inherited;
end;

constructor TAT3Atrac3Decoder.Create;
begin
  inherited Create;
end;

class procedure TAT3Atrac3Decoder.initStaticData;
begin
  if (staticInitDone) then
  begin
    Exit;
  end;
  initImdctWindow;
  TATAtrac.generateTables;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 7) do
    begin
      begin
        spectral_coeff_tab[V_i] := TATVLC.Create();
        spectral_coeff_tab[V_i].initVLCSparse(9, huff_tab_sizes[V_i], huff_bits[V_i], huff_codes[V_i], nil);
      end;
      Inc(V_i);
    end;
  end;
  staticInitDone := True;
end;

function TAT3Atrac3Decoder.init(Arg_blockAlign: Integer; Arg_channels: Integer; Arg_outputChannels: Integer; Arg_codingMode: Integer): Integer;
begin
  var V_ret: Integer;
  initStaticData;
  ctx := TAT3Context.Create();
  ctx.channels := Arg_channels;
  ctx.outputChannels := Arg_outputChannels;
  var Temporary1: Integer;
  if (Arg_codingMode <> 0) then
  begin
    Temporary1 := JOINT_STEREO;
  end
  else
  begin
    Temporary1 := STEREO;
  end;
  ctx.codingMode := Temporary1;
  ctx.blockAlign := Arg_blockAlign;
  ctx.mdctCtx := TATIMDCT.Create();
  V_ret := ctx.mdctCtx.mdctInit(9, True, (1.0 / 32768.0));
  if ((V_ret < 0)) then
  begin
    Exit(V_ret);
  end;
  ctx.weightingDelay[0] := 0;
  ctx.weightingDelay[1] := 7;
  ctx.weightingDelay[2] := 0;
  ctx.weightingDelay[3] := 7;
  ctx.weightingDelay[4] := 0;
  ctx.weightingDelay[5] := 7;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < 4) do
    begin
      begin
        ctx.matrixCoeffIndexPrev[V_i] := 3;
        ctx.matrixCoeffIndexNow[V_i] := 3;
        ctx.matrixCoeffIndexNext[V_i] := 3;
      end;
      Inc(V_i);
    end;
  end;
  ctx.gaincCtx := TATAtrac.Create();
  ctx.gaincCtx.initGainCompensation(4, 3);
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Length(ctx.units)) do
    begin
      begin
        ctx.units[V_i] := TAT3ChannelUnit.Create();
      end;
      Inc(V_i);
    end;
  end;
  Exit(0);
end;

procedure TAT3Atrac3Decoder.imlt(Arg_input: TArray<Single>; Arg_inputOffset: Integer; Arg_output: TArray<Single>; Arg_outputOffset: Integer; Arg_oddBand: Boolean);
begin
  if (Arg_oddBand) then
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < 128) do
      begin
        begin
          var V_tmp: Single;
          V_tmp := Arg_input[(Arg_inputOffset + V_i)];
          Arg_input[(Arg_inputOffset + V_i)] := Arg_input[((Arg_inputOffset + 255) - V_i)];
          Arg_input[((Arg_inputOffset + 255) - V_i)] := V_tmp;
        end;
        Inc(V_i);
      end;
    end;
  end;
  ctx.mdctCtx.imdctCalc(Arg_output, Arg_outputOffset, Arg_input, Arg_inputOffset);
  vectorFmul(Arg_output, Arg_outputOffset, Arg_output, Arg_outputOffset, mdct_window, 0, MDCT_SIZE);
end;

class procedure TAT3Atrac3Decoder.initImdctWindow;
begin
  begin
    var V_i: Integer;
    V_i := 0;
    var V_j: Integer;
    V_j := 255;
    while (V_i < 128) do
    begin
      begin
        var V_wi: Single;
        V_wi := (Single(Sin(((((((V_i + 0.5)) / 256.0) - 0.5)) * Pi))) + 1.0);
        var V_wj: Single;
        V_wj := (Single(Sin(((((((V_j + 0.5)) / 256.0) - 0.5)) * Pi))) + 1.0);
        var V_w: Single;
        V_w := (0.5 * (((V_wi * V_wi) + (V_wj * V_wj))));
        mdct_window[V_i] := (V_wi / V_w);
        mdct_window[V_j] := (V_wj / V_w);
        mdct_window[(511 - V_i)] := (V_wi / V_w);
        mdct_window[(511 - V_j)] := (V_wj / V_w);
      end;
      Inc(V_i);
      Dec(V_j);
    end;
  end;
end;

function TAT3Atrac3Decoder.decodeGainControl(Arg_block: TAT3GainBlock; Arg_numBands: Integer): Integer;
begin
  var V_b: Integer;
  begin
    V_b := 0;
    while (V_b <= Arg_numBands) do
    begin
      begin
        Arg_block.gBlock[V_b].numPoints := br.read(3);
        var V_level: TArray<Integer>;
        V_level := Arg_block.gBlock[V_b].levCode;
        var V_loc: TArray<Integer>;
        V_loc := Arg_block.gBlock[V_b].locCode;
        begin
          var V_j: Integer;
          V_j := 0;
          while (V_j < Arg_block.gBlock[V_b].numPoints) do
          begin
            begin
              V_level[V_j] := br.read(4);
              V_loc[V_j] := br.read(5);
              if (((V_j > 0) and (V_loc[V_j] <= V_loc[(V_j - 1)]))) then
              begin
                Exit(AT3_ERROR);
              end;
            end;
            Inc(V_j);
          end;
        end;
      end;
      Inc(V_b);
    end;
  end;
  begin
    while (V_b < 4) do
    begin
      begin
        Arg_block.gBlock[V_b].numPoints := 0;
      end;
      Inc(V_b);
    end;
  end;
  Exit(0);
end;

function TAT3Atrac3Decoder.decodeTonalComponents(Arg_components: TArray<TAT3TonalComponent>; Arg_numBands: Integer): Integer;
begin
  var V_bandFlags: TArray<Integer>;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 4);
  V_bandFlags := Temporary1;
  var V_mantissa: TArray<Integer>;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 8);
  V_mantissa := Temporary2;
  var V_componentCount: Integer;
  V_componentCount := 0;
  var V_nbComponents: Integer;
  V_nbComponents := br.read(5);
  if ((V_nbComponents = 0)) then
  begin
    Exit(0);
  end;
  var V_codingModeSelector: Integer;
  V_codingModeSelector := br.read(2);
  if ((V_codingModeSelector = 2)) then
  begin
    Exit(AT3_ERROR);
  end;
  var V_codingMode: Integer;
  V_codingMode := (V_codingModeSelector and 1);
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < V_nbComponents) do
    begin
      begin
        begin
          var V_b: Integer;
          V_b := 0;
          while (V_b <= Arg_numBands) do
          begin
            begin
              V_bandFlags[V_b] := br.read1;
            end;
            Inc(V_b);
          end;
        end;
        var V_codedValuesPerComponent: Integer;
        V_codedValuesPerComponent := br.read(3);
        var V_quantStepIndex: Integer;
        V_quantStepIndex := br.read(3);
        if ((V_quantStepIndex <= 1)) then
        begin
          Exit(AT3_ERROR);
        end;
        if ((V_codingModeSelector = 3)) then
        begin
          V_codingMode := br.read1;
        end;
        begin
          var V_b: Integer;
          V_b := 0;
          while (V_b < (((Arg_numBands + 1)) * 4)) do
          begin
            begin
              if ((V_bandFlags[ATSar(V_b, 2)] = 0)) then
              begin
                Inc(V_b);
                Continue;
              end;
              var V_codedComponents: Integer;
              V_codedComponents := br.read(3);
              begin
                var V_c: Integer;
                V_c := 0;
                while (V_c < V_codedComponents) do
                begin
                  begin
                    if ((V_componentCount >= 64)) then
                    begin
                      Exit(AT3_ERROR);
                    end;
                    var V_cmp: TAT3TonalComponent;
                    V_cmp := Arg_components[V_componentCount];
                    var V_sfIndex: Integer;
                    V_sfIndex := br.read(6);
                    V_cmp.pos := ((V_b * 64) + br.read(6));
                    var V_maxCodedValues: Integer;
                    V_maxCodedValues := (SAMPLES_PER_FRAME - V_cmp.pos);
                    var V_codedValues: Integer;
                    V_codedValues := (V_codedValuesPerComponent + 1);
                    V_codedValues := Min(V_maxCodedValues, V_codedValues);
                    var V_scaleFactor: Single;
                    V_scaleFactor := (ff_atrac_sf_table[V_sfIndex] * inv_max_quant[V_quantStepIndex]);
                    readQuantSpectralCoeffs(V_quantStepIndex, V_codingMode, V_mantissa, V_codedValues);
                    V_cmp.numCoefs := V_codedValues;
                    begin
                      var V_m: Integer;
                      V_m := 0;
                      while (V_m < V_codedValues) do
                      begin
                        begin
                          V_cmp.coef[V_m] := (V_mantissa[V_m] * V_scaleFactor);
                        end;
                        Inc(V_m);
                      end;
                    end;
                    Inc(V_componentCount);
                  end;
                  Inc(V_c);
                end;
              end;
            end;
            Inc(V_b);
          end;
        end;
      end;
      Inc(V_i);
    end;
  end;
  Exit(V_componentCount);
end;

procedure TAT3Atrac3Decoder.readQuantSpectralCoeffs(Arg_selector: Integer; Arg_codingFlag: Integer; Arg_mantissas: TArray<Integer>; Arg_numCodes: Integer);
begin
  if ((Arg_selector = 1)) then
  begin
    Arg_numCodes := (Arg_numCodes div 2);
  end;
  if ((Arg_codingFlag <> 0)) then
  begin
    var V_numBits: Integer;
    V_numBits := clc_length_tab[Arg_selector];
    if ((Arg_selector > 1)) then
    begin
      begin
        var V_i: Integer;
        V_i := 0;
        while (V_i < Arg_numCodes) do
        begin
          begin
            var V_code: Integer;
            var Temporary1: Integer;
            if (V_numBits <> 0) then
            begin
              Temporary1 := ATSigned(br.read(V_numBits), V_numBits);
            end
            else
            begin
              Temporary1 := 0;
            end;
            V_code := (Temporary1);
            Arg_mantissas[V_i] := V_code;
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
        while (V_i < Arg_numCodes) do
        begin
          begin
            var V_code: Integer;
            var Temporary2: Integer;
            if (V_numBits <> 0) then
            begin
              Temporary2 := br.read(V_numBits);
            end
            else
            begin
              Temporary2 := 0;
            end;
            V_code := (Temporary2);
            Arg_mantissas[(V_i * 2)] := mantissa_clc_tab[ATSar(V_code, 2)];
            Arg_mantissas[((V_i * 2) + 1)] := mantissa_clc_tab[(V_code and 3)];
          end;
          Inc(V_i);
        end;
      end;
    end;
  end
  else
  begin
    if ((Arg_selector <> 1)) then
    begin
      begin
        var V_i: Integer;
        V_i := 0;
        while (V_i < Arg_numCodes) do
        begin
          begin
            var V_huffSymb: Integer;
            V_huffSymb := spectral_coeff_tab[(Arg_selector - 1)].getVLC2(br, 3);
            V_huffSymb := (V_huffSymb + 1);
            var V_code: Integer;
            V_code := ATSar(V_huffSymb, 1);
            if ((((V_huffSymb and 1)) <> 0)) then
            begin
              V_code := -(V_code);
            end;
            Arg_mantissas[V_i] := V_code;
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
        while (V_i < Arg_numCodes) do
        begin
          begin
            var V_huffSymb: Integer;
            V_huffSymb := spectral_coeff_tab[(Arg_selector - 1)].getVLC2(br, 3);
            Arg_mantissas[(V_i * 2)] := mantissa_vlc_tab[(V_huffSymb * 2)];
            Arg_mantissas[((V_i * 2) + 1)] := mantissa_vlc_tab[((V_huffSymb * 2) + 1)];
          end;
          Inc(V_i);
        end;
      end;
    end;
  end;
end;

function TAT3Atrac3Decoder.decodeSpectrum(Arg_output: TArray<Single>): Integer;
begin
  var V_subbandVlcIndex: TArray<Integer>;
  var Temporary1: TArray<Integer>;
  SetLength(Temporary1, 32);
  V_subbandVlcIndex := Temporary1;
  var V_sfIndex: TArray<Integer>;
  var Temporary2: TArray<Integer>;
  SetLength(Temporary2, 32);
  V_sfIndex := Temporary2;
  var V_mantissas: TArray<Integer>;
  var Temporary3: TArray<Integer>;
  SetLength(Temporary3, 128);
  V_mantissas := Temporary3;
  var V_numSubbands: Integer;
  V_numSubbands := br.read(5);
  var V_codingMode: Integer;
  V_codingMode := br.read(1);
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i <= V_numSubbands) do
    begin
      begin
        V_subbandVlcIndex[V_i] := br.read(3);
      end;
      Inc(V_i);
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i <= V_numSubbands) do
    begin
      begin
        if ((V_subbandVlcIndex[V_i] <> 0)) then
        begin
          V_sfIndex[V_i] := br.read(6);
        end;
      end;
      Inc(V_i);
    end;
  end;
  var V_i: Integer;
  begin
    V_i := 0;
    while (V_i <= V_numSubbands) do
    begin
      begin
        var V_first: Integer;
        V_first := subband_tab[V_i];
        var V_last: Integer;
        V_last := subband_tab[(V_i + 1)];
        var V_subbandSize: Integer;
        V_subbandSize := (V_last - V_first);
        if ((V_subbandVlcIndex[V_i] <> 0)) then
        begin
          readQuantSpectralCoeffs(V_subbandVlcIndex[V_i], V_codingMode, V_mantissas, V_subbandSize);
          var V_scaleFactor: Single;
          V_scaleFactor := (ff_atrac_sf_table[V_sfIndex[V_i]] * inv_max_quant[V_subbandVlcIndex[V_i]]);
          begin
            var V_j: Integer;
            V_j := 0;
            while (V_first < V_last) do
            begin
              begin
                Arg_output[V_first] := (V_mantissas[V_j] * V_scaleFactor);
              end;
              Inc(V_first);
              Inc(V_j);
            end;
          end;
        end
        else
        begin
          ATFill(Arg_output, V_first, (V_first + V_subbandSize), 0.0);
        end;
      end;
      Inc(V_i);
    end;
  end;
  ATFill(Arg_output, subband_tab[V_i], SAMPLES_PER_FRAME, 0.0);
  Exit(V_numSubbands);
end;

function TAT3Atrac3Decoder.addTonalComponents(Arg_spectrum: TArray<Single>; Arg_numComponents: Integer; Arg_components: TArray<TAT3TonalComponent>): Integer;
begin
  var V_lastPos: Integer;
  V_lastPos := -1;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < Arg_numComponents) do
    begin
      begin
        V_lastPos := Max((Arg_components[V_i].pos + Arg_components[V_i].numCoefs), V_lastPos);
        begin
          var V_j: Integer;
          V_j := 0;
          while (V_j < Arg_components[V_i].numCoefs) do
          begin
            begin
              Arg_spectrum[(Arg_components[V_i].pos + V_j)] := (Arg_spectrum[(Arg_components[V_i].pos + V_j)] + Arg_components[V_i].coef[V_j]);
            end;
            Inc(V_j);
          end;
        end;
      end;
      Inc(V_i);
    end;
  end;
  Exit(V_lastPos);
end;

procedure TAT3Atrac3Decoder.reverseMatrixing(Arg_su1: TArray<Single>; Arg_su2: TArray<Single>; Arg_prevCode: TArray<Integer>; Arg_currCode: TArray<Integer>);
begin
  begin
    var V_i: Integer;
    V_i := 0;
    var V_band: Integer;
    V_band := 0;
    while (V_band < (4 * 256)) do
    begin
      begin
        var V_s1: Integer;
        V_s1 := Arg_prevCode[V_i];
        var V_s2: Integer;
        V_s2 := Arg_currCode[V_i];
        var V_nsample: Integer;
        V_nsample := V_band;
        if ((V_s1 <> V_s2)) then
        begin
          var V_mc1l: Single;
          V_mc1l := matrix_coeffs[(V_s1 * 2)];
          var V_mc1r: Single;
          V_mc1r := matrix_coeffs[((V_s1 * 2) + 1)];
          var V_mc2l: Single;
          V_mc2l := matrix_coeffs[(V_s2 * 2)];
          var V_mc2r: Single;
          V_mc2r := matrix_coeffs[((V_s2 * 2) + 1)];
          begin
            while (V_nsample < (V_band + 8)) do
            begin
              begin
                var V_c1: Single;
                V_c1 := Arg_su1[V_nsample];
                var V_c2: Single;
                V_c2 := Arg_su2[V_nsample];
                V_c2 := ((V_c1 * INTERPOLATE(V_mc1l, V_mc2l, (V_nsample - V_band))) + (V_c2 * INTERPOLATE(V_mc1r, V_mc2r, (V_nsample - V_band))));
                Arg_su1[V_nsample] := V_c2;
                Arg_su2[V_nsample] := ((V_c1 * 2.0) - V_c2);
              end;
              Inc(V_nsample);
            end;
          end;
        end;
        case (V_s2) of
          0:
            begin
              begin
                while (V_nsample < (V_band + 256)) do
                begin
                  begin
                    var V_c1: Single;
                    V_c1 := Arg_su1[V_nsample];
                    var V_c2: Single;
                    V_c2 := Arg_su2[V_nsample];
                    Arg_su1[V_nsample] := (V_c2 * 2.0);
                    Arg_su2[V_nsample] := (((V_c1 - V_c2)) * 2.0);
                  end;
                  Inc(V_nsample);
                end;
              end;
            end;
          1:
            begin
              begin
                while (V_nsample < (V_band + 256)) do
                begin
                  begin
                    var V_c1: Single;
                    V_c1 := Arg_su1[V_nsample];
                    var V_c2: Single;
                    V_c2 := Arg_su2[V_nsample];
                    Arg_su1[V_nsample] := (((V_c1 + V_c2)) * 2.0);
                    Arg_su2[V_nsample] := (V_c2 *  - (2.0));
                  end;
                  Inc(V_nsample);
                end;
              end;
            end;
          2, 3:
            begin
              begin
                while (V_nsample < (V_band + 256)) do
                begin
                  begin
                    var V_c1: Single;
                    V_c1 := Arg_su1[V_nsample];
                    var V_c2: Single;
                    V_c2 := Arg_su2[V_nsample];
                    Arg_su1[V_nsample] := (V_c1 + V_c2);
                    Arg_su2[V_nsample] := (V_c1 - V_c2);
                  end;
                  Inc(V_nsample);
                end;
              end;
            end;
        else
          begin
          end;
        end;
      end;
      V_band := (V_band + 256);
      Inc(V_i);
    end;
  end;
end;

procedure TAT3Atrac3Decoder.getChannelWeights(Arg_index: Integer; Arg_flag: Integer; Arg_ch: TArray<Single>);
begin
  if ((Arg_index = 7)) then
  begin
    Arg_ch[0] := 1.0;
    Arg_ch[1] := 1.0;
  end
  else
  begin
    Arg_ch[0] := (((Arg_index and 7)) / 7.0);
    Arg_ch[1] := Single(Sqrt((2.0 - (Arg_ch[0] * Arg_ch[0]))));
    if ((Arg_flag <> 0)) then
    begin
      var V_tmp: Single;
      V_tmp := Arg_ch[0];
      Arg_ch[0] := Arg_ch[1];
      Arg_ch[1] := V_tmp;
    end;
  end;
end;

function TAT3Atrac3Decoder.INTERPOLATE(Arg_oldValue: Single; Arg_newValue: Single; Arg_nsample: Integer): Single;
begin
  Exit((Arg_oldValue + ((Arg_nsample * 0.125) * ((Arg_newValue - Arg_oldValue)))));
end;

procedure TAT3Atrac3Decoder.channelWeighting(Arg_su1: TArray<Single>; Arg_su2: TArray<Single>; Arg_p3: TArray<Integer>);
begin
  var V_w: TArray<TArray<Single>>;
  var Temporary1: TArray<TArray<Single>>;
  SetLength(Temporary1, 2, 2);
  V_w := Temporary1;
  if (((Arg_p3[1] <> 7) or (Arg_p3[3] <> 7))) then
  begin
    getChannelWeights(Arg_p3[1], Arg_p3[0], V_w[0]);
    getChannelWeights(Arg_p3[3], Arg_p3[2], V_w[1]);
    begin
      var V_band: Integer;
      V_band := 256;
      while (V_band < (4 * 256)) do
      begin
        begin
          var V_nsample: Integer;
          begin
            V_nsample := V_band;
            while (V_nsample < (V_band + 8)) do
            begin
              begin
                Arg_su1[V_nsample] := (Arg_su1[V_nsample] * INTERPOLATE(V_w[0][0], V_w[0][1], (V_nsample - V_band)));
                Arg_su2[V_nsample] := (Arg_su2[V_nsample] * INTERPOLATE(V_w[1][0], V_w[1][1], (V_nsample - V_band)));
              end;
              Inc(V_nsample);
            end;
          end;
          begin
            while (V_nsample < (V_band + 256)) do
            begin
              begin
                Arg_su1[V_nsample] := (Arg_su1[V_nsample] * V_w[1][0]);
                Arg_su2[V_nsample] := (Arg_su2[V_nsample] * V_w[1][1]);
              end;
              Inc(V_nsample);
            end;
          end;
        end;
        V_band := (V_band + 256);
      end;
    end;
  end;
end;

function TAT3Atrac3Decoder.decodeChannelSoundUnit(Arg_snd: TAT3ChannelUnit; Arg_output: TArray<Single>; Arg_channelNum: Integer; Arg_codingMode: Integer): Integer;
begin
  var V_ret: Integer;
  var V_gain1: TAT3GainBlock;
  V_gain1 := Arg_snd.gainBlock[Arg_snd.gcBlkSwitch];
  var V_gain2: TAT3GainBlock;
  V_gain2 := Arg_snd.gainBlock[(1 - Arg_snd.gcBlkSwitch)];
  if (((Arg_codingMode = JOINT_STEREO) and (Arg_channelNum = 1))) then
  begin
    if ((br.read(2) <> 3)) then
    begin
      Exit(AT3_ERROR);
    end;
  end
  else
  begin
    if ((br.read(6) <> 40)) then
    begin
      Exit(AT3_ERROR);
    end;
  end;
  Arg_snd.bandsCoded := br.read(2);
  V_ret := decodeGainControl(V_gain2, Arg_snd.bandsCoded);
  if ((V_ret <> 0)) then
  begin
    Exit(V_ret);
  end;
  Arg_snd.numComponents := decodeTonalComponents(Arg_snd.components, Arg_snd.bandsCoded);
  if ((Arg_snd.numComponents < 0)) then
  begin
    Exit(Arg_snd.numComponents);
  end;
  var V_numSubbands: Integer;
  V_numSubbands := decodeSpectrum(Arg_snd.spectrum);
  var V_lastTonal: Integer;
  V_lastTonal := addTonalComponents(Arg_snd.spectrum, Arg_snd.numComponents, Arg_snd.components);
  var V_numBands: Integer;
  V_numBands := ATSar(((subband_tab[V_numSubbands] - 1)), 8);
  if ((V_lastTonal >= 0)) then
  begin
    V_numBands := Max(ATSar(((V_lastTonal + 256)), 8), V_numBands);
  end;
  begin
    var V_band: Integer;
    V_band := 0;
    while (V_band < 4) do
    begin
      begin
        if ((V_band <= V_numBands)) then
        begin
          imlt(Arg_snd.spectrum, (V_band * 256), Arg_snd.imdctBuf, 0, (((V_band and 1)) <> 0));
        end
        else
        begin
          ATFill(Arg_snd.imdctBuf, 0, 512, 0.0);
        end;
        ctx.gaincCtx.gainCompensation(Arg_snd.imdctBuf, 0, Arg_snd.prevFrame, (V_band * 256), V_gain1.gBlock[V_band], V_gain2.gBlock[V_band], 256, Arg_output, (V_band * 256));
      end;
      Inc(V_band);
    end;
  end;
  Arg_snd.gcBlkSwitch := (Arg_snd.gcBlkSwitch xor 1);
  Exit(0);
end;

function TAT3Atrac3Decoder.decodeFrame: Integer;
begin
  var V_ret: Integer;
  if ((ctx.codingMode = JOINT_STEREO)) then
  begin
    V_ret := decodeChannelSoundUnit(ctx.units[0], ctx.samples[0], 0, JOINT_STEREO);
    if ((V_ret <> 0)) then
    begin
      Exit(V_ret);
    end;
    br.seek((ctx.blockAlign - 1));
    br.setDirection(-1);
    while ((br.peek(8) = 248)) do
    begin
      br.read(8);
    end;
    ATCopy(ctx.weightingDelay, 2, ctx.weightingDelay, 0, 4);
    ctx.weightingDelay[4] := br.read1;
    ctx.weightingDelay[5] := br.read(3);
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < 4) do
      begin
        begin
          ctx.matrixCoeffIndexPrev[V_i] := ctx.matrixCoeffIndexNow[V_i];
          ctx.matrixCoeffIndexNow[V_i] := ctx.matrixCoeffIndexNext[V_i];
          ctx.matrixCoeffIndexNext[V_i] := br.read(2);
        end;
        Inc(V_i);
      end;
    end;
    V_ret := decodeChannelSoundUnit(ctx.units[1], ctx.samples[1], 1, JOINT_STEREO);
    br.setDirection(1);
    br.seek(ctx.blockAlign);
    if ((V_ret <> 0)) then
    begin
      Exit(V_ret);
    end;
    reverseMatrixing(ctx.samples[0], ctx.samples[1], ctx.matrixCoeffIndexPrev, ctx.matrixCoeffIndexNow);
    channelWeighting(ctx.samples[0], ctx.samples[1], ctx.weightingDelay);
  end
  else
  begin
    begin
      var V_i: Integer;
      V_i := 0;
      while (V_i < ctx.channels) do
      begin
        begin
          br.seek(((V_i * ctx.blockAlign) div ctx.channels));
          V_ret := decodeChannelSoundUnit(ctx.units[V_i], ctx.samples[V_i], V_i, ctx.codingMode);
          if ((V_ret <> 0)) then
          begin
            Exit(V_ret);
          end;
        end;
        Inc(V_i);
      end;
    end;
  end;
  begin
    var V_i: Integer;
    V_i := 0;
    while (V_i < ctx.channels) do
    begin
      begin
        TATAtrac.iqmf(ctx.samples[V_i], 0, ctx.samples[V_i], 256, 256, ctx.samples[V_i], 0, ctx.units[V_i].delayBuf1, ctx.tempBuf);
        TATAtrac.iqmf(ctx.samples[V_i], 768, ctx.samples[V_i], 512, 256, ctx.samples[V_i], 512, ctx.units[V_i].delayBuf2, ctx.tempBuf);
        TATAtrac.iqmf(ctx.samples[V_i], 0, ctx.samples[V_i], 512, 512, ctx.samples[V_i], 0, ctx.units[V_i].delayBuf3, ctx.tempBuf);
      end;
      Inc(V_i);
    end;
  end;
  Exit(0);
end;

destructor TAT3Atrac3Decoder.Destroy;
begin
  ctx.Free;
  inherited;
end;

initialization
  huffcode1 := TArray<Integer>.Create(0, 4, 5, 12, 13, 28, 29, 30, 31);
  huffbits1 := TArray<Integer>.Create(1, 3, 3, 4, 4, 5, 5, 5, 5);
  huffcode2 := TArray<Integer>.Create(0, 4, 5, 6, 7);
  huffbits2 := TArray<Integer>.Create(1, 3, 3, 3, 3);
  huffcode3 := TArray<Integer>.Create(0, 4, 5, 12, 13, 14, 15);
  huffbits3 := TArray<Integer>.Create(1, 3, 3, 4, 4, 4, 4);
  huffcode4 := TArray<Integer>.Create(0, 4, 5, 12, 13, 28, 29, 30, 31);
  huffbits4 := TArray<Integer>.Create(1, 3, 3, 4, 4, 5, 5, 5, 5);
  huffcode5 := TArray<Integer>.Create(0, 2, 3, 8, 9, 10, 11, 28, 29, 60, 61, 62, 63, 12, 13);
  huffbits5 := TArray<Integer>.Create(2, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 4, 4);
  huffcode6 := TArray<Integer>.Create(0, 2, 3, 4, 5, 6, 7, 20, 21, 22, 23, 24, 25, 52, 53, 54, 55, 56, 57, 58, 59, 120, 121, 122, 123, 124, 125, 126, 127, 8, 9);
  huffbits6 := TArray<Integer>.Create(3, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 4, 4);
  huffcode7 := TArray<Integer>.Create(0, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 2, 3);
  huffbits7 := TArray<Integer>.Create(3, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4, 4);
  huff_tab_sizes := TArray<Integer>.Create(9, 5, 7, 9, 15, 31, 63);
  huff_codes := TArray<TArray<Integer>>.Create(huffcode1, huffcode2, huffcode3, huffcode4, huffcode5, huffcode6, huffcode7);
  huff_bits := TArray<TArray<Integer>>.Create(huffbits1, huffbits2, huffbits3, huffbits4, huffbits5, huffbits6, huffbits7);
  atrac3_vlc_offs := TArray<Integer>.Create(0, 512, 1024, 1536, 2048, 2560, 3072, 3584, 4096);
  clc_length_tab := TArray<Integer>.Create(0, 4, 3, 3, 4, 4, 5, 6);
  mantissa_clc_tab := TArray<Integer>.Create(0, 1, -2, -1);
  mantissa_vlc_tab := TArray<Integer>.Create(0, 0, 0, 1, 0, -1, 1, 0, -1, 0, 1, 1, 1, -1, -1, 1, -1, -1);
  inv_max_quant := TArray<Single>.Create(0.0, (1.0 / 1.5), (1.0 / 2.5), (1.0 / 3.5), (1.0 / 4.5), (1.0 / 7.5), (1.0 / 15.5), (1.0 / 31.5));
  subband_tab := TArray<Integer>.Create(0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 288, 320, 352, 384, 416, 448, 480, 512, 576, 640, 704, 768, 896, 1024);
  matrix_coeffs := TArray<Single>.Create(0.0, 2.0, 2.0, 2.0, 0.0, 0.0, 1.0, 1.0);
  var Temporary1: TArray<Single>;
  SetLength(Temporary1, MDCT_SIZE);
  mdct_window := Temporary1;
  var Temporary2: TArray<TATVLC>;
  SetLength(Temporary2, 7);
  spectral_coeff_tab := Temporary2;
  staticInitDone := False;
  TAT3Atrac3Decoder.initStaticData;

finalization
  for var Item in spectral_coeff_tab do
    Item.Free;

end.

