unit GB.Cartridge;

interface

uses
  System.SysUtils, GB.RomFormat;

{$SCOPEDENUMS ON}

const
  ROM_CORE_ID_GB = 'GB';
  ROM_CORE_ID_GBC = 'GBC';

const
  GB_ROM_HEADER_SIZE = $150;
  GB_ROM_LOGO_OFFSET = $104;
  GB_ROM_CGB_FLAG_OFFSET = $143;
  GB_ROM_CGB_SUPPORTED_FLAG = $80;
  GB_ROM_CGB_ONLY_FLAG = $C0;
  GB_ROM_MIN_SIZE = $8000;
  GB_ROM_MAX_SIZE = 8 * 1024 * 1024;
  GB_ROM_BANK_SIZE = $4000;
  GB_ROM_TITLE_OFFSET = $134;
  GB_ROM_TITLE_SIZE = 16;
  GB_ROM_CGB_TITLE_SIZE = 15;
  GB_ROM_CGB_SHORT_TITLE_SIZE = 11;
  GB_ROM_MANUFACTURER_OFFSET = $13F;
  GB_ROM_MANUFACTURER_SIZE = 4;
  GB_ROM_NEW_LICENSEE_OFFSET = $144;
  GB_ROM_NEW_LICENSEE_SIZE = 2;
  GB_ROM_NEW_LICENSEE_FLAG = $33;
  GB_ROM_SGB_FLAG_OFFSET = $146;
  GB_ROM_SGB_SUPPORTED_FLAG = $03;
  GB_ROM_CARTRIDGE_TYPE_OFFSET = $147;
  GB_ROM_SIZE_OFFSET = $148;
  GB_ROM_RAM_SIZE_OFFSET = $149;
  GB_ROM_DESTINATION_OFFSET = $14A;
  GB_ROM_OLD_LICENSEE_OFFSET = $14B;
  GB_ROM_VERSION_OFFSET = $14C;
  GB_ROM_HEADER_CHECKSUM_OFFSET = $14D;
  GB_ROM_GLOBAL_CHECKSUM_OFFSET = $14E;
  GB_ROM_LOGO: array[0..47] of Byte = (
    $CE, $ED, $66, $66, $CC, $0D, $00, $0B, $03, $73, $00, $83,
    $00, $0C, $00, $0D, $00, $08, $11, $1F, $88, $89, $00, $0E,
    $DC, $CC, $6E, $E6, $DD, $DD, $D9, $99, $BB, $BB, $67, $63,
    $6E, $0E, $EC, $CC, $DD, $DC, $99, $9F, $BB, $B9, $33, $3E);

type
  // Header-recognized families; recognition does not imply emulation support.
  TMapperType = (
    Unknown, ROMOnly, MBC1, MBC2, MBC3, MBC5, MBC6, MBC7,
    MMM01, PocketCamera, TAMA5, HuC1, HuC3, MBC1M, MBC30, M161, WisdomTree);

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
    constructor Create(const Data: TBytes; HeaderOffset: Integer = 0);
    class function DecodeCartridgeType(Code: Byte): TCartridgeType; static;
    procedure ApplyGBX(const Footer: TGBXFooter);
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

constructor TGBCartridge.Create(const Data: TBytes; HeaderOffset: Integer);
begin
  inherited Create;
  if (HeaderOffset < 0) or (HeaderOffset > Length(Data) - CartridgeHeaderSize) then
    raise EGBInvalidROM.CreateFmt('ROM is too short: %d bytes; header requires %d.', [Length(Data), CartridgeHeaderSize]);

  FActualROMSize := Length(Data);
  FCGBFlag := Data[HeaderOffset + AddressCGBFlag];
  FSupportsCGB := (FCGBFlag and GB_ROM_CGB_SUPPORTED_FLAG) <> 0;
  FCGBOnly := (FCGBFlag and GB_ROM_CGB_ONLY_FLAG) = GB_ROM_CGB_ONLY_FLAG;
  if FSupportsCGB then
  begin
    FTitle := HeaderText(Data, HeaderOffset + AddressTitleStart, GB_ROM_CGB_TITLE_SIZE);
    FShortTitle := HeaderText(Data, HeaderOffset + AddressTitleStart, GB_ROM_CGB_SHORT_TITLE_SIZE);
    FManufacturerCode := HeaderText(Data, HeaderOffset + GB_ROM_MANUFACTURER_OFFSET, GB_ROM_MANUFACTURER_SIZE);
  end
  else
  begin
    FTitle := HeaderText(Data, HeaderOffset + AddressTitleStart, GB_ROM_TITLE_SIZE);
    FShortTitle := FTitle;
  end;
  FOldLicenseeCode := Data[HeaderOffset + AddressOldLicensee];
  FNewLicenseeCode := HeaderText(Data, HeaderOffset + AddressNewLicensee, GB_ROM_NEW_LICENSEE_SIZE);
  FUsesNewLicenseeCode := FOldLicenseeCode = GB_ROM_NEW_LICENSEE_FLAG;
  if FUsesNewLicenseeCode then
    FLicenseeCode := FNewLicenseeCode
  else
    FLicenseeCode := IntToHex(FOldLicenseeCode, 2);
  FSGBFlag := Data[HeaderOffset + AddressSGBFlag];
  FSupportsSGB := (FSGBFlag = GB_ROM_SGB_SUPPORTED_FLAG) and FUsesNewLicenseeCode;
  FVersion := Data[HeaderOffset + AddressVersion];
  FDestinationCode := Data[HeaderOffset + AddressLocale];
  case FDestinationCode of
    0:
      FDestination := TCartridgeRegion.Japanese;
    1:
      FDestination := TCartridgeRegion.World;
  else
    FDestination := TCartridgeRegion.Unknown;
    Include(FIssues, TCartridgeIssue.UnknownDestination);
  end;
  FCartridgeType := DecodeCartridgeType(Data[HeaderOffset + AddressCartType]);
  if FCartridgeType.MapperType = TMapperType.Unknown then
    Include(FIssues, TCartridgeIssue.UnknownCartridgeType);
  FROMSizeCode := Data[HeaderOffset + AddressROMSize];
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
  FRAMSizeCode := Data[HeaderOffset + AddressRAMSize];
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
  case FCartridgeType.MapperType of
    TMapperType.MBC1:
      if (Length(Data) >= $44000) and
        CompareMem(@Data[$104], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) and
        CompareMem(@Data[$40104], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
      begin
        FCartridgeType.MapperType := TMapperType.MBC1M;
        FCartridgeType.Name := 'MBC1M multicart';
      end;
    TMapperType.MBC3:
      if (FCartridgeType.ID = $10) and (FTitle = 'TETRIS SET') then
      begin
        FCartridgeType.MapperType := TMapperType.M161;
        FCartridgeType.Name := 'M161 multicart';
        FCartridgeType.HasRAM := False;
        FCartridgeType.HasBattery := False;
        FCartridgeType.HasTimer := False;
      end
      else if (FRAMSizeBytes > $8000) or (Length(Data) > $200000) then
      begin
        FCartridgeType.MapperType := TMapperType.MBC30;
        FCartridgeType.Name := 'MBC30';
      end;
    TMapperType.ROMOnly:
      if (Length(Data) > $8000) and (Data[$14D] = $E7) then
      begin
        var EmptyHeader := True;
        for var i := $134 to $14B do
          EmptyHeader := EmptyHeader and (Data[i] = 0);
        for var i := $F0 to $FF do
          EmptyHeader := EmptyHeader and (Data[i] = 0);
        if EmptyHeader then
          for var i := $300 to Length(Data) - 11 do
            if (Data[i] = Ord('W')) and
              (HeaderText(Data, i, 6) = 'WISDOM') and
              (HeaderText(Data, i + 7, 4) = 'TREE') then
            begin
              FCartridgeType.MapperType := TMapperType.WisdomTree;
              FCartridgeType.Name := 'Wisdom Tree';
              Break;
            end;
      end;
  end;
  FLogoValid := CompareMem(@Data[HeaderOffset + AddressLogoStart], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO));
  if not FLogoValid then
    Include(FIssues, TCartridgeIssue.InvalidLogo);
  var Checksum: Integer := 0;
  for var i := AddressHeaderChecksumCalculatedStart to AddressHeaderChecksumCalculatedEnd do
    Checksum := (Checksum - Data[HeaderOffset + i] - 1) and $FF;
  FCalculatedHeaderChecksum := Checksum;
  FHeaderChecksum := Data[HeaderOffset + AddressHeaderChecksumExpected];
  if not HeaderChecksumValid then
    Include(FIssues, TCartridgeIssue.HeaderChecksum);
  Checksum := 0;
  for var i: NativeInt := 0 to High(Data) do
    if (i <> HeaderOffset + AddressGlobalChecksum) and (i <> HeaderOffset + AddressGlobalChecksum + 1) then
      Checksum := (Checksum + Data[i]) and $FFFF;
  FCalculatedGlobalChecksum := Checksum;
  FGlobalChecksum := (Word(Data[HeaderOffset + AddressGlobalChecksum]) shl 8) or Data[HeaderOffset + AddressGlobalChecksum + 1];
  if not GlobalChecksumValid then
    Include(FIssues, TCartridgeIssue.GlobalChecksum);
end;

procedure TGBCartridge.ApplyGBX(const Footer: TGBXFooter);
begin
  if not Footer.Present then
    Exit;

  var Kind := TMapperType.Unknown;
  if Footer.Mapper = 'ROM' then
    Kind := TMapperType.ROMOnly
  else if Footer.Mapper = 'MBC1' then
    Kind := TMapperType.MBC1
  else if Footer.Mapper = 'MB1M' then
    Kind := TMapperType.MBC1M
  else if Footer.Mapper = 'MBC2' then
    Kind := TMapperType.MBC2
  else if Footer.Mapper = 'MBC3' then
  begin
    Kind := TMapperType.MBC3;
    if (Footer.RAMSize > $8000) or (Footer.ROMSize > $200000) then
      Kind := TMapperType.MBC30;
  end
  else if Footer.Mapper = 'MBC5' then
    Kind := TMapperType.MBC5
  else if Footer.Mapper = 'MBC6' then
    Kind := TMapperType.MBC6
  else if Footer.Mapper = 'MBC7' then
    Kind := TMapperType.MBC7
  else if Footer.Mapper = 'MMM1' then
    Kind := TMapperType.MMM01
  else if Footer.Mapper = 'M161' then
    Kind := TMapperType.M161
  else if Footer.Mapper = 'HUC1' then
    Kind := TMapperType.HuC1
  else if Footer.Mapper = 'HUC3' then
    Kind := TMapperType.HuC3
  else if Footer.Mapper = 'CAMR' then
    Kind := TMapperType.PocketCamera
  else if Footer.Mapper = 'WISD' then
    Kind := TMapperType.WisdomTree;
  if Kind = TMapperType.Unknown then
    raise ENotSupportedException.Create('Unsupported GBX mapper: ' + Footer.Mapper);

  FCartridgeType := Default(TCartridgeType);
  FCartridgeType.ID := -1;
  FCartridgeType.Name := 'GBX ' + Footer.Mapper;
  FCartridgeType.MapperType := Kind;
  FCartridgeType.HasRAM := Footer.RAMSize > 0;
  FCartridgeType.HasBattery := Footer.Battery;
  FCartridgeType.HasRumble := Footer.Rumble;
  FCartridgeType.HasTimer := Footer.Timer and (Kind in [TMapperType.MBC3, TMapperType.MBC30, TMapperType.HuC3]);
  FCartridgeType.HasAccelerometer := Kind = TMapperType.MBC7;
  FROMSizeBytes := Footer.ROMSize;
  FROMBanks := FROMSizeBytes div GB_ROM_BANK_SIZE;
  FRAMSizeBytes := Footer.RAMSize;
  FRAMBanks := (FRAMSizeBytes + $1FFF) div $2000;
  FIssues := FIssues - [TCartridgeIssue.UnknownCartridgeType, TCartridgeIssue.UnknownROMSize,
      TCartridgeIssue.UnknownRAMSize, TCartridgeIssue.ROMSizeMismatch];
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

