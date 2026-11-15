unit Java.Collections;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaCollections(VM: TJVM);

function InvokeJavaCollections(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes;

{$Q-}{$R-}

const
  VectorName = 'java/util/Vector';
  EnumName = 'java/util/Vector$Enumeration';
  StackName = 'java/util/Stack';
  ObjectType = 'Ljava/lang/Object;';
  DataKey = VectorName + '.elementData:[Ljava/lang/Object;';
  CountKey = VectorName + '.elementCount:I';
  IncrementKey = VectorName + '.capacityIncrement:I';
  EnumVectorKey = EnumName + '.$vector:Ljava/util/Vector;';
  EnumIndexKey = EnumName + '.$index:I';
  Sync = JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED;

procedure InstallJavaCollections(VM: TJVM);
var
  B: TJavaClassBuilder;
  Data, Count: Word;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Descriptor: string; Access: Word = Sync);
  begin
    B.JavaClass.AddNative(Name, Descriptor).Access := Access or JVM_ACC_NATIVE;
  end;

  procedure Throw(const Name: string);
  begin
    B.Ref($BB, B.ClassRef(Name));
    B.Emit([$59]);
    B.Ref($B7, B.Member(Name, '<init>', '()V'));
    B.Emit([$BF]);
  end;

  procedure StringValue(const Text: string);
  begin
    B.Ref($13, B.StringConstant(Text));
  end;

  procedure Append;
  begin
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Emit([$57]);
  end;

begin
  B := nil;
  try
    for var Name in ['NoSuchElementException', 'EmptyStackException'] do
    begin
      B := TJavaClassBuilder.Create('java/util/' + Name, 'java/lang/RuntimeException');
      Native('<init>', '()V', JVM_ACC_PUBLIC);
      if Name = 'NoSuchElementException' then
        Native('<init>', '(Ljava/lang/String;)V', JVM_ACC_PUBLIC);
      Done;
    end;
    B := TJavaClassBuilder.Create('java/util/Enumeration', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.AddNative('hasMoreElements', '()Z').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    B.JavaClass.AddNative('nextElement', '()Ljava/lang/Object;').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Done;

    B := TJavaClassBuilder.Create(VectorName, 'java/lang/Object');
    Data := B.Field('elementData', '[Ljava/lang/Object;', JVM_ACC_PROTECTED);
    Count := B.Field('elementCount', 'I', JVM_ACC_PROTECTED);
    B.Field('capacityIncrement', 'I', JVM_ACC_PROTECTED);
    for var Descriptor in ['()V', '(I)V', '(II)V'] do
      Native('<init>', Descriptor, JVM_ACC_PUBLIC);
    Native('capacity', '()I');
    Native('size', '()I');
    Native('isEmpty', '()Z');
    Native('setSize', '(I)V');
    Native('ensureCapacity', '(I)V');
    Native('trimToSize', '()V');
    Native('elementAt', '(I)Ljava/lang/Object;');
    Native('firstElement', '()Ljava/lang/Object;');
    Native('lastElement', '()Ljava/lang/Object;');
    Native('addElement', '(Ljava/lang/Object;)V');
    Native('insertElementAt', '(Ljava/lang/Object;I)V');
    Native('setElementAt', '(Ljava/lang/Object;I)V');
    Native('removeElementAt', '(I)V');
    Native('removeAllElements', '()V');
    Native('elements', '()Ljava/util/Enumeration;', JVM_ACC_PUBLIC);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, Data);
    B.Emit([$03, $2B, $03, $2A]);
    B.Ref($B4, Count);
    B.Ref($B8, B.Member('java/lang/System', 'arraycopy', '(Ljava/lang/Object;ILjava/lang/Object;II)V'));
    B.Emit([$B1]);
    B.Finish('copyInto', '([Ljava/lang/Object;)V', Sync, 5, 2);
    for var Reverse in [False, True] do
    begin
      var Name := 'indexOf';
      if Reverse then
        Name := 'lastIndexOf';
      B.Start;
      if Reverse then
      begin
        B.Emit([$1C, $2A]);
        B.Ref($B4, Count);
        B.Jump($A1, 'loop');
        Throw('java/lang/IndexOutOfBoundsException');
      end;
      B.Mark('loop');
      if Reverse then
      begin
        B.Emit([$1C]);
        B.Jump($9B, 'missing');
      end
      else
      begin
        B.Emit([$1C, $2A]);
        B.Ref($B4, Count);
        B.Jump($A2, 'missing');
      end;
      B.Emit([$2A]);
      B.Ref($B4, Data);
      B.Emit([$1C, $32, $4E, $2B]);
      B.Jump($C7, 'equals');
      B.Emit([$2D]);
      B.Jump($C6, 'found');
      B.Jump($A7, 'next');
      B.Mark('equals');
      B.Emit([$2B, $2D]);
      B.Ref($B6, B.Member('java/lang/Object', 'equals', '(Ljava/lang/Object;)Z'));
      B.Jump($9A, 'found');
      B.Mark('next');
      if Reverse then
        B.Emit([$84, 2, $FF])
      else
        B.Emit([$84, 2, 1]);
      B.Jump($A7, 'loop');
      B.Mark('found');
      B.Emit([$1C, $AC]);
      B.Mark('missing');
      B.Emit([$02, $AC]);
      B.Finish(Name, '(Ljava/lang/Object;I)I', Sync, 2, 4);
      B.Start;
      B.Emit([$2A, $2B]);
      if Reverse then
      begin
        B.Emit([$2A]);
        B.Ref($B4, Count);
        B.Emit([$04, $64]);
      end
      else
        B.Emit([$03]);
      B.Ref($B6, B.Member(VectorName, Name, '(Ljava/lang/Object;I)I'));
      B.Emit([$AC]);
      B.Finish(Name, '(Ljava/lang/Object;)I', Sync, 4, 2);
    end;
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member(VectorName, 'indexOf', '(Ljava/lang/Object;)I'));
    B.Jump($9B, 'missing');
    B.Emit([$04, $AC]);
    B.Mark('missing');
    B.Emit([$03, $AC]);
    B.Finish('contains', '(Ljava/lang/Object;)Z', JVM_ACC_PUBLIC, 2, 2);
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member(VectorName, 'indexOf', '(Ljava/lang/Object;)I'));
    B.Emit([$3D, $1C]);
    B.Jump($9B, 'missing');
    B.Emit([$2A, $1C]);
    B.Ref($B6, B.Member(VectorName, 'removeElementAt', '(I)V'));
    B.Emit([$04, $AC]);
    B.Mark('missing');
    B.Emit([$03, $AC]);
    B.Finish('removeElement', '(Ljava/lang/Object;)Z', Sync, 2, 3);

    // Composed guest calls retain the vector monitor through arbitrary guest
    // equals/toString callbacks, yielding, exceptions and recursive mutations.
    B.Start;
    B.Ref($BB, B.ClassRef('java/lang/StringBuffer'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/StringBuffer', '<init>', '()V'));
    B.Emit([$4C, $2B]);
    StringValue('[');
    Append;
    B.Emit([$03, $3D]);
    B.Mark('loop');
    B.Emit([$1C, $2A]);
    B.Ref($B4, Count);
    B.Jump($A2, 'end');
    B.Emit([$1C]);
    B.Jump($99, 'item');
    B.Emit([$2B]);
    StringValue(', ');
    Append;
    B.Mark('item');
    B.Emit([$2A]);
    B.Ref($B4, Data);
    B.Emit([$1C, $32, $4E, $2B, $2D]);
    B.Jump($C7, 'notNull');
    StringValue('null');
    B.Jump($A7, 'append');
    B.Mark('notNull');
    B.Emit([$2D, $2A]);
    B.Jump($A6, 'value');
    StringValue('(this Collection)');
    B.Jump($A7, 'append');
    B.Mark('value');
    B.Emit([$2D]);
    B.Ref($B6, B.Member('java/lang/Object', 'toString', '()Ljava/lang/String;'));
    B.Mark('append');
    Append;
    B.Emit([$84, 2, 1]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$2B]);
    StringValue(']');
    Append;
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'toString', '()Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('toString', '()Ljava/lang/String;', Sync, 3, 4);
    Done;

    B := TJavaClassBuilder.Create(EnumName, 'java/lang/Object', JVM_ACC_FINAL or $0020);
    B.JavaClass.Interfaces := ['java/util/Enumeration'];
    var Owner := B.Field('$vector', 'Ljava/util/Vector;', JVM_ACC_PRIVATE);
    B.Field('$index', 'I', JVM_ACC_PRIVATE);
    Native('hasMoreElements', '()Z', JVM_ACC_PUBLIC);
    Native('$next', '()Ljava/lang/Object;', JVM_ACC_PRIVATE);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, Owner);
    B.Emit([$59, $4C, $C2]);
    B.Mark('locked');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(EnumName, '$next', '()Ljava/lang/Object;'));
    B.Emit([$4D, $2B, $C3]);
    B.Mark('unlocked');
    B.Emit([$2C, $B0]);
    B.Mark('failed');
    B.Emit([$4D, $2B, $C3, $2C, $BF]);
    B.Finish('nextElement', '()Ljava/lang/Object;', JVM_ACC_PUBLIC, 2, 3);
    var H: TJVMExceptionHandler;
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('locked');
    H.EndPC := B.Position('unlocked');
    H.HandlerPC := B.Position('failed');
    B.JavaClass.Methods.Last.Handlers := [H];
    Done;

    B := TJavaClassBuilder.Create(StackName, VectorName);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(VectorName, '<init>', '()V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member(VectorName, 'addElement', '(Ljava/lang/Object;)V'));
    B.Emit([$2B, $B0]);
    B.Finish('push', '(Ljava/lang/Object;)Ljava/lang/Object;', JVM_ACC_PUBLIC, 2, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(VectorName, 'size', '()I'));
    B.Emit([$3C, $1B]);
    B.Jump($9A, 'item');
    Throw('java/util/EmptyStackException');
    B.Mark('item');
    B.Emit([$2A, $1B, $04, $64]);
    B.Ref($B6, B.Member(VectorName, 'elementAt', '(I)Ljava/lang/Object;'));
    B.Emit([$B0]);
    B.Finish('peek', '()Ljava/lang/Object;', Sync, 3, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(VectorName, 'size', '()I'));
    B.Emit([$3C, $2A]);
    B.Ref($B6, B.Member(StackName, 'peek', '()Ljava/lang/Object;'));
    B.Emit([$4D, $2A, $1B, $04, $64]);
    B.Ref($B6, B.Member(VectorName, 'removeElementAt', '(I)V'));
    B.Emit([$2C, $B0]);
    B.Finish('pop', '()Ljava/lang/Object;', Sync, 3, 3);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(VectorName, 'size', '()I'));
    B.Jump($9A, 'no');
    B.Emit([$04, $AC]);
    B.Mark('no');
    B.Emit([$03, $AC]);
    B.Finish('empty', '()Z', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B6, B.Member(VectorName, 'lastIndexOf', '(Ljava/lang/Object;)I'));
    B.Emit([$3D, $1C]);
    B.Jump($9B, 'missing');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(VectorName, 'size', '()I'));
    B.Emit([$1C, $64, $AC]);
    B.Mark('missing');
    B.Emit([$02, $AC]);
    B.Finish('search', '(Ljava/lang/Object;)I', Sync, 2, 3);
    Done;
  finally
    B.Free;
  end;
end;

function InvokeJavaCollections(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, Data: TJVMObject;
  Count, Index: Integer;
  N: string;

  function ArrayData: TJVMObject;
  begin
    Result := VM.GetObject(O.Fields[DataKey].AsRef);
  end;

  procedure ArrayIndex(I: Integer);
  begin
    if (I < 0) or (I >= Length(Data.Elements)) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
  end;

  procedure ValidIndex(I: Integer);
  begin
    if (I < 0) or (I >= Count) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    ArrayIndex(I);
  end;

  procedure Store(I: Integer; const Value: TJVMValue);
  begin
    ArrayIndex(I);
    if (Value.AsRef <> 0) and (Data.ClassName <> '[Ljava/lang/Object;') then
    begin
      var Component := Copy(Data.ClassName, 2, MaxInt);
      if Component.StartsWith('L') then
        Component := Copy(Component, 2, Length(Component) - 2);
      if not VM.IsAssignable(VM.GetObject(Value.AsRef).ClassName, Component) then
        VM.RaiseJava('java/lang/ArrayStoreException');
    end;
    Data.Elements[I] := Value;
  end;

  procedure Resize(NewCapacity: Int64);
  begin
    if NewCapacity < 0 then
      VM.RaiseJava('java/lang/NegativeArraySizeException');
    if (NewCapacity > MaxInt) or (NewCapacity > VM.MaxArrayLength) then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Vector capacity limit');
    var Ref := VM.NewArray('[Ljava/lang/Object;', Integer(NewCapacity));
    var NewData := VM.GetObject(Ref);
    for var I := 0 to Min(Length(Data.Elements), Length(NewData.Elements)) - 1 do
      NewData.Elements[I] := Data.Elements[I];
    O.Fields[DataKey] := TJVMValue.Ref(Ref);
    Data := NewData;
  end;

  procedure Grow(Minimum: Int64);
  begin
    if Minimum <= Length(Data.Elements) then
      Exit;
    var Capacity := Int64(Length(Data.Elements));
    var Increment := O.Fields[IncrementKey].AsInt;
    if Increment > 0 then
      Inc(Capacity, Increment)
    else
      Capacity := Capacity * 2;
    Resize(Max(Capacity, Minimum));
  end;

begin
  Result := Default(TJVMValue);
  N := Method.Name;
  O := VM.GetObject(Args[0].AsRef);
  if Method.Owner.Name = EnumName then
  begin
    var E := O;
    Index := E.Fields[EnumIndexKey].AsInt;
    O := VM.GetObject(E.Fields[EnumVectorKey].AsRef);
    Count := O.Fields[CountKey].AsInt;
    if N = 'hasMoreElements' then
      Exit(TJVMValue.Int(Ord(Index < Count)));
    if Index >= Count then
      VM.RaiseJava('java/util/NoSuchElementException');
    Data := ArrayData;
    ArrayIndex(Index);
    Result := Data.Elements[Index];
    E.Fields[EnumIndexKey] := TJVMValue.Int(Index + 1);
    Exit;
  end;
  if N = '<init>' then
  begin
    var Capacity := 10;
    var Increment := 0;
    if Length(Args) > 1 then
      Capacity := Args[1].AsInt;
    if Length(Args) > 2 then
      Increment := Args[2].AsInt;
    if Capacity < 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    if Capacity > VM.MaxArrayLength then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Vector capacity limit');
    var Ref := VM.NewArray('[Ljava/lang/Object;', Capacity);
    O.Fields[DataKey] := TJVMValue.Ref(Ref);
    O.Fields[CountKey] := TJVMValue.Int(0);
    O.Fields[IncrementKey] := TJVMValue.Int(Increment);
    Exit;
  end;
  Count := O.Fields[CountKey].AsInt;
  if N = 'size' then
    Exit(TJVMValue.Int(Count));
  if N = 'isEmpty' then
    Exit(TJVMValue.Int(Ord(Count = 0)));
  if N = 'elements' then
  begin
    var Ref := VM.NewObject(EnumName);
    var E := VM.GetObject(Ref);
    E.Fields[EnumVectorKey] := Args[0];
    E.Fields[EnumIndexKey] := TJVMValue.Int(0);
    Exit(TJVMValue.Ref(Ref));
  end;
  if (N = 'ensureCapacity') and (Args[1].AsInt <= 0) then
    Exit;
  Data := ArrayData;
  if N = 'capacity' then
    Exit(TJVMValue.Int(Length(Data.Elements)));
  if N = 'ensureCapacity' then
  begin
    Grow(Args[1].AsInt);
    Exit;
  end;
  if N = 'trimToSize' then
  begin
    if Count < Length(Data.Elements) then
      Resize(Count);
    Exit;
  end;
  if N = 'setSize' then
  begin
    var NewCount := Args[1].AsInt;
    if NewCount < 0 then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    Grow(NewCount);
    for var I := Min(Count, NewCount) to Max(Count, NewCount) - 1 do
      Store(I, TJVMValue.Ref(0));
    O.Fields[CountKey] := TJVMValue.Int(NewCount);
    Exit;
  end;
  if (N = 'firstElement') or (N = 'lastElement') then
  begin
    if Count = 0 then
      VM.RaiseJava('java/util/NoSuchElementException');
    Index := 0;
    if N = 'lastElement' then
      Index := Count - 1;
    ArrayIndex(Index);
    Exit(Data.Elements[Index]);
  end;
  if N = 'elementAt' then
  begin
    Index := Args[1].AsInt;
    ValidIndex(Index);
    Exit(Data.Elements[Index]);
  end;
  if N = 'setElementAt' then
  begin
    Index := Args[2].AsInt;
    ValidIndex(Index);
    Store(Index, Args[1]);
    Exit;
  end;
  if (N = 'insertElementAt') or (N = 'addElement') then
  begin
    Index := Count;
    if N = 'insertElementAt' then
      Index := Args[2].AsInt;
    if (Index < 0) or (Index > Count) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    Grow(Int64(Count) + 1);
    ArrayIndex(Count);
    for var I := Count downto Index + 1 do
      Store(I, Data.Elements[I - 1]);
    Store(Index, Args[1]);
    O.Fields[CountKey] := TJVMValue.Int(Count + 1);
    Exit;
  end;
  if N = 'removeElementAt' then
  begin
    Index := Args[1].AsInt;
    ValidIndex(Index);
    if Count > 0 then
      ArrayIndex(Count - 1);
    for var I := Index to Count - 2 do
      Store(I, Data.Elements[I + 1]);
    Store(Count - 1, TJVMValue.Ref(0));
    O.Fields[CountKey] := TJVMValue.Int(Count - 1);
    Exit;
  end;
  if N = 'removeAllElements' then
  begin
    if Count > 0 then
      for var I := 0 to Count - 1 do
        Store(I, TJVMValue.Ref(0));
    O.Fields[CountKey] := TJVMValue.Int(0);
    Exit;
  end;
  raise EJVMUnsupported.Create('Vector native method: ' + N);
end;

end.

