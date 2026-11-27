unit Core.Platforms.Intellivision.Adapter;

interface

uses
  System.SysUtils, System.IniFiles, Core.Emulation, Core.Emulation.Types,
  Core.InputConfig, Core.Input.Keyboard, Core.Storage, INTV.Console,
  INTV.Emulation, INTV.ECS, INTV.KeyboardComponent, INTV.KeyboardPeripherals,
  INTV.PlayCable, INTV.Cartridge, INTV.Firmware, Core.Microphone;

const
  IntvPlatformId = 'intellivision';
  IntvCoreId = 'INTV';
  IntvCartSizeLimit = $200000;

type
  TIntvKeyMap = array[0..1, TEmulatorButton] of UInt32;

  IIntvKeypadInput = interface
    ['{427BBC27-B7BD-4943-8D2D-7DE2C803B36C}']
    procedure SetVirtualKeypad(Mask: Word);
  end;

  TIntvConfig = class(TEmulatorConfigBase)
  private
    FPAL, FUseKeyboardComponent, FKeyboardMicrophoneEnabled: Boolean;
    FModel: string;
    FECSMode, FVoiceMode, FKeyboardTape, FKeyboardTapeAudio: string;
    FECSInput: TIntvECSInput;
    FKeys: TIntvKeyMap;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage);
    class procedure DefaultKeys(out Keys: TIntvKeyMap); static;
  end;

  TIntvCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationInputPorts, IEmulationLiveSettings, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IIntvKeypadInput, IEmulationKeyboard, IEmulationMicrophoneInput)
  private
    FWorker: TIntvWorker;
    FData, FExec, FGROM, FIdentity, FECSROM, FVoiceROM: TBytes;
    FKeyboardFirmware: TIntvKeyboardFirmware;
    FKeyboardTape, FKeyboardTapeAudio: TBytes;
    FKeyboardTapePath, FKeyboardPrintPath: string;
    FMicrophone: IMicrophoneSource;
    FMicrophoneOverridden: Boolean;
    FMapping, FSnapshotDirectory, FFlashPath, FError: string;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FPorts: TCoreInputPorts;
    FKeyboard: array[0..1] of TEmulatorButtons;
    FGamepad: TEmulatorInput;
    FKeypads: TIntvKeypads;
    FECSKeys, FScreenKeys: THostKeyboardKeys;
    FECSInput: TIntvECSInput;
    FVirtualKeypad: Word;
    FPaused, FPAL, FSTIC1A: Boolean;
    procedure UpdateWorker;
  public
    constructor Create(const Data: TBytes; const Storage: IStorage; const RomName, Mapping: string);
    destructor Destroy; override;
    procedure ApplyLiveSettings;
    procedure ApplyInputPorts(const Ports: TCoreInputPorts);
    procedure SetVirtualKeypad(Mask: Word);
    procedure SetMicrophoneSource(const Source: IMicrophoneSource);
    procedure SetScreenKeys(const Keys: THostKeyboardKeys);
    function GetHasKeyboard: Boolean;
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
  System.Classes, System.UITypes, System.IOUtils, System.Hash,
  System.Generics.Collections, Core.EmulatorRegistry;

const
  MappedButtons =[ TEmulatorButton.Up,  TEmulatorButton.Down,  TEmulatorButton.Left,
      TEmulatorButton.Right,  TEmulatorButton.A,  TEmulatorButton.B,  TEmulatorButton.C,
      TEmulatorButton.Start,  TEmulatorButton.Select,  TEmulatorButton.X,  TEmulatorButton.Y];
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
  KeySections: array[0..1] of string = ('Keys', 'Keys2');

constructor TIntvConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  FModel := 'Standard';
  FECSMode := 'Auto';
  FVoiceMode := 'Auto';
  FECSInput := TIntvECSInput.Keyboard;
  DefaultKeys(FKeys);
end;

class procedure TIntvConfig.DefaultKeys(out Keys: TIntvKeyMap);
const
  Defaults: TIntvKeyMap = (
    (vkUp, vkDown, vkLeft, vkRight, vkZ, vkX, vkQ, vkReturn, vkC, vk1, vk2, 0, 0),
    (vkT, vkG, vkF, vkH, vkN, vkM, vkE, vkR, vkB, vkNumpad1, vkNumpad2, 0, 0));
begin
  Keys := Defaults;
end;

procedure TIntvConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FPAL := SameText(Ini.ReadString('Video', 'Region', 'NTSC'), 'PAL');
  FModel := Ini.ReadString('Hardware', 'Model', 'Standard');
  FKeyboardMicrophoneEnabled := Ini.ReadBool('Hardware', 'KeyboardMicrophone', False);
  FKeyboardTape := Ini.ReadString('Hardware', 'KeyboardTape', '');
  FKeyboardTapeAudio := Ini.ReadString('Hardware', 'KeyboardTapeAudio', '');
  FUseKeyboardComponent := SameText(Ini.ReadString('Hardware', 'KeyboardComponent', 'Off'), 'On');
  FECSMode := Ini.ReadString('Hardware', 'ECS', 'Auto');
  FVoiceMode := Ini.ReadString('Hardware', 'Intellivoice', 'Auto');
  var Device := Ini.ReadString('Hardware', 'ECSInput', 'Keyboard');
  if SameText(Device, 'Controllers') then
    FECSInput := TIntvECSInput.Controllers
  else if SameText(Device, 'Piano') then
    FECSInput := TIntvECSInput.Piano
  else
    FECSInput := TIntvECSInput.Keyboard;
  DefaultKeys(FKeys);
  for var Port := 0 to 1 do
    for var Button in MappedButtons do
      FKeys[Port, Button] := ReadEmulatorKey(Ini, KeySections[Port], KeyNames[Button], FKeys[Port, Button]);
end;

procedure TIntvConfig.SaveCoreSettings(Ini: TCustomIniFile);
const
  Devices: array[TIntvECSInput] of string = ('Keyboard', 'Controllers', 'Piano');
begin
  Ini.WriteString('Hardware', 'Model', FModel);
  if FUseKeyboardComponent then
    Ini.WriteString('Hardware', 'KeyboardComponent', 'On')
  else
    Ini.WriteString('Hardware', 'KeyboardComponent', 'Off');
  Ini.WriteBool('Hardware', 'KeyboardMicrophone', FKeyboardMicrophoneEnabled);
  Ini.WriteString('Hardware', 'KeyboardTape', FKeyboardTape);
  Ini.WriteString('Hardware', 'KeyboardTapeAudio', FKeyboardTapeAudio);
  Ini.WriteString('Hardware', 'ECS', FECSMode);
  Ini.WriteString('Hardware', 'Intellivoice', FVoiceMode);
  Ini.WriteString('Hardware', 'ECSInput', Devices[FECSInput]);
  if FPAL then
    Ini.WriteString('Video', 'Region', 'PAL')
  else
    Ini.WriteString('Video', 'Region', 'NTSC');
  for var Port := 0 to 1 do
    for var Button in MappedButtons do
      Ini.WriteInteger(KeySections[Port], KeyNames[Button], FKeys[Port, Button]);
end;

constructor TIntvCoreAdapter.Create(const Data: TBytes; const Storage: IStorage; const RomName, Mapping: string);

  function TryReadFirmware(const Folder, Name: string; Maximum: Integer; out Bytes: TBytes): Boolean;
  begin
    var Location := '';
    if Folder.StartsWith('content://', True) then
    begin
      for var FileName in FStorage.Files(Folder) do
        if SameText(FStorage.Describe(FileName).Name, Name) then
        begin
          Location := FileName;
          Break;
        end;
    end
    else
    begin
      var Path := TPath.Combine(Folder, Name);
      if FStorage.Exists(Path) then
        Location := Path;
    end;
    Result := Location <> '';
    if not Result then
      Exit;
    var Input := FStorage.OpenRead(Location);
    try
      if (Input.Size <= 0) or (Input.Size > Maximum) then
        raise ECoreInvalidMedia.Create('Invalid Intellivision firmware: ' + Location);
      Bytes := ReadRomData(Input);
    finally
      Input.Free;
    end;
  end;

  function FirmwareFolders: TArray<string>;
  begin
    var RomFolder := FStorage.RomFolder(IntvPlatformId);
    var LocalFolder := ExtractFileDir(RomName);
    if RomName.StartsWith('content://', True) then
      LocalFolder := '';
    var BIOSFolder := TPath.Combine(FStorage.Root, 'bios');
    var Candidates := TList<string>.Create;
    try
      for var Folder in [LocalFolder, RomFolder, TPath.Combine(BIOSFolder, IntvPlatformId), BIOSFolder] do
      begin
        if (Folder = '') or Candidates.Contains(Folder) then
          Continue;
        Candidates.Add(Folder);
        if Folder.StartsWith('content://', True) then
        begin
          for var Subfolder in FStorage.Folders(Folder) do
            if SameText(FStorage.Describe(Subfolder).Name, 'firmware') then
              Candidates.Add(Subfolder);
        end
        else
          Candidates.Add(TPath.Combine(Folder, 'firmware'));
      end;
      Result := Candidates.ToArray;
    finally
      Candidates.Free;
    end;
  end;

  procedure ReadFirmware(const Folders: TArray<string>; const ExecName, GROMName: string; MaximumExec: Integer = $2200; ExactSize: Boolean = False; Builtin: Boolean = True);
  begin
    for var Candidate in Folders do
    begin
      var Exec, GROM: TBytes;
      if TryReadFirmware(Candidate, ExecName, MaximumExec, Exec) and
        (not ExactSize or (Length(Exec) = MaximumExec)) and
        TryReadFirmware(Candidate, GROMName, $800, GROM) and
        (not ExactSize or (Length(GROM) = $800)) then
      begin
        FExec := Exec;
        FGROM := GROM;
        Exit;
      end;
    end;
    if Builtin then
    begin
      var Exec := LoadBuiltinIntvFirmware(ExecName);
      var GROM := LoadBuiltinIntvFirmware(GROMName);
      if (Exec <> nil) and (GROM <> nil) and (Length(Exec) <= MaximumExec) and
        (not ExactSize or (Length(Exec) = MaximumExec)) then
      begin
        FExec := Exec;
        FGROM := GROM;
      end;
    end;
  end;

  procedure ReadIntellivisionIIFirmware(const Folders: TArray<string>);
  const
    MainSize = $2000;
    ExtensionSize = $200;
    ImageSize = MainSize + ExtensionSize;
  begin
    for var Candidate in Folders do
    begin
      ReadFirmware([Candidate], 'exec2.bin', 'grom.bin', ImageSize, True, False);
      if FExec <> nil then
        Exit;
      var Raw, GROM: TBytes;
      if TryReadFirmware(Candidate, 'ro-3-9506-010.ic6', ImageSize, Raw) and
        (Length(Raw) = ImageSize) and TryReadFirmware(Candidate, 'grom.bin', $800, GROM) and
        (Length(GROM) = $800) then
      begin
        // The physical dump starts with $0400-$04FF and stores words little-endian.
        SetLength(FExec, ImageSize);
        for var Offset := 0 to ImageSize div 2 - 1 do
        begin
          var Source := (Offset * 2 + ExtensionSize) mod ImageSize;
          FExec[Offset * 2] := Raw[Source + 1];
          FExec[Offset * 2 + 1] := Raw[Source];
        end;
        FGROM := GROM;
        Exit;
      end;
      ReadFirmware([Candidate], 'exec.bin', 'grom.bin', ImageSize, True, False);
      if FExec <> nil then
        Exit;
    end;
    FExec := LoadBuiltinIntvFirmware('exec2.bin');
    FGROM := LoadBuiltinIntvFirmware('grom.bin');
  end;

begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FData := Data;
  FMapping := Mapping;
  var Config := TIntvConfig.Create(FStorage.ConfigFile(IntvPlatformId), FStorage);
  FConfig := Config;
  FConfig.Load;
  FPAL := Config.FPAL;
  FECSInput := Config.FECSInput;
  FPorts := LoadCoreInputPorts(FStorage, IntvPlatformId, FConfig.FileName);
  var Folders := FirmwareFolders;
  var PlayCable := TIntvPlayCable.IsImage(Data);
  var Kiosk := TIntvKiosk.IsImage(Data);
  var IntellivisionII := SameText(Config.FModel, 'Intellivision II');
  var TutorVision := not PlayCable and SameText(Config.FModel, 'TutorVision');
  FSTIC1A := TutorVision or (not PlayCable and SameText(Config.FModel, 'INTV88'));
  if TutorVision then
  begin
    ReadFirmware(Folders, 'wbexec.bin', 'wbgrom.bin', $4000, True);
    if (Length(FExec) <> $4000) or (Length(FGROM) <> $800) then
      raise ECoreInvalidMedia.Create('TutorVision needs a 16 KiB wbexec.bin and a 2 KiB wbgrom.bin in the same firmware folder.');
  end;
  if IntellivisionII then
  begin
    ReadIntellivisionIIFirmware(Folders);
    if (Length(FExec) <> $2200) or (Length(FGROM) <> $800) then
      raise ECoreInvalidMedia.Create('Intellivision II needs an 8704-byte EXEC image (exec2.bin, ro-3-9506-010.ic6 or combined exec.bin) and a 2 KiB grom.bin in the same firmware folder.');
  end;
  if SameText(Config.FModel, 'Sears Super Video Arcade') then
  begin
    ReadFirmware(Folders, 'searsexc.bin', 'grom.bin', $2000, True);
    if FExec = nil then
      raise ECoreInvalidMedia.Create('Sears Super Video Arcade needs an 8 KiB searsexc.bin and a 2 KiB grom.bin in the same firmware folder.');
  end;
  if Config.FUseKeyboardComponent and (FExec = nil) then
    ReadFirmware(Folders, 'kbd-exec.bin', 'kbd-grom.bin');
  if FExec = nil then
    ReadFirmware(Folders, 'exec.bin', 'grom.bin');
  if (PlayCable or Kiosk) and (FExec = nil) then
    ReadFirmware(Folders, 'kbd-exec.bin', 'kbd-grom.bin');
  if PlayCable and (FExec = nil) then
    raise ECoreInvalidMedia.Create('PlayCable needs the original exec.bin and grom.bin.');
  if Kiosk and (FExec = nil) then
    raise ECoreInvalidMedia.Create('The kiosk needs original exec.bin and grom.bin.');
  if Config.FUseKeyboardComponent and (FExec = nil) then
    raise ECoreInvalidMedia.Create('Keyboard Component needs the original exec.bin and grom.bin.');
  if FExec = nil then
    ReadFirmware(Folders, 'miniexec.bin', 'minigrom.bin');
  if FExec = nil then
    raise ECoreInvalidMedia.Create('Intellivision needs exec.bin and grom.bin in the ROM or BIOS folder.');
  try
    if Kiosk and Config.FUseKeyboardComponent then
      raise EReadError.Create('The kiosk ROM occupies the Keyboard Component ROM window');
    if Kiosk and SameText(Config.FECSMode, 'On') then
      raise EReadError.Create('The kiosk ROM occupies the ECS ROM window');
    var Console := TIntvConsole.Create(FData, FExec, FGROM, FMapping, FPAL, FSTIC1A);
    try
      if Config.FUseKeyboardComponent and not PlayCable then
      begin
        for var Folder in Folders do
        begin
          var Firmware: TIntvKeyboardFirmware;
          if TryReadFirmware(Folder, 'kbd-master.bin', $2000, Firmware.MasterROM) and
            TryReadFirmware(Folder, 'kbd-6502.bin', $2000, Firmware.KeyboardROM) and
            TryReadFirmware(Folder, 'kbd-font.bin', $800, Firmware.CharacterROM) then
          begin
            FKeyboardFirmware := Firmware;
            Break;
          end;
        end;
        if FKeyboardFirmware.MasterROM = nil then
        begin
          FKeyboardFirmware.MasterROM := LoadBuiltinIntvFirmware('kbd-master.bin');
          FKeyboardFirmware.KeyboardROM := LoadBuiltinIntvFirmware('kbd-6502.bin');
          FKeyboardFirmware.CharacterROM := LoadBuiltinIntvFirmware('kbd-font.bin');
        end;
        if FKeyboardFirmware.MasterROM = nil then
          raise ECoreInvalidMedia.Create('Keyboard Component needs kbd-master.bin, kbd-6502.bin and kbd-font.bin together in the firmware folder.');
        for var Folder in Folders do
          if TryReadFirmware(Folder, 'kbd-basic.bin', $2000, FKeyboardFirmware.CartridgeROM) then
            Break;
        if FKeyboardFirmware.CartridgeROM = nil then
          FKeyboardFirmware.CartridgeROM := LoadBuiltinIntvFirmware('kbd-basic.bin');
        Console.EnableKeyboardComponent(FKeyboardFirmware);
        if (Config.FKeyboardTape = '') and (Config.FKeyboardTapeAudio <> '') then
          raise EReadError.Create('Keyboard Component audio needs a digital tape image');
        if Config.FKeyboardTape <> '' then
        begin
          var Tape := FStorage.OpenRead(Config.FKeyboardTape);
          try
            if (Tape.Size <= 0) or (Tape.Size > IntvKeyboardTapeLimit) then
              raise EReadError.Create('Invalid Keyboard Component tape image size');
            FKeyboardTape := ReadRomData(Tape);
          finally
            Tape.Free;
          end;
          var TapeHash := THashSHA2.Create;
          TapeHash.Update(FKeyboardTape);
          FKeyboardTapePath := TPath.Combine(FStorage.SaveRoot, 'intellivision-keyboard-' + TapeHash.HashAsString + '.bits');
          Console.KeyboardComponent.Peripherals.Attach(FKeyboardTape, nil, '', '');
          if Config.FKeyboardTapeAudio <> '' then
          begin
            var Wave := FStorage.OpenRead(Config.FKeyboardTapeAudio);
            try
              if (Wave.Size <= 0) or (Wave.Size > IntvKeyboardAudioLimit) then
                raise EReadError.Create('Invalid Keyboard Component tape audio size');
              FKeyboardTapeAudio := ReadRomData(Wave, IntvKeyboardAudioLimit);
            finally
              Wave.Free;
            end;
            Console.KeyboardComponent.Peripherals.AttachAudio(FKeyboardTapeAudio);
          end;
        end;
      end;
      var ForceECS := not PlayCable and SameText(Config.FECSMode, 'On');
      var AutoECS := not SameText(Config.FECSMode, 'Off') and (Console.Cartridge.ECSCompatibility >= 2);
      if TutorVision and (ForceECS or (AutoECS and (Console.Cartridge.ECSCompatibility = 3))) then
        raise EReadError.Create('TutorVision WBEXEC occupies the ECS ROM window at $2000-$2FFF');
      if not Kiosk and not TutorVision and (ForceECS or AutoECS) then
      begin
        for var Folder in Folders do
          if TryReadFirmware(Folder, 'ecs.bin', $6000, FECSROM) then
            Break;
        if FECSROM = nil then
          FECSROM := LoadBuiltinIntvFirmware('ecs.bin');
        if FECSROM <> nil then
          Console.EnableECS(FECSROM)
        else if ForceECS or (Console.Cartridge.ECSCompatibility = 3) then
          raise ECoreInvalidMedia.Create('Intellivision ECS needs ecs.bin in the ROM or BIOS folder.');
      end;
      var ForceVoice := not PlayCable and SameText(Config.FVoiceMode, 'On');
      var AutoVoice := not SameText(Config.FVoiceMode, 'Off') and (Console.Cartridge.VoiceCompatibility > 0);
      if ForceVoice or AutoVoice then
      begin
        for var Folder in Folders do
        begin
          for var Name in ['ivoice.bin', 'sp0256-012.bin', '012.bin'] do
            if TryReadFirmware(Folder, Name, $800, FVoiceROM) then
              Break;
          if FVoiceROM <> nil then
            Break;
        end;
        if FVoiceROM = nil then
          FVoiceROM := LoadBuiltinIntvFirmware('ivoice.bin');
        if FVoiceROM <> nil then
          Console.EnableVoice(FVoiceROM)
        else if ForceVoice or (Console.Cartridge.VoiceCompatibility = 3) then
          raise ECoreInvalidMedia.Create('Intellivoice needs ivoice.bin (SP0256-012) in the ROM or BIOS folder.');
      end;
    finally
      Console.Free;
    end;
  except
    on E: EReadError do
      raise ECoreInvalidMedia.Create(E.Message);
  end;

  var Hash := THashSHA2.Create;
  Hash.Update(FData);
  Hash.Update(FExec);
  Hash.Update(FGROM);
  Hash.Update(TEncoding.UTF8.GetBytes(FMapping));
  Hash.Update(TEncoding.ASCII.GetBytes(IntToStr(Ord(FPAL))));
  if FSTIC1A then
    Hash.Update(TEncoding.ASCII.GetBytes('STIC1A'));
  if FECSROM <> nil then
    Hash.Update(FECSROM);
  if FVoiceROM <> nil then
  begin
    Hash.Update(TEncoding.ASCII.GetBytes('SP0256-012'));
    Hash.Update(FVoiceROM);
  end;
  if FKeyboardFirmware.MasterROM <> nil then
  begin
    Hash.Update(TEncoding.ASCII.GetBytes('Keyboard Component'));
    Hash.Update(FKeyboardFirmware.MasterROM);
    Hash.Update(FKeyboardFirmware.KeyboardROM);
    Hash.Update(FKeyboardFirmware.CharacterROM);
    if FKeyboardFirmware.CartridgeROM <> nil then
      Hash.Update(FKeyboardFirmware.CartridgeROM);
    if FKeyboardTape <> nil then
    begin
      Hash.Update(TEncoding.ASCII.GetBytes('Keyboard Component tape'));
      Hash.Update(FKeyboardTape);
      if FKeyboardTapeAudio <> nil then
      begin
        Hash.Update(TEncoding.ASCII.GetBytes('Keyboard Component tape audio'));
        Hash.Update(FKeyboardTapeAudio);
      end;
    end;
  end;
  FIdentity := Hash.HashAsBytes;
  FSnapshotDirectory := FStorage.GameSnapshots(IntvPlatformId, RomName, Hash.HashAsString);
  var FlashIdentity := THashSHA2.Create;
  FlashIdentity.Update(FData);
  FlashIdentity.Update(TEncoding.UTF8.GetBytes(FMapping));
  FFlashPath := FStorage.GameSave(IntvPlatformId, RomName, FlashIdentity.HashAsString);
  if FKeyboardFirmware.MasterROM <> nil then
    FKeyboardPrintPath := ChangeFileExt(FFlashPath, '.kbd-printer.txt');
end;

destructor TIntvCoreAdapter.Destroy;
begin
  FWorker.Free;
  inherited;
end;

procedure TIntvCoreAdapter.UpdateWorker;
begin
  if FWorker <> nil then
  begin
    var Keypads := FKeypads;
    Keypads[0] := Keypads[0] or FVirtualKeypad;
    var Keys := FECSKeys;
    for var Key := 0 to High(Keys) do
      Keys[Key] := Keys[Key] or FScreenKeys[Key];
    FWorker.Configure(GetInputState, Keypads, Keys, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
  end;
end;

procedure TIntvCoreAdapter.ApplyLiveSettings;
begin
  ClearInput;
end;

procedure TIntvCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FWorker <> nil then
    FWorker.InputPorts := Ports;
  FPorts := Ports;
end;

procedure TIntvCoreAdapter.SetVirtualKeypad(Mask: Word);
begin
  if FVirtualKeypad = (Mask and $FFF) then
    Exit;
  FVirtualKeypad := Mask and $FFF;
  UpdateWorker;
end;

procedure TIntvCoreAdapter.SetMicrophoneSource(const Source: IMicrophoneSource);
begin
  FMicrophone := Source;
  FMicrophoneOverridden := True;
  if FWorker <> nil then
    FWorker.SetMicrophoneSource(Source);
end;

procedure TIntvCoreAdapter.SetScreenKeys(const Keys: THostKeyboardKeys);
begin
  if GetHasKeyboard then
  begin
    FScreenKeys := Keys;
    UpdateWorker;
  end;
end;

function TIntvCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := (FKeyboardFirmware.MasterROM <> nil) or
    ((FECSROM <> nil) and (FECSInput <> TIntvECSInput.Controllers));
end;

function TIntvCoreAdapter.GetSystemId: string;
begin
  Result := IntvPlatformId;
end;

function TIntvCoreAdapter.GetName: string;
begin
  Result := 'Intellivision';
end;

function TIntvCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TIntvCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TIntvCoreAdapter.InsertCoin1;
begin
end;

procedure TIntvCoreAdapter.InsertCoin2;
begin
end;

procedure TIntvCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  FWorker := TIntvWorker.Create(FData, FExec, FGROM, FIdentity, FECSROM, FVoiceROM, FMapping, FPAL, FStorage, FKeyboardFirmware, FSTIC1A);
  FWorker.SnapshotDirectory := FSnapshotDirectory;
  FWorker.FlashPath := FFlashPath;
  FWorker.KeyboardTape := FKeyboardTape;
  FWorker.KeyboardTapeAudio := FKeyboardTapeAudio;
  FWorker.KeyboardMicrophoneEnabled := (FConfig as TIntvConfig).FKeyboardMicrophoneEnabled;
  if FMicrophoneOverridden then
    FWorker.SetMicrophoneSource(FMicrophone);
  FWorker.KeyboardTapePath := FKeyboardTapePath;
  FWorker.KeyboardPrintPath := FKeyboardPrintPath;
  FWorker.ECSInput := FECSInput;
  FWorker.InputPorts := FPorts;
  UpdateWorker;
  FWorker.Start;
end;

procedure TIntvCoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;
  FWorker.StopAndWait;
  FError := FWorker.TakeError;
  FreeAndNil(FWorker);
end;

procedure TIntvCoreAdapter.Pause;
begin
  FPaused := True;
  UpdateWorker;
end;

procedure TIntvCoreAdapter.Resume;
begin
  FPaused := False;
  UpdateWorker;
end;

procedure TIntvCoreAdapter.Reset;
begin
  FPaused := False;
  if FWorker <> nil then
    FWorker.RequestReset;
  UpdateWorker;
end;

procedure TIntvCoreAdapter.ClearInput;
begin
  FKeyboard[0] := [];
  FKeyboard[1] := [];
  FGamepad := Default(TEmulatorInput);
  FKeypads := Default(TIntvKeypads);
  FECSKeys := Default(THostKeyboardKeys);
  FScreenKeys := Default(THostKeyboardKeys);
  FVirtualKeypad := 0;
  UpdateWorker;
end;

procedure TIntvCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if (Code = 0) or not FPorts.KeyboardEnabled then
    Exit;
  if GetHasKeyboard and (Code <= High(FECSKeys)) then
    FECSKeys[Code] := Pressed;
  if FKeyboardFirmware.MasterROM <> nil then
  begin
    UpdateWorker;
    Exit;
  end;
  for var Port := 0 to 1 do
    for var Button in MappedButtons do
      if Code = (FConfig as TIntvConfig).FKeys[Port, Button] then
        if Pressed then
          Include(FKeyboard[Port], Button)
        else
          Exclude(FKeyboard[Port], Button);
  var Port := 0;
  var Key := -1;
  if (Code >= Ord('0')) and (Code <= Ord('9')) then
    Key := Code - Ord('0')
  else if (Code >= vkNumpad0) and (Code <= vkNumpad9) then
  begin
    Port := 1;
    Key := Code - vkNumpad0;
  end;
  if Key >= 0 then
    if Pressed then
      FKeypads[Port] := FKeypads[Port] or (1 shl Key)
    else
      FKeypads[Port] := FKeypads[Port] and not (1 shl Key);
  UpdateWorker;
end;

procedure TIntvCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  UpdateWorker;
end;

function TIntvCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := Result.Buttons + FKeyboard[0];
  Result.Buttons2 := Result.Buttons2 + FKeyboard[1];
end;

function TIntvCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TIntvCoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FWorker.SaveSnapshot(Name);
end;

procedure TIntvCoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker = nil then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FWorker.LoadSnapshot(Name);
end;

function TIntvCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TIntvCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TIntvCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FWorker <> nil then
    Result := FWorker.TakeAudioError;
end;

function TIntvCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TIntvCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

