unit Core.PS2.Playback;

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
    function State: TPCMAudioQueueState;
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
  State;
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

procedure TPS2AudioPlayback.Clear;
begin
  State;
  FCount := 0;
  FAudio.Clear;
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
  Result := (FCount < BlockFrames * 2) and (FPriming or (State.QueuedBlocks < TargetBlocks));
end;

end.
