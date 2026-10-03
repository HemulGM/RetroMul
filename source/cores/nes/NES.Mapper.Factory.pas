unit NES.Mapper.Factory;

interface

uses
  NES.Types, NES.Mapper;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False; Submapper: Integer = 0): TMapper;

implementation

uses
  NES.Mapper.Nrom, NES.Mapper.Mmc1, NES.Mapper.Uxrom, NES.Mapper.Cnrom,
  NES.Mapper.Mmc3, NES.Mapper.Axrom, NES.Mapper.Gxrom, NES.Mapper.ColorDreams,
  NES.Mapper.Discrete, NES.Mapper.MmcLatch, NES.Mapper.Mmc3Variants,
  NES.Mapper.Vrc, NES.Mapper.Sunsoft, NES.Mapper.Rambo, NES.Mapper.Cony,
  NES.Mapper.Bandai, NES.Mapper.Jy, NES.Mapper.Mmc5, NES.Mapper.Subor,
  NES.Mapper.Warface;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean; Submapper: Integer): TMapper;
begin
  case MapperId of
    MAPPER_NROM:
      Result := TMapperNrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC1:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode);
    155: // NES 2.0/iNES mapper 155 identifies MMC1A, with RAM permanently enabled.
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode, True);
    MAPPER_UXROM:
      Result := TMapperUxrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper = 2);
    MAPPER_CNROM:
      Result := TMapperCnrom.Create(Prg, Chr, HasChrRam, MirrorMode, Submapper <> 1, LegacyHeader);
    MAPPER_MMC3:
      Result := TMapperMmc3.Create(Prg, Chr, HasChrRam, MirrorMode);
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
    MAPPER_VRC2A,              //
    MAPPER_VRC2B_VRC4E,        //
    MAPPER_VRC2C_VRC4B:
      Result := TMapperVrc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
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

