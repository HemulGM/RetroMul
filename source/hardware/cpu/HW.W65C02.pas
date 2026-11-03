unit HW.W65C02;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots;

type
  T65C02Read = function(Address: Word): Byte of object;

  T65C02Write = procedure(Address: Word; Value: Byte) of object;

  // CMOS 65C02 instruction engine. The host accounts for bus wait states.
  TW65C02 = class
  private
    FRead: T65C02Read;
    FWrite: T65C02Write;
    function Fetch: Integer;
    function FetchWord: Integer;
    function ReadWord(Address: Integer): Integer;
    function ZWord(Address: Integer): Integer;
    procedure Push(Value: Integer);
    function Pop: Integer;
    procedure NZ(Value: Integer);
    procedure Compare(L, R: Integer);
    procedure Arithmetic(Value: Integer; Subtract: Boolean);
    function Branch(Taken: Boolean): Integer;
  public
    A, X, Y, SP, P, PC: Integer;
    Waiting, Stopped: Boolean;
    constructor Create(Read: T65C02Read; Write: T65C02Write);
    procedure Reset;
    function Interrupt(Vector: Word = $FFFE; NonMaskable: Boolean = False): Integer;
    function Step: Integer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

constructor TW65C02.Create(Read: T65C02Read; Write: T65C02Write);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
end;

procedure TW65C02.Reset;
begin
  A := 0;
  X := 0;
  Y := 0;
  SP := $FD;
  P := $24;
  PC := ReadWord($FFFC);
  Waiting := False;
  Stopped := False;
end;

function TW65C02.Fetch: Integer;
begin
  Result := FRead(PC);
  PC := (PC + 1) and $FFFF;
end;

function TW65C02.FetchWord: Integer;
begin
  Result := Fetch;
  Result := Result or (Fetch shl 8);
end;

function TW65C02.ReadWord(Address: Integer): Integer;
begin
  Result := FRead(Address and $FFFF);
  Result := Result or (Integer(FRead((Address + 1) and $FFFF)) shl 8);
end;

function TW65C02.ZWord(Address: Integer): Integer;
begin
  Result := FRead(Address and 255);
  Result := Result or (Integer(FRead((Address + 1) and 255)) shl 8);
end;

procedure TW65C02.Push(Value: Integer);
begin
  FWrite($100 or SP, Value and 255);
  SP := (SP - 1) and 255;
end;

function TW65C02.Pop: Integer;
begin
  SP := (SP + 1) and 255;
  Result := FRead($100 or SP);
end;

procedure TW65C02.NZ(Value: Integer);
begin
  P := (P and $7D) or (Value and $80);
  if Value and 255 = 0 then
    P := P or 2;
end;

procedure TW65C02.Compare(L, R: Integer);
begin
  P := (P and $FE) or Ord(L >= R);
  NZ((L - R) and 255);
end;

procedure TW65C02.Arithmetic(Value: Integer; Subtract: Boolean);
var
  Sum, Low, High, Carry, Binary, Overflow: Integer;
begin
  Carry := P and 1;
  if Subtract then
  begin
    Sum := A - Value - (1 - Carry);
    Binary := Sum and 255;
    Overflow := ((A xor Value) and (A xor Binary) and $80) shr 1;
    Carry := Ord(Sum >= 0);
    if P and 8 <> 0 then
    begin
      Low := (A and 15) - (Value and 15) - (1 - (P and 1));
      High := (A shr 4) - (Value shr 4);
      if Low < 0 then
      begin
        Dec(Low, 6);
        Dec(High);
      end;
      if High < 0 then
        Dec(High, 6);
      Sum := (High shl 4) + (Low and 15);
    end;
  end
  else
  begin
    Sum := A + Value + Carry;
    Overflow := ((not (A xor Value)) and (A xor Sum) and $80) shr 1;
    if P and 8 <> 0 then
    begin
      Low := (A and 15) + (Value and 15) + Carry;
      if Low > 9 then
        Low := ((Low + 6) and 15) + 16;
      Sum := (A and $F0) + (Value and $F0) + Low;
      Overflow := ((not (A xor Value)) and (A xor Sum) and $80) shr 1;
      if Sum > $9F then
        Inc(Sum, $60);
    end;
    Carry := Ord(Sum > 255);
  end;
  A := Sum and 255;
  P := (P and $BE) or Carry or Overflow;
  NZ(A);
end;

function TW65C02.Branch(Taken: Boolean): Integer;
begin
  var Offset := Fetch;
  if Offset >= 128 then
    Dec(Offset, 256);
  Result := 2;
  if Taken then
  begin
    var OldPC := PC;
    PC := (PC + Offset) and $FFFF;
    Result := 3 + Ord((PC xor OldPC) and $FF00 <> 0);
  end;
end;

function TW65C02.Interrupt(Vector: Word; NonMaskable: Boolean): Integer;
begin
  Result := 0;
  if Stopped then
    Exit;
  Waiting := False; // Even a masked IRQ releases WAI.
  if not NonMaskable and (P and 4 <> 0) then
    Exit;
  Push(PC shr 8);
  Push(PC);
  Push((P or $20) and $EF);
  P := (P and $F7) or $24;
  PC := ReadWord(Vector);
  Result := 7;
end;

function TW65C02.Step: Integer;
var
  Op, Group, Mode, Address, Base, Value, Temp, Mask: Integer;
  Taken: Boolean;
begin
  if Waiting or Stopped then
    Exit(1);
  Op := Fetch;
  Result := 2;
  if Op and $1F = $10 then
  begin
    case Op shr 5 of
      0:
        Taken := P and $80 = 0;
      1:
        Taken := P and $80 <> 0;
      2:
        Taken := P and $40 = 0;
      3:
        Taken := P and $40 <> 0;
      4:
        Taken := P and 1 = 0;
      5:
        Taken := P and 1 <> 0;
      6:
        Taken := P and 2 = 0;
    else
      Taken := P and 2 <> 0;
    end;
    Exit(Branch(Taken));
  end;
  if Op and 15 = 7 then
  begin
    Address := Fetch;
    Value := FRead(Address);
    Mask := 1 shl ((Op shr 4) and 7);
    if Op < $80 then
      Value := Value and (Mask xor 255)
    else
      Value := Value or Mask;
    FWrite(Address, Value);
    Exit(5);
  end;
  if Op and 15 = 15 then
  begin
    Address := Fetch;
    Value := FRead(Address);
    Mask := 1 shl ((Op shr 4) and 7);
    Exit(Branch((Value and Mask <> 0) = (Op >= $80)) + 3);
  end;
  if ((Op and 3 = 1) and (Op <> $89)) or (Op and $1F = $12) then
  begin
    Group := Op shr 5;
    Mode := (Op shr 2) and 7;
    if Op and $1F = $12 then
    begin
      Address := ZWord(Fetch);
      Result := 5;
    end
    else
      case Mode of
        0:
          begin
            Address := ZWord((Fetch + X) and 255);
            Result := 6;
          end;
        1:
          begin
            Address := Fetch;
            Result := 3;
          end;
        2:
          begin
            Address := PC;
            PC := (PC + 1) and $FFFF;
          end;
        3:
          begin
            Address := FetchWord;
            Result := 4;
          end;
        4:
          begin
            Base := ZWord(Fetch);
            Address := (Base + Y) and $FFFF;
            Result := 5 + Ord((Group = 4) or ((Address xor Base) and $FF00 <> 0));
          end;
        5:
          begin
            Address := (Fetch + X) and 255;
            Result := 4;
          end;
      else
        Base := FetchWord;
        if Mode = 6 then
          Temp := Y
        else
          Temp := X;
        Address := (Base + Temp) and $FFFF;
        Result := 4 + Ord((Group = 4) or ((Address xor Base) and $FF00 <> 0));
      end;
    if Group = 4 then
    begin
      FWrite(Address, A);
      Exit;
    end;
    Value := FRead(Address);
    case Group of
      0:
        begin
          A := A or Value;
          NZ(A);
        end;
      1:
        begin
          A := A and Value;
          NZ(A);
        end;
      2:
        begin
          A := A xor Value;
          NZ(A);
        end;
      3:
        begin
          Arithmetic(Value, False);
          Inc(Result, Ord(P and 8 <> 0));
        end;
      5:
        begin
          A := Value;
          NZ(A);
        end;
      6:
        Compare(A, Value);
      7:
        begin
          Arithmetic(Value, True);
          Inc(Result, Ord(P and 8 <> 0));
        end;
    end;
    Exit;
  end;
  if (Op and 3 = 2) and ((Op and $1F) in [2, 6, $0A, $0E, $16, $1E]) and
    ((Op and $1F <> $0A) or (Op < $80)) and
    not (Op in [$02, $22, $42, $62, $82, $9E, $C2, $E2]) then
  begin
    Group := Op shr 5;
    Mode := (Op shr 2) and 7;
    Address := -1;
    case Mode of
      0:
        begin
          Address := PC;
          PC := (PC + 1) and $FFFF;
        end;
      1:
        begin
          Address := Fetch;
          if Group in [4, 5] then
            Result := 3
          else
            Result := 5;
        end;
      2:
        Result := 2;
      3:
        begin
          Address := FetchWord;
          if Group in [4, 5] then
            Result := 4
          else
            Result := 6;
        end;
      5:
        begin
          if Group in [4, 5] then
            Temp := Y
          else
            Temp := X;
          Address := (Fetch + Temp) and 255;
          if Group in [4, 5] then
            Result := 4
          else
            Result := 6;
        end;
      7:
        begin
          Base := FetchWord;
          if Group = 5 then
            Temp := Y
          else
            Temp := X;
          Address := (Base + Temp) and $FFFF;
          if Group = 5 then
            Result := 4 + Ord((Base xor Address) and $FF00 <> 0)
          else
            Result := 6;
        end;
    end;
    if Group = 4 then
    begin
      FWrite(Address, X);
      Exit;
    end;
    if Address < 0 then
      Value := A
    else
      Value := FRead(Address);
    case Group of
      0:
        begin
          Temp := Value shl 1;
          P := (P and $FE) or (Value shr 7);
          Value := Temp and 255;
        end;
      1:
        begin
          Temp := (Value shl 1) or (P and 1);
          P := (P and $FE) or (Value shr 7);
          Value := Temp and 255;
        end;
      2:
        begin
          P := (P and $FE) or (Value and 1);
          Value := Value shr 1;
        end;
      3:
        begin
          Temp := (Value shr 1) or ((P and 1) shl 7);
          P := (P and $FE) or (Value and 1);
          Value := Temp;
        end;
      5:
        begin
          X := Value;
          NZ(X);
          Exit;
        end;
      6:
        Value := (Value - 1) and 255;
      7:
        Value := (Value + 1) and 255;
    end;
    NZ(Value);
    if Address < 0 then
      A := Value
    else
      FWrite(Address, Value);
    Exit;
  end;
  case Op of
    $00:
      begin
        Fetch;
        Push(PC shr 8);
        Push(PC);
        Push(P or $30);
        P := (P and $F7) or $24;
        PC := ReadWord($FFFE);
        Result := 7;
      end;
    $04, $0C, $14, $1C:
      begin
        if Op and 8 = 0 then
          Address := Fetch
        else
          Address := FetchWord;
        Value := FRead(Address);
        P := P and $FD;
        if Value and A = 0 then
          P := P or 2;
        if Op and $10 = 0 then
          Value := Value or A
        else
          Value := Value and (A xor 255);
        FWrite(Address, Value);
        Result := 5 + Ord(Op and 8 <> 0);
      end;
    $08:
      begin
        Push(P or $30);
        Result := 3;
      end;
    $28:
      begin
        P := (Pop and $EF) or $20;
        Result := 4;
      end;
    $18:
      P := P and $FE;
    $38:
      P := P or 1;
    $58:
      P := P and $FB;
    $78:
      P := P or 4;
    $B8:
      P := P and $BF;
    $D8:
      P := P and $F7;
    $F8:
      P := P or 8;
    $1A:
      begin
        A := (A + 1) and 255;
        NZ(A);
      end;
    $3A:
      begin
        A := (A - 1) and 255;
        NZ(A);
      end;
    $20:
      begin
        Address := FetchWord;
        Temp := (PC - 1) and $FFFF;
        Push(Temp shr 8);
        Push(Temp);
        PC := Address;
        Result := 6;
      end;
    $40:
      begin
        P := (Pop and $EF) or $20;
        PC := Pop;
        PC := PC or (Pop shl 8);
        Result := 6;
      end;
    $48:
      begin
        Push(A);
        Result := 3;
      end;
    $68:
      begin
        A := Pop;
        NZ(A);
        Result := 4;
      end;
    $4C:
      begin
        PC := FetchWord;
        Result := 3;
      end;
    $6C, $7C:
      begin
        Address := FetchWord;
        if Op = $7C then
          Address := (Address + X) and $FFFF;
        PC := ReadWord(Address);
        Result := 6;
      end;
    $60:
      begin
        Temp := Pop;
        PC := (Temp + (Pop shl 8) + 1) and $FFFF;
        Result := 6;
      end;
    $64, $74, $9C, $9E:
      begin
        case Op of
          $64:
            begin
              Address := Fetch;
              Result := 3;
            end;
          $74:
            begin
              Address := (Fetch + X) and 255;
              Result := 4;
            end;
          $9C:
            begin
              Address := FetchWord;
              Result := 4;
            end;
        else
          Address := (FetchWord + X) and $FFFF;
          Result := 5;
        end;
        FWrite(Address, 0);
      end;
    $24, $2C, $34, $3C, $89:
      begin
        case Op of
          $89:
            begin
              Address := PC;
              PC := (PC + 1) and $FFFF;
            end;
          $24:
            begin
              Address := Fetch;
              Result := 3;
            end;
          $34:
            begin
              Address := (Fetch + X) and 255;
              Result := 4;
            end;
          $2C:
            begin
              Address := FetchWord;
              Result := 4;
            end;
        else
          Base := FetchWord;
          Address := (Base + X) and $FFFF;
          Result := 4 + Ord((Base xor Address) and $FF00 <> 0);
        end;
        Value := FRead(Address);
        P := P and $FD;
        if A and Value = 0 then
          P := P or 2;
        if Op <> $89 then
          P := (P and $3F) or (Value and $C0);
      end;
    $80:
      Result := Branch(True);
    $84, $94, $8C:
      begin
        case Op of
          $84:
            begin
              Address := Fetch;
              Result := 3;
            end;
          $94:
            begin
              Address := (Fetch + X) and 255;
              Result := 4;
            end;
        else
          Address := FetchWord;
          Result := 4;
        end;
        FWrite(Address, Y);
      end;
    $88:
      begin
        Y := (Y - 1) and 255;
        NZ(Y);
      end;
    $C8:
      begin
        Y := (Y + 1) and 255;
        NZ(Y);
      end;
    $CA:
      begin
        X := (X - 1) and 255;
        NZ(X);
      end;
    $E8:
      begin
        X := (X + 1) and 255;
        NZ(X);
      end;
    $8A:
      begin
        A := X;
        NZ(A);
      end;
    $98:
      begin
        A := Y;
        NZ(A);
      end;
    $A8:
      begin
        Y := A;
        NZ(Y);
      end;
    $AA:
      begin
        X := A;
        NZ(X);
      end;
    $BA:
      begin
        X := SP;
        NZ(X);
      end;
    $9A:
      SP := X;
    $5A:
      begin
        Push(Y);
        Result := 3;
      end;
    $7A:
      begin
        Y := Pop;
        NZ(Y);
        Result := 4;
      end;
    $DA:
      begin
        Push(X);
        Result := 3;
      end;
    $FA:
      begin
        X := Pop;
        NZ(X);
        Result := 4;
      end;
    $A0, $A4, $AC, $B4, $BC, $C0, $C4, $CC, $E0, $E4, $EC:
      begin
        case Op and $1F of
          0:
            begin
              Address := PC;
              PC := (PC + 1) and $FFFF;
            end;
          4:
            begin
              Address := Fetch;
              Result := 3;
            end;
          $0C:
            begin
              Address := FetchWord;
              Result := 4;
            end;
          $14:
            begin
              Address := (Fetch + X) and 255;
              Result := 4;
            end;
        else
          Base := FetchWord;
          Address := (Base + X) and $FFFF;
          Result := 4 + Ord((Base xor Address) and $FF00 <> 0);
        end;
        Value := FRead(Address);
        case Op shr 5 of
          5:
            begin
              Y := Value;
              NZ(Y);
            end;
          6:
            Compare(Y, Value);
          7:
            Compare(X, Value);
        end;
      end;
    $CB:
      begin
        Waiting := True;
        Result := 3;
      end;
    $DB:
      begin
        Stopped := True;
        Result := 3;
      end;
    // Reserved CMOS opcodes are NOPs with defined operand lengths.
      $02, $22, $42, $62, $82, $C2, $E2:
      Fetch;
    $44:
      begin
        Fetch;
        Result := 3;
      end;
    $54, $D4, $F4:
      begin
        Fetch;
        Result := 4;
      end;
    $5C:
      begin
        FetchWord;
        Result := 8;
      end;
    $DC, $FC:
      begin
        FetchWord;
        Result := 4;
      end;
    $EA:
      Result := 2;
  else
    Result := 1;
  end;
end;

procedure TW65C02.SerializeState(State: TStateArchive);
begin
  State.Field(A, SizeOf(A));
  State.Field(X, SizeOf(X));
  State.Field(Y, SizeOf(Y));
  State.Field(SP, SizeOf(SP));
  State.Field(P, SizeOf(P));
  State.Field(PC, SizeOf(PC));
  State.Field(Waiting, SizeOf(Waiting));
  State.Field(Stopped, SizeOf(Stopped));
  if State.Loading and ((A < 0) or (A > 255) or (X < 0) or (X > 255) or
    (Y < 0) or (Y > 255) or (SP < 0) or (SP > 255) or (P < 0) or (P > 255) or
    (PC < 0) or (PC > $FFFF)) then
    raise EReadError.Create('Invalid 65C02 state');
end;

end.

