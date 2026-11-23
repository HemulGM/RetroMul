unit J2ME.Audio.State;

interface

uses
  Audio.Types, System.SysUtils, Audio.Decoder, Audio.Synthesis.SoundFont,
  JVM.StateIO;

function J2MEAudioThreadTerminated: Boolean;

function OpenJ2MEDecoder(const Data: TBytes; const Extension: string): IAudioSource;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): IAudioSource;

procedure TransferJ2MEMidiSynth(S: TJVMStateIO; Synth: TSoundFontSynth);

implementation

uses
  System.Classes, System.Math, Audio.Format.WAV, Audio.Format.MIDI,
  Audio.MP3.Source, Audio.Format.AMR, J2ME.SMAF, J2ME.Compatibility,
  J2ME.Media.Video;

function J2MEAudioThreadTerminated: Boolean;
begin
  if TThread.CurrentThread.ExternalThread then
    Exit(False);
  Result := TThread.CheckTerminated;
end;

function OpenJ2MEDecoder(const Data: TBytes; const Extension: string): IAudioSource;
begin
  if SameText(Extension, '.wav') then
    Result := OpenWav(Data)
  else if SameText(Extension, '.mid') then
    Result := OpenMidi(NormalizeJ2MECompatibilityMIDI(Data))
  else if SameText(Extension, '.mp3') then
    Result := OpenMP3(Data)
  else if SameText(Extension, '.mmf') then
    Result := OpenSMAF(Data)
  else if SameText(Extension, '.amr') then
    Result := OpenAMRForPlayback(Data)
  else if SameText(Extension, '.m4a') then
    Result := OpenJ2MEContainerAudio(Data)
  else
    raise EArgumentException.Create('Unsupported J2ME audio format: ' + Extension);
end;

function RestoreJ2MEDecoder(const Data: TBytes; const Extension: string; Samples, SampleRate, Channels: Integer): IAudioSource;
begin
  if not (Channels in [1, 2]) or (Samples < 0) or (Samples mod Channels <> 0) then
    raise EReadError.Create('Invalid snapshot decoder position');
  Result := OpenJ2MEDecoder(Data, Extension);
  var Info := GetAudioInfo(Result);
  if (Info.SampleRate <> SampleRate) or (Info.Channels <> Channels) then
    raise EReadError.Create('Incompatible snapshot audio format');
  var Seeker: IAudioSeekSource;
  if Supports(Result, IAudioSeekSource, Seeker) then
  begin
    var Frame := Int64(Samples div Channels);
    if Seeker.SeekFrame(Frame,
      function: Boolean
      begin
        Result := J2MEAudioThreadTerminated;
      end) <> Frame then
      raise EReadError.Create('Invalid snapshot decoder position');
    Exit;
  end;
  var Remaining := Samples div Channels;
  var PCM: TArray<SmallInt>;
  SetLength(PCM, 4096 * Channels);
  while Remaining > 0 do
  begin
    var Requested := Min(4096, Remaining);
    var Read := Result.Render(PCM, Requested);
    if (Read <= 0) or (Read > Requested) then
      raise EReadError.Create('Invalid snapshot decoder position');
    Dec(Remaining, Read);
  end;
end;

procedure TransferJ2MEMidiSynth(S: TJVMStateIO; Synth: TSoundFontSynth);

  procedure Finite(var Value: Double);
  begin
    S.RealValue(Value);
    if IsNan(Value) or IsInfinite(Value) then
      raise EReadError.Create('Invalid MIDI synthesizer value');
  end;

  procedure Channel(var C: TSFChannel);
  begin
    S.Int(C.Preset);
    S.Int(C.BankMSB);
    S.Int(C.BankLSB);
    S.Int(C.Volume);
    S.Int(C.Expression);
    S.Int(C.Pan);
    S.Int(C.Bend);
    S.Int(C.Modulation);
    S.Int(C.RPNMSB);
    S.Int(C.RPNLSB);
    S.Int(C.DataMSB);
    S.Int(C.DataLSB);
    Finite(C.PitchRange);
    Finite(C.Tuning);
    S.Bool(C.Sustain);
  end;

  procedure Voice(var V: TSFVoice);
  begin
    S.Bool(V.Active);
    if not V.Active then
      Exit;
    S.Bool(V.Held);
    S.Bool(V.Sustained);
    S.Bool(V.Released);
    S.Int(V.Channel);
    S.Int(V.Key);
    S.Int(V.Velocity);
    S.Int(V.Region);
    S.Int(V.Stage);
    S.Int(V.StageRemaining);
    S.Int64Value(V.Age);
    Finite(V.Position);
    Finite(V.Step);
    Finite(V.BaseStep);
    Finite(V.Gain);
    Finite(V.Left);
    Finite(V.Right);
    Finite(V.Envelope);
    Finite(V.EnvStep);
    Finite(V.LFOPhase);
    Finite(V.VibPhase);
    S.Int(V.DelaySamples);
    S.Int(V.AttackSamples);
    S.Int(V.HoldSamples);
    S.Int(V.DecaySamples);
    S.Int(V.ReleaseSamples);
    Finite(V.SustainLevel);
    S.Int(V.ModStage);
    S.Int(V.ModRemaining);
    S.Int(V.ModDelay);
    S.Int(V.ModAttack);
    S.Int(V.ModHold);
    S.Int(V.ModDecay);
    S.Int(V.ModRelease);
    S.Int64Value(V.Clock);
    S.Int(V.UpdateCounter);
    S.Int(V.LFODelay);
    S.Int(V.VibDelay);
    Finite(V.ModEnvelope);
    Finite(V.ModStep);
    Finite(V.ModSustain);
    Finite(V.LFOIncrement);
    Finite(V.VibIncrement);
    Finite(V.PitchStep);
    Finite(V.ModGain);
    Finite(V.B0);
    Finite(V.B1);
    Finite(V.B2);
    Finite(V.A1);
    Finite(V.A2);
    Finite(V.Z1);
    Finite(V.Z2);
  end;

begin
  var Bank := Synth.BankFingerprint;
  S.Text(Bank);
  if Bank <> Synth.BankFingerprint then
    raise EReadError.Create('MIDI snapshot requires its original SoundFont');
  var State: TSoundFontSynthState;
  if S.Loading then
    State := Default(TSoundFontSynthState)
  else
    State := Synth.CaptureState;
  S.Int64Value(State.Age);
  for var I := Low(State.Channels) to High(State.Channels) do
    Channel(State.Channels[I]);
  for var I := Low(State.Voices) to High(State.Voices) do
    Voice(State.Voices[I]);
  if S.Loading then
  begin
    Synth.ValidateState(State);
    Synth.RestoreState(State);
  end;
end;

end.

