unit ZX.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, ZX.Console, ZX.Machine;

type
  TZXWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FData: TBytes;
    FName: string;
    FMachine: TZXMachineConfig;
    FOptions: TZXRuntimeOptions;
    FPreparedConsole: TZXConsole;
    FPreparedOptions: TZXRuntimeOptions;
    FFastForward: Boolean;
    FMouseDX, FMouseDY: Integer;
    FMouseButtons: Byte;
    FNMIPending: Boolean;
    FInput: TEmulatorInput;
    FKeys: TZXHostKeys;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError, FTapeStatus: string;
    FTapeChoices: TArray<string>;
    FTapeCommands: TArray<Integer>;
    procedure Publish(Console: TZXConsole);
    procedure PersistNeoGSFlash(Console: TZXConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, DiskSaveFile, CMOSSaveFile, ServiceROMFile, TimexCartridgeFile: string;
    DivImageFile, DivFirmwareFile, DivSaveFile: string;
    DivImageHash: TBytes;
    MoonSoundFlashFile: string;
    NeoGSImageFile, NeoGSSaveFile, NeoGSFlashFile: string;
    NeoGSImageHash: TBytes;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const Data: TBytes; const Name: string; const Storage: IStorage; Tape128: Boolean = False; Pentagon: Boolean = False; PentagonRAMKB: Integer = 128); overload;
    constructor Create(const Data: TBytes; const Name: string; const Storage: IStorage; const Machine: TZXMachineConfig); overload;
    // Data is privately owned by the adapter and remains immutable for restarts.
    constructor CreatePrepared(const Data: TBytes; const Name: string; const Storage: IStorage; const Machine: TZXMachineConfig; const Options: TZXRuntimeOptions; var Console: TZXConsole);
    destructor Destroy; override;
    procedure SetFastForward(Enabled: Boolean);
    procedure MoveMouse(DX, DY: Integer; Buttons: Byte);
    procedure ConfigureOptions(const Options: TZXRuntimeOptions);
    procedure Configure(const Input: TEmulatorInput; const Keys: TZXHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    procedure RequestNMI;
    procedure StopAndSave;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    procedure ControlTape(Command: Integer);
    function GetTapeStatus: string;
    function GetTapeChoices: TArray<string>;
  end;

implementation

uses
  System.Diagnostics, System.Math, Core.SavePaths, Core.PerformanceHints,
  PCM.Audio;

function TZXWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TZXWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TZXWorker.Create(const Data: TBytes; const Name: string; const Storage: IStorage; Tape128, Pentagon: Boolean; PentagonRAMKB: Integer);
begin
  Create(Data, Name, Storage, TZXMachineConfig.FromLegacy(Tape128, Pentagon, PentagonRAMKB));
end;

constructor TZXWorker.Create(const Data: TBytes; const Name: string; const Storage: IStorage; const Machine: TZXMachineConfig);
begin
  Machine.Profile;
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FData := Copy(Data);
  FStorage := Storage;
  FName := Name;
  FMachine := Machine;
  FOptions := TZXRuntimeOptions.Defaults;
end;

constructor TZXWorker.CreatePrepared(const Data: TBytes; const Name: string; const Storage: IStorage; const Machine: TZXMachineConfig; const Options: TZXRuntimeOptions; var Console: TZXConsole);
begin
  Create(nil, Name, Storage, Machine);
  FData := Data;
  FPreparedOptions := Options.Normalized;
  FPreparedConsole := Console;
  Console := nil;
end;

procedure TZXWorker.SetFastForward(Enabled: Boolean);
begin
  FLock.Acquire;
  try
    FFastForward := Enabled;
  finally
    FLock.Release;
  end;
end;

destructor TZXWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FPreparedConsole.Free;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TZXWorker.MoveMouse(DX, DY: Integer; Buttons: Byte);
begin
  FLock.Acquire;
  try
    FMouseDX := (FMouseDX + (DX mod 256)) mod 256;
    FMouseDY := (FMouseDY + (DY mod 256)) mod 256;
    FMouseButtons := Buttons and 7;
  finally
    FLock.Release;
  end;
end;

procedure TZXWorker.ConfigureOptions(const Options: TZXRuntimeOptions);
begin
  FLock.Acquire;
  try
    FOptions := Options.Normalized;
  finally
    FLock.Release;
  end;
  // Applied on the next frame (or within 10 ms while paused); input updates
  // must not wake the frame pacer and inadvertently accelerate emulation.
end;

procedure TZXWorker.Configure(const Input: TEmulatorInput; const Keys: TZXHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FKeys := Keys;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TZXWorker.RequestNMI;
begin
  FLock.Acquire;
  try
    FNMIPending := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TZXWorker.RequestReset;
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

procedure TZXWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TZXWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TZXWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TZXWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TZXWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TZXWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TZXWorker.ControlTape(Command: Integer);
begin
  FLock.Acquire;
  try
    if Length(FTapeCommands) < 64 then
      FTapeCommands := FTapeCommands + [Command];
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TZXWorker.GetTapeStatus: string;
begin
  FLock.Acquire;
  try
    Result := FTapeStatus;
  finally
    FLock.Release;
  end;
end;

function TZXWorker.GetTapeChoices: TArray<string>;
begin
  FLock.Acquire;
  try
    Result := Copy(FTapeChoices);
  finally
    FLock.Release;
  end;
end;

procedure TZXWorker.Publish(Console: TZXConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := Console.Width;
  Frame.Height := Console.Height;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  Frame.Pixels := Copy(Console.Pixels);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TZXWorker.PersistNeoGSFlash(Console: TZXConsole);
begin
  if (Console <> nil) and (Console.MoonSound <> nil) and Console.MoonSound.FlashDirty and (MoonSoundFlashFile <> '') then
  begin
    var MoonStream := TBytesStream.Create(Console.MoonSound.FlashImage);
    try
      SaveStreamAtomically(MoonStream, MoonSoundFlashFile, FStorage);
    finally
      MoonStream.Free;
    end;
  end;
  if (Console = nil) or (Console.NeoGS = nil) or not Console.NeoGS.FlashDirty or
    (NeoGSFlashFile = '') then
    Exit;
  var Stream := TBytesStream.Create(Console.NeoGS.FlashImage);
  try
    SaveStreamAtomically(Stream, NeoGSFlashFile, FStorage);
  finally
    Stream.Free;
  end;
end;

procedure TZXWorker.Execute;
var
  Console: TZXConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keys: TZXHostKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
  Options: TZXRuntimeOptions;
  TapeSpeed: Integer;
  MouseDX, MouseDY: Integer;
  MouseButtons: Byte;
  NMI, FastForward, Prepared: Boolean;
  PreviousSpeed: Integer;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'ZX';
  try
    try
      FLock.Acquire;
      try
        Options := FOptions;
      finally
        FLock.Release;
      end;
      Prepared := (FPreparedConsole <> nil) and CompareMem(@Options, @FPreparedOptions, SizeOf(Options));
      if Prepared then
      begin
        Console := FPreparedConsole;
        FPreparedConsole := nil;
        Console.CMOS.SetDateTime(Now);
      end
      else
      begin
        FreeAndNil(FPreparedConsole);
        Console := TZXConsole.Create;
        Console.ApplyOptions(Options);
        Console.Load(FData, FName, FMachine);
      end;
      if not Prepared and (TimexCartridgeFile <> '') and (Console.Machine.Model = zmTimex2068) and not SameText(ExtractFileExt(FName), '.dck') then
        Console.MountTimexCartridge(FStorage.ReadBytes(TimexCartridgeFile));
      if not Prepared and (DivFirmwareFile <> '') then
        Console.DivStorage.Configure(Console.DivStorage.Kind, FMachine.DivRAMKB, FStorage.ReadBytes(DivFirmwareFile));
      if not Prepared and (DivImageFile <> '') then
        Console.DivStorage.Mount(FStorage.OpenRead(DivImageFile), DivImageHash);
      if (Console.DivStorage.Disk <> nil) and (DivSaveFile <> '') and FStorage.Exists(DivSaveFile) then
        Console.DivStorage.Disk.LoadOverlay(FStorage.ReadBytes(DivSaveFile));
      if (Console.MoonSound <> nil) and (MoonSoundFlashFile <> '') and FStorage.Exists(MoonSoundFlashFile) then
        Console.MoonSound.LoadFlash(FStorage.ReadBytes(MoonSoundFlashFile));
      if (Console.NeoGS <> nil) and (NeoGSFlashFile <> '') and FStorage.Exists(NeoGSFlashFile) then
        Console.NeoGS.LoadFlash(FStorage.ReadBytes(NeoGSFlashFile));
      if (Console.NeoGS <> nil) and (NeoGSImageFile <> '') then
      begin
        if not Prepared then
          Console.NeoGS.Mount(FStorage.OpenRead(NeoGSImageFile), NeoGSImageHash);
        if (NeoGSSaveFile <> '') and FStorage.Exists(NeoGSSaveFile) then
          Console.NeoGS.Disk.LoadOverlay(FStorage.ReadBytes(NeoGSSaveFile));
        Console.NeoGS.Disk.WriteProtected := Options.DiskWriteProtected;
      end;
      if (ServiceROMFile <> '') and (Console.Pentagon and (Console.RAMSizeKB = 1024)) then
        Console.SetServiceROM(FStorage.ReadBytes(ServiceROMFile));
      if (Console.Beta.Disk <> nil) and (DiskSaveFile <> '') and FStorage.Exists(DiskSaveFile) then
        Console.Beta.Mount(FStorage.ReadBytes(DiskSaveFile), False, 0, (Console.Beta.Disk.SectorSize = 1024) and (Console.Machine.Model <> zmByte01), Console.Machine.Model = zmByte01);
      if (Console.Plus3Disk <> nil) and (DiskSaveFile <> '') and FStorage.Exists(DiskSaveFile) then
        Console.MountPlus3Disk(FStorage.ReadBytes(DiskSaveFile));
      if Console.Pentagon and (Console.RAMSizeKB = 1024) and (CMOSSaveFile <> '') and FStorage.Exists(CMOSSaveFile) then
        Console.CMOS.LoadBattery(FStorage.ReadBytes(CMOSSaveFile));
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), CoreId);
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 2048;
      Format.BlockCount := 4;
      Deadline := TStopwatch.GetTimeStamp;
      PreviousSpeed := 1;
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
              end;
            if Loading then
            begin
              // A state may remove the board. Retain completed guest flash writes.
              PersistNeoGSFlash(Console);
              LoadCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              FLock.Acquire;
              try
                Options := FOptions;
              finally
                FLock.Release;
              end;
              Console.ApplyOptions(Options);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.Width, Console.Height, Console.Width, @Console.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        var TapeCommands: TArray<Integer>;
        FLock.Acquire;
        try
          TapeCommands := FTapeCommands;
          FTapeCommands := nil;
          Options := FOptions;
          FastForward := FFastForward;
          NMI := FNMIPending;
          FNMIPending := False;
          MouseDX := FMouseDX;
          MouseDY := FMouseDY;
          MouseButtons := FMouseButtons;
          FMouseDX := 0;
          FMouseDY := 0;
          Input := FInput;
          Keys := FKeys;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;
        Console.ApplyOptions(Options);
        if ResetRequested then
        begin
          Hints.Pause;
          var DiskImage: TBytes;
          var DiskChanged := False;
          var ProfiMedia := False;
          var ByteMedia := False;
          if Console.Beta.Disk <> nil then
          begin
            DiskImage := Console.Beta.Disk.Image;
            DiskChanged := Console.Beta.Disk.Dirty;
            ByteMedia := (Console.Machine.Model = zmByte01) and (Console.Beta.Disk.SectorSize = 1024);
            ProfiMedia := (Console.Beta.Disk.SectorSize = 1024) and not ByteMedia;
          end;
          var Plus3Image: TBytes;
          var Plus3Changed := False;
          if Console.Plus3Disk <> nil then
          begin
            Plus3Image := Console.Plus3Disk.Image;
            Plus3Changed := Console.Plus3Disk.Dirty;
          end;
          var DivOverlay: TBytes;
          if Console.DivStorage.Disk <> nil then
            DivOverlay := Console.DivStorage.Disk.SaveOverlay;
          var NeoGSOverlay: TBytes;
          if (Console.NeoGS <> nil) and (Console.NeoGS.Disk <> nil) then
            NeoGSOverlay := Console.NeoGS.Disk.SaveOverlay;
          Console.Load(FData, FName, FMachine);
          if (Console.NeoGS <> nil) and (NeoGSImageFile <> '') then
          begin
            if Console.NeoGS.Disk = nil then
              Console.NeoGS.Mount(FStorage.OpenRead(NeoGSImageFile), NeoGSImageHash);
            if Length(NeoGSOverlay) > 0 then
              Console.NeoGS.Disk.LoadOverlay(NeoGSOverlay);
            Console.NeoGS.Disk.WriteProtected := Options.DiskWriteProtected;
          end;
          if (TimexCartridgeFile <> '') and (Console.Machine.Model = zmTimex2068) and not SameText(ExtractFileExt(FName), '.dck') then
            Console.MountTimexCartridge(FStorage.ReadBytes(TimexCartridgeFile));
          if DivFirmwareFile <> '' then
            Console.DivStorage.Configure(Console.DivStorage.Kind, FMachine.DivRAMKB, FStorage.ReadBytes(DivFirmwareFile));
          if Length(DivOverlay) > 0 then
            Console.DivStorage.Disk.LoadOverlay(DivOverlay);
          if (ServiceROMFile <> '') and (Console.Pentagon and (Console.RAMSizeKB = 1024)) then
            Console.SetServiceROM(FStorage.ReadBytes(ServiceROMFile));
          if Length(DiskImage) <> 0 then
          begin
            Console.Beta.Mount(DiskImage, False, 0, ProfiMedia, ByteMedia);
            Console.Beta.Disk.Dirty := DiskChanged;
          end;
          if Length(Plus3Image) <> 0 then
          begin
            Console.MountPlus3Disk(Plus3Image);
            Console.Plus3Disk.Dirty := Plus3Changed;
          end;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp;
        end;
        if NMI then
          Console.RequestNMI;
        Console.MoveMouse(MouseDX, MouseDY, MouseButtons);
        Console.ApplyOptions(Options); // Also apply protection after disk remount/reset.
        for var Command in TapeCommands do
          case Command of
            1:
              if Console.Tape.Stopped then
                Console.Tape.Play
              else
                Console.Tape.Stop;
            2:
              Console.Tape.Rewind;
          else
            if (Command >= 1000) and (Command - 1000 < Length(Console.Tape.Choices)) then
              Console.Tape.Select(Command - 1000);
          end;
        FLock.Acquire;
        try
          FTapeChoices := Copy(Console.Tape.Choices);
          FTapeStatus := Console.Tape.MessageText;
          if FTapeStatus = '' then
            if Console.Tape.Stopped then
              FTapeStatus := 'Tape stopped. F7: play, F8: rewind'
            else
              FTapeStatus := 'Tape playing. F7: pause, F8: rewind';
        finally
          FLock.Release;
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
        if InputPorts.Devices[0] = 'none' then
          Input.Buttons := [];
        if InputPorts.Devices[1] = 'none' then
          Input.Buttons2 := [];
        if not InputPorts.KeyboardEnabled then
          FillChar(Keys, SizeOf(Keys), 0);
        Hints.BeginWork;
        Console.SetInput(Input, Keys);
        Console.RunFrame;

        if Terminated then
          Break;

        TapeSpeed := Options.PlaybackSpeed(Console.HasTape, Console.Tape.Stopped, FastForward);
        if (TapeSpeed = 1) or (Console.FrameNumber mod Cardinal(TapeSpeed) = 0) then
          Publish(Console);
        if TapeSpeed <> PreviousSpeed then
          Deadline := TStopwatch.GetTimeStamp;
        PreviousSpeed := TapeSpeed;
        Enabled := Enabled and (TapeSpeed = 1); // Accelerated playback is muted, without changing chip clocks.
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
        Deadline := Deadline + TStopwatch.Frequency / (Console.FramesPerSecond * TapeSpeed);
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        Hints.WaitUntil(FWake, Round(Deadline));
      end;
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
    if (Console <> nil) and (Console.DivStorage.Disk <> nil) and Console.DivStorage.Disk.Dirty and (DivSaveFile <> '') then
    try
      var Stream := TBytesStream.Create(Console.DivStorage.Disk.SaveOverlay);
      try
        SaveStreamAtomically(Stream, DivSaveFile, FStorage);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (((Console.NeoGS <> nil) and Console.NeoGS.FlashDirty and (NeoGSFlashFile <> '')) or
      ((Console.MoonSound <> nil) and Console.MoonSound.FlashDirty and (MoonSoundFlashFile <> ''))) then
    try
      PersistNeoGSFlash(Console);
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (Console.NeoGS <> nil) and (Console.NeoGS.Disk <> nil) and
      Console.NeoGS.Disk.Dirty and (NeoGSSaveFile <> '') then
    try
      var Stream := TBytesStream.Create(Console.NeoGS.Disk.SaveOverlay);
      try
        SaveStreamAtomically(Stream, NeoGSSaveFile, FStorage);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (DiskSaveFile <> '') and (Console.Beta.Disk <> nil) and Console.Beta.Disk.Dirty then
    try
      var DiskStream := TBytesStream.Create(Console.Beta.Disk.Image);
      try
        SaveStreamAtomically(DiskStream, DiskSaveFile, FStorage);
      finally
        DiskStream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (DiskSaveFile <> '') and (Console.Plus3Disk <> nil) and Console.Plus3Disk.Dirty then
    try
      var Stream := TBytesStream.Create(Console.Plus3Disk.Image);
      try
        SaveStreamAtomically(Stream, DiskSaveFile, FStorage);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (CMOSSaveFile <> '') and (Console.Pentagon and (Console.RAMSizeKB = 1024)) then
    try
      var Stream := TBytesStream.Create(Console.CMOS.SaveBattery);
      try
        SaveStreamAtomically(Stream, CMOSSaveFile, FStorage);
      finally
        Stream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    Console.Free;
  end;
end;

end.

