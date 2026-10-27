unit PS1.GPU.Raster;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, PS1.Types;

type
  // Drawing environment set by GP0(E1h..E6h) and GP1(09h).
  TPS1DrawEnvironment = record
    DrawMode, TextureWindow, AreaTopLeft, AreaBottomRight, Offset: Cardinal;
    MaskSet, MaskCheck, TextureDisableAllowed: Boolean;
  end;

  PPS1DrawEnvironment = ^TPS1DrawEnvironment;

  // Draws GP0 polygons, lines and rectangles into VRAM.
  TPS1Rasterizer = class
  private
    const
    // 4x4 dither offsets added to 8-bit colors before truncation to 5 bits
    // (here so that the inline Shade can use them).
      DitherTable: array[0..3, 0..3] of Integer = ((-4, 0, -3, 1), (2, -2, 3, -1), (-3, 1, -4, 0), (3, -1, 2, -2));
  private
    type
      TVertex = record
        X, Y, R, G, B, U, V: Integer;
      end;

      TMode = record
        Textured, Raw, Shaded, SemiTransparent, Dither: Boolean;
        Blend, Depth, PageX, PageY: Integer;
        WindowAndU, WindowOrU, WindowAndV, WindowOrV: Integer;
        MaskOut: Word;
        PixelWork: Integer;
      end;
  private
    FVRAM: PPS1VRAM;
    FEnv: PPS1DrawEnvironment;
    FClut: array[0..255] of Word;
    FClutCount: Integer;
    FClutAttribute: Cardinal;
    FLeft, FTop, FRight, FBottom: Integer;
    FOffsetX, FOffsetY: Integer;
    procedure PrepareArea;
    procedure PrepareMode(var Mode: TMode; DrawMode: Cardinal);
    procedure PrepareWork(var Mode: TMode);
    procedure LoadClut(const Mode: TMode; Attribute: Cardinal);
    function Texel(const Mode: TMode; U, V: Integer): Word; inline;
    procedure Shade(const Mode: TMode; X, Y, R, G, B: Integer; Texture: Word); inline;
    procedure Triangle(const V0, V1, V2: TVertex; const Mode: TMode);
  public
    // Rows of this parity are left alone (interlaced output with drawing to
    // the displayed field prohibited); -1 draws every row.
    SkipParity: Integer;
    // Drawing time of the primitives so far, in 1/256 CPU cycles; the GPU
    // collects and clears it.
    Work: Int64;
    constructor Create(VRAM: PPS1VRAM; Environment: PPS1DrawEnvironment);
    procedure Reset;
    procedure InvalidateClut;
    procedure Polygon(const Words: array of Cardinal);
    procedure Line(Color0, Vertex0, Color1, Vertex1: Cardinal; Shaded, SemiTransparent: Boolean);
    procedure Rectangle(const Words: array of Cardinal);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

const
  // Drawing time in 1/256 CPU cycles, fitted to ps1-tests gpu/bandwidth: per
  // primitive, per drawn row and per pixel (untextured opaque and
  // semi-transparent, textured by texel depth).
  PrimitiveWork = 16 * 256;
  RowWork = 2 * 256;
  OpaquePixelWork = 133;
  BlendPixelWork = 202;
  TexturePixelWork: array[0..2] of Integer = (268, 420, 712);

  // Interpolated attributes have 12 fraction bits: per-pixel steps are the
  // plane gradients truncated toward zero, and the value at the leftmost
  // vertex is rounded (fitted to the ps1-tests triangle and uv-interpolation
  // captures, which this matches exactly).
  AttributeFraction = 12;
  AttributeOne = Int64(1) shl AttributeFraction;
  AttributeBias = Int64(1) shl (AttributeFraction - 1);

function SignExtend11(Value: Cardinal): Integer; inline;
begin
  Result := Integer(Value and $7FF);
  if Result >= $400 then
    Dec(Result, $800);
end;

function Sar64(Value: Int64; Count: Integer): Int64; inline;
begin
  if Value >= 0 then
    Result := Value shr Count
  else
    Result := not ((not Value) shr Count);
end;

// Floor of N / D for D > 0.
function FloorDiv(N, D: Int64): Int64; inline;
begin
  if N >= 0 then
    Result := N div D
  else
    Result := -((D - 1 - N) div D);
end;

function CeilDiv(N, D: Int64): Int64; inline;
begin
  Result := -FloorDiv(-N, D);
end;

function Clamp8(Value: Integer): Integer; inline;
begin
  if Value < 0 then
    Result := 0
  else if Value > 255 then
    Result := 255
  else
    Result := Value;
end;

constructor TPS1Rasterizer.Create(VRAM: PPS1VRAM; Environment: PPS1DrawEnvironment);
begin
  inherited Create;
  FVRAM := VRAM;
  FEnv := Environment;
  Reset;
end;

procedure TPS1Rasterizer.Reset;
begin
  FillChar(FClut, SizeOf(FClut), 0);
  FClutCount := 0;
  FClutAttribute := 0;
  SkipParity := -1;
end;

procedure TPS1Rasterizer.InvalidateClut;
begin
  FClutCount := 0;
end;

procedure TPS1Rasterizer.PrepareArea;
begin
  FLeft := Integer(FEnv.AreaTopLeft and $3FF);
  FTop := Integer((FEnv.AreaTopLeft shr 10) and $1FF);
  FRight := Integer(FEnv.AreaBottomRight and $3FF);
  FBottom := Integer((FEnv.AreaBottomRight shr 10) and $1FF);
  FOffsetX := SignExtend11(FEnv.Offset);
  FOffsetY := SignExtend11(FEnv.Offset shr 11);
end;

procedure TPS1Rasterizer.PrepareMode(var Mode: TMode; DrawMode: Cardinal);
begin
  Mode.Blend := Integer((DrawMode shr 5) and 3);
  Mode.Depth := Integer((DrawMode shr 7) and 3);
  if Mode.Depth = 3 then
    Mode.Depth := 2;
  Mode.PageX := Integer(DrawMode and $F) * 64;
  Mode.PageY := Integer((DrawMode shr 4) and 1) * 256;
  // Texcoord = (Texcoord AND NOT (Mask * 8)) OR ((Offset AND Mask) * 8)
  var Window := FEnv.TextureWindow;
  var MaskU := Integer(Window and $1F) * 8;
  var MaskV := Integer((Window shr 5) and $1F) * 8;
  Mode.WindowAndU := not MaskU and $FF;
  Mode.WindowAndV := not MaskV and $FF;
  Mode.WindowOrU := Integer((Window shr 10) and $1F) * 8 and MaskU;
  Mode.WindowOrV := Integer((Window shr 15) and $1F) * 8 and MaskV;
  Mode.MaskOut := 0;
  if FEnv.MaskSet then
    Mode.MaskOut := $8000;
end;

procedure TPS1Rasterizer.PrepareWork(var Mode: TMode);
begin
  if Mode.Textured then
    Mode.PixelWork := TexturePixelWork[Mode.Depth]
  else if Mode.SemiTransparent then
    Mode.PixelWork := BlendPixelWork
  else
    Mode.PixelWork := OpaquePixelWork;
  Inc(Work, PrimitiveWork);
end;

// The CLUT cache reloads when another palette is used or more entries are
// needed than it holds; VRAM writes alone do not refresh it.
procedure TPS1Rasterizer.LoadClut(const Mode: TMode; Attribute: Cardinal);
begin
  if Mode.Depth = 2 then
    Exit;

  var Needed := 16;
  if Mode.Depth = 1 then
    Needed := 256;
  Attribute := Attribute and $7FFF;
  if (FClutCount >= Needed) and (FClutAttribute = Attribute) then
    Exit;

  var X := Integer(Attribute and $3F) * 16;
  var Row := Integer((Attribute shr 6) and $1FF) * PS1VRAMWidth;
  for var I := 0 to Needed - 1 do
    FClut[I] := FVRAM[Row + ((X + I) and $3FF)];
  FClutCount := Needed;
  FClutAttribute := Attribute;
end;

function TPS1Rasterizer.Texel(const Mode: TMode; U, V: Integer): Word;
begin
  U := (U and Mode.WindowAndU) or Mode.WindowOrU;
  V := (V and Mode.WindowAndV) or Mode.WindowOrV;
  var Row := ((Mode.PageY + V) and $1FF) * PS1VRAMWidth;
  case Mode.Depth of
    0:
      begin
        var Data := FVRAM[Row + ((Mode.PageX + U shr 2) and $3FF)];
        Result := FClut[(Data shr ((U and 3) * 4)) and $F];
      end;
    1:
      begin
        var Data := FVRAM[Row + ((Mode.PageX + U shr 1) and $3FF)];
        Result := FClut[(Data shr ((U and 1) * 8)) and $FF];
      end;
  else
    Result := FVRAM[Row + ((Mode.PageX + U) and $3FF)];
  end;
end;

// Colors are 8-bit; Texture is the fetched texel of textured primitives.
procedure TPS1Rasterizer.Shade(const Mode: TMode; X, Y, R, G, B: Integer; Texture: Word);
begin
  var Index := Y * PS1VRAMWidth + X;
  var Old := FVRAM[Index];
  if FEnv.MaskCheck and ((Old and $8000) <> 0) then
    Exit;

  var Semi := Mode.SemiTransparent;
  var Mask := Mode.MaskOut;
  var R5, G5, B5: Integer;
  if Mode.Textured and Mode.Raw then
  begin
    R5 := Texture and $1F;
    G5 := (Texture shr 5) and $1F;
    B5 := (Texture shr 10) and $1F;
  end
  else
  begin
    if Mode.Textured then
    begin
      R := ((Texture and $1F) * R) shr 4;
      G := (((Texture shr 5) and $1F) * G) shr 4;
      B := (((Texture shr 10) and $1F) * B) shr 4;
    end;
    if Mode.Dither then
    begin
      var Offset := DitherTable[Y and 3, X and 3];
      Inc(R, Offset);
      Inc(G, Offset);
      Inc(B, Offset);
    end;
    R5 := Clamp8(R) shr 3;
    G5 := Clamp8(G) shr 3;
    B5 := Clamp8(B) shr 3;
  end;
  if Mode.Textured then
  begin
    Semi := Semi and ((Texture and $8000) <> 0);
    Mask := Mask or (Texture and $8000);
  end;
  if Semi then
  begin
    var OldR := Old and $1F;
    var OldG := (Old shr 5) and $1F;
    var OldB := (Old shr 10) and $1F;
    case Mode.Blend of
      0:
        begin
          R5 := (OldR + R5) shr 1;
          G5 := (OldG + G5) shr 1;
          B5 := (OldB + B5) shr 1;
        end;
      1:
        begin
          R5 := OldR + R5;
          G5 := OldG + G5;
          B5 := OldB + B5;
        end;
      2:
        begin
          R5 := OldR - R5;
          G5 := OldG - G5;
          B5 := OldB - B5;
        end;
    else
      begin
        R5 := OldR + R5 shr 2;
        G5 := OldG + G5 shr 2;
        B5 := OldB + B5 shr 2;
      end;
    end;
    if R5 < 0 then
      R5 := 0
    else if R5 > 31 then
      R5 := 31;
    if G5 < 0 then
      G5 := 0
    else if G5 > 31 then
      G5 := 31;
    if B5 < 0 then
      B5 := 0
    else if B5 > 31 then
      B5 := 31;
  end;
  FVRAM[Index] := Word(R5 or (G5 shl 5) or (B5 shl 10)) or Mask;
end;

// Polygons cover pixels whose top-left corner lies inside the triangle; the
// right and bottom edges are excluded. Attributes are linear in X and Y.
procedure TPS1Rasterizer.Triangle(const V0, V1, V2: TVertex; const Mode: TMode);
var
  P: array[0..2] of TVertex;
  GradX, GradY, Base, Acc: array[0..4] of Int64;
  Planes: array[0..4] of Integer;
begin
  var MinX := V0.X;
  var MaxX := V0.X;
  var MinY := V0.Y;
  var MaxY := V0.Y;
  for var V in [V1, V2] do
  begin
    if V.X < MinX then
      MinX := V.X;
    if V.X > MaxX then
      MaxX := V.X;
    if V.Y < MinY then
      MinY := V.Y;
    if V.Y > MaxY then
      MaxY := V.Y;
  end;
  if (MaxX - MinX >= 1024) or (MaxY - MinY >= 512) then
    Exit;

  var Area := Int64(V1.X - V0.X) * (V2.Y - V0.Y) - Int64(V2.X - V0.X) * (V1.Y - V0.Y);
  if Area = 0 then
    Exit;

  // Attribute planes relative to the leftmost vertex O: 0..2 color, 3..4
  // texcoords.
  var O := V0;
  for var V in [V1, V2] do
    if (V.X < O.X) or ((V.X = O.X) and (V.Y < O.Y)) then
      O := V;
  var PlaneCount := 0;
  var NeedColor := Mode.Shaded and not (Mode.Textured and Mode.Raw);
  for var I := 0 to 4 do
    if ((I < 3) and NeedColor) or ((I >= 3) and Mode.Textured) then
    begin
      Planes[PlaneCount] := I;
      Inc(PlaneCount);
      var A0, A1, A2, AO: Integer;
      case I of
        0:
          begin
            A0 := V0.R;
            A1 := V1.R;
            A2 := V2.R;
            AO := O.R;
          end;
        1:
          begin
            A0 := V0.G;
            A1 := V1.G;
            A2 := V2.G;
            AO := O.G;
          end;
        2:
          begin
            A0 := V0.B;
            A1 := V1.B;
            A2 := V2.B;
            AO := O.B;
          end;
        3:
          begin
            A0 := V0.U;
            A1 := V1.U;
            A2 := V2.U;
            AO := O.U;
          end;
      else
        begin
          A0 := V0.V;
          A1 := V1.V;
          A2 := V2.V;
          AO := O.V;
        end;
      end;
      var NumX := Int64(A1 - A0) * (V2.Y - V0.Y) - Int64(A2 - A0) * (V1.Y - V0.Y);
      var NumY := Int64(A2 - A0) * (V1.X - V0.X) - Int64(A1 - A0) * (V2.X - V0.X);
      GradX[I] := NumX * AttributeOne div Area;
      GradY[I] := NumY * AttributeOne div Area;
      Base[I] := Int64(AO) * AttributeOne + AttributeBias;
    end;

  // Sort by Y: top, middle, bottom.
  P[0] := V0;
  P[1] := V1;
  P[2] := V2;
  if P[1].Y < P[0].Y then
  begin
    var T := P[0];
    P[0] := P[1];
    P[1] := T;
  end;
  if P[2].Y < P[1].Y then
  begin
    var T := P[1];
    P[1] := P[2];
    P[2] := T;
  end;
  if P[1].Y < P[0].Y then
  begin
    var T := P[0];
    P[0] := P[1];
    P[1] := T;
  end;
  // The middle vertex lies left of the long edge when Side < 0.
  var Side := Int64(P[1].X - P[0].X) * (P[2].Y - P[0].Y) - Int64(P[2].X - P[0].X) * (P[1].Y - P[0].Y);

  var RowFirst := P[0].Y;
  if RowFirst < FTop then
    RowFirst := FTop;
  var RowLast := P[2].Y - 1;
  if RowLast > FBottom then
    RowLast := FBottom;
  var R := V0.R;
  var G := V0.G;
  var B := V0.B;
  for var Y := RowFirst to RowLast do
  begin
    Inc(Work, RowWork);
    if (Y and 1) = SkipParity then
      Continue;
    // Each boundary is the first pixel at or right of its edge.
    var LongX := P[0].X + CeilDiv(Int64(Y - P[0].Y) * (P[2].X - P[0].X), P[2].Y - P[0].Y);
    var ShortX: Int64;
    if Y < P[1].Y then
      ShortX := P[0].X + CeilDiv(Int64(Y - P[0].Y) * (P[1].X - P[0].X), P[1].Y - P[0].Y)
    else
      ShortX := P[1].X + CeilDiv(Int64(Y - P[1].Y) * (P[2].X - P[1].X), P[2].Y - P[1].Y);
    var Left := LongX;
    var Right := ShortX;
    if Side < 0 then
    begin
      Left := ShortX;
      Right := LongX;
    end;
    if Left < FLeft then
      Left := FLeft;
    if Right > FRight + 1 then
      Right := FRight + 1;
    if Left >= Right then
      Continue;

    Inc(Work, (Right - Left) * Mode.PixelWork);
    var X0 := Integer(Left);
    for var J := 0 to PlaneCount - 1 do
    begin
      var I := Planes[J];
      Acc[I] := Base[I] + (X0 - O.X) * GradX[I] + (Y - O.Y) * GradY[I];
    end;
    for var X := X0 to Integer(Right) - 1 do
    begin
      if NeedColor then
      begin
        R := Clamp8(Integer(Sar64(Acc[0], AttributeFraction)));
        G := Clamp8(Integer(Sar64(Acc[1], AttributeFraction)));
        B := Clamp8(Integer(Sar64(Acc[2], AttributeFraction)));
      end;
      var Texture: Word := 0;
      if Mode.Textured then
        Texture := Texel(Mode, Integer(Sar64(Acc[3], AttributeFraction) and $FF),
          Integer(Sar64(Acc[4], AttributeFraction) and $FF));
      if not Mode.Textured or (Texture <> 0) then
        Shade(Mode, X, Y, R, G, B, Texture);
      // Planes holds 0..2 with NeedColor and 3..4 when textured.
      if NeedColor then
      begin
        Inc(Acc[0], GradX[0]);
        Inc(Acc[1], GradX[1]);
        Inc(Acc[2], GradX[2]);
      end;
      if Mode.Textured then
      begin
        Inc(Acc[3], GradX[3]);
        Inc(Acc[4], GradX[4]);
      end;
    end;
  end;
end;

procedure TPS1Rasterizer.Polygon(const Words: array of Cardinal);
var
  V: array[0..3] of TVertex;
  Mode: TMode;
begin
  var Op := Words[0] shr 24;
  var Count := 3;
  if (Op and $08) <> 0 then
    Count := 4;
  Mode.Shaded := (Op and $10) <> 0;
  Mode.Textured := (Op and $04) <> 0;
  Mode.SemiTransparent := (Op and $02) <> 0;
  Mode.Raw := (Op and $01) <> 0;

  var Clut: Cardinal := 0;
  var Page: Cardinal := 0;
  var P := 1;
  for var I := 0 to Count - 1 do
  begin
    var Color := Words[0];
    if Mode.Shaded and (I > 0) then
    begin
      Color := Words[P];
      Inc(P);
    end;
    var Vertex := Words[P];
    Inc(P);
    V[I].R := Integer(Color and $FF);
    V[I].G := Integer((Color shr 8) and $FF);
    V[I].B := Integer((Color shr 16) and $FF);
    V[I].X := SignExtend11(Vertex);
    V[I].Y := SignExtend11(Vertex shr 16);
    V[I].U := 0;
    V[I].V := 0;
    if Mode.Textured then
    begin
      var UV := Words[P];
      Inc(P);
      V[I].U := Integer(UV and $FF);
      V[I].V := Integer((UV shr 8) and $FF);
      case I of
        0:
          Clut := UV shr 16;
        1:
          Page := UV shr 16;
      end;
    end;
  end;

  if Mode.Textured then
  begin
    // The page attribute replaces E1h bits 0..8 (and the texture disable
    // bit when GP1(09h) allows it).
    var Bits: Cardinal := $1FF;
    if FEnv.TextureDisableAllowed then
      Bits := $9FF;
    FEnv.DrawMode := (FEnv.DrawMode and not Bits) or (Page and Bits);
    if (FEnv.DrawMode and $800) <> 0 then
      Mode.Textured := False;
  end;
  PrepareArea;
  PrepareMode(Mode, FEnv.DrawMode);
  Mode.Dither := ((FEnv.DrawMode and $200) <> 0) and (Mode.Shaded or (Mode.Textured and not Mode.Raw));
  PrepareWork(Mode);
  if Mode.Textured then
    LoadClut(Mode, Clut);
  for var I := 0 to Count - 1 do
  begin
    Inc(V[I].X, FOffsetX);
    Inc(V[I].Y, FOffsetY);
  end;
  if (FLeft > FRight) or (FTop > FBottom) then
    Exit;

  Triangle(V[0], V[1], V[2], Mode);
  if Count = 4 then
    Triangle(V[1], V[2], V[3], Mode);
end;

// Lines include both end points and step one pixel along the major axis. The
// minor coordinate is rounded to nearest, X ties down and Y ties up; colors
// step like polygon attributes (ps1-tests lines, matched exactly).
procedure TPS1Rasterizer.Line(Color0, Vertex0, Color1, Vertex1: Cardinal; Shaded, SemiTransparent: Boolean);
var
  Mode: TMode;
begin
  PrepareArea;
  Mode := Default(TMode);
  PrepareMode(Mode, FEnv.DrawMode);
  Mode.Shaded := Shaded;
  Mode.SemiTransparent := SemiTransparent;
  Mode.Dither := (FEnv.DrawMode and $200) <> 0;
  PrepareWork(Mode);
  if (FLeft > FRight) or (FTop > FBottom) then
    Exit;

  var X0 := SignExtend11(Vertex0) + FOffsetX;
  var Y0 := SignExtend11(Vertex0 shr 16) + FOffsetY;
  var X1 := SignExtend11(Vertex1) + FOffsetX;
  var Y1 := SignExtend11(Vertex1 shr 16) + FOffsetY;
  var DX := X1 - X0;
  var DY := Y1 - Y0;
  if (Abs(DX) >= 1024) or (Abs(DY) >= 512) then
    Exit;

  var R0 := Integer(Color0 and $FF);
  var G0 := Integer((Color0 shr 8) and $FF);
  var B0 := Integer((Color0 shr 16) and $FF);
  var Steps := Abs(DX);
  if Abs(DY) > Steps then
    Steps := Abs(DY);
  var StepR: Int64 := 0;
  var StepG: Int64 := 0;
  var StepB: Int64 := 0;
  if Shaded and (Steps > 0) then
  begin
    StepR := (Integer(Color1 and $FF) - R0) * AttributeOne div Steps;
    StepG := (Integer((Color1 shr 8) and $FF) - G0) * AttributeOne div Steps;
    StepB := (Integer((Color1 shr 16) and $FF) - B0) * AttributeOne div Steps;
  end;
  for var K := 0 to Steps do
  begin
    var X := X0;
    var Y := Y0;
    if Steps > 0 then
    begin
      X := X0 + Integer(CeilDiv(Int64(2 * K) * DX - Steps, 2 * Steps));
      Y := Y0 + Integer(FloorDiv(Int64(2 * K) * DY + Steps, 2 * Steps));
    end;
    var R := Integer(Sar64(R0 * AttributeOne + AttributeBias + K * StepR, AttributeFraction));
    var G := Integer(Sar64(G0 * AttributeOne + AttributeBias + K * StepG, AttributeFraction));
    var B := Integer(Sar64(B0 * AttributeOne + AttributeBias + K * StepB, AttributeFraction));
    if (X < FLeft) or (X > FRight) or (Y < FTop) or (Y > FBottom) or ((Y and 1) = SkipParity) then
      Continue;
    Inc(Work, Mode.PixelWork);
    Shade(Mode, X, Y, R, G, B, 0);
  end;
end;

procedure TPS1Rasterizer.Rectangle(const Words: array of Cardinal);
var
  Mode: TMode;
begin
  var Op := Words[0] shr 24;
  Mode := Default(TMode);
  PrepareArea;
  PrepareMode(Mode, FEnv.DrawMode);
  Mode.Textured := ((Op and $04) <> 0) and ((FEnv.DrawMode and $800) = 0);
  Mode.SemiTransparent := (Op and $02) <> 0;
  Mode.Raw := (Op and $01) <> 0;
  PrepareWork(Mode);
  if (FLeft > FRight) or (FTop > FBottom) then
    Exit;

  var P := 2;
  var UV: Cardinal := 0;
  if (Op and $04) <> 0 then
  begin
    UV := Words[2];
    Inc(P);
  end;
  var Width, Height: Integer;
  case (Op shr 3) and 3 of
    1:
      begin
        Width := 1;
        Height := 1;
      end;
    2:
      begin
        Width := 8;
        Height := 8;
      end;
    3:
      begin
        Width := 16;
        Height := 16;
      end;
  else
    Width := Integer(Words[P] and $3FF);
    Height := Integer((Words[P] shr 16) and $1FF);
  end;
  if Mode.Textured then
    LoadClut(Mode, UV shr 16);

  var X0 := SignExtend11(Words[1]) + FOffsetX;
  var Y0 := SignExtend11(Words[1] shr 16) + FOffsetY;
  var R := Integer(Words[0] and $FF);
  var G := Integer((Words[0] shr 8) and $FF);
  var B := Integer((Words[0] shr 16) and $FF);
  // An X-flipped rectangle samples texel U0+1 first (ps1-tests texture-flip).
  var StartU := Integer(UV and $FF);
  var StepU := 1;
  if (FEnv.DrawMode and $1000) <> 0 then
  begin
    StepU := -1;
    Inc(StartU);
  end;
  var StepV := 1;
  if (FEnv.DrawMode and $2000) <> 0 then
    StepV := -1;
  var ColumnFirst := FLeft - X0;
  if ColumnFirst < 0 then
    ColumnFirst := 0;
  var ColumnLast := FRight - X0;
  if ColumnLast > Width - 1 then
    ColumnLast := Width - 1;
  for var Row := 0 to Height - 1 do
  begin
    var Y := Y0 + Row;
    if (Y < FTop) or (Y > FBottom) then
      Continue;
    Inc(Work, RowWork);
    if ((Y and 1) = SkipParity) or (ColumnFirst > ColumnLast) then
      Continue;
    Inc(Work, (ColumnLast - ColumnFirst + 1) * Mode.PixelWork);
    var V := (Integer((UV shr 8) and $FF) + Row * StepV) and $FF;
    for var Column := ColumnFirst to ColumnLast do
    begin
      var X := X0 + Column;
      var Texture: Word := 0;
      if Mode.Textured then
      begin
        Texture := Texel(Mode, (StartU + Column * StepU) and $FF, V);
        if Texture = 0 then
          Continue;
      end;
      Shade(Mode, X, Y, R, G, B, Texture);
    end;
  end;
end;

procedure TPS1Rasterizer.SerializeState(State: TStateArchive);
begin
  State.Field(FClut, SizeOf(FClut));
  State.Field(FClutCount, SizeOf(FClutCount));
  State.Field(FClutAttribute, SizeOf(FClutAttribute));
  if State.Loading and (FClutCount <> 0) and (FClutCount <> 16) and (FClutCount <> 256) then
    raise EReadError.Create('PS1 snapshot CLUT cache');
end;

end.

