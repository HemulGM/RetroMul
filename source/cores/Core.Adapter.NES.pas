unit Core.Adapter.NES;

interface

uses
  System.Classes, System.IniFiles, Core.Storage, Core.Emulation, NES.Emulation,
  NES.Input, NES.Types, NES.Controller, NES.FamicomKeyboardDevice,
  NES.FamicomDataRecorder;

type
  TNesZapperMask = NES.Types.TNesZapperMask;

  INesPeripheralCore = interface
    ['{E2878EE8-4AED-4E93-A006-7DBD5A63ABED}']
    procedure SetSuborKeys(const Keys: TSuborKeys);
    procedure SetFamicomKeys(const Keys: TFamicomKeys);
    function GetFamicomKeys: TFamicomKeys;
    function UsesFamicomKeyboard: Boolean;
    procedure SetPowerPadButtons(const Buttons: TPowerPadButtons);
    function GetSuborKeys: TSuborKeys;
    function GetSuborIndicators: TSuborIndicators;
    function GetPowerPadButtons: TPowerPadButtons;
    function Zapper: TZapper;
    function UsesPowerPad: Boolean;
  end;

  INesTapeCore = interface
    ['{0A3514F2-7804-45BB-BFD0-2BACD5DE9AD3}']
    function UsesDataRecorder: Boolean;
    function GetTapeState: TTapeState;
    function GetTapeProgress: TTapeProgress;
    procedure TapeCommand(Action: TTapeAction; const FileName: string = '');
  end;

  INesEmulatorConfig = interface(IEmulatorConfig)
    ['{EDE593B6-24DD-4D4E-B4CA-30E4B33D7688}']
    function GetFourScore: Boolean;
    procedure SetFourScore(const Value: Boolean);
    function GetZapperEnabled: Boolean;
    procedure SetZapperEnabled(const Value: Boolean);
    function GetRegion: TRegionOverride;
    procedure SetRegion(const Value: TRegionOverride);
    function GetKeys: TKeyMap;
    procedure SetKeys(const Value: TKeyMap);
    function GetKeys2: TKeyMap;
    procedure SetKeys2(const Value: TKeyMap);
    function GetKeys3: TKeyMap;
    procedure SetKeys3(const Value: TKeyMap);
    function GetKeys4: TKeyMap;
    procedure SetKeys4(const Value: TKeyMap);
    property FourScore: Boolean read GetFourScore write SetFourScore;
    property ZapperEnabled: Boolean read GetZapperEnabled write SetZapperEnabled;
    property Region: TRegionOverride read GetRegion write SetRegion;
    property Keys: TKeyMap read GetKeys write SetKeys;
    property Keys2: TKeyMap read GetKeys2 write SetKeys2;
    property Keys3: TKeyMap read GetKeys3 write SetKeys3;
    property Keys4: TKeyMap read GetKeys4 write SetKeys4;
  end;

  TNesEmulatorConfig = class(TEmulatorConfigBase, INesEmulatorConfig)
  private
    FFourScore: Boolean;
    FZapperEnabled: Boolean;
    FRegion: TRegionOverride;
    FKeys, FKeys2, FKeys3, FKeys4: TKeyMap;
    procedure LoadKeyMap(Ini: TCustomIniFile; const Section: string; var Keys: TKeyMap);
    procedure SaveKeyMap(Ini: TCustomIniFile; const Section: string; const Keys: TKeyMap);
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const AFileName: string; const Storage: IStorage = nil);
    function GetFourScore: Boolean;
    procedure SetFourScore(const Value: Boolean);
    function GetZapperEnabled: Boolean;
    procedure SetZapperEnabled(const Value: Boolean);
    function GetRegion: TRegionOverride;
    procedure SetRegion(const Value: TRegionOverride);
    function GetKeys: TKeyMap;
    procedure SetKeys(const Value: TKeyMap);
    function GetKeys2: TKeyMap;
    procedure SetKeys2(const Value: TKeyMap);
    function GetKeys3: TKeyMap;
    procedure SetKeys3(const Value: TKeyMap);
    function GetKeys4: TKeyMap;
    procedure SetKeys4(const Value: TKeyMap);
  end;

  TNesCoreAdapter = class(TInterfacedObject, IEmulationCore, INesPeripheralCore, INesTapeCore)
  private
    FThread: TNesEmulationThread;
    FGamepadInput: TEmulatorInput;
    FConfig: INesEmulatorConfig;
    FFrameNumber: UInt64;
    FError: string;
    procedure ApplyGamepadInput;
    function GetName: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
  public
    constructor Create(const FileName: string; const ConfigFileName: string = ''); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ConfigFileName: string = ''); overload;
    destructor Destroy; override;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    property HasCoinAcceptor: Boolean read GetHasCoinAcceptor;
    procedure Start;
    function UsesDataRecorder: Boolean;
    function GetTapeState: TTapeState;
    function GetTapeProgress: TTapeProgress;
    procedure TapeCommand(Action: TTapeAction; const FileName: string = '');
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    function GetSuborKeys: TSuborKeys;
    function GetSuborIndicators: TSuborIndicators;
    function GetPowerPadButtons: TPowerPadButtons;
    procedure SetSuborKeys(const Keys: TSuborKeys);
    procedure SetFamicomKeys(const Keys: TFamicomKeys);
    function GetFamicomKeys: TFamicomKeys;
    function UsesFamicomKeyboard: Boolean;
    procedure SetPowerPadButtons(const Buttons: TPowerPadButtons);
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function Zapper: TZapper;
    function UsesPowerPad: Boolean;
  end;

implementation

uses
  Core.RomFormat, System.SysUtils, System.UITypes;

{ TNesCoreAdapter }

function TNesCoreAdapter.UsesDataRecorder: Boolean;
begin
  Result := FThread.UsesDataRecorder;
end;

function TNesCoreAdapter.GetTapeState: TTapeState;
begin
  Result := FThread.GetTapeState;
end;

function TNesCoreAdapter.GetTapeProgress: TTapeProgress;
begin
  Result := FThread.GetTapeProgress;
end;

procedure TNesCoreAdapter.TapeCommand(Action: TTapeAction; const FileName: string);
begin
  FThread.TapeCommand(Action, FileName);
end;

constructor TNesCoreAdapter.Create(const FileName, ConfigFileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName, ConfigFileName);
  finally
    Stream.Free;
  end;
end;

constructor TNesCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName, ConfigFileName: string);
begin
  inherited Create;
  var CoreStorage := Storage;
  if CoreStorage = nil then
    CoreStorage := TStorage.Default;
  var ConfigPath := ConfigFileName;
  if ConfigPath = '' then
    ConfigPath := CoreStorage.ConfigFile(ROM_SYSTEM_NES);
  FConfig := TNesEmulatorConfig.Create(ConfigPath, CoreStorage);
  FConfig.Load;
  FThread := TNesEmulationThread.Create(Stream, CoreStorage, RomName,
    FConfig.FourScore, FConfig.Region, FConfig.AudioEnabled, FConfig.AudioVolume);
  // Select port 2 before starting the worker. A light gun replaces the pad
  // and changes reads even when the trigger is not pressed.
  FThread.Console.Zapper.Enabled := FConfig.ZapperEnabled and
    not FThread.Console.UsesPowerPad;
end;

destructor TNesCoreAdapter.Destroy;
begin
  Stop;
  FThread.Free;
  inherited;
end;

function TNesCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TNesButton] of TEmulatorButton =
    (TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select,
    TEmulatorButton.Start, TEmulatorButton.Up, TEmulatorButton.Down,
    TEmulatorButton.Left, TEmulatorButton.Right);
var
  Buttons, Buttons2: TNesButtons;
begin
  FThread.GetButtons(Buttons, Buttons2);
  Result := Default(TEmulatorInput);
  for var Button := Low(TNesButton) to High(TNesButton) do
  begin
    if Button in Buttons then
      Include(Result.Buttons, Mapping[Button]);
    if Button in Buttons2 then
      Include(Result.Buttons2, Mapping[Button]);
  end;
end;

function TNesCoreAdapter.GetFamicomKeys: TFamicomKeys;
begin
  Result := FThread.GetFamicomKeys;
end;

function TNesCoreAdapter.UsesFamicomKeyboard: Boolean;
begin
  Result := FThread.UsesFamicomKeyboard;
end;

procedure TNesCoreAdapter.SetFamicomKeys(const Keys: TFamicomKeys);
begin
  FThread.SetFamicomKeys(Keys);
end;

function TNesCoreAdapter.GetSuborKeys: TSuborKeys;
begin
  Result := FThread.GetSuborKeys;
end;

function TNesCoreAdapter.GetSuborIndicators: TSuborIndicators;
begin
  Result := FThread.GetSuborIndicators;
end;

function TNesCoreAdapter.GetPowerPadButtons: TPowerPadButtons;
begin
  Result := FThread.GetPowerPadButtons;
end;

procedure TNesCoreAdapter.ApplyGamepadInput;
var
  Buttons: TNesButtons;
begin
  Buttons := [];
  if TEmulatorButton.A in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.A);
  if TEmulatorButton.B in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.B);
  if TEmulatorButton.Select in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Select);
  if TEmulatorButton.Start in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Start);
  if TEmulatorButton.Up in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Up);
  if TEmulatorButton.Down in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Down);
  if TEmulatorButton.Left in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Left);
  if TEmulatorButton.Right in FGamepadInput.Buttons then
    Include(Buttons, TNesButton.Right);
  FThread.SetButtons(INPUT_SCREEN_GAMEPAD, 1, Buttons);
end;

procedure TNesCoreAdapter.ClearInput;
begin
  FGamepadInput := Default(TEmulatorInput);
  FThread.ClearInput;
end;

function TNesCoreAdapter.GetName: string;
begin
  Result := 'NES';
end;

function TNesCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TNesCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := FThread.Console.HasCoinAcceptor;
end;

procedure TNesCoreAdapter.InsertCoin1;
begin
  FThread.InsertCoin1;
end;

procedure TNesCoreAdapter.InsertCoin2;
begin
  FThread.InsertCoin2;
end;

function TNesCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := FThread.UsesSuborKeyboard;
end;

function TNesCoreAdapter.IsPaused: Boolean;
begin
  Result := FThread.IsPausd;
end;

procedure TNesCoreAdapter.LoadSnapshot(const Name: string);
begin
  FThread.LoadSnapshot(Name);
  FError := '';
end;

procedure TNesCoreAdapter.Pause;
begin
  FThread.RequestPause;
end;

procedure TNesCoreAdapter.Reset;
begin
  FThread.RequestReset;
  FError := '';
end;

procedure TNesCoreAdapter.Resume;
begin
  FThread.RequestResume;
end;

procedure TNesCoreAdapter.SaveSnapshot(const Name: string);
begin
  FThread.SaveSnapshot(Name);
end;

procedure TNesCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepadInput := Input;
  ApplyGamepadInput;
end;

procedure TNesCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  FThread.SetKey(Code, Pressed, FConfig.Keys, FConfig.Keys2, FConfig.Keys3, FConfig.Keys4);
end;

procedure TNesCoreAdapter.SetSuborKeys(const Keys: TSuborKeys);
begin
  FThread.SetSuborKeys(Keys);
end;

procedure TNesCoreAdapter.SetPowerPadButtons(const Buttons: TPowerPadButtons);
begin
  FThread.SetPowerPadButtons(Buttons);
end;

procedure TNesCoreAdapter.Start;
begin
  FThread.Start;
end;

procedure TNesCoreAdapter.Stop;
begin
  if (FThread <> nil) and not FThread.Finished then
    FThread.StopAndSave;
end;

function TNesCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
end;

function TNesCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TNesCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
var
  NesFrame: TFrameBuffer;
  Status: TEmulationStatus;
begin
  Result := FThread.TakeSnapshot(NesFrame, Status);
  if Status.Error <> '' then
    FError := Status.Error;
  if not Result then
    Exit;

  Frame.Width := 256;
  Frame.Height := 240;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  for var Y := 0 to Frame.Height - 1 do
    for var X := 0 to Frame.Width - 1 do
      Frame.Pixels[Y * Frame.Width + X] := NesFrame[X, Y] or $FF000000;
  Inc(FFrameNumber);
  Frame.FrameNumber := FFrameNumber;
  Frame.FramesPerSecond := Status.FramesPerSecond;
end;

function TNesCoreAdapter.Zapper: TZapper;
begin
  Result := FThread.Console.Zapper;
end;

function TNesCoreAdapter.UsesPowerPad: Boolean;
begin
  Result := FThread.Console.UsesPowerPad;
end;

{ TNesEmulatorConfig }

constructor TNesEmulatorConfig.Create(const AFileName: string; const Storage: IStorage);
begin
  inherited Create(AFileName, Storage);
  FKeys.A := vkZ;
  FKeys.B := vkX;
  FKeys.Select := vkSpace;
  FKeys.Start := vkReturn;
  FKeys.Up := vkUp;
  FKeys.Down := vkDown;
  FKeys.Left := vkLeft;
  FKeys.Right := vkRight;
  FKeys2.A := vkG;
  FKeys2.B := vkH;
  FKeys2.Select := vkT;
  FKeys2.Start := vkY;
  FKeys2.Up := vkW;
  FKeys2.Down := vkS;
  FKeys2.Left := vkA;
  FKeys2.Right := vkD;
  FKeys3.A := vkN;
  FKeys3.B := vkM;
  FKeys3.Select := vkU;
  FKeys3.Start := vkO;
  FKeys3.Up := vkI;
  FKeys3.Down := vkK;
  FKeys3.Left := vkJ;
  FKeys3.Right := vkL;
  FKeys4.A := vkNumpad1;
  FKeys4.B := vkNumpad3;
  FKeys4.Select := vkNumpad7;
  FKeys4.Start := vkNumpad9;
  FKeys4.Up := vkNumpad8;
  FKeys4.Down := vkNumpad5;
  FKeys4.Left := vkNumpad4;
  FKeys4.Right := vkNumpad6;
  FFourScore := True;
  FZapperEnabled := False;
  FRegion := TRegionOverride.Auto;
end;

function ReadKey(Ini: TCustomIniFile; const Section, Name: string; DefaultValue: UInt32): UInt32;
begin
  Result := ReadEmulatorKey(Ini, Section, Name, DefaultValue);
end;

procedure TNesEmulatorConfig.LoadKeyMap(Ini: TCustomIniFile; const Section: string; var Keys: TKeyMap);
begin
  Keys.A := ReadKey(Ini, Section, 'A', Keys.A);
  Keys.B := ReadKey(Ini, Section, 'B', Keys.B);
  Keys.Select := ReadKey(Ini, Section, 'Select', Keys.Select);
  Keys.Start := ReadKey(Ini, Section, 'Start', Keys.Start);
  Keys.Up := ReadKey(Ini, Section, 'Up', Keys.Up);
  Keys.Down := ReadKey(Ini, Section, 'Down', Keys.Down);
  Keys.Left := ReadKey(Ini, Section, 'Left', Keys.Left);
  Keys.Right := ReadKey(Ini, Section, 'Right', Keys.Right);
end;

procedure TNesEmulatorConfig.SaveKeyMap(Ini: TCustomIniFile; const Section: string; const Keys: TKeyMap);
begin
  Ini.WriteInteger(Section, 'A', Keys.A);
  Ini.WriteInteger(Section, 'B', Keys.B);
  Ini.WriteInteger(Section, 'Select', Keys.Select);
  Ini.WriteInteger(Section, 'Start', Keys.Start);
  Ini.WriteInteger(Section, 'Up', Keys.Up);
  Ini.WriteInteger(Section, 'Down', Keys.Down);
  Ini.WriteInteger(Section, 'Left', Keys.Left);
  Ini.WriteInteger(Section, 'Right', Keys.Right);
end;

procedure TNesEmulatorConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FFourScore := Ini.ReadBool('Input', 'FourScore', FFourScore);
  FZapperEnabled := Ini.ReadBool('Input', 'Zapper', False);
  var Region := Ini.ReadString('Video', 'Region', 'Auto');
  if SameText(Region, 'PAL') then
    FRegion := TRegionOverride.PAL
  else if SameText(Region, 'NTSC') then
    FRegion := TRegionOverride.NTSC
  else
    FRegion := TRegionOverride.Auto;
  LoadKeyMap(Ini, 'Controls', FKeys);
  LoadKeyMap(Ini, 'Controls2', FKeys2);
  LoadKeyMap(Ini, 'Controls3', FKeys3);
  LoadKeyMap(Ini, 'Controls4', FKeys4);
end;

procedure TNesEmulatorConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteBool('Input', 'FourScore', FFourScore);
  Ini.WriteBool('Input', 'Zapper', FZapperEnabled);
  case FRegion of
    TRegionOverride.NTSC:
      Ini.WriteString('Video', 'Region', 'NTSC');
    TRegionOverride.PAL:
      Ini.WriteString('Video', 'Region', 'PAL');
  else
    Ini.WriteString('Video', 'Region', 'Auto');
  end;
  SaveKeyMap(Ini, 'Controls', FKeys);
  SaveKeyMap(Ini, 'Controls2', FKeys2);
  SaveKeyMap(Ini, 'Controls3', FKeys3);
  SaveKeyMap(Ini, 'Controls4', FKeys4);
end;

function TNesEmulatorConfig.GetFourScore: Boolean;
begin
  Result := FFourScore;
end;

function TNesEmulatorConfig.GetZapperEnabled: Boolean;
begin
  Result := FZapperEnabled;
end;

procedure TNesEmulatorConfig.SetZapperEnabled(const Value: Boolean);
begin
  FZapperEnabled := Value;
end;

function TNesEmulatorConfig.GetRegion: TRegionOverride;
begin
  Result := FRegion;
end;

function TNesEmulatorConfig.GetKeys: TKeyMap;
begin
  Result := FKeys;
end;

function TNesEmulatorConfig.GetKeys2: TKeyMap;
begin
  Result := FKeys2;
end;

function TNesEmulatorConfig.GetKeys3: TKeyMap;
begin
  Result := FKeys3;
end;

function TNesEmulatorConfig.GetKeys4: TKeyMap;
begin
  Result := FKeys4;
end;

procedure TNesEmulatorConfig.SetFourScore(const Value: Boolean);
begin
  FFourScore := Value;
end;

procedure TNesEmulatorConfig.SetRegion(const Value: TRegionOverride);
begin
  FRegion := Value;
end;

procedure TNesEmulatorConfig.SetKeys(const Value: TKeyMap);
begin
  FKeys := Value;
end;

procedure TNesEmulatorConfig.SetKeys2(const Value: TKeyMap);
begin
  FKeys2 := Value;
end;

procedure TNesEmulatorConfig.SetKeys3(const Value: TKeyMap);
begin
  FKeys3 := Value;
end;

procedure TNesEmulatorConfig.SetKeys4(const Value: TKeyMap);
begin
  FKeys4 := Value;
end;

end.
