// The accepted PS2 FP64 interpolation and its bounded Single estimates.
function PackDouble(Lo, Hi: Cardinal): Double;
begin
  Result := BitsToDouble(UInt64(Lo) or (UInt64(Hi) shl 32));
end;

function TowardZero(V: Double): Double;
begin
  Result := BitsToDouble(DoubleToBits(V) - UInt64(1));
end;

function StepDouble(V: Double; Up: Boolean): Double;
begin
  var Bits := DoubleToBits(V);
  if (V > 0.0d) = Up then
    Inc(Bits)
  else
    Dec(Bits);
  Result := BitsToDouble(Bits);
end;

function AddD(var Ctx: TPS2PixelContext; A, B: Double): Double;
begin
  var R: Double := A + B;
  if DrawParam(Ctx, 55) <> 3 then
    Exit(R);
  var Z: Double := R - A;
  var E: Double := (A - (R - Z)) + (B - Z);
  Result := if ((R > 0.0d) and (E < 0.0d)) or ((R < 0.0d) and (E > 0.0d)) then TowardZero(R) else R;
end;

function SubD(var Ctx: TPS2PixelContext; A, B: Double): Double;
begin
  Result := AddD(Ctx, A, -B);
end;

function MulD(var Ctx: TPS2PixelContext; A, B: Double): Double;
begin
  var R: Double := A * B;
  if DrawParam(Ctx, 55) <> 3 then
    Exit(R);
  var E: Double := Fma(A, B, -R);
  Result := if ((R > 0.0d) and (E < 0.0d)) or ((R < 0.0d) and (E > 0.0d)) then TowardZero(R) else R;
end;

function Residual(A, B, Q: Double): TPS2DoublePair;
begin
  var Product: Double := Q * B;
  var PE: Double := Fma(Q, B, -Product);
  var S: Double := A - Product;
  var E: Double := -PE;
  var Hi: Double := S + E;
  var Z: Double := Hi - S;
  var Lo: Double := (S - (Hi - Z)) + (E - Z);
  Result := Default(TPS2DoublePair);
  Result.Hi := Hi;
  Result.Lo := Lo;
end;

function PositiveDD(R: TPS2DoublePair): Boolean;
begin
  Result := (R.Hi > 0.0d) or ((R.Hi = 0.0d) and (R.Lo > 0.0d));
end;

function AbsDD(R: TPS2DoublePair): TPS2DoublePair;
begin
  if PositiveDD(R) then
    Exit(R);
  Result := Default(TPS2DoublePair);
  Result.Hi := -R.Hi;
  Result.Lo := -R.Lo;
end;

function DivD(var Ctx: TPS2PixelContext; A, B: Double): Double;
begin
  var Q: Double := A / B;
  if A = 0.0d then
    Exit(Q);
  for var I := 0 to 7 do
  begin
    var R := Residual(A, B, Q);
    if (R.Hi = 0.0d) and (R.Lo = 0.0d) then
      Exit(Q);
    var Up := PositiveDD(R) = (B > 0.0d);
    var N: Double := StepDouble(Q, Up);
    var RN := Residual(A, B, N);
    if (RN.Hi = 0.0d) and (RN.Lo = 0.0d) then
      Exit(N);
    if (PositiveDD(RN) = (B > 0.0d)) <> Up then
    begin
      if DrawParam(Ctx, 55) = 3 then
        Exit(if Abs(Q) < Abs(N) then Q else N);
      var AR := AbsDD(R);
      var AN := AbsDD(RN);
      if (AR.Hi < AN.Hi) or ((AR.Hi = AN.Hi) and (AR.Lo < AN.Lo)) then
        Exit(Q);
      if (AR.Hi > AN.Hi) or ((AR.Hi = AN.Hi) and (AR.Lo > AN.Lo)) then
        Exit(N);
      Exit(if (Cardinal(DoubleToBits(Q)) and 1) = 0 then Q else N);
    end;
    Q := N;
  end;
  Result := Q;
end;

function Interpolate(var Ctx: TPS2PixelContext; W0, W1, W2, A, B, C: Double): Double;
begin
  Result := AddD(Ctx, AddD(Ctx, MulD(Ctx, W0, A), MulD(Ctx, W1, B)), MulD(Ctx, W2, C));
end;

function Rounded(var Ctx: TPS2PixelContext; V: Double): Integer;
begin
  Result := Integer(Cardinal(DoubleToBits(AddD(Ctx, V, 6755399441055744.0d))));
end;

function DepthValue(var Ctx: TPS2PixelContext; V: Double): Cardinal;
begin
  V := Clamp(V, 0.0d, 4294967295.0d);
  // Preserve the CPU accumulator's four-decimal Currency quantization.
  var Scaled: Double := MulD(Ctx, V, 10000.0d);
  var IntegerValue: Double := SubD(Ctx, AddD(Ctx, Scaled, 6755399441055744.0d), 6755399441055744.0d);
  var R := Cardinal(IntegerValue / 10000.0d);
  var Remainder: Double := IntegerValue - Double(R) * 10000.0d;
  if Remainder < 0.0d then
    Dec(R)
  else if Remainder >= 10000.0d then
    Inc(R);
  Result := R;
end;

function TextureCoordinate(V: Double): Integer;
begin
  if not (V > -16777216.0d) then
    Exit(-16777216);
  if V > 16777216.0d then
    Exit(16777216);
  Result := Integer(V);
end;

function SingleBits(var Ctx: TPS2PixelContext; Q: Double): Cardinal;
begin
  if not (Q > 0.0d) then
    Exit(0);
  var Bits := SingleToBits(Single(Q));
  if DrawParam(Ctx, 55) = 3 then
  begin
    if (Bits > 0) and (Double(BitsToSingle(Bits)) > Q) then
      Dec(Bits)
    else if (Bits < $7F7FFFFF) and (Double(BitsToSingle(Bits + 1)) <= Q) then
      Inc(Bits);
    Exit(Bits);
  end;
  var Lo := Bits;
  var Hi := Bits;
  if Double(BitsToSingle(Bits)) <= Q then
    Hi := Bits + 1
  else
    Lo := Bits - 1;
  var DL: Double := Q - Double(BitsToSingle(Lo));
  var DH: Double := Double(BitsToSingle(Hi)) - Q;
  if DL < DH then
    Exit(Lo);
  if DH < DL then
    Exit(Hi);
  Result := if (Lo and 1) = 0 then Lo else Hi;
end;

function LodCode(var Ctx: TPS2PixelContext; Q: Double): Cardinal;
begin
  var Bits := SingleBits(Ctx, Q);
  var Base := DrawParam(Ctx, 79);
  var Lo := 0;
  var Hi := Integer(LodTables[Base]) - 1;
  while Lo < Hi do
  begin
    var Middle := ArithmeticShiftRight(Lo + Hi + 1, 1);
    if LodTables[Base + 1 + Cardinal(Middle) * 2] <= Bits then
      Lo := Middle
    else
      Hi := Middle - 1;
  end;
  Result := LodTables[Base + 2 + Cardinal(Lo) * 2];
end;

function VF(var Ctx: TPS2PixelContext; Vertex, Field: Cardinal): Double;
begin
  var Raw := DrawParam(Ctx, 80 + Vertex * 16 + Field);
  if Field >= 10 then
    Exit(Double(BitsToSingle(Raw)));
  if (Field = 0) or (Field = 1) or (Field = 8) or (Field = 9) then
    Exit(Double(Integer(Raw)));
  Result := Double(Raw);
end;

function Estimate(W: Single3; A, B, C: Single; out Error: Single): Single;
begin
  var T0: Single := W.X * A;
  var T1: Single := W.Y * B;
  var T2: Single := W.Z * C;
  Error := (Abs(T0) + Abs(T1) + Abs(T2)) * (1.0 / 1048576.0) + 1e-37;
  Result := (T0 + T1) + T2;
end;

function RoundedEstimate(var Ctx: TPS2PixelContext; V, Error: Single; out R: Integer): Boolean;
begin
  R := 0;
  if not (Abs(V) < 1048576.0) or not (Error < 0.25) then
    Exit(False);
  var F: Single := FloorFloat(V);
  var Fraction: Single := V - F;
  if DrawParam(Ctx, 55) = 3 then
  begin
    if (Fraction > Error) and (1.0 - Fraction > Error) then
    begin
      R := Integer(F);
      Exit(True);
    end;
    Exit(False);
  end;
  if Fraction - 0.5 > Error then
  begin
    R := Integer(F) + 1;
    Exit(True);
  end;
  if 0.5 - Fraction > Error then
  begin
    R := Integer(F);
    Exit(True);
  end;
  Result := False;
end;

function TruncEstimate(V, Error: Single; out R: Integer): Boolean;
begin
  R := 0;
  if not (Abs(V) < 1048576.0) or not (Error < 0.25) then
    Exit(False);
  var M: Single := Abs(V);
  var F: Single := FloorFloat(M);
  if F = 0.0 then
    Exit(M + Error < 1.0);
  if (M - F > Error) and (F + 1.0 - M > Error) then
  begin
    R := if V < 0.0 then -Integer(F) else Integer(F);
    Exit(True);
  end;
  Result := False;
end;

function VS(var Ctx: TPS2PixelContext; Vertex, Field: Cardinal): Single;
begin
  var Raw := DrawParam(Ctx, 80 + Vertex * 16 + Field);
  if Field >= 10 then
    Exit(BitsToSingle(Raw));
  if (Field = 8) or (Field = 9) then
    Exit(Single(Integer(Raw)));
  Result := Single(Raw);
end;

function Colour(var Ctx: TPS2PixelContext; W: Single3; W0, W1, W2: Double; I0, I1, Field: Cardinal): Integer;
begin
  if (DrawParam(Ctx, 80 + I0 * 16 + Field) < 65536) and
    (DrawParam(Ctx, 80 + I1 * 16 + Field) < 65536) and (DrawParam(Ctx, 112 + Field) < 65536) then
  begin
    var Error: Single;
    var R: Integer;
    var Guess: Single := Estimate(W, VS(Ctx, I0, Field), VS(Ctx, I1, Field), VS(Ctx, 2, Field), Error);
    if RoundedEstimate(Ctx, Guess, Error, R) then
      Exit(R);
  end;
  Result := Rounded(Ctx, Interpolate(Ctx, W0, W1, W2, VF(Ctx, I0, Field), VF(Ctx, I1, Field), VF(Ctx, 2, Field)));
end;

function PerspectiveEstimate(var Ctx: TPS2PixelContext; W: Single3; Field: Cardinal;
  Q, EQ, Scale: Single; out R: Integer): Boolean;
begin
  R := 0;
  if not (Abs(Q) > 4.0 * EQ) or not (Abs(Q) > 1e-30) or not (Abs(Q) < 1e30) then
    Exit(False);
  var ES: Single;
  var S: Single := Estimate(W, VS(Ctx, 0, Field), VS(Ctx, 1, Field), VS(Ctx, 2, Field), ES);
  var T: Single := S / Q;
  var ET: Single := ((ES + Abs(T) * EQ) / (Abs(Q) - EQ) + Abs(T) * (1.0 / 1048576.0)) * 1.001;
  Result := TruncEstimate(T * Scale, ET * Scale, R);
end;

function TriangleCover(var Ctx: TPS2PixelContext; XY: Integer2; out Z: Cardinal;
  out W0, W1, W2: Double): Boolean;
begin
  Z := 0;
  W0 := 0.0d;
  W1 := 0.0d;
  W2 := 0.0d;
  if (XY.X < Integer(DrawParam(Ctx, 60))) or (XY.Y < Integer(DrawParam(Ctx, 61))) or
    (XY.X >= Integer(DrawParam(Ctx, 62))) or (XY.Y >= Integer(DrawParam(Ctx, 63))) then
    Exit(False);
  var X := Int64(XY.X * 16);
  var Y := Int64(XY.Y * 16);
  var X0 := Int64(Integer(DrawParam(Ctx, 80)));
  var Y0 := Int64(Integer(DrawParam(Ctx, 81)));
  var X1 := Int64(Integer(DrawParam(Ctx, 96)));
  var Y1 := Int64(Integer(DrawParam(Ctx, 97)));
  var X2 := Int64(Integer(DrawParam(Ctx, 112)));
  var Y2 := Int64(Integer(DrawParam(Ctx, 113)));
  var S := Int64(Integer(DrawParam(Ctx, 58)));
  var A0 := (Y1 - Y2) * S;
  var B0 := (X2 - X1) * S;
  var A1 := (Y2 - Y0) * S;
  var B1 := (X0 - X2) * S;
  var A2 := (Y0 - Y1) * S;
  var B2 := (X1 - X0) * S;
  var E0 := A0 * (X - X1) + B0 * (Y - Y1);
  var E1 := A1 * (X - X2) + B1 * (Y - Y2);
  var E2 := A2 * (X - X0) + B2 * (Y - Y0);
  var Bias0: Int64 := if (A0 > 0) or ((A0 = 0) and (B0 > 0)) then 0 else -1;
  var Bias1: Int64 := if (A1 > 0) or ((A1 = 0) and (B1 > 0)) then 0 else -1;
  var Bias2: Int64 := if (A2 > 0) or ((A2 = 0) and (B2 > 0)) then 0 else -1;
  if (E0 + Bias0 < 0) or (E1 + Bias1 < 0) or (E2 + Bias2 < 0) then
    Exit(False);
  var Sign: Double := Double(S);
  var Inverse: Double := PackDouble(DrawParam(Ctx, 56), DrawParam(Ctx, 57));
  W0 := MulD(Ctx, Double(E0) * Sign, Inverse);
  W1 := MulD(Ctx, Double(E1) * Sign, Inverse);
  W2 := SubD(Ctx, SubD(Ctx, 1.0d, W0), W1);
  Z := if DrawParam(Ctx, 59) <> 0 then
    DepthValue(Ctx, Interpolate(Ctx, W0, W1, W2, VF(Ctx, 0, 2), VF(Ctx, 1, 2), VF(Ctx, 2, 2))) else Cardinal(0);
  Result := True;
end;

function TriangleColor(var Ctx: TPS2PixelContext; W0, W1, W2: Double): Cardinal;
begin
  var W: Single3 := Single3(Single(W0), Single(W1), Single(W2));
  var I0: Cardinal := if DrawParam(Ctx, 54) <> 0 then 0 else 2;
  var I1: Cardinal := if DrawParam(Ctx, 54) <> 0 then 1 else 2;
  var C := Integer3(Colour(Ctx, W, W0, W1, W2, I0, I1, 3),
    Colour(Ctx, W, W0, W1, W2, I0, I1, 4), Colour(Ctx, W, W0, W1, W2, I0, I1, 5));
  var A := Colour(Ctx, W, W0, W1, W2, I0, I1, 6);
  var Fog := if DrawParam(Ctx, 22) <> 0 then Colour(Ctx, W, W0, W1, W2, 0, 1, 7) else 0;
  var U := 0;
  var V := 0;
  var Mip := DrawParam(Ctx, 52);
  if DrawParam(Ctx, 47) <> 0 then
    if DrawParam(Ctx, 53) <> 0 then
    begin
      var Error: Single;
      var Guess: Single := Estimate(W, VS(Ctx, 0, 8), VS(Ctx, 1, 8), VS(Ctx, 2, 8), Error);
      if not TruncEstimate(Guess, Error, U) then
        U := TextureCoordinate(Interpolate(Ctx, W0, W1, W2, VF(Ctx, 0, 8), VF(Ctx, 1, 8), VF(Ctx, 2, 8)));
      Guess := Estimate(W, VS(Ctx, 0, 9), VS(Ctx, 1, 9), VS(Ctx, 2, 9), Error);
      if not TruncEstimate(Guess, Error, V) then
        V := TextureCoordinate(Interpolate(Ctx, W0, W1, W2, VF(Ctx, 0, 9), VF(Ctx, 1, 9), VF(Ctx, 2, 9)));
    end
    else
    begin
      var QX: Double := 0.0d;
      var EQ: Single;
      var QE: Single := Estimate(W, VS(Ctx, 0, 12), VS(Ctx, 1, 12), VS(Ctx, 2, 12), EQ);
      if DrawParam(Ctx, 78) <> 0 then
      begin
        QX := Interpolate(Ctx, W0, W1, W2, VF(Ctx, 0, 12), VF(Ctx, 1, 12), VF(Ctx, 2, 12));
        Mip := LodCode(Ctx, QX);
      end;
      if not PerspectiveEstimate(Ctx, W, 10, QE, EQ, Single(DrawParam(Ctx, 35)) * 16.0, U) or
        not PerspectiveEstimate(Ctx, W, 11, QE, EQ, Single(DrawParam(Ctx, 36)) * 16.0, V) then
      begin
        var Q: Double := if DrawParam(Ctx, 78) <> 0 then QX else
          Interpolate(Ctx, W0, W1, W2, VF(Ctx, 0, 12), VF(Ctx, 1, 12), VF(Ctx, 2, 12));
        if Q = 0.0d then
          Q := 1.0d;
        U := TextureCoordinate(MulD(Ctx, DivD(Ctx, Interpolate(Ctx, W0, W1, W2,
          VF(Ctx, 0, 10), VF(Ctx, 1, 10), VF(Ctx, 2, 10)), Q), Double(DrawParam(Ctx, 35)) * 16.0d));
        V := TextureCoordinate(MulD(Ctx, DivD(Ctx, Interpolate(Ctx, W0, W1, W2,
          VF(Ctx, 0, 11), VF(Ctx, 1, 11), VF(Ctx, 2, 11)), Q), Double(DrawParam(Ctx, 36)) * 16.0d));
      end;
    end;
  C := Clamp(C, Integer3(0), Integer3(255));
  A := Clamp(A, 0, 255);
  SourceColor(Ctx, C, A, Clamp(Fog, 0, 255), U, V, Mip);
  Result := Cardinal(C.R) or (Cardinal(C.G) shl 8) or (Cardinal(C.B) shl 16) or (Cardinal(A) shl 24);
end;

function SpriteCover(var Ctx: TPS2PixelContext; XY: Integer2): Boolean;
begin
  Result := not ((XY.X < Integer(DrawParam(Ctx, 60))) or (XY.Y < Integer(DrawParam(Ctx, 61))) or
    (XY.X >= Integer(DrawParam(Ctx, 62))) or (XY.Y >= Integer(DrawParam(Ctx, 63))));
end;

function SpriteColor(var Ctx: TPS2PixelContext; XY: Integer2): Cardinal;
begin
  var U := 0;
  var V := 0;
  if DrawParam(Ctx, 47) <> 0 then
  begin
    U := Coordinates[Ctx.DrawIndex * 4096 + Cardinal(XY.X - Integer(DrawParam(Ctx, 60)))];
    V := Coordinates[Ctx.DrawIndex * 4096 + 2048 + Cardinal(XY.Y - Integer(DrawParam(Ctx, 61)))];
  end;
  var C := Integer3(Integer(DrawParam(Ctx, 26)), Integer(DrawParam(Ctx, 27)), Integer(DrawParam(Ctx, 28)));
  var A := Integer(DrawParam(Ctx, 29));
  SourceColor(Ctx, C, A, Integer(DrawParam(Ctx, 30)), U, V, DrawParam(Ctx, 52));
  Result := Cardinal(C.R) or (Cardinal(C.G) shl 8) or (Cardinal(C.B) shl 16) or (Cardinal(A) shl 24);
end;

function Cover(var Ctx: TPS2PixelContext; XY: Integer2; out Z: Cardinal;
  out W0, W1, W2: Double): Boolean;
begin
  if DrawParam(Ctx, 58) = 0 then
  begin
    W0 := 0.0d;
    W1 := 0.0d;
    W2 := 0.0d;
    Z := DrawParam(Ctx, 31);
    Exit(SpriteCover(Ctx, XY));
  end;
  Result := TriangleCover(Ctx, XY, Z, W0, W1, W2);
end;

function CoveredColor(var Ctx: TPS2PixelContext; XY: Integer2; W0, W1, W2: Double): Cardinal;
begin
  Result := if DrawParam(Ctx, 58) = 0 then SpriteColor(Ctx, XY) else TriangleColor(Ctx, W0, W1, W2);
end;
