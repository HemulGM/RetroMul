unit J2ME.Vodafone.Device;

interface

uses
  System.Generics.Collections, JVM.Types, JVM.ClassFile, JVM.Runtime,
  J2ME.Effects;

procedure InstallJ2MEVodafoneDevice(VM: TJVM);

function HandlesJ2MEVodafoneDevice(const ClassName: string): Boolean;

function InvokeJ2MEVodafoneDevice(VM: TJVM; Effects: TJ2MEDeviceEffects; Method: TJVMMethod; const Args: TArray<TJVMValue>; const Keys: TDictionary<Integer, Boolean>): TJVMValue;

implementation

uses
  Java.Classes, J2ME.Input;

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
    B.JavaClass.AddNative('getDeviceState', '(I)I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function HandlesJ2MEVodafoneDevice(const ClassName: string): Boolean;
begin
  Result := ClassName = DeviceName;
end;

function KeyState(const Keys: TDictionary<Integer, Boolean>): Integer;
const
  Navigation: array[12..18] of Integer = (-1, -3, -4, -2, -5, -6, -7);
begin
  Result := 0;
  for var I := Low(J2MEKeypadCodes) to High(J2MEKeypadCodes) do
    if Keys.ContainsKey(J2MEKeypadCodes[I]) then
      Result := Result or (1 shl I);
  for var I := Low(Navigation) to High(Navigation) do
    if Keys.ContainsKey(Navigation[I]) then
      Result := Result or (1 shl I);
end;

function InvokeJ2MEVodafoneDevice(VM: TJVM; Effects: TJ2MEDeviceEffects; Method: TJVMMethod; const Args: TArray<TJVMValue>; const Keys: TDictionary<Integer, Boolean>): TJVMValue;
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
  if Method.Name = 'getDeviceState' then
  begin
    case Args[1].AsInt of
      1:
        Exit(TJVMValue.Int(100)); // The virtual handset has no battery drain.
        2:
        Exit(TJVMValue.Int(0));   // Cellular signal is outside this device model.
        3:
        Exit(TJVMValue.Int(KeyState(Keys)));
    end;
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Vodafone device state');
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

