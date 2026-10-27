unit Audio.MP3.Layer3;

{$POINTERMATH ON}

{
  Audio.MP3.Layer3.pas - MPEG-1/2/2.5 Layer III full decode pipeline

  Supports MPEG1, MPEG2, and MPEG2.5
  Translated from minimp3.h by lieff
  Original: https://github.com/lieff/minimp3

  License: CC0 1.0 Universal (Public Domain)
  https://creativecommons.org/publicdomain/zero/1.0/

  To the extent possible under law, the author(s) of the original minimp3
  have dedicated all copyright and related and neighboring rights to this
  software to the public domain worldwide.
}

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, Audio.MP3.Types,
  Audio.MP3.BitStream, Audio.MP3.Huffman, Audio.MP3.ScaleFactors;

type
  TMP3Layer3Decoder = class
  private
    FDec: TMP3Dec;

    procedure DoL3Decode(var bs: TBsT; var gr_info: array of TL3GrInfo; nch: Integer; grbuf: array of PSingle; scf_ptrs: array of PSingle; ist_ptrs: array of PByte);

    procedure BuildGrInfo(const Header: TMP3FrameHeader; const SideInfo: TMP3SideInfo; GranIdx: Integer; var gr_info: array of TL3GrInfo);

  public
    constructor Create;
    procedure SerializeState(State: TStateArchive);

    procedure DecodeFrame(const Header: TMP3FrameHeader; const SideInfo: TMP3SideInfo; const MainDataBuf: TBytes; MainDataBegin: Integer; out PCMLeft, PCMRight: TArray<Single>);
  end;

implementation

procedure L3_midside_stereo(left: PSingle; n: Integer);
var
  i: Integer;
  right: PSingle;
  a, b: Single;
begin
  right := left + 576;
  for i := 0 to n - 1 do
  begin
    a := PSingle(left)[i];
    b := PSingle(right)[i];
    PSingle(left)[i] := a + b;
    PSingle(right)[i] := a - b;
  end;
end;

procedure L3_intensity_stereo_band(left: PSingle; n: Integer; kl, kr: Single);
var
  i: Integer;
  right: PSingle;
begin
  right := left + 576;
  for i := 0 to n - 1 do
  begin
    PSingle(right)[i] := PSingle(left)[i] * kr;
    PSingle(left)[i] := PSingle(left)[i] * kl;
  end;
end;

procedure L3_stereo_top_band(right: PSingle; sfb: PByte; nbands: Integer; max_band: PInteger);
var
  i, k: Integer;
  p: PSingle;
begin
  PIntegerArray(max_band)[0] := -1;
  PIntegerArray(max_band)[1] := -1;
  PIntegerArray(max_band)[2] := -1;
  p := right;
  for i := 0 to nbands - 1 do
  begin
    k := 0;
    while k < Integer(PByteArray(sfb)[i]) do
    begin
      if (PSingle(p)[k] <> 0) or (PSingle(p)[k + 1] <> 0) then
      begin
        PIntegerArray(max_band)[i mod 3] := i;
        Break;
      end;
      Inc(k, 2);
    end;
    Inc(p, PByteArray(sfb)[i]);
  end;
end;

procedure L3_stereo_process(left: PSingle; ist_pos: PByte; sfb: PByte; const hdr: array of Byte; max_band: PInteger; mpeg2_sh: Integer);
const
  g_pan: array[0..13] of Single = (
    0, 1, 0.21132487, 0.78867513, 0.36602540, 0.63397460,
    0.5, 0.5,
    0.63397460, 0.36602540, 0.78867513, 0.21132487, 1, 0
  );
var
  i: Integer;
  max_pos: Cardinal;
  ipos: Cardinal;
  kl, kr, s: Single;
  p: PSingle;
begin
  if HDR_TEST_MPEG1(hdr) then
    max_pos := 7
  else
    max_pos := 64;
  p := left;
  i := 0;
  while PByteArray(sfb)[i] <> 0 do
  begin
    ipos := PByteArray(ist_pos)[i];
    if (i > PIntegerArray(max_band)[i mod 3]) and (ipos < max_pos) then
    begin
      if HDR_TEST_MS_STEREO(hdr) then
        s := 1.41421356
      else
        s := 1.0;
      if HDR_TEST_MPEG1(hdr) then
      begin
        kl := g_pan[2 * ipos];
        kr := g_pan[2 * ipos + 1];
      end
      else
      begin
        kl := 1.0;
        kr := L3_ldexp_q2(1.0, Integer((ipos + 1) shr 1) shl mpeg2_sh);
        if (ipos and 1) <> 0 then
        begin
          kl := kr;
          kr := 1.0;
        end;
      end;
      L3_intensity_stereo_band(p, PByteArray(sfb)[i], kl * s, kr * s);
    end
    else if HDR_TEST_MS_STEREO(hdr) then
      L3_midside_stereo(p, PByteArray(sfb)[i]);
    Inc(p, PByteArray(sfb)[i]);
    Inc(i);
  end;
end;

procedure L3_intensity_stereo(left: PSingle; ist_pos: PByte; gr_ptr: PByte; const hdr: array of Byte);
var
  max_band: array[0..2] of Integer;
  n_sfb, i, max_blocks, mx: Integer;
  default_pos, itop, prev: Integer;
  gr0, gr1: ^TL3GrInfo;
begin
  gr0 := Pointer(gr_ptr);
  gr1 := Pointer(gr_ptr + SizeOf(TL3GrInfo));

  n_sfb := gr0^.n_long_sfb + gr0^.n_short_sfb;
  if gr0^.n_short_sfb <> 0 then
    max_blocks := 3
  else
    max_blocks := 1;

  L3_stereo_top_band(left + 576, gr0^.sfbtab, n_sfb, @max_band[0]);

  if gr0^.n_long_sfb <> 0 then
  begin
    mx := max_band[0];
    if max_band[1] > mx then
      mx := max_band[1];
    if max_band[2] > mx then
      mx := max_band[2];
    max_band[0] := mx;
    max_band[1] := mx;
    max_band[2] := mx;
  end;

  for i := 0 to max_blocks - 1 do
  begin
    if HDR_TEST_MPEG1(hdr) then
      default_pos := 3
    else
      default_pos := 0;
    itop := n_sfb - max_blocks + i;
    prev := itop - max_blocks;
    if PIntegerArray(@max_band)[i] >= prev then
      PByteArray(ist_pos)[itop] := default_pos
    else
      PByteArray(ist_pos)[itop] := PByteArray(ist_pos)[prev];
  end;

  L3_stereo_process(left, ist_pos, gr0^.sfbtab, hdr, @max_band[0],
    Integer(gr1^.scalefac_compress) and 1);
end;

procedure L3_reorder(grbuf: PSingle; scratch: PSingle; sfb: PByte);
var
  len, i: Integer;
  src, dst: PSingle;
begin
  src := grbuf;
  dst := scratch;
  while PByteArray(sfb)[0] <> 0 do
  begin
    len := PByteArray(sfb)[0];
    for i := 0 to len - 1 do
    begin
      dst^ := PSingle(src + 0 * len + i)^;
      Inc(dst);
      dst^ := PSingle(src + 1 * len + i)^;
      Inc(dst);
      dst^ := PSingle(src + 2 * len + i)^;
      Inc(dst);
    end;
    Inc(sfb, 3);
    Inc(src, 3 * len);
  end;
  Move(scratch^, grbuf^, Integer(dst - scratch) * SizeOf(Single));
end;

procedure L3_antialias(grbuf: PSingle; nbands: Integer);
var
  i: Integer;
  u, d: Single;
  p: PSingle;
begin
  p := grbuf;
  while nbands > 0 do
  begin
    for i := 0 to 7 do
    begin
      u := PSingle(p)[18 + i];
      d := PSingle(p)[17 - i];
      PSingle(p)[18 + i] := u * g_aa_cs[i] - d * g_aa_ca[i];
      PSingle(p)[17 - i] := u * g_aa_ca[i] + d * g_aa_cs[i];
    end;
    Inc(p, 18);
    Dec(nbands);
  end;
end;

procedure L3_dct3_9(y: PSingle);
var
  s0, s1, s2, s3, s4, s5, s6, s7, s8, t0, t2, t4: Single;
begin
  s0 := PSingle(y)[0];
  s2 := PSingle(y)[2];
  s4 := PSingle(y)[4];
  s6 := PSingle(y)[6];
  s8 := PSingle(y)[8];
  t0 := s0 + s6 * 0.5;
  s0 := s0 - s6;
  t4 := (s4 + s2) * 0.93969262;
  t2 := (s8 + s2) * 0.76604444;
  s6 := (s4 - s8) * 0.17364818;
  s4 := s4 + s8 - s2;
  s2 := s0 - s4 * 0.5;
  PSingle(y)[4] := s4 + s0;
  s8 := t0 - t2 + s6;
  s0 := t0 - t4 + t2;
  s4 := t0 + t4 - s6;

  s1 := PSingle(y)[1];
  s3 := PSingle(y)[3];
  s5 := PSingle(y)[5];
  s7 := PSingle(y)[7];
  s3 := s3 * 0.86602540;
  t0 := (s5 + s1) * 0.98480775;
  t4 := (s5 - s7) * 0.34202014;
  t2 := (s1 + s7) * 0.64278761;
  s1 := (s1 - s5 - s7) * 0.86602540;

  s5 := t0 - s3 - t2;
  s7 := t4 - s3 - t0;
  s3 := t4 + s3 - t2;

  PSingle(y)[0] := s4 - s7;
  PSingle(y)[1] := s2 + s1;
  PSingle(y)[2] := s0 - s3;
  PSingle(y)[3] := s8 + s5;
  PSingle(y)[5] := s8 - s5;
  PSingle(y)[6] := s0 + s3;
  PSingle(y)[7] := s2 - s1;
  PSingle(y)[8] := s4 + s7;
end;

procedure L3_imdct36(grbuf: PSingle; overlap: PSingle; const window: array of Single; nbands: Integer);
var
  i, j: Integer;
  co, si: array[0..8] of Single;
  ovl, sum: Single;
  gb, ov: PSingle;
begin
  gb := grbuf;
  ov := overlap;
  for j := 0 to nbands - 1 do
  begin
    co[0] := -PSingle(gb)[0];
    si[0] := PSingle(gb)[17];
    for i := 0 to 3 do
    begin
      si[8 - 2 * i] := PSingle(gb)[4 * i + 1] - PSingle(gb)[4 * i + 2];
      co[1 + 2 * i] := PSingle(gb)[4 * i + 1] + PSingle(gb)[4 * i + 2];
      si[7 - 2 * i] := PSingle(gb)[4 * i + 4] - PSingle(gb)[4 * i + 3];
      co[2 + 2 * i] := -(PSingle(gb)[4 * i + 3] + PSingle(gb)[4 * i + 4]);
    end;
    L3_dct3_9(@co[0]);
    L3_dct3_9(@si[0]);

    si[1] := -si[1];
    si[3] := -si[3];
    si[5] := -si[5];
    si[7] := -si[7];

    for i := 0 to 8 do
    begin
      ovl := PSingle(ov)[i];
      sum := co[i] * g_twid9[9 + i] + si[i] * g_twid9[i];
      PSingle(ov)[i] := co[i] * g_twid9[i] - si[i] * g_twid9[9 + i];
      PSingle(gb)[i] := ovl * window[i] - sum * window[9 + i];
      PSingle(gb)[17 - i] := ovl * window[9 + i] + sum * window[i];
    end;
    Inc(gb, 18);
    Inc(ov, 9);
  end;
end;

procedure L3_idct3(x0, x1, x2: Single; dst: PSingle);
var
  m1, a1: Single;
begin
  m1 := x1 * 0.86602540;
  a1 := x0 - x2 * 0.5;
  PSingle(dst)[1] := x0 + x2;
  PSingle(dst)[0] := a1 + m1;
  PSingle(dst)[2] := a1 - m1;
end;

procedure L3_imdct12(x: PSingle; dst: PSingle; overlap: PSingle);
var
  co, si: array[0..2] of Single;
  i: Integer;
  ovl, sum: Single;
begin
  L3_idct3(-PSingle(x)[0], PSingle(x)[6] + PSingle(x)[3], PSingle(x)[12] + PSingle(x)[9], @co[0]);
  L3_idct3(PSingle(x)[15], PSingle(x)[12] - PSingle(x)[9], PSingle(x)[6] - PSingle(x)[3], @si[0]);
  si[1] := -si[1];

  for i := 0 to 2 do
  begin
    ovl := PSingle(overlap)[i];
    sum := co[i] * g_twid3[3 + i] + si[i] * g_twid3[i];
    PSingle(overlap)[i] := co[i] * g_twid3[i] - si[i] * g_twid3[3 + i];
    PSingle(dst)[i] := ovl * g_twid3[2 - i] - sum * g_twid3[5 - i];
    PSingle(dst)[5 - i] := ovl * g_twid3[5 - i] + sum * g_twid3[2 - i];
  end;
end;

procedure L3_imdct_short(grbuf: PSingle; overlap: PSingle; nbands: Integer);
var
  tmp: array[0..17] of Single;
begin
  while nbands > 0 do
  begin
    Move(grbuf^, tmp[0], 18 * SizeOf(Single));
    Move(overlap^, grbuf^, 6 * SizeOf(Single));
    L3_imdct12(@tmp[0], grbuf + 6, overlap + 6);
    L3_imdct12(@tmp[1], grbuf + 12, overlap + 6);
    L3_imdct12(@tmp[2], overlap, overlap + 6);
    Inc(overlap, 9);
    Inc(grbuf, 18);
    Dec(nbands);
  end;
end;

procedure L3_change_sign(grbuf: PSingle);
var
  b, i: Integer;
  p: PSingle;
begin
  p := grbuf + 18;
  b := 0;
  while b < 32 do
  begin
    i := 1;
    while i < 18 do
    begin
      PSingle(p)[i] := -PSingle(p)[i];
      Inc(i, 2);
    end;
    Inc(p, 36);   // skip 2 subbands (b += 2)
    Inc(b, 2);
  end;
end;

procedure L3_imdct_gr(grbuf: PSingle; overlap: PSingle; block_type: Cardinal; n_long_bands: Cardinal);
begin
  if n_long_bands > 0 then
  begin
    L3_imdct36(grbuf, overlap, g_mdct_window[0], n_long_bands);
    Inc(grbuf, 18 * Integer(n_long_bands));
    Inc(overlap, 9 * Integer(n_long_bands));
  end;
  if block_type = SHORT_BLOCK_TYPE then
    L3_imdct_short(grbuf, overlap, 32 - Integer(n_long_bands))
  else if block_type = STOP_BLOCK_TYPE then
    L3_imdct36(grbuf, overlap, g_mdct_window[1], 32 - Integer(n_long_bands))
  else
    L3_imdct36(grbuf, overlap, g_mdct_window[0], 32 - Integer(n_long_bands));
end;

procedure mp3d_DCT_II(grbuf: PSingle; n: Integer);
var
  k, i: Integer;
  t: array[0..3, 0..7] of Single;
  x: PSingle;
  y: PSingle;
  x0, x1, x2, x3, x4, x5, x6, x7, xt: Single;
  tt0, tt1, tt2, tt3: Single;
begin
  for k := 0 to n - 1 do
  begin
    y := PSingle(grbuf + k);

    // First stage: butterfly pairs
    for i := 0 to 7 do
    begin
      tt0 := y[i * 18] + y[(31 - i) * 18];
      tt1 := y[(15 - i) * 18] + y[(16 + i) * 18];
      tt2 := (y[(15 - i) * 18] - y[(16 + i) * 18]) * g_sec[3 * i];
      tt3 := (y[i * 18] - y[(31 - i) * 18]) * g_sec[3 * i + 1];
      t[0][i] := tt0 + tt1;
      t[1][i] := (tt0 - tt1) * g_sec[3 * i + 2];
      t[2][i] := tt3 + tt2;
      t[3][i] := (tt3 - tt2) * g_sec[3 * i + 2];
    end;

    // Second stage: radix-8 butterflies on each row
    for i := 0 to 3 do
    begin
      x := PSingle(@t[i][0]);
      x0 := x[0];
      x1 := x[1];
      x2 := x[2];
      x3 := x[3];
      x4 := x[4];
      x5 := x[5];
      x6 := x[6];
      x7 := x[7];

      xt := x0 - x7;
      x0 := x0 + x7;
      x7 := x1 - x6;
      x1 := x1 + x6;
      x6 := x2 - x5;
      x2 := x2 + x5;
      x5 := x3 - x4;
      x3 := x3 + x4;
      x4 := x0 - x3;
      x0 := x0 + x3;
      x3 := x1 - x2;
      x1 := x1 + x2;

      x[0] := x0 + x1;
      x[4] := (x0 - x1) * 0.70710677;
      x5 := x5 + x6;
      x6 := (x6 + x7) * 0.70710677;
      x7 := x7 + xt;
      x3 := (x3 + x4) * 0.70710677;
      x5 := x5 - x7 * 0.198912367;
      x7 := x7 + x5 * 0.382683432;
      x5 := x5 - x7 * 0.198912367;
      x0 := xt - x6;
      xt := xt + x6;
      x[1] := (xt + x7) * 0.50979561;
      x[2] := (x4 + x3) * 0.54119611;
      x[3] := (x0 - x5) * 0.60134488;
      x[5] := (x0 + x5) * 0.89997619;
      x[6] := (x4 - x3) * 1.30656302;
      x[7] := (xt - x7) * 2.56291556;
    end;

    // Write output: interleave the 4 rows
    for i := 0 to 6 do
    begin
      y[0 * 18] := t[0][i];
      y[1 * 18] := t[2][i] + t[3][i] + t[3][i + 1];
      y[2 * 18] := t[1][i] + t[1][i + 1];
      y[3 * 18] := t[2][i + 1] + t[3][i] + t[3][i + 1];
      y := PSingle(@y[4 * 18]);
    end;
    y[0 * 18] := t[0][7];
    y[1 * 18] := t[2][7] + t[3][7];
    y[2 * 18] := t[1][7];
    y[3 * 18] := t[3][7];
  end;
end;

function mp3d_scale_pcm(sample: Single): SmallInt;
var
  s: Integer;
begin
  if sample >= 32766.5 then
  begin
    Result := 32767;
    Exit;
  end;
  if sample <= -32767.5 then
  begin
    Result := -32768;
    Exit;
  end;
  s := Trunc(sample + 0.5);
  if s < 0 then
    Dec(s);
  Result := SmallInt(s);
end;

procedure mp3d_synth_pair(pcm: PSmallInt; nch: Integer; z: PSingle);
var
  a: Single;
begin
  a := (PSingle(z)[14 * 64] - PSingle(z)[0]) * 29
    + (PSingle(z)[1 * 64] + PSingle(z)[13 * 64]) * 213
    + (PSingle(z)[12 * 64] - PSingle(z)[2 * 64]) * 459
    + (PSingle(z)[3 * 64] + PSingle(z)[11 * 64]) * 2037
    + (PSingle(z)[10 * 64] - PSingle(z)[4 * 64]) * 5153
    + (PSingle(z)[5 * 64] + PSingle(z)[9 * 64]) * 6574
    + (PSingle(z)[8 * 64] - PSingle(z)[6 * 64]) * 37489
    + PSingle(z)[7 * 64] * 75038;
  PSmallInt(pcm)[0] := mp3d_scale_pcm(a);

  Inc(z, 2);
  a := PSingle(z)[14 * 64] * 104
    + PSingle(z)[12 * 64] * 1567
    + PSingle(z)[10 * 64] * 9727
    + PSingle(z)[8 * 64] * 64019
    + PSingle(z)[6 * 64] * (-9975)
    + PSingle(z)[4 * 64] * (-45)
    + PSingle(z)[2 * 64] * 146
    + PSingle(z)[0 * 64] * (-5);
  PSmallInt(pcm)[16 * nch] := mp3d_scale_pcm(a);
end;

procedure mp3d_synth(xl: PSingle; dstl: PSmallInt; nch: Integer; lins: PSingle);
var
  i, j: Integer;
  xr: PSingle;
  dstr: PSmallInt;
  zlin: PSingle;
  w: PSingle;
  a, b: array[0..3] of Single;
  w0, w1: Single;
  vz, vy: PSingle;
  xla, xra: PSingle;
  dstla, dstra: PSmallInt;
begin
  xr := xl + 576 * (nch - 1);
  dstr := dstl + (nch - 1);
  zlin := PSingle(lins + 15 * 64);
  w := @g_win[0];
  xla := PSingle(xl);
  xra := PSingle(xr);
  dstla := PSmallInt(dstl);
  dstra := PSmallInt(dstr);

  zlin[4 * 15] := xla[18 * 16];
  zlin[4 * 15 + 1] := xra[18 * 16];
  zlin[4 * 15 + 2] := xla[0];
  zlin[4 * 15 + 3] := xra[0];

  zlin[4 * 31] := xla[1 + 18 * 16];
  zlin[4 * 31 + 1] := xra[1 + 18 * 16];
  zlin[4 * 31 + 2] := xla[1];
  zlin[4 * 31 + 3] := xra[1];

  mp3d_synth_pair(dstr, nch, lins + 4 * 15 + 1);
  mp3d_synth_pair(dstr + 32 * nch, nch, lins + 4 * 15 + 64 + 1);
  mp3d_synth_pair(dstl, nch, lins + 4 * 15);
  mp3d_synth_pair(dstl + 32 * nch, nch, lins + 4 * 15 + 64);

  // S0,S2,S1,S2,S1,S2,S1,S2 pattern for k=0..7
  for i := 14 downto 0 do
  begin
    // Fill zlin
    zlin[4 * i] := xla[18 * (31 - i)];
    zlin[4 * i + 1] := xra[18 * (31 - i)];
    zlin[4 * i + 2] := xla[1 + 18 * (31 - i)];
    zlin[4 * i + 3] := xra[1 + 18 * (31 - i)];
    zlin[4 * (i + 16)] := xla[1 + 18 * (1 + i)];
    zlin[4 * (i + 16) + 1] := xra[1 + 18 * (1 + i)];
    zlin[4 * (i - 16) + 2] := xla[18 * (1 + i)];
    zlin[4 * (i - 16) + 3] := xra[18 * (1 + i)];

    // S0(0): b = vz*w1+vy*w0, a = vz*w0-vy*w1
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 0 * 64];
    vy := @zlin[4 * i - 15 * 64];
    for j := 0 to 3 do
    begin
      b[j] := vz[j] * w1 + vy[j] * w0;
      a[j] := vz[j] * w0 - vy[j] * w1;
    end;

    // S2(1): a += vy*w1 - vz*w0
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 1 * 64];
    vy := @zlin[4 * i - 14 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vy[j] * w1 - vz[j] * w0;
    end;

    // S1(2): a += vz*w0 - vy*w1
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 2 * 64];
    vy := @zlin[4 * i - 13 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vz[j] * w0 - vy[j] * w1;
    end;

    // S2(3)
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 3 * 64];
    vy := @zlin[4 * i - 12 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vy[j] * w1 - vz[j] * w0;
    end;

    // S1(4)
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 4 * 64];
    vy := @zlin[4 * i - 11 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vz[j] * w0 - vy[j] * w1;
    end;

    // S2(5)
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 5 * 64];
    vy := @zlin[4 * i - 10 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vy[j] * w1 - vz[j] * w0;
    end;

    // S1(6)
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 6 * 64];
    vy := @zlin[4 * i - 9 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vz[j] * w0 - vy[j] * w1;
    end;

    // S2(7)
    w0 := w^;
    Inc(w);
    w1 := w^;
    Inc(w);
    vz := @zlin[4 * i - 7 * 64];
    vy := @zlin[4 * i - 8 * 64];
    for j := 0 to 3 do
    begin
      b[j] := b[j] + vz[j] * w1 + vy[j] * w0;
      a[j] := a[j] + vy[j] * w1 - vz[j] * w0;
    end;

    dstra[(15 - i) * nch] := mp3d_scale_pcm(a[1]);
    dstra[(17 + i) * nch] := mp3d_scale_pcm(b[1]);
    dstla[(15 - i) * nch] := mp3d_scale_pcm(a[0]);
    dstla[(17 + i) * nch] := mp3d_scale_pcm(b[0]);
    dstra[(47 - i) * nch] := mp3d_scale_pcm(a[3]);
    dstra[(49 + i) * nch] := mp3d_scale_pcm(b[3]);
    dstla[(47 - i) * nch] := mp3d_scale_pcm(a[2]);
    dstla[(49 + i) * nch] := mp3d_scale_pcm(b[2]);
  end;
end;

procedure mp3d_synth_granule(qmf_state: PSingle; grbuf: PSingle; nbands, nch: Integer; pcm: PSmallInt; lins: PSingle);
var
  i: Integer;
begin
  for i := 0 to nch - 1 do
    mp3d_DCT_II(grbuf + 576 * i, nbands);

  Move(qmf_state^, lins^, SizeOf(Single) * 15 * 64);

  i := 0;
  while i < nbands do
  begin
    mp3d_synth(grbuf + i, pcm + 32 * nch * i, nch, lins + i * 64);
    Inc(i, 2);
  end;

  // Preserve the inactive right filter history across mono/stereo transitions.
  if nch = 1 then
  begin
    i := 0;
    while i < 15 * 64 do
    begin
      qmf_state[i] := lins[nbands * 64 + i];
      Inc(i, 2);
    end;
  end
  else
    Move((lins + nbands * 64)^, qmf_state^, SizeOf(Single) * 15 * 64);
end;

procedure TMP3Layer3Decoder.DoL3Decode(var bs: TBsT; var gr_info: array of TL3GrInfo; nch: Integer; grbuf: array of PSingle; scf_ptrs: array of PSingle; ist_ptrs: array of PByte);
var
  ch, layer3gr_limit: Integer;
  aa_bands, n_long_bands: Integer;
  sr_idx: Integer;
  scratch: array[0..575] of Single;
  hdr: array[0..3] of Byte;
begin
  hdr[0] := FDec.header[0];
  hdr[1] := FDec.header[1];
  hdr[2] := FDec.header[2];
  hdr[3] := FDec.header[3];

  // Decode scalefactors + Huffman for each channel
  for ch := 0 to nch - 1 do
  begin
    layer3gr_limit := bs.pos + gr_info[ch].part_23_length;
    L3_decode_scalefactors(hdr, ist_ptrs[ch], bs, gr_info[ch], scf_ptrs[ch], ch);
    L3_huffman(grbuf[ch], bs, gr_info[ch], scf_ptrs[ch], layer3gr_limit);
  end;

  // Stereo processing
  if HDR_TEST_I_STEREO(hdr) then
    L3_intensity_stereo(grbuf[0], ist_ptrs[1], @gr_info[0], hdr)
  else if HDR_IS_MS_STEREO(hdr) then
    L3_midside_stereo(grbuf[0], 576);

  // Compute sample rate index for n_long_bands
  sr_idx := HDR_GET_MY_SAMPLE_RATE(hdr);
  if sr_idx <> 0 then
    Dec(sr_idx);

  // Per-channel post-processing
  for ch := 0 to nch - 1 do
  begin
    aa_bands := 31;
    if gr_info[ch].mixed_block_flag <> 0 then
      n_long_bands := 2 shl Ord(sr_idx = 2)
    else
      n_long_bands := 0;

    if gr_info[ch].n_short_sfb <> 0 then
    begin
      aa_bands := n_long_bands - 1;
      FillChar(scratch, SizeOf(scratch), 0);
      L3_reorder(grbuf[ch] + n_long_bands * 18, @scratch[0],
        gr_info[ch].sfbtab + gr_info[ch].n_long_sfb);
    end;

    L3_antialias(grbuf[ch], aa_bands);
    L3_imdct_gr(grbuf[ch], @FDec.mdct_overlap[ch][0],
      gr_info[ch].block_type, n_long_bands);
    L3_change_sign(grbuf[ch]);
  end;
end;

procedure TMP3Layer3Decoder.BuildGrInfo(const Header: TMP3FrameHeader; const SideInfo: TMP3SideInfo; GranIdx: Integer; var gr_info: array of TL3GrInfo);
var
  ch, nch: Integer;
  gi: ^TGranuleInfo;
  gr: ^TL3GrInfo;
  sr_idx: Integer;
  sf: TScfsi;
begin
  nch := Header.Channels;

  sr_idx := HDR_GET_MY_SAMPLE_RATE(Header.hdr);
  if sr_idx <> 0 then
    Dec(sr_idx);

  for ch := 0 to nch - 1 do
  begin
    gi := @SideInfo.Granules[GranIdx][ch];
    gr := @gr_info[ch];

    gr^.part_23_length := gi^.Part2_3_Length;
    gr^.big_values := gi^.BigValues;
    gr^.global_gain := gi^.GlobalGain;
    gr^.scalefac_compress := gi^.ScalefacCompress;
    gr^.block_type := gi^.BlockType;
    gr^.mixed_block_flag := Ord(gi^.MixedBlockFlag);
    gr^.table_select[0] := gi^.TableSelect[0];
    gr^.table_select[1] := gi^.TableSelect[1];
    gr^.table_select[2] := gi^.TableSelect[2];
    gr^.subblock_gain[0] := gi^.SubblockGain[0];
    gr^.subblock_gain[1] := gi^.SubblockGain[1];
    gr^.subblock_gain[2] := gi^.SubblockGain[2];
    gr^.preflag := Ord(gi^.Preflag);
    gr^.scalefac_scale := gi^.ScalefacScale;
    gr^.count1_table := gi^.Count1TableSelect;
    gr^.region_count[0] := gi^.Region0Count;
    gr^.region_count[1] := gi^.Region1Count;
    gr^.region_count[2] := 255;

    // scfsi from SideInfo (only meaningful for granule 1)
    sf := SideInfo.Scfsi[ch];
    gr^.scfsi := 0;
    if sf[0] then
      gr^.scfsi := gr^.scfsi or 8;
    if sf[1] then
      gr^.scfsi := gr^.scfsi or 4;
    if sf[2] then
      gr^.scfsi := gr^.scfsi or 2;
    if sf[3] then
      gr^.scfsi := gr^.scfsi or 1;
    if (GranIdx = 0) or (gi^.BlockType = SHORT_BLOCK_TYPE) then
      gr^.scfsi := 0;

    // sfbtab and sfb counts
    if gi^.WindowSwitchingFlag and (gi^.BlockType = SHORT_BLOCK_TYPE) then
    begin
      if gi^.MixedBlockFlag then
      begin
        gr^.sfbtab := @g_scf_mixed[sr_idx][0];
        if HDR_TEST_MPEG1(Header.hdr) then
          gr^.n_long_sfb := 8
        else
          gr^.n_long_sfb := 6;
        gr^.n_short_sfb := 30;
      end
      else
      begin
        gr^.sfbtab := @g_scf_short[sr_idx][0];
        gr^.n_long_sfb := 0;
        gr^.n_short_sfb := 39;
        gr^.region_count[0] := 8;  // minimp3 sets this for short blocks
      end;
    end
    else
    begin
      gr^.sfbtab := @g_scf_long[sr_idx][0];
      gr^.n_long_sfb := 22;
      gr^.n_short_sfb := 0;
    end;
  end;
end;

constructor TMP3Layer3Decoder.Create;
begin
  inherited Create;
  FillChar(FDec, SizeOf(FDec), 0);
end;

procedure TMP3Layer3Decoder.DecodeFrame(const Header: TMP3FrameHeader; const SideInfo: TMP3SideInfo; const MainDataBuf: TBytes; MainDataBegin: Integer; out PCMLeft, PCMRight: TArray<Single>);
var
  nch, igr, i: Integer;
  bs: TBsT;
  gr_info: array[0..1] of TL3GrInfo;
  grbuf_all: array[0..1151] of Single;  // contiguous: [0..575]=left, [576..1151]=right
  grbuf: array[0..1] of PSingle;
  scf0: array[0..39] of Single;
  scf1: array[0..39] of Single;
  scf_ptrs: array[0..1] of PSingle;
  ist0: array[0..38] of Byte;
  ist1: array[0..38] of Byte;
  ist_ptrs: array[0..1] of PByte;
  pcm16: array[0..1151] of SmallInt;     // 576 samples x 2 channels interleaved
begin
  nch := Header.Channels;

  var nGranules: Integer;
  if HDR_TEST_MPEG1(Header.hdr) then
    nGranules := 2
  else
    nGranules := 1;

  SetLength(PCMLeft, nGranules * 576);
  SetLength(PCMRight, nGranules * 576);

  // Store raw header for minimp3 macros
  FDec.header[0] := Header.hdr[0];
  FDec.header[1] := Header.hdr[1];
  FDec.header[2] := Header.hdr[2];
  FDec.header[3] := Header.hdr[3];

  // Init bitstream: MainDataBuf is already the assembled reservoir+current data
  // MainDataBegin is always 0 here (caller prepends reservoir)
  if Length(MainDataBuf) = 0 then
    Exit;
  bs_init(bs, @MainDataBuf[0], Length(MainDataBuf));

  grbuf[0] := @grbuf_all[0];
  grbuf[1] := @grbuf_all[576];
  scf_ptrs[0] := @scf0[0];
  scf_ptrs[1] := @scf1[0];
  ist_ptrs[0] := @ist0[0];
  ist_ptrs[1] := @ist1[0];
  for igr := 0 to nGranules - 1 do
  begin
    // Zero granule buffers
    FillChar(grbuf_all, SizeOf(grbuf_all), 0);
    FillChar(scf0, SizeOf(scf0), 0);
    FillChar(scf1, SizeOf(scf1), 0);

    // Build gr_info from SideInfo
    BuildGrInfo(Header, SideInfo, igr, gr_info);

    // L3_decode
    DoL3Decode(bs, gr_info, nch, grbuf, scf_ptrs, ist_ptrs);

    // Synthesis filter bank: outputs interleaved int16 PCM
    // Note: FDec.syn must NOT be zeroed here - it's a persistent ring buffer
    FillChar(pcm16, SizeOf(pcm16), 0);
    mp3d_synth_granule(@FDec.qmf_state[0], @grbuf_all[0], 18, nch,
      @pcm16[0], @FDec.syn[0]);

    // Convert to float and de-interleave
    for i := 0 to 575 do
    begin
      if nch = 2 then
      begin
        PCMLeft[igr * 576 + i] := pcm16[i * 2] / 32768.0;
        PCMRight[igr * 576 + i] := pcm16[i * 2 + 1] / 32768.0;
      end
      else
      begin
        PCMLeft[igr * 576 + i] := pcm16[i] / 32768.0;
        PCMRight[igr * 576 + i] := PCMLeft[igr * 576 + i];
      end;
    end;
  end;
end;

procedure TMP3Layer3Decoder.SerializeState(State: TStateArchive);
begin
  State.Field(FDec, SizeOf(FDec));
  if State.Loading then
  begin
    for var ch := 0 to 1 do
      for var i := 0 to 287 do
        if IsNan(FDec.mdct_overlap[ch, i]) or IsInfinite(FDec.mdct_overlap[ch, i]) then
          raise EReadError.Create('Invalid MP3 overlap state');
    for var i := 0 to High(FDec.syn) do
      if IsNan(FDec.syn[i]) or IsInfinite(FDec.syn[i]) then
        raise EReadError.Create('Invalid MP3 working synthesis state');
    for var i := 0 to High(FDec.qmf_state) do
      if IsNan(FDec.qmf_state[i]) or IsInfinite(FDec.qmf_state[i]) then
        raise EReadError.Create('Invalid MP3 synthesis state');
  end;
end;

end.

