unit Core.Adapter.MD;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Emulation, MD.Console,
  MD.Emulation;

type
  TMDKeyMap = array[TMDButton] of UInt32;

  TMDConfig = class(TEmulatorConfigBase)
  private
    FKeys: TMDKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TIniFile); override;
    procedure SaveCoreSettings(Ini: TIniFile); override;
  public
    constructor Create(const FileName: string);
    property Keys: TMDKeyMap read FKeys;
  end;

  TMDCoreAdapter = class(TInterfacedObject, IEmulationCore)
  private
    FThread: TMDWorker;
    FData: TBytes;
    FSnapshotDirectory: string;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys: TMDKeyMap;
    FKeyboard, FGamepad: TMDButtons;
    FPaused: Boolean;
    procedure ApplySettings;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

implementation

uses
  System.IOUtils, System.UITypes, System.Hash, MD.Cartridge, Core.SavePaths;

const
  KeyNames: array[TMDButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'C', 'Start', 'X', 'Y', 'Z', 'Mode');

constructor TMDConfig.Create(const FileName: string);
const
  Defaults: TMDKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkC, vkReturn, vkA, vkS, vkD, vkSpace);
begin
  inherited Create(FileName);
  FKeys := Defaults;
end;

procedure TMDConfig.LoadCoreSettings(Ini: TIniFile);
begin
  for var Button := Low(TMDButton) to High(TMDButton) do
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
end;

procedure TMDConfig.SaveCoreSettings(Ini: TIniFile);
begin
  for var Button := Low(TMDButton) to High(TMDButton) do
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
end;

constructor TMDCoreAdapter.Create(const FileName: string);
var
  Cart: TMDCartridge;
  Config: TMDConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  Cart := TMDCartridge.Create(FileName);
  try
    FData := Copy(Cart.Data);
  finally
    Cart.Free;
  end;
  Config := TMDConfig.Create(EmulatorConfigFileName('md'));
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  FSavePath := GetSaveDirectory;
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSavePath := TPath.Combine(FSavePath, 'MD-' + Hash.HashAsString + '.sav');
  FSnapshotDirectory := ResolveGameSavePath(GetSnapshotDirectory, FileName,
    'MD-' + Hash.HashAsString, '');
end;

destructor TMDCoreAdapter.Destroy;
begin
  Stop;
  inherited;
end;

procedure TMDCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(FKeyboard + FGamepad, FPaused,
      FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TMDCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TMDWorker.Create(FData, FSavePath);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TMDCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.Terminate;
  FThread.WakeSetEvent;
  FThread.WaitFor;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TMDCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TMDCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TMDCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TMDCoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FGamepad := [];
  ApplySettings;
end;

procedure TMDCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TMDButton;
begin
  for Button := Low(TMDButton) to High(TMDButton) do
    if Code = FKeys[Button] then
      if Pressed then
        Include(FKeyboard, Button)
      else
        Exclude(FKeyboard, Button);
  ApplySettings;
end;

procedure TMDCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TEmulatorButton] of TMDButton =
    (TMDButton.Up, TMDButton.Down, TMDButton.Left, TMDButton.Right,
    TMDButton.A, TMDButton.B, TMDButton.C, TMDButton.Start);
var
  Button: TEmulatorButton;
begin
  FGamepad := [];
  for Button := Low(TEmulatorButton) to High(TEmulatorButton) do
    if Button in Input.Buttons then
      Include(FGamepad, Mapping[Button]);
  ApplySettings;
end;

function TMDCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TMDCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TMDCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TMDCoreAdapter.GetName: string;
begin
  Result := 'SEGA Genesis / Mega Drive';
end;

function TMDCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TMDCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TMDCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

procedure TMDCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then raise EInvalidOpException.Create('Emulation worker is not running');
  FThread.SaveSnapshot(Name);
end;

procedure TMDCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then raise EInvalidOpException.Create('Emulation worker is not running');
  FThread.LoadSnapshot(Name);
end;

end.

