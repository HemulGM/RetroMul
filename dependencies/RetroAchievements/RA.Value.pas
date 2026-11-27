unit RA.Value;

interface

uses
  RA.DefinitionLayout, RA.Memory, RA.MemoryValues, RA.Progress, RA.Trigger;

type
  TRAValue = class
  private
    FEvaluator: TRATrigger;
    FLastValue: TRAMemoryValue;
    FRCValue: TRAMemorySample;
    FRawRCValue, FLegacyHasSource: Boolean;
    function RCValueBits: Cardinal;
    procedure Initialize(const Expression: string; RawRCValue, AllowTrailingText: Boolean; out NextPosition: Integer);
  public
    constructor Create(const Expression: string; RawRCValue: Boolean = False; AllowTrailingText: Boolean = False);
    constructor CreatePrefix(const Expression: string; out NextPosition: Integer; RawRCValue: Boolean = False);
    destructor Destroy; override;
    function UpdateMemory(const ReadMemory: TRAMemoryRead; AllowUnavailable: Boolean = False): Boolean;
    function EvaluatePrepared: TRAMemoryValue;
    function Evaluate(const ReadMemory: TRAMemoryRead): TRAMemoryValue;
    procedure Reset;
    procedure ClearProgress;
    function ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
    procedure WriteProgress(const IO: TRAProgressIO);
    procedure ReadProgress(const IO: TRAProgressIO);
    procedure CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean = False);
    procedure MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
    procedure RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
    procedure WriteRCProgress(const IO: TRAProgressIO);
    procedure ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
    function RCCurrentValue: Cardinal;
    function IsRCSimpleValue: Boolean;
    procedure ValidateRCModifiedOperands;
    function ValueFromMeasuredHits: Boolean;
    function RestoreRCDisplayValue(AllowLegacyProgress: Boolean = False): TRAMemoryValue;
    property CurrentValue: TRAMemoryValue read FLastValue;
  end;

function RAValueAsInteger(const Value: TRAMemoryValue): Integer;

implementation

uses
  System.Math, System.SysUtils, RA.Conditions, RA.Errors;

function NormalizeLegacyValue(const Clause: string): string;
var
  Terms: TArray<string>;
  Prefix: Char;
  Term: string;
  Multiplier, Digit: Integer;
begin
  Result := '';
  if Clause = '' then
    raise ERAConditionError.CreateWithCode('Empty legacy value term', RAErrorInvalidMemoryOperand);
  Terms := Clause.Split(['_']);
  Prefix := 'A';
  for var Index := 0 to High(Terms) do
  begin
    Term := Terms[Index];
    if Term = '' then
      raise ERAConditionError.CreateWithCode('Empty legacy value term', RAErrorInvalidMemoryOperand);
    Prefix := 'A';
    Multiplier := Pos('*', Term) + 1;
    if Multiplier > 1 then
    begin
      if (Multiplier <= Length(Term)) and (Term[Multiplier] = '-') then
      begin
        Delete(Term, Multiplier, 1);
        Prefix := 'B';
      end;
      Digit := Multiplier;
      if (Digit <= Length(Term)) and (Term[Digit] = '+') then
        Inc(Digit);
      while (Digit <= Length(Term)) and CharInSet(Term[Digit], ['0'..'9']) do
        Inc(Digit);
      if (Digit <= Length(Term)) and (Term[Digit] = '.') then
        Insert('f', Term, Multiplier);
    end;
    if Length(Term) >= 62 then
      raise ERAConditionError.CreateWithCode('Legacy value term is too long', RAErrorInvalidValue);

    if Result <> '' then
      Result := Result + '_';
    if (Index = High(Terms)) and (Prefix = 'A') then
      Prefix := 'M';
    Result := Result + Prefix + ':' + Term;
  end;
  if Prefix = 'B' then
    Result := Result + '_M:0';
end;

constructor TRAValue.Create(const Expression: string; RawRCValue, AllowTrailingText: Boolean);
var
  NextPosition: Integer;
begin
  inherited Create;
  Initialize(Expression, RawRCValue, AllowTrailingText, NextPosition);
end;

constructor TRAValue.CreatePrefix(const Expression: string; out NextPosition: Integer; RawRCValue: Boolean);
begin
  inherited Create;
  Initialize(Expression, RawRCValue, True, NextPosition);
end;

procedure TRAValue.Initialize(const Expression: string; RawRCValue, AllowTrailingText: Boolean; out NextPosition: Integer);
var
  Clauses: TArray<string>;
  Definition, Group: TRATriggerDefinition;
  Legacy: Boolean;
  Clause, ValueText: string;
begin
  FRawRCValue := RawRCValue;
  NextPosition := Length(Expression) + 1;
  if Expression = '' then
    raise ERAConditionError.CreateWithCode('Missing value expression', RAErrorInvalidMemoryOperand);

  Legacy := (Length(Expression) < 2) or (Expression[2] <> ':');
  if AllowTrailingText and not Legacy then
  begin
    Definition := TRATriggerDefinition.ParsePrefix(Expression, NextPosition, '$');
    if (NextPosition <= Length(Expression)) and CharInSet(Expression[NextPosition], ['s', 'S']) then
      raise ERAConditionError.CreateWithCode('Alternative trigger groups are invalid in a value expression', RAErrorInvalidOperator);
    FEvaluator := TRATrigger.Create(Definition, True);
    Exit;
  end;

  ValueText := Expression;
  if Legacy then
  begin
    NextPosition := 1;
    while (NextPosition <= Length(Expression)) and not CharInSet(Expression[NextPosition], [#0, ':', ')']) do
      Inc(NextPosition);
    if NextPosition <= Length(Expression) then
    begin
      if not AllowTrailingText then
        raise ERAConditionError.CreateAt('Unexpected legacy value separator', NextPosition);
      ValueText := Copy(Expression, 1, NextPosition - 1);
    end;
  end;
  if ValueText = '' then
    raise ERAConditionError.CreateAt('Invalid memory operand', 1, RAErrorInvalidMemoryOperand);
  Clauses := ValueText.Split(['$']);
  SetLength(Definition.Alternatives, Length(Clauses) - 1);
  for var Index := 0 to High(Clauses) do
  begin
    Clause := Clauses[Index];
    if Legacy then
      Clause := NormalizeLegacyValue(Clause);
    Group := TRATriggerDefinition.Parse(Clause);
    if Length(Group.Alternatives) <> 0 then
      raise ERAConditionError.CreateWithCode('Alternative trigger groups are invalid in a value expression', RAErrorInvalidOperator);
    if Legacy then
    begin
      FLegacyHasSource := FLegacyHasSource or (Length(Group.Core) > 1);
      for var ConditionIndex := 0 to High(Group.Core) do
        Group.Core[ConditionIndex].LegacyValueComparison :=
          (Group.Core[ConditionIndex].Kind = TRAConditionKind.Measured) and
          (Group.Core[ConditionIndex].OperatorKind in [TRAOperator.Equal..TRAOperator.GreaterOrEqual]);
    end;
    if Index = 0 then
      Definition.Core := Group.Core
    else
      Definition.Alternatives[Index - 1] := Group.Core;
  end;
  FEvaluator := TRATrigger.Create(Definition, True);
end;

destructor TRAValue.Destroy;
begin
  FEvaluator.Free;
  inherited;
end;

function TRAValue.UpdateMemory(const ReadMemory: TRAMemoryRead; AllowUnavailable: Boolean): Boolean;
begin
  Result := FEvaluator.UpdateMemory(ReadMemory, AllowUnavailable);
end;

function TRAValue.EvaluatePrepared: TRAMemoryValue;
var
  Value: TRAMemoryValue;
begin
  if FEvaluator.TryEvaluatePreparedValue(Value) then
  begin
    FLastValue := Value;
    FRCValue.Update(RCValueBits);
  end;
  Result := FLastValue;
end;

function TRAValue.Evaluate(const ReadMemory: TRAMemoryRead): TRAMemoryValue;
begin
  if UpdateMemory(ReadMemory) then
    Result := EvaluatePrepared
  else
    Result := FLastValue;
end;

procedure TRAValue.Reset;
begin
  FEvaluator.Reset;
  FLastValue := Default(TRAMemoryValue);
  FRCValue := Default(TRAMemorySample);
end;

procedure TRAValue.ClearProgress;
begin
  FEvaluator.ClearProgress;
  FLastValue := Default(TRAMemoryValue);
  FRCValue := Default(TRAMemorySample);
end;

function TRAValue.ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
begin
  Result := FEvaluator.ReferencesMemref(Memref);
end;

procedure TRAValue.WriteProgress(const IO: TRAProgressIO);
begin
  IO.WriteFlag(FLastValue.IsFloat);
  IO.WriteUInt(FLastValue.Unsigned);
  FEvaluator.WriteProgress(IO);
end;

procedure TRAValue.ReadProgress(const IO: TRAProgressIO);
begin
  FLastValue.IsFloat := IO.ReadFlag;
  FLastValue.Unsigned := IO.ReadUInt;
  FRCValue.Restore(RCValueBits, 0, False);
  FEvaluator.ReadProgress(IO);
end;

function TRAValue.RCValueBits: Cardinal;
begin
  if FRawRCValue then
    Result := FLastValue.Unsigned
  else
    Result := Cardinal(RAValueAsInteger(FLastValue));
end;

function TRAValue.ValueFromMeasuredHits: Boolean;
begin
  Result := FEvaluator.ValueFromMeasuredHits;
end;

procedure TRAValue.ValidateRCModifiedOperands;
begin
  FEvaluator.ValidateRCModifiedOperands;
end;

function TRAValue.IsRCSimpleValue: Boolean;
begin
  Result := not FLegacyHasSource and FEvaluator.IsRCSimpleValue;
end;

function TRAValue.RestoreRCDisplayValue(AllowLegacyProgress: Boolean): TRAMemoryValue;
var
  Value: TRAMemoryValue;
begin
  if (AllowLegacyProgress or not FLegacyHasSource) and FEvaluator.TryReadSimpleValue(Value, AllowLegacyProgress) then
  begin
    FLastValue := Value;
    if AllowLegacyProgress and not IsRCSimpleValue then
      FRCValue.Restore(RCValueBits, 0, False);
  end;
  Result := FLastValue;
end;

procedure TRAValue.MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
begin
  FEvaluator.MeasureDefinitionLayout(Layout);
end;

procedure TRAValue.CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean);
begin
  FEvaluator.CollectRCMemrefs(Memrefs, Bind);
  if Bind and FRawRCValue then
    RestoreRCDisplayValue;
end;

procedure TRAValue.RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
begin
  FEvaluator.RestoreRCMemrefs(Memrefs);
end;

procedure TRAValue.WriteRCProgress(const IO: TRAProgressIO);
const
  ChangedThisFrame = $00010000;
  HasConditions = $01000000;
var
  Flags: Cardinal;
begin
  Flags := 0;
  if FRCValue.Changed then
    Flags := ChangedThisFrame;
  if FEvaluator.HasRCValueConditionProgress then
    Flags := Flags or HasConditions;
  IO.WriteUInt(Flags);
  IO.WriteUInt(FRCValue.Current);
  IO.WriteUInt(FRCValue.Prior);
  if (Flags and HasConditions) <> 0 then
    FEvaluator.WriteRCValueConditions(IO);
end;

procedure TRAValue.ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
const
  ChangedThisFrame = $00010000;
  HasConditions = $01000000;
var
  Flags, Current, Prior: Cardinal;
begin
  Flags := IO.ReadUInt;
  Current := IO.ReadUInt;
  Prior := IO.ReadUInt;
  FEvaluator.ReadRCValueConditions(IO, (Flags and HasConditions) <> 0, Apply);
  if Apply then
  begin
    FRCValue.Restore(Current, Prior, (Flags and ChangedThisFrame) <> 0);
    FLastValue.IsFloat := FRawRCValue and FEvaluator.ReadPreparedValueType;
    FLastValue.Unsigned := Current;
  end;
end;

function TRAValue.RCCurrentValue: Cardinal;
begin
  Result := FRCValue.Current;
end;

function RAValueAsInteger(const Value: TRAMemoryValue): Integer;
begin
  if not Value.IsFloat then
    Exit(Integer(Value.Unsigned));
  if IsNan(Value.Float) or IsInfinite(Value.Float) or (Abs(Value.Float) >= 9223372036854775808.0) then
    Exit(0);
  Result := Integer(Cardinal(Trunc(Value.Float) and $FFFFFFFF));
end;

end.

