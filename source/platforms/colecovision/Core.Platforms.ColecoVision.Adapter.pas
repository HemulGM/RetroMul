unit Core.Platforms.ColecoVision.Adapter;

interface

uses
  Core.Input.Keyboard, System.SysUtils, System.Classes, System.IniFiles,
  Core.Storage, Core.Emulation, Core.InputConfig, CV.Console, CV.Emulation,
  Core.Emulation.Types;

type
  IColecoKeypadInput = interface
    ['{D3AD8BC8-AFC7-4A67-AE72-F89E5725FB8C}']
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
  end;

  TCVButton = (Up, Down, Left, Right, A, B, Start, Select, X, Y);

  TCVButtons = set of TCVButton;

  TCVKeyMap = array[TCVButton] of UInt32;

  TCVConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TCVKeyMap;
    FPAL, FKeyboardEnabled: Boolean;
    FMapperHint, FVideoHint: Integer;
    FOptions: TCVOptions;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property PAL: Boolean read FPAL;
    property Keys: TCVKeyMap read FKeys;
    property Keys2: TCVKeyMap read FKeys2;
    property KeyboardEnabled: Boolean read FKeyboardEnabled;
    property MapperHint: Integer read FMapperHint;
    property VideoHint: Integer read FVideoHint;
    property Options: TCVOptions read FOptions;
  end;

  TCVCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationKeyboard, IEmulationMouseInput, IColecoKeypadInput)
  private
    FThread: TCVWorker;
    FData, FBootROM: TBytes;
    FSnapshotDirectory, FSaveFile: string;
    FStorage: IStorage;
    FError: string;
    FResolvedPAL: Boolean;
    FHostKeys, FScreenKeys: TCVHostKeys;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TCVKeyMap;
    FKeyboard, FGamepad, FKeyboard2, FGamepad2: TCVButtons;
    FPaused: Boolean;
    FVirtualKeypad: array[0..1] of Word;
    FAnalog: array[0..1] of TEmulatorAnalogPad;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string); overload;
    destructor Destroy; override;
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure SetScreenKeys(const Keys: THostKeyboardKeys);
    function GetHasKeyboard: Boolean;
    function GetSystemId: string;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
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
  System.IOUtils, System.UITypes, System.Hash, System.Math, System.StrUtils,
  CV.Firmware, CV.Cartridge;

const
  KeyNames: array[TCVButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Start', 'Select', 'X', 'Y');

{ TCVConfig }

procedure TCVCoreAdapter.ApplyLiveSettings;
begin
  var Config := FConfig as TCVConfig;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  if FThread <> nil then
    FThread.ConfigureOptions(Config.Options);
  ApplySettings;
end;

constructor TCVConfig.Create(const FileName: string; const Storage: IStorage);
const
  Defaults: TCVKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkReturn, vkSpace, vkC, vkV);
  Defaults2: TCVKeyMap = (vkT, vkG, vkF, vkH,
    vkN, vkM, vkY, vkB, vkO, vkP);
begin
  inherited Create(FileName, Storage);
  FKeys := Defaults;
  FKeys2 := Defaults2;
  FOptions := TCVOptions.Defaults;
  FKeyboardEnabled := True;
  FMapperHint := -1;
  FVideoHint := -1;
end;

procedure TCVConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FPAL := SameText(Ini.ReadString('Video', 'Region', 'NTSC'), 'PAL');
  FKeyboardEnabled := Ini.ReadBool('Ports', 'KeyboardEnabled', True);
  FMapperHint := EnsureRange(Ini.ReadInteger('Cartridge', 'Mapper', -1), -1, Ord(High(TCVMapper)));
  FVideoHint := EnsureRange(Ini.ReadInteger('Video', 'Chip', -1), -1, 1);
  FOptions.ShowBackground := Ini.ReadBool('Video', 'ShowBackground', True);
  FOptions.ShowSprites := Ini.ReadBool('Video', 'ShowSprites', True);
  FOptions.RemoveSpriteLimit := Ini.ReadBool('Video', 'RemoveSpriteLimit', False);
  FOptions.LegacyRAM := Ini.ReadBool('Hardware', 'LegacyRAM', False);
  FOptions.SGMEnabled := Ini.ReadBool('Hardware', 'SGM', True);
  FOptions.MousePort := EnsureRange(Ini.ReadInteger('Ports', 'MousePort', 0), 0, 1);
  FOptions.AYVolume := EnsureRange(Ini.ReadInteger('Audio', 'AYVolume', 100), 0, 100);
  for var I := 0 to 3 do
    FOptions.ChannelVolume[I] := EnsureRange(Ini.ReadInteger('Audio', 'Channel' + IntToStr(I + 1) + 'Volume', 100), 0, 100);
  for var Button := Low(TCVButton) to High(TCVButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TCVConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Video', 'Region', IfThen(FPAL, 'PAL', 'NTSC'));
  Ini.WriteBool('Ports', 'KeyboardEnabled', FKeyboardEnabled);
  Ini.WriteInteger('Cartridge', 'Mapper', FMapperHint);
  Ini.WriteInteger('Video', 'Chip', FVideoHint);
  Ini.WriteBool('Hardware', 'LegacyRAM', FOptions.LegacyRAM);
  Ini.WriteBool('Hardware', 'SGM', FOptions.SGMEnabled);
  Ini.WriteInteger('Ports', 'MousePort', FOptions.MousePort);
  Ini.WriteBool('Video', 'ShowBackground', FOptions.ShowBackground);
  Ini.WriteBool('Video', 'ShowSprites', FOptions.ShowSprites);
  Ini.WriteBool('Video', 'RemoveSpriteLimit', FOptions.RemoveSpriteLimit);
  Ini.WriteInteger('Audio', 'AYVolume', FOptions.AYVolume);
  for var I := 0 to 3 do
    Ini.WriteInteger('Audio', 'Channel' + IntToStr(I + 1) + 'Volume', FOptions.ChannelVolume[I]);
  for var Button := Low(TCVButton) to High(TCVButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

{ TCVCoreAdapter }

constructor TCVCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName);
  finally
    Stream.Free;
  end;
end;

constructor TCVCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FData := ReadRomData(Stream);
  var Config := TCVConfig.Create(FStorage.ConfigFile('colecovision'), FStorage);
  FConfig := Config;
  Config.Load;
  FResolvedPAL := Config.PAL;
  FBootROM := LoadBuiltinColecoBIOS;
  // Validate synchronously, so a bad cartridge never starts a worker.
  var Console := TCVConsole.Create(FData, FBootROM, FResolvedPAL, Config.MapperHint, Config.VideoHint);
  Console.Free;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  var Hash := THashSHA2.Create;
  Hash.Update(FData);
  FSnapshotDirectory := FStorage.GameSnapshots('colecovision', RomName, Hash.HashAsString);
  FSaveFile := FStorage.GameSave('colecovision', RomName, Hash.HashAsString);
end;

destructor TCVCoreAdapter.Destroy;
begin
  // The worker joins before releasing its console and synchronization objects.
  FThread.Free;
  inherited;
end;

procedure TCVCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    var Keys := FHostKeys;
    for var i := 0 to High(Keys) do
      Keys[i] := Keys[i] or FScreenKeys[i];
    for var Port := 0 to 1 do
      for var I := 0 to 11 do
        if FVirtualKeypad[Port] and (1 shl I) <> 0 then
        begin
          var Code := $30 + I + Port * $30;
          if I = 10 then
            Code := $51 - Port * 12;
          if I = 11 then
            Code := $57 - Port * 5;
          Keys[Code] := True;
        end;
    FThread.Configure(GetInputState, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TCVCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TCVWorker.Create(FData, FBootROM, FResolvedPAL, FStorage);
  FThread.Options := TCVConfig(FConfig).Options;
  FThread.MapperHint := TCVConfig(FConfig).MapperHint;
  FThread.VideoHint := TCVConfig(FConfig).VideoHint;
  FThread.SaveFile := FSaveFile;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'colecovision');
  ApplySettings;
  FThread.Start;
end;

procedure TCVCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TCVCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TCVCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TCVCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TCVCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
  (FConfig as TCVConfig).FKeyboardEnabled := Ports.KeyboardEnabled;
end;

procedure TCVCoreAdapter.ClearInput;
begin
  FillChar(FAnalog, SizeOf(FAnalog), 0);
  FillChar(FVirtualKeypad, SizeOf(FVirtualKeypad), 0);
  SendMouseDelta(0, 0, 0);
  FillChar(FHostKeys, SizeOf(FHostKeys), 0);
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FKeyboard := [];
  FGamepad := [];
  FKeyboard2 := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TCVCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TCVButton;
begin
  if GetHasKeyboard then
  begin
    if not TCVConfig(FConfig).KeyboardEnabled then
      Exit;
    if Code <= High(FHostKeys) then
      FHostKeys[Code] := Pressed;
  end;

  for Button := Low(TCVButton) to High(TCVButton) do
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

function TCVCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TCVButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
    TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y);
begin
  Result := Default(TEmulatorInput);
  for var Port := 0 to 1 do
    Result.Analog[Port] := FAnalog[Port];
  for var Button := Low(TCVButton) to High(TCVButton) do
  begin
    if Button in (FKeyboard + FGamepad) then
      Include(Result.Buttons, Mapping[Button]);
    if Button in (FKeyboard2 + FGamepad2) then
      Include(Result.Buttons2, Mapping[Button]);
  end;
  for var I := 0 to 5 do
  begin
    if FScreenKeys[$D0 + I] then
      Include(Result.Buttons, Mapping[TCVButton(I)]);
    if FScreenKeys[$D6 + I] then
      Include(Result.Buttons2, Mapping[TCVButton(I)]);
  end;
end;

procedure TCVCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TCVButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y);
begin
  for var Port := 0 to 1 do
    FAnalog[Port] := Input.Analog[Port];
  FGamepad := [];
  FGamepad2 := [];
  for var Button := Low(TCVButton) to High(TCVButton) do
  begin
    if Mapping[Button] in Input.Buttons then
      Include(FGamepad, Button);
    if Mapping[Button] in Input.Buttons2 then
      Include(FGamepad2, Button);
  end;
  ApplySettings;
end;

function TCVCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TCVCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TCVCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TCVCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

procedure TCVCoreAdapter.SetVirtualKeypad(Port: Integer; Mask: Word);
begin
  if (Port < 0) or (Port > 1) then
    Exit;
  if FVirtualKeypad[Port] = (Mask and $FFF) then
    Exit;
  FVirtualKeypad[Port] := Mask and $FFF;
  ApplySettings;
end;

procedure TCVCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if FThread <> nil then
    FThread.SendMouseDelta(DX, DY, Buttons);
end;

procedure TCVCoreAdapter.SetScreenKeys(const Keys: THostKeyboardKeys);
begin
  Move(Keys, FScreenKeys, SizeOf(FScreenKeys));
  ApplySettings;
end;

function TCVCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := True;
end;

function TCVCoreAdapter.GetSystemId: string;
begin
  Result := 'colecovision';
end;

function TCVCoreAdapter.GetName: string;
begin
  Result := 'ColecoVision';
end;

function TCVCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TCVCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TCVCoreAdapter.InsertCoin1;
begin
end;

procedure TCVCoreAdapter.InsertCoin2;
begin
end;

function TCVCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TCVCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TCVCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TCVCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.

