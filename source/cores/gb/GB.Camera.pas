unit GB.Camera;

interface

uses
  System.SysUtils, System.SyncObjs, Core.Snapshots;

const
  GB_CAMERA_SENSOR_WIDTH = 128;
  GB_CAMERA_SENSOR_HEIGHT = 128;
  GB_CAMERA_IMAGE_HEIGHT = 112;
  GB_CAMERA_SENSOR_MARGIN = 8;

type
  // Row-major sensor output, top to bottom. 0 = black, 255 = white.
  // Values are before the cartridge's 2-bit threshold/dither conversion.
  TGBCameraFrame = record
    Pixels: array[0..GB_CAMERA_SENSOR_WIDTH * GB_CAMERA_SENSOR_HEIGHT - 1] of Byte;
    class function Neutral: TGBCameraFrame; static;
  end;

  IGBCameraFrameSource = interface
    ['{D664B224-177A-4A84-A79C-CF7EAA6586A9}']
    procedure SubmitFrame(const Frame: TGBCameraFrame);
    procedure CopyFrame(out Frame: TGBCameraFrame);
  end;

  // Optional capability of GB/GBC adapters; use Supports on IEmulationCore.
  IGBCameraInput = interface
    ['{708A4C69-1595-4C44-9A1C-129AAE1221EB}']
    function GetHasCamera: Boolean;
    procedure SubmitCameraFrame(const Frame: TGBCameraFrame);
    property HasCamera: Boolean read GetHasCamera;
  end;

  TGBCameraFrameSource = class(TInterfacedObject, IGBCameraFrameSource)
  private
    FLock: TCriticalSection;
    FFrame: TGBCameraFrame;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SubmitFrame(const Frame: TGBCameraFrame);
    procedure CopyFrame(out Frame: TGBCameraFrame);
  end;

  TGBCameraController = class
  private
    FSource: IGBCameraFrameSource;
    FCaptureFrame: TGBCameraFrame;
  public
    constructor Create(const Source: IGBCameraFrameSource = nil);
    // Thread-safe producer entry point. The controller keeps a copy.
    procedure SubmitFrame(const Frame: TGBCameraFrame);
    // Called by the emulation thread once per NEW capture, not on resume.
    procedure BeginCapture;
    function BuildTiles(const Registers: array of Byte): TBytes;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

class function TGBCameraFrame.Neutral: TGBCameraFrame;
begin
  FillChar(Result.Pixels, SizeOf(Result.Pixels), 128);
end;

constructor TGBCameraFrameSource.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FFrame := TGBCameraFrame.Neutral;
end;

destructor TGBCameraFrameSource.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TGBCameraFrameSource.SubmitFrame(const Frame: TGBCameraFrame);
begin
  FLock.Acquire;
  try
    FFrame := Frame;
  finally
    FLock.Release;
  end;
end;

procedure TGBCameraFrameSource.CopyFrame(out Frame: TGBCameraFrame);
begin
  FLock.Acquire;
  try
    Frame := FFrame;
  finally
    FLock.Release;
  end;
end;

constructor TGBCameraController.Create(const Source: IGBCameraFrameSource);
begin
  inherited Create;
  FSource := Source;
  if FSource = nil then
    FSource := TGBCameraFrameSource.Create;
  FCaptureFrame := TGBCameraFrame.Neutral;
end;

procedure TGBCameraController.SubmitFrame(const Frame: TGBCameraFrame);
begin
  FSource.SubmitFrame(Frame);
end;

procedure TGBCameraController.BeginCapture;
begin
  FSource.CopyFrame(FCaptureFrame);
end;

function TGBCameraController.BuildTiles(const Registers: array of Byte): TBytes;
begin
  if Length(Registers) < $36 then
    raise EArgumentException.Create('Camera requires 54 capture registers');
  SetLength(Result, 16 * 14 * 16);
  FillChar(Result[0], Length(Result), 0);
  // Pan Docs: the sensor transfers 128x128; the cart discards 8 rows at each end.
  // https://gbdev.io/pandocs/Gameboy_Camera.html
  for var Y := 0 to GB_CAMERA_IMAGE_HEIGHT - 1 do
    for var X := 0 to GB_CAMERA_SENSOR_WIDTH - 1 do
    begin
      var Level := FCaptureFrame.Pixels[(Y + GB_CAMERA_SENSOR_MARGIN) * GB_CAMERA_SENSOR_WIDTH + X];
      var Threshold := 6 + ((Y and 3) * 4 + (X and 3)) * 3;
      var Color := 0;
      for var I := 0 to 2 do
        if Level < Registers[Threshold + I] then
          Inc(Color);
      var Offset := ((Y shr 3) * 16 + (X shr 3)) * 16 + (Y and 7) * 2;
      var Mask := 1 shl (7 - (X and 7));
      if (Color and 1) <> 0 then
        Result[Offset] := Result[Offset] or Mask;
      if (Color and 2) <> 0 then
        Result[Offset + 1] := Result[Offset + 1] or Mask;
    end;
end;

procedure TGBCameraController.SerializeState(State: TStateArchive);
begin
  // The in-flight exposure is emulated state; the latest live input is not.
  State.Field(FCaptureFrame.Pixels, SizeOf(FCaptureFrame.Pixels));
end;

end.

