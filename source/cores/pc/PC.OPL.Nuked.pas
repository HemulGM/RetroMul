unit PC.OPL.Nuked;

interface

uses
  System.SysUtils;

type
  POplChip = ^TOplChip;

  POplChannel = ^TOplChannel;

  POplSlot = ^TOplSlot;

  POplWriteBuffer = ^TOplWriteBuffer;

  PInt16 = ^SmallInt;

  PPInt16 = ^PInt16;

  TOplSlot = record
    channel: POplChannel;
    chip: POplChip;
    &out: SmallInt;
    fbmod: SmallInt;
    &mod: PInt16;
    prout: SmallInt;
    eg_rout: Word;
    eg_out: Word;
    eg_inc: Byte;
    eg_gen: Byte;
    eg_rate: Byte;
    eg_ksl: Byte;
    trem: PByte;
    reg_vib: Byte;
    reg_type: Byte;
    reg_ksr: Byte;
    reg_mult: Byte;
    reg_ksl: Byte;
    reg_tl: Byte;
    reg_ar: Byte;
    reg_dr: Byte;
    reg_sl: Byte;
    reg_rr: Byte;
    reg_wf: Byte;
    key: Byte;
    pg_reset: Cardinal;
    pg_phase: Cardinal;
    pg_phase_out: Word;
    slot_num: Byte;
  end;

  TOplChannel = record
    slotz: array[0..1] of POplSlot;
    pair: POplChannel;
    chip: POplChip;
    &out: array[0..3] of PInt16;
    chtype: Byte;
    f_num: Word;
    f_num_reg: Word;
    block: Byte;
    block_reg: Byte;
    fb: Byte;
    con: Byte;
    alg: Byte;
    ksv: Byte;
    cha: Word;
    chb: Word;
    chc: Word;
    chd: Word;
    ch_num: Byte;
  end;

  TOplWriteBuffer = record
    time: UInt64;
    reg: Word;
    data: Byte;
  end;

  TOplChip = record
    channel: array[0..17] of TOplChannel;
    slot: array[0..35] of TOplSlot;
    timer: Word;
    eg_timer: UInt64;
    eg_timerrem: Byte;
    eg_state: Byte;
    eg_add: Byte;
    eg_timer_lo: Byte;
    newm: Byte;
    nts: Byte;
    rhy: Byte;
    vibpos: Byte;
    vibshift: Byte;
    tremolo: Byte;
    tremolopos: Byte;
    tremoloshift: Byte;
    noise: Cardinal;
    zeromod: SmallInt;
    mixbuff: array[0..3] of Integer;
    rm_hh_bit2: Byte;
    rm_hh_bit3: Byte;
    rm_hh_bit7: Byte;
    rm_hh_bit8: Byte;
    rm_tc_bit3: Byte;
    rm_tc_bit5: Byte;
    rateratio: Integer;
    samplecnt: Integer;
    oldsamples: array[0..3] of SmallInt;
    samples: array[0..3] of SmallInt;
    writebuf_samplecnt: UInt64;
    writebuf_cur: Cardinal;
    writebuf_last: Cardinal;
    writebuf_lasttime: UInt64;
    writebuf: array[0..1023] of TOplWriteBuffer;
  end;

procedure OPL3_Generate4Ch(chip: POplChip; var buf4: array of SmallInt);

procedure OPL3_Generate(chip: POplChip; var buf: array of SmallInt);

procedure OPL3_Reset(chip: POplChip; samplerate: Cardinal);

procedure OPL3_WriteReg(chip: POplChip; reg: Word; v: Byte);

procedure OPL3_WriteRegBuffered(chip: POplChip; reg: Word; v: Byte);

implementation

function Wrap8(Value: Int64): Byte; inline;
begin
  Result := Byte(Value and $FF);
end;

function Signed8(Value: Int64): ShortInt; inline;
begin
  Result := ShortInt((Value and $7F) - (Value and $80));
end;

function Wrap16(Value: Int64): Word; inline;
begin
  Result := Word(Value and $FFFF);
end;

function Signed16(Value: Int64): SmallInt; inline;
begin
  Result := SmallInt((Value and $7FFF) - (Value and $8000));
end;

function Wrap32(Value: Int64): Cardinal; inline;
begin
  Result := Cardinal(Value and $FFFFFFFF);
end;

function SAR(Value: Integer; Bits: Integer): Integer; inline;
begin
  if Bits = 0 then
    Exit(Value);
  Result := Integer(Cardinal(Value) shr Bits);
  if Value < 0 then
    Result := Result or Integer($FFFFFFFF shl (32 - Bits));
end;

function Choose(Condition: Boolean; A, B: Integer): Integer; inline;
begin
  if Condition then
    Result := A
  else
    Result := B;
end;

type
  envelope_sinfunc = function(phase, envelope: Word): SmallInt;

function OPL3_EnvelopeCalcExp(level: Cardinal): SmallInt; forward;

function OPL3_EnvelopeCalcSin0(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin1(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin2(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin3(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin4(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin5(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin6(phase: Word; envelope: Word): SmallInt; forward;

function OPL3_EnvelopeCalcSin7(phase: Word; envelope: Word): SmallInt; forward;

procedure OPL3_EnvelopeUpdateKSL(slot: POplSlot); forward;

procedure OPL3_EnvelopeCalc(slot: POplSlot); forward;

procedure OPL3_EnvelopeKeyOn(slot: POplSlot; &type: Byte); forward;

procedure OPL3_EnvelopeKeyOff(slot: POplSlot; &type: Byte); forward;

procedure OPL3_PhaseGenerate(slot: POplSlot); forward;

procedure OPL3_SlotWrite20(slot: POplSlot; data: Byte); forward;

procedure OPL3_SlotWrite40(slot: POplSlot; data: Byte); forward;

procedure OPL3_SlotWrite60(slot: POplSlot; data: Byte); forward;

procedure OPL3_SlotWrite80(slot: POplSlot; data: Byte); forward;

procedure OPL3_SlotWriteE0(slot: POplSlot; data: Byte); forward;

procedure OPL3_SlotGenerate(slot: POplSlot); forward;

procedure OPL3_SlotCalcFB(slot: POplSlot); forward;

procedure OPL3_ChannelUpdateRhythm(chip: POplChip; data: Byte); forward;

procedure OPL3_ChannelUpdateFrequency(channel: POplChannel); forward;

procedure OPL3_ChannelRestoreFrequency(channel: POplChannel); forward;

procedure OPL3_ChannelSync4Op(channel: POplChannel); forward;

procedure OPL3_ChannelWriteA0(channel: POplChannel; data: Byte); forward;

procedure OPL3_ChannelWriteB0(channel: POplChannel; data: Byte); forward;

procedure OPL3_ChannelSetupAlg(channel: POplChannel); forward;

procedure OPL3_ChannelUpdateAlg(channel: POplChannel); forward;

procedure OPL3_ChannelWriteC0(channel: POplChannel; data: Byte); forward;

procedure OPL3_ChannelKeyOn(channel: POplChannel); forward;

procedure OPL3_ChannelKeyOff(channel: POplChannel); forward;

procedure OPL3_ChannelSet4Op(chip: POplChip; data: Byte); forward;

function OPL3_ClipSample(sample: Integer): SmallInt; forward;

procedure OPL3_ProcessSlot(slot: POplSlot); forward;

const
  ch_2op = 0;
  ch_4op = 1;
  ch_4op2 = 2;
  ch_drum = 3;
  egk_norm = 1;
  egk_drum = 2;
  envelope_gen_num_attack = 0;
  envelope_gen_num_decay = 1;
  envelope_gen_num_sustain = 2;
  envelope_gen_num_release = 3;
  logsinrom: array[0..255] of Word = (
    $859, $6c3, $607, $58b, $52e, $4e4, $4a6, $471,
    $443, $41a, $3f5, $3d3, $3b5, $398, $37e, $365,
    $34e, $339, $324, $311, $2ff, $2ed, $2dc, $2cd,
    $2bd, $2af, $2a0, $293, $286, $279, $26d, $261,
    $256, $24b, $240, $236, $22c, $222, $218, $20f,
    $206, $1fd, $1f5, $1ec, $1e4, $1dc, $1d4, $1cd,
    $1c5, $1be, $1b7, $1b0, $1a9, $1a2, $19b, $195,
    $18f, $188, $182, $17c, $177, $171, $16b, $166,
    $160, $15b, $155, $150, $14b, $146, $141, $13c,
    $137, $133, $12e, $129, $125, $121, $11c, $118,
    $114, $10f, $10b, $107, $103, $0ff, $0fb, $0f8,
    $0f4, $0f0, $0ec, $0e9, $0e5, $0e2, $0de, $0db,
    $0d7, $0d4, $0d1, $0cd, $0ca, $0c7, $0c4, $0c1,
    $0be, $0bb, $0b8, $0b5, $0b2, $0af, $0ac, $0a9,
    $0a7, $0a4, $0a1, $09f, $09c, $099, $097, $094,
    $092, $08f, $08d, $08a, $088, $086, $083, $081,
    $07f, $07d, $07a, $078, $076, $074, $072, $070,
    $06e, $06c, $06a, $068, $066, $064, $062, $060,
    $05e, $05c, $05b, $059, $057, $055, $053, $052,
    $050, $04e, $04d, $04b, $04a, $048, $046, $045,
    $043, $042, $040, $03f, $03e, $03c, $03b, $039,
    $038, $037, $035, $034, $033, $031, $030, $02f,
    $02e, $02d, $02b, $02a, $029, $028, $027, $026,
    $025, $024, $023, $022, $021, $020, $01f, $01e,
    $01d, $01c, $01b, $01a, $019, $018, $017, $017,
    $016, $015, $014, $014, $013, $012, $011, $011,
    $010, $00f, $00f, $00e, $00d, $00d, $00c, $00c,
    $00b, $00a, $00a, $009, $009, $008, $008, $007,
    $007, $007, $006, $006, $005, $005, $005, $004,
    $004, $004, $003, $003, $003, $002, $002, $002,
    $002, $001, $001, $001, $001, $001, $001, $001,
    $000, $000, $000, $000, $000, $000, $000, $000);
  exprom: array[0..255] of Word = ($7fa,
    $7f5,
    $7ef, $7ea, $7e4, $7df, $7da, $7d4, $7cf, $7c9,
    $7c4, $7bf, $7b9, $7b4, $7ae, $7a9, $7a4, $79f,
    $799, $794, $78f, $78a, $784, $77f, $77a, $775,
    $770, $76a, $765, $760, $75b, $756, $751, $74c,
    $747, $742, $73d, $738, $733, $72e, $729, $724,
    $71f, $71a, $715, $710, $70b, $706, $702, $6fd,
    $6f8, $6f3, $6ee, $6e9, $6e5, $6e0, $6db, $6d6,
    $6d2, $6cd, $6c8, $6c4, $6bf, $6ba, $6b5, $6b1,
    $6ac, $6a8, $6a3, $69e, $69a, $695, $691, $68c,
    $688, $683, $67f, $67a, $676, $671, $66d, $668,
    $664, $65f, $65b, $657, $652, $64e, $649, $645,
    $641, $63c, $638, $634, $630, $62b, $627, $623,
    $61e, $61a, $616, $612, $60e, $609, $605, $601,
    $5fd, $5f9, $5f5, $5f0, $5ec, $5e8, $5e4, $5e0,
    $5dc, $5d8, $5d4, $5d0, $5cc, $5c8, $5c4, $5c0,
    $5bc, $5b8, $5b4, $5b0, $5ac, $5a8, $5a4, $5a0,
    $59c, $599, $595, $591, $58d, $589, $585, $581,
    $57e, $57a, $576, $572, $56f, $56b, $567, $563,
    $560, $55c, $558, $554, $551, $54d, $549, $546,
    $542, $53e, $53b, $537, $534, $530, $52c, $529,
    $525, $522, $51e, $51b, $517, $514, $510, $50c,
    $509, $506, $502, $4ff, $4fb, $4f8, $4f4, $4f1,
    $4ed, $4ea, $4e7, $4e3, $4e0, $4dc, $4d9, $4d6,
    $4d2, $4cf, $4cc, $4c8, $4c5, $4c2, $4be, $4bb,
    $4b8, $4b5, $4b1, $4ae, $4ab, $4a8, $4a4, $4a1,
    $49e, $49b, $498, $494, $491, $48e, $48b, $488,
    $485, $482, $47e, $47b, $478, $475, $472, $46f,
    $46c, $469, $466, $463, $460, $45d, $45a, $457,
    $454, $451, $44e, $44b, $448, $445, $442, $43f,
    $43c, $439, $436, $433, $430, $42d, $42a, $428,
    $425, $422, $41f, $41c, $419, $416, $414, $411,
    $40e, $40b, $408, $406, $403, $400);
  mt: array[0..15] of Byte = (1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30);
  kslrom: array[0..15] of Byte = (0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64);
  kslshift: array[0..3] of Byte = (8, 1, 2, 0);
  eg_incstep: array[0..3] of array[0..3] of Byte = (
    (0, 0, 0, 0),
    (1, 0, 0, 0),
    (1, 0, 1, 0),
    (1, 1, 1, 0));
  ad_slot: array[0..31] of ShortInt = (
    0, 1, 2, 3, 4, 5, (-Int64(1)), (-Int64(1)),
    6, 7, 8, 9, 10, 11, (-Int64(1)), (-Int64(1)),
    12, 13, 14, 15, 16, 17, (-Int64(1)), (-Int64(1)),
    (-Int64(1)), (-Int64(1)), (-Int64(1)), (-Int64(1)),
    (-Int64(1)), (-Int64(1)), (-Int64(1)), (-Int64(1)));
  ch_slot: array[0..17] of Byte = (0, 1, 2, 6, 7, 8, 12, 13, 14, 18, 19, 20, 24, 25, 26, 30, 31, 32);
  envelope_sin: array[0..7] of envelope_sinfunc = (
    OPL3_EnvelopeCalcSin0,
    OPL3_EnvelopeCalcSin1,
    OPL3_EnvelopeCalcSin2,
    OPL3_EnvelopeCalcSin3,
    OPL3_EnvelopeCalcSin4,
    OPL3_EnvelopeCalcSin5,
    OPL3_EnvelopeCalcSin6,
    OPL3_EnvelopeCalcSin7);

function OPL3_EnvelopeCalcExp(level: Cardinal): SmallInt;
begin
  if (level > $1fff) then
  begin
    level := Wrap32($1fff);
  end;
  Exit(Signed16(SAR((exprom[(level and $ff)] shl 1), (level shr 8))));
end;

function OPL3_EnvelopeCalcSin0(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
  neg: Word;
begin
  neg := Wrap16(0);
  phase := Wrap16((phase and $3ff));
  if ((phase and $200) <> 0) then
  begin
    neg := Wrap16($ffff);
  end;
  if ((phase and $100) <> 0) then
  begin
    &out := Wrap16(logsinrom[(Int64((phase and $ff)) xor Int64($ff))]);
  end
  else
  begin
    &out := Wrap16(logsinrom[(phase and $ff)]);
  end;
  Exit(Signed16((Int64(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))) xor Int64(neg))));
end;

function OPL3_EnvelopeCalcSin1(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
begin
  phase := Wrap16((phase and $3ff));
  if ((phase and $200) <> 0) then
  begin
    &out := Wrap16($1000);
  end
  else
  begin
    if ((phase and $100) <> 0) then
    begin
      &out := Wrap16(logsinrom[(Int64((phase and $ff)) xor Int64($ff))]);
    end
    else
    begin
      &out := Wrap16(logsinrom[(phase and $ff)]);
    end;
  end;
  Exit(Signed16(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))));
end;

function OPL3_EnvelopeCalcSin2(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
begin
  phase := Wrap16((phase and $3ff));
  if ((phase and $100) <> 0) then
  begin
    &out := Wrap16(logsinrom[(Int64((phase and $ff)) xor Int64($ff))]);
  end
  else
  begin
    &out := Wrap16(logsinrom[(phase and $ff)]);
  end;
  Exit(Signed16(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))));
end;

function OPL3_EnvelopeCalcSin3(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
begin
  phase := Wrap16((phase and $3ff));
  if ((phase and $100) <> 0) then
  begin
    &out := Wrap16($1000);
  end
  else
  begin
    &out := Wrap16(logsinrom[(phase and $ff)]);
  end;
  Exit(Signed16(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))));
end;

function OPL3_EnvelopeCalcSin4(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
  neg: Word;
begin
  neg := Wrap16(0);
  phase := Wrap16((phase and $3ff));
  if ((phase and $300) = $100) then
  begin
    neg := Wrap16($ffff);
  end;
  if ((phase and $200) <> 0) then
  begin
    &out := Wrap16($1000);
  end
  else
  begin
    if ((phase and $80) <> 0) then
    begin
      &out := Wrap16(logsinrom[(((Int64(phase) xor Int64($ff)) shl 1) and $ff)]);
    end
    else
    begin
      &out := Wrap16(logsinrom[((phase shl 1) and $ff)]);
    end;
  end;
  Exit(Signed16((Int64(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))) xor Int64(neg))));
end;

function OPL3_EnvelopeCalcSin5(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
begin
  phase := Wrap16((phase and $3ff));
  if ((phase and $200) <> 0) then
  begin
    &out := Wrap16($1000);
  end
  else
  begin
    if ((phase and $80) <> 0) then
    begin
      &out := Wrap16(logsinrom[(((Int64(phase) xor Int64($ff)) shl 1) and $ff)]);
    end
    else
    begin
      &out := Wrap16(logsinrom[((phase shl 1) and $ff)]);
    end;
  end;
  Exit(Signed16(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))));
end;

function OPL3_EnvelopeCalcSin6(phase: Word; envelope: Word): SmallInt;
var
  neg: Word;
begin
  neg := Wrap16(0);
  phase := Wrap16((phase and $3ff));
  if ((phase and $200) <> 0) then
  begin
    neg := Wrap16($ffff);
  end;
  Exit(Signed16((Int64(OPL3_EnvelopeCalcExp(Wrap32((envelope shl 3)))) xor Int64(neg))));
end;

function OPL3_EnvelopeCalcSin7(phase: Word; envelope: Word): SmallInt;
var
  &out: Word;
  neg: Word;
begin
  neg := Wrap16(0);
  phase := Wrap16((phase and $3ff));
  if ((phase and $200) <> 0) then
  begin
    neg := Wrap16($ffff);
    phase := Wrap16((Int64((phase and $1ff)) xor Int64($1ff)));
  end;
  &out := Wrap16((phase shl 3));
  Exit(Signed16((Int64(OPL3_EnvelopeCalcExp(Wrap32((Int64(&out) + Int64((envelope shl 3)))))) xor Int64(neg))));
end;

procedure OPL3_EnvelopeUpdateKSL(slot: POplSlot);
var
  ksl: SmallInt;
begin
  ksl := Signed16((Int64((kslrom[SAR(slot^.channel^.f_num, 6)] shl 2)) - Int64(((Int64($08) - Int64(slot^.channel^.block)) shl 5))));
  if (ksl < 0) then
  begin
    ksl := Signed16(0);
  end;
  slot^.eg_ksl := Wrap8(Wrap8(ksl));
end;

procedure OPL3_EnvelopeCalc(slot: POplSlot);
var
  nonzero: Byte;
  rate: Byte;
  rate_hi: Byte;
  rate_lo: Byte;
  reg_rate: Byte;
  ks: Byte;
  eg_shift: Byte;
  shift: Byte;
  eg_rout: Word;
  eg_inc: SmallInt;
  eg_off: Byte;
  reset_flag: Byte;
begin
  reg_rate := Wrap8(0);
  reset_flag := Wrap8(0);
  slot^.eg_out := Wrap16((Int64((Int64((Int64(slot^.eg_rout) + Int64((slot^.reg_tl shl 2)))) + Int64(SAR(slot^.eg_ksl, kslshift[slot^.reg_ksl])))) + Int64(slot^.trem^)));
  if ((slot^.key <> 0) and (slot^.eg_gen = envelope_gen_num_release)) then
  begin
    reset_flag := Wrap8(1);
    reg_rate := Wrap8(slot^.reg_ar);
  end
  else
  begin
    case slot^.eg_gen of
      envelope_gen_num_attack:
        begin
          reg_rate := Wrap8(slot^.reg_ar);
        end;
      envelope_gen_num_decay:
        begin
          reg_rate := Wrap8(slot^.reg_dr);
        end;
      envelope_gen_num_sustain:
        begin
          if (not (slot^.reg_type <> 0)) then
          begin
            reg_rate := Wrap8(slot^.reg_rr);
          end;
        end;
      envelope_gen_num_release:
        begin
          reg_rate := Wrap8(slot^.reg_rr);
        end;
    end;
  end;
  slot^.pg_reset := Wrap32(reset_flag);
  ks := Wrap8(SAR(slot^.channel^.ksv, ((Int64(slot^.reg_ksr) xor Int64(1)) shl 1)));
  nonzero := Wrap8(Ord((reg_rate <> 0)));
  rate := Wrap8((Int64(ks) + Int64((reg_rate shl 2))));
  rate_hi := Wrap8(SAR(rate, 2));
  rate_lo := Wrap8((rate and $03));
  if ((rate_hi and $10) <> 0) then
  begin
    rate_hi := Wrap8($0f);
  end;
  eg_shift := Wrap8((Int64(rate_hi) + Int64(slot^.chip^.eg_add)));
  shift := Wrap8(0);
  if (nonzero <> 0) then
  begin
    if (rate_hi < 12) then
    begin
      if (slot^.chip^.eg_state <> 0) then
      begin
        case eg_shift of
          12:
            begin
              shift := Wrap8(1);
            end;
          13:
            begin
              shift := Wrap8((SAR(rate_lo, 1) and $01));
            end;
          14:
            begin
              shift := Wrap8((rate_lo and $01));
            end;
        else
          begin
          end;
        end;
      end;
    end
    else
    begin
      shift := Wrap8((Int64((rate_hi and $03)) + Int64(eg_incstep[rate_lo][slot^.chip^.eg_timer_lo])));
      if ((shift and $04) <> 0) then
      begin
        shift := Wrap8($03);
      end;
      if (not (shift <> 0)) then
      begin
        shift := Wrap8(slot^.chip^.eg_state);
      end;
    end;
  end;
  eg_rout := Wrap16(slot^.eg_rout);
  eg_inc := Signed16(0);
  eg_off := Wrap8(0);
  if ((reset_flag <> 0) and (rate_hi = $0f)) then
  begin
    eg_rout := Wrap16($00);
  end;
  if ((slot^.eg_rout and $1f8) = $1f8) then
  begin
    eg_off := Wrap8(1);
  end;
  if (((slot^.eg_gen <> envelope_gen_num_attack) and (not (reset_flag <> 0))) and (eg_off <> 0)) then
  begin
    eg_rout := Wrap16($1ff);
  end;
  case slot^.eg_gen of
    envelope_gen_num_attack:
      begin
        if (not (slot^.eg_rout <> 0)) then
        begin
          slot^.eg_gen := Wrap8(envelope_gen_num_decay);
        end
        else
        begin
          if (((slot^.key <> 0) and (shift > 0)) and (rate_hi <> $0f)) then
          begin
            eg_inc := Signed16(SAR((not Integer(slot^.eg_rout)), (Int64(4) - Int64(shift))));
          end;
        end;
      end;
    envelope_gen_num_decay:
      begin
        if (SAR(slot^.eg_rout, 4) = slot^.reg_sl) then
        begin
          slot^.eg_gen := Wrap8(envelope_gen_num_sustain);
        end
        else
        begin
          if (((not (eg_off <> 0)) and (not (reset_flag <> 0))) and (shift > 0)) then
          begin
            eg_inc := Signed16((1 shl (Int64(shift) - Int64(1))));
          end;
        end;
      end;
    envelope_gen_num_sustain, envelope_gen_num_release:
      begin
        if (((not (eg_off <> 0)) and (not (reset_flag <> 0))) and (shift > 0)) then
        begin
          eg_inc := Signed16((1 shl (Int64(shift) - Int64(1))));
        end;
      end;
  end;
  slot^.eg_rout := Wrap16(((Int64(eg_rout) + Int64(eg_inc)) and $1ff));
  if (reset_flag <> 0) then
  begin
    slot^.eg_gen := Wrap8(envelope_gen_num_attack);
  end;
  if (not (slot^.key <> 0)) then
  begin
    slot^.eg_gen := Wrap8(envelope_gen_num_release);
  end;
end;

procedure OPL3_EnvelopeKeyOn(slot: POplSlot; &type: Byte);
begin
  slot^.key := Wrap8((slot^.key or &type));
end;

procedure OPL3_EnvelopeKeyOff(slot: POplSlot; &type: Byte);
begin
  slot^.key := Wrap8((slot^.key and (not Integer(&type))));
end;

procedure OPL3_PhaseGenerate(slot: POplSlot);
var
  chip: POplChip;
  f_num: Word;
  basefreq: Cardinal;
  rm_xor: Byte;
  n_bit: Byte;
  noise: Cardinal;
  phase: Word;
  range_value: ShortInt;
  vibpos: Byte;
begin
  chip := slot^.chip;
  f_num := Wrap16(slot^.channel^.f_num);
  if (slot^.reg_vib <> 0) then
  begin
    range_value := Signed8((SAR(f_num, 7) and 7));
    vibpos := Wrap8(slot^.chip^.vibpos);
    if (not ((vibpos and 3) <> 0)) then
    begin
      range_value := Signed8(0);
    end
    else
    begin
      if ((vibpos and 1) <> 0) then
      begin
        range_value := Signed8(SAR(range_value, 1));
      end;
    end;
    range_value := Signed8(SAR(range_value, slot^.chip^.vibshift));
    if ((vibpos and 4) <> 0) then
    begin
      range_value := Signed8((-Int64(range_value)));
    end;
    f_num := Wrap16((f_num + range_value));
  end;
  basefreq := Wrap32(SAR((f_num shl slot^.channel^.block), 1));
  phase := Wrap16(Wrap16((slot^.pg_phase shr 9)));
  if (slot^.pg_reset <> 0) then
  begin
    slot^.pg_phase := Wrap32(0);
  end;
  slot^.pg_phase := Wrap32((slot^.pg_phase + ((Int64(basefreq) * Int64(mt[slot^.reg_mult])) shr 1)));
  noise := Wrap32(chip^.noise);
  slot^.pg_phase_out := Wrap16(phase);
  if (slot^.slot_num = 13) then
  begin
    chip^.rm_hh_bit2 := Wrap8((SAR(phase, 2) and 1));
    chip^.rm_hh_bit3 := Wrap8((SAR(phase, 3) and 1));
    chip^.rm_hh_bit7 := Wrap8((SAR(phase, 7) and 1));
    chip^.rm_hh_bit8 := Wrap8((SAR(phase, 8) and 1));
  end;
  if ((slot^.slot_num = 17) and ((chip^.rhy and $20) <> 0)) then
  begin
    chip^.rm_tc_bit3 := Wrap8((SAR(phase, 3) and 1));
    chip^.rm_tc_bit5 := Wrap8((SAR(phase, 5) and 1));
  end;
  if ((chip^.rhy and $20) <> 0) then
  begin
    rm_xor := Wrap8((((Int64(chip^.rm_hh_bit2) xor Int64(chip^.rm_hh_bit7)) or (Int64(chip^.rm_hh_bit3) xor Int64(chip^.rm_tc_bit5))) or (Int64(chip^.rm_tc_bit3) xor Int64(chip^.rm_tc_bit5))));
    case slot^.slot_num of
      13:
        begin
          slot^.pg_phase_out := Wrap16((rm_xor shl 9));
          if ((Int64(rm_xor) xor Int64((noise and 1))) <> 0) then
          begin
            slot^.pg_phase_out := Wrap16((slot^.pg_phase_out or $d0));
          end
          else
          begin
            slot^.pg_phase_out := Wrap16((slot^.pg_phase_out or $34));
          end;
        end;
      16:
        begin
          slot^.pg_phase_out := Wrap16(((chip^.rm_hh_bit8 shl 9) or ((Int64(chip^.rm_hh_bit8) xor Int64((noise and 1))) shl 8)));
        end;
      17:
        begin
          slot^.pg_phase_out := Wrap16(((rm_xor shl 9) or $80));
        end;
    else
      begin
      end;
    end;
  end;
  n_bit := Wrap8(((Int64((noise shr 14)) xor Int64(noise)) and $01));
  chip^.noise := Wrap32(((noise shr 1) or (n_bit shl 22)));
end;

procedure OPL3_SlotWrite20(slot: POplSlot; data: Byte);
begin
  if ((SAR(data, 7) and $01) <> 0) then
  begin
    slot^.trem := @slot^.chip^.tremolo;
  end
  else
  begin
    slot^.trem := PByte(@slot^.chip^.zeromod);
  end;
  slot^.reg_vib := Wrap8((SAR(data, 6) and $01));
  slot^.reg_type := Wrap8((SAR(data, 5) and $01));
  slot^.reg_ksr := Wrap8((SAR(data, 4) and $01));
  slot^.reg_mult := Wrap8((data and $0f));
end;

procedure OPL3_SlotWrite40(slot: POplSlot; data: Byte);
begin
  slot^.reg_ksl := Wrap8((SAR(data, 6) and $03));
  slot^.reg_tl := Wrap8((data and $3f));
  OPL3_EnvelopeUpdateKSL(slot);
end;

procedure OPL3_SlotWrite60(slot: POplSlot; data: Byte);
begin
  slot^.reg_ar := Wrap8((SAR(data, 4) and $0f));
  slot^.reg_dr := Wrap8((data and $0f));
end;

procedure OPL3_SlotWrite80(slot: POplSlot; data: Byte);
begin
  slot^.reg_sl := Wrap8((SAR(data, 4) and $0f));
  if (slot^.reg_sl = $0f) then
  begin
    slot^.reg_sl := Wrap8($1f);
  end;
  slot^.reg_rr := Wrap8((data and $0f));
end;

procedure OPL3_SlotWriteE0(slot: POplSlot; data: Byte);
begin
  slot^.reg_wf := Wrap8((data and $07));
  if (slot^.chip^.newm = $00) then
  begin
    slot^.reg_wf := Wrap8((slot^.reg_wf and $03));
  end;
end;

procedure OPL3_SlotGenerate(slot: POplSlot);
begin
  slot^.&out := Signed16(envelope_sin[slot^.reg_wf](Wrap16((Int64(slot^.pg_phase_out) + Int64(slot^.&mod^))), Wrap16(slot^.eg_out)));
end;

procedure OPL3_SlotCalcFB(slot: POplSlot);
begin
  if (slot^.channel^.fb <> $00) then
  begin
    slot^.fbmod := Signed16(SAR((Int64(slot^.prout) + Int64(slot^.&out)), (Int64($09) - Int64(slot^.channel^.fb))));
  end
  else
  begin
    slot^.fbmod := Signed16(0);
  end;
  slot^.prout := Signed16(slot^.&out);
end;

procedure OPL3_ChannelUpdateRhythm(chip: POplChip; data: Byte);
var
  channel6: POplChannel;
  channel7: POplChannel;
  channel8: POplChannel;
  chnum: Byte;
begin
  chip^.rhy := Wrap8((data and $3f));
  if ((chip^.rhy and $20) <> 0) then
  begin
    channel6 := @chip^.channel[6];
    channel7 := @chip^.channel[7];
    channel8 := @chip^.channel[8];
    channel6^.&out[0] := @channel6^.slotz[1]^.&out;
    channel6^.&out[1] := @channel6^.slotz[1]^.&out;
    channel6^.&out[2] := @chip^.zeromod;
    channel6^.&out[3] := @chip^.zeromod;
    channel7^.&out[0] := @channel7^.slotz[0]^.&out;
    channel7^.&out[1] := @channel7^.slotz[0]^.&out;
    channel7^.&out[2] := @channel7^.slotz[1]^.&out;
    channel7^.&out[3] := @channel7^.slotz[1]^.&out;
    channel8^.&out[0] := @channel8^.slotz[0]^.&out;
    channel8^.&out[1] := @channel8^.slotz[0]^.&out;
    channel8^.&out[2] := @channel8^.slotz[1]^.&out;
    channel8^.&out[3] := @channel8^.slotz[1]^.&out;
    chnum := Wrap8(6);
    while (chnum < 9) do
    begin
      chip^.channel[chnum].chtype := Wrap8(ch_drum);
      chnum := Wrap8((chnum + 1));
    end;
    OPL3_ChannelSetupAlg(channel6);
    OPL3_ChannelSetupAlg(channel7);
    OPL3_ChannelSetupAlg(channel8);
    if ((chip^.rhy and $01) <> 0) then
    begin
      OPL3_EnvelopeKeyOn(channel7^.slotz[0], Wrap8(egk_drum));
    end
    else
    begin
      OPL3_EnvelopeKeyOff(channel7^.slotz[0], Wrap8(egk_drum));
    end;
    if ((chip^.rhy and $02) <> 0) then
    begin
      OPL3_EnvelopeKeyOn(channel8^.slotz[1], Wrap8(egk_drum));
    end
    else
    begin
      OPL3_EnvelopeKeyOff(channel8^.slotz[1], Wrap8(egk_drum));
    end;
    if ((chip^.rhy and $04) <> 0) then
    begin
      OPL3_EnvelopeKeyOn(channel8^.slotz[0], Wrap8(egk_drum));
    end
    else
    begin
      OPL3_EnvelopeKeyOff(channel8^.slotz[0], Wrap8(egk_drum));
    end;
    if ((chip^.rhy and $08) <> 0) then
    begin
      OPL3_EnvelopeKeyOn(channel7^.slotz[1], Wrap8(egk_drum));
    end
    else
    begin
      OPL3_EnvelopeKeyOff(channel7^.slotz[1], Wrap8(egk_drum));
    end;
    if ((chip^.rhy and $10) <> 0) then
    begin
      OPL3_EnvelopeKeyOn(channel6^.slotz[0], Wrap8(egk_drum));
      OPL3_EnvelopeKeyOn(channel6^.slotz[1], Wrap8(egk_drum));
    end
    else
    begin
      OPL3_EnvelopeKeyOff(channel6^.slotz[0], Wrap8(egk_drum));
      OPL3_EnvelopeKeyOff(channel6^.slotz[1], Wrap8(egk_drum));
    end;
  end
  else
  begin
    chnum := Wrap8(6);
    while (chnum < 9) do
    begin
      chip^.channel[chnum].chtype := Wrap8(ch_2op);
      OPL3_ChannelSetupAlg(@chip^.channel[chnum]);
      OPL3_EnvelopeKeyOff(chip^.channel[chnum].slotz[0], Wrap8(egk_drum));
      OPL3_EnvelopeKeyOff(chip^.channel[chnum].slotz[1], Wrap8(egk_drum));
      chnum := Wrap8((chnum + 1));
    end;
  end;
end;

procedure OPL3_ChannelUpdateFrequency(channel: POplChannel);
begin
  channel^.ksv := Wrap8(((channel^.block shl 1) or (SAR(channel^.f_num, (Int64($09) - Int64(channel^.chip^.nts))) and $01)));
  OPL3_EnvelopeUpdateKSL(channel^.slotz[0]);
  OPL3_EnvelopeUpdateKSL(channel^.slotz[1]);
end;

procedure OPL3_ChannelRestoreFrequency(channel: POplChannel);
begin
  channel^.f_num := Wrap16(channel^.f_num_reg);
  channel^.block := Wrap8(channel^.block_reg);
  OPL3_ChannelUpdateFrequency(channel);
end;

procedure OPL3_ChannelSync4Op(channel: POplChannel);
begin
  channel^.pair^.f_num := Wrap16(channel^.f_num);
  channel^.pair^.block := Wrap8(channel^.block);
  OPL3_ChannelUpdateFrequency(channel^.pair);
end;

procedure OPL3_ChannelWriteA0(channel: POplChannel; data: Byte);
begin
  channel^.f_num_reg := Wrap16(((channel^.f_num_reg and $300) or data));
  if (channel^.chtype = ch_4op2) then
  begin
    Exit;
  end;
  OPL3_ChannelRestoreFrequency(channel);
  if (channel^.chtype = ch_4op) then
  begin
    OPL3_ChannelSync4Op(channel);
  end;
end;

procedure OPL3_ChannelWriteB0(channel: POplChannel; data: Byte);
begin
  channel^.f_num_reg := Wrap16(((channel^.f_num_reg and $ff) or ((data and $03) shl 8)));
  channel^.block_reg := Wrap8((SAR(data, 2) and $07));
  if (channel^.chtype = ch_4op2) then
  begin
    Exit;
  end;
  OPL3_ChannelRestoreFrequency(channel);
  if (channel^.chtype = ch_4op) then
  begin
    OPL3_ChannelSync4Op(channel);
  end;
end;

procedure OPL3_ChannelSetupAlg(channel: POplChannel);
begin
  if (channel^.chtype = ch_drum) then
  begin
    if ((channel^.ch_num = 7) or (channel^.ch_num = 8)) then
    begin
      channel^.slotz[0]^.&mod := @channel^.chip^.zeromod;
      channel^.slotz[1]^.&mod := @channel^.chip^.zeromod;
      Exit;
    end;
    case (channel^.alg and $01) of
      $00:
        begin
          channel^.slotz[0]^.&mod := @channel^.slotz[0]^.fbmod;
          channel^.slotz[1]^.&mod := @channel^.slotz[0]^.&out;
        end;
      $01:
        begin
          channel^.slotz[0]^.&mod := @channel^.slotz[0]^.fbmod;
          channel^.slotz[1]^.&mod := @channel^.chip^.zeromod;
        end;
    end;
    Exit;
  end;
  if ((channel^.alg and $08) <> 0) then
  begin
    Exit;
  end;
  if ((channel^.alg and $04) <> 0) then
  begin
    channel^.pair^.&out[0] := @channel^.chip^.zeromod;
    channel^.pair^.&out[1] := @channel^.chip^.zeromod;
    channel^.pair^.&out[2] := @channel^.chip^.zeromod;
    channel^.pair^.&out[3] := @channel^.chip^.zeromod;
    case (channel^.alg and $03) of
      $00:
        begin
          channel^.pair^.slotz[0]^.&mod := @channel^.pair^.slotz[0]^.fbmod;
          channel^.pair^.slotz[1]^.&mod := @channel^.pair^.slotz[0]^.&out;
          channel^.slotz[0]^.&mod := @channel^.pair^.slotz[1]^.&out;
          channel^.slotz[1]^.&mod := @channel^.slotz[0]^.&out;
          channel^.&out[0] := @channel^.slotz[1]^.&out;
          channel^.&out[1] := @channel^.chip^.zeromod;
          channel^.&out[2] := @channel^.chip^.zeromod;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
      $01:
        begin
          channel^.pair^.slotz[0]^.&mod := @channel^.pair^.slotz[0]^.fbmod;
          channel^.pair^.slotz[1]^.&mod := @channel^.pair^.slotz[0]^.&out;
          channel^.slotz[0]^.&mod := @channel^.chip^.zeromod;
          channel^.slotz[1]^.&mod := @channel^.slotz[0]^.&out;
          channel^.&out[0] := @channel^.pair^.slotz[1]^.&out;
          channel^.&out[1] := @channel^.slotz[1]^.&out;
          channel^.&out[2] := @channel^.chip^.zeromod;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
      $02:
        begin
          channel^.pair^.slotz[0]^.&mod := @channel^.pair^.slotz[0]^.fbmod;
          channel^.pair^.slotz[1]^.&mod := @channel^.chip^.zeromod;
          channel^.slotz[0]^.&mod := @channel^.pair^.slotz[1]^.&out;
          channel^.slotz[1]^.&mod := @channel^.slotz[0]^.&out;
          channel^.&out[0] := @channel^.pair^.slotz[0]^.&out;
          channel^.&out[1] := @channel^.slotz[1]^.&out;
          channel^.&out[2] := @channel^.chip^.zeromod;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
      $03:
        begin
          channel^.pair^.slotz[0]^.&mod := @channel^.pair^.slotz[0]^.fbmod;
          channel^.pair^.slotz[1]^.&mod := @channel^.chip^.zeromod;
          channel^.slotz[0]^.&mod := @channel^.pair^.slotz[1]^.&out;
          channel^.slotz[1]^.&mod := @channel^.chip^.zeromod;
          channel^.&out[0] := @channel^.pair^.slotz[0]^.&out;
          channel^.&out[1] := @channel^.slotz[0]^.&out;
          channel^.&out[2] := @channel^.slotz[1]^.&out;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
    end;
  end
  else
  begin
    case (channel^.alg and $01) of
      $00:
        begin
          channel^.slotz[0]^.&mod := @channel^.slotz[0]^.fbmod;
          channel^.slotz[1]^.&mod := @channel^.slotz[0]^.&out;
          channel^.&out[0] := @channel^.slotz[1]^.&out;
          channel^.&out[1] := @channel^.chip^.zeromod;
          channel^.&out[2] := @channel^.chip^.zeromod;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
      $01:
        begin
          channel^.slotz[0]^.&mod := @channel^.slotz[0]^.fbmod;
          channel^.slotz[1]^.&mod := @channel^.chip^.zeromod;
          channel^.&out[0] := @channel^.slotz[0]^.&out;
          channel^.&out[1] := @channel^.slotz[1]^.&out;
          channel^.&out[2] := @channel^.chip^.zeromod;
          channel^.&out[3] := @channel^.chip^.zeromod;
        end;
    end;
  end;
end;

procedure OPL3_ChannelUpdateAlg(channel: POplChannel);
begin
  channel^.alg := Wrap8(channel^.con);
  if (channel^.chtype = ch_4op) then
  begin
    channel^.pair^.alg := Wrap8((($04 or (channel^.con shl 1)) or channel^.pair^.con));
    channel^.alg := Wrap8($08);
    OPL3_ChannelSetupAlg(channel^.pair);
  end
  else
  begin
    if (channel^.chtype = ch_4op2) then
    begin
      channel^.alg := Wrap8((($04 or (channel^.pair^.con shl 1)) or channel^.con));
      channel^.pair^.alg := Wrap8($08);
      OPL3_ChannelSetupAlg(channel);
    end
    else
    begin
      OPL3_ChannelSetupAlg(channel);
    end;
  end;
end;

procedure OPL3_ChannelWriteC0(channel: POplChannel; data: Byte);
begin
  channel^.fb := Wrap8(SAR((data and $0e), 1));
  channel^.con := Wrap8((data and $01));
  OPL3_ChannelUpdateAlg(channel);
  if (channel^.chip^.newm <> 0) then
  begin
    channel^.cha := Wrap16(Choose(((SAR(data, 4) and $01) <> 0), (not Integer(0)), 0));
    channel^.chb := Wrap16(Choose(((SAR(data, 5) and $01) <> 0), (not Integer(0)), 0));
    channel^.chc := Wrap16(Choose(((SAR(data, 6) and $01) <> 0), (not Integer(0)), 0));
    channel^.chd := Wrap16(Choose(((SAR(data, 7) and $01) <> 0), (not Integer(0)), 0));
  end
  else
  begin
    channel^.chb := Wrap16(Wrap16((not Integer(0))));
    channel^.cha := Wrap16(channel^.chb);
    channel^.chd := Wrap16(0);
    channel^.chc := Wrap16(channel^.chd);
  end;
end;

procedure OPL3_ChannelKeyOn(channel: POplChannel);
begin
  if (channel^.chtype = ch_4op) then
  begin
    OPL3_EnvelopeKeyOn(channel^.slotz[0], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOn(channel^.slotz[1], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOn(channel^.pair^.slotz[0], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOn(channel^.pair^.slotz[1], Wrap8(egk_norm));
  end
  else
  begin
    if ((channel^.chtype = ch_2op) or (channel^.chtype = ch_drum)) then
    begin
      OPL3_EnvelopeKeyOn(channel^.slotz[0], Wrap8(egk_norm));
      OPL3_EnvelopeKeyOn(channel^.slotz[1], Wrap8(egk_norm));
    end;
  end;
end;

procedure OPL3_ChannelKeyOff(channel: POplChannel);
begin
  if (channel^.chtype = ch_4op) then
  begin
    OPL3_EnvelopeKeyOff(channel^.slotz[0], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOff(channel^.slotz[1], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOff(channel^.pair^.slotz[0], Wrap8(egk_norm));
    OPL3_EnvelopeKeyOff(channel^.pair^.slotz[1], Wrap8(egk_norm));
  end
  else
  begin
    if ((channel^.chtype = ch_2op) or (channel^.chtype = ch_drum)) then
    begin
      OPL3_EnvelopeKeyOff(channel^.slotz[0], Wrap8(egk_norm));
      OPL3_EnvelopeKeyOff(channel^.slotz[1], Wrap8(egk_norm));
    end;
  end;
end;

procedure OPL3_ChannelSet4Op(chip: POplChip; data: Byte);
var
  bit: Byte;
  chnum: Byte;
begin
  bit := Wrap8(0);
  while (bit < 6) do
  begin
    chnum := Wrap8(bit);
    if (bit >= 3) then
    begin
      chnum := Wrap8((chnum + (Int64(9) - Int64(3))));
    end;
    if ((SAR(data, bit) and $01) <> 0) then
    begin
      chip^.channel[chnum].chtype := Wrap8(ch_4op);
      chip^.channel[(Int64(chnum) + Int64(3))].chtype := Wrap8(ch_4op2);
      OPL3_ChannelSync4Op(@chip^.channel[chnum]);
      OPL3_ChannelUpdateAlg(@chip^.channel[chnum]);
    end
    else
    begin
      chip^.channel[chnum].chtype := Wrap8(ch_2op);
      chip^.channel[(Int64(chnum) + Int64(3))].chtype := Wrap8(ch_2op);
      OPL3_ChannelRestoreFrequency(@chip^.channel[(Int64(chnum) + Int64(3))]);
      OPL3_ChannelUpdateAlg(@chip^.channel[chnum]);
      OPL3_ChannelUpdateAlg(@chip^.channel[(Int64(chnum) + Int64(3))]);
    end;
    bit := Wrap8((bit + 1));
  end;
end;

function OPL3_ClipSample(sample: Integer): SmallInt;
begin
  if (sample > 32767) then
  begin
    sample := 32767;
  end
  else
  begin
    if (sample < (-Int64(32768))) then
    begin
      sample := (-Int64(32768));
    end;
  end;
  Exit(Signed16(Signed16(sample)));
end;

procedure OPL3_ProcessSlot(slot: POplSlot);
begin
  OPL3_SlotCalcFB(slot);
  OPL3_EnvelopeCalc(slot);
  OPL3_PhaseGenerate(slot);
  OPL3_SlotGenerate(slot);
end;

procedure OPL3_Generate4Ch(chip: POplChip; var buf4: array of SmallInt);
var
  channel: POplChannel;
  writebuf: POplWriteBuffer;
  mix: array[0..1] of Integer;
  ii: Byte;
  accm: SmallInt;
  shift: Byte;
begin
  if Length(buf4) < 4 then
    raise EArgumentException.Create('OPL output buffer is too small');
  shift := Wrap8(0);
  buf4[1] := Signed16(OPL3_ClipSample(chip^.mixbuff[1]));
  buf4[3] := Signed16(OPL3_ClipSample(chip^.mixbuff[3]));
  ii := Wrap8(0);
  while (ii < 15) do
  begin
    OPL3_ProcessSlot(@chip^.slot[ii]);
    ii := Wrap8((ii + 1));
  end;
  mix[1] := 0;
  mix[0] := mix[1];
  ii := Wrap8(0);
  while (ii < 18) do
  begin
    channel := @chip^.channel[ii];
    accm := Signed16((Int64((Int64((Int64(channel^.&out[0]^) + Int64(channel^.&out[1]^))) + Int64(channel^.&out[2]^))) + Int64(channel^.&out[3]^)));
    mix[0] := (mix[0] + Signed16((accm and channel^.cha)));
    mix[1] := (mix[1] + Signed16((accm and channel^.chc)));
    ii := Wrap8((ii + 1));
  end;
  chip^.mixbuff[0] := mix[0];
  chip^.mixbuff[2] := mix[1];
  ii := Wrap8(15);
  while (ii < 18) do
  begin
    OPL3_ProcessSlot(@chip^.slot[ii]);
    ii := Wrap8((ii + 1));
  end;
  buf4[0] := Signed16(OPL3_ClipSample(chip^.mixbuff[0]));
  buf4[2] := Signed16(OPL3_ClipSample(chip^.mixbuff[2]));
  ii := Wrap8(18);
  while (ii < 33) do
  begin
    OPL3_ProcessSlot(@chip^.slot[ii]);
    ii := Wrap8((ii + 1));
  end;
  mix[1] := 0;
  mix[0] := mix[1];
  ii := Wrap8(0);
  while (ii < 18) do
  begin
    channel := @chip^.channel[ii];
    accm := Signed16((Int64((Int64((Int64(channel^.&out[0]^) + Int64(channel^.&out[1]^))) + Int64(channel^.&out[2]^))) + Int64(channel^.&out[3]^)));
    mix[0] := (mix[0] + Signed16((accm and channel^.chb)));
    mix[1] := (mix[1] + Signed16((accm and channel^.chd)));
    ii := Wrap8((ii + 1));
  end;
  chip^.mixbuff[1] := mix[0];
  chip^.mixbuff[3] := mix[1];
  ii := Wrap8(33);
  while (ii < 36) do
  begin
    OPL3_ProcessSlot(@chip^.slot[ii]);
    ii := Wrap8((ii + 1));
  end;
  if ((chip^.timer and $3f) = $3f) then
  begin
    chip^.tremolopos := Wrap8(((Int64(chip^.tremolopos) + Int64(1)) mod 210));
  end;
  if (chip^.tremolopos < 105) then
  begin
    chip^.tremolo := Wrap8(SAR(chip^.tremolopos, chip^.tremoloshift));
  end
  else
  begin
    chip^.tremolo := Wrap8(SAR((Int64(210) - Int64(chip^.tremolopos)), chip^.tremoloshift));
  end;
  if ((chip^.timer and $3ff) = $3ff) then
  begin
    chip^.vibpos := Wrap8(((Int64(chip^.vibpos) + Int64(1)) and 7));
  end;
  chip^.timer := Wrap16((chip^.timer + 1));
  if (chip^.eg_state <> 0) then
  begin
    while ((shift < 13) and (((chip^.eg_timer shr shift) and 1) = 0)) do
    begin
      shift := Wrap8((shift + 1));
    end;
    if (shift > 12) then
    begin
      chip^.eg_add := Wrap8(0);
    end
    else
    begin
      chip^.eg_add := Wrap8((Int64(shift) + Int64(1)));
    end;
    chip^.eg_timer_lo := Wrap8(Wrap8((chip^.eg_timer and $3)));
  end;
  if ((chip^.eg_timerrem <> 0) or (chip^.eg_state <> 0)) then
  begin
    if (chip^.eg_timer = $fffffffff) then
    begin
      chip^.eg_timer := 0;
      chip^.eg_timerrem := Wrap8(1);
    end
    else
    begin
      chip^.eg_timer := (chip^.eg_timer + 1);
      chip^.eg_timerrem := Wrap8(0);
    end;
  end;
  chip^.eg_state := Wrap8((chip^.eg_state xor 1));
  while True do
  begin
    writebuf := @chip^.writebuf[chip^.writebuf_cur];
    if not (writebuf^.time <= chip^.writebuf_samplecnt) then
      Break;
    if (not ((writebuf^.reg and $200) <> 0)) then
    begin
      Break;
    end;
    writebuf^.reg := Wrap16((writebuf^.reg and $1ff));
    OPL3_WriteReg(chip, Wrap16(writebuf^.reg), Wrap8(writebuf^.data));
    chip^.writebuf_cur := Wrap32(((Int64(chip^.writebuf_cur) + Int64(1)) mod 1024));
  end;
  chip^.writebuf_samplecnt := (chip^.writebuf_samplecnt + 1);
end;

procedure OPL3_Generate(chip: POplChip; var buf: array of SmallInt);
var
  samples: array[0..3] of SmallInt;
begin
  if Length(buf) < 2 then
    raise EArgumentException.Create('OPL output buffer is too small');
  OPL3_Generate4Ch(chip, samples);
  buf[0] := Signed16(samples[0]);
  buf[1] := Signed16(samples[1]);
end;

procedure OPL3_Reset(chip: POplChip; samplerate: Cardinal);
var
  slot: POplSlot;
  channel: POplChannel;
  slotnum: Byte;
  channum: Byte;
  local_ch_slot: Byte;
begin
  FillChar(chip^, SizeOf(TOplChip), 0);
  slotnum := Wrap8(0);
  while (slotnum < 36) do
  begin
    slot := @chip^.slot[slotnum];
    slot^.chip := chip;
    slot^.&mod := @chip^.zeromod;
    slot^.eg_rout := Wrap16($1ff);
    slot^.eg_out := Wrap16($1ff);
    slot^.eg_gen := Wrap8(envelope_gen_num_release);
    slot^.trem := PByte(@chip^.zeromod);
    slot^.slot_num := Wrap8(slotnum);
    slotnum := Wrap8((slotnum + 1));
  end;
  channum := Wrap8(0);
  while (channum < 18) do
  begin
    channel := @chip^.channel[channum];
    local_ch_slot := Wrap8(ch_slot[channum]);
    channel^.slotz[0] := @chip^.slot[local_ch_slot];
    channel^.slotz[1] := @chip^.slot[(Int64(local_ch_slot) + Int64(3))];
    chip^.slot[local_ch_slot].channel := channel;
    chip^.slot[(Int64(local_ch_slot) + Int64(3))].channel := channel;
    if ((channum mod 9) < 3) then
    begin
      channel^.pair := @chip^.channel[(Int64(channum) + Int64(3))];
    end
    else
    begin
      if ((channum mod 9) < 6) then
      begin
        channel^.pair := @chip^.channel[(Int64(channum) - Int64(3))];
      end;
    end;
    channel^.chip := chip;
    channel^.&out[0] := @chip^.zeromod;
    channel^.&out[1] := @chip^.zeromod;
    channel^.&out[2] := @chip^.zeromod;
    channel^.&out[3] := @chip^.zeromod;
    channel^.chtype := Wrap8(ch_2op);
    channel^.cha := Wrap16($ffff);
    channel^.chb := Wrap16($ffff);
    channel^.ch_num := Wrap8(channum);
    OPL3_ChannelSetupAlg(channel);
    channum := Wrap8((channum + 1));
  end;
  chip^.noise := Wrap32(1);
  chip^.rateratio := ((samplerate shl 10) div 49716);
  chip^.tremoloshift := Wrap8(4);
  chip^.vibshift := Wrap8(1);
end;

procedure OPL3_WriteReg(chip: POplChip; reg: Word; v: Byte);
var
  high: Byte;
  regm: Byte;
begin
  if reg > $1FF then
    raise EArgumentOutOfRangeException.Create('Invalid OPL register');
  high := Wrap8((SAR(reg, 8) and $01));
  regm := Wrap8((reg and $ff));
  case (regm and $f0) of
    $00:
      begin
        if (high <> 0) then
        begin
          case (regm and $0f) of
            $04:
              begin
                OPL3_ChannelSet4Op(chip, Wrap8(v));
              end;
            $05:
              begin
                chip^.newm := Wrap8((v and $01));
              end;
          end;
        end
        else
        begin
          case (regm and $0f) of
            $08:
              begin
                chip^.nts := Wrap8((SAR(v, 6) and $01));
              end;
          end;
        end;
      end;
    $20, $30:
      begin
        if (ad_slot[(regm and $1f)] >= 0) then
        begin
          OPL3_SlotWrite20(@chip^.slot[(Int64((Int64(18) * Int64(high))) + Int64(ad_slot[(regm and $1f)]))], Wrap8(v));
        end;
      end;
    $40, $50:
      begin
        if (ad_slot[(regm and $1f)] >= 0) then
        begin
          OPL3_SlotWrite40(@chip^.slot[(Int64((Int64(18) * Int64(high))) + Int64(ad_slot[(regm and $1f)]))], Wrap8(v));
        end;
      end;
    $60, $70:
      begin
        if (ad_slot[(regm and $1f)] >= 0) then
        begin
          OPL3_SlotWrite60(@chip^.slot[(Int64((Int64(18) * Int64(high))) + Int64(ad_slot[(regm and $1f)]))], Wrap8(v));
        end;
      end;
    $80, $90:
      begin
        if (ad_slot[(regm and $1f)] >= 0) then
        begin
          OPL3_SlotWrite80(@chip^.slot[(Int64((Int64(18) * Int64(high))) + Int64(ad_slot[(regm and $1f)]))], Wrap8(v));
        end;
      end;
    $e0, $f0:
      begin
        if (ad_slot[(regm and $1f)] >= 0) then
        begin
          OPL3_SlotWriteE0(@chip^.slot[(Int64((Int64(18) * Int64(high))) + Int64(ad_slot[(regm and $1f)]))], Wrap8(v));
        end;
      end;
    $a0:
      begin
        if ((regm and $0f) < 9) then
        begin
          OPL3_ChannelWriteA0(@chip^.channel[(Int64((Int64(9) * Int64(high))) + Int64((regm and $0f)))], Wrap8(v));
        end;
      end;
    $b0:
      begin
        if ((regm = $bd) and (not (high <> 0))) then
        begin
          chip^.tremoloshift := Wrap8((Int64(((Int64(SAR(v, 7)) xor Int64(1)) shl 1)) + Int64(2)));
          chip^.vibshift := Wrap8((Int64((SAR(v, 6) and $01)) xor Int64(1)));
          OPL3_ChannelUpdateRhythm(chip, Wrap8(v));
        end
        else
        begin
          if ((regm and $0f) < 9) then
          begin
            OPL3_ChannelWriteB0(@chip^.channel[(Int64((Int64(9) * Int64(high))) + Int64((regm and $0f)))], Wrap8(v));
            if ((v and $20) <> 0) then
            begin
              OPL3_ChannelKeyOn(@chip^.channel[(Int64((Int64(9) * Int64(high))) + Int64((regm and $0f)))]);
            end
            else
            begin
              OPL3_ChannelKeyOff(@chip^.channel[(Int64((Int64(9) * Int64(high))) + Int64((regm and $0f)))]);
            end;
          end;
        end;
      end;
    $c0:
      begin
        if ((regm and $0f) < 9) then
        begin
          OPL3_ChannelWriteC0(@chip^.channel[(Int64((Int64(9) * Int64(high))) + Int64((regm and $0f)))], Wrap8(v));
        end;
      end;
  end;
end;

procedure OPL3_WriteRegBuffered(chip: POplChip; reg: Word; v: Byte);
var
  time1: UInt64;
  time2: UInt64;
  writebuf: POplWriteBuffer;
  writebuf_last: Cardinal;
begin
  if reg > $1FF then
    raise EArgumentOutOfRangeException.Create('Invalid OPL register');
  writebuf_last := Wrap32(chip^.writebuf_last);
  writebuf := @chip^.writebuf[writebuf_last];
  if ((writebuf^.reg and $200) <> 0) then
  begin
    OPL3_WriteReg(chip, Wrap16((writebuf^.reg and $1ff)), Wrap8(writebuf^.data));
    chip^.writebuf_cur := Wrap32(((Int64(writebuf_last) + Int64(1)) mod 1024));
    chip^.writebuf_samplecnt := writebuf^.time;
  end;
  writebuf^.reg := Wrap16((reg or $200));
  writebuf^.data := Wrap8(v);
  time1 := (Int64(chip^.writebuf_lasttime) + Int64(2));
  time2 := chip^.writebuf_samplecnt;
  if (time1 < time2) then
  begin
    time1 := time2;
  end;
  writebuf^.time := time1;
  chip^.writebuf_lasttime := time1;
  chip^.writebuf_last := Wrap32(((Int64(writebuf_last) + Int64(1)) mod 1024));
end;

end.

