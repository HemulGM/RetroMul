unit MSX.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, MSX.Console,
  MSX.Machine;

type
  TMSXWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FMediaCommands: TSnapshotQueue;
    FStorage: IStorage;
    FData, FBios, FSubROM: TBytes;
    FModel: TMSXModel;
    FInput: TEmulatorInput;
    FKeys: TMSXHostKeys;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    FMouseDX, FMouseDY: Integer;
    FMouseButtons: Byte;
    procedure Publish(Console: TMSXConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory: string;
    SaveFile: string;
    MapperHint: Integer;
    MediaKind: TMSXMediaKind;
    Options: TMSXPeripheralOptions;
    DiskSaveFiles: array[0..1] of string;
    RTCFile, Cartridge2SaveFile, TapeRecordFile: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const Data: TBytes; Model: TMSXModel; const Storage: IStorage; const BIOS, SubROM: TBytes);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; const Keys: TMSXHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
    procedure MoveMouse(DX, DY: Integer; Buttons: Byte);
    procedure OpenDisk(const Location: string);
    procedure EjectDisk;
    procedure StopAndSave;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
  end;

implementation

uses
  System.Diagnostics, System.Math, Core.SavePaths, Core.PerformanceHints,
  PCM.Audio, System.UITypes, System.DateUtils, System.IOUtils, MSX.Floppy;

function TMSXWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TMSXWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TMSXWorker.Create(const Data: TBytes; Model: TMSXModel; const Storage: IStorage; const BIOS, SubROM: TBytes);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FInputPortsCommand := TInputPortsCommand.Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FMediaCommands := TSnapshotQueue.Create(False);
  FData := Copy(Data);
  FBios := Copy(BIOS);
  FSubROM := Copy(SubROM);
  FModel := Model;
  FStorage := Storage;
  MapperHint := -1;
end;

destructor TMSXWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FMediaCommands.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TMSXWorker.MoveMouse(DX, DY: Integer; Buttons: Byte);
begin
  FLock.Acquire;
  try
    FMouseDX := EnsureRange(Int64(FMouseDX) + DX, -$100000, $100000);
    FMouseDY := EnsureRange(Int64(FMouseDY) + DY, -$100000, $100000);
    FMouseButtons := Buttons and 3;
  finally
    FLock.Release;
  end;
end;

procedure TMSXWorker.OpenDisk(const Location: string);
begin
  FMediaCommands.Execute(Self, Location, True);
end;

procedure TMSXWorker.EjectDisk;
begin
  FMediaCommands.Execute(Self, '', False);
end;

procedure TMSXWorker.Configure(const Input: TEmulatorInput; const Keys: TMSXHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
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

procedure TMSXWorker.RequestReset;
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

procedure TMSXWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TMSXWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TMSXWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TMSXWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TMSXWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TMSXWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TMSXWorker.Publish(Console: TMSXConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := Console.VDP.ScreenWidth;
  Frame.Height := Console.VDP.OutputHeight;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  Frame.Pixels := Copy(Console.VDP.Output, 0, Frame.Width * Frame.Height);
  if (Console.Model <> MSX1) and not Console.VDP.Interlaced then
  begin
    var Native := Frame.Pixels;
    Frame.Height := Frame.Height * 2;
    SetLength(Frame.Pixels, Frame.Width * Frame.Height);
    for var Y := 0 to Console.VDP.ScreenHeight - 1 do
    begin
      Move(Native[Y * Frame.Width], Frame.Pixels[Y * 2 * Frame.Width], Frame.Width * SizeOf(TAlphaColor));
      Move(Native[Y * Frame.Width], Frame.Pixels[(Y * 2 + 1) * Frame.Width], Frame.Width * SizeOf(TAlphaColor));
    end;
  end;
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TMSXWorker.Execute;
var
  Console: TMSXConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keys: TMSXHostKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed, ReadyToSave: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
  MouseDX, MouseDY: Integer;
  MouseButtons: Byte;
  SaveBytes: TProc<string, TBytes>;
  SaveDisk: TProc<Integer>;

  procedure LoadDiskSave(Drive: Integer; const Original: TBytes);
  begin
    if (Length(Original) > 0) and (DiskSaveFiles[Drive] <> '') and FStorage.Exists(DiskSaveFiles[Drive]) then
      Console.Floppy.Controller.MountImage(FStorage.ReadBytes(DiskSaveFiles[Drive]), Drive,
        Options.DiskWriteProtected, SnapshotIdentity(Original));
  end;

  procedure LoadRTC;
  begin
    if (FModel = MSX1) or (RTCFile = '') or not FStorage.Exists(RTCFile) then
      Exit;
    var Bytes := FStorage.ReadBytes(RTCFile);
    if (Length(Bytes) <> 70) or (TEncoding.ASCII.GetString(Bytes, 0, 8) <> 'MSXRTC01') then
      raise EReadError.Create('Invalid MSX RTC battery file');
    var SavedUTC: Int64;
    Move(Bytes[8], SavedUTC, 8);
    Console.RTC.LoadBattery(Copy(Bytes, 16, 54));
    var CurrentUTC := DateTimeToUnix(TTimeZone.local.ToUniversalTime(Now), True);
    if (SavedUTC >= 0) and (SavedUTC < CurrentUTC) then
      Console.RTC.ElapseSeconds(CurrentUTC - SavedUTC);
  end;

  procedure SaveRTC;
  begin
    if (FModel = MSX1) or (RTCFile = '') then
      Exit;
    var Bytes := TEncoding.ASCII.GetBytes('MSXRTC01');
    SetLength(Bytes, 16);
    var UTC := DateTimeToUnix(TTimeZone.local.ToUniversalTime(Now), True);
    Move(UTC, Bytes[8], 8);
    Bytes := Bytes + Console.RTC.Battery;
    SaveBytes(RTCFile, Bytes);
  end;

begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  ReadyToSave := False;
  SaveBytes :=
    procedure(Path: string; Bytes: TBytes)
    begin
      if (Path = '') or (Length(Bytes) = 0) then
        Exit;
      var S := TBytesStream.Create(Bytes);
      try
        SaveStreamAtomically(S, Path, FStorage);
      finally
        S.Free;
      end;
    end;
  SaveDisk :=
    procedure(Drive: Integer)
    begin
      var D := Console.Floppy.Controller.Disk(Drive);
      if (D <> nil) and D.Dirty and not D.WriteProtected and (DiskSaveFiles[Drive] <> '') then
      begin
        SaveBytes(DiskSaveFiles[Drive], D.Image);
        D.Dirty := False;
      end;
    end;
  CoreId := UpperCase(MSXSystemId(FModel));
  try
    try
      var Cart := FData;
      if MediaKind <> CartridgeMedia then
        Cart := nil;
      Console := TMSXConsole.Create(Cart, FModel, MapperHint, FBios, FSubROM);
      Console.ConfigurePeripherals(Options);
      LoadDiskSave(0, Options.DiskA);
      LoadDiskSave(1, Options.DiskB);
      LoadRTC;
      if (Console.Cartridge2 <> nil) and (Cartridge2SaveFile <> '') and FStorage.Exists(Cartridge2SaveFile) then
        Console.Cartridge2.LoadRAM(FStorage.ReadBytes(Cartridge2SaveFile));
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
        Console.Cartridge.LoadRAM(FStorage.ReadBytes(SaveFile));
      ReadyToSave := True;
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), CoreId);
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 2048;
      Format.BlockCount := 4;
      Deadline := TStopwatch.GetTimeStamp;
      WasEnabled := False;
      WasPaused := False;
      AudioFailed := False;
      while not Terminated do
      begin
        FInputPortsCommand.Process(
          procedure(const Ports: TCoreInputPorts)
          begin
            Console.SetMousePorts((Options.MousePort = 1) or (Ports.Devices[0] = 'mouse'),
              (Options.MousePort = 2) or (Ports.Devices[1] = 'mouse'));
          end);
        FMediaCommands.Process(
          procedure(const Location: string; Mounting: Boolean)
          begin
            if not Console.Floppy.Enabled then
              raise EInvalidOpException.Create('Configure a Philips disk ROM before inserting disks');
            var Data: TBytes;
            if Mounting then
              Data := FStorage.ReadBytes(Location);
            var NewSave, SourceIdentity: string;
            if Mounting then
            begin
              SourceIdentity := SnapshotIdentity(Data);
              NewSave := FStorage.GameSave(MSXSystemId(FModel), Location, SourceIdentity) + '.dsk';
              var Check := TMSXWD2793.Create;
              try
                Check.MountImage(Data, 0, Options.DiskWriteProtected);
                var Current := Console.Floppy.Controller.Disk(0);
                if SameText(NewSave, DiskSaveFiles[0]) and (Current <> nil) and Current.Dirty then
                  Data := Current.Image
                else if FStorage.Exists(NewSave) then
                  Data := FStorage.ReadBytes(NewSave);
                Check.MountImage(Data, 0, Options.DiskWriteProtected);
              finally
                Check.Free;
              end;
            end;
            SaveDisk(0);
            if Mounting then
            begin
              Console.Floppy.Controller.MountImage(Data, 0, Options.DiskWriteProtected, SourceIdentity);
              DiskSaveFiles[0] := NewSave;
            end
            else
            begin
              Console.Floppy.Controller.Eject(0);
              DiskSaveFiles[0] := '';
            end;
            Publish(Console);
          end);
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
              LoadCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              Publish(Console);
              SaveSnapshotPreview(Path, FFrame.Width, FFrame.Height, FFrame.Width, @FFrame.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Input := FInput;
          Keys := FKeys;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
          MouseDX := FMouseDX;
          MouseDY := FMouseDY;
          MouseButtons := FMouseButtons;
          FMouseDX := 0;
          FMouseDY := 0;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          Hints.Pause;
          Console.Reset;
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
        if InputPorts.Devices[0] = 'none' then
          Input.Buttons := [];
        if InputPorts.Devices[1] = 'none' then
          Input.Buttons2 := [];
        if not InputPorts.KeyboardEnabled then
          FillChar(Keys, SizeOf(Keys), 0);
        Hints.BeginWork;
        Console.SetInput(Input, Keys);
        Console.SendMouseDelta(MouseDX, MouseDY, MouseButtons);
        Console.RunFrame;

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
    if (Console <> nil) and ReadyToSave then
    try
      SaveDisk(0);
      SaveDisk(1);
      SaveRTC;
      if (Console.Cartridge2 <> nil) and Console.Cartridge2.Dirty then
        SaveBytes(Cartridge2SaveFile, Console.Cartridge2.SaveRAM);
      if Console.Cassette.Recording then
        SaveBytes(TapeRecordFile, Console.Cassette.SaveWAV);
    except
      on E: Exception do
        FError := CoreId + ' peripheral save: ' + E.Message;
    end;
    if (Console <> nil) and ReadyToSave and (SaveFile <> '') then
    try
      var Saved: TBytes;
      if Console.Cartridge.Dirty then
        Saved := Console.Cartridge.SaveRAM;
      if Length(Saved) > 0 then
      begin
        var Stream := TBytesStream.Create(Saved);
        try
          SaveStreamAtomically(Stream, SaveFile, FStorage);
        finally
          Stream.Free;
        end;
      end;
    except
      on E: Exception do
        FError := CoreId + ' save: ' + E.Message;
    end;
    Hints.Free;
    Audio.Free;
    Console.Free;
  end;
end;

end.

