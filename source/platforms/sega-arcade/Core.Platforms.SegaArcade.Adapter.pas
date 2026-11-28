unit Core.Platforms.SegaArcade.Adapter;

interface

uses
  Core.Emulation.Types, System.SysUtils, System.Classes, System.SyncObjs,
  System.IniFiles, Core.Storage, Core.Emulation, Core.InputConfig,
  SegaArcade.Cartridge, Core.Snapshots, PCM.Audio, SegaArcade.Console;

type
  TSegaArcadeKeys = array[TEmulatorButton] of UInt32;

  TSegaArcadeDIPs = array[0..1] of Integer;

  TSegaArcadeConfig = class(TEmulatorConfigBase)
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    DIPs: TSegaArcadeDIPs;
    DIPSection: string;
    Keys: array[0..3] of TSegaArcadeKeys;
    constructor Create(const FileName: string; const Storage: IStorage; const Section: string);
  end;

  // Keeps the hardware PCM stream continuous across video-frame boundaries.
  TSegaArcadeAudioBuffer = record
  private
    FPending: TArray<SmallInt>;
    FCount: Integer;
    FPrimed: Boolean;
  public
    procedure Clear(Audio: TPCMAudio);
    procedure Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
  end;

  TSegaArcadeWorker = class(TAchievementWorker)
  private
    FCart: TSegaArcadeCartridge;
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory, FCoreId: string;
    FConsoleClass: TSegaArcadeConsoleClass;
    FSnapshots: TSnapshotQueue;
    FAudioEnabled: Boolean;
    FVolume: Single;
    FAudioError: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FInput: TEmulatorInput;
    FCoins: array[0..1] of Boolean;
    FPointerX, FPointerY: Integer;
    FPause, FReset, FAvailable: Boolean;
    FFrame: TEmulatorFrame;
    FError: string;
    procedure OrientFrame(var Frame: TEmulatorFrame);
  protected
    procedure Execute; override;
  public
    DIPOverride: TSegaArcadeDIPs;
    constructor Create(Cart: TSegaArcadeCartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; ConsoleClass: TSegaArcadeConsoleClass);
    destructor Destroy; override;
    procedure Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
    procedure InsertCoin(Player: Integer);
    procedure AddPointerMotion(DX, DY: Integer);
    procedure Stop;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    procedure Snapshot(const Name: string; Loading: Boolean);
    function TakeAudioError: string;
    function TakeError: string;
  end;

  TSegaArcadeCoreAdapter = class abstract(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationVirtualControls, IEmulationInputPorts, IEmulationAudioDiagnostics, IEmulationSnapshotLocation, IEmulationAchievements, IEmulationArcadeAchievements)
  private
    FStorage: IStorage;
    FIdentity: TBytes;
    FSavePath, FSnapshotDirectory: string;
    FConsoleClass: TSegaArcadeConsoleClass;
    FSystemId, FName: string;
    FWorker: TSegaArcadeWorker;
    FConfig: IEmulatorConfig;
    FOptions: TSegaArcadeConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPorts: TCoreInputPorts;
    FPaused: Boolean;
    FError, FAudioError: string;
    procedure Configure;
  protected
    FCart: TSegaArcadeCartridge;
    procedure UpdateInput;
    function InputPortEnabled(Port: Integer): Boolean;
    procedure AddPointerMotion(DX, DY: Integer);
    procedure InitializeCore(Cart: TSegaArcadeCartridge; ConsoleClass: TSegaArcadeConsoleClass; const Storage: IStorage; const RomName, SystemId, PlatformName, DIPSection: string);
  public
    procedure ApplyLiveSettings;
    destructor Destroy; override;
    function GetSystemId: string;
    function AchievementROM: TBytes;
    function AchievementSetName: string;
    procedure SetAchievementObserver(const Observer: IEmulationAchievementObserver);
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetSnapshotDirectory: string;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput; virtual;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    function GetInputState: TEmulatorInput; virtual;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetVirtualButtons: TEmulatorButtons;
  end;

implementation

uses
  System.UITypes, System.Diagnostics, System.Math, SegaArcade.Video,
  Core.SavePaths, System.IOUtils;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TSegaArcadeCoreAdapter.ApplyLiveSettings;
begin
  Configure;
end;

procedure TSegaArcadeAudioBuffer.Clear(Audio: TPCMAudio);
begin
  FCount := 0;
  FPrimed := False;
  if Audio <> nil then
  begin
    Audio.Clear;
    Audio.SetPaused(True);
  end;
end;

procedure TSegaArcadeAudioBuffer.Submit(Audio: TPCMAudio; const Samples: TArray<SmallInt>; const Format: TPCMAudioFormat);
begin
  // Keep complete blocks and prime 46 ms before starting playback. Re-prime
  // after an underrun, pause, reset or state load instead of playing fragments.
  if FPrimed and (Audio.QueueState.QueuedBlocks = 0) then
  begin
    FPrimed := False;
    Audio.SetPaused(True);
  end;
  if Length(FPending) < FCount + Length(Samples) then
    SetLength(FPending, FCount + Length(Samples));
  if Length(Samples) > 0 then
    Move(Samples[0], FPending[FCount], Length(Samples) * SizeOf(SmallInt));
  Inc(FCount, Length(Samples));
  var BlockSamples := Format.BlockFrames * Format.Channels;
  if not FPrimed and (FCount < BlockSamples * 2) then
    Exit;
  var Used := 0;
  while (FCount - Used >= BlockSamples) and
    (Audio.QueueState.QueuedBlocks < Format.BlockCount) do
  begin
    Audio.Submit(Copy(FPending, Used, BlockSamples), Format.BlockFrames);
    Inc(Used, BlockSamples);
  end;
  Dec(FCount, Used);
  if FCount > 0 then
    Move(FPending[Used], FPending[0], FCount * SizeOf(SmallInt));
  if not FPrimed and (Used > 0) then
  begin
    Audio.SetPaused(False);
    FPrimed := True;
  end;
end;

procedure TSegaArcadeWorker.OrientFrame(var Frame: TEmulatorFrame);
begin
  var Rotation := FCart.RomSet.Rotation;
  if Rotation = 0 then
    Exit;

  var Source := Frame.Pixels;
  Frame.Pixels := nil;
  SetLength(Frame.Pixels, Length(Source));
  var W := Frame.Width;
  var H := Frame.Height;
  if (Rotation = 90) or (Rotation = 270) then
  begin
    Frame.Width := H;
    Frame.Height := W;
  end;
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
      case Rotation of
        90:
          Frame.Pixels[X * H + H - 1 - Y] := Source[Y * W + X];
        180:
          Frame.Pixels[(H - 1 - Y) * W + W - 1 - X] := Source[Y * W + X];
        270:
          Frame.Pixels[(W - 1 - X) * H + Y] := Source[Y * W + X];
      end;
end;

constructor TSegaArcadeConfig.Create(const FileName: string; const Storage: IStorage; const Section: string);
const
  P1: TSegaArcadeKeys = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vk5, vkReturn, vkC, vkA, vkS, vkD, vkF2);
  P2: TSegaArcadeKeys = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, vk6, vkNumpad0, vkNumpad3, vkNumpad7, vkNumpad9, vkDecimal, 0);
begin
  inherited Create(FileName, Storage);
  DIPSection := Section;
  Keys[0] := P1;
  Keys[1] := P2;
  for var i := 0 to 1 do
    DIPs[i] := -1;
end;

procedure TSegaArcadeConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var i := 0 to 1 do
  begin
    DIPs[i] := Ini.ReadInteger(DIPSection, 'DIP' + Chr(Ord('A') + i), DIPs[i]);
    if (DIPs[i] < -1) or (DIPs[i] > 255) then
      DIPs[i] := -1;
  end;
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Keys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], Keys[P, B]);
  end;
end;

procedure TSegaArcadeConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var i := 0 to 1 do
    Ini.WriteInteger(DIPSection, 'DIP' + Chr(Ord('A') + i), DIPs[i]);
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], Keys[P, B]);
  end;
end;

constructor TSegaArcadeWorker.Create(Cart: TSegaArcadeCartridge; const Storage: IStorage; const Identity: TBytes; const SavePath, SnapshotDirectory, CoreId: string; ConsoleClass: TSegaArcadeConsoleClass);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCart := Cart;
  for var i := 0 to 1 do
    DIPOverride[i] := -1;
  FStorage := Storage;
  FIdentity := Identity;
  FSavePath := SavePath;
  FSnapshotDirectory := SnapshotDirectory;
  FCoreId := CoreId;
  FConsoleClass := ConsoleClass;
  FSnapshots := TSnapshotQueue.Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
end;

destructor TSegaArcadeWorker.Destroy;
begin
  Stop;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
  inherited;
end;

procedure TSegaArcadeWorker.Stop;
begin
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TSegaArcadeWorker.Configure(const Input: TEmulatorInput; Paused, Reset, AudioEnabled: Boolean; Volume: Single);
begin
  FLock.Acquire;
  try
    FInput := Input;
    FPause := Paused;
    FReset := FReset or Reset;
    FAudioEnabled := AudioEnabled;
    FVolume := Volume;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TSegaArcadeWorker.InsertCoin(Player: Integer);
begin
  FLock.Acquire;
  try
    FCoins[Player - 1] := True;
  finally
    FLock.Release;
  end;
end;

procedure TSegaArcadeWorker.AddPointerMotion(DX, DY: Integer);
begin
  FLock.Acquire;
  try
    FPointerX := (FPointerX + (DX mod $1000)) and $FFF;
    FPointerY := (FPointerY + (DY mod $1000)) and $FFF;
  finally
    FLock.Release;
  end;
end;

function TSegaArcadeWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TSegaArcadeWorker.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSegaArcadeWorker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

function TSegaArcadeWorker.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

procedure TSegaArcadeWorker.Execute;
var
  Console: TSegaArcadeConsole;
  Audio: TPCMAudio;
  AudioBuffer: TSegaArcadeAudioBuffer;
  AudioFailed: Boolean;
  LastBattery: TBytes;
  Publish: TProc;

  procedure SaveBattery;
  begin
    if Console = nil then
      Exit;
    var Data := Console.Battery;
    if Length(Data) = 0 then
      Exit;
    if (Length(Data) = Length(LastBattery)) and CompareMem(@Data[0], @LastBattery[0], Length(Data)) then
      Exit;
    var Stream := TBytesStream.Create(Data);
    try
      FStorage.WriteAtomic(FSavePath, Stream);
      LastBattery := Data;
    finally
      Stream.Free;
    end;
  end;

begin
  Console := nil;
  Audio := nil;
  AudioFailed := False;
  AudioBuffer := Default(TSegaArcadeAudioBuffer);
  Publish :=
    procedure
    begin
      var Frame: TEmulatorFrame;
      Frame.Width := SEGA_ARCADE_WIDTH;
      Frame.Height := SEGA_ARCADE_HEIGHT;
      Frame.FramesPerSecond := Console.FrameRate;
      Frame.Pixels := Copy(Console.Video.Pixels);
      Frame.FrameNumber := Console.FrameNumber;
      OrientFrame(Frame);
      FLock.Acquire;
      try
        FFrame := Frame;
        FAvailable := True;
      finally
        FLock.Release;
      end;
    end;

  var ReadMemory: TEmulationAchievementRead :=
    function(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal
    begin
      Result := Console.ReadAchievementRAM(Address, Buffer, Count);
    end;
  try
    try
      Console := FConsoleClass.Create(FCart);
      for var I := 0 to 1 do
        if DIPOverride[I] >= 0 then
          Console.DIP[I] := Byte(DIPOverride[I]);
      if FStorage.Exists(FSavePath) then
      begin
        LastBattery := FStorage.ReadBytes(FSavePath);
        Console.LoadBattery(LastBattery);
      end;
      var Format: TPCMAudioFormat;
      Format.SampleRate := 44100;
      Format.Channels := 2;
      Format.BlockFrames := 1024;
      Format.BlockCount := 4;
      var Deadline := TStopwatch.GetTimeStamp;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
            var Transfer: TStateTransfer :=
              procedure(State: TStateArchive)
              begin
                Console.SerializeState(State);
                TransferAchievementProgress(State);
              end;
            if Loading then
            begin
              LoadCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              AudioBuffer.Clear(Audio);
              Publish;
            end
            else
            begin
              SaveCoreSnapshot(Path, FCoreId, FIdentity, Transfer, FStorage);
              var Preview: TEmulatorFrame;
              Preview.Width := SEGA_ARCADE_WIDTH;
              Preview.Height := SEGA_ARCADE_HEIGHT;
              Preview.Pixels := Copy(Console.Video.Pixels);
              OrientFrame(Preview);
              SaveSnapshotPreview(Path, Preview.Width, Preview.Height, Preview.Width, @Preview.Pixels[0], FStorage);
            end;
            Deadline := TStopwatch.GetTimeStamp;
          end);
        FLock.Acquire;
        var Enabled := FAudioEnabled;
        var Volume := FVolume;
        var Input := FInput;
        var Paused := FPause;
        var Reset := FReset;
        var Coin1 := FCoins[0];
        var Coin2 := FCoins[1];
        var PointerX := FPointerX;
        var PointerY := FPointerY;
        FPointerX := 0;
        FPointerY := 0;
        FReset := False;
        FCoins[0] := False;
        FCoins[1] := False;
        FLock.Release;
        if Reset then
        begin
          Console.Reset;
          ResetAchievements;
          AudioBuffer.Clear(Audio);
        end;
        Console.SetInput(Input);
        if Coin1 then
          Console.InsertCoin(1);
        if Coin2 then
          Console.InsertCoin(2);
        if Paused then
        begin
          AudioBuffer.Clear(Audio);
          FWake.WaitFor(20);
          Deadline := TStopwatch.GetTimeStamp;
          Continue;
        end;
        if (PointerX <> 0) or (PointerY <> 0) then
          Console.AddPointerMotion(PointerX, PointerY);
        Console.RunFrame;
        AchievementFrame(ReadMemory);
        Publish;
        if Enabled and not AudioFailed then
        try
          if Audio = nil then
          begin
            Audio := TPCMAudio.Create(Format);
            Audio.SetPaused(True);
          end;
          var Samples := Copy(Console.AudioSamples);
          for var I := 0 to High(Samples) do
            Samples[I] := Round(Samples[I] * Volume);
          AudioBuffer.Submit(Audio, Samples, Format);
          if Audio.Error <> '' then
            raise EInOutError.Create(Audio.Error);
        except
          on E: Exception do
          begin
            FLock.Acquire;
            try
              FAudioError := FCoreId + ' audio: ' + E.Message;
            finally
              FLock.Release;
            end;
            FreeAndNil(Audio);
            AudioFailed := True;
          end;
        end
        else if not Enabled then
        begin
          AudioBuffer.Clear(Audio);
          AudioFailed := False;
        end;
        if Console.FrameNumber mod 120 = 0 then
          SaveBattery;
        Inc(Deadline, Round(TStopwatch.Frequency / Console.FrameRate));
        var Now := TStopwatch.GetTimeStamp;
        if Now - Deadline > TStopwatch.Frequency div 4 then
          Deadline := Now;
        while not Terminated and (Now < Deadline) do
        begin
          FWake.WaitFor(Max(1, Integer((Deadline - Now) * 1000 div TStopwatch.Frequency)));
          Now := TStopwatch.GetTimeStamp;
        end;
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          FError := E.ClassName + ': ' + E.Message;
        finally
          FLock.Release;
        end;
      end;
    end;
  finally
    try
      try
        SaveBattery;
      except
        on E: Exception do
        begin
          FLock.Acquire;
          try
            FError := FCoreId + ' save: ' + E.Message;
          finally
            FLock.Release;
          end;
        end;
      end;
    finally
      Audio.Free;
      Console.Free;
    end;
  end;
end;

procedure TSegaArcadeCoreAdapter.InitializeCore(Cart: TSegaArcadeCartridge; ConsoleClass: TSegaArcadeConsoleClass; const Storage: IStorage; const RomName, SystemId, PlatformName, DIPSection: string);
begin
  FCart := Cart;
  FConsoleClass := ConsoleClass;
  FSystemId := SystemId;
  FName := PlatformName;
  var S := Storage;
  if S = nil then
    S := TStorage.Default;
  FStorage := S;
  FIdentity := FCart.Identity;

  FOptions := TSegaArcadeConfig.Create(S.ConfigFile(GetSystemId), S, DIPSection);
  FConfig := FOptions;
  FConfig.Load;
  FPorts := LoadCoreInputPorts(S, GetSystemId, GetConfig.FileName);
  var IdentityHash := SnapshotIdentity(FIdentity);
  FSavePath := S.GameSave(GetSystemId, RomName, IdentityHash);
  FSnapshotDirectory := S.GameSnapshots(GetSystemId, RomName, IdentityHash);
end;

destructor TSegaArcadeCoreAdapter.Destroy;
begin
  Stop;
  FCart.Free;
  inherited;
end;

procedure TSegaArcadeCoreAdapter.UpdateInput;
begin
  Configure;
end;

function TSegaArcadeCoreAdapter.InputPortEnabled(Port: Integer): Boolean;
begin
  Result := FPorts.Devices[Port] <> 'none';
end;

procedure TSegaArcadeCoreAdapter.AddPointerMotion(DX, DY: Integer);
begin
  if FWorker <> nil then
    FWorker.AddPointerMotion(DX, DY);
end;

procedure TSegaArcadeCoreAdapter.Configure;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, False, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TSegaArcadeCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;

  // Continue Game requests Pause before starting the worker and restoring state.
  // Preserve that request; only Resume should release an existing pause.
  FWorker := TSegaArcadeWorker.Create(FCart, FStorage, FIdentity, FSavePath, FSnapshotDirectory, GetSystemId, FConsoleClass);
  FWorker.DIPOverride := FOptions.DIPs;
  Configure;
  FWorker.Start;
end;

procedure TSegaArcadeCoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;

  FWorker.Stop;
  var AudioError := FWorker.TakeAudioError;
  if AudioError <> '' then
    FAudioError := AudioError;
  var Error := FWorker.TakeError;
  if Error <> '' then
    FError := Error;
  FreeAndNil(FWorker);
end;

procedure TSegaArcadeCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TSegaArcadeCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TSegaArcadeCoreAdapter.Reset;
begin
  if FWorker <> nil then
    FWorker.Configure(GetInputState, FPaused, True, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TSegaArcadeCoreAdapter.InsertCoin1;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(1);
end;

procedure TSegaArcadeCoreAdapter.InsertCoin2;
begin
  if FWorker <> nil then
    FWorker.InsertCoin(2);
end;

procedure TSegaArcadeCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
  for var I := 0 to 3 do
    FPorts.Devices[I] := FPorts.Devices[I].Trim.ToLower;
  ClearInput;
end;

procedure TSegaArcadeCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  Configure;
end;

procedure TSegaArcadeCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if (Code <> 0) and (Code = FOptions.Keys[0, B]) then
      if Pressed then
        Include(FKeyboard.Buttons, B)
      else
        Exclude(FKeyboard.Buttons, B);
    if (Code <> 0) and (Code = FOptions.Keys[1, B]) then
      if Pressed then
        Include(FKeyboard.Buttons2, B)
      else
        Exclude(FKeyboard.Buttons2, B);
    if (Code <> 0) and (Code = FOptions.Keys[2, B]) then
      if Pressed then
        Include(FKeyboard.Buttons3, B)
      else
        Exclude(FKeyboard.Buttons3, B);
    if (Code <> 0) and (Code = FOptions.Keys[3, B]) then
      if Pressed then
        Include(FKeyboard.Buttons4, B)
      else
        Exclude(FKeyboard.Buttons4, B);
  end;
  Configure;
end;

procedure TSegaArcadeCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  Configure;
end;

function TSegaArcadeCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  if FPorts.KeyboardEnabled then
  begin
    Result.Buttons := Result.Buttons + FKeyboard.Buttons;
    Result.Buttons2 := Result.Buttons2 + FKeyboard.Buttons2;
    Result.Buttons3 := Result.Buttons3 + FKeyboard.Buttons3;
    Result.Buttons4 := Result.Buttons4 + FKeyboard.Buttons4;
  end;
  if FPorts.Devices[0] = 'none' then
    Result.Buttons := [];
  if FPorts.Devices[1] = 'none' then
    Result.Buttons2 := [];
  if FPorts.Devices[2] = 'none' then
    Result.Buttons3 := [];
  if FPorts.Devices[3] = 'none' then
    Result.Buttons4 := [];
end;

function TSegaArcadeCoreAdapter.AchievementROM: TBytes;
begin
  Result := nil;
end;

function TSegaArcadeCoreAdapter.AchievementSetName: string;
begin
  Result := FCart.RomSet.Name;
end;

procedure TSegaArcadeCoreAdapter.SetAchievementObserver(const Observer: IEmulationAchievementObserver);
begin
  if FWorker <> nil then
    FWorker.SetAchievementObserver(Observer);
end;

function TSegaArcadeCoreAdapter.GetSystemId: string;
begin
  Result := FSystemId;
end;

function TSegaArcadeCoreAdapter.GetName: string;
begin
  Result := FName;
end;

function TSegaArcadeCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TSegaArcadeCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TSegaArcadeCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := True;
end;

function TSegaArcadeCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TSegaArcadeCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TSegaArcadeCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TSegaArcadeCoreAdapter.TakeAudioError: string;
begin
  Result := FAudioError;
  FAudioError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeAudioError;
end;

function TSegaArcadeCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TSegaArcadeCoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.Mode];
end;

procedure TSegaArcadeCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create(GetName + ' core is stopped');

  FWorker.Snapshot(Name, False);
end;

procedure TSegaArcadeCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create(GetName + ' core is stopped');

  FWorker.Snapshot(Name, True);
end;

end.

