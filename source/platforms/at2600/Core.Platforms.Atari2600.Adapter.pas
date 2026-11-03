unit Core.Platforms.Atari2600.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  A2600.Console, A2600.Emulation, Core.InputConfig;

type
  TA2600KeyMap = array[TEmulatorButton] of UInt32;

  TA2600Config = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TA2600KeyMap;
    FPAL, FDetectedPAL: Boolean;
    FMapper, FRegion: string;
    FSwitches: Byte;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Keys: TA2600KeyMap read FKeys;
    property PAL: Boolean read FPAL;
    property Mapper: string read FMapper;
    property Keys2: TA2600KeyMap read FKeys2;
  end;

  TA2600CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls, IEmulationMouseInput)
  private
    FCartridge: TBytes;
    FThread: TA2600Worker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TA2600Config;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
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
  RM.Platforms.Atari2600, System.UITypes, Core.Snapshots;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TA2600CoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TA2600Config.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TA2600KeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkA, vkC, vkV, vkS, 0);
  Keys2: TA2600KeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FRegion := 'auto';
  FSwitches := $3F;
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TA2600Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FRegion := Ini.ReadString('Video', 'Region', 'auto');
  if SameText(FRegion, 'pal') then
    FPAL := True
  else if SameText(FRegion, 'ntsc') then
    FPAL := False
  else
  begin
    FPAL := FDetectedPAL;
    // Migrate the old explicit setting only if Region has never been saved.
    if not Ini.ValueExists('Video', 'Region') and Ini.ValueExists('Video', 'PAL') then
    begin
      FPAL := Ini.ReadBool('Video', 'PAL', FDetectedPAL);
      if FPAL then
        FRegion := 'pal'
      else
        FRegion := 'ntsc';
    end;
  end;
  FSwitches := $3F;
  if not Ini.ReadBool('Console', 'Color', True) then
    FSwitches := FSwitches and $F7;
  if Ini.ReadBool('Console', 'DifficultyLeft', False) then
    FSwitches := FSwitches or $40;
  if Ini.ReadBool('Console', 'DifficultyRight', False) then
    FSwitches := FSwitches or $80;
  FMapper := Ini.ReadString('Cartridge', 'Mapper', FMapper);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TA2600Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Video', 'Region', FRegion);
  Ini.WriteBool('Console', 'Color', FSwitches and 8 <> 0);
  Ini.WriteBool('Console', 'DifficultyLeft', FSwitches and $40 <> 0);
  Ini.WriteBool('Console', 'DifficultyRight', FSwitches and $80 <> 0);
  Ini.WriteString('Cartridge', 'Mapper', FMapper);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TA2600CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > 512 * 1024) then
    raise EReadError.Create('Atari 2600 cartridge exceeds 512 KiB or is empty');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  Stream.ReadBuffer(Data[0], Length(Data));
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  FCartridge := Copy(Data);
  FConfigObject := TA2600Config.Create(FStorage.ConfigFile('at2600'), FStorage);
  FConfigObject.FDetectedPAL := (ImageName + ' ' + SourceName).ToUpper.Contains('(PAL)');
  FConfigObject.FPAL := FConfigObject.FDetectedPAL;
  FConfig := FConfigObject;
  FConfig.Load;
  var Check := TA2600Console.Create(Data, FConfigObject.PAL, FConfigObject.Mapper);
  Check.Free;
  FSnapshotDirectory := FStorage.GameSnapshots('at2600', RomName, SnapshotIdentity(Data));
end;

destructor TA2600CoreAdapter.Destroy;
begin
  FThread.Free;

  inherited;
end;

procedure TA2600CoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FConfigObject.FSwitches);
end;

procedure TA2600CoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TA2600Worker.Create(FCartridge, FConfigObject.PAL, FConfigObject.Mapper, FStorage);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'at2600');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TA2600CoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.Stop;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TA2600CoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TA2600CoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TA2600CoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TA2600CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TA2600CoreAdapter.ClearInput;
begin
  if FThread <> nil then
    FThread.ClearMouseInput;
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TA2600CoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if FThread <> nil then
    FThread.SendMouseDelta(DX, DY, Buttons);
end;

procedure TA2600CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TA2600CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TA2600CoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  if FThread <> nil then
    Result := FThread.SupportedButtons
  else
    Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.Start, TEmulatorButton.Select];
end;

function TA2600CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TA2600CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TA2600CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TA2600CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TA2600CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TA2600CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TA2600CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TA2600CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TA2600CoreAdapter.GetSystemId: string;
begin
  Result := 'at2600';
end;

function TA2600CoreAdapter.GetName: string;
begin
  Result := 'Atari 2600';
end;

function TA2600CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TA2600CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TA2600CoreAdapter.InsertCoin1;
begin
end;

procedure TA2600CoreAdapter.InsertCoin2;
begin
end;

function TA2600CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

