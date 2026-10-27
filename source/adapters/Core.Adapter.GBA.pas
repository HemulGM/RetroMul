unit Core.Adapter.GBA;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, GBA.Console, GBA.Emulation;

const
  GBA_BUTTONS: TEmulatorButtons = [
      TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
      TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.C,
      TEmulatorButton.Z];

type
  TGBAKeyMap = array[TEmulatorButton] of UInt32;

  TGBAConfig = class(TEmulatorConfigBase)
  private
    FKeys: TGBAKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    BIOSFile: string;
    SaveOverride, SolarLevel: Integer;
    RumbleEnabled: Boolean;
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TGBAKeyMap read FKeys;
  end;

  TGBACoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationMotionInput, IEmulationRotationInput, IEmulationRumbleOutput)
  private
    FThread: TGBAWorker;
    FData: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys: TGBAKeyMap;
    FKeyboard, FGamepad: TEmulatorButtons;
    FBIOS: TBytes;
    FPaused, FHasTilt, FHasGyro, FHasRumble: Boolean;
    FCoreConfig: TGBAConfig;
    FMotionX, FMotionY, FRotation: Double;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string); overload;
    destructor Destroy; override;
    function GetHasAccelerometer: Boolean;
    procedure SetAcceleration(X, Y: Double);
    function GetHasGyroscope: Boolean;
    procedure SetRotation(Value: Double);
    function GetHasRumble: Boolean;
    function GetRumbleLevel: Byte;
    function GetSystemId: string;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
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
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

implementation

uses
  System.IOUtils, System.UITypes, System.Math, System.Hash, GBA.Cartridge,
  Core.RomFormat;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'L', 'X', 'Y', 'R', 'Mode');

{ TGBAConfig }

procedure TGBACoreAdapter.ApplyLiveSettings;
begin
  FKeys := FCoreConfig.Keys;
  if FThread <> nil then
    FThread.SetSolarLevel(FCoreConfig.SolarLevel);
  ApplySettings;
end;

constructor TGBAConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TGBAKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkSpace, vkReturn, vkA, 0, 0, vkS, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  SaveOverride := -1;
  SolarLevel := 128;
  RumbleEnabled := True;
end;

procedure TGBAConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  BIOSFile := Ini.ReadString('Boot', 'File', '');
  SaveOverride := Ini.ReadInteger('Cartridge', 'SaveType', -1);
  if (SaveOverride < -1) or (SaveOverride > 4) then
    SaveOverride := -1;
  SolarLevel := EnsureRange(Ini.ReadInteger('Cartridge', 'SolarLevel', 128), 0, 255);
  RumbleEnabled := Ini.ReadBool('Peripherals', 'Rumble', True);

  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
  end;
end;

procedure TGBAConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Boot', 'File', BIOSFile);
  Ini.WriteInteger('Cartridge', 'SaveType', SaveOverride);
  Ini.WriteInteger('Cartridge', 'SolarLevel', SolarLevel);
  Ini.WriteBool('Peripherals', 'Rumble', RumbleEnabled);

  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
  end;
end;

{ TGBACoreAdapter }

constructor TGBACoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

constructor TGBACoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
var
  Cart: TGBACartridge;
  Config: TGBAConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Data := ReadRomData(Stream);
  var Format := DetectRom(Data);
  Cart := TGBACartridge.Create(NormalizeRom(Data, Format));
  try
    FData := Copy(Cart.Data);
    FHasTilt := Cart.Hardware.HasTilt;
    FHasGyro := Cart.Hardware.HasGyro;
    FHasRumble := Cart.Hardware.HasRumble;
  finally
    Cart.Free;
  end;
  Config := TGBAConfig.Create(FStorage.ConfigFile(ROM_SYSTEM_GBA), FStorage);
  FConfig := Config;
  FCoreConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  if Config.BIOSFile <> '' then
  begin
    FBIOS := FStorage.ReadBytes(Config.BIOSFile);
    if Length(FBIOS) <> 16384 then
      raise EReadError.Create('GBA BIOS must be exactly 16384 bytes');
  end;

  Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSavePath := FStorage.GameSave(ROM_SYSTEM_GBA, RomName, Hash.HashAsString);
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_GBA, RomName, Hash.HashAsString);
end;

destructor TGBACoreAdapter.Destroy;
begin
  // Explicit Stop reports persistence failures before the owner releases us.
  FThread.Free;
  inherited;
end;

function TGBACoreAdapter.GetHasAccelerometer: Boolean;
begin
  Result := FHasTilt;
end;

procedure TGBACoreAdapter.SetAcceleration(X, Y: Double);
begin
  FMotionX := X;
  FMotionY := Y;
  if FThread <> nil then
    FThread.SetMotion(X, Y, FRotation);
end;

function TGBACoreAdapter.GetHasGyroscope: Boolean;
begin
  Result := FHasGyro;
end;

procedure TGBACoreAdapter.SetRotation(Value: Double);
begin
  FRotation := Value;
  if FThread <> nil then
    FThread.SetMotion(FMotionX, FMotionY, Value);
end;

function TGBACoreAdapter.GetHasRumble: Boolean;
begin
  Result := FHasRumble;
end;

function TGBACoreAdapter.GetRumbleLevel: Byte;
begin
  Result := 0;
  if FHasRumble and FCoreConfig.RumbleEnabled and not FPaused and (FThread <> nil) then
    Result := FThread.GetRumbleLevel;
end;

procedure TGBACoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(FKeyboard + FGamepad, FPaused,
      FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TGBACoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TGBAWorker.Create(FData, FSavePath, FStorage, FBIOS, FCoreConfig.SaveOverride, FCoreConfig.SolarLevel);
  FThread.SetMotion(FMotionX, FMotionY, FRotation);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_GBA);
  ApplySettings;
  FThread.Start;
end;

procedure TGBACoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TGBACoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TGBACoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TGBACoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TGBACoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TGBACoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FGamepad := [];
  ApplySettings;
end;

procedure TGBACoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if (Button in GBA_BUTTONS) and (Code <> 0) and (Code = FKeys[Button]) then
      if Pressed then
        Include(FKeyboard, Button)
      else
        Exclude(FKeyboard, Button);
  end;
  ApplySettings;
end;

function TGBACoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard + FGamepad;
end;

procedure TGBACoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input.Buttons * GBA_BUTTONS;
  ApplySettings;
end;

function TGBACoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TGBACoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TGBACoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TGBACoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TGBACoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_GBA;
end;

function TGBACoreAdapter.GetName: string;
begin
  Result := 'Game Boy Advance';
end;

function TGBACoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TGBACoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TGBACoreAdapter.InsertCoin1;
begin
end;

procedure TGBACoreAdapter.InsertCoin2;
begin
end;

function TGBACoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TGBACoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TGBACoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TGBACoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TGBACoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.

