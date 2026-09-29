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
    function HeaderText(Offset, Count: Integer): string;
  public
    constructor Create(const Data: TBytes; const Extension: string); overload;
    constructor Create(const FileName: string); overload;
    function ReadByte(Address: Cardinal): Byte;
    function ReadWord(Address: Cardinal): Word;
    property Data: TBytes read FData;
    property Title: string read FTitle;
    property Region: TMDRegion read FRegion;
  end;

implementation

uses
  System.IOUtils;

const
  MaxROMSize = 8 * 1024 * 1024;

constructor TMDCartridge.Create(const FileName: string);
begin
  var Bytes: TBytes;
  var Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    if (Stream.Size < $200) or (Stream.Size > MaxROMSize + 512) then
      raise EMDCartridge.Create('Mega Drive ROM must contain 512 bytes to 8 MiB');
    SetLength(Bytes, Integer(Stream.Size));
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Create(Bytes, TPath.GetExtension(FileName));
end;

constructor TMDCartridge.Create(const Data: TBytes; const Extension: string);
begin
  inherited Create;
  // Some collections label ordinary big-endian dumps as .smd. Trust the
  // cartridge signature before attempting the copier's interleaving format.
  if SameText(Extension, '.smd') and not ((Length(Data) >= $200) and
    (Data[$100] = Ord('S')) and (Data[$101] = Ord('E')) and
    (Data[$102] = Ord('G')) and (Data[$103] = Ord('A'))) then
  begin
    if (Length(Data) <= 512) or ((Length(Data) - 512) mod $4000 <> 0) or (Length(Data) > MaxROMSize + 512) then
      raise EMDCartridge.Create('Invalid SMD size: expected a 512-byte header and 16 KiB blocks');
    SetLength(FData, Length(Data) - 512);
    for var Block := 0 to Length(FData) div $4000 - 1 do
    begin
      var Source := 512 + Block * $4000;
      for var i := 0 to $1FFF do
      begin
        FData[Block * $4000 + i * 2] := Data[Source + $2000 + i];
        FData[Block * $4000 + i * 2 + 1] := Data[Source + i];
      end;
    end;
  end
  else
    FData := Copy(Data);
  if (Length(FData) < $200) or (Length(FData) > MaxROMSize) or Odd(Length(FData)) then
    raise EMDCartridge.Create('Invalid Mega Drive ROM size');
  if HeaderText($100, 4) <> 'SEGA' then
    raise EMDCartridge.Create('Mega Drive ROM has no SEGA header at $100');
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

