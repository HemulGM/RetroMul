unit NGP.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, NGP.Console,
  NGP.Cartridge;

type
  TNGPWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FBIOS, FIdentity, FCartridgeROM: TBytes;
    FColor: Boolean;
    FSystemId: string;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FInput: TEmulatorInput;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TNGPConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, SaveFile, SystemSaveFile: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const ROM, BIOS, Identity: TBytes; const Storage: IStorage; Color: Boolean; const SystemId: string);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure RequestReset;
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
  PCM.Audio;

function TNGPWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TNGPWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TNGPWorker.Create(const ROM, BIOS, Identity: TBytes; const Storage: IStorage; Color: Boolean; const SystemId: string);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FBIOS := Copy(BIOS);
  FCartridgeROM := Copy(ROM);
  FColor := Color;
  FSystemId := SystemId;
  FIdentity := Copy(Identity);
  if Length(FIdentity) = 0 then
    FIdentity := Copy(BIOS);
  FStorage := Storage;
end;

destructor TNGPWorker.Destroy;
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

procedure TNGPWorker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TNGPWorker.RequestReset;
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

procedure TNGPWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TNGPWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TNGPWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TNGPWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TNGPWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TNGPWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TNGPWorker.Publish(Console: TNGPConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := Console.FrameWidth;
  Frame.Height := Console.FrameHeight;
  Frame.Pixels := Copy(Console.Pixels);
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TNGPWorker.Execute;
var
  Console: TNGPConsole;
  Hints: TEmulationPerformanceHints;
  Audio: TPCMAudio;
  AudioFailed: Boolean;
begin
  Console := nil;
  Hints := nil;
  Audio := nil;
  AudioFailed := False;
  try
    try
      Console := TNGPConsole.Create(FCartridgeROM, FBIOS, FColor);
      if (SystemSaveFile <> '') and FStorage.Exists(SystemSaveFile) then
        Console.LoadSystemBackup(FStorage.ReadBytes(SystemSaveFile));
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
        Console.LoadBackup(FStorage.ReadBytes(SaveFile));
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 1024;
      Format.BlockCount := 8;
      var Rate: Double := Console.FramesPerSecond;
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Rate), 'NGP');
      var Deadline: Double := TStopwatch.GetTimeStamp;
      while not Terminated do
      begin
        FInputPortsCommand.Process(nil);
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            Hints.Pause;
            if Audio <> nil then
              Audio.Clear;
            var Path := ResolveSnapshotPath(SnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, FSystemId.ToUpper, FIdentity, Transfer, FStorage);
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, FSystemId.ToUpper, FIdentity, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.FrameWidth, Console.FrameHeight, Console.FrameWidth, @Console.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        var Input: TEmulatorInput;
        var Paused, ResetRequested, Enabled: Boolean;
        var Volume: Single;
        try
          Input := FInput;
          Paused := FPause;
          ResetRequested := FReset;
          FReset := False;
          Enabled := FAudioEnabled;
          Volume := FVolume;
        finally
          FLock.Release;
        end;
        if ResetRequested then
        begin
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Hints.Pause;
          Deadline := TStopwatch.GetTimeStamp;
        end;

        if Paused then
        begin
          Hints.Pause;
          if Audio <> nil then
            Audio.Clear;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;

        Hints.BeginWork;
        if InputPorts.Devices[0] = 'none' then
          Console.SetInput([])
        else
          Console.SetInput(Input.Buttons);
        Console.RunFrame;
        Rate := Console.FramesPerSecond;
        if Terminated then
          Break;

        if Enabled and not AudioFailed then
        try
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          var Samples: TArray<SmallInt>;
          SetLength(Samples, Console.SampleFrames * 2);
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Console.Samples[I] * Volume);
          Audio.Submit(Samples, Console.SampleFrames);
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := 'NGP audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          if Audio <> nil then
            Audio.Clear;
          AudioFailed := False;
        end;

        Publish(Console);
        Hints.EndWork;
        Deadline := Deadline + TStopwatch.Frequency / Rate;
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        Hints.WaitUntil(FWake, Round(Deadline));
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'NGP: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    if Console <> nil then
    try
      Console.PowerOff;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'NGP power off: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (SystemSaveFile <> '') then
    try
      var Data := Console.SystemBackup;
      if Length(Data) > 0 then
      begin
        var Stream := TBytesStream.Create(Data);
        try
          SaveStreamAtomically(Stream, SystemSaveFile, FStorage);
        finally
          Stream.Free;
        end;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'NGP system save: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    if (Console <> nil) and (SaveFile <> '') and Console.BackupDirty then
    try
      var SaveStream := TBytesStream.Create(Console.Backup);
      try
        SaveStreamAtomically(SaveStream, SaveFile, FStorage);
      finally
        SaveStream.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'NGP save: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    Audio.Free;
    Console.Free;
    Hints.Free;
  end;
end;

end.

