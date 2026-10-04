unit NES.Mapper.Factory;

interface

uses
  NES.Types, NES.Mapper;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False; Submapper: Integer = 0; Battery: Boolean = False): TMapper;

implementation

uses
  NES.Mapper.Nrom, NES.Mapper.Mmc1, NES.Mapper.Uxrom, NES.Mapper.Cnrom,
  NES.Mapper.Mmc3, NES.Mapper.Axrom, NES.Mapper.Gxrom, NES.Mapper.ColorDreams,
  NES.Mapper.Discrete, NES.Mapper.MmcLatch, NES.Mapper.Mmc3Variants,
  NES.Mapper.Vrc, NES.Mapper.Sunsoft, NES.Mapper.Rambo, NES.Mapper.Cony,
  NES.Mapper.Bandai, NES.Mapper.Jy, NES.Mapper.Mmc5, NES.Mapper.Subor,
  NES.Mapper.Warface, NES.Mapper.ExtendedDiscrete, NES.Mapper.ExtendedIrq,
  NES.Mapper.ExtendedMmc3, NES.Mapper.Multicart, NES.Mapper.Sachen,
  NES.Mapper.ExtendedMemory, NES.Mapper.Flash, NES.Mapper.Namco,
  NES.Mapper.VrcAudio, NES.Mapper.Drip, NES.Mapper.Rainbow;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean; Submapper: Integer; Battery: Boolean): TMapper;
begin
  case MapperId of
    MAPPER_RAINBOW:
      Result := TMapperRainbow.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_DRIP_GAME:
      Result := TMapperDrip.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_VRC6A,             //
    MAPPER_VRC6B,             //
    MAPPER_VRC7:
      Result := TMapperVrcAudio.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_NAMCO_163,         //
    MAPPER_NAMCO_175_340:
      Result := TMapperNamco.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper, LegacyHeader);
    MAPPER_RAMBO1_158:
      Result := TMapperRambo.Create(Prg, Chr, HasChrRam, MirrorMode, True);
    MAPPER_MMC1_105,           //
    MAPPER_FARID_SLROM:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, False, MapperId);
    MAPPER_BANDAI_LZ93D50,     //
    MAPPER_BANDAI_DATACH:
      Result := TMapperBandai.Create(False, Prg, Chr, HasChrRam, MirrorMode, MapperId);
    MAPPER_UNROM512,           //
    MAPPER_GTROM:
      Result := TMapperFlash.Create(MapperId, Prg, Chr, MirrorMode, Submapper, Battery);
    MAPPER_ACTION53,           //
    MAPPER_FDS_CONVERSION_103, //
    MAPPER_WAIXING162,         //
    MAPPER_NANJING,            //
    MAPPER_WAIXING164,         //
    MAPPER_RACERMATE,          //
    MAPPER_SPECIAL_174,        //
    MAPPER_KAISER7022,         //
    MAPPER_BANDAI_KARAOKE,     //
    MAPPER_MAGIC_KID_GOO_GOO,  //
    MAPPER_MAGIC_FLOOR218,     //
    MAPPER_T262,               //
    MAPPER_KAISER7057,         //
    MAPPER_KAISER7031,         //
    MAPPER_KAISER7037,         //
    MAPPER_DANCE2000,          //
    MAPPER_LH10,               //
    MAPPER_AX5705:
      Result := TMapperExtendedMemory.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_TXC_22000,          //
    MAPPER_TXC_22211A,         //
    MAPPER_SACHEN_136,         //
    MAPPER_SACHEN_8259D,       //
    MAPPER_SACHEN_8259B,       //
    MAPPER_SACHEN_8259C,       //
    MAPPER_SACHEN_8259A,       //
    MAPPER_SACHEN_147,         //
    MAPPER_SACHEN_74LS374N_150, //
    MAPPER_TXC_22211B,         //
    MAPPER_TXC_22211C,         //
    MAPPER_SACHEN_74LS374N_243:
      Result := TMapperSachen.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BMC51,              //
    MAPPER_SUPERVISION,        //
    MAPPER_MULTICART_57,       //
    MAPPER_UNL_D1038,          //
    MAPPER_MULTICART_60,       //
    MAPPER_MULTICART_62,       //
    MAPPER_BMC63,              //
    MAPPER_MULTICART_221,      //
    MAPPER_MULTICART_230,      //
    MAPPER_MULTICART_234,      //
    MAPPER_BMC235,             //
    MAPPER_BMC70IN1,           //
    MAPPER_BMC255,             //
    MAPPER_BMC810544_CA1,      //
    MAPPER_BMC80013_B,         //
    MAPPER_BS5,                //
    MAPPER_GKCX1,              //
    MAPPER_BMC60311_C,         //
    MAPPER_BMC_NTD03,          //
    MAPPER_BMC64IN1_NO_REPEAT, //
    MAPPER_BMC830425_C4391_T,  //
    MAPPER_FARID_UNROM,        //
    MAPPER_BMC12IN1,           //
    MAPPER_SUPER40IN1_WS,      //
    MAPPER_BMC_G146,           //
    MAPPER_MULTICART_487,      //
    MAPPER_EH8813_A:
      Result := TMapperMulticart.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3_14,            //
    MAPPER_MMC3_37,            //
    MAPPER_MMC3_44,            //
    MAPPER_MMC3_45,            //
    MAPPER_MMC3_47,            //
    MAPPER_TAITO_TC0690,       //
    MAPPER_MMC3_49,            //
    MAPPER_MMC3_52,            //
    MAPPER_MMC3_CHR_RAM_74,    //
    MAPPER_MMC3_114,           //
    MAPPER_MMC3_115,           //
    MAPPER_MULTIMAPPER_116,    //
    MAPPER_TXSROM,             //
    MAPPER_MMC3_121,           //
    MAPPER_MMC3_123,           //
    MAPPER_MMC3_126,           //
    MAPPER_MMC3_134,           //
    MAPPER_MMC3_165,           //
    MAPPER_FK23C,              //
    MAPPER_MMC3_182,           //
    MAPPER_MMC3_187,           //
    MAPPER_MMC3_189,           //
    MAPPER_MMC3_CHR_RAM_191,   //
    MAPPER_MMC3_CHR_RAM_192,   //
    MAPPER_MMC3_CHR_RAM_194,   //
    MAPPER_MMC3_CHR_RAM_195,   //
    MAPPER_MMC3_196,           //
    MAPPER_MMC3_197,           //
    MAPPER_MMC3_198,           //
    MAPPER_MMC3_199,           //
    MAPPER_MMC3_205,           //
    MAPPER_MMC3_208,           //
    MAPPER_MMC3_215,           //
    MAPPER_MMC3_219,           //
    MAPPER_MMC3_224,           //
    MAPPER_MMC3_238,           //
    MAPPER_MMC3_249,           //
    MAPPER_MMC3_254,           //
    MAPPER_UNL158_B,           //
    MAPPER_MMC3_BMC_F15,       //
    MAPPER_BMC_HPXX,           //
    MAPPER_MMC3_STREET_HEROES, //
    MAPPER_MMC3_KOF97,         //
    MAPPER_MMC3_COOLBOY,       //
    MAPPER_MMC3_BMC411120_C,   //
    MAPPER_DRAGON_FIGHTER,     //
    MAPPER_RESET_TXROM,        //
    MAPPER_MMC3_MALI_SB,       //
    MAPPER_BMC8IN1,            //
    MAPPER_BMC830118_C,        //
    MAPPER_BMC_GN45,           //
    MAPPER_SACHEN_9602:
      Result := TMapperExtendedMmc3.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_FFE_F4XXX,          //
    MAPPER_FFE_F8XXX,          //
    MAPPER_JY_35,              //
    MAPPER_SMB2J_40,           //
    MAPPER_SMB2J_43,           //
    MAPPER_SMB2J_50,           //
    MAPPER_KAISER_KS202_56,    //
    MAPPER_IREM_H3001,         //
    MAPPER_SUNSOFT3,           //
    MAPPER_TAITO_X1005,        //
    MAPPER_TAITO_X1017,        //
    MAPPER_IRQ_106,            //
    MAPPER_IRQ_117,            //
    MAPPER_KAISER_KS202_142,   //
    MAPPER_TAITO_X1005_207,    //
    MAPPER_IRQ_222,            //
    MAPPER_YOKO,               //
    MAPPER_CITY_FIGHTER,       //
    MAPPER_KAISER7017,         //
    MAPPER_SMB2J,              //
    MAPPER_TAITO_X1017_552:
      Result := TMapperExtendedIrq.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_SEALIE_COMPUTING,   //
    MAPPER_UNL_PCI556,         //
    MAPPER_DISCRETE_39,        //
    MAPPER_COLOR_DREAMS_46,    //
    MAPPER_NOVEL_DIAMOND_54,   //
    MAPPER_JALECO_JF17,        //
    MAPPER_NAMCO_108_76,       //
    MAPPER_IREM_LROG017,       //
    MAPPER_JALECO_JF13,        //
    MAPPER_SUNSOFT_89,         //
    MAPPER_JALECO_JF19,        //
    MAPPER_NAMCO_108_95,       //
    MAPPER_OEKA_KIDS,          //
    MAPPER_IREM_TAM_S1,        //
    MAPPER_GOLDEN_FIVE,        //
    MAPPER_DISCRETE_107,       //
    MAPPER_DISCRETE_120,       //
    MAPPER_LH32,               //
    MAPPER_SACHEN_143,         //
    MAPPER_SACHEN_149,         //
    MAPPER_DAOU_INFOSYS,       //
    MAPPER_SUBOR166,           //
    MAPPER_DISCRETE_170,       //
    MAPPER_KAISER7058,         //
    MAPPER_HENGGEDIANZI177,    //
    MAPPER_WAIXING178,         //
    MAPPER_HENGGEDIANZI179,    //
    MAPPER_CNROM_PROTECT,      //
    MAPPER_NTDEC_TC112,        //
    MAPPER_NOVEL_DIAMOND_201,  //
    MAPPER_DISCRETE_203,       //
    MAPPER_DISCRETE_214,       //
    MAPPER_DISCRETE_216,       //
    MAPPER_DISCRETE_225,       //
    MAPPER_DISCRETE_226,       //
    MAPPER_DISCRETE_227,       //
    MAPPER_DISCRETE_229,       //
    MAPPER_DISCRETE_231,       //
    MAPPER_DISCRETE_233,       //
    MAPPER_DISCRETE_241,       //
    MAPPER_DISCRETE_244,       //
    MAPPER_DISCRETE_246,       //
    MAPPER_GS2004,             //
    MAPPER_A65_AS,             //
    MAPPER_BMC11160,           //
    MAPPER_BMC190IN1,          //
    MAPPER_BMC8157,            //
    MAPPER_KAISER7016,         //
    MAPPER_LH51,               //
    MAPPER_KAISER7013_B,       //
    MAPPER_HP898F,             //
    MAPPER_RT01,               //
    MAPPER_EDU2000,            //
    MAPPER_BMC_K3046,          //
    MAPPER_KAISER7012,         //
    MAPPER_DREAM_TECH01:       //
      Result := TMapperExtendedDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_NINA03_06_146:
      Result := TMapperDiscrete.Create(MAPPER_NINA03, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader);
    MAPPER_VRC1_VS:
      Result := TMapperDiscrete.Create(MAPPER_VRC1, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JY_211:
      Result := TMapperJy.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_NROM:
      Result := TMapperNrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC1:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC1A: // NES 2.0/iNES mapper 155 identifies MMC1A, with RAM permanently enabled.
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, True);
    MAPPER_UXROM:
      Result := TMapperUxrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper = 2);
    MAPPER_CNROM:
      Result := TMapperCnrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper <> 1, LegacyHeader);
    MAPPER_MMC3:
      Result := TMapperMmc3.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper = 1);
    MAPPER_AXROM:
      Result := TMapperAxrom.Create(Prg, Chr, HasChrRam, Submapper = 2);
    MAPPER_COLOR_DREAMS:
      Result := TMapperColorDreams.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_GXROM:
      Result := TMapperGxrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC5:
      Result := TMapperMmc5.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BANDAI_FCG,         //
    MAPPER_BANDAI_159:
      Result := TMapperBandai.Create(MapperId = MAPPER_BANDAI_159, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JY_90,              //
    MAPPER_JY_209:
      Result := TMapperJy.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_WARFACE:
      Result := TMapperWarface.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_SUBOR:
      Result := TMapperSubor.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JALECO_140,         //
    MAPPER_REVERSE_UNROM,      //
    MAPPER_NSF_CART,           //
    MAPPER_JALECO_101,         //
    MAPPER_FDS_CONVERSION_108, //
    MAPPER_JALECO_SS88006,     //
    MAPPER_SACHEN_133,         //
    MAPPER_SACHEN_145,         //
    MAPPER_HES_148,            //
    MAPPER_SUNSOFT1,           //
    MAPPER_SUNSOFT_3R,         //
    MAPPER_TAITO_TC0190,       //
    MAPPER_VRC1,               //
    MAPPER_VRC3,               //
    MAPPER_CALTRON,            //
    MAPPER_FDS_CONVERSION_42,  //
    MAPPER_MULTICART_58,       //
    MAPPER_MULTICART_61,       //
    MAPPER_IREM_78,            //
    MAPPER_NTDEC_N715021,      //
    MAPPER_UN1ROM,             //
    MAPPER_MULTICART_200,      //
    MAPPER_MULTICART_202,      //
    MAPPER_MULTICART_204,      //
    MAPPER_SUPER_HIK_212,      //
    MAPPER_MULTICART_213,      //
    MAPPER_MULTICART_217:
      Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, False, Submapper);
    MAPPER_FFE_F3XXX,          //
    MAPPER_CPROM,              //
    MAPPER_MULTICART_15,       //
    MAPPER_IREM_G101,          //
    MAPPER_BNROM_NINA001,      //
    MAPPER_BANDAI_70,          //
    MAPPER_CAMERICA,           //
    MAPPER_NINA03,             //
    MAPPER_JALECO_87,          //
    MAPPER_NAMCO_118,          //
    MAPPER_VS_SYSTEM,          //
    MAPPER_DISCRETE_112,       //
    MAPPER_NINA_113,           //
    MAPPER_AGCI,               //
    MAPPER_BANDAI_152,         //
    MAPPER_NAMCO_154,          //
    MAPPER_DXROM,              //
    MAPPER_ACTION52,           //
    MAPPER_CAMERICA_QUATTRO,   //
    MAPPER_DISCRETE_240,       //
    MAPPER_WAIXING_242:
      Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader);
    MAPPER_MMC2,               //
    MAPPER_MMC4:
      Result := TMapperMmcLatch.Create(MapperId = MAPPER_MMC4, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3_12,            //
    MAPPER_MMC3_91,            //
    MAPPER_TQROM,              //
    MAPPER_MMC3_245,           //
    MAPPER_MMC3_250:
      Result := TMapperMmc3Variant.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_VRC4A_VRC4C,        //
    MAPPER_VRC2_VRC4_27,       //
    MAPPER_VRC2_VRC4_183,      //
    MAPPER_WAIXING_252,        //
    MAPPER_VRC4_253,           //
    MAPPER_TF1201,             //
    MAPPER_T230,               //
    MAPPER_VRC2A,              //
    MAPPER_VRC2B_VRC4E,        //
    MAPPER_VRC2C_VRC4B:
      Result := TMapperVrc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_SUNSOFT4,           //
    MAPPER_FME7:
      Result := TMapperSunsoft.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_RAMBO1:
      Result := TMapperRambo.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_CONY:
      Result := TMapperCony.Create(Prg, Chr, HasChrRam, MirrorMode);
  else
    Result := nil;
  end;
end;

end.

