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
    Seconds: Double;
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
    FStarted: Boolean;
    FPCMWindow: TTunePCMWindow;
    FPCMPosition: Integer;
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
    procedure SetVolume(Percent: Integer);
    function Status: TTunePlayerStatus;
    procedure GetVisualization(out Samples: TTunePCMWindow; out SampleRate: Integer);
  end;

implementation

uses
  PCM.Audio;

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
    ClearVisualization;
    FStatus.Seconds := 0;
    FStatus.Error := '';
    Inc(FGeneration);
    if FStatus.State = TTunePlayerState.Finished then
      FStatus.State := TTunePlayerState.Stopped;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
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
      finally
        FLock.Release;
      end;
      if (Current.State <> TTunePlayerState.Playing) then
      begin
        if WasPlaying and (Audio <> nil) then
          Audio.Clear;
        WasPlaying := False;
        FWake.WaitFor(50);
        Continue;
      end;
      try
        if Audio = nil then
          Audio := TPCMAudio.Create(AudioFormat);
        if (Audio.Error <> '') or not Audio.QueueState.DeviceOpen then
          raise EInvalidOpException.Create('PCM audio device: ' + Audio.Error);
        if not HaveGeneration or (AppliedGeneration <> Generation) then
        begin
          Audio.Clear;
          FDecoder.SelectTrack(Current.Track);
          AppliedGeneration := Generation;
          HaveGeneration := True;
          AtEnd := False;
        end;
        WasPlaying := True;
        if AtEnd then
        begin
          if Audio.QueueState.QueuedBlocks = 0 then
          begin
            FLock.Acquire;
            try
              if FGeneration = Generation then
                FStatus.State := TTunePlayerState.Finished;
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

