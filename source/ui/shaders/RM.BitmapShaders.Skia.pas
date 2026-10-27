unit RM.BitmapShaders.Skia;

interface

uses
  System.SysUtils, System.Types, System.Skia, FMX.Graphics, FMX.Types3D,
  RM.BitmapShaders;

type
  // UI-thread renderer. Draw into the active window canvas to keep SkSL on GPU.
  // TBitmap.Canvas is raster-backed even when its class is TVkCanvas.
  TSkBitmapShaderRenderer = class(TBitmapShaderCanvasRenderer)
  private
    FBuiltin, FCustom: ISkRuntimeShaderBuilder;
    FInput, FHistory: ISkImage;
    FInputSurface: ISkSurface;
    FHistorySurfaces: array[0..1] of ISkSurface;
    FHistoryIndex: Integer;
    FInputDirty: Boolean;
    FSurfaceAllocationCount: Integer;
    FSurfaceSize: TSize;
    FPaint, FResponsePaint: ISkPaint;
    FSource: TBitmap;
    FContext: IGrDirectContext;
    procedure ClearChildren;
    procedure EnsureSurfaces(const Size: TSize; const Context: IGrDirectContext);
    class function CreateBuilder(const Code: string): ISkRuntimeShaderBuilder; static;
    procedure SetParameters(const Builder: ISkRuntimeShaderBuilder; const SourceSize, OutputSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Pass, Weight: Single);
  public
    property SurfaceAllocationCount: Integer read FSurfaceAllocationCount;
    class function SupportsCanvas(const Canvas: TCanvas): Boolean; override;
    procedure InvalidateInput; override;
    procedure ResetHistory; override;
    procedure LoadCanvasShader(const Shader: TContextShader); override;
    procedure LoadCustomShader(const Source: TContextShaderSource);
    function DrawToCanvas(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single): Boolean; override;
    function Draw(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; const GPUContext: IGrDirectContext = nil): Boolean;
  end;

implementation

uses
  System.Math, FMX.Skia, FMX.Skia.Canvas, RM.BitmapShaderSources;

class function TSkBitmapShaderRenderer.SupportsCanvas(const Canvas: TCanvas): Boolean;
begin
  Result := Canvas is TSkCanvasCustom;
end;

function TSkBitmapShaderRenderer.DrawToCanvas(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single): Boolean;
begin
  Result := Draw(Source, Canvas, Dest, PixelSize, Mode, Settings, Opacity, DeltaMilliseconds);
end;

class function TSkBitmapShaderRenderer.CreateBuilder(const Code: string): ISkRuntimeShaderBuilder;
var
  Effect: ISkRuntimeEffect;
  Error: string;
begin
  Effect := TSkRuntimeEffect.MakeForShader(Code, Error);
  if Effect = nil then
    raise EInvalidOpException.Create('SkSL: ' + Error);
  Result := TSkRuntimeShaderBuilder.Create(Effect);
end;

procedure TSkBitmapShaderRenderer.InvalidateInput;
begin
  FInputDirty := True;
end;

procedure TSkBitmapShaderRenderer.ResetHistory;
begin
  ClearChildren;
  FHistory := nil;
end;

procedure TSkBitmapShaderRenderer.ClearChildren;

  procedure Clear(const Builder: ISkRuntimeShaderBuilder);
  begin
    if Builder = nil then
      Exit;
    if Builder.Effect.ChildExists('Input') then
      Builder.SetChild('Input', ISkShader(nil));
    if Builder.Effect.ChildExists('Target') then
      Builder.SetChild('Target', ISkShader(nil));
  end;

begin
  if FPaint <> nil then
    FPaint.Shader := nil;
  if FResponsePaint <> nil then
    FResponsePaint.Shader := nil;
  Clear(FBuiltin);
  Clear(FCustom);
end;

procedure TSkBitmapShaderRenderer.EnsureSurfaces(const Size: TSize; const Context: IGrDirectContext);
var
  Info: TSkImageInfo;

  function Surface: ISkSurface;
  begin
    if Context <> nil then
      Result := TSkSurface.MakeRenderTarget(Context, False, Info)
    else
      Result := TSkSurface.MakeRaster(Info);
    if Result = nil then
      raise EInvalidOpException.Create('Cannot allocate shader surface.');
  end;

begin
  if (FInputSurface <> nil) and (FSurfaceSize = Size) and (FContext = Context) then
    Exit;
  ClearChildren;
  FInput := nil;
  FHistory := nil;
  FInputSurface := nil;
  FHistorySurfaces[0] := nil;
  FHistorySurfaces[1] := nil;
  FContext := Context;
  FSurfaceSize := Size;
  Info := TSkImageInfo.Create(Size.Width, Size.Height, TSkColorType.RGBA8888);
  FInputSurface := Surface;
  Inc(FSurfaceAllocationCount);
  // History surfaces are allocated lazily, only for temporal LCD mode.
  FInputDirty := True;
end;

procedure TSkBitmapShaderRenderer.LoadCanvasShader(const Shader: TContextShader);
begin
  LoadCustomShader(Shader.GetSourceByArch(TContextShaderArch.SKSL));
end;

procedure TSkBitmapShaderRenderer.LoadCustomShader(const Source: TContextShaderSource);
var
  Builder: ISkRuntimeShaderBuilder;
begin
  Builder := nil;
  if Source.IsDefined then
    Builder := CreateBuilder(TEncoding.UTF8.GetString(Source.Code));
  // Replace only after compilation succeeds.
  FCustom := Builder;
end;

procedure TSkBitmapShaderRenderer.SetParameters(const Builder: ISkRuntimeShaderBuilder; const SourceSize, OutputSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Pass, Weight: Single);

  procedure Vector(const Name: string; X, Y, Z, W: Single);
  begin
    if Builder.Effect.UniformExists(Name) then
      Builder.SetUniform(Name, TSkRuntimeEffectFloat4.Create(X, Y, Z, W));
  end;

begin
  Vector('SourceSize', SourceSize.Width, SourceSize.Height, 0, 0);
  Vector('OutputSize', OutputSize.Width, OutputSize.Height, 0, 0);
  Vector('Controls', EnsureRange(Settings.ScanlineStrength, 0.0, 1.0),
    EnsureRange(Settings.Curvature, 0.0, 0.3), EnsureRange(Settings.MaskStrength, 0.0, 1.0),
    EnsureRange(Settings.Glow, 0.0, 1.0));
  Vector('ModeState', Ord(Mode), Pass, Weight, 0);
  Vector('LCDControls', EnsureRange(Settings.LCDGridStrength, 0.0, 1.0), 0, 0, 0);
  Vector('ColorControls', EnsureRange(Settings.Gamma, 0.25, 4.0),
    EnsureRange(Settings.Saturation, 0.0, 2.0), EnsureRange(Settings.Temperature, -1.0, 1.0), 0);
end;

function TSkBitmapShaderRenderer.Draw(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; const GPUContext: IGrDirectContext): Boolean;
var
  Builder: ISkRuntimeShaderBuilder;
  Context: IGrDirectContext;
  SkCanvas: ISkCanvas;
  Image: ISkImage;
  InputShader: ISkShader;
  Data: TBitmapData;
  Next: Integer;
  Info: TSkImageInfo;
begin
  Result := False;
  if not (Canvas is TSkCanvasCustom) or (Mode = TBitmapShaderMode.Original) then
    Exit;
  if Mode = TBitmapShaderMode.Custom then
  begin
    Builder := FCustom;
    if Builder = nil then
      Exit;
  end
  else
  begin
    if FBuiltin = nil then
      FBuiltin := CreateBuilder(BuiltinBitmapShaderText(TContextShaderArch.SKSL));
    Builder := FBuiltin;
  end;
  if (Source = nil) or Source.IsEmpty then
    Exit;
  Context := GPUContext;
  // FMX bitmap canvases are raster surfaces. A GPU image belongs to its context;
  // never reuse that history for a screenshot/raster canvas or a recreated window.
  if (Context = nil) and (Canvas is TGrCanvas) and (Canvas.Bitmap = nil) then
    Context := TGrCanvas(Canvas).GrDirectContext;
  // Flush previously queued draws before releasing their snapshots. Otherwise
  // Skia may preserve those snapshots by copying a surface on its next write.
  if Context <> nil then
    Context.Flush;
  ClearChildren;
  EnsureSurfaces(Source.Size, Context);
  if FSource <> Source then
  begin
    ResetHistory;
    FInputDirty := True;
  end;
  if FInputDirty or (FInput = nil) then
  begin
    FInput := nil;
    if not Source.Map(TMapAccess.Read, Data) then
      raise EInvalidOpException.Create('Cannot map shader input.');
    try
      // Upload directly into the existing surface; no intermediate raster SkImage.
      FInputSurface.WritePixels(TSkImageInfo.Create(Source.Width, Source.Height,
          SkFmxColorType[Data.PixelFormat]), Data.Data, Data.Pitch);
    finally
      Source.Unmap(Data);
    end;
    FInput := FInputSurface.MakeImageSnapshot;
    FInputDirty := False;
    FSource := Source;
  end;
  Image := FInput;
  InputShader := Image.MakeShader(TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None));
  if Builder.Effect.ChildExists('Input') then
    Builder.SetChild('Input', InputShader);
  if Builder.Effect.ChildExists('Target') then
    Builder.SetChild('Target', InputShader);
  if (Mode = TBitmapShaderMode.LCD) and (Settings.LCDResponseMS > 0) then
  begin
    if (FHistorySurfaces[0] = nil) or (FHistorySurfaces[1] = nil) then
    begin
      Info := TSkImageInfo.Create(Source.Width, Source.Height, TSkColorType.RGBA8888);
      if Context <> nil then
      begin
        FHistorySurfaces[0] := TSkSurface.MakeRenderTarget(Context, False, Info);
        FHistorySurfaces[1] := TSkSurface.MakeRenderTarget(Context, False, Info);
      end
      else
      begin
        FHistorySurfaces[0] := TSkSurface.MakeRaster(Info);
        FHistorySurfaces[1] := TSkSurface.MakeRaster(Info);
      end;
      if (FHistorySurfaces[0] = nil) or (FHistorySurfaces[1] = nil) then
        raise EInvalidOpException.Create('Cannot allocate LCD history surfaces.');
      Inc(FSurfaceAllocationCount, 2);
    end;
    if FHistory = nil then
    begin
      FHistoryIndex := 0;
      FHistorySurfaces[0].Canvas.Clear(0);
      FHistorySurfaces[0].Canvas.DrawImage(FInput, 0, 0);
      FHistory := FHistorySurfaces[0].MakeImageSnapshot;
    end
    else if DeltaMilliseconds > 0 then
    begin
      Next := 1 - FHistoryIndex;
      SetParameters(Builder, Source.Size, Source.Size, Mode, Settings, 1,
        Exp(-DeltaMilliseconds / Min(Settings.LCDResponseMS, 500)));
      Builder.SetChild('Target', FHistory.MakeShader(TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None)));
      if FResponsePaint = nil then
      begin
        FResponsePaint := TSkPaint.Create;
        FResponsePaint.Blender := TSkBlender.MakeMode(TSkBlendMode.Src);
      end;
      FResponsePaint.Shader := Builder.MakeShader;
      FHistorySurfaces[Next].Canvas.DrawRect(TRectF.Create(0, 0, Source.Width, Source.Height), FResponsePaint);
      FResponsePaint.Shader := nil;
      Builder.SetChild('Target', ISkShader(nil));
      FHistory := nil;
      FHistory := FHistorySurfaces[Next].MakeImageSnapshot;
      FHistoryIndex := Next;
      if (Context <> nil) and not FHistory.IsTextureBacked then
        raise EInvalidOpException.Create('Skia LCD history must stay on GPU.');
    end;
    Image := FHistory;
    Builder.SetChild('Input', Image.MakeShader(TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None)));
  end
  else
    FHistory := nil;
  SetParameters(Builder, Source.Size, PixelSize, Mode, Settings, 2, 0);
  if FPaint = nil then
    FPaint := TSkPaint.Create;
  FPaint.Blender := nil;
  FPaint.Shader := Builder.MakeShader;
  FPaint.AlphaF := Opacity;
  SkCanvas := TSkCanvasCustom(Canvas).Canvas;
  SkCanvas.Save;
  try
    SkCanvas.Translate(Dest.Left, Dest.Top);
    SkCanvas.Scale(Dest.Width / PixelSize.Width, Dest.Height / PixelSize.Height);
    SkCanvas.DrawRect(TRectF.Create(0, 0, PixelSize.Width, PixelSize.Height), FPaint);
  finally
    SkCanvas.Restore;
    ClearChildren;
  end;
  Result := True;
end;

initialization
  TBitmapShaderCanvasRenderer.RegisterRenderer(TSkBitmapShaderRenderer);

finalization
  TBitmapShaderCanvasRenderer.UnregisterRenderer(TSkBitmapShaderRenderer);

end.

