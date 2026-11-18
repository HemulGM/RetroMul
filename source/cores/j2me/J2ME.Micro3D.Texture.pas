unit J2ME.Micro3D.Texture;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Suite;

procedure InstallJ2MEMicro3DTextures(VM: TJVM);

function J2MEMicro3DTextureHandles(const ClassName: string): Boolean;

function InvokeJ2MEMicro3DTexture(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.Classes, System.Math, System.StrUtils, System.SysUtils, Java.Classes;

const
  Prefix = 'com/mascotcapsule/micro3d/v3/';
  TextureName = Prefix + 'Texture';
  EffectName = Prefix + 'Effect3D';
  TextureType = 'L' + TextureName + ';';
  LightType = 'L' + Prefix + 'Light;';
  TexturePalette = TextureName + '.$palette:[I';
  TextureIndices = TextureName + '.$indices:[B';
  TextureWidth = TextureName + '.$width:I';
  TextureHeight = TextureName + '.$height:I';
  TextureModel = TextureName + '.$model:Z';
  MaxTextureData = 1024 * 1024;
  NormalShading = 0;
  ToonShading = 1;
  EffectLight = EffectName + '.$light:' + LightType;
  EffectSphere = EffectName + '.$sphere:' + TextureType;
  EffectShading = EffectName + '.$shading:I';
  EffectBlend = EffectName + '.$blend:Z';
  EffectThreshold = EffectName + '.$threshold:I';
  EffectHigh = EffectName + '.$high:I';
  EffectLow = EffectName + '.$low:I';

procedure InstallJ2MEMicro3DTextures(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(TextureName, 'java/lang/Object');
  try
    B.Field('$palette', '[I', JVM_ACC_PRIVATE);
    B.Field('$indices', '[B', JVM_ACC_PRIVATE);
    B.Field('$width', 'I', JVM_ACC_PRIVATE);
    B.Field('$height', 'I', JVM_ACC_PRIVATE);
    B.Field('$model', 'Z', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '([BZ)V');
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;Z)V');
    B.JavaClass.AddNative('dispose', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE or JVM_ACC_FINAL;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;

  B := TJavaClassBuilder.Create(EffectName, 'java/lang/Object');
  try
    B.Field('NORMAL_SHADING', 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(NormalShading);
    B.Field('TOON_SHADING', 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(ToonShading);
    B.Field('$light', LightType, JVM_ACC_PRIVATE);
    B.Field('$sphere', TextureType, JVM_ACC_PRIVATE);
    B.Field('$blend', 'Z', JVM_ACC_PRIVATE);
    for var Name in ['$shading', '$threshold', '$high', '$low'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('<init>', '(' + LightType + 'IZ' + TextureType + ')V');
    B.JavaClass.AddNative('getLight', '()' + LightType);
    B.JavaClass.AddNative('setLight', '(' + LightType + ')V');
    for var Name in ['getSphereMap', 'getSphereTexture'] do
      B.JavaClass.AddNative(Name, '()' + TextureType);
    for var Name in ['setSphereMap', 'setSphereTexture'] do
      B.JavaClass.AddNative(Name, '(' + TextureType + ')V');
    for var Name in ['getShading', 'getShadingType', 'getThreshold', 'getThresholdHigh', 'getThresholdLow', 'getToonThreshold', 'getToonHigh', 'getToonLow'] do
      B.JavaClass.AddNative(Name, '()I');
    for var Name in ['setShading', 'setShadingType'] do
      B.JavaClass.AddNative(Name, '(I)V');
    for var Name in ['isTransparency', 'isSemiTransparentEnabled'] do
      B.JavaClass.AddNative(Name, '()Z');
    for var Name in ['setTransparency', 'setSemiTransparentEnabled'] do
      B.JavaClass.AddNative(Name, '(Z)V');
    for var Name in ['setThreshold', 'setToonParams'] do
      B.JavaClass.AddNative(Name, '(III)V');
    for var Method in B.JavaClass.Methods do
      if Method.Name <> '<init>' then
        Method.Access := Method.Access or JVM_ACC_FINAL;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function J2MEMicro3DTextureHandles(const ClassName: string): Boolean;
begin
  Result := (ClassName = TextureName) or (ClassName = EffectName);
end;

procedure DecodeTexture(VM: TJVM; O: TJVMObject; const Data: TBytes; ForModel: Boolean);

  function WordAt(Offset: Integer): Word;
  begin
    Result := Word(Data[Offset]) or (Word(Data[Offset + 1]) shl 8);
  end;

  function LongAt(Offset: Integer): Cardinal;
  begin
    Result := Cardinal(WordAt(Offset)) or (Cardinal(WordAt(Offset + 2)) shl 16);
  end;

  procedure Require(Condition: Boolean; const What: string);
  begin
    if not Condition then
      VM.RaiseJava('java/lang/RuntimeException', 'Micro3D texture: ' + What);
  end;

begin
  Require((Length(Data) >= 54) and (Length(Data) <= MaxTextureData), 'invalid BMP length');
  Require((WordAt(0) = $4D42) and (WordAt(26) = 1) and (WordAt(28) = 8) and
    (LongAt(30) = 0), 'expected an uncompressed 8-bit BMP');

  var DeclaredSize := LongAt(2);
  var PixelsAt := LongAt(10);
  var DIBSize := LongAt(14);
  Require((DIBSize >= 40) and (DIBSize <= DeclaredSize - Int64(14)) and
    (PixelsAt >= Int64(DIBSize) + 14) and (PixelsAt <= DeclaredSize) and
    (DeclaredSize <= Cardinal(Length(Data))), 'invalid BMP header or pixel offset');

  var W := Integer(LongAt(18));
  var H := Integer(LongAt(22));
  Require(InRange(W, 1, 256) and InRange(H, -256, 256) and (H <> 0), 'invalid dimensions');
  var Height := Abs(H);
  Require(ForModel or ((W = 64) and (Height = 64)), 'environment textures must be 64x64');
  var Stride := (W + 3) and not 3;
  Require(Int64(PixelsAt) + Stride * Height <= DeclaredSize, 'truncated pixel data');

  var PaletteAt := Integer(DIBSize) + 14;
  var AvailableColors := (Integer(PixelsAt) - PaletteAt) div 4;
  var DeclaredColors := LongAt(46);
  Require((DeclaredColors <= 256) and (AvailableColors > 0), 'invalid palette size');
  var ColorCount := Integer(DeclaredColors);
  if ColorCount = 0 then
    ColorCount := Min(256, AvailableColors);
  Require(ColorCount <= AvailableColors, 'truncated palette');

  var Palette := VM.NewArray('[I', ColorCount);
  var Colors := VM.GetObject(Palette);
  for var I := 0 to ColorCount - 1 do
    Colors.ElementValues[I] := TJVMValue.Int(Integer(LongAt(PaletteAt + I * 4) or $FF000000));
  var Indices := VM.NewArray('[B', W * Height);
  var Rows := VM.GetObject(Indices);
  for var Y := 0 to Height - 1 do
  begin
    var SourceRow := Y;
    if H > 0 then
      SourceRow := Height - 1 - Y;
    var Offset := Integer(PixelsAt) + SourceRow * Stride;
    for var X := 0 to W - 1 do
    begin
      var Value := Data[Offset + X];
      Require(Value < ColorCount, 'pixel index outside palette');
      Rows.ElementValues[Y * W + X] := TJVMValue.Int(ShortInt(Value));
    end;
  end;

  // Retain palette indices so the renderer can distinguish the color key
  // even when two palette entries have the same RGB value.
  O.Fields[TexturePalette] := TJVMValue.Ref(Palette);
  O.Fields[TextureIndices] := TJVMValue.Ref(Indices);
  O.Fields[TextureWidth] := TJVMValue.Int(W);
  O.Fields[TextureHeight] := TJVMValue.Int(Height);
  O.Fields[TextureModel] := TJVMValue.Int(Ord(ForModel));
end;

procedure InitTexture(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; O: TJVMObject; const Args: TArray<TJVMValue>);
begin
  var Input := VM.GetObject(Args[1].AsRef);
  var Data: TBytes;
  if Method.Descriptor = '([BZ)V' then
  begin
    if Input.ElementCount > MaxTextureData then
      VM.RaiseJava('java/lang/RuntimeException', 'Micro3D texture exceeds the decoder limit');
    SetLength(Data, Input.ElementCount);
    for var I := 0 to High(Data) do
      Data[I] := Byte(Input.ElementValues[I].AsInt and $FF);
  end
  else
  begin
    var Name := Input.Text;
    if (Name = '') or not Suite.HasResource(Name) then
      VM.RaiseJava('java/io/IOException', 'Missing texture: ' + Name);
    try
      Data := Suite.ReadResource(Name);
    except
      on E: EStreamError do
        VM.RaiseJava('java/io/IOException', E.Message);
    end;
  end;

  DecodeTexture(VM, O, Data, Args[2].AsInt <> 0);
end;

function InvokeEffect(VM: TJVM; O: TJVMObject; const Name: string; const Args: TArray<TJVMValue>): TJVMValue;

  procedure CheckSphere(Value: TJVMValue);
  begin
    if (Value.AsRef <> 0) and (VM.GetObject(Value.AsRef).Fields[TextureModel].AsInt <> 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Expected an environment texture');
  end;

  procedure CheckShading(Value: TJVMValue);
  begin
    if not InRange(Value.AsInt, NormalShading, ToonShading) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Shading mode');
  end;

begin
  Result := Default(TJVMValue);
  if Name = '<init>' then
  begin
    if Length(Args) = 1 then
      O.Fields[EffectBlend] := TJVMValue.Int(1)
    else
    begin
      CheckShading(Args[2]);
      CheckSphere(Args[4]);
      O.Fields[EffectLight] := Args[1];
      O.Fields[EffectShading] := Args[2];
      O.Fields[EffectBlend] := Args[3];
      O.Fields[EffectSphere] := Args[4];
    end;
    Exit;
  end;
  if Name = 'getLight' then
    Exit(O.Fields[EffectLight]);
  if Name = 'setLight' then
  begin
    O.Fields[EffectLight] := Args[1];
    Exit;
  end;
  if MatchStr(Name, ['getSphereMap', 'getSphereTexture']) then
    Exit(O.Fields[EffectSphere]);
  if MatchStr(Name, ['setSphereMap', 'setSphereTexture']) then
  begin
    CheckSphere(Args[1]);
    O.Fields[EffectSphere] := Args[1];
    Exit;
  end;
  if MatchStr(Name, ['getShading', 'getShadingType']) then
    Exit(O.Fields[EffectShading]);
  if MatchStr(Name, ['setShading', 'setShadingType']) then
  begin
    CheckShading(Args[1]);
    O.Fields[EffectShading] := Args[1];
    Exit;
  end;
  if MatchStr(Name, ['getThreshold', 'getToonThreshold']) then
    Exit(O.Fields[EffectThreshold]);
  if MatchStr(Name, ['getThresholdHigh', 'getToonHigh']) then
    Exit(O.Fields[EffectHigh]);
  if MatchStr(Name, ['getThresholdLow', 'getToonLow']) then
    Exit(O.Fields[EffectLow]);
  if MatchStr(Name, ['setThreshold', 'setToonParams']) then
  begin
    for var I := 1 to 3 do
      if not InRange(Args[I].AsInt, 0, 255) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Toon parameter');
    O.Fields[EffectThreshold] := Args[1];
    O.Fields[EffectHigh] := Args[2];
    O.Fields[EffectLow] := Args[3];
    Exit;
  end;
  if MatchStr(Name, ['isTransparency', 'isSemiTransparentEnabled']) then
    Exit(O.Fields[EffectBlend]);
  if MatchStr(Name, ['setTransparency', 'setSemiTransparentEnabled']) then
  begin
    O.Fields[EffectBlend] := Args[1];
    Exit;
  end;
  raise EJVMUnsupported.Create(EffectName + '.' + Name);
end;

function InvokeJ2MEMicro3DTexture(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  var O := VM.GetObject(Args[0].AsRef);
  if Method.Owner.Name = EffectName then
    Exit(InvokeEffect(VM, O, Method.Name, Args));
  Result := Default(TJVMValue);
  if Method.Name = '<init>' then
  begin
    InitTexture(VM, Suite, Method, O, Args);
    Exit;
  end;
  if Method.Name = 'dispose' then
  begin
    O.Fields[TexturePalette] := TJVMValue.Ref(0);
    O.Fields[TextureIndices] := TJVMValue.Ref(0);
    O.Fields[TextureWidth] := TJVMValue.Int(0);
    O.Fields[TextureHeight] := TJVMValue.Int(0);
    Exit;
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + Method.Name);
end;

end.

