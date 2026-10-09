unit GBC.Cartridge;

interface

uses
  Core.RomFormat, GB.Cartridge;

const
  AddressRAMSize: Integer = GB_ROM_RAM_SIZE_OFFSET;
  AddressTitleStart: Integer = GB_ROM_TITLE_OFFSET;
  AddressTitleEnd: Integer = GB_ROM_CGB_FLAG_OFFSET;
  AddressLocale: Integer = GB_ROM_DESTINATION_OFFSET;
  AddressROMSize: Integer = GB_ROM_SIZE_OFFSET;
  AddressCartType: Integer = GB_ROM_CARTRIDGE_TYPE_OFFSET;
  AddressLogoStart: Integer = GB_ROM_LOGO_OFFSET;
  AddressLogoEnd: Integer = GB_ROM_TITLE_OFFSET - 1;
  AddressHeaderChecksumExpected: Integer = GB_ROM_HEADER_CHECKSUM_OFFSET;
  AddressHeaderChecksumCalculatedStart: Integer = GB_ROM_TITLE_OFFSET;
  AddressHeaderChecksumCalculatedEnd: Integer = GB_ROM_HEADER_CHECKSUM_OFFSET - 1;
  CartridgeHeaderSize = GB_ROM_HEADER_SIZE;
  AddressCGBFlag = GB_ROM_CGB_FLAG_OFFSET;
  AddressNewLicensee = GB_ROM_NEW_LICENSEE_OFFSET;
  AddressSGBFlag = GB_ROM_SGB_FLAG_OFFSET;
  AddressOldLicensee = GB_ROM_OLD_LICENSEE_OFFSET;
  AddressVersion = GB_ROM_VERSION_OFFSET;
  AddressGlobalChecksum = GB_ROM_GLOBAL_CHECKSUM_OFFSET;

type
  TMapperType = GB.Cartridge.TMapperType;

  TCartridgeRegion = GB.Cartridge.TCartridgeRegion;

  TCartridgeType = GB.Cartridge.TCartridgeType;

  TCartridgeIssue = GB.Cartridge.TCartridgeIssue;

  TCartridgeIssues = GB.Cartridge.TCartridgeIssues;

  EGBCInvalidROM = GB.Cartridge.EGBInvalidROM;

  TGBCCartridge = GB.Cartridge.TGBCartridge;

implementation

end.

