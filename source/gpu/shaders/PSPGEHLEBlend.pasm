// GE integer blending and target-format logic operations.
function BlendTerm(Kind: Cardinal; C, Other, SA, DA, Fix: Integer): Integer;
begin
  case Kind of
    0:
      Exit(ArithmeticShiftRight((C + 1) * Other, 8));
    1:
      Exit(ArithmeticShiftRight((C + 1) * (255 - Other), 8));
    2:
      Exit(ArithmeticShiftRight((C + 1) * SA, 8));
    3:
      Exit(ArithmeticShiftRight((C + 1) * (255 - SA), 8));
    4:
      Exit(ArithmeticShiftRight((C + 1) * DA, 8));
    5:
      Exit(ArithmeticShiftRight((C + 1) * (255 - DA), 8));
    6:
      Exit(ArithmeticShiftRight((C + 1) * SA, 8) * 2);
    7:
      Exit(ArithmeticShiftRight((C + 1) * Max(0, 255 - 2 * SA), 8));
    8:
      Exit(ArithmeticShiftRight((C + 1) * DA, 8) * 2);
    9:
      Exit(ArithmeticShiftRight((C + 1) * Max(0, 255 - 2 * DA), 8));
  end;
  Result := ArithmeticShiftRight((C + 1) * Fix, 8);
end;

function BlendChannel(S, D, SA, DA, FixA, FixB: Integer): Integer;
begin
  var Op := (PC.Blend shr 8) and 7;
  if Op <= 2 then
  begin
    var A := BlendTerm(PC.Blend and 15, S, D, SA, DA, FixA);
    var B := BlendTerm((PC.Blend shr 4) and 15, D, S, SA, DA, FixB);
    if Op = 0 then
      Exit(A + B);
    Exit(if Op = 1 then A - B else B - A);
  end;
  if Op = 3 then
    Exit(Min(S, D));
  if Op = 4 then
    Exit(Max(S, D));
  Result := Abs(S - D);
end;

function EncodeColor(C: Integer3; Format: Cardinal): Cardinal;
begin
  var U := Cardinal3(C);
  if Format = 0 then
    Exit((U.R shr 3) or ((U.G shr 2) shl 5) or ((U.B shr 3) shl 11));
  if Format = 1 then
    Exit((U.R shr 3) or ((U.G shr 3) shl 5) or ((U.B shr 3) shl 10));
  if Format = 2 then
    Exit((U.R shr 4) or ((U.G shr 4) shl 4) or ((U.B shr 4) shl 8));
  Result := U.R or (U.G shl 8) or (U.B shl 16);
end;

function DecodeColor(P, Format: Cardinal): Integer3;
begin
  if Format = 0 then
  begin
    var Q := Cardinal3(P and 31, (P shr 5) and 63, (P shr 11) and 31);
    Exit(Integer3((Q.R shl 3) or (Q.R shr 2), (Q.G shl 2) or (Q.G shr 4), (Q.B shl 3) or (Q.B shr 2)));
  end;
  if Format = 1 then
  begin
    var Q := Cardinal3(P and 31, (P shr 5) and 31, (P shr 10) and 31);
    Exit(Integer3((Q shl 3) or (Q shr 2)));
  end;
  if Format = 2 then
    Exit(Integer3(Cardinal3(P and 15, (P shr 4) and 15, (P shr 8) and 15) * 17));
  Result := Integer3(Integer(P and 255), Integer((P shr 8) and 255), Integer((P shr 16) and 255));
end;

function LogicOp(F, S, D: Cardinal): Cardinal;
begin
  case F of
    0:
      Exit(0);
    1:
      Exit(S and D);
    2:
      Exit(S and not D);
    3:
      Exit(S);
    4:
      Exit(not S and D);
    5:
      Exit(D);
    6:
      Exit(S xor D);
    7:
      Exit(S or D);
    8:
      Exit(not (S or D));
    9:
      Exit(not (S xor D));
    10:
      Exit(not D);
    11:
      Exit(S or not D);
    12:
      Exit(not S);
    13:
      Exit(not S or D);
    14:
      Exit(not (S and D));
  end;
  Result := $FFFFFFFF;
end;
