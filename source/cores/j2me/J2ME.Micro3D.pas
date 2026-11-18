unit J2ME.Micro3D;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEMicro3D(VM: TJVM);

function J2MEMicro3DHandles(const ClassName: string): Boolean;

function InvokeJ2MEMicro3D(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

procedure SetMicro3DViewDirection(VM: TJVM; const Args: TArray<TJVMValue>);

implementation

uses
  System.Math, System.StrUtils, System.SysUtils, Java.Classes;

{$Q-}{$R-}

const
  Prefix = 'com/mascotcapsule/micro3d/v3/';
  VectorName = Prefix + 'Vector3D';
  AffineName = Prefix + 'AffineTrans';
  UtilName = Prefix + 'Util3D';
  LayoutName = Prefix + 'FigureLayout';
  LightName = Prefix + 'Light';
  VectorType = 'L' + VectorName + ';';
  AffineType = 'L' + AffineName + ';';
  FixedOne = 4096;
  VectorFields: array[0..2] of string = ('x', 'y', 'z');
  AffineFields: array[0..2, 0..3] of string = (
    ('m00', 'm01', 'm02', 'm03'), ('m10', 'm11', 'm12', 'm13'), ('m20', 'm21', 'm22', 'm23'));
  Identity: array[0..2, 0..3] of Integer = (
    (FixedOne, 0, 0, 0), (0, FixedOne, 0, 0), (0, 0, FixedOne, 0));

type
  TVector = array[0..2] of Integer;

  TRealVector = array[0..2] of Double;

  TAffine = array[0..2, 0..3] of Integer;

  TProjection = (Scale, Parallel, FieldOfView, NearPlaneSize);

procedure InstallJ2MEMicro3D(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Start(const Name: string);
  begin
    B := TJavaClassBuilder.Create(Name, 'java/lang/Object');
  end;

  procedure Finish;
  begin
    VM.DefineClass(B.Detach);
    B.Free;
    B := nil;
  end;

  procedure Native(const Name, Descriptor: string; IsStatic: Boolean = False);
  begin
    var M := B.JavaClass.AddNative(Name, Descriptor, IsStatic);
    if Name <> '<init>' then
      M.Access := M.Access or JVM_ACC_FINAL;
  end;

begin
  B := nil;
  try
    Start(VectorName);
    for var Field in VectorFields do
    begin
      B.Field(Field, 'I', JVM_ACC_PUBLIC);
      Native('get' + UpperCase(Field), '()I');
      Native('set' + UpperCase(Field), '(I)V');
    end;
    Native('<init>', '()V');
    Native('<init>', '(III)V');
    Native('<init>', '(' + VectorType + ')V');
    Native('set', '(III)V');
    Native('set', '(' + VectorType + ')V');
    Native('unit', '()V');
    Native('innerProduct', '(' + VectorType + ')I');
    Native('innerProduct', '(' + VectorType + VectorType + ')I', True);
    Native('outerProduct', '(' + VectorType + ')V');
    Native('outerProduct', '(' + VectorType + VectorType + ')' + VectorType, True);
    Finish;

    Start(AffineName);
    for var Row := 0 to 2 do
      for var Col := 0 to 3 do
        B.Field(AffineFields[Row, Col], 'I', JVM_ACC_PUBLIC);
    Native('<init>', '()V');
    for var Descriptor in ['(IIIIIIIIIIII)V', '(' + AffineType + ')V', '([I)V', '([II)V', '([[I)V'] do
    begin
      Native('<init>', Descriptor);
      Native('set', Descriptor);
    end;
    Native('get', '([I)V');
    Native('get', '([II)V');
    Native('setIdentity', '()V');
    for var Name in ['rotationX', 'rotationY', 'rotationZ', 'setRotationX', 'setRotationY', 'setRotationZ'] do
      Native(Name, '(I)V');
    for var Name in ['setRotation', 'rotationV'] do
      Native(Name, '(' + VectorType + 'I)V');
    for var Name in ['lookAt', 'setViewTrans'] do
      Native(Name, '(' + VectorType + VectorType + VectorType + ')V');
    for var Name in ['mul', 'multiply'] do
    begin
      Native(Name, '(' + AffineType + ')V');
      Native(Name, '(' + AffineType + AffineType + ')V');
    end;
    for var Name in ['transform', 'transPoint'] do
      Native(Name, '(' + VectorType + ')' + VectorType);
    Finish;

    Start(UtilName);
    for var Name in ['sin', 'cos', 'sqrt'] do
      Native(Name, '(I)I', True);
    Finish;

    Start(LayoutName);
    B.Field('$transform', AffineType, JVM_ACC_PRIVATE);
    B.Field('$transforms', '[' + AffineType, JVM_ACC_PRIVATE);
    for var Field in ['$projection', '$scaleX', '$scaleY', '$centerX', '$centerY', '$parallelWidth', '$parallelHeight', '$near', '$far', '$angle', '$width', '$height'] do
      B.Field(Field, 'I', JVM_ACC_PRIVATE);
    Native('<init>', '()V');
    Native('<init>', '(' + AffineType + 'IIII)V');
    Native('getAffineTrans', '()' + AffineType);
    Native('setAffineTrans', '(' + AffineType + ')V');
    Native('setAffineTrans', '([' + AffineType + ')V');
    Native('setAffineTransArray', '([' + AffineType + ')V');
    Native('selectAffineTrans', '(I)V');
    for var Name in ['getScaleX', 'getScaleY', 'getCenterX', 'getCenterY', 'getParallelWidth', 'getParallelHeight'] do
      Native(Name, '()I');
    for var Name in ['setScale', 'setCenter', 'setParallelSize'] do
      Native(Name, '(II)V');
    Native('setPerspective', '(III)V');
    Native('setPerspective', '(IIII)V');
    Finish;

    Start(LightName);
    B.Field('$direction', VectorType, JVM_ACC_PRIVATE);
    B.Field('$parallel', 'I', JVM_ACC_PRIVATE);
    B.Field('$ambient', 'I', JVM_ACC_PRIVATE);
    Native('<init>', '()V');
    Native('<init>', '(' + VectorType + 'II)V');
    for var Name in ['getDirection', 'getParallelLightDirection'] do
      Native(Name, '()' + VectorType);
    for var Name in ['setDirection', 'setParallelLightDirection'] do
      Native(Name, '(' + VectorType + ')V');
    for var Name in ['getDirIntensity', 'getParallelLightIntensity', 'getAmbIntensity', 'getAmbientIntensity'] do
      Native(Name, '()I');
    for var Name in ['setDirIntensity', 'setParallelLightIntensity', 'setAmbIntensity', 'setAmbientIntensity'] do
      Native(Name, '(I)V');
    Finish;
  finally
    B.Free;
  end;
end;

function J2MEMicro3DHandles(const ClassName: string): Boolean;
begin
  Result := MatchStr(ClassName, [VectorName, AffineName, UtilName, LayoutName, LightName]);
end;

function FieldKey(const Owner, Name: string; const Descriptor: string = 'I'): string;
begin
  Result := Owner + '.' + Name + ':' + Descriptor;
end;

function ReadVector(VM: TJVM; Ref: Integer): TVector;
begin
  var O := VM.GetObject(Ref);
  for var I := 0 to High(Result) do
    Result[I] := O.Fields[FieldKey(VectorName, VectorFields[I])].AsInt;
end;

procedure WriteVector(O: TJVMObject; const Value: TVector);
begin
  for var I := 0 to High(Value) do
    O.Fields[FieldKey(VectorName, VectorFields[I])] := TJVMValue.Int(Value[I]);
end;

function NewVector(VM: TJVM; const Value: TVector): TJVMValue;
begin
  Result := TJVMValue.Ref(VM.NewObject(VectorName));
  WriteVector(VM.GetObject(Result.AsRef), Value);
end;

function ReadAffine(O: TJVMObject): TAffine;
begin
  for var Row := 0 to 2 do
    for var Col := 0 to 3 do
      Result[Row, Col] := O.Fields[FieldKey(AffineName, AffineFields[Row, Col])].AsInt;
end;

procedure WriteAffine(O: TJVMObject; const Value: TAffine);
begin
  for var Row := 0 to 2 do
    for var Col := 0 to 3 do
      O.Fields[FieldKey(AffineName, AffineFields[Row, Col])] := TJVMValue.Int(Value[Row, Col]);
end;

function FromFixedProduct(Value: Int64): Integer;
begin
  // Arithmetic shift with half a Q12 unit added before rounding.
  Result := Integer(UInt64(Value + FixedOne div 2) shr 12);
end;

function IntDot(const A, B: TVector): Int64;
begin
  Result := 0;
  for var I := 0 to High(A) do
    Inc(Result, Int64(A[I]) * B[I]);
end;

function RealVector(const A: TVector): TRealVector;
begin
  for var I := 0 to High(A) do
    Result[I] := A[I];
end;

function Normalize(var A: TRealVector): Boolean;
begin
  var LengthSquared := Sqr(A[0]) + Sqr(A[1]) + Sqr(A[2]);
  Result := LengthSquared > 0;
  if Result then
  begin
    var InverseLength := 1 / Sqrt(LengthSquared);
    for var I := 0 to High(A) do
      A[I] := A[I] * InverseLength;
  end;
end;

function Cross(const A, B: TRealVector): TRealVector;
begin
  Result[0] := A[1] * B[2] - A[2] * B[1];
  Result[1] := A[2] * B[0] - A[0] * B[2];
  Result[2] := A[0] * B[1] - A[1] * B[0];
end;

function Radians(Angle: Integer): Double;
begin
  Result := (Angle and 4095) * (2 * Pi / 4096);
end;

function InvokeVector(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Name := Method.Name;
  if (Name = 'innerProduct') or (Name = 'outerProduct') then
  begin
    var A := ReadVector(VM, Args[0].AsRef);
    var B := ReadVector(VM, Args[1].AsRef);
    if Name = 'innerProduct' then
      Exit(TJVMValue.Int(FromFixedProduct(IntDot(A, B))));
    var Product: TVector;
    for var I := 0 to High(Product) do
    begin
      var J := (I + 1) mod 3;
      var K := (I + 2) mod 3;
      Product[I] := FromFixedProduct(Int64(A[J]) * B[K] - Int64(A[K]) * B[J]);
    end;
    if Method.Access and JVM_ACC_STATIC <> 0 then
      Exit(NewVector(VM, Product));
    WriteVector(VM.GetObject(Args[0].AsRef), Product);
    Exit;
  end;

  var O := VM.GetObject(Args[0].AsRef);
  if (Name = '<init>') or (Name = 'set') then
  begin
    var Value: TVector;
    case Length(Args) of
      1:
        Value := Default(TVector);
      2:
        Value := ReadVector(VM, Args[1].AsRef);
      4:
        for var I := 0 to High(Value) do
          Value[I] := Args[I + 1].AsInt;
    else
      raise EJVMUnsupported.Create(VectorName + '.' + Name + Method.Descriptor);
    end;
    WriteVector(O, Value);
    Exit;
  end;
  if Name = 'unit' then
  begin
    var Value := ReadVector(VM, Args[0].AsRef);
    var Normal := RealVector(Value);
    if Normalize(Normal) then
    begin
      for var I := 0 to High(Value) do
        Value[I] := Round(Normal[I] * FixedOne);
      WriteVector(O, Value);
    end;
    Exit;
  end;
  var Axis := IndexStr(Name, ['getX', 'getY', 'getZ', 'setX', 'setY', 'setZ']);
  if Axis >= 0 then
  begin
    var Key := FieldKey(VectorName, VectorFields[Axis mod 3]);
    if Axis < 3 then
      Exit(O.Fields[Key]);
    O.Fields[Key] := Args[1];
    Exit;
  end;
  raise EJVMUnsupported.Create(VectorName + '.' + Name + Method.Descriptor);
end;

function ReadArrayMatrix(VM: TJVM; const Args: TArray<TJVMValue>; Rows: Boolean): TAffine;
begin
  var O := VM.GetObject(Args[1].AsRef);
  if Rows then
  begin
    if O.ElementCount < 3 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Affine matrix needs three rows');
    for var Row := 0 to 2 do
    begin
      var A := VM.GetObject(O.ElementValues[Row].AsRef);
      if A.ElementCount < 4 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Affine matrix row needs four elements');
      for var Col := 0 to 3 do
        Result[Row, Col] := A.ElementValues[Col].AsInt;
    end;
    Exit;
  end;
  var Offset := 0;
  if Length(Args) = 3 then
    Offset := Args[2].AsInt;
  if (Offset < 0) or (Offset > O.ElementCount - 12) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Affine matrix needs twelve elements at the offset');
  for var Row := 0 to 2 do
    for var Col := 0 to 3 do
      Result[Row, Col] := O.ElementValues[Offset + Row * 4 + Col].AsInt;
end;

procedure WriteArrayMatrix(VM: TJVM; const Args: TArray<TJVMValue>; const Value: TAffine);
begin
  var O := VM.GetObject(Args[1].AsRef);
  var Offset := 0;
  if Length(Args) = 3 then
    Offset := Args[2].AsInt;
  if (Offset < 0) or (Offset > O.ElementCount - 12) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Affine matrix needs twelve elements at the offset');
  for var Row := 0 to 2 do
    for var Col := 0 to 3 do
      O.ElementValues[Offset + Row * 4 + Col] := TJVMValue.Int(Value[Row, Col]);
end;

function MultiplyAffine(const A, B: TAffine): TAffine;
begin
  for var Row := 0 to 2 do
    for var Col := 0 to 3 do
    begin
      var Sum: Int64 := 0;
      for var I := 0 to 2 do
        Inc(Sum, Int64(A[Row, I]) * B[I, Col]);
      Result[Row, Col] := FromFixedProduct(Sum);
      if Col = 3 then
        Inc(Result[Row, Col], A[Row, Col]);
    end;
end;

procedure RotateAffine(var A: TAffine; const UnitAxis: TRealVector; Angle: Integer);
begin
  var S: Double;
  var C: Double;
  SinCos(Radians(Angle), S, C);
  for var Row := 0 to 2 do
    for var Col := 0 to 2 do
    begin
      var Value := (1 - C) * UnitAxis[Row] * UnitAxis[Col];
      if Row = Col then
        Value := Value + C
      else
      begin
        var Axis := 3 - Row - Col;
        if (Row + 1) mod 3 = Col then
          Value := Value - S * UnitAxis[Axis]
        else
          Value := Value + S * UnitAxis[Axis];
      end;
      A[Row, Col] := Round(Value * FixedOne);
    end;
end;

function BuildView(const Eye, Up: TVector; forward: TRealVector; out A: TAffine): Boolean;
var
  Right, Down: TRealVector;
begin
  Result := False;
  var ViewUp := RealVector(Up);
  // Cross the original integer directions before normalizing so parallel
  // vectors are detected without a floating-point normalization artifact.
  // The guest supplies up, while Mascot Capsule screen Y grows downward.
  Right := Cross(forward, ViewUp);
  if not Normalize(forward) or not Normalize(Right) then
    Exit;
  Down := Cross(forward, Right);
  for var I := 0 to 2 do
  begin
    A[0, I] := Round(Right[I] * FixedOne);
    A[1, I] := Round(Down[I] * FixedOne);
    A[2, I] := Round(forward[I] * FixedOne);
  end;
  for var Row := 0 to 2 do
  begin
    var Sum: Int64 := 0;
    for var I := 0 to 2 do
      Inc(Sum, Int64(A[Row, I]) * Eye[I]);
    A[Row, 3] := -FromFixedProduct(Sum);
  end;
  Result := True;
end;

function LookAt(const Eye, Target, Up: TVector; out A: TAffine): Boolean;
var
  forward: TRealVector;
begin
  for var I := 0 to High(forward) do
    forward[I] := Double(Target[I]) - Eye[I];
  Result := BuildView(Eye, Up, forward, A);
end;

procedure SetMicro3DViewDirection(VM: TJVM; const Args: TArray<TJVMValue>);
begin
  var Target := VM.GetObject(Args[0].AsRef);
  var Eye := ReadVector(VM, Args[1].AsRef);
  var Direction := RealVector(ReadVector(VM, Args[2].AsRef));
  var Up := ReadVector(VM, Args[3].AsRef);
  var Matrix: TAffine;
  if not BuildView(Eye, Up, Direction, Matrix) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Vodafone viewing direction');
  WriteAffine(Target, Matrix);
end;

function InvokeAffine(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  var Descriptor := Method.Descriptor;
  if (Name = '<init>') or (Name = 'set') then
  begin
    var Matrix: TAffine;
    if Descriptor = '()V' then
      Matrix := Default(TAffine)
    else if Descriptor = '(IIIIIIIIIIII)V' then
      for var Row := 0 to 2 do
        for var Col := 0 to 3 do
          Matrix[Row, Col] := Args[1 + Row * 4 + Col].AsInt
    else if Descriptor = '(' + AffineType + ')V' then
      Matrix := ReadAffine(VM.GetObject(Args[1].AsRef))
    else
      Matrix := ReadArrayMatrix(VM, Args, Descriptor = '([[I)V');
    WriteAffine(O, Matrix);
    Exit;
  end;
  if Name = 'get' then
  begin
    WriteArrayMatrix(VM, Args, ReadAffine(O));
    Exit;
  end;
  if Name = 'setIdentity' then
  begin
    WriteAffine(O, TAffine(Identity));
    Exit;
  end;
  if (Name = 'mul') or (Name = 'multiply') then
  begin
    var A := O;
    if Length(Args) = 3 then
      A := VM.GetObject(Args[1].AsRef);
    var B := VM.GetObject(Args[High(Args)].AsRef);
    WriteAffine(O, MultiplyAffine(ReadAffine(A), ReadAffine(B)));
    Exit;
  end;
  if (Name = 'transform') or (Name = 'transPoint') then
  begin
    var Point := ReadVector(VM, Args[1].AsRef);
    var Matrix := ReadAffine(O);
    var Value: TVector;
    for var Row := 0 to 2 do
    begin
      var Sum: Int64 := 0;
      for var Col := 0 to 2 do
        Inc(Sum, Int64(Matrix[Row, Col]) * Point[Col]);
      Value[Row] := FromFixedProduct(Sum) + Matrix[Row, 3];
    end;
    Exit(NewVector(VM, Value));
  end;
  if (Name = 'lookAt') or (Name = 'setViewTrans') then
  begin
    var Eye := ReadVector(VM, Args[1].AsRef);
    var Target := ReadVector(VM, Args[2].AsRef);
    var Up := ReadVector(VM, Args[3].AsRef);
    var Matrix: TAffine;
    if LookAt(Eye, Target, Up, Matrix) then
      WriteAffine(O, Matrix);
    Exit;
  end;

  var AxisIndex := IndexStr(Name, ['rotationX', 'rotationY', 'rotationZ',
      'setRotationX', 'setRotationY', 'setRotationZ', 'rotationV', 'setRotation']);
  if AxisIndex >= 0 then
  begin
    var Axis := Default(TRealVector);
    var Angle: Integer;
    if AxisIndex < 6 then
    begin
      Axis[AxisIndex mod 3] := 1;
      Angle := Args[1].AsInt;
    end
    else
    begin
      Axis := RealVector(ReadVector(VM, Args[1].AsRef));
      if not Normalize(Axis) then
        Exit;
      Angle := Args[2].AsInt;
    end;
    var Matrix := ReadAffine(O);
    RotateAffine(Matrix, Axis, Angle);
    WriteAffine(O, Matrix);
    Exit;
  end;
  raise EJVMUnsupported.Create(AffineName + '.' + Name + Descriptor);
end;

function InvokeLayout(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
const
  Properties: array[0..5] of string = (
    '$scaleX', '$scaleY', '$centerX', '$centerY', '$parallelWidth', '$parallelHeight');
var
  O: TJVMObject;

  procedure Put(const Name: string; Value: Integer);
  begin
    O.Fields[FieldKey(LayoutName, Name)] := TJVMValue.Int(Value);
  end;

  procedure SetTransform(Value: TJVMValue);
  begin
    if Value.AsRef = 0 then
    begin
      Value := TJVMValue.Ref(VM.NewObject(AffineName));
      WriteAffine(VM.GetObject(Value.AsRef), TAffine(Identity));
    end;
    O.Fields[FieldKey(LayoutName, '$transform', AffineType)] := Value;
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  if Name = '<init>' then
  begin
    if Length(Args) = 1 then
    begin
      SetTransform(TJVMValue.Ref(0));
      Put('$scaleX', 512);
      Put('$scaleY', 512);
    end
    else
    begin
      SetTransform(Args[1]);
      for var I := 0 to 3 do
        Put(Properties[I], Args[I + 2].AsInt);
    end;
    Exit;
  end;
  if Name = 'getAffineTrans' then
    Exit(O.Fields[FieldKey(LayoutName, '$transform', AffineType)]);
  if (Name = 'setAffineTrans') and (Method.Descriptor = '(' + AffineType + ')V') then
  begin
    SetTransform(Args[1]);
    Exit;
  end;
  if (Name = 'setAffineTrans') or (Name = 'setAffineTransArray') then
  begin
    var A := VM.GetObject(Args[1].AsRef);
    for var I := 0 to A.ElementCount - 1 do
      if A.ElementValues[I].AsRef = 0 then
        VM.RaiseJava('java/lang/NullPointerException', 'Affine transformation array element');
    O.Fields[FieldKey(LayoutName, '$transforms', '[' + AffineType)] := Args[1];
    Exit;
  end;
  if Name = 'selectAffineTrans' then
  begin
    var Ref := O.Fields[FieldKey(LayoutName, '$transforms', '[' + AffineType)].AsRef;
    if Ref = 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'No affine transformation array');
    var A := VM.GetObject(Ref);
    var Index := Args[1].AsInt;
    if (Index < 0) or (Index >= A.ElementCount) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Affine transformation index');
    var Value := A.ElementValues[Index];
    if Value.AsRef = 0 then
      VM.RaiseJava('java/lang/NullPointerException', 'Affine transformation array element');
    SetTransform(Value);
    Exit;
  end;
  var Index := IndexStr(Name, ['getScaleX', 'getScaleY', 'getCenterX', 'getCenterY', 'getParallelWidth', 'getParallelHeight']);
  if Index >= 0 then
    Exit(O.Fields[FieldKey(LayoutName, Properties[Index])]);
  Index := IndexStr(Name, ['setScale', 'setCenter', 'setParallelSize']);
  if Index >= 0 then
  begin
    if (Index = 2) and ((Args[1].AsInt < 0) or (Args[2].AsInt < 0)) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Parallel size');
    Put(Properties[Index * 2], Args[1].AsInt);
    Put(Properties[Index * 2 + 1], Args[2].AsInt);
    case Index of
      0:
        Put('$projection', Ord(TProjection.Scale));
      2:
        Put('$projection', Ord(TProjection.Parallel));
    end;
    Exit;
  end;
  if Name = 'setPerspective' then
  begin
    var NearDistance := Args[1].AsInt;
    var FarDistance := Args[2].AsInt;
    var First := Args[3].AsInt;
    if (NearDistance < 1) or (FarDistance >= 32768) or (NearDistance >= FarDistance) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Perspective clipping distances');
    if Length(Args) = 4 then
    begin
      if (First <= 0) or (First >= 2048) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Perspective angle');
      Put('$angle', First);
      Put('$projection', Ord(TProjection.FieldOfView));
    end
    else
    begin
      var Height := Args[4].AsInt;
      if (First < 0) or (Height < 0) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Perspective size');
      Put('$width', First);
      Put('$height', Height);
      Put('$projection', Ord(TProjection.NearPlaneSize));
    end;
    Put('$near', NearDistance);
    Put('$far', FarDistance);
    Exit;
  end;
  raise EJVMUnsupported.Create(LayoutName + '.' + Name + Method.Descriptor);
end;

function InvokeLight(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  var Direction := FieldKey(LightName, '$direction', VectorType);
  var Parallel := FieldKey(LightName, '$parallel');
  var Ambient := FieldKey(LightName, '$ambient');
  if Name = '<init>' then
  begin
    if Length(Args) = 1 then
    begin
      var Axis := Default(TVector);
      Axis[2] := FixedOne;
      O.Fields[Direction] := NewVector(VM, Axis);
      O.Fields[Parallel] := TJVMValue.Int(FixedOne);
      O.Fields[Ambient] := TJVMValue.Int(0);
      Exit;
    end;
    if Args[1].AsRef = 0 then
      VM.RaiseJava('java/lang/NullPointerException', 'Light direction');
    O.Fields[Direction] := Args[1];
    O.Fields[Parallel] := Args[2];
    O.Fields[Ambient] := Args[3];
    Exit;
  end;
  if MatchStr(Name, ['getDirection', 'getParallelLightDirection']) then
    Exit(O.Fields[Direction]);
  if MatchStr(Name, ['setDirection', 'setParallelLightDirection']) then
  begin
    if Args[1].AsRef = 0 then
      VM.RaiseJava('java/lang/NullPointerException', 'Light direction');
    O.Fields[Direction] := Args[1];
    Exit;
  end;
  if MatchStr(Name, ['getDirIntensity', 'getParallelLightIntensity']) then
    Exit(O.Fields[Parallel]);
  if MatchStr(Name, ['getAmbIntensity', 'getAmbientIntensity']) then
    Exit(O.Fields[Ambient]);
  if MatchStr(Name, ['setDirIntensity', 'setParallelLightIntensity']) then
  begin
    O.Fields[Parallel] := Args[1];
    Exit;
  end;
  if MatchStr(Name, ['setAmbIntensity', 'setAmbientIntensity']) then
  begin
    O.Fields[Ambient] := Args[1];
    Exit;
  end;
  raise EJVMUnsupported.Create(LightName + '.' + Name + Method.Descriptor);
end;

function InvokeJ2MEMicro3D(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  var Name := Method.Owner.Name;
  if Name = VectorName then
    Exit(InvokeVector(VM, Method, Args));
  if Name = AffineName then
    Exit(InvokeAffine(VM, Method, Args));
  if Name = LayoutName then
    Exit(InvokeLayout(VM, Method, Args));
  if Name = LightName then
    Exit(InvokeLight(VM, Method, Args));
  if Name = UtilName then
  begin
    var Argument := Args[0].AsInt;
    if Method.Name = 'sqrt' then
      Exit(TJVMValue.Int(Trunc(Sqrt(Abs(Int64(Argument))))));
    if Method.Name = 'sin' then
      Exit(TJVMValue.Int(Round(1024 * Sin(Radians(Argument)))));
    if Method.Name = 'cos' then
      Exit(TJVMValue.Int(Round(1024 * Cos(Radians(Argument)))));
  end;
  raise EJVMUnsupported.Create(Name + '.' + Method.Name + Method.Descriptor);
end;

end.

