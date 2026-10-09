unit GB.Cartridge;

interface

uses
  System.SysUtils, Core.RomFormat;

{$SCOPEDENUMS ON}

type
  // Header-recognized families; recognition does not imply emulation support.
  TMapperType = (
    Unknown, ROMOnly, MBC1, MBC2, MBC3, MBC5, MBC6,
    MBC7, MMM01, PocketCamera, TAMA5, HuC1, HuC3);

  TCartridgeRegion = (Japanese, World, Unknown);

  EGBInvalidROM = class(Exception);

  TCartridgeType = record
    ID: Integer;
    Name: string;
    MapperType: TMapperType;
    HasRAM: Boolean; // External RAM as indicated by the cartridge type.
    HasBattery: Boolean;
    HasTimer: Boolean;
    HasRumble: Boolean;
    HasAccelerometer: Boolean;
  end;

  TCartridgeIssue = (
    InvalidLogo, HeaderChecksum, GlobalChecksum, UnknownCartridgeType,
    UnknownROMSize, UnknownRAMSize, ROMSizeMismatch, UnknownDestination);

  TCartridgeIssues = set of TCartridgeIssue;

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
  TGBCartridge = class
  private
    FTitle, FShortTitle, FManufacturerCode: string;
    FNewLicenseeCode, FLicenseeCode: string;
    FCartridgeType: TCartridgeType;
    FDestination: TCartridgeRegion;
    FCGBFlag, FSGBFlag, FDestinationCode, FVersion: Byte;
    FOldLicenseeCode, FROMSizeCode, FRAMSizeCode: Byte;
    FROMSizeBytes, FRAMSizeBytes, FROMBanks, FRAMBanks: Integer;
    FActualROMSize: NativeInt;
    FHeaderChecksum, FCalculatedHeaderChecksum: Byte;
    FGlobalChecksum, FCalculatedGlobalChecksum: Word;
    FLogoValid, FSupportsCGB, FCGBOnly, FSupportsSGB: Boolean;
    FUsesNewLicenseeCode: Boolean;
    FIssues: TCartridgeIssues;
    function GetHeaderChecksumValid: Boolean;
    function GetGlobalChecksumValid: Boolean;
    function GetInternalRAMSizeBytes: Integer;
  public
    constructor Create(const Data: TBytes);
    class function DecodeCartridgeType(Code: Byte): TCartridgeType; static;
    // CGB headers have overlapping 15-character and 11+4 layouts. No flag
    // identifies the layout: preserve both interpretations instead of guessing.
    property Title: string read FTitle;
    property ShortTitle: string read FShortTitle;
    property ManufacturerCode: string read FManufacturerCode;
    property CartridgeType: TCartridgeType read FCartridgeType;
    property Destination: TCartridgeRegion read FDestination;
    property DestinationCode: Byte read FDestinationCode;
    property CGBFlag: Byte read FCGBFlag;
    property SGBFlag: Byte read FSGBFlag;
    property SupportsCGB: Boolean read FSupportsCGB;
    property CGBOnly: Boolean read FCGBOnly;
    property SupportsSGB: Boolean read FSupportsSGB;
    property Version: Byte read FVersion;
    property OldLicenseeCode: Byte read FOldLicenseeCode;
    property NewLicenseeCode: string read FNewLicenseeCode;
    property UsesNewLicenseeCode: Boolean read FUsesNewLicenseeCode;
    property LicenseeCode: string read FLicenseeCode;
    property ROMSizeCode: Byte read FROMSizeCode;
    property RAMSizeCode: Byte read FRAMSizeCode;
    // Unknown size codes return -1, not zero (which means no RAM).
    property ROMSizeBytes: Integer read FROMSizeBytes;
    property RAMSizeBytes: Integer read FRAMSizeBytes;
    property ROMBanks: Integer read FROMBanks;
    property RAMBanks: Integer read FRAMBanks;
    property ActualROMSize: NativeInt read FActualROMSize;
    // MBC2 has 512 four-bit cells, separate from the external RAM size field.
    property InternalRAMSizeBytes: Integer read GetInternalRAMSizeBytes;
    property LogoValid: Boolean read FLogoValid;
    property HeaderChecksum: Byte read FHeaderChecksum;
    property CalculatedHeaderChecksum: Byte read FCalculatedHeaderChecksum;
    property HeaderChecksumValid: Boolean read GetHeaderChecksumValid;
    property GlobalChecksum: Word read FGlobalChecksum;
    property CalculatedGlobalChecksum: Word read FCalculatedGlobalChecksum;
    property GlobalChecksumValid: Boolean read GetGlobalChecksumValid;
    property Issues: TCartridgeIssues read FIssues;
  end;

implementation

// Header format: https://gbdev.io/pandocs/The_Cartridge_Header.html

function HeaderText(const Data: TBytes; First, Count: Integer): string;
begin
  Result := '';
  for var i := First to First + Count - 1 do
  begin
    if Data[i] = 0 then
      Break;
    Result := Result + Char(Data[i]);
  end;
end;

class function TGBCartridge.DecodeCartridgeType(Code: Byte): TCartridgeType;
begin
  Result := Default(TCartridgeType);
  Result.ID := Code;
  case Code of
    $00:
      begin
        Result.Name := 'ROM Only';
        Result.MapperType := TMapperType.ROMOnly;
      end;
    $01:
      begin
        Result.Name := 'MBC1';
        Result.MapperType := TMapperType.MBC1;
      end;
    $02:
      begin
        Result.Name := 'MBC1 + RAM';
        Result.MapperType := TMapperType.MBC1;
      end;
    $03:
      begin
        Result.Name := 'MBC1 + RAM + Battery';
        Result.MapperType := TMapperType.MBC1;
      end;
    $05:
      begin
        Result.Name := 'MBC2';
        Result.MapperType := TMapperType.MBC2;
      end;
    $06:
      begin
        Result.Name := 'MBC2 + Battery';
        Result.MapperType := TMapperType.MBC2;
      end;
    $08:
      begin
        Result.Name := 'ROM + RAM';
        Result.MapperType := TMapperType.ROMOnly;
      end;
    $09:
      begin
        Result.Name := 'ROM + RAM + Battery';
        Result.MapperType := TMapperType.ROMOnly;
      end;
    $0B:
      begin
        Result.Name := 'MMM01';
        Result.MapperType := TMapperType.MMM01;
      end;
    $0C:
      begin
        Result.Name := 'MMM01 + RAM';
        Result.MapperType := TMapperType.MMM01;
      end;
    $0D:
      begin
        Result.Name := 'MMM01 + RAM + Battery';
        Result.MapperType := TMapperType.MMM01;
      end;
    $0F:
      begin
        Result.Name := 'MBC3 + Timer + Battery';
        Result.MapperType := TMapperType.MBC3;
      end;
    $10:
      begin
        Result.Name := 'MBC3 + Timer + RAM + Battery';
        Result.MapperType := TMapperType.MBC3;
      end;
    $11:
      begin
        Result.Name := 'MBC3';
        Result.MapperType := TMapperType.MBC3;
      end;
    $12:
      begin
        Result.Name := 'MBC3 + RAM';
        Result.MapperType := TMapperType.MBC3;
      end;
    $13:
      begin
        Result.Name := 'MBC3 + RAM + Battery';
        Result.MapperType := TMapperType.MBC3;
      end;
    $19:
      begin
        Result.Name := 'MBC5';
        Result.MapperType := TMapperType.MBC5;
      end;
    $1A:
      begin
        Result.Name := 'MBC5 + RAM';
        Result.MapperType := TMapperType.MBC5;
      end;
    $1B:
      begin
        Result.Name := 'MBC5 + RAM + Battery';
        Result.MapperType := TMapperType.MBC5;
      end;
    $1C:
      begin
        Result.Name := 'MBC5 + Rumble';
        Result.MapperType := TMapperType.MBC5;
      end;
    $1D:
      begin
        Result.Name := 'MBC5 + Rumble + RAM';
        Result.MapperType := TMapperType.MBC5;
      end;
    $1E:
      begin
        Result.Name := 'MBC5 + Rumble + RAM + Battery';
        Result.MapperType := TMapperType.MBC5;
      end;
    $20:
      begin
        Result.Name := 'MBC6';
        Result.MapperType := TMapperType.MBC6;
      end;
    $22:
      begin
        Result.Name := 'MBC7 + Sensor + Rumble + RAM + Battery';
        Result.MapperType := TMapperType.MBC7;
      end;
    $FC:
      begin
        Result.Name := 'Pocket Camera';
        Result.MapperType := TMapperType.PocketCamera;
      end;
    $FD:
      begin
        Result.Name := 'Bandai TAMA5';
        Result.MapperType := TMapperType.TAMA5;
      end;
    $FE:
      begin
        Result.Name := 'HuC3';
        Result.MapperType := TMapperType.HuC3;
      end;
    $FF:
      begin
        Result.Name := 'HuC1 + RAM + Battery';
        Result.MapperType := TMapperType.HuC1;
      end;
  else
    Result.Name := 'Unknown ($' + IntToHex(Code, 2) + ')';
    Result.MapperType := TMapperType.Unknown;
  end;
  Result.HasRAM := Code in [
      $02, $03, $08, $09, $0C, $0D, $10, $12, $13,
      $1A, $1B, $1D, $1E, $20, $22, $FC, $FE, $FF];
  Result.HasBattery := Code in [
      $03, $06, $09, $0D, $0F, $10, $13,
      $1B, $1E, $20, $22, $FC, $FD, $FE, $FF];
  Result.HasTimer := Code in [$0F, $10, $FD, $FE];
  Result.HasRumble := Code in [$1C, $1D, $1E, $22];
  Result.HasAccelerometer := Code = $22;
end;

constructor TGBCartridge.Create(const Data: TBytes);
begin
  inherited Create;
  if Length(Data) < CartridgeHeaderSize then
    raise EGBInvalidROM.CreateFmt('ROM is too short: %d bytes; header requires %d.', [Length(Data), CartridgeHeaderSize]);

  FActualROMSize := Length(Data);
  FCGBFlag := Data[AddressCGBFlag];
  FSupportsCGB := (FCGBFlag and GB_ROM_CGB_SUPPORTED_FLAG) <> 0;
  FCGBOnly := (FCGBFlag and GB_ROM_CGB_ONLY_FLAG) = GB_ROM_CGB_ONLY_FLAG;
  if FSupportsCGB then
  begin
    FTitle := HeaderText(Data, AddressTitleStart, GB_ROM_CGB_TITLE_SIZE);
    FShortTitle := HeaderText(Data, AddressTitleStart, GB_ROM_CGB_SHORT_TITLE_SIZE);
    FManufacturerCode := HeaderText(Data, GB_ROM_MANUFACTURER_OFFSET, GB_ROM_MANUFACTURER_SIZE);
  end
  else
  begin
    FTitle := HeaderText(Data, AddressTitleStart, GB_ROM_TITLE_SIZE);
    FShortTitle := FTitle;
  end;
  FOldLicenseeCode := Data[AddressOldLicensee];
  FNewLicenseeCode := HeaderText(Data, AddressNewLicensee, GB_ROM_NEW_LICENSEE_SIZE);
  FUsesNewLicenseeCode := FOldLicenseeCode = GB_ROM_NEW_LICENSEE_FLAG;
  if FUsesNewLicenseeCode then
    FLicenseeCode := FNewLicenseeCode
  else
    FLicenseeCode := IntToHex(FOldLicenseeCode, 2);
  FSGBFlag := Data[AddressSGBFlag];
  FSupportsSGB := (FSGBFlag = GB_ROM_SGB_SUPPORTED_FLAG) and FUsesNewLicenseeCode;
  FVersion := Data[AddressVersion];
  FDestinationCode := Data[AddressLocale];
  case FDestinationCode of
    0:
      FDestination := TCartridgeRegion.Japanese;
    1:
      FDestination := TCartridgeRegion.World;
  else
    FDestination := TCartridgeRegion.Unknown;
    Include(FIssues, TCartridgeIssue.UnknownDestination);
  end;
  FCartridgeType := DecodeCartridgeType(Data[AddressCartType]);
  if FCartridgeType.MapperType = TMapperType.Unknown then
    Include(FIssues, TCartridgeIssue.UnknownCartridgeType);
  FROMSizeCode := Data[AddressROMSize];
  case FROMSizeCode of
    $00..$08:
      FROMBanks := 2 shl FROMSizeCode;
    $52:  // Legacy codes, retained for compatibility with older ROM tools.
      FROMBanks := 72;
    $53:
      FROMBanks := 80;
    $54:
      FROMBanks := 96;
  else
    FROMBanks := -1;
    Include(FIssues, TCartridgeIssue.UnknownROMSize);
  end;
  FROMSizeBytes := -1;
  if FROMBanks > 0 then
  begin
    FROMSizeBytes := FROMBanks * GB_ROM_BANK_SIZE;
    if FROMSizeBytes <> FActualROMSize then
      Include(FIssues, TCartridgeIssue.ROMSizeMismatch);
  end;
  FRAMSizeCode := Data[AddressRAMSize];
  case FRAMSizeCode of
    0:
      FRAMSizeBytes := 0;
    1: // Legacy 2 KiB code, used by some homebrew.
      FRAMSizeBytes := $800;
    2:
      FRAMSizeBytes := $2000;
    3:
      FRAMSizeBytes := $8000;
    4:
      FRAMSizeBytes := $20000;
    5:
      FRAMSizeBytes := $10000;
  else
    FRAMSizeBytes := -1;
    Include(FIssues, TCartridgeIssue.UnknownRAMSize);
  end;
  if FRAMSizeBytes >= 0 then
    FRAMBanks := (FRAMSizeBytes + $1FFF) div $2000
  else
    FRAMBanks := -1;
  FLogoValid := CompareMem(@Data[AddressLogoStart], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO));
  if not FLogoValid then
    Include(FIssues, TCartridgeIssue.InvalidLogo);
  var Checksum: Integer := 0;
  for var i := AddressHeaderChecksumCalculatedStart to AddressHeaderChecksumCalculatedEnd do
    Checksum := (Checksum - Data[i] - 1) and $FF;
  FCalculatedHeaderChecksum := Checksum;
  FHeaderChecksum := Data[AddressHeaderChecksumExpected];
  if not HeaderChecksumValid then
    Include(FIssues, TCartridgeIssue.HeaderChecksum);
  Checksum := 0;
  for var i: NativeInt := 0 to High(Data) do
    if (i <> AddressGlobalChecksum) and (i <> AddressGlobalChecksum + 1) then
      Checksum := (Checksum + Data[i]) and $FFFF;
  FCalculatedGlobalChecksum := Checksum;
  FGlobalChecksum := (Word(Data[AddressGlobalChecksum]) shl 8) or Data[AddressGlobalChecksum + 1];
  if not GlobalChecksumValid then
    Include(FIssues, TCartridgeIssue.GlobalChecksum);
end;

function TGBCartridge.GetHeaderChecksumValid: Boolean;
begin
  Result := FHeaderChecksum = FCalculatedHeaderChecksum;
end;

function TGBCartridge.GetGlobalChecksumValid: Boolean;
begin
  Result := FGlobalChecksum = FCalculatedGlobalChecksum;
end;

function TGBCartridge.GetInternalRAMSizeBytes: Integer;
begin
  if FCartridgeType.MapperType = TMapperType.MBC2 then
    Result := 256
  else
    Result := 0;
end;

end.

