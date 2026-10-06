unit RM.FrameUpload;

interface

uses
  System.UITypes, FMX.Graphics;

// Destination is already mapped by the caller; respect its native format/pitch.
procedure UploadFramePixels(const Pixels: array of TAlphaColor; Width, Height: Integer; const Destination: TBitmapData);

implementation

uses
  System.SysUtils, FMX.Types;

procedure UploadFramePixels(const Pixels: array of TAlphaColor; Width, Height: Integer; const Destination: TBitmapData);
begin
  if (Width <= 0) or (Height <= 0) or (Width <> Destination.Width) or
    (Height <> Destination.Height) or (Int64(Width) * Height > Length(Pixels)) or
    (Destination.Data = nil) then
    raise EArgumentException.Create('Invalid frame upload dimensions');

  case Destination.PixelFormat of
    TPixelFormat.BGRA:
      for var Y := 0 to Height - 1 do
        Move(Pixels[Y * Width], Destination.GetScanline(Y)^, Width * SizeOf(TAlphaColor));
    TPixelFormat.RGBA:
      for var Y := 0 to Height - 1 do
      begin
        var Source: PAlphaColor := @Pixels[Y * Width];
        var Output: PAlphaColor := Destination.GetScanline(Y);
        for var X := 0 to Width - 1 do
        begin
          var Color := Source^;
          Output^ := (Color and $FF00FF00) or ((Color and $00FF0000) shr 16) or ((Color and $000000FF) shl 16);
          Inc(Source);
          Inc(Output);
        end;
      end;
  else
    for var Y := 0 to Height - 1 do
      AlphaColorToScanline(@Pixels[Y * Width], Destination.GetScanline(Y),
        Width, Destination.PixelFormat);
  end;
end;

end.

