unit Audio.MP3.Types;

{$POINTERMATH ON}

interface

const
  MAX_BITRESERVOIR_BYTES = 511;
  MAX_L3_FRAME_PAYLOAD_BYTES = 2304;
  SHORT_BLOCK_TYPE = 2;
  STOP_BLOCK_TYPE = 3;
  MODE_MONO = 3;
  MODE_JOINT_STEREO = 1;
  HDR_SIZE = 4;
  BITS_DEQUANTIZER_OUT = -1;
  MAX_SCF = ( 255 + BITS_DEQUANTIZER_OUT * 4 - 210);
  MAX_SCFI = ( MAX_SCF + 3) and (not 3);

  // g_pow43 table: index offset 16, range [-16..128]
  // index 0..15 are negative mirror, 16 = 0, 17..144 = positive
  g_pow43: array[0..144] of Single = (
    0, -1, -2.519842, -4.326749, -6.349604, -8.549880,
    -10.902724, -13.390518, -16.000000, -18.720754, -21.544347,
    -24.463781, -27.473142, -30.567351, -33.741992, -36.993181,
    0, 1, 2.519842, 4.326749, 6.349604, 8.549880,
    10.902724, 13.390518, 16.000000, 18.720754, 21.544347,
    24.463781, 27.473142, 30.567351, 33.741992, 36.993181,
    40.317474, 43.711787, 47.173345, 50.699631, 54.288352,
    57.937408, 61.644865, 65.408941, 69.227979, 73.100443,
    77.024898, 81.000000, 85.024491, 89.097188, 93.216975,
    97.382800, 101.593667, 105.848633, 110.146801, 114.487321,
    118.869381, 123.292209, 127.755065, 132.257246, 136.798076,
    141.376907, 145.993119, 150.646117, 155.335327, 160.060199,
    164.820202, 169.614826, 174.443577, 179.305980, 184.201575,
    189.129918, 194.090580, 199.083145, 204.107210, 209.162385,
    214.248292, 219.364564, 224.510845, 229.686789, 234.892058,
    240.126328, 245.389280, 250.680604, 256.000000, 261.347174,
    266.721841, 272.123723, 277.552547, 283.008049, 288.489971,
    293.998060, 299.532071, 305.091761, 310.676898, 316.287249,
    321.922592, 327.582707, 333.267377, 338.976394, 344.709550,
    350.466646, 356.247482, 362.051866, 367.879608, 373.730522,
    379.604427, 385.501143, 391.420496, 397.362314, 403.326427,
    409.312672, 415.320884, 421.350905, 427.402579, 433.475750,
    439.570269, 445.685987, 451.822757, 457.980436, 464.158883,
    470.357960, 476.577530, 482.817459, 489.077615, 495.357868,
    501.658090, 507.978156, 514.317941, 520.677324, 527.056184,
    533.454404, 539.871867, 546.308458, 552.764065, 559.238575,
    565.731879, 572.243870, 578.774440, 585.323483, 591.890898,
    598.476581, 605.080431, 611.702349, 618.342238, 625.000000,
    631.675540, 638.368763, 645.079578
  );

  // Alias reduction cs/ca coefficients from minimp3 g_aa
  g_aa_cs: array[0..7] of Single = (
    0.85749293, 0.88174200, 0.94962865, 0.98331459,
    0.99551782, 0.99916056, 0.99989920, 0.99999316
  );
  g_aa_ca: array[0..7] of Single = (
    0.51449576, 0.47173197, 0.31337745, 0.18191320,
    0.09457419, 0.04096558, 0.01419856, 0.00369997
  );

  // g_sec for mp3d_DCT_II
  g_sec: array[0..23] of Single = (
    10.19000816, 0.50060302, 0.50241929,
    3.40760851, 0.50547093, 0.52249861,
    2.05778098, 0.51544732, 0.56694406,
    1.48416460, 0.53104258, 0.64682180,
    1.16943991, 0.55310392, 0.78815460,
    0.97256821, 0.58293498, 1.06067765,
    0.83934963, 0.62250412, 1.72244716,
    0.74453628, 0.67480832, 5.10114861
  );

  // IMDCT twiddle factors for 36-point IMDCT
  g_twid9: array[0..17] of Single = (
    0.73727734, 0.79335334, 0.84339145, 0.88701083, 0.92387953,
    0.95371695, 0.97629601, 0.99144486, 0.99904822,
    0.67559021, 0.60876143, 0.53729961, 0.46174861, 0.38268343,
    0.30070580, 0.21643961, 0.13052619, 0.04361938
  );

  // IMDCT twiddle for 12-point (short blocks)
  g_twid3: array[0..5] of Single = (
    0.79335334, 0.92387953, 0.99144486,
    0.60876143, 0.38268343, 0.13052619
  );

  // MDCT windows: [0]=normal/start, [1]=stop
  g_mdct_window: array[0..1, 0..17] of Single = (
    (0.99904822, 0.99144486, 0.97629601, 0.95371695, 0.92387953,
    0.88701083, 0.84339145, 0.79335334, 0.73727734,
    0.04361938, 0.13052619, 0.21643961, 0.30070580, 0.38268343,
    0.46174861, 0.53729961, 0.60876143, 0.67559021),
    (1, 1, 1, 1, 1, 1,
    0.99144486, 0.92387953, 0.79335334,
    0, 0, 0, 0, 0, 0,
    0.13052619, 0.38268343, 0.60876143)
  );

  // g_win for synthesis filter bank (mp3d_synth) - 240 entries (15*16)
  // These are integer values used as: float = value (no scaling needed in the loop)
  g_win: array[0..239] of Single = (
    -1, 26, -31, 208, 218, 401, -519, 2063, 2000, 4788, -5517, 7134, 5959, 35640, -39336, 74992,
    -1, 24, -35, 202, 222, 347, -581, 2080, 1952, 4425, -5879, 7640, 5288, 33791, -41176, 74856,
    -1, 21, -38, 196, 225, 294, -645, 2087, 1893, 4063, -6237, 8092, 4561, 31947, -43006, 74630,
    -1, 19, -41, 190, 227, 244, -711, 2085, 1822, 3705, -6589, 8492, 3776, 30112, -44821, 74313,
    -1, 17, -45, 183, 228, 197, -779, 2075, 1739, 3351, -6935, 8840, 2935, 28289, -46617, 73908,
    -1, 16, -49, 176, 228, 153, -848, 2057, 1644, 3004, -7271, 9139, 2037, 26482, -48390, 73415,
    -2, 14, -53, 169, 227, 111, -919, 2032, 1535, 2663, -7597, 9389, 1082, 24694, -50137, 72835,
    -2, 13, -58, 161, 224, 72, -991, 2001, 1414, 2330, -7910, 9592, 70, 22929, -51853, 72169,
    -2, 11, -63, 154, 221, 36, -1064, 1962, 1280, 2006, -8209, 9750, -998, 21189, -53534, 71420,
    -2, 10, -68, 147, 215, 2, -1137, 1919, 1131, 1692, -8491, 9863, -2122, 19478, -55178, 70590,
    -3, 9, -73, 139, 208, -29, -1210, 1870, 970, 1388, -8755, 9935, -3300, 17799, -56778, 69679,
    -3, 8, -79, 132, 200, -57, -1283, 1817, 794, 1095, -8998, 9966, -4533, 16155, -58333, 68692,
    -4, 7, -85, 125, 189, -83, -1356, 1759, 605, 814, -9219, 9959, -5818, 14548, -59838, 67629,
    -4, 7, -91, 117, 177, -106, -1428, 1698, 402, 545, -9416, 9916, -7154, 12980, -61289, 66494,
    -5, 6, -97, 111, 163, -127, -1498, 1634, 185, 288, -9585, 9838, -8540, 11455, -62684, 65290
  );

  // Scale factor band tables (from minimp3 g_scf_long/short/mixed)
  // Index: sr_idx = HDR_GET_MY_SAMPLE_RATE - (sr!=0)
  // For MPEG1: sr_idx 0-2 map to 44100,48000,32000
  g_scf_long: array[0..7, 0..22] of Byte = (
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (12, 12, 12, 12, 12, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 76, 90, 2, 2, 2, 2, 2, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 18, 22, 26, 32, 38, 46, 54, 62, 70, 76, 36, 0),
    (6, 6, 6, 6, 6, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 38, 46, 52, 60, 68, 58, 54, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 8, 10, 12, 16, 20, 24, 28, 34, 42, 50, 54, 76, 158, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 10, 12, 16, 18, 22, 28, 34, 40, 46, 54, 54, 192, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 8, 10, 12, 16, 20, 24, 30, 38, 46, 56, 68, 84, 102, 26, 0)
  );
  g_scf_short: array[0..7, 0..39] of Byte = (
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0),
    (8, 8, 8, 8, 8, 8, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26, 26, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66, 0),
    (4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12, 0)
  );
  g_scf_mixed: array[0..7, 0..39] of Byte = (
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0, 0, 0, 0),
    (12, 12, 12, 4, 4, 4, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 24, 24, 24, 28, 28, 28, 36, 36, 36, 2, 2, 2, 2, 2, 2, 2, 2, 2, 26, 26, 26, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 14, 14, 14, 18, 18, 18, 26, 26, 26, 32, 32, 32, 42, 42, 42, 18, 18, 18, 0, 0, 0, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 32, 32, 32, 44, 44, 44, 12, 12, 12, 0, 0, 0, 0),
    (6, 6, 6, 6, 6, 6, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 24, 24, 24, 30, 30, 30, 40, 40, 40, 18, 18, 18, 0, 0, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 10, 10, 10, 12, 12, 12, 14, 14, 14, 18, 18, 18, 22, 22, 22, 30, 30, 30, 56, 56, 56, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 6, 6, 6, 10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16, 20, 20, 20, 26, 26, 26, 66, 66, 66, 0, 0),
    (4, 4, 4, 4, 4, 4, 6, 6, 4, 4, 4, 6, 6, 6, 8, 8, 8, 12, 12, 12, 16, 16, 16, 20, 20, 20, 26, 26, 26, 34, 34, 34, 42, 42, 42, 12, 12, 12, 0, 0)
  );

type
  // Array pointer types for indexed pointer access
  TSmallIntArray = array[0..MaxInt div 2 - 1] of SmallInt;

  PSmallIntArray = ^TSmallIntArray;

  TSingleArray = array[0..MaxInt div 4 - 1] of Single;

  PSingleArray = ^TSingleArray;

  TIntegerArray = array[0..MaxInt div 4 - 1] of Integer;

  PIntegerArray = ^TIntegerArray;

  // Granule info structure matching minimp3's L3_gr_info_t
  TL3GrInfo = record
    sfbtab: PByte;           // pointer into g_scf_long/short/mixed
    part_23_length: Word;
    big_values: Word;
    scalefac_compress: Word;
    global_gain: Byte;
    block_type: Byte;
    mixed_block_flag: Byte;
    n_long_sfb: Byte;
    n_short_sfb: Byte;
    table_select: array[0..2] of Byte;
    region_count: array[0..2] of Byte;
    subblock_gain: array[0..2] of Byte;
    preflag: Byte;
    scalefac_scale: Byte;
    count1_table: Byte;
    scfsi: Byte;
  end;

  // mp3dec_t equivalent - decoder persistent state
  TMP3Dec = record
    mdct_overlap: array[0..1, 0..9 * 32 - 1] of Single;   // 2ch x 288
    qmf_state: array[0..15 * 2 * 32 - 1] of Single;          // 960
    syn: array[0..33 * 64 - 1] of Single;                // 2112 - polyphase ring buffer (must persist)
    reserv: Integer;
    free_format_bytes: Integer;
    header: array[0..3] of Byte;
    reserv_buf: array[0..MAX_BITRESERVOIR_BYTES - 1] of Byte;
  end;

  // Bitstream state
  TBsT = record
    buf: PByte;
    pos: Integer;
    limit: Integer;
  end;

  // mp3dec_frame_info_t
  TMP3FrameInfo = record
    frame_bytes: Integer;
    frame_offset: Integer;
    channels: Integer;
    hz: Integer;
    layer: Integer;
    bitrate_kbps: Integer;
  end;

  // For compatibility with existing MP3ToWAV.dpr interface
  TChannelMode = (cmStereo = 0, cmJointStereo = 1, cmDualChannel = 2, cmMono = 3);

  TMP3FrameHeader = record
    SyncWord: Word;
    Version: Integer;
    Layer: Integer;
    BitrateIndex: Integer;
    SampleRateIndex: Integer;
    Padding: Integer;
    ChannelMode: TChannelMode;
    ModeExtension: Integer;
    Copyright: Boolean;
    Original: Boolean;
    Emphasis: Integer;
    Bitrate: Integer;
    SampleRate: Integer;
    Channels: Integer;
    FrameSize: Integer;
    // Raw header bytes for minimp3 macros
    hdr: array[0..3] of Byte;
  end;

  TGranuleInfo = record
    Part2_3_Length: Integer;
    BigValues: Integer;
    GlobalGain: Integer;
    ScalefacCompress: Integer;
    WindowSwitchingFlag: Boolean;
    BlockType: Integer;
    MixedBlockFlag: Boolean;
    TableSelect: array[0..2] of Integer;
    SubblockGain: array[0..2] of Integer;
    Region0Count: Integer;
    Region1Count: Integer;
    Preflag: Boolean;
    ScalefacScale: Integer;
    Count1TableSelect: Integer;
  end;

  TScfsi = array[0..3] of Boolean;

  TMP3SideInfo = record
    MainDataBegin: Integer;
    PrivateBits: Integer;
    Scfsi: array[0..1] of TScfsi;
    Granules: array[0..1, 0..1] of TGranuleInfo;
  end;

  TScaleFactorData = record
    Long: array[0..20] of Integer;
    Short: array[0..2, 0..12] of Integer;
  end;

// Helper inline functions matching minimp3 header macros
function HDR_IS_MONO(const h: array of Byte): Boolean;

function HDR_IS_MS_STEREO(const h: array of Byte): Boolean;

function HDR_IS_FREE_FORMAT(const h: array of Byte): Boolean;

function HDR_IS_CRC(const h: array of Byte): Boolean;

function HDR_TEST_PADDING(const h: array of Byte): Boolean;

function HDR_TEST_MPEG1(const h: array of Byte): Boolean;

function HDR_TEST_NOT_MPEG25(const h: array of Byte): Boolean;

function HDR_TEST_I_STEREO(const h: array of Byte): Boolean;

function HDR_TEST_MS_STEREO(const h: array of Byte): Boolean;

function HDR_GET_STEREO_MODE(const h: array of Byte): Integer;

function HDR_GET_STEREO_MODE_EXT(const h: array of Byte): Integer;

function HDR_GET_LAYER(const h: array of Byte): Integer;

function HDR_GET_BITRATE(const h: array of Byte): Integer;

function HDR_GET_SAMPLE_RATE(const h: array of Byte): Integer;

function HDR_GET_MY_SAMPLE_RATE(const h: array of Byte): Integer;

function HDR_IS_FRAME_576(const h: array of Byte): Boolean;

function HDR_IS_LAYER_1(const h: array of Byte): Boolean;

function hdr_valid(const h: PByte): Boolean;

function hdr_bitrate_kbps(const h: PByte): Cardinal;

function hdr_sample_rate_hz(const h: PByte): Cardinal;

function hdr_frame_samples(const h: PByte): Cardinal;

function hdr_frame_bytes(const h: PByte; free_format_size: Integer): Integer;

function hdr_padding(const h: PByte): Integer;

procedure bs_init(var bs: TBsT; data: PByte; bytes: Integer);

function get_bits(var bs: TBsT; n: Integer): Cardinal;

implementation

function HDR_IS_MONO(const h: array of Byte): Boolean;
begin
  Result := (h[3] and $C0) = $C0;
end;

function HDR_IS_MS_STEREO(const h: array of Byte): Boolean;
begin
  Result := (h[3] and $E0) = $60;
end;

function HDR_IS_FREE_FORMAT(const h: array of Byte): Boolean;
begin
  Result := (h[2] and $F0) = 0;
end;

function HDR_IS_CRC(const h: array of Byte): Boolean;
begin
  Result := (h[1] and 1) = 0;
end;

function HDR_TEST_PADDING(const h: array of Byte): Boolean;
begin
  Result := (h[2] and $2) <> 0;
end;

function HDR_TEST_MPEG1(const h: array of Byte): Boolean;
begin
  Result := (h[1] and $8) <> 0;
end;

function HDR_TEST_NOT_MPEG25(const h: array of Byte): Boolean;
begin
  Result := (h[1] and $10) <> 0;
end;

function HDR_TEST_I_STEREO(const h: array of Byte): Boolean;
begin
  Result := (h[3] and $10) <> 0;
end;

function HDR_TEST_MS_STEREO(const h: array of Byte): Boolean;
begin
  Result := (h[3] and $20) <> 0;
end;

function HDR_GET_STEREO_MODE(const h: array of Byte): Integer;
begin
  Result := (h[3] shr 6) and 3;
end;

function HDR_GET_STEREO_MODE_EXT(const h: array of Byte): Integer;
begin
  Result := (h[3] shr 4) and 3;
end;

function HDR_GET_LAYER(const h: array of Byte): Integer;
begin
  Result := (h[1] shr 1) and 3;
end;

function HDR_GET_BITRATE(const h: array of Byte): Integer;
begin
  Result := h[2] shr 4;
end;

function HDR_GET_SAMPLE_RATE(const h: array of Byte): Integer;
begin
  Result := (h[2] shr 2) and 3;
end;

function HDR_GET_MY_SAMPLE_RATE(const h: array of Byte): Integer;
var
  sr: Integer;
begin
  sr := HDR_GET_SAMPLE_RATE(h);
  Result := sr + (((h[1] shr 3) and 1) + ((h[1] shr 4) and 1)) * 3;
end;

function HDR_IS_FRAME_576(const h: array of Byte): Boolean;
begin
  Result := (h[1] and 14) = 2;
end;

function HDR_IS_LAYER_1(const h: array of Byte): Boolean;
begin
  Result := (h[1] and 6) = 6;
end;

function hdr_valid(const h: PByte): Boolean;
var
  ha: array[0..3] of Byte;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  Result := (h[0] = $FF) and
    (((h[1] and $F0) = $F0) or ((h[1] and $FE) = $E2)) and
    (HDR_GET_LAYER(ha) <> 0) and
    (HDR_GET_BITRATE(ha) <> 15) and
    (HDR_GET_SAMPLE_RATE(ha) <> 3);
end;

function hdr_bitrate_kbps(const h: PByte): Cardinal;
const
  halfrate: array[0..1, 0..2, 0..14] of Byte = (
    ((0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80),
    (0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80),
    (0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128)),
    ((0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160),
    (0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192),
    (0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224))
  );
var
  ha: array[0..3] of Byte;
  isMpeg1, layer, br: Integer;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  if HDR_TEST_MPEG1(ha) then
    isMpeg1 := 1
  else
    isMpeg1 := 0;
  layer := HDR_GET_LAYER(ha) - 1;
  br := HDR_GET_BITRATE(ha);
  Result := 2 * halfrate[isMpeg1][layer][br];
end;

function hdr_sample_rate_hz(const h: PByte): Cardinal;
const
  g_hz: array[0..2] of Cardinal = (44100, 48000, 32000);
var
  ha: array[0..3] of Byte;
  sr: Integer;
  notMpeg1, notMpeg25: Integer;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  sr := HDR_GET_SAMPLE_RATE(ha);
  if HDR_TEST_MPEG1(ha) then
    notMpeg1 := 0
  else
    notMpeg1 := 1;
  if HDR_TEST_NOT_MPEG25(ha) then
    notMpeg25 := 0
  else
    notMpeg25 := 1;
  Result := g_hz[sr] shr notMpeg1 shr notMpeg25;
end;

function hdr_frame_samples(const h: PByte): Cardinal;
var
  ha: array[0..3] of Byte;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  if HDR_IS_LAYER_1(ha) then
    Result := 384
  else
  begin
    if HDR_IS_FRAME_576(ha) then
      Result := 576
    else
      Result := 1152;
  end;
end;

function hdr_frame_bytes(const h: PByte; free_format_size: Integer): Integer;
var
  ha: array[0..3] of Byte;
  frame_bytes: Integer;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  frame_bytes := Integer(hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125) div
    Integer(hdr_sample_rate_hz(h));
  if HDR_IS_LAYER_1(ha) then
    frame_bytes := frame_bytes and (not 3);
  if frame_bytes <> 0 then
    Result := frame_bytes
  else
    Result := free_format_size;
end;

function hdr_padding(const h: PByte): Integer;
var
  ha: array[0..3] of Byte;
begin
  ha[0] := h[0];
  ha[1] := h[1];
  ha[2] := h[2];
  ha[3] := h[3];
  if HDR_TEST_PADDING(ha) then
  begin
    if HDR_IS_LAYER_1(ha) then
      Result := 4
    else
      Result := 1;
  end
  else
    Result := 0;
end;

procedure bs_init(var bs: TBsT; data: PByte; bytes: Integer);
begin
  bs.buf := data;
  bs.pos := 0;
  bs.limit := bytes * 8;
end;

function get_bits(var bs: TBsT; n: Integer): Cardinal;
var
  next, cache: Cardinal;
  s, shl_: Integer;
  p: PByte;
begin
  cache := 0;
  s := bs.pos and 7;
  shl_ := n + s;
  p := bs.buf + (bs.pos shr 3);
  Inc(bs.pos, n);
  if bs.pos > bs.limit then
  begin
    Result := 0;
    Exit;
  end;
  next := p^ and (255 shr s);
  Inc(p);
  shl_ := shl_ - 8;
  while shl_ > 0 do
  begin
    cache := cache or (next shl shl_);
    next := p^;
    Inc(p);
    shl_ := shl_ - 8;
  end;
  Result := cache or (next shr (-shl_));
end;

end.

