unit Core.Adapter.SNES;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  SNES.Console, SNES.Emulation;

type
  TSnesKeyMap = array[TSnesButton] of UInt32;

  TSnesConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TSnesKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TSnesKeyMap read FKeys;
    property Keys2: TSnesKeyMap read FKeys2;
  end;

  TSnesCoreAdapter = class(TInterfacedObject, IEmulationCore)
  private
    FThread: TSnesWorker;
    FData, FFirmware: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TSnesKeyMap;
    FKeyboard, FGamepad, FKeyboard2, FGamepad2: TSnesButtons;
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
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

implementation

uses
  System.IOUtils, System.UITypes, System.Hash, SNES.Cartridge, Core.RomFormat;

const
  KeyNames: array[TSnesButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'X', 'Y', 'L', 'R');

{ TSnesConfig }

constructor TSnesConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TSnesKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkX, vkZ, vkSpace, vkReturn, vkS, vkA, vkQ, vkW);
  Defaults2: TSnesKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vkNumpad3, vkNumpad0, vkNumpad7, vkNumpad9,
    vkDecimal, vkMultiply);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  FKeys2 := Defaults2;
end;

procedure TSnesConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TSnesButton) to High(TSnesButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TSnesConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  for var Button := Low(TSnesButton) to High(TSnesButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

{ TSnesCoreAdapter }

constructor TSnesCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

constructor TSnesCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
var
  Cart: TSnesCartridge;
  Config: TSnesConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Data := ReadRomData(Stream);
  var Format := DetectRom(Data);
  Data := NormalizeRom(Data, Format);
  Config := TSnesConfig.Create(FStorage.ConfigFile(ROM_SYSTEM_SNES), FStorage);
  FConfig := Config;
  Config.Load;
  var FirmwareName := SnesDSPFirmwareName(Data);
  if FirmwareName <> '' then
  begin
    var EmbeddedSize := SnesEmbeddedFirmwareSize(Data);
    if EmbeddedSize > 0 then
      FFirmware := Copy(Data, Length(Data) - EmbeddedSize, EmbeddedSize)
    else
      FFirmware := SnesResourceFirmware(FirmwareName);
  end;
  Cart := TSnesCartridge.Create(Data, FFirmware);
  try
    FData := Copy(Cart.Data);
  finally
    Cart.Free;
  end;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  if Length(FFirmware) > 0 then
    Hash.Update(FFirmware);
  FSavePath := FStorage.GameSave(ROM_SYSTEM_SNES, RomName, Hash.HashAsString);
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_SNES, RomName, Hash.HashAsString);
end;

destructor TSnesCoreAdapter.Destroy;
begin
  Stop;
  inherited;
end;

procedure TSnesCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(FKeyboard + FGamepad, FPaused,
      FConfig.AudioEnabled, FConfig.AudioVolume, FKeyboard2 + FGamepad2);
end;

procedure TSnesCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TSnesWorker.Create(FData, FSavePath, FStorage, FFirmware);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TSnesCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.Terminate;
  FThread.WakeSetEvent;
  FThread.WaitFor;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TSnesCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TSnesCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TSnesCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TSnesCoreAdapter.ClearInput;
begin
  FKeyboard := [];
  FGamepad := [];
  FKeyboard2 := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TSnesCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TSnesButton;
begin
  for Button := Low(TSnesButton) to High(TSnesButton) do
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

function TSnesCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TSnesButton] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z);
begin
  Result := Default(TEmulatorInput);
  for var Button := Low(TSnesButton) to High(TSnesButton) do
  begin
    if Button in (FKeyboard + FGamepad) then
      Include(Result.Buttons, Mapping[Button]);
    if Button in (FKeyboard2 + FGamepad2) then
      Include(Result.Buttons2, Mapping[Button]);
  end;
end;

procedure TSnesCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TEmulatorButton] of TSnesButton = (TSnesButton.Up, TSnesButton.Down, TSnesButton.Left, TSnesButton.Right, TSnesButton.A, TSnesButton.B, TSnesButton.Select, TSnesButton.Start, TSnesButton.L, TSnesButton.X, TSnesButton.Y, TSnesButton.R, TSnesButton.Select);
var
  Button: TEmulatorButton;
begin
  FGamepad := [];
  FGamepad2 := [];
  for Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    if (Button <> TEmulatorButton.Mode) and (Button in Input.Buttons) then
      Include(FGamepad, Mapping[Button]);
    if (Button <> TEmulatorButton.Mode) and (Button in Input.Buttons2) then
      Include(FGamepad2, Mapping[Button]);
  end;
  ApplySettings;
end;

function TSnesCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TSnesCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TSnesCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TSnesCoreAdapter.GetName: string;
begin
  Result := 'Super Nintendo (SNES)';
end;

function TSnesCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TSnesCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TSnesCoreAdapter.InsertCoin1;
begin
end;

procedure TSnesCoreAdapter.InsertCoin2;
begin
end;

function TSnesCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TSnesCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

procedure TSnesCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TSnesCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.

