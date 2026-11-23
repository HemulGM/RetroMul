unit J2ME.M3G.Environment;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Raster;

procedure InstallM3GEnvironment(VM: TJVM);

function M3GEnvironmentHandles(const Name: string): Boolean;

function InvokeM3GEnvironment(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GEnvironmentReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

procedure M3GClearBackground(VM: TJVM; Ref: Integer; const Target: TM3GRasterTarget; var HostPixels: TArray<UInt32>);

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.M3G.Texture;

const
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';
  BackgroundName = Base + 'Background';
  FogName = Base + 'Fog';

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if (O <> nil) and O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if (O <> nil) and O.Fields.TryGetValue(P + Key, V) then
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

procedure PI(O: TJVMObject; const Key: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(Value));
end;

procedure Invalid(VM: TJVM; const What: string);
begin
  VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G ' + What);
end;

function M3GEnvironmentHandles(const Name: string): Boolean;
begin
  Result := (Name = BackgroundName) or (Name = FogName);
end;

function M3GEnvironmentReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, BackgroundName) and (R(O, 'image') <> 0) then
    Result := [R(O, 'image')];
end;

procedure InstallM3GEnvironment(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(BackgroundName, Base + 'Object3D');
  try
    Constant('BORDER', 32);
    Constant('REPEAT', 33);
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('getColor', '()I');
    B.JavaClass.AddNative('setColor', '(I)V');
    B.JavaClass.AddNative('setImage', '(Ljavax/microedition/m3g/Image2D;)V');
    B.JavaClass.AddNative('getImage', '()Ljavax/microedition/m3g/Image2D;');
    B.JavaClass.AddNative('setImageMode', '(II)V');
    B.JavaClass.AddNative('setCrop', '(IIII)V');
    for var Name in ['ImageModeX', 'ImageModeY', 'CropX', 'CropY', 'CropWidth', 'CropHeight'] do
      B.JavaClass.AddNative('get' + Name, '()I');
    for var Name in ['Color', 'Depth'] do
    begin
      B.JavaClass.AddNative('set' + Name + 'ClearEnable', '(Z)V');
      B.JavaClass.AddNative('is' + Name + 'ClearEnabled', '()Z');
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(FogName, Base + 'Object3D');
  try
    Constant('EXPONENTIAL', 80);
    Constant('LINEAR', 81);
    B.JavaClass.AddNative('<init>', '()V');
    for var Name in ['Color', 'Mode'] do
    begin
      B.JavaClass.AddNative('get' + Name, '()I');
      B.JavaClass.AddNative('set' + Name, '(I)V');
    end;
    B.JavaClass.AddNative('setDensity', '(F)V');
    B.JavaClass.AddNative('setLinear', '(FF)V');
    for var Name in ['Density', 'NearDistance', 'FarDistance'] do
      B.JavaClass.AddNative('get' + Name, '()F');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeM3GEnvironment(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = '<init>' then
    Exit;
  if N = 'getColor' then
    Exit(TJVMValue.Int(I(O, 'color')));
  if N = 'setColor' then
  begin
    var Color := Args[1].AsInt;
    if Method.Owner.Name = FogName then
      Color := Color and $FFFFFF;
    PI(O, 'color', Color);
    Exit;
  end;
  if Method.Owner.Name = BackgroundName then
  begin
    if N = 'getImage' then
      Exit(TJVMValue.Ref(R(O, 'image')));
    if N = 'setImage' then
    begin
      var W := 0;
      var H := 0;
      if Args[1].AsRef <> 0 then
      begin
        var Image := M3GImageView(VM, Args[1].AsRef);
        if (Image.Format <> 99) and (Image.Format <> 100) then
          Invalid(VM, 'background image format');
        W := Image.Width;
        H := Image.Height;
      end;
      O.Fields.AddOrSetValue(P + 'image', Args[1]);
      PI(O, 'cropX', 0);
      PI(O, 'cropY', 0);
      PI(O, 'cropWidth', W);
      PI(O, 'cropHeight', H);
      Exit;
    end;
    if N = 'setCrop' then
    begin
      if (Args[3].AsInt < 0) or (Args[4].AsInt < 0) then
        Invalid(VM, 'background crop dimensions');
      PI(O, 'cropX', Args[1].AsInt);
      PI(O, 'cropY', Args[2].AsInt);
      PI(O, 'cropWidth', Args[3].AsInt);
      PI(O, 'cropHeight', Args[4].AsInt);
      Exit;
    end;
    if N = 'setImageMode' then
    begin
      var X := Args[1].AsInt;
      var Y := Args[2].AsInt;
      if ((X <> 32) and (X <> 33)) or ((Y <> 32) and (Y <> 33)) then
        Invalid(VM, 'background image mode');
      PI(O, 'modeX', X);
      PI(O, 'modeY', Y);
      Exit;
    end;
    if N.StartsWith('getImageMode') then
      Exit(TJVMValue.Int(I(O, 'mode' + Copy(N, 13, 1), 32)));
    if N.StartsWith('getCrop') then
      Exit(TJVMValue.Int(I(O, 'crop' + Copy(N, 8, MaxInt))));
    if N.StartsWith('is') then
      Exit(TJVMValue.Int(I(O, LowerCase(Copy(N, 3, 1)) + Copy(N, 4, Length(N) - 10), 1)));
    if N.StartsWith('set') and N.EndsWith('Enable') then
    begin
      PI(O, LowerCase(Copy(N, 4, 1)) + Copy(N, 5, Length(N) - 10), Ord(Args[1].AsInt <> 0));
      Exit;
    end;
  end
  else
  begin
    if N = 'getMode' then
      Exit(TJVMValue.Int(I(O, 'mode', 81)));
    if N = 'setMode' then
    begin
      var Mode := Args[1].AsInt;
      if (Mode <> 80) and (Mode <> 81) then
        Invalid(VM, 'fog mode');
      PI(O, 'mode', Mode);
      Exit;
    end;
    if N = 'getDensity' then
      Exit(TJVMValue.Float(F(O, 'density', 1)));
    if N = 'getNearDistance' then
      Exit(TJVMValue.Float(F(O, 'near')));
    if N = 'getFarDistance' then
      Exit(TJVMValue.Float(F(O, 'far', 1)));
    if N = 'setDensity' then
    begin
      if not (Args[1].AsFloat >= 0) then
        Invalid(VM, 'fog density');
      O.Fields.AddOrSetValue(P + 'density', Args[1]);
      Exit;
    end;
    if N = 'setLinear' then
    begin
      O.Fields.AddOrSetValue(P + 'near', Args[1]);
      O.Fields.AddOrSetValue(P + 'far', Args[2]);
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N + Method.Descriptor);
end;

procedure M3GClearBackground(VM: TJVM; Ref: Integer; const Target: TM3GRasterTarget; var HostPixels: TArray<UInt32>);
begin
  var O: TJVMObject := nil;
  if Ref <> 0 then
    O := VM.GetObject(Ref);
  var ClearColor := I(O, 'colorClear', 1) <> 0;
  var ClearDepth := Target.DepthEnabled and (I(O, 'depthClear', 1) <> 0);
  var CropW := I(O, 'cropWidth');
  var CropH := I(O, 'cropHeight');
  var BaseColor := UInt32(I(O, 'color'));
  var CropX := Int64(I(O, 'cropX'));
  var CropY := Int64(I(O, 'cropY'));
  var RepeatX := I(O, 'modeX', 32) = 33;
  var RepeatY := I(O, 'modeY', 32) = 33;
  var ViewX := Trunc(Target.ViewX);
  var ViewY := Trunc(Target.ViewY);
  var ViewW := Trunc(Target.ViewWidth);
  var ViewH := Trunc(Target.ViewHeight);
  var ImageRef := R(O, 'image');
  var Image: TM3GImageView;
  var Snapshot: TArray<UInt32> := nil;
  if ImageRef <> 0 then
  begin
    Image := M3GImageView(VM, ImageRef);
    var ExpectedFormat := 99;
    if Target.PreserveAlpha then
      ExpectedFormat := 100;
    if Image.Format <> ExpectedFormat then
      Invalid(VM, 'background/target format mismatch');
    if (Target.Pixels = Image.Pixels) and ClearColor and (CropW > 0) and (CropH > 0) then
    begin
      SetLength(Snapshot, Length(Image.Pixels.Elements));
      for var K := 0 to High(Snapshot) do
        Snapshot[K] := UInt32(Image.Pixels.Elements[K].AsInt);
    end;
  end;
  if not ClearColor and not ClearDepth then
    Exit;
  for var Y := Target.Top to Target.Bottom - 1 do
  begin
    if VM.StopRequested then
      Exit;
    for var X := Target.Left to Target.Right - 1 do
    begin
      var Index := Y * Target.Width + X;
      if ClearColor then
      begin
        var Color := BaseColor;
        if (ImageRef <> 0) and (CropW > 0) and (CropH > 0) then
        begin
          // Integer pixel-center mapping avoids precision loss with extreme
          // crop offsets/sizes. Projection uses the full, unclipped viewport.
          var SX := CropX + ((2 * (Int64(X) - ViewX) + 1) * CropW div (2 * ViewW));
          var SY := CropY + ((2 * (Int64(Y) - ViewY) + 1) * CropH div (2 * ViewH));
          if RepeatX then
            SX := ((SX mod Image.Width) + Image.Width) mod Image.Width;
          if RepeatY then
            SY := ((SY mod Image.Height) + Image.Height) mod Image.Height;
          if (SX >= 0) and (SY >= 0) and (SX < Image.Width) and (SY < Image.Height) then
          begin
            var Source := Integer(SY) * Image.Width + Integer(SX);
            if Snapshot <> nil then
              Color := Snapshot[Source]
            else
              Color := UInt32(Image.Pixels.Elements[Source].AsInt);
          end;
        end;
        if not Target.PreserveAlpha then
          Color := Color or $FF000000;
        if Target.Pixels <> nil then
          Target.Pixels.Elements[Index] := TJVMValue.Int(Integer(Color))
        else
          HostPixels[Index] := Color;
      end;
      if ClearDepth then
        Target.Depth.Elements[Index] := TJVMValue.Float(1);
    end;
  end;
end;

end.

