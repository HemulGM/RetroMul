unit GB.Cartridge;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

type
  TCartridgeRegion = (Japanese, World, Unknown);

  EGBInvalidROM = class(Exception);

  TCartridgeType = record
    ID: Integer;
    Name: string;
    MapperType: string;
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

const
  NintendoLogo: array[0..47] of Byte = (
    $CE, $ED, $66, $66, $CC, $0D, $00, $0B, $03, $73, $00, $83, $00, $0C, $00, $0D,
    $00, $08, $11, $1F, $88, $89, $00, $0E, $DC, $CC, $6E, $E6, $DD, $DD, $D9, $99,
    $BB, $BB, $67, $63, $6E, $0E, $EC, $CC, $DD, $DC, $99, $9F, $BB, $B9, $33, $3E);

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
        Result.MapperType := 'ROM_ONLY';
      end;
    $01:
      begin
        Result.Name := 'MBC1';
        Result.MapperType := 'MBC1';
      end;
    $02:
      begin
        Result.Name := 'MBC1 + RAM';
        Result.MapperType := 'MBC1';
      end;
    $03:
      begin
        Result.Name := 'MBC1 + RAM + Battery';
        Result.MapperType := 'MBC1';
      end;
    $05:
      begin
        Result.Name := 'MBC2';
        Result.MapperType := 'MBC2';
      end;
    $06:
      begin
        Result.Name := 'MBC2 + Battery';
        Result.MapperType := 'MBC2';
      end;
    $08:
      begin
        Result.Name := 'ROM + RAM';
        Result.MapperType := 'ROM_ONLY';
      end;
    $09:
      begin
        Result.Name := 'ROM + RAM + Battery';
        Result.MapperType := 'ROM_ONLY';
      end;
    $0B:
      begin
        Result.Name := 'MMM01';
        Result.MapperType := 'MMM01';
      end;
    $0C:
      begin
        Result.Name := 'MMM01 + RAM';
        Result.MapperType := 'MMM01';
      end;
    $0D:
      begin
        Result.Name := 'MMM01 + RAM + Battery';
        Result.MapperType := 'MMM01';
      end;
    $0F:
      begin
        Result.Name := 'MBC3 + Timer + Battery';
        Result.MapperType := 'MBC3';
      end;
    $10:
      begin
        Result.Name := 'MBC3 + Timer + RAM + Battery';
        Result.MapperType := 'MBC3';
      end;
    $11:
      begin
        Result.Name := 'MBC3';
        Result.MapperType := 'MBC3';
      end;
    $12:
      begin
        Result.Name := 'MBC3 + RAM';
        Result.MapperType := 'MBC3';
      end;
    $13:
      begin
        Result.Name := 'MBC3 + RAM + Battery';
        Result.MapperType := 'MBC3';
      end;
    $19:
      begin
        Result.Name := 'MBC5';
        Result.MapperType := 'MBC5';
      end;
    $1A:
      begin
        Result.Name := 'MBC5 + RAM';
        Result.MapperType := 'MBC5';
      end;
    $1B:
      begin
        Result.Name := 'MBC5 + RAM + Battery';
        Result.MapperType := 'MBC5';
      end;
    $1C:
      begin
        Result.Name := 'MBC5 + Rumble';
        Result.MapperType := 'MBC5';
      end;
    $1D:
      begin
        Result.Name := 'MBC5 + Rumble + RAM';
        Result.MapperType := 'MBC5';
      end;
    $1E:
      begin
        Result.Name := 'MBC5 + Rumble + RAM + Battery';
        Result.MapperType := 'MBC5';
      end;
    $20:
      begin
        Result.Name := 'MBC6';
        Result.MapperType := 'MBC6';
      end;
    $22:
      begin
        Result.Name := 'MBC7 + Sensor + Rumble + RAM + Battery';
        Result.MapperType := 'MBC7';
      end;
    $FC:
      begin
        Result.Name := 'Pocket Camera';
        Result.MapperType := 'POCKET_CAMERA';
      end;
    $FD:
      begin
        Result.Name := 'Bandai TAMA5';
        Result.MapperType := 'TAMA5';
      end;
    $FE:
      begin
        Result.Name := 'HuC3';
        Result.MapperType := 'HuC3';
      end;
    $FF:
      begin
        Result.Name := 'HuC1 + RAM + Battery';
        Result.MapperType := 'HuC1';
      end;
  else
    Result.Name := 'Unknown ($' + IntToHex(Code, 2) + ')';
    Result.MapperType := 'UNKNOWN';
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
  FSupportsCGB := (FCGBFlag and $80) <> 0;
  FCGBOnly := (FCGBFlag and $C0) = $C0;
  if FSupportsCGB then
  begin
    FTitle := HeaderText(Data, AddressTitleStart, 15);
    FShortTitle := HeaderText(Data, AddressTitleStart, 11);
    FManufacturerCode := HeaderText(Data, $13F, 4);
  end
  else
  begin
    FTitle := HeaderText(Data, AddressTitleStart, 16);
    FShortTitle := FTitle;
  end;
  FOldLicenseeCode := Data[AddressOldLicensee];
  FNewLicenseeCode := HeaderText(Data, AddressNewLicensee, 2);
  FUsesNewLicenseeCode := FOldLicenseeCode = $33;
  if FUsesNewLicenseeCode then
    FLicenseeCode := FNewLicenseeCode
  else
    FLicenseeCode := IntToHex(FOldLicenseeCode, 2);
  FSGBFlag := Data[AddressSGBFlag];
  FSupportsSGB := (FSGBFlag = $03) and FUsesNewLicenseeCode;
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
  if FCartridgeType.MapperType = 'UNKNOWN' then
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
    FROMSizeBytes := FROMBanks * $4000;
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
  FLogoValid := CompareMem(@Data[AddressLogoStart], @NintendoLogo[0], SizeOf(NintendoLogo));
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
  if FCartridgeType.ID in [$05, $06] then
    Result := 256
  else
    Result := 0;
end;

end.

