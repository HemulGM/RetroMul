unit SWF.Spark;

interface

uses
  System.SysUtils, Media.Image.PixelBuffer, Video.H263.Picture;

type
  TSparkHeader = Video.H263.Picture.TH263PictureHeader;

  TSparkFrame = Video.H263.Picture.TH263Picture;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TSparkHeader): Boolean;

function DecodeSpark(const Data: TBytes; const Header: TSparkHeader; const Reference: TSparkFrame; var Work: Int64; WorkLimit: Integer): TSparkFrame;

procedure PublishSpark(const Frame: TSparkFrame; Quantizer: Integer; Deblock: Boolean; const Bitmap: IImagePixelBuffer);

implementation

uses
  System.Math, SWF.Reader, Video.AVC.Types;

const
  SparkDeblockStrength: array[0..31] of Byte = (
    0, 1, 1, 2, 2, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 12);

function ClipByte(Value: Integer): Byte; inline;
begin
  Result := EnsureRange(Value, 0, 255);
end;

function ReadSparkHeader(const Data: TBytes; Offset: Integer; out Header: TSparkHeader): Boolean;
begin
  Result := Video.H263.Picture.ReadSparkHeader(Data, Offset, Header);
end;

function DecodeSpark(const Data: TBytes; const Header: TSparkHeader; const Reference: TSparkFrame; var Work: Int64; WorkLimit: Integer): TSparkFrame;
begin
  try
    Result := Video.H263.Picture.DecodeH263Picture(Data, Header, Reference, Work, WorkLimit);
  except
    on E: EPlayerError do
      raise ESWFError.Create(E.Message);
  end;
end;

procedure FilterPlane(var Plane: TBytes; Width, Height, Strength: Integer);
var
  X, Y: Integer;

  procedure Filter(First, Step: Integer);
  var
    A, B, C, D, Delta, Ramp, Adjustment: Integer;
  begin
    A := Plane[First];
    B := Plane[First + Step];
    C := Plane[First + 2 * Step];
    D := Plane[First + 3 * Step];
    Delta := (A - 4 * B + 4 * C - D) div 8;
    Ramp := Max(0, Min(Abs(Delta), 2 * Strength - Abs(Delta)));
    if Delta < 0 then
      Ramp := -Ramp;
    Adjustment := EnsureRange((A - D) div 4, -Abs(Ramp div 2), Abs(Ramp div 2));
    Plane[First] := Byte(A - Adjustment);
    Plane[First + Step] := ClipByte(B + Ramp);
    Plane[First + 2 * Step] := ClipByte(C - Ramp);
    Plane[First + 3 * Step] := Byte(D + Adjustment);
  end;

begin
  Y := 8;
  while Y <= Height - 2 do
  begin
    for X := 0 to Width - 1 do
      Filter((Y - 2) * Width + X, Width);
    Inc(Y, 8);
  end;
  X := 8;
  while X <= Width - 2 do
  begin
    for Y := 0 to Height - 1 do
      Filter(Y * Width + X - 2, 1);
    Inc(X, 8);
  end;
end;

procedure PublishSpark(const Frame: TSparkFrame; Quantizer: Integer; Deblock: Boolean; const Bitmap: IImagePixelBuffer);
var
  YPlane, CbPlane, CrPlane: TBytes;
  X, Y, ChromaIndex, Gray, Cb, Cr, R, G, B, HalfWidth, HalfHeight: Integer;
begin
  HalfWidth := (Frame.Width + 1) div 2;
  HalfHeight := (Frame.Height + 1) div 2;
  YPlane := Frame.Y;
  CbPlane := Frame.Cb;
  CrPlane := Frame.Cr;
  if Deblock then
  begin
    YPlane := Copy(YPlane);
    CbPlane := Copy(CbPlane);
    CrPlane := Copy(CrPlane);
    FilterPlane(YPlane, Frame.Width, Frame.Height, SparkDeblockStrength[Quantizer]);
    FilterPlane(CbPlane, HalfWidth, HalfHeight, SparkDeblockStrength[Quantizer]);
    FilterPlane(CrPlane, HalfWidth, HalfHeight, SparkDeblockStrength[Quantizer]);
  end;
  for Y := 0 to Frame.Height - 1 do
    for X := 0 to Frame.Width - 1 do
    begin
      ChromaIndex := (Y div 2) * HalfWidth + (X div 2);
      Gray := (Integer(YPlane[Y * Frame.Width + X]) - 16) * 76309 + 32768;
      Cb := Integer(CbPlane[ChromaIndex]) - 128;
      Cr := Integer(CrPlane[ChromaIndex]) - 128;
      R := ClipByte((Gray + 104597 * Cr) div 65536);
      G := ClipByte((Gray - 53279 * Cr - 25675 * Cb) div 65536);
      B := ClipByte((Gray + 132201 * Cb) div 65536);
      Bitmap.SetPixelPremultiplied(X, Y, $FF000000 or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B));
    end;
end;

end.

