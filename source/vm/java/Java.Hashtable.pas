unit Java.Hashtable;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaHashtable(VM: TJVM);

function InvokeJavaHashtable(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

// Native producers use ordinary Integer keys and guest references as values.
// Keys must be unique; callers retain ownership of the supplied value roots.
function JavaNewIntegerKeyTable(VM: TJVM; const Keys, Values: TArray<Integer>): Integer;

implementation

uses
  System.SysUtils, System.Generics.Collections, Java.Classes, Java.Numbers;

{$Q-}{$R-}

const
  TableName = 'java/util/Hashtable';
  EntryName = TableName + '$Entry';
  EnumName = TableName + '$Enumeration';
  EntryType = 'Ljava/util/Hashtable$Entry;';
  ArrayType = '[Ljava/util/Hashtable$Entry;';
  BucketsKey = TableName + '.$table:' + ArrayType;
  CountKey = TableName + '.$count:I';
  ThresholdKey = TableName + '.$threshold:I';
  VersionKey = TableName + '.$version:I';
  HashKey = EntryName + '.$hash:I';
  KeyKey = EntryName + '.$key:Ljava/lang/Object;';
  ValueKey = EntryName + '.$value:Ljava/lang/Object;';
  NextKey = EntryName + '.$next:' + EntryType;
  EnumTable = EnumName + '.$table:' + ArrayType;
  EnumOwner = EnumName + '.$owner:Ljava/util/Hashtable;';
  EnumIndex = EnumName + '.$index:I';
  EnumEntry = EnumName + '.$entry:' + EntryType;
  EnumKind = EnumName + '.$kind:I';
  Sync = JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED;

procedure InstallJavaHashtable(VM: TJVM);
var
  B: TJavaClassBuilder;
  Table, Version, Count, Threshold, Hash, Key, Value, Next: Word;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Descriptor: string; Access: Word = Sync);
  begin
    B.JavaClass.AddNative(Name, Descriptor).Access := Access or JVM_ACC_NATIVE;
  end;

  procedure ThrowNull;
  begin
    B.Ref($BB, B.ClassRef('java/lang/NullPointerException'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/NullPointerException', '<init>', '()V'));
    B.Emit([$BF]);
  end;

  procedure Append(const Text: string);
  begin
    B.Emit([$2B]);
    B.Ref($13, B.StringConstant(Text));
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Emit([$57]);
  end;

  procedure AppendObject(local: Byte; const LabelName: string);
  begin
    B.Emit([$2B, $19, local, $2A]);
    B.Jump($A6, LabelName);
    B.Ref($13, B.StringConstant('(this Map)'));
    B.Jump($A7, LabelName + 'Append');
    B.Mark(LabelName);
    B.Emit([$19, local]);
    B.Ref($B8, B.Member('java/lang/String', 'valueOf', '(Ljava/lang/Object;)Ljava/lang/String;'));
    B.Mark(LabelName + 'Append');
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Emit([$57]);
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(EntryName, 'java/lang/Object', JVM_ACC_FINAL or $0020);
    B.Field('$hash', 'I', 0);
    B.Field('$key', 'Ljava/lang/Object;', 0);
    B.Field('$value', 'Ljava/lang/Object;', 0);
    B.Field('$next', EntryType, 0);
    Done;
    B := TJavaClassBuilder.Create(EnumName, 'java/lang/Object', JVM_ACC_FINAL or $0020);
    B.JavaClass.Interfaces := ['java/util/Enumeration'];
    B.Field('$owner', 'Ljava/util/Hashtable;', JVM_ACC_PRIVATE);
    B.Field('$table', ArrayType, JVM_ACC_PRIVATE);
    B.Field('$entry', EntryType, JVM_ACC_PRIVATE);
    B.Field('$index', 'I', JVM_ACC_PRIVATE);
    B.Field('$kind', 'I', JVM_ACC_PRIVATE);
    Native('hasMoreElements', '()Z', JVM_ACC_PUBLIC);
    Native('nextElement', '()Ljava/lang/Object;', JVM_ACC_PUBLIC);
    Native('$nextEntry', '()' + EntryType, 0);
    Done;

    B := TJavaClassBuilder.Create(TableName, 'java/lang/Object');
    Table := B.Field('$table', ArrayType, JVM_ACC_PRIVATE);
    Count := B.Field('$count', 'I', JVM_ACC_PRIVATE);
    Threshold := B.Field('$threshold', 'I', JVM_ACC_PRIVATE);
    Version := B.Field('$version', 'I', JVM_ACC_PRIVATE);
    Hash := B.Member(EntryName, '$hash', 'I', 9);
    Key := B.Member(EntryName, '$key', 'Ljava/lang/Object;', 9);
    Value := B.Member(EntryName, '$value', 'Ljava/lang/Object;', 9);
    Next := B.Member(EntryName, '$next', EntryType, 9);
    Native('<init>', '()V', JVM_ACC_PUBLIC);
    Native('<init>', '(I)V', JVM_ACC_PUBLIC);
    Native('size', '()I');
    Native('isEmpty', '()Z');
    Native('clear', '()V');
    Native('rehash', '()V', JVM_ACC_PROTECTED);
    Native('keys', '()Ljava/util/Enumeration;');
    Native('elements', '()Ljava/util/Enumeration;');
    Native('$enumerator', '(I)Ljava/util/Hashtable$Enumeration;', JVM_ACC_PRIVATE);
    Native('$replace', '(' + EntryType + 'Ljava/lang/Object;)Ljava/lang/Object;', JVM_ACC_PRIVATE);
    Native('$delete', '(' + EntryType + 'I)Ljava/lang/Object;', JVM_ACC_PRIVATE);
    Native('$add', '(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;', JVM_ACC_PRIVATE);

    // Search executes guest equals. A callback may mutate the same table or
    // release its monitor with wait; restart against the new storage/version.
    B.Start;
    B.Mark('restart');
    B.Emit([$2A]);
    B.Ref($B4, Version);
    B.Emit([$3E, $2A]);
    B.Ref($B4, Table);
    B.Emit([$1C]);
    B.Ref($13, B.IntConstant(MaxInt));
    B.Emit([$7E, $2A]);
    B.Ref($B4, Table);
    B.Emit([$BE, $70, $32, $3A, 4]);
    B.Mark('loop');
    B.Emit([$19, 4]);
    B.Jump($C6, 'missing');
    B.Emit([$19, 4]);
    B.Ref($B4, Hash);
    B.Emit([$1C]);
    B.Jump($A0, 'next');
    B.Emit([$19, 4]);
    B.Ref($B4, Key);
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/lang/Object', 'equals', '(Ljava/lang/Object;)Z'));
    B.Emit([$36, 5]);
    B.Emit([$2A]);
    B.Ref($B4, Version);
    B.Emit([$1D]);
    B.Jump($A0, 'restart');
    B.Emit([$15, 5]);
    B.Jump($9A, 'found');
    B.Mark('next');
    B.Emit([$19, 4]);
    B.Ref($B4, Next);
    B.Emit([$3A, 4]);
    B.Jump($A7, 'loop');
    B.Mark('found');
    B.Emit([$19, 4, $B0]);
    B.Mark('missing');
    B.Emit([$01, $B0]);
    B.Finish('$find', '(Ljava/lang/Object;I)' + EntryType, JVM_ACC_PRIVATE, 3, 6);

    for var Name in ['get', 'containsKey', 'remove'] do
    begin
      B.Start;
      B.Emit([$2B]);
      B.Ref($B6, B.Member('java/lang/Object', 'hashCode', '()I'));
      B.Emit([$3D, $2A, $2B, $1C]);
      B.Ref($B7, B.Member(TableName, '$find', '(Ljava/lang/Object;I)' + EntryType));
      B.Emit([$4E, $2D]);
      B.Jump($C6, 'missing');
      if Name = 'containsKey' then
        B.Emit([$04, $AC])
      else if Name = 'get' then
      begin
        B.Emit([$2D]);
        B.Ref($B4, Value);
        B.Emit([$B0]);
      end
      else
      begin
        B.Emit([$2A, $2D, $1C]);
        B.Ref($B7, B.Member(TableName, '$delete', '(' + EntryType + 'I)Ljava/lang/Object;'));
        B.Emit([$B0]);
      end;
      B.Mark('missing');
      var Descriptor := '(Ljava/lang/Object;)Ljava/lang/Object;';
      if Name = 'containsKey' then
      begin
        B.Emit([$03, $AC]);
        Descriptor := '(Ljava/lang/Object;)Z';
      end
      else
        B.Emit([$01, $B0]);
      B.Finish(Name, Descriptor, Sync, 3, 4);
    end;

    B.Start;
    B.Emit([$2C]);
    B.Jump($C7, 'value');
    ThrowNull;
    B.Mark('value');
    B.Emit([$03, $36, 5]);
    B.Mark('hash');
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/lang/Object', 'hashCode', '()I'));
    B.Emit([$3E, $2A, $2B, $1D]);
    B.Ref($B7, B.Member(TableName, '$find', '(Ljava/lang/Object;I)' + EntryType));
    B.Emit([$3A, 4, $19, 4]);
    B.Jump($C6, 'new');
    B.Emit([$2A, $19, 4, $2C]);
    B.Ref($B7, B.Member(TableName, '$replace', '(' + EntryType + 'Ljava/lang/Object;)Ljava/lang/Object;'));
    B.Emit([$B0]);
    B.Mark('new');
    B.Emit([$15, 5]);
    B.Jump($9A, 'add');
    B.Emit([$2A]);
    B.Ref($B4, Count);
    B.Emit([$2A]);
    B.Ref($B4, Threshold);
    B.Jump($A1, 'add');
    B.Emit([$04, $36, 5, $2A]);
    B.Ref($B6, B.Member(TableName, 'rehash', '()V'));
    B.Jump($A7, 'hash');
    B.Mark('add');
    B.Emit([$2A, $2B, $2C, $1D]);
    B.Ref($B7, B.Member(TableName, '$add', '(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;'));
    B.Emit([$B0]);
    B.Finish('put', '(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;', Sync, 4, 6);

    B.Start;
    B.Emit([$2B]);
    B.Jump($C7, 'restart');
    ThrowNull;
    B.Mark('restart');
    B.Emit([$2A]);
    B.Ref($B4, Version);
    B.Emit([$3D, $2A, $05]);
    B.Ref($B7, B.Member(TableName, '$enumerator', '(I)Ljava/util/Hashtable$Enumeration;'));
    B.Emit([$4E]);
    B.Mark('loop');
    B.Emit([$2D]);
    B.Ref($B6, B.Member(EnumName, 'hasMoreElements', '()Z'));
    B.Jump($99, 'missing');
    B.Emit([$2D]);
    B.Ref($B6, B.Member(EnumName, '$nextEntry', '()' + EntryType));
    B.Ref($B4, Value);
    B.Emit([$3A, 4, $19, 4]);
    B.Jump($C6, 'loop');
    B.Emit([$19, 4, $2B]);
    B.Ref($B6, B.Member('java/lang/Object', 'equals', '(Ljava/lang/Object;)Z'));
    B.Emit([$36, 5]);
    B.Emit([$2A]);
    B.Ref($B4, Version);
    B.Emit([$1C]);
    B.Jump($A0, 'restart');
    B.Emit([$15, 5]);
    B.Jump($99, 'loop');
    B.Emit([$04, $AC]);
    B.Mark('missing');
    B.Emit([$03, $AC]);
    B.Finish('contains', '(Ljava/lang/Object;)Z', Sync, 2, 6);

    B.Start;
    B.Ref($BB, B.ClassRef('java/lang/StringBuffer'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/StringBuffer', '<init>', '()V'));
    B.Emit([$4C]);
    Append('{');
    B.Emit([$2A, $05]);
    B.Ref($B7, B.Member(TableName, '$enumerator', '(I)Ljava/util/Hashtable$Enumeration;'));
    B.Emit([$4D, $03, $36, 6]);
    B.Mark('loop');
    B.Emit([$2C]);
    B.Ref($B6, B.Member(EnumName, 'hasMoreElements', '()Z'));
    B.Jump($99, 'end');
    B.Emit([$15, 6]);
    B.Jump($99, 'item');
    Append(', ');
    B.Mark('item');
    B.Emit([$2C]);
    B.Ref($B6, B.Member(EnumName, '$nextEntry', '()' + EntryType));
    B.Emit([$4E, $2D]);
    B.Ref($B4, Key);
    B.Emit([$3A, 4, $2D]);
    B.Ref($B4, Value);
    B.Emit([$3A, 5]);
    AppendObject(4, 'key');
    Append('=');
    AppendObject(5, 'value');
    B.Emit([$04, $36, 6]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    Append('}');
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'toString', '()Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('toString', '()Ljava/lang/String;', Sync, 3, 7);
    Done;
  finally
    B.Free;
  end;
end;

function GetRef(O: TJVMObject; const Name: string): Integer;
begin
  Result := O.Fields[Name].AsRef;
end;

function GetInt(O: TJVMObject; const Name: string): Integer;
begin
  Result := O.Fields[Name].AsInt;
end;

procedure Bump(O: TJVMObject);
begin
  O.Fields[VersionKey] := TJVMValue.Int(GetInt(O, VersionKey) + 1);
end;

function Bucket(Hash, Capacity: Integer): Integer;
begin
  Result := Integer((UInt32(Hash) and $7FFFFFFF) mod UInt32(Capacity));
end;

function NewBuckets(VM: TJVM; Capacity: Int64): Integer;
begin
  if (Capacity > MaxInt) or (Capacity > VM.MaxArrayLength) then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Hashtable capacity limit');
  Result := VM.NewArray(ArrayType, Integer(Capacity));
end;

function InvokeJavaHashtable(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, Table, Entry: TJVMObject;
  N: string;
  Count, Index, Ref: Integer;

  function Enumerator(Kind: Integer): Integer;
  begin
    Result := VM.NewObject(EnumName);
    var E := VM.GetObject(Result);
    E.Fields[EnumOwner] := Args[0];
    E.Fields[EnumTable] := O.Fields[BucketsKey];
    E.Fields[EnumIndex] := TJVMValue.Int(Length(Table.Elements));
    E.Fields[EnumKind] := TJVMValue.Int(Kind);
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if Method.Owner.Name = EnumName then
  begin
    if (N <> 'hasMoreElements') and (N <> 'nextElement') and (N <> '$nextEntry') then
      raise EJVMUnsupported.Create('Hashtable enumeration method: ' + N);
    Table := VM.GetObject(GetRef(O, EnumTable));
    Ref := GetRef(O, EnumEntry);
    Index := GetInt(O, EnumIndex);
    var Scanned := 0;
    while (Ref = 0) and (Index > 0) do
    begin
      Dec(Index);
      Ref := Table.Elements[Index].AsRef;
      Inc(Scanned);
      if (Scanned = 256) and (Ref = 0) then
      begin
        O.Fields[EnumIndex] := TJVMValue.Int(Index);
        VM.RetryNative;
        Exit;
      end;
    end;
    O.Fields[EnumIndex] := TJVMValue.Int(Index);
    O.Fields[EnumEntry] := TJVMValue.Ref(Ref);
    if N = 'hasMoreElements' then
      Exit(TJVMValue.Int(Ord(Ref <> 0)));
    if Ref = 0 then
      VM.RaiseJava('java/util/NoSuchElementException');
    Entry := VM.GetObject(Ref);
    O.Fields[EnumEntry] := Entry.Fields[NextKey];
    if (N = '$nextEntry') or (GetInt(O, EnumKind) = 2) then
      Exit(TJVMValue.Ref(Ref));
    if GetInt(O, EnumKind) = 0 then
      Exit(Entry.Fields[KeyKey])
    else
      Exit(Entry.Fields[ValueKey]);
  end;
  if N = '<init>' then
  begin
    var Capacity := 11;
    if Length(Args) > 1 then
      Capacity := Args[1].AsInt;
    if Capacity < 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    if Capacity = 0 then
      Capacity := 1;
    Ref := NewBuckets(VM, Capacity);
    O.Fields[BucketsKey] := TJVMValue.Ref(Ref);
    O.Fields[CountKey] := TJVMValue.Int(0);
    O.Fields[ThresholdKey] := TJVMValue.Int(Integer(Int64(Capacity) * 3 div 4));
    Exit;
  end;
  Count := GetInt(O, CountKey);
  if N = 'size' then
    Exit(TJVMValue.Int(Count));
  if N = 'isEmpty' then
    Exit(TJVMValue.Int(Ord(Count = 0)));
  Table := VM.GetObject(GetRef(O, BucketsKey));
  if N = 'keys' then
    Exit(TJVMValue.Ref(Enumerator(0)));
  if N = 'elements' then
    Exit(TJVMValue.Ref(Enumerator(1)));
  if N = '$enumerator' then
    Exit(TJVMValue.Ref(Enumerator(Args[1].AsInt)));
  if N = 'clear' then
  begin
    Index := 0;
    var State := VM.NativeContinuation;
    if State.Kind = TJVMKind.Int then
      Index := State.AsInt;
    var Limit := Length(Table.Elements);
    var Last := Limit;
    if Limit - Index > 256 then
      Last := Index + 256;
    for var I := Index to Last - 1 do
      Table.Elements[I] := TJVMValue.Ref(0);
    if Last < Limit then
    begin
      VM.SetNativeContinuation(TJVMValue.Int(Last));
      VM.RetryNative;
      Exit;
    end;
    O.Fields[CountKey] := TJVMValue.Int(0);
    Bump(O);
    Exit;
  end;
  if N = 'rehash' then
  begin
    var Capacity := Length(Table.Elements);
    var NewCapacity := Int64(Capacity) * 2 + 1;
    Ref := NewBuckets(VM, NewCapacity);
    var NewTable := VM.GetObject(Ref);
    for var I := Capacity - 1 downto 0 do
    begin
      var Node := Table.Elements[I].AsRef;
      while Node <> 0 do
      begin
        Entry := VM.GetObject(Node);
        var Following := GetRef(Entry, NextKey);
        Index := Bucket(GetInt(Entry, HashKey), Integer(NewCapacity));
        Entry.Fields[NextKey] := NewTable.Elements[Index];
        NewTable.Elements[Index] := TJVMValue.Ref(Node);
        Node := Following;
      end;
    end;
    O.Fields[BucketsKey] := TJVMValue.Ref(Ref);
    O.Fields[ThresholdKey] := TJVMValue.Int(Integer(NewCapacity * 3 div 4));
    Bump(O);
    Exit;
  end;
  if N = '$replace' then
  begin
    Entry := VM.GetObject(Args[1].AsRef);
    Result := Entry.Fields[ValueKey];
    Entry.Fields[ValueKey] := Args[2];
    Bump(O);
    Exit;
  end;
  if N = '$add' then
  begin
    // Allocate and initialize before mutating the table/count.
    Ref := VM.NewObject(EntryName);
    Entry := VM.GetObject(Ref);
    Index := Bucket(Args[3].AsInt, Length(Table.Elements));
    Entry.Fields[HashKey] := Args[3];
    Entry.Fields[KeyKey] := Args[1];
    Entry.Fields[ValueKey] := Args[2];
    Entry.Fields[NextKey] := Table.Elements[Index];
    Table.Elements[Index] := TJVMValue.Ref(Ref);
    O.Fields[CountKey] := TJVMValue.Int(Count + 1);
    Bump(O);
    Exit(TJVMValue.Ref(0));
  end;
  if N = '$delete' then
  begin
    Ref := Args[1].AsRef;
    Index := Bucket(Args[2].AsInt, Length(Table.Elements));
    var Previous := 0;
    var Node := Table.Elements[Index].AsRef;
    while Node <> 0 do
    begin
      Entry := VM.GetObject(Node);
      if Node = Ref then
      begin
        Result := Entry.Fields[ValueKey];
        if Previous = 0 then
          Table.Elements[Index] := Entry.Fields[NextKey]
        else
          VM.GetObject(Previous).Fields[NextKey] := Entry.Fields[NextKey];
        Entry.Fields[ValueKey] := TJVMValue.Ref(0);
        O.Fields[CountKey] := TJVMValue.Int(Count - 1);
        Bump(O);
        Exit;
      end;
      Previous := Node;
      Node := GetRef(Entry, NextKey);
    end;
    raise EJVMError.Create('Hashtable selected entry disappeared');
  end;
  raise EJVMUnsupported.Create('Hashtable native method: ' + N);
end;

function JavaNewIntegerKeyTable(VM: TJVM; const Keys, Values: TArray<Integer>): Integer;
begin
  if Length(Keys) <> Length(Values) then
    raise EJVMFormatError.Create('Integer-key table lengths');
  for var Value in Values do
    VM.GetObject(Value); // Hashtable values cannot be null.
  var Seen := TDictionary<Integer, Boolean>.Create;
  try
    for var K in Keys do
    begin
      if Seen.ContainsKey(K) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Duplicate integer table key');
      Seen.Add(K, True);
    end;
  finally
    Seen.Free;
  end;
  Result := VM.NewObject(TableName);
  VM.AddRoot(Result);
  try
    var C := VM.LoadClass(TableName);
    var Number := VM.LoadClass('java/lang/Integer');
    InvokeJavaHashtable(VM, C.FindMethod('<init>', '(I)V'), [TJVMValue.Ref(Result), TJVMValue.Int(Length(Keys) * 2 + 1)]);
    for var K := 0 to High(Keys) do
    begin
      var Key := VM.NewObject(Number.Name);
      InvokeJavaInteger(VM, Number.FindMethod('<init>', '(I)V'), [TJVMValue.Ref(Key), TJVMValue.Int(Keys[K])]);
      InvokeJavaHashtable(VM, C.FindMethod('$add', '(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;'),
        [TJVMValue.Ref(Result), TJVMValue.Ref(Key), TJVMValue.Ref(Values[K]), TJVMValue.Int(Keys[K])]);
    end;
  finally
    VM.RemoveRoot(Result);
  end;
end;

end.

