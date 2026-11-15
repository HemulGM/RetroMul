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
    FCount: Integer;
    FPriming, FCanPause: Boolean;
    procedure Check;
    procedure StartPrimed;
  public
    constructor Create(const Factory: TJ2MEAudioFactory = nil);
    destructor Destroy; override;
    class function AudioFormat: TPCMAudioFormat; static;
    procedure Enqueue(const Samples: TArray<SmallInt>; Volume: Single);
    procedure Clear;
  end;

implementation

uses
  System.SysUtils, System.Math;

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
  SetLength(FPending, AudioFormat.BlockFrames * 2);
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
  FCanPause := FAudio.SetPaused(True);
  FPriming := True;
end;

procedure TJ2MEAudioPlayback.StartPrimed;
begin
  if not FPriming then
    Exit;
  if FCanPause then
  begin
    if FAudio.QueueState.QueuedBlocks < 2 then
      Exit;
    if not FAudio.SetPaused(False) then
      raise EInOutError.Create('Java ME audio output could not resume');
  end;
  FPriming := False;
end;

procedure TJ2MEAudioPlayback.Enqueue(const Samples: TArray<SmallInt>; Volume: Single);
begin
  if Odd(Length(Samples)) then
    raise EArgumentException.Create('Stereo PCM frames required');
  Check;
  if not FPriming and (FAudio.QueueState.QueuedBlocks = 0) then
  begin
    FPriming := True;
    if FCanPause then
      FAudio.SetPaused(True);
  end;
  for var Sample in Samples do
  begin
    FPending[FCount] := SmallInt(EnsureRange(Round(Sample * Volume), Int64(-32768), Int64(32767)));
    Inc(FCount);
    if FCount = Length(FPending) then
    begin
      // Submit owns bounded backpressure: excess catch-up PCM is counted as
      // dropped by the backend. A full queue is not a device failure.
      FAudio.Submit(FPending, FCount div 2);
      FCount := 0;
      Check;
      // Start within this batch so a large first batch cannot fill a paused
      // device before the end of Enqueue. Nonpausable devices play immediately.
      StartPrimed;
    end;
  end;
end;

end.

