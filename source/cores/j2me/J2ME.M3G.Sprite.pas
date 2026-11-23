unit J2ME.M3G.Sprite;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Math, J2ME.M3G.Raster;

const
  M3GMaxSpriteCrop = 1024;

procedure InstallM3GSprite(VM: TJVM);

function M3GSpriteHandles(const Name: string): Boolean;

function InvokeM3GSprite(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GSpriteReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

function M3GSpriteExtent(const ModelView, Projection: TM3GMatrix; out Clip: TM3GDoubleVector; out Width, Height: Double): Boolean;

procedure M3GDrawSprite(VM: TJVM; Ref: Integer; const ModelView, Projection: TM3GMatrix; const Surface: TM3GRasterTarget; Alpha: Double; var Pixels: TArray<UInt32>);

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.M3G.Texture;

const
  Name = 'javax/microedition/m3g/Sprite3D';
  P = '$m3g.';

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

procedure PI(O: TJVMObject; const Key: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(Value));
end;

function M3GSpriteHandles(const Name: string): Boolean;
begin
  Result := Name = 'javax/microedition/m3g/Sprite3D';
end;

function M3GSpriteReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, Name) then
  begin
    if R(O, 'image') <> 0 then
      Result := [R(O, 'image')];
    if R(O, 'appearance') <> 0 then
      Result := Result + [R(O, 'appearance')];
  end;
end;

procedure InstallM3GSprite(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, 'javax/microedition/m3g/Node');
  try
    B.JavaClass.AddNative('<init>', '(ZLjavax/microedition/m3g/Image2D;Ljavax/microedition/m3g/Appearance;)V');
    B.JavaClass.AddNative('isScaled', '()Z');
    for var N in ['Image', 'Appearance'] do
    begin
      var D := 'Ljavax/microedition/m3g/' + N + ';';
      if N = 'Image' then
        D := 'Ljavax/microedition/m3g/Image2D;';
      B.JavaClass.AddNative('get' + N, '()' + D);
      B.JavaClass.AddNative('set' + N, '(' + D + ')V');
    end;
    B.JavaClass.AddNative('setCrop', '(IIII)V');
    for var N in ['X', 'Y', 'Width', 'Height'] do
      B.JavaClass.AddNative('getCrop' + N, '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeM3GSprite(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if (N = '<init>') or (N = 'setImage') then
  begin
    var Index := 1;
    if N = '<init>' then
      Index := 2;
    var Image := M3GImageView(VM, Args[Index].AsRef);
    O.Fields.AddOrSetValue(P + 'image', Args[Index]);
    PI(O, 'cropX', 0);
    PI(O, 'cropY', 0);
    PI(O, 'cropWidth', Min(Image.Width, M3GMaxSpriteCrop));
    PI(O, 'cropHeight', Min(Image.Height, M3GMaxSpriteCrop));
    if N = '<init>' then
    begin
      PI(O, 'scaled', Ord(Args[1].AsInt <> 0));
      O.Fields.AddOrSetValue(P + 'appearance', Args[3]);
    end;
    Exit;
  end;
  if N = 'isScaled' then
    Exit(TJVMValue.Int(I(O, 'scaled')));
  if N = 'getImage' then
    Exit(TJVMValue.Ref(R(O, 'image')));
  if N = 'getAppearance' then
    Exit(TJVMValue.Ref(R(O, 'appearance')));
  if N = 'setAppearance' then
  begin
    O.Fields.AddOrSetValue(P + 'appearance', Args[1]);
    Exit;
  end;
  if N.StartsWith('getCrop') then
    Exit(TJVMValue.Int(I(O, 'crop' + Copy(N, 8, MaxInt))));
  if N = 'setCrop' then
  begin
    if (Abs(Int64(Args[3].AsInt)) > M3GMaxSpriteCrop) or (Abs(Int64(Args[4].AsInt)) > M3GMaxSpriteCrop) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G sprite crop size');
    PI(O, 'cropX', Args[1].AsInt);
    PI(O, 'cropY', Args[2].AsInt);
    PI(O, 'cropWidth', Args[3].AsInt);
    PI(O, 'cropHeight', Args[4].AsInt);
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

function M3GSpriteExtent(const ModelView, Projection: TM3GMatrix; out Clip: TM3GDoubleVector; out Width, Height: Double): Boolean;

  function Distance(const A, B: TM3GDoubleVector): Double;
  begin
    Result := 0;
    if (A[3] = 0) or (B[3] = 0) then
      Exit;
    for var K := 0 to 2 do
      Result := Result + Sqr(A[K] / A[3] - B[K] / B[3]);
    Result := Sqrt(Result);
  end;

begin
  Result := False;
  Width := 0;
  Height := 0;
  var Point := Default(TM3GDoubleVector);
  Point[3] := 1;
  var Eye := M3GDoubleTransform(ModelView, Point);
  Clip := M3GDoubleTransform(Projection, Eye);
  for var K := 0 to 3 do
    if IsNan(Clip[K]) or IsInfinite(Clip[K]) then
      Exit;
  if Clip[3] <= 0 then
    Exit;
  Point[0] := 1;
  var X := M3GDoubleTransform(ModelView, Point);
  Point[0] := 0;
  Point[1] := 1;
  var Y := M3GDoubleTransform(ModelView, Point);
  var Offset := Eye;
  Offset[0] := Offset[0] + Distance(X, Eye);
  Width := Distance(M3GDoubleTransform(Projection, Offset), Clip);
  Offset := Eye;
  Offset[1] := Offset[1] + Distance(Y, Eye);
  Height := Distance(M3GDoubleTransform(Projection, Offset), Clip);
  Result := not IsNan(Width) and not IsInfinite(Width) and (Width > 0) and
    not IsNan(Height) and not IsInfinite(Height) and (Height > 0);
end;

procedure M3GDrawSprite(VM: TJVM; Ref: Integer; const ModelView, Projection: TM3GMatrix; const Surface: TM3GRasterTarget; Alpha: Double; var Pixels: TArray<UInt32>);
type
  TVector = array[0..3] of Double;

  function Transform(const M: TM3GMatrix; const V: TVector): TVector;
  begin
    for var K := 0 to 3 do
    begin
      Result[K] := 0;
      for var J := 0 to 3 do
        Result[K] := Result[K] + M[K * 4 + J] * V[J];
    end;
  end;

begin
  var O := VM.GetObject(Ref);
  var CW := I(O, 'cropWidth');
  var CH := I(O, 'cropHeight');
  if (CW = 0) or (CH = 0) or (Surface.ViewWidth = 0) or (Surface.ViewHeight = 0) then
    Exit;
  var Point := Default(TVector);
  Point[3] := 1;
  var Eye := Transform(ModelView, Point);
  var Clip := Transform(Projection, Eye);
  for var K := 0 to 3 do
    if IsNan(Clip[K]) or IsInfinite(Clip[K]) then
      Exit;
  if (Clip[3] <= 0) or (Clip[2] < -Clip[3]) or (Clip[2] > Clip[3]) then
    Exit;
  var W: Double := Abs(CW);
  var H: Double := Abs(CH);
  if I(O, 'scaled') <> 0 then
  begin
    var Projected: TM3GDoubleVector;
    if not M3GSpriteExtent(ModelView, Projection, Projected, W, H) then
      Exit;
    W := W * Surface.ViewWidth / 2;
    H := H * Surface.ViewHeight / 2;
  end;
  if IsNan(W) or IsInfinite(W) or IsNan(H) or IsInfinite(H) or (W <= 0) or (H <= 0) then
    Exit;
  var L := Surface.ViewX + (Clip[0] / Clip[3] + 1) * Surface.ViewWidth / 2 - W / 2;
  var T := Surface.ViewY + (1 - Clip[1] / Clip[3]) * Surface.ViewHeight / 2 - H / 2;
  // Pixel-sized sprites keep an integral footprint when moving subpixel-wise.
  if I(O, 'scaled') = 0 then
  begin
    // Bound before converting to an integer, even for huge offscreen origins.
    if (L > Surface.Right) or (L + W < Surface.Left - 1) or (T > Surface.Bottom) or (T + H < Surface.Top - 1) then
      Exit;
    L := Floor(L + 0.5);
    T := Floor(T + 0.5);
  end;
  var Image := M3GImageView(VM, R(O, 'image'));
  var Target := Surface;
  Target.Culling := 162;
  Target.Winding := 168;
  Target.InterpolateColors := False;
  Target.TwoSidedColors := False;
  Target.SpriteAlpha := Alpha;
  Target.Textures[0] := Default(TM3GRasterTexture);
  Target.Textures[1] := Default(TM3GRasterTexture);
  Target.Textures[0].Pixels := Image.Pixels;
  Target.Textures[0].Width := Image.Width;
  Target.Textures[0].Height := Image.Height;
  Target.Textures[0].Format := Image.Format;
  Target.Textures[0].WrapS := 240;
  Target.Textures[0].WrapT := 240;
  Target.Textures[0].Blending := 227;
  Target.Textures[0].Filter := 210;
  Target.Textures[0].BorderDiscard := True;
  var S0 := Double(I(O, 'cropX')) / Image.Width;
  var S1 := (Double(I(O, 'cropX')) + Abs(CW)) / Image.Width;
  var T0 := Double(I(O, 'cropY')) / Image.Height;
  var T1 := (Double(I(O, 'cropY')) + Abs(CH)) / Image.Height;
  if CW < 0 then
  begin
    var Swap := S0;
    S0 := S1;
    S1 := Swap;
  end;
  if CH < 0 then
  begin
    var Swap := T0;
    T0 := T1;
    T1 := Swap;
  end;
  var V: array[0..3] of TM3GClipVertex;
  FillChar(V, SizeOf(V), 0);
  for var K := 0 to 3 do
  begin
    var X := L;
    if (K and 1) <> 0 then
      X := X + W;
    var Y := T;
    if (K and 2) <> 0 then
      Y := Y + H;
    V[K][0] := 2 * (X - Surface.ViewX) / Surface.ViewWidth - 1;
    V[K][1] := 1 - 2 * (Y - Surface.ViewY) / Surface.ViewHeight;
    V[K][2] := Clip[2] / Clip[3];
    V[K][3] := 1;
    V[K][4] := Eye[2];
    V[K][5] := Eye[3];
    V[K][6] := S0;
    if (K and 1) <> 0 then
      V[K][6] := S1;
    V[K][7] := T0;
    if (K and 2) <> 0 then
      V[K][7] := T1;
    V[K][8] := 1;
  end;
  var Color := (UInt32(Trunc(255 * Alpha + 0.5)) shl 24) or $FFFFFF;
  M3GRasterTriangle(VM, Target, Pixels, V[0], V[1], V[2], Color);
  M3GRasterTriangle(VM, Target, Pixels, V[2], V[1], V[3], Color);
end;

end.

