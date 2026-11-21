unit Core.Platforms.Atari8.Adapter;

interface

uses
  System.SysUtils, System.Classes, System.IniFiles, Core.Storage, Core.Emulation,
  Core.InputConfig, Core.Input.Keyboard, A8.Machine, A5200.Emulation;

const
  Atari8SystemId = 'atari800';
  Atari8CoreId = 'ATARI800';
  Atari8Buttons: TEmulatorButtons = [TEmulatorButton.Up, TEmulatorButton.Down, TEmulatorButton.Left,
      TEmulatorButton.Right, TEmulatorButton.A, TEmulatorButton.B, TEmulatorButton.Select, TEmulatorButton.Start,
      TEmulatorButton.Mode];
  Atari8ModelNames: array[TA8Model] of string = ('Atari 400 · 16K', 'Atari 800 · 48K',
    'Atari 600XL · 16K', 'Atari 800XL · 64K', 'Atari 1200XL · 64K',
    'Atari 65XE · 64K', 'Atari 130XE · 128K', 'Atari 800XE · 64K', 'Atari XEGS · 64K');

type
  TA8Config = class(TEmulatorConfigBase)
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
  public
    Options: TA8Options;
    LegacyOSFile, XLOSFile, BasicFile, GameFile: string;
    constructor Create(const FileName: string; const Storage: IStorage);
  end;

  TA8CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationLiveSettings, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationVirtualControls, IEmulationKeyboard)
  private
    FData: TBytes;
    FThread: TA5200Worker;
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TA8Config;
    FGamepad: TEmulatorInput;
    FPorts: TCoreInputPorts;
    FKeys, FScreenKeys: THostKeyboardKeys;
    FLastKey: Byte;
    FAutomaticRawMapper: Integer;
    FRequiresOriginalXLOS, FTapeBootBasic, FTapeBasicRevA, FTapeOSB: Boolean;
    FPaused: Boolean;
    FError, FRomName, FExtension, FSnapshotDirectory: string;
    function KeyboardState: Word;
  public
    constructor Create(const Data: TBytes; const Storage: IStorage; const RomName, Extension: string);
    destructor Destroy; override;
    procedure ApplyLiveSettings;
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
    procedure SetScreenKeys(const Keys: THostKeyboardKeys);
    function GetHasKeyboard: Boolean;
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

function ResolveAtari8BootOptions(const Storage: IStorage; const RomName: string; Config: TA8Config; RequiresOriginalXLOS: Boolean; TapeBootBasic: Boolean = False; TapeBasicRevA: Boolean = False; TapeOSB: Boolean = False): TA8Options;

implementation

uses
  System.Hash, System.IOUtils, System.UITypes, System.ZLib, A5200.Console,
  A5200.Controller, A8.Media, A8.POKEY, Core.Snapshots, Core.Archive.Container,
  Core.Archive.Zip;

function ReadAtariFirmware(const Storage: IStorage; const Location: string; Size: Integer): TBytes;
begin
  Result := nil;
  if Location = '' then
    Exit;
  var Stream := Storage.OpenRead(Location);
  try
    if Stream.Size <> Size then
      raise EReadError.CreateFmt('Atari firmware must be %d bytes: %s', [Size, Location]);
    SetLength(Result, Size);
    Stream.ReadBuffer(Result[0], Size);
  finally
    Stream.Free;
  end;
end;

function AtariFirmwareFolders(const Storage: IStorage; const RomName, Category: string): TArray<string>;
begin
  Result := [TPath.Combine(Storage.Root, 'firmware')];
  if not RomName.Contains('://') and TPath.IsPathRooted(RomName) then
  begin
    var RomFolder := ExtractFileDir(ExpandFileName(RomName));
    var Firmware := TPath.Combine(ExtractFileDir(RomFolder), 'Atari firmware');
    Result := Result + [RomFolder, Firmware, TPath.Combine(Firmware, Category)];
  end;
end;

function FindOriginalOS(const Storage: IStorage; const RomName: string; Legacy: Boolean): TBytes;
begin
  var Names: TArray<string>;
  var Size: Integer;
  var Expected: Cardinal;
  if Legacy then
  begin
    Names := ['atariosb.rom', '400-800 OS B NTSC.rom'];
    Size := $2800;
    Expected := $0E86D61D;
  end
  else
  begin
    Names := ['atarixl.rom', '800XL-XE OS rev 2.rom'];
    Size := $4000;
    Expected := $1F9CD270;
  end;
  for var Folder in AtariFirmwareFolders(Storage, RomName, 'Original OS') do
    for var Name in Names do
    begin
      var Location := TPath.Combine(Folder, Name);
      if not Storage.Exists(Location) then
        Continue;
      try
        var Data := ReadAtariFirmware(Storage, Location, Size);
        if crc32(0, @Data[0], Length(Data)) = Expected then
          Exit(Data);
      except
        on E: EInOutError do
          Continue;
        on E: EStreamError do
          Continue;
      end;
    end;
  Result := nil;
end;

function FindOriginalBasic(const Storage: IStorage; const RomName: string; RevisionA: Boolean): TBytes;
const
  BasicSize = $2000;
  BasicRevACRC32 = $4BEC4DE2;
  BasicRevCCRC32 = $7D684184;
begin
  var Names: TArray<string>;
  var Expected: Cardinal;
  if RevisionA then
  begin
    Names := ['Atari BASIC rev A.rom', 'BASIC - Revision A.rom', 'BASIC - Revision A.zip'];
    Expected := BasicRevACRC32;
  end
  else
  begin
    Names := ['Atari BASIC rev C.rom', 'ataribas.rom'];
    Expected := BasicRevCCRC32;
  end;
  for var Folder in AtariFirmwareFolders(Storage, RomName, 'Original BASIC') do
    for var Name in Names do
    begin
      var Location := TPath.Combine(Folder, Name);
      if not Storage.Exists(Location) then
        Continue;
      try
        var Data: TBytes;
        if SameText(ExtractFileExt(Location), '.zip') then
        begin
          var Input := Storage.OpenRead(Location);
          var Archive: IArchiveContainer;
          try
            Archive := OpenZip(Input, Storage);
            var Member := Archive.FindName('BASIC - Revision A.rom');
            if (Member < 0) or (Archive.Entries[Member].Size <> BasicSize) then
              Continue;
            Archive.Read(Member, Data);
          finally
            Archive := nil;
            Input.Free;
          end;
        end
        else
          Data := ReadAtariFirmware(Storage, Location, BasicSize);
        if (Length(Data) = BasicSize) and (crc32(0, @Data[0], Length(Data)) = Expected) then
          Exit(Data);
      except
        on E: EInOutError do
          Continue;
        on E: EStreamError do
          Continue;
      end;
    end;
  Result := nil;
end;

function ResolveAtari8BootOptions(const Storage: IStorage; const RomName: string; Config: TA8Config; RequiresOriginalXLOS, TapeBootBasic, TapeBasicRevA, TapeOSB: Boolean): TA8Options;
begin
  Result := Config.Options;
  var Legacy := Result.Model in [TA8Model.Atari400, TA8Model.Atari800];
  if TapeOSB and (Legacy or ((Result.Model = TA8Model.Atari800XL) and (Config.XLOSFile = ''))) then
  begin
    Result.OSROM := ReadAtariFirmware(Storage, Config.LegacyOSFile, $2800);
    if Length(Result.OSROM) = 0 then
      Result.OSROM := FindOriginalOS(Storage, RomName, True);
    if (Length(Result.OSROM) <> 0) and not Legacy then
    begin
      Result.Model := TA8Model.Atari800;
      Legacy := True;
    end;
  end;
  if Legacy then
  begin
    if Length(Result.OSROM) = 0 then
      Result.OSROM := ReadAtariFirmware(Storage, Config.LegacyOSFile, $2800);
  end
  else
  begin
    Result.OSROM := ReadAtariFirmware(Storage, Config.XLOSFile, $4000);
    if (Config.XLOSFile = '') and (Result.Model = TA8Model.Atari800XL) then
    begin
      var Original := FindOriginalOS(Storage, RomName, False);
      if RequiresOriginalXLOS then
        Result.OSROM := Original
      else
        Result.FallbackOSROM := Original;
    end;
    if Result.Model = TA8Model.AtariXEGS then
      Result.GameROM := ReadAtariFirmware(Storage, Config.GameFile, $2000);
  end;
  if (Result.Model <> TA8Model.Atari1200XL) and (not Legacy or TapeBootBasic) then
  begin
    Result.BasicROM := ReadAtariFirmware(Storage, Config.BasicFile, $2000);
    if (Config.BasicFile = '') and TapeBootBasic then
      Result.BasicROM := FindOriginalBasic(Storage, RomName, TapeBasicRevA);
  end;
end;

constructor TA8Config.Create(const FileName: string; const Storage: IStorage);
begin
  inherited;
  Options.Model := TA8Model.Atari800XL;
end;

procedure TA8Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  var Model := Ini.ReadInteger('Machine', 'Model', Ord(TA8Model.Atari800XL));
  if (Model < Ord(Low(TA8Model))) or (Model > Ord(High(TA8Model))) then
    Model := Ord(TA8Model.Atari800XL);
  Options.Model := TA8Model(Model);
  Options.PAL := Ini.ReadBool('Machine', 'PAL', False);
  Options.Basic := Ini.ReadBool('Machine', 'Basic', False);
  Options.Mapper := Ini.ReadInteger('Cartridge', 'Mapper', 0);
  Options.WriteProtected := Ini.ReadBool('Media', 'DiskWriteProtected', False);
  LegacyOSFile := Ini.ReadString('Firmware', 'LegacyOS', '').Trim;
  XLOSFile := Ini.ReadString('Firmware', 'XLOS', '').Trim;
  BasicFile := Ini.ReadString('Firmware', 'Basic', '').Trim;
  GameFile := Ini.ReadString('Firmware', 'Game', '').Trim;
end;

constructor TA8CoreAdapter.Create(const Data: TBytes; const Storage: IStorage; const RomName, Extension: string);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FRomName := RomName;
  FExtension := Extension;
  FData := Copy(Data);
  FConfigObject := TA8Config.Create(FStorage.ConfigFile(Atari8SystemId), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FPorts := LoadCoreInputPorts(FStorage, Atari8SystemId, FConfig.FileName);
  var Check := TA8Media.Create(FData, FExtension, FConfigObject.Options.Mapper);
  try
    FAutomaticRawMapper := Check.AutomaticRawMapper;
    FRequiresOriginalXLOS := Check.RequiresOriginalXLOS;
    FTapeBootBasic := Check.TapeBootBasic;
    FTapeBasicRevA := Check.TapeBasicRevA;
    FTapeOSB := Check.TapeOSB;
  finally
    Check.Free;
  end;
  FSnapshotDirectory := FStorage.GameSnapshots(Atari8SystemId, FRomName, SnapshotIdentity(FData));
end;

destructor TA8CoreAdapter.Destroy;
begin
  FThread.Free;
  inherited;
end;

function MatrixCode(Code: Byte): Byte;
const
  Letters: array[0..25] of Byte = ($3F, $15, $12, $3A, $2A, $38, $3D, $39, $0D,
    $01, $05, $00, $25, $23, $08, $0A, $2F, $28, $3E, $2D, $0B, $10, $2E, $16, $2B, $17);
  Digits: array[0..9] of Byte = ($32, $1F, $1E, $1A, $18, $1D, $1B, $33, $35, $30);
begin
  case Code of
    vkA..vkZ:
      Result := Letters[Code - vkA];
    vk0..vk9:
      Result := Digits[Code - vk0];
    vkUp:
      Result := $8E;
    vkDown:
      Result := $8F;
    vkLeft:
      Result := $86;
    vkRight:
      Result := $87;
    vkBack:
      Result := $34;
    vkDelete:
      Result := $B4;
    vkInsert:
      Result := $B7;
    vkEscape:
      Result := $1C;
    vkCapital:
      Result := $3C;
    vkTab:
      Result := $2C;
    vkReturn:
      Result := $0C;
    vkSpace:
      Result := $21;
    vkF6:
      Result := $11;
    vkF10:
      Result := $27;
    vkSemicolon:
      Result := $02;
    vkComma:
      Result := $20;
    vkPeriod:
      Result := $22;
    vkMinus:
      Result := $0E;
    vkEqual:
      Result := $0F;
    vkSlash:
      Result := $26;
    vkLeftBracket:
      Result := $60;
    vkRightBracket:
      Result := $62;
    vkBackslash, vkOem102:
      Result := $46;
    vkQuote:
      Result := $73;
  else
    Result := A8NoKey;
  end;
end;

function TA8CoreAdapter.KeyboardState: Word;

  function Down(Code: Byte): Boolean;
  begin
    Result := FKeys[Code] or FScreenKeys[Code];
  end;

begin
  Result := A8NoKey;
  if not GetHasKeyboard then
    Exit;
  if Down(FLastKey) then
    Result := MatrixCode(FLastKey);
  if Result = A8NoKey then
    for var Code := Low(FKeys) to High(FKeys) do
      if Down(Code) and (MatrixCode(Code) <> A8NoKey) then
      begin
        Result := MatrixCode(Code);
        Break;
      end;
  if Down(vkShift) or Down(vkLShift) or Down(vkRShift) or
    ((Result <> A8NoKey) and (Result and $40 <> 0)) then
  begin
    Result := Result or A8Shift;
    if Byte(Result) <> A8NoKey then
      Result := Result or $40;
  end;
  if (Byte(Result) <> A8NoKey) and (Down(vkControl) or Down(vkLControl) or Down(vkRControl)) then
    Result := Result or $80;
  if Down(vkPause) or Down(vkF7) then
    Result := Result or A8Break;
  if Down(vkF2) then
    Result := Result or A8StartKey;
  if Down(vkF3) then
    Result := Result or A8SelectKey;
  if Down(vkF4) then
    Result := Result or A8OptionKey;
  if Down(vkF5) then
    Result := Result or A8ResetKey;
end;

procedure TA8CoreAdapter.ApplyLiveSettings;
var
  UnusedKeypads: TA5200Keypads;
begin
  if FThread <> nil then
  begin
    UnusedKeypads := Default(TA5200Keypads);
    FThread.Configure(FGamepad, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume,
      UnusedKeypads, KeyboardState);
  end;
end;

procedure TA8CoreAdapter.Start;
begin
  if FThread <> nil then
    Exit;
  var Options := ResolveAtari8BootOptions(FStorage, FRomName, FConfigObject, FRequiresOriginalXLOS,
    FTapeBootBasic, FTapeBasicRevA, FTapeOSB);
  var Settings: TBytes := [Byte(Options.Model), Byte(Options.PAL), Byte(Options.Basic), Byte(Options.Mapper)];
  var Firmware := Options.OSROM + Options.BasicROM + Options.GameROM;
  var Identity := FData + Settings + Firmware;
  var CompatibleHash: TBytes;
  if (FAutomaticRawMapper <> 0) and ((Options.Mapper = 0) or (Options.Mapper = FAutomaticRawMapper)) then
  begin
    // Older snapshots distinguish the menu choices even when they select the same hardware.
    if Options.Mapper = 0 then
      Settings[3] := Byte(FAutomaticRawMapper)
    else
      Settings[3] := 0;
    var Hash := THashSHA2.Create;
    Hash.Update(FData);
    Hash.Update(Settings);
    if Length(Firmware) <> 0 then
      Hash.Update(Firmware);
    CompatibleHash := Hash.HashAsBytes;
  end;
  var DiskCopy := '';
  if SameText(FExtension, '.atr') or SameText(FExtension, '.xfd') then
    DiskCopy := FStorage.GameSave(Atari8SystemId, FRomName, SnapshotIdentity(FData)) + FExtension;
  FThread := TA5200Worker.Create(Identity, Atari8CoreId,
    function: TAtariFrameMachine
    begin
      var Machine := TA8Machine.Create(FData, FExtension, Options);
      try
        Machine.AttachDisk(FStorage, DiskCopy);
      except
        Machine.Free;
        raise;
      end;
      Result := Machine;
    end, Atari8Buttons, FStorage, CompatibleHash);
  FThread.InputPorts := FPorts;
  FThread.SnapshotDirectory := FSnapshotDirectory;
  ApplyLiveSettings;
  FThread.Start;
end;

procedure TA8CoreAdapter.Stop;
begin
  if FThread = nil then
    Exit;
  FThread.Stop;
  FError := FThread.TakeError;
  FreeAndNil(FThread);
end;

procedure TA8CoreAdapter.Pause;
begin
  FPaused := True;
  ApplyLiveSettings;
end;

procedure TA8CoreAdapter.Resume;
begin
  FPaused := False;
  ApplyLiveSettings;
end;

procedure TA8CoreAdapter.Reset;
begin
  FPaused := False;
  if FThread <> nil then
    FThread.RequestReset;
  ApplyLiveSettings;
end;

procedure TA8CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  FPorts := Ports;
  ClearInput;
  if FThread <> nil then
    FThread.InputPorts := Ports;
end;

procedure TA8CoreAdapter.ClearInput;
begin
  FKeys := Default(THostKeyboardKeys);
  FScreenKeys := Default(THostKeyboardKeys);
  FLastKey := 0;
  FGamepad := Default(TEmulatorInput);
  ApplyLiveSettings;
end;

procedure TA8CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code > High(FKeys) then
    Exit;
  if Pressed and not FKeys[Code] and (MatrixCode(Code) <> A8NoKey) then
    FLastKey := Code;
  FKeys[Code] := Pressed;
  ApplyLiveSettings;
end;

procedure TA8CoreAdapter.SetScreenKeys(const Keys: THostKeyboardKeys);
begin
  FScreenKeys := Keys;
  ApplyLiveSettings;
end;

function TA8CoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := FPorts.KeyboardEnabled;
end;

procedure TA8CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  ApplyLiveSettings;
end;

function TA8CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
end;

function TA8CoreAdapter.GetVirtualButtons: TEmulatorButtons;
begin
  Result := Atari8Buttons;
end;

function TA8CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TA8CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.SaveSnapshot(Name);
end;

procedure TA8CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FThread <> nil then
    FThread.LoadSnapshot(Name);
end;

function TA8CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Result := (FThread <> nil) and FThread.TryGetFrame(Frame);
end;

function TA8CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FThread <> nil) then
    Result := FThread.TakeError;
end;

function TA8CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FThread <> nil then
    Result := FThread.TakeAudioError;
end;

function TA8CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TA8CoreAdapter.GetSystemId: string;
begin
  Result := Atari8SystemId;
end;

function TA8CoreAdapter.GetName: string;
begin
  Result := Atari8ModelNames[FConfigObject.Options.Model];
end;

function TA8CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TA8CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TA8CoreAdapter.InsertCoin1;
begin
end;

procedure TA8CoreAdapter.InsertCoin2;
begin
end;

function TA8CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.

