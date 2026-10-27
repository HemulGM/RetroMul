unit Core.N64.Playback;
// PCM preparation also stays optimized in application Debug builds.
{$IFNDEF N64_CHECKED}{$O+}{$ENDIF}

interface

uses
  System.SysUtils, PCM.Audio, PCM.Audio.Backend;

type
  TN64PlaybackStats = record
    GeneratedFrames, SubmittedFrames, DroppedFrames, ClearedFrames: UInt64;
    EmptyQueueEvents, Starts: UInt64;
    PendingFrames, QueuedBlocks: Integer;
    Playing, BilinearFiltering: Boolean;
    MaxSupplyGapMS: Double;
    EmulationMS, VIWaitMS, RSPWaitMS, RDPWaitMS: Double;
    RDPThreads, RDPThreadChanges: Integer;
  end;

  // One owner (the emulation thread). The device clock paces the guest;
  // pending PCM is retained until a native header is available.
  TN64AudioPlayback = class
  public const
    SampleRate = 48000;
    BlockFrames = 1024;
    BlockCount = 16;
    TargetBlocks = 12; // 256 ms, including sustained bursts of expensive fields.
  private
    FAudio: TPCMAudio;
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FPriming, FCanPause, FEmpty: Boolean;
    FStats: TN64PlaybackStats;
    FLastSupply: Int64;
    FDeviceState: TPCMAudioQueueState;
    function State: TPCMAudioQueueState;
    procedure SubmitBlock(Frames: Integer);
  public
    constructor Create(const Backend: IPCMAudioBackend = nil);
    destructor Destroy; override;
    class function AudioFormat: TPCMAudioFormat; static;
    procedure Clear;
    procedure Enqueue(const Samples: array of SmallInt; Volume: Single);
    procedure Pump;
    function CanAdvance: Boolean;
    // End of a finite recording: submit the final partial block when there
    // is room. The caller stops generating and may poll until Pending=0.
    procedure Finish;
    // False uses the state just acquired by Pump/Enqueue/Clear.
    function Stats(RefreshDevice: Boolean = True): TN64PlaybackStats;
  end;

implementation

uses System.Math, System.Diagnostics;

class function TN64AudioPlayback.AudioFormat: TPCMAudioFormat;
begin
  Result.SampleRate := SampleRate;
  Result.Channels := 2;
  Result.BlockFrames := BlockFrames;
  Result.BlockCount := BlockCount;
end;

constructor TN64AudioPlayback.Create(const Backend: IPCMAudioBackend);
begin
  inherited Create;
  if Backend = nil then FAudio := TPCMAudio.Create(AudioFormat)
  else FAudio := TPCMAudio.Create(AudioFormat, Backend);
  State;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

destructor TN64AudioPlayback.Destroy;
begin
  FAudio.Free;
  inherited;
end;

function TN64AudioPlayback.State: TPCMAudioQueueState;
begin
  if FAudio.Error <> '' then raise EInOutError.Create(FAudio.Error);
  Result := FAudio.QueueState;
  if not Result.DeviceOpen then
    raise EInOutError.Create('N64 audio output is unavailable');
  FDeviceState := Result;
end;

procedure TN64AudioPlayback.Clear;
begin
  State;
  // Clear intentionally cancels playback on pause/reset/load/mute.
  Inc(FStats.ClearedFrames, FCount div 2);
  FCount := 0;
  FAudio.Clear;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
  FEmpty := False;
  FLastSupply := 0;
  State;
end;

procedure TN64AudioPlayback.Enqueue(const Samples: array of SmallInt; Volume: Single);
begin
  if Odd(Length(Samples)) then
    raise EArgumentException.Create('N64 PCM must contain stereo frames');
  if Length(Samples) = 0 then Exit;
  var Now := TStopwatch.GetTimeStamp;
  if (FLastSupply <> 0) and not FPriming then
    FStats.MaxSupplyGapMS := Max(FStats.MaxSupplyGapMS,
      (Now - FLastSupply) * (1000.0 / TStopwatch.Frequency));
  FLastSupply := Now;
  if Length(FPending) < FCount + Length(Samples) then
    SetLength(FPending, Max(FCount + Length(Samples), BlockFrames * 4));
  if Volume = 0 then
    FillChar(FPending[FCount], Length(Samples) * SizeOf(SmallInt), 0)
  else if Volume = 1 then
    Move(Samples[0], FPending[FCount], Length(Samples) * SizeOf(SmallInt))
  else
    for var I := 0 to High(Samples) do
      FPending[FCount + I] := EnsureRange(Round(Samples[I] * Volume), -32768, 32767);
  Inc(FCount, Length(Samples));
  Inc(FStats.GeneratedFrames, Length(Samples) div 2);
  Pump;
end;

procedure TN64AudioPlayback.SubmitBlock(Frames: Integer);
begin
  FAudio.Submit(FPending, Frames);
  Dec(FCount, Frames * 2);
  if FCount > 0 then
    Move(FPending[Frames * 2], FPending[0], FCount * SizeOf(SmallInt));
end;

procedure TN64AudioPlayback.Pump;
begin
  var S := State;
  if not FPriming and (S.QueuedBlocks = 0) then
  begin
    if not FEmpty then Inc(FStats.EmptyQueueEvents);
    FEmpty := True;
    FPriming := True;
    if FCanPause then FAudio.SetPaused(True);
  end;
  while (FCount >= BlockFrames * 2) and (S.QueuedBlocks < BlockCount) do
  begin
    SubmitBlock(BlockFrames);
    S := State;
  end;
  if FPriming and ((S.QueuedBlocks >= TargetBlocks) or
    (not FCanPause and (S.QueuedBlocks > 0))) then
  begin
    if FCanPause and not FAudio.SetPaused(False) then
      raise EInOutError.Create('N64 audio playback could not start');
    FPriming := False;
    FEmpty := False;
    Inc(FStats.Starts);
  end;
end;

function TN64AudioPlayback.CanAdvance: Boolean;
begin
  Pump;
  // Pump already acquired the device queue, including any submitted blocks.
  var S := FDeviceState;
  Result := (FCount < BlockFrames * 2) and
    (FPriming or (S.QueuedBlocks < TargetBlocks));
end;

procedure TN64AudioPlayback.Finish;
begin
  Pump;
  if (FCount > 0) and (State.QueuedBlocks < BlockCount) then
    SubmitBlock(FCount div 2);
  if FPriming and (State.QueuedBlocks > 0) then
  begin
    if FCanPause then FAudio.SetPaused(False);
    FPriming := False;
    Inc(FStats.Starts);
  end;
end;

function TN64AudioPlayback.Stats(RefreshDevice: Boolean): TN64PlaybackStats;
begin
  Result := FStats;
  var S := FDeviceState;
  if RefreshDevice then S := State;
  Result.SubmittedFrames := S.SubmittedSamples;
  Result.DroppedFrames := S.DroppedSamples;
  Result.PendingFrames := FCount div 2;
  Result.QueuedBlocks := S.QueuedBlocks;
  Result.Playing := not FPriming;
end;

end.
