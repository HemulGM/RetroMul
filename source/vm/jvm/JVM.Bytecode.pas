unit JVM.Bytecode;

interface

uses
  System.SysUtils;

// Structural checking is deliberately separate from type-flow/StackMap verification.
function JVMInstructionMap(const Code: TBytes; MaxLocals: Integer): TArray<Boolean>;

implementation

uses
  System.Generics.Collections, JVM.Types;

function JVMInstructionMap(const Code: TBytes; MaxLocals: Integer): TArray<Boolean>;
var
  PC, Start, N, I, Index, Slots: Integer;
  Op, Sub: Byte;
  Offset, LowKey, HighKey, LastKey: Integer;
  Targets: TList<Int64>;

  procedure Need(Count: Integer);
  begin
    if (Count < 0) or (Count > Length(Code) - PC) then
      raise EJVMFormatError.Create('Truncated bytecode instruction');
  end;

  function U1: Byte;
  begin
    Need(1);
    Result := Code[PC];
    Inc(PC);
  end;

  function U2: Word;
  var
    A: Byte;
  begin
    A := U1;
    Result := (Word(A) shl 8) or U1;
  end;

  function S4: Integer;
  var
    A: Word;
  begin
    A := U2;
    Result := Integer((UInt32(A) shl 16) or U2);
  end;

  procedure local(At, Width: Integer);
  begin
    if (At < 0) or (At > MaxLocals - Width) then
      raise EJVMFormatError.CreateFmt('Local %d width %d exceeds max_locals %d at pc %d opcode $%.2x', [At, Width, MaxLocals, Start, Op]);
  end;

  procedure Target(Value: Int64);
  begin
    if (Value < 0) or (Value >= Length(Code)) then
      raise EJVMFormatError.Create('Branch outside bytecode');
    Targets.Add(Value);
  end;

begin
  Result := nil;
  SetLength(Result, Length(Code) + 1);
  PC := 0;
  Targets := TList<Int64>.Create;
  try
    while PC < Length(Code) do
    begin
      Start := PC;
      Result[PC] := True;
      Op := U1;
      N := 0;
      case Op of
        $00..$0F, $2E..$35, $4F..$83, $85..$98, $AC..$B1, $BE, $BF, $C2, $C3:
          ;
        $10, $12, $BC:
          N := 1;
        $11, $13, $14, $B2..$B8, $BB, $BD, $C0, $C1:
          N := 2;
        $15..$19, $36..$3A:
          begin
            Index := U1;
            Slots := 1;
            if Op in [$16, $18, $37, $39] then
              Slots := 2;
            local(Index, Slots);
          end;
        $1A..$2D:
          begin
            I := (Op - $1A) div 4;
            Slots := 1;
            if I in [1, 3] then
              Slots := 2;
            local((Op - $1A) mod 4, Slots);
          end;
        $3B..$4E:
          begin
            I := (Op - $3B) div 4;
            Slots := 1;
            if I in [1, 3] then
              Slots := 2;
            local((Op - $3B) mod 4, Slots);
          end;
        $84:
          begin
            local(U1, 1);
            U1;
          end;
        $99..$A8, $C6, $C7:
          begin
            Offset := SmallInt(U2);
            Target(Int64(Start) + Offset);
          end;
        $A9:
          local(U1, 1);
        $AA, $AB:
          begin
            while (PC and 3) <> 0 do
              U1;
            Offset := S4;
            Target(Int64(Start) + Offset);
            if Op = $AA then
            begin
              LowKey := S4;
              HighKey := S4;
              if (HighKey < LowKey) or (Int64(HighKey) - LowKey + 1 > (Length(Code) - PC) div 4) then
                raise EJVMFormatError.Create('Invalid tableswitch range');
              N := Integer(Int64(HighKey) - LowKey + 1);
              for I := 1 to N do
              begin
                Offset := S4;
                Target(Int64(Start) + Offset);
              end;
            end
            else
            begin
              N := S4;
              if (N < 0) or (N > (Length(Code) - PC) div 8) then
                raise EJVMFormatError.Create('Invalid lookupswitch range');
              LastKey := Low(Integer);
              for I := 1 to N do
              begin
                Index := S4;
                if (I > 1) and (Index <= LastKey) then
                  raise EJVMFormatError.Create('Unsorted lookupswitch keys');
                LastKey := Index;
                Offset := S4;
                Target(Int64(Start) + Offset);
              end;
            end;
            N := 0;
          end;
        $B9:
          begin
            U2;
            if (U1 = 0) or (U1 <> 0) then
              raise EJVMFormatError.Create('Invalid invokeinterface operands');
          end;
        $BA:
          begin
            U2;
            if U2 <> 0 then
              raise EJVMFormatError.Create('Invalid invokedynamic operands');
          end;
        $C4:
          begin
            Sub := U1;
            Index := U2;
            Slots := 1;
            case Sub of
              $16, $18, $37, $39:
                Slots := 2;
              $15, $17, $19, $36, $38, $3A, $A9:
                ;
              $84:
                U2;
            else
              raise EJVMFormatError.Create('Invalid wide opcode');
            end;
            local(Index, Slots);
          end;
        $C5:
          begin
            U2;
            if U1 = 0 then
              raise EJVMFormatError.Create('Zero multianewarray dimensions');
          end;
        $C8, $C9:
          begin
            Offset := S4;
            Target(Int64(Start) + Offset);
          end;
      else
        raise EJVMFormatError.CreateFmt('Invalid opcode $%.2x', [Op]);
      end;
      Need(N);
      Inc(PC, N);
    end;
    Result[Length(Code)] := True;
    for var BranchTarget in Targets do
      if not Result[Integer(BranchTarget)] then
        raise EJVMFormatError.Create('Branch enters an instruction operand');
  finally
    Targets.Free;
  end;
end;

end.

