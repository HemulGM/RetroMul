unit GB.Sound;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, System.Math, GB.Memory,
  PCM.Audio, PCM.Audio.Backend, Core.AudioFilter;

const
  GB_AUDIO_SAMPLE_RATE = 44100;
  GB_AUDIO_OVERSAMPLE = 4;
  GB_AUDIO_INTERNAL_RATE = GB_AUDIO_SAMPLE_RATE * GB_AUDIO_OVERSAMPLE;
  GB_AUDIO_CHANNELS = 2;
  GB_AUDIO_BLOCK_SAMPLES = 2048;
  GB_AUDIO_BLOCK_COUNT = 4;

type
  TIntegerArray = array of Integer;

  TEnvelope = class
  private
    FBase: Integer;
    FDirection: Integer;
    FStepLength: Integer;
    FIndex: Integer;
  public
    function GetBase: Integer;
    procedure SetBase(Value: Integer);

    function GetDirection: Integer;
    procedure SetDirection(Value: Integer);

    function GetStepLength: Integer;
    procedure SetStepLength(Value: Integer);

    function GetIndex: Integer;
    procedure SetIndex(Value: Integer);

    procedure HandleSweep;
    procedure SerializeState(State: TStateArchive);
  end;

  TBaseChannel = class
  private
    FEnabled: Boolean;
    FLengthEnabled: Boolean;
    FLength: Integer;
    FFrequency: Double;
    FIndex: Integer;
    FWave: TIntegerArray;
    FWavePhase: Double;
  public
    function IsEnabled: Boolean;
    procedure SetEnabled(Value: Boolean);

    function IsLengthEnabled: Boolean;
    procedure SetLengthEnabled(Value: Boolean);

    function GetLength: Integer;
    procedure SetLength(Value: Integer);
    procedure DecLength;

    function GetFrequency: Double;
    procedure SetFrequency(Value: Double);

    function GetIndex: Integer;
    procedure SetIndex(Value: Integer);
    procedure IncIndex;

    function GetWave: TIntegerArray;
    function GetWaveValue(Index: Integer): Integer;
    procedure SetWave(const Value: TIntegerArray);
    function NextWaveSample(VolumeShift: Integer = 0): Double;
    procedure SerializeState(State: TStateArchive); virtual;
  end;

const
  SoundWavePattern: array[0..3, 0..31] of Integer = (
    (1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1),
    (1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1, -1)
  );

type
  TSquareWaveChannel = class(TBaseChannel)
  private
    FVolume: TEnvelope;
    FGBFrequency: Integer;
    FSweepIndex: Integer;
    FSweepLength: Integer;
    FSweepDirection: Integer;
    FSweepShift: Integer;
    FWaveDuty: Integer;
  public
    destructor Destroy; override;

    function GetVolume: TEnvelope;
    procedure SetVolume(Value: TEnvelope);

    function GetGBFrequency: Integer;
    procedure SetGBFrequency(Value: Integer);

    function GetSweepIndex: Integer;
    procedure SetSweepIndex(Value: Integer);
    procedure DecSweepIndex;

    function GetSweepLength: Integer;
    procedure SetSweepLength(Value: Integer);

    function GetSweepDirection: Integer;
    procedure SetSweepDirection(Value: Integer);

    function GetSweepShift: Integer;
    procedure SetSweepShift(Value: Integer);

    procedure SetWaveDuty(Value: Integer);
    procedure SerializeState(State: TStateArchive); override;
  end;

  TWaveChannel = class(TBaseChannel)
  end;

  TNoiseChannel = class(TBaseChannel)
  private
    FVolume: TEnvelope;

    FShiftFrequency: Integer;
    FCounterStep: Integer;
    FDivisorRatio: Double;

    FLFSR: Word;
    FPhase: Double;
  public
    constructor Create;
    destructor Destroy; override;

    function GetVolume: TEnvelope;
    procedure SetVolume(Value: TEnvelope);

    function GetShiftFrequency: Integer;
    procedure SetShiftFrequency(Value: Integer);

    function GetCounterStep: Integer;
    procedure SetCounterStep(Value: Integer);

    function GetDivisorRatio: Double;
    procedure SetDivisorRatio(Value: Double);

    procedure ResetLFSR;
    function NextSample: Double;
    procedure SerializeState(State: TStateArchive); override;
  end;

  TGBHardwareChannel = record
    Enabled, DAC, LengthEnabled, EnvelopeStopped, EnvelopeUp: Boolean;
    SweepEnabled, SweepNegated: Boolean;
    Length, Frequency, Timer, Position, Output, Volume: Integer;
    EnvelopePeriod, EnvelopeTimer, SweepPeriod, SweepTimer, SweepShift: Integer;
    SweepShadow, WaveBuffer, WaveAccessClocks, DACCounter, DACVolume: Integer;
    LFSR: Word;
  end;

  TGBSound = class
  private
    const
      NR10 = $FF10;
      NR11 = $FF11;
      NR12 = $FF12;
      NR13 = $FF13;
      NR14 = $FF14;

      NR21 = $FF16;
      NR22 = $FF17;
      NR23 = $FF18;
      NR24 = $FF19;

      NR30 = $FF1A;
      NR31 = $FF1B;
      NR32 = $FF1C;
      NR33 = $FF1D;
      NR34 = $FF1E;

      NR41 = $FF20;
      NR42 = $FF21;
      NR43 = $FF22;
      NR44 = $FF23;

      NR50 = $FF24;
      NR51 = $FF25;
      NR52 = $FF26;

  private
    FMemory: TGBMemory;

    FChannel1: TSquareWaveChannel;
    FChannel2: TSquareWaveChannel;
    FChannel3: TWaveChannel;
    FChannel4: TNoiseChannel;

    FAudio: TPCMAudio;
    FOnPCM: TProc<TArray<SmallInt>, Integer>;

    FSoundTimer: Double;
    FSoundBufferIndex: Integer;

    // Текущий уровень каждого аппаратного канала.
    FChannelSamples: array[0..3] of Double;
    FOutputPhase: Integer;
    FFilter: array[0..1] of TPCMLowPass;
    FDCFilter: array[0..1] of TPCMDCBlocker;

    // Interleaved stereo PCM16.
    FMixedBuffer: array[0..GB_AUDIO_BLOCK_SAMPLES * GB_AUDIO_CHANNELS - 1] of SmallInt;
    FVolume: Single;
    FChannelVolumes: array[0..3] of Single;
    FHardware: array[0..3] of TGBHardwareChannel;
    FFrameStep, FSkipFrame: Integer;
    FIntegrated: array[0..3] of Double;
    FIntegratedClocks: Integer;
    procedure SetVolume(const Value: Single);
    procedure ClockFrameSequencer;
    procedure WriteHardware(Address: Integer; Value: Byte);
    function ReadHardware(Address: Integer): Byte;
    procedure Trigger(Index: Integer);
    procedure ClockChannel(Index: Integer); {$IFNDEF CPUX86} inline;{$ENDIF}
    procedure UpdateOutput(Index: Integer);
    procedure SyncChannels;
    function SweepFrequency: Integer;
    procedure ClockEnvelope(Index: Integer);
    procedure WriteEnvelope(Index: Integer; Value: Byte);
    function ChannelPeriod(Index: Integer): Integer;
    procedure MixSound;
    procedure FlushBuffer;
    function IsSoundToTerminal(ChannelNumber: Integer; OutputNumber: Integer): Boolean;
    function GetSoundLevel(OutputNumber: Integer): Integer;
    function ReadRegister(Address: Integer): Byte; inline;

  public
    constructor Create(AMemory: TGBMemory; EnableOutput: Boolean = True; const Backend: IPCMAudioBackend = nil); overload;
    destructor Destroy; override;

    function ReadPCM(Address: Integer): Byte;
    procedure SetChannelVolume(Index: Integer; Value: Single);
    procedure StartAudio;
    procedure UpdateSound(Cycle: Integer);
    procedure PlaySound;
    procedure FlushPCM;

    property Channel1: TSquareWaveChannel read FChannel1;
    property Channel2: TSquareWaveChannel read FChannel2;
    property Channel3: TWaveChannel read FChannel3;
    property Channel4: TNoiseChannel read FChannel4;

    property BufferIndex: Integer read FSoundBufferIndex;

    // 0.0 = mute
    // 1.0 = 100%
    property Volume: Single read FVolume write SetVolume;

    property Audio: TPCMAudio read FAudio;
    // Optional host sink; used with EnableOutput=False by music decoders.
    property OnPCM: TProc<TArray<SmallInt>, Integer> read FOnPCM write FOnPCM;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

{$IFNDEF CPUX86}

var
  // The DAC numerator is an integer in [-1500, 1500]. Keep Extended here
  // to preserve the original expression precision on each target.
  DACLevels: array[-1500..1500] of Extended;

procedure InitializeDACLevels;
begin
  for var Numerator := Low(DACLevels) to High(DACLevels) do
    DACLevels[Numerator] := Numerator / 100;
end;
{$ENDIF}

{ TEnvelope }

function TEnvelope.GetBase: Integer;
begin
  Result := FBase;
end;

procedure TEnvelope.SetBase(Value: Integer);
begin
  FBase := EnsureRange(Value, 0, 15);
end;

function TEnvelope.GetDirection: Integer;
begin
  Result := FDirection;
end;

procedure TEnvelope.SetDirection(Value: Integer);
begin
  FDirection := Value;
end;

function TEnvelope.GetStepLength: Integer;
begin
  Result := FStepLength;
end;

procedure TEnvelope.SetStepLength(Value: Integer);
begin
  FStepLength := Value;
end;

function TEnvelope.GetIndex: Integer;
begin
  Result := FIndex;
end;

procedure TEnvelope.SetIndex(Value: Integer);
begin
  FIndex := Value;
end;

procedure TEnvelope.HandleSweep;
begin
  if FStepLength <= 0 then
    Exit;

  if FIndex <= 0 then
    FIndex := FStepLength;

  Dec(FIndex);

  if FIndex > 0 then
    Exit;

  FIndex := FStepLength;

  if FDirection > 0 then
  begin
    if FBase < 15 then
      Inc(FBase);
  end
  else
  begin
    if FBase > 0 then
      Dec(FBase);
  end;
end;

{ TBaseChannel }

function TBaseChannel.IsEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure TBaseChannel.SetEnabled(Value: Boolean);
begin
  FEnabled := Value;
end;

function TBaseChannel.IsLengthEnabled: Boolean;
begin
  Result := FLengthEnabled;
end;

procedure TBaseChannel.SetLengthEnabled(Value: Boolean);
begin
  FLengthEnabled := Value;
end;

function TBaseChannel.GetLength: Integer;
begin
  Result := FLength;
end;

procedure TBaseChannel.SetLength(Value: Integer);
begin
  FLength := Value;
end;

procedure TBaseChannel.DecLength;
begin
  if FLength > 0 then
    Dec(FLength);
end;

function TBaseChannel.GetFrequency: Double;
begin
  Result := FFrequency;
end;

procedure TBaseChannel.SetFrequency(Value: Double);
begin
  FFrequency := Value;
end;

function TBaseChannel.GetIndex: Integer;
begin
  Result := FIndex;
end;

procedure TBaseChannel.SetIndex(Value: Integer);
begin
  FIndex := Value;
  FWavePhase := 0;
end;

procedure TBaseChannel.IncIndex;
begin
  Inc(FIndex);
end;

function TBaseChannel.GetWave: TIntegerArray;
begin
  Result := Copy(FWave);
end;

function TBaseChannel.GetWaveValue(Index: Integer): Integer;
begin
  if Length(FWave) = 0 then
    Exit(0);

  Index := Index mod Length(FWave);

  if Index < 0 then
    Inc(Index, Length(FWave));

  Result := FWave[Index];
end;

procedure TBaseChannel.SetWave(const Value: TIntegerArray);
begin
  FWave := Copy(Value);
end;

function TBaseChannel.NextWaveSample(VolumeShift: Integer): Double;
var
  Step, Remaining, Span, Area: Double;
  Position, Value: Integer;
begin
  if Length(FWave) = 0 then
    Exit(0);
  Step := GetFrequency * Length(FWave) / GB_AUDIO_INTERNAL_RATE;
  if Step <= 0 then
    Exit(FWave[Trunc(FWavePhase)]);

  Remaining := Step;
  Area := 0;

  // Integrate every transition, including pulses shorter than an output sample.
  while Remaining > 1E-10 do
  begin
    Position := Trunc(FWavePhase);
    Span := Min(Remaining, Position + 1.0 - FWavePhase);
    Value := FWave[Position];
    if VolumeShift > 0 then
      Value := Value shr VolumeShift;
    Area := Area + Value * Span;
    FWavePhase := FWavePhase + Span;
    if FWavePhase >= Length(FWave) then
      FWavePhase := 0;
    Remaining := Remaining - Span;
  end;
  Result := Area / Step;
end;

{ TSquareWaveChannel }

destructor TSquareWaveChannel.Destroy;
begin
  FVolume.Free;
  inherited;
end;

function TSquareWaveChannel.GetVolume: TEnvelope;
begin
  Result := FVolume;
end;

procedure TSquareWaveChannel.SetVolume(Value: TEnvelope);
begin
  if FVolume <> Value then
    FVolume.Free;

  FVolume := Value;
end;

function TSquareWaveChannel.GetGBFrequency: Integer;
begin
  Result := FGBFrequency;
end;

procedure TSquareWaveChannel.SetGBFrequency(Value: Integer);
begin
  FGBFrequency := Value;
end;

function TSquareWaveChannel.GetSweepIndex: Integer;
begin
  Result := FSweepIndex;
end;

procedure TSquareWaveChannel.SetSweepIndex(Value: Integer);
begin
  FSweepIndex := Value;
end;

procedure TSquareWaveChannel.DecSweepIndex;
begin
  if FSweepIndex > 0 then
    Dec(FSweepIndex);
end;

function TSquareWaveChannel.GetSweepLength: Integer;
begin
  Result := FSweepLength;
end;

procedure TSquareWaveChannel.SetSweepLength(Value: Integer);
begin
  FSweepLength := Value;
end;

function TSquareWaveChannel.GetSweepDirection: Integer;
begin
  Result := FSweepDirection;
end;

procedure TSquareWaveChannel.SetSweepDirection(Value: Integer);
begin
  FSweepDirection := Value;
end;

function TSquareWaveChannel.GetSweepShift: Integer;
begin
  Result := FSweepShift;
end;

procedure TSquareWaveChannel.SetSweepShift(Value: Integer);
begin
  FSweepShift := Value;
end;

procedure TSquareWaveChannel.SetWaveDuty(Value: Integer);
begin
  Value := Value and 3;
  if (FWaveDuty = Value) and (Length(FWave) = 32) then
    Exit;

  FWaveDuty := Value;
  var Wave: TIntegerArray;
  System.SetLength(Wave, 32);

  for var i := 0 to 31 do
    Wave[i] := SoundWavePattern[Value, i];

  SetWave(Wave);
end;

{ TNoiseChannel }

constructor TNoiseChannel.Create;
begin
  inherited;
  FLFSR := $7FFF;
  FPhase := 0;
end;

destructor TNoiseChannel.Destroy;
begin
  FVolume.Free;
  inherited;
end;

function TNoiseChannel.GetVolume: TEnvelope;
begin
  Result := FVolume;
end;

procedure TNoiseChannel.SetVolume(Value: TEnvelope);
begin
  if FVolume <> Value then
    FVolume.Free;

  FVolume := Value;
end;

function TNoiseChannel.GetShiftFrequency: Integer;
begin
  Result := FShiftFrequency;
end;

procedure TNoiseChannel.SetShiftFrequency(Value: Integer);
begin
  FShiftFrequency := Value;
end;

function TNoiseChannel.GetCounterStep: Integer;
begin
  Result := FCounterStep;
end;

procedure TNoiseChannel.SetCounterStep(Value: Integer);
begin
  FCounterStep := Value;
end;

function TNoiseChannel.GetDivisorRatio: Double;
begin
  Result := FDivisorRatio;
end;

procedure TNoiseChannel.SetDivisorRatio(Value: Double);
begin
  FDivisorRatio := Value;
end;

procedure TNoiseChannel.ResetLFSR;
begin
  FLFSR := $7FFF;
  FPhase := 0;
end;

function TNoiseChannel.NextSample: Double;
var
  Feedback: Word;
  Step, Remaining, Span, Area, Level: Double;
begin
  Step := GetFrequency / GB_AUDIO_INTERNAL_RATE;
  if Step <= 0 then
  begin
    if (FLFSR and 1) = 0 then
      Exit(1)
    else
      Exit(-1);
  end;

  Remaining := Step;
  Area := 0;
  while Remaining > 1E-10 do
  begin
    if (FLFSR and 1) = 0 then
      Level := 1
    else
      Level := -1;
    Span := Min(Remaining, 1.0 - FPhase);
    Area := Area + Level * Span;
    FPhase := FPhase + Span;
    Remaining := Remaining - Span;
    if FPhase >= 1.0 then
    begin
      FPhase := 0;
      Feedback := (FLFSR xor (FLFSR shr 1)) and 1;
      FLFSR := (FLFSR shr 1) or (Feedback shl 14);
      if FCounterStep <> 0 then
        FLFSR := (FLFSR and not $40) or (Feedback shl 6);
    end;
  end;
  Result := Area / Step;
end;

{ TGBSound }

constructor TGBSound.Create(AMemory: TGBMemory; EnableOutput: Boolean; const Backend: IPCMAudioBackend);
begin
  inherited Create;

  if AMemory = nil then
    raise EArgumentNilException.Create('Memory must not be nil');

  FMemory := AMemory;

  FChannel1 := TSquareWaveChannel.Create;
  FChannel2 := TSquareWaveChannel.Create;
  FChannel3 := TWaveChannel.Create;
  FChannel4 := TNoiseChannel.Create;

  FVolume := 1.0;
  for var i := 0 to 3 do
    FChannelVolumes[i] := 1.0;

  var AudioFormat: TPCMAudioFormat;
  AudioFormat.SampleRate := GB_AUDIO_SAMPLE_RATE;
  AudioFormat.Channels := GB_AUDIO_CHANNELS;
  AudioFormat.BlockFrames := GB_AUDIO_BLOCK_SAMPLES;
  AudioFormat.BlockCount := GB_AUDIO_BLOCK_COUNT;

  if Backend <> nil then
    FAudio := TPCMAudio.Create(AudioFormat, Backend)
  else if EnableOutput then
    FAudio := TPCMAudio.Create(AudioFormat)
  else
    FAudio := nil;

  FChannel1.SetVolume(TEnvelope.Create);
  FChannel2.SetVolume(TEnvelope.Create);
  FChannel4.SetVolume(TEnvelope.Create);
  StartAudio;
  FMemory.AudioRead := ReadHardware;
  FMemory.AudioWrite := WriteHardware;
  FMemory.PCMRead := ReadPCM;
  FMemory.Timer.OnFrameSequencer := ClockFrameSequencer;
end;

destructor TGBSound.Destroy;
begin
  FMemory.AudioRead := nil;
  FMemory.AudioWrite := nil;
  FMemory.PCMRead := nil;
  FMemory.Timer.OnFrameSequencer := nil;
  if Assigned(FAudio) then
    FAudio.Clear;

  FAudio.Free;

  FChannel4.Free;
  FChannel3.Free;
  FChannel2.Free;
  FChannel1.Free;

  inherited;
end;

procedure TGBSound.SetChannelVolume(Index: Integer; Value: Single);
begin
  if (Index < 0) or (Index > 3) then
    raise EArgumentOutOfRangeException.Create('Audio channel');

  if IsNan(Value) or IsInfinite(Value) then
    Value := 1;
  FChannelVolumes[Index] := EnsureRange(Value, 0.0, 1.0);
end;

procedure TGBSound.SetVolume(const Value: Single);
begin
  FVolume := EnsureRange(Value, 0.0, 1.0);
end;

procedure TGBSound.StartAudio;
begin
  FSoundTimer := 0;
  FOutputPhase := 0;
  FSoundBufferIndex := 0;
  FFrameStep := 0;
  FSkipFrame := 0;
  FillChar(FHardware, SizeOf(FHardware), 0);
  FillChar(FIntegrated, SizeOf(FIntegrated), 0);
  FIntegratedClocks := 0;
  FillChar(FChannelSamples, SizeOf(FChannelSamples), 0);
  FillChar(FMixedBuffer, SizeOf(FMixedBuffer), 0);
  for var i := 0 to 1 do
  begin
    FFilter[i].Configure(GB_AUDIO_INTERNAL_RATE, 12000);
    FFilter[i].Reset;
    FDCFilter[i].Configure(GB_AUDIO_INTERNAL_RATE, 20);
    FDCFilter[i].Reset;
  end;
  SyncChannels;
  if Assigned(FAudio) then
    FAudio.Clear;
end;

function TGBSound.ReadRegister(Address: Integer): Byte;
begin
  Result := FMemory.IOPort[Address - $FF00];
end;

function TGBSound.ReadHardware(Address: Integer): Byte;
const
  Masks: array[0..$1F] of Byte = (
    $80, $3F, $00, $FF, $BF, $FF, $3F, $00, $FF, $BF, $7F, $FF, $9F, $FF, $BF, $FF,
    $FF, $00, $00, $BF, $00, $00, $70, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF);
begin
  if Address >= $FF30 then
  begin
    if FHardware[2].Enabled then
    begin
      if not FMemory.IsCGBHardware and (FHardware[2].WaveAccessClocks = 0) then
        Exit($FF);
      Address := $FF30 + FHardware[2].Position div 2;
    end;
    Exit(ReadRegister(Address));
  end;

  Result := ReadRegister(Address) or Masks[Address - $FF10];
end;

function TGBSound.ChannelPeriod(Index: Integer): Integer;
const
  NoiseDivisors: array[0..7] of Integer = (8, 16, 32, 48, 64, 80, 96, 112);
begin
  if Index < 2 then
    Result := (2048 - FHardware[Index].Frequency) * 4
  else if Index = 2 then
    Result := (2048 - FHardware[Index].Frequency) * 2
  else
    Result := NoiseDivisors[ReadRegister(NR43) and 7] shl (ReadRegister(NR43) shr 4);
end;

procedure TGBSound.SyncChannels;
begin
  FChannel1.SetEnabled(FHardware[0].Enabled);
  FChannel2.SetEnabled(FHardware[1].Enabled);
  FChannel3.SetEnabled(FHardware[2].Enabled);
  FChannel4.SetEnabled(FHardware[3].Enabled);
  FChannel1.GetVolume.SetBase(FHardware[0].Volume);
  FChannel2.GetVolume.SetBase(FHardware[1].Volume);
  FChannel4.GetVolume.SetBase(FHardware[3].Volume);
  var Status := ReadRegister(NR52) and $80;
  for var i := 0 to 3 do
    if FHardware[i].Enabled then
      Status := Status or (1 shl i);
  FMemory.IOPort[$26] := Status;
end;

procedure TGBSound.UpdateOutput(Index: Integer);
const
  Duty: array[0..3] of Byte = ($01, $81, $87, $7E);
begin
  FHardware[Index].Output := 0;
  if not FHardware[Index].Enabled then
    Exit;

  if Index < 2 then
  begin
    var RegisterOffset := $11 + Index * 5;
    if ((Duty[FMemory.IOPort[RegisterOffset] shr 6] shr FHardware[Index].Position) and 1) <> 0 then
      FHardware[Index].Output := FHardware[Index].Volume;
  end
  else if Index = 2 then
  begin
    var Shift := (ReadRegister(NR32) shr 5) and 3;
    if Shift = 0 then
      Exit;

    var Value := FHardware[2].WaveBuffer;
    if (FHardware[2].Position and 1) = 0 then
      Value := Value shr 4;
    FHardware[2].Output := (Value and 15) shr (Shift - 1);
  end
  else if (FHardware[3].LFSR and 1) = 0 then
    FHardware[3].Output := FHardware[3].Volume;
end;

procedure TGBSound.ClockChannel(Index: Integer);
begin
  if FHardware[Index].WaveAccessClocks > 0 then
    Dec(FHardware[Index].WaveAccessClocks);
  Dec(FHardware[Index].Timer);
  if FHardware[Index].Timer <= 0 then
  begin
    Inc(FHardware[Index].Timer, ChannelPeriod(Index));
    if Index < 2 then
      FHardware[Index].Position := (FHardware[Index].Position + 1) and 7
    else if Index = 2 then
    begin
      if FHardware[2].Enabled then
      begin
        FHardware[2].Position := (FHardware[2].Position + 1) and 31;
        FHardware[2].WaveBuffer := FMemory.IOPort[$30 + FHardware[2].Position div 2];
        FHardware[2].WaveAccessClocks := 2;
      end;
    end
    else if (ReadRegister(NR43) shr 4) < 14 then
    begin
      var Bit := (FHardware[3].LFSR xor (FHardware[3].LFSR shr 1)) and 1;
      FHardware[3].LFSR := (FHardware[3].LFSR shr 1) or (Bit shl 14);
      if (ReadRegister(NR43) and 8) <> 0 then
        FHardware[3].LFSR := (FHardware[3].LFSR and $7FBF) or (Bit shl 6);
    end;
    UpdateOutput(Index);
  end;
  Dec(FHardware[Index].DACCounter);
  if FHardware[Index].DACCounter <= 0 then
  begin
    FHardware[Index].DACCounter := 250;
    if FHardware[Index].DAC then
      FHardware[Index].DACVolume := Min(100, FHardware[Index].DACVolume + 1)
    else
      FHardware[Index].DACVolume := Max(0, FHardware[Index].DACVolume - 1);
  end;
end;

procedure TGBSound.ClockEnvelope(Index: Integer);
begin
  if FHardware[Index].EnvelopeTimer > 0 then
    Dec(FHardware[Index].EnvelopeTimer);

  if FHardware[Index].EnvelopeTimer <> 0 then
    Exit;

  FHardware[Index].EnvelopeTimer := FHardware[Index].EnvelopePeriod;
  if FHardware[Index].EnvelopeTimer = 0 then
    FHardware[Index].EnvelopeTimer := 8;

  if (FHardware[Index].EnvelopePeriod = 0) or FHardware[Index].EnvelopeStopped then
    Exit;

  var NewVolume := FHardware[Index].Volume;
  if FHardware[Index].EnvelopeUp then
    Inc(NewVolume)
  else
    Dec(NewVolume);
  if (NewVolume >= 0) and (NewVolume <= 15) then
    FHardware[Index].Volume := NewVolume
  else
    FHardware[Index].EnvelopeStopped := True;
  UpdateOutput(Index);
end;

function TGBSound.SweepFrequency: Integer;
begin
  var Delta := FHardware[0].SweepShadow shr FHardware[0].SweepShift;
  if (ReadRegister(NR10) and 8) <> 0 then
  begin
    Result := FHardware[0].SweepShadow - Delta;
    FHardware[0].SweepNegated := True;
  end
  else
    Result := FHardware[0].SweepShadow + Delta;
  if Result > 2047 then
    FHardware[0].Enabled := False;
end;

procedure TGBSound.ClockFrameSequencer;
begin
  if (ReadRegister(NR52) and $80) = 0 then
    Exit;

  if FSkipFrame > 0 then
  begin
    Dec(FSkipFrame);
    Exit;
  end;

  if (FFrameStep and 1) = 0 then
    for var i := 0 to 3 do
      if FHardware[i].LengthEnabled and (FHardware[i].Length > 0) then
      begin
        Dec(FHardware[i].Length);
        if FHardware[i].Length = 0 then
          FHardware[i].Enabled := False;
        UpdateOutput(i);
      end;

  if (FFrameStep = 2) or (FFrameStep = 6) then
  begin
    if FHardware[0].SweepTimer > 0 then
      Dec(FHardware[0].SweepTimer);
    if FHardware[0].SweepTimer = 0 then
    begin
      FHardware[0].SweepTimer := FHardware[0].SweepPeriod;
      if FHardware[0].SweepTimer = 0 then
        FHardware[0].SweepTimer := 8;
      if FHardware[0].SweepEnabled and (FHardware[0].SweepPeriod > 0) then
      begin
        var Frequency := SweepFrequency;
        if (Frequency <= 2047) and (FHardware[0].SweepShift > 0) then
        begin
          FHardware[0].Frequency := Frequency;
          FHardware[0].SweepShadow := Frequency;
          FMemory.IOPort[$13] := Frequency and $FF;
          FMemory.IOPort[$14] := (FMemory.IOPort[$14] and $F8) or (Frequency shr 8);
          SweepFrequency;
        end;
      end;
    end;
  end;
  if FFrameStep = 7 then
  begin
    ClockEnvelope(0);
    ClockEnvelope(1);
    ClockEnvelope(3);
  end;
  FFrameStep := (FFrameStep + 1) and 7;
  SyncChannels;
end;

procedure TGBSound.WriteEnvelope(Index: Integer; Value: Byte);
begin
  var Up := (Value and 8) <> 0;
  var Period := Value and 7;
  if FHardware[Index].Enabled and ((Value and $F8) <> 0) then
  begin
    var PreventIncrement := False;
    if Up <> FHardware[Index].EnvelopeUp then
    begin
      if Up then
      begin
        if not FHardware[Index].EnvelopeStopped and (FHardware[Index].EnvelopePeriod = 0) then
          FHardware[Index].Volume := FHardware[Index].Volume xor 15
        else
          FHardware[Index].Volume := 14 - FHardware[Index].Volume;
        PreventIncrement := True;
      end
      else
        FHardware[Index].Volume := 16 - FHardware[Index].Volume;
    end;
    if not PreventIncrement and not FHardware[Index].EnvelopeStopped and
      (FHardware[Index].EnvelopePeriod = 0) and ((Period > 0) or Up) then
      if Up then
        Inc(FHardware[Index].Volume)
      else
        Dec(FHardware[Index].Volume);
    FHardware[Index].Volume := FHardware[Index].Volume and 15;
  end;
  FHardware[Index].EnvelopePeriod := Period;
  FHardware[Index].EnvelopeUp := Up;
  FHardware[Index].DAC := (Value and $F8) <> 0;
  if not FHardware[Index].DAC then
    FHardware[Index].Enabled := False;
  UpdateOutput(Index);
end;

procedure TGBSound.Trigger(Index: Integer);
begin
  if (Index = 2) and FHardware[2].Enabled and not FMemory.IsCGBHardware and (FHardware[2].Timer <= 2) then
  begin
    var Address := ((FHardware[2].Position + 1) and 31) div 2;
    if Address < 4 then
      FMemory.IOPort[$30] := FMemory.IOPort[$30 + Address]
    else
    begin
      Address := Address and $C;
      Move(FMemory.IOPort[$30 + Address], FMemory.IOPort[$30], 4);
    end;
  end;
  FHardware[Index].Enabled := FHardware[Index].DAC;
  if FHardware[Index].Length = 0 then
  begin
    FHardware[Index].Length := 64;
    if Index = 2 then
      FHardware[Index].Length := 256;
    if FHardware[Index].LengthEnabled and ((FFrameStep and 1) <> 0) then
      Dec(FHardware[Index].Length);
  end;
  FHardware[Index].Timer := ChannelPeriod(Index);
  if Index = 2 then
  begin
    FHardware[2].Position := 0;
    Inc(FHardware[2].Timer, 6);
  end
  else if Index = 3 then
    FHardware[3].LFSR := $7FFF;
  if Index <> 2 then
  begin
    var Offset := $12 + Index * 5;
    if Index = 3 then
      Offset := $21;
    FHardware[Index].Volume := FMemory.IOPort[Offset] shr 4;
    FHardware[Index].EnvelopeStopped := False;
    FHardware[Index].EnvelopeTimer := FHardware[Index].EnvelopePeriod;
    if FHardware[Index].EnvelopeTimer = 0 then
      FHardware[Index].EnvelopeTimer := 8;
    if FFrameStep = 7 then
      Inc(FHardware[Index].EnvelopeTimer);
  end;
  if Index = 0 then
  begin
    FHardware[0].SweepShadow := FHardware[0].Frequency;
    FHardware[0].SweepTimer := FHardware[0].SweepPeriod;
    if FHardware[0].SweepTimer = 0 then
      FHardware[0].SweepTimer := 8;
    FHardware[0].SweepNegated := False;
    FHardware[0].SweepEnabled := (FHardware[0].SweepPeriod <> 0) or (FHardware[0].SweepShift <> 0);
    if FHardware[0].SweepShift > 0 then
      SweepFrequency;
  end;
  UpdateOutput(Index);
end;

procedure TGBSound.WriteHardware(Address: Integer; Value: Byte);
begin
  if Address >= $FF30 then
  begin
    if FHardware[2].Enabled then
    begin
      if not FMemory.IsCGBHardware and (FHardware[2].WaveAccessClocks = 0) then
        Exit;

      Address := $FF30 + FHardware[2].Position div 2;
    end;
    FMemory.IOPort[Address - $FF00] := Value;
    Exit;
  end;
  if Address = NR52 then
  begin
    var WasOn := (ReadRegister(NR52) and $80) <> 0;
    var OnNow := (Value and $80) <> 0;
    if WasOn and not OnNow then
    begin
      for var i := $10 to $25 do
        FMemory.IOPort[i] := 0;
      for var i := 0 to 3 do
      begin
        var Length := FHardware[i].Length;
        var Gain := FHardware[i].DACVolume;
        FHardware[i] := Default(TGBHardwareChannel);
        FHardware[i].DACVolume := Gain;
        if not FMemory.IsCGBHardware then
          FHardware[i].Length := Length;
      end;
    end;
    if not WasOn and OnNow then
    begin
      FFrameStep := 0;
      FSkipFrame := Ord(FMemory.Timer.FrameSequencerBit);
    end;
    FMemory.IOPort[$26] := Ord(OnNow) shl 7;
    SyncChannels;
    Exit;
  end;

  var Offset := Address - $FF00;
  if (ReadRegister(NR52) and $80) = 0 then
  begin
    if FMemory.IsCGBHardware or (Address <> NR11) and (Address <> NR21) and (Address <> NR31) and (Address <> NR41) then
      Exit;

    if Address <> NR31 then
      Value := Value and $3F;
  end;
  FMemory.IOPort[Offset] := Value;
  case Address of
    NR10:
      begin
        if FHardware[0].SweepNegated and ((Value and 8) = 0) then
          FHardware[0].Enabled := False;
        FHardware[0].SweepPeriod := (Value shr 4) and 7;
        FHardware[0].SweepShift := Value and 7;
      end;
    NR11:
      FHardware[0].Length := 64 - (Value and 63);
    NR21:
      FHardware[1].Length := 64 - (Value and 63);
    NR31:
      FHardware[2].Length := 256 - Value;
    NR41:
      FHardware[3].Length := 64 - (Value and 63);
    NR12:
      WriteEnvelope(0, Value);
    NR22:
      WriteEnvelope(1, Value);
    NR42:
      WriteEnvelope(3, Value);
    NR30:
      begin
        FHardware[2].DAC := (Value and $80) <> 0;
        if not FHardware[2].DAC then
          FHardware[2].Enabled := False;
      end;
    NR13, NR14, NR23, NR24, NR33, NR34:
      begin
        var Index := 0;
        if Address >= NR33 then
          Index := 2
        else if Address >= NR23 then
          Index := 1;
        var Low := $13 + Index * 5;
        FHardware[Index].Frequency := FMemory.IOPort[Low] or ((FMemory.IOPort[Low + 1] and 7) shl 8);
      end;
  end;
  if (Address = NR14) or (Address = NR24) or (Address = NR34) or (Address = NR44) then
  begin
    var Index := 3;
    if Address = NR14 then
      Index := 0
    else if Address = NR24 then
      Index := 1
    else if Address = NR34 then
      Index := 2;
    var NewLength := (Value and $40) <> 0;
    if NewLength and not FHardware[Index].LengthEnabled and ((FFrameStep and 1) <> 0) and (FHardware[Index].Length > 0) then
    begin
      Dec(FHardware[Index].Length);
      if FHardware[Index].Length = 0 then
        FHardware[Index].Enabled := False;
    end;
    FHardware[Index].LengthEnabled := NewLength;
    if (Value and $80) <> 0 then
    begin
      Trigger(Index);
      FMemory.IOPort[Offset] := Value and $7F;
    end;
  end;
  for var i := 0 to 3 do
    UpdateOutput(i);
  SyncChannels;
end;

procedure TGBSound.UpdateSound(Cycle: Integer);
const
  ClockRate = 4194304;
begin
  for var Tick := 1 to Cycle do
  begin
    for var i := 0 to 3 do
    begin
      ClockChannel(i);
      {$IFDEF CPUX86}
      // x87 division benchmarks faster than indexed Extended loads on Win32.
      var Value := (FHardware[i].Output * 2 - 15) * FHardware[i].DACVolume / 100;
      {$ELSE}
      var Value := DACLevels[(FHardware[i].Output * 2 - 15) * FHardware[i].DACVolume];
      {$ENDIF}
      if (i = 2) and ((ReadRegister(NR32) and $60) = 0) then
        Value := 0;
      FIntegrated[i] := FIntegrated[i] + Value;
    end;
    Inc(FIntegratedClocks);
    FSoundTimer := FSoundTimer + GB_AUDIO_INTERNAL_RATE;
    if FSoundTimer >= ClockRate then
    begin
      FSoundTimer := FSoundTimer - ClockRate;
      for var i := 0 to 3 do
      begin
        FChannelSamples[i] := FIntegrated[i] / FIntegratedClocks;
        FIntegrated[i] := 0;
      end;
      FIntegratedClocks := 0;
      MixSound;
      Inc(FOutputPhase);
      if FOutputPhase = GB_AUDIO_OVERSAMPLE then
      begin
        FOutputPhase := 0;
        Inc(FSoundBufferIndex);
        if FSoundBufferIndex >= GB_AUDIO_BLOCK_SAMPLES then
          FlushBuffer;
      end;
    end;
  end;
end;

function TGBSound.IsSoundToTerminal(ChannelNumber: Integer; OutputNumber: Integer): Boolean;
begin
  Result := (ReadRegister(NR51) and (1 shl (ChannelNumber - 1 + (OutputNumber - 1) * 4))) <> 0;
end;

function TGBSound.GetSoundLevel(OutputNumber: Integer): Integer;
begin
  var Shift := 0;
  if OutputNumber = 2 then
    Shift := 4;
  Result := ((ReadRegister(NR50) shr Shift) and 7) + 1;
end;

procedure TGBSound.PlaySound;
begin
  FlushBuffer;
end;

function TGBSound.ReadPCM(Address: Integer): Byte;
begin
  if Address = $FF76 then
    Result := FHardware[0].Output or (FHardware[1].Output shl 4)
  else
    Result := FHardware[2].Output or (FHardware[3].Output shl 4);
end;

procedure TGBSound.MixSound;
var
  LeftAmp: Double;
  RightAmp: Double;
  LeftVolume: Integer;
  RightVolume: Integer;
  BufferIndex: Integer;
begin
  LeftAmp := 0;
  RightAmp := 0;

  for var i := 1 to 4 do
  begin
    // NR51 bits 4..7 -> SO2 / Left
    if IsSoundToTerminal(i, 2) then
      LeftAmp := LeftAmp + FChannelSamples[i - 1] * FChannelVolumes[i - 1];

    // NR51 bits 0..3 -> SO1 / Right
    if IsSoundToTerminal(i, 1) then
      RightAmp := RightAmp + FChannelSamples[i - 1] * FChannelVolumes[i - 1];
  end;

  LeftVolume := GetSoundLevel(2);
  RightVolume := GetSoundLevel(1);

  LeftAmp := LeftAmp * LeftVolume;
  RightAmp := RightAmp * RightVolume;

  // Keep 6 dB of headroom for coincident channels and DC-removal transients.
  LeftAmp := FFilter[0].Process(LeftAmp * (32767.0 / 960.0));
  RightAmp := FFilter[1].Process(RightAmp * (32767.0 / 960.0));

  // Remove DAC bias without discarding musical bass. 20 Hz DC blocker.
  LeftAmp := FDCFilter[0].Process(LeftAmp) * FVolume;
  RightAmp := FDCFilter[1].Process(RightAmp) * FVolume;

  LeftAmp := EnsureRange(LeftAmp, -32768, 32767);
  RightAmp := EnsureRange(RightAmp, -32768, 32767);

  BufferIndex := FSoundBufferIndex * 2;

  FMixedBuffer[BufferIndex] := SmallInt(Round(LeftAmp));
  FMixedBuffer[BufferIndex + 1] := SmallInt(Round(RightAmp));
end;

procedure TGBSound.FlushBuffer;
begin
  if FSoundBufferIndex <= 0 then
    Exit;

  if Assigned(FAudio) then
    FAudio.Submit(FMixedBuffer, FSoundBufferIndex);
  if Assigned(FOnPCM) then
  begin
    var Captured: TArray<SmallInt>;
    SetLength(Captured, FSoundBufferIndex * GB_AUDIO_CHANNELS);
    Move(FMixedBuffer[0], Captured[0], Length(Captured) * SizeOf(SmallInt));
    FOnPCM(Captured, FSoundBufferIndex);
  end;

  FSoundBufferIndex := 0;
end;

procedure TGBSound.FlushPCM;
begin
  FlushBuffer;
end;

procedure TEnvelope.SerializeState(State: TStateArchive);
begin
  State.Field(FBase, SizeOf(FBase));
  State.Field(FDirection, SizeOf(FDirection));
  State.Field(FStepLength, SizeOf(FStepLength));
  State.Field(FIndex, SizeOf(FIndex));
end;

procedure TBaseChannel.SerializeState(State: TStateArchive);
begin
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FLengthEnabled, SizeOf(FLengthEnabled));
  State.Field(FLength, SizeOf(FLength));
  State.Field(FFrequency, SizeOf(FFrequency));
  State.Field(FIndex, SizeOf(FIndex));
  var Count := Length(FWave);
  State.Field(Count, SizeOf(Count));
  if (Count < 0) or (Count > 32768) then
    raise EReadError.Create('Invalid waveform length');

  if State.Loading then
    System.SetLength(FWave, Count);
  if Count > 0 then
    State.Field(FWave[0], Count * SizeOf(FWave[0]));
  State.Field(FWavePhase, SizeOf(FWavePhase));
end;

procedure TSquareWaveChannel.SerializeState(State: TStateArchive);
begin
  inherited SerializeState(State);
  var HasEnvelope := FVolume <> nil;
  State.Field(HasEnvelope, SizeOf(HasEnvelope));
  if State.Loading then
    if HasEnvelope then
    begin
      if FVolume = nil then
        FVolume := TEnvelope.Create;
    end
    else
      FreeAndNil(FVolume);
  if HasEnvelope then
    FVolume.SerializeState(State);
  State.Field(FGBFrequency, SizeOf(FGBFrequency));
  State.Field(FSweepIndex, SizeOf(FSweepIndex));
  State.Field(FSweepLength, SizeOf(FSweepLength));
  State.Field(FSweepDirection, SizeOf(FSweepDirection));
  State.Field(FSweepShift, SizeOf(FSweepShift));
  State.Field(FWaveDuty, SizeOf(FWaveDuty));
end;

procedure TNoiseChannel.SerializeState(State: TStateArchive);
begin
  inherited SerializeState(State);
  var HasEnvelope := FVolume <> nil;
  State.Field(HasEnvelope, SizeOf(HasEnvelope));
  if State.Loading then
    if HasEnvelope then
    begin
      if FVolume = nil then
        FVolume := TEnvelope.Create;
    end
    else
      FreeAndNil(FVolume);
  if HasEnvelope then
    FVolume.SerializeState(State);
  State.Field(FShiftFrequency, SizeOf(FShiftFrequency));
  State.Field(FCounterStep, SizeOf(FCounterStep));
  State.Field(FDivisorRatio, SizeOf(FDivisorRatio));
  State.Field(FLFSR, SizeOf(FLFSR));
  State.Field(FPhase, SizeOf(FPhase));
end;

procedure TGBSound.SerializeState(State: TStateArchive);
begin
  State.Field(FHardware, SizeOf(FHardware));
  State.Field(FFrameStep, SizeOf(FFrameStep));
  State.Field(FSkipFrame, SizeOf(FSkipFrame));
  State.Field(FIntegrated, SizeOf(FIntegrated));
  State.Field(FIntegratedClocks, SizeOf(FIntegratedClocks));
  FChannel1.SerializeState(State);
  FChannel2.SerializeState(State);
  FChannel3.SerializeState(State);
  FChannel4.SerializeState(State);
  State.Field(FSoundTimer, SizeOf(FSoundTimer));
  State.Field(FSoundBufferIndex, SizeOf(FSoundBufferIndex));
  State.Field(FChannelSamples, SizeOf(FChannelSamples));
  State.Field(FOutputPhase, SizeOf(FOutputPhase));
  State.Field(FFilter, SizeOf(FFilter));
  State.Field(FDCFilter, SizeOf(FDCFilter));
  State.Field(FMixedBuffer, SizeOf(FMixedBuffer));
  if (FSoundBufferIndex < 0) or (FSoundBufferIndex >= GB_AUDIO_BLOCK_SAMPLES) then
    raise EReadError.Create('Invalid sound buffer index');
end;

{$IFNDEF CPUX86}
initialization
  InitializeDACLevels;
{$ENDIF}

end.


