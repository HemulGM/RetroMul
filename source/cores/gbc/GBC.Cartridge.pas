unit GBC.Cartridge;

interface

uses
  GB.Cartridge;

const
  AddressRAMSize: Integer = $0149;
  AddressTitleStart: Integer = $134;
  AddressTitleEnd: Integer = $143;
  AddressLocale: Integer = $14A;
  AddressROMSize: Integer = $148;
  AddressCartType: Integer = $0147;
  AddressLogoStart: Integer = $104;
  AddressLogoEnd: Integer = $0133;
  AddressHeaderChecksumExpected: Integer = $014D;
  AddressHeaderChecksumCalculatedStart: Integer = $0134;
  AddressHeaderChecksumCalculatedEnd: Integer = $014C;
  CartridgeHeaderSize = $150;
  AddressCGBFlag = $143;
  AddressNewLicensee = $144;
  AddressSGBFlag = $146;
  AddressOldLicensee = $14B;
  AddressVersion = $14C;
  AddressGlobalChecksum = $14E;

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

