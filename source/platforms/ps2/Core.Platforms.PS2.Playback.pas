unit Core.Platforms.PS2.Playback;

interface

uses
  System.Classes,
  System.SyncObjs,
  System.SysUtils,
  PS2.HostTempo,
  PCM.Audio,
  PCM.Audio.Backend;

type
  // One owner (the emulation worker). SPU2 produces 48000 Hz stereo, passed
  // through unchanged; the queue is the real-time clock: the worker runs the
  // next field only while CanAdvance.
  TPS2AudioPlayback = class
  public
    const
      SampleRate = 48000;
      BlockFrames = 1024;
      BlockCount = 24;
      TargetBlocks = 6; // About 130 ms queued.
  private
    FAudio: TPCMAudio;
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FTempo: TPS2HostTempo;
    FPriming, FCanPause: Boolean;
    FClockKnown, FResumeField: Boolean;
    FUseReserve, FArmed: Boolean;
    FTimed, FStopping: Boolean;
    FTestBackend: Boolean;
    FWake: TEvent;
    FGate: TCriticalSection;
    FServiceThread: TThread;
    FFieldExtra, FExtraBudget, FElapsedCarry, FLastServiceElapsed, FResumeElapsed: Integer;
    FResumeGrain: TArray<SmallInt>;
    FGrain: TArray<SmallInt>;
    FWorkStart, FNextCheck: Int64;
    FDeviceAt: Int64;
    FDeviceLead: Integer;
    FServiceError: string;
    FClockClears, FLastPlayed: Cardinal;
    FRecoveryLimit, FRecoveryPeak, FRecoveryFields: Integer;
    FSubmittedBase, FPlayed: UInt64;
    function HoldFrames: Integer;
    procedure ServiceWait;
    procedure ServiceElapsed(Elapsed: Integer);
    procedure StartService;
    procedure WaitForDeadline;
    procedure FeedDuringWork(Elapsed: Integer);
    function FeedGrain(const S: TPCMAudioQueueState; Total: UInt64; N, Device, Elapsed: Integer): Boolean;
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
    procedure EnqueueTimed(const Samples: array of SmallInt; Volume: Single; WorkTicks, Frequency: Int64);
    procedure Pump;
    function CanAdvance: Boolean;
    procedure BeginWork(AlreadyCovered: Integer = 0);
    function BeginDisplayInterval: Boolean;
    function EndDisplayInterval(KeepSeed: Boolean = True): Integer;
    procedure EndWork;
  end;

implementation

uses
  System.Math,
  System.Diagnostics,
  PS2.AudioWait;

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
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  FUseReserve := True;
{$ENDIF}
  FTestBackend := Backend <> nil;
  FTempo := TPS2HostTempo.Create;
  FTempo.Clear;
  ResetClock(State);
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

destructor TPS2AudioPlayback.Destroy;
begin
  EndWork;
  if FServiceThread <> nil then
  begin
    FGate.Acquire;
    try
      FStopping := True;
      FWake.SetEvent;
    finally
      FGate.Release;
    end;
    FServiceThread.WaitFor;
    FServiceThread.Free;
  end;
  FWake.Free;
  FGate.Free;
  FTempo.Free;
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
  FResumeGrain := nil;
  // All buffers are ours. Capture the lifetime-submission and device-position
  // origins together while the queue is empty (construction, Clear or underrun).
  FDeviceAt := 0;
  FDeviceLead := 0;
  FRecoveryLimit := 0;
  FRecoveryPeak := 0;
  FRecoveryFields := 0;
  FClockKnown := S.PositionKnown and (S.QueuedBlocks = 0);
  FClockClears := S.Clears;
  FLastPlayed := S.PlayedSamples;
  FSubmittedBase := S.SubmittedSamples;
  FPlayed := 0;
end;

function TPS2AudioPlayback.QueuedFrames(const S: TPCMAudioQueueState; out Frames: UInt64): Boolean;
begin
  Result := False;
  if not FClockKnown or not S.PositionKnown then
    Exit;
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
  EndWork;
  FTimed := False;
  State;
  FServiceError := '';
  FTempo.Clear;
  FCount := 0;
  FResumeField := False;
  FAudio.Clear;
  ResetClock(State);
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

procedure TPS2AudioPlayback.Enqueue(const Samples: array of SmallInt; Volume: Single);
begin
  FResumeGrain := nil;
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

procedure TPS2AudioPlayback.StartService;
begin
  if not FUseReserve or FTestBackend or (FServiceThread <> nil) then
    Exit;
  FGate := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FServiceThread := TThread.CreateAnonymousThread(procedure begin WaitForDeadline; end);
  FServiceThread.FreeOnTerminate := False;
  FServiceThread.Start;
end;

procedure TPS2AudioPlayback.EnqueueTimed(const Samples: array of SmallInt; Volume: Single; WorkTicks, Frequency: Int64);
begin
  if FServiceError <> '' then
  begin
    var Message := FServiceError;
    FServiceError := '';
    raise EInOutError.Create(Message);
  end;
  var Frames: UInt64;
  StartService;
  FTimed := True;
  var Actual := QueuedFrames(State, Frames);
  var Level := -1;
  if Actual and not FPriming then
    Level := Integer(Min(Frames, UInt64(BlockFrames * BlockCount)));
  var WorkFrames := Integer(Min(WorkTicks, Frequency) * SampleRate div Frequency);
  var WasStretching := FTempo.Stretching;
  var Presented: TArray<SmallInt>;
  if FTempo.Expand(Samples, WorkFrames, Level, Presented) then
    Enqueue(Presented, Volume)
  else
    Enqueue(Samples, Volume);
  if FTempo.Stretching or FPriming or not Actual then
  begin
    FRecoveryLimit := 0;
    Exit;
  end;
  if not WasStretching and (FRecoveryLimit = 0) then
    Exit;
  if not QueuedFrames(State, Frames) then
  begin
    FRecoveryLimit := 0;
    Exit;
  end;
  var After := Integer(Min(Frames, UInt64(BlockFrames * BlockCount)));
  var Normal := TargetBlocks * BlockFrames;
  if WasStretching then
  begin
    FRecoveryPeak := 0;
    FRecoveryFields := 0;
    if After > Normal then
    begin
      FRecoveryLimit := After + 1;
    end
    else
      FRecoveryLimit := 0;
  end
  else
  begin
    // Heavy and light fields can alternate. Lower the high-water mark
    // only to a surplus the device has actually consumed over a full window.
    FRecoveryPeak := Max(FRecoveryPeak, After);
    Inc(FRecoveryFields);
    if FRecoveryFields >= 8 then
    begin
      if FRecoveryPeak <= Normal then
        FRecoveryLimit := 0
      else
        FRecoveryLimit := Min(FRecoveryLimit, FRecoveryPeak + 1);
      FRecoveryPeak := 0;
      FRecoveryFields := 0;
    end;
  end;
end;

procedure TPS2AudioPlayback.SubmitBlock(Frames: Integer);
begin
  FResumeGrain := nil;
  FAudio.Submit(FPending, Frames);
  Dec(FCount, Frames * 2);
  if FCount > 0 then
    Move(FPending[Frames * 2], FPending[0], FCount * SizeOf(SmallInt));
end;

function TPS2AudioPlayback.HoldFrames: Integer;
begin
  Result := 0;
  if FUseReserve and FTimed and FClockKnown and not FPriming then
    Result := EnsureRange(FTempo.TargetFrames - 3 * BlockFrames, 0, 3 * BlockFrames);
end;

function TPS2AudioPlayback.BeginDisplayInterval: Boolean;
begin
  Result := False;
  if (HoldFrames = 0) or (FCount < 2) then
    Exit;
  var Frames: UInt64;
  if not QueuedFrames(State, Frames) or (Frames < UInt64(FCount div 2)) then
    Exit;
  // Pending stereo frames can be supplied during this interval, but the
  // device cannot play them until the service has actually submitted them.
  FDeviceLead := Integer(Min(Frames - UInt64(FCount div 2), UInt64(BlockFrames * BlockCount)));
  FDeviceAt := TStopwatch.GetTimeStamp;
  BeginWork;
  Result := True;
end;

function TPS2AudioPlayback.EndDisplayInterval(KeepSeed: Boolean): Integer;
begin
  if FGate <> nil then
    FGate.Acquire;
  try
    FArmed := False;
    if KeepSeed then
      FResumeGrain := FGrain
    else
      FResumeGrain := nil;
    FResumeElapsed := FLastServiceElapsed;
    FGrain := nil;
    Result := FFieldExtra;
  finally
    if FGate <> nil then
      FGate.Release;
  end;
end;

procedure TPS2AudioPlayback.BeginWork(AlreadyCovered: Integer);
begin
  if (HoldFrames = 0) or (FCount < 2) then
    Exit;
  if FGate <> nil then
    FGate.Acquire;
  try
    FArmed := True;
    FFieldExtra := 0;
    FExtraBudget := Max(0, 12288 - AlreadyCovered);
    FElapsedCarry := 0;
    FLastServiceElapsed := 0;
    if (AlreadyCovered > 0) and (Length(FResumeGrain) > 0) then
    begin
      // The matched suffix still starts at the same sample. Any submission,
      // enqueue or clock reset between owners cancels this continuation.
      FGrain := FResumeGrain;
      FElapsedCarry := Max(0, FResumeElapsed - AlreadyCovered);
    end;
    FResumeGrain := nil;
    FWorkStart := TStopwatch.GetTimeStamp;
    FNextCheck := FWorkStart + TStopwatch.Frequency div 250;
    if FDeviceAt <> 0 then
      FNextCheck :=
        Max(FNextCheck, FDeviceAt + Int64(Max(0, FDeviceLead - 2304)) * TStopwatch.Frequency div SampleRate);
    if FWake <> nil then
      FWake.SetEvent;
  finally
    if FGate <> nil then
      FGate.Release;
  end;
end;

procedure TPS2AudioPlayback.EndWork;
begin
  if FGate <> nil then
    FGate.Acquire;
  try
    FArmed := False;
    FGrain := nil;
    FResumeGrain := nil;
  finally
    if FGate <> nil then
      FGate.Release;
  end;
end;

// During RunFrame the guest has no access to the device or to unsent PCM.
// EndWork takes the same lock before the producer can use either again.
procedure TPS2AudioPlayback.WaitForDeadline;
begin
  var Delay: Cardinal := High(Cardinal);
  while True do
  begin
    FWake.WaitFor(Delay);
    FGate.Acquire;
    try
      if FStopping then
        Exit;
      Delay := High(Cardinal);
      if FArmed and (FCount > 0) and (FServiceError = '') then
      begin
        var Now := TStopwatch.GetTimeStamp;
        if Now >= FNextCheck then
          ServiceWait;
        if FArmed and (FCount > 0) and (FServiceError = '') then
          Delay :=
            Cardinal(
              EnsureRange((FNextCheck - TStopwatch.GetTimeStamp) * 1000 div TStopwatch.Frequency, Int64(1), Int64(1000))
            );
      end;
    finally
      FGate.Release;
    end;
  end;
end;

function TPS2AudioPlayback.FeedGrain(const S: TPCMAudioQueueState; Total: UInt64; N, Device, Elapsed: Integer): Boolean;
begin
  Result := False;
  if (Elapsed < 1056) or (Device > 1440) or (FFieldExtra >= FExtraBudget) then
    Exit;
  if Length(FGrain) = 0 then
  begin
    if (N < 256) or (N > 2048) then
      Exit;
    if (Elapsed < 1920) and (Device > 960) then
      Exit;
    var Prefix: Integer;
    if not TakeSplice(FPending, N, Prefix, FGrain) then
      Exit;
    while Prefix > 0 do
    begin
      var Part := Min(Prefix, BlockFrames);
      SubmitBlock(Part);
      Dec(Prefix, Part);
    end;

    Exit(True);
  end;
  var L := Length(FGrain) div 2;
  // Device capacity, total queue budget and actual elapsed overrun are
  // independent limits. A completed field never forces a long planned loop.
  var Free := Min(FTempo.TargetFrames - Integer(Total), FExtraBudget - FFieldExtra);
  Free := Min(Free, Elapsed - 800 - FFieldExtra + 256);
  if Free < L then
    Exit(True);
  var C := Min(BlockFrames div L, Free div L);
  if (C < 1) or (S.QueuedBlocks >= BlockCount) then
    Exit(True);
  var Samples: TArray<SmallInt>;
  SetLength(Samples, C * Length(FGrain));
  for var I := 0 to C - 1 do
    Move(FGrain[0], Samples[I * Length(FGrain)], Length(FGrain) * 2);
  FAudio.Submit(Samples, C * L);
  Inc(FFieldExtra, C * L);
  Result := True;
end;

procedure TPS2AudioPlayback.FeedDuringWork(Elapsed: Integer);
begin
  if not FArmed or (Elapsed < 192) or FPriming then
    Exit;
  var S := State;
  if S.QueuedBlocks = 0 then
  begin
    Pump;
    FArmed := False;
    Exit;
  end;
  var Total: UInt64;
  if not QueuedFrames(S, Total) then
    Exit;
  var N := FCount div 2;
  if (N = 0) or (Total < UInt64(N)) then
    Exit;
  var Device := Min(Integer(Total) - N, S.QueuedBlocks * BlockFrames);
  if Device > 2304 then
  begin
    FNextCheck := TStopwatch.GetTimeStamp + Int64(Device - 2304) * TStopwatch.Frequency div SampleRate;
    Exit;
  end;
  if FeedGrain(S, Total, N, Device, Elapsed) then
    Exit;
  if (Elapsed >= 1920) and (N >= 1024) and (Device <= 1440) then
  begin
    var Free := FTempo.TargetFrames - Integer(Total);
    // Use only enough original signal for this low-water interval. Preserve
    // an independently usable suffix rather than spending all samples early.
    var Part := EnsureRange(Free div 2, 1024, 1536);
    if N - Part < 1024 then
      if N >= 2048 then
        Part := N - 1024
      else
        Part := N;
    var Extra := Min(2 * Part, Min(FExtraBudget - FFieldExtra, FTempo.TargetFrames - Integer(Total)));
    if (Extra >= 512)
      and (Part <= 8192)
      and (S.QueuedBlocks + (Part + Extra + BlockFrames - 1) div BlockFrames <= BlockCount) then
    begin
      // Submit a complete expanded prefix. Its final samples are original,
      // and the following, still-unsubmitted suffix can cover a longer stall.
      var Original := FPending;
      FPending := StretchReserve(Original, Part, Extra);
      FCount := Length(FPending);
      while FCount > 0 do
        SubmitBlock(Min(BlockFrames, FCount div 2));
      FPending := Original;
      FCount := (N - Part) * 2;
      if FCount > 0 then
        Move(FPending[Part * 2], FPending[0], FCount * SizeOf(SmallInt));
      Inc(FFieldExtra, Extra);
      Exit;
    end;
  end;
  if (Device <= 960) or (S.QueuedBlocks = 1) then
  begin
    var Len := Min(N, BlockFrames);
    if (N >= 1536) and (Elapsed < 1920) then
      Len := 512;
    if (Elapsed < 1056) and (N >= 256) and (Device > 384) then
      Len := Min(Len, Max(0, N - 576));
    if Len = 0 then
      Exit;
    SubmitBlock(Len);
  end;
end;

procedure TPS2AudioPlayback.ServiceWait;
begin
  var Now := TStopwatch.GetTimeStamp;
  if not FArmed or (Now < FNextCheck) then
    Exit;
  FNextCheck := Now + TStopwatch.Frequency div 250;
  try
    ServiceElapsed(Integer(Min(Now - FWorkStart, TStopwatch.Frequency) * SampleRate div TStopwatch.Frequency));
  except
    on E: Exception do
    begin
      FServiceError := E.Message;
      FArmed := False;
    end;
  end;
end;

procedure TPS2AudioPlayback.ServiceElapsed(Elapsed: Integer);
begin
  FLastServiceElapsed := Elapsed;
  FeedDuringWork(Elapsed + FElapsedCarry);
end;

procedure TPS2AudioPlayback.Pump;
begin
  var S := State;
  // An underrun restarts priming so playback resumes with a full cushion.
  if not FPriming and (S.QueuedBlocks = 0) then
  begin
    // Keep the recovery permission while priming; consume it after restart.
    FResumeField := True;
    FPriming := True;
    if FCanPause then
      FAudio.SetPaused(True);
    ResetClock(State);
  end;
  var Hold := HoldFrames;
  while (FCount >= BlockFrames * 2)
    and (S.QueuedBlocks < BlockCount)
    and ((S.QueuedBlocks < 4 - Ord(FUseReserve and FTimed)) or (FCount div 2 >= Hold + BlockFrames)) do
  begin
    SubmitBlock(BlockFrames);
    S := State;
  end;
  if (not FUseReserve or (S.QueuedBlocks <= 2))
    and TimelyRefill
    and FTempo.Stretching
    and not FPriming
    and (S.QueuedBlocks <= 6)
    and (FCount >= 512)
    and (FCount < BlockFrames * 2) then
  begin
    SubmitBlock(FCount div 2);
    S := State;
  end;
  var CurrentTarget := (FTempo.TargetFrames + BlockFrames - 1) div BlockFrames;
  if FPriming and ((S.QueuedBlocks >= CurrentTarget) or (not FCanPause and (S.QueuedBlocks > 0))) then
  begin
    if FCanPause and not FAudio.SetPaused(False) then
      raise EInOutError.Create('PS2 audio playback could not start');
    FResumeField := FResumeField and FCanPause and (S.QueuedBlocks <= CurrentTarget);
    FPriming := False;
  end;
end;

function TPS2AudioPlayback.CanAdvance: Boolean;
begin
  Pump;
  if FCount div 2 >= HoldFrames + BlockFrames then
    Exit(False);
  if FPriming then
    Exit(True);
  var S := State;
  var CurrentTarget := (FTempo.TargetFrames + BlockFrames - 1) div BlockFrames;
  var Frames: UInt64;
  var Known := QueuedFrames(S, Frames);
  if Known and FUseReserve then
  begin
    // Only submitted samples protect the device while the producer is away.
    FDeviceLead := Integer(Min(Frames - UInt64(FCount div 2), UInt64(BlockFrames * BlockCount)));
    FDeviceAt := TStopwatch.GetTimeStamp;
  end;
  if Known then
    Result := Frames < UInt64(Max(CurrentTarget * BlockFrames, FRecoveryLimit))
  else
    Result := S.QueuedBlocks < CurrentTarget;
  if FResumeField then
  begin
    FResumeField := False;
    // Overlap one field with the device restart after an underrun. Pending
    // samples otherwise stall a producer already behind real time at once.
    if Known then
      if (S.QueuedBlocks <= CurrentTarget) and (Frames < (CurrentTarget + 1) * BlockFrames) then
        Result := True;
  end;
end;

end.
