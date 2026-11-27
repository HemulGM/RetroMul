unit HW.CPU.CP1600X.ALU;

interface

procedure ExecuteExtendedALU(Opcode: Byte; Swap: Boolean; Left, LeftHigh, Right: Word; var LowResult, HighResult: Word);

implementation

uses
  System.Math;

function Wrap(Value: Int64): Word; inline;
begin
  Result := Value and $FFFF;
end;

function RotateBytes(Value: Word): Word; inline;
begin
  Result := ((Value and $FF) shl 8) or (Value shr 8);
end;

function Signed(Value: Word): Integer; inline;
begin
  Result := (Value xor $8000) - $8000;
end;

function SignedShift(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value < 0 then
    Result := -1 - ((-1 - Value) shr Count)
  else
    Result := Value shr Count;
end;

function Number(Value: Word; Fixed, Unsigned: Boolean): Int64; inline;
begin
  if Fixed then
    Value := RotateBytes(Value);
  if Unsigned then
    Result := Value
  else
    Result := Signed(Value);
end;

function Direction(X, Y: Integer): Word;
begin
  // Fold into the first octant, using the cartridge's fixed point slopes.
  var A := 0;
  if Y < 0 then
    A := A xor 31;
  if X < 0 then
    A := A xor 15;
  var Upper := Abs(X);
  var Lower := Abs(Y);
  if Lower > Upper then
  begin
    Upper := Abs(Y);
    Lower := Abs(X);
    A := A xor 7;
  end;
  if Upper <> 0 then
    while Upper < $8000 do
    begin
      Upper := Upper shl 1;
      Lower := Lower shl 1;
    end;
  var Slope := $32EC;
  if Lower > (Int64(Upper) * $6A0A) shr 16 then
  begin
    A := A xor 2;
    Slope := $AB0E;
  end;
  if Lower > (Int64(Upper) * Slope) shr 16 then
    A := A xor 1;
  Result := ((A + 1) shr 1) and 15;
end;

function SearchBit(Value, Start, Step: Integer; FindOne: Boolean): Word;
begin
  var Bit := Start;
  while (Bit >= 0) and (Bit < 16) do
  begin
    if (Value and (1 shl Bit) <> 0) = FindOne then
      Exit(Bit);
    Inc(Bit, Step);
  end;
  Result := $FFFF;
end;

procedure DecimalALU(Left, Right: Word; Add, CarryIn, CarryOut: Boolean; var LowResult, HighResult: Word);
begin
  var Carry := 0;
  if CarryIn then
    Carry := ((LowResult and 7) xor 4) - 4;
  LowResult := 0;
  for var Shift in [0, 4, 8, 12] do
  begin
    var Digit := (Left shr Shift) and $F;
    var Other := (Right shr Shift) and $F;
    if Add then
      Inc(Digit, Other)
    else
      Dec(Digit, Other);
    Inc(Digit, Carry);
    Carry := (Digit + 20) div 10 - 2;
    LowResult := LowResult or ((Digit - Carry * 10) shl Shift);
  end;
  if CarryOut then
    HighResult := Wrap(Carry);
end;

procedure ExecuteExtendedALU(Opcode: Byte; Swap: Boolean; Left, LeftHigh, Right: Word; var LowResult, HighResult: Word);
begin
  if Swap then
  begin
    if Opcode in [$4E, $4F] then
      Exit;
    var Temp := Left;
    Left := Right;
    Right := Temp;
  end;

  var Count := Right and 15;
  var Bit := 1 shl Count;
  case Opcode of
    0:
      LowResult := Wrap((Integer(Left) + Right) * (1 - 2 * Ord(Swap)));
    1:
      LowResult := RotateBytes(Wrap((Integer(RotateBytes(Left)) + RotateBytes(Right)) * (1 - 2 * Ord(Swap))));
    2:
      LowResult := Wrap(Integer(Left) - Right);
    3:
      LowResult := RotateBytes(Wrap(Integer(RotateBytes(Left)) - RotateBytes(Right)));
    4..7:
      begin
        var Value: Word;
        case Opcode of
          4:
            Value := Left and Right;
          5:
            Value := not Left and Right;
          6:
            Value := Left or Right;
        else
          Value := Left xor Right;
        end;
        if Swap then
          Value := Value xor $FFFF;
        LowResult := Value;
      end;
    8, 9:
      begin
        var Value := Number(Left, False, Opcode = 9) * Bit;
        LowResult := Wrap(Value);
        HighResult := Wrap(SignedShift(Value, 16));
      end;
    $A, $B:
      begin
        LowResult := Wrap(SignedShift(Number(Left, False, Opcode = $B), Count));
        HighResult := Wrap(Int64(Left) shl (16 - Count));
      end;
    $C, $D:
      begin
        Count := Min(Count, 8);
        var L := Left and $FF;
        var H := Left shr 8;
        if Opcode = $C then
        begin
          LowResult := ((H shl Count) and $FF) shl 8 or ((L shl Count) and $FF);
          HighResult := (H shr (8 - Count)) shl 8 or (L shr (8 - Count));
        end
        else
        begin
          LowResult := (H shr Count) shl 8 or (L shr Count);
          HighResult := ((H shl (8 - Count)) and $FF) shl 8 or ((L shl (8 - Count)) and $FF);
        end;
      end;
    $E:
      LowResult := Wrap((Integer(Left) shl Count) or (Left shr (16 - Count)));
    $F:
      LowResult := Wrap((Left shr Count) or (Integer(Left) shl (16 - Count)));
    $10..$13:
      begin
        var FromLeft := Opcode = $12;
        if Opcode in [$10, $11] then
          FromLeft := Opcode = $10;
        var Value := 0;
        for var Index := 0 to Count do
        begin
          var Source := Index;
          if FromLeft then
            Source := 15 - Index;
          var Digit := (Left shr Source) and 1;
          if Opcode < $12 then
            Inc(Value, Digit)
          else if FromLeft then
            Value := Value or (Digit shl Index)
          else
            Value := Value or (Digit shl (Count - Index));
        end;
        if FromLeft and (Opcode >= $12) then
          Value := Value shl (15 - Count);
        LowResult := Value;
      end;
    $14, $15:
      LowResult := SearchBit(Left, Count, -1, Opcode = $14);
    $16, $17:
      LowResult := SearchBit(Left, Count, 1, Opcode = $16);
    $18, $19, $1A, $1B:
      begin
        var PackedLow := ((Left and $FF) shl 8) or (Right and $FF);
        var PackedHigh := (Left and $FF00) or (Right shr 8);
        case Opcode of
          $18:
            begin
              LowResult := PackedLow;
              HighResult := PackedHigh;
            end;
          $19:
            LowResult := PackedLow;
          $1A:
            LowResult := PackedHigh;
          $1B:
            LowResult := ((Left and $FF) shl 8) or (Right shr 8);
        end;
      end;
    $1C:
      LowResult := Left xor Bit;
    $1D:
      LowResult := Left or Bit;
    $1E:
      LowResult := Left and not Bit;
    $1F, $60:
      if (Left = Right) = Swap then
        LowResult := 0
      else if Opcode = $1F then
        LowResult := $FFFF;
    $20..$2F:
      begin
        var A := Number(Left, Odd(Opcode), Opcode and 8 = 0);
        var B := Number(Right, Odd(Opcode), Opcode and 8 = 0);
        if (A > B) or ((Opcode and 2 = 0) and (A = B)) then
          LowResult := 0
        else if Opcode and 4 = 0 then
          LowResult := $FFFF;
      end;
    $30..$35:
      begin
        var A := Number(Left, Odd(Opcode), Swap);
        var B := Number(Right, Odd(Opcode), Swap);
        var Value: Int64;
        case Opcode of
          $30, $31:
            Value := Min(A, B);
          $32, $33:
            Value := Max(A, B);
        else
          Value := EnsureRange(Number(LowResult, Odd(Opcode), Swap), Min(A, B), Max(A, B));
        end;
        LowResult := Wrap(Value);
        if Odd(Opcode) then
          LowResult := RotateBytes(LowResult);
      end;
    $36, $37:
      begin
        var Mask := Bit - 1;
        var Value := Integer(LowResult) + Integer(Left) * (1 - 2 * Ord(Odd(Opcode)));
        LowResult := (LowResult and not Mask) or (Value and Mask);
      end;
    $38, $39:
      LowResult := Direction(Number(Left, Odd(Opcode), False), Number(Right, Odd(Opcode), False));
    $3A..$3F:
      begin
        var A := Number(Left, Odd(Opcode), Swap);
        var B := Number(Right, Odd(Opcode), Swap);
        case Opcode of
          $3A, $3B:
            LowResult := Abs(A - B);
          $3C, $3D:
            LowResult := Wrap((123 * Max(Abs(A), Abs(B)) + 51 * Min(Abs(A), Abs(B))) shr 7);
          $3E, $3F:
            begin
              var Sum := Min(A * A + B * B, Int64($FFFFFFFF));
              LowResult := Wrap(Sum);
              HighResult := Wrap(Sum shr 16);
            end;
        end;
        if Opcode in [$3B, $3D] then
          LowResult := RotateBytes(LowResult);
      end;
    $40..$45:
      begin
        var A := Number(Left, Odd(Opcode), (Opcode >= $44) or ((Opcode < $42) and Swap));
        var B := Number(Right, Odd(Opcode), (Opcode in [$42, $43]) or ((Opcode < $42) and Swap));
        var Product := A * B;
        if Odd(Opcode) then
          LowResult := RotateBytes(Wrap(SignedShift(Product, 8)))
        else
        begin
          LowResult := Wrap(Product);
          HighResult := Wrap(SignedShift(Product, 16));
        end;
      end;
    $46:
      LowResult := Wrap(Int64(Left) * Right);
    $47:
      if Swap then
        LowResult := RotateBytes(Trunc(Sqrt(256 * Integer(RotateBytes(Right)))))
      else
        LowResult := Trunc(Sqrt(Left));
    $48:
      LowResult := Wrap((((Left and $FF) - $20) and $1FF) * 8 + Right);
    $49:
      LowResult := Wrap(((((Left shr 8) and $FF) - $20) and $1FF) * 8 + Right);
    $4A..$4F:
      begin
        var Unsigned := Opcode >= $4C;
        if Opcode >= $4E then
          Unsigned := Opcode = $4F;
        var Fixed := Opcode in [$4B, $4D];
        var Dividend := Number(Left, Fixed, Unsigned);
        if Fixed then
          Dividend := Dividend * 256
        else if Opcode >= $4E then
          Dividend := Number(LeftHigh, False, Unsigned) * 65536 + Left;
        var Divisor := Number(Right, Fixed, Unsigned);
        var Limit := Int64($7FFF + $8000 * Ord(Unsigned));
        LowResult := Limit;
        HighResult := Limit;
        if Divisor <> 0 then
        begin
          var Quotient := Dividend div Divisor;
          if (not Fixed and (Opcode < $4E)) or
            ((Quotient >= -$8000 * Ord(not Unsigned)) and (Quotient <= Limit)) then
          begin
            LowResult := Wrap(Quotient);
            HighResult := Wrap(Dividend mod Divisor);
          end;
        end;
        if Fixed then
        begin
          LowResult := RotateBytes(LowResult);
          HighResult := RotateBytes(HighResult);
        end;
      end;
    $50..$55:
      begin
        var Value: Int64;
        case Opcode of
          $50:
            Value := Number(Left, False, Swap) + Number(Right, False, Swap);
          $51:
            Value := Integer(Left) + Right + LowResult;
          $52:
            Value := Signed(Left) - Signed(Right);
          $53:
            Value := Integer(Left) - Right;
        else
          Value := Integer(Left) - Right + Signed(LowResult);
        end;
        LowResult := Wrap(Value);
        if (Opcode <> $55) and ((Opcode <> $51) or Swap) then
          HighResult := Wrap(SignedShift(Value, 16));
      end;
    $56:
      begin
        LowResult := Right;
        HighResult := Left;
      end;
    $57:
      begin
        LowResult := Wrap(Integer(Left) - Right);
        HighResult := Wrap(Integer(Left) + Right);
      end;
    $58..$5D:
      DecimalALU(Left, Right, Opcode < $5A, Opcode in [$59, $5C, $5D],
        (Opcode in [$5B, $5C]) or ((Opcode in [$58, $59]) and Swap), LowResult, HighResult);
    $5E:
      begin
        var Value := Min(99999999, (Int64(Left) shl 16) or Right);
        var BCD: Int64 := 0;
        for var Digit := 0 to 7 do
        begin
          BCD := BCD or ((Value mod 10) shl (Digit * 4));
          Value := Value div 10;
        end;
        LowResult := Wrap(BCD);
        HighResult := Wrap(BCD shr 16);
      end;
    $5F:
      begin
        var BCD := (Int64(Left) shl 16) or Right;
        var Value := 0;
        for var Digit := 7 downto 0 do
          Value := Value * 10 + ((BCD shr (Digit * 4)) and $F);
        LowResult := Wrap(Value);
        HighResult := Wrap(Value shr 16);
      end;
  end;
end;

end.

