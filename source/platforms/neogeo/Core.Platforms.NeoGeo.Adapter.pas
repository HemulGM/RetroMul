unit Core.Platforms.NeoGeo.Adapter;

interface

uses
  Core.InputConfig, System.SysUtils, System.Classes, System.IniFiles,
  Core.Storage, Core.Emulation, NeoGeo.Cartridge, NeoGeo.Emulation;

type
  TNeoGeoKeyMap = array[TEmulatorButton] of UInt32;

  TNeoGeoConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TNeoGeoKeyMap;
    FModel, FCountry, FBIOS, FCardPath: string;
    FCardInserted, FCardReadOnly, FPAL: Boolean;
    FDIPSettings, FDIPFreePlay, FDIPFreeze, FDIPSingleCoin: Boolean;
    FDiscPresent, FTrayOpen: Boolean;
    FCardSize: Integer;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TNeoGeoKeyMap read FKeys;
    property Keys2: TNeoGeoKeyMap read FKeys2;
  end;

  TNeoGeoCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FThread: TNeoGeoWorker;
    FCartridge: TNeoGeoCartridge;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FNeoConfig: TNeoGeoConfig;
    FKeys, FKeys2: TNeoGeoKeyMap;
    FKeyboard, FKeyboard2, FGamepad, FGamepad2: TEmulatorButtons;
    FPaused: Boolean;
    FSavePath, FSnapshotDirectory, FError: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; CD: Boolean = False);
    destructor Destroy; override;
    function GetSystemId: string;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
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
  System.UITypes, System.Hash;

const
  Buttons: TEmulatorButtons = [TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A,
      TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X,
      TEmulatorButton.Start, TEmulatorButton.Select];
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'D', 'Y', 'Z', 'Mode');

procedure TNeoGeoCoreAdapter.ApplyLiveSettings;
begin
  FKeys := FNeoConfig.Keys;
  FKeys2 := FNeoConfig.Keys2;
  var DIPs: Byte := $FF;
  if FNeoConfig.FDIPSettings then
    DIPs := DIPs and $FE;
  if FNeoConfig.FDIPSingleCoin then
    DIPs := DIPs and $FD;
  if FNeoConfig.FDIPFreePlay then
    DIPs := DIPs and $BF;
  if FNeoConfig.FDIPFreeze then
    DIPs := DIPs and $7F;
  if FThread <> nil then
  begin
    FThread.ConfigureCabinet(DIPs);
    var Path := FNeoConfig.FCardPath;
    if Path = '' then
      Path := FStorage.SaveRoot + PathDelim + 'neogeo-memorycard.bin';
    FThread.ConfigureCard(Path, FNeoConfig.FCardSize);
  end;
  ApplySettings;
end;

constructor TNeoGeoConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TNeoGeoKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vk5, vkReturn, vkC, vkV, 0, 0, 0);
  Defaults2: TNeoGeoKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vk6, vkNumpad0, vkNumpad3, vkDecimal, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  FKeys2 := Defaults2;
  FModel := 'auto';
  FCountry := 'auto';
  FCardSize := 2048;
  FDiscPresent := True;
end;

procedure TNeoGeoConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FModel := Ini.ReadString('Hardware', 'Model', 'auto');
  FCountry := Ini.ReadString('Hardware', 'Region', 'auto');
  FBIOS := Ini.ReadString('Hardware', 'BIOS', '');
  FPAL := Ini.ReadBool('Hardware', 'PAL', False);
  FDIPSettings := Ini.ReadBool('Cabinet', 'Settings', False);
  FDIPFreePlay := Ini.ReadBool('Cabinet', 'FreePlay', False);
  FDIPFreeze := Ini.ReadBool('Cabinet', 'Freeze', False);
  FDIPSingleCoin := Ini.ReadBool('Cabinet', 'SingleCoin', False);
  FCardInserted := Ini.ReadBool('MemoryCard', 'Inserted', False);
  FCardReadOnly := Ini.ReadBool('MemoryCard', 'ReadOnly', False);
  FCardPath := Ini.ReadString('MemoryCard', 'Path', '');
  FCardSize := Ini.ReadInteger('MemoryCard', 'Size', 2048);
  FDiscPresent := Ini.ReadBool('Drive', 'DiscPresent', True);
  FTrayOpen := Ini.ReadBool('Drive', 'TrayOpen', False);
  if (FCardSize < 2048) or (FCardSize > 16384) or (FCardSize mod 2048 <> 0) then
    FCardSize := 2048;
  for var B in Buttons do
  begin
    FKeys[B] := ReadEmulatorKey(Ini, 'Keys', KeyNames[B], FKeys[B]);
    FKeys2[B] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[B], FKeys2[B]);
  end;
end;

procedure TNeoGeoConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'Model', FModel);
  Ini.WriteString('Hardware', 'Region', FCountry);
  Ini.WriteString('Hardware', 'BIOS', FBIOS);
  Ini.WriteBool('Hardware', 'PAL', FPAL);
  Ini.WriteBool('Cabinet', 'Settings', FDIPSettings);
  Ini.WriteBool('Cabinet', 'FreePlay', FDIPFreePlay);
  Ini.WriteBool('Cabinet', 'Freeze', FDIPFreeze);
  Ini.WriteBool('Cabinet', 'SingleCoin', FDIPSingleCoin);
  Ini.WriteBool('MemoryCard', 'Inserted', FCardInserted);
  Ini.WriteBool('MemoryCard', 'ReadOnly', FCardReadOnly);
  Ini.WriteString('MemoryCard', 'Path', FCardPath);
  Ini.WriteInteger('MemoryCard', 'Size', FCardSize);
  Ini.WriteBool('Drive', 'DiscPresent', FDiscPresent);
  Ini.WriteBool('Drive', 'TrayOpen', FTrayOpen);
  for var B in Buttons do
  begin
    Ini.WriteInteger('Keys', KeyNames[B], FKeys[B]);
    Ini.WriteInteger('Keys2', KeyNames[B], FKeys2[B]);
  end;
end;

constructor TNeoGeoCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; CD: Boolean);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;

  var SystemId := ROM_SYSTEM_NEOGEO;
  if CD then
    SystemId := ROM_SYSTEM_NEOGEOCD;
  var Config := TNeoGeoConfig.Create(FStorage.ConfigFile(SystemId), FStorage);
  FConfig := Config;
  FNeoConfig := Config;
  Config.Load;
  if CD then
    FCartridge := TNeoGeoCartridge.CreateCD(Stream, FStorage, RomName, Config.FBIOS, Config.FModel)
  else
    FCartridge := TNeoGeoCartridge.Create(ReadNeoGeoData(Stream), FStorage, RomName);

  FCartridge.ConfigureHardware(FStorage, RomName, Config.FModel, Config.FCountry, Config.FBIOS);
  FCartridge.PAL := Config.FPAL and FCartridge.AES;
  FCartridge.CardInserted := Config.FCardInserted;
  FCartridge.CardReadOnly := Config.FCardReadOnly;
  FCartridge.CardSize := Config.FCardSize;
  if Config.FDIPSettings then
    FCartridge.CabinetDIPs := FCartridge.CabinetDIPs and $FE;
  if Config.FDIPSingleCoin then
    FCartridge.CabinetDIPs := FCartridge.CabinetDIPs and $FD;
  if Config.FDIPFreePlay then
    FCartridge.CabinetDIPs := FCartridge.CabinetDIPs and $BF;
  if Config.FDIPFreeze then
    FCartridge.CabinetDIPs := FCartridge.CabinetDIPs and $7F;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;

  var Hash := THashSHA2.Create;
  Hash.Update(FCartridge.Identity);

  var Identity := Hash.HashAsString;
  FSavePath := FStorage.GameSave(SystemId, RomName, Identity);
  FSnapshotDirectory := FStorage.GameSnapshots(SystemId, RomName, Identity);
  if not CD then
  begin
    // Retain access to saves written before AES joined the Neo Geo platform.
    var LegacySave := FStorage.GameSave(ROM_SYSTEM_NEOGEOAES, RomName, Identity);
    if not FStorage.Exists(FSavePath) and FStorage.Exists(LegacySave) then
      FSavePath := LegacySave;
    var LegacySnapshots := FStorage.GameSnapshots(ROM_SYSTEM_NEOGEOAES, RomName, Identity);
    if not FStorage.FolderExists(FSnapshotDirectory) and FStorage.FolderExists(LegacySnapshots) then
      FSnapshotDirectory := LegacySnapshots;
  end;
end;

destructor TNeoGeoCoreAdapter.Destroy;
begin
  FThread.Free;
  FCartridge.Free;
  inherited;
end;

procedure TNeoGeoCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    FThread.Configure(FKeyboard + FGamepad, FPaused, FConfig.AudioEnabled,
      FConfig.AudioVolume, FKeyboard2 + FGamepad2);
    FThread.ConfigureMedia(FNeoConfig.FCardInserted, FNeoConfig.FCardReadOnly, FNeoConfig.FDiscPresent, FNeoConfig.FTrayOpen);
  end;
end;

procedure TNeoGeoCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TNeoGeoWorker.Create(FCartridge, FSavePath, FStorage);
  if FCartridge.Disc = nil then
  begin
    FThread.MemoryCardPath := FNeoConfig.FCardPath;
    if FThread.MemoryCardPath = '' then
      FThread.MemoryCardPath := FStorage.SaveRoot + PathDelim + 'neogeo-memorycard.bin';
  end;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, GetSystemId);
  ApplySettings;
  FThread.Start;
end;

procedure TNeoGeoCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TNeoGeoCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TNeoGeoCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TNeoGeoCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TNeoGeoCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TNeoGeoCoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FKeyboard2 := [];
  FGamepad := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TNeoGeoCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
const
  TileButtons: array[0..6] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C);
  ActionButtons: array[0..4] of TEmulatorButton = (TEmulatorButton.X, TEmulatorButton.Y,
    TEmulatorButton.Z, TEmulatorButton.Mode, TEmulatorButton.Select);
  ActionKeys: array[0..4] of UInt32 = (vkO, vkP, vkQ, vkR, vkS);
begin
  if Code = 0 then
    Exit;

  if FCartridge.Protection = 'neogeo_mj' then
  begin
    if (Code >= vkA) and (Code <= vkG) then
      if Pressed then
        Include(FKeyboard, TileButtons[Code - vkA])
      else
        Exclude(FKeyboard, TileButtons[Code - vkA]);
    if (Code >= vkH) and (Code <= vkN) then
      if Pressed then
        Include(FKeyboard2, TileButtons[Code - vkH])
      else
        Exclude(FKeyboard2, TileButtons[Code - vkH]);
    for var I := 0 to 4 do
      if Code = ActionKeys[I] then
        if Pressed then
          Include(FKeyboard2, ActionButtons[I])
        else
          Exclude(FKeyboard2, ActionButtons[I]);
    if Code = vkReturn then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Start)
      else
        Exclude(FKeyboard, TEmulatorButton.Start);
    if Code = vk5 then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Select)
      else
        Exclude(FKeyboard, TEmulatorButton.Select);
    ApplySettings;
    Exit;
  end;

  if (FCartridge.Disc = nil) and not FCartridge.AES and (FCartridge.Protection <> 'vliner') then
  begin
    if Code = vkF3 then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Y)
      else
        Exclude(FKeyboard, TEmulatorButton.Y);
    if Code = vkF2 then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Mode)
      else
        Exclude(FKeyboard, TEmulatorButton.Mode);
  end;

  if FCartridge.Protection = 'vliner' then
  begin
    if Code = vkF1 then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Mode)
      else
        Exclude(FKeyboard, TEmulatorButton.Mode);
    if Code = vkF2 then
      if Pressed then
        Include(FKeyboard, TEmulatorButton.Y)
      else
        Exclude(FKeyboard, TEmulatorButton.Y);
  end;

  for var B in Buttons do
  begin
    if Code = FKeys[B] then
      if Pressed then
        Include(FKeyboard, B)
      else
        Exclude(FKeyboard, B);
    if Code = FKeys2[B] then
      if Pressed then
        Include(FKeyboard2, B)
      else
        Exclude(FKeyboard2, B);
  end;

  ApplySettings;
end;

procedure TNeoGeoCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input.Buttons * Buttons;
  FGamepad2 := Input.Buttons2 * Buttons;
  ApplySettings;
end;

function TNeoGeoCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard + FGamepad;
  Result.Buttons2 := FKeyboard2 + FGamepad2;
end;

procedure TNeoGeoCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TNeoGeoCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

function TNeoGeoCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TNeoGeoCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TNeoGeoCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TNeoGeoCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TNeoGeoCoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_NEOGEO;
  if FCartridge.Disc <> nil then
    Result := ROM_SYSTEM_NEOGEOCD;
end;

function TNeoGeoCoreAdapter.GetName: string;
begin
  if FCartridge.Disc <> nil then
    Result := 'SNK Neo Geo CD'
  else if FCartridge.AES then
    Result := 'SNK Neo Geo AES'
  else
    Result := 'SNK Neo Geo MVS';
end;

function TNeoGeoCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TNeoGeoCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TNeoGeoCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := (FCartridge.Disc = nil) and not FCartridge.AES;
end;

procedure TNeoGeoCoreAdapter.InsertCoin1;
begin
  if FThread <> nil then
    FThread.InsertCoin(1);
end;

procedure TNeoGeoCoreAdapter.InsertCoin2;
begin
  if FThread <> nil then
    FThread.InsertCoin(2);
end;

function TNeoGeoCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

