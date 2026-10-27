unit Core.Adapter.Saturn;

interface

uses
  Core.RomFormat, System.SysUtils, System.Classes, System.IniFiles, Core.Storage,
  Core.Emulation, Saturn.Console, Saturn.Emulation, Core.InputConfig,
  Core.CD.Disc;

type
  TSaturnKeyMap = array[TEmulatorButton] of UInt32;

  TSaturnConfig = class(TEmulatorConfigBase)
  private
    FKeys, FKeys2: TSaturnKeyMap;
    FBIOSFile: string;
    FCartROM: string;
    FUseSH1, FProtection: Boolean;
    FRAMCart: Integer;
    FRegion: Byte;
    FPAL: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    property BIOSFile: string read FBIOSFile;
    property CartROM: string read FCartROM;
    property UseSH1: Boolean read FUseSH1;
    property Protection: Boolean read FProtection;
    property RAMCart: Integer read FRAMCart;
    property Region: Byte read FRegion;
    property PAL: Boolean read FPAL;
    property Keys: TSaturnKeyMap read FKeys;
    property Keys2: TSaturnKeyMap read FKeys2;
  end;

  TSaturnCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics)
  private
    FBIOS, FIdentity: TBytes;
    FCartROM: TBytes;
    FDisc: TCDDisc;
    FThread: TSaturnWorker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TSaturnConfig;
    FKeyboard, FGamepad: TEmulatorInput;
    FPaused: Boolean;
    FError, FSnapshotDirectory, FSaveFile: string;
    procedure ApplySettings;
  public
    procedure ApplyLiveSettings;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc = nil);
    destructor Destroy; override;
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
  System.UITypes, System.IOUtils, Core.Snapshots, Saturn.Firmware;

const
  KeyNames: array[TEmulatorButton] of string = ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');

procedure TSaturnCoreAdapter.ApplyLiveSettings;
begin
  ApplySettings;
end;

constructor TSaturnConfig.Create(const FileName: string; const Storage: IStorage);
const
  Keys1: TSaturnKeyMap = (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkShift, vkReturn, vkC, vkA, vkS, vkD, vkTab);
  Keys2: TSaturnKeyMap = (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, 0, vkNumpad0, 0, vkNumpad3, 0, 0, 0);
begin
  inherited Create(FileName, Storage);
  FRegion := 4;
  FPAL := False;
  FRAMCart := 0;
  FKeys := Keys1;
  FKeys2 := Keys2;
end;

procedure TSaturnConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FRAMCart := Ini.ReadInteger('Hardware', 'RAMCart', 0);
  if not (FRAMCart in [0, 1, 4, 16, $21..$24]) then
    FRAMCart := 0;
  FCartROM := Ini.ReadString('Hardware', 'CartROM', '');
  FUseSH1 := SameText(Ini.ReadString('Hardware', 'CDBackend', 'model'), 'sh1');
  FProtection := Ini.ReadBool('Hardware', 'OpticalProtection', False);
  FRegion := Ini.ReadInteger('System', 'Region', 4);
  FPAL := Ini.ReadBool('System', 'PAL', False);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    FKeys[Button] := ReadEmulatorKey(Ini, 'Keys', KeyNames[Button], FKeys[Button]);
    FKeys2[Button] := ReadEmulatorKey(Ini, 'Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

procedure TSaturnConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteInteger('Hardware', 'RAMCart', FRAMCart);
  Ini.WriteString('Hardware', 'CartROM', FCartROM);
  if FUseSH1 then
    Ini.WriteString('Hardware', 'CDBackend', 'sh1')
  else
    Ini.WriteString('Hardware', 'CDBackend', 'model');
  Ini.WriteBool('Hardware', 'OpticalProtection', FProtection);
  Ini.WriteInteger('System', 'Region', FRegion);
  Ini.WriteBool('System', 'PAL', FPAL);
  for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
  begin
    Ini.WriteInteger('Keys', KeyNames[Button], FKeys[Button]);
    Ini.WriteInteger('Keys2', KeyNames[Button], FKeys2[Button]);
  end;
end;

constructor TSaturnCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc);
begin
  inherited Create;
  FDisc := OwnedDisc;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FConfigObject := TSaturnConfig.Create(FStorage.ConfigFile('saturn'), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  if FConfigObject.RAMCart = 16 then
  begin
    if FConfigObject.CartROM = '' then
      raise EReadError.Create('Select a Saturn ROM cartridge image in Saturn settings');

    FCartROM := FStorage.ReadBytes(FConfigObject.CartROM);
    if (Length(FCartROM) <> $100000) and (Length(FCartROM) <> $200000) and (Length(FCartROM) <> $400000) then
      raise EReadError.Create('Saturn ROM cartridge must contain 1, 2 or 4 MiB');
  end;
  if FDisc = nil then
  begin
    if Stream.Size - Stream.Position <> $80000 then
      raise EReadError.Create('Saturn BIOS must contain exactly 512 KiB');

    SetLength(FBIOS, $80000);
    Stream.ReadBuffer(FBIOS[0], Length(FBIOS));
    FIdentity := Copy(FBIOS);
  end
  else
  begin
    var BIOSPath := FConfigObject.BIOSFile;
    if BIOSPath = '' then
      for var Name in ['saturn_bios.bin', 'bios.bin', 'sega_101.bin', 'mpr-17933.bin'] do
      begin
        var Candidate := TPath.Combine(ExtractFilePath(RomName), Name);
        if not RomName.StartsWith('content://', True) and FStorage.Exists(Candidate) then
        begin
          BIOSPath := Candidate;
          Break;
        end;

        Candidate := TPath.Combine(FStorage.RomFolder('saturn'), Name);
        if not Candidate.StartsWith('content://', True) and FStorage.Exists(Candidate) then
        begin
          BIOSPath := Candidate;
          Break;
        end;
      end;

    if BIOSPath = '' then
      FBIOS := LoadBuiltinSaturnBIOS(DefaultSaturnBIOSName(FConfigObject.Region))
    else if BIOSPath.StartsWith('builtin:', True) then
      FBIOS := LoadBuiltinSaturnBIOS(BIOSPath.Substring(8))
    else
      FBIOS := FStorage.ReadBytes(BIOSPath);
    if Length(FBIOS) <> $80000 then
      raise EReadError.Create('Saturn BIOS must contain exactly 512 KiB');

    FIdentity := FDisc.Identity;
  end;
  FSnapshotDirectory := FStorage.GameSnapshots('saturn', RomName, SnapshotIdentity(FIdentity));
  FSaveFile := FStorage.GameSave('saturn', RomName, SnapshotIdentity(FIdentity));
end;

destructor TSaturnCoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;

  inherited;
end;

procedure TSaturnCoreAdapter.ApplySettings;
begin
  if FThread <> nil then
    FThread.Configure(GetInputState, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TSaturnCoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;

  FThread := TSaturnWorker.Create(FBIOS, FStorage, FConfigObject.Region, FConfigObject.PAL, FDisc, FConfigObject.RAMCart, FIdentity);
  FThread.CartROM := FCartROM;
  FThread.UseSH1 := FConfigObject.UseSH1;
  FThread.Protection := FConfigObject.Protection;
  if FConfigObject.RAMCart in [$21..$24] then
    FThread.CartSaveFile := FStorage.GameSave('saturn', 'backup-cartridge-' + IntToStr(FConfigObject.RAMCart), 'backup-cartridge-' + IntToStr(FConfigObject.RAMCart));
  FThread.InputPorts := LoadCoreInputPorts(FStorage, 'saturn');
  FThread.SaveFile := FSaveFile;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplySettings;
  FThread.Start;
end;

procedure TSaturnCoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;

  FThread.StopAndSave;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TSaturnCoreAdapter.Pause;
begin
  FPaused := True;
  ApplySettings;
end;

procedure TSaturnCoreAdapter.Resume;
begin
  FPaused := False;
  ApplySettings;
end;

procedure TSaturnCoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplySettings;
end;

procedure TSaturnCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TSaturnCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  ApplySettings;
end;

procedure TSaturnCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;

  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys, FKeyboard.Buttons);
  UpdateMappedButtons(Code, Pressed, FConfigObject.Keys2, FKeyboard.Buttons2);
  ApplySettings;
end;

procedure TSaturnCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplySettings;
end;

function TSaturnCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TSaturnCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TSaturnCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TSaturnCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TSaturnCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  ApplySettings;
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TSaturnCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TSaturnCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TSaturnCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TSaturnCoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_SATURN;
end;

function TSaturnCoreAdapter.GetName: string;
begin
  Result := 'SEGA Saturn';
end;

function TSaturnCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TSaturnCoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TSaturnCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TSaturnCoreAdapter.InsertCoin1;
begin
end;

procedure TSaturnCoreAdapter.InsertCoin2;
begin
end;

function TSaturnCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

