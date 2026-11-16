unit J2ME.Vodafone.Device;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Effects;

procedure InstallJ2MEVodafoneDevice(VM: TJVM);

function HandlesJ2MEVodafoneDevice(const ClassName: string): Boolean;

function InvokeJ2MEVodafoneDevice(VM: TJVM; Effects: TJ2MEDeviceEffects; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  Java.Classes;

const
  DeviceName = 'com/vodafone/v10/system/device/DeviceControl';
  DeviceDescriptor = 'Lcom/vodafone/v10/system/device/DeviceControl;';

procedure InstallJ2MEVodafoneDevice(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(DeviceName, 'java/lang/Object');
  try
    // VSCL device IDs. No native handles or singleton references outside the VM.
    var ID := 0;
    for var Name in ['BATTERY', 'FIELD_INTENSITY', 'KEY_STATE', 'VIBRATION', 'BACK_LIGHT', 'EIGHT_DIRECTIONS'] do
    begin
      Inc(ID);
      B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(ID);
    end;
    B.Field('$default', DeviceDescriptor, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.JavaClass.AddNative('<init>', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('getDefaultDeviceControl', '()' + DeviceDescriptor, True);
    B.JavaClass.AddNative('setDeviceActive', '(IZ)Z');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function HandlesJ2MEVodafoneDevice(const ClassName: string): Boolean;
begin
  Result := ClassName = DeviceName;
end;

function InvokeJ2MEVodafoneDevice(VM: TJVM; Effects: TJ2MEDeviceEffects; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Method.Name = '<init>' then
    Exit;
  if Method.Name = 'getDefaultDeviceControl' then
  begin
    for var F in Method.Owner.Fields do
      if F.Name = '$default' then
      begin
        if F.Value.AsRef = 0 then
          F.Value := TJVMValue.Ref(VM.NewObject(DeviceName));
        Exit(F.Value);
      end;
  end;
  if Method.Name = 'setDeviceActive' then
  begin
    var Active := Args[2].AsInt <> 0;
    case Args[1].AsInt of
      4:
        begin
          if Active then
            Effects.SetVibration(100, -1, VM.Host.MonotonicMillis)
          else
            Effects.SetVibration(0, 0, VM.Host.MonotonicMillis);
        end;
      5:
        Effects.SetBacklight(Ord(Active) * 100, True);
    else
      Exit(TJVMValue.Int(0)); // This host has no controllable device of that kind.
    end;
    Exit(TJVMValue.Int(1));
  end;
  raise EJVMUnsupported.Create(DeviceName + '.' + Method.Name);
end;

end.

