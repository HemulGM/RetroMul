unit GB.RomFormat;

interface

uses
  System.SysUtils;

type
  TGBXFooter = record
    Present: Boolean;
    Mapper: string;
    ROMSize, RAMSize, FooterSize, MinorVersion: Cardinal;
    Battery, Rumble, Timer: Boolean;
    Variables: array[0..7] of Cardinal;
  end;

  TLegacyFooterReader = reference to function(const Data: TBytes): TGBXFooter;

function ReadFooter(const Data: TBytes): TGBXFooter;

function ReadGBXFooter(const Data: TBytes): TGBXFooter;

procedure RegisterLegacyFooterReader(const Reader: TLegacyFooterReader);

implementation

uses
  GB.Cartridge, System.Classes;

var
  FooterReader: TLegacyFooterReader;

procedure RegisterLegacyFooterReader(const Reader: TLegacyFooterReader);
begin
  if Assigned(FooterReader) then
    raise EArgumentException.Create('Duplicate legacy footer reader');
  FooterReader := Reader;
end;

function ReadGBXFooter(const Data: TBytes): TGBXFooter;
begin
  Result := Default(TGBXFooter);
  if Assigned(FooterReader) then
    Result := FooterReader(Data);
end;

function ReadFooter(const Data: TBytes): TGBXFooter;

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

initialization

finalization
  FooterReader := nil;

end.

