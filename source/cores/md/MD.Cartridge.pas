unit MD.Cartridge;

interface

uses
  System.SysUtils, System.Classes, MD.EEPROM;

const
  MD_ROM_COPIER_HEADER_SIZE = 512;

const
  ROM_CORE_ID_MD = 'MD';
  ROM_EXTENSION_MD = '.md';
  ROM_EXTENSION_SMD = '.smd';

const
  SMD_BLOCK_SIZE = $4000;
  SMD_HALF_BLOCK_SIZE = SMD_BLOCK_SIZE div 2;
  ROM_SIGNATURE_PROBE_SIZE = MD_ROM_COPIER_HEADER_SIZE + SMD_BLOCK_SIZE;

const
  MD_ROM_MAX_SIZE = 64 * 1024 * 1024;
  MD_ROM_SIGNATURE: AnsiString = 'SEGA';
  MD_ROM_HEADER_OFFSET = $100;
  MD_ROM_ALTERNATE_HEADER_OFFSET = $200;
  MD_ROM_HEADER_SIZE = $100;
  MD_ROM_DOMESTIC_TITLE_OFFSET = $120;
  MD_ROM_OVERSEAS_TITLE_OFFSET = $150;
  MD_ROM_TITLE_SIZE = 48;
  MD_ROM_REGION_OFFSET = $1F0;
  MD_ROM_REGION_SIZE = 16;

type
  EMDCartridge = class(Exception);

  TMDRegion = (Japan, USA, Europe);

  // ROM bytes are always in the 68000's big-endian bus order.
  TMDCartridge = class
  private
    FData: TBytes;
    FTitle: string;
    FRegion: TMDRegion;
    FHeaderOffset: Integer;
    FEEPROMConfig: TMDEEPROMConfig;
    FJCart: Boolean;
    F32X: Boolean;
    function HeaderText(Offset, Count: Integer): string;
  public
    constructor Create(const Data: TBytes; const Extension: string); overload;
    constructor Create(Stream: TStream); overload;
    constructor Create(const FileName: string); overload;
    function ReadByte(Address: Cardinal): Byte; inline;
    function ReadWord(Address: Cardinal): Word;
    property Data: TBytes read FData;
    property Title: string read FTitle;
    property Region: TMDRegion read FRegion;
    property EEPROMConfig: TMDEEPROMConfig read FEEPROMConfig;
    property JCart: Boolean read FJCart;
    property Is32X: Boolean read F32X;
  end;

implementation

uses
  Core.Storage, MD.RomFormat;

constructor TMDCartridge.Create(const FileName: string);
begin
  var Stream := TStorage.Default.OpenRead(FileName);
  try
    Create(Stream);
  finally
    Stream.Free;
  end;
end;

constructor TMDCartridge.Create(Stream: TStream);
begin
  var Bytes := ReadRomData(Stream);
  var Encoding: string;
  if not MD.RomFormat.TryDetectEncoding(Bytes, Encoding) then
    raise EMDCartridge.Create('Unrecognized Mega Drive ROM header');

  Create(MD.RomFormat.NormalizeImage(Bytes, Encoding), '');
end;

constructor TMDCartridge.Create(const Data: TBytes; const Extension: string);
begin
  inherited Create;
  FHeaderOffset := MD_ROM_HEADER_OFFSET;

  // Some collections label ordinary big-endian dumps as .smd. Trust the
  // cartridge signature before attempting the copier's interleaving format.
  if SameText(Extension, ROM_EXTENSION_SMD) and
    not ((Length(Data) >= MD_ROM_HEADER_OFFSET + MD_ROM_HEADER_SIZE) and
    CompareMem(@Data[MD_ROM_HEADER_OFFSET], PAnsiChar(MD_ROM_SIGNATURE), Length(MD_ROM_SIGNATURE))) then
  begin
    if (Length(Data) <= MD_ROM_COPIER_HEADER_SIZE) or
      ((Length(Data) - MD_ROM_COPIER_HEADER_SIZE) mod SMD_BLOCK_SIZE <> 0) or
      (Length(Data) > MD_ROM_MAX_SIZE + MD_ROM_COPIER_HEADER_SIZE) then
      raise EMDCartridge.Create('Invalid SMD size: expected a 512-byte header and 16 KiB blocks');

    SetLength(FData, Length(Data) - MD_ROM_COPIER_HEADER_SIZE);
    for var Block := 0 to Length(FData) div SMD_BLOCK_SIZE - 1 do
    begin
      var Source := MD_ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE;
      for var i := 0 to SMD_HALF_BLOCK_SIZE - 1 do
      begin
        FData[Block * SMD_BLOCK_SIZE + i * 2] := Data[Source + SMD_HALF_BLOCK_SIZE + i];
        FData[Block * SMD_BLOCK_SIZE + i * 2 + 1] := Data[Source + i];
      end;
    end;
  end
  else
    FData := Copy(Data);

  if (Length(FData) < MD_ROM_HEADER_OFFSET + MD_ROM_HEADER_SIZE) or
    (Length(FData) > MD_ROM_MAX_SIZE) or Odd(Length(FData)) then
    raise EMDCartridge.Create('Invalid Mega Drive ROM size');

  if (HeaderText(MD_ROM_HEADER_OFFSET, Length(MD_ROM_SIGNATURE)) <> string(MD_ROM_SIGNATURE)) and not MD.RomFormat.CheckImage(FData) then
  begin
    // Some early diagnostics retain the first 128 vector entries and
    // place the identification header at $200 (Charles MacDonald's itest).
    if (Length(FData) < MD_ROM_ALTERNATE_HEADER_OFFSET + MD_ROM_HEADER_SIZE) or
      (HeaderText(MD_ROM_ALTERNATE_HEADER_OFFSET, Length(MD_ROM_SIGNATURE)) <> string(MD_ROM_SIGNATURE)) then
      raise EMDCartridge.Create('Mega Drive ROM has no SEGA header at $100 or $200');

    FHeaderOffset := MD_ROM_ALTERNATE_HEADER_OFFSET;
  end;

  FEEPROMConfig := DetectMDEEPROM(HeaderText($180, 14),
    ReadWord($18E + Cardinal(FHeaderOffset - MD_ROM_HEADER_OFFSET)),
    (Cardinal(ReadWord(0)) shl 16) or ReadWord(2));
  var Product := UpperCase(HeaderText($180, 14));
  // Homebrew such as SRB32X uses a SEGA SSF header. An explicit .32x
  // cartridge must still attach the expansion hardware.
  F32X := SameText(Extension, '.32x') or
    (Pos('32X', UpperCase(HeaderText($100, 16))) > 0);
  var InitialSP := (Cardinal(ReadWord(0)) shl 16) or ReadWord(2);
  FJCart := (Pos('T-120096', Product) > 0) or (Pos('T-120146', Product) > 0) or
    (Pos('T-120106', Product) > 0) or (Pos('T-120066', Product) > 0) or
    (Pos('T-123456', Product) > 0) or
    ((Pos('00000000', Product) > 0) and
    ((ReadWord($18E) = $168B) or (ReadWord($18E) = $165E) or
    (ReadWord($18E) = $CEE0) or (ReadWord($18E) = $2C41)) and
    ((InitialSP = $444E4C44) or (InitialSP = $FFFFFFFC)));
  // SRAM-patched Mega Man / Wonder Boy dumps retain their product ID but
  // advertise a parallel RAM range instead of the original serial port.
  if (FEEPROMConfig.Mode = TMDEEPROMMode.Address7) and
    (FEEPROMConfig.SDAInMask = 1) and
    (ReadWord(Cardinal(FHeaderOffset + $B0)) = $5241) then
  begin
    var StartAddress := (Cardinal(ReadWord(Cardinal(FHeaderOffset + $B4))) shl 16) or
      ReadWord(Cardinal(FHeaderOffset + $B6));
    var EndAddress := (Cardinal(ReadWord(Cardinal(FHeaderOffset + $B8))) shl 16) or
      ReadWord(Cardinal(FHeaderOffset + $BA));
    if (StartAddress < EndAddress) and (EndAddress - StartAddress > 2) and
      ((Pos('T-12046', HeaderText($180, 14)) > 0) or
      (Pos('T-12053', HeaderText($180, 14)) > 0) or
      (Pos('G-4060', HeaderText($180, 14)) > 0)) then
      FEEPROMConfig := Default(TMDEEPROMConfig);
  end;
  FTitle := HeaderText(MD_ROM_OVERSEAS_TITLE_OFFSET, MD_ROM_TITLE_SIZE);
  if FTitle = '' then
    FTitle := HeaderText(MD_ROM_DOMESTIC_TITLE_OFFSET, MD_ROM_TITLE_SIZE);
  var RegionText := UpperCase(HeaderText(MD_ROM_REGION_OFFSET, MD_ROM_REGION_SIZE));
  var RegionMask: Integer;

  // Prefer NTSC for multiregion cartridges. Older headers use J/U/E,
  // newer headers use a hexadecimal region mask (Japan=1, USA=4, Europe=8).
  FRegion := TMDRegion.USA;
  if Pos('U', RegionText) > 0 then
    FRegion := TMDRegion.USA
  else if Pos('J', RegionText) > 0 then
    FRegion := TMDRegion.Japan
  else if Pos('E', RegionText) > 0 then
    FRegion := TMDRegion.Europe
  else if (Length(RegionText) = 1) and
    TryStrToInt('$' + RegionText, RegionMask) then
  begin
    if RegionMask and 4 <> 0 then
      FRegion := TMDRegion.USA
    else if RegionMask and 1 <> 0 then
      FRegion := TMDRegion.Japan
    else if RegionMask and 8 <> 0 then
      FRegion := TMDRegion.Europe;
  end;
end;

function TMDCartridge.HeaderText(Offset, Count: Integer): string;
begin
  Inc(Offset, FHeaderOffset - MD_ROM_HEADER_OFFSET);
  Result := '';
  for var i := Offset to Offset + Count - 1 do
    if (FData[i] >= 32) and (FData[i] < 127) then
      Result := Result + Char(FData[i]);
  Result := Trim(Result);
end;

function TMDCartridge.ReadByte(Address: Cardinal): Byte;
begin
  if Address < Cardinal(Length(FData)) then
    Result := FData[Address]
  else
    Result := $FF;
end;

function TMDCartridge.ReadWord(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  Result := (Word(ReadByte(Address)) shl 8) or ReadByte(Address + 1);
end;

end.

