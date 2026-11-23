unit J2ME.M3G;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Math;

procedure InstallJ2MEM3G(VM: TJVM);

function J2MEM3GHandles(const Name: string): Boolean;

function InvokeJ2MEM3G(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GGetMatrix(VM: TJVM; Ref: Integer): TM3GMatrix;

procedure M3GPutMatrix(VM: TJVM; Ref: Integer; const Matrix: TM3GMatrix);

function M3GComposite(VM: TJVM; Ref: Integer): TM3GMatrix;

function M3GDuplicateClass(VM: TJVM; O: TJVMObject): string;

function M3GObjectReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, Java.Classes,
  J2ME.M3G.Geometry, J2ME.M3G.Scene, J2ME.M3G.Mesh, J2ME.M3G.Graphics,
  J2ME.M3G.Texture, J2ME.M3G.Loader, J2ME.M3G.Environment, J2ME.M3G.Sprite,
  J2ME.M3G.Keyframe, J2ME.M3G.Animation, J2ME.M3G.Skin, J2ME.M3G.Morph,
  J2ME.M3G.Picking;

const
  Base = 'javax/microedition/m3g/';
  ObjectName = Base + 'Object3D';
  TransformName = Base + 'Transform';
  VertexName = Base + 'VertexArray';
  TransformableName = Base + 'Transformable';
  TransformD = 'Ljavax/microedition/m3g/Transform;';
  P = '$m3g.';
  Axes = 'xyz';

function J2MEM3GHandles(const Name: string): Boolean;
begin
  Result := (Name = ObjectName) or (Name = TransformName) or (Name = VertexName) or
    (Name = TransformableName) or M3GGeometryHandles(Name) or M3GSceneHandles(Name) or M3GMeshHandles(Name) or M3GTextureHandles(Name) or M3GEnvironmentHandles(Name) or M3GSpriteHandles(Name) or M3GKeyframeHandles(Name) or M3GAnimationHandles(Name) or M3GSkinHandles(Name) or M3GMorphHandles(Name) or M3GPickingHandles(Name);
end;

function M3GObjectReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := M3GGeometryReferences(VM, O) + M3GSceneReferences(VM, O) + M3GMeshReferences(VM, O) + M3GWorldReferences(VM, O) +
    M3GTextureReferences(VM, O) + M3GEnvironmentReferences(VM, O) + M3GSpriteReferences(VM, O) + M3GAnimationReferences(VM, O) + M3GSkinReferences(VM, O) + M3GMorphReferences(VM, O);
end;

function M3GDuplicateClass(VM: TJVM; O: TJVMObject): string;
begin
  var C := VM.LoadClass(O.ClassName);
  while not J2MEM3GHandles(C.Name) do
    C := VM.LoadClass(C.SuperName);
  Result := C.Name;
end;

function IntField(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsInt;
end;

function RefField(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsRef;
end;

procedure PutInt(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Name, TJVMValue.Int(Value));
end;

procedure PutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Name, TJVMValue.Ref(Value));
end;

function FloatArray(VM: TJVM; Ref, Minimum: Integer): TJVMObject;
begin
  Result := VM.GetObject(Ref);
  if (Result.ClassName <> '[F') or (Length(Result.Elements) < Minimum) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G float array length/type');
end;

function M3GGetMatrix(VM: TJVM; Ref: Integer): TM3GMatrix;
begin
  var O := VM.GetObject(Ref);
  var Data := VM.GetObject(RefField(O, 'matrix'));
  for var I := 0 to 15 do
    Result[I] := Data.Elements[I].AsFloat;
end;

procedure M3GPutMatrix(VM: TJVM; Ref: Integer; const Matrix: TM3GMatrix);
begin
  var O := VM.GetObject(Ref);
  var DataRef := RefField(O, 'matrix');
  if DataRef = 0 then
  begin
    DataRef := VM.NewArray('[F', 16);
    PutRef(O, 'matrix', DataRef);
  end;
  var Data := VM.GetObject(DataRef);
  for var I := 0 to 15 do
    Data.Elements[I] := TJVMValue.Float(Matrix[I]);
end;

procedure InstallJ2MEM3G(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  // Package version remains unadvertised while the complete API is unavailable.
  B := TJavaClassBuilder.Create(TransformName, 'java/lang/Object');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('<init>', '(' + TransformD + ')V');
    B.JavaClass.AddNative('set', '(' + TransformD + ')V');
    B.JavaClass.AddNative('set', '([F)V');
    B.JavaClass.AddNative('get', '([F)V');
    B.JavaClass.AddNative('postMultiply', '(' + TransformD + ')V');
    for var N in ['setIdentity', 'invert', 'transpose'] do
      B.JavaClass.AddNative(N, '()V');
    for var N in ['postScale', 'postTranslate'] do
      B.JavaClass.AddNative(N, '(FFF)V');
    for var N in ['postRotate', 'postRotateQuat'] do
      B.JavaClass.AddNative(N, '(FFFF)V');
    B.JavaClass.AddNative('transform', '([F)V');
    B.JavaClass.AddNative('transform', '(Ljavax/microedition/m3g/VertexArray;[FZ)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(ObjectName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    // Animation/referenced scene classes will extend this common object layer.
    B.JavaClass.AddNative('getUserID', '()I').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('setUserID', '(I)V').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('getUserObject', '()Ljava/lang/Object;');
    B.JavaClass.AddNative('setUserObject', '(Ljava/lang/Object;)V');
    B.JavaClass.AddNative('getReferences', '([Ljavax/microedition/m3g/Object3D;)I');
    B.JavaClass.AddNative('find', '(I)Ljavax/microedition/m3g/Object3D;');
    B.JavaClass.AddNative('duplicate', '()Ljavax/microedition/m3g/Object3D;').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('animate', '(I)I');
    B.JavaClass.AddNative('addAnimationTrack', '(Ljavax/microedition/m3g/AnimationTrack;)V');
    B.JavaClass.AddNative('removeAnimationTrack', '(Ljavax/microedition/m3g/AnimationTrack;)V');
    B.JavaClass.AddNative('getAnimationTrack', '(I)Ljavax/microedition/m3g/AnimationTrack;');
    B.JavaClass.AddNative('getAnimationTrackCount', '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(VertexName, ObjectName);
  try
    B.JavaClass.AddNative('<init>', '(III)V');
    for var N in ['getVertexCount', 'getComponentCount', 'getComponentType'] do
      B.JavaClass.AddNative(N, '()I');
    for var N in ['set', 'get'] do
    begin
      B.JavaClass.AddNative(N, '(II[B)V');
      B.JavaClass.AddNative(N, '(II[S)V');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  InstallM3GGeometry(VM);
  B := TJavaClassBuilder.Create(TransformableName, ObjectName, JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    for var N in ['getCompositeTransform', 'getTransform', 'setTransform'] do
      B.JavaClass.AddNative(N, '(' + TransformD + ')V');
    for var N in ['getOrientation', 'getScale', 'getTranslation'] do
      B.JavaClass.AddNative(N, '([F)V');
    for var N in ['setScale', 'scale', 'setTranslation', 'translate'] do
      B.JavaClass.AddNative(N, '(FFF)V');
    for var N in ['setOrientation', 'preRotate', 'postRotate'] do
      B.JavaClass.AddNative(N, '(FFFF)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  InstallM3GScene(VM);
  InstallM3GMesh(VM);
  InstallM3GTexture(VM);
  InstallM3GEnvironment(VM);
  InstallM3GSprite(VM);
  InstallM3GKeyframe(VM);
  InstallM3GAnimation(VM);
  InstallM3GSkin(VM);
  InstallM3GMorph(VM);
  InstallM3GPicking(VM);
  InstallM3GGraphics(VM);
  InstallM3GLoader(VM);
end;

function Component(O: TJVMObject; const Name: string; Fallback: Single = 0): Single;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsFloat;
end;

function ComponentMatrix(O: TJVMObject; const Name: string): TM3GMatrix;
begin
  Result := M3GIdentity;
  for var I := 0 to 15 do
    Result[I] := Component(O, Name + IntToStr(I), Result[I]);
end;

procedure PutComponentMatrix(O: TJVMObject; const Name: string; const M: TM3GMatrix);
begin
  for var I := 0 to 15 do
    O.Fields.AddOrSetValue(P + Name + IntToStr(I), TJVMValue.Float(M[I]));
end;

function M3GComposite(VM: TJVM; Ref: Integer): TM3GMatrix;
begin
  var O := VM.GetObject(Ref);
  Result := M3GMultiply(M3GScale(Component(O, 'sx', 1), Component(O, 'sy', 1), Component(O, 'sz', 1)), ComponentMatrix(O, 'general'));
  Result := M3GMultiply(ComponentMatrix(O, 'orientation'), Result);
  Result := M3GMultiply(M3GTranslation(Component(O, 'tx'), Component(O, 'ty'), Component(O, 'tz')), Result);
end;

function InvokeTransformable(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if (N = 'setTransform') or (N = 'getTransform') or (N = 'getCompositeTransform') then
  begin
    var M := ComponentMatrix(O, 'general');
    if N = 'setTransform' then
    begin
      M := M3GIdentity;
      if Args[1].AsRef <> 0 then
        M := M3GGetMatrix(VM, Args[1].AsRef);
      if VM.IsAssignable(O.ClassName, Base + 'Node') and
        ((M[12] <> 0) or (M[13] <> 0) or (M[14] <> 0) or (M[15] <> 1)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Projective M3G node transform');
      PutComponentMatrix(O, 'general', M);
    end
    else
    begin
      if N = 'getCompositeTransform' then
        M := M3GComposite(VM, Args[0].AsRef);
      M3GPutMatrix(VM, Args[1].AsRef, M);
    end;
    Exit;
  end;
  if (N = 'setOrientation') or (N = 'preRotate') or (N = 'postRotate') then
  begin
    var R: TM3GMatrix;
    if not M3GRotation(Args[1].AsFloat, Args[2].AsFloat, Args[3].AsFloat, Args[4].AsFloat, R) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Zero M3G rotation axis');
    if N = 'preRotate' then
      R := M3GMultiply(R, ComponentMatrix(O, 'orientation'))
    else if N = 'postRotate' then
      R := M3GMultiply(ComponentMatrix(O, 'orientation'), R);
    PutComponentMatrix(O, 'orientation', R);
    Exit;
  end;
  if N = 'getOrientation' then
  begin
    var Output := FloatArray(VM, Args[1].AsRef, 4);
    var R := ComponentMatrix(O, 'orientation');
    // Stable matrix-to-quaternion conversion, including rotations near 180 deg.
    var Q: array[0..3] of Double;
    var Trace: Double := Double(R[0]) + R[5] + R[10];
    if Trace > 0 then
    begin
      var S := Sqrt(Trace + 1) * 2;
      Q[3] := S / 4;
      Q[0] := (Double(R[9]) - R[6]) / S;
      Q[1] := (Double(R[2]) - R[8]) / S;
      Q[2] := (Double(R[4]) - R[1]) / S;
    end
    else
    begin
      var I := 0;
      if R[5] > R[0] then
        I := 1;
      if R[10] > R[I * 5] then
        I := 2;
      var J := (I + 1) mod 3;
      var K := (I + 2) mod 3;
      var S := Sqrt(Max(0.0, 1.0 + Double(R[I * 5]) - R[J * 5] - R[K * 5])) * 2;
      Q[I] := S / 4;
      Q[J] := (Double(R[I * 4 + J]) + R[J * 4 + I]) / S;
      Q[K] := (Double(R[I * 4 + K]) + R[K * 4 + I]) / S;
      Q[3] := (Double(R[K * 4 + J]) - R[J * 4 + K]) / S;
    end;
    var Length := Sqrt(Q[0] * Q[0] + Q[1] * Q[1] + Q[2] * Q[2]);
    var Angle: Double := 0;
    if Length > 0 then
      Angle := ArcTan2(Length, Q[3]) * (360 / Pi);
    Output.Elements[0] := TJVMValue.Float(Angle);
    for var I := 0 to 2 do
    begin
      var Axis: Double := 0;
      if Length > 0 then
        Axis := Q[I] / Length;
      Output.Elements[I + 1] := TJVMValue.Float(Axis);
    end;
    Exit;
  end;
  var Prefix := 't';
  if (N = 'setScale') or (N = 'scale') or (N = 'getScale') then
    Prefix := 's';
  if (N = 'getScale') or (N = 'getTranslation') then
  begin
    var Output := FloatArray(VM, Args[1].AsRef, 3);
    for var I := 0 to 2 do
      Output.Elements[I] := TJVMValue.Float(Component(O, Prefix + string(Axes[I + 1]), Ord(Prefix = 's')));
    Exit;
  end;
  for var I := 0 to 2 do
  begin
    var Key := Prefix + string(Axes[I + 1]);
    var V := Args[I + 1].AsFloat;
    if N = 'scale' then
      V := V * Component(O, Key, 1)
    else if N = 'translate' then
      V := V + Component(O, Key);
    O.Fields.AddOrSetValue(P + Key, TJVMValue.Float(V));
  end;
end;

function InvokeJ2MEM3G(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Matrix, Other: TM3GMatrix;
  Vector: TM3GVector;
begin
  if M3GEnvironmentHandles(Method.Owner.Name) then
    Exit(InvokeM3GEnvironment(VM, Method, Args));
  if M3GSpriteHandles(Method.Owner.Name) then
    Exit(InvokeM3GSprite(VM, Method, Args));
  if M3GKeyframeHandles(Method.Owner.Name) then
    Exit(InvokeM3GKeyframe(VM, Method, Args));
  if M3GAnimationHandles(Method.Owner.Name) then
    Exit(InvokeM3GAnimation(VM, Method, Args));
  if M3GSkinHandles(Method.Owner.Name) then
    Exit(InvokeM3GSkin(VM, Method, Args));
  if M3GPickingHandles(Method.Owner.Name) then
    Exit(InvokeM3GPicking(VM, Method, Args));
  if M3GMorphHandles(Method.Owner.Name) then
    Exit(InvokeM3GMorph(VM, Method, Args));
  if M3GTextureHandles(Method.Owner.Name) then
    Exit(InvokeM3GTexture(VM, Method, Args));
  if M3GMeshHandles(Method.Owner.Name) then
    Exit(InvokeM3GMesh(VM, Method, Args));
  if M3GSceneHandles(Method.Owner.Name) then
    Exit(InvokeM3GScene(VM, Method, Args));
  if Method.Owner.Name = TransformableName then
    Exit(InvokeTransformable(VM, Method, Args));
  if M3GGeometryHandles(Method.Owner.Name) then
    Exit(InvokeM3GGeometry(VM, Method, Args));
  Result := Default(TJVMValue);
  var N := Method.Name;
  var D := Method.Descriptor;
  var C := Method.Owner.Name;
  var Self := Args[0].AsRef;
  var O := VM.GetObject(Self);
  if C = TransformName then
  begin
    if (N = '<init>') or (N = 'set') then
    begin
      if D = '()V' then
        Matrix := M3GIdentity
      else if D = '([F)V' then
      begin
        var A := FloatArray(VM, Args[1].AsRef, 16);
        for var I := 0 to 15 do
          Matrix[I] := A.Elements[I].AsFloat;
      end
      else
        Matrix := M3GGetMatrix(VM, Args[1].AsRef);
      M3GPutMatrix(VM, Self, Matrix);
      Exit;
    end;
    Matrix := M3GGetMatrix(VM, Self);
    if N = 'get' then
    begin
      var A := FloatArray(VM, Args[1].AsRef, 16);
      for var I := 0 to 15 do
        A.Elements[I] := TJVMValue.Float(Matrix[I]);
      Exit;
    end;
    if N = 'transform' then
    begin
      if D = '([F)V' then
      begin
        var A := FloatArray(VM, Args[1].AsRef, 0);
        if Length(A.Elements) mod 4 <> 0 then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vector length');
        for var I := 0 to Length(A.Elements) div 4 - 1 do
        begin
          for var J := 0 to 3 do
            Vector[J] := A.Elements[I * 4 + J].AsFloat;
          Vector := M3GTransformVector(Matrix, Vector);
          for var J := 0 to 3 do
            A.Elements[I * 4 + J] := TJVMValue.Float(Vector[J]);
        end;
      end
      else
      begin
        var V := VM.GetObject(Args[1].AsRef);
        var A := FloatArray(VM, Args[2].AsRef, 0);
        var Components := IntField(V, 'components');
        var Count := IntField(V, 'vertices');
        if (Components = 4) or (Length(A.Elements) < Count * 4) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex transform dimensions');
        var Data := VM.GetObject(RefField(V, 'data'));
        for var I := 0 to Count - 1 do
        begin
          Vector := Default(TM3GVector);
          Vector[3] := Ord(Args[3].AsInt <> 0);
          for var J := 0 to Components - 1 do
            Vector[J] := Data.Elements[I * Components + J].AsInt;
          Vector := M3GTransformVector(Matrix, Vector);
          for var J := 0 to 3 do
            A.Elements[I * 4 + J] := TJVMValue.Float(Vector[J]);
        end;
      end;
      Exit;
    end;
    if N = 'setIdentity' then
      Matrix := M3GIdentity
    else if N = 'transpose' then
      Matrix := M3GTranspose(Matrix)
    else if N = 'invert' then
    begin
      if not M3GInverse(Matrix, Other) then
        VM.RaiseJava('java/lang/ArithmeticException', 'Singular or unrepresentable M3G inverse');
      Matrix := Other;
    end
    else
    begin
      if N = 'postMultiply' then
        Other := M3GGetMatrix(VM, Args[1].AsRef)
      else if N = 'postScale' then
        Other := M3GScale(Args[1].AsFloat, Args[2].AsFloat, Args[3].AsFloat)
      else if N = 'postTranslate' then
        Other := M3GTranslation(Args[1].AsFloat, Args[2].AsFloat, Args[3].AsFloat)
      else if N = 'postRotate' then
      begin
        if not M3GRotation(Args[1].AsFloat, Args[2].AsFloat, Args[3].AsFloat, Args[4].AsFloat, Other) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Zero M3G rotation axis');
      end
      else if N = 'postRotateQuat' then
      begin
        if not M3GQuaternion(Args[1].AsFloat, Args[2].AsFloat, Args[3].AsFloat, Args[4].AsFloat, Other) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Zero M3G quaternion');
      end
      else
        raise EJVMUnsupported.Create(C + '.' + N + D);
      Matrix := M3GMultiply(Matrix, Other);
    end;
    M3GPutMatrix(VM, Self, Matrix);
    Exit;
  end;
  if C = VertexName then
  begin
    if N = '<init>' then
    begin
      var Count := Args[1].AsInt;
      var Components := Args[2].AsInt;
      var Size := Args[3].AsInt;
      if (Count < 1) or (Count > 65535) or (Components < 2) or (Components > 4) or not (Size in [1, 2]) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex dimensions');
      var Descriptor := '[B';
      if Size = 2 then
        Descriptor := '[S';
      var DataRef := VM.NewArray(Descriptor, Count * Components);
      PutInt(O, 'vertices', Count);
      PutInt(O, 'components', Components);
      PutInt(O, 'size', Size);
      PutRef(O, 'data', DataRef);
      Exit;
    end;
    if N = 'getVertexCount' then
      Exit(TJVMValue.Int(IntField(O, 'vertices')));
    if N = 'getComponentCount' then
      Exit(TJVMValue.Int(IntField(O, 'components')));
    if N = 'getComponentType' then
      Exit(TJVMValue.Int(IntField(O, 'size')));
    if (N = 'set') or (N = 'get') then
    begin
      var A := VM.GetObject(Args[3].AsRef);
      var Size := 1;
      if D = '(II[S)V' then
        Size := 2;
      if IntField(O, 'size') <> Size then
        VM.RaiseJava('java/lang/IllegalStateException', 'M3G vertex component type');
      var First := Args[1].AsInt;
      var Count := Args[2].AsInt;
      var Total := IntField(O, 'vertices');
      var Components := IntField(O, 'components');
      if (Count < 0) or (Int64(Count) * Components > Length(A.Elements)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex value count');
      if (First < 0) or (First > Total) or (Count > Total - First) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G vertex range');
      var Data := VM.GetObject(RefField(O, 'data'));
      for var I := 0 to Count * Components - 1 do
        if N = 'set' then
          Data.Elements[First * Components + I] := A.Elements[I]
        else
          A.Elements[I] := Data.Elements[First * Components + I];
      Exit;
    end;
  end;
  if C = ObjectName then
  begin
    if (N = 'animate') or (N = 'addAnimationTrack') or (N = 'removeAnimationTrack') or
      (N = 'getAnimationTrack') or (N = 'getAnimationTrackCount') then
      Exit(InvokeM3GAnimationObject(VM, Method, Args));
    if N = 'getUserID' then
      Exit(TJVMValue.Int(IntField(O, 'id')));
    if N = 'setUserID' then
    begin
      PutInt(O, 'id', Args[1].AsInt);
      Exit;
    end;
    if N = 'getUserObject' then
      Exit(TJVMValue.Ref(RefField(O, 'user')));
    if N = 'setUserObject' then
    begin
      PutRef(O, 'user', Args[1].AsRef);
      Exit;
    end;
    if N = 'getReferences' then
    begin
      var Refs := M3GObjectReferences(VM, O);
      if Args[1].AsRef <> 0 then
      begin
        var Output := VM.GetObject(Args[1].AsRef);
        if Length(Output.Elements) < Length(Refs) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G reference output length');
        for var I := 0 to High(Refs) do
          Output.Elements[I] := TJVMValue.Ref(Refs[I]);
      end;
      Exit(TJVMValue.Int(Length(Refs)));
    end;
    if N = 'find' then
    begin
      var Pending := TList<Integer>.Create;
      var Visited := TDictionary<Integer, Boolean>.Create;
      try
        Pending.Add(Self);
        while Pending.Count > 0 do
        begin
          var Ref := Pending.Last;
          Pending.Delete(Pending.Count - 1);
          if Visited.ContainsKey(Ref) then
            Continue;
          Visited.Add(Ref, True);
          var Item := VM.GetObject(Ref);
          if IntField(Item, 'id') = Args[1].AsInt then
            Exit(TJVMValue.Ref(Ref));
          // Duplicate user IDs are legal and any matching object is permitted.
          // Prefer the first reference/child consistently with getReferences,
          // rather than accidentally searching the last inserted branch first.
          var Refs := M3GObjectReferences(VM, Item);
          for var K := High(Refs) downto 0 do
            Pending.Add(Refs[K]);
        end;
        Result := TJVMValue.Ref(0);
      finally
        Visited.Free;
        Pending.Free;
      end;
      Exit;
    end;
    if N = 'duplicate' then
    begin
      if VM.IsAssignable(O.ClassName, Base + 'Node') then
        Exit(TJVMValue.Ref(M3GDuplicateNode(VM, Self)));
      if not VM.IsAssignable(O.ClassName, VertexName) and
        not VM.IsAssignable(O.ClassName, TransformableName) and
        not VM.IsAssignable(O.ClassName, Base + 'Appearance') and
        not VM.IsAssignable(O.ClassName, Base + 'Material') and
        not M3GTextureHandles(M3GDuplicateClass(VM, O)) and
        not M3GEnvironmentHandles(M3GDuplicateClass(VM, O)) and
        not M3GKeyframeHandles(M3GDuplicateClass(VM, O)) and
        not M3GAnimationHandles(M3GDuplicateClass(VM, O)) and
        not VM.IsAssignable(O.ClassName, 'javax/microedition/m3g/VertexBuffer') and
        not VM.IsAssignable(O.ClassName, 'javax/microedition/m3g/TriangleStripArray') then
        raise EJVMUnsupported.Create('M3G duplicate class ' + O.ClassName);
      var Clone := VM.NewObject(M3GDuplicateClass(VM, O));
      VM.AddRoot(Clone);
      try
        var Target := VM.GetObject(Clone);
        for var Pair in O.Fields do
          if Pair.Key.StartsWith(P) then
            Target.Fields.AddOrSetValue(Pair.Key, Pair.Value);
        // Object3D references and user objects remain shared for non-node
        // duplicates. Mutable internal storage must belong to the new object.
        for var Name in ['data', 'indices', 'strips', 'pixels', 'keyTimes', 'keyValues'] do
          if RefField(O, Name) <> 0 then
          begin
            var Data := VM.GetObject(RefField(O, Name));
            var CopyRef := VM.NewArray(Data.ClassName, Length(Data.Elements));
            PutRef(Target, Name, CopyRef);
            var CopyData := VM.GetObject(CopyRef);
            for var I := 0 to High(Data.Elements) do
              CopyData.Elements[I] := Data.Elements[I];
          end;
        Result := TJVMValue.Ref(Clone);
      finally
        VM.RemoveRoot(Clone);
      end;
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(C + '.' + N + D);
end;

end.

