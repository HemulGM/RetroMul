unit Core.Audio.Player;

interface

uses
  Audio.Types, System.Classes, System.SysUtils, System.SyncObjs, Audio.Decoder,
  Audio.Spectrum, PCM.Audio;

type
  TAudioOutputFactory = reference to function(const Format: TPCMAudioFormat): TPCMAudio;

  TAudioPlayerState = (Stopped, Playing, Paused, Finished);

  TAudioPlayerStatus = record
    State: TAudioPlayerState;
    Track: Integer;
    Seconds, DurationSeconds: Double;
    Seeking: Boolean;
    Error: string;
  end;

  // The worker owns the decoder and PCM device. The UI sends commands only;
  // no UI object or queued callback is retained by this thread.
  TAudioPlayer = class(TThread)
  private
    FDecoder: IAudioSource;
    FDecoderUsed: Boolean;
    FAudioFactory: TAudioOutputFactory;
    FInfo: TAudioInfo;
    FLock: TCriticalSection;
    FWake: TEvent;
    FStatus: TAudioPlayerStatus;
    FGeneration: UInt64;
    FVolume: Integer;
    FSeekSeconds: Double;
    FStarted: Boolean;
    FPCMWindow: TAudioPCMWindow;
    FStereoWindow: TAudioStereoWindow;
    FPCMPosition: Integer;
    function MoveDecoder(Track: Integer; Seconds: Double; Generation: UInt64; out Actual: Double): Boolean;
    procedure SetTrackDuration;
    procedure ClearVisualization;
    procedure SetFailure(const MessageText: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Decoder: IAudioSource; const AudioFactory: TAudioOutputFactory = nil);
    destructor Destroy; override;
    procedure Play;
    procedure Pause;
    procedure Stop;
    procedure SelectTrack(Index: Integer);
    procedure Seek(Seconds: Double);
    procedure RestorePlayback(const Previous: TAudioPlayerStatus);
    procedure SetVolume(Percent: Integer);
    function Status: TAudioPlayerStatus;
    procedure GetVisualization(out Samples: TAudioPCMWindow; out SampleRate: Integer);
    // Atomic chronological L/R snapshot. Mono sources are duplicated.
    procedure GetStereoVisualization(out Samples: TAudioStereoWindow; out SampleRate: Integer);
  end;

implementation

uses
  System.Math;

constructor TAudioPlayer.Create(const Decoder: IAudioSource; const AudioFactory: TAudioOutputFactory);
begin
  // TThread.AfterConstruction starts it only after all fields are initialized.
  inherited Create(False);
  FreeOnTerminate := False;
  if Decoder = nil then
    raise EArgumentNilException.Create('Decoder is required');

  FDecoder := Decoder;
  FAudioFactory := AudioFactory;
  FInfo := GetAudioInfo(Decoder);
  if (FInfo.TrackCount < 1) or (FInfo.DefaultTrack < 0) or (FInfo.DefaultTrack >= FInfo.TrackCount) then
    raise EArgumentException.Create('Invalid decoder track information');

  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FStatus.Track := FInfo.DefaultTrack;
  SetTrackDuration;
  FStatus.State := TAudioPlayerState.Stopped;
  FVolume := 80;
  FStarted := True;
end;

destructor TAudioPlayer.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  if FStarted then
    WaitFor;
  FDecoder := nil;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TAudioPlayer.Play;
begin
  FLock.Acquire;
  try
    if FStatus.State in [TAudioPlayerState.Stopped, TAudioPlayerState.Finished] then
    begin
      Inc(FGeneration);
      FStatus.Seconds := 0;
      FSeekSeconds := 0;
      FStatus.Seeking := False;
      ClearVisualization;
    end;
    FStatus.Error := '';
    FStatus.State := TAudioPlayerState.Playing;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAudioPlayer.Pause;
begin
  FLock.Acquire;
  try
    if FStatus.State = TAudioPlayerState.Playing then
      FStatus.State := TAudioPlayerState.Paused;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAudioPlayer.Stop;
begin
  FLock.Acquire;
  try
    FStatus.State := TAudioPlayerState.Stopped;
    FStatus.Seconds := 0;
    FSeekSeconds := 0;
    FStatus.Seeking := False;
    ClearVisualization;
    Inc(FGeneration);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAudioPlayer.SelectTrack(Index: Integer);
begin
  if (Index < 0) or (Index >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid track');
  FLock.Acquire;
  try
    FStatus.Track := Index;
    SetTrackDuration;
    ClearVisualization;
    FStatus.Seconds := 0;
    FSeekSeconds := 0;
    FStatus.Seeking := False;
    FStatus.Error := '';
    Inc(FGeneration);
    if FStatus.State = TAudioPlayerState.Finished then
      FStatus.State := TAudioPlayerState.Stopped;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAudioPlayer.RestorePlayback(const Previous: TAudioPlayerStatus);
begin
  if (Previous.Track < 0) or (Previous.Track >= FInfo.TrackCount) then
    raise EArgumentOutOfRangeException.Create('Invalid track');
  if IsNan(Previous.Seconds) or IsInfinite(Previous.Seconds) or
    (Previous.Seconds < 0) or (Previous.Seconds > 86400) then
    raise EArgumentOutOfRangeException.Create('Invalid playback position');
  // Restore all commands together, before the worker can play the new decoder.
  FLock.Acquire;
  try
    FStatus.Track := Previous.Track;
    SetTrackDuration;
    FSeekSeconds := Previous.Seconds;
    if FStatus.DurationSeconds >= 0 then
      FSeekSeconds := Min(FSeekSeconds, FStatus.DurationSeconds);
    FStatus.Seconds := FSeekSeconds;
    FStatus.State := Previous.State;
    FStatus.Seeking := Previous.State <> TAudioPlayerState.Stopped;
    FStatus.Error := '';
    ClearVisualization;
    Inc(FGeneration);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TAudioPlayer.SetTrackDuration;
begin
  FStatus.DurationSeconds := -1;
  if FStatus.Track < Length(FInfo.TrackDurations) then
    FStatus.DurationSeconds := FInfo.TrackDurations[FStatus.Track];
end;

procedure TAudioPlayer.Seek(Seconds: Double);
begin
  if IsNan(Seconds) or IsInfinite(Seconds) or (Seconds < 0) or (Seconds > 86400) then
    raise EArgumentOutOfRangeException.Create('Invalid playback position');
  FLock.Acquire;
  try
    if FStatus.DurationSeconds >= 0 then
      Seconds := Min(Seconds, FStatus.DurationSeconds);
    FSeekSeconds := Seconds;
    FStatus.Seconds := Seconds;
    FStatus.Seeking := True;
    FStatus.Error := '';
    if FStatus.State in [TAudioPlayerState.Stopped, TAudioPlayerState.Finished] then
      FStatus.State := TAudioPlayerState.Paused;
    ClearVisualization;
    Inc(FGeneration);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TAudioPlayer.MoveDecoder(Track: Integer; Seconds: Double; Generation: UInt64; out Actual: Double): Boolean;
var
  Discard: TArray<SmallInt>;
begin
  Result := False;
  Actual := 0;
  PrepareAudioSource(FDecoder, Track, FDecoderUsed);
  FDecoderUsed := True;
  SetLength(Discard, 4096 * FInfo.Channels);
  var Target := Round(Seconds * FInfo.SampleRate);
  var Position: Int64 := 0;
  while Position < Target do
  begin
    if Terminated then
      Exit;
    FLock.Acquire;
    try
      if FGeneration <> Generation then
        Exit;
    finally
      FLock.Release;
    end;
    var Requested := Integer(Min(Int64(4096), Target - Position));
    var Count := FDecoder.Render(Discard, Requested);
    if (Count < 0) or (Count > Requested) then
      raise EInvalidOpException.Create('Invalid decoder frame count during seek');
    if Count = 0 then
      Break;
    Inc(Position, Count);
  end;
  Actual := Position / FInfo.SampleRate;
  FLock.Acquire;
  try
    Result := FGeneration = Generation;
  finally
    FLock.Release;
  end;
end;

procedure TAudioPlayer.SetVolume(Percent: Integer);
begin
  if (Percent < 0) or (Percent > 100) then
    raise EArgumentOutOfRangeException.Create('Volume must be between 0 and 100');

  FLock.Acquire;
  try
    FVolume := Percent;
  finally
    FLock.Release;
  end;
end;

function TAudioPlayer.Status: TAudioPlayerStatus;
begin
  FLock.Acquire;
  try
    Result := FStatus;
  finally
    FLock.Release;
  end;
end;

procedure TAudioPlayer.ClearVisualization;
begin
  // Called while FLock is held.
  FillChar(FPCMWindow, SizeOf(FPCMWindow), 0);
  FStereoWindow := Default(TAudioStereoWindow);
  FPCMPosition := 0;
end;

procedure TAudioPlayer.GetVisualization(out Samples: TAudioPCMWindow; out SampleRate: Integer);
begin
  FLock.Acquire;
  try
    SampleRate := FInfo.SampleRate;
    for var I := 0 to AudioFFTSize - 1 do
      Samples[I] := FPCMWindow[(FPCMPosition + I) mod AudioFFTSize];
  finally
    FLock.Release;
  end;
end;

procedure TAudioPlayer.GetStereoVisualization(out Samples: TAudioStereoWindow; out SampleRate: Integer);
begin
  FLock.Acquire;
  try
    SampleRate := FInfo.SampleRate;
    for var I := 0 to AudioFFTSize - 1 do
    begin
      var At := (FPCMPosition + I) mod AudioFFTSize;
      Samples.Left[I] := FStereoWindow.Left[At];
      Samples.Right[I] := FStereoWindow.Right[At];
    end;
  finally
    FLock.Release;
  end;
end;

procedure TAudioPlayer.SetFailure(const MessageText: string);
begin
  FLock.Acquire;
  try
    FStatus.Error := MessageText;
    FStatus.State := TAudioPlayerState.Stopped;
  finally
    FLock.Release;
  end;
end;

procedure TAudioPlayer.Execute;
const
  BlockFrames = 1024;
  BufferedSeconds = 0.12;
  MaxQueueBlocks = 8;
var
  Audio: TPCMAudio;
  AudioFormat: TPCMAudioFormat;
  Samples: TArray<SmallInt>;
  Current: TAudioPlayerStatus;
  Generation, AppliedGeneration: UInt64;
  Volume, Count, I, Channel, Sum, QueueLimit: Integer;
  HaveGeneration, WasPlaying, AtEnd, PendingBlock, DevicePaused: Boolean;
  Target, Actual: Double;
begin
  Audio := nil;
  try
    AudioFormat.SampleRate := FInfo.SampleRate;
    AudioFormat.Channels := FInfo.Channels;
    AudioFormat.BlockFrames := BlockFrames;
    AudioFormat.BlockCount := MaxQueueBlocks;
    // Keep enough PCM queued to survive short scheduler/UI/driver stalls.
    // Use the sample rate so lower-rate formats do not gain excessive latency.
    QueueLimit := EnsureRange(Ceil(FInfo.SampleRate * BufferedSeconds / BlockFrames),
      2, MaxQueueBlocks - 1);
    SetLength(Samples, BlockFrames * FInfo.Channels);
    HaveGeneration := False;
    WasPlaying := False;
    AtEnd := False;
    PendingBlock := False;
    Count := 0;
    DevicePaused := False;
    AppliedGeneration := 0;
    while not Terminated do
    begin
      FLock.Acquire;
      try
        Current := FStatus;
        Generation := FGeneration;
        Volume := FVolume;
        Target := FSeekSeconds;
      finally
        FLock.Release;
      end;
      if Current.State = TAudioPlayerState.Stopped then
      begin
        if (Audio <> nil) and (WasPlaying or HaveGeneration or DevicePaused) then
        begin
          Audio.Clear;
          if DevicePaused then
            Audio.SetPaused(False);
        end;
        DevicePaused := False;
        PendingBlock := False;
        WasPlaying := False;
        HaveGeneration := False;
        FWake.WaitFor(50);
        Continue;
      end;
      try
        if not HaveGeneration or (AppliedGeneration <> Generation) then
        begin
          if Audio <> nil then
            Audio.Clear;
          PendingBlock := False;
          if not MoveDecoder(Current.Track, Target, Generation, Actual) then
            Continue;
          FLock.Acquire;
          try
            if FGeneration <> Generation then
              Continue;
            FStatus.Seconds := Actual;
            FStatus.Seeking := False;
          finally
            FLock.Release;
          end;
          AppliedGeneration := Generation;
          HaveGeneration := True;
          AtEnd := False;
        end;
        if Current.State <> TAudioPlayerState.Playing then
        begin
          if WasPlaying and (Audio <> nil) and not DevicePaused then
            DevicePaused := Audio.SetPaused(True);
          // A backend without pause support drains its existing short queue;
          // clearing it would discard samples already consumed by the decoder.
          WasPlaying := False;
          FWake.WaitFor(50);
          Continue;
        end;
        if Audio = nil then
          if Assigned(FAudioFactory) then
            Audio := FAudioFactory(AudioFormat)
          else
            Audio := TPCMAudio.Create(AudioFormat);
        if (Audio.Error <> '') or not Audio.QueueState.DeviceOpen then
          raise EInvalidOpException.Create('PCM audio device: ' + Audio.Error);
        if DevicePaused then
        begin
          if not Audio.SetPaused(False) then
            raise EInvalidOpException.Create('PCM audio device could not resume');
          DevicePaused := False;
        end;
        WasPlaying := True;
        if AtEnd then
        begin
          if Audio.QueueState.QueuedBlocks = 0 then
          begin
            FLock.Acquire;
            try
              if (FGeneration = Generation) and (FStatus.State = TAudioPlayerState.Playing) then
              begin
                FStatus.State := TAudioPlayerState.Finished;
                if FStatus.DurationSeconds < 0 then
                  FStatus.DurationSeconds := FStatus.Seconds;
              end;
            finally
              FLock.Release;
            end;
          end;
          FWake.WaitFor(5);
          Continue;
        end;
        // Queue length paces emulation; do not render music against wall time.
        if Audio.QueueState.QueuedBlocks >= QueueLimit then
        begin
          FWake.WaitFor(5);
          Continue;
        end;
        if not PendingBlock then
        begin
          Count := FDecoder.Render(Samples, BlockFrames);
          if (Count < 0) or (Count > BlockFrames) then
            raise EInvalidOpException.Create('Decoder returned an invalid PCM frame count');
          for I := 0 to Count * FInfo.Channels - 1 do
            Samples[I] := (Integer(Samples[I]) * Volume) div 100;
          PendingBlock := True;
        end;
        FLock.Acquire;
        try
          // Generation changes discard obsolete PCM; pause retains the block.
          if (FGeneration = Generation) and (FStatus.State = TAudioPlayerState.Playing) then
          begin
            PendingBlock := False;
            if Count = 0 then
              AtEnd := True
            else
            begin
              Audio.Submit(Samples, Count);
              for I := 0 to Count - 1 do
              begin
                Sum := 0;
                for Channel := 0 to FInfo.Channels - 1 do
                  Inc(Sum, Samples[I * FInfo.Channels + Channel]);
                FPCMWindow[FPCMPosition] := Sum / (32768.0 * FInfo.Channels);
                FStereoWindow.Left[FPCMPosition] := Samples[I * FInfo.Channels] / 32768.0;
                if FInfo.Channels > 1 then
                  FStereoWindow.Right[FPCMPosition] := Samples[I * FInfo.Channels + 1] / 32768.0
                else
                  FStereoWindow.Right[FPCMPosition] := FStereoWindow.Left[FPCMPosition];
                FPCMPosition := (FPCMPosition + 1) mod AudioFFTSize;
              end;
              FStatus.Seconds := FStatus.Seconds + Count / FInfo.SampleRate;
            end;
          end;
        finally
          FLock.Release;
        end;
      except
        on E: Exception do
        begin
          if Audio <> nil then
            Audio.Clear;
          FreeAndNil(Audio);
          DevicePaused := False;
          PendingBlock := False;
          WasPlaying := False;
          HaveGeneration := False;
          FLock.Acquire;
          try
            if FGeneration = Generation then
            begin
              FStatus.Error := E.Message;
              FStatus.Seeking := False;
              FStatus.State := TAudioPlayerState.Stopped;
            end;
          finally
            FLock.Release;
          end;
        end;
      end;
    end;
  except
    on E: Exception do
      SetFailure(E.Message);
  end;
  Audio.Free;
end;

end.

