unit SG1000.Emulation;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, Core.Storage,
  Core.Emulation.Types, Core.InputConfig, Core.Snapshots, SG1000.Console;

type
  TSGWorker = class(TThread)
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
    FModel: TSGModel;
    FWarmBoot: Boolean;
    FSC3000, FPAL: Boolean;
    FInput: TEmulatorInput;
    FKeys: TSGHostKeys;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FOptions: TSGOptions;
    FFrame: TEmulatorFrame;
    FError, FAudioError: string;
    procedure Publish(Console: TSGConsole);
  protected
    procedure Execute; override;
  public
    SnapshotDirectory: string;
    SaveFile: string;
    MapperHint: Integer;
    TapeFile: string;
    TapeAutoPlay: Boolean;
    procedure ConfigureOptions(const Value: TSGOptions);
    property Options: TSGOptions read FOptions write ConfigureOptions;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    constructor Create(const Data: TBytes; SC3000, PAL: Boolean; const Storage: IStorage; Model: Integer = -1; const BIOS: TBytes = nil; WarmBoot: Boolean = True);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; const Keys: TSGHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
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
  SG1000.Cartridge, System.Diagnostics, System.Math, Core.SavePaths,
  Core.PerformanceHints, PCM.Audio;

function TSGWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TSGWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TSGWorker.Create(const Data: TBytes; SC3000, PAL: Boolean; const Storage: IStorage; Model: Integer; const BIOS: TBytes; WarmBoot: Boolean);
begin
  inherited Create(True);
  FInputPortsCommand := TInputPortsCommand.Create;
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FData := Copy(Data);
  FStorage := Storage;
  FSC3000 := SC3000;
  FPAL := PAL;
  if SC3000 then
    FModel := TSGModel.SC3000
  else
    FModel := TSGModel.SG1000;
  if (Model >= 0) and (Model <= Ord(High(TSGModel))) then
    FModel := TSGModel(Model);
  FBios := Copy(BIOS);
  FWarmBoot := WarmBoot;
  Options := TSGOptions.Defaults;
  MapperHint := -1;
end;

destructor TSGWorker.Destroy;
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

procedure TSGWorker.Configure(const Input: TEmulatorInput; const Keys: TSGHostKeys; Paused, AudioEnabled: Boolean; Volume: Single);
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

procedure TSGWorker.ConfigureOptions(const Value: TSGOptions);
begin
  FLock.Acquire;
  try
    FOptions := Value;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TSGWorker.RequestReset;
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

procedure TSGWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

procedure TSGWorker.SaveSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, False);
end;

procedure TSGWorker.LoadSnapshot(const Name: string);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, True);
end;

function TSGWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TSGWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TSGWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSGWorker.Publish(Console: TSGConsole);
begin
  var Frame: TEmulatorFrame;
  Frame.Width := 256;
  Frame.Height := Console.VDP.ScreenHeight;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := Console.FramesPerSecond;
  if Console.Model = TSGModel.GameGear then
  begin
    Frame.Width := 160;
    Frame.Height := 144;
    SetLength(Frame.Pixels, 160 * 144);
    var Top := (Console.VDP.ScreenHeight - 144) div 2;
    for var Y := 0 to 143 do
      Move(Console.VDP.Pixels[(Y + Top) * 256 + 48], Frame.Pixels[Y * 160], 160 * SizeOf(Cardinal));
  end
  else
    Frame.Pixels := Copy(Console.VDP.Pixels);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

procedure TSGWorker.Execute;
var
  Console: TSGConsole;
  Audio: TPCMAudio;
  Hints: TEmulationPerformanceHints;
  Input: TEmulatorInput;
  Keys: TSGHostKeys;
  Samples: TArray<SmallInt>;
  Paused, ResetRequested, Enabled, WasEnabled, WasPaused, AudioFailed: Boolean;
  Volume: Single;
  Deadline: Double;
  CoreId: string;
begin
  Console := nil;
  Audio := nil;
  Hints := nil;
  case FModel of
    TSGModel.SC3000, TSGModel.SC3000H:
      CoreId := ROM_CORE_ID_SC3000;
    TSGModel.SF7000:
      CoreId := ROM_CORE_ID_SF7000;
    TSGModel.Multivision:
      CoreId := ROM_CORE_ID_OMV;
    TSGModel.MasterSystem, TSGModel.MarkIII:
      CoreId := ROM_CORE_ID_SMS;
    TSGModel.GameGear:
      CoreId := ROM_CORE_ID_GG;
  else
    CoreId := ROM_CORE_ID_SG1000;
  end;
  try
    try
      if FModel = TSGModel.SF7000 then
        Console := TSGConsole.CreateSF7000(FBios, FData, FPAL, FWarmBoot)
      else
        Console := TSGConsole.CreateModel(FData, FModel, FPAL, MapperHint);
      if (Console.SMSCartridge <> nil) and (Length(FBios) > 0) then
        Console.SetBIOS(FBios);
      if (SaveFile <> '') and FStorage.Exists(SaveFile) then
      begin
        var Saved := FStorage.ReadBytes(SaveFile);
        if Console.SMSCartridge <> nil then
          Console.SMSCartridge.LoadRAM(Saved)
        else if Console.SF7000 <> nil then
          Console.SF7000.Mount(Saved, False);
      end;
      Console.ApplyOptions(Options);
      if (TapeFile <> '') and (FModel in [TSGModel.SG1000II, TSGModel.SC3000, TSGModel.SC3000H, TSGModel.SF7000]) then
      begin
        Console.Cassette.LoadWAV(FStorage.ReadBytes(TapeFile));
        if TapeAutoPlay then
          Console.Cassette.Play;
      end;
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
        FInputPortsCommand.Process(nil);
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
              if Console.Model = TSGModel.GameGear then
                SaveSnapshotPreview(Path, 160, 144, 256, @Console.VDP.Pixels[((Console.VDP.ScreenHeight - 144) div 2) * 256 + 48], FStorage)
              else
                SaveSnapshotPreview(Path, 256, Console.VDP.ScreenHeight, 256, @Console.VDP.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        try
          Console.ApplyOptions(FOptions);
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
          Input.Buttons := [];
        if InputPorts.Devices[1] = 'none' then
          Input.Buttons2 := [];
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
      var Saved: TBytes;
      if (Console.SMSCartridge <> nil) and Console.SMSCartridge.Dirty then
        Saved := Console.SMSCartridge.SaveRAM
      else if (Console.SF7000 <> nil) and (Console.SF7000.Disk <> nil) and Console.SF7000.Disk.Dirty then
        Saved := Console.SF7000.Disk.Image;
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

