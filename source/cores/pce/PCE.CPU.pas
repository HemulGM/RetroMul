unit PCE.CPU;

interface

uses
  System.SysUtils;

type
  THuCRead = function(Address: Word): Byte of object;

  THuCWrite = procedure(Address: Word; Value: Byte) of object;
 // HuC6280 logical addresses; the bus maps the eight MPR banks.

  THuC6280 = class
  private
    FRead: THuCRead;
    FWrite: THuCWrite;
    FVDCWrite: THuCWrite;
    FSource, FDestination, FRemaining, FTransfer, FToggle: Integer;
    function Fetch: Integer;
    function FetchWord: Integer;
    function ZWord(Address: Integer): Integer;
    procedure Push(Value: Integer);
    function Pop: Integer;
    procedure NZ(Value: Integer);
    procedure Compare(L, R: Integer);
    procedure Arithmetic(Value: Integer; Subtract: Boolean);
    function Branch(Taken: Boolean): Integer;
  public
    A, X, Y, SP, P, PC: Integer;
    MPR: array[0..7] of Byte;
    LowSpeed: Boolean;
    constructor Create(Read: THuCRead; Write: THuCWrite; WriteVDC: THuCWrite = nil);
    procedure Reset(Address, Track: Integer);
    function Interrupt(Vector: Word): Integer;
    function Step: Integer;
  end;

implementation

uses
  System.Math;

constructor THuC6280.Create(Read: THuCRead; Write: THuCWrite; WriteVDC: THuCWrite);
begin
  inherited Create;
  FRead := Read;
  FWrite := Write;
  FVDCWrite := WriteVDC;
end;

procedure THuC6280.Reset(Address, Track: Integer);
begin
  A := Track and 255;
  X := 0;
  Y := 0;
  SP := $FD;
  P := $04;
  PC := Address and $FFFF;
  LowSpeed := False;
  FRemaining := 0;
end;

function THuC6280.Fetch: Integer;
begin
  Result := FRead(PC);
  PC := (PC + 1) and $FFFF;
end;

function THuC6280.FetchWord: Integer;
begin
  Result := Fetch;
  Result := Result + Fetch * 256;
end;

function THuC6280.ZWord(Address: Integer): Integer;
begin
  Result := Integer(FRead($2000 or (Address and 255))) + Integer(FRead($2000 or ((Address + 1) and 255))) * 256;
end;

procedure THuC6280.Push(Value: Integer);
begin
  FWrite($2100 or SP, Value and 255);
  SP := (SP - 1) and 255;
end;

function THuC6280.Pop: Integer;
begin
  SP := (SP + 1) and 255;
  Result := FRead($2100 or SP);
end;

procedure THuC6280.NZ(Value: Integer);
begin
  P := P and $7D;
  if Value and 255 = 0 then
    P := P or 2;
  P := P or (Value and $80);
end;

procedure THuC6280.Compare(L, R: Integer);
begin
  P := P and $FE;
  if L >= R then
    P := P or 1;
  NZ((L - R) and 255);
end;

procedure THuC6280.Arithmetic(Value: Integer; Subtract: Boolean);
begin
  var Old := A;
  var V := Value;
  if Subtract then
    V := V xor 255;
  var Sum := A + V + (P and 1);
  var Binary := Sum and 255;
  var Overflow := ((not (Old xor V)) and (Old xor Binary) and $80) <> 0;
  var Carry := Sum > 255;
  if P and 8 <> 0 then
  begin
    if not Subtract then
    begin
      if (Old and 15) + (Value and 15) + (P and 1) > 9 then
        Inc(Sum, 6);
      if Sum > $99 then
        Inc(Sum, $60);
      Carry := Sum > 255;
    end
    else
    begin
      Sum := Old - Value - 1 + (P and 1);
      if (Old and 15) - (Value and 15) - 1 + (P and 1) < 0 then
        Dec(Sum, 6);
      if Sum < 0 then
        Dec(Sum, $60);
    end;
  end;
  A := Sum and 255;
  P := P and $BE;
  if Carry then
    P := P or 1;
  if Overflow then
    P := P or $40;
  NZ(A);
end;

function THuC6280.Branch(Taken: Boolean): Integer;
begin
  var Offset := Fetch;
  if Offset >= 128 then
    Dec(Offset, 256);
  Result := 2;
  if Taken then
  begin
    PC := (PC + Offset) and $FFFF;
    Result := 4;
  end;
end;

function THuC6280.Interrupt(Vector: Word): Integer;
begin
  Result := 0;
  if (P and 4 <> 0) or (FRemaining <> 0) then
    Exit;
  Push(PC shr 8);
  Push(PC);
  Push(P and $EF);
  P := (P and $D7) or 4;
  PC := Integer(FRead(Vector)) + Integer(FRead((Integer(Vector) + 1) and $FFFF)) * 256;
  Result := 8;
end;

function THuC6280.Step: Integer;
var
  Op, Group, Mode, Address, Value, Temp, Mask, OldA: Integer;
  Transfer: Boolean;
begin
  if FRemaining > 0 then
  begin
    FWrite(FDestination, FRead(FSource));
    case FTransfer of
      $73:
        begin
          FSource := (FSource + 1) and $FFFF;
          FDestination := (FDestination + 1) and $FFFF;
        end;
      $C3:
        begin
          FSource := (FSource - 1) and $FFFF;
          FDestination := (FDestination - 1) and $FFFF;
        end;
      $D3:
        FSource := (FSource + 1) and $FFFF;
      $E3:
        begin
          FSource := (FSource + 1) and $FFFF;
          FDestination := (FDestination + 1 - 2 * FToggle) and $FFFF;
          FToggle := FToggle xor 1;
        end;
      $F3:
        begin
          FDestination := (FDestination + 1) and $FFFF;
          FSource := (FSource + 1 - 2 * FToggle) and $FFFF;
          FToggle := FToggle xor 1;
        end;
    end;
    Dec(FRemaining);
    Exit(6);
  end;
  Op := Fetch;
  Transfer := P and $20 <> 0;
  P := P and $DF;
  Result := 2;
  if Op and $1F = $10 then
  begin
    case Op shr 5 of
      0:
        Transfer := P and $80 = 0;
      1:
        Transfer := P and $80 <> 0;
      2:
        Transfer := P and $40 = 0;
      3:
        Transfer := P and $40 <> 0;
      4:
        Transfer := P and 1 = 0;
      5:
        Transfer := P and 1 <> 0;
      6:
        Transfer := P and 2 = 0;
    else
      Transfer := P and 2 <> 0;
    end;
    Exit(Branch(Transfer));
  end;
  if Op and $0F = 7 then
  begin
    Address := $2000 or Fetch;
    Value := FRead(Address);
    Mask := 1 shl ((Op shr 4) and 7);
    if Op < $80 then
      Value := Value and (Mask xor 255)
    else
      Value := Value or Mask;
    FWrite(Address, Value);
    Exit(7);
  end;
  if Op and $0F = $0F then
  begin
    Address := $2000 or Fetch;
    Value := FRead(Address);
    Mask := 1 shl ((Op shr 4) and 7);
    Exit(Branch((Value and Mask <> 0) = (Op >= $80)) + 4);
  end;
  if ((Op and 3 = 1) and (Op <> $89)) or (Op and $1F = $12) then
  begin
    Group := Op shr 5;
    Mode := (Op shr 2) and 7;
    if Op and $1F = $12 then
    begin
      Address := ZWord(Fetch);
      Result := 7;
    end
    else
      case Mode of
        0:
          begin
            Address := ZWord((Fetch + X) and 255);
            Result := 7;
          end;
        1:
          begin
            Address := $2000 or Fetch;
            Result := 4;
          end;
        2:
          begin
            Address := PC;
            PC := (PC + 1) and $FFFF;
            Result := 2;
          end;
        3:
          begin
            Address := FetchWord;
            Result := 5;
          end;
        4:
          begin
            Address := (ZWord(Fetch) + Y) and $FFFF;
            Result := 7;
          end;
        5:
          begin
            Address := $2000 or ((Fetch + X) and 255);
            Result := 4;
          end;
        6:
          begin
            Address := (FetchWord + Y) and $FFFF;
            Result := 5;
          end;
      else
        begin
          Address := (FetchWord + X) and $FFFF;
          Result := 5;
        end;
      end;
    if Group = 4 then
    begin
      FWrite(Address, A);
      Exit;
    end;
    Value := FRead(Address);
    OldA := A;
    if Transfer and (Group <= 3) then
    begin
      A := FRead($2000 or X);
      Inc(Result, 3);
    end;
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
          if P and 8 <> 0 then
            Inc(Result);
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
          if P and 8 <> 0 then
            Inc(Result);
        end;
    end;
    if Transfer and (Group <= 3) then
    begin
      FWrite($2000 or X, A);
      A := OldA;
    end;
    Exit;
  end;
  if (Op and 3 = 2) and ((Op and $1F) in [2, 6, $0A, $0E, $16, $1E]) and ((Op and $1F <> $0A) or (Op < $80)) and not (Op in [$02, $22, $42, $62, $82, $9E, $C2, $E2]) then
  begin
    Group := Op shr 5;
    Mode := (Op shr 2) and 7;
    Address := -1;
    case Mode of
      0:
        begin
          Address := PC;
          PC := (PC + 1) and $FFFF;
          Result := 2;
        end;
      1:
        begin
          Address := $2000 or Fetch;
          Result := ifthen(Group in [4, 5], 4, 6);
        end;
      2:
        Result := 2;
      3:
        begin
          Address := FetchWord;
          Result := ifthen(Group in [4, 5], 5, 7);
        end;
      5:
        begin
          Temp := X;
          if Group in [4, 5] then
            Temp := Y;
          Address := $2000 or ((Fetch + Temp) and 255);
          Result := ifthen(Group in [4, 5], 4, 6);
        end;
      7:
        begin
          Temp := X;
          Address := (FetchWord + Temp) and $FFFF;
          Result := ifthen(Group = 5, 5, 7);
        end;
    else
      raise EArgumentException.CreateFmt('Invalid HuC6280 opcode %.2x', [Op]);
    end;
    if Address < 0 then
      Value := A
    else
      Value := FRead(Address);
    case Group of
      0:
        begin
          Temp := Value * 2;
          P := (P and $FE) or Ord(Temp > 255);
          Value := Temp and 255;
          NZ(Value);
        end;
      1:
        begin
          Temp := Value * 2 + (P and 1);
          P := (P and $FE) or Ord(Temp > 255);
          Value := Temp and 255;
          NZ(Value);
        end;
      2:
        begin
          P := (P and $FE) or (Value and 1);
          Value := Value shr 1;
          NZ(Value);
        end;
      3:
        begin
          Temp := (Value shr 1) + (P and 1) * 128;
          P := (P and $FE) or (Value and 1);
          Value := Temp;
          NZ(Value);
        end;
      4:
        Value := X;
      5:
        begin
          X := Value;
          NZ(X);
          Exit;
        end;
      6:
        begin
          Value := (Value - 1) and 255;
          NZ(Value);
        end;
      7:
        begin
          Value := (Value + 1) and 255;
          NZ(Value);
        end;
    end;
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
        Push(P or $10);
        P := (P and $D7) or 4;
        PC := Integer(FRead($FFF6)) + Integer(FRead($FFF7)) * 256;
        Result := 8;
      end;
    $02:
      begin
        Temp := X;
        X := Y;
        Y := Temp;
        Result := 3;
      end;
    $22:
      begin
        Temp := A;
        A := X;
        X := Temp;
        Result := 3;
      end;
    $42:
      begin
        Temp := A;
        A := Y;
        Y := Temp;
        Result := 3;
      end;
    $03, $13, $23:
      begin
        Value := Fetch;
        Address := 0;
        if Op = $13 then
          Address := 2
        else if Op = $23 then
          Address := 3;
        if Assigned(FVDCWrite) then
          FVDCWrite(Address, Value)
        else
          FWrite(Address, Value);
        Result := 4;
      end;
    $04, $0C, $14, $1C:
      begin
        if Op and 8 = 0 then
          Address := $2000 or Fetch
        else
          Address := FetchWord;
        Value := FRead(Address);
        P := P and $FD;
        if A and Value = 0 then
          P := P or 2;
        if Op and $10 = 0 then
          Value := Value or A
        else
          Value := Value and (A xor 255);
        FWrite(Address, Value);
        Result := 6 + Ord(Op and 8 <> 0);
      end;
    $08:
      begin
        Push(P or $10);
        Result := 3;
      end;
    $28:
      begin
        P := Pop;
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
    $F4:
      P := P or $20;
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
        Result := 7;
      end;
    $40:
      begin
        P := Pop;
        PC := Pop;
        PC := PC + Pop * 256;
        Result := 7;
      end;
    $43, $53:
      begin
        Mask := Fetch;
        for var I := 0 to 7 do
          if Mask and (1 shl I) <> 0 then
            if Op = $43 then
              A := MPR[I]
            else
              MPR[I] := A;
        Result := 4 + Ord(Op = $53);
      end;
    $44:
      begin
        Value := Fetch;
        if Value >= 128 then
          Dec(Value, 256);
        Temp := (PC - 1) and $FFFF;
        Push(Temp shr 8);
        Push(Temp);
        PC := (PC + Value) and $FFFF;
        Result := 8;
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
        Result := 4;
      end;
    $6C, $7C:
      begin
        Address := FetchWord;
        if Op = $7C then
          Address := (Address + X) and $FFFF;
        PC := Integer(FRead(Address)) + Integer(FRead((Address + 1) and $FFFF)) * 256;
        Result := 7;
      end;
    $54:
      LowSpeed := True;
    $D4:
      LowSpeed := False;
    $60:
      begin
        Temp := Pop;
        PC := (Temp + Pop * 256 + 1) and $FFFF;
        Result := 7;
      end;
    $62:
      A := 0;
    $82:
      X := 0;
    $C2:
      Y := 0;
    $64, $74, $9C, $9E:
      begin
        if Op in [$64, $74] then
        begin
          Address := Fetch;
          if Op = $74 then
            Address := (Address + X) and 255;
          Address := Address or $2000;
        end
        else
        begin
          Address := FetchWord;
          if Op = $9E then
            Address := (Address + X) and $FFFF;
        end;
        FWrite(Address, 0);
        Result := 4 + Ord(Op in [$9C, $9E]);
      end;
    $24, $2C, $34, $3C, $89:
      begin
        case Op of
          $89:
            begin
              Address := PC;
              PC := (PC + 1) and $FFFF;
              Result := 2;
            end;
          $24:
            begin
              Address := $2000 or Fetch;
              Result := 4;
            end;
          $34:
            begin
              Address := $2000 or ((Fetch + X) and 255);
              Result := 4;
            end;
          $2C:
            begin
              Address := FetchWord;
              Result := 5;
            end;
        else
          begin
            Address := (FetchWord + X) and $FFFF;
            Result := 5;
          end;
        end;
        Value := FRead(Address);
        P := P and $FD;
        if A and Value = 0 then
          P := P or 2;
        if Op <> $89 then
          P := (P and $3F) or (Value and $C0);
      end;
    $73, $C3, $D3, $E3, $F3:
      begin
        FSource := FetchWord;
        FDestination := FetchWord;
        FRemaining := FetchWord;
        if FRemaining = 0 then
          FRemaining := 65536;
        FToggle := 0;
        FTransfer := Op;
        Result := 17;
      end;
    $80:
      Result := Branch(True);
    $83, $93, $A3, $B3:
      begin
        Mask := Fetch;
        if Op in [$83, $A3] then
          Address := $2000 or Fetch
        else
          Address := FetchWord;
        if Op in [$A3, $B3] then
          if Op = $A3 then
            Address := $2000 or ((Address + X) and 255)
          else
            Address := (Address + X) and $FFFF;
        Value := FRead(Address);
        P := P and $3D;
        P := P or (Value and $C0);
        if Value and Mask = 0 then
          P := P or 2;
        Result := 7 + Ord(Op in [$93, $B3]);
      end;
    $84, $94, $8C:
      begin
        if Op = $8C then
          Address := FetchWord
        else
        begin
          Address := Fetch;
          if Op = $94 then
            Address := (Address + X) and 255;
          Address := Address or $2000;
        end;
        FWrite(Address, Y);
        Result := 4 + Ord(Op = $8C);
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
              Result := 2;
            end;
          4:
            begin
              Address := $2000 or Fetch;
              Result := 4;
            end;
          $0C:
            begin
              Address := FetchWord;
              Result := 5;
            end;
          $14:
            begin
              Address := $2000 or ((Fetch + X) and 255);
              Result := 4;
            end;
        else
          begin
            Address := (FetchWord + X) and $FFFF;
            Result := 5;
          end;
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
    $EA:
      Result := 2;
  else
    raise EArgumentException.CreateFmt('Unknown HuC6280 opcode %.2x at %.4x', [Op, (PC - 1) and $FFFF]);
  end;
end;

end.

