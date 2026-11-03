unit A2600.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, A2600.Console;

type
  TA2600Worker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FCartridge: TBytes;
    FPAL: Boolean;
    FMapper: string;
    FInput: TEmulatorInput;
    FControlButtons: TEmulatorButtons;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FSwitches: Byte;
    FMouseDX, FMouseDY: Integer;
    FMouseButtons: Byte;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
    procedure Publish(Console: TA2600Console);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory: string;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
    constructor Create(const Cartridge: TBytes; PAL: Boolean; const Mapper: string; const Storage: IStorage);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; Switches: Byte);
    procedure RequestReset;
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure ClearMouseInput;
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
  PCM.Audio;

function TA2600Worker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TA2600Worker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TA2600Worker.Create(const Cartridge: TBytes; PAL: Boolean; const Mapper: string; const Storage: IStorage);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FCartridge := Copy(Cartridge);
  FPAL := PAL;
  FMapper := Mapper;
  FControlButtons := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.Start, TEmulatorButton.Select];
  FStorage := Storage;
end;

destructor TA2600Worker.Destroy;
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

procedure TA2600Worker.Configure(const Input: TEmulatorInput; Paused, AudioEnabled: Boolean; Volume: Single; Switches: Byte);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInput := Input;
    FSwitches := Switches;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TA2600Worker.RequestReset;
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

procedure TA2600Worker.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FLock.Acquire;
  try
    FMouseDX := EnsureRange(Int64(FMouseDX) + DX, -1000000, 1000000);
    FMouseDY := EnsureRange(Int64(FMouseDY) + DY, -1000000, 1000000);
    FMouseButtons := Buttons;
  finally
    FLock.Release;
  end;
end;

procedure TA2600Worker.ClearMouseInput;
begin
  FLock.Acquire;
  try
    FMouseDX := 0;
    FMouseDY := 0;
    FMouseButtons := 0;
  finally
    FLock.Release;
  end;
end;

procedure TA2600Worker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TA2600Worker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TA2600Worker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TA2600Worker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TA2600Worker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TA2600Worker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function TA2600Worker.SupportedButtons: TEmulatorButtons;
begin
  FLock.Acquire;
  try
    Result := FControlButtons;
  finally
    FLock.Release;
  end;
end;

procedure TA2600Worker.Publish(Console: TA2600Console);
begin
  var Frame := Console.Frame;
  var Buttons := Console.SupportedButtons;
  FLock.Acquire;
  try
    FFrame := Frame;
    FControlButtons := Buttons;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TA2600Worker.Execute;
var
  Console: TA2600Console;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Switches: Byte;
  MouseDX, MouseDY: Integer;
  MouseButtons: Byte;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'A2600';
  try
    try
      Console := TA2600Console.Create(FCartridge, FPAL, FMapper);
      Console.ConfigureInputPorts(GetInputPorts);
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
            Console.ConfigureInputPorts(Ports);
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
              LoadCoreSnapshot(Path, CoreId, FCartridge, Transfer, FStorage);
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
          Switches := FSwitches;
          MouseDX := FMouseDX;
          MouseDY := FMouseDY;
          MouseButtons := FMouseButtons;
          FMouseDX := 0;
          FMouseDY := 0;
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
        begin
          Input.Buttons := [];
          Input.Analog[0] := Default(TEmulatorAnalogPad);
        end;
        if InputPorts.Devices[1] = 'none' then
        begin
          Input.Buttons2 := [];
          Input.Analog[1] := Default(TEmulatorAnalogPad);
        end;
        Console.ConsoleSwitches := Switches;
        Console.SetInput(Input);
        Console.ApplyMouse(MouseDX, MouseDY, MouseButtons);
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
    Console.Free;
  end;
end;

end.

