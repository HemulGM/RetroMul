unit MD.Sound;

interface

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

  TFMAudioCallback = procedure(UserData: Pointer; TotalFrames: Cardinal);

const
  PSG_NOISE_TYPE_PERIODIC = 0;
  PSG_NOISE_TYPE_WHITE = PSG_NOISE_TYPE_PERIODIC + 1;
  PSG_VOLUMES: array[0..15] of array[0..1] of SmallInt = (($1FFF, (-$1FFF)), ($196A, (-$196A)), ($1430, (-$1430)), ($1009, (-$1009)), ($0CBD, (-$0CBD)), ($0A1E, (-$0A1E)), ($0809, (-$0809)), ($0662, (-$0662)), ($0512, (-$0512)), ($0407, (-$0407)), ($0333, (-$0333)), ($028A, (-$028A)), ($0204, (-$0204)), ($019A, (-$019A)), ($0146, (-$0146)), ($0000, (-$0000)));
  FM_OPERATOR_ENVELOPE_MODE_ATTACK = 0;
  FM_OPERATOR_ENVELOPE_MODE_DECAY = 1;
  FM_OPERATOR_ENVELOPE_MODE_SUSTAIN = 2;
  FM_OPERATOR_ENVELOPE_MODE_RELEASE = 3;
  LOGARITHMIC_ATTENUATION_SINE_TABLE: array[0..255] of Word = ($859, $6C3, $607, $58B, $52E, $4E4, $4A6, $471, $443, $41A, $3F5, $3D3, $3B5, $398, $37E, $365, $34E, $339, $324, $311, $2FF,
    $2ED, $2DC, $2CD, $2BD, $2AF, $2A0, $293, $286, $279, $26D, $261, $256, $24B, $240, $236, $22C, $222, $218, $20F, $206, $1FD, $1F5, $1EC, $1E4, $1DC, $1D4, $1CD, $1C5, $1BE, $1B7,
    $1B0, $1A9, $1A2, $19B, $195, $18F, $188, $182, $17C, $177, $171, $16B, $166, $160, $15B, $155, $150, $14B, $146, $141, $13C, $137, $133, $12E, $129, $125, $121, $11C, $118, $114,
    $10F, $10B, $107, $103, $0FF, $0FB, $0F8, $0F4, $0F0, $0EC, $0E9, $0E5, $0E2, $0DE, $0DB, $0D7, $0D4, $0D1, $0CD, $0CA, $0C7, $0C4, $0C1, $0BE, $0BB, $0B8, $0B5, $0B2, $0AF, $0AC,
    $0A9, $0A7, $0A4, $0A1, $09F, $09C, $099, $097, $094, $092, $08F, $08D, $08A, $088, $086, $083, $081, $07F, $07D, $07A, $078, $076, $074, $072, $070, $06E, $06C, $06A, $068, $066,
    $064, $062, $060, $05E, $05C, $05B, $059, $057, $055, $053, $052, $050, $04E, $04D, $04B, $04A, $048, $046, $045, $043, $042, $040, $03F, $03E, $03C, $03B, $039, $038, $037, $035,
    $034, $033, $031, $030, $02F, $02E, $02D, $02B, $02A, $029, $028, $027, $026, $025, $024, $023, $022, $021, $020, $01F, $01E, $01D, $01C, $01B, $01A, $019, $018, $017, $017, $016,
    $015, $014, $014, $013, $012, $011, $011, $010, $00F, $00F, $00E, $00D, $00D, $00C, $00C, $00B, $00A, $00A, $009, $009, $008, $008, $007, $007, $007, $006, $006, $005, $005, $005,
    $004, $004, $004, $003, $003, $003, $002, $002, $002, $002, $001, $001, $001, $001, $001, $001, $001, $000, $000, $000, $000, $000, $000, $000, $000);
  POWER_TABLE: array[0..255] of Word = ($7FA, $7F5, $7EF, $7EA, $7E4, $7DF, $7DA, $7D4, $7CF, $7C9, $7C4, $7BF, $7B9, $7B4, $7AE, $7A9, $7A4, $79F, $799, $794, $78F, $78A, $784, $77F, $77A,
    $775, $770, $76A, $765, $760, $75B, $756, $751, $74C, $747, $742, $73D, $738, $733, $72E, $729, $724, $71F, $71A, $715, $710, $70B, $706, $702, $6FD, $6F8, $6F3, $6EE, $6E9, $6E5,
    $6E0, $6DB, $6D6, $6D2, $6CD, $6C8, $6C4, $6BF, $6BA, $6B5, $6B1, $6AC, $6A8, $6A3, $69E, $69A, $695, $691, $68C, $688, $683, $67F, $67A, $676, $671, $66D, $668, $664, $65F, $65B,
    $657, $652, $64E, $649, $645, $641, $63C, $638, $634, $630, $62B, $627, $623, $61E, $61A, $616, $612, $60E, $609, $605, $601, $5FD, $5F9, $5F5, $5F0, $5EC, $5E8, $5E4, $5E0, $5DC,
    $5D8, $5D4, $5D0, $5CC, $5C8, $5C4, $5C0, $5BC, $5B8, $5B4, $5B0, $5AC, $5A8, $5A4, $5A0, $59C, $599, $595, $591, $58D, $589, $585, $581, $57E, $57A, $576, $572, $56F, $56B, $567,
    $563, $560, $55C, $558, $554, $551, $54D, $549, $546, $542, $53E, $53B, $537, $534, $530, $52C, $529, $525, $522, $51E, $51B, $517, $514, $510, $50C, $509, $506, $502, $4FF, $4FB,
    $4F8, $4F4, $4F1, $4ED, $4EA, $4E7, $4E3, $4E0, $4DC, $4D9, $4D6, $4D2, $4CF, $4CC, $4C8, $4C5, $4C2, $4BE, $4BB, $4B8, $4B5, $4B1, $4AE, $4AB, $4A8, $4A4, $4A1, $49E, $49B, $498,
    $494, $491, $48E, $48B, $488, $485, $482, $47E, $47B, $478, $475, $472, $46F, $46C, $469, $466, $463, $460, $45D, $45A, $457, $454, $451, $44E, $44B, $448, $445, $442, $43F, $43C,
    $439, $436, $433, $430, $42D, $42A, $428, $425, $422, $41F, $41C, $419, $416, $414, $411, $40E, $40B, $408, $406, $403, $400);

procedure PSGInitialise(var Psg: TPSG);

procedure PSGDoCommand(var Psg: TPSG; Command: Cardinal);

procedure PSGUpdate(var Psg: TPSG; var SampleBuffer: array of SmallInt);

function RecalculatePhaseStep(var Phase: TFMPhase; Modulation: Cardinal; ModulationSensitivity: Cardinal): Cardinal;

procedure FMPhaseInitialise(var Phase: TFMPhase);

procedure FMPhaseSetFrequency(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal; FNumberAndBlock: Cardinal);

procedure FMPhaseSetDetuneAndMultiplier(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal; Detune: Cardinal; Multiplier: Cardinal);

procedure FMPhaseSetModulationAndSensitivity(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal);

function GetSSGEGCorrectedAttenuation(var State: TFMOperator; DisableInversion: Byte): Cardinal;

function CalculateRate(var State: TFMOperator): Cardinal;

procedure EnterAttackMode(var State: TFMOperator);

function InversePow2(Value: Cardinal): Cardinal;

procedure FMOperatorInitialise(var State: TFMOperator);

procedure FMOperatorSetKeyOn(var State: TFMOperator; KeyOn: Byte);

procedure FMOperatorSetSSGEG(var State: TFMOperator; SSGEg: Cardinal);

procedure FMOperatorSetTotalLevel(var State: TFMOperator; TotalLevel: Cardinal);

procedure FMOperatorSetKeyScaleAndAttackRate(var State: TFMOperator; KeyScale: Cardinal; AttackRate: Cardinal);

procedure FMOperatorSetSustainLevelAndReleaseRate(var State: TFMOperator; SustainLevel: Cardinal; ReleaseRate: Cardinal);

function GetEnvelopeDelta(var State: TFMOperator): Cardinal;

procedure UpdateEnvelopeSSGEG(var State: TFMOperator);

procedure UpdateEnvelopeADSR(var State: TFMOperator);

function GetEnvelopeAttenuation(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;

function UpdateEnvelope(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;

function FMOperatorProcess(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal; PhaseModulation: Cardinal): Cardinal;

function ComputeFeedbackDivisor(Value: Cardinal): Cardinal;

procedure SetAmplitudeModulation(var State: TFMChannel; AmplitudeModulation: Cardinal);

procedure FMChannelInitialise(var State: TFMChannel);

procedure FMChannelSetFrequencies(var Channel: TFMChannel; Modulation: Cardinal; FNumberAndBlock: Cardinal);

procedure FMChannelSetFeedbackAndAlgorithm(var Channel: TFMChannel; Feedback: Cardinal; Algorithm: Cardinal);

procedure FMChannelSetPhaseModulationAndSensitivity(var Channel: TFMChannel; PhaseModulation: Cardinal; PhaseModulationSensitivity: Cardinal);

procedure FMChannelSetModulationSensitivity(var Channel: TFMChannel; PhaseModulation: Cardinal; Amplitude: Cardinal; Phase: Cardinal);

procedure FMChannelSetPhaseModulation(var Channel: TFMChannel; PhaseModulation: Cardinal);

function FMChannelMixSamples(A: Cardinal; B: Cardinal): Cardinal;

function FMChannelGetSample(var Channel: TFMChannel; AmplitudeModulation: Cardinal): Cardinal;

procedure FMLFOInitialise(var State: TFMLFO);

function FMLFOSetEnabled(var State: TFMLFO; Enabled: Byte): Byte;

function FMLFOAdvance(var State: TFMLFO): Byte;

function FMConvertTimerAValue(Value: Cardinal): Cardinal;

function FMConvertTimerBValue(Value: Cardinal): Cardinal;

procedure FMInitialise(var Fm: TFM);

procedure FMDoAddress(var Fm: TFM; Port: Cardinal; Address: Cardinal);

procedure FMDoData(var Fm: TFM; Data: Cardinal);

function GetFinalSample(var Fm: TFM; Sample: Integer; Enabled: Byte): Integer;

function FMToNativeSigned(Value: Cardinal): Integer;

procedure FMOutputSamples(var Fm: TFM; var SampleBuffer: array of SmallInt);

function FMUpdate(var Fm: TFM; CyclesToDo: Cardinal; FmAudioToBeGenerated: TFMAudioCallback; UserData: Pointer): Cardinal;

implementation

procedure PSGInitialise(var Psg: TPSG);
begin
  for var ItemIndex := 0 to High(Psg.State.Tones) do
  begin
    Psg.State.Tones[ItemIndex].CountDown := 0;
    Psg.State.Tones[ItemIndex].CountDownMaster := 0;
    Psg.State.Tones[ItemIndex].Attenuation := $F;
    Psg.State.Tones[ItemIndex].OutputBit := 0;
  end;
  Psg.State.Noise.CountDown := 0;
  Psg.State.Noise.Attenuation := $F;
  Psg.State.Noise.FakeOutputBit := 0;
  Psg.State.Noise.RealOutputBit := 0;
  Psg.State.Noise.FrequencyMode := 0;
  Psg.State.Noise.NoiseType := Byte(PSG_NOISE_TYPE_PERIODIC);
  Psg.State.Noise.ShiftRegister := 0;
  Psg.State.LatchedCommand.Channel := 0;
  Psg.State.LatchedCommand.IsVolumeCommand := 0;
end;

procedure PSGDoCommand(var Psg: TPSG; Command: Cardinal);
begin
  var Latch: Byte := Ord((Command and $80) <> 0);
  if Latch <> 0 then
  begin
    Psg.State.LatchedCommand.Channel := Byte((Command shr 5) and 3);
    Psg.State.LatchedCommand.IsVolumeCommand := Ord((Command and $10) <> 0);
  end;
  if Psg.State.LatchedCommand.Channel < Integer(Length(Psg.State.Tones)) then
  begin
    if Psg.State.LatchedCommand.IsVolumeCommand <> 0 then
      Psg.State.Tones[Psg.State.LatchedCommand.Channel].Attenuation := Byte(Command and $F)
    else
    begin
      if Latch <> 0 then
      begin
        Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster := Word(Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster and (not $F));
        Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster := Word(Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster or (Command and $F));
      end
      else
      begin
        Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster := Word(Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster and $F);
        Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster := Word(Psg.State.Tones[Psg.State.LatchedCommand.Channel].CountDownMaster or ((Command and $3F) shl 4));
      end;
    end;
  end
  else
  begin
    if Psg.State.LatchedCommand.IsVolumeCommand <> 0 then
      Psg.State.Noise.Attenuation := Byte(Command and $F)
    else
    begin
      if (Command and 4) <> 0 then
        Psg.State.Noise.NoiseType := Byte(PSG_NOISE_TYPE_WHITE)
      else
        Psg.State.Noise.NoiseType := Byte(PSG_NOISE_TYPE_PERIODIC);
      Psg.State.Noise.FrequencyMode := Byte(Command and 3);
      Psg.State.Noise.ShiftRegister := 1;
    end;
  end;
end;

procedure PSGUpdate(var Psg: TPSG; var SampleBuffer: array of SmallInt);
begin
  for var ChannelIndex := Low(Psg.State.Tones) to High(Psg.State.Tones) do
  begin
    if Psg.Configuration.ToneDisabled[ChannelIndex] <> 0 then
      Continue;

    for var SampleIndex := Low(SampleBuffer) to High(SampleBuffer) do
    begin
      if Psg.State.Tones[ChannelIndex].CountDown <> 0 then
        Dec(Psg.State.Tones[ChannelIndex].CountDown);
      if (Psg.State.Tones[ChannelIndex].CountDownMaster <> 0) and (Psg.State.Tones[ChannelIndex].CountDown = 0) then
      begin
        Psg.State.Tones[ChannelIndex].CountDown := Psg.State.Tones[ChannelIndex].CountDownMaster;
        Psg.State.Tones[ChannelIndex].OutputBit := Ord(Psg.State.Tones[ChannelIndex].OutputBit = 0);
      end;
      SampleBuffer[SampleIndex] := SmallInt(SampleBuffer[SampleIndex] +
          PSG_VOLUMES[Psg.State.Tones[ChannelIndex].Attenuation][Psg.State.Tones[ChannelIndex].OutputBit]);
    end;
  end;

  if Psg.Configuration.NoiseDisabled <> 0 then
    Exit;

  for var SampleIndex := Low(SampleBuffer) to High(SampleBuffer) do
  begin
    if Psg.State.Noise.CountDown <> 0 then
      Dec(Psg.State.Noise.CountDown);
    if Psg.State.Noise.CountDown = 0 then
    begin
      if Psg.State.Noise.FrequencyMode = 3 then
        Psg.State.Noise.CountDown := Psg.State.Tones[High(Psg.State.Tones)].CountDownMaster
      else
        Psg.State.Noise.CountDown := $10 shl Psg.State.Noise.FrequencyMode;
      Psg.State.Noise.FakeOutputBit := Ord(Psg.State.Noise.FakeOutputBit = 0);
      if Psg.State.Noise.FakeOutputBit <> 0 then
      begin
        Psg.State.Noise.RealOutputBit := (Psg.State.Noise.ShiftRegister and $8000) shr 15;
        Psg.State.Noise.ShiftRegister := Word((Psg.State.Noise.ShiftRegister shl 1) or Psg.State.Noise.RealOutputBit);
        if Psg.State.Noise.NoiseType = PSG_NOISE_TYPE_WHITE then
          Psg.State.Noise.ShiftRegister := Psg.State.Noise.ShiftRegister xor ((Psg.State.Noise.ShiftRegister and $2000) shr 13);
      end;
    end;
    SampleBuffer[SampleIndex] := SmallInt(SampleBuffer[SampleIndex] +
        PSG_VOLUMES[Psg.State.Noise.Attenuation][Psg.State.Noise.RealOutputBit]);
  end;
end;

function RecalculatePhaseStep(var Phase: TFMPhase; Modulation: Cardinal; ModulationSensitivity: Cardinal): Cardinal;
const
  KEY_CODES: array[0..15] of Cardinal = (0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3);
  DETUNE_LOOKUP: array[0..7] of array[0..3] of array[0..3] of Cardinal = (((0, 0, 1, 2), (0, 0, 1, 2), (0, 0, 1, 2), (0, 0, 1, 2)), ((0, 1, 2, 2), (0, 1, 2, 3), (0, 1, 2, 3), (0, 1, 2, 3)), ((0, 1, 2, 4), (0, 1, 3, 4), (0, 1, 3, 4), (0, 1, 3, 5)), ((0, 2, 4, 5), (0, 2, 4, 6), (0, 2, 4, 6), (0, 2, 5, 7)), ((0, 2, 5, 8), (0, 3, 6, 8), (0, 3, 6, 9), (0, 3, 7, 10)), ((0, 4, 8, 11), (0, 4, 8, 12), (0, 4, 9, 13), (0, 5, 10, 14)), ((0, 5, 11, 16), (0, 6, 12, 17), (0, 6, 13, 19), (0, 7, 14, 20)), ((0, 8, 16, 22), (0, 8, 16, 22), (0, 8, 16, 22), (0, 8, 16, 22)));
  LFO_SHIFT_LOOKUP: array[0..7] of array[0..7] of array[0..1] of Byte = (((7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7), (7, 7)), ((7, 7), (7, 7), (7, 7), (7, 7), (7, 2), (7, 2), (7, 2), (7, 2)), ((7, 7), (7, 7), (7, 7), (7, 2), (7, 2), (7, 2), (1, 7), (1, 7)), ((7, 7), (7, 7), (7, 2), (7, 2), (1, 7), (1, 7), (1, 2), (1, 2)), ((7, 7), (7, 7), (7, 2), (1, 7), (1, 7), (1, 7), (1, 2), (0, 7)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)), ((7, 7), (7, 7), (1, 7), (1, 2), (0, 7), (0, 7), (0, 2), (0, 1)));
begin
  var Temp39: Integer;
  var Block: Cardinal := Cardinal(ArithmeticShiftRight(Phase.FNumberAndBlock, 11) and 7);
  var FNumber: Cardinal := Phase.FNumberAndBlock and $7FF;
  var Detune: Cardinal := Cardinal(DETUNE_LOOKUP[Block][KEY_CODES[(FNumber shr 7)]][(Phase.Detune mod Length(DETUNE_LOOKUP[0][0]))]);
  var PhaseModulationIsNegativeLobe: Byte := Ord((Modulation and $10) <> 0);
  var PhaseModulationIsMirroredSizeOfLobe: Byte := Ord((Modulation and 8) <> 0);
  if PhaseModulationIsMirroredSizeOfLobe <> 0 then
    Temp39 := 7
  else
    Temp39 := 0;
  var PhaseModulationAbsoluteQuadrant: Cardinal := (Modulation and 7) xor Cardinal(Temp39);
  var FNumberUpperNybbles: Cardinal := FNumber shr 4;
  var Shifts := LFO_SHIFT_LOOKUP[ModulationSensitivity][PhaseModulationAbsoluteQuadrant];
  var Step: Cardinal := Add32(FNumberUpperNybbles shr Shifts[0], FNumberUpperNybbles shr Shifts[1]);
  if ModulationSensitivity > 5 then
    Step := Step shl (Sub32(ModulationSensitivity, 5));
  Step := Step shr 2;
  if PhaseModulationIsNegativeLobe <> 0 then
    Step := Sub32(0, Step);
  Step := Add32(Step, FNumber shl 1);
  Step := Step and $FFF;
  Step := Step shl Block;
  Step := Step shr 1;
  Step := Step shr 1;
  if (Phase.Detune and 4) <> 0 then
    Step := Sub32(Step, Detune)
  else
    Step := Add32(Step, Detune);
  Step := Step and $1FFFF;
  Step := Mul32(Step, Phase.Multiplier);
  Step := Cardinal(Step div 2);
  Exit(Step);
end;

procedure FMPhaseInitialise(var Phase: TFMPhase);
begin
  FMPhaseSetFrequency(Phase, 0, 0, 0);
  FMPhaseSetDetuneAndMultiplier(Phase, 0, 0, 0, 0);
  Phase.Position := 0;
end;

procedure FMPhaseSetFrequency(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal; FNumberAndBlock: Cardinal);
begin
  Phase.FNumberAndBlock := Word(FNumberAndBlock);
  Phase.KeyCode := Word(FNumberAndBlock shr 9);
  Phase.Step := RecalculatePhaseStep(Phase, Modulation, Sensitivity);
end;

procedure FMPhaseSetDetuneAndMultiplier(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal; Detune: Cardinal; Multiplier: Cardinal);
begin
  Phase.Detune := Word(Detune);
  if Multiplier = 0 then
    Phase.Multiplier := Word(1)
  else
    Phase.Multiplier := Word(Mul32(Multiplier, 2));
  Phase.Step := RecalculatePhaseStep(Phase, Modulation, Sensitivity);
end;

procedure FMPhaseSetModulationAndSensitivity(var Phase: TFMPhase; Modulation: Cardinal; Sensitivity: Cardinal);
begin
  Phase.Step := RecalculatePhaseStep(Phase, Modulation, Sensitivity);
end;

function GetSSGEGCorrectedAttenuation(var State: TFMOperator; DisableInversion: Byte): Cardinal;
begin
  var Temp46: Integer := Ord(((DisableInversion = 0)) and (State.SSGEg.Enabled <> 0));
  if (Temp46 <> 0) and (State.SSGEg.Invert <> State.SSGEg.Attack) then
    Exit(Cardinal(($200 - State.Attenuation) and $3FF))
  else
    Exit(Cardinal(State.Attenuation));
end;

function CalculateRate(var State: TFMOperator): Cardinal;
begin
  var Temp47: Integer;
  if State.Rates[State.EnvelopeMode] = 0 then
    Exit(0);
  if $3F < Integer((State.Rates[State.EnvelopeMode] * 2) + ArithmeticShiftRight(State.Phase.KeyCode, State.KeyScale)) then
    Temp47 := $3F
  else
    Temp47 := (State.Rates[State.EnvelopeMode] * 2) + ArithmeticShiftRight(State.Phase.KeyCode, State.KeyScale);
  Exit(Cardinal(Temp47));
end;

procedure EnterAttackMode(var State: TFMOperator);
begin
  if State.KeyOn <> 0 then
  begin
    State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_ATTACK;
    if CalculateRate(State) >= Cardinal($1F * 2) then
    begin
      State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_DECAY;
      State.Attenuation := 0;
    end;
  end;
end;

function InversePow2(Value: Cardinal): Cardinal;
begin
  var Whole: Cardinal := Value shr 8;
  var Fraction: Cardinal := Value and $FF;
  Exit(Cardinal(ArithmeticShiftRight(Integer(POWER_TABLE[Fraction] shl 2), Whole)));
end;

procedure FMOperatorInitialise(var State: TFMOperator);
begin
  FMPhaseInitialise(State.Phase);
  State.CountDown := 1;
  State.CycleCounter := 0;
  State.DeltaIndex := 0;
  State.Attenuation := $3FF;
  FMOperatorSetSSGEG(State, 0);
  FMOperatorSetTotalLevel(State, $7F);
  FMOperatorSetKeyScaleAndAttackRate(State, 0, 0);
  State.Rates[FM_OPERATOR_ENVELOPE_MODE_DECAY] := 0;
  State.Rates[FM_OPERATOR_ENVELOPE_MODE_SUSTAIN] := 0;
  FMOperatorSetSustainLevelAndReleaseRate(State, 0, 0);
  State.AmplitudeModulationOn := 0;
  State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
  State.KeyOn := 0;
end;

procedure FMOperatorSetKeyOn(var State: TFMOperator; KeyOn: Byte);
begin
  if State.KeyOn <> KeyOn then
  begin
    State.KeyOn := KeyOn;
    if KeyOn <> 0 then
    begin
      EnterAttackMode(State);
      State.Phase.Position := 0;
    end
    else
    begin
      State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
      State.Attenuation := Word(GetSSGEGCorrectedAttenuation(State, 0));
      State.SSGEg.Invert := 0;
    end;
  end;
end;

procedure FMOperatorSetSSGEG(var State: TFMOperator; SSGEg: Cardinal);
begin
  State.SSGEg.Enabled := Ord((SSGEg and $8) <> 0);
  var Temp48: Integer := Ord(((SSGEg and $4) <> 0) and (State.SSGEg.Enabled <> 0));
  State.SSGEg.Attack := Byte(Temp48);
  var Temp49: Integer := Ord(((SSGEg and $2) <> 0) and (State.SSGEg.Enabled <> 0));
  State.SSGEg.Alternate := Byte(Temp49);
  var Temp50: Integer := Ord(((SSGEg and 1) <> 0) and (State.SSGEg.Enabled <> 0));
  State.SSGEg.Hold := Byte(Temp50);
end;

procedure FMOperatorSetTotalLevel(var State: TFMOperator; TotalLevel: Cardinal);
begin
  State.TotalLevel := Word(TotalLevel shl 3);
end;

procedure FMOperatorSetKeyScaleAndAttackRate(var State: TFMOperator; KeyScale: Cardinal; AttackRate: Cardinal);
begin
  State.KeyScale := Byte(Sub32(3, KeyScale));
  State.Rates[FM_OPERATOR_ENVELOPE_MODE_ATTACK] := Word(AttackRate);
end;

procedure FMOperatorSetSustainLevelAndReleaseRate(var State: TFMOperator; SustainLevel: Cardinal; ReleaseRate: Cardinal);
begin
  if SustainLevel = $F then
    State.SustainLevel := Word($3E0)
  else
    State.SustainLevel := Word(Mul32(SustainLevel, $20));
  State.Rates[FM_OPERATOR_ENVELOPE_MODE_RELEASE] := Word((ReleaseRate shl 1) or 1);
end;

function GetEnvelopeDelta(var State: TFMOperator): Cardinal;
const
  DELTAS: array[0..63] of array[0..7] of Cardinal = ((0, 0, 0, 0, 0, 0, 0, 0), (0, 0, 0, 0, 0, 0, 0, 0), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 0, 1, 0,
    1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1,
    0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1,
    1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1,
    0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0,
    1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1,
    0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0, 1, 1, 1, 1, 1, 1, 1), (0, 1, 0, 1, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 1), (0, 1, 1, 1, 0, 1, 1, 1), (0,
    1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 1, 1, 1, 1, 1), (1, 1, 1, 2, 1, 1, 1, 2), (1, 2, 1, 2, 1, 2, 1, 2), (1, 2, 2, 2, 1, 2, 2, 2), (2, 2, 2, 2, 2, 2, 2, 2), (2, 2, 2, 3, 2, 2, 2, 3),
    (2, 3, 2, 3, 2, 3, 2, 3), (2, 3, 3, 3, 2, 3, 3, 3), (3, 3, 3, 3, 3, 3, 3, 3), (3, 3, 3, 4, 3, 3, 3, 4), (3, 4, 3, 4, 3, 4, 3, 4), (3, 4, 4, 4, 3, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4,
    4), (4, 4, 4, 4, 4, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4, 4), (4, 4, 4, 4, 4, 4, 4, 4));
begin
  var Rate: Cardinal;
  var Temp52: Word;
  var Temp53: Integer;
  var Temp56: Word;
  Dec(State.CountDown);
  if State.CountDown = 0 then
  begin
    Rate := CalculateRate(State);
    State.CountDown := 3;
    Temp52 := State.CycleCounter;
    State.CycleCounter := (State.CycleCounter + 1) and $FFFF;
    if 11 > Cardinal(Rate div 4) then
      Temp53 := 11
    else
      Temp53 := Rate div 4;
    if Integer(Temp52 and ((1 shl (Sub32(Temp53, Rate div 4))) - 1)) = 0 then
    begin
      Temp56 := State.DeltaIndex;
      State.DeltaIndex := (State.DeltaIndex + 1) and $FFFF;
      Exit(Cardinal(DELTAS[Rate][(Temp56 mod Length(DELTAS[Rate]))]));
    end;
  end;
  Exit(0);
end;

procedure UpdateEnvelopeSSGEG(var State: TFMOperator);
begin
  if (State.SSGEg.Enabled <> 0) and (State.Attenuation >= $200) then
  begin
    if State.SSGEg.Alternate <> 0 then
    begin
      if State.SSGEg.Hold <> 0 then
        State.SSGEg.Invert := Byte(1)
      else
        State.SSGEg.Invert := Byte(Ord((State.SSGEg.Invert = 0)));
    end
    else
    begin
      if State.SSGEg.Hold = 0 then
        State.Phase.Position := 0;
    end;
    if State.SSGEg.Hold = 0 then
      EnterAttackMode(State);
  end;
end;

procedure UpdateEnvelopeADSR(var State: TFMOperator);
begin
  var Temp59: Integer;
  var Temp65: Integer;
  var Temp66: Integer;
  var Temp67: Integer;
  var Temp68: Integer;
  var Temp69: Integer;
  var Delta: Cardinal := GetEnvelopeDelta(State);
  if State.SSGEg.Enabled <> 0 then
    Temp59 := $200
  else
    Temp59 := $3F0;
  var EndEnvelope: Byte := Ord(State.Attenuation >= Temp59);
  case State.EnvelopeMode of
    FM_OPERATOR_ENVELOPE_MODE_ATTACK:
      begin
        repeat
          if State.Attenuation = 0 then
          begin
            State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_DECAY;
            Break;
          end;
          if Delta <> 0 then
          begin
            State.Attenuation := Word(State.Attenuation + (((not Cardinal(State.Attenuation)) shl (Sub32(Delta, 1))) shr 4));
            Assert(State.Attenuation <= $3FF);
          end;
        until True;
      end;
    FM_OPERATOR_ENVELOPE_MODE_DECAY:
      begin
        repeat
          if State.Attenuation >= State.SustainLevel then
          begin
            State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_SUSTAIN;
            Break;
          end;
          Temp65 := Ord((Delta <> 0) and ((EndEnvelope = 0)));
          if Temp65 <> 0 then
          begin
            if State.SSGEg.Enabled <> 0 then
              Temp66 := 2
            else
              Temp66 := 0;
            State.Attenuation := Word(State.Attenuation + (1 shl (Add32(Sub32(Delta, 1), Temp66))));
            Assert(State.Attenuation <= $3FF);
          end;
          Temp67 := Ord(EndEnvelope <> 0);
          if Temp67 <> 0 then
          begin
            Temp69 := Ord((State.KeyOn <> 0) and (State.SSGEg.Hold <> 0));
            Temp68 := Ord((Temp69 <> 0) and (State.SSGEg.Alternate <> State.SSGEg.Attack));
            Temp67 := Ord((Temp68 = 0));
          end;
          if Temp67 <> 0 then
          begin
            State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
            State.Attenuation := $3FF;
          end;
        until True;
      end;
    FM_OPERATOR_ENVELOPE_MODE_SUSTAIN, FM_OPERATOR_ENVELOPE_MODE_RELEASE:
      begin
        Temp65 := Ord((Delta <> 0) and ((EndEnvelope = 0)));
        if Temp65 <> 0 then
        begin
          if State.SSGEg.Enabled <> 0 then
            Temp66 := 2
          else
            Temp66 := 0;
          State.Attenuation := Word(State.Attenuation + (1 shl (Add32(Sub32(Delta, 1), Temp66))));
          Assert(State.Attenuation <= $3FF);
        end;
        Temp67 := Ord(EndEnvelope <> 0);
        if Temp67 <> 0 then
        begin
          Temp69 := Ord((State.KeyOn <> 0) and (State.SSGEg.Hold <> 0));
          Temp68 := Ord((Temp69 <> 0) and (State.SSGEg.Alternate <> State.SSGEg.Attack));
          Temp67 := Ord((Temp68 = 0));
        end;
        if Temp67 <> 0 then
        begin
          State.EnvelopeMode := FM_OPERATOR_ENVELOPE_MODE_RELEASE;
          State.Attenuation := $3FF;
        end;
      end;
  end;
end;

function GetEnvelopeAttenuation(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;
begin
  var Temp71: Integer;
  var FinalAmplitudeModulation: Cardinal;
  if State.AmplitudeModulationOn <> 0 then
    FinalAmplitudeModulation := AmplitudeModulation shr AmplitudeModulationShift
  else
    FinalAmplitudeModulation := 0;
  var Attenuation: Cardinal := Add32(Add32(GetSSGEGCorrectedAttenuation(State, Ord((State.KeyOn = 0))), FinalAmplitudeModulation), State.TotalLevel);
  if $3FF < Attenuation then
    Temp71 := $3FF
  else
    Temp71 := Attenuation;
  Exit(Cardinal(Temp71));
end;

function UpdateEnvelope(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal): Cardinal;
begin
  UpdateEnvelopeSSGEG(State);
  UpdateEnvelopeADSR(State);
  Exit(GetEnvelopeAttenuation(State, AmplitudeModulation, AmplitudeModulationShift));
end;

function FMOperatorProcess(var State: TFMOperator; AmplitudeModulation: Cardinal; AmplitudeModulationShift: Cardinal; PhaseModulation: Cardinal): Cardinal;
begin
  var Temp72: Integer;
  State.Phase.Position := Add32(State.Phase.Position, State.Phase.Step);
  var Phase: Cardinal := State.Phase.Position shr 10;
  var Attenuation: Cardinal := UpdateEnvelope(State, AmplitudeModulation, AmplitudeModulationShift);
  var ModulatedPhase: Cardinal := Add32(Phase, PhaseModulation div 2) and $3FF;
  var PhaseIsInNegativeWave: Byte := Ord((ModulatedPhase and $200) <> 0);
  var PhaseIsInMirroredHalfOfWave: Byte := Ord((ModulatedPhase and $100) <> 0);
  if PhaseIsInMirroredHalfOfWave <> 0 then
    Temp72 := $FF
  else
    Temp72 := 0;
  var QuarterPhase: Cardinal := (ModulatedPhase and $FF) xor Cardinal(Temp72);
  var PhaseAsAttenuation: Cardinal := LOGARITHMIC_ATTENUATION_SINE_TABLE[QuarterPhase];
  var CombinedAttenuation: Cardinal := Add32(PhaseAsAttenuation, Attenuation shl 2);
  var SampleAbsolute: Cardinal := InversePow2(CombinedAttenuation);
  var Sample: Cardinal;
  if PhaseIsInNegativeWave <> 0 then
    Sample := Sub32(0, SampleAbsolute)
  else
    Sample := SampleAbsolute;
  Exit(Sample);
end;

function ComputeFeedbackDivisor(Value: Cardinal): Cardinal;
begin
  Assert(Value <= 9);
  Exit(Sub32(9, Value));
end;

procedure SetAmplitudeModulation(var State: TFMChannel; AmplitudeModulation: Cardinal);
begin
  State.AmplitudeModulationShift := Byte(ArithmeticShiftRight(7, AmplitudeModulation));
end;

procedure FMChannelInitialise(var State: TFMChannel);
begin
  for var ItemIndex := 0 to High(State.Operators) do
  begin
    FMOperatorInitialise(State.Operators[ItemIndex]);
  end;
  State.FeedbackDivisor := Byte(ComputeFeedbackDivisor(0));
  State.Algorithm := 0;
  for var ItemIndex := 0 to High(State.Operator1PreviousSamples) do
  begin
    State.Operator1PreviousSamples[ItemIndex] := 0;
  end;
  SetAmplitudeModulation(State, 0);
  State.PhaseModulationSensitivity := 0;
end;

procedure FMChannelSetFrequencies(var Channel: TFMChannel; Modulation: Cardinal; FNumberAndBlock: Cardinal);
begin
  for var ItemIndex := 0 to High(Channel.Operators) do
  begin
    FMPhaseSetFrequency(Channel.Operators[ItemIndex].Phase, Modulation, Channel.PhaseModulationSensitivity, FNumberAndBlock);
  end;
end;

procedure FMChannelSetFeedbackAndAlgorithm(var Channel: TFMChannel; Feedback: Cardinal; Algorithm: Cardinal);
begin
  Channel.FeedbackDivisor := Byte(ComputeFeedbackDivisor(Feedback));
  Channel.Algorithm := Word(Algorithm);
end;

procedure FMChannelSetPhaseModulationAndSensitivity(var Channel: TFMChannel; PhaseModulation: Cardinal; PhaseModulationSensitivity: Cardinal);
begin
  for var ItemIndex := 0 to High(Channel.Operators) do
  begin
    FMPhaseSetModulationAndSensitivity(Channel.Operators[ItemIndex].Phase, PhaseModulation, PhaseModulationSensitivity);
  end;
end;

procedure FMChannelSetModulationSensitivity(var Channel: TFMChannel; PhaseModulation: Cardinal; Amplitude: Cardinal; Phase: Cardinal);
begin
  SetAmplitudeModulation(Channel, Amplitude);
  Channel.PhaseModulationSensitivity := Byte(Phase);
  FMChannelSetPhaseModulationAndSensitivity(Channel, PhaseModulation, Phase);
end;

procedure FMChannelSetPhaseModulation(var Channel: TFMChannel; PhaseModulation: Cardinal);
begin
  FMChannelSetPhaseModulationAndSensitivity(Channel, PhaseModulation, Channel.PhaseModulationSensitivity);
end;

function FMChannelMixSamples(A: Cardinal; B: Cardinal): Cardinal;
begin
  var Sum: Cardinal := Add32(A, B);
  if (((A and B) and not Sum) and $100) <> 0 then
    Exit(Cardinal(0 - $100));
  if (((not A and not B) and Sum) and $100) <> 0 then
    Exit($FF);
  Exit(Sum);
end;

function FMChannelGetSample(var Channel: TFMChannel; AmplitudeModulation: Cardinal): Cardinal;
begin
  var FeedbackModulation: Cardinal;
  var Operator1Sample: Cardinal;
  var Operator2Sample: Cardinal;
  var Operator3Sample: Cardinal;
  var Operator4Sample: Cardinal;
  var Sample: Cardinal;
  var AmplitudeModulationShift: Cardinal := Cardinal(Channel.AmplitudeModulationShift);

  if Cardinal(Channel.FeedbackDivisor) = ComputeFeedbackDivisor(0) then
    FeedbackModulation := 0
  else
  begin
    FeedbackModulation := Cardinal(ArithmeticShiftRight(Integer(Add32(Channel.Operator1PreviousSamples[0], Channel.Operator1PreviousSamples[1])), Channel.FeedbackDivisor));
    FeedbackModulation := Sub32(FeedbackModulation and Sub32(Cardinal(1) shl (15 - Channel.FeedbackDivisor), 1), FeedbackModulation and (Cardinal(1) shl (15 - Channel.FeedbackDivisor)));
  end;
  case Channel.Algorithm of
    0:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, Operator2Sample);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, Operator3Sample);
        Sample := Operator4Sample shr (14 - 9);
      end;
    1:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, (Add32(Operator1Sample, Operator2Sample)));
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, Operator3Sample);
        Sample := Operator4Sample shr (14 - 9);
      end;
    2:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, Operator2Sample);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, (Add32(Operator1Sample, Operator3Sample)));
        Sample := Operator4Sample shr (14 - 9);
      end;
    3:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, (Add32(Operator2Sample, Operator3Sample)));
        Sample := Operator4Sample shr (14 - 9);
      end;
    4:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, Operator3Sample);
        Sample := Operator2Sample shr (14 - 9);
        Sample := FMChannelMixSamples(Sample, (Operator4Sample shr (14 - 9)));
      end;
    5:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Sample := Operator2Sample shr (14 - 9);
        Sample := FMChannelMixSamples(Sample, (Operator3Sample shr (14 - 9)));
        Sample := FMChannelMixSamples(Sample, (Operator4Sample shr (14 - 9)));
      end;
    6:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, 0);
        Sample := Operator2Sample shr (14 - 9);
        Sample := FMChannelMixSamples(Sample, (Operator3Sample shr (14 - 9)));
        Sample := FMChannelMixSamples(Sample, (Operator4Sample shr (14 - 9)));
      end;
    7:
      begin
        Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
        Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, 0);
        Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, 0);
        Sample := Operator1Sample shr (14 - 9);
        Sample := FMChannelMixSamples(Sample, (Operator2Sample shr (14 - 9)));
        Sample := FMChannelMixSamples(Sample, (Operator3Sample shr (14 - 9)));
        Sample := FMChannelMixSamples(Sample, (Operator4Sample shr (14 - 9)));
      end;
  else
    begin
      Assert(0 <> 0);
      Operator1Sample := FMOperatorProcess(Channel.Operators[0], AmplitudeModulation, AmplitudeModulationShift, FeedbackModulation);
      Operator2Sample := FMOperatorProcess(Channel.Operators[1], AmplitudeModulation, AmplitudeModulationShift, Operator1Sample);
      Operator3Sample := FMOperatorProcess(Channel.Operators[2], AmplitudeModulation, AmplitudeModulationShift, Operator2Sample);
      Operator4Sample := FMOperatorProcess(Channel.Operators[3], AmplitudeModulation, AmplitudeModulationShift, Operator3Sample);
      Sample := Operator4Sample shr (14 - 9);
    end;
  end;
  Channel.Operator1PreviousSamples[1] := Channel.Operator1PreviousSamples[0];
  Channel.Operator1PreviousSamples[0] := Word(Operator1Sample);
  Exit(Sample);
end;

procedure FMLFOInitialise(var State: TFMLFO);
begin
  State.Frequency := 0;
  State.PhaseModulation := 0;
  State.AmplitudeModulation := State.PhaseModulation;
  State.Counter := 0;
  State.SubCounter := Byte(State.Counter);
  State.Enabled := 0;
end;

function FMLFOSetEnabled(var State: TFMLFO; Enabled: Byte): Byte;
begin
  if State.Enabled <> Enabled then
  begin
    State.Enabled := Enabled;
    if Enabled = 0 then
    begin
      State.AmplitudeModulation := 0;
      State.PhaseModulation := State.AmplitudeModulation;
      State.Counter := State.PhaseModulation;
      Exit(1);
    end;
  end;
  Exit(0);
end;

function FMLFOAdvance(var State: TFMLFO): Byte;
const
  THRESHOLDS: array[0..7] of Byte = ($6C, $4D, $47, $43, $3E, $2C, $08, $05);
begin
  var PhaseModulationDivisor: Cardinal;
  var Threshold: Byte := THRESHOLDS[State.Frequency];
  var Temp93: Byte := State.SubCounter;
  Inc(State.SubCounter);
  if (Temp93 and Threshold) = Threshold then
  begin
    State.SubCounter := 0;
    if State.Enabled <> 0 then
    begin
      PhaseModulationDivisor := 4;
      Inc(State.Counter);
      State.Counter := Byte(State.Counter mod $80);
      State.PhaseModulation := Byte(State.Counter div PhaseModulationDivisor);
      State.AmplitudeModulation := Byte(State.Counter * 2);
      if State.AmplitudeModulation >= $80 then
        State.AmplitudeModulation := Byte(State.AmplitudeModulation and $7E)
      else
        State.AmplitudeModulation := Byte(State.AmplitudeModulation xor $7E);
      Exit(Ord(Cardinal(State.Counter mod PhaseModulationDivisor) = 0));
    end;
  end;
  Exit(0);
end;

function FMConvertTimerAValue(Value: Cardinal): Cardinal;
begin
  Exit(Sub32($400, Value));
end;

function FMConvertTimerBValue(Value: Cardinal): Cardinal;
begin
  Exit(Mul32($10, Sub32($100, Value)));
end;

procedure FMInitialise(var Fm: TFM);
begin
  for var ChannelIndex := Low(Fm.State.Channels) to High(Fm.State.Channels) do
  begin
    FMChannelInitialise(Fm.State.Channels[ChannelIndex].State);
    Fm.State.Channels[ChannelIndex].PanLeft := 1;
    Fm.State.Channels[ChannelIndex].PanRight := 1;
  end;
  for var ItemIndex := 0 to High(Fm.State.Channel3Metadata.Frequencies) do
  begin
    Fm.State.Channel3Metadata.Frequencies[ItemIndex] := 0;
  end;
  Fm.State.Channel3Metadata.PerOperatorFrequenciesEnabled := 0;
  Fm.State.Channel3Metadata.CsmModeEnabled := 0;
  Fm.State.Port := 0;
  Fm.State.Address := 0;
  Fm.State.DacSample := $100;
  Fm.State.DacEnabled := 0;
  Fm.State.DacTest := 0;
  Fm.State.RawTimerAValue := 0;
  Fm.State.Timers[0].Value := FMConvertTimerAValue(0);
  Fm.State.Timers[0].Counter := FMConvertTimerAValue(0);
  Fm.State.Timers[0].Enabled := 0;
  Fm.State.Timers[1].Value := FMConvertTimerBValue(0);
  Fm.State.Timers[1].Counter := FMConvertTimerBValue(0);
  Fm.State.Timers[1].Enabled := 0;
  Fm.State.CachedAddress27 := 0;
  Fm.State.CachedUpperFrequencyBitsFM3MultiFrequency := 0;
  Fm.State.CachedUpperFrequencyBits := Fm.State.CachedUpperFrequencyBitsFM3MultiFrequency;
  Fm.State.LeftoverCycles := 0;
  Fm.State.Status := 0;
  Fm.State.BusyFlagCounter := 0;
  FMLFOInitialise(Fm.State.LFO);
end;

procedure FMDoAddress(var Fm: TFM; Port: Cardinal; Address: Cardinal);
begin
  Fm.State.Port := Byte(Mul32(Port, 3));
  Fm.State.Address := Byte(Address);
end;

procedure FMDoData(var Fm: TFM; Data: Cardinal);
const
  TABLE: array[0..7] of Cardinal = (0, 1, 2, $FF, 3, 4, 5, $FF);
  OPERATOR_MAPPINGS: array[0..2] of Byte = (2, 0, 1);
begin
  var Fm3PerOperatorFrequenciesEnabled: Byte;
  var Temp125: Cardinal;
  var ChannelIndex: Cardinal;
  var SlotIndex: Cardinal;
  var ChannelIndexScope102: Cardinal;
  var OperatorIndexScrambled: Cardinal;
  var OperatorIndex: Cardinal;
  var Frequency: Cardinal;
  var OperatorIndexScope104: Cardinal;
  var FrequencyScope105: Cardinal;

  Fm.State.Status := Byte(Fm.State.Status or $80);
  Fm.State.BusyFlagCounter := Byte(32 * 6);
  if Fm.State.Address < $30 then
  begin
    if Fm.State.Port = 0 then
    begin
      case Fm.State.Address of
        $22:
          begin
            if FMLFOSetEnabled(Fm.State.LFO, Ord((Data and 8) <> 0)) <> 0 then
            begin
              for var ModulationChannelIndex := Low(Fm.State.Channels) to High(Fm.State.Channels) do
              begin
                FMChannelSetPhaseModulation(Fm.State.Channels[ModulationChannelIndex].State, Fm.State.LFO.PhaseModulation);
              end;
            end;
            Fm.State.LFO.Frequency := Byte(Data and 7);
          end;
        $24:
          begin
            Fm.State.RawTimerAValue := Word(Fm.State.RawTimerAValue and 3);
            Fm.State.RawTimerAValue := Word(Fm.State.RawTimerAValue or (Data shl 2));
            Fm.State.Timers[0].Value := FMConvertTimerAValue(Fm.State.RawTimerAValue);
          end;
        $25:
          begin
            Fm.State.RawTimerAValue := Word(Fm.State.RawTimerAValue and (not 3));
            Fm.State.RawTimerAValue := Word(Fm.State.RawTimerAValue or (Data and 3));
            Fm.State.Timers[0].Value := FMConvertTimerAValue(Fm.State.RawTimerAValue);
          end;
        $26:
          begin
            Fm.State.Timers[1].Value := FMConvertTimerBValue(Data);
          end;
        $27:
          begin
            Fm3PerOperatorFrequenciesEnabled := Ord((Data and $C0) <> 0);
            for var ItemIndex := 0 to High(Fm.State.Timers) do
            begin
              if ((Data and Cardinal(1 shl (Add32(0, ItemIndex)))) <> 0) and ((Fm.State.CachedAddress27 and (1 shl (Add32(0, ItemIndex)))) = 0) then
                Fm.State.Timers[ItemIndex].Counter := Fm.State.Timers[ItemIndex].Value;
              Fm.State.Timers[ItemIndex].Enabled := Ord((Data and Cardinal(1 shl (Add32(2, ItemIndex)))) <> 0);
              if (Data and Cardinal(1 shl (Add32(4, ItemIndex)))) <> 0 then
                Fm.State.Status := Byte(Fm.State.Status and (not (1 shl ItemIndex)));
            end;
            Fm.State.CachedAddress27 := Byte(Data);
            if Fm.State.Channel3Metadata.PerOperatorFrequenciesEnabled <> Fm3PerOperatorFrequenciesEnabled then
            begin
              Fm.State.Channel3Metadata.PerOperatorFrequenciesEnabled := Fm3PerOperatorFrequenciesEnabled;
              for var IScope99Item := 0 to High(Fm.State.Channels[2].State.Operators) do
              begin
                if Fm3PerOperatorFrequenciesEnabled <> 0 then
                  Temp125 := IScope99Item
                else
                  Temp125 := 3;
                FMPhaseSetFrequency(Fm.State.Channels[2].State.Operators[IScope99Item].Phase, Fm.State.LFO.PhaseModulation, Fm.State.Channels[2].State.PhaseModulationSensitivity, Fm.State.Channel3Metadata.Frequencies[Temp125]);
              end;
            end;
            Fm.State.Channel3Metadata.CsmModeEnabled := Ord((Data and $C0) = $80);
          end;
        $28:
          begin
            ChannelIndex := Cardinal(TABLE[(Data mod Cardinal(Length(TABLE)))]);
            if ChannelIndex <> $FF then
            begin
              for var IScope101Item := 0 to High(Fm.State.Channels[ChannelIndex].State.Operators) do
              begin
                FMOperatorSetKeyOn(Fm.State.Channels[ChannelIndex].State.Operators[IScope101Item], Ord((Data and Cardinal(1 shl (Add32(4, IScope101Item)))) <> 0));
              end;
            end;
          end;
        $2A:
          begin
            Fm.State.DacSample := Word(Fm.State.DacSample and 1);
            Fm.State.DacSample := Word(Fm.State.DacSample or (Data shl 1));
          end;
        $2B:
          begin
            Fm.State.DacEnabled := Ord((Data and $80) <> 0);
          end;
        $2C:
          begin
            Fm.State.DacSample := Word(Fm.State.DacSample and (not 1));
            Fm.State.DacSample := Word(Fm.State.DacSample or ((Data shr 3) and 1));
            Fm.State.DacTest := Ord((Data and $20) <> 0);
          end;
      end;
    end;
  end
  else
  begin
    SlotIndex := Cardinal(Fm.State.Address and 3);
    ChannelIndexScope102 := Add32(Fm.State.Port, SlotIndex);

    if SlotIndex <> 3 then
    begin
      if Fm.State.Address < $A0 then
      begin
        OperatorIndexScrambled := Cardinal(ArithmeticShiftRight(Fm.State.Address, 2) and 3);
        OperatorIndex := ((OperatorIndexScrambled shr 1) or (OperatorIndexScrambled shl 1)) and 3;
        case (Fm.State.Address div $10) of
          (          $30 div $10):
            begin
              FMPhaseSetDetuneAndMultiplier(Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex].Phase, Fm.State.LFO.PhaseModulation, Fm.State.Channels[ChannelIndexScope102].State.PhaseModulationSensitivity, ((Data shr 4) and 7), (Data and $F));
            end;
          (          $40 div $10):
            begin
              FMOperatorSetTotalLevel(Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex], (Data and $7F));
            end;
          (          $50 div $10):
            begin
              FMOperatorSetKeyScaleAndAttackRate(Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex], ((Data shr 6) and 3), (Data and $1F));
            end;
          (          $60 div $10):
            begin
              Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex].Rates[FM_OPERATOR_ENVELOPE_MODE_DECAY] := Word(Data and $1F);
              Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex].AmplitudeModulationOn := Ord((Data and $80) <> 0);
            end;
          (          $70 div $10):
            begin
              Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex].Rates[FM_OPERATOR_ENVELOPE_MODE_SUSTAIN] := Word(Data and $1F);
            end;
          (          $80 div $10):
            begin
              FMOperatorSetSustainLevelAndReleaseRate(Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex], ((Data shr 4) and $F), (Data and $F));
            end;
          (          $90 div $10):
            begin
              FMOperatorSetSSGEG(Fm.State.Channels[ChannelIndexScope102].State.Operators[OperatorIndex], Data);
            end;
        end;
      end
      else
      begin
        case (Fm.State.Address div 4) of
          (          $A0 div 4):
            begin
              repeat
                Frequency := Data or Cardinal(Fm.State.CachedUpperFrequencyBits shl 8);
                if ChannelIndexScope102 = 2 then
                begin
                  Fm.State.Channel3Metadata.Frequencies[3] := Word(Frequency);
                  if Fm.State.Channel3Metadata.PerOperatorFrequenciesEnabled <> 0 then
                  begin
                    FMPhaseSetFrequency(Fm.State.Channels[2].State.Operators[3].Phase, Fm.State.LFO.PhaseModulation, Fm.State.Channels[2].State.PhaseModulationSensitivity, Frequency);
                    Break;
                  end;
                end;
                FMChannelSetFrequencies(Fm.State.Channels[ChannelIndexScope102].State, Fm.State.LFO.PhaseModulation, Frequency);
              until True;
            end;
          (          $A4 div 4):
            begin
              Fm.State.CachedUpperFrequencyBits := Byte(Data and $3F);
            end;
          (          $A8 div 4):
            begin
              if Fm.State.Port = 0 then
              begin
                OperatorIndexScope104 := Cardinal(OPERATOR_MAPPINGS[SlotIndex]);
                FrequencyScope105 := Data or Cardinal(Fm.State.CachedUpperFrequencyBitsFM3MultiFrequency shl 8);
                Fm.State.Channel3Metadata.Frequencies[OperatorIndexScope104] := Word(FrequencyScope105);
                if Fm.State.Channel3Metadata.PerOperatorFrequenciesEnabled <> 0 then
                  FMPhaseSetFrequency(Fm.State.Channels[2].State.Operators[OperatorIndexScope104].Phase, Fm.State.LFO.PhaseModulation, Fm.State.Channels[2].State.PhaseModulationSensitivity, FrequencyScope105);
              end;
            end;
          (          $AC div 4):
            begin
              Fm.State.CachedUpperFrequencyBitsFM3MultiFrequency := Byte(Data and $3F);
            end;
          (          $B0 div 4):
            begin
              FMChannelSetFeedbackAndAlgorithm(Fm.State.Channels[ChannelIndexScope102].State, ((Data shr 3) and 7), (Data and 7));
            end;
          (          $B4 div 4):
            begin
              Fm.State.Channels[ChannelIndexScope102].PanLeft := Ord((Data and $80) <> 0);
              Fm.State.Channels[ChannelIndexScope102].PanRight := Ord((Data and $40) <> 0);
              FMChannelSetModulationSensitivity(Fm.State.Channels[ChannelIndexScope102].State, Fm.State.LFO.PhaseModulation, ((Data shr 4) and 3), (Data and 7));
            end;
        end;
      end;
    end;
  end;
end;

function GetFinalSample(var Fm: TFM; Sample: Integer; Enabled: Byte): Integer;
begin
  var Offset: Integer;
  var Temp147: Integer;
  var Temp148: Integer;
  if Fm.Configuration.LadderEffectDisabled <> 0 then
    Offset := 0
  else
  begin
    if Sample < 0 then
    begin
      Inc(Sample);
      Offset := -4;
    end
    else
      Offset := 4;
  end;
  if Enabled = 0 then
    Sample := 0;
  if Fm.State.DacTest <> 0 then
  begin
    Sample := Integer(Sample * 4);
    if $FF < Sample then
      Temp148 := $FF
    else
      Temp148 := Sample;
    if -$FF > Temp148 then
      Temp147 := -$FF
    else
    begin
      if $FF < Sample then
        Temp147 := $FF
      else
        Temp147 := Sample;
    end;
    Sample := Temp147;
  end
  else
    Sample := Integer(Sample + Offset);
  Exit(Integer((Sample * (1 shl (16 - 9))) div 8));
end;

function FMToNativeSigned(Value: Cardinal): Integer;
begin
  Exit(Integer(Sub32(Cardinal(Integer(Value)) and Sub32(Cardinal(1) shl (9 - 1), 1), Cardinal(Integer(Value)) and (Cardinal(1) shl (9 - 1)))));
end;

procedure FMOutputSamples(var Fm: TFM; var SampleBuffer: array of SmallInt);
begin
  var PanLeft: Byte;
  var PanRight: Byte;
  var IsDac: Byte;
  var Temp158: Integer;
  var ChannelDisabled: Byte;
  var FmSample: Integer;
  var Sample: Integer;

  var DacSample: Integer := FMToNativeSigned(Fm.State.DacSample xor $100);
  if Odd(Length(SampleBuffer)) then
    raise EArgumentException.Create('FM output requires complete stereo frames');
  for var FrameIndex := 0 to Length(SampleBuffer) div 2 - 1 do
  begin
    var SampleIndex := FrameIndex * 2;
    if FMLFOAdvance(Fm.State.LFO) <> 0 then
    begin
      for var ModulationChannelIndex := Low(Fm.State.Channels) to High(Fm.State.Channels) do
      begin
        FMChannelSetPhaseModulation(Fm.State.Channels[ModulationChannelIndex].State, Fm.State.LFO.PhaseModulation);
      end;
    end;
    for var ChannelIndex := 0 to High(Fm.State.Channels) do
    begin
      PanLeft := Fm.State.Channels[ChannelIndex].PanLeft;
      PanRight := Fm.State.Channels[ChannelIndex].PanRight;
      Temp158 := Ord((ChannelIndex = 5) and (Fm.State.DacEnabled <> 0));
      IsDac := Byte(Ord((Temp158 <> 0) or (Fm.State.DacTest <> 0)));
      if IsDac <> 0 then
        ChannelDisabled := Fm.Configuration.DacChannelDisabled
      else
        ChannelDisabled := Fm.Configuration.FMChannelsDisabled[ChannelIndex];
      FmSample := FMToNativeSigned(FMChannelGetSample(Fm.State.Channels[ChannelIndex].State, Fm.State.LFO.AmplitudeModulation));
      if IsDac <> 0 then
        Sample := DacSample
      else
        Sample := FmSample;
      if ChannelDisabled = 0 then
      begin
        SampleBuffer[SampleIndex] := SmallInt(SampleBuffer[SampleIndex] + GetFinalSample(Fm, Sample, PanLeft));
        SampleBuffer[SampleIndex + 1] := SmallInt(SampleBuffer[SampleIndex + 1] + GetFinalSample(Fm, Sample, PanRight));
      end;
    end;
    for var TimerIndex := 0 to High(Fm.State.Timers) do
    begin
      Dec(Fm.State.Timers[TimerIndex].Counter);
      if Fm.State.Timers[TimerIndex].Counter = 0 then
      begin
        if Fm.State.Timers[TimerIndex].Enabled <> 0 then
          Fm.State.Status := Byte(Fm.State.Status or 1 shl TimerIndex);
        Fm.State.Timers[TimerIndex].Counter := Fm.State.Timers[TimerIndex].Value;
        if (Fm.State.Channel3Metadata.CsmModeEnabled <> 0) and (TimerIndex = 0) then
        begin
          for var OperatorIndex := 0 to High(Fm.State.Channels[2].State.Operators) do
          begin
            FMOperatorSetKeyOn(Fm.State.Channels[2].State.Operators[OperatorIndex], 1);
            FMOperatorSetKeyOn(Fm.State.Channels[2].State.Operators[OperatorIndex], 0);
          end;
        end;
      end;
    end;
  end;
end;

function FMUpdate(var Fm: TFM; CyclesToDo: Cardinal; FmAudioToBeGenerated: TFMAudioCallback; UserData: Pointer): Cardinal;
begin
  var Temp168: Byte;

  var TotalFrames: Cardinal := Cardinal(Add32(Fm.State.LeftoverCycles, CyclesToDo) div Cardinal((6 * 6) * 4));
  Fm.State.LeftoverCycles := Byte(Add32(Fm.State.LeftoverCycles, CyclesToDo) mod Cardinal((6 * 6) * 4));
  if TotalFrames <> 0 then
    FmAudioToBeGenerated(UserData, TotalFrames);
  if Fm.State.BusyFlagCounter <> 0 then
  begin
    if Cardinal(Fm.State.BusyFlagCounter) < CyclesToDo then
      Temp168 := Fm.State.BusyFlagCounter
    else
      Temp168 := CyclesToDo;
    Fm.State.BusyFlagCounter := Byte(Fm.State.BusyFlagCounter - Temp168);
    if Fm.State.BusyFlagCounter = 0 then
      Fm.State.Status := Byte(Fm.State.Status and (not $80));
  end;
  Exit(Cardinal(Fm.State.Status));
end;

end.

