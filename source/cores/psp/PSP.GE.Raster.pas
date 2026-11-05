unit PSP.GE.Raster;

// The GE back end: rasterization of points, lines, triangles and sprites
// and the pixel pipeline (texture, fog, tests, stencil, depth, blend,
// dither, logic op, masks). Everything here is a pure function of a
// TGERaster snapshot, the primitive's vertices and guest memory, so a
// primitive can be drawn by any thread for any band of rows, and the same
// integer arithmetic can run in a compute shader.
//
// Screen positions are 1/16 pixel fixed point relative to the drawing
// origin; a pixel is covered when its centre (x + 0.5, y + 0.5) is inside,
// with the top-left fill rule.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, PSP.Types, PSP.Memory, PSP.GE.Texture;

type
  TGEVertex = record
    X, Y: Integer;       // 1/16 pixel, drawing area
    Z: Integer;          // depth as computed (may be outside 0..65535)
    W: Single;           // 1/w for perspective (1 in through mode)
    R, G, B, A: Integer; // primary colour, 0..255
    SR, SG, SB: Integer; // secondary (specular) colour
    S, T: Single;        // texture coordinates in texels, still to divide by Q
    Q: Single;           // texture projection divisor (1 but for TEXMAPMODE's matrix)
    Fog: Single;         // 0 = fog colour, 1 = no fog
  end;
  PGEVertex = ^TGEVertex;

  TGERaster = record
    VRAM: PByte;
    FBAddr, FBStride, FBFormat: Cardinal;
    ZAddr, ZStride: Cardinal;
    ZPermutation: Integer;
    ScissorX1, ScissorY1, ScissorX2, ScissorY2: Integer;
    // Rows this pass may touch (a band for a render thread).
    BandY1, BandY2: Integer;
    Through: Boolean;
    ClearMode: Boolean;
    ClearColor, ClearStencil, ClearDepth: Boolean;
    Flat: Boolean;
    Gouraud: Boolean;
    // Lines: the fragment's alpha is the line's coverage (GELineCoverage).
    Antialias: Boolean;
    Textured: Boolean;
    Tex: TGETexture;
    TexFunc: Integer;
    TexAlpha: Boolean;
    ColorDouble: Boolean;
    EnvR, EnvG, EnvB: Integer;
    FogEnabled: Boolean;
    FogR, FogG, FogB: Integer;
    ColorTest: Boolean;
    ColorTestFunc: Integer;
    ColorRef, ColorMask: Cardinal;
    AlphaTest: Boolean;
    AlphaFunc, AlphaRef, AlphaMask: Integer;
    StencilTest: Boolean;
    StencilFunc, StencilRef, StencilMask: Integer;
    StencilFail, StencilZFail, StencilZPass: Integer;
    DepthTest: Boolean;
    DepthFunc: Integer;
    DepthWrite: Boolean;
    MinZ, MaxZ: Integer;
    DepthClamp: Boolean;
    Blend: Boolean;
    BlendOp, BlendSrc, BlendDst: Integer;
    FixA, FixB: Cardinal;
    Dither: Boolean;
    DitherMatrix: array[0..15] of Integer;
    LogicOp: Boolean;
    LogicFunc: Integer;
    MaskRGB: Cardinal;
    MaskA: Integer;
    // Derived by GEPrepareRaster: the pixel bits the masks keep; the blend
    // equation when it is a common one (1: source alpha, one minus source
    // alpha; 2: source alpha, fixed colour; both added), else 0.
    KeepMask: Cardinal;
    BlendKind: Integer;
  end;

var
  // Tests: every pixel through the generic pipeline, the reference for the
  // specialised ones.
  GEGenericPixels: Boolean;

// Fills in the fields derived from the others.
procedure GEPrepareRaster(var S: TGERaster);
procedure GEDrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
procedure GEDrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
procedure GEDrawLine(const S: TGERaster; const V0, V1: TGEVertex);
procedure GEDrawPoint(const S: TGERaster; const V: TGEVertex);
// A point's texture coordinates: the vertex's S/w, T/w and Q/w in 15-bit
// units and the perspective reciprocal, cut toward zero to 1/16 texel.
// Periodic coordinates are reduced before conversion to Single so large
// values keep their low bits (recorded on a PSP-E1000).
procedure GEPointUV(const S: TGERaster; const V: TGEVertex; out SS, TT: Single);
// A sprite's texture coordinate step per pixel: the difference over the
// length (in 1/16 pixels), truncated toward zero to single precision
// (recorded on a PSP-E1000: 12 texels over 7 pixels steps a hair under 12/7).
function GESpriteStep(D: Single; Len: Integer): Single;
// A vertex's fog factor as a triangle's fog plane takes it (recorded on a
// PSP-E1000): clamped to [0, 1] and rounded to 8 bits; the plane interpolates
// those like the colours.
function GEFogByte(F: Single): Integer;
// A pixel's texture level of detail in 1/16 levels by TEXLEVEL's mode: from
// the primitive's largest step of S and T times 1/w per pixel (G, in level 0
// texels) over the pixel's Q times 1/w (Q), from TEXLODSLOPE over 1/w (IW),
// or the bias alone.
function GETexLod(const S: TGERaster; G, Q, IW: Single): Integer;

type
  // A triangle's depth as the GE interpolates it (recorded on a PSP-E1000,
  // probe ge_zplane): from one vertex's depth (at AX, AY in 1/16
  // pixels) by steps per 1/16 pixel in x and y, fixed point with 14 fraction
  // bits; a pixel takes the floor at its centre. Valid is False where the
  // depths or the area are beyond the range this is exact in.
  TGEDepthPlane = record
    AX, AY, C0, GX, GY: Int64;
    Valid: Boolean;
  end;

procedure GEMakeDepthPlane(const V0, V1, V2: TGEVertex; out P: TGEDepthPlane);
// The same plane through three other values at the vertices (Gouraud
// colours, recorded on a PSP-E1000: gpu/exact's Gouraud plane jobs).
procedure GEMakeValuePlane(const V0, V1, V2: TGEVertex; C0, C1, C2: Int64; out P: TGEDepthPlane);
// The GE's reciprocal of an area's (or a length's) mantissa 1 + M16 / 2^16,
// in 2^-16.
function GEAreaRecip(M16: Integer): Int64;

type
  // A through-mode triangle's texture coordinates as planes (GEUVPlanes).
  TGEUVPlanes = record
    S, T: TGEDepthPlane;
    // The fraction bits of each, in texels.
    KS, KT: Integer;
  end;

type
  // Band-independent interpolation. Jobs retain values, never vertex pointers.
  TGEPreparedTriangle = record
    R, G, B, A, Fog, Depth: TGEDepthPlane;
    UV: TGEUVPlanes;
    HasUV: Boolean;
  end;
  PGEPreparedTriangle = ^TGEPreparedTriangle;

procedure GEPrepareTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex; out P: TGEPreparedTriangle);
procedure GEDrawPreparedTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex; const P: TGEPreparedTriangle);

// Recorded on a PSP-E1000 (probe ge_uv: 730,000 pixels of
// through-mode triangles over textures of 32 to 512 texels, 99.99%; the
// rest a texel up where the plane lands within a few thousandths of the
// next): S and T, over the level 0 width and height, truncated to 15
// fraction bits, are planes like the depth's (GEMakeValuePlane). False
// where the coordinates are beyond the range this is exact in.
function GEUVPlanes(const S: TGERaster; const V0, V1, V2: TGEVertex; out P: TGEUVPlanes): Boolean;
// A sprite's texture coordinates as the same planes (recorded on a
// PSP-E1000, probe ge_sprite: every sample of integer spans,
// 99.8% of fractional ones): a triangle of V0's corner and the corners beside
// it along x and y, so the steps come from the reciprocal of width times
// height. False where Q is not 1 or the planes are not exact.
function GESpriteUVPlanes(const S: TGERaster; const V0, V1: TGEVertex; out P: TGEUVPlanes): Boolean;
// A pixel's S and T (in texels, floored to 1/16) from GEUVPlanes'.
procedure GEUVAt(const P: TGEUVPlanes; PX, PY: Integer; out SS, TT: Single); inline;

type
  // A triangle's perspective texture coordinates as the GE makes them
  // (recorded on a PSP-E1000, probes ge_persp3, ge_stq2 and ge_persp: every
  // pixel where q or w differ from 1 with w at 1, 99.9% with w not 1): S and
  // T cut to 16 bits times 1/w, and Q times 1/w, are planes like the depth's
  // (GEMakeValuePlane) of the vertices' values in fixed point with 15 bits
  // up to the largest of each (truncated, K the fraction bits); at a pixel
  // each plane's value is floored to those units and S and T are multiplied
  // by the reciprocal of Q's (GEPerspRecip of its mantissa).
  TGEPerspPlanes = record
    S, T, Q: TGEDepthPlane;
    KS, KT, KQ: Integer;
  end;

function GEPerspPlanes(const V0, V1, V2: TGEVertex; out P: TGEPerspPlanes): Boolean;
// A transform-mode sprite's (recorded on a PSP-E1000, probe ge_stqs: every
// pixel of 512 sprites, q and w random): the triangle of V0's corner and the
// corners beside it, the one along S's axis with V1's S and Q (times V1's
// 1/w) and V0's T, the other with V1's T.
function GESpritePerspPlanes(const V0, V1: TGEVertex; out P: TGEPerspPlanes): Boolean;
// A pixel's S and T (in texels, floored to 1/16) from GEPerspPlanes'; False
// where Q's plane is not positive there.
function GEPerspAt(const P: TGEPerspPlanes; PX, PY: Integer; out SS, TT: Single): Boolean;
// The automatic level of detail's G from GEPerspPlanes': the largest step of
// S and T's planes per pixel, in texels.
function GEPerspLodG(const P: TGEPerspPlanes): Single;
// Its Q at a pixel: Q's plane floored to its units.
function GEPerspLodQ(const P: TGEPerspPlanes; PX, PY: Integer): Single;
// The pixel of each 4 in a row (x aligned to 4) whose Q and 1/w give the
// four their level of detail, as the GE walks a triangle (recorded on a
// PSP-E1000, probe ge_alod): the second from the left (1) where the middle
// vertex by y lies right of the long edge, else the second from the right
// (2); moved into the row's span where that pixel is outside it.
function GELodPixel(const V0, V1, V2: TGEVertex): Integer;
// The perspective divide's reciprocal of a mantissa 1 + M16 / 2^16 in 2^-16
// (recorded on a PSP-E1000, probe ge_persp3: 4,256 mantissas): 128 segments
// of 512, each a node in half units down by a drop per segment.
function GEPerspRecip(M16: Integer): Int64;
// A colour plane's channel where N (P.C0 plus the steps) is, 0..255.
function GEPlaneByte(N: Int64): Integer; inline;

type
  // The pixels a line covers, in order from its first vertex (GELineStart,
  // then GELineNext until False).
  TGELineWalk = record
    XMajor: Boolean;
    X0, Y0, X1, Y1: Int64;
    // Major and minor axis: start, step, the end on the major axis.
    M0, N0, DM, DN: Int64;
    Lo, Hi, P, Last, Step: Int64;
    // The first pixel drawn on the major axis and the pixel last given's
    // index from it.
    FirstP, K, Count: Int64;
  end;

function GELineStart(const V0, V1: TGEVertex; out W: TGELineWalk): Boolean;
// The next pixel and its position along the line (T in [0, 1], for the
// vertex values); False after the last.
function GELineNext(var W: TGELineWalk; out PX, PY: Integer; out T: Single): Boolean;
// A Gouraud line's colour channel at pixel (PX, PY), from C0 at the first
// vertex to C1 at the last.
function GELineColor(const W: TGELineWalk; PX, PY, C0, C1: Integer): Integer;
// An antialiased line's coverage of the pixel GELineNext gave last, 0..128.
function GELineCoverage(const W: TGELineWalk; PX, PY: Integer): Integer;

implementation

function GESpriteStep(D: Single; Len: Integer): Single;
begin
  var Q: Double := D / (Len / 16);
  Result := Q;
  if Abs(Double(Result)) > Abs(Q) then
    PCardinal(@Result)^ := PCardinal(@Result)^-1;
end;

type
  TGEFragment = record
    R, G, B, A: Integer;
    SR, SG, SB: Integer;
    Z: Integer;
    S, T: Single;
    Fog: Single;
    // Level of detail in 1/16 levels when the texture needs it.
    Lod: Integer;
  end;

// The level of detail (recorded on a PSP-E1000): both modes take two
// logarithms apart, each the exponent and 4 mantissa bits of its float. The
// automatic mode: log(G) - log(Q), G the primitive's largest step of S/w or
// T/w per pixel and Q the Q/w of GELodPixel's pixel (probe ge_alod: every
// pixel, through mode and perspective); the slope mode: log(slope) -
// log(1/w) (probe ge_lod: every sample), where 1/w is not
// positive slope times w.
function GETexLod(const S: TGERaster; G, Q, IW: Single): Integer;
begin
  case S.Tex.LevelMode of
    0:
      Result := GELog16(G) - GELog16(Q) + S.Tex.LodBias;
    2:
      if IW > 0 then
        Result := GELog16(S.Tex.Slope) - GELog16(IW) + 16 + S.Tex.LodBias
      else
      begin
        var W: Single := 1;
        if IW <> 0 then
          W := 1 / IW;
        Result := GELog16(S.Tex.Slope * W) + 16 + S.Tex.LodBias;
      end;
  else
    Result := S.Tex.LodBias;
  end;
end;

// Raster interpolants are bounded to signed 32 bits. Use the SSE conversion
// directly, with the same rounding mode as Round(), without its Int64 helper.
function GERound(X: Double): Integer;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  assembler;
{$ELSE}
  inline;
{$ENDIF}
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  .NOFRAME
  CVTSD2SI EAX, XMM0
end;
{$ELSE}
begin
  Result := Round(X);
end;
{$ENDIF}

// V is read once: the inliner would otherwise evaluate an argument
// expression for every use.
function Clamp255(V: Integer): Integer; inline;
begin
  Result := V;
  if Result < 0 then
    Result := 0
  else if Result > 255 then
    Result := 255;
end;

function TestFunc(Func, A, B: Integer): Boolean; inline;
begin
  case Func of
    0:
      Result := False;
    1:
      Result := True;
    2:
      Result := A = B;
    3:
      Result := A <> B;
    4:
      Result := A < B;
    5:
      Result := A <= B;
    6:
      Result := A > B;
    7:
      Result := A >= B;
  else
    Result := True;
  end;
end;

// The framebuffer's alpha bits as an 8-bit stencil value.
function StencilOf(Format, Pixel: Cardinal): Integer; inline;
begin
  case Format of
    1:
      Result := Ord((Pixel and $8000) <> 0) * 255;
    2:
      Result := (Pixel shr 12) * 17;
    3:
      Result := Pixel shr 24;
  else
    Result := 0;
  end;
end;

function StencilOp(Op, Format, Old, Ref: Integer): Integer;
begin
  // Values are in the format's own stencil precision.
  var Max: Integer;
  case Format of
    1:
      Max := 1;
    2:
      Max := 15;
    3:
      Max := 255;
  else
    Max := 0;
  end;
  case Op of
    0:
      Result := Old;
    1:
      Result := 0;
    2:
      case Format of
        1:
          Result := Ref shr 7;
        2:
          Result := Ref shr 4;
      else
        Result := Ref;
      end;
    3:
      Result := (not Old) and Max;
    4:
      if Old < Max then
        Result := Old + 1
      else
        Result := Max;
    5:
      if Old > 0 then
        Result := Old - 1
      else
        Result := 0;
  else
    Result := Old;
  end;
end;

function RawStencil(Format, Pixel: Cardinal): Integer; inline;
begin
  case Format of
    1:
      Result := (Pixel shr 15) and 1;
    2:
      Result := (Pixel shr 12) and $F;
    3:
      Result := Pixel shr 24;
  else
    Result := 0;
  end;
end;

// A colour times a factor as the GE's 8-bit units multiply (the lighting's
// Mul8): (2c + 1) (2f + 1) / 1024, truncated, so 255 counts as one.
function BlendMul(C, F: Integer): Integer; inline;
begin
  Result := ((2 * C + 1) * (2 * F + 1)) shr 10;
end;

// One side of the blend equation: a colour times its factor (BlendMul:
// source alpha over one minus it matches every one of 65,536 colour and alpha
// pairs on a PSP-E1000, gpu/exact's dither and 565 job); doubled factors
// double the product, "one minus double" factors clamp at zero.
function BlendTerm(Kind, C, Other, SA, DA, Fix: Integer): Integer; inline;
begin
  case Kind of
    0:
      Result := BlendMul(C, Other);
    1:
      Result := BlendMul(C, 255 - Other);
    2:
      Result := BlendMul(C, SA);
    3:
      Result := BlendMul(C, 255 - SA);
    4:
      Result := BlendMul(C, DA);
    5:
      Result := BlendMul(C, 255 - DA);
    6:
      Result := BlendMul(C, SA) * 2;
    7:
      Result := BlendMul(C, Max(0, 255 - 2 * SA));
    8:
      Result := BlendMul(C, DA) * 2;
    9:
      Result := BlendMul(C, Max(0, 255 - 2 * DA));
  else
    Result := BlendMul(C, Fix);
  end;
end;

function BlendChannel(const S: TGERaster; SC, DC, SA, DA, Shift: Integer): Integer; inline;
begin
  case S.BlendOp of
    0..2:
      begin
        var A := BlendTerm(S.BlendSrc, SC, DC, SA, DA, (S.FixA shr Shift) and $FF);
        var B := BlendTerm(S.BlendDst, DC, SC, SA, DA, (S.FixB shr Shift) and $FF);
        case S.BlendOp of
          0:
            Result := A + B;
          1:
            Result := A - B;
        else
          Result := B - A;
        end;
      end;
    3:
      Result := Min(SC, DC);
    4:
      Result := Max(SC, DC);
  else
    Result := Abs(SC - DC);
  end;
end;

procedure DecodePixel(Format, P: Cardinal; out R, G, B, A: Integer); inline;
begin
  case Format of
    0:
      begin
        R := P and $1F;
        R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $3F;
        G := (G shl 2) or (G shr 4);
        B := (P shr 11) and $1F;
        B := (B shl 3) or (B shr 2);
        A := 0;
      end;
    1:
      begin
        R := P and $1F;
        R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $1F;
        G := (G shl 3) or (G shr 2);
        B := (P shr 10) and $1F;
        B := (B shl 3) or (B shr 2);
        A := Ord((P and $8000) <> 0) * 255;
      end;
    2:
      begin
        R := (P and $F) * 17;
        G := ((P shr 4) and $F) * 17;
        B := ((P shr 8) and $F) * 17;
        A := ((P shr 12) and $F) * 17;
      end;
  else
    begin
      R := P and $FF;
      G := (P shr 8) and $FF;
      B := (P shr 16) and $FF;
      A := P shr 24;
    end;
  end;
end;

function EncodeColor(Format: Cardinal; R, G, B: Integer): Cardinal; inline;
begin
  case Format of
    0:
      Result := Cardinal(R shr 3) or (Cardinal(G shr 2) shl 5) or (Cardinal(B shr 3) shl 11);
    1:
      Result := Cardinal(R shr 3) or (Cardinal(G shr 3) shl 5) or (Cardinal(B shr 3) shl 10);
    2:
      Result := Cardinal(R shr 4) or (Cardinal(G shr 4) shl 4) or (Cardinal(B shr 4) shl 8);
  else
    Result := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
  end;
end;

function StencilBits(Format: Cardinal; V: Integer): Cardinal; inline;
begin
  case Format of
    1:
      Result := Cardinal(V and 1) shl 15;
    2:
      Result := Cardinal(V and $F) shl 12;
    3:
      Result := Cardinal(V and $FF) shl 24;
  else
    Result := 0;
  end;
end;

// Write mask of a pixel: 1 bits are kept from the old pixel.
function PixelKeepMask(const S: TGERaster): Cardinal;
begin
  var M := S.MaskRGB;
  var A := Cardinal(S.MaskA);
  case S.FBFormat of
    0:
      Result := ((M shr 3) and $1F) or (((M shr 10) and $3F) shl 5) or (((M shr 19) and $1F) shl 11);
    1:
      Result := ((M shr 3) and $1F) or (((M shr 11) and $1F) shl 5) or (((M shr 19) and $1F) shl 10) or
        ((A shr 7) shl 15);
    2:
      Result := ((M shr 4) and $F) or (((M shr 12) and $F) shl 4) or (((M shr 20) and $F) shl 8) or ((A shr 4) shl 12);
  else
    Result := (M and $FFFFFF) or (A shl 24);
  end;
end;

procedure GEPrepareRaster(var S: TGERaster);
begin
  S.KeepMask := PixelKeepMask(S);
  // The common blend equations, for the specialised pipelines (BlendTerm's
  // kinds 2 and 3, and 10-15 for the fixed colour, added).
  S.BlendKind := 0;
  if S.Blend and (S.BlendOp = 0) and (S.BlendSrc = 2) then
    if S.BlendDst = 3 then
      S.BlendKind := 1
    else if S.BlendDst >= 10 then
      S.BlendKind := 2;
  if S.Textured then
  begin
    if not S.Tex.PalValid then
      GEPreparePalette(S.Tex);
    GEPrepareSampler(S.Tex);
  end;
end;

// a * (255 - t) + b * t over 256, rounded up, doubled before the shift.
function TexLerp(A, B, T, Dbl: Integer): Integer; inline;
begin
  Result := Clamp255(((A * (255 - T) + B * T + 255) * Dbl) shr 8);
end;

// A colour times a texture colour: the colour counts as (c + 1) / 256.
function TexMul(C, T, Dbl: Integer): Integer; inline;
begin
  Result := Clamp255(((C + 1) * T * Dbl) shr 8);
end;

procedure ApplyTexture(const S: TGERaster; var F: TGEFragment);
var
  TR, TG, TB, TA: Integer;
begin
  var C: Cardinal;
  if S.Tex.NeedLod then
    C := GESampleTextureLod(S.Tex, F.S, F.T, F.Lod)
  else if Assigned(S.Tex.Sampler) and not GEGenericTexels then
    C := S.Tex.Sampler(@S.Tex, F.S, F.T)
  else
    C := GESampleTexture(S.Tex, F.S, F.T);
  TR := C and $FF;
  TG := (C shr 8) and $FF;
  TB := (C shr 16) and $FF;
  TA := C shr 24;
  var Dbl := 1;
  if S.ColorDouble then
    Dbl := 2;
  case S.TexFunc of
    0: // modulate
      begin
        F.R := TexMul(F.R, TR, Dbl);
        F.G := TexMul(F.G, TG, Dbl);
        F.B := TexMul(F.B, TB, Dbl);
        if S.TexAlpha then
          F.A := TexMul(F.A, TA, 1);
      end;
    1: // decal
      if S.TexAlpha then
      begin
        F.R := TexLerp(F.R, TR, TA, Dbl);
        F.G := TexLerp(F.G, TG, TA, Dbl);
        F.B := TexLerp(F.B, TB, TA, Dbl);
      end
      else
      begin
        F.R := Clamp255(TR * Dbl);
        F.G := Clamp255(TG * Dbl);
        F.B := Clamp255(TB * Dbl);
      end;
    2: // blend
      begin
        F.R := TexLerp(F.R, S.EnvR, TR, Dbl);
        F.G := TexLerp(F.G, S.EnvG, TG, Dbl);
        F.B := TexLerp(F.B, S.EnvB, TB, Dbl);
        if S.TexAlpha then
          F.A := TexMul(F.A, TA, 1);
      end;
    3: // replace
      begin
        F.R := Clamp255(TR * Dbl);
        F.G := Clamp255(TG * Dbl);
        F.B := Clamp255(TB * Dbl);
        if S.TexAlpha then
          F.A := TA;
      end;
  else // add
    begin
      F.R := Clamp255((F.R + TR) * Dbl);
      F.G := Clamp255((F.G + TG) * Dbl);
      F.B := Clamp255((F.B + TB) * Dbl);
      if S.TexAlpha then
        F.A := TexMul(F.A, TA, 1);
    end;
  end;
end;

procedure PlotPixel(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
var
  DR, DG, DB, DA: Integer;
begin
  if (X < S.ScissorX1) or (X > S.ScissorX2) or (Y < S.ScissorY1) or (Y > S.ScissorY2) then
    Exit;
  if (Y < S.BandY1) or (Y > S.BandY2) then
    Exit;
  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  var PAddr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * Bpp) and (PSPVRAMSize - 1);
  var ZAddr := PSPDepthOffset(S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X)) * 2, S.ZPermutation);
  var Old: Cardinal;
  if Bpp = 4 then
    Old := PCardinal(S.VRAM + PAddr)^
  else
    Old := PWord(S.VRAM + PAddr)^;
  var Z := F.Z;
  if Z < 0 then
    Z := 0;
  if Z > 65535 then
    Z := 65535;

  if S.ClearMode then
  begin
    var NewP := Old;
    var Keep := S.KeepMask;
    if S.ClearColor then
    begin
      var CR := F.R;
      var CG := F.G;
      var CB := F.B;
      if S.Dither then
      begin
        var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
        CR := Clamp255(CR + D);
        CG := Clamp255(CG + D);
        CB := Clamp255(CB + D);
      end;
      NewP := (NewP and not (EncodeColor(S.FBFormat, 255, 255, 255))) or EncodeColor(S.FBFormat, CR, CG, CB);
    end;
    if S.ClearStencil then
    begin
      var SV: Integer;
      case S.FBFormat of
        1:
          SV := F.A shr 7;
        2:
          SV := F.A shr 4;
      else
        SV := F.A;
      end;
      NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, SV);
    end;
    NewP := (NewP and not Keep) or (Old and Keep);
    if Bpp = 4 then
      PCardinal(S.VRAM + PAddr)^ := NewP
    else
      PWord(S.VRAM + PAddr)^ := Word(NewP);
    if S.ClearDepth then
      PWord(S.VRAM + ZAddr)^ := Word(Z);
    Exit;
  end;

  // The depth range test sees the depth clamped only with depth clamping on.
  if not S.Through then
    if S.DepthClamp then
    begin
      if (Z < S.MinZ) or (Z > S.MaxZ) then
        Exit;
    end
    else if (F.Z < S.MinZ) or (F.Z > S.MaxZ) then
      Exit;

  if S.Textured then
    ApplyTexture(S, F);

  // Secondary colour.
  F.R := Clamp255(F.R + F.SR);
  F.G := Clamp255(F.G + F.SG);
  F.B := Clamp255(F.B + F.SB);

  if S.FogEnabled then
  begin
    var Fg := F.Fog;
    if not (Fg > 0) then
      Fg := 0;
    if Fg > 1 then
      Fg := 1;
    var FI := Trunc(Fg * 255);
    F.R := TexLerp(S.FogR, F.R, FI, 1);
    F.G := TexLerp(S.FogG, F.G, FI, 1);
    F.B := TexLerp(S.FogB, F.B, FI, 1);
  end;

  if S.ColorTest then
  begin
    var C := Cardinal(F.R) or (Cardinal(F.G) shl 8) or (Cardinal(F.B) shl 16);
    var Pass: Boolean;
    case S.ColorTestFunc of
      0:
        Pass := False;
      1:
        Pass := True;
      2:
        Pass := (C and S.ColorMask) = (S.ColorRef and S.ColorMask);
    else
      Pass := (C and S.ColorMask) <> (S.ColorRef and S.ColorMask);
    end;
    if not Pass then
      Exit;
  end;

  if S.AlphaTest then
    if not TestFunc(S.AlphaFunc, F.A and S.AlphaMask, S.AlphaRef and S.AlphaMask) then
      Exit;

  var Stencil := RawStencil(S.FBFormat, Old);
  var NewStencil := Stencil;
  var StencilWrite := False;
  if S.StencilTest and (S.FBFormat <> 0) then
  begin
    var St8 := StencilOf(S.FBFormat, Old);
    if not TestFunc(S.StencilFunc, S.StencilRef and S.StencilMask, St8 and S.StencilMask) then
    begin
      NewStencil := StencilOp(S.StencilFail, S.FBFormat, Stencil, S.StencilRef);
      if NewStencil <> Stencil then
      begin
        var Keep := S.KeepMask;
        var NewP := (Old and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
        NewP := (NewP and not Keep) or (Old and Keep);
        if Bpp = 4 then
          PCardinal(S.VRAM + PAddr)^ := NewP
        else
          PWord(S.VRAM + PAddr)^ := Word(NewP);
      end;
      Exit;
    end;
    StencilWrite := True;
  end;

  if S.DepthTest then
  begin
    var OldZ := Integer(PWord(S.VRAM + ZAddr)^);
    if not TestFunc(S.DepthFunc, Z, OldZ) then
    begin
      if StencilWrite then
      begin
        NewStencil := StencilOp(S.StencilZFail, S.FBFormat, Stencil, S.StencilRef);
        if NewStencil <> Stencil then
        begin
          var Keep := S.KeepMask;
          var NewP := (Old and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
          NewP := (NewP and not Keep) or (Old and Keep);
          if Bpp = 4 then
            PCardinal(S.VRAM + PAddr)^ := NewP
          else
            PWord(S.VRAM + PAddr)^ := Word(NewP);
        end;
      end;
      Exit;
    end;
  end;
  if StencilWrite then
    NewStencil := StencilOp(S.StencilZPass, S.FBFormat, Stencil, S.StencilRef);
  if S.DepthWrite and S.DepthTest then
    PWord(S.VRAM + ZAddr)^ := Word(Z);

  var R := F.R;
  var G := F.G;
  var B := F.B;
  if S.Blend then
  begin
    DecodePixel(S.FBFormat, Old, DR, DG, DB, DA);
    if S.FBFormat = 0 then
      DA := 0;
    R := BlendChannel(S, F.R, DR, F.A, DA, 0);
    G := BlendChannel(S, F.G, DG, F.A, DA, 8);
    B := BlendChannel(S, F.B, DB, F.A, DA, 16);
  end;

  if S.Dither then
  begin
    var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
    R := R + D;
    G := G + D;
    B := B + D;
  end;
  R := Clamp255(R);
  G := Clamp255(G);
  B := Clamp255(B);

  var NewP := (Old and StencilBits(S.FBFormat, $FF)) or EncodeColor(S.FBFormat, R, G, B);
  if StencilWrite then
    NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or StencilBits(S.FBFormat, NewStencil);
  if S.LogicOp then
  begin
    var Src := NewP;
    case S.LogicFunc of
      0:
        NewP := 0;
      1:
        NewP := Src and Old;
      2:
        NewP := Src and not Old;
      3:
        NewP := Src;
      4:
        NewP := not Src and Old;
      5:
        NewP := Old;
      6:
        NewP := Src xor Old;
      7:
        NewP := Src or Old;
      8:
        NewP := not (Src or Old);
      9:
        NewP := not (Src xor Old);
      10:
        NewP := not Old;
      11:
        NewP := Src or not Old;
      12:
        NewP := not Src;
      13:
        NewP := not Src or Old;
      14:
        NewP := not (Src and Old);
    else
      NewP := $FFFFFFFF;
    end;
    // The stencil channel follows the stencil operation, not the logic op.
    NewP := (NewP and not StencilBits(S.FBFormat, $FF)) or (Src and StencilBits(S.FBFormat, $FF));
  end;
  var Keep := S.KeepMask;
  NewP := (NewP and not Keep) or (Old and Keep);
  if Bpp = 4 then
    PCardinal(S.VRAM + PAddr)^ := NewP
  else
    PWord(S.VRAM + PAddr)^ := Word(NewP);
end;

// Pixel pipelines specialised on target format, texture, blend and depth.
{$DEFINE GEPIX_565}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_565}
{$DEFINE GEPIX_5551}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_5551}
{$DEFINE GEPIX_4444}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_4444}
{$DEFINE GEPIX_8888}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_0(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_1(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_2(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_3(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_4(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_5(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_6(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_7(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_8888}
// The same with secondary colour, fog and the stencil test.
{$DEFINE GEPIX_EXTRA}
{$DEFINE GEPIX_565}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_0X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_1X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_2X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel565_3X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_4X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_5X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_6X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel565_7X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_565}
{$DEFINE GEPIX_5551}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_0X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_1X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_2X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel5551_3X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_4X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_5X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_6X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel5551_7X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_5551}
{$DEFINE GEPIX_4444}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_0X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_1X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_2X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel4444_3X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_4X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_5X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_6X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel4444_7X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_4444}
{$DEFINE GEPIX_8888}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_0X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_1X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_2X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
procedure Pixel8888_3X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_4X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_5X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_6X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$DEFINE GEPIX_TEXTURE}
{$DEFINE GEPIX_BLEND}
{$DEFINE GEPIX_DEPTH}
procedure Pixel8888_7X(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
{$I PSP.GE.Pixel.inc}

{$UNDEF GEPIX_8888}
{$UNDEF GEPIX_EXTRA}
{$UNDEF GEPIX_TEXTURE}
{$UNDEF GEPIX_BLEND}
{$UNDEF GEPIX_DEPTH}
type
  TGEPlotProc = procedure(const S: TGERaster; X, Y: Integer; var F: TGEFragment);

const
  PixelProcs: array[0..3, 0..7] of TGEPlotProc = (
    (Pixel565_0, Pixel565_1, Pixel565_2, Pixel565_3, Pixel565_4, Pixel565_5, Pixel565_6, Pixel565_7),
    (Pixel5551_0, Pixel5551_1, Pixel5551_2, Pixel5551_3, Pixel5551_4, Pixel5551_5, Pixel5551_6, Pixel5551_7),
    (Pixel4444_0, Pixel4444_1, Pixel4444_2, Pixel4444_3, Pixel4444_4, Pixel4444_5, Pixel4444_6, Pixel4444_7),
    (Pixel8888_0, Pixel8888_1, Pixel8888_2, Pixel8888_3, Pixel8888_4, Pixel8888_5, Pixel8888_6, Pixel8888_7));
  PixelProcsExtra: array[0..3, 0..7] of TGEPlotProc = (
    (Pixel565_0X, Pixel565_1X, Pixel565_2X, Pixel565_3X, Pixel565_4X, Pixel565_5X, Pixel565_6X, Pixel565_7X),
    (Pixel5551_0X, Pixel5551_1X, Pixel5551_2X, Pixel5551_3X, Pixel5551_4X, Pixel5551_5X, Pixel5551_6X, Pixel5551_7X),
    (Pixel4444_0X, Pixel4444_1X, Pixel4444_2X, Pixel4444_3X, Pixel4444_4X, Pixel4444_5X, Pixel4444_6X, Pixel4444_7X),
    (Pixel8888_0X, Pixel8888_1X, Pixel8888_2X, Pixel8888_3X, Pixel8888_4X, Pixel8888_5X, Pixel8888_6X, Pixel8888_7X));

// Specialise once per primitive. The generic path handles clearing, the
// colour test and logic operations.
function SelectPixel(const S: TGERaster; Secondary: Boolean): TGEPlotProc;
begin
  if S.ClearMode or S.ColorTest or S.LogicOp or GEGenericPixels then
  begin
    Result := PlotPixel;
    Exit;
  end;
  // A depth test that always passes and writes nothing has no effect.
  var Depth := S.DepthTest and ((S.DepthFunc <> 1) or S.DepthWrite);
  var Kind := Ord(S.Textured) or (Ord(S.Blend) shl 1) or (Ord(Depth) shl 2);
  if S.FogEnabled or Secondary or S.StencilTest then
    Result := PixelProcsExtra[S.FBFormat, Kind]
  else
    Result := PixelProcs[S.FBFormat, Kind];
end;

// A pixel through the texture cache's pipeline (S.Tex.Cache): the cache
// sees the bytes it replaces, then the pipeline it runs around draws it.
procedure CachedPixel(const S: TGERaster; X, Y: Integer; var F: TGEFragment);
begin
  var C := S.Tex.Cache;
  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  GETexCachePixel(C^, (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * Bpp) and (PSPVRAMSize - 1), Integer(Bpp),
    X, Y);
  TGEPlotProc(C.Plot)(S, X, Y, F);
  Inc(C.Clock);
end;

// Plot, or CachedPixel around it when the texture reads through the cache.
function CachePixels(const S: TGERaster; Plot: TGEPlotProc): TGEPlotProc;
begin
  Result := Plot;
  if S.Textured and (S.Tex.Cache <> nil) then
  begin
    GETexCacheStart(S.Tex.Cache^, S.Tex.CacheEpoch, S.VRAM);
    S.Tex.Cache.Plot := @Plot;
    Result := CachedPixel;
  end;
end;

// Clear-mode primitives of one colour and depth: the bits PlotPixel's clear
// path writes, the same in every pixel but for the dither matrix's 4x4
// pattern of colours.
type
  TGEClearFill = record
    Bits: array[0..15] of Cardinal;
    W: Cardinal;
    Z: Integer;
  end;

procedure ClearSetup(const S: TGERaster; R, G, B, A, Z: Integer; out C: TGEClearFill);
begin
  var Fmt := S.FBFormat;
  var SetMask: Cardinal := 0;
  var StencilSet: Cardinal := 0;
  if S.ClearColor then
    SetMask := EncodeColor(Fmt, 255, 255, 255);
  if S.ClearStencil then
  begin
    var SV: Integer;
    case Fmt of
      1:
        SV := A shr 7;
      2:
        SV := A shr 4;
    else
      SV := A;
    end;
    SetMask := SetMask or StencilBits(Fmt, $FF);
    StencilSet := StencilBits(Fmt, SV);
  end;
  C.W := SetMask and not S.KeepMask;
  for var I := 0 to 15 do
  begin
    var Bits := StencilSet;
    if S.ClearColor then
      if S.Dither then
      begin
        var D := S.DitherMatrix[I];
        Bits := Bits or EncodeColor(Fmt, Clamp255(R + D), Clamp255(G + D), Clamp255(B + D));
      end
      else
        Bits := Bits or EncodeColor(Fmt, R, G, B);
    C.Bits[I] := Bits and C.W;
  end;
  if Z < 0 then
    Z := 0;
  if Z > 65535 then
    Z := 65535;
  C.Z := Z;
end;

procedure ClearRow(const S: TGERaster; const C: TGEClearFill; X1, X2, Y: Integer);
begin
  var W := C.W;
  if W <> 0 then
  begin
    var Row := (Y and 3) * 4;
    if S.FBFormat = 3 then
    begin
      var A := S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X1)) * 4;
      for var X := X1 to X2 do
      begin
        var P := PCardinal(S.VRAM + (A and (PSPVRAMSize - 1)));
        P^ := (P^ and not W) or C.Bits[Row + (X and 3)];
        Inc(A, 4);
      end;
    end
    else
    begin
      var A := S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X1)) * 2;
      for var X := X1 to X2 do
      begin
        var P := PWord(S.VRAM + (A and (PSPVRAMSize - 1)));
        P^ := Word((P^ and not W) or C.Bits[Row + (X and 3)]);
        Inc(A, 2);
      end;
    end;
  end;
  if S.ClearDepth then
  begin
    var A := S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X1)) * 2;
    for var X := X1 to X2 do
    begin
      PWord(S.VRAM + PSPDepthOffset(A, S.ZPermutation))^ := Word(C.Z);
      Inc(A, 2);
    end;
  end;
end;

procedure ClearRect(const S: TGERaster; X1, Y1, X2, Y2: Integer; const V: TGEVertex);
var
  C: TGEClearFill;
begin
  ClearSetup(S, V.R, V.G, V.B, V.A, V.Z, C);
  for var Y := Y1 to Y2 do
    ClearRow(S, C, X1, X2, Y);
end;

procedure SetupFragment(var F: TGEFragment; const V: TGEVertex); inline;
begin
  F.R := V.R;
  F.G := V.G;
  F.B := V.B;
  F.A := V.A;
  F.SR := V.SR;
  F.SG := V.SG;
  F.SB := V.SB;
  F.Z := V.Z;
  F.S := V.S;
  F.T := V.T;
  F.Fog := V.Fog;
  F.Lod := 0;
end;

// Intersect a row's x interval with E + Step * (x - Origin) >= 0.
procedure EdgeSpan(E, Step: Int64; Origin: Integer; var Lo, Hi: Integer); inline;
begin
  if Step > 0 then
  begin
    var N := -E;
    var Q := N div Step;
    if (N > 0) and (N mod Step <> 0) then
      Inc(Q);
    if Origin + Q > Lo then
      Lo := Origin + Q;
  end
  else if Step < 0 then
  begin
    var D := -Step;
    var Q := E div D;
    if (E < 0) and (E mod D <> 0) then
      Dec(Q);
    if Origin + Q < Hi then
      Hi := Origin + Q;
  end
  else if E < 0 then
    Hi := Lo - 1;
end;

// Floor of V / 2^S.
function FloorShr(V: Int64; S: Integer): Int64; inline;
begin
  if V >= 0 then
    Result := V shr S
  else
    Result := -((-V - 1) shr S) - 1;
end;

// The vertex the depth plane starts from: of the vertices at the ends in x
// (a tie going to the upper one) and in y (a tie to the left one), the one
// not between the others on either axis; where two are, the third vertex's
// side of the line through them picks one. Recorded on a PSP-E1000: every
// triangle of ge_zplane whose plane goes through one vertex only.
function DepthAnchor(const X, Y: array of Int64): Integer;
begin
  var XMin := 0;
  var XMax := 0;
  var YMin := 0;
  var YMax := 0;
  for var I := 1 to 2 do
  begin
    if (X[I] < X[XMin]) or ((X[I] = X[XMin]) and (Y[I] < Y[XMin])) then
      XMin := I;
    if (X[I] > X[XMax]) or ((X[I] = X[XMax]) and (Y[I] < Y[XMax])) then
      XMax := I;
    if (Y[I] < Y[YMin]) or ((Y[I] = Y[YMin]) and (X[I] < X[YMin])) then
      YMin := I;
    if (Y[I] > Y[YMax]) or ((Y[I] = Y[YMax]) and (X[I] < X[YMax])) then
      YMax := I;
  end;
  var MX := 3 - XMin - XMax;
  var MY := 3 - YMin - YMax;
  if MX <> MY then
    Exit(3 - MX - MY);
  // Two candidates: C1 the left one (the upper of a column), C2 the other.
  var C1 := (MX + 1) mod 3;
  var C2 := (MX + 2) mod 3;
  if (X[C2] < X[C1]) or ((X[C2] = X[C1]) and (Y[C2] < Y[C1])) then
  begin
    var T := C1;
    C1 := C2;
    C2 := T;
  end;
  var Cross := (X[C2] - X[C1]) * (Y[MX] - Y[C1]) - (Y[C2] - Y[C1]) * (X[MX] - X[C1]);
  if (Cross > 0) = (Y[C1] <= Y[C2]) then
    Result := C2
  else
    Result := C1;
end;

// The GE's reciprocal of a triangle's area (recorded on a PSP-E1000,
// probe ge_recip: every one of the 2^16 mantissas): for the
// area's mantissa 1 + M16 / 2^16, 2^16 over it from a table of 256 segments
// of M16, each from its node 2^27 / (256 + J) (in 2^-11) down by the slope
// 2^24 / (256 + J)^2 a step of M16 (in 2^-8), both floored, the sum floored
// to an integer. Floor(2^32 / (2^16 + M16)) is one off for a fifth of them.
function GEAreaRecip(M16: Integer): Int64;
begin
  var J := M16 shr 8;
  var Node := (Int64(1) shl 27) div (256 + J);
  var Slope := (Int64(1) shl 24) div ((256 + J) * (256 + J));
  Result := (Node * 32 - Slope * (M16 and 255)) shr 8;
end;

procedure GEMakeDepthPlane(const V0, V1, V2: TGEVertex; out P: TGEDepthPlane);
begin
  GEMakeValuePlane(V0, V1, V2, V0.Z, V1.Z, V2.Z, P);
end;

function GEUVPlanes(const S: TGERaster; const V0, V1, V2: TGEVertex; out P: TGEUVPlanes): Boolean;

  function Log2(N: Integer): Integer;
  begin
    Result := 0;
    while (1 shl (Result + 1)) <= N do
      Inc(Result);
  end;

  function Fixed(V: Single; K: Integer; out R: Int64): Boolean;
  begin
    var D := Double(V) * (Int64(1) shl K);
    Result := (D > -(Int64(1) shl 24)) and (D < (Int64(1) shl 24));
    if Result then
      R := Trunc(D);
  end;

begin
  // (Through mode: Q is 1.)
  Result := (V0.Q = 1) and (V1.Q = 1) and (V2.Q = 1);
  if not Result then
    Exit;
  P.KS := 15 - Log2(Max(S.Tex.Levels[0].Width, 1));
  P.KT := 15 - Log2(Max(S.Tex.Levels[0].Height, 1));
  var S0, S1, S2, T0, T1, T2: Int64;
  Result := Fixed(V0.S, P.KS, S0) and Fixed(V1.S, P.KS, S1) and Fixed(V2.S, P.KS, S2) and Fixed(V0.T, P.KT, T0) and
    Fixed(V1.T, P.KT, T1) and Fixed(V2.T, P.KT, T2);
  if not Result then
    Exit;
  GEMakeValuePlane(V0, V1, V2, S0, S1, S2, P.S);
  GEMakeValuePlane(V0, V1, V2, T0, T1, T2, P.T);
  Result := P.S.Valid and P.T.Valid;
end;

function GESpriteUVPlanes(const S: TGERaster; const V0, V1: TGEVertex; out P: TGEUVPlanes): Boolean;
begin
  Result := (V0.Q = 1) and (V1.Q = 1) and (V0.X <> V1.X) and (V0.Y <> V1.Y);
  if not Result then
    Exit;
  // A: V0's corner, B along x, C along y. S runs along x and T along y,
  // except when the corners are flipped in one axis only (GEDrawSprite).
  var A := V0;
  var B := V0;
  var C := V0;
  B.X := V1.X;
  C.Y := V1.Y;
  if (V0.X > V1.X) <> (V0.Y > V1.Y) then
  begin
    B.T := V1.T;
    C.S := V1.S;
  end
  else
  begin
    B.S := V1.S;
    C.T := V1.T;
  end;
  Result := GEUVPlanes(S, A, B, C, P);
end;

procedure GEUVAt(const P: TGEUVPlanes; PX, PY: Integer; out SS, TT: Single);
begin
  var DX := Int64(PX) * 16 + 8 - P.S.AX;
  var DY := Int64(PY) * 16 + 8 - P.S.AY;
  SS := FloorShr(P.S.C0 + P.S.GX * DX + P.S.GY * DY, 10 + P.KS) / 16;
  TT := FloorShr(P.T.C0 + P.T.GX * DX + P.T.GY * DY, 10 + P.KT) / 16;
end;

const
  // The last segment also takes ge_persp3's boundary mantissa (65024):
  // node 65793 and drop 128, where the interior samples alone allowed
  // 65792 and 127. The full probe then matches in every RGB pixel.
  GEPerspRecipNode: array[0..127] of Integer = (
    131073, 130056, 129055, 128072, 127100, 126144, 125204, 124275, 123362, 122462, 121575, 120701,
    119837, 118987, 118151, 117324, 116509, 115705, 114914, 114131, 113359, 112600, 111848, 111108,
    110376, 109655, 108944, 108240, 107546, 106862, 106185, 105518, 104859, 104207, 103564, 102928,
    102301, 101681, 101068, 100464, 99866, 99274, 98690, 98114, 97543, 96978, 96422, 95870,
    95327, 94787, 94256, 93728, 93207, 92692, 92183, 91681, 91181, 90689, 90202, 89718,
    89241, 88770, 88303, 87839, 87382, 86929, 86482, 86038, 85600, 85165, 84733, 84308,
    83886, 83469, 83056, 82647, 82242, 81840, 81443, 81050, 80660, 80276, 79893, 79514,
    79139, 78767, 78399, 78034, 77674, 77316, 76961, 76609, 76261, 75915, 75575, 75235,
    74899, 74565, 74237, 73909, 73585, 73265, 72945, 72629, 72317, 72006, 71698, 71394,
    71091, 70790, 70494, 70198, 69907, 69616, 69328, 69043, 68760, 68480, 68201, 67926,
    67651, 67379, 67110, 66842, 66578, 66313, 66053, 65793);
  GEPerspRecipDrop: array[0..127] of SmallInt = (
    508, 500, 492, 486, 478, 470, 464, 456, 450, 444, 438, 432, 424, 418, 414, 408,
    402, 396, 392, 386, 380, 376, 370, 366, 360, 356, 352, 346, 342, 338, 334, 330,
    326, 322, 318, 314, 310, 306, 302, 300, 296, 292, 288, 286, 282, 278, 276, 272,
    270, 266, 264, 260, 257, 254, 252, 250, 246, 244, 242, 238, 236, 234, 232, 228,
    226, 224, 222, 220, 218, 216, 212, 210, 208, 206, 204, 202, 200, 198, 196, 194,
    192, 192, 190, 188, 186, 184, 182, 180, 180, 178, 176, 174, 172, 170, 170, 168,
    166, 164, 164, 162, 160, 160, 158, 156, 156, 154, 152, 152, 150, 148, 148, 146,
    146, 144, 142, 142, 140, 140, 138, 138, 136, 134, 134, 132, 132, 129, 130, 128);

function GEPerspRecip(M16: Integer): Int64;
begin
  var J := M16 shr 9;
  Result := (256 * Int64(GEPerspRecipNode[J]) - 1 - Int64(GEPerspRecipDrop[J]) * (M16 and 511)) shr 9;
end;

// V cut to 16 significant bits (toward zero).
function GEPerspCut16(V: Double): Double;
begin
  if V = 0 then
    Exit(0);
  var M: Extended;
  var E: Integer;
  Frexp(V, M, E);
  Result := Ldexp(Trunc(M * 65536), E - 16);
end;

// One of GEPerspPlanes' planes: A, B, C in fixed point with K fraction bits,
// the largest in magnitude taking 15 bits.
function GEPerspPlane(const V0, V1, V2: TGEVertex; A, B, C: Double; out P: TGEDepthPlane; out K: Integer): Boolean;
begin
  var Top := Max(Abs(A), Max(Abs(B), Abs(C)));
  K := 0;
  if Top = 0 then
    GEMakeValuePlane(V0, V1, V2, 0, 0, 0, P)
  else
  begin
    var M: Extended;
    var E: Integer;
    Frexp(Top, M, E);
    K := 15 - E;
    // Truncated toward zero (gpu/texmtx/negq's negative S and T).
    GEMakeValuePlane(V0, V1, V2, Trunc(Ldexp(A, K)), Trunc(Ldexp(B, K)), Trunc(Ldexp(C, K)), P);
  end;
  Result := P.Valid;
end;

function GEPerspPlanes(const V0, V1, V2: TGEVertex; out P: TGEPerspPlanes): Boolean;
begin
  // The products are exact in a Double (16 bits by 1/w's 17, Q's 24 by 17).
  Result := GEPerspPlane(V0, V1, V2, Double(V0.Q) * V0.W, Double(V1.Q) * V1.W, Double(V2.Q) * V2.W, P.Q, P.KQ) and
    GEPerspPlane(V0, V1, V2, GEPerspCut16(V0.S) * V0.W, GEPerspCut16(V1.S) * V1.W, GEPerspCut16(V2.S) * V2.W, P.S,
    P.KS) and GEPerspPlane(V0, V1, V2, GEPerspCut16(V0.T) * V0.W, GEPerspCut16(V1.T) * V1.W,
    GEPerspCut16(V2.T) * V2.W, P.T, P.KT);
end;

function GESpritePerspPlanes(const V0, V1: TGEVertex; out P: TGEPerspPlanes): Boolean;
begin
  Result := (V0.X <> V1.X) and (V0.Y <> V1.Y);
  if not Result then
    Exit;
  // A: V0's corner, B along x, C along y, as GESpriteUVPlanes.
  var A := V0;
  var B := V0;
  var C := V0;
  B.X := V1.X;
  C.Y := V1.Y;
  var SW0 := GEPerspCut16(V0.S) * V0.W;
  var SW1 := GEPerspCut16(V1.S) * V1.W;
  var TW0 := GEPerspCut16(V0.T) * V0.W;
  var TW1 := GEPerspCut16(V1.T) * V1.W;
  var QW0 := Double(V0.Q) * V0.W;
  var QW1 := Double(V1.Q) * V1.W;
  // The corner along S's axis takes V1's S and Q (each times its own 1/w),
  // the one along T's V1's T.
  if (V0.X > V1.X) <> (V0.Y > V1.Y) then
    Result := GEPerspPlane(A, B, C, SW0, SW0, SW1, P.S, P.KS) and GEPerspPlane(A, B, C, TW0, TW1, TW0, P.T, P.KT) and
      GEPerspPlane(A, B, C, QW0, QW0, QW1, P.Q, P.KQ)
  else
    Result := GEPerspPlane(A, B, C, SW0, SW1, SW0, P.S, P.KS) and GEPerspPlane(A, B, C, TW0, TW0, TW1, P.T, P.KT) and
      GEPerspPlane(A, B, C, QW0, QW1, QW0, P.Q, P.KQ);
end;

function GEPerspAt(const P: TGEPerspPlanes; PX, PY: Integer; out SS, TT: Single): Boolean;

  // N R 2^-Sh, truncated toward zero (gpu/texmtx/negq; Sh may be negative).
  function Scaled(N: Int64; Sh: Integer): Int64;
  begin
    if Sh < 0 then
      Result := N shl (-Sh)
    else if N >= 0 then
      Result := N shr Sh
    else
      Result := -((-N) shr Sh);
  end;

begin
  var DX := Int64(PX) * 16 + 8 - P.Q.AX;
  var DY := Int64(PY) * 16 + 8 - P.Q.AY;
  var D := FloorShr(P.Q.C0 + P.Q.GX * DX + P.Q.GY * DY, 14);
  Result := (D > 0) and (D < 65536);
  if not Result then
    Exit;
  var E := 0;
  while (D shr (E + 1)) <> 0 do
    Inc(E);
  var R := GEPerspRecip(Integer((D shl (16 - E)) - 65536));
  var NS := FloorShr(P.S.C0 + P.S.GX * (Int64(PX) * 16 + 8 - P.S.AX) + P.S.GY * (Int64(PY) * 16 + 8 - P.S.AY), 14);
  var NT := FloorShr(P.T.C0 + P.T.GX * (Int64(PX) * 16 + 8 - P.T.AX) + P.T.GY * (Int64(PY) * 16 + 8 - P.T.AY), 14);
  // In texels: N R 2^(KQ - K - 16 - E), floored to 1/16.
  SS := Scaled(NS * R, 12 + E + P.KS - P.KQ) / 16;
  TT := Scaled(NT * R, 12 + E + P.KT - P.KQ) / 16;
end;

function GEPerspLodG(const P: TGEPerspPlanes): Single;
begin
  // A step is 2^-14 units per 1/16 pixel.
  Result := Max(Ldexp(Max(Abs(P.S.GX), Abs(P.S.GY)), -10 - P.KS), Ldexp(Max(Abs(P.T.GX), Abs(P.T.GY)), -10 - P.KT));
end;

function GEPerspLodQ(const P: TGEPerspPlanes; PX, PY: Integer): Single;
begin
  var D := FloorShr(P.Q.C0 + P.Q.GX * (Int64(PX) * 16 + 8 - P.Q.AX) + P.Q.GY * (Int64(PY) * 16 + 8 - P.Q.AY), 14);
  Result := Ldexp(D, -P.KQ);
end;

function GELodPixel(const V0, V1, V2: TGEVertex): Integer;

  // Whether A comes before B by y, then x.
  function Before(const A, B: TGEVertex): Boolean;
  begin
    Result := (A.Y < B.Y) or ((A.Y = B.Y) and (A.X < B.X));
  end;

var
  T, M, B, C: PGEVertex;
begin
  T := @V0;
  M := @V1;
  B := @V2;
  if Before(M^, T^) then
  begin
    C := T;
    T := M;
    M := C;
  end;
  if Before(B^, M^) then
  begin
    C := M;
    M := B;
    B := C;
  end;
  if Before(M^, T^) then
  begin
    C := T;
    T := M;
    M := C;
  end;
  // Negative: the middle vertex is left of the long edge (y down).
  var Side := (Int64(M.X) - T.X) * (Int64(B.Y) - T.Y) - (Int64(M.Y) - T.Y) * (Int64(B.X) - T.X);
  if Side < 0 then
    Result := 2
  else
    Result := 1;
end;

function GEPlaneByte(N: Int64): Integer;
begin
  if N < 0 then
    Exit(0);
  Result := N shr 14;
  if Result > 255 then
    Result := 255;
end;

procedure GEMakeValuePlane(const V0, V1, V2: TGEVertex; C0, C1, C2: Int64; out P: TGEDepthPlane);
begin
  P := Default(TGEDepthPlane);
  var X: array[0..2] of Int64;
  var Y: array[0..2] of Int64;
  var Z: array[0..2] of Int64;
  X[0] := V0.X;
  Y[0] := V0.Y;
  Z[0] := C0;
  X[1] := V1.X;
  Y[1] := V1.Y;
  Z[1] := C1;
  X[2] := V2.X;
  Y[2] := V2.Y;
  Z[2] := C2;
  var Area := (X[1] - X[0]) * (Y[2] - Y[0]) - (Y[1] - Y[0]) * (X[2] - X[0]);
  // dz/dx and dz/dy times the area.
  var NX := -(Z[0] * (Y[2] - Y[1]) + Z[1] * (Y[0] - Y[2]) + Z[2] * (Y[1] - Y[0]));
  var NY := Z[0] * (X[2] - X[1]) + Z[1] * (X[0] - X[2]) + Z[2] * (X[1] - X[0]);
  if Area < 0 then
  begin
    Area := -Area;
    NX := -NX;
    NY := -NY;
  end;
  P.Valid := (Area > 0) and (Area < (Int64(1) shl 34));
  for var I := 0 to 2 do
    if Abs(Z[I]) >= 1 shl 20 then
      P.Valid := False;
  if not P.Valid then
    Exit;
  // 1/area to 16 bits from the area's top 17 (GEAreaRecip of its mantissa's
  // 16 fraction bits); the steps are N times it, floored to 2^-14.
  var E := 63;
  while (Area shr E) = 0 do
    Dec(E);
  var M16: Int64;
  if E >= 16 then
    M16 := (Area shr (E - 16)) - 65536
  else
    M16 := (Area shl (16 - E)) - 65536;
  var R := GEAreaRecip(Integer(M16));
  P.GX := FloorShr(NX * R, E + 2);
  P.GY := FloorShr(NY * R, E + 2);
  var A := DepthAnchor(X, Y);
  P.AX := X[A];
  P.AY := Y[A];
  P.C0 := Z[A] shl 14;
end;

// Floor of A / B (B <> 0).
function FloorDiv64(A, B: Int64): Int64; inline;
begin
  if B < 0 then
  begin
    A := -A;
    B := -B;
  end;
  Result := A div B;
  if (A mod B) < 0 then
    Dec(Result);
end;

// Lines (recorded on a PSP-E1000, probe ge_line: every one of
// 8,192 lines, and gpu/exact's line jobs): a pixel is drawn when the line
// leaves its diamond (|x - cx| + |y - cy| < 1/2 pixel round the centre): the
// first vertex inside it and the last not, or the line crossing it with
// neither end inside. A point on a diamond's edge counts as inside when it
// lies above the centre (x-major lines, |dx| > |dy|) or left of it (y-major).
// On each step of the major axis the line meets one diamond: the one on the
// row (column) the line is in at the pixel centre.
function LineMember(PX, PY, X, Y: Int64; XMajor: Boolean): Boolean; inline;
begin
  var A := X - (PX * 16 + 8);
  var B := Y - (PY * 16 + 8);
  var D := Abs(A) + Abs(B);
  if D <> 8 then
    Exit(D < 8);
  if XMajor then
    Result := B < 0
  else
    Result := A < 0;
end;

function GELineStart(const V0, V1: TGEVertex; out W: TGELineWalk): Boolean;
begin
  W.X0 := V0.X;
  W.Y0 := V0.Y;
  W.X1 := V1.X;
  W.Y1 := V1.Y;
  var DX := W.X1 - W.X0;
  var DY := W.Y1 - W.Y0;
  Result := (DX <> 0) or (DY <> 0);
  if not Result then
    Exit;
  W.XMajor := Abs(DX) > Abs(DY);
  if W.XMajor then
  begin
    W.M0 := W.X0;
    W.N0 := W.Y0;
    W.DM := DX;
    W.DN := DY;
    W.Lo := Min(W.X0, W.X1);
    W.Hi := Max(W.X0, W.X1);
  end
  else
  begin
    W.M0 := W.Y0;
    W.N0 := W.X0;
    W.DM := DY;
    W.DN := DX;
    W.Lo := Min(W.Y0, W.Y1);
    W.Hi := Max(W.Y0, W.Y1);
  end;
  if W.DM > 0 then
    W.Step := 1
  else
    W.Step := -1;
  // From the pixel before the first vertex's to the one after the last's.
  W.P := FloorDiv64(W.M0, 16) - W.Step;
  W.Last := FloorDiv64(W.M0 + W.DM, 16) + W.Step;
  W.FirstP := 0;
  W.K := 0;
  W.Count := 0;
end;

function GELineNext(var W: TGELineWalk; out PX, PY: Integer; out T: Single): Boolean;
begin
  while W.P <> W.Last + W.Step do
  begin
    var P := W.P;
    Inc(W.P, W.Step);
    var C := P * 16 + 8;
    var Q := FloorDiv64(W.N0 * W.DM + W.DN * (C - W.M0), 16 * W.DM);
    var X, Y: Int64;
    if W.XMajor then
    begin
      X := P;
      Y := Q;
    end
    else
    begin
      X := Q;
      Y := P;
    end;
    var InA := LineMember(X, Y, W.X0, W.Y0, W.XMajor);
    var InB := LineMember(X, Y, W.X1, W.Y1, W.XMajor);
    if (InA and not InB) or (not InA and not InB and (C > W.Lo) and (C < W.Hi)) then
    begin
      if W.Count = 0 then
        W.FirstP := P;
      W.K := W.Count;
      Inc(W.Count);
      PX := X;
      PY := Y;
      T := (C - W.M0) / W.DM;
      if not (T > 0) then
        T := 0;
      if T > 1 then
        T := 1;
      Exit(True);
    end;
  end;
  Result := False;
end;

// Recorded on a PSP-E1000 (gpu/exact's Gouraud line jobs: 99.9% of the
// channels): the step per pixel along the major axis is (C1 - C0) * 16 times
// 1/length (the length in 1/16 pixels, its reciprocal floored to 24 bits
// below its leading one), floored to 12 fraction bits; a pixel's value is C0
// plus the step times its centre's distance from the first vertex along the
// line, floored, then clamped to 0..255.
// The GE's reciprocal of a line's length L (1/16 pixels) as of an area
// (GEAreaRecip): about 2^(16 + E) / L.
function LineRecip(L: Int64; out E: Integer): Int64;
begin
  E := 0;
  while (L shr (E + 1)) <> 0 do
    Inc(E);
  var M16: Int64;
  if E >= 16 then
    M16 := (L shr (E - 16)) - 65536
  else
    M16 := (L shl (16 - E)) - 65536;
  Result := GEAreaRecip(Integer(M16));
end;

function GELineColor(const W: TGELineWalk; PX, PY, C0, C1: Integer): Integer;
begin
  var E: Integer;
  var R := LineRecip(Abs(W.DM), E);
  var Step := FloorShr(Int64(C1 - C0) * 16 * R * 1024, 16 + E);
  var C: Int64;
  if W.XMajor then
    C := Int64(PX) * 16 + 8
  else
    C := Int64(PY) * 16 + 8;
  // The distance in the direction of travel.
  var D := (C - W.M0) * W.Step;
  Result := FloorShr(Int64(C0) * 1024 + FloorShr(Step * D, 4), 10);
  if Result < 0 then
    Result := 0;
  if Result > 255 then
    Result := 255;
end;

// Recorded on a PSP-E1000 (ge_line's antialiased set: every one of 21,297
// pixels; gpu/exact's antialiased jobs): the line's position on the minor
// axis comes from the first vertex and a step per major 1/16 pixel, both in
// 2^-18 of 1/16 pixel, the step rounded up; X, its offset into the pixel in
// 1/256 pixel rounded up, gives the coverage X up to the middle and 256 - X
// past it.
function GELineCoverage(const W: TGELineWalk; PX, PY: Integer): Integer;
begin
  // The slope (minor per major 1/16 pixel) in 2^-18 from the length's
  // reciprocal, rounded toward +infinity; the position at the pixel centre.
  var E: Integer;
  var R := LineRecip(Abs(W.DM), E);
  var V := W.DN * R * (1 shl 18);
  var Step := -FloorShr(-V, 16 + E);
  var C: Int64;
  var Q: Int64;
  if W.XMajor then
  begin
    C := Int64(PX) * 16 + 8;
    Q := PY;
  end
  else
  begin
    C := Int64(PY) * 16 + 8;
    Q := PX;
  end;
  var Pos := (W.N0 shl 18) + Step * (C - W.M0) * W.Step;
  var X := -FloorShr(-(Pos - Q * 16 * (1 shl 18)) * 16, 18);
  if X > 128 then
    X := 256 - X;
  Result := Max(0, Min(255, X));
end;

function GEFogByte(F: Single): Integer;
begin
  if not (F > 0) then
    Exit(0);
  if F >= 1 then
    Exit(255);
  Result := Trunc(F * 255 + 0.5);
end;

procedure GEPrepareTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex; out P: TGEPreparedTriangle);
begin
  P := Default(TGEPreparedTriangle);
  if S.Gouraud and not S.Flat then
  begin
    GEMakeValuePlane(V0, V1, V2, V0.R, V1.R, V2.R, P.R);
    GEMakeValuePlane(V0, V1, V2, V0.G, V1.G, V2.G, P.G);
    GEMakeValuePlane(V0, V1, V2, V0.B, V1.B, V2.B, P.B);
    GEMakeValuePlane(V0, V1, V2, V0.A, V1.A, V2.A, P.A);
  end;
  if S.FogEnabled then
    GEMakeValuePlane(V0, V1, V2, GEFogByte(V0.Fog), GEFogByte(V1.Fog), GEFogByte(V2.Fog), P.Fog);
  if (V0.Z <> V1.Z) or (V0.Z <> V2.Z) then
    GEMakeDepthPlane(V0, V1, V2, P.Depth);
  P.HasUV := S.Textured and S.Through and GEUVPlanes(S, V0, V1, V2, P.UV);
end;

procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex; Prepared: PGEPreparedTriangle);
var
  F: TGEFragment;
begin
{$I PSP.GE.TriangleSetup.inc}
  // Edge functions for edges opposite each vertex. E_i >= 0 inside. Top-left
  // rule: pixels exactly on an edge belong to it only when the edge is a top
  // or left edge.
  var DX0 := X2 - X1;
  var DY0 := Y2 - Y1; // edge 1->2, opposite V0
  var DX1 := X0 - X2;
  var DY1 := Y0 - Y2; // edge 2->0, opposite V1
  var DX2 := X1 - X0;
  var DY2 := Y1 - Y0; // edge 0->1, opposite V2
  var Bias0: Int64 := 0;
  var Bias1: Int64 := 0;
  var Bias2: Int64 := 0;
  // With y down and positive area the triangle is clockwise on screen; an edge
  // is top-left when it goes up (dy < 0) or is horizontal going right (dy = 0, dx > 0).
  if not ((DY0 < 0) or ((DY0 = 0) and (DX0 > 0))) then
    Bias0 := -1;
  if not ((DY1 < 0) or ((DY1 = 0) and (DX1 > 0))) then
    Bias1 := -1;
  if not ((DY2 < 0) or ((DY2 = 0) and (DX2 > 0))) then
    Bias2 := -1;
  var FArea := 1.0 / Area;
  var Setup: TGEPreparedTriangle;
  if Prepared = nil then
  begin
    GEPrepareTriangle(S, V0, V1, V2, Setup);
    Prepared := @Setup;
  end;
  var PR := Prepared.R;
  var PG := Prepared.G;
  var PB := Prepared.B;
  var PA := Prepared.A;
  var PF := Prepared.Fog;
  var UV := Prepared.UV;
  var UVPlanes := Prepared.HasUV;
  // Transform mode: retain the perspective planes alongside the shared
  // band-independent colour, fog, depth and through-mode UV setup.
  var Persp: TGEPerspPlanes;
  var PerspPlanes := S.Textured and not S.Through and GEPerspPlanes(V0, V1, V2, Persp);
  // For the level of detail: the steps of S/w and T/w per pixel along x and
  // y, from the steps of the weights, and the largest of them (GETexLod's G).
  var NeedLod := S.Textured and S.Tex.NeedLod;
  var NSX, NSY, NTX, NTY, LodG: Single;
  NSX := 0;
  NSY := 0;
  NTX := 0;
  NTY := 0;
  LodG := 0;
  F.Lod := 0;
  var LodPixel := 1;
  if NeedLod then
  begin
    LodPixel := GELodPixel(V0, V1, V2);
    var LA: Double := FArea;
    var BX0 := -16 * DY0 * LA;
    var BY0 := 16 * DX0 * LA;
    var BX1 := -16 * DY1 * LA;
    var BY1 := 16 * DX1 * LA;
    var BX2 := -16 * DY2 * LA;
    var BY2 := 16 * DX2 * LA;
    NSX := A0.S * A0.W * BX0 + A1.S * A1.W * BX1 + A2.S * A2.W * BX2;
    NSY := A0.S * A0.W * BY0 + A1.S * A1.W * BY1 + A2.S * A2.W * BY2;
    NTX := A0.T * A0.W * BX0 + A1.T * A1.W * BX1 + A2.T * A2.W * BX2;
    NTY := A0.T * A0.W * BY0 + A1.T * A1.W * BY1 + A2.T * A2.W * BY2;
    LodG := Max(Max(Abs(NSX), Abs(NSY)), Max(Abs(NTX), Abs(NTY)));
    if PerspPlanes then
      LodG := GEPerspLodG(Persp);
  end;
  var Step0 := -16 * DY0;
  var Step1 := -16 * DY1;
  var Step2 := -16 * DY2;
  var OriginX := Int64(PX1) * 16 + 8;
  var OriginY := Int64(PY1) * 16 + 8;
  var Row0 := (OriginY - Y1) * DX0 - (OriginX - X1) * DY0;
  var Row1 := (OriginY - Y2) * DX1 - (OriginX - X2) * DY1;
  var Row2 := (OriginY - Y0) * DX2 - (OriginX - X0) * DY2;
  var Gouraud := S.Gouraud and not S.Flat and ((A0.R <> A1.R) or (A0.R <> A2.R) or (A0.G <> A1.G) or (A0.G <> A2.G) or
    (A0.B <> A1.B) or (A0.B <> A2.B) or (A0.A <> A1.A) or (A0.A <> A2.A) or (A0.SR <> A1.SR) or (A0.SR <> A2.SR) or
    (A0.SG <> A1.SG) or (A0.SG <> A2.SG) or (A0.SB <> A1.SB) or (A0.SB <> A2.SB));
  var Secondary := (A0.SR or A0.SG or A0.SB or A1.SR or A1.SG or A1.SB or A2.SR or A2.SG or A2.SB) <> 0;
  var ConstantZ := (A0.Z = A1.Z) and (A0.Z = A2.Z);
  var DP := Prepared.Depth;
  var NeedWeights := S.Textured or Secondary or (not ConstantZ and not DP.Valid);
  // Clear mode in one colour and depth: spans of PlotPixel's clear bits.
  if S.ClearMode and not Gouraud and (ConstantZ or not S.ClearDepth) and not GEGenericPixels then
  begin
    var Fill: TGEClearFill;
    ClearSetup(S, V2.R, V2.G, V2.B, V2.A, A0.Z, Fill);
    for var PY := PY1 to PY2 do
    begin
      var Lo := PX1;
      var Hi := PX2;
      EdgeSpan(Row0 + Bias0, Step0, PX1, Lo, Hi);
      EdgeSpan(Row1 + Bias1, Step1, PX1, Lo, Hi);
      EdgeSpan(Row2 + Bias2, Step2, PX1, Lo, Hi);
      if Lo <= Hi then
        ClearRow(S, Fill, Lo, Hi, PY);
      Inc(Row0, 16 * DX0);
      Inc(Row1, 16 * DX1);
      Inc(Row2, 16 * DX2);
    end;
    Exit;
  end;
  var Plot := CachePixels(S, SelectPixel(S, Secondary));
  // The vertices' values the per pixel sums weigh, as those sums take them:
  // S, T and Q times 1/w as their single products (exact in a Double, also
  // where the product is wider), 1/w, depth, fog and secondary colour.
  var QW0: Double := A0.Q * A0.W;
  var QW1: Double := A1.Q * A1.W;
  var QW2: Double := A2.Q * A2.W;
  var SW0: Double := A0.S * A0.W;
  var SW1: Double := A1.S * A1.W;
  var SW2: Double := A2.S * A2.W;
  var TW0: Double := A0.T * A0.W;
  var TW1: Double := A1.T * A1.W;
  var TW2: Double := A2.T * A2.W;
  var IW0: Double := A0.W;
  var IW1: Double := A1.W;
  var IW2: Double := A2.W;
  var Z0: Double := A0.Z;
  var Z1: Double := A1.Z;
  var Z2: Double := A2.Z;
  var Fog0: Double := A0.Fog;
  var Fog1: Double := A1.Fog;
  var Fog2: Double := A2.Fog;
  var SR0: Double := A0.SR;
  var SR1: Double := A1.SR;
  var SR2: Double := A2.SR;
  var SG0: Double := A0.SG;
  var SG1: Double := A1.SG;
  var SG2: Double := A2.SG;
  var SB0: Double := A0.SB;
  var SB1: Double := A1.SB;
  var SB2: Double := A2.SB;
  // What is the same in every pixel. The pipelines change only F's colour.
  var Textured := S.Textured;
  var Fog := S.FogEnabled;
  var CR := V2.R;
  var CG := V2.G;
  var CB := V2.B;
  var CA := V2.A;
  F.SR := V2.SR;
  F.SG := V2.SG;
  F.SB := V2.SB;
  if Gouraud then
  begin
    F.SR := 0;
    F.SG := 0;
    F.SB := 0;
  end;
  F.Z := A0.Z;
  for var PY := PY1 to PY2 do
  begin
    var SY := Int64(PY) * 16 + 8;
    var Lo := PX1;
    var Hi := PX2;
    EdgeSpan(Row0 + Bias0, Step0, PX1, Lo, Hi);
    EdgeSpan(Row1 + Bias1, Step1, PX1, Lo, Hi);
    EdgeSpan(Row2 + Bias2, Step2, PX1, Lo, Hi);
    var E0 := Row0 + Step0 * (Lo - PX1);
    var E1 := Row1 + Step1 * (Lo - PX1);
    var E2 := Row2 + Step2 * (Lo - PX1);
    var NR, NG, NB, NA: Int64;
    NR := 0;
    NG := 0;
    NB := 0;
    NA := 0;
    if Gouraud then
    begin
      var DX := Int64(Lo) * 16 + 8 - PR.AX;
      var DY := SY - PR.AY;
      NR := PR.C0 + PR.GX * DX + PR.GY * DY;
      NG := PG.C0 + PG.GX * DX + PG.GY * DY;
      NB := PB.C0 + PB.GX * DX + PB.GY * DY;
      NA := PA.C0 + PA.GX * DX + PA.GY * DY;
    end;
    var NF: Int64 := 0;
    if Fog then
      NF := PF.C0 + PF.GX * (Int64(Lo) * 16 + 8 - PF.AX) + PF.GY * (SY - PF.AY);
    var NZ: Int64 := 0;
    if DP.Valid then
      NZ := DP.C0 + DP.GX * (Int64(Lo) * 16 + 8 - DP.AX) + DP.GY * (SY - DP.AY);
    for var PX := Lo to Hi do
    begin
      var W0, W1, W2: Double;
      W0 := 0;
      W1 := 0;
      W2 := 0;
      if NeedWeights then
      begin
        W0 := E0 * FArea;
        W1 := E1 * FArea;
        W2 := E2 * FArea;
      end;
      if not Gouraud then
      begin
        F.R := CR;
        F.G := CG;
        F.B := CB;
        F.A := CA;
      end
      else
      begin
        F.R := GEPlaneByte(NR);
        Inc(NR, PR.GX * 16);
        F.G := GEPlaneByte(NG);
        Inc(NG, PG.GX * 16);
        F.B := GEPlaneByte(NB);
        Inc(NB, PB.GX * 16);
        F.A := GEPlaneByte(NA);
        Inc(NA, PA.GX * 16);
        if Secondary then
        begin
          F.SR := GERound(SR0 * W0 + SR1 * W1 + SR2 * W2);
          F.SG := GERound(SG0 * W0 + SG1 * W1 + SG2 * W2);
          F.SB := GERound(SB0 * W0 + SB1 * W1 + SB2 * W2);
        end;
      end;
      if DP.Valid then
      begin
        F.Z := Integer(FloorShr(NZ, 14));
        Inc(NZ, DP.GX * 16);
      end
      else if not ConstantZ then
        F.Z := GERound(Z0 * W0 + Z1 * W1 + Z2 * W2);
      if Textured then
      begin
        // S, T and Q go through the perspective (1/w) and then S and T are
        // divided by Q; where Q is not positive the GE takes the last texel.
        var Q := QW0 * W0 + QW1 * W1 + QW2 * W2;
        var IW := IW0 * W0 + IW1 * W1 + IW2 * W2;
        if (Q <> 0) and ((Q > 0) = (IW > 0)) then
        begin
          if UVPlanes then
            GEUVAt(UV, PX, PY, F.S, F.T)
          else if not PerspPlanes or not GEPerspAt(Persp, PX, PY, F.S, F.T) then
          begin
            F.S := (SW0 * W0 + SW1 * W1 + SW2 * W2) / Q;
            F.T := (TW0 * W0 + TW1 * W1 + TW2 * W2) / Q;
          end;
          if NeedLod then
          begin
            // One level of detail for 4 pixels of a row (x aligned to 4), at
            // GELodPixel's.
            var LX := Min(Max((PX and not 3) + LodPixel, Lo), Hi);
            var Off: Int64 := LX - PX;
            var WL0 := (E0 + Step0 * Off) * FArea;
            var WL1 := (E1 + Step1 * Off) * FArea;
            var WL2 := (E2 + Step2 * Off) * FArea;
            var QL := Abs(QW0 * WL0 + QW1 * WL1 + QW2 * WL2);
            var IWL := IW0 * WL0 + IW1 * WL1 + IW2 * WL2;
            if PerspPlanes then
            begin
              var QP := GEPerspLodQ(Persp, LX, PY);
              if QP > 0 then
                QL := QP;
            end;
            F.Lod := GETexLod(S, LodG, QL, IWL);
          end;
        end
        else
        begin
          F.S := S.Tex.Levels[0].Width - 0.5;
          F.T := S.Tex.Levels[0].Height - 0.5;
        end;
      end;
      if Fog then
      begin
        // The pixel pipelines take Trunc(Fog * 255): half a step above keeps it.
        F.Fog := (GEPlaneByte(NF) + 0.5) / 255;
        Inc(NF, PF.GX * 16);
      end;
      Plot(S, PX, PY, F);
      Inc(E0, Step0);
      Inc(E1, Step1);
      Inc(E2, Step2);
    end;
    Inc(Row0, 16 * DX0);
    Inc(Row1, 16 * DX1);
    Inc(Row2, 16 * DX2);
  end;
end;

procedure GEDrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  DrawTriangle(S, V0, V1, V2, nil);
end;

procedure GEDrawPreparedTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex; const P: TGEPreparedTriangle);
begin
  DrawTriangle(S, V0, V1, V2, @P);
end;

procedure GEDrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEFragment;
begin
  var X1 := Min(V0.X, V1.X);
  var X2 := Max(V0.X, V1.X);
  var Y1 := Min(V0.Y, V1.Y);
  var Y2 := Max(V0.Y, V1.Y);
  // Pixels whose centre lies in [x1, x2) x [y1, y2), the left edge taking a
  // centre a sixteenth of a pixel before it too (probe ge_round).
  var PX1 := (X1 - 9 + 15 + 65536) div 16 - 4096;
  var PX2 := (X2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  var PY1 := (Y1 - 8 + 15 + 65536) div 16 - 4096;
  var PY2 := (Y2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  if S.ClearMode and not GEGenericPixels then
  begin
    ClearRect(S, PX1, PY1, PX2, PY2, V1);
    Exit;
  end;
  var Plot := CachePixels(S, SelectPixel(S, (V1.SR or V1.SG or V1.SB) <> 0));
  SetupFragment(F, V1);
  // S runs along x and T along y, except when the corners are flipped in
  // one axis only: then the texture is turned, S along y and T along x.
  var Turned := (V0.X > V1.X) <> (V0.Y > V1.Y);
  // Q goes with S, and divides both.
  var SX: Single := 0;
  var SY: Single := 0;
  var TX: Single := 0;
  var TY: Single := 0;
  var QX: Single := 0;
  var QY: Single := 0;
  if V1.X <> V0.X then
  begin
    if Turned then
      TX := GESpriteStep(V1.T - V0.T, V1.X - V0.X)
    else
    begin
      SX := GESpriteStep(V1.S - V0.S, V1.X - V0.X);
      QX := GESpriteStep(V1.Q - V0.Q, V1.X - V0.X);
    end;
  end;
  if V1.Y <> V0.Y then
  begin
    if Turned then
    begin
      SY := GESpriteStep(V1.S - V0.S, V1.Y - V0.Y);
      QY := GESpriteStep(V1.Q - V0.Q, V1.Y - V0.Y);
    end
    else
      TY := GESpriteStep(V1.T - V0.T, V1.Y - V0.Y);
  end;
  var Projected := (V0.Q <> 1) or (V1.Q <> 1);
  var Lod := 0;
  if S.Textured and S.Tex.NeedLod then
  begin
    var IW: Single := 1;
    if V1.W > 0 then
      IW := V1.W;
    Lod := GETexLod(S, Max(Max(Abs(SX), Abs(SY)), Max(Abs(TX), Abs(TY))), 1, IW);
  end;
  SetupFragment(F, V1);
  F.Lod := Lod;
  var UV: TGEUVPlanes;
  var UVPlanes := S.Textured and S.Through and GESpriteUVPlanes(S, V0, V1, UV);
  var Persp: TGEPerspPlanes;
  var PerspPlanes := S.Textured and not S.Through and GESpritePerspPlanes(V0, V1, Persp);
  for var PY := PY1 to PY2 do
  begin
    // The per row terms of S = V0.S + SX * FX + SY * FY (and T, Q), in the
    // type and order of that expression. FX and FY are 1/16 multiples, so the
    // division by 16 is a multiplication.
    var FY: Extended := (PY * 16 + 8 - V0.Y) * 0.0625;
    var SYFY: Extended := SY * FY;
    var TYFY: Extended := TY * FY;
    var QYFY: Extended := QY * FY;
    for var PX := PX1 to PX2 do
    begin
      // The pipelines change only the colour.
      F.R := V1.R;
      F.G := V1.G;
      F.B := V1.B;
      F.A := V1.A;
      if UVPlanes then
        GEUVAt(UV, PX, PY, F.S, F.T)
      else if S.Textured and not (PerspPlanes and GEPerspAt(Persp, PX, PY, F.S, F.T)) then
      begin
        var FX: Extended := (PX * 16 + 8 - V0.X) * 0.0625;
        F.S := V0.S + SX * FX + SYFY;
        F.T := V0.T + TX * FX + TYFY;
        if Projected then
        begin
          var Q := V0.Q + QX * FX + QYFY;
          if Q <> 0 then
          begin
            F.S := F.S / Q;
            F.T := F.T / Q;
          end;
        end;
      end;
      Plot(S, PX, PY, F);
    end;
  end;
end;

procedure GEDrawLine(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEFragment;
begin
  // The pixels as GELineNext walks them.
  var W: TGELineWalk;
  if not GELineStart(V0, V1, W) then
    Exit;
  var PX, PY: Integer;
  var T: Single;
  while GELineNext(W, PX, PY, T) do
  begin
    SetupFragment(F, V1);
    if not S.Flat and S.Gouraud then
    begin
      F.R := GELineColor(W, PX, PY, V0.R, V1.R);
      F.G := GELineColor(W, PX, PY, V0.G, V1.G);
      F.B := GELineColor(W, PX, PY, V0.B, V1.B);
      F.A := GELineColor(W, PX, PY, V0.A, V1.A);
    end;
    if S.Antialias then
      F.A := GELineCoverage(W, PX, PY);
    F.Z := GERound(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    var Q := V0.Q + (V1.Q - V0.Q) * T;
    if (Q <> 1) and (Q <> 0) then
    begin
      F.S := F.S / Q;
      F.T := F.T / Q;
    end;
    F.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    PlotPixel(S, PX, PY, F);
  end;
end;

procedure GEPointUV(const S: TGERaster; const V: TGEVertex; out SS, TT: Single);

  function Significant(X: Double; Bits: Integer): Double;
  var
    M: Extended;
    E: Integer;
  begin
    if (X = 0) or IsNan(X) or IsInfinite(X) then
      Exit(X);
    Frexp(X, M, E);
    Result := Ldexp(Trunc(M * (1 shl Bits)), E - Bits);
  end;

  function Coordinate(X: Double; Clamp: Boolean; Size: Integer): Single;
  begin
    if IsNan(X) or IsInfinite(X) then
      Exit(X);
    // Int returns a floating-point integer, avoiding Int64 overflow.
    X := Int(X * 16) / 16;
    if Clamp then
      X := Max(0.0, Min(X, Max(Size, 1) - 0.5))
    else
    begin
      // Every valid level's width/height divides this period. Keep the
      // low fixed-point bits before narrowing a very large coordinate.
      X := Frac(X / 65536) * 65536;
      if X < 0 then
        X := X + 65536;
    end;
    Result := X;
  end;

begin
  if V.Q <= 0 then
  begin
    // All bits set in 16.4, including the fraction: distinct from the
    // last texel's centre with a linear, repeating filter.
    SS := 65535.9375;
    TT := 65535.9375;
    Exit;
  end;
  if (PCardinal(@V.Q)^ and $7F800000) = $7F800000 then
  begin
    SS := Coordinate(V.S / V.Q, S.Tex.ClampU, S.Tex.Levels[0].Width);
    TT := Coordinate(V.T / V.Q, S.Tex.ClampV, S.Tex.Levels[0].Height);
    Exit;
  end;
  var IW: Double := 1;
  if not S.Through and (V.W > 0) and not IsInfinite(V.W) then
    IW := V.W;
  var QW := Significant(Significant(V.Q, 16) * IW, 15);
  var M: Extended;
  var E: Integer;
  Frexp(QW, M, E);
  var R := Ldexp(GEPerspRecip(Trunc((M * 2 - 1) * 65536)), -15 - E);
  SS := Coordinate(Significant(Significant(V.S, 16) * IW, 15) * R, S.Tex.ClampU, S.Tex.Levels[0].Width);
  TT := Coordinate(Significant(Significant(V.T, 16) * IW, 15) * R, S.Tex.ClampV, S.Tex.Levels[0].Height);
end;

procedure GEDrawPoint(const S: TGERaster; const V: TGEVertex);
var
  F: TGEFragment;
begin
  SetupFragment(F, V);
  if S.Textured then
    GEPointUV(S, V, F.S, F.T);
  PlotPixel(S, (V.X + $100000) div 16 - $10000, (V.Y + $100000) div 16 - $10000, F);
end;

end.
