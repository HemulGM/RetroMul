unit Core.Platforms.Jaguar.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Jaguar.Console, Jaguar.Emulation, Core.InputConfig, Jaguar.Jerry, Core.CD.Disc;

type
  IJaguarKeypadInput = interface
    ['{77FA9E0F-0E83-4774-A4FA-25FB526D6C59}']
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
  end;

  TJaguarKeyMap = array[TEmulatorButton] of UInt32;

  TJaguarConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TJaguarKeyMap;
    FBootBIOS, FPAL: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property BootBIOS: Boolean read FBootBIOS;
    property PAL: Boolean read FPAL;
    property Keys: TJaguarKeyMap read FKeys;
    property Keys2: TJaguarKeyMap read FKeys2;
  end;

  TJaguarCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls, IJaguarKeypadInput, IEmulationDiscControl)
  private
    FCartridge: TBytes;
    FDisc: TCDDisc;
    FDiscLocations, FDiscNames: TArray<string>;
    FDiscIndex: Integer;
    FCDHardware: Boolean;
    FThread: TJaguarWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TJaguarConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FVirtualKeypads: TJaguarKeypads;
    FPaused: Boolean;
    FError, FSnapshotDirectory, FBatteryPath: string;
    procedure ApplySettings;
    procedure ReplaceDisc(const Location: string; Index: Integer);
  public
    function GetDiscCount: Integer;
    function GetDiscName(Index: Integer): string;
    function GetDiscIndex: Integer;
    procedure ChangeDisc(Index: Integer);
    procedure OpenDisc(const Location: string);
    procedure EjectDisc;
    procedure SetVirtualKeypad(Port: Integer; Mask: Word);
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string = ''; OwnedDisc: TCDDisc = nil);
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
  System.UITypes, System.IOUtils, System.Hash, Core.Snapshots, Jaguar.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TJaguarCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TJaguarConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TJaguarKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkC, vkA, vkS, vkD, vkTab);
  Keys2: TJaguarKeyMap = (vkI, vkK, vkJ, vkL, vkDivide, vkMultiply, vkP, vkO, vkU, 0, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TJaguarConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBootBIOS := Ini.ReadBool('Hardware', 'BootBIOS', False);
  FPAL := Ini.ReadBool('Video', 'PAL', False);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TJaguarConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteBool('Hardware', 'BootBIOS', FBootBIOS);
  Ini.WriteBool('Video', 'PAL', FPAL);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TJaguarCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string; OwnedDisc: TCDDisc);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FDisc := OwnedDisc;
  FDiscIndex := -1;
  var Ext := ExtractFileExt(RomName).ToLower;
  FCDHardware := (FDisc <> nil) or (Ext = '.m3u') or
    (Ext = '.cue') or (Ext = '.chd') or (Ext = '.cdi') or
    (Ext = '.mds') or (Ext = '.nrg') or (Ext = '.ccd');
  if FCDHardware then
  begin
    if Ext = '.m3u' then
      FDiscLocations := ReadCDPlaylist(Stream, FStorage, RomName, 'jaguarcd')
    else
      FDiscLocations := [RomName];
    SetLength(FDiscNames, Length(FDiscLocations));
    for var i := 0 to High(FDiscLocations) do
      FDiscNames[i] := FStorage.Describe(FDiscLocations[i]).Name;
    if Length(FDiscLocations) = 0 then
      raise EReadError.Create('Empty Jaguar CD playlist');
    if FDisc = nil then
    begin
      if Ext = '.m3u' then
      begin
        var Image := FStorage.OpenRead(FDiscLocations[0]);
        try
          FDisc := TCDDisc.Create(Image, FStorage, FDiscLocations[0]);
        finally
          Image.Free;
        end;
      end
      else
        FDisc := TCDDisc.Create(Stream, FStorage, RomName);
    end;
    FDiscIndex := 0;
    FCartridge := LoadJaguarCDBIOS;
    FConfigObject := TJaguarConfig.Create(FStorage.ConfigFile('jaguar'), FStorage);
    FConfig := FConfigObject;
    FConfig.Load;
    var Identity := FDisc.Identity;
    FSnapshotDirectory := FStorage.GameSnapshots('jaguarcd', RomName, SnapshotIdentity(Identity));
    FBatteryPath := FStorage.GameSave('jaguarcd', 'MemoryTrack', 'atari-nvm-romulator-v1');
    Exit;
  end;
  if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > $600000) then
    raise EReadError.Create('Atari Jaguar cartridge exceeds 6 MiB or is empty');

  var Data: TBytes;
  SetLength(Data, Stream.Size - Stream.Position);
  Stream.ReadBuffer(Data[0], Length(Data));
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  FCartridge := Copy(Data);
  FConfigObject := TJaguarConfig.Create(FStorage.ConfigFile('jaguar'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  var Check := TJaguarConsole.Create(Data, LoadJaguarBIOS, FConfigObject.PAL, FConfigObject.BootBIOS);
  Check.Free;
  FSnapshotDirectory := FStorage.GameSnapshots('jaguar', RomName, SnapshotIdentity(Data));
  FBatteryPath := FStorage.GameSave('jaguar', RomName, SnapshotIdentity(Data));
end;

destructor TJaguarCoreAdapter.Destroy;
begin
  FThread.Free;
  FDisc.Free;
  inherited;
end;

procedure TJaguarCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FVirtualKeypads);
  end;
end;

procedure TJaguarCoreAdapter.SetVirtualKeypad(Port: Integer; Mask: Word);
begin
  if (Port < 0) or (Port > 7) then
    Exit;
  FVirtualKeypads[Port] := Mask and $FFF;
  ApplySettings;
end;

procedure TJaguarCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TJaguarWorker.Create(FCartridge, FStorage, FConfigObject.PAL, FConfigObject.BootBIOS, FDisc, FCDHardware);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'jaguar');
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.BatteryPath := FBatteryPath;
  ApplySettings;
  FThread.Start;
end;

procedure TJaguarCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.Stop;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TJaguarCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TJaguarCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TJaguarCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TJaguarCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TJaguarCoreAdapter.ClearInput;
begin
  FillChar(FVirtualKeypads, SizeOf(FVirtualKeypads), 0);
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TJaguarCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TJaguarCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TJaguarCoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  if FThread <> nil then
    Result := FThread.SupportedButtons
  else
    Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.C, TEmulatorButton.Start, TEmulatorButton.Select, TEmulatorButton.X, TEmulatorButton.Y, TEmulatorButton.Z];
end;

function TJaguarCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TJaguarCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TJaguarCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TJaguarCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TJaguarCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TJaguarCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TJaguarCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TJaguarCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TJaguarCoreAdapter.GetDiscCount: Integer;
begin
  Result := Length(FDiscLocations);
end;

function TJaguarCoreAdapter.GetDiscIndex: Integer;
begin
  Result := FDiscIndex;
end;

function TJaguarCoreAdapter.GetDiscName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  Result := FDiscNames[Index];
end;

procedure TJaguarCoreAdapter.ReplaceDisc(const Location: string; Index: Integer);
begin
  var Image := FStorage.OpenRead(Location);
  var Disc: TCDDisc;
  try
    Disc := TCDDisc.Create(Image, FStorage, Location);
  finally
    Image.Free;
  end;
  try
    Disc.Identity; // Hash before the worker starts using its streams.
    if FThread <> nil then
      FThread.ChangeDisc(Disc);
  except
    Disc.Free;
    raise;
  end;
  FDisc.Free;
  FDisc := Disc;
  FDiscIndex := Index;
end;

procedure TJaguarCoreAdapter.ChangeDisc(Index: Integer);
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  if Index <> FDiscIndex then
    ReplaceDisc(FDiscLocations[Index], Index);
end;

procedure TJaguarCoreAdapter.OpenDisc(const Location: string);
begin
  if not FCDHardware then
    raise EInvalidOpException.Create('Jaguar CD hardware is not installed');
  for var i := 0 to High(FDiscLocations) do
    if FDiscLocations[i] = Location then
    begin
      ChangeDisc(i);
      Exit;
    end;
  var Locations := FDiscLocations + [Location];
  var Names := FDiscNames + [FStorage.Describe(Location).Name];
  ReplaceDisc(Location, Length(FDiscLocations));
  FDiscLocations := Locations;
  FDiscNames := Names;
end;

procedure TJaguarCoreAdapter.EjectDisc;
begin
  if not FCDHardware or (FDiscIndex < 0) then
    Exit;
  if FThread <> nil then
    FThread.ChangeDisc(nil);
  FreeAndNil(FDisc);
  FDiscIndex := -1;
end;

function TJaguarCoreAdapter.GetSystemId: string;
begin
  Result := 'jaguar';
  if FCDHardware then
    Result := 'jaguarcd';
end;

function TJaguarCoreAdapter.GetName: string;
begin
  Result := 'Atari Jaguar';
  if FCDHardware then
    Result := 'Atari Jaguar CD';
end;

function TJaguarCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TJaguarCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TJaguarCoreAdapter.InsertCoin1;
begin
end;

procedure TJaguarCoreAdapter.InsertCoin2;
begin
end;

function TJaguarCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

