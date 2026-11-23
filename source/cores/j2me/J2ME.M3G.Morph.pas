unit J2ME.M3G.Morph;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

type
  TM3GMorph = record
    Enabled: Boolean;
    Attributes: array[0..4] of TArray<Double>; // positions, normals, colors, tex0, tex1
    Color: UInt32;
  end;

procedure InstallM3GMorph(VM: TJVM);

function M3GMorphHandles(const Name: string): Boolean;

function InvokeM3GMorph(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function M3GMorphReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;

procedure M3GSetAnimatedMorphWeights(VM: TJVM; O: TJVMObject; const Values: TArray<Double>);

function M3GPrepareMorph(VM: TJVM; Ref: Integer): TM3GMorph;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.M3G.Mesh;

const
  Name = 'javax/microedition/m3g/MorphingMesh';
  Base = 'javax/microedition/m3g/';
  P = '$m3g.';

const
  Slots: array[0..4] of string = ('positions', 'normals', 'colors', 'tex0', 'tex1');

function R(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsRef;
end;

function I(O: TJVMObject; const Key: string; Fallback: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  Result := Fallback;
  if O.Fields.TryGetValue(P + Key, V) then
    Result := V.AsInt;
end;

procedure PR(O: TJVMObject; const Key: string; Ref: Integer);
begin
  O.Fields.AddOrSetValue(P + Key, TJVMValue.Ref(Ref));
end;

function M3GMorphHandles(const Name: string): Boolean;
begin
  Result := Name = 'javax/microedition/m3g/MorphingMesh';
end;

procedure InstallM3GMorph(VM: TJVM);
begin
  var B := TJavaClassBuilder.Create(Name, Base + 'Mesh');
  try
    for var Arrays in [False, True] do
    begin
      var A := '';
      if Arrays then
        A := '[';
      B.JavaClass.AddNative('<init>', '(Ljavax/microedition/m3g/VertexBuffer;[Ljavax/microedition/m3g/VertexBuffer;' + A + 'Ljavax/microedition/m3g/IndexBuffer;' + A + 'Ljavax/microedition/m3g/Appearance;)V');
    end;
    B.JavaClass.AddNative('getMorphTargetCount', '()I');
    B.JavaClass.AddNative('getMorphTarget', '(I)Ljavax/microedition/m3g/VertexBuffer;');
    B.JavaClass.AddNative('setWeights', '([F)V');
    B.JavaClass.AddNative('getWeights', '([F)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function M3GMorphReferences(VM: TJVM; O: TJVMObject): TArray<Integer>;
begin
  Result := nil;
  var Ref := R(O, 'morphTargets');
  if Ref = 0 then
    Exit;
  var Targets := VM.GetObject(Ref);
  SetLength(Result, Length(Targets.Elements));
  for var K := 0 to High(Result) do
    Result[K] := Targets.Elements[K].AsRef;
end;

function InvokeM3GMorph(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if N = '<init>' then
  begin
    VM.GetObject(Args[1].AsRef);
    var Input := VM.GetObject(Args[2].AsRef);
    var Count := Length(Input.Elements);
    if Count = 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G empty morph targets');
    for var Value in Input.Elements do
      VM.GetObject(Value.AsRef);
    var Descriptor := Method.Descriptor.Replace('[Ljavax/microedition/m3g/VertexBuffer;', '');
    InvokeM3GMesh(VM, VM.LoadClass(Base + 'Mesh').FindMethod('<init>', Descriptor), [Args[0], Args[1], Args[3], Args[4]]);
    var TargetRef := VM.NewArray(Input.ClassName, Count);
    VM.AddRoot(TargetRef);
    try
      var Weights := VM.NewArray('[F', Count);
      var Targets := VM.GetObject(TargetRef);
      for var K := 0 to Count - 1 do
        Targets.Elements[K] := Input.Elements[K];
      PR(O, 'morphTargets', TargetRef);
      PR(O, 'morphWeights', Weights);
    finally
      VM.RemoveRoot(TargetRef);
    end;
    Exit;
  end;
  var Targets := VM.GetObject(R(O, 'morphTargets'));
  var Count := Length(Targets.Elements);
  if N = 'getMorphTargetCount' then
    Exit(TJVMValue.Int(Count));
  if N = 'getMorphTarget' then
  begin
    var Index := Args[1].AsInt;
    if (Index < 0) or (Index >= Count) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException', 'M3G morph target index');
    Exit(Targets.Elements[Index]);
  end;
  if (N = 'setWeights') or (N = 'getWeights') then
  begin
    var Input := VM.GetObject(Args[1].AsRef);
    if Length(Input.Elements) < Count then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'M3G morph weight array length');
    if N = 'setWeights' then
    begin
      // Immutable arrays let duplicate Nodes share storage until either changes
      // its weights, without exposing internal mutable containers to the guest.
      var Ref := VM.NewArray('[F', Count);
      var Data := VM.GetObject(Ref);
      for var K := 0 to Count - 1 do
        Data.Elements[K] := Input.Elements[K];
      PR(O, 'morphWeights', Ref);
    end
    else
    begin
      var Data := VM.GetObject(R(O, 'morphWeights'));
      for var K := 0 to Count - 1 do
        Input.Elements[K] := Data.Elements[K];
    end;
    Exit;
  end;
  raise EJVMUnsupported.Create(Name + '.' + N + Method.Descriptor);
end;

procedure M3GSetAnimatedMorphWeights(VM: TJVM; O: TJVMObject; const Values: TArray<Double>);
begin
  var Targets := VM.GetObject(R(O, 'morphTargets'));
  var ArrayRef := VM.NewArray('[F', Length(Targets.Elements));
  var Data := VM.GetObject(ArrayRef);
  for var K := 0 to Min(Length(Values), Length(Data.Elements)) - 1 do
  begin
    var Value := Values[K];
    if IsNan(Value) then
      Value := 0
    else
      Value := EnsureRange(Value, -3.4028234663852886E38, 3.4028234663852886E38);
    Data.Elements[K] := TJVMValue.Float(Value);
  end;
  // Missing components are zero; surplus components are ignored, per Track.
  PR(O, 'morphWeights', ArrayRef);
end;

function M3GPrepareMorph(VM: TJVM; Ref: Integer): TM3GMorph;

  function Raw(Data: TJVMObject; Index, Slot: Integer): Double;
  begin
    var Value := Data.Elements[Index].AsInt;
    if Slot = 2 then
      Value := Value and 255;
    Result := Value;
  end;

  function Channel(Value: Double): UInt32;
  begin
    if IsNan(Value) or (Value < 0) then
      Value := 0
    else if Value > 255 then
      Value := 255;
    Result := UInt32(Trunc(Value + 0.5));
  end;

begin
  Result := Default(TM3GMorph);
  if Ref = 0 then
    Exit;
  var O := VM.GetObject(Ref);
  var BaseBuffer := VM.GetObject(R(O, 'vertices'));
  var Targets := VM.GetObject(R(O, 'morphTargets'));
  var Weights := VM.GetObject(R(O, 'morphWeights'));
  Result.Enabled := True;
  var Buffers: TArray<TJVMObject>;
  SetLength(Buffers, Length(Targets.Elements));
  for var K := 0 to High(Buffers) do
    Buffers[K] := VM.GetObject(Targets.Elements[K].AsRef);
  for var Slot := 0 to 4 do
  begin
    if VM.StopRequested then
      raise EJVMError.Create('M3G morph preparation cancelled');
    var FirstRef := R(Buffers[0], Slots[Slot]);
    var BaseRef := R(BaseBuffer, Slots[Slot]);
    var First: TJVMObject := nil;
    var BaseArray: TJVMObject := nil;
    if FirstRef <> 0 then
    begin
      First := VM.GetObject(FirstRef);
      if BaseRef = 0 then
        VM.RaiseJava('java/lang/IllegalStateException', 'M3G morph target is not a base subset');
      BaseArray := VM.GetObject(BaseRef);
    end;
    var Arrays: TArray<TJVMObject>;
    SetLength(Arrays, Length(Buffers));
    for var K := 0 to High(Buffers) do
    begin
      if (K and 255) = 0 then
        if VM.StopRequested then
          raise EJVMError.Create('M3G morph validation cancelled');
      var ArrayRef := R(Buffers[K], Slots[Slot]);
      if (ArrayRef = 0) <> (FirstRef = 0) then
        VM.RaiseJava('java/lang/IllegalStateException', 'M3G morph target attribute mismatch');
      if ArrayRef = 0 then
        Continue;
      var ArrayObject := VM.GetObject(ArrayRef);
      for var Key in ['vertices', 'components', 'size'] do
        if (I(ArrayObject, Key) <> I(First, Key)) or (I(BaseArray, Key) <> I(First, Key)) then
          VM.RaiseJava('java/lang/IllegalStateException', 'M3G morph target dimensions/type mismatch');
      Arrays[K] := VM.GetObject(R(ArrayObject, 'data'));
    end;
    if FirstRef = 0 then
      Continue; // Copy this base-only attribute without morphing.
    var BaseData := VM.GetObject(R(BaseArray, 'data'));
    SetLength(Result.Attributes[Slot], Length(BaseData.Elements));
    for var At := 0 to High(BaseData.Elements) do
    begin
      if (At and 255) = 0 then
        if VM.StopRequested then
          raise EJVMError.Create('M3G morph interpolation cancelled');
      var BaseValue := Raw(BaseData, At, Slot);
      var Delta: Double := 0;
      for var K := 0 to High(Arrays) do
      begin
        if (K and 255) = 0 then
          if VM.StopRequested then
            raise EJVMError.Create('M3G morph interpolation cancelled');
        Delta := Delta + Weights.Elements[K].AsFloat * (Raw(Arrays[K], At, Slot) - BaseValue);
      end;
      Result.Attributes[Slot][At] := BaseValue + Delta;
    end;
  end;
  var BaseColor := UInt32(I(BaseBuffer, 'color', -1));
  Result.Color := 0;
  for var Component := 0 to 3 do
  begin
    var Shift := (3 - Component) * 8;
    var B: Double := (BaseColor shr Shift) and 255;
    var Delta: Double := 0;
    for var K := 0 to High(Buffers) do
      Delta := Delta + Weights.Elements[K].AsFloat * (Double((UInt32(I(Buffers[K], 'color', -1)) shr Shift) and 255) - B);
    Result.Color := Result.Color or (Channel(B + Delta) shl Shift);
  end;
end;

end.

