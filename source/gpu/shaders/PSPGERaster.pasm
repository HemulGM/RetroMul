// The LLE GE rasterizer. One 16x16 workgroup per tile, one invocation per pixel;
// primitives are walked in submission order. Resource bindings and packed state
// match PSP.GE.VulkanLLE. The embedded source is compiled at context startup.
uses SoftDouble;

type
  TTextureContext = record
    TexSource, TexBase, TexData, ClutData: Cardinal;
    VramShift: Integer;
  end;
  TFragment = record
    R, G, B, A, SR, SG, SB, Z: Integer;
    S, T, Fog: Single;
    Lod: Integer;
  end;
  TTaps = array[0..3] of Cardinal;
  TLevels = array[0..1] of Integer;
  TColors = array[0..1] of Cardinal;
  TTexCoords = array[0..1] of Single;

const
  VramMask: Cardinal = $1FFFFF;
  V0: Cardinal = 6;
  V1: Cardinal = 20;
  V2: Cardinal = 34;
  Int64Limit: Double = 9223372036854775808.0d;
  PerspNode: array[0..127] of Integer = (
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
  PerspDrop: array[0..127] of Integer = (
    508, 500, 492, 486, 478, 470, 464, 456, 450, 444, 438, 432, 424, 418, 414, 408,
    402, 396, 392, 386, 380, 376, 370, 366, 360, 356, 352, 346, 342, 338, 334, 330,
    326, 322, 318, 314, 310, 306, 302, 300, 296, 292, 288, 286, 282, 278, 276, 272,
    270, 266, 264, 260, 257, 254, 252, 250, 246, 244, 242, 238, 236, 234, 232, 228,
    226, 224, 222, 220, 218, 216, 212, 210, 208, 206, 204, 202, 200, 198, 196, 194,
    192, 192, 190, 188, 186, 184, 182, 180, 180, 178, 176, 174, 172, 170, 170, 168,
    166, 164, 164, 162, 160, 160, 158, 156, 156, 154, 152, 152, 150, 148, 148, 146,
    146, 144, 142, 142, 140, 140, 138, 138, 136, 134, 134, 132, 132, 129, 130, 128);
  // Packed TGERaster offsets and flags.
  ST_FBADDR = 0;
  ST_FBSTRIDE = 1;
  ST_FBFORMAT = 2;
  ST_ZADDR = 3;
  ST_ZSTRIDE = 4;
  ST_SCISSORX1 = 5;
  ST_SCISSORY1 = 6;
  ST_SCISSORX2 = 7;
  ST_SCISSORY2 = 8;
  ST_BANDY1 = 9;
  ST_BANDY2 = 10;
  ST_FLAGS = 11;
  ST_TEXFUNC = 12;
  ST_ENVR = 13;
  ST_ENVG = 14;
  ST_ENVB = 15;
  ST_FOGR = 16;
  ST_FOGG = 17;
  ST_FOGB = 18;
  ST_COLORTESTFUNC = 19;
  ST_COLORREF = 20;
  ST_COLORMASK = 21;
  ST_ALPHAFUNC = 22;
  ST_ALPHAREF = 23;
  ST_ALPHAMASK = 24;
  ST_STENCILFUNC = 25;
  ST_STENCILREF = 26;
  ST_STENCILMASK = 27;
  ST_STENCILFAIL = 28;
  ST_STENCILZFAIL = 29;
  ST_STENCILZPASS = 30;
  ST_DEPTHFUNC = 31;
  ST_MINZ = 32;
  ST_MAXZ = 33;
  ST_BLENDOP = 34;
  ST_BLENDSRC = 35;
  ST_BLENDDST = 36;
  ST_FIXA = 37;
  ST_FIXB = 38;
  ST_LOGICFUNC = 39;
  ST_DITHER = 42;
  ST_TEXFORMAT = 58;
  ST_TEXSWIZZLE = 59;
  ST_TEXLEVEL = 60;
  ST_TEXCLAMPU = 61;
  ST_TEXCLAMPV = 62;
  ST_TEXLINEAR = 63;
  ST_CLUTFORMAT = 64;
  ST_CLUTSHIFT = 65;
  ST_CLUTMASK = 66;
  ST_CLUTOFFSET = 67;
  ST_CLUTDATA = 71;
  ST_LEVELS = 72;
  ST_KEEPMASK = 104;
  ST_ZPERMUTATION = 105;
  ST_VRAMSHIFT = 106;
  ST_LEVELDATA = 107;
  ST_MINFILTER = 115;
  ST_MAXLEVEL = 116;
  ST_LEVELMODE = 117;
  ST_LODBIAS = 118;
  ST_SLOPE = 119;
  ST_CLUTSTEP = 120;
  NO_DATA: Cardinal = $FFFFFFFF;
  SF_THROUGH = 1 shl 0;
  SF_CLEARMODE = 1 shl 1;
  SF_CLEARCOLOR = 1 shl 2;
  SF_CLEARSTENCIL = 1 shl 3;
  SF_CLEARDEPTH = 1 shl 4;
  SF_FLAT = 1 shl 5;
  SF_GOURAUD = 1 shl 6;
  SF_TEXTURED = 1 shl 7;
  SF_TEXALPHA = 1 shl 8;
  SF_COLORDOUBLE = 1 shl 9;
  SF_FOGENABLED = 1 shl 10;
  SF_COLORTEST = 1 shl 11;
  SF_ALPHATEST = 1 shl 12;
  SF_STENCILTEST = 1 shl 13;
  SF_DEPTHTEST = 1 shl 14;
  SF_DEPTHWRITE = 1 shl 15;
  SF_BLEND = 1 shl 16;
  SF_DITHER = 1 shl 17;
  SF_LOGICOP = 1 shl 18;
  SF_DEPTHCLAMP = 1 shl 19;
  SF_NEEDLOD = 1 shl 20;

var
  [Binding(0, 0), Aliased] Vram32: array of Cardinal;
  [Binding(0, 1), Aliased] Vram16: array of Word;
  [Binding(0, 2), Aliased, ReadOnly] Vram8: array of Byte;
  [Binding(0, 3), ReadOnly] Prims: array of Cardinal;
  [Binding(0, 4), ReadOnly] States: array of Cardinal;
  [Binding(0, 5), ReadOnly] Data8: array of Byte;
  [Binding(0, 6), ReadOnly] Data32: array of Cardinal;
  [Binding(0, 7), ReadOnly] Bins: array of Cardinal;
  [PushConstant] PC: record
    Table, TilesX: Cardinal;
    X1, Y1, X2, Y2: Integer;
  end;

function StInt(S, Index: Cardinal): Integer;
begin
  Result := Integer(States[S + Index]);
end;

function StUint(S, Index: Cardinal): Cardinal;
begin
  Result := States[S + Index];
end;

function StFlag(S, Flag: Cardinal): Boolean;
begin
  Result := (States[S + ST_FLAGS] and Flag) <> 0;
end;

function StDither(S: Cardinal; Index: Integer): Integer;
begin
  Result := Integer(States[S + ST_DITHER + Cardinal(Index)]);
end;

function StLevelAddr(S: Cardinal; Level: Integer): Cardinal;
begin
  Result := States[S + ST_LEVELS + Cardinal(Level) * 4];
end;

function StLevelWidth(S: Cardinal; Level: Integer): Integer;
begin
  Result := Integer(States[S + ST_LEVELS + Cardinal(Level) * 4 + 1]);
end;

function StLevelHeight(S: Cardinal; Level: Integer): Integer;
begin
  Result := Integer(States[S + ST_LEVELS + Cardinal(Level) * 4 + 2]);
end;

function StLevelBufWidth(S: Cardinal; Level: Integer): Integer;
begin
  Result := Integer(States[S + ST_LEVELS + Cardinal(Level) * 4 + 3]);
end;

function RoundRasterD(X: Double): Integer;
var
  R: Double;
begin
  R := RoundEven(X);
  if not ((R >= -2147483648.0d) and (R < 2147483648.0d)) then
    Exit(-2147483648);
  Result := Integer(R);
end;

function FloorD(X: Double): Integer;
begin
  Result := Integer(Trunc(X));
  // Binary64 values outside this interval have no fractional bits. Preserve
  // floorD's low-word result even when truncD returns the indefinite Int64.
  if not IsNan(X) and not IsInfinite(X) and (X < 0) and
    (X > -4503599627370496.0d) and (X <> Double(Trunc(X))) then
    Dec(Result);
end;

function FloorF(X: Single): Integer;
begin
  Result := FloorD(Double(X));
end;

function Clamp255(V: Integer): Integer;
begin
  Result := if V < 0 then 0 else if V > 255 then 255 else V;
end;

function DepthOffset(I: Cardinal; Shift: Integer): Cardinal;
var
  Bank, Mask, Bits: Cardinal;
begin
  if Shift = 0 then
  begin
    Bank := I and $600;
    if (Bank = 0) or (Bank = $600) then
      I := I xor $600;
  end
  else
  begin
    Mask := (Cardinal(1) shl Shift) - $20;
    Bits := ((I and (Mask shr 1) and not Cardinal($3F)) shl 1) or
      (((not I) and $20) shl 1) or ((I shr (Shift - 6)) and $20);
    I := ((I xor (Cardinal(1) shl (Shift + 3))) and not Mask) or Bits;
  end;
  Result := I and VramMask;
end;

function TexAddress(const Ctx: TTextureContext; Address: Cardinal): Cardinal;
var
  I: Cardinal;
begin
  if Ctx.TexSource <> 0 then
    Exit(Ctx.TexData + (Address - Ctx.TexBase));
  I := Address and VramMask;
  if (Address and $1FA00000) = $04200000 then
    if (Address and $400000) <> 0 then
      I := DepthOffset(I, Ctx.VramShift)
    else
      I := I xor (if Ctx.VramShift = 0 then Cardinal($600)
        else (Cardinal(1) shl (Ctx.VramShift + 3)) or $40);
  Result := I;
end;

function TexRead8(const Ctx: TTextureContext; Address: Cardinal): Cardinal;
var
  P: Cardinal;
begin
  P := TexAddress(Ctx, Address);
  Result := if Ctx.TexSource = 0 then Cardinal(Vram8[P]) else Cardinal(Data8[P]);
end;

function TexRead16(const Ctx: TTextureContext; Address: Cardinal): Cardinal;
var
  P: Cardinal;
begin
  P := TexAddress(Ctx, Address);
  if Ctx.TexSource = 0 then
    Result := Cardinal(Vram8[P]) or (Cardinal(Vram8[P + 1]) shl 8)
  else
    Result := Cardinal(Data8[P]) or (Cardinal(Data8[P + 1]) shl 8);
end;

function TexRead32(const Ctx: TTextureContext; Address: Cardinal): Cardinal;
var
  P: Cardinal;
begin
  P := TexAddress(Ctx, Address);
  if Ctx.TexSource = 0 then
    Result := Cardinal(Vram8[P]) or (Cardinal(Vram8[P + 1]) shl 8) or
      (Cardinal(Vram8[P + 2]) shl 16) or (Cardinal(Vram8[P + 3]) shl 24)
  else
    Result := Cardinal(Data8[P]) or (Cardinal(Data8[P + 1]) shl 8) or
      (Cardinal(Data8[P + 2]) shl 16) or (Cardinal(Data8[P + 3]) shl 24);
end;

function ClutByte(const Ctx: TTextureContext; Offset: Cardinal): Cardinal;
begin
  Result := Cardinal(Data8[Ctx.ClutData + Offset]);
end;

function Decode16(Format: Integer; P: Cardinal): Cardinal;
var
  R, G, B, A: Cardinal;
begin
  if Format = 0 then
  begin
    R := P and $1F;
    G := (P shr 5) and $3F;
    B := (P shr 11) and $1F;
    Exit($FF000000 or (R shl 3) or (R shr 2) or (((G shl 2) or (G shr 4)) shl 8) or
      (((B shl 3) or (B shr 2)) shl 16));
  end;
  if Format = 1 then
  begin
    R := P and $1F;
    G := (P shr 5) and $1F;
    B := (P shr 10) and $1F;
    Result := (R shl 3) or (R shr 2) or (((G shl 3) or (G shr 2)) shl 8) or
      (((B shl 3) or (B shr 2)) shl 16);
    if P and $8000 <> 0 then
      Result := Result or $FF000000;
    Exit;
  end;
  R := P and $F;
  G := (P shr 4) and $F;
  B := (P shr 8) and $F;
  A := (P shr 12) and $F;
  Result := R * 17 or (G * 17 shl 8) or (B * 17 shl 16) or (A * 17 shl 24);
end;

function ClutLookup(const Ctx: TTextureContext; S, Index: Cardinal; Level: Integer): Cardinal;
var
  I, O: Cardinal;
begin
  I := ((Index shr Cardinal(StInt(S, ST_CLUTSHIFT))) and Cardinal(StInt(S, ST_CLUTMASK))) or
    (Cardinal(StInt(S, ST_CLUTOFFSET)) and $1FF);
  I := I + ((Cardinal(Level) * States[S + ST_CLUTSTEP]) and $1FF);
  if StInt(S, ST_CLUTFORMAT) = 3 then
  begin
    O := (I and $FF) * 4;
    Exit(ClutByte(Ctx, O) or (ClutByte(Ctx, O + 1) shl 8) or
      (ClutByte(Ctx, O + 2) shl 16) or (ClutByte(Ctx, O + 3) shl 24));
  end;
  O := (I and $1FF) * 2;
  Result := Decode16(StInt(S, ST_CLUTFORMAT), ClutByte(Ctx, O) or (ClutByte(Ctx, O + 1) shl 8));
end;

function TexelOffset(Swizzle: Boolean; BufWidth, X, Y, Bits: Integer): Cardinal;
var
  RowBytes, ByteX, BlockX, BlockY, BlocksPerRow: Integer;
begin
  RowBytes := BufWidth * Bits div 8;
  ByteX := X * Bits div 8;
  if Swizzle then
  begin
    BlockX := ByteX shr 4;
    BlockY := Y shr 3;
    BlocksPerRow := RowBytes shr 4;
    Exit(Cardinal(((BlockY * BlocksPerRow + BlockX) shl 7) + ((Y and 7) shl 4) + (ByteX and 15)));
  end;
  Result := Cardinal(Y * RowBytes + ByteX);
end;

procedure SplitDXT(C: Cardinal; out R, G, B: Integer);
begin
  R := Integer((C shr 11) and $1F) shl 3;
  G := Integer((C shr 5) and $3F) shl 2;
  B := Integer(C and $1F) shl 3;
end;

function DxtColor(C0, C1, Index: Cardinal): Cardinal;
var
  R0, G0, B0, R1, G1, B1: Integer;
begin
  SplitDXT(C0, R0, G0, B0);
  SplitDXT(C1, R1, G1, B1);
  if Index = 0 then
    Exit(Cardinal(R0) or (Cardinal(G0) shl 8) or (Cardinal(B0) shl 16) or $FF000000);
  if Index = 1 then
    Exit(Cardinal(R1) or (Cardinal(G1) shl 8) or (Cardinal(B1) shl 16) or $FF000000);
  if Index = 2 then
    if C0 > C1 then
      Exit(Cardinal((2 * R0 + R1) div 3) or (Cardinal((2 * G0 + G1) div 3) shl 8) or
        (Cardinal((2 * B0 + B1) div 3) shl 16) or $FF000000)
    else
      Exit(Cardinal((R0 + R1) div 2) or (Cardinal((G0 + G1) div 2) shl 8) or
        (Cardinal((B0 + B1) div 2) shl 16) or $FF000000);
  if C0 > C1 then
    Exit(Cardinal((R0 + 2 * R1) div 3) or (Cardinal((G0 + 2 * G1) div 3) shl 8) or
      (Cardinal((B0 + 2 * B1) div 3) shl 16) or $FF000000);
  Result := 0;
end;

function FetchTexel(var Ctx: TTextureContext; S: Cardinal; Level, X, Y: Integer): Cardinal;
var
  Addr, Data, B, Block, Bits, C0, C1, Index, AW, A, A0, A1, AI: Cardinal;
  BufWidth, Format, BlockBytes, BlocksPerRow: Integer;
  Swizzle: Boolean;
  ABits: UInt64;
begin
  Addr := StLevelAddr(S, Level);
  Data := States[S + ST_LEVELDATA + Cardinal(Level)];
  Ctx.TexSource := if Data = NO_DATA then 0 else 1;
  Ctx.TexBase := Addr;
  Ctx.TexData := Data;
  BufWidth := StLevelBufWidth(S, Level);
  Swizzle := StInt(S, ST_TEXSWIZZLE) <> 0;
  Format := StInt(S, ST_TEXFORMAT);
  if Format <= 2 then
    Exit(Decode16(Format, TexRead16(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 16))));
  if Format = 3 then
    Exit(TexRead32(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 32)));
  if Format = 4 then
  begin
    B := TexRead8(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 4));
    B := if X and 1 <> 0 then B shr 4 else B and $F;
    Exit(ClutLookup(Ctx, S, B, Level));
  end;
  if Format = 5 then
    Exit(ClutLookup(Ctx, S, TexRead8(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 8)), Level));
  if Format = 6 then
    Exit(ClutLookup(Ctx, S, TexRead16(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 16)), Level));
  if Format = 7 then
    Exit(ClutLookup(Ctx, S, TexRead32(Ctx, Addr + TexelOffset(Swizzle, BufWidth, X, Y, 32)), Level));
  if Format <= 10 then
  begin
    BlockBytes := if Format = 8 then 8 else 16;
    BlocksPerRow := BufWidth div 4;
    Block := Addr + Cardinal(((Y shr 2) * BlocksPerRow + (X shr 2)) * BlockBytes);
    Bits := TexRead32(Ctx, Block);
    C0 := TexRead16(Ctx, Block + 4);
    C1 := TexRead16(Ctx, Block + 6);
    Index := (Bits shr (((Y and 3) * 4 + (X and 3)) * 2)) and 3;
    Result := DxtColor(C0, C1, Index);
    if Format = 9 then
    begin
      AW := TexRead16(Ctx, Block + 8 + Cardinal((Y and 3) * 2));
      A := (AW shr ((X and 3) * 4)) and $F;
      Result := (Result and $FFFFFF) or (A shl 4 shl 24);
    end
    else if Format = 10 then
    begin
      A0 := TexRead8(Ctx, Block + 14);
      A1 := TexRead8(Ctx, Block + 15);
      ABits := UInt64(TexRead32(Ctx, Block + 8)) or (UInt64(TexRead16(Ctx, Block + 12)) shl 32);
      AI := Cardinal((ABits shr (((Y and 3) * 4 + (X and 3)) * 3)) and 7);
      if A0 > A1 then
        A := if AI = 0 then A0 else if AI = 1 then A1 else ((8 - AI) * A0 + (AI - 1) * A1) div 7
      else
        A := if AI = 0 then A0 else if AI = 1 then A1 else if AI = 6 then 0 else if AI = 7 then 255
          else ((6 - AI) * A0 + (AI - 1) * A1) div 5;
      Result := (Result and $FFFFFF) or (A shl 24);
    end;
    Exit;
  end;
  Result := 0;
end;

function WrapCoord(V, Size: Integer; ClampIt: Boolean): Integer;
begin
  if ClampIt then
    Exit(if V < 0 then 0 else if V >= Size then Size - 1 else V);
  Result := V and (Size - 1);
end;

function SampleLevelGE(var Ctx: TTextureContext; S: Cardinal; Level: Integer; FS, FT: Single; Linear: Boolean): Cardinal;
var
  Width, Height, XA, XB, YA, YB, X0, Y0, Count: Integer;
  FracX, FracY, A, B, C, D, Top, Bottom: Int64;
  DS, DT, FX, FY: Double;
  ClampU, ClampV: Boolean;
  Taps: TTaps;
  V: UInt64;
  Shift: Cardinal;
begin
  Width := StLevelWidth(S, Level);
  Height := StLevelHeight(S, Level);
  ClampU := StInt(S, ST_TEXCLAMPU) <> 0;
  ClampV := StInt(S, ST_TEXCLAMPV) <> 0;
  FracX := 0;
  FracY := 0;
  if not Linear then
  begin
    XA := WrapCoord(FloorF(FS), Width, ClampU);
    YA := WrapCoord(FloorF(FT), Height, ClampV);
    XB := XA;
    YB := YA;
  end
  else
  begin
    DS := Double(FS) - 0.5d;
    DT := Double(FT) - 0.5d;
    X0 := FloorF(Single(DS));
    Y0 := FloorF(Single(DT));
    FX := (DS - Double(X0)) * 16.0d;
    FY := (DT - Double(Y0)) * 16.0d;
    FracX := Trunc(FX);
    FracY := Trunc(FY);
    XA := WrapCoord(X0, Width, ClampU);
    XB := WrapCoord(X0 + 1, Width, ClampU);
    YA := WrapCoord(Y0, Height, ClampV);
    YB := WrapCoord(Y0 + 1, Height, ClampV);
  end;
  Taps := Default(TTaps);
  Count := if Linear then 4 else 1;
  for var I := 0 to Count - 1 do
    Taps[I] := FetchTexel(Ctx, S, Level, (if I and 1 <> 0 then XB else XA), (if I and 2 <> 0 then YB else YA));
  if not Linear then
    Exit(Taps[0]);
  Result := 0;
  for var Channel := 0 to 3 do
  begin
    Shift := Cardinal(Channel * 8);
    A := Int64((Taps[0] shr Shift) and $FF);
    B := Int64((Taps[1] shr Shift) and $FF);
    C := Int64((Taps[2] shr Shift) and $FF);
    D := Int64((Taps[3] shr Shift) and $FF);
    Top := Int64(UInt64(A * (16 - FracX) + B * FracX) shr 4);
    Bottom := Int64(UInt64(C * (16 - FracX) + D * FracX) shr 4);
    V := UInt64(Top * (16 - FracY) + Bottom * FracY) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

function PowerRecip(Size: Integer): Single;
begin
  Result := BitsToSingle(Cardinal(127 - FindMSB(Size)) shl 23);
end;

function SampleTexture(var Ctx: TTextureContext; S: Cardinal; FS, FT: Single; Lod: Integer): Cardinal;
var
  Levels: TLevels;
  Colors: TColors;
  Count, Frac, MinFilter, MaxLevel, Level, V: Integer;
  Linear: Boolean;
  LS, LT, SU, TV: Single;
  Shift: Cardinal;
begin
  Levels := Default(TLevels);
  Colors := Default(TColors);
  Levels[0] := StInt(S, ST_TEXLEVEL);
  Count := 1;
  Frac := 0;
  Linear := StInt(S, ST_TEXLINEAR) <> 0;
  if StFlag(S, SF_NEEDLOD) then
  begin
    Levels[0] := 0;
    if Lod > 0 then
    begin
      MinFilter := StInt(S, ST_MINFILTER);
      MaxLevel := StInt(S, ST_MAXLEVEL);
      Linear := MinFilter and 1 <> 0;
      if (MinFilter >= 4) and (MaxLevel <> 0) then
      begin
        if Lod > MaxLevel * 16 then
          Lod := MaxLevel * 16;
        Level := Lod shr 4;
        Frac := Lod and 15;
        if MinFilter < 6 then
        begin
          if Frac >= 8 then
            Inc(Level);
          if Level > MaxLevel then
            Level := MaxLevel;
        end
        else if (Frac <> 0) and (Level < MaxLevel) then
        begin
          Levels[1] := Level + 1;
          Count := 2;
        end;
        Levels[0] := Level;
      end;
    end;
  end;
  for var I := 0 to Count - 1 do
  begin
    Level := Levels[I];
    LS := FS;
    LT := FT;
    if (Level > 0) and StFlag(S, SF_NEEDLOD) then
    begin
      SU := FS * Single(StLevelWidth(S, Level));
      TV := FT * Single(StLevelHeight(S, Level));
      LS := SU * PowerRecip(StLevelWidth(S, 0));
      LT := TV * PowerRecip(StLevelHeight(S, 0));
    end;
    Colors[I] := SampleLevelGE(Ctx, S, Level, LS, LT, Linear);
  end;
  if Count = 1 then
    Exit(Colors[0]);
  Result := 0;
  for var Channel := 0 to 3 do
  begin
    Shift := Cardinal(Channel * 8);
    V := (Integer((Colors[0] shr Shift) and $FF) * (16 - Frac) + Integer((Colors[1] shr Shift) and $FF) * Frac) shr 4;
    Result := Result or (Cardinal(V) shl Shift);
  end;
end;

function DelphiMax(A, B: Single): Single;
begin
  if A <> B then
  begin
    if not IsNan(A) then
      Exit(if B < A then A else B);
    Exit(A);
  end;
  Result := if SingleToBits(B) and $80000000 <> 0 then A else B;
end;

function GELog16(V: Single): Integer;
var
  Bits: Cardinal;
begin
  if not (V > 0) then
    Exit(-$10000);
  Bits := SingleToBits(V);
  Result := (Integer((Bits shr 23) and $FF) - 127) * 16 + Integer((Bits shr 19) and $F);
end;

function TexLod(S: Cardinal; G, Q, IW: Single): Integer;
var
  Mode, Bias: Integer;
  Slope, W, SW: Single;
begin
  Mode := StInt(S, ST_LEVELMODE);
  Bias := StInt(S, ST_LODBIAS);
  if Mode = 0 then
    Exit(GELog16(G) - GELog16(Q) + Bias);
  if Mode = 2 then
  begin
    Slope := BitsToSingle(StUint(S, ST_SLOPE));
    if IW > 0 then
      Exit(GELog16(Slope) - GELog16(IW) + 16 + Bias);
    W := 1;
    if IW <> 0 then
      W := Single(SoftDiv(1.0d, Double(IW)));
    SW := Slope * W;
    Exit(GELog16(SW) + 16 + Bias);
  end;
  Result := Bias;
end;

function TestFunc(Func, A, B: Integer): Boolean;
begin
  case Func of
    0:
      Exit(False);
    1:
      Exit(True);
    2:
      Exit(A = B);
    3:
      Exit(A <> B);
    4:
      Exit(A < B);
    5:
      Exit(A <= B);
    6:
      Exit(A > B);
    7:
      Exit(A >= B);
  end;
  Result := True;
end;

function StencilOf(Format, Pixel: Cardinal): Integer;
begin
  if Format = 1 then
    Exit(if Pixel and $8000 <> 0 then 255 else 0);
  if Format = 2 then
    Exit(Integer((Pixel shr 12) * 17));
  if Format = 3 then
    Exit(Integer(Pixel shr 24));
  Result := 0;
end;

function StencilOp(Op: Integer; Format: Cardinal; Old, Ref: Integer): Integer;
var
  MaxValue: Integer;
begin
  MaxValue := if Format = 1 then 1 else if Format = 2 then 15 else if Format = 3 then 255 else 0;
  case Op of
    0:
      Exit(Old);
    1:
      Exit(0);
    2:
      begin
        if Format = 1 then
          Exit(Ref shr 7);
        if Format = 2 then
          Exit(Ref shr 4);
        Exit(Ref);
      end;
    3:
      Exit((not Old) and MaxValue);
    4:
      Exit(if Old < MaxValue then Old + 1 else MaxValue);
    5:
      Exit(if Old > 0 then Old - 1 else 0);
  end;
  Result := Old;
end;

function RawStencil(Format, Pixel: Cardinal): Integer;
begin
  if Format = 1 then
    Exit(Integer((Pixel shr 15) and 1));
  if Format = 2 then
    Exit(Integer((Pixel shr 12) and $F));
  if Format = 3 then
    Exit(Integer(Pixel shr 24));
  Result := 0;
end;

function BlendMul(C, F: Integer): Integer;
begin
  Result := ((2 * C + 1) * (2 * F + 1)) shr 10;
end;

function BlendTerm(Kind, C, Other, SA, DA, Fix: Integer): Integer;
begin
  case Kind of
    0:
      Exit(BlendMul(C, Other));
    1:
      Exit(BlendMul(C, 255 - Other));
    2:
      Exit(BlendMul(C, SA));
    3:
      Exit(BlendMul(C, 255 - SA));
    4:
      Exit(BlendMul(C, DA));
    5:
      Exit(BlendMul(C, 255 - DA));
    6:
      Exit(BlendMul(C, SA) * 2);
    7:
      Exit(BlendMul(C, Max(0, 255 - 2 * SA)));
    8:
      Exit(BlendMul(C, DA) * 2);
    9:
      Exit(BlendMul(C, Max(0, 255 - 2 * DA)));
  end;
  Result := BlendMul(C, Fix);
end;

function BlendChannel(S: Cardinal; SC, DC, SA, DA: Integer; Shift: Cardinal): Integer;
var
  Op, A, B: Integer;
begin
  Op := StInt(S, ST_BLENDOP);
  if Op <= 2 then
  begin
    A := BlendTerm(StInt(S, ST_BLENDSRC), SC, DC, SA, DA, Integer((StUint(S, ST_FIXA) shr Shift) and $FF));
    B := BlendTerm(StInt(S, ST_BLENDDST), DC, SC, SA, DA, Integer((StUint(S, ST_FIXB) shr Shift) and $FF));
    Exit(if Op = 0 then A + B else if Op = 1 then A - B else B - A);
  end;
  if Op = 3 then
    Exit(Min(SC, DC));
  if Op = 4 then
    Exit(Max(SC, DC));
  Result := Abs(SC - DC);
end;

procedure DecodePixel(Format, P: Cardinal; out R, G, B, A: Integer);
begin
  if Format = 0 then
  begin
    R := Integer(P and $1F);
    R := (R shl 3) or (R shr 2);
    G := Integer((P shr 5) and $3F);
    G := (G shl 2) or (G shr 4);
    B := Integer((P shr 11) and $1F);
    B := (B shl 3) or (B shr 2);
    A := 0;
  end
  else if Format = 1 then
  begin
    R := Integer(P and $1F);
    R := (R shl 3) or (R shr 2);
    G := Integer((P shr 5) and $1F);
    G := (G shl 3) or (G shr 2);
    B := Integer((P shr 10) and $1F);
    B := (B shl 3) or (B shr 2);
    A := if P and $8000 <> 0 then 255 else 0;
  end
  else if Format = 2 then
  begin
    R := Integer(P and $F) * 17;
    G := Integer((P shr 4) and $F) * 17;
    B := Integer((P shr 8) and $F) * 17;
    A := Integer((P shr 12) and $F) * 17;
  end
  else
  begin
    R := Integer(P and $FF);
    G := Integer((P shr 8) and $FF);
    B := Integer((P shr 16) and $FF);
    A := Integer(P shr 24);
  end;
end;

function EncodeColor(Format: Cardinal; R, G, B: Integer): Cardinal;
begin
  if Format = 0 then
    Exit((Cardinal(R) shr 3) or ((Cardinal(G) shr 2) shl 5) or ((Cardinal(B) shr 3) shl 11));
  if Format = 1 then
    Exit((Cardinal(R) shr 3) or ((Cardinal(G) shr 3) shl 5) or ((Cardinal(B) shr 3) shl 10));
  if Format = 2 then
    Exit((Cardinal(R) shr 4) or ((Cardinal(G) shr 4) shl 4) or ((Cardinal(B) shr 4) shl 8));
  Result := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
end;

function StencilBits(Format: Cardinal; V: Integer): Cardinal;
begin
  if Format = 1 then
    Exit(Cardinal(V and 1) shl 15);
  if Format = 2 then
    Exit(Cardinal(V and $F) shl 12);
  if Format = 3 then
    Exit(Cardinal(V and $FF) shl 24);
  Result := 0;
end;

function TexLerp(A, B, T, Dbl: Integer): Integer;
begin
  Result := Clamp255(((A * (255 - T) + B * T + 255) * Dbl) shr 8);
end;

function TexMul(C, T, Dbl: Integer): Integer;
begin
  Result := Clamp255(((C + 1) * T * Dbl) shr 8);
end;

procedure ApplyTexture(var Ctx: TTextureContext; S: Cardinal; var F: TFragment);
var
  C: Cardinal;
  TR, TG, TB, TA, Dbl, Func: Integer;
  TexAlpha: Boolean;
begin
  C := SampleTexture(Ctx, S, F.S, F.T, F.Lod);
  TR := Integer(C and $FF);
  TG := Integer((C shr 8) and $FF);
  TB := Integer((C shr 16) and $FF);
  TA := Integer(C shr 24);
  Dbl := if StFlag(S, SF_COLORDOUBLE) then 2 else 1;
  TexAlpha := StFlag(S, SF_TEXALPHA);
  Func := StInt(S, ST_TEXFUNC);
  if Func = 0 then
  begin
    F.R := TexMul(F.R, TR, Dbl);
    F.G := TexMul(F.G, TG, Dbl);
    F.B := TexMul(F.B, TB, Dbl);
    if TexAlpha then
      F.A := TexMul(F.A, TA, 1);
  end
  else if Func = 1 then
  begin
    if TexAlpha then
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
  end
  else if Func = 2 then
  begin
    F.R := TexLerp(F.R, StInt(S, ST_ENVR), TR, Dbl);
    F.G := TexLerp(F.G, StInt(S, ST_ENVG), TG, Dbl);
    F.B := TexLerp(F.B, StInt(S, ST_ENVB), TB, Dbl);
    if TexAlpha then
      F.A := TexMul(F.A, TA, 1);
  end
  else if Func = 3 then
  begin
    F.R := Clamp255(TR * Dbl);
    F.G := Clamp255(TG * Dbl);
    F.B := Clamp255(TB * Dbl);
    if TexAlpha then
      F.A := TA;
  end
  else
  begin
    F.R := Clamp255((F.R + TR) * Dbl);
    F.G := Clamp255((F.G + TG) * Dbl);
    F.B := Clamp255((F.B + TB) * Dbl);
    if TexAlpha then
      F.A := TexMul(F.A, TA, 1);
  end;
end;

function ReadPixel(Addr: Cardinal; Wide: Boolean): Cardinal;
begin
  Result := if Wide then Vram32[Addr shr 2] else Cardinal(Vram16[Addr shr 1]);
end;

procedure WritePixel(Addr: Cardinal; Wide: Boolean; Value: Cardinal);
begin
  if Wide then
    Vram32[Addr shr 2] := Value
  else
    Vram16[Addr shr 1] := Word(Value);
end;

procedure PlotPixel(var Ctx: TTextureContext; S: Cardinal; X, Y: Integer; F: TFragment);
var
  Format, Bpp, PAddr, ZAddr, Old, NewP, Keep, C, Mask, Src: Cardinal;
  Z, CR, CG, CB, D, SV, RangeZ, FI, Func, Stencil, NewStencil, St8, Ref, MaskI, OldZ: Integer;
  R, G, B, DR, DG, DB, DA: Integer;
  Wide, Pass, StencilWrite: Boolean;
  FG, Scaled: Single;
begin
  if (X < StInt(S, ST_SCISSORX1)) or (X > StInt(S, ST_SCISSORX2)) or
    (Y < StInt(S, ST_SCISSORY1)) or (Y > StInt(S, ST_SCISSORY2)) then
    Exit;
  if (Y < StInt(S, ST_BANDY1)) or (Y > StInt(S, ST_BANDY2)) then
    Exit;
  Format := StUint(S, ST_FBFORMAT);
  Wide := Format = 3;
  Bpp := if Wide then 4 else 2;
  PAddr := (StUint(S, ST_FBADDR) + (Cardinal(Y) * StUint(S, ST_FBSTRIDE) + Cardinal(X)) * Bpp) and VramMask;
  ZAddr := DepthOffset(StUint(S, ST_ZADDR) + (Cardinal(Y) * StUint(S, ST_ZSTRIDE) + Cardinal(X)) * 2,
    StInt(S, ST_ZPERMUTATION));
  Old := ReadPixel(PAddr, Wide);
  Z := Clamp(F.Z, 0, 65535);
  if StFlag(S, SF_CLEARMODE) then
  begin
    NewP := Old;
    Keep := StUint(S, ST_KEEPMASK);
    if StFlag(S, SF_CLEARCOLOR) then
    begin
      CR := F.R;
      CG := F.G;
      CB := F.B;
      if StFlag(S, SF_DITHER) then
      begin
        D := StDither(S, (Y and 3) * 4 + (X and 3));
        CR := Clamp255(CR + D);
        CG := Clamp255(CG + D);
        CB := Clamp255(CB + D);
      end;
      NewP := (NewP and not EncodeColor(Format, 255, 255, 255)) or EncodeColor(Format, CR, CG, CB);
    end;
    if StFlag(S, SF_CLEARSTENCIL) then
    begin
      SV := if Format = 1 then F.A shr 7 else if Format = 2 then F.A shr 4 else F.A;
      NewP := (NewP and not StencilBits(Format, $FF)) or StencilBits(Format, SV);
    end;
    NewP := (NewP and not Keep) or (Old and Keep);
    WritePixel(PAddr, Wide, NewP);
    if StFlag(S, SF_CLEARDEPTH) then
      Vram16[ZAddr shr 1] := Word(Z);
    Exit;
  end;
  if not StFlag(S, SF_THROUGH) then
  begin
    RangeZ := if StFlag(S, SF_DEPTHCLAMP) then Z else F.Z;
    if (RangeZ < StInt(S, ST_MINZ)) or (RangeZ > StInt(S, ST_MAXZ)) then
      Exit;
  end;
  if StFlag(S, SF_TEXTURED) then
    ApplyTexture(Ctx, S, F);
  F.R := Clamp255(F.R + F.SR);
  F.G := Clamp255(F.G + F.SG);
  F.B := Clamp255(F.B + F.SB);
  if StFlag(S, SF_FOGENABLED) then
  begin
    FG := F.Fog;
    if not (FG > 0) then
      FG := 0;
    if FG > 1 then
      FG := 1;
    Scaled := FG * 255.0;
    FI := Integer(Trunc(Double(Scaled)));
    F.R := TexLerp(StInt(S, ST_FOGR), F.R, FI, 1);
    F.G := TexLerp(StInt(S, ST_FOGG), F.G, FI, 1);
    F.B := TexLerp(StInt(S, ST_FOGB), F.B, FI, 1);
  end;
  if StFlag(S, SF_COLORTEST) then
  begin
    C := Cardinal(F.R) or (Cardinal(F.G) shl 8) or (Cardinal(F.B) shl 16);
    Mask := StUint(S, ST_COLORMASK);
    Func := StInt(S, ST_COLORTESTFUNC);
    Pass := if Func = 0 then False else if Func = 1 then True else if Func = 2 then
      (C and Mask) = (StUint(S, ST_COLORREF) and Mask) else (C and Mask) <> (StUint(S, ST_COLORREF) and Mask);
    if not Pass then
      Exit;
  end;
  if StFlag(S, SF_ALPHATEST) then
    if not TestFunc(StInt(S, ST_ALPHAFUNC), F.A and StInt(S, ST_ALPHAMASK),
      StInt(S, ST_ALPHAREF) and StInt(S, ST_ALPHAMASK)) then
      Exit;
  Stencil := RawStencil(Format, Old);
  NewStencil := Stencil;
  StencilWrite := False;
  if StFlag(S, SF_STENCILTEST) and (Format <> 0) then
  begin
    St8 := StencilOf(Format, Old);
    Ref := StInt(S, ST_STENCILREF);
    MaskI := StInt(S, ST_STENCILMASK);
    if not TestFunc(StInt(S, ST_STENCILFUNC), Ref and MaskI, St8 and MaskI) then
    begin
      NewStencil := StencilOp(StInt(S, ST_STENCILFAIL), Format, Stencil, Ref);
      if NewStencil <> Stencil then
      begin
        Keep := StUint(S, ST_KEEPMASK);
        NewP := (Old and not StencilBits(Format, $FF)) or StencilBits(Format, NewStencil);
        NewP := (NewP and not Keep) or (Old and Keep);
        WritePixel(PAddr, Wide, NewP);
      end;
      Exit;
    end;
    StencilWrite := True;
  end;
  if StFlag(S, SF_DEPTHTEST) then
  begin
    OldZ := Integer(Vram16[ZAddr shr 1]);
    if not TestFunc(StInt(S, ST_DEPTHFUNC), Z, OldZ) then
    begin
      if StencilWrite then
      begin
        NewStencil := StencilOp(StInt(S, ST_STENCILZFAIL), Format, Stencil, StInt(S, ST_STENCILREF));
        if NewStencil <> Stencil then
        begin
          Keep := StUint(S, ST_KEEPMASK);
          NewP := (Old and not StencilBits(Format, $FF)) or StencilBits(Format, NewStencil);
          NewP := (NewP and not Keep) or (Old and Keep);
          WritePixel(PAddr, Wide, NewP);
        end;
      end;
      Exit;
    end;
  end;
  if StencilWrite then
    NewStencil := StencilOp(StInt(S, ST_STENCILZPASS), Format, Stencil, StInt(S, ST_STENCILREF));
  if StFlag(S, SF_DEPTHWRITE) and StFlag(S, SF_DEPTHTEST) then
    Vram16[ZAddr shr 1] := Word(Z);
  R := F.R;
  G := F.G;
  B := F.B;
  if StFlag(S, SF_BLEND) then
  begin
    DecodePixel(Format, Old, DR, DG, DB, DA);
    if Format = 0 then
      DA := 0;
    R := BlendChannel(S, F.R, DR, F.A, DA, 0);
    G := BlendChannel(S, F.G, DG, F.A, DA, 8);
    B := BlendChannel(S, F.B, DB, F.A, DA, 16);
  end;
  if StFlag(S, SF_DITHER) then
  begin
    D := StDither(S, (Y and 3) * 4 + (X and 3));
    R := R + D;
    G := G + D;
    B := B + D;
  end;
  R := Clamp255(R);
  G := Clamp255(G);
  B := Clamp255(B);
  NewP := (Old and StencilBits(Format, $FF)) or EncodeColor(Format, R, G, B);
  if StencilWrite then
    NewP := (NewP and not StencilBits(Format, $FF)) or StencilBits(Format, NewStencil);
  if StFlag(S, SF_LOGICOP) then
  begin
    Src := NewP;
    case StInt(S, ST_LOGICFUNC) of
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
    NewP := (NewP and not StencilBits(Format, $FF)) or (Src and StencilBits(Format, $FF));
  end;
  Keep := StUint(S, ST_KEEPMASK);
  NewP := (NewP and not Keep) or (Old and Keep);
  WritePixel(PAddr, Wide, NewP);
end;

function VInt(P, V, Field: Cardinal): Integer;
begin
  Result := Integer(Prims[P + V + Field]);
end;

function VFloat(P, V, Field: Cardinal): Single;
begin
  Result := BitsToSingle(Prims[P + V + Field]);
end;

procedure SetupFragment(P, V: Cardinal; var F: TFragment);
begin
  F.R := VInt(P, V, 4);
  F.G := VInt(P, V, 5);
  F.B := VInt(P, V, 6);
  F.A := VInt(P, V, 7);
  F.SR := VInt(P, V, 8);
  F.SG := VInt(P, V, 9);
  F.SB := VInt(P, V, 10);
  F.Z := VInt(P, V, 2);
  F.S := VFloat(P, V, 11);
  F.T := VFloat(P, V, 12);
  F.Fog := VFloat(P, V, 13);
  F.Lod := 0;
end;

function PrimInt64(O: Cardinal): Int64;
begin
  Result := Int64(UInt64(Prims[O]) or (UInt64(Prims[O + 1]) shl 32));
end;

function PlaneAt(O: Cardinal; DX, DY: Int64): Integer;
var
  V: Int64;
begin
  V := PrimInt64(O) + PrimInt64(O + 2) * DX + PrimInt64(O + 4) * DY;
  if V < 0 then
    Exit(0);
  Result := Integer(UInt64(V) shr 14);
  if Result > 255 then
    Result := 255;
end;

procedure UVPlanes(P: Cardinal; PX, PY: Integer; var FS, FT: Single);
var
  UVF: Cardinal;
  UDX, UDY, US, UT: Int64;
  KS, KT: Integer;
begin
  UVF := Prims[P + 125];
  if UVF and 1 = 0 then
    Exit;
  UDX := Int64(PX) * 16 + 8 - Int64(Integer(Prims[P + 123]));
  UDY := Int64(PY) * 16 + 8 - Int64(Integer(Prims[P + 124]));
  KS := Integer((UVF shr 8) and $FF);
  KT := Integer((UVF shr 16) and $FF);
  US := ArithmeticShiftRight(PrimInt64(P + 111) + PrimInt64(P + 113) * UDX + PrimInt64(P + 115) * UDY, 10 + KS);
  UT := ArithmeticShiftRight(PrimInt64(P + 117) + PrimInt64(P + 119) * UDX + PrimInt64(P + 121) * UDY, 10 + KT);
  FS := Single(US) * 0.0625;
  FT := Single(UT) * 0.0625;
end;

function PerspScaled(V: Int64; SH: Integer): Int64;
begin
  if SH < 0 then
    Exit(V shl (-SH));
  Result := if V >= 0 then V shr SH else -((-V) shr SH);
end;

function PerspPlanes(P: Cardinal; PX, PY: Integer; var FS, FT: Single): Boolean;
var
  DX, DY, D, R, NS, NT: Int64;
  E, M16, J, KS, KT, KQ: Integer;
begin
  if Prims[P + 151] and 1 = 0 then
    Exit(False);
  DX := Int64(PX) * 16 + 8 - Int64(Integer(Prims[P + 146]));
  DY := Int64(PY) * 16 + 8 - Int64(Integer(Prims[P + 147]));
  D := ArithmeticShiftRight(PrimInt64(P + 140) + PrimInt64(P + 142) * DX + PrimInt64(P + 144) * DY, 14);
  if (D <= 0) or (D >= 65536) then
    Exit(False);
  E := FindMSB(Cardinal(D));
  M16 := Integer((D shl (16 - E)) - 65536);
  J := M16 shr 9;
  R := ArithmeticShiftRight(256 * Int64(PerspNode[J]) - 1 - Int64(PerspDrop[J]) * Int64(M16 and 511), 9);
  NS := ArithmeticShiftRight(PrimInt64(P + 128) + PrimInt64(P + 130) * DX + PrimInt64(P + 132) * DY, 14);
  NT := ArithmeticShiftRight(PrimInt64(P + 134) + PrimInt64(P + 136) * DX + PrimInt64(P + 138) * DY, 14);
  KS := Integer(Prims[P + 148]);
  KT := Integer(Prims[P + 149]);
  KQ := Integer(Prims[P + 150]);
  FS := Single(Double(PerspScaled(NS * R, 12 + E + KS - KQ)) * 0.0625d);
  FT := Single(Double(PerspScaled(NT * R, 12 + E + KT - KQ)) * 0.0625d);
  Result := True;
end;

function TriangleFragment(P, S: Cardinal; PX, PY: Integer; var F: TFragment): Boolean;
var
  X0, Y0, X1, Y1, X2, Y2, SX, SY, E0, E1, E2, DX, DY, ZDX, ZDY, FDX, FDY: Int64;
  LSX, LE0, LE1, LE2, QD: Int64;
  Bias: Cardinal;
  FArea, W0, W1, W2, SR, SG, SB, ZZ, Q, IW, N, LW0, LW1, LW2, LQ, LIW: Double;
  AW0, AW1, AW2, AQ0, AQ1, AQ2, C0, C1, C2, NSX, NSY, NTX, NTY, LodG, LQF, FV: Single;
  ST: TTexCoords;
  LX, LDir: Integer;
begin
  X0 := Int64(VInt(P, V0, 0));
  Y0 := Int64(VInt(P, V0, 1));
  X1 := Int64(VInt(P, V1, 0));
  Y1 := Int64(VInt(P, V1, 1));
  X2 := Int64(VInt(P, V2, 0));
  Y2 := Int64(VInt(P, V2, 1));
  SX := Int64(PX) * 16 + 8;
  SY := Int64(PY) * 16 + 8;
  E0 := -((SX - X1) * (Y2 - Y1) - (SY - Y1) * (X2 - X1));
  E1 := -((SX - X2) * (Y0 - Y2) - (SY - Y2) * (X0 - X2));
  E2 := -((SX - X0) * (Y1 - Y0) - (SY - Y0) * (X1 - X0));
  Bias := Prims[P + 59];
  if (E0 + (if Bias and 1 <> 0 then -1 else 0) < 0) or
    (E1 + (if Bias and 2 <> 0 then -1 else 0) < 0) or
    (E2 + (if Bias and 4 <> 0 then -1 else 0) < 0) then
    Exit(False);
  FArea := BitsToDouble(UInt64(Prims[P + 57]) or (UInt64(Prims[P + 58]) shl 32));
  W0 := Double(E0) * FArea;
  W1 := Double(E1) * FArea;
  W2 := Double(E2) * FArea;
  if StFlag(S, SF_FLAT) or not StFlag(S, SF_GOURAUD) then
  begin
    F.R := Integer(Prims[P + 48]);
    F.G := Integer(Prims[P + 49]);
    F.B := Integer(Prims[P + 50]);
    F.A := Integer(Prims[P + 51]);
    F.SR := Integer(Prims[P + 52]);
    F.SG := Integer(Prims[P + 53]);
    F.SB := Integer(Prims[P + 54]);
  end
  else
  begin
    DX := SX - Int64(Integer(Prims[P + 64]));
    DY := SY - Int64(Integer(Prims[P + 65]));
    F.R := PlaneAt(P + 66, DX, DY);
    F.G := PlaneAt(P + 72, DX, DY);
    F.B := PlaneAt(P + 78, DX, DY);
    F.A := PlaneAt(P + 84, DX, DY);
    SR := Double(VInt(P, V0, 8)) * W0 + Double(VInt(P, V1, 8)) * W1 + Double(VInt(P, V2, 8)) * W2;
    SG := Double(VInt(P, V0, 9)) * W0 + Double(VInt(P, V1, 9)) * W1 + Double(VInt(P, V2, 9)) * W2;
    SB := Double(VInt(P, V0, 10)) * W0 + Double(VInt(P, V1, 10)) * W1 + Double(VInt(P, V2, 10)) * W2;
    F.SR := RoundRasterD(SR);
    F.SG := RoundRasterD(SG);
    F.SB := RoundRasterD(SB);
  end;
  if Prims[P + 110] <> 0 then
  begin
    ZDX := SX - Int64(Integer(Prims[P + 102]));
    ZDY := SY - Int64(Integer(Prims[P + 103]));
    F.Z := Integer(ArithmeticShiftRight(PrimInt64(P + 104) + PrimInt64(P + 106) * ZDX + PrimInt64(P + 108) * ZDY, 14));
  end
  else
  begin
    ZZ := Double(VInt(P, V0, 2)) * W0 + Double(VInt(P, V1, 2)) * W1 + Double(VInt(P, V2, 2)) * W2;
    F.Z := RoundRasterD(ZZ);
  end;
  F.S := 0;
  F.T := 0;
  F.Lod := 0;
  if StFlag(S, SF_TEXTURED) then
  begin
    AW0 := VFloat(P, V0, 3);
    AW1 := VFloat(P, V1, 3);
    AW2 := VFloat(P, V2, 3);
    AQ0 := BitsToSingle(Prims[P + 60]) * AW0;
    AQ1 := BitsToSingle(Prims[P + 61]) * AW1;
    AQ2 := BitsToSingle(Prims[P + 62]) * AW2;
    Q := Double(AQ0) * W0 + Double(AQ1) * W1 + Double(AQ2) * W2;
    IW := Double(AW0) * W0 + Double(AW1) * W1 + Double(AW2) * W2;
    if (Q <> 0) and ((Q > 0) = (IW > 0)) then
    begin
      // Successful planes replace both divided coordinates completely.
      if not PerspPlanes(P, PX, PY, F.S, F.T) then
      begin
        if Prims[P + 125] and 1 <> 0 then
          UVPlanes(P, PX, PY, F.S, F.T)
        else
        begin
          ST := Default(TTexCoords);
          for var I: Cardinal := 0 to 1 do
          begin
            C0 := VFloat(P, V0, 11 + I) * AW0;
            C1 := VFloat(P, V1, 11 + I) * AW1;
            C2 := VFloat(P, V2, 11 + I) * AW2;
            N := Double(C0) * W0 + Double(C1) * W1 + Double(C2) * W2;
            ST[I] := Single(SoftDiv(N, Q));
          end;
          F.S := ST[0];
          F.T := ST[1];
        end;
      end;
      if StFlag(S, SF_NEEDLOD) then
      begin
        NSX := BitsToSingle(Prims[P + 90]);
        NSY := BitsToSingle(Prims[P + 91]);
        NTX := BitsToSingle(Prims[P + 92]);
        NTY := BitsToSingle(Prims[P + 93]);
        LodG := DelphiMax(DelphiMax(Abs(NSX), Abs(NSY)), DelphiMax(Abs(NTX), Abs(NTY)));
        LX := (PX and not 3) + Integer(Prims[P + 152]);
        LDir := if LX > PX then -1 else 1;
        repeat
          LSX := Int64(LX) * 16 + 8;
          LE0 := -((LSX - X1) * (Y2 - Y1) - (SY - Y1) * (X2 - X1));
          LE1 := -((LSX - X2) * (Y0 - Y2) - (SY - Y2) * (X0 - X2));
          LE2 := -((LSX - X0) * (Y1 - Y0) - (SY - Y0) * (X1 - X0));
          if (LX = PX) or ((LX >= Integer(Prims[P + 2])) and (LX <= Integer(Prims[P + 4])) and
            (LE0 + (if Bias and 1 <> 0 then -1 else 0) >= 0) and
            (LE1 + (if Bias and 2 <> 0 then -1 else 0) >= 0) and
            (LE2 + (if Bias and 4 <> 0 then -1 else 0) >= 0)) then
            Break;
          LX := LX + LDir;
        until False;
        LW0 := Double(LE0) * FArea;
        LW1 := Double(LE1) * FArea;
        LW2 := Double(LE2) * FArea;
        LQ := Double(AQ0) * LW0 + Double(AQ1) * LW1 + Double(AQ2) * LW2;
        LIW := Double(AW0) * LW0 + Double(AW1) * LW1 + Double(AW2) * LW2;
        LQF := Single(Abs(LQ));
        if Prims[P + 151] and 1 <> 0 then
        begin
          QD := ArithmeticShiftRight(PrimInt64(P + 140) + PrimInt64(P + 142) *
            (Int64(LX) * 16 + 8 - Int64(Integer(Prims[P + 146]))) + PrimInt64(P + 144) *
            (SY - Int64(Integer(Prims[P + 147]))), 14);
          if QD > 0 then
            LQF := Single(Ldexp(Double(QD), -Integer(Prims[P + 150])));
        end;
        F.Lod := TexLod(S, LodG, LQF, Single(LIW));
      end;
    end
    else
    begin
      F.S := Single(Double(StLevelWidth(S, 0)) - 0.5d);
      F.T := Single(Double(StLevelHeight(S, 0)) - 0.5d);
    end;
  end;
  if StFlag(S, SF_FOGENABLED) then
  begin
    FDX := SX - Int64(Integer(Prims[P + 64]));
    FDY := SY - Int64(Integer(Prims[P + 65]));
    FV := Single(PlaneAt(P + 96, FDX, FDY)) + 0.5;
    F.Fog := Single(SoftDiv(Double(FV), 255.0d));
  end
  else
    F.Fog := 0;
  Result := True;
end;

procedure SpriteFragment(P, S: Cardinal; PX, PY: Integer; var F: TFragment);
var
  X0, Y0: Integer;
  U, V, SS, TT, Q: Double;
begin
  SetupFragment(P, V1, F);
  if StFlag(S, SF_TEXTURED) then
  begin
    F.Lod := Integer(Prims[P + 42]);
    X0 := VInt(P, V0, 0);
    Y0 := VInt(P, V0, 1);
    U := Double(PX * 16 + 8 - X0) * 0.0625d;
    V := Double(PY * 16 + 8 - Y0) * 0.0625d;
    SS := Double(VFloat(P, V0, 11)) + Double(BitsToSingle(Prims[P + 34])) * U + Double(BitsToSingle(Prims[P + 35])) * V;
    TT := Double(VFloat(P, V0, 12)) + Double(BitsToSingle(Prims[P + 36])) * U + Double(BitsToSingle(Prims[P + 37])) * V;
    F.S := Single(SS);
    F.T := Single(TT);
    UVPlanes(P, PX, PY, F.S, F.T);
    if Prims[P + 41] <> 0 then
    begin
      Q := Double(BitsToSingle(Prims[P + 40])) + Double(BitsToSingle(Prims[P + 38])) * U + Double(BitsToSingle(Prims[P + 39])) * V;
      if Q <> 0 then
      begin
        F.S := Single(SoftDiv(Double(F.S), Q));
        F.T := Single(SoftDiv(Double(F.T), Q));
      end;
    end;
    PerspPlanes(P, PX, PY, F.S, F.T);
  end;
end;

function ListFragment(P: Cardinal; PX, PY: Integer; var F: TFragment): Boolean;
var
  Count, First, Index: Integer;
  XMajor: Boolean;
  O: Cardinal;
begin
  Count := Integer(Prims[P + 6]);
  First := Integer(Prims[P + 7]);
  XMajor := Prims[P + 8] <> 0;
  Index := (if XMajor then PX else PY) - First;
  if (Index < 0) or (Index >= Count) then
    Exit(False);
  O := Prims[P + 9] + Cardinal(Index) * 16;
  if (Integer(Data32[O]) <> PX) or (Integer(Data32[O + 1]) <> PY) then
    Exit(False);
  F.R := Integer(Data32[O + 2]);
  F.G := Integer(Data32[O + 3]);
  F.B := Integer(Data32[O + 4]);
  F.A := Integer(Data32[O + 5]);
  F.SR := Integer(Data32[O + 6]);
  F.SG := Integer(Data32[O + 7]);
  F.SB := Integer(Data32[O + 8]);
  F.Z := Integer(Data32[O + 9]);
  F.S := BitsToSingle(Data32[O + 10]);
  F.T := BitsToSingle(Data32[O + 11]);
  F.Fog := BitsToSingle(Data32[O + 12]);
  F.Lod := 0;
  Result := True;
end;

[Vulkan11, StrictFloat, LocalSize(16, 16, 1)]
procedure Main;
var
  Tile, First, Count, P, S, Kind: Cardinal;
  PX, PY: Integer;
  F: TFragment;
  Covered: Boolean;
  Ctx: TTextureContext;
begin
  Tile := PC.Table + (WorkgroupID.Y * PC.TilesX + WorkgroupID.X) * 2;
  First := Bins[Tile];
  Count := Bins[Tile + 1];
  // GLSL >> on signed positions is arithmetic (Pascal shr is logical).
  PX := (ArithmeticShiftRight(PC.X1, 4) + Integer(WorkgroupID.X)) * 16 + Integer(LocalInvocationID.X);
  PY := (ArithmeticShiftRight(PC.Y1, 4) + Integer(WorkgroupID.Y)) * 16 + Integer(LocalInvocationID.Y);
  if (PX < PC.X1) or (PY < PC.Y1) or (PX > PC.X2) or (PY > PC.Y2) then
    Exit;
  Ctx := Default(TTextureContext);
  // Count may be zero: avoid an unsigned Count-1 for-loop bound.
  var I: Cardinal := 0;
  while I < Count do
  begin
    P := Bins[First + I] * 160;
    Inc(I);
    if (PX < Integer(Prims[P + 2])) or (PY < Integer(Prims[P + 3])) or
      (PX > Integer(Prims[P + 4])) or (PY > Integer(Prims[P + 5])) then
      Continue;
    S := Prims[P + 1] * 128;
    Ctx.ClutData := StUint(S, ST_CLUTDATA);
    Ctx.VramShift := StInt(S, ST_VRAMSHIFT);
    Kind := Prims[P];
    F := Default(TFragment);
    Covered := True;
    if Kind = 0 then
      Covered := TriangleFragment(P, S, PX, PY, F)
    else if Kind = 1 then
      SpriteFragment(P, S, PX, PY, F)
    else
      Covered := ListFragment(P, PX, PY, F);
    if Covered then
      PlotPixel(Ctx, S, PX, PY, F);
  end;
end;
