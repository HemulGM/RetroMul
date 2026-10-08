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

const
  ROM_MAX_SIZE = 64 * 1024 * 1024;

const
  ROM_COPIER_HEADER_SIZE = 512;
  SMD_BLOCK_SIZE = $4000;
  SMD_HALF_BLOCK_SIZE = SMD_BLOCK_SIZE div 2;
  ROM_SIGNATURE_PROBE_SIZE = ROM_COPIER_HEADER_SIZE + SMD_BLOCK_SIZE;

const
  NES_ROM_SIGNATURE: AnsiString = 'NES' + #$1A;

const
  MD_ROM_MAX_SIZE = 8 * 1024 * 1024;
  MD_ROM_SIGNATURE: AnsiString = 'SEGA';
  MD_SWAPPED_ROM_SIGNATURE: AnsiString = 'ESAG';
  MD_ROM_HEADER_OFFSET = $100;
  MD_ROM_ALTERNATE_HEADER_OFFSET = $200;
  MD_ROM_HEADER_SIZE = $100;

const
  GB_ROM_HEADER_SIZE = $150;
  GB_ROM_LOGO_OFFSET = $104;
  GB_ROM_CGB_FLAG_OFFSET = $143;
  GB_ROM_LOGO: array[0..47] of Byte = ($CE, $ED, $66, $66, $CC, $0D, $00, $0B, $03, $73, $00, $83,
    $00, $0C, $00, $0D, $00, $08, $11, $1F, $88, $89, $00, $0E, $DC, $CC, $6E, $E6, $DD, $DD,
    $D9, $99, $BB, $BB, $67, $63, $6E, $0E, $EC, $CC, $DD, $DC, $99, $9F, $BB, $B9, $33, $3E);

const
  SNES_ROM_PROBE_SIZE = $410000 + ROM_COPIER_HEADER_SIZE;
  SNES_ROM_HEADER_BASES: array[0..7] of Integer = (
    0, ROM_COPIER_HEADER_SIZE,
    $8000, $8000 + ROM_COPIER_HEADER_SIZE,
    $400000, $400000 + ROM_COPIER_HEADER_SIZE,
    $408000, $408000 + ROM_COPIER_HEADER_SIZE);

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
      Result := ['.zip', '.neo'];
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
  if Signature(0, 'NEO' + #1) or Signature(0, 'PK' + #3 + #4) then
    Result.System := TRomSystem.NeoGeo
  else if Signature(0, NES_ROM_SIGNATURE) then
    Result.System := TRomSystem.NES
  else if (Length(Data) >= GB_ROM_HEADER_SIZE) and CompareMem(@Data[GB_ROM_LOGO_OFFSET], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
  begin
    if Data[GB_ROM_CGB_FLAG_OFFSET] in [$80, $C0] then
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
        Inc(ProbeSize, Integer((Remaining - ProbeSize) and $3FF));
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

