unit Core.PerformanceHints;

interface

uses
  System.SyncObjs;

type
  {$IFDEF ANDROID}
  TEmulationCpuMask = array[0..15] of UInt64;
  {$ENDIF}
  // Create, use and destroy on the worker. Own the Windows timer resolution here.

  TEmulationPerformanceHints = class
  private
    {$IFDEF ANDROID}
    FManager, FSession: IInterface;
    FStart, FWorkTicks: Int64;
    FWorking: Boolean;
    FOriginalCpuMask, FFastCpuMask: TEmulationCpuMask;
    FAffinityPrepared, FAffinityAttempted, FAffinityApplied: Boolean;
    FSlowSince: Int64;
    {$ENDIF}
    {$IFDEF MSWINDOWS}
    FTimer: NativeUInt;
    FTimerPeriodActive: Boolean;
    {$ENDIF}
    FName: string;
    FTargetNanos: Int64;
    {$IFDEF ANDROID}
    procedure Log(const Message: string);
    procedure Disable(const Reason: string);
    procedure PrepareCpuAffinity;
    procedure ObserveWork(WorkNanos: Int64);
    {$ENDIF}
    procedure SetTargetDurationNanos(Value: Int64);
  public
    constructor Create(TargetNanos: Int64; const Name: string);
    destructor Destroy; override;
    // True means a command/stop woke the worker before the deadline.
    function WaitUntil(Wake: TEvent; Deadline: Int64): Boolean;
    procedure BeginWork;
    // False accumulates a segment; True reports all segments since the last report.
    // End every segment before sleeping; this excludes limiter/paused time.
    procedure EndWork(CompletePeriod: Boolean = True);
    // Closes the session and discards unfinished work. BeginWork recreates it.
    procedure Pause;
    property TargetDurationNanos: Int64 read FTargetNanos write SetTargetDurationNanos;
  end;

implementation

uses
  System.SysUtils, System.Diagnostics,
  {$IFDEF MSWINDOWS}
  Winapi.Windows, Winapi.MMSystem,
  {$ENDIF}
  {$IFDEF ANDROID}
  System.IOUtils, System.Classes, Androidapi.Helpers, Androidapi.JNIBridge,
  Androidapi.JNI.JavaTypes, Androidapi.JNI.Os, Androidapi.Log,
  {$ENDIF}
  System.Math;

{$IFDEF ANDROID}
type
  [JavaSignature('android/os/PerformanceHintManager$Session')]
  JEmulationHintSession = interface(JObject)
    ['{3FDDC238-C7FA-423C-BDAA-650E68791F85}']
    procedure reportActualWorkDuration(actualDurationNanos: Int64); cdecl;
    procedure updateTargetWorkDuration(targetDurationNanos: Int64); cdecl;
    procedure close; cdecl;
  end;

  JEmulationHintManagerClass = interface(JObjectClass)
    ['{22FC8E24-BA27-4AE5-A350-A4DB0B4F7A53}']
  end;

  [JavaSignature('android/os/PerformanceHintManager')]
  JEmulationHintManager = interface(JObject)
    ['{DD96F349-F4DD-4710-BF21-54D1A1A17C61}']
    function createHintSession(tids: TJavaArray<Integer>; initialTargetWorkDurationNanos: Int64): JEmulationHintSession; cdecl;
  end;

  TJEmulationHintManager = class(TJavaGenericImport<JEmulationHintManagerClass, JEmulationHintManager>);

  JEmulationProcessClass = interface(JObjectClass)
    ['{932F55BF-E2E8-40E5-9DAE-0B66840CDBA9}']
    function myTid: Integer; cdecl;
  end;

  [JavaSignature('android/os/Process')]
  JEmulationProcess = interface(JObject)
    ['{C315F8A1-388B-44C2-B6A2-12ED8FD1531F}']
  end;

  TJEmulationProcess = class(TJavaGenericImport<JEmulationProcessClass, JEmulationProcess>);

function AndroidGetAffinity(tid: Integer; size: NativeUInt; mask: Pointer): Integer; cdecl; external 'libc.so' name 'sched_getaffinity';

function AndroidSetAffinity(tid: Integer; size: NativeUInt; mask: Pointer): Integer; cdecl; external 'libc.so' name 'sched_setaffinity';
{$ENDIF}

constructor TEmulationPerformanceHints.Create(TargetNanos: Int64; const Name: string);
begin
  inherited Create;
  FName := Name;
  SetTargetDurationNanos(TargetNanos);
  {$IFDEF MSWINDOWS}
  // High-resolution waitable timers do not rely on message processing or the
  // system clock tick. The flag is supported since Windows 10 version 1803.
  FTimer := CreateWaitableTimerEx(nil, nil, $00000002 { HIGH_RESOLUTION },
    $00100002 { SYNCHRONIZE or TIMER_MODIFY_STATE });
  if FTimer = 0 then
    FTimerPeriodActive := timeBeginPeriod(1) = TIMERR_NOERROR;
  {$ENDIF}
  {$IFDEF ANDROID}
  try
    if TJBuild_VERSION.JavaClass.SDK_INT < 31 then
      Exit;
    var Service := TAndroidHelper.Context.getSystemService(StringToJString('performance_hint'));
    if Service <> nil then
      FManager := TJEmulationHintManager.Wrap((Service as ILocalObject).GetObjectID)
    else
      Log('performance_hint service unavailable');
  except
    on E: Exception do
      Disable('initialization failed: ' + E.Message);
  end;
  {$ENDIF}
end;

destructor TEmulationPerformanceHints.Destroy;
begin
  Pause;
  {$IFDEF MSWINDOWS}
  if FTimer <> 0 then
    CloseHandle(FTimer);
  if FTimerPeriodActive then
    timeEndPeriod(1);
  {$ENDIF}
  inherited;
end;

function TEmulationPerformanceHints.WaitUntil(Wake: TEvent; Deadline: Int64): Boolean;
begin
  Result := False;
  repeat
    var Remaining := Deadline - TStopwatch.GetTimeStamp;
    if Remaining <= 0 then
      Exit;
    {$IFDEF MSWINDOWS}
    if FTimer <> 0 then
    begin
      var Due: TLargeInteger := -Max(Int64(1), Ceil(Remaining * (10000000.0 / TStopwatch.Frequency)));
      if not SetWaitableTimer(FTimer, Due, 0, nil, nil, False) then
        RaiseLastOSError;
      var Handles: array[0..1] of THandle;
      Handles[0] := Wake.Handle;
      Handles[1] := FTimer;
      case WaitForMultipleObjects(2, @Handles[0], False, INFINITE) of
        WAIT_OBJECT_0:
          Exit(True);
        WAIT_OBJECT_0 + 1:
          Continue;
      else
        RaiseLastOSError;
      end;
    end;
    {$ENDIF}
    // Round up and recheck: frames must never start early. Commands still wake
    // the worker immediately; neither sleeping nor pacing depends on UI messages.
    var WaitMS := Cardinal(Max(Int64(1), Ceil(Remaining * (1000.0 / TStopwatch.Frequency))));
    case Wake.WaitFor(WaitMS) of
      wrSignaled:
        Exit(True);
      wrError:
        raise EOSError.Create('Frame pacing wait failed');
    end;
  until False;
end;

{$IFDEF ANDROID}
procedure TEmulationPerformanceHints.Log(const Message: string);
begin
  var Text := UTF8String(FName + ': ' + Message);
  __android_log_write(android_LogPriority.ANDROID_LOG_INFO,
    'RetroMul.Hints', MarshaledAString(Text));
end;

procedure TEmulationPerformanceHints.Disable(const Reason: string);
begin
  Log(Reason);
  Pause;
  FManager := nil; // Do not retry unsupported/failed APIs on every frame.
end;

procedure TEmulationPerformanceHints.PrepareCpuAffinity;
begin
  FAffinityPrepared := True;
  FAffinityAttempted := True; // Unsupported discovery must not repeat per frame.
  FillChar(FFastCpuMask, SizeOf(FFastCpuMask), 0);
  if AndroidGetAffinity(0, SizeOf(FOriginalCpuMask), @FOriginalCpuMask) <> 0 then
    Exit;
  try
    var BestCapacity := 0;
    for var Cpu := 0 to High(FOriginalCpuMask) * 64 + 63 do
    begin
      var Bit := UInt64(1) shl (Cpu and 63);
      if (FOriginalCpuMask[Cpu div 64] and Bit) = 0 then
        Continue;
      var Path := Format('/sys/devices/system/cpu/cpu%d/cpu_capacity', [Cpu]);
      var Capacity := 0;
      if not TFile.Exists(Path) then
        Continue;
      // sysfs advertises a page-sized file, but returns only one short line.
      var Reader := TStreamReader.Create(Path);
      try
        TryStrToInt(Reader.ReadLine.Trim, Capacity);
      finally
        Reader.Free;
      end;
      if Capacity <= 0 then
        Continue;
      if Capacity > BestCapacity then
      begin
        BestCapacity := Capacity;
        FillChar(FFastCpuMask, SizeOf(FFastCpuMask), 0);
      end;
      if Capacity = BestCapacity then
        FFastCpuMask[Cpu div 64] := FFastCpuMask[Cpu div 64] or Bit;
    end;
    // Homogeneous/unknown CPUs keep the scheduler's original placement.
    FAffinityAttempted := (BestCapacity = 0) or
      CompareMem(@FFastCpuMask, @FOriginalCpuMask, SizeOf(FFastCpuMask));
  except
    on E: Exception do
      Log('CPU capacity unavailable: ' + E.Message);
  end;
end;

procedure TEmulationPerformanceHints.ObserveWork(WorkNanos: Int64);
begin
  if FAffinityAttempted then
    Exit;
  // First let ADPF react. Ignore short startup spikes and normal frame jitter.
  if WorkNanos <= FTargetNanos * 1.05 then
  begin
    FSlowSince := 0;
    Exit;
  end;
  var Now := TStopwatch.GetTimeStamp;
  if FSlowSince = 0 then
    FSlowSince := Now;
  if Now - FSlowSince < TStopwatch.Frequency div 2 then
    Exit;
  FAffinityAttempted := True;
  FAffinityApplied := AndroidSetAffinity(0, SizeOf(FFastCpuMask), @FFastCpuMask) = 0;
  if FAffinityApplied then
    Log('frame budget missed: selected highest-capacity allowed CPUs')
  else
    Log('CPU affinity unavailable; retaining system placement');
end;
{$ENDIF}

procedure TEmulationPerformanceHints.SetTargetDurationNanos(Value: Int64);
begin
  if Value <= 0 then
    raise EArgumentOutOfRangeException.Create('Performance hint target must be positive');
  if FTargetNanos = Value then
    Exit;
  FTargetNanos := Value;
  {$IFDEF ANDROID}
  if FSession <> nil then
  try
    (FSession as JEmulationHintSession).updateTargetWorkDuration(Value);
  except
    on E: Exception do
      Disable('target update failed: ' + E.Message);
  end;
  {$ENDIF}
end;

procedure TEmulationPerformanceHints.Pause;
begin
  {$IFDEF ANDROID}
  FWorking := False;
  FWorkTicks := 0;
  FSlowSince := 0;
  if FAffinityApplied then
  begin
    if AndroidSetAffinity(0, SizeOf(FOriginalCpuMask), @FOriginalCpuMask) = 0 then
      FAffinityApplied := False
    else
      Log('could not restore CPU affinity');
  end;
  // Keep the saved mask if restoring failed; do not overwrite it on resume.
  if not FAffinityApplied then
    FAffinityPrepared := False;
  if FSession <> nil then
  try
    (FSession as JEmulationHintSession).close;
    Log('session closed');
  except
    on E: Exception do
    begin
      Log('session close failed: ' + E.Message);
      FManager := nil;
    end;
  end;
  FSession := nil;
  {$ENDIF}
end;

procedure TEmulationPerformanceHints.BeginWork;
begin
  {$IFDEF ANDROID}
  if FWorking then
    Exit;
  if not FAffinityPrepared then
    PrepareCpuAffinity;
  if (FManager <> nil) and (FSession = nil) then
  try
    var Tids := TJavaArray<Integer>.Create(1);
    try
      // Android requires the Linux TID, not Delphi's pthread ThreadID.
      Tids[0] := TJEmulationProcess.JavaClass.myTid;
      FSession := (FManager as JEmulationHintManager).createHintSession(Tids, FTargetNanos);
      if FSession = nil then
      begin
        Disable('session unsupported');
        Exit;
      end;
      Log(Format('session created, tid=%d, target=%d ns', [Tids[0], FTargetNanos]));
    finally
      Tids.Free;
    end;
  except
    on E: Exception do
    begin
      Disable('session creation failed: ' + E.Message);
      Exit;
    end;
  end;
  FStart := TStopwatch.GetTimeStamp;
  FWorking := True;
  {$ENDIF}
end;

procedure TEmulationPerformanceHints.EndWork(CompletePeriod: Boolean);
begin
  {$IFDEF ANDROID}
  if not FWorking then
    Exit;
  Inc(FWorkTicks, TStopwatch.GetTimeStamp - FStart);
  FWorking := False;
  if not CompletePeriod then
    Exit;
  var WorkNanos := Max(Int64(1), Round(FWorkTicks * (1000000000.0 / TStopwatch.Frequency)));
  FWorkTicks := 0;
  if FSession <> nil then
  try
    (FSession as JEmulationHintSession).reportActualWorkDuration(WorkNanos);
  except
    on E: Exception do
      Disable('work report failed: ' + E.Message);
  end;
  ObserveWork(WorkNanos);
  {$ENDIF}
end;

end.

