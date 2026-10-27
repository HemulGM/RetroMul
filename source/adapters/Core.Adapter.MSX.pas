unit Core.Adapter.MSX;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, Core.Adapter.SG1000, SG1000.Console, MSX.Machine,
  MSX.Emulation;

type
  TMSXConfig = class(TEmulatorConfigBase)
  public
    BIOSFile, SubROMFile, DiskROMFile, DiskAFile, DiskBFile, TapeFile, KanjiFile, KanjiBasicFile, MusicFile, Cartridge2File: string;
    MapperHint, Mapper2, Expansion2, TapeMode, TapeBaud, MousePort, AudioSampleRAM, VDPChip: Integer;
    DiskWriteProtected: Boolean;
    UseOriginalBIOS, VDPWaitConnected: Boolean;
    constructor Create(const FileName: string; const Storage: IStorage);
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  end;

  TMSXCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, ISGKeyboardCore, IEmulationMouseInput, IEmulationDiscControl)
  private
    FThread: TMSXWorker;
    FData, FBIOS, FSubROM: TBytes;
    FModel: TMSXModel;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FSnapshotDirectory, FSaveFile, FError: string;
    FKeys, FScreenKeys: TMSXHostKeys;
    FInput: TEmulatorInput;
    FPorts: TCoreInputPorts;
    FPaused: Boolean;
    FMediaKind: TMSXMediaKind;
    FOptions: TMSXPeripheralOptions;
    FDiskSaveFiles: array[0..1] of string;
    FSecondSaveFile, FRTCFile: string;
    FDiscNames: TStringList;
    FDiscIndex: Integer;
    procedure ApplySettings;
  public
    constructor Create(const Data: TBytes; Model: TMSXModel; const Storage: IStorage; const RomName: string; MediaKind: TMSXMediaKind = CartridgeMedia);
    destructor Destroy; override;
    procedure ApplyLiveSettings;
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    function GetSystemId: string;
    function GetName: string;
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
    procedure SetGamepadInput(const Input: TEmulatorInput);
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    function GetDiscCount: Integer;
    function GetDiscName(Index: Integer): string;
    function GetDiscIndex: Integer;
    procedure ChangeDisc(Index: Integer);
    procedure OpenDisc(const Location: string);
    procedure EjectDisc;
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
  Core.Snapshots, MSX.Console, MSX.Cartridge, MSX.Firmware, System.IOUtils;

constructor TMSXConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  MapperHint := -1;
  Mapper2 := -1;
  TapeBaud := 1200;
  TapeMode := 1;
  AudioSampleRAM := 32;
end;

procedure TMSXConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  BIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  SubROMFile := Ini.ReadString('Hardware', 'SubROM', '');
  MapperHint := Ini.ReadInteger('Cartridge', 'Mapper', -1);
  UseOriginalBIOS := Ini.ReadBool('Hardware', 'OriginalBIOS', False);
  VDPWaitConnected := Ini.ReadBool('Hardware', 'VDPWaitConnected', False);
  VDPChip := Ini.ReadInteger('Hardware', 'VDPChip', 0);
  if (VDPChip < 0) or (VDPChip > Ord(High(TMSXVDPChip))) then
    VDPChip := 0;
  if (MapperHint < -1) or (MapperHint > Ord(High(TMSXMapper))) then
    MapperHint := -1;
  DiskROMFile := Ini.ReadString('Disk', 'ROM', '');
  DiskAFile := Ini.ReadString('Disk', 'DriveA', '');
  DiskBFile := Ini.ReadString('Disk', 'DriveB', '');
  DiskWriteProtected := Ini.ReadBool('Disk', 'WriteProtected', False);
  TapeFile := Ini.ReadString('Cassette', 'File', '');
  TapeMode := Ini.ReadInteger('Cassette', 'Mode', 1);
  TapeBaud := Ini.ReadInteger('Cassette', 'Baud', 1200);
  if (TapeBaud <> 1200) and (TapeBaud <> 2400) then
    TapeBaud := 1200;
  if (TapeMode < 0) or (TapeMode > 2) then
    TapeMode := 1;
  KanjiFile := Ini.ReadString('Hardware', 'Kanji', '');
  MusicFile := Ini.ReadString('Hardware', 'MusicROM', '');
  KanjiBasicFile := Ini.ReadString('Hardware', 'KanjiBasicROM', '');
  Cartridge2File := Ini.ReadString('Cartridge', 'Slot2', '');
  Mapper2 := Ini.ReadInteger('Cartridge', 'Mapper2', -1);
  Expansion2 := Ini.ReadInteger('Cartridge', 'Expansion2', 0);
  if (Expansion2 < 0) or (Expansion2 > 7) then
    Expansion2 := 0;
  AudioSampleRAM := Ini.ReadInteger('Hardware', 'AudioSampleRAM', 32);
  if (AudioSampleRAM <> 32) and (AudioSampleRAM <> 256) then
    AudioSampleRAM := 32;
  if (Mapper2 < -1) or (Mapper2 > Ord(High(TMSXMapper))) then
    Mapper2 := -1;
  MousePort := Ini.ReadInteger('Ports', 'MSXMousePort', 0);
  if (MousePort < 0) or (MousePort > 2) then
    MousePort := 0;
end;

procedure TMSXConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', BIOSFile);
  Ini.WriteString('Hardware', 'SubROM', SubROMFile);
  Ini.WriteInteger('Cartridge', 'Mapper', MapperHint);
  Ini.WriteBool('Hardware', 'OriginalBIOS', UseOriginalBIOS);
  Ini.WriteInteger('Hardware', 'VDPChip', VDPChip);
  Ini.WriteBool('Hardware', 'VDPWaitConnected', VDPWaitConnected);
  Ini.WriteString('Disk', 'ROM', DiskROMFile);
  Ini.WriteString('Disk', 'DriveA', DiskAFile);
  Ini.WriteString('Disk', 'DriveB', DiskBFile);
  Ini.WriteBool('Disk', 'WriteProtected', DiskWriteProtected);
  Ini.WriteString('Cassette', 'File', TapeFile);
  Ini.WriteInteger('Cassette', 'Mode', TapeMode);
  Ini.WriteInteger('Cassette', 'Baud', TapeBaud);
  Ini.WriteString('Hardware', 'Kanji', KanjiFile);
  Ini.WriteString('Hardware', 'MusicROM', MusicFile);
  Ini.WriteString('Hardware', 'KanjiBasicROM', KanjiBasicFile);
  Ini.WriteString('Cartridge', 'Slot2', Cartridge2File);
  Ini.WriteInteger('Cartridge', 'Mapper2', Mapper2);
  Ini.WriteInteger('Cartridge', 'Expansion2', Expansion2);
  Ini.WriteInteger('Hardware', 'AudioSampleRAM', AudioSampleRAM);
  Ini.WriteInteger('Ports', 'MSXMousePort', MousePort);
end;

constructor TMSXCoreAdapter.Create(const Data: TBytes; Model: TMSXModel; const Storage: IStorage; const RomName: string; MediaKind: TMSXMediaKind);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FModel := Model;
  FData := Copy(Data);
  FMediaKind := MediaKind;
  FDiscNames := TStringList.Create;
  FDiscIndex := -1;
  var Config := TMSXConfig.Create(FStorage.ConfigFile(GetSystemId), FStorage);
  FConfig := Config;
  Config.Load;
  FPorts := LoadCoreInputPorts(FStorage, GetSystemId);
  var OriginalMain, OriginalSub, OriginalDisk, OriginalMusic, OriginalKanji, OriginalKanjiBasic: TBytes;
  LoadMSXOriginalFirmware(Model, OriginalMain, OriginalSub, OriginalDisk, OriginalMusic, OriginalKanji, OriginalKanjiBasic);
  var FMPACPrimary := (Length(Data) = $10000) and
    (TEncoding.ASCII.GetString(Data, $18, 8) = 'PAC2OPLL');
  var AudioPrimary := TMSXCartridge.DetectMapper(Data) in [PhilipsAudio, PanasonicAudio];
  if (Config.BIOSFile = '') and (Config.UseOriginalBIOS or (MediaKind <> CartridgeMedia) or FMPACPrimary or AudioPrimary) then
  begin
    FBIOS := OriginalMain;
    FSubROM := OriginalSub;
    FOptions.MusicROM := OriginalMusic;
    FOptions.KanjiROM := OriginalKanji;
    FOptions.KanjiBasicROM := OriginalKanjiBasic;
  end;
  if Config.BIOSFile <> '' then
  begin
    FBIOS := FStorage.ReadBytes(Config.BIOSFile);
    if Config.SubROMFile <> '' then
      FSubROM := FStorage.ReadBytes(Config.SubROMFile);
  end;
  FOptions.Mapper2 := Config.Mapper2;
  FOptions.TapeBaud := Config.TapeBaud;
  FOptions.VDPChip := TMSXVDPChip(Config.VDPChip);
  FOptions.VDPWaitConnected := ((FModel = MSX2Plus) or ((FModel = MSX2) and (Config.VDPChip = Ord(VDPV9958)))) and Config.VDPWaitConnected;
  FOptions.TapeMode := Config.TapeMode;
  FOptions.MousePort := Config.MousePort;
  FOptions.AudioSampleRAM := Config.AudioSampleRAM * 1024;
  FOptions.DiskWriteProtected := Config.DiskWriteProtected;
  if Config.DiskROMFile <> '' then
    FOptions.DiskROM := FStorage.ReadBytes(Config.DiskROMFile);
  if (Config.DiskROMFile = '') and ((MediaKind = DiskMedia) or (Config.DiskAFile <> '') or (Config.DiskBFile <> '')) then
    FOptions.DiskROM := OriginalDisk;
  if Config.KanjiFile <> '' then
    FOptions.KanjiROM := FStorage.ReadBytes(Config.KanjiFile);
  if Config.MusicFile <> '' then
    FOptions.MusicROM := FStorage.ReadBytes(Config.MusicFile);
  if Config.KanjiBasicFile <> '' then
    FOptions.KanjiBasicROM := FStorage.ReadBytes(Config.KanjiBasicFile);
  var Cartridge2Name := Config.Cartridge2File;
  case Config.Expansion2 of
    1:
      begin
        FOptions.Cartridge2 := LoadMSXFMPAC;
        FOptions.Mapper2 := Ord(FMPAC);
        Cartridge2Name := 'fmpac';
      end;
    2:
      begin
        SetLength(FOptions.Cartridge2, $2000);
        FillChar(FOptions.Cartridge2[0], $2000, $FF);
        FOptions.Mapper2 := Ord(PAC);
        Cartridge2Name := 'pac';
      end;
    3..5:
      begin
        SetLength(FOptions.Cartridge2, $2000);
        FillChar(FOptions.Cartridge2[0], $2000, $FF);
        FOptions.Mapper2 := Ord(SCCPlus) + Config.Expansion2 - 3;
        case Config.Expansion2 of
          3:
            Cartridge2Name := 'sccplus128';
          4:
            Cartridge2Name := 'snatcher';
          5:
            Cartridge2Name := 'sdsnatcher';
        end;
      end;
    6, 7:
      begin
        FOptions.Cartridge2 := LoadMSXAudioFirmware(Config.Expansion2 = 7);
        FOptions.Mapper2 := Ord(PhilipsAudio) + Config.Expansion2 - 6;
        if Config.Expansion2 = 7 then
          Cartridge2Name := 'fs-ca1'
        else
          Cartridge2Name := 'nms1205';
      end;
  else
    if Config.Cartridge2File <> '' then
      FOptions.Cartridge2 := FStorage.ReadBytes(Config.Cartridge2File);
  end;
  if Config.DiskAFile <> '' then
    FOptions.DiskA := FStorage.ReadBytes(Config.DiskAFile);
  if Config.DiskBFile <> '' then
    FOptions.DiskB := FStorage.ReadBytes(Config.DiskBFile);
  if Config.TapeFile <> '' then
  begin
    FOptions.Tape := FStorage.ReadBytes(Config.TapeFile);
    FOptions.TapeCAS := SameText(ExtractFileExt(Config.TapeFile), '.cas');
  end;
  var DiskAName := Config.DiskAFile;
  if MediaKind = DiskMedia then
  begin
    FOptions.DiskA := Copy(Data);
    DiskAName := RomName;
  end;
  if MediaKind in [CASMedia, WAVMedia] then
  begin
    FOptions.Tape := Copy(Data);
    FOptions.TapeCAS := MediaKind = CASMedia;
  end;
  if ((Length(FOptions.DiskA) > 0) or (Length(FOptions.DiskB) > 0)) and (Length(FOptions.DiskROM) = 0) then
    raise EReadError.Create('Configure a 16 KiB Philips disk ROM in MSX settings before opening disks');
  if (Length(FOptions.DiskA) > 0) then
    FDiskSaveFiles[0] := FStorage.GameSave(GetSystemId, DiskAName, SnapshotIdentity(FOptions.DiskA)) + '.dsk';
  if (Length(FOptions.DiskB) > 0) then
    FDiskSaveFiles[1] := FStorage.GameSave(GetSystemId, Config.DiskBFile, SnapshotIdentity(FOptions.DiskB)) + '.dsk';
  if (DiskAName <> '') then
  begin
    FDiscNames.Add(DiskAName);
    FDiscIndex := 0;
  end;
  if FDiscNames.Count = 0 then
    FDiscNames.Add('');
  FRTCFile := TPath.Combine(TPath.Combine(FStorage.SaveRoot, GetSystemId), 'rtc.bin');
  if Length(FOptions.Cartridge2) > 0 then
    FSecondSaveFile := FStorage.GameSave(GetSystemId, Cartridge2Name, SnapshotIdentity(FOptions.Cartridge2)) + '.slot2';
  // Validate synchronously, so a bad image/BIOS reports an actionable error
  // before a worker is launched or a playback window is entered.
  var Cart := FData;
  if MediaKind <> CartridgeMedia then
    Cart := nil;
  var Check := TMSXConsole.Create(Cart, FModel, Config.MapperHint, FBIOS, FSubROM);
  try
    Check.ConfigurePeripherals(FOptions);
  finally
    Check.Free;
  end;
  var Identity := SnapshotIdentity(FData);
  FSnapshotDirectory := FStorage.GameSnapshots(GetSystemId, RomName, Identity);
  FSaveFile := FStorage.GameSave(GetSystemId, RomName, Identity);
end;

destructor TMSXCoreAdapter.Destroy;
begin
  Stop;
  FDiscNames.Free;
  inherited;
end;

procedure TMSXCoreAdapter.ApplySettings;
begin
  if FThread = nil then
    Exit;
  var Keys := FKeys;
  for var i := 0 to 255 do
    Keys[i] := Keys[i] or FScreenKeys[i];
  FThread.Configure(FInput, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TMSXCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

procedure TMSXCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TMSXCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TMSXWorker.Create(FData, FModel, FStorage, FBIOS, FSubROM);
  FThread.MapperHint := TMSXConfig(FConfig).MapperHint;
  FThread.MediaKind := FMediaKind;
  FThread.Options := FOptions;
  FThread.DiskSaveFiles[0] := FDiskSaveFiles[0];
  FThread.DiskSaveFiles[1] := FDiskSaveFiles[1];
  FThread.RTCFile := FRTCFile;
  FThread.Cartridge2SaveFile := FSecondSaveFile;
  FThread.TapeRecordFile := FSaveFile + '.tape.wav';
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.SaveFile := FSaveFile;
  FThread.InputPorts := FPorts;
  ApplySettings;
  FThread.Start;
end;

procedure TMSXCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TMSXCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TMSXCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TMSXCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TMSXCoreAdapter.ClearInput;
begin
  FillChar(FKeys, SizeOf(FKeys), 0);
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FInput := Default(TEmulatorInput);
  ApplySettings;
  SendMouseDelta(0, 0, 0);
end;

procedure TMSXCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if (Code < 256) and FPorts.KeyboardEnabled then
    FKeys[Code] := Pressed;
  ApplySettings;
end;

procedure TMSXCoreAdapter.SetScreenKeys(const Keys: TSGHostKeys);
begin
  Move(Keys, FScreenKeys, SizeOf(FScreenKeys));
  ApplySettings;
end;

procedure TMSXCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FInput := Input;
  ApplySettings;
end;

procedure TMSXCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if FThread <> nil then
    FThread.MoveMouse(DX, DY, Buttons);
end;

function TMSXCoreAdapter.GetDiscCount: Integer;
begin
  Result := 0;
  if Length(FOptions.DiskROM) > 0 then
    Result := FDiscNames.Count;
end;

function TMSXCoreAdapter.GetDiscName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('MSX disk index');
  Result := ExtractFileName(FDiscNames[Index]);
  if Result = '' then
    Result := 'Drive A (empty)';
end;

function TMSXCoreAdapter.GetDiscIndex: Integer;
begin
  Result := FDiscIndex;
end;

procedure TMSXCoreAdapter.OpenDisc(const Location: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('MSX worker is not running');
  FThread.OpenDisk(Location);
  var Index := FDiscNames.IndexOf(Location);
  if Index < 0 then
    Index := FDiscNames.Add(Location);
  FDiscIndex := Index;
end;

procedure TMSXCoreAdapter.ChangeDisc(Index: Integer);
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('MSX disk index');
  if FDiscNames[Index] = '' then
    EjectDisc
  else
    OpenDisc(FDiscNames[Index]);
end;

procedure TMSXCoreAdapter.EjectDisc;
begin
  if FThread = nil then
    raise EInvalidOpException.Create('MSX worker is not running');
  FThread.EjectDisk;
  FDiscIndex := -1;
end;

function TMSXCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FInput;
end;

function TMSXCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := True;
end;

function TMSXCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TMSXCoreAdapter.GetSystemId: string;
begin
  Result := MSXSystemId(FModel);
end;

function TMSXCoreAdapter.GetName: string;
begin
  Result := MSXModelName(FModel);
end;

function TMSXCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TMSXCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TMSXCoreAdapter.InsertCoin1;
begin
end;

procedure TMSXCoreAdapter.InsertCoin2;
begin
end;

function TMSXCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TMSXCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TMSXCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TMSXCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('MSX worker is not running');
  FThread.SaveSnapshot(Name);
end;

procedure TMSXCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('MSX worker is not running');
  FThread.LoadSnapshot(Name);
end;

function TMSXCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TMSXCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TMSXCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

end.

