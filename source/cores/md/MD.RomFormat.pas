unit MD.RomFormat;

interface

uses
  System.SysUtils;

const
  MD_ENCODING_SMD = 'md.smd';
  MD_ENCODING_BYTE_SWAPPED = 'md.byte-swapped';

function CheckImage(const Data: TBytes): Boolean;

function TryDetectEncoding(const Data: TBytes; out Encoding: string): Boolean;

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;

implementation

uses
  MD.Cartridge, System.Classes;

function CheckImage(const Data: TBytes): Boolean;
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

function TryDetectEncoding(const Data: TBytes; out Encoding: string): Boolean;

  function Signature(Offset: Integer; const Text: AnsiString): Boolean;
  begin
    Result := (Length(Data) >= Offset + Length(Text)) and
      CompareMem(@Data[Offset], PAnsiChar(Text), Length(Text));
  end;

begin
  Encoding := '';
  Result := True;
  if Signature(MD_ROM_HEADER_OFFSET, MD_ROM_SIGNATURE) or
    Signature(MD_ROM_ALTERNATE_HEADER_OFFSET, MD_ROM_SIGNATURE) or CheckImage(Data) then
    Exit;
  if Signature(MD_ROM_HEADER_OFFSET, 'ESAG') or
    Signature(MD_ROM_ALTERNATE_HEADER_OFFSET, 'ESAG') then
    Encoding := MD_ENCODING_BYTE_SWAPPED
  else if (Length(Data) >= ROM_SIGNATURE_PROBE_SIZE) and
    (Data[MD_ROM_COPIER_HEADER_SIZE + SMD_HALF_BLOCK_SIZE + MD_ROM_HEADER_OFFSET div 2] = Ord(MD_ROM_SIGNATURE[1])) and
    (Data[MD_ROM_COPIER_HEADER_SIZE + MD_ROM_HEADER_OFFSET div 2] = Ord(MD_ROM_SIGNATURE[2])) and
    (Data[MD_ROM_COPIER_HEADER_SIZE + SMD_HALF_BLOCK_SIZE + MD_ROM_HEADER_OFFSET div 2 + 1] = Ord(MD_ROM_SIGNATURE[3])) and
    (Data[MD_ROM_COPIER_HEADER_SIZE + MD_ROM_HEADER_OFFSET div 2 + 1] = Ord(MD_ROM_SIGNATURE[4])) then
    Encoding := MD_ENCODING_SMD
  else
    Result := False;
end;

function NormalizeImage(const Data: TBytes; const Encoding: string): TBytes;
begin
  if Encoding = MD_ENCODING_SMD then
  begin
    if (Length(Data) - MD_ROM_COPIER_HEADER_SIZE) mod SMD_BLOCK_SIZE <> 0 then
      raise EReadError.Create('Invalid SMD size');
    SetLength(Result, Length(Data) - MD_ROM_COPIER_HEADER_SIZE);
    for var Block := 0 to Length(Result) div SMD_BLOCK_SIZE - 1 do
      for var I := 0 to SMD_HALF_BLOCK_SIZE - 1 do
      begin
        Result[Block * SMD_BLOCK_SIZE + I * 2] := Data[MD_ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE + SMD_HALF_BLOCK_SIZE + I];
        Result[Block * SMD_BLOCK_SIZE + I * 2 + 1] := Data[MD_ROM_COPIER_HEADER_SIZE + Block * SMD_BLOCK_SIZE + I];
      end;
    Exit;
  end;
  Result := Copy(Data);
  if Encoding = MD_ENCODING_BYTE_SWAPPED then
  begin
    if Odd(Length(Data)) then
      raise EReadError.Create('Invalid byte-swapped ROM size');
    for var I := 0 to Length(Data) div 2 - 1 do
    begin
      Result[I * 2] := Data[I * 2 + 1];
      Result[I * 2 + 1] := Data[I * 2];
    end;
  end
  else if Encoding <> '' then
    raise EReadError.Create('Unsupported Mega Drive ROM encoding');
end;

end.

