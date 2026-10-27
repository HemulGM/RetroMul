unit Audio.MP3.ScaleFactors;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, Audio.MP3.Types;

// L3_ldexp_q2: compute y * 2^(exp_q2/4) matching minimp3 exactly
function L3_ldexp_q2(y: Single; exp_q2: Integer): Single;

// L3_decode_scalefactors: fills scf[] with dequantized scale factors
procedure L3_decode_scalefactors(const hdr: array of Byte; ist_pos: PByte; var bs: TBsT; const gr: TL3GrInfo; scf: PSingle; ch: Integer);

implementation

const
  g_expfrac: array[0..3] of Single = (
    9.31322575e-10, 7.83145814e-10, 6.58544508e-10, 5.53767716e-10
  );

function L3_ldexp_q2(y: Single; exp_q2: Integer): Single;
var
  e: Integer;
  tmp: Single;
begin
  Result := y;
  while exp_q2 > 0 do
  begin
    if exp_q2 > 30 * 4 then
      e := 30 * 4
    else
      e := exp_q2;
    tmp := g_expfrac[e and 3] * Single(1 shl 30 shr (e shr 2));
    Result := Result * tmp;
    Dec(exp_q2, e);
  end;
end;

// Inner read function
procedure L3_read_scalefactors(scf: PByte; ist_pos: PByte; const scf_size: array of Byte; scf_count_ptr: PByte;  // pointer to scf_count array
  var bitbuf: TBsT; scfsi: Integer);
var
  i, k, cnt, bits, s, max_scf: Integer;
begin
  i := 0;
  while (i < 4) and (scf_count_ptr[i] <> 0) do
  begin
    cnt := scf_count_ptr[i];
    if (scfsi and 8) <> 0 then
    begin
      // Copy from ist_pos (shared from previous granule)
      Move(ist_pos^, scf^, cnt);
    end
    else
    begin
      bits := scf_size[i];
      if bits = 0 then
      begin
        FillChar(scf^, cnt, 0);
        FillChar(ist_pos^, cnt, 0);
      end
      else
      begin
        if scfsi < 0 then
          max_scf := (1 shl bits) - 1
        else
          max_scf := -1;
        for k := 0 to cnt - 1 do
        begin
          s := get_bits(bitbuf, bits);
          if s = max_scf then
            PByteArray(ist_pos)[k] := 255  // -1 cast to byte
          else
            PByteArray(ist_pos)[k] := Byte(s);
          PByteArray(scf)[k] := Byte(s);
        end;
      end;
    end;
    Inc(ist_pos, cnt);
    Inc(scf, cnt);
    scfsi := scfsi shl 1;
    Inc(i);
  end;
  // Trailing zeros (minimp3: scf[0]=scf[1]=scf[2]=0)
  PByteArray(scf)[0] := 0;
  PByteArray(scf)[1] := 0;
  PByteArray(scf)[2] := 0;
end;

procedure L3_decode_scalefactors(const hdr: array of Byte; ist_pos: PByte; var bs: TBsT; const gr: TL3GrInfo; scf: PSingle; ch: Integer);
const
  g_scf_partitions: array[0..2, 0..27] of Byte = (
    (6, 5, 5, 5, 6, 5, 5, 5, 6, 5, 7, 3, 11, 10, 0, 0, 7, 7, 7, 0, 6, 6, 6, 3, 8, 8, 5, 0),
    (8, 9, 6, 12, 6, 9, 9, 9, 6, 9, 12, 6, 15, 18, 0, 0, 6, 15, 12, 0, 6, 12, 9, 6, 6, 18, 9, 0),
    (9, 9, 6, 12, 9, 9, 9, 9, 9, 9, 12, 6, 18, 18, 0, 0, 12, 12, 12, 0, 12, 9, 9, 6, 15, 12, 9, 0)
  );
  g_scfc_decode: array[0..15] of Byte = (
    0, 1, 2, 3, 12, 5, 6, 7, 9, 10, 11, 13, 14, 15, 18, 19
  );
  g_mod: array[0..23] of Byte = (
    5, 5, 4, 4, 5, 5, 4, 1, 4, 3, 1, 1, 5, 6, 6, 1, 4, 4, 4, 1, 4, 3, 1, 1
  );
  g_preamp: array[0..9] of Byte = (1, 1, 1, 1, 2, 2, 3, 3, 3, 2);
var
  scf_partition: PByte;
  scf_size: array[0..3] of Byte;
  iscf: array[0..42] of Byte;
  i, scf_shift, gain_exp: Integer;
  scfsi: Integer;
  gain: Single;
  part, k, modprod, sfc, ist: Integer;
  part_idx: Integer;
  sh: Integer;
  n_total: Integer;
begin
  // Select partition table
  // minimp3: g_scf_partitions[!!n_short_sfb + !n_long_sfb]
  if gr.n_short_sfb <> 0 then
  begin
    if gr.n_long_sfb = 0 then
      part_idx := 2
    else
      part_idx := 1;
  end
  else
    part_idx := 0;

  scf_partition := @g_scf_partitions[part_idx][0];
  scf_shift := Integer(gr.scalefac_scale) + 1;
  scfsi := Integer(gr.scfsi);

  FillChar(iscf, SizeOf(iscf), 0);

  if HDR_TEST_MPEG1(hdr) then
  begin
    // MPEG1: decode scalefac_compress -> (slen1, slen2) via g_scfc_decode
    part := g_scfc_decode[gr.scalefac_compress and 15];
    scf_size[0] := part shr 2;
    scf_size[1] := part shr 2;
    scf_size[2] := part and 3;
    scf_size[3] := part and 3;
    L3_read_scalefactors(@iscf[0], ist_pos, scf_size, scf_partition, bs, scfsi);
  end
  else
  begin
    // MPEG2
    if HDR_TEST_I_STEREO(hdr) and (ch <> 0) then
      ist := 1
    else
      ist := 0;
    sfc := Integer(gr.scalefac_compress) shr ist;
    k := ist * 3 * 4;
    // Find correct row in g_mod
    while True do
    begin
      modprod := 1;
      for i := 3 downto 0 do
      begin
        scf_size[i] := Byte((sfc div modprod) mod Integer(g_mod[k + i]));
        modprod := modprod * Integer(g_mod[k + i]);
      end;
      if sfc < modprod then
        Break;
      Dec(sfc, modprod);
      Inc(k, 4);
    end;
    // C for-loop advances past the selected row before choosing the partition.
    Inc(scf_partition, k + 4);
    scfsi := -16;
    L3_read_scalefactors(@iscf[0], ist_pos, scf_size, scf_partition, bs, scfsi);
  end;

  // Apply subblock gains (short blocks) or preemphasis (long blocks)
  if gr.n_short_sfb <> 0 then
  begin
    sh := 3 - scf_shift;
    i := 0;
    while i < Integer(gr.n_short_sfb) do
    begin
      iscf[Integer(gr.n_long_sfb) + i + 0] :=
        iscf[Integer(gr.n_long_sfb) + i + 0] + Integer(gr.subblock_gain[0]) shl sh;
      iscf[Integer(gr.n_long_sfb) + i + 1] :=
        iscf[Integer(gr.n_long_sfb) + i + 1] + Integer(gr.subblock_gain[1]) shl sh;
      iscf[Integer(gr.n_long_sfb) + i + 2] :=
        iscf[Integer(gr.n_long_sfb) + i + 2] + Integer(gr.subblock_gain[2]) shl sh;
      Inc(i, 3);
    end;
  end
  else if gr.preflag <> 0 then
  begin
    for i := 0 to 9 do
      iscf[11 + i] := iscf[11 + i] + Integer(g_preamp[i]);
  end;

  // Compute global gain
  // gain_exp = global_gain + BITS_DEQUANTIZER_OUT*4 - 210 - (MS_STEREO ? 2 : 0)
  gain_exp := Integer(gr.global_gain) + BITS_DEQUANTIZER_OUT * 4 - 210;
  if HDR_IS_MS_STEREO(hdr) then
    Dec(gain_exp, 2);

  // gain = L3_ldexp_q2(1 << (MAX_SCFI/4), MAX_SCFI - gain_exp)
  gain := L3_ldexp_q2(Single(1 shl (MAX_SCFI div 4)), MAX_SCFI - gain_exp);

  // Fill scf[] with per-band scale factors
  n_total := Integer(gr.n_long_sfb) + Integer(gr.n_short_sfb);
  for i := 0 to n_total - 1 do
  begin
    PSingleArray(scf)[i] := L3_ldexp_q2(gain, Integer(iscf[i]) shl scf_shift);
  end;
end;

end.

