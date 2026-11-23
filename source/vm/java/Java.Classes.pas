unit Java.Classes;

interface

uses
  System.SysUtils, System.Generics.Collections, JVM.Types, JVM.ClassFile;

type
  // Small assembler for our shared Java library. Composed library methods run
  // as ordinary verified guest code, preserving virtual overrides and budgets.
  TJavaClassBuilder = class
  private
    FClass: TJVMClass;
    FCode: TList<Byte>;
    FLabels: TDictionary<string, Integer>;
    FFixups: TList<TPair<Integer, string>>;
    function Constant(const Value: TJVMConstant): Word;
  public
    constructor Create(const Name, Parent: string; Access: Word = JVM_ACC_PUBLIC or $0020);
    destructor Destroy; override;
    function UTF(const Value: string): Word;
    function ClassRef(const Name: string): Word;
    function Member(const Owner, Name, Descriptor: string; Tag: Byte = 10): Word;
    function LongConstant(Value: Int64): Word;
    function IntConstant(Value: Integer): Word;
    function StringConstant(const Value: string): Word;
    function Field(const Name, Descriptor: string; Access: Word): Word;
    procedure Start;
    procedure Emit(const Bytes: array of Byte);
    procedure Ref(Op: Byte; Index: Word);
    procedure Mark(const Name: string);
    function Position(const Name: string): Integer;
    procedure Jump(Op: Byte; const Target: string);
    procedure Finish(const Name, Descriptor: string; Access, Stack, Locals: Word);
    function Detach: TJVMClass;
    property JavaClass: TJVMClass read FClass;
  end;

implementation

constructor TJavaClassBuilder.Create(const Name, Parent: string; Access: Word);
begin
  inherited Create;
  FClass := TJVMClass.Create;
  FClass.Name := Name;
  FClass.SuperName := Parent;
  FClass.Access := Access;
  SetLength(FClass.Constants, 1);
  FCode := TList<Byte>.Create;
  FLabels := TDictionary<string, Integer>.Create;
  FFixups := TList<TPair<Integer, string>>.Create;
end;

destructor TJavaClassBuilder.Destroy;
begin
  FFixups.Free;
  FLabels.Free;
  FCode.Free;
  FClass.Free;
  inherited;
end;

function TJavaClassBuilder.Constant(const Value: TJVMConstant): Word;
var
  I: Integer;
begin
  for I := 1 to High(FClass.Constants) do
    if (FClass.Constants[I].Tag = Value.Tag) and (FClass.Constants[I].A = Value.A) and
      (FClass.Constants[I].B = Value.B) and (FClass.Constants[I].Text = Value.Text) and
      (FClass.Constants[I].Bits = Value.Bits) then
      Exit(I);
  I := Length(FClass.Constants);
  SetLength(FClass.Constants, I + 1 + Ord(Value.Tag in [5, 6]));
  FClass.Constants[I] := Value;
  Result := I;
end;

function TJavaClassBuilder.UTF(const Value: string): Word;
var
  C: TJVMConstant;
begin
  C := Default(TJVMConstant);
  C.Tag := 1;
  C.Text := Value;
  Result := Constant(C);
end;

function TJavaClassBuilder.ClassRef(const Name: string): Word;
var
  C: TJVMConstant;
begin
  C := Default(TJVMConstant);
  C.Tag := 7;
  C.A := UTF(Name);
  Result := Constant(C);
end;

function TJavaClassBuilder.Member(const Owner, Name, Descriptor: string; Tag: Byte): Word;
var
  C: TJVMConstant;
  NT, CL: Word;
begin
  C := Default(TJVMConstant);
  C.Tag := 12;
  C.A := UTF(Name);
  C.B := UTF(Descriptor);
  NT := Constant(C);
  CL := ClassRef(Owner);
  C := Default(TJVMConstant);
  C.Tag := Tag;
  C.A := CL;
  C.B := NT;
  Result := Constant(C);
end;

function TJavaClassBuilder.LongConstant(Value: Int64): Word;
var
  C: TJVMConstant;
begin
  C := Default(TJVMConstant);
  C.Tag := 5;
  C.Bits := Value;
  Result := Constant(C);
end;

function TJavaClassBuilder.IntConstant(Value: Integer): Word;
var
  C: TJVMConstant;
begin
  C := Default(TJVMConstant);
  C.Tag := 3;
  C.Bits := Value;
  Result := Constant(C);
end;

function TJavaClassBuilder.StringConstant(const Value: string): Word;
var
  C: TJVMConstant;
begin
  C := Default(TJVMConstant);
  C.Tag := 8;
  C.A := UTF(Value);
  Result := Constant(C);
end;

function TJavaClassBuilder.Field(const Name, Descriptor: string; Access: Word): Word;
var
  F: TJVMField;
begin
  F := TJVMField.Create;
  F.Name := Name;
  F.Descriptor := Descriptor;
  F.Access := Access;
  F.Value := JVMDefaultValue(Descriptor);
  FClass.Fields.Add(F);
  Result := Member(FClass.Name, Name, Descriptor, 9);
end;

procedure TJavaClassBuilder.Start;
begin
  FCode.Clear;
  FLabels.Clear;
  FFixups.Clear;
end;

procedure TJavaClassBuilder.Emit(const Bytes: array of Byte);
begin
  for var B in Bytes do
    FCode.Add(B);
end;

procedure TJavaClassBuilder.Ref(Op: Byte; Index: Word);
begin
  Emit([Op, Byte(Index shr 8), Byte(Index)]);
end;

procedure TJavaClassBuilder.Mark(const Name: string);
begin
  FLabels.Add(Name, FCode.Count);
end;

function TJavaClassBuilder.Position(const Name: string): Integer;
begin
  Result := FLabels[Name];
end;

procedure TJavaClassBuilder.Jump(Op: Byte; const Target: string);
begin
  FFixups.Add(TPair<Integer, string>.Create(FCode.Count, Target));
  Emit([Op, 0, 0]);
end;

procedure TJavaClassBuilder.Finish(const Name, Descriptor: string; Access, Stack, Locals: Word);
var
  M: TJVMMethod;
  Offset: Integer;
begin
  for var Fixup in FFixups do
  begin
    Offset := FLabels[Fixup.Value] - Fixup.Key;
    if (Offset < Low(SmallInt)) or (Offset > High(SmallInt)) then
      raise EJVMError.Create('Library branch too large');
    FCode[Fixup.Key + 1] := Byte(Offset shr 8);
    FCode[Fixup.Key + 2] := Byte(Offset);
  end;
  M := TJVMMethod.Create;
  M.Owner := FClass;
  M.Name := Name;
  M.Descriptor := Descriptor;
  M.Signature := JVMMethodType(Descriptor);
  M.Access := Access;
  M.MaxStack := Stack;
  M.MaxLocals := Locals;
  M.Code := FCode.ToArray;
  FClass.Methods.Add(M);
end;

function TJavaClassBuilder.Detach: TJVMClass;
begin
  Result := FClass;
  FClass := nil;
end;

end.

