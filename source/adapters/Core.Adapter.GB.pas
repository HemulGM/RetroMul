unit Core.Adapter.GB;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage,
  Core.InputConfig, Core.Emulation, GB.EmulationThread, GB.Joypad, GB.GPU,
  GB.Camera, GB.Memory, GB.Palettes;

type
  TGBKeyMap = record
    A, B, Select, Start, Up, Down, Left, Right: UInt32;
  end;

  IGBEmulatorConfig = interface(IEmulatorConfig)
    ['{F92F710A-091C-4D32-9C97-369476030FB1}']
    function GetKeys: TGBKeyMap;
    procedure SetKeys(const Value: TGBKeyMap);
    property Keys: TGBKeyMap read GetKeys write SetKeys;
    function GetRumbleEnabled: Boolean;
    procedure SetRumbleEnabled(Value: Boolean);
    property RumbleEnabled: Boolean read GetRumbleEnabled write SetRumbleEnabled;
    function GetBootModel: TGBBootModel;
    procedure SetBootModel(Value: TGBBootModel);
    function GetBootROMFile(Model: TGBBootModel): string;
    procedure SetBootROMFile(Model: TGBBootModel; const Value: string);
    property BootModel: TGBBootModel read GetBootModel write SetBootModel;
    function GetRuntimeOptions: TGBRuntimeOptions;
    procedure SetRuntimeOptions(const Value: TGBRuntimeOptions);
    property RuntimeOptions: TGBRuntimeOptions read GetRuntimeOptions write SetRuntimeOptions;
    function GetScreenPalette: Integer;
    procedure SetScreenPalette(const Value: Integer);
    property ScreenPalette: Integer read GetScreenPalette write SetScreenPalette;
  end;

  TGBEmulatorConfig = class(TEmulatorConfigBase, IGBEmulatorConfig)
  private
    FKeys: TGBKeyMap;
    FScreenPalette: Integer;
    FRuntimeOptions: TGBRuntimeOptions;
    FRumbleEnabled: Boolean;
    FBootModel: TGBBootModel;
    FBootROMFiles: array[TGBBootModel] of string;
  protected
    procedure LoadControls(Ini: TCustomIniFile);
    procedure SaveControls(Ini: TCustomIniFile);
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const AFileName: string; const Storage: IStorage = nil);
    function GetKeys: TGBKeyMap;
    procedure SetKeys(const Value: TGBKeyMap);

    function GetRumbleEnabled: Boolean;
    procedure SetRumbleEnabled(Value: Boolean);
    property RumbleEnabled: Boolean read GetRumbleEnabled write SetRumbleEnabled;
    function GetBootModel: TGBBootModel;
    procedure SetBootModel(Value: TGBBootModel);
    function GetBootROMFile(Model: TGBBootModel): string;
    procedure SetBootROMFile(Model: TGBBootModel; const Value: string);
    property BootModel: TGBBootModel read GetBootModel write SetBootModel;
    function GetRuntimeOptions: TGBRuntimeOptions;
    procedure SetRuntimeOptions(const Value: TGBRuntimeOptions);
    property RuntimeOptions: TGBRuntimeOptions read GetRuntimeOptions write SetRuntimeOptions;
    function GetScreenPalette: Integer;
    procedure SetScreenPalette(const Value: Integer);
  end;

  TGBCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IGBCameraInput, IEmulationMotionInput, IEmulationRumbleOutput)
  protected
    FThread: TGBEmulationThread;
    FColorHardware: Boolean;
    FBootROMData: TBytes;
    FCameraSource: IGBCameraFrameSource;
    FHasAccelerometer, FHasRumble: Boolean;
    FAccelerationX, FAccelerationY: Double;
    FSnapshotDirectory: string;
    FSavePath: string;
    FStorage: IStorage;
    FROMData: TArray<Byte>;
    FGamepadInput: TEmulatorInput;
    FKeyboardInput: TEmulatorInput;
    FControllerEnabled: Boolean;
    FConfig: IGBEmulatorConfig;
    FFrameNumber: UInt64;
    procedure CreateThread;
    procedure ApplyInput;
    function ConfigPrefix: string; virtual;
    function CreateConfig(const FileName: string): IGBEmulatorConfig; virtual;
    function CreateWorker: TGBEmulationThread; virtual;
    procedure CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame); virtual;
    function GetSystemId: string;
    function GetName: string; virtual;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
  public
    procedure ApplyLiveSettings;
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string); overload;
    destructor Destroy; override;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    function GetSnapshotDirectory: string;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetHasRumble: Boolean;
    function GetRumbleLevel: Byte;
    function GetHasAccelerometer: Boolean;
    procedure SetAcceleration(X, Y: Double);
    function GetHasCamera: Boolean;
    procedure SubmitCameraFrame(const Frame: TGBCameraFrame);
  end;

implementation

uses
  Core.RomFormat, Core.Snapshots, Core.SavePaths, System.Math, System.UITypes,
  GB.ROM, GB.MBC, GBC.EmulationThread;

procedure TGBCoreAdapter.ApplyLiveSettings;
begin
  if FThread = nil then
    Exit;
  FThread.ScreenPalette := FConfig.ScreenPalette;
  FThread.RuntimeOptions := FConfig.RuntimeOptions;
  FThread.SoundVolume := FConfig.AudioVolume;
end;

function TGBCoreAdapter.GetHasRumble: Boolean;
begin
  Result := FHasRumble;
end;

function TGBCoreAdapter.GetRumbleLevel: Byte;
begin
  Result := 0;
  if FHasRumble and FConfig.RumbleEnabled and (FThread <> nil) then
    Result := FThread.GetRumbleLevel;
end;

function TGBCoreAdapter.GetHasAccelerometer: Boolean;
begin
  Result := FHasAccelerometer;
end;

procedure TGBCoreAdapter.SetAcceleration(X, Y: Double);
begin
  FAccelerationX := X;
  FAccelerationY := Y;
  if FThread <> nil then
    FThread.SetAcceleration(X, Y);
end;

function TGBCoreAdapter.GetHasCamera: Boolean;
begin
  Result := FCameraSource <> nil;
end;

procedure TGBCoreAdapter.SubmitCameraFrame(const Frame: TGBCameraFrame);
begin
  if not GetHasCamera then
    raise ENotSupportedException.Create('Cartridge has no camera');

  FCameraSource.SubmitFrame(Frame);
end;

function TGBCoreAdapter.ConfigPrefix: string;
begin
  Result := ROM_SYSTEM_GB;
end;

function TGBCoreAdapter.CreateConfig(const FileName: string): IGBEmulatorConfig;
begin
  Result := TGBEmulatorConfig.Create(FileName, FStorage);
end;

function TGBCoreAdapter.CreateWorker: TGBEmulationThread;
begin
  if FColorHardware then
    Result := TGBCEmulationThread.Create(FROMData, FConfig.AudioEnabled, FCameraSource)
  else
    Result := TGBEmulationThread.Create(FROMData, FConfig.AudioEnabled, FCameraSource);
end;

procedure TGBCoreAdapter.CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame);
begin
  var Options := FConfig.RuntimeOptions;
  var Palette := FConfig.ScreenPalette;
  for var i := 0 to High(Screen) do
    Frame.Pixels[i] := Options.PresentationColor(Screen[i], Palette, FColorHardware);
end;

constructor TGBCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

constructor TGBCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FConfig := CreateConfig(FStorage.ConfigFile(ConfigPrefix));
  FConfig.Load;
  FControllerEnabled := LoadCoreInputPorts(FStorage, ConfigPrefix).Devices[0] <> 'none';
  var ROM := TGBROM.Create;
  try
    ROM.ReadROM(Stream);
    FROMData := ROM.ImageData;
    if ROM.GetCartridgeType.MapperType = TMapperType.PocketCamera then
      FCameraSource := TGBCameraFrameSource.Create;
    FHasAccelerometer := ROM.GetCartridgeType.HasAccelerometer;
    FHasRumble := (ROM.GetCartridgeType.MapperType = TMapperType.MBC5) and
      ROM.GetCartridgeType.HasRumble;
    FColorHardware := ConfigPrefix = ROM_SYSTEM_GBC;
    if FConfig.BootModel <> TGBBootModel.Skip then
    begin
      FColorHardware := GBBootUsesColor(FConfig.BootModel);
      if ROM.Cartridge.CGBOnly and not FColorHardware then
        raise ENotSupportedException.Create('This cartridge requires a color boot ROM model');

      var BootFile := FConfig.GetBootROMFile(FConfig.BootModel);
      var BootData: TBytes;
      if BootFile <> '' then
      begin
        var BootStream := FStorage.OpenRead(BootFile);
        try
          SetLength(BootData, $901);
          var Count := 0;
          while Count < Length(BootData) do
          begin
            var N := BootStream.Read(BootData[Count], Length(BootData) - Count);
            if N = 0 then
              Break;

            Inc(Count, N);
          end;
          if Count = 0 then
            raise EReadError.Create('Boot ROM file is empty');

          SetLength(BootData, Count);
        finally
          BootStream.Free;
        end;
      end;
      if (BootFile = '') and not (FConfig.BootModel in [TGBBootModel.DMG, TGBBootModel.MGB]) then
        raise EReadError.Create('Select a boot ROM file for ' + GB_BOOT_MODEL_LABELS[FConfig.BootModel]);

      FBootROMData := PrepareGBBootROM(FConfig.BootModel, BootData);
    end;

    // Validate mapper support before the frontend replaces the active session.
    TGBMBC.Create(ROM).Free;
  finally
    ROM.Free;
  end;
  FSnapshotDirectory := FStorage.GameSnapshots(ConfigPrefix, RomName, SnapshotIdentity(FROMData));
  FSavePath := FStorage.GameSave(ConfigPrefix, RomName, SnapshotIdentity(FROMData));
  CreateThread;
end;

procedure TGBCoreAdapter.CreateThread;
begin
  FThread := CreateWorker;
  FThread.ConfigureBootROM(FConfig.BootModel, FBootROMData);
  FThread.Storage := FStorage;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.SavePath := FSavePath;
  FThread.ScreenPalette := FConfig.ScreenPalette;
  FThread.RuntimeOptions := FConfig.RuntimeOptions;
  FThread.SoundVolume := FConfig.AudioVolume;
  FThread.SetAcceleration(FAccelerationX, FAccelerationY);
end;

destructor TGBCoreAdapter.Destroy;
begin
  Stop;
  FThread.Free;
  inherited;
end;

function TGBCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  if not FControllerEnabled then
    Exit;

  Result.Buttons := (FGamepadInput.Buttons + FKeyboardInput.Buttons) * [TEmulatorButton.Up..TEmulatorButton.Start];
end;

procedure TGBCoreAdapter.ApplyInput;
const
  ButtonKeys: array[TEmulatorButton.Up..TEmulatorButton.Start] of TGBKey =
    (TGBKey.Up, TGBKey.Down, TGBKey.Left, TGBKey.Right,
    TGBKey.A, TGBKey.B, TGBKey.Select, TGBKey.Start);
begin
  for var Button := Low(ButtonKeys) to High(ButtonKeys) do
    FThread.SetKeyState(ButtonKeys[Button],
      FControllerEnabled and ((Button in FGamepadInput.Buttons) or (Button in FKeyboardInput.Buttons)));
end;

procedure TGBCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FControllerEnabled := Ports.Devices[0] <> 'none';
  ClearInput;
end;

procedure TGBCoreAdapter.ClearInput;
begin
  FGamepadInput := Default(TEmulatorInput);
  FKeyboardInput := Default(TEmulatorInput);
  FThread.ReleaseKeys;
end;

function TGBCoreAdapter.GetSystemId: string;
begin
  Result := ConfigPrefix;
end;

function TGBCoreAdapter.GetName: string;
begin
  Result := 'Game Boy';
end;

function TGBCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TGBCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TGBCoreAdapter.InsertCoin1;
begin
end;

procedure TGBCoreAdapter.InsertCoin2;
begin
end;

function TGBCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TGBCoreAdapter.IsPaused: Boolean;
begin
  Result := FThread.PauseRequested;
end;

procedure TGBCoreAdapter.LoadSnapshot(const Name: string);
begin
  FThread.LoadSnapshot(Name);
end;

procedure TGBCoreAdapter.Pause;
begin
  FThread.RequestPause;
end;

procedure TGBCoreAdapter.Reset;
begin
  // The Game Boy core has no in-place reset path. Recreate its worker so all
  // singleton CPU, GPU and memory state is returned to the power-on state.
  FreeAndNil(FThread);
  CreateThread;
  FFrameNumber := 0;
  FThread.Start;
  ApplyInput;
end;

procedure TGBCoreAdapter.Resume;
begin
  FThread.RequestResume;
end;

function TGBCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TGBCoreAdapter.SaveSnapshot(const Name: string);
begin
  FThread.ScreenPalette := FConfig.ScreenPalette;
  FThread.RuntimeOptions := FConfig.RuntimeOptions;
  FThread.SoundVolume := FConfig.AudioVolume;
  FThread.SaveSnapshot(Name);
end;

procedure TGBCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepadInput := Input;
  ApplyInput;
end;

procedure TGBCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  var Keys := FConfig.Keys;
  if Code = Keys.A then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.A)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.A);
  if Code = Keys.B then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.B)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.B);
  if Code = Keys.Select then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Select)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Select);
  if Code = Keys.Start then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Start)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Start);
  if Code = Keys.Up then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Up)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Up);
  if Code = Keys.Down then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Down)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Down);
  if Code = Keys.Left then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Left)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Left);
  if Code = Keys.Right then
    if Pressed then
      Include(FKeyboardInput.Buttons, TEmulatorButton.Right)
    else
      Exclude(FKeyboardInput.Buttons, TEmulatorButton.Right);
  ApplyInput;
end;

procedure TGBCoreAdapter.Start;
begin
  // GB and GBC share this lifecycle. A pause request must survive Start,
  // including repeated calls after the worker has already been launched.
  if (FThread <> nil) and FThread.Suspended and not FThread.Finished then
    FThread.Start;
end;

procedure TGBCoreAdapter.Stop;
begin
  if (FThread <> nil) and not FThread.Finished then
  begin
    FThread.RequestStop;
    // Match other cores: returning from Stop means no further emulation work.
    // A never-started worker exits immediately once released after termination.
    if FThread.Suspended then
      FThread.Start;
    FThread.WaitFor;
  end;
end;

function TGBCoreAdapter.TakeError: string;
begin
  Result := FThread.TakeError;
end;

function TGBCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TGBCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
var
  Screen, Previous: TScreenArray;
  HasPrevious: Boolean;
  FramesPerSecond: Double;
begin
  // Palette changes also republish the last frame while the worker is paused.
  FThread.ScreenPalette := FConfig.ScreenPalette;
  FThread.RuntimeOptions := FConfig.RuntimeOptions;
  FThread.SoundVolume := FConfig.AudioVolume;
  Result := FThread.TryGetFrame(Screen, Previous, HasPrevious, FramesPerSecond);
  if not Result then
    Exit;

  Frame.Width := 160;
  Frame.Height := 144;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  CopyFrame(Screen, Frame);
  if FConfig.RuntimeOptions.FrameBlending and HasPrevious then
  begin
    var PreviousFrame: TEmulatorFrame;
    SetLength(PreviousFrame.Pixels, Length(Frame.Pixels));
    CopyFrame(Previous, PreviousFrame);
    for var i := 0 to High(Frame.Pixels) do
      Frame.Pixels[i] := GBBlendColor(Frame.Pixels[i], PreviousFrame.Pixels[i]);
  end;
  Inc(FFrameNumber);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := FramesPerSecond;
end;

{ TGBEmulatorConfig }

constructor TGBEmulatorConfig.Create(const AFileName: string; const Storage: IStorage);
begin
  inherited Create(AFileName, Storage);
  FRumbleEnabled := True;
  FKeys.A := vkZ;
  FKeys.B := vkX;
  FKeys.Select := vkSpace;
  FKeys.Start := vkReturn;
  FKeys.Up := vkUp;
  FKeys.Down := vkDown;
  FKeys.Left := vkLeft;
  FKeys.Right := vkRight;
  FScreenPalette := 0;
  FRuntimeOptions := TGBRuntimeOptions.Defaults;
end;

function TGBEmulatorConfig.GetRumbleEnabled: Boolean;
begin
  Result := FRumbleEnabled;
end;

procedure TGBEmulatorConfig.SetRumbleEnabled(Value: Boolean);
begin
  FRumbleEnabled := Value;
end;

function TGBEmulatorConfig.GetBootModel: TGBBootModel;
begin
  Result := FBootModel;
end;

procedure TGBEmulatorConfig.SetBootModel(Value: TGBBootModel);
begin
  FBootModel := Value;
end;

function TGBEmulatorConfig.GetBootROMFile(Model: TGBBootModel): string;
begin
  Result := FBootROMFiles[Model];
end;

procedure TGBEmulatorConfig.SetBootROMFile(Model: TGBBootModel; const Value: string);
begin
  FBootROMFiles[Model] := Value;
end;

procedure TGBEmulatorConfig.LoadControls(Ini: TCustomIniFile);
begin
  FKeys.A := ReadEmulatorKey(Ini, 'Controls', 'A', FKeys.A);
  FKeys.B := ReadEmulatorKey(Ini, 'Controls', 'B', FKeys.B);
  FKeys.Select := ReadEmulatorKey(Ini, 'Controls', 'Select', FKeys.Select);
  FKeys.Start := ReadEmulatorKey(Ini, 'Controls', 'Start', FKeys.Start);
  FKeys.Up := ReadEmulatorKey(Ini, 'Controls', 'Up', FKeys.Up);
  FKeys.Down := ReadEmulatorKey(Ini, 'Controls', 'Down', FKeys.Down);
  FKeys.Left := ReadEmulatorKey(Ini, 'Controls', 'Left', FKeys.Left);
  FKeys.Right := ReadEmulatorKey(Ini, 'Controls', 'Right', FKeys.Right);
end;

procedure TGBEmulatorConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  LoadControls(Ini);
  FRuntimeOptions.Load(Ini);
  FRumbleEnabled := Ini.ReadBool('Peripherals', 'Rumble', True);
  FBootModel := GBBootModel(Ini.ReadString('Boot', 'Model', 'none'));
  for var Model := Low(TGBBootModel) to High(TGBBootModel) do
    FBootROMFiles[Model] := Ini.ReadString('Boot', GB_BOOT_MODEL_KEYS[Model] + 'File', '');
  FScreenPalette := EnsureRange(Ini.ReadInteger('Video', 'Palette', 0), 0, SCREEN_PALETTE_COUNT - 1);
end;

procedure TGBEmulatorConfig.SaveControls(Ini: TCustomIniFile);
begin
  Ini.WriteInteger('Controls', 'A', FKeys.A);
  Ini.WriteInteger('Controls', 'B', FKeys.B);
  Ini.WriteInteger('Controls', 'Select', FKeys.Select);
  Ini.WriteInteger('Controls', 'Start', FKeys.Start);
  Ini.WriteInteger('Controls', 'Up', FKeys.Up);
  Ini.WriteInteger('Controls', 'Down', FKeys.Down);
  Ini.WriteInteger('Controls', 'Left', FKeys.Left);
  Ini.WriteInteger('Controls', 'Right', FKeys.Right);
end;

procedure TGBEmulatorConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  SaveControls(Ini);
  FRuntimeOptions.Save(Ini);
  Ini.WriteBool('Peripherals', 'Rumble', FRumbleEnabled);
  Ini.WriteString('Boot', 'Model', GB_BOOT_MODEL_KEYS[FBootModel]);
  for var Model := Low(TGBBootModel) to High(TGBBootModel) do
    Ini.WriteString('Boot', GB_BOOT_MODEL_KEYS[Model] + 'File', FBootROMFiles[Model]);
  Ini.WriteInteger('Video', 'Palette', FScreenPalette);
end;

function TGBEmulatorConfig.GetRuntimeOptions: TGBRuntimeOptions;
begin
  Result := FRuntimeOptions;
end;

procedure TGBEmulatorConfig.SetRuntimeOptions(const Value: TGBRuntimeOptions);
begin
  FRuntimeOptions := Value;
  FRuntimeOptions.Normalize;
end;

function TGBEmulatorConfig.GetKeys: TGBKeyMap;
begin
  Result := FKeys;
end;

function TGBEmulatorConfig.GetScreenPalette: Integer;
begin
  Result := FScreenPalette;
end;

procedure TGBEmulatorConfig.SetKeys(const Value: TGBKeyMap);
begin
  FKeys := Value;
end;

procedure TGBEmulatorConfig.SetScreenPalette(const Value: Integer);
begin
  FScreenPalette := EnsureRange(Value, 0, SCREEN_PALETTE_COUNT - 1);
end;

end.

