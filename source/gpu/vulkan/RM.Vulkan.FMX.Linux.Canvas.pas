unit RM.Vulkan.FMX.Linux.Canvas;

// Startup adapter for FMXLinux 1.82: its native text layout supplies metrics
// and rasterizes UI text into cached glyph-label bitmaps. Delphi's
// stock TGPUTextLayout has no Linux TFontGlyphManager implementation.
interface

procedure ConfigureFMXLinuxGPUCanvas;

implementation

uses
  System.SysUtils, System.Types, System.UITypes, System.Math, FMX.Types,
  FMX.Graphics, FMX.TextLayout, FMX.Canvas.GPU, FMX.Canvas.Linux, FMUX.Api;

type
  TFMXLinuxGPUTextLayout = class(TLinuxTextLayout)
  private
    FTextBitmap: TBitmap;
    FNativeLayout: Pointer;
    FColor: TAlphaColor;
    procedure RasterizeText;
  protected
    procedure DoRenderLayout; override;
    procedure DoDrawLayout(const ACanvas: TCanvas); override;
  public
    destructor Destroy; override;
  end;

procedure TFMXLinuxGPUTextLayout.DoRenderLayout;
var
  NativeFont: TFmuxFont;
begin
  inherited;
  FreeAndNil(FTextBitmap);
  if FNativeLayout <> nil then
    FmuxDestroyTextLayout(FNativeLayout);
  FNativeLayout := nil;
  NativeFont.Family := PChar(Font.Family);
  NativeFont.Size := Font.Size;
  NativeFont.Underline := TFontStyle.fsUnderline in Font.StyleExt.SimpleStyle;
  NativeFont.Strikeout := TFontStyle.fsStrikeout in Font.StyleExt.SimpleStyle;
  NativeFont.Weight := Integer(Font.StyleExt.Weight);
  NativeFont.Slant := Integer(Font.StyleExt.Slant);
  FNativeLayout := FmuxCreateTextLayout(PChar(Text), NativeFont, MaxSize.X, MaxSize.Y,
    Integer(HorizontalAlign), Integer(Trimming), WordWrap);
end;

procedure TFMXLinuxGPUTextLayout.RasterizeText;
var
  Width, Height: Integer;
  Bits: TBytes;
  Bitmap, Context: Pointer;
  Data: TBitmapData;
  HOffset, VOffset: Single;
begin
  Width := Max(1, Ceil(Min(MaxSize.X, 8192)));
  Height := Max(1, Ceil(Min(MaxSize.Y, 8192)));
  HOffset := 0;
  VOffset := 0;
  case VerticalAlign of
    TTextAlign.Center:
      VOffset := (MaxSize.Y - TextHeight) / 2;
    TTextAlign.Trailing:
      VOffset := MaxSize.Y - TextHeight;
  end;
  if not WordWrap and (Trimming = TTextTrimming.None) then
    case HorizontalAlign of
      TTextAlign.Center:
        HOffset := (MaxSize.X - TextWidth) / 2;
      TTextAlign.Trailing:
        HOffset := MaxSize.X - TextWidth;
    end;
  SetLength(Bits, Width * Height * 4);
  Bitmap := FmuxBitmapCreate(Width, Height, @Bits[0]);
  if Bitmap = nil then
    raise Exception.Create('FMXLinux could not create a native UI text bitmap.');
  try
    Context := FmuxCreateContext(Bitmap);
    if Context = nil then
      raise Exception.Create('FMXLinux could not create a native UI text context.');
    try
      FmuxCanvasSetFillColor(Context, Color);
      FmuxDrawTextLayout(Context, FNativeLayout, HOffset, VOffset);
    finally
      FmuxDestroyContext(Context);
    end;
  finally
    FmuxBitmapDestroy(Bitmap);
  end;
  FreeAndNil(FTextBitmap);
  FTextBitmap := TBitmap.Create(Width, Height);
  if not FTextBitmap.Map(TMapAccess.Write, Data) then
    raise Exception.Create('FMXLinux could not upload its UI text bitmap.');
  try
    for var Y := 0 to Height - 1 do
      Move(Bits[Y * Width * 4], Data.GetScanline(Y)^, Width * 4);
  finally
    FTextBitmap.Unmap(Data);
  end;
  FColor := Color;
end;

procedure TFMXLinuxGPUTextLayout.DoDrawLayout(const ACanvas: TCanvas);
var
  State: TCanvasSaveState;
begin
  if Text.IsEmpty or (FNativeLayout = nil) then
    Exit;
  if (FTextBitmap = nil) or (FColor <> Color) then
    RasterizeText;
  State := ACanvas.SaveState;
  try
    ACanvas.IntersectClipRect(TRectF.Create(TopLeft, MaxSize.X, MaxSize.Y));
    ACanvas.DrawBitmap(FTextBitmap, FTextBitmap.BoundsF,
      TRectF.Create(TopLeft, FTextBitmap.Width, FTextBitmap.Height), Opacity, True);
  finally
    ACanvas.RestoreState(State);
  end;
end;

destructor TFMXLinuxGPUTextLayout.Destroy;
begin
  if FNativeLayout <> nil then
    FmuxDestroyTextLayout(FNativeLayout);
  FTextBitmap.Free;
  inherited;
end;

var
  GPUCanvasConfigured: Boolean;

procedure ConfigureFMXLinuxGPUCanvas;
begin
  if GPUCanvasConfigured then
    Exit;
  // Call exactly once, before Application.Initialize and before creating any
  // form or bitmap. Rebuild the startup layout registry so the native Linux
  // layout, rather than TGPUTextLayout, is associated with the GPU canvas.
  FMX.Canvas.GPU.RegisterCanvasClasses;
  TCanvasManager.EnableSoftwareCanvas(False);
  TTextLayoutManager.UnInitialize;
  TTextLayoutManager.RegisterTextLayout(TLinuxTextLayout, TLinuxCanvas);
  TTextLayoutManager.RegisterTextLayout(TFMXLinuxGPUTextLayout, TCanvasManager.DefaultCanvas);
  GPUCanvasConfigured := True;
end;

end.

