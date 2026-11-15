unit Java.Numbers;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

function JavaIntegerDigit(C: Char): Integer;

procedure InstallJavaNumbers(VM: TJVM);

function InvokeJavaSmallInteger(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function InvokeJavaInteger(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function InvokeJavaLong(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, Java.Classes, Java.Unicode;

{$Q-}{$R-}

const
  IntegerName = 'java/lang/Integer';
  ValueKey = IntegerName + '.value:I';

procedure InstallJavaNumbers(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create('java/lang/NumberFormatException', 'java/lang/IllegalArgumentException');
  try
    B.JavaClass.AddNative('<init>', '()V');
    B.JavaClass.AddNative('<init>', '(Ljava/lang/String;)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(IntegerName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
  try
    B.Field('value', 'I', JVM_ACC_PRIVATE or JVM_ACC_FINAL);
    for var Name in ['MIN_VALUE', 'MAX_VALUE'] do
    begin
      B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      var Value := Low(Integer);
      if Name = 'MAX_VALUE' then
        Value := High(Integer);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
    end;
    B.JavaClass.AddNative('<init>', '(I)V');
    for var D in ['I', 'J', 'F', 'D', 'B', 'S'] do
    begin
      var Name := 'intValue';
      case D of
        'J':
          Name := 'longValue';
        'F':
          Name := 'floatValue';
        'D':
          Name := 'doubleValue';
        'B':
          Name := 'byteValue';
        'S':
          Name := 'shortValue';
      end;
      B.JavaClass.AddNative(Name, '()' + D);
    end;
    B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
    B.JavaClass.AddNative('hashCode', '()I');
    B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
    B.JavaClass.AddNative('toString', '(I)Ljava/lang/String;', True);
    B.JavaClass.AddNative('toString', '(II)Ljava/lang/String;', True);
    for var Name in ['toHexString', 'toOctalString', 'toBinaryString'] do
      B.JavaClass.AddNative(Name, '(I)Ljava/lang/String;', True);
    for var D in ['(Ljava/lang/String;)', '(Ljava/lang/String;I)'] do
    begin
      B.JavaClass.AddNative('parseInt', D + 'I', True);
      B.JavaClass.AddNative('valueOf', D + 'Ljava/lang/Integer;', True);
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create('java/lang/Long', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
  try
    B.Field('value', 'J', JVM_ACC_PRIVATE or JVM_ACC_FINAL);
    B.Field('MIN_VALUE', 'J', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Long(Low(Int64));
    B.Field('MAX_VALUE', 'J', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Long(High(Int64));
    B.JavaClass.AddNative('<init>', '(J)V');
    B.JavaClass.AddNative('longValue', '()J');
    B.JavaClass.AddNative('intValue', '()I');
    B.JavaClass.AddNative('floatValue', '()F');
    B.JavaClass.AddNative('doubleValue', '()D');
    B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
    B.JavaClass.AddNative('hashCode', '()I');
    B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
    B.JavaClass.AddNative('toString', '(J)Ljava/lang/String;', True);
    B.JavaClass.AddNative('toString', '(JI)Ljava/lang/String;', True);
    B.JavaClass.AddNative('parseLong', '(Ljava/lang/String;)J', True);
    B.JavaClass.AddNative('parseLong', '(Ljava/lang/String;I)J', True);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  for var IsByte in [True, False] do
  begin
    var Name := 'java/lang/Short';
    var D := 'S';
    var ParseName := 'parseShort';
    var Getter := 'shortValue';
    var Minimum := Integer(Low(SmallInt));
    var Maximum := Integer(High(SmallInt));
    if IsByte then
    begin
      Name := 'java/lang/Byte';
      D := 'B';
      ParseName := 'parseByte';
      Getter := 'byteValue';
      Minimum := Low(ShortInt);
      Maximum := High(ShortInt);
    end;
    B := TJavaClassBuilder.Create(Name, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
    try
      B.Field('value', D, JVM_ACC_PRIVATE or JVM_ACC_FINAL);
      B.Field('MIN_VALUE', D, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Minimum);
      B.Field('MAX_VALUE', D, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(Maximum);
      B.JavaClass.AddNative('<init>', '(' + D + ')V');
      B.JavaClass.AddNative(Getter, '()' + D);
      B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
      B.JavaClass.AddNative('hashCode', '()I');
      B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
      B.JavaClass.AddNative(ParseName, '(Ljava/lang/String;)' + D, True);
      B.JavaClass.AddNative(ParseName, '(Ljava/lang/String;I)' + D, True);
      VM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
  end;
end;

function JavaIntegerDigit(C: Char): Integer;
begin
  Result := JavaCharDigit(C, 36);
end;

function ParseSigned(VM: TJVM; Ref, Radix: Integer; Minimum, Maximum: Int64): Int64;

  procedure Invalid;
  begin
    VM.RaiseJava('java/lang/NumberFormatException', 'Invalid integer');
  end;

begin
  if (Ref = 0) or (Radix < 2) or (Radix > 36) then
    Invalid;
  var Text := VM.GetObject(Ref).Text;
  if Text = '' then
    Invalid;
  var Negative := Text[1] = '-';
  var Index := 1;
  if Negative then
    Inc(Index);
  if Index > Length(Text) then
    Invalid;
  // CLDC 1.1 permits a leading ASCII minus, and rejects a leading plus.
  // Accumulate negatively, preserving the extra negative value at either width.
  var Limit := -Maximum;
  if Negative then
    Limit := Minimum;
  var Threshold := Limit div Radix;
  var Accumulator: Int64 := 0;
  while Index <= Length(Text) do
  begin
    var D := JavaIntegerDigit(Text[Index]);
    if (D < 0) or (D >= Radix) or (Accumulator < Threshold) then
      Invalid;
    Accumulator := Accumulator * Radix;
    if Accumulator < Limit + D then
      Invalid;
    Dec(Accumulator, D);
    Inc(Index);
  end;
  if not Negative then
    Accumulator := -Accumulator;
  Result := Accumulator;
end;

function Parse(VM: TJVM; Ref, Radix: Integer): Integer;
begin
  Result := Integer(ParseSigned(VM, Ref, Radix, Low(Integer), High(Integer)));
end;

function TextBase(Magnitude: UInt64; Radix: Integer; Negative: Boolean): string;
const
  Digits = '0123456789abcdefghijklmnopqrstuvwxyz';
var
  Buffer: array[0..64] of Char;
begin
  var Index := Length(Buffer);
  repeat
    Dec(Index);
    Buffer[Index] := Digits[Integer(Magnitude mod UInt64(Radix)) + 1];
    Magnitude := Magnitude div UInt64(Radix);
  until Magnitude = 0;
  if Negative then
  begin
    Dec(Index);
    Buffer[Index] := '-';
  end;
  SetString(Result, PChar(@Buffer[Index]), Length(Buffer) - Index);
end;

function InvokeJavaSmallInteger(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Number: Integer;
begin
  Result := Default(TJVMValue);
  var IsByte := Method.Owner.Name = 'java/lang/Byte';
  var N := Method.Name;
  var D := 'S';
  if IsByte then
    D := 'B';
  var FieldKey := Method.Owner.Name + '.value:' + D;
  if (Method.Access and JVM_ACC_STATIC) <> 0 then
  begin
    if (IsByte and (N <> 'parseByte')) or (not IsByte and (N <> 'parseShort')) then
      raise EJVMUnsupported.Create('Small integer static method: ' + N);
    var Radix := 10;
    if Length(Args) = 2 then
      Radix := Args[1].AsInt;
    Number := Parse(VM, Args[0].AsRef, Radix);
    var Minimum := Integer(Low(SmallInt));
    var Maximum := Integer(High(SmallInt));
    if IsByte then
    begin
      Minimum := Low(ShortInt);
      Maximum := High(ShortInt);
    end;
    if (Number < Minimum) or (Number > Maximum) then
      VM.RaiseJava('java/lang/NumberFormatException', 'Small integer range');
    Exit(TJVMValue.Int(Number));
  end;
  var O := VM.GetObject(Args[0].AsRef);
  if N = '<init>' then
  begin
    Number := Args[1].AsInt;
    if IsByte then
      Number := ShortInt(Number)
    else
      Number := SmallInt(Number);
    O.Fields[FieldKey] := TJVMValue.Int(Number);
    Exit;
  end;
  Number := O.Fields[FieldKey].AsInt;
  if (N = 'byteValue') or (N = 'shortValue') or (N = 'hashCode') then
    Exit(TJVMValue.Int(Number));
  if N = 'equals' then
  begin
    var Other := Args[1].AsRef;
    Exit(TJVMValue.Int(Ord((Other <> 0) and (VM.GetObject(Other).ClassName = Method.Owner.Name) and (VM.GetObject(Other).Fields[FieldKey].AsInt = Number))));
  end;
  if N = 'toString' then
    Exit(TJVMValue.Ref(VM.NewString(IntToStr(Number))));
  raise EJVMUnsupported.Create('Small integer method: ' + N);
end;

function InvokeJavaInteger(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  Number, Radix: Integer;
  N, Text: string;
  O: TJVMObject;
begin
  Result := Default(TJVMValue);
  N := Method.Name;
  if (N = 'parseInt') or (N = 'valueOf') then
  begin
    Radix := 10;
    if Length(Args) > 1 then
      Radix := Args[1].AsInt;
    Number := Parse(VM, Args[0].AsRef, Radix);
    if N = 'parseInt' then
      Exit(TJVMValue.Int(Number));
    var Ref := VM.NewObject(IntegerName);
    VM.GetObject(Ref).Fields[ValueKey] := TJVMValue.Int(Number);
    Exit(TJVMValue.Ref(Ref));
  end;
  if (Method.Access and JVM_ACC_STATIC) <> 0 then
  begin
    Number := Args[0].AsInt;
    Radix := 10;
    if N = 'toString' then
    begin
      if Length(Args) > 1 then
        Radix := Args[1].AsInt;
      if (Radix < 2) or (Radix > 36) then
        Radix := 10;
    end
    else
    begin
      if N = 'toHexString' then
        Radix := 16
      else if N = 'toOctalString' then
        Radix := 8
      else if N = 'toBinaryString' then
        Radix := 2
      else
        raise EJVMUnsupported.Create('Integer static method: ' + N);
      Exit(TJVMValue.Ref(VM.NewString(TextBase(UInt32(Number), Radix, False))));
    end;
  end
  else
  begin
    O := VM.GetObject(Args[0].AsRef);
    if N = '<init>' then
    begin
      O.Fields[ValueKey] := Args[1];
      Exit;
    end;
    Number := O.Fields[ValueKey].AsInt;
    if (N = 'intValue') or (N = 'hashCode') then
      Exit(TJVMValue.Int(Number));
    if N = 'byteValue' then
      Exit(TJVMValue.Int(ShortInt(Number)));
    if N = 'shortValue' then
      Exit(TJVMValue.Int(SmallInt(Number)));
    if N = 'longValue' then
      Exit(TJVMValue.Long(Number));
    if N = 'floatValue' then
      Exit(TJVMValue.Float(Number));
    if N = 'doubleValue' then
      Exit(TJVMValue.Double(Number));
    if N = 'equals' then
    begin
      var Other := Args[1].AsRef;
      Exit(TJVMValue.Int(Ord((Other <> 0) and (VM.GetObject(Other).ClassName = IntegerName) and (VM.GetObject(Other).Fields[ValueKey].AsInt = Number))));
    end;
    if N <> 'toString' then
      raise EJVMUnsupported.Create('Integer instance method: ' + N);
    Radix := 10;
  end;
  var Magnitude := Int64(Number);
  if Magnitude < 0 then
    Magnitude := -Magnitude;
  Text := TextBase(UInt64(Magnitude), Radix, Number < 0);
  Result := TJVMValue.Ref(VM.NewString(Text));
end;

function InvokeJavaLong(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
const
  Name = 'java/lang/Long';
  Key = Name + '.value:J';
var
  Number: Int64;
  Radix: Integer;
begin
  Result := Default(TJVMValue);
  var N := Method.Name;
  if (Method.Access and JVM_ACC_STATIC) <> 0 then
  begin
    Radix := 10;
    if Length(Args) > 1 then
      Radix := Args[1].AsInt;
    if N = 'parseLong' then
      Exit(TJVMValue.Long(ParseSigned(VM, Args[0].AsRef, Radix, Low(Int64), High(Int64))));
    if N <> 'toString' then
      raise EJVMUnsupported.Create('Long static method: ' + N);
    Number := Args[0].AsLong;
    if (Radix < 2) or (Radix > 36) then
      Radix := 10;
  end
  else
  begin
    var O := VM.GetObject(Args[0].AsRef);
    if N = '<init>' then
    begin
      O.Fields[Key] := Args[1];
      Exit;
    end;
    Number := O.Fields[Key].AsLong;
    if N = 'longValue' then
      Exit(TJVMValue.Long(Number));
    if N = 'intValue' then
      Exit(TJVMValue.Int(Integer(Number)));
    if N = 'floatValue' then
      Exit(TJVMValue.Float(Number));
    if N = 'doubleValue' then
      Exit(TJVMValue.Double(Number));
    if N = 'hashCode' then
      Exit(TJVMValue.Int(Integer(Number xor Int64(UInt64(Number) shr 32))));
    if N = 'equals' then
    begin
      var Other := Args[1].AsRef;
      Exit(TJVMValue.Int(Ord((Other <> 0) and (VM.GetObject(Other).ClassName = Name) and (VM.GetObject(Other).Fields[Key].AsLong = Number))));
    end;
    if N <> 'toString' then
      raise EJVMUnsupported.Create('Long instance method: ' + N);
    Radix := 10;
  end;
  var Magnitude := UInt64(Number);
  if Number < 0 then
    Magnitude := UInt64(-(Number + 1)) + 1;
  Result := TJVMValue.Ref(VM.NewString(TextBase(Magnitude, Radix, Number < 0)));
end;

end.

