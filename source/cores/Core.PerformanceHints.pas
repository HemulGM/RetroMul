unit Core.PerformanceHints;

interface

type
  // Create, use and destroy on the worker being hinted. Other platforms are no-ops.
  TEmulationPerformanceHints = class
  private
    {$IFDEF ANDROID}
    FManager, FSession: IInterface;
    FStart, FWorkTicks: Int64;
    FWorking: Boolean;
    {$ENDIF}
    FName: string;
    FTargetNanos: Int64;
    {$IFDEF ANDROID}
    procedure Log(const Message: string);
    procedure Disable(const Reason: string);
    {$ENDIF}
    procedure SetTargetDurationNanos(Value: Int64);
  public
    constructor Create(TargetNanos: Int64; const Name: string);
    destructor Destroy; override;
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
  {$IFDEF ANDROID}
  Androidapi.Helpers, Androidapi.JNIBridge, Androidapi.JNI.JavaTypes,
  Androidapi.JNI.Os, Androidapi.Log,
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
{$ENDIF}

constructor TEmulationPerformanceHints.Create(TargetNanos: Int64; const Name: string);
begin
  inherited Create;
  FName := Name;
  SetTargetDurationNanos(TargetNanos);
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
  inherited;
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
  if (FManager = nil) or FWorking then
    Exit;
  if FSession = nil then
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
  try
    (FSession as JEmulationHintSession).reportActualWorkDuration(
        Max(Int64(1), Round(FWorkTicks * (1000000000.0 / TStopwatch.Frequency))));
    FWorkTicks := 0;
  except
    on E: Exception do
      Disable('work report failed: ' + E.Message);
  end;
  {$ENDIF}
end;

end.

