unit Jaguar.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, Jaguar.Console,
  Jaguar.Jerry, Core.CD.Disc;

type
  TJaguarWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots, FMediaChanges: TSnapshotQueue;
    FDisc, FNextDisc: TCDDisc;
    FCDHardware: Boolean;
    FStorage: IStorage;
    FCartridge: TBytes;
    FPAL, FUseBIOS: Boolean;
    FKeypads: TJaguarKeypads;
    FInput: TEmulatorInput;
    FControlButtons: TEmulatorButtons;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
    procedure Publish(Console: TJaguarConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, BatteryPath: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
    constructor Create(const Cartridge: TBytes; const Storage: IStorage; PAL, UseBIOS: Boolean; Disc: TCDDisc = nil; CDHardware: Boolean = False);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; const Keypads: TJaguarKeypads);
    procedure RequestReset;
    procedure ChangeDisc(Disc: TCDDisc);
    procedure Stop;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function SupportedButtons: TEmulatorButtons;
  end;

implementation

uses
  System.Diagnostics, System.Math, Core.SavePaths, Core.PerformanceHints,
  PCM.Audio, Jaguar.Firmware, System.Hash;

function TJaguarWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TJaguarWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TJaguarWorker.Create(const Cartridge: TBytes; const Storage: IStorage; PAL, UseBIOS: Boolean; Disc: TCDDisc; CDHardware: Boolean);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FMediaChanges := TSnapshotQueue.Create(False);
  FDisc := Disc;
  FCDHardware := CDHardware or (Disc <> nil);
  FCartridge := Copy(Cartridge);
  FPAL := PAL;
  FUseBIOS := UseBIOS;
  FControlButtons := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z];
  FStorage := Storage;
end;

destructor TJaguarWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;

  // Join before freeing synchronization objects used by Execute.
  inherited;
  FInputPortsCommand.Free;
  FMediaChanges.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TJaguarWorker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; const Keypads: TJaguarKeypads);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FKeypads := Keypads;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TJaguarWorker.ChangeDisc(Disc: TCDDisc);
begin
  FNextDisc := Disc;
  FWake.SetEvent;
  FMediaChanges.Execute(Self, '', False);
end;

procedure TJaguarWorker.RequestReset;
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

procedure TJaguarWorker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TJaguarWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TJaguarWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TJaguarWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TJaguarWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TJaguarWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function TJaguarWorker.SupportedButtons: TEmulatorButtons;
begin
  FLock.Acquire;
  try
    Result := FControlButtons;
  finally
    FLock.Release;
  end;
end;

procedure TJaguarWorker.Publish(Console: TJaguarConsole);
begin
  var Frame := Console.Frame;
  Frame.Pixels := Copy(Frame.Pixels);
  var Buttons: TEmulatorButtons := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z];
  FLock.Acquire;
  try
    FFrame := Frame;
    FControlButtons := Buttons;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TJaguarWorker.Execute;
var
  Console: TJaguarConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Keypads: TJaguarKeypads;
  Deadline: Double;
  CoreId: string;
  Identity: TBytes;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'JAGUAR';
  try
    try
      Console := TJaguarConsole.Create(FCartridge, LoadJaguarBIOS, FPAL, FUseBIOS, FDisc, FCDHardware);
      var Hash := THashSHA2.Create;
      Hash.Update(FCartridge);
      Identity := Hash.HashAsBytes;
      if FDisc <> nil then
        Identity := FDisc.Identity;
      if (BatteryPath <> '') and FStorage.Exists(BatteryPath) then
        Console.LoadBattery(FStorage.ReadBytes(BatteryPath));
      Publish(Console); // Also expose the keymap when starting paused.
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.Rate), CoreId);
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
        FInputPortsCommand.Process(Console.ConfigurePorts);
        FMediaChanges.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            Console.InsertDisc(FNextDisc);
            FDisc := FNextDisc;
            if FDisc <> nil then
              Identity := FDisc.Identity
            else
            begin
              SetLength(Identity, 32);
              FillChar(Identity[0], 32, 0);
            end;
            if Audio <> nil then
              Audio.Clear;
            Deadline := TStopwatch.GetTimeStamp;
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
              LoadCoreSnapshotHash(Path, CoreId, Identity, Transfer, FStorage);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshotHash(Path, CoreId, Identity, Transfer, FStorage);
              var Frame := Console.Frame;
              SaveSnapshotPreview(Path, Frame.Width, Frame.Height, Frame.Width, @Frame.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Input := FInput;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          Keypads := FKeypads;
          ResetRequested := FReset;
          FReset := False;
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
        Hints.BeginWork;
        if InputPorts.Devices[0] = 'none' then
          Input.Buttons := [];
        if InputPorts.Devices[1] = 'none' then
          Input.Buttons2 := [];
        if InputPorts.Devices[2] = 'none' then
          Input.Buttons3 := [];
        if InputPorts.Devices[3] = 'none' then
          Input.Buttons4 := [];
        for var Port := 0 to 7 do
        begin
          if InputPorts.Devices[Port] = 'none' then
          begin
            Keypads[Port] := 0;
            Input.Analog[Port] := Default(TEmulatorAnalogPad);
          end;
          Console.SetKeypad(Port, Keypads[Port]);
        end;
        Console.SetInput(Input);
        Console.RunFrame;

        if Terminated then
          Break;

        Publish(Console);
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          SetLength(Samples, (Length(Console.Samples) div 2) * 2);
          for var i := 0 to High(Samples) do
            Samples[i] := Round(Console.Samples[i] * Volume);
          Audio.Submit(Samples, (Length(Console.Samples) div 2));

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
        Deadline := Deadline + TStopwatch.Frequency / Console.Rate;
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
    if (Console <> nil) and (BatteryPath <> '') then
    try
      var Memory := TBytesStream.Create(Console.Battery);
      try
        FStorage.WriteAtomic(BatteryPath, Memory);
      finally
        Memory.Free;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := 'Jaguar EEPROM: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    Console.Free;
  end;
end;

end.

