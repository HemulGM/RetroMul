unit SWF.Bitmap;

interface

uses
  System.SysUtils, SWF.Reader, Media.Image.Types;

type
  ESWFBitmapUnsupported = class(ESWFError);

const
  SWFBitmapPixelLimit = 16 * 1024 * 1024;
  SWFMovieBitmapPixelLimit = 32 * 1024 * 1024;

function DecodeSWFLossless(Reader: TSWFReader; HasAlpha: Boolean; MaxPixels: Integer): TRasterImage;

function DecodeSWFJPEG(Reader: TSWFReader; TagCode: Integer; const Tables: TBytes; MaxPixels: Integer): TRasterImage;

function InflateBitmap(const Data: TBytes; ExpectedSize: Integer; MaxSize: Integer = 0): TBytes;

implementation

uses
  System.Math, System.ZLib, Media.Image.JPEG, Media.Image.PNG;

function InflateBitmap(const Data: TBytes; ExpectedSize: Integer; MaxSize: Integer): TBytes;
var
  Stream: z_stream;
  Status: Integer;
begin
  if (Length(Data) = 0) or (ExpectedSize < 1) then
    raise ESWFError.Create('Empty SWF bitmap compression stream');
  MaxSize := Max(ExpectedSize, MaxSize);
  SetLength(Result, MaxSize);
  Stream := Default(z_stream);
  if inflateInit(Stream) <> Z_OK then
    raise ESWFError.Create('Cannot initialize SWF bitmap inflater');
  try
    Stream.next_in := @Data[0];
    Stream.avail_in := Length(Data);
    Stream.next_out := @Result[0];
    Stream.avail_out := MaxSize;
    Status := inflate(Stream, Z_FINISH);
    if (Status <> Z_STREAM_END) or (Stream.total_out < UInt64(ExpectedSize)) or
      (Stream.avail_in <> 0) then
      raise ESWFError.Create('Invalid compressed SWF bitmap length or data');
  finally
    inflateEnd(Stream);
  end;
  if MaxSize > ExpectedSize then
    SetLength(Result, ExpectedSize);
end;

function StraightARGB(Red, Green, Blue, Alpha: Integer): Cardinal;
begin
  if Alpha = 0 then
    Exit(0);
  if Alpha < 255 then
  begin
    Red := (Min(Red, Alpha) * 255 + Alpha div 2) div Alpha;
    Green := (Min(Green, Alpha) * 255 + Alpha div 2) div Alpha;
    Blue := (Min(Blue, Alpha) * 255 + Alpha div 2) div Alpha;
  end;
  Result := (Cardinal(Alpha) shl 24) or (Cardinal(Red) shl 16) or
    (Cardinal(Green) shl 8) or Cardinal(Blue);
end;

function DecodeSWFLossless(Reader: TSWFReader; HasAlpha: Boolean; MaxPixels: Integer): TRasterImage;
var
  BitmapFormat, PaletteCount, PaletteStride, TableSize, RowStride, ExpectedSize: Integer;
  X, Y, At, PixelIndex, EntryIndex, Alpha, RGB15, Red, Green, Blue: Integer;
  Data: TBytes;
  Palette: array[0..255] of Cardinal;
  MissingColor: Cardinal;
begin
  Result := Default(TRasterImage);
  BitmapFormat := Reader.U8;
  Result.Width := Reader.U16;
  Result.Height := Reader.U16;
  if (Result.Width < 1) or (Result.Height < 1) or
    (Int64(Result.Width) * Result.Height > MaxPixels) then
    raise ESWFError.Create('Invalid or excessive SWF bitmap size');
  PaletteCount := 0;
  PaletteStride := 3 + Ord(HasAlpha);
  case BitmapFormat of
    3:
      begin
        PaletteCount := Integer(Reader.U8) + 1;
        RowStride := (Result.Width + 3) and not 3;
      end;
    4:
      RowStride := ((Result.Width + 1) and not 1) * 2;
    5:
      RowStride := Result.Width * 4;
  else
    raise ESWFError.Create('Unknown SWF lossless bitmap format');
  end;
  TableSize := PaletteCount * PaletteStride;
  ExpectedSize := TableSize + RowStride * Result.Height;
  if BitmapFormat = 4 then
    // Flash accepts format 4 tags made by relabeling 32-bit data. Decode
    // the padded 15-bit rows and allow a bounded unused tail.
    Data := InflateBitmap(Reader.Bytes(Reader.Remaining), ExpectedSize, Result.Width * Result.Height * 4)
  else
    Data := InflateBitmap(Reader.Bytes(Reader.Remaining), ExpectedSize);
  SetLength(Result.Pixels, Result.Width * Result.Height);

  Alpha := 255;
  for EntryIndex := 0 to PaletteCount - 1 do
  begin
    At := EntryIndex * PaletteStride;
    if HasAlpha then
      Alpha := Data[At + 3];
    Palette[EntryIndex] := StraightARGB(Data[At], Data[At + 1], Data[At + 2], Alpha);
  end;
  if HasAlpha then
    MissingColor := 0
  else
    MissingColor := $FF000000;

  PixelIndex := 0;
  for Y := 0 to Result.Height - 1 do
  begin
    At := TableSize + Y * RowStride;
    for X := 0 to Result.Width - 1 do
    begin
      case BitmapFormat of
        3:
          begin
            EntryIndex := Data[At];
            if EntryIndex < PaletteCount then
              Result.Pixels[PixelIndex] := Palette[EntryIndex]
            else
              Result.Pixels[PixelIndex] := MissingColor;
            Inc(At);
          end;
        4:
          begin
            RGB15 := (Integer(Data[At]) shl 8) or Data[At + 1];
            Red := (((RGB15 shr 10) and 31) * 255 + 15) div 31;
            Green := (((RGB15 shr 5) and 31) * 255 + 15) div 31;
            Blue := ((RGB15 and 31) * 255 + 15) div 31;
            Result.Pixels[PixelIndex] := StraightARGB(Red, Green, Blue, 255);
            Inc(At, 2);
          end;
        5:
          begin
            Alpha := 255;
            if HasAlpha then
              Alpha := Data[At];
            Result.Pixels[PixelIndex] := StraightARGB(Data[At + 1], Data[At + 2], Data[At + 3], Alpha);
            Inc(At, 4);
          end;
      end;
      Inc(PixelIndex);
    end;
  end;
end;

function IsMarker(const Data: TBytes; Index: Integer; Marker: Byte): Boolean;
begin
  Result := (Index >= 0) and (Index <= Length(Data) - 2) and
    (Data[Index] = $FF) and (Data[Index + 1] = Marker);
end;

function JoinJPEGTables(const Image, Tables: TBytes): TBytes;
var
  TableSize, ImageOffset: Integer;
begin
  Result := Image;
  if Length(Tables) = 0 then
    Exit;
  if not IsMarker(Tables, 0, $D8) or not IsMarker(Tables, Length(Tables) - 2, $D9) then
    raise ESWFError.Create('Invalid SWF JPEGTables markers');
  TableSize := Length(Tables) - 2;
  ImageOffset := 0;
  if IsMarker(Image, 0, $D9) and IsMarker(Image, 2, $D8) then
  begin
    ImageOffset := 4;
    if IsMarker(Image, 4, $D8) then
      Inc(ImageOffset, 2);
  end
  else if IsMarker(Image, 0, $D8) then
    ImageOffset := 2;
  SetLength(Result, TableSize + Length(Image) - ImageOffset);
  Move(Tables[0], Result[0], TableSize);
  if ImageOffset < Length(Image) then
    Move(Image[ImageOffset], Result[TableSize], Length(Image) - ImageOffset);
end;

function RepairJPEG(const Data: TBytes; out FrameMarker: Byte): TBytes;
var
  Start, At, Size, RemovedAt, OutSize: Integer;
  Marker: Byte;
begin
  Result := Data;
  FrameMarker := 0;
  Start := 0;
  if IsMarker(Data, 0, $D9) and IsMarker(Data, 2, $D8) then
  begin
    Start := 2;
    if IsMarker(Data, 4, $D8) then
      Start := 4;
  end;
  At := Start;
  RemovedAt := -1;
  while At <= Length(Data) - 2 do
  begin
    if Data[At] <> $FF then
      Break;
    Marker := Data[At + 1];
    case Marker of
      $FF:
        Inc(At);
      $D8, $D0..$D7, $01:
        Inc(At, 2);
      $D9:
        begin
          if (RemovedAt >= 0) or not IsMarker(Data, At + 2, $D8) then
            Break;
          RemovedAt := At;
          Inc(At, 4);
        end;
      $C0..$C3, $C5..$C7, $C9..$CB, $CD..$CF:
        begin
          FrameMarker := Marker;
          Break;
        end;
      $DA:
        Break;
    else
      if At > Length(Data) - 4 then
        Break;
      Size := (Integer(Data[At + 2]) shl 8) or Data[At + 3];
      if Size < 2 then
        Break;
      Inc(At, Size + 2);
    end;
  end;
  if RemovedAt >= 0 then
  begin
    OutSize := Length(Data) - Start - 4;
    SetLength(Result, OutSize);
    if RemovedAt > Start then
      Move(Data[Start], Result[0], RemovedAt - Start);
    if RemovedAt + 4 < Length(Data) then
      Move(Data[RemovedAt + 4], Result[RemovedAt - Start], Length(Data) - RemovedAt - 4);
  end
  else if Start > 0 then
    Result := Copy(Data, Start, Length(Data) - Start);
  OutSize := Length(Result);
  if not IsMarker(Result, OutSize - 2, $D9) then
  begin
    SetLength(Result, OutSize + 2);
    Result[OutSize] := $FF;
    Result[OutSize + 1] := $D9;
  end;
end;

function DecodeSWFJPEG(Reader: TSWFReader; TagCode: Integer; const Tables: TBytes; MaxPixels: Integer): TRasterImage;
const
  PNGSignature: array[0..7] of Byte = ($89, $50, $4E, $47, $0D, $0A, $1A, $0A);
var
  ImageSize: Cardinal;
  Encoded, AlphaData: TBytes;
  Header: Byte;
  PNG: TPNGImage;
  I: Integer;
  Color: Cardinal;
begin
  if TagCode in [35, 90] then
  begin
    ImageSize := Reader.U32;
    if TagCode = 90 then
      Reader.U16; // DeblockParam is not used by the decoder.
    if ImageSize > Cardinal(Reader.Remaining) then
      raise ESWFError.Create('Invalid SWF JPEG alpha offset');
    Encoded := Reader.Bytes(Integer(ImageSize));
    AlphaData := Reader.Bytes(Reader.Remaining);
  end
  else
    Encoded := Reader.Bytes(Reader.Remaining);

  if TagCode = 6 then
    Encoded := JoinJPEGTables(Encoded, Tables);
  if IsMarker(Encoded, 0, $D8) or (IsMarker(Encoded, 0, $D9) and IsMarker(Encoded, 2, $D8)) then
  begin
    Encoded := RepairJPEG(Encoded, Header);
    if (Header <> 0) and not (Header in [$C0, $C1]) then
      raise ESWFBitmapUnsupported.Create('Unsupported SWF JPEG frame coding');
    try
      Result := DecodeJPEG(Encoded, MaxPixels);
    except
      on E: EImageResourceLimit do
        raise ESWFError.Create('SWF JPEG exceeds bitmap pixel budget');
      on E: EImageFormat do
        raise ESWFBitmapUnsupported.Create('Cannot decode embedded SWF JPEG: ' + E.Message);
    end;
    if Length(AlphaData) > 0 then
    begin
      AlphaData := InflateBitmap(AlphaData, Length(Result.Pixels));
      for I := 0 to High(Result.Pixels) do
      begin
        Color := Result.Pixels[I];
        Result.Pixels[I] := StraightARGB((Color shr 16) and $FF, (Color shr 8) and $FF,
            Color and $FF, AlphaData[I]);
      end;
    end;
    Exit;
  end;
  if (Length(Encoded) >= SizeOf(PNGSignature)) and
    CompareMem(@Encoded[0], @PNGSignature[0], SizeOf(PNGSignature)) then
  begin
    try
      PNG := DecodePNG(Encoded, MaxPixels);
    except
      on E: EPNGResourceLimit do
        raise ESWFError.Create('SWF PNG exceeds bitmap pixel budget');
      on E: EPNGFormat do
        raise ESWFBitmapUnsupported.Create('Cannot decode embedded SWF PNG: ' + E.Message);
    end;
    Result.Width := PNG.Width;
    Result.Height := PNG.Height;
    Result.Pixels := PNG.Pixels;
    Exit;
  end;
  raise ESWFBitmapUnsupported.Create('Unknown or unsupported SWF JPEG-tag bitmap format');
end;

end.

