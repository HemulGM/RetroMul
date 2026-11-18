unit Core.Platforms.J2ME.Playback;

interface

uses
  PCM.Audio, PCM.Audio.Backend;

type
  TJ2MEAudioFactory = reference to function(const Format: TPCMAudioFormat): IPCMAudioBackend;

  // Owned by the emulation worker, sharing RetroMul's cross-platform PCM API.
  TJ2MEAudioPlayback = class
  private
    FAudio: TPCMAudio;
    FPending: TArray<SmallInt>;
    FHead, FCount: Integer;
    FSubmit: array[0..1023] of SmallInt;
    FPrimeSince, FLastAppend, FWriteBlockedSince: UInt64;
    FProgressAt, FLastSubmitted, FLastPlayed: UInt64;
    FLastQueued: Integer;
    FPrimeBlocks, FPrimeWaitMillis: Integer;
    FPriming, FCanPause, FShortWrite, FPaused: Boolean;
    function Check: TPCMAudioQueueState;
    procedure StartPrimed(Queued: Integer);
  public
    constructor Create(const Factory: TJ2MEAudioFactory = nil; PrimeBlocks: Integer = 0);
    destructor Destroy; override;
    class function AudioFormat: TPCMAudioFormat; static;
    function Enqueue(const Samples: TArray<SmallInt>; Volume: Single): Integer;
    procedure Pump;
    function AvailableFrames: Integer;
    function PendingFrames: Integer;
    procedure Clear;
    procedure SetPaused(Value: Boolean);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

class function TJ2MEAudioPlayback.AudioFormat: TPCMAudioFormat;
begin
  Result.SampleRate := 44100;
  Result.Channels := 2;
  Result.BlockFrames := 512;
  {$IFDEF ANDROID}
  // Leave room for a slow guest frame or an Android scheduling delay.
  Result.BlockCount := 16;
  {$ELSE}
  Result.BlockCount := 8;
  {$ENDIF}
end;

constructor TJ2MEAudioPlayback.Create(const Factory: TJ2MEAudioFactory; PrimeBlocks: Integer);
begin
  inherited Create;
  var Format := AudioFormat;
  if PrimeBlocks = 0 then
  {$IFDEF ANDROID}
    PrimeBlocks := Format.BlockCount;
  {$ELSE}
  PrimeBlocks := 2;
  {$ENDIF}
  FPrimeBlocks := EnsureRange(PrimeBlocks, 1, Format.BlockCount);
  FPrimeWaitMillis := 20;
  if FPrimeBlocks > 2 then
    FPrimeWaitMillis := Format.BlockFrames * FPrimeBlocks * 1000 div Format.SampleRate + 32;
  if Assigned(Factory) then
    FAudio := TPCMAudio.Create(Format, Factory(Format))
  else
    FAudio := TPCMAudio.Create(Format);
  Check;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
  // Bounded 371 ms software FIFO in addition to the device queue.
  // The producer observes AvailableFrames before advancing the mixer.
  SetLength(FPending, 16384 * 2);
  FPrimeSince := TThread.GetTickCount64;
end;

destructor TJ2MEAudioPlayback.Destroy;
begin
  FAudio.Free;
  inherited;
end;

function TJ2MEAudioPlayback.Check: TPCMAudioQueueState;
begin
  if FAudio.Error <> '' then
    raise EInOutError.Create(FAudio.Error);
  var State := FAudio.QueueState;
  if not State.DeviceOpen then
    raise EInOutError.Create('Java ME audio output is unavailable');
  var Now := TThread.GetTickCount64;
  // Backpressure may pause the VM while a bounded device queue drains. If an
  // open driver never completes buffers, report failure instead of freezing
  // Java forever. Submitted counts also support backends without positions.
  if FPriming or (State.QueuedBlocks = 0) or
    (State.SubmittedSamples <> FLastSubmitted) or
    (State.PositionKnown and (State.PlayedSamples <> FLastPlayed)) or (State.QueuedBlocks < FLastQueued) or
    (FProgressAt = 0) then
    FProgressAt := Now;
  FLastSubmitted := State.SubmittedSamples;
  if State.PositionKnown then
    FLastPlayed := State.PlayedSamples;
  FLastQueued := State.QueuedBlocks;
  if not FPaused and not FPriming and (State.QueuedBlocks >= AudioFormat.BlockCount) and
    (Now - FProgressAt >= 1000) then
    raise EInOutError.Create('Java ME audio output stalled');
  Result := State;
end;

procedure TJ2MEAudioPlayback.Clear;
begin
  Check;
  FAudio.Clear;
  FCount := 0;
  FHead := 0;
  FShortWrite := False;
  FWriteBlockedSince := 0;
  FPrimeSince := TThread.GetTickCount64;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

procedure TJ2MEAudioPlayback.SetPaused(Value: Boolean);
begin
  if FPaused = Value then
    Exit;
  var State := Check;
  if Value then
  begin
    // The mixer position already includes the queued PCM. Keep it on a
    // normal pause so resume does not start partway through the music.
    if FCanPause then
      FCanPause := FAudio.SetPaused(True);
    if not FCanPause then
      Clear;
  end
  else
  begin
    FProgressAt := TThread.GetTickCount64;
    FPrimeSince := FProgressAt;
    FWriteBlockedSince := 0;
    if FCanPause then
    begin
      // Refill a low device queue before playback consumes the remaining PCM.
      FPriming := FPriming or (State.QueuedBlocks < (FPrimeBlocks + 1) div 2);
      if not FPriming and not FAudio.SetPaused(False) then
        raise EInOutError.Create('Java ME audio output could not resume');
    end;
  end;
  FPaused := Value;
end;

procedure TJ2MEAudioPlayback.StartPrimed(Queued: Integer);
begin
  if not FPriming then
    Exit;
  if FCanPause then
  begin
    if Queued = 0 then
      Exit;
    if (Queued < FPrimeBlocks) and (TThread.GetTickCount64 - FPrimeSince < UInt64(FPrimeWaitMillis)) then
      Exit;
    if not FAudio.SetPaused(False) then
      raise EInOutError.Create('Java ME audio output could not resume');
  end;
  FPriming := False;
end;

function TJ2MEAudioPlayback.PendingFrames: Integer;
begin
  Result := FCount div 2;
end;

function TJ2MEAudioPlayback.AvailableFrames: Integer;
begin
  Pump;
  Result := (Length(FPending) - FCount) div 2;
end;

procedure TJ2MEAudioPlayback.Pump;
begin
  if FPaused then
    Exit;
  var State := Check;
  if not FPriming and (State.QueuedBlocks = 0) then
  begin
    FPriming := True;
    FPrimeSince := TThread.GetTickCount64;
    if FCanPause then
      FCanPause := FAudio.SetPaused(True);
  end;
  // AudioTrack starts as soon as its first block is submitted. Hold a small
  // reserve on the producer side so the first writes can fill the device.
  if FPriming and not FCanPause and (FPrimeBlocks > 2) and
    (FCount < FPrimeBlocks * Length(FSubmit)) and
    (TThread.GetTickCount64 - FPrimeSince < UInt64(FPrimeWaitMillis)) then
    Exit;
  while (FCount > 0) and (State.QueuedBlocks < AudioFormat.BlockCount) do
  begin
    if (FCount < Length(FSubmit)) and not FShortWrite and
      ((State.QueuedBlocks > 0) or (TThread.GetTickCount64 - FLastAppend < 12)) then
      Break;
    var Count := Min(FCount, Length(FSubmit));
    for var I := 0 to Count - 1 do
      FSubmit[I] := FPending[(FHead + I) mod Length(FPending)];
    var Submitted := State.SubmittedSamples;
    FAudio.Submit(FSubmit, Count div 2);
    State := Check;
    // The non-blocking backend may accept only part of a block. Its
    // submission counter is in frames. Keep the remainder for the next pump.
    var Written := State.SubmittedSamples - Submitted;
    if Written > UInt64(Count div 2) then
      raise EInOutError.Create('Invalid Java ME audio submission count');
    var Accepted := Integer(Written) * 2;
    FHead := (FHead + Accepted) mod Length(FPending);
    Dec(FCount, Accepted);
    FShortWrite := Accepted < Count;
    if Accepted > 0 then
      FWriteBlockedSince := 0
    else if FWriteBlockedSince = 0 then
      FWriteBlockedSince := TThread.GetTickCount64
    else if TThread.GetTickCount64 - FWriteBlockedSince >= 1000 then
      raise EInOutError.Create('Java ME audio output stalled');
    StartPrimed(State.QueuedBlocks);
    if FShortWrite then
      Break;
  end;
  if State.QueuedBlocks > 0 then
    StartPrimed(State.QueuedBlocks);
end;

function TJ2MEAudioPlayback.Enqueue(const Samples: TArray<SmallInt>; Volume: Single): Integer;
begin
  if Odd(Length(Samples)) then
    raise EArgumentException.Create('Stereo PCM frames required');
  if Length(Samples) > Length(FPending) - FCount then
    Pump;
  Result := Min(Length(Samples) div 2, (Length(FPending) - FCount) div 2);
  for var I := 0 to Result * 2 - 1 do
    FPending[(FHead + FCount + I) mod Length(FPending)] :=
      SmallInt(EnsureRange(Round(Samples[I] * Volume), Int64(-32768), Int64(32767)));
  Inc(FCount, Result * 2);
  if Result > 0 then
    FLastAppend := TThread.GetTickCount64;
  Pump;
end;

end.

