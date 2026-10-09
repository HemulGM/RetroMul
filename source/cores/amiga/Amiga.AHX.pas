unit Amiga.AHX;

interface

uses
  System.SysUtils;

type
  TAHXEnvelope = record
    AFrames, AVolume, DFrames, DVolume, SFrames, RFrames, RVolume: Integer;
  end;

  TAHXPerf = record
    Note, Wave, FixedNote: Integer;
    FX, Param: array[0..1] of Integer;
  end;

  TAHXInstrument = record
    Volume, WaveLength, FilterLower, FilterUpper, FilterSpeed, SquareLower, SquareUpper, SquareSpeed: Integer;
    VibratoDelay, VibratoSpeed, VibratoDepth, HardCut, HardRelease, PerfSpeed: Integer;
    Envelope: TAHXEnvelope;
    Perf: TArray<TAHXPerf>;
  end;

  TAHXStep = record
    Note, Instrument, FX, Param, FXb, Paramb: Integer;
  end;

  TAHXPosition = record
    Track, Transpose: array[0..15] of Integer;
  end;

  TAHXVoice = record
    Instrument, Track, NextTrack, Transpose, TrackNote, InstrNote, FixedNote, WaveLength, Wave: Integer;
    ADSR: TAHXEnvelope;
    ADSRVolume, Volume, PerfVolume, MasterVolume, AudioVolume, AudioPeriod: Integer;
    SlideOn, SlideSpeed, SlidePeriod, SlideLimit, SlideLimited, PerfSlideOn, PerfSlideSpeed, PerfSlidePeriod: Integer;
    VibratoCurrent, VibratoDelay, VibratoDepth, VibratoSpeed, VibratoPeriod, VolumeUp, VolumeDown: Integer;
    HardCut, HardRelease, HardReleaseFrames, CutOn, CutWait, DelayOn, DelayWait: Integer;
    PerfCurrent, PerfSpeed, PerfWait, SquarePos, SquareOn, SquareInit, SquareWait, SquareSign, SquareIn, IgnoreSquare: Integer;
    SquareLower, SquareUpper, FilterOn, FilterInit, FilterWait, FilterSign, FilterIn, FilterPos, IgnoreFilter: Integer;
    FilterLower, FilterUpper, FilterSpeed, Pan, SetPan, OverrideTranspose: Integer;
    RingNote, RingWave, RingFixed, RingPhase, RingDelta: Integer;
    NoiseRandom: Cardinal;
    Phase, Delta: Integer;
    Buffer: array[0..639] of ShortInt;
    NewWave, PlantPeriod, RingPlantPeriod: Boolean;
  end;

  TAHX = class
  private
    class var
      FWaves: array[0..410759] of ShortInt;
    class var
      FPanL, FPanR: array[0..255] of Integer;
  private
    FPositions: TArray<TAHXPosition>;
    FInstruments: TArray<TAHXInstrument>;
    FSubsongs: TArray<Integer>;
    FTracks: array[0..255, 0..63] of TAHXStep;
    FVoices: array[0..15] of TAHXVoice;
    FTitle: string;
    FHVL: Boolean;
    FChannels, FVersion, FGain, FPanLeft, FPanRight: Integer;
    FLength, FRestart, FSpeed, FPosition, FRow, FTempo, FWait, FJump, FJumpRow, FSamplesLeft: Integer;
    FNewPosition, FPatternBreak, FEnded: Boolean;
    procedure ProcessStep(Channel: Integer);
    procedure PerfCommand(var V: TAHXVoice; FX, Param: Integer);
    procedure ProcessVoice(Channel: Integer);
    procedure Tick;
  public
    class constructor Create;
    constructor Create(const Data: TBytes);
    procedure Reset(Subsong: Integer);
    function FrameCount(Subsong: Integer): Int64;
    function Sample(out Left, Right: SmallInt): Boolean;
    function Title: string;
    function TrackCount: Integer;
    function ChannelCount: Integer;
    function IsHVL: Boolean;
  end;

implementation

uses
  System.Math;

const
  HVLPanLeft: array[0..4] of Integer = (128, 96, 64, 32, 0);
  HVLPanRight: array[0..4] of Integer = (128, 160, 193, 225, 255);
  WaveBlock = 6520;
  TriangleBase = 202120;
  SawBase = 202372;
  SquareBase = 202624;
  NoiseBase = 206720;
  Offsets: array[0..5] of Integer = (0, 4, 12, 28, 60, 124);
  Periods: array[0..60] of Integer = (
    $0000, $0D60, $0CA0, $0BE8, $0B40, $0A98, $0A00, $0970,
    $08E8, $0868, $07F0, $0780, $0714, $06B0, $0650, $05F4,
    $05A0, $054C, $0500, $04B8, $0474, $0434, $03F8, $03C0,
    $038A, $0358, $0328, $02FA, $02D0, $02A6, $0280, $025C,
    $023A, $021A, $01FC, $01E0, $01C5, $01AC, $0194, $017D,
    $0168, $0153, $0140, $012E, $011D, $010D, $00FE, $00F0,
    $00E2, $00D6, $00CA, $00BE, $00B4, $00AA, $00A0, $0097,
    $008F, $0087, $007F, $0078, $0071);
  Vibrato: array[0..63] of Integer = (
    0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
    255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
    0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
    -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24);
  FilterInitial: array[0..2789] of Integer = (
    -1161, -4413, -7161, -13094, 635, 13255, 2189, 6401,
    9041, 16130, 13460, 5360, 6349, 12699, 19049, 25398,
    30464, 32512, 32512, 32515, 31625, 29756, 27158, 24060,
    20667, 17156, 13970, 11375, 9263, 7543, 6142, 5002,
    4074, 3318, 2702, 2178, 1755, 1415, 1141, 909,
    716, 563, 444, 331, -665, -2082, -6170, -9235,
    -13622, 12545, 9617, 3951, 8345, 11246, 18486, 6917,
    3848, 8635, 17271, 25907, 32163, 32512, 32455, 30734,
    27424, 23137, 18397, 13869, 10429, 7843, 5897, 4435,
    3335, 2507, 1885, 1389, 1023, 720, 530, 353,
    260, 173, 96, 32, -18, -55, -79, -92,
    -95, -838, -3229, -7298, -12386, -7107, 13946, 6501,
    5970, 9133, 14947, 16881, 6081, 3048, 10921, 21843,
    31371, 32512, 32068, 28864, 23686, 17672, 12233, 8469,
    5862, 4058, 2809, 1944, 1346, 900, 601, 371,
    223, 137, 64, 7, -34, -58, -69, -70,
    -63, -52, -39, -26, -14, -5, 4984, -4476,
    -8102, -14892, 2894, 12723, 4883, 8010, 9750, 17887,
    11790, 5099, 2520, 13207, 26415, 32512, 32457, 28690,
    22093, 14665, 9312, 5913, 3754, 2384, 1513, 911,
    548, 330, 143, 3, -86, -130, -139, -125,
    -97, -65, -35, -11, 6, 15, 19, 19,
    16, 12, 8, 6877, -5755, -9129, -15709, 9705,
    10893, 4157, 9882, 10897, 19236, 8153, 4285, 2149,
    15493, 30618, 32512, 30220, 22942, 14203, 8241, 4781,
    2774, 1609, 933, 501, 220, 81, 35, 2,
    -18, -26, -25, -20, -13, -7, -1, 2,
    4, 4, 3, 2, 1, 0, 0, -1,
    2431, -6956, -10698, -14594, 12720, 8980, 3714, 10892,
    12622, 19554, 6915, 3745, 1872, 17779, 32512, 32622,
    26286, 16302, 8605, 4542, 2397, 1265, 599, 283,
    45, -92, -141, -131, -93, -49, -14, 8,
    18, 18, 14, 8, 3, 0, -2, -3,
    -2, -2, -1, 0, 0, -3654, -8008, -12743,
    -11088, 13625, 7342, 3330, 11330, 14859, 18769, 6484,
    3319, 1660, 20065, 32512, 30699, 21108, 10616, 5075,
    2425, 1159, 477, 196, 1, -93, -109, -82,
    -44, -12, 7, 14, 13, 9, 4, 0,
    -2, -2, -1, -1, 0, 0, 0, 0,
    0, 0, -7765, -8867, -14957, -5862, 13550, 6139,
    2988, 11284, 17054, 16602, 6017, 2979, 1489, 22351,
    32512, 28083, 15576, 6708, 2888, 1243, 535, 188,
    32, -47, -64, -47, -22, -3, 7, 8,
    5, 3, 0, -1, -1, -1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, -9079,
    -9532, -16960, -335, 13001, 5333, 2704, 11192, 18742,
    13697, 5457, 2703, 1351, 24637, 32512, 24556, 10851,
    4185, 1614, 622, 184, 15, -57, -59, -34,
    -9, 5, 8, 6, 2, 0, -1, -1,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, -8576, -10043, -18551, 4372,
    12190, 4809, 2472, 11230, 19803, 11170, 4953, 2473,
    1236, 26923, 32512, 20567, 7430, 2550, 875, 212,
    51, -30, -43, -25, -6, 3, 5, 3,
    1, 0, -1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, -6960, -10485, -19740, 7864, 11223, 4449, 2279,
    11623, 20380, 9488, 4553, 2280, 1140, 29209, 31829,
    16235, 4924, 1493, 452, 86, -7, -32, -20,
    -5, 2, 3, 2, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, -4739, -10974,
    -19831, 10240, 10190, 4169, 2114, 12524, 20649, 8531,
    4226, 2114, 1057, 31495, 29672, 11916, 3168, 841,
    121, 17, -22, -18, -5, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, -2333, -11641, -19288, 11765, 9175,
    3923, 1971, 13889, 20646, 8007, 3942, 1971, 985,
    32512, 27426, 8446, 1949, 449, 45, -11, -16,
    -5, 1, 1, 1, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    29, -12616, -17971, 12690, 8247, 3693, 1846, 15662,
    20271, 7658, 3692, 1846, 923, 32512, 25132, 6284,
    1245, 246, -71, -78, -17, 8, 7, 1,
    -1, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 2232, -14001, -15234,
    13198, 7447, 3478, 1736, 17409, 19411, 7332, 3472,
    1736, 868, 32512, 22545, 4352, 731, 18, -117,
    -40, 8, 9, 2, -1, -1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 4197, -15836, -11480, 13408, 6791, 3281,
    1639, 19224, 18074, 6978, 3276, 1639, 819, 32512,
    19657, 2706, 380, -148, -86, 2, 13, 3,
    -2, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 5863,
    -17878, -9460, 13389, 6270, 3104, 1551, 20996, 16431,
    6616, 3102, 1551, 776, 32512, 16633, 1921, 221,
    -95, -39, 5, 5, 0, -1, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 7180, -20270, -6194, 13181,
    5866, 2946, 1473, 22548, 14746, 6273, 2946, 1473,
    737, 32512, 13621, 1263, 116, -53, -15, 4,
    2, -1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 8117, -21129, -2795, 12809, 5550, 2804, 1402,
    23717, 13326, 5962, 2804, 1402, 701, 32512, 10687,
    776, -56, -56, 4, 4, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 8560, -19953,
    508, 12299, 5295, 2675, 1337, 25109, 12263, 5684,
    2675, 1338, 669, 32512, 7905, 433, -36, -22,
    3, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 8488, -18731, 3672, 11679, 5080,
    2558, 1279, 26855, 11480, 5434, 2557, 1279, 639,
    32512, 5357, 212, -95, 0, 4, -1, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    7977, -24055, 6537, 10986, 4883, 2450, 1225, 28611,
    10918, 5206, 2450, 1225, 612, 32512, 3131, 83,
    -35, 2, 1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 7088, -30584, 9054,
    10265, 4696, 2351, 1176, 28707, 10494, 4996, 2351,
    1175, 588, 32512, 1920, -155, -13, 4, -1,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 5952, -32627, 11249, 9564, 4519, 2260,
    1130, 28678, 10113, 4803, 2260, 1130, 565, 32512,
    1059, -73, -1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 4629,
    -32753, 13199, 8934, 4351, 2175, 1088, 28446, 9775,
    4623, 2175, 1087, 544, 32512, 434, -22, 1,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 3132, -32768, 15225, 8430,
    4194, 2097, 1049, 30732, 9439, 4456, 2097, 1049,
    524, 32512, 75, -6, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 1345, -32768, 16765, 8107, 4048, 2025, 1012,
    32512, 9112, 4302, 2025, 1012, 506, 32385, 392,
    5, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, -706, -32768,
    17879, 8005, 3913, 1956, 978, 32512, 8843, 4157,
    1957, 978, 489, 31184, 1671, 122, 10, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, -3050, -32768, 18923, 8163, 3799,
    1893, 946, 32512, 8613, 4022, 1893, 945, 473,
    29903, 3074, 316, 52, 11, 3, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    -5812, -32768, 19851, 8626, 3739, 1833, 917, 32512,
    7982, 3889, 1833, 916, 459, 28541, 4567, 731,
    206, 66, 23, 8, 1, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, -9235, -32768, 20587,
    9408, 3841, 1784, 889, 32512, 6486, 3688, 1776,
    889, 447, 27099, 6112, 1379, 313, 135, 65,
    33, 17, 7, 4, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, -12713, 1188, 1318, -1178, -4304, -26320,
    -14931, -1716, -1486, 2494, 3611, 22275, 27450, -31839,
    -29668, -26258, -21608, -15880, -9560, -3211, 3138, 9369,
    15281, 20717, 25571, 29774, 32512, 32512, 32512, 32512,
    32512, 32512, 32512, 32512, 32512, 32512, 32512, 32512,
    32512, 32748, 32600, 32750, 32566, 32659, 32730, 8886,
    1762, 506, -1665, -12112, -24641, -8513, -2224, 247,
    3288, 9926, 25787, 28909, -31048, -27034, -20726, -12532,
    -3896, 4733, 13043, 20568, 27010, 32215, 32512, 32512,
    32512, 32512, 32512, 32512, 32512, 32762, 32696, 32647,
    32512, 32665, 32512, 32587, 32638, 32669, 32681, 32679,
    32667, 32648, 32624, 32598, 6183, 2141, -630, -2674,
    -21856, -18306, -5711, -2161, 2207, 4247, 17616, 26475,
    29719, -30017, -23596, -13741, -2819, 8029, 18049, 26470,
    32512, 32512, 32512, 32512, 32512, 32512, 32512, 32738,
    32663, 32612, 32756, 32549, 32602, 32629, 32636, 32628,
    32610, 32588, 32564, 32542, 32524, 32510, 32500, 32494,
    32492, 3604, 2248, -1495, -5612, -26800, -13545, -4745,
    -1390, 3443, 6973, 23495, 27724, 30246, -28745, -19355,
    -6335, 6861, 19001, 28690, 32512, 32512, 32512, 32512,
    32512, 32512, 32512, 32512, 32667, 32743, 32757, 32730,
    32681, 32624, 32572, 32529, 32500, 32482, 32476, 32477,
    32482, 32489, 32497, 32504, 32509, 32513, 7977, 1975,
    -1861, -9752, -25893, -10150, -4241, 86, 4190, 10643,
    25235, 28481, 30618, -27231, -14398, 1096, 15982, 27872,
    32512, 32512, 32512, 32512, 32512, 32734, 32631, 32767,
    32531, 32553, 32557, 32551, 32539, 32527, 32516, 32509,
    32505, 32504, 32505, 32506, 32508, 32510, 32511, 32512,
    32512, 32512, 32511, 14529, 1389, -2028, -14813, -22765,
    -7845, -3774, 1986, 4706, 14562, 25541, 29019, 30894,
    -25476, -9294, 8516, 23979, 32512, 32512, 32512, 32512,
    32512, 32512, 32708, 32762, 32727, 32654, 32579, 32522,
    32490, 32478, 32480, 32488, 32498, 32507, 32512, 32515,
    32515, 32514, 32513, 32512, 32510, 32510, 32510, 32510,
    17663, 557, -2504, -19988, -19501, -6436, -3340, 4135,
    5461, 18788, 26016, 29448, 31107, -23481, -4160, 15347,
    30045, 32512, 32512, 32512, 32512, 32512, 32674, 32700,
    32654, 32586, 32531, 32498, 32486, 32488, 32496, 32504,
    32510, 32513, 32514, 32513, 32512, 32511, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 16286, -402, -3522,
    -23951, -16641, -5631, -2983, 6251, 6837, 22781, 26712,
    29788, 31277, -21244, 1108, 21806, 32512, 32512, 32512,
    32512, 32695, 32576, 32622, 32600, 32557, 32520, 32501,
    32496, 32500, 32505, 32509, 32512, 32512, 32512, 32511,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 13436, -1351, -4793, -25948, -14224, -5151,
    -2702, 7687, 8805, 25705, 27348, 30064, 31415, -18766,
    5872, 26652, 32512, 32512, 32512, 32747, 32581, 32620,
    32586, 32540, 32508, 32497, 32499, 32505, 32510, 32512,
    32512, 32512, 32511, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 10427,
    -2162, -7136, -26147, -12195, -4810, -2474, 8723, 11098,
    27251, 27832, 30293, 31530, -16047, 10877, 30990, 32512,
    32512, 32512, 32512, 32584, 32571, 32536, 32511, 32502,
    32503, 32507, 32510, 32512, 32512, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 7797, -2748, -10188, -25174,
    -10519, -4515, -2281, 9397, 13473, 27937, 28213, 30487,
    31627, -13087, 15816, 32512, 32512, 32512, 32715, 32550,
    32560, 32534, 32512, 32505, 32506, 32508, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 5840, -3084, -13327, -23617, -9177, -4231, -2116,
    9892, 15843, 28292, 28538, 30652, 31710, -9886, 20235,
    32512, 32512, 32512, 32512, 32550, 32534, 32514, 32507,
    32507, 32510, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 4592, -3215,
    -15898, -21856, -8141, -3958, -1972, 10401, 18229, 28612,
    28824, 30796, 31781, -7103, 24037, 32512, 32512, 32745,
    32535, 32534, 32517, 32508, 32508, 32509, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 3964, -3262, -18721, -20087, -7368,
    -3705, -1847, 11014, 20634, 28996, 29075, 30920, 31843,
    -4732, 27243, 32512, 32512, 32648, 32627, 32530, 32495,
    32500, 32510, 32512, 32512, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    3858, -3404, -21965, -18398, -6801, -3479, -1738, 12009,
    22960, 29429, 29294, 31030, 31898, -2281, 30194, 32512,
    32512, 32699, 32569, 32496, 32496, 32509, 32513, 32512,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 4177, -3869, -24180,
    -16820, -6380, -3280, -1640, 13235, 25035, 29863, 29490,
    31128, 31947, 251, 32758, 32512, 32749, 32652, 32508,
    32490, 32507, 32513, 32512, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 4837, -4913, -26436, -15364, -6056, -3103,
    -1553, 14759, 26704, 30256, 29664, 31215, 31991, 2863,
    32512, 32512, 32657, 32580, 32503, 32501, 32510, 32512,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 5755,
    -6290, -27702, -14036, -5788, -2947, -1474, 16549, 27912,
    30602, 29821, 31294, 32030, 5555, 32512, 32512, 32592,
    32541, 32505, 32507, 32511, 32511, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 6898, -8911, -27788, -12841,
    -5550, -2805, -1403, 18509, 28687, 30906, 29963, 31364,
    32066, 8328, 32512, 32512, 32623, 32511, 32502, 32510,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 8107, -11465, -27077, -11789, -5325, -2676, -1339,
    19833, 29213, 31179, 30092, 31429, 32098, 11181, 32512,
    32512, 32561, 32508, 32508, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 9247, -13203,
    -25808, -10886, -5109, -2559, -1280, 21060, 29636, 31428,
    30209, 31488, 32127, 14114, 32512, 32681, 32529, 32502,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 10252, -16863, -24251, -10137, -4902,
    -2451, -1226, 21937, 30022, 31656, 30317, 31542, 32154,
    17128, 32512, 32581, 32514, 32508, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    11032, -22427, -22598, -9535, -4705, -2353, -1177, 20999,
    30406, 31867, 30415, 31591, 32179, 20222, 32512, 32591,
    32501, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 11539, -19778, -20962,
    -9060, -4522, -2261, -1131, 19486, 30789, 32061, 30507,
    31637, 32201, 23396, 32512, 32535, 32508, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 11803, -12759, -19353, -8690, -4353, -2177,
    -1089, 18499, 31165, 32240, 30591, 31678, 32222, 26651,
    32512, 32514, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 11826,
    -7586, -17510, -8384, -4196, -2099, -1050, 26861, 31521,
    32406, 30669, 31718, 32241, 29986, 32585, 32510, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 32511, 32511, 32511, 32511,
    32511, 32511, 32511, 32511, 11599, -2848, -15807, -8097,
    -4051, -2025, -1014, 30693, 31850, 32561, 30743, 31755,
    32261, 32512, 32524, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 11037, -5302, -14051, -7770, -3913, -1958, -980,
    28033, 32165, 32705, 30810, 31789, 32278, 32512, 32729,
    32536, 32513, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 10114, -7837,
    -12293, -7348, -3782, -1894, -948, 24926, 32473, 32512,
    30873, 31819, 32294, 32512, 32512, 32580, 32527, 32515,
    32512, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 8759, -10456, -10591, -6766, -3638,
    -1835, -917, 24058, 32600, 32512, 30934, 31850, 32309,
    32512, 32512, 32729, 32591, 32537, 32520, 32514, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    32510, 32510, 32510, 32510, 32510, 32510, 32510, 32510,
    6811, -13156, -9045, -5965, -3421, -1776, -890, 31582,
    32246, 32512, 30988, 31878, 32324, 32512, 32512, 32512,
    32628, 32573, 32541, 32526, 32518, 32514, 32513, 32512,
    32512, 32512, 32512, 32512, 32512, 32512, 32512, 32512,
    32512, 32512, 32512, 32512, 32512, 32512, 32512, 32512,
    32512, 32512, 32512, 32512, 32512, 4835);

function Sar(V, B: Integer): Integer; inline;
begin
  if V >= 0 then
    Result := V shr B
  else
    Result := -((-Int64(V) + (Int64(1) shl B) - 1) shr B);
end;

function ClipFilter(V: Integer): Integer; inline;
begin
  Result := V;
  if Sar(V, 16) > 127 then
    Result := 127 * 65536
  else if Sar(V, 16) < -128 then
    Result := -128 * 65536;
end;

class constructor TAHX.Create;
begin
  for var i := 0 to 255 do
  begin
    FPanL[i] := Trunc(Cos((Pi / 2) * i / 256) * 255);
    FPanR[i] := Trunc(Sin((Pi / 2) * i / 256) * 255);
  end;
  FPanL[255] := 0;
  FPanR[0] := 0;
  for var W := 0 to 5 do
  begin
    var N := 4 shl W;
    var Add := 256 div (N - 1);
    var Quarter := N div 4;
    for var i := 0 to N - 1 do
      FWaves[SawBase + Offsets[W] + i] := -128 + i * Add;
    for var i := 0 to Quarter - 1 do
      FWaves[TriangleBase + Offsets[W] + i] := i * (128 div Quarter);
    FWaves[TriangleBase + Offsets[W] + Quarter] := 127;
    for var i := 1 to Quarter - 1 do
      FWaves[TriangleBase + Offsets[W] + Quarter + i] := 128 - i * (128 div Quarter);
    for var i := 0 to N div 2 - 1 do
    begin
      var V := Integer(FWaves[TriangleBase + Offsets[W] + i]);
      if V = 127 then
        V := -128
      else
        V := -V;
      FWaves[TriangleBase + Offsets[W] + N div 2 + i] := V;
    end;
  end;
  for var Duty := 1 to 32 do
    for var i := 0 to 127 do
      if i < (64 - Duty) * 2 then
        FWaves[SquareBase + (Duty - 1) * 128 + i] := -128
      else
        FWaves[SquareBase + (Duty - 1) * 128 + i] := 127;
  var Random: Cardinal := $41595321;
  for var i := 0 to 1919 do
  begin
    var V := Integer(Random and 255);
    if V > 127 then
      Dec(V, 256);
    if Random and $100 <> 0 then
    begin
      V := 127;
      if Random and $8000 <> 0 then
        V := -128;
    end;
    FWaves[NoiseBase + i] := V;
    Random := (Random shr 5) or (Random shl 27);
    Random := (Random and $FFFFFF00) or ((Random and 255) xor $9A);
    var BX := Random and $FFFF;
    Random := (Random shl 2) or (Random shr 30);
    var AX := Random and $FFFF;
    BX := (BX + AX) and $FFFF;
    AX := AX xor BX;
    Random := (Random and $FFFF0000) or AX;
    Random := (Random shr 3) or (Random shl 29);
  end;
  var Init := 0;
  for var Filter := 0 to 30 do
  begin
    var Src := TriangleBase;
    var Dst := Filter * WaveBlock;
    var HighDst := 208640 + Filter * WaveBlock;
    var Freq := 25 + Filter * 9;
    for var Wave := 0 to 44 do
    begin
      var N := 128;
      if Wave < 12 then
        N := 4 shl (Wave mod 6)
      else if Wave = 44 then
        N := 1920;
      var Mid := FilterInitial[Init] * 256;
      var Low := FilterInitial[1395 + Init] * 256;
      Inc(Init);
      for var i := 0 to N - 1 do
      begin
        var High := ClipFilter(Integer(FWaves[Src + i]) * 65536 - Mid - Low);
        Mid := ClipFilter(Mid + Sar(High, 8) * Freq);
        Low := ClipFilter(Low + Sar(Mid, 8) * Freq);
        FWaves[Dst + i] := Sar(Low, 16);
        FWaves[HighDst + i] := Sar(High, 16);
      end;
      Inc(Src, N);
      Inc(Dst, N);
      Inc(HighDst, N);
    end;
  end;
end;

function Sar64(Value: Int64; Bits: Integer): Int64;
begin
  Result := Value div (Int64(1) shl Bits);
  if (Value < 0) and (Value mod (Int64(1) shl Bits) <> 0) then
    Dec(Result);
end;

constructor TAHX.Create(const Data: TBytes);
var
  Pos: Integer;

  function B: Integer;
  begin
    if Pos >= Length(Data) then
      raise EArgumentException.Create('Truncated AHX');

    Result := Data[Pos];
    Inc(Pos);
  end;

  function BEWord: Integer;
  begin
    Result := B * 256;
    Result := Result + B;
  end;

begin
  inherited Create;
  if Length(Data) < 14 then
    raise EArgumentException.Create('Truncated AHX/HVL');

  FHVL := TEncoding.ASCII.GetString(Data, 0, 3) = 'HVL';
  if ((not FHVL) and (TEncoding.ASCII.GetString(Data, 0, 3) <> 'THX')) or (Data[3] > 1) then
    raise EArgumentException.Create('Invalid AHX header');

  FChannels := 4;
  FGain := 194;
  FPanLeft := 64;
  FPanRight := 193;
  FVersion := Data[3];
  if FHVL then
  begin
    if Length(Data) < 16 then
      raise EArgumentException.Create('Truncated HVL');

    FChannels := (Data[8] shr 2) + 4;
    if (FChannels > 16) or (Data[15] > 4) then
      raise EArgumentException.Create('Invalid HVL channel count/stereo');

    FGain := Integer(Data[14]) * 256 div 100;
    FPanLeft := HVLPanLeft[Data[15]];
    FPanRight := HVLPanRight[Data[15]];
  end;
  var NumPos := (Integer(Data[6] and 15) * 256) + Data[7];
  FLength := Data[10];
  var NumTracks := Data[11];
  var NumIns := Data[12];
  if (NumPos < 1) or (NumPos > 1000) or (FLength < 1) or (FLength > 64) or (NumIns > 64) then
    raise EArgumentException.Create('Invalid AHX dimensions');

  FSpeed := ((Data[6] shr 5) and 3) + 1;
  FRestart := Integer(Data[8]) * 256 + Data[9];
  if FHVL then
    FRestart := Integer(Data[8] and 3) * 256 + Data[9];
  if FRestart >= NumPos then
    FRestart := NumPos - 1;
  var TextPos := Integer(Data[4]) * 256 + Data[5];
  if (TextPos < 14) or (TextPos >= Length(Data)) then
    raise EArgumentException.Create('Invalid AHX title offset');

  var EndPos := TextPos;
  while (EndPos < Length(Data)) and (Data[EndPos] <> 0) do
    Inc(EndPos);
  FTitle := TEncoding.ASCII.GetString(Data, TextPos, EndPos - TextPos);
  Pos := 14;
  if FHVL then
    Pos := 16;
  SetLength(FSubsongs, Integer(Data[13]) + 1);
  FSubsongs[0] := 0;
  for var i := 1 to High(FSubsongs) do
  begin
    FSubsongs[i] := BEWord;
    if FSubsongs[i] >= NumPos then
      raise EArgumentException.Create('Invalid AHX subsong');
  end;
  SetLength(FPositions, NumPos);
  for var i := 0 to NumPos - 1 do
    for var C := 0 to FChannels - 1 do
    begin
      var T := B;
      if T > NumTracks then
        raise EArgumentException.Create('AHX position track');

      FPositions[i].Track[C] := T;
      var V := B;
      if V >= 128 then
        Dec(V, 256);
      FPositions[i].Transpose[C] := V;
    end;
  FillChar(FTracks, SizeOf(FTracks), 0);
  for var T := 0 to NumTracks do
  begin
    if (T = 0) and (Data[6] and $80 <> 0) then
      Continue;

    for var Row := 0 to FLength - 1 do
    begin
      var S := Default(TAHXStep);
      var B0 := B;
      if FHVL then
      begin
        if B0 <> $3F then
        begin
          S.Note := B0;
          S.Instrument := B;
          var Effects := B;
          S.FX := Effects shr 4;
          S.FXb := Effects and 15;
          S.Param := B;
          S.Paramb := B;
        end;
      end
      else
      begin
        var B1 := B;
        var B2 := B;
        S.Note := (B0 shr 2) and 63;
        S.Instrument := ((B0 and 3) shl 4) or (B1 shr 4);
        S.FX := B1 and 15;
        S.Param := B2;
      end;
      if (S.Note > 60) or (S.Instrument > NumIns) then
        raise EArgumentException.Create('Invalid AHX note/instrument');

      FTracks[T, Row] := S;
    end;
  end;
  SetLength(FInstruments, NumIns + 1);
  for var i := 1 to NumIns do
  begin
    var H: array[0..21] of Integer;
    for var J := 0 to 21 do
      H[J] := B;
    var V: TAHXInstrument;
    V := Default(TAHXInstrument);
    V.Volume := H[0];
    V.WaveLength := H[1] and 7;
    if (V.Volume > 64) or (V.WaveLength > 5) then
      raise EArgumentException.Create('AHX instrument parameters');

    V.FilterSpeed := ((H[1] shr 3) and 31) or ((H[12] shr 2) and 32);
    V.FilterLower := H[12] and 127;
    V.FilterUpper := H[19] and 63;
    if (V.FilterLower > 63) or (H[3] > 64) or (H[5] > 64) or (H[8] > 64) or (H[16] > 64) or (H[17] > 64) then
      raise EArgumentException.Create('AHX envelope/filter');

    V.Envelope.AFrames := H[2];
    V.Envelope.AVolume := H[3];
    V.Envelope.DFrames := H[4];
    V.Envelope.DVolume := H[5];
    V.Envelope.SFrames := H[6];
    V.Envelope.RFrames := H[7];
    V.Envelope.RVolume := H[8];
    V.VibratoDelay := H[13];
    V.HardCut := (H[14] shr 4) and 7;
    V.HardRelease := Ord(H[14] and 128 <> 0);
    V.VibratoDepth := H[14] and 15;
    V.VibratoSpeed := H[15];
    V.SquareLower := H[16];
    V.SquareUpper := H[17];
    V.SquareSpeed := H[18];
    V.PerfSpeed := H[20];
    SetLength(V.Perf, H[21]);
    for var J := 0 to High(V.Perf) do
    begin
      var B0 := B;
      var B1 := B;
      var P := Default(TAHXPerf);
      if FHVL then
      begin
        var B2 := B;
        P.Wave := B1 and 7;
        P.FixedNote := (B2 shr 6) and 1;
        P.Note := B2 and 63;
        P.FX[0] := B0 and 15;
        P.FX[1] := (B1 shr 3) and 15;
      end
      else
      begin
        P.Wave := ((B0 shl 1) and 6) or (B1 shr 7);
        P.FixedNote := (B1 shr 6) and 1;
        P.Note := B1 and 63;
        P.FX[0] := (B0 shr 2) and 7;
        P.FX[1] := (B0 shr 5) and 7;
        for var K := 0 to 1 do
          if P.FX[K] = 6 then
            P.FX[K] := 12
          else if P.FX[K] = 7 then
            P.FX[K] := 15;
      end;
      if (P.Wave > 4) or (P.Note > 60) then
        raise EArgumentException.Create('Invalid AHX/HVL performance entry');

      for var K := 0 to 1 do
      begin
        P.Param[K] := B;
        if (not FHVL) and (Data[3] = 0) and (P.FX[K] = 4) and (P.Param[K] and $F0 <> 0) then
          P.Param[K] := P.Param[K] and 15;
      end;
      V.Perf[J] := P;
    end;
    FInstruments[i] := V;
  end;
  if Pos > TextPos then
    raise EArgumentException.Create('AHX instrument/title overlap');

  Reset(0);
end;

function TAHX.Title: string;
begin
  Result := FTitle;
end;

function TAHX.ChannelCount: Integer;
begin
  Result := FChannels;
end;

function TAHX.IsHVL: Boolean;
begin
  Result := FHVL;
end;

function TAHX.TrackCount: Integer;
begin
  Result := Length(FSubsongs);
end;

procedure TAHX.Reset(Subsong: Integer);
begin
  if (Subsong < 0) or (Subsong >= Length(FSubsongs)) then
    raise EArgumentOutOfRangeException.Create('AHX subsong');

  FillChar(FVoices, SizeOf(FVoices), 0);
  for var C := 0 to FChannels - 1 do
  begin
    FVoices[C].MasterVolume := 64;
    FVoices[C].PerfVolume := 64;
    FVoices[C].NoiseRandom := $280;
    FVoices[C].Delta := 1;
    FVoices[C].Pan := FPanLeft;
    if C mod 4 in [1, 2] then
      FVoices[C].Pan := FPanRight;
    FVoices[C].SetPan := FVoices[C].Pan;
    FVoices[C].OverrideTranspose := 1000;
  end;
  FPosition := FSubsongs[Subsong];
  FRow := 0;
  FTempo := 6;
  FWait := 0;
  FJump := 0;
  FJumpRow := 0;
  FSamplesLeft := 0;
  FNewPosition := True;
  FPatternBreak := False;
  FEnded := False;
end;

function TAHX.FrameCount(Subsong: Integer): Int64;
begin
  Reset(Subsong);
  var Ticks := 0;
  while not FEnded do
  begin
    if Ticks >= 90000 then
      raise EArgumentException.Create('AHX exceeds 90,000 ticks');

    Tick;
    Inc(Ticks);
  end;
  Result := Int64(Ticks) * (44100 div (50 * FSpeed));
  Reset(Subsong);
end;

procedure TAHX.ProcessStep(Channel: Integer);
var
  V: TAHXVoice;
  S, Step: TAHXStep;
  Note: Integer;

  procedure Phase1;
  begin
    case S.FX of
      0:
        if (S.Param and 15 > 0) and (S.Param and 15 <= 9) then
          FJump := S.Param and 15;
      7:
        if FHVL then
        begin
          V.Pan := (S.Param + 128) and 255;
          V.SetPan := V.Pan;
        end;
      5, 10:
        begin
          V.VolumeDown := S.Param and 15;
          V.VolumeUp := S.Param shr 4;
        end;
      11:
        begin
          FJump := FJump * 100 + (S.Param and 15) + (S.Param shr 4) * 10;
          FPatternBreak := True;
          if FJump <= FPosition then
            FEnded := True;
        end;
      13:
        begin
          FJump := FPosition + 1;
          FJumpRow := (S.Param and 15) + (S.Param shr 4) * 10;
          if FJumpRow >= FLength then
            FJumpRow := 0;
          FPatternBreak := True;
        end;
      14:
        if (S.Param shr 4 = 12) and (S.Param and 15 < FTempo) and (S.Param and 15 <> 0) then
        begin
          V.CutWait := S.Param and 15;
          V.CutOn := 1;
          V.HardRelease := 0;
        end;
      15:
        begin
          FTempo := S.Param;
          if FTempo = 0 then
            FEnded := True;
        end;
    end;
  end;

  procedure Phase2;
  begin
    if S.FX = 9 then
    begin
      V.SquarePos := S.Param shr (5 - V.WaveLength);
      V.IgnoreSquare := 1;
    end;
    if S.FX in [3, 5] then
    begin
      if (S.FX = 3) and (S.Param <> 0) then
        V.SlideSpeed := S.Param;
      if Note <> 0 then
      begin
        var Diff := Periods[V.TrackNote] - Periods[Note];
        if Diff + V.SlidePeriod <> 0 then
          V.SlideLimit := -Diff;
      end;
      V.SlideOn := 1;
      V.SlideLimited := 1;
      Note := 0;
    end;
  end;

  procedure Phase3;
  begin
    case S.FX of
      1:
        begin
          V.SlideSpeed := -S.Param;
          V.SlideOn := 1;
          V.SlideLimited := 0;
        end;
      2:
        begin
          V.SlideSpeed := S.Param;
          V.SlideOn := 1;
          V.SlideLimited := 0;
        end;
      4:
        if (S.Param > 0) and (S.Param < 64) then
          V.IgnoreFilter := S.Param
        else if (S.Param > 64) and (S.Param < 128) then
          V.FilterPos := S.Param - 64;
      12:
        if S.Param <= 64 then
          V.Volume := S.Param
        else if (S.Param >= 80) and (S.Param <= 144) then
        begin
          for var C := 0 to FChannels - 1 do
            FVoices[C].MasterVolume := S.Param - 80;
          V.MasterVolume := S.Param - 80;
        end
        else if (S.Param >= 160) and (S.Param <= 224) then
          V.MasterVolume := S.Param - 160;
      14:
        case S.Param shr 4 of
          1:
            begin
              Dec(V.SlidePeriod, S.Param and 15);
              V.PlantPeriod := True;
            end;
          2:
            begin
              Inc(V.SlidePeriod, S.Param and 15);
              V.PlantPeriod := True;
            end;
          15:
            if FHVL and (FVersion >= 1) and (S.Param and 15 = 1) then
              V.OverrideTranspose := V.Transpose;
          4:
            V.VibratoDepth := S.Param and 15;
          10:
            V.Volume := Min(64, V.Volume + (S.Param and 15));
          11:
            V.Volume := Max(0, V.Volume - (S.Param and 15));
        end;
    end;
  end;

begin
  V := FVoices[Channel];
  V.VolumeUp := 0;
  V.VolumeDown := 0;
  Step := FTracks[FPositions[FPosition].Track[Channel], FRow];
  S := Step;
  Note := Step.Note;
  for var K := 0 to Ord(FHVL) do
  begin
    var FX := Step.FX;
    var Param := Step.Param;
    if K = 1 then
    begin
      FX := Step.FXb;
      Param := Step.Paramb;
    end;
    if (FX = 14) and (Param and $F0 = $D0) then
    begin
      if V.DelayOn <> 0 then
      begin
        V.DelayOn := 0;
        Break;
      end
      else if (Param and 15 < FTempo) and (Param and 15 <> 0) then
      begin
        V.DelayWait := Param and 15;
        V.DelayOn := 1;
        FVoices[Channel] := V;
        Exit;
      end;
    end;
  end;
  if Note <> 0 then
    V.OverrideTranspose := 1000;
  Phase1;
  if FHVL then
  begin
    S.FX := Step.FXb;
    S.Param := Step.Paramb;
    Phase1;
  end;
  S := Step;
  if S.Instrument <> 0 then
  begin
    if FHVL then
    begin
      V.Pan := V.SetPan;
      V.RingNote := 0;
      V.RingPhase := 0;
      V.RingPlantPeriod := False;
    end;
    var i := FInstruments[S.Instrument];
    V.Instrument := S.Instrument;
    V.SlideSpeed := 0;
    V.SlidePeriod := 0;
    V.SlideLimit := 0;
    V.PerfVolume := 64;
    V.ADSRVolume := 0;
    V.Phase := 0;
    V.ADSR := i.Envelope;
    if V.ADSR.AFrames <> 0 then
      V.ADSR.AVolume := i.Envelope.AVolume * 256 div V.ADSR.AFrames
    else
      V.ADSR.AVolume := i.Envelope.AVolume * 256;
    if V.ADSR.DFrames <> 0 then
      V.ADSR.DVolume := (i.Envelope.DVolume - i.Envelope.AVolume) * 256 div V.ADSR.DFrames
    else
      V.ADSR.DVolume := i.Envelope.DVolume * 256;
    if V.ADSR.RFrames <> 0 then
      V.ADSR.RVolume := (i.Envelope.RVolume - i.Envelope.DVolume) * 256 div V.ADSR.RFrames
    else
      V.ADSR.RVolume := i.Envelope.RVolume * 256;
    V.WaveLength := i.WaveLength;
    V.Volume := i.Volume;
    V.VibratoCurrent := 0;
    V.VibratoDelay := i.VibratoDelay;
    V.VibratoDepth := i.VibratoDepth;
    V.VibratoSpeed := i.VibratoSpeed;
    V.VibratoPeriod := 0;
    V.HardRelease := i.HardRelease;
    V.HardCut := i.HardCut;
    V.IgnoreSquare := 0;
    V.SquareIn := 0;
    V.SquareWait := 0;
    V.SquareOn := 0;
    V.SquareLower := Min(i.SquareLower, i.SquareUpper) shr (5 - V.WaveLength);
    V.SquareUpper := Max(i.SquareLower, i.SquareUpper) shr (5 - V.WaveLength);
    V.IgnoreFilter := 0;
    V.FilterWait := 0;
    V.FilterOn := 0;
    V.FilterIn := 0;
    V.FilterSpeed := i.FilterSpeed;
    V.FilterLower := Min(i.FilterLower, i.FilterUpper);
    V.FilterUpper := Max(i.FilterLower, i.FilterUpper);
    V.FilterPos := 32;
    V.PerfWait := 0;
    V.PerfCurrent := 0;
    V.PerfSpeed := i.PerfSpeed;
  end;
  V.SlideOn := 0;
  Phase2;
  if FHVL then
  begin
    S.FX := Step.FXb;
    S.Param := Step.Paramb;
    Phase2;
  end;
  if Note <> 0 then
  begin
    V.TrackNote := Note;
    V.PlantPeriod := True;
  end;
  S := Step;
  Phase3;
  if FHVL then
  begin
    S.FX := Step.FXb;
    S.Param := Step.Paramb;
    Phase3;
  end;
  FVoices[Channel] := V;
end;

procedure TAHX.PerfCommand(var V: TAHXVoice; FX, Param: Integer);
begin
  case FX of
    0:
      if (Param > 0) and (Param < 64) then
      begin
        if V.IgnoreFilter <> 0 then
        begin
          V.FilterPos := V.IgnoreFilter;
          V.IgnoreFilter := 0;
        end
        else
          V.FilterPos := Param;
        V.NewWave := True;
      end;
    1:
      begin
        V.PerfSlideSpeed := Param;
        V.PerfSlideOn := 1;
      end;
    2:
      begin
        V.PerfSlideSpeed := -Param;
        V.PerfSlideOn := 1;
      end;
    3:
      if V.IgnoreSquare = 0 then
        V.SquarePos := Param shr (5 - V.WaveLength)
      else
        V.IgnoreSquare := 0;
    4:
      begin
        if (Param = 0) or (Param and 15 <> 0) then
        begin
          V.SquareOn := V.SquareOn xor 1;
          V.SquareInit := V.SquareOn;
          V.SquareSign := 1;
          if Param and 15 = 15 then
            V.SquareSign := -1;
        end;
        if Param and $F0 <> 0 then
        begin
          V.FilterOn := V.FilterOn xor 1;
          V.FilterInit := V.FilterOn;
          V.FilterSign := 1;
          if Param and $F0 = $F0 then
            V.FilterSign := -1;
        end;
      end;
    7, 8:
      if FHVL then
      begin
        V.RingWave := FX - 7;
        V.RingNote := 0;
        if (Param >= 1) and (Param <= 60) then
        begin
          V.RingNote := Param;
          V.RingFixed := 1;
        end
        else if (Param >= 129) and (Param <= 188) then
        begin
          V.RingNote := Param - 128;
          V.RingFixed := 0;
        end;
        V.RingPlantPeriod := V.RingNote <> 0;
      end;
    9:
      if FHVL then
        V.Pan := (Param + 128) and 255;
    5:
      V.PerfCurrent := Param;
    12:
      if Param <= 64 then
        V.Volume := Param
      else if (Param >= 80) and (Param <= 144) then
        V.PerfVolume := Param - 80
      else if (Param >= 160) and (Param <= 224) then
        V.MasterVolume := Param - 160;
    15:
      begin
        V.PerfSpeed := Param;
        V.PerfWait := Param;
      end;
  end;
end;

procedure TAHX.ProcessVoice(Channel: Integer);
begin
  var V := FVoices[Channel];
  if V.DelayOn <> 0 then
  begin
    if V.DelayWait <= 0 then
    begin
      ProcessStep(Channel);
      V := FVoices[Channel];
    end
    else
      Dec(V.DelayWait);
  end;
  var i := FInstruments[V.Instrument];
  if V.HardCut <> 0 then
  begin
    var Next := FTracks[V.NextTrack, 0].Instrument;
    if FRow + 1 < FLength then
      Next := FTracks[V.Track, FRow + 1].Instrument;
    if Next <> 0 then
      if V.CutOn = 0 then
      begin
        V.CutOn := 1;
        V.CutWait := Max(0, FTempo - V.HardCut);
        V.HardReleaseFrames := FTempo - V.CutWait;
      end
      else
        V.HardCut := 0;
  end;
  if V.CutOn <> 0 then
    if V.CutWait <= 0 then
    begin
      V.CutOn := 0;
      if V.HardRelease <> 0 then
      begin
        V.ADSR.RFrames := V.HardReleaseFrames;
        V.ADSR.RVolume := 0;
        if V.ADSR.RFrames > 0 then
          V.ADSR.RVolume := -(V.ADSRVolume - i.Envelope.RVolume * 256) div V.ADSR.RFrames;
        V.ADSR.AFrames := 0;
        V.ADSR.DFrames := 0;
        V.ADSR.SFrames := 0;
      end
      else
        V.Volume := 0;
    end
    else
      Dec(V.CutWait);
  if V.ADSR.AFrames <> 0 then
  begin
    Inc(V.ADSRVolume, V.ADSR.AVolume);
    Dec(V.ADSR.AFrames);
    if V.ADSR.AFrames <= 0 then
      V.ADSRVolume := i.Envelope.AVolume * 256;
  end
  else if V.ADSR.DFrames <> 0 then
  begin
    Inc(V.ADSRVolume, V.ADSR.DVolume);
    Dec(V.ADSR.DFrames);
    if V.ADSR.DFrames <= 0 then
      V.ADSRVolume := i.Envelope.DVolume * 256;
  end
  else if V.ADSR.SFrames <> 0 then
    Dec(V.ADSR.SFrames)
  else if V.ADSR.RFrames <> 0 then
  begin
    Inc(V.ADSRVolume, V.ADSR.RVolume);
    Dec(V.ADSR.RFrames);
    if V.ADSR.RFrames <= 0 then
      V.ADSRVolume := i.Envelope.RVolume * 256;
  end;
  V.Volume := EnsureRange(V.Volume + V.VolumeUp - V.VolumeDown, 0, 64);
  if V.SlideOn <> 0 then
  begin
    if V.SlideLimited <> 0 then
    begin
      var Diff := V.SlidePeriod - V.SlideLimit;
      var Speed := V.SlideSpeed;
      if Diff > 0 then
        Speed := -Speed;
      if Diff <> 0 then
      begin
        if (Diff + Speed) xor Diff >= 0 then
          Inc(V.SlidePeriod, Speed)
        else
          V.SlidePeriod := V.SlideLimit;
        V.PlantPeriod := True;
      end;
    end
    else
    begin
      V.SlidePeriod := EnsureRange(V.SlidePeriod + V.SlideSpeed, -32768, 32767);
      V.PlantPeriod := True;
    end;
  end;
  if V.VibratoDepth <> 0 then
    if V.VibratoDelay <= 0 then
    begin
      V.VibratoPeriod := Sar(Vibrato[V.VibratoCurrent] * V.VibratoDepth, 7);
      V.PlantPeriod := True;
      V.VibratoCurrent := (V.VibratoCurrent + V.VibratoSpeed) and 63;
    end
    else
      Dec(V.VibratoDelay);
  if V.Instrument <> 0 then
  begin
    if V.PerfCurrent < Length(i.Perf) then
    begin
      var Overflow := V.PerfWait = 128;
      Dec(V.PerfWait);
      var SignedWait := V.PerfWait and 255;
      if SignedWait >= 128 then
        Dec(SignedWait, 256);
      if Overflow or (SignedWait <= 0) then
      begin
        var Entry := i.Perf[V.PerfCurrent];
        Inc(V.PerfCurrent);
        V.PerfWait := V.PerfSpeed;
        if Entry.Wave <> 0 then
        begin
          V.Wave := Entry.Wave - 1;
          V.NewWave := True;
          V.PerfSlideSpeed := 0;
          V.PerfSlidePeriod := 0;
        end;
        V.PerfSlideOn := 0;
        for var K := 0 to 1 do
          PerfCommand(V, Entry.FX[K], Entry.Param[K]);
        if Entry.Note <> 0 then
        begin
          V.InstrNote := Entry.Note;
          V.PlantPeriod := True;
          V.FixedNote := Entry.FixedNote;
        end;
      end;
    end
    else if V.PerfWait <> 0 then
      Dec(V.PerfWait)
    else
      V.PerfSlideSpeed := 0;
  end;
  if V.PerfSlideOn <> 0 then
  begin
    V.PerfSlidePeriod := EnsureRange(V.PerfSlidePeriod - V.PerfSlideSpeed, -32768, 32767);
    if V.PerfSlidePeriod <> 0 then
      V.PlantPeriod := True;
  end;
  if (V.Wave = 2) and (V.SquareOn <> 0) then
  begin
    Dec(V.SquareWait);
    if V.SquareWait <= 0 then
    begin
      if V.SquareInit <> 0 then
      begin
        V.SquareInit := 0;
        if V.SquarePos <= V.SquareLower then
        begin
          V.SquareIn := 1;
          V.SquareSign := 1;
        end
        else if V.SquarePos >= V.SquareUpper then
        begin
          V.SquareIn := 1;
          V.SquareSign := -1;
        end;
      end;
      if (V.SquarePos = V.SquareLower) or (V.SquarePos = V.SquareUpper) then
        if V.SquareIn <> 0 then
          V.SquareIn := 0
        else
          V.SquareSign := -V.SquareSign;
      Inc(V.SquarePos, V.SquareSign);
      V.SquareWait := i.SquareSpeed;
    end;
  end;
  if V.FilterOn <> 0 then
  begin
    Dec(V.FilterWait);
    if V.FilterWait <= 0 then
    begin
      if V.FilterInit <> 0 then
      begin
        V.FilterInit := 0;
        if V.FilterPos <= V.FilterLower then
        begin
          V.FilterIn := 1;
          V.FilterSign := 1;
        end
        else if V.FilterPos >= V.FilterUpper then
        begin
          V.FilterIn := 1;
          V.FilterSign := -1;
        end;
      end;
      var Count := 1;
      if V.FilterSpeed < 4 then
        Count := 5 - V.FilterSpeed;
      for var K := 1 to Count do
      begin
        if (V.FilterPos = V.FilterLower) or (V.FilterPos = V.FilterUpper) then
          if V.FilterIn <> 0 then
            V.FilterIn := 0
          else
            V.FilterSign := -V.FilterSign;
        Inc(V.FilterPos, V.FilterSign);
      end;
      V.FilterPos := EnsureRange(V.FilterPos, 1, 63);
      V.NewWave := True;
      V.FilterWait := Max(1, V.FilterSpeed - 3);
    end;
  end;
  if V.Wave in [2, 3] then
    V.NewWave := True;
  if V.NewWave then
  begin
    var Base := TriangleBase;
    if V.Wave = 1 then
      Base := SawBase
    else if V.Wave = 2 then
      Base := SquareBase
    else if V.Wave = 3 then
      Base := NoiseBase;
    Inc(Base, (EnsureRange(V.FilterPos, 1, 63) - 32) * WaveBlock);
    var N := 4 shl V.WaveLength;
    if V.Wave = 3 then
    begin
      Inc(Base, Integer(V.NoiseRandom and 1278));
      V.NoiseRandom := Cardinal((UInt64(V.NoiseRandom) + 2239384) and $FFFFFFFF);
      var Rotated: Cardinal := (V.NoiseRandom shr 8) or (V.NoiseRandom shl 24);
      if V.NoiseRandom and $80000000 <> 0 then
        Rotated := Rotated or $FF000000;
      V.NoiseRandom := Cardinal(((((UInt64(Rotated) + 782323) and $FFFFFFFF) xor 75) + UInt64($100000000) - 6735) and $FFFFFFFF);
      N := 640;
    end;
    if V.Wave = 2 then
    begin
      var Duty := V.SquarePos shl (5 - V.WaveLength);
      if Duty > 32 then
        Duty := 64 - Duty;
      Duty := EnsureRange(Duty, 0, 32);
      Inc(Base, Max(0, Duty - 1) * 128);
      for var K := 0 to 639 do
        V.Buffer[K] := FWaves[Base + (K mod N) * (32 shr V.WaveLength)];
    end
    else
    begin
      if V.Wave < 2 then
        Inc(Base, Offsets[V.WaveLength]);
      for var K := 0 to 639 do
        V.Buffer[K] := FWaves[Base + K mod N];
    end;
  end;
  var Transpose := V.Transpose;
  if FHVL and (V.OverrideTranspose <> 1000) then
    Transpose := V.OverrideTranspose;
  if (V.RingNote <> 0) and V.RingPlantPeriod then
  begin
    var RingNote := V.RingNote;
    if V.RingFixed = 0 then
      Inc(RingNote, Transpose + V.TrackNote - 1);
    var RingPeriod := Periods[EnsureRange(RingNote, 0, 60)];
    if V.RingFixed = 0 then
      Inc(RingPeriod, V.SlidePeriod);
    Inc(RingPeriod, V.PerfSlidePeriod + V.VibratoPeriod);
    RingPeriod := EnsureRange(RingPeriod, $71, $D60);
    var RingFreq: Single := 3546895.0 * 65536 / RingPeriod;
    V.RingDelta := Max(1, Trunc(RingFreq / 44100.0));
    V.RingPlantPeriod := False;
  end;
  var Note := V.InstrNote;
  if V.FixedNote = 0 then
    Inc(Note, Transpose + V.TrackNote - 1);
  V.AudioPeriod := Periods[EnsureRange(Note, 0, 60)];
  if V.FixedNote = 0 then
    Inc(V.AudioPeriod, V.SlidePeriod);
  Inc(V.AudioPeriod, V.PerfSlidePeriod + V.VibratoPeriod);
  V.AudioPeriod := EnsureRange(V.AudioPeriod, $71, $D60);
  V.AudioVolume := Sar(Sar(Sar(Sar(V.ADSRVolume, 8) * V.Volume, 6) * V.PerfVolume, 6) * V.MasterVolume, 6);
  if V.PlantPeriod then
  begin
    var NativeFreq: Single := 3546895.0 * 65536 / V.AudioPeriod;
    V.Delta := Max(1, Trunc(NativeFreq / 44100.0));
    V.PlantPeriod := False;
  end;
  FVoices[Channel] := V;
end;

procedure TAHX.Tick;
begin
  if FWait = 0 then
  begin
    if FNewPosition then
    begin
      var Next := (FPosition + 1) mod Length(FPositions);
      for var C := 0 to FChannels - 1 do
      begin
        FVoices[C].Track := FPositions[FPosition].Track[C];
        FVoices[C].NextTrack := FPositions[Next].Track[C];
        FVoices[C].Transpose := FPositions[FPosition].Transpose[C];
      end;
      FNewPosition := False;
    end;
    for var C := 0 to FChannels - 1 do
      ProcessStep(C);
    FWait := Max(1, FTempo);
  end;
  for var C := 0 to FChannels - 1 do
    ProcessVoice(C);
  Dec(FWait);
  if FWait = 0 then
  begin
    if not FPatternBreak then
    begin
      Inc(FRow);
      if FRow >= FLength then
      begin
        FJump := FPosition + 1;
        FJumpRow := 0;
        FPatternBreak := True;
      end;
    end;
    if FPatternBreak then
    begin
      FPatternBreak := False;
      FPosition := FJump;
      FRow := FJumpRow;
      if FPosition >= Length(FPositions) then
      begin
        FEnded := True;
        FPosition := FRestart;
      end;
      FJumpRow := 0;
      FJump := 0;
      FNewPosition := True;
    end;
  end;
end;

function TAHX.Sample(out Left, Right: SmallInt): Boolean;
begin
  Result := False;
  if FSamplesLeft = 0 then
  begin
    if FEnded then
      Exit;
    Tick;
    FSamplesLeft := 44100 div (50 * FSpeed);
  end;

  var L := 0;
  var R := 0;
  for var C := 0 to FChannels - 1 do
  begin
    var Wave := Integer(FVoices[C].Buffer[FVoices[C].Phase shr 16]);
    if FVoices[C].RingNote <> 0 then
    begin
      var Base := TriangleBase;
      if FVoices[C].RingWave = 1 then
        Base := SawBase;
      var N := 4 shl FVoices[C].WaveLength;
      var RingSample := Integer(FWaves[Base + Offsets[FVoices[C].WaveLength] + (FVoices[C].RingPhase shr 16) mod N]);
      Wave := Sar(Wave * RingSample, 7);
      FVoices[C].RingPhase := (FVoices[C].RingPhase + FVoices[C].RingDelta) mod (640 * 65536);
    end;
    var V := Wave * FVoices[C].AudioVolume;
    var PanL := FPanL[FVoices[C].Pan];
    // HivelyTracker's single-precision pi literal yields 254 at hard left.
    if FHVL and (FVoices[C].Pan = 0) then
      PanL := 254;
    Inc(L, Sar(V * PanL, 7));
    Inc(R, Sar(V * FPanR[FVoices[C].Pan], 7));
    FVoices[C].Phase := (FVoices[C].Phase + FVoices[C].Delta) mod (640 * 65536);
  end;
  Left := EnsureRange(Sar64(Int64(L) * FGain, 8), -32768, 32767);
  Right := EnsureRange(Sar64(Int64(R) * FGain, 8), -32768, 32767);
  Dec(FSamplesLeft);
  Result := True;
end;

end.

