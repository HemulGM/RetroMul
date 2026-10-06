unit GB.EmulationThread;

interface

uses
  Core.Storage, Core.Snapshots, System.Classes, System.SyncObjs,
  System.Generics.Collections, System.Diagnostics, GB.Joypad, GB.GPU, GB.ROM,
  GB.MBC, GB.Memory, GB.Timer, GB.InterruptManager, GB.Camera;

type
  TGBInputEvent = record
    Key: TGBKey;
    Pressed: Boolean;
  end;

  // Run one session at a time: the core's timer, joypad and interrupts are singletons.
  TGBEmulationThread = class(TThread)
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FSavePath: string;
    FStorage: IStorage;
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
    FScreenPalette: Integer;
    FPauseRequested: Boolean;
    FCameraSource: IGBCameraFrameSource;
    FHasCamera: Boolean;
    procedure ApplyInput;
    procedure SetSoundVolume(const Value: Single);
    procedure SetScreenPalette(const Value: Integer);
  protected
    procedure PublishFrame(const Screen: TScreenArray);
    function CoreID: string; virtual;
    function CreateVideo(ROM: TGBROM): TGBVideo; virtual;
    function CreateMemory(MBC: TGBMBC; Video: TGBVideo): TGBMemory; virtual;
    function GetJoypad: TGBJoypad; virtual;
    function GetTimer: TGBTimer; virtual;
    function GetInterruptManager: TGBInterruptManager; virtual;
    procedure ReleasePeripherals; virtual;
    procedure Execute; override;
  public
    constructor Create(const FileName: string; EnableAudio: Boolean = True); overload;
    constructor Create(const ROMData: TArray<Byte>; EnableAudio: Boolean = True; const CameraSource: IGBCameraFrameSource = nil); overload;
    destructor Destroy; override;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    property SavePath: string read FSavePath write FSavePath;
    property Storage: IStorage read FStorage write FStorage;
    procedure RequestStop;
    procedure RequestPause;
    procedure RequestResume;
    procedure SetKeyState(Key: TGBKey; Pressed: Boolean);
    procedure ReleaseKeys;
    function TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean;
    function TakeError: string;
    property SoundVolume: Single read FSoundVolume write SetSoundVolume;
    property ScreenPalette: Integer write SetScreenPalette;
    property PauseRequested: Boolean read FPauseRequested;
    property HasCamera: Boolean read FHasCamera;
    procedure SubmitCameraFrame(const Frame: TGBCameraFrame);
  end;

implementation

uses
  Core.PerformanceHints, System.SysUtils, System.IOUtils, System.Math, GB.CPU, GB.Sound, GB.Palettes;

function TGBEmulationThread.CoreID: string;
begin
  Result := 'GB';
end;

function TGBEmulationThread.CreateVideo(ROM: TGBROM): TGBVideo;
begin
  Result := TGBGPU.Create(PublishFrame);
end;

function TGBEmulationThread.CreateMemory(MBC: TGBMBC; Video: TGBVideo): TGBMemory;
begin
  Result := TGBMemory.Create(MBC, Video);
end;

function TGBEmulationThread.GetJoypad: TGBJoypad;
begin
  Result := TGBJoypad.Instance;
end;

function TGBEmulationThread.GetTimer: TGBTimer;
begin
  Result := TGBTimer.Instance;
end;

function TGBEmulationThread.GetInterruptManager: TGBInterruptManager;
begin
  Result := TGBInterruptManager.Instance;
end;

procedure TGBEmulationThread.ReleasePeripherals;
begin
  TGBJoypad.ReleaseInstance;
  TGBTimer.ReleaseInstance;
  TGBInterruptManager.ReleaseInstance;
end;

constructor TGBEmulationThread.Create(const FileName: string; EnableAudio: Boolean);
begin
  Create(TStorage.Default.ReadBytes(FileName), EnableAudio);
  FSavePath := FStorage.GameSave(LowerCase(CoreID), FileName, SnapshotIdentity(FROMData));
end;

constructor TGBEmulationThread.Create(const ROMData: TArray<Byte>; EnableAudio: Boolean; const CameraSource: IGBCameraFrameSource);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FStorage := TStorage.Default;
  FROMData := Copy(ROMData);
  FHasCamera := (Length(FROMData) > $147) and (FROMData[$147] = $FC);
  if FHasCamera then
  begin
    FCameraSource := CameraSource;
    if FCameraSource = nil then
      FCameraSource := TGBCameraFrameSource.Create;
  end;
  FEnableAudio := EnableAudio;
  FSoundVolume := 0.5;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FInputEvents := TQueue<TGBInputEvent>.Create;
end;

destructor TGBEmulationThread.Destroy;
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

procedure TGBEmulationThread.SubmitCameraFrame(const Frame: TGBCameraFrame);
begin
  if not FHasCamera then
    raise ENotSupportedException.Create('Cartridge has no camera');
  FCameraSource.SubmitFrame(Frame);
end;

procedure TGBEmulationThread.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TGBEmulationThread.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
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

procedure TGBEmulationThread.SetScreenPalette(const Value: Integer);
begin
  FLock.Acquire;
  try
    FScreenPalette := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
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
      var Joypad := GetJoypad;
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
      FFramesPerSecond := FFramesSinceRateUpdate * 1000.0 / FFrameRateStopwatch.ElapsedMilliseconds;
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
  FrameCycles = 70224; // 456 dots * 154 lines, also in CGB double-speed mode.
var
  LastRAM, LastRTC: TBytes;
  BatteryArmed: Boolean;

  procedure SaveBattery(MBC: TGBMBC);

    procedure SaveChanged(const Path: string; const Data: TBytes; var Last: TBytes);
    begin
      if (Length(Data) = Length(Last)) and ((Length(Data) = 0) or CompareMem(@Data[0], @Last[0], Length(Data))) then
        Exit;
      var Stream := TBytesStream.Create(Data);
      try
        SaveStreamAtomically(Stream, Path, FStorage);
        Last := Copy(Data);
      finally
        Stream.Free;
      end;
    end;

  begin
    if not BatteryArmed then
      Exit;

    SaveChanged(FSavePath, MBC.SaveMemory, LastRAM);
    if MBC.HasTimer then
      SaveChanged(ChangeFileExt(FSavePath, '.rtc'), MBC.RTCData, LastRTC);
  end;

begin
  BatteryArmed := False;
  if Terminated then
    Exit;

  var ROM: TGBROM := nil;
  var MBC: TGBMBC := nil;
  var GPU: TGBVideo := nil;
  var Memory: TGBMemory := nil;
  var Sound: TGBSound := nil;
  var FrameHints: TEmulationPerformanceHints := nil;
  var HintNextCycles: UInt64;
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
      GPU := CreateVideo(ROM);
      MBC := TGBMBC.Create(ROM, nil, FCameraSource);
      if MBC.HasBattery and (FSavePath <> '') then
      begin
        if FStorage.Exists(FSavePath) then
          MBC.LoadSaveMemory(FStorage.ReadBytes(FSavePath));
        var RTCPath := ChangeFileExt(FSavePath, '.rtc');
        if MBC.HasTimer and FStorage.Exists(RTCPath) then
          MBC.LoadRTCData(FStorage.ReadBytes(RTCPath));
        LastRAM := MBC.SaveMemory;
        LastRTC := MBC.RTCData;
        // Never overwrite an invalid file when activation failed above.
        BatteryArmed := True;
      end;
      Memory := CreateMemory(MBC, GPU);
      Sound := TGBSound.Create(Memory, FEnableAudio);
      Sound.Volume := FSoundVolume;
      CPU := TGBCPU.Create(Memory, GPU, Sound);
      CPU.SkipBIOS;
      FrameHints := TEmulationPerformanceHints.Create(Round(FrameCycles * 1000000000.0 / CPUClockFrequency), CoreID);
      HintNextCycles := CPU.Cycles + FrameCycles;
      var PacingStart := TStopwatch.GetTimeStamp;
      var StartCycles := CPU.Cycles;
      var BatteryWatch := TStopwatch.StartNew;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            FrameHints.Pause;
            var Path := TPath.Combine(FSnapshotDirectory, Name + '.snapshot');
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                CPU.SerializeState(State);
                Memory.SerializeState(State);
                GPU.SerializeState(State);
                MBC.SerializeState(State);
                Sound.SerializeState(State);
                GetTimer.SerializeState(State);
                GetInterruptManager.SerializeState(State);
                GetJoypad.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, CoreID, FROMData, Transfer, FStorage);
              if Sound.Audio <> nil then
                Sound.Audio.Clear;
              // Host key state is authoritative after restoring the emulated JOYP.
              FLock.Acquire;
              try
                for var Key := Low(TGBKey) to High(TGBKey) do
                  if Key in FPressedKeys then
                    GetJoypad.KeyDown(GetJoypad.KeyBindings[Key])
                  else
                    GetJoypad.KeyUp(GetJoypad.KeyBindings[Key]);
              finally
                FLock.Release;
              end;
              PublishFrame(GPU.Screen);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreID, FROMData, Transfer, FStorage);
              var Preview := GPU.Screen;
              if CoreID = 'GB' then
              begin
                var Palette: Integer;
                FLock.Acquire;
                try
                  Palette := FScreenPalette;
                finally
                  FLock.Release;
                end;
                for var i := 0 to High(Preview) do
                begin
                  var Color := ScreenPalettes[Palette].Colors[EnsureRange(Preview[i], 0, 3)];
                  Move(Color, Preview[i], SizeOf(Color));
                end;
              end;
              SaveSnapshotPreview(Path, 160, 144, 160, @Preview[0], FStorage);
            end;
            HintNextCycles := CPU.Cycles + FrameCycles;
            StartCycles := CPU.Cycles;
            PacingStart := TStopwatch.GetTimeStamp;
          end);
        ApplyInput;
        FLock.Acquire;
        try
          if FPauseRequested then
          begin
            SaveBattery(MBC);
            FrameHints.Pause;
            // The stop event also wakes this short sleep during shutdown.
            FLock.Release;
            try
              FStopEvent.WaitFor(25);
            finally
              FLock.Acquire;
            end;
            HintNextCycles := CPU.Cycles + FrameCycles;
            StartCycles := CPU.Cycles;
            PacingStart := TStopwatch.GetTimeStamp;
            Continue;
          end;
        finally
          FLock.Release;
        end;
        FrameHints.BeginWork;
        Sound.Volume := FSoundVolume;
        var NextCycles := CPU.Cycles + BatchCycles;
        while (CPU.Cycles < NextCycles) and not Terminated do
          CPU.Step;
        if BatteryWatch.ElapsedMilliseconds >= 2000 then
        begin
          SaveBattery(MBC);
          BatteryWatch := TStopwatch.StartNew;
        end;
        // Sum only active batches: limiter waits between them are excluded.
        var HintComplete := CPU.Cycles >= HintNextCycles;
        FrameHints.EndWork(HintComplete);
        if HintComplete then
          Inc(HintNextCycles, FrameCycles);

        var TargetTicks := Round((CPU.Cycles - StartCycles) * (TStopwatch.Frequency / CPUClockFrequency));
        var Remaining := PacingStart + TargetTicks - TStopwatch.GetTimeStamp;
        if Remaining > 0 then
        begin
          if FrameHints.WaitUntil(FStopEvent, PacingStart + TargetTicks) then
            Break;
        end
        else if Remaining < -TStopwatch.Frequency div 4 then
        begin
          // Do not run a long catch-up burst after a debugger pause or system sleep.
          StartCycles := CPU.Cycles;
          PacingStart := TStopwatch.GetTimeStamp;
        end;
      end;
    finally
      try
        SaveBattery(MBC);
      finally
        FrameHints.Free;
        CPU.Free;
        Sound.Free;
        Memory.Free;
        MBC.Free;
        GPU.Free;
        ROM.Free;
        ReleasePeripherals;
      end;
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

