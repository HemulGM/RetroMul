unit J2ME.M3G;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Math;

procedure InstallJ2MEM3G(VM: TJVM);

function J2MEM3GHandles(const Name: string): Boolean;

function InvokeJ2MEM3G(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GGetMatrix(VM: TJVM; Ref: Integer): TM3GMatrix;

procedure M3GPutMatrix(VM: TJVM; Ref: Integer; const Matrix: TM3GMatrix);

implementation

uses
  System.SysUtils, Java.Classes;

const
  Base = 'javax/microedition/m3g/';
  ObjectName = Base + 'Object3D';
  TransformName = Base + 'Transform';
  VertexName = Base + 'VertexArray';
  TransformD = 'Ljavax/microedition/m3g/Transform;';
  P = '$m3g.';

function J2MEM3GHandles(const Name: string): Boolean;
begin
  Result := (Name = ObjectName) or (Name = TransformName) or (Name = VertexName);
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
  // No package version or Node discovery is advertised until scene loading and
  // rendering exist. These are functional geometry objects, not Node stubs.
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
end;

function InvokeJ2MEM3G(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Matrix, Other: TM3GMatrix;
  Vector: TM3GVector;
begin
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
    // The only concrete Object3D currently installed is VertexArray. It has no
    // Object3D references: its storage and application user object are excluded.
    if N = 'getReferences' then
      Exit(TJVMValue.Int(0));
    if N = 'find' then
    begin
      if IntField(O, 'id') = Args[1].AsInt then
        Result := TJVMValue.Ref(Self)
      else
        Result := TJVMValue.Ref(0);
      Exit;
    end;
    if N = 'duplicate' then
    begin
      if not VM.IsAssignable(O.ClassName, VertexName) then
        raise EJVMUnsupported.Create('M3G duplicate class ' + O.ClassName);
      var Clone := VM.NewObject(O.ClassName);
      VM.AddRoot(Clone);
      try
        var Target := VM.GetObject(Clone);
        for var Pair in O.Fields do
          Target.Fields.AddOrSetValue(Pair.Key, Pair.Value);
        var Data := VM.GetObject(RefField(O, 'data'));
        var CopyRef := VM.NewArray(Data.ClassName, Length(Data.Elements));
        var CopyData := VM.GetObject(CopyRef);
        for var I := 0 to High(Data.Elements) do
          CopyData.Elements[I] := Data.Elements[I];
        PutRef(Target, 'data', CopyRef);
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

