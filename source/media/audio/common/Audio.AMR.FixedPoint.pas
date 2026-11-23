unit Audio.AMR.FixedPoint;

interface

{$POINTERMATH ON}

type
  PAMRSmallInt = ^SmallInt;

  // AMR saturation is sticky. Each codec keeps its own instance of this record.
  TAMRFixedPoint = record
  strict private
    FOverflow: Integer;
  public
    function Saturate(Left: Integer): SmallInt;
    function Add(Left, Right: SmallInt): SmallInt;
    function Sub(Left, Right: SmallInt): SmallInt;
    function LAdd(Left, Right: Integer): Integer;
    function LSub(Left, Right: Integer): Integer;
    function Mult(Left, Right: SmallInt): SmallInt;
    function LMult(Left, Right: SmallInt): Integer;
    function LMac(LVar3: Integer; Left, Right: SmallInt): Integer;
    function LMsu(LVar3: Integer; Left, Right: SmallInt): Integer;
    function ShiftLeft(Left, Right: SmallInt): SmallInt;
    function ShiftRight(Left, Right: SmallInt): SmallInt;
    function LShl(Left: Integer; Right: SmallInt): Integer;
    function LShr(Left: Integer; Right: SmallInt): Integer;
    function ShrR(Left, Right: SmallInt): SmallInt;
    function LShrR(Left: Integer; Right: SmallInt): Integer;
    function Round(Left: Integer): SmallInt;
    function DivS(Left, Right: SmallInt): SmallInt;
    procedure LExtract(L32: Integer; Hi, Lo: PAMRSmallInt);
    function Mpy3216(Hi, Lo, N: SmallInt): Integer;
    procedure Log2Norm(LX: Integer; Exp: SmallInt; Exponent, Fraction: PAMRSmallInt);
    procedure Log2(LX: Integer; Exponent, Fraction: PAMRSmallInt);
    function Pow2(Exponent, Fraction: SmallInt): Integer;
    property Overflow: Integer read FOverflow write FOverflow;
  end;

function SignedRightShift(Value, Count: Integer): Integer; inline;

function AmrExtractL(Left: Integer): SmallInt;

function AmrExtractH(Left: Integer): SmallInt;

function AmrLDepositL(Left: SmallInt): Integer;

function AmrLDepositH(Left: SmallInt): Integer;

function AmrNormL(Left: Integer): SmallInt;

function AmrNormS(Left: SmallInt): SmallInt;

function AmrAbsS(Left: SmallInt): SmallInt;

function AmrLAbs(Left: Integer): Integer;

function AmrNegate(Left: SmallInt): SmallInt;

implementation

uses
  System.SysUtils;

// Shared fixed-point primitives from 3GPP TS 26.073 and TS 26.173.
// The operations that wrap before testing for overflow require unchecked arithmetic.
{$Q-}
{$R-}
{$B-}

const
  Log2Table: array[0..32] of SmallInt = (
    0, 1455, 2866, 4236, 5568, 6863, 8124, 9352, 10549, 11716, 12855, 13967,
    15054, 16117, 17156, 18172, 19167, 20142, 21097, 22033, 22951, 23852, 24735, 25603,
    26455, 27291, 28113, 28922, 29716, 30497, 31266, 32023, 32767
  );
  Pow2Table: array[0..32] of SmallInt = (
    16384, 16743, 17109, 17484, 17867, 18258, 18658, 19066, 19484, 19911, 20347, 20792,
    21247, 21713, 22188, 22674, 23170, 23678, 24196, 24726, 25268, 25821, 26386, 26964,
    27554, 28158, 28774, 29405, 30048, 30706, 31379, 32066, 32767
  );

function SignedRightShift(Value, Count: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := not ((not Value) shr Count)
  else
    Result := Value shr Count;
end;

function AmrExtractL(Left: Integer): SmallInt;
var
  Value: SmallInt;
begin
  Value := SmallInt(Left);
  Result := Value;
end;

function AmrExtractH(Left: Integer): SmallInt;
var
  Value: SmallInt;
begin
  Value := SmallInt(SignedRightShift(Left, 16));
  Result := Value;
end;

function AmrLDepositL(Left: SmallInt): Integer;
var
  Value: Integer;
begin
  Value := Integer(Left);
  Result := Value;
end;

function AmrLDepositH(Left: SmallInt): Integer;
var
  Value: Integer;
begin
  Value := Integer(Left) shl 16;
  Result := Value;
end;

function AmrNormL(Left: Integer): SmallInt;
var
  Value: SmallInt;
begin
  if Left = 0 then
    Value := 0
  else
  begin
    if Left = Integer($FFFFFFFF) then
      Value := 31
    else
    begin
      if Left < 0 then
        Left := not Left;
      Value := 0;
      while Left < Integer($40000000) do
      begin
        Left := Left shl 1;
        Inc(Value);
      end;
    end;
  end;
  Result := Value;
end;

function AmrNormS(Left: SmallInt): SmallInt;
var
  Value: SmallInt;
begin
  if Left = 0 then
    Value := 0
  else
  begin
    if Left = SmallInt($FFFF) then
      Value := 15
    else
    begin
      if Left < 0 then
        Left := not Left;
      Value := 0;
      while Left < $4000 do
      begin
        Left := Left shl 1;
        Inc(Value);
      end;
    end;
  end;
  Result := Value;
end;

function AmrAbsS(Left: SmallInt): SmallInt;
var
  Value: SmallInt;
begin
  if Left = SmallInt($8000) then
    Value := SmallInt($7FFF)
  else
  begin
    if Left < 0 then
      Value := -Left
    else
      Value := Left;
  end;
  Result := Value;
end;

function AmrLAbs(Left: Integer): Integer;
var
  Value: Integer;
begin
  if Left = Integer($80000000) then
    Value := Integer($7FFFFFFF)
  else
  begin
    if Left < 0 then
      Value := -Left
    else
      Value := Left;
  end;
  Result := Value;
end;

function AmrNegate(Left: SmallInt): SmallInt;
var
  Value: SmallInt;
begin
  if Left = SmallInt($8000) then
    Value := SmallInt($7FFF)
  else
    Value := -Left;
  Result := Value;
end;

function TAMRFixedPoint.Saturate(Left: Integer): SmallInt;
var
  Value: SmallInt;
begin
  if Left > $7FFF then
  begin
    FOverflow := 1;
    Value := SmallInt($7FFF);
  end
  else
  begin
    if Left < Integer($FFFF8000) then
    begin
      FOverflow := 1;
      Value := SmallInt($8000);
    end
    else
      Value := AmrExtractL(Left);
  end;
  Result := Value;
end;

function TAMRFixedPoint.Add(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
  LSum: Integer;
begin
  LSum := Integer(Left) + Right;
  Value := Saturate(LSum);
  Result := Value;
end;

function TAMRFixedPoint.Sub(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
  LDiff: Integer;
begin
  LDiff := Integer(Left) - Right;
  Value := Saturate(LDiff);
  Result := Value;
end;

function TAMRFixedPoint.LAdd(Left, Right: Integer): Integer;
var
  Value: Integer;
begin
  Value := Left + Right;
  if ((Left xor Right) and Integer($80000000)) = 0 then
  begin
    if ((Value xor Left) and Integer($80000000)) <> 0 then
    begin
      if Left < 0 then
        Value := Integer($80000000)
      else
        Value := Integer($7FFFFFFF);
      FOverflow := 1;
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.LSub(Left, Right: Integer): Integer;
var
  Value: Integer;
begin
  Value := Left - Right;
  if ((Left xor Right) and Integer($80000000)) <> 0 then
  begin
    if ((Value xor Left) and Integer($80000000)) <> 0 then
    begin
      if Left < 0 then
        Value := Integer($80000000)
      else
        Value := Integer($7FFFFFFF);
      FOverflow := 1;
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.Mult(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
  LProduct: Integer;
begin
  LProduct := Integer(Left) * Integer(Right);
  LProduct := SignedRightShift((LProduct and Integer($FFFF8000)), 15);
  if (LProduct and Integer($10000)) <> 0 then
    LProduct := LProduct or Integer($FFFF0000);
  Value := Saturate(LProduct);
  Result := Value;
end;

function TAMRFixedPoint.LMult(Left, Right: SmallInt): Integer;
var
  Value: Integer;
begin
  Value := Integer(Left) * Integer(Right);
  if Value <> Integer($40000000) then
    Value := Value * 2
  else
  begin
    FOverflow := 1;
    Value := Integer($7FFFFFFF);
  end;
  Result := Value;
end;

function TAMRFixedPoint.LMac(LVar3: Integer; Left, Right: SmallInt): Integer;
var
  Value: Integer;
  LProduct: Integer;
begin
  LProduct := LMult(Left, Right);
  Value := LAdd(LVar3, LProduct);
  Result := Value;
end;

function TAMRFixedPoint.LMsu(LVar3: Integer; Left, Right: SmallInt): Integer;
var
  Value: Integer;
  LProduct: Integer;
begin
  LProduct := LMult(Left, Right);
  Value := LSub(LVar3, LProduct);
  Result := Value;
end;

function TAMRFixedPoint.ShiftLeft(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
  ResultValue: Integer;
begin
  if Right < 0 then
  begin
    if Right < (-16) then
      Right := -16;
    Value := ShiftRight(Left, (-Right));
  end
  else
  begin
    ResultValue := Integer(Left) * (Integer(1) shl Right);
    if ((Right > 15) and (Left <> 0)) or (ResultValue <> Integer(SmallInt(ResultValue))) then
    begin
      FOverflow := 1;
      if Left > 0 then
        Value := SmallInt($7FFF)
      else
        Value := SmallInt($8000);
    end
    else
      Value := AmrExtractL(ResultValue);
  end;
  Result := Value;
end;

function TAMRFixedPoint.ShiftRight(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
begin
  if Right < 0 then
  begin
    if Right < (-16) then
      Right := -16;
    Value := ShiftLeft(Left, (-Right));
  end
  else
  begin
    if Right >= 15 then
    begin
      if Left < 0 then
        Value := -1
      else
        Value := 0;
    end
    else
    begin
      if Left < 0 then
        Value := not SignedRightShift((not Left), Right)
      else
        Value := SignedRightShift(Left, Right);
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.LShl(Left: Integer; Right: SmallInt): Integer;
var
  Value: Integer;
begin
  Value := Left;
  if Right <= 0 then
  begin
    if Right < (-32) then
      Right := -32;
    Value := LShr(Left, (-Right));
  end
  else
  begin
    while Right > 0 do
    begin
      if Left > Integer($3FFFFFFF) then
      begin
        FOverflow := 1;
        Value := Integer($7FFFFFFF);
        Break;
      end
      else
      begin
        if Left < Integer($C0000000) then
        begin
          FOverflow := 1;
          Value := Integer($80000000);
          Break;
        end;
      end;
      Left := Left * 2;
      Value := Left;
      Dec(Right);
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.LShr(Left: Integer; Right: SmallInt): Integer;
var
  Value: Integer;
begin
  if Right < 0 then
  begin
    if Right < (-32) then
      Right := -32;
    Value := LShl(Left, (-Right));
  end
  else
  begin
    if Right >= 31 then
    begin
      if Left < 0 then
        Value := -1
      else
        Value := 0;
    end
    else
    begin
      if Left < 0 then
        Value := not SignedRightShift((not Left), Right)
      else
        Value := SignedRightShift(Left, Right);
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.ShrR(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
begin
  if Right > 15 then
    Value := 0
  else
  begin
    Value := ShiftRight(Left, Right);
    if Right > 0 then
    begin
      if (Left and (SmallInt(1) shl (Right - 1))) <> 0 then
      begin
        Inc(Value);
      end;
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.LShrR(Left: Integer; Right: SmallInt): Integer;
var
  Value: Integer;
begin
  if Right > 31 then
    Value := 0
  else
  begin
    Value := LShr(Left, Right);
    if Right > 0 then
    begin
      if (Left and (Integer(1) shl (Right - 1))) <> 0 then
      begin
        Inc(Value);
      end;
    end;
  end;
  Result := Value;
end;

function TAMRFixedPoint.Round(Left: Integer): SmallInt;
var
  Value: SmallInt;
  LRounded: Integer;
begin
  LRounded := LAdd(Left, Integer($8000));
  Value := AmrExtractH(LRounded);
  Result := Value;
end;

function TAMRFixedPoint.DivS(Left, Right: SmallInt): SmallInt;
var
  Value: SmallInt;
  Iteration: SmallInt;
  LNum: Integer;
  LDenom: Integer;
begin
  Value := 0;
  if (Left > Right) or (Left < 0) or (Right < 0) then
  begin
    raise EInvalidOpException.Create('3GPP AMR-NB reference error');
  end;
  if Right = 0 then
  begin
    raise EInvalidOpException.Create('3GPP AMR-NB reference error');
  end;
  if Left = 0 then
    Value := 0
  else
  begin
    if Left = Right then
      Value := SmallInt($7FFF)
    else
    begin
      LNum := AmrLDepositL(Left);
      LDenom := AmrLDepositL(Right);
      for Iteration := 0 to 14 do
      begin
        Value := Value shl 1;
        LNum := LNum shl 1;
        if LNum >= LDenom then
        begin
          LNum := LSub(LNum, LDenom);
          Value := Add(Value, 1);
        end;
      end;
    end;
  end;
  Result := Value;
end;

procedure TAMRFixedPoint.LExtract(L32: Integer; Hi, Lo: PAMRSmallInt);
begin
  Hi^ := AmrExtractH(L32);
  Lo^ := AmrExtractL(LMsu(LShr(L32, 1), Hi^, 16384));
end;

function TAMRFixedPoint.Mpy3216(Hi, Lo, N: SmallInt): Integer;
var
  L32: Integer;
begin
  L32 := LMult(Hi, N);
  L32 := LMac(L32, Mult(Lo, N), 1);
  Result := L32;
end;

procedure TAMRFixedPoint.Log2Norm(LX: Integer; Exp: SmallInt; Exponent, Fraction: PAMRSmallInt);
var
  I: SmallInt;
  A: SmallInt;
  Tmp: SmallInt;
  LY: Integer;
begin
  if LX <= Integer(0) then
  begin
    Exponent^ := 0;
    Fraction^ := 0;
    Exit;
  end;
  Exponent^ := Sub(30, Exp);
  LX := LShr(LX, 9);
  I := AmrExtractH(LX);
  LX := LShr(LX, 1);
  A := AmrExtractL(LX);
  A := A and SmallInt($7FFF);
  I := Sub(I, 32);
  LY := AmrLDepositH(Log2Table[I]);
  Tmp := Sub(Log2Table[I], Log2Table[I + 1]);
  LY := LMsu(LY, Tmp, A);
  Fraction^ := AmrExtractH(LY);
end;

procedure TAMRFixedPoint.Log2(LX: Integer; Exponent, Fraction: PAMRSmallInt);
var
  Exp: SmallInt;
begin
  Exp := AmrNormL(LX);
  Log2Norm(LShl(LX, Exp), Exp, Exponent, Fraction);
end;

function TAMRFixedPoint.Pow2(Exponent, Fraction: SmallInt): Integer;
var
  Exp: SmallInt;
  I: SmallInt;
  A: SmallInt;
  Tmp: SmallInt;
  LX: Integer;
begin
  LX := LMult(Fraction, 32);
  I := AmrExtractH(LX);
  LX := LShr(LX, 1);
  A := AmrExtractL(LX);
  A := A and SmallInt($7FFF);
  LX := AmrLDepositH(Pow2Table[I]);
  Tmp := Sub(Pow2Table[I], Pow2Table[I + 1]);
  LX := LMsu(LX, Tmp, A);
  Exp := Sub(30, Exponent);
  LX := LShrR(LX, Exp);
  Result := LX;
end;

end.

