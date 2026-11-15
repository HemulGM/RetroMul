unit J2ME.Nokia.UI;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Effects;

type
  TJ2MENokiaUI = class
  private
    FVM: TJVM;
    FEffects: TJ2MEDeviceEffects; // borrowed from the host
  public
    constructor Create(VM: TJVM; Effects: TJ2MEDeviceEffects);
    procedure Install;
    function Handles(const ClassName: string): Boolean;
    function Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
    function Poll(Now: Int64): Boolean;
    procedure ApplyBacklight(var Pixels: TArray<UInt32>);
  end;

implementation

uses
  System.Math, Java.Classes;

const
  FullCanvasName = 'com/nokia/mid/ui/FullCanvas';
  DeviceName = 'com/nokia/mid/ui/DeviceControl';
  CanvasName = 'javax/microedition/lcdui/Canvas';

constructor TJ2MENokiaUI.Create(VM: TJVM; Effects: TJ2MEDeviceEffects);
begin
  inherited Create;
  FVM := VM;
  FEffects := Effects;
end;

procedure TJ2MENokiaUI.Install;
begin
  var B := TJavaClassBuilder.Create(FullCanvasName, CanvasName, JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    for var Name in ['KEY_UP_ARROW', 'KEY_DOWN_ARROW', 'KEY_LEFT_ARROW', 'KEY_RIGHT_ARROW', 'KEY_SOFTKEY3', 'KEY_SOFTKEY1', 'KEY_SOFTKEY2', 'KEY_SEND', 'KEY_END'] do
    begin
      var Code := -1;
      if Name = 'KEY_DOWN_ARROW' then
        Code := -2
      else if Name = 'KEY_LEFT_ARROW' then
        Code := -3
      else if Name = 'KEY_RIGHT_ARROW' then
        Code := -4
      else if Name = 'KEY_SOFTKEY3' then
        Code := -5
      else if Name = 'KEY_SOFTKEY1' then
        Code := -6
      else if Name = 'KEY_SOFTKEY2' then
        Code := -7
      else if Name = 'KEY_SEND' then
        Code := -10
      else if Name = 'KEY_END' then
        Code := -11;
      B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Code);
    end;
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(CanvasName, '<init>', '()V'));
    B.Emit([$2A, $04]);
    B.Ref($B7, B.Member(CanvasName, 'setFullScreenMode', '(Z)V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PROTECTED, 2, 1);
    // FullCanvas retains its fullscreen contract on MIDP 2 hosts too.
    B.Start;
    B.Emit([$2A, $04]);
    B.Ref($B7, B.Member(CanvasName, 'setFullScreenMode', '(Z)V'));
    B.Emit([$B1]);
    B.Finish('setFullScreenMode', '(Z)V', JVM_ACC_PUBLIC, 2, 2);
    B.JavaClass.AddNative('addCommand', '(Ljavax/microedition/lcdui/Command;)V');
    B.JavaClass.AddNative('setCommandListener', '(Ljavax/microedition/lcdui/CommandListener;)V');
    FVM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  var C := TJVMClass.Create;
  C.Name := DeviceName;
  C.SuperName := 'java/lang/Object';
  C.AddNative('<init>', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
  C.AddNative('setLights', '(II)V', True);
  C.AddNative('flashLights', '(J)V', True);
  C.AddNative('startVibra', '(IJ)V', True);
  C.AddNative('stopVibra', '()V', True);
  FVM.DefineClass(C);
end;

function TJ2MENokiaUI.Handles(const ClassName: string): Boolean;
begin
  Result := (ClassName = DeviceName) or (ClassName = FullCanvasName);
end;

function TJ2MENokiaUI.Invoke(Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Method.Owner.Name = FullCanvasName then
    FVM.RaiseJava('java/lang/IllegalStateException', 'FullCanvas does not support commands');
  if Method.Name = '<init>' then
    Exit;
  if Method.Name = 'setLights' then
  begin
    var Number := Args[0].AsInt;
    var Level := Args[1].AsInt;
    if (Number <> 0) or (Level < 0) or (Level > 100) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    FEffects.SetBacklight(Level);
    Exit;
  end;
  if Method.Name = 'flashLights' then
  begin
    var Duration := Args[0].AsLong;
    if Duration < 0 then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    FEffects.FlashBacklight(Min(Duration, Int64(30000)), FVM.Host.MonotonicMillis);
    Exit;
  end;
  if Method.Name = 'startVibra' then
  begin
    if (Args[0].AsInt < 0) or (Args[0].AsInt > 100) or (Args[1].AsLong < 0) then
      FVM.RaiseJava('java/lang/IllegalArgumentException');
    FEffects.SetVibration(Args[0].AsInt, Args[1].AsLong, FVM.Host.MonotonicMillis);
    Exit;
  end;
  if Method.Name = 'stopVibra' then
  begin
    FEffects.SetVibration(0, 0, FVM.Host.MonotonicMillis);
    Exit;
  end;
  raise EJVMUnsupported.Create(DeviceName + '.' + Method.Name);
end;

function TJ2MENokiaUI.Poll(Now: Int64): Boolean;
begin
  Result := FEffects.Poll(Now);
end;

procedure TJ2MENokiaUI.ApplyBacklight(var Pixels: TArray<UInt32>);
begin
  FEffects.ApplyBacklight(Pixels);
end;

end.

