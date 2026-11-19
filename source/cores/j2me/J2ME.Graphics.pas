unit J2ME.Graphics;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

const
  J2MEDefaultNativePixelFormat = 8888;

function J2MECompositeColor(Old, Value: UInt32): UInt32;

procedure InstallJ2MEGraphics(VM: TJVM);

function InvokeJ2MEDirectUtils(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function InvokeJ2MEGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer; NativePixelFormat: Integer = J2MEDefaultNativePixelFormat): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Java.Classes, J2ME.Image, J2ME.Font,
  Media.Raster.Shapes;

{$Q-}{$R-}{$POINTERMATH ON}

const
  DirectName = 'com/nokia/mid/ui/DirectGraphics';
  GraphicsName = 'javax/microedition/lcdui/Graphics';
  ImageName = 'javax/microedition/lcdui/Image';

procedure DirectMethods(C: TJVMClass; abstract: Boolean);

  procedure Add(const N, D: string);
  begin
    var M := C.AddNative(N, D);
    if abstract then
      M.Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

begin
  Add('setARGBColor', '(I)V');
  Add('getAlphaComponent', '()I');
  Add('getNativePixelFormat', '()I');
  Add('drawImage', '(Ljavax/microedition/lcdui/Image;IIII)V');
  Add('drawTriangle', '(IIIIIII)V');
  Add('fillTriangle', '(IIIIIII)V');
  Add('drawPolygon', '([II[IIII)V');
  Add('fillPolygon', '([II[IIII)V');
  Add('drawPixels', '([IZIIIIIIII)V');
  Add('drawPixels', '([SZIIIIIIII)V');
  Add('drawPixels', '([B[BIIIIIIII)V');
  Add('getPixels', '([IIIIIIII)V');
  Add('getPixels', '([SIIIIIII)V');
  Add('getPixels', '([B[BIIIIIII)V');
end;

function InvokeJ2MEDirectUtils(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  if Method.Name = '<init>' then
    Exit;
  if Method.Name = 'getDirectGraphics' then
  begin
    VM.GetObject(Args[0].AsRef);
    Exit(Args[0]);
  end;
  if Method.Descriptor.StartsWith('(III)') then
  begin
    var Ref := J2MENewMutableImage(VM, Args[0].AsInt, Args[1].AsInt);
    var Image := J2MEImageView(VM, Ref);
    for var I := 0 to (Image.Pixels.ElementCount - 1) do
      Image.Pixels.ElementValues[I] := Args[2];
    Exit(TJVMValue.Ref(Ref));
  end;
  var M := VM.LoadClass(ImageName).FindMethod('createImage', '([BII)Ljavax/microedition/lcdui/Image;');
  Result := InvokeJ2MEImage(VM, M, Args);
  VM.GetObject(Result.AsRef).Fields[ImageName + '.$mutable:Z'] := TJVMValue.Int(1);
end;

procedure CheckManipulation(VM: TJVM; Value: Integer);
begin
  if ((Value and not $61FF) <> 0) or ((Value and $1FF <> 0) and (Value and $1FF <> 90) and (Value and $1FF <> 180) and (Value and $1FF <> 270)) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Image manipulation');
end;

procedure DirectSource(X, Y, W, H, Manipulation: Integer; out SX, SY: Integer);
var
  DW, DH: Integer;
begin
  DW := W;
  DH := H;
  if (Manipulation and $1FF = 90) or (Manipulation and $1FF = 270) then
  begin
    DW := H;
    DH := W;
  end;
  if Manipulation and $2000 <> 0 then
    X := DW - 1 - X;
  if Manipulation and $4000 <> 0 then
    Y := DH - 1 - Y;
  case Manipulation and $1FF of
    90:
      begin
        SX := W - 1 - Y;
        SY := X;
      end;
    180:
      begin
        SX := W - 1 - X;
        SY := H - 1 - Y;
      end;
    270:
      begin
        SX := Y;
        SY := H - 1 - X;
      end;
  else
    SX := X;
    SY := Y;
  end;
end;

function J2MECompositeColor(Old, Value: UInt32): UInt32;
var
  A, Inverse, DA, Denominator: Integer;

  function Channel(Shift: Integer): UInt32;
  begin
    Result := (((Value shr Shift) and 255) * UInt32(A * 255) +
      ((Old shr Shift) and 255) * UInt32(DA * Inverse) + UInt32(Denominator div 2)) div UInt32(Denominator);
  end;

begin
  A := Value shr 24;
  if A = 0 then
    Exit(Old);
  if A = 255 then
    Exit(Value);
  DA := Old shr 24;
  Inverse := 255 - A;
  Denominator := A * 255 + DA * Inverse;
  Result := (UInt32((Denominator + 127) div 255) shl 24) or (Channel(16) shl 16) or (Channel(8) shl 8) or Channel(0);
end;

procedure InstallJ2MEGraphics(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(DirectName, 'java/lang/Object', JVM_ACC_PUBLIC or $0200 or JVM_ACC_ABSTRACT);
  try
    Constant('FLIP_HORIZONTAL', $2000);
    Constant('FLIP_VERTICAL', $4000);
    Constant('ROTATE_90', 90);
    Constant('ROTATE_180', 180);
    Constant('ROTATE_270', 270);
    Constant('TYPE_BYTE_1_GRAY', 1);
    Constant('TYPE_BYTE_1_GRAY_VERTICAL', -1);
    Constant('TYPE_BYTE_2_GRAY', 2);
    Constant('TYPE_BYTE_4_GRAY', 4);
    Constant('TYPE_BYTE_8_GRAY', 8);
    Constant('TYPE_BYTE_332_RGB', 332);
    Constant('TYPE_USHORT_444_RGB', 444);
    Constant('TYPE_USHORT_555_RGB', 555);
    Constant('TYPE_USHORT_565_RGB', 565);
    Constant('TYPE_USHORT_1555_ARGB', 1555);
    Constant('TYPE_USHORT_4444_ARGB', 4444);
    Constant('TYPE_INT_888_RGB', 888);
    Constant('TYPE_INT_8888_ARGB', 8888);
    DirectMethods(B.JavaClass, True);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create('com/nokia/mid/ui/DirectUtils', 'java/lang/Object');
  try
    B.JavaClass.AddNative('<init>', '()V').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('getDirectGraphics', '(Ljavax/microedition/lcdui/Graphics;)Lcom/nokia/mid/ui/DirectGraphics;', True);
    B.JavaClass.AddNative('createImage', '(III)Ljavax/microedition/lcdui/Image;', True);
    B.JavaClass.AddNative('createImage', '([BII)Ljavax/microedition/lcdui/Image;', True);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create('javax/microedition/lcdui/Graphics', 'java/lang/Object');
  try
    B.JavaClass.Interfaces := [DirectName];
    DirectMethods(B.JavaClass, False);
    Constant('HCENTER', 1);
    Constant('VCENTER', 2);
    Constant('LEFT', 4);
    Constant('RIGHT', 8);
    Constant('TOP', 16);
    Constant('BOTTOM', 32);
    Constant('BASELINE', 64);
    Constant('SOLID', 0);
    Constant('DOTTED', 1);
    B.JavaClass.AddNative('setColor', '(I)V');
    B.JavaClass.AddNative('setColor', '(III)V');
    B.JavaClass.AddNative('getColor', '()I');
    B.JavaClass.AddNative('getRedComponent', '()I');
    B.JavaClass.AddNative('getGreenComponent', '()I');
    B.JavaClass.AddNative('getBlueComponent', '()I');
    B.JavaClass.AddNative('setGrayScale', '(I)V');
    B.JavaClass.AddNative('getGrayScale', '()I');
    B.JavaClass.AddNative('getDisplayColor', '(I)I');
    B.JavaClass.AddNative('translate', '(II)V');
    for var N in ['getTranslateX', 'getTranslateY', 'getClipX', 'getClipY', 'getClipWidth', 'getClipHeight', 'getStrokeStyle'] do
      B.JavaClass.AddNative(N, '()I');
    B.JavaClass.AddNative('setStrokeStyle', '(I)V');
    B.JavaClass.AddNative('setClip', '(IIII)V');
    B.JavaClass.AddNative('clipRect', '(IIII)V');
    B.JavaClass.AddNative('fillRect', '(IIII)V');
    B.JavaClass.AddNative('drawRect', '(IIII)V');
    B.JavaClass.AddNative('drawLine', '(IIII)V');
    for var Name in ['drawArc', 'fillArc', 'drawRoundRect', 'fillRoundRect'] do
      B.JavaClass.AddNative(Name, '(IIIIII)V');
    B.JavaClass.AddNative('fillTriangle', '(IIIIII)V');
    B.JavaClass.AddNative('copyArea', '(IIIIIII)V');
    B.JavaClass.AddNative('drawImage', '(Ljavax/microedition/lcdui/Image;III)V');
    B.JavaClass.AddNative('drawRegion', '(Ljavax/microedition/lcdui/Image;IIIIIIII)V');
    B.JavaClass.AddNative('drawRGB', '([IIIIIIIZ)V');
    B.JavaClass.AddNative('getFont', '()Ljavax/microedition/lcdui/Font;');
    B.JavaClass.AddNative('setFont', '(Ljavax/microedition/lcdui/Font;)V');
    B.JavaClass.AddNative('drawString', '(Ljava/lang/String;III)V');
    B.JavaClass.AddNative('drawSubstring', '(Ljava/lang/String;IIIII)V');
    B.JavaClass.AddNative('drawChar', '(CIII)V');
    B.JavaClass.AddNative('drawChars', '([CIIIII)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJ2MEGraphics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height, NativePixelFormat: Integer): TJVMValue;
var
  O, TargetPixels, RGB: TJVMObject;
  TargetRef: TJVMValue;
  Target, Source: TJ2MEImageView;
  N: string;
  Color: UInt32;
  TX, TY, CL, CT, CR, CB, Stroke, SrcX, SrcY, SW, SH, DW, DH, Transform, SX, SY, Offset, Stride: Integer;
  CollectCoverage: Boolean;
  Snapshot, ShapePixels: TArray<UInt32>;
  Raster: TShapeRasterizer;
  Font: TJ2MEFontView;
  Glyph: TJ2MEGlyph;
  Text: string;
  TextWidth, TextAnchor: Integer;
  X1, Y1, X2, Y2, W, H, X3, Y3, XX, YY: Int64;
  I, R, G, B: Integer;
  C1, C2, C3: Double;

  function Get(const Name: string; Default: Integer = 0): Integer;
  var
    V: TJVMValue;
  begin
    if O.Fields.TryGetValue('$' + Name, V) then
      Result := V.AsInt
    else
      Result := Default;
  end;

  procedure Put(const Name: string; Value: Integer);
  begin
    O.Fields.AddOrSetValue('$' + Name, TJVMValue.Int(Value));
  end;

  function Arg(Index: Integer): Integer;
  begin
    Result := Args[Index].AsInt;
  end;

  function FontRef: Integer;
  var
    Value: TJVMValue;
  begin
    if O.Fields.TryGetValue('$font', Value) then
      Exit(Value.AsRef);
    Result := J2MEGetFont(VM);
    O.Fields.Add('$font', TJVMValue.Ref(Result));
  end;

  function ReadPixel(Index: Integer): UInt32;
  begin
    if TargetPixels = nil then
      Result := Pixels[Index]
    else
      Result := UInt32(TargetPixels.ElementValues[Index].AsInt);
  end;

  procedure WritePixel(Index: Integer; Value: UInt32);
  begin
    if TargetPixels = nil then
      Pixels[Index] := Value
    else
      TargetPixels.ElementValues[Index] := TJVMValue.Int(Integer(Value));
  end;

  procedure Blend(X, Y: Int64; Value: UInt32);
  begin
    if (X < CL) or (X >= CR) or (Y < CT) or (Y >= CB) or (Value shr 24 = 0) then
      Exit;
    var Index := Integer(Y) * Width + Integer(X);
    WritePixel(Index, J2MECompositeColor(ReadPixel(Index), Value));
  end;

  procedure Anchor(var X, Y: Int64; W, H, Flags: Integer);
  var
    Horizontal, Vertical: Integer;
  begin
    if Flags = 0 then
      Flags := 20;
    Horizontal := Flags and 13;
    Vertical := Flags and 50;
    if ((Flags and not 63) <> 0) or not (Horizontal in [1, 4, 8]) or not (Vertical in [2, 16, 32]) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Image anchor');
    if Horizontal = 1 then
      Dec(X, W div 2)
    else if Horizontal = 8 then
      Dec(X, W);
    if Vertical = 2 then
      Dec(Y, H div 2)
    else if Vertical = 32 then
      Dec(Y, H);
  end;

  procedure Pixel(X, Y: Int64);
  begin
    if (X >= CL) and (X < CR) and (Y >= CT) and (Y < CB) then
      if CollectCoverage then
        ShapePixels[Integer(Y) * Width + Integer(X)] := 1
      else
        Blend(X, Y, Color);
  end;

  procedure Rect(X, Y, W, H: Int64);
  var
    L, T, R, B, Row, Col: Integer;
  begin
    if (W <= 0) or (H <= 0) then
      Exit;
    L := Integer(Max(Int64(CL), Min(Int64(CR), X)));
    R := Integer(Max(Int64(CL), Min(Int64(CR), X + W)));
    T := Integer(Max(Int64(CT), Min(Int64(CB), Y)));
    B := Integer(Max(Int64(CT), Min(Int64(CB), Y + H)));
    for Row := T to B - 1 do
      for Col := L to R - 1 do
        Blend(Col, Row, Color);
  end;

  procedure Line(AX, AY, BX, BY: Int64; ExcludeEnds: Boolean = False);
  var
    DX, DY, Major, Minor, StartAt, EndAt, Step, Other, Origin, Temp, Direction: Int64;
    Horizontal: Boolean;
  begin
    DX := Abs(BX - AX);
    DY := Abs(BY - AY);
    Horizontal := DX >= DY;
    if (Horizontal and (AX > BX)) or (not Horizontal and (AY > BY)) then
    begin
      Temp := AX;
      AX := BX;
      BX := Temp;
      Temp := AY;
      AY := BY;
      BY := Temp;
    end;
    if Horizontal then
    begin
      Major := DX;
      Minor := DY;
      Origin := AY;
      StartAt := Max(Int64(0), Int64(CL) - AX);
      EndAt := Min(Major, Int64(CR) - 1 - AX);
      Direction := Sign(BY - AY);
    end
    else
    begin
      Major := DY;
      Minor := DX;
      Origin := AX;
      StartAt := Max(Int64(0), Int64(CT) - AY);
      EndAt := Min(Major, Int64(CB) - 1 - AY);
      Direction := Sign(BX - AX);
    end;
    // Iterate only the visible major-axis interval, even for extreme Java int
    // endpoints. Unsigned products cover the complete 32-bit coordinate range.
    for Step := StartAt to EndAt do
    begin
      Other := Origin;
      if Major <> 0 then
        Other := Other + Direction * Int64((UInt64(Step) * UInt64(Minor) + UInt64(Major div 2)) div UInt64(Major));
      if (not ExcludeEnds or ((Step <> 0) and (Step <> Major))) and ((Stroke = 0) or ((Step and 1) = 0)) then
        if Horizontal then
          Pixel(AX + Step, Other)
        else
          Pixel(Other, AY + Step);
    end;
  end;

  procedure DirectPixels;
  var
    Data, Mask: TJVMObject;
    Format, Bits, Base, Scan, W, H, DW, DH, Manip, Start: Integer;
    ByteData, ReadBack, Alpha: Boolean;
    DX, DY, Lo, Hi, Tail, Index: Int64;
    SX, SY: Integer;
    Value: UInt32;

    function ByteLocation(X, Y: Integer; out Shift: Integer): Integer;
    var
      UnitIndex: Int64;
    begin
      if Format = -1 then
      begin
        UnitIndex := ((Int64(Base div Scan) + Y) div 8) * Scan + Base mod Scan + X;
        Shift := (Base div Scan + Y) mod 8;
        Result := Integer(UnitIndex);
      end
      else
      begin
        UnitIndex := Int64(Base) + Int64(Y) * Scan + X;
        Result := Integer(UnitIndex div (8 div Bits));
        Shift := 8 - Bits - Integer(UnitIndex mod (8 div Bits)) * Bits;
      end;
    end;

    function ReadPacked(A: TJVMObject; X, Y: Integer): Integer;
    var
      Shift: Integer;
    begin
      var At := ByteLocation(X, Y, Shift);
      Result := (A.ElementValues[At].AsInt shr Shift) and ((1 shl Bits) - 1);
    end;

    procedure StorePacked(A: TJVMObject; X, Y, V: Integer);
    var
      Shift: Integer;
    begin
      var At := ByteLocation(X, Y, Shift);
      var BitMask := ((1 shl Bits) - 1) shl Shift;
      A.ElementValues[At] := TJVMValue.Int(ShortInt((A.ElementValues[At].AsInt and not BitMask) or ((V shl Shift) and BitMask)));
    end;

    function Expand(V, MaxValue: Integer): UInt32;
    begin
      Result := UInt32((V * 255 + MaxValue div 2) div MaxValue);
    end;

    function Decode(V: UInt32): UInt32;
    var
      R, G, B, A: UInt32;
    begin
      A := 255;
      case Format of
        -1, 1, 2, 4, 8:
          begin
            R := 255 - Expand(V, (1 shl Bits) - 1);
            G := R;
            B := R;
          end;
        332:
          begin
            R := Expand((V shr 5) and 7, 7);
            G := Expand((V shr 2) and 7, 7);
            B := Expand(V and 3, 3);
          end;
        444, 4444:
          begin
            R := ((V shr 8) and 15) * 17;
            G := ((V shr 4) and 15) * 17;
            B := (V and 15) * 17;
            if Format = 4444 then
              A := ((V shr 12) and 15) * 17;
          end;
        555, 1555:
          begin
            R := Expand((V shr 10) and 31, 31);
            G := Expand((V shr 5) and 31, 31);
            B := Expand(V and 31, 31);
            if Format = 1555 then
              A := (V shr 15 and 1) * 255;
          end;
        565:
          begin
            R := Expand((V shr 11) and 31, 31);
            G := Expand((V shr 5) and 63, 63);
            B := Expand(V and 31, 31);
          end;
      else
        R := V shr 16 and 255;
        G := V shr 8 and 255;
        B := V and 255;
        if Format = 8888 then
          A := V shr 24;
      end;
      if not Alpha then
        A := 255;
      Result := (A shl 24) or (R shl 16) or (G shl 8) or B;
    end;

    function Encode(V: UInt32): UInt32;
    var
      R, G, B, A, Gray: UInt32;
    begin
      R := V shr 16 and 255;
      G := V shr 8 and 255;
      B := V and 255;
      A := V shr 24;
      case Format of
        -1, 1, 2, 4, 8:
          begin
            Gray := (R * 299 + G * 587 + B * 114 + 500) div 1000;
            Result := ((255 - Gray) * UInt32((1 shl Bits) - 1) + 127) div 255;
          end;
        332:
          Result := ((R shr 5) shl 5) or ((G shr 5) shl 2) or (B shr 6);
        444:
          Result := ((R shr 4) shl 8) or ((G shr 4) shl 4) or (B shr 4);
        4444:
          Result := ((A shr 4) shl 12) or ((R shr 4) shl 8) or ((G shr 4) shl 4) or (B shr 4);
        555, 1555:
          begin
            Result := ((R shr 3) shl 10) or ((G shr 3) shl 5) or (B shr 3);
            if (Format = 1555) and (A <> 0) then
              Result := Result or $8000;
          end;
        565:
          Result := ((R shr 3) shl 11) or ((G shr 2) shl 5) or (B shr 3);
        888:
          Result := V and $FFFFFF;
      else
        Result := V;
      end;
    end;

  begin
    ReadBack := N = 'getPixels';
    Data := VM.GetObject(Args[1].AsRef);
    Mask := nil;
    ByteData := Method.Descriptor.StartsWith('([B');
    Alpha := False;
    Start := 2;
    if ByteData then
    begin
      if Args[2].AsRef <> 0 then
        Mask := VM.GetObject(Args[2].AsRef);
      Inc(Start);
    end
    else if not ReadBack then
    begin
      Alpha := Arg(2) <> 0;
      Inc(Start);
    end;
    Base := Arg(Start);
    Scan := Arg(Start + 1);
    DX := Int64(Arg(Start + 2)) + TX;
    DY := Int64(Arg(Start + 3)) + TY;
    W := Arg(Start + 4);
    H := Arg(Start + 5);
    Manip := 0;
    if ReadBack then
      Format := Arg(Start + 6)
    else
    begin
      Manip := Arg(Start + 6);
      Format := Arg(Start + 7);
      CheckManipulation(VM, Manip);
    end;
    Bits := 8;
    if ByteData then
    begin
      if not ((Format = -1) or (Format = 1) or (Format = 2) or (Format = 4) or (Format = 8) or (Format = 332)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Byte pixel format');
      if Format = -1 then
        Bits := 1
      else if Format < 8 then
        Bits := Format;
    end
    else if Data.ClassName = '[S' then
    begin
      if not ((Format = 444) or (Format = 4444) or (Format = 555) or (Format = 1555) or (Format = 565)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Short pixel format');
    end
    else if (Format <> 888) and (Format <> 8888) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Int pixel format');
    if (W < 0) or (H < 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Pixel dimensions');
    if ReadBack and ((Arg(Start + 2) < 0) or (Arg(Start + 3) < 0) or (DX < 0) or (DY < 0) or (DX + W > Width) or (DY + H > Height)) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Pixel source region');
    if (W = 0) or (H = 0) then
      Exit;
    if Format = -1 then
    begin
      if Scan <= 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Vertical pixel scanlength');
      if Base < 0 then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      Lo := Int64(Base div Scan div 8) * Scan + Base mod Scan;
      Hi := ((Int64(Base div Scan) + H - 1) div 8) * Scan + Base mod Scan + W - 1;
    end
    else
    begin
      Tail := Int64(Base) + Int64(H - 1) * Scan;
      Lo := Min(Int64(Base), Tail);
      Hi := Max(Int64(Base), Tail) + W - 1;
      if ByteData then
      begin
        if Lo < 0 then
          VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
        Lo := Lo div (8 div Bits);
        Hi := Hi div (8 div Bits);
      end;
    end;
    if (Lo < 0) or (Hi >= Data.ElementCount) or ((Mask <> nil) and (Hi >= Mask.ElementCount)) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    if ReadBack then
    begin
      // Validate every range before changing either caller-owned array.
      for var Y := 0 to H - 1 do
        for var X := 0 to W - 1 do
        begin
          Value := ReadPixel((Integer(DY) + Y) * Width + Integer(DX) + X);
          if TargetPixels = nil then
            Value := Value or $FF000000;
          if ByteData then
          begin
            StorePacked(Data, X, Y, Encode(Value));
            if Mask <> nil then
              StorePacked(Mask, X, Y, ((Integer(Value shr 24) * ((1 shl Bits) - 1) + 127) div 255));
          end
          else
          begin
            Index := Int64(Base) + Int64(Y) * Scan + X;
            if Data.ClassName = '[S' then
              Data.ElementValues[Integer(Index)] := TJVMValue.Int(SmallInt(Encode(Value)))
            else
              Data.ElementValues[Integer(Index)] := TJVMValue.Int(Integer(Encode(Value)));
          end;
        end;
      Exit;
    end;
    DW := W;
    DH := H;
    if ((Manip and $1FF) = 90) or ((Manip and $1FF) = 270) then
    begin
      DW := H;
      DH := W;
    end;
    // Rendering is bounded by the visible destination, even for huge overlapping strides.
    for var Y := Max(Int64(CT), DY) to Min(Int64(CB) - 1, DY + DH - 1) do
      for var X := Max(Int64(CL), DX) to Min(Int64(CR) - 1, DX + DW - 1) do
      begin
        DirectSource(Integer(X - DX), Integer(Y - DY), W, H, Manip, SX, SY);
        if ByteData then
        begin
          Value := Decode(ReadPacked(Data, SX, SY));
          if Mask <> nil then
            Value := (Value and $FFFFFF) or (Expand(ReadPacked(Mask, SX, SY), (1 shl Bits) - 1) shl 24);
        end
        else
          Value := Decode(UInt32(Data.ElementValues[Integer(Int64(Base) + Int64(SY) * Scan + SX)].AsInt));
        Blend(X, Y, Value);
      end;
  end;

  procedure DirectPolygon;
  var
    PX, PY: TArray<Int64>;
    XA, YA: TJVMObject;
    Count, XO, YO: Integer;
    Fill: Boolean;
    L, T, R, B: Int64;
    Last, CrossingCount: Integer;
    Crossings: TArray<Double>;
  begin
    Fill := N.StartsWith('fill');
    if (N = 'drawTriangle') or (N = 'fillTriangle') then
    begin
      Count := 3;
      PX := [Int64(Arg(1)) + TX, Int64(Arg(3)) + TX, Int64(Arg(5)) + TX];
      PY := [Int64(Arg(2)) + TY, Int64(Arg(4)) + TY, Int64(Arg(6)) + TY];
      Color := UInt32(Arg(7));
    end
    else
    begin
      XA := VM.GetObject(Args[1].AsRef);
      YA := VM.GetObject(Args[3].AsRef);
      XO := Arg(2);
      YO := Arg(4);
      Count := Arg(5);
      Color := UInt32(Arg(6));
      if (XO < 0) or (YO < 0) or (Count < 0) or (Int64(XO) + Count > XA.ElementCount) or (Int64(YO) + Count > YA.ElementCount) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      SetLength(PX, Count);
      SetLength(PY, Count);
      for var I := 0 to Count - 1 do
      begin
        PX[I] := Int64(XA.ElementValues[XO + I].AsInt) + TX;
        PY[I] := Int64(YA.ElementValues[YO + I].AsInt) + TY;
      end;
    end;
    if (Count = 0) or (CL >= CR) or (CT >= CB) or (Color shr 24 = 0) then
      Exit;
    if not Fill then
    begin
      // Deduplicate connected vertices/overlapping segments before alpha blending.
      // The bounded surface mask also handles degenerate and self-crossing polygons.
      SetLength(ShapePixels, Width * Height);
      var Saved := Color;
      Color := $FFFFFFFF;
      // Collect line coverage without changing the destination until all edges finish.
      CollectCoverage := True;
      try
        for var I := 0 to Count - 1 do
          Line(PX[I], PY[I], PX[(I + 1) mod Count], PY[(I + 1) mod Count]);
      finally
        CollectCoverage := False;
        Color := Saved;
      end;
      for var Y := CT to CB - 1 do
        for var X := CL to CR - 1 do
          if ShapePixels[Y * Width + X] <> 0 then
            Blend(X, Y, Color);
      Exit;
    end;
    if Count < 3 then
      Exit;
    L := PX[0];
    R := L;
    T := PY[0];
    B := T;
    for var I := 1 to Count - 1 do
    begin
      L := Min(L, PX[I]);
      R := Max(R, PX[I]);
      T := Min(T, PY[I]);
      B := Max(B, PY[I]);
    end;
    SetLength(Crossings, Count);
    for var Y := Max(Int64(CT), T) to Min(Int64(CB) - 1, B - 1) do
    begin
      CrossingCount := 0;
      Last := Count - 1;
      for var I := 0 to Count - 1 do
      begin
        // Half-open edges and pixel centers implement the even-odd fill rule.
        if (PY[I] > Y) <> (PY[Last] > Y) then
        begin
          Crossings[CrossingCount] := Double(PX[Last] - PX[I]) * (Double(Y) + 0.5 - PY[I]) / (PY[Last] - PY[I]) + PX[I];
          Inc(CrossingCount);
        end;
        Last := I;
      end;
      TArray.Sort<Double>(Crossings, TComparer<Double>.Default, 0, CrossingCount);
      var Pair := 0;
      while Pair + 1 < CrossingCount do
      begin
        for var X := Max(Int64(CL), Ceil(Crossings[Pair] - 0.5)) to Min(Int64(CR), Ceil(Crossings[Pair + 1] - 0.5)) - 1 do
          Blend(X, Y, Color);
        Inc(Pair, 2);
      end;
    end;
  end;

begin
  CollectCoverage := False;
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  Result := Default(TJVMValue);
  TargetPixels := nil;
  if O.Fields.TryGetValue('$target', TargetRef) then
  begin
    Target := J2MEImageView(VM, TargetRef.AsRef);
    TargetPixels := Target.Pixels;
    Width := Target.Width;
    Height := Target.Height;
  end;
  if TargetPixels = nil then
    Height := Min(Height, Get('displayHeight', Height));
  Color := (UInt32(Get('color')) and $FFFFFF) or (UInt32(Get('alpha', 255)) shl 24);
  TX := Get('tx');
  TY := Get('ty');
  // A retained display Graphics may predate a viewport resize. Its clip must
  // remain inside the physical raster, including during a restored paint call.
  CL := EnsureRange(Get('clipL'), 0, Width);
  CT := EnsureRange(Get('clipT'), 0, Height);
  CR := EnsureRange(Get('clipR', Width), CL, Width);
  CB := EnsureRange(Get('clipB', Height), CT, Height);
  Stroke := Get('stroke');
  if N = 'setARGBColor' then
  begin
    Put('color', Arg(1) and $FFFFFF);
    Put('alpha', UInt32(Arg(1)) shr 24);
    Exit;
  end;
  if N = 'getAlphaComponent' then
    Exit(TJVMValue.Int(Color shr 24));
  if N = 'getNativePixelFormat' then
    Exit(TJVMValue.Int(NativePixelFormat));
  if N = 'setColor' then
  begin
    I := Arg(1);
    if Length(Args) = 4 then
    begin
      R := I;
      G := Arg(2);
      B := Arg(3);
      if (R < 0) or (R > 255) or (G < 0) or (G > 255) or (B < 0) or (B > 255) then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      I := (R shl 16) or (G shl 8) or B;
    end;
    Put('color', I and $FFFFFF);
    Put('alpha', 255);
    Exit;
  end;
  if N = 'setGrayScale' then
  begin
    I := Arg(1);
    if (I < 0) or (I > 255) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    Put('color', I * $010101);
    Put('alpha', 255);
    Exit;
  end;
  if N = 'getColor' then
    Exit(TJVMValue.Int(Color and $FFFFFF));
  if N = 'getRedComponent' then
    Exit(TJVMValue.Int((Color shr 16) and 255));
  if N = 'getGreenComponent' then
    Exit(TJVMValue.Int((Color shr 8) and 255));
  if N = 'getBlueComponent' then
    Exit(TJVMValue.Int(Color and 255));
  if N = 'getGrayScale' then
    Exit(TJVMValue.Int((((Color shr 16) and 255) * 299 + ((Color shr 8) and 255) * 587 + (Color and 255) * 114 + 500) div 1000));
  if N = 'getDisplayColor' then
    Exit(TJVMValue.Int(Arg(1) and $FFFFFF));
  if N = 'translate' then
  begin
    Put('tx', TX + Arg(1));
    Put('ty', TY + Arg(2));
    Exit;
  end;
  if N = 'getTranslateX' then
    Exit(TJVMValue.Int(TX));
  if N = 'getTranslateY' then
    Exit(TJVMValue.Int(TY));
  if N = 'getClipX' then
    Exit(TJVMValue.Int(CL - TX));
  if N = 'getClipY' then
    Exit(TJVMValue.Int(CT - TY));
  if N = 'getClipWidth' then
    Exit(TJVMValue.Int(CR - CL));
  if N = 'getClipHeight' then
    Exit(TJVMValue.Int(CB - CT));
  if N = 'getStrokeStyle' then
    Exit(TJVMValue.Int(Stroke));
  if N = 'setStrokeStyle' then
  begin
    I := Arg(1);
    if (I < 0) or (I > 1) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    Put('stroke', I);
    Exit;
  end;
  if N = 'getFont' then
    Exit(TJVMValue.Ref(FontRef));
  if N = 'setFont' then
  begin
    I := Args[1].AsRef;
    if I = 0 then
      I := J2MEGetFont(VM);
    J2MEFontView(VM, I);
    O.Fields.AddOrSetValue('$font', TJVMValue.Ref(I));
    Exit;
  end;
  if (N = 'drawString') or (N = 'drawSubstring') or (N = 'drawChars') or (N = 'drawChar') then
  begin
    Font := J2MEFontView(VM, FontRef);
    if N = 'drawChar' then
    begin
      Text := Char(Arg(1));
      X1 := Int64(Arg(2)) + TX;
      Y1 := Int64(Arg(3)) + TY;
      TextAnchor := Arg(4);
    end
    else if N = 'drawChars' then
    begin
      RGB := VM.GetObject(Args[1].AsRef);
      Offset := Arg(2);
      I := Arg(3);
      if (Offset < 0) or (I < 0) or (Offset > RGB.ElementCount) or (I > RGB.ElementCount - Offset) then
        VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
      SetLength(Text, I);
      for var J := 0 to I - 1 do
        Text[J + 1] := Char(RGB.ElementValues[Offset + J].AsInt);
      X1 := Int64(Arg(4)) + TX;
      Y1 := Int64(Arg(5)) + TY;
      TextAnchor := Arg(6);
    end
    else
    begin
      Text := VM.GetObject(Args[1].AsRef).Text;
      if N = 'drawSubstring' then
      begin
        Offset := Arg(2);
        I := Arg(3);
        if (Offset < 0) or (I < 0) or (Offset > Length(Text)) or (I > Length(Text) - Offset) then
          VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
        Text := Copy(Text, Offset + 1, I);
        X1 := Int64(Arg(4)) + TX;
        Y1 := Int64(Arg(5)) + TY;
        TextAnchor := Arg(6);
      end
      else
      begin
        X1 := Int64(Arg(2)) + TX;
        Y1 := Int64(Arg(3)) + TY;
        TextAnchor := Arg(4);
      end;
    end;
    TextWidth := J2MEFontTextWidth(Font, Text);
    if (TextAnchor and 2) <> 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'VCENTER text anchor');
    if (TextAnchor and 64) <> 0 then
    begin
      if (TextAnchor and 50) <> 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Conflicting text anchor');
      Dec(Y1, Font.Baseline);
      TextAnchor := (TextAnchor and not 64) or 16;
    end;
    Anchor(X1, Y1, TextWidth, Font.Height, TextAnchor);
    for var C in Text do
    begin
      I := J2MEFontAdvance(Font, C);
      if (X1 < CR) and (X1 + I > CL) and (Y1 < CB) and (Y1 + Font.Height > CT) then
      begin
        Glyph := J2MEFontGlyph(Font, C);
        for var Row := 0 to Glyph.Height - 1 do
          for var Col := 0 to Glyph.Width - 1 do
            if Glyph.Mask[Row * Glyph.Width + Col] <> 0 then
              Pixel(X1 + Col, Y1 + Row);
      end;
      Inc(X1, I);
    end;
    Exit;
  end;
  if N = 'drawRGB' then
  begin
    RGB := VM.GetObject(Args[1].AsRef);
    Offset := Arg(2);
    Stride := Arg(3);
    X1 := Int64(Arg(4)) + TX;
    Y1 := Int64(Arg(5)) + TY;
    SW := Arg(6);
    SH := Arg(7);
    J2MECheckRGBBounds(VM, RGB, Offset, Stride, SW, SH);
    if (SW <= 0) or (SH <= 0) then
      Exit;
    for YY := Max(Int64(CT), Y1) to Min(Int64(CB) - 1, Y1 + SH - 1) do
      for XX := Max(Int64(CL), X1) to Min(Int64(CR) - 1, X1 + SW - 1) do
      begin
        var Value := UInt32(RGB.ElementValues[Integer(Int64(Offset) + (YY - Y1) * Stride + XX - X1)].AsInt);
        if Arg(8) = 0 then
          Value := Value or $FF000000;
        Blend(XX, YY, Value);
      end;
    Exit;
  end;
  if (N = 'drawImage') or (N = 'drawRegion') then
  begin
    Source := J2MEImageView(VM, Args[1].AsRef);
    SrcX := 0;
    SrcY := 0;
    SW := Source.Width;
    SH := Source.Height;
    Transform := 0;
    if N = 'drawImage' then
    begin
      X1 := Int64(Arg(2)) + TX;
      Y1 := Int64(Arg(3)) + TY;
      I := Arg(4);
      if Length(Args) = 6 then
      begin
        Transform := Arg(5);
        CheckManipulation(VM, Transform);
      end;
    end
    else
    begin
      SrcX := Arg(2);
      SrcY := Arg(3);
      SW := Arg(4);
      SH := Arg(5);
      Transform := Arg(6);
      X1 := Int64(Arg(7)) + TX;
      Y1 := Int64(Arg(8)) + TY;
      I := Arg(9);
      if (Source.Pixels = TargetPixels) or (Transform < 0) or (Transform > 7) or (SrcX < 0) or (SrcY < 0) or (SW < 0) or (SH < 0) or
        (Int64(SrcX) + SW > Source.Width) or (Int64(SrcY) + SH > Source.Height) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Image source region');
    end;
    DW := SW;
    DH := SH;
    if ((N = 'drawImage') and (Length(Args) = 6)) then
    begin
      if ((Transform and $1FF) = 90) or ((Transform and $1FF) = 270) then
      begin
        DW := SH;
        DH := SW;
      end;
    end
    else if Transform >= 4 then
    begin
      DW := SH;
      DH := SW;
    end;
    Anchor(X1, Y1, DW, DH, I);
    // Clip before narrowing coordinates to pixel indices. The anchor and
    // translation can place the image outside the Java int range.
    var Left := Max(Int64(CL), X1);
    var Top := Max(Int64(CT), Y1);
    var Right := Min(Int64(CR), X1 + DW);
    var Bottom := Min(Int64(CB), Y1 + DH);
    if (Left >= Right) or (Top >= Bottom) then
      Exit;
    if Source.Pixels = TargetPixels then
    begin
      SetLength(Snapshot, Source.Pixels.ElementCount);
      for I := 0 to High(Snapshot) do
        Snapshot[I] := UInt32(Source.Pixels.ElementValues[I].AsInt);
    end;
    // No transform/aliasing: copy opaque runs, skip binary transparency, and
    // invoke general source-over only for actually translucent pixels.
    if (Transform = 0) and (Length(Snapshot) = 0) then
    begin
      var SourceData, TargetData: PInteger;
      var DirectTarget := TargetPixels = nil;
      if DirectTarget then
      begin
        TargetData := nil;
        if Length(Pixels) <> 0 then
          TargetData := PInteger(@Pixels[0]);
      end
      else
        DirectTarget := TargetPixels.TryIntData(TargetData);
      if DirectTarget and Source.Pixels.TryIntData(SourceData) then
      begin
        for YY := Top to Bottom - 1 do
        begin
          var SourceIndex := (SrcY + Integer(YY - Y1)) * Source.Width + SrcX + Integer(Left - X1);
          var TargetIndex := Integer(YY) * Width + Integer(Left);
          var Remaining := Integer(Right - Left);
          while Remaining > 0 do
          begin
            var Value := UInt32(SourceData[SourceIndex]);
            if Value shr 24 = 255 then
            begin
              var Count := 1;
              while (Count < Remaining) and (UInt32(SourceData[SourceIndex + Count]) shr 24 = 255) do
                Inc(Count);
              Move(SourceData[SourceIndex], TargetData[TargetIndex], Count * 4);
              Inc(SourceIndex, Count);
              Inc(TargetIndex, Count);
              Dec(Remaining, Count);
            end
            else
            begin
              if Value shr 24 <> 0 then
                TargetData[TargetIndex] := Integer(J2MECompositeColor(UInt32(TargetData[TargetIndex]), Value));
              Inc(SourceIndex);
              Inc(TargetIndex);
              Dec(Remaining);
            end;
          end;
        end;
        Exit;
      end;
    end;
    for YY := Top to Bottom - 1 do
      for XX := Left to Right - 1 do
      begin
        if (N = 'drawImage') and (Length(Args) = 6) then
          DirectSource(Integer(XX - X1), Integer(YY - Y1), SW, SH, Transform, SX, SY)
        else
          J2METransformSource(Integer(XX - X1), Integer(YY - Y1), SW, SH, Transform, SX, SY);
        I := (SrcY + SY) * Source.Width + SrcX + SX;
        if Length(Snapshot) <> 0 then
          Blend(XX, YY, Snapshot[I])
        else
          Blend(XX, YY, UInt32(Source.Pixels.ElementValues[I].AsInt));
      end;
    Exit;
  end;
  if N = 'copyArea' then
  begin
    if TargetPixels = nil then
      VM.RaiseJava('java/lang/IllegalStateException', 'Display Graphics does not support copyArea');
    X1 := Int64(Arg(1)) + TX;
    Y1 := Int64(Arg(2)) + TY;
    SW := Arg(3);
    SH := Arg(4);
    if (X1 < 0) or (Y1 < 0) or (SW < 0) or (SH < 0) or (X1 + SW > Width) or (Y1 + SH > Height) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    X2 := Int64(Arg(5)) + TX;
    Y2 := Int64(Arg(6)) + TY;
    Anchor(X2, Y2, SW, SH, Arg(7));
    SetLength(Snapshot, SW * SH);
    for SrcY := 0 to SH - 1 do
      for SrcX := 0 to SW - 1 do
        Snapshot[SrcY * SW + SrcX] := ReadPixel((Integer(Y1) + SrcY) * Width + Integer(X1) + SrcX);
    for YY := Max(Int64(CT), Y2) to Min(Int64(CB) - 1, Y2 + SH - 1) do
      for XX := Max(Int64(CL), X2) to Min(Int64(CR) - 1, X2 + SW - 1) do
        Blend(XX, YY, Snapshot[Integer(YY - Y2) * SW + Integer(XX - X2)]);
    Exit;
  end;
  if (N = 'drawPixels') or (N = 'getPixels') then
  begin
    DirectPixels;
    Exit;
  end;
  if (N = 'drawPolygon') or (N = 'fillPolygon') or (N = 'drawTriangle') or ((N = 'fillTriangle') and (Length(Args) = 8)) then
  begin
    DirectPolygon;
    Exit;
  end;
  X1 := Int64(Arg(1)) + TX;
  Y1 := Int64(Arg(2)) + TY;
  if (N = 'setClip') or (N = 'clipRect') then
  begin
    X2 := X1 + Max(0, Arg(3));
    Y2 := Y1 + Max(0, Arg(4));
    if N = 'setClip' then
    begin
      CL := 0;
      CT := 0;
      CR := Width;
      CB := Height;
    end;
    CL := Integer(Max(Int64(CL), Min(Int64(CR), X1)));
    CT := Integer(Max(Int64(CT), Min(Int64(CB), Y1)));
    CR := Integer(Max(Int64(CL), Min(Int64(CR), X2)));
    CB := Integer(Max(Int64(CT), Min(Int64(CB), Y2)));
    Put('clipL', CL);
    Put('clipT', CT);
    Put('clipR', CR);
    Put('clipB', CB);
    Exit;
  end;
  W := Arg(3);
  H := Arg(4);
  if (N = 'drawArc') or (N = 'fillArc') or (N = 'drawRoundRect') or (N = 'fillRoundRect') then
  begin
    ShapePixels := Pixels;
    Raster.Init(CL, CT, CR, CB,
      procedure(Row, Left, Right: Integer)
      begin
        for var Col := Left to Right - 1 do
          if TargetPixels = nil then
            ShapePixels[Row * Width + Col] := J2MECompositeColor(ShapePixels[Row * Width + Col], Color)
          else
            TargetPixels.ElementValues[Row * Width + Col] := TJVMValue.Int(Integer(J2MECompositeColor(UInt32(TargetPixels.ElementValues[Row * Width + Col].AsInt), Color)));
      end);
    if (N = 'drawArc') or (N = 'fillArc') then
      Raster.Arc(X1, Y1, Integer(W), Integer(H), Arg(5), Arg(6), N = 'fillArc', Stroke <> 0)
    else
      Raster.RoundRect(X1, Y1, Integer(W), Integer(H), Arg(5), Arg(6), N = 'fillRoundRect', Stroke <> 0);
    Exit;
  end;
  if N = 'fillRect' then
  begin
    Rect(X1, Y1, W, H);
    Exit;
  end;
  if N = 'drawRect' then
  begin
    if (W < 0) or (H < 0) then
      Exit;
    if W = 0 then
    begin
      Line(X1, Y1, X1, Y1 + H);
      Exit;
    end;
    if H = 0 then
    begin
      Line(X1, Y1, X1 + W, Y1);
      Exit;
    end;
    Line(X1, Y1, X1 + W, Y1);
    Line(X1, Y1 + H, X1 + W, Y1 + H);
    if H > 1 then
    begin
      Line(X1, Y1, X1, Y1 + H, True);
      Line(X1 + W, Y1, X1 + W, Y1 + H, True);
    end;
    Exit;
  end;
  X2 := Int64(Arg(3)) + TX;
  Y2 := Int64(Arg(4)) + TY;
  if N = 'drawLine' then
  begin
    Line(X1, Y1, X2, Y2);
    Exit;
  end;
  if N = 'fillTriangle' then
  begin
    X3 := Int64(Arg(5)) + TX;
    Y3 := Int64(Arg(6)) + TY;
    for YY := Max(Int64(CT), Min(Y1, Min(Y2, Y3))) to Min(Int64(CB) - 1, Max(Y1, Max(Y2, Y3))) do
      for XX := Max(Int64(CL), Min(X1, Min(X2, X3))) to Min(Int64(CR) - 1, Max(X1, Max(X2, X3))) do
      begin
        C1 := Double(XX - X1) * (Y2 - Y1) - Double(YY - Y1) * (X2 - X1);
        C2 := Double(XX - X2) * (Y3 - Y2) - Double(YY - Y2) * (X3 - X2);
        C3 := Double(XX - X3) * (Y1 - Y3) - Double(YY - Y3) * (X1 - X3);
        if ((C1 >= 0) and (C2 >= 0) and (C3 >= 0)) or ((C1 <= 0) and (C2 <= 0) and (C3 <= 0)) then
          Pixel(XX, YY);
      end;
    Exit;
  end;
  raise EJVMUnsupported.Create('Graphics method not implemented: ' + N);
end;

end.

