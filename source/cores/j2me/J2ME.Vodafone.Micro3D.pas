unit J2ME.Vodafone.Micro3D;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Suite;

const
  Vodafone3DPrefix = 'com/vodafone/v10/graphics/j3d/';
  Vodafone3DDraw = 'drawFigure';

procedure InstallJ2MEVodafoneMicro3D(VM: TJVM);

function HandlesJ2MEVodafoneMicro3D(const ClassName, MethodName: string): Boolean;

function InvokeJ2MEVodafoneMicro3D(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height, RootMIDlet: Integer): TJVMValue;

implementation

uses
  System.SysUtils, Java.Classes, J2ME.Micro3D, J2ME.Micro3D.Texture,
  J2ME.Micro3D.Figure, J2ME.Micro3D.Action, J2ME.Micro3D.Graphics;

const
  MascotPrefix = 'com/mascotcapsule/micro3d/v3/';
  GraphicsClassName = 'javax/microedition/lcdui/Graphics';
  GraphicsType = 'L' + GraphicsClassName + ';';
  DrawInterface = Vodafone3DPrefix + 'Graphics3D';
  VectorType = 'L' + Vodafone3DPrefix + 'Vector3D;';
  AffineType = 'L' + Vodafone3DPrefix + 'AffineTrans;';
  LightType = 'L' + Vodafone3DPrefix + 'Light;';
  TextureType = 'L' + Vodafone3DPrefix + 'Texture;';
  FigureType = 'L' + Vodafone3DPrefix + 'Figure;';
  ActionType = 'L' + Vodafone3DPrefix + 'ActionTable;';
  LayoutType = 'L' + Vodafone3DPrefix + 'FigureLayout;';
  EffectType = 'L' + Vodafone3DPrefix + 'Effect3D;';
  DrawDescriptor = '(' + FigureType + 'II' + LayoutType + EffectType + ')V';
  RendererKey = '$vodafoneMicro3D';

procedure InstallJ2MEVodafoneMicro3D(VM: TJVM);
var
  Builder: TJavaClassBuilder;

  procedure Finish;
  begin
    VM.DefineClass(Builder.Detach);
    FreeAndNil(Builder);
  end;

  procedure Start(const SimpleName: string);
  begin
    Builder := TJavaClassBuilder.Create(Vodafone3DPrefix + SimpleName, MascotPrefix + SimpleName);
  end;

  procedure Native(const Name, Descriptor: string; StaticMethod: Boolean = False);
  begin
    Builder.JavaClass.AddNative(Name, Descriptor, StaticMethod);
  end;

begin
  Builder := nil;
  try
    // VSCL and Mascot v3 use the same model data and fixed-point operations.
    // Keep the VSCL parameter and result descriptors visible to guest code.
    Start('Vector3D');
    Native('<init>', '()V');
    Native('<init>', '(III)V');
    Native('innerProduct', '(' + VectorType + ')I');
    Native('outerProduct', '(' + VectorType + ')V');
    Native('innerProduct', '(' + VectorType + VectorType + ')I', True);
    Native('outerProduct', '(' + VectorType + VectorType + ')' + VectorType, True);
    Finish;

    Start('AffineTrans');
    Native('<init>', '()V');
    Native('<init>', '([[I)V');
    Native('transPoint', '(' + VectorType + ')' + VectorType);
    Native('multiply', '(' + AffineType + ')V');
    Native('multiply', '(' + AffineType + AffineType + ')V');
    Native('rotationV', '(' + VectorType + 'I)V');
    Native('setViewTrans', '(' + VectorType + VectorType + VectorType + ')V');
    Finish;

    Start('FigureLayout');
    Native('<init>', '()V');
    Native('<init>', '(' + AffineType + 'IIII)V');
    Native('setAffineTrans', '(' + AffineType + ')V');
    Native('getAffineTrans', '()' + AffineType);
    Finish;

    Start('Light');
    Native('<init>', '()V');
    Native('<init>', '(' + VectorType + 'II)V');
    Native('setDirection', '(' + VectorType + ')V');
    Native('getDirection', '()' + VectorType);
    Finish;

    Start('Effect3D');
    Native('<init>', '()V');
    Native('<init>', '(' + LightType + 'IZ' + TextureType + ')V');
    Native('getLight', '()' + LightType);
    Native('setLight', '(' + LightType + ')V');
    Native('getSphereMap', '()' + TextureType);
    Native('setSphereMap', '(' + TextureType + ')V');
    Finish;

    for var Name in ['Figure', 'ActionTable'] do
    begin
      Start(Name);
      Native('<init>', '([B)V');
      Native('<init>', '(Ljava/lang/String;)V');
      if Name = 'Figure' then
      begin
        Native('setPosture', '(' + ActionType + 'II)V');
        Native('setTexture', '(' + TextureType + ')V');
      end;
      Finish;
    end;

    Start('Texture');
    Native('<init>', '([BZ)V');
    Native('<init>', '(Ljava/lang/String;Z)V');
    Finish;

    Start('Util3D');
    Finish;

    Builder := TJavaClassBuilder.Create(DrawInterface, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
    Builder.JavaClass.AddNative(Vodafone3DDraw, DrawDescriptor).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Finish;

    var Graphics := VM.LoadClass(GraphicsClassName);
    Graphics.Interfaces := Graphics.Interfaces + [DrawInterface];
    Graphics.AddNative(Vodafone3DDraw, DrawDescriptor);
  finally
    Builder.Free;
  end;
end;

function HandlesJ2MEVodafoneMicro3D(const ClassName, MethodName: string): Boolean;
begin
  Result := ClassName.StartsWith(Vodafone3DPrefix) or
    ((ClassName = GraphicsClassName) and (MethodName = Vodafone3DDraw));
end;

function MascotDescriptor(const Descriptor: string): string;
begin
  Result := StringReplace(Descriptor, Vodafone3DPrefix, MascotPrefix, [rfReplaceAll]);
end;

procedure DrawFigure(VM: TJVM; Suite: TJ2MESuite; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height, RootMIDlet: Integer);
begin
  var F := VM.LoadClass(MascotPrefix + 'Figure');
  var Texture := InvokeJ2MEMicro3DFigure(VM, Suite,
    F.FindMethod('getTexture', '()L' + MascotPrefix + 'Texture;'), [Args[1]]);
  if Texture.AsRef = 0 then
    VM.RaiseJava('java/lang/NullPointerException', 'No texture set for Vodafone figure');

  // Canvas.paint gets a fresh Graphics object. Keep the reusable depth and
  // triangle buffers on the MIDlet so allocations do not grow with frame rate.
  var Owner := VM.GetObject(Args[0].AsRef);
  if RootMIDlet <> 0 then
    Owner := VM.GetObject(RootMIDlet);
  var Renderer: TJVMValue;
  if not Owner.Fields.TryGetValue(RendererKey, Renderer) then
  begin
    Renderer := TJVMValue.Ref(VM.NewObject(Micro3DGraphicsName));
    Owner.Fields.Add(RendererKey, Renderer);
  end;
  var Core := VM.LoadClass(Micro3DGraphicsName);
  var Binding: TArray<TJVMValue> := [Renderer, Args[0]];
  InvokeJ2MEMicro3DGraphics(VM, Core.FindMethod('bind', '(' + GraphicsType + ')V'), Binding, Pixels, Width, Height);
  try
    InvokeJ2MEMicro3DGraphics(VM, Core.FindMethod('drawFigure', MascotDescriptor(DrawDescriptor)),
      [Renderer, Args[1], Args[2], Args[3], Args[4], Args[5]], Pixels, Width, Height);
  finally
    InvokeJ2MEMicro3DGraphics(VM, Core.FindMethod('release', '(' + GraphicsType + ')V'), Binding, Pixels, Width, Height);
  end;
end;

function InvokeJ2MEVodafoneMicro3D(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height, RootMIDlet: Integer): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Method.Owner.Name = GraphicsClassName then
  begin
    DrawFigure(VM, Suite, Args, Pixels, Width, Height, RootMIDlet);
    Exit;
  end;

  var Owner := Method.Owner.SuperName;
  if (Owner = MascotPrefix + 'AffineTrans') and (Method.Name = 'setViewTrans') then
  begin
    SetMicro3DViewDirection(VM, Args);
    Exit;
  end;
  var ClassInfo := VM.LoadClass(Owner);
  var Desc := MascotDescriptor(Method.Descriptor);
  var Native := ClassInfo.FindMethod(Method.Name, Desc);
  if Native = nil then
    raise EJVMUnsupported.Create(Owner + '.' + Method.Name + Desc);
  if J2MEMicro3DHandles(Owner) then
  begin
    Result := InvokeJ2MEMicro3D(VM, Native, Args);
    if (Owner = MascotPrefix + 'FigureLayout') and (Method.Name = '<init>') and (Desc = '()V') then
      InvokeJ2MEMicro3D(VM, ClassInfo.FindMethod('setCenter', '(II)V'),
        [Args[0], TJVMValue.Int(Width div 2), TJVMValue.Int(Height div 2)]);
  end
  else if J2MEMicro3DFigureHandles(Owner) then
    Result := InvokeJ2MEMicro3DFigure(VM, Suite, Native, Args)
  else if Owner = Micro3DActionName then
    Result := InvokeJ2MEMicro3DAction(VM, Suite, Native, Args)
  else
    Result := InvokeJ2MEMicro3DTexture(VM, Suite, Native, Args);

  var ReturnType := Copy(Method.Descriptor, Pos(')', Method.Descriptor) + 1, MaxInt);
  if ReturnType.StartsWith('L' + Vodafone3DPrefix) and (Result.AsRef <> 0) then
  begin
    var ClassName := Copy(ReturnType, 2, Length(ReturnType) - 2);
    var Source := VM.GetObject(Result.AsRef);
    if VM.IsAssignable(Source.ClassName, ClassName) then
      Exit;
    Result := TJVMValue.Ref(VM.NewObject(ClassName));
    var Adapted := VM.GetObject(Result.AsRef);
    for var Field in Source.Fields do
      Adapted.Fields.AddOrSetValue(Field.Key, Field.Value);
    // The shared constructors create default affine and light vectors. Preserve
    // object identity when a VSCL application obtains and edits either default.
    if Method.Name = 'getAffineTrans' then
      VM.GetObject(Args[0].AsRef).Fields[Owner + '.$transform:' + Copy(Desc, 3, MaxInt)] := Result
    else if Method.Name = 'getDirection' then
      VM.GetObject(Args[0].AsRef).Fields[Owner + '.$direction:' + Copy(Desc, 3, MaxInt)] := Result;
  end;
end;

end.

