unit Java.Booleans;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaBooleans(VM: TJVM);

function InvokeJavaBoolean(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  Java.Classes;

const
  Name = 'java/lang/Boolean';
  ValueKey = Name + '.value:Z';

procedure InstallJavaBooleans(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(Name, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $20);
  try
    B.Field('value', 'Z', JVM_ACC_PRIVATE or JVM_ACC_FINAL);
    for var N in ['FALSE', 'TRUE'] do
      B.Field(N, 'Ljava/lang/Boolean;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.AddNative('<init>', '(Z)V');
    B.JavaClass.AddNative('booleanValue', '()Z');
    B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
    B.JavaClass.AddNative('hashCode', '()I');
    B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
    B.Start;
    for var Value := 0 to 1 do
    begin
      B.Ref($BB, B.ClassRef(Name));
      B.Emit([$59, Byte($03 + Value)]);
      B.Ref($B7, B.Member(Name, '<init>', '(Z)V'));
      var N := 'FALSE';
      if Value = 1 then
        N := 'TRUE';
      B.Ref($B3, B.Member(Name, N, 'Ljava/lang/Boolean;', 9));
    end;
    B.Emit([$B1]);
    B.Finish('<clinit>', '()V', JVM_ACC_STATIC, 3, 0);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaBoolean(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O: TJVMObject;
  Value: Integer;
begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  if Method.Name = '<init>' then
  begin
    O.Fields[ValueKey] := TJVMValue.Int(Args[1].AsInt and 1);
    Exit;
  end;
  Value := O.Fields[ValueKey].AsInt;
  if Method.Name = 'booleanValue' then
    Exit(TJVMValue.Int(Value));
  if Method.Name = 'hashCode' then
  begin
    if Value <> 0 then
      Exit(TJVMValue.Int(1231))
    else
      Exit(TJVMValue.Int(1237));
  end;
  if Method.Name = 'toString' then
  begin
    if Value <> 0 then
      Exit(TJVMValue.Ref(VM.InternString('true')))
    else
      Exit(TJVMValue.Ref(VM.InternString('false')));
  end;
  if Method.Name = 'equals' then
  begin
    if Args[1].AsRef = 0 then
      Exit(TJVMValue.Int(0));
    O := VM.GetObject(Args[1].AsRef);
    if O.ClassName <> Name then
      Exit(TJVMValue.Int(0));
    Exit(TJVMValue.Int(Ord(O.Fields[ValueKey].AsInt = Value)));
  end;
  raise EJVMUnsupported.Create(Name + '.' + Method.Name + Method.Descriptor);
end;

end.

