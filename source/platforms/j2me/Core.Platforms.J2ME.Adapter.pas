unit Core.Platforms.J2ME.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  System.Generics.Collections, Core.Storage, Core.Emulation, J2ME.Suite,
  J2ME.Runtime, Core.Platforms.J2ME.Playback, Core.Bluetooth.Types,
  Core.Messaging.Types, J2ME.Device;

type
  TJ2MEConfig = class(TEmulatorConfigBase)
  public
    Width, Height, MIDletIndex: Integer;
    ScreenSize: string;
    function EffectiveScreen: TJ2MEScreenSize;
    constructor Create(const FileName: string; const Storage: IStorage);
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  end;

  TJ2MEKeyEvent = record
    Code: Integer;
    Pressed: Boolean;
  end;

  TJ2MECoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationAudioDiagnostics, IEmulationBluetooth, IEmulationMessaging, IEmulationRumbleOutput)
  private
    FStorage: IStorage;
    FSuite: TJ2MESuite;
    FConfig: IEmulatorConfig;
    FSettings: TJ2MEConfig;
    FWorker: TThread;
    FLock: TCriticalSection;
    FEvents: TQueue<TJ2MEKeyEvent>;
    FKeyboard: TDictionary<UInt32, Integer>;
    FHeld: TDictionary<Integer, Integer>;
    FInput: TEmulatorInput;
    FFrame: TEmulatorFrame;
    FFrameReady, FPaused: Boolean;
    FError, FAudioError: string;
    FRumbleArea: Double;
    FRumbleMillis: Int64;
    FMotorResetGeneration: UInt64;
    FAudioFactory: TJ2MEAudioFactory;
    FBluetooth: IBluetoothProvider;
    FMessaging: IMessagingProvider;
    procedure ExecuteVM;
    procedure ChangeHeld(Code: Integer; Pressed: Boolean);
  public
    constructor Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TJ2MEAudioFactory = nil);
    destructor Destroy; override;
    function GetSystemId: string;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetHasRumble: Boolean;
    function GetRumbleLevel: Byte;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    procedure SetMessagingProvider(const Provider: IMessagingProvider);
    function GetMessagingProvider: IMessagingProvider;
    procedure SetBluetoothProvider(const Provider: IBluetoothProvider);
    function GetBluetoothProvider: IBluetoothProvider;
  end;

implementation

uses
  System.IOUtils, System.Math, System.Diagnostics, JVM.Types, Core.Bluetooth,
  Core.Platforms.Bluetooth, Core.Messaging;

const
  PadCodes: array[TEmulatorButton] of Integer = (-1, -2, -3, -4, -5, 48, -6, -7, 49, 51, 55, 57, 53);

constructor TJ2MEConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  Width := 240;
  Height := 320;
  ScreenSize := 'custom';
end;

procedure TJ2MEConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  Width := EnsureRange(Ini.ReadInteger('Phone', 'Width', 240), 1, 1024);
  Height := EnsureRange(Ini.ReadInteger('Phone', 'Height', 320), 1, 1024);
  MIDletIndex := EnsureRange(Ini.ReadInteger('Phone', 'MIDletIndex', 0), 0, 1023);
  ScreenSize := LowerCase(Trim(Ini.ReadString('Phone', 'ScreenSize', 'custom')));
  var Valid := ScreenSize = 'custom';
  for var Size in TJ2MEScreenSize.Presets do
    if ScreenSize = Size.ToString then
      Valid := True;
  if not Valid then
    ScreenSize := 'custom';
end;

procedure TJ2MEConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteInteger('Phone', 'Width', Width);
  Ini.WriteInteger('Phone', 'Height', Height);
  Ini.WriteInteger('Phone', 'MIDletIndex', MIDletIndex);
  Ini.WriteString('Phone', 'ScreenSize', ScreenSize);
end;

function TJ2MEConfig.EffectiveScreen: TJ2MEScreenSize;
begin
  if not TJ2MEScreenSize.TryParse(ScreenSize, Result) then
    Result := TJ2MEScreenSize.Create(Width, Height);
end;

constructor TJ2MECoreAdapter.Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TJ2MEAudioFactory);
var
  JAD: TBytes;
  JADName: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAudioFactory := AudioFactory;
  FBluetooth := CreatePlatformBluetoothProvider;
  FMessaging := CreateUnavailableMessagingProvider;
  FEvents := TQueue<TJ2MEKeyEvent>.Create;
  FKeyboard := TDictionary<UInt32, Integer>.Create;
  FHeld := TDictionary<Integer, Integer>.Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FSettings := TJ2MEConfig.Create(FStorage.ConfigFile('j2me'), FStorage);
  FConfig := FSettings;
  FConfig.Load;
  JADName := ChangeFileExt(RomName, '.jad');
  if FStorage.Exists(JADName) then
    JAD := FStorage.ReadBytes(JADName);
  FSuite := TJ2MESuite.Open(Input, FStorage, JAD);
  if FSettings.MIDletIndex >= FSuite.MIDletCount then
    raise EReadError.Create('Configured MIDlet index is not present in this suite');
end;

destructor TJ2MECoreAdapter.Destroy;
begin
  Stop;
  FSuite.Free;
  FHeld.Free;
  FKeyboard.Free;
  FEvents.Free;
  FLock.Free;
  inherited;
end;

function TJ2MECoreAdapter.GetSystemId: string;
begin
  Result := 'j2me';
end;

function TJ2MECoreAdapter.GetName: string;
begin
  Result := FSuite.GetProperty('MIDlet-Name');
  if Result = '' then
    Result := FSuite.MIDlet(FSettings.MIDletIndex).Name;
end;

function TJ2MECoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := False;
end;

function TJ2MECoreAdapter.GetHasRumble: Boolean;
begin
  Result := True;
end;

function TJ2MECoreAdapter.GetRumbleLevel: Byte;
begin
  FLock.Acquire;
  try
    Result := 0;
    if not FPaused and (FWorker <> nil) and (FRumbleMillis > 0) then
      Result := Byte(EnsureRange(Round(FRumbleArea / FRumbleMillis * 255 / 100), Int64(0), Int64(255)));
    FRumbleArea := 0;
    FRumbleMillis := 0;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TJ2MECoreAdapter.InsertCoin1;
begin
end;

procedure TJ2MECoreAdapter.InsertCoin2;
begin
end;

procedure TJ2MECoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  FPaused := False;
  FError := '';
  FAudioError := '';
  FFrameReady := False;
  FLock.Acquire;
  try
    FRumbleArea := 0;
    FRumbleMillis := 0;
    FMotorResetGeneration := 0;
  finally
    FLock.Release;
  end;
  FWorker := TThread.CreateAnonymousThread(
    procedure
    begin
      ExecuteVM;
    end);
  FWorker.FreeOnTerminate := False;
  FWorker.Start;
end;

procedure TJ2MECoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;
  FWorker.Terminate;
  FWorker.WaitFor;
  FreeAndNil(FWorker);
  ClearInput;
  FLock.Acquire;
  try
    FEvents.Clear;
    FRumbleArea := 0;
    FRumbleMillis := 0;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.Pause;
begin
  FLock.Acquire;
  try
    FPaused := True;
    FRumbleArea := 0;
    FRumbleMillis := 0;
    Inc(FMotorResetGeneration);
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.Resume;
begin
  FLock.Acquire;
  try
    FPaused := False;
    FRumbleArea := 0;
    FRumbleMillis := 0;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.Reset;
begin
  Stop;
  Start;
end;

procedure TJ2MECoreAdapter.ChangeHeld(Code: Integer; Pressed: Boolean);
var
  N: Integer;
  Event: TJ2MEKeyEvent;
begin
  if not FHeld.TryGetValue(Code, N) then
    N := 0;
  if Pressed then
  begin
    FHeld.AddOrSetValue(Code, N + 1);
    if N <> 0 then
      Exit;
  end
  else
  begin
    if N = 0 then
      Exit;
    if N > 1 then
    begin
      FHeld[Code] := N - 1;
      Exit;
    end;
    FHeld.Remove(Code);
  end;
  Event.Code := Code;
  Event.Pressed := Pressed;
  if FEvents.Count < 1024 then
    FEvents.Enqueue(Event);
end;

procedure TJ2MECoreAdapter.ClearInput;
var
  Event: TJ2MEKeyEvent;
  Code: Integer;
begin
  FLock.Acquire;
  try
    FEvents.Clear;
    for Code in FHeld.Keys do
    begin
      Event.Code := Code;
      Event.Pressed := False;
      FEvents.Enqueue(Event);
    end;
    FHeld.Clear;
    FKeyboard.Clear;
    FInput := Default(TEmulatorInput);
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  JavaCode: Integer;
begin
  FLock.Acquire;
  try
    if not Pressed then
    begin
      if FKeyboard.TryGetValue(Code, JavaCode) then
      begin
        FKeyboard.Remove(Code);
        ChangeHeld(JavaCode, False);
      end;
      Exit;
    end;
    if FKeyboard.ContainsKey(Code) then
      Exit;
    case Code of
      48..57:
        JavaCode := Code;
      96..105:
        JavaCode := Integer(Code) - 48;
      38:
        JavaCode := -1;
      40:
        JavaCode := -2;
      37:
        JavaCode := -3;
      39:
        JavaCode := -4;
      13, 32:
        JavaCode := -5;
      65..90:
        JavaCode := -10000 - (Integer(Code) + 32);
      8, 46:
        JavaCode := -8;
      36:
        JavaCode := -1001;
      35:
        JavaCode := -1002;
      9:
        JavaCode := -1003;
      112:
        JavaCode := -6;
      113:
        JavaCode := -7;
      114, 106:
        JavaCode := 42;
      115, 111:
        JavaCode := 35;
    else
      Exit;
    end;
    FKeyboard.Add(Code, JavaCode);
    ChangeHeld(JavaCode, True);
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
var
  B: TEmulatorButton;
begin
  FLock.Acquire;
  try
    for B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if (B in Input.Buttons) <> (B in FInput.Buttons) then
        ChangeHeld(PadCodes[B], B in Input.Buttons);
    FInput := Input;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetInputState: TEmulatorInput;
begin
  FLock.Acquire;
  try
    Result := FInput;
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if FHeld.ContainsKey(PadCodes[B]) then
        Include(Result.Buttons, B);
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SaveSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('J2ME state snapshots are not implemented');
end;

procedure TJ2MECoreAdapter.LoadSnapshot(const Name: string);
begin
  raise ENotSupportedException.Create('J2ME state snapshots are not implemented');
end;

function TJ2MECoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FFrameReady;
    if Result then
    begin
      Frame := FFrame;
      FFrameReady := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.TakeError: string;
begin
  FLock.Acquire;
  try
    Result := FError;
    FError := '';
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.TakeAudioError: string;
begin
  FLock.Acquire;
  try
    Result := FAudioError;
    FAudioError := '';
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TJ2MECoreAdapter.IsPaused: Boolean;
begin
  FLock.Acquire;
  try
    Result := FPaused;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SetMessagingProvider(const Provider: IMessagingProvider);
begin
  FLock.Acquire;
  try
    if FWorker <> nil then
      raise EInvalidOpException.Create('Bind messaging while stopped');
    FMessaging := Provider;
    if FMessaging = nil then
      FMessaging := CreateUnavailableMessagingProvider;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetMessagingProvider: IMessagingProvider;
begin
  FLock.Acquire;
  try
    Result := FMessaging;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SetBluetoothProvider(const Provider: IBluetoothProvider);
begin
  FLock.Acquire;
  try
    if FWorker <> nil then
      raise EInvalidOperation.Create('Bind Bluetooth provider while the core is stopped');
    FBluetooth := Provider;
    if FBluetooth = nil then
      FBluetooth := CreateUnavailableBluetoothProvider;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetBluetoothProvider: IBluetoothProvider;
begin
  FLock.Acquire;
  try
    Result := FBluetooth;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.ExecuteVM;
var
  Runtime: TJ2MERuntime;
  Events: TArray<TJ2MEKeyEvent>;
  Event: TJ2MEKeyEvent;
  Paused, WasPaused, AudioFailed, Enabled, WasEnabled: Boolean;
  Frame: TEmulatorFrame;
  Pixels: TArray<UInt32>;
  Playback: TJ2MEAudioPlayback;
  Watch: TStopwatch;
  LastMillis, Millis, Due, Remainder: Int64;
  Samples: TArray<SmallInt>;
  Volume: Single;
  MotorReset, SeenMotorReset: UInt64;

  procedure AudioFailure(const Error: string);
  begin
    FLock.Acquire;
    try
      FAudioError := Error;
    finally
      FLock.Release;
    end;
    FreeAndNil(Playback);
    AudioFailed := True;
  end;

begin
  Runtime := nil;
  Playback := nil;
  WasPaused := False;
  WasEnabled := False;
  AudioFailed := False;
  SeenMotorReset := 0;
  Remainder := 0;
  Watch := TStopwatch.StartNew;
  LastMillis := 0;
  try
    try
      var Screen := FSettings.EffectiveScreen;
      Runtime := TJ2MERuntime.Create(FSuite, Screen.Width, Screen.Height, FBluetooth, FMessaging);
      Runtime.Start(FSettings.MIDletIndex);
      while not TThread.CurrentThread.CheckTerminated do
      begin
        FLock.Acquire;
        try
          Events := FEvents.ToArray;
          FEvents.Clear;
          Paused := FPaused;
          MotorReset := FMotorResetGeneration;
        finally
          FLock.Release;
        end;
        if MotorReset <> SeenMotorReset then
        begin
          Runtime.CancelVibration;
          SeenMotorReset := MotorReset;
        end;
        if Paused <> WasPaused then
        begin
          if Paused then
            Runtime.Pause
          else
            Runtime.Resume;
        end;
        for Event in Events do
          Runtime.KeyEvent(Event.Code, Event.Pressed);
        Runtime.Tick(2000);
        if TThread.CheckTerminated then
          Break;
        var Rumble := Runtime.TakeVibrationSample;
        FLock.Acquire;
        try
          if (MotorReset = FMotorResetGeneration) and not FPaused and not Paused and (Runtime.State in [TJ2MEState.Starting, TJ2MEState.Active]) then
          begin
            FRumbleArea := FRumbleArea + Rumble.Area;
            Inc(FRumbleMillis, Rumble.Millis);
          end
          else
          begin
            FRumbleArea := 0;
            FRumbleMillis := 0;
          end;
        finally
          FLock.Release;
        end;
        var LifecycleError := Runtime.TakeLifecycleError;
        if LifecycleError <> '' then
          raise Exception.Create(LifecycleError);
        Millis := Watch.ElapsedMilliseconds;
        Enabled := FConfig.AudioEnabled;
        Volume := FConfig.AudioVolume;
        if (Paused <> WasPaused) or (Enabled <> WasEnabled) then
        begin
          if Enabled <> WasEnabled then
            AudioFailed := False;
          if Playback <> nil then
          try
            Playback.Clear;
          except
            on E: Exception do
              AudioFailure(E.Message);
          end;
        end;
        if not Paused and not WasPaused then
        begin
          Due := Min(Int64(250), Max(Int64(0), Millis - LastMillis)) * 44100 + Remainder;
          Remainder := Due mod 1000;
          Due := Due div 1000;
          while Due > 0 do
          begin
            var Count := Integer(Min(Int64(2048), Due));
            Samples := Runtime.RenderAudio(Count);
            Dec(Due, Count);
            if Enabled and not AudioFailed then
            try
              if Playback = nil then
                for var S in Samples do
                  if S <> 0 then
                  begin
                    Playback := TJ2MEAudioPlayback.Create(FAudioFactory);
                    Break;
                  end;
              if Playback <> nil then
                Playback.Enqueue(Samples, Volume);
            except
              on E: Exception do
                AudioFailure(E.Message);
            end;
          end;
        end;
        LastMillis := Millis;
        WasPaused := Paused;
        WasEnabled := Enabled;
        var MediaError := Runtime.TakeMediaError;
        if MediaError <> '' then
        begin
          FLock.Acquire;
          try
            FAudioError := MediaError;
          finally
            FLock.Release;
          end;
        end;
        var RMSError := Runtime.TakeRMSError;
        if RMSError <> '' then
        begin
          FLock.Acquire;
          try
            FError := RMSError;
          finally
            FLock.Release;
          end;
        end;
        var MessagingError := Runtime.TakeMessagingError;
        if MessagingError <> '' then
          raise Exception.Create(MessagingError);
        var BluetoothError := Runtime.TakeBluetoothError;
        if BluetoothError <> '' then
        begin
          FLock.Acquire;
          try
            FError := BluetoothError;
          finally
            FLock.Release;
          end;
        end;
        if Runtime.State = TJ2MEState.Faulted then
          raise EJVMError.Create(Runtime.Error);
        if Runtime.State = TJ2MEState.Destroyed then
          Break;
        if Runtime.TakeFrame(Pixels, Frame.FrameNumber) then
        begin
          SetLength(Frame.Pixels, Length(Pixels));
          if Length(Pixels) <> 0 then
            Move(Pixels[0], Frame.Pixels[0], Length(Pixels) * SizeOf(UInt32));
          Frame.Width := Screen.Width;
          Frame.Height := Screen.Height;
          Frame.FramesPerSecond := 60;
          FLock.Acquire;
          try
            FFrame := Frame;
            FFrameReady := True;
          finally
            FLock.Release;
          end;
        end;
        if not Runtime.NeedsExecution then
          TThread.Sleep(1);
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
    FLock.Acquire;
    try
      FRumbleArea := 0;
      FRumbleMillis := 0;
    finally
      FLock.Release;
    end;
    Playback.Free;
    Runtime.Free;
  end;
end;

end.

