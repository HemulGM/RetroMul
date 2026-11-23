begin
  if not S.Through then
  begin
    var TestZ := F.Z;
    if S.DepthClamp then
    begin
      if TestZ < 0 then
        TestZ := 0;
      if TestZ > 65535 then
        TestZ := 65535;
    end;
    if (TestZ < S.MinZ) or (TestZ > S.MaxZ) then
      Exit;
  end;
{$IFDEF GEPIX_TEXTURE}
  // ApplyTexture, straight for modulate through a format sampler.
  if (S.TexFunc = 0) and Assigned(S.Tex.Sampler) and not S.Tex.NeedLod and not GEGenericTexels then
  begin
    var TC := S.Tex.Sampler(@S.Tex, F.S, F.T);
    var Dbl := 1;
    if S.ColorDouble then
      Dbl := 2;
    F.R := TexMul(F.R, Integer(TC and $FF), Dbl);
    F.G := TexMul(F.G, Integer((TC shr 8) and $FF), Dbl);
    F.B := TexMul(F.B, Integer((TC shr 16) and $FF), Dbl);
    if S.TexAlpha then
      F.A := TexMul(F.A, Integer(TC shr 24), 1);
  end
  else
    ApplyTexture(S, F);
{$ENDIF}
{$IFDEF GEPIX_EXTRA}
  // Secondary colour, then fog, as PlotPixel.
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
{$ENDIF}
  if S.AlphaTest then
    if not TestFunc(S.AlphaFunc, F.A and S.AlphaMask, S.AlphaRef and S.AlphaMask) then
      Exit;

{$IFDEF GEPIX_8888}
  var Addr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * 4) and (PSPVRAMSize - 1);
  var P := PCardinal(S.VRAM + Addr);
{$ELSE}
  var Addr := (S.FBAddr + (Cardinal(Y) * S.FBStride + Cardinal(X)) * 2) and (PSPVRAMSize - 1);
  var P := PWord(S.VRAM + Addr);
{$ENDIF}
  var Old := Cardinal(P^);
{$IF DEFINED(GEPIX_EXTRA) and not DEFINED(GEPIX_565)}
  // The stencil test and operations, as PlotPixel (a 565 target has none).
  {$IFDEF GEPIX_8888}
  const SFmt = 3;
  {$ELSEIF DEFINED(GEPIX_5551)}
  const SFmt = 1;
  {$ELSE}
  const SFmt = 2;
  {$ENDIF}
  var Stencil := RawStencil(SFmt, Old);
  var NewStencil := Stencil;
  var StencilWrite := False;
  if S.StencilTest then
  begin
    if not TestFunc(S.StencilFunc, S.StencilRef and S.StencilMask, StencilOf(SFmt, Old) and S.StencilMask) then
    begin
      NewStencil := StencilOp(S.StencilFail, SFmt, Stencil, S.StencilRef);
      if NewStencil <> Stencil then
      begin
        var NewP := (Old and not StencilBits(SFmt, $FF)) or StencilBits(SFmt, NewStencil);
        NewP := (NewP and not S.KeepMask) or (Old and S.KeepMask);
  {$IFDEF GEPIX_8888}
        P^ := NewP;
  {$ELSE}
        P^ := Word(NewP);
  {$ENDIF}
      end;
      Exit;
    end;
    StencilWrite := True;
  end;
{$ENDIF}
{$IFDEF GEPIX_DEPTH}
  var Z := F.Z;
  if Z < 0 then
    Z := 0;
  if Z > 65535 then
    Z := 65535;
  var ZA := PSPDepthOffset(S.ZAddr + (Cardinal(Y) * S.ZStride + Cardinal(X)) * 2, S.ZPermutation);
  var ZP := PWord(S.VRAM + ZA);
  if not TestFunc(S.DepthFunc, Z, ZP^) then
  begin
  {$IF DEFINED(GEPIX_EXTRA) and not DEFINED(GEPIX_565)}
    if StencilWrite then
    begin
      NewStencil := StencilOp(S.StencilZFail, SFmt, Stencil, S.StencilRef);
      if NewStencil <> Stencil then
      begin
        var NewP := (Old and not StencilBits(SFmt, $FF)) or StencilBits(SFmt, NewStencil);
        NewP := (NewP and not S.KeepMask) or (Old and S.KeepMask);
    {$IFDEF GEPIX_8888}
        P^ := NewP;
    {$ELSE}
        P^ := Word(NewP);
    {$ENDIF}
      end;
    end;
  {$ENDIF}
    Exit;
  end;
{$ENDIF}
{$IF DEFINED(GEPIX_EXTRA) and not DEFINED(GEPIX_565)}
  if StencilWrite then
    NewStencil := StencilOp(S.StencilZPass, SFmt, Stencil, S.StencilRef);
{$ENDIF}
{$IFDEF GEPIX_DEPTH}
  if S.DepthWrite then
    ZP^ := Word(Z);
{$ENDIF}

  var R := F.R;
  var G := F.G;
  var B := F.B;
{$IFDEF GEPIX_BLEND}
  var DR, DG, DB, DA: Integer;
  {$IFDEF GEPIX_8888}
  DecodePixel(3, Old, DR, DG, DB, DA);
  {$ELSEIF DEFINED(GEPIX_565)}
  DecodePixel(0, Old, DR, DG, DB, DA);
  {$ELSEIF DEFINED(GEPIX_5551)}
  DecodePixel(1, Old, DR, DG, DB, DA);
  {$ELSE}
  DecodePixel(2, Old, DR, DG, DB, DA);
  {$ENDIF}
  // BlendChannel, straight for the common equations.
  case S.BlendKind of
    1:
      begin
        var SA := F.A;
        var DF := 255 - SA;
        R := BlendMul(R, SA) + BlendMul(DR, DF);
        G := BlendMul(G, SA) + BlendMul(DG, DF);
        B := BlendMul(B, SA) + BlendMul(DB, DF);
      end;
    2:
      begin
        var SA := F.A;
        var Fix := S.FixB;
        R := BlendMul(R, SA) + BlendMul(DR, Integer(Fix and $FF));
        G := BlendMul(G, SA) + BlendMul(DG, Integer((Fix shr 8) and $FF));
        B := BlendMul(B, SA) + BlendMul(DB, Integer((Fix shr 16) and $FF));
      end;
  else
    R := BlendChannel(S, R, DR, F.A, DA, 0);
    G := BlendChannel(S, G, DG, F.A, DA, 8);
    B := BlendChannel(S, B, DB, F.A, DA, 16);
  end;
{$ENDIF}
  if S.Dither then
  begin
    var D := S.DitherMatrix[(Y and 3) * 4 + (X and 3)];
    Inc(R, D);
    Inc(G, D);
    Inc(B, D);
  end;
  R := Clamp255(R);
  G := Clamp255(G);
  B := Clamp255(B);
{$IFDEF GEPIX_8888}
  var C := (Old and $FF000000) or Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16);
{$ELSEIF DEFINED(GEPIX_565)}
  var C := Cardinal(R shr 3) or (Cardinal(G shr 2) shl 5) or (Cardinal(B shr 3) shl 11);
{$ELSEIF DEFINED(GEPIX_5551)}
  var C := (Old and $8000) or Cardinal(R shr 3) or (Cardinal(G shr 3) shl 5) or (Cardinal(B shr 3) shl 10);
{$ELSE}
  var C := (Old and $F000) or Cardinal(R shr 4) or (Cardinal(G shr 4) shl 4) or (Cardinal(B shr 4) shl 8);
{$ENDIF}
{$IF DEFINED(GEPIX_EXTRA) and not DEFINED(GEPIX_565)}
  if StencilWrite then
    C := (C and not StencilBits(SFmt, $FF)) or StencilBits(SFmt, NewStencil);
{$ENDIF}
  C := (C and not S.KeepMask) or (Old and S.KeepMask);
{$IFDEF GEPIX_8888}
  P^ := C;
{$ELSE}
  P^ := Word(C);
{$ENDIF}
end;
