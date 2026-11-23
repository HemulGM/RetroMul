unit Java.Floating;

interface

uses
  JVM.Types, JVM.Runtime, JVM.ClassFile;

procedure InstallJavaFloating(VM: TJVM);

function IsLegacyEmptyFloatingClass(C: TJVMClass): Boolean;

function InvokeJavaFloating(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function ParseJavaFloating(VM: TJVM; Ref: Integer; SinglePrecision: Boolean): TJVMValue;

implementation

uses
  System.SysUtils, Java.Classes, Java.Floating.Text;

{$Q-}{$R-}

const
  FloatingNames: array[0..4] of string = ('POSITIVE_INFINITY', 'NEGATIVE_INFINITY', 'NaN', 'MAX_VALUE', 'MIN_VALUE');
  SingleFieldBits: array[0..4] of UInt64 = ($7F800000, $FF800000, $7FC00000, $7F7FFFFF, 1);
  DoubleFieldBits: array[0..4] of UInt64 = ($7FF0000000000000, $FFF0000000000000, $7FF8000000000000, $7FEFFFFFFFFFFFFF, 1);

function IsLegacyEmptyFloatingClass(C: TJVMClass): Boolean;
begin
  Result := False;
  if (C = nil) or ((C.Name <> 'java/lang/Float') and (C.Name <> 'java/lang/Double')) then
    Exit;
  if (C.Fields.Count <> 6) or (C.Access <> (JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020)) then
    Exit;
  var SinglePrecision := C.Name = 'java/lang/Float';
  var D := 'D';
  var Kind := TJVMKind.Double;
  if SinglePrecision then
  begin
    D := 'F';
    Kind := TJVMKind.Float;
  end;
  // Earlier bootstrap classes supplied only bit helpers and had zero fields.
  // Accept that exact empty legacy layout only for this reviewed current schema.
  for var I := 0 to 5 do
  begin
    var F := C.Fields[I];
    var Name := 'value';
    var Bits := UInt64(0);
    var Flags := JVM_ACC_PRIVATE or JVM_ACC_FINAL;
    if I > 0 then
    begin
      Name := FloatingNames[I - 1];
      Flags := JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL;
      Bits := DoubleFieldBits[I - 1];
      if SinglePrecision then
        Bits := SingleFieldBits[I - 1];
    end;
    if (F.Name <> Name) or (F.Descriptor <> D) or (F.Access <> Flags) or
      (F.Value.Kind <> Kind) or (UInt64(F.Value.Bits) <> Bits) then
      Exit;
  end;
  Result := True;
end;

function FloatingValue(SinglePrecision: Boolean; Bits: UInt64): TJVMValue;
begin
  Result.Kind := TJVMKind.Double;
  if SinglePrecision then
  begin
    Result.Kind := TJVMKind.Float;
    Bits := UInt32(Bits);
  end;
  Result.Bits := Int64(Bits);
end;

function CanonicalFloating(Bits: UInt64; SinglePrecision: Boolean): UInt64;
begin
  if SinglePrecision then
  begin
    Result := UInt32(Bits);
    if (Result and $7FFFFFFF) > $7F800000 then
      Result := $7FC00000;
  end
  else
  begin
    Result := Bits;
    if (Bits and $7FFFFFFFFFFFFFFF) > $7FF0000000000000 then
      Result := $7FF8000000000000;
  end;
end;

procedure InstallJavaFloating(VM: TJVM);
begin
  for var SinglePrecision in [True, False] do
  begin
    var Name := 'java/lang/Double';
    var D := 'D';
    var ParseName := 'parseDouble';
    if SinglePrecision then
    begin
      Name := 'java/lang/Float';
      D := 'F';
      ParseName := 'parseFloat';
    end;
    var B := TJavaClassBuilder.Create(Name, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
    try
      B.Field('value', D, JVM_ACC_PRIVATE or JVM_ACC_FINAL);
      for var I := Low(FloatingNames) to High(FloatingNames) do
      begin
        B.Field(FloatingNames[I], D, JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
        var Bits := DoubleFieldBits[I];
        if SinglePrecision then
          Bits := SingleFieldBits[I];
        B.JavaClass.Fields.Last.Value := FloatingValue(SinglePrecision, Bits);
      end;
      B.JavaClass.AddNative('<init>', '(' + D + ')V');
      if SinglePrecision then
        B.JavaClass.AddNative('<init>', '(D)V');
      B.JavaClass.AddNative(ParseName, '(Ljava/lang/String;)' + D, True);
      B.JavaClass.AddNative('valueOf', '(Ljava/lang/String;)L' + Name + ';', True);
      for var N in ['isNaN', 'isInfinite'] do
      begin
        B.JavaClass.AddNative(N, '(' + D + ')Z', True);
        B.JavaClass.AddNative(N, '()Z');
      end;
      for var N in ['byteValue', 'shortValue', 'intValue', 'longValue', 'floatValue', 'doubleValue'] do
      begin
        var ResultType := 'I';
        if N = 'byteValue' then
          ResultType := 'B'
        else if N = 'shortValue' then
          ResultType := 'S'
        else if N = 'longValue' then
          ResultType := 'J'
        else if N = 'floatValue' then
          ResultType := 'F'
        else if N = 'doubleValue' then
          ResultType := 'D';
        B.JavaClass.AddNative(N, '()' + ResultType);
      end;
      B.JavaClass.AddNative('equals', '(Ljava/lang/Object;)Z');
      B.JavaClass.AddNative('hashCode', '()I');
      B.JavaClass.AddNative('toString', '()Ljava/lang/String;');
      B.JavaClass.AddNative('toString', '(' + D + ')Ljava/lang/String;', True);
      if SinglePrecision then
      begin
        B.JavaClass.AddNative('floatToIntBits', '(F)I', True);
        B.JavaClass.AddNative('intBitsToFloat', '(I)F', True);
      end
      else
      begin
        B.JavaClass.AddNative('doubleToLongBits', '(D)J', True);
        B.JavaClass.AddNative('longBitsToDouble', '(J)D', True);
      end;
      VM.DefineClass(B.Detach);
    finally
      B.Free;
    end;
  end;
end;

function InvokeJavaFloating(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var SinglePrecision := Method.Owner.Name = 'java/lang/Float';
  var Name := Method.Name;
  var D := 'D';
  if SinglePrecision then
    D := 'F';
  var Key := Method.Owner.Name + '.value:' + D;
  var V := Default(TJVMValue);
  if (Method.Access and JVM_ACC_STATIC) <> 0 then
  begin
    if (Name = 'parseFloat') or (Name = 'parseDouble') or (Name = 'valueOf') then
    begin
      V := ParseJavaFloating(VM, Args[0].AsRef, SinglePrecision);
      if Name <> 'valueOf' then
        Exit(V);
      var Ref := VM.NewObject(Method.Owner.Name);
      VM.GetObject(Ref).Fields[Key] := V;
      Exit(TJVMValue.Ref(Ref));
    end;
    V := Args[0];
    if Name = 'intBitsToFloat' then
      Exit(FloatingValue(True, UInt32(V.AsInt)));
    if Name = 'longBitsToDouble' then
      Exit(FloatingValue(False, UInt64(V.AsLong)));
    if Name = 'floatToIntBits' then
      Exit(TJVMValue.Int(Integer(CanonicalFloating(UInt64(V.Bits), True))));
    if Name = 'doubleToLongBits' then
      Exit(TJVMValue.Long(Int64(CanonicalFloating(UInt64(V.Bits), False))));
  end
  else
  begin
    var O := VM.GetObject(Args[0].AsRef);
    if Name = '<init>' then
    begin
      V := Args[1];
      if SinglePrecision and (V.Kind = TJVMKind.Double) then
        V := TJVMValue.Float(V.AsDouble);
      O.Fields[Key] := V;
      Exit;
    end;
    V := O.Fields[Key];
    if Name = 'hashCode' then
    begin
      var Bits := CanonicalFloating(UInt64(V.Bits), SinglePrecision);
      if not SinglePrecision then
        Bits := Bits xor (Bits shr 32);
      Exit(TJVMValue.Int(Integer(Bits)));
    end;
    if Name = 'equals' then
    begin
      var Ref := Args[1].AsRef;
      if (Ref = 0) or (VM.GetObject(Ref).ClassName <> Method.Owner.Name) then
        Exit(TJVMValue.Int(0));
      var Other := VM.GetObject(Ref).Fields[Key];
      Exit(TJVMValue.Int(Ord(CanonicalFloating(UInt64(V.Bits), SinglePrecision) = CanonicalFloating(UInt64(Other.Bits), SinglePrecision))));
    end;
    if Name = 'floatValue' then
    begin
      if SinglePrecision then
        Exit(V);
      Exit(TJVMValue.Float(V.AsDouble));
    end;
    if Name = 'doubleValue' then
    begin
      if not SinglePrecision then
        Exit(V);
      Exit(TJVMValue.Double(V.AsFloat));
    end;
    if (Name = 'longValue') or (Name = 'intValue') or (Name = 'byteValue') or (Name = 'shortValue') then
    begin
      var RealValue: Double;
      if SinglePrecision then
        RealValue := V.AsFloat
      else
        RealValue := V.AsDouble;
      if Name = 'longValue' then
        Exit(TJVMValue.Long(RealToJavaLong(RealValue)));
      if Name = 'intValue' then
        Exit(TJVMValue.Int(RealToJavaInt(RealValue)));
      if Name = 'byteValue' then
        Exit(TJVMValue.Int(ShortInt(RealToJavaInt(RealValue))));
      Exit(TJVMValue.Int(SmallInt(RealToJavaInt(RealValue))));
    end;
  end;
  if Name = 'toString' then
    Exit(TJVMValue.Ref(VM.NewString(JavaFloatingText(UInt64(V.Bits), SinglePrecision))));
  var Magnitude := UInt64(V.Bits) and $7FFFFFFFFFFFFFFF;
  var Infinity := UInt64($7FF0000000000000);
  if SinglePrecision then
  begin
    Magnitude := UInt32(V.Bits) and $7FFFFFFF;
    Infinity := $7F800000;
  end;
  if Name = 'isNaN' then
    Exit(TJVMValue.Int(Ord(Magnitude > Infinity)));
  if Name = 'isInfinite' then
    Exit(TJVMValue.Int(Ord(Magnitude = Infinity)));
  raise EJVMUnsupported.Create('Floating-point native method: ' + Method.Owner.Name + '.' + Name + Method.Descriptor);
end;

// Compare decimal strings with exact dyadic rounding boundaries. Integer-only
// arithmetic avoids double rounding, host locale/FPU state, and overflow traps.
function BoundaryDigits(Bits: UInt64; SinglePrecision: Boolean; out Power: Integer): string;
const
  Base = UInt64(1000000000);
var
  Words: TArray<Cardinal>;

  procedure Multiply(Factor: Cardinal);
  begin
    var Carry := UInt64(0);
    for var I := 0 to High(Words) do
    begin
      var Value := UInt64(Words[I]) * Factor + Carry;
      Words[I] := Value mod Base;
      Carry := Value div Base;
    end;
    if Carry <> 0 then
    begin
      SetLength(Words, Length(Words) + 1);
      Words[High(Words)] := Carry;
    end;
  end;

begin
  var FractionBits := 52;
  var Bias := 1023;
  if SinglePrecision then
  begin
    FractionBits := 23;
    Bias := 127;
  end;
  var Exponent := Integer(Bits shr FractionBits);
  var Mantissa := Bits and ((UInt64(1) shl FractionBits) - 1);
  if Exponent = 0 then
    Exponent := 1
  else
    Mantissa := Mantissa or (UInt64(1) shl FractionBits);
  // Midpoint between this finite number and its successor, including the
  // zero/subnormal and finite/infinity rounding boundaries.
  Mantissa := Mantissa * 2 + 1;
  Exponent := Exponent - Bias - FractionBits - 1;
  repeat
    SetLength(Words, Length(Words) + 1);
    Words[High(Words)] := Mantissa mod Base;
    Mantissa := Mantissa div Base;
  until Mantissa = 0;
  Power := 0;
  if Exponent >= 0 then
    for var I := 1 to Exponent do
      Multiply(2)
  else
  begin
    Power := Exponent;
    for var I := 1 to -Exponent do
      Multiply(5);
  end;
  Result := UIntToStr(Words[High(Words)]);
  for var I := High(Words) - 1 downto 0 do
  begin
    var Group := UIntToStr(Words[I]);
    Result := Result + StringOfChar('0', 9 - Length(Group)) + Group;
  end;
  var Last := Length(Result);
  while (Last > 1) and (Result[Last] = '0') do
  begin
    Dec(Last);
    Inc(Power);
  end;
  SetLength(Result, Last);
end;

function CompareBoundary(const Digits: string; Power: Int64; Bits: UInt64; SinglePrecision: Boolean): Integer;
begin
  var BoundaryPower: Integer;
  var Boundary := BoundaryDigits(Bits, SinglePrecision, BoundaryPower);
  var Order := Int64(Length(Digits)) + Power;
  var BoundaryOrder := Length(Boundary) + BoundaryPower;
  if Order < BoundaryOrder then
    Exit(-1);
  if Order > BoundaryOrder then
    Exit(1);
  var Count := Length(Digits);
  if Count > Length(Boundary) then
    Count := Length(Boundary);
  for var I := 1 to Count do
  begin
    if Digits[I] < Boundary[I] then
      Exit(-1);
    if Digits[I] > Boundary[I] then
      Exit(1);
  end;
  // Both significands have no trailing zeros. A remaining suffix therefore
  // contains a nonzero digit and sorts above implicit zero padding.
  if Length(Digits) < Length(Boundary) then
    Exit(-1);
  if Length(Digits) > Length(Boundary) then
    Exit(1);
  Result := 0;
end;

function ParseJavaFloating(VM: TJVM; Ref: Integer; SinglePrecision: Boolean): TJVMValue;
var
  Text, Digits: string;
  Index, Last, Count, FractionDigits: Integer;
  Negative, Dot, ExponentNegative: Boolean;
  Exponent, Power: Int64;

  procedure Invalid;
  begin
    VM.RaiseJava('java/lang/NumberFormatException', 'Invalid floating-point number');
  end;

  function Digit: Boolean;
  begin
    Result := (Index <= Last) and (Text[Index] >= '0') and (Text[Index] <= '9');
  end;

  function Value(Bits: UInt64; NaNValue: Boolean = False): TJVMValue;
  begin
    if SinglePrecision then
    begin
      Result.Kind := TJVMKind.Float;
      if Negative and not NaNValue then
        Bits := Bits or $80000000;
    end
    else
    begin
      Result.Kind := TJVMKind.Double;
      if Negative and not NaNValue then
        Bits := Bits or (UInt64(1) shl 63);
    end;
    Result.Bits := Int64(Bits);
  end;

begin
  if Ref = 0 then
    VM.RaiseJava('java/lang/NullPointerException');
  Text := VM.GetObject(Ref).Text;
  Index := 1;
  Last := Length(Text);
  // Java String.trim semantics, independent of Unicode/RTL whitespace tables.
  while (Index <= Last) and (Ord(Text[Index]) <= 32) do
    Inc(Index);
  while (Last >= Index) and (Ord(Text[Last]) <= 32) do
    Dec(Last);
  if Index > Last then
    Invalid;
  Negative := Text[Index] = '-';
  if Negative or (Text[Index] = '+') then
    Inc(Index);
  if Index > Last then
    Invalid;
  var InfinityBits := UInt64($7FF0000000000000);
  var NaNBits := UInt64($7FF8000000000000);
  if SinglePrecision then
  begin
    InfinityBits := $7F800000;
    NaNBits := $7FC00000;
  end;
  var Special := Copy(Text, Index, Last - Index + 1);
  if Special = 'NaN' then
    Exit(Value(NaNBits, True));
  if Special = 'Infinity' then
    Exit(Value(InfinityBits));
  SetLength(Digits, Last - Index + 1);
  Count := 0;
  FractionDigits := 0;
  Dot := False;
  while Index <= Last do
  begin
    if Digit then
    begin
      Inc(Count);
      Digits[Count] := Text[Index];
      if Dot then
        Inc(FractionDigits);
    end
    else if (Text[Index] = '.') and not Dot then
      Dot := True
    else
      Break;
    Inc(Index);
  end;
  if Count = 0 then
    Invalid;
  Exponent := 0;
  if (Index <= Last) and CharInSet(Text[Index], ['e', 'E']) then
  begin
    Inc(Index);
    ExponentNegative := (Index <= Last) and (Text[Index] = '-');
    if (Index <= Last) and CharInSet(Text[Index], ['+', '-']) then
      Inc(Index);
    if not Digit then
      Invalid;
    while Digit do
    begin
      // Beyond any possible String length only the sign/order matters. Keep
      // consuming and validating digits without overflowing the accumulator.
      if Exponent < Int64(MaxInt) * 4 then
        Exponent := Exponent * 10 + Ord(Text[Index]) - Ord('0');
      Inc(Index);
    end;
    if ExponentNegative then
      Exponent := -Exponent;
  end;
  if (Index <= Last) and CharInSet(Text[Index], ['f', 'F', 'd', 'D']) then
    Inc(Index);
  if Index <= Last then
    Invalid;
  Power := Exponent - FractionDigits;
  while (Count > 0) and (Digits[Count] = '0') do
  begin
    Dec(Count);
    Inc(Power);
  end;
  if Count = 0 then
    Exit(Value(0));
  var First := 1;
  while Digits[First] = '0' do
    Inc(First);
  Digits := Copy(Digits, First, Count - First + 1);
  var Low := UInt64(0);
  var High := InfinityBits;
  while Low < High do
  begin
    var Middle := Low + (High - Low) div 2;
    var Comparison := CompareBoundary(Digits, Power, Middle, SinglePrecision);
    if (Comparison > 0) or ((Comparison = 0) and ((Middle and 1) <> 0)) then
      Low := Middle + 1
    else
      High := Middle;
  end;
  Result := Value(Low);
end;

end.

