unit NES.Mapper.Factory;

interface

uses
  NES.Types, NES.Mapper;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False; Submapper: Integer = 0; Battery: Boolean = False; const MiscRom: TArray<Byte> = nil; const JalecoPack: string = ''): TMapper;

implementation

uses
  NES.Mapper.Nrom, NES.Mapper.Mmc1, NES.Mapper.Uxrom, NES.Mapper.Cnrom,
  NES.Mapper.Mmc3, NES.Mapper.Axrom, NES.Mapper.Gxrom, NES.Mapper.ColorDreams,
  NES.Mapper.Discrete, NES.Mapper.MmcLatch, NES.Mapper.Mmc3Variants,
  NES.Mapper.Vrc, NES.Mapper.Sunsoft, NES.Mapper.Rambo, NES.Mapper.Cony,
  NES.Mapper.Bandai, NES.Mapper.Jy, NES.Mapper.Mmc5, NES.Mapper.Subor,
  NES.Mapper.Warface, NES.Mapper.Jf13, NES.Mapper.ExtendedDiscrete,
  NES.Mapper.ExtendedIrq, NES.Mapper.GameDoctor, NES.Mapper.MagicCard,
  NES.Mapper.Yuxing, NES.Mapper.ExtendedMmc3, NES.Mapper.Multicart,
  NES.Mapper.Sachen, NES.Mapper.ExtendedMemory, NES.Mapper.Flash,
  NES.Mapper.Namco, NES.Mapper.Xmas, NES.Mapper.OneBus, NES.Mapper.VrcAudio,
  NES.Mapper.Drip, NES.Mapper.Rainbow, NES.Mapper.Vrc5, NES.Mapper.Mindkids,
  NES.Mapper.BlazePro, NES.Mapper.SuperGameMega, NES.Mapper.StudyBox,
  NES.Mapper.CoolGirl, NES.Mapper.Um6578;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean; Submapper: Integer; Battery: Boolean; const MiscRom: TArray<Byte>; const JalecoPack: string): TMapper;
begin
  case MapperId of
    MAPPER_JALECO_SS88006:
      if (JalecoPack <> '') or (Length(MiscRom) <> 0) then
        Result := TMapperJalecoIrqSpeech.Create(Prg, Chr, HasChrRam, MirrorMode, LegacyHeader, Submapper, MiscRom)
      else
        Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader, Submapper);
    MAPPER_JALECO_JF17, MAPPER_JALECO_JF19:
      if (JalecoPack <> '') or (Length(MiscRom) <> 0) then
        Result := TMapperJalecoJfSpeech.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper, MiscRom)
      else
        Result := TMapperExtendedDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_JALECO_JF13:
      Result := TMapperJf13.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper, MiscRom);
    MAPPER_BMC_JY104:
      Result := TMapperBmcJy104.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BMC_810344C:
      Result := TMapperBmc810344C.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BTL_UT1245A:
      if Submapper in [0..2] then
        Result := TMapperDbzBootleg.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper)
      else
        Result := nil;
    MAPPER_UM6578, MAPPER_UM6578_ABL, MAPPER_UM6578_JUNGLETAC:
      Result := TMapperUm6578.Create(MapperId, Prg, Chr);
    MAPPER_SUBOR_SB2000:
      Result := TMapperSuborSb2000.Create(Prg, Chr, Submapper);
    MAPPER_COOLGIRL:
      Result := TMapperCoolGirl.Create(Prg);
    MAPPER_STUDY_BOX:
      Result := TMapperStudyBox.Create(Prg);
    MAPPER_SUPER_GAME_MEGA:
      Result := TMapperSuperGameMega.Create(Prg, Chr, MirrorMode);
    MAPPER_MINDKIDS_FPGA:
      Result := TMapperMindkids.Create(Prg, Chr, Submapper);
    MAPPER_SUPER_GAME_DOCTOR, MAPPER_TURBO_GAME_DOCTOR:
      Result := TMapperGameDoctor.Create(Prg, Chr, MirrorMode, Submapper,
        MapperId = MAPPER_TURBO_GAME_DOCTOR, MiscRom);
    MAPPER_3D_BLOCK_PIC:
      Result := TMapper3dBlock.Create(Prg, Chr, HasChrRam, MirrorMode, MiscRom);
    MAPPER_YUXING:
      if LegacyHeader then
        Result := TMapperDiscrete.Create(MAPPER_MULTICART_15, Prg, Chr, HasChrRam, MirrorMode, True)
      else
        Result := TMapperYuxing.Create(Prg, Chr, MirrorMode);
    MAPPER_VRC_830768C:
      Result := TMapperVrc830768C.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_TECHLINE_XB, MAPPER_C88DIP:
      Result := TMapperJyMultiAsic.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BMC_NT319:
      Result := TMapperNt319.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_HSK007:
      Result := TMapperHsk007.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_MCAFE_E1:
      Result := TMapperMcafeE1.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BATMAP_SRRX:
      Result := TMapperBatmapSrrx.Create(Prg, Chr, MiscRom, MirrorMode);
    MAPPER_BATMAP:
      Result := TMapperBatmap.Create(Prg, Chr, MirrorMode, Submapper);
    MAPPER_8BIT_XMAS_2017:
      Result := TMapperXmas.Create(Prg, Chr, MirrorMode);
    MAPPER_IMPACT_SOFT_406:
      Result := TMapperImpactFlash.Create(Prg, Chr, MirrorMode, Submapper);
    MAPPER_HARATYLER:
      Result := TMapperHaratyler.Create(Prg, Chr, MirrorMode);
    MAPPER_RINCO_TALKMAN:
      Result := TMapperRincoTalkman.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_KONAMI_QTA:
      Result := TMapperVrc5.Create(Prg, Chr);
    MAPPER_RAINBOW_NROM:
      Result := TMapperRainbowNrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_RAINBOW_PROTO:
      Result := TMapperRainbowProto.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_RAINBOW512:
      Result := TMapperRainbow512.Create(Prg, Chr, MirrorMode, Battery);
    MAPPER_RAINBOW13:
      Result := TMapperRainbow13.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_RAINBOW:
      Result := TMapperRainbow.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_DRIP_GAME:
      Result := TMapperDrip.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_VRC6A,             //
    MAPPER_VRC6B,             //
    MAPPER_VRC7:
      Result := TMapperVrcAudio.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_BLAZEPRO:
      Result := TMapperBlazePro.Create(Prg, Chr, MirrorMode, Submapper);
    MAPPER_BLAZEPRO_FDS:
      Result := TMapperBlazeProFds.Create(Prg, Chr, MirrorMode);
    MAPPER_CHINA_ER_SAN2:
      Result := TMapperChinaErSan2.Create(Prg, Chr, MiscRom, HasChrRam, MirrorMode);
    MAPPER_NAMCO_163,         //
    MAPPER_NAMCO_175_340, MAPPER_SANGOKUSHI_NAMCOT:
      Result := TMapperNamco.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper, LegacyHeader);
    MAPPER_RAMBO1_158:
      Result := TMapperRambo.Create(Prg, Chr, HasChrRam, MirrorMode, True);
    MAPPER_MMC1_105,           //
    MAPPER_PREDATOR_C806, MAPPER_FARID_SLROM, MAPPER_BMC_3927, MAPPER_BMC_FC41, MAPPER_BMC_03101, MAPPER_MGC002, MAPPER_CH501, MAPPER_GAMESTAR_CM9309:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, False, MapperId);
    MAPPER_JY_CHESS_550, MAPPER_RESET_SLROM, MAPPER_JY012005, MAPPER_BMC_K3011:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, True, MapperId);
    MAPPER_BANDAI_LZ93D50,     //
    MAPPER_BANDAI_DATACH:
      Result := TMapperBandai.Create(False, Prg, Chr, HasChrRam, MirrorMode, MapperId);
    MAPPER_UNROM512,           //
    MAPPER_GTROM, MAPPER_4MROM512:
      Result := TMapperFlash.Create(MapperId, Prg, Chr, MirrorMode, Submapper, Battery);
    MAPPER_WAIXING164:
      Result := TMapperExtendedMemory.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader and Battery);
    MAPPER_WAIXING558, MAPPER_CROAKY_KARAOKE:
      Result := TMapperExtendedMemory.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_ONEBUS, MAPPER_VT42XX, MAPPER_VT32, MAPPER_WIN_LOSE_OR_DRAW, MAPPER_VT369_4150, MAPPER_VT369_411E, MAPPER_VT369_41E6, MAPPER_VT369_SERIAL_ROM, MAPPER_VT369_INVERTER_ROM, MAPPER_VT389, MAPPER_ARCADE_ADVANCED, MAPPER_TAIKEE_ADPCM, MAPPER_ZLX08:
      Result := TMapperOneBus.Create(MapperId, Submapper, Prg, Chr, MirrorMode);
    MAPPER_NESTICLE_MMC3:
      Result := TMapperNesticle.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JNCOTA_KT1005:
      Result := TMapperJncota523.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_PEC586, MAPPER_MEGASONIC_PEC586, MAPPER_SONIC_REC9388, MAPPER_GOLDEN_KEY:
      Result := TMapperPec.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_ASDER_PC95:
      Result := TMapperAsderPc95.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_LITTLE_KIM_PC95:
      Result := TMapperLittleKimPc95.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_DANCING_EXPERT:
      Result := TMapperDancingExpert.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_T262_LEGACY:
      Result := TMapperExtendedMemory.Create(MapperId, Prg, nil, True, TMirrorMode.Vertical);
    MAPPER_ACTION53,           //
    MAPPER_FDS_CONVERSION_103, //
    MAPPER_WAIXING162,         //
    MAPPER_NANJING,            //
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
    MAPPER_REALTEC_8031, MAPPER_BMC70IN1,           //
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
    MAPPER_TEC9719,            //
    MAPPER_ING022,             //
    MAPPER_NES_EVENT2,         //
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
    MAPPER_BMC830134_C, MAPPER_BMC820310, MAPPER_BMC_K3033, MAPPER_BMC_K3006, MAPPER_BMC_BS110, MAPPER_BMC_5IN1_1993, MAPPER_BMC_GN26, MAPPER_BMC_L6IN1, MAPPER_BMC_K3097, MAPPER_BMC_SFC12, MAPPER_BMC_SFC13, MAPPER_BMC_VIP19, MAPPER_GAMES_XPLOSION, MAPPER_BMC_831031C, MAPPER_BMC_840415C, MAPPER_BMC_810431C, MAPPER_BMC_GN23, MAPPER_BMC_FC2940, MAPPER_BMC_47_2, MAPPER_BMC_10_24_C_A1, MAPPER_BMC_ST80, MAPPER_BMC_810305C, MAPPER_F600, MAPPER_REALTEC_8210, MAPPER_JY302, MAPPER_JY208, MAPPER_BMC_EL861121C, MAPPER_BMC_EL860947C, MAPPER_YY841155C, MAPPER_YY840708C, MAPPER_A88S1, MAPPER_REALTEC_K6C3001A, MAPPER_COOLX_LITE, MAPPER_BMC_GN45,           //
    MAPPER_YY841101C,          //
    MAPPER_00202650, MAPPER_820720C, MAPPER_FK206,              //
    MAPPER_REALTEC_MMC3,       //
    MAPPER_NC7000M,            //
    MAPPER_BMC_NT639, MAPPER_BMC_JY830832C, MAPPER_NC3000M, MAPPER_NTDEC_N625231, MAPPER_N49C300, MAPPER_A971210, MAPPER_NTDEC_N625836, MAPPER_BMC_WE7HGX, MAPPER_BMC_480, MAPPER_BMC_K3101, MAPPER_BMC_ET170, MAPPER_BMC_K3054, MAPPER_BMC_5426757A, MAPPER_BMC_GA009, MAPPER_BMC_A018, MAPPER_BMC_CG008, MAPPER_BMC_K3022, MAPPER_BMC_ET149, MAPPER_BMC_TOP_TEN, MAPPER_BMC_T227, MAPPER_BMC_820315C, MAPPER_BMC_F648, MAPPER_BMC_910610, MAPPER_BMC_FC49, MAPPER_BMC_GN27, MAPPER_BMC_K3044, MAPPER_BMC_NS32, MAPPER_BMC_4782, MAPPER_BMC_FC53A, MAPPER_BMC_1N4148, MAPPER_SACHEN_TC032, MAPPER_COCOMA, MAPPER_BMC_N42S2, MAPPER_BMC_JY4M4, MAPPER_BMC_830947, MAPPER_RETROAD_KJ01A, MAPPER_BMC_820215CA2, MAPPER_ESTIQUE, MAPPER_DG574B, MAPPER_SACHEN_9602:
      Result := TMapperExtendedMmc3.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_FFE_F4XXX:
      begin
        if LegacyHeader and (Submapper = 0) then
          Submapper := 1;
        if (Length(Prg) > $80000) or (Length(Chr) > $8000) or (Submapper > 7) then
          Result := TMapperExtendedIrq.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper)
        else
          Result := TMapperMagicCard.Create(MapperId, Submapper, Prg, Chr, MirrorMode);
      end;
    MAPPER_FFE_F3XXX:
      // Retain the historic interpretation of images that cannot fit this board.
      if (Length(Prg) > $80000) or (Length(Chr) > $8000) then
        Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader)
      else
        Result := TMapperMagicCard.Create(MapperId, Submapper, Prg, Chr, MirrorMode);
    MAPPER_FFE_F8XXX:
      if (Length(Prg) > $80000) or (Length(Chr) > $40000) or (Submapper > 3) then
        Result := TMapperExtendedIrq.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper)
      else
        Result := TMapperMagicCard.Create(MapperId, Submapper, Prg, Chr, MirrorMode);
    MAPPER_JY_35,              //
    MAPPER_SMB2J_40,           //
    MAPPER_SMB2J_43, MAPPER_SMB2J_311, //
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
    MAPPER_YUNG_08, MAPPER_SMB2J_4IN1, MAPPER_WHIRLWIND_LH53, MAPPER_CTC15, MAPPER_BMC_SB5013, MAPPER_82112C, MAPPER_BJ56, MAPPER_DOUBLE_DRAGON_PIRATE, MAPPER_J2012_II, MAPPER_BIT_P3117, MAPPER_IMPACT_SOFT_IM1, MAPPER_TAITO_X1017_552, MAPPER_FINE_STUDIO:
      Result := TMapperExtendedIrq.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_SEALIE_COMPUTING,   //
    MAPPER_UNL_PCI556,         //
    MAPPER_DISCRETE_39,        //
    MAPPER_COLOR_DREAMS_46,    //
    MAPPER_NOVEL_DIAMOND_54,   //
    MAPPER_MALEE2,             //
    MAPPER_NAMCO_108_76,       //
    MAPPER_IREM_LROG017,       //
    MAPPER_SUNSOFT_89,         //
    MAPPER_NAMCO_108_95,       //
    MAPPER_OEKA_KIDS,          //
    MAPPER_IREM_TAM_S1,        //
    MAPPER_GOLDEN_FIVE,        //
    MAPPER_DISCRETE_107,       //
    MAPPER_DISCRETE_120,       //
    MAPPER_LH32,               //
    MAPPER_JY043,              //
    MAPPER_SACHEN_143,         //
    MAPPER_SACHEN_149,         //
    MAPPER_DAOU_INFOSYS,       //
    MAPPER_SUBOR166,           //
    MAPPER_DISCRETE_170,       //
    MAPPER_KAISER7058,         //
    MAPPER_HENGGEDIANZI177,    //
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
    MAPPER_MULTICART_380,      //
    MAPPER_CTC09, MAPPER_CTC12IN1, MAPPER_TJ03, MAPPER_BMC_631601, MAPPER_TELETUBBIES_420, MAPPER_OK043, MAPPER_BMC_09078, MAPPER_BMC_P3127_01, MAPPER_BMC_K3017, MAPPER_NEWSTAR_12IN1, MAPPER_BMC_K1053, MAPPER_BMC_SQ002, MAPPER_BMC_35BH1, MAPPER_NTDEC_2779, MAPPER_BMC_K3036, MAPPER_BMC_5069, MAPPER_CALTRON_9IN1, MAPPER_BMC_J2282, MAPPER_BMC_9999999IN1, MAPPER_BMC_TH2348, MAPPER_REALTEC_8042, MAPPER_BMC_ET89, MAPPER_BMC_VQ168, MAPPER_BMC_971107_00G, MAPPER_BMC_YH810X1, MAPPER_NTDEC_9012, MAPPER_BMC_ET120,
      MAPPER_KEYBYTE_COMPUTER, MAPPER_NTDEC_15IN1, MAPPER_BMC_K1079, MAPPER_BMC_0359, MAPPER_BMC_HC001, MAPPER_BMC_N80, MAPPER_SANE_TING_5IN1, MAPPER_BMC_K3069, MAPPER_BMC_CH512K, MAPPER_SACHEN_3014, MAPPER_BMC_BD23, MAPPER_BMC_5068, MAPPER_BMC_FC40, MAPPER_BMC_W03, MAPPER_BMC_J2096, MAPPER_BMC_KN20, MAPPER_BMC_T215, MAPPER_BMC_ET156, MAPPER_BMC_ET82, MAPPER_BMC_8203, MAPPER_BMC_ST32, MAPPER_BMC_FE011, MAPPER_BMC_HN02, MAPPER_BMC_K3057, MAPPER_BMC_ET81, MAPPER_BMC_810706, MAPPER_BMC_810706_LEGACY,
      MAPPER_BMC_810430, MAPPER_BMC_07027, MAPPER_BMC_J2054, MAPPER_NTDEC_A9778, MAPPER_SUPER_SOCCER_CHAMPION, MAPPER_KAISER_KS7030, MAPPER_LUCKY_RABBIT, MAPPER_PALTHENA, MAPPER_KAISER_KS7016B, MAPPER_KAISER_KS7010, MAPPER_WHIRLWIND_LH42, MAPPER_KAISER_KS7021A, MAPPER_CONTRA_PIRATE, MAPPER_SACHEN_3013, MAPPER_NTDEC_2718, MAPPER_BMC_K3021, MAPPER_BMC_ET133A, MAPPER_BMC_J2061, MAPPER_BMC_TX5_8IN1, MAPPER_BMC_T4IN1, MAPPER_BMC_4705, MAPPER_BMC_A23, MAPPER_BMC_63100, MAPPER_BMC_J2042, MAPPER_BMC_T124,
      MAPPER_BMC_K3004, MAPPER_BMC_9135, MAPPER_BMC_LB12IN1, MAPPER_BMC_68IN1, MAPPER_BMC_3945, MAPPER_BMC_J2083, MAPPER_BMC_KL09B, MAPPER_BMC_ET20, MAPPER_BMC_90IN1, MAPPER_BMC_821134, MAPPER_BMC_GC004, MAPPER_MGC026, MAPPER_RESET_NROM256, MAPPER_I030_0365, MAPPER_SA005A, MAPPER_BMC891227, MAPPER_FAM250, MAPPER_P3150, MAPPER_LITTLECOM160, MAPPER_MULTICART_375, MAPPER_KN42, MAPPER_BMC830928C, MAPPER_INX_007T, MAPPER_SUBOR_045N, MAPPER_MAXIVISION_NTDEC, MAPPER_MULTICART_428,      //
    MAPPER_YY850437C,          //
    MAPPER_NC20MB,             //
    MAPPER_S009,               //
    MAPPER_F1002,              //
    MAPPER_YS2309,             //
    MAPPER_SUPER_GAMES_KING,    //
    MAPPER_BMC_K3046,          //
    MAPPER_KAISER7012,         //
    MAPPER_YHC_UNROM, MAPPER_YHC_AXROM, MAPPER_YHC_MULTICART, MAPPER_SACHEN_89433, MAPPER_LIKO_429, MAPPER_BMC_K3071, MAPPER_KAISER_KS7009, MAPPER_JINGKETAI, MAPPER_DREAM_TECH01:       //
      Result := TMapperExtendedDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_N46:
      Result := TMapperN46.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_SUBOR_LOGO:
      Result := TMapperSuborLogo.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_CE_BASIC:
      Result := TMapperCeBasic.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_SUBOR_KARAOKE:
      Result := TMapperSuborKaraoke.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_FAMILY_NORAEBANG:
      Result := TMapperFamilyNoraebang.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_KKACHI_KARAOKE:
      Result := TMapperKkachiKaraoke.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_RCM_DS9:
      Result := TMapperRcm452.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_NINA03_06_146:
      Result := TMapperDiscrete.Create(MAPPER_NINA03, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader);
    MAPPER_VRC1_VS:
      Result := TMapperDiscrete.Create(MAPPER_VRC1, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JY_211:
      Result := TMapperJy.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_NROM:
      Result := TMapperNrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC1, MAPPER_MMC1A:
      if Submapper = 6 then
        Result := TMapperMmc1TwoMe.Create(Prg)
      else
        Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, MapperId = MAPPER_MMC1A,
          MAPPER_MMC1, Submapper);
    MAPPER_UXROM:
      Result := TMapperUxrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper = 2);
    MAPPER_CNROM:
      Result := TMapperCnrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper <> 1, LegacyHeader);
    MAPPER_MMC3:
      if Submapper = 5 then
        Result := TMapperMmc3.Create(Prg, Chr, HasChrRam, MirrorMode, False, False, False, False, CanonicalT9552)
      else
        Result := TMapperMmc3.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper = 1, Submapper = 3,
          Submapper = 2, Submapper = 4, NoT9552, Submapper in [0, 2, 4], Submapper = 6);
    MAPPER_AXROM:
      Result := TMapperAxrom.Create(Prg, Chr, HasChrRam, Submapper = 2);
    MAPPER_COLOR_DREAMS:
      Result := TMapperColorDreams.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_GXROM:
      Result := TMapperGxrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC5:
      Result := TMapperMmc5.Create(Prg, Chr, HasChrRam, MirrorMode, Battery);
    MAPPER_BANDAI_FCG:
      Result := TMapperBandai.Create(False, Prg, Chr, HasChrRam, MirrorMode, MapperId, Submapper);
    MAPPER_BANDAI_159:
      Result := TMapperBandai.Create(True, Prg, Chr, HasChrRam, MirrorMode, MapperId);
    MAPPER_JY_90,              //
    MAPPER_JY_209, MAPPER_JY_281, MAPPER_JY_282, MAPPER_JY_295, MAPPER_JY_358, MAPPER_JY_386, MAPPER_JY_387, MAPPER_JY_388, MAPPER_JY_397, MAPPER_JY_SC871115C:
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
    MAPPER_CPROM,              //
    MAPPER_MULTICART_15,       //
    MAPPER_BANDAI_70,          //
    MAPPER_NINA03,             //
    MAPPER_JALECO_87,          //
    MAPPER_NAMCO_118,          //
    MAPPER_VS_SYSTEM,          //
    MAPPER_DISCRETE_112,       //
    MAPPER_NINA_113,           //
    MAPPER_AGCI,               //
    MAPPER_BANDAI_152,         //
    MAPPER_NAMCO_154,          //
    MAPPER_ACTION52,           //
    MAPPER_DISCRETE_240,       //
    MAPPER_WAIXING_242,        //
    MAPPER_RETROUSB_DPCM_CART:
      Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader);
    MAPPER_BNROM_NINA001, MAPPER_IREM_G101, MAPPER_CAMERICA, MAPPER_CAMERICA_QUATTRO, MAPPER_DXROM:
      Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader, Submapper);
    MAPPER_MMC2,               //
    MAPPER_MMC4:
      Result := TMapperMmcLatch.Create(MapperId = MAPPER_MMC4, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3_12:
      if Submapper = 1 then
        Result := TMapperMagicCard.Create(MapperId, Submapper, Prg, Chr, MirrorMode)
      else
        Result := TMapperMmc3Variant.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3_91,            //
    MAPPER_TQROM,              //
    MAPPER_MMC3_245,           //
    MAPPER_MMC3_250:
      Result := TMapperMmc3Variant.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_VRC4A_VRC4C,        //
    MAPPER_VRC2_VRC4_27,       //
    MAPPER_VRC2_VRC4_183,      //
    MAPPER_WAIXING_252,        //
    MAPPER_VRC_830506C, MAPPER_VRC_YY840820C, MAPPER_VRC_KL06, MAPPER_VRC_FS306, MAPPER_VRC_J2020, MAPPER_VRC_J33C, MAPPER_VRC_9052, MAPPER_VRC_AD301, MAPPER_VRC_JC011, MAPPER_NTDEC_TH2131, MAPPER_JYV610, MAPPER_SUBOR_SANGOKUSHI, MAPPER_VRC_L1A16, MAPPER_VRC_YY841157C, MAPPER_VRC_DATACH_2IN1, MAPPER_VRC_900218, MAPPER_VRC_J3_C, MAPPER_VRC_AX40G, MAPPER_VRC4_253,           //
    MAPPER_TF1201,             //
    MAPPER_T230,               //
    MAPPER_VRC2A,              //
    MAPPER_VRC2B_VRC4E,        //
    MAPPER_VRC2C_VRC4B:
      Result := TMapperVrc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_DISCRETE_241:
      if Submapper = 1 then
        Result := TMapperPeLpc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper)
      else
        Result := TMapperExtendedDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
    MAPPER_WAIXING178:
      case Submapper of
        1:
          Result := TMapperGameinis.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
        2:
          Result := TMapperPeLpc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
        3:
          Result := TMapper178SolderPad.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
      else
        Result := TMapperExtendedDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, Submapper);
      end;
    MAPPER_SUNSOFT4:
      if Submapper = 1 then
        Result := TMapperSunsoftDcs.Create(Prg, Chr, HasChrRam, MirrorMode)
      else
        Result := TMapperSunsoft.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_FME7, MAPPER_BMC_831128C:
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

