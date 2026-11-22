unit A5200.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, A5200.Console,
  A5200.Controller;

type
  TAtariMachineFactory = reference to function: TAtariFrameMachine;

  TA5200Worker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FCartridge, FCompatibleSnapshotHash: TBytes;
    FCoreId: string;
    FMachineFactory: TAtariMachineFactory;
    FKeyboard: Word;
    FDiskReadMuted: Boolean;
    FKeypads: TA5200Keypads;
    FInput: TEmulatorInput;
    FControlButtons: TEmulatorButtons;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
    procedure Publish(Console: TAtariFrameMachine);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
    constructor Create(const Cartridge: TBytes; Mapper: Integer; const Storage: IStorage); overload;
    constructor Create(const Media: TBytes; const CoreId: string; const Factory: TAtariMachineFactory; const Buttons: TEmulatorButtons; const Storage: IStorage; const CompatibleSnapshotHash: TBytes = nil); overload;
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; const Keypads: TA5200Keypads; Keyboard: Word = $FF; DiskReadMuted: Boolean = False);
    procedure RequestReset;
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
  PCM.Audio, A5200.Firmware;

function TA5200Worker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TA5200Worker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TA5200Worker.Create(const Cartridge: TBytes; Mapper: Integer; const Storage: IStorage);
begin
  Create(Cartridge, 'A5200',
    function: TAtariFrameMachine
    begin
      Result := TA5200Console.Create(FCartridge, LoadBuiltinAtari5200BIOS, Mapper);
    end,
        [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
          TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Start,
          TEmulatorButton.Select], Storage);
end;

constructor TA5200Worker.Create(const Media: TBytes; const CoreId: string; const Factory: TAtariMachineFactory; const Buttons: TEmulatorButtons; const Storage: IStorage; const CompatibleSnapshotHash: TBytes);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FCartridge := Copy(Media);
  FCompatibleSnapshotHash := Copy(CompatibleSnapshotHash);
  FCoreId := CoreId;
  FMachineFactory := Factory;
  FKeyboard := $FF;
  FControlButtons := Buttons;
  FStorage := Storage;
end;

destructor TA5200Worker.Destroy;
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

procedure TA5200Worker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; const Keypads: TA5200Keypads; Keyboard: Word; DiskReadMuted: Boolean);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FKeypads := Keypads;
    FKeyboard := Keyboard;
    FDiskReadMuted := DiskReadMuted;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TA5200Worker.RequestReset;
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

procedure TA5200Worker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TA5200Worker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TA5200Worker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TA5200Worker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TA5200Worker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TA5200Worker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function TA5200Worker.SupportedButtons: TEmulatorButtons;
begin
  FLock.Acquire;
  try
    Result := FControlButtons;
  finally
    FLock.Release;
  end;
end;

procedure TA5200Worker.Publish(Console: TAtariFrameMachine);
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

procedure TA5200Worker.Execute;
var
  Console: TAtariFrameMachine;
  Keyboard: Word;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed, DiskReadMuted: Boolean;
  Volume: Single;
  Keypads: TA5200Keypads;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := FCoreId;
  try
    try
      Console := FMachineFactory();
      Console.SetInputPorts(InputPorts);
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
        FInputPortsCommand.Process(
          procedure(const Ports: TCoreInputPorts)
          begin
            Console.SetInputPorts(Ports);
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
              LoadCoreSnapshot(Path, CoreId, FCartridge, Transfer, FStorage, FCompatibleSnapshotHash);
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, FCartridge, Transfer, FStorage);
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
          Keyboard := FKeyboard;
          DiskReadMuted := FDiskReadMuted;
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
        for var Port := 0 to 3 do
        begin
          if InputPorts.Devices[Port] = 'none' then
          begin
            Keypads[Port] := 0;
            Input.Analog[Port] := Default(TEmulatorAnalogPad);
            Input.AnalogButtons[Port] := Default(TEmulatorAnalogButtons);
            Input.RelativeButtons[Port] := [];
          end;
          Console.SetKeypad(Port, Keypads[Port]);
        end;
        Console.SetInput(Input);
        Console.SetKeyboard(Keyboard);
        Console.SetDiskReadMuted(DiskReadMuted);
        Console.RunFrame;

        if Terminated then
          Break;

        Publish(Console);
        if Console.Frame.FrameNumber mod 60 = 0 then
          Console.FlushMedia;
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
      Console.FlushMedia;
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

