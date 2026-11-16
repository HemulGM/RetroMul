unit JVM.ClassFile;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types;

const
  JVM_ACC_PUBLIC = $0001;
  JVM_ACC_PRIVATE = $0002;
  JVM_ACC_PROTECTED = $0004;
  JVM_ACC_STATIC = $0008;
  JVM_ACC_FINAL = $0010;
  JVM_ACC_SYNCHRONIZED = $0020;
  JVM_ACC_NATIVE = $0100;
  JVM_ACC_ABSTRACT = $0400;

type
  TJVMConstant = record
    Tag: Byte;
    A, B: Word;
    Bits: Int64;
    Text: string;
  end;

  TJVMExceptionHandler = record
    StartPC, EndPC, HandlerPC, CatchType: Word;
  end;

  TJVMField = class
  public
    Name, Descriptor: string;
    Access, ConstantIndex: Word;
    Value: TJVMValue;
  end;

  TJVMClass = class;

  TJVMMethod = class
  public
    Owner: TJVMClass;
    Name, Descriptor: string;
    Access, MaxStack, MaxLocals: Word;
    Signature: TJVMMethodType;
    Code: TBytes;
    InstructionStarts: TArray<Boolean>;
    Handlers: TArray<TJVMExceptionHandler>;
    // Raw metadata is consumed by the context-aware JVM.Verifier.
    StackMap, StackMapTable: TBytes;
    HasStackMap, HasStackMapTable: Boolean;
    VerificationState: Integer;
  end;

  // Successful symbolic field resolution belongs to the referring class's
  // constant pool. It contains no guest object references or mutable values.
  TJVMResolvedField = record
    Field: TJVMField;
    Owner: TJVMClass;
    Key: string;
  end;

  TJVMClass = class
  public
    Name, SuperName: string;
    Interfaces: TArray<string>;
    Major, Minor, Access: Word;
    Constants: TArray<TJVMConstant>;
    ResolvedFields: TArray<TJVMResolvedField>;
    Fields: TObjectList<TJVMField>;
    Methods: TObjectList<TJVMMethod>;
    InitState: Integer; // 0=uninitialized, 1=initializing, 2=ready, 3=failed.
    InitOwner, InitFailure: Integer;
    LinkState: Integer;
    LinkErrorClass, LinkError: string;
    VerificationState: Integer;
    VerificationError: string;
    constructor Create;
    destructor Destroy; override;
    function Constant(Index: Integer; ExpectedTag: Byte = 0): TJVMConstant;
    function UTF8(Index: Integer): string;
    function ClassName(Index: Integer): string;
    procedure MemberRef(Index: Integer; out ClassName, Name, Descriptor: string);
    function FindMethod(const Name, Descriptor: string): TJVMMethod;
    function AddNative(const Name, Descriptor: string; IsStatic: Boolean = False): TJVMMethod;
    procedure ValidateFormat;
    class function Parse(const Data: TBytes; MaxMajor: Word = 51): TJVMClass; static;
  end;

implementation

uses
  JVM.Bytecode;

type
  TClassReader = class
  private
    FData: TBytes;
    FPosition: Integer;
  public
    constructor Create(const Data: TBytes);
    function U1: Byte;
    function U2: Word;
    function U4: UInt32;
    function Bytes(Count: UInt32): TBytes;
    function Remaining: Integer;
    function ModifiedUTF8: string;
  end;

constructor TClassReader.Create(const Data: TBytes);
begin
  inherited Create;
  FData := Data;
end;

function TClassReader.Remaining: Integer;
begin
  Result := Length(FData) - FPosition;
end;

function TClassReader.U1: Byte;
begin
  if Remaining < 1 then
    raise EJVMFormatError.Create('Truncated class file');
  Result := FData[FPosition];
  Inc(FPosition);
end;

function TClassReader.U2: Word;
var
  A: Byte;
begin
  A := U1;
  Result := (Word(A) shl 8) or U1;
end;

function TClassReader.U4: UInt32;
var
  A: Word;
begin
  A := U2;
  Result := (UInt32(A) shl 16) or U2;
end;

function TClassReader.Bytes(Count: UInt32): TBytes;
begin
  if Count > UInt32(Remaining) then
    raise EJVMFormatError.Create('Truncated class attribute');
  Result := Copy(FData, FPosition, Integer(Count));
  Inc(FPosition, Integer(Count));
end;

function TClassReader.ModifiedUTF8: string;
var
  B: TBytes;
  I, N, C, D, E: Integer;
begin
  B := Bytes(U2);
  SetLength(Result, Length(B));
  I := 0;
  N := 0;
  while I < Length(B) do
  begin
    C := B[I];
    Inc(I);
    if (C >= 1) and (C <= $7F) then
      D := C
    else if (C and $E0) = $C0 then
    begin
      if (I >= Length(B)) or ((B[I] and $C0) <> $80) then
        raise EJVMFormatError.Create('Invalid modified UTF-8');
      D := ((C and $1F) shl 6) or (B[I] and $3F);
      Inc(I);
      if (D < $80) and not ((C = $C0) and (D = 0)) then
        raise EJVMFormatError.Create('Overlong modified UTF-8');
    end
    else if (C and $F0) = $E0 then
    begin
      if (I + 1 >= Length(B)) or ((B[I] and $C0) <> $80) or
        ((B[I + 1] and $C0) <> $80) then
        raise EJVMFormatError.Create('Invalid modified UTF-8');
      E := B[I];
      D := ((C and $F) shl 12) or ((E and $3F) shl 6) or (B[I + 1] and $3F);
      Inc(I, 2);
      if D < $800 then
        raise EJVMFormatError.Create('Overlong modified UTF-8');
    end
    else
      raise EJVMFormatError.Create('Invalid modified UTF-8 lead byte');
    Inc(N);
    Result[N] := Char(D);
  end;
  SetLength(Result, N);
end;

constructor TJVMClass.Create;
begin
  inherited;
  Access := JVM_ACC_PUBLIC or $0020;
  Fields := TObjectList<TJVMField>.Create(True);
  Methods := TObjectList<TJVMMethod>.Create(True);
end;

destructor TJVMClass.Destroy;
begin
  Methods.Free;
  Fields.Free;
  inherited;
end;

function TJVMClass.Constant(Index: Integer; ExpectedTag: Byte): TJVMConstant;
begin
  if (Index <= 0) or (Index >= Length(Constants)) then
    raise EJVMFormatError.Create('Invalid constant pool index');
  Result := Constants[Index];
  if (Result.Tag = 0) or ((ExpectedTag <> 0) and (Result.Tag <> ExpectedTag)) then
    raise EJVMFormatError.Create('Invalid constant pool tag');
end;

function TJVMClass.UTF8(Index: Integer): string;
begin
  Result := Constant(Index, 1).Text;
end;

function TJVMClass.ClassName(Index: Integer): string;
begin
  Result := UTF8(Constant(Index, 7).A);
end;

procedure TJVMClass.MemberRef(Index: Integer; out ClassName, Name, Descriptor: string);
var
  C, NT: TJVMConstant;
begin
  C := Constant(Index);
  if not (C.Tag in [9, 10, 11]) then
    raise EJVMFormatError.Create('Expected member reference');
  ClassName := Self.ClassName(C.A);
  NT := Constant(C.B, 12);
  Name := UTF8(NT.A);
  Descriptor := UTF8(NT.B);
end;

function TJVMClass.FindMethod(const Name, Descriptor: string): TJVMMethod;
var
  M: TJVMMethod;
begin
  for M in Methods do
    if (M.Name = Name) and (M.Descriptor = Descriptor) then
      Exit(M);
  Result := nil;
end;

function TJVMClass.AddNative(const Name, Descriptor: string; IsStatic: Boolean): TJVMMethod;
begin
  if FindMethod(Name, Descriptor) <> nil then
    raise EJVMError.Create('Duplicate native method');
  Result := TJVMMethod.Create;
  Methods.Add(Result);
  Result.Owner := Self;
  Result.Name := Name;
  Result.Descriptor := Descriptor;
  Result.Signature := JVMMethodType(Descriptor);
  Result.Access := JVM_ACC_NATIVE or JVM_ACC_PUBLIC;
  if IsStatic then
    Result.Access := Result.Access or JVM_ACC_STATIC;
end;

procedure TJVMClass.ValidateFormat;
var
  CP, NT: TJVMConstant;
  Seen: TDictionary<string, Boolean>;
  Key, N, D: string;
  I, Tag: Integer;
  F: TJVMField;
  M: TJVMMethod;
  Sig: TJVMMethodType;

  procedure Visibility(Flags: Word);
  var
    V: Word;
  begin
    V := Flags and 7;
    if (V <> 0) and ((V and (V - 1)) <> 0) then
      raise EJVMFormatError.Create('Conflicting visibility flags');
  end;

  procedure MethodName(const Name, Descriptor: string);
  begin
    JVMMemberName(Name, True);
    Sig := JVMMethodType(Descriptor);
    if ((Name = '<init>') or (Name = '<clinit>')) and (Sig.ReturnType <> 'V') then
      raise EJVMFormatError.Create('Initializer must return void');
    if (Name = '<clinit>') and (Descriptor <> '()V') then
      raise EJVMFormatError.Create('Invalid class initializer descriptor');
  end;

begin
  JVMClassName(Name, False);
  if SuperName <> '' then
    JVMClassName(SuperName, False);
  if (Access and (JVM_ACC_FINAL or JVM_ACC_ABSTRACT)) = (JVM_ACC_FINAL or JVM_ACC_ABSTRACT) then
    raise EJVMFormatError.Create('Class is both final and abstract');
  if (Access and $0200) <> 0 then
  begin
    if ((Access and JVM_ACC_ABSTRACT) = 0) or ((Access and JVM_ACC_FINAL) <> 0) or
      (SuperName <> 'java/lang/Object') then
      raise EJVMFormatError.Create('Invalid interface declaration');
  end;
  Seen := TDictionary<string, Boolean>.Create;
  try
    for N in Interfaces do
    begin
      JVMClassName(N, False);
      if Seen.ContainsKey(N) then
        raise EJVMFormatError.Create('Duplicate direct interface');
      Seen.Add(N, True);
    end;
    I := 1;
    while I < Length(Constants) do
    begin
      CP := Constant(I);
      case CP.Tag of
        7:
          JVMClassName(UTF8(CP.A));
        8:
          UTF8(CP.A);
        9, 10, 11:
          begin
            ClassName(CP.A);
            NT := Constant(CP.B, 12);
            N := UTF8(NT.A);
            D := UTF8(NT.B);
            if CP.Tag = 9 then
            begin
              JVMMemberName(N, False);
              JVMFieldType(D);
            end
            else
            begin
              MethodName(N, D);
              if (N = '<clinit>') or ((CP.Tag = 11) and (N = '<init>')) then
                raise EJVMFormatError.Create('Illegal initializer reference');
            end;
          end;
        12:
          begin
            N := UTF8(CP.A);
            D := UTF8(CP.B);
            if D.StartsWith('(') then
              MethodName(N, D)
            else
            begin
              JVMMemberName(N, False);
              JVMFieldType(D);
            end;
          end;
      end;
      if CP.Tag in [5, 6] then
        Inc(I);
      Inc(I);
    end;
    Seen.Clear;
    for F in Fields do
    begin
      JVMMemberName(F.Name, False);
      JVMFieldType(F.Descriptor);
      Visibility(F.Access);
      if (F.Access and ($0010 or $0040)) = ($0010 or $0040) then
        raise EJVMFormatError.Create('Field is both final and volatile');
      if ((Access and $0200) <> 0) and ((F.Access and $0019) <> $0019) then
        raise EJVMFormatError.Create('Interface field must be public static final');
      Key := F.Name + ':' + F.Descriptor;
      if Seen.ContainsKey(Key) then
        raise EJVMFormatError.Create('Duplicate field');
      Seen.Add(Key, True);
      if F.ConstantIndex <> 0 then
      begin
        case F.Descriptor[1] of
          'B', 'C', 'I', 'S', 'Z':
            Tag := 3;
          'F':
            Tag := 4;
          'J':
            Tag := 5;
          'D':
            Tag := 6;
        else
          if F.Descriptor <> 'Ljava/lang/String;' then
            raise EJVMFormatError.Create('Invalid ConstantValue field type');
          Tag := 8;
        end;
        Constant(F.ConstantIndex, Tag);
      end;
    end;
    Seen.Clear;
    for M in Methods do
    begin
      MethodName(M.Name, M.Descriptor);
      Visibility(M.Access);
      if M.Signature.ArgumentSlots + Ord((M.Access and JVM_ACC_STATIC) = 0) > 255 then
        raise EJVMFormatError.Create('Method parameter slot limit exceeded');
      Key := M.Name + M.Descriptor;
      if Seen.ContainsKey(Key) then
        raise EJVMFormatError.Create('Duplicate method');
      Seen.Add(Key, True);
      if ((M.Access and JVM_ACC_ABSTRACT) <> 0) and ((M.Access and $093A) <> 0) then
        raise EJVMFormatError.Create('Invalid abstract method flags');
      if M.Name = '<init>' then
      begin
        if ((Access and $0200) <> 0) or ((M.Access and not $1887) <> 0) then
          raise EJVMFormatError.Create('Invalid constructor flags');
      end
      else if M.Name = '<clinit>' then
      begin
        if (Major >= 51) and ((M.Access and JVM_ACC_STATIC) = 0) then
          raise EJVMFormatError.Create('Class initializer must be static');
        M.Access := M.Access or JVM_ACC_STATIC;
      end
      else if ((Access and $0200) <> 0) and (Major <= 51) then
      begin
        if ((M.Access and $0401) <> $0401) or ((M.Access and $093E) <> 0) then
          raise EJVMFormatError.Create('Invalid interface method flags');
      end;
    end;
  finally
    Seen.Free;
  end;
end;

class function TJVMClass.Parse(const Data: TBytes; MaxMajor: Word): TJVMClass;
var
  R, CodeReader: TClassReader;
  C: TJVMClass;
  I, J, K, N, Count: Integer;
  CP: TJVMConstant;
  F: TJVMField;
  M: TJVMMethod;
  Attr: string;
  Payload: TBytes;
  HasCode: Boolean;
  Sig: TJVMMethodType;

  procedure ReadCode;
  var
    X, Y: Integer;
    H: TJVMExceptionHandler;
    S: string;
  begin
    if HasCode then
      raise EJVMFormatError.Create('Duplicate Code attribute');
    HasCode := True;
    CodeReader := TClassReader.Create(Payload);
    try
      M.MaxStack := CodeReader.U2;
      M.MaxLocals := CodeReader.U2;
      N := Integer(CodeReader.U4);
      if (N < 1) or (N > 65535) then
        raise EJVMFormatError.Create('Invalid code length');
      M.Code := CodeReader.Bytes(N);
      try
        M.InstructionStarts := JVMInstructionMap(M.Code, M.MaxLocals);
      except
        on E: EJVMFormatError do
          raise EJVMVerifyError.Create(C.Name + '.' + M.Name + M.Descriptor + ': ' + E.Message);
      end;
      SetLength(M.Handlers, CodeReader.U2);
      for X := 0 to High(M.Handlers) do
      begin
        H.StartPC := CodeReader.U2;
        H.EndPC := CodeReader.U2;
        H.HandlerPC := CodeReader.U2;
        H.CatchType := CodeReader.U2;
        if (H.StartPC >= H.EndPC) or (H.EndPC > N) or (H.HandlerPC >= N) then
          raise EJVMFormatError.Create('Invalid exception handler');
        if not M.InstructionStarts[H.StartPC] or not M.InstructionStarts[H.EndPC] or
          not M.InstructionStarts[H.HandlerPC] then
          raise EJVMFormatError.Create('Exception handler enters an instruction operand');
        if H.CatchType <> 0 then
          C.ClassName(H.CatchType);
        M.Handlers[X] := H;
      end;
      Y := CodeReader.U2;
      for X := 1 to Y do
      begin
        S := C.UTF8(CodeReader.U2);
        if S = 'StackMap' then
        begin
          if M.HasStackMap then
            raise EJVMFormatError.Create('Duplicate StackMap');
          M.HasStackMap := True;
          M.StackMap := CodeReader.Bytes(CodeReader.U4);
        end
        else if S = 'StackMapTable' then
        begin
          if M.HasStackMapTable then
            raise EJVMFormatError.Create('Duplicate StackMapTable');
          M.HasStackMapTable := True;
          M.StackMapTable := CodeReader.Bytes(CodeReader.U4);
        end
        else
          CodeReader.Bytes(CodeReader.U4);
      end;
      if CodeReader.Remaining <> 0 then
        raise EJVMFormatError.Create('Trailing Code attribute data');
      Sig := M.Signature;
      X := Sig.ArgumentSlots;
      if ((M.Access and JVM_ACC_STATIC) = 0) and (M.Name <> '<clinit>') then
        Inc(X);
      if X > M.MaxLocals then
        raise EJVMFormatError.Create('Insufficient method locals');
    finally
      CodeReader.Free;
    end;
  end;

begin
  if Length(Data) > 16 * 1024 * 1024 then
    raise EJVMFormatError.Create('Class exceeds 16 MiB');
  R := TClassReader.Create(Data);
  C := TJVMClass.Create;
  try
    if R.U4 <> $CAFEBABE then
      raise EJVMFormatError.Create('Invalid class signature');
    C.Minor := R.U2;
    C.Major := R.U2;
    if (C.Major < 45) or (C.Major > MaxMajor) then
      raise EJVMUnsupported.CreateFmt('Unsupported class version %d.%d (maximum %d)', [C.Major, C.Minor, MaxMajor]);
    Count := R.U2;
    if Count < 1 then
      raise EJVMFormatError.Create('Empty constant pool');
    SetLength(C.Constants, Count);
    I := 1;
    while I < Count do
    begin
      CP := Default(TJVMConstant);
      CP.Tag := R.U1;
      case CP.Tag of
        1:
          CP.Text := R.ModifiedUTF8;
        3, 4:
          CP.Bits := R.U4;
        5, 6:
          begin
            CP.Bits := Int64(UInt64(R.U4) shl 32);
            CP.Bits := CP.Bits or R.U4;
            if I + 1 >= Count then
              raise EJVMFormatError.Create('Truncated wide constant');
          end;
        7, 8:
          CP.A := R.U2;
        9, 10, 11, 12:
          begin
            CP.A := R.U2;
            CP.B := R.U2;
          end;
        15, 16, 18:
          raise EJVMUnsupported.Create('Method handles and invokedynamic are not implemented');
      else
        raise EJVMFormatError.Create('Unknown constant pool tag');
      end;
      C.Constants[I] := CP;
      Inc(I);
      if CP.Tag in [5, 6] then
        Inc(I);
    end;
    C.Access := R.U2;
    C.Name := C.ClassName(R.U2);
    I := R.U2;
    if I <> 0 then
      C.SuperName := C.ClassName(I)
    else if C.Name <> 'java/lang/Object' then
      raise EJVMFormatError.Create('Missing superclass');
    SetLength(C.Interfaces, R.U2);
    for I := 0 to High(C.Interfaces) do
      C.Interfaces[I] := C.ClassName(R.U2);
    Count := R.U2;
    for I := 1 to Count do
    begin
      F := TJVMField.Create;
      C.Fields.Add(F);
      F.Access := R.U2;
      F.Name := C.UTF8(R.U2);
      F.Descriptor := C.UTF8(R.U2);
      F.Value := JVMDefaultValue(F.Descriptor);
      K := R.U2;
      for J := 1 to K do
      begin
        Attr := C.UTF8(R.U2);
        Payload := R.Bytes(R.U4);
        if Attr = 'ConstantValue' then
        begin
          if (Length(Payload) <> 2) or (F.ConstantIndex <> 0) then
            raise EJVMFormatError.Create('Invalid ConstantValue');
          F.ConstantIndex := (Word(Payload[0]) shl 8) or Payload[1];
          C.Constant(F.ConstantIndex);
        end;
      end;
    end;
    Count := R.U2;
    for I := 1 to Count do
    begin
      M := TJVMMethod.Create;
      C.Methods.Add(M);
      M.Owner := C;
      M.Access := R.U2;
      M.Name := C.UTF8(R.U2);
      M.Descriptor := C.UTF8(R.U2);
      M.Signature := JVMMethodType(M.Descriptor);
      K := R.U2;
      HasCode := False;
      for J := 1 to K do
      begin
        Attr := C.UTF8(R.U2);
        Payload := R.Bytes(R.U4);
        if Attr = 'Code' then
          ReadCode;
      end;
      if HasCode = ((M.Access and (JVM_ACC_NATIVE or JVM_ACC_ABSTRACT)) <> 0) then
        raise EJVMFormatError.Create('Invalid method Code presence');
    end;
    Count := R.U2;
    for I := 1 to Count do
    begin
      C.UTF8(R.U2);
      R.Bytes(R.U4);
    end;
    if R.Remaining <> 0 then
      raise EJVMFormatError.Create('Trailing class file data');
    C.ValidateFormat;
    Result := C;
    C := nil;
  finally
    C.Free;
    R.Free;
  end;
end;

end.

