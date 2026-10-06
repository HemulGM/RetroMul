unit Core.Adapter.GB;

interface

uses
  System.Classes, System.IniFiles, Core.Storage, Core.InputConfig,
  Core.Emulation, GB.EmulationThread, GB.Joypad, GB.GPU, GB.Camera;

type
  TGBKeyMap = record
    A, B, Select, Start, Up, Down, Left, Right: UInt32;
  end;

  IGBEmulatorConfig = interface(IEmulatorConfig)
    ['{F92F710A-091C-4D32-9C97-369476030FB1}']
    function GetKeys: TGBKeyMap;
    procedure SetKeys(const Value: TGBKeyMap);
    property Keys: TGBKeyMap read GetKeys write SetKeys;
    function GetScreenPalette: Integer;
    procedure SetScreenPalette(const Value: Integer);
    property ScreenPalette: Integer read GetScreenPalette write SetScreenPalette;
  end;

  TGBEmulatorConfig = class(TEmulatorConfigBase, IGBEmulatorConfig)
  private
    FKeys: TGBKeyMap;
    FScreenPalette: Integer;
  protected
    procedure LoadControls(Ini: TCustomIniFile);
    procedure SaveControls(Ini: TCustomIniFile);
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const AFileName: string; const Storage: IStorage = nil);
    function GetKeys: TGBKeyMap;
    procedure SetKeys(const Value: TGBKeyMap);

    function GetScreenPalette: Integer;
    procedure SetScreenPalette(const Value: Integer);
  end;

  TGBCoreAdapter = class(TInterfacedObject, IEmulationCore, IGBCameraInput)
  protected
    FThread: TGBEmulationThread;
    FCameraSource: IGBCameraFrameSource;
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
    function GetName: string; virtual;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
  public
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
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetHasCamera: Boolean;
    procedure SubmitCameraFrame(const Frame: TGBCameraFrame);
  end;

implementation

uses
  Core.RomFormat, Core.Snapshots, Core.SavePaths, System.SysUtils, System.Math,
  System.UITypes, GB.Palettes, GB.ROM, GB.MBC;

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
  Result := TGBEmulationThread.Create(FROMData, FConfig.AudioEnabled, FCameraSource);
end;

procedure TGBCoreAdapter.CopyFrame(const Screen: TScreenArray; var Frame: TEmulatorFrame);
begin
  for var i := 0 to High(Screen) do
  begin
    var Shade := Screen[i];
    if (Shade < 0) or (Shade > 3) then
      Shade := 0;
    Frame.Pixels[i] := ScreenPalettes[FConfig.ScreenPalette].Colors[Shade];
  end;
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
    FROMData := ROM.ROMData;
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
  if (FCameraSource = nil) and (Length(FROMData) > $147) and (FROMData[$147] = $FC) then
    FCameraSource := TGBCameraFrameSource.Create;
  FThread := CreateWorker;
  FThread.Storage := FStorage;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.SavePath := FSavePath;
  FThread.SoundVolume := FConfig.AudioVolume;
  FThread.ScreenPalette := FConfig.ScreenPalette;
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

procedure TGBCoreAdapter.ClearInput;
begin
  FGamepadInput := Default(TEmulatorInput);
  FKeyboardInput := Default(TEmulatorInput);
  FThread.ReleaseKeys;
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

procedure TGBCoreAdapter.SaveSnapshot(const Name: string);
begin
  FThread.ScreenPalette := FConfig.ScreenPalette;
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
  FThread.Start;
end;

procedure TGBCoreAdapter.Stop;
begin
  if (FThread <> nil) and not FThread.Finished then
    FThread.RequestStop;
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
  Screen: TScreenArray;
  FramesPerSecond: Double;
begin
  Result := FThread.TryGetFrame(Screen, FramesPerSecond);
  if not Result then
    Exit;

  Frame.Width := 160;
  Frame.Height := 144;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  CopyFrame(Screen, Frame);
  Inc(FFrameNumber);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := FramesPerSecond;
end;

{ TGBEmulatorConfig }

constructor TGBEmulatorConfig.Create(const AFileName: string; const Storage: IStorage);
begin
  inherited Create(AFileName, Storage);
  FKeys.A := vkZ;
  FKeys.B := vkX;
  FKeys.Select := vkSpace;
  FKeys.Start := vkReturn;
  FKeys.Up := vkUp;
  FKeys.Down := vkDown;
  FKeys.Left := vkLeft;
  FKeys.Right := vkRight;
  FScreenPalette := 0;
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
  Ini.WriteInteger('Video', 'Palette', FScreenPalette);
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

