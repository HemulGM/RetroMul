unit Core.Platforms.GameWatch.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage,
  Core.Emulation, GW.Cartridge, GW.Emulation, Core.InputConfig;

type
  TGWKeyMap = array[TEmulatorButton] of UInt32;

  TGWConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TGWKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TGWKeyMap read FKeys;
    property Keys2: TGWKeyMap read FKeys2;
  end;

  TGWCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls)
  private
    FCartridge: TGWCartridge;
    FThread: TGWWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TGWConfig;
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
    function GetVirtualButtons: TEmulatorButtons;
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
  RM.Platforms.GameWatch, System.UITypes, Core.Snapshots;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TGWCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TGWConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TGWKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkA, vkC, vkV, vkS, 0);
  Keys2: TGWKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TGWConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TGWConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TGWCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > 8 * 1024 * 1024) then
    raise EReadError.Create('Game & Watch package exceeds 8 MiB or is empty');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  Stream.ReadBuffer(Data[0], Length(Data));
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  FCartridge := TGWCartridge.Create(Data, SourceName);
  FConfigObject := TGWConfig.Create(FStorage.ConfigFile('gw'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FSnapshotDirectory := FStorage.GameSnapshots('gw', RomName, SnapshotIdentity(Data));
  FSaveFile := FStorage.GameSave('gw', RomName, SnapshotIdentity(Data));
end;

destructor TGWCoreAdapter.Destroy;
begin
  FThread.Free;
  FCartridge.Free;
  inherited;
end;

procedure TGWCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TGWCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TGWWorker.Create(FCartridge, FStorage);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'gw');
  FThread.SaveFile := FSaveFile;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TGWCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TGWCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TGWCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TGWCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TGWCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TGWCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TGWCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TGWCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TGWCoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  if FThread <> nil then
    Result := FThread.SupportedButtons
  else
    Result := FCartridge.SupportedButtons;
end;

function TGWCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TGWCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TGWCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TGWCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TGWCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TGWCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TGWCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TGWCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TGWCoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_GW;
end;

function TGWCoreAdapter.GetName: string;
begin
  Result := 'Game && Watch';
end;

function TGWCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TGWCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TGWCoreAdapter.InsertCoin1;
begin
end;

procedure TGWCoreAdapter.InsertCoin2;
begin
end;

function TGWCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

