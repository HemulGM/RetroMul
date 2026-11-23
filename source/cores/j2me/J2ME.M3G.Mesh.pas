unit J2ME.M3G.Mesh;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallM3GMesh(VM: TJVM);

function M3GMeshHandles(const Name: string): Boolean;

function InvokeM3GMesh(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GMeshReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

implementation

uses
  System.SysUtils, Java.Classes, J2ME.M3G.Geometry;

const
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';
  MeshName = Base + 'Mesh';
  AppearanceName = Base + 'Appearance';
  MaterialName = Base + 'Material';
  VD = 'Ljavax/microedition/m3g/VertexBuffer;';
  ID = 'Ljavax/microedition/m3g/IndexBuffer;';
  AD = 'Ljavax/microedition/m3g/Appearance;';

const
  ColorTargets: array[0..3] of Integer = (1024, 2048, 4096, 8192);

function GetRef(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsRef;
end;

function GetInt(O: TJVMObject; const Name: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Name, V) then
    Result := V.AsInt;
end;

procedure PutRef(O: TJVMObject; const Name: string; Ref: Integer);
begin
  O.Fields.AddOrSetValue(P + Name, TJVMValue.Ref(Ref));
end;

function M3GMeshHandles(const Name: string): Boolean;
begin
  Result := (Name = MeshName) or (Name = AppearanceName) or (Name = MaterialName);
end;

function M3GMeshReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

  procedure Add(Ref: Integer);
  begin
    if Ref = 0 then
      Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Ref;
  end;

begin
  Result := nil;
  if VM.IsAssignable(O.ClassName, MeshName) then
  begin
    Add(GetRef(O, 'vertices'));
    for var I := 0 to GetInt(O, 'submeshCount') - 1 do
    begin
      Add(GetRef(O, 'submesh' + IntToStr(I)));
      Add(GetRef(O, 'appearance' + IntToStr(I)));
    end;
  end
  else if VM.IsAssignable(O.ClassName, AppearanceName) then
  begin
    for var Name in ['Material', 'Fog', 'CompositingMode', 'PolygonMode'] do
      Add(GetRef(O, Name));
    for var I := 0 to M3GTextureUnits - 1 do
      Add(GetRef(O, 'texture' + IntToStr(I)));
  end;
end;

procedure InstallM3GMesh(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(MeshName, Base + 'Node');
  try
    B.JavaClass.AddNative('<init>', '(' + VD + ID + AD + ')V');
    B.JavaClass.AddNative('<init>', '(' + VD + '[' + ID + '[' + AD + ')V');
    B.JavaClass.AddNative('getVertexBuffer', '()' + VD);
    B.JavaClass.AddNative('getSubmeshCount', '()I');
    B.JavaClass.AddNative('getIndexBuffer', '(I)' + ID);
    B.JavaClass.AddNative('getAppearance', '(I)' + AD);
    B.JavaClass.AddNative('setAppearance', '(I' + AD + ')V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(AppearanceName, Base + 'Object3D');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('getLayer', '()I');
    B.JavaClass.AddNative('setLayer', '(I)V');
    for var N in ['Material', 'Fog', 'CompositingMode', 'PolygonMode'] do
    begin
      var Descriptor := 'Ljavax/microedition/m3g/' + N + ';';
      B.JavaClass.AddNative('get' + N, '()' + Descriptor);
      B.JavaClass.AddNative('set' + N, '(' + Descriptor + ')V');
    end;
    B.JavaClass.AddNative('getTexture', '(I)Ljavax/microedition/m3g/Texture2D;');
    B.JavaClass.AddNative('setTexture', '(ILjavax/microedition/m3g/Texture2D;)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(MaterialName, Base + 'Object3D');
  try
    var Mask := 1024;
    for var N in ['AMBIENT', 'DIFFUSE', 'EMISSIVE', 'SPECULAR'] do
    begin
      B.Field(N, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Mask);
      Mask := Mask shl 1;
    end;
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('getColor', '(I)I');
    B.JavaClass.AddNative('setColor', '(II)V');
    B.JavaClass.AddNative('getShininess', '()F');
    B.JavaClass.AddNative('setShininess', '(F)V');
    B.JavaClass.AddNative('isVertexColorTrackingEnabled', '()Z');
    B.JavaClass.AddNative('setVertexColorTrackingEnable', '(Z)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeM3GMesh(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  var C := Method.Owner.Name;
  if C = MeshName then
  begin
    if N = '<init>' then
    begin
      var Vertices := Args[1].AsRef;
      VM.GetObject(Vertices);
      var Submeshes, Appearances: TArray<Integer>;
      if Method.Descriptor = '(' + VD + ID + AD + ')V' then
      begin
        var Submesh := Args[2].AsRef;
        VM.GetObject(Submesh);
        Submeshes := [Submesh];
        Appearances := [Args[3].AsRef];
      end
      else
      begin
        var Input := VM.GetObject(Args[2].AsRef);
        var Count := Length(Input.Elements);
        if Count = 0 then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'Empty M3G submeshes');
        SetLength(Submeshes, Count);
        SetLength(Appearances, Count);
        for var I := 0 to Count - 1 do
        begin
          Submeshes[I] := Input.Elements[I].AsRef;
          VM.GetObject(Submeshes[I]);
        end;
        if Args[3].AsRef <> 0 then
        begin
          Input := VM.GetObject(Args[3].AsRef);
          if Length(Input.Elements) < Count then
            VM.RaiseJava('java/lang/IllegalArgumentException', 'Short M3G appearances');
          for var I := 0 to Count - 1 do
            Appearances[I] := Input.Elements[I].AsRef;
        end;
      end;
      // Copy the input containers, retaining their Object3D references. Keeping
      // slots as fields also gives duplicate() independent mutable slot state.
      PutRef(O, 'vertices', Vertices);
      O.Fields.AddOrSetValue(P + 'submeshCount', TJVMValue.Int(Length(Submeshes)));
      for var I := 0 to High(Submeshes) do
      begin
        PutRef(O, 'submesh' + IntToStr(I), Submeshes[I]);
        PutRef(O, 'appearance' + IntToStr(I), Appearances[I]);
      end;
      Exit;
    end;
    if N = 'getVertexBuffer' then
      Exit(TJVMValue.Ref(GetRef(O, 'vertices')));
    var Count := GetInt(O, 'submeshCount');
    if N = 'getSubmeshCount' then
      Exit(TJVMValue.Int(Count));
    var Index := Args[1].AsInt;
    if (Index < 0) or (Index >= Count) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G submesh index');
    var Key := 'appearance' + IntToStr(Index);
    if N = 'getAppearance' then
      Exit(TJVMValue.Ref(GetRef(O, Key)));
    if N = 'getIndexBuffer' then
      Exit(TJVMValue.Ref(GetRef(O, 'submesh' + IntToStr(Index))));
    if N = 'setAppearance' then
    begin
      PutRef(O, Key, Args[2].AsRef);
      Exit;
    end;
  end;
  if C = AppearanceName then
  begin
    if N = '<init>' then
      Exit;
    if N = 'getLayer' then
      Exit(TJVMValue.Int(GetInt(O, 'layer')));
    if N = 'setLayer' then
    begin
      var V := Args[1].AsInt;
      if (V < -63) or (V > 63) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G appearance layer');
      O.Fields.AddOrSetValue(P + 'layer', Args[1]);
      Exit;
    end;
    var Key := Copy(N, 4, MaxInt);
    var First := 1;
    if Key = 'Texture' then
    begin
      var Index := Args[1].AsInt;
      if (Index < 0) or (Index >= M3GTextureUnits) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G texture unit');
      Key := 'texture' + IntToStr(Index);
      First := 2;
    end;
    if N.StartsWith('get') then
      Exit(TJVMValue.Ref(GetRef(O, Key)));
    if N.StartsWith('set') then
    begin
      PutRef(O, Key, Args[First].AsRef);
      Exit;
    end;
  end;
  if C = MaterialName then
  begin
    if N = '<init>' then
      Exit;
    if (N = 'getColor') or (N = 'setColor') then
    begin
      var Mask := Args[1].AsInt;
      if (Mask = 0) or ((Mask and not $3C00) <> 0) or ((N = 'getColor') and ((Mask and (Mask - 1)) <> 0)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G material color target');
      for var Bit in ColorTargets do
        if (Mask and Bit) <> 0 then
        begin
          var Key := 'color' + IntToStr(Bit);
          if N = 'getColor' then
          begin
            var Fallback := 0;
            if Bit = 1024 then
              Fallback := $333333
            else if Bit = 2048 then
              Fallback := Integer($FFCCCCCC);
            Exit(TJVMValue.Int(GetInt(O, Key, Fallback)));
          end;
          var Color := Args[2].AsInt;
          if Bit <> 2048 then
            Color := Color and $FFFFFF;
          O.Fields.AddOrSetValue(P + Key, TJVMValue.Int(Color));
        end;
      Exit;
    end;
    if N = 'getShininess' then
    begin
      var Value: TJVMValue;
      if O.Fields.TryGetValue(P + 'shininess', Value) then
        Result := Value
      else
        Result := TJVMValue.Float(0);
      Exit;
    end;
    if N = 'setShininess' then
    begin
      var V := Args[1].AsFloat;
      if not ((V >= 0) and (V <= 128)) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G shininess range');
      O.Fields.AddOrSetValue(P + 'shininess', Args[1]);
      Exit;
    end;
    if N = 'isVertexColorTrackingEnabled' then
      Exit(TJVMValue.Int(GetInt(O, 'tracking')));
    if N = 'setVertexColorTrackingEnable' then
    begin
      O.Fields.AddOrSetValue(P + 'tracking', Args[1]);
      Exit;
    end;
  end;
  raise EJVMUnsupported.Create(C + '.' + N + Method.Descriptor);
end;

end.

