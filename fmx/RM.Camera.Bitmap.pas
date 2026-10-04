unit RM.Camera.Bitmap;

interface

uses
  FMX.Graphics, GB.Camera;

// Scale to fill the sensor, preserve aspect ratio, crop equally on both sides.
// Downscaling uses area averaging; upscaling uses bilinear interpolation.
// The source bitmap is read-only; transparent pixels are composited over black.
function BitmapToGBCameraFrame(const Bitmap: TBitmap): TGBCameraFrame;

type
  TBitmapCameraHelper = class helper for TBitmap
    function ToGBCameraFrame: TGBCameraFrame;
    procedure SubmitToGBCamera(const CameraInput: IGBCameraInput);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math, System.UITypes;

function BitmapToGBCameraFrame(const Bitmap: TBitmap): TGBCameraFrame;
var
  Data: TBitmapData;

  function Gray(X, Y: Integer): Double;
  begin
    var Color := TAlphaColorRec(Data.GetPixel(X, Y));
    // FMX mapped RGB components are premultiplied, so they already represent
    // the color composited over black. Do not multiply by alpha a second time.
    if Color.A = 0 then
      Exit(0);
    Result := (Integer(Color.R) * 77 + Integer(Color.G) * 150 + Integer(Color.B) * 29) / 256;
  end;

begin
  if Bitmap = nil then
    raise EArgumentNilException.Create('Bitmap must not be nil');
  if (Bitmap.Width <= 0) or (Bitmap.Height <= 0) then
    raise EArgumentException.Create('Bitmap must not be empty');
  if not Bitmap.Map(TMapAccess.Read, Data) then
    raise EReadError.Create('Cannot map camera bitmap for reading');

  try
    var Scale := Max(GB_CAMERA_SENSOR_WIDTH / Bitmap.Width, GB_CAMERA_SENSOR_HEIGHT / Bitmap.Height);
    var Step := 1 / Scale;
    var Left := (Bitmap.Width - GB_CAMERA_SENSOR_WIDTH * Step) / 2;
    var Top := (Bitmap.Height - GB_CAMERA_SENSOR_HEIGHT * Step) / 2;
    for var Y := 0 to GB_CAMERA_SENSOR_HEIGHT - 1 do
      for var X := 0 to GB_CAMERA_SENSOR_WIDTH - 1 do
      begin
        var Level: Double;
        if Step > 1 then
        begin
          var X0 := Left + X * Step;
          var X1 := X0 + Step;
          var Y0 := Top + Y * Step;
          var Y1 := Y0 + Step;
          Level := 0;
          for var SY := Max(0, Integer(Floor(Y0))) to Min(Bitmap.Height - 1, Integer(Ceil(Y1)) - 1) do
          begin
            var WY := Min(Y1, SY + 1.0) - Max(Y0, Double(SY));
            for var SX := Max(0, Integer(Floor(X0))) to Min(Bitmap.Width - 1, Integer(Ceil(X1)) - 1) do
            begin
              var WX := Min(X1, SX + 1.0) - Max(X0, Double(SX));
              Level := Level + Gray(SX, SY) * WX * WY;
            end;
          end;
          Level := Level / (Step * Step);
        end
        else
        begin
          var FX := EnsureRange(Left + (X + 0.5) * Step - 0.5, 0.0, Bitmap.Width - 1.0);
          var FY := EnsureRange(Top + (Y + 0.5) * Step - 0.5, 0.0, Bitmap.Height - 1.0);
          var SX := Integer(Floor(FX));
          var SY := Integer(Floor(FY));
          var NX := Min(SX + 1, Bitmap.Width - 1);
          var NY := Min(SY + 1, Bitmap.Height - 1);
          var DX := FX - SX;
          var DY := FY - SY;
          Level := (Gray(SX, SY) * (1 - DX) + Gray(NX, SY) * DX) * (1 - DY) + (Gray(SX, NY) * (1 - DX) + Gray(NX, NY) * DX) * DY;
        end;
        Result.Pixels[Y * GB_CAMERA_SENSOR_WIDTH + X] := EnsureRange(Integer(Floor(Level + 0.5)), 0, 255);
      end;
  finally
    Bitmap.Unmap(Data);
  end;
end;

function TBitmapCameraHelper.ToGBCameraFrame: TGBCameraFrame;
begin
  Result := BitmapToGBCameraFrame(Self);
end;

procedure TBitmapCameraHelper.SubmitToGBCamera(const CameraInput: IGBCameraInput);
begin
  if CameraInput = nil then
    raise EArgumentNilException.Create('Camera input must not be nil');
  if not CameraInput.HasCamera then
    raise ENotSupportedException.Create('Cartridge has no camera');

  CameraInput.SubmitCameraFrame(ToGBCameraFrame);
end;

end.

