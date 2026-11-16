unit J2ME.M3G.Scene;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Math;

function M3GCameraProjection(VM: TJVM; Ref: Integer): TM3GMatrix;

procedure InstallM3GScene(VM: TJVM);

function M3GSceneHandles(const Name: string): Boolean;

function InvokeM3GScene(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GSceneReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

function M3GWorldReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

function M3GDuplicateNode(VM: TJVM; Ref: Integer): Integer;

function M3GRelativeTransform(VM: TJVM; Source, Target: Integer; out Matrix: TM3GMatrix): Boolean;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, Java.Classes,
  J2ME.M3G, J2ME.M3G.Picking;

const
  Base = 'javax/microedition/m3g/';
  NodeName = Base + 'Node';
  GroupName = Base + 'Group';
  CameraName = Base + 'Camera';
  WorldName = Base + 'World';
  LightName = Base + 'Light';
  ND = 'Ljavax/microedition/m3g/Node;';
  TD = 'Ljavax/microedition/m3g/Transform;';
  P = '$m3g.';

function RefField(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsRef;
end;

function IntField(O: TJVMObject; const Name: string; Fallback: Integer): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsInt;
end;

function FloatField(O: TJVMObject; const Name: string; Fallback: Single): Single;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsFloat;
end;

procedure PutRef(O: TJVMObject; const Name: string; Ref: Integer);
begin
  O.Fields.AddOrSetValue(P + Name, TJVMValue.Ref(Ref));
end;

function M3GCameraProjection(VM: TJVM; Ref: Integer): TM3GMatrix;
begin
  var O := VM.GetObject(Ref);
  var Mode := IntField(O, 'projectionType', 48);
  Result := M3GIdentity;
  if Mode = 48 then
    for var I := 0 to 15 do
      Result[I] := FloatField(O, 'projection' + IntToStr(I), Result[I])
  else
  begin
    var Height: Double := FloatField(O, 'projectionParam1', 0);
    var Aspect: Double := FloatField(O, 'projectionParam2', 0);
    var near: Double := FloatField(O, 'projectionParam3', 0);
    var far: Double := FloatField(O, 'projectionParam4', 0);
    if near = far then
      VM.RaiseJava('java/lang/ArithmeticException', 'Empty M3G camera volume');
    Result := Default(TM3GMatrix);
    if Mode = 50 then
    begin
      Height := Tan(Height * (Pi / 360));
      Result[0] := 1 / (Aspect * Height);
      Result[5] := 1 / Height;
      Result[10] := -(near + far) / (far - near);
      Result[11] := -2 * near * far / (far - near);
      Result[14] := -1;
    end
    else
    begin
      Result[0] := 2 / (Aspect * Height);
      Result[5] := 2 / Height;
      Result[10] := -2 / (far - near);
      Result[11] := -(near + far) / (far - near);
      Result[15] := 1;
    end;
  end;
end;

function M3GSceneReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  var Ref := RefField(O, 'children');
  if Ref <> 0 then
  begin
    var Data := VM.GetObject(Ref);
    SetLength(Result, Length(Data.Elements));
    for var I := 0 to High(Result) do
      Result[I] := Data.Elements[I].AsRef;
  end;
end;

function M3GWorldReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, WorldName) then
    for var Key in ['activeCamera', 'background'] do
    begin
      var Ref := RefField(O, Key);
      if Ref <> 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Ref;
      end;
    end;
end;

procedure ConstantInt(B: TJavaClassBuilder; const Name: string; Value: Integer);
begin
  B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
  B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
end;

procedure InstallM3GScene(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(NodeName, Base + 'Transformable', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    var Value := 144;
    for var N in ['NONE', 'ORIGIN', 'X_AXIS', 'Y_AXIS', 'Z_AXIS'] do
    begin
      ConstantInt(B, N, Value);
      Inc(Value);
    end;
    B.JavaClass.AddNative('getParent', '()' + ND);
    B.JavaClass.AddNative('getTransformTo', '(' + ND + TD + ')Z');
    B.JavaClass.AddNative('align', '(' + ND + ')V').Access := JVM_ACC_PUBLIC or JVM_ACC_FINAL or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('setAlignment', '(' + ND + 'I' + ND + 'I)V');
    B.JavaClass.AddNative('getAlignmentTarget', '(I)I');
    B.JavaClass.AddNative('getAlignmentReference', '(I)' + ND);
    B.JavaClass.AddNative('getScope', '()I');
    B.JavaClass.AddNative('setScope', '(I)V');
    B.JavaClass.AddNative('getAlphaFactor', '()F');
    B.JavaClass.AddNative('setAlphaFactor', '(F)V');
    for var N in ['Rendering', 'Picking'] do
    begin
      B.JavaClass.AddNative('is' + N + 'Enabled', '()Z');
      B.JavaClass.AddNative('set' + N + 'Enable', '(Z)V');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(GroupName, NodeName);
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('addChild', '(' + ND + ')V');
    B.JavaClass.AddNative('removeChild', '(' + ND + ')V');
    B.JavaClass.AddNative('getChildCount', '()I');
    B.JavaClass.AddNative('getChild', '(I)' + ND);
    B.JavaClass.AddNative('pick', '(IFFFFFFLjavax/microedition/m3g/RayIntersection;)Z');
    B.JavaClass.AddNative('pick', '(IFFLjavax/microedition/m3g/Camera;Ljavax/microedition/m3g/RayIntersection;)Z');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(CameraName, NodeName);
  try
    ConstantInt(B, 'GENERIC', 48);
    ConstantInt(B, 'PARALLEL', 49);
    ConstantInt(B, 'PERSPECTIVE', 50);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('setGeneric', '(' + TD + ')V');
    B.JavaClass.AddNative('setParallel', '(FFFF)V');
    B.JavaClass.AddNative('setPerspective', '(FFFF)V');
    B.JavaClass.AddNative('getProjection', '(' + TD + ')I');
    B.JavaClass.AddNative('getProjection', '([F)I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(WorldName, GroupName);
  try
    B.JavaClass.AddNative('<init>', '()V');
    for var N in ['ActiveCamera', 'Background'] do
    begin
      var Descriptor := 'Ljavax/microedition/m3g/Background;';
      if N = 'ActiveCamera' then
        Descriptor := 'Ljavax/microedition/m3g/Camera;';
      B.JavaClass.AddNative('get' + N, '()' + Descriptor);
      B.JavaClass.AddNative('set' + N, '(' + Descriptor + ')V');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(LightName, NodeName);
  try
    var Value := 128;
    for var N in ['AMBIENT', 'DIRECTIONAL', 'OMNI', 'SPOT'] do
    begin
      ConstantInt(B, N, Value);
      Inc(Value);
    end;
    B.JavaClass.AddNative('<init>', '()V');
    for var N in ['Color', 'Mode'] do
    begin
      B.JavaClass.AddNative('get' + N, '()I');
      B.JavaClass.AddNative('set' + N, '(I)V');
    end;
    for var N in ['Intensity', 'SpotAngle', 'SpotExponent'] do
    begin
      B.JavaClass.AddNative('get' + N, '()F');
      B.JavaClass.AddNative('set' + N, '(F)V');
    end;
    for var N in ['Constant', 'Linear', 'Quadratic'] do
      B.JavaClass.AddNative('get' + N + 'Attenuation', '()F');
    B.JavaClass.AddNative('setAttenuation', '(FFF)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function M3GSceneHandles(const Name: string): Boolean;
begin
  Result := (Name = NodeName) or (Name = GroupName) or (Name = CameraName) or (Name = WorldName) or (Name = LightName);
end;

function M3GRelativeTransform(VM: TJVM; Source, Target: Integer; out Matrix: TM3GMatrix): Boolean;
begin
  var Ancestors := TDictionary<Integer, TM3GMatrix>.Create;
  try
    Matrix := M3GIdentity;
    var Ref := Source;
    while Ref <> 0 do
    begin
      if Ancestors.ContainsKey(Ref) then
        raise EJVMError.Create('Cyclic M3G parent chain');
      Ancestors.Add(Ref, Matrix);
      Matrix := M3GMultiply(M3GComposite(VM, Ref), Matrix);
      Ref := RefField(VM.GetObject(Ref), 'parent');
    end;
    var TargetMatrix := M3GIdentity;
    Ref := Target;
    var Seen := TDictionary<Integer, Boolean>.Create;
    try
      while Ref <> 0 do
      begin
        if Ancestors.TryGetValue(Ref, Matrix) then
        begin
          var Inverse: TM3GMatrix;
          if not M3GInverse(TargetMatrix, Inverse) then
            VM.RaiseJava('java/lang/ArithmeticException', 'Singular M3G path');
          Matrix := M3GMultiply(Inverse, Matrix);
          Exit(True);
        end;
        if Seen.ContainsKey(Ref) then
          raise EJVMError.Create('Cyclic M3G parent chain');
        Seen.Add(Ref, True);
        TargetMatrix := M3GMultiply(M3GComposite(VM, Ref), TargetMatrix);
        Ref := RefField(VM.GetObject(Ref), 'parent');
      end;
    finally
      Seen.Free;
    end;
    Result := False;
  finally
    Ancestors.Free;
  end;
end;

function M3GDuplicateNode(VM: TJVM; Ref: Integer): Integer;
begin
  var Map := TDictionary<Integer, Integer>.Create;
  var Originals := TList<Integer>.Create;
  try
    Originals.Add(Ref);
    var I := 0;
    while I < Originals.Count do
    begin
      var Source := VM.GetObject(Originals[I]);
      var Clone := VM.NewObject(M3GDuplicateClass(VM, Source));
      VM.AddRoot(Clone);
      Map.Add(Originals[I], Clone);
      var Target := VM.GetObject(Clone);
      for var Pair in Source.Fields do
        if Pair.Key.StartsWith(P) then
          Target.Fields.AddOrSetValue(Pair.Key, Pair.Value);
      PutRef(Target, 'parent', 0);
      for var Child in M3GSceneReferences(VM, Source) do
        Originals.Add(Child);
      Inc(I);
    end;
    for var Original in Originals do
    begin
      var Target := VM.GetObject(Map[Original]);
      var Camera := RefField(Target, 'activeCamera');
      var Mapped: Integer;
      if (Camera <> 0) and Map.TryGetValue(Camera, Mapped) then
        PutRef(Target, 'activeCamera', Mapped);
      for var Key in ['alignZRef', 'alignYRef'] do
      begin
        var Alignment := RefField(Target, Key);
        if (Alignment <> 0) and Map.TryGetValue(Alignment, Mapped) then
          PutRef(Target, Key, Mapped);
      end;
      var Skeleton := RefField(Target, 'skinSkeleton');
      if (Skeleton <> 0) and Map.TryGetValue(Skeleton, Mapped) then
        PutRef(Target, 'skinSkeleton', Mapped);
      var BoneRef := RefField(Target, 'skinBones');
      if BoneRef <> 0 then
      begin
        var Bones := VM.GetObject(BoneRef);
        var DataRef := VM.NewArray(Bones.ClassName, Length(Bones.Elements));
        PutRef(Target, 'skinBones', DataRef);
        var Data := VM.GetObject(DataRef);
        for I := 0 to High(Bones.Elements) do
        begin
          var Bone := Bones.Elements[I].AsRef;
          if Map.TryGetValue(Bone, Mapped) then
            Bone := Mapped;
          Data.Elements[I] := TJVMValue.Ref(Bone);
        end;
      end;
      var Children := M3GSceneReferences(VM, VM.GetObject(Original));
      if Length(Children) = 0 then
        PutRef(Target, 'children', 0)
      else
      begin
        var DataRef := VM.NewArray('[' + ND, Length(Children));
        PutRef(Target, 'children', DataRef);
        var Data := VM.GetObject(DataRef);
        for I := 0 to High(Children) do
        begin
          Data.Elements[I] := TJVMValue.Ref(Map[Children[I]]);
          PutRef(VM.GetObject(Map[Children[I]]), 'parent', Map[Original]);
        end;
      end;
    end;
    Result := Map[Ref];
  finally
    for var Clone in Map.Values do
      VM.RemoveRoot(Clone);
    Originals.Free;
    Map.Free;
  end;
end;

function SceneRoot(VM: TJVM; Ref: Integer): Integer;
begin
  Result := Ref;
  while Ref <> 0 do
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G alignment cancelled');
    Result := Ref;
    Ref := RefField(VM.GetObject(Ref), 'parent');
  end;
end;

// Shortest rotation from an initial unit Y or Z axis. The antiparallel
// case has no unique solution; consistently use a half turn about X.
function AlignAxis(Axis: Integer; const Target: TM3GDoubleVector): TM3GMatrix;
begin
  Result := M3GIdentity;
  var Length := Sqrt(Sqr(Target[0]) + Sqr(Target[1]) + Sqr(Target[2]));
  if Length = 0 then
    Exit; // An origin at the node's own position has no direction.
  var X: Double;
  var Y: Double;
  var Z: Double;
  if Axis = 2 then
  begin
    X := -Target[1] / Length;
    Y := Target[0] / Length;
    Z := 0;
  end
  else
  begin
    X := Target[2] / Length;
    Y := 0;
    Z := -Target[0] / Length;
  end;
  var S := Sqrt(X * X + Y * Y + Z * Z);
  var C := Target[Axis] / Length;
  if S = 0 then
  begin
    if C < 0 then
    begin
      Result[5] := -1;
      Result[10] := -1;
    end;
    Exit;
  end;
  X := X / S;
  Y := Y / S;
  Z := Z / S;
  var T := 1 - C;
  Result[0] := X * X * T + C;
  Result[1] := X * Y * T - Z * S;
  Result[2] := X * Z * T + Y * S;
  Result[4] := Y * X * T + Z * S;
  Result[5] := Y * Y * T + C;
  Result[6] := Y * Z * T - X * S;
  Result[8] := Z * X * T - Y * S;
  Result[9] := Z * Y * T + X * S;
  Result[10] := Z * Z * T + C;
end;

procedure AlignNodes(VM: TJVM; Self, Reference: Integer);
var
  Common, Root: Integer;

  function TargetVector(Ref: Integer; O: TJVMObject; const Axis: string): TM3GDoubleVector;
  begin
    var Target := IntField(O, 'align' + Axis + 'Target', 144);
    var Other := RefField(O, 'align' + Axis + 'Ref');
    if Other = 0 then
      Other := Common;
    if SceneRoot(VM, Other) <> Root then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G alignment reference has no scene path');
    var Ancestor := Other;
    while Ancestor <> 0 do
    begin
      if Ancestor = Ref then
        VM.RaiseJava('java/lang/IllegalStateException', 'M3G alignment reference is self or descendant');
      Ancestor := RefField(VM.GetObject(Ancestor), 'parent');
    end;
    // Only T defines the initial frame. Do not invert the aligned node's
    // old orientation, scale or generic matrix (which may even be singular).
    var M: TM3GMatrix;
    if not M3GRelativeTransform(VM, Other, RefField(O, 'parent'), M) then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G alignment reference has no parent path');
    Result := Default(TM3GDoubleVector);
    if Target = 145 then
      Result[3] := 1
    else
      Result[Target - 146] := 1;
    Result := M3GDoubleTransform(M, Result);
    if Target = 145 then
    begin
      Result[0] := Result[0] - FloatField(O, 'tx', 0);
      Result[1] := Result[1] - FloatField(O, 'ty', 0);
      Result[2] := Result[2] - FloatField(O, 'tz', 0);
    end;
  end;

begin
  Root := SceneRoot(VM, Self);
  Common := Reference;
  if Common = 0 then
    Common := Self;
  if SceneRoot(VM, Common) <> Root then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G common alignment reference has no scene path');
  var Pending := TList<Integer>.Create;
  try
    Pending.Add(Self);
    while Pending.Count > 0 do
    begin
      if VM.StopRequested then
        raise EJVMError.Create('M3G alignment cancelled');
      var Ref := Pending.Last;
      Pending.Delete(Pending.Count - 1);
      var O := VM.GetObject(Ref);
      var Z := IntField(O, 'alignZTarget', 144);
      var Y := IntField(O, 'alignYTarget', 144);
      if (Z <> 144) or (Y <> 144) then
      begin
        var Rotation := M3GIdentity;
        if Z <> 144 then
        begin
          Rotation := AlignAxis(2, TargetVector(Ref, O, 'Z'));
          if Y <> 144 then
          begin
            var local := M3GDoubleTransform(M3GTranspose(Rotation), TargetVector(Ref, O, 'Y'));
            var Length := Sqrt(Sqr(local[0]) + Sqr(local[1]));
            if Length <> 0 then
            begin
              var Twist := M3GIdentity;
              Twist[0] := local[1] / Length;
              Twist[1] := local[0] / Length;
              Twist[4] := -local[0] / Length;
              Twist[5] := local[1] / Length;
              Rotation := M3GMultiply(Rotation, Twist);
            end;
          end;
        end
        else
          Rotation := AlignAxis(1, TargetVector(Ref, O, 'Y'));
        for var K := 0 to 15 do
          O.Fields.AddOrSetValue(P + 'orientation' + IntToStr(K), TJVMValue.Float(Rotation[K]));
      end;
      var Children := M3GSceneReferences(VM, O);
      for var K := High(Children) downto 0 do
        Pending.Add(Children[K]);
    end;
  finally
    Pending.Free;
  end;
end;

function InvokeM3GScene(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Self := Args[0].AsRef;
  var O := VM.GetObject(Self);
  var N := Method.Name;
  if N = 'pick' then
    Exit(M3GPickGroup(VM, Method, Args));
  var C := Method.Owner.Name;
  if N = '<init>' then
    Exit; // Identity/default components are implicit.
  if C = NodeName then
  begin
    if N = 'setAlignment' then
    begin
      var ZRef := Args[1].AsRef;
      var Z := Args[2].AsInt;
      var YRef := Args[3].AsRef;
      var Y := Args[4].AsInt;
      if (Z < 144) or (Z > 148) or (Y < 144) or (Y > 148) or
        ((ZRef = YRef) and (Z = Y) and (Z <> 144)) or (ZRef = Self) or (YRef = Self) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G alignment parameters');
      PutRef(O, 'alignZRef', ZRef);
      PutRef(O, 'alignYRef', YRef);
      O.Fields.AddOrSetValue(P + 'alignZTarget', Args[2]);
      O.Fields.AddOrSetValue(P + 'alignYTarget', Args[4]);
      Exit;
    end;
    if (N = 'getAlignmentTarget') or (N = 'getAlignmentReference') then
    begin
      var Axis := Args[1].AsInt;
      if (Axis <> 147) and (Axis <> 148) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G alignment query axis');
      var Key := 'alignY';
      if Axis = 148 then
        Key := 'alignZ';
      if N = 'getAlignmentTarget' then
        Exit(TJVMValue.Int(IntField(O, Key + 'Target', 144)));
      Exit(TJVMValue.Ref(RefField(O, Key + 'Ref')));
    end;
    if N = 'align' then
    begin
      AlignNodes(VM, Self, Args[1].AsRef);
      Exit;
    end;
    if N = 'getParent' then
      Exit(TJVMValue.Ref(RefField(O, 'parent')));
    if N = 'getScope' then
      Exit(TJVMValue.Int(IntField(O, 'scope', -1)));
    if N = 'getAlphaFactor' then
      Exit(TJVMValue.Float(FloatField(O, 'alpha', 1)));
    if N = 'setScope' then
    begin
      O.Fields.AddOrSetValue(P + 'scope', Args[1]);
      Exit;
    end;
    if N = 'setAlphaFactor' then
    begin
      var V := Args[1].AsFloat;
      if not ((V >= 0) and (V <= 1)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G alpha range');
      O.Fields.AddOrSetValue(P + 'alpha', Args[1]);
      Exit;
    end;
    if N = 'getTransformTo' then
    begin
      var Target := Args[1].AsRef;
      VM.GetObject(Target);
      VM.GetObject(Args[2].AsRef);
      var M: TM3GMatrix;
      var Found := M3GRelativeTransform(VM, Self, Target, M);
      if Found then
        M3GPutMatrix(VM, Args[2].AsRef, M);
      Exit(TJVMValue.Int(Ord(Found)));
    end;
    var Key := 'render';
    if (N = 'isPickingEnabled') or (N = 'setPickingEnable') then
      Key := 'pick';
    if N.StartsWith('is') then
      Exit(TJVMValue.Int(IntField(O, Key, 1)));
    if N.StartsWith('set') then
    begin
      O.Fields.AddOrSetValue(P + Key, Args[1]);
      Exit;
    end;
  end;
  if C = GroupName then
  begin
    var Children := M3GSceneReferences(VM, O);
    if N = 'getChildCount' then
      Exit(TJVMValue.Int(Length(Children)));
    if N = 'getChild' then
    begin
      var Index := Args[1].AsInt;
      if (Index < 0) or (Index >= Length(Children)) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G child index');
      Exit(TJVMValue.Ref(Children[Index]));
    end;
    var Child := Args[1].AsRef;
    if N = 'addChild' then
    begin
      var Item := VM.GetObject(Child);
      var Parent := RefField(Item, 'parent');
      if VM.IsAssignable(Item.ClassName, WorldName) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G World cannot be a child');
      if Parent = Self then
        Exit;
      if Parent <> 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G child already attached');
      var Ancestor := Self;
      while Ancestor <> 0 do
      begin
        if Ancestor = Child then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G hierarchy cycle');
        Ancestor := RefField(VM.GetObject(Ancestor), 'parent');
      end;
      var DataRef := VM.NewArray('[' + ND, Length(Children) + 1);
      var Data := VM.GetObject(DataRef);
      for var I := 0 to High(Children) do
        Data.Elements[I] := TJVMValue.Ref(Children[I]);
      Data.Elements[High(Data.Elements)] := TJVMValue.Ref(Child);
      PutRef(O, 'children', DataRef);
      PutRef(Item, 'parent', Self);
      Exit;
    end;
    if N = 'removeChild' then
    begin
      if Child = 0 then
        Exit;
      var Item := VM.GetObject(Child);
      if RefField(Item, 'parent') <> Self then
        Exit;
      var DataRef := VM.NewArray('[' + ND, Length(Children) - 1);
      var Data := VM.GetObject(DataRef);
      var Index := 0;
      for var Ref in Children do
        if Ref <> Child then
        begin
          Data.Elements[Index] := TJVMValue.Ref(Ref);
          Inc(Index);
        end;
      PutRef(O, 'children', DataRef);
      PutRef(Item, 'parent', 0);
      Exit;
    end;
  end;
  if C = WorldName then
  begin
    var Key := 'background';
    if (N = 'getActiveCamera') or (N = 'setActiveCamera') then
      Key := 'activeCamera';
    if N.StartsWith('get') then
      Exit(TJVMValue.Ref(RefField(O, Key)));
    if N.StartsWith('set') then
    begin
      if Key = 'activeCamera' then
        VM.GetObject(Args[1].AsRef);
      PutRef(O, Key, Args[1].AsRef);
      Exit;
    end;
  end;
  if C = LightName then
  begin
    if N = 'getMode' then
      Exit(TJVMValue.Int(IntField(O, 'lightMode', 129)));
    if N = 'setMode' then
    begin
      var V := Args[1].AsInt;
      if (V < 128) or (V > 131) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G light mode');
      O.Fields.AddOrSetValue(P + 'lightMode', Args[1]);
      Exit;
    end;
    if N = 'getColor' then
      Exit(TJVMValue.Int(IntField(O, 'lightColor', $FFFFFF)));
    if N = 'setColor' then
    begin
      O.Fields.AddOrSetValue(P + 'lightColor', TJVMValue.Int(Args[1].AsInt and $FFFFFF));
      Exit;
    end;
    if N = 'setAttenuation' then
    begin
      var A := Args[1].AsFloat;
      var B := Args[2].AsFloat;
      var Q := Args[3].AsFloat;
      if (A < 0) or (B < 0) or (Q < 0) or ((A = 0) and (B = 0) and (Q = 0)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G attenuation coefficients');
      O.Fields.AddOrSetValue(P + 'ConstantAttenuation', Args[1]);
      O.Fields.AddOrSetValue(P + 'LinearAttenuation', Args[2]);
      O.Fields.AddOrSetValue(P + 'QuadraticAttenuation', Args[3]);
      Exit;
    end;
    var Key := Copy(N, 4, MaxInt);
    if N.StartsWith('get') then
    begin
      var Fallback: Single := 0;
      if (Key = 'Intensity') or (Key = 'ConstantAttenuation') then
        Fallback := 1
      else if Key = 'SpotAngle' then
        Fallback := 45;
      Exit(TJVMValue.Float(FloatField(O, Key, Fallback)));
    end;
    if N.StartsWith('set') then
    begin
      var V := Args[1].AsFloat;
      var Limit: Single := 128;
      if Key = 'SpotAngle' then
        Limit := 90;
      if (Key <> 'Intensity') and not ((V >= 0) and (V <= Limit)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G spotlight parameter');
      O.Fields.AddOrSetValue(P + Key, Args[1]);
      Exit;
    end;
  end;
  if C = CameraName then
  begin
    if N = 'setGeneric' then
    begin
      var M := M3GGetMatrix(VM, Args[1].AsRef);
      for var I := 0 to 15 do
        O.Fields.AddOrSetValue(P + 'projection' + IntToStr(I), TJVMValue.Float(M[I]));
      O.Fields.AddOrSetValue(P + 'projectionType', TJVMValue.Int(48));
      Exit;
    end;
    if (N = 'setParallel') or (N = 'setPerspective') then
    begin
      var Height := Args[1].AsFloat;
      var Aspect := Args[2].AsFloat;
      var near := Args[3].AsFloat;
      var far := Args[4].AsFloat;
      var Mode := 49;
      if N = 'setPerspective' then
        Mode := 50;
      if (Height <= 0) or (Aspect <= 0) or ((Mode = 50) and ((Height >= 180) or (near <= 0) or (far <= 0))) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G camera parameters');
      for var I := 1 to 4 do
        O.Fields.AddOrSetValue(P + 'projectionParam' + IntToStr(I), Args[I]);
      O.Fields.AddOrSetValue(P + 'projectionType', TJVMValue.Int(Mode));
      Exit;
    end;
    if N = 'getProjection' then
    begin
      var Mode := IntField(O, 'projectionType', 48);
      if Method.Descriptor = '([F)I' then
      begin
        if Args[1].AsRef <> 0 then
        begin
          var Output := VM.GetObject(Args[1].AsRef);
          if Length(Output.Elements) < 4 then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G camera output length');
          if Mode <> 48 then
            for var I := 1 to 4 do
              Output.Elements[I - 1] := TJVMValue.Float(FloatField(O, 'projectionParam' + IntToStr(I), 0));
        end;
      end
      else if Args[1].AsRef <> 0 then
      begin
        M3GPutMatrix(VM, Args[1].AsRef, M3GCameraProjection(VM, Self));
      end;
      Exit(TJVMValue.Int(Mode));
    end;
  end;
  raise EJVMUnsupported.Create(C + '.' + N + Method.Descriptor);
end;

end.

