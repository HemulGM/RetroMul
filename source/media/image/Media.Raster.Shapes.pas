unit Media.Raster.Shapes;

interface

type
  // Opaque spans, already intersected with the caller's clip. Right is exclusive.
  TRasterSpan = reference to procedure(Y, Left, Right: Integer);

  TShapeRasterizer = record
  private
    FLeft, FTop, FRight, FBottom: Integer;
    FSpan: TRasterSpan;
    procedure Span(Y, Left, Right: Int64);
    procedure Point(X, Y, OriginX, OriginY, Width, Height: Int64; Dotted: Boolean);
  public
    procedure Init(Left, Top, Right, Bottom: Integer; const Output: TRasterSpan);
    procedure Arc(X, Y: Int64; Width, Height: Integer; StartAngle, ArcAngle: Integer; Filled, Dotted: Boolean);
    procedure RoundRect(X, Y: Int64; Width, Height: Integer; ArcWidth, ArcHeight: Integer; Filled, Dotted: Boolean);
  end;

implementation

uses
  System.Math;

{$Q-}{$R-}

type
  TProduct128 = record
    Hi, Lo: UInt64;
  end;

  TArcRange = record
    Start, Sweep: Integer;
    SX, SY, EX, EY: Int64;
    Full: Boolean;
    procedure Init(StartAngle, Extent: Integer);
    function Contains(NX, NY: Int64; IncludeEnd: Boolean): Boolean;
    function IncludesAngle(Angle: Integer): Boolean;
  end;

// Q60 sin(0..90 degrees), rounded with 90-digit decimal arithmetic. Keeping the
// table integer also makes cardinal/diagonal rays exact and all targets agree.
const
  Sines: array[0..90] of Int64 = (
    0, 20121254688683129, 40236380248269115, 60339249416652910,
    80423738665144958, 100483730063757353, 120513113144784577, 140505786764111158,
    160455660959679271, 180356658806550176, 200202718267994420, 219987794042046953,
    239705859402964666, 259350908037025434, 278916955872109463, 298398042900505626,
    317788234994387546, 337081625713406416, 356272338103849953, 375354526488819420,
    394322378248879447, 413170115592638214, 431891997316718680, 450482320554584749,
    468935422513689663, 487245682200417466, 505407522132292112, 523415410036932657,
    541263860537237022, 558947436822280990, 576460752303423488, 593798472255113663,
    610955315439899965, 627926055717146238, 644705523634964778, 661288608004881463,
    677670257458753271, 693845481987463950, 709809354460929138, 725557012128947911,
    741083658102443606, 756384562814642698, 771455065461746661, 786290575422657948,
    800886573657327654, 815238614083298888, 829342324930026563, 843193410070561051,
    856787650330190070, 870120904771640173, 883189111956446361, 895988291182105575,
    908514543694637246, 920764053876181524, 932733090407273441, 944418007403438966,
    955815245525766734, 966921333065117160, 977732886999638672, 988246614025268939,
    998459311558907194, 1008367868713952068, 1017969267247907787, 1027260582481770070,
    1036238984190911692, 1044901737467196319, 1053246203552058017, 1061269840640292681,
    1068970204654316517, 1076344949988655751, 1083391830224440781, 1090108698813687127,
    1096493509733154735, 1102544318107586485, 1108259280802136027, 1113636656983804515,
    1118674808651715199, 1123372201136064364, 1127727403565596613, 1131739089303462118,
    1135406036351323053, 1138727127721586125, 1141701351777647818, 1144327802542048700,
    1146605679972442934, 1148534290205298929, 1150113045767256890, 1151341465754078895,
    1152219175977136987, 1152745909077394653, 1152921504606846976
  );

function Multiply128(A, B: UInt64): TProduct128;
const
  Mask: UInt64 = $FFFFFFFF;
begin
  var P0 := (A and Mask) * (B and Mask);
  var P1 := (A shr 32) * (B and Mask);
  var P2 := (A and Mask) * (B shr 32);
  var Middle := (P0 shr 32) + (P1 and Mask) + (P2 and Mask);
  Result.Lo := (P0 and Mask) or (Middle shl 32);
  Result.Hi := (A shr 32) * (B shr 32) + (P1 shr 32) + (P2 shr 32) + (Middle shr 32);
end;

function Compare128(const A, B: TProduct128): Integer;
begin
  if A.Hi < B.Hi then
    Exit(-1);
  if A.Hi > B.Hi then
    Exit(1);
  if A.Lo < B.Lo then
    Exit(-1);
  if A.Lo > B.Lo then
    Exit(1);
  Result := 0;
end;

function Magnitude(Value: Int64): UInt64;
begin
  Result := UInt64(Value);
  if Value < 0 then
    Result := UInt64(0) - Result;
end;

function CompareProducts(A, B, C, D: Int64): Integer;
begin
  var NegativeAB := ((A < 0) xor (B < 0)) and (A <> 0) and (B <> 0);
  var NegativeCD := ((C < 0) xor (D < 0)) and (C <> 0) and (D <> 0);
  if NegativeAB <> NegativeCD then
  begin
    if NegativeAB then
      Exit(-1)
    else
      Exit(1);
  end;
  Result := Compare128(Multiply128(Magnitude(A), Magnitude(B)), Multiply128(Magnitude(C), Magnitude(D)));
  if NegativeAB then
    Result := -Result;
end;

function Normalize(Angle: Int64): Integer;
begin
  Result := Integer(Angle mod 360);
  if Result < 0 then
    Inc(Result, 360);
end;

procedure Direction(Angle: Integer; out X, Y: Int64);
begin
  var A := Angle mod 90;
  var S := Sines[A];
  var C := Sines[90 - A];
  case Angle div 90 of
    0:
      begin
        X := C;
        Y := S;
      end;
    1:
      begin
        X := -S;
        Y := C;
      end;
    2:
      begin
        X := -C;
        Y := -S;
      end;
  else
    X := S;
    Y := -C;
  end;
end;

procedure TArcRange.Init(StartAngle, Extent: Integer);
begin
  var Count := Int64(Extent);
  var First := Int64(StartAngle);
  if Count < 0 then
  begin
    Inc(First, Count);
    Count := -Count;
  end;
  Full := Count >= 360;
  Sweep := Integer(Min(Int64(360), Count));
  Start := Normalize(First);
  Direction(Start, SX, SY);
  Direction(Normalize(Int64(Start) + Sweep), EX, EY);
end;

function TArcRange.Contains(NX, NY: Int64; IncludeEnd: Boolean): Boolean;
begin
  if Full then
    Exit(True);
  if Sweep = 0 then
    Exit(False);
  // Assign a central pixel to angle zero, so adjacent half-open pie wedges
  // partition the complete ellipse without a hole or duplicated central pixel.
  if (NX = 0) and (NY = 0) then
    NX := 1;
  var A := CompareProducts(SX, NY, SY, NX);
  if Sweep = 180 then
  begin
    if IncludeEnd then
      Exit(A >= 0);
    Exit((A > 0) or ((A = 0) and (CompareProducts(SX, NX, -SY, NY) > 0)));
  end;
  var B := CompareProducts(NX, EY, NY, EX);
  var EndOK := B > 0;
  if IncludeEnd then
    EndOK := B >= 0;
  if Sweep < 180 then
    Result := (A >= 0) and EndOK
  else
    Result := (A >= 0) or EndOK;
end;

function TArcRange.IncludesAngle(Angle: Integer): Boolean;
begin
  Result := Full or (Normalize(Int64(Angle) - Start) <= Sweep);
end;

// Right-hand outline coordinate relative to the ellipse's x origin, at DY2
// measured in doubled y coordinates. The approximate square root is only a
// starting point: exact 128-bit inequalities decide every resulting pixel.
function EllipseRight(Size, Axis: Int64; DY2: Int64): Int64;
var
  Denominator, Numerator: UInt64;
  Limit: TProduct128;

  function Fits(Value: Int64): Boolean;
  begin
    var Distance := Value * 2 - Size - 1;
    if Distance <= 0 then
      Exit(True);
    Result := Compare128(Multiply128(UInt64(Distance * Distance), Denominator), Limit) <= 0;
  end;

begin
  Denominator := UInt64(Axis * Axis);
  Numerator := Denominator - UInt64(DY2 * DY2);
  Limit := Multiply128(UInt64(Size * Size), Numerator);
  var Estimate: Double := Sqrt(Double(Size * Size) * Double(Numerator) / Double(Denominator));
  Result := EnsureRange(Floor((Double(Size + 1) + Estimate) * 0.5), Size div 2, Size);
  for var I := 1 to 2 do
  begin
    if not Fits(Result) then
      Dec(Result)
    else if (Result < Size) and Fits(Result + 1) then
      Inc(Result)
    else
      Exit;
  end;
  // A bounded fallback keeps the work finite even with an unusual host FP mode.
  var L := Size div 2;
  var R := Size;
  while L < R do
  begin
    var Middle := L + (R - L + 1) div 2;
    if Fits(Middle) then
      L := Middle
    else
      R := Middle - 1;
  end;
  Result := L;
end;

function Endpoint(Size, UnitValue: Int64): Int64;
begin
  var Base: TProduct128;
  Base.Hi := UInt64(Size + 1) shr 4;
  Base.Lo := UInt64(Size + 1) shl 60;
  var Product := Multiply128(UInt64(Size), Magnitude(UnitValue));
  var Previous := Base.Lo;
  if UnitValue < 0 then
  begin
    Dec(Base.Lo, Product.Lo);
    Dec(Base.Hi, Product.Hi + UInt64(Ord(Previous < Product.Lo)));
  end
  else
  begin
    Inc(Base.Lo, Product.Lo);
    Inc(Base.Hi, Product.Hi + UInt64(Ord(Base.Lo < Previous)));
  end;
  Result := Int64((Base.Lo shr 61) or (Base.Hi shl 3));
end;

procedure TShapeRasterizer.Init(Left, Top, Right, Bottom: Integer; const Output: TRasterSpan);
begin
  FLeft := Left;
  FTop := Top;
  FRight := Right;
  FBottom := Bottom;
  FSpan := Output;
end;

procedure TShapeRasterizer.Span(Y, Left, Right: Int64);
begin
  if (Y < FTop) or (Y >= FBottom) then
    Exit;
  Left := Max(Left, Int64(FLeft));
  Right := Min(Right, Int64(FRight));
  if Left < Right then
    FSpan(Integer(Y), Integer(Left), Integer(Right));
end;

procedure TShapeRasterizer.Point(X, Y, OriginX, OriginY, Width, Height: Int64; Dotted: Boolean);
begin
  if (X < FLeft) or (X >= FRight) or (Y < FTop) or (Y >= FBottom) then
    Exit;
  if Dotted then
  begin
    var DX := (X * 2 - OriginX * 2 - Width) * Height;
    var DY := (Y * 2 - OriginY * 2 - Height) * Width;
    var Phase := X - OriginX;
    if (Width = 0) or ((Height <> 0) and (Magnitude(DX) >= Magnitude(DY))) then
      Phase := Y - OriginY;
    if (Phase and 1) <> 0 then
      Exit;
  end;
  FSpan(Integer(Y), Integer(X), Integer(X + 1));
end;

procedure TShapeRasterizer.Arc(X, Y: Int64; Width, Height: Integer; StartAngle, ArcAngle: Integer; Filled, Dotted: Boolean);
var
  Range: TArcRange;
  CX2, CY2: Int64;

  procedure OutlinePoint(PX, PY: Int64);
  begin
    Point(PX, PY, X, Y, Width, Height, Dotted);
  end;

  procedure OutlineQuadrant(First, Last, Quadrant: Integer);
  begin
    var AX, AY, BX, BY: Int64;
    Direction(First mod 360, AX, AY);
    Direction(Last mod 360, BX, BY);
    var Y1 := Y + Endpoint(Height, -AY);
    var Y2 := Y + Endpoint(Height, -BY);
    var X1 := X + Endpoint(Width, AX);
    var X2 := X + Endpoint(Width, BX);
    for var Row := Max(Int64(FTop), Min(Y1, Y2)) to Min(Int64(FBottom) - 1, Max(Y1, Y2)) do
    begin
      var Right := EllipseRight(Width, Height, Row * 2 - CY2);
      var PX := X + Right;
      if (Quadrant = 1) or (Quadrant = 2) then
        PX := X + Width - Right;
      if (PX >= Min(X1, X2)) and (PX <= Max(X1, X2)) then
        OutlinePoint(PX, Row);
    end;
    for var Col := Max(Int64(FLeft), Min(X1, X2)) to Min(Int64(FRight) - 1, Max(X1, X2)) do
    begin
      var Bottom := EllipseRight(Height, Width, Col * 2 - CX2);
      var PY := Y + Bottom;
      if Quadrant < 2 then
        PY := Y + Height - Bottom;
      if (PY >= Min(Y1, Y2)) and (PY <= Max(Y1, Y2)) then
        OutlinePoint(Col, PY);
    end;
    OutlinePoint(X1, Y1);
    OutlinePoint(X2, Y2);
  end;

  procedure PieSpan(Row, L, R: Int64);
  var
    Cuts: array[0..9] of Int64;
    Count: Integer;

    function Side(PX: Int64; Ending: Boolean): Integer;
    begin
      var NX := (PX * 2 + 1 - CX2) * Height;
      var NY := (CY2 - Row * 2 - 1) * Width;
      if Ending then
        Result := CompareProducts(NX, Range.EY, NY, Range.EX)
      else
        Result := CompareProducts(Range.SX, NY, Range.SY, NX);
    end;

    procedure Cut(Value: Int64);
    begin
      if (Value > L) and (Value < R) then
      begin
        Cuts[Count] := Value;
        Inc(Count);
      end;
    end;

    procedure Boundary(Ending: Boolean);
    begin
      var First := Side(L, Ending);
      if First = Side(R - 1, Ending) then
        Exit;
      var Low := L;
      var High := R - 1;
      while Low < High do
      begin
        var Middle := Low + (High - Low) div 2;
        if Side(Middle, Ending) = First then
          Low := Middle + 1
        else
          High := Middle;
      end;
      Cut(Low);
      if Side(Low, Ending) = 0 then
        Cut(Low + 1);
    end;

  begin
    L := Max(L, Int64(FLeft));
    R := Min(R, Int64(FRight));
    if L >= R then
      Exit;
    if Range.Full then
    begin
      Span(Row, L, R);
      Exit;
    end;
    Count := 2;
    Cuts[0] := L;
    Cuts[1] := R;
    Boundary(False);
    Boundary(True);
    // Opposite horizontal rays have zero cross products along the central row;
    // split it at the center too, including the special central-pixel convention.
    Cut(X + Width div 2);
    Cut(X + (Int64(Width) + 1) div 2);
    for var I := 1 to Count - 1 do
    begin
      var Value := Cuts[I];
      var J := I;
      while (J > 0) and (Cuts[J - 1] > Value) do
      begin
        Cuts[J] := Cuts[J - 1];
        Dec(J);
      end;
      Cuts[J] := Value;
    end;
    for var I := 0 to Count - 2 do
      if Cuts[I] < Cuts[I + 1] then
        if Range.Contains((Cuts[I] * 2 + 1 - CX2) * Height, (CY2 - Row * 2 - 1) * Width, False) then
          Span(Row, Cuts[I], Cuts[I + 1]);
  end;

begin
  if (Width < 0) or (Height < 0) or (FLeft >= FRight) or (FTop >= FBottom) or (ArcAngle = 0) then
    Exit;
  if Filled and ((Width = 0) or (Height = 0)) then
    Exit;
  if (X >= FRight) or (Y >= FBottom) or (X + Width < FLeft) or (Y + Height < FTop) then
    Exit;
  Range.Init(StartAngle, ArcAngle);
  CX2 := X * 2 + Width;
  CY2 := Y * 2 + Height;
  if (Width = 0) or (Height = 0) then
  begin
    if (Width = 0) and (Height = 0) then
    begin
      Point(X, Y, X, Y, 0, 0, Dotted);
      Exit;
    end;
    if Width = 0 then
    begin
      var L := Y + Min(Endpoint(Height, -Range.SY), Endpoint(Height, -Range.EY));
      var R := Y + Max(Endpoint(Height, -Range.SY), Endpoint(Height, -Range.EY));
      if Range.IncludesAngle(90) then
        L := Y;
      if Range.IncludesAngle(270) then
        R := Y + Height;
      for var Row := Max(Int64(FTop), L) to Min(Int64(FBottom) - 1, R) do
        Point(X, Row, X, Y, 0, Height, Dotted);
    end
    else
    begin
      var L := X + Min(Endpoint(Width, Range.SX), Endpoint(Width, Range.EX));
      var R := X + Max(Endpoint(Width, Range.SX), Endpoint(Width, Range.EX));
      if Range.IncludesAngle(180) then
        L := X;
      if Range.IncludesAngle(0) then
        R := X + Width;
      for var Col := Max(Int64(FLeft), L) to Min(Int64(FRight) - 1, R) do
        Point(Col, Y, X, Y, Width, 0, Dotted);
    end;
    Exit;
  end;
  if Filled then
  begin
    for var Row := Max(Int64(FTop), Y) to Min(Int64(FBottom) - 1, Y + Height - 1) do
    begin
      var Right := EllipseRight(Width, Height, Row * 2 - CY2);
      PieSpan(Row, X + Width - Right, X + Right);
    end;
    Exit;
  end;
  // Split the parameter interval at quadrant boundaries. Filtering an already
  // rounded pixel by atan2 would cut very thin ellipses at the wrong position.
  var First := Range.Start;
  if Range.Full then
    First := 0;
  var Last := First + Range.Sweep;
  while First < Last do
  begin
    var Next := Min(Last, (First div 90 + 1) * 90);
    OutlineQuadrant(First, Next, (First div 90) mod 4);
    First := Next;
  end;
end;

procedure TShapeRasterizer.RoundRect(X, Y: Int64; Width, Height: Integer; ArcWidth, ArcHeight: Integer; Filled, Dotted: Boolean);

  procedure Horizontal(L, R, Row: Int64);
  begin
    if not Dotted then
      Span(Row, L, R + 1)
    else
      for var Col := Max(Int64(FLeft), L) to Min(Int64(FRight) - 1, R) do
        if ((Col - X) and 1) = 0 then
          Span(Row, Col, Col + 1);
  end;

  procedure Vertical(Col, T, B: Int64);
  begin
    for var Row := Max(Int64(FTop), T) to Min(Int64(FBottom) - 1, B) do
      if not Dotted or (((Row - Y) and 1) = 0) then
        Span(Row, Col, Col + 1);
  end;

begin
  if (Width < 0) or (Height < 0) or (FLeft >= FRight) or (FTop >= FBottom) then
    Exit;
  if Filled and ((Width = 0) or (Height = 0)) then
    Exit;
  if (X >= FRight) or (Y >= FBottom) or (X + Width < FLeft) or (Y + Height < FTop) then
    Exit;
  var AW := Integer(Min(Int64(Width), Int64(Magnitude(ArcWidth))));
  var AH := Integer(Min(Int64(Height), Int64(Magnitude(ArcHeight))));
  if Filled then
  begin
    for var Row := Max(Int64(FTop), Y) to Min(Int64(FBottom) - 1, Y + Height - 1) do
    begin
      var Inset: Int64 := 0;
      if (AW > 0) and (AH > 0) then
      begin
        var LocalY := Row - Y;
        if LocalY * 2 < Int64(AH) then
          Inset := AW - EllipseRight(AW, AH, LocalY * 2 - AH)
        else if (Int64(Height) - LocalY) * 2 < AH then
          Inset := AW - EllipseRight(AW, AH, (LocalY - Height + AH) * 2 - AH);
      end;
      Span(Row, X + Inset, X + Width - Inset);
    end;
    Exit;
  end;
  if (AW = 0) or (AH = 0) then
  begin
    Horizontal(X, X + Width, Y);
    Horizontal(X, X + Width, Y + Height);
    Vertical(X, Y, Y + Height);
    Vertical(X + Width, Y, Y + Height);
    Exit;
  end;
  Horizontal(X + AW div 2, X + Width - AW div 2, Y);
  Horizontal(X + AW div 2, X + Width - AW div 2, Y + Height);
  Vertical(X, Y + AH div 2, Y + Height - AH div 2);
  Vertical(X + Width, Y + AH div 2, Y + Height - AH div 2);
  Arc(X, Y, AW, AH, 90, 90, False, Dotted);
  Arc(X + Width - AW, Y, AW, AH, 0, 90, False, Dotted);
  Arc(X, Y + Height - AH, AW, AH, 180, 90, False, Dotted);
  Arc(X + Width - AW, Y + Height - AH, AW, AH, 270, 90, False, Dotted);
end;

end.

