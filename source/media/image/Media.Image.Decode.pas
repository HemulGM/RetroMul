unit Media.Image.Decode;

interface

uses
  System.SysUtils, Media.Image.Types, Media.Image.PNG;

function DecodeRasterImage(const Data: TBytes; MaxPixels: Integer = 16 * 1024 * 1024; PNGOptions: TPNGDecodeOptions = []): TRasterImage;

implementation

uses
  Media.Image.GIF, Media.Image.JPEG;

function DecodeRasterImage(const Data: TBytes; MaxPixels: Integer; PNGOptions: TPNGDecodeOptions): TRasterImage;
begin
  if (Length(Data) >= 3) and (Data[0] = Ord('G')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F')) then
    Exit(DecodeGIF(Data, MaxPixels));
  if (Length(Data) >= 2) and (Data[0] = $FF) and (Data[1] = $D8) then
    Exit(DecodeJPEG(Data, MaxPixels));
  // The PNG decoder owns signature/structure errors for the established path.
  try
    var PNG := DecodePNG(Data, MaxPixels, PNGOptions);
    Result.Width := PNG.Width;
    Result.Height := PNG.Height;
    Result.Pixels := PNG.Pixels;
  except
    on E: EPNGResourceLimit do
      raise EImageResourceLimit.Create(E.Message);
    on E: EPNGFormat do
      raise EImageFormat.Create(E.Message);
  end;
end;

end.

