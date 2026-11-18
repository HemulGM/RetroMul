unit AVM1.Arrays;

interface

uses
  System.SysUtils, AVM1.Runtime;

function AVMNewArray(VM: TAVM1; const Values: TArray<TAVMValue>): TAVMObject;

function AVMArrayCall(VM: TAVM1; const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;

function AVMArrayIndex(const Name: string; out Index: Integer): Boolean;

implementation

uses
  System.Math, System.Generics.Collections, SWF.Reader, AVM1.Coercion,
  AVM1.Names;

type
  TSortElement = record
    Index: Integer;
    Value: TAVMValue;
  end;

  TSortRange = record
    Low, High: Integer;
  end;

  TSortField = record
    Name: string;
    Options: Integer;
  end;

function AVMArrayIndex(const Name: string; out Index: Integer): Boolean;
var
  I: Integer;
  Negative: Boolean;
  Value: Cardinal;
  Digit: Integer;
begin
  Index := 0;
  Result := False;
  I := 1;
  while (I <= Length(Name)) and ((Name[I] = ' ') or (Ord(Name[I]) in [9..13])) do
    Inc(I);
  Negative := False;
  if (I <= Length(Name)) and CharInSet(Name[I], ['+', '-']) then
  begin
    Negative := Name[I] = '-';
    Inc(I);
  end;
  if I > Length(Name) then
    Exit;
  Value := 0;
  while I <= Length(Name) do
  begin
    Digit := Ord(Name[I]) - Ord('0');
    if (Digit < 0) or (Digit > 9) then
      Exit;
    Value := Cardinal((UInt64(Value) * 10 + Cardinal(Digit)) and $FFFFFFFF);
    Inc(I);
  end;
  if Negative then
    Value := Cardinal((UInt64($100000000) - Value) and $FFFFFFFF);
  Move(Value, Index, SizeOf(Index));
  Result := True;
end;

function ArrayLength(VM: TAVM1; O: TAVMObject): Integer;
begin
  if (O = nil) or (O.SuperThis <> nil) then
    Exit(0);
  Result := AVMToInt32(VM.CoerceNumber(VM.GetData(O, 'length')));
end;

procedure CheckIterationLength(Length: Integer);
begin
  if Length > 65536 then
    raise ESWFError.Create('AVM1 array iteration limit');
end;

function Element(VM: TAVM1; O: TAVMObject; Index: Integer): TAVMValue;
begin
  Result := Default(TAVMValue);
  if (O <> nil) and (O.SuperThis = nil) then
    Result := VM.GetData(O, IntToStr(Index));
end;

procedure SetElement(VM: TAVM1; O: TAVMObject; Index: Integer; const Value: TAVMValue);
begin
  if (O = nil) or (O.SuperThis <> nil) then
    Exit;
  if (O.ClassName = 'Array') and (Index >= ArrayLength(VM, O)) then
    VM.SetArrayLength(O, AVMToInt32(Index + 1.0));
  VM.PutData(O, IntToStr(Index), Value);
end;

procedure Initialize(VM: TAVM1; O: TAVMObject; const Values: TArray<TAVMValue>);
var
  I: Integer;
begin
  for I := 0 to High(Values) do
  begin
    O.StoreData(IntToStr(I), Values[I]);
    O.Attributes.AddOrSetValue(IntToStr(I), 0);
  end;
  O.StoreData('length', TAVMValue.Num(Length(Values)));
  O.Attributes.AddOrSetValue('length', 3);
  O.ClassName := 'Array';
end;

function AVMNewArray(VM: TAVM1; const Values: TArray<TAVMValue>): TAVMObject;
var
  ConstructorValue, PrototypeValue: TAVMValue;
  Key: string;
begin
  Result := VM.NewObject('Array');
  Result.RemoveData('__proto__');
  { ArrayBuilder resolves the global constructor and its own stored prototype,
    without running getters, even if guest code has replaced the constructor. }
  if VM.FindOwnKey(VM.Global, 'Array', Key) then
  begin
    ConstructorValue := VM.GetData(VM.Global, Key);
    if ConstructorValue.Obj <> nil then
    begin
      if VM.FindOwnKey(ConstructorValue.Obj, 'prototype', Key) then
      begin
        PrototypeValue := VM.GetData(ConstructorValue.Obj, Key);
        Result.StoreData('__proto__', PrototypeValue);
        Result.Attributes.AddOrSetValue('__proto__', 3);
        VM.PutData(Result, '__proto__', PrototypeValue);
      end;
      Result.StoreData('constructor', ConstructorValue);
      Result.Attributes.AddOrSetValue('constructor', 3);
    end;
  end;
  Initialize(VM, Result, Values);
end;

function AbsoluteIndex(Index, Length: Integer): Integer;
begin
  if Index < 0 then
    Result := Max(AVMToInt32(Index + Double(Length)), 0)
  else
    Result := Min(Index, Length);
end;

function CompareValues(VM: TAVM1; const A, B: TAVMValue; Options: Integer): Integer;
var
  Left, Right: string;
  I: Integer;
begin
  Result := 0;
  if ((Options and 16) <> 0) and (A.Kind = avNumber) and (B.Kind = avNumber) then
  begin
    if A.Number < B.Number then
      Result := -1
    else if A.Number > B.Number then
      Result := 1;
  end
  else
  begin
    Left := VM.CoerceString(A);
    Right := VM.CoerceString(B);
    if (Options and 1) <> 0 then
    begin
      Left := AVMLowerName(Left);
      Right := AVMLowerName(Right);
    end;
    { Flash compares UCS-2 code units, without locale collation. }
    for I := 1 to Min(Length(Left), Length(Right)) do
    begin
      if Ord(Left[I]) < Ord(Right[I]) then
      begin
        Result := -1;
        Break;
      end;
      if Ord(Left[I]) > Ord(Right[I]) then
      begin
        Result := 1;
        Break;
      end;
    end;
    if Result = 0 then
    begin
      if Length(Left) < Length(Right) then
        Result := -1
      else if Length(Left) > Length(Right) then
        Result := 1;
    end;
  end;
  if (Options and 2) <> 0 then
    Result := -Result;
end;

function SortArray(VM: TAVM1; O: TAVMObject; const Args: TArray<TAVMValue>; SortOn: Boolean): TAVMValue;
var
  Options, Count, I, J, Left, Right, LowerBound, UpperBound, CompareOptions: Integer;
  Descending: Boolean;
  Comparator: TAVMObject;
  Fields: TArray<TSortField>;
  Elements: TArray<TSortElement>;
  Values: TArray<TAVMValue>;
  Stack: TList<TSortRange>;
  Item: TSortElement;
  Range: TSortRange;
  Pivot: TAVMValue;
  FieldValue, OptionValue: TAVMValue;

  function Compare(const A, B: TAVMValue; DefaultComparator: Boolean = False): Integer;
  var
    K: Integer;
    Number: Double;
    V: TAVMValue;
  begin
    VM.ChargeWork(1);
    if SortOn and (Length(Fields) > 0) and (A.Obj <> nil) and (B.Obj <> nil) then
    begin
      Result := 0;
      for K := 0 to High(Fields) do
      begin
        Result := CompareValues(VM, VM.GetOwnStored(A.Obj, Fields[K].Name),
          VM.GetOwnStored(B.Obj, Fields[K].Name), Fields[K].Options);
        if Result <> 0 then
          Exit;
      end;
    end
    else if not DefaultComparator and (Comparator <> nil) then
    begin
      V := VM.Call(TAVMValue.Ref(Comparator), nil, [A, B]);
      Number := VM.CoerceNumber(V);
      Result := 0;
      if Number < 0 then
        Result := -1
      else if Number > 0 then
        Result := 1;
    end
    else
      Result := CompareValues(VM, A, B, CompareOptions);
  end;

begin
  Result := Default(TAVMValue);
  Comparator := nil;
  Options := 0;
  Fields := nil;
  if SortOn then
  begin
    if System.Length(Args) = 0 then
      Exit;
    FieldValue := Args[0];
    OptionValue := Default(TAVMValue);
    if System.Length(Args) > 1 then
      OptionValue := Args[1];
    if FieldValue.Obj <> nil then
    begin
      if FieldValue.Obj.ClassName = 'Array' then
      begin
        Count := ArrayLength(VM, FieldValue.Obj);
        CheckIterationLength(Count);
        if Count <= 0 then
          Exit(TAVMValue.Ref(O));
        SetLength(Fields, Count);
        for I := 0 to Count - 1 do
          Fields[I].Name := VM.CoerceString(Element(VM, FieldValue.Obj, I));
        if (OptionValue.Obj <> nil) and (OptionValue.Obj.ClassName = 'Array') and
          (ArrayLength(VM, OptionValue.Obj) = Count) then
          for I := 0 to Count - 1 do
            Fields[I].Options := AVMToInt32(VM.CoerceNumber(Element(VM, OptionValue.Obj, I))) and 31
        else if OptionValue.Kind <> avObject then
        begin
          Options := AVMToInt32(VM.CoerceNumber(OptionValue)) and 31;
          for I := 0 to Count - 1 do
            Fields[I].Options := Options;
        end;
      end;
    end
    else
    begin
      SetLength(Fields, 1);
      Fields[0].Name := VM.CoerceString(FieldValue);
      if OptionValue.Kind = avNumber then
        Fields[0].Options := AVMToInt32(OptionValue.Number) and 31;
    end;
    if System.Length(Fields) > 0 then
      Options := Fields[0].Options;
  end
  else if System.Length(Args) > 0 then
  begin
    if Args[0].Kind = avObject then
    begin
      Comparator := Args[0].Obj;
      if (System.Length(Args) > 1) and (Args[1].Kind = avNumber) then
        Options := AVMToInt32(Args[1].Number) and 31;
    end
    else if Args[0].Kind = avNumber then
    begin
      Options := AVMToInt32(Args[0].Number) and 31;
      if (System.Length(Args) > 1) and (Args[1].Kind = avNumber) then
        Options := AVMToInt32(Args[1].Number) and 31;
    end
    else
      Exit;
  end;
  Count := ArrayLength(VM, O);
  CheckIterationLength(Count);
  SetLength(Elements, Max(0, Count));
  for I := 0 to Count - 1 do
  begin
    Elements[I].Index := I;
    Elements[I].Value := Element(VM, O, I);
  end;
  Descending := (Options and 2) <> 0;
  CompareOptions := Options;
  if not SortOn then
    CompareOptions := CompareOptions and not 2;
  Stack := TList<TSortRange>.Create;
  try
    Range.Low := 0;
    Range.High := Count - 1;
    Stack.Add(Range);
    while Stack.Count > 0 do
    begin
      Range := Stack.Last;
      Stack.Delete(Stack.Count - 1);
      LowerBound := Range.Low;
      UpperBound := Range.High;
      if LowerBound >= UpperBound then
        Continue;
      Pivot := Elements[LowerBound].Value;
      Left := LowerBound + 1;
      Right := UpperBound;
      while True do
      begin
        while Left < Right do
        begin
          if Compare(Pivot, Elements[Left].Value) <= 0 then
            Break;
          Inc(Left);
        end;
        while Right > LowerBound do
        begin
          if Compare(Pivot, Elements[Right].Value) > 0 then
            Break;
          Dec(Right);
        end;
        if Left >= Right then
          Break;
        Item := Elements[Left];
        Elements[Left] := Elements[Right];
        Elements[Right] := Item;
      end;
      Item := Elements[LowerBound];
      Elements[LowerBound] := Elements[Right];
      Elements[Right] := Item;
      Range.Low := Right + 1;
      Range.High := UpperBound;
      Stack.Add(Range);
      if Right > 0 then
      begin
        Range.Low := LowerBound;
        Range.High := Right - 1;
        Stack.Add(Range);
      end;
    end;
  finally
    Stack.Free;
  end;
  if not SortOn and Descending then
    for I := 0 to Count div 2 - 1 do
    begin
      J := Count - I - 1;
      Item := Elements[I];
      Elements[I] := Elements[J];
      Elements[J] := Item;
    end;
  if (Options and 4) <> 0 then
    for I := 1 to Count - 1 do
      if Compare(Elements[I - 1].Value, Elements[I].Value, not SortOn) = 0 then
        Exit(TAVMValue.Num(0));
  if (Options and 8) <> 0 then
  begin
    SetLength(Values, Max(0, Count));
    for I := 0 to Count - 1 do
      Values[I] := TAVMValue.Num(Elements[I].Index);
    Exit(TAVMValue.Ref(AVMNewArray(VM, Values)));
  end;
  for I := 0 to Count - 1 do
    SetElement(VM, O, I, Elements[I].Value);
  Result := TAVMValue.Ref(O);
end;

function OtherArrayCall(VM: TAVM1; const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
var
  Length, NewLength, I, J, Start, Finish, DeleteCount, InsertCount, Source, Destination: Integer;
  Values: TArray<TAVMValue>;
  V, Other: TAVMValue;
  O: TAVMObject;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < System.Length(Args) then
      Result := Args[Index];
  end;

  procedure Append(const Value: TAVMValue);
  var
    Count: Integer;
  begin
    Count := System.Length(Values);
    if Count >= 65536 then
      raise ESWFError.Create('AVM1 array iteration limit');
    SetLength(Values, Count + 1);
    Values[Count] := Value;
    VM.ChargeWork(1);
  end;

  procedure MoveSplice(Index: Integer);
  var
    Target: Integer;
  begin
    Target := Index - DeleteCount + InsertCount;
    if VM.HasOwnProperty(ThisObj, IntToStr(Index)) then
      SetElement(VM, ThisObj, Target, Element(VM, ThisObj, Index))
    else
      VM.DeleteMember(ThisObj, IntToStr(Target));
    VM.ChargeWork(1);
  end;

begin
  Result := Default(TAVMValue);
  if Name = 'Array' then
  begin
    if ConstructorCall then
    begin
      O := ThisObj;
      if O = nil then
        Exit;
      Initialize(VM, O, []);
    end
    else
      O := AVMNewArray(VM, []);
    if (System.Length(Args) = 1) and (Args[0].Kind = avNumber) then
    begin
      V := Args[0];
      if IsNan(V.Number) then
        I := 0
      else if V.Number >= High(Integer) then
        I := High(Integer)
      else if V.Number <= Low(Integer) then
        I := Low(Integer)
      else
        I := Trunc(V.Number);
      VM.SetArrayLength(O, I);
    end
    else
      Initialize(VM, O, Args);
    Exit(TAVMValue.Ref(O));
  end;
  if Name = 'Array.sort' then
    Exit(SortArray(VM, ThisObj, Args, False));
  if Name = 'Array.sortOn' then
    Exit(SortArray(VM, ThisObj, Args, True));
  if Name = 'Array.splice' then
  begin
    if (System.Length(Args) = 0) or (Arg(0).Kind = avUndefined) then
      Exit;
    Start := AVMToInt32(VM.CoerceNumber(Arg(0)));
  end
  else
    Start := 0;
  Length := ArrayLength(VM, ThisObj);
  CheckIterationLength(Length);
  if Name = 'Array.push' then
  begin
    NewLength := AVMToInt32(Length + Double(System.Length(Args)));
    for I := 0 to High(Args) do
    begin
      VM.ChargeWork(1);
      SetElement(VM, ThisObj, AVMToInt32(Length + Double(I)), Args[I]);
    end;
    VM.SetArrayLength(ThisObj, NewLength);
    Exit(TAVMValue.Num(NewLength));
  end;
  if (Name = 'Array.pop') or (Name = 'Array.shift') then
  begin
    if Length = 0 then
      Exit;
    if Name = 'Array.pop' then
    begin
      I := AVMToInt32(Length - 1.0);
      Result := Element(VM, ThisObj, I);
      VM.DeleteMember(ThisObj, IntToStr(I));
    end
    else
    begin
      Result := Element(VM, ThisObj, 0);
      for I := 1 to Length - 1 do
      begin
        VM.ChargeWork(1);
        V := Element(VM, ThisObj, I);
        VM.DeleteMember(ThisObj, IntToStr(I - 1));
        SetElement(VM, ThisObj, I - 1, V);
      end;
    end;
    if (ThisObj <> nil) and (ThisObj.ClassName = 'Array') then
      VM.SetArrayLength(ThisObj, AVMToInt32(Length - 1.0));
    Exit;
  end;
  if Name = 'Array.unshift' then
  begin
    NewLength := AVMToInt32(Length + Double(System.Length(Args)));
    for I := 0 to Length - 1 do
    begin
      VM.ChargeWork(1);
      Source := Length - I - 1;
      Destination := NewLength - I - 1;
      V := Element(VM, ThisObj, Source);
      VM.DeleteMember(ThisObj, IntToStr(Destination));
      SetElement(VM, ThisObj, Destination, V);
    end;
    for I := 0 to High(Args) do
    begin
      VM.DeleteMember(ThisObj, IntToStr(I));
      SetElement(VM, ThisObj, I, Args[I]);
    end;
    if (ThisObj <> nil) and (ThisObj.ClassName = 'Array') then
      VM.SetArrayLength(ThisObj, NewLength);
    Exit(TAVMValue.Num(NewLength));
  end;
  if Name = 'Array.reverse' then
  begin
    for I := 0 to Length div 2 - 1 do
    begin
      VM.ChargeWork(1);
      J := Length - I - 1;
      V := Element(VM, ThisObj, I);
      Other := Element(VM, ThisObj, J);
      VM.DeleteMember(ThisObj, IntToStr(I));
      VM.DeleteMember(ThisObj, IntToStr(J));
      SetElement(VM, ThisObj, I, Other);
      SetElement(VM, ThisObj, J, V);
    end;
    Exit(TAVMValue.Ref(ThisObj));
  end;
  if Name = 'Array.slice' then
  begin
    Start := AbsoluteIndex(AVMToInt32(VM.CoerceNumber(Arg(0))), Length);
    Finish := Length;
    if (System.Length(Args) > 1) and (Arg(1).Kind <> avUndefined) then
      Finish := AbsoluteIndex(AVMToInt32(VM.CoerceNumber(Arg(1))), Length);
    for I := Start to Finish - 1 do
      Append(Element(VM, ThisObj, I));
    Exit(TAVMValue.Ref(AVMNewArray(VM, Values)));
  end;
  if Name = 'Array.splice' then
  begin
    Start := AbsoluteIndex(Start, Length);
    DeleteCount := Length - Start;
    if System.Length(Args) > 1 then
    begin
      if Arg(1).Kind = avUndefined then
        Exit;
      DeleteCount := Min(AVMToInt32(VM.CoerceNumber(Args[1])), DeleteCount);
    end;
    if DeleteCount < 0 then
      Exit;
    for I := 0 to DeleteCount - 1 do
      Append(Element(VM, ThisObj, Start + I));
    O := AVMNewArray(VM, Values);
    InsertCount := Max(0, System.Length(Args) - 2);
    if InsertCount > DeleteCount then
      for I := Length - 1 downto Start + DeleteCount do
        MoveSplice(I)
    else
      for I := Start + DeleteCount to Length - 1 do
        MoveSplice(I);
    for I := 0 to InsertCount - 1 do
      SetElement(VM, ThisObj, Start + I, Args[I + 2]);
    VM.SetArrayLength(ThisObj, AVMToInt32(Length - Double(DeleteCount) + InsertCount));
    Exit(TAVMValue.Ref(O));
  end;
  if Name = 'Array.concat' then
  begin
    for I := -1 to High(Args) do
    begin
      if I < 0 then
        V := TAVMValue.Ref(ThisObj)
      else
        V := Args[I];
      O := V.Obj;
      if (O <> nil) and ((O.ClassName = 'Array') or ((I < 0) and (O.HostData = nil) and not O.IsFunction and not O.IsBoxed)) then
      begin
        J := ArrayLength(VM, O);
        CheckIterationLength(J);
        for Source := 0 to J - 1 do
          Append(Element(VM, O, Source));
      end
      else
        Append(V);
    end;
    Exit(TAVMValue.Ref(AVMNewArray(VM, Values)));
  end;
  raise ESWFError.Create('Unsupported AVM1 array method: ' + Name);
end;

function JoinArray(VM: TAVM1; const Name: string; O: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  Count, I: Integer;
  Text, Part, Separator: string;
begin
  Count := ArrayLength(VM, O);
  CheckIterationLength(Count);
  Separator := ',';
  if (Name = 'Array.join') and (Length(Args) > 0) then
    Separator := VM.CoerceString(Args[0]);
  Text := '';
  for I := 0 to Count - 1 do
  begin
    VM.ChargeWork(1);
    Part := VM.CoerceString(Element(VM, O, I));
    if I > 0 then
      Text := Text + Separator;
    Text := Text + Part;
    if Length(Text) > 1048576 then
      raise ESWFError.Create('AVM1 joined string limit');
  end;
  Result := TAVMValue.Str(Text);
end;

function AVMArrayCall(VM: TAVM1; const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>; ConstructorCall: Boolean): TAVMValue;
begin
  if Name = 'Array.unknown' then
    Exit(Default(TAVMValue));
  if (Name = 'Array.toString') or (Name = 'Array.join') then
    Exit(JoinArray(VM, Name, ThisObj, Args));
  Result := OtherArrayCall(VM, Name, ThisObj, Args, ConstructorCall);
end;

end.

