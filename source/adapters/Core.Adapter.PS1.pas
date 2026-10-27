unit Core.Adapter.PS1;

interface

uses
  Core.InputConfig, System.SysUtils, System.Classes, System.IniFiles,
  System.SyncObjs, Core.Storage, Core.Emulation, Core.Snapshots, Core.CD.Disc,
  PS1.Console, PS1.SIO, Core.PS1.Playback;

{$SCOPEDENUMS ON}

type
  TPS1KeyMap = array[0..1, TEmulatorButton] of UInt32;

  // Controller inputs beyond the logical pad; frontends number their actions
  // in this order.
  TPS1Extra = (L2, L3, R3, Analog, LeftUp, LeftDown, LeftLeft, LeftRight, RightUp, RightDown, RightLeft,
    RightRight);

  TPS1ExtraKeyMap = array[0..1, TPS1Extra] of UInt32;

  TPS1Config = class(TEmulatorConfigBase)
  private
    FKeys: TPS1KeyMap;
    FExtraKeys: TPS1ExtraKeyMap;
    FBIOSFile, FVideo: string;
    FRumble: Boolean;
  protected
    procedure LoadCoreSettings(Ini: TCustomIniFile); override;
    procedure SaveCoreSettings(Ini: TCustomIniFile); override;
  public
    constructor Create(const FileName: string; const Storage: IStorage = nil);
    class function ExtraKeyName(Extra: TPS1Extra): string; static;
    function ExtraKey(Port: Integer; Extra: TPS1Extra): UInt32;
    // Empty: search beside the game, then the built-in BIOS. 'builtin:<name>'
    // or a path selects one explicitly.
    property BIOSFile: string read FBIOSFile write FBIOSFile;
    // 'auto' (from the BIOS or the disc), 'ntsc' or 'pal'.
    property Video: string read FVideo write FVideo;
    property Rumble: Boolean read FRumble write FRumble;
    property Keys: TPS1KeyMap read FKeys;
  end;

  // Controller inputs a frontend supplies beyond the logical pad. The left
  // stick adds to TEmulatorInput.Analog of the port.
  TPS1Pad = record
    Buttons: Word; // PS1Pad* bits (L2, L3, R3) added to the logical pad
    AnalogButton: Boolean; // DualShock ANALOG button
    // -32768..32767, 0 centred, Y growing downwards.
    LeftX, LeftY, RightX, RightY: SmallInt;
  end;

  IPS1ControllerInput = interface
    ['{5E0C8C9E-3C55-4D2B-9C1E-7B1E6B5F2A41}']
    procedure SetPS1Controller(Port: Integer; const Pad: TPS1Pad);
  end;

  TPS1PadInputs = array[0..1] of TPS1PadInput;

  TPS1Worker = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FSnapshots: TSnapshotQueue;
    FMediaDone: TEvent;
    FMediaPending: Boolean;
    FNextDisc: TCDDisc;
    FMediaError: string;
    FInputPortsCommand: TInputPortsCommand;
    FStorage: IStorage;
    FBIOS, FExe, FIdentity: TBytes;
    FPAL: Boolean;
    FDisc: TCDDisc;
    FCardFiles: array[0..1] of string;
    FSnapshotDirectory, FError, FAudioError: string;
    FInputs: TPS1PadInputs;
    FPause, FReset, FAudioEnabled, FAvailable: Boolean;
    FVolume: Single;
    FFrame: TEmulatorFrame;
    FRumbleLevel: Byte;
    // Worker-thread state.
    FConsole: TPS1Console;
    FAudio: TPS1AudioPlayback;
    FAudioFailed: Boolean;
    FRate: TEmulationFrameRate;
    FDeadline: Double;
    FClockGuest: Int64;
    FConnected: array[0..1] of Boolean;
    FKinds: array[0..1] of TPS1PadKind;
    procedure ProcessMediaChange;
    procedure ReportError(const Text: string);
    procedure AudioFailure(E: Exception);
    procedure ClearAudio;
    procedure Restart;
    procedure ApplyPorts(const Ports: TCoreInputPorts);
    procedure TransferSnapshot(const Name: string; Loading: Boolean);
    function GetInputPorts: TCoreInputPorts;
    procedure SetInputPorts(const Ports: TCoreInputPorts);
    procedure Publish(Console: TPS1Console);
    procedure LoadCards(Console: TPS1Console);
    procedure SaveCards(Console: TPS1Console);
  protected
    procedure Execute; override;
  public
    constructor Create(const BIOS, Exe, Identity: TBytes; PAL: Boolean; Disc: TCDDisc; const Storage: IStorage; const CardFile1, CardFile2, SnapshotDirectory: string);
    destructor Destroy; override;
    procedure Configure(const Inputs: TPS1PadInputs; Paused, AudioEnabled: Boolean; Volume: Single);
    procedure ChangeDisc(Disc: TCDDisc);
    procedure RequestReset;
    procedure StopAndSave;
    function TryGetFrame(out Frame: TEmulatorFrame): Boolean;
    function TakeError(Audio: Boolean): string;
    procedure Snapshot(const Name: string; Loading: Boolean);
    // Port 1 motors after the last frame (large speed, or the small motor).
    function RumbleLevel: Byte;
    property InputPorts: TCoreInputPorts read GetInputPorts write SetInputPorts;
  end;

  TPS1CoreAdapter = class(TInterfacedObject, IEmulationCore, IEmulationInputPorts, IEmulationSnapshotLocation, IEmulationAudioDiagnostics, IPS1ControllerInput, IEmulationRumbleOutput, IEmulationDiscControl)
  private
    FStorage: IStorage;
    FConfig: IEmulatorConfig;
    FConfigObject: TPS1Config;
    FWorker: TPS1Worker;
    FDisc: TCDDisc;
    FBIOS, FExe, FIdentity: TBytes;
    FPAL: Boolean;
    FPorts: TCoreInputPorts;
    FKeyboard, FGamepad: TEmulatorInput;
    FKeyboardExtra: array[0..1, TPS1Extra] of Boolean;
    FControllers: array[0..1] of TPS1Pad;
    FPaused: Boolean;
    FCardFiles: array[0..1] of string;
    FSnapshotDirectory, FError: string;
    FDiscLocations, FDiscNames: TArray<string>;
    FDiscIndex: Integer;
    procedure ReplaceDisc(const Location: string; Index: Integer);
    procedure LoadBIOS(const RomName: string);
    procedure Configure;
  public
    function GetDiscCount: Integer;
    function GetDiscName(Index: Integer): string;
    function GetDiscIndex: Integer;
    procedure ChangeDisc(Index: Integer);
    procedure OpenDisc(const Location: string);
    procedure EjectDisc;
    // Stream holds a PS-X EXE or an M3U when no disc is given.
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc = nil);
    destructor Destroy; override;
    // A PlayStation disc: PVD system identifier, licence sector or boot files.
    class function IsPS1Disc(Disc: TCDDisc): Boolean; static;
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
    procedure SetPS1Controller(Port: Integer; const Pad: TPS1Pad);
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
  end;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.MMSystem, {$ENDIF}
  System.Math, System.Diagnostics, System.UITypes, System.IOUtils,
  Core.RomFormat, Core.SavePaths, PS1.Types, PS1.Firmware;

const
  KeyNames: array[TEmulatorButton] of string =
    ('Up', 'Down', 'Left', 'Right', 'Cross', 'Circle', 'Select', 'Start', 'L1', 'Square', 'Triangle', 'R1', 'R2');
  DefaultKeys: array[0..1, TEmulatorButton] of UInt32 = (
    (vkUp, vkDown, vkLeft, vkRight, vkX, vkC, vkSpace, vkReturn, vkQ, vkZ, vkS, vkE, vkR),
    (vkNumpad8, vkNumpad5, vkNumpad4, vkNumpad6, vkNumpad2, vkNumpad3, 0, vkNumpad0, 0, vkNumpad1, vkNumpad7, 0, 0));
  // Logical pad: A Cross, B Circle, X Square, Y Triangle, C L1, Z R1, Mode R2.
  ButtonBits: array[TEmulatorButton] of Word = (PS1PadUp, PS1PadDown, PS1PadLeft, PS1PadRight, PS1PadCross,
    PS1PadCircle, PS1PadSelect, PS1PadStart, PS1PadL1, PS1PadSquare, PS1PadTriangle, PS1PadR1, PS1PadR2);
  BIOSNames: array[0..9] of string = ('ps1_bios.bin', 'psx_bios.bin', 'scph1001.bin', 'scph5501.bin', 'scph7001.bin',
    'scph101.bin', 'scph1002.bin', 'scph5502.bin', 'scph1000.bin', 'scph5500.bin');
  ExtraKeyNames: array[TPS1Extra] of string = ('L2', 'L3', 'R3', 'Analog', 'LeftStickUp', 'LeftStickDown',
    'LeftStickLeft', 'LeftStickRight', 'RightStickUp', 'RightStickDown', 'RightStickLeft', 'RightStickRight');
  DefaultExtraKeys: array[TPS1Extra] of UInt32 = (vkW, 0, 0, vkA, vkT, vkG, vkF, vkH, vkI, vkK, vkJ, vkL);

function PadBits(const Buttons: TEmulatorButtons): Word;
begin
  Result := 0;
  for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
    if B in Buttons then
      Result := Result or ButtonBits[B];
end;

// -32768..32767 (sums of several sources are clamped) to the pad's 00h..FFh.
function StickByte(Value: Integer): Byte;
begin
  Result := EnsureRange(128 + EnsureRange(Value, -32768, 32767) div 256, 0, 255);
end;

{ TPS1Config }

constructor TPS1Config.Create(const FileName: string; const Storage: IStorage);
begin
  inherited Create(FileName, Storage);
  FKeys := TPS1KeyMap(DefaultKeys);
  for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
  begin
    FExtraKeys[0, Extra] := DefaultExtraKeys[Extra];
    FExtraKeys[1, Extra] := 0;
  end;
  FVideo := 'auto';
  FRumble := True;
end;

class function TPS1Config.ExtraKeyName(Extra: TPS1Extra): string;
begin
  Result := ExtraKeyNames[Extra];
end;

function TPS1Config.ExtraKey(Port: Integer; Extra: TPS1Extra): UInt32;
begin
  Result := FExtraKeys[Port, Extra];
end;

procedure TPS1Config.LoadCoreSettings(Ini: TCustomIniFile);
begin
  FBIOSFile := Ini.ReadString('Hardware', 'BIOS', '');
  FVideo := Ini.ReadString('System', 'Video', 'auto').ToLower;
  if (FVideo <> 'ntsc') and (FVideo <> 'pal') then
    FVideo := 'auto';
  FRumble := Ini.ReadBool('Peripherals', 'Rumble', True);
  for var P := 0 to 1 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      FKeys[P, B] := ReadEmulatorKey(Ini, Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      FExtraKeys[P, Extra] := ReadEmulatorKey(Ini, Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

procedure TPS1Config.SaveCoreSettings(Ini: TCustomIniFile);
begin
  Ini.WriteString('Hardware', 'BIOS', FBIOSFile);
  Ini.WriteString('System', 'Video', FVideo);
  Ini.WriteBool('Peripherals', 'Rumble', FRumble);
  for var P := 0 to 1 do
  begin
    var Section := 'Keys';
    if P > 0 then
      Section := Section + IntToStr(P + 1);
    for var B := Low(TEmulatorButton) to High(TEmulatorButton) do
      Ini.WriteInteger(Section, KeyNames[B], FKeys[P, B]);
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      Ini.WriteInteger(Section, ExtraKeyNames[Extra], FExtraKeys[P, Extra]);
  end;
end;

{ TPS1Worker }

constructor TPS1Worker.Create(const BIOS, Exe, Identity: TBytes; PAL: Boolean; Disc: TCDDisc; const Storage: IStorage; const CardFile1, CardFile2, SnapshotDirectory: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FBIOS := Copy(BIOS);
  FExe := Copy(Exe);
  FIdentity := Copy(Identity);
  FPAL := PAL;
  FDisc := Disc;
  FStorage := Storage;
  FCardFiles[0] := CardFile1;
  FCardFiles[1] := CardFile2;
  FSnapshotDirectory := SnapshotDirectory;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FSnapshots := TSnapshotQueue.Create;
  FMediaDone := TEvent.Create(nil, True, False, '');
  FInputPortsCommand := TInputPortsCommand.Create;
end;

destructor TPS1Worker.Destroy;
begin
  Terminate;
  if FWake <> nil then
    FWake.SetEvent;
  // Join before freeing the objects Execute uses.
  inherited;
  FInputPortsCommand.Free;
  FSnapshots.Free;
  FMediaDone.Free;
  FWake.Free;
  FLock.Free;
end;

procedure TPS1Worker.ChangeDisc(Disc: TCDDisc);
begin
  if Suspended or Finished then
    raise EInvalidOpException.Create('Emulation worker is not running');
  FLock.Acquire;
  try
    if FMediaPending then
      raise EInvalidOpException.Create('A disc change is already pending');
    FMediaDone.ResetEvent;
    FNextDisc := Disc;
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

procedure TPS1Worker.ProcessMediaChange;
begin
  FLock.Acquire;
  try
    if not FMediaPending then
      Exit;
    try
      // Keep RAM, CPU and memory cards intact. Only the drive changes media.
      var Identity: TBytes;
      if FNextDisc <> nil then
        Identity := FNextDisc.Identity;
      FConsole.CDROM.OpenShell;
      try
        if FNextDisc <> nil then
          FConsole.CDROM.CloseShell(FNextDisc);
      except
        // Restore the borrowed old disc before the caller can free the candidate.
        FConsole.CDROM.CloseShell(FDisc);
        raise;
      end;
      FDisc := FNextDisc;
      FIdentity := Identity;
      ClearAudio;
      FConsole.SPU.TakeSamples;
      Restart;
    except
      on E: Exception do
        FMediaError := E.Message;
    end;
    FNextDisc := nil;
    FMediaPending := False;
    FMediaDone.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TPS1Worker.GetInputPorts: TCoreInputPorts;
begin
  Result := FInputPortsCommand.GetPorts;
end;

procedure TPS1Worker.SetInputPorts(const Ports: TCoreInputPorts);
begin
  FInputPortsCommand.Apply(Self, Ports, FWake);
end;

procedure TPS1Worker.Configure(const Inputs: TPS1PadInputs; Paused, AudioEnabled: Boolean; Volume: Single);
begin
  var Wake: Boolean;
  FLock.Acquire;
  try
    Wake := FPause <> Paused;
    FInputs := Inputs;
    FPause := Paused;
    FAudioEnabled := AudioEnabled;
    FVolume := EnsureRange(Volume, 0.0, 1.0);
  finally
    FLock.Release;
  end;
  if Wake then
    FWake.SetEvent;
end;

procedure TPS1Worker.RequestReset;
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

procedure TPS1Worker.StopAndSave;
begin
  Terminate;
  FWake.SetEvent;
  if Suspended then
    Start;
  WaitFor;
end;

function TPS1Worker.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
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

function TPS1Worker.TakeError(Audio: Boolean): string;
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

procedure TPS1Worker.Snapshot(const Name: string; Loading: Boolean);
begin
  FWake.SetEvent;
  FSnapshots.Execute(Self, Name, Loading);
end;

function TPS1Worker.RumbleLevel: Byte;
begin
  FLock.Acquire;
  try
    Result := FRumbleLevel;
  finally
    FLock.Release;
  end;
end;

// The picture is resampled to its shape on a 4:3 screen: the width follows
// the display aspect, and lines are doubled when the source is wider than
// that would allow (hi-res modes keep their horizontal detail).
procedure TPS1Worker.Publish(Console: TPS1Console);
begin
  var Width := Console.FrameWidth;
  var Height := Console.FrameHeight;
  var Aspect := Console.DisplayAspect;
  var Lines := 1;
  if (Height < 400) and (Width > Round(Height * Aspect * 1.05)) then
    Lines := 2;
  var OutHeight := Height * Lines;
  var OutWidth := EnsureRange(Round(OutHeight * Aspect), 16, 1024);
  var Frame: TEmulatorFrame;
  Frame.Width := OutWidth;
  Frame.Height := OutHeight;
  var Source := Console.Pixels;
  if (OutWidth = Width) and (Lines = 1) then
    Frame.Pixels := Copy(Source)
  else
  begin
    SetLength(Frame.Pixels, OutWidth * OutHeight);
    var Columns: TArray<Integer>;
    SetLength(Columns, OutWidth);
    for var X := 0 to OutWidth - 1 do
      Columns[X] := X * Width div OutWidth;
    for var Y := 0 to OutHeight - 1 do
    begin
      var Row := (Y div Lines) * Width;
      var Target := Y * OutWidth;
      for var X := 0 to OutWidth - 1 do
        Frame.Pixels[Target + X] := Source[Row + Columns[X]];
    end;
  end;
  Frame.FrameNumber := Console.FrameNumber;
  Frame.FramesPerSecond := FRate.Update(Frame.FrameNumber, TStopwatch.GetTimeStamp, TStopwatch.Frequency);
  FLock.Acquire;
  try
    FFrame := Frame;
    FAvailable := True;
  finally
    FLock.Release;
  end;
end;

// New cards start formatted; a card file is written only once a game saves
// to the card.
procedure TPS1Worker.LoadCards(Console: TPS1Console);
begin
  for var Port := 0 to 1 do
  begin
    var Card := TPS1MemoryCard.Create;
    try
      if (FCardFiles[Port] <> '') and FStorage.Exists(FCardFiles[Port]) then
      begin
        var Image := FStorage.ReadBytes(FCardFiles[Port]);
        if Length(Image) <> PS1MemoryCardSize then
          raise EReadError.CreateFmt('Memory card %d must contain 128 KiB: %s', [Port + 1, FCardFiles[Port]]);
        Card.Load(Image);
      end;
      Card.Dirty := False;
    except
      Card.Free;
      raise;
    end;
    Console.InsertCard(Port, Card);
  end;
end;

procedure TPS1Worker.SaveCards(Console: TPS1Console);
begin
  for var Port := 0 to 1 do
  begin
    var Card := Console.Card(Port);
    if (Card = nil) or not Card.Dirty or (FCardFiles[Port] = '') then
      Continue;
    FStorage.WriteBytes(FCardFiles[Port], Card.Image);
    Card.Dirty := False;
  end;
end;

procedure TPS1Worker.ReportError(const Text: string);
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

procedure TPS1Worker.AudioFailure(E: Exception);
begin
  FLock.Acquire;
  try
    FAudioError := 'PS1 audio: ' + E.Message;
  finally
    FLock.Release;
  end;
  FAudioFailed := True;
  FreeAndNil(FAudio);
  Restart;
end;

procedure TPS1Worker.ClearAudio;
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

procedure TPS1Worker.Restart;
begin
  FDeadline := TStopwatch.GetTimeStamp;
  FClockGuest := FConsole.Scheduler.Now;
  FRate.Reset(FConsole.FrameNumber, TStopwatch.GetTimeStamp);
end;

procedure TPS1Worker.ApplyPorts(const Ports: TCoreInputPorts);
begin
  for var Port := 0 to 1 do
  begin
    FConnected[Port] := Ports.Devices[Port] <> 'none';
    if Ports.Devices[Port] = 'pad-analog' then
      FKinds[Port] := TPS1PadKind.DualShock
    else
      FKinds[Port] := TPS1PadKind.Digital;
  end;
end;

procedure TPS1Worker.TransferSnapshot(const Name: string; Loading: Boolean);
begin
  if (FDisc = nil) and (Length(FExe) = 0) then
    raise EInvalidOpException.Create('Insert a disc before saving or loading a PS1 snapshot');
  var Path := ResolveSnapshotPath(FSnapshotDirectory, Name);
  var Console := FConsole;
  var Transfer: TStateTransfer :=
    procedure(State: TStateArchive)
    begin
      Console.SerializeState(State);
    end;
  if Loading then
  begin
    LoadCoreSnapshot(Path, ROM_CORE_ID_PS1, FIdentity, Transfer, FStorage);
    // The cards now hold the snapshot's contents; they are written to their
    // files on the next pause, reset or stop (a never-used blank card still
    // gets no file).
    var Blank := TPS1MemoryCard.Create;
    try
      for var Port := 0 to 1 do
        if Console.Card(Port) <> nil then
          Console.Card(Port).Dirty := FStorage.Exists(FCardFiles[Port]) or
            not CompareMem(@Console.Card(Port).Data[0], @Blank.Data[0], PS1MemoryCardSize);
    finally
      Blank.Free;
    end;
    ClearAudio;
    Console.SPU.TakeSamples;
    Publish(Console);
  end
  else
  begin
    SaveCoreSnapshot(Path, ROM_CORE_ID_PS1, FIdentity, Transfer, FStorage);
    SaveSnapshotPreview(Path, Console.FrameWidth, Console.FrameHeight, Console.FrameWidth, @Console.Pixels[0], FStorage);
  end;
  Restart;
end;

procedure TPS1Worker.Execute;
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
      FConsole := TPS1Console.Create(FBIOS, FPAL);
      FConsole.InsertDisc(FDisc);
      LoadCards(FConsole);
      if Length(FExe) > 0 then
        FConsole.LoadExe(FExe);
      Restart;
      while not Terminated do
      begin
        ProcessMediaChange;
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

        var Inputs: TPS1PadInputs;
        var Paused, Enabled, ResetRequested: Boolean;
        var Volume: Single;
        FLock.Acquire;
        try
          Inputs := FInputs;
          Paused := FPause;
          Enabled := FAudioEnabled;
          Volume := FVolume;
          ResetRequested := FReset;
          FReset := False;
        finally
          FLock.Release;
        end;

        if ResetRequested then
        begin
          SaveCards(FConsole);
          FConsole.Reset;
          FConsole.SPU.TakeSamples;
          ClearAudio;
          Restart;
        end;

        if Paused then
        begin
          if not WasPaused then
          begin
            SaveCards(FConsole);
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

        // The audio queue is the real-time clock: run a frame only when the
        // device has room for its samples.
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

        for var Port := 0 to 1 do
          FConsole.SetPad(Port, Inputs[Port], FKinds[Port], FConnected[Port]);
        FConsole.RunFrame;
        var Pad := FConsole.Pad(0);
        var Level := Pad.LargeMotor;
        if Pad.SmallMotor then
          Level := Max(Level, 128);
        FLock.Acquire;
        try
          FRumbleLevel := Level;
        finally
          FLock.Release;
        end;
        if Terminated then
          Break;

        var Samples := FConsole.SPU.TakeSamples;
        if Enabled and not FAudioFailed then
        try
          if FAudio = nil then
            FAudio := TPS1AudioPlayback.Create;
          FAudio.Enqueue(Samples, Volume);
        except
          on E: Exception do
            AudioFailure(E);
        end;
        Publish(FConsole);

        if not Enabled or FAudioFailed then
        begin
          // Without audio, pace the emulated time.
          var Target := FDeadline + (FConsole.Scheduler.Now - FClockGuest) * (TStopwatch.Frequency / PS1CPUClock);
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
        ReportError('PS1: ' + E.Message);
    end;
    if FConsole <> nil then
    try
      SaveCards(FConsole);
    except
      on E: Exception do
        ReportError('PS1 memory card: ' + E.Message);
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

{ TPS1CoreAdapter }

class function TPS1CoreAdapter.IsPS1Disc(Disc: TCDDisc): Boolean;
begin
  Result := False;
  for var T := 1 to Disc.TrackCount do
  begin
    var Track := Disc.Track(T);
    if Track.Audio then
      Continue;
    if Track.EndLBA - Track.StartLBA < 17 then
      Exit;

    var Sector: TBytes;
    Disc.ReadData(Track.StartLBA + 16, Sector);
    if (Sector[0] = 1) and (TEncoding.ASCII.GetString(Sector, 1, 5) = 'CD001') and
      TEncoding.ASCII.GetString(Sector, 8, 32).Trim.StartsWith('PLAYSTATION') then
      Exit(True);
    Disc.ReadData(Track.StartLBA + 4, Sector);
    if TEncoding.ASCII.GetString(Sector, 0, 128).Contains('Sony Computer Entertainment') then
      Exit(True);
    var Config := TEncoding.ASCII.GetString(Disc.ReadISOFile('SYSTEM.CNF', 2048)).ToUpper;
    if Config.Contains('BOOT') and Config.Contains('CDROM:') then
      Exit(True);
    var Exe := Disc.ReadISOFile('PSX.EXE', 2048);
    Exit((Length(Exe) >= 8) and (TEncoding.ASCII.GetString(Exe, 0, 8) = 'PS-X EXE'));
  end;
end;

constructor TPS1CoreAdapter.Create(Stream: TStream; const Storage: IStorage; const RomName: string; OwnedDisc: TCDDisc);
begin
  inherited Create;
  FDisc := OwnedDisc;
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FConfigObject := TPS1Config.Create(FStorage.ConfigFile(ROM_SYSTEM_PS1), FStorage);
  FConfig := FConfigObject;
  FConfig.Load;
  FDiscIndex := -1;
  var SourceName := RomName;
  if RomName.StartsWith('content://', True) then
    SourceName := FStorage.Describe(RomName).Name;
  var Playlist := SameText(ExtractFileExt(SourceName), ROM_EXTENSION_M3U);
  if Playlist then
  begin
    FDiscLocations := ReadCDPlaylist(Stream, FStorage, RomName);
    SetLength(FDiscNames, Length(FDiscLocations));
    for var I := 0 to High(FDiscLocations) do
      FDiscNames[I] := FStorage.Describe(FDiscLocations[I]).Name;
    var DiscStream := FStorage.OpenRead(FDiscLocations[0]);
    try
      FDisc := TCDDisc.Create(DiscStream, FStorage, FDiscLocations[0]);
      if not IsPS1Disc(FDisc) then
        raise EReadError.Create('M3U disc is not a PlayStation image: ' + FDiscNames[0]);
    finally
      DiscStream.Free;
    end;
  end
  else if FDisc <> nil then
  begin
    FDiscLocations := TArray<string>.Create(RomName);
    FDiscNames := TArray<string>.Create(ExtractFileName(SourceName));
  end;
  if FDisc <> nil then
    FDiscIndex := 0;
  if FDisc = nil then
  begin
    var Size := Stream.Size - Stream.Position;
    if (Size < $800) or (Size > PS1RAMSize) then
      raise EReadError.Create('PS-X EXE must contain a header and fit in 2 MiB');
    SetLength(FExe, Size);
    Stream.ReadBuffer(FExe[0], Size);
    FIdentity := Copy(FExe);
  end
  else
    FIdentity := FDisc.Identity;
  LoadBIOS(RomName);

  // Video standard: setting, else the region of a Sony BIOS, else the disc's
  // licence text.
  var Video := FConfigObject.Video;
  if Video = 'pal' then
    FPAL := True
  else if Video = 'ntsc' then
    FPAL := False
  else
  begin
    var Info := IdentifyPS1BIOS(FBIOS);
    if Info.Known and not Info.OpenBIOS then
      FPAL := Info.Region = TPS1Region.Europe
    else if FDisc <> nil then
      for var T := 1 to FDisc.TrackCount do
        if not FDisc.Track(T).Audio then
        begin
          if FDisc.Track(T).EndLBA - FDisc.Track(T).StartLBA > 4 then
          begin
            var Sector: TBytes;
            FDisc.ReadData(FDisc.Track(T).StartLBA + 4, Sector);
            FPAL := TEncoding.ASCII.GetString(Sector, 0, 128).Contains('Entertainment Euro');
          end;
          Break;
        end;
  end;

  var Identity := SnapshotIdentity(FIdentity);
  // A playlist owns a stable save namespace, independent of the inserted disc.
  // Disc identities remain unmodified in snapshot headers for compatibility checks.
  if Playlist then
    Identity := SnapshotIdentity(TEncoding.UTF8.GetBytes('PS1 M3U/' + ExtractFileName(SourceName) + '/' + Identity));
  FSnapshotDirectory := FStorage.GameSnapshots(ROM_SYSTEM_PS1, RomName, Identity);
  FCardFiles[0] := FStorage.GameSave(ROM_SYSTEM_PS1, RomName, Identity);
  FCardFiles[1] := FStorage.GameSave(ROM_SYSTEM_PS1, RomName, Identity + '-2');
end;

destructor TPS1CoreAdapter.Destroy;
begin
  Stop;
  FDisc.Free;
  inherited;
end;

function TPS1CoreAdapter.GetDiscCount: Integer;
begin
  Result := Length(FDiscLocations);
end;

function TPS1CoreAdapter.GetDiscName(Index: Integer): string;
begin
  if (Index < 0) or (Index >= Length(FDiscNames)) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  Result := FDiscNames[Index];
end;

function TPS1CoreAdapter.GetDiscIndex: Integer;
begin
  Result := FDiscIndex;
end;

procedure TPS1CoreAdapter.ReplaceDisc(const Location: string; Index: Integer);
begin
  var Stream := FStorage.OpenRead(Location);
  var Disc: TCDDisc := nil;
  try
    Disc := TCDDisc.Create(Stream, FStorage, Location);
    if not IsPS1Disc(Disc) then
      raise EReadError.Create('Not a PlayStation disc: ' + Location);
    var Identity := Disc.Identity;
    if FWorker <> nil then
      FWorker.ChangeDisc(Disc);
    var OldDisc := FDisc;
    FDisc := Disc;
    Disc := nil;
    FIdentity := Identity;
    FDiscIndex := Index;
    OldDisc.Free;
  finally
    Disc.Free;
    Stream.Free;
  end;
end;

procedure TPS1CoreAdapter.ChangeDisc(Index: Integer);
begin
  if (Index < 0) or (Index >= GetDiscCount) then
    raise EArgumentOutOfRangeException.Create('Invalid disc index');
  if Index = FDiscIndex then
    Exit;
  ReplaceDisc(FDiscLocations[Index], Index);
end;

procedure TPS1CoreAdapter.OpenDisc(const Location: string);
begin
  if GetDiscCount = 0 then
    raise EInvalidOpException.Create('This PS1 session has no CD game');
  for var I := 0 to High(FDiscLocations) do
    if FDiscLocations[I] = Location then
    begin
      ChangeDisc(I);
      Exit;
    end;
  var Name := FStorage.Describe(Location).Name;
  var Index := Length(FDiscLocations);
  // Allocate metadata first; a failed load leaves the running session unchanged.
  var Locations := FDiscLocations + TArray<string>.Create(Location);
  var Names := FDiscNames + TArray<string>.Create(Name);
  ReplaceDisc(Location, Index);
  FDiscLocations := Locations;
  FDiscNames := Names;
end;

procedure TPS1CoreAdapter.EjectDisc;
begin
  if (GetDiscCount = 0) or (FDiscIndex < 0) then
    Exit;
  if FWorker <> nil then
    FWorker.ChangeDisc(nil);
  FreeAndNil(FDisc);
  FDiscIndex := -1;
  FIdentity := nil;
end;

// Setting (path or builtin:<name>), else a BIOS beside the game or in the
// ps1 ROM folder, else the built-in BIOS. An explicit file that is not a
// 512 KiB image is an error, never replaced.
procedure TPS1CoreAdapter.LoadBIOS(const RomName: string);
begin
  var Path := FConfigObject.BIOSFile;
  if Path = '' then
    for var Name in BIOSNames do
    begin
      var Candidate := TPath.Combine(ExtractFilePath(RomName), Name);
      if not RomName.StartsWith('content://', True) and FStorage.Exists(Candidate) then
      begin
        Path := Candidate;
        Break;
      end;
      Candidate := TPath.Combine(FStorage.RomFolder(ROM_SYSTEM_PS1), Name);
      if not Candidate.StartsWith('content://', True) and FStorage.Exists(Candidate) then
      begin
        Path := Candidate;
        Break;
      end;
    end;

  if Path = '' then
  begin
    if not HasBuiltinPS1BIOS then
      raise EReadError.Create('Select a PlayStation BIOS in PS1 settings');
    FBIOS := LoadBuiltinPS1BIOS(PS1BuiltinOpenBIOS);
  end
  else if Path.StartsWith('builtin:', True) then
    FBIOS := LoadBuiltinPS1BIOS(Path.Substring(8))
  else
  begin
    FBIOS := FStorage.ReadBytes(Path);
    if Length(FBIOS) <> PS1BIOSSize then
      raise EReadError.CreateFmt('PlayStation BIOS must contain exactly 512 KiB: %s', [Path]);
  end;
end;

procedure TPS1CoreAdapter.Configure;
begin
  if FWorker = nil then
    Exit;

  var Input := GetInputState;
  var Inputs: TPS1PadInputs;
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
    LeftX := LeftX + 32767 * (Ord(Keys[TPS1Extra.LeftRight]) - Ord(Keys[TPS1Extra.LeftLeft]));
    LeftY := LeftY + 32767 * (Ord(Keys[TPS1Extra.LeftDown]) - Ord(Keys[TPS1Extra.LeftUp]));
    RightX := RightX + 32767 * (Ord(Keys[TPS1Extra.RightRight]) - Ord(Keys[TPS1Extra.RightLeft]));
    RightY := RightY + 32767 * (Ord(Keys[TPS1Extra.RightDown]) - Ord(Keys[TPS1Extra.RightUp]));

    var Buttons := Pad.Buttons;
    if Port = 0 then
      Buttons := Buttons or PadBits(Input.Buttons)
    else
      Buttons := Buttons or PadBits(Input.Buttons2);
    if Keys[TPS1Extra.L2] then
      Buttons := Buttons or PS1PadL2;
    if Keys[TPS1Extra.L3] then
      Buttons := Buttons or PS1PadL3;
    if Keys[TPS1Extra.R3] then
      Buttons := Buttons or PS1PadR3;

    Inputs[Port].Buttons := Buttons;
    Inputs[Port].AnalogButton := Pad.AnalogButton or Keys[TPS1Extra.Analog];
    Inputs[Port].Axes[0] := StickByte(RightX);
    Inputs[Port].Axes[1] := StickByte(RightY);
    Inputs[Port].Axes[2] := StickByte(LeftX);
    Inputs[Port].Axes[3] := StickByte(LeftY);
  end;
  FWorker.Configure(Inputs, FPaused, FConfig.AudioEnabled, FConfig.AudioVolume);
end;

procedure TPS1CoreAdapter.Start;
begin
  if FWorker <> nil then
    Exit;

  FWorker := TPS1Worker.Create(FBIOS, FExe, FIdentity, FPAL, FDisc, FStorage, FCardFiles[0], FCardFiles[1],
    FSnapshotDirectory);
  FPorts := LoadCoreInputPorts(FStorage, ROM_SYSTEM_PS1);
  FWorker.InputPorts := FPorts;
  Configure;
  FWorker.Start;
end;

procedure TPS1CoreAdapter.Stop;
begin
  if FWorker = nil then
    Exit;

  FWorker.StopAndSave;
  FError := FWorker.TakeError(False);
  FreeAndNil(FWorker);
end;

procedure TPS1CoreAdapter.Pause;
begin
  FPaused := True;
  Configure;
end;

procedure TPS1CoreAdapter.Resume;
begin
  FPaused := False;
  Configure;
end;

procedure TPS1CoreAdapter.Reset;
begin
  FPaused := False;
  if FWorker <> nil then
    FWorker.RequestReset;
  Configure;
end;

procedure TPS1CoreAdapter.ApplyInputPorts(const Ports: TCoreInputPorts);
begin
  ClearInput;
  if FWorker <> nil then
    FWorker.InputPorts := Ports;
  FPorts := Ports;
end;

procedure TPS1CoreAdapter.ClearInput;
begin
  FKeyboard := Default(TEmulatorInput);
  FGamepad := Default(TEmulatorInput);
  FillChar(FKeyboardExtra, SizeOf(FKeyboardExtra), 0);
  FControllers[0] := Default(TPS1Pad);
  FControllers[1] := Default(TPS1Pad);
  Configure;
end;

procedure TPS1CoreAdapter.SetKeyState(Code: UInt32; Pressed: Boolean);
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
    for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
      if Code = FConfigObject.ExtraKey(Port, Extra) then
        FKeyboardExtra[Port, Extra] := Pressed;
  end;
  Configure;
end;

procedure TPS1CoreAdapter.SetGamepadInput(const Input: TEmulatorInput);
begin
  FGamepad := Input;
  Configure;
end;

procedure TPS1CoreAdapter.SetPS1Controller(Port: Integer; const Pad: TPS1Pad);
begin
  if (Port < 0) or (Port > 1) then
    Exit;
  FControllers[Port] := Pad;
  Configure;
end;

function TPS1CoreAdapter.GetInputState: TEmulatorInput;
begin
  Result := FGamepad;
  Result.Buttons := FKeyboard.Buttons + FGamepad.Buttons;
  Result.Buttons2 := FKeyboard.Buttons2 + FGamepad.Buttons2;
end;

function TPS1CoreAdapter.GetSnapshotDirectory: string;
begin
  Result := FSnapshotDirectory;
end;

procedure TPS1CoreAdapter.SaveSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, False);
end;

procedure TPS1CoreAdapter.LoadSnapshot(const Name: string);
begin
  if FWorker <> nil then
    FWorker.Snapshot(Name, True);
end;

function TPS1CoreAdapter.TryGetFrame(out Frame: TEmulatorFrame): Boolean;
begin
  // Picks up audio setting changes.
  Configure;
  Result := (FWorker <> nil) and FWorker.TryGetFrame(Frame);
end;

function TPS1CoreAdapter.TakeError: string;
begin
  Result := FError;
  FError := '';
  if (Result = '') and (FWorker <> nil) then
    Result := FWorker.TakeError(False);
end;

function TPS1CoreAdapter.TakeAudioError: string;
begin
  Result := '';
  if FWorker <> nil then
    Result := FWorker.TakeError(True);
end;

function TPS1CoreAdapter.GetConfig: IEmulatorConfig;
begin
  Result := FConfig;
end;

function TPS1CoreAdapter.GetSystemId: string;
begin
  Result := ROM_SYSTEM_PS1;
end;

function TPS1CoreAdapter.GetName: string;
begin
  Result := 'PlayStation';
end;

function TPS1CoreAdapter.GetSupportsSnapshots: Boolean;
begin
  Result := True;
end;

function TPS1CoreAdapter.GetUsesSuborKeyboard: Boolean;
begin
  Result := False;
end;

function TPS1CoreAdapter.GetHasCoinAcceptor: Boolean;
begin
  Result := False;
end;

procedure TPS1CoreAdapter.InsertCoin1;
begin
end;

procedure TPS1CoreAdapter.InsertCoin2;
begin
end;

function TPS1CoreAdapter.IsPaused: Boolean;
begin
  Result := FPaused;
end;

function TPS1CoreAdapter.GetHasRumble: Boolean;
begin
  Result := FPorts.Devices[0] = 'pad-analog';
end;

function TPS1CoreAdapter.GetRumbleLevel: Byte;
begin
  Result := 0;
  if GetHasRumble and FConfigObject.Rumble and not FPaused and (FWorker <> nil) then
    Result := FWorker.RumbleLevel;
end;

end.

