unit RetroTune.Player;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs, RetroTune.Decoder,
  RetroTune.Spectrum;

type
  TTunePlayerState = (Stopped, Playing, Paused, Finished);

  TTunePlayerStatus = record
    State: TTunePlayerState;
    Track: Integer;
    Seconds, DurationSeconds: Double;
    Seeking: Boolean;
    Error: string;
  end;

  // The worker owns the decoder and PCM device. The UI sends commands only;
  // no UI object or queued callback is retained by this thread.
  TTunePlayer = class(TThread)
  private
    FDecoder: ITuneDecoder;
    FInfo: TTuneInfo;
    FLock: TCriticalSection;
    FWake: TEvent;
    FStatus: TTunePlayerStatus;
    FGeneration: UInt64;
    FVolume: Integer;
    FSeekSeconds: Double;
    FStarted: Boolean;
    FPCMWindow: TTunePCMWindow;
    FStereoWindow: TTuneStereoWindow;
    FPCMPosition: Integer;
    function MoveDecoder(Track: Integer; Seconds: Double; Generation: UInt64; out Actual: Double): Boolean;
    procedure SetTrackDuration;
    procedure ClearVisualization;
    procedure SetFailure(const MessageText: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Decoder: ITuneDecoder);
    destructor Destroy; override;
    procedure Play;
    procedure Pause;
    procedure Stop;
    procedure SelectTrack(Index: Integer);
    procedure Seek(Seconds: Double);
    procedure SetVolume(Percent: Integer);
    function Status: TTunePlayerStatus;
    procedure GetVisualization(out Samples: TTunePCMWindow; out SampleRate: Integer);
    // Atomic chronological L/R snapshot. Mono sources are duplicated.
    procedure GetStereoVisualization(out Samples: TTuneStereoWindow; out SampleRate: Integer);
  end;

implementation

uses
  PCM.Audio, System.Math;

constructor TTunePlayer.Create(const Decoder: ITuneDecoder);
begin
  // TThread.AfterConstruction starts it only after all fields are initialized.
  inherited Create(False);
  FreeOnTerminate := False;
  if Decoder = nil then
    raise EArgumentNilException.Create('Decoder is required');

  FDecoder := Decoder;
  FInfo := Decoder.GetInfo;
  if (FInfo.TrackCount < 1) or (FInfo.DefaultTrack < 0) or (FInfo.DefaultTrack >= FInfo.TrackCount) then
    raise EArgumentException.Create('Invalid decoder track information');

  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FStatus.Track := FInfo.DefaultTrack;
  SetTrackDuration;
  FStatus.State := TTunePlayerState.Stopped;
  FVolume := 80;
  FStarted := True;
end;

destructor TTunePlayer.Destroy;
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

procedure TTunePlayer.Play;
begin
  FLock.Acquire;
  try
    if FStatus.State in [TTunePlayerState.Stopped, TTunePlayerState.Finished] then
    begin
      Inc(FGeneration);
      FStatus.Seconds := 0;
      FSeekSeconds := 0;
      FStatus.Seeking := False;
      ClearVisualization;
    end;
    FStatus.Error := '';
    FStatus.State := TTunePlayerState.Playing;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TTunePlayer.Pause;
begin
  FLock.Acquire;
  try
    if FStatus.State = TTunePlayerState.Playing then
      FStatus.State := TTunePlayerState.Paused;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TTunePlayer.Stop;
begin
  FLock.Acquire;
  try
    FStatus.State := TTunePlayerState.Stopped;
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

procedure TTunePlayer.SelectTrack(Index: Integer);
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
    if FStatus.State = TTunePlayerState.Finished then
      FStatus.State := TTunePlayerState.Stopped;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TTunePlayer.SetTrackDuration;
begin
  FStatus.DurationSeconds := -1;
  if FStatus.Track < Length(FInfo.TrackDurations) then
    FStatus.DurationSeconds := FInfo.TrackDurations[FStatus.Track];
end;

procedure TTunePlayer.Seek(Seconds: Double);
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
    if FStatus.State in [TTunePlayerState.Stopped, TTunePlayerState.Finished] then
      FStatus.State := TTunePlayerState.Paused;
    ClearVisualization;
    Inc(FGeneration);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TTunePlayer.MoveDecoder(Track: Integer; Seconds: Double; Generation: UInt64; out Actual: Double): Boolean;
var
  Discard: TArray<SmallInt>;
begin
  Result := False;
  Actual := 0;
  FDecoder.SelectTrack(Track);
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

procedure TTunePlayer.SetVolume(Percent: Integer);
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

function TTunePlayer.Status: TTunePlayerStatus;
begin
  FLock.Acquire;
  try
    Result := FStatus;
  finally
    FLock.Release;
  end;
end;

procedure TTunePlayer.ClearVisualization;
begin
  // Called while FLock is held.
  FillChar(FPCMWindow, SizeOf(FPCMWindow), 0);
  FStereoWindow := Default(TTuneStereoWindow);
  FPCMPosition := 0;
end;

procedure TTunePlayer.GetVisualization(out Samples: TTunePCMWindow; out SampleRate: Integer);
begin
  FLock.Acquire;
  try
    SampleRate := FInfo.SampleRate;
    for var I := 0 to TuneFFTSize - 1 do
      Samples[I] := FPCMWindow[(FPCMPosition + I) mod TuneFFTSize];
  finally
    FLock.Release;
  end;
end;

procedure TTunePlayer.GetStereoVisualization(out Samples: TTuneStereoWindow; out SampleRate: Integer);
begin
  FLock.Acquire;
  try
    SampleRate := FInfo.SampleRate;
    for var I := 0 to TuneFFTSize - 1 do
    begin
      var At := (FPCMPosition + I) mod TuneFFTSize;
      Samples.Left[I] := FStereoWindow.Left[At];
      Samples.Right[I] := FStereoWindow.Right[At];
    end;
  finally
    FLock.Release;
  end;
end;

procedure TTunePlayer.SetFailure(const MessageText: string);
begin
  FLock.Acquire;
  try
    FStatus.Error := MessageText;
    FStatus.State := TTunePlayerState.Stopped;
  finally
    FLock.Release;
  end;
end;

procedure TTunePlayer.Execute;
const
  BlockFrames = 512;
var
  Audio: TPCMAudio;
  AudioFormat: TPCMAudioFormat;
  Samples: TArray<SmallInt>;
  Current: TTunePlayerStatus;
  Generation, AppliedGeneration: UInt64;
  Volume, Count, I, Channel, Sum: Integer;
  HaveGeneration, WasPlaying, AtEnd: Boolean;
  Target, Actual: Double;
begin
  Audio := nil;
  try
    AudioFormat.SampleRate := FInfo.SampleRate;
    AudioFormat.Channels := FInfo.Channels;
    AudioFormat.BlockFrames := BlockFrames;
    AudioFormat.BlockCount := 8;
    SetLength(Samples, BlockFrames * FInfo.Channels);
    HaveGeneration := False;
    WasPlaying := False;
    AtEnd := False;
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
      if Current.State = TTunePlayerState.Stopped then
      begin
        if WasPlaying and (Audio <> nil) then
          Audio.Clear;
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
        if Current.State <> TTunePlayerState.Playing then
        begin
          if WasPlaying and (Audio <> nil) then
            Audio.Clear;
          WasPlaying := False;
          FWake.WaitFor(50);
          Continue;
        end;
        if Audio = nil then
          Audio := TPCMAudio.Create(AudioFormat);
        if (Audio.Error <> '') or not Audio.QueueState.DeviceOpen then
          raise EInvalidOpException.Create('PCM audio device: ' + Audio.Error);
        WasPlaying := True;
        if AtEnd then
        begin
          if Audio.QueueState.QueuedBlocks = 0 then
          begin
            FLock.Acquire;
            try
              if FGeneration = Generation then
              begin
                FStatus.State := TTunePlayerState.Finished;
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
        if Audio.QueueState.QueuedBlocks >= 4 then
        begin
          FWake.WaitFor(5);
          Continue;
        end;
        Count := FDecoder.Render(Samples, BlockFrames);
        if (Count < 0) or (Count > BlockFrames) then
          raise EInvalidOpException.Create('Decoder returned an invalid PCM frame count');
        for I := 0 to Count * FInfo.Channels - 1 do
          Samples[I] := (Integer(Samples[I]) * Volume) div 100;
        FLock.Acquire;
        try
          // Discard a block if stop/track/pause arrived during rendering.
          if (FGeneration = Generation) and (FStatus.State = TTunePlayerState.Playing) then
          begin
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
                FPCMPosition := (FPCMPosition + 1) mod TuneFFTSize;
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
          WasPlaying := False;
          HaveGeneration := False;
          FLock.Acquire;
          try
            if FGeneration = Generation then
            begin
              FStatus.Error := E.Message;
              FStatus.Seeking := False;
              FStatus.State := TTunePlayerState.Stopped;
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

