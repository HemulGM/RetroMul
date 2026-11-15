unit Media.Font.Bitmap;

// RetroMul Pixel: native-size bitmap glyphs repackaged from Terminus Font.
interface

uses
  System.SysUtils;

type
  TBitmapFontSize = (Small, Medium, Large);

  TBitmapGlyph = record
    Width, Height, Baseline, Left, Right, RowBytes, Offset: Integer;
    Data: TBytes; // Shared immutable font data; callers must not modify it.
    function Ink(X, Y: Integer): Boolean;
  end;

function BitmapFontGlyph(Size: TBitmapFontSize; C: Char): TBitmapGlyph;

implementation

uses
  System.Classes, System.Math;

{$R 'Media.Font.Bitmap.res' 'Media.Font.Bitmap.rc'}

type
  TGlyphBounds = record
    Left, Right: Integer;
  end;

  TBitmapFont = class
    Data: TBytes;
    Width, Height, Baseline, RowBytes, RecordSize, Count, Fallback: Integer;
    Bounds: TArray<TGlyphBounds>;
    constructor Create(const ResourceName: string);
    function Code(Index: Integer): Integer;
    function Find(C: Char): Integer;
    function Glyph(C: Char): TBitmapGlyph;
  end;

var
  Fonts: array[TBitmapFontSize] of TBitmapFont;
  FontLock: TObject;

function TBitmapGlyph.Ink(X, Y: Integer): Boolean;
begin
  Result := (X >= 0) and (X < Width) and (Y >= 0) and (Y < Height) and
    ((Data[Offset + Y * RowBytes + X div 8] and ($80 shr (X mod 8))) <> 0);
end;

constructor TBitmapFont.Create(const ResourceName: string);

  function WordAt(Offset: Integer): Integer;
  begin
    Result := Data[Offset] or (Integer(Data[Offset + 1]) shl 8);
  end;

begin
  inherited Create;
  var Stream := TResourceStream.Create(HInstance, ResourceName, PChar(10));
  try
    SetLength(Data, Stream.Size);
    if Length(Data) > 0 then
      Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  if (Length(Data) < 14) or (Data[0] <> Ord('R')) or (Data[1] <> Ord('M')) or
    (Data[2] <> Ord('B')) or (Data[3] <> Ord('F')) or (WordAt(4) <> 1) then
    raise EReadError.Create('Invalid bitmap font header');
  Width := WordAt(6);
  Height := WordAt(8);
  Baseline := WordAt(10);
  Count := WordAt(12);
  if (Width < 1) or (Width > 32) or (Height < 1) or (Height > 64) or
    (Baseline < 1) or (Baseline >= Height) or (Count < 1) then
    raise EReadError.Create('Invalid bitmap font metrics');
  RowBytes := (Width + 7) div 8;
  RecordSize := 2 + RowBytes * Height;
  if Length(Data) <> 14 + Count * RecordSize then
    raise EReadError.Create('Truncated bitmap font');
  SetLength(Bounds, Count);
  Fallback := -1;
  for var I := 0 to Count - 1 do
  begin
    if (I > 0) and (Code(I) <= Code(I - 1)) then
      raise EReadError.Create('Unsorted bitmap font');
    if Code(I) = $FFFD then
      Fallback := I;
    Bounds[I].Left := Width;
    Bounds[I].Right := -1;
    for var Y := 0 to Height - 1 do
      for var X := 0 to Width - 1 do
        if (Data[14 + I * RecordSize + 2 + Y * RowBytes + X div 8] and ($80 shr (X mod 8))) <> 0 then
        begin
          Bounds[I].Left := Min(Bounds[I].Left, X);
          Bounds[I].Right := Max(Bounds[I].Right, X);
        end;
  end;
  if Fallback < 0 then
    raise EReadError.Create('Bitmap font has no replacement glyph');
end;

function TBitmapFont.Code(Index: Integer): Integer;
begin
  var At := 14 + Index * RecordSize;
  Result := Data[At] or (Integer(Data[At + 1]) shl 8);
end;

function TBitmapFont.Find(C: Char): Integer;
var
  L, R, M, Value: Integer;
begin
  L := 0;
  R := Count - 1;
  while L <= R do
  begin
    M := L + (R - L) div 2;
    Value := Code(M);
    if Value = Ord(C) then
      Exit(M);
    if Value < Ord(C) then
      L := M + 1
    else
      R := M - 1;
  end;
  Result := Fallback;
end;

function TBitmapFont.Glyph(C: Char): TBitmapGlyph;
begin
  var Index := Find(C);
  Result.Width := Width;
  Result.Height := Height;
  Result.Baseline := Baseline;
  Result.Left := Bounds[Index].Left;
  Result.Right := Bounds[Index].Right;
  Result.RowBytes := RowBytes;
  Result.Offset := 14 + Index * RecordSize + 2;
  Result.Data := Data;
end;

function BitmapFontGlyph(Size: TBitmapFontSize; C: Char): TBitmapGlyph;
const
  Names: array[TBitmapFontSize] of string = ('RETROMUL_PIXEL_12', 'RETROMUL_PIXEL_16', 'RETROMUL_PIXEL_24');
begin
  TMonitor.Enter(FontLock);
  try
    if Fonts[Size] = nil then
      Fonts[Size] := TBitmapFont.Create(Names[Size]);
    Result := Fonts[Size].Glyph(C);
  finally
    TMonitor.Exit(FontLock);
  end;
end;

initialization
  FontLock := TObject.Create;

finalization
  for var Size := Low(TBitmapFontSize) to High(TBitmapFontSize) do
    Fonts[Size].Free;
  FontLock.Free;

end.

