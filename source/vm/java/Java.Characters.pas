unit Java.Characters;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaCharacters(VM: TJVM);

function InvokeJavaCharacter(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  Java.Classes, Java.Unicode;

const
  Name = 'java/lang/Character';
  ValueKey = Name + '.value:C';

procedure InstallJavaCharacters(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure ConstantField(const FieldName, Desc: string; Value: Integer);
  begin
    B.Field(FieldName, Desc, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(Name, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $20);
  try
    B.Field('value', 'C', JVM_ACC_PRIVATE or JVM_ACC_FINAL);
    ConstantField('MIN_VALUE', 'C', 0);
    ConstantField('MAX_VALUE', 'C', $FFFF);
    ConstantField('MIN_RADIX', 'I', 2);
    ConstantField('MAX_RADIX', 'I', 36);
    B.JavaClass.AddNative('<init>', '(C)V');
    B.JavaClass.AddNative('charValue', '()C');
    B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
    B.JavaClass.AddNative('hashCode', '()I');
    B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
    for var N in ['isLowerCase', 'isUpperCase', 'isDigit'] do
      B.JavaClass.AddNative(N, '(C)Z', True);
    for var N in ['toLowerCase', 'toUpperCase'] do
      B.JavaClass.AddNative(N, '(C)C', True);
    B.JavaClass.AddNative('digit', '(CI)I', True);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaCharacter(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  C: Char;
  O: TJVMObject;
  Info: TJavaCharInfo;
begin
  Result := Default(TJVMValue);
  if (Method.Access and JVM_ACC_STATIC) <> 0 then
  begin
    C := Char(Args[0].AsInt and $FFFF);
    if Method.Name = 'digit' then
      Exit(TJVMValue.Int(JavaCharDigit(C, Args[1].AsInt)));
    Info := JavaCharInfo(C);
    if Method.Name = 'toLowerCase' then
      Exit(TJVMValue.Int(Ord(Info.Lower)));
    if Method.Name = 'toUpperCase' then
      Exit(TJVMValue.Int(Ord(Info.Upper)));
    if Method.Name = 'isLowerCase' then
      Exit(TJVMValue.Int(Ord((Info.Flags and 1) <> 0)));
    if Method.Name = 'isUpperCase' then
      Exit(TJVMValue.Int(Ord((Info.Flags and 2) <> 0)));
    if Method.Name = 'isDigit' then
      Exit(TJVMValue.Int(Ord((Info.Flags and 4) <> 0)));
  end
  else
  begin
    O := VM.GetObject(Args[0].AsRef);
    if Method.Name = '<init>' then
    begin
      O.Fields[ValueKey] := TJVMValue.Int(Args[1].AsInt and $FFFF);
      Exit;
    end;
    C := Char(O.Fields[ValueKey].AsInt and $FFFF);
    if (Method.Name = 'charValue') or (Method.Name = 'hashCode') then
      Exit(TJVMValue.Int(Ord(C)));
    if Method.Name = 'toString' then
      Exit(TJVMValue.Ref(VM.NewString(string(C))));
    if Method.Name = 'equals' then
    begin
      if Args[1].AsRef = 0 then
        Exit(TJVMValue.Int(0));
      O := VM.GetObject(Args[1].AsRef);
      if O.ClassName <> Name then
        Exit(TJVMValue.Int(0));
      Exit(TJVMValue.Int(Ord(O.Fields[ValueKey].AsInt = Ord(C))));
    end;
  end;
  raise EJVMUnsupported.Create(Name + '.' + Method.Name + Method.Descriptor);
end;

end.

