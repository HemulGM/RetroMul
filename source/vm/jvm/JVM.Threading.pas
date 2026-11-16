unit JVM.Threading;

interface

uses
  System.Classes, JVM.StateIO, System.SysUtils, System.Generics.Collections;

{$SCOPEDENUMS ON}

type
  TJVMThreadState = (New, Idle, Runnable, Sleeping, Blocked, Waiting, ClassInitialization, Terminated);

  TJVMThreadContext = class
  public
    ID, JavaObject, Target, Priority, Quantum: Integer;
    State: TJVMThreadState;
    Interrupted, PendingInterrupted: Boolean;
    WakeAt: Int64;
    WaitMonitor, WaitDepth: Integer;
    WaitClass: string;
    constructor Create(Identifier: Integer);
  end;

  TJVMMonitor = class
  public
    Reference, Owner, Depth: Integer;
  end;

  TJVMScheduler = class
  private
    FThreads: TObjectList<TJVMThreadContext>;
    FMonitors: TObjectDictionary<Integer, TJVMMonitor>;
    FNextID: Integer;
    function Monitor(Ref: Integer): TJVMMonitor;
    procedure WakeWaiter(Thread: TJVMThreadContext);
  public
    procedure TransferState(S: TJVMStateIO);
    constructor Create;
    destructor Destroy; override;
    function NewThread: TJVMThreadContext;
    function ThreadForObject(Ref: Integer): TJVMThreadContext;
    function ThreadByID(ID: Integer): TJVMThreadContext;
    function NextRunnable(PreviousID: Integer; Now: Int64): TJVMThreadContext;
    function Enter(Thread: TJVMThreadContext; Ref: Integer): Boolean;
    function ExitMonitor(Thread: TJVMThreadContext; Ref: Integer): Boolean;
    function OwnsMonitor(Thread: TJVMThreadContext; Ref: Integer): Boolean;
    procedure Wait(Thread: TJVMThreadContext; Ref: Integer; Timeout, Now: Int64);
    procedure Notify(Ref: Integer; All: Boolean);
    procedure Interrupt(Thread: TJVMThreadContext);
    procedure Finish(Thread: TJVMThreadContext);
    procedure WakeClass(const Name: string);
    procedure ForgetObject(Ref: Integer);
    function LiveCount: Integer;
    function MonitorRoots: TArray<Integer>;
    property Threads: TObjectList<TJVMThreadContext> read FThreads;
  end;

function JVMDeadline(Now, Timeout: Int64): Int64;

implementation

function JVMDeadline(Now, Timeout: Int64): Int64;
begin
  if Timeout > High(Int64) - Now then
    Result := High(Int64)
  else
    Result := Now + Timeout;
end;

constructor TJVMThreadContext.Create(Identifier: Integer);
begin
  inherited Create;
  ID := Identifier;
  Priority := 5;
end;

constructor TJVMScheduler.Create;
begin
  inherited Create;
  FNextID := 1;
  FThreads := TObjectList<TJVMThreadContext>.Create(True);
  FMonitors := TObjectDictionary<Integer, TJVMMonitor>.Create([doOwnsValues]);
end;

destructor TJVMScheduler.Destroy;
begin
  FMonitors.Free;
  FThreads.Free;
  inherited;
end;

function TJVMScheduler.NewThread: TJVMThreadContext;
begin
  if FNextID = MaxInt then
    raise EInvalidOpException.Create('Java thread identifier limit');
  Result := TJVMThreadContext.Create(FNextID);
  Inc(FNextID);
  FThreads.Add(Result);
end;

function TJVMScheduler.ThreadForObject(Ref: Integer): TJVMThreadContext;
begin
  for Result in FThreads do
    if Result.JavaObject = Ref then
      Exit;
  Result := nil;
end;

function TJVMScheduler.ThreadByID(ID: Integer): TJVMThreadContext;
begin
  for Result in FThreads do
    if Result.ID = ID then
      Exit;
  Result := nil;
end;

function TJVMScheduler.Monitor(Ref: Integer): TJVMMonitor;
begin
  if not FMonitors.TryGetValue(Ref, Result) then
  begin
    Result := TJVMMonitor.Create;
    Result.Reference := Ref;
    FMonitors.Add(Ref, Result);
  end;
end;

function TJVMScheduler.OwnsMonitor(Thread: TJVMThreadContext; Ref: Integer): Boolean;
var
  M: TJVMMonitor;
begin
  Result := FMonitors.TryGetValue(Ref, M) and (M.Owner = Thread.ID);
end;

function TJVMScheduler.Enter(Thread: TJVMThreadContext; Ref: Integer): Boolean;
var
  M: TJVMMonitor;
begin
  M := Monitor(Ref);
  Result := (M.Owner = 0) or (M.Owner = Thread.ID);
  if Result then
  begin
    M.Owner := Thread.ID;
    Inc(M.Depth);
    Thread.WaitMonitor := 0;
  end
  else
  begin
    Thread.State := TJVMThreadState.Blocked;
    Thread.WaitMonitor := Ref;
    Thread.WaitDepth := 0;
    Thread.Quantum := 0;
  end;
end;

function TJVMScheduler.ExitMonitor(Thread: TJVMThreadContext; Ref: Integer): Boolean;
var
  M: TJVMMonitor;
begin
  Result := OwnsMonitor(Thread, Ref);
  if not Result then
    Exit;
  M := Monitor(Ref);
  Dec(M.Depth);
  if M.Depth = 0 then
    M.Owner := 0;
end;

procedure TJVMScheduler.Wait(Thread: TJVMThreadContext; Ref: Integer; Timeout, Now: Int64);
var
  M: TJVMMonitor;
begin
  M := Monitor(Ref);
  Thread.WaitMonitor := Ref;
  Thread.WaitDepth := M.Depth;
  Thread.State := TJVMThreadState.Waiting;
  Thread.Quantum := 0;
  if Timeout = 0 then
    Thread.WakeAt := 0
  else
    Thread.WakeAt := JVMDeadline(Now, Timeout);
  M.Owner := 0;
  M.Depth := 0;
end;

procedure TJVMScheduler.WakeWaiter(Thread: TJVMThreadContext);
begin
  Thread.State := TJVMThreadState.Blocked;
  Thread.WakeAt := 0;
end;

procedure TJVMScheduler.Notify(Ref: Integer; All: Boolean);
var
  Thread: TJVMThreadContext;
begin
  for Thread in FThreads do
    if (Thread.State = TJVMThreadState.Waiting) and (Thread.WaitMonitor = Ref) then
    begin
      WakeWaiter(Thread);
      if not All then
        Break;
    end;
end;

procedure TJVMScheduler.Interrupt(Thread: TJVMThreadContext);
begin
  if Thread.State = TJVMThreadState.Terminated then
    Exit;
  Thread.Interrupted := True;
  case Thread.State of
    TJVMThreadState.Sleeping:
      begin
        Thread.State := TJVMThreadState.Runnable;
        Thread.WakeAt := 0;
        Thread.PendingInterrupted := True;
      end;
    TJVMThreadState.Waiting:
      begin
        WakeWaiter(Thread);
        Thread.PendingInterrupted := True;
      end;
  end;
end;

procedure TJVMScheduler.Finish(Thread: TJVMThreadContext);
var
  M: TJVMMonitor;
begin
  Thread.State := TJVMThreadState.Terminated;
  Thread.WaitMonitor := 0;
  Thread.WaitDepth := 0;
  Thread.PendingInterrupted := False;
  Thread.WakeAt := 0;
  Thread.WaitClass := '';
  for M in FMonitors.Values do
    if M.Owner = Thread.ID then
    begin
      M.Owner := 0;
      M.Depth := 0;
    end;
  if Thread.JavaObject <> 0 then
    Notify(Thread.JavaObject, True);
end;

procedure TJVMScheduler.WakeClass(const Name: string);
var
  Thread: TJVMThreadContext;
begin
  for Thread in FThreads do
    if (Thread.State = TJVMThreadState.ClassInitialization) and (Thread.WaitClass = Name) then
    begin
      Thread.WaitClass := '';
      Thread.State := TJVMThreadState.Runnable;
    end;
end;

function TJVMScheduler.NextRunnable(PreviousID: Integer; Now: Int64): TJVMThreadContext;
var
  Thread, First: TJVMThreadContext;
  M: TJVMMonitor;
begin
  for Thread in FThreads do
  begin
    if (Thread.State in [TJVMThreadState.Sleeping, TJVMThreadState.Waiting]) and
      (Thread.WakeAt <> 0) and (Now >= Thread.WakeAt) then
    begin
      if Thread.State = TJVMThreadState.Sleeping then
      begin
        Thread.State := TJVMThreadState.Runnable;
        Thread.WakeAt := 0;
      end
      else
        WakeWaiter(Thread);
    end;
    if (Thread.State = TJVMThreadState.Blocked) and (Monitor(Thread.WaitMonitor).Owner = 0) then
    begin
      if Thread.WaitDepth <> 0 then
      begin
        M := Monitor(Thread.WaitMonitor);
        M.Owner := Thread.ID;
        M.Depth := Thread.WaitDepth;
        Thread.WaitDepth := 0;
      end;
      Thread.WaitMonitor := 0;
      Thread.State := TJVMThreadState.Runnable;
    end;
  end;
  First := nil;
  for Thread in FThreads do
    if Thread.State = TJVMThreadState.Runnable then
    begin
      if First = nil then
        First := Thread;
      if Thread.ID > PreviousID then
        Exit(Thread);
    end;
  Result := First;
end;

function TJVMScheduler.LiveCount: Integer;
begin
  Result := 0;
  for var Thread in FThreads do
    if not (Thread.State in [TJVMThreadState.New, TJVMThreadState.Terminated]) then
      Inc(Result);
end;

function TJVMScheduler.MonitorRoots: TArray<Integer>;
var
  Roots: TList<Integer>;
  M: TJVMMonitor;
  Thread: TJVMThreadContext;
begin
  Roots := TList<Integer>.Create;
  try
    for M in FMonitors.Values do
      if M.Owner <> 0 then
        Roots.Add(M.Reference);
    for Thread in FThreads do
      if Thread.WaitMonitor <> 0 then
        Roots.Add(Thread.WaitMonitor);
    Result := Roots.ToArray;
  finally
    Roots.Free;
  end;
end;

procedure TJVMScheduler.ForgetObject(Ref: Integer);
var
  I: Integer;
begin
  FMonitors.Remove(Ref);
  for I := FThreads.Count - 1 downto 0 do
    if (FThreads[I].JavaObject = Ref) and (FThreads[I].State in [TJVMThreadState.New, TJVMThreadState.Terminated]) then
      FThreads.Delete(I);
end;

procedure TJVMScheduler.TransferState(S: TJVMStateIO);
begin
  S.Tag('scheduler-1');
  S.Int(FNextID);
  var N := FThreads.Count;
  S.Count(N, 65536);
  if S.Loading then
  begin
    FThreads.Clear;
    FMonitors.Clear;
  end;
  for var I := 0 to N - 1 do
  begin
    if S.Loading then
      FThreads.Add(TJVMThreadContext.Create(0));
    var T := FThreads[I];
    S.Int(T.ID);
    S.Int(T.JavaObject);
    S.Int(T.Target);
    S.Int(T.Priority);
    S.Int(T.Quantum);
    var State: Integer := Ord(T.State);
    S.Count(State, Ord(High(TJVMThreadState)));
    T.State := TJVMThreadState(State);
    S.Bool(T.Interrupted);
    S.Bool(T.PendingInterrupted);
    S.Int64Value(T.WakeAt);
    S.Int(T.WaitMonitor);
    S.Int(T.WaitDepth);
    S.Text(T.WaitClass);
    if (T.ID <= 0) or (T.ID >= FNextID) then
      raise EReadError.Create('Invalid snapshot thread identifier');
    for var J := 0 to I - 1 do
      if FThreads[J].ID = T.ID then
        raise EReadError.Create('Duplicate snapshot thread identifier');
  end;
  var Refs := FMonitors.Keys.ToArray;
  N := Length(Refs);
  S.Count(N);
  if not S.Loading then
    TArray.Sort<Integer>(Refs);
  for var I := 0 to N - 1 do
  begin
    var M: TJVMMonitor;
    if S.Loading then
      M := TJVMMonitor.Create
    else
      M := FMonitors[Refs[I]];
    try
      S.Int(M.Reference);
      S.Int(M.Owner);
      S.Int(M.Depth);
      if S.Loading then
      begin
        if (M.Depth < 0) or ((M.Owner <> 0) and (ThreadByID(M.Owner) = nil)) then
          raise EReadError.Create('Invalid snapshot monitor');
        FMonitors.Add(M.Reference, M);
        M := nil;
      end;
    finally
      if S.Loading then
        M.Free;
    end;
  end;
end;

end.

