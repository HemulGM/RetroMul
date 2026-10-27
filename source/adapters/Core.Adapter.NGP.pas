unit Core.Adapter.NGP;

interface

uses
  Core.RomFormat, System.SysUtils, System.Classes, System.IniFiles, Core.Storage,
  Core.Emulation, NGP.Console, NGP.Emulation, Core.InputConfig, NGP.Cartridge;

type
  TNGPKeyMap = array[TEmulatorButton] of UInt32;

  TNGPConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TNGPKeyMap;
    FBIOSFile: string;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property BIOSFile: string read FBIOSFile;
    property Keys: TNGPKeyMap read FKeys;
    property Keys2: TNGPKeyMap read FKeys2;
  end;

  TNGPCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FBIOS, FIdentity: TBytes;
    FCartridgeROM: TBytes;
    FColor: Boolean;
    FSystemId: string;
    FThread: TNGPWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TNGPConfig;
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
    function GetUsesSuborKeyboard: Boolean;
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
  System.UITypes, System.IOUtils, Core.Snapshots, NGP.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TNGPCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TNGPConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TNGPKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, 0, 0, 0, 0, 0);
  Keys2: TNGPKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TNGPConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TNGPConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TNGPCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FCartridgeROM := ReadRomData(Stream);
  var Cart := TNGPCartridge.Create(FCartridgeROM);
  try
    FColor := Cart.Color;
  finally
    Cart.Free;
  end;
  FSystemId := ROM_SYSTEM_NGP;
  if FColor then
    FSystemId := ROM_SYSTEM_NGPC;
  FConfigObject := TNGPConfig.Create(FStorage.ConfigFile(FSystemId), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  var BIOSPath := FConfigObject.BIOSFile;
  if BIOSPath = '' then
  begin
    var Names: TArray<string>;
    if FColor then
      Names := TArray<string>.Create('ngpc_bios.bin', 'ngpcbios.bin')
    else
      Names := TArray<string>.Create('ngp_bios.bin', 'ngpbios.bin');
    for var Folder in TArray<string>.Create(ExtractFilePath(RomName), FStorage.RomFolder(FSystemId), TPath.Combine(FStorage.Root, 'bios')) do
    begin
      for var Name in Names do
      begin
        var Candidate := TPath.Combine(Folder, Name);
        if FStorage.Exists(Candidate) then
        begin
          BIOSPath := Candidate;
          Break;
        end;
      end;
      if BIOSPath <> '' then
        Break;
    end;
  end;
  if BIOSPath = '' then
    FBIOS := LoadNGPBIOS(FColor)
  else
    FBIOS := FStorage.ReadBytes(BIOSPath);
  if Length(FBIOS) <> $10000 then
    raise EReadError.Create('Neo Geo Pocket BIOS must contain exactly 64 KiB');

  FIdentity := Copy(FCartridgeROM);
  var N := Length(FIdentity);
  SetLength(FIdentity, N + Length(FBIOS) + 1);
  Move(FBIOS[0], FIdentity[N], Length(FBIOS));
  FIdentity[High(FIdentity)] := Ord(FColor);
  FSnapshotDirectory := FStorage.GameSnapshots(FSystemId, RomName, SnapshotIdentity(FIdentity));
  FSaveFile := FStorage.GameSave(FSystemId, RomName, SnapshotIdentity(FCartridgeROM));
end;

destructor TNGPCoreAdapter.Destroy;
begin
  Stop;

  inherited;
end;

procedure TNGPCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TNGPCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TNGPWorker.Create(FCartridgeROM, FBIOS, FIdentity, FStorage, FColor, FSystemId);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, FSystemId);
  FThread.SaveFile := FSaveFile;
  FThread.SystemSaveFile := TPath.Combine(FStorage.SaveRoot,
    FSystemId + '-system-' + SnapshotIdentity(FBIOS).Substring(0, 16) + '.bin');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TNGPCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TNGPCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TNGPCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TNGPCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TNGPCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TNGPCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TNGPCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  ApplySettings;
end;

procedure TNGPCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Default(TEmulatorInput);
  FGamepad.Buttons := Input.Buttons;
  ApplySettings;
end;

function TNGPCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TNGPCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TNGPCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TNGPCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TNGPCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TNGPCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TNGPCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TNGPCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TNGPCoreAdapter.GetSystemId: string;
begin
  Result := FSystemId;
end;

function TNGPCoreAdapter.GetName: string;
begin
  if FColor then
    Result := 'SNK Neo Geo Pocket Color'
  else
    Result := 'SNK Neo Geo Pocket';
end;

function TNGPCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TNGPCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TNGPCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TNGPCoreAdapter.InsertCoin1;
begin
end;

procedure TNGPCoreAdapter.InsertCoin2;
begin
end;

function TNGPCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

