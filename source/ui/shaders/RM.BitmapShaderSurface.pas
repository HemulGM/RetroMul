unit RM.BitmapShaderSurface;

interface

uses
  System.Types, FMX.Graphics, FMX.Types3D, RM.BitmapShaders
  {$IFDEF MSWINDOWS}, RM.BitmapShaders.D2D{$ENDIF};

type
  // One physical display owns its own input texture and LCD history.
  // No FMX controls or timers: the containing view drives both displays once.
  TBitmapShaderSurface = class
  private
    FSource: TBitmap;
    FFilter: TBitmapShaderRenderer;
    FCanvasRenderer: TBitmapShaderCanvasRenderer;
    {$IFDEF MSWINDOWS}
    FD2DRenderer: TD2DBitmapShaderRenderer;
    {$ENDIF}
    FCustomShader: TContextShader;
    FOutput: TBitmap;
    FOutputWidth, FOutputHeight: Integer;
    FDirty: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Invalidate;
    procedure ResetHistory;
    procedure UpdateSource(const Atlas: TBitmap; const Bounds: TRect);
    procedure Draw(const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; const CustomShader: TContextShader; DisableInterpolation: Boolean);
  end;

implementation

uses
  System.SysUtils;

constructor TBitmapShaderSurface.Create;
begin
  inherited;
  FSource := TBitmap.Create;
  FDirty := True;
end;

destructor TBitmapShaderSurface.Destroy;
begin
  FOutput := nil;
  FCanvasRenderer.Free;
  FFilter.Free;
  {$IFDEF MSWINDOWS}
  FD2DRenderer.Free;
  {$ENDIF}
  FSource.Free;
  inherited;
end;

procedure TBitmapShaderSurface.Invalidate;
begin
  FDirty := True;
  if FCanvasRenderer <> nil then
    FCanvasRenderer.InvalidateInput;
end;

procedure TBitmapShaderSurface.ResetHistory;
begin
  if FFilter <> nil then
    FFilter.ResetHistory;
  if FCanvasRenderer <> nil then
    FCanvasRenderer.ResetHistory;
  {$IFDEF MSWINDOWS}
  if FD2DRenderer <> nil then
    FD2DRenderer.ResetHistory;
  {$ENDIF}
  FDirty := True;
end;

procedure TBitmapShaderSurface.UpdateSource(const Atlas: TBitmap; const Bounds: TRect);
begin
  if (FSource.Width <> Bounds.Width) or (FSource.Height <> Bounds.Height) then
  begin
    FSource.SetSize(Bounds.Width, Bounds.Height);
    ResetHistory;
  end;
  FSource.CopyFromBitmap(Atlas, Bounds, 0, 0);
  Invalidate;
end;

procedure TBitmapShaderSurface.Draw(const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; const CustomShader: TContextShader; DisableInterpolation: Boolean);
begin
  if Mode = TBitmapShaderMode.Original then
  begin
    Canvas.DrawBitmap(FSource, FSource.BoundsF, Dest, Opacity, DisableInterpolation);
    Exit;
  end;
  if FCustomShader <> CustomShader then
  begin
    FCustomShader := CustomShader;
    if FFilter <> nil then
      FFilter.CustomShader := CustomShader;
    if (FCanvasRenderer <> nil) and (CustomShader <> nil) then
      FCanvasRenderer.LoadCanvasShader(CustomShader);
    ResetHistory;
  end;
  if (FCanvasRenderer <> nil) and not FCanvasRenderer.SupportsCanvas(Canvas) then
    FreeAndNil(FCanvasRenderer);
  if FCanvasRenderer = nil then
  begin
    FCanvasRenderer := TBitmapShaderCanvasRenderer.CreateForCanvas(Canvas);
    if (FCanvasRenderer <> nil) and (Mode = TBitmapShaderMode.Custom) and (CustomShader <> nil) then
      FCanvasRenderer.LoadCanvasShader(CustomShader);
  end;
  if (FCanvasRenderer <> nil) and FCanvasRenderer.DrawToCanvas(FSource, Canvas, Dest, PixelSize,
    Mode, Settings, Opacity, DeltaMilliseconds) then
  begin
    FDirty := False;
    Exit;
  end;
  if FFilter = nil then
  begin
    FFilter := TBitmapShaderRenderer.Create;
    FFilter.CustomShader := CustomShader;
  end;
  if FFilter.Draw(FSource, Canvas, Dest, PixelSize, Mode, Settings, Opacity, DeltaMilliseconds, FDirty) then
  begin
    FDirty := False;
    Exit;
  end;
  {$IFDEF MSWINDOWS}
  if FD2DRenderer = nil then
    FD2DRenderer := TD2DBitmapShaderRenderer.Create;
  if FD2DRenderer.Draw(FSource, Canvas, Dest, PixelSize, Mode, Settings, Opacity, DeltaMilliseconds, FDirty, CustomShader) then
  begin
    FDirty := False;
    Exit;
  end;
  {$ENDIF}
  if FDirty or (PixelSize.Width <> FOutputWidth) or (PixelSize.Height <> FOutputHeight) then
  begin
    FOutput := FFilter.Render(FSource, PixelSize.Width, PixelSize.Height, Mode, Settings, DeltaMilliseconds);
    FOutputWidth := PixelSize.Width;
    FOutputHeight := PixelSize.Height;
    FDirty := False;
  end;
  Canvas.DrawBitmap(FOutput, FOutput.BoundsF, Dest, Opacity, True);
end;

end.

