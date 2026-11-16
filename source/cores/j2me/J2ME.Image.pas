unit J2ME.Image;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

type
  TJ2MEImageView = record
    Image, Pixels: TJVMObject;
    Width, Height: Integer;
    Mutable: Boolean;
  end;

procedure InstallJ2MEImage(VM: TJVM);

function InvokeJ2MEImage(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function J2MEImageView(VM: TJVM; Ref: Integer): TJ2MEImageView;

function J2MENewMutableImage(VM: TJVM; Width, Height: Integer): Integer;

function J2MENewRasterImage(VM: TJVM; Width, Height: Integer; const Pixels: TArray<UInt32>; Mutable: Boolean): Integer;

function J2MENewBitmapImage(VM: TJVM; Data: TJVMObject; Width, Height: Integer): Integer;

procedure J2METransformSource(X, Y, Width, Height, Transform: Integer; out SX, SY: Integer);

procedure J2MECheckRGBBounds(VM: TJVM; Data: TJVMObject; Offset, Stride, Width, Height: Integer);

implementation

uses
  System.SysUtils, System.Math, Java.Classes, Java.Bootstrap, Media.Image.Types,
  Media.Image.Decode;

{$Q-}{$R-}

const
  ImageClass = 'javax/microedition/lcdui/Image';
  ImageDesc = 'Ljavax/microedition/lcdui/Image;';

function J2MENewRasterImage(VM: TJVM; Width, Height: Integer; const Pixels: TArray<UInt32>; Mutable: Boolean): Integer;
begin
  if (Width <= 0) or (Height <= 0) then
    VM.RaiseJava('java/lang/IllegalArgumentException');
  if Int64(Width) * Height > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Image pixel limit');
  if Length(Pixels) <> Width * Height then
    raise EJVMFormatError.Create('Raster image size');
  var PixelRef := VM.NewArray('[I', Length(Pixels));
  var A := VM.GetObject(PixelRef);
  for var I := 0 to High(Pixels) do
    A.ElementValues[I] := TJVMValue.Int(Integer(Pixels[I]));
  Result := VM.NewObject(ImageClass);
  var O := VM.GetObject(Result);
  O.Fields.AddOrSetValue(ImageClass + '.$pixels:[I', TJVMValue.Ref(PixelRef));
  O.Fields.AddOrSetValue(ImageClass + '.$width:I', TJVMValue.Int(Width));
  O.Fields.AddOrSetValue(ImageClass + '.$height:I', TJVMValue.Int(Height));
  O.Fields.AddOrSetValue(ImageClass + '.$mutable:Z', TJVMValue.Int(Ord(Mutable)));
end;

function J2MENewBitmapImage(VM: TJVM; Data: TJVMObject; Width, Height: Integer): Integer;
begin
  if (Width <= 0) or (Height <= 0) then
    VM.RaiseJava('java/lang/IllegalArgumentException');
  if Int64(Width) * Height > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Image pixel limit');
  var Stride := (Int64(Width) + 7) div 8;
  if Stride * Height > Data.ElementCount then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  var Pixels: TArray<UInt32>;
  SetLength(Pixels, Width * Height);
  for var Y := 0 to Height - 1 do
    for var X := 0 to Width - 1 do
    begin
      var Black := (Data.ElementValues[Y * Integer(Stride) + X div 8].AsInt shr (7 - (X and 7))) and 1;
      Pixels[Y * Width + X] := $FFFFFFFF;
      if Black <> 0 then
        Pixels[Y * Width + X] := $FF000000;
    end;
  Result := J2MENewRasterImage(VM, Width, Height, Pixels, False);
  VM.GetObject(Result).Fields.AddOrSetValue('$siemens.bpp', TJVMValue.Int(1));
end;

function J2MENewMutableImage(VM: TJVM; Width, Height: Integer): Integer;
var
  Pixels, O: TJVMObject;
  Ref: Integer;
begin
  if (Width <= 0) or (Height <= 0) then
    VM.RaiseJava('java/lang/IllegalArgumentException');
  if Int64(Width) * Height > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Image pixel limit');
  Ref := VM.NewArray('[I', Width * Height);
  Pixels := VM.GetObject(Ref);
  for var I := 0 to (Pixels.ElementCount - 1) do
    Pixels.ElementValues[I] := TJVMValue.Int(-1);
  Result := VM.NewObject(ImageClass);
  O := VM.GetObject(Result);
  O.Fields.AddOrSetValue(ImageClass + '.$pixels:[I', TJVMValue.Ref(Ref));
  O.Fields.AddOrSetValue(ImageClass + '.$width:I', TJVMValue.Int(Width));
  O.Fields.AddOrSetValue(ImageClass + '.$height:I', TJVMValue.Int(Height));
  O.Fields.AddOrSetValue(ImageClass + '.$mutable:Z', TJVMValue.Int(1));
end;

procedure InstallJ2MEImage(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(ImageClass, 'java/lang/Object');
  try
    B.Field('$width', 'I', JVM_ACC_PRIVATE);
    B.Field('$height', 'I', JVM_ACC_PRIVATE);
    B.Field('$pixels', '[I', JVM_ACC_PRIVATE);
    B.Field('$mutable', 'Z', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('createImage', '(II)' + ImageDesc, True);
    B.JavaClass.AddNative('createImage', '(' + ImageDesc + ')' + ImageDesc, True);
    B.JavaClass.AddNative('createImage', '(' + ImageDesc + 'IIIII)' + ImageDesc, True);
    B.JavaClass.AddNative('createImage', '(Ljava/lang/String;)' + ImageDesc, True);
    B.JavaClass.AddNative('createImage', '([BII)' + ImageDesc, True);
    // Siemens MIDP 1 extension, also used through the standard Image owner.
    B.JavaClass.AddNative('createImageFromBitmap', '([BII)' + ImageDesc, True);
    B.JavaClass.AddNative('createRGBImage', '([IIIZ)' + ImageDesc, True);
    B.JavaClass.AddNative('getWidth', '()I');
    B.JavaClass.AddNative('getHeight', '()I');
    B.JavaClass.AddNative('isMutable', '()Z');
    B.JavaClass.AddNative('getGraphics', '()Ljavax/microedition/lcdui/Graphics;');
    B.JavaClass.AddNative('getRGB', '([IIIIIII)V');
    // Stream loading delegates to guest read/write overrides and yields normally.
    B.Start;
    B.Ref($BB, B.ClassRef('java/io/ByteArrayOutputStream'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/io/ByteArrayOutputStream', '<init>', '()V'));
    B.Emit([$4C, $11, 4, 0, $BC, 8, $4D]);
    B.Mark('loop');
    B.Emit([$2A, $2C]);
    B.Ref($B6, B.Member('java/io/InputStream', 'read', '([B)I'));
    B.Emit([$3E, $1D]);
    B.Jump($9B, 'end');
    B.Emit([$1D]);
    B.Jump($9A, 'write');
    // Defensive progress for streams that temporarily return zero.
    B.Emit([$2A]);
    B.Ref($B6, B.Member('java/io/InputStream', 'read', '()I'));
    B.Emit([$3E, $1D]);
    B.Jump($9B, 'end');
    B.Emit([$2B, $1D]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'write', '(I)V'));
    B.Jump($A7, 'loop');
    B.Mark('write');
    B.Emit([$2B, $2C, $03, $1D]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'write', '([BII)V'));
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/io/ByteArrayOutputStream', 'toByteArray', '()[B'));
    B.Emit([$4D, $2C, $03, $2C, $BE]);
    B.Ref($B8, B.Member(ImageClass, '$decodeStream', '([BII)' + ImageDesc));
    B.Emit([$B0]);
    B.Finish('createImage', '(Ljava/io/InputStream;)' + ImageDesc, JVM_ACC_PUBLIC or JVM_ACC_STATIC, 4, 4);
    B.JavaClass.AddNative('$decodeStream', '([BII)' + ImageDesc, True).Access := JVM_ACC_PRIVATE or JVM_ACC_STATIC or JVM_ACC_NATIVE;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function J2MEImageView(VM: TJVM; Ref: Integer): TJ2MEImageView;
begin
  Result.Image := VM.GetObject(Ref);
  if not VM.IsAssignable(Result.Image.ClassName, ImageClass) then
    raise EJVMFormatError.Create('Expected Image');
  Result.Width := Result.Image.Fields[ImageClass + '.$width:I'].AsInt;
  Result.Height := Result.Image.Fields[ImageClass + '.$height:I'].AsInt;
  Result.Mutable := Result.Image.Fields[ImageClass + '.$mutable:Z'].AsInt <> 0;
  Result.Pixels := VM.GetObject(Result.Image.Fields[ImageClass + '.$pixels:[I'].AsRef);
end;

procedure J2METransformSource(X, Y, Width, Height, Transform: Integer; out SX, SY: Integer);
begin
  case Transform of
    0:
      begin
        SX := X;
        SY := Y;
      end;
    1:
      begin
        SX := X;
        SY := Height - 1 - Y;
      end;
    2:
      begin
        SX := Width - 1 - X;
        SY := Y;
      end;
    3:
      begin
        SX := Width - 1 - X;
        SY := Height - 1 - Y;
      end;
    4:
      begin
        SX := Y;
        SY := X;
      end;
    5:
      begin
        SX := Y;
        SY := Height - 1 - X;
      end;
    6:
      begin
        SX := Width - 1 - Y;
        SY := X;
      end;
    7:
      begin
        SX := Width - 1 - Y;
        SY := Height - 1 - X;
      end;
  else
    raise EJVMFormatError.Create('Invalid image transform');
  end;
end;

procedure J2MECheckRGBBounds(VM: TJVM; Data: TJVMObject; Offset, Stride, Width, Height: Integer);
var
  LastRow, First, Last: Int64;
begin
  if Data.ClassName <> '[I' then
    raise EJVMFormatError.Create('Expected int array');
  if (Width <= 0) or (Height <= 0) then
    Exit;
  LastRow := Int64(Offset) + Int64(Height - 1) * Stride;
  First := Min(Int64(Offset), LastRow);
  Last := Max(Int64(Offset), LastRow) + Width - 1;
  if (First < 0) or (Last >= Data.ElementCount) then
    VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
end;

function InvokeJ2MEImage(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  N, D, Resource, ErrorClass: string;
  A, Dest: TJVMObject;
  Source: TJ2MEImageView;
  Decoded: TRasterImage;
  Pixels: TArray<UInt32>;
  Bytes: TBytes;
  W, H, X, Y, Transform, Ref, I, J, SX, SY, Offset, Stride, Width, Height: Integer;
  Mutable, Alpha: Boolean;

  function Arg(Index: Integer): Integer;
  begin
    Result := Args[Index].AsInt;
  end;

  procedure Dimensions;
  begin
    if (W <= 0) or (H <= 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    if Int64(W) * H > VM.MaxArrayLength then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Image pixel limit');
  end;

begin
  N := Method.Name;
  D := Method.Descriptor;
  Result := Default(TJVMValue);
  if N = 'createImageFromBitmap' then
    Exit(TJVMValue.Ref(J2MENewBitmapImage(VM, VM.GetObject(Args[0].AsRef), Arg(1), Arg(2))));
  if (N = 'getWidth') or (N = 'getHeight') or (N = 'isMutable') or (N = 'getGraphics') or (N = 'getRGB') then
  begin
    Source := J2MEImageView(VM, Args[0].AsRef);
    if N = 'getWidth' then
      Exit(TJVMValue.Int(Source.Width));
    if N = 'getHeight' then
      Exit(TJVMValue.Int(Source.Height));
    if N = 'isMutable' then
      Exit(TJVMValue.Int(Ord(Source.Mutable)));
    if N = 'getGraphics' then
    begin
      if not Source.Mutable then
        VM.RaiseJava('java/lang/IllegalStateException');
      Ref := VM.NewObject('javax/microedition/lcdui/Graphics');
      VM.GetObject(Ref).Fields.Add('$target', Args[0]);
      Exit(TJVMValue.Ref(Ref));
    end;
    Dest := VM.GetObject(Args[1].AsRef);
    Offset := Arg(2);
    Stride := Arg(3);
    X := Arg(4);
    Y := Arg(5);
    W := Arg(6);
    H := Arg(7);
    if (X < 0) or (Y < 0) or (Int64(X) + W > Source.Width) or (Int64(Y) + H > Source.Height) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    if (W <= 0) or (H <= 0) then
      Exit;
    if Abs(Int64(Stride)) < W then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    J2MECheckRGBBounds(VM, Dest, Offset, Stride, W, H);
    for J := 0 to H - 1 do
      for I := 0 to W - 1 do
        Dest.ElementValues[Integer(Int64(Offset) + Int64(J) * Stride + I)] := Source.Pixels.ElementValues[(Y + J) * Source.Width + X + I];
    Exit;
  end;
  Mutable := False;
  if (N = 'createImage') and D.StartsWith('(II)') then
  begin
    W := Arg(0);
    H := Arg(1);
    Dimensions;
    SetLength(Pixels, W * H);
    for I := 0 to High(Pixels) do
      Pixels[I] := $FFFFFFFF;
    Mutable := True;
  end
  else if N = 'createRGBImage' then
  begin
    A := VM.GetObject(Args[0].AsRef);
    W := Arg(1);
    H := Arg(2);
    Alpha := Arg(3) <> 0;
    Dimensions;
    J2MECheckRGBBounds(VM, A, 0, W, W, H);
    SetLength(Pixels, W * H);
    for I := 0 to High(Pixels) do
    begin
      Pixels[I] := UInt32(A.ElementValues[I].AsInt);
      if not Alpha then
        Pixels[I] := Pixels[I] or $FF000000;
    end;
  end
  else if D.StartsWith('(' + ImageDesc) then
  begin
    Source := J2MEImageView(VM, Args[0].AsRef);
    X := 0;
    Y := 0;
    W := Source.Width;
    H := Source.Height;
    Transform := 0;
    if Length(Args) > 1 then
    begin
      X := Arg(1);
      Y := Arg(2);
      W := Arg(3);
      H := Arg(4);
      Transform := Arg(5);
      if (Transform < 0) or (Transform > 7) or (X < 0) or (Y < 0) or (W <= 0) or (H <= 0) or
        (Int64(X) + W > Source.Width) or (Int64(Y) + H > Source.Height) then
        VM.RaiseJava('java/lang/IllegalArgumentException');
    end;
    Width := W;
    Height := H;
    if Transform >= 4 then
    begin
      W := Height;
      H := Width;
    end;
    Dimensions;
    SetLength(Pixels, W * H);
    for J := 0 to H - 1 do
      for I := 0 to W - 1 do
      begin
        J2METransformSource(I, J, Width, Height, Transform, SX, SY);
        Pixels[J * W + I] := UInt32(Source.Pixels.ElementValues[(Y + SY) * Source.Width + X + SX].AsInt);
      end;
  end
  else
  begin
    ErrorClass := 'java/lang/IllegalArgumentException';
    if D.StartsWith('(Ljava/lang/String;)') then
    begin
      ErrorClass := 'java/io/IOException';
      Resource := VM.GetObject(Args[0].AsRef).Text;
      if Resource.StartsWith('/') then
        Delete(Resource, 1, 1);
      if not (VM.Host is TJavaHost) or not TJavaHost(VM.Host).LoadResource(Resource, Bytes) then
        VM.RaiseJava('java/io/IOException', 'Image resource not found: ' + Resource);
    end
    else
    begin
      if N = '$decodeStream' then
        ErrorClass := 'java/io/IOException';
      A := VM.GetObject(Args[0].AsRef);
      Offset := Arg(1);
      I := Arg(2);
      if (Offset < 0) or (I < 0) or ((I = 0) and (N <> '$decodeStream')) or (Offset > A.ElementCount) or (I > A.ElementCount - Offset) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      SetLength(Bytes, I);
      for J := 0 to I - 1 do
        Bytes[J] := Byte(A.ElementValues[Offset + J].AsInt);
    end;
    try
      Decoded := DecodeRasterImage(Bytes, VM.MaxArrayLength);
    except
      on E: EImageResourceLimit do
        VM.RaiseJava('java/lang/OutOfMemoryError', E.Message);
      on E: EImageFormat do
        VM.RaiseJava(ErrorClass, E.Message);
    end;
    W := Decoded.Width;
    H := Decoded.Height;
    Pixels := Decoded.Pixels;
  end;
  Ref := J2MENewRasterImage(VM, W, H, Pixels, Mutable);
  if D.StartsWith('(' + ImageDesc) then
  begin
    var Packing: TJVMValue;
    if Source.Image.Fields.TryGetValue('$siemens.bpp', Packing) then
      VM.GetObject(Ref).Fields.AddOrSetValue('$siemens.bpp', Packing);
  end;
  Result := TJVMValue.Ref(Ref);
end;

end.

