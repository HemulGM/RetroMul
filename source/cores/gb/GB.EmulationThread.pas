unit GB.EmulationThread;

interface

uses
  System.Classes, System.SyncObjs, System.Generics.Collections,
  System.Diagnostics, GB.Joypad, GB.GPU;

type
  TGBInputEvent = record
    Key: TGBKey;
    Pressed: Boolean;
  end;

  // Run one session at a time: the core's timer, joypad and interrupts are singletons.
  TGBEmulationThread = class(TThread)
  private
    FROMData: TArray<Byte>;
    FEnableAudio: Boolean;
    FLock: TCriticalSection;
    FStopEvent: TEvent;
    FInputEvents: TQueue<TGBInputEvent>;
    FPressedKeys: set of TGBKey;
    FFrame: TScreenArray;
    FFrameAvailable: Boolean;
    FFramesPerSecond: Double;
    FFrameRateStopwatch: TStopwatch;
    FFramesSinceRateUpdate: Integer;
    FErrorMessage: string;
    FSoundVolume: Single;
    FPauseRequested: Boolean;
    procedure PublishFrame(const Screen: TScreenArray);
    procedure ApplyInput;
    procedure SetSoundVolume(const Value: Single);
  protected
    procedure Execute; override;
  public
    constructor Create(const FileName: string; EnableAudio: Boolean = True); overload;
    constructor Create(const ROMData: TArray<Byte>; EnableAudio: Boolean = True); overload;
    destructor Destroy; override;
    procedure RequestStop;
    procedure RequestPause;
    procedure RequestResume;
    procedure SetKeyState(Key: TGBKey; Pressed: Boolean);
    procedure ReleaseKeys;
    function TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean;
    function TakeError: string;
    property SoundVolume: Single read FSoundVolume write SetSoundVolume;
    property PauseRequested: Boolean read FPauseRequested;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, GB.ROM, GB.MBC, GB.Memory, GB.CPU, GB.Sound,
  GB.Timer, GB.InterruptManager;

constructor TGBEmulationThread.Create(const FileName: string; EnableAudio: Boolean);
begin
  Create(TFile.ReadAllBytes(FileName), EnableAudio);
end;

constructor TGBEmulationThread.Create(const ROMData: TArray<Byte>; EnableAudio: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FROMData := Copy(ROMData);
  FEnableAudio := EnableAudio;
  FSoundVolume := 0.5;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FInputEvents := TQueue<TGBInputEvent>.Create;
end;

destructor TGBEmulationThread.Destroy;
begin
  RequestStop;
  // TThread joins the worker (including an unstarted thread) before shared data is freed.
  // Execute never synchronizes with the UI, so joining cannot wait for a UI callback.
  inherited Destroy;
  FInputEvents.Free;
  FStopEvent.Free;
  FLock.Free;
end;

procedure TGBEmulationThread.RequestStop;
begin
  Terminate;
  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

procedure TGBEmulationThread.RequestPause;
begin
  FLock.Acquire;
  try
    FPauseRequested := True;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.RequestResume;
begin
  FLock.Acquire;
  try
    FPauseRequested := False;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.SetKeyState(Key: TGBKey; Pressed: Boolean);
begin
  FLock.Acquire;
  try
    if (Key in FPressedKeys) = Pressed then
      Exit;
    if Pressed then
      Include(FPressedKeys, Key)
    else
      Exclude(FPressedKeys, Key);
    var Input: TGBInputEvent;
    Input.Key := Key;
    Input.Pressed := Pressed;
    FInputEvents.Enqueue(Input);
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.SetSoundVolume(const Value: Single);
begin
  FLock.Acquire;
  try
    FSoundVolume := Value;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.ReleaseKeys;
begin
  for var Key := Low(TGBKey) to High(TGBKey) do
    SetKeyState(Key, False);
end;

procedure TGBEmulationThread.ApplyInput;
begin
  FLock.Acquire;
  try
    while FInputEvents.Count > 0 do
    begin
      var Input := FInputEvents.Dequeue;
      var Joypad := TGBJoypad.Instance;
      if Input.Pressed then
        Joypad.KeyDown(Joypad.KeyBindings[Input.Key])
      else
        Joypad.KeyUp(Joypad.KeyBindings[Input.Key]);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.PublishFrame(const Screen: TScreenArray);
begin
  FLock.Acquire;
  try
    // Copy GPU memory; a slow UI simply skips older frames instead of accumulating them.
    FFrame := Screen;
    FFrameAvailable := True;
    Inc(FFramesSinceRateUpdate);
    if FFrameRateStopwatch.ElapsedMilliseconds >= 500 then
    begin
      FFramesPerSecond := FFramesSinceRateUpdate * 1000.0 /
        FFrameRateStopwatch.ElapsedMilliseconds;
      FFramesSinceRateUpdate := 0;
      FFrameRateStopwatch := TStopwatch.StartNew;
    end;
  finally
    FLock.Release;
  end;
end;

function TGBEmulationThread.TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean;
begin
  FLock.Acquire;
  try
    Result := FFrameAvailable;
    FramesPerSecond := FFramesPerSecond;
    if Result then
    begin
      Screen := FFrame;
      FFrameAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TGBEmulationThread.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FErrorMessage;
    FErrorMessage := '';
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.Execute;
const
  BatchCycles = 4096;
begin
  if Terminated then
    Exit;
  var ROM: TGBROM := nil;
  var MBC: TGBMBC := nil;
  var GPU: TGBGPU := nil;
  var Memory: TGBMemory := nil;
  var Sound: TGBSound := nil;
  var CPU: TGBCPU := nil;
  try
    try
      ROM := TGBROM.Create;
      var Stream := TBytesStream.Create(FROMData);
      try
        ROM.ReadROM(Stream);
      finally
        Stream.Free;
      end;
      if Terminated then
        Exit;
      FFrameRateStopwatch := TStopwatch.StartNew;
      FFramesSinceRateUpdate := 0;
      FFramesPerSecond := 0;
      GPU := TGBGPU.Create(PublishFrame);
      MBC := TGBMBC.Create(ROM);
      Memory := TGBMemory.Create(MBC, GPU);
      Sound := TGBSound.Create(Memory, FEnableAudio);
      Sound.Volume := FSoundVolume;
      CPU := TGBCPU.Create(Memory, GPU, Sound);
      CPU.SkipBIOS;
      var Stopwatch := TStopwatch.StartNew;
      var StartCycles := CPU.Cycles;
      while not Terminated do
      begin
        ApplyInput;
        FLock.Acquire;
        try
          if FPauseRequested then
          begin
            // The stop event also wakes this short sleep during shutdown.
            FLock.Release;
            try
              FStopEvent.WaitFor(25);
            finally
              FLock.Acquire;
            end;
            StartCycles := CPU.Cycles;
            Stopwatch := TStopwatch.StartNew;
            Continue;
          end;
        finally
          FLock.Release;
        end;
        Sound.Volume := FSoundVolume;
        var NextCycles := CPU.Cycles + BatchCycles;
        while (CPU.Cycles < NextCycles) and not Terminated do
          CPU.Step;

        var TargetMilliseconds := Int64((CPU.Cycles - StartCycles) * 1000 div CPUClockFrequency);
        var WaitMilliseconds := TargetMilliseconds - Stopwatch.ElapsedMilliseconds;
        if WaitMilliseconds > 0 then
        begin
          if FStopEvent.WaitFor(Cardinal(WaitMilliseconds)) = wrSignaled then
            Break;
        end
        else if WaitMilliseconds < -250 then
        begin
          // Do not run a long catch-up burst after a debugger pause or system sleep.
          StartCycles := CPU.Cycles;
          Stopwatch := TStopwatch.StartNew;
        end;
      end;
    finally
      CPU.Free;
      Sound.Free;
      Memory.Free;
      MBC.Free;
      GPU.Free;
      ROM.Free;
      TGBJoypad.ReleaseInstance;
      TGBTimer.ReleaseInstance;
      TGBInterruptManager.ReleaseInstance;
    end;
  except
    on E: Exception do
    begin
      FLock.Acquire;
      try
        FErrorMessage := E.ClassName + ': ' + E.Message;
      finally
        FLock.Release;
      end;
    end;
  end;
end;

end.

