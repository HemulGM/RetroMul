unit SNES.RomFormat;

interface

uses
  System.SysUtils;

const
  SNES_ENCODING_COPIER = 'snes.copier';

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;

function LoadImage(const Data: TBytes): TBytes;

implementation

uses
  SNES.Cartridge, System.Classes;

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;
begin
  if Encoding = SNES_ENCODING_COPIER then
    Exit(Copy(Data, SNES_ROM_COPIER_HEADER_SIZE, Length(Data) - SNES_ROM_COPIER_HEADER_SIZE));

  if Encoding <> '' then
    raise EReadError.Create('Unsupported SNES ROM encoding');

  Result := Copy(Data);
end;

function LoadImage(const Data: TBytes): TBytes;
begin
  var Header: TSnesHeader;
  if DetectSnesHeader(Data, Header) and (Header.CopierSize <> 0) then
    Result := NormalizeImage(Data, SNES_ENCODING_COPIER)
  else
    Result := Copy(Data);
end;

end.

