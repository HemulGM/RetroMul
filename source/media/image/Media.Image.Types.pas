unit Media.Image.Types;

interface

uses
  System.SysUtils;

type
  EImageFormat = class(Exception);

  EImageResourceLimit = class(EImageFormat);

  TRasterImage = record
    Width, Height: Integer;
    Pixels: TArray<UInt32>; // Unpremultiplied ARGB, top-left origin.
  end;

implementation

end.

