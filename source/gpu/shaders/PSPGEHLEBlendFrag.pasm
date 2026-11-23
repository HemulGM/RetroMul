// Exact GE blend, dither, logic operations and bit masks in primitive order.
{$I PSPGEHLEPush.pasm}

var
  [PushConstant] PC: TGEHLEPush;
  [Input, Location(0), NoPerspective] VColor: Single4;
  [Input, Location(1), NoPerspective] VSecondary: Single3;
  [Input, Location(2), NoPerspective] VSTQW: Single4;
  [Input, Location(3), NoPerspective] VFog: Single;
  [Input, Location(4), NoPerspective] VZ: Single;
  [Input, Location(5), Flat] VBox: Single4;
  [Input, Builtin(FragCoord)] Pixel: Single4;
  [Binding(0, 0)] UTexture: CombinedTexture2D;
  [Binding(1, 0), Coherent] UTarget: Image2D_RGBA8;
  [Binding(1, 1)] UDepth: CombinedTexture2D;
  [Binding(1, 2)] UStencil: CombinedTexture2DUInt;

{$I PSPGEHLEFragment.pasm}
{$I PSPGEHLEBlend.pasm}

[Fragment, PixelInterlockOrdered, Vulkan11]
procedure Main;
begin
  var ZR: Single;
  var C := Shade(ZR, True);
  var P := Integer2(Pixel.XY);
  var Format := (PC.Flags shr 16) and 3;
  if (PC.Blend and (Cardinal(1) shl 23)) <> 0 then
  begin
    var Old := Integer(RoundFloat(TexelFetch(UDepth, P, 0).R * 65536.0));
    if not TestFunc((PC.Blend shr 20) and 7, Integer(Clamp(ZR, 0.0, 65535.0)), Old) then
      Discard;
  end;
  if (PC.Blend and (Cardinal(1) shl 27)) <> 0 then
  begin
    var ST := Integer(TexelFetch(UStencil, P, 0).R and 255);
    var Ref := Integer(PC.Stencil and 255);
    var Mask := Integer((PC.Stencil shr 8) and 255);
    if not TestFunc((PC.Blend shr 24) and 7, Ref and Mask, ST and Mask) then
      Discard;
  end;
  Interlock
  begin
    var DV: Single4 := ImageLoad(UTarget, P);
    var OldBits := EncodeColor(Integer3(RoundFloat(DV.RGB * 255.0)), Format);
    var D := DecodeColor(OldBits, Format);
    var R := C.RGB;
    if (PC.Blend and (Cardinal(1) shl 11)) <> 0 then
    begin
      var DA := (if Format = 0 then 0 else Integer(RoundFloat(DV.A * 255.0)));
      var FA := UnpackRGB(PC.FixA);
      var FB := UnpackRGB(PC.FixB);
      R := Integer3(BlendChannel(C.R, D.R, C.A, DA, FA.R, FB.R),
        BlendChannel(C.G, D.G, C.A, DA, FA.G, FB.G),
        BlendChannel(C.B, D.B, C.A, DA, FA.B, FB.B));
    end;
    if (PC.Flags and FLAG_DITHER) <> 0 then
      R := R + DitherAt;
    R := Clamp(R, 0, 255);
    var Bits := EncodeColor(R, Format);
    if (PC.Blend and (Cardinal(1) shl 16)) <> 0 then
      Bits := LogicOp((PC.Blend shr 12) and 15, Bits, OldBits);
    var ColorBits := EncodeColor(Integer3(255), Format);
    Bits := ((Bits and not PC.Keep) or (OldBits and PC.Keep)) and ColorBits;
    ImageStore(UTarget, P, Single4(Single3(DecodeColor(Bits, Format)) / 255.0, DV.A));
  end;
end;
