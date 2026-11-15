unit J2ME.Game.Layers;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEGameLayers(VM: TJVM; SiemensColor: Boolean = False);

function J2MEGameLayersHandles(const ClassName: string): Boolean;

function InvokeJ2MEGameLayers(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.Image, J2ME.Graphics;

{$Q-}{$R-}

const
  MIDPGame = 'javax/microedition/lcdui/game/';
  SiemensGame = 'com/siemens/mp/color_game/';
  ImageD = 'Ljavax/microedition/lcdui/Image;';
  GraphicsD = 'Ljavax/microedition/lcdui/Graphics;';
  Prefix = '$game.';

type
  TBox = record
    L, T, R, B: Int64;
  end; // Exclusive right/bottom.

  TSpriteView = record
    O: TJVMObject;
    Image: TJ2MEImageView;
    FrameWidth, FrameHeight, Transform, SourceX, SourceY: Integer;
  end;

function J2MEGameLayersHandles(const ClassName: string): Boolean;
var
  Base, Name: string;
begin
  if ClassName.StartsWith(MIDPGame) then
    Base := MIDPGame
  else if ClassName.StartsWith(SiemensGame) then
    Base := SiemensGame
  else
    Exit(False);
  Name := ClassName.Substring(Length(Base));
  Result := (Name = 'Layer') or (Name = 'Sprite') or (Name = 'TiledLayer') or (Name = 'LayerManager');
end;

function Get(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Prefix + Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function Ref(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue(Prefix + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Prefix + Name, TJVMValue.Int(Value));
end;

procedure PutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue(Prefix + Name, TJVMValue.Ref(Value));
end;

procedure ForwardPoint(X, Y: Int64; W, H, Transform: Integer; out DX, DY: Int64);
begin
  case Transform of
    0:
      begin
        DX := X;
        DY := Y;
      end;
    1:
      begin
        DX := X;
        DY := H - 1 - Y;
      end;
    2:
      begin
        DX := W - 1 - X;
        DY := Y;
      end;
    3:
      begin
        DX := W - 1 - X;
        DY := H - 1 - Y;
      end;
    4:
      begin
        DX := Y;
        DY := X;
      end;
    5:
      begin
        DX := H - 1 - Y;
        DY := X;
      end;
    6:
      begin
        DX := Y;
        DY := W - 1 - X;
      end;
    7:
      begin
        DX := H - 1 - Y;
        DY := W - 1 - X;
      end;
  else
    raise EJVMFormatError.Create('Sprite transform');
  end;
end;

procedure ReferencePoint(O: TJVMObject; out X, Y: Int64);
begin
  ForwardPoint(Get(O, 'refX'), Get(O, 'refY'), Get(O, 'fw'), Get(O, 'fh'), Get(O, 'transform'), X, Y);
end;

procedure SetSize(O: TJVMObject);
begin
  if Get(O, 'transform') >= 4 then
  begin
    Put(O, 'w', Get(O, 'fh'));
    Put(O, 'h', Get(O, 'fw'));
  end
  else
  begin
    Put(O, 'w', Get(O, 'fw'));
    Put(O, 'h', Get(O, 'fh'));
  end;
  Put(O, 'maxW', Get(O, 'w'));
  Put(O, 'maxH', Get(O, 'h'));
end;

function Intersection(const A, B: TBox): TBox;
begin
  Result.L := Max(A.L, B.L);
  Result.T := Max(A.T, B.T);
  Result.R := Min(A.R, B.R);
  Result.B := Min(A.B, B.B);
end;

function Empty(const B: TBox): Boolean;
begin
  Result := (B.L >= B.R) or (B.T >= B.B);
end;

function Bounds(O: TJVMObject): TBox;
begin
  Result.L := Get(O, 'x');
  Result.T := Get(O, 'y');
  Result.R := Result.L + Get(O, 'w');
  Result.B := Result.T + Get(O, 'h');
end;

function CollisionBounds(O: TJVMObject): TBox;
var
  X, Y, X2, Y2: Int64;
begin
  if (Get(O, 'cw') = 0) or (Get(O, 'ch') = 0) then
    Exit(Default(TBox));
  ForwardPoint(Get(O, 'cx'), Get(O, 'cy'), Get(O, 'fw'), Get(O, 'fh'), Get(O, 'transform'), X, Y);
  ForwardPoint(Int64(Get(O, 'cx')) + Get(O, 'cw') - 1, Int64(Get(O, 'cy')) + Get(O, 'ch') - 1,
    Get(O, 'fw'), Get(O, 'fh'), Get(O, 'transform'), X2, Y2);
  Result.L := Int64(Get(O, 'x')) + Min(X, X2);
  Result.T := Int64(Get(O, 'y')) + Min(Y, Y2);
  Result.R := Int64(Get(O, 'x')) + Max(X, X2) + 1;
  Result.B := Int64(Get(O, 'y')) + Max(Y, Y2) + 1;
end;

function SpriteView(VM: TJVM; O: TJVMObject): TSpriteView;
var
  Frame: Integer;
begin
  Result.O := O;
  Result.Image := J2MEImageView(VM, Ref(O, 'image'));
  Result.FrameWidth := Get(O, 'fw');
  Result.FrameHeight := Get(O, 'fh');
  Result.Transform := Get(O, 'transform');
  Frame := Get(O, 'frame');
  if Ref(O, 'sequence') <> 0 then
    Frame := VM.GetObject(Ref(O, 'sequence')).Elements[Frame].AsInt;
  // Siemens exposes protected image replacement independently of sprite frames.
  // Reject an incompatible image before calculating a source-column modulus.
  if (Result.FrameWidth <= 0) or (Result.FrameHeight <= 0) or
    (Result.Image.Width < Result.FrameWidth) or (Result.Image.Height < Result.FrameHeight) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Layer image is smaller than a frame');
  Result.SourceX := (Frame mod (Result.Image.Width div Result.FrameWidth)) * Result.FrameWidth;
  Result.SourceY := (Frame div (Result.Image.Width div Result.FrameWidth)) * Result.FrameHeight;
end;

function OpaqueSpritePixel(const S: TSpriteView; X, Y: Int64): Boolean;
var
  SX, SY: Integer;
begin
  X := X - Get(S.O, 'x');
  Y := Y - Get(S.O, 'y');
  if (X < 0) or (Y < 0) or (X >= Get(S.O, 'w')) or (Y >= Get(S.O, 'h')) then
    Exit(False);
  J2METransformSource(Integer(X), Integer(Y), S.FrameWidth, S.FrameHeight, S.Transform, SX, SY);
  Result := UInt32(S.Image.Pixels.Elements[(S.SourceY + SY) * S.Image.Width + S.SourceX + SX].AsInt) shr 24 = 255;
end;

function TileAt(VM: TJVM; O: TJVMObject; Col, Row: Integer): Integer;
begin
  Result := VM.GetObject(Ref(O, 'cells')).Elements[Row * Get(O, 'cols') + Col].AsInt;
  if Result < 0 then
    Result := VM.GetObject(Ref(O, 'animated')).Elements[-Result - 1].AsInt;
end;

function SpriteCollision(VM: TJVM; O, Other: TJVMObject; OtherRef: Integer; const Descriptor: string; X, Y: Integer; PixelLevel: Boolean): Boolean;
var
  Area, OtherBox: TBox;
  S, S2: TSpriteView;
  Img: TJ2MEImageView;
  XX, YY: Int64;
  Tile, Col, Row, SX, SY, TW, TH: Integer;
begin
  if Get(O, 'visible') = 0 then
    Exit(False);
  Area := CollisionBounds(O);
  if Descriptor.StartsWith('(' + ImageD) then
  begin
    Img := J2MEImageView(VM, OtherRef);
    OtherBox.L := X;
    OtherBox.T := Y;
    OtherBox.R := Int64(X) + Img.Width;
    OtherBox.B := Int64(Y) + Img.Height;
    Area := Intersection(Area, OtherBox);
    if Empty(Area) then
      Exit(False);
    if not PixelLevel then
      Exit(True);
    Area := Intersection(Area, Bounds(O));
    S := SpriteView(VM, O);
    for YY := Area.T to Area.B - 1 do
      for XX := Area.L to Area.R - 1 do
        if OpaqueSpritePixel(S, XX, YY) and (UInt32(Img.Pixels.Elements[Integer(YY - Y) * Img.Width + Integer(XX - X)].AsInt) shr 24 = 255) then
          Exit(True);
    Exit(False);
  end;
  if Get(Other, 'visible') = 0 then
    Exit(False);
  if Descriptor.Contains('/Sprite;') then
  begin
    Area := Intersection(Area, CollisionBounds(Other));
    if Empty(Area) then
      Exit(False);
    if not PixelLevel then
      Exit(True);
    Area := Intersection(Intersection(Area, Bounds(O)), Bounds(Other));
    S := SpriteView(VM, O);
    S2 := SpriteView(VM, Other);
    for YY := Area.T to Area.B - 1 do
      for XX := Area.L to Area.R - 1 do
        if OpaqueSpritePixel(S, XX, YY) and OpaqueSpritePixel(S2, XX, YY) then
          Exit(True);
    Exit(False);
  end;
  Area := Intersection(Area, Bounds(Other));
  if Empty(Area) then
    Exit(False);
  TW := Get(Other, 'tw');
  TH := Get(Other, 'th');
  if not PixelLevel then
  begin
    for Row := Integer((Area.T - Get(Other, 'y')) div TH) to Integer((Area.B - 1 - Get(Other, 'y')) div TH) do
      for Col := Integer((Area.L - Get(Other, 'x')) div TW) to Integer((Area.R - 1 - Get(Other, 'x')) div TW) do
        if TileAt(VM, Other, Col, Row) <> 0 then
          Exit(True);
    Exit(False);
  end;
  Area := Intersection(Area, Bounds(O));
  S := SpriteView(VM, O);
  Img := J2MEImageView(VM, Ref(Other, 'image'));
  for YY := Area.T to Area.B - 1 do
    for XX := Area.L to Area.R - 1 do
      if OpaqueSpritePixel(S, XX, YY) then
      begin
        Col := Integer((XX - Get(Other, 'x')) div TW);
        Row := Integer((YY - Get(Other, 'y')) div TH);
        Tile := TileAt(VM, Other, Col, Row);
        if Tile = 0 then
          Continue;
        Dec(Tile);
        SX := (Tile mod (Img.Width div TW)) * TW + Integer((XX - Get(Other, 'x')) mod TW);
        SY := (Tile div (Img.Width div TW)) * TH + Integer((YY - Get(Other, 'y')) mod TH);
        if UInt32(Img.Pixels.Elements[SY * Img.Width + SX].AsInt) shr 24 = 255 then
          Exit(True);
      end;
  Result := False;
end;

procedure InstallJ2MEGameLayers(VM: TJVM; SiemensColor: Boolean);
var
  B: TJavaClassBuilder;
  H: TJVMExceptionHandler;
  Base, LayerName, SpriteName, TileName, ManagerName, LayerD: string;

  procedure Native(const Name, Descriptor: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Descriptor).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

begin
  Base := MIDPGame;
  if SiemensColor then
    Base := SiemensGame;
  LayerName := Base + 'Layer';
  SpriteName := Base + 'Sprite';
  TileName := Base + 'TiledLayer';
  ManagerName := Base + 'LayerManager';
  LayerD := 'L' + LayerName + ';';
  B := nil;
  try
    B := TJavaClassBuilder.Create(LayerName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    Native('<init>', '(II)V', JVM_ACC_PROTECTED);
    if SiemensColor then
    begin
      Native('<init>', '(' + ImageD + ')V', JVM_ACC_PROTECTED);
      Native('getLayerImage', '()' + ImageD, JVM_ACC_PROTECTED);
      Native('setLayerImage', '(' + ImageD + ')V', JVM_ACC_PROTECTED);
      Native('copyAllLayerVariables', '(' + LayerD + ')V', JVM_ACC_PROTECTED);
      Native('setWidth', '(I)V');
      Native('setHeight', '(I)V');
      B.Field('NativeMemoryTable', 'Lcom/siemens/mp/misc/NativeMem;', JVM_ACC_PROTECTED);
    end;
    for var N in ['getX', 'getY', 'getWidth', 'getHeight'] do
      Native(N, '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Native('isVisible', '()Z', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Native('move', '(II)V');
    Native('setPosition', '(II)V');
    Native('setVisible', '(Z)V');
    B.JavaClass.AddNative('paint', '(' + GraphicsD + ')V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Done;
    B := TJavaClassBuilder.Create(SpriteName, LayerName);
    for var D in ['(' + ImageD + ')V', '(' + ImageD + 'II)V', '(L' + SpriteName + ';)V'] do
      Native('<init>', D);
    Native('getRawFrameCount', '()I');
    Native('getFrame', '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    if SiemensColor then
    begin
      Native('getFrameSequenceLength', '()I');
      Native('setCollisionRectangle', '(IIII)V');
    end
    else
    begin
      for var N in ['getRefPixelX', 'getRefPixelY'] do
        Native(N, '()I');
      Native('getFrameSequenceLength', '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
      Native('defineReferencePixel', '(II)V');
      Native('setRefPixelPosition', '(II)V');
      Native('defineCollisionRectangle', '(IIII)V');
      Native('setTransform', '(I)V');
    end;
    Native('setFrame', '(I)V');
    Native('setFrameSequence', '([I)V');
    Native('nextFrame', '()V');
    Native('prevFrame', '()V');
    Native('setImage', '(' + ImageD + 'II)V');
    Native('paint', '(' + GraphicsD + ')V', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    if SiemensColor then
    begin
      Native('collidesWith', '(L' + SpriteName + ';Z)Z');
      Native('collidesWith', '(' + ImageD + 'IIZ)Z');
    end
    else
    begin
      Native('collidesWith', '(L' + SpriteName + ';Z)Z', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
      Native('collidesWith', '(L' + TileName + ';Z)Z', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
      Native('collidesWith', '(' + ImageD + 'IIZ)Z', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
      var Names := TArray<string>.Create('TRANS_NONE', 'TRANS_MIRROR_ROT180', 'TRANS_MIRROR', 'TRANS_ROT180', 'TRANS_MIRROR_ROT270', 'TRANS_ROT90', 'TRANS_ROT270', 'TRANS_MIRROR_ROT90');
      for var I := 0 to High(Names) do
      begin
        B.Field(Names[I], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
        B.JavaClass.Fields.Last.Value := TJVMValue.Int(I);
      end;
    end;
    Done;
    B := TJavaClassBuilder.Create(TileName, LayerName);
    Native('<init>', '(II' + ImageD + 'II)V');
    for var N in ['getCellWidth', 'getCellHeight', 'getColumns', 'getRows'] do
      Native(N, '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Native('setCell', '(III)V');
    Native('getCell', '(II)I');
    Native('fillCells', '(IIIII)V');
    Native('createAnimatedTile', '(I)I');
    Native('setAnimatedTile', '(II)V');
    Native('getAnimatedTile', '(I)I');
    Native('setStaticTileSet', '(' + ImageD + 'II)V');
    Native('paint', '(' + GraphicsD + ')V', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
    Done;
    B := TJavaClassBuilder.Create(ManagerName, 'java/lang/Object');
    Native('<init>', '()V');
    if SiemensColor then
    begin
      B.Field('NativeMemoryTable', 'Lcom/siemens/mp/misc/NativeMem;', JVM_ACC_PROTECTED);
      Native('removeLayer', '(Lcom/siemens/mp/misc/NativeMem;' + LayerD + ')V');
    end;
    Native('append', '(' + LayerD + ')V');
    Native('insert', '(' + LayerD + 'I)V');
    Native('remove', '(' + LayerD + ')V');
    Native('getSize', '()I');
    Native('getLayerAt', '(I)' + LayerD);
    Native('setViewWindow', '(IIII)V');
    Native('$beginPaint', '(' + GraphicsD + 'II)[Ljava/lang/Object;', JVM_ACC_PRIVATE);
    Native('$endPaint', '(' + GraphicsD + '[Ljava/lang/Object;)V', JVM_ACC_PRIVATE);
    B.Start;
    B.Emit([$2A, $2B, $1C, $1D]);
    B.Ref($B7, B.Member(ManagerName, '$beginPaint', '(' + GraphicsD + 'II)[Ljava/lang/Object;'));
    B.Emit([$3A, 4, $19, 4, $BE, $04, $64, $36, 5]);
    B.Mark('try');
    B.Mark('loop');
    B.Emit([$15, 5]);
    B.Jump($9E, 'end');
    B.Emit([$19, 4, $15, 5, $32]);
    B.Ref($C0, B.ClassRef(LayerName));
    B.Emit([$2B]);
    B.Ref($B6, B.Member(LayerName, 'paint', '(' + GraphicsD + ')V'));
    B.Emit([$84, 5, $FF]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$2A, $2B, $19, 4]);
    B.Ref($B7, B.Member(ManagerName, '$endPaint', '(' + GraphicsD + '[Ljava/lang/Object;)V'));
    B.Emit([$B1]);
    B.Mark('catch');
    B.Emit([$3A, 6, $2A, $2B, $19, 4]);
    B.Ref($B7, B.Member(ManagerName, '$endPaint', '(' + GraphicsD + '[Ljava/lang/Object;)V'));
    B.Emit([$19, 6, $BF]);
    B.Finish('paint', '(' + GraphicsD + 'II)V', JVM_ACC_PUBLIC, 4, 7);
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('try');
    H.EndPC := B.Position('end');
    H.HandlerPC := B.Position('catch');
    B.JavaClass.Methods.Last.Handlers := [H];
    Done;
  finally
    B.Free;
  end;
end;

function InvokeJ2MEGameLayers(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; var Pixels: TArray<UInt32>; Width, Height: Integer): TJVMValue;
var
  O, Other, ArrayObject, NewArray, Sequence, State, Snapshot, ClipObject: TJVMObject;
  C, N, D, Base, LayerName, SpriteName, TileName, ManagerName, LayerD: string;
  SiemensColor: Boolean;
  SavedClip: array[0..3] of TJVMValue;
  SavedClipMask: Integer;
  Image: TJ2MEImageView;
  S: TSpriteView;
  I, J, K, W, H, OldCount, Count, Index, Col, Row, Tile, G, GraphicRef, NewRef: Integer;
  X, Y, X2, Y2, WX, WY, ClipX, ClipY, ClipW, ClipH: Int64;
  V: TJVMValue;

  function Arg(Index: Integer): Integer;
  begin
    Result := Args[Index].AsInt;
  end;

  procedure Check(Condition: Boolean; const Error: string = 'java/lang/IllegalArgumentException');
  begin
    if not Condition then
      VM.RaiseJava(Error);
  end;

  procedure Graphic(const Name, Descriptor: string; const Values: array of TJVMValue);
  var
    A: TArray<TJVMValue>;
  begin
    SetLength(A, Length(Values));
    for var L := 0 to High(Values) do
      A[L] := Values[L];
    InvokeJ2MEGraphics(VM, VM.LoadClass('javax/microedition/lcdui/Graphics').FindMethod(Name, Descriptor), A, Pixels, Width, Height);
  end;

  function GraphicInt(const Name: string): Integer;
  begin
    Result := InvokeJ2MEGraphics(VM, VM.LoadClass('javax/microedition/lcdui/Graphics').FindMethod(Name, '()I'), [TJVMValue.Ref(GraphicRef)], Pixels, Width, Height).AsInt;
  end;

  procedure Region(Img, SX, SY, SW, SH, Transform, DX, DY: Integer);
  begin
    Graphic('drawRegion', '(' + ImageD + 'IIIIIIII)V', [TJVMValue.Ref(GraphicRef), TJVMValue.Ref(Img), TJVMValue.Int(SX), TJVMValue.Int(SY),
        TJVMValue.Int(SW), TJVMValue.Int(SH), TJVMValue.Int(Transform), TJVMValue.Int(DX), TJVMValue.Int(DY), TJVMValue.Int(20)]);
  end;

  procedure BeginLayerClip;
  begin
    if not SiemensColor then
      Exit;
    ClipObject := VM.GetObject(GraphicRef);
    SavedClipMask := 0;
    var L := 0;
    for var Key in ['$clipL', '$clipT', '$clipR', '$clipB'] do
    begin
      if ClipObject.Fields.TryGetValue(Key, SavedClip[L]) then
        SavedClipMask := SavedClipMask or (1 shl L);
      Inc(L);
    end;
    Graphic('clipRect', '(IIII)V', [TJVMValue.Ref(GraphicRef), TJVMValue.Int(Get(O, 'x')), TJVMValue.Int(Get(O, 'y')),
        TJVMValue.Int(Get(O, 'w')), TJVMValue.Int(Get(O, 'h'))]);
  end;

  procedure EndLayerClip;
  begin
    if not SiemensColor then
      Exit;
    var L := 0;
    for var Key in ['$clipL', '$clipT', '$clipR', '$clipB'] do
    begin
      if (SavedClipMask and (1 shl L)) = 0 then
        ClipObject.Fields.Remove(Key)
      else
        ClipObject.Fields.AddOrSetValue(Key, SavedClip[L]);
      Inc(L);
    end;
  end;

  procedure FrameSet;
  begin
    Image := J2MEImageView(VM, Args[1].AsRef);
    W := Arg(2);
    H := Arg(3);
    Check((W > 0) and (H > 0));
    Check((Image.Width mod W = 0) and (Image.Height mod H = 0));
    Count := (Image.Width div W) * (Image.Height div H);
  end;

  function SequenceLength: Integer;
  begin
    if Ref(O, 'sequence') = 0 then
      Result := Get(O, 'rawCount')
    else
      Result := Length(VM.GetObject(Ref(O, 'sequence')).Elements);
  end;

  procedure StaticTile(Index: Integer);
  begin
    Check((Index >= 0) and (Index <= Get(O, 'rawCount')), 'java/lang/IndexOutOfBoundsException');
  end;

  procedure AnyTile(Index: Integer);
  begin
    if Index >= 0 then
      StaticTile(Index)
    else
      Check((-Int64(Index) <= Get(O, 'animatedCount')), 'java/lang/IndexOutOfBoundsException');
  end;

  procedure Cell(Col, Row: Integer);
  begin
    Check((Col >= 0) and (Col < Get(O, 'cols')) and (Row >= 0) and (Row < Get(O, 'rows')), 'java/lang/IndexOutOfBoundsException');
  end;

begin
  O := VM.GetObject(Args[0].AsRef);
  C := Method.Owner.Name;
  N := Method.Name;
  D := Method.Descriptor;
  Result := Default(TJVMValue);
  SiemensColor := C.StartsWith(SiemensGame);
  Base := MIDPGame;
  if SiemensColor then
    Base := SiemensGame;
  LayerName := Base + 'Layer';
  SpriteName := Base + 'Sprite';
  TileName := Base + 'TiledLayer';
  ManagerName := Base + 'LayerManager';
  LayerD := 'L' + LayerName + ';';
  if C = LayerName then
  begin
    if N = '<init>' then
    begin
      if D = '(II)V' then
      begin
        W := Arg(1);
        H := Arg(2);
        Check((W >= 0) and (H >= 0));
      end
      else
      begin
        Image := J2MEImageView(VM, Args[1].AsRef);
        W := Image.Width;
        H := Image.Height;
        PutRef(O, 'image', Args[1].AsRef);
      end;
      Put(O, 'w', W);
      Put(O, 'h', H);
      Put(O, 'maxW', W);
      Put(O, 'maxH', H);
      Put(O, 'visible', 1);
      Exit;
    end;
    if N = 'getLayerImage' then
      Exit(TJVMValue.Ref(Ref(O, 'image')));
    if N = 'setLayerImage' then
    begin
      VM.GetObject(Args[1].AsRef);
      PutRef(O, 'image', Args[1].AsRef);
      Exit;
    end;
    if N = 'copyAllLayerVariables' then
    begin
      Other := VM.GetObject(Args[1].AsRef);
      for var Key in ['x', 'y', 'w', 'h', 'maxW', 'maxH', 'visible'] do
        Put(Other, Key, Get(O, Key));
      PutRef(Other, 'image', Ref(O, 'image'));
      var Key := SiemensGame + 'Layer.NativeMemoryTable:Lcom/siemens/mp/misc/NativeMem;';
      if O.Fields.TryGetValue(Key, V) then
        Other.Fields.AddOrSetValue(Key, V);
      Exit;
    end;
    if (N = 'setWidth') or (N = 'setHeight') then
    begin
      var Key := 'w';
      var Limit := 'maxW';
      if N = 'setHeight' then
      begin
        Key := 'h';
        Limit := 'maxH';
      end;
      Check((Arg(1) >= 0) and (Arg(1) <= Get(O, Limit)));
      Put(O, Key, Arg(1));
      Exit;
    end;
    if N = 'getX' then
      Exit(TJVMValue.Int(Get(O, 'x')));
    if N = 'getY' then
      Exit(TJVMValue.Int(Get(O, 'y')));
    if N = 'getWidth' then
      Exit(TJVMValue.Int(Get(O, 'w')));
    if N = 'getHeight' then
      Exit(TJVMValue.Int(Get(O, 'h')));
    if N = 'isVisible' then
      Exit(TJVMValue.Int(Get(O, 'visible')));
    if N = 'setVisible' then
    begin
      Put(O, 'visible', Ord(Arg(1) <> 0));
      Exit;
    end;
    if N = 'setPosition' then
    begin
      Put(O, 'x', Arg(1));
      Put(O, 'y', Arg(2));
      Exit;
    end;
    if N = 'move' then
    begin
      Put(O, 'x', Get(O, 'x') + Arg(1));
      Put(O, 'y', Get(O, 'y') + Arg(2));
      Exit;
    end;
  end;
  if C = SpriteName then
  begin
    if N = '<init>' then
    begin
      if D = '(L' + SpriteName + ';)V' then
      begin
        Other := VM.GetObject(Args[1].AsRef);
        for var Pair in Other.Fields do
          if Pair.Key.StartsWith(Prefix) then
            O.Fields.AddOrSetValue(Pair.Key, Pair.Value);
        if SiemensColor then
        begin
          var Key := SiemensGame + 'Layer.NativeMemoryTable:Lcom/siemens/mp/misc/NativeMem;';
          if Other.Fields.TryGetValue(Key, V) then
            O.Fields.AddOrSetValue(Key, V);
        end;
        if Ref(O, 'sequence') <> 0 then
        begin
          Sequence := VM.GetObject(Ref(O, 'sequence'));
          NewRef := VM.NewArray('[I', Length(Sequence.Elements));
          VM.GetObject(NewRef).Elements := Copy(Sequence.Elements);
          PutRef(O, 'sequence', NewRef);
        end;
        Exit;
      end;
      Image := J2MEImageView(VM, Args[1].AsRef);
      W := Image.Width;
      H := Image.Height;
      if Length(Args) = 4 then
      begin
        FrameSet;
      end
      else
        Count := 1;
      PutRef(O, 'image', Args[1].AsRef);
      Put(O, 'fw', W);
      Put(O, 'fh', H);
      Put(O, 'rawCount', Count);
      Put(O, 'visible', 1);
      Put(O, 'cw', W);
      Put(O, 'ch', H);
      SetSize(O);
      Exit;
    end;
    if N = 'defineReferencePixel' then
    begin
      Put(O, 'refX', Arg(1));
      Put(O, 'refY', Arg(2));
      Exit;
    end;
    if (N = 'getRefPixelX') or (N = 'getRefPixelY') then
    begin
      ReferencePoint(O, X, Y);
      if N = 'getRefPixelX' then
        Exit(TJVMValue.Int(Integer(X + Get(O, 'x'))))
      else
        Exit(TJVMValue.Int(Integer(Y + Get(O, 'y'))));
    end;
    if N = 'setRefPixelPosition' then
    begin
      ReferencePoint(O, X, Y);
      Put(O, 'x', Integer(Int64(Arg(1)) - X));
      Put(O, 'y', Integer(Int64(Arg(2)) - Y));
      Exit;
    end;
    if N = 'setTransform' then
    begin
      Check((Arg(1) >= 0) and (Arg(1) <= 7));
      ReferencePoint(O, X, Y);
      WX := Get(O, 'x') + X;
      WY := Get(O, 'y') + Y;
      Put(O, 'transform', Arg(1));
      ReferencePoint(O, X, Y);
      Put(O, 'x', Integer(WX - X));
      Put(O, 'y', Integer(WY - Y));
      SetSize(O);
      Exit;
    end;
    if N = 'getRawFrameCount' then
      Exit(TJVMValue.Int(Get(O, 'rawCount')));
    if N = 'getFrameSequenceLength' then
      Exit(TJVMValue.Int(SequenceLength));
    if N = 'getFrame' then
      Exit(TJVMValue.Int(Get(O, 'frame')));
    if N = 'setFrame' then
    begin
      Check((Arg(1) >= 0) and (Arg(1) < SequenceLength), 'java/lang/IndexOutOfBoundsException');
      Put(O, 'frame', Arg(1));
      Exit;
    end;
    if N = 'nextFrame' then
    begin
      Put(O, 'frame', (Get(O, 'frame') + 1) mod SequenceLength);
      Exit;
    end;
    if N = 'prevFrame' then
    begin
      Put(O, 'frame', (Get(O, 'frame') + SequenceLength - 1) mod SequenceLength);
      Exit;
    end;
    if N = 'setFrameSequence' then
    begin
      NewRef := 0;
      if Args[1].AsRef <> 0 then
      begin
        Sequence := VM.GetObject(Args[1].AsRef);
        Check(Length(Sequence.Elements) > 0);
        for V in Sequence.Elements do
          Check((V.AsInt >= 0) and (V.AsInt < Get(O, 'rawCount')), 'java/lang/ArrayIndexOutOfBoundsException');
        NewRef := VM.NewArray('[I', Length(Sequence.Elements));
        VM.GetObject(NewRef).Elements := Copy(Sequence.Elements);
      end;
      PutRef(O, 'sequence', NewRef);
      Put(O, 'frame', 0);
      Exit;
    end;
    if N = 'setImage' then
    begin
      FrameSet;
      OldCount := Get(O, 'rawCount');
      ReferencePoint(O, X, Y);
      WX := Get(O, 'x') + X;
      WY := Get(O, 'y') + Y;
      if (Get(O, 'fw') <> W) or (Get(O, 'fh') <> H) then
      begin
        Put(O, 'cx', 0);
        Put(O, 'cy', 0);
        Put(O, 'cw', W);
        Put(O, 'ch', H);
      end;
      PutRef(O, 'image', Args[1].AsRef);
      Put(O, 'fw', W);
      Put(O, 'fh', H);
      Put(O, 'rawCount', Count);
      if Count < OldCount then
      begin
        PutRef(O, 'sequence', 0);
        Put(O, 'frame', 0);
      end;
      ReferencePoint(O, X, Y);
      Put(O, 'x', Integer(WX - X));
      Put(O, 'y', Integer(WY - Y));
      SetSize(O);
      Exit;
    end;
    if (N = 'defineCollisionRectangle') or (N = 'setCollisionRectangle') then
    begin
      Check((Arg(3) >= 0) and (Arg(4) >= 0));
      Put(O, 'cx', Arg(1));
      Put(O, 'cy', Arg(2));
      Put(O, 'cw', Arg(3));
      Put(O, 'ch', Arg(4));
      Exit;
    end;
    if N = 'paint' then
    begin
      GraphicRef := Args[1].AsRef;
      VM.GetObject(GraphicRef);
      if Get(O, 'visible') = 0 then
        Exit;
      BeginLayerClip;
      try
        S := SpriteView(VM, O);
        Region(Ref(O, 'image'), S.SourceX, S.SourceY, S.FrameWidth, S.FrameHeight, S.Transform, Get(O, 'x'), Get(O, 'y'));
      finally
        EndLayerClip;
      end;
      Exit;
    end;
    if N = 'collidesWith' then
    begin
      Other := VM.GetObject(Args[1].AsRef);
      X := 0;
      Y := 0;
      if Length(Args) = 5 then
      begin
        X := Arg(2);
        Y := Arg(3);
        Result := TJVMValue.Int(Ord(SpriteCollision(VM, O, Other, Args[1].AsRef, D, Integer(X), Integer(Y), (Arg(4) <> 0) and not SiemensColor)));
      end
      else
        Result := TJVMValue.Int(Ord(SpriteCollision(VM, O, Other, Args[1].AsRef, D, 0, 0, (Arg(2) <> 0) and not SiemensColor)));
      Exit;
    end;
  end;
  if C = TileName then
  begin
    if N = '<init>' then
    begin
      Col := Arg(1);
      Row := Arg(2);
      Image := J2MEImageView(VM, Args[3].AsRef);
      W := Arg(4);
      H := Arg(5);
      Check((Col > 0) and (Row > 0) and (W > 0) and (H > 0));
      Check((Image.Width mod W = 0) and (Image.Height mod H = 0));
      if SiemensColor then
        Check((Image.Width div W) * (Image.Height div H) <= 32767);
      Check((Int64(Col) * Row <= VM.MaxArrayLength) and (Int64(Col) * W <= MaxInt) and (Int64(Row) * H <= MaxInt), 'java/lang/OutOfMemoryError');
      Put(O, 'cols', Col);
      Put(O, 'rows', Row);
      Put(O, 'tw', W);
      Put(O, 'th', H);
      Put(O, 'w', Col * W);
      Put(O, 'h', Row * H);
      Put(O, 'visible', 1);
      Put(O, 'maxW', Col * W);
      Put(O, 'maxH', Row * H);
      PutRef(O, 'image', Args[3].AsRef);
      Put(O, 'rawCount', (Image.Width div W) * (Image.Height div H));
      PutRef(O, 'cells', VM.NewArray('[I', Col * Row));
      Exit;
    end;
    if N = 'getColumns' then
      Exit(TJVMValue.Int(Get(O, 'cols')));
    if N = 'getRows' then
      Exit(TJVMValue.Int(Get(O, 'rows')));
    if N = 'getCellWidth' then
      Exit(TJVMValue.Int(Get(O, 'tw')));
    if N = 'getCellHeight' then
      Exit(TJVMValue.Int(Get(O, 'th')));
    if (N = 'setCell') or (N = 'getCell') then
    begin
      Col := Arg(1);
      Row := Arg(2);
      Cell(Col, Row);
      ArrayObject := VM.GetObject(Ref(O, 'cells'));
      I := Row * Get(O, 'cols') + Col;
      if N = 'getCell' then
        Exit(ArrayObject.Elements[I]);
      AnyTile(Arg(3));
      ArrayObject.Elements[I] := Args[3];
      Exit;
    end;
    if N = 'fillCells' then
    begin
      Col := Arg(1);
      Row := Arg(2);
      W := Arg(3);
      H := Arg(4);
      if SiemensColor then
        Check((W >= 0) and (H >= 0), 'java/lang/IndexOutOfBoundsException')
      else
        Check((W >= 0) and (H >= 0));
      Check((Col >= 0) and (Row >= 0) and (Int64(Col) + W <= Get(O, 'cols')) and (Int64(Row) + H <= Get(O, 'rows')), 'java/lang/IndexOutOfBoundsException');
      AnyTile(Arg(5));
      ArrayObject := VM.GetObject(Ref(O, 'cells'));
      for J := Row to Row + H - 1 do
        for I := Col to Col + W - 1 do
          ArrayObject.Elements[J * Get(O, 'cols') + I] := Args[5];
      Exit;
    end;
    if N = 'createAnimatedTile' then
    begin
      StaticTile(Arg(1));
      Count := Get(O, 'animatedCount');
      if SiemensColor then
        Check(Count < 32767);
      if Ref(O, 'animated') = 0 then
        ArrayObject := nil
      else
        ArrayObject := VM.GetObject(Ref(O, 'animated'));
      if (ArrayObject = nil) or (Count = Length(ArrayObject.Elements)) then
      begin
        I := 4;
        if ArrayObject <> nil then
          I := Length(ArrayObject.Elements) * 2;
        I := Min(I, VM.MaxArrayLength);
        if SiemensColor then
          I := Min(I, 32767);
        Check(I > Count, 'java/lang/OutOfMemoryError');
        NewRef := VM.NewArray('[I', I);
        NewArray := VM.GetObject(NewRef);
        if ArrayObject <> nil then
          for J := 0 to Count - 1 do
            NewArray.Elements[J] := ArrayObject.Elements[J];
        ArrayObject := NewArray;
        PutRef(O, 'animated', NewRef);
      end;
      ArrayObject.Elements[Count] := Args[1];
      Put(O, 'animatedCount', Count + 1);
      Exit(TJVMValue.Int(-Count - 1));
    end;
    if (N = 'getAnimatedTile') or (N = 'setAnimatedTile') then
    begin
      I := Arg(1);
      Check((I < 0) and (-Int64(I) <= Get(O, 'animatedCount')), 'java/lang/IndexOutOfBoundsException');
      ArrayObject := VM.GetObject(Ref(O, 'animated'));
      if N = 'getAnimatedTile' then
        Exit(ArrayObject.Elements[-I - 1]);
      StaticTile(Arg(2));
      ArrayObject.Elements[-I - 1] := Args[2];
      Exit;
    end;
    if N = 'setStaticTileSet' then
    begin
      FrameSet;
      if SiemensColor then
        Check(Count <= 32767);
      Check((Int64(Get(O, 'cols')) * W <= MaxInt) and (Int64(Get(O, 'rows')) * H <= MaxInt), 'java/lang/OutOfMemoryError');
      if Count < Get(O, 'rawCount') then
      begin
        ArrayObject := VM.GetObject(Ref(O, 'cells'));
        for I := 0 to High(ArrayObject.Elements) do
          ArrayObject.Elements[I] := TJVMValue.Int(0);
        PutRef(O, 'animated', 0);
        Put(O, 'animatedCount', 0);
      end;
      PutRef(O, 'image', Args[1].AsRef);
      Put(O, 'rawCount', Count);
      Put(O, 'tw', W);
      Put(O, 'th', H);
      Put(O, 'w', Get(O, 'cols') * W);
      Put(O, 'h', Get(O, 'rows') * H);
      Put(O, 'maxW', Get(O, 'w'));
      Put(O, 'maxH', Get(O, 'h'));
      Exit;
    end;
    if N = 'paint' then
    begin
      GraphicRef := Args[1].AsRef;
      VM.GetObject(GraphicRef);
      if Get(O, 'visible') = 0 then
        Exit;
      ClipX := GraphicInt('getClipX');
      ClipY := GraphicInt('getClipY');
      ClipW := GraphicInt('getClipWidth');
      ClipH := GraphicInt('getClipHeight');
      if (ClipW = 0) or (ClipH = 0) then
        Exit;
      W := Get(O, 'tw');
      H := Get(O, 'th');
      Image := J2MEImageView(VM, Ref(O, 'image'));
      if (W <= 0) or (H <= 0) or (Image.Width < W) or (Image.Height < H) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Layer image is smaller than a tile');
      X := Max(Int64(0), ClipX - Get(O, 'x'));
      Y := Max(Int64(0), ClipY - Get(O, 'y'));
      X2 := Min(Int64(Get(O, 'w')), ClipX + ClipW - Get(O, 'x'));
      Y2 := Min(Int64(Get(O, 'h')), ClipY + ClipH - Get(O, 'y'));
      if (X >= X2) or (Y >= Y2) then
        Exit;
      BeginLayerClip;
      try
        for Row := Integer(Y div H) to Integer((Y2 - 1) div H) do
          for Col := Integer(X div W) to Integer((X2 - 1) div W) do
          begin
            Tile := TileAt(VM, O, Col, Row);
            if Tile = 0 then
              Continue;
            Dec(Tile);
            Region(Ref(O, 'image'), (Tile mod (Image.Width div W)) * W, (Tile div (Image.Width div W)) * H, W, H, 0, Get(O, 'x') + Col * W, Get(O, 'y') + Row * H);
          end;
      finally
        EndLayerClip;
      end;
      Exit;
    end;
  end;
  if C = ManagerName then
  begin
    if N = '<init>' then
    begin
      W := MaxInt;
      H := MaxInt;
      if SiemensColor then
      begin
        W := Width;
        H := Height;
      end;
      Put(O, 'vw', W);
      Put(O, 'vh', H);
      PutRef(O, 'layers', VM.NewArray('[' + LayerD, 0));
      Exit;
    end;
    if N = 'setViewWindow' then
    begin
      Check((Arg(3) >= 0) and (Arg(4) >= 0));
      Put(O, 'vx', Arg(1));
      Put(O, 'vy', Arg(2));
      Put(O, 'vw', Arg(3));
      Put(O, 'vh', Arg(4));
      Exit;
    end;
    ArrayObject := VM.GetObject(Ref(O, 'layers'));
    Count := Length(ArrayObject.Elements);
    if N = 'getSize' then
      Exit(TJVMValue.Int(Count));
    if N = 'getLayerAt' then
    begin
      Check((Arg(1) >= 0) and (Arg(1) < Count), 'java/lang/IndexOutOfBoundsException');
      Exit(ArrayObject.Elements[Arg(1)]);
    end;
    if (N = 'append') or (N = 'insert') or (N = 'remove') or (N = 'removeLayer') then
    begin
      V := Args[1];
      if N = 'removeLayer' then
      begin
        V := Args[2];
        N := 'remove';
      end;
      VM.GetObject(V.AsRef);
      Index := Count;
      if N = 'insert' then
      begin
        Index := Arg(2);
        Check((Index >= 0) and (Index <= Count), 'java/lang/IndexOutOfBoundsException');
      end;
      K := -1;
      for I := 0 to Count - 1 do
        if ArrayObject.Elements[I].AsRef = V.AsRef then
        begin
          K := I;
          Break;
        end;
      if (N = 'remove') and (K < 0) then
        Exit;
      J := Count + Ord(N <> 'remove') - Ord(K >= 0);
      NewRef := VM.NewArray('[' + LayerD, J);
      NewArray := VM.GetObject(NewRef);
      if (K >= 0) and (Index = Count) then
        Dec(Index);
      J := 0;
      for I := 0 to Count - 1 do
        if I <> K then
        begin
          if (N <> 'remove') and (J = Index) then
            Inc(J);
          NewArray.Elements[J] := ArrayObject.Elements[I];
          Inc(J);
        end;
      if N <> 'remove' then
        NewArray.Elements[Index] := V;
      PutRef(O, 'layers', NewRef);
      Exit;
    end;
    if N = '$beginPaint' then
    begin
      GraphicRef := Args[1].AsRef;
      Other := VM.GetObject(GraphicRef);
      NewRef := VM.NewArray('[Ljava/lang/Object;', Count + 1);
      Snapshot := VM.GetObject(NewRef);
      G := VM.NewArray('[I', 7);
      State := VM.GetObject(G);
      I := 0;
      for var Key in TArray<string>.Create('$tx', '$ty', '$clipL', '$clipT', '$clipR', '$clipB') do
      begin
        if Other.Fields.TryGetValue(Key, V) then
        begin
          State.Elements[I] := V;
          State.Elements[6] := TJVMValue.Int(State.Elements[6].AsInt or (1 shl I));
        end;
        Inc(I);
      end;
      Snapshot.Elements[0] := TJVMValue.Ref(G);
      for I := 0 to Count - 1 do
        Snapshot.Elements[I + 1] := ArrayObject.Elements[I];
      Graphic('clipRect', '(IIII)V', [Args[1], Args[2], Args[3], TJVMValue.Int(Get(O, 'vw')), TJVMValue.Int(Get(O, 'vh'))]);
      Graphic('translate', '(II)V', [Args[1], TJVMValue.Int(Arg(2) - Get(O, 'vx')), TJVMValue.Int(Arg(3) - Get(O, 'vy'))]);
      Exit(TJVMValue.Ref(NewRef));
    end;
    if N = '$endPaint' then
    begin
      Other := VM.GetObject(Args[1].AsRef);
      Snapshot := VM.GetObject(Args[2].AsRef);
      State := VM.GetObject(Snapshot.Elements[0].AsRef);
      I := 0;
      for var Key in TArray<string>.Create('$tx', '$ty', '$clipL', '$clipT', '$clipR', '$clipB') do
      begin
        if (State.Elements[6].AsInt and (1 shl I)) = 0 then
          Other.Fields.Remove(Key)
        else
          Other.Fields.AddOrSetValue(Key, State.Elements[I]);
        Inc(I);
      end;
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create('Game native not implemented: ' + C + '.' + N + D);
end;

end.

