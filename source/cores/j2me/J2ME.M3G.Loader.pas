unit J2ME.M3G.Loader;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Suite;

procedure InstallM3GLoader(VM: TJVM);

function InvokeM3GLoader(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.Hash,
  System.Generics.Collections, J2ME.Compatibility, Java.Classes, Java.Hashtable,
  J2ME.Resources, J2ME.M3G, J2ME.M3G.Math, J2ME.M3G.Geometry, J2ME.M3G.Format,
  J2ME.M3G.Texture, J2ME.M3G.Keyframe, Media.Image.PNG;

{$Q-}{$R-}

const
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';
  ObjectArray = '[Ljavax/microedition/m3g/Object3D;';
  MaxLoadBytes = 64 * 1024 * 1024;

type
  TM3GLoad = class
  private
    VM: TJVM;
    Suite: TJ2MESuite;
    Roots: TList<Integer>;
    Loading: TDictionary<string, Boolean>;
    Cache: TDictionary<string, TArray<Integer>>;
    StoredBytes, DecodedBytes, ObjectCount: Int64;
    function Keep(Ref: Integer): Integer;
    function NewObject(const Name: string): Integer;
    function NewArray(const Name: string; Count: Integer): Integer;
    function ByteArray(const Data: TBytes): Integer;
    procedure Call(Ref: Integer; const Owner, Name, Descriptor: string; const Values: array of TJVMValue);
    function Decode(const Data: TBytes; Offset: Integer; const Location: string; Depth: Integer): TArray<Integer>;
    function Resource(const Name, Parent: string; Depth: Integer): TArray<Integer>;
    function PNG(const Data: TBytes; Offset: Integer; AllowTrailing: Boolean): Integer;
  public
    constructor Create(AVM: TJVM; ASuite: TJ2MESuite);
    destructor Destroy; override;
    function Load(Method: TJVMMethod; const Args: TArray<TJVMValue>): Integer;
  end;

  TM3GObjectReader = class
  private
    Load: TM3GLoad;
    Reader: TM3GDataReader;
    Refs: TArray<Integer>;
    Used: TArray<Boolean>;
    Current, ObjectRef: Integer;
    AllowUnusedTexBias: Boolean;
    RepairOrphanCamera: Boolean;
    function Ref(const Expected: string; Nullable: Boolean = True; Direct: Boolean = True): Integer;
    function RGB(Alpha: Boolean): Integer;
    function Floats(Count: Integer): TArray<TJVMValue>;
    procedure Call(const Owner, Name, Descriptor: string; const Values: array of TJVMValue);
    procedure Common;
    procedure Transformable;
    procedure Node;
    procedure Group;
    procedure VertexArray;
    procedure VertexBuffer;
    procedure Strips;
    procedure Image;
    procedure ObjectData(Kind: Byte);
  public
    constructor Create(ALoad: TM3GLoad; Count: Integer);
    function Decode(const Document: TM3GDocument; const Location: string; Depth: Integer): TArray<Integer>;
  end;

procedure Bad(const Why: string);
begin
  raise EM3GFormat.Create(Why);
end;

procedure InstallM3GLoader(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Base + 'Loader', 'java/lang/Object');
  try
    B.JavaClass.AddNative('load', '(Ljava/lang/String;)' + ObjectArray, True);
    B.JavaClass.AddNative('load', '([BI)' + ObjectArray, True);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

constructor TM3GLoad.Create(AVM: TJVM; ASuite: TJ2MESuite);
begin
  inherited Create;
  VM := AVM;
  Suite := ASuite;
  Roots := TList<Integer>.Create;
  Loading := TDictionary<string, Boolean>.Create;
  Cache := TDictionary<string, TArray<Integer>>.Create;
end;

destructor TM3GLoad.Destroy;
begin
  for var Ref in Roots do
    VM.RemoveRoot(Ref);
  Roots.Free;
  Loading.Free;
  Cache.Free;
  inherited;
end;

function TM3GLoad.Keep(Ref: Integer): Integer;
begin
  VM.AddRoot(Ref);
  Roots.Add(Ref);
  Result := Ref;
end;

function TM3GLoad.NewObject(const Name: string): Integer;
begin
  Inc(ObjectCount);
  if ObjectCount > 100000 then
    Bad('M3G object limit');
  Result := Keep(VM.NewObject(Base + Name));
end;

function TM3GLoad.NewArray(const Name: string; Count: Integer): Integer;
begin
  Result := Keep(VM.NewArray(Name, Count));
end;

function TM3GLoad.ByteArray(const Data: TBytes): Integer;
begin
  Result := NewArray('[B', Length(Data));
  var A := VM.GetObject(Result);
  for var K := 0 to High(Data) do
    A.Elements[K] := TJVMValue.Int(ShortInt(Data[K]));
end;

procedure TM3GLoad.Call(Ref: Integer; const Owner, Name, Descriptor: string; const Values: array of TJVMValue);
begin
  var Args: TArray<TJVMValue>;
  SetLength(Args, Length(Values) + 1);
  Args[0] := TJVMValue.Ref(Ref);
  for var K := 0 to High(Values) do
    Args[K + 1] := Values[K];
  var Method := VM.LoadClass(Base + Owner).FindMethod(Name, Descriptor);
  if Method = nil then
    raise EJVMError.Create('M3G loader binding ' + Owner + '.' + Name + Descriptor);
  InvokeJ2MEM3G(VM, Method, Args);
end;

function TM3GLoad.Resource(const Name, Parent: string; Depth: Integer): TArray<Integer>;
begin
  if Depth > 64 then
    Bad('M3G resource nesting limit');
  if VM.StopRequested then
    Bad('M3G loading cancelled');
  var Path := Name;
  if Path.StartsWith('resource:') then
    Path := Copy(Path, 10, MaxInt)
  else if Path.Contains(':') then
    Bad('M3G Loader protocol is not implemented: ' + Copy(Path, 1, Pos(':', Path) - 1))
  else if Parent = '' then
    Bad('Relative M3G reference without a resource location');
  if not Path.StartsWith('/') then
    Path := Copy(Parent, 1, LastDelimiter('/', Parent)) + Path;
  var Key: string;
  if not J2MECanonicalResourceName(Path, Key) or Key.EndsWith('.class') then
    Bad('Invalid M3G resource name');
  Path := '/' + Key;
  if Loading.ContainsKey(Path) then
    Bad('Cyclic M3G resource reference: ' + Path);
  if Cache.TryGetValue(Path, Result) then
    Exit;
  if not Suite.HasResource(Key) then
    Bad('M3G resource not found: ' + Path);
  Loading.Add(Path, True);
  try
    var Data := Suite.ReadResource(Key);
    Result := Decode(Data, 0, Path, Depth);
    Cache.Add(Path, Result);
  finally
    Loading.Remove(Path);
  end;
end;

function TM3GLoad.PNG(const Data: TBytes; Offset: Integer; AllowTrailing: Boolean): Integer;
begin
  var Bytes := Copy(Data, Offset, Length(Data) - Offset);
  // A byte[] may contain several packed assets after the selected offset.
  // IEND, like the M3G header file size, identifies this asset's boundary.
  // Named PNG resources retain exact-file validation except reviewed hashes.
  if AllowTrailing then
  begin
    var At := 8;
    while At <= Length(Bytes) - 12 do
    begin
      var Size := (UInt32(Bytes[At]) shl 24) or (UInt32(Bytes[At + 1]) shl 16) or (UInt32(Bytes[At + 2]) shl 8) or Bytes[At + 3];
      if Size > UInt32(Length(Bytes) - At - 12) then
        Bad('Truncated M3G PNG chunk');
      if (Bytes[At + 4] = Ord('I')) and (Bytes[At + 5] = Ord('E')) and (Bytes[At + 6] = Ord('N')) and (Bytes[At + 7] = Ord('D')) then
      begin
        SetLength(Bytes, At + Integer(Size) + 12);
        Break;
      end;
      Inc(At, Integer(Size) + 12);
    end;
  end;
  var Image := DecodePNG(Bytes, VM.MaxArrayLength);
  Inc(DecodedBytes, Int64(Image.Width) * Image.Height * 4);
  if DecodedBytes > MaxLoadBytes then
    Bad('M3G decoded resource limit');
  var Format := 99;
  var ColorType := Bytes[25];
  var Transparent := False;
  var At := 8;
  while At <= Length(Bytes) - 12 do
  begin
    var Size := (UInt32(Bytes[At]) shl 24) or (UInt32(Bytes[At + 1]) shl 16) or (UInt32(Bytes[At + 2]) shl 8) or Bytes[At + 3];
    if Size > UInt32(Length(Bytes) - At - 12) then
      Bad('Truncated M3G PNG chunk');
    if (Bytes[At + 4] = Ord('t')) and (Bytes[At + 5] = Ord('R')) and (Bytes[At + 6] = Ord('N')) and (Bytes[At + 7] = Ord('S')) then
      Transparent := True;
    Inc(At, Integer(Size) + 12);
  end;
  case ColorType of
    0:
      if Transparent then
        Format := 98
      else
        Format := 97;
    2, 3:
      if Transparent then
        Format := 100;
    4:
      Format := 98;
    6:
      Format := 100;
  end;
  Result := Keep(M3GNewRasterImage(VM, Format, Image.Width, Image.Height, Image.Pixels));
end;

function TM3GLoad.Decode(const Data: TBytes; Offset: Integer; const Location: string; Depth: Integer): TArray<Integer>;
begin
  Inc(StoredBytes, Length(Data) - Offset);
  if StoredBytes > MaxLoadBytes then
    Bad('M3G resource byte limit');
  if (Length(Data) - Offset >= 8) and (Data[Offset] = $89) and (Data[Offset + 1] = $50) and (Data[Offset + 2] = $4E) and (Data[Offset + 3] = $47) then
  begin
    var AllowTrailing := Location = '';
    if not AllowTrailing then
    begin
      var PNGHash := THashSHA2.Create;
      PNGHash.Update(Data[Offset], Length(Data) - Offset);
      AllowTrailing := J2MECompatibilityPNGTrailingData(PNGHash.HashAsString);
    end;
    SetLength(Result, 1);
    Result[0] := PNG(Data, Offset, AllowTrailing);
    Exit;
  end;
  var Document := ReadM3GDocument(Data, Offset, MaxLoadBytes - Integer(DecodedBytes));
  Inc(DecodedBytes, Document.DecodedBytes);
  var Objects := TM3GObjectReader.Create(Self, Length(Document.Objects));
  try
    var Hash := THashSHA2.Create;
    Hash.Update(Data[Offset], Document.FileSize);
    Objects.AllowUnusedTexBias := J2MECompatibilityM3GUnusedTexBias(Hash.HashAsString);
    Objects.RepairOrphanCamera := J2MECompatibilityM3GOrphanCamera(Hash.HashAsString);
    Result := Objects.Decode(Document, Location, Depth);
  finally
    Objects.Free;
  end;
end;

function TM3GLoad.Load(Method: TJVMMethod; const Args: TArray<TJVMValue>): Integer;
begin
  var Objects: TArray<Integer>;
  if Method.Descriptor.StartsWith('(Ljava/lang/String;') then
  begin
    Objects := Resource(VM.GetObject(Args[0].AsRef).Text, '/', 0);
  end
  else
  begin
    var Input := VM.GetObject(Args[0].AsRef);
    var Offset := Args[1].AsInt;
    if (Offset < 0) or (Offset >= Length(Input.Elements)) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G load offset');
    var Data: TBytes;
    SetLength(Data, Length(Input.Elements) - Offset);
    for var K := 0 to High(Data) do
      Data[K] := Byte(Input.Elements[K + Offset].AsInt);
    Objects := Decode(Data, 0, '', 0);
  end;
  Result := NewArray(ObjectArray, Length(Objects));
  var Output := VM.GetObject(Result);
  for var K := 0 to High(Objects) do
    Output.Elements[K] := TJVMValue.Ref(Objects[K]);
end;

constructor TM3GObjectReader.Create(ALoad: TM3GLoad; Count: Integer);
begin
  inherited Create;
  Load := ALoad;
  SetLength(Refs, Count + 1);
  SetLength(Used, Count + 1);
end;

function TM3GObjectReader.Ref(const Expected: string; Nullable, Direct: Boolean): Integer;
begin
  var Index := Reader.U32;
  if Index = 0 then
  begin
    if not Nullable then
      Bad('Null M3G ' + Expected + ' reference');
    Exit(0);
  end;
  if Index > UInt32(Current) then
    Bad('Forward M3G reference');
  Result := Refs[Index];
  if (Result = 0) or not Load.VM.IsAssignable(Load.VM.GetObject(Result).ClassName, Base + Expected) then
    Bad('Wrong M3G ' + Expected + ' reference type');
  if Direct then
    Used[Index] := True;
end;

function TM3GObjectReader.RGB(Alpha: Boolean): Integer;
begin
  var Red := UInt32(Reader.U8);
  var Green := UInt32(Reader.U8);
  var Blue := UInt32(Reader.U8);
  var A: UInt32 := 0;
  if Alpha then
    A := Reader.U8;
  Result := Integer((A shl 24) or (Red shl 16) or (Green shl 8) or Blue);
end;

function TM3GObjectReader.Floats(Count: Integer): TArray<TJVMValue>;
begin
  SetLength(Result, Count);
  for var K := 0 to Count - 1 do
    Result[K] := TJVMValue.Float(Reader.Float32);
end;

procedure TM3GObjectReader.Call(const Owner, Name, Descriptor: string; const Values: array of TJVMValue);
begin
  Load.Call(ObjectRef, Owner, Name, Descriptor, Values);
end;

procedure TM3GObjectReader.Common;
begin
  var O := Load.VM.GetObject(ObjectRef);
  O.Fields.AddOrSetValue(P + 'id', TJVMValue.Int(Reader.I32));
  var Tracks := Reader.Count(4);
  for var K := 0 to Tracks - 1 do
    Call('Object3D', 'addAnimationTrack', '(Ljavax/microedition/m3g/AnimationTrack;)V', [TJVMValue.Ref(Ref('AnimationTrack', False))]);
  var Count := Reader.Count(8);
  var Keys, Values: TArray<Integer>;
  SetLength(Keys, Count);
  SetLength(Values, Count);
  var Seen := TDictionary<Integer, Boolean>.Create;
  try
    for var K := 0 to Count - 1 do
    begin
      Keys[K] := Reader.I32;
      if Seen.ContainsKey(Keys[K]) then
        Bad('Duplicate M3G user parameter');
      Seen.Add(Keys[K], True);
      Values[K] := Load.ByteArray(Reader.Bytes(Reader.Count));
    end;
  finally
    Seen.Free;
  end;
  if Count <> 0 then
    O.Fields.AddOrSetValue(P + 'user', TJVMValue.Ref(Load.Keep(JavaNewIntegerKeyTable(Load.VM, Keys, Values))));
end;

procedure TM3GObjectReader.Transformable;
begin
  if Reader.Bool then
  begin
    Call('Transformable', 'setTranslation', '(FFF)V', Floats(3));
    Call('Transformable', 'setScale', '(FFF)V', Floats(3));
    Call('Transformable', 'setOrientation', '(FFFF)V', Floats(4));
  end;
  if Reader.Bool then
  begin
    var M: TM3GMatrix;
    for var K := 0 to 15 do
      M[K] := Reader.Float32;
    var T := Load.NewObject('Transform');
    M3GPutMatrix(Load.VM, T, M);
    Call('Transformable', 'setTransform', '(Ljavax/microedition/m3g/Transform;)V', [TJVMValue.Ref(T)]);
  end;
end;

procedure TM3GObjectReader.Node;
begin
  Transformable;
  Call('Node', 'setRenderingEnable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
  Call('Node', 'setPickingEnable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
  Call('Node', 'setAlphaFactor', '(F)V', [TJVMValue.Float(Reader.U8 / 255)]);
  Call('Node', 'setScope', '(I)V', [TJVMValue.Int(Reader.I32)]);
  if Reader.Bool then
  begin
    var Z := Reader.U8;
    var Y := Reader.U8;
    var ZRef := Ref('Node', True, False);
    var YRef := Ref('Node', True, False);
    Call('Node', 'setAlignment', '(Ljavax/microedition/m3g/Node;ILjavax/microedition/m3g/Node;I)V',
      [TJVMValue.Ref(ZRef), TJVMValue.Int(Z), TJVMValue.Ref(YRef), TJVMValue.Int(Y)]);
  end;
end;

procedure TM3GObjectReader.Group;
begin
  var Count := Reader.Count(4);
  for var K := 0 to Count - 1 do
    Call('Group', 'addChild', '(Ljavax/microedition/m3g/Node;)V', [TJVMValue.Ref(Ref('Node', False))]);
end;

procedure TM3GObjectReader.VertexArray;
begin
  var Size := Reader.U8;
  var Components := Reader.U8;
  var Encoding := Reader.U8;
  var Count := Reader.U16;
  if Encoding > 1 then
    Bad('Invalid M3G vertex encoding');
  Call('VertexArray', '<init>', '(III)V', [TJVMValue.Int(Count), TJVMValue.Int(Components), TJVMValue.Int(Size)]);
  var O := Load.VM.GetObject(ObjectRef);
  var Data := Load.VM.GetObject(O.Fields[P + 'data'].AsRef);
  var Acc: array[0..3] of Integer;
  FillChar(Acc, SizeOf(Acc), 0);
  for var V := 0 to Count - 1 do
  begin
    if Load.VM.StopRequested then
      Bad('M3G loading cancelled');
    for var C := 0 to Components - 1 do
    begin
      var Value: Integer;
      if Size = 1 then
        Value := Reader.U8
      else
        Value := Reader.I16;
      if Encoding = 1 then
        Inc(Value, Acc[C]);
      if Size = 1 then
        Value := ShortInt(Byte(Value))
      else
        Value := SmallInt(Word(Value));
      Acc[C] := Value;
      Data.Elements[V * Components + C] := TJVMValue.Int(Value);
    end;
  end;
end;

procedure TM3GObjectReader.VertexBuffer;

  procedure Attribute(const Name: string; Index: Integer);
  begin
    var A := Ref('VertexArray');
    var Bias := Load.NewArray('[F', 3);
    var B := Load.VM.GetObject(Bias);
    for var K := 0 to 2 do
      B.Elements[K] := TJVMValue.Float(Reader.Float32);
    var Scale := TJVMValue.Float(Reader.Float32);
    if (Index >= 0) and (A <> 0) and (Load.VM.GetObject(A).Fields[P + 'components'].AsInt = 2) and (B.Elements[2].AsFloat <> 0) then
    begin
      if not AllowUnusedTexBias then
        Bad('M3G two-component texture bias Z');
      // Only this reviewed, unused component is normalized. All other format
      // validation and three-component texture coordinates remain unchanged.
      B.Elements[2] := TJVMValue.Float(0);
    end;
    if Index < 0 then
      Call('VertexBuffer', Name, '(Ljavax/microedition/m3g/VertexArray;F[F)V', [TJVMValue.Ref(A), Scale, TJVMValue.Ref(Bias)])
    else
      Call('VertexBuffer', Name, '(ILjavax/microedition/m3g/VertexArray;F[F)V', [TJVMValue.Int(Index), TJVMValue.Ref(A), Scale, TJVMValue.Ref(Bias)]);
  end;

begin
  Call('VertexBuffer', 'setDefaultColor', '(I)V', [TJVMValue.Int(RGB(True))]);
  Attribute('setPositions', -1);
  Call('VertexBuffer', 'setNormals', '(Ljavax/microedition/m3g/VertexArray;)V', [TJVMValue.Ref(Ref('VertexArray'))]);
  Call('VertexBuffer', 'setColors', '(Ljavax/microedition/m3g/VertexArray;)V', [TJVMValue.Ref(Ref('VertexArray'))]);
  var Count := Reader.Count(20, M3GTextureUnits);
  for var K := 0 to Count - 1 do
    Attribute('setTexCoords', K);
end;

procedure TM3GObjectReader.Strips;
begin
  var Encoding := Reader.U8;
  var Start := 0;
  var Indices := 0;
  if (Encoding = 0) or (Encoding = 1) or (Encoding = 2) then
    case Encoding of
      0:
        Start := Reader.I32;
      1:
        Start := Reader.U8;
      2:
        Start := Reader.U16;
    end
  else if (Encoding = 128) or (Encoding = 129) or (Encoding = 130) then
  begin
    var Size := 4;
    if Encoding = 129 then
      Size := 1
    else if Encoding = 130 then
      Size := 2;
    var Count := Reader.Count(Size);
    Indices := Load.NewArray('[I', Count);
    var A := Load.VM.GetObject(Indices);
    for var K := 0 to Count - 1 do
    begin
      var Value: Integer;
      case Encoding of
        128:
          Value := Reader.I32;
        129:
          Value := Reader.U8;
      else
        Value := Reader.U16;
      end;
      A.Elements[K] := TJVMValue.Int(Value);
    end;
  end
  else
    Bad('Invalid M3G strip encoding');
  var Count := Reader.Count(4);
  var Lengths := Load.NewArray('[I', Count);
  var A := Load.VM.GetObject(Lengths);
  for var K := 0 to Count - 1 do
    A.Elements[K] := TJVMValue.Int(Reader.I32);
  if Encoding < 128 then
    Call('TriangleStripArray', '<init>', '(I[I)V', [TJVMValue.Int(Start), TJVMValue.Ref(Lengths)])
  else
    Call('TriangleStripArray', '<init>', '([I[I)V', [TJVMValue.Ref(Indices), TJVMValue.Ref(Lengths)]);
end;

procedure TM3GObjectReader.Image;
begin
  var Format := Reader.U8;
  var Mutable := Reader.Bool;
  var W := Reader.I32;
  var H := Reader.I32;
  if Mutable then
    Call('Image2D', '<init>', '(III)V', [TJVMValue.Int(Format), TJVMValue.Int(W), TJVMValue.Int(H)])
  else
  begin
    var Palette := Reader.Bytes(Reader.Count);
    var Pixels := Reader.Bytes(Reader.Count);
    var Data := Load.ByteArray(Pixels);
    if Length(Palette) = 0 then
      Call('Image2D', '<init>', '(III[B)V', [TJVMValue.Int(Format), TJVMValue.Int(W), TJVMValue.Int(H), TJVMValue.Ref(Data)])
    else
      Call('Image2D', '<init>', '(III[B[B)V', [TJVMValue.Int(Format), TJVMValue.Int(W), TJVMValue.Int(H), TJVMValue.Ref(Data), TJVMValue.Ref(Load.ByteArray(Palette))]);
  end;
end;

procedure TM3GObjectReader.ObjectData(Kind: Byte);
begin
  Common;
  if Kind in [5, 9, 12, 14, 15, 16, 18, 22] then
    Node
  else if Kind = 17 then
    Transformable;
  case Kind of
    1:
      begin
        Call('AnimationController', '<init>', '()V', []);
        var Speed := Reader.Float32;
        var Weight := Reader.Float32;
        var Start := Reader.I32;
        var Finish := Reader.I32;
        var Position := Reader.Float32;
        var WorldTime := Reader.I32;
        Call('AnimationController', 'setSpeed', '(FI)V', [TJVMValue.Float(Speed), TJVMValue.Int(WorldTime)]);
        Call('AnimationController', 'setPosition', '(FI)V', [TJVMValue.Float(Position), TJVMValue.Int(WorldTime)]);
        Call('AnimationController', 'setWeight', '(F)V', [TJVMValue.Float(Weight)]);
        Call('AnimationController', 'setActiveInterval', '(II)V', [TJVMValue.Int(Start), TJVMValue.Int(Finish)]);
      end;
    2:
      begin
        var Sequence := Ref('KeyframeSequence', False);
        var Controller := Ref('AnimationController');
        var PropertyID := Reader.I32;
        Call('AnimationTrack', '<init>', '(Ljavax/microedition/m3g/KeyframeSequence;I)V', [TJVMValue.Ref(Sequence), TJVMValue.Int(PropertyID)]);
        Call('AnimationTrack', 'setController', '(Ljavax/microedition/m3g/AnimationController;)V', [TJVMValue.Ref(Controller)]);
      end;
    3:
      begin
        Call('Appearance', 'setLayer', '(I)V', [TJVMValue.Int(ShortInt(Reader.U8))]);
        for var Name in ['CompositingMode', 'Fog', 'PolygonMode', 'Material'] do
          Call('Appearance', 'set' + Name, '(Ljavax/microedition/m3g/' + Name + ';)V', [TJVMValue.Ref(Ref(Name))]);
        var Count := Reader.Count(4, M3GTextureUnits);
        for var K := 0 to Count - 1 do
          Call('Appearance', 'setTexture', '(ILjavax/microedition/m3g/Texture2D;)V', [TJVMValue.Int(K), TJVMValue.Ref(Ref('Texture2D'))]);
      end;
    4:
      begin
        Call('Background', 'setColor', '(I)V', [TJVMValue.Int(RGB(True))]);
        Call('Background', 'setImage', '(Ljavax/microedition/m3g/Image2D;)V', [TJVMValue.Ref(Ref('Image2D'))]);
        var X := Reader.U8;
        var Y := Reader.U8;
        Call('Background', 'setImageMode', '(II)V', [TJVMValue.Int(X), TJVMValue.Int(Y)]);
        var CropX := Reader.I32;
        var CropY := Reader.I32;
        var W := Reader.I32;
        var H := Reader.I32;
        Call('Background', 'setCrop', '(IIII)V', [TJVMValue.Int(CropX), TJVMValue.Int(CropY), TJVMValue.Int(W), TJVMValue.Int(H)]);
        Call('Background', 'setDepthClearEnable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
        Call('Background', 'setColorClearEnable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
      end;
    5:
      begin
        var Mode := Reader.U8;
        if Mode = 48 then
        begin
          var M: TM3GMatrix;
          for var K := 0 to 15 do
            M[K] := Reader.Float32;
          var T := Load.NewObject('Transform');
          M3GPutMatrix(Load.VM, T, M);
          Call('Camera', 'setGeneric', '(Ljavax/microedition/m3g/Transform;)V', [TJVMValue.Ref(T)]);
        end
        else if Mode = 49 then
          Call('Camera', 'setParallel', '(FFFF)V', Floats(4))
        else if Mode = 50 then
          Call('Camera', 'setPerspective', '(FFFF)V', Floats(4))
        else
          Bad('Invalid M3G camera projection');
      end;
    6:
      begin
        for var Name in ['DepthTest', 'DepthWrite', 'ColorWrite', 'AlphaWrite'] do
          Call('CompositingMode', 'set' + Name + 'Enable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
        Call('CompositingMode', 'setBlending', '(I)V', [TJVMValue.Int(Reader.U8)]);
        Call('CompositingMode', 'setAlphaThreshold', '(F)V', [TJVMValue.Float(Reader.U8 / 255)]);
        Call('CompositingMode', 'setDepthOffset', '(FF)V', Floats(2));
      end;
    7:
      begin
        Call('Fog', 'setColor', '(I)V', [TJVMValue.Int(RGB(False))]);
        var Mode := Reader.U8;
        Call('Fog', 'setMode', '(I)V', [TJVMValue.Int(Mode)]);
        if Mode = 80 then
          Call('Fog', 'setDensity', '(F)V', Floats(1))
        else
          Call('Fog', 'setLinear', '(FF)V', Floats(2));
      end;
    8:
      begin
        for var Name in ['Culling', 'Shading', 'Winding'] do
          Call('PolygonMode', 'set' + Name, '(I)V', [TJVMValue.Int(Reader.U8)]);
        for var Name in ['TwoSidedLighting', 'LocalCameraLighting', 'PerspectiveCorrection'] do
          Call('PolygonMode', 'set' + Name + 'Enable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
      end;
    9:
      Group;
    10:
      Image;
    11:
      Strips;
    12:
      begin
        Call('Light', 'setAttenuation', '(FFF)V', Floats(3));
        Call('Light', 'setColor', '(I)V', [TJVMValue.Int(RGB(False))]);
        Call('Light', 'setMode', '(I)V', [TJVMValue.Int(Reader.U8)]);
        for var Name in ['Intensity', 'SpotAngle', 'SpotExponent'] do
          Call('Light', 'set' + Name, '(F)V', Floats(1));
      end;
    13:
      begin
        var Target := 1024;
        for var K := 0 to 3 do
        begin
          Call('Material', 'setColor', '(II)V', [TJVMValue.Int(Target), TJVMValue.Int(RGB(K = 1))]);
          Target := Target shl 1;
        end;
        Call('Material', 'setShininess', '(F)V', Floats(1));
        Call('Material', 'setVertexColorTrackingEnable', '(Z)V', [TJVMValue.Int(Ord(Reader.Bool))]);
      end;
    14..16:
      begin
        var Vertices := Ref('VertexBuffer', False);
        var Count := Reader.Count(8);
        var Indices := Load.NewArray('[Ljavax/microedition/m3g/IndexBuffer;', Count);
        var Appearances := Load.NewArray('[Ljavax/microedition/m3g/Appearance;', Count);
        for var K := 0 to Count - 1 do
        begin
          Load.VM.GetObject(Indices).Elements[K] := TJVMValue.Ref(Ref('IndexBuffer', False));
          Load.VM.GetObject(Appearances).Elements[K] := TJVMValue.Ref(Ref('Appearance'));
        end;
        if Kind = 14 then
          Call('Mesh', '<init>', '(Ljavax/microedition/m3g/VertexBuffer;[Ljavax/microedition/m3g/IndexBuffer;[Ljavax/microedition/m3g/Appearance;)V',
            [TJVMValue.Ref(Vertices), TJVMValue.Ref(Indices), TJVMValue.Ref(Appearances)])
        else if Kind = 16 then
        begin
          var Skeleton := Ref('Group', False);
          Call('SkinnedMesh', '<init>', '(Ljavax/microedition/m3g/VertexBuffer;[Ljavax/microedition/m3g/IndexBuffer;[Ljavax/microedition/m3g/Appearance;Ljavax/microedition/m3g/Group;)V',
            [TJVMValue.Ref(Vertices), TJVMValue.Ref(Indices), TJVMValue.Ref(Appearances), TJVMValue.Ref(Skeleton)]);
          var BoneCount := Reader.Count(16);
          for var K := 0 to BoneCount - 1 do
          begin
            var Bone := Ref('Node', False);
            var First := Reader.I32;
            var BoneVertices := Reader.I32;
            var Weight := Reader.I32;
            Call('SkinnedMesh', 'addTransform', '(Ljavax/microedition/m3g/Node;III)V', [TJVMValue.Ref(Bone), TJVMValue.Int(Weight), TJVMValue.Int(First), TJVMValue.Int(BoneVertices)]);
          end;
        end
        else
        begin
          var TargetCount := Reader.Count(8, Load.VM.MaxArrayLength);
          var Targets := Load.NewArray('[Ljavax/microedition/m3g/VertexBuffer;', TargetCount);
          var Weights := Load.NewArray('[F', TargetCount);
          for var K := 0 to TargetCount - 1 do
          begin
            Load.VM.GetObject(Targets).Elements[K] := TJVMValue.Ref(Ref('VertexBuffer', False));
            Load.VM.GetObject(Weights).Elements[K] := TJVMValue.Float(Reader.Float32);
          end;
          Call('MorphingMesh', '<init>', '(Ljavax/microedition/m3g/VertexBuffer;[Ljavax/microedition/m3g/VertexBuffer;[Ljavax/microedition/m3g/IndexBuffer;[Ljavax/microedition/m3g/Appearance;)V',
            [TJVMValue.Ref(Vertices), TJVMValue.Ref(Targets), TJVMValue.Ref(Indices), TJVMValue.Ref(Appearances)]);
          Call('MorphingMesh', 'setWeights', '([F)V', [TJVMValue.Ref(Weights)]);
        end;
      end;
    17:
      begin
        Call('Texture2D', '<init>', '(Ljavax/microedition/m3g/Image2D;)V', [TJVMValue.Ref(Ref('Image2D', False))]);
        Call('Texture2D', 'setBlendColor', '(I)V', [TJVMValue.Int(RGB(False))]);
        Call('Texture2D', 'setBlending', '(I)V', [TJVMValue.Int(Reader.U8)]);
        var S := Reader.U8;
        var T := Reader.U8;
        Call('Texture2D', 'setWrapping', '(II)V', [TJVMValue.Int(S), TJVMValue.Int(T)]);
        var Level := Reader.U8;
        var Image := Reader.U8;
        Call('Texture2D', 'setFiltering', '(II)V', [TJVMValue.Int(Level), TJVMValue.Int(Image)]);
      end;
    18:
      begin
        var Image := Ref('Image2D', False);
        var Appearance := Ref('Appearance');
        var Scaled := Ord(Reader.Bool);
        Call('Sprite3D', '<init>', '(ZLjavax/microedition/m3g/Image2D;Ljavax/microedition/m3g/Appearance;)V', [TJVMValue.Int(Scaled), TJVMValue.Ref(Image), TJVMValue.Ref(Appearance)]);
        var X := Reader.I32;
        var Y := Reader.I32;
        var W := Reader.I32;
        var H := Reader.I32;
        Call('Sprite3D', 'setCrop', '(IIII)V', [TJVMValue.Int(X), TJVMValue.Int(Y), TJVMValue.Int(W), TJVMValue.Int(H)]);
      end;
    19:
      begin
        var Mode := Reader.U8;
        var RepeatMode := Reader.U8;
        var Encoding := Reader.U8;
        if Encoding > 2 then
          Bad('M3G keyframe encoding');
        var Duration := Reader.I32;
        var First := Reader.I32;
        var Last := Reader.I32;
        var Components := Reader.Count(1, Load.VM.MaxArrayLength);
        var Count := Reader.Count(4, Load.VM.MaxArrayLength);
        var Bytes := Int64(Count) * Components * 8 + Int64(Count) * 4;
        if Bytes > MaxLoadBytes - Load.DecodedBytes then
          Bad('M3G decoded keyframe limit');
        Inc(Load.DecodedBytes, Bytes);
        Call('KeyframeSequence', '<init>', '(III)V', [TJVMValue.Int(Count), TJVMValue.Int(Components), TJVMValue.Int(Mode)]);
        Call('KeyframeSequence', 'setRepeatMode', '(I)V', [TJVMValue.Int(RepeatMode)]);
        Call('KeyframeSequence', 'setDuration', '(I)V', [TJVMValue.Int(Duration)]);
        Call('KeyframeSequence', 'setValidRange', '(II)V', [TJVMValue.Int(First), TJVMValue.Int(Last)]);
        var Bias, Scale: TArray<TJVMValue>;
        if Encoding <> 0 then
        begin
          Bias := Floats(Components);
          Scale := Floats(Components);
        end;
        var Vector := Load.NewArray('[F', Components);
        for var K := 0 to Count - 1 do
        begin
          if Load.VM.StopRequested then
            Bad('M3G keyframe loading cancelled');
          var Time := Reader.I32;
          var Values := Load.VM.GetObject(Vector);
          for var J := 0 to Components - 1 do
            if Encoding = 0 then
              Values.Elements[J] := TJVMValue.Float(Reader.Float32)
            else
            begin
              var Quantized: Double;
              var Maximum: Double;
              if Encoding = 1 then
              begin
                Quantized := Reader.U8;
                Maximum := 255;
              end
              else
              begin
                Quantized := Reader.U16;
                Maximum := 65535;
              end;
              Values.Elements[J] := TJVMValue.Float(Bias[J].AsFloat + Quantized * Scale[J].AsFloat / Maximum);
            end;
          Call('KeyframeSequence', 'setKeyframe', '(II[F)V', [TJVMValue.Int(K), TJVMValue.Int(Time), TJVMValue.Ref(Vector)]);
        end;
        M3GValidateSequence(Load.VM, ObjectRef);
      end;
    20:
      VertexArray;
    21:
      VertexBuffer;
    22:
      begin
        Group;
        var Camera := Ref('Camera');
        var Background := Ref('Background');
        if Camera <> 0 then
        begin
          Call('World', 'setActiveCamera', '(Ljavax/microedition/m3g/Camera;)V', [TJVMValue.Ref(Camera)]);
          if RepairOrphanCamera then
          begin
            var Parent: TJVMValue;
            var CameraObject := Load.VM.GetObject(Camera);
            if not CameraObject.Fields.TryGetValue(P + 'parent', Parent) or (Parent.AsRef = 0) then
              Call('Group', 'addChild', '(Ljavax/microedition/m3g/Node;)V', [TJVMValue.Ref(Camera)]);
          end;
        end;
        Call('World', 'setBackground', '(Ljavax/microedition/m3g/Background;)V', [TJVMValue.Ref(Background)]);
      end;
  else
    Bad('Unsupported M3G scene object ' + IntToStr(Kind));
  end;
end;

function TM3GObjectReader.Decode(const Document: TM3GDocument; const Location: string; Depth: Integer): TArray<Integer>;
const
  Names: array[0..22] of string = ('', 'AnimationController', 'AnimationTrack', 'Appearance', 'Background', 'Camera', 'CompositingMode', 'Fog', 'PolygonMode', 'Group', 'Image2D', 'TriangleStripArray', 'Light', 'Material', 'Mesh', 'MorphingMesh', 'SkinnedMesh', 'Texture2D', 'Sprite3D', 'KeyframeSequence', 'VertexArray', 'VertexBuffer', 'World');
begin
  Result := nil;
  for var K := 1 to High(Document.Objects) do
  begin
    if Load.VM.StopRequested then
      Bad('M3G loading cancelled');
    Current := K + 1;
    var Item := Document.Objects[K];
    Reader := TM3GDataReader.Create(Item.Data);
    try
      if Item.Kind = 255 then
      begin
        var Name := Reader.UTF8;
        Reader.Finish;
        var external := Load.Resource(Name, Location, Depth + 1);
        if Length(external) = 0 then
          Bad('M3G external reference has no root');
        Refs[Current] := external[0];
      end
      else
      begin
        if (Item.Kind > High(Names)) or (Names[Item.Kind] = '') then
          Bad('M3G scene object not implemented: ' + IntToStr(Item.Kind));
        ObjectRef := Load.NewObject(Names[Item.Kind]);
        Refs[Current] := ObjectRef;
        ObjectData(Item.Kind);
        Reader.Finish;
      end;
    finally
      Reader.Free;
      Reader := nil;
    end;
  end;
  for var K := 2 to High(Refs) do
    if not Used[K] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Refs[K];
    end;
end;

function InvokeM3GLoader(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  // Public argument errors differ from malformed file contents. Validate them
  // before converting immediate scene-construction failures into IOException.
  var Input := VM.GetObject(Args[0].AsRef);
  if Method.Descriptor.StartsWith('([BI)') and
    ((Args[1].AsInt < 0) or (Args[1].AsInt >= Length(Input.Elements))) then
    VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G load offset');
  var Load := TM3GLoad.Create(VM, Suite);
  try
    try
      Result := TJVMValue.Ref(Load.Load(Method, Args));
    except
      on E: EM3GFormat do
        VM.RaiseJava('java/io/IOException', E.Message);
      on E: EPNGFormat do
        VM.RaiseJava('java/io/IOException', 'M3G PNG: ' + E.Message);
      on E: EReadError do
        VM.RaiseJava('java/io/IOException', 'M3G resource: ' + E.Message);
      on E: EJVMThrown do
      begin
        var ClassName := VM.GetObject(E.Reference).ClassName;
        if VM.IsAssignable(ClassName, 'java/lang/Error') then
          raise;
        VM.RaiseJava('java/io/IOException', 'Invalid M3G object: ' + ClassName);
      end;
    end;
  finally
    Load.Free;
  end;
end;

end.

