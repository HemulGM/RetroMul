unit Java.Bootstrap;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime;

type
  // Shared library bindings. No frontend, operating-system, or Java ME dependency.
  TJavaHost = class(TJVMHost)
  public
    function LoadResource(const Name: string; out Data: TBytes): Boolean; virtual;
    function LoadClassResource(const ClassName, Name: string; out Data: TBytes): Boolean; virtual;
    function GetProperty(const Name: string; out Value: string): Boolean; virtual;
    function DefaultEncoding: string; virtual;
    function DefaultTimeZoneID: string; virtual;
    function AllowEmptySnapshotFields(C: TJVMClass): Boolean; override;
    function InvokeNative(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>): TJVMValue; override;
  end;

procedure InstallJavaBootstrap(VM: TJVM);

function NewJavaLong(VM: TJVM; Value: Int64): Integer;

function JavaClassResourceName(const ClassName, Name: string): string;

implementation

uses
  System.Math, JVM.Threading, Java.Random, Java.IO, Java.Strings, Java.Timers,
  Java.Collections, Java.Numbers, Java.Characters, Java.Booleans, Java.Math,
  Java.Hashtable, Java.Readers, Java.Writers, Java.Diagnostics, Java.Builders,
  Java.Reflection, Java.Environment, Java.TimeZones, Java.Calendars,
  Java.Floating;

{$Q-}{$R-}

procedure InstallJavaBootstrap(VM: TJVM);
var
  C: TJVMClass;
  M: TJVMMethod;

  function AddClass(const Name, Parent: string): TJVMClass;
  begin
    Result := TJVMClass.Create;
    Result.Name := Name;
    Result.SuperName := Parent;
    VM.DefineClass(Result);
  end;

  procedure AddException(const Name, Parent: string; AcceptsIndex: Boolean = False);
  var
    E: TJVMClass;
  begin
    E := AddClass('java/lang/' + Name, 'java/lang/' + Parent);
    E.AddNative('<init>', '()V');
    E.AddNative('<init>', '(Ljava/lang/String;)V');
    if AcceptsIndex then
      E.AddNative('<init>', '(I)V');
  end;

begin
  C := AddClass('java/lang/Object', '');
  C.AddNative('<init>', '()V');
  C.AddNative('hashCode', '()I');
  C.AddNative('equals', '(Ljava/lang/Object;)Z');
  C.AddNative('toString', '()Ljava/lang/String;');
  C.AddNative('getClass', '()Ljava/lang/Class;');
  C.AddNative('clone', '()Ljava/lang/Object;').Access := JVM_ACC_NATIVE or JVM_ACC_PROTECTED;
  C.AddNative('wait', '()V');
  C.AddNative('wait', '(J)V');
  C.AddNative('wait', '(JI)V');
  C.AddNative('notify', '()V');
  C.AddNative('notifyAll', '()V');

  C := AddClass('java/lang/ref/Reference', 'java/lang/Object');
  C.Access := C.Access or JVM_ACC_ABSTRACT;
  C.AddNative('get', '()Ljava/lang/Object;');
  C.AddNative('clear', '()V');
  C := AddClass('java/lang/ref/WeakReference', 'java/lang/ref/Reference');
  C.AddNative('<init>', '(Ljava/lang/Object;)V');
  C.AddNative('get', '()Ljava/lang/Object;');
  C.AddNative('clear', '()V');

  C := AddClass('java/lang/Class', 'java/lang/Object');
  C.Access := C.Access or JVM_ACC_FINAL;
  C.AddNative('getName', '()Ljava/lang/String;');
  C.AddNative('isArray', '()Z');
  C.AddNative('isInterface', '()Z');
  C.AddNative('isInstance', '(Ljava/lang/Object;)Z');
  C.AddNative('isAssignableFrom', '(Ljava/lang/Class;)Z');
  C.AddNative('getResourceAsStream', '(Ljava/lang/String;)Ljava/io/InputStream;');
  InstallJavaClassMethods(C);
  C := AddClass('java/lang/String', 'java/lang/Object');
  C.Access := C.Access or JVM_ACC_FINAL;
  C.AddNative('<init>', '()V');
  C.AddNative('<init>', '(Ljava/lang/String;)V');
  C.AddNative('length', '()I');
  C.AddNative('charAt', '(I)C');
  C.AddNative('equals', '(Ljava/lang/Object;)Z');
  C.AddNative('hashCode', '()I');
  C.AddNative('toString', '()Ljava/lang/String;');
  C.AddNative('intern', '()Ljava/lang/String;');
  C.AddNative('substring', '(I)Ljava/lang/String;');
  C.AddNative('substring', '(II)Ljava/lang/String;');
  C.AddNative('concat', '(Ljava/lang/String;)Ljava/lang/String;');
  InstallJavaStringMethods(C);
  InstallJavaBuilders(VM);
  InstallJavaThrowable(VM);
  AddException('Exception', 'Throwable');
  AddException('RuntimeException', 'Exception');
  AddException('ArithmeticException', 'RuntimeException');
  AddException('NullPointerException', 'RuntimeException');
  AddException('IndexOutOfBoundsException', 'RuntimeException');
  AddException('ArrayIndexOutOfBoundsException', 'IndexOutOfBoundsException', True);
  AddException('StringIndexOutOfBoundsException', 'IndexOutOfBoundsException', True);
  AddException('ArrayStoreException', 'RuntimeException');
  AddException('NegativeArraySizeException', 'RuntimeException');
  AddException('ClassCastException', 'RuntimeException');
  AddException('IllegalArgumentException', 'RuntimeException');
  AddException('IllegalStateException', 'RuntimeException');
  AddException('SecurityException', 'RuntimeException');
  AddException('IllegalMonitorStateException', 'RuntimeException');
  AddException('IllegalThreadStateException', 'IllegalArgumentException');
  AddException('InterruptedException', 'Exception');
  AddException('CloneNotSupportedException', 'Exception');
  AddException('ClassNotFoundException', 'Exception');
  AddException('InstantiationException', 'Exception');
  AddException('IllegalAccessException', 'Exception');
  AddException('Error', 'Throwable');
  AddException('LinkageError', 'Error');
  AddException('VerifyError', 'LinkageError');
  AddException('ClassFormatError', 'LinkageError');
  AddException('IncompatibleClassChangeError', 'LinkageError');
  AddException('InstantiationError', 'IncompatibleClassChangeError');
  AddException('AbstractMethodError', 'IncompatibleClassChangeError');
  AddException('IllegalAccessError', 'IncompatibleClassChangeError');
  AddException('NoSuchMethodError', 'IncompatibleClassChangeError');
  AddException('NoSuchFieldError', 'IncompatibleClassChangeError');
  AddException('ClassCircularityError', 'LinkageError');
  AddException('UnsatisfiedLinkError', 'LinkageError');
  AddException('ExceptionInInitializerError', 'LinkageError');
  AddException('NoClassDefFoundError', 'LinkageError');
  VM.LoadClass('java/lang/ExceptionInInitializerError').AddNative('getException', '()Ljava/lang/Throwable;');
  AddException('VirtualMachineError', 'Error');
  VM.LoadClass('java/lang/VirtualMachineError').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020;
  AddException('OutOfMemoryError', 'VirtualMachineError');
  C := AddClass('java/io/IOException', 'java/lang/Exception');
  C.AddNative('<init>', '()V');
  C.AddNative('<init>', '(Ljava/lang/String;)V');
  C := AddClass('java/lang/Cloneable', 'java/lang/Object');
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200;
  C := AddClass('java/io/Serializable', 'java/lang/Object');
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200;
  C := AddClass('java/lang/Runnable', 'java/lang/Object');
  C.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200;
  C.AddNative('run', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  C := AddClass('java/lang/Thread', 'java/lang/Object');
  C.Interfaces := TArray<string>.Create('java/lang/Runnable');
  C.AddNative('<init>', '()V');
  C.AddNative('<init>', '(Ljava/lang/Runnable;)V');
  C.AddNative('<init>', '(Ljava/lang/String;)V');
  C.AddNative('<init>', '(Ljava/lang/Runnable;Ljava/lang/String;)V');
  C.AddNative('start', '()V');
  C.AddNative('run', '()V');
  C.AddNative('interrupt', '()V');
  C.AddNative('currentThread', '()Ljava/lang/Thread;', True);
  C.AddNative('activeCount', '()I', True);
  C.AddNative('yield', '()V', True);
  C.AddNative('sleep', '(J)V', True);
  C.AddNative('sleep', '(JI)V', True);
  C.AddNative('holdsLock', '(Ljava/lang/Object;)Z', True);
  C.AddNative('interrupted', '()Z', True);
  C.AddNative('isInterrupted', '()Z');
  C.AddNative('isAlive', '()Z');
  C.AddNative('getPriority', '()I');
  C.AddNative('setPriority', '(I)V');
  C.AddNative('getName', '()Ljava/lang/String;');
  C.AddNative('setName', '(Ljava/lang/String;)V');
  for var Descriptor in ['()V', '(J)V', '(JI)V'] do
  begin
    M := C.AddNative('join', Descriptor);
    M.Access := M.Access or $0020;
  end;
  InstallJavaSystem(VM);
  InstallJavaEnvironment(VM);
  InstallJavaMath(VM);
  InstallJavaFloating(VM);
  InstallJavaRandom(VM);
  InstallJavaNumbers(VM);
  InstallJavaCharacters(VM);
  InstallJavaBooleans(VM);
  InstallJavaCollections(VM);
  InstallJavaHashtable(VM);
  InstallJavaTimeZones(VM);
  InstallJavaCalendars(VM);
  InstallJavaTimers(VM);
  InstallJavaIO(VM);
  InstallJavaReaders(VM);
  InstallJavaWriters(VM);
  InstallJavaPrintStreams(VM);
  VM.PrepareOutOfMemory;
end;

function NewJavaLong(VM: TJVM; Value: Int64): Integer;
begin
  Result := VM.NewObject('java/lang/Long');
  VM.GetObject(Result).Fields['java/lang/Long.value:J'] := TJVMValue.Long(Value);
end;

function TJavaHost.LoadResource(const Name: string; out Data: TBytes): Boolean;
begin
  Data := nil;
  Result := False;
end;

function JavaClassResourceName(const ClassName, Name: string): string;
begin
  Result := Name;
  if Result.StartsWith('/') then
    Exit;
  var Owner := ClassName;
  while Owner.StartsWith('[') do
    Delete(Owner, 1, 1);
  if Owner.StartsWith('L') and Owner.EndsWith(';') then
    Owner := Copy(Owner, 2, Length(Owner) - 2);
  Result := '/' + Copy(Owner, 1, LastDelimiter('/', Owner)) + Name;
end;

function TJavaHost.LoadClassResource(const ClassName, Name: string; out Data: TBytes): Boolean;
begin
  var Key := JavaClassResourceName(ClassName, Name);
  Delete(Key, 1, 1);
  Result := LoadResource(Key, Data);
end;

function TJavaHost.GetProperty(const Name: string; out Value: string): Boolean;
begin
  Value := '';
  Result := False;
end;

function TJavaHost.AllowEmptySnapshotFields(C: TJVMClass): Boolean;
begin
  Result := IsLegacyEmptyFloatingClass(C);
end;

function TJavaHost.DefaultEncoding: string;
begin
  Result := 'UTF-8';
end;

function TJavaHost.DefaultTimeZoneID: string;
begin
  Result := 'GMT';
end;

function TJavaHost.InvokeNative(VM: TJVM; Method: TJVMMethod; const Arguments: TArray<TJVMValue>): TJVMValue;
var
  C, N, D, S, T, Component: string;
  O, Source, Dest: TJVMObject;
  I, J, K, Count, Hash: Integer;
  V: TJVMValue;
  Thread: TJVMThreadContext;
  Timeout: Int64;
  Resource: TBytes;

  function Arg(Index: Integer): TJVMValue;
  begin
    Result := Arguments[Index];
  end;

  function Text(Index: Integer): string;
  begin
    Result := VM.GetObject(Arg(Index).AsRef).Text;
  end;

  function TimeoutArgument(Offset: Integer): Int64;
  var
    Nanos: Integer;
  begin
    Result := 0;
    if Length(Arguments) > Offset then
      Result := Arg(Offset).AsLong;
    if Result < 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Negative timeout');
    if Length(Arguments) > Offset + 1 then
    begin
      Nanos := Arg(Offset + 1).AsInt;
      if (Nanos < 0) or (Nanos > 999999) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid nanosecond timeout');
      if (Nanos > 0) and (Result < High(Int64)) then
        Inc(Result);
    end;
  end;

begin
  C := Method.Owner.Name;
  N := Method.Name;
  D := Method.Descriptor;
  Result := Default(TJVMValue);
  if (C = 'java/lang/ref/Reference') or (C = 'java/lang/ref/WeakReference') then
  begin
    var Reference := VM.GetObject(Arg(0).AsRef);
    if N = '<init>' then
      Reference.WeakReferent := Arg(1).AsRef
    else if N = 'get' then
      Exit(TJVMValue.Ref(Reference.WeakReferent))
    else if N = 'clear' then
      Reference.WeakReferent := 0;
    Exit;
  end;
  if C = 'java/lang/Runtime' then
    Exit(InvokeJavaEnvironment(VM, Method, Arguments));
  if C = 'java/lang/Long' then
    Exit(InvokeJavaLong(VM, Method, Arguments));
  if (C = 'java/io/PrintStream') or (C = 'java/io/PrintStream$ConsoleOutput') then
  begin
    S := #10;
    if (N = '$newline') and GetProperty('line.separator', T) then
      S := T;
    Exit(InvokeJavaDiagnostics(VM, Method, Arguments, DefaultEncoding, S));
  end;
  if (C = 'java/io/Reader') or (C = 'java/io/InputStreamReader') then
    Exit(InvokeJavaReaders(VM, Method, Arguments, DefaultEncoding));
  if (C = 'java/io/Writer') or (C = 'java/io/OutputStreamWriter') or (C = 'java/io/StringWriter') then
    Exit(InvokeJavaWriters(VM, Method, Arguments, DefaultEncoding));
  if (C = 'java/util/Hashtable') or (C = 'java/util/Hashtable$Enumeration') then
    Exit(InvokeJavaHashtable(VM, Method, Arguments));
  if (C = 'java/lang/Byte') or (C = 'java/lang/Short') then
    Exit(InvokeJavaSmallInteger(VM, Method, Arguments));
  if C = 'java/lang/Integer' then
    Exit(InvokeJavaInteger(VM, Method, Arguments));
  if C = 'java/lang/Character' then
    Exit(InvokeJavaCharacter(VM, Method, Arguments));
  if C = 'java/lang/Boolean' then
    Exit(InvokeJavaBoolean(VM, Method, Arguments));
  if (C = 'java/util/Vector') or (C = 'java/util/Vector$Enumeration') then
    Exit(InvokeJavaCollections(VM, Method, Arguments));
  if (C = 'java/util/Timer') or (C = 'java/util/TimerTask') or (C = 'java/util/Timer$Thread') or (C = 'java/util/Date') then
    Exit(InvokeJavaTimers(VM, Method, Arguments, DefaultTimeZoneID));
  if (C = 'java/util/TimeZone') or (C = 'java/util/TimeZone$Fixed') then
    Exit(InvokeJavaTimeZone(VM, Method, Arguments, DefaultTimeZoneID));
  if (C = 'java/util/Calendar') or (C = 'java/util/Calendar$Gregorian') then
    Exit(InvokeJavaCalendar(VM, Method, Arguments));
  if C = 'java/util/Random' then
    Exit(InvokeJavaRandom(VM, Method, Arguments));
  if (C = 'java/io/ByteArrayInputStream') or (C = 'java/io/ByteArrayOutputStream') or
    ((C = 'java/io/DataInputStream') and (N = '$decodeUTF')) or
    ((C = 'java/io/DataOutputStream') and ((N = '$encodeUTF') or (N = '$count'))) then
    Exit(InvokeJavaIO(VM, Method, Arguments, DefaultEncoding));
  if C = 'java/lang/Object' then
  begin
    if N = '<init>' then
      Exit;
    if N = 'getClass' then
      Exit(TJVMValue.Ref(VM.ClassObject(VM.GetObject(Arg(0).AsRef).ClassName)));
    if N = 'clone' then
      Exit(TJVMValue.Ref(VM.CloneObject(Arg(0).AsRef)));
    if N = 'wait' then
    begin
      Timeout := TimeoutArgument(1);
      VM.WaitCurrent(Arg(0).AsRef, Timeout);
      Exit;
    end;
    if (N = 'notify') or (N = 'notifyAll') then
    begin
      VM.NotifyCurrent(Arg(0).AsRef, N = 'notifyAll');
      Exit;
    end;
    if N = 'hashCode' then
      Exit(TJVMValue.Int(Arg(0).AsRef));
    if N = 'equals' then
      Exit(TJVMValue.Int(Ord(Arg(0).AsRef = Arg(1).AsRef)));
    if N = 'toString' then
    begin
      if not VM.TakeGuestResult(V) then
      begin
        VM.InvokeGuestResult(VM.ResolveVirtualMethod(Arg(0).AsRef, VM.LoadClass('java/lang/Object').FindMethod('hashCode', '()I')), [Arg(0)]);
        Exit;
      end;
      S := VM.GetObject(Arg(0).AsRef).ClassName.Replace('/', '.');
      Exit(TJVMValue.Ref(VM.NewString(S + '@' + IntToHex(UInt32(V.AsInt), 1).ToLower)));
    end;
  end;
  if C = 'java/lang/Class' then
  begin
    if TryInvokeJavaClass(VM, Method, Arguments, Result) then
      Exit;
    S := Text(0);
    if N = 'getResourceAsStream' then
    begin
      T := Text(1);
      if LoadClassResource(S, T, Resource) then
        Exit(TJVMValue.Ref(NewJavaByteArrayInput(VM, Resource)));
      Exit(TJVMValue.Ref(0));
    end;
    if N = 'getName' then
      Exit(TJVMValue.Ref(VM.NewString(S.Replace('/', '.'))));
    if N = 'isArray' then
      Exit(TJVMValue.Int(Ord(S.StartsWith('['))));
    if N = 'isInterface' then
    begin
      I := 0;
      if not S.StartsWith('[') then
        I := Ord((VM.LoadClass(S).Access and $0200) <> 0);
      Exit(TJVMValue.Int(I));
    end;
    if N = 'isInstance' then
    begin
      I := Arg(1).AsRef;
      Exit(TJVMValue.Int(Ord((I <> 0) and VM.IsAssignable(VM.GetObject(I).ClassName, S))));
    end;
    if N = 'isAssignableFrom' then
      Exit(TJVMValue.Int(Ord(VM.IsAssignable(Text(1), S))));
  end;
  if C = 'java/lang/Thread' then
  begin
    if N = '<init>' then
    begin
      I := 0;
      S := 'Thread-' + IntToStr(Arg(0).AsRef);
      if D.StartsWith('(Ljava/lang/Runnable;') then
      begin
        I := Arg(1).AsRef;
        if I <> 0 then
        begin
          if not VM.IsAssignable(VM.GetObject(I).ClassName, 'java/lang/Runnable') then
            raise EJVMFormatError.Create('Thread target does not implement Runnable');
        end;
      end;
      if D = '(Ljava/lang/String;)V' then
        S := Text(1)
      else if Length(Arguments) = 3 then
        S := Text(2);
      VM.InitializeJavaThread(Arg(0).AsRef, I, S);
      Exit;
    end;
    if N = 'currentThread' then
      Exit(TJVMValue.Ref(VM.CurrentJavaThread));
    if N = 'activeCount' then
      Exit(TJVMValue.Int(VM.Scheduler.LiveCount));
    if N = 'yield' then
    begin
      VM.YieldCurrent;
      Exit;
    end;
    if N = 'sleep' then
    begin
      Timeout := TimeoutArgument(0);
      VM.SleepCurrent(Timeout);
      Exit;
    end;
    if N = 'interrupted' then
      Exit(TJVMValue.Int(Ord(VM.ClearInterrupted)));
    if N = 'holdsLock' then
    begin
      VM.GetObject(Arg(0).AsRef);
      Exit(TJVMValue.Int(Ord(VM.Scheduler.OwnsMonitor(VM.CurrentThread, Arg(0).AsRef))));
    end;
    Thread := VM.JavaThread(Arg(0).AsRef);
    if N = 'start' then
    begin
      VM.StartJavaThread(Arg(0).AsRef);
      Exit;
    end;
    if N = 'run' then
    begin
      if Thread.Target <> 0 then
        VM.InvokeGuest(VM.ResolveMethod(VM.LoadClass(VM.GetObject(Thread.Target).ClassName), 'run', '()V'),
          [TJVMValue.Ref(Thread.Target)]);
      Exit;
    end;
    if N = 'interrupt' then
    begin
      VM.InterruptJavaThread(Arg(0).AsRef);
      Exit;
    end;
    if N = 'join' then
    begin
      Timeout := TimeoutArgument(1);
      VM.JoinJavaThread(Arg(0).AsRef, Timeout);
      Exit;
    end;
    if N = 'isAlive' then
      Exit(TJVMValue.Int(Ord(not (Thread.State in [TJVMThreadState.New, TJVMThreadState.Terminated]))));
    if N = 'isInterrupted' then
      Exit(TJVMValue.Int(Ord(Thread.Interrupted)));
    if N = 'getPriority' then
      Exit(TJVMValue.Int(Thread.Priority));
    if N = 'setPriority' then
    begin
      I := Arg(1).AsInt;
      if (I < 1) or (I > 10) then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      Thread.Priority := I;
      Exit;
    end;
    if N = 'getName' then
      Exit(TJVMValue.Ref(VM.NewString(Text(0))));
    if N = 'setName' then
    begin
      VM.GetObject(Arg(0).AsRef).Text := Text(1);
      Exit;
    end;
  end;
  if C = 'java/lang/String' then
  begin
    if TryInvokeJavaString(VM, Method, Arguments, DefaultEncoding, Result) then
      Exit;
    O := VM.GetObject(Arg(0).AsRef);
    S := O.Text;
    if N = '<init>' then
    begin
      if Length(Arguments) = 2 then
        O.Text := Text(1);
      Exit;
    end;
    if N = 'length' then
      Exit(TJVMValue.Int(Length(S)));
    if N = 'charAt' then
    begin
      I := Arg(1).AsInt;
      if (I < 0) or (I >= Length(S)) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      Exit(TJVMValue.Int(Ord(S[I + 1])));
    end;
    if N = 'equals' then
    begin
      I := Arg(1).AsRef;
      Exit(TJVMValue.Int(Ord((I <> 0) and (VM.GetObject(I).ClassName = 'java/lang/String') and (VM.GetObject(I).Text = S))));
    end;
    if N = 'hashCode' then
    begin
      Hash := 0;
      for I := 1 to Length(S) do
        Hash := Hash * 31 + Ord(S[I]);
      Exit(TJVMValue.Int(Hash));
    end;
    if N = 'toString' then
      Exit(Arg(0));
    if N = 'intern' then
      Exit(TJVMValue.Ref(VM.InternString(S)));
    if N = 'concat' then
      Exit(TJVMValue.Ref(VM.NewString(S + Text(1))));
    if N = 'substring' then
    begin
      I := Arg(1).AsInt;
      J := Length(S);
      if Length(Arguments) = 3 then
        J := Arg(2).AsInt;
      if (I < 0) or (J < I) or (J > Length(S)) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      Exit(TJVMValue.Ref(VM.NewString(Copy(S, I + 1, J - I))));
    end;
  end;
  if (C = 'java/lang/StringBuffer') or (C = 'java/lang/StringBuilder') then
    Exit(InvokeJavaBuilder(VM, Method, Arguments));
  if VM.IsAssignable(C, 'java/lang/Throwable') then
  begin
    O := VM.GetObject(Arg(0).AsRef);
    if N = '<init>' then
    begin
      V := TJVMValue.Ref(0);
      if Method.Descriptor = '(I)V' then
        V := TJVMValue.Ref(VM.NewString('Index out of range: ' + IntToStr(Arg(1).AsInt)))
      else if Length(Arguments) = 2 then
        V := Arg(1);
      O.Fields.AddOrSetValue('$message', V);
      O.Text := '';
      if V.AsRef <> 0 then
        O.Text := VM.GetObject(V.AsRef).Text;
      VM.CaptureThrowableTrace(Arg(0).AsRef, True);
      Exit;
    end;
    if N = 'getMessage' then
    begin
      if O.Fields.TryGetValue('$message', Result) then
        Exit;
      if O.Text = '' then
        Exit(TJVMValue.Ref(0));
      Result := TJVMValue.Ref(VM.NewString(O.Text));
      O.Fields.AddOrSetValue('$message', Result);
      Exit;
    end;
    if N = '$trace' then
      Exit(TJVMValue.Ref(VM.NewString(O.ThrowableTrace)));
    if (N = 'getCause') or (N = 'getException') then
    begin
      if not O.Fields.TryGetValue('$cause', Result) then
        Result := TJVMValue.Ref(0);
      Exit;
    end;
  end;
  if C = 'java/lang/System' then
  begin
    if N = 'exit' then
    begin
      VM.ExitApplication(Arg(0).AsInt);
      Exit;
    end;
    if N = 'getProperty' then
    begin
      S := Text(0);
      if S = '' then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      if GetProperty(S, T) then
        Exit(TJVMValue.Ref(VM.NewString(T)));
      if S = 'line.separator' then
        Exit(TJVMValue.Ref(VM.InternString(#10)));
      Exit(TJVMValue.Ref(0));
    end;
    if N = 'currentTimeMillis' then
      Exit(TJVMValue.Long(TimeMillis));
    if N = 'gc' then
    begin
      VM.CollectGarbage;
      Exit;
    end;
    if N = 'arraycopy' then
    begin
      Source := VM.GetObject(Arg(0).AsRef);
      I := Arg(1).AsInt;
      Dest := VM.GetObject(Arg(2).AsRef);
      J := Arg(3).AsInt;
      Count := Arg(4).AsInt;
      if not Source.IsArray or not Dest.IsArray then
        VM.RaiseJava('java/lang/ArrayStoreException');
      S := Copy(Source.ClassName, 2, MaxInt);
      T := Copy(Dest.ClassName, 2, MaxInt);
      if ((Length(S) = 1) or (Length(T) = 1)) and (S <> T) then
        VM.RaiseJava('java/lang/ArrayStoreException');
      if (I < 0) or (J < 0) or (Count < 0) or (Int64(I) + Count > Source.ElementCount) or
        (Int64(J) + Count > Dest.ElementCount) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      if (Length(S) = 1) or (Source = Dest) or VM.IsAssignable(Source.ClassName, Dest.ClassName) then
        Source.CopyArrayElementsTo(Dest, I, J, Count)
      else
      begin
        Component := T;
        if T.StartsWith('L') then
          Component := Copy(T, 2, Length(T) - 2);
        // Distinct reference arrays may fail after a compatible prefix. Preserve
        // Java's partial-copy behavior, without an intermediate tagged array.
        for K := 0 to Count - 1 do
        begin
          V := Source.ElementValues[I + K];
          if (V.AsRef <> 0) and not VM.IsAssignable(VM.GetObject(V.AsRef).ClassName, Component) then
            VM.RaiseJava('java/lang/ArrayStoreException');
          Dest.ElementValues[J + K] := V;
        end;
      end;
      Exit;
    end;
  end;
  if C = 'java/lang/Math' then
    Exit(InvokeJavaMath(VM, Method, Arguments));
  if (C = 'java/lang/Float') or (C = 'java/lang/Double') then
    Exit(InvokeJavaFloating(VM, Method, Arguments));
  raise EJVMUnsupported.Create('Native method not implemented: ' + C + '.' + N + D);
end;

end.

