// Shared GE texture sampling, colour, fog and fragment tests.
function Clamp255(V: Integer): Integer;
begin
  Result := Clamp(V, 0, 255);
end;

function TexLerp(A, B, T, Dbl: Integer): Integer;
begin
  Result := Clamp255(ArithmeticShiftRight((A * (255 - T) + B * T + 255) * Dbl, 8));
end;

function TexMul(C, T, Dbl: Integer): Integer;
begin
  Result := Clamp255(ArithmeticShiftRight((C + 1) * T * Dbl, 8));
end;

function UnpackRGB(C: Cardinal): Integer3;
begin
  Result := Integer3(Integer(C and 255), Integer((C shr 8) and 255), Integer((C shr 16) and 255));
end;

function TestFunc(Func: Cardinal; A, B: Integer): Boolean;
begin
  case Func of
    0:
      Exit(False);
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

function DitherAt: Integer;
begin
  var P := Cardinal2(Pixel.XY);
  var I := (P.Y and 3) * 4 + (P.X and 3);
  var BitsWord := (if I < 8 then PC.Dither0 else PC.Dither1);
  var N := Integer((BitsWord shr ((I and 7) * 4)) and 15);
  Result := (if N >= 8 then N - 16 else N);
end;

function Quantize(C: Integer3; Format: Cardinal): Integer3;
begin
  if Format = 0 then
  begin
    var Q := ArithmeticShiftRight(C, Integer3(3, 2, 3));
    Exit(Integer3((Q.R shl 3) or ArithmeticShiftRight(Q.R, 2),
      (Q.G shl 2) or ArithmeticShiftRight(Q.G, 4),
      (Q.B shl 3) or ArithmeticShiftRight(Q.B, 2)));
  end;
  if Format = 1 then
  begin
    var Q := ArithmeticShiftRight(C, 3);
    Exit((Q shl 3) or ArithmeticShiftRight(Q, 2));
  end;
  if Format = 2 then
    Exit(ArithmeticShiftRight(C, 4) * 17);
  Result := C;
end;

function WrapCoord(V, Size: Integer; ClampIt: Boolean): Integer;
begin
  if ClampIt then
    Exit(Clamp(V, 0, Size - 1));
  if (PC.TexFunc and (TEX_TARGET or TEX_SCALED)) <> 0 then
    Exit(V - Size * Integer(FloorFloat(Single(V) / Single(Size))));
  Result := V and (Size - 1);
end;

function Texel(P: Integer2; Level: Integer): Integer4;
begin
  if (PC.TexFunc and TEX_TARGET) = 0 then
    Exit(Integer4(RoundFloat(TexelFetch(UTexture, P, Level) * 255.0)));
  var T := Integer4(RoundFloat(TexelFetch(UTexture, Min(P, TextureSize(UTexture, 0) - 1), 0) * 255.0));
  var Format := (PC.TexFunc shr 21) and 3;
  T.RGB := Quantize(T.RGB, Format);
  if Format = 0 then
    T.A := 255;
  Result := T;
end;

function GESampleLevel(ST: Single2; Level: Integer; Linear: Boolean): Integer4;
begin
  var Size := TextureSize(UTexture, Level);
  var Scale := Integer((PC.TexFunc shr 17) and 15);
  if (PC.TexFunc and TEX_TARGET) <> 0 then
  begin
    ST := ST * Single(Scale);
    Size := Integer2(PC.TexSize) * Scale;
  end
  else if Scale > 1 then
    ST := ST * Single(Scale);
  var CU := (PC.TexFunc and TEX_CLAMPU) <> 0;
  var CV := (PC.TexFunc and TEX_CLAMPV) <> 0;
  if not Linear then
  begin
    var P := Integer2(FloorFloat(ST));
    Exit(Texel(Integer2(WrapCoord(P.X, Size.X, CU), WrapCoord(P.Y, Size.Y, CV)), Level));
  end;
  var F: Single2 := ST - 0.5;
  var F0: Single2 := FloorFloat(F);
  var P0 := Integer2(F0);
  var Fr := Integer2((F - F0) * 16.0);
  var XA := WrapCoord(P0.X, Size.X, CU);
  var XB := WrapCoord(P0.X + 1, Size.X, CU);
  var YA := WrapCoord(P0.Y, Size.Y, CV);
  var YB := WrapCoord(P0.Y + 1, Size.Y, CV);
  var Top := ArithmeticShiftRight(Texel(Integer2(XA, YA), Level) * (16 - Fr.X) +
    Texel(Integer2(XB, YA), Level) * Fr.X, 4);
  var Bottom := ArithmeticShiftRight(Texel(Integer2(XA, YB), Level) * (16 - Fr.X) +
    Texel(Integer2(XB, YB), Level) * Fr.X, 4);
  Result := ArithmeticShiftRight(Top * (16 - Fr.Y) + Bottom * Fr.Y, 4);
end;

function GESampleAt(ST: Single2; Level: Integer; Linear: Boolean): Integer4;
begin
  if Level > 0 then
    ST := ST * Single2(TextureSize(UTexture, Level)) / Single2(TextureSize(UTexture, 0));
  Result := GESampleLevel(ST, Level, Linear);
end;

function Log16(V: Single): Integer;
begin
  if not (V > 0.0) then
    Exit(-$10000);
  var Bits := SingleToBits(V);
  Result := (Integer((Bits shr 23) and 255) - 127) * 16 + Integer((Bits shr 19) and 15);
end;

function GESampleTexture(ST: Single2; Scale, W: Single): Integer4;
begin
  var LodMode := (PC.TexFunc shr 5) and 3;
  var MagLinear := (PC.TexFunc and TEX_MAGLINEAR) <> 0;
  if LodMode = 0 then
    Exit(GESampleLevel(ST, 0, MagLinear));
  var Bias := Integer(PC.LodBias);
  var Lod: Integer;
  if LodMode = 1 then
    Lod := Log16(Scale) + Bias
  else if LodMode = 2 then
    Lod := Bias
  else
    Lod := Log16(PC.LodSlope / W) + 16 + Bias;
  if Lod <= 0 then
    Exit(GESampleLevel(ST, 0, MagLinear));
  var MinFilter := Integer((PC.TexFunc shr 8) and 7);
  var MaxLevel := Integer((PC.TexFunc shr 13) and 7);
  var Linear := (MinFilter and 1) <> 0;
  if (MinFilter < 4) or (MaxLevel = 0) then
    Exit(GESampleLevel(ST, 0, Linear));
  Lod := Min(Lod, MaxLevel * 16);
  var Level := ArithmeticShiftRight(Lod, 4);
  var Frac := Lod and 15;
  if MinFilter < 6 then
  begin
    if Frac >= 8 then
      Inc(Level);
    Exit(GESampleAt(ST, Min(Level, MaxLevel), Linear));
  end;
  var C0 := GESampleAt(ST, Level, Linear);
  if (Frac = 0) or (Level >= MaxLevel) then
    Exit(C0);
  Result := ArithmeticShiftRight(C0 * (16 - Frac) + GESampleAt(ST, Level + 1, Linear) * Frac, 4);
end;

function FixedBlendSource(C: Integer4): Integer4;
begin
  var Flags := PC.Flags;
  var Premultiply := (Flags shr 12) and 3;
  if Premultiply = 1 then
  begin
    var Fix := UnpackRGB(PC.FixA);
    C.RGB := ArithmeticShiftRight((C.RGB + 1) * Fix, 8);
  end
  else if Premultiply = 2 then
    C.RGB := Clamp(ArithmeticShiftRight((C.RGB + 1) * C.A, 8) * 2, 0, 255)
  else if Premultiply = 3 then
    C.RGB := ArithmeticShiftRight((C.RGB + 1) * Max(0, 255 - 2 * C.A), 8);
  if (Flags and FLAG_DITHER) <> 0 then
    C.RGB := Clamp(C.RGB + DitherAt, 0, 255);
  if (Flags and FLAG_QUANTIZE) <> 0 then
    C.RGB := Quantize(C.RGB, (Flags shr 16) and 3);
  Result := C;
end;

function Shade(out ZR: Single; ShaderBlend: Boolean): Integer4;
begin
  var Flags := PC.Flags;
  var Format := (Flags shr 16) and 3;
  ZR := RoundEven(VZ);
  var C := Integer4(RoundFloat(Clamp(VColor, 0.0, 1.0) * 255.0));
  var Q: Single := VSTQW.Z;
  var Good := (Q <> 0.0) and ((Q > 0.0) = (VSTQW.W > 0.0));
  var ST: Single2 := (if Good then VSTQW.XY / Q else PC.TexSize - 0.5);
  var DX: Single2 := DdxFine(ST);
  var DY: Single2 := DdyFine(ST);
  if VBox.X <= VBox.Z then
    ST.X := Clamp(ST.X, VBox.X, VBox.Z);
  if VBox.Y <= VBox.W then
    ST.Y := Clamp(ST.Y, VBox.Y, VBox.W);
  var T := Integer4(0);
  if (Flags and FLAG_TEXTURED) <> 0 then
    T := GESampleTexture(ST, Max(Max(Abs(DX.X), Abs(DY.X)), Max(Abs(DX.Y), Abs(DY.Y))), VSTQW.W);
  if (Flags and FLAG_CLEAR) <> 0 then
  begin
    var RGB := C.RGB;
    if (Flags and FLAG_DITHER) <> 0 then
      RGB := Clamp(RGB + DitherAt, 0, 255);
    RGB := Quantize(RGB, Format);
    var S := C.A;
    if Format = 1 then
      S := ArithmeticShiftRight(S, 7) * 255
    else if Format = 2 then
      S := ArithmeticShiftRight(S, 4) * 17
    else if Format = 0 then
      S := 0;
    Exit(Integer4(RGB, S));
  end;
  if (Flags and FLAG_RANGE) <> 0 then
  begin
    var Z: Single := ZR;
    if (Flags and FLAG_CLAMPZ) <> 0 then
      Z := Clamp(Z, 0.0, 65535.0);
    if (Z < PC.MinZ) or (Z > PC.MaxZ) then
      Discard;
  end;
  if (Flags and FLAG_TEXTURED) <> 0 then
  begin
    var Func := PC.TexFunc and 7;
    var TexAlpha := (PC.TexFunc and 8) <> 0;
    var Dbl := (if (PC.TexFunc and 16) <> 0 then 2 else 1);
    if Func = 0 then
    begin
      C.RGB := Integer3(TexMul(C.R, T.R, Dbl), TexMul(C.G, T.G, Dbl), TexMul(C.B, T.B, Dbl));
      if TexAlpha then
        C.A := TexMul(C.A, T.A, 1);
    end
    else if Func = 1 then
    begin
      if TexAlpha then
        C.RGB := Integer3(TexLerp(C.R, T.R, T.A, Dbl), TexLerp(C.G, T.G, T.A, Dbl), TexLerp(C.B, T.B, T.A, Dbl))
      else
        C.RGB := Clamp(T.RGB * Dbl, 0, 255);
    end
    else if Func = 2 then
    begin
      var Env := UnpackRGB(PC.Env);
      C.RGB := Integer3(TexLerp(C.R, Env.R, T.R, Dbl), TexLerp(C.G, Env.G, T.G, Dbl), TexLerp(C.B, Env.B, T.B, Dbl));
      if TexAlpha then
        C.A := TexMul(C.A, T.A, 1);
    end
    else if Func = 3 then
    begin
      C.RGB := Clamp(T.RGB * Dbl, 0, 255);
      if TexAlpha then
        C.A := T.A;
    end
    else
    begin
      C.RGB := Clamp((C.RGB + T.RGB) * Dbl, 0, 255);
      if TexAlpha then
        C.A := TexMul(C.A, T.A, 1);
    end;
  end;
  C.RGB := Clamp(C.RGB + Integer3(RoundFloat(Clamp(VSecondary, 0.0, 1.0) * 255.0)), 0, 255);
  if (Flags and FLAG_FOG) <> 0 then
  begin
    var FI := Integer(Clamp(VFog, 0.0, 1.0) * 255.0);
    var Fog := UnpackRGB(PC.FogColor);
    C.RGB := Integer3(TexLerp(Fog.R, C.R, FI, 1), TexLerp(Fog.G, C.G, FI, 1), TexLerp(Fog.B, C.B, FI, 1));
  end;
  if (Flags and FLAG_COLORTEST) <> 0 then
  begin
    var Packed := Cardinal(C.R) or (Cardinal(C.G) shl 8) or (Cardinal(C.B) shl 16);
    var Func := (Flags shr 8) and 3;
    var Same := (Packed and PC.ColorMask) = (PC.ColorRef and PC.ColorMask);
    if (Func = 0) or ((Func = 2) and not Same) or ((Func = 3) and Same) then
      Discard;
  end;
  if (Flags and FLAG_ALPHATEST) <> 0 then
  begin
    var Mask := Integer((PC.AlphaTest shr 16) and 255);
    var Ref := Integer((PC.AlphaTest shr 8) and 255);
    if not TestFunc(PC.AlphaTest and 7, C.A and Mask, Ref and Mask) then
      Discard;
  end;
  if not ShaderBlend then
    C := FixedBlendSource(C);
  Result := C;
end;
