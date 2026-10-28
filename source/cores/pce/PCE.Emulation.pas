unit PCE.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, PCE.Console,
  PCE.Cartridge, Core.CD.Disc;

type
  TPCEWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FCartridge: TPCECartridge;
    FModel: TPCEModel;
    FDisc: TCDDisc;
    FOptions: TPCEOptions;
    FInput: TEmulatorInput;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TPCEConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, SaveFile: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    IdentityData: TBytes;
    constructor Create(Cartridge: TPCECartridge; Model: TPCEModel; Disc: TCDDisc; const Storage: IStorage);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure ConfigureOptions(const Options: TPCEOptions);
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

function TPCEWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TPCEWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TPCEWorker.Create(Cartridge: TPCECartridge; Model: TPCEModel; Disc: TCDDisc; const Storage: IStorage);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FCartridge := Cartridge;
  FModel := Model;
  FDisc := Disc;
  FOptions := TPCEOptions.Defaults;
  FStorage := Storage;
end;

destructor TPCEWorker.Destroy;
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

procedure TPCEWorker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single);
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

procedure TPCEWorker.ConfigureOptions(const Options: TPCEOptions);
begin
  FLock.Acquire;
  try
    FOptions := Options;
  finally
    FLock.Release;
  end;
end;

procedure TPCEWorker.RequestReset;
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

procedure TPCEWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TPCEWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TPCEWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TPCEWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TPCEWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TPCEWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TPCEWorker.Publish(Console: TPCEConsole);
begin
  var Frame := Console.Frame;
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TPCEWorker.Execute;
var
  Console: TPCEConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Options: TPCEOptions;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'PCE';
  if PCESuperGrafx(FModel) then
    CoreId := 'SGX';
  if PCEHasCD(FModel) then
    CoreId := 'PCECD';
  try
    try
      var SavedData: TBytes := nil;
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
        SavedData := FStorage.ReadBytes(SaveFile);
      Console := TPCEConsole.Create(FCartridge, FModel, FDisc, SavedData);
      Console.InputPorts := InputPorts;
      Hints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.Frame.FramesPerSecond), CoreId);
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
            Console.ConfigureInputPorts(Ports);
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
              LoadCoreSnapshot(Path, CoreId, IdentityData, Transfer, FStorage);
              Console.ConfigureInputPorts(InputPorts);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, IdentityData, Transfer, FStorage);
              var Frame := Console.Frame;
              SaveSnapshotPreview(Path, Frame.Width, Frame.Height, Frame.Width, @Frame.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Input := FInput;
          Options := FOptions;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
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
        Options.Multitap := InputPorts.Multitap[0];
        Console.Options := Options;
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
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Console.Samples[I] * Volume);
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
        Deadline := Deadline + TStopwatch.Frequency / Console.Frame.FramesPerSecond;
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
    if (Console <> nil) and (SaveFile <> '') then
    try
      var Saved := Console.SavePersistent;
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
      begin
        FLock.Acquire;
        try
          FError := 'PCE save: ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
    Hints.Free;
    Audio.Free;
    Console.Free;
  end;
end;

end.

