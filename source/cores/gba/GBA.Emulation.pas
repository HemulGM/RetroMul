unit GBA.Emulation;

interface

uses
  Core.InputConfig, Core.Storage, Core.Snapshots, System.SysUtils,
  System.Classes, System.SyncObjs, Core.Emulation.Types, Core.Emulation.Timing,
  GBA.Console;

const
  GBA_SAMPLE_RATE = 44100;
  AUDIO_BLOCK_SAMPLES = 2048;
  AUDIO_BLOCK_COUNT = 4;

type
  TGBAWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FData, FBIOS: TBytes;
    FSavePath: string;
    FStorage: IStorage;
    FInput: TEmulatorButtons;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError, FAudioError, FFinalSaveError: string;
    FPendingBattery, FPendingRTC: TBytes;
    FSaveOverride, FSolarLevel: Integer;
    FMotionX, FMotionY, FRotation: Double;
    FRumbleLevel: Byte;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const Data: TBytes; const SavePath: string; const Storage: IStorage = nil; const BIOS: TBytes = nil; SaveOverride: Integer = -1; SolarLevel: Integer = 128);
    destructor Destroy; override;
    procedure WakeSetEvent;
    procedure SetSolarLevel(Value: Integer);
    procedure SetMotion(X, Y, Rotation: Double);
    function GetRumbleLevel: Byte;
    procedure Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
  public
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    procedure StopAndSave;
  end;

implementation

uses
  GBA.Cartridge, Core.SavePaths, Core.PerformanceHints, System.IOUtils,
  System.UITypes, System.Diagnostics, System.Math, PCM.Audio;

{ TGBAWorker }

function TGBAWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TGBAWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TGBAWorker.Create(const Data: TBytes; const SavePath: string; const Storage: IStorage; const BIOS: TBytes; SaveOverride, SolarLevel: Integer);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FreeOnTerminate := False;
  FSnapshots := TSnapshotQueue.Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FData := Copy(Data);
  FBIOS := Copy(BIOS);
  FSavePath := SavePath;
  FSaveOverride := SaveOverride;
  FSolarLevel := SolarLevel;
end;

destructor TGBAWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited Destroy;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TGBAWorker.SetSolarLevel(Value: Integer);
begin
  FLock.Acquire;
  try
    FSolarLevel := EnsureRange(Value, 0, 255);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TGBAWorker.SetMotion(X, Y, Rotation: Double);
begin
  FLock.Acquire;
  try
    FMotionX := X;
    FMotionY := Y;
    FRotation := Rotation;
  finally
    FLock.Release;
  end;
end;

function TGBAWorker.GetRumbleLevel: Byte;
begin
  FLock.Acquire;
  try
    Result := FRumbleLevel;
    if FPause or Terminated then
      Result := 0;
  finally
    FLock.Release;
  end;
end;

procedure TGBAWorker.Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TGBAWorker.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TGBAWorker.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
end;

procedure TGBAWorker.RequestReset;
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

procedure TGBAWorker.SetError(const Value: string);
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

function TGBAWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TGBAWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TGBAWorker.StopAndSave;
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
      raise EInOutError.Create('Game Boy Advance SRAM: ' + E.Message);
  end;

  if Length(FPendingRTC) > 0 then
  begin
    FStorage.WriteBytes(FSavePath + '.rtc', FPendingRTC);
    FPendingRTC := nil;
    FFinalSaveError := '';
  end;

  if FFinalSaveError <> '' then
    raise EInOutError.Create('Game Boy Advance SRAM: ' + FFinalSaveError);
end;

function TGBAWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

procedure TGBAWorker.WakeSetEvent;
begin
  FWake.SetEvent;
end;

procedure TGBAWorker.Execute;

  procedure SaveBattery(Console: TGBAConsole; var LastBattery: TBytes);
  begin
    if Console = nil then
      Exit;

    // Retain both payloads before either storage write can fail.
    if Console.BatteryDirty then
      FPendingBattery := Console.BatteryData;
    if Console.Cartridge.Hardware.HasRTC then
    begin
      var RTC := Console.Cartridge.Hardware.RTCBattery;
      FPendingRTC := Copy(RTC);
      var RTCStream := TBytesStream.Create(RTC);
      try
        SaveStreamAtomically(RTCStream, FSavePath + '.rtc', FStorage);
        FPendingRTC := nil;
      finally
        RTCStream.Free;
      end;
    end;
    if not Console.BatteryDirty then
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
    begin
      FPendingBattery := nil;
      Exit;
    end;

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
  var MotionX, MotionY, Rotation: Double;
  var Frame: TEmulatorFrame;
  var Samples: TArray<SmallInt>;
  var Deadline: Double;
  var LastBattery: TBytes;
  var AudioFailed := False;
  var Console: TGBAConsole := nil;
  var Audio: TPCMAudio := nil;
  var FrameHints: TEmulationPerformanceHints := nil;
  var Rate := Default(TEmulationFrameRate);
  try
    try
      Console := TGBAConsole.Create(FData, FBIOS);
      if (FSaveOverride >= 0) and (FSaveOverride <= Ord(High(TGBASaveKind))) then
        Console.Cartridge.OverrideSaveKind(TGBASaveKind(FSaveOverride));
      Console.Cartridge.Hardware.SetSolar(FSolarLevel);
      if Console.Cartridge.Hardware.HasRTC and FStorage.Exists(FSavePath + '.rtc') then
        Console.Cartridge.Hardware.LoadRTCBattery(FStorage.ReadBytes(FSavePath + '.rtc'));
      Console.ConfigureInputPorts(InputPorts);
      FrameHints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), ROM_CORE_ID_GBA);
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := GBA_SAMPLE_RATE;
      Format.Channels := 2;
      Format.BlockFrames := AUDIO_BLOCK_SAMPLES;
      Format.BlockCount := AUDIO_BLOCK_COUNT;
      Deadline := TStopwatch.GetTimeStamp;
      Rate.Reset(Console.FrameNumber, Round(Deadline));
      WasPaused := False;
      WasEnabled := False;
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
            FrameHints.Pause;
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, ROM_CORE_ID_GBA, FData, Transfer, FStorage);
              Console.ConfigureInputPorts(InputPorts);
              Console.MarkBatteryDirty;
              if Audio <> nil then
                Audio.Clear;
              Frame.Width := Console.Width;
              Frame.Height := Console.Height;
              Frame.FrameNumber := Console.FrameNumber;
              Frame.FramesPerSecond := 0;
              Frame.Pixels := nil;
              SetLength(Frame.Pixels, Frame.Width * Frame.Height);
              for var Y := 0 to Frame.Height - 1 do
                for var X := 0 to Frame.Width - 1 do
                  Frame.Pixels[Y * Frame.Width + X] := Console.Pixels[Y * 240 + X];
              FLock.Acquire;
              try
                FRumbleLevel := Console.Cartridge.Hardware.TakeRumbleLevel;
                FFrame := Frame;
                FAvailable := True;
              finally
                FLock.Release;
              end;
            end
            else
            begin
              SaveCoreSnapshot(Path, ROM_CORE_ID_GBA, FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.Width, Console.Height, 240, @Console.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
            Rate.Reset(Console.FrameNumber, Round(Deadline));
          end);
        var Input: TEmulatorButtons;
        FLock.Acquire;
        try
          Console.Cartridge.Hardware.SetSolar(FSolarLevel);
          Input := FInput;
          MotionX := FMotionX;
          MotionY := FMotionY;
          Rotation := FRotation;
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
          Rate.Reset(Console.FrameNumber, Round(Deadline));
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
          Rate.Reset(Console.FrameNumber, Round(Deadline));
          Continue;
        end;

        WasPaused := False;
        FrameHints.TargetDurationNanos := Round(1000000000.0 / Console.FramesPerSecond);
        FrameHints.BeginWork;
        Console.SetInput(Input);
        var AppliedRotation := Rotation;
        if Console.Cartridge.Hardware.HasGyro then
          AppliedRotation := AppliedRotation + Ord(TEmulatorButton.Z in Input) - Ord(TEmulatorButton.C in Input);
        Console.Cartridge.Hardware.SetMotion(MotionX, MotionY, AppliedRotation);
        Console.RunFrame;

        if Terminated then
          Break;

        Frame.Width := Console.Width;
        Frame.Height := Console.Height;
        Frame.FrameNumber := Console.FrameNumber;
        Frame.FramesPerSecond := Rate.Update(Console.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);

        // Allocate a new publication buffer: previously delivered frames remain immutable.
        Frame.Pixels := nil;
        SetLength(Frame.Pixels, Frame.Width * Frame.Height);
        for var Y := 0 to Frame.Height - 1 do
          Move(Console.Pixels[Y * 240], Frame.Pixels[Y * Frame.Width],
            Frame.Width * SizeOf(Frame.Pixels[0]));
        FLock.Acquire;
        try
          FRumbleLevel := Console.Cartridge.Hardware.TakeRumbleLevel;
          FFrame := Frame;
          FAvailable := True;
        finally
          FLock.Release;
        end;
        if Enabled and not AudioFailed then
        try
          if Console.SampleFrames = 0 then
          begin
            if Audio <> nil then
              Audio.Clear;
          end
          else
          begin
            if Audio = nil then
              Audio := TPCMAudio.Create(Format);
            SetLength(Samples, Console.SampleFrames * 2);
            for var i := 0 to High(Samples) do
              Samples[i] := Round(Console.Samples[i] * Volume);
            Audio.Submit(Samples, Console.SampleFrames);
            if Audio.Error <> '' then
              raise EInOutError.Create(Audio.Error);
          end;
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := 'Game Boy Advance audio: ' + E.Message;
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
        SetError('Game Boy Advance: ' + E.Message);
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

