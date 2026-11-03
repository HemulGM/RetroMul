unit Core.Platforms.PS2.Playback;

interface

uses
  System.SysUtils, PCM.Audio, PCM.Audio.Backend;

type
  // One owner (the emulation worker). SPU2 produces 48000 Hz stereo, passed
  // through unchanged; the queue is the real-time clock: the worker runs the
  // next field only while CanAdvance.
  TPS2AudioPlayback = class
  public const
    SampleRate = 48000;
    BlockFrames = 1024;
    BlockCount = 16;
    TargetBlocks = 6; // About 130 ms queued.
  private
    FAudio: TPCMAudio;
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FPriming, FCanPause: Boolean;
    FClockKnown: Boolean;
    FClockClears, FLastPlayed: Cardinal;
    FSubmittedBase, FPlayed: UInt64;
    function State: TPCMAudioQueueState;
    procedure ResetClock(const S: TPCMAudioQueueState);
    function QueuedFrames(const S: TPCMAudioQueueState; out Frames: UInt64): Boolean;
    procedure SubmitBlock(Frames: Integer);
  public
    constructor Create(const Backend: IPCMAudioBackend = nil);
    destructor Destroy; override;
    class function AudioFormat: TPCMAudioFormat; static;
    // Drops queued and pending audio (pause, reset, snapshot load, mute).
    procedure Clear;
    procedure Enqueue(const Samples: array of SmallInt; Volume: Single);
    procedure Pump;
    function CanAdvance: Boolean;
  end;

implementation

uses
  System.Math;

class function TPS2AudioPlayback.AudioFormat: TPCMAudioFormat;
begin
  Result.SampleRate := SampleRate;
  Result.Channels := 2;
  Result.BlockFrames := BlockFrames;
  Result.BlockCount := BlockCount;
end;

constructor TPS2AudioPlayback.Create(const Backend: IPCMAudioBackend);
begin
  inherited Create;
  if Backend = nil then
    FAudio := TPCMAudio.Create(AudioFormat)
  else
    FAudio := TPCMAudio.Create(AudioFormat, Backend);
  ResetClock(State);
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

destructor TPS2AudioPlayback.Destroy;
begin
  FAudio.Free;
  inherited;
end;

function TPS2AudioPlayback.State: TPCMAudioQueueState;
begin
  if FAudio.Error <> '' then
    raise EInOutError.Create(FAudio.Error);
  Result := FAudio.QueueState;
  if not Result.DeviceOpen then
    raise EInOutError.Create('PS2 audio output is unavailable');
end;

procedure TPS2AudioPlayback.ResetClock(const S: TPCMAudioQueueState);
begin
  // All buffers are ours. Capture the lifetime-submission and device-position
  // origins together while the queue is empty (construction, Clear or underrun).
  FClockKnown := S.PositionKnown and (S.QueuedBlocks = 0);
  FClockClears := S.Clears;
  FLastPlayed := S.PlayedSamples;
  FSubmittedBase := S.SubmittedSamples;
  FPlayed := 0;
end;

function TPS2AudioPlayback.QueuedFrames(const S: TPCMAudioQueueState; out Frames: UInt64): Boolean;
begin
  Result := False;
  if not FClockKnown or not S.PositionKnown then Exit;
  // Unexpected device resets/counter changes retain the old block-count
  // fallback until an empty queue establishes a fresh origin. A normal
  // 32-bit wrap is a small forward delta, not a reset.
  if (S.Clears <> FClockClears) or (S.SubmittedSamples < FSubmittedBase) then
  begin
    FClockKnown := False;
    Exit;
  end;
  var Delta := (UInt64(S.PlayedSamples) + UInt64($100000000) - FLastPlayed) and $FFFFFFFF;
  if Delta > $7FFFFFFF then
  begin
    FClockKnown := False;
    Exit;
  end;
  FLastPlayed := S.PlayedSamples;
  Inc(FPlayed, Delta);
  var Submitted := S.SubmittedSamples - FSubmittedBase;
  if FPlayed > Submitted then
  begin
    FClockKnown := False;
    Exit;
  end;
  // Pending samples count too: a field produces about 800 stereo frames,
  // not a whole 1024-frame device block. Ignoring that fraction releases
  // fields in bursts at block boundaries instead of at the playback rate.
  Frames := Submitted - FPlayed + UInt64(FCount div 2);
  Result := True;
end;

procedure TPS2AudioPlayback.Clear;
begin
  State;
  FCount := 0;
  FAudio.Clear;
  ResetClock(State);
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

procedure TPS2AudioPlayback.Enqueue(const Samples: array of SmallInt; Volume: Single);
begin
  if Odd(Length(Samples)) then
    raise EArgumentException.Create('PS2 PCM must contain stereo frames');
  if Length(Samples) = 0 then
    Exit;
  if Length(FPending) < FCount + Length(Samples) then
    SetLength(FPending, Max(FCount + Length(Samples), BlockFrames * 4));
  for var I := 0 to High(Samples) do
    FPending[FCount + I] := EnsureRange(Round(Samples[I] * Volume), -32768, 32767);
  Inc(FCount, Length(Samples));
  Pump;
end;

procedure TPS2AudioPlayback.SubmitBlock(Frames: Integer);
begin
  FAudio.Submit(FPending, Frames);
  Dec(FCount, Frames * 2);
  if FCount > 0 then
    Move(FPending[Frames * 2], FPending[0], FCount * SizeOf(SmallInt));
end;

procedure TPS2AudioPlayback.Pump;
begin
  var S := State;
  // An underrun restarts priming so playback resumes with a full cushion.
  if not FPriming and (S.QueuedBlocks = 0) then
  begin
    FPriming := True;
    if FCanPause then
      FAudio.SetPaused(True);
    ResetClock(State);
  end;
  while (FCount >= BlockFrames * 2) and (S.QueuedBlocks < BlockCount) do
  begin
    SubmitBlock(BlockFrames);
    S := State;
  end;
  if FPriming and ((S.QueuedBlocks >= TargetBlocks) or (not FCanPause and (S.QueuedBlocks > 0))) then
  begin
    if FCanPause and not FAudio.SetPaused(False) then
      raise EInOutError.Create('PS2 audio playback could not start');
    FPriming := False;
  end;
end;

function TPS2AudioPlayback.CanAdvance: Boolean;
begin
  Pump;
  if FCount >= BlockFrames * 2 then Exit(False);
  if FPriming then Exit(True);
  var S := State;
  var Frames: UInt64;
  if QueuedFrames(S, Frames) then
    Result := Frames < TargetBlocks * BlockFrames
  else
    Result := S.QueuedBlocks < TargetBlocks;
end;

end.
