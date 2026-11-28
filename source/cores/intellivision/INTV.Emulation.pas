unit INTV.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, INTV.Console,
  INTV.STIC, INTV.ECS, INTV.KeyboardComponent, Core.Input.Keyboard,
  Core.Microphone;

type
  TIntvWorker = class(TAchievementWorker)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FData, FExec, FGROM, FIdentity, FECSROM, FVoiceROM: TBytes;
    FKeyboardFirmware: TIntvKeyboardFirmware;
    FMapping: string;
    FPAL, FSTIC1A: Boolean;
    FInput: TEmulatorInput;
    FKeypads: TIntvKeypads;
    FECSKeys: THostKeyboardKeys;
    FMicrophone: IMicrophoneSource;
    FMicrophoneOverridden: Boolean;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TIntvConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, FlashPath, KeyboardTapePath, KeyboardPrintPath: string;
    KeyboardTape, KeyboardTapeAudio: TBytes;
    KeyboardMicrophoneEnabled: Boolean;
    ECSInput: TIntvECSInput;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const Data, Exec, GROM, Identity, ECSROM, VoiceROM: TBytes; const Mapping: string; PAL: Boolean; const Storage: IStorage; const KeyboardFirmware: TIntvKeyboardFirmware; STIC1A: Boolean = False);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; const Keypads: TIntvKeypads; const ECSKeys: THostKeyboardKeys; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure SetMicrophoneSource(const Source: IMicrophoneSource);
    procedure RequestReset;
    procedure StopAndWait;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
  end;

implementation

uses
  System.Diagnostics, System.IOUtils, System.Math, Core.SavePaths,
  Core.PerformanceHints, PCM.Audio;

function TIntvWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TIntvWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TIntvWorker.Create(const Data, Exec, GROM, Identity, ECSROM, VoiceROM: TBytes; const Mapping: string; PAL: Boolean; const Storage: IStorage; const KeyboardFirmware: TIntvKeyboardFirmware; STIC1A: Boolean);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FData := Copy(Data);
  FStorage := Storage;
  FPAL := PAL;
  FSTIC1A := STIC1A;
  FExec := Exec;
  FGROM := GROM;
  FIdentity := Identity;
  FECSROM := ECSROM;
  FVoiceROM := VoiceROM;
  FKeyboardFirmware := KeyboardFirmware;
  FMapping := Mapping;
end;

destructor TIntvWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TIntvWorker.SetMicrophoneSource(const Source: IMicrophoneSource);
begin
  FLock.Acquire;
  try
    FMicrophone := Source;
    FMicrophoneOverridden := True;
  finally
    FLock.Release;
  end;
end;

procedure TIntvWorker.Configure(const Input: TEmulatorInput; const Keypads: TIntvKeypads; const ECSKeys: THostKeyboardKeys; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FKeypads := Keypads;
    FECSKeys := ECSKeys;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TIntvWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TIntvWorker.StopAndWait;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TIntvWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TIntvWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TIntvWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TIntvWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TIntvWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function CaptureFrame(Console: TIntvConsole): TEmulatorFrame;
begin
  // STIC MOBs address individual scanlines, while each background row
  // covers two. Expand each column to retain the display proportions.
  Result.Width := IntvScreenWidth * 2;
  Result.Height := IntvScreenHeight;
  Result.FrameNumber := Console.FrameNumber;
  Result.FramesPerSecond := Console.FramesPerSecond;
  SetLength(Result.Pixels, Result.Width * Result.Height);
  var Pixels := Console.STIC.Pixels;
  for var Index := 0 to High(Pixels) do
  begin
    Result.Pixels[Index * 2] := Pixels[Index];
    Result.Pixels[Index * 2 + 1] := Pixels[Index];
  end;
  if Console.KeyboardComponent <> nil then
    Console.KeyboardComponent.Overlay(Result.Pixels);
end;

procedure TIntvWorker.Publish(Console: TIntvConsole);
begin
  var Frame := CaptureFrame(Console);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TIntvWorker.Execute;
var
  Console: TIntvConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keypads: TIntvKeypads;
  ECSKeys: THostKeyboardKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Microphone, HostMicrophone: IMicrophoneSource;
  MicSamples: TArray<SmallInt>;
  TriedMicrophone, UseHostMicrophone, RecordingAudio: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
begin
  var ReadAchievementMemory: TEmulationAchievementRead :=
    function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
    begin
      Result := Console.ReadAchievementRAM(Address, Buffer, Count);
    end;
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'INTV';
  TriedMicrophone := False;
  try
    try
      Console := TIntvConsole.Create(FData, FExec, FGROM, FMapping, FPAL, FSTIC1A);
      if FKeyboardFirmware.MasterROM <> nil then
      begin
        Console.EnableKeyboardComponent(FKeyboardFirmware);
        var Tape := KeyboardTape;
        if (KeyboardTapePath <> '') and FStorage.Exists(KeyboardTapePath) then
        begin
          var Recording := FStorage.OpenRead(KeyboardTapePath);
          try
            if Recording.Size <> Length(KeyboardTape) then
              raise EReadError.Create('Keyboard Component saved tape has the wrong size');
            Tape := nil;
            SetLength(Tape, Length(KeyboardTape));
            Recording.ReadBuffer(Tape[0], Length(Tape));
          finally
            Recording.Free;
          end;
        end;
        Console.KeyboardComponent.Peripherals.Attach(Tape, FStorage, KeyboardTapePath, KeyboardPrintPath);
        Console.KeyboardComponent.Peripherals.AttachAudio(KeyboardTapeAudio);
      end;
      if FECSROM <> nil then
        Console.EnableECS(FECSROM, FStorage, TPath.Combine(FStorage.SaveRoot, 'intellivision-ecs'));
      if FVoiceROM <> nil then
        Console.EnableVoice(FVoiceROM);
      var JLP := Console.Cartridge.JLP;
      if (JLP <> nil) and (FlashPath <> '') and FStorage.Exists(FlashPath) then
        JLP.LoadFlash(FStorage.ReadBytes(FlashPath));
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), CoreId);
      var Format: TPCMAudioFormat;
      Format.SampleRate := IntvSampleRate;
      Format.Channels := 2;
      Format.BlockFrames := 2048;
      Format.BlockCount := 4;
      Deadline := TStopwatch.GetTimeStamp;
      WasEnabled := False;
      WasPaused := False;
      AudioFailed := False;
      while not Terminated do
      begin
        FInputPortsCommand.Process(nil);
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            Hints.Pause;
            var Path := ResolveSnapshotPath(SnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
                // Keyboard tape data already owns the optional snapshot tail.
                if Console.KeyboardComponent = nil then
                  TransferAchievementProgress(State)
                else if State.Loading then
                  RestoreAchievementProgress(nil);
              end;
            if Loading then
            begin
              LoadCoreSnapshotHash(Path, CoreId, FIdentity, Transfer, FStorage);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshotHash(Path, CoreId, FIdentity, Transfer, FStorage);
              var Frame := CaptureFrame(Console);
              SaveSnapshotPreview(Path, Frame.Width, Frame.Height, Frame.Width, @Frame.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Input := FInput;
          Keypads := FKeypads;
          ECSKeys := FECSKeys;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          Microphone := FMicrophone;
          UseHostMicrophone := KeyboardMicrophoneEnabled and not FMicrophoneOverridden;
          FReset := False;
        finally
          FLock.Release;
        end;
        RecordingAudio := (Console.KeyboardComponent <> nil) and
          Console.KeyboardComponent.Peripherals.IsRecordingAudio;
        if UseHostMicrophone and RecordingAudio and not Paused then
        begin
          if not TriedMicrophone then
          begin
            HostMicrophone := OpenHostMicrophone;
            TriedMicrophone := True;
          end;
          Microphone := HostMicrophone;
        end
        else
        begin
          HostMicrophone := nil;
          TriedMicrophone := False;
        end;
        if (Microphone <> nil) and (ResetRequested or (Paused and not WasPaused)) then
          Microphone.Clear;
        if ResetRequested then
        begin
          Hints.Pause;
          Console.Reset;
          ResetAchievements;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp;
        end;
        if Paused then
        begin
          Hints.Pause;
          if not WasPaused and (Audio <> nil) then
            Audio.Clear;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;

        WasPaused := False;
        var Ports := InputPorts;
        if Ports.Devices[0] = 'none' then
        begin
          Input.Buttons := [];
          Input.Analog[0] := Default(TEmulatorAnalogPad);
          Keypads[0] := 0;
        end;
        if Ports.Devices[1] = 'none' then
        begin
          Input.Buttons2 := [];
          Input.Analog[1] := Default(TEmulatorAnalogPad);
          Keypads[1] := 0;
        end;
        Hints.BeginWork;
        if Ports.Devices[2] = 'none' then
        begin
          Input.Buttons3 := [];
          Input.Analog[2] := Default(TEmulatorAnalogPad);
          Keypads[2] := 0;
        end;
        if Ports.Devices[3] = 'none' then
        begin
          Input.Buttons4 := [];
          Input.Analog[3] := Default(TEmulatorAnalogPad);
          Keypads[3] := 0;
        end;
        Console.SetInput(Input, Keypads);
        Console.SetECSInput(ECSKeys, ECSInput);
        if Console.KeyboardComponent <> nil then
          Console.KeyboardComponent.SetInput(ECSKeys);
        if RecordingAudio and (Microphone <> nil) then
        begin
          // Share the console's fractional audio frame timing with live capture.
          SetLength(MicSamples, Console.NextFrameSampleCount);
          Microphone.ReadSamples(MicSamples);
          Console.SetKeyboardMicrophone(MicSamples);
        end
        else
          Console.SetKeyboardMicrophone(nil);
        Console.RunFrame;
        AchievementFrame(ReadAchievementMemory);
        if (Console.KeyboardComponent <> nil) and (Console.FrameNumber mod 60 = 0) then
          Console.KeyboardComponent.Peripherals.FlushWhenIdle;
        if (JLP <> nil) and (FlashPath <> '') and JLP.Dirty then
        begin
          FStorage.WriteBytes(FlashPath, JLP.FlashData);
          JLP.MarkFlashSaved;
        end;

        if Terminated then
          Break;

        Publish(Console);
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          SetLength(Samples, Console.SampleFrames * 2);
          for var i := 0 to High(Samples) do
            Samples[i] := Round(Console.Samples[i] * Volume);
          Audio.Submit(Samples, Console.SampleFrames);

          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := CoreId + ' audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          if WasEnabled and (Audio <> nil) then
            Audio.Clear;
          AudioFailed := False;
        end;
        WasEnabled := Enabled;
        Hints.EndWork;
        Deadline := Deadline + TStopwatch.Frequency / Console.FramesPerSecond;
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        Hints.WaitUntil(FWake, Round(Deadline));
      end;
      if Console.KeyboardComponent <> nil then
        Console.KeyboardComponent.Peripherals.Flush;
      Console.FlushECS;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := CoreId + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    Hints.Free;
    Audio.Free;
    Console.Free;
  end;
end;

end.

