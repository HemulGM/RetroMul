unit Core.Adapter.MD;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, MD.Console, MD.Emulation;

type
  TMDKeyMap = array[TMDButton] of UInt32;

  TMDConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TMDKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TMDKeyMap read FKeys;
    property Keys2: TMDKeyMap read FKeys2;
  end;

  TMDCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FThread: TMDWorker;
    FData: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TMDKeyMap;
    FKeyboard, FGamepad, FKeyboard2, FGamepad2: TMDButtons;
    FPaused: Boolean;
    procedure ApplySettings;
  public
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string); overload;
    destructor Destroy; override;
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
  System.IOUtils, System.UITypes, System.Hash, MD.Cartridge, Core.RomFormat;

const
  KeyNames: array[TMDButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'C', 'Start', 'X', 'Y', 'Z', 'Mode');

{ TMDConfig }

constructor TMDConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TMDKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkC, vkReturn, vkA, vkS, vkD, vkSpace);
  Defaults2: TMDKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad0, vkNumpad7, vkNumpad9,
    vkDecimal, vkMultiply);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  FKeys2 := Defaults2;
end;

procedure TMDConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TMDButton) to High(TMDButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TMDConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TMDButton) to High(TMDButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

{ TMDCoreAdapter }

constructor TMDCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

constructor TMDCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
var
  Cart: TMDCartridge;
  Config: TMDConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Data := ReadRomData(Stream);
  var Format := DetectRom(Data);
  Cart := TMDCartridge.Create(NormalizeRom(Data, Format), '');
  try
    FData := Copy(Cart.Data);
  finally
    Cart.Free;
  end;
  Config := TMDConfig.Create(FStorage.ConfigFile(ROM_SYSTEM_MD), FStorage);
  FConfig := Config;
  Config.Load;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSavePath := FStorage.GameSave(ROM_SYSTEM_MD, RomName, Hash.HashAsString);
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_MD, RomName, Hash.HashAsString);
end;

destructor TMDCoreAdapter.Destroy;
begin
  // Explicit Stop reports persistence failures before the owner releases us.
  FThread.Free;
  inherited;
end;

procedure TMDCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(FKeyboard + FGamepad, FPaused,
      FConfig.AudioEnabled, FConfig.AudioVolume, FKeyboard2 + FGamepad2);
end;

procedure TMDCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TMDWorker.Create(FData, FSavePath, FStorage);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_MD);
  ApplySettings;
  FThread.Start;
end;

procedure TMDCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.StopAndSave;
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
  FKeyboard2 := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TMDCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TMDButton;
begin
  for Button := Low(TMDButton) to High(TMDButton) do
  begin
    if Code = FKeys[Button] then
      if Pressed then
        Include(FKeyboard, Button)
      else
        Exclude(FKeyboard, Button);
    if Code = FKeys2[Button] then
      if Pressed then
        Include(FKeyboard2, Button)
      else
        Exclude(FKeyboard2, Button);
  end;
  ApplySettings;
end;

function TMDCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TMDButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
    TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.X,
    TEmulatorButton.Y, TEmulatorButton.Z, TEmulatorButton.Mode);
begin
  Result := Default(TEmulatorInput);
  for var Button := Low(TMDButton) to High(TMDButton) do
  begin
    if Button in (FKeyboard + FGamepad) then
      Include(Result.Buttons, Mapping[Button]);
    if Button in (FKeyboard2 + FGamepad2) then
      Include(Result.Buttons2, Mapping[Button]);
  end;
end;

procedure TMDCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TEmulatorButton] of TMDButton =
    (TMDButton.Up, TMDButton.Down, TMDButton.Left, TMDButton.Right,
    TMDButton.A, TMDButton.B, TMDButton.C, TMDButton.Start,
    TMDButton.C, TMDButton.X, TMDButton.Y, TMDButton.Z, TMDButton.Mode);
var
  Button: TEmulatorButton;
begin
  FGamepad := [];
  FGamepad2 := [];
  for Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if Button in Input.Buttons then
      Include(FGamepad, Mapping[Button]);
    if Button in Input.Buttons2 then
      Include(FGamepad2, Mapping[Button]);
  end;
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

function TMDCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
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

function TMDCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TMDCoreAdapter.InsertCoin1;
begin
end;

procedure TMDCoreAdapter.InsertCoin2;
begin
end;

function TMDCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TMDCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TMDCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TMDCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TMDCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.

