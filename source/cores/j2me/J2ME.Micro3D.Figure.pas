unit J2ME.Micro3D.Figure;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.Suite;

procedure InstallJ2MEMicro3DFigure(VM: TJVM);

function J2MEMicro3DFigureHandles(const ClassName: string): Boolean;

function InvokeJ2MEMicro3DFigure(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.Classes, System.Math, System.SysUtils, Java.Classes,
  J2ME.Micro3D.Action;

const
  FigureName = 'com/mascotcapsule/micro3d/v3/Figure';
  TextureName = 'com/mascotcapsule/micro3d/v3/Texture';
  TextureType = 'L' + TextureName + ';';
  TextureIndexKey = FigureName + '.$textureIndex:I';
  TextureArrayKey = FigureName + '.$textures:[' + TextureType;
  PatternKey = FigureName + '.$pattern:I';
  PatternCountKey = FigureName + '.$patternCount:I';
  MaterialCountKey = FigureName + '.$materialCount:I';
  MaxFigureBytes = 8 * 1024 * 1024;

type
  TMBACReader = record
    Data: TBytes;
    Position, Limit, BitsLeft: Integer;
    Pending: Cardinal;
    procedure Align;
    function Bits(Count: Integer): Integer;
    function SignedBits(Count: Integer): Integer;
  end;

  TFace = record
    Corners, Flags, RGB, TextureSlot, Pattern: Integer;
    Indices, U, V: array[0..3] of Integer;
  end;

  TBone = record
    VertexCount, Parent: Integer;
    Matrix: array[0..11] of Integer;
  end;

  TFigureData = record
    Vertices, Normals: TArray<Integer>;
    Faces: TArray<TFace>;
    Bones: TArray<TBone>;
    PatternCount, TextureSlots: Integer;
  end;

procedure Require(Condition: Boolean; const MessageText: string);
begin
  if not Condition then
    raise EReadError.Create('MBAC: ' + MessageText);
end;

procedure TMBACReader.Align;
begin
  BitsLeft := 0;
  Pending := 0;
end;

function TMBACReader.Bits(Count: Integer): Integer;
begin
  // MBAC packs the first field into the least significant bits of each byte.
  Require((Count >= 0) and (Count <= 16), 'field bit width');
  while BitsLeft < Count do
  begin
    Require(Position < Limit, 'truncated data');
    Pending := Pending or (Cardinal(Data[Position]) shl BitsLeft);
    Inc(Position);
    Inc(BitsLeft, 8);
  end;
  Result := Pending and ((Cardinal(1) shl Count) - 1);
  Pending := Pending shr Count;
  Dec(BitsLeft, Count);
end;

function TMBACReader.SignedBits(Count: Integer): Integer;
begin
  Result := Bits(Count);
  if Result >= (1 shl (Count - 1)) then
    Dec(Result, 1 shl Count);
end;

function DecodeFigure(const Data: TBytes): TFigureData;
const
  ComponentBits: array[0..3] of Integer = (8, 10, 13, 16);
  NormalAxis: array[0..5, 0..2] of Integer =
    ((4096, 0, 0), (0, 4096, 0), (0, 0, 4096), (-4096, 0, 0), (0, -4096, 0), (0, 0, -4096));
var
  Reader: TMBACReader;
  FaceCounts, AssignedCounts: array[0..3] of Integer;
  FaceStart: array[0..3] of Integer;
  VertexCount, ColorCount: Integer;

  procedure AssignFaces(Group, Count, Pattern, Slot: Integer);
  begin
    Require(Count <= FaceCounts[Group] - AssignedCounts[Group], 'too many faces in pattern');
    var First := FaceStart[Group] + AssignedCounts[Group];
    for var I := First to First + Count - 1 do
    begin
      Result.Faces[I].Pattern := Pattern;
      Result.Faces[I].TextureSlot := Slot;
    end;
    Inc(AssignedCounts[Group], Count);
  end;

  procedure ReadFaces(Group, Encoding, FlagsBits, IndexBits, UVBits, ColorBits: Integer; const Colors: TArray<Integer>);
  begin
    for var I := FaceStart[Group] to FaceStart[Group] + FaceCounts[Group] - 1 do
    begin
      var Face := Result.Faces[I];
      Face.Corners := 3 + (Group and 1);
      Face.Flags := Reader.Bits(FlagsBits);
      if Encoding = 1 then
        Face.Flags := ((Face.Flags and 4) shl 2) or ((Face.Flags and 2) shr 1)
      else if Group >= 2 then
        Face.Flags := Face.Flags shl 1;
      for var J := 0 to Face.Corners - 1 do
      begin
        Face.Indices[J] := Reader.Bits(IndexBits);
        Require(Face.Indices[J] < VertexCount, 'face vertex index');
      end;
      if Group < 2 then
        for var J := 0 to Face.Corners - 1 do
        begin
          Face.U[J] := Reader.Bits(UVBits);
          Face.V[J] := Reader.Bits(UVBits);
        end
      else
      begin
        var Color := Reader.Bits(ColorBits);
        Require(Color < Length(Colors), 'face color index');
        Face.RGB := Colors[Color];
      end;
      Result.Faces[I] := Face;
    end;
  end;

begin
  Result := Default(TFigureData);
  Reader := Default(TMBACReader);
  Reader.Data := Data;
  Reader.Limit := Length(Data);
  Require(Reader.Limit <= MaxFigureBytes, 'model too large');
  Require(Reader.Bits(16) = $424D, 'signature');
  var Version := Reader.Bits(16);
  Require(Version in [2, 3, 4, 5], 'unsupported version');
  var VertexEncoding := 1;
  var NormalEncoding := 0;
  var FaceEncoding := 1;
  if Version >= 4 then
  begin
    VertexEncoding := Reader.Bits(8);
    NormalEncoding := Reader.Bits(8);
    FaceEncoding := Reader.Bits(8);
    Require(Reader.Bits(8) = 1, 'unsupported bone encoding');
    Require((VertexEncoding in [1, 2]) and (NormalEncoding in [0, 1, 2]) and
      (FaceEncoding >= 1) and (FaceEncoding <= Version - 2), 'unsupported geometry encoding');
    Dec(Reader.Limit, 20); // Exporter trailer is outside the geometry bitstream.
  end;

  VertexCount := Reader.Bits(16);
  FaceCounts[0] := Reader.Bits(16);
  FaceCounts[1] := Reader.Bits(16);
  var BoneCount := Reader.Bits(16);
  FaceCounts[2] := 0;
  FaceCounts[3] := 0;
  Result.PatternCount := 1;
  Result.TextureSlots := 1;
  ColorCount := 0;
  if FaceEncoding = 3 then
  begin
    FaceCounts[2] := Reader.Bits(16);
    FaceCounts[3] := Reader.Bits(16);
    Result.TextureSlots := Reader.Bits(16);
    Result.PatternCount := Reader.Bits(16);
    ColorCount := Reader.Bits(16);
  end;
  Require((Result.TextureSlots <= 16) and (Result.PatternCount in [1..33]) and
    (ColorCount <= 256), 'pattern, texture or palette count');
  var TotalFaces := 0;
  for var Group := 0 to 3 do
  begin
    FaceStart[Group] := TotalFaces;
    Inc(TotalFaces, FaceCounts[Group]);
    AssignedCounts[Group] := 0;
  end;
  Require((VertexCount <= 21845) and (TotalFaces <= 65535) and (BoneCount <= 32768),
    'geometry count exceeds limits');
  SetLength(Result.Faces, TotalFaces);

  if Version = 5 then
  begin
    for var Pattern := 0 to Result.PatternCount - 1 do
    begin
      AssignFaces(2, Reader.Bits(16), Pattern, -1);
      AssignFaces(3, Reader.Bits(16), Pattern, -1);
      for var Slot := 0 to Result.TextureSlots - 1 do
      begin
        AssignFaces(0, Reader.Bits(16), Pattern, Slot);
        AssignFaces(1, Reader.Bits(16), Pattern, Slot);
      end;
    end;
    for var Group := 0 to 3 do
      Require(AssignedCounts[Group] = FaceCounts[Group], 'incomplete pattern table');
  end;

  SetLength(Result.Vertices, VertexCount * 3);
  if VertexEncoding = 1 then
    for var I := 0 to High(Result.Vertices) do
      Result.Vertices[I] := Reader.SignedBits(16)
  else
  begin
    var Index := 0;
    while Index < Length(Result.Vertices) do
    begin
      var Header := Reader.Bits(8);
      var Components := ((Header and 63) + 1) * 3;
      Require(Components <= Length(Result.Vertices) - Index, 'vertex block exceeds count');
      var Width := ComponentBits[Header shr 6];
      for var I := 1 to Components do
      begin
        Result.Vertices[Index] := Reader.SignedBits(Width);
        Inc(Index);
      end;
    end;
  end;
  Reader.Align;

  if NormalEncoding <> 0 then
    SetLength(Result.Normals, VertexCount * 3);
  if NormalEncoding = 1 then
    for var I := 0 to High(Result.Normals) do
      Result.Normals[I] := Reader.SignedBits(16)
  else if NormalEncoding = 2 then
    for var Vertex := 0 to VertexCount - 1 do
    begin
      var X := Reader.SignedBits(7);
      if X = -64 then
      begin
        var Direction := Reader.Bits(3);
        Require(Direction <= 5, 'normal axis');
        for var Axis := 0 to 2 do
          Result.Normals[Vertex * 3 + Axis] := NormalAxis[Direction, Axis];
      end
      else
      begin
        X := X * 64;
        var Y := Reader.SignedBits(7) * 64;
        var Z := Round(Sqrt(Max(0, 4096 * 4096 - X * X - Y * Y)));
        if Reader.Bits(1) <> 0 then
          Z := -Z;
        Result.Normals[Vertex * 3] := X;
        Result.Normals[Vertex * 3 + 1] := Y;
        Result.Normals[Vertex * 3 + 2] := Z;
      end;
    end;
  Reader.Align;

  if FaceCounts[2] + FaceCounts[3] > 0 then
  begin
    var FlagsBits := Reader.Bits(8);
    var IndexBits := Reader.Bits(8);
    var ChannelBits := Reader.Bits(8);
    var ColorBits := Reader.Bits(8);
    Reader.Bits(8); // Reserved exporter field.
    Require(ChannelBits <= 8, 'color channel bit width');
    var Colors: TArray<Integer>;
    SetLength(Colors, ColorCount);
    for var I := 0 to High(Colors) do
    begin
      var R := Reader.Bits(ChannelBits);
      var G := Reader.Bits(ChannelBits);
      Colors[I] := (R shl 16) or (G shl 8) or Reader.Bits(ChannelBits);
    end;
    ReadFaces(2, 3, FlagsBits, IndexBits, 0, ColorBits, Colors);
    ReadFaces(3, 3, FlagsBits, IndexBits, 0, ColorBits, Colors);
  end;

  if FaceCounts[0] + FaceCounts[1] > 0 then
  begin
    var FlagsBits := 16;
    var IndexBits := 16;
    var UVBits := 8;
    if FaceEncoding >= 2 then
    begin
      FlagsBits := Reader.Bits(8);
      IndexBits := Reader.Bits(8);
      UVBits := 7;
    end;
    if FaceEncoding = 3 then
    begin
      UVBits := Reader.Bits(8);
      Reader.Bits(8); // Reserved exporter field.
      Require(UVBits <= 8, 'UV bit width');
    end;
    ReadFaces(0, FaceEncoding, FlagsBits, IndexBits, UVBits, 0, nil);
    ReadFaces(1, FaceEncoding, FlagsBits, IndexBits, UVBits, 0, nil);
  end;
  Reader.Align;

  SetLength(Result.Bones, BoneCount);
  var CoveredVertices := 0;
  for var I := 0 to BoneCount - 1 do
  begin
    var Bone: TBone;
    Bone.VertexCount := Reader.Bits(16);
    Bone.Parent := Reader.SignedBits(16);
    Require((Bone.Parent >= -1) and (Bone.Parent < BoneCount), 'bone hierarchy index');
    for var J := 0 to High(Bone.Matrix) do
      Bone.Matrix[J] := Reader.SignedBits(16);
    Inc(CoveredVertices, Bone.VertexCount);
    Require(CoveredVertices <= VertexCount, 'bone vertex groups exceed vertex count');
    Result.Bones[I] := Bone;
  end;
  Require(CoveredVertices = VertexCount, 'incomplete bone vertex groups');
  Require(Reader.Position = Reader.Limit, 'unexpected geometry length');

  var Visited: TArray<Byte>;
  SetLength(Visited, BoneCount);
  for var Start := 0 to BoneCount - 1 do
  begin
    var I := Start;
    while (I >= 0) and (Visited[I] = 0) do
    begin
      Visited[I] := 1;
      I := Result.Bones[I].Parent;
    end;
    Require((I < 0) or (Visited[I] = 2), 'cyclic bone hierarchy');
    I := Start;
    while (I >= 0) and (Visited[I] = 1) do
    begin
      Visited[I] := 2;
      I := Result.Bones[I].Parent;
    end;
  end;
end;

procedure InstallJ2MEMicro3DFigure(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(FigureName, 'java/lang/Object');
  try
    for var Name in ['$vertices', '$normals', '$faces', '$bones'] do
      B.Field(Name, '[I', JVM_ACC_PRIVATE);
    B.Field('$textures', '[' + TextureType, JVM_ACC_PRIVATE);
    for var Name in ['$pattern', '$patternCount', '$materialCount', '$textureIndex'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('<init>', '([B)V');
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;)V');
    B.Field('$pose', '[F', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('setPosture', '(' + Micro3DActionType + 'II)V');
    B.JavaClass.AddNative('dispose', '()V');
    B.JavaClass.AddNative('getTexture', '()' + TextureType);
    B.JavaClass.AddNative('setTexture', '(' + TextureType + ')V');
    B.JavaClass.AddNative('setTexture', '([' + TextureType + ')V');
    B.JavaClass.AddNative('selectTexture', '(I)V');
    B.JavaClass.AddNative('getNumTextures', '()I');
    B.JavaClass.AddNative('getNumPattern', '()I');
    B.JavaClass.AddNative('setPattern', '(I)V');
    for var Method in B.JavaClass.Methods do
      if Method.Name <> '<init>' then
        Method.Access := Method.Access or JVM_ACC_FINAL;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function J2MEMicro3DFigureHandles(const ClassName: string): Boolean;
begin
  Result := ClassName = FigureName;
end;

procedure StoreFigure(VM: TJVM; O: TJVMObject; const Model: TFigureData);
const
  FaceInts = 17;
  BoneInts = 14;
var
  Values: TArray<Integer>;

  procedure Store(const Name: string; const Data: TArray<Integer>);
  begin
    var Ref := VM.NewArray('[I', Length(Data));
    var A := VM.GetObject(Ref);
    for var I := 0 to High(Data) do
      A.ElementValues[I] := TJVMValue.Int(Data[I]);
    O.Fields[FigureName + '.' + Name + ':[I'] := TJVMValue.Ref(Ref);
  end;

begin
  Store('$vertices', Model.Vertices);
  Store('$normals', Model.Normals);
  SetLength(Values, Length(Model.Faces) * FaceInts);
  for var I := 0 to High(Model.Faces) do
  begin
    var F := Model.Faces[I];
    var Start := I * FaceInts;
    Values[Start] := F.Corners;
    Values[Start + 1] := F.Flags;
    Values[Start + 2] := F.RGB;
    Values[Start + 3] := F.TextureSlot;
    Values[Start + 4] := F.Pattern;
    for var J := 0 to 3 do
    begin
      Values[Start + 5 + J * 3] := F.Indices[J];
      Values[Start + 6 + J * 3] := F.U[J];
      Values[Start + 7 + J * 3] := F.V[J];
    end;
  end;
  Store('$faces', Values);
  SetLength(Values, Length(Model.Bones) * BoneInts);
  for var I := 0 to High(Model.Bones) do
  begin
    var Bone := Model.Bones[I];
    Values[I * BoneInts] := Bone.VertexCount;
    Values[I * BoneInts + 1] := Bone.Parent;
    for var J := 0 to High(Bone.Matrix) do
      Values[I * BoneInts + 2 + J] := Bone.Matrix[J];
  end;
  Store('$bones', Values);
  O.Fields[PatternCountKey] := TJVMValue.Int(Model.PatternCount);
  O.Fields[MaterialCountKey] := TJVMValue.Int(Model.TextureSlots);
  O.Fields[TextureIndexKey] := TJVMValue.Int(-1);
end;

function InvokeJ2MEMicro3DFigure(VM: TJVM; Suite: TJ2MESuite; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

  procedure CheckModelTexture(Value: TJVMValue);
  begin
    var T := VM.GetObject(Value.AsRef);
    if T.Fields[TextureName + '.$model:Z'].AsInt = 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Expected a model texture');
  end;

begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var Name := Method.Name;
  if Name = '<init>' then
  begin
    var Input := VM.GetObject(Args[1].AsRef);
    var Data: TBytes;
    if Method.Descriptor = '([B)V' then
    begin
      if Input.ElementCount > MaxFigureBytes then
        VM.RaiseJava('java/lang/RuntimeException', 'MBAC model exceeds the decoder limit');
      SetLength(Data, Input.ElementCount);
      for var I := 0 to High(Data) do
        Data[I] := Byte(Input.ElementValues[I].AsInt and $FF);
    end
    else
    begin
      if (Input.Text = '') or not Suite.HasResource(Input.Text) then
        VM.RaiseJava('java/io/IOException', 'Missing model: ' + Input.Text);
      try
        Data := Suite.ReadResource(Input.Text);
      except
        on E: EStreamError do
          VM.RaiseJava('java/io/IOException', E.Message);
      end;
    end;
    try
      StoreFigure(VM, O, DecodeFigure(Data));
    except
      on E: EReadError do
        VM.RaiseJava('java/lang/RuntimeException', E.Message);
    end;
    Exit;
  end;
  if Name = 'dispose' then
  begin
    for var Field in ['$vertices', '$normals', '$faces', '$bones'] do
      O.Fields[FigureName + '.' + Field + ':[I'] := TJVMValue.Ref(0);
    O.Fields[Micro3DPoseKey] := TJVMValue.Ref(0);
    O.Fields[TextureIndexKey] := TJVMValue.Int(-1);
    O.Fields[TextureArrayKey] := TJVMValue.Ref(0);
    O.Fields[MaterialCountKey] := TJVMValue.Int(0);
    O.Fields[PatternCountKey] := TJVMValue.Int(0);
    O.Fields[PatternKey] := TJVMValue.Int(0);
    Exit;
  end;
  if Name = 'setPosture' then
  begin
    var Table := VM.GetObject(Args[1].AsRef);
    var Bones := O.Fields[FigureName + '.$bones:[I'].AsRef;
    if Bones = 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'Figure is disposed');
    var Pattern := O.Fields[PatternKey].AsInt;
    SetMicro3DPosture(VM, O, Table, VM.GetObject(Bones).ElementCount div 14, Args[2].AsInt, Args[3].AsInt, Pattern);
    O.Fields[PatternKey] := TJVMValue.Int(Pattern);
    Exit;
  end;
  if Name = 'getNumPattern' then
    Exit(O.Fields[PatternCountKey]);
  if Name = 'setPattern' then
  begin
    O.Fields[PatternKey] := Args[1];
    Exit;
  end;
  if Name = 'getTexture' then
  begin
    var Index := O.Fields[TextureIndexKey].AsInt;
    if Index < 0 then
      Exit(TJVMValue.Ref(0));
    var Textures := VM.GetObject(O.Fields[TextureArrayKey].AsRef);
    Exit(Textures.ElementValues[Index]);
  end;
  if Name = 'setTexture' then
  begin
    if Method.Descriptor = '(' + TextureType + ')V' then
    begin
      CheckModelTexture(Args[1]);
      var Ref := VM.NewArray('[' + TextureType, 1);
      VM.GetObject(Ref).ElementValues[0] := Args[1];
      O.Fields[TextureArrayKey] := TJVMValue.Ref(Ref);
      O.Fields[TextureIndexKey] := TJVMValue.Int(0);
    end
    else
    begin
      var Textures := VM.GetObject(Args[1].AsRef);
      if Textures.ElementCount = 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Empty model texture array');
      for var I := 0 to Textures.ElementCount - 1 do
        CheckModelTexture(Textures.ElementValues[I]);
      O.Fields[TextureArrayKey] := Args[1];
      O.Fields[TextureIndexKey] := TJVMValue.Int(-1);
    end;
    Exit;
  end;
  var TextureArray := O.Fields[TextureArrayKey].AsRef;
  if Name = 'getNumTextures' then
  begin
    if TextureArray = 0 then
      Exit(TJVMValue.Int(0));
    Exit(TJVMValue.Int(VM.GetObject(TextureArray).ElementCount));
  end;
  if Name = 'selectTexture' then
  begin
    var I := Args[1].AsInt;
    if (I < 0) or (TextureArray = 0) or (I >= VM.GetObject(TextureArray).ElementCount) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Texture selection index');
    var Value := VM.GetObject(TextureArray).ElementValues[I];
    CheckModelTexture(Value);
    O.Fields[TextureIndexKey] := TJVMValue.Int(I);
    Exit;
  end;
  raise EJVMUnsupported.Create(FigureName + '.' + Name + Method.Descriptor);
end;

end.

