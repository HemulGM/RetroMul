unit NeoGeo.Emulation;

interface

uses
  Core.InputConfig, Core.Storage, Core.Snapshots, System.SysUtils,
  System.Classes, System.SyncObjs, Core.Emulation.Types, NeoGeo.Console,
  NeoGeo.Cartridge, NeoGeo.Video;

const
  NG_WORKER_SAMPLE_RATE = 44100;
  AUDIO_BLOCK_SAMPLES = 2048;
  AUDIO_BLOCK_COUNT = 4;

type
  TNeoGeoWorker = class(TThread)
  private
    FInputPortsCommand: TInputPortsCommand;
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
  private
    FSnapshots: TSnapshotQueue;
    FSnapshotDirectory: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FData: TBytes;
    FCoreId: string;
    FCartridge: TNeoGeoCartridge;
    FCoins: array[0..1] of Boolean;
    FSavePath: string;
    FStorage: IStorage;
    FInput, FInput2: TEmulatorButtons;
    FPause, FReset, FAudioEnabled: Boolean;
    FVolume: Single;
    FCabinetDIPs: Byte;
    FRequestedCardPath: string;
    FRequestedCardSize: Integer;
    FReplaceCard: Boolean;
    FFrame: TEmulatorFrame;
    FAvailable: Boolean;
    FError, FAudioError, FFinalSaveError: string;
    FPendingBattery: TBytes;
    FMemoryCardPath: string;
    FPendingCard: TBytes;
    FLastCard: TBytes;
    FCardSaveError: string;
    FRTCPath, FRTCSaveError: string;
    FPendingRTC: TBytes;
    FCardInserted, FCardReadOnly, FDiscPresent, FTrayOpen, FDiscChanged, FCardChanged: Boolean;
    procedure SetError(const Value: string);
  protected
    procedure Execute; override;
  public
    constructor Create(Cartridge: TNeoGeoCartridge; const SavePath: string; const Storage: IStorage = nil);
    destructor Destroy; override;
    procedure WakeSetEvent;
    procedure Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TEmulatorButtons = []);
    procedure ConfigureCard(const Path: string; NewCardSize: Integer);
    procedure ConfigureCabinet(DIPs: Byte);
    procedure ConfigureMedia(CardInserted, CardReadOnly, DiscPresent, TrayOpen: Boolean);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
  public
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  public
    property SnapshotDirectory: string read FSnapshotDirectory write FSnapshotDirectory;
    property MemoryCardPath: string read FMemoryCardPath write FMemoryCardPath;
    procedure InsertCoin(Player: Integer);
    procedure RequestReset;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    procedure StopAndSave;
  end;

implementation

uses
  Core.SavePaths, Core.PerformanceHints, System.IOUtils, System.UITypes,
  System.Diagnostics, System.Math, PCM.Audio;

{ TNeoGeoWorker }

function TNeoGeoWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TNeoGeoWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

constructor TNeoGeoWorker.Create(Cartridge: TNeoGeoCartridge; const SavePath: string; const Storage: IStorage);
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
  FCartridge := Cartridge;
  FCabinetDIPs := Cartridge.CabinetDIPs;
  FCardInserted := Cartridge.CardInserted;
  FCardReadOnly := Cartridge.CardReadOnly;
  FDiscPresent := True;
  FData := Cartridge.Identity;
  FCoreId := ROM_CORE_ID_NEOGEO;
  if Cartridge.Disc <> nil then
    FCoreId := ROM_CORE_ID_NEOGEOCD;
  FSavePath := SavePath;
  if (Cartridge.Disc = nil) and not Cartridge.AES then
    FRTCPath := FStorage.SaveRoot + PathDelim + 'neogeo-rtc.bin';
end;

destructor TNeoGeoWorker.Destroy;
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

procedure TNeoGeoWorker.Configure(const Input: TEmulatorButtons; Paused, AudioEnabled: Boolean; Volume: Single; const Input2: TEmulatorButtons);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FInput2 := Input2;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
end;

procedure TNeoGeoWorker.SaveSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, False);
end;

procedure TNeoGeoWorker.LoadSnapshot(const Name: string);
begin
  FSnapshots.Execute(Self, Name, True);
end;

procedure TNeoGeoWorker.RequestReset;
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

procedure TNeoGeoWorker.SetError(const Value: string);
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

function TNeoGeoWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TNeoGeoWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TNeoGeoWorker.ConfigureCard(const Path: string; NewCardSize: Integer);
begin
  FLock.Acquire;
  try
    FRequestedCardPath := Path;
    FRequestedCardSize := NewCardSize;
    FReplaceCard := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TNeoGeoWorker.ConfigureCabinet(DIPs: Byte);
begin
  FLock.Acquire;
  try
    FCabinetDIPs := DIPs;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TNeoGeoWorker.ConfigureMedia(CardInserted, CardReadOnly, DiscPresent, TrayOpen: Boolean);
begin
  FLock.Acquire;
  try
    // Input polling also reapplies media settings. Unchanged media must not
    // interrupt the frame limiter on every frontend poll.
    if (FCardInserted = CardInserted) and (FCardReadOnly = CardReadOnly) and
      (FDiscPresent = DiscPresent) and (FTrayOpen = TrayOpen) then
      Exit;

    if (FCardInserted <> CardInserted) or (FCardReadOnly <> CardReadOnly) then
      FCardChanged := True;
    FCardInserted := CardInserted;
    FCardReadOnly := CardReadOnly;
    if (FDiscPresent <> DiscPresent) or (FTrayOpen <> TrayOpen) then
      FDiscChanged := True;
    FDiscPresent := DiscPresent;
    FTrayOpen := TrayOpen;
  finally
    FLock.Release;
  end;
  WakeSetEvent;
end;

procedure TNeoGeoWorker.StopAndSave;
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
      raise EInOutError.Create('Neo Geo SRAM: ' + E.Message);
  end;

  if Length(FPendingCard) > 0 then
  begin
    var CardStream := TBytesStream.Create(FPendingCard);
    try
      SaveStreamAtomically(CardStream, FMemoryCardPath, FStorage);
    finally
      CardStream.Free;
    end;
    FPendingCard := nil;
    FCardSaveError := '';
  end;
  if Length(FPendingRTC) > 0 then
  begin
    FStorage.WriteBytes(FRTCPath, FPendingRTC);
    FPendingRTC := nil;
    FRTCSaveError := '';
  end;
  if FRTCSaveError <> '' then
    raise EInOutError.Create('Neo Geo RTC: ' + FRTCSaveError);

  if FCardSaveError <> '' then
    raise EInOutError.Create('Neo Geo memory card: ' + FCardSaveError);

  if FFinalSaveError <> '' then
    raise EInOutError.Create('Neo Geo SRAM: ' + FFinalSaveError);
end;

function TNeoGeoWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

procedure TNeoGeoWorker.WakeSetEvent;
begin
  FWake.SetEvent;
end;

procedure TNeoGeoWorker.Execute;

  procedure SaveBattery(Console: TNeoGeoConsole; var LastBattery: TBytes);
  begin
    if (Console <> nil) and (FRTCPath <> '') then
    begin
      var Clock := Console.RTCBatteryData;
      if Length(Clock) > 0 then
      begin
        FPendingRTC := Clock;
        try
          FStorage.WriteBytes(FRTCPath, Clock);
          FPendingRTC := nil;
          FRTCSaveError := '';
        except
          on E: Exception do
            FRTCSaveError := E.Message;
        end;
      end;
    end;
    if (Console <> nil) and Console.MemoryCardDirty and (FMemoryCardPath <> '') then
    begin
      var Card := Console.MemoryCardData;
      if (Length(Card) > 0) and
        ((Length(FPendingCard) > 0) or (Length(Card) <> Length(FLastCard)) or not CompareMem(@Card[0], @FLastCard[0], Length(Card))) then
      begin
        FPendingCard := Copy(Card);
        var CardStream := TBytesStream.Create(Card);
        try
          try
            SaveStreamAtomically(CardStream, FMemoryCardPath, FStorage);
            FPendingCard := nil;
            FLastCard := Card;
            FCardSaveError := '';
          except
            on E: Exception do
              FCardSaveError := E.Message;
          end;
        finally
          CardStream.Free;
        end;
      end;
    end;
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
  var Samples: TArray<SmallInt>;
  var Deadline: Double;
  var LastBattery: TBytes;
  var AudioFailed := False;
  var Console: TNeoGeoConsole := nil;
  var Audio: TPCMAudio := nil;
  var FrameHints: TEmulationPerformanceHints := nil;
  try
    try
      Console := TNeoGeoConsole.Create(FCartridge);
      Console.ConfigureInputPorts(InputPorts);
      if (FRTCPath <> '') and FStorage.Exists(FRTCPath) then
        Console.LoadRTCBattery(FStorage.ReadBytes(FRTCPath));
      if (FMemoryCardPath <> '') and FStorage.Exists(FMemoryCardPath) then
      begin
        FLastCard := FStorage.ReadBytes(FMemoryCardPath);
        Console.LoadMemoryCard(FLastCard);
      end;
      FrameHints := TEmulationPerformanceHints.Create(Round(1000000000.0 / Console.FramesPerSecond), FCoreId);
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := NG_WORKER_SAMPLE_RATE;
      Format.Channels := 2;
      Format.BlockFrames := AUDIO_BLOCK_SAMPLES;
      Format.BlockCount := AUDIO_BLOCK_COUNT;
      Deadline := TStopwatch.GetTimeStamp;
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
              LoadCoreSnapshot(Path, FCoreId, FData, Transfer, FStorage);
              Console.ConfigureInputPorts(InputPorts);
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
                  Frame.Pixels[Y * Frame.Width + X] := Console.Video.Pixels[Y * 320 + X];
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
              SaveCoreSnapshot(Path, FCoreId, FData, Transfer, FStorage);
              SaveSnapshotPreview(Path, Console.Width, Console.Height, 320, @Console.Video.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);

        var ReplaceCard: Boolean;
        var CardPath: string;
        var CardSize: Integer;
        var Input, Input2: TEmulatorButtons;
        FLock.Acquire;
        try
          ReplaceCard := FReplaceCard;
          CardPath := FRequestedCardPath;
          CardSize := FRequestedCardSize;
          FReplaceCard := False;
          FCartridge.CabinetDIPs := FCabinetDIPs;
          Input := FInput;
          Input2 := FInput2;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
          if FCardChanged then
          begin
            Console.SetMemoryCard(FCardInserted, FCardReadOnly);
            FCardChanged := False;
          end;
          if FDiscChanged and (Console.CDController <> nil) then
          begin
            Console.CDController.SetDiscPresent(FDiscPresent);
            Console.CDController.SetTrayOpen(FTrayOpen);
            FDiscChanged := False;
          end;
        finally
          FLock.Release;
        end;

        if ReplaceCard and (Console.CDController = nil) and
          (CardPath <> FMemoryCardPath) then
        begin
          // Read and validate the replacement before touching the active card.
          var Card: TBytes;
          if FStorage.Exists(CardPath) then
            Card := FStorage.ReadBytes(CardPath)
          else
          begin
            SetLength(Card, CardSize);
            FillChar(Card[0], Length(Card), $FF);
          end;
          if (Length(Card) < 2048) or (Length(Card) > 16384) or
            (Length(Card) mod 2048 <> 0) then
            raise EReadError.Create('Invalid Neo Geo memory card size');
          SaveBattery(Console, LastBattery);
          if FCardSaveError <> '' then
            raise EInOutError.Create('Neo Geo memory card: ' + FCardSaveError);
          Console.LoadMemoryCard(Card);
          FMemoryCardPath := CardPath;
          FLastCard := Copy(Card);
          FPendingCard := nil;
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

        // A command may wake the end-of-frame wait early. Process it above,
        // then wait for the same deadline before executing another frame.
        // Re-enter the loop after waiting so input and pause state are current.
        if TStopwatch.GetTimeStamp < Round(Deadline) then
        begin
          FrameHints.WaitUntil(FWake, Round(Deadline));
          Continue;
        end;

        WasPaused := False;
        FrameHints.TargetDurationNanos := Round(1000000000.0 / Console.FramesPerSecond);
        FrameHints.BeginWork;
        var GameInput := Default(TEmulatorInput);
        GameInput.Buttons := Input;
        GameInput.Buttons2 := Input2;
        Console.SetInput(GameInput);
        FLock.Acquire;
        try
          for var Player := 0 to 1 do
            if FCoins[Player] then
            begin
              Console.InsertCoin(Player + 1);
              FCoins[Player] := False;
            end;
        finally
          FLock.Release;
        end;
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
          Move(Console.Video.Pixels[Y * 320], Frame.Pixels[Y * Frame.Width], Frame.Width * SizeOf(Frame.Pixels[0]));

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
              FAudioError := 'Neo Geo audio: ' + E.Message;
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
        SetError('Neo Geo: ' + E.Message);
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

procedure TNeoGeoWorker.InsertCoin(Player: Integer);
begin
  if not (Player in [1, 2]) then
    Exit;

  FLock.Acquire;
  try
    FCoins[Player - 1] := True;
  finally
    FLock.Release;
  end;
end;

end.

