unit SNES.Emulation;

interface

uses
  Core.Storage, Core.RomFormat, Core.Snapshots, System.SysUtils, System.Classes,
  System.SyncObjs, Core.InputConfig, Core.Emulation, SNES.Console;

const
  SNES_SAMPLE_RATE = 32000;
  AUDIO_BLOCK_SAMPLES = 2048;
  AUDIO_BLOCK_COUNT = 4;

type
  TSnesWorker = class(TThread)
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FData, FFirmware: TBytes;
    FSavePath: string;
    FStorage: IStorage;
    FInputs: TSnesPads;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError, FAudioError, FFinalSaveError: string;
    FPendingBattery: TBytes;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const SavePath: string; const Storage: IStorage = nil; const Firmware: TBytes = nil);
    destructor Destroy; override;
    procedure WakeSetEvent;
    procedure Configure(const Input: TSnesButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TSnesButtons = []);
    procedure ConfigurePads(const Inputs: TSnesPads; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
  public
    InputPorts: TCoreInputPorts; // Set before starting the worker.
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    procedure StopAndSave;
  end;

implementation

uses
  Core.PerformanceHints, System.IOUtils, System.UITypes, System.Diagnostics,
  System.Math, PCM.Audio;

{ TSnesWorker }

constructor TSnesWorker.Create(const Data: TBytes; const SavePath: string; const Storage: IStorage; const Firmware: TBytes);
begin
  inherited Create(True);
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FreeOnTerminate := False;
  FSnapshots := TSnapshotQueue.Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FData := Copy(Data);
  FFirmware := Copy(Firmware);
  FSavePath := SavePath;
end;

destructor TSnesWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited Destroy;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TSnesWorker.Configure(const Input: TSnesButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TSnesButtons);
begin
  var Inputs := Default(TSnesPads);
  Inputs[0] := Input;
  Inputs[1] := Input2;
  ConfigurePads(Inputs, Paused, AudioEnabled, Volume);
end;

procedure TSnesWorker.ConfigurePads(const Inputs: TSnesPads; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInputs := Inputs;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TSnesWorker.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TSnesWorker.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
end;

procedure TSnesWorker.RequestReset;
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

procedure TSnesWorker.SetError(const Value: string);
begin
  FLock.Acquire;
  try
    if FError = '' then
      FError := Value
    else
      FError := FError + SLineBreak + Value;
  finally
    FLock.Release;
  end;
end;

function TSnesWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TSnesWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSnesWorker.StopAndSave;
begin
  Terminate;
  WakeSetEvent;
  if Suspended then
    Start;
  WaitFor;
  // Preserve failed SRAM until an explicit retry succeeds. No worker can mutate it now.
  if Length(FPendingBattery) > 0 then
  try
    FStorage.WriteBytes(FSavePath, FPendingBattery);
    FPendingBattery := nil;
    FFinalSaveError := '';
  except
    on E: Exception do
      raise EInOutError.Create('SNES SRAM: ' + E.Message);
  end;
  if FFinalSaveError <> '' then
    raise EInOutError.Create('SNES SRAM: ' + FFinalSaveError);
end;

function TSnesWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

procedure TSnesWorker.WakeSetEvent;
begin
  FWake.SetEvent;
end;

procedure TSnesWorker.Execute;

  procedure SaveBattery(Console: TSnesConsole; var LastBattery: TBytes);
  begin
    if (Console = nil) or not Console.BatteryDirty then
      Exit;

    var Data := Console.BatteryData;
    if Length(Data) = 0 then
      Exit;

    var Unchanged := Length(Data) = Length(LastBattery);
    if Unchanged then
      for var i := 0 to High(Data) do
        if Data[i] <> LastBattery[i] then
        begin
          Unchanged := False;
          Break;
        end;
    if Unchanged then
      Exit;

    var Stream := TBytesStream.Create(Data);
    try
      FPendingBattery := Copy(Data);
      SaveStreamAtomically(Stream, FSavePath, FStorage);
      FPendingBattery := nil;
      LastBattery := Data;
    finally
      Stream.Free;
    end;
  end;

begin
  var Paused, ResetRequested, Enabled, WasPaused, WasEnabled: Boolean;
  var Volume: Single;
  var Frame: TEmulatorFrame;
  var SnapshotData := FData;
  if Length(FFirmware) > 0 then
    SnapshotData := FData + FFirmware;
  var Console: TSnesConsole := nil;
  var Audio: TPCMAudio := nil;
  var FrameHints: TEmulationPerformanceHints := nil;
  var LastBattery: TBytes;
  try
    try
      Console := TSnesConsole.Create(FData, ROM_EXTENSION_SFC, FFirmware);
      Console.ConfigureInputPorts(InputPorts);
      FrameHints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), 'SNES');
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var AudioFailed := False;
      var Format: TPCMAudioFormat;
      Format.SampleRate := SNES_SAMPLE_RATE;
      Format.Channels := 2;
      Format.BlockFrames := AUDIO_BLOCK_SAMPLES;
      Format.BlockCount := AUDIO_BLOCK_COUNT;
      var Deadline: Double := TStopwatch.GetTimeStamp;
      WasPaused := False;
      WasEnabled := False;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            FrameHints.Pause;
            var Path := TPath.Combine(FSnapshotDirectory, Name + '.snapshot');
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, 'SNES', SnapshotData, Transfer, FStorage);
              Console.MarkBatteryDirty;
              if Audio <> nil then
                Audio.Clear;
              Frame.Width := Console.Width;
              Frame.Height := Console.Height;
              Frame.FrameNumber := Console.FrameNumber;
              Frame.FramesPerSecond := Console.FramesPerSecond;
              Frame.Pixels := nil;
              SetLength(Frame.Pixels, Frame.Width * Frame.Height);
              for var Y := 0 to Frame.Height - 1 do
                for var X := 0 to Frame.Width - 1 do
                  Frame.Pixels[Y * Frame.Width + X] := Console.Pixels[Y * 512 + X];
              FLock.Acquire;
              try
                FFrame := Frame;
                FAvailable := True;
              finally
                FLock.Release;
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, 'SNES', SnapshotData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.Width, Console.Height, 512, @Console.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        var Inputs: TSnesPads;
        FLock.Acquire;
        try
          Inputs := FInputs;
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
          FrameHints.Pause;
          SaveBattery(Console, LastBattery);
          Console.Reset;
          if Audio <> nil then
            Audio.Clear;
          Deadline := TStopwatch.GetTimeStamp;
        end;
        if Paused then
        begin
          FrameHints.Pause;
          if not WasPaused then
          begin
            if Audio <> nil then
              Audio.Clear;
            SaveBattery(Console, LastBattery);
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;

        WasPaused := False;
        FrameHints.TargetDurationNanos := Round(1000000000.0 / Console.FramesPerSecond);
        FrameHints.BeginWork;
        Console.SetInputs(Inputs);
        Console.RunFrame;
        if Terminated then
          Break;

        Frame.Width := Console.Width;
        Frame.Height := Console.Height;
        Frame.FrameNumber := Console.FrameNumber;
        Frame.FramesPerSecond := Console.FramesPerSecond;
        // Allocate a new publication buffer: previously delivered frames remain immutable.
        Frame.Pixels := nil;
        SetLength(Frame.Pixels, Frame.Width * Frame.Height);
        for var Y := 0 to Frame.Height - 1 do
          Move(Console.Pixels[Y * 512], Frame.Pixels[Y * Frame.Width],
            Frame.Width * SizeOf(Frame.Pixels[0]));
        FLock.Acquire;
        try
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
            Audio := TPCMAudio.Create(Format);
          var Samples: TArray<SmallInt>;
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
              FAudioError := 'SNES audio: ' + E.Message;
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
          AudioFailed := False; // A later explicit audio enable may retry the device.
        end;
        FrameHints.EndWork;
        WasEnabled := Enabled;
        if Console.FrameNumber mod 120 = 0 then
          SaveBattery(Console, LastBattery);
        Deadline := Deadline + TStopwatch.Frequency / Console.FramesPerSecond;
        if TStopwatch.GetTimeStamp - Deadline > TStopwatch.Frequency div 10 then
          Deadline := TStopwatch.GetTimeStamp;
        FrameHints.WaitUntil(FWake, Round(Deadline));
      end;
    except
      on E: Exception do
        SetError('SNES: ' + E.Message);
    end;
  finally
    FrameHints.Free;
    try
      SaveBattery(Console, LastBattery);
    except
      on E: Exception do
        FFinalSaveError := E.Message; // StopAndSave reports this and retains pending data.
    end;
    Audio.Free;
    Console.Free;
  end;
end;

end.

