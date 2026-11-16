unit J2ME.M3G.Skin;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime, J2ME.M3G.Math;

const
  M3GMaxTransformsPerVertex = 4;

procedure InstallM3GSkin(VM: TJVM);

function M3GSkinHandles(const Name: string): Boolean;

function InvokeM3GSkin(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GSkinReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

function M3GSkinMatrices(VM: TJVM; Ref, VertexCount: Integer): TArray<TM3GMatrix>;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections,
  System.Generics.Defaults, Java.Classes, J2ME.M3G, J2ME.M3G.Mesh,
  J2ME.M3G.Scene;

const
  Name = 'javax/microedition/m3g/SkinnedMesh';
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsRef;
end;

procedure PR(O: TJVMObject; const Key: string; Ref: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Ref(Ref));
end;

function M3GSkinHandles(const Name: string): Boolean;
begin
  Result := Name = 'javax/microedition/m3g/SkinnedMesh';
end;

procedure InstallM3GSkin(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, Base + 'Mesh');
  try
    for var Arrays in [False, True] do
    begin
      var A := '';
      if Arrays then
        A := '[';
      B.JavaClass.AddNative('<init>', '(Ljavax/microedition/m3g/VertexBuffer;' + A + 'Ljavax/microedition/m3g/IndexBuffer;' + A + 'Ljavax/microedition/m3g/Appearance;Ljavax/microedition/m3g/Group;)V');
    end;
    B.JavaClass.AddNative('getSkeleton', '()Ljavax/microedition/m3g/Group;');
    B.JavaClass.AddNative('addTransform', '(Ljavax/microedition/m3g/Node;III)V');
    B.JavaClass.AddNative('getBoneTransform', '(Ljavax/microedition/m3g/Node;Ljavax/microedition/m3g/Transform;)V');
    B.JavaClass.AddNative('getBoneVertices', '(Ljavax/microedition/m3g/Node;[I[F)I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function BoneIndex(VM: TJVM; O: TJVMObject; Bone: Integer): Integer;
begin
  VM.GetObject(Bone);
  var At := Bone;
  var Skeleton := R(O, 'skinSkeleton');
  while At <> Skeleton do
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G bone lookup cancelled');
    if At = 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G bone outside skeleton');
    At := R(VM.GetObject(At), 'parent');
  end;
  Result := -1;
  var Ref := R(O, 'skinBones');
  if Ref = 0 then
    Exit;
  var Bones := VM.GetObject(Ref);
  for var K := 0 to High(Bones.Elements) do
    if Bones.Elements[K].AsRef = Bone then
      Exit(K);
end;

function M3GSkinReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  var Ref := R(O, 'skinBones');
  if Ref = 0 then
    Exit;
  var Bones := VM.GetObject(Ref);
  SetLength(Result, Length(Bones.Elements));
  for var K := 0 to High(Result) do
    Result[K] := Bones.Elements[K].AsRef;
end;

type
  TSkinRange = record
    Bone, First, Count, Weight: Integer;
  end;

  TSkinVertex = record
    Count: Integer;
    Bones: array[0..M3GMaxTransformsPerVertex - 1] of Integer;
    Weights: array[0..M3GMaxTransformsPerVertex - 1] of Int64;
  end;

function Weights(VM: TJVM; O: TJVMObject; VertexCount: Integer): TArray<TSkinVertex>;
begin
  Result := nil;
  var Ref := R(O, 'skinRanges');
  if Ref = 0 then
    Exit;
  var Input := VM.GetObject(Ref);
  var Ranges := TList<TSkinRange>.Create;
  try
    var Highest := 0;
    for var K := 0 to Length(Input.Elements) div 4 - 1 do
    begin
      var Entry: TSkinRange;
      Entry.Bone := Input.Elements[K * 4].AsInt;
      Entry.First := Input.Elements[K * 4 + 1].AsInt;
      Entry.Count := Input.Elements[K * 4 + 2].AsInt;
      Entry.Weight := Input.Elements[K * 4 + 3].AsInt;
      if Entry.First + Entry.Count > VertexCount then
        VM.RaiseJava('java/lang/IllegalStateException', 'M3G skin range outside vertex buffer');
      Highest := Max(Highest, Entry.First + Entry.Count);
      Ranges.Add(Entry);
    end;
    SetLength(Result, Highest);
    // Aggregate overlapping calls for each bone before selecting the strongest
    // four bones. A sweep avoids allocating a vertices-by-bones weight table.
    Ranges.Sort(TComparer<TSkinRange>.Construct(
      function(const A, B: TSkinRange): Integer
      begin
        Result := A.Bone - B.Bone;
      end));
    var Difference: TArray<Int64>;
    SetLength(Difference, Highest + 1);
    var At := 0;
    while At < Ranges.Count do
    begin
      if VM.StopRequested then
        raise EJVMError.Create('M3G skin weighting cancelled');
      var Finish := At;
      var Low := Highest;
      var High := 0;
      var Bone := Ranges[At].Bone;
      while (Finish < Ranges.Count) and (Ranges[Finish].Bone = Bone) do
      begin
        Low := Min(Low, Ranges[Finish].First);
        High := Max(High, Ranges[Finish].First + Ranges[Finish].Count);
        Inc(Finish);
      end;
      for var K := Low to High do
        Difference[K] := 0;
      for var K := At to Finish - 1 do
      begin
        var E := Ranges[K];
        Inc(Difference[E.First], Int64(E.Weight));
        Dec(Difference[E.First + E.Count], Int64(E.Weight));
      end;
      var Running := Int64(0);
      for var Vertex := Low to High - 1 do
      begin
        if (Vertex and 255) = 0 then
          if VM.StopRequested then
            raise EJVMError.Create('M3G skin weighting cancelled');
        Inc(Running, Difference[Vertex]);
        if Running = 0 then
          Continue;
        var Entry := Result[Vertex];
        var Slot := 0;
        while (Slot < Entry.Count) and ((Entry.Weights[Slot] > Running) or
          ((Entry.Weights[Slot] = Running) and (Entry.Bones[Slot] < Bone))) do
          Inc(Slot);
        if Slot >= M3GMaxTransformsPerVertex then
          Continue;
        for var K := Min(Entry.Count, M3GMaxTransformsPerVertex - 1) downto Slot + 1 do
        begin
          Entry.Bones[K] := Entry.Bones[K - 1];
          Entry.Weights[K] := Entry.Weights[K - 1];
        end;
        Entry.Bones[Slot] := Bone;
        Entry.Weights[Slot] := Running;
        Entry.Count := Min(Entry.Count + 1, M3GMaxTransformsPerVertex);
        Result[Vertex] := Entry;
      end;
      At := Finish;
    end;
  finally
    Ranges.Free;
  end;
end;

function M3GSkinMatrices(VM: TJVM; Ref, VertexCount: Integer): TArray<TM3GMatrix>;
begin
  Result := nil;
  if Ref = 0 then
    Exit;
  var O := VM.GetObject(Ref);
  var Vertices := Weights(VM, O, VertexCount);
  if Length(Vertices) = 0 then
    Exit;
  var Bones := VM.GetObject(R(O, 'skinBones'));
  var Rest := VM.GetObject(R(O, 'skinBind'));
  var Palette: TArray<TM3GMatrix>;
  var Ready: TArray<Boolean>;
  SetLength(Palette, Length(Bones.Elements));
  SetLength(Ready, Length(Bones.Elements));
  SetLength(Result, Length(Vertices));
  for var Vertex := 0 to High(Vertices) do
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G skin palette cancelled');
    var Entry := Vertices[Vertex];
    var Total := Int64(0);
    for var K := 0 to Entry.Count - 1 do
      Inc(Total, Entry.Weights[K]);
    if Entry.Count = 0 then
    begin
      Result[Vertex] := M3GIdentity;
      Continue;
    end;
    var Sum: array[0..15] of Double;
    FillChar(Sum, SizeOf(Sum), 0);
    for var K := 0 to Entry.Count - 1 do
    begin
      var Bone := Entry.Bones[K];
      if not Ready[Bone] then
      begin
        var Current, Bind: TM3GMatrix;
        if not M3GRelativeTransform(VM, Bones.Elements[Bone].AsRef, Ref, Current) then
          VM.RaiseJava('java/lang/IllegalStateException', 'M3G disconnected bone');
        for var J := 0 to 15 do
          Bind[J] := Rest.Elements[Bone * 16 + J].AsFloat;
        Palette[Bone] := M3GMultiply(Current, Bind);
        Ready[Bone] := True;
      end;
      var Weight: Double := Entry.Weights[K] / Total;
      for var J := 0 to 15 do
        Sum[J] := Sum[J] + Weight * Palette[Bone][J];
    end;
    for var K := 0 to 15 do
      Result[Vertex][K] := Sum[K];
  end;
end;

function InvokeM3GSkin(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var Self := Args[0].AsRef;
  var O := VM.GetObject(Self);
  var N := Method.Name;
  if N = '<init>' then
  begin
    var SkeletonRef := Args[4].AsRef;
    var Skeleton := VM.GetObject(SkeletonRef);
    if VM.IsAssignable(Skeleton.ClassName, Base + 'World') or (R(Skeleton, 'parent') <> 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G skeleton must be a free Group');
    var Descriptor := Copy(Method.Descriptor, 1, Length(Method.Descriptor) - Length('Ljavax/microedition/m3g/Group;)V')) + ')V';
    InvokeM3GMesh(VM, VM.LoadClass(Base + 'Mesh').FindMethod('<init>', Descriptor), [Args[0], Args[1], Args[2], Args[3]]);
    var Children := VM.NewArray('[Ljavax/microedition/m3g/Node;', 1);
    VM.GetObject(Children).Elements[0] := Args[4];
    PR(O, 'children', Children);
    PR(O, 'skinSkeleton', SkeletonRef);
    PR(Skeleton, 'parent', Self);
    Exit;
  end;
  if N = 'getSkeleton' then
    Exit(TJVMValue.Ref(R(O, 'skinSkeleton')));
  var Bone := Args[1].AsRef;
  var Index := BoneIndex(VM, O, Bone);
  if N = 'getBoneTransform' then
  begin
    VM.GetObject(Args[2].AsRef);
    var Bind := M3GIdentity;
    if Index >= 0 then
    begin
      var Data := VM.GetObject(R(O, 'skinBind'));
      for var K := 0 to 15 do
        Bind[K] := Data.Elements[Index * 16 + K].AsFloat;
    end;
    M3GPutMatrix(VM, Args[2].AsRef, Bind);
    Exit;
  end;
  if N = 'getBoneVertices' then
  begin
    var Vertices := Weights(VM, O, 65535);
    var Count := 0;
    for var Entry in Vertices do
      for var K := 0 to Entry.Count - 1 do
        if Entry.Bones[K] = Index then
          Inc(Count);
    Result := TJVMValue.Int(Count);
    if (Args[2].AsRef = 0) or (Args[3].AsRef = 0) then
      Exit;
    var Indices := VM.GetObject(Args[2].AsRef);
    var Output := VM.GetObject(Args[3].AsRef);
    if (Length(Indices.Elements) < Count) or (Length(Output.Elements) < Count) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G bone vertex output size');
    var At := 0;
    for var Vertex := 0 to High(Vertices) do
    begin
      var Entry := Vertices[Vertex];
      var Total := Int64(0);
      for var K := 0 to Entry.Count - 1 do
        Inc(Total, Entry.Weights[K]);
      for var K := 0 to Entry.Count - 1 do
        if Entry.Bones[K] = Index then
        begin
          Indices.Elements[At] := TJVMValue.Int(Vertex);
          Output.Elements[At] := TJVMValue.Float(Entry.Weights[K] / Total);
          Inc(At);
        end;
    end;
    Exit;
  end;
  if N = 'addTransform' then
  begin
    var Weight := Args[2].AsInt;
    var First := Args[3].AsInt;
    var Count := Args[4].AsInt;
    if (Weight <= 0) or (Count <= 0) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G bone weight/count');
    if (First < 0) or (Int64(First) + Count > 65535) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G bone range');
    var Bind: TM3GMatrix;
    if not M3GRelativeTransform(VM, Self, Bone, Bind) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G bone path');
    var Kept := TList<Integer>.Create;
    try
      var BoneRef := R(O, 'skinBones');
      var BindRef := R(O, 'skinBind');
      if Index < 0 then
      begin
        var OldCount := 0;
        if BoneRef <> 0 then
          OldCount := Length(VM.GetObject(BoneRef).Elements);
        var NewBones := VM.NewArray('[Ljavax/microedition/m3g/Node;', OldCount + 1);
        VM.AddRoot(NewBones);
        Kept.Add(NewBones);
        var NewBind := VM.NewArray('[F', (OldCount + 1) * 16);
        VM.AddRoot(NewBind);
        Kept.Add(NewBind);
        for var K := 0 to OldCount - 1 do
          VM.GetObject(NewBones).Elements[K] := VM.GetObject(BoneRef).Elements[K];
        for var K := 0 to OldCount * 16 - 1 do
          VM.GetObject(NewBind).Elements[K] := VM.GetObject(BindRef).Elements[K];
        VM.GetObject(NewBones).Elements[OldCount] := Args[1];
        for var K := 0 to 15 do
          VM.GetObject(NewBind).Elements[OldCount * 16 + K] := TJVMValue.Float(Bind[K]);
        Index := OldCount;
        BoneRef := NewBones;
        BindRef := NewBind;
      end;
      var OldRef := R(O, 'skinRanges');
      var OldCount := 0;
      if OldRef <> 0 then
        OldCount := Length(VM.GetObject(OldRef).Elements);
      var NewRanges := VM.NewArray('[I', OldCount + 4);
      VM.AddRoot(NewRanges);
      Kept.Add(NewRanges);
      var Data := VM.GetObject(NewRanges);
      for var K := 0 to OldCount - 1 do
        Data.Elements[K] := VM.GetObject(OldRef).Elements[K];
      Data.Elements[OldCount] := TJVMValue.Int(Index);
      Data.Elements[OldCount + 1] := Args[3];
      Data.Elements[OldCount + 2] := Args[4];
      Data.Elements[OldCount + 3] := Args[2];
      PR(O, 'skinBones', BoneRef);
      PR(O, 'skinBind', BindRef);
      PR(O, 'skinRanges', NewRanges);
    finally
      for var Ref in Kept do
        VM.RemoveRoot(Ref);
      Kept.Free;
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

end.

