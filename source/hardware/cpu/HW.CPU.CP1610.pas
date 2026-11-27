unit HW.CPU.CP1610;

interface

type
  TCP1610Read = function(Address: Word): Word of object;

  TCP1610Write = procedure(Address, Value: Word) of object;

  TCP1610Previous = function(Address: Word; out Value: Word): Boolean of object;

  TCP1610State = packed record
    Registers: array[0..7] of Word;
    Sign, Zero, Overflow, Carry, InterruptEnable, DoubleByte: Boolean;
    Interruptible, Halted: Boolean;
  end;

  TCP1600XState = packed record
    Registers: array[0..15] of Word;
    PreviousValue: Word;
  end;

  TCP1610 = class
  private
    FRead: TCP1610Read;
    FWrite: TCP1610Write;
    FPrevious: TCP1610Previous;
    FState: TCP1610State;
    FExtended: TCP1600XState;
    FExtendedEnabled: Boolean;
    function ExtendedOperation(Opcode: Word): Integer;
    function ExtendedDirect(Opcode: Word): Integer;
    function ExtendedALU(Opcode: Word): Integer;
    function Fetch: Word;
    procedure SetFlags(Value: Word; SignMask: Word = $8000);
    function Add(Left, Right: Word): Word;
    function Subtract(Left, Right: Word): Word;
    procedure Operate(Operation, Destination: Integer; Value: Word; SetMoveFlags: Boolean);
    function Shift(Opcode: Word): Integer;
    function Branch(Opcode: Word): Integer;
    function MemoryOperation(Opcode: Word; DoubleByte: Boolean): Integer;
  public
    constructor Create(const ReadWord: TCP1610Read; const WriteWord: TCP1610Write);
    procedure Reset;
    function Step(IRQ: Boolean; out Acknowledged: Boolean): Integer;
    function ReadExtendedPort(Address: Word): Word;
    procedure WriteExtendedPort(Address, Value: Word);
    property OnPreviousValue: TCP1610Previous read FPrevious write FPrevious;
    property ExtendedEnabled: Boolean read FExtendedEnabled write FExtendedEnabled;
    property ExtendedState: TCP1600XState read FExtended write FExtended;
    property State: TCP1610State read FState write FState;
  end;

implementation

uses
  HW.CPU.CP1600X.ALU;

constructor TCP1610.Create(const ReadWord: TCP1610Read; const WriteWord: TCP1610Write);
begin
  inherited Create;
  FRead := ReadWord;
  FWrite := WriteWord;
  Reset;
end;

procedure TCP1610.Reset;
begin
  FState := Default(TCP1610State);
  FExtended := Default(TCP1600XState);
  FState.Registers[7] := $1000;
end;

function TCP1610.Fetch: Word;
begin
  Result := FRead(FState.Registers[7]);
  FState.Registers[7] := Word(FState.Registers[7] + 1);
end;

procedure TCP1610.SetFlags(Value, SignMask: Word);
begin
  FState.Sign := Value and SignMask <> 0;
  FState.Zero := Value = 0;
end;

function TCP1610.Add(Left, Right: Word): Word;
begin
  var Sum := Cardinal(Left) + Right;
  Result := Word(Sum);
  FState.Carry := Sum > $FFFF;
  FState.Overflow := (not (Left xor Right) and (Left xor Result) and $8000) <> 0;
  SetFlags(Result);
end;

function TCP1610.Subtract(Left, Right: Word): Word;
begin
  Result := Word(Integer(Left) - Integer(Right));
  FState.Carry := Left >= Right;
  FState.Overflow := ((Left xor Right) and (Left xor Result) and $8000) <> 0;
  SetFlags(Result);
end;

procedure TCP1610.Operate(Operation, Destination: Integer; Value: Word; SetMoveFlags: Boolean);
begin
  var Original := FState.Registers[Destination];
  case Operation of
    2:
      if SetMoveFlags then
        SetFlags(Value);
    3:
      Value := Add(Original, Value);
    4:
      Value := Subtract(Original, Value);
    5:
      begin
        Subtract(Original, Value);
        Exit;
      end;
    6:
      begin
        Value := Original and Value;
        SetFlags(Value);
      end;
    7:
      begin
        Value := Original xor Value;
        SetFlags(Value);
      end;
  end;
  FState.Registers[Destination] := Value;
end;

function TCP1610.Shift(Opcode: Word): Integer;
begin
  FState.Interruptible := False;
  var RegisterIndex := Opcode and 3;
  var Count := 1 + ((Opcode shr 2) and 1);
  var Operation := (Opcode shr 3) and 7;
  var Value := FState.Registers[RegisterIndex];
  var Original := Value;
  var OldCarry := FState.Carry;
  var OldOverflow := FState.Overflow;
  case Operation of
    0:
      if Count = 1 then
        Value := (Value shr 8) or Word(Value shl 8)
      else
        Value := (Value and $FF) * $101;
    1, 2, 3:
      begin
        Value := Word(Value shl Count);
        if Operation = 2 then
        begin
          Value := Value or (Ord(OldCarry) shl (Count - 1));
          if Count = 2 then
            Value := Value or Word(Ord(OldOverflow));
        end;
        if Operation <> 1 then
        begin
          FState.Carry := Original and $8000 <> 0;
          if Count = 2 then
            FState.Overflow := Original and $4000 <> 0;
        end;
      end;
    4, 5, 6, 7:
      begin
        Value := Value shr Count;
        if (Operation in [5, 7]) and (Original and $8000 <> 0) then
          Value := Value or Word(Cardinal($FFFF) shl (16 - Count));
        if Operation = 6 then
        begin
          Value := Value or (Ord(OldCarry) shl (16 - Count));
          if Count = 2 then
            Value := Value or (Word(Ord(OldOverflow)) shl 15);
        end;
        if Operation in [6, 7] then
        begin
          FState.Carry := Original and 1 <> 0;
          if Count = 2 then
            FState.Overflow := Original and 2 <> 0;
        end;
      end;
  end;
  FState.Registers[RegisterIndex] := Value;
  if (Operation = 0) or (Operation >= 4) then
    SetFlags(Value, $80)
  else
    SetFlags(Value);
  Result := 4 + 2 * Count;
end;

function TCP1610.Branch(Opcode: Word): Integer;
begin
  var Displacement := Fetch;
  var Taken: Boolean;
  if Opcode and $10 <> 0 then
    Taken := False  // The Master Component has no external branch inputs.
  else
  begin
    case Opcode and 7 of
      0:
        Taken := True;
      1:
        Taken := FState.Carry;
      2:
        Taken := FState.Overflow;
      3:
        Taken := not FState.Sign;
      4:
        Taken := FState.Zero;
      5:
        Taken := FState.Sign xor FState.Overflow;
      6:
        Taken := FState.Zero or (FState.Sign xor FState.Overflow);
    else
      Taken := FState.Carry xor FState.Sign;
    end;
    if Opcode and 8 <> 0 then
      Taken := not Taken;
  end;
  Result := 7;
  if Taken then
  begin
    if Opcode and $20 <> 0 then
      Displacement := not Displacement;
    FState.Registers[7] := Word(FState.Registers[7] + Displacement);
    Result := 9;
  end;
end;

function TCP1610.MemoryOperation(Opcode: Word; DoubleByte: Boolean): Integer;
begin
  var AddressRegister := (Opcode shr 3) and 7;
  var DataRegister := Opcode and 7;
  var Operation := (Opcode shr 6) and 7;
  var Address: Word;
  if AddressRegister = 0 then
    Address := Fetch
  else
  begin
    if (AddressRegister = 6) and (Operation <> 1) then
      FState.Registers[6] := Word(FState.Registers[6] - 1);
    Address := FState.Registers[AddressRegister];
  end;

  if Operation = 1 then
  begin
    FWrite(Address, FState.Registers[DataRegister]);
    if AddressRegister >= 4 then
      FState.Registers[AddressRegister] := Word(Address + 1);
    FState.Interruptible := False;
    if AddressRegister = 0 then
      Exit(11);
    Exit(9);
  end;

  var Value := FRead(Address);
  if AddressRegister = 0 then
    Result := 10
  else if AddressRegister = 6 then
    Result := 11
  else
  begin
    Result := 8;
    if AddressRegister >= 4 then
      FState.Registers[AddressRegister] := Word(Address + 1);
    if DoubleByte then
    begin
      Address := FState.Registers[AddressRegister];
      Value := (Value and $FF) or ((FRead(Address) and $FF) shl 8);
      if AddressRegister >= 4 then
        FState.Registers[AddressRegister] := Word(Address + 1);
      Result := 10;
    end;
  end;
  Operate(Operation, DataRegister, Value, False);
end;

function TCP1610.ReadExtendedPort(Address: Word): Word;
begin
  if Address = $9F8D then
    Result := FExtended.PreviousValue
  else
    Result := FExtended.Registers[Address and $F];
end;

procedure TCP1610.WriteExtendedPort(Address, Value: Word);
begin
  if Address = $9F8D then
    FExtended.PreviousValue := Value
  else
    FExtended.Registers[Address and $F] := Value;
end;

function TCP1610.ExtendedALU(Opcode: Word): Integer;
begin
  var OperandPC := FState.Registers[7];
  var Operand := Fetch;
  FState.Interruptible := False;
  Result := 9;

  var Format := Opcode shr 10;
  var OperandType := (Format shr 1) and 3;
  var Operation := Operand shr 8;
  if (Format >= $20) or (OperandType = 0) or (Operation > $60) then
    Exit;

  var Index := Opcode and 7;
  var Left, LeftHigh: Word;
  if Format and 8 = 0 then
  begin
    Left := FState.Registers[Index];
    if Index = 7 then
      Left := OperandPC;
    LeftHigh := Left;
    if Operation in [$4E, $4F] then
      Left := 0;
  end
  else
  begin
    if Format and $10 <> 0 then
      Inc(Index, 8);
    Left := FExtended.Registers[Index];
    LeftHigh := FExtended.Registers[(Index + 1) and $F];
  end;

  var Right: Word := (Operand shr 4) and $F;
  case OperandType of
    1:
      Right := FExtended.Registers[Right];
    3:
      Right := Right xor $FFFF;
  end;
  var Dest := Operand and $F;
  FExtended.PreviousValue := FExtended.Registers[Dest];
  ExecuteExtendedALU(Operation, Format and 1 <> 0, Left, LeftHigh, Right,
    FExtended.Registers[Dest], FExtended.Registers[(Dest + 1) and $F]);
end;

function TCP1610.ExtendedDirect(Opcode: Word): Integer;
begin
  var RegisterIndex := Opcode and 7;
  var XRegister := (Opcode shr 10) and 7;
  var Mode := (Opcode shr 13) and 3;
  var Operation := (Opcode shr 6) and 7;
  var OperandPC := FState.Registers[7];
  var Offset := Fetch;
  var Address := Word(FExtended.Registers[XRegister] + Offset);
  var Value := Address;
  if Mode = 0 then
  begin
    if Operation = 1 then
    begin
      FExtended.Registers[XRegister] := Word(FState.Registers[RegisterIndex] + Offset);
      FState.Interruptible := False;
      Exit(11);
    end;
    if RegisterIndex = 7 then
      case Operation of
        2:
          begin
            if FExtended.Registers[XRegister] <> 0 then
              Value := Word(OperandPC + Offset)
            else
              Value := FState.Registers[7];
          end;
        7:
          begin
            FExtended.Registers[XRegister] := Word(FExtended.Registers[XRegister] - 1);
            Value := 0;
            if FExtended.Registers[XRegister] <> 0 then
              Value := FState.Registers[7] xor Word(OperandPC + Offset);
          end;
      end;
  end
  else
  begin
    var Effective := Address;
    if Mode = 2 then
      Effective := FExtended.Registers[XRegister];
    if Mode >= 2 then
      FExtended.Registers[XRegister] := Address;
    if Operation = 1 then
    begin
      FWrite(Effective, FState.Registers[RegisterIndex]);
      FState.Interruptible := False;
      Exit(11);
    end;
    Value := FRead(Effective);
  end;
  Operate(Operation, RegisterIndex, Value, False);
  Result := 10 + Ord(RegisterIndex >= 6);
end;

function TCP1610.ExtendedOperation(Opcode: Word): Integer;
begin
  var AddressRegister := (Opcode shr 3) and 7;
  var Operation := (Opcode shr 6) and 7;
  var Format := Opcode shr 10;
  Result := 0;
  if (AddressRegister = 0) and (Format and $1F <> 0) then
    Exit(ExtendedDirect(Opcode));
  if Operation <> 1 then
    Exit;
  if AddressRegister = 7 then
    Exit(ExtendedALU(Opcode));
  if (AddressRegister = 0) or (Format > 3) then
    Exit;
  var Address := FState.Registers[AddressRegister];
  var Value := FState.Registers[Opcode and 7];
  var Previous: Word;
  if Assigned(FPrevious) and FPrevious(Address, Previous) then
    case Format of
      1:
        Value := Word(Value + Previous);
      2:
        Value := Value and Previous;
      3:
        Value := Value or Previous;
    end;
  FWrite(Address, Value);
  if AddressRegister >= 4 then
    FState.Registers[AddressRegister] := Word(Address + 1);
  FState.Interruptible := False;
  Result := 9;
end;

function TCP1610.Step(IRQ: Boolean; out Acknowledged: Boolean): Integer;
begin
  Acknowledged := False;
  if FState.Halted then
    Exit(4);
  if IRQ and FState.InterruptEnable and FState.Interruptible then
  begin
    FWrite(FState.Registers[6], FState.Registers[7]);
    FState.Registers[6] := Word(FState.Registers[6] + 1);
    FState.Registers[7] := $1004;
    FState.Interruptible := False;
    Acknowledged := True;
    Exit(12);
  end;

  var DoubleByte := FState.DoubleByte;
  FState.DoubleByte := False;
  FState.Interruptible := True;
  var Instruction := Fetch;
  var Opcode := Instruction and $3FF;
  if FExtendedEnabled and (Instruction > $3FF) and (Opcode >= $240) then
  begin
    Result := ExtendedOperation(Instruction);
    if Result <> 0 then
      Exit;
  end;
  var Destination := Opcode and 7;
  if Opcode >= $240 then
    Exit(MemoryOperation(Opcode, DoubleByte));
  if Opcode >= $200 then
    Exit(Branch(Opcode));
  if Opcode >= $80 then
  begin
    var Operation := 2 + ((Opcode - $80) shr 6);
    Operate(Operation, Destination, FState.Registers[(Opcode shr 3) and 7], True);
    if (Operation = 2) and (Destination >= 6) then
      Exit(7);
    Exit(6);
  end;
  if Opcode >= $40 then
    Exit(Shift(Opcode));

  var Value := FState.Registers[Destination];
  Result := 6;
  case Opcode of
    $00..$07:
      begin
        Result := 4;
        FState.Interruptible := False;
        case Opcode of
          0:
            FState.Halted := True;
          1:
            FState.DoubleByte := True;
          2:
            FState.InterruptEnable := True;
          3:
            FState.InterruptEnable := False;
          4:
            begin
              var HighAddress := Fetch;
              var LowAddress := Fetch;
              var Link := 4 + ((HighAddress shr 8) and 3);
              if Link <> 7 then
                FState.Registers[Link] := FState.Registers[7];
              case HighAddress and 3 of
                1:
                  FState.InterruptEnable := True;
                2:
                  FState.InterruptEnable := False;
              end;
              FState.Registers[7] := ((HighAddress and $FC) shl 8) or (LowAddress and $3FF);
              FState.Interruptible := True;
              Result := 12;
            end;
          6:
            FState.Carry := False;
          7:
            FState.Carry := True;
        end;
      end;
    $08..$1F:
      begin
        case Opcode shr 3 of
          1:
            Value := Word(Value + 1);
          2:
            Value := Word(Value - 1);
          3:
            Value := not Value;
        end;
        SetFlags(Value);
        FState.Registers[Destination] := Value;
      end;
    $20..$27:
      FState.Registers[Destination] := Subtract(0, Value);
    $28..$2F:
      FState.Registers[Destination] := Add(Value, Ord(FState.Carry));
    $30..$33:
      FState.Registers[Destination] := ((Ord(FState.Sign) shl 7) or
        (Ord(FState.Zero) shl 6) or (Ord(FState.Overflow) shl 5) or
        (Ord(FState.Carry) shl 4)) * $101;
    $38..$3F:
      begin
        FState.Sign := Value and $80 <> 0;
        FState.Zero := Value and $40 <> 0;
        FState.Overflow := Value and $20 <> 0;
        FState.Carry := Value and $10 <> 0;
      end;
  end;
end;

end.

