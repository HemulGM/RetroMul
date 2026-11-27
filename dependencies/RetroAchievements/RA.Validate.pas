unit RA.Validate;

interface

{$SCOPEDENUMS ON}

uses
  RA.Conditions, RA.MemoryValues;

type
  TRAValidationCode = (ParseError, AddressOutOfRange, VirtualRAM, KernelRAM, TrailingChain,
    MissingHitTarget, ResetWithoutHits, ResetTargetOfOne, MissingMeasured, UnboundRecall,
    EarlyRecall, PauseRecall, PreviousFramePointer, FractionalPointer, TransformedPointer,
    DifferentMemorySizes, MaskTooLarge, MaskAlwaysZero, AlwaysTrue, NeverTrue, Conflict,
    Redundant, SameComparisonAcrossFrames);

  TRAValidationIssue = record
    Code: TRAValidationCode;
    GroupIndex: Integer; // 0 = Core, 1 = Alt1
    ConditionIndex: Integer; // 1-based, zero for a parse error
    RelatedGroup, RelatedCondition: Integer;
    ExpressionPosition: Integer; // 1-based for a parse error
    Message: string;
  end;

// Returns the primary rcheevos diagnostic first, followed by other findings.
function ValidateRADefinition(const Definition: TRATriggerDefinition; MaxAddress: Cardinal = High(Cardinal); ConsoleID: Cardinal = 0): TArray<TRAValidationIssue>; overload;

function ValidateRADefinition(const Expression: string; MaxAddress: Cardinal = High(Cardinal); ConsoleID: Cardinal = 0): TArray<TRAValidationIssue>; overload;

// Copies the primary diagnostic as zero-terminated UTF-8. The buffer is optional.
function ValidateRATrigger(const Definition: TRATriggerDefinition; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress: Cardinal = High(Cardinal); ConsoleID: Cardinal = 0): Boolean; overload;

function ValidateRATrigger(const Expression: string; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress: Cardinal = High(Cardinal); ConsoleID: Cardinal = 0): Boolean; overload;
// Validates the conditions in a group without checking trigger-level overlaps.

function ValidateRAConditionGroup(const Group: TRAConditionGroup; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress: Cardinal = High(Cardinal); ConsoleID: Cardinal = 0): Boolean;

// Checks the direct references in registration order without changing runtime state.
function ValidateRAMemoryReferencesForConsole(const References: TRARuntimeMemrefs; ConsoleID: Cardinal; out Issue: TRAValidationIssue): Boolean;

implementation

uses
  System.Generics.Collections, System.Math, System.SysUtils, System.TypInfo,
  RA.Console, RA.Format, RA.Streams, RA.Trigger;

type
  TRAOperandRange = record
    Minimum, Maximum: Cardinal;
  end;

  TRAComparison = record
    GroupIndex, ConditionIndex: Integer;
    Kind: TRAConditionKind;
    Operand: TRAOperand;
    OperatorKind: TRAOperator;
    Constant: Cardinal;
    OperandOnLeft: Boolean;
    EffectiveHistory: TRAValueHistory;
    Chain: TRAConditionGroup;
  end;

  TRAOverlap = (None, Conflict, Redundant);

  TRAConstantOrder = (Less, Equal, Greater);

function IsFloat(const Operand: TRAOperand): Boolean;
begin
  Result := (Operand.Kind = TRAOperandKind.FloatConstant) or
    (Operand.IsMemoryReference and (Operand.Memory.Size >= TRAMemorySize.Float32));
end;

function IsCombining(Kind: TRAConditionKind): Boolean;
begin
  Result := Kind in [TRAConditionKind.AddSource, TRAConditionKind.SubSource,
      TRAConditionKind.AddHits, TRAConditionKind.SubHits, TRAConditionKind.AndNext,
      TRAConditionKind.OrNext, TRAConditionKind.AddAddress, TRAConditionKind.Remember,
      TRAConditionKind.ResetNextIf];
end;

function SameOperand(const A, B: TRAOperand): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  if A.IsMemoryReference then
    Exit((A.Memory.Address = B.Memory.Address) and (A.Memory.Size = B.Memory.Size) and
      (A.Memory.History = B.Memory.History));
  if A.Kind = TRAOperandKind.FloatConstant then
    Exit(A.FloatLiteral = B.FloatLiteral);
  Result := A.Value.Unsigned = B.Value.Unsigned;
end;

function SameChain(const A, B: TRAConditionGroup): Boolean;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for var Index := 0 to High(A) do
  begin
    if not (A[Index].Kind in [TRAConditionKind.AddAddress, TRAConditionKind.AddSource,
        TRAConditionKind.SubSource, TRAConditionKind.AndNext]) or (A[Index].Kind <> B[Index].Kind) or
      (A[Index].OperatorKind <> B[Index].OperatorKind) or (A[Index].RequiredHits <> B[Index].RequiredHits) or
      not SameOperand(A[Index].Left, B[Index].Left) or
      ((A[Index].OperatorKind <> TRAOperator.None) and not SameOperand(A[Index].Right, B[Index].Right)) then
      Exit(False);
  end;
  Result := True;
end;

function OperandLimit(const Operand: TRAOperand): Cardinal;
begin
  if Operand.Kind = TRAOperandKind.UnsignedConstant then
    Exit(Operand.Value.Unsigned);
  if not Operand.IsMemoryReference then
    Exit(High(Cardinal));
  case Operand.Memory.Size of
    TRAMemorySize.Bit0..TRAMemorySize.Bit7:
      Exit(1);
    TRAMemorySize.LowNibble, TRAMemorySize.HighNibble:
      Exit(15);
    TRAMemorySize.BitCount:
      Exit(8);
    TRAMemorySize.UInt8:
      if Operand.Kind = TRAOperandKind.BCD then
        Exit(165)
      else
        Exit($FF);
    TRAMemorySize.UInt16, TRAMemorySize.UInt16BE:
      if Operand.Kind = TRAOperandKind.BCD then
        Exit(16665)
      else
        Exit($FFFF);
    TRAMemorySize.UInt24, TRAMemorySize.UInt24BE:
      if Operand.Kind = TRAOperandKind.BCD then
        Exit(1666665)
      else
        Exit($FFFFFF);
  end;
  if Operand.Kind = TRAOperandKind.BCD then
    Exit(166666665);
  Result := High(Cardinal);
end;

function OperandRange(const Operand: TRAOperand): TRAOperandRange;
begin
  Result.Maximum := OperandLimit(Operand);
  if Operand.Kind = TRAOperandKind.UnsignedConstant then
    Result.Minimum := Result.Maximum
  else
    Result.Minimum := 0;
end;

function CombineRanges(Left, Right: TRAOperandRange; OperatorKind: TRAOperator): TRAOperandRange;
begin
  Result := Left;
  case OperatorKind of
    TRAOperator.Multiply:
      begin
        Result.Minimum := Cardinal(Min(UInt64(Left.Minimum) * Right.Minimum, UInt64(High(Cardinal))));
        Result.Maximum := Cardinal(Min(UInt64(Left.Maximum) * Right.Maximum, UInt64(High(Cardinal))));
      end;
    TRAOperator.Divide:
      begin
        if Right.Maximum <> 0 then
          Result.Minimum := Left.Minimum div Right.Maximum;
        if Right.Minimum <> 0 then
          Result.Maximum := Left.Maximum div Right.Minimum;
      end;
    TRAOperator.BitAnd:
      begin
        Result.Minimum := 0;
        Result.Maximum := Left.Maximum and Right.Maximum;
      end;
    TRAOperator.BitXor:
      begin
        Result.Minimum := 0;
        Result.Maximum := Left.Maximum or Right.Maximum;
      end;
    TRAOperator.Modulo:
      begin
        Result.Minimum := 0;
        if Left.Maximum >= Right.Maximum then
          Result.Maximum := Cardinal((Int64(Right.Maximum) - 1) and $FFFFFFFF);
      end;
    TRAOperator.Add:
      begin
        Result.Minimum := Cardinal((UInt64(Left.Minimum) + Right.Minimum) and $FFFFFFFF);
        // An already wrapped range also wraps its upper bound when adding.
        if Left.Minimum > Left.Maximum then
          Result.Maximum := Cardinal((UInt64(Left.Maximum) + Right.Maximum) and $FFFFFFFF)
        else
          Result.Maximum := Cardinal(Min(UInt64(Left.Maximum) + Right.Maximum, UInt64(High(Cardinal))));
      end;
    TRAOperator.Subtract:
      begin
        Result.Minimum := Cardinal((Int64(Left.Minimum) - Right.Maximum) and $FFFFFFFF);
        Result.Maximum := Cardinal((Int64(Left.Maximum) - Right.Minimum) and $FFFFFFFF);
      end;
  end;
end;

function Swapped(OperatorKind: TRAOperator): TRAOperator;
begin
  case OperatorKind of
    TRAOperator.Less:
      Result := TRAOperator.Greater;
    TRAOperator.LessOrEqual:
      Result := TRAOperator.GreaterOrEqual;
    TRAOperator.Greater:
      Result := TRAOperator.Less;
    TRAOperator.GreaterOrEqual:
      Result := TRAOperator.LessOrEqual;
  else
    Result := OperatorKind;
  end;
end;

function Inverted(OperatorKind: TRAOperator): TRAOperator;
begin
  case OperatorKind of
    TRAOperator.Equal:
      Result := TRAOperator.NotEqual;
    TRAOperator.NotEqual:
      Result := TRAOperator.Equal;
    TRAOperator.Less:
      Result := TRAOperator.GreaterOrEqual;
    TRAOperator.LessOrEqual:
      Result := TRAOperator.Greater;
    TRAOperator.Greater:
      Result := TRAOperator.LessOrEqual;
    TRAOperator.GreaterOrEqual:
      Result := TRAOperator.Less;
  else
    Result := OperatorKind;
  end;
end;

function ComparisonOverlap(const Source, Compared: TRAComparison): TRAOverlap;
const
  None = TRAOverlap.None;
  Conflict = TRAOverlap.Conflict;
  Redundant = TRAOverlap.Redundant;
  // Each block lists source operators in the order =, !=, <, <=, >, >=.
  // Each row lists outcomes when the source constant is less, equal or greater.
  Overlaps: array[TRAOperator.Equal..TRAOperator.GreaterOrEqual, TRAOperator.Equal..TRAOperator.GreaterOrEqual, TRAConstantOrder] of TRAOverlap = (
    ( // Compared operator: EQ
    (Conflict, Redundant, Conflict),
    (None, Conflict, None),
    (Conflict, Conflict, None),
    (Conflict, None, None),
    (None, Conflict, Conflict),
    (None, None, Conflict)),
    ( // Compared operator: NE
    (Redundant, Conflict, Redundant),
    (None, Redundant, None),
    (Redundant, Redundant, None),
    (Redundant, None, None),
    (None, Redundant, Redundant),
    (None, None, Redundant)),
    ( // Compared operator: LT
    (Redundant, Conflict, Conflict),
    (None, None, None),
    (Redundant, Redundant, None),
    (Redundant, None, None),
    (None, Conflict, Conflict),
    (None, Conflict, Conflict)),
    ( // Compared operator: LE
    (Redundant, Redundant, Conflict),
    (None, None, None),
    (Redundant, Redundant, None),
    (Redundant, Redundant, None),
    (None, Conflict, Conflict),
    (None, None, Conflict)),
    ( // Compared operator: GT
    (Conflict, Conflict, Redundant),
    (None, None, None),
    (Conflict, Conflict, None),
    (Conflict, Conflict, None),
    (None, Redundant, Redundant),
    (None, None, Redundant)),
    ( // Compared operator: GE
    (Conflict, Redundant, Redundant),
    (None, None, None),
    (Conflict, Conflict, None),
    (Conflict, None, None),
    (None, Redundant, Redundant),
    (Redundant, Redundant, None))
  );
var
  Order: TRAConstantOrder;
begin
  if Source.Constant < Compared.Constant then
    Order := TRAConstantOrder.Less
  else if Source.Constant = Compared.Constant then
    Order := TRAConstantOrder.Equal
  else
    Order := TRAConstantOrder.Greater;
  Result := Overlaps[Compared.OperatorKind, Source.OperatorKind, Order];
end;

function TryGetAddressIssue(Address, MaxAddress, ConsoleID: Cardinal; out Code: TRAValidationCode; out MessageText: string): Boolean;
begin
  if Address > MaxAddress then
  begin
    Code := TRAValidationCode.AddressOutOfRange;
    MessageText := 'Address ' + IntToHex(Address, 4) + ' out of range (max ' + IntToHex(MaxAddress, 4) + ')';
  end
  else if (ConsoleID in [RAConsoleNintendo, RAConsoleFamicomDiskSystem]) and (Address >= $800) and (Address <= $1FFF) then
  begin
    Code := TRAValidationCode.VirtualRAM;
    MessageText := 'Mirror RAM may not be exposed by emulator (address ' + IntToHex(Address, 4) + ')';
  end
  else if (ConsoleID in [RAConsoleGameBoy, RAConsoleGameBoyColor]) and (Address >= $E000) and (Address <= $FDFF) then
  begin
    Code := TRAValidationCode.VirtualRAM;
    MessageText := 'Echo RAM may not be exposed by emulator (address ' + IntToHex(Address, 4) + ')';
  end
  else if (ConsoleID = RAConsolePlayStation) and (Address <= $FFFF) then
  begin
    Code := TRAValidationCode.KernelRAM;
    MessageText := 'Kernel RAM may not be initialized without real BIOS (address ' + IntToHex(Address, 4) + ')';
  end
  else
    Exit(False);
  Result := True;
end;

function ValidateRAMemoryReferencesForConsole(const References: TRARuntimeMemrefs; ConsoleID: Cardinal; out Issue: TRAValidationIssue): Boolean;
var
  MaxAddress: Cardinal;
  Code: TRAValidationCode;
  MessageText: string;
begin
  Issue := Default(TRAValidationIssue);
  MaxAddress := RAConsoleMaxAddress(ConsoleID);
  Result := References.CheckDirectAddresses(
    function(Address: Cardinal): Boolean
    begin
      Result := not TryGetAddressIssue(Address, MaxAddress, ConsoleID, Code, MessageText);
    end);
  if not Result then
  begin
    Issue.Code := Code;
    Issue.RelatedGroup := -1;
    Issue.Message := MessageText;
  end;
end;

function ValidateDefinition(const Definition: TRATriggerDefinition; MaxAddress, ConsoleID: Cardinal; CheckOverlaps: Boolean): TArray<TRAValidationIssue>;
const
  NeverTrueIntegerToFloatPriority = 5;
  NeverTrueWithoutMaxPriority = 6;
  AlwaysTrueIntegerToFloatPriority = 8;
var
  Issues: TList<TRAValidationIssue>;
  Comparisons: TList<TRAComparison>;
  HasTargets, ConsiderForPrimary: Boolean;
  GroupHasIssues: TArray<Boolean>;
  ComparisonStarts: TArray<Integer>;
  PrimaryIndex, PrimaryPriority, PreviousCount: Integer;
  PrimaryIssue: TRAValidationIssue;

  function Location(GroupIndex, ConditionIndex: Integer): string;
  begin
    Result := 'Condition ' + IntToStr(ConditionIndex);
    if Length(Definition.Alternatives) <> 0 then
      if GroupIndex = 0 then
        Result := 'Core ' + Result
      else
        Result := 'Alt' + IntToStr(GroupIndex) + ' ' + Result;
  end;

  procedure AddIssue(Code: TRAValidationCode; GroupIndex, Index: Integer; const Text: string; RelatedGroup: Integer = -1; RelatedIndex: Integer = 0; PriorityOverride: Integer = 0);
  const
    // rcheevos lists the most severe diagnostic first, then uses source order.
    Priorities: array[TRAValidationCode] of Integer = (
      0, 1, 20, 19, 10, 12, 22, 23, 11, 2, 3, 3, 13, 14, 15, 16, 24, 17, 9, 4, 7, 21, 18);
  var
    Issue, Previous: TRAValidationIssue;
    Priority: Integer;
  begin
    Issue.Code := Code;
    Issue.GroupIndex := GroupIndex;
    Issue.ConditionIndex := Index;
    Issue.RelatedGroup := RelatedGroup;
    Issue.RelatedCondition := RelatedIndex;
    Issue.ExpressionPosition := 0;
    Issue.Message := Location(GroupIndex, Index) + ': ' + Text;
    Priority := PriorityOverride;
    if Priority = 0 then
      Priority := Priorities[Code];
    if PrimaryIndex >= 0 then
      Previous := Issues[PrimaryIndex]
    else
      Previous := Default(TRAValidationIssue);
    if ConsiderForPrimary and ((Priority < PrimaryPriority) or
      ((Priority = PrimaryPriority) and ((GroupIndex < Previous.GroupIndex) or
      ((GroupIndex = Previous.GroupIndex) and (Index < Previous.ConditionIndex))))) then
    begin
      PrimaryPriority := Priority;
      PrimaryIndex := Issues.Count;
    end;
    Issues.Add(Issue);
  end;

  procedure CheckAddress(const Operand: TRAOperand; GroupIndex, Index: Integer);
  var
    Code: TRAValidationCode;
    MessageText: string;
  begin
    if Operand.IsMemoryReference and TryGetAddressIssue(Operand.Memory.Address, MaxAddress, ConsoleID, Code, MessageText) then
      AddIssue(Code, GroupIndex, Index, MessageText);
  end;

  procedure CheckComparison(const Condition: TRACondition; GroupIndex, Index: Integer; const Group: TRAConditionGroup; ChainStart: Integer; Indirect, HasSource, FirstSourceSubtracts: Boolean; const SourceRange: TRAOperandRange; SourceHistory: TRAValueHistory);
  var
    Left, Right: TRAOperand;
    OperatorKind: TRAOperator;
    Maximum, RightMinimum, RightMaximum: Cardinal;
    LeftRange: TRAOperandRange;
    FloatNumber: Double;
    RoundedInteger: Single;
    NeverTrue, AlwaysTrue: Boolean;

    procedure AddComparison;
    var
      Comparison: TRAComparison;
    begin
      if not CheckOverlaps or not Left.IsMemoryReference or IsCombining(Condition.Kind) or
        (Condition.RequiredHits <> 0) or (Right.Kind <> TRAOperandKind.UnsignedConstant) then
        Exit;
      Comparison := Default(TRAComparison);
      Comparison.GroupIndex := GroupIndex;
      Comparison.ConditionIndex := Index;
      Comparison.Kind := Condition.Kind;
      if Comparison.Kind = TRAConditionKind.MeasuredPercent then
        Comparison.Kind := TRAConditionKind.Measured;
      Comparison.Operand := Left;
      Comparison.OperandOnLeft := Condition.Left.IsMemoryReference;
      Comparison.EffectiveHistory := Left.Memory.History;
      if HasSource and (Comparison.EffectiveHistory <> SourceHistory) then
        Comparison.EffectiveHistory := TRAValueHistory.Current;
      Comparison.OperatorKind := Condition.OperatorKind;
      if not Comparison.OperandOnLeft then
        Comparison.OperatorKind := Inverted(Comparison.OperatorKind);
      Comparison.Constant := Right.Value.Unsigned;
      Comparison.Chain := Copy(Group, ChainStart, Index - 1 - ChainStart);
      Comparisons.Add(Comparison);
    end;

  begin
    OperatorKind := Condition.OperatorKind;
    if not (OperatorKind in [TRAOperator.Equal..TRAOperator.GreaterOrEqual]) then
      Exit;
    Left := Condition.Left;
    Right := Condition.Right;
    if not HasSource and not Left.IsMemoryReference and Right.IsMemoryReference then
    begin
      Left := Condition.Right;
      Right := Condition.Left;
      OperatorKind := Swapped(OperatorKind);
    end;
    AddComparison;
    if Left.IsMemoryReference and Right.IsMemoryReference and not Indirect and not HasSource and
      (OperandLimit(Left) <> OperandLimit(Right)) then
      AddIssue(TRAValidationCode.DifferentMemorySizes, GroupIndex, Index, 'Comparing different memory sizes');
    if not (HasSource or Left.IsMemoryReference) or ((HasSource or Condition.Left.IsMemoryReference) and IsFloat(Condition.Left)) then
      Exit;
    LeftRange := OperandRange(Left);
    if HasSource then
      if FirstSourceSubtracts then
        LeftRange := CombineRanges(LeftRange, SourceRange, TRAOperator.Subtract)
      else
        LeftRange := CombineRanges(SourceRange, LeftRange, TRAOperator.Add);
    if LeftRange.Minimum > LeftRange.Maximum then
      Maximum := High(Cardinal)
    else
      Maximum := LeftRange.Maximum;
    RightMinimum := 0;
    RightMaximum := OperandLimit(Right);
    case Right.Kind of
      TRAOperandKind.UnsignedConstant:
        RightMinimum := Right.Value.Unsigned;
      TRAOperandKind.FloatConstant:
        begin
          FloatNumber := Right.FloatLiteral;
          if (FloatNumber <= -2147483649.0) or (FloatNumber >= 2147483648.0) then
            RightMinimum := $80000000
          else
            RightMinimum := Cardinal(Integer(Trunc(FloatNumber)));
          RoundedInteger := RightMinimum;
          if not IsFloat(Left) and (Double(RoundedInteger) <> FloatNumber) then
          begin
            if OperatorKind in [TRAOperator.Equal, TRAOperator.NotEqual] then
            begin
              var Text := StringReplace(FormatRAValue(Right.Value, TRAValueFormat.Float6), ',', '', [rfReplaceAll]);
              while Text[Length(Text)] = '0' do
                SetLength(Text, Length(Text) - 1);
              if OperatorKind = TRAOperator.Equal then
                AddIssue(TRAValidationCode.NeverTrue, GroupIndex, Index,
                  'Comparison is never true (integer can never be ' + Text + ')', -1, 0, NeverTrueIntegerToFloatPriority)
              else
                AddIssue(TRAValidationCode.AlwaysTrue, GroupIndex, Index,
                  'Comparison is always true (integer can never be ' + Text + ')', -1, 0, AlwaysTrueIntegerToFloatPriority);
            end;
            if OperatorKind in [TRAOperator.GreaterOrEqual, TRAOperator.Less] then
              RightMinimum := Cardinal((UInt64(RightMinimum) + 1) and High(Cardinal));
          end;
        end;
    end;

    NeverTrue := False;
    AlwaysTrue := False;
    case OperatorKind of
      TRAOperator.Equal:
        NeverTrue := RightMinimum > Maximum;
      TRAOperator.NotEqual:
        AlwaysTrue := RightMinimum > Maximum;
      TRAOperator.GreaterOrEqual:
        begin
          NeverTrue := RightMinimum > Maximum;
          AlwaysTrue := RightMaximum = 0;
        end;
      TRAOperator.Greater:
        NeverTrue := RightMinimum >= Maximum;
      TRAOperator.LessOrEqual:
        AlwaysTrue := RightMinimum >= Maximum;
      TRAOperator.Less:
        begin
          AlwaysTrue := RightMinimum > Maximum;
          if not AlwaysTrue and (RightMaximum = 0) then
            AddIssue(TRAValidationCode.NeverTrue, GroupIndex, Index, 'Comparison is never true', -1, 0, NeverTrueWithoutMaxPriority);
        end;
    end;
    if NeverTrue then
      AddIssue(TRAValidationCode.NeverTrue, GroupIndex, Index,
        'Comparison is never true (max ' + UIntToStr(Maximum) + ')')
    else if AlwaysTrue then
      AddIssue(TRAValidationCode.AlwaysTrue, GroupIndex, Index,
        'Comparison is always true (max ' + UIntToStr(Maximum) + ')');
  end;

  procedure CheckGroup(const Group: TRAConditionGroup; GroupIndex: Integer);
  var
    Indirect, Chained, HasSource, InAddHits, HasMeasured, HasRemember, HasPauseRemember, RememberSeen, PauseRememberSeen, RememberIsConstant: Boolean;
    MeasuresIf, FirstRememberIndex, ChainStart: Integer;
    SourceRange, PartRange: TRAOperandRange;
    SourceHistory, PartHistory: TRAValueHistory;
    FirstSourceSubtracts: Boolean;
    ConsumedByPause: TArray<Boolean>;
    Pause: Boolean;
  begin
    HasMeasured := False;
    HasRemember := False;
    HasPauseRemember := False;
    FirstRememberIndex := -1;
    Pause := False;
    SetLength(ConsumedByPause, Length(Group));
    for var Index := High(Group) downto 0 do
    begin
      if not IsCombining(Group[Index].Kind) then
        Pause := Group[Index].Kind = TRAConditionKind.PauseIf;
      ConsumedByPause[Index] := Pause;
      HasMeasured := HasMeasured or (Group[Index].Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]);
      if Group[Index].Kind = TRAConditionKind.Remember then
      begin
        HasRemember := True;
        FirstRememberIndex := Index;
        HasPauseRemember := HasPauseRemember or Pause;
      end;
    end;

    Indirect := False;
    Chained := False;
    HasSource := False;
    SourceHistory := TRAValueHistory.Current;
    FirstSourceSubtracts := False;

    InAddHits := False;
    RememberSeen := False;
    PauseRememberSeen := False;
    RememberIsConstant := False;
    SourceRange := Default(TRAOperandRange);
    ChainStart := 0;
    MeasuresIf := -1;
    for var Index := 0 to High(Group) do
    begin
      var Condition := Group[Index];
      if not Indirect then
      begin
        CheckAddress(Condition.Left, GroupIndex, Index + 1);
        CheckAddress(Condition.Right, GroupIndex, Index + 1);
      end;

      if (Condition.Left.Kind = TRAOperandKind.Recall) or
        ((Condition.OperatorKind <> TRAOperator.None) and (Condition.Right.Kind = TRAOperandKind.Recall)) then
      begin
        if not HasRemember then
          AddIssue(TRAValidationCode.UnboundRecall, GroupIndex, Index + 1, 'Recall used without Remember')
        else if ConsumedByPause[Index] and not PauseRememberSeen and not RememberIsConstant then
          AddIssue(TRAValidationCode.PauseRecall, GroupIndex, Index + 1,
            'PauseIf cannot use Remembered value not associated to PauseIf chain')
        else if not RememberSeen and not (HasPauseRemember and (Index < FirstRememberIndex)) then
          AddIssue(TRAValidationCode.EarlyRecall, GroupIndex, Index + 1, 'Recall used before Remember');
      end;

      if Condition.Kind = TRAConditionKind.AddAddress then
      begin
        if Condition.Left.IsMemoryReference and (Condition.Left.Memory.History <> TRAValueHistory.Current) then
          AddIssue(TRAValidationCode.PreviousFramePointer, GroupIndex, Index + 1, 'Using pointer from previous frame')
        else if IsFloat(Condition.Left) or IsFloat(Condition.Right) then
          AddIssue(TRAValidationCode.FractionalPointer, GroupIndex, Index + 1, 'Using non-integer value in AddAddress calculation')
        else if (Condition.Left.Kind in [TRAOperandKind.BCD, TRAOperandKind.Inverted]) and
          (Condition.OperatorKind <> TRAOperator.Multiply) then
          AddIssue(TRAValidationCode.TransformedPointer, GroupIndex, Index + 1, 'Using transformed value in AddAddress calculation');
      end;
      if not IsCombining(Condition.Kind) and (Condition.OperatorKind = TRAOperator.BitAnd) and
        (Condition.Right.Kind = TRAOperandKind.UnsignedConstant) and Condition.Left.IsMemoryReference and
        not IsFloat(Condition.Left) then
      begin
        if Condition.Right.Value.Unsigned > OperandLimit(Condition.Left) then
          AddIssue(TRAValidationCode.MaskTooLarge, GroupIndex, Index + 1, 'Mask has more bits than source')
        else if Condition.Right.Value.Unsigned = 0 then
          AddIssue(TRAValidationCode.MaskAlwaysZero, GroupIndex, Index + 1, 'Result of mask is always 0');
      end;
      if Condition.Kind = TRAConditionKind.ResetIf then
      begin
        if not InAddHits then
          if not HasTargets then
            AddIssue(TRAValidationCode.ResetWithoutHits, GroupIndex, Index + 1, 'No captured hits to reset')
          else if Condition.RequiredHits = 1 then
            AddIssue(TRAValidationCode.ResetTargetOfOne, GroupIndex, Index + 1, 'Hit target of 1 is redundant on ResetIf');
      end
      else if InAddHits and not IsCombining(Condition.Kind) and (Condition.RequiredHits = 0) then
        AddIssue(TRAValidationCode.MissingHitTarget, GroupIndex, Index + 1,
          'Final condition in AddHits chain must have a hit target');

      CheckComparison(Condition, GroupIndex, Index + 1, Group, ChainStart, Indirect, HasSource,
        FirstSourceSubtracts, SourceRange, SourceHistory);

      Indirect := Condition.Kind = TRAConditionKind.AddAddress;
      if Condition.Kind = TRAConditionKind.Remember then
      begin
        RememberSeen := True;
        PauseRememberSeen := PauseRememberSeen or ConsumedByPause[Index];
        RememberIsConstant := not HasSource and (Condition.OperatorKind = TRAOperator.None) and
          (Condition.Left.Kind in [TRAOperandKind.UnsignedConstant, TRAOperandKind.FloatConstant]);
      end;
      if Condition.Kind in [TRAConditionKind.AddSource, TRAConditionKind.SubSource] then
      begin
        // The combined operand retains delta/prior access only when both operands share it.
        PartHistory := TRAValueHistory.Current;
        if (Condition.OperatorKind = TRAOperator.None) and (Condition.Left.Kind = TRAOperandKind.Memory) then
          PartHistory := Condition.Left.Memory.History;
        if not HasSource then
          SourceHistory := PartHistory
        else if (SourceHistory <> PartHistory) or (FirstSourceSubtracts and (Condition.Kind = TRAConditionKind.SubSource)) then
          SourceHistory := TRAValueHistory.Current;
        if (Condition.OperatorKind = TRAOperator.Divide) and Condition.Right.IsMemoryReference and
          not Indirect and SameOperand(Condition.Left, Condition.Right) then
        begin
          PartRange.Minimum := 0;
          PartRange.Maximum := 1;
        end
        else
          PartRange := CombineRanges(OperandRange(Condition.Left), OperandRange(Condition.Right), Condition.OperatorKind);
        if not HasSource then
          SourceRange := PartRange
        else if Condition.Kind = TRAConditionKind.SubSource then
        begin
          // Two leading SubSource terms start at zero.
          if FirstSourceSubtracts then
            SourceRange := CombineRanges(Default(TRAOperandRange), SourceRange, TRAOperator.Subtract);
          SourceRange := CombineRanges(SourceRange, PartRange, TRAOperator.Subtract);
        end
        else if FirstSourceSubtracts then
          SourceRange := CombineRanges(PartRange, SourceRange, TRAOperator.Subtract)
        else
          SourceRange := CombineRanges(SourceRange, PartRange, TRAOperator.Add);
        FirstSourceSubtracts := not HasSource and (Condition.Kind = TRAConditionKind.SubSource);
        HasSource := True;
      end
      else if Condition.Kind <> TRAConditionKind.AddAddress then
      begin
        HasSource := False;
      end;
      if not IsCombining(Condition.Kind) then
        InAddHits := False
      else
        InAddHits := InAddHits or (Condition.Kind in [TRAConditionKind.AddHits, TRAConditionKind.SubHits]);
      if (MeasuresIf < 0) and (Condition.Kind = TRAConditionKind.MeasuredIf) then
        MeasuresIf := Index;
      Chained := IsCombining(Condition.Kind);
      if not Chained then
        ChainStart := Index + 1;
    end;
    if Chained then
      AddIssue(TRAValidationCode.TrailingChain, GroupIndex, Length(Group),
        GetEnumName(TypeInfo(TRAConditionKind), Ord(Group[High(Group)].Kind)) +
        ' condition type expects another condition to follow');
    if (MeasuresIf >= 0) and not HasMeasured then
      AddIssue(TRAValidationCode.MissingMeasured, GroupIndex, MeasuresIf + 1, 'MeasuredIf without Measured');
  end;

  procedure CheckOverlap(Source, Compared: TRAComparison);
  var
    SameGroup, SourcePauses, ComparedPauses, SourceResets, ComparedResets: Boolean;
    Overlap: TRAOverlap;

    procedure Report(Code: TRAValidationCode; const Text: string);
    begin
      AddIssue(Code, Compared.GroupIndex, Compared.ConditionIndex,
        Text + Location(Source.GroupIndex, Source.ConditionIndex), Source.GroupIndex, Source.ConditionIndex);
    end;

  begin
    if not SameChain(Source.Chain, Compared.Chain) then
      Exit;
    if (Source.Operand.Kind <> Compared.Operand.Kind) or
      (Source.Operand.Memory.Address <> Compared.Operand.Memory.Address) or
      (Source.Operand.Memory.Size <> Compared.Operand.Memory.Size) then
      Exit;
    if Source.Operand.Memory.History <> Compared.Operand.Memory.History then
    begin
      if (Source.EffectiveHistory = TRAValueHistory.Current) and
        (Compared.EffectiveHistory <> TRAValueHistory.Current) and
        Source.OperandOnLeft and Compared.OperandOnLeft and (Source.Kind = Compared.Kind) and
        (Source.OperatorKind = Compared.OperatorKind) and (Source.Constant = Compared.Constant) then
        Report(TRAValidationCode.SameComparisonAcrossFrames, 'Same comparison across frames as ');
      Exit;
    end;

    SameGroup := Source.GroupIndex = Compared.GroupIndex;
    SourcePauses := Source.Kind = TRAConditionKind.PauseIf;
    ComparedPauses := Compared.Kind = TRAConditionKind.PauseIf;
    SourceResets := Source.Kind = TRAConditionKind.ResetIf;
    ComparedResets := Compared.Kind = TRAConditionKind.ResetIf;
    if SourceResets or (SameGroup and SourcePauses) then
      Source.OperatorKind := Inverted(Source.OperatorKind);
    if ComparedResets or (SameGroup and ComparedPauses) then
      Compared.OperatorKind := Inverted(Compared.OperatorKind);

    Overlap := ComparisonOverlap(Source, Compared);
    case Overlap of
      TRAOverlap.None:
        Exit;
      TRAOverlap.Conflict:
        if not SameGroup and (SourcePauses <> ComparedPauses) then
          Exit;
      TRAOverlap.Redundant:
        begin
          if not SameGroup and (Compared.GroupIndex = 0) and
            (ComparisonOverlap(Compared, Source) <> TRAOverlap.Redundant) then
            Exit;
          if SourcePauses or ComparedPauses then
          begin
            if not SameGroup or (ComparisonOverlap(Compared, Source) <> TRAOverlap.Redundant) then
              Exit;
            if SourceResets or ComparedResets then
              Overlap := TRAOverlap.Conflict;
          end
          else if SourceResets <> ComparedResets then
          begin
            if HasTargets then
              Exit;
          end
          else if (Source.Kind = TRAConditionKind.MeasuredIf) or (Compared.Kind = TRAConditionKind.MeasuredIf) then
          begin
            if not SameGroup or ((Compared.Kind = TRAConditionKind.MeasuredIf) and (Source.Kind <> Compared.Kind)) then
              Exit;
          end
          else if (Source.Kind = TRAConditionKind.Trigger) and (Compared.Kind <> TRAConditionKind.Trigger) then
            Exit;
        end;
    end;

    for var Issue in Issues do
      if (Issue.Code in [TRAValidationCode.Conflict, TRAValidationCode.Redundant]) and
        (Issue.RelatedGroup = Compared.GroupIndex) and (Issue.RelatedCondition = Compared.ConditionIndex) then
        Exit;
    if Overlap = TRAOverlap.Conflict then
      Report(TRAValidationCode.Conflict, 'Conflicts with ')
    else
      Report(TRAValidationCode.Redundant, 'Redundant with ');
  end;

  function CompareGroups(SourceGroup, ComparedGroup: Integer): Boolean;
  var
    Before: Integer;
  begin
    Before := Issues.Count;
    for var SourceIndex := ComparisonStarts[SourceGroup] to ComparisonStarts[SourceGroup + 1] - 1 do
      for var ComparedIndex := ComparisonStarts[ComparedGroup] to ComparisonStarts[ComparedGroup + 1] - 1 do
        if SourceIndex <> ComparedIndex then
          CheckOverlap(Comparisons[SourceIndex], Comparisons[ComparedIndex]);
    Result := Issues.Count <> Before;
  end;

begin
  MaxAddress := Min(MaxAddress, RAConsoleMaxAddress(ConsoleID));
  HasTargets := False;
  for var Condition in Definition.Core do
    HasTargets := HasTargets or (Condition.RequiredHits <> 0);
  for var Group in Definition.Alternatives do
    for var Condition in Group do
      HasTargets := HasTargets or (Condition.RequiredHits <> 0);
  PrimaryIndex := -1;
  PrimaryPriority := MaxInt;
  ConsiderForPrimary := True;
  SetLength(GroupHasIssues, Length(Definition.Alternatives) + 1);
  SetLength(ComparisonStarts, Length(GroupHasIssues) + 1);
  Issues := TList<TRAValidationIssue>.Create;
  Comparisons := TList<TRAComparison>.Create;
  try
    CheckGroup(Definition.Core, 0);
    GroupHasIssues[0] := Issues.Count <> 0;
    ComparisonStarts[1] := Comparisons.Count;
    for var Index := 0 to High(Definition.Alternatives) do
    begin
      PreviousCount := Issues.Count;
      CheckGroup(Definition.Alternatives[Index], Index + 1);
      GroupHasIssues[Index + 1] := Issues.Count <> PreviousCount;
      ComparisonStarts[Index + 2] := Comparisons.Count;
    end;

    if not GroupHasIssues[0] then
      CompareGroups(0, 0);
    for var GroupIndex := 1 to High(GroupHasIssues) do
      if not GroupHasIssues[GroupIndex] and not CompareGroups(GroupIndex, GroupIndex) and
        not CompareGroups(0, GroupIndex) then
        CompareGroups(GroupIndex, 0);

    // Keep secondary findings for Delphi callers even when the C API skips a group's overlap pass.
    ConsiderForPrimary := False;
    for var GroupIndex := 0 to High(GroupHasIssues) do
      if GroupHasIssues[GroupIndex] then
        CompareGroups(GroupIndex, GroupIndex);
    Result := Issues.ToArray;
    if PrimaryIndex > 0 then
    begin
      PrimaryIssue := Result[PrimaryIndex];
      for var Index := PrimaryIndex downto 1 do
        Result[Index] := Result[Index - 1];
      Result[0] := PrimaryIssue;
    end;
  finally
    Comparisons.Free;
    Issues.Free;
  end;
end;

function MakeParseIssue(const Error: ERAConditionError): TRAValidationIssue;
begin
  Result := Default(TRAValidationIssue);
  Result.Code := TRAValidationCode.ParseError;
  Result.RelatedGroup := -1;
  Result.ExpressionPosition := Error.Position;
  if Error.Position > 0 then
    Result.Message := Error.Reason
  else
    Result.Message := Error.Message;
end;

function ValidateRADefinition(const Definition: TRATriggerDefinition; MaxAddress, ConsoleID: Cardinal): TArray<TRAValidationIssue>;
var
  Target: Cardinal;
  AsPercent: Boolean;
begin
  try
    ReadRATriggerMeasurement(Definition, Target, AsPercent);
  except
    on Error: ERAConditionError do
    begin
      Result := [MakeParseIssue(Error)];
      Exit;
    end;
  end;
  Result := ValidateDefinition(Definition, MaxAddress, ConsoleID, True);
end;

function ValidateRADefinition(const Expression: string; MaxAddress, ConsoleID: Cardinal): TArray<TRAValidationIssue>;
var
  NextPosition: Integer;
begin
  try
    Result := ValidateRADefinition(TRATriggerDefinition.ParsePrefix(Expression, NextPosition), MaxAddress, ConsoleID);
  except
    on Error: ERAConditionError do
      Result := [MakeParseIssue(Error)];
  end;
end;

function CopyValidationDiagnostic(const Issues: TArray<TRAValidationIssue>; Buffer: PAnsiChar; BufferSize: NativeUInt): Boolean;
begin
  Result := Length(Issues) = 0;
  if Result then
    CopyRAUTF8Text('', Buffer, BufferSize)
  else
    CopyRAUTF8Text(Issues[0].Message, Buffer, BufferSize);
end;

function ValidateRATrigger(const Definition: TRATriggerDefinition; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress, ConsoleID: Cardinal): Boolean;
begin
  Result := CopyValidationDiagnostic(ValidateRADefinition(Definition, MaxAddress, ConsoleID), Buffer, BufferSize);
end;

function ValidateRATrigger(const Expression: string; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress, ConsoleID: Cardinal): Boolean;
begin
  Result := CopyValidationDiagnostic(ValidateRADefinition(Expression, MaxAddress, ConsoleID), Buffer, BufferSize);
end;

function ValidateRAConditionGroup(const Group: TRAConditionGroup; Buffer: PAnsiChar; BufferSize: NativeUInt; MaxAddress, ConsoleID: Cardinal): Boolean;
var
  Definition: TRATriggerDefinition;
begin
  Definition := Default(TRATriggerDefinition);
  Definition.Core := Group;
  Result := CopyValidationDiagnostic(ValidateDefinition(Definition, MaxAddress, ConsoleID, False), Buffer, BufferSize);
end;

end.

