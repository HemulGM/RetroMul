unit Java.Calendars;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaCalendars(VM: TJVM);

function InvokeJavaCalendar(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, Java.Classes, Java.Dates;

{$Q-}{$R-}

const
  Cal = 'java/util/Calendar';
  Gregorian = Cal + '$Gregorian';
  Zone = 'java/util/TimeZone';
  PublicFields: array[0..9] of Integer = (1, 2, 5, 7, 9, 10, 11, 12, 13, 14);

function Key(const Name, Desc: string): string;
begin
  Result := Cal + '.' + Name + ':' + Desc;
end;

procedure InstallJavaCalendars(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Native(const N, D: string; Access: Word = JVM_ACC_PRIVATE);
  begin
    B.JavaClass.AddNative(N, D).Access := Access or JVM_ACC_NATIVE;
  end;

  procedure Call(Op: Byte; const N, D: string);
  begin
    B.Ref(Op, B.Member(Cal, N, D));
  end;

  procedure Constant(const N: string; V: Integer);
  begin
    B.Field(N, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(V);
  end;

  procedure Compute(const Name, Done: string);
  begin
    B.Emit([$2A]);
    Call($B6, Name, '()V');
    B.Emit([$2A]);
    Call($B7, Done, '()V');
  end;

begin
  B := TJavaClassBuilder.Create(Cal, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    B.Field('fields', '[I', JVM_ACC_PROTECTED);
    B.Field('isSet', '[Z', JVM_ACC_PROTECTED);
    B.Field('time', 'J', JVM_ACC_PROTECTED);
    B.Field('$zone', 'Ljava/util/TimeZone;', JVM_ACC_PRIVATE);
    B.Field('$stamps', '[I', JVM_ACC_PRIVATE);
    for var N in ['$timeValid', '$fieldsValid', '$nextStamp'] do
      B.Field(N, 'I', JVM_ACC_PRIVATE);
    Constant('YEAR', 1);
    Constant('MONTH', 2);
    Constant('DATE', 5);
    Constant('DAY_OF_MONTH', 5);
    Constant('DAY_OF_WEEK', 7);
    Constant('AM_PM', 9);
    Constant('HOUR', 10);
    Constant('HOUR_OF_DAY', 11);
    Constant('MINUTE', 12);
    Constant('SECOND', 13);
    Constant('MILLISECOND', 14);
    var Names: TArray<string> := ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
    for var I := 0 to High(Names) do
      Constant(Names[I], I);
    Names := ['SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY'];
    for var I := 0 to High(Names) do
      Constant(Names[I], I + 1);
    Constant('AM', 0);
    Constant('PM', 1);
    Native('$init', '(Ljava/util/TimeZone;)V');
    Native('$needTime', '()Z');
    Native('$needFields', '()Z');
    Native('$didTime', '()V');
    Native('$didFields', '()V');
    Native('$setMillis', '(J)V');
    Native('$fillBeforeSet', '()Z');
    Native('$check', '(I)V');
    Native('$get', '(I)I');
    Native('$set', '(II)V');
    Native('getTimeZone', '()Ljava/util/TimeZone;', JVM_ACC_PUBLIC);
    Native('setTimeZone', '(Ljava/util/TimeZone;)V', JVM_ACC_PUBLIC);
    Native('getInstance', '(Ljava/util/TimeZone;)Ljava/util/Calendar;', JVM_ACC_PUBLIC or JVM_ACC_STATIC);
    for var N in ['computeFields', 'computeTime'] do
      B.JavaClass.AddNative(N, '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member('java/lang/Object', '<init>', '()V'));
    B.Emit([$2A]);
    B.Ref($B8, B.Member(Zone, 'getDefault', '()Ljava/util/TimeZone;'));
    Call($B7, '$init', '(Ljava/util/TimeZone;)V');
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PROTECTED, 2, 1);
    B.Start;
    B.Ref($B8, B.Member(Zone, 'getDefault', '()Ljava/util/TimeZone;'));
    Call($B8, 'getInstance', '(Ljava/util/TimeZone;)Ljava/util/Calendar;');
    B.Emit([$B0]);
    B.Finish('getInstance', '()Ljava/util/Calendar;', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 1, 0);
    B.Start;
    B.Emit([$2A]);
    Call($B7, '$needTime', '()Z');
    B.Jump($99, 'done');
    Compute('computeTime', '$didTime');
    B.Mark('done');
    B.Emit([$2A]);
    B.Ref($B4, B.Member(Cal, 'time', 'J', 9));
    B.Emit([$AD]);
    B.Finish('getTimeInMillis', '()J', JVM_ACC_PROTECTED, 2, 1);
    B.Start;
    B.Emit([$2A, $1F]);
    Call($B7, '$setMillis', '(J)V');
    Compute('computeFields', '$didFields');
    B.Emit([$B1]);
    B.Finish('setTimeInMillis', '(J)V', JVM_ACC_PROTECTED, 3, 3);
    B.Start;
    B.Ref($BB, B.ClassRef('java/util/Date'));
    B.Emit([$59, $2A]);
    Call($B6, 'getTimeInMillis', '()J');
    B.Ref($B7, B.Member('java/util/Date', '<init>', '(J)V'));
    B.Emit([$B0]);
    B.Finish('getTime', '()Ljava/util/Date;', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 4, 1);
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member('java/util/Date', 'getTime', '()J'));
    Call($B6, 'setTimeInMillis', '(J)V');
    B.Emit([$B1]);
    B.Finish('setTime', '(Ljava/util/Date;)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 3, 2);
    B.Start;
    B.Emit([$2A, $1B]);
    Call($B7, '$check', '(I)V');
    B.Emit([$2A]);
    Call($B6, 'getTimeInMillis', '()J');
    B.Emit([$58, $2A]);
    Call($B7, '$needFields', '()Z');
    B.Jump($99, 'done');
    Compute('computeFields', '$didFields');
    B.Mark('done');
    B.Emit([$2A, $1B]);
    Call($B7, '$get', '(I)I');
    B.Emit([$AC]);
    B.Finish('get', '(I)I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 2, 2);
    B.Start;
    B.Emit([$2A, $1B]);
    Call($B7, '$check', '(I)V');
    B.Emit([$2A]);
    Call($B7, '$fillBeforeSet', '()Z');
    B.Jump($99, 'done');
    Compute('computeFields', '$didFields');
    B.Mark('done');
    B.Emit([$2A, $1B, $1C]);
    Call($B7, '$set', '(II)V');
    B.Emit([$B1]);
    B.Finish('set', '(II)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 3, 3);
    for var N in ['equals', 'before', 'after'] do
    begin
      B.Start;
      B.Emit([$2B]);
      B.Ref($C1, B.ClassRef(Cal));
      B.Jump($99, 'no');
      B.Emit([$2A]);
      Call($B6, 'getTimeInMillis', '()J');
      B.Emit([$2B]);
      B.Ref($C0, B.ClassRef(Cal));
      Call($B6, 'getTimeInMillis', '()J');
      B.Emit([$94]);
      if N = 'before' then
        B.Jump($9C, 'no')
      else if N = 'after' then
        B.Jump($9E, 'no')
      else
      begin
        B.Jump($9A, 'no');
        B.Emit([$2A]);
        Call($B6, 'getTimeZone', '()Ljava/util/TimeZone;');
        B.Emit([$2B]);
        B.Ref($C0, B.ClassRef(Cal));
        Call($B6, 'getTimeZone', '()Ljava/util/TimeZone;');
        B.Ref($B6, B.Member('java/lang/Object', 'equals', '(Ljava/lang/Object;)Z'));
        B.Emit([$AC]);
      end;
      B.Emit([$04, $AC]);
      B.Mark('no');
      B.Emit([$03, $AC]);
      B.Finish(N, '(Ljava/lang/Object;)Z', JVM_ACC_PUBLIC, 4, 2);
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(Gregorian, Cal, JVM_ACC_FINAL or $20);
  try
    B.JavaClass.AddNative('computeFields', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('computeTime', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    B.Start;
    B.Emit([$2A]);
    Call($B7, '<init>', '()V');
    B.Emit([$2A, $2B]);
    Call($B6, 'setTimeZone', '(Ljava/util/TimeZone;)V');
    B.Emit([$2A, $20]);
    Call($B6, 'setTimeInMillis', '(J)V');
    B.Emit([$B1]);
    B.Finish('<init>', '(Ljava/util/TimeZone;J)V', 0, 3, 4);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaCalendar(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, Fields, Flags, Stamps, State: TJVMObject;
  N: string;
  Value, Continuation: TJVMValue;
  StateRef, Phase: Integer;

  function Get(const Name, Desc: string): TJVMValue;
  begin
    Result := O.Fields[Key(Name, Desc)];
  end;

  procedure Put(const Name, Desc: string; V: TJVMValue);
  begin
    O.Fields[Key(Name, Desc)] := V;
  end;

  procedure Int(const Name: string; V: Integer);
  begin
    Put(Name, 'I', TJVMValue.Int(V));
  end;

  procedure Arrays;
  begin
    Fields := VM.GetObject(Get('fields', '[I').AsRef);
    Flags := VM.GetObject(Get('isSet', '[Z').AsRef);
    Stamps := VM.GetObject(Get('$stamps', '[I').AsRef);
    if (Length(Fields.Elements) < 17) or (Length(Flags.Elements) < 17) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException', 'Calendar arrays');
  end;

  function F(Index, DefaultValue: Integer): Int64;
  begin
    if Flags.Elements[Index].AsInt = 0 then
      Result := DefaultValue
    else
      Result := Fields.Elements[Index].AsInt;
  end;

  procedure S(Index, V: Integer);
  begin
    Fields.Elements[Index] := TJVMValue.Int(V);
    Flags.Elements[Index] := TJVMValue.Int(1);
    Stamps.Elements[Index] := TJVMValue.Int(1);
  end;

  function ReadState(const K: string): TJVMValue;
  begin
    Result := State.Fields[K];
  end;

  procedure SaveState(const K: string; V: TJVMValue);
  begin
    State.Fields.AddOrSetValue(K, V);
  end;

  procedure OffsetCall(Millis, Offset: Int64; NextPhase: Integer);
  var
    Day: Int64;
    Time: Integer;
  begin
    JavaSplitMillis(Millis, Offset, Day, Time);
    var D := JavaCivil(Day, Time);
    var Era := 1;
    if D.Year <= 0 then
    begin
      Era := 0;
      D.Year := 1 - D.Year;
    end;
    SaveState('phase', TJVMValue.Int(NextPhase));
    var Ref := ReadState('zone').AsRef;
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Ref, VM.LoadClass(Zone).FindMethod('getOffset', '(IIIIII)I')),
      [TJVMValue.Ref(Ref), TJVMValue.Int(Era), TJVMValue.Int(Integer(D.Year)), TJVMValue.Int(D.Month - 1), TJVMValue.Int(D.Day), TJVMValue.Int(D.DayOfWeek), TJVMValue.Int(Time)]);
  end;

begin
  Result := Default(TJVMValue);
  N := Method.Name;
  if N = 'getInstance' then
  begin
    VM.GetObject(Args[0].AsRef); // Null zone is a Java error before allocation.
    if VM.TakeGuestResult(Value) then
      Exit(VM.NativeContinuation);
    var Ref := VM.NewObject(Gregorian);
    VM.SetNativeContinuation(TJVMValue.Ref(Ref));
    VM.InvokeGuestResult(VM.LoadClass(Gregorian).FindMethod('<init>', '(Ljava/util/TimeZone;J)V'), [TJVMValue.Ref(Ref), Args[0], TJVMValue.Long(VM.Host.TimeMillis)]);
    Exit;
  end;
  O := VM.GetObject(Args[0].AsRef);
  if N = '$init' then
  begin
    Put('fields', '[I', TJVMValue.Ref(VM.NewArray('[I', 17)));
    Put('isSet', '[Z', TJVMValue.Ref(VM.NewArray('[Z', 17)));
    Put('$stamps', '[I', TJVMValue.Ref(VM.NewArray('[I', 17)));
    Put('$zone', 'Ljava/util/TimeZone;', Args[1]);
    Int('$nextStamp', 2);
    Exit;
  end;
  if N = '$check' then
  begin
    var I := Args[1].AsInt;
    for var Valid in PublicFields do
      if I = Valid then
        Exit;
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException', IntToStr(I));
  end;
  if N = '$needTime' then
    Exit(TJVMValue.Int(Ord(Get('$timeValid', 'I').AsInt = 0)));
  if N = '$needFields' then
    Exit(TJVMValue.Int(Ord(Get('$fieldsValid', 'I').AsInt = 0)));
  if N = '$fillBeforeSet' then
    Exit(TJVMValue.Int(Ord((Get('$timeValid', 'I').AsInt <> 0) and (Get('$fieldsValid', 'I').AsInt = 0))));
  if N = '$didTime' then
  begin
    Int('$timeValid', 1);
    Exit;
  end;
  if N = '$didFields' then
  begin
    Int('$fieldsValid', 1);
    Exit;
  end;
  if N = '$setMillis' then
  begin
    Put('time', 'J', Args[1]);
    Int('$timeValid', 1);
    Int('$fieldsValid', 0);
    Exit;
  end;
  if N = 'getTimeZone' then
    Exit(Get('$zone', 'Ljava/util/TimeZone;'));
  if N = 'setTimeZone' then
  begin
    VM.GetObject(Args[1].AsRef);
    Put('$zone', 'Ljava/util/TimeZone;', Args[1]);
    Int('$fieldsValid', 0);
    Exit;
  end;
  if N = '$get' then
  begin
    Arrays;
    Exit(Fields.Elements[Args[1].AsInt]);
  end;
  if N = '$set' then
  begin
    Arrays;
    var I := Args[1].AsInt;
    Fields.Elements[I] := Args[2];
    Flags.Elements[I] := TJVMValue.Int(1);
    var Stamp := Get('$nextStamp', 'I').AsInt;
    if Stamp = High(Integer) then
    begin
      // Only relative order matters. Compact the at most17 live stamps.
      var Old: TArray<Integer>;
      SetLength(Old, 17);
      for var K := 0 to 16 do
        Old[K] := Stamps.Elements[K].AsInt;
      for var K := 0 to 16 do
        if Old[K] >= 2 then
        begin
          var Rank := 2;
          for var J := 0 to 16 do
            if (Old[J] >= 2) and (Old[J] < Old[K]) then
              Inc(Rank);
          Stamps.Elements[K] := TJVMValue.Int(Rank);
        end;
      Stamp := 19;
    end;
    Stamps.Elements[I] := TJVMValue.Int(Stamp);
    Int('$nextStamp', Stamp + 1);
    Int('$timeValid', 0);
    Int('$fieldsValid', 0);
    Exit;
  end;
  if (N <> 'computeTime') and (N <> 'computeFields') then
    raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N);
  Continuation := VM.NativeContinuation;
  if Continuation.Kind <> TJVMKind.Reference then
  begin
    Arrays;
    StateRef := VM.NewObject('java/lang/Object');
    State := VM.GetObject(StateRef);
    VM.SetNativeContinuation(TJVMValue.Ref(StateRef));
    SaveState('zone', Get('$zone', 'Ljava/util/TimeZone;'));
    SaveState('phase', TJVMValue.Int(1));
    var Millis := Get('time', 'J').AsLong;
    if N = 'computeTime' then
    begin
      var Year := F(1, 1970);
      if F(0, 1) = 0 then
        Year := 1 - Year;
      var Day := JavaDateDay(Year, F(2, 0), F(5, 1));
      if Stamps.Elements[7].AsInt > Stamps.Elements[5].AsInt then
      begin
        var First := JavaDateDay(Year, F(2, 0), 1);
        var FirstDate := JavaCivil(First, 0);
        Day := First - (FirstDate.DayOfWeek - 1) + (F(4, 1) - 1) * 7 + F(7, 1) - 1;
      end;
      var Hour := F(11, 0);
      var HourStamp := Stamps.Elements[10].AsInt;
      var AmStamp := Stamps.Elements[9].AsInt;
      if AmStamp > HourStamp then
        HourStamp := AmStamp;
      if HourStamp > Stamps.Elements[11].AsInt then
        Hour := F(10, 0) + 12 * F(9, 0);
      var Time := ((Hour * 60 + F(12, 0)) * 60 + F(13, 0)) * 1000 + F(14, 0);
      Millis := JavaDateMillis(Day, Time, 0);
    end;
    SaveState('millis', TJVMValue.Long(Millis));
    var Ref := ReadState('zone').AsRef;
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Ref, VM.LoadClass(Zone).FindMethod('getRawOffset', '()I')), [TJVMValue.Ref(Ref)]);
    Exit;
  end;
  State := VM.GetObject(Continuation.AsRef);
  Phase := ReadState('phase').AsInt;
  if not VM.TakeGuestResult(Value) then
    raise EJVMError.Create('Missing calendar callback');
  var Millis := ReadState('millis').AsLong;
  if Phase = 1 then
  begin
    SaveState('raw', Value);
    if N = 'computeFields' then
      OffsetCall(Millis, Value.AsInt, 2)
    else
      OffsetCall(Millis, 0, 2);
    Exit;
  end;
  if N = 'computeTime' then
  begin
    Put('time', 'J', TJVMValue.Long(JavaDateMillis(0, Millis, Value.AsInt)));
    Exit;
  end;
  var Day: Int64;
  var Time: Integer;
  JavaSplitMillis(Millis, Value.AsInt, Day, Time);
  var D := JavaCivil(Day, Time);
  Arrays;
  var Era := 1;
  if D.Year <= 0 then
  begin
    Era := 0;
    D.Year := 1 - D.Year;
  end;
  S(0, Era);
  S(1, Integer(D.Year));
  S(2, D.Month - 1);
  S(5, D.Day);
  S(7, D.DayOfWeek);
  var AstronomicalYear := D.Year;
  if Era = 0 then
    AstronomicalYear := 1 - D.Year;
  var First := JavaDateDay(AstronomicalYear, D.Month - 1, 1);
  var FirstDate := JavaCivil(First, 0);
  S(4, Integer((Day - First + FirstDate.DayOfWeek - 1) div 7 + 1));
  S(9, D.Hour div 12);
  S(10, D.Hour mod 12);
  S(11, D.Hour);
  S(12, D.Minute);
  S(13, D.Second);
  S(14, D.Millisecond);
  S(15, ReadState('raw').AsInt);
  S(16, Value.AsInt - ReadState('raw').AsInt);
  Int('$nextStamp', 2);
end;

end.

