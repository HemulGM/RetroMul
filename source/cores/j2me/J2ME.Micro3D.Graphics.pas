unit J2ME.Micro3D.Graphics;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEMicro3DGraphics(VM: TJVM);

function InvokeJ2MEMicro3DGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;

const
  Micro3DGraphicsName = 'com/mascotcapsule/micro3d/v3/Graphics3D';

implementation

uses
  System.Math, System.SysUtils, Java.Classes, J2ME.Image, J2ME.M3G.Math,
  J2ME.M3G.Raster, J2ME.Micro3D.Action;

const
  Prefix = 'com/mascotcapsule/micro3d/v3/';
  FigureName = Prefix + 'Figure';
  TextureName = Prefix + 'Texture';
  LayoutName = Prefix + 'FigureLayout';
  EffectName = Prefix + 'Effect3D';
  LightName = Prefix + 'Light';
  VectorName = Prefix + 'Vector3D';
  AffineName = Prefix + 'AffineTrans';
  GraphicsType = 'Ljavax/microedition/lcdui/Graphics;';
  TextureType = 'L' + TextureName + ';';
  LayoutArgs = 'IIL' + LayoutName + ';L' + EffectName + ';';
  MaxTriangles = 32768;
  VertexStride = 7;
  TriangleStride = 3 * VertexStride + 3;
  FaceStride = 17;
  BoneStride = 14;
  CommandVersion = $FE000001;
  ClipPresent = Int64(1) shl 45;

type
  TProjection = record
    Transform: TM3GMatrix;
    CenterX, CenterY, ScaleX, ScaleY, NearZ, FarZ: Double;
    Perspective: Boolean;
    function Project(X, Y, Z: Double): TM3GClipVertex;
  end;

  TView = record
    Transform: TM3GMatrix;
    CenterX, CenterY, Kind, SizeX, SizeY, NearZ, FarZ: Integer;
  end;

  TLighting = record
    Enabled, Toon: Boolean;
    Direction: TM3GDoubleVector;
    Ambient, Parallel, Threshold, High, Low: Integer;
    function Shade(const Normal: TM3GDoubleVector; const Transform: TM3GMatrix): Double;
  end;

  TDrawQueue = record
    Data, Textures: TJVMObject;
    Count: Integer;
    Clip: Int64;
    procedure Push(const A, B, C: TM3GClipVertex; TextureRef: Integer; Color: UInt32; Flags: Integer; Semitransparent: Boolean);
  end;

function Key(const Owner, Field, Kind: string): string;
begin
  Result := Owner + '.$' + Field + ':' + Kind;
end;

function I32(O: TJVMObject; const Owner, Field: string): Integer;
begin
  Result := O.Fields[Key(Owner, Field, 'I')].AsInt;
end;

function Ref(O: TJVMObject; const Owner, Field, Kind: string): Integer;
begin
  Result := O.Fields[Key(Owner, Field, Kind)].AsRef;
end;

procedure PutRef(O: TJVMObject; const Field, Kind: string; Value: Integer);
begin
  O.Fields[Key(Micro3DGraphicsName, Field, Kind)] := TJVMValue.Ref(Value);
end;

procedure PutInt(O: TJVMObject; const Field: string; Value: Integer);
begin
  O.Fields[Key(Micro3DGraphicsName, Field, 'I')] := TJVMValue.Int(Value);
end;

function GI(O: TJVMObject; const Field: string; Fallback: Integer = 0): Integer;
begin
  var Value: TJVMValue;
  if O.Fields.TryGetValue('$' + Field, Value) then
    Exit(Value.AsInt);
  Result := Fallback;
end;

function Arg(O: TJVMObject; Index: Integer): Integer;
begin
  Result := O.ElementValues[Index].AsInt;
end;

procedure InstallJ2MEMicro3DGraphics(VM: TJVM);

  procedure Constant(B: TJavaClassBuilder; const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  var B := TJavaClassBuilder.Create(Micro3DGraphicsName, 'java/lang/Object');
  try
    B.Field('$target', GraphicsType, JVM_ACC_PRIVATE);
    B.Field('$depth', '[F', JVM_ACC_PRIVATE);
    B.Field('$draws', '[D', JVM_ACC_PRIVATE);
    B.Field('$textures', '[' + TextureType, JVM_ACC_PRIVATE);
    for var Field in ['$count', '$width', '$height', '$left', '$top', '$right', '$bottom', '$tx', '$ty'] do
      B.Field(Field, 'I', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('dispose', '()V');
    B.JavaClass.AddNative('bind', '(' + GraphicsType + ')V');
    B.JavaClass.AddNative('release', '(' + GraphicsType + ')V');
    B.JavaClass.AddNative('flush', '()V');
    B.JavaClass.AddNative('renderFigure', '(L' + FigureName + ';' + LayoutArgs + ')V');
    B.JavaClass.AddNative('drawFigure', '(L' + FigureName + ';' + LayoutArgs + ')V');
    B.JavaClass.AddNative('drawCommandList', '(' + TextureType + LayoutArgs + '[I)V');
    B.JavaClass.AddNative('drawCommandList', '([' + TextureType + LayoutArgs + '[I)V');
    B.JavaClass.AddNative('renderPrimitives', '(' + TextureType + LayoutArgs + 'II[I[I[I[I)V');
    Constant(B, 'COMMAND_AFFINE_INDEX', Integer($87000000));
    Constant(B, 'COMMAND_AMBIENT_LIGHT', Integer($A0000000));
    Constant(B, 'COMMAND_ATTRIBUTE', Integer($83000000));
    Constant(B, 'COMMAND_CENTER', Integer($85000000));
    Constant(B, 'COMMAND_CLIP', Integer($84000000));
    Constant(B, 'COMMAND_DIRECTION_LIGHT', Integer($A1000000));
    Constant(B, 'COMMAND_END', Integer($80000000));
    Constant(B, 'COMMAND_FLUSH', Integer($82000000));
    Constant(B, 'COMMAND_LIST_VERSION_1_0', Integer($FE000001));
    Constant(B, 'COMMAND_NOP', Integer($81000000));
    Constant(B, 'COMMAND_PARALLEL_SCALE', Integer($90000000));
    Constant(B, 'COMMAND_PARALLEL_SIZE', Integer($91000000));
    Constant(B, 'COMMAND_PERSPECTIVE_FOV', Integer($92000000));
    Constant(B, 'COMMAND_PERSPECTIVE_WH', Integer($93000000));
    Constant(B, 'COMMAND_TEXTURE_INDEX', Integer($86000000));
    Constant(B, 'COMMAND_THRESHOLD', Integer($AF000000));
    Constant(B, 'ENV_ATTR_LIGHTING', $1);
    Constant(B, 'ENV_ATTR_SEMI_TRANSPARENT', $8);
    Constant(B, 'ENV_ATTR_SPHERE_MAP', $2);
    Constant(B, 'ENV_ATTR_TOON_SHADING', $4);
    Constant(B, 'PATTR_BLEND_ADD', $40);
    Constant(B, 'PATTR_BLEND_HALF', $20);
    Constant(B, 'PATTR_BLEND_NORMAL', $0);
    Constant(B, 'PATTR_BLEND_SUB', $60);
    Constant(B, 'PATTR_COLORKEY', $10);
    Constant(B, 'PATTR_LIGHTING', $1);
    Constant(B, 'PATTR_SPHERE_MAP', $2);
    Constant(B, 'PDATA_COLOR_NONE', $0);
    Constant(B, 'PDATA_COLOR_PER_COMMAND', $400);
    Constant(B, 'PDATA_COLOR_PER_FACE', $800);
    Constant(B, 'PDATA_NORMAL_NONE', $0);
    Constant(B, 'PDATA_NORMAL_PER_FACE', $200);
    Constant(B, 'PDATA_NORMAL_PER_VERTEX', $300);
    Constant(B, 'PDATA_POINT_SPRITE_PARAMS_PER_CMD', $1000);
    Constant(B, 'PDATA_POINT_SPRITE_PARAMS_PER_FACE', $2000);
    Constant(B, 'PDATA_POINT_SPRITE_PARAMS_PER_VERTEX', $3000);
    Constant(B, 'PDATA_TEXURE_COORD', $3000);
    Constant(B, 'PDATA_TEXURE_COORD_NONE', $0);
    Constant(B, 'POINT_SPRITE_LOCAL_SIZE', $0);
    Constant(B, 'POINT_SPRITE_NO_PERS', $2);
    Constant(B, 'POINT_SPRITE_PERSPECTIVE', $0);
    Constant(B, 'POINT_SPRITE_PIXEL_SIZE', $1);
    Constant(B, 'PRIMITVE_LINES', $2000000);
    Constant(B, 'PRIMITVE_POINT_SPRITES', $5000000);
    Constant(B, 'PRIMITVE_POINTS', $1000000);
    Constant(B, 'PRIMITVE_QUADS', $4000000);
    Constant(B, 'PRIMITVE_TRIANGLES', $3000000);
    for var Method in B.JavaClass.Methods do
      if Method.Name <> '<init>' then
        Method.Access := Method.Access or JVM_ACC_FINAL;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function Vector4(X, Y, Z, W: Double): TM3GDoubleVector;
begin
  Result[0] := X;
  Result[1] := Y;
  Result[2] := Z;
  Result[3] := W;
end;

function TProjection.Project(X, Y, Z: Double): TM3GClipVertex;
begin
  var local := M3GDoubleTransform(Transform, Vector4(X, Y, Z, 1));
  Result := Default(TM3GClipVertex);
  var W: Double := 1;
  if Perspective then
  begin
    W := local[2];
    Result[2] := (FarZ + NearZ) / (FarZ - NearZ) * W - 2 * FarZ * NearZ / (FarZ - NearZ);
  end
  else
    Result[2] := 2 * (local[2] - NearZ) / (FarZ - NearZ) - 1;
  Result[0] := local[0] * ScaleX + CenterX * W;
  Result[1] := -local[1] * ScaleY + CenterY * W;
  Result[3] := W;
  Result[8] := 1;
end;

function ReadTransform(Matrix: TJVMObject): TM3GMatrix;
const
  Fields: array[0..11] of string =
    ('m00', 'm01', 'm02', 'm03', 'm10', 'm11', 'm12', 'm13', 'm20', 'm21', 'm22', 'm23');
begin
  Result := M3GIdentity;
  for var Col := 0 to 11 do
  begin
    var Value := Matrix.Fields[AffineName + '.' + Fields[Col] + ':I'].AsInt;
    if (Col and 3) = 3 then
      Result[Col] := Value
    else
      Result[Col] := Value / 4096;
  end;
end;

function ReadView(VM: TJVM; Layout: TJVMObject): TView;
begin
  Result := Default(TView);
  Result.Transform := ReadTransform(VM.GetObject(Ref(Layout, LayoutName, 'transform', 'L' + AffineName + ';')));
  Result.CenterX := I32(Layout, LayoutName, 'centerX');
  Result.CenterY := I32(Layout, LayoutName, 'centerY');
  Result.Kind := I32(Layout, LayoutName, 'projection');
  case Result.Kind of
    0:
      begin
        Result.SizeX := I32(Layout, LayoutName, 'scaleX');
        Result.SizeY := I32(Layout, LayoutName, 'scaleY');
      end;
    1:
      begin
        Result.SizeX := I32(Layout, LayoutName, 'parallelWidth');
        Result.SizeY := I32(Layout, LayoutName, 'parallelHeight');
      end;
    2:
      Result.SizeX := I32(Layout, LayoutName, 'angle');
    3:
      begin
        Result.SizeX := I32(Layout, LayoutName, 'width');
        Result.SizeY := I32(Layout, LayoutName, 'height');
      end;
  end;
  Result.NearZ := I32(Layout, LayoutName, 'near');
  Result.FarZ := I32(Layout, LayoutName, 'far');
end;

function SetupProjection(VM: TJVM; O: TJVMObject; const View: TView; X, Y: Integer): TProjection;
begin
  var W := I32(O, Micro3DGraphicsName, 'width');
  var H := I32(O, Micro3DGraphicsName, 'height');
  var ViewW := I32(O, Micro3DGraphicsName, 'right') - I32(O, Micro3DGraphicsName, 'left');
  var ViewH := I32(O, Micro3DGraphicsName, 'bottom') - I32(O, Micro3DGraphicsName, 'top');
  Result.Transform := View.Transform;
  Result.CenterX := 2 * (Double(X) + I32(O, Micro3DGraphicsName, 'tx') + View.CenterX) / W - 1;
  Result.CenterY := 1 - 2 * (Double(Y) + I32(O, Micro3DGraphicsName, 'ty') + View.CenterY) / H;
  Result.Perspective := View.Kind >= 2;
  // Parallel projection uses the full signed Micro3D screen Z range.
  Result.NearZ := -32768;
  Result.FarZ := 32767;
  case View.Kind of
    0:
      begin
        Result.ScaleX := View.SizeX / (2048 * W);
        Result.ScaleY := View.SizeY / (2048 * H);
      end;
    1:
      begin
        Result.ScaleX := 2.0 * ViewW / (W * Double(Max(1, View.SizeX)));
        Result.ScaleY := 2.0 * ViewH / (H * Double(Max(1, View.SizeY)));
      end;
    2, 3:
      begin
        Result.NearZ := View.NearZ;
        Result.FarZ := View.FarZ;
        if View.Kind = 2 then
        begin
          var Focus := ViewW / Tan(View.SizeX * Pi / 4096);
          Result.ScaleX := Focus / W;
          Result.ScaleY := Focus / H;
        end
        else
        begin
          Result.ScaleX := 8192 * Result.NearZ * ViewW / (W * Double(Max(1, View.SizeX)));
          Result.ScaleY := 8192 * Result.NearZ * ViewH / (H * Double(Max(1, View.SizeY)));
        end;
      end;
  else
    VM.RaiseJava('java/lang/IllegalStateException', 'Invalid Micro3D projection');
  end;
end;

procedure TDrawQueue.Push(const A, B, C: TM3GClipVertex; TextureRef: Integer; Color: UInt32; Flags: Integer; Semitransparent: Boolean);
var
  Offset: Integer;

  procedure WriteVertex(const V: TM3GClipVertex);
  begin
    for var I := 0 to 3 do
      Data.ElementValues[Offset + I] := TJVMValue.Double(V[I]);
    Data.ElementValues[Offset + 4] := TJVMValue.Double(V[6]);
    Data.ElementValues[Offset + 5] := TJVMValue.Double(V[7]);
    Data.ElementValues[Offset + 6] := TJVMValue.Double(V[13]);
    Inc(Offset, VertexStride);
  end;

begin
  Offset := Count * TriangleStride;
  WriteVertex(A);
  WriteVertex(B);
  WriteVertex(C);
  Data.ElementValues[Offset] := TJVMValue.Double(Color);
  Data.ElementValues[Offset + 1] := TJVMValue.Double(Flags);
  Data.ElementValues[Offset + 2] := TJVMValue.Double(Clip or Ord(Semitransparent));
  Textures.ElementValues[Count] := TJVMValue.Ref(TextureRef);
  Inc(Count);
end;

function ReserveQueue(VM: TJVM; O: TJVMObject; Added: Integer): TDrawQueue;
begin
  Result.Clip := 0;
  Result.Count := I32(O, Micro3DGraphicsName, 'count');
  var Required := Result.Count + Added;
  if Required > MaxTriangles then
    VM.RaiseJava('java/lang/RuntimeException', 'Micro3D triangle queue limit');
  var DataRef := Ref(O, Micro3DGraphicsName, 'draws', '[D');
  var TextureRef := Ref(O, Micro3DGraphicsName, 'textures', '[' + TextureType);
  if (DataRef = 0) or (VM.GetObject(TextureRef).ElementCount < Required) then
  begin
    var Capacity := Max(64, Required);
    if DataRef <> 0 then
      Capacity := Min(MaxTriangles, Max(Capacity, VM.GetObject(TextureRef).ElementCount * 2));
    var NewData := VM.NewArray('[D', Capacity * TriangleStride);
    var NewTextures := VM.NewArray('[' + TextureType, Capacity);
    Result.Data := VM.GetObject(NewData);
    Result.Textures := VM.GetObject(NewTextures);
    if Result.Count <> 0 then
    begin
      var OldData := VM.GetObject(DataRef);
      var OldTextures := VM.GetObject(TextureRef);
      for var I := 0 to Result.Count * TriangleStride - 1 do
        Result.Data.ElementValues[I] := OldData.ElementValues[I];
      for var I := 0 to Result.Count - 1 do
        Result.Textures.ElementValues[I] := OldTextures.ElementValues[I];
    end;
    PutRef(O, 'draws', '[D', NewData);
    PutRef(O, 'textures', '[' + TextureType, NewTextures);
  end
  else
  begin
    Result.Data := VM.GetObject(DataRef);
    Result.Textures := VM.GetObject(TextureRef);
  end;
end;

procedure Flush(VM: TJVM; O, Graphics: TJVMObject; var Pixels: TArray<UInt32>; First: Integer = 0);
var
  Offset: Integer;

  function ReadVertex(Data: TJVMObject; Color: UInt32; Alpha: Integer): TM3GClipVertex;
  begin
    Result := Default(TM3GClipVertex);
    for var I := 0 to 3 do
      Result[I] := Data.ElementValues[Offset + I].AsDouble;
    Result[6] := Data.ElementValues[Offset + 4].AsDouble;
    Result[7] := Data.ElementValues[Offset + 5].AsDouble;
    Result[8] := 1;
    Result[12] := Alpha;
    var Shade := Data.ElementValues[Offset + 6].AsDouble;
    for var I := 0 to 2 do
      Result[13 + I] := ((Color shr ((2 - I) * 8)) and 255) * Shade;
    Inc(Offset, VertexStride);
  end;

begin
  var Count := I32(O, Micro3DGraphicsName, 'count');
  if Count <= First then
    Exit;
  var Data := VM.GetObject(Ref(O, Micro3DGraphicsName, 'draws', '[D'));
  var Textures := VM.GetObject(Ref(O, Micro3DGraphicsName, 'textures', '[' + TextureType));
  var Target := Default(TM3GRasterTarget);
  Target.Width := I32(O, Micro3DGraphicsName, 'width');
  Target.Height := I32(O, Micro3DGraphicsName, 'height');
  Target.ViewWidth := Target.Width;
  Target.ViewHeight := Target.Height;
  var BaseLeft := I32(O, Micro3DGraphicsName, 'left');
  var BaseTop := I32(O, Micro3DGraphicsName, 'top');
  var BaseRight := I32(O, Micro3DGraphicsName, 'right');
  var BaseBottom := I32(O, Micro3DGraphicsName, 'bottom');
  Target.Depth := VM.GetObject(Ref(O, Micro3DGraphicsName, 'depth', '[F'));
  Target.DepthEnabled := True;
  Target.DepthTest := True;
  Target.ColorWrite := True;
  Target.AlphaWrite := True;
  Target.FarDepth := 1;
  Target.InterpolateColors := True;
  var Image: TJVMValue;
  if Graphics.Fields.TryGetValue('$target', Image) then
    Target.Pixels := J2MEImageView(VM, Image.AsRef).Pixels;
  if (Target.Pixels = nil) and (Length(Pixels) < Target.Width * Target.Height) then
    VM.RaiseJava('java/lang/IllegalStateException', 'Micro3D target is no longer available');
  try
    for var I := First to Count - 1 do
    begin
      if (I and 63 = 0) and VM.StopRequested then
        Break;
      Offset := I * TriangleStride;
      var Style := Offset + 3 * VertexStride;
      var Color := UInt32(Trunc(Data.ElementValues[Style].AsDouble));
      var Flags := Trunc(Data.ElementValues[Style + 1].AsDouble);
      var Blend := 0;
      // The low bit is the original snapshot value. Optional clip coordinates
      // occupy four 11-bit fields, all exactly representable as doubles.
      var DrawState := Trunc(Data.ElementValues[Style + 2].AsDouble);
      if (DrawState and 1) <> 0 then
        Blend := (Flags shr 1) and 3;
      Target.Left := BaseLeft;
      Target.Top := BaseTop;
      Target.Right := BaseRight;
      Target.Bottom := BaseBottom;
      if (DrawState and ClipPresent) <> 0 then
      begin
        Target.Left := Max(Target.Left, Integer((DrawState shr 1) and $7FF));
        Target.Top := Max(Target.Top, Integer((DrawState shr 12) and $7FF));
        Target.Right := Min(Target.Right, Integer((DrawState shr 23) and $7FF));
        Target.Bottom := Min(Target.Bottom, Integer((DrawState shr 34) and $7FF));
        if (Target.Left >= Target.Right) or (Target.Top >= Target.Bottom) then
          Continue;
      end;
      var Alpha := 255;
      Target.DepthWrite := Blend = 0;
      Target.Culling := 162;
      if (Flags and 16) = 0 then
        Target.Culling := 160;
      Target.Winding := 169; // Clockwise polygons face the camera in Micro3D.
      Target.Blending := 68;
      case Blend of
        1:
          begin
            Target.Blending := 64;
            Alpha := 128;
          end;
        2:
          Target.Blending := 65;
        3:
          Target.Blending := 256;
      end;
      var TextureRef := Textures.ElementValues[I].AsRef;
      Target.Textures[0] := Default(TM3GRasterTexture);
      Target.AlphaThreshold := 0;
      if TextureRef <> 0 then
      begin
        var T := VM.GetObject(TextureRef);
        var Indices := Ref(T, TextureName, 'indices', '[B');
        if Indices = 0 then
          Continue;
        Target.Textures[0].Pixels := VM.GetObject(Indices);
        Target.Textures[0].Palette := VM.GetObject(Ref(T, TextureName, 'palette', '[I'));
        Target.Textures[0].Width := I32(T, TextureName, 'width');
        Target.Textures[0].Height := I32(T, TextureName, 'height');
        Target.Textures[0].Format := 100;
        Target.Textures[0].Blending := 227;
        Target.Textures[0].ColorKey := (Flags and 1) <> 0;
        Target.AlphaThreshold := 1 / 255;
      end;
      var A := ReadVertex(Data, Color, Alpha);
      var B := ReadVertex(Data, Color, Alpha);
      var C := ReadVertex(Data, Color, Alpha);
      M3GRasterTriangle(VM, Target, Pixels, A, B, C, Color);
    end;
  finally
    for var I := First to Count - 1 do
      Textures.ElementValues[I] := TJVMValue.Ref(0);
    PutInt(O, 'count', First);
  end;
end;

procedure TextureUV(VM: TJVM; TextureRef, U, V: Integer; var Vertex: TM3GClipVertex);
begin
  if TextureRef = 0 then
    Exit;
  var T := VM.GetObject(TextureRef);
  var W := I32(T, TextureName, 'width');
  var H := I32(T, TextureName, 'height');
  if (W > 0) and (H > 0) then
  begin
    Vertex[6] := (U + 0.5) / W;
    Vertex[7] := (V + 0.5) / H;
  end;
end;

function ReadLighting(VM: TJVM; Light: Integer; Effect: TJVMObject): TLighting;
begin
  Result := Default(TLighting);
  Result.Enabled := Light <> 0;
  if Result.Enabled then
  begin
    var L := VM.GetObject(Light);
    var D := VM.GetObject(Ref(L, LightName, 'direction', 'L' + VectorName + ';'));
    Result.Direction := Vector4(D.Fields[VectorName + '.x:I'].AsInt, D.Fields[VectorName + '.y:I'].AsInt,
      D.Fields[VectorName + '.z:I'].AsInt, 0);
    Result.Ambient := I32(L, LightName, 'ambient');
    Result.Parallel := I32(L, LightName, 'parallel');
  end;
  Result.Toon := I32(Effect, EffectName, 'shading') = 1;
  Result.Threshold := I32(Effect, EffectName, 'threshold');
  Result.High := I32(Effect, EffectName, 'high');
  Result.Low := I32(Effect, EffectName, 'low');
end;

function TLighting.Shade(const Normal: TM3GDoubleVector; const Transform: TM3GMatrix): Double;
begin
  Result := 1;
  if not Enabled then
    Exit;
  var N := M3GDoubleTransform(Transform, Normal);
  var X := Direction[0];
  var Y := Direction[1];
  var Z := Direction[2];
  var Lengths := Sqrt((Sqr(X) + Sqr(Y) + Sqr(Z)) * (Sqr(N[0]) + Sqr(N[1]) + Sqr(N[2])));
  var Directional: Double := 0;
  if Lengths > 0 then
    Directional := Max(0.0, (X * N[0] + Y * N[1] + Z * N[2]) / Lengths);
  Result := EnsureRange((Ambient + Parallel * Directional) / 4096, 0.0, 1.0);
  if Toon then
  begin
    if Result * 255 >= Threshold then
      Result := High / 255
    else
      Result := Low / 255;
  end;
end;

procedure SubmitFigure(VM: TJVM; O, Figure, Effect: TJVMObject; const Projection: TProjection);
var
  BoneMatrices: TArray<TM3GMatrix>;
  Pose: TJVMObject;
  Built: TArray<Boolean>;
  BoneOf: TArray<Integer>;
  Projected: TArray<TM3GClipVertex>;
  Vert: array[0..3] of TM3GClipVertex;

  procedure BuildBone(Index: Integer; Bones: TJVMObject; var Chain: TArray<Integer>);
  begin
    var Count := 0;
    while (Index >= 0) and not Built[Index] do
    begin
      Chain[Count] := Index;
      Inc(Count);
      Index := Arg(Bones, Index * BoneStride + 1);
    end;
    for var I := Count - 1 downto 0 do
    begin
      var Bone := Chain[I];
      var Matrix := M3GIdentity;
      for var J := 0 to 11 do
      begin
        var V := Arg(Bones, Bone * BoneStride + J + 2);
        if (J and 3) = 3 then
          Matrix[J] := V
        else
          Matrix[J] := V / 4096;
      end;
      if Index >= 0 then
        Matrix := M3GMultiply(BoneMatrices[Index], Matrix);
      // A pose is local to its bone, after the bind transform and parent.
      if (Pose <> nil) and (Bone < Pose.ElementCount div 12) then
      begin
        var Motion := M3GIdentity;
        for var J := 0 to 11 do
          Motion[J] := Pose.ElementValues[Bone * 12 + J].AsFloat;
        Matrix := M3GMultiply(Matrix, Motion);
      end;
      BoneMatrices[Bone] := Matrix;
      Built[Bone] := True;
      Index := Bone;
    end;
  end;

begin
  var Vertices := VM.GetObject(Ref(Figure, FigureName, 'vertices', '[I'));
  var Normals := VM.GetObject(Ref(Figure, FigureName, 'normals', '[I'));
  var Faces := VM.GetObject(Ref(Figure, FigureName, 'faces', '[I'));
  var Bones := VM.GetObject(Ref(Figure, FigureName, 'bones', '[I'));
  Pose := nil;
  var PoseValue: TJVMValue;
  if Figure.Fields.TryGetValue(Micro3DPoseKey, PoseValue) and (PoseValue.AsRef <> 0) then
    Pose := VM.GetObject(PoseValue.AsRef);
  var FaceCount := Faces.ElementCount div FaceStride;
  var BoneCount := Bones.ElementCount div BoneStride;
  SetLength(BoneMatrices, BoneCount);
  SetLength(Built, BoneCount);
  SetLength(BoneOf, Vertices.ElementCount div 3);
  SetLength(Projected, Length(BoneOf));
  var Chain: TArray<Integer>;
  SetLength(Chain, BoneCount);
  var N := 0;
  for var I := 0 to BoneCount - 1 do
  begin
    BuildBone(I, Bones, Chain);
    for var J := 1 to Arg(Bones, I * BoneStride) do
    begin
      BoneOf[N] := I;
      var P := M3GDoubleTransform(BoneMatrices[I], Vector4(
          Arg(Vertices, N * 3), Arg(Vertices, N * 3 + 1), Arg(Vertices, N * 3 + 2), 1));
      Projected[N] := Projection.Project(P[0], P[1], P[2]);
      Inc(N);
    end;
  end;

  var Queue := ReserveQueue(VM, O, FaceCount * 2);
  var Pattern := UInt32(I32(Figure, FigureName, 'pattern'));
  var Light := Ref(Effect, EffectName, 'light', 'L' + LightName + ';');
  var Lighting := ReadLighting(VM, Light, Effect);
  var Blend := Effect.Fields[Key(EffectName, 'blend', 'Z')].AsInt <> 0;
  var Textures := Ref(Figure, FigureName, 'textures', '[' + TextureType);
  var Selected := I32(Figure, FigureName, 'textureIndex');
  for var I := 0 to FaceCount - 1 do
  begin
    var Offset := I * FaceStride;
    var Group := Arg(Faces, Offset + 4);
    if (Group > 0) and ((Pattern and (UInt32(1) shl (Group - 1))) = 0) then
      Continue;
    var Corners := Arg(Faces, Offset);
    var Flags := Arg(Faces, Offset + 1);
    var Slot := Arg(Faces, Offset + 3);
    var Texture := 0;
    var Color := UInt32(Arg(Faces, Offset + 2));
    if Slot >= 0 then
    begin
      Color := $FFFFFF;
      if Textures <> 0 then
      begin
        var ArrayObject := VM.GetObject(Textures);
        if I32(Figure, FigureName, 'materialCount') <= 1 then
          Slot := Selected;
        if (Slot >= 0) and (Slot < ArrayObject.ElementCount) then
          Texture := ArrayObject.ElementValues[Slot].AsRef;
      end;
    end;
    for var J := 0 to Corners - 1 do
    begin
      var Index := Arg(Faces, Offset + 5 + J * 3);
      Vert[J] := Projected[Index];
      TextureUV(VM, Texture, Arg(Faces, Offset + 6 + J * 3), Arg(Faces, Offset + 7 + J * 3), Vert[J]);
      Vert[J][13] := 1;
      if ((Flags and 32) <> 0) and (Light <> 0) and (Normals.ElementCount <> 0) then
      begin
        var Matrix := M3GMultiply(Projection.Transform, BoneMatrices[BoneOf[Index]]);
        Vert[J][13] := Lighting.Shade(Vector4(Arg(Normals, Index * 3),
              Arg(Normals, Index * 3 + 1), Arg(Normals, Index * 3 + 2), 0), Matrix);
      end;
    end;
    Queue.Push(Vert[0], Vert[1], Vert[2], Texture, Color, Flags, Blend);
    if Corners = 4 then
      Queue.Push(Vert[2], Vert[1], Vert[3], Texture, Color, Flags, Blend);
  end;
  PutInt(O, 'count', Queue.Count);
end;

type
  TIntData = record
    Obj: TJVMObject;
    Start: Integer;
    function Read(Index: Integer): Integer;
    procedure Validate(VM: TJVM; Count: Integer);
  end;

  TPrimitiveFormat = record
    Kind, Count, Vertices, NormalStep, UVStep, UVCount, ColorCount: Integer;
    class function Decode(VM: TJVM; Command, Count: Integer): TPrimitiveFormat; static;
  end;

function TIntData.Read(Index: Integer): Integer;
begin
  Result := Arg(Obj, Start + Index);
end;

procedure TIntData.Validate(VM: TJVM; Count: Integer);
begin
  if Count = 0 then
    Exit;
  if (Obj = nil) or (Start > Obj.ElementCount - Count) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Micro3D primitive array length');
end;

class function TPrimitiveFormat.Decode(VM: TJVM; Command, Count: Integer): TPrimitiveFormat;
begin
  Result := Default(TPrimitiveFormat);
  Result.Kind := Command shr 24;
  Result.Count := Count;
  if not (Result.Kind in [1..5]) or (Count < 1) or (Count > 255) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Micro3D primitive command $' + IntToHex(Command, 8));
  Result.Vertices := Result.Kind;
  if Result.Kind = 5 then
  begin
    Result.Vertices := 1;
    case (Command shr 12) and 3 of
      1:
        Result.UVCount := 8;
      2, 3:
        begin
          Result.UVStep := 8;
          Result.UVCount := Count * 8;
        end;
    else
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Missing Micro3D point-sprite parameters');
    end;
    Exit;
  end;
  if Result.Kind in [3, 4] then
  begin
    case (Command shr 8) and 3 of
      2:
        Result.NormalStep := 3;
      3:
        Result.NormalStep := 3 * Result.Vertices;
    end;
    if (Command and $3000) = $3000 then
    begin
      Result.UVStep := Result.Vertices * 2;
      Result.UVCount := Result.UVStep * Count;
    end;
  end;
  case (Command shr 10) and 3 of
    1:
      Result.ColorCount := 1;
    2:
      Result.ColorCount := Count;
  end;
  if (Result.Kind in [1, 2]) and (Result.ColorCount = 0) then
    Result.ColorCount := Count;
end;

procedure SubmitPrimitives(VM: TJVM; O: TJVMObject; const Projection: TProjection; const Lighting: TLighting; const Format: TPrimitiveFormat; const Points, Normals, UV, Colors: TIntData; Command, Texture: Integer; Blend: Boolean; Clip: Int64);
var
  Vert: array[0..3] of TM3GClipVertex;

  procedure Quad(const A, B: TM3GClipVertex; X, Y, U, V: Double);
  begin
    Vert[0] := A;
    Vert[1] := B;
    Vert[2] := B;
    Vert[3] := A;
    Vert[0][0] := A[0] - X * A[3];
    Vert[0][1] := A[1] - Y * A[3];
    Vert[1][0] := B[0] - X * B[3];
    Vert[1][1] := B[1] - Y * B[3];
    Vert[2][0] := B[0] + U * B[3];
    Vert[2][1] := B[1] + V * B[3];
    Vert[3][0] := A[0] + U * A[3];
    Vert[3][1] := A[1] + V * A[3];
  end;

  function Side(A, B, C: Integer): Double;
  begin
    var X := Vert[A][0] / Vert[A][3];
    var Y := Vert[A][1] / Vert[A][3];
    Result := (Vert[B][0] / Vert[B][3] - X) * (Vert[C][1] / Vert[C][3] - Y) -
      (Vert[B][1] / Vert[B][3] - Y) * (Vert[C][0] / Vert[C][3] - X);
  end;

  function Crosses(A, B, C, D: Integer): Boolean;
  begin
    Result := (Side(A, B, C) * Side(A, B, D) < 0) and (Side(C, D, A) * Side(C, D, B) < 0);
  end;

  procedure Swap(A, B: Integer);
  begin
    var Temp := Vert[A];
    Vert[A] := Vert[B];
    Vert[B] := Temp;
  end;

begin
  Points.Validate(VM, Format.Count * Format.Vertices * 3);
  Normals.Validate(VM, Format.Count * Format.NormalStep);
  UV.Validate(VM, Format.UVCount);
  Colors.Validate(VM, Format.ColorCount);
  if Format.UVCount = 0 then
    Texture := 0;
  var Triangles := 2;
  if Format.Kind = 3 then
    Triangles := 1;
  var Queue := ReserveQueue(VM, O, Format.Count * Triangles);
  Queue.Clip := Clip;
  var Flags := 16 or ((Command shr 4) and 7);
  var Width := I32(O, Micro3DGraphicsName, 'width');
  var Height := I32(O, Micro3DGraphicsName, 'height');
  for var I := 0 to Format.Count - 1 do
  begin
    var Color: UInt32 := $FFFFFF;
    if Format.ColorCount > 0 then
      Color := UInt32(Colors.Read(I mod Format.ColorCount)) and $FFFFFF;
    for var J := 0 to Format.Vertices - 1 do
    begin
      var K := (I * Format.Vertices + J) * 3;
      Vert[J] := Projection.Project(Points.Read(K), Points.Read(K + 1), Points.Read(K + 2));
      if (Format.Kind in [3, 4]) and (Format.UVStep > 0) then
      begin
        var U := I * Format.UVStep + J * 2;
        TextureUV(VM, Texture, UV.Read(U), UV.Read(U + 1), Vert[J]);
      end;
      Vert[J][13] := 1;
      if ((Command and 1) <> 0) and Lighting.Enabled and (Format.NormalStep > 0) then
      begin
        var N := I * Format.NormalStep + (J * 3) mod Format.NormalStep;
        Vert[J][13] := Lighting.Shade(Vector4(Normals.Read(N), Normals.Read(N + 1), Normals.Read(N + 2), 0),
            Projection.Transform);
      end;
    end;
    case Format.Kind of
      1:
        begin
          var A := Vert[0];
          if A[3] <= 0 then
            Continue;
          var B := A;
          A[0] := A[0] - A[3] / Width;
          B[0] := B[0] + B[3] / Width;
          Quad(A, B, 0, 1 / Height, 0, 1 / Height);
        end;
      2:
        begin
          var A := Vert[0];
          var B := Vert[1];
          if (A[3] <= 0) or (B[3] <= 0) then
            Continue;
          var DX := (B[0] / B[3] - A[0] / A[3]) * Width;
          var DY := (B[1] / B[3] - A[1] / A[3]) * Height;
          var L := Hypot(DX, DY);
          if L = 0 then
          begin
            A[0] := A[0] - A[3] / Width;
            B[0] := B[0] + B[3] / Width;
            Quad(A, B, 0, 1 / Height, 0, 1 / Height);
          end
          else
            Quad(A, B, -DY / (L * Width), DX / (L * Height), -DY / (L * Width), DX / (L * Height));
        end;
      4:
        begin
          // Preserve perimeter order and accept the strip order used by some MIDlets.
          if (Vert[0][3] > 0) and (Vert[1][3] > 0) and (Vert[2][3] > 0) and (Vert[3][3] > 0) then
          begin
            if Crosses(1, 2, 3, 0) then
              Swap(2, 3)
            else if Crosses(0, 1, 2, 3) then
              Swap(1, 2);
          end;
        end;
      5:
        begin
          var A := Vert[0];
          if (A[3] <= 0) or (Texture = 0) then
            Continue;
          var P := I * Format.UVStep;
          var SpriteFlags := UV.Read(P + 7);
          var SX := 1.0 / Width;
          var SY := 1.0 / Height;
          if (SpriteFlags and 1) = 0 then
          begin
            SX := Projection.ScaleX * 0.5;
            SY := Projection.ScaleY * 0.5;
            if Projection.Perspective and ((SpriteFlags and 2) = 0) then
            begin
              SX := SX / A[3];
              SY := SY / A[3];
            end;
          end;
          var Angle := (UV.Read(P + 2) and $FFF) * Pi / 2048;
          var C := Cos(Angle);
          var S := Sin(Angle);
          for var J := 0 to 3 do
          begin
            var Left := J in [0, 3];
            var Top := J in [2, 3];
            var X := Double(UV.Read(P)) * (2 * Ord(not Left) - 1);
            var Y := Double(UV.Read(P + 1)) * (2 * Ord(Top) - 1);
            Vert[J] := A;
            Vert[J][0] := A[0] + (X * C - Y * S) * SX * A[3];
            Vert[J][1] := A[1] + (X * S + Y * C) * SY * A[3];
            TextureUV(VM, Texture, UV.Read(P + 3 + 2 * Ord(not Left)),
              UV.Read(P + 4 + 2 * Ord(not Top)), Vert[J]);
          end;
        end;
    end;
    Queue.Push(Vert[0], Vert[1], Vert[2], Texture, Color, Flags, Blend);
    if Triangles = 2 then
      Queue.Push(Vert[0], Vert[2], Vert[3], Texture, Color, Flags, Blend);
  end;
  PutInt(O, 'count', Queue.Count);
end;

function OptionalData(VM: TJVM; Ref: Integer): TIntData;
begin
  Result := Default(TIntData);
  if Ref <> 0 then
    Result.Obj := VM.GetObject(Ref);
end;

function ArrayChoice(VM: TJVM; ArrayRef, Index: Integer): Integer;
begin
  if ArrayRef = 0 then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Missing Micro3D indexed array');
  var Arr := VM.GetObject(ArrayRef);
  if Index >= Arr.ElementCount then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Micro3D array index out of bounds');
  Result := Arr.ElementValues[Index].AsRef;
end;

procedure DrawCommandList(VM: TJVM; O, Graphics, Layout, Effect: TJVMObject; TextureRef: Integer; TextureArray: Boolean; X, Y: Integer; Commands: TJVMObject; var Pixels: TArray<UInt32>);
var
  Cursor: Integer;

  function Take(Count: Integer): TIntData;
  begin
    Result.Obj := Commands;
    Result.Start := Cursor;
    Result.Validate(VM, Count);
    Inc(Cursor, Count);
  end;

  function WordValue: Integer;
  begin
    Result := Take(1).Read(0);
  end;

  function ClipCoordinate(Value, Translation, Limit: Integer): Int64;
  begin
    Result := EnsureRange(Int64(Value) + Translation, Int64(0), Int64(Limit));
  end;

begin
  Cursor := 0;
  if UInt32(WordValue) <> CommandVersion then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Unsupported Micro3D command list version');
  var View := ReadView(VM, Layout);
  var Lighting := ReadLighting(VM, Ref(Effect, EffectName, 'light', 'L' + LightName + ';'), Effect);
  var Blend := Effect.Fields[Key(EffectName, 'blend', 'Z')].AsInt <> 0;
  var Texture := TextureRef;
  if TextureArray and (TextureRef <> 0) then
  begin
    Texture := 0;
    if VM.GetObject(TextureRef).ElementCount > 0 then
      Texture := ArrayChoice(VM, TextureRef, 0);
  end;
  var Clip: Int64 := 0;
  while Cursor < Commands.ElementCount do
  begin
    if VM.StopRequested then
      Exit;
    var Command := WordValue;
    var Opcode := Command shr 24;
    var Parameter := Command and $FFFFFF;
    case Opcode of
      $01..$05:
        begin
          var Format := TPrimitiveFormat.Decode(VM, Command, Parameter shr 16);
          var Points := Take(Format.Count * Format.Vertices * 3);
          var Normals := Take(Format.Count * Format.NormalStep);
          var UV := Take(Format.UVCount);
          var Colors := Take(Format.ColorCount);
          SubmitPrimitives(VM, O, SetupProjection(VM, O, View, X, Y), Lighting, Format,
            Points, Normals, UV, Colors, Command, Texture, Blend, Clip);
        end;
      $80:
        Exit;
      $81:
        Take(Parameter);
      $82:
        Flush(VM, O, Graphics, Pixels);
      $83:
        begin
          Lighting.Enabled := (Parameter and 1) <> 0;
          Lighting.Toon := (Parameter and 4) <> 0;
          Blend := (Parameter and 8) <> 0;
        end;
      $84:
        begin
          var R := Take(4);
          var W := I32(O, Micro3DGraphicsName, 'width');
          var H := I32(O, Micro3DGraphicsName, 'height');
          var TX := I32(O, Micro3DGraphicsName, 'tx');
          var TY := I32(O, Micro3DGraphicsName, 'ty');
          Clip := ClipPresent or (ClipCoordinate(R.Read(0), TX, W) shl 1) or
            (ClipCoordinate(R.Read(1), TY, H) shl 12) or (ClipCoordinate(R.Read(2), TX, W) shl 23) or
            (ClipCoordinate(R.Read(3), TY, H) shl 34);
        end;
      $85:
        begin
          View.CenterX := WordValue;
          View.CenterY := WordValue;
        end;
      $86:
        begin
          if TextureArray then
            Texture := ArrayChoice(VM, TextureRef, Parameter)
          else if Parameter <> 0 then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Micro3D texture index');
        end;
      $87:
        View.Transform := ReadTransform(VM.GetObject(
            ArrayChoice(VM, Ref(Layout, LayoutName, 'transforms', '[L' + AffineName + ';'), Parameter)));
      $90..$93:
        begin
          View.Kind := Opcode - $90;
          if View.Kind >= 2 then
          begin
            View.NearZ := WordValue;
            View.FarZ := WordValue;
            if (View.NearZ <= 0) or (View.FarZ <= View.NearZ) then
              VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Micro3D perspective depth');
          end;
          View.SizeX := WordValue;
          if View.Kind <> 2 then
            View.SizeY := WordValue;
          if (View.Kind = 2) and ((View.SizeX <= 0) or (View.SizeX >= 2048)) then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid Micro3D perspective angle');
        end;
      $A0:
        begin
          Lighting.Enabled := True;
          Lighting.Ambient := WordValue;
        end;
      $A1:
        begin
          Lighting.Enabled := True;
          var Direction := Take(3);
          Lighting.Direction := Vector4(Direction.Read(0), Direction.Read(1), Direction.Read(2), 0);
          Lighting.Parallel := WordValue;
        end;
      $AF:
        begin
          Lighting.Threshold := WordValue;
          Lighting.High := WordValue;
          Lighting.Low := WordValue;
        end;
    else
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Unknown Micro3D command $' + IntToHex(Command, 8));
    end;
  end;
  VM.RaiseJava('java/lang/IllegalArgumentException', 'Missing Micro3D command list terminator');
end;

function InvokeJ2MEMicro3DGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  var TargetRef := Ref(O, Micro3DGraphicsName, 'target', GraphicsType);
  if Name = '<init>' then
    Exit;
  if Name = 'dispose' then
  begin
    PutInt(O, 'count', 0);
    PutRef(O, 'target', GraphicsType, 0);
    PutRef(O, 'depth', '[F', 0);
    PutRef(O, 'draws', '[D', 0);
    PutRef(O, 'textures', '[' + TextureType, 0);
    Exit;
  end;
  if Name = 'bind' then
  begin
    var Graphics := VM.GetObject(Args[1].AsRef);
    if TargetRef <> 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'Micro3D target already bound');
    var Image: TJVMValue;
    if Graphics.Fields.TryGetValue('$target', Image) then
    begin
      var Surface := J2MEImageView(VM, Image.AsRef);
      Width := Surface.Width;
      Height := Surface.Height;
    end;
    if (Width < 1) or (Height < 1) or (Width > 1024) or (Height > 1024) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Micro3D target dimensions');
    var DepthRef := Ref(O, Micro3DGraphicsName, 'depth', '[F');
    if (DepthRef = 0) or (VM.GetObject(DepthRef).ElementCount <> Width * Height) then
    begin
      DepthRef := VM.NewArray('[F', Width * Height);
      PutRef(O, 'depth', '[F', DepthRef);
    end;
    var Depth := VM.GetObject(DepthRef);
    for var I := 0 to Depth.ElementCount - 1 do
      Depth.ElementValues[I] := TJVMValue.Float(1);
    PutInt(O, 'width', Width);
    PutInt(O, 'height', Height);
    PutInt(O, 'tx', GI(Graphics, 'tx'));
    PutInt(O, 'ty', GI(Graphics, 'ty'));
    var Left := EnsureRange(GI(Graphics, 'clipL'), 0, Width);
    var Top := EnsureRange(GI(Graphics, 'clipT'), 0, Height);
    PutInt(O, 'left', Left);
    PutInt(O, 'top', Top);
    PutInt(O, 'right', EnsureRange(GI(Graphics, 'clipR', Width), Left, Width));
    PutInt(O, 'bottom', EnsureRange(GI(Graphics, 'clipB', Height), Top, Height));
    PutRef(O, 'target', GraphicsType, Args[1].AsRef);
    Exit;
  end;
  if Name = 'release' then
  begin
    VM.GetObject(Args[1].AsRef);
    if TargetRef <> Args[1].AsRef then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Different Micro3D target');
    var Count := I32(O, Micro3DGraphicsName, 'count');
    if Count > 0 then
    begin
      var T := VM.GetObject(Ref(O, Micro3DGraphicsName, 'textures', '[' + TextureType));
      for var I := 0 to Count - 1 do
        T.ElementValues[I] := TJVMValue.Ref(0);
      PutInt(O, 'count', 0);
    end;
    PutRef(O, 'target', GraphicsType, 0);
    Exit;
  end;
  if TargetRef = 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'No Micro3D target');
  if Name = 'flush' then
  begin
    Flush(VM, O, VM.GetObject(TargetRef), Pixels);
    Exit;
  end;
  var Layout := VM.GetObject(Args[4].AsRef);
  var Effect := VM.GetObject(Args[5].AsRef);
  if Name = 'drawCommandList' then
  begin
    DrawCommandList(VM, O, VM.GetObject(TargetRef), Layout, Effect, Args[1].AsRef,
      Method.Descriptor.StartsWith('(['), Args[2].AsInt, Args[3].AsInt, VM.GetObject(Args[6].AsRef), Pixels);
    Exit;
  end;
  var Projection := SetupProjection(VM, O, ReadView(VM, Layout), Args[2].AsInt, Args[3].AsInt);
  if Name = 'renderPrimitives' then
  begin
    var Command := Args[6].AsInt;
    var Format := TPrimitiveFormat.Decode(VM, Command, Args[7].AsInt);
    SubmitPrimitives(VM, O, Projection, ReadLighting(VM, Ref(Effect, EffectName, 'light', 'L' + LightName + ';'), Effect),
      Format, OptionalData(VM, Args[8].AsRef), OptionalData(VM, Args[9].AsRef),
      OptionalData(VM, Args[10].AsRef), OptionalData(VM, Args[11].AsRef), Command, Args[1].AsRef,
      Effect.Fields[Key(EffectName, 'blend', 'Z')].AsInt <> 0, 0);
  end
  else if (Name = 'renderFigure') or (Name = 'drawFigure') then
  begin
    var First := I32(O, Micro3DGraphicsName, 'count');
    SubmitFigure(VM, O, VM.GetObject(Args[1].AsRef), Effect, Projection);
    if Name = 'drawFigure' then
      Flush(VM, O, VM.GetObject(TargetRef), Pixels, First);
  end
  else
    raise EJVMUnsupported.Create(Micro3DGraphicsName + '.' + Name);
end;

end.

