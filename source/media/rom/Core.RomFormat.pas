unit Core.RomFormat;

interface

uses
  System.Classes, System.SysUtils, Core.Platforms;

const
  ROM_SYSTEM_ZX = 'zx';
  ROM_SYSTEM_NES = 'nes';
  ROM_SYSTEM_GB = 'gb';
  ROM_SYSTEM_GBC = 'gbc';
  ROM_SYSTEM_GBA = 'gba';
  ROM_SYSTEM_MD = 'md';
  ROM_SYSTEM_SEGACD = 'segacd';
  ROM_SYSTEM_SEGA32X = 'sega32x';
  ROM_SYSTEM_SG1000 = 'sg1000';
  ROM_SYSTEM_SC3000 = 'sc3000';
  ROM_SYSTEM_SF7000 = 'sf7000';
  ROM_SYSTEM_OMV = 'omv';
  ROM_SYSTEM_SMS = 'sms';
  ROM_SYSTEM_GG = 'gg';
  ROM_SYSTEM_GW = 'gw';
  ROM_SYSTEM_PCE = 'pce';
  ROM_SYSTEM_SGX = 'sgx';
  ROM_SYSTEM_PCECD = 'pcecd';
  ROM_SYSTEM_SNES = 'snes';
  ROM_SYSTEM_N64 = 'n64';
  ROM_SYSTEM_SATURN = 'saturn';
  ROM_SYSTEM_PS1 = 'ps1';
  ROM_SYSTEM_PS2 = 'ps2';
  ROM_SYSTEM_NEOGEO = 'neogeo';
  ROM_SYSTEM_NEOGEOCD = 'neogeocd';
  ROM_SYSTEM_NEOGEOAES = 'neogeoaes';
  ROM_SYSTEM_NGP = 'ngp';
  ROM_SYSTEM_NGPC = 'ngpc';
  ROM_SYSTEM_CPS1 = 'cps1';
  ROM_SYSTEM_CPS2 = 'cps2';
  ROM_SYSTEM_CPS3 = 'cps3';
  ROM_FOLDER_MD = 'megadrive';

  // Uppercase IDs are persisted in snapshots and used by emulation workers.
  ROM_CORE_ID_NES = 'NES';
  ROM_CORE_ID_GB = 'GB';
  ROM_CORE_ID_GBC = 'GBC';
  ROM_CORE_ID_GBA = 'GBA';
  ROM_CORE_ID_MD = 'MD';
  ROM_CORE_ID_SG1000 = 'SG1000';
  ROM_CORE_ID_SC3000 = 'SC3000';
  ROM_CORE_ID_SF7000 = 'SF7000';
  ROM_CORE_ID_OMV = 'OMV';
  ROM_CORE_ID_SMS = 'SMS';
  ROM_CORE_ID_GG = 'GG';
  ROM_CORE_ID_GW = 'GW';
  ROM_CORE_ID_PCE = 'PCE';
  ROM_CORE_ID_SGX = 'SGX';
  ROM_CORE_ID_PCECD = 'PCECD';
  ROM_CORE_ID_SNES = 'SNES';
  ROM_CORE_ID_N64 = 'N64';
  ROM_CORE_ID_SATURN = 'SATURN';
  ROM_CORE_ID_PS1 = 'PS1';
  ROM_CORE_ID_PS2 = 'PS2';
  ROM_CORE_ID_NEOGEO = 'NEOGEO';
  ROM_CORE_ID_NEOGEOCD = 'NEOGEOCD';

const
  ROM_EXTENSION_NES = '.nes';
  ROM_EXTENSION_GB = '.gb';
  ROM_EXTENSION_GBC = '.gbc';
  ROM_EXTENSION_GBA = '.gba';
  ROM_EXTENSION_GBX = '.gbx';
  ROM_EXTENSION_MD = '.md';
  ROM_EXTENSION_SG = '.sg';
  ROM_EXTENSION_SMS = '.sms';
  ROM_EXTENSION_GG = '.gg';
  ROM_EXTENSION_GW = '.gw';
  ROM_EXTENSION_PCE = '.pce';
  ROM_EXTENSION_SGX = '.sgx';
  ROM_EXTENSION_MGW = '.mgw';
  ROM_EXTENSION_SC = '.sc';
  ROM_EXTENSION_SF7 = '.sf7';
  ROM_EXTENSION_SF = '.sf';
  ROM_EXTENSION_DSK = '.dsk';
  ROM_EXTENSION_MV = '.mv';
  ROM_EXTENSION_SMD = '.smd';
  ROM_EXTENSION_BIN = '.bin';
  ROM_EXTENSION_GEN = '.gen';
  ROM_EXTENSION_Z64 = '.z64';
  ROM_EXTENSION_N64 = '.n64';
  ROM_EXTENSION_V64 = '.v64';
  ROM_EXTENSION_SFC = '.sfc';
  ROM_EXTENSION_SMC = '.smc';
  ROM_EXTENSION_SWC = '.swc';
  ROM_EXTENSION_FIG = '.fig';
  ROM_EXTENSION_GENERIC = '.rom';
  ROM_EXTENSION_ZIP = '.zip';
  ROM_EXTENSION_7Z = '.7z';
  ROM_EXTENSION_NEO = '.neo';
  ROM_EXTENSION_NGP = '.ngp';
  ROM_EXTENSION_NGPC = '.ngc';
  ROM_EXTENSION_CUE = '.cue';
  ROM_EXTENSION_ISO = '.iso';
  ROM_EXTENSION_CHD = '.chd';
  ROM_EXTENSION_EXE = '.exe';

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
  MD_ROM_MAX_SIZE = 64 * 1024 * 1024;
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
  TRomSystem = Core.Platforms.TRomSystem;

  TRomEncoding = (Native, SMD, ByteSwapped, SnesCopier, WordSwapped);

  TRomFormatInfo = record
    System: TRomSystem;
    Encoding: TRomEncoding;
    function SystemId: string;
  end;

function RomSystemFromId(const SystemId: string): TRomSystem;

function RomSystemId(System: TRomSystem): string;

function RomSystemFolder(System: TRomSystem): string;

type
  TGBXFooter = record
    Present: Boolean;
    Mapper: string;
    ROMSize, RAMSize, FooterSize, MinorVersion: Cardinal;
    Battery, Rumble, Timer: Boolean;
    Variables: array[0..7] of Cardinal;
  end;

// A signed but malformed/unsupported footer is an error, never a raw-ROM fallback.
function ReadGBXFooter(const Data: TBytes): TGBXFooter;

function RomExtensions(System: TRomSystem): TArray<string>;

function DetectRom(const Data: TBytes): TRomFormatInfo; overload;

function DetectRom(Stream: TStream): TRomFormatInfo; overload;

function ReadRomData(Stream: TStream): TBytes;

function NormalizeRom(const Data: TBytes; const Format: TRomFormatInfo): TBytes;

function IsMDRealtec(const Data: TBytes): Boolean;

implementation

uses
  SNES.Cartridge, GBA.Cartridge, CPS.RomSets;

function CPSSystem(Generation: TCPSGeneration): TRomSystem;
begin
  case Generation of
    TCPSGeneration.CPS1:
      Result := TRomSystem.CPS1;
    TCPSGeneration.CPS2:
      Result := TRomSystem.CPS2;
  else
    Result := TRomSystem.CPS3;
  end;
end;

function IsMDRealtec(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) <> $80000 then
    Exit;

  var Sum: Cardinal := 0;
  for var i := $200 div 2 to Length(Data) div 2 - 1 do
    Sum := (Sum + (Cardinal(Data[i * 2]) shl 8) + Data[i * 2 + 1]) and $FFFF;
  var Signature := (Cardinal(Data[$18E]) shl 24) or (Cardinal(Data[$18F]) shl 16) or Sum;
  Result := (Signature = $000006AB) or (Signature = $FFFFF863) or
    (Signature = $FFFF44FB) or (Signature = $0000C0CD);
end;

function TRomFormatInfo.SystemId: string;
begin
  Result := RomSystemId(System);
end;

function RomSystemFromId(const SystemId: string): TRomSystem;
begin
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(SystemId, Info) then
    Result := Info.System
  else
    Result := TRomSystem.Unknown;
end;

function RomSystemFolder(System: TRomSystem): string;
begin
  var Info: TPlatformInfo;
  TPlatformRegistry.Find(System, Info);
  Result := Info.Folder;
end;

function RomExtensions(System: TRomSystem): TArray<string>;
begin
  var Info: TPlatformInfo;
  TPlatformRegistry.Find(System, Info);
  Result := Copy(Info.Extensions);
end;

function RomSystemId(System: TRomSystem): string;
begin
  var Info: TPlatformInfo;
  TPlatformRegistry.Find(System, Info);
  Result := Info.Id;
end;

function ReadGBXFooter(const Data: TBytes): TGBXFooter;

  function BigEndian(Offset: Integer): Cardinal;
  begin
    Result := (Cardinal(Data[Offset]) shl 24) or (Cardinal(Data[Offset + 1]) shl 16) or
      (Cardinal(Data[Offset + 2]) shl 8) or Data[Offset + 3];
  end;

begin
  Result := Default(TGBXFooter);
  var Size := Length(Data);
  if (Size < 4) or not CompareMem(@Data[Size - 4], PAnsiChar(AnsiString('GBX!')), 4) then
    Exit;

  if Size < 64 then
    raise EReadError.Create('Truncated GBX footer');

  if BigEndian(Size - 12) <> 1 then
    raise EReadError.Create('Unsupported GBX major version');

  Result.FooterSize := BigEndian(Size - 16);
  if (Result.FooterSize < 64) or (Result.FooterSize > Cardinal(Size)) then
    raise EReadError.Create('Invalid GBX footer size');

  var Offset := Size - Integer(Result.FooterSize);
  Result.ROMSize := BigEndian(Offset + 8);
  Result.RAMSize := BigEndian(Offset + 12);
  if (Result.ROMSize < GB_ROM_BANK_SIZE) or (Result.ROMSize > GB_ROM_MAX_SIZE) or
    (Result.ROMSize mod GB_ROM_BANK_SIZE <> 0) or (Result.ROMSize <> Cardinal(Offset)) then
    raise EReadError.Create('Invalid GBX ROM size');

  if Result.RAMSize > $20000 then
    raise EReadError.Create('Unsupported GBX RAM size');

  if (Data[Offset + 4] > 1) or (Data[Offset + 5] > 1) or (Data[Offset + 6] > 1) then
    raise EReadError.Create('Invalid GBX cartridge flags');

  for var i := 0 to 3 do
    if Data[Offset + i] <> 0 then
      Result.Mapper := Result.Mapper + Char(Data[Offset + i]);
  if (Result.Mapper = 'MMM1') and (Result.ROMSize < GB_ROM_MIN_SIZE) then
    raise EReadError.Create('MMM01 needs at least two ROM banks');

  Result.Battery := Data[Offset + 4] = 1;
  Result.Rumble := Data[Offset + 5] = 1;
  Result.Timer := Data[Offset + 6] = 1;
  Result.MinorVersion := BigEndian(Size - 8);
  for var i := 0 to 7 do
    Result.Variables[i] := BigEndian(Offset + 16 + i * 4);
  Result.Present := True;
end;

function DetectRom(const Data: TBytes): TRomFormatInfo;

  function Signature(Offset: Integer; const Text: AnsiString): Boolean;
  begin
    Result := (Length(Data) >= Offset + Length(Text)) and
      CompareMem(@Data[Offset], PAnsiChar(Text), Length(Text));
  end;

begin
  Result := Default(TRomFormatInfo);
  if (Length(Data) >= $40) and (Length(Data) <= $400000) and
    (Signature(0, 'COPYRIGHT BY SNK CORPORATION') or Signature(0, ' LICENSED BY SNK CORPORATION')) and
    (Data[$23] in [$00, $10]) then
  begin
    Result.System := TRomSystem.NeoGeoPocket;
    if Data[$23] = $10 then
      Result.System := TRomSystem.NeoGeoPocketColor;
    Exit;
  end;

  // PlayStation executables (PS-X EXE header).
  if (Length(Data) >= $800) and Signature(0, 'PS-X EXE') then
  begin
    Result.System := TRomSystem.PS1;
    Exit;
  end;

  // Retail Saturn BIOS reset vectors. Identification is independent of filenames.
  if (Length(Data) >= 16) and Signature(0, AnsiString(#$20#$00#$02#$00#$06#$00#$20#$00#$20#$00#$02#$00#$06#$00#$20#$00)) then
  begin
    Result.System := TRomSystem.Saturn;
    Exit;
  end;

  for var Offset in [$1FF0, $3FF0, $7FF0] do
    for var Header in [0, ROM_COPIER_HEADER_SIZE] do
      if Signature(Offset + Header, 'TMR SEGA') and
        (Length(Data) > Offset + Header + 15) and
        ((Data[Offset + Header + 15] shr 4) in [3, 4, 5, 6, 7]) then
      begin
        Result.System := TRomSystem.SMS;
        if Data[Offset + Header + 15] shr 4 >= 5 then
          Result.System := TRomSystem.GameGear;
        Exit;
      end;

  if Length(Data) >= 64 then
  begin
    var N64Signature := (Cardinal(Data[0]) shl 24) or (Cardinal(Data[1]) shl 16) or
      (Cardinal(Data[2]) shl 8) or Data[3];
    if (N64Signature = $80371240) or (N64Signature = $37804012) or (N64Signature = $40123780) then
    begin
      Result.System := TRomSystem.N64;
      if N64Signature = $37804012 then
        Result.Encoding := TRomEncoding.ByteSwapped
      else if N64Signature = $40123780 then
        Result.Encoding := TRomEncoding.WordSwapped;
      Exit;
    end;
  end;

  var GBX := ReadGBXFooter(Data);
  if GBX.Present then
  begin
    Result.System := TRomSystem.GB;
    var Header := 0;
    if GBX.Mapper = 'MMM1' then
      Header := Integer(GBX.ROMSize) - $8000;
    if Data[Header + GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG] then
      Result.System := TRomSystem.GBC;
    Exit;
  end;

  if Signature(0, NEOGEO_ROM_SIGNATURE) or Signature(0, NEOGEO_ZIP_ROM_SIGNATURE) then
  begin
    Result.System := TRomSystem.NeoGeo;
    if Signature(0, NEOGEO_ZIP_ROM_SIGNATURE) then
    begin
      var Input := TBytesStream.Create(Data);
      try
        var CPSSet: TCPSRomSet;
        if TCPSRomSet.IdentifyStream(Input, '', CPSSet) then
          Result.System := CPSSystem(CPSSet.Generation);
      finally
        Input.Free;
      end;
    end;
  end
  else if IsGBAROM(Data) then
    Result.System := TRomSystem.GBA
  else if Signature(0, NES_ROM_SIGNATURE) then
    Result.System := TRomSystem.NES
  else if (Length(Data) >= GB_ROM_HEADER_SIZE) and CompareMem(@Data[GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
  begin
    if Data[GB_ROM_CGB_FLAG_OFFSET] in [GB_ROM_CGB_SUPPORTED_FLAG, GB_ROM_CGB_ONLY_FLAG] then
      Result.System := TRomSystem.GBC
    else
      Result.System := TRomSystem.GB;
  end
  else if (Length(Data) >= GB_ROM_MIN_SIZE) and
    (Data[Length(Data) - $8000 + GB_ROM_CARTRIDGE_TYPE_OFFSET] in [$0B..$0D]) and
    CompareMem(@Data[Length(Data) - $8000 + GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
    Result.System := TRomSystem.GB
  else if Signature(MD_ROM_HEADER_OFFSET, MD_ROM_SIGNATURE) or Signature(MD_ROM_ALTERNATE_HEADER_OFFSET, MD_ROM_SIGNATURE) or IsMDRealtec(Data) then
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
    if (Position = 0) and (Stream.Size >= 4) then
    begin
      var Magic: Cardinal;
      Stream.ReadBuffer(Magic, 4);
      Stream.Position := Position;
      if Magic = $04034B50 then
      begin
        var CPSSet: TCPSRomSet;
        if TCPSRomSet.IdentifyStream(Stream, '', CPSSet) then
        begin
          Result := Default(TRomFormatInfo);
          Result.System := CPSSystem(CPSSet.Generation);
          Exit;
        end;
      end;
    end;

    var Data: TBytes;
    if Stream.Size - Position >= 4 then
    begin
      var SignatureBytes: array[0..3] of AnsiChar;
      Stream.Position := Stream.Size - 4;
      Stream.ReadBuffer(SignatureBytes, SizeOf(SignatureBytes));
      Stream.Position := Position;
      if CompareMem(@SignatureBytes[0], PAnsiChar(AnsiString('GBX!')), 4) then
        Exit(DetectRom(ReadRomData(Stream)));
    end;

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
  if Format.System = TRomSystem.N64 then
    if (Length(Data) < $1000) or (Length(Data) > ROM_MAX_SIZE) or ((Length(Data) and 3) <> 0) then
      raise EReadError.Create('Invalid N64 ROM size');

  if Format.Encoding = TRomEncoding.WordSwapped then
  begin
    if (Length(Data) and 3) <> 0 then
      raise EReadError.Create('Invalid word-swapped ROM size');

    for var i := 0 to Length(Data) div 4 - 1 do
      for var j := 0 to 3 do
        Result[i * 4 + j] := Data[i * 4 + 3 - j];
  end
  else if Format.Encoding = TRomEncoding.SnesCopier then
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

