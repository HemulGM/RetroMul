unit Core.Adapter.SG1000;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, SG1000.Console, SG1000.Emulation;

type
  ISGKeyboardCore = interface
    ['{EFD61C7F-7A61-4F3A-A792-A0D5D6C237ED}']
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    property HasKeyboard: Boolean read GetHasKeyboard;
  end;

  TSGButton = (Up, Down, Left, Right, A, B, Start);

  TSGButtons = set of TSGButton;

  TSGKeyMap = array[TSGButton] of UInt32;

  TSGConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TSGKeyMap;
    FSystemId: string;
    FPAL: Boolean;
    FVideoRegion: string;
    FModelName, FBiosFile, FIPLFile: string;
    FWarmBoot, FKeyboardEnabled, FBIOSenabled, FTapeAutoPlay: Boolean;
    FTapeFile: string;
    FMapperHint: Integer;
    FOptions: TSGOptions;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil; const SystemId: string = 'sg1000');
    property SystemId: string read FSystemId;
    function ResolvePAL(const ROM: TBytes; const RomName: string): Boolean;
    property VideoRegion: string read FVideoRegion;
    property PAL: Boolean read FPAL;
    property Keys: TSGKeyMap read FKeys;
    property Keys2: TSGKeyMap read FKeys2;
    property ModelName: string read FModelName;
    property BIOSFile: string read FBiosFile;
    property IPLFile: string read FIPLFile;
    property WarmBoot: Boolean read FWarmBoot;
    property BIOSenabled: Boolean read FBIOSenabled;
    property KeyboardEnabled: Boolean read FKeyboardEnabled;
    property TapeFile: string read FTapeFile;
    property TapeAutoPlay: Boolean read FTapeAutoPlay;
    property MapperHint: Integer read FMapperHint;
    property Options: TSGOptions read FOptions;
  end;

  TSGCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, ISGKeyboardCore)
  private
    FThread: TSGWorker;
    FData, FBootROM: TBytes;
    FModel: TSGModel;
    FSaveFile: string;
    FSnapshotDirectory: string;
    FStorage: IStorage;
    FError: string;
    FSC3000, FResolvedPAL: Boolean;
    FHostKeys, FScreenKeys: TSGHostKeys;
    FConfig: IEmulatorConfig;
    FKeys, FKeys2: TSGKeyMap;
    FKeyboard, FGamepad, FKeyboard2, FGamepad2: TSGButtons;
    FPaused: Boolean;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(const FileName: string); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; SC3000: Boolean = False; ModelHint: Integer = -1); overload;
    destructor Destroy; override;
    procedure SetScreenKeys(const Keys: TSGHostKeys);
    function GetHasKeyboard: Boolean;
    function GetSystemId: string;
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
  System.IOUtils, System.UITypes, System.Hash, SG1000.Cartridge, SG1000.Disk,
  SMS.Cartridge, SMS.Firmware, Core.RomFormat, System.Math;

const
  KeyNames: array[TSGButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Start');

{ TSGConfig }

procedure TSGCoreAdapter.ApplyLiveSettings;
begin
  var Config := FConfig as TSGConfig;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  if FThread <> nil then
    FThread.ConfigureOptions(Config.Options);
  ApplySettings;
end;

constructor TSGConfig.Create(const FileName: string; const Storage: IStorage; const SystemId: string);
const
  Defaults: TSGKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkReturn);
  Defaults2: TSGKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6,
    vkNumpad1, vkNumpad2, vkNumpad0);
begin
  inherited Create(FileName, Storage);
  FSystemId := SystemId;
  FKeys := Defaults;
  FKeys2 := Defaults2;
  FOptions := TSGOptions.Defaults;
  FModelName := 'auto';
  FVideoRegion := 'NTSC';
  if SameText(SystemId, 'sms') then FVideoRegion := 'Auto';
  FKeyboardEnabled := True;
  FBIOSenabled := True;
  FWarmBoot := True;
  FMapperHint := -1;
end;

procedure TSGConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  var DefaultRegion := 'NTSC';
  if FSystemId = ROM_SYSTEM_SMS then DefaultRegion := 'Auto';
  FVideoRegion := Ini.ReadString('Video', 'Region', DefaultRegion);
  if not (SameText(FVideoRegion, 'Auto') or SameText(FVideoRegion, 'PAL') or SameText(FVideoRegion, 'NTSC')) then
    FVideoRegion := DefaultRegion;
  FPAL := SameText(FVideoRegion, 'PAL');
  FModelName := Ini.ReadString('Hardware', 'Model', 'auto');
  FBiosFile := Ini.ReadString('Hardware', 'BIOS', '');
  FIPLFile := Ini.ReadString('Hardware', 'IPL', '');
  FWarmBoot := Ini.ReadBool('Hardware', 'WarmBoot', True);
  FBIOSenabled := Ini.ReadBool('Hardware', 'BIOSEnabled', True);
  FKeyboardEnabled := Ini.ReadBool('Ports', 'KeyboardEnabled', True);
  FTapeFile := Ini.ReadString('Ports', 'TapeFile', '');
  FTapeAutoPlay := Ini.ReadBool('Ports', 'TapeAutoPlay', False);
  FMapperHint := Ini.ReadInteger('Cartridge', 'Mapper', -1);
  if (FMapperHint < -1) or (FMapperHint > Ord(High(TSMSMapper))) then
    FMapperHint := -1;
  FOptions.ShowBackground := Ini.ReadBool('Video', 'ShowBackground', True);
  FOptions.ShowSprites := Ini.ReadBool('Video', 'ShowSprites', True);
  FOptions.RemoveSpriteLimit := Ini.ReadBool('Video', 'RemoveSpriteLimit', False);
  FOptions.GGRegion := EnsureRange(Ini.ReadInteger('Hardware', 'Territory', 0), 0, 2);
  FOptions.FMEnabled := True;
  FOptions.FMVolume := EnsureRange(Ini.ReadInteger('Audio', 'FMVolume', 100), 0, 100);
  FOptions.DiskWriteProtected := Ini.ReadBool('Disk', 'WriteProtected', False);
  for var i := 0 to 3 do
    FOptions.ChannelVolume[i] := EnsureRange(Ini.ReadInteger('Audio', 'Channel' + IntToStr(i + 1) + 'Volume', 100), 0, 100);
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TSGConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'Model', FModelName);
  Ini.WriteString('Hardware', 'BIOS', FBiosFile);
  Ini.WriteString('Hardware', 'IPL', FIPLFile);
  Ini.WriteBool('Hardware', 'WarmBoot', FWarmBoot);
  Ini.WriteBool('Hardware', 'BIOSEnabled', FBIOSenabled);
  Ini.WriteBool('Ports', 'KeyboardEnabled', FKeyboardEnabled);
  Ini.WriteString('Ports', 'TapeFile', FTapeFile);
  Ini.WriteBool('Ports', 'TapeAutoPlay', FTapeAutoPlay);
  Ini.WriteInteger('Cartridge', 'Mapper', FMapperHint);
  Ini.WriteBool('Video', 'ShowBackground', FOptions.ShowBackground);
  Ini.WriteBool('Video', 'ShowSprites', FOptions.ShowSprites);
  Ini.WriteBool('Video', 'RemoveSpriteLimit', FOptions.RemoveSpriteLimit);
  Ini.WriteInteger('Hardware', 'Territory', FOptions.GGRegion);
  Ini.DeleteKey('Audio', 'FMEnabled');
  Ini.WriteInteger('Audio', 'FMVolume', FOptions.FMVolume);
  Ini.WriteBool('Disk', 'WriteProtected', FOptions.DiskWriteProtected);
  for var i := 0 to 3 do
    Ini.WriteInteger('Audio', 'Channel' + IntToStr(i + 1) + 'Volume', FOptions.ChannelVolume[i]);
  Ini.WriteString('Video', 'Region', FVideoRegion);
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

function TSGConfig.ResolvePAL(const ROM: TBytes; const RomName: string): Boolean;
begin
  if (FSystemId = ROM_SYSTEM_SMS) and SameText(FVideoRegion, 'Auto') then
    Result := SMSAutoPAL(ROM, RomName)
  else
    Result := FPAL;
end;

{ TSGCoreAdapter }

constructor TSGCoreAdapter.Create(const FileName: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName, SameText(ExtractFileExt(FileName), ROM_EXTENSION_SC));
  finally
    Stream.Free;
  end;
end;

constructor TSGCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; SC3000: Boolean; ModelHint: Integer);
var
  Cart: TSGCartridge;
  Config: TSGConfig;
  Hash: THashSHA2;
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var Data := ReadRomData(Stream);
  FData := Copy(Data);
  FSC3000 := SC3000;
  if SC3000 then
    FModel := TSGModel.SC3000
  else
    FModel := TSGModel.SG1000;
  if (ModelHint >= 0) and (ModelHint <= Ord(High(TSGModel))) then
    FModel := TSGModel(ModelHint);
  if FModel in [TSGModel.MasterSystem, TSGModel.MarkIII, TSGModel.GameGear] then
  begin
    var Cartridge := TSMSCartridge.Create(Data);
    Cartridge.Free;
  end
  else if FModel <> TSGModel.SF7000 then
  begin
    Cart := TSGCartridge.Create(Data);
    Cart.Free;
  end;
  var SystemId := ROM_SYSTEM_SG1000;
  if FSC3000 then
    SystemId := ROM_SYSTEM_SC3000;
  case FModel of
    TSGModel.SF7000:
      SystemId := ROM_SYSTEM_SF7000;
    TSGModel.Multivision:
      SystemId := ROM_SYSTEM_OMV;
    TSGModel.MasterSystem, TSGModel.MarkIII:
      SystemId := ROM_SYSTEM_SMS;
    TSGModel.GameGear:
      SystemId := ROM_SYSTEM_GG;
  end;
  Config := TSGConfig.Create(FStorage.ConfigFile(SystemId), FStorage, SystemId);
  FConfig := Config;
  Config.Load;
  FResolvedPAL := Config.ResolvePAL(FData, RomName);
  if (SystemId = ROM_SYSTEM_SG1000) and SameText(Config.ModelName, 'sg1000ii') then
    FModel := TSGModel.SG1000II;
  if (SystemId = ROM_SYSTEM_SC3000) and SameText(Config.ModelName, 'sc3000h') then
    FModel := TSGModel.SC3000H;
  if (SystemId = ROM_SYSTEM_SMS) and SameText(Config.ModelName, 'markiii') then
    FModel := TSGModel.MarkIII;
  if (SystemId = ROM_SYSTEM_SMS) and Config.BIOSenabled then
  begin
    if Config.BIOSFile <> '' then
      FBootROM := FStorage.ReadBytes(Config.BIOSFile)
    else if FModel = TSGModel.MasterSystem then
      FBootROM := LoadBuiltinSMSBIOS(DefaultSMSBIOSJapanese(FData));
    // Mark III has no internal BIOS. An explicit external ROM remains usable.
  end;
  if FModel = TSGModel.SF7000 then
  begin
    if (Length(FData) = $2000) and (SGCRC32(FData) = $D76810B8) then
    begin
      FBootROM := FData;
      FData := nil;
    end
    else
    begin
      var IPL := Config.IPLFile;
      if IPL = '' then
      begin
        var Folders: TArray<string> := [ExtractFilePath(RomName)];
        Folders := Folders + [FStorage.RomFolder('sf7000'), FStorage.RomFolder('sg1000')];
        for var Folder in Folders do
        begin
          if not FStorage.FolderExists(Folder) then
            Continue;
          for var Path in FStorage.Files(Folder) do
          begin
            var FileInfo := FStorage.Describe(Path);
            if (FileInfo.Size = $2000) and (SameText(FileInfo.Name, 'ipl.rom') or
              FileInfo.Name.ToLower.Contains('initial program loader') or SameText(FileInfo.Name, 'sf7000.rom')) then
            begin
              IPL := Path;
              Break;
            end;
          end;
          if IPL <> '' then
            Break;
        end;
      end;
      if IPL = '' then
        raise EReadError.Create('SF-7000 needs its 8 KiB IPL ROM. Select it in SF-7000 settings or place ipl.rom beside the disk.');

      FBootROM := FStorage.ReadBytes(IPL);
      var Disk := SG1000.Disk.TSGDisk.Create(FData);
      Disk.Free;
    end;
  end;
  FKeys := Config.Keys;
  FKeys2 := Config.Keys2;
  Hash := THashSHA2.Create;
  Hash.Update(Data);
  FSnapshotDirectory := FStorage.GameSnapshots(SystemId, RomName, Hash.HashAsString);
  FSaveFile := FStorage.GameSave(SystemId, RomName, Hash.HashAsString);
end;

destructor TSGCoreAdapter.Destroy;
begin
  // The worker joins before releasing its console and synchronization objects.
  FThread.Free;
  inherited;
end;

procedure TSGCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    var Keys := FHostKeys;
    for var i := 0 to High(Keys) do
      Keys[i] := Keys[i] or FScreenKeys[i];
    FThread.Configure(GetInputState, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TSGCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TSGWorker.Create(FData, FSC3000, FResolvedPAL, FStorage,
    Ord(FModel), FBootROM, TSGConfig(FConfig).WarmBoot);
  FThread.Options := TSGConfig(FConfig).Options;
  FThread.MapperHint := TSGConfig(FConfig).MapperHint;
  FThread.TapeFile := TSGConfig(FConfig).TapeFile;
  FThread.TapeAutoPlay := TSGConfig(FConfig).TapeAutoPlay;
  FThread.SaveFile := FSaveFile;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  FThread.InputPorts := LoadCoreInputPorts(FStorage, TSGConfig(FConfig).SystemId);
  ApplySettings;
  FThread.Start;
end;

procedure TSGCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TSGCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TSGCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TSGCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TSGCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
  (FConfig as TSGConfig).FKeyboardEnabled := Ports.KeyboardEnabled;
end;

procedure TSGCoreAdapter.ClearInput;
begin
  FillChar(FHostKeys, SizeOf(FHostKeys), 0);
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FKeyboard := [];
  FGamepad := [];
  FKeyboard2 := [];
  FGamepad2 := [];
  ApplySettings;
end;

procedure TSGCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
var
  Button: TSGButton;
begin
  if GetHasKeyboard then
  begin
    if not TSGConfig(FConfig).KeyboardEnabled then
      Exit;
    if Code <= High(FHostKeys) then
      FHostKeys[Code] := Pressed;

    // FMX can report either generic or left/right modifier virtual keys.
    if Code in [vkLShift, vkRShift] then
      FHostKeys[vkShift] := FHostKeys[vkLShift] or FHostKeys[vkRShift];
    if Code in [vkLControl, vkRControl] then
      FHostKeys[vkControl] := FHostKeys[vkLControl] or FHostKeys[vkRControl];
    if Code in [vkLMenu, vkRMenu] then
      FHostKeys[vkMenu] := FHostKeys[vkLMenu];
    ApplySettings;
    if FModel <> TSGModel.Multivision then
      Exit;
  end;

  for Button := Low(TSGButton) to High(TSGButton) do
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

function TSGCoreAdapter.GetInputState: TEmulatorInput;
const
  Mapping: array[TSGButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B,
    TEmulatorButton.Start);
begin
  Result := Default(TEmulatorInput);
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    if Button in (FKeyboard + FGamepad) then
      Include(Result.Buttons, Mapping[Button]);
    if Button in (FKeyboard2 + FGamepad2) then
      Include(Result.Buttons2, Mapping[Button]);
  end;
end;

procedure TSGCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
const
  Mapping: array[TSGButton] of TEmulatorButton =
    (TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
    TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Start);
begin
  FGamepad := [];
  FGamepad2 := [];
  for var Button := Low(TSGButton) to High(TSGButton) do
  begin
    if Mapping[Button] in Input.Buttons then
      Include(FGamepad, Button);
    if Mapping[Button] in Input.Buttons2 then
      Include(FGamepad2, Button);
  end;
  ApplySettings;
end;

function TSGCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TSGCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TSGCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TSGCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

procedure TSGCoreAdapter.SetScreenKeys(const Keys: TSGHostKeys);
begin
  FScreenKeys := Keys;
  ApplySettings;
end;

function TSGCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := FModel in [TSGModel.SG1000II, TSGModel.SC3000, TSGModel.SC3000H, TSGModel.SF7000, TSGModel.Multivision];
end;

function TSGCoreAdapter.GetSystemId: string;
begin
  Result := (FConfig as TSGConfig).SystemId;
end;

function TSGCoreAdapter.GetName: string;
begin
  case FModel of
    TSGModel.SG1000:
      Result := 'SEGA SG-1000';
    TSGModel.SG1000II:
      Result := 'SEGA SG-1000 II';
    TSGModel.SC3000:
      Result := 'SEGA SC-3000';
    TSGModel.SC3000H:
      Result := 'SEGA SC-3000H';
    TSGModel.Multivision:
      Result := 'Othello Multivision';
    TSGModel.SF7000:
      Result := 'SEGA SF-7000';
    TSGModel.MasterSystem:
      Result := 'SEGA Master System';
    TSGModel.GameGear:
      Result := 'SEGA Game Gear';
    TSGModel.MarkIII:
      Result := 'SEGA Mark III';
  end;
end;

function TSGCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TSGCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TSGCoreAdapter.InsertCoin1;
begin
end;

procedure TSGCoreAdapter.InsertCoin2;
begin
end;

function TSGCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TSGCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TSGCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TSGCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.SaveSnapshot(Name);
end;

procedure TSGCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');

  FThread.LoadSnapshot(Name);
end;

end.


