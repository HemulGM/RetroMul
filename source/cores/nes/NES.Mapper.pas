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
  MAPPER_CHINA_ER_SAN2 = 532;
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
  MAPPER_MALEE2 = 55;
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
  MAPPER_BLAZEPRO = 468;
  MAPPER_BLAZEPRO_FDS = 469;
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
  MAPPER_JY043 = 122;
  MAPPER_SUPER_GAME_MEGA = 124;
  MAPPER_STUDY_BOX = 186;
  MAPPER_COOLGIRL = 342;
  MAPPER_UM6578 = 405;
  MAPPER_UM6578_ABL = 600;
  MAPPER_UM6578_JUNGLETAC = 601;
  MAPPER_SUBOR_SB2000 = 602;
  MAPPER_MMC3_123 = 123;
  MAPPER_LH32 = 125;
  MAPPER_MMC3_126 = 126;
  MAPPER_DOUBLE_DRAGON_PIRATE = 127;
  MAPPER_T262_LEGACY = 128;
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
  MAPPER_YUXING = 169;
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
  MAPPER_JY_281 = 281;
  MAPPER_JY_282 = 282;
  MAPPER_JY_295 = 295;
  MAPPER_JY_358 = 358;
  MAPPER_JY_386 = 386;
  MAPPER_JY_387 = 387;
  MAPPER_JY_388 = 388;
  MAPPER_00202650 = 392;
  MAPPER_820720C = 393;
  MAPPER_HSK007 = 394;
  MAPPER_JY_397 = 397;
  MAPPER_JY_CHESS_550 = 550;
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
  MAPPER_GAMES_XPLOSION = 269;
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
  MAPPER_NTDEC_TH2131 = 308;
  MAPPER_LH51 = 309;
  MAPPER_KAISER7013_B = 312;
  MAPPER_RESET_TXROM = 313;
  MAPPER_BMC64IN1_NO_REPEAT = 314;
  MAPPER_BMC830134_C = 315;
  MAPPER_HP898F = 319;
  MAPPER_BMC830425_C4391_T = 320;
  MAPPER_BMC820310 = 321;
  MAPPER_BMC_K3033 = 322;
  MAPPER_FARID_SLROM = 323;
  MAPPER_FARID_UNROM = 324;
  MAPPER_MMC3_MALI_SB = 325;
  MAPPER_CONTRA_PIRATE = 326;
  MAPPER_BMC_10_24_C_A1 = 327;
  MAPPER_RT01 = 328;
  MAPPER_EDU2000 = 329;
  MAPPER_SANGOKUSHI_NAMCOT = 330;
  MAPPER_BMC12IN1 = 331;
  MAPPER_SUPER40IN1_WS = 332;
  MAPPER_BMC8IN1 = 333;
  MAPPER_BMC_5IN1_1993 = 334;
  MAPPER_BMC_K3046 = 336;
  MAPPER_CTC09 = 335;
  MAPPER_CTC12IN1 = 337;
  MAPPER_TJ03 = 341;
  MAPPER_I030_0365 = 343;
  MAPPER_SA005A = 338;
  MAPPER_BMC891227 = 350;
  MAPPER_TECHLINE_XB = 351;
  MAPPER_FAM250 = 354;
  MAPPER_3D_BLOCK_PIC = 355;
  MAPPER_P3150 = 360;
  MAPPER_MGC002 = 297;
  MAPPER_N49C300 = 369;
  MAPPER_BIT_P3117 = 357;
  MAPPER_SACHEN_89433 = 403;
  MAPPER_LIKO_429 = 429;
  MAPPER_BMC_K3071 = 438;
  MAPPER_RCM_DS9 = 452;
  MAPPER_IMPACT_SOFT_IM1 = 471;
  MAPPER_GAMESTAR_CM9309 = 461;
  MAPPER_BMC_830947 = 472;
  MAPPER_RETROAD_KJ01A = 473;
  MAPPER_BMC_820215CA2 = 475;
  MAPPER_ESTIQUE = 484;
  MAPPER_YHC_UNROM = 500;
  MAPPER_YHC_AXROM = 501;
  MAPPER_YHC_MULTICART = 502;
  MAPPER_A971210 = 420;
  MAPPER_NTDEC_N625836 = 455;
  MAPPER_LITTLECOM160 = 541;
  MAPPER_SUBOR_KARAOKE = 514;
  MAPPER_FAMILY_NORAEBANG = 515;
  MAPPER_KKACHI_KARAOKE = 517;
  MAPPER_CH501 = 543;
  MAPPER_MULTICART_375 = 375;
  MAPPER_KN42 = 381;
  MAPPER_BMC830928C = 382;
  MAPPER_BMC_K3006 = 339;
  MAPPER_BMC_GN26 = 344;
  MAPPER_BMC_L6IN1 = 345;
  MAPPER_KAISER7012 = 346;
  MAPPER_BMC830118_C = 348;
  MAPPER_BMC_G146 = 349;
  MAPPER_YY841101C = 361;
  MAPPER_BMC_GN45 = 366;
  MAPPER_BMC_K3097 = 367;
  MAPPER_BMC_SFC12 = 372;
  MAPPER_BMC_SFC13 = 373;
  MAPPER_RESET_SLROM = 374;
  MAPPER_MULTICART_380 = 380;
  MAPPER_BMC_BS110 = 391;
  MAPPER_YY850437C = 396;
  MAPPER_BATMAP = 399;
  MAPPER_8BIT_XMAS_2017 = 400;
  MAPPER_BMC_VIP19 = 401;
  MAPPER_IMPACT_SOFT_406 = 406;
  MAPPER_DG574B = 445;
  MAPPER_MINDKIDS_FPGA = 446;
  MAPPER_HARATYLER = 451;
  MAPPER_BMC_810706_LEGACY = 762;
  MAPPER_RETROUSB_DPCM_CART = 409;
  MAPPER_BATMAP_SRRX = 413;
  MAPPER_FK206 = 412;
  MAPPER_JY_SC871115C = 421;
  MAPPER_TEC9719 = 422;
  MAPPER_MULTICART_428 = 428;
  MAPPER_BMC_831031C = 430;
  MAPPER_REALTEC_MMC3 = 432;
  MAPPER_NC20MB = 433;
  MAPPER_S009 = 434;
  MAPPER_F1002 = 435;
  MAPPER_YS2309 = 439;
  MAPPER_BMC_840415C = 441;
  MAPPER_NC7000M = 444;
  MAPPER_SUPER_GAMES_KING = 449;
  MAPPER_BMC_810431C = 457;
  MAPPER_BMC_GN23 = 458;
  MAPPER_BMC_FC2940 = 460;
  MAPPER_BMC_47_2 = 467;
  MAPPER_INX_007T = 470;
  MAPPER_SUBOR_045N = 481;
  MAPPER_MULTICART_487 = 487;
  MAPPER_MAXIVISION_NTDEC = 493;
  MAPPER_BMC_ST80 = 545;
  MAPPER_BMC_631601 = 294;
  MAPPER_BMC_810305C = 353;
  MAPPER_F600 = 370;
  MAPPER_REALTEC_8210 = 395;
  MAPPER_JY208 = 356;
  MAPPER_YY841155C = 376;
  MAPPER_YY840708C = 383;
  MAPPER_JY012005 = 404;
  MAPPER_JY302 = 410;
  MAPPER_A88S1 = 411;
  MAPPER_REALTEC_K6C3001A = 456;
  MAPPER_COOLX_LITE = 479;
  MAPPER_VRC_830506C = 362;
  MAPPER_VRC_YY840820C = 398;
  MAPPER_VRC_KL06 = 447;
  MAPPER_VRC_830768C = 448;
  MAPPER_VRC_FS306 = 544;
  MAPPER_TELETUBBIES_420 = 237;
  MAPPER_BMC_EL861121C = 267;
  MAPPER_OK043 = 239;
  MAPPER_BMC_09078 = 277;
  MAPPER_BMC_P3127_01 = 279;
  MAPPER_BMC_JY104 = 316;
  MAPPER_BMC_810344C = 317;
  MAPPER_BTL_UT1245A = 318;
  MAPPER_BMC_K3017 = 280;
  MAPPER_NEWSTAR_12IN1 = 293;
  MAPPER_BMC_K1053 = 310;
  MAPPER_BMC_SQ002 = 378;
  MAPPER_BMC_35BH1 = 379;
  MAPPER_NTDEC_2779 = 385;
  MAPPER_BMC_K3036 = 340;
  MAPPER_BMC_5069 = 363;
  MAPPER_CALTRON_9IN1 = 389;
  MAPPER_REALTEC_8031 = 390;
  MAPPER_BMC_J2282 = 402;
  MAPPER_BMC_9999999IN1 = 414;
  MAPPER_BMC_TH2348 = 437;
  MAPPER_REALTEC_8042 = 453;
  MAPPER_BMC_ET89 = 454;
  MAPPER_BMC_NT639 = 291;
  MAPPER_BMC_JY830832C = 364;
  MAPPER_NC3000M = 443;
  MAPPER_BMC_VQ168 = 459;
  MAPPER_BMC_971107_00G = 462;
  MAPPER_BMC_YH810X1 = 463;
  MAPPER_NTDEC_9012 = 464;
  MAPPER_BMC_ET120 = 465;
  MAPPER_KEYBYTE_COMPUTER = 466;
  MAPPER_NTDEC_N625231 = 474;
  MAPPER_BMC_WE7HGX = 478;
  MAPPER_BMC_480 = 480;
  MAPPER_BMC_K3101 = 490;
  MAPPER_BMC_ET170 = 503;
  MAPPER_BMC_K3054 = 504;
  MAPPER_BMC_5426757A = 505;
  MAPPER_BMC_GA009 = 506;
  MAPPER_BMC_A018 = 507;
  MAPPER_BMC_CG008 = 508;
  MAPPER_BMC_K3022 = 509;
  MAPPER_NTDEC_15IN1 = 477;
  MAPPER_BMC_K1079 = 482;
  MAPPER_BMC_3927 = 483;
  MAPPER_BMC_0359 = 485;
  MAPPER_BMC_HC001 = 488;
  MAPPER_BMC_N80 = 489;
  MAPPER_SANE_TING_5IN1 = 491;
  MAPPER_BMC_K3069 = 492;
  MAPPER_BMC_CH512K = 494;
  MAPPER_BMC_K3011 = 498;
  MAPPER_BMC_FC41 = 499;
  MAPPER_BMC_FC53A = 510;
  MAPPER_BMC_1N4148 = 511;
  MAPPER_SACHEN_TC032 = 512;
  MAPPER_COCOMA = 516;
  MAPPER_BMC_831128C = 528;
  MAPPER_SACHEN_3014 = 533;
  MAPPER_BMC_N42S2 = 536;
  MAPPER_KAISER_KS7030 = 347;
  MAPPER_BMC_SB5013 = 359;
  MAPPER_YUNG_08 = 368;
  MAPPER_LUCKY_RABBIT = 415;
  MAPPER_SMB2J_4IN1 = 416;
  MAPPER_FINE_STUDIO = 417;
  MAPPER_WHIRLWIND_LH42 = 418;
  MAPPER_KAISER_KS7021A = 525;
  MAPPER_BJ56 = 526;
  MAPPER_WHIRLWIND_LH53 = 535;
  MAPPER_BMC_JY4M4 = 537;
  MAPPER_SUPER_SOCCER_CHAMPION = 538;
  MAPPER_PALTHENA = 539;
  MAPPER_82112C = 540;
  MAPPER_JYV610 = 542;
  MAPPER_CTC15 = 548;
  MAPPER_KAISER_KS7016B = 549;
  MAPPER_SACHEN_3013 = 553;
  MAPPER_KAISER_KS7010 = 554;
  MAPPER_C88DIP = 556;
  MAPPER_NTDEC_2718 = 557;
  MAPPER_SUBOR_SANGOKUSHI = 559;
  MAPPER_BMC_03101 = 546;
  MAPPER_SUPER_GAME_DOCTOR = 561;
  MAPPER_TURBO_GAME_DOCTOR = 562;
  MAPPER_VRC_J2020 = 563;
  MAPPER_BMC_BD23 = 564;
  MAPPER_VRC_J33C = 565;
  MAPPER_VRC_9052 = 570;
  MAPPER_VRC_JC011 = 571;
  MAPPER_BMC_5068 = 573;
  MAPPER_BMC_FC40 = 574;
  MAPPER_BMC_W03 = 575;
  MAPPER_BMC_J2096 = 576;
  MAPPER_BMC_KN20 = 577;
  MAPPER_BMC_T215 = 579;
  MAPPER_BMC_ET156 = 580;
  MAPPER_BMC_ET82 = 581;
  MAPPER_BMC_8203 = 583;
  MAPPER_BMC_ST32 = 584;
  MAPPER_BMC_FE011 = 585;
  MAPPER_BMC_HN02 = 586;
  MAPPER_BMC_K3057 = 587;
  MAPPER_BMC_ET81 = 588;
  MAPPER_BMC_810706 = 589;
  MAPPER_BMC_810430 = 590;
  MAPPER_BMC_07027 = 591;
  MAPPER_BMC_J2054 = 592;
  MAPPER_MCAFE_E1 = 593;
  MAPPER_RINCO_TALKMAN = 594;
  MAPPER_4MROM512 = 595;
  MAPPER_BMC_NT319 = 613;
  MAPPER_BMC_ET149 = 566;
  MAPPER_BMC_TOP_TEN = 567;
  MAPPER_BMC_T227 = 568;
  MAPPER_BMC_820315C = 569;
  MAPPER_BMC_F648 = 572;
  MAPPER_BMC_910610 = 578;
  MAPPER_NTDEC_A9778 = 582;
  MAPPER_BMC_FC49 = 596;
  MAPPER_BMC_GN27 = 597;
  MAPPER_BMC_K3044 = 616;
  MAPPER_VRC_AD301 = 617;
  MAPPER_BMC_NS32 = 618;
  MAPPER_BMC_4782 = 620;
  MAPPER_PREDATOR_C806 = 621;
  MAPPER_BMC_K3021 = 598;
  MAPPER_BMC_ET133A = 599;
  MAPPER_BMC_J2061 = 603;
  MAPPER_BMC_TX5_8IN1 = 605;
  MAPPER_BMC_T4IN1 = 606;
  MAPPER_BMC_4705 = 607;
  MAPPER_BMC_A23 = 608;
  MAPPER_BMC_63100 = 609;
  MAPPER_BMC_J2042 = 610;
  MAPPER_BMC_T124 = 611;
  MAPPER_BMC_K3004 = 612;
  MAPPER_BMC_9135 = 614;
  MAPPER_BMC_LB12IN1 = 615;
  MAPPER_BMC_68IN1 = 619;
  MAPPER_BMC_3945 = 622;
  MAPPER_BMC_J2083 = 623;
  MAPPER_BMC_KL09B = 624;
  MAPPER_BMC_ET20 = 625;
  MAPPER_BMC_90IN1 = 626;
  MAPPER_BMC_821134 = 627;
  MAPPER_BMC_GC004 = 628;
  MAPPER_MGC026 = 271;
  MAPPER_J2012_II = 272;
  MAPPER_RESET_NROM256 = 352;
  MAPPER_BMC_EL860947C = 377;
  MAPPER_VRC_L1A16 = 384;
  MAPPER_VRC_YY841157C = 450;
  MAPPER_VRC_DATACH_2IN1 = 520;
  MAPPER_NESTICLE_MMC3 = 100;
  MAPPER_SMB2J_311 = 311;
  MAPPER_CROAKY_KARAOKE = 476;
  MAPPER_JNCOTA_KT1005 = 523;
  MAPPER_ONEBUS = 256;
  MAPPER_VT32 = 296;
  MAPPER_VT369_4150 = 423;
  MAPPER_VT369_411E = 424;
  MAPPER_VT369_41E6 = 425;
  MAPPER_VT369_SERIAL_ROM = 426;
  MAPPER_VT369_INVERTER_ROM = 427;
  MAPPER_VT389 = 496;
  MAPPER_WIN_LOSE_OR_DRAW = 407;
  MAPPER_ARCADE_ADVANCED = 408;
  MAPPER_TAIKEE_ADPCM = 419;
  MAPPER_ZLX08 = 436;
  MAPPER_PEC586 = 257;
  MAPPER_VT42XX = 270;
  MAPPER_ASDER_PC95 = 365;
  MAPPER_LITTLE_KIM_PC95 = 531;
  MAPPER_MEGASONIC_PEC586 = 371;
  MAPPER_SONIC_REC9388 = 440;
  MAPPER_GOLDEN_KEY = 442;
  MAPPER_VRC_J3_C = 273;
  MAPPER_KAISER_KS7009 = 486;
  MAPPER_N46 = 495;
  MAPPER_SUBOR_LOGO = 497;
  MAPPER_JINGKETAI = 551;
  MAPPER_WAIXING558 = 558;
  MAPPER_CE_BASIC = 560;
  MAPPER_VRC_900218 = 524;
  MAPPER_VRC_AX40G = 527;
  MAPPER_SACHEN_9602 = 513;
  MAPPER_DANCE2000 = 518;
  MAPPER_DANCING_EXPERT = 604;
  MAPPER_EH8813_A = 519;
  MAPPER_DREAM_TECH01 = 521;
  MAPPER_LH10 = 522;
  MAPPER_T230 = 529;
  MAPPER_AX5705 = 530;
  MAPPER_ING022 = 534;
  MAPPER_KONAMI_QTA = 547;
  MAPPER_TAITO_X1017_552 = 552;
  MAPPER_NES_EVENT2 = 555;
  MAPPER_RAINBOW = 682;
  MAPPER_HOMEBREW_800 = 800;
  MAPPER_RAINBOW_NROM = 3840;
  MAPPER_RAINBOW512 = 3870;
  MAPPER_RAINBOW_PROTO = 3871;
  MAPPER_RAINBOW13 = 3872;
  MAPPER_WARFACE = 3914;
  MAPPER_BMC_3927_ARCHIVAL = 3927;

type
  TMirrorMode = (Horizontal, Vertical, Single0, Single1, FourScreen);

  TPpuBusReadObserver = procedure(Address: UInt16) of object;

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
    // Cartridge registers with read side effects can supply a debugger value here.
    function CpuPeek(Address: UInt16; out Value: UInt8): Boolean; virtual;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function CpuWriteTimed(Address: UInt16; Value: UInt8; CpuCycle: UInt64): Boolean; virtual;
    function PpuRead(Address: UInt16; out Value: UInt8): Boolean; virtual; abstract;
    function PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean; virtual;
    function PpuReadContext(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean = False): Boolean;
    function PpuWrite(Address: UInt16; Value: UInt8): Boolean; virtual; abstract;
    function GetMirrorMode: TMirrorMode; virtual; abstract;
    function NameTableOffset(Address: UInt16): UInt16; virtual;
    function UsesPpuAddressBus: Boolean; virtual;
    procedure ClockPpuAddress(Address: UInt16; PpuCycle: UInt64); virtual;
    procedure SetRegion(Region: TNesRegion); virtual;
    procedure ClockCpu; virtual;
    // External CPU address observed once per bus cycle, including DMA.
    procedure ClockCpuBus(Address: UInt16); virtual;
    procedure ClockCpuWrite; virtual;
    procedure ClockPpuRead; virtual;
    procedure ObservePpuBusRead(Address: UInt16); virtual;
    function PpuBusReadObserver: TPpuBusReadObserver;
    function HasPpuClockCallbacks(out HasReadCallback: Boolean): Boolean;
    function HasPpuRenderCallbacks: Boolean;
    // Opt in only when repeated PPU reads/fetch context have no side effects.
    function AllowsPpuReadCaching: Boolean; virtual;
    // Opt in only if PpuRead never depends on rendering/sprite context.
    function AllowsDirectPpuRead: Boolean; virtual;
    procedure ClockScanline(Line: Integer; Rendering: Boolean); virtual;
    procedure SetPpuFetchKind(Sprite: Boolean; X, Y: Integer); virtual;
    procedure SetPpuControl(Value: UInt8); virtual;
    function IrqPending: Boolean; virtual;
    function ExpansionAudio: Double; virtual;
    procedure CpuRamWrite(Address: UInt16; Value: UInt8); virtual;
    function ConsumeDacWrite(out Value: UInt8): Boolean; virtual;
    procedure CpuIoRead(Address: UInt16; Value: UInt8); virtual;
    procedure CpuIoWrite(Address: UInt16; Value: UInt8); virtual;
    procedure SetPpuSpriteIndex(Index: Integer); virtual;
    procedure PowerOn; virtual;
    procedure Reset; virtual; abstract;
  end;

implementation

procedure TMapper.PowerOn;
begin
  Reset;
end;

function TMapper.PpuPeek(Address: UInt16; Rendering: Boolean; out Value: UInt8; Sprite: Boolean): Boolean;
begin
  Result := PpuReadContext(Address, Rendering, Value, Sprite);
end;

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

function TMapper.NameTableOffset(Address: UInt16): UInt16;
begin
  var Index := Address and $0FFF;
  case GetMirrorMode of
    TMirrorMode.Horizontal:
      Result := ((Index shr 1) and $400) or (Index and $3FF);
    TMirrorMode.Single0:
      Result := Index and $3FF;
    TMirrorMode.Single1:
      Result := $400 or (Index and $3FF);
    TMirrorMode.FourScreen:
      Result := Index;
  else
    Result := Index and $7FF;
  end;
end;

procedure TMapper.CpuIoRead(Address: UInt16; Value: UInt8);
begin
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

function TMapper.CpuPeek(Address: UInt16; out Value: UInt8): Boolean;
begin
  Result := False;
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

function TMapper.AllowsDirectPpuRead: Boolean;
begin
  Result := False;
end;

function TMapper.HasPpuClockCallbacks(out HasReadCallback: Boolean): Boolean;
type
  TAddressCallback = procedure(Address: UInt16; PpuCycle: UInt64) of object;

  TReadCallback = procedure of object;
var
  AddressCallback: TAddressCallback;
  ReadCallback: TReadCallback;
begin
  AddressCallback := ClockPpuAddress;
  ReadCallback := ClockPpuRead;
  HasReadCallback := TMethod(ReadCallback).Code <> @TMapper.ClockPpuRead;
  Result := (TMethod(AddressCallback).Code <> @TMapper.ClockPpuAddress) or HasReadCallback;
end;

function TMapper.HasPpuRenderCallbacks: Boolean;
type
  TFetchCallback = procedure(Sprite: Boolean; X, Y: Integer) of object;

  TSpriteCallback = procedure(Index: Integer) of object;
var
  FetchCallback: TFetchCallback;
  SpriteCallback: TSpriteCallback;
begin
  FetchCallback := SetPpuFetchKind;
  SpriteCallback := SetPpuSpriteIndex;
  Result := (TMethod(FetchCallback).Code <> @TMapper.SetPpuFetchKind) or
    (TMethod(SpriteCallback).Code <> @TMapper.SetPpuSpriteIndex);
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

procedure TMapper.ClockCpuBus(Address: UInt16);
begin
end;

procedure TMapper.ClockCpuWrite;
begin
end;

function TMapper.PpuBusReadObserver: TPpuBusReadObserver;
begin
  Result := ObservePpuBusRead;
  if TMethod(Result).Code = @TMapper.ObservePpuBusRead then
    Result := nil;
end;

procedure TMapper.ObservePpuBusRead(Address: UInt16);
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

function TMapper.UsesPpuAddressBus: Boolean;
begin
  Result := False;
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

