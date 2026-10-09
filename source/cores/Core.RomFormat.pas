unit Core.RomFormat;

interface

uses
  System.Classes, System.SysUtils;

const
  ROM_SYSTEM_NES = 'nes';
  ROM_SYSTEM_GB = 'gb';
  ROM_SYSTEM_GBC = 'gbc';
  ROM_SYSTEM_MD = 'md';
  ROM_SYSTEM_SNES = 'snes';
  ROM_SYSTEM_NEOGEO = 'neogeo';
  ROM_FOLDER_MD = 'megadrive';

  // Uppercase IDs are persisted in snapshots and used by emulation workers.
  ROM_CORE_ID_NES = 'NES';
  ROM_CORE_ID_GB = 'GB';
  ROM_CORE_ID_GBC = 'GBC';
  ROM_CORE_ID_MD = 'MD';
  ROM_CORE_ID_SNES = 'SNES';
  ROM_CORE_ID_NEOGEO = 'NEOGEO';

const
  ROM_EXTENSION_NES = '.nes';
  ROM_EXTENSION_GB = '.gb';
  ROM_EXTENSION_GBC = '.gbc';
  ROM_EXTENSION_MD = '.md';
  ROM_EXTENSION_SMD = '.smd';
  ROM_EXTENSION_BIN = '.bin';
  ROM_EXTENSION_GEN = '.gen';
  ROM_EXTENSION_SFC = '.sfc';
  ROM_EXTENSION_SMC = '.smc';
  ROM_EXTENSION_SWC = '.swc';
  ROM_EXTENSION_FIG = '.fig';
  ROM_EXTENSION_GENERIC = '.rom';
  ROM_EXTENSION_ZIP = '.zip';
  ROM_EXTENSION_NEO = '.neo';

const
  ROM_MAX_SIZE = 64 * 1024 * 1024;

const
  ROM_COPIER_HEADER_SIZE = 512;
  ROM_COPIER_ALIGNMENT_MASK = ROM_COPIER_HEADER_SIZE * 2 - 1;
  SMD_BLOCK_SIZE = $4000;
  SMD_HALF_BLOCK_SIZE = SMD_BLOCK_SIZE div 2;
  ROM_SIGNATURE_PROBE_SIZE = ROM_COPIER_HEADER_SIZE + SMD_BLOCK_SIZE;

const
  NES_ROM_SIGNATURE: AnsiString = 'NES' + #$1A;
  NES_ROM_SIGNATURE_SIZE = 4;
  NES_ROM_HEADER_SIZE = 16;
  NES_ROM_TRAINER_SIZE = 512;
  NES_ROM_PRG_BANK_SIZE = $4000;
  NES_ROM_CHR_BANK_SIZE = $2000;
  NES_ROM_RAM_BANK_SIZE = $2000;

const
  MD_ROM_MAX_SIZE = 8 * 1024 * 1024;
  MD_ROM_SIGNATURE: AnsiString = 'SEGA';
  MD_SWAPPED_ROM_SIGNATURE: AnsiString = 'ESAG';
  MD_ROM_HEADER_OFFSET = $100;
  MD_ROM_ALTERNATE_HEADER_OFFSET = $200;
  MD_ROM_HEADER_SIZE = $100;
  MD_ROM_DOMESTIC_TITLE_OFFSET = $120;
  MD_ROM_OVERSEAS_TITLE_OFFSET = $150;
  MD_ROM_TITLE_SIZE = 48;
  MD_ROM_REGION_OFFSET = $1F0;
  MD_ROM_REGION_SIZE = 16;

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

const
  SNES_ROM_BANK_SIZE = $8000;
  SNES_ROM_EXTENDED_BASE = $400000;
  SNES_ROM_HEADER_OFFSET = $7FC0;
  SNES_ROM_METADATA_SIZE = $20;
  SNES_ROM_TITLE_SIZE = 21;
  SNES_ROM_MAP_MODE_OFFSET = $15;
  SNES_ROM_CARTRIDGE_TYPE_OFFSET = $16;
  SNES_ROM_SIZE_OFFSET = $17;
  SNES_ROM_RAM_SIZE_OFFSET = $18;
  SNES_ROM_REGION_OFFSET = $19;
  SNES_ROM_LICENSEE_OFFSET = $1A;
  SNES_ROM_CHECKSUM_COMPLEMENT_OFFSET = $1C;
  SNES_ROM_CHECKSUM_OFFSET = $1E;
  SNES_ROM_RESET_VECTOR_OFFSET = $3C;
  SNES_ROM_COPROCESSOR_SUBTYPE_OFFSET = -1;
  SNES_ROM_EXPANSION_RAM_SIZE_OFFSET = -3;
  SNES_ROM_PROBE_SIZE = SNES_ROM_EXTENDED_BASE + 2 * SNES_ROM_BANK_SIZE + ROM_COPIER_HEADER_SIZE;
  SNES_ROM_HEADER_BASES: array[0..7] of Integer = (
    0,
    ROM_COPIER_HEADER_SIZE,
    SNES_ROM_BANK_SIZE,
    SNES_ROM_BANK_SIZE + ROM_COPIER_HEADER_SIZE,
    SNES_ROM_EXTENDED_BASE,
    SNES_ROM_EXTENDED_BASE + ROM_COPIER_HEADER_SIZE,
    SNES_ROM_EXTENDED_BASE + SNES_ROM_BANK_SIZE,
    SNES_ROM_EXTENDED_BASE + SNES_ROM_BANK_SIZE + ROM_COPIER_HEADER_SIZE);

const
  NEOGEO_ZIP_ROM_SIGNATURE: AnsiString = 'PK' + #3 + #4;
  NEOGEO_ROM_SIGNATURE: AnsiString = 'NEO' + #1;
  NEOGEO_ROM_MAGIC_SIZE = 3;
  NEOGEO_ROM_HEADER_SIZE = $1000;
  NEOGEO_ROM_MAX_CONTAINER_SIZE = 256 * 1024 * 1024;
  NEOGEO_ROM_REGION_COUNT = 5;
  NEOGEO_ROM_REGION_SIZES_OFFSET = 4;
  NEOGEO_ROM_NAME_OFFSET = $30;
  NEOGEO_ROM_NAME_SIZE = 33;

type
  TRomSystem = (Unknown, NES, GB, GBC, MD, SNES, NeoGeo);

  TRomEncoding = (Native, SMD, ByteSwapped, SnesCopier);

  TRomFormatInfo = record
    System: TRomSystem;
    Encoding: TRomEncoding;
    function SystemId: string;
  end;

function RomSystemFromId(const SystemId: string): TRomSystem;

function RomSystemId(System: TRomSystem): string;

function RomSystemFolder(System: TRomSystem): string;

function RomExtensions(System: TRomSystem): TArray<string>;

function DetectRom(const Data: TBytes): TRomFormatInfo; overload;

function DetectRom(Stream: TStream): TRomFormatInfo; overload;

function ReadRomData(Stream: TStream): TBytes;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;

implementation

uses
  SNES.Cartridge;

{ TRomFormatInfo }

function TRomFormatInfo.SystemId: string;
begin
  Result := RomSystemId(System);
end;

function RomSystemFromId(const SystemId: string): TRomSystem;
begin
  for var System := TRomSystem.NES to TRomSystem.NeoGeo do
    if SameText(SystemId, RomSystemId(System)) or SameText(SystemId, RomSystemFolder(System)) then
      Exit(System);

  Result := TRomSystem.Unknown;
end;

function RomSystemFolder(System: TRomSystem): string;
begin
  if System = TRomSystem.MD then
    Result := ROM_FOLDER_MD
  else
    Result := RomSystemId(System);
end;

function RomExtensions(System: TRomSystem): TArray<string>;
begin
  case System of
    TRomSystem.NES:
      Result := [ROM_EXTENSION_NES];
    TRomSystem.GB:
      Result := [ROM_EXTENSION_GB];
    TRomSystem.GBC:
      Result := [ROM_EXTENSION_GBC];
    TRomSystem.MD:
      Result := [ROM_EXTENSION_SMD, ROM_EXTENSION_BIN, ROM_EXTENSION_GEN, ROM_EXTENSION_MD];
    TRomSystem.SNES:
      Result := [ROM_EXTENSION_SFC, ROM_EXTENSION_SMC, ROM_EXTENSION_SWC, ROM_EXTENSION_FIG];
    TRomSystem.NeoGeo:
      Result := [ROM_EXTENSION_ZIP, ROM_EXTENSION_NEO];
  else
    Result := nil;
  end;
end;

function RomSystemId(System: TRomSystem): string;
begin
  case System of
    TRomSystem.NES:
      Result := ROM_SYSTEM_NES;
    TRomSystem.GB:
      Result := ROM_SYSTEM_GB;
    TRomSystem.GBC:
      Result := ROM_SYSTEM_GBC;
    TRomSystem.MD:
      Result := ROM_SYSTEM_MD;
    TRomSystem.SNES:
      Result := ROM_SYSTEM_SNES;
    TRomSystem.NeoGeo:
      Result := ROM_SYSTEM_NEOGEO;
  else
    Result := '';
  end;
end;

function DetectRom(const Data: TBytes): TRomFormatInfo;

  function Signature(Offset: Integer; const Text: AnsiString): Boolean;
  begin
    Result := (Length(Data) >= Offset + Length(Text)) and
      CompareMem(@Data[Offset], PAnsiChar(Text), Length(Text));
  end;

begin
  Result := Default(TRomFormatInfo);
  if Signature(0, NEOGEO_ROM_SIGNATURE) or Signature(0, NEOGEO_ZIP_ROM_SIGNATURE) then
    Result.System := TRomSystem.NeoGeo
  else if Signature(0, NES_ROM_SIGNATURE) then
    Result.System := TRomSystem.NES
  else if (Length(Data) >= GB_ROM_HEADER_SIZE) and CompareMem(@Data[GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
  begin
    if Data[GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG] then
      Result.System := TRomSystem.GBC
    else
      Result.System := TRomSystem.GB;
  end
  else if Signature(MD_ROM_HEADER_OFFSET, MD_ROM_SIGNATURE) or Signature(MD_ROM_ALTERNATE_HEADER_OFFSET, MD_ROM_SIGNATURE) then
    Result.System := TRomSystem.MD
  else if Signature(MD_ROM_HEADER_OFFSET, MD_SWAPPED_ROM_SIGNATURE) or Signature(MD_ROM_ALTERNATE_HEADER_OFFSET, MD_SWAPPED_ROM_SIGNATURE) then
  begin
    Result.System := TRomSystem.MD;
    Result.Encoding := TRomEncoding.ByteSwapped;
  end
  else if (Length(Data) >= ROM_SIGNATURE_PROBE_SIZE) and
    (Data[ROM_COPIER_HEADER_SIZE + SMD_HALF_BLOCK_SIZE + MD_ROM_HEADER_OFFSET div 2] = Ord(MD_ROM_SIGNATURE[1])) and
    (Data[ROM_COPIER_HEADER_SIZE + MD_ROM_HEADER_OFFSET div 2] = Ord(MD_ROM_SIGNATURE[2])) and
    (Data[ROM_COPIER_HEADER_SIZE + SMD_HALF_BLOCK_SIZE + MD_ROM_HEADER_OFFSET div 2 + 1] = Ord(MD_ROM_SIGNATURE[3])) and
    (Data[ROM_COPIER_HEADER_SIZE + MD_ROM_HEADER_OFFSET div 2 + 1] = Ord(MD_ROM_SIGNATURE[4])) then
  begin
    Result.System := TRomSystem.MD;
    Result.Encoding := TRomEncoding.SMD;
  end
  else
  begin
    var Header: TSnesHeader;
    if DetectSnesHeader(Data, Header) then
    begin
      Result.System := TRomSystem.SNES;
      if Header.CopierSize <> 0 then
        Result.Encoding := TRomEncoding.SnesCopier;
    end;
  end;
end;

function DetectRom(Stream: TStream): TRomFormatInfo;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');

  var Position := Stream.Position;
  try
    var Data: TBytes;
    SetLength(Data, ROM_SIGNATURE_PROBE_SIZE);
    var Count := 0;
    while Count < Length(Data) do
    begin
      var Read := Stream.Read(Data[Count], Length(Data) - Count);
      if Read = 0 then
        Break;
      Inc(Count, Read);
    end;
    SetLength(Data, Count);
    Result := DetectRom(Data);
    // Keep the short signature read for existing systems. SNES has no leading
    // signature; ExHiROM stores its header past 4 MiB.
    if (Result.System = TRomSystem.Unknown) and (Count = ROM_SIGNATURE_PROBE_SIZE) then
    begin
      // Preserve the complete image's size residue for copier-prefix
      // detection when a large ROM is represented by a truncated probe.
      var ProbeSize := SNES_ROM_PROBE_SIZE;
      var Remaining := Stream.Size - Position;
      if Remaining > ProbeSize then
        Inc(ProbeSize, Integer((Remaining - ProbeSize) and ROM_COPIER_ALIGNMENT_MASK));
      SetLength(Data, ProbeSize);
      while Count < Length(Data) do
      begin
        var Read := Stream.Read(Data[Count], Length(Data) - Count);
        if Read = 0 then
          Break;
        Inc(Count, Read);
      end;
      SetLength(Data, Count);
      Result := DetectRom(Data);
    end;
  finally
    Stream.Position := Position;
  end;
end;

function ReadRomData(Stream: TStream): TBytes;
begin
  if Stream = nil then
    raise EArgumentNilException.Create('Stream');

  var Buffer: array[0..65535] of Byte;
  var Memory := TMemoryStream.Create;
  try
    while True do
    begin
      var Count := Stream.Read(Buffer, SizeOf(Buffer));
      if Count = 0 then
        Break;
      if Memory.Size + Count > ROM_MAX_SIZE then
        raise EReadError.Create('ROM exceeds 64 MiB');

      Memory.WriteBuffer(Buffer, Count);
    end;
    SetLength(Result, Memory.Size);
    if Length(Result) > 0 then
      Move(Memory.Memory^, Result[0], Length(Result));
  finally
    Memory.Free;
  end;
end;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;
begin
  Result := Copy(Data);
  if Format.Encoding = TRomEncoding.SnesCopier then
    Result := Copy(Data, ROM_COPIER_HEADER_SIZE, Length(Data) - ROM_COPIER_HEADER_SIZE)
  else if Format.Encoding = TRomEncoding.ByteSwapped then
  begin
    if Odd(Length(Result)) then
      raise EReadError.Create('Invalid byte-swapped ROM size');

    for var i := 0 to Length(Result) div 2 - 1 do
    begin
      Result[i * 2] := Data[i * 2 + 1];
      Result[i * 2 + 1] := Data[i * 2];
    end;
  end
  else if Format.Encoding = TRomEncoding.SMD then
  begin
    if ((Length(Data) - ROM_COPIER_HEADER_SIZE) mod SMD_BLOCK_SIZE <> 0) then
      raise EReadError.Create('Invalid SMD size');

    SetLength(Result, Length(Data) - ROM_COPIER_HEADER_SIZE);
    for var Block := 0 to Length(Result) div SMD_BLOCK_SIZE - 1 do
      for var i := 0 to SMD_HALF_BLOCK_SIZE - 1 do
      begin
        Result[Block * SMD_BLOCK_SIZE + i * 2] := Data[ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE + SMD_HALF_BLOCK_SIZE + i];
        Result[Block * SMD_BLOCK_SIZE + i * 2 + 1] := Data[ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE + i];
      end;
  end;
end;

end.

