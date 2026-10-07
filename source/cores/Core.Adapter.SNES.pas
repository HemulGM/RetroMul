unit Core.Adapter.SNES;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, SNES.Console, SNES.Emulation;

type
  TSnesKeyMap = array[TSnesButton] of UInt32;

  TSnesConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TSnesKeyMap;
    FExtraKeys: array[2..7] of TSnesKeyMap;
    FMultitap1, FMultitap2: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    function KeyMap(Port: Integer): TSnesKeyMap;
    property Multitap1: Boolean read FMultitap1 write FMultitap1;
    property Multitap2: Boolean read FMultitap2 write FMultitap2;
    property Keys: TSnesKeyMap read FKeys;
    property Keys2: TSnesKeyMap read FKeys2;
  end;

  TSnesCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationAudioDiagnostics)
  private
    FThread: TSnesWorker;
    FData, FFirmware: TBytes;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FSavePath, FError: string;
    FConfig: IEmulatorConfig;
    FKeys: array[0..7] of TSnesKeyMap;
    FKeyboards, FGamepads: TSnesPads;
    FPaused, FCropOverscan: Boolean;
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
    function TakeAudioError: string;
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

function TSnesConfig.KeyMap(Port: Integer): TSnesKeyMap;
begin
  case Port of
    0:
      Result := FKeys;
    1:
      Result := FKeys2;
    2..7:
      Result := FExtraKeys[Port];
  else
    raise EArgumentOutOfRangeException.Create('Controller port');
  end;
end;

procedure TSnesConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FMultitap1 := Ini.ReadBool('Input', 'Multitap1', False);
  FMultitap2 := Ini.ReadBool('Input', 'Multitap2', False);
  for var Button := Low(TSnesButton) to High(TSnesButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
    for var Port := 2 to 7 do
      FExtraKeys[Port, Button] := ReadEmulatorKey(Ini, 'Keys' + IntToStr(Port + 1), KeyNames[Button], 0);
  end;
end;

procedure TSnesConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteBool('Input', 'Multitap1', FMultitap1);
  Ini.WriteBool('Input', 'Multitap2', FMultitap2);
  for var Button := Low(TSnesButton) to High(TSnesButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
    for var Port := 2 to 7 do
      Ini.WriteInteger('Keys' + IntToStr(Port + 1), KeyNames[Button], FExtraKeys[Port, Button]);
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
  for var Port := 0 to 7 do
    FKeys[Port] := Config.KeyMap(Port);
  Hash := THashSHA2.Create;
  Hash.Update(FData);
  if Length(FFirmware) > 0 then
    Hash.Update(FFirmware);
  FSavePath := FStorage.GameSave(ROM_SYSTEM_SNES, RomName, Hash.HashAsString);
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_SNES, RomName, Hash.HashAsString);
end;

destructor TSnesCoreAdapter.Destroy;
begin
  // Explicit Stop reports persistence failures before the owner releases us.
  FThread.Free;
  inherited;
end;

procedure TSnesCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    var Inputs: TSnesPads;
    for var Port := 0 to 7 do
      Inputs[Port] := FKeyboards[Port] + FGamepads[Port];
    FThread.ConfigurePads(Inputs, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TSnesCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TSnesWorker.Create(FData, FSavePath, FStorage, FFirmware);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_SNES);
  var Ini := FStorage.ReadConfig(FStorage.ConfigFile(ROM_SYSTEM_SNES));
  try
    FCropOverscan := Ini.ReadBool('Video', 'CropOverscan', False);
  finally
    Ini.Free;
  end;
  ApplySettings;
  FThread.Start;
end;

procedure TSnesCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
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
  FKeyboards := Default(TSnesPads);
  FGamepads := Default(TSnesPads);
  ApplySettings;
end;

procedure TSnesCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TSnesButton;
begin
  if Code = 0 then
    Exit;
  for var Port := 0 to 7 do
    for Button := Low(TSnesButton) to High(TSnesButton) do
      if Code = FKeys[Port, Button] then
        if Pressed then
          Include(FKeyboards[Port], Button)
        else
          Exclude(FKeyboards[Port], Button);
  ApplySettings;
end;

function TSnesCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TSnesButton] of TEmulatorButton = (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.C, TEmulatorButton.Z);
begin
  Result := Default(TEmulatorInput);
  var Pads: array[0..7] of TEmulatorButtons;
  for var Port := 0 to 7 do
  begin
    Pads[Port] := [];
    for var Button := Low(TSnesButton) to High(TSnesButton) do
      if Button in (FKeyboards[Port] + FGamepads[Port]) then
        Include(Pads[Port], Mapping[Button]);
  end;
  Result.Buttons := Pads[0];
  Result.Buttons2 := Pads[1];
  Result.Buttons3 := Pads[2];
  Result.Buttons4 := Pads[3];
  Result.Buttons5 := Pads[4];
  Result.Buttons6 := Pads[5];
  Result.Buttons7 := Pads[6];
  Result.Buttons8 := Pads[7];
end;

procedure TSnesCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TEmulatorButton] of TSnesButton = (TSnesButton.Up, TSnesButton.Down, TSnesButton.Left, TSnesButton.Right, TSnesButton.A, TSnesButton.B, TSnesButton.Select, TSnesButton.Start, TSnesButton.L, TSnesButton.X, TSnesButton.Y, TSnesButton.R, TSnesButton.Select);
var
  Button: TEmulatorButton;
begin
  var Pads: array[0..7] of TEmulatorButtons;
  Pads[0] := Input.Buttons;
  Pads[1] := Input.Buttons2;
  Pads[2] := Input.Buttons3;
  Pads[3] := Input.Buttons4;
  Pads[4] := Input.Buttons5;
  Pads[5] := Input.Buttons6;
  Pads[6] := Input.Buttons7;
  Pads[7] := Input.Buttons8;
  for var Port := 0 to 7 do
  begin
    FGamepads[Port] := [];
    for Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      if (Button <> TEmulatorButton.Mode) and (Button in Pads[Port]) then
        Include(FGamepads[Port], Mapping[Button]);
  end;
  ApplySettings;
end;

function TSnesCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
  if Result and FCropOverscan and ((Frame.Height = 239) or (Frame.Height = 478)) then
  begin
    var Border := 7 * (1 + Ord(Frame.Height > 239));
    var NewHeight := 224 * (1 + Ord(Frame.Height > 239));
    Frame.Pixels := Copy(Frame.Pixels, Border * Frame.Width, NewHeight * Frame.Width);
    Frame.Height := NewHeight;
  end;
end;

function TSnesCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TSnesCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
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

