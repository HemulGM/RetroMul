// Native palette metrics are shared by all occurrences of each colour.
type
  THybrid = record
    W, H, Indices, Palette, Premul, Distances, Count, Shares, OutputAt, Pass: Cardinal;
  end;
var
  [PushConstant]
  PC: THybrid;
  [Binding(0, 0), ReadOnly]
  Source: array of Cardinal;
  [Binding(0, 1)]
  Corners: array of Cardinal;
  [Binding(0, 2), WriteOnly]
  Pixels: array of Cardinal;

function IndexAt(X, Y: Integer): Cardinal;
begin
  var N := Cardinal(Clamp(Y, 0, Integer(PC.H) - 1)) * PC.W + Cardinal(Clamp(X, 0, Integer(PC.W) - 1));
  Result := (Source[PC.Indices + (N shr 2)] shr ((N and 3) * 8)) and 255;
end;

function Key(I: Cardinal): Cardinal;
begin
  var C := Source[PC.Palette + I];
  Result :=
    if (C shr 24) = 0 then
      Cardinal(0)
    else
      C;
end;

function Dist(A, B: Cardinal): Single;
begin
  Result := BitsToSingle(Source[PC.Distances + A * PC.Count + B]);
end;

function Corner(X, Y: Integer): Cardinal;
begin
  var F := IndexAt(X, Y);
  var G := IndexAt(X + 1, Y);
  var J := IndexAt(X, Y + 1);
  var K := IndexAt(X + 1, Y + 1);
  var KF := Key(F);
  var KG := Key(G);
  var KJ := Key(J);
  var KK := Key(K);
  if ((KF = KG) and (KJ = KK)) or ((KF = KJ) and (KG = KK)) then
    Exit(0);
  var JG: Single := Dist(IndexAt(X - 1, Y + 1), F) + Dist(F, IndexAt(X + 1, Y - 1));
  JG := JG + Dist(IndexAt(X, Y + 2), K);
  JG := JG + Dist(K, IndexAt(X + 2, Y));
  JG := JG + 4.0 * Dist(J, G);
  var FK: Single := Dist(IndexAt(X - 1, Y), J) + Dist(J, IndexAt(X + 1, Y + 2));
  FK := FK + Dist(IndexAt(X, Y - 1), G);
  FK := FK + Dist(G, IndexAt(X + 2, Y + 1));
  FK := FK + 4.0 * Dist(F, K);
  // The native thresholds are binary32 constants widened for comparison.
  var Dom: Double := Double(BitsToSingle(Cardinal($40666666)));
  var B: Cardinal := 0;
  if JG < FK then
  begin
    var T := Cardinal(1) + Cardinal(Ord(Dom * Double(JG) < Double(FK)));
    if (KF <> KG) and (KF <> KJ) then
      B := B or T;
    if (KK <> KG) and (KK <> KJ) then
      B := B or (T shl 2);
  end
  else if FK < JG then
  begin
    var T := Cardinal(1) + Cardinal(Ord(Dom * Double(FK) < Double(JG)));
    if (KJ <> KF) and (KJ <> KK) then
      B := B or (T shl 4);
    if (KG <> KF) and (KG <> KK) then
      B := B or (T shl 6);
  end;
  Result := B;
end;

function Premult(X, Y: Integer): Single4;
begin
  var P := PC.Premul + IndexAt(X, Y) * 4;
  Result :=
    Single4(
      BitsToSingle(Source[P]),
      BitsToSingle(Source[P + 1]),
      BitsToSingle(Source[P + 2]),
      BitsToSingle(Source[P + 3])
    );
end;

function Tap(Phase: Cardinal): Single4;
begin
  if Phase = 0 then
    Exit(Single4(-0.0234375, 0.2265625, 0.8671875, -0.0703125));
  Result := Single4(-0.0703125, 0.8671875, 0.2265625, -0.0234375);
end;

function Row(X, Y: Integer; Phase: Cardinal): Single4;
begin
  var Left := X - 2 + Integer(Phase);
  var T: Single4 := Tap(Phase);
  var S: Single4 := Premult(Left, Y) * T.X;
  S := S + Premult(Left + 1, Y) * T.Y;
  S := S + Premult(Left + 2, Y) * T.Z;
  Result := S + Premult(Left + 3, Y) * T.W;
end;

// Two dyadic 1/128 filters leave interpolated byte alpha exactly K/16384.
// Form the CPU's rounded binary64 reciprocal with a remainder and tie test.
function Reciprocal(K: Cardinal): Double;
begin
  if K = 4177920 then
    Exit(Double(1));
  var E := 21 - FindMSB(K);
  var Num := UInt64(4177920);
  var Den := UInt64(K);
  if E >= 0 then
    Den := Den shl Cardinal(E)
  else
    Num := Num shl Cardinal(-E);
  if Num < Den then
  begin
    Num := Num shl 1;
    E := E - 1;
  end;
  var R: UInt64 := (Num - Den) shl 26;
  var Hi := R div Den;
  R := (R - Hi * Den) shl 26;
  var Lo := R div Den;
  R := R - Lo * Den;
  var M: UInt64 := (UInt64(1) shl 52) + (Hi shl 26) + Lo;
  if ((R shl 1) > Den) or (((R shl 1) = Den) and ((M and UInt64(1)) <> UInt64(0))) then
    M := M + UInt64(1);
  if M = (UInt64(1) shl 53) then
  begin
    E := E + 1;
    M := UInt64(1) shl 52;
  end;
  Result := BitsToDouble((UInt64(1023 + E) shl 52) or (M - (UInt64(1) shl 52)));
end;

function Channel(V: Single): Cardinal;
begin
  Result := Cardinal(RoundEven(Clamp(V, 0.0, 255.0)));
end;

function Cubic(X, Y: Integer; OX, OY, Centre: Cardinal): Cardinal;
begin
  var Top := Y - 2 + Integer(OY);
  var T: Single4 := Tap(OY);
  var C: Single4 := Row(X, Top, OX) * T.X;
  C := C + Row(X, Top + 1, OX) * T.Y;
  C := C + Row(X, Top + 2, OX) * T.Z;
  C := C + Row(X, Top + 3, OX) * T.W;
  if C.A < 0.5 then
    Exit(Centre and $FFFFFF);
  var Inv: Double := Reciprocal(Cardinal(C.A * 16384.0));
  Result :=
    Channel(Single(Double(C.R) * Inv))
      or (Channel(Single(Double(C.G) * Inv)) shl 8)
      or (Channel(Single(Double(C.B) * Inv)) shl 16)
      or (Channel(C.A) shl 24);
end;

function MixColour(D, S, W: Cardinal): Cardinal;
begin
  if W >= 256 then
    Exit(S);
  if W = 0 then
    Exit(D);
  var WD := 256 - W;
  var DA := D shr 24;
  var SA := S shr 24;
  var NA := DA * WD + SA * W;
  var O := ((NA + 128) shr 8) shl 24;
  for var K := 0 to 2 do
  begin
    var Shift := Cardinal(K * 8);
    var DC := (D shr Shift) and 255;
    var SC := (S shr Shift) and 255;
    var C :=
      if NA = 0 then
        (DC * WD + SC * W + 128)
        shr 8
        else
          (DC * DA * WD + SC * SA * W + NA div 2)
        div NA;
    O := O or (Min(C, Cardinal(255)) shl Shift);
  end;
  Result := O;
end;

function FilterAt(X, Y: Integer; OX, OY: Cardinal): Cardinal;
begin
  var E := IndexAt(X, Y);
  var C := Source[PC.Palette + E];
  var Edge := False;
  for var J := -1 to 1 do
    for var I := -1 to 1 do
      if ((I <> 0) or (J <> 0)) and (Dist(E, IndexAt(X + I, Y + J)) >= 40.0) then
        Edge := True;
  if not Edge then
    Exit(Cubic(X, Y, OX, OY, C));
  var Pitch := PC.W + 1;
  var At := Cardinal(Y) * Pitch + Cardinal(X);
  var Types :=
    ((Corners[At] shr 2) and 3)
      or (((Corners[At + 1] shr 4) and 3) shl 2)
      or (((Corners[At + Pitch] shr 6) and 3) shl 4)
      or ((Corners[At + Pitch + 1] and 3) shl 6);
  for var R := 0 to 3 do
  begin
    var Kind := (Types shr Cardinal(2 * R)) and 3;
    if Kind <> 0 then
    begin
      var SX := 2 * (R and 1) - 1;
      var SY := (R and 2) - 1;
      var EB := IndexAt(X, Y - SY);
      var EC := IndexAt(X + SX, Y - SY);
      var ED := IndexAt(X - SX, Y);
      var EF := IndexAt(X + SX, Y);
      var EG := IndexAt(X - SX, Y + SY);
      var EH := IndexAt(X, Y + SY);
      var EI := IndexAt(X + SX, Y + SY);
      var TR := (Types shr Cardinal(2 * ((R and 1) or (2 - (R and 2))))) and 3;
      var BL := (Types shr Cardinal(2 * ((1 - (R and 1)) or (R and 2)))) and 3;
      var Line := True;
      if Kind <> 2 then
      begin
        if (TR <> 0) and (Dist(E, EG) >= 30.0) then
          Line := False
        else if (BL <> 0) and (Dist(E, EC) >= 30.0) then
          Line := False
        else if (Dist(E, EI) >= 30.0)
          and (Dist(EG, EH) < 30.0)
          and (Dist(EH, EI) < 30.0)
          and (Dist(EI, EF) < 30.0)
          and (Dist(EF, EC) < 30.0) then
          Line := False;
      end;
      var S :=
        if Dist(E, EF) <= Dist(E, EH) then
          EF
        else
          EH;
      var Shape: Cardinal := 0;
      if Line then
      begin
        var FG: Single := Dist(EF, EG);
        var HC: Single := Dist(EH, EC);
        var Ratio: Double := Double(BitsToSingle(Cardinal($400CCCCD)));
        var Shallow := (Ratio * Double(FG) <= Double(HC)) and (Key(E) <> Key(EG)) and (Key(ED) <> Key(EG));
        var Steep := (Ratio * Double(HC) <= Double(FG)) and (Key(E) <> Key(EC)) and (Key(EB) <> Key(EC));
        Shape :=
          if Shallow then
            (if Steep then Cardinal(4)
          else
            Cardinal(2))
          else
            (if Steep then Cardinal(3)
          else
            Cardinal(1));
      end;
      var U :=
        if SX < 0 then
          1
          - OX
          else
            OX;
      var V :=
        if SY < 0 then
          1
          - OY
          else
            OY;
      C := MixColour(C, Source[PC.Palette + S], Source[PC.Shares + Shape * 4 + V * 2 + U]);
    end;
  end;
  Result := C;
end;

[Vulkan12, StrictFloat, LocalSize(8, 8, 1)]
procedure Main;
begin
  var Q := GlobalInvocationID.XY;
  if PC.Pass = 0 then
  begin
    if (Q.X <= PC.W) and (Q.Y <= PC.H) then
      Corners[Q.Y * (PC.W + 1) + Q.X] := Corner(Integer(Q.X) - 1, Integer(Q.Y) - 1);
  end
  else if (Q.X < PC.W * 2) and (Q.Y < PC.H * 2) then
    Pixels[PC.OutputAt + Q.Y * PC.W * 2 + Q.X] :=
      FilterAt(Integer(Q.X shr 1), Integer(Q.Y shr 1), Q.X and 1, Q.Y and 1);
end;
