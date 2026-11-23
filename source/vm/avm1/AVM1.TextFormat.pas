unit AVM1.TextFormat;

interface

uses
  System.SysUtils, AVM1.Runtime;

const
  AVMFormatNames: array[0..18] of string = ('font', 'size', 'color', 'url', 'target',
    'bold', 'italic', 'underline', 'align', 'leftMargin', 'rightMargin', 'indent',
    'leading', 'blockIndent', 'tabStops', 'bullet', 'display', 'kerning', 'letterSpacing');

procedure RegisterAVMTextFormat(VM: TAVM1; out PrototypeObject: TAVMObject);

function AVMTextFormatCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;

function AVMNewTextFormat(VM: TAVM1; Data: TAVMTextFormatData): TAVMObject;

procedure AVMMixTextFormat(Destination, Source: TAVMTextFormatData);

procedure AVMIntersectTextFormat(Destination, Source: TAVMTextFormatData);

implementation

uses
  System.Math, AVM1.Coercion, AVM1.Names, SWF.Reader;

function RoundToEven(Value: Double): Integer;
var
  Base: Int64;
  Fraction: Double;
begin
  if IsNan(Value) or IsInfinite(Value) or (Value < -2147483648.0) or
    (Value >= 2147483647.5) then
    Exit(Low(Integer));
  Base := Floor(Value);
  Fraction := Value - Base;
  if (Fraction > 0.5) or ((Fraction = 0.5) and Odd(Base)) then
    Inc(Base);
  Result := Integer(Base);
end;

procedure SetFormatValue(VM: TAVM1; Data: TAVMTextFormatData; Index: Integer; const Value: TAVMValue; InConstructor: Boolean = False);
var
  Text: string;
  Number: Double;
  Bits: Integer;
  Unsigned: Cardinal;
  Count, I: Integer;
  Tabs: TArray<Double>;
begin
  if Index = 8 then
  begin
    if Value.Kind in [avNull, avUndefined] then
      Exit;
    Text := AVMLowerName(VM.CoerceString(Value));
    if (Text = 'left') or (Text = 'center') or (Text = 'right') or (Text = 'justify') then
      Data.Values[Index] := TAVMValue.Str(Text);
    Exit;
  end;
  if Index = 16 then
  begin
    Text := 'block';
    if not (Value.Kind in [avNull, avUndefined]) then
      Text := VM.CoerceString(Value);
    if (Text <> 'inline') and (Text <> 'none') then
      Text := 'block';
    Data.Values[Index] := TAVMValue.Str(Text);
    Exit;
  end;
  if Index = 14 then
  begin
    if Value.Obj = nil then
    begin
      Data.Values[Index] := TAVMValue.Ref(nil);
      Data.TabStops := nil;
      Exit;
    end;
    Count := AVMToInt32(VM.CoerceNumber(VM.GetData(Value.Obj, 'length')));
    if Count < 0 then
      Count := 0;
    if Count > 65536 then
      raise ESWFError.Create('AVM1 TextFormat tab stop limit');
    VM.ChargeWork(Count);
    SetLength(Tabs, Count);
    for I := 0 to Count - 1 do
      Tabs[I] := RoundToEven(VM.CoerceNumber(VM.GetData(Value.Obj, IntToStr(I))));
    Data.TabStops := Tabs;
    Data.Values[Index] := TAVMValue.Bool(True);
    Exit;
  end;
  if Value.Kind in [avNull, avUndefined] then
  begin
    Data.Values[Index] := TAVMValue.Ref(nil);
    Exit;
  end;
  case Index of
    0, 3, 4:
      begin
        Text := VM.CoerceString(Value);
        if Index = 0 then
          Text := Copy(Text, 1, 64);
        Data.Values[Index] := TAVMValue.Str(Text);
      end;
    2:
      begin
        Bits := AVMToInt32(VM.CoerceNumber(Value));
        Move(Bits, Unsigned, SizeOf(Unsigned));
        Data.Values[Index] := TAVMValue.Num(Unsigned);
      end;
    5, 6, 7, 15, 17:
      Data.Values[Index] := TAVMValue.Bool(Value.AsBoolean(VM.SWFVersion));
    1, 9, 10, 11, 12, 13:
      begin
        Number := VM.CoerceNumber(Value);
        if InConstructor then
          Bits := AVMToInt32(Number)
        else if VM.SWFVersion < 8 then
        begin
          Bits := AVMToInt32(Number);
          if (Index <> 1) and (Bits < 0) then
            Bits := 0;
        end
        else
        begin
          if (Index in [9, 10]) and (IsNan(Number) or (Number < 0)) then
            Number := 0;
          Bits := RoundToEven(Number);
        end;
        Data.Values[Index] := TAVMValue.Num(Bits);
      end;
    18:
      Data.Values[Index] := TAVMValue.Num(VM.CoerceNumber(Value));
  end;
end;

procedure RegisterAVMTextFormat(VM: TAVM1; out PrototypeObject: TAVMObject);
var
  ConstructorValue: TAVMValue;
  I: Integer;
begin
  ConstructorValue := VM.NativeFunction('TextFormat');
  PrototypeObject := VM.NewObject;
  VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(PrototypeObject));
  ConstructorValue.Obj.Attributes.AddOrSetValue('prototype', 3);
  VM.PutData(PrototypeObject, 'constructor', ConstructorValue);
  PrototypeObject.Attributes.AddOrSetValue('constructor', 1);
  for I := 0 to High(AVMFormatNames) do
    VM.AddProperty(PrototypeObject, AVMFormatNames[I],
      VM.NativeFunction('TextFormat.get.' + IntToStr(I)).Obj,
      VM.NativeFunction('TextFormat.set.' + IntToStr(I)).Obj);
  VM.PutData(PrototypeObject, 'getTextExtent', VM.NativeFunction('TextFormat.getTextExtent'));
  PrototypeObject.Attributes.AddOrSetValue('getTextExtent', 3);
  VM.PutData(VM.Global, 'TextFormat', ConstructorValue);
end;

function AVMNewTextFormat(VM: TAVM1; Data: TAVMTextFormatData): TAVMObject;
var
  ConstructorValue: TAVMValue;
begin
  Result := VM.NewObject('TextFormat');
  ConstructorValue := VM.Get(VM.Global, 'TextFormat');
  VM.PutData(Result, '__proto__', VM.GetData(ConstructorValue.Obj, 'prototype'));
  Result.TextFormatData := Data.Clone;
end;

procedure AVMMixTextFormat(Destination, Source: TAVMTextFormatData);
var
  I: Integer;
begin
  for I := 0 to High(Source.Values) do
    if Source.Values[I].Kind <> avNull then
    begin
      Destination.Values[I] := Source.Values[I];
      if I = 14 then
        Destination.TabStops := Copy(Source.TabStops);
    end;
end;

procedure AVMIntersectTextFormat(Destination, Source: TAVMTextFormatData);
var
  I, J: Integer;
  Equal: Boolean;
begin
  for I := 0 to High(Source.Values) do
  begin
    Equal := Destination.Values[I].Kind = Source.Values[I].Kind;
    if Equal then
      case Source.Values[I].Kind of
        avNumber, avBoolean:
          Equal := Destination.Values[I].Number = Source.Values[I].Number;
        avString:
          Equal := Destination.Values[I].Text = Source.Values[I].Text;
      end;
    if Equal and (I = 14) then
    begin
      Equal := Length(Destination.TabStops) = Length(Source.TabStops);
      if Equal then
        for J := 0 to High(Source.TabStops) do
          if Destination.TabStops[J] <> Source.TabStops[J] then
          begin
            Equal := False;
            Break;
          end;
    end;
    if not Equal then
    begin
      Destination.Values[I] := TAVMValue.Ref(nil);
      if I = 14 then
        Destination.TabStops := nil;
    end;
  end;
end;

function AVMTextFormatCall(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
const
  ArgumentFields: array[0..12] of Integer = (0, 1, 2, 5, 6, 7, 3, 4, 8, 9, 10, 11, 12);
var
  Data: TAVMTextFormatData;
  I, Index: Integer;
  Value: TAVMValue;
  Tabs: TArray<TAVMValue>;
begin
  Result := Default(TAVMValue);
  if Name = 'TextFormat' then
  begin
    if not ConstructorCall or (O = nil) then
      Exit;
    Data := TAVMTextFormatData.Create;
    try
      for I := 0 to High(ArgumentFields) do
      begin
        Value := Default(TAVMValue);
        if I < Length(Args) then
          Value := Args[I];
        SetFormatValue(VM, Data, ArgumentFields[I], Value, True);
      end;
      O.TextFormatData.Free;
      O.TextFormatData := Data;
      Data := nil;
    finally
      Data.Free;
    end;
    Exit(TAVMValue.Ref(O));
  end;
  if (O = nil) or (O.TextFormatData = nil) then
    Exit;
  if Name = 'TextFormat.getTextExtent' then
    raise ESWFError.Create('TextFormat.getTextExtent layout metrics are not implemented');
  Data := O.TextFormatData;
  if Name.StartsWith('TextFormat.get.') then
  begin
    Index := StrToInt(Copy(Name, 16, MaxInt));
    Result := Data.Values[Index];
    if (Index = 14) and (Result.Kind <> avNull) then
    begin
      SetLength(Tabs, Length(Data.TabStops));
      for I := 0 to High(Tabs) do
        Tabs[I] := TAVMValue.Num(Data.TabStops[I]);
      Result := TAVMValue.Ref(VM.CreateArray(Tabs));
    end;
  end
  else if Name.StartsWith('TextFormat.set.') then
  begin
    Index := StrToInt(Copy(Name, 16, MaxInt));
    Value := Default(TAVMValue);
    if Length(Args) > 0 then
      Value := Args[0];
    SetFormatValue(VM, Data, Index, Value);
  end;
end;

end.

