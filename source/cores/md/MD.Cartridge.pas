unit MD.Cartridge;

interface

uses
  System.SysUtils, System.Classes;

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
    function HeaderText(Offset, Count: Integer): string;
  public
    constructor Create(const Data: TBytes; const Extension: string); overload;
    constructor Create(Stream: TStream); overload;
    constructor Create(const FileName: string); overload;
    function ReadByte(Address: Cardinal): Byte;
    function ReadWord(Address: Cardinal): Word;
    property Data: TBytes read FData;
    property Title: string read FTitle;
    property Region: TMDRegion read FRegion;
  end;

implementation

uses
  Core.Storage, Core.RomFormat;

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
  var Format := DetectRom(Bytes);
  if Format.System <> TRomSystem.MD then
    raise EMDCartridge.Create('Unrecognized Mega Drive ROM header');
  Create(NormalizeRom(Bytes, Format), '');
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
    if (Length(Data) <= ROM_COPIER_HEADER_SIZE) or
      ((Length(Data) - ROM_COPIER_HEADER_SIZE) mod SMD_BLOCK_SIZE <> 0) or
      (Length(Data) > MD_ROM_MAX_SIZE + ROM_COPIER_HEADER_SIZE) then
      raise EMDCartridge.Create('Invalid SMD size: expected a 512-byte header and 16 KiB blocks');
    SetLength(FData, Length(Data) - ROM_COPIER_HEADER_SIZE);
    for var Block := 0 to Length(FData) div SMD_BLOCK_SIZE - 1 do
    begin
      var Source := ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE;
      for var I := 0 to SMD_HALF_BLOCK_SIZE - 1 do
      begin
        FData[Block * SMD_BLOCK_SIZE + I * 2] := Data[Source + SMD_HALF_BLOCK_SIZE + I];
        FData[Block * SMD_BLOCK_SIZE + I * 2 + 1] := Data[Source + I];
      end;
    end;
  end
  else
    FData := Copy(Data);

  if (Length(FData) < MD_ROM_HEADER_OFFSET + MD_ROM_HEADER_SIZE) or
    (Length(FData) > MD_ROM_MAX_SIZE) or Odd(Length(FData)) then
    raise EMDCartridge.Create('Invalid Mega Drive ROM size');
  if HeaderText(MD_ROM_HEADER_OFFSET, Length(MD_ROM_SIGNATURE)) <> string(MD_ROM_SIGNATURE) then
  begin
    // Some early diagnostics retain the first 128 vector entries and
    // place the identification header at $200 (Charles MacDonald's itest).
    if (Length(FData) < MD_ROM_ALTERNATE_HEADER_OFFSET + MD_ROM_HEADER_SIZE) or
      (HeaderText(MD_ROM_ALTERNATE_HEADER_OFFSET, Length(MD_ROM_SIGNATURE)) <> string(MD_ROM_SIGNATURE)) then
      raise EMDCartridge.Create('Mega Drive ROM has no SEGA header at $100 or $200');
    FHeaderOffset := MD_ROM_ALTERNATE_HEADER_OFFSET;
  end;

  FTitle := HeaderText($150, 48);
  if FTitle = '' then
    FTitle := HeaderText($120, 48);
  var RegionText := UpperCase(HeaderText($1F0, 16));
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
  Inc(Offset, FHeaderOffset - $100);
  Result := '';
  for var I := Offset to Offset + Count - 1 do
    if (FData[I] >= 32) and (FData[I] < 127) then
      Result := Result + Char(FData[I]);
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

