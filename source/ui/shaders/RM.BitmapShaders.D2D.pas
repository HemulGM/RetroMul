unit RM.BitmapShaders.D2D;

interface

{$IFDEF MSWINDOWS}

uses
  System.SysUtils, System.Types, System.Rtti, System.Messaging, Winapi.D3D10,
  FMX.Graphics, FMX.Types3D, RM.BitmapShaders;

type
  // Uses D2D's own D3D10 device and bitmap texture. No DX11 bridge or readback.
  TD2DBitmapShaderRenderer = class
  private
    type
      TTarget = record
        Texture: ID3D10Texture2D;
        View: ID3D10RenderTargetView;
        Resource: ID3D10ShaderResourceView;
        procedure Release;
        procedure Ensure(const Device: ID3D10Device; W, H: Integer; const BitmapTexture: ID3D10Texture2D = nil);
      end;
  private
    FDevice: ID3D10Device;
    FVertexShader: ID3D10VertexShader;
    FBuiltinShader, FCustomShader: ID3D10PixelShader;
    FCustomSource: TContextShader;
    FConstants: ID3D10Buffer;
    FSampler: ID3D10SamplerState;
    FRasterizer: ID3D10RasterizerState;
    FDepth: ID3D10DepthStencilState;
    FBlend: ID3D10BlendState;
    FState: ID3D10StateBlock;
    FInput: ID3D10Texture2D;
    FInputView: ID3D10ShaderResourceView;
    FOutput: FMX.Graphics.TBitmap;
    FOutputTarget: TTarget;
    FHistory: array[0..1] of TTarget;
    FHistoryIndex: Integer;
    FHistoryValid, FOutputValid: Boolean;
    FSource: FMX.Graphics.TBitmap;
    FRTTI: TRttiContext;
    FTextureField: TRttiField;
    FSubscription: Integer;
    function BitmapTexture(const Bitmap: FMX.Graphics.TBitmap): ID3D10Texture2D;
    procedure EnsureDevice;
    procedure ReleaseResources;
    procedure ContextLost(const Sender: TObject; const Message: TMessage);
    procedure Pass(const Target: TTarget; const Input, History: ID3D10ShaderResourceView; const SourceSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; ResponsePass: Integer; Weight: Single);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ResetHistory;
    // Borrowed bitmap whose D2D texture is the shader render target itself.
    function Render(const Source: FMX.Graphics.TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single; const CustomShader: TContextShader = nil): FMX.Graphics.TBitmap;
    function Draw(const Source: FMX.Graphics.TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; Update: Boolean; const CustomShader: TContextShader = nil): Boolean;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}

uses
  System.Math, System.Math.Vectors, System.TypInfo, System.Win.ComObj,
  Winapi.Windows, Winapi.D3DCommon, Winapi.D3DCompiler, Winapi.DxgiFormat,
  FMX.Canvas.D2D, RM.BitmapShaderSources;

// The RTL declarations omit stdcall for these two exports (breaks Win32).
function CreateD2DStateBlock(const Device: ID3D10Device; const Mask: TD3D10_StateBlockMask; out State: ID3D10StateBlock): HResult; stdcall; external 'd3d10.dll' name 'D3D10CreateStateBlock';

function EnableD2DStateMask(var Mask: TD3D10_StateBlockMask): HResult; stdcall; external 'd3d10.dll' name 'D3D10StateBlockMaskEnableAll';

procedure TD2DBitmapShaderRenderer.TTarget.Release;
begin
  Resource := nil;
  View := nil;
  Texture := nil;
end;

procedure TD2DBitmapShaderRenderer.TTarget.Ensure(const Device: ID3D10Device; W, H: Integer; const BitmapTexture: ID3D10Texture2D);
var
  Desc: TD3D10_Texture2DDesc;
begin
  if Texture <> nil then
  begin
    Texture.GetDesc(Desc);
    if (Desc.Width = Cardinal(W)) and (Desc.Height = Cardinal(H)) and
      ((BitmapTexture = nil) or (Texture = BitmapTexture)) and
      (View <> nil) and (Resource <> nil) then
      Exit;
  end;
  Release;
  if BitmapTexture <> nil then
    Texture := BitmapTexture
  else
  begin
    Desc := Default(TD3D10_Texture2DDesc);
    Desc.Width := W;
    Desc.Height := H;
    Desc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
    Desc.MipLevels := 1;
    Desc.ArraySize := 1;
    Desc.SampleDesc.Count := 1;
    Desc.Usage := D3D10_USAGE_DEFAULT;
    Desc.BindFlags := D3D10_BIND_RENDER_TARGET or D3D10_BIND_SHADER_RESOURCE;
    OleCheck(Device.CreateTexture2D(Desc, nil, Texture));
  end;
  OleCheck(Device.CreateRenderTargetView(Texture, nil, @View));
  OleCheck(Device.CreateShaderResourceView(Texture, nil, @Resource));
end;

constructor TD2DBitmapShaderRenderer.Create;
begin
  inherited;
  FRTTI := TRttiContext.Create;
  FOutput := FMX.Graphics.TBitmap.Create;
  FSubscription := TMessageManager.DefaultManager.SubscribeToMessage(TContextLostMessage, ContextLost);
end;

destructor TD2DBitmapShaderRenderer.Destroy;
begin
  TMessageManager.DefaultManager.Unsubscribe(TContextLostMessage, FSubscription);
  ReleaseResources;
  FOutput.Free;
  FRTTI.Free;
  inherited;
end;

procedure TD2DBitmapShaderRenderer.ReleaseResources;
begin
  FInputView := nil;
  FInput := nil;
  FOutputTarget.Release;
  FHistory[0].Release;
  FHistory[1].Release;
  FVertexShader := nil;
  FBuiltinShader := nil;
  FCustomShader := nil;
  FCustomSource := nil;
  FConstants := nil;
  FSampler := nil;
  FRasterizer := nil;
  FDepth := nil;
  FBlend := nil;
  FState := nil;
  FDevice := nil;
  ResetHistory;
end;

procedure TD2DBitmapShaderRenderer.ContextLost(const Sender: TObject; const Message: TMessage);
begin
  ReleaseResources;
end;

procedure TD2DBitmapShaderRenderer.ResetHistory;
begin
  FHistoryValid := False;
  FOutputValid := False;
  FSource := nil;
end;

function TD2DBitmapShaderRenderer.BitmapTexture(const Bitmap: FMX.Graphics.TBitmap): ID3D10Texture2D;
var
  Handle: TObject;
begin
  Handle := TObject(Bitmap.Handle);
  // FMX exposes neither this texture nor its bitmap handle type publicly.
  // Validate extended RTTI rather than depending on private object offsets.
  if (Handle = nil) or (Handle.ClassName <> 'TD2DBitmapHandle') then
    raise EInvalidOpException.Create('The D2D shader requires a D2D bitmap handle.');
  if FTextureField = nil then
  begin
    FTextureField := FRTTI.GetType(Handle.ClassType).GetField('FTexture');
    if (FTextureField = nil) or (FTextureField.FieldType.Handle <> TypeInfo(ID3D10Texture2D)) then
      raise EInvalidOpException.Create('This FMX version does not expose the D2D bitmap texture through RTTI.');
  end;
  Result := FTextureField.GetValue(Handle).AsInterface as ID3D10Texture2D;
  if Result = nil then
  begin
    // Initialize the D2D texture lazily without mapping or reading its pixels.
    if not Bitmap.Canvas.BeginScene then
      raise EInvalidOpException.Create('Cannot initialize D2D bitmap.');
    Bitmap.Canvas.EndScene;
    Result := FTextureField.GetValue(Handle).AsInterface as ID3D10Texture2D;
  end;
  if Result = nil then
    raise EInvalidOpException.Create('D2D bitmap texture is unavailable.');
end;

procedure TD2DBitmapShaderRenderer.EnsureDevice;
const
  VertexCode: AnsiString =
    'float4 main(uint id:SV_VertexID):SV_Position {' +
    'float2 uv=float2((id<<1)&2,id&2); return float4(uv*float2(2,-2)+float2(-1,1),0,1); }';
var
  Code, Errors: ID3DBlob;
  Sources: TArray<TContextShaderSource>;
  Buffer: TD3D10_BufferDesc;
  Sampler: TD3D10_SamplerDesc;
  Rasterizer: TD3D10_RasterizerDesc;
  Depth: TD3D10_DepthStencilDesc;
  Blend: TD3D10_BlendDesc;
  Mask: TD3D10_StateBlockMask;
begin
  if (FDevice = TCustomCanvasD2D.SharedDevice) and (FState <> nil) then
    Exit;
  ReleaseResources;
  FDevice := TCustomCanvasD2D.SharedDevice;
  OleCheck(D3DCompile(PAnsiChar(VertexCode), Length(VertexCode), nil, nil, nil,
      'main', 'vs_4_0', D3DCOMPILE_ENABLE_STRICTNESS, 0, Code, Errors));
  OleCheck(FDevice.CreateVertexShader(Code.GetBufferPointer, Code.GetBufferSize, @FVertexShader));
  Sources := BuiltinBitmapShaderSources;
  for var Source in Sources do
    if Source.Arch = TContextShaderArch.DX10 then
      OleCheck(FDevice.CreatePixelShader(@Source.Code[0], Length(Source.Code), @FBuiltinShader));
  if FBuiltinShader = nil then
    raise EInvalidOpException.Create('D2D shader bytecode is unavailable.');
  Buffer := Default(TD3D10_BufferDesc);
  Buffer.ByteWidth := 6 * SizeOf(TVector3D);
  Buffer.Usage := D3D10_USAGE_DEFAULT;
  Buffer.BindFlags := D3D10_BIND_CONSTANT_BUFFER;
  OleCheck(FDevice.CreateBuffer(Buffer, nil, @FConstants));
  Sampler := Default(TD3D10_SamplerDesc);
  Sampler.Filter := D3D10_FILTER_MIN_MAG_MIP_POINT;
  Sampler.AddressU := D3D10_TEXTURE_ADDRESS_CLAMP;
  Sampler.AddressV := D3D10_TEXTURE_ADDRESS_CLAMP;
  Sampler.AddressW := D3D10_TEXTURE_ADDRESS_CLAMP;
  Sampler.ComparisonFunc := D3D10_COMPARISON_NEVER;
  Sampler.MaxLOD := D3D10_FLOAT32_MAX;
  OleCheck(FDevice.CreateSamplerState(Sampler, @FSampler));
  Rasterizer := Default(TD3D10_RasterizerDesc);
  Rasterizer.FillMode := D3D10_FILL_SOLID;
  Rasterizer.CullMode := D3D10_CULL_NONE;
  Rasterizer.DepthClipEnable := True;
  OleCheck(FDevice.CreateRasterizerState(Rasterizer, @FRasterizer));
  Depth := Default(TD3D10_DepthStencilDesc);
  Depth.DepthFunc := D3D10_COMPARISON_ALWAYS;
  OleCheck(FDevice.CreateDepthStencilState(Depth, @FDepth));
  Blend := Default(TD3D10_BlendDesc);
  Blend.SrcBlend := D3D10_BLEND_ONE;
  Blend.DestBlend := D3D10_BLEND_ZERO;
  Blend.BlendOp := D3D10_BLEND_OP_ADD;
  Blend.SrcBlendAlpha := D3D10_BLEND_ONE;
  Blend.DestBlendAlpha := D3D10_BLEND_ZERO;
  Blend.BlendOpAlpha := D3D10_BLEND_OP_ADD;
  Blend.RenderTargetWriteMask[0] := Ord(D3D10_COLOR_WRITE_ENABLE_ALL);
  OleCheck(FDevice.CreateBlendState(Blend, @FBlend));
  OleCheck(EnableD2DStateMask(Mask));
  OleCheck(CreateD2DStateBlock(FDevice, Mask, FState));
end;

procedure TD2DBitmapShaderRenderer.Pass(const Target: TTarget; const Input, History: ID3D10ShaderResourceView; const SourceSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; ResponsePass: Integer; Weight: Single);
var
  Params: array[0..5] of TVector3D;
  Views: array[0..1] of ID3D10ShaderResourceView;
  Samplers: array[0..1] of ID3D10SamplerState;
  Viewport: TD3D10_Viewport;
  Desc: TD3D10_Texture2DDesc;
begin
  Target.Texture.GetDesc(Desc);
  Params[0] := Vector3D(SourceSize.Width, SourceSize.Height, 0, 0);
  Params[1] := Vector3D(Desc.Width, Desc.Height, 0, 0);
  Params[2] := Vector3D(EnsureRange(Settings.ScanlineStrength, 0.0, 1.0),
      EnsureRange(Settings.Curvature, 0.0, 0.3), EnsureRange(Settings.MaskStrength, 0.0, 1.0),
      EnsureRange(Settings.Glow, 0.0, 1.0));
  Params[3] := Vector3D(Ord(Mode), ResponsePass, Weight, 0);
  Params[4] := Vector3D(EnsureRange(Settings.LCDGridStrength, 0.0, 1.0), 0, 0, 0);
  Params[5] := Vector3D(EnsureRange(Settings.Gamma, 0.25, 4.0),
      EnsureRange(Settings.Saturation, 0.0, 2.0), EnsureRange(Settings.Temperature, -1.0, 1.0), 0);
  // Unbind all previous inputs before selecting the next history as a target.
  Views[0] := nil;
  Views[1] := nil;
  FDevice.PSSetShaderResources(0, 2, @Views[0]);
  FDevice.OMSetRenderTargets(1, @Target.View, nil);
  Viewport := Default(TD3D10_Viewport);
  Viewport.Width := Desc.Width;
  Viewport.Height := Desc.Height;
  Viewport.MaxDepth := 1;
  FDevice.RSSetViewports(1, @Viewport);
  FDevice.UpdateSubresource(FConstants, 0, nil, @Params[0], 0, 0);
  FDevice.PSSetConstantBuffers(0, 1, @FConstants);
  Views[0] := Input;
  Views[1] := History;
  FDevice.PSSetShaderResources(0, 2, @Views[0]);
  Samplers[0] := FSampler;
  Samplers[1] := FSampler;
  FDevice.PSSetSamplers(0, 2, @Samplers[0]);
  if Mode = TBitmapShaderMode.Custom then
    FDevice.PSSetShader(FCustomShader)
  else
    FDevice.PSSetShader(FBuiltinShader);
  FDevice.Draw(3, 0);
end;

function TD2DBitmapShaderRenderer.Render(const Source: FMX.Graphics.TBitmap; Width, Height: Integer; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; DeltaMilliseconds: Single; const CustomShader: TContextShader): FMX.Graphics.TBitmap;
const
  BlendFactor: TColorArray = (0, 0, 0, 0);
var
  InputTexture: ID3D10Texture2D;
  InputView: ID3D10ShaderResourceView;
  ShaderSource: TContextShaderSource;
  Next: Integer;
  Desc: TD3D10_Texture2DDesc;
begin
  if (Source = nil) or Source.IsEmpty then
    raise EArgumentException.Create('Empty D2D shader input.');
  if (Width < 1) or (Height < 1) then
    raise EArgumentOutOfRangeException.Create('Invalid D2D output size.');
  if Mode = TBitmapShaderMode.Original then
  begin
    ResetHistory;
    Exit(Source);
  end;
  if Source.Canvas.BeginSceneCount > 0 then
    Source.Canvas.Flush;
  EnsureDevice;
  FOutputValid := False;
  if Mode = TBitmapShaderMode.Custom then
  begin
    if CustomShader = nil then
      raise EInvalidOpException.Create('Load a custom shader first.');
    if FCustomSource <> CustomShader then
    begin
      ShaderSource := CustomShader.GetSourceByArch(TContextShaderArch.DX10);
      if not ShaderSource.IsDefined then
        raise EInvalidOpException.Create('Custom shader has no HLSL bytecode.');
      FCustomShader := nil;
      OleCheck(FDevice.CreatePixelShader(@ShaderSource.Code[0], Length(ShaderSource.Code), @FCustomShader));
      FCustomSource := CustomShader;
    end;
  end;
  InputTexture := BitmapTexture(Source);
  if FInput <> InputTexture then
  begin
    FInputView := nil;
    FInput := InputTexture;
    OleCheck(FDevice.CreateShaderResourceView(FInput, nil, @FInputView));
  end;
  if (FOutput.Width <> Width) or (FOutput.Height <> Height) then
    FOutput.SetSize(Width, Height);
  FOutputTarget.Ensure(FDevice, Width, Height, BitmapTexture(FOutput));
  OleCheck(FState.Capture);
  try
    FDevice.IASetInputLayout(nil);
    FDevice.IASetPrimitiveTopology(Winapi.D3D10.D3D10_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    FDevice.VSSetShader(FVertexShader);
    FDevice.GSSetShader(nil);
    FDevice.RSSetState(FRasterizer);
    FDevice.OMSetDepthStencilState(FDepth, 0);
    FDevice.OMSetBlendState(FBlend, BlendFactor, $FFFFFFFF);
    FDevice.SetPredication(nil, False);
    InputView := FInputView;
    if (Mode = TBitmapShaderMode.LCD) and (Settings.LCDResponseMS > 0) then
    begin
      if FHistory[0].Texture <> nil then
      begin
        FHistory[0].Texture.GetDesc(Desc);
        if (Desc.Width <> Cardinal(Source.Width)) or (Desc.Height <> Cardinal(Source.Height)) then
          FHistoryValid := False;
      end;
      if FSource <> Source then
        FHistoryValid := False;
      FHistory[0].Ensure(FDevice, Source.Width, Source.Height);
      FHistory[1].Ensure(FDevice, Source.Width, Source.Height);
      if not FHistoryValid then
      begin
        FHistoryIndex := 0;
        Pass(FHistory[0], FInputView, FInputView, Source.Size, Mode, Settings, 1, 0);
        FHistoryValid := True;
      end
      else if DeltaMilliseconds > 0 then
      begin
        Next := 1 - FHistoryIndex;
        Pass(FHistory[Next], FInputView, FHistory[FHistoryIndex].Resource,
          Source.Size, Mode, Settings, 1, Exp(-DeltaMilliseconds / Min(Settings.LCDResponseMS, 500)));
        FHistoryIndex := Next;
      end;
      FSource := Source;
      InputView := FHistory[FHistoryIndex].Resource;
    end
    else
    begin
      FHistoryValid := False;
      FSource := nil;
    end;
    Pass(FOutputTarget, InputView, InputView, Source.Size, Mode, Settings, 2, 0);
  finally
    OleCheck(FState.Apply);
    FState.ReleaseAllDeviceObjects;
  end;
  FOutputValid := True;
  Result := FOutput;
end;

function TD2DBitmapShaderRenderer.Draw(const Source: FMX.Graphics.TBitmap; const Canvas: TCanvas; const Dest: TRectF; const PixelSize: TSize; Mode: TBitmapShaderMode; const Settings: TBitmapShaderSettings; Opacity, DeltaMilliseconds: Single; Update: Boolean; const CustomShader: TContextShader): Boolean;
begin
  Result := (Canvas is TCustomCanvasD2D) and (Source.CanvasClass.InheritsFrom(TCustomCanvasD2D));
  if not Result then
    Exit;
  // D2D batches draws: consume the old texture before writing the next frame.
  Canvas.Flush;
  if Update or not FOutputValid or (FOutput.Width <> PixelSize.Width) or
    (FOutput.Height <> PixelSize.Height) or (FDevice <> TCustomCanvasD2D.SharedDevice) then
    Render(Source, PixelSize.Width, PixelSize.Height, Mode, Settings, DeltaMilliseconds, CustomShader);
  Canvas.DrawBitmap(FOutput, FOutput.BoundsF, Dest, Opacity, True);
end;
{$ENDIF}

end.

