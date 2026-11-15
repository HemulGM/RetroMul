unit Java.Builders;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaBuilders(VM: TJVM);

function InvokeJavaBuilder(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, System.Math;

{$Q-}{$R-}

procedure InstallJavaBuilders(VM: TJVM);
begin
  for var Name in ['StringBuffer', 'StringBuilder'] do
  begin
    var C := TJVMClass.Create;
    C.Name := 'java/lang/' + Name;
    C.SuperName := 'java/lang/Object';
    C.Access := C.Access or JVM_ACC_FINAL;
    C.AddNative('<init>', '()V');
    C.AddNative('<init>', '(I)V');
    C.AddNative('<init>', '(Ljava/lang/String;)V');
    for var D in ['I', 'J', 'F', 'D', 'Z', 'C', 'Ljava/lang/String;', 'Ljava/lang/Object;', '[C', '[CII'] do
    begin
      C.AddNative('append', '(' + D + ')L' + C.Name + ';');
      C.AddNative('insert', '(I' + D + ')L' + C.Name + ';');
    end;
    C.AddNative('toString', '()Ljava/lang/String;');
    C.AddNative('length', '()I');
    C.AddNative('capacity', '()I');
    C.AddNative('ensureCapacity', '(I)V');
    C.AddNative('setLength', '(I)V');
    C.AddNative('charAt', '(I)C');
    C.AddNative('setCharAt', '(IC)V');
    C.AddNative('getChars', '(II[CI)V');
    C.AddNative('delete', '(II)L' + C.Name + ';');
    C.AddNative('deleteCharAt', '(I)L' + C.Name + ';');
    C.AddNative('reverse', '()L' + C.Name + ';');
    if Name = 'StringBuffer' then
      for var M in C.Methods do
        if M.Name <> '<init>' then
          M.Access := M.Access or JVM_ACC_SYNCHRONIZED;
    VM.DefineClass(C);
  end;
end;

function InvokeJavaBuilder(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O, A: TJVMObject;
  N, D, S, Kind: string;
  Count, I, J, At, Start, Size, Offset: Integer;
  V: TJVMValue;

  procedure SetCount(Value: Integer);
  begin
    Count := Value;
    O.Fields.AddOrSetValue('$builderCount', TJVMValue.Int(Value));
  end;

  procedure Reserve(Minimum: Int64; Exact: Boolean = False);
  var
    Target: Int64;
  begin
    if Minimum < 0 then
      VM.RaiseJava('java/lang/OutOfMemoryError');
    if not Exact and (Minimum <= Length(O.Text)) then
      Exit;
    Target := Minimum;
    if not Exact then
      Target := Max(Target, Int64(Length(O.Text)) * 2 + 2);
    if (Target > VM.MaxArrayLength) or (Target > High(Integer)) then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'String buffer capacity limit exceeded');
    SetLength(O.Text, Integer(Target));
  end;

  procedure CheckIndex(Index: Integer; AllowEnd: Boolean = False);
  begin
    if (Index < 0) or (Index > Count) or ((Index = Count) and not AllowEnd) then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  D := Method.Descriptor;
  Count := 0;
  if O.Fields.TryGetValue('$builderCount', V) then
    Count := V.AsInt;
  if N = '<init>' then
  begin
    S := '';
    I := 16;
    if D = '(I)V' then
    begin
      I := Args[1].AsInt;
      if I < 0 then
        VM.RaiseJava('java/lang/NegativeArraySizeException');
    end
    else if D = '(Ljava/lang/String;)V' then
    begin
      S := VM.GetObject(Args[1].AsRef).Text;
      I := Length(S);
    end;
    var Capacity := Int64(I);
    if D = '(Ljava/lang/String;)V' then
      Inc(Capacity, 16);
    Reserve(Capacity, True);
    if S <> '' then
    begin
      UniqueString(O.Text);
      Move(S[1], O.Text[1], Length(S) * SizeOf(Char));
    end;
    SetCount(Length(S));
    Exit;
  end;
  if N = 'length' then
    Exit(TJVMValue.Int(Count));
  if N = 'capacity' then
    Exit(TJVMValue.Int(Length(O.Text)));
  if N = 'toString' then
    Exit(TJVMValue.Ref(VM.NewString(Copy(O.Text, 1, Count))));
  if N = 'ensureCapacity' then
  begin
    I := Args[1].AsInt;
    if I > 0 then
      Reserve(I);
    Exit;
  end;
  if N = 'setLength' then
  begin
    I := Args[1].AsInt;
    if I < 0 then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    Reserve(I);
    UniqueString(O.Text);
    for J := Count + 1 to I do
      O.Text[J] := #0;
    SetCount(I);
    Exit;
  end;
  if (N = 'charAt') or (N = 'setCharAt') then
  begin
    I := Args[1].AsInt;
    CheckIndex(I);
    if N = 'charAt' then
      Exit(TJVMValue.Int(Ord(O.Text[I + 1])));
    O.Text[I + 1] := Char(Args[2].AsInt);
    Exit;
  end;
  if N = 'getChars' then
  begin
    I := Args[1].AsInt;
    J := Args[2].AsInt;
    CheckIndex(I, True);
    if (J < I) or (J > Count) then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    A := VM.GetObject(Args[3].AsRef);
    At := Args[4].AsInt;
    if (At < 0) or (At > Length(A.Elements)) or (J - I > Length(A.Elements) - At) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    for Offset := 0 to J - I - 1 do
      A.Elements[At + Offset] := TJVMValue.Int(Ord(O.Text[I + Offset + 1]));
    Exit;
  end;
  if (N = 'delete') or (N = 'deleteCharAt') then
  begin
    I := Args[1].AsInt;
    CheckIndex(I, N = 'delete');
    J := I + 1;
    if N = 'delete' then
      J := Args[2].AsInt;
    if J < I then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    J := Min(J, Count);
    UniqueString(O.Text);
    if J < Count then
      Move(O.Text[J + 1], O.Text[I + 1], (Count - J) * SizeOf(Char));
    SetCount(Count - (J - I));
    Exit(Args[0]);
  end;
  if N = 'reverse' then
  begin
    UniqueString(O.Text);
    for I := 1 to Count div 2 do
    begin
      var C := O.Text[I];
      O.Text[I] := O.Text[Count - I + 1];
      O.Text[Count - I + 1] := C;
    end;
    // CLDC StringBuffer reverses UTF-16 code units. The Java SE StringBuilder
    // extension additionally restores high/low surrogate pairs after reversal.
    if Method.Owner.Name = 'java/lang/StringBuilder' then
    begin
      I := 1;
      while I < Count do
      begin
        if (Ord(O.Text[I]) >= $DC00) and (Ord(O.Text[I]) <= $DFFF) and
          (Ord(O.Text[I + 1]) >= $D800) and (Ord(O.Text[I + 1]) <= $DBFF) then
        begin
          var C := O.Text[I];
          O.Text[I] := O.Text[I + 1];
          O.Text[I + 1] := C;
          Inc(I);
        end;
        Inc(I);
      end;
    end;
    Exit(Args[0]);
  end;
  if (N = 'append') or (N = 'insert') then
  begin
    Offset := 1;
    if N = 'insert' then
      Offset := 2;
    Kind := Copy(D, Offset + 1, Pos(')', D) - Offset - 1);
    V := Args[Offset];
    if Kind = 'Ljava/lang/Object;' then
    begin
      if not VM.TakeGuestResult(V) then
      begin
        VM.InvokeGuestResult(VM.LoadClass('java/lang/String').FindMethod('valueOf', '(Ljava/lang/Object;)Ljava/lang/String;'), [Args[Offset]]);
        Exit;
      end;
      S := 'null';
      if V.AsRef <> 0 then
        S := VM.GetObject(V.AsRef).Text;
    end
    else if Kind = 'Ljava/lang/String;' then
    begin
      S := 'null';
      if V.AsRef <> 0 then
        S := VM.GetObject(V.AsRef).Text;
    end
    else if Kind.StartsWith('[C') then
    begin
      if N = 'insert' then
        CheckIndex(Args[1].AsInt, True);
      A := VM.GetObject(V.AsRef);
      Start := 0;
      Size := Length(A.Elements);
      if Kind = '[CII' then
      begin
        Start := Args[Offset + 1].AsInt;
        Size := Args[Offset + 2].AsInt;
      end;
      if (Start < 0) or (Size < 0) or (Start > Length(A.Elements)) or (Size > Length(A.Elements) - Start) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException');
      SetLength(S, Size);
      for I := 0 to Size - 1 do
        S[I + 1] := Char(A.Elements[Start + I].AsInt);
    end
    else if Kind = 'Z' then
    begin
      if V.AsInt = 0 then
        S := 'false'
      else
        S := 'true';
    end
    else if Kind = 'C' then
      S := Char(V.AsInt)
    else
      case V.Kind of
        TJVMKind.Int:
          S := IntToStr(V.AsInt);
        TJVMKind.Long:
          S := IntToStr(V.AsLong);
        TJVMKind.Float:
          S := FloatToStr(V.AsFloat, TFormatSettings.Invariant);
        TJVMKind.Double:
          S := FloatToStr(V.AsDouble, TFormatSettings.Invariant);
      else
        raise EJVMError.Create('Unsupported string buffer argument');
      end;
    // Object conversion may have called back into this same buffer.
    Count := O.Fields['$builderCount'].AsInt;
    At := Count;
    if N = 'insert' then
    begin
      At := Args[1].AsInt;
      CheckIndex(At, True);
    end;
    Reserve(Int64(Count) + Length(S));
    UniqueString(O.Text);
    if (At < Count) and (S <> '') then
      Move(O.Text[At + 1], O.Text[At + Length(S) + 1], (Count - At) * SizeOf(Char));
    if S <> '' then
      Move(S[1], O.Text[At + 1], Length(S) * SizeOf(Char));
    SetCount(Count + Length(S));
    Exit(Args[0]);
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N + D);
end;

end.

