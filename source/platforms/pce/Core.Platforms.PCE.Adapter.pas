unit Core.Platforms.PCE.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  PCE.Cartridge, PCE.Emulation, Core.CD.Disc, Core.InputConfig;

type
  TPCEKeyMap = array[TEmulatorButton] of UInt32;

  TPCEConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TPCEKeyMap;
    FModelName, FBIOSFile: string;
    FSystemId: string;
    FOptions: TPCEOptions;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property Options: TPCEOptions read FOptions;
    property SystemId: string read FSystemId write FSystemId;
    property ModelName: string read FModelName;
    property BIOSFile: string read FBIOSFile;
    property Keys: TPCEKeyMap read FKeys;
    property Keys2: TPCEKeyMap read FKeys2;
  end;

  TPCECoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FCartridge: TPCECartridge;
    FDisc: TCDDisc;
    FModel: TPCEModel;
    FIdentity: TBytes;
    FSystemId: string;
    FThread: TPCEWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TPCEConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory, FSaveFile: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; Disc: TCDDisc = nil; const SourceHint: string = '');
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
  System.UITypes, System.IOUtils, Core.Snapshots, PCE.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TPCECoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TPCEConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TPCEKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkA, vkC, vkV, vkS, 0);
  Keys2: TPCEKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FKeys := Keys1;
  FKeys2 := Keys2;
  FModelName := 'auto';
  FOptions := TPCEOptions.Defaults;
end;

procedure TPCEConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FModelName := Ini.ReadString('Hardware', 'Model', 'auto');
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FOptions.ShowBackground := Ini.ReadBool('Video', 'ShowBackground', True);
  FOptions.ShowSprites := Ini.ReadBool('Video', 'ShowSprites', True);
  FOptions.RemoveSpriteLimit := Ini.ReadBool('Video', 'RemoveSpriteLimit', False);
  FOptions.Multitap := Ini.ReadBool('Input', 'Multitap1', False);
  FOptions.SixButton := Ini.ReadBool('Input', 'SixButton', False);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TPCEConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'Model', FModelName);
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteBool('Video', 'ShowBackground', FOptions.ShowBackground);
  Ini.WriteBool('Video', 'ShowSprites', FOptions.ShowSprites);
  Ini.WriteBool('Video', 'RemoveSpriteLimit', FOptions.RemoveSpriteLimit);
  Ini.WriteBool('Input', 'Multitap1', FOptions.Multitap);
  Ini.WriteBool('Input', 'SixButton', FOptions.SixButton);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TPCECoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; Disc: TCDDisc; const SourceHint: string);
const
  Models: array[TPCEModel] of string = ('pce', 'tg16', 'coregrafx', 'coregrafxii',
    'shuttle', 'gt', 'lt', 'sgx', 'cdrom2', 'supercd', 'duo', 'duor', 'duorx', 'turboduo', 'arcadeduo', 'arcadepro',
    'sgxcd', 'tgcd', 'sgxarcade');
begin
  inherited Create;
  FDisc := Disc; // Ownership transfers before validation, including constructor failure.
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  if SourceHint <> '' then
    SourceName := SourceHint;
  var Ext := ExtractFileExt(SourceName).ToLower;
  FSystemId := 'pce';
  FModel := TPCEModel.PCengine;
  if SourceName.ToLower.Contains('(u)') or SourceName.ToLower.Contains('(usa)') then
    FModel := TPCEModel.TurboGrafx16;
  if (Ext = '.cue') or (Ext = '.iso') or (Ext = '.chd') or (Ext = '.mds') then
  begin
    FSystemId := 'pcecd';
    FModel := TPCEModel.SuperCDROM2;
    if SourceName.ToLower.Contains('(u)') or SourceName.ToLower.Contains('(usa)') then
      FModel := TPCEModel.TurboDuo;
    if FDisc = nil then
      FDisc := TCDDisc.Create(Stream, FStorage, RomName);
  end
  else
  begin
    var Data := ReadRomData(Stream);
    FCartridge := TPCECartridge.Create(Data, SourceName);
    if FCartridge.SuperGrafx then
    begin
      FSystemId := 'sgx';
      FModel := TPCEModel.SuperGrafx;
    end;
  end;
  FConfigObject := TPCEConfig.Create(FStorage.ConfigFile(FSystemId), FStorage);
  FConfig := FConfigObject;
  FConfigObject.SystemId := FSystemId;
  FConfig.Load;
  for var M := Low(TPCEModel) to High(TPCEModel) do
    if SameText(FConfigObject.ModelName, Models[M]) then
      FModel := M;
  if (FDisc <> nil) and not PCEHasCD(FModel) then
    raise EReadError.Create('A CD image requires a CD-ROM2, Duo or Arcade Card model');

  if (FCartridge <> nil) and FCartridge.SuperGrafx and not PCESuperGrafx(FModel) then
    raise EReadError.Create('This HuCard requires SuperGrafx');

  if FDisc <> nil then
  begin
    var BIOS := FConfigObject.BIOSFile;
    if BIOS = '' then
    begin
      for var N in [DefaultPCEBIOSName(FModel), 'syscard.pce'] do
      begin
        var Candidate := TPath.Combine(ExtractFilePath(RomName), N);
        if not RomName.StartsWith('content://', True) and FStorage.Exists(Candidate) then
        begin
          BIOS := Candidate;
          Break;
        end;

        Candidate := TPath.Combine(FStorage.RomFolder('pcecd'), N);
        if not FStorage.RomFolder('pcecd').StartsWith('content://', True) and FStorage.Exists(Candidate) then
        begin
          BIOS := Candidate;
          Break;
        end;
      end;
    end;
    if BIOS = '' then
      BIOS := 'builtin:' + DefaultPCEBIOSName(FModel);
    if BIOS.StartsWith('builtin:', True) then
      FCartridge := TPCECartridge.Create(LoadBuiltinPCEBIOS(Copy(BIOS, 9, MaxInt)), BIOS)
    else
      FCartridge := TPCECartridge.Create(FStorage.ReadBytes(BIOS), BIOS);
    FIdentity := FDisc.Identity + FCartridge.IdentityData;
  end
  else
    FIdentity := Copy(FCartridge.IdentityData);
  FSnapshotDirectory := FStorage.GameSnapshots(FSystemId, RomName, SnapshotIdentity(FIdentity));
  FSaveFile := FStorage.GameSave(FSystemId, RomName, SnapshotIdentity(FIdentity));
end;

destructor TPCECoreAdapter.Destroy;
begin
  FThread.Free;
  FDisc.Free;
  FCartridge.Free;
  inherited;
end;

procedure TPCECoreAdapter.ApplySettings;
begin
  if FThread <> nil then
  begin
    FThread.ConfigureOptions(FConfigObject.Options);
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TPCECoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  FThread := TPCEWorker.Create(FCartridge, FModel, FDisc, FStorage);
  FThread.InputPorts := LoadCoreInputPorts(FStorage, FSystemId);
  FThread.IdentityData := Copy(FIdentity);
  FThread.SaveFile := FSaveFile;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TPCECoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TPCECoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TPCECoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TPCECoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TPCECoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TPCECoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TPCECoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TPCECoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TPCECoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := Default(TEmulatorInput);
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
  Result.Buttons3 := FGamepad.Buttons3;
  Result.Buttons4 := FGamepad.Buttons4;
  Result.Buttons5 := FGamepad.Buttons5;
end;

function TPCECoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TPCECoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TPCECoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TPCECoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TPCECoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TPCECoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TPCECoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TPCECoreAdapter.GetSystemId: string;
begin
  Result := FSystemId;
end;

function TPCECoreAdapter.GetName: string;
begin
  Result := PCEModelName(FModel);
end;

function TPCECoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TPCECoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TPCECoreAdapter.InsertCoin1;
begin
end;

procedure TPCECoreAdapter.InsertCoin2;
begin
end;

function TPCECoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

