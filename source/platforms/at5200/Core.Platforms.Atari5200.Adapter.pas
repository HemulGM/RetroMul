unit Core.Platforms.Atari5200.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  A5200.Console, A5200.Emulation, Core.InputConfig, A5200.Controller;

type
  IAtari5200KeypadInput = interface
    ['{2B623A36-5168-40C3-A665-0BB5D9BB072C}']
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
  end;

  TA5200KeyMap = array[TEmulatorButton] of UInt32;

  TA5200Config = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TA5200KeyMap;
    FMapper: Integer;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TA5200KeyMap read FKeys;
    property Mapper: Integer read FMapper;
    property Keys2: TA5200KeyMap read FKeys2;
  end;

  TA5200CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls, IAtari5200KeypadInput)
  private
    FCartridge: TBytes;
    FThread: TA5200Worker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TA5200Config;
    FKeyboard, FGamepad: TEmulatorInput;
    FVirtualKeypads: TA5200Keypads;
    FPaused: Boolean;
    FError, FSnapshotDirectory: string;
    procedure ApplySettings;
  public
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
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
  RM.Platforms.Atari5200, System.UITypes, Core.Snapshots, A5200.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TA5200CoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TA5200Config.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TA5200KeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkA, vkC, vkV, vkS, vkC);
  Keys2: TA5200KeyMap = (vkI, vkK, vkJ, vkL, vkDivide, vkMultiply, 0, vkO, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FMapper := -1;
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TA5200Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FMapper := Ini.ReadInteger('Cartridge', 'Mapper', -1);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TA5200Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteInteger('Cartridge', 'Mapper', FMapper);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TA5200CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > 40976) then
    raise EReadError.Create('Atari 5200 cartridge exceeds 40 KiB + header or is empty');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  Stream.ReadBuffer(Data[0], Length(Data));
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  FCartridge := Copy(Data);
  FConfigObject := TA5200Config.Create(FStorage.ConfigFile('at5200'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  var Check := TA5200Console.Create(Data, LoadBuiltinAtari5200BIOS, FConfigObject.Mapper);
  Check.Free;
  FSnapshotDirectory := FStorage.GameSnapshots('at5200', RomName, SnapshotIdentity(Data));
end;

destructor TA5200CoreAdapter.Destroy;
begin
  FThread.Free;

  inherited;
end;

procedure TA5200CoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FVirtualKeypads);
  end;
end;

procedure TA5200CoreAdapter.SetVirtualKeypad(Port: Integer; Mask: Word);
begin
  if (Port < 0) or (Port > 3) then
    Exit;
  FVirtualKeypads[Port] := Mask and $7FFF;
  ApplySettings;
end;

procedure TA5200CoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TA5200Worker.Create(FCartridge, FConfigObject.Mapper, FStorage);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'at5200');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TA5200CoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.Stop;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TA5200CoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TA5200CoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TA5200CoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TA5200CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TA5200CoreAdapter.ClearInput;
begin
  FillChar(FVirtualKeypads, SizeOf(FVirtualKeypads), 0);
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TA5200CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TA5200CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TA5200CoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  if FThread <> nil then
    Result := FThread.SupportedButtons
  else
    Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Start, TEmulatorButton.Select];
end;

function TA5200CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TA5200CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TA5200CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TA5200CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TA5200CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TA5200CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TA5200CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TA5200CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TA5200CoreAdapter.GetSystemId: string;
begin
  Result := 'at5200';
end;

function TA5200CoreAdapter.GetName: string;
begin
  Result := 'Atari 5200';
end;

function TA5200CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TA5200CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TA5200CoreAdapter.InsertCoin1;
begin
end;

procedure TA5200CoreAdapter.InsertCoin2;
begin
end;

function TA5200CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

