unit RA.Conditions;

interface

{$SCOPEDENUMS ON}

uses
  System.SysUtils, RA.Errors, RA.MemoryValues;

type
  ERAConditionError = class(Exception)
  private
    FReason: string;
    FPosition: Integer;
    FCode: Integer;
    function GetCode: Integer;
  public
    constructor CreateAt(const Reason: string; Position: Integer; Code: Integer = RAErrorInvalidState);
    constructor CreateWithCode(const Message: string; Code: Integer);
    property Code: Integer read GetCode;
    property Reason: string read FReason;
    property Position: Integer read FPosition;
  end;

  TRAOperandKind = (UnsignedConstant, FloatConstant, Memory, BCD, Inverted, Recall, LegacyFunction);

  TRAOperand = record
  private
    FFloatLiteral: Double;
  public
    Kind: TRAOperandKind;
    Memory: TRAMemoryReference;
    Value: TRAMemoryValue;
    function FloatLiteral: Double;
    function IsMemoryReference: Boolean;
  end;

  TRAConditionKind = (
    Standard, PauseIf, ResetIf, AddSource, SubSource, AddHits, SubHits, AndNext, OrNext,
    Measured, MeasuredPercent, MeasuredIf, AddAddress, Trigger, Remember, ResetNextIf
    );

  TRAOperator = (
    None, Equal, NotEqual, Less, LessOrEqual, Greater, GreaterOrEqual,
    Multiply, Divide, BitAnd, BitXor, Modulo, Add, Subtract
    );

  TRACondition = record
    Kind: TRAConditionKind;
    Left, Right: TRAOperand;
    OperatorKind: TRAOperator;
    RequiredHits: Cardinal;
    LegacyValueComparison: Boolean;
  end;

  TRAConditionGroup = TArray<TRACondition>;

  TRATriggerDefinition = record
    Core: TRAConditionGroup;
    Alternatives: TArray<TRAConditionGroup>;
    class function Parse(const Expression: string): TRATriggerDefinition; static;
    // Returns the compiled prefix and the first unconsumed character (1-based).
    class function ParsePrefix(const Expression: string; out NextPosition: Integer; GroupSeparator: Char = 'S'): TRATriggerDefinition; static;
  end;

implementation

uses
  System.Generics.Collections;

type
  TRAConditionParser = record
  private
    FExpression: string;
    FPosition: Integer;
    function Peek(Offset: Integer = 0): Char;
    procedure Fail(const Reason: string; Code: Integer);
    function ReadOperand: TRAOperand;
    function ReadOperator: TRAOperator;
    function ReadCondition: TRACondition;
  public
    constructor Create(const Expression: string);
    function ReadGroup: TRAConditionGroup;
  end;

function TRAOperand.FloatLiteral: Double;
begin
  Result := FFloatLiteral;
  if Result = 0 then
    Result := Value.Float;
end;

function TRAOperand.IsMemoryReference: Boolean;
begin
  Result := Kind in [TRAOperandKind.Memory, TRAOperandKind.BCD, TRAOperandKind.Inverted];
end;

constructor ERAConditionError.CreateAt(const Reason: string; Position: Integer; Code: Integer);
begin
  inherited CreateFmt('%s at position %d', [Reason, Position]);
  FReason := Reason;
  FPosition := Position;
  FCode := Code;
end;

constructor ERAConditionError.CreateWithCode(const Message: string; Code: Integer);
begin
  inherited Create(Message);
  FCode := Code;
end;

function ERAConditionError.GetCode: Integer;
begin
  if FCode = RAErrorOK then
    Exit(RAErrorInvalidState);
  Result := FCode;
end;

constructor TRAConditionParser.Create(const Expression: string);
begin
  if Pos(#0, Expression) > 0 then
    raise ERAConditionError.Create('Achievement condition contains a null character');
  FExpression := Expression;
  FPosition := 1;
end;

function TRAConditionParser.Peek(Offset: Integer): Char;
begin
  if FPosition + Offset > Length(FExpression) then
    Result := #0
  else
    Result := FExpression[FPosition + Offset];
end;

procedure TRAConditionParser.Fail(const Reason: string; Code: Integer);
begin
  raise ERAConditionError.CreateAt(Reason, FPosition, Code);
end;

function FloatLiteralWhole(Value: UInt64; Negative: Boolean): Double;
begin
  if not Negative then
    Exit(Value);

  // The original negates the integral part as C long before converting it to double.
  {$IF Defined(MSWINDOWS) or not Defined(CPU64BITS)}
  Result := Integer(Cardinal((-Int64(Value)) and High(Cardinal)));
  {$ELSE}
  var SignedValue := Int64(Value);
  if SignedValue <> Low(Int64) then
    SignedValue := -SignedValue;
  Result := SignedValue;
  {$ENDIF}
end;

function TRAConditionParser.ReadOperand: TRAOperand;
var
  Prefix: Char;
  Value: UInt64;
  Fraction, Scale: Cardinal;
  FractionalValue: Double;
  HasDigits, Negative, Signed, AllowFraction: Boolean;
  VariableStart: Integer;
begin
  Result := Default(TRAOperand);
  if TRAMemoryReference.TryParse(FExpression, FPosition, Result.Memory) then
  begin
    Result.Kind := TRAOperandKind.Memory;
    Exit;
  end;

  Prefix := UpCase(Peek);
  case Prefix of
    'B', '~':
      begin
        Inc(FPosition);
        if not TRAMemoryReference.TryParse(FExpression, FPosition, Result.Memory) or
          (Result.Memory.History <> TRAValueHistory.Current) then
          Fail('Invalid memory operand', RAErrorInvalidMemoryOperand);
        if Prefix = 'B' then
          Result.Kind := TRAOperandKind.BCD
        else
          Result.Kind := TRAOperandKind.Inverted;
        Exit;
      end;
    '{':
      begin
        Inc(FPosition);
        VariableStart := FPosition;
        if not CharInSet(UpCase(Peek), ['A'..'Z']) then
          Fail('Invalid variable name', RAErrorInvalidVariableName);
        repeat
          Inc(FPosition);
        until not CharInSet(UpCase(Peek), ['A'..'Z', '0'..'9']);
        if (Peek <> '}') or (FPosition - VariableStart > 15) then
          Fail('Invalid variable name', RAErrorInvalidVariableName);
        if Copy(FExpression, VariableStart, FPosition - VariableStart) <> 'recall' then
          Fail('Unknown variable name', RAErrorUnknownVariableName);
        Inc(FPosition);
        Result.Kind := TRAOperandKind.Recall;
        Exit;
      end;
    '@':
      begin
        Inc(FPosition);
        if not CharInSet(UpCase(Peek), ['A'..'Z']) then
          Fail('Invalid legacy function name', RAErrorInvalidFunctionOperand);
        repeat
          Inc(FPosition);
        until not CharInSet(UpCase(Peek), ['A'..'Z', '0'..'9', '_']);
        Result.Kind := TRAOperandKind.LegacyFunction;
        Exit;
      end;
    'H':
      begin
        Inc(FPosition);
        if UpCase(Peek(1)) = 'X' then
          Fail('Invalid hexadecimal operand', RAErrorInvalidConstantOperand);
        if not TryReadRAUnsignedLong(FExpression, FPosition, 16, Value) then
          Fail('Missing hexadecimal operand', RAErrorInvalidConstantOperand);
        if Value > High(Cardinal) then
          Value := High(Cardinal);
        Result.Value.Unsigned := Cardinal(Value);
        Exit;
      end;
    '0':
      if UpCase(Peek(1)) = 'X' then
        Fail('Invalid memory operand', RAErrorInvalidMemoryOperand);
    '1'..'9', '+', '-', 'V', 'F':
      ;
  else
    Fail('Missing operand', RAErrorInvalidMemoryOperand);
  end;

  AllowFraction := Prefix = 'F';
  Signed := CharInSet(Prefix, ['+', '-', 'V', 'F']);
  if CharInSet(Prefix, ['V', 'F']) then
    Inc(FPosition);
  Negative := Peek = '-';
  if CharInSet(Peek, ['+', '-']) then
    Inc(FPosition);
  HasDigits := TryReadRAUnsignedLong(FExpression, FPosition, 10, Value);

  if AllowFraction and (Peek = '.') then
  begin
    Inc(FPosition);
    if not CharInSet(Peek, ['0'..'9']) then
      Fail('Missing fractional digits', RAErrorInvalidFloatOperand);
    Fraction := 0;
    Scale := 1;
    repeat
      if Scale < 1000000000 then
      begin
        Fraction := Fraction * 10 + Cardinal(Ord(Peek) - Ord('0'));
        Scale := Scale * 10;
      end;
      Inc(FPosition);
    until not CharInSet(Peek, ['0'..'9']);
    Result.Kind := TRAOperandKind.FloatConstant;
    Result.Value.IsFloat := True;
    Result.FFloatLiteral := FloatLiteralWhole(Value, Negative);
    if Fraction <> 0 then
    begin
      FractionalValue := Fraction / Scale;
      if Negative then
        Result.FFloatLiteral := Result.FFloatLiteral - FractionalValue
      else
        Result.FFloatLiteral := Result.FFloatLiteral + FractionalValue;
    end;
    Result.Value.Float := Result.FFloatLiteral;
    Exit;
  end;

  if not HasDigits then
  begin
    if AllowFraction then
      Fail('Missing operand', RAErrorInvalidFloatOperand);
    Fail('Missing operand', RAErrorInvalidConstantOperand);
  end;
  if Signed and (Value > Cardinal(High(Integer))) then
    Value := High(Integer)
  else if Value > High(Cardinal) then
    Value := High(Cardinal);
  if Negative then
    Result.Value.Unsigned := Cardinal(-Integer(Value))
  else
    Result.Value.Unsigned := Cardinal(Value);
end;

function TRAConditionParser.ReadOperator: TRAOperator;
var
  Code: Char;
begin
  Code := Peek;
  if CharInSet(Code, [#0, '_', 'S', ')', '$']) then
    Exit(TRAOperator.None);
  Inc(FPosition);
  case Code of
    '=':
      begin
        if Peek = '=' then
          Inc(FPosition);
        Result := TRAOperator.Equal;
      end;
    '!':
      begin
        if Peek <> '=' then
          Fail('Expected "=" after "!"', RAErrorInvalidOperator);
        Inc(FPosition);
        Result := TRAOperator.NotEqual;
      end;
    '<':
      if Peek = '=' then
      begin
        Inc(FPosition);
        Result := TRAOperator.LessOrEqual;
      end
      else
        Result := TRAOperator.Less;
    '>':
      if Peek = '=' then
      begin
        Inc(FPosition);
        Result := TRAOperator.GreaterOrEqual;
      end
      else
        Result := TRAOperator.Greater;
    '*':
      Result := TRAOperator.Multiply;
    '/':
      Result := TRAOperator.Divide;
    '&':
      Result := TRAOperator.BitAnd;
    '^':
      Result := TRAOperator.BitXor;
    '%':
      Result := TRAOperator.Modulo;
    '+':
      Result := TRAOperator.Add;
    '-':
      Result := TRAOperator.Subtract;
  else
    Fail('Invalid condition operator', RAErrorInvalidOperator);
    Result := TRAOperator.None;
  end;
end;

function TRAConditionParser.ReadCondition: TRACondition;
var
  ModifiesSource: Boolean;
  First, Last: Char;
  Hits: UInt64;
begin
  Result := Default(TRACondition);
  if Peek(1) = ':' then
  begin
    case UpCase(Peek) of
      'P':
        Result.Kind := TRAConditionKind.PauseIf;
      'R':
        Result.Kind := TRAConditionKind.ResetIf;
      'A':
        Result.Kind := TRAConditionKind.AddSource;
      'B':
        Result.Kind := TRAConditionKind.SubSource;
      'C':
        Result.Kind := TRAConditionKind.AddHits;
      'D':
        Result.Kind := TRAConditionKind.SubHits;
      'N':
        Result.Kind := TRAConditionKind.AndNext;
      'O':
        Result.Kind := TRAConditionKind.OrNext;
      'M':
        Result.Kind := TRAConditionKind.Measured;
      'G':
        Result.Kind := TRAConditionKind.MeasuredPercent;
      'Q':
        Result.Kind := TRAConditionKind.MeasuredIf;
      'I':
        Result.Kind := TRAConditionKind.AddAddress;
      'T':
        Result.Kind := TRAConditionKind.Trigger;
      'K':
        Result.Kind := TRAConditionKind.Remember;
      'Z':
        Result.Kind := TRAConditionKind.ResetNextIf;
    else
      Fail('Invalid condition flag', RAErrorInvalidConditionType);
    end;
    Inc(FPosition, 2);
  end;

  Result.Left := ReadOperand;
  Result.OperatorKind := ReadOperator;
  ModifiesSource := Result.Kind in [TRAConditionKind.AddSource, TRAConditionKind.SubSource,
      TRAConditionKind.AddAddress, TRAConditionKind.Remember];
  if Result.OperatorKind = TRAOperator.None then
  begin
    if not ModifiesSource and not (Result.Kind in [TRAConditionKind.Measured, TRAConditionKind.MeasuredPercent]) then
      Fail('Missing comparison', RAErrorInvalidOperator);
    Exit;
  end;

  Result.Right := ReadOperand;
  if ModifiesSource and (Result.OperatorKind < TRAOperator.Multiply) then
  begin
    if Result.Kind = TRAConditionKind.Remember then
      Fail('Remember requires an arithmetic operator', RAErrorInvalidOperator);
    // Old achievement definitions used comparisons in source/address modifiers.
    Result.OperatorKind := TRAOperator.None;
    Result.Right := Default(TRAOperand);
  end;

  First := Peek;
  if CharInSet(First, ['(', '.']) then
  begin
    Inc(FPosition);
    Last := First;
    if First = '(' then
      Last := ')';
    if not TryReadRAUnsignedLong(FExpression, FPosition, 10, Hits) or (Peek <> Last) then
      Fail('Invalid required hits', RAErrorInvalidRequiredHits);
    if Result.OperatorKind <> TRAOperator.None then
      Result.RequiredHits := Cardinal(Hits and High(Cardinal));
    Inc(FPosition);
  end;
end;

function TRAConditionParser.ReadGroup: TRAConditionGroup;
var
  Conditions: TList<TRACondition>;
begin
  if CharInSet(UpCase(Peek), [#0, 'S']) then
    Exit(nil);
  Conditions := TList<TRACondition>.Create;
  try
    while True do
    begin
      Conditions.Add(ReadCondition);
      if Peek <> '_' then
        Break;
      Inc(FPosition);
    end;
    Result := Conditions.ToArray;
  finally
    Conditions.Free;
  end;
end;

class function TRATriggerDefinition.Parse(const Expression: string): TRATriggerDefinition;
var
  NextPosition: Integer;
begin
  Result := ParsePrefix(Expression, NextPosition);
  if NextPosition <= Length(Expression) then
    raise ERAConditionError.CreateAt('Unexpected condition separator', NextPosition, RAErrorInvalidOperator);
end;

class function TRATriggerDefinition.ParsePrefix(const Expression: string; out NextPosition: Integer; GroupSeparator: Char): TRATriggerDefinition;
var
  Parser: TRAConditionParser;
  Alternatives: TList<TRAConditionGroup>;
begin
  Parser := TRAConditionParser.Create(Expression);
  Result.Core := Parser.ReadGroup;
  Alternatives := TList<TRAConditionGroup>.Create;
  try
    while UpCase(Parser.Peek) = GroupSeparator do
    begin
      Inc(Parser.FPosition);
      Alternatives.Add(Parser.ReadGroup);
    end;
    NextPosition := Parser.FPosition;
    Result.Alternatives := Alternatives.ToArray;
  finally
    Alternatives.Free;
  end;
end;

end.

