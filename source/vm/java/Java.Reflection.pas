unit Java.Reflection;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaClassMethods(C: TJVMClass);

function TryInvokeJavaClass(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Value: TJVMValue): Boolean;

implementation

uses
  System.SysUtils;

procedure InstallJavaClassMethods(C: TJVMClass);
begin
  C.AddNative('forName', '(Ljava/lang/String;)Ljava/lang/Class;', True);
  C.AddNative('newInstance', '()Ljava/lang/Object;');
  C.AddNative('toString', '()Ljava/lang/String;');
end;

function TryInvokeJavaClass(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Value: TJVMValue): Boolean;
var
  Name, InternalName, Component: string;
  C: TJVMClass;
  ConstructorMethod: TJVMMethod;
  Dummy: TJVMValue;
begin
  Value := Default(TJVMValue);
  Result := True;
  if Method.Name = 'forName' then
  begin
    Name := VM.GetObject(Args[0].AsRef).Text;
    if (Name = '') or Name.Contains('/') then
      VM.RaiseJava('java/lang/ClassNotFoundException', Name);
    InternalName := Name.Replace('.', '/');
    try
      JVMClassName(InternalName);
    except
      on E: EJVMFormatError do
        VM.RaiseJava('java/lang/ClassNotFoundException', Name);
    end;
    Component := InternalName;
    if InternalName.StartsWith('[') then
    begin
      while Component.StartsWith('[') do
        Delete(Component, 1, 1);
      if Component.StartsWith('L') then
        Component := Copy(Component, 2, Length(Component) - 2);
    end;
    try
      Value := TJVMValue.Ref(VM.ClassObject(InternalName));
    except
      on E: EJVMClassMissing do
      begin
      // A missing requested class is CNFE. Missing dependencies retain their
      // linkage error, as do wrong-name, malformed and erroneous class files.
        if E.MissingName = Component then
          VM.RaiseJava('java/lang/ClassNotFoundException', Name);
        raise;
      end;
    end;
    if not InternalName.StartsWith('[') then
      if not VM.InitializeNativeClass(VM.LoadClass(InternalName)) then
        Exit;
    Exit;
  end;
  if Method.Name = 'newInstance' then
  begin
    if VM.TakeGuestResult(Dummy) then
    begin
      Value := VM.NativeContinuation;
      VM.SetNativeContinuation(Default(TJVMValue));
      Exit;
    end;
    Name := VM.GetObject(Args[0].AsRef).Text;
    if Name = 'java/lang/Class' then
      VM.RaiseJava('java/lang/IllegalAccessException', Name);
    if Name.StartsWith('[') then
      VM.RaiseJava('java/lang/InstantiationException', Name);
    C := VM.LoadClass(Name);
    if (C.Access and (JVM_ACC_ABSTRACT or $0200)) <> 0 then
      VM.RaiseJava('java/lang/InstantiationException', Name);
    ConstructorMethod := C.FindMethod('<init>', '()V');
    if ConstructorMethod = nil then
      VM.RaiseJava('java/lang/InstantiationException', Name);
    try
      VM.CheckNativeAccess(C, ConstructorMethod.Access);
    except
      on E: EJVMLinkError do
      begin
        if E.JavaClass = 'java/lang/IllegalAccessError' then
          VM.RaiseJava('java/lang/IllegalAccessException', E.Message);
        raise;
      end;
    end;
    if not VM.InitializeNativeClass(C) then
      Exit;
    Value := TJVMValue.Ref(VM.NewObject(Name));
    VM.SetNativeContinuation(Value);
    VM.InvokeGuestResult(ConstructorMethod, [Value]);
    Exit;
  end;
  if Method.Name = 'toString' then
  begin
    Name := VM.GetObject(Args[0].AsRef).Text;
    if Name.StartsWith('[') then
      Component := 'class '
    else if (VM.LoadClass(Name).Access and $0200) <> 0 then
      Component := 'interface '
    else
      Component := 'class ';
    Value := TJVMValue.Ref(VM.NewString(Component + Name.Replace('/', '.')));
    Exit;
  end;
  Result := False;
end;

end.

