unit Core.Platforms.WS.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  WS.Console, WS.Emulation, Core.InputConfig, WS.Cartridge;

type
  TWSKeyMap = array[TEmulatorButton] of UInt32;

  TWSConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TWSKeyMap;
    FBIOSFile: string;
    FOrientation, FPalette, FModel: Integer;
    FHeadphones: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Model: Integer read FModel;
    property Orientation: Integer read FOrientation;
    property Palette: Integer read FPalette;
    property Headphones: Boolean read FHeadphones;
    property BIOSFile: string read FBIOSFile;
    property Keys: TWSKeyMap read FKeys;
    property Keys2: TWSKeyMap read FKeys2;
  end;

  TWSCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FBIOS, FIdentity: TBytes;
    FCartridgeROM: TBytes;
    FColor: Boolean;
    FSystemId: string;
    FThread: TWSWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TWSConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory, FSaveFile: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string = '');
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
  RM.Platforms.WS, System.UITypes, System.IOUtils, System.Math, Core.Snapshots;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TWSCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TWSConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TWSKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, 0, vkReturn, vkA, vkW, vkD, vkS, 0);
  Keys2: TWSKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FHeadphones := True;
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TWSConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FModel := EnsureRange(Ini.ReadInteger('Hardware', 'Model', 0), 0, 2);
  FOrientation := EnsureRange(Ini.ReadInteger('Video', 'Orientation', 0), 0, 2);
  FPalette := EnsureRange(Ini.ReadInteger('Video', 'MonoPalette', 0), 0, 2);
  FHeadphones := Ini.ReadBool('Audio', 'Headphones', True);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TWSConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteInteger('Hardware', 'Model', FModel);
  Ini.WriteInteger('Video', 'Orientation', FOrientation);
  Ini.WriteInteger('Video', 'MonoPalette', FPalette);
  Ini.WriteBool('Audio', 'Headphones', FHeadphones);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TWSCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName, ImageName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FCartridgeROM := ReadRomData(Stream);
  var Cart := TWSCartridge.Create(FCartridgeROM);
  try
    FColor := Cart.Color or SameText(ExtractFileExt(ImageName), '.wsc') or
      ((ImageName = '') and SameText(ExtractFileExt(RomName), '.wsc'));
  finally
    Cart.Free;
  end;
  FSystemId := ROM_SYSTEM_WS;
  if FColor then
    FSystemId := ROM_SYSTEM_WSC;
  FConfigObject := TWSConfig.Create(FStorage.ConfigFile(FSystemId), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  if FConfigObject.Model <> 0 then
    FColor := FConfigObject.Model = 2;
  var BIOSPath := FConfigObject.BIOSFile;
  if BIOSPath <> '' then
    FBIOS := FStorage.ReadBytes(BIOSPath);

  FIdentity := Copy(FCartridgeROM);
  var N := Length(FIdentity);
  SetLength(FIdentity, N + Length(FBIOS) + 1);
  if Length(FBIOS) > 0 then
    Move(FBIOS[0], FIdentity[N], Length(FBIOS));
  FIdentity[High(FIdentity)] := Ord(FColor);
  FSnapshotDirectory := FStorage.GameSnapshots(FSystemId, RomName, SnapshotIdentity(FIdentity));
  FSaveFile := FStorage.GameSave(FSystemId, RomName, SnapshotIdentity(FCartridgeROM));
end;

destructor TWSCoreAdapter.Destroy;
begin
  Stop;

  inherited;
end;

procedure TWSCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume,
      FConfigObject.Orientation, FConfigObject.Palette, FConfigObject.Headphones);
end;

procedure TWSCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TWSWorker.Create(FCartridgeROM, FBIOS, FIdentity, FStorage, FColor, FSystemId);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, FSystemId);
  FThread.SaveFile := FSaveFile;
  var HardwareId := ROM_SYSTEM_WS;
  if FColor then
    HardwareId := ROM_SYSTEM_WSC;
  FThread.SystemSaveFile := TPath.Combine(FStorage.SaveRoot, HardwareId + '-system-eeprom.bin');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TWSCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TWSCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TWSCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TWSCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TWSCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TWSCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TWSCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  ApplySettings;
end;

procedure TWSCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Default(TEmulatorInput);
  FGamepad.Buttons := Input.Buttons;
  ApplySettings;
end;

function TWSCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TWSCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TWSCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TWSCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TWSCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TWSCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TWSCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TWSCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TWSCoreAdapter.GetSystemId: string;
begin
  Result := FSystemId;
end;

function TWSCoreAdapter.GetName: string;
begin
  if FColor then
    Result := 'Bandai WonderSwan Color'
  else
    Result := 'Bandai WonderSwan';
end;

function TWSCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TWSCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TWSCoreAdapter.InsertCoin1;
begin
end;

procedure TWSCoreAdapter.InsertCoin2;
begin
end;

function TWSCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

