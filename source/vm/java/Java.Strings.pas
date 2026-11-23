unit Java.Strings;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaStringMethods(C: TJVMClass);

function TryInvokeJavaString(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string; out Value: TJVMValue): Boolean;

implementation

uses
  System.SysUtils, System.Math, Java.Charsets, Java.Unicode, Java.Floating.Text;

{$Q-}{$R-}

procedure InstallJavaStringMethods(C: TJVMClass);
begin
  C.AddNative('<init>', '([C)V');
  C.AddNative('<init>', '([CII)V');
  C.AddNative('toCharArray', '()[C');
  C.AddNative('getChars', '(II[CI)V');
  for var D in ['([B)V', '([BII)V', '([BLjava/lang/String;)V', '([BIILjava/lang/String;)V', '(Ljava/lang/StringBuffer;)V'] do
    C.AddNative('<init>', D);
  for var D in ['I', 'J', 'F', 'D', 'Z', 'C', '[C', '[CII', 'Ljava/lang/Object;'] do
    C.AddNative('valueOf', '(' + D + ')Ljava/lang/String;', True);
  C.AddNative('getBytes', '()[B');
  C.AddNative('getBytes', '(Ljava/lang/String;)[B');
  for var N in ['indexOf', 'lastIndexOf'] do
    for var D in ['(I)I', '(II)I', '(Ljava/lang/String;)I', '(Ljava/lang/String;I)I'] do
      C.AddNative(N, D);
  C.AddNative('compareTo', '(Ljava/lang/String;)I');
  C.AddNative('equalsIgnoreCase', '(Ljava/lang/String;)Z');
  C.AddNative('startsWith', '(Ljava/lang/String;)Z');
  C.AddNative('startsWith', '(Ljava/lang/String;I)Z');
  C.AddNative('endsWith', '(Ljava/lang/String;)Z');
  C.AddNative('regionMatches', '(ILjava/lang/String;II)Z');
  C.AddNative('regionMatches', '(ZILjava/lang/String;II)Z');
  C.AddNative('replace', '(CC)Ljava/lang/String;');
  C.AddNative('trim', '()Ljava/lang/String;');
  C.AddNative('toLowerCase', '()Ljava/lang/String;');
  C.AddNative('toUpperCase', '()Ljava/lang/String;');
end;

function Find(const Text, Pattern: string; FromIndex: Integer; Reverse: Boolean): Integer;
var
  Start, Limit, I, J: Integer;
  Border: TArray<Integer>;
begin
  Result := -1;
  if Reverse then
  begin
    if FromIndex < 0 then
      Exit;
    Start := 0;
    Limit := Min(FromIndex, Length(Text) - Length(Pattern));
  end
  else
  begin
    Start := Max(0, FromIndex);
    Limit := Length(Text) - Length(Pattern);
  end;
  if Pattern = '' then
  begin
    if Reverse then
      Result := Min(FromIndex, Length(Text))
    else
      Result := Min(Start, Length(Text));
    Exit;
  end;
  if (Start > Limit) or (Limit < 0) then
    Exit;
  // KMP keeps adversarial repeated-prefix strings linear in native execution.
  SetLength(Border, Length(Pattern));
  J := 0;
  for I := 1 to Length(Pattern) - 1 do
  begin
    while (J > 0) and (Pattern[I + 1] <> Pattern[J + 1]) do
      J := Border[J - 1];
    if Pattern[I + 1] = Pattern[J + 1] then
      Inc(J);
    Border[I] := J;
  end;
  J := 0;
  for I := Start to Limit + Length(Pattern) - 1 do
  begin
    while (J > 0) and (Text[I + 1] <> Pattern[J + 1]) do
      J := Border[J - 1];
    if Text[I + 1] = Pattern[J + 1] then
      Inc(J);
    if J = Length(Pattern) then
    begin
      Result := I - J + 1;
      if not Reverse then
        Exit;
      J := Border[J - 1];
    end;
  end;
end;

function EqualChar(A, B: Char; IgnoreCase: Boolean): Boolean;
begin
  if A = B then
    Exit(True);
  if not IgnoreCase then
    Exit(False);
  // CLDC compares the original characters' uppercase OR lowercase mappings.
  Result := (JavaCharUpper(A) = JavaCharUpper(B)) or (JavaCharLower(A) = JavaCharLower(B));
end;

function Region(const A, B: string; AStart, BStart, Count: Integer; IgnoreCase: Boolean): Boolean;
begin
  if (AStart < 0) or (BStart < 0) or (Int64(AStart) > Int64(Length(A)) - Count) or (Int64(BStart) > Int64(Length(B)) - Count) then
    Exit(False);
  if Count <= 0 then
    Exit(True);
  for var I := 0 to Count - 1 do
    if not EqualChar(A[AStart + I + 1], B[BStart + I + 1], IgnoreCase) then
      Exit(False);
  Result := True;
end;

function TryInvokeJavaString(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string; out Value: TJVMValue): Boolean;
var
  N, D, Text, Other: string;
  O, A: TJVMObject;
  Start, Count, I, J, FromIndex, RefValue: Integer;
  IgnoreCase, Match: Boolean;
  Data: TBytes;
  Charset: TJavaCharset;
begin
  N := Method.Name;
  D := Method.Descriptor;
  Value := Default(TJVMValue);
  Result := True;
  if N = 'valueOf' then
  begin
    if D = '(Ljava/lang/Object;)Ljava/lang/String;' then
    begin
      if VM.TakeGuestResult(Value) then
        Exit;
      RefValue := Args[0].AsRef;
      if RefValue = 0 then
        Value := TJVMValue.Ref(VM.InternString('null'))
      else
        VM.InvokeGuestResult(VM.ResolveVirtualMethod(RefValue, VM.LoadClass('java/lang/Object').FindMethod('toString', '()Ljava/lang/String;')), [Args[0]]);
      Exit;
    end;
    if D.StartsWith('([C') then
    begin
      A := VM.GetObject(Args[0].AsRef);
      Start := 0;
      Count := Length(A.Elements);
      if Length(Args) = 3 then
      begin
        Start := Args[1].AsInt;
        Count := Args[2].AsInt;
      end;
      if (Start < 0) or (Count < 0) or (Start > Length(A.Elements)) or (Count > Length(A.Elements) - Start) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      SetLength(Text, Count);
      for I := 0 to Count - 1 do
        Text[I + 1] := Char(A.Elements[Start + I].AsInt);
    end
    else
      case D[2] of
        'I':
          Text := IntToStr(Args[0].AsInt);
        'J':
          Text := IntToStr(Args[0].AsLong);
        'F':
          Text := JavaFloatingText(UInt64(Args[0].Bits), True);
        'D':
          Text := JavaFloatingText(UInt64(Args[0].Bits), False);
        'C':
          Text := Char(Args[0].AsInt);
        'Z':
          if Args[0].AsInt = 0 then
            Text := 'false'
          else
            Text := 'true';
      else
        Exit(False);
      end;
    if D[2] = 'Z' then
      Value := TJVMValue.Ref(VM.InternString(Text))
    else
      Value := TJVMValue.Ref(VM.NewString(Text));
    Exit;
  end;
  if (N = '<init>') and (D = '(Ljava/lang/StringBuffer;)V') then
  begin
    if VM.TakeGuestResult(Value) then
      VM.GetObject(Args[0].AsRef).Text := VM.GetObject(Value.AsRef).Text
    else
    begin
      RefValue := Args[1].AsRef;
      VM.GetObject(RefValue);
      VM.InvokeGuestResult(VM.ResolveMethod(VM.LoadClass('java/lang/StringBuffer'), 'toString', '()Ljava/lang/String;'), [Args[1]]);
    end;
    Exit;
  end;
  if not ((N = 'indexOf') or (N = 'lastIndexOf') or (N = 'compareTo') or (N = 'equalsIgnoreCase') or
    (N = 'startsWith') or (N = 'endsWith') or (N = 'regionMatches') or (N = 'replace') or (N = 'trim') or
    (N = 'toLowerCase') or (N = 'toUpperCase') or (N = 'getChars') or (N = 'toCharArray') or (N = 'getBytes') or
    ((N = '<init>') and (D.StartsWith('([C') or D.StartsWith('([B')))) then
    Exit(False);
  O := VM.GetObject(Args[0].AsRef);
  Text := O.Text;
  if (N = 'getBytes') or ((N = '<init>') and D.StartsWith('([B')) then
  begin
    Other := DefaultEncoding;
    if ((N = 'getBytes') and (Length(Args) = 2)) or ((N = '<init>') and D.EndsWith('Ljava/lang/String;)V')) then
      Other := VM.GetObject(Args[High(Args)].AsRef).Text;
    Charset := JavaCharset(VM, Other);
    if N = 'getBytes' then
    begin
      Data := JavaEncode(VM, Text, Charset);
      RefValue := VM.NewArray('[B', Length(Data));
      A := VM.GetObject(RefValue);
      for I := 0 to High(Data) do
        A.Elements[I] := TJVMValue.Int(ShortInt(Data[I]));
      Value := TJVMValue.Ref(RefValue);
    end
    else
    begin
      A := VM.GetObject(Args[1].AsRef);
      Start := 0;
      Count := Length(A.Elements);
      if D.StartsWith('([BII') then
      begin
        Start := Args[2].AsInt;
        Count := Args[3].AsInt;
      end;
      if (Start < 0) or (Count < 0) or (Start > Length(A.Elements)) or (Count > Length(A.Elements) - Start) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      SetLength(Data, Count);
      for I := 0 to Count - 1 do
        Data[I] := Byte(A.Elements[Start + I].AsInt);
      O.Text := JavaDecode(VM, Data, Charset);
    end;
    Exit;
  end;
  if (N = '<init>') and D.StartsWith('([C') then
  begin
    A := VM.GetObject(Args[1].AsRef);
    Start := 0;
    Count := Length(A.Elements);
    if Length(Args) = 4 then
    begin
      Start := Args[2].AsInt;
      Count := Args[3].AsInt;
    end;
    if (Start < 0) or (Count < 0) or (Start > Length(A.Elements)) or (Count > Length(A.Elements) - Start) then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    SetLength(Text, Count);
    for I := 0 to Count - 1 do
      Text[I + 1] := Char(A.Elements[Start + I].AsInt);
    O.Text := Text;
    Exit;
  end;
  if N = 'toCharArray' then
  begin
    RefValue := VM.NewArray('[C', Length(Text));
    A := VM.GetObject(RefValue);
    for I := 1 to Length(Text) do
      A.Elements[I - 1] := TJVMValue.Int(Ord(Text[I]));
    Value := TJVMValue.Ref(RefValue);
    Exit;
  end;
  if N = 'getChars' then
  begin
    Start := Args[1].AsInt;
    Count := Args[2].AsInt;
    if (Start < 0) or (Count < Start) or (Count > Length(Text)) then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    Dec(Count, Start);
    A := VM.GetObject(Args[3].AsRef);
    J := Args[4].AsInt;
    if (J < 0) or (J > Length(A.Elements)) or (Count > Length(A.Elements) - J) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    for I := 0 to Count - 1 do
      A.Elements[J + I] := TJVMValue.Int(Ord(Text[Start + I + 1]));
    Exit;
  end;
  if (N = 'indexOf') or (N = 'lastIndexOf') then
  begin
    FromIndex := 0;
    if N = 'lastIndexOf' then
      FromIndex := Length(Text);
    if Length(Args) = 3 then
      FromIndex := Args[2].AsInt;
    if D.StartsWith('(I') then
    begin
      I := Args[1].AsInt;
      if (I < 0) or (I > $10FFFF) then
      begin
        Value := TJVMValue.Int(-1);
        Exit;
      end;
      if I <= $FFFF then
        Other := Char(I)
      else
      begin
        Dec(I, $10000);
        Other := Char($D800 or (I shr 10)) + Char($DC00 or (I and $3FF));
      end;
    end
    else
      Other := VM.GetObject(Args[1].AsRef).Text;
    Value := TJVMValue.Int(Find(Text, Other, FromIndex, N = 'lastIndexOf'));
    Exit;
  end;
  if N = 'compareTo' then
  begin
    Other := VM.GetObject(Args[1].AsRef).Text;
    I := 1;
    while (I <= Min(Length(Text), Length(Other))) and (Text[I] = Other[I]) do
      Inc(I);
    if I <= Min(Length(Text), Length(Other)) then
      J := Ord(Text[I]) - Ord(Other[I])
    else
      J := Length(Text) - Length(Other);
    Value := TJVMValue.Int(J);
    Exit;
  end;
  if (N = 'startsWith') or (N = 'endsWith') or (N = 'equalsIgnoreCase') then
  begin
    if (N = 'equalsIgnoreCase') and (Args[1].AsRef = 0) then
    begin
      Value := TJVMValue.Int(0);
      Exit;
    end;
    Other := VM.GetObject(Args[1].AsRef).Text;
    Start := 0;
    if Length(Args) = 3 then
      Start := Args[2].AsInt;
    if N = 'endsWith' then
      Start := Length(Text) - Length(Other);
    Match := Region(Text, Other, Start, 0, Length(Other), N = 'equalsIgnoreCase');
    if N = 'equalsIgnoreCase' then
      Match := Match and (Length(Text) = Length(Other));
    Value := TJVMValue.Int(Ord(Match));
    Exit;
  end;
  if N = 'regionMatches' then
  begin
    I := 1;
    IgnoreCase := D.StartsWith('(Z');
    if IgnoreCase then
    begin
      IgnoreCase := Args[1].AsInt <> 0;
      Inc(I);
    end;
    Start := Args[I].AsInt;
    Other := VM.GetObject(Args[I + 1].AsRef).Text;
    Value := TJVMValue.Int(Ord(Region(Text, Other, Start, Args[I + 2].AsInt, Args[I + 3].AsInt, IgnoreCase)));
    Exit;
  end;
  if N = 'trim' then
  begin
    I := 1;
    J := Length(Text);
    while (I <= J) and (Ord(Text[I]) <= 32) do
      Inc(I);
    while (J >= I) and (Ord(Text[J]) <= 32) do
      Dec(J);
    Text := Copy(Text, I, J - I + 1);
  end
  else if N = 'replace' then
  begin
    for I := 1 to Length(Text) do
      if Text[I] = Char(Args[1].AsInt) then
        Text[I] := Char(Args[2].AsInt);
  end
  else
  begin
    for I := 1 to Length(Text) do
      if N = 'toLowerCase' then
        Text[I] := JavaCharLower(Text[I])
      else
        Text[I] := JavaCharUpper(Text[I]);
  end;
  if Text = O.Text then
    Value := Args[0]
  else
    Value := TJVMValue.Ref(VM.NewString(Text));
end;

end.

