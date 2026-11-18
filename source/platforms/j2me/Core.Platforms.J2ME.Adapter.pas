unit Core.Platforms.J2ME.Adapter;

interface

uses
  System.UITypes, Core.Snapshots, System.Diagnostics, System.Hash,
  System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs,
  System.Generics.Collections, Core.Storage, Core.Emulation, J2ME.Suite,
  J2ME.Runtime, Core.Platforms.J2ME.Playback, Core.Bluetooth.Types,
  Core.Messaging.Types, J2ME.Device, J2ME.Screen, J2ME.Display, Core.RomMetadata,
  J2ME.Input, Core.Input.Touch;

type
  TJ2MEConfig = class(TEmulatorConfigBase)
  public
    Width, Height, MIDletIndex: Integer;
    ScreenSize: string;
    ShowResolutionRecommendations: Boolean;
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

  TJ2MECoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationCompletion, IEmulationGameActions, IEmulationAudioDiagnostics, IEmulationBluetooth, IEmulationMessaging, IEmulationRumbleOutput, IEmulationSnapshotLocation, IEmulationRomMetadata, IJ2MEPhoneInput, IJ2MEResolutionAdvice, IEmulationTouchInput)
  private
    FSnapshotCommands: TSnapshotQueue;
    FSnapshotHash: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FSuite: TJ2MESuite;
    FMetadata: IRomMetadata;
    FScreenDecision: TJ2MEScreenDecision;
    FDisplayPlan: TJ2MEDisplayPlan;
    FConfig: IEmulatorConfig;
    FSettings: TJ2MEConfig;
    FWorker: TThread;
    FLock: TCriticalSection;
    FEvents: TQueue<TJ2MEKeyEvent>;
    FTouchEvents: TList<TEmulationTouchEvent>;
    FTouchTracker: TEmulationTouchTracker;
    FUsesTouch, FTouchOverflow, FTouchFit: Boolean;
    FCanvasWidth, FCanvasHeight: Integer;
    FKeyboard: TDictionary<UInt32, Integer>;
    FHeld: TDictionary<Integer, Integer>;
    FInput: TEmulatorInput;
    FVirtualKeypad: Word;
    FFrame: TEmulatorFrame;
    FDisplayQuarterTurns: Integer;
    FAdviceCurrent, FAdviceRecommended: TJ2MEScreenSize;
    FAdviceReady, FAdviceShown, FAdviceSuppressed: Boolean;
    FFrameReady, FPaused, FFinished: Boolean;
    FInputResync: Boolean;
    FError, FAudioError: string;
    FRumbleArea: Double;
    FRumbleMillis: Int64;
    FMotorResetGeneration: UInt64;
    FAudioFactory: TJ2MEAudioFactory;
    FBluetooth: IBluetoothProvider;
    FMessaging: IMessagingProvider;
    function DisplayFrame: TEmulatorFrame; // FLock must be held.
    function ConfiguredScreen: TJ2MEScreenSize;
    procedure PublishFrame(Runtime: TJ2MERuntime; const Pixels: TArray<UInt32>; Number: UInt64);
    procedure ProcessSnapshots(var Runtime: TJ2MERuntime; var Playback: TJ2MEAudioPlayback; var AudioFailed, WasPaused: Boolean; const Watch: TStopwatch; var LastMillis, Remainder: Int64);
    procedure ExecuteVM;
    procedure ChangeHeld(Code: Integer; Pressed: Boolean);
  public
    constructor Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TJ2MEAudioFactory = nil);
    destructor Destroy; override;
    function GetSystemId: string;
    function GetName: string;
    function GetRomMetadata: IRomMetadata;
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
    procedure SetVirtualKeypad(Keys: Word);
    function GetUsesTouch: Boolean;
    procedure SendTouch(const Event: TEmulationTouchEvent);
    function GetInputState: TEmulatorInput;
    function GetSnapshotDirectory: string;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function TakeResolutionAdvice(out Current, Recommended: TJ2MEScreenSize): Boolean;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function IsFinished: Boolean;
    function GetGameActions: TArray<TEmulationGameAction>;
    procedure ExecuteGameAction(const Id: string);
    procedure SetMessagingProvider(const Provider: IMessagingProvider);
    function GetMessagingProvider: IMessagingProvider;
    procedure SetBluetoothProvider(const Provider: IBluetoothProvider);
    function GetBluetoothProvider: IBluetoothProvider;
  end;

implementation

uses
  System.IOUtils, System.Math, Core.SavePaths, JVM.Types, Core.Bluetooth,
  Core.Platforms.Bluetooth, Core.Messaging, J2ME.Compatibility, J2ME.Metadata;

const
  PadCodes: array[TEmulatorButton] of Integer = (-1, -2, -3, -4, -5, 48, -6, -7, 49, 51, 55, 57, 53);

constructor TJ2MEConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  Width := 240;
  Height := 320;
  ScreenSize := 'auto';
  ShowResolutionRecommendations := True;
end;

procedure TJ2MEConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  ShowResolutionRecommendations := Ini.ReadBool('Phone', 'ShowResolutionRecommendations', True);
  Width := EnsureRange(Ini.ReadInteger('Phone', 'Width', 240), 1, 1024);
  Height := EnsureRange(Ini.ReadInteger('Phone', 'Height', 320), 1, 1024);
  MIDletIndex := EnsureRange(Ini.ReadInteger('Phone', 'MIDletIndex', 0), 0, 1023);
  var DefaultSize := 'auto';
  // Width/height-only configurations predate presets and are explicit choices.
  if Ini.ValueExists('Phone', 'Width') or Ini.ValueExists('Phone', 'Height') then
    DefaultSize := 'custom';
  ScreenSize := LowerCase(Trim(Ini.ReadString('Phone', 'ScreenSize', DefaultSize)));
  var Valid := (ScreenSize = 'custom') or (ScreenSize = 'auto');
  for var Size in TJ2MEScreenSize.Presets do
    if ScreenSize = Size.ToString then
      Valid := True;
  if not Valid then
    ScreenSize := 'custom';
end;

procedure TJ2MEConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteBool('Phone', 'ShowResolutionRecommendations', ShowResolutionRecommendations);
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

function TJ2MECoreAdapter.TakeResolutionAdvice(out Current, Recommended: TJ2MEScreenSize): Boolean;
begin
  Current := Default(TJ2MEScreenSize);
  Recommended := Default(TJ2MEScreenSize);
  FLock.Acquire;
  try
    Result := FSettings.ShowResolutionRecommendations and FAdviceReady and
      not FAdviceShown and not FAdviceSuppressed;
    if Result then
    begin
      Current := FAdviceCurrent;
      Recommended := FAdviceRecommended;
      FAdviceShown := True;
    end;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.ConfiguredScreen: TJ2MEScreenSize;
begin
  Result := FScreenDecision.Size;
end;

constructor TJ2MECoreAdapter.Create(Input: TStream; const Storage: IStorage; const RomName: string; const AudioFactory: TJ2MEAudioFactory);
var
  JAD: TBytes;
  JADName, JADError: string;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSnapshotCommands := TSnapshotQueue.Create;
  FAudioFactory := AudioFactory;
  FBluetooth := CreatePlatformBluetoothProvider;
  FMessaging := CreateUnavailableMessagingProvider;
  FEvents := TQueue<TJ2MEKeyEvent>.Create;
  FTouchEvents := TList<TEmulationTouchEvent>.Create;
  FKeyboard := TDictionary<UInt32, Integer>.Create;
  FHeld := TDictionary<Integer, Integer>.Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FSettings := TJ2MEConfig.Create(FStorage.ConfigFile('j2me'), FStorage);
  FConfig := FSettings;
  FConfig.Load;
  JAD := ReadJ2MEJAD(Input, FStorage, RomName, JADName, JADError);
  var Position := Input.Position;
  try
    Input.Position := 0;
    FSnapshotHash := THashSHA2.GetHashBytes(Input);
  finally
    Input.Position := Position;
  end;
  FSnapshotDirectory := FStorage.GameSnapshots('j2me', RomName, THash.DigestAsString(FSnapshotHash));
  FSuite := TJ2MESuite.Open(Input, FStorage, JAD);
  if FSettings.MIDletIndex >= FSuite.MIDletCount then
    raise EReadError.Create('Configured MIDlet index is not present in this suite');
  if FSettings.ScreenSize = 'auto' then
    FScreenDecision := DetectJ2MEScreen(FSuite, THash.DigestAsString(FSnapshotHash),
      FSettings.MIDletIndex, FSettings.EffectiveScreen)
  else
  begin
    FScreenDecision.Size := FSettings.EffectiveScreen;
    FScreenDecision.Source := 'manual';
    FScreenDecision.Evidence := [FSettings.ScreenSize];
  end;
  FDisplayPlan := J2MEDisplayPlan(FSuite, FScreenDecision, FSettings.EffectiveScreen, FSettings.ScreenSize = 'auto');
  FMetadata := J2MERomMetadata(FSuite, RomName, THash.DigestAsString(FSnapshotHash),
    JADName, JADError, FSettings.ScreenSize, FScreenDecision, FDisplayPlan);
end;

procedure TJ2MECoreAdapter.PublishFrame(Runtime: TJ2MERuntime; const Pixels: TArray<UInt32>; Number: UInt64);
begin
  var Size := TJ2MEScreenSize.Create(Runtime.ScreenWidth, Runtime.ScreenHeight);
  var Raster := Pixels;
  if FDisplayPlan.Scaling and Runtime.IsFullscreenCanvas then
  begin
    Raster := J2MEFitDisplay(Pixels, Size, FDisplayPlan.Size);
    Size := FDisplayPlan.Size;
  end;
  var Frame: TEmulatorFrame;
  Frame.FrameNumber := Number;
  Frame.Width := Size.Width;
  Frame.Height := Size.Height;
  Frame.FramesPerSecond := 60;
  Frame.Pixels := TArray<TAlphaColor>(Raster);
  FLock.Acquire;
  try
    FUsesTouch := Runtime.HasTouchCanvas;
    FTouchFit := FDisplayPlan.Scaling and Runtime.IsFullscreenCanvas;
    FCanvasWidth := Runtime.ScreenWidth;
    FCanvasHeight := Runtime.ScreenHeight;
    FFrame := Frame;
    FFrameReady := True;
    if not FAdviceSuppressed and not FAdviceShown then
    begin
      FAdviceReady := Runtime.ScreenRecommendation(FAdviceRecommended);
      FAdviceCurrent := TJ2MEScreenSize.Create(Runtime.ScreenWidth, Runtime.ScreenHeight);
    end;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.GetRomMetadata: IRomMetadata;
begin
  Result := FMetadata;
end;

destructor TJ2MECoreAdapter.Destroy;
begin
  Stop;
  FSnapshotCommands.Free;
  FSuite.Free;
  FHeld.Free;
  FKeyboard.Free;
  FEvents.Free;
  FTouchEvents.Free;
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
  Result := True;
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
  FFinished := False;
  FError := '';
  FAudioError := '';
  FFrameReady := False;
  FLock.Acquire;
  try
    FRumbleArea := 0;
    FRumbleMillis := 0;
    FMotorResetGeneration := 0;
    FUsesTouch := False;
    FTouchEvents.Clear;
    FTouchTracker := Default(TEmulationTouchTracker);
    FTouchOverflow := False;
    FAdviceReady := False;
    FAdviceShown := False;
    FAdviceSuppressed := False;
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
  ClearInput;
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
  if FEvents.Count >= 1024 then
  begin
    FEvents.Clear;
    FInputResync := True;
  end;
  FEvents.Enqueue(Event);
end;

function TJ2MECoreAdapter.GetUsesTouch: Boolean;
begin
  FLock.Acquire;
  try
    Result := FUsesTouch;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.SendTouch(const Event: TEmulationTouchEvent);
begin
  if Event.Contact <> 0 then
    Exit;
  FLock.Acquire;
  try
    if FTouchOverflow then
    begin
      if Event.Phase in [TEmulationTouchPhase.Up, TEmulationTouchPhase.Cancel] then
        FTouchOverflow := False;
      Exit;
    end;
    var X := 0;
    var Y := 0;
    var Valid := FUsesTouch and not FPaused and
      MapEmulationTouch(Event.X, Event.Y, FFrame.Width, FFrame.Height, FDisplayQuarterTurns,
      FCanvasWidth, FCanvasHeight, FTouchFit, X, Y);
    var Mapped: TEmulationTouchEvent;
    if not FTouchTracker.Update(Event.Phase, X, Y, Valid, Mapped) then
      Exit;
    if (Mapped.Phase = TEmulationTouchPhase.Move) and (FTouchEvents.Count > 0) and
      (FTouchEvents.Last.Phase = TEmulationTouchPhase.Move) then
      FTouchEvents[FTouchEvents.Count - 1] := Mapped
    else if FTouchEvents.Count < 256 then
      FTouchEvents.Add(Mapped)
    else
    begin
      // Bound hostile producers without dropping a release and sticking down.
      FTouchEvents.Clear;
      FTouchTracker := Default(TEmulationTouchTracker);
      Mapped.Phase := TEmulationTouchPhase.Cancel;
      FTouchEvents.Add(Mapped);
      FTouchOverflow := not (Event.Phase in [TEmulationTouchPhase.Up, TEmulationTouchPhase.Cancel]);
    end;
  finally
    FLock.Release;
  end;
end;

procedure TJ2MECoreAdapter.ClearInput;
var
  Event: TJ2MEKeyEvent;
  Code: Integer;
begin
  FLock.Acquire;
  try
    FEvents.Clear;
    FTouchEvents.Clear;
    FTouchTracker := Default(TEmulationTouchTracker);
    FTouchOverflow := False;
    var Cancel := Default(TEmulationTouchEvent);
    Cancel.Phase := TEmulationTouchPhase.Cancel;
    FTouchEvents.Add(Cancel);
    for Code in FHeld.Keys do
    begin
      Event.Code := Code;
      Event.Pressed := False;
      FEvents.Enqueue(Event);
    end;
    FHeld.Clear;
    FKeyboard.Clear;
    FInput := Default(TEmulatorInput);
    FVirtualKeypad := 0;
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

procedure TJ2MECoreAdapter.SetVirtualKeypad(Keys: Word);
begin
  Keys := Keys and J2MEKeypadMask;
  FLock.Acquire;
  try
    for var I := Low(J2MEKeypadCodes) to High(J2MEKeypadCodes) do
      if ((Keys xor FVirtualKeypad) and (Word(1) shl I)) <> 0 then
        ChangeHeld(J2MEKeypadCodes[I], (Keys and (Word(1) shl I)) <> 0);
    FVirtualKeypad := Keys;
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
  FSnapshotCommands.Execute(FWorker, Name, False);
end;

procedure TJ2MECoreAdapter.LoadSnapshot(const Name: string);
begin
  // Suppress before the worker can publish any frame of the restored run.
  FLock.Acquire;
  try
    FAdviceSuppressed := True;
    FAdviceReady := False;
  finally
    FLock.Release;
  end;
  FSnapshotCommands.Execute(FWorker, Name, True);
end;

function TJ2MECoreAdapter.DisplayFrame: TEmulatorFrame;
begin
  Result := FFrame;
  if Length(Result.Pixels) = 0 then
    Exit;
  Result.Pixels := TArray<TAlphaColor>(J2MERotateDisplay(TArray<UInt32>(FFrame.Pixels), FFrame.Width, FFrame.Height, FDisplayQuarterTurns));
  if Odd(FDisplayQuarterTurns) then
  begin
    Result.Width := FFrame.Height;
    Result.Height := FFrame.Width;
  end;
end;

function TJ2MECoreAdapter.GetGameActions: TArray<TEmulationGameAction>;
begin
  SetLength(Result, 1);
  Result[0].Id := 'rotate-screen';
  Result[0].Caption := 'Rotate screen';
  Result[0].Enabled := True;
end;

procedure TJ2MECoreAdapter.ExecuteGameAction(const Id: string);
begin
  if Id <> 'rotate-screen' then
    raise EArgumentException.Create('Unknown Java ME game action');
  ClearInput;
  FLock.Acquire;
  try
    FDisplayQuarterTurns := (FDisplayQuarterTurns + 1) mod 4;
    // Republish the current raster even when the VM is paused or finished.
    FFrameReady := Length(FFrame.Pixels) > 0;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FFrameReady;
    if Result then
    begin
      Frame := DisplayFrame;
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
    Result := FPaused or FFinished;
  finally
    FLock.Release;
  end;
end;

function TJ2MECoreAdapter.IsFinished: Boolean;
begin
  FLock.Acquire;
  try
    Result := FFinished;
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
  TouchEvents: TArray<TEmulationTouchEvent>;
  Event: TJ2MEKeyEvent;
  Paused, WasPaused, AudioFailed, Enabled, WasEnabled, Resync: Boolean;
  DesiredKeys: TArray<Integer>;
  Frame: TEmulatorFrame;
  Pixels: TArray<UInt32>;
  Playback: TJ2MEAudioPlayback;
  Watch: TStopwatch;
  LastMillis, Millis, Due, Remainder, AudioRetryAt: Int64;
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
    AudioRetryAt := Watch.ElapsedMilliseconds + 1000;
  end;

begin
  Runtime := nil;
  Playback := nil;
  WasPaused := False;
  WasEnabled := False;
  AudioFailed := False;
  SeenMotorReset := 0;
  Remainder := 0;
  AudioRetryAt := 0;
  Watch := TStopwatch.StartNew;
  LastMillis := 0;
  try
    try
      var Screen := ConfiguredScreen;
      Runtime := TJ2MERuntime.Create(FSuite, Screen.Width, Screen.Height, FBluetooth, FMessaging);
      Runtime.Start(FSettings.MIDletIndex);
      while not TThread.CurrentThread.CheckTerminated do
      begin
        ProcessSnapshots(Runtime, Playback, AudioFailed, WasPaused, Watch, LastMillis, Remainder);
        // Keep servicing save/load requests after a normal guest exit.
        if Runtime.State = TJ2MEState.Destroyed then
        begin
          TThread.Sleep(10);
          Continue;
        end;
        FLock.Acquire;
        try
          Resync := FInputResync;
          FInputResync := False;
          DesiredKeys := nil;
          if Resync then
          begin
            DesiredKeys := FHeld.Keys.ToArray;
            FEvents.Clear;
            Events := nil;
          end
          else
          begin
            SetLength(Events, Min(32, FEvents.Count));
            for var I := 0 to High(Events) do
              Events[I] := FEvents.Dequeue;
          end;
          TouchEvents := FTouchEvents.ToArray;
          FTouchEvents.Clear;
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
        // A cancellation is also delivered while host-paused. Its Java release
        // stays queued until execution resumes, before any fresh press.
        for var Touch in TouchEvents do
          if not Paused or (Touch.Phase = TEmulationTouchPhase.Cancel) then
            Runtime.PointerEvent(Touch);
        if Paused <> WasPaused then
        begin
          Runtime.SetExecutionPaused(Paused);
          if Playback <> nil then
          try
            Playback.SetPaused(Paused);
          except
            on E: Exception do
              AudioFailure(E.Message);
          end;
        end;
        if not Paused then
        begin
          if Resync then
          begin
            Runtime.ReleasePhysicalKeys;
            for var Key in DesiredKeys do
              Runtime.KeyEvent(Key, True);
          end;
          for Event in Events do
            Runtime.KeyEvent(Event.Code, Event.Pressed);
        end;
        // Device backpressure applies only to advancing the mixer below.
        // A full PCM FIFO may stay full while healthy playback continues;
        // gating Java here can starve it forever until pause clears the FIFO.
        Runtime.Tick(2000);
        if TThread.CheckTerminated then
          Break;
        if Runtime.State = TJ2MEState.Destroyed then
        begin
          var ExitError := Runtime.TakeLifecycleError;
          if ExitError <> '' then
            raise Exception.Create(ExitError);
          FreeAndNil(Playback);
          ClearInput;
          FLock.Acquire;
          try
            FFinished := True;
            FRumbleArea := 0;
            FRumbleMillis := 0;
          finally
            FLock.Release;
          end;
          Continue;
        end;
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
        if AudioFailed and (Millis >= AudioRetryAt) then
          AudioFailed := False;
        Enabled := FConfig.AudioEnabled;
        Volume := FConfig.AudioVolume;
        if Enabled <> WasEnabled then
        begin
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
          Due := Min(Int64(11025), Due div 1000);
          var Batch := 1;
          {$IFDEF ANDROID}
          if Enabled and not AudioFailed then
            Batch := TJ2MEAudioPlayback.AudioFormat.BlockFrames;
          {$ENDIF}
          while Due >= Batch do
          begin
            var Count := Integer(Min(Int64(2048), Due));
            {$IFDEF ANDROID}
            if Batch > 1 then
              Count := Batch;
            {$ENDIF}
            if Enabled and not AudioFailed and (Playback <> nil) then
            try
              Count := Min(Count, Playback.AvailableFrames);
            except
              on E: Exception do
                AudioFailure(E.Message);
            end;
            Count := Count div Batch * Batch;
            if Count = 0 then
              Break;
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
                if Playback.Enqueue(Samples, Volume) <> Count then
                  raise EInvalidOpException.Create('Audio producer exceeded available capacity');
            except
              on E: Exception do
                AudioFailure(E.Message);
            end;
            {$IFDEF ANDROID}
            // Give the VM another slice during catch-up instead of rendering
            // an entire accumulated backlog in one turn.
            if (Batch > 1) and (Watch.ElapsedMilliseconds - Millis >= 10) then
              Break;
            {$ENDIF}
          end;
          // Retain partially accumulated blocks and PCM deferred by buffer pressure.
          Inc(Remainder, Due * 1000);
        end;
        if Paused or WasPaused then
          Remainder := 0;
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
        if Runtime.TakeFrame(Pixels, Frame.FrameNumber) then
          PublishFrame(Runtime, Pixels, Frame.FrameNumber);
        if not Runtime.NeedsExecution then
          TThread.Sleep(1);
      end;
    except
      on E: Exception do
      begin
        FLock.Acquire;
        try
          if not TThread.CheckTerminated then
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

function TJ2MECoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TJ2MECoreAdapter.ProcessSnapshots(var Runtime: TJ2MERuntime; var Playback: TJ2MEAudioPlayback; var AudioFailed, WasPaused: Boolean; const Watch: TStopwatch; var LastMillis, Remainder: Int64);
begin
  var LocalRuntime := Runtime;
  var LocalPlayback := Playback;
  var LocalAudioFailed := AudioFailed;
  var LocalWasPaused := WasPaused;
  var LocalWatch := Watch;
  var LocalLastMillis := LastMillis;
  var LocalRemainder := Remainder;
  FSnapshotCommands.Process(
    procedure(const Name: string; Loading: Boolean)
    var
      Candidate: TJ2MERuntime;
    begin
      Candidate := nil;
      try
        var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
        var Transfer: TStateTransfer :=
          procedure(State: TStateArchive)
          begin
            var Buffer := TMemoryStream.Create;
            try
              var Size := 0;
              if not State.Loading then
              begin
                if LocalRuntime.State = TJ2MEState.Destroyed then
                begin
                  // Rebuild before the first instruction, with current persistent
                  // RMS data. Never serialize the dead VM or start the game here.
                  var Screen := ConfiguredScreen;
                  var Fresh := TJ2MERuntime.Create(FSuite, Screen.Width, Screen.Height, FBluetooth, FMessaging);
                  try
                    Fresh.Start(FSettings.MIDletIndex);
                    Fresh.SaveState(Buffer);
                  finally
                    Fresh.Free;
                  end;
                end
                else
                  LocalRuntime.SaveState(Buffer);
                Size := Buffer.Size;
              end;
              State.Field(Size, SizeOf(Size));
              if (Size <= 0) or (Size > 256 * 1024 * 1024 - 8) then
                raise EReadError.Create('Java ME snapshot size limit');
              if State.Loading then
                Buffer.Size := Size;
              State.Field(Buffer.Memory^, Size);
              if State.Loading then
              begin
                Buffer.Position := 0;
                FreeAndNil(Candidate);
                Candidate := TJ2MERuntime.LoadState(FSuite, Buffer, FBluetooth, FMessaging, True);
              end;
            finally
              Buffer.Free;
            end;
          end;
        if Loading then
        begin
          LoadCoreSnapshotHash(Path, 'J2ME', FSnapshotHash, Transfer, FStorage);
          if FSettings.ScreenSize = 'auto' then
            MigrateJ2MECompatibilityScreen(THash.DigestAsString(FSnapshotHash), Candidate, FScreenDecision.Size);
          // Reconstruction and checksum validation have finished. Only now may
          // the game/RMS state change; a rejected file leaves the old VM alive.
          Candidate.CommitRestoredState;
          var Previous := LocalRuntime;
          LocalRuntime := Candidate;
          Candidate := nil;
          Previous.Free;
          FreeAndNil(LocalPlayback);
          LocalAudioFailed := False;
          ClearInput;
          LocalRuntime.ReleasePhysicalKeys;
          FLock.Acquire;
          try
            FEvents.Clear;
            FAudioError := '';
            FError := '';
            FFinished := LocalRuntime.State = TJ2MEState.Destroyed;
            FRumbleArea := 0;
            FRumbleMillis := 0;
            LocalWasPaused := FPaused;
          finally
            FLock.Release;
          end;
          // Previous adapter versions serialized emulator pause as a MIDlet
          // lifecycle request. Retain their resume path for those legacy states.
          if LocalRuntime.LifecyclePauseRequested then
            LocalRuntime.Resume;
          var Pixels: TArray<UInt32>;
          var Frame: TEmulatorFrame;
          if LocalRuntime.TakeFrame(Pixels, Frame.FrameNumber) then
            PublishFrame(LocalRuntime, Pixels, Frame.FrameNumber);
          // Storage, display migration and frame publication are host work.
          LocalRuntime.SetExecutionPaused(LocalWasPaused);
          LocalLastMillis := LocalWatch.ElapsedMilliseconds;
          LocalRemainder := 0;
        end
        else
        begin
          SaveCoreSnapshotHash(Path, 'J2ME', FSnapshotHash, Transfer, FStorage);
          FLock.Acquire;
          try
            var Preview := DisplayFrame;
            if Length(Preview.Pixels) > 0 then
              SaveSnapshotPreview(Path, Preview.Width, Preview.Height, Preview.Width, @Preview.Pixels[0], FStorage);
          finally
            FLock.Release;
          end;
          LocalLastMillis := LocalWatch.ElapsedMilliseconds;
        end;
      finally
        Candidate.Free;
      end;
    end);
  Runtime := LocalRuntime;
  Playback := LocalPlayback;
  AudioFailed := LocalAudioFailed;
  WasPaused := LocalWasPaused;
  LastMillis := LocalLastMillis;
  Remainder := LocalRemainder;
end;

initialization
  RegisterSnapshotPolicy('J2ME', TSnapshotPolicy.Create(1, 256 * 1024 * 1024));

end.

