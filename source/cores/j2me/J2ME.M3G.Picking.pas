unit J2ME.M3G.Picking;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallM3GPicking(VM: TJVM);

function M3GPickingHandles(const Name: string): Boolean;

function InvokeM3GPicking(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GPickGroup(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, Java.Classes,
  J2ME.M3G, J2ME.M3G.Math, J2ME.M3G.Scene, J2ME.M3G.Geometry, J2ME.M3G.Morph,
  J2ME.M3G.Skin, J2ME.M3G.Sprite, J2ME.M3G.Texture;

const
  Name = 'javax/microedition/m3g/RayIntersection';
  P = '$m3g.';
  Base = 'javax/microedition/m3g/';

type
  TVec = array[0..2] of Double;

  THit = record
    Node, Submesh: Integer;
    Distance: Double;
    Normal: TVec;
    S, T: array[0..1] of Double;
  end;

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function F(O: TJVMObject; const Key: string; Fallback: Double = 0): Double;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsFloat;
end;

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsRef;
end;

procedure PF(O: TJVMObject; const Key: string; Value: Double);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Float(Value));
end;

function M3GPickingHandles(const Name: string): Boolean;
begin
  Result := Name = 'javax/microedition/m3g/RayIntersection';
end;

procedure InstallM3GPicking(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, 'java/lang/Object');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('getIntersected', '()Ljavax/microedition/m3g/Node;');
    B.JavaClass.AddNative('getSubmeshIndex', '()I');
    for var N in ['Distance', 'NormalX', 'NormalY', 'NormalZ'] do
      B.JavaClass.AddNative('get' + N, '()F');
    for var N in ['S', 'T'] do
      B.JavaClass.AddNative('getTexture' + N, '(I)F');
    B.JavaClass.AddNative('getRay', '([F)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeM3GPicking(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = '<init>' then
  begin
    O.Fields.AddOrSetValue(P + 'intersected', TJVMValue.Ref(0));
    O.Fields.AddOrSetValue(P + 'SubmeshIndex', TJVMValue.Int(0));
    PF(O, 'Distance', 0);
    PF(O, 'NormalX', 0);
    PF(O, 'NormalY', 0);
    PF(O, 'NormalZ', 1);
    for var K := 0 to 5 do
      PF(O, 'ray' + IntToStr(K), Ord(K = 5));
    for var K := 0 to M3GTextureUnits - 1 do
    begin
      PF(O, 's' + IntToStr(K), 0);
      PF(O, 't' + IntToStr(K), 0);
    end;
    Exit;
  end;
  if N = 'getIntersected' then
    Exit(TJVMValue.Ref(R(O, 'intersected')));
  if N = 'getSubmeshIndex' then
    Exit(TJVMValue.Int(I(O, 'SubmeshIndex')));
  if (N = 'getTextureS') or (N = 'getTextureT') then
  begin
    var Index := Args[1].AsInt;
    if (Index < 0) or (Index >= M3GTextureUnits) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G pick texture unit');
    var Key := 's';
    if N = 'getTextureT' then
      Key := 't';
    Exit(TJVMValue.Float(F(O, Key + IntToStr(Index))));
  end;
  if N = 'getRay' then
  begin
    var A := VM.GetObject(Args[1].AsRef);
    if Length(A.Elements) < 6 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G pick ray array length');
    for var K := 0 to 5 do
      A.Elements[K] := TJVMValue.Float(F(O, 'ray' + IntToStr(K)));
    Exit;
  end;
  if (N = 'getDistance') or N.StartsWith('getNormal') then
    Exit(TJVMValue.Float(F(O, Copy(N, 4, MaxInt))));
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

function Minus(const A, B: TVec): TVec;
begin
  for var K := 0 to 2 do
    Result[K] := A[K] - B[K];
end;

function Dot(const A, B: TVec): Double;
begin
  Result := A[0] * B[0] + A[1] * B[1] + A[2] * B[2];
end;

function Cross(const A, B: TVec): TVec;
begin
  Result[0] := A[1] * B[2] - A[2] * B[1];
  Result[1] := A[2] * B[0] - A[0] * B[2];
  Result[2] := A[0] * B[1] - A[1] * B[0];
end;

procedure Normalize(var V: TVec);
begin
  var Length := Sqrt(Dot(V, V));
  if (Length = 0) or IsNan(Length) or IsInfinite(Length) then
    V := Default(TVec)
  else
    for var K := 0 to 2 do
      V[K] := V[K] / Length;
end;

function Point(const Matrix: TM3GMatrix; const V: TM3GDoubleVector): TM3GDoubleVector;
begin
  Result := M3GDoubleTransform(Matrix, V);
  if Result[3] <> 0 then
    for var K := 0 to 2 do
      Result[K] := Result[K] / Result[3]
  else
    for var K := 0 to 2 do
      Result[K] := NaN;
end;

function M3GPickGroup(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
type
  TEntry = record
    Ref: Integer;
    Model: TM3GMatrix;
  end;
var
  Origin, Direction: TVec;
  Best: THit;
  CameraPick: Boolean;
  CameraToGroup, GroupToCamera, Projection, InverseProjection: TM3GMatrix;
  NDCX, NDCY: Double;

  procedure Cancel;
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G picking cancelled');
  end;

  procedure Mesh(Ref: Integer; const Model: TM3GMatrix);
  begin
    var O := VM.GetObject(Ref);
    var Needed := False;
    for var Sub := 0 to I(O, 'submeshCount') - 1 do
      if R(O, 'appearance' + IntToStr(Sub)) <> 0 then
        Needed := True;
    if not Needed then
      Exit;
    var Buffer := VM.GetObject(R(O, 'vertices'));
    var PosRef := R(Buffer, 'positions');
    if PosRef = 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'No M3G pick positions');
    var Position := VM.GetObject(PosRef);
    var Count := I(Position, 'vertices');
    var Data := VM.GetObject(R(Position, 'data'));
    var Skin: TArray<TM3GMatrix>;
    var Morph := Default(TM3GMorph);
    if VM.IsAssignable(O.ClassName, Base + 'SkinnedMesh') then
      Skin := M3GSkinMatrices(VM, Ref, Count);
    if VM.IsAssignable(O.ClassName, Base + 'MorphingMesh') then
      Morph := M3GPrepareMorph(VM, Ref);
    var Points: TArray<TM3GDoubleVector>;
    SetLength(Points, Count);
    for var Vertex := 0 to Count - 1 do
    begin
      if (Vertex and 255) = 0 then
        Cancel;
      var V := Default(TM3GDoubleVector);
      V[3] := 1;
      for var K := 0 to 2 do
      begin
        var Raw := Double(Data.Elements[Vertex * 3 + K].AsInt);
        if Length(Morph.Attributes[0]) <> 0 then
          Raw := Morph.Attributes[0][Vertex * 3 + K];
        V[K] := Raw * F(Buffer, 'positions.scale', 1) + F(Buffer, 'positions.bias' + IntToStr(K));
      end;
      if Vertex < Length(Skin) then
        V := M3GDoubleTransform(Skin[Vertex], V);
      Points[Vertex] := Point(Model, V);
    end;
    for var Sub := 0 to I(O, 'submeshCount') - 1 do
    begin
      var AppearanceRef := R(O, 'appearance' + IntToStr(Sub));
      if AppearanceRef = 0 then
        Continue;
      var Appearance := VM.GetObject(AppearanceRef);
      var Culling := 160;
      var Winding := 168;
      var PolygonRef := R(Appearance, 'PolygonMode');
      if PolygonRef <> 0 then
      begin
        var Mode := VM.GetObject(PolygonRef);
        Culling := I(Mode, 'Culling', 160);
        Winding := I(Mode, 'Winding', 168);
      end;
      var Indices := VM.GetObject(R(O, 'submesh' + IntToStr(Sub)));
      var IndexData := VM.GetObject(R(Indices, 'indices'));
      var Strips := VM.GetObject(R(Indices, 'strips'));
      for var K := 0 to High(IndexData.Elements) do
      begin
        if (K and 255) = 0 then
          Cancel;
        var Index := IndexData.Elements[K].AsInt;
        if (Index < 0) or (Index >= Count) then
          VM.RaiseJava('java/lang/IllegalStateException', 'M3G pick index outside vertex buffer');
      end;
      var Offset := 0;
      for var Strip in Strips.Elements do
      begin
        for var Triangle := 0 to Strip.AsInt - 3 do
        begin
          Cancel;
          var IDs: array[0..2] of Integer;
          IDs[0] := IndexData.Elements[Offset + Triangle + (Triangle and 1)].AsInt;
          IDs[1] := IndexData.Elements[Offset + Triangle + 1 - (Triangle and 1)].AsInt;
          IDs[2] := IndexData.Elements[Offset + Triangle + 2].AsInt;
          var V: array[0..2] of TVec;
          var Valid := True;
          for var J := 0 to 2 do
            for var K := 0 to 2 do
            begin
              V[J][K] := Points[IDs[J]][K];
              if IsNan(V[J][K]) or IsInfinite(V[J][K]) or (Points[IDs[J]][3] = 0) then
                Valid := False;
            end;
          if not Valid then
            Continue;
          var E1 := Minus(V[1], V[0]);
          var E2 := Minus(V[2], V[0]);
          var H := Cross(Direction, E2);
          var Det := Dot(E1, H);
          if Det = 0 then
            Continue;
          var Front := Det > 0;
          if Winding = 169 then
            Front := not Front;
          if ((Culling = 160) and not Front) or ((Culling = 161) and Front) then
            Continue;
          var Delta := Minus(Origin, V[0]);
          var U := Dot(Delta, H) / Det;
          if (U < 0) or (U > 1) then
            Continue;
          var Q := Cross(Delta, E1);
          var W := Dot(Direction, Q) / Det;
          if (W < 0) or (U + W > 1) then
            Continue;
          var Distance := Dot(E2, Q) / Det;
          if IsNan(Distance) or IsInfinite(Distance) or (Distance < 0) or (Distance >= Best.Distance) then
            Continue;
          var Weight: array[0..2] of Double;
          Weight[0] := 1 - U - W;
          Weight[1] := U;
          Weight[2] := W;
          var Sum: Double := 0;
          for var J := 0 to 2 do
          begin
            Weight[J] := Weight[J] / Points[IDs[J]][3];
            Sum := Sum + Weight[J];
          end;
          if Sum = 0 then
            Continue;
          for var J := 0 to 2 do
            Weight[J] := Weight[J] / Sum;
          var Hit := Default(THit);
          Hit.Node := Ref;
          Hit.Submesh := Sub;
          Hit.Distance := Distance;
          Hit.Normal[2] := 1;
          var NormalRef := R(Buffer, 'normals');
          if NormalRef <> 0 then
          begin
            Hit.Normal := Default(TVec);
            var Normals := VM.GetObject(R(VM.GetObject(NormalRef), 'data'));
            for var J := 0 to 2 do
            begin
              var N: TVec;
              for var K := 0 to 2 do
              begin
                var Raw := Double(Normals.Elements[IDs[J] * 3 + K].AsInt);
                if Length(Morph.Attributes[1]) <> 0 then
                  Raw := Morph.Attributes[1][IDs[J] * 3 + K];
                N[K] := 2 * Raw + 1;
              end;
              if IDs[J] < Length(Skin) then
              begin
                var Inv: TM3GMatrix;
                if not M3GInverse(Skin[IDs[J]], Inv) then
                  Inv := M3GIdentity;
                var Original := N;
                for var K := 0 to 2 do
                begin
                  N[K] := 0;
                  for var C := 0 to 2 do
                    N[K] := N[K] + Inv[C * 4 + K] * Original[C];
                end;
              end;
              for var K := 0 to 2 do
                Hit.Normal[K] := Hit.Normal[K] + Weight[J] * N[K];
            end;
            Normalize(Hit.Normal);
          end;
          for var UnitIndex := 0 to M3GTextureUnits - 1 do
          begin
            var TextureRef := R(Appearance, 'texture' + IntToStr(UnitIndex));
            var Key := 'tex' + IntToStr(UnitIndex);
            var CoordRef := R(Buffer, Key);
            if (TextureRef = 0) or (CoordRef = 0) then
              Continue;
            var Coordinates := VM.GetObject(CoordRef);
            var Components := I(Coordinates, 'components');
            var CoordData := VM.GetObject(R(Coordinates, 'data'));
            var TexturePoint := Default(TM3GDoubleVector);
            TexturePoint[3] := 1;
            for var K := 0 to Components - 1 do
              for var J := 0 to 2 do
              begin
                var Raw := Double(CoordData.Elements[IDs[J] * Components + K].AsInt);
                if Length(Morph.Attributes[3 + UnitIndex]) <> 0 then
                  Raw := Morph.Attributes[3 + UnitIndex][IDs[J] * Components + K];
                TexturePoint[K] := TexturePoint[K] + Weight[J] * (Raw * F(Buffer, Key + '.scale', 1) + F(Buffer, Key + '.bias' + IntToStr(K)));
              end;
            TexturePoint := M3GDoubleTransform(M3GComposite(VM, TextureRef), TexturePoint);
            if TexturePoint[3] <> 0 then
            begin
              Hit.S[UnitIndex] := TexturePoint[0] / TexturePoint[3];
              Hit.T[UnitIndex] := TexturePoint[1] / TexturePoint[3];
            end;
          end;
          Best := Hit;
        end;
        Inc(Offset, Strip.AsInt);
      end;
    end;
  end;

  procedure Sprite(Ref: Integer; const Model: TM3GMatrix);
  begin
    var O := VM.GetObject(Ref);
    var AppearanceRef := R(O, 'appearance');
    var CW := I(O, 'cropWidth');
    var CH := I(O, 'cropHeight');
    if not CameraPick or (I(O, 'scaled') = 0) or (AppearanceRef = 0) or (CW = 0) or (CH = 0) then
      Exit;
    var Clip: TM3GDoubleVector;
    var Width, Height: Double;
    if not M3GSpriteExtent(M3GMultiply(GroupToCamera, Model), Projection, Clip, Width, Height) then
      Exit;
    var X := (NDCX - Clip[0] / Clip[3]) / Width + 0.5;
    var Y := (Clip[1] / Clip[3] - NDCY) / Height + 0.5;
    if (X < 0) or (X > 1) or (Y < 0) or (Y > 1) then
      Exit;
    var Image := M3GImageView(VM, R(O, 'image'));
    if CW < 0 then
      X := 1 - X;
    if CH < 0 then
      Y := 1 - Y;
    var S := (Double(I(O, 'cropX')) + X * Abs(CW)) / Image.Width;
    var T := (Double(I(O, 'cropY')) + Y * Abs(CH)) / Image.Height;
    if (S < 0) or (S > 1) or (T < 0) or (T > 1) then
      Exit;
    var PX := Min(Trunc(S * Image.Width), Image.Width - 1);
    var PY := Min(Trunc(T * Image.Height), Image.Height - 1);
    var Alpha := (UInt32(Image.Pixels.Elements[PY * Image.Width + PX].AsInt) shr 24) / 255;
    var ModeRef := R(VM.GetObject(AppearanceRef), 'CompositingMode');
    if (ModeRef <> 0) and (Alpha < F(VM.GetObject(ModeRef), 'AlphaThreshold')) then
      Exit;
    var NDC: TM3GDoubleVector;
    NDC[0] := NDCX;
    NDC[1] := NDCY;
    NDC[2] := Clip[2] / Clip[3];
    NDC[3] := 1;
    var CameraPoint := Point(InverseProjection, NDC);
    CameraPoint[3] := 1;
    var GroupPoint := Point(CameraToGroup, CameraPoint);
    var Axis := 0;
    for var K := 1 to 2 do
      if Abs(Direction[K]) > Abs(Direction[Axis]) then
        Axis := K;
    var Distance := (GroupPoint[Axis] - Origin[Axis]) / Direction[Axis];
    if IsNan(Distance) or IsInfinite(Distance) or (Distance < 0) or (Distance >= Best.Distance) then
      Exit;
    Best := Default(THit);
    Best.Node := Ref;
    Best.Distance := Distance;
    Best.Normal[2] := 1;
    Best.S[0] := S;
    Best.T[0] := T;
  end;

begin
  var Root := Args[0].AsRef;
  VM.GetObject(Root);
  var Scope := Args[1].AsInt;
  CameraPick := Method.Descriptor.StartsWith('(IFFL');
  var ResultRef := Args[High(Args)].AsRef;
  if ResultRef <> 0 then
    VM.GetObject(ResultRef);
  if CameraPick then
  begin
    var CameraRef := Args[4].AsRef;
    VM.GetObject(CameraRef);
    if not M3GRelativeTransform(VM, CameraRef, Root, CameraToGroup) then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G pick camera has no scene path');
    Projection := M3GCameraProjection(VM, CameraRef);
    if not M3GInverse(Projection, InverseProjection) or not M3GInverse(CameraToGroup, GroupToCamera) then
      VM.RaiseJava('java/lang/ArithmeticException', 'Singular M3G pick camera');
    NDCX := 2 * Double(Args[2].AsFloat) - 1;
    NDCY := 1 - 2 * Double(Args[3].AsFloat);
    var V: TM3GDoubleVector;
    V[0] := NDCX;
    V[1] := NDCY;
    V[2] := -1;
    V[3] := 1;
    var near := Point(InverseProjection, V);
    near[3] := 1;
    near := Point(CameraToGroup, near);
    V[2] := 1;
    var far := Point(InverseProjection, V);
    far[3] := 1;
    far := Point(CameraToGroup, far);
    for var K := 0 to 2 do
    begin
      Origin[K] := near[K];
      Direction[K] := far[K] - near[K];
    end;
  end
  else
  begin
    for var K := 0 to 2 do
    begin
      Origin[K] := Args[K + 2].AsFloat;
      Direction[K] := Args[K + 5].AsFloat;
    end;
    if (Direction[0] = 0) and (Direction[1] = 0) and (Direction[2] = 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Zero M3G pick direction');
  end;
  Result := TJVMValue.Int(0);
  for var K := 0 to 2 do
    if IsNan(Origin[K]) or IsInfinite(Origin[K]) or IsNan(Direction[K]) or IsInfinite(Direction[K]) then
      Exit;
  if (Direction[0] = 0) and (Direction[1] = 0) and (Direction[2] = 0) then
    Exit;
  Best := Default(THit);
  Best.Distance := Infinity;
  var Stack := TList<TEntry>.Create;
  try
    var Entry: TEntry;
    Entry.Ref := Root;
    Entry.Model := M3GIdentity;
    Stack.Add(Entry);
    while Stack.Count <> 0 do
    begin
      Cancel;
      Entry := Stack.Last;
      Stack.Delete(Stack.Count - 1);
      var O := VM.GetObject(Entry.Ref);
      if I(O, 'pick', 1) = 0 then
        Continue;
      if (I(O, 'scope', -1) and Scope) <> 0 then
      begin
        if VM.IsAssignable(O.ClassName, Base + 'Mesh') then
          Mesh(Entry.Ref, Entry.Model)
        else if CameraPick and VM.IsAssignable(O.ClassName, Base + 'Sprite3D') then
          Sprite(Entry.Ref, Entry.Model);
      end;
      var Children := M3GSceneReferences(VM, O);
      for var K := High(Children) downto 0 do
      begin
        var Child: TEntry;
        Child.Ref := Children[K];
        Child.Model := M3GMultiply(Entry.Model, M3GComposite(VM, Child.Ref));
        Stack.Add(Child);
      end;
    end;
  finally
    Stack.Free;
  end;
  if Best.Node = 0 then
    Exit;
  Result := TJVMValue.Int(1);
  if ResultRef = 0 then
    Exit;
  var O := VM.GetObject(ResultRef);
  O.Fields.AddOrSetValue(P + 'intersected', TJVMValue.Ref(Best.Node));
  O.Fields.AddOrSetValue(P + 'SubmeshIndex', TJVMValue.Int(Best.Submesh));
  PF(O, 'Distance', Best.Distance);
  for var K := 0 to 2 do
  begin
    PF(O, 'ray' + IntToStr(K), Origin[K]);
    PF(O, 'ray' + IntToStr(K + 3), Direction[K]);
    PF(O, 'Normal' + Copy('XYZ', K + 1, 1), Best.Normal[K]);
  end;
  for var K := 0 to M3GTextureUnits - 1 do
  begin
    PF(O, 's' + IntToStr(K), Best.S[K]);
    PF(O, 't' + IntToStr(K), Best.T[K]);
  end;
end;

end.

