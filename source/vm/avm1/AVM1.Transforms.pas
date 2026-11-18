unit AVM1.Transforms;

interface

uses
  AVM1.Runtime, SWF.Reader;

procedure RegisterAVMTransform(VM: TAVM1; out PrototypeObject: TAVMObject);

function AVMTransformCall(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>; Index: Integer): TAVMValue;

function AVMNewGeometry(VM: TAVM1; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;

function AVMColorTransform(const Data: IAVMColorData): TSWFColorTransform;

implementation

uses
  System.SysUtils, System.Math;

function AVMNewGeometry(VM: TAVM1; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
var
  NamespaceValue, ConstructorValue: TAVMValue;
begin
  NamespaceValue := VM.Get(VM.Global, 'flash');
  NamespaceValue := VM.Get(NamespaceValue.Obj, 'geom');
  ConstructorValue := VM.Get(NamespaceValue.Obj, Name);
  Result := VM.Construct(ConstructorValue, Args);
end;

function Saturate16(Value: Double): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value <= -32768 then
    Exit(-32768);
  if Value >= 32767 then
    Exit(32767);
  Result := Trunc(Value);
end;

function MultiplierBits(Value: Double): Integer;
begin
  if IsNan(Value) then
    Exit(0);
  if Value <= -128 then
    Exit(-32768);
  if Value >= 127.99609375 then
    Exit(32767);
  Result := Trunc(Value * 256);
end;

function AVMColorTransform(const Data: IAVMColorData): TSWFColorTransform;
var
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    Result.Mult[I] := MultiplierBits(Data[I]) / 256.0;
    Result.Add[I] := Saturate16(Data[4 + I]);
  end;
end;

function AVMTransformCall(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>; Index: Integer): TAVMValue;
const
  MatrixNames: array[0..5] of string = ('a', 'b', 'c', 'd', 'tx', 'ty');
var
  Target, Other, Parent: TAVMObject;
  Value: TAVMValue;
  Matrix, MatrixParent: TSWFMatrix;
  Color, ParentColor: TSWFColorTransform;
  Bounds: TSWFRect;
  Numbers: array[0..5] of Double;
  Data: IAVMColorData;
  I, Depth: Integer;
  Path: string;
begin
  Result := Default(TAVMValue);
  if O = nil then
    Exit;
  if Index = 0 then
  begin
    if (Length(Args) <> 1) or (Args[0].Kind <> avObject) then
      Exit;
    Target := VM.BindTransformReference(Args[0].Obj, Path);
    O.TransformTarget := Target;
    O.TransformPath := Path;
    O.IsTransform := True;
    O.ColorData := nil;
    O.IsBoxed := False;
    O.IsDate := False;
    O.PrimitiveValue := Default(TAVMValue);
    Exit(TAVMValue.Ref(O));
  end;
  if not O.IsTransform then
    Exit;
  Target := VM.ResolveTransformReference(O.TransformTarget, O.TransformPath);
  if Target = nil then
    Exit;
  case Index of
    101, 103:
      begin
        if not VM.ReadDisplayMatrix(Target, Matrix) then
          Exit;
        if Index = 103 then
        begin
          Parent := VM.DisplayParent(Target);
          Depth := 0;
          while Parent <> nil do
          begin
            Inc(Depth);
            if Depth > 128 then
              raise ESWFError.Create('Flash transform parent limit');
            if not VM.ReadDisplayMatrix(Parent, MatrixParent) then
              Break;
            Matrix := Matrix.ThenBy(MatrixParent);
            Parent := VM.DisplayParent(Parent);
          end;
        end;
        Exit(AVMNewGeometry(VM, 'Matrix', [TAVMValue.Num(Matrix.A), TAVMValue.Num(Matrix.B),
              TAVMValue.Num(Matrix.C), TAVMValue.Num(Matrix.D), TAVMValue.Num(Matrix.TX / 20), TAVMValue.Num(Matrix.TY / 20)]));
      end;
    102:
      begin
        if Length(Args) <> 1 then
          Exit;
        Other := VM.Box(Args[0]);
        for I := 0 to 5 do
          if not VM.HasOwnProperty(Other, MatrixNames[I]) then
            Exit;
        for I := 0 to 5 do
        begin
          Value := VM.Get(Other, MatrixNames[I]);
          Numbers[I] := VM.CoerceNumber(Value);
        end;
        Matrix.A := SWFFloat32(Numbers[0]);
        Matrix.B := SWFFloat32(Numbers[1]);
        Matrix.C := SWFFloat32(Numbers[2]);
        Matrix.D := SWFFloat32(Numbers[3]);
        Matrix.TX := SWFTwipsFromPixels(Numbers[4]);
        Matrix.TY := SWFTwipsFromPixels(Numbers[5]);
        VM.WriteDisplayMatrix(Target, Matrix);
        VM.MarkColorTarget(Target);
      end;
    105, 107:
      begin
        if not VM.ReadColorTransform(Target, Color) then
          Exit;
        if Index = 107 then
        begin
          Parent := VM.DisplayParent(Target);
          Depth := 0;
          while Parent <> nil do
          begin
            Inc(Depth);
            if Depth > 128 then
              raise ESWFError.Create('Flash transform parent limit');
            if not VM.ReadColorTransform(Parent, ParentColor) then
              Break;
            Color := Color.ThenBy(ParentColor);
            Parent := VM.DisplayParent(Parent);
          end;
        end;
        Exit(AVMNewGeometry(VM, 'ColorTransform', [TAVMValue.Num(Color.Mult[0]), TAVMValue.Num(Color.Mult[1]),
              TAVMValue.Num(Color.Mult[2]), TAVMValue.Num(Color.Mult[3]), TAVMValue.Num(Color.Add[0]),
              TAVMValue.Num(Color.Add[1]), TAVMValue.Num(Color.Add[2]), TAVMValue.Num(Color.Add[3])]));
      end;
    106:
      begin
        if (Length(Args) <> 1) or (Args[0].Obj = nil) then
          Exit;
        Data := Args[0].Obj.ColorData;
        if Data = nil then
          Exit;
        Color := AVMColorTransform(Data);
        VM.WriteColorTransform(Target, Color);
        VM.MarkColorTarget(Target);
      end;
    109:
      begin
        if not VM.DisplayBounds(Target, Bounds) then
          Bounds := Default(TSWFRect);
        Exit(AVMNewGeometry(VM, 'Rectangle', [TAVMValue.Num(Bounds.Left / 20), TAVMValue.Num(Bounds.Top / 20),
              TAVMValue.Num((Int64(Bounds.Right) - Bounds.Left) / 20), TAVMValue.Num((Int64(Bounds.Bottom) - Bounds.Top) / 20)]));
      end;
  end;
end;

procedure RegisterAVMTransform(VM: TAVM1; out PrototypeObject: TAVMObject);
const
  Names: array[0..4] of string = ('matrix', 'concatenatedMatrix', 'colorTransform', 'concatenatedColorTransform', 'pixelBounds');
  Getters: array[0..4] of Integer = (101, 103, 105, 107, 109);
  Setters: array[0..4] of Integer = (102, -1, 106, -1, -1);
var
  NamespaceValue, ConstructorValue, GetterValue, SetterValue: TAVMValue;
  I: Integer;
begin
  NamespaceValue := VM.Get(VM.Global, 'flash');
  NamespaceValue := VM.Get(NamespaceValue.Obj, 'geom');
  ConstructorValue := VM.NativeFunction('Geom.Transform');
  PrototypeObject := VM.NewObject;
  VM.Put(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  VM.Put(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
  VM.Put(NamespaceValue.Obj, 'Transform', ConstructorValue);
  for I := 0 to 4 do
  begin
    GetterValue := VM.NativeFunction('Transform.' + IntToStr(Getters[I]));
    SetterValue := Default(TAVMValue);
    if Setters[I] >= 0 then
      SetterValue := VM.NativeFunction('Transform.' + IntToStr(Setters[I]));
    VM.AddProperty(PrototypeObject, Names[I], GetterValue.Obj, SetterValue.Obj);
    PrototypeObject.Attributes.AddOrSetValue(Names[I], $1000);
  end;
end;

end.

