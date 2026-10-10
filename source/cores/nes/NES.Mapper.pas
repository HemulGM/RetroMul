unit NES.Mapper;

interface

uses
  NES.State, NES.Types;

{$SCOPEDENUMS ON}

const
  // Numeric iNES/NES 2.0 mapper IDs, ordered by ID.
  MAPPER_NROM = 0;
  MAPPER_MMC1 = 1;
  MAPPER_UXROM = 2;
  MAPPER_CNROM = 3;
  MAPPER_MMC3 = 4;
  MAPPER_MMC5 = 5;
  MAPPER_FFE_F4XXX = 6;
  MAPPER_AXROM = 7;
  MAPPER_FFE_F3XXX = 8;
  MAPPER_MMC2 = 9;
  MAPPER_MMC4 = 10;
  MAPPER_COLOR_DREAMS = 11;
  MAPPER_MMC3_12 = 12;
  MAPPER_CPROM = 13;
  MAPPER_MMC3_14 = 14;
  MAPPER_MULTICART_15 = 15;
  MAPPER_BANDAI_FCG = 16;
  MAPPER_FFE_F8XXX = 17;
  MAPPER_JALECO_SS88006 = 18;
  MAPPER_NAMCO_163 = 19;
  MAPPER_VRC4A_VRC4C = 21;
  MAPPER_VRC2A = 22;
  MAPPER_VRC2B_VRC4E = 23;
  MAPPER_VRC6A = 24;
  MAPPER_VRC2C_VRC4B = 25;
  MAPPER_VRC6B = 26;
  MAPPER_VRC2_VRC4_27 = 27;
  MAPPER_ACTION53 = 28;
  MAPPER_SEALIE_COMPUTING = 29;
  MAPPER_UNROM512 = 30;
  MAPPER_NSF_CART = 31;
  MAPPER_IREM_G101 = 32;
  MAPPER_TAITO_TC0190 = 33;
  MAPPER_BNROM_NINA001 = 34;
  MAPPER_JY_35 = 35;
  MAPPER_TXC_22000 = 36;
  MAPPER_MMC3_37 = 37;
  MAPPER_UNL_PCI556 = 38;
  MAPPER_DISCRETE_39 = 39;
  MAPPER_SMB2J_40 = 40;
  MAPPER_CALTRON = 41;
  MAPPER_FDS_CONVERSION_42 = 42;
  MAPPER_SMB2J_43 = 43;
  MAPPER_MMC3_44 = 44;
  MAPPER_MMC3_45 = 45;
  MAPPER_COLOR_DREAMS_46 = 46;
  MAPPER_MMC3_47 = 47;
  MAPPER_TAITO_TC0690 = 48;
  MAPPER_MMC3_49 = 49;
  MAPPER_SMB2J_50 = 50;
  MAPPER_BMC51 = 51;
  MAPPER_MMC3_52 = 52;
  MAPPER_SUPERVISION = 53;
  MAPPER_NOVEL_DIAMOND_54 = 54;
  MAPPER_KAISER_KS202_56 = 56;
  MAPPER_MULTICART_57 = 57;
  MAPPER_MULTICART_58 = 58;
  MAPPER_UNL_D1038 = 59;
  MAPPER_MULTICART_60 = 60;
  MAPPER_MULTICART_61 = 61;
  MAPPER_MULTICART_62 = 62;
  MAPPER_BMC63 = 63;
  MAPPER_RAMBO1 = 64;
  MAPPER_IREM_H3001 = 65;
  MAPPER_GXROM = 66;
  MAPPER_SUNSOFT3 = 67;
  MAPPER_SUNSOFT4 = 68;
  MAPPER_FME7 = 69;
  MAPPER_BANDAI_70 = 70;
  MAPPER_CAMERICA = 71;
  MAPPER_JALECO_JF17 = 72;
  MAPPER_VRC3 = 73;
  MAPPER_MMC3_CHR_RAM_74 = 74;
  MAPPER_VRC1 = 75;
  MAPPER_NAMCO_108_76 = 76;
  MAPPER_IREM_LROG017 = 77;
  MAPPER_IREM_78 = 78;
  MAPPER_NINA03 = 79;
  MAPPER_TAITO_X1005 = 80;
  MAPPER_NTDEC_N715021 = 81;
  MAPPER_TAITO_X1017 = 82;
  MAPPER_CONY = 83;
  MAPPER_VRC7 = 85;
  MAPPER_JALECO_JF13 = 86;
  MAPPER_JALECO_87 = 87;
  MAPPER_NAMCO_118 = 88;
  MAPPER_SUNSOFT_89 = 89;
  MAPPER_JY_90 = 90;
  MAPPER_MMC3_91 = 91;
  MAPPER_JALECO_JF19 = 92;
  MAPPER_SUNSOFT_3R = 93;
  MAPPER_UN1ROM = 94;
  MAPPER_NAMCO_108_95 = 95;
  MAPPER_OEKA_KIDS = 96;
  MAPPER_IREM_TAM_S1 = 97;
  MAPPER_VS_SYSTEM = 99;
  MAPPER_JALECO_101 = 101;
  MAPPER_FDS_CONVERSION_103 = 103;
  MAPPER_GOLDEN_FIVE = 104;
  MAPPER_MMC1_105 = 105;
  MAPPER_IRQ_106 = 106;
  MAPPER_DISCRETE_107 = 107;
  MAPPER_FDS_CONVERSION_108 = 108;
  MAPPER_GTROM = 111;
  MAPPER_DISCRETE_112 = 112;
  MAPPER_NINA_113 = 113;
  MAPPER_MMC3_114 = 114;
  MAPPER_MMC3_115 = 115;
  MAPPER_MULTIMAPPER_116 = 116;
  MAPPER_IRQ_117 = 117;
  MAPPER_TXSROM = 118;
  MAPPER_TQROM = 119;
  MAPPER_DISCRETE_120 = 120;
  MAPPER_MMC3_121 = 121;
  MAPPER_MMC3_123 = 123;
  MAPPER_LH32 = 125;
  MAPPER_MMC3_126 = 126;
  MAPPER_TXC_22211A = 132;
  MAPPER_SACHEN_133 = 133;
  MAPPER_MMC3_134 = 134;
  MAPPER_SACHEN_136 = 136;
  MAPPER_SACHEN_8259D = 137;
  MAPPER_SACHEN_8259B = 138;
  MAPPER_SACHEN_8259C = 139;
  MAPPER_JALECO_140 = 140;
  MAPPER_SACHEN_8259A = 141;
  MAPPER_KAISER_KS202_142 = 142;
  MAPPER_SACHEN_143 = 143;
  MAPPER_AGCI = 144;
  MAPPER_SACHEN_145 = 145;
  MAPPER_NINA03_06_146 = 146;
  MAPPER_SACHEN_147 = 147;
  MAPPER_HES_148 = 148;
  MAPPER_SACHEN_149 = 149;
  MAPPER_SACHEN_74LS374N_150 = 150;
  MAPPER_VRC1_VS = 151;
  MAPPER_BANDAI_152 = 152;
  MAPPER_BANDAI_LZ93D50 = 153;
  MAPPER_NAMCO_154 = 154;
  MAPPER_MMC1A = 155;
  MAPPER_DAOU_INFOSYS = 156;
  MAPPER_BANDAI_DATACH = 157;
  MAPPER_RAMBO1_158 = 158;
  MAPPER_BANDAI_159 = 159;
  MAPPER_WAIXING162 = 162;
  MAPPER_NANJING = 163;
  MAPPER_WAIXING164 = 164;
  MAPPER_MMC3_165 = 165;
  MAPPER_SUBOR166 = 166;
  MAPPER_SUBOR = 167;
  MAPPER_RACERMATE = 168;
  MAPPER_DISCRETE_170 = 170;
  MAPPER_KAISER7058 = 171;
  MAPPER_TXC_22211B = 172;
  MAPPER_TXC_22211C = 173;
  MAPPER_SPECIAL_174 = 174;
  MAPPER_KAISER7022 = 175;
  MAPPER_FK23C = 176;
  MAPPER_HENGGEDIANZI177 = 177;
  MAPPER_WAIXING178 = 178;
  MAPPER_HENGGEDIANZI179 = 179;
  MAPPER_REVERSE_UNROM = 180;
  MAPPER_MMC3_182 = 182;
  MAPPER_VRC2_VRC4_183 = 183;
  MAPPER_SUNSOFT1 = 184;
  MAPPER_CNROM_PROTECT = 185;
  MAPPER_MMC3_187 = 187;
  MAPPER_BANDAI_KARAOKE = 188;
  MAPPER_MMC3_189 = 189;
  MAPPER_MAGIC_KID_GOO_GOO = 190;
  MAPPER_MMC3_CHR_RAM_191 = 191;
  MAPPER_MMC3_CHR_RAM_192 = 192;
  MAPPER_NTDEC_TC112 = 193;
  MAPPER_MMC3_CHR_RAM_194 = 194;
  MAPPER_MMC3_CHR_RAM_195 = 195;
  MAPPER_MMC3_196 = 196;
  MAPPER_MMC3_197 = 197;
  MAPPER_MMC3_198 = 198;
  MAPPER_MMC3_199 = 199;
  MAPPER_MULTICART_200 = 200;
  MAPPER_NOVEL_DIAMOND_201 = 201;
  MAPPER_MULTICART_202 = 202;
  MAPPER_DISCRETE_203 = 203;
  MAPPER_MULTICART_204 = 204;
  MAPPER_MMC3_205 = 205;
  MAPPER_DXROM = 206;
  MAPPER_TAITO_X1005_207 = 207;
  MAPPER_MMC3_208 = 208;
  MAPPER_JY_209 = 209;
  MAPPER_NAMCO_175_340 = 210;
  MAPPER_JY_211 = 211;
  MAPPER_SUPER_HIK_212 = 212;
  MAPPER_MULTICART_213 = 213;
  MAPPER_DISCRETE_214 = 214;
  MAPPER_MMC3_215 = 215;
  MAPPER_DISCRETE_216 = 216;
  MAPPER_MULTICART_217 = 217;
  MAPPER_MAGIC_FLOOR218 = 218;
  MAPPER_MMC3_219 = 219;
  MAPPER_MULTICART_221 = 221;
  MAPPER_IRQ_222 = 222;
  MAPPER_MMC3_224 = 224;
  MAPPER_DISCRETE_225 = 225;
  MAPPER_DISCRETE_226 = 226;
  MAPPER_DISCRETE_227 = 227;
  MAPPER_ACTION52 = 228;
  MAPPER_DISCRETE_229 = 229;
  MAPPER_MULTICART_230 = 230;
  MAPPER_DISCRETE_231 = 231;
  MAPPER_CAMERICA_QUATTRO = 232;
  MAPPER_DISCRETE_233 = 233;
  MAPPER_MULTICART_234 = 234;
  MAPPER_BMC235 = 235;
  MAPPER_BMC70IN1 = 236;
  MAPPER_MMC3_238 = 238;
  MAPPER_DISCRETE_240 = 240;
  MAPPER_DISCRETE_241 = 241;
  MAPPER_WAIXING_242 = 242;
  MAPPER_SACHEN_74LS374N_243 = 243;
  MAPPER_DISCRETE_244 = 244;
  MAPPER_MMC3_245 = 245;
  MAPPER_DISCRETE_246 = 246;
  MAPPER_MMC3_249 = 249;
  MAPPER_MMC3_250 = 250;
  MAPPER_WAIXING_252 = 252;
  MAPPER_VRC4_253 = 253;
  MAPPER_MMC3_254 = 254;
  MAPPER_BMC255 = 255;
  MAPPER_UNL158_B = 258;
  MAPPER_MMC3_BMC_F15 = 259;
  MAPPER_BMC_HPXX = 260;
  MAPPER_BMC810544_CA1 = 261;
  MAPPER_MMC3_STREET_HEROES = 262;
  MAPPER_MMC3_KOF97 = 263;
  MAPPER_YOKO = 264;
  MAPPER_T262 = 265;
  MAPPER_CITY_FIGHTER = 266;
  MAPPER_MMC3_COOLBOY = 268;
  MAPPER_BMC80013_B = 274;
  MAPPER_GS2004 = 283;
  MAPPER_DRIP_GAME = 284;
  MAPPER_A65_AS = 285;
  MAPPER_BS5 = 286;
  MAPPER_MMC3_BMC411120_C = 287;
  MAPPER_GKCX1 = 288;
  MAPPER_BMC60311_C = 289;
  MAPPER_BMC_NTD03 = 290;
  MAPPER_DRAGON_FIGHTER = 292;
  MAPPER_TF1201 = 298;
  MAPPER_BMC11160 = 299;
  MAPPER_BMC190IN1 = 300;
  MAPPER_BMC8157 = 301;
  MAPPER_KAISER7057 = 302;
  MAPPER_KAISER7017 = 303;
  MAPPER_SMB2J = 304;
  MAPPER_KAISER7031 = 305;
  MAPPER_KAISER7016 = 306;
  MAPPER_KAISER7037 = 307;
  MAPPER_LH51 = 309;
  MAPPER_KAISER7013_B = 312;
  MAPPER_RESET_TXROM = 313;
  MAPPER_BMC64IN1_NO_REPEAT = 314;
  MAPPER_HP898F = 319;
  MAPPER_BMC830425_C4391_T = 320;
  MAPPER_FARID_SLROM = 323;
  MAPPER_FARID_UNROM = 324;
  MAPPER_MMC3_MALI_SB = 325;
  MAPPER_RT01 = 328;
  MAPPER_EDU2000 = 329;
  MAPPER_BMC12IN1 = 331;
  MAPPER_SUPER40IN1_WS = 332;
  MAPPER_BMC8IN1 = 333;
  MAPPER_BMC_K3046 = 336;
  MAPPER_KAISER7012 = 346;
  MAPPER_BMC830118_C = 348;
  MAPPER_BMC_G146 = 349;
  MAPPER_BMC_GN45 = 366;
  MAPPER_MULTICART_487 = 487;
  MAPPER_SACHEN_9602 = 513;
  MAPPER_DANCE2000 = 518;
  MAPPER_EH8813_A = 519;
  MAPPER_DREAM_TECH01 = 521;
  MAPPER_LH10 = 522;
  MAPPER_T230 = 529;
  MAPPER_AX5705 = 530;
  MAPPER_KONAMI_QTA = 547;
  MAPPER_TAITO_X1017_552 = 552;
  MAPPER_RAINBOW = 682;
  MAPPER_WARFACE = 3914;

type
  TMirrorMode = (Horizontal, Vertical, Single0, Single1, FourScreen);

  TMapper = class
  protected
    FCpuOpenBus: Byte;
    FPpuRenderingRead: Boolean;
    FPpuSpriteFetch: Boolean;
    class procedure ValidateMemory(const PrgRom, ChrData: TByteArray); static;
  public
    procedure SerializeState(State: TNesStateArchive); virtual;
    // Physical cartridge memory, independent of CPU banking / write protection.
    function GetSaveMemory: TByteArray; virtual;
    procedure SetSaveMemory(const Data: TByteArray); virtual;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; virtual; abstract;
    function CpuReadOpenBus(Address: UInt16; OpenBus: UInt8; out Value: UInt8): Boolean;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; virtual;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; virtual; abstract;
    function PpuReadContext(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean = False): Boolean;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function GetMirrorMode: TMirrorMode; virtual; abstract;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); virtual;
    procedure SetRegion(Region: TNesRegion); virtual;
    procedure ClockCpu; virtual;
    procedure ClockCpuWrite; virtual;
    procedure ClockPpuRead; virtual;
    function HasPpuClockCallbacks: Boolean;
    // Opt in only when repeated PPU reads/fetch context have no side effects.
    function AllowsPpuReadCaching: Boolean; virtual;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); virtual;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); virtual;
    procedure SetPpuControl(Value: UInt8); virtual;
    function IrqPending: Boolean; virtual;
    function ExpansionAudio: Double; virtual;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); virtual;
    function ConsumeDacWrite(out Value: UInt8): Boolean; virtual;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); virtual;
    procedure SetPpuSpriteIndex(Index: Integer); virtual;
    procedure Reset; virtual; abstract;
  end;

implementation

function TMapper.PpuReadContext(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  FPpuRenderingRead := Rendering;
  FPpuSpriteFetch := Sprite;
  try
    Result := PpuRead(Address, Value)
  finally
    FPpuRenderingRead := False;
    FPpuSpriteFetch := False
  end;
end;

procedure TMapper.CpuIoWrite(Address: UInt16; Value: UInt8);
begin
end;

procedure TMapper.SetPpuSpriteIndex(Index: Integer);
begin
end;

procedure TMapper.CpuRamWrite(Address: UInt16; Value: UInt8);
begin
end;

function TMapper.ConsumeDacWrite(out Value: UInt8): Boolean;
begin
  Value := 0;
  Result := False
end;

function TMapper.ExpansionAudio: Double;
begin
  Result := 0
end;

function TMapper.CpuReadOpenBus(Address: UInt16; OpenBus: UInt8; out Value: UInt8): Boolean;
begin
  FCpuOpenBus := OpenBus;
  Result := CpuRead(Address, Value);
end;

function TMapper.AllowsPpuReadCaching: Boolean;
begin
  Result := False;
end;

function TMapper.HasPpuClockCallbacks: Boolean;
type
  TAddressCallback = procedure(Address: UInt16; PpuCycle: UInt64) of object;

  TReadCallback = procedure of object;
var
  AddressCallback: TAddressCallback;
  ReadCallback: TReadCallback;
begin
  AddressCallback := ClockPpuAddress;
  ReadCallback := ClockPpuRead;
  Result := (TMethod(AddressCallback).Code <> @TMapper.ClockPpuAddress) or
    (TMethod(ReadCallback).Code <> @TMapper.ClockPpuRead);
end;

procedure TMapper.SerializeState(State: TNesStateArchive);
begin
end;

function TMapper.GetSaveMemory: TByteArray;
begin
  Result := nil;
end;

procedure TMapper.SetSaveMemory(const Data: TByteArray);
begin
  if Length(Data) <> 0 then
    raise ENesException.Create('This mapper has no persistent memory');
end;

procedure TMapper.SetRegion(Region: TNesRegion);
begin
end;

procedure TMapper.ClockCpu;
begin
end;

procedure TMapper.ClockCpuWrite;
begin
end;

procedure TMapper.ClockPpuRead;
begin
end;

procedure TMapper.ClockScanline(Line: Integer; Rendering: Boolean);
begin
end;

procedure TMapper.SetPpuFetchKind(Sprite: Boolean; X, Y: Integer);
begin
end;

procedure TMapper.SetPpuControl(Value: UInt8);
begin
end;

class procedure TMapper.ValidateMemory(const PrgRom, ChrData: TByteArray);
begin
  if (Length(PrgRom) = 0) or ((Length(PrgRom) mod $4000) <> 0) then
    raise ENesException.Create('PRG ROM must contain complete 16 KB banks');

  if (Length(ChrData) mod $2000) <> 0 then
    raise ENesException.Create('CHR data must contain complete 8 KB banks');
end;

procedure TMapper.ClockPpuAddress(Address: UInt16; PpuCycle: UInt64);
begin
end;

function TMapper.IrqPending: Boolean;
begin
  Result := False;
end;

function TMapper.CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean;
begin
  Result := CpuWrite(Address, Value);
end;

end.

