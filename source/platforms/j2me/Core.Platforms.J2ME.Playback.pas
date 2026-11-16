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
    FPrimeSince, FLastAppend: UInt64;
    FPriming, FCanPause: Boolean;
    procedure Check;
    procedure StartPrimed;
  public
    constructor Create(const Factory: TJ2MEAudioFactory = nil);
    destructor Destroy; override;
    class function AudioFormat: TPCMAudioFormat; static;
    function Enqueue(const Samples: TArray<SmallInt>; Volume: Single): Integer;
    procedure Pump;
    function AvailableFrames: Integer;
    function PendingFrames: Integer;
    procedure Clear;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

class function TJ2MEAudioPlayback.AudioFormat: TPCMAudioFormat;
begin
  Result.SampleRate := 44100;
  Result.Channels := 2;
  Result.BlockFrames := 512;
  Result.BlockCount := 8;
end;

constructor TJ2MEAudioPlayback.Create(const Factory: TJ2MEAudioFactory);
begin
  inherited Create;
  if Assigned(Factory) then
    FAudio := TPCMAudio.Create(AudioFormat, Factory(AudioFormat))
  else
    FAudio := TPCMAudio.Create(AudioFormat);
  Check;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
  // Bounded 371 ms software FIFO in addition to the 93 ms device queue.
  // The producer observes AvailableFrames before advancing the mixer.
  SetLength(FPending, 16384 * 2);
  FPrimeSince := TThread.GetTickCount64;
end;

destructor TJ2MEAudioPlayback.Destroy;
begin
  FAudio.Free;
  inherited;
end;

procedure TJ2MEAudioPlayback.Check;
begin
  if FAudio.Error <> '' then
    raise EInOutError.Create(FAudio.Error);
  if not FAudio.QueueState.DeviceOpen then
    raise EInOutError.Create('Java ME audio output is unavailable');
end;

procedure TJ2MEAudioPlayback.Clear;
begin
  Check;
  FAudio.Clear;
  FCount := 0;
  FHead := 0;
  FPrimeSince := TThread.GetTickCount64;
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

procedure TJ2MEAudioPlayback.StartPrimed;
begin
  if not FPriming then
    Exit;
  if FCanPause then
  begin
    var Queued := FAudio.QueueState.QueuedBlocks;
    if Queued = 0 then
      Exit;
    if (Queued < 2) and (TThread.GetTickCount64 - FPrimeSince < 20) then
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
  Check;
  if not FPriming and (FAudio.QueueState.QueuedBlocks = 0) then
  begin
    FPriming := True;
    FPrimeSince := TThread.GetTickCount64;
    if FCanPause then
      FCanPause := FAudio.SetPaused(True);
  end;
  while (FCount >= Length(FSubmit)) and (FAudio.QueueState.QueuedBlocks < AudioFormat.BlockCount) do
  begin
    for var I := 0 to High(FSubmit) do
      FSubmit[I] := FPending[(FHead + I) mod Length(FPending)];
    FAudio.Submit(FSubmit, Length(FSubmit) div 2);
    FHead := (FHead + Length(FSubmit)) mod Length(FPending);
    Dec(FCount, Length(FSubmit));
    Check;
    StartPrimed;
  end;
  if (FCount > 0) and (FCount < Length(FSubmit)) and (FAudio.QueueState.QueuedBlocks = 0) and
    (TThread.GetTickCount64 - FLastAppend >= 12) then
  begin
    FillChar(FSubmit, SizeOf(FSubmit), 0);
    for var I := 0 to FCount - 1 do
      FSubmit[I] := FPending[(FHead + I) mod Length(FPending)];
    FAudio.Submit(FSubmit, Length(FSubmit) div 2);
    FHead := (FHead + FCount) mod Length(FPending);
    FCount := 0;
    Check;
  end;
  StartPrimed;
end;

function TJ2MEAudioPlayback.Enqueue(const Samples: TArray<SmallInt>; Volume: Single): Integer;
begin
  if Odd(Length(Samples)) then
    raise EArgumentException.Create('Stereo PCM frames required');
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

