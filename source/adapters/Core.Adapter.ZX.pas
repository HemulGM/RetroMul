unit Core.Adapter.ZX;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, Core.Adapter.SG1000, SG1000.Console, ZX.Console,
  ZX.Emulation, ZX.Machine, ZX.Configuration;

type
  IZXTapeCore = interface
    ['{4F830A0B-C699-4D48-AAD7-99682BC50911}']
    function GetTapeStatus: string;
    procedure ToggleTape;
    procedure RewindTape;
    procedure SelectTapePart(Index: Integer);
  end;

  TZXKeyMap = array[TEmulatorButton] of UInt32;

  TZXConfig = class(TEmulatorConfigBase)
  private
    function GetTape128: Boolean;
    function GetPentagon: Boolean;
    function GetPentagonRAMKB: Integer;
  public
    Keys: TZXKeyMap;
    Machine: TZXMachineConfig;
    ServiceROMFile, DivImageFile, DivFirmwareFile, TimexCartridgeFile, NeoGSImageFile: string;
    Options: TZXRuntimeOptions;
    // Read-only compatibility views; Machine is the single source of truth.
    property Tape128: Boolean read GetTape128;
    property Pentagon: Boolean read GetPentagon;
    property PentagonRAMKB: Integer read GetPentagonRAMKB;
    constructor Create(const FileName: string; const Storage: IStorage);
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  end;

  TZXCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls, ISGKeyboardCore, IZXTapeCore, IEmulationMouseInput)
  private
    FThread: TZXWorker;
    FPreparedConsole: TZXConsole;
    FPreparedMachine: TZXMachineConfig;
    FPreparedOptions: TZXRuntimeOptions;
    FPreparedKey: string;
    FData: TBytes;
    FName, FSnapshotDirectory, FError: string;
    FDivImageFile: string;
    FDivImageHash: TBytes;
    FDivImageLock: TStream;
    FNeoGSImageFile: string;
    FNeoGSImageHash: TBytes;
    FNeoGSImageLock: TStream;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FKeys, FScreenKeys: TZXHostKeys;
    FKeyboard, FGamepad: TEmulatorInput;
    FPorts: TCoreInputPorts;
    FPaused: Boolean;
    FTapeKeyDown: array[0..255] of Boolean;
    FChoicePage: Integer;
    function PreparationKey: string;
    procedure InitializeImage(Stream: TStream; const OwnedData: TBytes; const Storage: IStorage; const RomName, ImageName: string);
    function SessionMachine: TZXMachineConfig;
    procedure ApplySettings;
  public
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; const ImageName: string = '');
    // Transfers Data ownership; caller must not retain writable aliases.
    constructor CreateOwned(var Data: TBytes; const Storage: IStorage; const RomName, ImageName: string);
    destructor Destroy; override;
    function GetName: string;
    function GetTapeStatus: string;
    procedure ToggleTape;
    procedure RewindTape;
    procedure SelectTapePart(Index: Integer);
    function TapeKey(Code: UInt32; Pressed: Boolean): Boolean;
    function GetSystemId: string;
    function GetSupportsSnapshots: Boolean;
    function GetUsesSuborKeyboard: Boolean;
    function GetHasCoinAcceptor: Boolean;
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure Start;
    procedure Stop;
    procedure Pause;
    procedure Resume;
    procedure Reset;
    procedure ClearInput;
    procedure SetKeyState(Code: UInt32; Pressed: Boolean);
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    procedure SetGamepadInput(const Input: TEmulatorInput);
    function GetInputState: TEmulatorInput;
    function GetVirtualButtons: TEmulatorButtons;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function GetSnapshotDirectory: string;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
  end;

function IsZXImageName(const Name: string): Boolean;

implementation

uses
  ZX.BlockImage, System.UITypes, System.StrUtils, Core.RomFormat, Core.Snapshots;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TZXCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if FThread <> nil then
    FThread.MoveMouse(DX, DY, Buttons);
end;

procedure TZXCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

function IsZXImageName(const Name: string): Boolean;
begin
  Result := MatchText(ExtractFileExt(Name), ['.sna', '.z80', '.tap', '.tzx', '.trd', '.scl', '.dsk', '.mmc', '.ide', '.dck', '.pro', '.kdi']);
end;

function TZXConfig.GetTape128: Boolean;
begin
  Result := Machine.Profile.Has128Paging;
end;

function TZXConfig.GetPentagon: Boolean;
begin
  Result := Machine.Profile.IsPentagon;
end;

function TZXConfig.GetPentagonRAMKB: Integer;
begin
  Result := 128;
  if Pentagon then
    Result := Machine.Profile.RAMSizeKB;
end;

constructor TZXConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  Machine := TZXMachineConfig.ForModel(zmSpectrum48);
  Options := TZXRuntimeOptions.Defaults;
  Keys[TEmulatorButton.Up] := vkUp;
  Keys[TEmulatorButton.Down] := vkDown;
  Keys[TEmulatorButton.Left] := vkLeft;
  Keys[TEmulatorButton.Right] := vkRight;
  Keys[TEmulatorButton.A] := vkSpace;
  Keys[TEmulatorButton.Start] := vkReturn;
  Keys[TEmulatorButton.Select] := vkTab;
end;

procedure TZXConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  ServiceROMFile := Ini.ReadString('Hardware', 'ServiceROM', '');
  TimexCartridgeFile := Ini.ReadString('Hardware', 'TimexCartridge', '');
  Machine := TZXConfiguration.ReadMachine(Ini);
  DivImageFile := Ini.ReadString('Hardware', 'DivImage', '');
  NeoGSImageFile := Ini.ReadString('Hardware', 'NeoGSImage', '');
  DivFirmwareFile := Ini.ReadString('Hardware', 'DivFirmware', '');
  Machine.Validate;
  Options := TZXRuntimeOptions.Defaults;
  Options.YMChip := SameText(Ini.ReadString('Audio', 'PSGModel', 'ay'), 'ym');
  var Stereo := Ini.ReadString('Audio', 'Stereo', 'abc').ToLower;
  Options.Stereo := IndexStr(Stereo, ['abc', 'mono', 'acb', 'bac', 'bca', 'cab', 'cba']);
  Options.PITVolume := Ini.ReadInteger('Audio', 'PITVolume', 100);
  Options.AYVolume := Ini.ReadInteger('Audio', 'AYVolume', 100);
  Options.BeeperVolume := Ini.ReadInteger('Audio', 'BeeperVolume', 100);
  Options.ExpansionVolume := Ini.ReadInteger('Audio', 'ExpansionVolume', 100);
  var Joystick := Ini.ReadString('Ports', 'JoystickMode', 'both').ToLower;
  Options.Joystick := IndexStr(Joystick, ['both', 'kempston', 'qaop', 'none', 'sinclair1', 'sinclair2']);
  Options.SecondJoystick := Ini.ReadBool('Ports', 'SecondJoystick', False);
  Options.AutoLoad := Ini.ReadBool('Media', 'AutoLoad', True);
  Options.TapeAutoPlay := Ini.ReadBool('Media', 'TapeAutoPlay', True);
  Options.TapeSpeed := Ini.ReadInteger('Media', 'TapeSpeed', 1);
  Options.FastForwardSpeed := Ini.ReadInteger('Media', 'FastForwardSpeed', 8);
  Options.DiskWriteProtected := Ini.ReadBool('Media', 'DiskWriteProtected', False);
  Options := Options.Normalized;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Keys[B] := ReadEmulatorKey(Ini, 'Keys', KeyNames[B], Keys[B]);
end;

procedure TZXConfig.SaveCoreSettings(Ini: TCustomIniFile);
const
  StereoNames: array[0..6] of string = ('abc', 'mono', 'acb', 'bac', 'bca', 'cab', 'cba');
  JoystickNames: array[0..5] of string = ('both', 'kempston', 'qaop', 'none', 'sinclair1', 'sinclair2');
  DACNames: array[0..6] of string = ('none', 'covoxfb', 'covoxdd', 'covoxgs', 'soundrive', 'specdrum', 'nextdac');
begin
  Ini.WriteString('Hardware', 'ServiceROM', ServiceROMFile);
  Ini.WriteString('Hardware', 'TimexCartridge', TimexCartridgeFile);
  var DivKind := 'none';
  if Machine.DivType = zdIDE then
    DivKind := 'divide'
  else if Machine.DivType = zdMMC then
    DivKind := 'divmmc';
  Ini.WriteString('Hardware', 'DivType', DivKind);
  Ini.WriteInteger('Hardware', 'DivRAMKB', Machine.DivRAMKB);
  Ini.WriteString('Hardware', 'DivImage', DivImageFile);
  Ini.WriteString('Hardware', 'NeoGSImage', NeoGSImageFile);
  Ini.WriteString('Hardware', 'DivFirmware', DivFirmwareFile);
  Ini.WriteString('Hardware', 'TapeModel', Machine.Id);
  Ini.WriteString('Hardware', 'TKTiming', '60hz');
  if Machine.TKTiming = ztk50Hz then
    Ini.WriteString('Hardware', 'TKTiming', '50hz');
  Ini.WriteBool('Hardware', 'TKSpanish', Machine.TKSpanish);
  Ini.WriteBool('Hardware', 'ULAPlus', Machine.ULAPlus);
  Ini.WriteBool('Hardware', 'ByteCompatibility', Machine.ByteCompatibility);
  Ini.WriteInteger('Audio', 'PITVolume', Options.PITVolume);
  Ini.WriteBool('Hardware', 'TimexVideo', Machine.TimexVideo);
  Ini.WriteBool('Hardware', 'KempstonMouse', Machine.KempstonMouse);
  Ini.WriteBool('Ports', 'SecondJoystick', Options.SecondJoystick);
  Machine.Validate;
  Ini.WriteBool('Hardware', 'TurboSoundFM', Machine.TurboSoundFM);
  Ini.WriteBool('Hardware', 'TurboSound', Machine.TurboSound);
  Ini.WriteBool('Hardware', 'SAA1099', Machine.SAA1099);
  Ini.WriteString('Hardware', 'DAC', DACNames[Machine.DAC]);
  Ini.WriteInteger('Hardware', 'NextDACMode', Machine.NextDACMode);
  Ini.WriteBool('Hardware', 'NextDACStartup', Machine.NextDACStartup);
  Ini.WriteBool('Hardware', 'GeneralSound', Machine.GeneralSound);
  Ini.WriteInteger('Hardware', 'GeneralSoundRAMKB', Machine.GeneralSoundRAMKB);
  Ini.WriteBool('Hardware', 'NeoGS', Machine.NeoGS);
  Ini.WriteBool('Hardware', 'SID', Machine.SID);
  Ini.WriteInteger('Hardware', 'SIDModel', Machine.SIDModel);
  Ini.WriteString('Hardware', 'SIDInterface', 'ezxmb');
  if Machine.SIDInterface = 1 then
    Ini.WriteString('Hardware', 'SIDInterface', 'xxcf');
  Ini.WriteString('Hardware', 'SIDClock', 'pal');
  if Machine.SIDNTSC then
    Ini.WriteString('Hardware', 'SIDClock', 'ntsc');
  if Machine.SIDClock1MHz then
    Ini.WriteString('Hardware', 'SIDClock', '1mhz');
  Ini.WriteBool('Hardware', 'MoonSound', Machine.MoonSound);
  Ini.WriteBool('Hardware', 'MoonSoundIRQ', Machine.MoonSoundIRQ);
  Ini.WriteBool('Hardware', 'MoonSoundInDOS', Machine.MoonSoundInDOS);
  Ini.WriteBool('Hardware', 'DMAUSC', Machine.DMAUSC);
  Ini.WriteBool('Hardware', 'DMAUSCULABypass', Machine.DMAUSCULABypass);
  Ini.WriteInteger('Hardware', 'DMAUSCStereo', Machine.DMAUSCStereo);
  Ini.WriteInteger('Hardware', 'NeoGSRAMKB', Machine.NeoGSRAMKB);
  Options := Options.Normalized;
  if Options.YMChip then
    Ini.WriteString('Audio', 'PSGModel', 'ym')
  else
    Ini.WriteString('Audio', 'PSGModel', 'ay');
  Ini.WriteString('Audio', 'Stereo', StereoNames[Options.Stereo]);
  Ini.WriteInteger('Audio', 'AYVolume', Options.AYVolume);
  Ini.WriteInteger('Audio', 'BeeperVolume', Options.BeeperVolume);
  Ini.WriteInteger('Audio', 'ExpansionVolume', Options.ExpansionVolume);
  Ini.WriteString('Ports', 'JoystickMode', JoystickNames[Options.Joystick]);
  Ini.WriteBool('Media', 'AutoLoad', Options.AutoLoad);
  Ini.WriteBool('Media', 'TapeAutoPlay', Options.TapeAutoPlay);
  Ini.WriteInteger('Media', 'TapeSpeed', Options.TapeSpeed);
  Ini.WriteInteger('Media', 'FastForwardSpeed', Options.FastForwardSpeed);
  Ini.WriteBool('Media', 'DiskWriteProtected', Options.DiskWriteProtected);
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    Ini.WriteInteger('Keys', KeyNames[B], Keys[B]);
end;

function TZXCoreAdapter.SessionMachine: TZXMachineConfig;
begin
  Result := TZXConfig(FConfig).Machine;
  if SameText(ExtractFileExt(FName), '.kdi') then
    Result := Result.WithModel(zmByte01);
  if SameText(ExtractFileExt(FName), '.pro') and not Result.Profi then
    Result := Result.WithModel(zmProfi1024);
  if SameText(ExtractFileExt(FName), '.mmc') then
    Result.DivType := zdMMC
  else if SameText(ExtractFileExt(FName), '.ide') then
    Result.DivType := zdIDE;
end;

constructor TZXCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName, ImageName: string);
begin
  inherited Create;
  InitializeImage(Stream, nil, Storage, RomName, ImageName);
end;

constructor TZXCoreAdapter.CreateOwned(var Data: TBytes; const Storage: IStorage; const RomName, ImageName: string);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > 8 * 1024 * 1024) then
    raise EReadError.Create('Spectrum image is empty or exceeds 8 MiB');
  var Owned := Data;
  Data := nil;
  InitializeImage(nil, Owned, Storage, RomName, ImageName);
end;

function TZXCoreAdapter.PreparationKey: string;
begin
  var C := TZXConfig(FConfig);
  Result := C.TimexCartridgeFile + #0 + C.DivFirmwareFile + #0 + FDivImageFile + #0 + FNeoGSImageFile;
end;

procedure TZXCoreAdapter.InitializeImage(Stream: TStream; const OwnedData: TBytes; const Storage: IStorage; const RomName, ImageName: string);
begin
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FName := ImageName;
  if FName = '' then
    FName := RomName;
  FConfig := TZXConfig.Create(FStorage.ConfigFile('zx'), FStorage);
  FConfig.Load;
  var Config := TZXConfig(FConfig);
  FDivImageFile := Config.DivImageFile;
  var Mass := SameText(ExtractFileExt(FName), '.mmc') or SameText(ExtractFileExt(FName), '.ide');
  if Mass then
  begin
    if Stream = nil then
      raise EReadError.Create('CF/SD images require an immutable source stream');
    if not SameText(ExtractFileExt(RomName), ExtractFileExt(FName)) then
      raise EReadError.Create('Open CF/SD images directly, outside ZIP/7z archives');
    FData := TZXBlockImage.Identity(Stream);
    FDivImageFile := RomName;
    // Resolve this image independently of the saved global interface preference.
  end
  else if Stream = nil then
    FData := OwnedData
  else
  begin
    if (Stream.Size - Stream.Position <= 0) or (Stream.Size - Stream.Position > 8 * 1024 * 1024) then
      raise EReadError.Create('Spectrum image is empty or exceeds 8 MiB');
    SetLength(FData, Stream.Size - Stream.Position);
    Stream.ReadBuffer(FData[0], Length(FData));
  end;
  var Machine := SessionMachine;
  if (FDivImageFile <> '') and (Machine.DivType = zdNone) then
    FDivImageFile := '';
  if FDivImageFile <> '' then
  begin
    // Retain a read handle for this adapter's lifetime. On Windows this denies
    // outside writers, so worker restarts can reuse the already computed hash.
    FDivImageLock := FStorage.OpenRead(FDivImageFile);
    if Mass then
    begin
      if FDivImageLock.Size <> Stream.Size then
        raise EReadError.Create('CF/SD stream does not match its storage file');
      FDivImageHash := Copy(FData);
    end
    else
      FDivImageHash := TZXBlockImage.Identity(FDivImageLock);
  end;
  if Machine.NeoGS and (Config.NeoGSImageFile <> '') then
  begin
    FNeoGSImageFile := Config.NeoGSImageFile;
    FNeoGSImageLock := FStorage.OpenRead(FNeoGSImageFile);
    FNeoGSImageHash := TZXBlockImage.Identity(FNeoGSImageLock);
  end;
  var Console := TZXConsole.Create;
  try
    FPreparedOptions := Config.Options.Normalized;
    Console.ApplyOptions(FPreparedOptions);
    Console.Load(FData, FName, Machine);
    if (Config.TimexCartridgeFile <> '') and (Console.Machine.Model = zmTimex2068) and not SameText(ExtractFileExt(FName), '.dck') then
      Console.MountTimexCartridge(FStorage.ReadBytes(Config.TimexCartridgeFile));
    if Config.DivFirmwareFile <> '' then
      Console.DivStorage.Configure(Machine.DivType, Machine.DivRAMKB, FStorage.ReadBytes(Config.DivFirmwareFile));
    if FDivImageFile <> '' then
      Console.DivStorage.Mount(FStorage.OpenRead(FDivImageFile), FDivImageHash);
    if FNeoGSImageFile <> '' then
      Console.NeoGS.Mount(FStorage.OpenRead(FNeoGSImageFile), FNeoGSImageHash);
    FPreparedMachine := Machine;
    FPreparedKey := PreparationKey;
    FPreparedConsole := Console;
    Console := nil;
  finally
    Console.Free;
  end;
  FPorts := LoadCoreInputPorts(FStorage, 'zx');
  FSnapshotDirectory := FStorage.GameSnapshots('zx', RomName, SnapshotIdentity(FData));
end;

destructor TZXCoreAdapter.Destroy;
begin
  FThread.Free;
  FPreparedConsole.Free;
  FDivImageLock.Free;
  FNeoGSImageLock.Free;
  inherited;
end;

procedure TZXCoreAdapter.ApplySettings;
begin
  if FThread = nil then
    Exit;
  var Keys := FKeys;
  for var i := 0 to High(Keys) do
    Keys[i] := Keys[i] or FScreenKeys[i];
  FThread.ConfigureOptions(TZXConfig(FConfig).Options);
  FThread.Configure(GetInputState, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TZXCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  var Machine := SessionMachine;
  var Options := TZXConfig(FConfig).Options.Normalized;
  if (FPreparedKey <> PreparationKey) or
    not CompareMem(@Machine, @FPreparedMachine, SizeOf(Machine)) or
    not CompareMem(@Options, @FPreparedOptions, SizeOf(Options)) then
    FreeAndNil(FPreparedConsole);
  FThread := TZXWorker.CreatePrepared(FData, FName, FStorage, Machine, Options, FPreparedConsole);
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.CMOSSaveFile := ChangeFileExt(FStorage.ConfigFile('zx'), '.cmos');
  FThread.ServiceROMFile := TZXConfig(FConfig).ServiceROMFile;
  FThread.TimexCartridgeFile := TZXConfig(FConfig).TimexCartridgeFile;
  FThread.NeoGSImageHash := Copy(FNeoGSImageHash);
  FThread.NeoGSImageFile := FNeoGSImageFile;
  FThread.MoonSoundFlashFile := ChangeFileExt(FStorage.ConfigFile('zx'), '.moonsound.flash');
  FThread.NeoGSFlashFile := ChangeFileExt(FStorage.ConfigFile('zx'), '.neogs.flash');
  if FNeoGSImageFile <> '' then
    FThread.NeoGSSaveFile := FStorage.GameSave('zx', FNeoGSImageFile, SnapshotIdentity(FNeoGSImageHash)) + '.ngs';
  FThread.DivImageHash := Copy(FDivImageHash);
  FThread.DivImageFile := FDivImageFile;
  FThread.DivFirmwareFile := TZXConfig(FConfig).DivFirmwareFile;
  if FDivImageFile <> '' then
  begin
    FThread.DivSaveFile := FStorage.GameSave('zx', FDivImageFile, SnapshotIdentity(FDivImageHash)) + '.div';
  end;
  FThread.DiskSaveFile := FStorage.GameSave('zx', FName, SnapshotIdentity(FData));
  FThread.InputPorts := FPorts;
  ApplySettings;
  FThread.Start;
end;

procedure TZXCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TZXCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TZXCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TZXCoreAdapter.Reset;
begin
  if FThread <> nil then
    FThread.RequestReset;
  ClearInput;
  ApplySettings;
end;

procedure TZXCoreAdapter.ClearInput;
begin
  if FThread <> nil then
    FThread.SetFastForward(False);
  SendMouseDelta(0, 0, 0);
  FillChar(FKeys, SizeOf(FKeys), 0);
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FillChar(FTapeKeyDown, SizeOf(FTapeKeyDown), 0);
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TZXCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TZXCoreAdapter.ToggleTape;
begin
  if FThread <> nil then
    FThread.ControlTape(1);
end;

procedure TZXCoreAdapter.RewindTape;
begin
  FChoicePage := 0;
  if FThread <> nil then
    FThread.ControlTape(2);
end;

procedure TZXCoreAdapter.SelectTapePart(Index: Integer);
begin
  FChoicePage := 0;
  if FThread <> nil then
    FThread.ControlTape(1000 + Index);
end;

function TZXCoreAdapter.GetTapeStatus: string;
begin
  Result := '';
  if (FThread = nil) or not (SameText(ExtractFileExt(FName), '.tap') or SameText(ExtractFileExt(FName), '.tzx')) then
    Exit;
  var Choices := FThread.GetTapeChoices;
  if Length(Choices) = 0 then
    Exit(FThread.GetTapeStatus);
  Result := 'Tape part: ';
  if FChoicePage * 9 >= Length(Choices) then
    FChoicePage := 0;
  for var i := 0 to 8 do
    if FChoicePage * 9 + i < Length(Choices) then
      Result := Result + IntToStr(i + 1) + ': ' + Choices[FChoicePage * 9 + i] + '  ';
  if Length(Choices) > 9 then
    Result := Result + '0: next page';
end;

function TZXCoreAdapter.TapeKey(Code: UInt32; Pressed: Boolean): Boolean;
begin
  Result := False;
  if (FThread = nil) or (Code > 255) then
    Exit;
  var Choices := FThread.GetTapeChoices;
  Result := FTapeKeyDown[Code] or (Code in [vkF7, vkF8]) or ((Length(Choices) > 0) and (Code >= vk0) and (Code <= vk9));
  if not Result then
    Exit;
  var WasDown := FTapeKeyDown[Code];
  FTapeKeyDown[Code] := Pressed;
  if not Pressed or WasDown then
    Exit;
  if Code = vkF7 then
    ToggleTape
  else if Code = vkF8 then
    RewindTape
  else if Code = vk0 then
    FChoicePage := (FChoicePage + 1) mod ((Length(Choices) + 8) div 9)
  else if FChoicePage * 9 + Integer(Code - vk1) < Length(Choices) then
    SelectTapePart(FChoicePage * 9 + Integer(Code - vk1));
end;

procedure TZXCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = vkF10 then
  begin
    if FThread <> nil then
      FThread.SetFastForward(Pressed);
    Exit;
  end;
  if Code = vkF9 then
  begin
    if Pressed and not FKeys[vkF9] and (FThread <> nil) then
      FThread.RequestNMI;
    FKeys[vkF9] := Pressed;
    Exit;
  end;
  if TapeKey(Code, Pressed) then
    Exit;
  if not FPorts.KeyboardEnabled then
    Exit;
  if Code <= 255 then
    FKeys[Code] := Pressed;
  if Code in [vkLShift, vkRShift] then
    FKeys[vkShift] := FKeys[vkLShift] or FKeys[vkRShift];
  if Code in [vkLControl, vkRControl] then
    FKeys[vkControl] := FKeys[vkLControl] or FKeys[vkRControl];
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if (TZXConfig(FConfig).Keys[B] <> 0) and (Code = TZXConfig(FConfig).Keys[B]) then
      if Pressed then
        Include(FKeyboard.Buttons, B)
      else
        Exclude(FKeyboard.Buttons, B);
  ApplySettings;
end;

procedure TZXCoreAdapter.SetScreenKeys(const Keys: TSGHostKeys);
begin
  for var i := 0 to 255 do
    if (Keys[i] <> FScreenKeys[i]) or FTapeKeyDown[i] then
      if TapeKey(i, Keys[i]) then
        FScreenKeys[i] := False
      else
        FScreenKeys[i] := Keys[i];
  ApplySettings;
end;

procedure TZXCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  if (TEmulatorButton.B in Input.Buttons) and not (TEmulatorButton.B in FGamepad.Buttons) then
    ToggleTape;
  if (TEmulatorButton.Mode in Input.Buttons) and not (TEmulatorButton.Mode in FGamepad.Buttons) then
    RewindTape;
  FGamepad := Input;
  ApplySettings;
end;

function TZXCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  if FPorts.Devices[0] <> 'none' then
    Result.Buttons := FGamepad.Buttons + FKeyboard.Buttons;
  if FPorts.Devices[1] <> 'none' then
    Result.Buttons2 := FGamepad.Buttons2;
end;

function TZXCoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  Result := [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left, TEmulatorButton.Right,
      TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Mode, TEmulatorButton.Select, TEmulatorButton.Start];
end;

function TZXCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := FPorts.KeyboardEnabled;
end;

function TZXCoreAdapter.GetName: string;
begin
  Result := 'Sinclair ZX Spectrum';
end;

function TZXCoreAdapter.GetSystemId: string;
begin
  Result := 'zx';
end;

function TZXCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TZXCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TZXCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TZXCoreAdapter.InsertCoin1;
begin
end;

procedure TZXCoreAdapter.InsertCoin2;
begin
end;

function TZXCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TZXCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TZXCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

function TZXCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TZXCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TZXCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

procedure TZXCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FThread.SaveSnapshot(Name);
end;

procedure TZXCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FThread.LoadSnapshot(Name);
end;

end.

