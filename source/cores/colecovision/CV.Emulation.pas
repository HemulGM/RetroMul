unit CV.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, CV.Console;

type
  TCVWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FData, FBios: TBytes;
    FPAL: Boolean;
    FInput: TEmulatorInput;
    FKeys: TCVHostKeys;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FMouseDX, FMouseDY: Integer;
    FMouseButtons: Byte;
    FVolume: Single;
    FOptions: TCVOptions;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TCVConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory, SaveFile: string;
    MapperHint, VideoHint: Integer;
    procedure ConfigureOptions(const Value: TCVOptions);
    property Options: TCVOptions read FOptions write ConfigureOptions;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const Data, BIOS: TBytes; PAL: Boolean; const Storage: IStorage);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; const Keys: TCVHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
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

function TCVWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TCVWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TCVWorker.Create(const Data, BIOS: TBytes; PAL: Boolean; const Storage: IStorage);
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
  FBios := Copy(BIOS);
  Options := TCVOptions.Defaults;
  MapperHint := -1;
  VideoHint := -1;
end;

destructor TCVWorker.Destroy;
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

procedure TCVWorker.Configure(const Input: TEmulatorInput; const Keys: TCVHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
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

procedure TCVWorker.ConfigureOptions(const Value: TCVOptions);
begin
  FLock.Acquire;
  try
    FOptions := Value;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TCVWorker.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  FLock.Acquire;
  try
    FMouseDX := EnsureRange(Int64(FMouseDX) + DX, -4096, 4096);
    FMouseDY := EnsureRange(Int64(FMouseDY) + DY, -4096, 4096);
    FMouseButtons := Buttons;
  finally
    FLock.Release;
  end;
end;

procedure TCVWorker.RequestReset;
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

procedure TCVWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TCVWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TCVWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TCVWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TCVWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TCVWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TCVWorker.Publish(Console: TCVConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := Console.ScreenWidth;
  Frame.Height := Console.VDP.ScreenHeight;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  Frame.Pixels := Copy(Console.VDP.Pixels);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TCVWorker.Execute;
var
  Console: TCVConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keys: TCVHostKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  CoreId := 'COLECO';
  try
    try
      Console := TCVConsole.Create(FData, FBios, FPAL, MapperHint, VideoHint);
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
        Console.Cartridge.LoadRAM(FStorage.ReadBytes(SaveFile));
      Console.ApplyOptions(Options);
      Console.ConfigureControllers(InputPorts.Devices[0], InputPorts.Devices[1]);
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
            Console.ConfigureControllers(Ports.Devices[0], Ports.Devices[1]);
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
              FLock.Acquire;
              try
                Console.ApplyOptions(FOptions);
              finally
                FLock.Release;
              end;
              if Audio <> nil then
                Audio.Clear;
              Publish(Console);
            end
            else
            begin
              SaveCoreSnapshot(Path, CoreId, FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.ScreenWidth, Console.VDP.ScreenHeight, Console.ScreenWidth, @Console.VDP.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Console.ApplyOptions(FOptions);
          Console.SendMouseDelta(FMouseDX, FMouseDY, FMouseButtons);
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
        begin
          Input.Buttons := [];
          for var I := $30 to $39 do
            Keys[I] := False;
          Keys[$51] := False;
          Keys[$57] := False;
        end;
        if InputPorts.Devices[1] = 'none' then
        begin
          Input.Buttons2 := [];
          for var I := $60 to $69 do
            Keys[I] := False;
          Keys[$45] := False;
          Keys[$52] := False;
        end;
        Hints.BeginWork;
        Console.SetInput(Input, Keys);
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
    if (Console <> nil) and (SaveFile <> '') then
    try
      var Data := Console.Cartridge.SaveRAM;
      if Length(Data) > 0 then
      begin
        var Stream := TBytesStream.Create(Data);
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

