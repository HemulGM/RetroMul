unit JVM.Types;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

type
  EJVMError = class(Exception);

  EJVMFormatError = class(EJVMError);

  EJVMClassFormatError = class(EJVMFormatError);

  EJVMUnsupported = class(EJVMError);

  EJVMVerifyError = class(EJVMError);

  EJVMLinkError = class(EJVMError)
  public
    JavaClass: string;
    constructor Create(const JavaClass, Message: string);
  end;

  EJVMClassMissing = class(EJVMLinkError)
  public
    MissingName: string;
    constructor Create(const Name: string);
  end;

  TJVMKind = (Empty, Int, Long, Float, Double, Reference, ReturnAddress);

  TJVMValue = record
    Kind: TJVMKind;
    Bits: Int64;
    class function Int(Value: Integer): TJVMValue; static;
    class function Long(Value: Int64): TJVMValue; static;
    class function Float(Value: Single): TJVMValue; static;
    class function Double(Value: System.Double): TJVMValue; static;
    class function Ref(Value: Integer): TJVMValue; static;
    function AsInt: Integer;
    function AsLong: Int64;
    function AsFloat: Single;
    function AsDouble: System.Double;
    function AsRef: Integer;
    function Slots: Integer;
  end;

  TJVMMethodType = record
    Arguments: TArray<string>;
    ReturnType: string;
    ArgumentSlots: Integer;
  end;

function JVMMethodType(const Descriptor: string): TJVMMethodType;

function JVMDefaultValue(const Descriptor: string): TJVMValue;

function JVMFieldType(const Descriptor: string): string;

procedure JVMClassName(const Name: string; AllowArray: Boolean = True);

procedure JVMMemberName(const Name: string; IsMethod: Boolean);

implementation

constructor EJVMLinkError.Create(const JavaClass, Message: string);
begin
  inherited Create(Message);
  Self.JavaClass := JavaClass;
end;

constructor EJVMClassMissing.Create(const Name: string);
begin
  inherited Create('java/lang/NoClassDefFoundError', 'Class not available: ' + Name);
  MissingName := Name;
end;

class function TJVMValue.Int(Value: Integer): TJVMValue;
begin
  Result.Kind := TJVMKind.Int;
  Result.Bits := Value;
end;

class function TJVMValue.Long(Value: Int64): TJVMValue;
begin
  Result.Kind := TJVMKind.Long;
  Result.Bits := Value;
end;

class function TJVMValue.Float(Value: Single): TJVMValue;
var
  B: UInt32;
begin
  Move(Value, B, 4);
  Result.Kind := TJVMKind.Float;
  Result.Bits := B;
end;

class function TJVMValue.Double(Value: System.Double): TJVMValue;
begin
  Result.Kind := TJVMKind.Double;
  Move(Value, Result.Bits, 8);
end;

class function TJVMValue.Ref(Value: Integer): TJVMValue;
begin
  Result.Kind := TJVMKind.Reference;
  Result.Bits := Value;
end;

function TJVMValue.AsInt: Integer;
begin
  if Kind <> TJVMKind.Int then
    raise EJVMError.Create('Expected Java int');
  Result := Integer(Bits);
end;

function TJVMValue.AsLong: Int64;
begin
  if Kind <> TJVMKind.Long then
    raise EJVMError.Create('Expected Java long');
  Result := Bits;
end;

function TJVMValue.AsFloat: Single;
var
  B: UInt32;
begin
  if Kind <> TJVMKind.Float then
    raise EJVMError.Create('Expected Java float');
  B := UInt32(Bits);
  Move(B, Result, 4);
end;

function TJVMValue.AsDouble: System.Double;
begin
  if Kind <> TJVMKind.Double then
    raise EJVMError.Create('Expected Java double');
  Move(Bits, Result, 8);
end;

function TJVMValue.AsRef: Integer;
begin
  if Kind <> TJVMKind.Reference then
    raise EJVMError.Create('Expected Java reference');
  Result := Integer(Bits);
end;

function TJVMValue.Slots: Integer;
begin
  if Kind in [TJVMKind.Long, TJVMKind.Double] then
    Result := 2
  else
    Result := 1;
end;

function ReadType(const S: string; var P: Integer; AllowVoid: Boolean): string;
var
  Start: Integer;
begin
  Start := P;
  if P > Length(S) then
    raise EJVMFormatError.Create('Truncated descriptor');
  case S[P] of
    'B', 'C', 'D', 'F', 'I', 'J', 'S', 'Z':
      Inc(P);
    'V':
      begin
        if not AllowVoid then
          raise EJVMFormatError.Create('Void field/argument');
        Inc(P);
      end;
    '[':
      begin
        repeat
          Inc(P)
        until (P > Length(S)) or (S[P] <> '[');
        if P - Start > 255 then
          raise EJVMFormatError.Create('Too many array dimensions');
        ReadType(S, P, False);
      end;
    'L':
      begin
        Inc(P);
        while (P <= Length(S)) and (S[P] <> ';') do
        begin
          if CharInSet(S[P], ['.', '[']) then
            raise EJVMFormatError.Create('Invalid object descriptor');
          Inc(P);
        end;
        if (P > Length(S)) or (P = Start + 1) then
          raise EJVMFormatError.Create('Invalid object descriptor');
        JVMClassName(Copy(S, Start + 1, P - Start - 1), False);
        Inc(P);
      end;
  else
    raise EJVMFormatError.Create('Invalid descriptor');
  end;
  Result := Copy(S, Start, P - Start);
end;

function JVMFieldType(const Descriptor: string): string;
var
  P: Integer;
begin
  P := 1;
  Result := ReadType(Descriptor, P, False);
  if P <> Length(Descriptor) + 1 then
    raise EJVMFormatError.Create('Trailing descriptor data');
end;

procedure JVMMemberName(const Name: string; IsMethod: Boolean);
begin
  if Name = '' then
    raise EJVMFormatError.Create('Empty member name');
  if IsMethod and ((Name = '<init>') or (Name = '<clinit>')) then
    Exit;
  for var C in Name do
    if CharInSet(C, ['.', ';', '[', '/']) or (IsMethod and CharInSet(C, ['<', '>'])) then
      raise EJVMFormatError.Create('Invalid member name: ' + Name);
end;

procedure JVMClassName(const Name: string; AllowArray: Boolean);
var
  Part: string;
  Parts: TArray<string>;
begin
  if Name = '' then
    raise EJVMFormatError.Create('Empty class name');
  if Name[1] = '[' then
  begin
    if not AllowArray then
      raise EJVMFormatError.Create('Array where class name is required');
    JVMFieldType(Name);
    Exit;
  end;
  Parts := Name.Split(['/']);
  for Part in Parts do
    JVMMemberName(Part, False);
end;

function JVMMethodType(const Descriptor: string): TJVMMethodType;
var
  P, N: Integer;
  S: string;
begin
  Result := Default(TJVMMethodType);
  if (Length(Descriptor) < 3) or (Descriptor[1] <> '(') then
    raise EJVMFormatError.Create('Invalid method descriptor');
  P := 2;
  while (P <= Length(Descriptor)) and (Descriptor[P] <> ')') do
  begin
    S := ReadType(Descriptor, P, False);
    N := Length(Result.Arguments);
    SetLength(Result.Arguments, N + 1);
    Result.Arguments[N] := S;
    if (S = 'J') or (S = 'D') then
      Inc(Result.ArgumentSlots, 2)
    else
      Inc(Result.ArgumentSlots);
    if Result.ArgumentSlots > 255 then
      raise EJVMFormatError.Create('Too many method arguments');
  end;
  if P > Length(Descriptor) then
    raise EJVMFormatError.Create('Missing method return type');
  Inc(P);
  Result.ReturnType := ReadType(Descriptor, P, True);
  if P <> Length(Descriptor) + 1 then
    raise EJVMFormatError.Create('Trailing method descriptor data');
end;

function JVMDefaultValue(const Descriptor: string): TJVMValue;
begin
  JVMFieldType(Descriptor);
  case Descriptor[1] of
    'J':
      Result := TJVMValue.Long(0);
    'F':
      Result := TJVMValue.Float(0);
    'D':
      Result := TJVMValue.Double(0);
    'L', '[':
      Result := TJVMValue.Ref(0);
  else
    Result := TJVMValue.Int(0);
  end;
end;

end.

