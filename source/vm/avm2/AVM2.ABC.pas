unit AVM2.ABC;

interface

uses
  System.SysUtils;

type
  EAVM2Error = class(Exception);

  TABCReader = record
    Data: TBytes;
    Position: Integer;
    function Remaining: Integer;
    function U8: Byte;
    function U16: Word;
    function U32: Cardinal;
    function U30: Integer;
    function S24: Integer;
    function Bytes(Count: Integer): TBytes;
    procedure Need(Count: Integer);
  end;

  TABCNamespace = record
    Kind: Byte;
    Name: Integer;
  end;

  TABCMultiname = record
    Kind: Byte;
    Name, NamespaceIndex, NamespaceSet, BaseType: Integer;
    Parameters: TArray<Integer>;
  end;

  TABCTrait = record
    Kind, Flags, ValueKind: Byte;
    Name, Slot, Target, Value: Integer;
    Metadata: TArray<Integer>;
  end;

  TABCMetadata = record
    Name: Integer;
    Keys, Values: TArray<Integer>;
  end;

  TABCMethod = record
    Flags: Byte;
    Name, ReturnType, Body: Integer;
    ParameterTypes, ParameterNames, DefaultValues: TArray<Integer>;
    DefaultKinds: TBytes;
  end;

  TABCDefinition = record
    Init: Integer;
    Traits: TArray<TABCTrait>;
  end;

  TABCInstance = record
    Name, SuperName, ProtectedNamespace: Integer;
    Flags: Byte;
    Interfaces: TArray<Integer>;
    Definition: TABCDefinition;
  end;

  TABCException = record
    First, Last, Target, TypeName, VariableName: Integer;
  end;

  TABCBody = record
    Method, StackLimit, LocalCount, InitialScope, ScopeLimit: Integer;
    Code: TBytes;
    Exceptions: TArray<TABCException>;
    Traits: TArray<TABCTrait>;
  end;

  TABCFile = class
  private
    FReader: TABCReader;
    function Count(MinBytes: Integer = 1): Integer;
    function PoolCount(MinBytes: Integer = 1): Integer;
    function Index(Length: Integer; AllowZero: Boolean = True): Integer;
    function Indices(Length: Integer; AllowZero: Boolean = True): TArray<Integer>;
    procedure CheckIndex(Value, Length: Integer; AllowZero: Boolean = True);
    procedure DefaultValue(Value: Integer; Kind: Byte);
    procedure ReadPool;
    procedure ReadMethods;
    procedure ReadMetadata;
    function ReadTraits: TArray<TABCTrait>;
    function ReadDefinition: TABCDefinition;
    procedure ReadClasses;
    procedure ReadBodies;
  public
    Ints: TArray<Integer>;
    UInts: TArray<Cardinal>;
    Doubles: TArray<Double>;
    Strings: TArray<string>;
    Namespaces: TArray<TABCNamespace>;
    NamespaceSets: TArray<TArray<Integer>>;
    Multinames: TArray<TABCMultiname>;
    Methods: TArray<TABCMethod>;
    Metadata: TArray<TABCMetadata>;
    Instances: TArray<TABCInstance>;
    Classes, Scripts: TArray<TABCDefinition>;
    Bodies: TArray<TABCBody>;
    constructor Create(const Data: TBytes);
  end;

implementation

const
  MaxABCEntries = 65535;
  MaxABCBytes = 16 * 1024 * 1024;
  MaxABCString = 1024 * 1024;

procedure TABCReader.Need(Count: Integer);
begin
  if (Count < 0) or (Position < 0) or (Count > Remaining) then
    raise EAVM2Error.Create('Truncated ABC data');
end;

function TABCReader.Remaining: Integer;
begin
  Result := Length(Data) - Position;
end;

function TABCReader.U8: Byte;
begin
  Need(1);
  Result := Data[Position];
  Inc(Position);
end;

function TABCReader.U16: Word;
begin
  Need(2);
  Result := Word(Data[Position]) or (Word(Data[Position + 1]) shl 8);
  Inc(Position, 2);
end;

function TABCReader.U32: Cardinal;
var
  I: Integer;
  Part: Byte;
begin
  Result := 0;
  for I := 0 to 4 do
  begin
    Part := U8;
    if (I = 4) and (Part > $0F) then
      raise EAVM2Error.Create('Invalid ABC encoded U32');
    Result := Result or (Cardinal(Part and $7F) shl (I * 7));
    if Part and $80 = 0 then
      Exit;
  end;
end;

function TABCReader.U30: Integer;
var
  Value: Cardinal;
begin
  Value := U32;
  if Value > $3FFFFFFF then
    raise EAVM2Error.Create('Invalid ABC encoded U30');
  Result := Integer(Value);
end;

function TABCReader.S24: Integer;
begin
  Need(3);
  Result := Integer(Data[Position]) or (Integer(Data[Position + 1]) shl 8) or
    (Integer(Data[Position + 2]) shl 16);
  Inc(Position, 3);
  if Result and $800000 <> 0 then
    Dec(Result, $1000000);
end;

function TABCReader.Bytes(Count: Integer): TBytes;
begin
  Need(Count);
  Result := Copy(Data, Position, Count);
  Inc(Position, Count);
end;

function TABCFile.Count(MinBytes: Integer): Integer;
begin
  Result := FReader.U30;
  if (Result > MaxABCEntries) or (Result > FReader.Remaining div MinBytes) then
    raise EAVM2Error.Create('Excessive ABC table size');
end;

function TABCFile.PoolCount(MinBytes: Integer): Integer;
begin
  Result := FReader.U30;
  if Result = 0 then
    Result := 1;
  if (Result > MaxABCEntries + 1) or (Result - 1 > FReader.Remaining div MinBytes) then
    raise EAVM2Error.Create('Excessive ABC constant pool size');
end;

procedure TABCFile.CheckIndex(Value, Length: Integer; AllowZero: Boolean);
begin
  if (Value >= Length) or ((Value = 0) and not AllowZero) then
    raise EAVM2Error.CreateFmt('ABC index %d outside table of size %d', [Value, Length]);
end;

function TABCFile.Index(Length: Integer; AllowZero: Boolean): Integer;
begin
  Result := FReader.U30;
  CheckIndex(Result, Length, AllowZero);
end;

function TABCFile.Indices(Length: Integer; AllowZero: Boolean): TArray<Integer>;
var
  I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to High(Result) do
    Result[I] := Index(Length, AllowZero);
end;

procedure TABCFile.DefaultValue(Value: Integer; Kind: Byte);
begin
  case Kind of
    0, $0A, $0B, $0C:
      ;
    1:
      CheckIndex(Value, Length(Strings));
    3:
      CheckIndex(Value, Length(Ints));
    4:
      CheckIndex(Value, Length(UInts));
    6:
      CheckIndex(Value, Length(Doubles));
    5, 8, $16..$1A:
      CheckIndex(Value, Length(Namespaces), False);
  else
    raise EAVM2Error.Create('Invalid ABC constant kind');
  end;
end;

procedure TABCFile.ReadPool;
var
  I, Size: Integer;
  Value: TBytes;
  Kind: Byte;
begin
  SetLength(Ints, PoolCount);
  for I := 1 to High(Ints) do
    Ints[I] := Integer(FReader.U32);
  SetLength(UInts, PoolCount);
  for I := 1 to High(UInts) do
    UInts[I] := FReader.U32;
  SetLength(Doubles, PoolCount(8));
  for I := 1 to High(Doubles) do
  begin
    FReader.Need(8);
    Move(FReader.Data[FReader.Position], Doubles[I], 8);
    Inc(FReader.Position, 8);
  end;
  SetLength(Strings, PoolCount);
  for I := 1 to High(Strings) do
  begin
    Size := FReader.U30;
    if Size > MaxABCString then
      raise EAVM2Error.Create('ABC string size limit');
    Value := FReader.Bytes(Size);
    Strings[I] := TEncoding.UTF8.GetString(Value);
  end;
  SetLength(Namespaces, PoolCount(2));
  for I := 1 to High(Namespaces) do
  begin
    Kind := FReader.U8;
    if not (Kind in [5, 8, $16..$1A]) then
      raise EAVM2Error.Create('Invalid ABC namespace kind');
    Namespaces[I].Kind := Kind;
    Namespaces[I].Name := Index(Length(Strings));
  end;
  SetLength(NamespaceSets, PoolCount);
  for I := 1 to High(NamespaceSets) do
    NamespaceSets[I] := Indices(Length(Namespaces), False);
  SetLength(Multinames, PoolCount);
  for I := 1 to High(Multinames) do
  begin
    Kind := FReader.U8;
    Multinames[I].Kind := Kind;
    case Kind of
      7, $0D:
        begin
          Multinames[I].NamespaceIndex := Index(Length(Namespaces));
          Multinames[I].Name := Index(Length(Strings));
        end;
      $0F, $10:
        Multinames[I].Name := Index(Length(Strings));
      $11, $12:
        ;
      9, $0E:
        begin
          Multinames[I].Name := Index(Length(Strings));
          Multinames[I].NamespaceSet := Index(Length(NamespaceSets), False);
        end;
      $1B, $1C:
        Multinames[I].NamespaceSet := Index(Length(NamespaceSets), False);
      $1D:
        begin
          Multinames[I].BaseType := Index(Length(Multinames), False);
          Multinames[I].Parameters := Indices(Length(Multinames));
        end;
    else
      raise EAVM2Error.CreateFmt('Invalid ABC multiname kind $%.2x', [Kind]);
    end;
  end;
end;

procedure TABCFile.ReadMethods;
var
  I, J, Params, Defaults: Integer;
  Method: TABCMethod;
begin
  SetLength(Methods, Count(4));
  for I := 0 to High(Methods) do
  begin
    Method := Default(TABCMethod);
    Method.Body := -1;
    Params := Count;
    Method.ReturnType := Index(Length(Multinames));
    SetLength(Method.ParameterTypes, Params);
    for J := 0 to Params - 1 do
      Method.ParameterTypes[J] := Index(Length(Multinames));
    Method.Name := Index(Length(Strings));
    Method.Flags := FReader.U8;
    if Method.Flags and 8 <> 0 then
    begin
      Defaults := Count(2);
      if Defaults > Params then
        raise EAVM2Error.Create('Too many ABC optional parameters');
      SetLength(Method.DefaultValues, Defaults);
      SetLength(Method.DefaultKinds, Defaults);
      for J := 0 to Defaults - 1 do
      begin
        Method.DefaultValues[J] := FReader.U30;
        Method.DefaultKinds[J] := FReader.U8;
        DefaultValue(Method.DefaultValues[J], Method.DefaultKinds[J]);
      end;
    end;
    if Method.Flags and $80 <> 0 then
    begin
      SetLength(Method.ParameterNames, Params);
      for J := 0 to Params - 1 do
        Method.ParameterNames[J] := Index(Length(Strings));
    end;
    Methods[I] := Method;
  end;
end;

procedure TABCFile.ReadMetadata;
var
  I, J, Items: Integer;
begin
  SetLength(Metadata, Count(2));
  for I := 0 to High(Metadata) do
  begin
    Metadata[I].Name := Index(Length(Strings));
    Items := Count(2);
    SetLength(Metadata[I].Keys, Items);
    SetLength(Metadata[I].Values, Items);
    for J := 0 to Items - 1 do
      Metadata[I].Keys[J] := Index(Length(Strings));
    for J := 0 to Items - 1 do
      Metadata[I].Values[J] := Index(Length(Strings));
  end;
end;

function TABCFile.ReadTraits: TArray<TABCTrait>;
var
  I: Integer;
  Trait: TABCTrait;
begin
  SetLength(Result, Count(4));
  for I := 0 to High(Result) do
  begin
    Trait := Default(TABCTrait);
    Trait.Name := Index(Length(Multinames), False);
    Trait.Flags := FReader.U8;
    Trait.Kind := Trait.Flags and 15;
    Trait.Slot := FReader.U30;
    case Trait.Kind of
      0, 6:
        begin
          Trait.Target := Index(Length(Multinames));
          Trait.Value := FReader.U30;
          if Trait.Value <> 0 then
          begin
            Trait.ValueKind := FReader.U8;
            DefaultValue(Trait.Value, Trait.ValueKind);
          end;
        end;
      1..3, 5:
        Trait.Target := Index(Length(Methods));
      4:
        Trait.Target := Index(Length(Classes));
    else
      raise EAVM2Error.Create('Invalid ABC trait kind');
    end;
    if Trait.Flags and $40 <> 0 then
      Trait.Metadata := Indices(Length(Metadata));
    Result[I] := Trait;
  end;
end;

function TABCFile.ReadDefinition: TABCDefinition;
begin
  Result.Init := Index(Length(Methods));
  Result.Traits := ReadTraits;
end;

procedure TABCFile.ReadClasses;
var
  I, Size: Integer;
begin
  Size := Count(8);
  SetLength(Instances, Size);
  SetLength(Classes, Size);
  for I := 0 to Size - 1 do
  begin
    Instances[I].Name := Index(Length(Multinames), False);
    Instances[I].SuperName := Index(Length(Multinames));
    Instances[I].Flags := FReader.U8;
    if Instances[I].Flags and 8 <> 0 then
      Instances[I].ProtectedNamespace := Index(Length(Namespaces), False);
    Instances[I].Interfaces := Indices(Length(Multinames), False);
    Instances[I].Definition := ReadDefinition;
  end;
  for I := 0 to Size - 1 do
    Classes[I] := ReadDefinition;
end;

procedure TABCFile.ReadBodies;
var
  I, J: Integer;
  Body: TABCBody;
  Handler: TABCException;
begin
  SetLength(Bodies, Count(8));
  for I := 0 to High(Bodies) do
  begin
    Body := Default(TABCBody);
    Body.Method := Index(Length(Methods));
    if Methods[Body.Method].Body >= 0 then
      raise EAVM2Error.Create('Duplicate ABC method body');
    Methods[Body.Method].Body := I;
    Body.StackLimit := FReader.U30;
    Body.LocalCount := FReader.U30;
    Body.InitialScope := FReader.U30;
    Body.ScopeLimit := FReader.U30;
    if (Body.LocalCount = 0) or (Body.LocalCount > MaxABCEntries) or
      (Body.StackLimit > MaxABCEntries) or (Body.ScopeLimit > MaxABCEntries) or
      (Body.InitialScope > Body.ScopeLimit) then
      raise EAVM2Error.Create('Invalid ABC method resource counts');
    Body.Code := FReader.Bytes(FReader.U30);
    SetLength(Body.Exceptions, Count(5));
    for J := 0 to High(Body.Exceptions) do
    begin
      Handler.First := FReader.U30;
      Handler.Last := FReader.U30;
      Handler.Target := FReader.U30;
      Handler.TypeName := Index(Length(Multinames));
      Handler.VariableName := Index(Length(Multinames));
      if (Handler.First > Handler.Last) or (Handler.Last > Length(Body.Code)) or
        (Handler.Target >= Length(Body.Code)) then
        raise EAVM2Error.Create('Invalid ABC exception interval');
      Body.Exceptions[J] := Handler;
    end;
    Body.Traits := ReadTraits;
    Bodies[I] := Body;
  end;
end;

constructor TABCFile.Create(const Data: TBytes);
var
  Major, Minor, I: Integer;
begin
  inherited Create;
  if Length(Data) > MaxABCBytes then
    raise EAVM2Error.Create('ABC file size limit');
  FReader.Data := Data;
  Minor := FReader.U16;
  Major := FReader.U16;
  if (Major <> 46) or (Minor <> 16) then
    raise EAVM2Error.CreateFmt('Unsupported ABC version %d.%d', [Major, Minor]);
  ReadPool;
  ReadMethods;
  ReadMetadata;
  ReadClasses;
  SetLength(Scripts, Count(2));
  for I := 0 to High(Scripts) do
    Scripts[I] := ReadDefinition;
  ReadBodies;
  if FReader.Remaining <> 0 then
    raise EAVM2Error.Create('Unexpected data after ABC file');
  FReader.Data := nil;
end;

end.

