unit Java.Environment;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaEnvironment(VM: TJVM);

function InvokeJavaEnvironment(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils;

const
  RuntimeName = 'java/lang/Runtime';
  InstanceKey = '$instance';

procedure InstallJavaEnvironment(VM: TJVM);
begin
  var C := TJVMClass.Create;
  C.Name := RuntimeName;
  C.SuperName := 'java/lang/Object';
  var F := TJVMField.Create;
  F.Name := InstanceKey;
  F.Descriptor := 'Ljava/lang/Runtime;';
  F.Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC;
  F.Value := TJVMValue.Ref(0);
  C.Fields.Add(F);
  C.AddNative('<init>', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
  C.AddNative('getRuntime', '()Ljava/lang/Runtime;', True);
  C.AddNative('freeMemory', '()J');
  C.AddNative('totalMemory', '()J');
  C.AddNative('gc', '()V');
  C.AddNative('exit', '(I)V');
  VM.DefineClass(C);
  VM.LoadClass('java/lang/System').AddNative('exit', '(I)V', True);
end;

function InvokeJavaEnvironment(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Method.Name = 'getRuntime' then
  begin
    var F: TJVMField := nil;
    for var Field in VM.LoadClass(RuntimeName).Fields do
      if Field.Name = InstanceKey then
      begin
        F := Field;
        Break;
      end;
    if F = nil then
      raise EJVMError.Create('Runtime singleton field missing');
    if F.Value.AsRef = 0 then
      F.Value := TJVMValue.Ref(VM.NewObject(RuntimeName));
    Exit(F.Value);
  end;
  if Method.Name = '<init>' then
    Exit;
  VM.GetObject(Args[0].AsRef);
  if Method.Name = 'gc' then
  begin
    VM.CollectGarbage;
    Exit;
  end;
  if Method.Name = 'exit' then
  begin
    VM.ExitApplication(Args[1].AsInt);
    Exit;
  end;
  var Memory := VM.HeapMemory;
  if Method.Name = 'totalMemory' then
    Exit(TJVMValue.Long(Memory.CapacityBytes));
  if Method.Name = 'freeMemory' then
    Exit(TJVMValue.Long(Memory.CapacityBytes - Memory.UsedBytes));
  raise EJVMUnsupported.Create(RuntimeName + '.' + Method.Name);
end;

end.

