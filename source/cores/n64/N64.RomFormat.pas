unit N64.RomFormat;

interface

uses
  System.SysUtils;

const
  N64_IMAGE_MAX_SIZE = 64 * 1024 * 1024;
  N64_ENCODING_BYTE_SWAPPED = 'n64.byte-swapped';
  N64_ENCODING_WORD_SWAPPED = 'n64.word-swapped';

function TryDetectEncoding(const Data: TBytes; out Encoding: string): Boolean;

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;

implementation

uses
  System.Classes;

function TryDetectEncoding(const Data: TBytes; out Encoding: string): Boolean;
begin
  Encoding := '';
  Result := False;
  if Length(Data) < 64 then
    Exit;
  var Magic := (Cardinal(Data[0]) shl 24) or (Cardinal(Data[1]) shl 16) or
    (Cardinal(Data[2]) shl 8) or Data[3];
  case Magic of
    $80371240:
      Encoding := '';
    $37804012:
      Encoding := N64_ENCODING_BYTE_SWAPPED;
    $40123780:
      Encoding := N64_ENCODING_WORD_SWAPPED;
  else
    Exit;
  end;
  Result := True;
end;

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;
begin
  if (Length(Data) < $1000) or (Length(Data) > N64_IMAGE_MAX_SIZE) or ((Length(Data) and 3) <> 0) then
    raise EReadError.Create('Invalid N64 ROM size');
  Result := Copy(Data);
  if Encoding = N64_ENCODING_WORD_SWAPPED then
  begin
    for var i := 0 to Length(Data) div 4 - 1 do
      for var J := 0 to 3 do
        Result[i * 4 + J] := Data[i * 4 + 3 - J];
  end
  else if Encoding = N64_ENCODING_BYTE_SWAPPED then
  begin
    for var i := 0 to Length(Data) div 2 - 1 do
    begin
      Result[i * 2] := Data[i * 2 + 1];
      Result[i * 2 + 1] := Data[i * 2];
    end;
  end
  else if Encoding <> '' then
    raise EReadError.Create('Unsupported Nintendo 64 ROM encoding');
end;

end.

