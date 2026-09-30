unit MD.Sound;

interface

{$Q-}
{$R-}

uses
  System.SysUtils, System.Math, MD.Arithmetic;

type
  TPSGToneState = record
    CountDown: Word;
    CountDownMaster: Word;
    Attenuation: Byte;
    OutputBit: Byte;
  end;

  TPSGNoiseState = record
    CountDown: Word;
    Attenuation: Byte;
    FakeOutputBit: Byte;
    RealOutputBit: Byte;
    FrequencyMode: Byte;
    NoiseType: Byte;
    ShiftRegister: Word;
  end;

  PPSGNoiseState = ^TPSGNoiseState;

  TPSGLatchedCommand = record
    Channel: Byte;
    IsVolumeCommand: Byte;
  end;

  TPSGConfiguration = record
    ToneDisabled: array[0..2] of Byte;
    NoiseDisabled: Byte;
  end;

  TPSGState = record
    Tones: array[0..2] of TPSGToneState;
    Noise: TPSGNoiseState;
    LatchedCommand: TPSGLatchedCommand;
  end;

  TPSG = record
    Configuration: TPSGConfiguration;
    State: TPSGState;
  end;

  TFMPhase = record
    Position: Cardinal;
    Step: Cardinal;
    FNumberAndBlock: Word;
    KeyCode: Word;
    Detune: Word;
    Multiplier: Word;
  end;

  TFMSSGEnvelope = record
    Enabled: Byte;
    Attack: Byte;
    Alternate: Byte;
    Hold: Byte;
    Invert: Byte;
  end;

  TFMOperator = record
    Phase: TFMPhase;
    CountDown: Word;
    CycleCounter: Word;
    DeltaIndex: Word;
    Attenuation: Word;
    TotalLevel: Word;
    SustainLevel: Word;
    KeyScale: Byte;
    Rates: array[0..3] of Word;
    EnvelopeMode: Integer;
    KeyOn: Byte;
    AmplitudeModulationOn: Byte;
    SSGEg: TFMSSGEnvelope;
  end;

  TFMChannel = record
    Operators: array[0..3] of TFMOperator;
    FeedbackDivisor: Byte;
    Algorithm: Word;
    Operator1PreviousSamples: array[0..1] of Word;
    AmplitudeModulationShift: Byte;
    PhaseModulationSensitivity: Byte;
  end;

  TFMLFO = record
    Frequency: Byte;
    AmplitudeModulation: Byte;
    PhaseModulation: Byte;
    SubCounter: Byte;
    Counter: Byte;
    Enabled: Byte;
  end;

  TFMChannelMetadata = record
    State: TFMChannel;
    PanLeft: Byte;
    PanRight: Byte;
  end;

  TFMConfiguration = record
    FMChannelsDisabled: array[0..5] of Byte;
    DacChannelDisabled: Byte;
    LadderEffectDisabled: Byte;
  end;

  TFMTimer = record
    Value: Cardinal;
    Counter: Cardinal;
    Enabled: Byte;
  end;

  TFMChannel3Metadata = record
    Frequencies: array[0..3] of Word;
    PerOperatorFrequenciesEnabled: Byte;
    CsmModeEnabled: Byte;
  end;

  TFMState = record
    Channels: array[0..5] of TFMChannelMetadata;
    Channel3Metadata: TFMChannel3Metadata;
    Port: Byte;
    Address: Byte;
    DacSample: Word;
    DacEnabled: Byte;
    DacTest: Byte;
    RawTimerAValue: Word;
    Timers: array[0..1] of TFMTimer;
    CachedAddress27: Byte;
    CachedUpperFrequencyBits: Byte;
    CachedUpperFrequencyBitsFM3MultiFrequency: Byte;
    LeftoverCycles: Byte;
    Status: Byte;
    BusyFlagCounter: Byte;
    LFO: TFMLFO;
  end;

  TFM = record
    Configuration: TFMConfiguration;
    State: TFMState;
  end;

  PPSG = ^TPSG;

  PFMPhase = ^TFMPhase;

  PFMOperator = ^TFMOperator;

  PFMChannel = ^TFMChannel;

  PFMLFO = ^TFMLFO;

  PFM = ^TFM;

  TFMAudioCallback = procedure(UserData: Pointer; TotalFrames: Cardinal);

  PPSGToneState = ^TPSGToneState;

  PFMChannelMetadata = ^TFMChannelMetadata;

  PFMState = ^TFMState;

  PFMTimer = ^TFMTimer;

const
  PSG_NOISE_TYPE_PERIODIC = ( -1) + 1;
  PSG_NOISE_TYPE_WHITE = ( PSG_NOISE_TYPE_PERIODIC) + 1;
  psg_volumes: array[0..15] of array[0..1] of SmallInt = (($1FFF, (-$1FFF)), ($196A, (-$196A)), ($1430, (-$1430)), ($1009, (-$1009)), ($0CBD, (-$0CBD)), ($0A1E, (-$0A1E)), ($0809, (-$0809)), ($0662, (-$0662)), ($0512, (-$0512)), ($0407, (-$0407)), ($0333, (-$0333)), ($028A, (-$028A)), ($0204, (-$0204)), ($019A, (-$019A)), ($0146, (-$0146)), ($0000, (-$0000)));
  FM_OPERATOR_ENVELOPE_MODE_ATTACK = 0;
  FM_OPERATOR_ENVELOPE_MODE_DECAY = 1;
  FM_OPERATOR_ENVELOPE_MODE_SUSTAIN = 2;
  FM_OPERATOR_ENVELOPE_MODE_RELEASE = 3;
  logarithmiattenuation_sine_table: array[0..255] of Word = ($859, $6C3, $607, $58B, $52E, $4E4, $4A6, $471, $443, $41A, $3F5, $3D3, $3B5, $398, $37E, $365, $34E, $339, $324, $311, $2FF,
    $2ED, $2DC, $2CD, $2BD, $2AF, $2A0, $293, $286, $279, $26D, $261, $256, $24B, $240, $236, $22C, $222, $218, $20F, $206, $1FD, $1F5, $1EC, $1E4, $1DC, $1D4, $1CD, $1C5, $1BE, $1B7,
    $1B0, $1A9, $1A2, $19B, $195, $18F, $188, $182, $17C, $177, $171, $16B, $166, $160, $15B, $155, $150, $14B, $146, $141, $13C, $137, $133, $12E, $129, $125, $121, $11C, $118, $114,
    $10F, $10B, $107, $103, $0FF, $0FB, $0F8, $0F4, $0F0, $0EC, $0E9, $0E5, $0E2, $0DE, $0DB, $0D7, $0D4, $0D1, $0CD, $0CA, $0C7, $0C4, $0C1, $0BE, $0BB, $0B8, $0B5, $0B2, $0AF, $0AC,
    $0A9, $0A7, $0A4, $0A1, $09F, $09C, $099, $097, $094, $092, $08F, $08D, $08A, $088, $086, $083, $081, $07F, $07D, $07A, $078, $076, $074, $072, $070, $06E, $06C, $06A, $068, $066,
    $064, $062, $060, $05E, $05C, $05B, $059, $057, $055, $053, $052, $050, $04E, $04D, $04B, $04A, $048, $046, $045, $043, $042, $040, $03F, $03E, $03C, $03B, $039, $038, $037, $035,
    $034, $033, $031, $030, $02F, $02E, $02D, $02B, $02A, $029, $028, $027, $026, $025, $024, $023, $022, $021, $020, $01F, $01E, $01D, $01C, $01B, $01A, $019, $018, $017, $017, $016,
    $015, $014, $014, $013, $012, $011, $011, $010, $00F, $00F, $00E, $00D, $00D, $00C, $00C, $00B, $00A, $00A, $009, $009, $008, $008, $007, $007, $007, $006, $006, $005, $005, $005,
    $004, $004, $004, $003, $003, $003, $002, $002, $002, $002, $001, $001, $001, $001, $001, $001, $001, $000, $000, $000, $000, $000, $000, $000, $000);
  power_table: array[0..255] of Word = ($7FA, $7F5, $7EF, $7EA, $7E4, $7DF, $7DA, $7D4, $7CF, $7C9, $7C4, $7BF, $7B9, $7B4, $7AE, $7A9, $7A4, $79F, $799, $794, $78F, $78A, $784, $77F, $77A,
    $775, $770, $76A, $765, $760, $75B, $756, $751, $74C, $747, $742, $73D, $738, $733, $72E, $729, $724, $71F, $71A, $715, $710, $70B, $706, $702, $6FD, $6F8, $6F3, $6EE, $6E9, $6E5,
    $6E0, $6DB, $6D6, $6D2, $6CD, $6C8, $6C4, $6BF, $6BA, $6B5, $6B1, $6AC, $6A8, $6A3, $69E, $69A, $695, $691, $68C, $688, $683, $67F, $67A, $676, $671, $66D, $668, $664, $65F, $65B,
    $657, $652, $64E, $649, $645, $641, $63C, $638, $634, $630, $62B, $627, $623, $61E, $61A, $616, $612, $60E, $609, $605, $601, $5FD, $5F9, $5F5, $5F0, $5EC, $5E8, $5E4, $5E0, $5DC,
    $5D8, $5D4, $5D0, $5CC, $5C8, $5C4, $5C0, $5BC, $5B8, $5B4, $5B0, $5AC, $5A8, $5A4, $5A0, $59C, $599, $595, $591, $58D, $589, $585, $581, $57E, $57A, $576, $572, $56F, $56B, $567,
    $563, $560, $55C, $558, $554, $551, $54D, $549, $546, $542, $53E, $53B, $537, $534, $530, $52C, $529, $525, $522, $51E, $51B, $517, $514, $510, $50C, $509, $506, $502, $4FF, $4FB,
    $4F8, $4F4, $4F1, $4ED, $4EA, $4E7, $4E3, $4E0, $4DC, $4D9, $4D6, $4D2, $4CF, $4CC, $4C8, $4C5, $4C2, $4BE, $4BB, $4B8, $4B5, $4B1, $4AE, $4AB, $4A8, $4A4, $4A1, $49E, $49B, $498,
    $494, $491, $48E, $48B, $488, $485, $482, $47E, $47B, $478, $475, $472, $46F, $46C, $469, $466, $463, $460, $45D, $45A, $457, $454, $451, $44E, $44B, $448, $445, $442, $43F, $43C,
    $439, $436, $433, $430, $42D, $42A, $428, $425, $422, $41F, $41C, $419, $416, $414, $411, $40E, $40B, $408, $406, $403, $400);

procedure PSG_Initialise(psg_: PPSG);

procedure PSG_DoCommand(psg_: PPSG; command: Cardinal);

procedure PSG_Update(psg_: PPSG; var sample_buffer: array of SmallInt);

function RecalculatePhaseStep(Phase: PFMPhase; modulation: Cardinal; modulation_sensitivity: Cardinal): Cardinal;

procedure FM_Phase_Initialise(Phase: PFMPhase);

procedure FM_Phase_SetFrequency(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal; FNumberAndBlock: Cardinal);

procedure FM_Phase_SetDetuneAndMultiplier(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal; Detune: Cardinal; Multiplier: Cardinal);

procedure FM_Phase_SetModulationAndSensitivity(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal);

function GetSSGEGCorrectedAttenuation(State: PFMOperator; disable_inversion: Byte): Cardinal;

function CalculateRate(State: PFMOperator): Cardinal;

procedure EnterAttackMode(State: PFMOperator);

function InversePow2(Value: Cardinal): Cardinal;

procedure FM_Operator_Initialise(State: PFMOperator);

procedure FM_Operator_SetKeyOn(State: PFMOperator; KeyOn: Byte);

procedure FM_Operator_SetSSGEG(State: PFMOperator; SSGEg: Cardinal);

procedure FM_Operator_SetTotalLevel(State: PFMOperator; TotalLevel: Cardinal);

procedure FM_Operator_SetKeyScaleAndAttackRate(State: PFMOperator; KeyScale: Cardinal; attack_rate: Cardinal);

procedure FM_Operator_SetSustainLevelAndReleaseRate(State: PFMOperator; SustainLevel: Cardinal; release_rate: Cardinal);

function GetEnvelopeDelta(State: PFMOperator): Cardinal;

procedure UpdateEnvelopeSSGEG(State: PFMOperator);

procedure UpdateEnvelopeADSR(State: PFMOperator);

function GetEnvelopeAttenuation(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;

function UpdateEnvelope(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;

function FM_Operator_Process(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal; PhaseModulation: Cardinal): Cardinal;

function ComputeFeedbackDivisor(Value: Cardinal): Cardinal;

procedure SetAmplitudeModulation(State: PFMChannel; AmplitudeModulation: Cardinal);

procedure FM_Channel_Initialise(State: PFMChannel);

procedure FM_Channel_SetFrequencies(Channel: PFMChannel; modulation: Cardinal; FNumberAndBlock: Cardinal);

procedure FM_Channel_SetFeedbackAndAlgorithm(Channel: PFMChannel; feedback: Cardinal; Algorithm: Cardinal);

procedure FM_Channel_SetPhaseModulationAndSensitivity(Channel: PFMChannel; PhaseModulation: Cardinal; PhaseModulationSensitivity: Cardinal);

procedure FM_Channel_SetModulationSensitivity(Channel: PFMChannel; PhaseModulation: Cardinal; amplitude: Cardinal; Phase: Cardinal);

procedure FM_Channel_SetPhaseModulation(Channel: PFMChannel; PhaseModulation: Cardinal);

function FM_Channel_MixSamples(a: Cardinal; b: Cardinal): Cardinal;

function FM_Channel_GetSample(Channel: PFMChannel; AmplitudeModulation: Cardinal): Cardinal;

procedure FM_LFO_Initialise(State: PFMLFO);

function FM_LFO_SetEnabled(State: PFMLFO; Enabled: Byte): Byte;

function FM_LFO_Advance(State: PFMLFO): Byte;

function FM_ConvertTimerAValue(Value: Cardinal): Cardinal;

function FM_ConvertTimerBValue(Value: Cardinal): Cardinal;

procedure FM_Initialise(fm_: PFM);

procedure FM_DoAddress(fm_: PFM; Port: Cardinal; Address: Cardinal);

procedure FM_DoData(fm_: PFM; data: Cardinal);

function GetFinalSample(fm_: PFM; sample: Integer; Enabled: Byte): Integer;

function FM_ToNativeSigned(Value: Cardinal): Integer;

procedure FM_OutputSamples(fm_: PFM; var sample_buffer: array of SmallInt);

function FM_Update(fm_: PFM; cycles_to_do: Cardinal; fm_audio_to_be_generated: TFMAudioCallback; UserData: Pointer): Cardinal;

implementation

function ArithmeticShiftRight(Value: Integer; Bits: Cardinal): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer((Cardinal(Value) shr Bits) or (Cardinal(-Ord(Value < 0)) shl (32 - Bits)));
end;

procedure PSG_Initialise(psg_: PPSG);
begin
  var i: NativeUInt := 0;
  while (Cardinal(i) < Cardinal(Length(psg_^.State.Tones))) do
  begin
    psg_^.State.Tones[i].CountDown := Word(0);
    psg_^.State.Tones[i].CountDownMaster := Word(0);
    psg_^.State.Tones[i].Attenuation := Byte($F);
    psg_^.State.Tones[i].OutputBit := Byte(0);
    Inc(i);
  end;
  psg_^.State.Noise.CountDown := Word(0);
  psg_^.State.Noise.Attenuation := Byte($F);
  psg_^.State.Noise.FakeOutputBit := Byte(0);
  psg_^.State.Noise.RealOutputBit := Byte(0);
  psg_^.State.Noise.FrequencyMode := Byte(0);
  psg_^.State.Noise.NoiseType := Byte(PSG_NOISE_TYPE_PERIODIC);
  psg_^.State.Noise.ShiftRegister := Word(0);
  psg_^.State.LatchedCommand.Channel := Byte(0);
  psg_^.State.LatchedCommand.IsVolumeCommand := Byte(0);
end;

procedure PSG_DoCommand(psg_: PPSG; command: Cardinal);
var
  tone: PPSGToneState;
  temp25: Integer;
begin
  var latch: Byte := Byte(Ord(Cardinal(Cardinal(command) and Cardinal($80)) <> Cardinal(0)));
  if (latch <> 0) then
  begin
    psg_^.State.LatchedCommand.Channel := Byte(Cardinal(command shr 5) and Cardinal(3));
    psg_^.State.LatchedCommand.IsVolumeCommand := Byte(Ord(Cardinal(Cardinal(command) and Cardinal($10)) <> Cardinal(0)));
  end;
  if (Integer(psg_^.State.LatchedCommand.Channel) < Integer(Length(psg_^.State.Tones))) then
  begin
    tone := @psg_^.State.Tones[psg_^.State.LatchedCommand.Channel];
    if (psg_^.State.LatchedCommand.IsVolumeCommand <> 0) then
    begin
      tone^.Attenuation := Byte(Cardinal(command) and Cardinal($F));
    end
    else
    begin
      if (latch <> 0) then
      begin
        tone^.CountDownMaster := Word(tone^.CountDownMaster and (not $F));
        tone^.CountDownMaster := Word(tone^.CountDownMaster or (Cardinal(command) and Cardinal($F)));
      end
      else
      begin
        tone^.CountDownMaster := Word(tone^.CountDownMaster and $F);
        tone^.CountDownMaster := Word(tone^.CountDownMaster or ((Cardinal(command) and Cardinal($3F)) shl 4));
      end;
    end;
  end
  else
  begin
    if (psg_^.State.LatchedCommand.IsVolumeCommand <> 0) then
    begin
      psg_^.State.Noise.Attenuation := Byte(Cardinal(command) and Cardinal($F));
    end
    else
    begin
      if ((Cardinal(command) and Cardinal(4)) <> 0) then
      begin
        temp25 := PSG_NOISE_TYPE_WHITE;
      end
      else
      begin
        temp25 := PSG_NOISE_TYPE_PERIODIC;
      end;
      psg_^.State.Noise.NoiseType := Byte(temp25);
      psg_^.State.Noise.FrequencyMode := Byte(Cardinal(command) and Cardinal(3));
      psg_^.State.Noise.ShiftRegister := Word(1);
    end;
  end;
end;

procedure PSG_Update(psg_: PPSG; var sample_buffer: array of SmallInt);
begin
  for var ChannelIndex := Low(psg_^.State.Tones) to High(psg_^.State.Tones) do
  begin
    if psg_^.Configuration.ToneDisabled[ChannelIndex] <> 0 then
      Continue;
    var Tone: PPSGToneState := @psg_^.State.Tones[ChannelIndex];
    for var SampleIndex := Low(sample_buffer) to High(sample_buffer) do
    begin
      if Tone^.CountDown <> 0 then
        Dec(Tone^.CountDown);
      if (Tone^.CountDownMaster <> 0) and (Tone^.CountDown = 0) then
      begin
        Tone^.CountDown := Tone^.CountDownMaster;
        Tone^.OutputBit := Ord(Tone^.OutputBit = 0);
      end;
      sample_buffer[SampleIndex] := SmallInt(sample_buffer[SampleIndex] +
          psg_volumes[Tone^.Attenuation][Tone^.OutputBit]);
    end;
  end;

  if psg_^.Configuration.NoiseDisabled <> 0 then
    Exit;
  var Noise: PPSGNoiseState := @psg_^.State.Noise;
  for var SampleIndex := Low(sample_buffer) to High(sample_buffer) do
  begin
    if Noise^.CountDown <> 0 then
      Dec(Noise^.CountDown);
    if Noise^.CountDown = 0 then
    begin
      if Noise^.FrequencyMode = 3 then
        Noise^.CountDown := psg_^.State.Tones[High(psg_^.State.Tones)].CountDownMaster
      else
        Noise^.CountDown := $10 shl Noise^.FrequencyMode;
      Noise^.FakeOutputBit := Ord(Noise^.FakeOutputBit = 0);
      if Noise^.FakeOutputBit <> 0 then
      begin
        Noise^.RealOutputBit := (Noise^.ShiftRegister and $8000) shr 15;
        Noise^.ShiftRegister := Word((Noise^.ShiftRegister shl 1) or Noise^.RealOutputBit);
        if Noise^.NoiseType = PSG_NOISE_TYPE_WHITE then
          Noise^.ShiftRegister := Noise^.ShiftRegister xor ((Noise^.ShiftRegister and $2000) shr 13);
      end;
    end;
    sample_buffer[SampleIndex] := SmallInt(sample_buffer[SampleIndex] +
        psg_volumes[Noise^.Attenuation][Noise^.RealOutputBit]);
  end;
end;

function RecalculatePhaseStep(Phase: PFMPhase; modulation: Cardinal; modulation_sensitivity: Cardinal): Cardinal;
const
  key_codes: array[0..15] of Cardinal = (0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3);
  detune_lookup: array[0..7] of array[0..3] of array[0..3] of Cardinal = (((0, 0, 1, 2), (0, 0, 1, 2), (0, 0, 1, 2), (0, 0, 1, 2)), ((0, 1, 2, 2), (0, 1, 2, 3), (0, 1, 2, 3), (0, 1, 2, 3)), ((0, 1, 2, 4), (0, 1, 3, 4), (0, 1, 3, 4), (0, 1, 3, 5)), ((0, 2, 4, 5), (0, 2, 4, 6), (0, 2, 4, 6), (0, 2, 5, 7)), ((0, 2, 5, 8), (0, 3, 6, 8), (0, 3, 6, 9), (0, 3, 7, 10)), ((0, 4, 8, 11), (0, 4, 8, 12), (0, 4, 9, 13), (0, 5, 10, 14)), ((0, 5, 11, 16), (0, 6, 12, 17), (0, 6, 13, 19), (0, 7, 14, 20)), ((0, 8, 16, 22), (0, 8, 16, 22), (0, 8, 16, 22), (0, 8, 16, 22)));
  lfo_shift_lookup: array[0..7] of array[0..7] of array[0..1] of Byte = (((7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7)), ((7, 7), (7, 7), (7, 7), (7, 7), (7, 2), (7, 2), (7, 2), (7, 2)), ((7, 7), (7, 7), (7, 7), (7, 2), (7, 2), (7, 2), (1, 7), (1, 7)), ((7, 7), (7, 7), (7, 2), (7, 2), (1, 7), (1, 7), (1, 2), (1, 2)), ((7, 7), (7, 7), (7, 2), (1, 7), (1, 7), (1, 7), (1, 2), (0, 7)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)));
var
  Detune: Cardinal;
  temp39: Integer;
begin
  var block: Cardinal := Cardinal(ArithmeticShiftRight(Integer(Phase^.FNumberAndBlock), 11) and 7);
  var f_number: Cardinal := Phase^.FNumberAndBlock and $7FF;
  Detune := Cardinal(detune_lookup[block][key_codes[(f_number shr 7)]][(Phase^.Detune mod Length(detune_lookup[0][0]))]);
  var phase_modulation_is_negative_lobe: Byte := Byte(Ord(Cardinal(Cardinal(modulation) and Cardinal($10)) <> Cardinal(0)));
  var phase_modulation_is_mirrored_size_of_lobe: Byte := Byte(Ord(Cardinal(Cardinal(modulation) and Cardinal(8)) <> Cardinal(0)));
  if (phase_modulation_is_mirrored_size_of_lobe <> 0) then
  begin
    temp39 := 7;
  end
  else
  begin
    temp39 := 0;
  end;
  var phase_modulation_absolute_quadrant: Cardinal := Cardinal(Cardinal(Cardinal(modulation) and Cardinal(7)) xor Cardinal(temp39));
  var f_number_upper_nybbles: Cardinal := f_number shr 4;
  var Shifts := lfo_shift_lookup[modulation_sensitivity][phase_modulation_absolute_quadrant];
  var Step: Cardinal := Cardinal(Add32(f_number_upper_nybbles shr Shifts[0], f_number_upper_nybbles shr Shifts[1]));
  if (Cardinal(modulation_sensitivity) > Cardinal(5)) then
  begin
    Step := Cardinal(Step shl (Sub32(modulation_sensitivity, 5)));
  end;
  Step := Cardinal(Step shr 2);
  if (phase_modulation_is_negative_lobe <> 0) then
  begin
    Step := Cardinal(-Step);
  end;
  Step := Cardinal(Add32(Step, f_number shl 1));
  Step := Cardinal(Cardinal(Step) and Cardinal($FFF));
  Step := Cardinal(Step shl block);
  Step := Cardinal(Step shr 1);
  Step := Cardinal(Step shr 1);
  if (Integer(Phase^.Detune and 4) <> Integer(0)) then
  begin
    Step := Cardinal(Sub32(Step, Detune));
  end
  else
  begin
    Step := Cardinal(Add32(Step, Detune));
  end;
  Step := Cardinal(Cardinal(Step) and Cardinal($1FFFF));
  Step := Cardinal(Mul32(Step, Phase^.Multiplier));
  Step := Cardinal(Cardinal(Step) div Cardinal(2));
  Exit(Cardinal(Step));
end;

procedure FM_Phase_Initialise(Phase: PFMPhase);
begin
  FM_Phase_SetFrequency(Phase, 0, 0, 0);
  FM_Phase_SetDetuneAndMultiplier(Phase, 0, 0, 0, 0);
  Phase^.Position := Cardinal(0);
end;

procedure FM_Phase_SetFrequency(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal; FNumberAndBlock: Cardinal);
begin
  Phase^.FNumberAndBlock := Word(FNumberAndBlock);
  Phase^.KeyCode := Word(FNumberAndBlock shr 9);
  Phase^.Step := Cardinal(RecalculatePhaseStep(Phase, modulation, sensitivity));
end;

procedure FM_Phase_SetDetuneAndMultiplier(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal; Detune: Cardinal; Multiplier: Cardinal);
var
  temp44: Integer;
begin
  Phase^.Detune := Word(Detune);
  if (Cardinal(Multiplier) = Cardinal(0)) then
  begin
    temp44 := 1;
  end
  else
  begin
    temp44 := (Mul32(Multiplier, 2));
  end;
  Phase^.Multiplier := Word(temp44);
  Phase^.Step := Cardinal(RecalculatePhaseStep(Phase, modulation, sensitivity));
end;

procedure FM_Phase_SetModulationAndSensitivity(Phase: PFMPhase; modulation: Cardinal; sensitivity: Cardinal);
begin
  Phase^.Step := Cardinal(RecalculatePhaseStep(Phase, modulation, sensitivity));
end;

function GetSSGEGCorrectedAttenuation(State: PFMOperator; disable_inversion: Byte): Cardinal;
begin
  var temp46: Integer := Ord(not (disable_inversion <> 0));
  if temp46 <> 0 then
  begin
    temp46 := Ord(State^.SSGEg.Enabled <> 0);
  end;
  var temp45: Integer := Ord(temp46 <> 0);
  if temp45 <> 0 then
  begin
    temp45 := Ord(Integer(State^.SSGEg.Invert) <> Integer(State^.SSGEg.Attack));
  end;
  if (temp45 <> 0) then
  begin
    Exit(Cardinal(($200 - State^.Attenuation) and $3FF));
  end
  else
  begin
    Exit(Cardinal(State^.Attenuation));
  end;
end;

function CalculateRate(State: PFMOperator): Cardinal;
var
  temp47: Integer;
begin
  if (Integer(State^.Rates[State^.EnvelopeMode]) = Integer(0)) then
  begin
    Exit(Cardinal(0));
  end;
  if (Integer($3F) < Integer((State^.Rates[State^.EnvelopeMode] * 2) + ArithmeticShiftRight(Integer(State^.Phase.KeyCode), State^.KeyScale))) then
  begin
    temp47 := $3F;
  end
  else
  begin
    temp47 := ((State^.Rates[State^.EnvelopeMode] * 2) + ArithmeticShiftRight(Integer(State^.Phase.KeyCode), State^.KeyScale));
  end;
  Exit(Cardinal(temp47));
end;

procedure EnterAttackMode(State: PFMOperator);
begin
  if (State^.KeyOn <> 0) then
  begin
    State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_ATTACK;
    if (Cardinal(CalculateRate(State)) >= Cardinal($1F * 2)) then
    begin
      State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_DECAY;
      State^.Attenuation := Word(0);
    end;
  end;
end;

function InversePow2(Value: Cardinal): Cardinal;
begin
  var whole: Cardinal := Value shr 8;
  var fraction: Cardinal := Cardinal(Cardinal(Value) and Cardinal($FF));
  Exit(Cardinal(ArithmeticShiftRight(Integer(power_table[fraction] shl 2), whole)));
end;

procedure FM_Operator_Initialise(State: PFMOperator);
begin
  FM_Phase_Initialise(@State^.Phase);
  State^.CountDown := Word(1);
  State^.CycleCounter := Word(0);
  State^.DeltaIndex := Word(0);
  State^.Attenuation := Word($3FF);
  FM_Operator_SetSSGEG(State, 0);
  FM_Operator_SetTotalLevel(State, $7F);
  FM_Operator_SetKeyScaleAndAttackRate(State, 0, 0);
  State^.Rates[FM_OPERATOR_ENVELOPE_MODE_DECAY] := Word(0);
  State^.Rates[FM_OPERATOR_ENVELOPE_MODE_SUSTAIN] := Word(0);
  FM_Operator_SetSustainLevelAndReleaseRate(State, 0, 0);
  State^.AmplitudeModulationOn := Byte(0);
  State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
  State^.KeyOn := Byte(0);
end;

procedure FM_Operator_SetKeyOn(State: PFMOperator; KeyOn: Byte);
begin
  if (Integer(State^.KeyOn) <> Integer(KeyOn)) then
  begin
    State^.KeyOn := Byte(KeyOn);
    if (KeyOn <> 0) then
    begin
      EnterAttackMode(State);
      State^.Phase.Position := Cardinal(0);
    end
    else
    begin
      State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
      State^.Attenuation := Word(GetSSGEGCorrectedAttenuation(State, 0));
      State^.SSGEg.Invert := Byte(0);
    end;
  end;
end;

procedure FM_Operator_SetSSGEG(State: PFMOperator; SSGEg: Cardinal);
begin
  State^.SSGEg.Enabled := Byte(Ord(Cardinal(Cardinal(SSGEg) and Cardinal(1 shl 3)) <> Cardinal(0)));
  var temp48: Integer := Ord(Cardinal(Cardinal(SSGEg) and Cardinal(1 shl 2)) <> Cardinal(0));
  if temp48 <> 0 then
  begin
    temp48 := Ord(State^.SSGEg.Enabled <> 0);
  end;
  State^.SSGEg.Attack := Byte(temp48);
  var temp49: Integer := Ord(Cardinal(Cardinal(SSGEg) and Cardinal(1 shl 1)) <> Cardinal(0));
  if temp49 <> 0 then
  begin
    temp49 := Ord(State^.SSGEg.Enabled <> 0);
  end;
  State^.SSGEg.Alternate := Byte(temp49);
  var temp50: Integer := Ord(Cardinal(Cardinal(SSGEg) and Cardinal(1 shl 0)) <> Cardinal(0));
  if temp50 <> 0 then
  begin
    temp50 := Ord(State^.SSGEg.Enabled <> 0);
  end;
  State^.SSGEg.Hold := Byte(temp50);
end;

procedure FM_Operator_SetTotalLevel(State: PFMOperator; TotalLevel: Cardinal);
begin
  State^.TotalLevel := Word(TotalLevel shl 3);
end;

procedure FM_Operator_SetKeyScaleAndAttackRate(State: PFMOperator; KeyScale: Cardinal; attack_rate: Cardinal);
begin
  State^.KeyScale := Byte(Sub32(3, KeyScale));
  State^.Rates[FM_OPERATOR_ENVELOPE_MODE_ATTACK] := Word(attack_rate);
end;

procedure FM_Operator_SetSustainLevelAndReleaseRate(State: PFMOperator; SustainLevel: Cardinal; release_rate: Cardinal);
var
  temp51: Integer;
begin
  if (Cardinal(SustainLevel) = Cardinal($F)) then
  begin
    temp51 := $3E0;
  end
  else
  begin
    temp51 := (Mul32(SustainLevel, $20));
  end;
  State^.SustainLevel := Word(temp51);
  State^.Rates[FM_OPERATOR_ENVELOPE_MODE_RELEASE] := Word(Cardinal(release_rate shl 1) or Cardinal(1));
end;

function GetEnvelopeDelta(State: PFMOperator): Cardinal;
const
  deltas: array[0..63] of array[0..7] of Cardinal = ((0, 0, 0, 0, 0, 0, 0, 0), (0, 0, 0, 0, 0, 0, 0, 0), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0,
    1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1,
    0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1,
    1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1,
    0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0,
    1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1,
    0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0,
    1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 2, 1, 1, 1, 2), (1, 2, 1, 2, 1, 2, 1, 2), (1, 2, 2, 2, 1, 2, 2, 2), (2, 2, 2, 2, 2, 2, 2, 2), (2, 2, 2, 3, 2, 2, 2, 3),
    (2, 3, 2, 3, 2, 3, 2, 3), (2, 3, 3, 3, 2, 3, 3, 3), (3, 3, 3, 3, 3, 3, 3, 3), (3, 3, 3, 4, 3, 3, 3, 4), (3, 4, 3, 4, 3, 4, 3, 4), (3, 4, 4, 4, 3, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4,
    4), (4, 4, 4, 4, 4, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4, 4));
var
  rate: Cardinal;
  temp52: Word;
  temp53: Integer;
  temp56: Word;
begin
  Dec(State^.CountDown);
  if (Integer(State^.CountDown) = Integer(0)) then
  begin
    rate := Cardinal(CalculateRate(State));
    State^.CountDown := Word(3);
    temp52 := State^.CycleCounter;
    State^.CycleCounter := (State^.CycleCounter + 1) and $FFFF;
    if (Cardinal(11) > Cardinal(Cardinal(rate) div Cardinal(4))) then
    begin
      temp53 := 11;
    end
    else
    begin
      temp53 := (Cardinal(rate) div Cardinal(4));
    end;
    if (Integer(temp52 and ((1 shl (Sub32(temp53, Cardinal(rate) div Cardinal(4)))) - 1)) = Integer(0)) then
    begin
      temp56 := State^.DeltaIndex;
      State^.DeltaIndex := (State^.DeltaIndex + 1) and $FFFF;
      Exit(Cardinal(deltas[rate][(temp56 mod Length(deltas[rate]))]));
    end;
  end;
  Exit(Cardinal(0));
end;

procedure UpdateEnvelopeSSGEG(State: PFMOperator);
var
  temp58: Integer;
begin
  var temp57: Integer := Ord(State^.SSGEg.Enabled <> 0);
  if temp57 <> 0 then
  begin
    temp57 := Ord(Integer(State^.Attenuation) >= Integer($200));
  end;
  if (temp57 <> 0) then
  begin
    if (State^.SSGEg.Alternate <> 0) then
    begin
      if (State^.SSGEg.Hold <> 0) then
      begin
        temp58 := 1;
      end
      else
      begin
        temp58 := Ord(not (State^.SSGEg.Invert <> 0));
      end;
      State^.SSGEg.Invert := Byte(temp58);
    end
    else
    begin
      if (not (State^.SSGEg.Hold <> 0)) then
      begin
        State^.Phase.Position := Cardinal(0);
      end;
    end;
    if (not (State^.SSGEg.Hold <> 0)) then
    begin
      EnterAttackMode(State);
    end;
  end;
end;

procedure UpdateEnvelopeADSR(State: PFMOperator);
var
  temp59: Integer;
  temp65: Integer;
  temp66: Integer;
  temp67: Integer;
  temp68: Integer;
  temp69: Integer;
begin
  var delta: Cardinal := Cardinal(GetEnvelopeDelta(State));
  if (State^.SSGEg.Enabled <> 0) then
  begin
    temp59 := $200;
  end
  else
  begin
    temp59 := $3F0;
  end;
  var end_envelope: Byte := Byte(Ord(Integer(State^.Attenuation) >= Integer(temp59)));
  case State^.EnvelopeMode of
    FM_OPERATOR_ENVELOPE_MODE_ATTACK:
      begin
        repeat
          if (Integer(State^.Attenuation) = Integer(0)) then
          begin
            State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_DECAY;
            Break;
          end;
          if (Cardinal(delta) <> Cardinal(0)) then
          begin
            State^.Attenuation := Word(State^.Attenuation + (((not Cardinal(State^.Attenuation)) shl (Sub32(delta, 1))) shr 4));
            Assert(Integer(State^.Attenuation) <= Integer($3FF));
          end;
        until True;
      end;
    FM_OPERATOR_ENVELOPE_MODE_DECAY:
      begin
        repeat
          if (Integer(State^.Attenuation) >= Integer(State^.SustainLevel)) then
          begin
            State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_SUSTAIN;
            Break;
          end;
          temp65 := Ord(Cardinal(delta) <> Cardinal(0));
          if temp65 <> 0 then
          begin
            temp65 := Ord(not (end_envelope <> 0));
          end;
          if (temp65 <> 0) then
          begin
            if (State^.SSGEg.Enabled <> 0) then
            begin
              temp66 := 2;
            end
            else
            begin
              temp66 := 0;
            end;
            State^.Attenuation := Word(State^.Attenuation + (1 shl (Add32(Sub32(delta, 1), temp66))));
            Assert(Integer(State^.Attenuation) <= Integer($3FF));
          end;
          temp67 := Ord(end_envelope <> 0);
          if temp67 <> 0 then
          begin
            temp69 := Ord(State^.KeyOn <> 0);
            if temp69 <> 0 then
            begin
              temp69 := Ord(State^.SSGEg.Hold <> 0);
            end;
            temp68 := Ord(temp69 <> 0);
            if temp68 <> 0 then
            begin
              temp68 := Ord(Integer(State^.SSGEg.Alternate) <> Integer(State^.SSGEg.Attack));
            end;
            temp67 := Ord(not (temp68 <> 0));
          end;
          if (temp67 <> 0) then
          begin
            State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
            State^.Attenuation := Word($3FF);
          end;
        until True;
      end;
    FM_OPERATOR_ENVELOPE_MODE_SUSTAIN, FM_OPERATOR_ENVELOPE_MODE_RELEASE:
      begin
        temp65 := Ord(Cardinal(delta) <> Cardinal(0));
        if temp65 <> 0 then
        begin
          temp65 := Ord(not (end_envelope <> 0));
        end;
        if (temp65 <> 0) then
        begin
          if (State^.SSGEg.Enabled <> 0) then
          begin
            temp66 := 2;
          end
          else
          begin
            temp66 := 0;
          end;
          State^.Attenuation := Word(State^.Attenuation + (1 shl (Add32(Sub32(delta, 1), temp66))));
          Assert(Integer(State^.Attenuation) <= Integer($3FF));
        end;
        temp67 := Ord(end_envelope <> 0);
        if temp67 <> 0 then
        begin
          temp69 := Ord(State^.KeyOn <> 0);
          if temp69 <> 0 then
          begin
            temp69 := Ord(State^.SSGEg.Hold <> 0);
          end;
          temp68 := Ord(temp69 <> 0);
          if temp68 <> 0 then
          begin
            temp68 := Ord(Integer(State^.SSGEg.Alternate) <> Integer(State^.SSGEg.Attack));
          end;
          temp67 := Ord(not (temp68 <> 0));
        end;
        if (temp67 <> 0) then
        begin
          State^.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
          State^.Attenuation := Word($3FF);
        end;
      end;
  end;
end;

function GetEnvelopeAttenuation(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;
var
  temp70: Cardinal;
  temp71: Integer;
begin
  if (State^.AmplitudeModulationOn <> 0) then
  begin
    temp70 := (AmplitudeModulation shr AmplitudeModulationShift);
  end
  else
  begin
    temp70 := 0;
  end;
  var final_amplitude_modulation: Cardinal := temp70;
  var Attenuation: Cardinal := Cardinal(Add32(Add32(GetSSGEGCorrectedAttenuation(State, Ord(not (State^.KeyOn <> 0))), final_amplitude_modulation), State^.TotalLevel));
  if (Cardinal($3FF) < Cardinal(Attenuation)) then
  begin
    temp71 := $3FF;
  end
  else
  begin
    temp71 := Attenuation;
  end;
  Exit(Cardinal(temp71));
end;

function UpdateEnvelope(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;
begin
  UpdateEnvelopeSSGEG(State);
  UpdateEnvelopeADSR(State);
  Exit(Cardinal(GetEnvelopeAttenuation(State, AmplitudeModulation, AmplitudeModulationShift)));
end;

function FM_Operator_Process(State: PFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal; PhaseModulation: Cardinal): Cardinal;
var
  Phase: Cardinal;
  temp72: Integer;
  temp73: Cardinal;
begin
  State^.Phase.Position := Cardinal(Add32(State^.Phase.Position, State^.Phase.Step));
  Phase := Cardinal(State^.Phase.Position shr 10);
  var Attenuation: Cardinal := Cardinal(UpdateEnvelope(State, AmplitudeModulation, AmplitudeModulationShift));
  var modulated_phase: Cardinal := Cardinal(Cardinal(Add32(Phase, Cardinal(PhaseModulation) div Cardinal(2))) and Cardinal($3FF));
  var phase_is_in_negative_wave: Byte := Byte(Ord(Cardinal(Cardinal(modulated_phase) and Cardinal($200)) <> Cardinal(0)));
  var phase_is_in_mirrored_half_of_wave: Byte := Byte(Ord(Cardinal(Cardinal(modulated_phase) and Cardinal($100)) <> Cardinal(0)));
  if (phase_is_in_mirrored_half_of_wave <> 0) then
  begin
    temp72 := $FF;
  end
  else
  begin
    temp72 := 0;
  end;
  var quarter_phase: Cardinal := Cardinal(Cardinal(Cardinal(modulated_phase) and Cardinal($FF)) xor Cardinal(temp72));
  var phase_as_attenuation: Cardinal := logarithmiattenuation_sine_table[quarter_phase];
  var combined_attenuation: Cardinal := Cardinal(Add32(phase_as_attenuation, Attenuation shl 2));
  var sample_absolute: Cardinal := Cardinal(InversePow2(combined_attenuation));
  if (phase_is_in_negative_wave <> 0) then
  begin
    temp73 := (Sub32(0, sample_absolute));
  end
  else
  begin
    temp73 := sample_absolute;
  end;
  var sample: Cardinal := temp73;
  Exit(Cardinal(sample));
end;

function ComputeFeedbackDivisor(Value: Cardinal): Cardinal;
begin
  Assert(Cardinal(Value) <= Cardinal(9));
  Exit(Cardinal(Sub32(9, Value)));
end;

procedure SetAmplitudeModulation(State: PFMChannel; AmplitudeModulation: Cardinal);
begin
  State^.AmplitudeModulationShift := Byte(ArithmeticShiftRight(Integer(7), AmplitudeModulation));
end;

procedure FM_Channel_Initialise(State: PFMChannel);
begin
  var i: Cardinal := 0;
  while (Cardinal(i) < Cardinal(Length(State^.Operators))) do
  begin
    FM_Operator_Initialise(@State^.Operators[i]);
    Inc(i);
  end;
  State^.FeedbackDivisor := Byte(ComputeFeedbackDivisor(0));
  State^.Algorithm := Word(0);
  i := Cardinal(0);
  while (Cardinal(i) < Cardinal(Length(State^.Operator1PreviousSamples))) do
  begin
    State^.Operator1PreviousSamples[i] := Word(0);
    Inc(i);
  end;
  SetAmplitudeModulation(State, 0);
  State^.PhaseModulationSensitivity := Byte(0);
end;

procedure FM_Channel_SetFrequencies(Channel: PFMChannel; modulation: Cardinal; FNumberAndBlock: Cardinal);
begin
  var i: Cardinal := 0;
  while (Cardinal(i) < Cardinal(Length(Channel^.Operators))) do
  begin
    FM_Phase_SetFrequency(@Channel^.Operators[i].Phase, modulation, Channel^.PhaseModulationSensitivity, FNumberAndBlock);
    Inc(i);
  end;
end;

procedure FM_Channel_SetFeedbackAndAlgorithm(Channel: PFMChannel; feedback: Cardinal; Algorithm: Cardinal);
begin
  Channel^.FeedbackDivisor := Byte(ComputeFeedbackDivisor(feedback));
  Channel^.Algorithm := Word(Algorithm);
end;

procedure FM_Channel_SetPhaseModulationAndSensitivity(Channel: PFMChannel; PhaseModulation: Cardinal; PhaseModulationSensitivity: Cardinal);
begin
  var i: Cardinal := 0;
  while (Cardinal(i) < Cardinal(Length(Channel^.Operators))) do
  begin
    FM_Phase_SetModulationAndSensitivity(@Channel^.Operators[i].Phase, PhaseModulation, PhaseModulationSensitivity);
    Inc(i);
  end;
end;

procedure FM_Channel_SetModulationSensitivity(Channel: PFMChannel; PhaseModulation: Cardinal; amplitude: Cardinal; Phase: Cardinal);
begin
  SetAmplitudeModulation(Channel, amplitude);
  Channel^.PhaseModulationSensitivity := Byte(Phase);
  FM_Channel_SetPhaseModulationAndSensitivity(Channel, PhaseModulation, Phase);
end;

procedure FM_Channel_SetPhaseModulation(Channel: PFMChannel; PhaseModulation: Cardinal);
begin
  FM_Channel_SetPhaseModulationAndSensitivity(Channel, PhaseModulation, Channel^.PhaseModulationSensitivity);
end;

function FM_Channel_MixSamples(a: Cardinal; b: Cardinal): Cardinal;
begin
  var sum: Cardinal := Cardinal(Add32(a, b));
  if ((Cardinal(Cardinal(Cardinal(a) and Cardinal(b)) and Cardinal(not sum)) and Cardinal($100)) <> 0) then
  begin
    Exit(Cardinal(0 - $100));
  end;
  if ((Cardinal(Cardinal(Cardinal(not a) and Cardinal(not b)) and Cardinal(sum)) and Cardinal($100)) <> 0) then
  begin
    Exit(Cardinal($FF));
  end;
  Exit(Cardinal(sum));
end;

function FM_Channel_GetSample(Channel: PFMChannel; AmplitudeModulation: Cardinal): Cardinal;
var
  AmplitudeModulationShift: Cardinal;
  feedback_modulation: Cardinal;
  operator_1_sample: Cardinal;
  operator_2_sample: Cardinal;
  operator_3_sample: Cardinal;
  operator_4_sample: Cardinal;
  sample: Cardinal;
begin
  AmplitudeModulationShift := Cardinal(Channel^.AmplitudeModulationShift);
  var operator1: PFMOperator := @Channel^.Operators[0];
  var operator2: PFMOperator := @Channel^.Operators[1];
  var operator3: PFMOperator := @Channel^.Operators[2];
  var operator4: PFMOperator := @Channel^.Operators[3];
  if (Cardinal(Channel^.FeedbackDivisor) = Cardinal(ComputeFeedbackDivisor(0))) then
  begin
    feedback_modulation := Cardinal(0);
  end
  else
  begin
    feedback_modulation := Cardinal(ArithmeticShiftRight(Integer(Add32(Channel^.Operator1PreviousSamples[0], Channel^.Operator1PreviousSamples[1])), Channel^.FeedbackDivisor));
    feedback_modulation := Cardinal(Sub32(Cardinal(feedback_modulation) and Cardinal(Sub32(Cardinal(1) shl (15 - Channel^.FeedbackDivisor), 1)), Cardinal(feedback_modulation) and Cardinal(Cardinal(1) shl (15 - Channel^.FeedbackDivisor))));
  end;
  case Channel^.Algorithm of
    0:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, operator_2_sample));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, operator_3_sample));
        sample := Cardinal(operator_4_sample shr (14 - 9));
      end;
    1:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, (Add32(operator_1_sample, operator_2_sample))));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, operator_3_sample));
        sample := Cardinal(operator_4_sample shr (14 - 9));
      end;
    2:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, operator_2_sample));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, (Add32(operator_1_sample, operator_3_sample))));
        sample := Cardinal(operator_4_sample shr (14 - 9));
      end;
    3:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, (Add32(operator_2_sample, operator_3_sample))));
        sample := Cardinal(operator_4_sample shr (14 - 9));
      end;
    4:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, operator_3_sample));
        sample := Cardinal(operator_2_sample shr (14 - 9));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_4_sample shr (14 - 9))));
      end;
    5:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        sample := Cardinal(operator_2_sample shr (14 - 9));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_3_sample shr (14 - 9))));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_4_sample shr (14 - 9))));
      end;
    6:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, 0));
        sample := Cardinal(operator_2_sample shr (14 - 9));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_3_sample shr (14 - 9))));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_4_sample shr (14 - 9))));
      end;
    7:
      begin
        operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
        operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, 0));
        operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, 0));
        sample := Cardinal(operator_1_sample shr (14 - 9));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_2_sample shr (14 - 9))));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_3_sample shr (14 - 9))));
        sample := Cardinal(FM_Channel_MixSamples(sample, (operator_4_sample shr (14 - 9))));
      end;
  else
    begin
      Assert(0 <> 0);
      operator_1_sample := Cardinal(FM_Operator_Process(operator1, AmplitudeModulation, AmplitudeModulationShift, feedback_modulation));
      operator_2_sample := Cardinal(FM_Operator_Process(operator2, AmplitudeModulation, AmplitudeModulationShift, operator_1_sample));
      operator_3_sample := Cardinal(FM_Operator_Process(operator3, AmplitudeModulation, AmplitudeModulationShift, operator_2_sample));
      operator_4_sample := Cardinal(FM_Operator_Process(operator4, AmplitudeModulation, AmplitudeModulationShift, operator_3_sample));
      sample := Cardinal(operator_4_sample shr (14 - 9));
    end;
  end;
  Channel^.Operator1PreviousSamples[1] := Word(Channel^.Operator1PreviousSamples[0]);
  Channel^.Operator1PreviousSamples[0] := Word(operator_1_sample);
  Exit(Cardinal(sample));
end;

procedure FM_LFO_Initialise(State: PFMLFO);
begin
  State^.Frequency := Byte(0);
  State^.PhaseModulation := Byte(0);
  State^.AmplitudeModulation := Byte(State^.PhaseModulation);
  State^.Counter := Byte(0);
  State^.SubCounter := Byte(State^.Counter);
  State^.Enabled := Byte(0);
end;

function FM_LFO_SetEnabled(State: PFMLFO; Enabled: Byte): Byte;
begin
  if (Integer(State^.Enabled) <> Integer(Enabled)) then
  begin
    State^.Enabled := Byte(Enabled);
    if (not (Enabled <> 0)) then
    begin
      State^.AmplitudeModulation := Byte(0);
      State^.PhaseModulation := Byte(State^.AmplitudeModulation);
      State^.Counter := Byte(State^.PhaseModulation);
      Exit(Byte(1));
    end;
  end;
  Exit(Byte(0));
end;

function FM_LFO_Advance(State: PFMLFO): Byte;
const
  thresholds: array[0..7] of Byte = ($6C, $4D, $47, $43, $3E, $2C, $08, $05);
var
  phase_modulation_divisor: Cardinal;
begin
  var threshold: Byte := thresholds[State^.Frequency];
  var temp93: Byte := State^.SubCounter;
  Inc(State^.SubCounter);
  if (Integer(temp93 and threshold) = Integer(threshold)) then
  begin
    State^.SubCounter := Byte(0);
    if (State^.Enabled <> 0) then
    begin
      phase_modulation_divisor := Cardinal(4);
      Inc(State^.Counter);
      State^.Counter := Byte(State^.Counter mod $80);
      State^.PhaseModulation := Byte(Cardinal(State^.Counter) div Cardinal(phase_modulation_divisor));
      State^.AmplitudeModulation := Byte(State^.Counter * 2);
      if (Integer(State^.AmplitudeModulation) >= Integer($80)) then
      begin
        State^.AmplitudeModulation := Byte(State^.AmplitudeModulation and $7E);
      end
      else
      begin
        State^.AmplitudeModulation := Byte(State^.AmplitudeModulation xor $7E);
      end;
      Exit(Byte(Ord(Cardinal(Cardinal(State^.Counter) mod Cardinal(phase_modulation_divisor)) = Cardinal(0))));
    end;
  end;
  Exit(Byte(0));
end;

function FM_ConvertTimerAValue(Value: Cardinal): Cardinal;
begin
  Exit(Cardinal(Sub32($400, Value)));
end;

function FM_ConvertTimerBValue(Value: Cardinal): Cardinal;
begin
  Exit(Cardinal(Mul32($10, Sub32($100, Value))));
end;

procedure FM_Initialise(fm_: PFM);
begin
  for var ChannelIndex := Low(fm_^.State.Channels) to High(fm_^.State.Channels) do
  begin
    var Channel: PFMChannelMetadata := @fm_^.State.Channels[ChannelIndex];
    FM_Channel_Initialise(@Channel^.State);
    Channel^.PanLeft := Byte(1);
    Channel^.PanRight := Byte(1);
  end;
  var i: Cardinal := 0;
  while (Cardinal(i) < Cardinal(Length(fm_^.State.Channel3Metadata.Frequencies))) do
  begin
    fm_^.State.Channel3Metadata.Frequencies[i] := Word(0);
    Inc(i);
  end;
  fm_^.State.Channel3Metadata.PerOperatorFrequenciesEnabled := Byte(0);
  fm_^.State.Channel3Metadata.CsmModeEnabled := Byte(0);
  fm_^.State.Port := Byte(0 * 3);
  fm_^.State.Address := Byte(0);
  fm_^.State.DacSample := Word($100);
  fm_^.State.DacEnabled := Byte(0);
  fm_^.State.DacTest := Byte(0);
  fm_^.State.RawTimerAValue := Word(0);
  fm_^.State.Timers[0].Value := Cardinal(FM_ConvertTimerAValue(0));
  fm_^.State.Timers[0].Counter := Cardinal(FM_ConvertTimerAValue(0));
  fm_^.State.Timers[0].Enabled := Byte(0);
  fm_^.State.Timers[1].Value := Cardinal(FM_ConvertTimerBValue(0));
  fm_^.State.Timers[1].Counter := Cardinal(FM_ConvertTimerBValue(0));
  fm_^.State.Timers[1].Enabled := Byte(0);
  fm_^.State.CachedAddress27 := Byte(0);
  fm_^.State.CachedUpperFrequencyBitsFM3MultiFrequency := Byte(0);
  fm_^.State.CachedUpperFrequencyBits := Byte(fm_^.State.CachedUpperFrequencyBitsFM3MultiFrequency);
  fm_^.State.LeftoverCycles := Byte(0);
  fm_^.State.Status := Byte(0);
  fm_^.State.BusyFlagCounter := Byte(0);
  FM_LFO_Initialise(@fm_^.State.LFO);
end;

procedure FM_DoAddress(fm_: PFM; Port: Cardinal; Address: Cardinal);
begin
  fm_^.State.Port := Byte(Mul32(Port, 3));
  fm_^.State.Address := Byte(Address);
end;

procedure FM_DoData(fm_: PFM; data: Cardinal);
const
  table: array[0..7] of Cardinal = (0, 1, 2, $FF, 3, 4, 5, $FF);
  operator_mappings: array[0..2] of Byte = (2, 0, 1);
var
  State: PFMState;
  fm3_per_operator_frequencies_enabled: Byte;
  i: Cardinal;
  temp122: Integer;
  i_scope99: Cardinal;
  temp125: Cardinal;
  channel_index: Cardinal;
  channel_scope100: PFMChannel;
  i_scope101: Cardinal;
  slot_index: Cardinal;
  channel_index_scope102: Cardinal;
  channel_metadata: PFMChannelMetadata;
  channel_scope103: PFMChannel;
  operator_index_scrambled: Cardinal;
  operator_index: Cardinal;
  Frequency: Cardinal;
  operator_index_scope104: Cardinal;
  frequency_scope105: Cardinal;
begin
  State := @fm_^.State;
  State^.Status := Byte(State^.Status or $80);
  State^.BusyFlagCounter := Byte(32 * 6);
  if (Integer(State^.Address) < Integer($30)) then
  begin
    if (Integer(State^.Port) = Integer(0)) then
    begin
      case State^.Address of
        $22:
          begin
            if (FM_LFO_SetEnabled(@State^.LFO, Ord(Cardinal(Cardinal(data) and Cardinal(8)) <> Cardinal(0))) <> 0) then
            begin
              for var ChannelIndex := Low(State^.Channels) to High(State^.Channels) do
              begin
                var Channel: PFMChannelMetadata := @State^.Channels[ChannelIndex];
                FM_Channel_SetPhaseModulation(@Channel^.State, State^.LFO.PhaseModulation);
              end;
            end;
            State^.LFO.Frequency := Byte(Cardinal(data) and Cardinal(7));
          end;
        $24:
          begin
            State^.RawTimerAValue := Word(State^.RawTimerAValue and 3);
            State^.RawTimerAValue := Word(State^.RawTimerAValue or (data shl 2));
            State^.Timers[0].Value := Cardinal(FM_ConvertTimerAValue(State^.RawTimerAValue));
          end;
        $25:
          begin
            State^.RawTimerAValue := Word(State^.RawTimerAValue and (not 3));
            State^.RawTimerAValue := Word(State^.RawTimerAValue or (Cardinal(data) and Cardinal(3)));
            State^.Timers[0].Value := Cardinal(FM_ConvertTimerAValue(State^.RawTimerAValue));
          end;
        $26:
          begin
            State^.Timers[1].Value := Cardinal(FM_ConvertTimerBValue(data));
          end;
        $27:
          begin
            fm3_per_operator_frequencies_enabled := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($C0)) <> Cardinal(0)));
            i := Cardinal(0);
            while (Cardinal(i) < Cardinal(Length(State^.Timers))) do
            begin
              temp122 := Ord(Cardinal(Cardinal(data) and Cardinal(1 shl (Add32(0, i)))) <> Cardinal(0));
              if temp122 <> 0 then
              begin
                temp122 := Ord(Integer(State^.CachedAddress27 and (1 shl (Add32(0, i)))) = Integer(0));
              end;
              if (temp122 <> 0) then
              begin
                State^.Timers[i].Counter := Cardinal(State^.Timers[i].Value);
              end;
              State^.Timers[i].Enabled := Byte(Ord(Cardinal(Cardinal(data) and Cardinal(1 shl (Add32(2, i)))) <> Cardinal(0)));
              if (Cardinal(Cardinal(data) and Cardinal(1 shl (Add32(4, i)))) <> Cardinal(0)) then
              begin
                State^.Status := Byte(State^.Status and (not (1 shl i)));
              end;
              Inc(i);
            end;
            State^.CachedAddress27 := Byte(data);
            if (Integer(State^.Channel3Metadata.PerOperatorFrequenciesEnabled) <> Integer(fm3_per_operator_frequencies_enabled)) then
            begin
              State^.Channel3Metadata.PerOperatorFrequenciesEnabled := Byte(fm3_per_operator_frequencies_enabled);
              i_scope99 := Cardinal(0);
              while (Cardinal(i_scope99) < Cardinal(Length(State^.Channels[2].State.Operators))) do
              begin
                if (fm3_per_operator_frequencies_enabled <> 0) then
                begin
                  temp125 := i_scope99;
                end
                else
                begin
                  temp125 := 3;
                end;
                FM_Phase_SetFrequency(@State^.Channels[2].State.Operators[i_scope99].Phase, State^.LFO.PhaseModulation, State^.Channels[2].State.PhaseModulationSensitivity, State^.Channel3Metadata.Frequencies[temp125]);
                Inc(i_scope99);
              end;
            end;
            State^.Channel3Metadata.CsmModeEnabled := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($C0)) = Cardinal($80)));
          end;
        $28:
          begin
            channel_index := Cardinal(table[(Cardinal(data) mod Cardinal(Length(table)))]);
            if (Cardinal(channel_index) <> Cardinal($FF)) then
            begin
              channel_scope100 := @State^.Channels[channel_index].State;
              i_scope101 := Cardinal(0);
              while (Cardinal(i_scope101) < Cardinal(Length(channel_scope100^.Operators))) do
              begin
                FM_Operator_SetKeyOn(@channel_scope100^.Operators[i_scope101], Ord(Cardinal(Cardinal(data) and Cardinal(1 shl (Add32(4, i_scope101)))) <> Cardinal(0)));
                Inc(i_scope101);
              end;
            end;
          end;
        $2A:
          begin
            State^.DacSample := Word(State^.DacSample and 1);
            State^.DacSample := Word(State^.DacSample or (Cardinal(data) shl 1));
          end;
        $2B:
          begin
            State^.DacEnabled := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($80)) <> Cardinal(0)));
          end;
        $2C:
          begin
            State^.DacSample := Word(State^.DacSample and (not 1));
            State^.DacSample := Word(State^.DacSample or (Cardinal(data shr 3) and Cardinal(1)));
            State^.DacTest := Byte(Ord(Cardinal(Cardinal(data) and Cardinal(1 shl 5)) <> Cardinal(0)));
          end;
      else
        begin
          ;
        end;
      end;
    end;
  end
  else
  begin
    slot_index := Cardinal(State^.Address and 3);
    channel_index_scope102 := Cardinal(Add32(State^.Port, slot_index));
    channel_metadata := @State^.Channels[channel_index_scope102];
    channel_scope103 := @State^.Channels[channel_index_scope102].State;
    if (Cardinal(slot_index) <> Cardinal(3)) then
    begin
      if (Integer(State^.Address) < Integer($A0)) then
      begin
        operator_index_scrambled := Cardinal(ArithmeticShiftRight(Integer(State^.Address), 2) and 3);
        operator_index := Cardinal(Cardinal(Cardinal(operator_index_scrambled shr 1) or Cardinal(operator_index_scrambled shl 1)) and Cardinal(3));
        case (State^.Address div $10) of
          (          $30 div $10):
            begin
              FM_Phase_SetDetuneAndMultiplier(@channel_scope103^.Operators[operator_index].Phase, State^.LFO.PhaseModulation, channel_scope103^.PhaseModulationSensitivity, (Cardinal(data shr 4) and Cardinal(7)), (Cardinal(data) and Cardinal($F)));
            end;
          (          $40 div $10):
            begin
              FM_Operator_SetTotalLevel(@channel_scope103^.Operators[operator_index], (Cardinal(data) and Cardinal($7F)));
            end;
          (          $50 div $10):
            begin
              FM_Operator_SetKeyScaleAndAttackRate(@channel_scope103^.Operators[operator_index], (Cardinal(data shr 6) and Cardinal(3)), (Cardinal(data) and Cardinal($1F)));
            end;
          (          $60 div $10):
            begin
              channel_scope103^.Operators[operator_index].Rates[FM_OPERATOR_ENVELOPE_MODE_DECAY] := Word(Cardinal(data) and Cardinal($1F));
              channel_scope103^.Operators[operator_index].AmplitudeModulationOn := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($80)) <> Cardinal(0)));
            end;
          (          $70 div $10):
            begin
              channel_scope103^.Operators[operator_index].Rates[FM_OPERATOR_ENVELOPE_MODE_SUSTAIN] := Word(Cardinal(data) and Cardinal($1F));
            end;
          (          $80 div $10):
            begin
              FM_Operator_SetSustainLevelAndReleaseRate(@channel_scope103^.Operators[operator_index], (Cardinal(data shr 4) and Cardinal($F)), (Cardinal(data) and Cardinal($F)));
            end;
          (          $90 div $10):
            begin
              FM_Operator_SetSSGEG(@channel_scope103^.Operators[operator_index], data);
            end;
        else
          begin
            ;
          end;
        end;
      end
      else
      begin
        case (State^.Address div 4) of
          (          $A0 div 4):
            begin
              repeat
                Frequency := Cardinal(Cardinal(data) or Cardinal(State^.CachedUpperFrequencyBits shl 8));
                if (Cardinal(channel_index_scope102) = Cardinal(2)) then
                begin
                  State^.Channel3Metadata.Frequencies[3] := Word(Frequency);
                  if (State^.Channel3Metadata.PerOperatorFrequenciesEnabled <> 0) then
                  begin
                    FM_Phase_SetFrequency(@State^.Channels[2].State.Operators[3].Phase, State^.LFO.PhaseModulation, State^.Channels[2].State.PhaseModulationSensitivity, Frequency);
                    Break;
                  end;
                end;
                FM_Channel_SetFrequencies(channel_scope103, State^.LFO.PhaseModulation, Frequency);
              until True;
            end;
          (          $A4 div 4):
            begin
              State^.CachedUpperFrequencyBits := Byte(Cardinal(data) and Cardinal($3F));
            end;
          (          $A8 div 4):
            begin
              if (Integer(State^.Port) = Integer(0)) then
              begin
                operator_index_scope104 := Cardinal(operator_mappings[slot_index]);
                frequency_scope105 := Cardinal(Cardinal(data) or Cardinal(State^.CachedUpperFrequencyBitsFM3MultiFrequency shl 8));
                State^.Channel3Metadata.Frequencies[operator_index_scope104] := Word(frequency_scope105);
                if (State^.Channel3Metadata.PerOperatorFrequenciesEnabled <> 0) then
                begin
                  FM_Phase_SetFrequency(@State^.Channels[2].State.Operators[operator_index_scope104].Phase, State^.LFO.PhaseModulation, State^.Channels[2].State.PhaseModulationSensitivity, frequency_scope105);
                end;
              end;
            end;
          (          $AC div 4):
            begin
              State^.CachedUpperFrequencyBitsFM3MultiFrequency := Byte(Cardinal(data) and Cardinal($3F));
            end;
          (          $B0 div 4):
            begin
              FM_Channel_SetFeedbackAndAlgorithm(channel_scope103, (Cardinal(data shr 3) and Cardinal(7)), (Cardinal(data) and Cardinal(7)));
            end;
          (          $B4 div 4):
            begin
              channel_metadata^.PanLeft := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($80)) <> Cardinal(0)));
              channel_metadata^.PanRight := Byte(Ord(Cardinal(Cardinal(data) and Cardinal($40)) <> Cardinal(0)));
              FM_Channel_SetModulationSensitivity(channel_scope103, State^.LFO.PhaseModulation, (Cardinal(data shr 4) and Cardinal(3)), (Cardinal(data) and Cardinal(7)));
            end;
        else
          begin
            ;
          end;
        end;
      end;
    end;
  end;
end;

function GetFinalSample(fm_: PFM; sample: Integer; Enabled: Byte): Integer;
var
  offset: Integer;
  temp147: Integer;
  temp148: Integer;
  temp149: Integer;
begin
  if (fm_^.Configuration.LadderEffectDisabled <> 0) then
  begin
    offset := Integer(0);
  end
  else
  begin
    if (Integer(sample) < Integer(0)) then
    begin
      Inc(sample);
      offset := Integer(-4);
    end
    else
    begin
      offset := Integer(4);
    end;
  end;
  if (not (Enabled <> 0)) then
  begin
    sample := Integer(0);
  end;
  if (fm_^.State.DacTest <> 0) then
  begin
    sample := Integer(sample * 4);
    if (Integer($FF) < Integer(sample)) then
    begin
      temp148 := $FF;
    end
    else
    begin
      temp148 := sample;
    end;
    if (Integer(-$FF) > Integer(temp148)) then
    begin
      temp147 := (-$FF);
    end
    else
    begin
      if (Integer($FF) < Integer(sample)) then
      begin
        temp149 := $FF;
      end
      else
      begin
        temp149 := sample;
      end;
      temp147 := temp149;
    end;
    sample := Integer(temp147);
  end
  else
  begin
    sample := Integer(sample + offset);
  end;
  Exit(Integer((sample * (1 shl (16 - 9))) div 8));
end;

function FM_ToNativeSigned(Value: Cardinal): Integer;
begin
  Exit(Integer(Sub32(Cardinal(Integer(Value)) and Cardinal(Sub32(Cardinal(1) shl (9 - 1), 1)), Cardinal(Integer(Value)) and Cardinal(Cardinal(1) shl (9 - 1)))));
end;

procedure FM_OutputSamples(fm_: PFM; var sample_buffer: array of SmallInt);
var
  State: PFMState;
  DacSample: Integer;
  channel_index: Cardinal;
  timer_index: Cardinal;
  channel_metadata: PFMChannelMetadata;
  channel_scope150: PFMChannel;
  PanLeft: Byte;
  PanRight: Byte;
  is_dac: Byte;
  temp157: Integer;
  temp158: Integer;
  channel_disabled: Byte;
  temp159: Byte;
  fm_sample: Integer;
  sample: Integer;
  temp160: Integer;
  timer: PFMTimer;
  temp164: Integer;
  temp165: Integer;
  operator_index: Cardinal;
begin
  State := @fm_^.State;
  DacSample := Integer(FM_ToNativeSigned(State^.DacSample xor $100));
  if Odd(Length(sample_buffer)) then
    raise EArgumentException.Create('FM output requires complete stereo frames');
  for var FrameIndex := 0 to Length(sample_buffer) div 2 - 1 do
  begin
    var SampleIndex := FrameIndex * 2;
    if (FM_LFO_Advance(@State^.LFO) <> 0) then
    begin
      for var ChannelIndex := Low(State^.Channels) to High(State^.Channels) do
      begin
        var Channel: PFMChannelMetadata := @State^.Channels[ChannelIndex];
        FM_Channel_SetPhaseModulation(@Channel^.State, State^.LFO.PhaseModulation);
      end;
    end;
    channel_index := Cardinal(0);
    while (Cardinal(channel_index) < Cardinal(Length(State^.Channels))) do
    begin
      channel_metadata := @State^.Channels[channel_index];
      channel_scope150 := @State^.Channels[channel_index].State;
      PanLeft := Byte(channel_metadata^.PanLeft);
      PanRight := Byte(channel_metadata^.PanRight);
      temp158 := Ord(Cardinal(channel_index) = Cardinal(5));
      if temp158 <> 0 then
      begin
        temp158 := Ord(State^.DacEnabled <> 0);
      end;
      temp157 := Ord(temp158 <> 0);
      if temp157 = 0 then
      begin
        temp157 := Ord(State^.DacTest <> 0);
      end;
      is_dac := Byte(temp157);
      if (is_dac <> 0) then
      begin
        temp159 := fm_^.Configuration.DacChannelDisabled;
      end
      else
      begin
        temp159 := fm_^.Configuration.FMChannelsDisabled[channel_index];
      end;
      channel_disabled := Byte(temp159);
      fm_sample := Integer(FM_ToNativeSigned(FM_Channel_GetSample(channel_scope150, State^.LFO.AmplitudeModulation)));
      if (is_dac <> 0) then
      begin
        temp160 := DacSample;
      end
      else
      begin
        temp160 := fm_sample;
      end;
      sample := Integer(temp160);
      if (not (channel_disabled <> 0)) then
      begin
        sample_buffer[SampleIndex] := SmallInt(sample_buffer[SampleIndex] + GetFinalSample(fm_, sample, PanLeft));
        sample_buffer[SampleIndex + 1] := SmallInt(sample_buffer[SampleIndex + 1] + GetFinalSample(fm_, sample, PanRight));
      end;
      Inc(channel_index);
    end;
    timer_index := Cardinal(0);
    while (Cardinal(timer_index) < Cardinal(Length(State^.Timers))) do
    begin
      timer := @State^.Timers[timer_index];
      Dec(timer^.Counter);
      if (Cardinal(timer^.Counter) = Cardinal(0)) then
      begin
        if (timer^.Enabled <> 0) then
        begin
          temp164 := (1 shl timer_index);
        end
        else
        begin
          temp164 := 0;
        end;
        State^.Status := Byte(State^.Status or temp164);
        timer^.Counter := Cardinal(timer^.Value);
        temp165 := Ord(State^.Channel3Metadata.CsmModeEnabled <> 0);
        if temp165 <> 0 then
        begin
          temp165 := Ord(Cardinal(timer_index) = Cardinal(0));
        end;
        if (temp165 <> 0) then
        begin
          operator_index := Cardinal(0);
          while (Cardinal(operator_index) < Cardinal(Length(State^.Channels[2].State.Operators))) do
          begin
            FM_Operator_SetKeyOn(@State^.Channels[2].State.Operators[operator_index], 1);
            FM_Operator_SetKeyOn(@State^.Channels[2].State.Operators[operator_index], 0);
            Inc(operator_index);
          end;
        end;
      end;
      Inc(timer_index);
    end;
  end;
end;

function FM_Update(fm_: PFM; cycles_to_do: Cardinal; fm_audio_to_be_generated: TFMAudioCallback; UserData: Pointer): Cardinal;
var
  State: PFMState;
  temp168: Byte;
begin
  State := @fm_^.State;
  var TotalFrames: Cardinal := Cardinal(Cardinal(Add32(State^.LeftoverCycles, cycles_to_do)) div Cardinal((6 * 6) * 4));
  State^.LeftoverCycles := Byte(Cardinal(Add32(State^.LeftoverCycles, cycles_to_do)) mod Cardinal((6 * 6) * 4));
  if (Cardinal(TotalFrames) <> Cardinal(0)) then
  begin
    fm_audio_to_be_generated(UserData, TotalFrames);
  end;
  if (Integer(State^.BusyFlagCounter) <> Integer(0)) then
  begin
    if (Cardinal(State^.BusyFlagCounter) < Cardinal(cycles_to_do)) then
    begin
      temp168 := State^.BusyFlagCounter;
    end
    else
    begin
      temp168 := cycles_to_do;
    end;
    State^.BusyFlagCounter := Byte(State^.BusyFlagCounter - temp168);
    if (Integer(State^.BusyFlagCounter) = Integer(0)) then
    begin
      State^.Status := Byte(State^.Status and (not $80));
    end;
  end;
  Exit(Cardinal(State^.Status));
end;

end.

