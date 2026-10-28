unit GB.EmulationThread;

interface

uses
  Core.Storage, Core.Snapshots, System.SysUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections, System.Diagnostics, GB.Joypad, GB.GPU, GB.ROM,
  GB.MBC, GB.Memory, GB.Timer, GB.InterruptManager, GB.Camera, GB.Palettes,
  GB.CPU, GB.Sound, GB.RomFormat;

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
    FSnapshotIdentityData: TBytes;
    FEnableAudio: Boolean;
    FLock: TCriticalSection;
    FStopEvent: TEvent;
    FInputEvents: TQueue<TGBInputEvent>;
    FPressedKeys: set of TGBKey;
    FFrame, FPreviousFrame: TScreenArray;
    FHasPreviousFrame: Boolean;
    FRuntimeOptions: TGBRuntimeOptions;
    FFrameAvailable, FHasFrame: Boolean;
    FFramesPerSecond: Double;
    FFrameRateStopwatch: TStopwatch;
    FFramesSinceRateUpdate: Integer;
    FErrorMessage: string;
    FSoundVolume: Single;
    FScreenPalette: Integer;
    FPauseRequested: Boolean;
    FCameraSource: IGBCameraFrameSource;
    FHasCamera: Boolean;
    FRumbleLevel: Byte;
    FRumbleSamples, FRumbleWeightedLevel: UInt64;
    FAccelerationX, FAccelerationY: Double;
    procedure PublishRumble(Level: Byte; Clocks: UInt64 = 0);
    procedure ApplyInput(MBC: TGBMBC);
    procedure SetSoundVolume(const Value: Single);
    procedure SetRuntimeOptions(const Value: TGBRuntimeOptions);
    procedure ApplyRuntimeOptions(CPU: TGBCPU; GPU: TGBVideo; Sound: TGBSound);
    procedure SetScreenPalette(const Value: Integer);
    function GetPauseRequested: Boolean;
  protected
    FBootROMData: TBytes;
    FBootModel: TGBBootModel;
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
    procedure SetAcceleration(X, Y: Double);
    procedure ConfigureBootROM(Model: TGBBootModel; const Data: TBytes);
    property RuntimeOptions: TGBRuntimeOptions write SetRuntimeOptions;
    function TryGetFrame(out Screen: TScreenArray; out FramesPerSecond: Double): Boolean; overload;
    function TryGetFrame(out Screen, Previous: TScreenArray; out HasPrevious: Boolean; out FramesPerSecond: Double): Boolean; overload;
    function TakeError: string;
    function GetRumbleLevel: Byte;
    property SoundVolume: Single read FSoundVolume write SetSoundVolume;
    property ScreenPalette: Integer write SetScreenPalette;
    property PauseRequested: Boolean read GetPauseRequested;
    property HasCamera: Boolean read FHasCamera;
    procedure SubmitCameraFrame(const Frame: TGBCameraFrame);
  end;

implementation

uses
  GB.Cartridge, Core.SavePaths, Core.PerformanceHints, System.IOUtils,
  System.Math;

function TGBEmulationThread.CoreID: string;
begin
  Result := ROM_CORE_ID_GB;
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
  FSnapshotIdentityData := FROMData;
  FEnableAudio := EnableAudio;
  FSoundVolume := 0.5;
  FRuntimeOptions := TGBRuntimeOptions.Defaults;
  FLock := TCriticalSection.Create;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FInputEvents := TQueue<TGBInputEvent>.Create;
  var Footer := ReadGBXFooter(FROMData);
  if Footer.Present then
    FHasCamera := Footer.Mapper = 'CAMR'
  else
    FHasCamera := (Length(FROMData) > $147) and (FROMData[$147] = $FC);
  if FHasCamera then
  begin
    FCameraSource := CameraSource;
    if FCameraSource = nil then
      FCameraSource := TGBCameraFrameSource.Create;
  end;
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

procedure TGBEmulationThread.ConfigureBootROM(Model: TGBBootModel; const Data: TBytes);
begin
  if not Suspended then
    raise EInvalidOpException.Create('Boot ROM must be selected before starting');

  if (Model <> TGBBootModel.Skip) and (GBBootUsesColor(Model) <> (CoreID = ROM_CORE_ID_GBC)) then
    raise EArgumentException.Create('Boot ROM model does not match the worker');

  FBootROMData := PrepareGBBootROM(Model, Data);
  FBootModel := Model;
  FSnapshotIdentityData := FROMData;
  if Length(FBootROMData) > 0 then
  begin
    // Firmware is immutable session data. Reject snapshots made with another
    // boot ROM, including snapshots saved before FF50 has unmapped it.
    FSnapshotIdentityData := Copy(FROMData);
    var Offset := Length(FSnapshotIdentityData);
    SetLength(FSnapshotIdentityData, Offset + 1 + Length(FBootROMData));
    FSnapshotIdentityData[Offset] := Ord(Model);
    Move(FBootROMData[0], FSnapshotIdentityData[Offset + 1], Length(FBootROMData));
  end;
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

procedure TGBEmulationThread.PublishRumble(Level: Byte; Clocks: UInt64);
begin
  FLock.Acquire;
  try
    FRumbleLevel := Level;
    if Clocks = 0 then
    begin
      FRumbleSamples := 0;
      FRumbleWeightedLevel := 0;
    end
    else
    begin
      Inc(FRumbleSamples, Clocks);
      Inc(FRumbleWeightedLevel, UInt64(Level) * Clocks);
    end;
  finally
    FLock.Release;
  end;
end;

function TGBEmulationThread.GetRumbleLevel: Byte;
begin
  FLock.Acquire;
  try
    if Terminated or FPauseRequested then
      Result := 0
    else if FRumbleSamples > 0 then
      Result := (FRumbleWeightedLevel + FRumbleSamples div 2) div FRumbleSamples
    else
      Result := FRumbleLevel;

    // Accumulate all batches between frontend polls, including short pulses
    // that ended before the UI woke up. A static line keeps its last level.
    FRumbleSamples := 0;
    FRumbleWeightedLevel := 0;
  finally
    FLock.Release;
  end;
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
    FRumbleSamples := 0;
    FRumbleWeightedLevel := 0;
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

function TGBEmulationThread.GetPauseRequested: Boolean;
begin
  FLock.Acquire;
  try
    Result := FPauseRequested;
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

procedure TGBEmulationThread.SetRuntimeOptions(const Value: TGBRuntimeOptions);
begin
  var Options := Value;
  Options.Normalize;
  FLock.Acquire;
  try
    var Changed := (Options.FrameBlending <> FRuntimeOptions.FrameBlending);
    for var i := 0 to 2 do
      Changed := Changed or (Options.Palettes[i] <> FRuntimeOptions.Palettes[i]);
    FRuntimeOptions := Options;
    if Changed then
    begin
      FHasPreviousFrame := False;
      if FHasFrame then
        FFrameAvailable := True;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.ApplyRuntimeOptions(CPU: TGBCPU; GPU: TGBVideo; Sound: TGBSound);
begin
  FLock.Acquire;
  try
    GPU.RuntimeOptions := FRuntimeOptions;
    GPU.TagMonochromePixels := True;
    CPU.Overclock := FRuntimeOptions.Overclock;
    Sound.Volume := FSoundVolume;
    for var i := 0 to 3 do
      Sound.SetChannelVolume(i, FRuntimeOptions.ChannelVolumes[i] / 100);
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.SetScreenPalette(const Value: Integer);
begin
  FLock.Acquire;
  try
    var Palette := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
    if FScreenPalette <> Palette then
    begin
      FScreenPalette := Palette;
      FHasPreviousFrame := False;
      if FHasFrame then
        FFrameAvailable := True;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.ReleaseKeys;
begin
  for var Key := Low(TGBKey) to High(TGBKey) do
    SetKeyState(Key, False);
end;

procedure TGBEmulationThread.SetAcceleration(X, Y: Double);
begin
  FLock.Acquire;
  try
    FAccelerationX := X;
    FAccelerationY := Y;
  finally
    FLock.Release;
  end;
end;

procedure TGBEmulationThread.ApplyInput(MBC: TGBMBC);
begin
  FLock.Acquire;
  try
    MBC.SetAcceleration(FAccelerationX, FAccelerationY);
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
    FPreviousFrame := FFrame;
    FHasPreviousFrame := FHasFrame;
    FFrame := Screen;
    FHasFrame := True;
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
  var Previous: TScreenArray;
  var HasPrevious: Boolean;
  Result := TryGetFrame(Screen, Previous, HasPrevious, FramesPerSecond);
end;

function TGBEmulationThread.TryGetFrame(out Screen, Previous: TScreenArray; out HasPrevious: Boolean; out FramesPerSecond: Double): Boolean;
begin
  FLock.Acquire;
  try
    Result := FFrameAvailable;
    FramesPerSecond := FFramesPerSecond;
    HasPrevious := FHasPreviousFrame;
    if Result then
    begin
      Screen := FFrame;
      Previous := FPreviousFrame;
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
      Memory.ConfigureBootROM(FBootROMData);
      Sound := TGBSound.Create(Memory, FEnableAudio);
      CPU := TGBCPU.Create(Memory, GPU, Sound);
      ApplyRuntimeOptions(CPU, GPU, Sound);
      if Length(FBootROMData) = 0 then
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
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
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
              LoadCoreSnapshot(Path, CoreID, FSnapshotIdentityData, Transfer, FStorage);
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
              PublishRumble(MBC.TakeRumbleLevel);
              FLock.Acquire;
              try
                FHasFrame := False;
                FHasPreviousFrame := False;
              finally
                FLock.Release;
              end;
              ApplyRuntimeOptions(CPU, GPU, Sound);
              PublishFrame(GPU.Screen);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreID, FSnapshotIdentityData, Transfer, FStorage);
              var Preview := GPU.Screen;
              FLock.Acquire;
              try
                for var i := 0 to High(Preview) do
                begin
                  var Color := FRuntimeOptions.PresentationColor(Preview[i], FScreenPalette, CoreID = ROM_CORE_ID_GBC);
                  Move(Color, Preview[i], SizeOf(Color));
                end;
              finally
                FLock.Release;
              end;
              SaveSnapshotPreview(Path, 160, 144, 160, @Preview[0], FStorage);
            end;
            HintNextCycles := CPU.Cycles + FrameCycles;
            StartCycles := CPU.Cycles;
            PacingStart := TStopwatch.GetTimeStamp;
          end);
        ApplyInput(MBC);
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
        ApplyRuntimeOptions(CPU, GPU, Sound);
        var RumbleStartCycles := CPU.Cycles;
        var NextCycles := CPU.Cycles + BatchCycles;
        while (CPU.Cycles < NextCycles) and not Terminated do
          CPU.Step;
        if MBC.HasRumble then
          PublishRumble(MBC.TakeRumbleLevel, CPU.Cycles - RumbleStartCycles);
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
      PublishRumble(0);
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

