unit RA.Trigger;

interface

{$SCOPEDENUMS ON}

uses
  RA.Conditions, RA.DefinitionLayout, RA.Memory, RA.MemoryValues, RA.Progress;

type
  TRATriggerState = (Waiting, Active, Paused, Primed, Triggered, Disabled);

  TRATriggerFrame = (Waiting, Active, Paused, Primed, Triggered, Disabled, Reset, Inactive);

  TRAMeasuredProgress = record
    Value, Target: Cardinal;
    AsPercent: Boolean;
    Known: Boolean;
  end;

  TRATrigger = class
  private
    type
      TOperand = record
        Definition: TRAOperand;
        LocalSample: TRAMemorySample;
        Memref: TRARuntimeMemref;
        function Sample: PRAMemorySample;
        function ReadSample(Current: Boolean = False; ReadPrior: Boolean = False): TRAMemoryValue;
        function Update(const ReadMemory: TRAMemoryRead; const Base: TRAMemoryValue; Indirect: Boolean): Boolean;
        function Read(out HasValue: Boolean; Current: Boolean = False; ReadPrior: Boolean = False; Recall: Boolean = False): TRAMemoryValue;
      end;

      TEvaluationPhase = (Pause, Reset, Targets, Measured, Other);

      TGroupFrame = record
        Satisfied, Primed, Paused: Boolean;
        HasMeasurement, MeasuredFromHits: Boolean;
        Measurement: TRAMemoryValue;
      end;

      TExpressionKind = (Operand, Alias, Arithmetic);

      TArithmeticMode = (Normal, Accumulate, ApplySource, NegativeSource, AccumulateNegativeSource, RememberSource);

      TOperandReader = reference to function(ReadPrior: Boolean; out HasValue, Changed: Boolean): TRAMemoryValue;

      TExpression = record
        Kind: TExpressionKind;
        Operand: TOperand;
        Left, Right, Base: Integer;
        LeftRecall, RightRecall, BaseRecall: Boolean;
        OperatorKind: TRAOperator;
        Mode: TArithmeticMode;
        History: TRAValueHistory;
        StorageSize: TRAMemorySize;
        Value: TRAMemoryValue;
        HasValue, LegacyComparisonOperand: Boolean;
        function ApplyArithmetic(L, R: TRAMemoryValue; LeftAvailable, RightAvailable: Boolean; Restoring: Boolean = False): TRAMemoryValue;
        function ReadValue(Recall: Boolean; Current: Boolean = False): TRAMemoryValue;
        function ReadCalculated(Current, ReadPrior: Boolean): TRAMemoryValue;
        function RequestedSize: TRAMemorySize;
        function IsFloatOperand(Recall: Boolean): Boolean;
        function IsDirectIntegerRead: Boolean;
      end;

      TComparisonMode = (TypedValue, StoredSample, SharedSampleDelta, AlwaysFalse);

      TCondition = record
        Kind: TRAConditionKind;
        OperatorKind: TRAOperator;
        RequiredHits, Hits: Cardinal;
        TruthFlags: Cardinal;
        Left, Right: Integer;
        LeftRecall, RightRecall: Boolean;
        ComparisonMode: TComparisonMode;
        class function SelectComparisonMode(const LeftExpression, RightExpression: TExpression): TComparisonMode; static;
        function MatchesComparison(Comparison: Integer): Boolean;
        procedure CompileLegacyComparison(const LeftExpression, RightExpression: TExpression);
        function Test(const LeftExpression, RightExpression: TExpression): Boolean;
        function Evaluate(Matched: Boolean; var AndNext, OrNext: Boolean; ResetNext: Boolean; var HasHits, ResetCondition: Boolean): Boolean;
      end;

      TProgressCondition = record
        EvaluatedIndex, Left, Right: Integer;
      end;

      TGroup = record
        Conditions: TArray<TCondition>;
        ProgressConditions: TArray<TProgressCondition>;
        Expressions: TArray<TExpression>;
        EvaluationOrder: TArray<Integer>;
        FirstInPhase: array[TEvaluationPhase] of Integer;
        PastPhase: array[TEvaluationPhase] of Integer;
        Paused, HasRememberCondition: Boolean;
        LegacyComparisonOperands: Integer;
        function Update(const ReadMemory: TRAMemoryRead; RefreshSamples: Boolean = True; AllowUnavailable: Boolean = False): Boolean;
        class function MakeOperandReader(Operand: TOperand; Current, Recall: Boolean): TOperandReader; static;
        class function MakeCalculatedReader(Expression: TExpression; Current: Boolean): TOperandReader; static;
        class function MakeArithmeticReader(Expression: TExpression; Left, Right: TOperandReader): TRACalculatedValue; static;
        class function MakeAddressResolver(Base: TOperandReader; Offset: Cardinal): TRAIndirectAddress; static;
        procedure BindModifiedMemrefs(Memrefs: TRARuntimeMemrefs);
        procedure ResetHits;
        function IsIndirect(Expr: Integer): Boolean;
        procedure WriteRCProgress(const IO: TRAProgressIO);
        procedure ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
        function ContainsMeasurementFromHits(Value: Cardinal): Boolean;
        function Evaluate(var ResetRequested, HasHits, ResetCondition: Boolean): TGroupFrame;
      end;
  private
    FGroups: TArray<TGroup>;
    FState: TRATriggerState;
    FHasHits: Boolean;
    FFirstRCGroup: Integer;
    FMeasured: TRAMeasuredProgress;
    procedure ResetHits;
    function HasSingleMeasurement: Boolean;
    function EvaluatePreparedFrame: TRATriggerFrame;
  public
    // Unsupported definitions raise ERAConditionError on construction.
    constructor Create(const Definition: TRATriggerDefinition; ValueMode: Boolean = False);
    // Standalone testing evaluates as active and retries a previously unavailable read.
    function TestFrame(const ReadMemory: TRAMemoryRead): Boolean;
    function TestPreparedFrame: Boolean;
    function TestStoredFrame: Boolean;
    function HasRCRequiredHits: Boolean;
    function ValueFromMeasuredHits: Boolean;
    function IsRCSimpleValue: Boolean;
    procedure ValidateRCModifiedOperands;
    procedure RefreshStoredValues;
    function TryReadSimpleValue(out Value: TRAMemoryValue; IncludeRemember: Boolean = False): Boolean;
    function ReadPreparedValueType: Boolean;
    function UpdateMemory(const ReadMemory: TRAMemoryRead; AllowUnavailable: Boolean = False): Boolean;
    function TryEvaluatePreparedValue(out Value: TRAMemoryValue): Boolean;
    function EvaluateFrame(const ReadMemory: TRAMemoryRead): TRATriggerFrame;
    procedure Reset;
    procedure ClearProgress;
    procedure Disable;
    function ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
    procedure WriteProgress(const IO: TRAProgressIO);
    procedure ReadProgress(const IO: TRAProgressIO);
    procedure CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean = False);
    procedure MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
    procedure RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
    procedure WriteRCProgress(const IO: TRAProgressIO);
    procedure ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
    function HasRCValueConditionProgress: Boolean;
    procedure WriteRCValueConditions(const IO: TRAProgressIO);
    procedure ReadRCValueConditions(const IO: TRAProgressIO; Present, Apply: Boolean);
    property State: TRATriggerState read FState;
    property Measured: TRAMeasuredProgress read FMeasured;
  end;

procedure ReadRATriggerMeasurement(const Definition: TRATriggerDefinition; out Target: Cardinal; out AsPercent: Boolean);

implementation

uses
  System.Generics.Collections, System.Hash, System.Math, System.SysUtils,
  RA.Errors;

function FloatToUnsigned(Value: Double): Cardinal;
begin
  if IsNan(Value) or IsInfinite(Value) or (Abs(Value) >= 9223372036854775808.0) then
    Exit(0);
  Result := Cardinal(Trunc(Value) and $FFFFFFFF);
end;

procedure ReadRATriggerMeasurement(const Definition: TRATriggerDefinition; out Target: Cardinal; out AsPercent: Boolean);
var
  TriggerTarget: Cardinal;
  MeasuredAsPercent: Boolean;

  procedure ReadGroup(const Group: TRAConditionGroup);
  var
    GroupTarget: Cardinal;
  begin
    GroupTarget := 0;
    for var Condition in Group do
    begin
      if not (Condition.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]) then
        Continue;
      if GroupTarget <> 0 then
        raise ERAConditionError.CreateWithCode(RAErrorMessage(RAErrorMultipleMeasured), RAErrorMultipleMeasured);
      if Condition.RequiredHits <> 0 then
        GroupTarget := Condition.RequiredHits
      else
        case Condition.Right.Kind of
          TRAOperandKind.UnsignedConstant:
            GroupTarget := Condition.Right.Value.Unsigned;
          TRAOperandKind.FloatConstant:
            GroupTarget := FloatToUnsigned(Condition.Right.FloatLiteral);
        else
          raise ERAConditionError.CreateWithCode(RAErrorMessage(RAErrorInvalidMeasuredTarget), RAErrorInvalidMeasuredTarget);
        end;
      if (TriggerTarget <> 0) and (TriggerTarget <> GroupTarget) then
        raise ERAConditionError.CreateWithCode(RAErrorMessage(RAErrorMultipleMeasured), RAErrorMultipleMeasured);
      TriggerTarget := GroupTarget;
      MeasuredAsPercent := MeasuredAsPercent or (Condition.Kind = TRAConditionKind.MeasuredPercent);
    end;
  end;

begin
  TriggerTarget := 0;
  MeasuredAsPercent := False;
  ReadGroup(Definition.Core);
  for var Group in Definition.Alternatives do
    ReadGroup(Group);
  Target := TriggerTarget;
  AsPercent := MeasuredAsPercent;
end;

function IntegerValue(const Value: TRAMemoryValue): Cardinal;
begin
  if Value.IsFloat then
    Result := FloatToUnsigned(Value.Float)
  else
    Result := Value.Unsigned;
end;

function FloatValue(const Value: TRAMemoryValue): Single;
begin
  if Value.IsFloat then
    Result := Value.Float
  else
    Result := Value.Unsigned;
end;

function ResolveMemoryAddress(const Base: TRAMemoryValue; Offset: Cardinal): Cardinal; forward;

function TRATrigger.TOperand.Sample: PRAMemorySample;
begin
  if Memref <> nil then
    Exit(@Memref.Sample);
  Result := @LocalSample;
end;

function TRATrigger.TOperand.ReadSample(Current, ReadPrior: Boolean): TRAMemoryValue;
var
  History: TRAValueHistory;
begin
  History := Definition.Memory.History;
  if ReadPrior then
    History := TRAValueHistory.Prior
  else if Current then
    History := TRAValueHistory.Current;
  Result := DecodeRAMemoryValue(Sample^.Read(History), Definition.Memory.Size);
end;

function TRATrigger.TOperand.Update(const ReadMemory: TRAMemoryRead; const Base: TRAMemoryValue; Indirect: Boolean): Boolean;
var
  Raw, Address: Cardinal;
begin
  if (Memref <> nil) or not Definition.IsMemoryReference then
    Exit(True);
  Address := ResolveMemoryAddress(Base, Definition.Memory.Address);
  if not TryReadRARawValue(ReadMemory, Address, Definition.Memory.Size, Raw) and not Indirect then
    Exit(False);
  // Prior changes only when the selected bits change. Delta follows the shared
  // byte/word so that it still represents the previous emulated frame.
  if Definition.Memory.History = TRAValueHistory.Prior then
    Raw := MaskRARawValue(Raw, Definition.Memory.Size);
  LocalSample.Update(Raw);
  Result := True;
end;

function TRATrigger.TOperand.Read(out HasValue: Boolean; Current, ReadPrior, Recall: Boolean): TRAMemoryValue;
var
  Digits: Integer;
  Mask, Raw: Cardinal;
begin
  HasValue := True;
  if not Definition.IsMemoryReference then
    Exit(Definition.Value);

  Result := ReadSample(Current, ReadPrior);
  // rcheevos decodes floating-point operands from the retained sample by format
  // even when the underlying reference has no value type.
  HasValue := Result.IsFloat or (Memref = nil) or not Memref.Invalidated;
  if not HasValue then
    Exit(Default(TRAMemoryValue));
  // Recall keeps the memory format but does not reapply BCD or inversion.
  if Recall or Result.IsFloat or (Definition.Kind = TRAOperandKind.Memory) then
    Exit;

  case Definition.Memory.Size of
    TRAMemorySize.UInt8:
      Digits := 2;
    TRAMemorySize.UInt16, TRAMemorySize.UInt16BE:
      Digits := 4;
    TRAMemorySize.UInt24, TRAMemorySize.UInt24BE:
      Digits := 6;
    TRAMemorySize.UInt32, TRAMemorySize.UInt32BE:
      Digits := 8;
  else
    Digits := 0;
  end;

  case Definition.Kind of
    TRAOperandKind.BCD:
      if Digits <> 0 then
      begin
        Raw := Result.Unsigned;
        Result.Unsigned := 0;
        for var Index := Digits - 1 downto 0 do
          Result.Unsigned := Result.Unsigned * 10 + ((Raw shr (4 * Index)) and $F);
      end;
    TRAOperandKind.Inverted:
      begin
        if Digits <> 0 then
          Mask := Cardinal((UInt64(1) shl (Digits * 4)) - 1)
        else if Definition.Memory.Size in [TRAMemorySize.LowNibble, TRAMemorySize.HighNibble] then
          Mask := $F
        else
          Mask := 1;
        Result.Unsigned := Result.Unsigned xor Mask;
      end;
  end;
end;

function CompareDirectValues(const Left, Right: TRAMemoryValue): Integer;
const
  FloatEpsilon = 1.1920928955078125E-7;
var
  L, R, Threshold: Single;
  Difference: Double;
begin
  if not Left.IsFloat and not Right.IsFloat then
  begin
    if Left.Unsigned < Right.Unsigned then
      Exit(-1);
    Exit(Ord(Left.Unsigned > Right.Unsigned));
  end;

  L := FloatValue(Left);
  R := FloatValue(Right);
  if IsNan(L) or IsNan(R) then
    Exit(-1);
  if L = R then
    Exit(0);
  if IsInfinite(L) or IsInfinite(R) then
  begin
    // With two infinities, the reference uses an infinite tolerance.
    if IsInfinite(L) and IsInfinite(R) then
      Exit(0);
    if L > R then
      Exit(1);
    Exit(-1);
  end;
  Difference := Double(L) - Double(R);
  // Round the tolerance to Single before comparing denormalized values.
  Threshold := Min(Abs(L), Abs(R)) * FloatEpsilon;
  if Abs(Difference) <= Threshold then
    Result := 0
  else if Difference > Threshold then
    Result := 1
  else
    Result := -1;
end;

function FloatRemainder(const Numerator, Denominator: Single): Single;
const
  SignMask = $80000000;
  FractionMask = $007FFFFF;
  HiddenBit = $00800000;
  Infinite = $7F800000;
var
  Bits, Sign, Dividend, Divisor, Remainder: Cardinal;
  Exponent, DivisorExponent: Integer;

  function Significand(Magnitude: Cardinal; out BiasedExponent: Integer): Cardinal;
  begin
    BiasedExponent := Integer(Magnitude shr 23);
    Result := Magnitude and FractionMask;
    if BiasedExponent = 0 then
      BiasedExponent := 1
    else
      Result := Result or HiddenBit;
  end;

begin
  Move(Numerator, Bits, SizeOf(Bits));
  Sign := Bits and SignMask;
  Dividend := Bits and not Cardinal(SignMask);
  Move(Denominator, Bits, SizeOf(Bits));
  Divisor := Bits and not Cardinal(SignMask);

  if Divisor = 0 then
    Exit(0); // The evaluator converts an undefined remainder to zero.
  if Dividend > Infinite then
    Exit(Numerator);
  if Divisor > Infinite then
    Exit(Denominator);
  if Dividend = Infinite then
  begin
    {$IF Defined(MSWINDOWS) and Defined(CPUX64)}
    Bits := Sign or $7FC00000;
    {$ELSE}
    Bits := $FFC00000;
    {$ENDIF}
    Move(Bits, Result, SizeOf(Result));
    Exit;
  end;
  if Dividend < Divisor then
    Exit(Numerator);

  Dividend := Significand(Dividend, Exponent);
  Divisor := Significand(Divisor, DivisorExponent);
  // Align the significands while reducing each intermediate remainder. The
  // quotient itself can be much larger than any native integer.
  Remainder := Dividend mod Divisor;
  while (Exponent > DivisorExponent) and (Remainder <> 0) do
  begin
    Remainder := (Remainder shl 1) mod Divisor;
    Dec(Exponent);
  end;

  Bits := Sign;
  if Remainder <> 0 then
  begin
    while (Exponent > 1) and (Remainder < HiddenBit) do
    begin
      Remainder := Remainder shl 1;
      Dec(Exponent);
    end;
    if Remainder >= HiddenBit then
      Bits := Bits or (Cardinal(Exponent) shl 23) or (Remainder and FractionMask)
    else
      Bits := Bits or Remainder;
  end;
  Move(Bits, Result, SizeOf(Result));
end;

function NegatedFloatValue(const Value: TRAMemoryValue): Single;
begin
  if Value.IsFloat then
    Result := -Value.Float
  else
    // rcheevos negates integer operands as signed 32-bit values before promotion.
    Result := Integer(Cardinal((-Int64(Value.Unsigned)) and High(Cardinal)));
end;

function EvaluateArithmetic(OperatorKind: TRAOperator; L, R: TRAMemoryValue; LeftAvailable: Boolean = True; RightAvailable: Boolean = True): TRAMemoryValue;
var
  Left, Right: Cardinal;
  FL, FR: Double;
begin
  Result := Default(TRAMemoryValue);
  if (OperatorKind = TRAOperator.Multiply) and not (LeftAvailable and RightAvailable) then
    Exit;
  if not LeftAvailable then
    case OperatorKind of
      TRAOperator.Add:
        Exit(R);
      TRAOperator.Subtract:
        begin
          Result := R;
          if R.IsFloat then
            Result.Float := -R.Float
          else
            Result.Unsigned := Cardinal((-Int64(R.Unsigned)) and High(Cardinal));
          Exit;
        end;
    end;

  if (L.IsFloat or R.IsFloat) and not (OperatorKind in [TRAOperator.BitAnd, TRAOperator.BitXor]) then
  begin
    Result.IsFloat := True;
    if OperatorKind = TRAOperator.Modulo then
    begin
      Result.Float := FloatRemainder(FloatValue(L), FloatValue(R));
      Exit;
    end;
    FL := FloatValue(L);
    if OperatorKind = TRAOperator.Subtract then
      FR := NegatedFloatValue(R)
    else
      FR := FloatValue(R);
    case OperatorKind of
      TRAOperator.Add, TRAOperator.Subtract:
        Result.Float := FL + FR;
      TRAOperator.Multiply:
        Result.Float := FL * FR;
      TRAOperator.Divide:
        if FR <> 0 then
          Result.Float := FL / FR;
    end;
    Exit;
  end;

  Left := IntegerValue(L);
  Right := IntegerValue(R);
  case OperatorKind of
    TRAOperator.Multiply:
      Result.Unsigned := Cardinal((UInt64(Left) * Right) and $FFFFFFFF);
    TRAOperator.Add:
      Result.Unsigned := Cardinal((UInt64(Left) + Right) and $FFFFFFFF);
    TRAOperator.Subtract:
      Result.Unsigned := Cardinal((Int64(Left) - Right) and $FFFFFFFF);
    TRAOperator.BitAnd:
      Result.Unsigned := Left and Right;
    TRAOperator.BitXor:
      Result.Unsigned := Left xor Right;
    TRAOperator.Divide, TRAOperator.Modulo:
      if Right <> 0 then
        if OperatorKind = TRAOperator.Divide then
          Result.Unsigned := Left div Right
        else
          Result.Unsigned := Left mod Right;
  end;
end;

function ResolveMemoryAddress(const Base: TRAMemoryValue; Offset: Cardinal): Cardinal;
var
  Displacement: TRAMemoryValue;
begin
  if not Base.IsFloat then
    Exit(Cardinal((UInt64(Base.Unsigned) + Offset) and High(Cardinal)));

  // rcheevos adds the unsigned offset as a Single before converting the sum to an address.
  Displacement.IsFloat := False;
  Displacement.Unsigned := Offset;
  Result := IntegerValue(EvaluateArithmetic(TRAOperator.Add, Base, Displacement));
end;

procedure ConvertValue(var Value: TRAMemoryValue; ToFloat: Boolean);
begin
  if Value.IsFloat = ToFloat then
    Exit;
  if ToFloat then
    Value.Float := FloatValue(Value)
  else
    Value.Unsigned := IntegerValue(Value);
  Value.IsFloat := ToFloat;
end;

function TRATrigger.TExpression.ReadValue(Recall, Current: Boolean): TRAMemoryValue;
begin
  Result := Value;
  if not HasValue then
    Exit;

  if (Kind = TExpressionKind.Operand) and Recall and
    (Operand.Definition.Kind in [TRAOperandKind.BCD, TRAOperandKind.Inverted]) then
    Exit(Operand.ReadSample(Current));

  if Current and (History <> TRAValueHistory.Current) then
    if Kind = TExpressionKind.Operand then
      Result := Operand.ReadSample(True)
    else
      Result := ReadCalculated(True, False);
end;

function TRATrigger.TExpression.ReadCalculated(Current, ReadPrior: Boolean): TRAMemoryValue;
var
  Access: TRAValueHistory;
begin
  Access := History;
  if ReadPrior then
    Access := TRAValueHistory.Prior
  else if Current then
    Access := TRAValueHistory.Current;
  Result.Unsigned := Operand.Sample^.Read(Access);
  Result.IsFloat := StorageSize >= TRAMemorySize.Float32;
end;

function TRATrigger.TExpression.RequestedSize: TRAMemorySize;
begin
  Result := TRAMemorySize.UInt32;
  case Kind of
    TExpressionKind.Operand:
      if Operand.Definition.IsMemoryReference then
        Result := Operand.Definition.Memory.Size
      else if Operand.Definition.Kind = TRAOperandKind.FloatConstant then
        Result := TRAMemorySize.Float32;
    TExpressionKind.Arithmetic:
      if Mode = TArithmeticMode.Normal then
        Result := StorageSize;
  end;
end;

function TRATrigger.TExpression.IsFloatOperand(Recall: Boolean): Boolean;
begin
  if (Kind = TExpressionKind.Arithmetic) and not Recall then
    Result := StorageSize >= TRAMemorySize.Float32
  else
    Result := RequestedSize >= TRAMemorySize.Float32;
end;

function TRATrigger.TExpression.IsDirectIntegerRead: Boolean;
begin
  Result := (Kind = TExpressionKind.Operand) and (Base = 0) and
    (Operand.Definition.Kind = TRAOperandKind.Memory) and
    (Operand.Definition.Memory.History <> TRAValueHistory.Prior) and
    (Operand.Definition.Memory.Size in [TRAMemorySize.UInt8..TRAMemorySize.UInt32BE]);
end;

class function TRATrigger.TCondition.SelectComparisonMode(const LeftExpression, RightExpression: TExpression): TComparisonMode;
var
  LeftReference, RightReference: TRAMemoryReference;
begin
  Result := TComparisonMode.TypedValue;
  if not LeftExpression.IsDirectIntegerRead then
    Exit;
  if (RightExpression.Kind = TExpressionKind.Operand) and
    (RightExpression.Operand.Definition.Kind = TRAOperandKind.UnsignedConstant) then
    Exit(TComparisonMode.StoredSample);
  if not RightExpression.IsDirectIntegerRead then
    Exit;

  LeftReference := LeftExpression.Operand.Definition.Memory;
  RightReference := RightExpression.Operand.Definition.Memory;
  if (LeftReference.History = TRAValueHistory.Current) and (RightReference.History = TRAValueHistory.Current) then
    Exit(TComparisonMode.StoredSample);
  if (LeftReference.History <> RightReference.History) and (LeftReference.Address = RightReference.Address) and
    (RAProgressMemorySize(LeftReference) = RAProgressMemorySize(RightReference)) then
    Result := TComparisonMode.SharedSampleDelta;
end;

function TRATrigger.TCondition.MatchesComparison(Comparison: Integer): Boolean;
begin
  case OperatorKind of
    TRAOperator.Equal:
      Result := Comparison = 0;
    TRAOperator.NotEqual:
      Result := Comparison <> 0;
    TRAOperator.Less:
      Result := Comparison < 0;
    TRAOperator.LessOrEqual:
      Result := Comparison <= 0;
    TRAOperator.Greater:
      Result := Comparison > 0;
    TRAOperator.GreaterOrEqual:
      Result := Comparison >= 0;
  else
    Result := False;
  end;
end;

procedure TRATrigger.TCondition.CompileLegacyComparison(const LeftExpression, RightExpression: TExpression);
var
  LeftDefinition, RightDefinition: TRAOperand;
begin
  if (LeftExpression.Kind = TExpressionKind.Operand) and (RightExpression.Kind = TExpressionKind.Operand) then
  begin
    LeftDefinition := LeftExpression.Operand.Definition;
    RightDefinition := RightExpression.Operand.Definition;
    if (LeftDefinition.Kind = TRAOperandKind.UnsignedConstant) and
      (RightDefinition.Kind = TRAOperandKind.UnsignedConstant) then
    begin
      if not MatchesComparison(CompareDirectValues(LeftDefinition.Value, RightDefinition.Value)) then
        ComparisonMode := TComparisonMode.AlwaysFalse;
    end
    else if (ComparisonMode = TComparisonMode.StoredSample) and LeftExpression.IsDirectIntegerRead and
      RightExpression.IsDirectIntegerRead and (LeftDefinition.Memory.History = TRAValueHistory.Current) and
      (RightDefinition.Memory.History = TRAValueHistory.Current) and
      (LeftDefinition.Memory.Address = RightDefinition.Memory.Address) and
      (LeftDefinition.Memory.Size = RightDefinition.Memory.Size) and
      (Cardinal(Ord(LeftDefinition.Memory.Size)) = RAProgressMemorySize(LeftDefinition.Memory)) and not MatchesComparison(0) then
      ComparisonMode := TComparisonMode.AlwaysFalse;
  end;
  // The C parser keeps the comparator selected before removing the comparison operator.
  OperatorKind := TRAOperator.None;
end;

function TRATrigger.TCondition.Test(const LeftExpression, RightExpression: TExpression): Boolean;
var
  Comparison: Integer;
  LeftValue, RightValue: TRAMemoryValue;
begin
  if OperatorKind = TRAOperator.None then
    case ComparisonMode of
      TComparisonMode.AlwaysFalse:
        Exit(False);
      TComparisonMode.SharedSampleDelta:
        Exit(LeftExpression.Operand.Sample^.Changed);
    else
      Exit(True);
    end;

  LeftValue := LeftExpression.ReadValue(LeftRecall);
  RightValue := RightExpression.ReadValue(RightRecall);
  // rcheevos treats an unchanged shared sample as equal even across operand formats.
  if (ComparisonMode = TComparisonMode.SharedSampleDelta) and not LeftExpression.Operand.Sample^.Changed then
    Comparison := 0
  else
  begin
    if ComparisonMode = TComparisonMode.TypedValue then
    begin
      // Its typed comparator succeeds for a missing left operand unless promoted to float.
      if not LeftExpression.HasValue and not RightValue.IsFloat then
        Exit(True);
    end
    else
    begin
      if not LeftExpression.HasValue then
        LeftValue := LeftExpression.Operand.ReadSample;
      if not RightExpression.HasValue then
        RightValue := RightExpression.Operand.ReadSample;
    end;
    Comparison := CompareDirectValues(LeftValue, RightValue);
  end;
  Result := MatchesComparison(Comparison);
end;

function TRATrigger.TCondition.Evaluate(Matched: Boolean; var AndNext, OrNext: Boolean; ResetNext: Boolean; var HasHits, ResetCondition: Boolean): Boolean;
begin
  TruthFlags := Ord(Matched);
  if ResetNext then
  begin
    ResetCondition := ResetCondition or (Hits <> 0);
    Hits := 0;
    Result := False;
  end
  else
  begin
    Result := (Matched and AndNext) or OrNext;
    HasHits := HasHits or Result or (Hits <> 0);
    if Result and ((RequiredHits = 0) or (Hits < RequiredHits)) then
      Hits := Cardinal((UInt64(Hits) + 1) and High(Cardinal));
    if RequiredHits <> 0 then
      Result := Hits = RequiredHits;
  end;
  AndNext := True;
  OrNext := False;
end;

function TRATrigger.TExpression.ApplyArithmetic(L, R: TRAMemoryValue; LeftAvailable, RightAvailable, Restoring: Boolean): TRAMemoryValue;
var
  Operation: TRAOperator;
begin
  case Mode of
    TArithmeticMode.NegativeSource, TArithmeticMode.AccumulateNegativeSource:
      if LeftAvailable then
        Result := EvaluateArithmetic(TRAOperator.Subtract, R, L)
      else
        Result := R;
    TArithmeticMode.Accumulate, TArithmeticMode.RememberSource:
      begin
        // An unavailable accumulator has no numeric type to convert the modifier to.
        if not LeftAvailable then
          Result := Default(TRAMemoryValue)
        else if Restoring then
          Result := L
        else
        begin
          Operation := OperatorKind;
          if Operation <> TRAOperator.Subtract then
            ConvertValue(R, L.IsFloat)
          else if R.IsFloat and not L.IsFloat then
          begin
            R.Float := -R.Float;
            ConvertValue(R, False);
            Operation := TRAOperator.Add;
          end;
          Result := EvaluateArithmetic(Operation, L, R);
        end;
      end;
  else
    Result := EvaluateArithmetic(OperatorKind, L, R, LeftAvailable, RightAvailable);
  end;

  ConvertValue(Result, StorageSize >= TRAMemorySize.Float32);
end;

function TRATrigger.TGroup.Update(const ReadMemory: TRAMemoryRead; RefreshSamples, AllowUnavailable: Boolean): Boolean;
var
  Expression: ^TExpression;
  ReadOK: Boolean;
begin
  for var Index in EvaluationOrder do
  begin
    Expression := @Expressions[Index];
    case Expression.Kind of
      TExpressionKind.Operand:
        begin
          ReadOK := not RefreshSamples or Expression.Operand.Update(ReadMemory,
            Expressions[Expression.Base].ReadValue(Expression.BaseRecall), Expression.Base <> 0);
          if not ReadOK and not AllowUnavailable then
            Exit(False);
          Expression.Value := Expression.Operand.Read(Expression.HasValue);
          if not ReadOK and not Expression.Value.IsFloat then
          begin
            Expression.HasValue := False;
            Expression.Value := Default(TRAMemoryValue);
          end;
        end;
      TExpressionKind.Alias:
        begin
          Expression.Value := Expressions[Expression.Left].ReadValue(True);
          Expression.HasValue := Expressions[Expression.Left].HasValue;
        end;
      TExpressionKind.Arithmetic:
        begin
          if Expression.Operand.Memref <> nil then
            Expression.Value := Expression.ReadCalculated(False, False)
          else if Expression.History = TRAValueHistory.Current then
            Expression.Value := Expression.ApplyArithmetic(Expressions[Expression.Left].ReadValue(Expression.LeftRecall),
              Expressions[Expression.Right].ReadValue(Expression.RightRecall), Expressions[Expression.Left].HasValue,
              Expressions[Expression.Right].HasValue)
          else
          begin
            if RefreshSamples then
            begin
              Expression.Value := Expression.ApplyArithmetic(
                Expressions[Expression.Left].ReadValue(Expression.LeftRecall, True),
                Expressions[Expression.Right].ReadValue(Expression.RightRecall, True),
                Expressions[Expression.Left].HasValue, Expressions[Expression.Right].HasValue);
              Expression.Operand.LocalSample.Update(Expression.Value.Unsigned);
            end;
            Expression.Value.Unsigned := Expression.Operand.Sample^.Read(Expression.History);
          end;
          Expression.HasValue := True;
        end;
    end;
  end;
  Result := True;
end;

procedure TRATrigger.TGroup.ResetHits;
begin
  for var Index := 0 to High(Conditions) do
    Conditions[Index].Hits := 0;
end;

function TRATrigger.TGroup.ContainsMeasurementFromHits(Value: Cardinal): Boolean;
begin
  for var Index := FirstInPhase[TEvaluationPhase.Measured] to PastPhase[TEvaluationPhase.Measured] - 1 do
    if (Conditions[Index].Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]) and
      (Conditions[Index].RequiredHits <> 0) and (Conditions[Index].Hits = Value) then
      Exit(True);
  Result := False;
end;

function TRATrigger.TGroup.Evaluate(var ResetRequested, HasHits, ResetCondition: Boolean): TGroupFrame;
var
  AndNext, OrNext, ResetNext, CanMeasure, Matched: Boolean;
  AddedHits: Int64;
  Total: Cardinal;
  Condition: ^TCondition;
begin
  Result := Default(TGroupFrame);
  Result.Satisfied := True;
  Result.Primed := True;
  Paused := False;
  AndNext := True;
  OrNext := False;
  ResetNext := False;
  CanMeasure := True;
  AddedHits := 0;
  for var Phase := Low(TEvaluationPhase) to High(TEvaluationPhase) do
  begin
    if ResetRequested then
      case Phase of
        TEvaluationPhase.Targets, TEvaluationPhase.Other:
          Continue;
        TEvaluationPhase.Measured:
          for var Index := FirstInPhase[Phase] to PastPhase[Phase] - 1 do
            Conditions[Index].Hits := 0;
      end;

    for var Index := FirstInPhase[Phase] to PastPhase[Phase] - 1 do
    begin
      Condition := @Conditions[Index];
      Matched := Condition.Evaluate(Condition.Test(Expressions[Condition.Left], Expressions[Condition.Right]),
        AndNext, OrNext, ResetNext, HasHits, ResetCondition);
      case Condition.Kind of
        TRAConditionKind.AndNext:
          begin
            AndNext := Matched;
            Continue;
          end;
        TRAConditionKind.OrNext:
          begin
            OrNext := Matched;
            Continue;
          end;
        TRAConditionKind.ResetNextIf:
          begin
            ResetNext := Matched;
            Continue;
          end;
        TRAConditionKind.AddHits:
          Inc(AddedHits, Condition.Hits);
        TRAConditionKind.SubHits:
          Dec(AddedHits, Condition.Hits);
      else
        Total := Condition.Hits;
        if (Condition.RequiredHits <> 0) and (AddedHits <> 0) then
        begin
          Total := Cardinal(Max(0, Integer(Cardinal((Int64(Total) + AddedHits) and $FFFFFFFF))));
          Matched := Total >= Condition.RequiredHits;
          AddedHits := 0;
        end;

        case Condition.Kind of
          TRAConditionKind.PauseIf:
            begin
              if Matched then
              begin
                Paused := True;
                Result.Paused := True;
                Result.Satisfied := False;
                Result.Primed := False;
                Exit;
              end;
              if Condition.RequiredHits = 0 then
                Condition.Hits := 0;
            end;
          TRAConditionKind.ResetIf:
            if Matched then
            begin
              Condition.TruthFlags := Condition.TruthFlags or 2;
              ResetRequested := True;
              Result.Satisfied := False;
              Result.Primed := False;
            end;
        else
          Result.Satisfied := Result.Satisfied and Matched;
          if Condition.Kind <> TRAConditionKind.Trigger then
            Result.Primed := Result.Primed and Matched;
          case Condition.Kind of
            TRAConditionKind.MeasuredIf:
              CanMeasure := CanMeasure and Matched;
            TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent:
              begin
                Result.MeasuredFromHits := Condition.RequiredHits <> 0;
                Result.HasMeasurement := Result.MeasuredFromHits or Expressions[Condition.Left].HasValue;
                if Result.MeasuredFromHits then
                  Result.Measurement.Unsigned := Total
                else
                  Result.Measurement := Expressions[Condition.Left].ReadValue(Condition.LeftRecall);
              end;
          end;
        end;
      end;
      ResetNext := False;
    end;
  end;
  if not CanMeasure or (Result.MeasuredFromHits and ResetRequested) then
    Result.Measurement := Default(TRAMemoryValue);
end;

class function TRATrigger.TGroup.MakeOperandReader(Operand: TOperand; Current, Recall: Boolean): TOperandReader;
begin
  Result :=
    function(ReadPrior: Boolean; out HasValue, Changed: Boolean): TRAMemoryValue
    begin
      Changed := Operand.Sample^.Changed;
      Result := Operand.Read(HasValue, Current, ReadPrior, Recall);
    end;
end;

class function TRATrigger.TGroup.MakeCalculatedReader(Expression: TExpression; Current: Boolean): TOperandReader;
begin
  Result :=
    function(ReadPrior: Boolean; out HasValue, Changed: Boolean): TRAMemoryValue
    begin
      HasValue := True;
      Changed := Expression.Operand.Sample^.Changed;
      Result := Expression.ReadCalculated(Current, ReadPrior);
    end;
end;

class function TRATrigger.TGroup.MakeArithmeticReader(Expression: TExpression; Left, Right: TOperandReader): TRACalculatedValue;
begin
  Result :=
    function(ReadPrior, Restoring: Boolean; out Changed: Boolean): TRAMemoryValue
    var
      L, R: TRAMemoryValue;
      LeftAvailable, RightAvailable, LeftChanged, RightChanged: Boolean;
    begin
      L := Left(ReadPrior and not Expression.LeftRecall, LeftAvailable, LeftChanged);
      R := Right(ReadPrior and not Expression.RightRecall, RightAvailable, RightChanged);
      Changed := (LeftChanged and not Expression.LeftRecall) or (RightChanged and not Expression.RightRecall);
      Result := Expression.ApplyArithmetic(L, R, LeftAvailable, RightAvailable, Restoring);
    end;
end;

class function TRATrigger.TGroup.MakeAddressResolver(Base: TOperandReader; Offset: Cardinal): TRAIndirectAddress;
begin
  Result :=
    function: Cardinal
    var
      HasValue, Changed: Boolean;
    begin
      Result := ResolveMemoryAddress(Base(False, HasValue, Changed), Offset);
    end;
end;

procedure TRATrigger.TGroup.BindModifiedMemrefs(Memrefs: TRARuntimeMemrefs);
type
  TKeyFormat = (Original, Previous, Rounded, Current);
var
  Keys: array[TKeyFormat, Boolean] of TArray<string>;
  BoundKeys: array[TKeyFormat.Rounded..TKeyFormat.Current] of TArray<string>;
  Readers: array[Boolean, Boolean] of TArray<TOperandReader>;
  Expression: ^TExpression;
  Reference: TRAMemoryReference;
  Size: Cardinal;

  function ExpressionKey(Index: Integer; KeyFormat: TKeyFormat; Current: Boolean = False): string; forward;

  function OperandKey(Index: Integer; KeyFormat: TKeyFormat; Current, Recall: Boolean): string;
  begin
    Result := ExpressionKey(Index, KeyFormat, Current);
    if Recall and (KeyFormat >= TKeyFormat.Rounded) then
      Result := 'recall:' + Result;
  end;

  function PreviousArithmeticKey(const Node: TExpression; KeyFormat: TKeyFormat): string;
  var
    CurrentInputs: Boolean;
    Mode: TArithmeticMode;
  begin
    CurrentInputs := (KeyFormat <> TKeyFormat.Original) and (Node.History <> TRAValueHistory.Current);
    Mode := Node.Mode;
    if (KeyFormat = TKeyFormat.Original) and (Mode = TArithmeticMode.RememberSource) then
      Mode := TArithmeticMode.ApplySource;
    Result := THashMD5.GetHashString(Format('arithmetic:%d:%d:%s:%s',
        [Ord(Node.OperatorKind), Ord(Mode), ExpressionKey(Node.Left, KeyFormat, CurrentInputs),
          ExpressionKey(Node.Right, KeyFormat, CurrentInputs)]));
    if (KeyFormat = TKeyFormat.Previous) and (Mode <> TArithmeticMode.Normal) then
    begin
      var Size := TRAMemorySize.UInt32;
      if (Mode in [TArithmeticMode.ApplySource, TArithmeticMode.NegativeSource, TArithmeticMode.RememberSource]) and
        (Expressions[Node.Right].Kind = TExpressionKind.Operand) then
        Size := Expressions[Node.Right].RequestedSize;
      Result := Format('source:%d:%s', [Ord(Size), Result]);
    end;
  end;

  function ExpressionKey(Index: Integer; KeyFormat: TKeyFormat; Current: Boolean): string;
  var
    Node: TExpression;
    Operand: TRAOperand;
    History: TRAValueHistory;
    Literal: Double;
    Bits: UInt64;
  begin
    Result := Keys[KeyFormat, Current][Index];
    if Result <> '' then
      Exit;
    Node := Expressions[Index];
    History := Node.History;
    if Current then
      History := TRAValueHistory.Current;
    case Node.Kind of
      TExpressionKind.Alias:
        Result := ExpressionKey(Node.Left, KeyFormat);
      TExpressionKind.Arithmetic:
        begin
          if KeyFormat >= TKeyFormat.Rounded then
          begin
            Result := BoundKeys[KeyFormat][Index];
            if Node.RequestedSize = TRAMemorySize.Float32 then
              Result := 'float:' + Result;
          end
          else
            Result := PreviousArithmeticKey(Node, KeyFormat);
          if (History <> TRAValueHistory.Current) and (KeyFormat <> TKeyFormat.Original) then
            Result := Format('%d:%s', [Ord(History), Result]);
        end;
      TExpressionKind.Operand:
        begin
          Operand := Node.Operand.Definition;
          if Operand.IsMemoryReference then
          begin
            Result := Format('memory:%d:%d:%d:%u:%s',
              [Ord(Operand.Kind), Ord(Operand.Memory.Size), Ord(History), Operand.Memory.Address,
                OperandKey(Node.Base, KeyFormat, False, Node.BaseRecall)]);
            var OriginalSize := RAProgressMemorySize(Operand.Memory);
            Operand.Memory.History := History;
            if OriginalSize <> RAProgressMemorySize(Operand.Memory) then
              Result := Format('%s:%d', [Result, OriginalSize]);
          end
          else
          begin
            Result := Format('constant:%d:%u', [Ord(Operand.Kind), Operand.Value.Unsigned]);
            if (KeyFormat = TKeyFormat.Current) and (Operand.Kind = TRAOperandKind.FloatConstant) then
            begin
              Literal := Operand.FloatLiteral;
              if Literal <> Double(Operand.Value.Float) then
              begin
                Move(Literal, Bits, SizeOf(Bits));
                Result := Result + ':' + IntToHex(Bits, 16);
              end;
            end;
          end;
          Result := THashMD5.GetHashString(Result);
        end;
    end;
    Keys[KeyFormat, Current][Index] := Result;
  end;

  function ReadExpression(Index: Integer; Current, Recall: Boolean): TOperandReader;
  var
    Node: TExpression;
  begin
    Result := Readers[Current, Recall][Index];
    if Assigned(Result) then
      Exit;
    Node := Expressions[Index];
    case Node.Kind of
      TExpressionKind.Alias:
        Result := ReadExpression(Node.Left, False, True);
      TExpressionKind.Operand:
        Result := MakeOperandReader(Node.Operand, Current, Recall);
      TExpressionKind.Arithmetic:
        Result := MakeCalculatedReader(Node, Current);
    end;
    Readers[Current, Recall][Index] := Result;
  end;

  function IndirectKey(const Node: TExpression; KeyFormat: TKeyFormat; Width: Cardinal): string;
  begin
    Result := Format('%s:%u:%u', [OperandKey(Node.Base, KeyFormat, False, Node.BaseRecall),
        Node.Operand.Definition.Memory.Address, Width]);
    if KeyFormat >= TKeyFormat.Rounded then
      Result := 'indirect:' + Result;
  end;

  procedure BindCalculation(Index: Integer; var Node: TExpression);
  var
    Calculate: TRACalculatedValue;
    CurrentInputs: Boolean;
    KeyMode: TArithmeticMode;
  begin
    CurrentInputs := Node.History <> TRAValueHistory.Current;
    Calculate := MakeArithmeticReader(Node, ReadExpression(Node.Left, CurrentInputs, Node.LeftRecall),
      ReadExpression(Node.Right, CurrentInputs, Node.RightRecall));
    // An arithmetic sample is identified by the operator, storage width and operand views.
    KeyMode := Node.Mode;
    case KeyMode of
      TArithmeticMode.ApplySource:
        KeyMode := TArithmeticMode.Normal;
      TArithmeticMode.RememberSource:
        KeyMode := TArithmeticMode.Accumulate;
      TArithmeticMode.AccumulateNegativeSource:
        KeyMode := TArithmeticMode.NegativeSource;
    end;
    for var KeyFormat := TKeyFormat.Rounded to TKeyFormat.Current do
      BoundKeys[KeyFormat][Index] := 'calculated:' + THashMD5.GetHashString(Format('%d:%d:%d:%s:%s',
            [Ord(Node.StorageSize), Ord(Node.OperatorKind), Ord(KeyMode),
              OperandKey(Node.Left, KeyFormat, CurrentInputs, Node.LeftRecall),
              OperandKey(Node.Right, KeyFormat, CurrentInputs, Node.RightRecall)]));
    var Key := BoundKeys[TKeyFormat.Current][Index];
    var RoundedKey := BoundKeys[TKeyFormat.Rounded][Index];
    if Node.Mode = TArithmeticMode.Normal then
      Node.Operand.Memref := Memrefs.GetOrAddCalculated(Key, [RoundedKey], Node.StorageSize, Calculate)
    else
      Node.Operand.Memref := Memrefs.GetOrAddCalculated(Key,
        [RoundedKey, PreviousArithmeticKey(Node, TKeyFormat.Previous)], Node.StorageSize, Calculate);
  end;

begin
  for var Index in EvaluationOrder do
  begin
    Expression := @Expressions[Index];
    var Indirect := IsIndirect(Index);
    if not Indirect and (Expression.Kind <> TExpressionKind.Arithmetic) then
      Continue;
    if BoundKeys[TKeyFormat.Current] = nil then
    begin
      for var KeyFormat := TKeyFormat.Rounded to TKeyFormat.Current do
        SetLength(BoundKeys[KeyFormat], Length(Expressions));
      for var Current := Low(Boolean) to High(Boolean) do
      begin
        for var Recall := Low(Boolean) to High(Boolean) do
          SetLength(Readers[Current, Recall], Length(Expressions));
        for var KeyFormat := Low(TKeyFormat) to High(TKeyFormat) do
          SetLength(Keys[KeyFormat, Current], Length(Expressions));
      end;
    end;
    if Indirect then
    begin
      Reference := Expression.Operand.Definition.Memory;
      Size := RAProgressMemorySize(Reference);
      Expression.Operand.Memref := Memrefs.GetOrAddIndirect(IndirectKey(Expression^, TKeyFormat.Current, Size),
        [IndirectKey(Expression^, TKeyFormat.Rounded, Size), IndirectKey(Expression^, TKeyFormat.Previous, Size),
          IndirectKey(Expression^, TKeyFormat.Original, Size)],
        Size, MakeAddressResolver(ReadExpression(Expression.Base, False, Expression.BaseRecall), Reference.Address));
    end
    else
      BindCalculation(Index, Expression^);
  end;
end;

constructor TRATrigger.Create(const Definition: TRATriggerDefinition; ValueMode: Boolean);

  procedure CopyGroup(var Evaluated: TGroup; const Source: TRAConditionGroup);
  var
    Phases: TArray<TEvaluationPhase>;
    Compiled: TArray<TCondition>;
    Expressions: TList<TExpression>;
    UnboundRecalls, UpdateOrder: TList<Integer>;
    Scheduled: TArray<Boolean>;
    Phase: TEvaluationPhase;
    HasMeasured, NegativeSource, HasRemember, SourceIsRecall, AddressIsRecall: Boolean;
    Count, Remember, PauseRemember, Address, SourceValue, Left, Right, PreviousCount: Integer;

    function CompileOperand(const Operand: TRAOperand): Integer;
    var
      Expression: TExpression;
      Reference: Integer;
    begin
      Expression := Default(TExpression);
      if Operand.Kind = TRAOperandKind.Recall then
      begin
        Reference := Remember;
        if (Phase = TEvaluationPhase.Pause) and (PauseRemember = 0) and (Reference <> 0) then
        begin
          Expression := Expressions[Reference];
          if (Expression.Kind <> TExpressionKind.Operand) or Expression.Operand.Definition.IsMemoryReference then
            Reference := 0;
        end;
        if Reference <> 0 then
          Exit(Reference);
        Expression := Default(TExpression);
        Expression.Kind := TExpressionKind.Alias;
        Result := Expressions.Add(Expression);
        if not HasRemember and (Phase <> TEvaluationPhase.Pause) then
          UnboundRecalls.Add(Result);
        Exit;
      end;

      Expression.Kind := TExpressionKind.Operand;
      Expression.Operand.Definition := Operand;
      if Operand.IsMemoryReference then
      begin
        Expression.Base := Address;
        Expression.BaseRecall := AddressIsRecall;
        Expression.History := Operand.Memory.History;
      end;
      Result := Expressions.Add(Expression);
    end;

    function CompileMath(A, B: Integer; OperatorKind: TRAOperator; Mode: TArithmeticMode; MatchHistory, AIsRecall, BIsRecall: Boolean): Integer;
    var
      Expression: TExpression;
    begin
      if OperatorKind = TRAOperator.None then
        Exit(A);
      Expression := Default(TExpression);
      Expression.Kind := TExpressionKind.Arithmetic;
      Expression.Left := A;
      Expression.Right := B;
      Expression.LeftRecall := AIsRecall;
      Expression.RightRecall := BIsRecall;
      Expression.OperatorKind := OperatorKind;
      Expression.Mode := Mode;
      Expression.StorageSize := TRAMemorySize.UInt32;
      case Mode of
        TArithmeticMode.Normal:
          if Expressions[A].IsFloatOperand(AIsRecall) or Expressions[B].IsFloatOperand(BIsRecall) then
            Expression.StorageSize := TRAMemorySize.Float32;
        TArithmeticMode.Accumulate, TArithmeticMode.AccumulateNegativeSource:
          if Expressions[A].IsFloatOperand(AIsRecall) then
            Expression.StorageSize := TRAMemorySize.Float32;
      else
        Expression.StorageSize := Expressions[B].RequestedSize;
      end;
      // Equal history modifiers select the history of the combined value.
      if MatchHistory and (Expressions[A].History = Expressions[B].History) then
        Expression.History := Expressions[A].History;
      Result := Expressions.Add(Expression);
    end;

    function CompileConditionMath(A, B: Integer; const Condition: TRACondition): Integer;
    begin
      Result := CompileMath(A, B, Condition.OperatorKind, TArithmeticMode.Normal, False,
        Condition.Left.Kind = TRAOperandKind.Recall, Condition.Right.Kind = TRAOperandKind.Recall);
    end;

    function ApplySource(Base: Integer; BaseIsRecall: Boolean; Remembering: Boolean = False): Integer;
    var
      MatchHistory: Boolean;
    begin
      if SourceValue = 0 then
        Exit(Base);
      MatchHistory := not (SourceIsRecall or BaseIsRecall);
      if NegativeSource then
        Result := CompileMath(SourceValue, Base, TRAOperator.Subtract, TArithmeticMode.NegativeSource, MatchHistory, SourceIsRecall, BaseIsRecall)
      else if Remembering then
        Result := CompileMath(SourceValue, Base, TRAOperator.Add, TArithmeticMode.RememberSource, MatchHistory, SourceIsRecall, BaseIsRecall)
      else
        Result := CompileMath(SourceValue, Base, TRAOperator.Add, TArithmeticMode.ApplySource, MatchHistory, SourceIsRecall, BaseIsRecall);
    end;

  begin
    SetLength(Phases, Length(Source));
    HasMeasured := False;
    Phase := TEvaluationPhase.Other;
    for var Index := High(Source) downto 0 do
    begin
      var Condition := Source[Index];
      if Condition.Kind = TRAConditionKind.Remember then
        Evaluated.HasRememberCondition := True;
      case Condition.Kind of
        TRAConditionKind.AddAddress, TRAConditionKind.AddSource, TRAConditionKind.SubSource, TRAConditionKind.Remember:
          begin
            if not (Condition.OperatorKind in [TRAOperator.None, TRAOperator.Multiply..TRAOperator.Subtract]) then
              raise ERAConditionError.CreateWithCode('Expected an arithmetic condition', RAErrorInvalidOperator);
            Phases[Index] := Phase;
            Continue;
          end;
      end;
      if ValueMode and (Condition.Kind in [TRAConditionKind.Standard, TRAConditionKind.Trigger]) then
        raise ERAConditionError.CreateWithCode('Invalid flag in a value expression', RAErrorInvalidValueFlag);
      if not (ValueMode and (Condition.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent])) and
        not (Condition.OperatorKind in [TRAOperator.Equal..TRAOperator.GreaterOrEqual]) then
        raise ERAConditionError.CreateWithCode('Expected a comparison condition', RAErrorInvalidOperator);
      case Condition.Kind of
        TRAConditionKind.AddHits, TRAConditionKind.SubHits, TRAConditionKind.AndNext, TRAConditionKind.OrNext, TRAConditionKind.ResetNextIf:
          ; // Follow the consuming condition.
          TRAConditionKind.PauseIf:
          Phase := TEvaluationPhase.Pause;
        TRAConditionKind.ResetIf:
          Phase := TEvaluationPhase.Reset;
        TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent:
          begin
            if ValueMode and HasMeasured then
              raise ERAConditionError.CreateWithCode('Multiple measured conditions in one group', RAErrorMultipleMeasured);
            HasMeasured := True;
            Phase := TEvaluationPhase.Measured;
          end;
        TRAConditionKind.MeasuredIf:
          Phase := TEvaluationPhase.Measured;
        TRAConditionKind.Standard, TRAConditionKind.Trigger:
          if Condition.RequiredHits <> 0 then
            Phase := TEvaluationPhase.Targets
          else
            Phase := TEvaluationPhase.Other;
      end;
      Phases[Index] := Phase;
    end;

    if ValueMode and not HasMeasured then
      raise ERAConditionError.CreateWithCode('Missing Measured in a value expression', RAErrorMissingValueMeasured);
    SetLength(Compiled, Length(Source));
    Expressions := TList<TExpression>.Create;
    UnboundRecalls := TList<Integer>.Create;
    UpdateOrder := TList<Integer>.Create;
    try
      // Expression zero supplies the value of an unbound recall and the base of direct reads.
      SetLength(Evaluated.ProgressConditions, Length(Source));
      Expressions.Add(Default(TExpression));
      Remember := 0;
      PauseRemember := 0;
      HasRemember := False;
      Address := 0;
      AddressIsRecall := False;
      SourceValue := 0;
      NegativeSource := False;
      for var Index := 0 to High(Source) do
      begin
        var Condition := Source[Index];
        Phase := Phases[Index];
        Evaluated.ProgressConditions[Index].EvaluatedIndex := -1;
        if (Condition.Kind = TRAConditionKind.Remember) and (Condition.Left.Kind = TRAOperandKind.Recall) and
          (Condition.OperatorKind = TRAOperator.None) and (SourceValue = 0) and (Address = 0) then
          Continue;
        Left := CompileOperand(Condition.Left);
        Right := 0;
        if Condition.OperatorKind <> TRAOperator.None then
        begin
          var BeforeRight := Expressions.Count;
          Right := CompileOperand(Condition.Right);
          if Condition.LegacyValueComparison and (Right >= BeforeRight) then
          begin
            var OperandExpression := Expressions[Right];
            OperandExpression.LegacyComparisonOperand := True;
            Expressions[Right] := OperandExpression;
            Inc(Evaluated.LegacyComparisonOperands);
          end;
        end;
        if Condition.Left.Kind <> TRAOperandKind.Recall then
          Evaluated.ProgressConditions[Index].Left := Left;
        if Condition.Right.Kind <> TRAOperandKind.Recall then
          Evaluated.ProgressConditions[Index].Right := Right;
        var LeftIsRecall := (Condition.Left.Kind = TRAOperandKind.Recall) and
          not (Condition.OperatorKind in [TRAOperator.Multiply..TRAOperator.Subtract]);
        case Condition.Kind of
          TRAConditionKind.AddAddress:
            begin
              Address := CompileConditionMath(Left, Right, Condition);
              AddressIsRecall := LeftIsRecall;
              Continue;
            end;
          TRAConditionKind.AddSource, TRAConditionKind.SubSource:
            begin
              Left := CompileConditionMath(Left, Right, Condition);
              if SourceValue = 0 then
              begin
                SourceValue := Left;
                SourceIsRecall := LeftIsRecall;
                NegativeSource := Condition.Kind = TRAConditionKind.SubSource;
              end
              else
              begin
                var MatchHistory := not (SourceIsRecall or LeftIsRecall);
                if NegativeSource and (Condition.Kind = TRAConditionKind.AddSource) then
                  SourceValue := CompileMath(SourceValue, Left, TRAOperator.Subtract,
                    TArithmeticMode.AccumulateNegativeSource, MatchHistory, SourceIsRecall, LeftIsRecall)
                else
                begin
                  // The C parser materializes a constant accumulator before subtracting.
                  if not NegativeSource and (Condition.Kind = TRAConditionKind.SubSource) and
                    (Expressions[SourceValue].Kind = TExpressionKind.Operand) and
                    not Expressions[SourceValue].Operand.Definition.IsMemoryReference then
                  begin
                    SourceValue := CompileMath(SourceValue, 0, TRAOperator.Add, TArithmeticMode.Accumulate,
                      MatchHistory, SourceIsRecall, False);
                    SourceIsRecall := False;
                  end;
                  if NegativeSource then
                  begin
                    SourceValue := CompileMath(0, SourceValue, TRAOperator.Subtract, TArithmeticMode.Normal,
                      False, False, SourceIsRecall);
                    SourceIsRecall := False;
                  end;
                  if Condition.Kind = TRAConditionKind.SubSource then
                    SourceValue := CompileMath(SourceValue, Left, TRAOperator.Subtract, TArithmeticMode.Accumulate, MatchHistory, SourceIsRecall, LeftIsRecall)
                  else
                    SourceValue := CompileMath(SourceValue, Left, TRAOperator.Add, TArithmeticMode.Accumulate, MatchHistory, SourceIsRecall, LeftIsRecall);
                end;
                SourceIsRecall := False;
                NegativeSource := False;
              end;
              Address := 0;
              AddressIsRecall := False;
              Continue;
            end;
          TRAConditionKind.Remember:
            begin
              Remember := ApplySource(CompileConditionMath(Left, Right, Condition),
                LeftIsRecall, True);
              Evaluated.ProgressConditions[Index].Left := Remember;
              HasRemember := True;
              if Phase = TEvaluationPhase.Pause then
                PauseRemember := Remember;
            end;
        else
          if ValueMode and not Condition.LegacyValueComparison and
            (Condition.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]) then
          begin
            if Condition.OperatorKind in [TRAOperator.Equal..TRAOperator.GreaterOrEqual] then
              Condition.RequiredHits := High(Cardinal)
            else
            begin
              Left := CompileConditionMath(Left, Right, Condition);
              Condition.OperatorKind := TRAOperator.None;
            end;
          end;
          Compiled[Index].Kind := Condition.Kind;
          Compiled[Index].OperatorKind := Condition.OperatorKind;
          Compiled[Index].RequiredHits := Condition.RequiredHits;
          Compiled[Index].Left := ApplySource(Left, LeftIsRecall);
          Compiled[Index].Right := Right;
          Compiled[Index].LeftRecall := LeftIsRecall and (SourceValue = 0);
          Compiled[Index].RightRecall := Condition.Right.Kind = TRAOperandKind.Recall;
          if (Condition.OperatorKind in [TRAOperator.Equal..TRAOperator.GreaterOrEqual]) and
            (Condition.Left.Kind <> TRAOperandKind.Recall) and (Condition.Right.Kind <> TRAOperandKind.Recall) then
            Compiled[Index].ComparisonMode := TCondition.SelectComparisonMode(
                Expressions[Compiled[Index].Left], Expressions[Right]);
          if Condition.LegacyValueComparison then
            Compiled[Index].CompileLegacyComparison(Expressions[Compiled[Index].Left], Expressions[Right]);
          if Condition.Left.Kind <> TRAOperandKind.Recall then
            Evaluated.ProgressConditions[Index].Left := Compiled[Index].Left;
        end;
        SourceValue := 0;
        Address := 0;
        AddressIsRecall := False;
      end;

      // A pause chain executes first. Earlier unbound main-group recalls can see its last Remember.
      for var Index in UnboundRecalls do
      begin
        var Expression := Expressions[Index];
        Expression.Left := PauseRemember;
        Expressions[Index] := Expression;
      end;

      Evaluated.Expressions := Expressions.ToArray;
      Evaluated.Expressions[0].HasValue := True;
      SetLength(Scheduled, Expressions.Count);
      Scheduled[0] := True;
      while UpdateOrder.Count < Expressions.Count - 1 do
      begin
        PreviousCount := UpdateOrder.Count;
        for var Index := 1 to High(Evaluated.Expressions) do
        begin
          var Expression := Evaluated.Expressions[Index];
          if not Scheduled[Index] and Scheduled[Expression.Base] and
            Scheduled[Expression.Left] and Scheduled[Expression.Right] then
          begin
            Scheduled[Index] := True;
            UpdateOrder.Add(Index);
          end;
        end;
        if UpdateOrder.Count = PreviousCount then
          raise ERAConditionError.CreateWithCode('Cyclic Remember expression', RAErrorInvalidMemoryOperand);
      end;
      Evaluated.EvaluationOrder := UpdateOrder.ToArray;
    finally
      UpdateOrder.Free;
      UnboundRecalls.Free;
      Expressions.Free;
    end;

    SetLength(Evaluated.Conditions, Length(Source));
    Count := 0;
    for Phase := Low(TEvaluationPhase) to High(TEvaluationPhase) do
    begin
      Evaluated.FirstInPhase[Phase] := Count;
      for var Index := 0 to High(Source) do
        if (Phases[Index] = Phase) and not (Source[Index].Kind in [TRAConditionKind.AddAddress,
            TRAConditionKind.AddSource, TRAConditionKind.SubSource, TRAConditionKind.Remember]) then
        begin
          Evaluated.Conditions[Count] := Compiled[Index];
          Evaluated.ProgressConditions[Index].EvaluatedIndex := Count;
          Inc(Count);
        end;
      Evaluated.PastPhase[Phase] := Count;
    end;
    SetLength(Evaluated.Conditions, Count);
  end;

begin
  inherited Create;
  if not ValueMode then
    ReadRATriggerMeasurement(Definition, FMeasured.Target, FMeasured.AsPercent);
  SetLength(FGroups, Length(Definition.Alternatives) + 1);
  CopyGroup(FGroups[0], Definition.Core);
  if (Length(Definition.Core) = 0) and (Length(Definition.Alternatives) > 0) then
    FFirstRCGroup := 1;
  for var Index := 0 to High(Definition.Alternatives) do
    CopyGroup(FGroups[Index + 1], Definition.Alternatives[Index]);
  Reset;
end;

procedure TRATrigger.ResetHits;
begin
  for var Index := 0 to High(FGroups) do
    FGroups[Index].ResetHits;
  FHasHits := False;
end;

procedure TRATrigger.Reset;
begin
  ResetHits;
  FState := TRATriggerState.Waiting;
  FMeasured.Known := False;
  FMeasured.Value := 0;
end;

procedure TRATrigger.ClearProgress;
begin
  Reset;
  for var GroupIndex := 0 to High(FGroups) do
  begin
    FGroups[GroupIndex].Paused := False;
    for var ConditionIndex := 0 to High(FGroups[GroupIndex].Conditions) do
      FGroups[GroupIndex].Conditions[ConditionIndex].TruthFlags := 0;
    for var Index := 0 to High(FGroups[GroupIndex].Expressions) do
    begin
      FGroups[GroupIndex].Expressions[Index].Operand.LocalSample := Default(TRAMemorySample);
      FGroups[GroupIndex].Expressions[Index].Value := Default(TRAMemoryValue);
    end;
  end;
end;

procedure TRATrigger.Disable;
begin
  FState := TRATriggerState.Disabled;
end;

function TRATrigger.ReferencesMemref(Memref: TRARuntimeMemref): Boolean;
begin
  if Memref = nil then
    Exit(False);

  // The C runtime tests the operands retained by each condition. The inputs
  // of a computed operand still get sampled, but are not direct dependencies.
  for var Group in FGroups do
    for var Condition in Group.ProgressConditions do
      if (Group.Expressions[Condition.Left].Operand.Memref = Memref) or
        (Group.Expressions[Condition.Right].Operand.Memref = Memref) then
        Exit(True);
  Result := False;
end;

procedure TRATrigger.WriteProgress(const IO: TRAProgressIO);
begin
  IO.WriteUInt(Ord(FState));
  IO.WriteFlag(FHasHits);
  IO.WriteFlag(FMeasured.Known);
  IO.WriteUInt(FMeasured.Value);
  IO.WriteUInt(Length(FGroups));
  for var Group in FGroups do
  begin
    IO.WriteFlag(Group.Paused);
    IO.WriteUInt(Length(Group.Conditions));
    for var Condition in Group.Conditions do
      IO.WriteUInt(Condition.Hits);
    IO.WriteUInt(Length(Group.Expressions));
    for var Expression in Group.Expressions do
      Expression.Operand.Sample^.WriteProgress(IO);
  end;
end;

procedure TRATrigger.ReadProgress(const IO: TRAProgressIO);
var
  State, ExpressionCount: Cardinal;
  Group: ^TGroup;
  MissingLegacyOperands: Boolean;
begin
  State := IO.ReadUInt;
  if State > Cardinal(Ord(High(TRATriggerState))) then
    raise ERAProgressError.Create('Invalid RetroAchievements trigger state');
  FState := TRATriggerState(State);
  FHasHits := IO.ReadFlag;
  FMeasured.Known := IO.ReadFlag;
  FMeasured.Value := IO.ReadUInt;
  IO.ExpectUInt(Length(FGroups));
  for var GroupIndex := 0 to High(FGroups) do
  begin
    Group := @FGroups[GroupIndex];
    Group.Paused := IO.ReadFlag;
    IO.ExpectUInt(Length(Group.Conditions));
    for var Index := 0 to High(Group.Conditions) do
      Group.Conditions[Index].Hits := IO.ReadUInt;
    ExpressionCount := IO.ReadUInt;
    MissingLegacyOperands := (Group.LegacyComparisonOperands <> 0) and
      (ExpressionCount = Cardinal(Length(Group.Expressions) - Group.LegacyComparisonOperands));
    if (ExpressionCount <> Cardinal(Length(Group.Expressions))) and not MissingLegacyOperands then
      raise ERAProgressError.Create('Incompatible RetroAchievements progress');
    if MissingLegacyOperands then
    begin
      // Older versions captured the unused hit tally without enforcing the legacy target.
      for var Index := 0 to High(Group.Conditions) do
        if Group.Conditions[Index].RequiredHits <> 0 then
          Group.Conditions[Index].Hits := 0;
    end;
    for var Index := 0 to High(Group.Expressions) do
      if not MissingLegacyOperands or not Group.Expressions[Index].LegacyComparisonOperand then
        Group.Expressions[Index].Operand.Sample^.ReadProgress(IO);
  end;
end;

const
  RCConditionTruthMask = $00000003;
  RCConditionLeftIndirect = $00010000;
  RCConditionLeftChanged = $00020000;
  RCConditionRightIndirect = $00100000;
  RCConditionRightChanged = $00200000;

function TRATrigger.TGroup.IsIndirect(Expr: Integer): Boolean;
begin
  Result := (Expr > 0) and (Expressions[Expr].Kind = TExpressionKind.Operand) and
    (Expressions[Expr].Base <> 0) and Expressions[Expr].Operand.Definition.IsMemoryReference;
end;

procedure TRATrigger.TGroup.WriteRCProgress(const IO: TRAProgressIO);
var
  Hits, Flags: Cardinal;
  LeftIndirect, RightIndirect: Boolean;

  procedure WriteSample(Expr: Integer);
  begin
    IO.WriteUInt(Expressions[Expr].Operand.Sample^.Current);
    IO.WriteUInt(Expressions[Expr].Operand.Sample^.Prior);
  end;

begin
  IO.WriteUInt(Ord(Paused));
  for var Condition in ProgressConditions do
  begin
    Hits := 0;
    Flags := 0;
    if Condition.EvaluatedIndex >= 0 then
    begin
      Hits := Conditions[Condition.EvaluatedIndex].Hits;
      Flags := Conditions[Condition.EvaluatedIndex].TruthFlags;
    end;
    LeftIndirect := IsIndirect(Condition.Left);
    if LeftIndirect then
    begin
      Flags := Flags or RCConditionLeftIndirect;
      if Expressions[Condition.Left].Operand.Sample^.Changed then
        Flags := Flags or RCConditionLeftChanged;
    end;
    RightIndirect := IsIndirect(Condition.Right);
    if RightIndirect then
    begin
      Flags := Flags or RCConditionRightIndirect;
      if Expressions[Condition.Right].Operand.Sample^.Changed then
        Flags := Flags or RCConditionRightChanged;
    end;
    IO.WriteUInt(Hits);
    IO.WriteUInt(Flags);
    if LeftIndirect then
      WriteSample(Condition.Left);
    if RightIndirect then
      WriteSample(Condition.Right);
  end;
end;

procedure TRATrigger.TGroup.ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
var
  Hits, Flags: Cardinal;

  procedure ReadSample(Expr: Integer; Changed: Boolean);
  var
    Current, Prior: Cardinal;
  begin
    if not IsIndirect(Expr) then
      raise ERAProgressError.Create('Unexpected rcheevos indirect operand');
    Current := IO.ReadUInt;
    Prior := IO.ReadUInt;
    if Apply then
      Expressions[Expr].Operand.Sample^.Restore(Current, Prior, Changed);
  end;

begin
  Flags := IO.ReadUInt;
  if Apply then
    Paused := Flags <> 0;
  for var Condition in ProgressConditions do
  begin
    Hits := IO.ReadUInt;
    Flags := IO.ReadUInt;
    if Apply and (Condition.EvaluatedIndex >= 0) then
    begin
      Conditions[Condition.EvaluatedIndex].Hits := Hits;
      Conditions[Condition.EvaluatedIndex].TruthFlags := Flags and RCConditionTruthMask;
    end;
    if (Flags and RCConditionLeftIndirect) <> 0 then
      ReadSample(Condition.Left, (Flags and RCConditionLeftChanged) <> 0);
    if (Flags and RCConditionRightIndirect) <> 0 then
      ReadSample(Condition.Right, (Flags and RCConditionRightChanged) <> 0);
  end;
end;

procedure TRATrigger.MeasureDefinitionLayout(var Layout: TRADefinitionLayout);
begin
  for var Index := FFirstRCGroup to High(FGroups) do
    Layout.AddGroup(Length(FGroups[Index].ProgressConditions));
end;

procedure TRATrigger.CollectRCMemrefs(Memrefs: TRARuntimeMemrefs; Bind: Boolean);
var
  Expression: ^TExpression;
  Reference: TRAMemoryReference;
  Size: Cardinal;
begin
  for var GroupIndex := 0 to High(FGroups) do
  begin
    for var Index := 0 to High(FGroups[GroupIndex].Expressions) do
    begin
      Expression := @FGroups[GroupIndex].Expressions[Index];
      if (Expression.Kind <> TExpressionKind.Operand) or (Expression.Base <> 0) or
        not Expression.Operand.Definition.IsMemoryReference then
        Continue;
      Reference := Expression.Operand.Definition.Memory;
      Size := RAProgressMemorySize(Reference);
      if Bind then
        Expression.Operand.Memref := Memrefs.GetOrAdd(Reference.Address, Size)
      else
        Memrefs.Add(Reference.Address, Size, Expression.Operand.Sample^);
    end;
    if Bind then
      FGroups[GroupIndex].BindModifiedMemrefs(Memrefs);
  end;
end;

procedure TRATrigger.RestoreRCMemrefs(Memrefs: TRARuntimeMemrefs);
var
  Expression: ^TExpression;
  Reference: TRAMemoryReference;
  Sample: TRAMemorySample;
begin
  for var GroupIndex := 0 to High(FGroups) do
    for var Index := 0 to High(FGroups[GroupIndex].Expressions) do
    begin
      Expression := @FGroups[GroupIndex].Expressions[Index];
      if (Expression.Kind <> TExpressionKind.Operand) or (Expression.Base <> 0) or
        not Expression.Operand.Definition.IsMemoryReference then
        Continue;
      Reference := Expression.Operand.Definition.Memory;
      if Memrefs.TryGet(Reference.Address, RAProgressMemorySize(Reference), Sample) then
        Expression.Operand.Sample^ := Sample;
    end;
end;

procedure TRATrigger.WriteRCProgress(const IO: TRAProgressIO);
var
  State: Cardinal;
begin
  case FState of
    TRATriggerState.Waiting:
      State := 1;
    TRATriggerState.Active:
      State := 2;
    TRATriggerState.Paused:
      State := 3;
    TRATriggerState.Triggered:
      State := 5;
    TRATriggerState.Primed:
      State := 6;
  else
    State := 7;
  end;
  IO.WriteUInt(State);
  if FMeasured.Known then
    IO.WriteUInt(FMeasured.Value)
  else if FMeasured.Target <> 0 then
    IO.WriteUInt(High(Cardinal))
  else
    IO.WriteUInt(0);
  for var Index := FFirstRCGroup to High(FGroups) do
    FGroups[Index].WriteRCProgress(IO);
end;

procedure TRATrigger.ReadRCProgress(const IO: TRAProgressIO; Apply: Boolean);
var
  State: TRATriggerState;
  Value: Cardinal;
begin
  case IO.ReadUInt of
    0, 7:
      State := TRATriggerState.Disabled;
    1:
      State := TRATriggerState.Waiting;
    2, 4:
      State := TRATriggerState.Active;
    3:
      State := TRATriggerState.Paused;
    5:
      State := TRATriggerState.Triggered;
    6:
      State := TRATriggerState.Primed;
  else
    raise ERAProgressError.Create('Invalid rcheevos trigger state');
  end;
  Value := IO.ReadUInt;
  for var Index := FFirstRCGroup to High(FGroups) do
    FGroups[Index].ReadRCProgress(IO, Apply);
  if Apply then
  begin
    FState := State;
    // The portable snapshot leaves the previous evaluation flag unchanged.
    FMeasured.Known := (Value <> High(Cardinal)) and (FMeasured.Target <> 0);
    if FMeasured.Known then
      FMeasured.Value := Value
    else
      FMeasured.Value := 0;
  end;
end;

function TRATrigger.HasRCValueConditionProgress: Boolean;
begin
  for var Condition in FGroups[FFirstRCGroup].Conditions do
    if (Condition.Kind = TRAConditionKind.PauseIf) or (Condition.RequiredHits <> 0) then
      Exit(True);
  Result := False;
end;

procedure TRATrigger.WriteRCValueConditions(const IO: TRAProgressIO);
begin
  FGroups[FFirstRCGroup].WriteRCProgress(IO);
end;

procedure TRATrigger.ReadRCValueConditions(const IO: TRAProgressIO; Present, Apply: Boolean);
begin
  if Present then
    FGroups[FFirstRCGroup].ReadRCProgress(IO, Apply)
  else if Apply then
    FGroups[FFirstRCGroup].ResetHits;
end;

function TRATrigger.HasRCRequiredHits: Boolean;
begin
  for var Group in FGroups do
    for var Condition in Group.Conditions do
      if Condition.RequiredHits <> 0 then
        Exit(True);
  Result := False;
end;

function TRATrigger.ValueFromMeasuredHits: Boolean;
begin
  for var Group in FGroups do
    for var Condition in Group.Conditions do
      if Condition.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent] then
        Exit(Condition.RequiredHits <> 0);
  Result := False;
end;

function TRATrigger.HasSingleMeasurement: Boolean;
begin
  Result := (Length(FGroups) = 1) and (Length(FGroups[0].Conditions) = 1) and
    (FGroups[0].Conditions[0].Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]) and
    (FGroups[0].Conditions[0].RequiredHits = 0);
end;

procedure TRATrigger.ValidateRCModifiedOperands;
var
  Group: TGroup;

  function IsUnboundRecall(Index: Integer): Boolean;
  begin
    Result := (Group.Expressions[Index].Kind = TExpressionKind.Alias) and (Group.Expressions[Index].Left = 0);
  end;

begin
  for Group in FGroups do
    for var Index in Group.EvaluationOrder do
    begin
      var Expression := Group.Expressions[Index];
      if ((Expression.Kind = TExpressionKind.Arithmetic) and
        (IsUnboundRecall(Expression.Left) or IsUnboundRecall(Expression.Right))) or
        (Group.IsIndirect(Index) and IsUnboundRecall(Expression.Base)) then
        raise ERAConditionError.CreateWithCode('Unbound Recall in a modified memory operand', RAErrorInvalidMemoryOperand);
    end;
end;

function TRATrigger.IsRCSimpleValue: Boolean;
begin
  // Remember is a combining condition even though the evaluator compiles it into the operands.
  Result := HasSingleMeasurement and not FGroups[0].HasRememberCondition;
end;

procedure TRATrigger.RefreshStoredValues;
begin
  for var Index := 0 to High(FGroups) do
    FGroups[Index].Update(nil, False);
end;

function TRATrigger.TryReadSimpleValue(out Value: TRAMemoryValue; IncludeRemember: Boolean): Boolean;
begin
  Result := HasSingleMeasurement and (IncludeRemember or not FGroups[0].HasRememberCondition);
  if Result then
  begin
    RefreshStoredValues;
    var Condition := FGroups[0].Conditions[0];
    Value := FGroups[0].Expressions[Condition.Left].ReadValue(Condition.LeftRecall);
  end
  else
    Value := Default(TRAMemoryValue);
end;

function TRATrigger.ReadPreparedValueType: Boolean;
begin
  RefreshStoredValues;
  for var Condition in FGroups[FFirstRCGroup].Conditions do
    if Condition.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent] then
      Exit(FGroups[FFirstRCGroup].Expressions[Condition.Left].Value.IsFloat);
  Result := False;
end;

function TRATrigger.TestStoredFrame: Boolean;
var
  Original: TArray<TGroup>;
  State: TRATriggerState;
  Measured: TRAMeasuredProgress;
  HasHits: Boolean;
begin
  RefreshStoredValues;
  Original := FGroups;
  State := FState;
  Measured := FMeasured;
  HasHits := FHasHits;
  FGroups := Copy(Original);
  try
    for var Index := 0 to High(FGroups) do
      FGroups[Index].Conditions := Copy(Original[Index].Conditions);
    Result := TestPreparedFrame;
  finally
    FGroups := Original;
    FState := State;
    FMeasured := Measured;
    FHasHits := HasHits;
  end;
end;

function TRATrigger.UpdateMemory(const ReadMemory: TRAMemoryRead; AllowUnavailable: Boolean): Boolean;
begin
  for var Index := 0 to High(FGroups) do
    if not FGroups[Index].Update(ReadMemory, True, AllowUnavailable) then
      Exit(False);
  Result := True;
end;

function TRATrigger.TestFrame(const ReadMemory: TRAMemoryRead): Boolean;
begin
  if not UpdateMemory(ReadMemory) then
  begin
    Disable;
    Exit(False);
  end;
  FState := TRATriggerState.Active;
  Result := TestPreparedFrame;
end;

function TRATrigger.TestPreparedFrame: Boolean;
begin
  if FState = TRATriggerState.Disabled then
    Exit(False);
  FState := TRATriggerState.Active;
  Result := EvaluatePreparedFrame = TRATriggerFrame.Triggered;
end;

function TRATrigger.TryEvaluatePreparedValue(out Value: TRAMemoryValue): Boolean;
var
  Group: TGroupFrame;
  ResetRequested, HasHits, ResetCondition: Boolean;
begin
  Value := Default(TRAMemoryValue);
  Result := False;
  for var Index := 0 to High(FGroups) do
  begin
    ResetRequested := False;
    HasHits := False;
    ResetCondition := False;
    Group := FGroups[Index].Evaluate(ResetRequested, HasHits, ResetCondition);
    if ResetRequested then
      FGroups[Index].ResetHits;
    if Group.HasMeasurement and not Group.Paused and
      (not Result or (CompareDirectValues(Group.Measurement, Value) > 0)) then
    begin
      Value := Group.Measurement;
      Result := True;
    end;
  end;
end;

function TRATrigger.EvaluateFrame(const ReadMemory: TRAMemoryRead): TRATriggerFrame;
begin
  if FState in [TRATriggerState.Triggered, TRATriggerState.Disabled] then
    Exit(TRATriggerFrame.Inactive);
  if not UpdateMemory(ReadMemory) then
  begin
    FState := TRATriggerState.Disabled;
    Exit(TRATriggerFrame.Disabled);
  end;

  Result := EvaluatePreparedFrame;
end;

function TRATrigger.EvaluatePreparedFrame: TRATriggerFrame;
var
  Satisfied, Primed, Paused, HasHits, ResetRequested, PreviouslyHadHits, ResetCondition: Boolean;
  AltSatisfied, AltPrimed, AllAltsPaused: Boolean;
  Group, Measurement: TGroupFrame;
begin
  ResetRequested := False;
  ResetCondition := False;
  HasHits := False;
  Group := FGroups[0].Evaluate(ResetRequested, HasHits, ResetCondition);
  Measurement := Group;
  Satisfied := Group.Satisfied;
  Primed := Group.Primed;
  Paused := Group.Paused;
  if Length(FGroups) > 1 then
  begin
    AltSatisfied := False;
    AltPrimed := False;
    AllAltsPaused := True;
    for var Index := 1 to High(FGroups) do
    begin
      Group := FGroups[Index].Evaluate(ResetRequested, HasHits, ResetCondition);
      AltSatisfied := AltSatisfied or Group.Satisfied;
      AltPrimed := AltPrimed or Group.Primed;
      AllAltsPaused := AllAltsPaused and Group.Paused;
      if Group.HasMeasurement and
        (not Measurement.HasMeasurement or (CompareDirectValues(Group.Measurement, Measurement.Measurement) > 0)) then
        Measurement := Group;
    end;
    Satisfied := Satisfied and AltSatisfied;
    Primed := Primed and AltPrimed;
    Paused := Paused or AllAltsPaused;
  end;

  if not Paused and Measurement.HasMeasurement then
  begin
    FMeasured.Known := True;
    FMeasured.Value := IntegerValue(Measurement.Measurement);
  end;

  if ResetRequested then
  begin
    if Measurement.MeasuredFromHits then
      FMeasured.Value := 0
    else if Paused and FMeasured.Known and (FMeasured.Value <> 0) then
      for var Index := 0 to High(FGroups) do
        if FGroups[Index].Paused and FGroups[Index].ContainsMeasurementFromHits(FMeasured.Value) then
        begin
          FMeasured.Value := 0;
          Break;
        end;

    PreviouslyHadHits := FHasHits;
    ResetHits;
    if PreviouslyHadHits then
    begin
      if FState = TRATriggerState.Primed then
        FState := TRATriggerState.Active;
      Exit(TRATriggerFrame.Reset);
    end;
    Primed := False;
    HasHits := False;
  end
  else if Satisfied then
  begin
    if FState = TRATriggerState.Waiting then
    begin
      Reset;
      Exit(TRATriggerFrame.Waiting);
    end;
    FState := TRATriggerState.Triggered;
    Exit(TRATriggerFrame.Triggered);
  end;

  FHasHits := HasHits;
  if Paused then
  begin
    FState := TRATriggerState.Paused;
    Result := TRATriggerFrame.Paused;
  end
  else if Primed then
  begin
    FState := TRATriggerState.Primed;
    Result := TRATriggerFrame.Primed;
  end
  else
  begin
    FState := TRATriggerState.Active;
    Result := TRATriggerFrame.Active;
  end;
  if ResetCondition then
    Result := TRATriggerFrame.Reset;
end;

end.

