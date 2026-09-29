unit GBC.Sound;

interface

uses
  System.SysUtils, System.Math, GBC.Memory, PCM.Audio;

const
  GB_AUDIO_SAMPLE_RATE = 44100;
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
  end;

  TBaseChannel = class
  private
    FEnabled: Boolean;
    FLengthEnabled: Boolean;
    FLength: Integer;
    FFrequency: Double;
    FIndex: Integer;
    FWave: TIntegerArray;
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
    function NextSample: Integer;
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
    FMemory: TGBCMemory;

    FChannel1: TSquareWaveChannel;
    FChannel2: TSquareWaveChannel;
    FChannel3: TWaveChannel;
    FChannel4: TNoiseChannel;

    FAudio: TPCMAudio;

    FSoundTimer: Double;
    FSoundBufferIndex: Integer;

    // Текущий уровень каждого аппаратного канала.
    FChannelSamples: array[0..3] of Integer;

    // PCM backend пока mono PCM16.
    FMixedBuffer: array[0..GB_AUDIO_BLOCK_SAMPLES * GB_AUDIO_CHANNELS - 1] of SmallInt;
    FVolume: Single;
    procedure SetVolume(const Value: Single);
    procedure InitChannels;
    procedure InitChannel1;
    procedure InitChannel2;
    procedure InitChannel3;
    procedure InitChannel4;
    procedure UpdateChannel1;
    procedure UpdateChannel2;
    procedure UpdateChannel3;
    procedure UpdateChannel4;
    procedure MixSound;
    procedure FlushBuffer;
    function IsSoundReset(ChannelNumber: Integer): Boolean;
    procedure RemoveSoundReset(ChannelNumber: Integer);
    function IsAllSoundOn: Boolean;
    procedure SetSoundOn(ChannelNumber: Integer);
    procedure SetSoundOff(ChannelNumber: Integer);
    function IsSoundToTerminal(ChannelNumber: Integer; OutputNumber: Integer): Boolean;
    function GetSoundLevel(OutputNumber: Integer): Integer;
    procedure DisableAllChannels;

  public
    constructor Create(AMemory: TGBCMemory; EnableOutput: Boolean = True); overload;
    destructor Destroy; override;

    procedure StartAudio;
    procedure UpdateSound(Cycle: Integer);
    procedure PlaySound;

    property Channel1: TSquareWaveChannel read FChannel1;
    property Channel2: TSquareWaveChannel read FChannel2;
    property Channel3: TWaveChannel read FChannel3;
    property Channel4: TNoiseChannel read FChannel4;

    property BufferIndex: Integer read FSoundBufferIndex;

    // 0.0 = mute
    // 1.0 = 100%
    property Volume: Single read FVolume write SetVolume;

    property Audio: TPCMAudio read FAudio;
  end;

implementation

uses
  GBC.CPU;

const
  SoundFreq = CPUClockFrequency / GB_AUDIO_SAMPLE_RATE;

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
var
  Wave: TIntegerArray;
begin
  Value := Value and 3;
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

function TNoiseChannel.NextSample: Integer;
var
  Feedback: Word;
begin
  if GetFrequency <= 0 then
    Exit(0);

  FPhase := FPhase + GetFrequency / GB_AUDIO_SAMPLE_RATE;

  while FPhase >= 1.0 do
  begin
    FPhase := FPhase - 1.0;
    Feedback := (FLFSR xor (FLFSR shr 1)) and 1;
    FLFSR := (FLFSR shr 1) or (Feedback shl 14);

    if FCounterStep <> 0 then
      FLFSR := (FLFSR and not $40) or (Feedback shl 6);
  end;

  if (FLFSR and 1) = 0 then
    Result := 1
  else
    Result := -1;
end;

{ TGBSound }

constructor TGBSound.Create(AMemory: TGBCMemory; EnableOutput: Boolean);
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

  var AudioFormat: TPCMAudioFormat;
  AudioFormat.SampleRate := GB_AUDIO_SAMPLE_RATE;
  AudioFormat.Channels := GB_AUDIO_CHANNELS;
  AudioFormat.BlockFrames := GB_AUDIO_BLOCK_SAMPLES;
  AudioFormat.BlockCount := GB_AUDIO_BLOCK_COUNT;

  if EnableOutput then
    FAudio := TPCMAudio.Create(AudioFormat)
  else
    FAudio := nil;

  StartAudio;
end;

destructor TGBSound.Destroy;
begin
  if Assigned(FAudio) then
    FAudio.Clear;

  FAudio.Free;

  FChannel4.Free;
  FChannel3.Free;
  FChannel2.Free;
  FChannel1.Free;

  inherited;
end;

procedure TGBSound.SetVolume(const Value: Single);
begin
  FVolume := EnsureRange(Value, 0.0, 1.0);
end;

procedure TGBSound.StartAudio;
begin
  FSoundTimer := 0;
  FSoundBufferIndex := 0;

  FillChar(FMixedBuffer, SizeOf(FMixedBuffer), 0);
  FillChar(FChannelSamples, SizeOf(FChannelSamples), 0);

  DisableAllChannels;

  if Assigned(FAudio) then
    FAudio.Clear;
end;

procedure TGBSound.DisableAllChannels;
begin
  FChannel1.SetEnabled(False);
  FChannel2.SetEnabled(False);
  FChannel3.SetEnabled(False);
  FChannel4.SetEnabled(False);
end;

function TGBSound.IsAllSoundOn: Boolean;
begin
  Result := (FMemory.ReadByte(NR52) and $80) <> 0;
end;

function TGBSound.IsSoundReset(ChannelNumber: Integer): Boolean;
var
  Value: Integer;
begin
  case ChannelNumber of
    1:
      Value := FMemory.ReadByte(NR14);
    2:
      Value := FMemory.ReadByte(NR24);
    3:
      Value := FMemory.ReadByte(NR34);
    4:
      Value := FMemory.ReadByte(NR44);
  else
    Exit(False);
  end;

  Result := (Value and $80) <> 0;
end;

procedure TGBSound.RemoveSoundReset(ChannelNumber: Integer);
var
  Address: Integer;
  Value: Integer;
begin
  case ChannelNumber of
    1:
      Address := NR14;
    2:
      Address := NR24;
    3:
      Address := NR34;
    4:
      Address := NR44;
  else
    Exit;
  end;

  Value := FMemory.ReadByte(Address);
  FMemory.WriteByte(Address, Value and $7F);
end;

procedure TGBSound.SetSoundOn(ChannelNumber: Integer);
var
  Mask: Integer;
  Value: Integer;
begin
  if (ChannelNumber < 1) or (ChannelNumber > 4) then
    Exit;

  Mask := 1 shl (ChannelNumber - 1);
  Value := FMemory.ReadByte(NR52);
  FMemory.WriteByte(NR52, Value or Mask);
end;

procedure TGBSound.SetSoundOff(ChannelNumber: Integer);
var
  Mask: Integer;
  Value: Integer;
begin
  if (ChannelNumber < 1) or (ChannelNumber > 4) then
    Exit;

  Mask := 1 shl (ChannelNumber - 1);
  Value := FMemory.ReadByte(NR52);
  FMemory.WriteByte(NR52, Value and not Mask);
end;

function TGBSound.IsSoundToTerminal(ChannelNumber: Integer; OutputNumber: Integer): Boolean;
begin
  var Mask := 1 shl ((ChannelNumber - 1) + ((OutputNumber - 1) * 4));
  Result := (FMemory.ReadByte(NR51) and Mask) <> 0;
end;

function TGBSound.GetSoundLevel(OutputNumber: Integer): Integer;
begin
  var Value: Integer := FMemory.ReadByte(NR50);

  if OutputNumber = 1 then
    Result := (Value and $07) + 1
  else
    Result := ((Value shr 4) and $07) + 1;
end;

procedure TGBSound.InitChannels;
begin
  InitChannel1;
  InitChannel2;
  InitChannel3;
  InitChannel4;
end;

procedure TGBSound.InitChannel1;
var
  NR10Value: Integer;
  NR11Value: Integer;
  NR12Value: Integer;
  NR13Value: Integer;
  NR14Value: Integer;
  FrequencyValue: Integer;
  Envelope: TEnvelope;
  Period: Integer;
begin
  if not IsSoundReset(1) then
    Exit;

  RemoveSoundReset(1);

  NR10Value := FMemory.ReadByte(NR10);
  NR11Value := FMemory.ReadByte(NR11);
  NR12Value := FMemory.ReadByte(NR12);
  NR13Value := FMemory.ReadByte(NR13);
  NR14Value := FMemory.ReadByte(NR14);

  FrequencyValue := NR13Value or ((NR14Value and $07) shl 8);

  FChannel1.SetEnabled(True);
  FChannel1.SetWaveDuty((NR11Value shr 6) and $03);
  FChannel1.SetIndex(0);
  FChannel1.SetGBFrequency(FrequencyValue);

  if FrequencyValue < 2048 then
    FChannel1.SetFrequency(131072.0 / (2048 - FrequencyValue))
  else
    FChannel1.SetFrequency(0);

  if (NR14Value and $40) <> 0 then
  begin
    FChannel1.SetLengthEnabled(True);
    FChannel1.SetLength(((64 - (NR11Value and $3F)) * GB_AUDIO_SAMPLE_RATE) div 256);
  end
  else
    FChannel1.SetLengthEnabled(False);

  Envelope := TEnvelope.Create;
  Envelope.SetBase((NR12Value shr 4) and $0F);

  if (NR12Value and $08) <> 0 then
    Envelope.SetDirection(1)
  else
    Envelope.SetDirection(-1);

  Period := NR12Value and $07;

  if Period = 0 then
    Envelope.SetStepLength(0)
  else
    Envelope.SetStepLength(Period * GB_AUDIO_SAMPLE_RATE div 64);

  Envelope.SetIndex(Envelope.GetStepLength);
  FChannel1.SetVolume(Envelope);
  Period := (NR10Value shr 4) and $07;

  if Period = 0 then
    Period := 8;

  FChannel1.SetSweepLength(Period * GB_AUDIO_SAMPLE_RATE div 128);
  FChannel1.SetSweepIndex(FChannel1.GetSweepLength);

  if (NR10Value and $08) <> 0 then
    FChannel1.SetSweepDirection(-1)
  else
    FChannel1.SetSweepDirection(1);

  FChannel1.SetSweepShift(NR10Value and $07);
  SetSoundOn(1);
end;

procedure TGBSound.InitChannel2;
var
  NR21Value: Integer;
  NR22Value: Integer;
  NR23Value: Integer;
  NR24Value: Integer;
  FrequencyValue: Integer;
  Envelope: TEnvelope;
  Period: Integer;
begin
  if not IsSoundReset(2) then
    Exit;

  RemoveSoundReset(2);

  NR21Value := FMemory.ReadByte(NR21);
  NR22Value := FMemory.ReadByte(NR22);
  NR23Value := FMemory.ReadByte(NR23);
  NR24Value := FMemory.ReadByte(NR24);

  FrequencyValue := NR23Value or ((NR24Value and $07) shl 8);

  FChannel2.SetEnabled(True);
  FChannel2.SetWaveDuty((NR21Value shr 6) and $03);
  FChannel2.SetIndex(0);

  if FrequencyValue < 2048 then
    FChannel2.SetFrequency(131072.0 / (2048 - FrequencyValue))
  else
    FChannel2.SetFrequency(0);

  if (NR24Value and $40) <> 0 then
  begin
    FChannel2.SetLengthEnabled(True);
    FChannel2.SetLength(((64 - (NR21Value and $3F)) * GB_AUDIO_SAMPLE_RATE) div 256);
  end
  else
    FChannel2.SetLengthEnabled(False);

  Envelope := TEnvelope.Create;
  Envelope.SetBase((NR22Value shr 4) and $0F);

  if (NR22Value and $08) <> 0 then
    Envelope.SetDirection(1)
  else
    Envelope.SetDirection(-1);

  Period := NR22Value and $07;

  if Period = 0 then
    Envelope.SetStepLength(0)
  else
    Envelope.SetStepLength(Period * GB_AUDIO_SAMPLE_RATE div 64);

  Envelope.SetIndex(Envelope.GetStepLength);
  FChannel2.SetVolume(Envelope);
  SetSoundOn(2);
end;

procedure TGBSound.InitChannel3;
var
  NR30Value: Integer;
  NR31Value: Integer;
  NR33Value: Integer;
  NR34Value: Integer;
  FrequencyValue: Integer;
  WaveSamples: TIntegerArray;
  Value: Integer;
begin
  if not IsSoundReset(3) then
    Exit;

  RemoveSoundReset(3);

  NR30Value := FMemory.ReadByte(NR30);
  NR31Value := FMemory.ReadByte(NR31);
  NR33Value := FMemory.ReadByte(NR33);
  NR34Value := FMemory.ReadByte(NR34);

  FChannel3.SetIndex(0);

  if (NR30Value and $80) <> 0 then
    FChannel3.SetEnabled(True)
  else
    FChannel3.SetEnabled(False);

  FrequencyValue := NR33Value or ((NR34Value and $07) shl 8);

  if FrequencyValue < 2048 then
    FChannel3.SetFrequency(
      65536.0 / (2048 - FrequencyValue)
    )
  else
    FChannel3.SetFrequency(0);

  SetLength(WaveSamples, 32);

  for var i := $FF30 to $FF3F do
  begin
    Value := FMemory.ReadByte(i);
    WaveSamples[(i - $FF30) * 2] := (Value shr 4) and $0F;
    WaveSamples[((i - $FF30) * 2) + 1] := Value and $0F;
  end;

  FChannel3.SetWave(WaveSamples);

  if (NR34Value and $40) <> 0 then
  begin
    FChannel3.SetLengthEnabled(True);
    FChannel3.SetLength(((256 - NR31Value) * GB_AUDIO_SAMPLE_RATE) div 256);
  end
  else
    FChannel3.SetLengthEnabled(False);

  if FChannel3.IsEnabled then
    SetSoundOn(3)
  else
    SetSoundOff(3);
end;

procedure TGBSound.InitChannel4;
const
  DivisorTable: array[0..7] of Double = (0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
var
  NR41Value: Integer;
  NR42Value: Integer;
  NR43Value: Integer;
  NR44Value: Integer;
  Envelope: TEnvelope;
  Shift: Integer;
  DivisorCode: Integer;
  Period: Integer;
  Frequency: Double;
begin
  if not IsSoundReset(4) then
    Exit;

  RemoveSoundReset(4);

  NR41Value := FMemory.ReadByte(NR41);
  NR42Value := FMemory.ReadByte(NR42);
  NR43Value := FMemory.ReadByte(NR43);
  NR44Value := FMemory.ReadByte(NR44);

  FChannel4.SetEnabled(True);
  FChannel4.SetIndex(0);
  FChannel4.ResetLFSR;

  if (NR44Value and $40) <> 0 then
  begin
    FChannel4.SetLengthEnabled(True);

    FChannel4.SetLength(
      ((64 - (NR41Value and $3F)) *
      GB_AUDIO_SAMPLE_RATE) div 256
    );
  end
  else
    FChannel4.SetLengthEnabled(False);

  Envelope := TEnvelope.Create;
  Envelope.SetBase((NR42Value shr 4) and $0F);

  if (NR42Value and $08) <> 0 then
    Envelope.SetDirection(1)
  else
    Envelope.SetDirection(-1);

  Period := NR42Value and $07;

  if Period = 0 then
    Envelope.SetStepLength(0)
  else
    Envelope.SetStepLength(Period * GB_AUDIO_SAMPLE_RATE div 64);

  Envelope.SetIndex(Envelope.GetStepLength);

  FChannel4.SetVolume(Envelope);

  Shift := (NR43Value shr 4) and $0F;
  DivisorCode := NR43Value and $07;

  FChannel4.SetShiftFrequency(Shift);

  if (NR43Value and $08) <> 0 then
    FChannel4.SetCounterStep(1)
  else
    FChannel4.SetCounterStep(0);

  FChannel4.SetDivisorRatio(DivisorTable[DivisorCode]);

  Frequency := 262144.0 / DivisorTable[DivisorCode] / Power(2.0, Shift);
  FChannel4.SetFrequency(Frequency);
  SetSoundOn(4);
end;

procedure TGBSound.UpdateChannel1;
var
  WavePosition: Double;
  WaveIndex: Integer;
  Sample: Integer;
  NewFrequency: Integer;
  Delta: Integer;
  FrequencyRegister: Integer;
begin
  FChannelSamples[0] := 0;

  if not FChannel1.IsEnabled then
    Exit;

  FChannel1.IncIndex;
  WavePosition := 32.0 * FChannel1.GetFrequency * FChannel1.GetIndex / GB_AUDIO_SAMPLE_RATE;
  WaveIndex := Trunc(WavePosition) mod 32;
  Sample := FChannel1.GetWaveValue(WaveIndex);

  if FChannel1.GetVolume <> nil then
    FChannelSamples[0] := Sample * FChannel1.GetVolume.GetBase;

  if FChannel1.IsLengthEnabled then
  begin
    if FChannel1.GetLength > 0 then
      FChannel1.DecLength;

    if FChannel1.GetLength <= 0 then
    begin
      FChannel1.SetEnabled(False);
      SetSoundOff(1);
      FChannelSamples[0] := 0;
      Exit;
    end;
  end;

  if FChannel1.GetVolume <> nil then
    FChannel1.GetVolume.HandleSweep;

  if (FChannel1.GetSweepLength > 0) and (FChannel1.GetSweepShift > 0) then
  begin
    FChannel1.DecSweepIndex;

    if FChannel1.GetSweepIndex <= 0 then
    begin
      FChannel1.SetSweepIndex(FChannel1.GetSweepLength);
      Delta := FChannel1.GetGBFrequency shr FChannel1.GetSweepShift;
      NewFrequency := FChannel1.GetGBFrequency + Delta * FChannel1.GetSweepDirection;

      if (NewFrequency < 0) or (NewFrequency > 2047) then
      begin
        FChannel1.SetEnabled(False);
        SetSoundOff(1);
        Exit;
      end;

      FChannel1.SetGBFrequency(NewFrequency);
      FChannel1.SetFrequency(131072.0 / (2048 - NewFrequency));
      FMemory.WriteByte(NR13, NewFrequency and $FF);
      FrequencyRegister := (FMemory.ReadByte(NR14) and $F8) or ((NewFrequency shr 8) and $07);
      FMemory.WriteByte(NR14, FrequencyRegister);
    end;
  end;
end;

procedure TGBSound.UpdateChannel2;
var
  WavePosition: Double;
  WaveIndex: Integer;
  Sample: Integer;
begin
  FChannelSamples[1] := 0;

  if not FChannel2.IsEnabled then
    Exit;

  FChannel2.IncIndex;
  WavePosition := 32.0 * FChannel2.GetFrequency * FChannel2.GetIndex / GB_AUDIO_SAMPLE_RATE;
  WaveIndex := Trunc(WavePosition) mod 32;
  Sample := FChannel2.GetWaveValue(WaveIndex);

  if FChannel2.GetVolume <> nil then
    FChannelSamples[1] := Sample * FChannel2.GetVolume.GetBase;

  if FChannel2.IsLengthEnabled then
  begin
    if FChannel2.GetLength > 0 then
      FChannel2.DecLength;

    if FChannel2.GetLength <= 0 then
    begin
      FChannel2.SetEnabled(False);
      SetSoundOff(2);
      FChannelSamples[1] := 0;
      Exit;
    end;
  end;

  if FChannel2.GetVolume <> nil then
    FChannel2.GetVolume.HandleSweep;
end;

procedure TGBSound.UpdateChannel3;
var
  NR30Value: Integer;
  NR32Value: Integer;
  WavePosition: Double;
  WaveIndex: Integer;
  Sample: Integer;
  VolumeCode: Integer;
begin
  FChannelSamples[2] := 0;

  if not FChannel3.IsEnabled then
    Exit;

  NR30Value := FMemory.ReadByte(NR30);

  if (NR30Value and $80) = 0 then
  begin
    FChannel3.SetEnabled(False);
    SetSoundOff(3);
    Exit;
  end;

  NR32Value := FMemory.ReadByte(NR32);
  FChannel3.IncIndex;
  WavePosition := 32.0 * FChannel3.GetFrequency * FChannel3.GetIndex / GB_AUDIO_SAMPLE_RATE;
  WaveIndex := Trunc(WavePosition) mod 32;
  Sample := FChannel3.GetWaveValue(WaveIndex);
  VolumeCode := (NR32Value shr 5) and $03;

  case VolumeCode of
    0:
      Sample := 0;
    1: // 100%
      ;
    2:
      Sample := Sample shr 1;
    3:
      Sample := Sample shr 2;
  end;

  FChannelSamples[2] := (Sample shl 1) - 15;

  if FChannel3.IsLengthEnabled then
  begin
    if FChannel3.GetLength > 0 then
      FChannel3.DecLength;

    if FChannel3.GetLength <= 0 then
    begin
      FChannel3.SetEnabled(False);
      SetSoundOff(3);
      FChannelSamples[2] := 0;
    end;
  end;
end;

procedure TGBSound.UpdateChannel4;
begin
  FChannelSamples[3] := 0;

  if not FChannel4.IsEnabled then
    Exit;

  var Sample := FChannel4.NextSample;

  if FChannel4.GetVolume <> nil then
    FChannelSamples[3] := Sample * FChannel4.GetVolume.GetBase;

  if FChannel4.IsLengthEnabled then
  begin
    if FChannel4.GetLength > 0 then
      FChannel4.DecLength;

    if FChannel4.GetLength <= 0 then
    begin
      FChannel4.SetEnabled(False);
      SetSoundOff(4);
      FChannelSamples[3] := 0;
      Exit;
    end;
  end;

  if FChannel4.GetVolume <> nil then
    FChannel4.GetVolume.HandleSweep;
end;

procedure TGBSound.PlaySound;
begin
  FlushBuffer;
end;

procedure TGBSound.MixSound;
var
  LeftAmp: Integer;
  RightAmp: Integer;
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
      Inc(LeftAmp, FChannelSamples[i - 1]);

    // NR51 bits 0..3 -> SO1 / Right
    if IsSoundToTerminal(i, 1) then
      Inc(RightAmp, FChannelSamples[i - 1]);
  end;

  LeftVolume := GetSoundLevel(2);
  RightVolume := GetSoundLevel(1);

  LeftAmp := LeftAmp * LeftVolume;
  RightAmp := RightAmp * RightVolume;

  LeftAmp := Round(LeftAmp * (32767.0 / 480.0) * FVolume);
  RightAmp := Round(RightAmp * (32767.0 / 480.0) * FVolume);

  LeftAmp := EnsureRange(LeftAmp, -32768, 32767);
  RightAmp := EnsureRange(RightAmp, -32768, 32767);

  BufferIndex := FSoundBufferIndex * 2;

  FMixedBuffer[BufferIndex] := SmallInt(LeftAmp);
  FMixedBuffer[BufferIndex + 1] := SmallInt(RightAmp);
end;

procedure TGBSound.FlushBuffer;
begin
  if FSoundBufferIndex <= 0 then
    Exit;

  if Assigned(FAudio) then
    FAudio.Submit(FMixedBuffer, FSoundBufferIndex);

  FSoundBufferIndex := 0;
end;

procedure TGBSound.UpdateSound(Cycle: Integer);
var
  BufferIndex: Integer;
begin
  if Cycle <= 0 then
    Exit;

  if IsAllSoundOn then
    InitChannels
  else
    DisableAllChannels;

  FSoundTimer := FSoundTimer + Cycle;

  while FSoundTimer >= SoundFreq do
  begin
    FSoundTimer := FSoundTimer - SoundFreq;

    if IsAllSoundOn then
    begin
      UpdateChannel1;
      UpdateChannel2;
      UpdateChannel3;
      UpdateChannel4;

      MixSound;
    end
    else
    begin
      BufferIndex := FSoundBufferIndex * 2;

      FMixedBuffer[BufferIndex] := 0;
      FMixedBuffer[BufferIndex + 1] := 0;
    end;

    Inc(FSoundBufferIndex);

    if FSoundBufferIndex >= GB_AUDIO_BLOCK_SAMPLES then
      FlushBuffer;
  end;
end;

end.

