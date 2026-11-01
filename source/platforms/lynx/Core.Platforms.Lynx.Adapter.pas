unit Core.Platforms.Lynx.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Lynx.Console, Lynx.Emulation, Core.InputConfig, Lynx.Cartridge;

type
  TLynxKeyMap = array[TEmulatorButton] of UInt32;

  TLynxConfig = class(TEmulatorConfigBase)
  private
    FKeys: TLynxKeyMap;
    FBIOSFile: string;
    FRotation: Integer;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property BIOSFile: string read FBIOSFile;
    property Rotation: Integer read FRotation;
    property Keys: TLynxKeyMap read FKeys;
  end;

  TLynxCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FBIOS, FIdentity: TBytes;
    FCartridgeROM: TBytes;
    FSystemId: string;
    FThread: TLynxWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TLynxConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory, FSaveFile: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string);
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
  System.UITypes, Core.Snapshots, Lynx.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TLynxCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TLynxConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TLynxKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkC, 0, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FRotation := -1;
end;

procedure TLynxConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FRotation := Ini.ReadInteger('Video', 'Rotation', -1);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
  end;
end;

procedure TLynxConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteInteger('Video', 'Rotation', FRotation);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
  end;
end;

constructor TLynxCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FCartridgeROM := ReadRomData(Stream);
  var Cart := TLynxCartridge.Create(FCartridgeROM);
  Cart.Free;
  FSystemId := 'lynx';
  FConfigObject := TLynxConfig.Create(FStorage.ConfigFile(FSystemId), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  var BIOSPath := FConfigObject.BIOSFile;
  if BIOSPath = '' then
    FBIOS := LoadLynxBIOS
  else
    FBIOS := FStorage.ReadBytes(BIOSPath);
  if Length(FBIOS) <> 512 then
    raise EReadError.Create('Lynx BIOS must contain exactly 512 bytes');

  FIdentity := Copy(FCartridgeROM);
  var N := Length(FIdentity);
  SetLength(FIdentity, N + Length(FBIOS));
  Move(FBIOS[0], FIdentity[N], Length(FBIOS));
  FSnapshotDirectory := FStorage.GameSnapshots(FSystemId, RomName, SnapshotIdentity(FIdentity));
  FSaveFile := FStorage.GameSave(FSystemId, RomName, SnapshotIdentity(FCartridgeROM));
end;

destructor TLynxCoreAdapter.Destroy;
begin
  Stop;

  inherited;
end;

procedure TLynxCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FConfigObject.Rotation);
end;

procedure TLynxCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TLynxWorker.Create(FCartridgeROM, FBIOS, FIdentity, FStorage, FSystemId);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, FSystemId);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.SaveFile := FSaveFile;
  ApplySettings;
  FThread.Start;
end;

procedure TLynxCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TLynxCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TLynxCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TLynxCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TLynxCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TLynxCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TLynxCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  ApplySettings;
end;

procedure TLynxCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Default(TEmulatorInput);
  FGamepad.Buttons := Input.Buttons;
  ApplySettings;
end;

function TLynxCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TLynxCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TLynxCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TLynxCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TLynxCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TLynxCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TLynxCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TLynxCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TLynxCoreAdapter.GetSystemId: string;
begin
  Result := FSystemId;
end;

function TLynxCoreAdapter.GetName: string;
begin
  Result := 'Atari Lynx';
end;

function TLynxCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TLynxCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TLynxCoreAdapter.InsertCoin1;
begin
end;

procedure TLynxCoreAdapter.InsertCoin2;
begin
end;

function TLynxCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

