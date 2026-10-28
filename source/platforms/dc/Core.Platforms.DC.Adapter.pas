unit Core.Platforms.DC.Adapter;

interface

uses
  Core.Input.Keyboard, Core.InputConfig, System.SysUtils, System.Classes,
  System.IniFiles, System.SyncObjs, System.Threading, Core.Storage,
  Core.Emulation, Core.Snapshots, Core.CD.Disc, DC.Types, DC.Flash, DC.Maple,
  DC.Console, Core.Platforms.DC.Playback;

{$SCOPEDENUMS ON}

type
  // Analog stick directions beyond the logical pad (whose Select and Mode are
  // the L and R triggers); frontends number their actions in this order.
  TDCExtra = (StickUp, StickDown, StickLeft, StickRight);

  TDCKeyMap = array[0..3, TEmulatorButton] of UInt32;

  TDCExtraKeyMap = array[0..3, TDCExtra] of UInt32;

  // Host analog input of a controller: stick -32768..32767 (zero centered,
  // positive right/down) and triggers 0..255.
  TDCAnalogPad = record
    StickX, StickY: SmallInt;
    LeftTrigger, RightTrigger: Byte;
  end;

  IDCControllerInput = interface
    ['{3F1A7C52-9B0E-4D86-A2C4-58E1D7B9F036}']
    procedure SetDCController(Port: Integer; const Pad: TDCAnalogPad);
  end;

  TDCConfig = class(TEmulatorConfigBase)
  private
    FKeys: TDCKeyMap;
    FExtraKeys: TDCExtraKeyMap;
    FBIOSMode, FBIOSFile, FFlashFile, FRegion, FLanguage, FCable, FVideo, FVMUScreen: string;
    FShowVMU: Boolean;
    FRumble: Boolean;
    FRecompiler: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    class function ExtraKeyName(Extra: TDCExtra): string; static;
    function ExtraKey(Port: Integer; Extra: TDCExtra): UInt32;
    procedure SetExtraKey(Port: Integer; Extra: TDCExtra; Key: UInt32);
    // 'hle' (built-in high-level boot), 'auto' (external boot ROM when found)
    // or 'external'.
    property BIOSMode: string read FBIOSMode write FBIOSMode;
    // Empty: dc_boot.bin beside the image or in the dc ROM folder.
    property BIOSFile: string read FBIOSFile write FBIOSFile;
    property FlashFile: string read FFlashFile write FFlashFile;
    // 'auto' (from the disc), 'japan', 'usa' or 'europe'.
    property Region: string read FRegion write FRegion;
    // 'english', 'japanese', 'german', 'french', 'spanish' or 'italian'.
    property Language: string read FLanguage write FLanguage;
    // 'composite', 'rgb' or 'vga'.
    property Cable: string read FCable write FCable;
    // 'auto', 'ntsc' or 'pal'.
    property Video: string read FVideo write FVideo;
    // 'off', 'top-left', 'top-right', 'bottom-left' or 'bottom-right'.
    // The corner of the VMU screen and whether it is shown (hidden by default).
    property VMUScreen: string read FVMUScreen write FVMUScreen;
    property ShowVMU: Boolean read FShowVMU write FShowVMU;
    property Rumble: Boolean read FRumble write FRumble;
    // The SH-4's blocks as generated code where there is a code generator
    // (Emulation/Execution jit), else interpreted (interpreter).
    property Recompiler: Boolean read FRecompiler write FRecompiler;
    property Keys: TDCKeyMap read FKeys;
  end;

  TDCPadInputs = array[0..3] of TDCPad;

  // What a port holds (Dreamcast settings: controller, keyboard, mouse,
  // light gun or nothing).
  TDCPortKind = (None, Pad, Keyboard, Mouse, LightGun);

  // Keyboard, mouse and light gun input of the frontend thread: held keys
  // (USB HID usage codes, oldest first) and modifier bits, the mouse buttons
  // (bit 0 left, 1 right, 2 middle) and the pointer over the picture.
  TDCHostPeripherals = record
    Keys: array[0..5] of Byte;
    Modifiers: Byte;
    MouseButtons: Byte;
    PointerX, PointerY: Integer;
    PointerValid: Boolean;
  end;

  // The VMU display of port A for an overlay: 48x32, one byte per pixel
  // (0 off, 1 on), upright as seen through the controller window (the unit
  // sits upside down in the controller). False when unchanged or absent.
  IDCVMUScreen = interface
    ['{6B2C3D8E-5F41-4A7B-9C0D-2E1F3A4B5C6D}']
    function TakeVMUScreen(out Pixels: TBytes): Boolean;
    function VMUScreenCorner: string;
  end;

  TDCWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FInputPortsCommand: TInputPortsCommand;
    FStorage: IStorage;
    FConfig: TDCConsoleConfig;
    FProgram, FIdentity: TBytes;
    FDisc: TCDDisc;
    FVMUFiles: array[0..3] of string;
    FFlashSave: string;
    FSnapshotDirectory, FError, FAudioError: string;
    FInputs: TDCPadInputs;
    FPause, FReset, FAudioEnabled, FAvailable, FRumbleEnabled, FRecompiler: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FRumbleLevel: Byte;
    FVMUScreen: TBytes;
    FVMUChanged: Boolean;
    FConsole: TDCConsole;
    FAudio: TDCAudioPlayback;
    FAudioFailed: Boolean;
    FRate: TEmulationFrameRate;
    FDeadline: Double;
    FClockGuest: Int64;
    FKinds: array[0..3] of TDCPortKind;
    FWithVMU: array[0..3] of Boolean;
    FKeyboardRegion: Byte;
    FPeripherals: TDCHostPeripherals;
    FMouseDX, FMouseDY: Integer;
    // Disc change requested by the frontend thread (nil disc: eject).
    FMediaDone: TEvent;
    FMediaPending: Boolean;
    FNextDisc: TCDDisc;
    FNextIdentity: TBytes;
    FMediaError: string;
    procedure ProcessMediaChange;
    procedure ReportError(const Text: string);
    procedure SaveVMU(Port: Integer);
    procedure AudioFailure(E: Exception);
    procedure ClearAudio;
    procedure Restart;
    procedure ApplyPorts(const Ports: TCoreInputPorts);
    procedure AttachDevices;
    procedure TransferSnapshot(const Name: string; Loading: Boolean);
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
    procedure Publish;
    procedure SaveMemories;
    procedure StartMachine;
  protected
    procedure Execute; override;
  public
    constructor Create(const Config: TDCConsoleConfig; const ProgramData, Identity: TBytes; Disc: TCDDisc; const Storage: IStorage; const VMUFiles: array of string; const FlashSave, SnapshotDirectory: string; Rumble: Boolean);
    destructor Destroy; override;
    procedure Configure(const Inputs: TDCPadInputs; Paused, AudioEnabled: Boolean; Volume: Single; Recompiler: Boolean);
    procedure SetPeripherals(const Value: TDCHostPeripherals);
    // Relative host mouse movement, queued for the next frame.
    procedure AddMouseDelta(DX, DY: Integer);
    procedure RequestReset;
    procedure StopAndSave;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError(Audio: Boolean): string;
    procedure Snapshot(const Name: string; Loading: Boolean);
    function RumbleLevel: Byte;
    function TakeVMUScreen(out Pixels: TBytes): Boolean;
    // Opens the lid and, with a disc, closes it on that disc a second later
    // (machine time); returns once the lid is open. The disc must stay alive
    // until the next change or the end of the worker.
    procedure ChangeDisc(Disc: TCDDisc; const Identity: TBytes);
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  end;

  TDCCoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IEmulationRumbleOutput, IDCControllerInput, IDCVMUScreen, IEmulationDiscControl, IEmulationKeyboard, IEmulationMouseInput, IEmulationPointerInput)
  private
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TDCConfig;
    FWorker: TDCWorker;
    FDisc: TCDDisc;
    // Discs of the session (an M3U playlist, else the started image and any
    // opened later); FDiscIndex is -1 with the lid open and no disc.
    FDiscLocations, FDiscNames: TArray<string>;
    FDiscIndex: Integer;
    FProgram, FIdentity: TBytes;
    FMachine: TDCConsoleConfig;
    FPorts: TCoreInputPorts;
    FKeyboard, FGamepad: TEmulatorInput;
    FKeyboardExtra: array[0..3, TDCExtra] of Boolean;
    FControllers: array[0..3] of TDCAnalogPad;
    FPaused: Boolean;
    FVMUFiles: array[0..3] of string;
    FFlashSave, FSnapshotDirectory, FError: string;
    // Reads a newly chosen disc for its identity, then inserts it; the lid is
    // open meanwhile.
    FDiscTask: ITask;
    // Keyboard, mouse and light gun: host keys held (HID codes, oldest first)
    // and on-screen keys, mouse buttons and the pointer.
    FHostKeys: TArray<Byte>;
    FModifiers: Byte;
    FScreenKeys: THostKeyboardKeys;
    FPeripherals: TDCHostPeripherals;
    procedure LoadFirmware(const RomName: string);
    procedure Configure;
    function PortHolds(Device: string): Boolean;
    procedure HostKey(Code: UInt32; Pressed: Boolean);
    procedure PushPeripherals;
    procedure ReplaceDisc(const Location: string; Index: Integer);
    procedure WaitDiscTask;
  public
    // Stream holds an ELF or binary program when no disc is given.
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc = nil);
    destructor Destroy; override;
    class function IsDCDisc(Disc: TCDDisc): Boolean; static;
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
    procedure SetDCController(Port: Integer; const Pad: TDCAnalogPad);
    function GetInputState: TEmulatorInput;
    function GetSnapshotDirectory: string;
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError: string;
    function TakeAudioError: string;
    function GetConfig: IEmulatorConfig;
    function IsPaused: Boolean;
    function GetHasRumble: Boolean;
    function GetRumbleLevel: Byte;
    function TakeVMUScreen(out Pixels: TBytes): Boolean;
    function VMUScreenCorner: string;
    function GetDiscCount: Integer;
    function GetDiscName(Index: Integer): string;
    function GetDiscIndex: Integer;
    procedure ChangeDisc(Index: Integer);
    procedure OpenDisc(const Location: string);
    procedure EjectDisc;
    // A keyboard on a port takes the host keys.
    procedure SetScreenKeys(const Keys: THostKeyboardKeys);
    function GetHasKeyboard: Boolean;
    procedure SendMouseDelta(DX, DY: Integer; Buttons: Byte);
    function GetUsesPointer: Boolean;
    procedure SetPointer(X, Y: Integer; Valid: Boolean);
  end;

implementation

uses
  RM.Platforms.DC, Core.Platforms.DC.Keyboard,
  {$IFDEF MSWINDOWS}Winapi.MMSystem, {$ENDIF}
  System.Math, System.Diagnostics, System.UITypes, System.IOUtils,
  System.DateUtils, Core.SavePaths, DC.Disc, DC.ELF;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'A', 'B', 'Select', 'Start', 'C', 'X', 'Y', 'Z', 'Mode');
  // Select and Mode are the L and R triggers.
  DefaultKeys: array[0..1, TEmulatorButton] of UInt32 = (
    (vkUp, vkDown, vkLeft, vkRight, vkX, vkC, vkQ, vkReturn, 0, vkZ, vkS, 0, vkW),
    (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad1, vkNumpad2, vkDivide, vkNumpad0, 0, vkNumpad7, vkNumpad9,
    0, vkMultiply));
  ExtraKeyNames: array[TDCExtra] of string = ('StickUp', 'StickDown', 'StickLeft', 'StickRight');
  DefaultExtraKeys: array[TDCExtra] of UInt32 = (vkI, vkK, vkJ, vkL);
  ButtonBits: array[TEmulatorButton] of Word = (MapleUp, MapleDown, MapleLeft, MapleRight, MapleA, MapleB, 0,
    MapleStart, 0, MapleX, MapleY, 0, 0);

function StickByte(Value: Integer): Byte;
begin
  Result := EnsureRange(128 + EnsureRange(Value, -32768, 32767) div 256, 0, 255);
end;

{ TDCConfig }

constructor TDCConfig.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  for var P := 0 to 3 do
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if P < 2 then
        FKeys[P, B] := DefaultKeys[P, B]
      else
        FKeys[P, B] := 0;
  for var P := 0 to 3 do
    for var Extra := Low(TDCExtra) to High(TDCExtra) do
      if P = 0 then
        FExtraKeys[P, Extra] := DefaultExtraKeys[Extra]
      else
        FExtraKeys[P, Extra] := 0;
  FBIOSMode := 'hle';
  FRegion := 'auto';
  FLanguage := 'english';
  FCable := 'composite';
  FVideo := 'auto';
  FVMUScreen := 'top-right';
  FRumble := True;
  FRecompiler := True;
end;

class function TDCConfig.ExtraKeyName(Extra: TDCExtra): string;
begin
  Result := ExtraKeyNames[Extra];
end;

function TDCConfig.ExtraKey(Port: Integer; Extra: TDCExtra): UInt32;
begin
  Result := FExtraKeys[Port, Extra];
end;

procedure TDCConfig.SetExtraKey(Port: Integer; Extra: TDCExtra; Key: UInt32);
begin
  FExtraKeys[Port, Extra] := Key;
end;

function OneOf(const Value: string; const Allowed: array of string; const Default: string): string;
begin
  Result := Value.ToLower;
  for var A in Allowed do
    if Result = A then
      Exit;
  Result := Default;
end;

procedure TDCConfig.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSMode := OneOf(Ini.ReadString('Hardware', 'BIOSMode', 'hle'), ['hle', 'auto', 'external'], 'hle');
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FFlashFile := Ini.ReadString('Hardware', 'Flash', '');
  FRegion := OneOf(Ini.ReadString('System', 'Region', 'auto'), ['auto', 'japan', 'usa', 'europe'], 'auto');
  FLanguage := OneOf(Ini.ReadString('System', 'Language', 'english'),
    ['japanese', 'english', 'german', 'french', 'spanish', 'italian'], 'english');
  FCable := OneOf(Ini.ReadString('System', 'Cable', 'composite'), ['composite', 'rgb', 'vga'], 'composite');
  FVideo := OneOf(Ini.ReadString('System', 'Video', 'auto'), ['auto', 'ntsc', 'pal'], 'auto');
  FShowVMU := Ini.ReadBool('Peripherals', 'ShowVMU', False);
  FVMUScreen := OneOf(Ini.ReadString('Peripherals', 'VMUScreen', 'top-right'),
    ['top-left', 'top-right', 'bottom-left', 'bottom-right'], 'top-right');
  FRumble := Ini.ReadBool('Peripherals', 'Rumble', True);
  FRecompiler := not SameText(Ini.ReadString('Emulation', 'Execution', 'jit'), 'interpreter');
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      FKeys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TDCExtra) to High(TDCExtra) do
      FExtraKeys[P, Extra] := ReadEmulatorKey(Ini, Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

procedure TDCConfig.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOSMode', FBIOSMode);
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteString('Hardware', 'Flash', FFlashFile);
  Ini.WriteString('System', 'Region', FRegion);
  Ini.WriteString('System', 'Language', FLanguage);
  Ini.WriteString('System', 'Cable', FCable);
  Ini.WriteString('System', 'Video', FVideo);
  Ini.WriteBool('Peripherals', 'ShowVMU', FShowVMU);
  Ini.WriteString('Peripherals', 'VMUScreen', FVMUScreen);
  Ini.WriteBool('Peripherals', 'Rumble', FRumble);
  if FRecompiler then
    Ini.WriteString('Emulation', 'Execution', 'jit')
  else
    Ini.WriteString('Emulation', 'Execution', 'interpreter');
  for var P := 0 to 3 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TDCExtra) to High(TDCExtra) do
      Ini.WriteInteger(Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

{ TDCWorker }

constructor TDCWorker.Create(const Config: TDCConsoleConfig; const ProgramData, Identity: TBytes; Disc: TCDDisc; const Storage: IStorage; const VMUFiles: array of string; const FlashSave, SnapshotDirectory: string; Rumble: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConfig := Config;
  // Keyboard layout: Japanese on Japanese consoles, else US.
  FKeyboardRegion := 2;
  if Config.Region = TDCRegion.Japan then
    FKeyboardRegion := 1;
  FProgram := Copy(ProgramData);
  FIdentity := Copy(Identity);
  FDisc := Disc;
  FStorage := Storage;
  for var I := 0 to 3 do
    FVMUFiles[I] := VMUFiles[I];
  FFlashSave := FlashSave;
  FSnapshotDirectory := SnapshotDirectory;
  FRumbleEnabled := Rumble;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FInputPortsCommand := TInputPortsCommand.Create;
  FMediaDone := TEvent.Create(nil, True, False, '');
end;

destructor TDCWorker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FMediaDone.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TDCWorker.ChangeDisc(Disc: TCDDisc; const Identity: TBytes);
begin
  if Suspended or Finished then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FLock.Acquire;
  try
    if FMediaPending then
      raise EInvalidOpException.Create('A disc change is already pending');
    FMediaDone.ResetEvent;
    FNextDisc := Disc;
    FNextIdentity := Copy(Identity);
    FMediaError := '';
    FMediaPending := True;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
  while FMediaDone.WaitFor(50) <> wrSignaled do
    if Finished then
      raise EInvalidOpException.Create('Emulation stopped before changing the disc');
  FLock.Acquire;
  try
    if FMediaError <> '' then
      raise EReadError.Create(FMediaError);
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.ProcessMediaChange;
const
  // Machine time with the lid open, so that programs polling the drive
  // notice the change.
  LidSeconds = 1.0;
begin
  FLock.Acquire;
  try
    if not FMediaPending then
      Exit;
    try
      // RAM, CPU, VMUs and flash stay; only the drive changes media.
      if FNextDisc = nil then
        FConsole.OpenLid
      else
        FConsole.ChangeDisc(FNextDisc, LidSeconds);
      FDisc := FNextDisc;
      FIdentity := FNextIdentity;
    except
      on E: Exception do
        FMediaError := E.Message;
    end;
    FNextDisc := nil;
    FNextIdentity := nil;
    FMediaPending := False;
    FMediaDone.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TDCWorker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TDCWorker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

procedure TDCWorker.Configure(const Inputs: TDCPadInputs; Paused, AudioEnabled: Boolean; Volume: Single; Recompiler: Boolean);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInputs := Inputs;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
    FRecompiler := Recompiler;
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TDCWorker.RequestReset;
begin
  FLock.Acquire;
  try
    FReset := True;
    FAvailable := False;
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TDCWorker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

function TDCWorker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FAvailable;
    if Result then
    begin
      Frame := FFrame;
      FAvailable := False;
    end;
  finally
    FLock.Release;
  end;
end;

function TDCWorker.TakeError(Audio: Boolean): string;
begin
  FLock.Acquire;
  try
    if Audio then
    begin
      Result := FAudioError;
      FAudioError := '';
    end
    else
    begin
      Result := FError;
      FError := '';
    end;
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

function TDCWorker.RumbleLevel: Byte;
begin
  FLock.Acquire;
  try
    Result := FRumbleLevel;
  finally
    FLock.Release;
  end;
end;

function TDCWorker.TakeVMUScreen(out Pixels: TBytes): Boolean;
begin
  FLock.Acquire;
  try
    Result := FVMUChanged;
    FVMUChanged := False;
    Pixels := Copy(FVMUScreen);
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.Publish;
begin
  var Frame: TEmulatorFrame;
  Frame.Width := FConsole.PVR.FrameWidth;
  Frame.Height := FConsole.PVR.FrameHeight;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  var Source := FConsole.PVR.Frame;
  if Length(Source) >= Length(Frame.Pixels) then
    Move(Source[0], Frame.Pixels[0], Length(Frame.Pixels) * SizeOf(Cardinal));
  Frame.FrameNumber := FConsole.FrameCount;
  Frame.FramesPerSecond := FRate.Update(Frame.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);
  // Port A's VMU display for the frontend overlay, turned upright: the unit
  // sits upside down in the controller.
  var Screen: TBytes := nil;
  var Changed := False;
  var VMU := FConsole.Maple.Devices[0, 1];
  if (VMU is TDCVMU) and TDCVMU(VMU).LCDChanged then
  begin
    TDCVMU(VMU).LCDChanged := False;
    SetLength(Screen, 48 * 32);
    for var Y := 0 to 31 do
      for var X := 0 to 47 do
      begin
        var SX := 47 - X;
        var SY := 31 - Y;
        Screen[Y * 48 + X] := (TDCVMU(VMU).LCD[SY * 6 + SX div 8] shr (7 - SX mod 8)) and 1;
      end;
    Changed := True;
  end;
  var Level: Byte := 0;
  var Pack := FConsole.Maple.Devices[0, 2];
  if FRumbleEnabled and (Pack is TDCPuruPuru) then
    Level := TDCPuruPuru(Pack).Level;
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
    FRumbleLevel := Level;
    if Changed then
    begin
      FVMUScreen := Screen;
      FVMUChanged := True;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.ReportError(const Text: string);
begin
  FLock.Acquire;
  try
    if FError = '' then
      FError := Text
    else
      FError := FError + #13#10 + Text;
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.AudioFailure(E: Exception);
begin
  FLock.Acquire;
  try
    FAudioError := 'Dreamcast audio: ' + E.Message;
  finally
    FLock.Release;
  end;
  FAudioFailed := True;
  FreeAndNil(FAudio);
  Restart;
end;

procedure TDCWorker.ClearAudio;
begin
  if FAudio = nil then
    Exit;
  try
    FAudio.Clear;
  except
    on E: Exception do
      AudioFailure(E);
  end;
end;

procedure TDCWorker.Restart;
begin
  FDeadline := TStopwatch.GetTimeStamp;
  FClockGuest := FConsole.Scheduler.Now;
  FRate.Reset(FConsole.FrameCount, TStopwatch.GetTimeStamp);
end;

procedure TDCWorker.ApplyPorts(const Ports: TCoreInputPorts);
begin
  // 'auto': controllers on every port, a VMU in the first one.
  for var Port := 0 to 3 do
  begin
    var Device := Ports.Devices[Port];
    if Device = 'none' then
      FKinds[Port] := TDCPortKind.None
    else if Device = 'keyboard' then
      FKinds[Port] := TDCPortKind.Keyboard
    else if Device = 'mouse' then
      FKinds[Port] := TDCPortKind.Mouse
    else if Device = 'lightgun' then
      FKinds[Port] := TDCPortKind.LightGun
    else
      FKinds[Port] := TDCPortKind.Pad;
    FWithVMU[Port] := (Device = 'pad-vmu') or ((Device = 'auto') and (Port = 0));
  end;
  if FConsole <> nil then
    AttachDevices;
end;

procedure TDCWorker.SetPeripherals(const Value: TDCHostPeripherals);
begin
  FLock.Acquire;
  try
    FPeripherals := Value;
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.AddMouseDelta(DX, DY: Integer);
begin
  FLock.Acquire;
  try
    FMouseDX := EnsureRange(Int64(FMouseDX) + DX, -32768, 32767);
    FMouseDY := EnsureRange(Int64(FMouseDY) + DY, -32768, 32767);
  finally
    FLock.Release;
  end;
end;

procedure TDCWorker.SaveVMU(Port: Integer);
begin
  var VMU := FConsole.Maple.Devices[Port, 1];
  if (VMU is TDCVMU) and TDCVMU(VMU).Dirty and (FVMUFiles[Port] <> '') then
  begin
    FStorage.EnsureFolder(ExtractFilePath(FVMUFiles[Port]));
    FStorage.WriteBytes(FVMUFiles[Port], TDCVMU(VMU).Data);
    TDCVMU(VMU).Dirty := False;
  end;
end;

procedure TDCWorker.AttachDevices;
begin
  // A controller, keyboard, mouse or light gun per connected port; with a
  // controller, a VMU in its first socket on request and a jump pack in the
  // second socket of port A.
  for var Port := 0 to 3 do
  begin
    var Kind := FKinds[Port];
    if (Kind <> TDCPortKind.Pad) or not FWithVMU[Port] then
    begin
      SaveVMU(Port);
      FConsole.Maple.Attach(Port, 1, nil);
    end;
    if Kind <> TDCPortKind.Pad then
      for var U := 2 to 5 do
        FConsole.Maple.Attach(Port, U, nil);
    var Main := FConsole.Maple.Devices[Port, 0];
    case Kind of
      TDCPortKind.None:
        FConsole.Maple.Attach(Port, 0, nil);
      TDCPortKind.Keyboard:
        begin
          if not (Main is TDCKeyboard) then
            FConsole.Maple.Attach(Port, 0, TDCKeyboard.Create);
          TDCKeyboard(FConsole.Maple.Devices[Port, 0]).Region := FKeyboardRegion;
        end;
      TDCPortKind.Mouse:
        if not (Main is TDCMouse) then
          FConsole.Maple.Attach(Port, 0, TDCMouse.Create);
      TDCPortKind.LightGun:
        if not (Main is TDCLightGun) then
          FConsole.Maple.Attach(Port, 0, TDCLightGun.Create);
    end;
    if Kind <> TDCPortKind.Pad then
      Continue;
    if (Main = nil) or (Main.ClassType <> TDCController) then
      FConsole.Maple.Attach(Port, 0, TDCController.Create);
    if FWithVMU[Port] and (FVMUFiles[Port] <> '') and not (FConsole.Maple.Devices[Port, 1] is TDCVMU) then
    begin
      var VMU := TDCVMU.Create;
      try
        if FStorage.Exists(FVMUFiles[Port]) then
        begin
          var Image := FStorage.ReadBytes(FVMUFiles[Port]);
          if Length(Image) = Length(VMU.Data) then
            VMU.Data := Image;
        end;
        VMU.Dirty := False;
      except
        VMU.Free;
        raise;
      end;
      FConsole.Maple.Attach(Port, 1, VMU);
    end;
    if (Port = 0) and FRumbleEnabled and not (FConsole.Maple.Devices[Port, 2] is TDCPuruPuru) then
      FConsole.Maple.Attach(Port, 2, TDCPuruPuru.Create);
  end;
end;

procedure TDCWorker.SaveMemories;
begin
  if FConsole = nil then
    Exit;
  for var Port := 0 to 3 do
    SaveVMU(Port);
  if FConsole.Flash.S.Dirty and (FFlashSave <> '') then
  begin
    var Data: TBytes;
    SetLength(Data, DCFlashSize);
    Move(FConsole.Memory.Flash^, Data[0], DCFlashSize);
    FStorage.EnsureFolder(ExtractFilePath(FFlashSave));
    FStorage.WriteBytes(FFlashSave, Data);
    FConsole.Flash.S.Dirty := False;
  end;
end;

procedure TDCWorker.TransferSnapshot(const Name: string; Loading: Boolean);
begin
  var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
  var Console := FConsole;
  var Transfer: TStateTransfer :=
    procedure(State: TStateArchive)
    begin
      Console.SerializeState(State);
    end;
  if Loading then
  begin
    LoadCoreSnapshot(Path, ROM_CORE_ID_DC, FIdentity, Transfer, FStorage);
    Console.AICA.TakeSamples;
    ClearAudio;
    Publish;
  end
  else
  begin
    SaveCoreSnapshot(Path, ROM_CORE_ID_DC, FIdentity, Transfer, FStorage);
    SaveSnapshotPreview(Path, Console.PVR.FrameWidth, Console.PVR.FrameHeight, Console.PVR.FrameWidth,
      @Console.PVR.Frame[0], FStorage);
  end;
  Restart;
end;

procedure TDCWorker.StartMachine;
begin
  FConsole.InsertDisc(FDisc);
  AttachDevices;
  // A saved system flash keeps settings and game data between sessions.
  if (Length(FConfig.Flash) = 0) and (FFlashSave <> '') and FStorage.Exists(FFlashSave) then
  begin
    var Saved := FStorage.ReadBytes(FFlashSave);
    if Length(Saved) = DCFlashSize then
    begin
      Move(Saved[0], FConsole.Memory.Flash^, DCFlashSize);
      FConsole.Flash.Upgrade;
      FConsole.Flash.SetConfigTime(FConfig.RTCSeconds);
    end;
  end;
  // Without a disc (ejected) the high-level boot has nothing to start.
  if FConsole.HighLevelBoot then
  begin
    if FDisc <> nil then
      FConsole.BootDisc
    else if Length(FProgram) > 0 then
      FConsole.LoadProgram(FProgram);
  end;
end;

procedure TDCWorker.Execute;
begin
  FConsole := nil;
  FAudio := nil;
  FAudioFailed := False;
  var WasPaused := False;
  var WasEnabled := False;
  {$IFDEF MSWINDOWS}
  var TimerSet := timeBeginPeriod(1) = TIMERR_NOERROR;
  {$ENDIF}
  try
    try
      ApplyPorts(InputPorts);
      FConsole := TDCConsole.Create(FConfig);
      StartMachine;
      Restart;
      while not Terminated do
      begin
        FInputPortsCommand.Process(
          procedure(const Ports: TCoreInputPorts)
          begin
            ApplyPorts(Ports);
          end);
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            TransferSnapshot(Name, Loading);
          end);
        ProcessMediaChange;

        var Inputs: TDCPadInputs;
        var Paused, Enabled, ResetRequested, Recompiler: Boolean;
        var Volume: Single;
        var Host: TDCHostPeripherals;
        var MouseDX, MouseDY: Integer;
        FLock.Acquire;
        try
          Inputs := FInputs;
          Host := FPeripherals;
          MouseDX := FMouseDX;
          MouseDY := FMouseDY;
          FMouseDX := 0;
          FMouseDY := 0;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          Recompiler := FRecompiler;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;
        // (The same emulation either way: it may change at any time.)
        FConsole.CPU.Recompiler := Recompiler;

        if ResetRequested then
        begin
          SaveMemories;
          FConsole.Reset;
          StartMachine;
          FConsole.AICA.TakeSamples;
          ClearAudio;
          Restart;
        end;

        if Paused then
        begin
          if not WasPaused then
          begin
            SaveMemories;
            ClearAudio;
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Restart;
          Continue;
        end;
        WasPaused := False;

        if WasEnabled <> Enabled then
        begin
          if not Enabled then
            ClearAudio;
          Restart;
        end;
        WasEnabled := Enabled;

        // The audio queue is the real-time clock.
        if Enabled and not FAudioFailed and (FAudio <> nil) then
        try
          if not FAudio.CanAdvance then
          begin
            FWake.WaitFor(1);
            Continue;
          end;
        except
          on E: Exception do
            AudioFailure(E);
        end;

        for var Port := 0 to 3 do
        begin
          var Device := FConsole.Maple.Devices[Port, 0];
          if Device is TDCController then
            TDCController(Device).Pad := Inputs[Port];
          if Device is TDCLightGun then
          begin
            // The mouse aims and its buttons are the trigger, B and Start.
            var Gun := TDCLightGun(Device);
            Gun.X := Host.PointerX;
            Gun.Y := Host.PointerY;
            Gun.OnScreen := Host.PointerValid;
            if (Host.MouseButtons and 1) <> 0 then
              Gun.Pad.Buttons := Gun.Pad.Buttons or MapleA;
            if (Host.MouseButtons and 2) <> 0 then
              Gun.Pad.Buttons := Gun.Pad.Buttons or MapleB;
            if (Host.MouseButtons and 4) <> 0 then
              Gun.Pad.Buttons := Gun.Pad.Buttons or MapleStart;
          end
          else if Device is TDCKeyboard then
          begin
            var Kbd := TDCKeyboard(Device);
            Move(Host.Keys, Kbd.Keys, SizeOf(Kbd.Keys));
            Kbd.Modifiers := Host.Modifiers;
          end
          else if Device is TDCMouse then
          begin
            var Mouse := TDCMouse(Device);
            // Movement the program does not read yet stays (within bounds).
            Mouse.DX := EnsureRange(Mouse.DX + MouseDX, -4096, 4096);
            Mouse.DY := EnsureRange(Mouse.DY + MouseDY, -4096, 4096);
            Mouse.Buttons := 0;
            if (Host.MouseButtons and 1) <> 0 then
              Mouse.Buttons := Mouse.Buttons or MapleMouseLeft;
            if (Host.MouseButtons and 2) <> 0 then
              Mouse.Buttons := Mouse.Buttons or MapleMouseRight;
            if (Host.MouseButtons and 4) <> 0 then
              Mouse.Buttons := Mouse.Buttons or MapleMouseSide;
          end;
        end;
        FConsole.RunFrame;
        if FConsole.Halted then
        begin
          ReportError('Dreamcast: the program returned to the system menu');
          Break;
        end;
        if Terminated then
          Break;

        var Samples := FConsole.AICA.TakeSamples;
        if Enabled and not FAudioFailed then
        try
          if FAudio = nil then
            FAudio := TDCAudioPlayback.Create;
          FAudio.Enqueue(Samples, Volume);
        except
          on E: Exception do
            AudioFailure(E);
        end;
        Publish;

        if not Enabled or FAudioFailed then
        begin
          var Target := FDeadline + (FConsole.Scheduler.Now - FClockGuest) * (TStopwatch.Frequency / DCCPUClock);
          var Remaining := (Target - TStopwatch.GetTimeStamp) * 1000 / TStopwatch.Frequency;
          if Remaining > 0 then
            FWake.WaitFor(Min(100, Ceil(Remaining)))
          else if Remaining < -250 then
          begin
            FDeadline := TStopwatch.GetTimeStamp;
            FClockGuest := FConsole.Scheduler.Now;
          end;
        end;
      end;
    except
      on E: Exception do
        ReportError('Dreamcast: ' + E.Message);
    end;
    try
      SaveMemories;
    except
      on E: Exception do
        ReportError('Dreamcast memory card: ' + E.Message);
    end;
  finally
    FreeAndNil(FAudio);
    FreeAndNil(FConsole);
    {$IFDEF MSWINDOWS}
    if TimerSet then
      timeEndPeriod(1);
    {$ENDIF}
  end;
end;

{ TDCCoreAdapter }

class function TDCCoreAdapter.IsDCDisc(Disc: TCDDisc): Boolean;
begin
  Result := IsDreamcastDisc(Disc);
end;

// Seconds since 1950-01-01 (the AICA RTC epoch).
function DCSeconds(Value: TDateTime): Cardinal;
begin
  Result := Cardinal(Max(Int64(0), SecondsBetween(Value, EncodeDate(1950, 1, 1))));
end;

constructor TDCCoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc);
begin
  inherited Create;
  FDisc := OwnedDisc;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FConfigObject := TDCConfig.Create(FStorage.ConfigFile(ROM_SYSTEM_DC), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FDiscIndex := -1;
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  var Playlist := (FDisc = nil) and SameText(ExtractFileExt(SourceName), ROM_EXTENSION_M3U);
  if Playlist then
  begin
    FDiscLocations := ReadCDPlaylist(Stream, FStorage, RomName, ROM_SYSTEM_DC);
    SetLength(FDiscNames, Length(FDiscLocations));
    for var I := 0 to High(FDiscLocations) do
      FDiscNames[I] := FStorage.Describe(FDiscLocations[I]).Name;
    var DiscStream := FStorage.OpenRead(FDiscLocations[0]);
    try
      FDisc := TCDDisc.Create(DiscStream, FStorage, FDiscLocations[0]);
      if not IsDCDisc(FDisc) then
        raise EReadError.Create('M3U disc is not a Dreamcast image: ' + FDiscNames[0]);
    finally
      DiscStream.Free;
    end;
  end
  else if FDisc <> nil then
  begin
    FDiscLocations := TArray<string>.Create(RomName);
    FDiscNames := TArray<string>.Create(ExtractFileName(SourceName.Replace('/', PathDelim)));
  end;
  if FDisc <> nil then
    FDiscIndex := 0;
  if FDisc = nil then
  begin
    var Size := Stream.Size - Stream.Position;
    if (Size < 16) or (Size > DCRAMSize) then
      raise EReadError.Create('Dreamcast program must fit in 16 MiB');
    SetLength(FProgram, Size);
    Stream.ReadBuffer(FProgram[0], Size);
    FIdentity := Copy(FProgram);
  end
  else
    FIdentity := FDisc.Identity;

  FMachine := Default(TDCConsoleConfig);
  // Region: setting, else the disc's area symbols (IP.BIN 30h: J, U, E).
  var Areas := 'JUE';
  if FDisc <> nil then
  begin
    var Wrapper := TDCDisc.Create(FDisc);
    try
      var Sector := Wrapper.ReadBootSector(0);
      Areas := TEncoding.ANSI.GetString(Sector, $30, 8).ToUpper;
    finally
      Wrapper.Free;
    end;
  end;
  if FConfigObject.Region = 'japan' then
    FMachine.Region := TDCRegion.Japan
  else if FConfigObject.Region = 'usa' then
    FMachine.Region := TDCRegion.USA
  else if FConfigObject.Region = 'europe' then
    FMachine.Region := TDCRegion.Europe
  else if Areas.Contains('U') then
    FMachine.Region := TDCRegion.USA
  else if Areas.Contains('E') then
    FMachine.Region := TDCRegion.Europe
  else
    FMachine.Region := TDCRegion.Japan;
  if FConfigObject.Video = 'pal' then
    FMachine.PAL := True
  else if FConfigObject.Video = 'ntsc' then
    FMachine.PAL := False
  else
    FMachine.PAL := FMachine.Region = TDCRegion.Europe;
  if FConfigObject.Cable = 'vga' then
  begin
    FMachine.Cable := TDCCable.VGA;
    FMachine.PAL := False;
  end
  else if FConfigObject.Cable = 'rgb' then
    FMachine.Cable := TDCCable.RGB
  else
    FMachine.Cable := TDCCable.Composite;
  var Languages: array of string := ['japanese', 'english', 'german', 'french', 'spanish', 'italian'];
  for var I := 0 to High(Languages) do
    if FConfigObject.Language = Languages[I] then
      FMachine.Language := TDCLanguage(I);
  FMachine.RTCSeconds := DCSeconds(Now);
  LoadFirmware(RomName);

  var Identity := SnapshotIdentity(FIdentity);
  // A playlist owns a stable snapshot namespace, independent of the inserted
  // disc; snapshot headers still carry the inserted disc's identity.
  if Playlist then
    Identity := SnapshotIdentity(TEncoding.UTF8.GetBytes('DC M3U/' + ExtractFileName(SourceName) + '/' + Identity));
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_DC, RomName, Identity);
  // Visual Memory units and the system flash belong to the console, not a game.
  var Folder := TPath.Combine(FStorage.SaveRoot, ROM_SYSTEM_DC);
  for var Port := 0 to 3 do
    FVMUFiles[Port] := TPath.Combine(Folder, Format('vmu_%s1.bin', [Chr(Ord('A') + Port)]));
  FFlashSave := TPath.Combine(Folder, 'dc_flash.bin');
end;

destructor TDCCoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;
  inherited;
end;

function TDCCoreAdapter.GetDiscCount: Integer;
begin
  Result := Length(FDiscLocations);
end;

function TDCCoreAdapter.GetDiscName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= Length(FDiscNames)) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  Result := FDiscNames[Index];
end;

function TDCCoreAdapter.GetDiscIndex: Integer;
begin
  Result := FDiscIndex;
end;

procedure TDCCoreAdapter.WaitDiscTask;
begin
  if FDiscTask <> nil then
  begin
    FDiscTask.Wait;
    FDiscTask := nil;
  end;
end;

procedure TDCCoreAdapter.ReplaceDisc(const Location: string; Index: Integer);
begin
  WaitDiscTask;
  // The image is checked here; reading all of it for its identity (seconds
  // for a large image) happens on a task while the lid stays open, as a
  // player swapping discs takes a moment.
  var Stream := FStorage.OpenRead(Location);
  var Disc: TCDDisc := nil;
  try
    Disc := TCDDisc.Create(Stream, FStorage, Location, FWorker <> nil);
    if not IsDCDisc(Disc) then
      raise EReadError.Create('Not a Dreamcast disc: ' + FStorage.Describe(Location).Name);
  except
    Disc.Free;
    Stream.Free;
    raise;
  end;
  Stream.Free;
  if FWorker = nil then
  begin
    FDisc.Free;
    FDisc := Disc;
    FIdentity := Disc.Identity;
    FDiscIndex := Index;
    Exit;
  end;
  try
    FWorker.ChangeDisc(nil, nil);
  except
    Disc.Free;
    raise;
  end;
  // The worker has let go of the previous disc.
  FDisc.Free;
  FDisc := Disc;
  FIdentity := nil;
  FDiscIndex := Index;
  var Worker := FWorker;
  FDiscTask := TTask.Run(
    procedure
    begin
      // A disc that cannot be read to the end stays out (no disc selected).
      try
        var Identity := Disc.Identity;
        Worker.ChangeDisc(Disc, Identity);
        FIdentity := Identity;
      except
        FDiscIndex := -1;
      end;
    end);
end;

procedure TDCCoreAdapter.ChangeDisc(Index: Integer);
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  if Index = FDiscIndex then
    Exit;
  ReplaceDisc(FDiscLocations[Index], Index);
end;

procedure TDCCoreAdapter.OpenDisc(const Location: string);
begin
  if GetDiscCount = 0 then
    raise EInvalidOpException.Create('This Dreamcast session runs a program, not a disc');
  for var I := 0 to High(FDiscLocations) do
    if FDiscLocations[I] = Location then
    begin
      ChangeDisc(I);
      Exit;
    end;
  // A failed load leaves the running session and the disc list unchanged.
  var Index := Length(FDiscLocations);
  var Locations := FDiscLocations + TArray<string>.Create(Location);
  var Names := FDiscNames + TArray<string>.Create(FStorage.Describe(Location).Name);
  ReplaceDisc(Location, Index);
  FDiscLocations := Locations;
  FDiscNames := Names;
end;

procedure TDCCoreAdapter.EjectDisc;
begin
  WaitDiscTask;
  if (GetDiscCount = 0) or (FDiscIndex < 0) then
    Exit;
  if FWorker <> nil then
    FWorker.ChangeDisc(nil, nil);
  FreeAndNil(FDisc);
  FDiscIndex := -1;
  FIdentity := nil;
end;

procedure TDCCoreAdapter.LoadFirmware(const RomName: string);
begin
  // External boot ROM: setting, else dc_boot.bin beside the image or in the
  // dc ROM folder. The high-level boot is used without one, or by choice;
  // in automatic mode and for programs a found boot ROM only lends its font.
  if FConfigObject.BIOSMode = 'hle' then
    Exit;
  FMachine.HLEBoot := (FConfigObject.BIOSMode = 'auto') or (FDisc = nil);
  var Path := FConfigObject.BIOSFile;
  var FlashPath := FConfigObject.FlashFile;
  if Path = '' then
    for var Folder in [ExtractFilePath(RomName), FStorage.RomFolder(ROM_SYSTEM_DC)] do
    begin
      if (Folder = '') or Folder.StartsWith('content://', True) then
        Continue;
      var Candidate := TPath.Combine(Folder, 'dc_boot.bin');
      if FStorage.Exists(Candidate) then
      begin
        Path := Candidate;
        if FlashPath = '' then
        begin
          var Flash := TPath.Combine(Folder, 'dc_flash.bin');
          if FStorage.Exists(Flash) then
            FlashPath := Flash;
        end;
        Break;
      end;
    end;
  if Path = '' then
  begin
    if FConfigObject.BIOSMode = 'external' then
      raise EReadError.Create('Select a Dreamcast boot ROM (dc_boot.bin) in Dreamcast settings');
    Exit;
  end;
  FMachine.BootROM := FStorage.ReadBytes(Path);
  if Length(FMachine.BootROM) <> DCBootSize then
    raise EReadError.CreateFmt('Dreamcast boot ROM must contain exactly 2 MiB: %s', [Path]);
  if FlashPath <> '' then
  begin
    FMachine.Flash := FStorage.ReadBytes(FlashPath);
    if Length(FMachine.Flash) <> DCFlashSize then
      raise EReadError.CreateFmt('Dreamcast flash ROM must contain exactly 128 KiB: %s', [FlashPath]);
  end;
end;

procedure TDCCoreAdapter.Configure;
begin
  if FWorker = nil then
    Exit;
  var Input := GetInputState;
  var Inputs: TDCPadInputs;
  for var Port := 0 to 3 do
  begin
    var Buttons: TEmulatorButtons;
    case Port of
      0:
        Buttons := Input.Buttons;
      1:
        Buttons := Input.Buttons2;
      2:
        Buttons := Input.Buttons3;
    else
      Buttons := Input.Buttons4;
    end;
    var Pad := Default(TDCPad);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      if B in Buttons then
        Pad.Buttons := Pad.Buttons or ButtonBits[B];
    var Keys := FKeyboardExtra[Port];
    var Host := FControllers[Port];
    var X := Integer(Host.StickX);
    var Y := Integer(Host.StickY);
    var LT := Integer(Host.LeftTrigger);
    var RT := Integer(Host.RightTrigger);
    if Input.Analog[Port].Valid then
    begin
      Inc(X, Input.Analog[Port].X);
      Inc(Y, Input.Analog[Port].Y);
      LT := Max(LT, Input.Analog[Port].LeftTrigger);
      RT := Max(RT, Input.Analog[Port].RightTrigger);
    end;
    X := X + 32767 * (Ord(Keys[TDCExtra.StickRight]) - Ord(Keys[TDCExtra.StickLeft]));
    Y := Y + 32767 * (Ord(Keys[TDCExtra.StickDown]) - Ord(Keys[TDCExtra.StickUp]));
    // Select and Mode are the triggers: keys press them fully, while host
    // bindings and the on-screen pad report their travel above.
    var KeyButtons: TEmulatorButtons;
    case Port of
      0:
        KeyButtons := FKeyboard.Buttons;
      1:
        KeyButtons := FKeyboard.Buttons2;
      2:
        KeyButtons := FKeyboard.Buttons3;
    else
      KeyButtons := FKeyboard.Buttons4;
    end;
    if TEmulatorButton.Select in KeyButtons then
      LT := 255;
    if TEmulatorButton.Mode in KeyButtons then
      RT := 255;
    Pad.StickX := StickByte(X);
    Pad.StickY := StickByte(Y);
    Pad.LeftTrigger := Byte(EnsureRange(LT, 0, 255));
    Pad.RightTrigger := Byte(EnsureRange(RT, 0, 255));
    Inputs[Port] := Pad;
  end;
  FWorker.Configure(Inputs, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FConfigObject.Recompiler);
end;

procedure TDCCoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  FWorker := TDCWorker.Create(FMachine, FProgram, FIdentity, FDisc, FStorage, FVMUFiles, FFlashSave,
    FSnapshotDirectory, FConfigObject.Rumble);
  FPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_DC);
  FWorker.InputPorts := FPorts;
  Configure;
  PushPeripherals;
  FWorker.Start;
end;

procedure TDCCoreAdapter.Stop;
begin
  WaitDiscTask;
  if FWorker = nil then
    Exit;
  FWorker.StopAndSave;
  FError := FWorker.TakeError(False);
  FreeAndNil(FWorker);
end;

procedure TDCCoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TDCCoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TDCCoreAdapter.Reset;
begin
  FPaused := False;
  if FWorker <> nil then
    FWorker.RequestReset;
  Configure;
end;

procedure TDCCoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FWorker <> nil then
    FWorker.InputPorts := Ports;
  FPorts := Ports;
end;

procedure TDCCoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  FillChar(FKeyboardExtra, SizeOf(FKeyboardExtra), 0);
  FillChar(FControllers, SizeOf(FControllers), 0);
  FHostKeys := nil;
  FModifiers := 0;
  FillChar(FScreenKeys, SizeOf(FScreenKeys), 0);
  FPeripherals.MouseButtons := 0;
  PushPeripherals;
  Configure;
end;

function TDCCoreAdapter.PortHolds(Device: string): Boolean;
begin
  Result := False;
  for var Port := 0 to 3 do
    if FPorts.Devices[Port] = Device then
      Exit(True);
end;

procedure TDCCoreAdapter.PushPeripherals;
begin
  FillChar(FPeripherals.Keys, SizeOf(FPeripherals.Keys), 0);
  for var I := 0 to Min(High(FHostKeys), 5) do
    FPeripherals.Keys[I] := FHostKeys[I];
  FPeripherals.Modifiers := FModifiers;
  if FWorker <> nil then
    FWorker.SetPeripherals(FPeripherals);
end;

procedure TDCCoreAdapter.HostKey(Code: UInt32; Pressed: Boolean);
begin
  var Modifier := DCHostKeyModifier(Code);
  if Modifier <> 0 then
  begin
    if Pressed then
      FModifiers := FModifiers or Modifier
    else
      FModifiers := FModifiers and not Modifier;
  end
  else
  begin
    var HID := DCHostKeyToHID(Code);
    if HID = 0 then
      Exit;
    var Index := -1;
    for var I := 0 to High(FHostKeys) do
      if FHostKeys[I] = HID then
        Index := I;
    if Pressed and (Index < 0) then
      FHostKeys := FHostKeys + [HID]
    else if not Pressed and (Index >= 0) then
      Delete(FHostKeys, Index, 1);
  end;
  PushPeripherals;
end;

procedure TDCCoreAdapter.SetScreenKeys(const Keys: THostKeyboardKeys);
begin
  for var Code := 0 to 255 do
    if Keys[Code] <> FScreenKeys[Code] then
    begin
      FScreenKeys[Code] := Keys[Code];
      HostKey(Code, Keys[Code]);
    end;
end;

function TDCCoreAdapter.GetHasKeyboard: Boolean;
begin
  Result := PortHolds('keyboard');
end;

procedure TDCCoreAdapter.SendMouseDelta(DX, DY: Integer; Buttons: Byte);
begin
  if FPeripherals.MouseButtons <> Buttons then
  begin
    FPeripherals.MouseButtons := Buttons;
    PushPeripherals;
  end;
  if (FWorker <> nil) and ((DX <> 0) or (DY <> 0)) and PortHolds('mouse') then
    FWorker.AddMouseDelta(DX, DY);
end;

function TDCCoreAdapter.GetUsesPointer: Boolean;
begin
  Result := PortHolds('lightgun');
end;

procedure TDCCoreAdapter.SetPointer(X, Y: Integer; Valid: Boolean);
begin
  if (FPeripherals.PointerX = X) and (FPeripherals.PointerY = Y) and (FPeripherals.PointerValid = Valid) then
    Exit;
  FPeripherals.PointerX := X;
  FPeripherals.PointerY := Y;
  FPeripherals.PointerValid := Valid;
  PushPeripherals;
end;

procedure TDCCoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;
  // With a keyboard connected the host keys type on it.
  if GetHasKeyboard then
  begin
    HostKey(Code, Pressed);
    Exit;
  end;
  for var Port := 0 to 3 do
  begin
    for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      if Code = FConfigObject.Keys[Port, Button] then
        case Port of
          0:
            if Pressed then
              Include(FKeyboard.Buttons, Button)
            else
              Exclude(FKeyboard.Buttons, Button);
          1:
            if Pressed then
              Include(FKeyboard.Buttons2, Button)
            else
              Exclude(FKeyboard.Buttons2, Button);
          2:
            if Pressed then
              Include(FKeyboard.Buttons3, Button)
            else
              Exclude(FKeyboard.Buttons3, Button);
        else
          if Pressed then
            Include(FKeyboard.Buttons4, Button)
          else
            Exclude(FKeyboard.Buttons4, Button);
        end;
    for var Extra := Low(TDCExtra) to High(TDCExtra) do
      if Code = FConfigObject.ExtraKey(Port, Extra) then
        FKeyboardExtra[Port, Extra] := Pressed;
  end;
  Configure;
end;

procedure TDCCoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  Configure;
end;

procedure TDCCoreAdapter.SetDCController(Port: Integer; const Pad: TDCAnalogPad);
begin
  if (Port < 0) or (Port > 3) then
    Exit;
  FControllers[Port] := Pad;
  Configure;
end;

function TDCCoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
  Result.Buttons3 := FKeyboard.Buttons3 + FGamepad.Buttons3;
  Result.Buttons4 := FKeyboard.Buttons4 + FGamepad.Buttons4;
end;

function TDCCoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TDCCoreAdapter.SaveSnapshot(const Name: string);
begin
  // A snapshot records the inserted disc: let a pending change finish.
  WaitDiscTask;
  if FWorker <> nil then
    FWorker.Snapshot(Name, False);
end;

procedure TDCCoreAdapter.LoadSnapshot(const Name: string);
begin
  WaitDiscTask;
  if FWorker <> nil then
    FWorker.Snapshot(Name, True);
end;

function TDCCoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TDCCoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError(False);
end;

function TDCCoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FWorker <> nil then
    Result := FWorker.TakeError(True);
end;

function TDCCoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TDCCoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_DC;
end;

function TDCCoreAdapter.GetName: string;
begin
  Result := 'Dreamcast';
end;

function TDCCoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TDCCoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TDCCoreAdapter.InsertCoin1;
begin
end;

procedure TDCCoreAdapter.InsertCoin2;
begin
end;

function TDCCoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TDCCoreAdapter.GetHasRumble: Boolean;
begin
  Result := FConfigObject.Rumble and (FPorts.Devices[0] <> 'none');
end;

function TDCCoreAdapter.GetRumbleLevel: Byte;
begin
  Result := 0;
  if GetHasRumble and not FPaused and (FWorker <> nil) then
    Result := FWorker.RumbleLevel;
end;

function TDCCoreAdapter.TakeVMUScreen(out Pixels: TBytes): Boolean;
begin
  Pixels := nil;
  Result := (FWorker <> nil) and FConfigObject.ShowVMU and FWorker.TakeVMUScreen(Pixels);
end;

function TDCCoreAdapter.VMUScreenCorner: string;
begin
  Result := FConfigObject.VMUScreen;
  if not FConfigObject.ShowVMU then
    Result := 'off';
end;

end.

