unit J2ME.Text;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2METext(VM: TJVM);

function InvokeJ2METext(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Changed: Boolean): TJVMValue;

function J2METextValid(const Text: string; Constraints: Integer): Boolean;

procedure J2METextBegin(VM: TJVM; O: TJVMObject);

function J2METextUserInsert(VM: TJVM; O: TJVMObject; const Text: string): Boolean;

function J2METextKey(VM: TJVM; O: TJVMObject; Code: Integer; Now: Int64; out Changed: Boolean): Boolean;

function J2METextDisplay(VM: TJVM; O: TJVMObject): string;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, Java.Numbers, J2ME.UI.Data;

{$Q-}{$R-}

const
  FieldName = J2MEUI + 'TextField';
  BoxName = J2MEUI + 'TextBox';

function ValidConstraints(Value: Integer): Boolean;
begin
  Result := ((Value and $FFFF) <= 5) and ((Value and not $3FFFFF) = 0);
end;

function J2METextValid(const Text: string; Constraints: Integer): Boolean;
begin
  Result := False;
  if not ValidConstraints(Constraints) then
    Exit;
  var Kind := Constraints and $FFFF;
  if (Text = '') or (Kind in [0, 1, 4]) then
    Exit(True);
  if Kind = 3 then
  begin
    for var C in Text do
      if not CharInSet(C, ['0'..'9', '+', '*', '#', 'p', 'P', 'w', 'W', ',', ';', ' ', '-', '(', ')', '.']) then
        Exit;
    Exit(True);
  end;
  var I := 1;
  var Negative := Text[1] = '-';
  if Negative then
    Inc(I);
  if I > Length(Text) then
    Exit;
  if Kind = 2 then
  begin
    var Magnitude := Int64(0);
    var Limit := Int64(MaxInt);
    if Negative then
      Inc(Limit);
    while I <= Length(Text) do
    begin
      var D := JavaIntegerDigit(Text[I]);
      if (D < 0) or (D > 9) or (Magnitude > (Limit - D) div 10) then
        Exit;
      Magnitude := Magnitude * 10 + D;
      Inc(I);
    end;
    Exit(True);
  end;
  var Digits := 0;
  var Dot := False;
  while I <= Length(Text) do
  begin
    var C := Text[I];
    Inc(I);
    if C = '.' then
    begin
      if Dot then
        Exit;
      Dot := True;
    end
    else
    begin
      if not CharInSet(C, ['0'..'9']) then
        Exit;
      Inc(Digits);
    end;
  end;
  Result := Digits > 0;
end;

procedure InstallJ2METext(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Native(const Name, Desc: string);
  begin
    B.JavaClass.AddNative(Name, Desc);
  end;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  for var Name in [FieldName, BoxName] do
  begin
    var Parent := J2MEUI + 'Item';
    if Name = BoxName then
      Parent := J2MEUI + 'Screen';
    B := TJavaClassBuilder.Create(Name, Parent);
    try
      if Name = FieldName then
      begin
        Constant('ANY', 0);
        Constant('EMAILADDR', 1);
        Constant('NUMERIC', 2);
        Constant('PHONENUMBER', 3);
        Constant('URL', 4);
        Constant('DECIMAL', 5);
        Constant('CONSTRAINT_MASK', $FFFF);
        Constant('PASSWORD', $10000);
        Constant('UNEDITABLE', $20000);
        Constant('SENSITIVE', $40000);
        Constant('NON_PREDICTIVE', $80000);
        Constant('INITIAL_CAPS_WORD', $100000);
        Constant('INITIAL_CAPS_SENTENCE', $200000);
      end;
      Native('<init>', '(Ljava/lang/String;Ljava/lang/String;II)V');
      Native('getString', '()Ljava/lang/String;');
      Native('setString', '(Ljava/lang/String;)V');
      Native('getChars', '([C)I');
      Native('setChars', '([CII)V');
      Native('insert', '(Ljava/lang/String;I)V');
      Native('insert', '([CIII)V');
      Native('delete', '(II)V');
      for var N in ['getMaxSize', 'size', 'getCaretPosition', 'getConstraints'] do
        Native(N, '()I');
      Native('setMaxSize', '(I)I');
      Native('setConstraints', '(I)V');
      Native('setInitialInputMode', '(Ljava/lang/String;)V');
      VM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
  end;
end;

procedure Store(VM: TJVM; O: TJVMObject; const Text: string; Caret: Integer);
begin
  var Ref := VM.NewString(Text);
  UIPutRef(O, 'text', Ref);
  UIPut(O, 'caret', EnsureRange(Caret, 0, Length(Text)));
  UIPut(O, 'tapKey', 0);
  UIPut(O, 'negativePending', 0);
end;

function InvokeJ2METext(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; out Changed: Boolean): TJVMValue;
var
  O: TJVMObject;
  N, Text, Value: string;
  Offset, Count, Position: Integer;

  procedure CheckValue(const Candidate: string; Maximum, Constraints: Integer);
  begin
    if (Length(Candidate) > Maximum) or not J2METextValid(Candidate, Constraints) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Text capacity or constraints');
  end;

  function Capacity(Requested: Integer): Integer;
  begin
    if Requested <= 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Text maximum');
    if VM.MaxArrayLength < 1 then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Text capacity limit');
    Result := Min(Requested, VM.MaxArrayLength);
  end;

  function Chars(Ref, Offset, Count: Integer): string;
  begin
    var A := VM.GetObject(Ref);
    if (Offset < 0) or (Count < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    SetLength(Result, Count);
    for var I := 0 to Count - 1 do
      Result[I + 1] := Char(A.Elements[Offset + I].AsInt);
  end;

begin
  Result := Default(TJVMValue);
  Changed := False;
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  Text := UIString(VM, UIRef(O, 'text'));
  if N = '<init>' then
  begin
    var Maximum := Capacity(Args[3].AsInt);
    var Constraints := Args[4].AsInt;
    if not ValidConstraints(Constraints) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Text constraints');
    Text := UIString(VM, Args[2].AsRef);
    CheckValue(Text, Args[3].AsInt, Constraints);
    Value := Copy(Text, 1, Maximum);
    // An implementation capacity smaller than requested must not leave an
    // incomplete signed/decimal prefix as the constructor's actual contents.
    while not J2METextValid(Value, Constraints) do
      SetLength(Value, Length(Value) - 1);
    Store(VM, O, Value, Length(Value));
    UIPut(O, 'maximum', Maximum);
    UIPut(O, 'constraints', Constraints);
    if Method.Owner.Name = FieldName then
    begin
      UIInitItem(O, Args[1].AsRef);
      UIPut(O, 'itemKind', 5);
    end
    else
      UIPutRef(O, 'title', Args[1].AsRef);
    Exit;
  end;
  if N = 'getString' then
    Exit(TJVMValue.Ref(UIRef(O, 'text')));
  if N = 'getMaxSize' then
    Exit(TJVMValue.Int(UIInt(O, 'maximum')));
  if N = 'size' then
    Exit(TJVMValue.Int(Length(Text)));
  if N = 'getCaretPosition' then
    Exit(TJVMValue.Int(UIInt(O, 'caret')));
  if N = 'getConstraints' then
    Exit(TJVMValue.Int(UIInt(O, 'constraints')));
  if N = 'getChars' then
  begin
    var A := VM.GetObject(Args[1].AsRef);
    if Length(A.Elements) < Length(Text) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    for var I := 1 to Length(Text) do
      A.Elements[I - 1] := TJVMValue.Int(Ord(Text[I]));
    Exit(TJVMValue.Int(Length(Text)));
  end;
  if N = 'setInitialInputMode' then
  begin
    UIPutRef(O, 'inputHint', Args[1].AsRef);
    Exit;
  end;
  var Maximum := UIInt(O, 'maximum');
  var Constraints := UIInt(O, 'constraints');
  var Caret := UIInt(O, 'caret');
  if N = 'setConstraints' then
  begin
    var New := Args[1].AsInt;
    if not ValidConstraints(New) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Text constraints');
    Value := Text;
    if not J2METextValid(Value, New) then
      Value := '';
    Store(VM, O, Value, Min(Caret, Length(Value)));
    UIPut(O, 'constraints', New);
    Changed := True;
    Exit;
  end;
  if N = 'setMaxSize' then
  begin
    var New := Capacity(Args[1].AsInt);
    Value := Copy(Text, 1, New);
    CheckValue(Value, New, Constraints);
    Store(VM, O, Value, Min(Caret, Length(Value)));
    UIPut(O, 'maximum', New);
    Changed := True;
    Exit(TJVMValue.Int(New));
  end;
  if N = 'setString' then
  begin
    Value := UIString(VM, Args[1].AsRef);
    Caret := Length(Value);
  end
  else if N = 'setChars' then
  begin
    Value := '';
    if Args[1].AsRef <> 0 then
      Value := Chars(Args[1].AsRef, Args[2].AsInt, Args[3].AsInt);
    Caret := Length(Value);
  end
  else if N = 'insert' then
  begin
    if Args[1].AsRef = 0 then
      VM.GetObject(0);
    if Length(Args) = 3 then
    begin
      Value := UIString(VM, Args[1].AsRef);
      Position := Args[2].AsInt;
    end
    else
    begin
      Value := Chars(Args[1].AsRef, Args[2].AsInt, Args[3].AsInt);
      Position := Args[4].AsInt;
    end;
    if Length(Value) > Maximum - Length(Text) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Text capacity');
    Position := EnsureRange(Position, 0, Length(Text));
    Caret := Position + Length(Value);
    Value := Copy(Text, 1, Position) + Value + Copy(Text, Position + 1, MaxInt);
  end
  else if N = 'delete' then
  begin
    Offset := Args[1].AsInt;
    Count := Args[2].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Length(Text)) or (Count > Length(Text) - Offset) then
      VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
    Value := Copy(Text, 1, Offset) + Copy(Text, Offset + Count + 1, MaxInt);
    Caret := Max(Offset, Caret - Count);
    if UIInt(O, 'caret') <= Offset then
      Caret := UIInt(O, 'caret');
  end
  else
    raise EJVMUnsupported.Create('Text method: ' + N);
  CheckValue(Value, Maximum, Constraints);
  Store(VM, O, Value, Caret);
  Changed := True;
end;

procedure J2METextBegin(VM: TJVM; O: TJVMObject);
begin
  var Hint := UIString(VM, UIRef(O, 'inputHint'));
  var Mode := 0;
  if Hint = 'MIDP_UPPERCASE_LATIN' then
    Mode := 1
  else if (Hint = 'IS_LATIN_DIGITS') then
    Mode := 2;
  UIPut(O, 'inputMode', Mode);
  UIPut(O, 'editing', 1);
  UIPut(O, 'tapKey', 0);
  UIPut(O, 'negativePending', 0);
end;

function J2METextDisplay(VM: TJVM; O: TJVMObject): string;
begin
  Result := UIString(VM, UIRef(O, 'text'));
  if (UIInt(O, 'constraints') and $10000) <> 0 then
    Result := StringOfChar('*', Length(Result))
  else if UIInt(O, 'negativePending') <> 0 then
    Result := '-' + Result;
end;

function J2METextUserInsert(VM: TJVM; O: TJVMObject; const Text: string): Boolean;
begin
  Result := False;
  if (UIInt(O, 'constraints') and $20000) <> 0 then
    Exit;
  var Old := UIString(VM, UIRef(O, 'text'));
  var Caret := EnsureRange(UIInt(O, 'caret'), 0, Length(Old));
  if Length(Text) > UIInt(O, 'maximum') - Length(Old) then
    Exit;
  var Value := Copy(Old, 1, Caret) + Text + Copy(Old, Caret + 1, MaxInt);
  if (Length(Value) > UIInt(O, 'maximum')) or not J2METextValid(Value, UIInt(O, 'constraints')) then
    Exit;
  if Value = Old then
    Exit;
  Store(VM, O, Value, Caret + Length(Text));
  Result := True;
end;

function J2METextKey(VM: TJVM; O: TJVMObject; Code: Integer; Now: Int64; out Changed: Boolean): Boolean;
begin
  Result := True;
  Changed := False;
  var Constraints := UIInt(O, 'constraints');
  var Kind := Constraints and $FFFF;
  var Old := UIString(VM, UIRef(O, 'text'));
  var Caret := EnsureRange(UIInt(O, 'caret'), 0, Length(Old));
  if UIInt(O, 'editing') = 0 then
    J2METextBegin(VM, O);
  if (Code = -3) or (Code = -4) or (Code = -1001) or (Code = -1002) then
  begin
    if Code = -1001 then
      Caret := 0
    else if Code = -1002 then
      Caret := Length(Old)
    else if Code = -3 then
    begin
      if Caret > 0 then
      begin
        Dec(Caret);
        if (Caret > 0) and (Ord(Old[Caret + 1]) >= $DC00) and (Ord(Old[Caret + 1]) <= $DFFF) and
          (Ord(Old[Caret]) >= $D800) and (Ord(Old[Caret]) <= $DBFF) then
          Dec(Caret);
      end;
    end
    else if Caret < Length(Old) then
    begin
      Inc(Caret);
      if (Caret < Length(Old)) and (Ord(Old[Caret]) >= $D800) and (Ord(Old[Caret]) <= $DBFF) and
        (Ord(Old[Caret + 1]) >= $DC00) and (Ord(Old[Caret + 1]) <= $DFFF) then
        Inc(Caret);
    end;
    UIPut(O, 'caret', Caret);
    UIPut(O, 'tapKey', 0);
    Exit;
  end;
  if (Constraints and $20000) <> 0 then
    Exit;
  var Value := Old;
  var Group := '';
  var Replace: Boolean;
  var Tap := 0;
  if Code = -8 then
  begin
    if Caret = 0 then
    begin
      UIPut(O, 'negativePending', 0);
      Exit;
    end;
    var First := Caret - 1;
    if (First > 0) and (Ord(Old[First + 1]) >= $DC00) and (Ord(Old[First + 1]) <= $DFFF) and
      (Ord(Old[First]) >= $D800) and (Ord(Old[First]) <= $DBFF) then
      Dec(First);
    Value := Copy(Old, 1, First) + Copy(Old, Caret + 1, MaxInt);
    Caret := First;
    if ((Kind = 2) or (Kind = 5)) and (Value = '-') then
    begin
      Value := '';
      Caret := 0;
    end;
  end
  else if (Code = 42) and ((Kind = 2) or (Kind = 5)) then
  begin
    if Old = '' then
    begin
      UIPut(O, 'negativePending', 1 - UIInt(O, 'negativePending'));
      Exit;
    end;
    if Old[1] = '-' then
    begin
      Value := Copy(Old, 2, MaxInt);
      Caret := Max(0, Caret - 1);
    end
    else
    begin
      Value := '-' + Old;
      Inc(Caret);
    end;
  end
  else
  begin
    var Literal := '';
    if Code <= -10000 then
    begin
      var C := -Int64(Code) - 10000;
      if (C >= 0) and (C <= $FFFF) then
        Literal := Char(C);
    end
    else if (Code >= 48) and (Code <= 57) then
    begin
      if (Kind = 2) or (Kind = 3) or (Kind = 5) or (UIInt(O, 'inputMode') = 2) then
        Literal := Char(Code)
      else
        case Code of
          48:
            Group := ' 0';
          49:
            Group := '.,?!1@-:/+#*' + #10;
          50:
            Group := 'abc2';
          51:
            Group := 'def3';
          52:
            Group := 'ghi4';
          53:
            Group := 'jkl5';
          54:
            Group := 'mno6';
          55:
            Group := 'pqrs7';
          56:
            Group := 'tuv8';
          57:
            Group := 'wxyz9';
        end;
    end
    else if (Code = 35) and (Kind = 5) then
    begin
      Literal := '.';
      if Old = '' then
        Literal := '0.';
    end
    else if (Code = 35) and (Kind <> 3) and (Kind <> 2) then
    begin
      UIPut(O, 'inputMode', (UIInt(O, 'inputMode') + 1) mod 3);
      UIPut(O, 'tapKey', 0);
      Exit;
    end
    else if (Code = 42) or (Code = 35) then
      Literal := Char(Code)
    else if Code = -5 then
    begin
      UIPut(O, 'tapKey', 0);
      Exit;
    end
    else
      Exit(False);
    if Group <> '' then
    begin
      Replace := (UIInt(O, 'tapKey') = Code) and (Now >= UILong(O, 'tapTime')) and (Now - UILong(O, 'tapTime') < 800) and
        (UIInt(O, 'tapPosition') + 1 = Caret) and (Caret > 0);
      if Replace then
        Tap := (UIInt(O, 'tapIndex') + 1) mod Length(Group);
      Literal := Group[Tap + 1];
      if Replace then
      begin
        Value := Copy(Old, 1, Caret - 1) + Copy(Old, Caret + 1, MaxInt);
        Dec(Caret);
      end;
    end;
    if Literal = '' then
      Exit;
    if (UIInt(O, 'inputMode') = 1) and CharInSet(Literal[1], ['a'..'z']) then
      Literal[1] := Char(Ord(Literal[1]) - 32);
    if ((Constraints and $10000) = 0) and (UIInt(O, 'inputMode') = 0) and CharInSet(Literal[1], ['a'..'z']) then
    begin
      var Capital := False;
      if (Constraints and $100000) <> 0 then
        Capital := (Caret = 0) or CharInSet(Value[Caret], [' ', #10, #13, #9]);
      if (Constraints and $200000) <> 0 then
      begin
        var I := Caret;
        while (I > 0) and CharInSet(Value[I], [' ', #10, #13, #9]) do
          Dec(I);
        Capital := Capital or (I = 0) or CharInSet(Value[I], ['.', '!', '?']);
      end;
      if Capital then
        Literal[1] := Char(Ord(Literal[1]) - 32);
    end;
    if UIInt(O, 'negativePending') <> 0 then
      Literal := '-' + Literal;
    Value := Copy(Value, 1, Caret) + Literal + Copy(Value, Caret + 1, MaxInt);
    Inc(Caret, Length(Literal));
  end;
  if (Length(Value) > UIInt(O, 'maximum')) or not J2METextValid(Value, Constraints) then
    Exit;
  if Value = Old then
    Exit;
  Store(VM, O, Value, Caret);
  Changed := True;
  if Group <> '' then
  begin
    UIPut(O, 'tapKey', Code);
    UIPut(O, 'tapIndex', Tap);
    UIPut(O, 'tapPosition', Caret - 1);
    UIPutLong(O, 'tapTime', Now);
  end;
end;

end.

