unit NES.Emulation;

interface

uses
  Core.Storage, System.Classes, System.SysUtils, System.SyncObjs, NES.Types,
  NES.Console, NES.Input, PCM.Audio, NES.AudioDiagnostics, NES.Controller,
  NES.FamicomKeyboardDevice, NES.FamicomDataRecorder, NES.MiraclePianoDevice;

const
  NES_SAMPLE_RATE = 44100;
  AUDIO_BLOCK_SAMPLES = 1024;
  AUDIO_BLOCK_COUNT = 4;

type
  TEmulationStatus = record
    Region: TNesRegion;
    FrameNumber: UInt64;
    FramesPerSecond: Double;
    AudioQueue: TPCMAudioQueueState;
    AudioError, Error: string;
    TapeState: TTapeState;
    TapeProgress: TTapeProgress;
  end;

  // The core and audio backend belong to Execute after Start. The UI only exchanges
  // input, commands and completed frame copies through FLock; it never runs NES code.
  TNesEmulationThread = class(TThread)
  private
    FConsole: TNesConsole;
    FStorage: IStorage;
    FAudio: TPCMAudio;
    FAudioFormat: TPCMAudioFormat;
    FAudioEnabled: Boolean;
    FAudioVolume: Single;
    FDiagnostics: TAudioDiagnostics;
    FInput: TNesInput;
    FPendingCoins: array[0..1] of Integer;
    FLock: TCriticalSection;
    FWake: TEvent;
    FRomPath: string;
    FSaveDirectory: string;
    FSnapshotDirectory: string;
    FTapeDirectory: string;
    FSelectedTapeFile: string;
    FSnapshotLock: TCriticalSection;
    FSnapshotDone: TEvent;
    FSnapshotPending, FSnapshotLoading: Boolean;
    FSnapshotTape, FUsesDataRecorder: Boolean;
    FTapeAction: TTapeAction;
    FSnapshotName, FSnapshotError: string;
    FPowerPad: array[1..12] of Boolean;
    FScreenPowerPad: TPowerPadButtons;
    FPowerPadShortcuts: array[1..4] of Boolean;
    FResetRequested, FPauseRequested, FResumeRequested: Boolean;
    FFrame: TFrameBuffer;
    FFramePending: Boolean;
    FUsesSuborKeyboard: Boolean;
    FUsesFamicomKeyboard: Boolean;
    FUsesMiraclePiano: Boolean;
    FMiracleKeys: TMiracleKeys;
    FStatus: TEmulationStatus;
    FRunFrameMs: Double;
    FPaused: Boolean;
    procedure RequestCoin(Player: Integer);
    procedure RunEmulation;
    procedure SnapshotCommand(const Name: string; Loading: Boolean);
    procedure WorkerCommand(const Name: string; Loading, Tape: Boolean; Action: TTapeAction);
    function ProcessSnapshot: Boolean;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    // Validates the ROM before replacing the current session. Call Start once.
    constructor Create(const FileName: string; FourScoreEnabled: Boolean = False; RegionOverride: TRegionOverride = TRegionOverride.Auto; AudioEnabled: Boolean = True; AudioVolume: Single = 1; const SaveDirectory: string = ''; const SnapshotRoot: string = ''); overload;
    constructor Create(Stream: TStream; const Storage: IStorage; const RomName: string; FourScoreEnabled: Boolean = False; RegionOverride: TRegionOverride = TRegionOverride.Auto; AudioEnabled: Boolean = True; AudioVolume: Single = 1; const SaveDirectory: string = ''; const SnapshotRoot: string = ''); overload;
    destructor Destroy; override;
    procedure StopAndSave;
    procedure SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2: TKeyMap); overload;
    procedure SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2, Keys3, Keys4: TKeyMap); overload;
    procedure SetSuborKeys(const Keys: TSuborKeys);
    procedure SetMiracleKeys(const Keys: TMiracleKeys);
    function GetMiracleKeys: TMiracleKeys;
    procedure SetFamicomKeys(const Keys: TFamicomKeys);
    function GetFamicomKeys: TFamicomKeys;
    procedure SetPowerPadButtons(const Buttons: TPowerPadButtons);
    procedure GetButtons(out Buttons, Buttons2: TNesButtons);
    function GetSuborKeys: TSuborKeys;
    function GetSuborIndicators: TSuborIndicators;
    function GetPowerPadButtons: TPowerPadButtons;
    procedure ClearInput;
    procedure SetButtons(Source: UInt32; Player: Integer; const Buttons: TNesButtons);
    procedure InsertCoin1;
    procedure InsertCoin2;
    procedure RequestReset;
    procedure RequestPause;
    procedure RequestResume;
    function TakeSnapshot(var Frame: TFrameBuffer; out Status: TEmulationStatus): Boolean;
    procedure SaveDiagnostics(const Prefix: string);
    // Synchronous commands executed by the worker at a frame boundary.
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    procedure TapeCommand(Action: TTapeAction; const FileName: string = '');
    function GetTapeState: TTapeState;
    function GetTapeProgress: TTapeProgress;
    property UsesDataRecorder: Boolean read FUsesDataRecorder;
    property SnapshotDirectory: string read FSnapshotDirectory;
    property RunFrameMs: Double read FRunFrameMs;
    property UsesSuborKeyboard: Boolean read FUsesSuborKeyboard;
    property UsesMiraclePiano: Boolean read FUsesMiraclePiano;
    property UsesFamicomKeyboard: Boolean read FUsesFamicomKeyboard;
    property IsPausd: Boolean read FPaused;
    property Console: TNesConsole read FConsole;
  end;

implementation

uses
  System.Diagnostics, System.Math, System.IOUtils, System.UITypes, NES.Consts,
  Core.SavePaths, Core.PerformanceHints, PCM.Audio.Null;

constructor TNesEmulationThread.Create(const FileName: string; FourScoreEnabled: Boolean; RegionOverride: TRegionOverride; AudioEnabled: Boolean; AudioVolume: Single; const SaveDirectory, SnapshotRoot: string);
begin
  var Storage := TStorage.Default;
  var Stream := Storage.OpenRead(FileName);
  try
    Create(Stream, Storage, FileName, FourScoreEnabled, RegionOverride,
      AudioEnabled, AudioVolume, SaveDirectory, SnapshotRoot);
  finally
    Stream.Free;
  end;
end;

constructor TNesEmulationThread.Create(Stream: TStream; const Storage: IStorage; const RomName: string; FourScoreEnabled: Boolean; RegionOverride: TRegionOverride; AudioEnabled: Boolean; AudioVolume: Single; const SaveDirectory, SnapshotRoot: string);
begin
  inherited Create(True);
  FStorage := Storage;
  if FStorage = nil then
    FStorage := TStorage.Default;
  FreeOnTerminate := False;
  FAudioEnabled := AudioEnabled;
  FAudioVolume := EnsureRange(AudioVolume, 0.0, 1.0);
  FLock := TCriticalSection.Create;
  FSnapshotLock := TCriticalSection.Create;
  FSnapshotDone := TEvent.Create(nil, True, False, '');
  FWake := TEvent.Create(nil, False, False, '');
  FInput := TNesInput.Create;
  FAudioFormat.SampleRate := NES_SAMPLE_RATE;
  FAudioFormat.Channels := 1;
  FAudioFormat.BlockFrames := AUDIO_BLOCK_SAMPLES;
  FAudioFormat.BlockCount := AUDIO_BLOCK_COUNT;
  FDiagnostics := TAudioDiagnostics.Create(FAudioFormat, FStorage);
  FRomPath := RomName;
  FSaveDirectory := SaveDirectory;
  if FSaveDirectory = '' then
    FSaveDirectory := FStorage.SaveRoot;
  FConsole := TNesConsole.Create(FourScoreEnabled, FStorage);
  FConsole.LoadRom(Stream, RomName, RegionOverride);
  FUsesSuborKeyboard := FConsole.SuborKeyboard.Connected;
  FUsesFamicomKeyboard := FConsole.FamicomKeyboard.Connected;
  FUsesMiraclePiano := FConsole.UsesMiraclePiano;
  FUsesDataRecorder := FConsole.DataRecorder.Connected;
  var SnapshotBase := SnapshotRoot;
  if SnapshotBase = '' then
    SnapshotBase := FStorage.SnapshotRoot;
  FSnapshotDirectory := FStorage.GamePath(SnapshotBase, RomName, FConsole.RomIdentity, '');
  FTapeDirectory := FStorage.GamePath(FSaveDirectory, RomName, FConsole.RomIdentity, '');
  if FUsesDataRecorder then
    FConsole.DataRecorder.LoadTape(TPath.Combine(FTapeDirectory, 'data.tape'), True);
  FStatus.TapeProgress := FConsole.DataRecorder.GetProgress;
  FStatus.TapeProgress.DefaultFile := True;
  FStatus.Region := FConsole.Region;
  FConsole.Apu.SetSampleRate(NES_SAMPLE_RATE);
end;

procedure TNesEmulationThread.StopAndSave;
begin
  Terminate;
  if Suspended then
    Start;
  WaitFor;
  // Retry on the caller after joining, propagating any disk error to the UI.
  // Execute's final save also covers owners that just destroy the thread.
  FConsole.SaveBattery;
  FConsole.DataRecorder.Stop;
end;

destructor TNesEmulationThread.Destroy;
begin
  // TThread.Destroy also handles a suspended thread / failed constructor.
  // Wake first, and join before freeing anything Execute can still access.
  Terminate;
  inherited;
  FConsole.Free;
  FDiagnostics.Free;
  FInput.Free;
  FWake.Free;
  FLock.Free;
  FSnapshotDone.Free;
  FSnapshotLock.Free;
end;

procedure TNesEmulationThread.SaveSnapshot(const Name: string);
begin
  SnapshotCommand(Name, False);
end;

procedure TNesEmulationThread.LoadSnapshot(const Name: string);
begin
  SnapshotCommand(Name, True);
end;

procedure TNesEmulationThread.SnapshotCommand(const Name: string; Loading: Boolean);
begin
  // Restrict names to portable slot names; callers cannot escape the game folder.
  if (Name = '') or (Length(Name) > 80) then
    raise EArgumentException.Create('Invalid snapshot name');

  for var C in Name do
    if not CharInSet(C, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      raise EArgumentException.Create('Snapshot names use letters, digits, - and _');

  WorkerCommand(Name, Loading, False, TapeStop);
end;

procedure TNesEmulationThread.TapeCommand(Action: TTapeAction; const FileName: string);
begin
  if not FUsesDataRecorder then
    raise ENesException.Create('No data recorder connected');

  WorkerCommand(FileName, False, True, Action);
end;

function TNesEmulationThread.GetTapeState: TTapeState;
begin
  FLock.Enter;
  try
    Result := FStatus.TapeState;
  finally
    FLock.Leave;
  end;
end;

function TNesEmulationThread.GetTapeProgress: TTapeProgress;
begin
  FLock.Enter;
  try
    Result := FStatus.TapeProgress;
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.WorkerCommand(const Name: string; Loading, Tape: Boolean; Action: TTapeAction);
begin
  FSnapshotLock.Enter;
  try
    if Suspended or Terminated or Finished then
      raise ENesException.Create('Emulation worker is not running');

    FLock.Enter;
    try
      FSnapshotDone.ResetEvent;
      FSnapshotName := Name;
      FSnapshotLoading := Loading;
      FSnapshotTape := Tape;
      FTapeAction := Action;
      FSnapshotError := '';
      FSnapshotPending := True;
    finally
      FLock.Leave;
    end;
    FWake.SetEvent;
    while FSnapshotDone.WaitFor(50) <> wrSignaled do
      if Finished then
        raise ENesException.Create('Emulation stopped before completing the command');

    FLock.Enter;
    try
      if FSnapshotError <> '' then
        raise ENesException.Create(FSnapshotError);
    finally
      FLock.Leave;
    end;
  finally
    FSnapshotLock.Leave;
  end;
end;

function TNesEmulationThread.ProcessSnapshot: Boolean;
begin
  Result := False;
  var Name: string;
  var Loading: Boolean;
  var Tape: Boolean;
  var Action: TTapeAction;
  FLock.Enter;
  try
    if not FSnapshotPending then
      Exit;

    Name := FSnapshotName;
    Loading := FSnapshotLoading;
    Tape := FSnapshotTape;
    Action := FTapeAction;
    FSnapshotPending := False;
  finally
    FLock.Leave;
  end;
  var ErrorText := '';
  try
    if Tape then
    begin
      var TapePath := FSelectedTapeFile;
      if TapePath = '' then
        TapePath := TPath.Combine(FTapeDirectory, 'data.tape');
      case Action of
        TapePlay, TapeRecord:
          begin
            if Name <> '' then
              TapePath := Name;
            if FConsole.DataRecorder.GetProgress.FileName <> TapePath then
              FConsole.DataRecorder.LoadTape(TapePath, Action = TapeRecord);
            if Action = TapePlay then
              FConsole.DataRecorder.ResumeTape
            else
            begin
              FStorage.EnsureFolder(ExtractFilePath(ExpandFileName(TapePath)));
              FConsole.DataRecorder.RecordTape(TapePath);
            end;
          end;
        TapeStop:
          FConsole.DataRecorder.Stop;
        TapeSaveAs:
          FConsole.DataRecorder.SaveCopy(Name);
        TapeRewind, TapeForward:
          begin
            var Progress := FConsole.DataRecorder.GetProgress;
            var Step := Int64(Progress.TapeBytes div 20);
            if Step < 1 then
              Step := 1;
            if Action = TapeRewind then
              Step := -Step;
            FConsole.DataRecorder.SeekRelative(Step);
          end;
        TapeSelectFile:
          begin
            if Name = '' then
              raise ENesException.Create('A cassette filename is required');

            FConsole.DataRecorder.LoadTape(Name, True);
            FSelectedTapeFile := Name;
          end;
        TapeDefaultFile:
          begin
            FConsole.DataRecorder.LoadTape(TPath.Combine(FTapeDirectory, 'data.tape'), True);
            FSelectedTapeFile := '';
          end;
      end;
    end
    else
    begin
      var Path := TPath.Combine(FSnapshotDirectory, Name + '.snapshot');
      if Loading then
      begin
        FConsole.LoadSnapshot(Path);
        FAudio.Clear;
        FLock.Enter;
        try
          FDiagnostics.Clear;
          FFrame := FConsole.Ppu.Frame;
          FFramePending := True;
          FStatus.Error := '';
        finally
          FLock.Leave;
        end;
        Result := True;
      end
      else
        FConsole.SaveSnapshot(Path);
    end;
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  FLock.Enter;
  try
    FSnapshotError := ErrorText;
    FStatus.TapeState := FConsole.DataRecorder.TransportState;
    FStatus.TapeProgress := FConsole.DataRecorder.GetProgress;
    FStatus.TapeProgress.DefaultFile := FSelectedTapeFile = '';
  finally
    FLock.Leave;
  end;
  FSnapshotDone.SetEvent;
end;

procedure TNesEmulationThread.TerminatedSet;
begin
  inherited;
  if FWake <> nil then
    FWake.SetEvent;
end;

procedure TNesEmulationThread.SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2: TKeyMap);
begin
  SetKey(Code, Pressed, Keys, Keys2, Default(TKeyMap), Default(TKeyMap));
end;

procedure TNesEmulationThread.SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2, Keys3, Keys4: TKeyMap);
const
  PadKeys: array[1..12] of UInt32 = (vk1, vk2, vk3, vk4, vk5, vk6, vk7, vk8, vk9, vk0, vkMinus, vkEqual);
begin
  if Code = 0 then
    Exit;

  FLock.Enter;
  try
    if FUsesMiraclePiano then
    begin
      var PianoKey := TMiraclePianoDevice.HostKey(Code);
      if PianoKey >= 0 then
      begin
        if Pressed then Include(FMiracleKeys, TMiracleKey(PianoKey))
        else Exclude(FMiracleKeys, TMiracleKey(PianoKey));
        Exit;
      end;
      // Piano notes own the letter keys. Menu controls stay accessible.
      var MenuKey: TNesButton;
      case Code of
        vkReturn: MenuKey := TNesButton.Start;
        vkTab: MenuKey := TNesButton.Select;
        vkBack: MenuKey := TNesButton.B;
        vkUp: MenuKey := TNesButton.Up;
        vkDown: MenuKey := TNesButton.Down;
        vkLeft: MenuKey := TNesButton.Left;
        vkRight: MenuKey := TNesButton.Right;
      else Exit;
      end;
      FInput.SetButton(INPUT_KEYBOARD, 1, MenuKey, Pressed);
      if Code = vkReturn then
        FInput.SetButton(INPUT_KEYBOARD, 1, TNesButton.A, Pressed);
      Exit;
    end;
    if FUsesSuborKeyboard then
      FConsole.SuborKeyboard.SetHostKey(Code, Pressed);
    if FUsesFamicomKeyboard then
      FConsole.FamicomKeyboard.SetHostKey(Code, Pressed);
    FInput.SetKey(1, Code, Pressed, Keys);
    FInput.SetKey(2, Code, Pressed, Keys2);
    FInput.SetKey(3, Code, Pressed, Keys3);
    FInput.SetKey(4, Code, Pressed, Keys4);
    if Code = Keys.A then
      FPowerPadShortcuts[1] := Pressed;
    if Code = Keys.B then
      FPowerPadShortcuts[2] := Pressed;
    if Code = Keys.Left then
      FPowerPadShortcuts[3] := Pressed;
    if Code = Keys.Right then
      FPowerPadShortcuts[4] := Pressed;
    for var Button := Low(PadKeys) to High(PadKeys) do
      if Code = PadKeys[Button] then
        FPowerPad[Button] := Pressed;
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.SetSuborKeys(const Keys: TSuborKeys);
begin
  FLock.Enter;
  try
    if FUsesSuborKeyboard then
      FConsole.SuborKeyboard.SetScreenKeys(Keys);
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.SetMiracleKeys(const Keys: TMiracleKeys);
begin
  FLock.Enter;
  try
    if FUsesMiraclePiano then FConsole.MiraclePiano.SetScreenKeys(Keys);
  finally FLock.Leave; end;
end;

function TNesEmulationThread.GetMiracleKeys: TMiracleKeys;
begin
  FLock.Enter;
  try
    Result := FMiracleKeys + FConsole.MiraclePiano.GetPressedKeys;
  finally FLock.Leave; end;
end;

procedure TNesEmulationThread.SetFamicomKeys(const Keys: TFamicomKeys);
begin
  FLock.Enter;
  try
    if FUsesFamicomKeyboard then
      FConsole.FamicomKeyboard.SetScreenKeys(Keys);
  finally
    FLock.Leave;
  end;
end;

function TNesEmulationThread.GetFamicomKeys: TFamicomKeys;
begin
  FLock.Enter;
  try
    Result := FConsole.FamicomKeyboard.GetPressedKeys;
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.SetPowerPadButtons(const Buttons: TPowerPadButtons);
begin
  FLock.Enter;
  try
    FScreenPowerPad := Buttons;
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.ClearInput;
begin
  FLock.Enter;
  try
    FInput.Clear;
    FMiracleKeys := [];
    FConsole.MiraclePiano.ClearInput;
    FScreenPowerPad := [];
    FConsole.SuborKeyboard.Clear;
    FConsole.FamicomKeyboard.Clear;
    FillChar(FPowerPad, SizeOf(FPowerPad), 0);
    FillChar(FPowerPadShortcuts, SizeOf(FPowerPadShortcuts), 0);
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.SetButtons(Source: UInt32; Player: Integer; const Buttons: TNesButtons);
begin
  FLock.Enter;
  try
    for var Button := Low(TNesButton) to High(TNesButton) do
      FInput.SetButton(Source, Player, Button, Button in Buttons);
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.GetButtons(out Buttons, Buttons2: TNesButtons);
begin
  FLock.Enter;
  try
    Buttons := [];
    Buttons2 := [];
    for var Button := Low(TNesButton) to High(TNesButton) do
    begin
      if FInput.IsPressed(1, Button) then
        Include(Buttons, Button);
      if FInput.IsPressed(2, Button) then
        Include(Buttons2, Button);
    end;
  finally
    FLock.Leave;
  end;
end;

function TNesEmulationThread.GetSuborKeys: TSuborKeys;
begin
  FLock.Enter;
  try
    Result := FConsole.SuborKeyboard.GetPressedKeys;
  finally
    FLock.Leave;
  end;
end;

function TNesEmulationThread.GetSuborIndicators: TSuborIndicators;
begin
  FLock.Enter;
  try
    Result := FConsole.SuborKeyboard.Indicators;
  finally
    FLock.Leave;
  end;
end;

function TNesEmulationThread.GetPowerPadButtons: TPowerPadButtons;
begin
  FLock.Enter;
  try
    Result := FScreenPowerPad;
    for var Button := Low(FPowerPad) to High(FPowerPad) do
      if FPowerPad[Button] then
        Include(Result, Button);
    for var Button := Low(FPowerPadShortcuts) to High(FPowerPadShortcuts) do
      if FPowerPadShortcuts[Button] then
        Include(Result, Button);
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.RequestCoin(Player: Integer);
begin
  if not FConsole.HasCoinAcceptor then
    Exit;

  FLock.Enter;
  try
    if FPendingCoins[Player] < High(Integer) then
      Inc(FPendingCoins[Player]);
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TNesEmulationThread.InsertCoin1;
begin
  RequestCoin(0);
end;

procedure TNesEmulationThread.InsertCoin2;
begin
  RequestCoin(1);
end;

procedure TNesEmulationThread.RequestReset;
begin
  FLock.Enter;
  try
    FillChar(FPendingCoins, SizeOf(FPendingCoins), 0);
    FResetRequested := True;
    FPauseRequested := False;
    FResumeRequested := False;
    FStatus.Error := '';
    FFramePending := False;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TNesEmulationThread.RequestPause;
begin
  FLock.Enter;
  try
    FPauseRequested := True;
    FResumeRequested := False;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TNesEmulationThread.RequestResume;
begin
  FLock.Enter;
  try
    FResumeRequested := True;
    FPauseRequested := False;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TNesEmulationThread.TakeSnapshot(var Frame: TFrameBuffer; out Status: TEmulationStatus): Boolean;
begin
  FLock.Enter;
  try
    Status := FStatus;
    Result := FFramePending;
    if Result then
    begin
      Frame := FFrame;
      FFramePending := False;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TNesEmulationThread.SaveDiagnostics(const Prefix: string);
begin
  var Snapshot: TAudioDiagnostics;
  var AudioError: string;
  FLock.Enter;
  try
    Snapshot := FDiagnostics.Clone;
    AudioError := FStatus.AudioError;
  finally
    FLock.Leave;
  end;
  try
    // File I/O never blocks the emulation thread.
    Snapshot.Save(Prefix, FRomPath, AudioError);
  finally
    Snapshot.Free;
  end;
end;

procedure TNesEmulationThread.Execute;
begin
  if Terminated then
    Exit;

  try
    FConsole.LoadBattery(FSaveDirectory);
    try
      // Native backends may require initialization and teardown on the same thread.
      if FAudioEnabled then
        FAudio := TPCMAudio.Create(FAudioFormat)
      else
        FAudio := TPCMAudio.Create(FAudioFormat, TPCMAudioBackendNull.Create(FAudioFormat));
      try
        FLock.Enter;
        try
          FStatus.AudioError := FAudio.Error;
          FStatus.AudioQueue := FAudio.QueueState;
          FStatus.TapeState := FConsole.DataRecorder.TransportState;
          FStatus.TapeProgress := FConsole.DataRecorder.GetProgress;
          FStatus.TapeProgress.DefaultFile := FSelectedTapeFile = '';
        finally
          FLock.Leave;
        end;
        RunEmulation;
      finally
        FreeAndNil(FAudio);
      end;
    finally
      FConsole.SaveBattery;
      FConsole.DataRecorder.Stop;
    end;
  except
    on E: Exception do
    begin
      FLock.Enter;
      try
        FStatus.Error := E.Message;
      finally
        FLock.Leave;
      end;
    end;
  end;
end;

procedure TNesEmulationThread.RunEmulation;
begin
  var Samples: TArray<SmallInt>;
  SetLength(Samples, FAudioFormat.BlockFrames);
  var FramePeriod := Round(TStopwatch.Frequency / FrameRate(FConsole.Region));
  var NextFrame := TStopwatch.GetTimeStamp;
  var FpsStart := NextFrame;
  var Frames := 0;
  FPaused := False;
  var Failed := False;
  var NextSave := TStopwatch.GetTimeStamp + TStopwatch.Frequency * 5;
  var FrameHints := TEmulationPerformanceHints.Create(Round(1000000000.0 / FrameRate(FConsole.Region)), 'NES');
  try
    while not Terminated do
    begin
      try
        if ProcessSnapshot then
        begin
          FrameHints.Pause;
          NextFrame := TStopwatch.GetTimeStamp;
          FpsStart := NextFrame;
          Frames := 0;
          if Failed then
            FPaused := False;
          Failed := False;
        end;
        var PianoKeys: TMiracleKeys;
        var ResetRequested: Boolean;
        var PauseRequested: Boolean;
        var ResumeRequested: Boolean;
        FLock.Enter;
        try
          ResetRequested := FResetRequested;
          FResetRequested := False;
          PauseRequested := FPauseRequested;
          FPauseRequested := False;
          ResumeRequested := FResumeRequested;
          FResumeRequested := False;
          FInput.Apply(1, FConsole.Controller1);
          FInput.Apply(2, FConsole.Controller2);
          if FUsesMiraclePiano then
          begin
            for var Button := Low(TNesButton) to High(TNesButton) do
              FConsole.Controller2.SetButton(Button, FInput.IsPressed(1, Button) or FInput.IsPressed(2, Button));
          end;
          PianoKeys := FMiracleKeys + FConsole.MiraclePiano.GetPressedKeys;
          FInput.Apply(3, FConsole.Controller3);
          FInput.Apply(4, FConsole.Controller4);
          for var Button := Low(FPowerPad) to High(FPowerPad) do
          begin
            var PadPressed := FPowerPad[Button] or (Button in FScreenPowerPad);
            if Button <= High(FPowerPadShortcuts) then
              PadPressed := PadPressed or FPowerPadShortcuts[Button];
            FConsole.Controller2.SetPowerPadButton(Button, PadPressed);
          end;
        finally
          FLock.Leave;
        end;
        if ResetRequested then
        begin
          FrameHints.Pause;
          FAudio.Clear;
          FConsole.Reset;
          FLock.Enter;
          try
            FDiagnostics.Clear;
            FStatus := Default(TEmulationStatus);
            FStatus.Region := FConsole.Region;
            FStatus.AudioError := FAudio.Error;
            FFramePending := False;
          finally
            FLock.Leave;
          end;
          NextFrame := TStopwatch.GetTimeStamp;
          FpsStart := NextFrame;
          Frames := 0;
          FPaused := False;
          Failed := False;
        end;
        if ResumeRequested and FPaused and not Failed then
        begin
          FPaused := False;
          NextFrame := TStopwatch.GetTimeStamp;
          FpsStart := NextFrame;
          Frames := 0;
        end;
        if PauseRequested then
        begin
          FrameHints.Pause;
          FAudio.Clear;
          FPaused := True;
          FConsole.SaveBattery;
        end;
        if FPaused then
        begin
          FrameHints.Pause;
          FWake.WaitFor(INFINITE);
          Continue;
        end;

        var ClockNow := TStopwatch.GetTimeStamp;
        if ClockNow < NextFrame then
        begin
          FWake.WaitFor(Cardinal(Max(Int64(1), (NextFrame - ClockNow) * 1000 div TStopwatch.Frequency)));
          Continue;
        end;

        if Terminated then
          Break;

        FrameHints.TargetDurationNanos := Round(1000000000.0 / FrameRate(FConsole.Region));
        FrameHints.BeginWork;
        // Consume one request per slot per emulated frame. Pausing keeps requests.
        FLock.Enter;
        try
          if FPendingCoins[0] > 0 then
          begin
            FConsole.InsertCoin1;
            Dec(FPendingCoins[0]);
          end;
          if FPendingCoins[1] > 0 then
          begin
            FConsole.InsertCoin2;
            Dec(FPendingCoins[1]);
          end;
        finally
          FLock.Leave;
        end;
        if FUsesMiraclePiano then FConsole.MiraclePiano.ApplyKeys(PianoKeys);
        var T1 := TStopwatch.GetTimeStamp;
        FConsole.RunFrame;
        var T2 := TStopwatch.GetTimeStamp;
        FRunFrameMs := (T2 - T1) * 1000.0 / TStopwatch.Frequency;
        var Count: Integer;
        repeat
          Count := FConsole.Apu.PopSamples(Samples);
          if Count > 0 then
          begin
            if FUsesMiraclePiano then FConsole.MiraclePiano.MixAudio(Samples, Count, NES_SAMPLE_RATE);
            for var I := 0 to Count - 1 do
              Samples[I] := Round(Samples[I] * FAudioVolume);
            FAudio.Submit(Samples, Count);
            FLock.Enter;
            try
              FDiagnostics.Capture(FConsole, FAudio, Samples, Count);
            finally
              FLock.Leave;
            end;
          end;
        until Count = 0;
        FrameHints.EndWork;
        Inc(Frames);
        ClockNow := TStopwatch.GetTimeStamp;
        if ClockNow >= NextSave then
        begin
          FConsole.SaveBattery;
          NextSave := ClockNow + TStopwatch.Frequency * 5;
        end;
        FLock.Enter;
        try
          // One bounded mailbox: a slow UI skips old frames instead of queuing them.
          FFrame := FConsole.Ppu.Frame;
          FFramePending := True;
          Inc(FStatus.FrameNumber);
          FStatus.TapeProgress := FConsole.DataRecorder.GetProgress;
          FStatus.TapeProgress.DefaultFile := FSelectedTapeFile = '';
          FStatus.TapeState := FConsole.DataRecorder.TransportState;
          FStatus.AudioError := FAudio.Error;
          FStatus.AudioQueue := FAudio.QueueState;
          if ClockNow - FpsStart >= TStopwatch.Frequency then
          begin
            FStatus.FramesPerSecond := Frames * TStopwatch.Frequency / (ClockNow - FpsStart);
            Frames := 0;
            FpsStart := ClockNow;
          end;
        finally
          FLock.Leave;
        end;
        Inc(NextFrame, FramePeriod);
        // Discard stale deadlines without adding an idle frame when already late.
        if ClockNow - NextFrame > FramePeriod * 3 then
          NextFrame := ClockNow;
      except
        on E: Exception do
        begin
          FrameHints.Pause;
          FAudio.Clear;
          FPaused := True;
          FLock.Enter;
          Failed := True;
          try
            // A reset submitted during the failed frame supersedes its error.
            if not FResetRequested then
              FStatus.Error := E.Message;
          finally
            FLock.Leave;
          end;
        end;
      end;
    end;
  finally
    FrameHints.Free;
  end;
end;

end.

