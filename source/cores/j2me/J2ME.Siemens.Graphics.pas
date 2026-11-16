unit J2ME.Siemens.Graphics;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MESiemensGraphics(VM: TJVM);

function HandlesJ2MESiemensGraphics(const Owner: string): Boolean;

function InvokeJ2MESiemensGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Screen: TArray<UInt32>; ScreenWidth, ScreenHeight: Integer; out Flushed: Boolean): TJVMValue;

implementation

uses
  System.SysUtils, System.Classes, System.Math, Java.Classes, J2ME.Image,
  J2ME.Graphics;

{$Q-}{$R-}

const
  Base = 'com/siemens/mp/game/';
  ExtendedName = Base + 'ExtendedImage';
  ObjectName = Base + 'GraphicObject';
  ManagerName = Base + 'GraphicObjectManager';
  SpriteName = Base + 'Sprite';
  TilesName = Base + 'TiledBackground';
  NativeMem = 'com/siemens/mp/misc/NativeMem';
  UIName = 'com/siemens/mp/ui/Image';
  ImageName = 'javax/microedition/lcdui/Image';
  ImageD = 'Ljavax/microedition/lcdui/Image;';
  ExtendedD = 'Lcom/siemens/mp/game/ExtendedImage;';
  ObjectD = 'Lcom/siemens/mp/game/GraphicObject;';
  UID = 'Lcom/siemens/mp/ui/Image;';
  Key = '$siemens.gfx.';

function Get(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Key + Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function Ref(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Key + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Key + Name, TJVMValue.Int(Value));
end;

procedure PutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Key + Name, TJVMValue.Ref(Value));
end;

function Cancelled(VM: TJVM): Boolean;
begin
  var Executor := TThread.CurrentThread;
  if not Executor.ExternalThread then
    if Executor.CheckTerminated then
      VM.RequestStop;
  Result := VM.StopRequested;
end;

procedure Dimensions(VM: TJVM; W, H: Integer);
begin
  if (W <= 0) or (H <= 0) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens image dimensions');
  if Int64(W) * H > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Siemens pixel limit');
end;

function HasAlpha(const I: TJ2MEImageView): Boolean;
begin
  for var P in I.Pixels.Elements do
    if UInt32(P.AsInt) shr 24 <> 255 then
      Exit(True);
  Result := False;
end;

function Packing(const I: TJ2MEImageView): Integer;
var
  V: TJVMValue;
begin
  if I.Image.Fields.TryGetValue('$siemens.bpp', V) and (V.AsInt in [1, 2]) then
    Exit(V.AsInt);
  Result := 1;
  if HasAlpha(I) then
    Result := 2;
  I.Image.Fields.AddOrSetValue('$siemens.bpp', TJVMValue.Int(Result));
end;

function PixelColor(Code, BPP: Integer): UInt32;
begin
  if BPP = 1 then
  begin
    if Code = 0 then
      Exit($FFFFFFFF);
    Exit($FF000000);
  end;
  case Code of
    0:
      Result := 0;
    1:
      Result := $FFFFFFFF;
  else
    Result := $FF000000;
  end;
end;

function ColorCode(Pixel: UInt32; BPP: Integer): Integer;
begin
  if (BPP = 2) and (Pixel shr 24 < 128) then
    Exit(0);
  var Luma := (Pixel shr 16 and 255) * 299 + (Pixel shr 8 and 255) * 587 + (Pixel and 255) * 114;
  Result := Ord(Luma < 128000);
  if BPP = 2 then
    Inc(Result);
end;

function ReadRaw(Data: TJVMObject; Stride, X, Y, BPP: Integer): Integer;
begin
  Result := (Data.ElementValues[Y * Stride + X * BPP div 8].AsInt shr (8 - BPP - (X * BPP and 7))) and ((1 shl BPP) - 1);
end;

procedure WriteRaw(Data: TJVMObject; Stride, X, Y, BPP, Code: Integer);
begin
  var Index := Y * Stride + X * BPP div 8;
  var Shift := 8 - BPP - (X * BPP and 7);
  var Value := Byte(Data.ElementValues[Index].AsInt);
  Value := (Value and not (((1 shl BPP) - 1) shl Shift)) or (Code shl Shift);
  Data.ElementValues[Index] := TJVMValue.Int(ShortInt(Value));
end;

function Shadow(VM: TJVM; const I: TJ2MEImageView; Create: Boolean): TJVMObject;
var
  V: TJVMValue;
begin
  Result := nil;
  if I.Image.Fields.TryGetValue('$siemens.raw2', V) then
    Exit(VM.GetObject(V.AsRef));
  if not Create then
    Exit;
  var Stride := (I.Width + 3) div 4;
  var R := VM.NewArray('[B', Stride * I.Height);
  Result := VM.GetObject(R);
  for var Y := 0 to I.Height - 1 do
    for var X := 0 to I.Width - 1 do
      WriteRaw(Result, Stride, X, Y, 2, ColorCode(UInt32(I.Pixels.ElementValues[Y * I.Width + X].AsInt), 2));
  I.Image.Fields.AddOrSetValue('$siemens.raw2', TJVMValue.Ref(R));
end;

function ReadCode(VM: TJVM; const I: TJ2MEImageView; X, Y, BPP: Integer): Integer;
begin
  var Pixel := UInt32(I.Pixels.ElementValues[Y * I.Width + X].AsInt);
  Result := ColorCode(Pixel, BPP);
  if BPP <> 2 then
    Exit;
  var Raw := Shadow(VM, I, False);
  if Raw = nil then
    Exit;
  var Previous := ReadRaw(Raw, (I.Width + 3) div 4, X, Y, 2);
  if PixelColor(Previous, 2) = Pixel then
    Result := Previous
  else
    WriteRaw(Raw, (I.Width + 3) div 4, X, Y, 2, Result);
end;

procedure WriteCode(VM: TJVM; const I: TJ2MEImageView; X, Y, BPP, Code: Integer);
begin
  var Raw: TJVMObject := nil;
  if BPP = 2 then
    Raw := Shadow(VM, I, True);
  I.Pixels.ElementValues[Y * I.Width + X] := TJVMValue.Int(Integer(PixelColor(Code, BPP)));
  if Raw <> nil then
    WriteRaw(Raw, (I.Width + 3) div 4, X, Y, 2, Code);
end;

function Bitmap(VM: TJVM; Data: TJVMObject; W, H, BPP: Integer): Integer;
begin
  if BPP = 1 then
    Exit(J2MENewBitmapImage(VM, Data, W, H));
  Dimensions(VM, W, H);
  var Stride := (W + 3) div 4;
  var Count := Stride * H;
  if Count > Data.ElementCount then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  var Pixels: TArray<UInt32>;
  SetLength(Pixels, W * H);
  for var Y := 0 to H - 1 do
    for var X := 0 to W - 1 do
      Pixels[Y * W + X] := PixelColor(ReadRaw(Data, Stride, X, Y, 2), 2);
  Result := J2MENewRasterImage(VM, W, H, Pixels, False);
  var O := VM.GetObject(Result);
  O.Fields.AddOrSetValue('$siemens.bpp', TJVMValue.Int(2));
  var R := VM.NewArray('[B', Count);
  var A := VM.GetObject(R);
  for var I := 0 to Count - 1 do
    A.ElementValues[I] := Data.ElementValues[I];
  O.Fields.AddOrSetValue('$siemens.raw2', TJVMValue.Ref(R));
end;

function RGB332(VM: TJVM; Data: TJVMObject; W, H, Format: Integer): Integer;
begin
  if Format <> 5 then
    VM.RaiseJava('java/io/IOException', 'Unsupported Siemens color bitmap type');
  if (W <= 0) or (H <= 0) then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  Dimensions(VM, W, H);
  if Int64(W) * H > Data.ElementCount then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  var Pixels: TArray<UInt32>;
  SetLength(Pixels, W * H);
  for var I := 0 to High(Pixels) do
  begin
    var V := Byte(Data.ElementValues[I].AsInt);
    if V = $C0 then
      Pixels[I] := 0
    else
      Pixels[I] := $FF000000 or
        (UInt32(((V shr 5) * 255 + 3) div 7) shl 16) or
        (UInt32((((V shr 2) and 7) * 255 + 3) div 7) shl 8) or UInt32((V and 3) * 85);
  end;
  Result := J2MENewRasterImage(VM, W, H, Pixels, False);
end;

function Unwrap(VM: TJVM; Reference: Integer; Extended: Boolean): Integer;
begin
  Result := Reference;
  if Extended then
    Result := Ref(VM.GetObject(Reference), 'image');
  J2MEImageView(VM, Result);
end;

function CopyImage(VM: TJVM; Reference: Integer): Integer;
begin
  var I := J2MEImageView(VM, Reference);
  var Pixels: TArray<UInt32>;
  SetLength(Pixels, I.Width * I.Height);
  for var P := 0 to High(Pixels) do
    Pixels[P] := UInt32(I.Pixels.ElementValues[P].AsInt);
  Result := J2MENewRasterImage(VM, I.Width, I.Height, Pixels, I.Mutable);
  var O := VM.GetObject(Result);
  O.Fields.AddOrSetValue('$siemens.bpp', TJVMValue.Int(Packing(I)));
  var Raw := Shadow(VM, I, False);
  if Raw <> nil then
  begin
    var R := VM.NewArray('[B', Raw.ElementCount);
    var A := VM.GetObject(R);
    for var P := 0 to (Raw.ElementCount - 1) do
      A.ElementValues[P] := Raw.ElementValues[P];
    O.Fields.AddOrSetValue('$siemens.raw2', TJVMValue.Ref(R));
  end;
end;

procedure Opaque(VM: TJVM; const I: TJ2MEImageView);
var
  V: TJVMValue;
begin
  if (I.Image.Fields.TryGetValue('$siemens.bpp', V) and (V.AsInt = 2)) or HasAlpha(I) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens scene requires an image without transparency');
end;

procedure ValidateMap(VM: TJVM; O: TJVMObject);
begin
  var Map := VM.GetObject(Ref(O, 'map'));
  var Limit := Get(O, 'tiles') + 2;
  for var V in Map.Elements do
    if (V.AsInt and 255) > Limit then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens tile index');
end;

function Modulo(Value: Int64; Divisor: Integer): Integer;
begin
  Result := Integer(Value mod Divisor);
  if Result < 0 then
    Inc(Result, Divisor);
end;

procedure PaintObject(VM: TJVM; O: TJVMObject; const Target: TJ2MEImageView; OriginX, OriginY: Integer);
var
  Source, Mask: TJ2MEImageView;
  Pixels, Masks: TArray<TJVMValue>;

  procedure Bind;
  begin
    Source := J2MEImageView(VM, Ref(O, 'pixels'));
    Pixels := Source.Pixels.Elements;
    if Source.Pixels = Target.Pixels then
      Pixels := Copy(Pixels);
    if Ref(O, 'mask') <> 0 then
    begin
      Mask := J2MEImageView(VM, Ref(O, 'mask'));
      Masks := Mask.Pixels.Elements;
      if Mask.Pixels = Target.Pixels then
        Masks := Copy(Masks);
    end;
  end;

  procedure Draw(Dest, Src: Integer);
  begin
    if (Length(Masks) <> 0) and (ColorCode(UInt32(Masks[Src].AsInt), 1) = 0) then
      Exit;
    Target.Pixels.ElementValues[Dest] := TJVMValue.Int(Integer(J2MECompositeColor(
            UInt32(Target.Pixels.ElementValues[Dest].AsInt), UInt32(Pixels[Src].AsInt))));
  end;

begin
  if Get(O, 'visible', 1) = 0 then
    Exit;
  if VM.IsAssignable(O.ClassName, SpriteName) then
  begin
    Bind;
    var X := Int64(OriginX) + Get(O, 'x');
    var Y := Int64(OriginY) + Get(O, 'y');
    var Left := Max(Int64(0), Max(Int64(OriginX), X));
    var Top := Max(Int64(0), Max(Int64(OriginY), Y));
    var Right := Min(Int64(Target.Width), X + Get(O, 'w'));
    var Bottom := Min(Int64(Target.Height), Y + Get(O, 'h'));
    if (Left >= Right) or (Top >= Bottom) then
      Exit;
    var FrameY := Get(O, 'frame') * Get(O, 'h');
    for var DY := Integer(Top) to Integer(Bottom) - 1 do
    begin
      if Cancelled(VM) then
        Exit;
      for var DX := Integer(Left) to Integer(Right) - 1 do
        Draw(DY * Target.Width + DX, (FrameY + Integer(DY - Y)) * Source.Width + Integer(DX - X));
    end;
  end
  else if VM.IsAssignable(O.ClassName, TilesName) then
  begin
    if Ref(O, 'pixels') <> 0 then
      Bind;
    var Map := VM.GetObject(Ref(O, 'map'));
    var W := Get(O, 'cols');
    var H := Get(O, 'rows');
    for var DY := Max(0, OriginY) to Target.Height - 1 do
    begin
      if Cancelled(VM) then
        Exit;
      var SY := Modulo(Int64(DY) - OriginY + Get(O, 'mapY'), H * 8);
      for var DX := Max(0, OriginX) to Target.Width - 1 do
      begin
        var SX := Modulo(Int64(DX) - OriginX + Get(O, 'mapX'), W * 8);
        var Tile := Map.ElementValues[(SY div 8) * W + SX div 8].AsInt and 255;
        case Tile of
          0:
            Continue;
          1:
            Target.Pixels.ElementValues[DY * Target.Width + DX] := TJVMValue.Int(-1);
          2:
            Target.Pixels.ElementValues[DY * Target.Width + DX] := TJVMValue.Int(Integer($FF000000));
        else
          Draw(DY * Target.Width + DX, ((Tile - 3) * 8 + SY mod 8) * 8 + SX mod 8);
        end;
      end;
    end;
  end;
end;

procedure InstallJ2MESiemensGraphics(VM: TJVM);
var
  C: TJVMClass;

  function Add(const Name, Parent: string): TJVMClass;
  begin
    Result := TJVMClass.Create;
    Result.Name := Name;
    Result.SuperName := Parent;
    VM.DefineClass(Result);
  end;

begin
  C := Add(ExtendedName, NativeMem);
  C.AddNative('<init>', '(' + ImageD + ')V');
  C.AddNative('getImage', '()' + ImageD);
  C.AddNative('setPixel', '(IIB)V');
  C.AddNative('getPixel', '(II)I');
  C.AddNative('setPixels', '([BIIII)V');
  C.AddNative('getPixelBytes', '([BIIII)V');
  C.AddNative('clear', '(B)V');
  C.AddNative('blitToScreen', '(II)V');
  C := Add(ObjectName, NativeMem);
  C.AddNative('<init>', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
  C.AddNative('setVisible', '(Z)V');
  C.AddNative('getVisible', '()Z');
  C := Add(SpriteName, ObjectName);
  C.AddNative('<init>', '(' + ImageD + ImageD + 'I)V');
  C.AddNative('<init>', '(' + ExtendedD + ExtendedD + 'I)V');
  C.AddNative('<init>', '([BIII[BII)V');
  C.AddNative('setPosition', '(II)V');
  C.AddNative('getXPosition', '()I');
  C.AddNative('getYPosition', '()I');
  C.AddNative('setCollisionRectangle', '(IIII)V');
  C.AddNative('isCollidingWithPos', '(II)Z');
  C.AddNative('isCollidingWith', '(Lcom/siemens/mp/game/Sprite;)Z');
  C.AddNative('setFrame', '(I)V');
  C.AddNative('getFrame', '()I');
  C := Add(TilesName, ObjectName);
  C.AddNative('<init>', '(' + ImageD + ImageD + '[BII)V');
  C.AddNative('<init>', '(' + ExtendedD + ExtendedD + '[BII)V');
  C.AddNative('<init>', '([B[B[BII)V');
  C.AddNative('setPositionInMap', '(II)V');
  C := Add(ManagerName, NativeMem);
  C.AddNative('<init>', '()V');
  C.AddNative('addObject', '(' + ObjectD + ')V');
  C.AddNative('insertObject', '(' + ObjectD + 'I)V');
  C.AddNative('getObjectPosition', '(' + ObjectD + ')I');
  C.AddNative('getObjectAt', '(I)' + ObjectD);
  C.AddNative('deleteObject', '(I)V');
  C.AddNative('deleteObject', '(' + ObjectD + ')V');
  C.AddNative('paint', '(' + ImageD + 'II)V');
  C.AddNative('paint', '(' + ExtendedD + 'II)V');
  C.AddNative('createTextureBits', '(II[B)[B', True);
  C := Add(UIName, NativeMem);
  var F := TJVMField.Create;
  F.Name := 'COLOR_BMP_8BIT';
  F.Descriptor := 'I';
  F.Access := JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL;
  F.Value := TJVMValue.Int(5);
  C.Fields.Add(F);
  C.AddNative('<init>', '()V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
  for var D in ['(II)V', '(' + UID + ')V', '([BII)V', '([BIIZ)V', '(Ljava/lang/String;Z)V', '([B)V', '([BIII)V'] do
    C.AddNative('<init>', D);
  C.AddNative('getWidth', '()I');
  C.AddNative('getHeight', '()I');
  C.AddNative('createImageWithScaling', '(Ljava/lang/String;)' + ImageD, True);
  C.AddNative('createImageWithoutScaling', '(Ljava/lang/String;)' + ImageD, True);
  C.AddNative('createImageFromBitmap', '([BII)' + ImageD, True);
  C.AddNative('createTransparentImageFromBitmap', '([BII)' + ImageD, True);
  C.AddNative('createRGBImage', '([BIII)' + ImageD, True);
  C.AddNative('mirrorImageHorizontally', '(' + ImageD + ')V', True);
  C.AddNative('mirrorImageVertically', '(' + ImageD + ')V', True);
  C.AddNative('getNativeImage', '(' + ImageD + ')' + UID, True);
  C.AddNative('setNativeImage', '(' + ImageD + UID + ')V', True).Access := JVM_ACC_PROTECTED or JVM_ACC_STATIC or JVM_ACC_NATIVE;
end;

function HandlesJ2MESiemensGraphics(const Owner: string): Boolean;
begin
  Result := (Owner = ExtendedName) or (Owner = ObjectName) or (Owner = ManagerName) or
    (Owner = SpriteName) or (Owner = TilesName) or (Owner = UIName);
end;

function InvokeJ2MESiemensGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Screen: TArray<UInt32>; ScreenWidth, ScreenHeight: Integer; out Flushed: Boolean): TJVMValue;
var
  O, A: TJVMObject;
  I, P, Mask: TJ2MEImageView;
  N, C, D: string;
  R, BPP: Integer;

  function Arg(Index: Integer): Integer;
  begin
    Result := Args[Index].AsInt;
  end;

  procedure Point(X, Y: Integer);
  begin
    if (X < 0) or (Y < 0) or (X >= I.Width) or (Y >= I.Height) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens pixel coordinates');
  end;

  function Decode(DataRef: Integer): Integer;
  begin
    var Data := VM.GetObject(DataRef);
    Result := InvokeJ2MEImage(VM, VM.LoadClass(ImageName).FindMethod('createImage', '([BII)' + ImageD),
      [TJVMValue.Ref(DataRef), TJVMValue.Int(0), TJVMValue.Int(Data.ElementCount)]).AsRef;
  end;

  function Resource(NameRef: Integer; Scale: Boolean): Integer;
  begin
    Result := InvokeJ2MEImage(VM, VM.LoadClass(ImageName).FindMethod('createImage', '(Ljava/lang/String;)' + ImageD),
      [TJVMValue.Ref(NameRef)]).AsRef;
    var Image := J2MEImageView(VM, Result);
    if not Scale or ((Image.Width <= ScreenWidth) and (Image.Height <= ScreenHeight)) then
      Exit;
    var W := ScreenWidth;
    var H := Max(1, Integer(Int64(Image.Height) * W div Image.Width));
    if H > ScreenHeight then
    begin
      H := ScreenHeight;
      W := Max(1, Integer(Int64(Image.Width) * H div Image.Height));
    end;
    var Pixels: TArray<UInt32>;
    SetLength(Pixels, W * H);
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
        Pixels[Y * W + X] := UInt32(Image.Pixels.ElementValues[Integer(Int64(Y) * Image.Height div H) * Image.Width + Integer(Int64(X) * Image.Width div W)].AsInt);
    Result := J2MENewRasterImage(VM, W, H, Pixels, False);
  end;

begin
  Result := Default(TJVMValue);
  Flushed := False;
  N := Method.Name;
  C := Method.Owner.Name;
  D := Method.Descriptor;
  if C = UIName then
  begin
    if N = 'createImageFromBitmap' then
      Exit(TJVMValue.Ref(Bitmap(VM, VM.GetObject(Args[0].AsRef), Arg(1), Arg(2), 1)));
    if N = 'createTransparentImageFromBitmap' then
      Exit(TJVMValue.Ref(Bitmap(VM, VM.GetObject(Args[0].AsRef), Arg(1), Arg(2), 2)));
    if N = 'createRGBImage' then
      Exit(TJVMValue.Ref(RGB332(VM, VM.GetObject(Args[0].AsRef), Arg(1), Arg(2), Arg(3))));
    if (N = 'createImageWithScaling') or (N = 'createImageWithoutScaling') then
      Exit(TJVMValue.Ref(Resource(Args[0].AsRef, N = 'createImageWithScaling')));
    if N = 'getNativeImage' then
    begin
      I := J2MEImageView(VM, Args[0].AsRef);
      if I.Image.Fields.TryGetValue('$siemens.native', Result) then
        Exit;
      R := VM.NewObject(UIName);
      PutRef(VM.GetObject(R), 'image', Args[0].AsRef);
      Result := TJVMValue.Ref(R);
      I.Image.Fields.AddOrSetValue('$siemens.native', Result);
      Exit;
    end;
    if N = 'setNativeImage' then
    begin
      I := J2MEImageView(VM, Args[0].AsRef);
      P := J2MEImageView(VM, Ref(VM.GetObject(Args[1].AsRef), 'image'));
      for var Name in [ImageName + '.$width:I', ImageName + '.$height:I', ImageName + '.$pixels:[I'] do
        I.Image.Fields.AddOrSetValue(Name, P.Image.Fields[Name]);
      for var Name in ['$siemens.bpp', '$siemens.raw2'] do
      begin
        var V: TJVMValue;
        if P.Image.Fields.TryGetValue(Name, V) then
          I.Image.Fields.AddOrSetValue(Name, V)
        else
          I.Image.Fields.Remove(Name);
      end;
      I.Image.Fields.AddOrSetValue('$siemens.native', Args[1]);
      Exit;
    end;
    if N.StartsWith('mirrorImage') then
    begin
      I := J2MEImageView(VM, Args[0].AsRef);
      var Raw := Shadow(VM, I, False);
      if Raw <> nil then
        for var Y := 0 to I.Height - 1 do
          for var X := 0 to I.Width - 1 do
            ReadCode(VM, I, X, Y, 2);
      for var Y := 0 to I.Height - 1 do
        for var X := 0 to I.Width - 1 do
        begin
          var SX := X;
          var SY := Y;
        // The vendor documentation specifies reflection at the named axis.
          if N = 'mirrorImageHorizontally' then
            SY := I.Height - 1 - Y
          else
            SX := I.Width - 1 - X;
          var AIndex := Y * I.Width + X;
          var BIndex := SY * I.Width + SX;
          if AIndex >= BIndex then
            Continue;
          var V := I.Pixels.ElementValues[AIndex];
          I.Pixels.ElementValues[AIndex] := I.Pixels.ElementValues[BIndex];
          I.Pixels.ElementValues[BIndex] := V;
          if Raw <> nil then
          begin
            var Stride := (I.Width + 3) div 4;
            var Code := ReadRaw(Raw, Stride, X, Y, 2);
            WriteRaw(Raw, Stride, X, Y, 2, ReadRaw(Raw, Stride, SX, SY, 2));
            WriteRaw(Raw, Stride, SX, SY, 2, Code);
          end;
        end;
      Exit;
    end;
    O := VM.GetObject(Args[0].AsRef);
    if N = '<init>' then
    begin
      R := 0;
      if D = '(II)V' then
        R := J2MENewMutableImage(VM, Arg(1), Arg(2))
      else if D = '(' + UID + ')V' then
        R := CopyImage(VM, Ref(VM.GetObject(Args[1].AsRef), 'image'))
      else if D = '([BII)V' then
        R := Bitmap(VM, VM.GetObject(Args[1].AsRef), Arg(2), Arg(3), 1)
      else if D = '([BIIZ)V' then
        R := Bitmap(VM, VM.GetObject(Args[1].AsRef), Arg(2), Arg(3), 2)
      else if D = '([BIII)V' then
        R := RGB332(VM, VM.GetObject(Args[1].AsRef), Arg(2), Arg(3), Arg(4))
      else if D = '([B)V' then
        R := Decode(Args[1].AsRef)
      else if D = '(Ljava/lang/String;Z)V' then
        R := Resource(Args[1].AsRef, Arg(2) <> 0);
      PutRef(O, 'image', R);
      Exit;
    end;
    R := Ref(O, 'image');
    if R = 0 then
      Exit(TJVMValue.Int(0));
    I := J2MEImageView(VM, R);
    if N = 'getWidth' then
      Exit(TJVMValue.Int(I.Width));
    if N = 'getHeight' then
      Exit(TJVMValue.Int(I.Height));
  end;
  if (C = ManagerName) and (N = 'createTextureBits') then
  begin
    var W := Arg(0);
    var H := Arg(1);
    A := VM.GetObject(Args[2].AsRef);
    Dimensions(VM, W, H);
    if Int64(W) * H > A.ElementCount then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    var Stride := (W + 7) div 8;
    R := VM.NewArray('[B', Stride * H);
    var Bits := VM.GetObject(R);
    for var Y := 0 to H - 1 do
      for var X := 0 to W - 1 do
        WriteRaw(Bits, Stride, X, Y, 1, Ord(A.ElementValues[Y * W + X].AsInt <> 0));
    Exit(TJVMValue.Ref(R));
  end;
  O := VM.GetObject(Args[0].AsRef);
  if C = ExtendedName then
  begin
    if N = '<init>' then
    begin
      I := J2MEImageView(VM, Args[1].AsRef);
      if I.Width mod 8 <> 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'ExtendedImage width must be a multiple of8');
      Packing(I);
      PutRef(O, 'image', Args[1].AsRef);
      Exit;
    end;
    R := Ref(O, 'image');
    if N = 'getImage' then
      Exit(TJVMValue.Ref(R));
    I := J2MEImageView(VM, R);
    BPP := Packing(I);
    if N = 'getPixel' then
    begin
      Point(Arg(1), Arg(2));
      Exit(TJVMValue.Int(ReadCode(VM, I, Arg(1), Arg(2), BPP)));
    end;
    if (N = 'setPixel') or (N = 'clear') then
    begin
      var Code := Arg(1);
      if N = 'setPixel' then
        Code := Arg(3);
      if (Code < 0) or (Code >= 1 shl BPP) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens pixel color');
      if N = 'setPixel' then
      begin
        Point(Arg(1), Arg(2));
        WriteCode(VM, I, Arg(1), Arg(2), BPP, Code);
      end
      else
        for var Y := 0 to I.Height - 1 do
          for var X := 0 to I.Width - 1 do
            WriteCode(VM, I, X, Y, BPP, Code);
      Exit;
    end;
    if (N = 'setPixels') or (N = 'getPixelBytes') then
    begin
      A := VM.GetObject(Args[1].AsRef);
      var X := Arg(2);
      var Y := Arg(3);
      var W := Arg(4);
      var H := Arg(5);
      if (W < 0) or (H < 0) or (X mod 8 <> 0) or (W mod 8 <> 0) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'ExtendedImage rectangle');
      if (N = 'getPixelBytes') and ((X < 0) or (Y < 0) or
        (Int64(X) + W > I.Width) or (Int64(Y) + H > I.Height)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'ExtendedImage read rectangle');
      var Stride := (W div 8) * BPP;
      if Int64(Stride) * H > A.ElementCount then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      if N = 'getPixelBytes' then
      begin
        for var J := 0 to Stride * H - 1 do
          A.ElementValues[J] := TJVMValue.Int(0);
        for var DY := 0 to H - 1 do
          for var DX := 0 to W - 1 do
            WriteRaw(A, Stride, DX, DY, BPP, ReadCode(VM, I, X + DX, Y + DY, BPP));
      end
      else
      begin
        // Bulk writes are packed-image blits. BlockBreaker scrolls its wall
        // through a negative Y, so preserve the full source stride and clip the
        // destination instead of rejecting partly/offscreen drawing rectangles.
        var Left := Max(Int64(0), Int64(X));
        var Top := Max(Int64(0), Int64(Y));
        var Right := Min(Int64(I.Width), Int64(X) + W);
        var Bottom := Min(Int64(I.Height), Int64(Y) + H);
        if (Left >= Right) or (Top >= Bottom) then
          Exit;
        var Bytes := Copy(A.Elements);
        for var DY := Integer(Top) to Integer(Bottom) - 1 do
        begin
          if Cancelled(VM) then
            Exit;
          var SY := Integer(Int64(DY) - Y);
          for var DX := Integer(Left) to Integer(Right) - 1 do
          begin
            var SX := Integer(Int64(DX) - X);
            WriteCode(VM, I, DX, DY, BPP, (Bytes[SY * Stride + SX div (8 div BPP)].AsInt shr
              (8 - BPP - (SX mod (8 div BPP)) * BPP)) and ((1 shl BPP) - 1));
          end;
        end;
      end;
      Exit;
    end;
    if N = 'blitToScreen' then
    begin
      var X := Int64(Arg(1));
      var Y := Int64(Arg(2));
      var Left := Max(Int64(0), X);
      var Top := Max(Int64(0), Y);
      var Right := Min(Int64(ScreenWidth), X + I.Width);
      var Bottom := Min(Int64(ScreenHeight), Y + I.Height);
      for var DY := Integer(Top) to Integer(Bottom) - 1 do
      begin
        if Cancelled(VM) then
          Exit;
        for var DX := Integer(Left) to Integer(Right) - 1 do
        begin
          var Index := DY * ScreenWidth + DX;
          Screen[Index] := J2MECompositeColor(Screen[Index], UInt32(I.Pixels.ElementValues[Integer(DY - Y) * I.Width + Integer(DX - X)].AsInt));
        end;
      end;
      Flushed := (Left < Right) and (Top < Bottom);
      Exit;
    end;
  end;
  if C = ObjectName then
  begin
    if N = '<init>' then
      Put(O, 'visible', 1)
    else if N = 'setVisible' then
      Put(O, 'visible', Ord(Arg(1) <> 0))
    else if N = 'getVisible' then
      Exit(TJVMValue.Int(Get(O, 'visible', 1)));
    Exit;
  end;
  if C = SpriteName then
  begin
    if N = '<init>' then
    begin
      var PixelRef, Count, H: Integer;
      var MaskRef := 0;
      if D.StartsWith('([B') then
      begin
        var Data := VM.GetObject(Args[1].AsRef);
        var Bits: TJVMObject := nil;
        if Args[5].AsRef <> 0 then
          Bits := VM.GetObject(Args[5].AsRef);
        var W := Arg(3);
        H := Arg(4);
        Count := Arg(7);
        // Rows are byte aligned, but frame heights need not be. GP Pinball's
        // 8x5 ball also follows the vendor's array-size/exception contract;
        // its parameter prose inconsistently asks for a multiple-of-8 height.
        if (Arg(2) <> 0) or (Arg(6) <> 0) or (W <= 0) or (H <= 0) or (W mod 8 <> 0) or (Count < 1) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens sprite dimensions/offsets');
        Dimensions(VM, W, H);
        if Count > VM.MaxArrayLength div (W * H) then
          VM.RaiseJava('java/lang/OutOfMemoryError', 'Siemens sprite frame limit');
        var Required := W * H * Count div 8;
        if (Data.ElementCount <> Required) or ((Bits <> nil) and (Bits.ElementCount <> Required)) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens sprite bitmap length');
        PixelRef := J2MENewBitmapImage(VM, Data, W, H * Count);
        PutRef(O, 'pixels', PixelRef);
        // A null mask means an opaque sprite, as used by GameAPI_Demo's title
        // strips and BlockBreaker's level digits. The renderer already supports it.
        if Bits <> nil then
          MaskRef := J2MENewBitmapImage(VM, Bits, W, H * Count);
      end
      else
      begin
        var IsExtended := D.StartsWith('(' + ExtendedD);
        PixelRef := Unwrap(VM, Args[1].AsRef, IsExtended);
        P := J2MEImageView(VM, PixelRef);
        Count := Arg(3);
        if (P.Width mod 8 <> 0) or (Count < 1) or (P.Height mod Count <> 0) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens sprite image/frame dimensions');
        Opaque(VM, P);
        H := P.Height div Count;
        if Args[2].AsRef <> 0 then
        begin
          MaskRef := Unwrap(VM, Args[2].AsRef, IsExtended);
          Mask := J2MEImageView(VM, MaskRef);
          if (P.Width <> Mask.Width) or (P.Height <> Mask.Height) then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens sprite mask dimensions');
          Opaque(VM, Mask);
        end;
      end;
      P := J2MEImageView(VM, PixelRef);
      PutRef(O, 'pixels', PixelRef);
      PutRef(O, 'mask', MaskRef);
      Put(O, 'w', P.Width);
      Put(O, 'h', H);
      Put(O, 'count', Count);
      Put(O, 'frame', 0);
      Put(O, 'x', 0);
      Put(O, 'y', 0);
      Put(O, 'cx', 0);
      Put(O, 'cy', 0);
      Put(O, 'cw', P.Width);
      Put(O, 'ch', H);
      Put(O, 'visible', 1);
      Exit;
    end;
    if N = 'setPosition' then
    begin
      Put(O, 'x', Arg(1));
      Put(O, 'y', Arg(2));
      Exit;
    end;
    if N = 'getXPosition' then
      Exit(TJVMValue.Int(Get(O, 'x')));
    if N = 'getYPosition' then
      Exit(TJVMValue.Int(Get(O, 'y')));
    if N = 'getFrame' then
      Exit(TJVMValue.Int(Get(O, 'frame')));
    if N = 'setFrame' then
    begin
      if (Arg(1) < 0) or (Arg(1) >= Get(O, 'count')) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens sprite frame');
      Put(O, 'frame', Arg(1));
      Exit;
    end;
    if N = 'setCollisionRectangle' then
    begin
      if (Arg(3) < 0) or (Arg(4) < 0) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens collision dimensions');
      Put(O, 'cx', Arg(1));
      Put(O, 'cy', Arg(2));
      Put(O, 'cw', Arg(3));
      Put(O, 'ch', Arg(4));
      Exit;
    end;
    var Left := Int64(Get(O, 'x')) + Get(O, 'cx');
    var Top := Int64(Get(O, 'y')) + Get(O, 'cy');
    var Right := Left + Get(O, 'cw');
    var Bottom := Top + Get(O, 'ch');
    if N = 'isCollidingWithPos' then
      Exit(TJVMValue.Int(Ord((Arg(1) >= Left) and (Arg(1) < Right) and (Arg(2) >= Top) and (Arg(2) < Bottom))));
    if N = 'isCollidingWith' then
    begin
      A := VM.GetObject(Args[1].AsRef);
      var X := Int64(Get(A, 'x')) + Get(A, 'cx');
      var Y := Int64(Get(A, 'y')) + Get(A, 'cy');
      Exit(TJVMValue.Int(Ord((Left < Right) and (Top < Bottom) and (Get(A, 'cw') > 0) and (Get(A, 'ch') > 0) and
            (Left < X + Get(A, 'cw')) and (Right > X) and (Top < Y + Get(A, 'ch')) and (Bottom > Y))));
    end;
  end;
  if C = TilesName then
  begin
    if N = 'setPositionInMap' then
    begin
      Put(O, 'mapX', Arg(1));
      Put(O, 'mapY', Arg(2));
      Exit;
    end;
    var PixelRef := 0;
    var MaskRef := 0;
    var Count := 0;
    var Map := VM.GetObject(Args[3].AsRef);
    var W := Arg(4);
    var H := Arg(5);
    Dimensions(VM, W, H);
    if Int64(W) * H <> Map.ElementCount then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens map length');
    if D.StartsWith('([B') then
    begin
      var Data := VM.GetObject(Args[1].AsRef);
      var Bits: TJVMObject := nil;
      if Args[2].AsRef <> 0 then
        Bits := VM.GetObject(Args[2].AsRef);
      if (Data.ElementCount mod 8 <> 0) or ((Bits <> nil) and (Bits.ElementCount <> Data.ElementCount)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens tile bitmap length');
      Count := Data.ElementCount div 8;
      if Count > 0 then
      begin
        PixelRef := J2MENewBitmapImage(VM, Data, 8, Data.ElementCount);
        PutRef(O, 'pixels', PixelRef);
        if Bits <> nil then
          MaskRef := J2MENewBitmapImage(VM, Bits, 8, Bits.ElementCount);
      end;
    end
    else
    begin
      var IsExtended := D.StartsWith('(' + ExtendedD);
      PixelRef := Unwrap(VM, Args[1].AsRef, IsExtended);
      P := J2MEImageView(VM, PixelRef);
      if (P.Width <> 8) or (P.Height mod 8 <> 0) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens tile image dimensions');
      Opaque(VM, P);
      Count := P.Height div 8;
      if Args[2].AsRef <> 0 then
      begin
        MaskRef := Unwrap(VM, Args[2].AsRef, IsExtended);
        Mask := J2MEImageView(VM, MaskRef);
        if (Mask.Width <> 8) or (Mask.Height <> P.Height) then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Siemens tile mask dimensions');
        Opaque(VM, Mask);
      end;
    end;
    PutRef(O, 'pixels', PixelRef);
    PutRef(O, 'mask', MaskRef);
    PutRef(O, 'map', Args[3].AsRef);
    Put(O, 'cols', W);
    Put(O, 'rows', H);
    Put(O, 'tiles', Count);
    Put(O, 'mapX', 0);
    Put(O, 'mapY', 0);
    Put(O, 'visible', 1);
    ValidateMap(VM, O);
    Exit;
  end;
  if C = ManagerName then
  begin
    if N = '<init>' then
    begin
      PutRef(O, 'objects', VM.NewArray('[' + ObjectD, 0));
      Exit;
    end;
    var List := VM.GetObject(Ref(O, 'objects'));
    var Count := List.ElementCount;
    var Index := -1;
    if (N = 'getObjectPosition') or ((N = 'deleteObject') and D.StartsWith('(' + ObjectD)) then
    begin
      VM.GetObject(Args[1].AsRef);
      for var J := 0 to Count - 1 do
        if List.ElementValues[J].AsRef = Args[1].AsRef then
        begin
          Index := J;
          Break;
        end;
      if N = 'getObjectPosition' then
        Exit(TJVMValue.Int(Index));
    end;
    if N = 'getObjectAt' then
    begin
      Index := Arg(1);
      if (Index < 0) or (Index >= Count) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      Exit(List.ElementValues[Index]);
    end;
    if N = 'paint' then
    begin
      I := J2MEImageView(VM, Unwrap(VM, Args[1].AsRef, D.StartsWith('(' + ExtendedD)));
      Opaque(VM, I);
      // The supplied map remains live; validate updates before changing the target.
      for var V in List.Elements do
      begin
        if Cancelled(VM) then
          Exit;
        A := VM.GetObject(V.AsRef);
        if VM.IsAssignable(A.ClassName, TilesName) then
          ValidateMap(VM, A);
      end;
      for var V in List.Elements do
      begin
        if Cancelled(VM) then
          Exit;
        PaintObject(VM, VM.GetObject(V.AsRef), I, Arg(2), Arg(3));
      end;
      Exit;
    end;
    if (N = 'addObject') or (N = 'insertObject') then
    begin
      VM.GetObject(Args[1].AsRef);
      Index := Count;
      if N = 'insertObject' then
        Index := Arg(2);
      if (Index < 0) or (Index > Count) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      if Count >= VM.MaxArrayLength then
        VM.RaiseJava('java/lang/OutOfMemoryError', 'Siemens object collection limit');
      R := VM.NewArray('[' + ObjectD, Count + 1);
      A := VM.GetObject(R);
      for var J := 0 to Index - 1 do
        A.ElementValues[J] := List.ElementValues[J];
      A.ElementValues[Index] := Args[1];
      for var J := Index to Count - 1 do
        A.ElementValues[J + 1] := List.ElementValues[J];
      PutRef(O, 'objects', R);
      Exit;
    end;
    if N = 'deleteObject' then
    begin
      if D = '(I)V' then
      begin
        Index := Arg(1);
        if (Index < 0) or (Index >= Count) then
          VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      end;
      if Index < 0 then
        Exit;
      R := VM.NewArray('[' + ObjectD, Count - 1);
      A := VM.GetObject(R);
      for var J := 0 to Index - 1 do
        A.ElementValues[J] := List.ElementValues[J];
      for var J := Index + 1 to Count - 1 do
        A.ElementValues[J - 1] := List.ElementValues[J];
      PutRef(O, 'objects', R);
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(C + '.' + N);
end;

end.

