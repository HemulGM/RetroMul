unit NES.Mapper.Factory;

interface

uses
  NES.Types, NES.Mapper;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean = False): TMapper;

implementation

uses
  NES.Mapper.Nrom, NES.Mapper.Mmc1, NES.Mapper.Uxrom, NES.Mapper.Cnrom,
  NES.Mapper.Mmc3, NES.Mapper.Axrom, NES.Mapper.Gxrom, NES.Mapper.ColorDreams,
  NES.Mapper.Discrete, NES.Mapper.MmcLatch, NES.Mapper.Mmc3Variants,
  NES.Mapper.Vrc, NES.Mapper.Sunsoft, NES.Mapper.Rambo, NES.Mapper.Cony,
  NES.Mapper.Bandai, NES.Mapper.Jy, NES.Mapper.Mmc5, NES.Mapper.Subor;

function CreateMapper(MapperId: Integer; const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode; LegacyHeader: Boolean): TMapper;
begin
  case MapperId of
    MAPPER_NROM:
      Result := TMapperNrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC1:
      Result := TMapperMmc1.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_UXROM:
      Result := TMapperUxrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_CNROM:
      Result := TMapperCnrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3:
      Result := TMapperMmc3.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_AXROM:
      Result := TMapperAxrom.Create(Prg, Chr, HasChrRam);
    MAPPER_COLOR_DREAMS:
      Result := TMapperColorDreams.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_GXROM:
      Result := TMapperGxrom.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC5:
      Result := TMapperMmc5.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_BANDAI_FCG, MAPPER_BANDAI_159:
      Result := TMapperBandai.Create(MapperId = MAPPER_BANDAI_159, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_JY_90, MAPPER_JY_209:
      Result := TMapperJy.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_SUBOR:
      Result := TMapperSubor.Create(Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_FFE_F3XXX, MAPPER_CPROM, MAPPER_MULTICART_15, MAPPER_IREM_G101, MAPPER_BNROM_NINA001, MAPPER_BANDAI_70, MAPPER_CAMERICA, MAPPER_NINA03, MAPPER_JALECO_87, MAPPER_NAMCO_118, MAPPER_VS_SYSTEM, MAPPER_DISCRETE_112, MAPPER_NINA_113, MAPPER_AGCI, MAPPER_BANDAI_152, MAPPER_NAMCO_154, MAPPER_DXROM, MAPPER_ACTION52, MAPPER_CAMERICA_QUATTRO, MAPPER_DISCRETE_240, MAPPER_WAIXING_242:
      Result := TMapperDiscrete.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode, LegacyHeader);
    MAPPER_MMC2, MAPPER_MMC4:
      Result := TMapperMmcLatch.Create(MapperId = MAPPER_MMC4, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_MMC3_12, MAPPER_MMC3_91, MAPPER_TQROM, MAPPER_MMC3_245, MAPPER_MMC3_250:
      Result := TMapperMmc3Variant.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_VRC2A, MAPPER_VRC2B_VRC4E, MAPPER_VRC2C_VRC4B:
      Result := TMapperVrc.Create(MapperId, Prg, Chr, HasChrRam, MirrorMode);
    MAPPER_SUNSOFT4, MAPPER_FME7:
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

