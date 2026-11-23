unit Java.Timers;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaTimers(VM: TJVM);

function InvokeJavaTimers(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultZone: string = 'GMT'): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, JVM.Threading, Java.Dates,
  Java.TimeZones;

{$Q-}{$R-}

const
  TimerName = 'java/util/Timer';
  TaskName = 'java/util/TimerTask';
  RunnerName = 'java/util/Timer$Thread';
  DateName = 'java/util/Date';
  MaxTimerTasks = 65536;

procedure InstallJavaTimers(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Descriptor: string; Access: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Descriptor).Access := Access or JVM_ACC_NATIVE;
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(DateName, 'java/lang/Object');
    B.Field('$time', 'J', JVM_ACC_PRIVATE);
    Native('<init>', '()V');
    Native('<init>', '(J)V');
    Native('getTime', '()J');
    Native('setTime', '(J)V');
    B.Start;
    B.Emit([$2B]);
    B.Ref($C1, B.ClassRef(DateName));
    B.Jump($99, 'no');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(DateName, 'getTime', '()J'));
    B.Emit([$2B]);
    B.Ref($C0, B.ClassRef(DateName));
    B.Ref($B6, B.Member(DateName, 'getTime', '()J'));
    B.Emit([$94]);
    B.Jump($9A, 'no');
    B.Emit([$04, $AC]);
    B.Mark('no');
    B.Emit([$03, $AC]);
    B.Finish('equals', '(Ljava/lang/Object;)Z', JVM_ACC_PUBLIC, 4, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(DateName, 'getTime', '()J'));
    B.Emit([$40, $1F, $1F, $10, 32, $7D, $83, $88, $AC]);
    B.Finish('hashCode', '()I', JVM_ACC_PUBLIC, 5, 3);
    Native('$format', '(J)Ljava/lang/String;', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, B.Member(DateName, '$time', 'J', 9));
    B.Ref($B8, B.Member(DateName, '$format', '(J)Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('toString', '()Ljava/lang/String;', JVM_ACC_PUBLIC, 2, 1);
    Done;

    B := TJavaClassBuilder.Create(TaskName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    B.JavaClass.Interfaces := ['java/lang/Runnable'];
    for var Name in ['$status', '$beyond'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    for var Name in ['$due', '$period', '$last'] do
      B.Field(Name, 'J', JVM_ACC_PRIVATE);
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Native('cancel', '()Z');
    Native('scheduledExecutionTime', '()J');
    B.JavaClass.AddNative('run', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Done;

    B := TJavaClassBuilder.Create(RunnerName, 'java/lang/Thread', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
    // The owner is deliberately an integer handle, not a GC reference. The
    // timer thread retains pending tasks but does not keep the Timer alive.
    for var Name in ['$owner', '$closed', '$count'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    B.Field('$tasks', '[Ljava/util/TimerTask;', JVM_ACC_PRIVATE);
    var Lock := B.Field('$lock', 'Ljava/lang/Object;', JVM_ACC_PRIVATE);
    Native('$poll', '()Ljava/util/TimerTask;', JVM_ACC_PRIVATE);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, Lock);
    B.Emit([$59, $4C, $C2]);
    B.Mark('locked');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(RunnerName, '$poll', '()Ljava/util/TimerTask;'));
    B.Emit([$4D, $2B, $C3]);
    B.Mark('unlocked');
    B.Emit([$2C, $B0]);
    B.Mark('failed');
    B.Emit([$4D, $2B, $C3, $2C, $BF]);
    B.Finish('$take', '()Ljava/util/TimerTask;', JVM_ACC_PRIVATE, 2, 3);
    var Unlock: TJVMExceptionHandler;
    Unlock := Default(TJVMExceptionHandler);
    Unlock.StartPC := B.Position('locked');
    Unlock.EndPC := B.Position('unlocked');
    Unlock.HandlerPC := B.Position('failed');
    B.JavaClass.Methods.Last.Handlers := [Unlock];
    Native('$close', '()V', JVM_ACC_PRIVATE);
    B.Start;
    B.Mark('loop');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(RunnerName, '$take', '()Ljava/util/TimerTask;'));
    B.Mark('taken');
    B.Emit([$59]);
    B.Jump($C6, 'end');
    B.Emit([$4C, $2B]);
    B.Ref($B6, B.Member(TaskName, 'run', '()V'));
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$57, $B1]);
    B.Mark('interrupted');
    B.Emit([$57]);
    B.Jump($A7, 'loop');
    B.Mark('failed');
    B.Emit([$4C, $2A]);
    B.Ref($B7, B.Member(RunnerName, '$close', '()V'));
    B.Emit([$2B, $BF]);
    B.Finish('run', '()V', JVM_ACC_PUBLIC, 2, 2);
    var H: TJVMExceptionHandler;
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('loop');
    H.EndPC := B.Position('taken');
    H.HandlerPC := B.Position('interrupted');
    H.CatchType := B.ClassRef('java/lang/InterruptedException');
    var All: TJVMExceptionHandler;
    All := Default(TJVMExceptionHandler);
    All.StartPC := B.Position('loop');
    All.EndPC := B.Position('interrupted');
    All.HandlerPC := B.Position('failed');
    B.JavaClass.Methods.Last.Handlers := [H, All];
    Done;

    B := TJavaClassBuilder.Create(TimerName, 'java/lang/Object');
    B.Field('$thread', 'Ljava/util/Timer$Thread;', JVM_ACC_PRIVATE);
    Native('<init>', '()V');
    Native('cancel', '()V');
    Native('$schedule', '(Ljava/util/TimerTask;JJI)V', JVM_ACC_PRIVATE);
    for var Mode := 0 to 5 do
    begin
      var Repeating := Mode mod 3 <> 0;
      var absolute := Mode >= 3;
      var Name := 'schedule';
      if Mode mod 3 = 2 then
        Name := 'scheduleAtFixedRate';
      var Descriptor := '(Ljava/util/TimerTask;';
      if absolute then
        Descriptor := Descriptor + 'Ljava/util/Date;'
      else
        Descriptor := Descriptor + 'J';
      if Repeating then
        Descriptor := Descriptor + 'J';
      Descriptor := Descriptor + ')V';
      B.Start;
      B.Emit([$2A, $2B]);
      if absolute then
      begin
        B.Emit([$2C]);
        B.Ref($B6, B.Member(DateName, 'getTime', '()J'));
      end
      else
        B.Emit([$20]);
      if not Repeating then
        B.Emit([$09])
      else if absolute then
        B.Emit([$21])
      else
        B.Emit([$16, 4]);
      B.Emit([Byte($03 + Mode)]);
      B.Ref($B7, B.Member(TimerName, '$schedule', '(Ljava/util/TimerTask;JJI)V'));
      B.Emit([$B1]);
      var Locals := 4;
      if absolute then
        Locals := 3;
      if Repeating then
        Inc(Locals, 2);
      B.Finish(Name, Descriptor, JVM_ACC_PUBLIC, 7, Locals);
    end;
    Done;
  finally
    B.Free;
  end;
end;

function Key(const Name: string): string;
begin
  if Name = '$time' then
    Exit(DateName + '.' + Name + ':J');
  if Name = '$thread' then
    Exit(TimerName + '.' + Name + ':Ljava/util/Timer$Thread;');
  if Name = '$lock' then
    Exit(RunnerName + '.' + Name + ':Ljava/lang/Object;');
  if Name = '$tasks' then
    Exit(RunnerName + '.' + Name + ':[Ljava/util/TimerTask;');
  if (Name = '$status') or (Name = '$beyond') then
    Exit(TaskName + '.' + Name + ':I');
  if (Name = '$due') or (Name = '$period') or (Name = '$last') then
    Exit(TaskName + '.' + Name + ':J');
  Result := RunnerName + '.' + Name + ':I';
end;

function Value(O: TJVMObject; const Name: string): TJVMValue;
begin
  Result := O.Fields[Key(Name)];
end;

function Int(O: TJVMObject; const Name: string): Integer;
begin
  Result := Value(O, Name).AsInt;
end;

function Long(O: TJVMObject; const Name: string): Int64;
begin
  Result := Value(O, Name).AsLong;
end;

procedure PutInt(O: TJVMObject; const Name: string; V: Integer);
begin
  O.Fields.AddOrSetValue(Key(Name), TJVMValue.Int(V));
end;

procedure PutLong(O: TJVMObject; const Name: string; V: Int64);
begin
  O.Fields.AddOrSetValue(Key(Name), TJVMValue.Long(V));
end;

function DateText(Millis: Int64; const ZoneID: string): string;
const
  Days: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  Months: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  Day: Int64;
  Time, Offset: Integer;
begin
  var ID := JavaZoneID(ZoneID, Offset);
  JavaSplitMillis(Millis, Offset, Day, Time);
  var D := JavaCivil(Day, Time);
  if D.Year <= 0 then
    D.Year := 1 - D.Year;
  Result := Format('%s %s %.2d %.2d:%.2d:%.2d %s %.4d',
    [Days[D.DayOfWeek], Months[D.Month], D.Day, D.Hour, D.Minute, D.Second, ID, D.Year]);
end;

procedure CloseRunner(VM: TJVM; Runner: TJVMObject);
begin
  PutInt(Runner, '$closed', 1);
  PutInt(Runner, '$count', 0);
  Runner.Fields.AddOrSetValue(Key('$tasks'), TJVMValue.Ref(0));
  // Native queue operations are atomic within this cooperative VM. Wake its
  // private wait monitor without exposing/holding it across a guest task call.
  VM.Scheduler.Notify(Value(Runner, '$lock').AsRef, True);
end;

function InvokeJavaTimers(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultZone: string): TJVMValue;
var
  O, Runner, Task, Queue: TJVMObject;
  RunnerRef, Count: Integer;
  N, C: string;

  function TaskAt(Index: Integer): TJVMObject;
  begin
    Result := VM.GetObject(Queue.Elements[Index].AsRef);
  end;

  function Earlier(A, B: TJVMObject): Boolean;
  begin
    var ADue := Long(A, '$due');
    var BDue := Long(B, '$due');
    if ADue <> BDue then
      Exit(ADue < BDue);
    Result := Int(A, '$beyond') < Int(B, '$beyond');
  end;

  procedure Down(Index: Integer);
  begin
    var Item := Queue.Elements[Index];
    var Candidate := VM.GetObject(Item.AsRef);
    while Index < Count div 2 do
    begin
      var Child := Index * 2 + 1;
      if (Child + 1 < Count) and Earlier(TaskAt(Child + 1), TaskAt(Child)) then
        Inc(Child);
      if not Earlier(TaskAt(Child), Candidate) then
        Break;
      Queue.Elements[Index] := Queue.Elements[Child];
      Index := Child;
    end;
    Queue.Elements[Index] := Item;
  end;

  procedure Pop;
  begin
    Dec(Count);
    Queue.Elements[0] := Queue.Elements[Count];
    Queue.Elements[Count] := TJVMValue.Ref(0);
    PutInt(Runner, '$count', Count);
    if Count > 0 then
      Down(0);
  end;

begin
  Result := Default(TJVMValue);
  C := Method.Owner.Name;
  N := Method.Name;
  if C = DateName then
  begin
    if N = '$format' then
      Exit(TJVMValue.Ref(VM.NewString(DateText(Args[0].AsLong, DefaultZone))));
    O := VM.GetObject(Args[0].AsRef);
    if N = '<init>' then
    begin
      var Time := VM.Host.TimeMillis;
      if Length(Args) = 2 then
        Time := Args[1].AsLong;
      PutLong(O, '$time', Time);
      Exit;
    end;
    if N = 'getTime' then
      Exit(Value(O, '$time'));
    if N = 'setTime' then
    begin
      PutLong(O, '$time', Args[1].AsLong);
      Exit;
    end;
  end;
  O := VM.GetObject(Args[0].AsRef);
  if C = TaskName then
  begin
    if N = '<init>' then
    begin
      PutInt(O, '$status', 0);
      PutInt(O, '$beyond', 0);
      PutLong(O, '$due', 0);
      PutLong(O, '$period', 0);
      PutLong(O, '$last', 0);
      Exit;
    end;
    if N = 'cancel' then
    begin
      Result := TJVMValue.Int(Ord(Int(O, '$status') = 1));
      PutInt(O, '$status', 3);
      Exit;
    end;
    if N = 'scheduledExecutionTime' then
      Exit(Value(O, '$last'));
  end;
  if C = RunnerName then
  begin
    Runner := O;
    if N = '$close' then
    begin
      CloseRunner(VM, Runner);
      Exit;
    end;
    if N = '$poll' then
    begin
      if Int(Runner, '$closed') <> 0 then
        Exit(TJVMValue.Ref(0));
      Queue := VM.GetObject(Value(Runner, '$tasks').AsRef);
      Count := Int(Runner, '$count');
      // Cancelled heap entries need no guest callbacks. At most the explicit
      // queue limit is stored; each removal is logarithmic and each pass
      // yields after at most 64 cancelled roots.
      var Removed := 0;
      while (Count > 0) and (Int(TaskAt(0), '$status') = 3) do
      begin
        Pop;
        Inc(Removed);
        if Removed = 64 then
        begin
          VM.RetryNative;
          Exit;
        end;
      end;
      var Timeout: Int64 := 1000;
      if Count = 0 then
      begin
        if not VM.IsObjectAlive(Int(Runner, '$owner')) then
        begin
          CloseRunner(VM, Runner);
          Exit(TJVMValue.Ref(0));
        end;
      end
      else
      begin
        Task := TaskAt(0);
        var Due := Long(Task, '$due');
        var Now := VM.Host.TimeMillis;
        if (Due <= Now) and (Int(Task, '$beyond') = 0) then
        begin
          Result := Queue.Elements[0];
          var Period := Long(Task, '$period');
          var Last := Due;
          if Period < 0 then
            Last := Now;
          PutLong(Task, '$last', Last);
          if Period = 0 then
          begin
            Pop;
            PutInt(Task, '$status', 2);
          end
          else
          begin
            var Base := Due;
            if Period < 0 then
              Base := Now;
            // Saturating the deadline prevents a wrapped negative time from
            // spinning forever at the end of the representable epoch.
            var Delta := Abs(Period);
            var Beyond := Base > High(Int64) - Delta;
            PutInt(Task, '$beyond', Ord(Beyond));
            PutLong(Task, '$due', JVMDeadline(Base, Delta));
            Down(0);
          end;
          Exit;
        end;
        // Poll at a bounded interval for wall-clock adjustments and orphaned
        // owners. Normal scheduling/cancellation wakes this wait immediately.
        if (Int(Task, '$beyond') = 0) and (Now > Due - 1000) then
          Timeout := Due - Now;
      end;
      VM.RetryNative;
      VM.WaitCurrent(Value(Runner, '$lock').AsRef, Timeout);
      Exit;
    end;
  end;
  if C = TimerName then
  begin
    if N = '<init>' then
    begin
      RunnerRef := VM.NewObject(RunnerName);
      Runner := VM.GetObject(RunnerRef);
      PutInt(Runner, '$owner', Args[0].AsRef);
      PutInt(Runner, '$closed', 0);
      PutInt(Runner, '$count', 0);
      Runner.Fields.AddOrSetValue(Key('$lock'), TJVMValue.Ref(VM.NewObject('java/lang/Object')));
      Runner.Fields.AddOrSetValue(Key('$tasks'), TJVMValue.Ref(VM.NewArray('[Ljava/util/TimerTask;', 16)));
      O.Fields.AddOrSetValue(Key('$thread'), TJVMValue.Ref(RunnerRef));
      VM.InitializeJavaThread(RunnerRef, 0, 'Timer-' + IntToStr(RunnerRef));
      VM.StartJavaThread(RunnerRef);
      Exit;
    end;
    RunnerRef := Value(O, '$thread').AsRef;
    Runner := VM.GetObject(RunnerRef);
    if N = 'cancel' then
    begin
      CloseRunner(VM, Runner);
      Exit;
    end;
    if N = '$schedule' then
    begin
      var Mode := Args[4].AsInt;
      var Time := Args[2].AsLong;
      var Period := Args[3].AsLong;
      if (Time < 0) or ((Mode mod 3 <> 0) and (Period <= 0)) then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      if Mode < 3 then
      begin
        var Now := VM.Host.TimeMillis;
        if (Now > 0) and (Time > High(Int64) - Now) then
          VM.RaiseJava('java/lang/IllegalArgumentException');
        Inc(Time, Now);
        if Time < 0 then
          VM.RaiseJava('java/lang/IllegalArgumentException');
      end;
      if Mode mod 3 = 1 then
        Period := -Period;
      // Establish all validation before changing a TimerTask or queue.
      Task := VM.GetObject(Args[1].AsRef);
      if (Int(Runner, '$closed') <> 0) or (VM.JavaThread(RunnerRef).State = TJVMThreadState.Terminated) or
        (Int(Task, '$status') <> 0) then
        VM.RaiseJava('java/lang/IllegalStateException');
      Queue := VM.GetObject(Value(Runner, '$tasks').AsRef);
      Count := Int(Runner, '$count');
      if Count >= MaxTimerTasks then
        VM.RaiseJava('java/lang/OutOfMemoryError', 'Timer task queue limit');
      if Count = Length(Queue.Elements) then
      begin
        var NewRef := VM.NewArray('[Ljava/util/TimerTask;', Min(MaxTimerTasks, Count * 2));
        var NewQueue := VM.GetObject(NewRef);
        for var I := 0 to Count - 1 do
          NewQueue.Elements[I] := Queue.Elements[I];
        Runner.Fields.AddOrSetValue(Key('$tasks'), TJVMValue.Ref(NewRef));
        Queue := NewQueue;
      end;
      PutInt(Task, '$status', 1);
      PutInt(Task, '$beyond', 0);
      PutLong(Task, '$due', Time);
      PutLong(Task, '$period', Period);
      var Index := Count;
      while Index > 0 do
      begin
        var Parent := (Index - 1) div 2;
        if not Earlier(Task, TaskAt(Parent)) then
          Break;
        Queue.Elements[Index] := Queue.Elements[Parent];
        Index := Parent;
      end;
      Queue.Elements[Index] := Args[1];
      PutInt(Runner, '$count', Count + 1);
      VM.Scheduler.Notify(Value(Runner, '$lock').AsRef, True);
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create('Timer/date native method: ' + C + '.' + N);
end;

end.

