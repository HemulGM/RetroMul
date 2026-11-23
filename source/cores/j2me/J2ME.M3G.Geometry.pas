unit J2ME.M3G.Geometry;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

const
  M3GTextureUnits = 2;

procedure InstallM3GGeometry(VM: TJVM);

function M3GGeometryHandles(const Name: string): Boolean;

function InvokeM3GGeometry(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GGeometryReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

implementation

uses
  System.SysUtils, Java.Classes;

const
  Base = 'javax/microedition/m3g/';
  BufferName = Base + 'VertexBuffer';
  IndexName = Base + 'IndexBuffer';
  StripName = Base + 'TriangleStripArray';
  VertexD = 'Ljavax/microedition/m3g/VertexArray;';
  P = '$m3g.';

function GetInt(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsInt;
end;

function GetRef(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsRef;
end;

function GetFloat(O: TJVMObject; const Name: string): Single;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsFloat;
end;

function SlotName(Slot: Integer): string;
begin
  case Slot of
    0:
      Result := 'positions';
    1:
      Result := 'normals';
    2:
      Result := 'colors';
  else
    Result := 'tex' + IntToStr(Slot - 3);
  end;
end;

procedure CheckUnit(VM: TJVM; UnitIndex: Integer);
begin
  if (UnitIndex < 0) or (UnitIndex >= M3GTextureUnits) then
    VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G texture unit');
end;

function VertexCount(VM: TJVM; O: TJVMObject; Exclude: Integer = -1): Integer;
begin
  Result := 0;
  for var Slot := 0 to 2 + M3GTextureUnits do
    if Slot <> Exclude then
    begin
      var Ref := GetRef(O, SlotName(Slot));
      if Ref <> 0 then
        Exit(GetInt(VM.GetObject(Ref), 'vertices'));
    end;
end;

function M3GGeometryReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, BufferName) then
    for var Slot := 0 to 2 + M3GTextureUnits do
    begin
      var Ref := GetRef(O, SlotName(Slot));
      if Ref <> 0 then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Ref;
      end;
    end;
end;

procedure InstallM3GGeometry(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(BufferName, Base + 'Object3D');
  try
    B.JavaClass.AddNative('<init>', '()V');
    for var N in ['getVertexCount', 'getDefaultColor'] do
      B.JavaClass.AddNative(N, '()I');
    B.JavaClass.AddNative('setDefaultColor', '(I)V');
    for var N in ['Normals', 'Colors'] do
    begin
      B.JavaClass.AddNative('get' + N, '()' + VertexD);
      B.JavaClass.AddNative('set' + N, '(' + VertexD + ')V');
    end;
    B.JavaClass.AddNative('getPositions', '([F)' + VertexD);
    B.JavaClass.AddNative('getTexCoords', '(I[F)' + VertexD);
    B.JavaClass.AddNative('setPositions', '(' + VertexD + 'F[F)V');
    B.JavaClass.AddNative('setTexCoords', '(I' + VertexD + 'F[F)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(IndexName, Base + 'Object3D', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
  try
    B.JavaClass.AddNative('getIndexCount', '()I');
    B.JavaClass.AddNative('getIndices', '([I)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(StripName, IndexName);
  try
    B.JavaClass.AddNative('<init>', '(I[I)V');
    B.JavaClass.AddNative('<init>', '([I[I)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function M3GGeometryHandles(const Name: string): Boolean;
begin
  Result := (Name = BufferName) or (Name = IndexName) or (Name = StripName);
end;

procedure SetAttribute(VM: TJVM; O: TJVMObject; Slot, Ref: Integer; Scale: Single; BiasRef: Integer);
var
  Bias: array[0..2] of Single;
begin
  for var I := 0 to 2 do
    Bias[I] := 0;
  if Ref <> 0 then
  begin
    var Attribute := VM.GetObject(Ref);
    var Components := GetInt(Attribute, 'components');
    if ((Slot <= 1) and (Components <> 3)) or
      ((Slot = 2) and ((Components < 3) or (Components > 4) or (GetInt(Attribute, 'size') <> 1))) or
      ((Slot >= 3) and ((Components < 2) or (Components > 3))) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex attribute dimensions');
    var Existing := VertexCount(VM, O, Slot);
    if (Existing <> 0) and (GetInt(Attribute, 'vertices') <> Existing) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex attribute count');
    if ((Slot = 0) or (Slot >= 3)) and (BiasRef <> 0) then
    begin
      var Values := VM.GetObject(BiasRef);
      if Length(Values.Elements) < Components then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G vertex bias length');
      for var I := 0 to Components - 1 do
        Bias[I] := Values.Elements[I].AsFloat;
    end;
  end;
  // Validate everything before replacing the attribute and its copied bias.
  var Name := SlotName(Slot);
  O.Fields.AddOrSetValue(P + Name, TJVMValue.Ref(Ref));
  if (Slot = 0) or (Slot >= 3) then
  begin
    O.Fields.AddOrSetValue(P + Name + '.scale', TJVMValue.Float(Scale));
    for var I := 0 to 2 do
      O.Fields.AddOrSetValue(P + Name + '.bias' + IntToStr(I), TJVMValue.Float(Bias[I]));
  end;
end;

function InvokeM3GGeometry(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  var C := Method.Owner.Name;
  if C = BufferName then
  begin
    if N = '<init>' then
    begin
      O.Fields.AddOrSetValue(P + 'color', TJVMValue.Int(-1));
      Exit;
    end;
    if N = 'getVertexCount' then
      Exit(TJVMValue.Int(VertexCount(VM, O)));
    if N = 'getDefaultColor' then
      Exit(TJVMValue.Int(GetInt(O, 'color')));
    if N = 'setDefaultColor' then
    begin
      O.Fields.AddOrSetValue(P + 'color', Args[1]);
      Exit;
    end;
    var Slot := 0;
    var First := 1;
    if (N = 'setTexCoords') or (N = 'getTexCoords') then
    begin
      CheckUnit(VM, Args[1].AsInt);
      Slot := 3 + Args[1].AsInt;
      First := 2;
    end
    else if (N = 'setNormals') or (N = 'getNormals') then
      Slot := 1
    else if (N = 'setColors') or (N = 'getColors') then
      Slot := 2;
    if N.StartsWith('set') then
    begin
      var Scale: Single := 1;
      var BiasRef := 0;
      if (Slot = 0) or (Slot >= 3) then
      begin
        Scale := Args[First + 1].AsFloat;
        BiasRef := Args[First + 2].AsRef;
      end;
      SetAttribute(VM, O, Slot, Args[First].AsRef, Scale, BiasRef);
      Exit;
    end;
    var Ref := GetRef(O, SlotName(Slot));
    if (Slot = 0) or (Slot >= 3) then
    begin
      var OutputRef := Args[First].AsRef;
      if OutputRef <> 0 then
      begin
        var Output := VM.GetObject(OutputRef);
        var Components := 3;
        if (Slot >= 3) and (Ref <> 0) then
          Components := GetInt(VM.GetObject(Ref), 'components');
        if Length(Output.Elements) < Components + 1 then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G scale/bias output length');
        if Ref <> 0 then
        begin
          Output.Elements[0] := TJVMValue.Float(GetFloat(O, SlotName(Slot) + '.scale'));
          for var I := 0 to Components - 1 do
            Output.Elements[I + 1] := TJVMValue.Float(GetFloat(O, SlotName(Slot) + '.bias' + IntToStr(I)));
        end;
      end;
    end;
    Exit(TJVMValue.Ref(Ref));
  end;
  if (C = StripName) and (N = '<init>') then
  begin
    var Strips := VM.GetObject(Args[2].AsRef);
    if Length(Strips.Elements) = 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Empty M3G strips');
    var Total: Int64 := 0;
    for var Value in Strips.Elements do
    begin
      if Value.AsInt < 3 then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G strip shorter than three');
      Inc(Total, Value.AsInt);
    end;
    var Indices: TJVMObject := nil;
    var First := 0;
    if Method.Descriptor = '(I[I)V' then
    begin
      First := Args[1].AsInt;
      if (First < 0) or (Int64(First) + Total > 65535) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G implicit index range');
    end
    else
    begin
      Indices := VM.GetObject(Args[1].AsRef);
      if Total > Length(Indices.Elements) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G indices shorter than strips');
      for var Value in Indices.Elements do
        if (Value.AsInt < 0) or (Value.AsInt > 65535) then
          VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G explicit index range');
    end;
    var Ref := VM.NewArray('[I', Integer(Total));
    O.Fields.AddOrSetValue(P + 'indices', TJVMValue.Ref(Ref));
    var Data := VM.GetObject(Ref);
    for var I := 0 to Integer(Total) - 1 do
      if Indices = nil then
        Data.Elements[I] := TJVMValue.Int(First + I)
      else
        Data.Elements[I] := Indices.Elements[I];
    Ref := VM.NewArray('[I', Length(Strips.Elements));
    O.Fields.AddOrSetValue(P + 'strips', TJVMValue.Ref(Ref));
    Data := VM.GetObject(Ref);
    for var I := 0 to High(Strips.Elements) do
      Data.Elements[I] := Strips.Elements[I];
    O.Fields.AddOrSetValue(P + 'indexCount', TJVMValue.Int(Integer(Total - 2 * Length(Strips.Elements)) * 3));
    Exit;
  end;
  if C = IndexName then
  begin
    var Count := GetInt(O, 'indexCount');
    if N = 'getIndexCount' then
      Exit(TJVMValue.Int(Count));
    if N = 'getIndices' then
    begin
      var Output := VM.GetObject(Args[1].AsRef);
      if Length(Output.Elements) < Count then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G index output length');
      var Indices := VM.GetObject(GetRef(O, 'indices'));
      var Strips := VM.GetObject(GetRef(O, 'strips'));
      var Offset := 0;
      var Position := 0;
      for var Strip in Strips.Elements do
      begin
        for var I := 0 to Strip.AsInt - 3 do
        begin
          // Alternating winding restarts at every strip; degenerates are valid.
          Output.Elements[Position] := Indices.Elements[Offset + I + (I and 1)];
          Output.Elements[Position + 1] := Indices.Elements[Offset + I + 1 - (I and 1)];
          Output.Elements[Position + 2] := Indices.Elements[Offset + I + 2];
          Inc(Position, 3);
        end;
        Inc(Offset, Strip.AsInt);
      end;
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(C + '.' + N + Method.Descriptor);
end;

end.

