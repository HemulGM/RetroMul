unit J2ME.M3G.Texture;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

const
  M3GMaxTextureDimension = 1024;

type
  TM3GImageView = record
    Image, Pixels: TJVMObject;
    Width, Height, Format: Integer;
    Mutable: Boolean;
  end;

procedure InstallM3GTexture(VM: TJVM);

function M3GTextureHandles(const Name: string): Boolean;

function InvokeM3GTexture(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GTextureReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

function M3GImageView(VM: TJVM; Ref: Integer): TM3GImageView;
// Canonical unpremultiplied ARGB pixels, e.g. from the native PNG decoder.

function M3GNewRasterImage(VM: TJVM; Format, Width, Height: Integer; const Pixels: TArray<UInt32>): Integer;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.Image;

const
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';
  ImageName = Base + 'Image2D';
  TextureName = Base + 'Texture2D';
  CompositeName = Base + 'CompositingMode';
  PolygonName = Base + 'PolygonMode';

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

function F(O: TJVMObject; const Key: string): Single;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsFloat;
end;

procedure PI(O: TJVMObject; const Key: string; V: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(V));
end;

procedure Invalid(VM: TJVM; const What: string);
begin
  VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G ' + What);
end;

function M3GTextureHandles(const Name: string): Boolean;
begin
  Result := (Name = ImageName) or (Name = TextureName) or (Name = CompositeName) or (Name = PolygonName);
end;

function M3GTextureReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, TextureName) and (R(O, 'image') <> 0) then
    Result := [R(O, 'image')];
end;

function M3GImageView(VM: TJVM; Ref: Integer): TM3GImageView;
begin
  Result.Image := VM.GetObject(Ref);
  Result.Pixels := VM.GetObject(R(Result.Image, 'pixels'));
  Result.Width := I(Result.Image, 'width');
  Result.Height := I(Result.Image, 'height');
  Result.Format := I(Result.Image, 'format');
  Result.Mutable := I(Result.Image, 'mutable') <> 0;
end;

procedure InstallM3GTexture(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(ImageName, Base + 'Object3D');
  try
    Constant('ALPHA', 96);
    Constant('LUMINANCE', 97);
    Constant('LUMINANCE_ALPHA', 98);
    Constant('RGB', 99);
    Constant('RGBA', 100);
    for var D in ['(ILjava/lang/Object;)V', '(III[B)V', '(III[B[B)V', '(III)V'] do
      B.JavaClass.AddNative('<init>', D);
    for var N in ['Width', 'Height', 'Format'] do
      B.JavaClass.AddNative('get' + N, '()I');
    B.JavaClass.AddNative('isMutable', '()Z');
    B.JavaClass.AddNative('set', '(IIII[B)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(TextureName, Base + 'Transformable');
  try
    Constant('FILTER_BASE_LEVEL', 208);
    Constant('FILTER_LINEAR', 209);
    Constant('FILTER_NEAREST', 210);
    Constant('FUNC_ADD', 224);
    Constant('FUNC_BLEND', 225);
    Constant('FUNC_DECAL', 226);
    Constant('FUNC_MODULATE', 227);
    Constant('FUNC_REPLACE', 228);
    Constant('WRAP_CLAMP', 240);
    Constant('WRAP_REPEAT', 241);
    B.JavaClass.AddNative('<init>', '(Ljavax/microedition/m3g/Image2D;)V');
    B.JavaClass.AddNative('setImage', '(Ljavax/microedition/m3g/Image2D;)V');
    B.JavaClass.AddNative('getImage', '()Ljavax/microedition/m3g/Image2D;');
    for var N in ['Blending', 'BlendColor'] do
    begin
      B.JavaClass.AddNative('set' + N, '(I)V');
      B.JavaClass.AddNative('get' + N, '()I');
    end;
    B.JavaClass.AddNative('setFiltering', '(II)V');
    B.JavaClass.AddNative('setWrapping', '(II)V');
    for var N in ['LevelFilter', 'ImageFilter', 'WrappingS', 'WrappingT'] do
      B.JavaClass.AddNative('get' + N, '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(CompositeName, Base + 'Object3D');
  try
    Constant('ALPHA', 64);
    Constant('ALPHA_ADD', 65);
    Constant('MODULATE', 66);
    Constant('MODULATE_X2', 67);
    Constant('REPLACE', 68);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('setBlending', '(I)V');
    B.JavaClass.AddNative('getBlending', '()I');
    B.JavaClass.AddNative('setAlphaThreshold', '(F)V');
    B.JavaClass.AddNative('getAlphaThreshold', '()F');
    B.JavaClass.AddNative('setDepthOffset', '(FF)V');
    for var N in ['Factor', 'Units'] do
      B.JavaClass.AddNative('getDepthOffset' + N, '()F');
    for var N in ['AlphaWrite', 'ColorWrite', 'DepthWrite', 'DepthTest'] do
    begin
      B.JavaClass.AddNative('set' + N + 'Enable', '(Z)V');
      B.JavaClass.AddNative('is' + N + 'Enabled', '()Z');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(PolygonName, Base + 'Object3D');
  try
    Constant('CULL_BACK', 160);
    Constant('CULL_FRONT', 161);
    Constant('CULL_NONE', 162);
    Constant('SHADE_FLAT', 164);
    Constant('SHADE_SMOOTH', 165);
    Constant('WINDING_CCW', 168);
    Constant('WINDING_CW', 169);
    B.JavaClass.AddNative('<init>', '()V');
    for var N in ['Culling', 'Shading', 'Winding'] do
    begin
      B.JavaClass.AddNative('set' + N, '(I)V');
      B.JavaClass.AddNative('get' + N, '()I');
    end;
    for var N in ['LocalCameraLighting', 'PerspectiveCorrection', 'TwoSidedLighting'] do
    begin
      B.JavaClass.AddNative('set' + N + 'Enable', '(Z)V');
      B.JavaClass.AddNative('is' + N + 'Enabled', '()Z');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function Components(VM: TJVM; Format: Integer): Integer;
begin
  case Format of
    96, 97:
      Result := 1;
    98:
      Result := 2;
    99:
      Result := 3;
    100:
      Result := 4;
  else
    Invalid(VM, 'image format');
    Result := 0;
  end;
end;

function ReadPixel(Data: TJVMObject; Offset, Format: Integer): Integer;

  function ByteAt(Index: Integer): UInt32;
  begin
    Result := Data.Elements[Offset + Index].AsInt and 255;
  end;

begin
  var A: UInt32 := 255;
  var Red: UInt32 := 255;
  var Green: UInt32 := 255;
  var Blue: UInt32 := 255;
  case Format of
    96:
      A := ByteAt(0);
    97, 98:
      begin
        Red := ByteAt(0);
        Green := Red;
        Blue := Red;
        if Format = 98 then
          A := ByteAt(1);
      end;
    99, 100:
      begin
        Red := ByteAt(0);
        Green := ByteAt(1);
        Blue := ByteAt(2);
        if Format = 100 then
          A := ByteAt(3);
      end;
  end;
  Result := Integer((A shl 24) or (Red shl 16) or (Green shl 8) or Blue);
end;

function ConvertPixel(Color: UInt32; Format: Integer; RGBSource: Boolean): Integer;
begin
  var A := Color shr 24;
  var Red := (Color shr 16) and 255;
  var Green := (Color shr 8) and 255;
  var Blue := Color and 255;
  var Luminance := (Red + Green + Blue) div 3;
  if RGBSource then
    A := 255;
  case Format of
    96:
      begin
        if RGBSource then
          A := Luminance;
        Red := 255;
        Green := 255;
        Blue := 255;
      end;
    97, 98:
      begin
        Red := Luminance;
        Green := Red;
        Blue := Red;
        if Format = 97 then
          A := 255;
      end;
    99:
      A := 255;
  end;
  Result := Integer((A shl 24) or (Red shl 16) or (Green shl 8) or Blue);
end;

function M3GNewRasterImage(VM: TJVM; Format, Width, Height: Integer; const Pixels: TArray<UInt32>): Integer;
begin
  Components(VM, Format);
  if (Width <= 0) or (Height <= 0) then
    Invalid(VM, 'image dimensions');
  if Int64(Width) * Height > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'M3G image pixel limit');
  if Length(Pixels) <> Width * Height then
    raise EJVMFormatError.Create('M3G raster image size');
  var PixelRef := VM.NewArray('[I', Length(Pixels));
  var Data := VM.GetObject(PixelRef);
  for var K := 0 to High(Pixels) do
    Data.Elements[K] := TJVMValue.Int(Integer(Pixels[K]));
  Result := VM.NewObject(ImageName);
  var O := VM.GetObject(Result);
  PI(O, 'format', Format);
  PI(O, 'width', Width);
  PI(O, 'height', Height);
  PI(O, 'mutable', 0);
  O.Fields.AddOrSetValue(P + 'pixels', TJVMValue.Ref(PixelRef));
end;

procedure ImageCall(VM: TJVM; O: TJVMObject; const N, D: string; const Args: TArray<TJVMValue>; out Result: TJVMValue);
begin
  if N = 'getWidth' then
  begin
    Result := TJVMValue.Int(I(O, 'width'));
    Exit;
  end;
  if N = 'getHeight' then
  begin
    Result := TJVMValue.Int(I(O, 'height'));
    Exit;
  end;
  if N = 'getFormat' then
  begin
    Result := TJVMValue.Int(I(O, 'format'));
    Exit;
  end;
  if N = 'isMutable' then
  begin
    Result := TJVMValue.Int(I(O, 'mutable'));
    Exit;
  end;
  if N = 'set' then
  begin
    var Data := VM.GetObject(Args[5].AsRef);
    if I(O, 'mutable') = 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'Immutable M3G image');
    var X := Args[1].AsInt;
    var Y := Args[2].AsInt;
    var W := Args[3].AsInt;
    var H := Args[4].AsInt;
    var Format := I(O, 'format');
    var Bpp := Components(VM, Format);
    if (X < 0) or (Y < 0) or (W <= 0) or (H <= 0) or
      (Int64(X) + W > I(O, 'width')) or (Int64(Y) + H > I(O, 'height')) or
      (Int64(W) * H * Bpp > Length(Data.Elements)) then
      Invalid(VM, 'image update bounds/data');
    var Pixels := VM.GetObject(R(O, 'pixels'));
    for var DY := 0 to H - 1 do
      for var DX := 0 to W - 1 do
        Pixels.Elements[(Y + DY) * I(O, 'width') + X + DX] := TJVMValue.Int(ReadPixel(Data, (DY * W + DX) * Bpp, Format));
    Exit;
  end;
  if N <> '<init>' then
    raise EJVMUnsupported.Create(ImageName + '.' + N + D);
  var Format := Args[1].AsInt;
  var Bpp := Components(VM, Format);
  var W, H: Integer;
  var Data, Palette: TJVMObject;
  var Source: TJ2MEImageView;
  var IsMIDP := D = '(ILjava/lang/Object;)V';
  var Mutable := D = '(III)V';
  var Indexed := D = '(III[B[B)V';
  Data := nil;
  Palette := nil;
  if IsMIDP then
  begin
    var Input := VM.GetObject(Args[2].AsRef);
    if not VM.IsAssignable(Input.ClassName, 'javax/microedition/lcdui/Image') then
      Invalid(VM, 'image source type');
    Source := J2MEImageView(VM, Args[2].AsRef);
    W := Source.Width;
    H := Source.Height;
  end
  else
  begin
    W := Args[2].AsInt;
    H := Args[3].AsInt;
    if not Mutable then
      Data := VM.GetObject(Args[4].AsRef);
    if Indexed then
      Palette := VM.GetObject(Args[5].AsRef);
  end;
  if (W <= 0) or (H <= 0) then
    Invalid(VM, 'image dimensions');
  if Int64(W) * H > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'M3G image pixel limit');
  if Data <> nil then
  begin
    var Required := Int64(W) * H;
    if not Indexed then
      Required := Required * Bpp;
    if Required > Length(Data.Elements) then
      Invalid(VM, 'short image data');
    if Indexed and (Length(Palette.Elements) < 256 * Bpp) and (Length(Palette.Elements) mod Bpp <> 0) then
      Invalid(VM, 'partial palette entry');
  end;
  var PixelRef := VM.NewArray('[I', W * H);
  var Pixels := VM.GetObject(PixelRef);
  for var K := 0 to W * H - 1 do
  begin
    var Color := -1;
    if IsMIDP then
      Color := ConvertPixel(UInt32(Source.Pixels.Elements[K].AsInt), Format, Source.Mutable)
    else if Indexed then
    begin
      var Offset := (Data.Elements[K].AsInt and 255) * Bpp;
      // Missing palette entries have unspecified values; choose opaque white.
      if Offset + Bpp <= Min(Length(Palette.Elements), 256 * Bpp) then
        Color := ReadPixel(Palette, Offset, Format);
    end
    else if not Mutable then
      Color := ReadPixel(Data, K * Bpp, Format);
    Pixels.Elements[K] := TJVMValue.Int(Color);
  end;
  PI(O, 'format', Format);
  PI(O, 'width', W);
  PI(O, 'height', H);
  PI(O, 'mutable', Ord(Mutable));
  O.Fields.AddOrSetValue(P + 'pixels', TJVMValue.Ref(PixelRef));
end;

function InvokeM3GTexture(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  var C := Method.Owner.Name;
  if C = ImageName then
  begin
    ImageCall(VM, O, N, Method.Descriptor, Args, Result);
    Exit;
  end;
  if C = TextureName then
  begin
    if (N = '<init>') or (N = 'setImage') then
    begin
      var Image := M3GImageView(VM, Args[1].AsRef);
      var W := Image.Width;
      var H := Image.Height;
      if (W <= 0) or (H <= 0) or ((W and (W - 1)) <> 0) or ((H and (H - 1)) <> 0) or
        (W > M3GMaxTextureDimension) or (H > M3GMaxTextureDimension) then
        Invalid(VM, 'texture dimensions');
      O.Fields.AddOrSetValue(P + 'image', Args[1]);
      Exit;
    end;
    if N = 'getImage' then
      Exit(TJVMValue.Ref(R(O, 'image')));
    if N = 'setBlendColor' then
    begin
      PI(O, 'BlendColor', Args[1].AsInt and $FFFFFF);
      Exit;
    end;
    if N = 'setBlending' then
    begin
      if not (Args[1].AsInt in [224..228]) then
        Invalid(VM, 'texture blending');
      PI(O, 'Blending', Args[1].AsInt);
      Exit;
    end;
    if N = 'setFiltering' then
    begin
      if not (Args[1].AsInt in [208..210]) or not (Args[2].AsInt in [209..210]) then
        Invalid(VM, 'texture filtering');
      PI(O, 'LevelFilter', Args[1].AsInt);
      PI(O, 'ImageFilter', Args[2].AsInt);
      Exit;
    end;
    if N = 'setWrapping' then
    begin
      if not (Args[1].AsInt in [240, 241]) or not (Args[2].AsInt in [240, 241]) then
        Invalid(VM, 'texture wrapping');
      PI(O, 'WrappingS', Args[1].AsInt);
      PI(O, 'WrappingT', Args[2].AsInt);
      Exit;
    end;
    if N.StartsWith('get') then
    begin
      var Key := Copy(N, 4, MaxInt);
      var Fallback := 0;
      if Key = 'Blending' then
        Fallback := 227
      else if Key = 'LevelFilter' then
        Fallback := 208
      else if Key = 'ImageFilter' then
        Fallback := 210
      else if Key.StartsWith('Wrapping') then
        Fallback := 241;
      Exit(TJVMValue.Int(I(O, Key, Fallback)));
    end;
  end;
  if (C = CompositeName) or (C = PolygonName) then
  begin
    if N = '<init>' then
      Exit;
    if N.StartsWith('is') then
      Exit(TJVMValue.Int(I(O, Copy(N, 3, Length(N) - 9), Ord(C = CompositeName))));
    if N.EndsWith('Enable') then
    begin
      PI(O, Copy(N, 4, Length(N) - 9), Ord(Args[1].AsInt <> 0));
      Exit;
    end;
    if N = 'setDepthOffset' then
    begin
      O.Fields.AddOrSetValue(P + 'DepthOffsetFactor', Args[1]);
      O.Fields.AddOrSetValue(P + 'DepthOffsetUnits', Args[2]);
      Exit;
    end;
    if N.StartsWith('get') then
    begin
      var Key := Copy(N, 4, MaxInt);
      if (Key = 'AlphaThreshold') or Key.StartsWith('DepthOffset') then
        Exit(TJVMValue.Float(F(O, Key)));
      var Fallback := 0;
      if Key = 'Blending' then
        Fallback := 68
      else if Key = 'Culling' then
        Fallback := 160
      else if Key = 'Winding' then
        Fallback := 168
      else if Key = 'Shading' then
        Fallback := 165;
      Exit(TJVMValue.Int(I(O, Key, Fallback)));
    end;
    if N = 'setAlphaThreshold' then
    begin
      var Value := Args[1].AsFloat;
      if not ((Value >= 0) and (Value <= 1)) then
        Invalid(VM, 'alpha threshold');
      O.Fields.AddOrSetValue(P + 'AlphaThreshold', Args[1]);
      Exit;
    end;
    var Value := Args[1].AsInt;
    var Valid := False;
    if N = 'setBlending' then
      Valid := Value in [64..68]
    else if N = 'setCulling' then
      Valid := Value in [160..162]
    else if N = 'setShading' then
      Valid := Value in [164, 165]
    else if N = 'setWinding' then
      Valid := Value in [168, 169];
    if not Valid then
      Invalid(VM, 'polygon/compositing mode');
    PI(O, Copy(N, 4, MaxInt), Value);
    Exit;
  end;
  raise EJVMUnsupported.Create(C + '.' + N + Method.Descriptor);
end;

end.

