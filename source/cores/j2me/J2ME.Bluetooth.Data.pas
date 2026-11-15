unit J2ME.Bluetooth.Data;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime, Core.Bluetooth.Types;

procedure InstallJ2MEBluetoothData(VM: TJVM);

function HandlesJ2MEBluetoothData(const Owner: string): Boolean;

function InvokeJ2MEBluetoothData(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function J2MEBluetoothUUID(VM: TJVM; Ref: Integer): TBluetoothUUID;

function NewJ2MEBluetoothUUID(VM: TJVM; const UUID: TBluetoothUUID): Integer;

function DecodeJ2MEBluetoothSDP(VM: TJVM; const Data: TBytes): Integer;

function EncodeJ2MEBluetoothSDP(VM: TJVM; Element: Integer): TBytes;

function CopyJ2MEBluetoothData(VM: TJVM; Element: Integer): Integer;

implementation

uses
  System.Math, System.Generics.Collections, Java.Classes, Core.Bluetooth.SDP;

{$Q-}{$R-}

const
  BT = 'javax/bluetooth/';
  UUIDName = BT + 'UUID';
  ClassName = BT + 'DeviceClass';
  ElementName = BT + 'DataElement';
  EnumName = ElementName + '$Enumeration';
  TypeKey = '$bt.type';
  ValueKey = '$bt.value';
  ItemsKey = '$bt.items';
  NumberKey = '$bt.number';
  ParentKey = '$bt.parent';
  IndexKey = '$bt.index';

function BTArray(VM: TJVM; const Descriptor: string; Count: Integer): Integer;
begin
  if Count > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Bluetooth array capacity');
  Result := VM.NewArray(Descriptor, Count);
end;

function BTCloneArray(VM: TJVM; Reference: Integer): Integer;
begin
  if Length(VM.GetObject(Reference).Elements) > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Bluetooth array capacity');
  Result := VM.CloneObject(Reference);
end;

function Int(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsInt;
end;

function Ref(O: TJVMObject; const Key: string): Integer;
var
  V: TJVMValue;
begin
  Result := 0;
  if O.Fields.TryGetValue(Key, V) then
    Result := V.AsRef;
end;

procedure InstallJ2MEBluetoothData(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Native(const Name, Desc: string; Access: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Access or JVM_ACC_NATIVE;
  end;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(BT + 'L2CAPConnection', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.Interfaces := ['javax/microedition/io/Connection'];
    for var Pair in ['DEFAULT_MTU=672', 'MINIMUM_MTU=48'] do
    begin
      var P := Pair.Split(['=']);
      B.Field(P[0], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(StrToInt(P[1]));
    end;
    for var Pair in ['getReceiveMTU|()I', 'getTransmitMTU|()I', 'send|([B)V', 'receive|([B)I', 'ready|()Z'] do
    begin
      var P := Pair.Split(['|']);
      B.JavaClass.AddNative(P[0], P[1]).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    end;
    Done;
    B := TJavaClassBuilder.Create(BT + 'L2CAPConnectionNotifier', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    B.JavaClass.Interfaces := ['javax/microedition/io/Connection'];
    B.JavaClass.AddNative('acceptAndOpen', '()Ljavax/bluetooth/L2CAPConnection;').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Done;
    for var Name in ['BluetoothStateException', 'ServiceRegistrationException'] do
    begin
      B := TJavaClassBuilder.Create(BT + Name, 'java/io/IOException');
      Native('<init>', '()V');
      Native('<init>', '(Ljava/lang/String;)V');
      Done;
    end;
    B := TJavaClassBuilder.Create(BT + 'BluetoothConnectionException', 'java/io/IOException');
    for var Pair in ['UNKNOWN_PSM=1', 'SECURITY_BLOCK=2', 'NO_RESOURCES=3', 'FAILED_NOINFO=4', 'TIMEOUT=5', 'UNACCEPTABLE_PARAMS=6'] do
    begin
      var P := Pair.Split(['=']);
      B.Field(P[0], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(StrToInt(P[1]));
    end;
    Native('$status', '(I)V', JVM_ACC_PRIVATE);
    Native('getStatus', '()I');
    for var WithMessage in [False, True] do
    begin
      B.Start;
      B.Emit([$2A]);
      if WithMessage then
        B.Emit([$2C])
      else
        B.Emit([$01]);
      B.Ref($B7, B.Member('java/io/IOException', '<init>', '(Ljava/lang/String;)V'));
      B.Emit([$2A, $1B]);
      B.Ref($B7, B.Member(BT + 'BluetoothConnectionException', '$status', '(I)V'));
      B.Emit([$B1]);
      var Desc := '(I)V';
      var Locals := 2;
      if WithMessage then
      begin
        Desc := '(ILjava/lang/String;)V';
        Locals := 3;
      end;
      B.Finish('<init>', Desc, JVM_ACC_PUBLIC, 2, Locals);
    end;
    Done;
    B := TJavaClassBuilder.Create(UUIDName, 'java/lang/Object');
    Native('<init>', '(J)V');
    Native('<init>', '(Ljava/lang/String;Z)V');
    Native('toString', '()Ljava/lang/String;');
    Native('equals', '(Ljava/lang/Object;)Z');
    Native('hashCode', '()I');
    Done;
    B := TJavaClassBuilder.Create(ClassName, 'java/lang/Object');
    Native('<init>', '(I)V');
    for var Name in ['getServiceClasses', 'getMajorDeviceClass', 'getMinorDeviceClass'] do
      Native(Name, '()I');
    Done;
    B := TJavaClassBuilder.Create(ElementName, 'java/lang/Object');
    for var Pair in ['NULL=0', 'U_INT_1=8', 'U_INT_2=9', 'U_INT_4=10', 'U_INT_8=11', 'U_INT_16=12', 'INT_1=16', 'INT_2=17', 'INT_4=18', 'INT_8=19', 'INT_16=20', 'UUID=24', 'STRING=32', 'BOOL=40', 'DATSEQ=48', 'DATALT=56', 'URL=64'] do
    begin
      var P := Pair.Split(['=']);
      B.Field(P[0], 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
      B.JavaClass.Fields.Last.Value := TJVMValue.Int(StrToInt(P[1]));
    end;
    for var Desc in ['(I)V', '(Z)V', '(IJ)V', '(ILjava/lang/Object;)V'] do
      Native('<init>', Desc);
    Native('getDataType', '()I');
    Native('getLong', '()J');
    Native('getBoolean', '()Z');
    for var Pair in ['getValue|()Ljava/lang/Object;', 'getSize|()I', 'addElement|(Ljavax/bluetooth/DataElement;)V', 'insertElementAt|(Ljavax/bluetooth/DataElement;I)V', 'removeElement|(Ljavax/bluetooth/DataElement;)Z'] do
    begin
      var P := Pair.Split(['|']);
      Native(P[0], P[1], JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    end;
    Done;
    B := TJavaClassBuilder.Create(EnumName, 'java/lang/Object', JVM_ACC_FINAL or $0020);
    B.JavaClass.Interfaces := ['java/util/Enumeration'];
    Native('hasMoreElements', '()Z');
    Native('nextElement', '()Ljava/lang/Object;');
    Done;
  finally
    B.Free;
  end;
end;

function HandlesJ2MEBluetoothData(const Owner: string): Boolean;
begin
  Result := (Owner = UUIDName) or (Owner = ClassName) or (Owner = ElementName) or (Owner = EnumName) or (Owner = BT + 'BluetoothConnectionException');
end;

function J2MEBluetoothUUID(VM: TJVM; Ref: Integer): TBluetoothUUID;
begin
  var O := VM.GetObject(Ref);
  if not VM.IsAssignable(O.ClassName, UUIDName) or not TBluetoothUUID.TryParse(O.Text, Result) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Invalid UUID object');
end;

function NewJ2MEBluetoothUUID(VM: TJVM; const UUID: TBluetoothUUID): Integer;
begin
  Result := VM.NewObject(UUIDName);
  VM.GetObject(Result).Text := UUID.ToString;
end;

function DecodeJ2MEBluetoothSDP(VM: TJVM; const Data: TBytes): Integer;

  function Convert(E: TBluetoothSDPElement): Integer;
  var
    TypeCode, ValueRef: Integer;
    Value: TJVMValue;
  begin
    Result := VM.NewObject(ElementName);
    var O := VM.GetObject(Result);
    TypeCode := 0;
    Value := TJVMValue.Ref(0);
    case E.Kind of
      TBluetoothSDPKind.NilValue:
        ;
      TBluetoothSDPKind.UnsignedInteger, TBluetoothSDPKind.SignedInteger:
        begin
          var Size := Length(E.Data);
          var SizeIndex := 0;
          while (1 shl SizeIndex) < Size do
            Inc(SizeIndex);
          TypeCode := 8 + SizeIndex;
          if E.Kind = TBluetoothSDPKind.SignedInteger then
            Inc(TypeCode, 8);
          if (Size <= 4) or ((Size = 8) and (E.Kind = TBluetoothSDPKind.SignedInteger)) then
          begin
            var Number := UInt64(0);
            for var B in E.Data do
              Number := (Number shl 8) or B;
            if (Size < 8) and (E.Kind = TBluetoothSDPKind.SignedInteger) and ((E.Data[0] and $80) <> 0) then
              Number := Number or (High(UInt64) shl (Size * 8));
            Value := TJVMValue.Long(Int64(Number));
          end
          else
          begin
            ValueRef := BTArray(VM, '[B', Size);
            for var I := 0 to Size - 1 do
              VM.GetObject(ValueRef).Elements[I] := TJVMValue.Int(ShortInt(E.Data[I]));
            Value := TJVMValue.Ref(ValueRef);
          end;
        end;
      TBluetoothSDPKind.UUID:
        begin
          TypeCode := 24;
          var Text := '';
          for var B in E.Data do
            Text := Text + IntToHex(B, 2);
          var UUID: TBluetoothUUID;
          if not TBluetoothUUID.TryParse(Text, UUID) then
            raise EBluetoothSDP.Create('SDP UUID');
          Value := TJVMValue.Ref(NewJ2MEBluetoothUUID(VM, UUID));
        end;
      TBluetoothSDPKind.BooleanValue:
        begin
          TypeCode := 40;
          Value := TJVMValue.Int(Ord(E.Data[0] <> 0));
        end;
      TBluetoothSDPKind.TextString, TBluetoothSDPKind.URL:
        begin
          TypeCode := 32;
          if E.Kind = TBluetoothSDPKind.URL then
            TypeCode := 64;
          Value := TJVMValue.Ref(VM.NewString(TEncoding.UTF8.GetString(E.Data)));
        end;
      TBluetoothSDPKind.Sequence, TBluetoothSDPKind.Alternative:
        begin
          TypeCode := 48;
          if E.Kind = TBluetoothSDPKind.Alternative then
            TypeCode := 56;
          ValueRef := BTArray(VM, '[Ljavax/bluetooth/DataElement;', E.Children.Count);
          var A := VM.GetObject(ValueRef);
          for var I := 0 to E.Children.Count - 1 do
            A.Elements[I] := TJVMValue.Ref(Convert(E.Children[I]));
          Value := TJVMValue.Ref(ValueRef);
        end;
    end;
    O.Fields.AddOrSetValue(TypeKey, TJVMValue.Int(TypeCode));
    if TypeCode in [48, 56] then
      O.Fields.AddOrSetValue(ItemsKey, Value)
    else if TypeCode in [8, 9, 10, 16, 17, 18, 19, 40] then
      O.Fields.AddOrSetValue(NumberKey, Value)
    else
      O.Fields.AddOrSetValue(ValueKey, Value);
  end;

begin
  var Root := DecodeBluetoothSDP(Data);
  try
    Result := Convert(Root);
  finally
    Root.Free;
  end;
end;

function EncodeJ2MEBluetoothSDP(VM: TJVM; Element: Integer): TBytes;
var
  Active: TDictionary<Integer, Byte>;
  Nodes: Integer;

  function Convert(Ref: Integer; Depth: Integer): TBluetoothSDPElement;
  begin
    if (Depth > BLUETOOTH_SDP_MAX_DEPTH) or (Nodes >= BLUETOOTH_SDP_MAX_NODES) or Active.ContainsKey(Ref) then
      raise EBluetoothSDP.Create('Cyclic or excessive guest DataElement');
    Inc(Nodes);
    Active.Add(Ref, 0);
    Result := nil;
    try
      var O := VM.GetObject(Ref);
      var TypeCode := Int(O, TypeKey);
      case TypeCode of
        0:
          Result := TBluetoothSDPElement.Create(TBluetoothSDPKind.NilValue);
        8, 9, 10, 11, 12, 16, 17, 18, 19, 20:
          begin
            var Kind := TBluetoothSDPKind.UnsignedInteger;
            if TypeCode >= 16 then
              Kind := TBluetoothSDPKind.SignedInteger;
            Result := TBluetoothSDPElement.Create(Kind);
            var Size := 1 shl (TypeCode and 7);
            SetLength(Result.Data, Size);
            if TypeCode in [11, 12, 20] then
            begin
              var A := VM.GetObject(J2ME.Bluetooth.Data.Ref(O, ValueKey));
              if Length(A.Elements) <> Size then
                raise EBluetoothSDP.Create('DataElement integer width');
              for var I := 0 to Size - 1 do
                Result.Data[I] := Byte(A.Elements[I].AsInt);
            end
            else
            begin
              var Number := UInt64(O.Fields[NumberKey].AsLong);
              for var I := 0 to Size - 1 do
                Result.Data[Size - 1 - I] := Byte(Number shr (I * 8));
            end;
          end;
        24:
          begin
            Result := TBluetoothSDPElement.Create(TBluetoothSDPKind.UUID);
            var UUID := J2MEBluetoothUUID(VM, J2ME.Bluetooth.Data.Ref(O, ValueKey));
            var Text := UUID.ToString;
            SetLength(Result.Data, 16);
            for var I := 0 to 15 do
              Result.Data[I] := StrToInt('$' + Copy(Text, I * 2 + 1, 2));
          end;
        32, 64:
          begin
            var Kind := TBluetoothSDPKind.TextString;
            if TypeCode = 64 then
              Kind := TBluetoothSDPKind.URL;
            Result := TBluetoothSDPElement.Create(Kind);
            Result.Data := TEncoding.UTF8.GetBytes(VM.GetObject(J2ME.Bluetooth.Data.Ref(O, ValueKey)).Text);
          end;
        40:
          begin
            Result := TBluetoothSDPElement.Create(TBluetoothSDPKind.BooleanValue);
            Result.Data := TBytes.Create(Byte(Int(O, NumberKey) <> 0));
          end;
        48, 56:
          begin
            var Kind := TBluetoothSDPKind.Sequence;
            if TypeCode = 56 then
              Kind := TBluetoothSDPKind.Alternative;
            Result := TBluetoothSDPElement.Create(Kind);
            var A := VM.GetObject(J2ME.Bluetooth.Data.Ref(O, ItemsKey));
            for var V in A.Elements do
              Result.Children.Add(Convert(V.AsRef, Depth + 1));
          end;
      else
        raise EBluetoothSDP.Create('Unknown DataElement type');
      end;
    except
      Result.Free;
      Active.Remove(Ref);
      raise;
    end;
    Active.Remove(Ref);
  end;

begin
  Active := TDictionary<Integer, Byte>.Create;
  var Root: TBluetoothSDPElement := nil;
  try
    Nodes := 0;
    Root := Convert(Element, 0);
    Result := EncodeBluetoothSDP(Root);
  finally
    Root.Free;
    Active.Free;
  end;
end;

function CopyJ2MEBluetoothData(VM: TJVM; Element: Integer): Integer;
var
  Active: TDictionary<Integer, Byte>;
  Nodes: Integer;

  function CopyElement(Value: Integer; Depth: Integer): Integer;
  begin
    if (Depth > BLUETOOTH_SDP_MAX_DEPTH) or (Nodes >= BLUETOOTH_SDP_MAX_NODES) or Active.ContainsKey(Value) then
      raise EBluetoothSDP.Create('Cyclic or excessive DataElement copy');
    Inc(Nodes);
    Active.Add(Value, 0);
    try
      var O := VM.GetObject(Value);
      var TypeCode := Int(O, TypeKey);
      Result := VM.NewObject(ElementName);
      var CopyObject := VM.GetObject(Result);
      CopyObject.Fields.AddOrSetValue(TypeKey, TJVMValue.Int(TypeCode));
      if TypeCode in [48, 56] then
      begin
        var A := VM.GetObject(Ref(O, ItemsKey));
        var Values := BTArray(VM, '[Ljavax/bluetooth/DataElement;', Length(A.Elements));
        CopyObject.Fields.AddOrSetValue(ItemsKey, TJVMValue.Ref(Values));
        for var I := 0 to High(A.Elements) do
          VM.GetObject(Values).Elements[I] := TJVMValue.Ref(CopyElement(A.Elements[I].AsRef, Depth + 1));
      end
      else if TypeCode in [11, 12, 20] then
        CopyObject.Fields.AddOrSetValue(ValueKey, TJVMValue.Ref(BTCloneArray(VM, Ref(O, ValueKey))))
      else if TypeCode in [8, 9, 10, 16, 17, 18, 19, 40] then
        CopyObject.Fields.AddOrSetValue(NumberKey, O.Fields[NumberKey])
      else
        CopyObject.Fields.AddOrSetValue(ValueKey, O.Fields[ValueKey]);
    finally
      Active.Remove(Value);
    end;
  end;

begin
  Active := TDictionary<Integer, Byte>.Create;
  try
    Nodes := 0;
    Result := CopyElement(Element, 0);
  finally
    Active.Free;
  end;
end;

function InvokeJ2MEBluetoothData(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  O: TJVMObject;
  TypeCode: Integer;

  procedure Invalid;
  begin
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Bluetooth data value/type');
  end;

  procedure CastError;
  begin
    VM.RaiseJava('java/lang/ClassCastException', 'DataElement method is incompatible with its type');
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  var Owner := Method.Owner.Name;
  if Owner = BT + 'BluetoothConnectionException' then
  begin
    if N = '$status' then
    begin
      var Status := Args[1].AsInt;
      if not (Status in [1..6]) then
        Invalid;
      O.Fields.AddOrSetValue(NumberKey, Args[1]);
      Exit;
    end;
    Exit(TJVMValue.Int(Int(O, NumberKey)));
  end;
  if Owner = UUIDName then
  begin
    if N = '<init>' then
    begin
      var Value := '';
      if Method.Descriptor = '(J)V' then
      begin
        var Number := Args[1].AsLong;
        if (Number < 0) or (Number > $FFFFFFFF) then
          Invalid;
        Value := IntToHex(Number, 8) + '00001000800000805F9B34FB';
      end
      else
      begin
        Value := VM.GetObject(Args[1].AsRef).Text;
        var Short := Args[2].AsInt <> 0;
        if (Value = '') or (Length(Value) > 32) or (Short and (Length(Value) > 8)) then
          Invalid;
        for var C in Value do
          if not CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']) then
            VM.RaiseJava('java/lang/NumberFormatException', 'UUID hexadecimal syntax');
        if Short then
          Value := Value.PadLeft(8, '0') + '00001000800000805F9B34FB'
        else
          Value := Value.PadLeft(32, '0');
      end;
      O.Text := Value.ToUpper;
      Exit;
    end;
    if N = 'toString' then
      Exit(TJVMValue.Ref(VM.NewString(O.Text)));
    if N = 'equals' then
    begin
      var Other := Args[1].AsRef;
      Exit(TJVMValue.Int(Ord((Other <> 0) and VM.IsAssignable(VM.GetObject(Other).ClassName, UUIDName) and (VM.GetObject(Other).Text = O.Text))));
    end;
    if N = 'hashCode' then
    begin
      var Hash := UInt32(0);
      for var I := 0 to 3 do
      begin
        var Part: UInt64;
        if not TryStrToUInt64('$' + Copy(O.Text, I * 8 + 1, 8), Part) then
          Invalid;
        Hash := Hash xor UInt32(Part);
      end;
      Exit(TJVMValue.Int(Integer(Hash)));
    end;
  end;
  if Owner = ClassName then
  begin
    if N = '<init>' then
    begin
      var Value := Args[1].AsInt;
      if (UInt32(Value) and $FF000000) <> 0 then
        Invalid;
      O.Fields.AddOrSetValue(NumberKey, TJVMValue.Int(Value));
      Exit;
    end;
    var Mask := $FFE000;
    if N = 'getMajorDeviceClass' then
      Mask := $1F00
    else if N = 'getMinorDeviceClass' then
      Mask := $FC;
    Exit(TJVMValue.Int(Int(O, NumberKey) and Mask));
  end;
  if Owner = EnumName then
  begin
    var Parent := VM.GetObject(Ref(O, ParentKey));
    var Values := VM.GetObject(Ref(Parent, ItemsKey));
    var Index := Int(O, IndexKey);
    if N = 'hasMoreElements' then
      Exit(TJVMValue.Int(Ord(Index < Length(Values.Elements))));
    if Index >= Length(Values.Elements) then
      VM.RaiseJava('java/util/NoSuchElementException');
    Result := Values.Elements[Index];
    O.Fields.AddOrSetValue(IndexKey, TJVMValue.Int(Index + 1));
    Exit;
  end;
  if N = '<init>' then
  begin
    TypeCode := Args[1].AsInt;
    var Value := TJVMValue.Ref(0);
    if Method.Descriptor = '(Z)V' then
    begin
      TypeCode := 40;
      Value := TJVMValue.Int(Ord(Args[1].AsInt <> 0));
    end
    else if Method.Descriptor = '(I)V' then
    begin
      if not (TypeCode in [0, 48, 56]) then
        Invalid;
      if TypeCode <> 0 then
        Value := TJVMValue.Ref(BTArray(VM, '[Ljavax/bluetooth/DataElement;', 0));
    end
    else if Method.Descriptor = '(IJ)V' then
    begin
      var Number := Args[2].AsLong;
      case TypeCode of
        8:
          if (Number < 0) or (Number > 255) then
            Invalid;
        9:
          if (Number < 0) or (Number > 65535) then
            Invalid;
        10:
          if (Number < 0) or (Number > $FFFFFFFF) then
            Invalid;
        16:
          if (Number < -128) or (Number > 127) then
            Invalid;
        17:
          if (Number < -32768) or (Number > 32767) then
            Invalid;
        18:
          if (Number < Low(Integer)) or (Number > High(Integer)) then
            Invalid;
        19:
          ;
      else
        Invalid;
      end;
      Value := TJVMValue.Long(Number);
    end
    else
    begin
      var V := Args[2].AsRef;
      if V = 0 then
        Invalid;
      var ObjectValue := VM.GetObject(V);
      case TypeCode of
        32, 64:
          if ObjectValue.ClassName <> 'java/lang/String' then
            Invalid;
        24:
          if not VM.IsAssignable(ObjectValue.ClassName, UUIDName) then
            Invalid;
        11, 12, 20:
          begin
            var Size := 16;
            if TypeCode = 11 then
              Size := 8;
            if (ObjectValue.ClassName <> '[B') or (Length(ObjectValue.Elements) <> Size) then
              Invalid;
            V := BTCloneArray(VM, V);
          end;
      else
        Invalid;
      end;
      Value := TJVMValue.Ref(V);
    end;
    O.Fields.AddOrSetValue(TypeKey, TJVMValue.Int(TypeCode));
    if TypeCode in [48, 56] then
      O.Fields.AddOrSetValue(ItemsKey, Value)
    else if TypeCode in [8, 9, 10, 16, 17, 18, 19, 40] then
      O.Fields.AddOrSetValue(NumberKey, Value)
    else
      O.Fields.AddOrSetValue(ValueKey, Value);
    Exit;
  end;
  TypeCode := Int(O, TypeKey);
  if N = 'getDataType' then
    Exit(TJVMValue.Int(TypeCode));
  if N = 'getLong' then
  begin
    if not (TypeCode in [8, 9, 10, 16, 17, 18, 19]) then
      CastError;
    Exit(O.Fields[NumberKey]);
  end;
  if N = 'getBoolean' then
  begin
    if TypeCode <> 40 then
      CastError;
    Exit(O.Fields[NumberKey]);
  end;
  if N = 'getValue' then
  begin
    if TypeCode in [48, 56] then
    begin
      var E := VM.NewObject(EnumName);
      var EO := VM.GetObject(E);
      EO.Fields.AddOrSetValue(ParentKey, Args[0]);
      EO.Fields.AddOrSetValue(IndexKey, TJVMValue.Int(0));
      Exit(TJVMValue.Ref(E));
    end;
    if not (TypeCode in [11, 12, 20, 24, 32, 64]) then
      CastError;
    Result := O.Fields[ValueKey];
    if TypeCode in [11, 12, 20] then
      Result := TJVMValue.Ref(BTCloneArray(VM, Result.AsRef));
    Exit;
  end;
  if not (TypeCode in [48, 56]) then
    CastError;
  var Old := VM.GetObject(Ref(O, ItemsKey));
  var Count := Length(Old.Elements);
  if N = 'getSize' then
    Exit(TJVMValue.Int(Count));
  var Element := Args[1].AsRef;
  VM.GetObject(Element);
  var Index := Count;
  if N = 'insertElementAt' then
  begin
    Index := Args[2].AsInt;
    if (Index < 0) or (Index > Count) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;
  if N = 'removeElement' then
  begin
    Index := -1;
    for var I := 0 to Count - 1 do
      if Old.Elements[I].AsRef = Element then
      begin
        Index := I;
        Break;
      end;
    if Index < 0 then
      Exit(TJVMValue.Int(0));
  end;
  var NewCount := Count + 1;
  if N = 'removeElement' then
    NewCount := Count - 1;
  if NewCount > Min(65536, VM.MaxArrayLength) then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'DataElement sequence capacity');
  var Values := BTArray(VM, '[Ljavax/bluetooth/DataElement;', NewCount);
  var A := VM.GetObject(Values);
  if N = 'removeElement' then
  begin
    for var I := 0 to Index - 1 do
      A.Elements[I] := Old.Elements[I];
    for var I := Index to NewCount - 1 do
      A.Elements[I] := Old.Elements[I + 1];
    Result := TJVMValue.Int(1);
  end
  else
  begin
    for var I := 0 to Index - 1 do
      A.Elements[I] := Old.Elements[I];
    A.Elements[Index] := Args[1];
    for var I := Index + 1 to NewCount - 1 do
      A.Elements[I] := Old.Elements[I - 1];
  end;
  O.Fields.AddOrSetValue(ItemsKey, TJVMValue.Ref(Values));
end;

end.

