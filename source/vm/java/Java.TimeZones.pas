unit Java.TimeZones;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaTimeZones(VM: TJVM);

function InvokeJavaTimeZone(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultID: string): TJVMValue;

function JavaZoneID(const ID: string; out Offset: Integer): string;

implementation

{$Q-}{$R-}

uses
  System.SysUtils, Java.Classes, Java.Dates;

const
  Zone = 'java/util/TimeZone';
  FixedZone = Zone + '$Fixed';
  IDKey = Zone + '.$id:Ljava/lang/String;';
  OffsetKey = FixedZone + '.$offset:I';

function JavaZoneID(const ID: string; out Offset: Integer): string;

  function Digits(const S: string; out Value: Integer): Boolean;
  begin
    Value := 0;
    Result := False;
    if (Length(S) < 1) or (Length(S) > 2) then
      Exit;
    for var C in S do
    begin
      if (C < '0') or (C > '9') then
        Exit;
      Value := Value * 10 + Ord(C) - 48;
    end;
    Result := True;
  end;

begin
  Offset := 0;
  if (ID = 'GMT') or (ID = 'UTC') then
    Exit(ID);
  Result := 'GMT';
  if not ID.StartsWith('GMT') or (Length(ID) < 5) or not CharInSet(ID[4], ['+', '-']) then
    Exit;
  var Tail := Copy(ID, 5, MaxInt);
  var Colon := Pos(':', Tail);
  var Hours, Minutes: Integer;
  if Colon <> 0 then
  begin
    if not Digits(Copy(Tail, 1, Colon - 1), Hours) or (Length(Tail) - Colon <> 2) or not Digits(Copy(Tail, Colon + 1, 2), Minutes) then
      Exit;
  end
  else if Length(Tail) <= 2 then
  begin
    if not Digits(Tail, Hours) then
      Exit;
    Minutes := 0;
  end
  else
  begin
    if not Digits(Copy(Tail, 1, Length(Tail) - 2), Hours) or not Digits(Copy(Tail, Length(Tail) - 1, 2), Minutes) then
      Exit;
  end;
  if (Hours > 23) or (Minutes > 59) then
    Exit;
  Offset := (Hours * 60 + Minutes) * 60000;
  if ID[4] = '-' then
    Offset := -Offset;
  Result := Format('GMT%s%.2d:%.2d', [ID[4], Hours, Minutes]);
end;

procedure InstallJavaTimeZones(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(Zone, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    B.Field('$id', 'Ljava/lang/String;', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('getID', '()Ljava/lang/String;');
    B.JavaClass.AddNative('getTimeZone', '(Ljava/lang/String;)Ljava/util/TimeZone;', True);
    B.JavaClass.AddNative('getDefault', '()Ljava/util/TimeZone;', True);
    B.JavaClass.AddNative('getAvailableIDs', '()[Ljava/lang/String;', True);
    for var D in ['()I', '()Z', '(IIIIII)I'] do
    begin
      var N := 'getRawOffset';
      if D = '()Z' then
        N := 'useDaylightTime'
      else if D = '(IIIIII)I' then
        N := 'getOffset';
      B.JavaClass.AddNative(N, D).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(FixedZone, Zone, JVM_ACC_FINAL or $20);
  try
    B.Field('$offset', 'I', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('getOffset', '(IIIIII)I');
    B.JavaClass.AddNative('getRawOffset', '()I');
    B.JavaClass.AddNative('useDaylightTime', '()Z');
    B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
    B.JavaClass.AddNative('hashCode', '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaTimeZone(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultID: string): TJVMValue;
var
  O: TJVMObject;
  ID: string;
  Offset: Integer;
begin
  Result := Default(TJVMValue);
  if Method.Name = 'getAvailableIDs' then
  begin
    var Ref := VM.NewArray('[Ljava/lang/String;', 2);
    O := VM.GetObject(Ref);
    O.Elements[0] := TJVMValue.Ref(VM.InternString('GMT'));
    O.Elements[1] := TJVMValue.Ref(VM.InternString('UTC'));
    Exit(TJVMValue.Ref(Ref));
  end;
  if (Method.Name = 'getDefault') or (Method.Name = 'getTimeZone') then
  begin
    ID := DefaultID;
    if Method.Name = 'getTimeZone' then
      ID := VM.GetObject(Args[0].AsRef).Text;
    ID := JavaZoneID(ID, Offset);
    var Ref := VM.NewObject(FixedZone);
    O := VM.GetObject(Ref);
    O.Fields[IDKey] := TJVMValue.Ref(VM.InternString(ID));
    O.Fields[OffsetKey] := TJVMValue.Int(Offset);
    Exit(TJVMValue.Ref(Ref));
  end;
  O := VM.GetObject(Args[0].AsRef);
  if Method.Name = '<init>' then
    Exit;
  if Method.Name = 'getID' then
    Exit(O.Fields[IDKey]);
  if Method.Name = 'useDaylightTime' then
    Exit(TJVMValue.Int(0));
  if Method.Name = 'getRawOffset' then
    Exit(O.Fields[OffsetKey]);
  if Method.Name = 'getOffset' then
  begin
    var Era := Args[1].AsInt;
    var Year := Int64(Args[2].AsInt);
    var Month := Args[3].AsInt;
    var Day := Args[4].AsInt;
    var Dow := Args[5].AsInt;
    var Millis := Args[6].AsInt;
    if Era = 0 then
      Year := 1 - Year;
    if (Era < 0) or (Era > 1) or (Month < 0) or (Month > 11) or (Day < 1) or (Day > 31) or
      (Dow < 1) or (Dow > 7) or (Millis < 0) or (Millis >= JavaDayMillis) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid time-zone date');
    if Day > JavaMonthDays(Year, Month) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid time-zone date');
    Exit(O.Fields[OffsetKey]);
  end;
  if Method.Name = 'equals' then
  begin
    if Args[1].AsRef = 0 then
      Exit(TJVMValue.Int(0));
    var Other := VM.GetObject(Args[1].AsRef);
    if Other.ClassName <> FixedZone then
      Exit(TJVMValue.Int(0));
    Exit(TJVMValue.Int(Ord((O.Fields[OffsetKey].AsInt = Other.Fields[OffsetKey].AsInt) and (VM.GetObject(O.Fields[IDKey].AsRef).Text = VM.GetObject(Other.Fields[IDKey].AsRef).Text))));
  end;
  if Method.Name = 'hashCode' then
  begin
    var H := O.Fields[OffsetKey].AsInt;
    for var C in VM.GetObject(O.Fields[IDKey].AsRef).Text do
      H := Integer(UInt32(H) * 31 + Ord(C));
    Exit(TJVMValue.Int(H));
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + Method.Name);
end;

end.

