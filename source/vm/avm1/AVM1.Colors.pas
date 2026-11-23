unit AVM1.Colors;

interface

uses
  AVM1.Runtime;

procedure RegisterAVMColor(VM: TAVM1; out PrototypeObject: TAVMObject);

function AVMColorCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;

implementation

uses
  System.SysUtils, AVM1.Coercion, AVM1.Numeric, SWF.Reader;

procedure RegisterAVMColor(VM: TAVM1; out PrototypeObject: TAVMObject);
var
  ConstructorValue: TAVMValue;
  Name: string;
begin
  ConstructorValue := VM.NativeFunction('Color');
  VM.Put(VM.Global, 'Color', ConstructorValue);
  PrototypeObject := VM.NewObject;
  VM.Put(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  VM.Put(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 3);
  for Name in ['setRGB', 'setTransform', 'getRGB', 'getTransform'] do
  begin
    VM.Put(PrototypeObject, Name, VM.NativeFunction('Color.' + Name));
    PrototypeObject.Attributes.AddOrSetValue(Name, 7);
  end;
end;

function Wrapping16(Value: Double): Integer;
begin
  Result := AVMToInt32(Value) and $FFFF;
  if Result > 32767 then
    Dec(Result, 65536);
end;

function AVMColorCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
const
  MultNames: array[0..3] of string = ('ra', 'ga', 'ba', 'aa');
  AddNames: array[0..3] of string = ('rb', 'gb', 'bb', 'ab');
var
  TargetValue: TAVMValue;
  Target, TransformObject, Output: TAVMObject;
  Transform: TSWFColorTransform;
  RGB: Cardinal;
  I: Integer;
  NumberValue: Double;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

begin
  Result := Default(TAVMValue);
  if O = nil then
    Exit;
  if Name = 'Color' then
  begin
    { define_value replaces an existing slot, bypassing accessors/watchers. }
    if O.SuperThis <> nil then
      Exit;
    if O.Accessors <> nil then
      O.Accessors.Remove('target');
    O.StoreData('target', Arg(0));
    O.Attributes.AddOrSetValue('target', 7);
    Exit;
  end;
  TargetValue := VM.Get(O, 'target');
  if TargetValue.Kind = avUndefined then
    Exit;
  Target := VM.ColorTarget(TargetValue);
  if Target = nil then
    Exit;
  if (Name = 'Color.setRGB') or (Name = 'Color.setTransform') then
    VM.MarkColorTarget(Target);
  if Name = 'Color.setRGB' then
  begin
    RGB := Cardinal(AVMToInt32(VM.CoerceNumber(Arg(0))));
    if not VM.ReadColorTransform(Target, Transform) then
      Exit;
    for I := 0 to 2 do
    begin
      Transform.Mult[I] := 0;
      Transform.Add[I] := (RGB shr ((2 - I) * 8)) and 255;
    end;
    VM.WriteColorTransform(Target, Transform);
    Exit;
  end;
  if not VM.ReadColorTransform(Target, Transform) then
    Exit;
  if Name = 'Color.getRGB' then
    Exit(TAVMValue.Num(Integer((Cardinal(Transform.Add[0]) shl 16) or
          (Cardinal(Transform.Add[1]) shl 8) or Cardinal(Transform.Add[2]))));
  if Name = 'Color.getTransform' then
  begin
    Output := VM.NewObject;
    for I := 0 to 3 do
      VM.Put(Output, MultNames[I], TAVMValue.Num(Transform.Mult[I] * 100));
    for I := 0 to 3 do
      VM.Put(Output, AddNames[I], TAVMValue.Num(Transform.Add[I]));
    Exit(TAVMValue.Ref(Output));
  end;
  if Name = 'Color.setTransform' then
  begin
    TransformObject := VM.Box(Arg(0));
    for I := 0 to 3 do
      if VM.HasOwnProperty(TransformObject, MultNames[I]) then
      begin
        NumberValue := VM.CoerceNumber(VM.Get(TransformObject, MultNames[I]));
        NumberValue := AVMBinaryNumber($0D, AVMBinaryNumber($0C, NumberValue, 256), 100);
        Transform.Mult[I] := Wrapping16(NumberValue) / 256.0;
      end;
    for I := 0 to 3 do
      if VM.HasOwnProperty(TransformObject, AddNames[I]) then
        Transform.Add[I] := Wrapping16(VM.CoerceNumber(VM.Get(TransformObject, AddNames[I])));
    VM.WriteColorTransform(Target, Transform);
    Exit;
  end;
  raise ESWFError.Create('Unsupported AVM1 Color method ' + Name);
end;

end.

