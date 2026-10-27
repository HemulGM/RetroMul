unit RM.ShaderBitmap;

interface

uses
  System.Classes, System.IniFiles, System.Types, System.Math.Vectors, FMX.Types,
  FMX.Controls, FMX.Objects, FMX.Graphics, FMX.Types3D, FMX.DisplayLink,
  {$IFDEF MSWINDOWS}
  RM.BitmapShaders.D2D,
  {$ENDIF}
  RM.BitmapShaders;

// Align the final blit in physical canvas pixels, including fractional parent
// offsets and DPI. PixelSize is also the exact shader render-target size.
function AlignBitmapOutput(const Bounds: TRectF; const Matrix: TMatrix; Scale: Single; out PixelSize: TSize): TRectF;

// Follow real 60/120 Hz cadence, including panel clock drift. Other refresh
// rates retain an average 60 FPS target through phase accumulation.
function BitmapFrameDue(const Time, DeltaTime: Double; var NextFrameTime: Double): Boolean;

type
  // Owns Bitmap; changing Bitmap or Settings invalidates the cached GPU output.
  TShaderBitmap = class(TImage)
  private
    FFilter: TBitmapShaderRenderer;
    FCanvasRenderer: TBitmapShaderCanvasRenderer;
    {$IFDEF MSWINDOWS}
    FD2DRenderer: TD2DBitmapShaderRenderer;
    {$ENDIF}
    FMode: TBitmapShaderMode;
    FSettings: TBitmapShaderSettings;
    FDirty: Boolean;
    FOutput: TBitmap;
    FOutputWidth, FOutputHeight: Integer;
    FResponseTimer: TTimer;
    FResponseLink: IFMXDisplayLinkService;
    FResponseSubscribed: Boolean;
    FNextResponseTime: Double;
    FLastPaintMS, FResponseDeadlineMS: Double;
    procedure SetResponseClock(Enabled: Boolean);
    procedure ResponseFrame(const Time, DeltaTime: Double);
    procedure ResponseTimerTick(Sender: TObject);
    procedure WakeResponse;
    procedure EnsureShaderResources;
    procedure ReleaseShaderResources;
    procedure SetMode(Value: TBitmapShaderMode);
    procedure SetSettings(const Value: TBitmapShaderSettings);
  protected
    procedure Paint; override;
    procedure DoChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure InvalidateFrame;
    procedure ResetHistory;
    procedure LoadShaderFromFile(const FileName: string);
    procedure LoadSettings(Ini: TCustomIniFile);
    property Mode: TBitmapShaderMode read FMode write SetMode;
    property Settings: TBitmapShaderSettings read FSettings write SetSettings;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.UITypes, System.Math,
  System.Diagnostics, FMX.Platform;

function ClockMilliseconds: Double;
begin
  Result := TStopwatch.GetTimeStamp * (1000.0 / TStopwatch.Frequency);
end;

function BitmapFrameDue(const Time, DeltaTime: Double; var NextFrameTime: Double): Boolean;
var
  Period: Double;
  Divisor: Integer;
begin
  Result := False;
  if DeltaTime <= 0 then
    Exit;
  if (NextFrameTime = 0) or (Time - NextFrameTime > 0.25) then
    NextFrameTime := Time;
  if Time + 0.001 < NextFrameTime then
    Exit;
  Divisor := Max(1, Round(1 / (60 * DeltaTime)));
  Period := DeltaTime * Divisor;
  if Abs(Period - 1 / 60) < 0.002 then
    NextFrameTime := Time + Period
  else
    repeat
      NextFrameTime := NextFrameTime + 1 / 60
    until NextFrameTime > Time + 0.001;
  Result := True;
end;

function AlignBitmapOutput(const Bounds: TRectF; const Matrix: TMatrix; Scale: Single; out PixelSize: TSize): TRectF;
var
  SX, SY: Single;
begin
  Result := Bounds;
  PixelSize := TSize.Create(Max(1, Round(Bounds.Width * Scale)),
    Max(1, Round(Bounds.Height * Scale)));
  // Rotated/sheared controls retain normal FMX geometry.
  if (Abs(Matrix.m12) > 0.00001) or (Abs(Matrix.m21) > 0.00001) or
    (Matrix.m11 <= 0) or (Matrix.m22 <= 0) or (Scale <= 0) then
    Exit;
  SX := Matrix.m11 * Scale;
  SY := Matrix.m22 * Scale;
  PixelSize := TSize.Create(Max(1, Round(Bounds.Width * SX)),
    Max(1, Round(Bounds.Height * SY)));
  Result.Left := (Round((Bounds.Left * Matrix.m11 + Matrix.m31) * Scale) /
    Scale - Matrix.m31) / Matrix.m11;
  Result.Top := (Round((Bounds.Top * Matrix.m22 + Matrix.m32) * Scale) /
    Scale - Matrix.m32) / Matrix.m22;
  Result.Right := Result.Left + PixelSize.Width / SX;
  Result.Bottom := Result.Top + PixelSize.Height / SY;
end;

constructor TShaderBitmap.Create(AOwner: TComponent);
begin
  inherited;
  FSettings := TBitmapShaderSettings.Default;
  DisableInterpolation := True;
  FLastPaintMS := ClockMilliseconds;
  FDirty := True;
  HitTest := False;
end;

destructor TShaderBitmap.Destroy;
begin
  ReleaseShaderResources;
  inherited;
end;

procedure TShaderBitmap.EnsureShaderResources;
begin
  if FResponseTimer = nil then
  begin
    FResponseTimer := TTimer.Create(Self);
    FResponseTimer.Enabled := False;
    FResponseTimer.Interval := 16;
    FResponseTimer.OnTimer := ResponseTimerTick;
    WakeResponse;
  end;
end;

procedure TShaderBitmap.ReleaseShaderResources;
begin
  SetResponseClock(False);
  FResponseLink := nil;
  FreeAndNil(FResponseTimer);
  FOutput := nil;
  FreeAndNil(FFilter);
  FreeAndNil(FCanvasRenderer);
  {$IFDEF MSWINDOWS}
  FreeAndNil(FD2DRenderer);
  {$ENDIF}
  FOutputWidth := 0;
  FOutputHeight := 0;
end;

procedure TShaderBitmap.LoadSettings(Ini: TCustomIniFile);
var
  Value, FileName: string;
  NextMode: TBitmapShaderMode;
  Options: TBitmapShaderSettings;
begin
  Value := Ini.ReadString('Shaders', 'Mode', 'off');
  NextMode := TBitmapShaderMode.Original;
  if SameText(Value, 'scanlines') then
    NextMode := TBitmapShaderMode.Scanlines
  else if SameText(Value, 'crt') then
    NextMode := TBitmapShaderMode.CRT
  else if SameText(Value, 'lcd') then
    NextMode := TBitmapShaderMode.LCD
  else if SameText(Value, 'color') then
    NextMode := TBitmapShaderMode.ColorCorrection;
  Options := TBitmapShaderSettings.Default;
  Options.ScanlineStrength := EnsureRange(Ini.ReadInteger('Shaders', 'Scanlines', 35), 0, 100) / 100;
  Options.Curvature := EnsureRange(Ini.ReadInteger('Shaders', 'Curvature', 8), 0, 30) / 100;
  Options.MaskStrength := EnsureRange(Ini.ReadInteger('Shaders', 'Mask', 65), 0, 100) / 100;
  Options.Glow := EnsureRange(Ini.ReadInteger('Shaders', 'Glow', 20), 0, 100) / 100;
  Options.LCDGridStrength := EnsureRange(Ini.ReadInteger('Shaders', 'LCDGrid', 35), 0, 100) / 100;
  Options.LCDResponseMS := EnsureRange(Ini.ReadInteger('Shaders', 'LCDResponseMS', 65), 0, 500);
  Options.Gamma := EnsureRange(Ini.ReadInteger('Shaders', 'Gamma', 100), 25, 400) / 100;
  Options.Saturation := EnsureRange(Ini.ReadInteger('Shaders', 'Saturation', 100), 0, 200) / 100;
  Options.Temperature := EnsureRange(Ini.ReadInteger('Shaders', 'Temperature', 100), 0, 200) / 100 - 1;
  Settings := Options;
  if SameText(Value, 'custom') then
  begin
    FileName := Ini.ReadString('Shaders', 'File', '').Trim;
    if FileName <> '' then
    begin
      if not System.IOUtils.TPath.IsPathRooted(FileName) then
        FileName := System.IOUtils.TPath.Combine(System.IOUtils.TPath.GetDocumentsPath, FileName);
      try
        LoadShaderFromFile(FileName);
      except
        Mode := TBitmapShaderMode.Original;
        ReleaseShaderResources;
        raise;
      end;
      ResetHistory;
      Exit;
    end;
  end;
  Mode := NextMode;
  ResetHistory;
end;

procedure TShaderBitmap.InvalidateFrame;
begin
  FDirty := True;
  if FCanvasRenderer <> nil then
    FCanvasRenderer.InvalidateInput;
  WakeResponse;
  Repaint;
end;

procedure TShaderBitmap.WakeResponse;
begin
  if FResponseTimer = nil then
    Exit;
  FResponseDeadlineMS := ClockMilliseconds + Min(FSettings.LCDResponseMS, 500) * 8;
  SetResponseClock((FMode = TBitmapShaderMode.LCD) and
    (FSettings.LCDResponseMS > 0) and not Bitmap.IsEmpty);
end;

procedure TShaderBitmap.SetResponseClock(Enabled: Boolean);
begin
  if FResponseSubscribed and not Enabled then
  begin
    FResponseLink.Unsubscribe(ResponseFrame);
    FResponseSubscribed := False;
  end;
  if FResponseTimer <> nil then
    FResponseTimer.Enabled := False;
  if not Enabled then
    Exit;
  if FResponseLink = nil then
    TPlatformServices.Current.SupportsPlatformService(IFMXDisplayLinkService, FResponseLink);
  if FResponseLink <> nil then
  begin
    if not FResponseSubscribed then
    begin
      FNextResponseTime := 0;
      FResponseLink.Subscribe(ResponseFrame);
      FResponseSubscribed := True;
    end;
  end
  else
    FResponseTimer.Enabled := True;
end;

procedure TShaderBitmap.ResponseFrame(const Time, DeltaTime: Double);
begin
  if BitmapFrameDue(Time, DeltaTime, FNextResponseTime) then
    ResponseTimerTick(nil);
end;

procedure TShaderBitmap.ResponseTimerTick(Sender: TObject);
begin
  if ClockMilliseconds >= FResponseDeadlineMS then
  begin
    SetResponseClock(False);
    if FFilter <> nil then
      FFilter.ResetHistory;
    if FCanvasRenderer <> nil then
      FCanvasRenderer.ResetHistory;
    {$IFDEF MSWINDOWS}
    if FD2DRenderer <> nil then
      FD2DRenderer.ResetHistory;
    {$ENDIF}
  end;
  FDirty := True;
  Repaint;
end;

procedure TShaderBitmap.ResetHistory;
begin
  if FFilter <> nil then
    FFilter.ResetHistory;
  if FCanvasRenderer <> nil then
    FCanvasRenderer.ResetHistory;
  {$IFDEF MSWINDOWS}
  if FD2DRenderer <> nil then
    FD2DRenderer.ResetHistory;
  {$ENDIF}
  FLastPaintMS := ClockMilliseconds;
  InvalidateFrame;
end;

procedure TShaderBitmap.LoadShaderFromFile(const FileName: string);
begin
  EnsureShaderResources;
  if FFilter = nil then
    FFilter := TBitmapShaderRenderer.Create;
  FFilter.LoadCustomShader(FileName);
  if FCanvasRenderer <> nil then
    FCanvasRenderer.LoadCanvasShader(FFilter.CustomShader);
  Mode := TBitmapShaderMode.Custom;
  InvalidateFrame;
end;

procedure TShaderBitmap.DoChanged;
begin
  inherited;
  if FMode <> TBitmapShaderMode.Original then
    InvalidateFrame;
end;

procedure TShaderBitmap.SetMode(Value: TBitmapShaderMode);
begin
  if FMode <> Value then
  begin
    if Value = TBitmapShaderMode.Original then
      ReleaseShaderResources;
    FMode := Value;
    if FFilter <> nil then
      FFilter.ResetHistory;
    if FCanvasRenderer <> nil then
      FCanvasRenderer.ResetHistory;
    {$IFDEF MSWINDOWS}
    if FD2DRenderer <> nil then
      FD2DRenderer.ResetHistory;
    {$ENDIF}
    InvalidateFrame;
  end;
end;

procedure TShaderBitmap.SetSettings(const Value: TBitmapShaderSettings);
begin
  FSettings := Value;
  InvalidateFrame;
end;

procedure TShaderBitmap.Paint;
var
  Dest: TRectF;
  Fit: Single;
  W, H: Integer;
  PixelSize: TSize;
  NowMS: Double;
begin
  if FMode = TBitmapShaderMode.Original then
  begin
    inherited;
    Exit;
  end;
  EnsureShaderResources;
  Canvas.Fill.Color := TAlphaColors.Black;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  if Bitmap.IsEmpty or (Width <= 0) or (Height <= 0) then
    Exit;
  Fit := Min(Width / Bitmap.Width, Height / Bitmap.Height);
  Dest := TRectF.Create(0, 0, Bitmap.Width * Fit, Bitmap.Height * Fit);
  Dest.Offset((Width - Dest.Width) * 0.5, (Height - Dest.Height) * 0.5);
  Dest := AlignBitmapOutput(Dest, Canvas.Matrix, Canvas.Scale, PixelSize);
  W := PixelSize.Width;
  H := PixelSize.Height;
  NowMS := ClockMilliseconds;

  if (FCanvasRenderer <> nil) and not FCanvasRenderer.SupportsCanvas(Canvas) then
    FreeAndNil(FCanvasRenderer);
  if FCanvasRenderer = nil then
  begin
    FCanvasRenderer := TBitmapShaderCanvasRenderer.CreateForCanvas(Canvas);
    if (FCanvasRenderer <> nil) and (FMode = TBitmapShaderMode.Custom) and
      (FFilter <> nil) and (FFilter.CustomShader <> nil) then
      FCanvasRenderer.LoadCanvasShader(FFilter.CustomShader);
  end;
  if (FCanvasRenderer <> nil) and FCanvasRenderer.DrawToCanvas(Bitmap, Canvas, Dest, PixelSize, FMode, FSettings,
    AbsoluteOpacity, Max(0.0, NowMS - FLastPaintMS)) then
  begin
    FLastPaintMS := NowMS;
    FDirty := False;
    Exit;
  end;
  if FFilter = nil then
    FFilter := TBitmapShaderRenderer.Create;
  if FFilter.Draw(Bitmap, Canvas, Dest, PixelSize, FMode, FSettings,
    AbsoluteOpacity, Max(0.0, NowMS - FLastPaintMS), FDirty) then
  begin
    FLastPaintMS := NowMS;
    FDirty := False;
    Exit;
  end;
  {$IFDEF MSWINDOWS}
  if FD2DRenderer = nil then
    FD2DRenderer := TD2DBitmapShaderRenderer.Create;
  if FD2DRenderer.Draw(Bitmap, Canvas, Dest, PixelSize, FMode, FSettings,
    AbsoluteOpacity, Max(0.0, NowMS - FLastPaintMS), FDirty, FFilter.CustomShader) then
  begin
    FLastPaintMS := NowMS;
    FDirty := False;
    Exit;
  end;
  {$ENDIF}
  // Raster/export canvases still require a bitmap result.
  if FDirty or (W <> FOutputWidth) or (H <> FOutputHeight) then
  begin
    NowMS := ClockMilliseconds;
    FOutput := FFilter.Render(Bitmap, W, H, FMode, FSettings,
      Max(0.0, NowMS - FLastPaintMS));
    FLastPaintMS := NowMS;
    FOutputWidth := W;
    FOutputHeight := H;
    FDirty := False;
  end;
  Canvas.DrawBitmap(FOutput, TRectF.Create(0, 0, FOutput.Width, FOutput.Height),
    Dest, AbsoluteOpacity, True);
end;

end.

