unit J2ME.DateField;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEDateField(VM: TJVM);

function InvokeJ2MEDateField(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Changed: Boolean): TJVMValue;

function J2MEDateFieldText(O: TJVMObject): string;

function J2MEDateFieldKey(VM: TJVM; Item, Code: Integer): Boolean;

procedure J2MEDateFieldSelection(O: TJVMObject; out Start, Count: Integer);

implementation

uses
  System.SysUtils, System.Math, Java.Classes, Java.Dates, J2ME.UI.Data;

{$Q-}{$R-}

const
  Name = J2MEUI + 'DateField';
  Cal = 'java/util/Calendar';
  Zone = 'java/util/TimeZone';
  DateName = 'java/util/Date';
  Keys: array[0..4] of Integer = (1, 2, 5, 11, 12);
  Limits: array[0..4] of Integer = (9999, 12, 31, 23, 59);

function Part(O: TJVMObject): Integer;
begin
  Result := UIInt(O, 'datePart');
  case UIInt(O, 'dateMode') of
    1:
      Result := EnsureRange(Result, 0, 2);
    2:
      Result := EnsureRange(Result, 3, 4);
  else
    Result := EnsureRange(Result, 0, 4);
  end;
end;

function Token(O: TJVMObject; I: Integer): string;
begin
  var Width := 2;
  if I = 0 then
    Width := 4;
  if UIInt(O, 'dateSet') = 0 then
    Exit(StringOfChar('-', Width));
  var V := UIInt(O, 'date' + IntToStr(I));
  if I = 1 then
    Inc(V);
  Result := IntToStr(V);
  while Length(Result) < Width do
    Result := '0' + Result;
end;

function J2MEDateFieldText(O: TJVMObject): string;
begin
  Result := '';
  var Mode := UIInt(O, 'dateMode');
  if Mode <> 2 then
    Result := Token(O, 0) + '-' + Token(O, 1) + '-' + Token(O, 2);
  if Mode <> 1 then
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Token(O, 3) + ':' + Token(O, 4);
  end;
end;

procedure J2MEDateFieldSelection(O: TJVMObject; out Start, Count: Integer);
begin
  Start := 0;
  var I := Part(O);
  var First := 0;
  if UIInt(O, 'dateMode') = 2 then
    First := 3;
  for var J := First to I - 1 do
    Inc(Start, Length(Token(O, J)) + 1);
  Count := Length(Token(O, I));
end;

procedure InstallJ2MEDateField(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(Name, J2MEUI + 'Item');
  try
    for var I := 1 to 3 do
    begin
      var N := 'DATE';
      if I = 2 then
        N := 'TIME'
      else if I = 3 then
        N := 'DATE_TIME';
      B.Field(N, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
    end;
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;I)V');
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;ILjava/util/TimeZone;)V');
    B.JavaClass.AddNative('getInputMode', '()I');
    B.JavaClass.AddNative('getDate', '()Ljava/util/Date;').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('setDate', '(Ljava/util/Date;)V').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('setInputMode', '(I)V').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('$edit', '(III)V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('$input', '(Ljava/lang/String;)V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function NewDate(VM: TJVM; Millis: Int64): Integer;
begin
  Result := VM.NewObject(DateName);
  VM.GetObject(Result).Fields[DateName + '.$time:J'] := TJVMValue.Long(Millis);
end;

function InvokeJ2MEDateField(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Changed: Boolean): TJVMValue;
var
  O, State: TJVMObject;
  N: string;
  V: TJVMValue;
  Phase, Index, Mode: Integer;

  function Get(const K: string): TJVMValue;
  begin
    Result := State.Fields[K];
  end;

  procedure Put(const K: string; Value: TJVMValue);
  begin
    State.Fields.AddOrSetValue(K, Value);
  end;

  procedure Int(const K: string; Value: Integer);
  begin
    Put(K, TJVMValue.Int(Value));
  end;

  procedure Invoke(const C, M, D: string; const Values: array of TJVMValue; Next: Integer; virtual: Boolean = False);
  begin
    Int('phase', Next);
    var Target := VM.LoadClass(C).FindMethod(M, D);
    if virtual then
      Target := VM.ResolveVirtualMethod(Values[0].AsRef, Target);
    VM.InvokeGuestResult(Target, Values);
  end;

  procedure ReadFields(Next: Integer);
  begin
    Invoke(Cal, 'get', '(I)I', [Get('calendar'), TJVMValue.Int(Keys[Index])], Next, True);
  end;

  procedure CalendarFactory;
  begin
    Invoke(Cal, 'getInstance', '(Ljava/util/TimeZone;)Ljava/util/Calendar;', [Get('zone')], 2);
  end;

  procedure ModeCheck(Value: Integer);
  begin
    if (Value < 1) or (Value > 3) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'DateField input mode');
  end;

  procedure Clear;
  begin
    Changed := UIInt(O, 'dateSet') <> 0;
    UIPut(O, 'dateSet', 0);
    UIPut(O, 'dateDigits', 0);
  end;

  procedure AddOp(K, Value: Integer);
  begin
    var I := Get('opCount').AsInt;
    Int('key' + IntToStr(I), K);
    Int('value' + IntToStr(I), Value);
    Int('opCount', I + 1);
  end;

  function Component(I: Integer): Integer;
  begin
    Result := Get('component' + IntToStr(I)).AsInt;
  end;

  procedure SetComponent(I, Value: Integer);
  begin
    Int('component' + IntToStr(I), Value);
  end;

  procedure Commit;
  begin
    var Initialized := Get('initialized').AsInt;
    Changed := (UIInt(O, 'dateSet') <> Initialized) or (UIInt(O, 'dateMode') <> Mode) or
      ((Initialized <> 0) and (UILong(O, 'dateValue') <> Get('millis').AsLong));
    if N = '<init>' then
    begin
      UIInitItem(O, Args[1].AsRef);
      UIPut(O, 'itemKind', 7);
      Changed := True;
    end;
    UIPutRef(O, 'dateZone', Get('zone').AsRef);
    UIPut(O, 'dateMode', Mode);
    UIPut(O, 'dateSet', Initialized);
    UIPutLong(O, 'dateValue', Get('millis').AsLong);
    for var I := 0 to 4 do
      UIPut(O, 'date' + IntToStr(I), Component(I));
    if (N = 'setInputMode') or (N = 'setDate') or (N = '$input') then
      UIPut(O, 'dateDigits', 0);
    if N = 'setInputMode' then
      UIPut(O, 'editing', 0);
  end;

  function ParseInput(const Text: string): Boolean;
  var
    Values: TArray<Integer>;

    function Number(Offset, Count: Integer; out Value: Integer): Boolean;
    begin
      Result := False;
      Value := 0;
      if Length(Text) < Offset + Count - 1 then
        Exit;
      for var I := Offset to Offset + Count - 1 do
      begin
        if not CharInSet(Text[I], ['0'..'9']) then
          Exit;
        Value := Value * 10 + Ord(Text[I]) - 48;
      end;
      Result := True;
    end;

  begin
    Result := False;
    SetLength(Values, 5);
    var Start := 1;
    if Mode <> 2 then
    begin
      if (Length(Text) < 10) or (Text[5] <> '-') or (Text[8] <> '-') or not Number(1, 4, Values[0]) or not Number(6, 2, Values[1]) or not Number(9, 2, Values[2]) then
        Exit;
      if (Values[0] < 1) or (Values[1] < 1) or (Values[1] > 12) or (Values[2] < 1) or (Values[2] > JavaMonthDays(Values[0], Values[1] - 1)) then
        Exit;
      Dec(Values[1]);
      Start := 12;
    end;
    if Mode <> 1 then
    begin
      if Mode = 2 then
        Start := 1
      else if (Length(Text) < 11) or (Text[11] <> ' ') then
        Exit;
      if (Length(Text) <> Start + 4) or (Text[Start + 2] <> ':') or not Number(Start, 2, Values[3]) or not Number(Start + 3, 2, Values[4]) or (Values[3] > 23) or (Values[4] > 59) then
        Exit;
    end
    else if Length(Text) <> 10 then
      Exit;
    for var I := 0 to 4 do
      Int('input' + IntToStr(I), Values[I]);
    Result := True;
  end;

begin
  Result := Default(TJVMValue);
  Changed := False;
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if N = 'getInputMode' then
    Exit(TJVMValue.Int(UIInt(O, 'dateMode')));
  if N = 'getDate' then
  begin
    if UIInt(O, 'dateSet') = 0 then
      Exit(TJVMValue.Ref(0));
    Exit(TJVMValue.Ref(NewDate(VM, UILong(O, 'dateValue'))));
  end;
  if N = 'setDate' then
  begin
    if Args[1].AsRef = 0 then
    begin
      Clear;
      Exit;
    end;
  end;
  if N = 'setInputMode' then
  begin
    ModeCheck(Args[1].AsInt);
    if Args[1].AsInt = UIInt(O, 'dateMode') then
      Exit;
    if UIInt(O, 'dateSet') = 0 then
    begin
      UIPut(O, 'dateMode', Args[1].AsInt);
      UIPut(O, 'dateDigits', 0);
      UIPut(O, 'editing', 0);
      Changed := True;
      Exit;
    end;
  end;
  if (N = '$edit') and (Args[1].AsInt = -2) then
  begin
    Clear;
    Exit;
  end;
  V := VM.NativeContinuation;
  if V.Kind <> TJVMKind.Reference then
  begin
    Mode := UIInt(O, 'dateMode');
    if N = '<init>' then
      Mode := Args[2].AsInt
    else if N = 'setInputMode' then
      Mode := Args[1].AsInt;
    ModeCheck(Mode);
    var Ref := VM.NewObject('java/lang/Object');
    State := VM.GetObject(Ref);
    VM.SetNativeContinuation(TJVMValue.Ref(Ref));
    Int('mode', Mode);
    Int('initialized', 1);
    Int('index', 0);
    Int('opCount', 0);
    Put('millis', TJVMValue.Long(0));
    if N = '$input' then
      if not ParseInput(VM.GetObject(Args[1].AsRef).Text) then
        Exit;
    var ZoneRef := UIRef(O, 'dateZone');
    if N = '<init>' then
    begin
      ZoneRef := 0;
      if Length(Args) = 4 then
        ZoneRef := Args[3].AsRef;
    end;
    if ZoneRef = 0 then
    begin
      Invoke(Zone, 'getDefault', '()Ljava/util/TimeZone;', [], 1);
      Exit;
    end;
    Put('zone', TJVMValue.Ref(ZoneRef));
    CalendarFactory;
    Exit;
  end;
  State := VM.GetObject(V.AsRef);
  Mode := Get('mode').AsInt;
  Phase := Get('phase').AsInt;
  if not VM.TakeGuestResult(V) then
    raise EJVMError.Create('Missing DateField callback');
  if Phase = 1 then
  begin
    Put('zone', V);
    CalendarFactory;
    Exit;
  end;
  if Phase = 2 then
  begin
    Put('calendar', V);
    if N = '<init>' then
    begin
      Int('initialized', 0);
      Index := 0;
      ReadFields(4);
      Exit;
    end;
    var InputDate: Integer;
    if N = 'setDate' then
      InputDate := Args[1].AsRef
    else
    begin
      var Millis := UILong(O, 'dateValue');
      if UIInt(O, 'dateSet') = 0 then
        Millis := VM.Host.TimeMillis;
      InputDate := NewDate(VM, Millis);
    end;
    Invoke(Cal, 'setTime', '(Ljava/util/Date;)V', [Get('calendar'), TJVMValue.Ref(InputDate)], 3, True);
    Exit;
  end;
  if Phase = 3 then
  begin
    Index := 0;
    Int('index', 0);
    ReadFields(4);
    Exit;
  end;
  if Phase = 4 then
  begin
    Index := Get('index').AsInt;
    SetComponent(Index, V.AsInt);
    Inc(Index);
    Int('index', Index);
    if Index < 5 then
    begin
      ReadFields(4);
      Exit;
    end;
    if N = '<init>' then
    begin
      Commit;
      Exit;
    end;
    if N = 'setDate' then
    begin
      // TIME accepts instants within the epoch day; the zone supplies local
      // hour/minute, whose date components are then pinned to January1,1970.
      Invoke(Cal, 'getTime', '()Ljava/util/Date;', [Get('calendar')], 10, True);
      Exit;
    end;
    Phase := 5;
  end;
  if Phase = 10 then
  begin
    Put('date', V);
    Invoke(DateName, 'getTime', '()J', [V], 11, True);
    Exit;
  end;
  if Phase = 11 then
  begin
    if (Mode = 2) and ((V.AsLong < 0) or (V.AsLong >= JavaDayMillis)) then
    begin
      Clear;
      Exit;
    end;
    Phase := 5;
  end;
  if Phase = 5 then
  begin
    if N = '$input' then
      for var I := 0 to 4 do
      begin
        if ((Mode <> 2) and (I < 3)) or ((Mode <> 1) and (I >= 3)) then
          SetComponent(I, Get('input' + IntToStr(I)).AsInt);
      end;
    if (N = '$edit') and (Args[1].AsInt >= 0) then
    begin
      var I := Args[1].AsInt;
      if I > 4 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Date component');
      var NewValue := Args[2].AsInt;
      var Lower := 0;
      if I in [0, 2] then
        Lower := 1;
      var Maximum := Limits[I];
      if I = 1 then
        Maximum := 11
      else if I = 2 then
        Maximum := JavaMonthDays(Component(0), Component(1));
      if Args[3].AsInt <> 0 then
      begin
        NewValue := Component(I) + NewValue;
        if NewValue > Maximum then
          NewValue := Lower
        else if NewValue < Lower then
          NewValue := Maximum;
      end;
      if (NewValue < Lower) or (NewValue > Maximum) then
        Exit;
      SetComponent(I, NewValue);
      var MaxDay := JavaMonthDays(Component(0), Component(1));
      if Component(2) > MaxDay then
        SetComponent(2, MaxDay);
    end;
    if Mode = 1 then
    begin
      SetComponent(3, 0);
      SetComponent(4, 0);
    end
    else if Mode = 2 then
    begin
      SetComponent(0, 1970);
      SetComponent(1, 0);
      SetComponent(2, 1);
    end;
    // Start with day1 to avoid normalizing an old31st while changing the month.
    AddOp(5, 1);
    for var I := 0 to 4 do
      AddOp(Keys[I], Component(I));
    AddOp(13, 0);
    AddOp(14, 0);
    Int('index', 0);
    Index := 0;
    Invoke(Cal, 'set', '(II)V', [Get('calendar'), Get('key0'), Get('value0')], 6, True);
    Exit;
  end;
  if Phase = 6 then
  begin
    Index := Get('index').AsInt + 1;
    Int('index', Index);
    if Index < Get('opCount').AsInt then
    begin
      Invoke(Cal, 'set', '(II)V', [Get('calendar'), Get('key' + IntToStr(Index)), Get('value' + IntToStr(Index))], 6, True);
      Exit;
    end;
    Invoke(Cal, 'getTime', '()Ljava/util/Date;', [Get('calendar')], 7, True);
    Exit;
  end;
  if Phase = 7 then
  begin
    Put('date', V);
    Invoke(DateName, 'getTime', '()J', [V], 8, True);
    Exit;
  end;
  if Phase = 8 then
  begin
    Put('millis', V);
    Int('index', 0);
    Index := 0;
    ReadFields(9);
    Exit;
  end;
  if Phase = 9 then
  begin
    Index := Get('index').AsInt;
    SetComponent(Index, V.AsInt);
    Inc(Index);
    Int('index', Index);
    if Index < 5 then
    begin
      ReadFields(9);
      Exit;
    end;
    Commit;
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N);
end;

function J2MEDateFieldKey(VM: TJVM; Item, Code: Integer): Boolean;
var
  O: TJVMObject;

  procedure Edit(I, V, Delta: Integer);
  begin
    VM.InvokeGuest(VM.LoadClass(Name).FindMethod('$edit', '(III)V'), [TJVMValue.Ref(Item), TJVMValue.Int(I), TJVMValue.Int(V), TJVMValue.Int(Delta)]);
  end;

begin
  O := VM.GetObject(Item);
  Result := True;
  var Mode := UIInt(O, 'dateMode');
  var P := Part(O);
  if Code = -1003 then
    Exit(False);
  if Code = -8 then
  begin
    UIPut(O, 'dateDigits', 0);
    Edit(-2, 0, 0);
    Exit;
  end;
  if Code = -5 then
  begin
    UIPut(O, 'editing', 1 - UIInt(O, 'editing'));
    UIPut(O, 'dateDigits', 0);
    if (UIInt(O, 'editing') <> 0) and (UIInt(O, 'dateSet') = 0) then
      Edit(-1, 0, 0);
    Exit;
  end;
  if (Code = -3) or (Code = -4) then
  begin
    var Lo := 0;
    var Hi := 4;
    if Mode = 1 then
      Hi := 2
    else if Mode = 2 then
      Lo := 3;
    if Code = -3 then
      Dec(P)
    else
      Inc(P);
    if P < Lo then
      P := Hi
    else if P > Hi then
      P := Lo;
    UIPut(O, 'datePart', P);
    UIPut(O, 'editing', 1);
    UIPut(O, 'dateDigits', 0);
    Exit;
  end;
  if (Code = -1) or (Code = -2) then
  begin
    if UIInt(O, 'editing') = 0 then
      Exit(False);
    UIPut(O, 'dateDigits', 0);
    var Delta := 1;
    if Code = -2 then
      Delta := -1;
    Edit(P, Delta, 1);
    Exit;
  end;
  if (Code >= 48) and (Code <= 57) then
  begin
    var Digits := UIInt(O, 'dateDigits');
    var Maximum := 2;
    if P = 0 then
      Maximum := 4;
    var Number := UIInt(O, 'dateNumber');
    if Digits >= Maximum then
    begin
      Number := 0;
      Digits := 0;
    end;
    Number := Number * 10 + Code - 48;
    Inc(Digits);
    UIPut(O, 'dateNumber', Number);
    UIPut(O, 'dateDigits', Digits);
    UIPut(O, 'editing', 1);
    if (Number > Limits[P]) or ((Number = 0) and (P < 3)) then
      Exit;
    if P = 1 then
      Dec(Number);
    Edit(P, Number, 0);
    Exit;
  end;
  Result := False;
end;

end.

