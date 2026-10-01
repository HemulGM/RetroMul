unit NES.Emulation;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs, NES.Types, NES.Console,
  NES.Input, PCM.Audio, NES.AudioDiagnostics, NES.Controller;

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
  end;

  // The core and audio backend belong to Execute after Start. The UI only exchanges
  // input, commands and completed frame copies through FLock; it never runs NES code.
  TNesEmulationThread = class(TThread)
  private
    FConsole: TNesConsole;
    FAudio: TPCMAudio;
    FAudioFormat: TPCMAudioFormat;
    FAudioEnabled: Boolean;
    FAudioVolume: Single;
    FDiagnostics: TAudioDiagnostics;
    FInput: TNesInput;
    FLock: TCriticalSection;
    FWake: TEvent;
    FRomPath: string;
    FSaveDirectory: string;
    FSnapshotDirectory: string;
    FSnapshotLock: TCriticalSection;
    FSnapshotDone: TEvent;
    FSnapshotPending, FSnapshotLoading: Boolean;
    FSnapshotName, FSnapshotError: string;
    FPowerPad: array[1..12] of Boolean;
    FPowerPadShortcuts: array[1..4] of Boolean;
    FResetRequested, FPauseRequested, FResumeRequested: Boolean;
    FFrame: TFrameBuffer;
    FFramePending: Boolean;
    FUsesSuborKeyboard: Boolean;
    FStatus: TEmulationStatus;
    FRunFrameMs: Double;
    FPaused: Boolean;
    procedure RunEmulation;
    procedure SnapshotCommand(const Name: string; Loading: Boolean);
    function ProcessSnapshot: Boolean;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    // Validates the ROM before replacing the current session. Call Start once.
    constructor Create(const FileName: string; FourScoreEnabled: Boolean = False; RegionOverride: TRegionOverride = TRegionOverride.Auto; AudioEnabled: Boolean = True; AudioVolume: Single = 1; const SaveDirectory: string = ''; const SnapshotRoot: string = '');
    destructor Destroy; override;
    procedure StopAndSave;
    procedure SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2: TKeyMap); overload;
    procedure SetKey(Code: UInt32; Pressed: Boolean; const Keys, Keys2, Keys3, Keys4: TKeyMap); overload;
    procedure SetSuborKeys(const Keys: TSuborKeys);
    procedure ClearInput;
    procedure SetButtons(Source: UInt32; Player: Integer; const Buttons: TNesButtons);
    procedure RequestReset;
    procedure RequestPause;
    procedure RequestResume;
    function TakeSnapshot(var Frame: TFrameBuffer; out Status: TEmulationStatus): Boolean;
    procedure SaveDiagnostics(const Prefix: string);
    // Synchronous commands executed by the worker at a frame boundary.
    procedure SaveSnapshot(const Name: string);
    procedure LoadSnapshot(const Name: string);
    property SnapshotDirectory: string read FSnapshotDirectory;
    property RunFrameMs: Double read FRunFrameMs;
    property UsesSuborKeyboard: Boolean read FUsesSuborKeyboard;
    property IsPausd: Boolean read FPaused;
    property Console: TNesConsole read FConsole;
  end;

implementation

uses
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNIBridge, Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Os,
  {$ENDIF}
  System.Diagnostics, System.Math, System.IOUtils, NES.Consts, Core.SavePaths,
  PCM.Audio.Null;

{$IFDEF ANDROID}

const
  ANDROID_THREAD_PRIORITY_URGENT_AUDIO = -19;
  ANDROID_THREAD_PRIORITY_AUDIO = -16;
  ANDROID_THREAD_PRIORITY_URGENT_DISPLAY = -8;
  ANDROID_THREAD_PRIORITY_DISPLAY = -4;
  ANDROID_THREAD_PRIORITY_FOREGROUND = -2;
  ANDROID_THREAD_PRIORITY_DEFAULT = 0;
  ANDROID_THREAD_PRIORITY_BACKGROUND = 10;
  ANDROID_THREAD_PRIORITY_LOWEST = 19;

type
  // Java API is available from Android 12 (the native API needs Android 13).
  [JavaSignature('android/os/PerformanceHintManager$Session')]
  JNesHintSession = interface(IJavaInstance)
    ['{3FDDC238-C7FA-423C-BDAA-650E68791F85}']
    procedure reportActualWorkDuration(actualDurationNanos: Int64); cdecl;
    procedure close; cdecl;
  end;

  JNesHintManagerClass = interface(JObjectClass)
    ['{22FC8E24-BA27-4AE5-A350-A4DB0B4F7A53}']
  end;

  [JavaSignature('android/os/PerformanceHintManager')]
  JNesHintManager = interface(JObject)
    ['{DD96F349-F4DD-4710-BF21-54D1A1A17C61}']
    function createHintSession(tids: TJavaArray<Integer>; initialTargetWorkDurationNanos: Int64): JNesHintSession; cdecl;
  end;

  TJNesHintManager = class(TJavaGenericImport<JNesHintManagerClass, JNesHintManager>);

  JNesProcessClass = interface(JObjectClass)
    ['{932F55BF-E2E8-40E5-9DAE-0B66840CDBA9}']
    function myTid: Integer; cdecl;
    procedure setThreadPriority(priority: Integer); cdecl;
  end;

  [JavaSignature('android/os/Process')]
  JNesProcess = interface(JObject)
    ['{C315F8A1-388B-44C2-B6A2-12ED8FD1531F}']
  end;

  TJNesProcess = class(TJavaGenericImport<JNesProcessClass, JNesProcess>);

  // Owned and called exclusively by the emulation worker, including teardown.
  TNesFrameHints = class
  private
    FManager: JNesHintManager;
    FSession: JNesHintSession;
    FTargetNanos, FStart: Int64;
  public
    constructor Create(TargetNanos: Int64);
    destructor Destroy; override;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Pause;
  end;

constructor TNesFrameHints.Create(TargetNanos: Int64);
begin
  inherited Create;
  FTargetNanos := TargetNanos;
  if TJBuild_VERSION.JavaClass.SDK_INT < 31 then
    Exit;
  try
    var Service := TAndroidHelper.Context.getSystemService(StringToJString('performance_hint'));
    if Service <> nil then
      FManager := TJNesHintManager.Wrap((Service as ILocalObject).GetObjectID);
  except
    // Optional scheduling advice must never prevent a game from running.
    FManager := nil;
  end;
end;

destructor TNesFrameHints.Destroy;
begin
  Pause;
  inherited;
end;

procedure TNesFrameHints.Pause;
begin
  if FSession <> nil then
  try
    FSession.close;
  except
    FManager := nil;
  end;
  FSession := nil;
end;

procedure TNesFrameHints.BeginFrame;
begin
  if FManager = nil then
    Exit;
  if FSession = nil then
  try
    var Tids := TJavaArray<Integer>.Create(1);
    try
      // TThread.ThreadID is a pthread handle, not Android's Linux thread ID.
      Tids[0] := TJNesProcess.JavaClass.myTid;
      FSession := FManager.createHintSession(Tids, FTargetNanos);
      if FSession = nil then
        FManager := nil; // Unsupported device: do not retry on every frame.
    finally
      Tids.Free;
    end;
  except
    FManager := nil;
  end;
  FStart := TStopwatch.GetTimeStamp;
end;

procedure TNesFrameHints.EndFrame;
begin
  if FSession = nil then
    Exit;
  try
    var Elapsed := TStopwatch.GetTimeStamp - FStart;
    FSession.reportActualWorkDuration(Max(Int64(1), Round(Elapsed * (1000000000.0 / TStopwatch.Frequency))));
  except
    Pause;
    FManager := nil;
  end;
end;
{$ENDIF}

constructor TNesEmulationThread.Create(const FileName: string; FourScoreEnabled: Boolean; RegionOverride: TRegionOverride; AudioEnabled: Boolean; AudioVolume: Single; const SaveDirectory, SnapshotRoot: string);
begin
  inherited Create(True);
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
  FDiagnostics := TAudioDiagnostics.Create(FAudioFormat);
  FRomPath := FileName;
  FSaveDirectory := SaveDirectory;
  if FSaveDirectory = '' then
    FSaveDirectory := GetSaveDirectory;
  FConsole := TNesConsole.Create(FourScoreEnabled);
  FConsole.LoadRom(FileName, RegionOverride);
  FUsesSuborKeyboard := FConsole.SuborKeyboard.Connected;
  var SnapshotBase := SnapshotRoot;
  if SnapshotBase = '' then
    SnapshotBase := GetSnapshotDirectory;
  FSnapshotDirectory := ResolveGameSavePath(SnapshotBase, FileName, FConsole.RomIdentity, '');
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
  FSnapshotLock.Enter;
  try
    if Suspended or Terminated or Finished then
      raise ENesException.Create('Emulation worker is not running');
    FLock.Enter;
    try
      FSnapshotDone.ResetEvent;
      FSnapshotName := Name;
      FSnapshotLoading := Loading;
      FSnapshotError := '';
      FSnapshotPending := True;
    finally
      FLock.Leave;
    end;
    FWake.SetEvent;
    while FSnapshotDone.WaitFor(50) <> wrSignaled do
      if Finished then
        raise ENesException.Create('Emulation stopped before completing the snapshot');
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
  FLock.Enter;
  try
    if not FSnapshotPending then
      Exit;
    Name := FSnapshotName;
    Loading := FSnapshotLoading;
    FSnapshotPending := False;
  finally
    FLock.Leave;
  end;
  var ErrorText := '';
  try
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
  except
    on E: Exception do
      ErrorText := E.Message;
  end;
  FLock.Enter;
  try
    FSnapshotError := ErrorText;
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
  PadKeys: array[1..12] of UInt32 = ($31, $32, $33, $34, $35, $36,
    $37, $38, $39, $30, $BD, $BB); // 1..9, 0, minus, equals.
begin
  if Code = 0 then
    Exit;
  FLock.Enter;
  try
    if FUsesSuborKeyboard then
      FConsole.SuborKeyboard.SetHostKey(Code, Pressed);
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

procedure TNesEmulationThread.ClearInput;
begin
  FLock.Enter;
  try
    FInput.Clear;
    FConsole.SuborKeyboard.Clear;
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

procedure TNesEmulationThread.RequestReset;
begin
  FLock.Enter;
  try
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
        finally
          FLock.Leave;
        end;
        RunEmulation;
      finally
        FreeAndNil(FAudio);
      end;
    finally
      FConsole.SaveBattery;
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
  {$IFDEF ANDROID}
  //var FrameHints := TNesFrameHints.Create(Round(1000000000.0 / FrameRate(FConsole.Region)));
  try
  {$ENDIF}
    while not Terminated do
    begin
      try
        if ProcessSnapshot then
        begin
          NextFrame := TStopwatch.GetTimeStamp;
          FpsStart := NextFrame;
          Frames := 0;
          if Failed then
            FPaused := False;
          Failed := False;
        end;
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
          FInput.Apply(3, FConsole.Controller3);
          FInput.Apply(4, FConsole.Controller4);
          for var Button := Low(FPowerPad) to High(FPowerPad) do
          begin
            var PadPressed := FPowerPad[Button];
            if Button <= High(FPowerPadShortcuts) then
              PadPressed := PadPressed or FPowerPadShortcuts[Button];
            FConsole.Controller2.SetPowerPadButton(Button, PadPressed);
          end;
        finally
          FLock.Leave;
        end;
        if ResetRequested then
        begin
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
          FAudio.Clear;
          FPaused := True;
          FConsole.SaveBattery;
        end;
        if FPaused then
        begin
          //{$IFDEF ANDROID}
          //FrameHints.Pause;
          //{$ENDIF}
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
        //{$IFDEF ANDROID}
        // Report frame work only, excluding the frame limiter and paused time.
        //FrameHints.BeginFrame;
        //{$ENDIF}
        var T1 := TStopwatch.GetTimeStamp;
        FConsole.RunFrame;
        var T2 := TStopwatch.GetTimeStamp;
        FRunFrameMs := (T2 - T1) * 1000.0 / TStopwatch.Frequency;
        var Count: Integer;
        repeat
          Count := FConsole.Apu.PopSamples(Samples);
          if Count > 0 then
          begin
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
        //{$IFDEF ANDROID}
        //FrameHints.EndFrame;
        //{$ENDIF}
        Inc(NextFrame, FramePeriod);
        // Bound catch-up after debugging or an unusually slow frame.
        if ClockNow - NextFrame > FramePeriod * 3 then
          NextFrame := ClockNow + FramePeriod;
      except
        on E: Exception do
        begin
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
  {$IFDEF ANDROID}
  finally
    //FrameHints.Free;
  end;
  {$ENDIF}
end;

end.

