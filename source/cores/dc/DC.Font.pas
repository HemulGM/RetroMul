unit DC.Font;

// Fallback system font for the high-level boot ROM: the 12x24 glyphs of
// ISO 8859-1 at the boot ROM font address, drawn from the Hershey Simplex
// strokes (public domain, A. V. Hershey, U.S. National Bureau of Standards)
// with composed accents. Full-width (JIS X 0208) glyphs are left blank.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

// Writes the narrow glyphs (12x24, 36 bytes each, ASCII 20h..7Fh, then
// A0h..FFh; space and DEL blank) to Dest, the font area of the boot ROM.
procedure DCWriteFont(Dest: PByte);

implementation

uses
  System.SysUtils, System.Math;

const
  // Per character 21h..7Eh: the advance width, then x/y pairs (each value
  // offset by Ord('R'), y up from the baseline), a space lifting the pen.
  Strokes: array[33..126] of string = (
    '\WgWY WTVSWRXSWT',
    'bVgV` ^g^`',
    'g]kVK ck\K V^d^ UXcX',
    'fZkZN ^k^N cdaf^gZgWfUdUbV`W_Y^_\a[bZcXcUaS^RZRWSUU',
    'jggUR Zg\e\c[aY`W`UbUdVfXgZg\f_ebeefgg cYaX`V`TbRdRfSgUgWeYcY',
    'li^i_h`g`f_e]cXaU_S]RYRWSVTUVUXVZW[^__``b`d_f]g[fZdZb[_]\bUdSfRhRiSiT',
    '\WeVfWgXfXdWbVa',
    '`]k[iYfWbV]VYWTYP[M]K',
    '`UkWiYf[b\]\Y[TYPWMUK',
    'bZgZ[ Ud_^ _dU^',
    'l_d_R V[h[',
    '\XSWRVSWTXSXQWOVN',
    'lV[h[',
    '\WTVSWRXSWT',
    'hfkTK',
    'f[gXfVcU^U[VVXS[R]R`SbVc[c^bc`f]g[g',
    'fXcZd]g]R',
    'fVbVcWeXfZg^g`faebcbaa__\URcR',
    'fWgbg\___a^b]cZcXbU`S]RZRWSVTUV',
    'f_gUYdY _g_R',
    'fagWgV^W_Z`]``_b]cZcXbU`S]RZRWSVTUV',
    'fbdaf^g\gYfWcV^VYWUYS\R]R`SbUcXcYb\`^]_\_Y^W\VY',
    'fcgYR Ugcg',
    'fZgWfVdVbW`Y_]^`]b[cYcVbTaS^RZRWSVTUVUYV[X][^__a`bbbdaf^gZg',
    'fb`a]_[\Z[ZX[V]U`UaVdXf[g\g_fadb`b[aV_S\RZRWSVU',
    '\W`V_W^X_W` WTVSWRXSWT',
    '\W`V_W^X_W` XSWRVSWTXSXQWOVN',
    'jfdV[fR',
    'lV^h^ VXhX',
    'jVdf[VR',
    'dUbUcVeWfYg]g_f`eacaa`__^[\[Y [TZS[R\S[T',
    'md_caab^b\a[`Z]ZZ[X]W`WbXcZ ^b\`[][Z\X]W dbcZcXeWgWiYj\j^iahcfedfag^g[fYeWcVaU^U[VXWVYT[S^RaRdSfTgU ebdZdXeW',
    'd[gSR [gcR VY`Y',
    'gVgVR Vg_gbfcedcdac_b^_] V]_]b\c[dYdVcTbS_RVR',
    'gdbcdaf_g[gYfWdVbU_UZVWWUYS[R_RaScUdW',
    'gVgVR Vg]g`fbdcbd_dZcWbU`S]RVR',
    'eVgVR Vgcg V]^] VRcR',
    'dVgVR Vgcg V]^]',
    'gdbcdaf_g[gYfWdVbU_UZVWWUYS[R_RaScUdWdZ _ZdZ',
    'hVgVR dgdR V]d]',
    'ZVgVR',
    'b^g^W]T\SZRXRVSUTTWTY',
    'gVgVR dgVY [^dR',
    'cVgVR VRbR',
    'jVgVR Vg^R fg^R fgfR',
    'hVgVR VgdR dgdR',
    'h[gYfWdVbU_UZVWWUYS[R_RaScUdWeZe_dbcdaf_g[g',
    'gVgVR Vg_gbfcedcd`c^b]_\V\',
    'h[gYfWdVbU_UZVWWUYS[R_RaScUdWeZe_dbcdaf_g[g ^VdP',
    'gVgVR Vg_gbfcedcdac_b^_]V] ]]dR',
    'fcdaf^gZgWfUdUbV`W_Y^_\a[bZcXcUaS^RZRWSUU',
    'bZgZR Sgag',
    'hVgVXWUYS\R^RaScUdXdg',
    'dSg[R cg[R',
    'jTgYR ^gYR ^gcR hgcR',
    'fUgcR cgUR',
    'dSg[][R cg[]',
    'fcgUR Ugcg URcR',
    '`VkVK WkWK Vk]k VK]K',
    '`Rg`O',
    '`[k[K \k\K Uk\k UK\K',
    'bXaZd\a U^Zc_^ ZcZR',
    'bRPbP',
    '\XgWfVdVbWaXbWc',
    'ea`aR a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eVgVR V]X_Z`]`__a]bZbXaU_S]RZRXSVU',
    'da]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eagaR a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'dUZaZa\`^__]`Z`X_V]UZUXVUXSZR]R_SaU',
    '^\gZgXfWcWR T`[`',
    'ea`aP`M_L]KZKXL a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    'eVgVR V\Y_[`^``_a\aR',
    'ZUgVfWgVhUg V`VR',
    '\WgXfYgXhWg X`XOWLUKSK',
    'cVgVR ``VV ZZaR',
    'ZVgVR',
    'pV`VR V\Y_[`^``_a\aR a\d_f`i`k_l\lR',
    'eV`VR V\Y_[`^``_a\aR',
    'eZ`X_V]UZUXVUXSZR]R_SaUbXbZa]__]`Z`',
    'eV`VK V]X_Z`]`__a]bZbXaU_S]RZRXSVU',
    'ea`aK a]__]`Z`X_V]UZUXVUXSZR]R_SaU',
    '_V`VR VZW]Y_[`^`',
    'c`]__\`Y`V_U]V[XZ]Y_X`V`U_S\RYRVSUU',
    '^WgWVXSZR\R T`[`',
    'eV`VVWSYR\R^SaV a`aR',
    'bT`ZR ``ZR',
    'hU`YR ]`YR ]`aR e`aR',
    'cU``R ``UR',
    'bT`ZR ``ZRXNVLTKSK',
    'c``UR U``` UR`R',
    '`[kYjXiWgWeXcYbZ`Z^X\ YjXhXfYdZc[a[_Z]V[ZY[W[UZSYRXPXNYL XZZXZVYTXSWQWOXMYL[K',
    'ZVkVK',
    '`WkYjZi[g[eZcYbX`X^Z\ YjZhZfYdXcWaW_X]\[XYWWWUXSYRZPZNYL ZZXXXVYTZS[Q[OZMYLWK',
    'jUXUZV]X^Z^\]`ZbYdYfZg\ UZV\X]Z]\\`YbXdXfYg\g^');
  // A0h..FFh: base character and mark (` grave, / acute, ^ circumflex,
  // ~ tilde, : diaeresis, o ring, , cedilla, | slash, ! inverted, . dot,
  // v vertical bar, - none); a space base with no mark is blank.
  LatinBases = ' !c        < -       u     >   ?AAAAAA CEEEEIIII' +
    'DNOOOOOxOUUUUY  aaaaaa ceeeeiiiionooooo ouuuuypy';
  LatinMarks = '-!v-----:-------o---/--.,------!`/^~:o-,`/^:`/^:' +
    '-~`/^~:-|`/^:/--`/^~:o-,`/^:`/^:-~`/^~:-|`/^:/-:';

  CellWidth = 12;
  CellHeight = 24;
  // Hershey y runs from -7 (descender) to 25 (top); rows from the top.
  YScale = 23 / 32;
  PenRadius = 0.85;

type
  TSegment = record
    X0, Y0, X1, Y1: Single;
  end;

procedure AddStrokes(var Segments: TArray<TSegment>; const Points: array of Single);
begin
  for var I := 0 to Length(Points) div 2 - 2 do
  begin
    var S: TSegment;
    S.X0 := Points[I * 2];
    S.Y0 := Points[I * 2 + 1];
    S.X1 := Points[I * 2 + 2];
    S.Y1 := Points[I * 2 + 3];
    Segments := Segments + [S];
  end;
end;

// The strokes of an ASCII character; DotlessI drops the dot of i and j.
function Glyph(C: Char; DotlessI: Boolean; out Width: Integer): TArray<TSegment>;
begin
  Result := nil;
  Width := 16;
  if (Ord(C) < 33) or (Ord(C) > 126) then
    Exit;
  var Data := Strokes[Ord(C)];
  Width := Ord(Data[1]) - Ord('R');
  var HaveLast := False;
  var LX := 0;
  var LY := 0;
  var I := 2;
  while I <= Length(Data) do
  begin
    if Data[I] = ' ' then
    begin
      HaveLast := False;
      Inc(I);
      Continue;
    end;
    var X := Ord(Data[I]) - Ord('R');
    var Y := Ord(Data[I + 1]) - Ord('R');
    Inc(I, 2);
    if HaveLast and not (DotlessI and (LY > 15) and (Y > 15)) then
      AddStrokes(Result, [LX, LY, X, Y]);
    LX := X;
    LY := Y;
    HaveLast := True;
  end;
end;

function MarkStrokes(Mark: Char; CX, Top: Single): TArray<TSegment>;
begin
  Result := nil;
  case Mark of
    '`': AddStrokes(Result, [CX - 2, Top + 4, CX + 1, Top + 1]);
    '/': AddStrokes(Result, [CX + 2, Top + 4, CX - 1, Top + 1]);
    '^': AddStrokes(Result, [CX - 3, Top + 1, CX, Top + 4, CX + 3, Top + 1]);
    '~': AddStrokes(Result, [CX - 4, Top + 2, CX - 2, Top + 4, CX + 2, Top + 2, CX + 4, Top + 4]);
    ':':
      begin
        AddStrokes(Result, [CX - 3, Top + 2, CX - 3, Top + 3]);
        AddStrokes(Result, [CX + 3, Top + 2, CX + 3, Top + 3]);
      end;
    'o': AddStrokes(Result, [CX, Top + 1.5, CX + 1.5, Top + 2.5, CX + 1.5, Top + 3.5, CX, Top + 4.5,
      CX - 1.5, Top + 3.5, CX - 1.5, Top + 2.5, CX, Top + 1.5]);
    ',': AddStrokes(Result, [CX, 0, CX, -2, CX + 2, -3, CX - 1, -5]);
    '|': AddStrokes(Result, [CX - 6, -1, CX + 6, Top + 1]);
    'v': AddStrokes(Result, [CX, Top + 3, CX, -3]);
    '.': AddStrokes(Result, [CX, 9, CX, 10]);
  end;
end;

procedure Rasterize(const Segments: TArray<TSegment>; Width: Integer; Dest: PByte);
begin
  FillChar(Dest^, CellWidth * CellHeight div 8, 0);
  if Length(Segments) = 0 then
    Exit;
  var MinX := 1E9;
  var MaxX := -1E9;
  for var S in Segments do
  begin
    MinX := Min(MinX, Min(S.X0, S.X1));
    MaxX := Max(MaxX, Max(S.X0, S.X1));
  end;
  var XScale := 0.55;
  if (MaxX - MinX) * XScale > CellWidth - 1.2 then
    XScale := (CellWidth - 1.2) / (MaxX - MinX);
  var Center := Width / 2;
  for var Row := 0 to CellHeight - 1 do
    for var Col := 0 to CellWidth - 1 do
    begin
      var PX := Col + 0.5;
      var PY := Row + 0.5;
      var On := False;
      for var S in Segments do
      begin
        var AX := (S.X0 - Center) * XScale + CellWidth / 2;
        var AY := (25 - S.Y0) * YScale;
        var BX := (S.X1 - Center) * XScale + CellWidth / 2;
        var BY := (25 - S.Y1) * YScale;
        var DX := BX - AX;
        var DY := BY - AY;
        var Len := DX * DX + DY * DY;
        var T: Single := 0;
        if Len > 0 then
          T := EnsureRange(((PX - AX) * DX + (PY - AY) * DY) / Len, 0, 1);
        var QX := AX + T * DX - PX;
        var QY := AY + T * DY - PY;
        if QX * QX + QY * QY <= PenRadius * PenRadius then
        begin
          On := True;
          Break;
        end;
      end;
      if On then
      begin
        var Bit := Row * CellWidth + Col;
        (Dest + Bit div 8)^ := (Dest + Bit div 8)^ or ($80 shr (Bit mod 8));
      end;
    end;
end;

var
  // Built once; a published array is never changed again.
  FontCache: TBytes;

procedure BuildFont(Dest: PByte);
const
  GlyphBytes = CellWidth * CellHeight div 8;
begin
  for var C := 33 to 126 do
  begin
    var Width: Integer;
    var Segments := Glyph(Char(C), False, Width);
    Rasterize(Segments, Width, Dest + (C - 32) * GlyphBytes);
  end;
  for var C := $A0 to $FF do
  begin
    var Base := LatinBases[C - $A0 + 1];
    var Mark := LatinMarks[C - $A0 + 1];
    var Width := 16;
    var Segments: TArray<TSegment> := nil;
    if Base <> ' ' then
      Segments := Glyph(Base, CharInSet(Base, ['i', 'j']) and (Mark <> '-'), Width);
    if Mark = '!' then
      // Inverted punctuation hangs below the baseline.
      for var K := 0 to High(Segments) do
      begin
        Segments[K].X0 := Width - Segments[K].X0;
        Segments[K].X1 := Width - Segments[K].X1;
        Segments[K].Y0 := 14 - Segments[K].Y0;
        Segments[K].Y1 := 14 - Segments[K].Y1;
      end
    else if Mark <> '-' then
    begin
      var Top: Single := 14;
      if CharInSet(Base, ['A'..'Z']) then
        Top := 21
      else if Base = ' ' then
        Top := 16;
      Segments := Segments + MarkStrokes(Mark, Width / 2, Top);
    end;
    Rasterize(Segments, Width, Dest + (C - 64) * GlyphBytes);
  end;
end;

procedure DCWriteFont(Dest: PByte);
begin
  var Font := FontCache;
  if Font = nil then
  begin
    SetLength(Font, 192 * CellWidth * CellHeight div 8);
    BuildFont(@Font[0]);
    FontCache := Font;
  end;
  Move(Font[0], Dest^, Length(Font));
end;

end.
