unit Core.Platforms.PS2.Adapter;

// PlayStation 2 front-end adapter: disc images (DVD/CD through
// Core.DVD.Image) and homebrew ELF programs, a worker thread running fields,
// frame publishing, SPU2 sound (the audio queue paces the emulation; by time
// with sound off), snapshots and the controller state for DualShock 2.

interface

uses
  Core.InputConfig, System.SysUtils, System.Classes, System.IniFiles, System.SyncObjs, Core.Storage, Core.Emulation,
  Core.Snapshots, Core.CD.Disc, Core.DVD.Image, PS2.Types, PS2.Console, PS2.IOP.CDVD, Core.Platforms.PS2.Playback;

{$SCOPEDENUMS ON}

type
  TPS2KeyMap = array[0..1, TEmulatorButton] of UInt32;

  // Controller inputs beyond the logical pad; frontends number their actions
  // in this order.
  TPS2Extra = (L2, L3, R3, Analog, LeftUp, LeftDown, LeftLeft, LeftRight, RightUp, RightDown, RightLeft,
    RightRight);

  TPS2ExtraKeyMap = array[0..1, TPS2Extra] of UInt32;

  TPS2Config = class(TEmulatorConfigBase)
  private
    FKeys: TPS2KeyMap;
    FExtraKeys: TPS2ExtraKeyMap;
    FBIOSMode, FBIOSFile, FRegion, FVideo, FLanguage, FRenderer: string;
    FRecompiler: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    class function ExtraKeyName(Extra: TPS2Extra): string; static;
    function ExtraKey(Port: Integer; Extra: TPS2Extra): UInt32;
    // 'hle' (default), 'auto' or 'external' (Hardware/BIOSMode).
    property BIOSMode: string read FBIOSMode write FBIOSMode;
    property BIOSFile: string read FBIOSFile write FBIOSFile;
    // 'auto' (from the disc), 'japan', 'usa' or 'europe'.
    property Region: string read FRegion write FRegion;
    // 'auto' (from SYSTEM.CNF), 'ntsc' or 'pal'.
    property Video: string read FVideo write FVideo;
    // 'auto' (by region), 'japanese', 'english', 'french', 'spanish',
    // 'german', 'italian', 'dutch', 'portuguese' or 'russian'.
    property Language: string read FLanguage write FLanguage;
    function ConsoleLanguage: TPS2Language;
    // GS drawing (Video/Renderer): 'threads' (default: band threads beside
    // the emulation), 'single' (on the emulation thread), or experimental
    // 'vulkan' (Vulkan LLE, also read as 'vulkan-lle': supported
    // sprites/triangle pixels on the GPU, bit exact, other draws on the band
    // threads), or experimental 'vulkan-hle' (Vulkan HLE: every primitive on the
    // GPU's own pipelines, fast but not bit exact, on the emulation thread).
    // But for 'single' and 'vulkan-hle' the GS front end runs on a thread
    // of its own (TPS2GSRaster.Async) on hosts with four logical processors.
    property Renderer: string read FRenderer write FRenderer;
    property Recompiler: Boolean read FRecompiler write FRecompiler;
    // Band threads for Renderer (0: none; Vulkan's CPU fallbacks use them
    // too), and whether the GS draws on a thread of its own (not 'single').
    function GSThreads: Integer;
    function GSAsync: Boolean;
    property Keys: TPS2KeyMap read FKeys;
  end;

  // A DualShock 2 as the worker sees it: digital buttons (active high, in
  // the PS2 pad bit order), stick bytes (80h centre) and pressure.
  TPS2PadInput = record
    Buttons: Word;
    Axes: array[0..3] of Byte;
    Pressure: array[0..11] of Byte;
  end;

  TPS2PadInputs = array[0..1] of TPS2PadInput;

  // Controller inputs a frontend supplies beyond the logical pad.
  TPS2Pad = record
    Buttons: Word;
    AnalogButton: Boolean;
    LeftX, LeftY, RightX, RightY: SmallInt;
  end;

  IPS2ControllerInput = interface
    ['{9C7A3D2E-51B4-4E8A-9F3C-2A6D7E1B4C58}']
    procedure SetPS2Controller(Port: Integer; const Pad: TPS2Pad);
  end;

  TPS2Worker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FStorage: IStorage;
    FProgram, FIdentity: TBytes;
    FProgramName: string;
    // The console to build: video, region, language, disc (owned by the
    // adapter), BIOS.
    FBase: TPS2ConsoleConfig;
    FSnapshotDirectory, FError: string;
    FCardFiles: array[0..1] of string;
    FInputs: TPS2PadInputs;
    FPause, FReset, FAvailable, FAudioEnabled: Boolean;
    FVolume: Single;
    FGSThreads: Integer;
    FGSAsync: Boolean;
    FRecompiler: Boolean;
    FVulkan, FHLE: Boolean;
    FAudio: TPS2AudioPlayback;
    FAudioFailed: Boolean;
    FAudioError: string;
    FFrame: TEmulatorFrame;
    FConsole: TPS2Console;
    FRate: TEmulationFrameRate;
    FDeadline: Double;
    FClockGuest: Int64;
    procedure ReportError(const Text: string);
    procedure AudioFailure(E: Exception);
    procedure ClearAudio;
    procedure Restart;
    procedure Boot;
    procedure TransferSnapshot(const Name: string; Loading: Boolean);
    procedure Publish(Console: TPS2Console);
    procedure PublishPixels(const Source: TArray<Cardinal>; Width, Height: Integer; Number: Int64);
    procedure LoadCards;
    procedure SaveCards;
    procedure SaveNVM;
  protected
    procedure Execute; override;
  public
    // Where the console's EEPROM is saved (BIOS boot).
    NVMFile: string;
    constructor Create(const ProgramData, Identity: TBytes; const ProgramName: string; const Base: TPS2ConsoleConfig;
      const Storage: IStorage; const SnapshotDirectory, CardFile1, CardFile2: string);
    destructor Destroy; override;
    procedure Configure(const Inputs: TPS2PadInputs; Paused, AudioEnabled: Boolean; Volume: Single; GSThreads: Integer;
      GSAsync, Recompiler, Vulkan, HLE: Boolean);
    procedure RequestReset;
    procedure StopAndSave;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError(Audio: Boolean = False): string;
    procedure Snapshot(const Name: string; Loading: Boolean);
  end;

  TPS2CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationSnapshotLocation, IPS2ControllerInput,
    IEmulationAudioDiagnostics)
  private
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TPS2Config;
    FWorker: TPS2Worker;
    FDisc: TDVDImage;
    FProgram, FIdentity: TBytes;
    FProgramName: string;
    FRegion: TPS2Region;
    FPAL: Boolean;
    FKeyboard, FGamepad: TEmulatorInput;
    FKeyboardExtra: array[0..1, TPS2Extra] of Boolean;
    FControllers: array[0..1] of TPS2Pad;
    FPaused: Boolean;
    FSnapshotDirectory, FError: string;
    FCardFiles: array[0..1] of string;
    // BIOS boot: the image, its console's MECHACON version and EEPROM, and
    // where the EEPROM is kept.
    FBIOS, FMechacon, FNVM: TBytes;
    FNVMFile: string;
    procedure Configure;
    procedure SelectBIOS(const RomName: string);
    function FindBIOS(const RomName: string): string;
  public
    // Disc images are opened from the stream and RomName (owned); otherwise
    // Stream holds a PS2 ELF program.
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; Disc: TDVDImage = nil);
    destructor Destroy; override;
    // A PS2 disc: SYSTEM.CNF with BOOT2.
    class function IsPS2Disc(Disc: TDVDImage): Boolean; static;
    // A MIPS EE executable (ELF, machine 8, entry in EE RAM).
    class function IsPS2ELF(const Data: TBytes): Boolean; static;
    // A PlayStation 2 game on CD (BOOT2 in SYSTEM.CNF; PS1 discs use BOOT).
    class function IsPS2CD(Disc: TCDDisc): Boolean; static;
    // For the emulator factory, before CD detection: PS2 ELF programs, ISO,
    // MDS and DVD CHD images of PS2 discs (any size). nil otherwise; Stream
    // stays the caller's and is rewound.
    class function TryCreate(Stream: TStream; const Storage: IStorage; const RomName, SourceName: string): IEmulationCore; static;
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
    procedure SetPS2Controller(Port: Integer; const Pad: TPS2Pad);
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

const
  // DualShock 2 digital bits (active high here; the pad protocol inverts).
  PS2PadSelect = $0001;
  PS2PadL3 = $0002;
  PS2PadR3 = $0004;
  PS2PadStart = $0008;
  PS2PadUp = $0010;
  PS2PadRight = $0020;
  PS2PadDown = $0040;
  PS2PadLeft = $0080;
  PS2PadL2 = $0100;
  PS2PadR2 = $0200;
  PS2PadL1 = $0400;
  PS2PadR1 = $0800;
  PS2PadTriangle = $1000;
  PS2PadCircle = $2000;
  PS2PadCross = $4000;
  PS2PadSquare = $8000;

implementation

uses
  {$IFDEF MSWINDOWS}Winapi.MMSystem,{$ENDIF}
  System.Math, System.Diagnostics, System.UITypes, System.Hash, System.IOUtils, RM.Platforms.PS2, Core.SavePaths,
  System.Generics.Collections, PS2.ELF, PS2.IOP.MemoryCard, PS2.BIOS;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'Cross', 'Circle', 'Select', 'Start', 'L1', 'Square', 'Triangle', 'R1', 'R2');
  DefaultKeys: array[0..1, TEmulatorButton] of UInt32 = (
    (vkUp, vkDown, vkLeft, vkRight, vkX, vkC, vkSpace, vkReturn, vkQ, vkZ, vkS, vkE, vkR),
    (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad2, vkNumpad3, 0, vkNumpad0, 0, vkNumpad1, vkNumpad7, 0, 0));
  ButtonBits: array[TEmulatorButton] of Word = (PS2PadUp, PS2PadDown, PS2PadLeft, PS2PadRight, PS2PadCross,
    PS2PadCircle, PS2PadSelect, PS2PadStart, PS2PadL1, PS2PadSquare, PS2PadTriangle, PS2PadR1, PS2PadR2);
  ExtraKeyNames: array[TPS2Extra] of string = ('L2', 'L3', 'R3', 'Analog', 'LeftStickUp', 'LeftStickDown',
    'LeftStickLeft', 'LeftStickRight', 'RightStickUp', 'RightStickDown', 'RightStickLeft', 'RightStickRight');
  DefaultExtraKeys: array[TPS2Extra] of UInt32 = (vkW, 0, 0, vkA, vkT, vkG, vkF, vkH, vkI, vkK, vkJ, vkL);

function PadBits(const Buttons: TEmulatorButtons): Word;
begin
  Result := 0;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if B in Buttons then
      Result := Result or ButtonBits[B];
end;

function StickByte(Value: Integer): Byte;
begin
  Result := EnsureRange(128 + EnsureRange(Value, -32768, 32767) div 256, 0, 255);
end;

{ TPS2Config }

constructor TPS2Config.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  FKeys := TPS2KeyMap(DefaultKeys);
  for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
  begin
    FExtraKeys[0, Extra] := DefaultExtraKeys[Extra];
    FExtraKeys[1, Extra] := 0;
  end;
  FBIOSMode := 'hle';
  FRegion := 'auto';
  FVideo := 'auto';
  FLanguage := 'auto';
  FRenderer := 'threads';
end;

function TPS2Config.GSThreads: Integer;
begin
  Result := 0;
  // One per two logical processors (the emulation keeps one), 2..8.
  if (FRenderer <> 'single') and (FRenderer <> 'vulkan-hle') then
    Result := EnsureRange(TThread.ProcessorCount div 2, 2, 8);
end;

function TPS2Config.GSAsync: Boolean;
begin
  Result := (FRenderer <> 'single') and (FRenderer <> 'vulkan-hle') and (TThread.ProcessorCount >= 4);
end;

function TPS2Config.ConsoleLanguage: TPS2Language;
const
  Names: array[TPS2Language] of string = ('auto', 'japanese', 'english', 'french', 'spanish', 'german', 'italian',
    'dutch', 'portuguese', 'russian');
begin
  for var L := Low(TPS2Language) to High(TPS2Language) do
    if FLanguage = Names[L] then
      Exit(L);
  Result := TPS2Language.Auto;
end;

class function TPS2Config.ExtraKeyName(Extra: TPS2Extra): string;
begin
  Result := ExtraKeyNames[Extra];
end;

function TPS2Config.ExtraKey(Port: Integer; Extra: TPS2Extra): UInt32;
begin
  Result := FExtraKeys[Port, Extra];
end;

procedure TPS2Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSMode := Ini.ReadString('Hardware', 'BIOSMode', 'hle').ToLower;
  if (FBIOSMode <> 'auto') and (FBIOSMode <> 'external') then
    FBIOSMode := 'hle';
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FRegion := Ini.ReadString('System', 'Region', 'auto').ToLower;
  FVideo := Ini.ReadString('System', 'Video', 'auto').ToLower;
  if (FVideo <> 'ntsc') and (FVideo <> 'pal') then
    FVideo := 'auto';
  FLanguage := Ini.ReadString('System', 'Language', 'auto').ToLower;
  FRenderer := Ini.ReadString('Video', 'Renderer', 'threads').ToLower;
  FRecompiler := SameText(Ini.ReadString('Emulation', 'Execution', 'interpreter'), 'jit');
  if FRenderer = 'vulkan-lle' then
    FRenderer := 'vulkan';
  if (FRenderer <> 'single') and (FRenderer <> 'vulkan') and (FRenderer <> 'vulkan-hle') then
    FRenderer := 'threads';
  for var P := 0 to 1 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      FKeys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
      FExtraKeys[P, Extra] := ReadEmulatorKey(Ini, Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

procedure TPS2Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOSMode', FBIOSMode);
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteString('System', 'Region', FRegion);
  Ini.WriteString('System', 'Video', FVideo);
  Ini.WriteString('System', 'Language', FLanguage);
  Ini.WriteString('Video', 'Renderer', FRenderer);
  if FRecompiler then
    Ini.WriteString('Emulation', 'Execution', 'jit')
  else
    Ini.WriteString('Emulation', 'Execution', 'interpreter');
  for var P := 0 to 1 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
      Ini.WriteInteger(Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

{ TPS2Worker }

constructor TPS2Worker.Create(const ProgramData, Identity: TBytes; const ProgramName: string;
  const Base: TPS2ConsoleConfig; const Storage: IStorage; const SnapshotDirectory, CardFile1, CardFile2: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FProgram := Copy(ProgramData);
  FIdentity := Copy(Identity);
  FProgramName := ProgramName;
  FBase := Base;
  FStorage := Storage;
  FSnapshotDirectory := SnapshotDirectory;
  FCardFiles[0] := CardFile1;
  FCardFiles[1] := CardFile2;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
end;

destructor TPS2Worker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  inherited;
  FSnapshots.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TPS2Worker.Configure(const Inputs: TPS2PadInputs; Paused, AudioEnabled: Boolean; Volume: Single; GSThreads: Integer;
  GSAsync, Recompiler, Vulkan, HLE: Boolean);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInputs := Inputs;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
    FGSThreads := GSThreads;
    FGSAsync := GSAsync;
    FRecompiler := Recompiler;
    FVulkan := Vulkan;
    FHLE := HLE;
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TPS2Worker.RequestReset;
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

procedure TPS2Worker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

function TPS2Worker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TPS2Worker.TakeError(Audio: Boolean): string;
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

procedure TPS2Worker.AudioFailure(E: Exception);
begin
  FLock.Acquire;
  try
    FAudioError := 'PS2 audio: ' + E.Message;
  finally
    FLock.Release;
  end;
  FAudioFailed := True;
  FreeAndNil(FAudio);
  Restart;
end;

procedure TPS2Worker.ClearAudio;
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

procedure TPS2Worker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

procedure TPS2Worker.ReportError(const Text: string);
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

procedure TPS2Worker.Restart;
begin
  FDeadline := TStopwatch.GetTimeStamp;
  FClockGuest := FConsole.Scheduler.Now;
  FLock.Acquire;
  try
    FRate.Reset(FConsole.FrameCount, TStopwatch.GetTimeStamp);
  finally
    FLock.Release;
  end;
end;

// The console's last picture (after a snapshot load: the GS shows each
// picture it builds itself, OnFrame).
procedure TPS2Worker.Publish(Console: TPS2Console);
begin
  PublishPixels(Console.GS.Frame, Console.GS.FrameWidth, Console.GS.FrameHeight, Console.FrameCount);
end;

// A stable picture: a field (half height) is shown with doubled lines. (On
// the GS worker's thread too.)
procedure TPS2Worker.PublishPixels(const Source: TArray<Cardinal>; Width, Height: Integer; Number: Int64);
begin
  if (Width <= 0) or (Height <= 0) or (Length(Source) < Width * Height) then
    Exit;
  var Lines := 1;
  if Height < 300 then
    Lines := 2;
  var Frame: TEmulatorFrame;
  Frame.Width := Width;
  Frame.Height := Height * Lines;
  SetLength(Frame.Pixels, Width * Height * Lines);
  if Lines = 1 then
    Move(Source[0], Frame.Pixels[0], Width * Height * 4)
  else
  begin
    for var Y := 0 to Height - 1 do
    begin
      Move(Source[Y * Width], Frame.Pixels[Y * 2 * Width], Width * 4);
      Move(Source[Y * Width], Frame.Pixels[(Y * 2 + 1) * Width], Width * 4);
    end;
  end;
  Frame.FrameNumber := Number;
  FLock.Acquire;
  try
    Frame.FramesPerSecond := FRate.Update(Frame.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

// Memory cards live in one file per card; a card file is written only once
// a game changed the card. A card file of an earlier build (a file tree)
// is copied to '.old' once before the first save in the new form.
procedure TPS2Worker.LoadCards;
begin
  for var Port := 0 to 1 do
    if (FCardFiles[Port] <> '') and FStorage.Exists(FCardFiles[Port]) then
    begin
      var Data := FStorage.ReadBytes(FCardFiles[Port]);
      if (Length(Data) >= 8) and (CompareMem(@Data[0], @PS2MemoryCardMagic1, 8) or
        CompareMem(@Data[0], @PS2MemoryCardMagic2, 8)) and not FStorage.Exists(FCardFiles[Port] + '.old') then
        FStorage.WriteBytes(FCardFiles[Port] + '.old', Data);
      FConsole.MemoryCards.Cards[Port].Load(Data);
    end;
end;

procedure TPS2Worker.SaveCards;
begin
  if FConsole = nil then
    Exit;
  for var Port := 0 to 1 do
  begin
    var Card := FConsole.MemoryCards.Cards[Port];
    if not Card.Dirty or (FCardFiles[Port] = '') then
      Continue;
    FStorage.WriteBytes(FCardFiles[Port], Card.Image);
    Card.Dirty := False;
  end;
end;

// The console's EEPROM after the BIOS wrote it (configuration, NVM words).
procedure TPS2Worker.SaveNVM;
begin
  if (FConsole = nil) or not FConsole.BIOSBoot or not FConsole.Drive.NVMChanged or (NVMFile = '') then
    Exit;
  FStorage.EnsureFolder(ExtractFilePath(NVMFile));
  FStorage.WriteBytes(NVMFile, FConsole.Drive.NVM);
  FConsole.Drive.ClearNVMChanged;
end;

// A BIOS boots the disc itself.
procedure TPS2Worker.Boot;
begin
  if FConsole.BIOSBoot then
    Exit;
  if FBase.Disc <> nil then
  begin
    if not FConsole.BootDisc then
      raise EReadError.Create('Not a PlayStation 2 disc');
  end
  else
    FConsole.LoadProgram(FProgram, 'host:' + ExtractFileName(FProgramName));
end;

procedure TPS2Worker.TransferSnapshot(const Name: string; Loading: Boolean);
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
    LoadCoreSnapshot(Path, ROM_CORE_ID_PS2, FIdentity, Transfer, FStorage);
    Console.IOP.Hardware.SPU2.TakeSamples;
    ClearAudio;
    Publish(Console);
  end
  else
  begin
    SaveCoreSnapshot(Path, ROM_CORE_ID_PS2, FIdentity, Transfer, FStorage);
    var Pixels := Console.GS.Frame;
    if Length(Pixels) > 0 then
      SaveSnapshotPreview(Path, Console.GS.FrameWidth, Console.GS.FrameHeight, Console.GS.FrameWidth, @Pixels[0],
        FStorage);
  end;
  Restart;
end;

procedure TPS2Worker.Execute;
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
      var Config := FBase;
      if FBase.Disc = nil then
        Config.HostDirectory := ExtractFilePath(FProgramName);
      FConsole := TPS2Console.Create(Config);
      FConsole.GS.OnFrame :=
        procedure(const Pixels: TArray<Cardinal>; Width, Height: Integer; Number: Int64)
        begin
          PublishPixels(Pixels, Width, Height, Number);
        end;
      LoadCards;
      Boot;
      Restart;
      while not Terminated do
      begin
        FSnapshots.Process(
          procedure(const Name: string; Loading: Boolean)
          begin
            TransferSnapshot(Name, Loading);
          end);
        var Paused, ResetRequested, Enabled: Boolean;
        var Volume: Single;
        var Inputs: TPS2PadInputs;
        var GSThreads: Integer;
        var GSAsync, Recompiler, Vulkan, HLE: Boolean;
        FLock.Acquire;
        try
          Paused := FPause;
          ResetRequested := FReset;
          FReset := False;
          Inputs := FInputs;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          GSThreads := FGSThreads;
          GSAsync := FGSAsync;
          Recompiler := FRecompiler;
          Vulkan := FVulkan;
          HLE := FHLE;
        finally
          FLock.Release;
        end;
        // (The GS as the kick thread left it.)
        FConsole.GIF.Join;
        FConsole.GS.Raster.HLE := HLE;
        FConsole.GS.Raster.Vulkan := Vulkan;
        FConsole.GS.Raster.Threads := GSThreads;
        FConsole.GS.Raster.Async := GSAsync;
        FConsole.GIF.Threaded := GSAsync;
        FConsole.VU1.Core.UseJit := Recompiler;
        FConsole.VU0.Core.UseJit := Recompiler;
        FConsole.CPU.UseJit := Recompiler;
        for var Port := 0 to 1 do
        begin
          FConsole.PadMan.Pads[Port].Buttons := Inputs[Port].Buttons;
          for var K := 0 to 3 do
            FConsole.PadMan.Pads[Port].Axes[K] := Inputs[Port].Axes[K];
        end;
        if ResetRequested then
        begin
          SaveCards;
          FConsole.Reset;
          Boot;
          FConsole.IOP.Hardware.SPU2.TakeSamples;
          ClearAudio;
          Restart;
        end;
        if Paused then
        begin
          if not WasPaused then
          begin
            SaveCards;
            ClearAudio;
          end;
          WasPaused := True;
          FWake.WaitFor(10);
          Restart;
          Continue;
        end;
        if WasPaused then
          Restart;
        WasPaused := False;
        if WasEnabled <> Enabled then
        begin
          if not Enabled then
            ClearAudio;
          Restart;
        end;
        WasEnabled := Enabled;
        // With sound on, the audio queue is the real-time clock: a field runs
        // only when the device has room for its samples.
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
        FConsole.RunFrame;
        FConsole.TakeTTY;
        SaveNVM;
        if Terminated then
          Break;
        var Samples := FConsole.IOP.Hardware.SPU2.TakeSamples;
        if Enabled and not FAudioFailed then
        try
          if FAudio = nil then
            FAudio := TPS2AudioPlayback.Create;
          FAudio.Enqueue(Samples, Volume);
        except
          on E: Exception do
            AudioFailure(E);
        end;
        // (The picture was shown as the GS built it.)
        if not Enabled or FAudioFailed then
        begin
          // Without sound, pace the emulated time.
          var Target := FDeadline + (FConsole.Scheduler.Now - FClockGuest) * (TStopwatch.Frequency / PS2EEClock);
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
        ReportError('PS2: ' + E.Message);
    end;
    try
      SaveCards;
    except
      on E: Exception do
        ReportError('PS2 memory card: ' + E.Message);
    end;
    try
      SaveNVM;
    except
      on E: Exception do
        ReportError('PS2 console EEPROM: ' + E.Message);
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

{ TPS2CoreAdapter }

class function TPS2CoreAdapter.IsPS2Disc(Disc: TDVDImage): Boolean;
var
  Info: TPS2DiscInfo;
begin
  try
    Result := ReadPS2DiscInfo(Disc, Info);
  except
    Result := False;
  end;
end;

class function TPS2CoreAdapter.IsPS2ELF(const Data: TBytes): Boolean;
begin
  Result := TPS2ELF.IsELF(Data) and (Data[16] = 2);
  if Result then
  begin
    var Entry := PCardinal(@Data[24])^;
    Result := ((Entry and $1FFFFFFF) < PS2RAMSize) and ((Entry and $1FFFFFFF) >= $80000);
  end;
end;

class function TPS2CoreAdapter.IsPS2CD(Disc: TCDDisc): Boolean;
begin
  var Image := TDVDCDImage.Create(Disc, False);
  try
    Result := IsPS2Disc(Image);
  finally
    Image.Free;
  end;
end;

class function TPS2CoreAdapter.TryCreate(Stream: TStream; const Storage: IStorage; const RomName,
  SourceName: string): IEmulationCore;
begin
  Result := nil;
  var Ext := LowerCase(ExtractFileExt(SourceName));
  var Start := Stream.Position;
  try
    if Ext = '.elf' then
    begin
      var Size := Stream.Size - Start;
      if (Size >= 64) and (Size <= PS2RAMSize) then
      begin
        var Data: TBytes;
        SetLength(Data, Size);
        Stream.ReadBuffer(Data[0], Size);
        Stream.Position := Start;
        if IsPS2ELF(Data) then
          Result := TPS2CoreAdapter.Create(Stream, Storage, RomName);
      end;
      Exit;
    end;
    if (Ext <> '.iso') and (Ext <> '.mds') and (Ext <> '.chd') then
      Exit;
    if (Ext = '.iso') and not IsISO9660Stream(Stream) then
      Exit;
    var S := Storage;
    if S = nil then
      S := TStorage.Default;
    var Image := OpenDVDImage(S.OpenRead(RomName), S, RomName);
    if not (Image is TDVDCDImage) and IsPS2Disc(Image) then
      Result := TPS2CoreAdapter.Create(Stream, S, RomName, Image)
    else
      Image.Free;
  except
    Result := nil;
  end;
  Stream.Position := Start;
end;

constructor TPS2CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; Disc: TDVDImage);
begin
  inherited Create;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FConfigObject := TPS2Config.Create(FStorage.ConfigFile(ROM_SYSTEM_PS2), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FDisc := Disc;
  FProgramName := RomName;
  FRegion := TPS2Region.America;
  FPAL := False;
  if FDisc = nil then
  begin
    var Size := Stream.Size - Stream.Position;
    if (Size < 64) or (Size > PS2RAMSize) then
      raise EReadError.Create('PS2 ELF must fit in 32 MiB');
    SetLength(FProgram, Size);
    Stream.ReadBuffer(FProgram[0], Size);
    if not IsPS2ELF(FProgram) then
      raise EReadError.Create('Not a PlayStation 2 ELF program');
    var H := THashSHA2.Create;
    H.Update(FProgram[0], Length(FProgram));
    FIdentity := H.HashAsBytes;
  end
  else
  begin
    FIdentity := FDisc.Identity;
    var Info: TPS2DiscInfo;
    if ReadPS2DiscInfo(FDisc, Info) then
    begin
      var Prefix := Info.Serial.Substring(0, 4).ToUpper;
      if (Prefix = 'SLPS') or (Prefix = 'SLPM') or (Prefix = 'SCPS') or (Prefix = 'SCAJ') or (Prefix = 'SLKA') then
        FRegion := TPS2Region.Japan
      else if (Prefix = 'SLES') or (Prefix = 'SCES') or (Prefix = 'SCED') then
        FRegion := TPS2Region.Europe;
      FPAL := Info.VMode = 'PAL';
    end;
  end;
  var R := FConfigObject.Region;
  if R = 'japan' then
    FRegion := TPS2Region.Japan
  else if R = 'usa' then
    FRegion := TPS2Region.America
  else if R = 'europe' then
    FRegion := TPS2Region.Europe;
  if FConfigObject.Video = 'pal' then
    FPAL := True
  else if FConfigObject.Video = 'ntsc' then
    FPAL := False;
  if FDisc <> nil then
    SelectBIOS(RomName);
  var Identity := SnapshotIdentity(FIdentity);
  // BIOS boot snapshots hold the IOP machine too: kept apart.
  var SnapshotFolder := Identity;
  if FBIOS <> nil then
    SnapshotFolder := Identity + '-bios';
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_PS2, RomName, SnapshotFolder);
  FCardFiles[0] := FStorage.GameSave(ROM_SYSTEM_PS2, RomName, Identity);
  FCardFiles[1] := FStorage.GameSave(ROM_SYSTEM_PS2, RomName, Identity + '-2');
end;

// BIOS modes (Hardware/BIOSMode): 'hle' never boots a BIOS, 'auto' boots one
// when it finds it, 'external' requires one. The image is the one in the
// settings, or a PlayStation 2 BIOS beside the game, in the ps2 folder or in
// the bios folder (one of the disc's region first). The console's EEPROM is
// kept in the save folder per BIOS version; the first time it comes from an
// .nvm file beside the BIOS when there is one (blank otherwise: the BIOS runs
// its first-start setup and stores the answers). A .mec file beside the
// BIOS gives the MECHACON version.
procedure TPS2CoreAdapter.SelectBIOS(const RomName: string);
begin
  var Mode := FConfigObject.BIOSMode;
  if Mode = 'hle' then
    Exit;
  var Path := FConfigObject.BIOSFile;
  if (Path <> '') and not FStorage.Exists(Path) then
  begin
    if Mode = 'external' then
      raise EReadError.Create('PlayStation 2 BIOS file not found: ' + Path);
    Path := '';
  end;
  if Path = '' then
    Path := FindBIOS(RomName);
  if Path = '' then
  begin
    if Mode = 'external' then
      raise EReadError.Create('PlayStation 2 BIOS not found: choose it in the settings (BIOS file) or put it beside ' +
        'the game or in the ps2 folder');
    Exit;
  end;
  var Data := FStorage.ReadBytes(Path);
  if not TPS2BIOS.IsBIOS(Data) then
  begin
    if Mode = 'external' then
      raise EReadError.Create('Not a PlayStation 2 BIOS (4 MiB image with ROMDIR): ' + ExtractFileName(Path));
    Exit;
  end;
  FBIOS := Data;
  var BIOS := TPS2BIOS.Create(Data);
  try
    FNVMFile := TPath.Combine(TPath.Combine(FStorage.SaveRoot, ROM_SYSTEM_PS2), 'console-' + BIOS.ROMVER + '.nvm');
  finally
    BIOS.Free;
  end;
  if FStorage.Exists(FNVMFile) then
    FNVM := FStorage.ReadBytes(FNVMFile)
  else if FStorage.Exists(ChangeFileExt(Path, '.nvm')) then
    FNVM := FStorage.ReadBytes(ChangeFileExt(Path, '.nvm'));
  if FStorage.Exists(ChangeFileExt(Path, '.mec')) then
    FMechacon := FStorage.ReadBytes(ChangeFileExt(Path, '.mec'));
end;

function TPS2CoreAdapter.FindBIOS(const RomName: string): string;
begin
  Result := '';
  var Wanted := 'A';
  case FRegion of
    TPS2Region.Japan: Wanted := 'J';
    TPS2Region.Europe: Wanted := 'E';
  end;
  var Folders: TArray<string> := [FStorage.RomFolder(ROM_SYSTEM_PS2), TPath.Combine(FStorage.Root, 'bios')];
  if not RomName.StartsWith('content://', True) then
    Folders := [ExtractFilePath(RomName)] + Folders;
  for var Folder in Folders do
  begin
    if (Folder = '') or not FStorage.FolderExists(Folder) then
      Continue;
    var Names := FStorage.Files(Folder);
    TArray.Sort<string>(Names);
    for var Name in Names do
    begin
      var Ext := ExtractFileExt(Name).ToLower;
      if ((Ext <> '.bin') and (Ext <> '.rom')) or (FStorage.Describe(Name).Size <> PS2BIOSSize) then
        Continue;
      var Data := FStorage.ReadBytes(Name);
      if not TPS2BIOS.IsBIOS(Data) then
        Continue;
      var BIOS := TPS2BIOS.Create(Data);
      try
        if BIOS.RegionLetter = Wanted then
          Exit(Name);
      finally
        BIOS.Free;
      end;
      if Result = '' then
        Result := Name;
    end;
    if Result <> '' then
      Exit;
  end;
end;

destructor TPS2CoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;
  inherited;
end;

procedure TPS2CoreAdapter.Configure;
begin
  if FWorker = nil then
    Exit;
  var Input := GetInputState;
  var Inputs: TPS2PadInputs;
  for var Port := 0 to 1 do
  begin
    var Pad := FControllers[Port];
    var Keys := FKeyboardExtra[Port];
    var LeftX := Integer(Pad.LeftX);
    var LeftY := Integer(Pad.LeftY);
    var RightX := Integer(Pad.RightX);
    var RightY := Integer(Pad.RightY);
    if Input.Analog[Port].Valid then
    begin
      Inc(LeftX, Input.Analog[Port].X);
      Inc(LeftY, Input.Analog[Port].Y);
    end;
    LeftX := LeftX + 32767 * (Ord(Keys[TPS2Extra.LeftRight]) - Ord(Keys[TPS2Extra.LeftLeft]));
    LeftY := LeftY + 32767 * (Ord(Keys[TPS2Extra.LeftDown]) - Ord(Keys[TPS2Extra.LeftUp]));
    RightX := RightX + 32767 * (Ord(Keys[TPS2Extra.RightRight]) - Ord(Keys[TPS2Extra.RightLeft]));
    RightY := RightY + 32767 * (Ord(Keys[TPS2Extra.RightDown]) - Ord(Keys[TPS2Extra.RightUp]));
    var Buttons := Pad.Buttons;
    if Port = 0 then
      Buttons := Buttons or PadBits(Input.Buttons)
    else
      Buttons := Buttons or PadBits(Input.Buttons2);
    if Keys[TPS2Extra.L2] then
      Buttons := Buttons or PS2PadL2;
    if Keys[TPS2Extra.L3] then
      Buttons := Buttons or PS2PadL3;
    if Keys[TPS2Extra.R3] then
      Buttons := Buttons or PS2PadR3;
    Inputs[Port] := Default(TPS2PadInput);
    Inputs[Port].Buttons := Buttons;
    Inputs[Port].Axes[0] := StickByte(RightX);
    Inputs[Port].Axes[1] := StickByte(RightY);
    Inputs[Port].Axes[2] := StickByte(LeftX);
    Inputs[Port].Axes[3] := StickByte(LeftY);
    // Pressure: full for pressed buttons (keyboard and digital pads).
    for var K := 0 to 11 do
      Inputs[Port].Pressure[K] := 0;
  end;
  FWorker.Configure(Inputs, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume, FConfigObject.GSThreads,
    FConfigObject.GSAsync, FConfigObject.Recompiler, FConfigObject.Renderer = 'vulkan',
    FConfigObject.Renderer = 'vulkan-hle');
end;

procedure TPS2CoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;
  var Base := Default(TPS2ConsoleConfig);
  Base.PAL := FPAL;
  Base.Disc := FDisc;
  Base.Region := FRegion;
  Base.Language := FConfigObject.ConsoleLanguage;
  Base.BIOS := FBIOS;
  Base.Mechacon := FMechacon;
  Base.NVM := FNVM;
  FWorker := TPS2Worker.Create(FProgram, FIdentity, FProgramName, Base, FStorage, FSnapshotDirectory, FCardFiles[0],
    FCardFiles[1]);
  FWorker.NVMFile := FNVMFile;
  Configure;
  FWorker.Start;
end;

procedure TPS2CoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;
  FWorker.StopAndSave;
  FError := FWorker.TakeError;
  FreeAndNil(FWorker);
end;

procedure TPS2CoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TPS2CoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TPS2CoreAdapter.Reset;
begin
  FPaused := False;
  if FWorker <> nil then
    FWorker.RequestReset;
  Configure;
end;

procedure TPS2CoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  FillChar(FKeyboardExtra, SizeOf(FKeyboardExtra), 0);
  FControllers[0] := Default(TPS2Pad);
  FControllers[1] := Default(TPS2Pad);
  Configure;
end;

procedure TPS2CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
begin
  if Code = 0 then
    Exit;
  for var Port := 0 to 1 do
  begin
    for var Button := Low(TEmulatorButton) to High(TEmulatorButton) do
      if Code = FConfigObject.Keys[Port, Button] then
        if Port = 0 then
        begin
          if Pressed then
            Include(FKeyboard.Buttons, Button)
          else
            Exclude(FKeyboard.Buttons, Button);
        end
        else if Pressed then
          Include(FKeyboard.Buttons2, Button)
        else
          Exclude(FKeyboard.Buttons2, Button);
    for var Extra := Low(TPS2Extra) to High(TPS2Extra) do
      if Code = FConfigObject.ExtraKey(Port, Extra) then
        FKeyboardExtra[Port, Extra] := Pressed;
  end;
  Configure;
end;

procedure TPS2CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  Configure;
end;

procedure TPS2CoreAdapter.SetPS2Controller(Port: Integer; const Pad: TPS2Pad);
begin
  if (Port < 0) or (Port > 1) then
    Exit;
  FControllers[Port] := Pad;
  Configure;
end;

function TPS2CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TPS2CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TPS2CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, False);
end;

procedure TPS2CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, True);
end;

function TPS2CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TPS2CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError;
end;

function TPS2CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FWorker <> nil then
    Result := FWorker.TakeError(True);
end;

function TPS2CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TPS2CoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_PS2;
end;

function TPS2CoreAdapter.GetName: string;
begin
  Result := 'PlayStation 2';
end;

function TPS2CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TPS2CoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TPS2CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TPS2CoreAdapter.InsertCoin1;
begin
end;

procedure TPS2CoreAdapter.InsertCoin2;
begin
end;

function TPS2CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

end.
