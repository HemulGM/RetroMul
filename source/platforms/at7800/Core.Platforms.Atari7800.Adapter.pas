unit Core.Platforms.Atari7800.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  A7800.Console, A7800.Emulation, Core.InputConfig;

type
  TA7800KeyMap = array[TEmulatorButton] of UInt32;

  TA7800Config = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TA7800KeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TA7800KeyMap read FKeys;
    property Keys2: TA7800KeyMap read FKeys2;
  end;

  TA7800CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls)
  private
    FCartridge: TBytes;
    FThread: TA7800Worker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TA7800Config;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory: string;
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
  System.UITypes, Core.Snapshots;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TA7800CoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TA7800Config.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TA7800KeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkA, vkC, vkV, vkS, vkC);
  Keys2: TA7800KeyMap = (vkI, vkK, vkJ, vkL, vkDivide, vkMultiply, 0, vkO, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TA7800Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TA7800Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TA7800CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > $100080) then
    raise EReadError.Create('Atari 7800 cartridge exceeds 1 MiB + header or is empty');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  Stream.ReadBuffer(Data[0], Length(Data));
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  FCartridge := Copy(Data);
  FConfigObject := TA7800Config.Create(FStorage.ConfigFile('at7800'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  var Check := TA7800Console.Create(Data);
  Check.Free;
  FSnapshotDirectory := FStorage.GameSnapshots('at7800', RomName, SnapshotIdentity(Data));
end;

destructor TA7800CoreAdapter.Destroy;
begin
  FThread.Free;

  inherited;
end;

procedure TA7800CoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TA7800CoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TA7800Worker.Create(FCartridge, FStorage);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'at7800');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TA7800CoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.Stop;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TA7800CoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TA7800CoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TA7800CoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TA7800CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TA7800CoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TA7800CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TA7800CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TA7800CoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  if FThread <> nil then
    Result := FThread.SupportedButtons
  else
    Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Start, TEmulatorButton.Select];
end;

function TA7800CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TA7800CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TA7800CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TA7800CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TA7800CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TA7800CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TA7800CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TA7800CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TA7800CoreAdapter.GetSystemId: string;
begin
  Result := 'at7800';
end;

function TA7800CoreAdapter.GetName: string;
begin
  Result := 'Atari 7800';
end;

function TA7800CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TA7800CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TA7800CoreAdapter.InsertCoin1;
begin
end;

procedure TA7800CoreAdapter.InsertCoin2;
begin
end;

function TA7800CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

