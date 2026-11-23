unit J2ME.M3G.Graphics;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallM3GGraphics(VM: TJVM);

function InvokeM3GGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Java.Classes, J2ME.Image, J2ME.M3G, J2ME.M3G.Math,
  J2ME.M3G.Scene, J2ME.M3G.Raster, J2ME.M3G.Texture, J2ME.M3G.Environment,
  J2ME.M3G.Lighting, J2ME.M3G.Sprite, J2ME.M3G.Skin, J2ME.M3G.Morph;

{$Q-}{$R-}

const
  Name = 'javax/microedition/m3g/Graphics3D';
  P = '$m3g.';
  TD = 'Ljavax/microedition/m3g/Transform;';
  CD = 'Ljavax/microedition/m3g/Camera;';
  RenderD = '(Ljavax/microedition/m3g/VertexBuffer;Ljavax/microedition/m3g/IndexBuffer;Ljavax/microedition/m3g/Appearance;' + TD;

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsRef;
end;

function F(O: TJVMObject; const Key: string; Fallback: Single = 0): Single;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsFloat;
end;

procedure PI(O: TJVMObject; const Key: string; V: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(V));
end;

procedure PR(O: TJVMObject; const Key: string; V: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Ref(V));
end;

function G(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue('$' + Key, V) then
    Result := V.AsInt;
end;

function Matrix(O: TJVMObject; const Key: string): TM3GMatrix;
begin
  Result := M3GIdentity;
  for var N := 0 to 15 do
    Result[N] := F(O, Key + IntToStr(N), Result[N]);
end;

procedure PutMatrix(O: TJVMObject; const Key: string; const M: TM3GMatrix);
begin
  for var N := 0 to 15 do
    O.Fields.AddOrSetValue(P + Key + IntToStr(N), TJVMValue.Float(M[N]));
end;

procedure InstallM3GGraphics(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, 'java/lang/Object');
  try
    B.Field('$instance', 'Ljavax/microedition/m3g/Graphics3D;', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.JavaClass.AddNative('getInstance', '()Ljavax/microedition/m3g/Graphics3D;', True);
    var Values: TArray<Integer> := [2, 4, 8, 16];
    var N := 0;
    for var Key in ['ANTIALIAS', 'DITHER', 'TRUE_COLOR', 'OVERWRITE'] do
    begin
      B.Field(Key, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Values[N]);
      Inc(N);
    end;
    B.JavaClass.AddNative('bindTarget', '(Ljava/lang/Object;)V');
    B.JavaClass.AddNative('bindTarget', '(Ljava/lang/Object;ZI)V');
    B.JavaClass.AddNative('releaseTarget', '()V');
    B.JavaClass.AddNative('getTarget', '()Ljava/lang/Object;');
    B.JavaClass.AddNative('getHints', '()I');
    B.JavaClass.AddNative('isDepthBufferEnabled', '()Z');
    B.JavaClass.AddNative('setViewport', '(IIII)V');
    for var Key in ['X', 'Y', 'Width', 'Height'] do
      B.JavaClass.AddNative('getViewport' + Key, '()I');
    B.JavaClass.AddNative('setDepthRange', '(FF)V');
    for var Key in ['Near', 'Far'] do
      B.JavaClass.AddNative('getDepthRange' + Key, '()F');
    B.JavaClass.AddNative('setCamera', '(' + CD + TD + ')V');
    B.JavaClass.AddNative('getCamera', '(' + TD + ')' + CD);
    B.JavaClass.AddNative('clear', '(Ljavax/microedition/m3g/Background;)V');
    B.JavaClass.AddNative('render', RenderD + ')V');
    B.JavaClass.AddNative('render', RenderD + 'I)V');
    B.JavaClass.AddNative('render', '(Ljavax/microedition/m3g/World;)V');
    B.JavaClass.AddNative('render', '(Ljavax/microedition/m3g/Node;' + TD + ')V');
    B.JavaClass.AddNative('addLight', '(Ljavax/microedition/m3g/Light;' + TD + ')I');
    B.JavaClass.AddNative('setLight', '(ILjavax/microedition/m3g/Light;' + TD + ')V');
    B.JavaClass.AddNative('getLight', '(I' + TD + ')Ljavax/microedition/m3g/Light;');
    B.JavaClass.AddNative('getLightCount', '()I');
    B.JavaClass.AddNative('resetLights', '()V');
    // Build a fresh ordinary guest Hashtable. The composed method preserves
    // normal String hashing, boxed values, budgets and snapshot roots.
    B.Start;
    B.Ref($BB, B.ClassRef('java/util/Hashtable'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/util/Hashtable', '<init>', '()V'));
    B.Emit([$4B]);
    for var Key in ['supportAntialiasing', 'supportTrueColor', 'supportDithering', 'supportMipmapping', 'supportPerspectiveCorrection', 'supportLocalCameraLighting'] do
    begin
      B.Emit([$2A]);
      B.Ref($13, B.StringConstant(Key));
      var BooleanName := 'FALSE';
      if (Key = 'supportTrueColor') or (Key = 'supportPerspectiveCorrection') or (Key = 'supportLocalCameraLighting') then
        BooleanName := 'TRUE';
      B.Ref($B2, B.Member('java/lang/Boolean', BooleanName, 'Ljava/lang/Boolean;', 9));
      B.Ref($B6, B.Member('java/util/Hashtable', 'put', '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;'));
      B.Emit([$57]);
    end;
    for var Key in ['maxLights', 'maxViewportWidth', 'maxViewportHeight', 'maxViewportDimension', 'maxTextureDimension', 'maxSpriteCropDimension', 'maxTransformsPerVertex', 'numTextureUnits'] do
    begin
      var Value := 1024;
      if Key = 'maxLights' then
        Value := M3GMaxLights
      else if Key = 'maxTransformsPerVertex' then
        Value := M3GMaxTransformsPerVertex
      else if Key = 'numTextureUnits' then
        Value := 2;
      B.Emit([$2A]);
      B.Ref($13, B.StringConstant(Key));
      B.Ref($BB, B.ClassRef('java/lang/Integer'));
      B.Emit([$59]);
      B.Ref($13, B.IntConstant(Value));
      B.Ref($B7, B.Member('java/lang/Integer', '<init>', '(I)V'));
      B.Ref($B6, B.Member('java/util/Hashtable', 'put', '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;'));
      B.Emit([$57]);
    end;
    B.Emit([$2A, $B0]);
    B.Finish('getProperties', '()Ljava/util/Hashtable;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL, 5, 1);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function Surface(VM: TJVM; O: TJVMObject; Width, Height: Integer): TM3GRasterTarget;
begin
  Result := Default(TM3GRasterTarget);
  Result.Culling := 160;
  Result.Winding := 168;
  Result.Blending := 68;
  Result.DepthTest := True;
  Result.DepthWrite := True;
  Result.ColorWrite := True;
  Result.AlphaWrite := True;
  if R(O, 'target') = 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'No M3G render target');
  var Target := VM.GetObject(R(O, 'target'));
  var V: TJVMValue;
  if VM.IsAssignable(Target.ClassName, 'javax/microedition/m3g/Image2D') then
  begin
    var Image := M3GImageView(VM, R(O, 'target'));
    Width := Image.Width;
    Height := Image.Height;
    Result.Pixels := Image.Pixels;
    Result.PreserveAlpha := Image.Format = 100;
  end
  else if Target.Fields.TryGetValue('$target', V) then
  begin
    var Image := J2MEImageView(VM, V.AsRef);
    Width := Image.Width;
    Height := Image.Height;
    Result.Pixels := Image.Pixels;
  end;
  Result.Width := Width;
  Result.Height := Height;
  Result.ViewX := Double(I(O, 'viewX')) + I(O, 'tx');
  Result.ViewY := Double(I(O, 'viewY')) + I(O, 'ty');
  Result.ViewWidth := I(O, 'viewWidth');
  Result.ViewHeight := I(O, 'viewHeight');
  Result.Left := Trunc(EnsureRange(Max(Double(I(O, 'clipL')), Result.ViewX), 0.0, Double(Width)));
  Result.Top := Trunc(EnsureRange(Max(Double(I(O, 'clipT')), Result.ViewY), 0.0, Double(Height)));
  Result.Right := Trunc(EnsureRange(Min(Double(I(O, 'clipR')), Result.ViewX + Result.ViewWidth), Double(Result.Left), Double(Width)));
  Result.Bottom := Trunc(EnsureRange(Min(Double(I(O, 'clipB')), Result.ViewY + Result.ViewHeight), Double(Result.Top), Double(Height)));
  Result.NearDepth := F(O, 'near');
  Result.FarDepth := F(O, 'far', 1);
  Result.DepthEnabled := I(O, 'depthEnabled') <> 0;
  if Result.DepthEnabled then
  begin
    Result.Depth := VM.GetObject(R(O, 'depth'));
    if Length(Result.Depth.Elements) <> Width * Height then
      VM.RaiseJava('java/lang/IllegalStateException', 'Invalid M3G depth buffer');
  end;
end;

procedure AppearanceRaster(VM: TJVM; Appearance: TJVMObject; var Target: TM3GRasterTarget);
begin
  if R(Appearance, 'Fog') <> 0 then
  begin
    var Fog := VM.GetObject(R(Appearance, 'Fog'));
    Target.FogMode := I(Fog, 'mode', 81);
    Target.FogColor := UInt32(I(Fog, 'color'));
    Target.FogDensity := F(Fog, 'density', 1);
    Target.FogNear := F(Fog, 'near');
    Target.FogFar := F(Fog, 'far', 1);
  end;
  if R(Appearance, 'CompositingMode') <> 0 then
  begin
    var Mode := VM.GetObject(R(Appearance, 'CompositingMode'));
    Target.Blending := I(Mode, 'Blending', 68);
    Target.AlphaThreshold := F(Mode, 'AlphaThreshold');
    Target.DepthTest := I(Mode, 'DepthTest', 1) <> 0;
    Target.DepthWrite := I(Mode, 'DepthWrite', 1) <> 0;
    Target.ColorWrite := I(Mode, 'ColorWrite', 1) <> 0;
    Target.AlphaWrite := I(Mode, 'AlphaWrite', 1) <> 0;
    Target.DepthOffsetFactor := F(Mode, 'DepthOffsetFactor');
    Target.DepthOffsetUnits := F(Mode, 'DepthOffsetUnits');
  end;
end;

procedure Draw(VM: TJVM; O: TJVMObject; VertexRef, IndexRef, AppearanceRef: Integer; const Model: TM3GMatrix; Scope: Integer; Alpha: Double; var Pixels: TArray<UInt32>; Width, Height: Integer; SkinRef: Integer = 0; MorphRef: Integer = 0);
begin
  var Vertices := VM.GetObject(VertexRef);
  var Indices := VM.GetObject(IndexRef);
  var Appearance := VM.GetObject(AppearanceRef);
  var Target := Surface(VM, O, Width, Height);
  var CameraRef := R(O, 'camera');
  if CameraRef = 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'No M3G camera');
  var Camera := VM.GetObject(CameraRef);
  // Out-of-scope objects must not trigger deferred attribute validation.
  if (Scope and I(Camera, 'scope', -1)) = 0 then
    Exit;
  var PositionRef := R(Vertices, 'positions');
  if PositionRef = 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'No M3G positions');
  var Position := VM.GetObject(PositionRef);
  var Count := I(Position, 'vertices');
  var Data := VM.GetObject(R(Position, 'data'));
  var IndexData := VM.GetObject(R(Indices, 'indices'));
  var Strips := VM.GetObject(R(Indices, 'strips'));
  for var Value in IndexData.Elements do
    if (Value.AsInt < 0) or (Value.AsInt >= Count) then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G index outside vertex buffer');
  AppearanceRaster(VM, Appearance, Target);
  if R(Appearance, 'PolygonMode') <> 0 then
  begin
    var Mode := VM.GetObject(R(Appearance, 'PolygonMode'));
    Target.Culling := I(Mode, 'Culling', 160);
    Target.Winding := I(Mode, 'Winding', 168);
  end;
  var TextureMatrices: array[0..1] of TM3GMatrix;
  var Coordinates: array[0..1] of TJVMObject;
  var Components: array[0..1] of Integer;
  var TexScales: array[0..1] of Single;
  var Bias: array[0..1] of TM3GVector;
  for var UnitIndex := 0 to 1 do
  begin
    var TextureRef := R(Appearance, 'texture' + IntToStr(UnitIndex));
    if TextureRef = 0 then
      Continue;
    var Texture := VM.GetObject(TextureRef);
    var Image := M3GImageView(VM, R(Texture, 'image'));
    Target.Textures[UnitIndex].Pixels := Image.Pixels;
    Target.Textures[UnitIndex].Width := Image.Width;
    Target.Textures[UnitIndex].Height := Image.Height;
    Target.Textures[UnitIndex].Format := Image.Format;
    Target.Textures[UnitIndex].WrapS := I(Texture, 'WrappingS', 241);
    Target.Textures[UnitIndex].WrapT := I(Texture, 'WrappingT', 241);
    Target.Textures[UnitIndex].Blending := I(Texture, 'Blending', 227);
    Target.Textures[UnitIndex].BlendColor := UInt32(I(Texture, 'BlendColor'));
    Target.Textures[UnitIndex].Filter := I(Texture, 'ImageFilter', 210);
    TextureMatrices[UnitIndex] := M3GComposite(VM, TextureRef);
    var Key := 'tex' + IntToStr(UnitIndex);
    var CoordinateRef := R(Vertices, Key);
    Coordinates[UnitIndex] := nil;
    Components[UnitIndex] := 0;
    Bias[UnitIndex] := Default(TM3GVector);
    if CoordinateRef <> 0 then
    begin
      var Attribute := VM.GetObject(CoordinateRef);
      Coordinates[UnitIndex] := VM.GetObject(R(Attribute, 'data'));
      Components[UnitIndex] := I(Attribute, 'components');
      TexScales[UnitIndex] := F(Vertices, Key + '.scale', 1);
      for var K := 0 to 2 do
        Bias[UnitIndex][K] := F(Vertices, Key + '.bias' + IntToStr(K));
    end;
  end;
  var ColorData: TJVMObject := nil;
  var ColorComponents := 0;
  var ColorRef := R(Vertices, 'colors');
  if ColorRef <> 0 then
  begin
    var Attribute := VM.GetObject(ColorRef);
    ColorData := VM.GetObject(R(Attribute, 'data'));
    ColorComponents := I(Attribute, 'components');
    Target.InterpolateColors := True;
    var Polygon := R(Appearance, 'PolygonMode');
    if Polygon <> 0 then
      Target.InterpolateColors := I(VM.GetObject(Polygon), 'Shading', 165) = 165;
  end;
  var Inverse: TM3GMatrix;
  if not M3GInverse(Matrix(O, 'cameraMatrix'), Inverse) then
    VM.RaiseJava('java/lang/ArithmeticException', 'Singular M3G camera');
  var ModelView := M3GMultiply(Inverse, Model);
  var Lighting := M3GPrepareLighting(VM, O, R(Appearance, 'Material'), R(Appearance, 'PolygonMode'), Scope, ModelView, Inverse, Alpha);
  var NormalData: TJVMObject := nil;
  if Lighting.Enabled then
  begin
    var NormalRef := R(Vertices, 'normals');
    if NormalRef <> 0 then
      NormalData := VM.GetObject(R(VM.GetObject(NormalRef), 'data'));
    Target.InterpolateColors := True;
    var Polygon := R(Appearance, 'PolygonMode');
    if Polygon <> 0 then
      Target.InterpolateColors := I(VM.GetObject(Polygon), 'Shading', 165) = 165;
    Target.TwoSidedColors := Lighting.TwoSided;
  end;
  var Projection := M3GCameraProjection(VM, CameraRef);
  var Skin := M3GSkinMatrices(VM, SkinRef, Count);
  var Morph := M3GPrepareMorph(VM, MorphRef);
  var DefaultColorValue := UInt32(I(Vertices, 'color', -1));
  if Morph.Enabled then
    DefaultColorValue := Morph.Color;
  var Transformed: TArray<TM3GClipVertex>;
  SetLength(Transformed, Count);
  var Scale := F(Vertices, 'positions.scale', 1);
  for var N := 0 to Count - 1 do
  begin
    if VM.StopRequested then
      Exit;
    var V: TM3GVector;
    for var K := 0 to 2 do
      if Length(Morph.Attributes[0]) <> 0 then
        V[K] := Morph.Attributes[0][N * 3 + K] * Scale + F(Vertices, 'positions.bias' + IntToStr(K))
      else
        V[K] := Data.Elements[N * 3 + K].AsInt * Scale + F(Vertices, 'positions.bias' + IntToStr(K));
    V[3] := 1;
    if N < Length(Skin) then
      V := M3GTransformVector(Skin[N], V);
    V := M3GTransformVector(ModelView, V);
    Transformed[N][4] := V[2];
    Transformed[N][5] := V[3];
    var EyePosition := V;
    V := M3GTransformVector(Projection, V);
    for var K := 0 to 3 do
      Transformed[N][K] := V[K];
    for var UnitIndex := 0 to 1 do
      if Target.Textures[UnitIndex].Pixels <> nil then
      begin
        V := Default(TM3GVector);
        V[3] := 1;
        for var K := 0 to Components[UnitIndex] - 1 do
          if Length(Morph.Attributes[3 + UnitIndex]) <> 0 then
            V[K] := Morph.Attributes[3 + UnitIndex][N * Components[UnitIndex] + K] * TexScales[UnitIndex] + Bias[UnitIndex][K]
          else
            V[K] := Coordinates[UnitIndex].Elements[N * Components[UnitIndex] + K].AsInt * TexScales[UnitIndex] + Bias[UnitIndex][K];
        V := M3GTransformVector(TextureMatrices[UnitIndex], V);
        Transformed[N][6 + UnitIndex * 3] := V[0];
        Transformed[N][7 + UnitIndex * 3] := V[1];
        Transformed[N][8 + UnitIndex * 3] := V[3];
      end;
    if ColorData <> nil then
    begin
      Transformed[N][12] := 255 * Alpha;
      if ColorComponents = 4 then
        if Length(Morph.Attributes[2]) <> 0 then
          Transformed[N][12] := EnsureRange(Morph.Attributes[2][N * 4 + 3], 0.0, 255.0) * Alpha
        else
          Transformed[N][12] := (ColorData.Elements[N * 4 + 3].AsInt and 255) * Alpha;
      for var K := 0 to 2 do
        if Length(Morph.Attributes[2]) <> 0 then
          Transformed[N][13 + K] := EnsureRange(Morph.Attributes[2][N * ColorComponents + K], 0.0, 255.0)
        else
          Transformed[N][13 + K] := ColorData.Elements[N * ColorComponents + K].AsInt and 255;
    end;
    if Lighting.Enabled then
    begin
      var Normal := Default(TM3GLightVector);
      Normal[2] := 1;
      if NormalData <> nil then
        // The common signed-component divisor cancels during normalization.
        // The +1 bias is essential: an encoded zero is not exactly zero.
        for var K := 0 to 2 do
          if Length(Morph.Attributes[1]) <> 0 then
            Normal[K] := 2 * Morph.Attributes[1][N * 3 + K] + 1
          else
            Normal[K] := 2 * NormalData.Elements[N * 3 + K].AsInt + 1;
      if N < Length(Skin) then
      begin
        // Matrix-palette normal transformation: inverse transpose of the
        // blended skin matrix, followed by the ordinary model-view normal map.
        // Singular normal transformations are undefined; use the same identity
        // fallback as ordinary singular model-view lighting.
        var InverseSkin: TM3GMatrix;
        if not M3GInverse(Skin[N], InverseSkin) then
          InverseSkin := M3GIdentity;
        var Original := Normal;
        for var K := 0 to 2 do
        begin
          Normal[K] := 0;
          for var J := 0 to 2 do
            Normal[K] := Normal[K] + InverseSkin[J * 4 + K] * Original[J];
        end;
      end;
      var Source: TM3GLightColor;
      if ColorData <> nil then
        for var K := 0 to 3 do
          Source[K] := Transformed[N][12 + K]
      else
      begin
        var DefaultColor := DefaultColorValue;
        for var K := 0 to 3 do
          Source[K] := (DefaultColor shr ((3 - K) * 8)) and 255;
        Source[0] := Source[0] * Alpha;
      end;
      var Front, Back: TM3GLightColor;
      M3GLightVertex(Lighting, EyePosition, Normal, Source, Front, Back);
      for var K := 0 to 3 do
      begin
        Transformed[N][12 + K] := Front[K];
        Transformed[N][16 + K] := Back[K];
      end;
    end;
  end;
  var Offset := 0;
  var Color := DefaultColorValue;
  Color := (Color and $FFFFFF) or (UInt32(Trunc((Color shr 24) * Alpha + 0.5)) shl 24);
  for var Strip in Strips.Elements do
  begin
    for var N := 0 to Strip.AsInt - 3 do
    begin
      if VM.StopRequested then
        Exit;
      var A := IndexData.Elements[Offset + N + (N and 1)].AsInt;
      var B := IndexData.Elements[Offset + N + 1 - (N and 1)].AsInt;
      var C := IndexData.Elements[Offset + N + 2].AsInt;
      var TriangleColor := Color;
      if ((ColorData <> nil) or Lighting.Enabled) and not Target.InterpolateColors then
      begin
        TriangleColor := 0;
        for var K := 0 to 3 do
          TriangleColor := TriangleColor or (UInt32(Trunc(Transformed[C][12 + K] + 0.5)) shl ((3 - K) * 8));
      end;
      M3GRasterTriangle(VM, Target, Pixels, Transformed[A], Transformed[B], Transformed[C], TriangleColor);
    end;
    Inc(Offset, Strip.AsInt);
  end;
end;

procedure ResetLights(O: TJVMObject);
begin
  for var N := 0 to I(O, 'lightCount') - 1 do
    PR(O, 'light' + IntToStr(N), 0);
  PI(O, 'lightCount', 0);
end;

procedure StoreLight(O: TJVMObject; Index, Ref: Integer; const Transform: TM3GMatrix);
begin
  PR(O, 'light' + IntToStr(Index), Ref);
  PutMatrix(O, 'lightMatrix' + IntToStr(Index) + '.', Transform);
end;

procedure DrawScene(VM: TJVM; O: TJVMObject; Root: Integer; const RootMatrix: TM3GMatrix; Retained: Boolean; var Pixels: TArray<UInt32>; Width, Height: Integer);
type
  TNode = record
    Ref: Integer;
    Model: TM3GMatrix;
    Alpha: Double;
  end;

  TItem = record
    Vertices, Indices, Appearance, Scope, Layer, Blended, Order, Sprite, Skin, Morph: Integer;
    Model: TM3GMatrix;
    Alpha: Double;
  end;
begin
  var RootObject := VM.GetObject(Root);
  var Target := Surface(VM, O, Width, Height);
  if Retained then
  begin
    var CameraRef := R(RootObject, 'activeCamera');
    if CameraRef = 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'World has no active camera');
    var CameraMatrix := M3GIdentity;
    var Ancestor := CameraRef;
    var Seen := TDictionary<Integer, Boolean>.Create;
    try
      while Ancestor <> Root do
      begin
        if Ancestor = 0 then
          VM.RaiseJava('java/lang/IllegalStateException', 'Active camera is outside World');
        if Seen.ContainsKey(Ancestor) then
          raise EJVMError.Create('Cyclic M3G camera path');
        Seen.Add(Ancestor, True);
        CameraMatrix := M3GMultiply(M3GComposite(VM, Ancestor), CameraMatrix);
        Ancestor := R(VM.GetObject(Ancestor), 'parent');
      end;
    finally
      Seen.Free;
    end;
    var Inverse: TM3GMatrix;
    if not M3GInverse(CameraMatrix, Inverse) then
      VM.RaiseJava('java/lang/ArithmeticException', 'Singular World camera');
    var Background := R(RootObject, 'background');
    if Background <> 0 then
    begin
      var Image := R(VM.GetObject(Background), 'image');
      if Image <> 0 then
      begin
        var Format := 99;
        if Target.PreserveAlpha then
          Format := 100;
        if M3GImageView(VM, Image).Format <> Format then
          VM.RaiseJava('java/lang/IllegalStateException', 'World background/target format mismatch');
      end;
    end;
    PR(O, 'camera', CameraRef);
    PutMatrix(O, 'cameraMatrix', CameraMatrix);
    ResetLights(O);
    M3GClearBackground(VM, Background, Target, Pixels);
  end
  else
  begin
    if not VM.IsAssignable(RootObject.ClassName, 'javax/microedition/m3g/Group') and
      not VM.IsAssignable(RootObject.ClassName, 'javax/microedition/m3g/Mesh') and
      not VM.IsAssignable(RootObject.ClassName, 'javax/microedition/m3g/Sprite3D') then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G render node type');
    if R(O, 'camera') = 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'No M3G camera');
  end;
  var Stack := TList<TNode>.Create;
  var Items := TList<TItem>.Create;
  try
    var Entry: TNode;
    Entry.Ref := Root;
    Entry.Model := RootMatrix;
    Entry.Alpha := 1;
    Stack.Add(Entry);
    while Stack.Count <> 0 do
    begin
      if VM.StopRequested then
        Exit;
      Entry := Stack.Last;
      Stack.Delete(Stack.Count - 1);
      var Node := VM.GetObject(Entry.Ref);
      if I(Node, 'render', 1) = 0 then
        Continue;
      Entry.Alpha := Entry.Alpha * F(Node, 'alpha', 1);
      if VM.IsAssignable(Node.ClassName, 'javax/microedition/m3g/Light') then
      begin
        if Retained then
        begin
          var Index := I(O, 'lightCount');
          StoreLight(O, Index, Entry.Ref, Entry.Model);
          PI(O, 'lightCount', Index + 1);
        end;
      end
      else if VM.IsAssignable(Node.ClassName, 'javax/microedition/m3g/Mesh') then
      begin
        // Group scopes are local; only the mesh and camera masks decide visibility.
        if (I(Node, 'scope', -1) and I(VM.GetObject(R(O, 'camera')), 'scope', -1)) <> 0 then
          for var Submesh := 0 to I(Node, 'submeshCount') - 1 do
          begin
            var Appearance := R(Node, 'appearance' + IntToStr(Submesh));
            if Appearance = 0 then
              Continue;
            var Item := Default(TItem);
            Item.Vertices := R(Node, 'vertices');
            Item.Indices := R(Node, 'submesh' + IntToStr(Submesh));
            if VM.IsAssignable(Node.ClassName, 'javax/microedition/m3g/SkinnedMesh') then
              Item.Skin := Entry.Ref;
            if VM.IsAssignable(Node.ClassName, 'javax/microedition/m3g/MorphingMesh') then
              Item.Morph := Entry.Ref;
            Item.Appearance := Appearance;
            Item.Scope := I(Node, 'scope', -1);
            Item.Alpha := Entry.Alpha;
            Item.Model := Entry.Model;
            var A := VM.GetObject(Appearance);
            Item.Layer := I(A, 'layer');
            Item.Blended := 0;
            var Mode := R(A, 'CompositingMode');
            if (Mode <> 0) and (I(VM.GetObject(Mode), 'Blending', 68) <> 68) then
              Item.Blended := 1;
            Item.Order := Items.Count;
            Items.Add(Item);
          end;
      end
      else if VM.IsAssignable(Node.ClassName, 'javax/microedition/m3g/Sprite3D') then
      begin
        var Appearance := R(Node, 'appearance');
        if (Appearance = 0) or ((I(Node, 'scope', -1) and I(VM.GetObject(R(O, 'camera')), 'scope', -1)) = 0) then
          Continue;
        var Item := Default(TItem);
        Item.Sprite := Entry.Ref;
        Item.Appearance := Appearance;
        Item.Alpha := Entry.Alpha;
        Item.Model := Entry.Model;
        var A := VM.GetObject(Appearance);
        Item.Layer := I(A, 'layer');
        var Mode := R(A, 'CompositingMode');
        if (Mode <> 0) and (I(VM.GetObject(Mode), 'Blending', 68) <> 68) then
          Item.Blended := 1;
        Item.Order := Items.Count;
        Items.Add(Item);
      end;
      var Children := M3GSceneReferences(VM, Node);
      for var K := High(Children) downto 0 do
      begin
        var Child: TNode;
        Child.Ref := Children[K];
        Child.Alpha := Entry.Alpha;
        Child.Model := M3GMultiply(Entry.Model, M3GComposite(VM, Child.Ref));
        Stack.Add(Child);
      end;
    end;
    Items.Sort(TComparer<TItem>.Construct(
      function(const A, B: TItem): Integer
      begin
        Result := A.Layer - B.Layer;
        if Result = 0 then
          Result := A.Blended - B.Blended;
        if Result = 0 then
          Result := A.Order - B.Order;
      end));
    for var Item in Items do
    begin
      if VM.StopRequested then
        Exit;
      if Item.Sprite = 0 then
        Draw(VM, O, Item.Vertices, Item.Indices, Item.Appearance, Item.Model, Item.Scope, Item.Alpha, Pixels, Width, Height, Item.Skin, Item.Morph)
      else
      begin
        var SpriteTarget := Surface(VM, O, Width, Height);
        AppearanceRaster(VM, VM.GetObject(Item.Appearance), SpriteTarget);
        var Inverse: TM3GMatrix;
        if not M3GInverse(Matrix(O, 'cameraMatrix'), Inverse) then
          VM.RaiseJava('java/lang/ArithmeticException', 'Singular M3G camera');
        M3GDrawSprite(VM, Item.Sprite, M3GMultiply(Inverse, Item.Model), M3GCameraProjection(VM, R(O, 'camera')), SpriteTarget, Item.Alpha, Pixels);
      end;
    end;
  finally
    Items.Free;
    Stack.Free;
  end;
end;

function InvokeM3GGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;
begin
  Result := Default(TJVMValue);
  var N := Method.Name;
  if N = 'getInstance' then
  begin
    var Field := Method.Owner.Fields[0];
    if Field.Value.AsRef = 0 then
      Field.Value := TJVMValue.Ref(VM.NewObject(Name));
    Exit(Field.Value);
  end;
  var O := VM.GetObject(Args[0].AsRef);
  if N = 'resetLights' then
  begin
    ResetLights(O);
    Exit;
  end;
  if N = 'getLightCount' then
    Exit(TJVMValue.Int(I(O, 'lightCount')));
  if (N = 'addLight') or (N = 'setLight') or (N = 'getLight') then
  begin
    var Count := I(O, 'lightCount');
    var Index := Count;
    if N <> 'addLight' then
    begin
      Index := Args[1].AsInt;
      if (Index < 0) or (Index >= Count) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G light index');
    end;
    if N = 'getLight' then
    begin
      if Args[2].AsRef <> 0 then
        M3GPutMatrix(VM, Args[2].AsRef, Matrix(O, 'lightMatrix' + IntToStr(Index) + '.'));
      Exit(TJVMValue.Ref(R(O, 'light' + IntToStr(Index))));
    end;
    var RefArg := 1;
    if N = 'setLight' then
      RefArg := 2;
    var Ref := Args[RefArg].AsRef;
    if N = 'addLight' then
      VM.GetObject(Ref);
    var M := M3GIdentity;
    if Args[RefArg + 1].AsRef <> 0 then
      M := M3GGetMatrix(VM, Args[RefArg + 1].AsRef);
    StoreLight(O, Index, Ref, M);
    if N = 'addLight' then
      PI(O, 'lightCount', Count + 1);
    if N = 'addLight' then
      Result := TJVMValue.Int(Index);
    Exit;
  end;
  if N = 'getTarget' then
    Exit(TJVMValue.Ref(R(O, 'target')));
  if N = 'getHints' then
    Exit(TJVMValue.Int(I(O, 'hints')));
  if N = 'isDepthBufferEnabled' then
    Exit(TJVMValue.Int(I(O, 'depthEnabled')));
  if N = 'releaseTarget' then
  begin
    PR(O, 'target', 0);
    PR(O, 'depth', 0);
    Exit;
  end;
  if N = 'bindTarget' then
  begin
    var TargetRef := Args[1].AsRef;
    var Target := VM.GetObject(TargetRef);
    if R(O, 'target') <> 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'M3G target already bound');
    var V: TJVMValue;
    if VM.IsAssignable(Target.ClassName, 'javax/microedition/m3g/Image2D') then
    begin
      var Image := M3GImageView(VM, TargetRef);
      if not Image.Mutable or not (Image.Format in [99, 100]) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G target image mutability/format');
      Width := Image.Width;
      Height := Image.Height;
    end
    else if not VM.IsAssignable(Target.ClassName, 'javax/microedition/lcdui/Graphics') then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G target type')
    else if Target.Fields.TryGetValue('$target', V) then
    begin
      var Image := J2MEImageView(VM, V.AsRef);
      Width := Image.Width;
      Height := Image.Height;
    end;
    if (Width > 1024) or (Height > 1024) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G target dimensions');
    var Hints := 0;
    var Depth := 1;
    if Length(Args) = 4 then
    begin
      Depth := Args[2].AsInt;
      Hints := Args[3].AsInt;
    end;
    if (Hints and not 30) <> 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G hints');
    var DepthRef := 0;
    if Depth <> 0 then
    begin
      // Reuse storage across frames. JVM GC thresholds count objects, so a
      // fresh large float array on every bind would accumulate excessive memory
      // before a collection. Release still discards the active depth contents.
      DepthRef := R(O, 'depthCache');
      if (DepthRef = 0) or (Length(VM.GetObject(DepthRef).Elements) <> Width * Height) then
      begin
        DepthRef := VM.NewArray('[F', Width * Height);
        PR(O, 'depthCache', DepthRef);
      end;
      var Data := VM.GetObject(DepthRef);
      for var K := 0 to High(Data.Elements) do
        Data.Elements[K] := TJVMValue.Float(1);
    end;
    var TX := G(Target, 'tx');
    var TY := G(Target, 'ty');
    PI(O, 'tx', TX);
    PI(O, 'ty', TY);
    var L := EnsureRange(G(Target, 'clipL'), 0, Width);
    var T := EnsureRange(G(Target, 'clipT'), 0, Height);
    var Right := EnsureRange(G(Target, 'clipR', Width), L, Width);
    var Bottom := EnsureRange(G(Target, 'clipB', Height), T, Height);
    PI(O, 'clipL', L);
    PI(O, 'clipT', T);
    PI(O, 'clipR', Right);
    PI(O, 'clipB', Bottom);
    PI(O, 'viewX', L - TX);
    PI(O, 'viewY', T - TY);
    PI(O, 'viewWidth', Right - L);
    PI(O, 'viewHeight', Bottom - T);
    PI(O, 'depthEnabled', Depth);
    PI(O, 'hints', Hints);
    PR(O, 'depth', DepthRef);
    PR(O, 'target', TargetRef);
    Exit;
  end;
  if N = 'setViewport' then
  begin
    var W := Args[3].AsInt;
    var H := Args[4].AsInt;
    if (W <= 0) or (H <= 0) or (W > 1024) or (H > 1024) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G viewport');
    PI(O, 'viewX', Args[1].AsInt);
    PI(O, 'viewY', Args[2].AsInt);
    PI(O, 'viewWidth', W);
    PI(O, 'viewHeight', H);
    Exit;
  end;
  if N.StartsWith('getViewport') then
    Exit(TJVMValue.Int(I(O, 'view' + Copy(N, 12, MaxInt))));
  if N = 'setDepthRange' then
  begin
    var A := Args[1].AsFloat;
    var B := Args[2].AsFloat;
    if not ((A >= 0) and (A <= 1) and (B >= 0) and (B <= 1)) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G depth range');
    O.Fields.AddOrSetValue(P + 'near', Args[1]);
    O.Fields.AddOrSetValue(P + 'far', Args[2]);
    Exit;
  end;
  if N = 'getDepthRangeNear' then
    Exit(TJVMValue.Float(F(O, 'near')));
  if N = 'getDepthRangeFar' then
    Exit(TJVMValue.Float(F(O, 'far', 1)));
  if N = 'setCamera' then
  begin
    var M := M3GIdentity;
    if Args[2].AsRef <> 0 then
      M := M3GGetMatrix(VM, Args[2].AsRef);
    var Inverse: TM3GMatrix;
    if not M3GInverse(M, Inverse) then
      VM.RaiseJava('java/lang/ArithmeticException', 'Singular M3G camera');
    PutMatrix(O, 'cameraMatrix', M);
    PR(O, 'camera', Args[1].AsRef);
    Exit;
  end;
  if N = 'getCamera' then
  begin
    if Args[1].AsRef <> 0 then
      M3GPutMatrix(VM, Args[1].AsRef, Matrix(O, 'cameraMatrix'));
    Exit(TJVMValue.Ref(R(O, 'camera')));
  end;
  if N = 'clear' then
  begin
    var Target := Surface(VM, O, Width, Height);
    M3GClearBackground(VM, Args[1].AsRef, Target, Pixels);
    Exit;
  end;
  if N = 'render' then
  begin
    var Model := M3GIdentity;
    if Length(Args) = 2 then
      DrawScene(VM, O, Args[1].AsRef, Model, True, Pixels, Width, Height)
    else if Length(Args) = 3 then
    begin
      if Args[2].AsRef <> 0 then
        Model := M3GGetMatrix(VM, Args[2].AsRef);
      DrawScene(VM, O, Args[1].AsRef, Model, False, Pixels, Width, Height);
    end
    else
    begin
      if Args[4].AsRef <> 0 then
        Model := M3GGetMatrix(VM, Args[4].AsRef);
      var Scope := -1;
      if Length(Args) = 6 then
        Scope := Args[5].AsInt;
      Draw(VM, O, Args[1].AsRef, Args[2].AsRef, Args[3].AsRef, Model, Scope, 1, Pixels, Width, Height);
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

end.

