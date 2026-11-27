unit INTV.LuigiImage;

interface

uses
  System.SysUtils;

type
  TLuigiParagraphs = array[0..255] of Word;

  TLuigiPermissions = array[0..255] of Byte;

  TLuigiPages = array[0..15, 0..15] of Word;

  TLuigiImage = record
    Words: TArray<Word>;
    Paragraphs: TLuigiParagraphs;
    Permissions: TLuigiPermissions;
    Pages: TLuigiPages;
    ECSCompatibility, VoiceCompatibility, JLPMode, JLPFlashSectors: Integer;
    MapperEnabled: Boolean;
    class function IsContainer(const Data: TBytes): Boolean; static;
    class function Decode(const Data: TBytes): TLuigiImage; static;
  end;

implementation

uses
  System.Classes;

const
  Capacity = $80000;
  HeaderPolynomial = $98; // DOWCRC (reflected)
  PayloadPolynomial = $82F63B78; // CRC32/4 (reflected, zero initial value)

function CRC(const Data: TBytes; First, Count: Integer; Polynomial: Cardinal): Cardinal;
begin
  Result := 0;
  for var Offset := First to First + Count - 1 do
  begin
    Result := Result xor Data[Offset];
    for var Bit := 0 to 7 do
      if Result and 1 <> 0 then
        Result := (Result shr 1) xor Polynomial
      else
        Result := Result shr 1;
  end;
end;

function ReadLE(const Data: TBytes; Offset, Count: Integer): Cardinal;
begin
  Result := 0;
  for var Index := 0 to Count - 1 do
    Result := Result or (Cardinal(Data[Offset + Index]) shl (8 * Index));
end;

procedure DecodeMap(const Data: TBytes; Offset, Count: Integer; var Image: TLuigiImage);
begin
  if Count <> 1280 then
    raise EReadError.Create('Invalid LUIGI memory map size');
  for var Paragraph := 0 to 255 do
  begin
    var Translation := ReadLE(Data, Offset + 2 * Paragraph, 2);
    var Access := Data[Offset + 512 + Paragraph];
    if (Translation >= Capacity div 256) or (Access > $F) then
      raise EReadError.Create('Invalid LUIGI paragraph mapping');
    Image.Paragraphs[Paragraph] := Translation;
    Image.Permissions[Paragraph] := Access;
  end;
  Inc(Offset, 768);
  for var Chapter := 0 to 15 do
    for var Page := 0 to 15 do
    begin
      var Entry := ReadLE(Data, Offset, 2);
      if Entry shr 4 >= Capacity div $1000 then
        raise EReadError.Create('Invalid LUIGI page mapping');
      Image.Pages[Chapter, Page] := Entry;
      Inc(Offset, 2);
    end;
end;

procedure DecodeHunk(const Data: TBytes; Offset, Size: Integer; var Image: TLuigiImage);
begin
  if Size < 3 then
    raise EReadError.Create('Truncated LUIGI data hunk');
  var Position := Integer(ReadLE(Data, Offset, 3));
  var Limit := Offset + Size;
  if Position >= Capacity then
    raise EReadError.Create('LUIGI data hunk starts outside cartridge RAM');
  Inc(Offset, 3);
  while Offset < Limit do
  begin
    var Marker := Data[Offset];
    Inc(Offset);
    var Words, Bytes: Integer;
    case Marker of
      $01..$3F:
        begin
          Words := Marker;
          Bytes := Words + 1;
        end;
      $40..$BF:
        begin
          Words := Marker - $3F;
          Bytes := Words + 1 + (Words + 2) div 4;
        end;
      $C0..$FD:
        begin
          Words := Marker - $BF;
          Bytes := Words * 2;
        end;
    else
      raise EReadError.Create('Reserved encoding in LUIGI data hunk');
    end;
    if (Bytes > Limit - Offset) or (Words > Capacity - Position) then
      raise EReadError.Create('LUIGI data hunk exceeds bounds');

    var Upper := 0;
    for var Index := 0 to Words - 1 do
    begin
      if (Marker >= $C0) or (Index = Words - 1) then
      begin
        Image.Words[Position] := ReadLE(Data, Offset, 2);
        Inc(Offset, 2);
      end
      else
      begin
        if (Marker >= $40) and (Index mod 4 = 0) then
        begin
          Upper := Data[Offset];
          Inc(Offset);
        end;
        Image.Words[Position] := Data[Offset] or (((Upper shr (6 - (Index mod 4) * 2)) and 3) shl 8);
        Inc(Offset);
      end;
      Inc(Position);
    end;
  end;
end;

class function TLuigiImage.IsContainer(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= 3) and (Data[0] = Ord('L')) and (Data[1] = Ord('T')) and (Data[2] = Ord('O'));
end;

class function TLuigiImage.Decode(const Data: TBytes): TLuigiImage;
const
  HeaderSize: array[0..1] of Integer = (16, 32);
begin
  Result := Default(TLuigiImage);
  if not IsContainer(Data) or (Length(Data) < 4) then
    raise EReadError.Create('Invalid LUIGI signature');
  var Version := Data[3];
  if Version > High(HeaderSize) then
    raise EReadError.Create('Unsupported LUIGI version');
  var Offset := HeaderSize[Version];
  if Length(Data) < Offset then
    raise EReadError.Create('Truncated LUIGI file header');
  if CRC(Data, 0, Offset - 1, HeaderPolynomial) <> Data[Offset - 1] then
    raise EReadError.Create('Invalid LUIGI file header checksum');

  Result.VoiceCompatibility := Data[4] and 3;
  Result.ECSCompatibility := (Data[4] shr 2) and 3;
  Result.JLPMode := Data[6] and 3;
  Result.JLPFlashSectors := ReadLE(Data, 6, 2) shr 6;
  Result.MapperEnabled := Data[8] and 1 <> 0;
  SetLength(Result.Words, Capacity);

  var HasMap := False;
  while (Offset < Length(Data)) and (Data[Offset] <> $FF) do
  begin
    if Length(Data) - Offset < 4 then
      raise EReadError.Create('Truncated LUIGI block header');
    if CRC(Data, Offset, 3, HeaderPolynomial) <> Data[Offset + 3] then
      raise EReadError.Create('Invalid LUIGI block header checksum');
    var BlockKind := Data[Offset];
    var Count := Integer(ReadLE(Data, Offset + 1, 2));
    Inc(Offset, 4);
    if BlockKind = 0 then
      raise EReadError.Create('Encrypted LUIGI cartridges require their original LTO Flash hardware');
    if Count <> 0 then
    begin
      if Count + 4 > Length(Data) - Offset then
        raise EReadError.Create('Truncated LUIGI block');
      var Checksum := ReadLE(Data, Offset, 4);
      Inc(Offset, 4);
      if CRC(Data, Offset, Count, PayloadPolynomial) <> Checksum then
        raise EReadError.Create('Invalid LUIGI block payload checksum');
    end;

    case BlockKind of
      1:
        begin
          if HasMap then
            raise EReadError.Create('Duplicate LUIGI memory map');
          DecodeMap(Data, Offset, Count, Result);
          HasMap := True;
        end;
      2:
        DecodeHunk(Data, Offset, Count, Result);
      // Metadata and future block types do not alter cartridge memory.
    end;
    Inc(Offset, Count);
  end;
  if not HasMap then
    raise EReadError.Create('Missing LUIGI memory map');
end;

end.

