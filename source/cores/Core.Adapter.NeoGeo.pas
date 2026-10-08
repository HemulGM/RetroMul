unit Core.Adapter.NeoGeo;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  NeoGeo.Cartridge, NeoGeo.Emulation;

type
  TNeoGeoKeyMap = array[TEmulatorButton] of UInt32;

  TNeoGeoConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TNeoGeoKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TNeoGeoKeyMap read FKeys;
    property Keys2: TNeoGeoKeyMap read FKeys2;
  end;

  TNeoGeoCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationAudioDiagnostics)
  private
    FThread: TNeoGeoWorker;
    FCartridge: TNeoGeoCartridge;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TNeoGeoKeyMap;
    FKeyboard, FKeyboard2, FGamepad, FGamepad2: TEmulatorButtons;
    FPaused: Boolean;
    FSavePath, FSnapshotDirectory, FError: string;
    procedure ApplySettings;
  public
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
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
  end;

implementation

uses
  System.UITypes, System.Hash, Core.RomFormat, Core.InputConfig;

const
  Buttons: TEmulatorButtons = [TEmulatorButton.Up, TEmulatorButton.Down,
      TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A,
      TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.X,
      TEmulatorButton.Start, TEmulatorButton.Select];
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'D', 'Y', 'Z', 'Mode');

constructor TNeoGeoConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TNeoGeoKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vk5, vkReturn, vkC, vkV, 0, 0, 0);
  Defaults2: TNeoGeoKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vk6, vkNumpad0, vkNumpad3, vkDecimal, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  FKeys2 := Defaults2;
end;

procedure TNeoGeoConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var B in Buttons do
  begin
    FKeys[B] := ReadEmulatorKey(Ini, 'Keys', KeyNames[B], FKeys[B]);
    FKeys2[B] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[B], FKeys2[B]);
  end;
end;

procedure TNeoGeoConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var B in Buttons do
  begin
    Ini.WriteInteger('Keys', KeyNames[B], FKeys[B]);
    Ini.WriteInteger('Keys2', KeyNames[B], FKeys2[B]);
  end;
end;

constructor TNeoGeoCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FCartridge := TNeoGeoCartridge.Create(ReadNeoGeoData(Stream), FStorage, RomName);
  var Config := TNeoGeoConfig.Create(FStorage.ConfigFile(ROM_SYSTEM_NEOGEO), FStorage);
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  var Hash := THashSHA2.Create;
  Hash.Update(FCartridge.Identity);
  var Identity := Hash.HashAsString;
  FSavePath := FStorage.GameSave(ROM_SYSTEM_NEOGEO, RomName, Identity);
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_NEOGEO, RomName, Identity);
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
    FThread.Configure(FKeyboard + FGamepad, FPaused, FConfig.AudioEnabled,
      FConfig.AudioVolume, FKeyboard2 + FGamepad2);
end;

procedure TNeoGeoCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TNeoGeoWorker.Create(FCartridge, FSavePath, FStorage);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_NEOGEO);
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

function TNeoGeoCoreAdapter.GetName: string;
begin
  Result := 'SNK Neo Geo MVS';
end;

function TNeoGeoCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TNeoGeoCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TNeoGeoCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := True;
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

