unit RM.Vulkan.TexScale;

// Textures made larger for the Vulkan HLE renderers above 1x (RM.Vulkan.HLE):
// an option, not the consoles' (which sample their textures as they are).
// Every texel becomes a block of Factor x Factor; where the texels around one
// show an edge passing by one of its corners, that corner of the block takes
// the colour across the edge, cut along it: diagonally, at half or twice the
// diagonal's slope, or as a rounded corner where the edge has no direction to
// follow (xBRZ).
// Bicubic: every pixel of the larger texture is a Catmull-Rom interpolation
// of the 4x4 texels around it, smooth for painted and photographic
// textures. Hybrid: bicubic where a texel differs little from all eight
// around it, the edges' blocks elsewhere.
//
// The approach of the edges is xBRZ's: an edge at a corner is found from the
// colour differences along the two diagonals of the 4x4 texels around it, the shape
// of the blend from the 3x3 around the texel. The share of each pixel of a
// block is the part of its area inside the shape (sampled 16x16), for any
// factor. Colours are compared in Y'CbCr with alpha (transparent texels are
// all alike) and mixed weighted by their alpha; the bicubic one is
// interpolated with its colour premultiplied by its alpha.
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

const
  TexScaleMax = 6;

type
  TTexScaleFilter = (tfXBRZ, tfHybrid, tfBicubic);

// Src: W x H texels ($AABBGGRR, rows packed); Dst: (W * Factor) x
// (H * Factor), rows packed. Factor: 2 to TexScaleMax. Texels past the
// edges count as the edge's.
procedure ScaleTexture(Src: PCardinal; W, H, Factor: Integer; Dst: PCardinal; Filter: TTexScaleFilter = tfXBRZ);

// The filters' names in the settings: xbrz, hybrid, bicubic (anything else is
// xBRZ).
function TexScaleFilterName(Filter: TTexScaleFilter): string;
function TexScaleFilterFromName(const Name: string): TTexScaleFilter;

implementation

uses
  System.SysUtils, System.Math, System.Classes, System.Threading;

const
  FilterNames: array[TTexScaleFilter] of string = ('xbrz', 'hybrid', 'bicubic');

function TexScaleFilterName(Filter: TTexScaleFilter): string;
begin
  Result := FilterNames[Filter];
end;

function TexScaleFilterFromName(const Name: string): TTexScaleFilter;
begin
  for var F := Low(TTexScaleFilter) to High(TTexScaleFilter) do
    if SameText(Name.Trim, FilterNames[F]) then
      Exit(F);
  Result := tfXBRZ;
end;

type
  // A texel's colour as compared: luma and chroma (0 to 255 scale), alpha (0
  // to 1).
  TTexelColour = record
    Y, Cb, Cr, A: Single;
  end;

  // Where a block's corner takes the colour across the edge, in the corner's
  // frame (the block is [0, 1]^2, the corner at (1, 1)).
  TBlendShape = (bsCorner, bsDiagonal, bsShallow, bsSteep, bsShallowSteep);

const
  // Colours closer than this are the same.
  EqualDistance = 30;
  // How much the diagonals' difference must differ for an edge that is
  // drawn as a line whatever is around it.
  DominantRatio = 3.6;
  // How much the differences along a row and along a column must differ for
  // a line at half or twice the diagonal's slope.
  SteepRatio = 2.2;
  // The weight of the difference across the corner itself.
  CentreWeight = 4;
  // Hybrid: a texel this different from one of the eight around it is on an
  // edge.
  HybridEdgeDistance = 40;

  // Corner types (two bits per corner, TL, TR, BL, BR from bit 0).
  CornerNone = 0;
  CornerNormal = 1;
  CornerDominant = 2;

type
  // A pixel of a block along one axis: its 4 texels from Offset (relative to
  // the block's texel) and their Catmull-Rom weights.
  TBicubicTap = record
    Offset: Integer;
    W: array[0..3] of Single;
  end;
  PBicubicTap = ^TBicubicTap;

  // A texel premultiplied: colour times alpha / 255, alpha (0 to 255).
  TPremultiplied = record
    R, G, B, A: Single;
  end;
  PPremultiplied = ^TPremultiplied;

var
  // The share (of 256) of each pixel of a block the shape covers, in the
  // corner's frame, row by row.
  Coverage: array[2..TexScaleMax, TBlendShape, 0..TexScaleMax * TexScaleMax - 1] of Word;
  BicubicTaps: array[2..TexScaleMax, 0..TexScaleMax - 1] of TBicubicTap;

function InShape(Shape: TBlendShape; U, V: Single): Boolean;
begin
  case Shape of
    bsCorner:
      Result := (U > 0.5) and (V > 0.5) and (Sqr(U - 0.5) + Sqr(V - 0.5) > 0.25);
    bsDiagonal:
      Result := U + V > 1.5;
    bsShallow:
      Result := U + 2 * V > 2;
    bsSteep:
      Result := 2 * U + V > 2;
  else
    Result := (U + 2 * V > 2) or (2 * U + V > 2);
  end;
end;

procedure MakeCoverage;
begin
  for var F := 2 to TexScaleMax do
    for var Shape := Low(TBlendShape) to High(TBlendShape) do
      for var J := 0 to F - 1 do
        for var I := 0 to F - 1 do
        begin
          var N := 0;
          for var SY := 0 to 15 do
            for var SX := 0 to 15 do
              if InShape(Shape, (I + (SX + 0.5) / 16) / F, (J + (SY + 0.5) / 16) / F) then
                Inc(N);
          Coverage[F, Shape, J * F + I] := N;
        end;
end;

// Pixel O of a block of F samples at (O + 0.5) / F - 0.5 from the texel's
// centre: between it and the texel before or after.
procedure MakeBicubic;
begin
  for var F := 2 to TexScaleMax do
    for var O := 0 to F - 1 do
    begin
      var T: Single := (O + 0.5) / F - 0.5;
      var Base := 0;
      if T < 0 then
      begin
        Base := -1;
        T := T + 1;
      end;
      var T2 := T * T;
      var T3 := T2 * T;
      BicubicTaps[F, O].Offset := Base - 1;
      BicubicTaps[F, O].W[0] := (-T3 + 2 * T2 - T) / 2;
      BicubicTaps[F, O].W[1] := (3 * T3 - 5 * T2 + 2) / 2;
      BicubicTaps[F, O].W[2] := (-3 * T3 + 4 * T2 + T) / 2;
      BicubicTaps[F, O].W[3] := (T3 - T2) / 2;
    end;
end;

function Channel(V: Single): Cardinal; inline;
begin
  if V <= 0 then
    Result := 0
  else if V >= 255 then
    Result := 255
  else
    Result := Round(V);
end;

function ColourOf(C: Cardinal): TTexelColour;
begin
  var R: Single := C and $FF;
  var G: Single := (C shr 8) and $FF;
  var B: Single := (C shr 16) and $FF;
  Result.Y := 0.2627 * R + 0.678 * G + 0.0593 * B;
  Result.Cb := (B - Result.Y) * (1 / 1.8814);
  Result.Cr := (R - Result.Y) * (1 / 1.4746);
  Result.A := (C shr 24) * (1 / 255);
end;

// The colour difference, as far as the less opaque one shows, plus the
// difference in opacity.
function Distance(const P, Q: TTexelColour): Single; inline;
begin
  var DY := P.Y - Q.Y;
  var DB := P.Cb - Q.Cb;
  var DR := P.Cr - Q.Cr;
  var D := Sqrt(DY * DY + DB * DB + DR * DR);
  if P.A < Q.A then
    Result := P.A * D + 255 * (Q.A - P.A)
  else
    Result := Q.A * D + 255 * (P.A - Q.A);
end;

// D with S's share W (of 256), weighted by their alpha; transparent ones mix
// their colours as they are.
function Mix(D, S: Cardinal; W: Integer): Cardinal;
begin
  if W >= 256 then
    Exit(S);
  if W <= 0 then
    Exit(D);
  var WD := 256 - W;
  var DA := Integer(D shr 24);
  var SA := Integer(S shr 24);
  var NA := DA * WD + SA * W;
  Result := 0;
  for var Shift := 0 to 2 do
  begin
    var DC := Integer((D shr (Shift * 8)) and $FF);
    var SC := Integer((S shr (Shift * 8)) and $FF);
    var C: Integer;
    if NA = 0 then
      C := (DC * WD + SC * W + 128) shr 8
    else
      C := (DC * DA * WD + SC * SA * W + NA div 2) div NA;
    Result := Result or (Cardinal(Min(C, 255)) shl (Shift * 8));
  end;
  Result := Result or (Cardinal((NA + 128) shr 8) shl 24);
end;

type
  // One texture being scaled: the texels with two of border on every side
  // (repeating the edges), the corners' types from each 2x2 of texels.
  TTextureScaler = class
    W, H, PW, Factor: Integer;
    Filter: TTexScaleFilter;
    Dst: PCardinal;
    Colours, Keys: TArray<Cardinal>;
    Texels: TArray<TTexelColour>;
    Premultiplied: TArray<TPremultiplied>;
    // For the 2x2 whose top left texel is (X, Y), X and Y from -1, at
    // (Y + 1) * (W + 1) + X + 1: the types of F's bottom right corner (bits
    // 0-1), K's top left (2-3), J's top right (4-5), G's bottom left (6-7).
    Blocks: TArray<Byte>;
    constructor Create(Src: PCardinal; AW, AH, AFactor: Integer; ADst: PCardinal; AFilter: TTexScaleFilter);
    procedure FindCorners(Y1, Y2: Integer);
    function OnEdge(E: Integer): Boolean;
    procedure DrawBicubic(E: Integer; Block: PCardinal; DW: Integer);
    procedure DrawRows(Y1, Y2: Integer);
  end;

constructor TTextureScaler.Create(Src: PCardinal; AW, AH, AFactor: Integer; ADst: PCardinal; AFilter: TTexScaleFilter);
begin
  inherited Create;
  W := AW;
  H := AH;
  Factor := AFactor;
  Filter := AFilter;
  Dst := ADst;
  PW := W + 4;
  var PH := H + 4;
  SetLength(Colours, PW * PH);
  SetLength(Keys, PW * PH);
  SetLength(Texels, PW * PH);
  for var Y := 0 to PH - 1 do
  begin
    var Row := Src + EnsureRange(Y - 2, 0, H - 1) * W;
    for var X := 0 to PW - 1 do
    begin
      var C := Row[EnsureRange(X - 2, 0, W - 1)];
      var I := Y * PW + X;
      Colours[I] := C;
      // Transparent texels are all the same.
      if C shr 24 = 0 then
        Keys[I] := 0
      else
        Keys[I] := C;
      Texels[I] := ColourOf(C);
    end;
  end;
  SetLength(Blocks, (W + 1) * (H + 1));
  if Filter <> tfXBRZ then
  begin
    SetLength(Premultiplied, PW * PH);
    for var I := 0 to PW * PH - 1 do
    begin
      var C := Colours[I];
      var A: Single := C shr 24;
      var S := A / 255;
      Premultiplied[I].R := (C and $FF) * S;
      Premultiplied[I].G := ((C shr 8) and $FF) * S;
      Premultiplied[I].B := ((C shr 16) and $FF) * S;
      Premultiplied[I].A := A;
    end;
  end;
end;

// A texel that differs from one of the eight around it (hybrid).
function TTextureScaler.OnEdge(E: Integer): Boolean;
begin
  for var DY := -1 to 1 do
    for var DX := -1 to 1 do
      if ((DX <> 0) or (DY <> 0)) and (Distance(Texels[E], Texels[E + DY * PW + DX]) >= HybridEdgeDistance) then
        Exit(True);
  Result := False;
end;

// The block of texel E interpolated (Catmull-Rom, premultiplied alpha):
// along the rows of the five texels around it, then down the columns; where
// nothing is opaque, the texel's colour, transparent.
procedure TTextureScaler.DrawBicubic(E: Integer; Block: PCardinal; DW: Integer);
var
  Rows: array[0..4, 0..TexScaleMax - 1] of TPremultiplied;
begin
  for var RY := 0 to 4 do
    for var OX := 0 to Factor - 1 do
    begin
      var TX: PBicubicTap := @BicubicTaps[Factor, OX];
      var P: PPremultiplied := @Premultiplied[E + (RY - 2) * PW + TX.Offset];
      var S: TPremultiplied;
      S.R := TX.W[0] * P[0].R + TX.W[1] * P[1].R + TX.W[2] * P[2].R + TX.W[3] * P[3].R;
      S.G := TX.W[0] * P[0].G + TX.W[1] * P[1].G + TX.W[2] * P[2].G + TX.W[3] * P[3].G;
      S.B := TX.W[0] * P[0].B + TX.W[1] * P[1].B + TX.W[2] * P[2].B + TX.W[3] * P[3].B;
      S.A := TX.W[0] * P[0].A + TX.W[1] * P[1].A + TX.W[2] * P[2].A + TX.W[3] * P[3].A;
      Rows[RY, OX] := S;
    end;
  for var OY := 0 to Factor - 1 do
  begin
    var TY: PBicubicTap := @BicubicTaps[Factor, OY];
    var R0 := TY.Offset + 2;
    for var OX := 0 to Factor - 1 do
    begin
      var R := TY.W[0] * Rows[R0, OX].R + TY.W[1] * Rows[R0 + 1, OX].R + TY.W[2] * Rows[R0 + 2, OX].R +
        TY.W[3] * Rows[R0 + 3, OX].R;
      var G := TY.W[0] * Rows[R0, OX].G + TY.W[1] * Rows[R0 + 1, OX].G + TY.W[2] * Rows[R0 + 2, OX].G +
        TY.W[3] * Rows[R0 + 3, OX].G;
      var B := TY.W[0] * Rows[R0, OX].B + TY.W[1] * Rows[R0 + 1, OX].B + TY.W[2] * Rows[R0 + 2, OX].B +
        TY.W[3] * Rows[R0 + 3, OX].B;
      var A := TY.W[0] * Rows[R0, OX].A + TY.W[1] * Rows[R0 + 1, OX].A + TY.W[2] * Rows[R0 + 2, OX].A +
        TY.W[3] * Rows[R0 + 3, OX].A;
      if A >= 0.5 then
      begin
        var S := 255 / A;
        Block[OY * DW + OX] := Channel(R * S) or (Channel(G * S) shl 8) or (Channel(B * S) shl 16) or
          (Channel(A) shl 24);
      end
      else
        Block[OY * DW + OX] := Colours[E] and $FFFFFF;
    end;
  end;
end;

// The 2x2s with top rows Y1..Y2 (from -1), of texels F G / J K in the 4x4
//   A B C D
//   E F G H
//   I J K L
//   M N O P
// An edge along one diagonal through the middle (J-G or F-K) blends the
// corners there of the texels off it.
procedure TTextureScaler.FindCorners(Y1, Y2: Integer);
begin
  for var BY := Y1 to Y2 do
    for var BX := -1 to W - 1 do
    begin
      var F := (BY + 2) * PW + BX + 2;
      var G := F + 1;
      var J := F + PW;
      var K := J + 1;
      var KF := Keys[F];
      var KG := Keys[G];
      var KJ := Keys[J];
      var KK := Keys[K];
      if ((KF = KG) and (KJ = KK)) or ((KF = KJ) and (KG = KK)) then
        Continue;
      var JG := Distance(Texels[J - 1], Texels[F]) + Distance(Texels[F], Texels[G - PW]) + Distance(Texels[J + PW],
        Texels[K]) + Distance(Texels[K], Texels[G + 1]) + CentreWeight * Distance(Texels[J], Texels[G]);
      var FK := Distance(Texels[F - 1], Texels[J]) + Distance(Texels[J], Texels[K + PW]) + Distance(Texels[F - PW],
        Texels[G]) + Distance(Texels[G], Texels[K + 1]) + CentreWeight * Distance(Texels[F], Texels[K]);
      var B := 0;
      if JG < FK then
      begin
        var T := CornerNormal + Ord(DominantRatio * JG < FK);
        if (KF <> KG) and (KF <> KJ) then
          B := B or T;
        if (KK <> KG) and (KK <> KJ) then
          B := B or (T shl 2);
      end
      else if FK < JG then
      begin
        var T := CornerNormal + Ord(DominantRatio * FK < JG);
        if (KJ <> KF) and (KJ <> KK) then
          B := B or (T shl 4);
        if (KG <> KF) and (KG <> KK) then
          B := B or (T shl 6);
      end;
      Blocks[(BY + 1) * (W + 1) + BX + 1] := B;
    end;
end;

// The blocks of texel rows Y1..Y2: the texel's colour, then each corner with
// a type blended in its frame, where the texels around read (corner towards i)
//   a b c
//   d e f
//   g h i
procedure TTextureScaler.DrawRows(Y1, Y2: Integer);
begin
  var DW := W * Factor;
  var BW := W + 1;
  for var Y := Y1 to Y2 do
    for var X := 0 to W - 1 do
    begin
      var E := (Y + 2) * PW + X + 2;
      var Block := Dst + Y * Factor * DW + X * Factor;
      if (Filter = tfBicubic) or ((Filter = tfHybrid) and not OnEdge(E)) then
      begin
        DrawBicubic(E, Block, DW);
        Continue;
      end;
      var C := Colours[E];
      for var J := 0 to Factor - 1 do
        for var I := 0 to Factor - 1 do
          Block[J * DW + I] := C;
      // Its corners (TL, TR, BL, BR from bit 0) from the 2x2s around it.
      var Types := ((Blocks[Y * BW + X] shr 2) and 3) or (((Blocks[Y * BW + X + 1] shr 4) and 3) shl 2) or
        (((Blocks[(Y + 1) * BW + X] shr 6) and 3) shl 4) or ((Blocks[(Y + 1) * BW + X + 1] and 3) shl 6);
      if Types = 0 then
        Continue;
      for var R := 0 to 3 do
      begin
        var T := (Types shr (2 * R)) and 3;
        if T = CornerNone then
          Continue;
        // The corner's direction: right (bit 0) and down (bit 1).
        var SX := 2 * (R and 1) - 1;
        var SY := (R and 2) - 1;
        var StepY := SY * PW;
        var EB := E - StepY;
        var EC := E + SX - StepY;
        var ED := E - SX;
        var EF := E + SX;
        var EG := E - SX + StepY;
        var EH := E + StepY;
        var EI := E + SX + StepY;
        // The corners beside it in its frame: top right and bottom left.
        var TopRight := (Types shr (2 * ((R and 1) or (2 - (R and 2))))) and 3;
        var BottomLeft := (Types shr (2 * ((1 - (R and 1)) or (R and 2)))) and 3;
        var Line: Boolean;
        if T = CornerDominant then
          Line := True
        else if (TopRight <> CornerNone) and (Distance(Texels[E], Texels[EG]) >= EqualDistance) then
          Line := False
        else if (BottomLeft <> CornerNone) and (Distance(Texels[E], Texels[EC]) >= EqualDistance) then
          Line := False
              // An L of one colour around the corner: only the corner is rounded.
        else if (Distance(Texels[E], Texels[EI]) >= EqualDistance) and (Distance(Texels[EG], Texels[EH]) <
          EqualDistance) and (Distance(Texels[EH], Texels[EI]) < EqualDistance) and (Distance(Texels[EI], Texels[EF]) <
          EqualDistance) and (Distance(Texels[EF], Texels[EC]) < EqualDistance) then
          Line := False
        else
          Line := True;
        var P: Cardinal;
        if Distance(Texels[E], Texels[EF]) <= Distance(Texels[E], Texels[EH]) then
          P := Colours[EF]
        else
          P := Colours[EH];
        var Shape := bsCorner;
        if Line then
        begin
          var FG := Distance(Texels[EF], Texels[EG]);
          var HC := Distance(Texels[EH], Texels[EC]);
          var Shallow := (SteepRatio * FG <= HC) and (Keys[E] <> Keys[EG]) and (Keys[ED] <> Keys[EG]);
          var Steep := (SteepRatio * HC <= FG) and (Keys[E] <> Keys[EC]) and (Keys[EB] <> Keys[EC]);
          if Shallow and Steep then
            Shape := bsShallowSteep
          else if Shallow then
            Shape := bsShallow
          else if Steep then
            Shape := bsSteep
          else
            Shape := bsDiagonal;
        end;
        for var J := 0 to Factor - 1 do
          for var I := 0 to Factor - 1 do
          begin
            var Share := Coverage[Factor, Shape, J * Factor + I];
            if Share = 0 then
              Continue;
            var OX := I;
            if SX < 0 then
              OX := Factor - 1 - I;
            var OY := J;
            if SY < 0 then
              OY := Factor - 1 - J;
            Block[OY * DW + OX] := Mix(Block[OY * DW + OX], P, Share);
          end;
      end;
    end;
end;

procedure ScaleTexture(Src: PCardinal; W, H, Factor: Integer; Dst: PCardinal; Filter: TTexScaleFilter);
begin
  var S := TTextureScaler.Create(Src, W, H, EnsureRange(Factor, 2, TexScaleMax), Dst, Filter);
  try
    // Bands of rows on the thread pool for larger textures; each pass writes
    // only its own rows.
    var Bands := 1;
    if W * H >= 64 * 64 then
      Bands := Min(TThread.ProcessorCount, (H + 15) div 16);
    if Bands <= 1 then
    begin
      if Filter <> tfBicubic then
        S.FindCorners(-1, H - 1);
      S.DrawRows(0, H - 1);
      Exit;
    end;
    if Filter <> tfBicubic then
      TParallel.For(0, Bands - 1,
        procedure(Band: Integer)
        begin
          S.FindCorners(-1 + (H + 1) * Band div Bands, -1 + (H + 1) * (Band + 1) div Bands - 1);
        end);
    TParallel.For(0, Bands - 1,
      procedure(Band: Integer)
      begin
        S.DrawRows(H * Band div Bands, H * (Band + 1) div Bands - 1);
      end);
  finally
    S.Free;
  end;
end;

initialization
  MakeCoverage;
  MakeBicubic;

end.
