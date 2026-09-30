unit GBC.EmulationThread;

interface

uses
  Core.Snapshots, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.Diagnostics, GBC.Joypad, GBC.GPU;

type
  TGBInputEvent = record
    Key: TGBCKey;
    Pressed: Boolean;
  end;

  // Run one session at a time: the core's timer, joypad and interrupts are singletons.
  TGBCEmulationThread = class(TThread)
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FROMData: TArray<Byte>;
    FEnableAudio: Boolean;
    FLock: TCriticalSection;
    FStopEvent: TEvent;
    FInputEvents: TQueue<TGBInputEvent>;
    FPressedKeys: set of TGBCKey;
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
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    procedure RequestStop;
    procedure RequestPause;
    procedure RequestResume;
    procedure SetKeyState(Key: TGBCKey; Pressed: Boolean);
    procedure ReleaseKeys;
    function TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean;
    function TakeError: string;
    property SoundVolume: Single read FSoundVolume write SetSoundVolume;
    property PauseRequested: Boolean read FPauseRequested;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, GBC.ROM, GBC.MBC, GBC.Memory, GBC.CPU,
  GBC.Sound, GBC.Timer, GBC.InterruptManager;

constructor TGBCEmulationThread.Create(const FileName: string; EnableAudio: Boolean);
begin
  Create(TFile.ReadAllBytes(FileName), EnableAudio);
end;

constructor TGBCEmulationThread.Create(const ROMData: TArray<Byte>; EnableAudio: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FROMData := Copy(ROMData);
  FEnableAudio := EnableAudio;
  FSoundVolume := 0.5;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FInputEvents := TQueue<TGBInputEvent>.Create;
end;

destructor TGBCEmulationThread.Destroy;
begin
  RequestStop;
  // TThread joins the worker (including an unstarted thread) before shared data is freed.
  // Execute never synchronizes with the UI, so joining cannot wait for a UI callback.
  inherited Destroy;
  FSnapshots.Free;
  FInputEvents.Free;
  FStopEvent.Free;
  FLock.Free;
end;

procedure TGBCEmulationThread.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TGBCEmulationThread.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
end;

procedure TGBCEmulationThread.RequestStop;
begin
  Terminate;
  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

procedure TGBCEmulationThread.RequestPause;
begin
  FLock.Acquire;
  try
    FPauseRequested := True;
  finally
    FLock.Release;
  end;
end;

procedure TGBCEmulationThread.RequestResume;
begin
  FLock.Acquire;
  try
    FPauseRequested := False;
  finally
    FLock.Release;
  end;
end;

procedure TGBCEmulationThread.SetKeyState(Key: TGBCKey; Pressed: Boolean);
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

procedure TGBCEmulationThread.SetSoundVolume(const Value: Single);
begin
  FLock.Acquire;
  try
    FSoundVolume := Value;
  finally
    FLock.Release;
  end;
end;

procedure TGBCEmulationThread.ReleaseKeys;
begin
  for var Key := Low(TGBCKey) to High(TGBCKey) do
    SetKeyState(Key, False);
end;

procedure TGBCEmulationThread.ApplyInput;
begin
  FLock.Acquire;
  try
    while FInputEvents.Count > 0 do
    begin
      var Input := FInputEvents.Dequeue;
      var Joypad := TGBCJoypad.Instance;
      if Input.Pressed then
        Joypad.KeyDown(Joypad.KeyBindings[Input.Key])
      else
        Joypad.KeyUp(Joypad.KeyBindings[Input.Key]);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TGBCEmulationThread.PublishFrame(const Screen: TScreenArray);
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

function TGBCEmulationThread.TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean;
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

function TGBCEmulationThread.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FErrorMessage;
    FErrorMessage := '';
  finally
    FLock.Release;
  end;
end;

procedure TGBCEmulationThread.Execute;
const
  BatchCycles = 4096;
begin
  if Terminated then
    Exit;
  var ROM: TGBCROM := nil;
  var MBC: TGBCMBC := nil;
  var GPU: TGBCGPU := nil;
  var Memory: TGBCMemory := nil;
  var Sound: TGBSound := nil;
  var CPU: TGBCCPU := nil;
  try
    try
      ROM := TGBCROM.Create;
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
      GPU := TGBCGPU.Create(PublishFrame);
      // CGB header flags $80/$C0 opt into CGB hardware. Other cartridges run
      // through the DMG-compatible display path even when opened by this core.
      GPU.SetCGBMode(ROM.Cartridge.SupportsCGB);
      MBC := TGBCMBC.Create(ROM);
      Memory := TGBCMemory.Create(MBC, GPU);
      Sound := TGBSound.Create(Memory, FEnableAudio);
      Sound.Volume := FSoundVolume;
      CPU := TGBCCPU.Create(Memory, GPU, Sound);
      CPU.SkipBIOS;
      var Stopwatch := TStopwatch.StartNew;
      var StartCycles := CPU.Cycles;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := TPath.Combine(FSnapshotDirectory, Name + '.snapshot');
            var Transfer: TStateTransfer := procedure(State: TStateArchive)
            begin
              CPU.SerializeState(State);
              Memory.SerializeState(State);
              GPU.SerializeState(State);
              MBC.SerializeState(State);
              Sound.SerializeState(State);
              TGBCTimer.Instance.SerializeState(State);
              TGBCInterruptManager.Instance.SerializeState(State);
              TGBCJoypad.Instance.SerializeState(State);
            end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, 'GBC', FROMData, Transfer);
              if Sound.Audio <> nil then Sound.Audio.Clear;
              // Host key state is authoritative after restoring the emulated JOYP.
              FLock.Acquire;
              try
                for var Key := Low(TGBCKey) to High(TGBCKey) do
                  if Key in FPressedKeys then
                    TGBCJoypad.Instance.KeyDown(TGBCJoypad.Instance.KeyBindings[Key])
                  else
                    TGBCJoypad.Instance.KeyUp(TGBCJoypad.Instance.KeyBindings[Key]);
              finally
                FLock.Release;
              end;
              PublishFrame(GPU.Screen);
            end
            else
            begin
              SaveCoreSnapshot(Path, 'GBC', FROMData, Transfer);
              SaveSnapshotPreview(Path, 160, 144, 160, @GPU.Screen[0]);
            end;
            StartCycles := CPU.Cycles;
            Stopwatch := TStopwatch.StartNew;
          end);
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
      TGBCJoypad.ReleaseInstance;
      TGBCTimer.ReleaseInstance;
      TGBCInterruptManager.ReleaseInstance;
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

