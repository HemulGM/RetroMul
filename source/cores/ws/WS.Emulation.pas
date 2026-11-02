unit WS.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, WS.Console,
  WS.Cartridge;

type
  TWSWorker = class(TThread)
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
    FOrientation, FPalette: Integer;
    FHeadphones: Boolean;
    FInput: TEmulatorInput;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TWSConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, SaveFile, SystemSaveFile: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const ROM, BIOS, Identity: TBytes; const Storage: IStorage; Color: Boolean; const SystemId: string);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; Orientation, Palette: Integer; Headphones: Boolean);
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

function TWSWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TWSWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TWSWorker.Create(const ROM, BIOS, Identity: TBytes; const Storage: IStorage; Color: Boolean; const SystemId: string);
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

destructor TWSWorker.Destroy;
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

procedure TWSWorker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; Orientation, Palette: Integer; Headphones: Boolean);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FOrientation := Orientation;
    FPalette := Palette;
    FHeadphones := Headphones;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TWSWorker.RequestReset;
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

procedure TWSWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TWSWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TWSWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TWSWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TWSWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TWSWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TWSWorker.Publish(Console: TWSConsole);
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

procedure TWSWorker.Execute;
var
  Console: TWSConsole;
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
      Console := TWSConsole.Create(FCartridgeROM, FBIOS, FColor);
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
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Rate), 'WS');
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
        var Orientation, Palette: Integer;
        var Headphones: Boolean;
        try
          Input := FInput;
          Paused := FPause;
          ResetRequested := FReset;
          FReset := False;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          Orientation := FOrientation;
          Palette := FPalette;
          Headphones := FHeadphones;
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
        Console.Configure(Orientation, Palette, Headphones);
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
              FAudioError := 'WS audio: ' + E.Message;
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
          FError := 'WS: ' + E.Message;
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
          FError := 'WS power off: ' + E.Message;
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
          FError := 'WS system save: ' + E.Message;
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
          FError := 'WS save: ' + E.Message;
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

