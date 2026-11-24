program PS2PlaybackTest;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Math, PCM.Audio.Backend, Core.Platforms.PS2.Playback, PS2.AudioWait, PS2.HostTempo;

type
  TFakeDevice = class(TInterfacedObject, IPCMAudioBackend, IPCMAudioPlaybackControl)
  public
    S: TPCMAudioQueueState;
    Queued: Integer;
    Paused: Boolean;
    constructor Create(Known: Boolean);
    procedure Clear;
    procedure Submit(const Samples: array of SmallInt; Count: Integer);
    function QueueState: TPCMAudioQueueState;
    function GetError: string;
    function SetPaused(Value: Boolean): Boolean;
    procedure Advance(Frames: Integer);
  end;

procedure Check(Value: Boolean; const Text: string);
begin
  if not Value then raise Exception.Create(Text);
end;

constructor TFakeDevice.Create(Known: Boolean);
begin
  inherited Create;
  S.DeviceOpen := True;
  S.PositionKnown := Known;
end;

procedure TFakeDevice.Clear;
begin
  Queued := 0;
  S.QueuedBlocks := 0;
  S.Clears := Cardinal((UInt64(S.Clears) + 1) and $FFFFFFFF);
  S.PlayedSamples := 0;
end;

procedure TFakeDevice.Submit(const Samples: array of SmallInt; Count: Integer);
begin
  Check((Count > 0) and (Count <= TPS2AudioPlayback.BlockFrames), 'Invalid submission size');
  Check(Length(Samples) >= Count * 2, 'Short stereo buffer');
  Inc(S.SubmittedSamples, Count);
  Inc(Queued, Count);
  S.QueuedBlocks := (Queued + TPS2AudioPlayback.BlockFrames - 1) div TPS2AudioPlayback.BlockFrames;
  Check(S.QueuedBlocks <= TPS2AudioPlayback.BlockCount, 'Device queue overflow');
end;

function TFakeDevice.QueueState: TPCMAudioQueueState;
begin
  Result := S;
end;

function TFakeDevice.GetError: string;
begin
  Result := '';
end;

function TFakeDevice.SetPaused(Value: Boolean): Boolean;
begin
  Paused := Value;
  Result := True;
end;

procedure TFakeDevice.Advance(Frames: Integer);
begin
  Check(not Paused, 'Advancing a paused device');
  var Taken := Min(Frames, Queued);
  Dec(Queued, Taken);
  S.PlayedSamples := Cardinal((UInt64(S.PlayedSamples) + Cardinal(Taken)) and $FFFFFFFF);
  S.QueuedBlocks := (Queued + TPS2AudioPlayback.BlockFrames - 1) div TPS2AudioPlayback.BlockFrames;
end;

procedure Prime(P: TPS2AudioPlayback);
begin
  var Samples: TArray<SmallInt>;
  SetLength(Samples, 800 * 2);
  for var I := 1 to 8 do
  begin
    Check(P.CanAdvance, 'Preroll stopped too early');
    P.Enqueue(Samples, 1);
  end;
  // 6400 frames: six blocks submitted and 256 frames pending.
  Check(not P.CanAdvance, 'Preroll exceeded the target');
end;

procedure CheckClock(Known, Wrap: Boolean);
begin
  var Device := TFakeDevice.Create(Known);
  var Backend: IPCMAudioBackend := Device;
  if Wrap then
  begin
    Device.S.PlayedSamples := $FFFFFF00;
    Device.S.Clears := $FFFFFFFF;
  end;
  // Lifetime counters need not start at zero.
  Device.S.SubmittedSamples := 987654321;
  var P := TPS2AudioPlayback.Create(Backend);
  try
    Prime(P);
    Check(not Device.Paused, 'Playback did not start after preroll');
    Device.Advance(256);
    Check(not P.CanAdvance, 'Ignored pending frames at the target boundary');
    Device.Advance(1);
    if Known then
    begin
      Check(Device.S.QueuedBlocks = 6, 'Test did not retain six device blocks');
      Check(P.CanAdvance, 'Exact playback clock still waits for a whole block');
      var Samples: TArray<SmallInt>;
      SetLength(Samples, 800 * 2);
      for var Field := 1 to 10000 do
      begin
        P.Enqueue(Samples, 1);
        Check(not P.CanAdvance, 'Field advanced without its playback time');
        Device.Advance(799);
        Check(not P.CanAdvance, 'Field advanced before its last sample');
        Device.Advance(1);
        Check(P.CanAdvance, 'A full field of playback did not release a field');
      end;
    end
    else
    begin
      Check(not P.CanAdvance, 'Unknown device clock did not retain block fallback');
      Device.Advance(1024 - 257);
      Check(P.CanAdvance, 'Block-count fallback did not advance');
    end;
    P.Clear;
    Check(Device.Paused, 'Clear did not pause');
    Check(P.CanAdvance, 'Clear retained an obsolete playback origin');
    Prime(P);
    Device.Advance(257);
    Check(P.CanAdvance = Known, 'Clear did not establish a fresh playback origin');
    // Drain to underrun: the original priming behavior must remain.
    Device.Advance(Device.Queued);
    Check(P.CanAdvance, 'Underrun did not restart priming');
    Check(Device.Paused, 'Underrun did not pause for preroll');
    Check(Device.S.DroppedSamples = 0, 'Playback dropped samples');
  finally
    P.Free;
  end;
end;

procedure CheckClockRecovery;
begin
  var Device := TFakeDevice.Create(True);
  var Backend: IPCMAudioBackend := Device;
  var P := TPS2AudioPlayback.Create(Backend);
  try
    Prime(P);
    Device.Advance(257);
    Check(P.CanAdvance, 'Precise clock did not start');
    Dec(Device.S.PlayedSamples); // An unexpected backward device position.
    Check(not P.CanAdvance, 'Backward position did not use the safe block fallback');
    Device.Advance(Device.Queued);
    Check(P.CanAdvance and Device.Paused, 'Underrun did not pause for recovery');
    var Samples: TArray<SmallInt>;
    SetLength(Samples, TPS2AudioPlayback.TargetBlocks * TPS2AudioPlayback.BlockFrames * 2);
    P.Enqueue(Samples, 1);
    Check(not Device.Paused, 'Recovery preroll did not restart playback');
    Device.Advance(257);
    Check(P.CanAdvance, 'Underrun did not restore the precise clock');
    // A broken lifetime counter must not underflow the queue calculation.
    Device.S.SubmittedSamples := 0;
    Check(not P.CanAdvance, 'Submission counter reset did not use block fallback');
    P.Clear;
    Prime(P);
    Device.Advance(257);
    Check(P.CanAdvance, 'Clear did not recover from reset lifetime counters');
  finally
    P.Free;
  end;
end;

procedure CheckStereoReserve;
const
  Frames = 2048;
var
  Source, Output: TArray<SmallInt>;
begin
  SetLength(Source, Frames * 2);
  for var I := 0 to Frames - 1 do
  begin
    Source[2 * I] := 100 + (I mod 97) * 10;
    Source[2 * I + 1] := -Source[2 * I];
  end;
  var Extra := 777;
  Output := StretchReserve(Source, Frames, Extra);
  Check(Length(Output) = 2 * (Frames + Extra), 'Incorrect stereo reserve length');
  Check(CompareMem(@Output[0], @Source[0], 256 * 4), 'Reserve changed the first hop');
  Check(CompareMem(@Output[Length(Output) - 64], @Source[Length(Source) - 64], 64 * SizeOf(SmallInt)),
    'Reserve did not rejoin the source tail');
  for var I := 0 to Length(Output) div 2 - 1 do
    Check((Output[I * 2] >= 100) and (Output[I * 2 + 1] = -Output[I * 2]), 'Stereo reserve lost channel phase');

  var Tempo := TPS2HostTempo.Create;
  try
    Tempo.Clear;
    for var I := 1 to 12 do
      Check(not Tempo.Expand(Source, Frames, 6400, Output), 'Full-speed playback was stretched');
    for var I := 1 to 12 do
      Tempo.Expand(Source, Frames * 2, 2000, Output);
    Check(Tempo.Stretching, 'A sustained host slowdown did not enable the reserve');
    Check(Length(Output) > Length(Source), 'Slow playback did not produce extra device samples');
    for var I := 0 to Length(Output) div 2 - 1 do
      Check(Output[I * 2 + 1] = -Output[I * 2], 'Tempo correction split a stereo pair');
    for var I := 1 to 32 do
      Tempo.Expand(Source, Frames, 10000, Output);
    Check(not Tempo.Stretching, 'Recovered playback did not return to native PCM');
  finally
    Tempo.Free;
  end;
end;

begin
  try
    CheckClock(True, False);
    CheckClock(True, True);
    CheckClock(False, False);
    CheckClockRecovery;
    CheckStereoReserve;
    Writeln('PS2 playback: per-sample pacing, pending frames, position wrap, Clear, underrun and block fallback OK');
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
