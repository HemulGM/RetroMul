unit RM.BitmapShaders;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math.Vectors,
  System.Messaging, FMX.Graphics, FMX.Filter, FMX.Types3D;

type
  TBitmapShaderMode = (Original, Scanlines, CRT, LCD, ColorCorrection, Custom);

  TBitmapShaderSettings = record
    ScanlineStrength: Single;
    Curvature: Single;
    MaskStrength: Single;
    Glow: Single;
    LCDGridStrength: Single;
    LCDResponseMS: Single;
    Gamma: Single;
    Saturation: Single;
    Temperature: Single;
    class function Default: TBitmapShaderSettings; static;
  end;

  TBitmapShaderCanvasRenderer = class;

  TBitmapShaderCanvasRendererClass = class of TBitmapShaderCanvasRenderer;

  // Optional canvas adapters register themselves. The native shader/control units
  // know nothing about Skia and never initialize its runtime or canvas service.
  TBitmapShaderCanvasRenderer = class abstract
  private
    class var
      FClasses: TArray<TBitmapShaderCanvasRendererClass>;
  public
    constructor Create; virtual;
    class procedure RegisterRenderer(const Renderer: TBitmapShaderCanvasRendererClass); static;
    class procedure UnregisterRenderer(const Renderer: TBitmapShaderCanvasRendererClass); static;
    class function CreateForCanvas(const Canvas: TCanvas): TBitmapShaderCanvasRenderer; static;
    class function SupportsCanvas(const Canvas: TCanvas): Boolean; virtual; abstract;
    procedure InvalidateInput; virtual; abstract;
    procedure ResetHistory; virtual; abstract;
    procedure LoadCanvasShader(const Shader: TContextShader); virtual; abstract;
    function DrawToCanvas(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single): Boolean; virtual; abstract;
  end;

  // FMX Direct3D 10+, OpenGL/OpenGL ES, Metal and Skia filter. Native sources are
  // embedded; HLSL compilation is isolated to Windows in RM.ShaderCompiler.
  TBitmapShaderFilter = class(TFilter)
  private
    FWidth, FHeight: Integer;
    FSettings: TBitmapShaderSettings;
    FMode: TBitmapShaderMode;
    FStandardShader, FCustomShader: TContextShader;
    FHistory: TBitmap;
    FHistoryValid: Boolean;
    FHistorySource: TBitmap;
    FResponseWeight: Single;
    FLCDPass: Integer;
  protected
    procedure CalcSize(var W, H: Integer); override;
    procedure LoadShaders; override;
  public
    constructor Create; override;
    class function FilterAttr: TFilterRec; override;
    destructor Destroy; override;
    procedure ResetHistory; virtual;
    procedure LoadCustomShader(const FileName: string);
    property CustomShader: TContextShader read FCustomShader;
    // Borrowed result, valid until the next Render or destruction. UI thread only.
    // Rebinds Input even when the same TBitmap has been updated in place.
    function Render(const Source: TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single = 16.666667): TBitmap;
  end;

// Persistent native GPU targets. Render() above remains the bitmap export API.
type
  TBitmapShaderTarget = record
    Texture: TTexture;
    Context: TContext3D;
    procedure Ensure(Width, Height: Integer);
    procedure Release;
  end;

  TBitmapShaderRenderer = class(TBitmapShaderFilter)
  private
    FOutputTarget, FUploadTarget: TBitmapShaderTarget;
    FHistoryTargets: array[0..1] of TBitmapShaderTarget;
    FHistoryIndex: Integer;
    FNativeHistoryValid, FOutputValid: Boolean;
    FNativeSource: TBitmap;
    FCanvasContext: TContext3D;
    FVertices: TVertexBuffer;
    FIndices: TIndexBuffer;
    FMaterial: TMaterial;
    FCopyMaterial: TMaterial;
    FDrawInput, FDrawHistory: TTexture;
    FUploadTexture: TTexture;
    FDrawSourceSize: TSize;
    FContextLostSubscription: Integer;
    procedure ContextLost(const Sender: TObject; const Message: TMessage);
    procedure ReleaseTargets;
    procedure DrawPass(const Target: TBitmapShaderTarget; const Input, History: TTexture; const SourceSize: TSize; CopyOnly: Boolean = False);
    procedure ApplyNative(const Context: TContext3D);
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure ResetHistory; override;
    // Borrowed, renderer-owned output. No readback; do not keep across renders.
    function RenderTexture(const Source: TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single = 16.666667): TTexture;
    function Draw(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; Update: Boolean): Boolean;
  end;

implementation

uses
  System.Math, System.Hash, System.UITypes, System.RTLConsts, FMX.Canvas.GPU,
  FMX.Materials, RM.ShaderCompiler, RM.BitmapShaderSources;

constructor TBitmapShaderCanvasRenderer.Create;
begin
  inherited;
end;

class procedure TBitmapShaderCanvasRenderer.RegisterRenderer(const Renderer: TBitmapShaderCanvasRendererClass);
begin
  for var Registered in FClasses do
    if Registered = Renderer then
      Exit;
  FClasses := FClasses + [Renderer];
end;

class procedure TBitmapShaderCanvasRenderer.UnregisterRenderer(const Renderer: TBitmapShaderCanvasRendererClass);
begin
  for var I := High(FClasses) downto 0 do
    if FClasses[I] = Renderer then
      Delete(FClasses, I, 1);
end;

class function TBitmapShaderCanvasRenderer.CreateForCanvas(const Canvas: TCanvas): TBitmapShaderCanvasRenderer;
begin
  for var Renderer in FClasses do
    if Renderer.SupportsCanvas(Canvas) then
      Exit(Renderer.Create);
  Result := nil;
end;

class function TBitmapShaderSettings.Default: TBitmapShaderSettings;
begin
  Result.ScanlineStrength := 0.35;
  Result.Curvature := 0.08;
  Result.MaskStrength := 0.65;
  Result.Glow := 0.20;
  Result.LCDGridStrength := 0.35;
  Result.LCDResponseMS := 65;
  Result.Gamma := 1;
  Result.Saturation := 1;
  Result.Temperature := 0;
end;

constructor TBitmapShaderFilter.Create;
begin
  inherited;
  FHistory := TBitmap.Create;
  FStandardShader := TShaderManager.RegisterShaderFromData('retromul.bitmap.effects.v4',
    TContextShaderKind.PixelShader, '', BuiltinBitmapShaderSources);
  FShaders[0] := FStandardShader;
end;

class function TBitmapShaderFilter.FilterAttr: TFilterRec;
begin
  Result := TFilterRec.Create('RetroMulBitmap', 'Bitmap display effects', [
      TFilterValueRec.Create('Target', 'LCD response history', TFilterValueType.Bitmap)]);
end;

destructor TBitmapShaderFilter.Destroy;
begin
  // Detach the borrowed history bitmap before the inherited context is destroyed.
  ValuesAsBitmap['Target'] := nil;
  inherited;
  FHistory.Free;
end;

procedure TBitmapShaderFilter.ResetHistory;
begin
  FHistoryValid := False;
  FHistorySource := nil;
end;

procedure TBitmapShaderFilter.LoadCustomShader(const FileName: string);
var
  Sources: TArray<TContextShaderSource>;
  Source: TContextShaderSource;
  Shader: TContextShader;
  Hash: THashSHA2;
  Probe: TBitmapShaderFilter;
  Bitmap: TBitmap;
begin
  Sources := LoadBitmapShaderSources(FileName);
  Hash := THashSHA2.Create;
  for Source in Sources do
  begin
    Hash.Update(IntToStr(Ord(Source.Arch)));
    if Length(Source.Code) > 0 then
      Hash.Update(Source.Code[0], Length(Source.Code));
  end;
  Shader := TShaderManager.RegisterShaderFromData('retromul.custom.' + Hash.HashAsString,
    TContextShaderKind.PixelShader, '', Sources);
  // GLSL and Metal compile in the active FMX context. Validate before replacing
  // the live shader, so a failed native compile keeps the previous image.
  Probe := TBitmapShaderFilter.Create;
  Bitmap := TBitmap.Create(2, 2);
  try
    Probe.FCustomShader := Shader;
    Probe.Render(Bitmap, 2, 2, TBitmapShaderMode.Custom, TBitmapShaderSettings.Default);
  finally
    Probe.Free;
    Bitmap.Free;
  end;
  FCustomShader := Shader;
end;

procedure TBitmapShaderFilter.CalcSize(var W, H: Integer);
begin
  W := FWidth;
  H := FHeight;
end;

procedure TBitmapShaderFilter.LoadShaders;
begin
  inherited;
  FilterContext.SetShaderVariable('SourceSize', [Vector3D(InputSize.Width, InputSize.Height, 0, 0)]);
  FilterContext.SetShaderVariable('OutputSize', [Vector3D(FWidth, FHeight, 0, 0)]);
  FilterContext.SetShaderVariable('Controls', [Vector3D(
        EnsureRange(FSettings.ScanlineStrength, 0.0, 1.0),
        EnsureRange(FSettings.Curvature, 0.0, 0.3),
        EnsureRange(FSettings.MaskStrength, 0.0, 1.0),
        EnsureRange(FSettings.Glow, 0.0, 1.0))]);
  FilterContext.SetShaderVariable('ModeState', [Vector3D(Ord(FMode), FLCDPass, FResponseWeight, 0)]);
  FilterContext.SetShaderVariable('LCDControls', [Vector3D(
        EnsureRange(FSettings.LCDGridStrength, 0.0, 1.0), 0, 0, 0)]);
  FilterContext.SetShaderVariable('ColorControls', [Vector3D(
        EnsureRange(FSettings.Gamma, 0.25, 4.0), EnsureRange(FSettings.Saturation, 0.0, 2.0),
        EnsureRange(FSettings.Temperature, -1.0, 1.0), 0)]);
end;

function TBitmapShaderFilter.Render(const Source: TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single): TBitmap;
begin
  if (Source = nil) or Source.IsEmpty then
    raise EArgumentException.Create('The shader requires a non-empty source bitmap.');
  if (Width < 1) or (Height < 1) then
    raise EArgumentOutOfRangeException.Create('Output dimensions must be positive.');
  if Mode = TBitmapShaderMode.Original then
  begin
    ResetHistory;
    Exit(Source);
  end;
  if Mode = TBitmapShaderMode.Custom then
  begin
    if FCustomShader = nil then
      raise EInvalidOpException.Create('Load a custom shader for the active graphics backend first.');
    FShaders[0] := FCustomShader;
  end
  else
    FShaders[0] := FStandardShader;
  FWidth := Width;
  FHeight := Height;
  FMode := Mode;
  FSettings := Settings;
  FLCDPass := 0;
  if (Mode = TBitmapShaderMode.LCD) and (Settings.LCDResponseMS > 0) then
  begin
    if not FHistoryValid or (FHistorySource <> Source) or
      (FHistory.Width <> Source.Width) or (FHistory.Height <> Source.Height) then
    begin
      FHistory.SetSize(Source.Width, Source.Height);
      // Keep history CPU-backed: FMX native filters cache flipped ordinary-input
      // textures and cannot safely alternate those with render-target inputs.
      FHistory.CopyFromBitmap(Source, Source.Bounds, 0, 0);
      FHistorySource := Source;
      FHistoryValid := True;
    end
    else if DeltaMilliseconds > 0 then
    begin
      // Evolve the panel response at source resolution, then apply the grid at
      // output resolution. Grid darkening must never feed back into history.
      FResponseWeight := Exp(-DeltaMilliseconds / Min(Settings.LCDResponseMS, 500));
      FWidth := Source.Width;
      FHeight := Source.Height;
      FLCDPass := 1;
      ValuesAsBitmap['Input'] := Source;
      ValuesAsBitmap['Target'] := FHistory;
      InputChanged;
      var Response := ValuesAsBitmap['Output'];
      FHistory.CopyFromBitmap(Response, Response.Bounds, 0, 0);
      FWidth := Width;
      FHeight := Height;
    end;
    FLCDPass := 2;
    ValuesAsBitmap['Input'] := FHistory;
  end
  else
  begin
    ResetHistory;
    ValuesAsBitmap['Input'] := Source;
  end;
  InputChanged;
  Result := ValuesAsBitmap['Output'];
end;


{ Persistent native renderer }

type
  TBitmapShaderMaterial = class(TMaterial)
  private
    FOwner: TBitmapShaderRenderer;
  protected
    procedure DoInitialize; override;
    procedure DoApply(const Context: TContext3D); override;
    class function DoGetMaterialProperty(const Prop: TMaterial.TProperty): string; override;
  end;

procedure TBitmapShaderMaterial.DoInitialize;
begin
end;

procedure TBitmapShaderMaterial.DoApply(const Context: TContext3D);
begin
  FOwner.ApplyNative(Context);
end;

class function TBitmapShaderMaterial.DoGetMaterialProperty(const Prop: TMaterial.TProperty): string;
begin
  if Prop = TProperty.ModelViewProjection then
    Result := 'MVPMatrix'
  else
    Result := '';
end;

procedure TBitmapShaderTarget.Release;
begin
  FreeAndNil(Context);
  FreeAndNil(Texture);
end;

procedure TBitmapShaderTarget.Ensure(Width, Height: Integer);
begin
  if (Texture <> nil) and (Texture.Width = Width) and (Texture.Height = Height) and
    (Context <> nil) then
    Exit;
  Release;
  Texture := TTexture.Create;
  Texture.Style := [TTextureStyle.RenderTarget];
  Texture.MinFilter := TTextureFilter.Nearest;
  Texture.MagFilter := TTextureFilter.Nearest;
  Texture.SetSize(Width, Height);
  Context := TContextManager.CreateFromTexture(Texture, TMultisample.None, False);
end;

constructor TBitmapShaderRenderer.Create;
begin
  inherited;
  FContextLostSubscription := TMessageManager.DefaultManager.SubscribeToMessage(
    TContextLostMessage, ContextLost);
  FVertices := TVertexBuffer.Create([TVertexFormat.Vertex, TVertexFormat.TexCoord0], 4);
  FIndices := TIndexBuffer.Create(6);
  FIndices[0] := 0;
  FIndices[1] := 1;
  FIndices[2] := 3;
  FIndices[3] := 3;
  FIndices[4] := 1;
  FIndices[5] := 2;
  FMaterial := TBitmapShaderMaterial.Create;
  TBitmapShaderMaterial(FMaterial).FOwner := Self;
  FCopyMaterial := TTextureMaterial.Create;
end;

destructor TBitmapShaderRenderer.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TContextLostMessage, FContextLostSubscription);
  ReleaseTargets;
  FMaterial.Free;
  FCopyMaterial.Free;
  FVertices.Free;
  FIndices.Free;
  inherited;
end;

procedure TBitmapShaderRenderer.ReleaseTargets;
begin
  FreeAndNil(FUploadTexture);
  FOutputTarget.Release;
  FUploadTarget.Release;
  FHistoryTargets[0].Release;
  FHistoryTargets[1].Release;
  ResetHistory;
end;

procedure TBitmapShaderRenderer.ContextLost(const Sender: TObject; const Message: TMessage);
begin
  // FMX recreates texture/context handles; their previous pixels are lost.
  ResetHistory;
end;

procedure TBitmapShaderRenderer.ResetHistory;
begin
  inherited ResetHistory;
  FNativeHistoryValid := False;
  FOutputValid := False;
  FNativeSource := nil;
end;

procedure TBitmapShaderRenderer.ApplyNative(const Context: TContext3D);
begin
  Context.SetShaders(FVertexShader, FShaders[0]);
  Context.SetShaderVariable('Input', FDrawInput);
  Context.SetShaderVariable('Target', FDrawHistory);
  Context.SetShaderVariable('SourceSize', [Vector3D(FDrawSourceSize.Width, FDrawSourceSize.Height, 0, 0)]);
  Context.SetShaderVariable('OutputSize', [Vector3D(FWidth, FHeight, 0, 0)]);
  Context.SetShaderVariable('Controls', [Vector3D(
        EnsureRange(FSettings.ScanlineStrength, 0.0, 1.0),
        EnsureRange(FSettings.Curvature, 0.0, 0.3),
        EnsureRange(FSettings.MaskStrength, 0.0, 1.0),
        EnsureRange(FSettings.Glow, 0.0, 1.0))]);
  Context.SetShaderVariable('ModeState', [Vector3D(Ord(FMode), FLCDPass, FResponseWeight, 0)]);
  Context.SetShaderVariable('LCDControls', [Vector3D(
        EnsureRange(FSettings.LCDGridStrength, 0.0, 1.0), 0, 0, 0)]);
  Context.SetShaderVariable('ColorControls', [Vector3D(
        EnsureRange(FSettings.Gamma, 0.25, 4.0), EnsureRange(FSettings.Saturation, 0.0, 2.0),
        EnsureRange(FSettings.Temperature, -1.0, 1.0), 0)]);
end;

procedure TBitmapShaderRenderer.DrawPass(const Target: TBitmapShaderTarget; const Input, History: TTexture; const SourceSize: TSize; CopyOnly: Boolean);
var
  W, H: Integer;
  P: TPointF;
  Material: TMaterial;
  Flip: Boolean;
begin
  W := Target.Texture.Width;
  H := Target.Texture.Height;
  if not Target.Context.BeginScene then
    raise EInvalidOpException.Create('Cannot begin bitmap shader render target.');
  try
    P := Target.Context.PixelToPixelPolygonOffset;
    FVertices.Vertices[0] := Point3D(P.X, P.Y, 0);
    FVertices.Vertices[1] := Point3D(W + P.X, P.Y, 0);
    FVertices.Vertices[2] := Point3D(W + P.X, H + P.Y, 0);
    FVertices.Vertices[3] := Point3D(P.X, H + P.Y, 0);
    // Match the FMX filter convention, including custom shaders. On GL the
    // ordinary bitmap is normalized once on GPU before any temporal passes.
    Flip := not CopyOnly and (TContextStyle.RenderTargetFlipped in Target.Context.Style);
    FVertices.TexCoord0[0] := PointF(0, Ord(Flip));
    FVertices.TexCoord0[1] := PointF(1, Ord(Flip));
    FVertices.TexCoord0[2] := PointF(1, 1 - Ord(Flip));
    FVertices.TexCoord0[3] := PointF(0, 1 - Ord(Flip));
    if CopyOnly then
    begin
      TTextureMaterial(FCopyMaterial).Texture := Input;
      Material := FCopyMaterial;
    end
    else
    begin
      FDrawInput := Input;
      FDrawHistory := History;
      FDrawSourceSize := SourceSize;
      FWidth := W;
      FHeight := H;
      Material := FMaterial;
    end;
    Target.Context.SetMatrix(TMatrix3D.Identity);
    Target.Context.SetContextState(TContextState.cs2DScene);
    Target.Context.SetContextState(TContextState.csZWriteOff);
    Target.Context.SetContextState(TContextState.csZTestOff);
    Target.Context.SetContextState(TContextState.csAllFace);
    Target.Context.SetContextState(TContextState.csAlphaBlendOff);
    Target.Context.SetContextState(TContextState.csScissorOff);
    Target.Context.Clear(0);
    Target.Context.DrawTriangles(FVertices, FIndices, Material, 1);
  finally
    Target.Context.EndScene;
  end;
end;

function TBitmapShaderRenderer.RenderTexture(const Source: TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single): TTexture;
var
  Input: TTexture;
  Data: TBitmapData;
  Next: Integer;
begin
  if (Source = nil) or Source.IsEmpty then
    raise EArgumentException.Create('The shader requires a non-empty source bitmap.');
  if (Width < 1) or (Height < 1) then
    raise EArgumentOutOfRangeException.Create('Output dimensions must be positive.');
  if Mode = TBitmapShaderMode.Custom then
  begin
    if FCustomShader = nil then
      raise EInvalidOpException.Create('Load a custom shader first.');
    FShaders[0] := FCustomShader;
  end
  else
    FShaders[0] := FStandardShader;
  FOutputTarget.Ensure(Width, Height);
  FOutputValid := False;
  if TCanvasStyle.NeedGPUSurface in Source.CanvasClass.GetCanvasStyle then
    Input := TContextManager.DefaultContextClass.BitmapToTexture(Source)
  else
  begin
    // Non-GPU bitmap canvases return a NEW texture from BitmapToTexture.
    // Upload into our own persistent texture instead.
    if FUploadTexture = nil then
      FUploadTexture := TTexture.Create;
    if not Source.Map(TMapAccess.Read, Data) then
      raise EInvalidOpException.Create('Cannot map native shader input.');
    try
      FUploadTexture.PixelFormat := Data.PixelFormat;
      FUploadTexture.SetSize(Source.Width, Source.Height);
      FUploadTexture.UpdateTexture(Data.Data, Data.Pitch);
    finally
      Source.Unmap(Data);
    end;
    Input := FUploadTexture;
  end;
  if Mode = TBitmapShaderMode.Original then
  begin
    ResetHistory;
    Exit(Input);
  end;
  if (TContextStyle.RenderTargetFlipped in FOutputTarget.Context.Style) and
    not (TTextureStyle.RenderTarget in Input.Style) then
  begin
    FUploadTarget.Ensure(Source.Width, Source.Height);
    DrawPass(FUploadTarget, Input, nil, Source.Size, True);
    Input := FUploadTarget.Texture;
  end;
  FSettings := Settings;
  FMode := Mode;
  FLCDPass := 0;
  if (Mode = TBitmapShaderMode.LCD) and (Settings.LCDResponseMS > 0) then
  begin
    if (FNativeSource <> Source) or (FHistoryTargets[0].Texture = nil) or
      (FHistoryTargets[0].Texture.Width <> Source.Width) or
      (FHistoryTargets[0].Texture.Height <> Source.Height) then
      FNativeHistoryValid := False;
    FHistoryTargets[0].Ensure(Source.Width, Source.Height);
    FHistoryTargets[1].Ensure(Source.Width, Source.Height);
    if not FNativeHistoryValid then
    begin
      FHistoryIndex := 0;
      FResponseWeight := 0;
      FLCDPass := 1;
      DrawPass(FHistoryTargets[0], Input, Input, Source.Size);
      FNativeHistoryValid := True;
    end
    else if DeltaMilliseconds > 0 then
    begin
      Next := 1 - FHistoryIndex;
      FResponseWeight := Exp(-DeltaMilliseconds / Min(Settings.LCDResponseMS, 500));
      FLCDPass := 1;
      DrawPass(FHistoryTargets[Next], Input, FHistoryTargets[FHistoryIndex].Texture, Source.Size);
      FHistoryIndex := Next;
    end;
    FNativeSource := Source;
    Input := FHistoryTargets[FHistoryIndex].Texture;
    FLCDPass := 2;
  end
  else
  begin
    FNativeHistoryValid := False;
    FNativeSource := nil;
  end;
  DrawPass(FOutputTarget, Input, Input, Source.Size);
  FOutputValid := True;
  Result := FOutputTarget.Texture;
end;

function TBitmapShaderRenderer.Draw(const Source: TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; Update: Boolean): Boolean;
var
  GPU: TCustomCanvasGpu;
  Color: TAlphaColorRec;
begin
  Result := (Canvas is TCustomCanvasGpu) and (Mode <> TBitmapShaderMode.Original);
  if not Result then
    Exit;
  GPU := TCustomCanvasGpu(Canvas);
  // Submit queued samples of the old output before overwriting its texture.
  Canvas.Flush;
  if FCanvasContext <> GPU.Context then
  begin
    ReleaseTargets;
    FCanvasContext := GPU.Context;
  end;
  if Update or not FOutputValid or (FOutputTarget.Texture = nil) or
    (FOutputTarget.Texture.Width <> PixelSize.Width) or
    (FOutputTarget.Texture.Height <> PixelSize.Height) then
    RenderTexture(Source, PixelSize.Width, PixelSize.Height, Mode, Settings, DeltaMilliseconds);
  Color.Color := TAlphaColors.White;
  Color.A := Round(EnsureRange(Opacity, 0.0, 1.0) * 255);
  GPU.DrawTexture(Dest, TRectF.Create(0, 0, PixelSize.Width, PixelSize.Height),
    Color.Color, FOutputTarget.Texture);
end;

end.

