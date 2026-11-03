unit PSP.GE.VulkanHLE;

// The GE's primitives drawn by a Vulkan graphics pipeline (HLE): fast, not bit
// exact. PSP.GE.VulkanLLE is the bit-exact compute renderer; PSP.GE.Raster the
// reference. The device, targets, coherence, texture cache, batches and frames
// are RM.Vulkan.HLE's (TVulkanHLERenderer); here is what is the PSP's.
//
// The engine hands over every primitive transformed, lit and clipped, in the
// target's pixels. They are drawn with the GPU's rasterizer into images that
// stand for render targets (keyed by VRAM address, format and stride), with a
// depth/stencil image each. The PSP keeps its stencil in the colour's alpha
// bits: here the stencil aspect holds it (as 8 bits) and goes back into those
// bits when a target is read back; normal drawing never writes the colour
// image's alpha, which mirrors the stencil for blending with destination alpha.
//
// Coherence: a target's VRAM pages are held (TPSPMemory.HoldVRAM) while it has
// newer pixels than guest memory. Any access to a held page, a GE access to
// VRAM that may overlap one, a texture read from one and Sync bring every
// target back: the GPU finishes, the images are read back into VRAM and the
// holds released (a run ends). A target that is not held is compared with
// what guest memory held when it was last loaded before it is drawn into
// again, and reloaded when the CPU changed it. Textures are decoded on the CPU
// (GEFetchTexel), cached, compared with their source bytes once a run and
// watched (TPSPMemory.WatchPage) from then on; so are depth buffers that are
// only read. The depth buffer of a target (its own address, stride and
// permutation in VRAM) is the PSP's: loaded, compared, held, watched and read
// back here. The fragment shader samples texels itself, as the GE does
// (wrap, nearest, 4-bit bilinear weights, level of detail), and writes depth
// as the GE rounds it; lines are drawn as the GE's pixels, one point each.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Generics.Collections,
  Core.Emulation.Types, PSP.Types, PSP.Memory, PSP.GE.Texture, PSP.GE.Raster,
  PSP.GE.Backend, RM.Vulkan.Bindings, RM.Vulkan.Loader, RM.Vulkan.Compute,
  RM.Vulkan.HLE;

type
  // A target with what is the PSP's: its depth buffer, the stencil's mirror
  // in the colour's alpha, and the sets of the down-sampling kernel and of
  // shader blending.
  TGEHLETarget = class(TVulkanHLETarget)
  public
    // The depth and stencil aspects alone, for the down-sampling kernel.
    ZView, SView: VkImageView;
    DownSet: VkDescriptorSet;
    // With shader blending: the colour as a storage image, depth and stencil
    // sampled, and a framebuffer without attachments.
    BlendSet: VkDescriptorSet;
    BlendFramebuffer: VkFramebuffer;
    // Drawing changed the stencil since the colour's alpha (its mirror) was
    // loaded.
    AlphaStale: Boolean;
    // The depth buffer the depth aspect holds, as depth values when loaded.
    ZAddr, ZStride: Cardinal;
    ZPerm: Integer;
    ZLoaded: Boolean;
    // The run the depth image was last found equal to guest memory in, -1
    // for none.
    ZVerified: Int64;
    // The run its depth pages were watched in.
    ZWatched: Int64;
    ZShadow: TArray<Word>;
    ZDirty: Boolean;
    ZX1, ZY1, ZX2, ZY2: Integer;
    ZHeldY1, ZHeldY2: Integer;
    ZStale: Boolean;
    constructor Create;
  end;

  TGEHLEBox = array[0..3] of Single;

  // A vertex as the pipelines take it: position in target pixels with the raw
  // depth, colours, texture coordinates (times 1/w for perspective) and fog.
  // Box: the coordinates (S / Q, T / Q) the primitive's samples keep within
  // (low S, low T, high S, high T), for sprites above 1x; none when a low is
  // above its high.
  TGEHLEVertex = packed record
    X, Y, Z: Single;
    Color, Secondary: Cardinal;
    S, T, Q, W: Single;
    Fog: Single;
    Box: TGEHLEBox;
  end;

  PGEHLEVertex = ^TGEHLEVertex;

  TGEHLEStencil = array[0..2] of Cardinal;

  // What a draw binds: pipeline, texture, push constants and dynamic state
  // (stencil compare mask, write mask, reference).
  TGEHLEBindings = record
    Pipeline: VkPipeline;
    TexSet: VkDescriptorSet;
    Push: array[0..21] of Cardinal;
    Scissor: VkRect2D;
    Blend: Cardinal;
    Stencil: TGEHLEStencil;
    // Drawn by the shader-blending pipelines (no attachments), with the
    // target's set.
    Blended: Boolean;
    TargetSet: VkDescriptorSet;
  end;

  TGEVulkanHLEBackend = class;

  // What the GE engine draws through (TPSPGEEngine.Backend): the renderer.
  TGEHLEEngineBackend = class(TGERasterBackend)
  private
    FOwner: TGEVulkanHLEBackend;
  public
    constructor Create(Owner: TGEVulkanHLEBackend);
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); override;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); override;
    procedure Access(Address, Size: Cardinal; Write: Boolean); override;
    procedure Sync; override;
    procedure Release; override;
  end;

  TGEVulkanHLEBackend = class(TVulkanHLERenderer)
  private
    FMemory: TPSPMemory;
    FEngineBackend: TGEHLEEngineBackend;
    FVertexModule, FFragmentModule: VkShaderModule;
    // The kernel that brings targets back to the PSP's resolution (at a scale)
    // and copies the frames shown.
    FDownSetLayout: VkDescriptorSetLayout;
    FDownLayout: VkPipelineLayout;
    FDownModule: VkShaderModule;
    FDownPipeline: VkPipeline;
    FDownPool: VkDescriptorPool;
    // Shader blending (VK_EXT_fragment_shader_interlock): the GE's blend,
    // dither, logic operations and bit masks exactly, for draws that write no
    // depth or stencil.
    FShaderBlend: Boolean;
    FBlendModule: VkShaderModule;
    FBlendSetLayout: VkDescriptorSetLayout;
    FBlendLayout: VkPipelineLayout;
    FBlendPool: VkDescriptorPool;
    FBlendPass: VkRenderPass;
    // Recording: what is bound besides the pipeline and the texture.
    FBoundScissor: VkRect2D;
    FBoundBlend: Cardinal;
    FBoundStencil: TGEHLEStencil;
    FBoundPush: array[0..21] of Cardinal;
    FBoundTargetSet: VkDescriptorSet;
    FPushValid, FScissorValid, FBlendValid, FStencilValid: Boolean;
    // What the current state binds.
    FWant: TGEHLEBindings;
    // The state the draw being built was set up for.
    FLast: TGERaster;
    FLastClut: array[0..1023] of Byte;
    FLastKind: Integer;
    // The engine's RasterSerial when FLast was last found current.
    FLastSerial: UInt64;
    FStateValid: Boolean;
    // Clear-mode stencil writes take the primitive's alpha as the reference.
    FClearStencil: Boolean;
    FDepthWrites, FDepthUsed: Boolean;
    // The lowest row the primitive being set up needs in its target.
    FNeedY: Integer;
    FLine: TArray<TGEHLEVertex>;
    FDepthLoads, FDepthCopies: Int64;
    procedure CreateDown;
    procedure CreateDownSet(T: TGEHLETarget);
    procedure CreateBlend;
    procedure CreateBlendTarget(T: TGEHLETarget);
    procedure RefreshAlpha(T: TGEHLETarget);
    procedure DownSample(T: TGEHLETarget; X, Y, W, H: Integer; Offset, What: Cardinal; Step: Integer = 0);
    procedure HoldDepthRows(T: TGEHLETarget; Y1, Y2: Integer);
    procedure HoldNewDepthRows(T: TGEHLETarget; Y1, Y2: Integer);
    procedure WatchDepth(T: TGEHLETarget);
    function TargetFor(const S: TGERaster): TGEHLETarget;
    function BandRows(T: TVulkanHLETarget; Bytes: Integer): Integer;
    procedure Store(T: TGEHLETarget);
    procedure StoreDepth(T: TGEHLETarget);
    procedure EnsureDepth(T: TGEHLETarget; const S: TGERaster);
    procedure LoadDepth(T: TGEHLETarget);
    procedure CopyDepth(Source, Dest: TGEHLETarget);
    function EnsureTexture(const S: TGERaster): TVulkanHLETexture;
    function TextureScaleFor(const X: TGETexture; First, Count: Integer): Integer;
    function TargetTexture(const S: TGERaster): TVulkanHLETexture;
    procedure VRAMFault;
    procedure WatchFault;
    function SameState(const S: TGERaster; Kind: Integer): Boolean;
    function CurrentState(const S: TGERaster; Kind: Integer): Boolean;
    procedure SetupState(const S: TGERaster; Kind: Integer);
    procedure ApplyBindings;
    procedure Emit(Kind: Integer; const S: TGERaster; V: PGEHLEVertex; Count: Integer; X1, Y1, X2, Y2: Integer);
  protected
    procedure Unbound; override;
    procedure FreeDevice; override;
    function PipelineFor(Key: UInt64): VkPipeline; override;
    function NewTarget: TVulkanHLETarget; override;
    procedure InitTarget(T: TVulkanHLETarget); override;
    procedure DestroyTarget(T: TVulkanHLETarget); override;
    procedure LoadTarget(T: TVulkanHLETarget); override;
    procedure StoreTarget(T: TVulkanHLETarget); override;
    function TargetNewer(T: TVulkanHLETarget): Boolean; override;
    procedure NewRun; override;
    procedure WatchSource(T: TVulkanHLETexture); override;
    procedure DescribeTexture(Request: Pointer; out Width, Height, Levels, Scale: Integer); override;
    function TextureMatches(T: TVulkanHLETexture; Request: Pointer): Boolean; override;
    procedure DecodeTexture(T: TVulkanHLETexture; Request: Pointer); override;
    procedure WatchTexture(T: TVulkanHLETexture; Request: Pointer); override;
    function MemoryEquals(Addr: Cardinal; Data: PByte; Size: Cardinal): Boolean; override;
    procedure ReadMemory(Addr: Cardinal; Data: PByte; Size: Cardinal); override;
    procedure HoldMemory(Addr, Size: Cardinal); override;
    function MemoryHeld(Addr, Size: Cardinal): Boolean; override;
    procedure ReleaseHolds; override;
    procedure WatchMemory(Addr, Size: Cardinal); override;
    procedure ReleaseWatches; override;
    procedure RecordFrame(T: TVulkanHLETarget; W, H: Integer); override;
    function RecordFrameRegion(T: TVulkanHLETarget; X, Y, W, H: Integer): Boolean; override;
  public
    // ShaderBlend: blend in the shader where the device can (else always the
    // fixed function's).
    constructor Create(Memory: TPSPMemory; Compute: TVulkanCompute; Scale: Integer = 1; ShaderBlend: Boolean = True);
    destructor Destroy; override;
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex);
    // The engine is about to read (or write) guest memory from Address itself.
    procedure Access(Address, Size: Cardinal; Write: Boolean);
    // The shown framebuffer at the scale, when a target holds it (TPSPConsole.OnPresent).
    function Present(Address, Format, Stride: Cardinal; var Frame: TEmulatorFrame): Boolean;
    // What TPSPGEEngine.Backend is set to (owned by the renderer).
    property EngineBackend: TGEHLEEngineBackend read FEngineBackend;
    property ShaderBlend: Boolean read FShaderBlend;
    property DepthLoads: Int64 read FDepthLoads;
    property DepthCopies: Int64 read FDepthCopies;
  end;

// An HLE backend on a Vulkan device with a graphics queue, or False with the
// reason. Scale: the internal resolution in multiples of the PSP's (1 to 8).
// ShaderBlend: blending in the shader where the device can.
function CreateGEVulkanHLEBackend(Memory: TPSPMemory; out Backend: TGEVulkanHLEBackend; out Error: string; const DeviceName: string = ''; Scale: Integer = 1; ShaderBlend: Boolean = True): Boolean;

implementation

uses
  SPV.PSPGEHLEVert, SPV.PSPGEHLEFrag, SPV.PSPGEHLEBlendFrag, SPV.PSPGEHLEDown;

const
  VRAMMask = PSPVRAMSize - 1;
  // Texture bytes compared with their source at most (larger ones are
  // compared in their first bytes).
  MaxSource = 4 shl 20;
  KindTriangle = 0;
  KindLine = 1;
  KindPoint = 2;
  FLAG_TEXTURED = 1;
  FLAG_FOG = 2;
  FLAG_COLORTEST = 4;
  FLAG_ALPHATEST = 8;
  FLAG_RANGE = 16;
  FLAG_CLAMPZ = 32;
  FLAG_CLEAR = 64;
  FLAG_DITHER = 128;
  FLAG_QUANTIZE = 1024;

  // PSP test functions (never, always, =, <>, <, <=, >, >=) and stencil
  // operations (keep, zero, replace, invert, increment, decrement).
  CompareOps: array[0..7] of Integer = (VK_COMPARE_OP_NEVER, VK_COMPARE_OP_ALWAYS, VK_COMPARE_OP_EQUAL,
    VK_COMPARE_OP_NOT_EQUAL, VK_COMPARE_OP_LESS, VK_COMPARE_OP_LESS_OR_EQUAL, VK_COMPARE_OP_GREATER,
    VK_COMPARE_OP_GREATER_OR_EQUAL);
  StencilOps: array[0..7] of Integer = (VK_STENCIL_OP_KEEP, VK_STENCIL_OP_ZERO, VK_STENCIL_OP_REPLACE,
    VK_STENCIL_OP_INVERT, VK_STENCIL_OP_INCREMENT_AND_CLAMP, VK_STENCIL_OP_DECREMENT_AND_CLAMP, VK_STENCIL_OP_KEEP,
    VK_STENCIL_OP_KEEP);

type
  // As source/gpu/shaders/PSPGEHLEPush.glsl declares it.
  TGEHLEPush = packed record
    NdcX, NdcY: Single;
    Flags, TexFunc, Env, FogColor, AlphaTest, ColorRef, ColorMask: Cardinal;
    MinZ, MaxZ: Single;
    LodBias: Single;
    TexW, TexH: Single;
    Dither0, Dither1, FixA: Cardinal;
    LodSlope: Single;
    Blend, FixB, Keep, Stencil: Cardinal;
  end;

  PGERaster = ^TGERaster;

  // A texture as EnsureTexture asks for it (TVulkanHLERenderer.CachedTexture's
  // request): the GE's levels First.. in the image's Count levels.
  TGEHLETexRequest = record
    S: PGERaster;
    First, Count: Integer;
  end;

  PGEHLETexRequest = ^TGEHLETexRequest;

function Bpp(Format: Cardinal): Cardinal; inline;
begin
  if Format = 3 then
    Result := 4
  else
    Result := 2;
end;

function ClampByte(V: Integer): Cardinal; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := V;
end;

function PackColor(R, G, B, A: Integer): Cardinal; inline;
begin
  Result := ClampByte(R) or (ClampByte(G) shl 8) or (ClampByte(B) shl 16) or (ClampByte(A) shl 24);
end;

// The framebuffer's alpha bits as the 8-bit stencil value, and back.
function Stencil8(Format, Pixel: Cardinal): Cardinal; inline;
begin
  case Format of
    1:
      Result := Ord((Pixel and $8000) <> 0) * 255;
    2:
      Result := (Pixel shr 12) * 17;
    3:
      Result := Pixel shr 24;
  else
    Result := 0;
  end;
end;

function StencilBitsOf(Format, S8: Cardinal): Cardinal; inline;
begin
  case Format of
    1:
      Result := Cardinal(Ord(S8 >= 128)) shl 15;
    2:
      Result := (S8 shr 4) shl 12;
    3:
      Result := S8 shl 24;
  else
    Result := 0;
  end;
end;

procedure DecodeColor(Format, P: Cardinal; out R, G, B: Cardinal); inline;
begin
  case Format of
    0:
      begin
        R := P and $1F;
        R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $3F;
        G := (G shl 2) or (G shr 4);
        B := (P shr 11) and $1F;
        B := (B shl 3) or (B shr 2);
      end;
    1:
      begin
        R := P and $1F;
        R := (R shl 3) or (R shr 2);
        G := (P shr 5) and $1F;
        G := (G shl 3) or (G shr 2);
        B := (P shr 10) and $1F;
        B := (B shl 3) or (B shr 2);
      end;
    2:
      begin
        R := (P and $F) * 17;
        G := ((P shr 4) and $F) * 17;
        B := ((P shr 8) and $F) * 17;
      end;
  else
    R := P and $FF;
    G := (P shr 8) and $FF;
    B := (P shr 16) and $FF;
  end;
end;

function EncodeColorOf(Format, R, G, B: Cardinal): Cardinal; inline;
begin
  case Format of
    0:
      Result := (R shr 3) or ((G shr 2) shl 5) or ((B shr 3) shl 11);
    1:
      Result := (R shr 3) or ((G shr 3) shl 5) or ((B shr 3) shl 10);
    2:
      Result := (R shr 4) or ((G shr 4) shl 4) or ((B shr 4) shl 8);
  else
    Result := R or (G shl 8) or (B shl 16);
  end;
end;

{$IFOPT Q+}{$DEFINE HLE_OVERFLOW}{$Q-}{$ENDIF}
// Hashing wraps around.
function FNV(H: UInt64; V: UInt64): UInt64;
begin
  Result := (H xor V) * UInt64($100000001B3);
end;
{$IFDEF HLE_OVERFLOW}{$Q+}{$UNDEF HLE_OVERFLOW}{$ENDIF}

{ TGEHLETarget }

constructor TGEHLETarget.Create;
begin
  inherited;
  ZVerified := -1;
  ZWatched := -1;
end;

{ TGEHLEEngineBackend }

constructor TGEHLEEngineBackend.Create(Owner: TGEVulkanHLEBackend);
begin
  inherited Create;
  FOwner := Owner;
end;

procedure TGEHLEEngineBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  FOwner.DrawTriangle(S, V0, V1, V2);
end;

procedure TGEHLEEngineBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
begin
  FOwner.DrawSprite(S, V0, V1);
end;

procedure TGEHLEEngineBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
begin
  FOwner.DrawLine(S, V0, V1);
end;

procedure TGEHLEEngineBackend.DrawPoint(const S: TGERaster; const V: TGEVertex);
begin
  FOwner.DrawPoint(S, V);
end;

procedure TGEHLEEngineBackend.Access(Address, Size: Cardinal; Write: Boolean);
begin
  FOwner.Access(Address, Size, Write);
end;

procedure TGEHLEEngineBackend.Sync;
begin
  FOwner.Sync;
end;

procedure TGEHLEEngineBackend.Release;
begin
  FOwner.Release;
end;

{ TGEVulkanHLEBackend }

function CreateGEVulkanHLEBackend(Memory: TPSPMemory; out Backend: TGEVulkanHLEBackend; out Error: string; const DeviceName: string; Scale: Integer; ShaderBlend: Boolean): Boolean;
var
  Compute: TVulkanCompute;
begin
  Backend := nil;
  if Assigned(Memory.OnVRAMFault) then
  begin
    Error := 'This memory already has a VRAM device.';
    Exit(False);
  end;
  if not TryCreateVulkanCompute(Compute, Error, DeviceName, False, True) then
    Exit(False);
  try
    Backend := TGEVulkanHLEBackend.Create(Memory, Compute, Scale, ShaderBlend);
    Result := True;
  except
    on E: Exception do
    begin
      Error := E.Message;
      Compute.Free;
      Result := False;
    end;
  end;
end;

constructor TGEVulkanHLEBackend.Create(Memory: TPSPMemory; Compute: TVulkanCompute; Scale: Integer; ShaderBlend: Boolean);
var
  Props: VkFormatProperties;
begin
  FMemory := Memory;
  inherited Create(Compute, Scale, SizeOf(TGEHLEVertex), SizeOf(TGEHLEPush), PSPFrameWidth, PSPFrameHeight);
  FEngineBackend := TGEHLEEngineBackend.Create(Self);
  // The shader-blending pipelines and the down-sampling kernel write the
  // colour as a storage image (RGBA8 storage is required of every device);
  // the kernel samples the depth.
  FColorUsage := FColorUsage or VK_IMAGE_USAGE_STORAGE_BIT;
  FDepthUsage := FDepthUsage or VK_IMAGE_USAGE_SAMPLED_BIT;
  FVertexModule := Compute.CreateShaderModule(PSPGEHLEVertSPV);
  FFragmentModule := Compute.CreateShaderModule(PSPGEHLEFragSPV);
  CreateDown;
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_R8G8B8A8_UNORM, @Props);
  FShaderBlend := ShaderBlend and Compute.Features.PixelInterlock and ((Props.optimalTilingFeatures and
    VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) <> 0);
  if FShaderBlend then
    CreateBlend;
  FMemory.OnVRAMFault := VRAMFault;
  FMemory.OnWatchFault := WatchFault;
end;

destructor TGEVulkanHLEBackend.Destroy;
begin
  // Guest memory stops calling back; what is drawn goes back to it
  // (TVulkanHLERenderer.Destroy).
  if (FCompute <> nil) and (FMemory <> nil) then
  begin
    if Assigned(FMemory.OnVRAMFault) then
      FMemory.OnVRAMFault := nil;
    FMemory.OnWatchFault := nil;
  end;
  inherited;
  FEngineBackend.Free;
end;

procedure TGEVulkanHLEBackend.FreeDevice;
begin
  if FDownPipeline <> 0 then
    FAPI.vkDestroyPipeline(FDevice, FDownPipeline, nil);
  if FDownModule <> 0 then
    FAPI.vkDestroyShaderModule(FDevice, FDownModule, nil);
  if FDownPool <> 0 then
    FAPI.vkDestroyDescriptorPool(FDevice, FDownPool, nil);
  if FDownLayout <> 0 then
    FAPI.vkDestroyPipelineLayout(FDevice, FDownLayout, nil);
  if FDownSetLayout <> 0 then
    FAPI.vkDestroyDescriptorSetLayout(FDevice, FDownSetLayout, nil);
  if FBlendModule <> 0 then
    FAPI.vkDestroyShaderModule(FDevice, FBlendModule, nil);
  if FBlendPool <> 0 then
    FAPI.vkDestroyDescriptorPool(FDevice, FBlendPool, nil);
  if FBlendLayout <> 0 then
    FAPI.vkDestroyPipelineLayout(FDevice, FBlendLayout, nil);
  if FBlendSetLayout <> 0 then
    FAPI.vkDestroyDescriptorSetLayout(FDevice, FBlendSetLayout, nil);
  if FBlendPass <> 0 then
    FAPI.vkDestroyRenderPass(FDevice, FBlendPass, nil);
  if FVertexModule <> 0 then
    FAPI.vkDestroyShaderModule(FDevice, FVertexModule, nil);
  if FFragmentModule <> 0 then
    FAPI.vkDestroyShaderModule(FDevice, FFragmentModule, nil);
  inherited;
end;

procedure TGEVulkanHLEBackend.Unbound;
begin
  FBoundTargetSet := 0;
  FPushValid := False;
  FScissorValid := False;
  FBlendValid := False;
  FStencilValid := False;
end;

function TGEVulkanHLEBackend.NewTarget: TVulkanHLETarget;
begin
  Result := TGEHLETarget.Create;
end;

procedure TGEVulkanHLEBackend.InitTarget(T: TVulkanHLETarget);
begin
  CreateDownSet(TGEHLETarget(T));
  if FShaderBlend then
    CreateBlendTarget(TGEHLETarget(T));
end;

function TGEVulkanHLEBackend.TargetNewer(T: TVulkanHLETarget): Boolean;
begin
  Result := T.Dirty or TGEHLETarget(T).ZDirty;
end;

// Everything set up is set up again (textures and depth buffers are compared
// with guest memory again).
procedure TGEVulkanHLEBackend.NewRun;
begin
  inherited;
  FStateValid := False;
end;

// Key bits: 0-1 topology kind, 2 blend, 3-7 source factor, 8-12 destination
// factor, 13-15 blend op, 16-19 colour write mask, 20 logic op, 21-24 its
// function, 25 depth test, 26 depth write, 27-29 depth compare, 30 stencil
// test, 31-33 stencil compare, 34-36 fail, 37-39 depth fail, 40-42 pass, 43
// shader blending (no attachments: the rest of the key is unused).
function TGEVulkanHLEBackend.PipelineFor(Key: UInt64): VkPipeline;
var
  Stages: array[0..1] of VkPipelineShaderStageCreateInfo;
  Binding: VkVertexInputBindingDescription;
  Attributes: array[0..5] of VkVertexInputAttributeDescription;
  VertexInput: VkPipelineVertexInputStateCreateInfo;
  Assembly: VkPipelineInputAssemblyStateCreateInfo;
  Viewport: VkPipelineViewportStateCreateInfo;
  Raster: VkPipelineRasterizationStateCreateInfo;
  Multisample: VkPipelineMultisampleStateCreateInfo;
  DepthStencil: VkPipelineDepthStencilStateCreateInfo;
  Blend: VkPipelineColorBlendAttachmentState;
  BlendState: VkPipelineColorBlendStateCreateInfo;
  dynamic: VkPipelineDynamicStateCreateInfo;
  DynamicStates: array[0..5] of VkDynamicState;
  Info: VkGraphicsPipelineCreateInfo;
begin
  for var I := 0 to 1 do
  begin
    Stages[I] := Default(VkPipelineShaderStageCreateInfo);
    Stages[I].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    Stages[I].pName := 'main';
  end;
  Stages[0].stage := VK_SHADER_STAGE_VERTEX_BIT;
  Stages[0].module := FVertexModule;
  var Blended := ((Key shr 43) and 1) <> 0;
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  if Blended then
    Stages[1].module := FBlendModule
  else
    Stages[1].module := FFragmentModule;
  Binding.binding := 0;
  Binding.stride := SizeOf(TGEHLEVertex);
  Binding.inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
  Attributes[0].location := 0;
  Attributes[0].Binding := 0;
  Attributes[0].Format := VK_FORMAT_R32G32B32_SFLOAT;
  Attributes[0].offset := 0;
  Attributes[1].location := 1;
  Attributes[1].Binding := 0;
  Attributes[1].Format := VK_FORMAT_R8G8B8A8_UNORM;
  Attributes[1].offset := 12;
  Attributes[2].location := 2;
  Attributes[2].Binding := 0;
  Attributes[2].Format := VK_FORMAT_R8G8B8A8_UNORM;
  Attributes[2].offset := 16;
  Attributes[3].location := 3;
  Attributes[3].Binding := 0;
  Attributes[3].Format := VK_FORMAT_R32G32B32A32_SFLOAT;
  Attributes[3].offset := 20;
  Attributes[4].location := 4;
  Attributes[4].Binding := 0;
  Attributes[4].Format := VK_FORMAT_R32_SFLOAT;
  Attributes[4].offset := 36;
  Attributes[5].location := 5;
  Attributes[5].Binding := 0;
  Attributes[5].Format := VK_FORMAT_R32G32B32A32_SFLOAT;
  Attributes[5].offset := 40;
  VertexInput := Default(VkPipelineVertexInputStateCreateInfo);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  VertexInput.vertexBindingDescriptionCount := 1;
  VertexInput.pVertexBindingDescriptions := @Binding;
  VertexInput.vertexAttributeDescriptionCount := 6;
  VertexInput.pVertexAttributeDescriptions := @Attributes[0];
  Assembly := Default(VkPipelineInputAssemblyStateCreateInfo);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  case Key and 3 of
    KindLine:
      Assembly.topology := VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
    KindPoint:
      Assembly.topology := VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
  else
    Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
  end;
  Viewport := Default(VkPipelineViewportStateCreateInfo);
  Viewport.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  Viewport.viewportCount := 1;
  Viewport.scissorCount := 1;
  Raster := Default(VkPipelineRasterizationStateCreateInfo);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  Raster.depthClampEnable := Ord(FCompute.Features.DepthClamp);
  Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := VK_CULL_MODE_NONE;
  Raster.frontFace := VK_FRONT_FACE_COUNTER_CLOCKWISE;
  Raster.lineWidth := 1;
  Multisample := Default(VkPipelineMultisampleStateCreateInfo);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := VK_SAMPLE_COUNT_1_BIT;
  DepthStencil := Default(VkPipelineDepthStencilStateCreateInfo);
  DepthStencil.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  DepthStencil.depthTestEnable := (Key shr 25) and 1;
  DepthStencil.depthWriteEnable := (Key shr 26) and 1;
  DepthStencil.depthCompareOp := (Key shr 27) and 7;
  DepthStencil.stencilTestEnable := (Key shr 30) and 1;
  DepthStencil.front.compareOp := (Key shr 31) and 7;
  DepthStencil.front.failOp := (Key shr 34) and 7;
  DepthStencil.front.depthFailOp := (Key shr 37) and 7;
  DepthStencil.front.passOp := (Key shr 40) and 7;
  DepthStencil.front.compareMask := $FF;
  DepthStencil.front.writeMask := $FF;
  DepthStencil.back := DepthStencil.front;
  DepthStencil.maxDepthBounds := 1;
  Blend := Default(VkPipelineColorBlendAttachmentState);
  Blend.blendEnable := (Key shr 2) and 1;
  Blend.srcColorBlendFactor := (Key shr 3) and 31;
  Blend.dstColorBlendFactor := (Key shr 8) and 31;
  Blend.colorBlendOp := (Key shr 13) and 7;
  Blend.srcAlphaBlendFactor := VK_BLEND_FACTOR_ONE;
  Blend.dstAlphaBlendFactor := VK_BLEND_FACTOR_ZERO;
  Blend.alphaBlendOp := VK_BLEND_OP_ADD;
  Blend.colorWriteMask := (Key shr 16) and 15;
  BlendState := Default(VkPipelineColorBlendStateCreateInfo);
  BlendState.sType := VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  BlendState.logicOpEnable := (Key shr 20) and 1;
  BlendState.logicOp := (Key shr 21) and 15;
  BlendState.attachmentCount := 1;
  BlendState.pAttachments := @Blend;
  DynamicStates[0] := VK_DYNAMIC_STATE_VIEWPORT;
  DynamicStates[1] := VK_DYNAMIC_STATE_SCISSOR;
  DynamicStates[2] := VK_DYNAMIC_STATE_BLEND_CONSTANTS;
  DynamicStates[3] := VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK;
  DynamicStates[4] := VK_DYNAMIC_STATE_STENCIL_WRITE_MASK;
  DynamicStates[5] := VK_DYNAMIC_STATE_STENCIL_REFERENCE;
  dynamic := Default(VkPipelineDynamicStateCreateInfo);
  dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  dynamic.dynamicStateCount := 6;
  dynamic.pDynamicStates := @DynamicStates[0];
  Info := Default(VkGraphicsPipelineCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
  Info.stageCount := 2;
  Info.pStages := @Stages[0];
  Info.pVertexInputState := @VertexInput;
  Info.pInputAssemblyState := @Assembly;
  Info.pViewportState := @Viewport;
  Info.pRasterizationState := @Raster;
  Info.pMultisampleState := @Multisample;
  Info.pDepthStencilState := @DepthStencil;
  Info.pColorBlendState := @BlendState;
  Info.pDynamicState := @dynamic;
  Info.layout := FLayout;
  Info.renderPass := FRenderPass;
  if Blended then
  begin
    Info.pDepthStencilState := nil;
    BlendState.logicOpEnable := 0;
    BlendState.attachmentCount := 0;
    Info.layout := FBlendLayout;
    Info.renderPass := FBlendPass;
  end;
  Info.basePipelineIndex := -1;
  CheckVulkan(FAPI.vkCreateGraphicsPipelines(FDevice, 0, 1, @Info, nil, @Result), 'vkCreateGraphicsPipelines');
end;

procedure TGEVulkanHLEBackend.DestroyTarget(T: TVulkanHLETarget);
begin
  var G := TGEHLETarget(T);
  if G.DownSet <> 0 then
    FAPI.vkFreeDescriptorSets(FDevice, FDownPool, 1, @G.DownSet);
  if G.BlendSet <> 0 then
    FAPI.vkFreeDescriptorSets(FDevice, FBlendPool, 1, @G.BlendSet);
  if G.BlendFramebuffer <> 0 then
    FAPI.vkDestroyFramebuffer(FDevice, G.BlendFramebuffer, nil);
  if G.ZView <> 0 then
    FAPI.vkDestroyImageView(FDevice, G.ZView, nil);
  if G.SView <> 0 then
    FAPI.vkDestroyImageView(FDevice, G.SView, nil);
  inherited;
end;

// The down-sampling kernel (source/gpu/shaders/PSPGEHLEDown.comp): the
// colour, depth and stencil of a target, the read-back buffer.
procedure TGEVulkanHLEBackend.CreateDown;
var
  Bindings: array[0..4] of VkDescriptorSetLayoutBinding;
  SetInfo: VkDescriptorSetLayoutCreateInfo;
  Push: VkPushConstantRange;
  Info: VkPipelineLayoutCreateInfo;
  Sizes: array[0..2] of VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
  Pipe: VkComputePipelineCreateInfo;
begin
  for var I := 0 to 4 do
  begin
    Bindings[I] := Default(VkDescriptorSetLayoutBinding);
    Bindings[I].Binding := I;
    Bindings[I].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    Bindings[I].descriptorCount := 1;
    Bindings[I].stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
  end;
  Bindings[3].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Bindings[4].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := 5;
  SetInfo.pBindings := @Bindings[0];
  CheckVulkan(FAPI.vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @FDownSetLayout), 'vkCreateDescriptorSetLayout');
  Push.stageFlags := VK_SHADER_STAGE_COMPUTE_BIT;
  Push.offset := 0;
  Push.size := 32;
  Info := Default(VkPipelineLayoutCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  Info.setLayoutCount := 1;
  Info.pSetLayouts := @FDownSetLayout;
  Info.pushConstantRangeCount := 1;
  Info.pPushConstantRanges := @Push;
  CheckVulkan(FAPI.vkCreatePipelineLayout(FDevice, @Info, nil, @FDownLayout), 'vkCreatePipelineLayout');
  Sizes[0].&type := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  Sizes[0].descriptorCount := 3 * (HLEMaxTargets + 8);
  Sizes[1].&type := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Sizes[1].descriptorCount := HLEMaxTargets + 8;
  Sizes[2].&type := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Sizes[2].descriptorCount := HLEMaxTargets + 8;
  PoolInfo := Default(VkDescriptorPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.flags := VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
  PoolInfo.maxSets := HLEMaxTargets + 8;
  PoolInfo.poolSizeCount := 3;
  PoolInfo.pPoolSizes := @Sizes[0];
  CheckVulkan(FAPI.vkCreateDescriptorPool(FDevice, @PoolInfo, nil, @FDownPool), 'vkCreateDescriptorPool');
  FDownModule := FCompute.CreateShaderModule(PSPGEHLEDownSPV);
  Pipe := Default(VkComputePipelineCreateInfo);
  Pipe.sType := VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
  Pipe.stage.sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
  Pipe.stage.stage := VK_SHADER_STAGE_COMPUTE_BIT;
  Pipe.stage.module := FDownModule;
  Pipe.stage.pName := 'main';
  Pipe.layout := FDownLayout;
  Pipe.basePipelineIndex := -1;
  CheckVulkan(FAPI.vkCreateComputePipelines(FDevice, 0, 1, @Pipe, nil, @FDownPipeline), 'vkCreateComputePipelines');
end;

// The shader-blending pipelines' fragment shader (PSPGEHLEBlend.frag), set 1
// (the target's colour as a storage image, its depth and stencil sampled),
// layout and render pass without attachments.
procedure TGEVulkanHLEBackend.CreateBlend;
var
  Bindings: array[0..2] of VkDescriptorSetLayoutBinding;
  SetInfo: VkDescriptorSetLayoutCreateInfo;
  Layouts: array[0..1] of VkDescriptorSetLayout;
  Push: VkPushConstantRange;
  Info: VkPipelineLayoutCreateInfo;
  Sizes: array[0..1] of VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
  Subpass: VkSubpassDescription;
  Deps: array[0..1] of VkSubpassDependency;
  PassInfo: VkRenderPassCreateInfo;
begin
  FBlendModule := FCompute.CreateShaderModule(PSPGEHLEBlendFragSPV);
  for var I := 0 to 2 do
  begin
    Bindings[I] := Default(VkDescriptorSetLayoutBinding);
    Bindings[I].Binding := I;
    Bindings[I].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    Bindings[I].descriptorCount := 1;
    Bindings[I].stageFlags := VK_SHADER_STAGE_FRAGMENT_BIT;
  end;
  Bindings[0].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := 3;
  SetInfo.pBindings := @Bindings[0];
  CheckVulkan(FAPI.vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @FBlendSetLayout),
    'vkCreateDescriptorSetLayout');
  Layouts[0] := FSetLayout;
  Layouts[1] := FBlendSetLayout;
  Push.stageFlags := VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT;
  Push.offset := 0;
  Push.size := SizeOf(TGEHLEPush);
  Info := Default(VkPipelineLayoutCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  Info.setLayoutCount := 2;
  Info.pSetLayouts := @Layouts[0];
  Info.pushConstantRangeCount := 1;
  Info.pPushConstantRanges := @Push;
  CheckVulkan(FAPI.vkCreatePipelineLayout(FDevice, @Info, nil, @FBlendLayout), 'vkCreatePipelineLayout');
  Sizes[0].&type := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Sizes[0].descriptorCount := HLEMaxTargets + 8;
  Sizes[1].&type := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  Sizes[1].descriptorCount := 2 * (HLEMaxTargets + 8);
  PoolInfo := Default(VkDescriptorPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.flags := VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
  PoolInfo.maxSets := HLEMaxTargets + 8;
  PoolInfo.poolSizeCount := 2;
  PoolInfo.pPoolSizes := @Sizes[0];
  CheckVulkan(FAPI.vkCreateDescriptorPool(FDevice, @PoolInfo, nil, @FBlendPool), 'vkCreateDescriptorPool');
  Subpass := Default(VkSubpassDescription);
  Subpass.pipelineBindPoint := VK_PIPELINE_BIND_POINT_GRAPHICS;
  Deps[0] := Default(VkSubpassDependency);
  Deps[0].srcSubpass := VK_SUBPASS_EXTERNAL;
  Deps[0].dstSubpass := 0;
  Deps[0].srcStageMask := VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
  Deps[0].dstStageMask := VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
  Deps[0].srcAccessMask := VK_ACCESS_MEMORY_WRITE_BIT;
  Deps[0].dstAccessMask := VK_ACCESS_MEMORY_READ_BIT or VK_ACCESS_MEMORY_WRITE_BIT;
  Deps[1] := Deps[0];
  Deps[1].srcSubpass := 0;
  Deps[1].dstSubpass := VK_SUBPASS_EXTERNAL;
  PassInfo := Default(VkRenderPassCreateInfo);
  PassInfo.sType := VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
  PassInfo.subpassCount := 1;
  PassInfo.pSubpasses := @Subpass;
  PassInfo.dependencyCount := 2;
  PassInfo.pDependencies := @Deps[0];
  CheckVulkan(FAPI.vkCreateRenderPass(FDevice, @PassInfo, nil, @FBlendPass), 'vkCreateRenderPass');
end;

// A target's set 1 and framebuffer for the shader-blending pipelines.
procedure TGEVulkanHLEBackend.CreateBlendTarget(T: TGEHLETarget);
var
  Alloc: VkDescriptorSetAllocateInfo;
  Images: array[0..2] of VkDescriptorImageInfo;
  Writes: array[0..2] of VkWriteDescriptorSet;
  Info: VkFramebufferCreateInfo;
begin
  Alloc := Default(VkDescriptorSetAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  Alloc.descriptorPool := FBlendPool;
  Alloc.descriptorSetCount := 1;
  Alloc.pSetLayouts := @FBlendSetLayout;
  CheckVulkan(FAPI.vkAllocateDescriptorSets(FDevice, @Alloc, @T.BlendSet), 'vkAllocateDescriptorSets');
  var Nearest := Sampler(0);
  Images[0].sampler := Nearest;
  Images[0].imageView := T.Color.View;
  Images[0].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Images[1].sampler := Nearest;
  Images[1].imageView := T.ZView;
  Images[1].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Images[2].sampler := Nearest;
  Images[2].imageView := T.SView;
  Images[2].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  for var I := 0 to 2 do
  begin
    Writes[I] := Default(VkWriteDescriptorSet);
    Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[I].dstSet := T.BlendSet;
    Writes[I].dstBinding := I;
    Writes[I].descriptorCount := 1;
    Writes[I].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    Writes[I].pImageInfo := @Images[I];
  end;
  Writes[0].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  FAPI.vkUpdateDescriptorSets(FDevice, 3, @Writes[0], 0, nil);
  Info := Default(VkFramebufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  Info.renderPass := FBlendPass;
  Info.width := T.Width * FScale;
  Info.height := T.Height * FScale;
  Info.layers := 1;
  CheckVulkan(FAPI.vkCreateFramebuffer(FDevice, @Info, nil, @T.BlendFramebuffer), 'vkCreateFramebuffer');
end;

// The colour's alpha made the stencil again (the fixed function's stencil
// operations leave it behind), on the GPU.
procedure TGEVulkanHLEBackend.RefreshAlpha(T: TGEHLETarget);
begin
  Record_;
  EndPass;
  ImageBarrier;
  DownSample(T, 0, 0, T.Width * FScale, T.Height * FScale, 0, 4, 1);
  ImageBarrier;
  T.AlphaStale := False;
end;

// What = 1: colour and stencil, 2: depth, of the box in PSP pixels, 3: the
// shown colour of the box in image pixels (Step 1), into the read-back buffer
// from word Offset. Step 0 is the scale.
procedure TGEVulkanHLEBackend.DownSample(T: TGEHLETarget; X, Y, W, H: Integer; Offset, What: Cardinal; Step: Integer);
var
  Push: array[0..7] of Integer;
begin
  var Cmd := Slot.Cmd.Handle;
  FAPI.vkCmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_COMPUTE, FDownPipeline);
  FAPI.vkCmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_COMPUTE, FDownLayout, 0, 1, @T.DownSet, 0, nil);
  Push[0] := X;
  Push[1] := Y;
  Push[2] := W;
  Push[3] := H;
  if Step = 0 then
    Step := FScale;
  Push[4] := Step;
  Push[5] := Integer(Offset);
  Push[6] := Integer(What);
  Push[7] := Integer(T.Format);
  FAPI.vkCmdPushConstants(Cmd, FDownLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, SizeOf(Push), @Push[0]);
  FAPI.vkCmdDispatch(Cmd, (W + 7) div 8, (H + 7) div 8, 1);
  // The draws' pipeline, texture and push constants are bound again.
  FBoundPipeline := 0;
  FBoundSet := 0;
  FPushValid := False;
end;

// A VRAM range (offsets, wrapping) with a held page.
function TGEVulkanHLEBackend.MemoryHeld(Addr, Size: Cardinal): Boolean;
begin
  if (FMemory.HeldVRAMPages = 0) or (Size = 0) then
    Exit(False);
  if Size >= PSPVRAMSize then
    Exit(True);
  var First := Addr shr PSPPageShift;
  var Last := (Addr + Size - 1) shr PSPPageShift;
  for var P := First to Last do
    if FMemory.VRAMHeld(P and (PSPVRAMSize div PSPPageSize - 1)) then
      Exit(True);
  Result := False;
end;

function DepthBytes(T: TGEHLETarget): Cardinal; inline;
begin
  Result := Cardinal(T.Height) * T.ZStride * 2;
end;

// The physical pages of rows Y1..Y2 of a depth buffer (each guest page of the
// depth view stays one physical page).
procedure TGEVulkanHLEBackend.HoldDepthRows(T: TGEHLETarget; Y1, Y2: Integer);
begin
  var A := (T.ZAddr + Cardinal(Y1) * T.ZStride * 2) and not Cardinal(PSPPageSize - 1);
  var Last := T.ZAddr + Cardinal(Y2 + 1) * T.ZStride * 2;
  while A < Last do
  begin
    FMemory.HoldVRAM(PSPDepthOffset(A and VRAMMask, T.ZPerm) shr PSPPageShift);
    Inc(A, PSPPageSize);
  end;
end;

function DepthHeld(M: TPSPMemory; ZAddr, Bytes: Cardinal; Perm: Integer): Boolean;
begin
  if M.HeldVRAMPages = 0 then
    Exit(False);
  var A := ZAddr and not Cardinal(PSPPageSize - 1);
  while A < ZAddr + Bytes do
  begin
    if M.VRAMHeld(PSPDepthOffset(A and VRAMMask, Perm) shr PSPPageShift) then
      Exit(True);
    Inc(A, PSPPageSize);
  end;
  Result := False;
end;

// Count depth values of row Y from X between guest memory and Values. The
// depth permutations keep 32-byte blocks whole: each block is one run.
procedure DepthRow(M: TPSPMemory; T: TGEHLETarget; X, Y, Count: Integer; Values: PWord; ToMemory: Boolean);
begin
  var A := T.ZAddr + (Cardinal(Y) * T.ZStride + Cardinal(X)) * 2;
  while Count > 0 do
  begin
    var N := Min(Count, Integer(32 - (A and 31)) div 2);
    var P := @M.VRAM[PSPDepthOffset(A, T.ZPerm)];
    if ToMemory then
      Move(Values^, P^, N * 2)
    else
      Move(P^, Values^, N * 2);
    Inc(Values, N);
    Inc(A, N * 2);
    Dec(Count, N);
  end;
end;

// The target S draws into, as tall as FNeedY needs.
function TGEVulkanHLEBackend.TargetFor(const S: TGERaster): TGEHLETarget;
begin
  var Addr := S.FBAddr and VRAMMask;
  var Fmt := S.FBFormat and 3;
  var Stride := Cardinal(EnsureRange(Integer(S.FBStride), 1, 1024));
  // Rows past the end of VRAM would come round to its start.
  var MaxH := EnsureRange(Integer(PSPVRAMSize div (Stride * Bpp(Fmt))), 1, 1024);
  // Most targets are drawn whole: the display's height at least saves growing.
  Result := TGEHLETarget(FindTarget(Addr, Fmt, Stride, Bpp(Fmt), Min(FNeedY + 1, MaxH), Min(272, MaxH), MaxH));
end;

// A target's inputs to the down-sampling kernel.
procedure TGEVulkanHLEBackend.CreateDownSet(T: TGEHLETarget);
var
  Alloc: VkDescriptorSetAllocateInfo;
  Images: array[0..3] of VkDescriptorImageInfo;
  Buffer: VkDescriptorBufferInfo;
  Writes: array[0..4] of VkWriteDescriptorSet;
begin
  T.ZView := CreateView(T.Depth.Image, FDepthFormat, VK_IMAGE_ASPECT_DEPTH_BIT);
  T.SView := CreateView(T.Depth.Image, FDepthFormat, VK_IMAGE_ASPECT_STENCIL_BIT);
  Alloc := Default(VkDescriptorSetAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  Alloc.descriptorPool := FDownPool;
  Alloc.descriptorSetCount := 1;
  Alloc.pSetLayouts := @FDownSetLayout;
  CheckVulkan(FAPI.vkAllocateDescriptorSets(FDevice, @Alloc, @T.DownSet), 'vkAllocateDescriptorSets');
  var Nearest := Sampler(0);
  Images[0].sampler := Nearest;
  Images[0].imageView := T.Color.View;
  Images[0].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Images[1].sampler := Nearest;
  Images[1].imageView := T.ZView;
  Images[1].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Images[2].sampler := Nearest;
  Images[2].imageView := T.SView;
  Images[2].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Images[3].sampler := Nearest;
  Images[3].imageView := T.Color.View;
  Images[3].imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Buffer.buffer := FReadback.Handle;
  Buffer.offset := 0;
  Buffer.range := VK_WHOLE_SIZE;
  for var I := 0 to 4 do
  begin
    Writes[I] := Default(VkWriteDescriptorSet);
    Writes[I].sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    Writes[I].dstSet := T.DownSet;
    Writes[I].dstBinding := I;
    Writes[I].descriptorCount := 1;
    Writes[I].descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    if I < 3 then
      Writes[I].pImageInfo := @Images[I];
  end;
  Writes[3].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
  Writes[3].pBufferInfo := @Buffer;
  Writes[4].descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Writes[4].pImageInfo := @Images[3];
  FAPI.vkUpdateDescriptorSets(FDevice, 5, @Writes[0], 0, nil);
end;

// Rows of PSP pixels a band of an upload holds: Bytes for each pixel at the
// scale, and the staging buffer's half at most.
function TGEVulkanHLEBackend.BandRows(T: TVulkanHLETarget; Bytes: Integer): Integer;
begin
  Result := EnsureRange((HLEUploadCapacity div 2) div (T.Width * FScale * FScale * Bytes), 1, T.Height);
end;

// Guest memory's pixels into the colour image and the stencil aspect, each
// pixel as a block of the scale's size.
procedure TGEVulkanHLEBackend.LoadTarget(T: TVulkanHLETarget);
var
  RowColor: TArray<Cardinal>;
  RowStencil: TBytes;
begin
  var B := Bpp(T.Format);
  var V: PByte := @FMemory.VRAM[0];
  var SW := T.Width * FScale;
  // A row at the scale is built here and copied to the staging buffer, which
  // is only written (it may be write-combined memory).
  SetLength(RowColor, SW);
  SetLength(RowStencil, SW);
  var Rows := BandRows(T, 5);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    var ColorBytes := (Int64(SW) * N * FScale * 4 + 15) and not Int64(15);
    var Offset: Int64;
    var P := StageUpload(ColorBytes + Int64(SW) * N * FScale, Offset);
    var Color := PCardinal(P);
    var Stencil := P + ColorBytes;
    for var Y := Y0 to Y0 + N - 1 do
    begin
      var I := 0;
      for var X := 0 to T.Width - 1 do
      begin
        var A := (T.Addr + (Cardinal(Y) * T.Stride + Cardinal(X)) * B) and VRAMMask;
        var Px: Cardinal;
        if B = 4 then
          Px := PCardinal(V + A)^
        else
          Px := PWord(V + A)^;
        var R, G, BB: Cardinal;
        DecodeColor(T.Format, Px, R, G, BB);
        var S8 := Stencil8(T.Format, Px);
        var C := R or (G shl 8) or (BB shl 16) or (S8 shl 24);
        for var K := 0 to FScale - 1 do
        begin
          RowColor[I] := C;
          RowStencil[I] := S8;
          Inc(I);
        end;
      end;
      for var K := 0 to FScale - 1 do
      begin
        Move(RowColor[0], Color^, SW * 4);
        Inc(Color, SW);
        Move(RowStencil[0], Stencil^, SW);
        Inc(Stencil, SW);
      end;
    end;
    CopyToImage(T.Color.Image, VK_IMAGE_ASPECT_COLOR_BIT, Offset, 0, 0, Y0 * FScale, SW, N * FScale);
    CopyToImage(T.Depth.Image, VK_IMAGE_ASPECT_STENCIL_BIT, Offset + ColorBytes, 0, 0, Y0 * FScale, SW, N * FScale);
    Inc(Y0, N);
  end;
  TGEHLETarget(T).AlphaStale := False;
end;

procedure TGEVulkanHLEBackend.LoadDepth(T: TGEHLETarget);
var
  Row: TArray<Cardinal>;
begin
  SetLength(T.ZShadow, T.Width * T.Height);
  for var Y := 0 to T.Height - 1 do
    DepthRow(FMemory, T, 0, Y, T.Width, @T.ZShadow[Y * T.Width], False);
  var SW := T.Width * FScale;
  SetLength(Row, SW);
  var Rows := BandRows(T, 4);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    var Offset: Int64;
    var P := PCardinal(StageUpload(Int64(SW) * N * FScale * 4, Offset));
    for var Y := Y0 to Y0 + N - 1 do
    begin
      var I := 0;
      for var X := 0 to T.Width - 1 do
      begin
        var Z := T.ZShadow[Y * T.Width + X];
        // The fragment shader writes depth as Z / 65536, exact in a float.
        var D: Cardinal;
        if FD24 then
          D := Cardinal(Round(Z * (16777215 / 65536)))
        else
          PSingle(@D)^ := Z / 65536;
        for var K := 0 to FScale - 1 do
        begin
          Row[I] := D;
          Inc(I);
        end;
      end;
      for var K := 0 to FScale - 1 do
      begin
        Move(Row[0], P^, SW * 4);
        Inc(P, SW);
      end;
    end;
    CopyToImage(T.Depth.Image, VK_IMAGE_ASPECT_DEPTH_BIT, Offset, 0, 0, Y0 * FScale, SW, N * FScale);
    Inc(Y0, N);
  end;
  T.ZLoaded := True;
  Inc(FDepthLoads);
end;

function SameDepth(M: TPSPMemory; T: TGEHLETarget): Boolean;
begin
  if Length(T.ZShadow) <> T.Width * T.Height then
    Exit(False);
  var Row: array[0..1023] of Word;
  for var Y := 0 to T.Height - 1 do
  begin
    DepthRow(M, T, 0, Y, T.Width, @Row[0], False);
    if not CompareMem(@Row[0], @T.ZShadow[Y * T.Width], T.Width * 2) then
      Exit(False);
  end;
  Result := True;
end;

// The depth aspect of one target's image into another's, on the GPU.
procedure TGEVulkanHLEBackend.CopyDepth(Source, Dest: TGEHLETarget);
var
  Region: VkImageCopy;
begin
  Record_;
  EndPass;
  ImageBarrier;
  Region := Default(VkImageCopy);
  Region.srcSubresource.aspectMask := VK_IMAGE_ASPECT_DEPTH_BIT;
  Region.srcSubresource.layerCount := 1;
  Region.dstSubresource := Region.srcSubresource;
  Region.extent.width := Min(Source.Width, Dest.Width) * FScale;
  Region.extent.height := Min(Source.Height, Dest.Height) * FScale;
  Region.extent.depth := 1;
  FAPI.vkCmdCopyImage(Slot.Cmd.Handle, Source.Depth.Image, VK_IMAGE_LAYOUT_GENERAL, Dest.Depth.Image,
    VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
  Inc(FDepthCopies);
end;

procedure TGEVulkanHLEBackend.EnsureDepth(T: TGEHLETarget; const S: TGERaster);
begin
  var ZA := S.ZAddr and VRAMMask;
  var ZS := Max(S.ZStride, 1);
  var ZP := S.ZPermutation;
  var Same := T.ZLoaded and (T.ZAddr = ZA) and (T.ZStride = ZS) and (T.ZPerm = ZP);
  if Same and T.ZDirty then
    Exit;
  // Its own depth buffer was another one: that goes back first.
  if T.ZDirty then
    FlushAll;
  // The newest values of this depth buffer may be another target's: they
  // move over on the GPU when that image covers this one, else through VRAM.
  for var V in FTargets do
  begin
    var U := TGEHLETarget(V);
    if (U <> T) and U.ZDirty and (U.ZAddr = ZA) and (U.ZStride = ZS) and (U.ZPerm = ZP) then
    begin
      if (U.Width <> T.Width) or (U.Height < T.Height) then
      begin
        StoreDepth(U);
        Break;
      end;
      CopyDepth(U, T);
      T.ZAddr := ZA;
      T.ZStride := ZS;
      T.ZPerm := ZP;
      T.ZLoaded := True;
      T.ZShadow := Copy(U.ZShadow);
      T.ZDirty := True;
      T.ZX1 := U.ZX1;
      T.ZY1 := U.ZY1;
      T.ZX2 := Min(U.ZX2, T.Width - 1);
      T.ZY2 := Min(U.ZY2, T.Height - 1);
      // The same pages stay held and watched.
      T.ZHeldY1 := U.ZHeldY1;
      T.ZHeldY2 := U.ZHeldY2;
      T.ZStale := U.ZStale;
      U.ZDirty := False;
      Exit;
    end;
  end;
  T.ZAddr := ZA;
  T.ZStride := ZS;
  T.ZPerm := ZP;
  // Compared in this run already: its pages are watched since.
  if Same and (T.ZVerified = FRun) then
    Exit;
  if Same and SameDepth(FMemory, T) then
  begin
    T.ZVerified := FRun;
    Exit;
  end;
  if DepthHeld(FMemory, ZA, DepthBytes(T), ZP) then
    FlushAll;
  // Targets drawn in turn with one depth buffer: the one that drew last
  // still has what guest memory has, and its image is copied on the GPU.
  for var V in FTargets do
  begin
    var U := TGEHLETarget(V);
    if (U <> T) and U.ZLoaded and not U.ZDirty and (U.ZAddr = ZA) and (U.ZStride = ZS) and (U.ZPerm = ZP) and
      (U.Width = T.Width) and (U.Height >= T.Height) and ((U.ZVerified = FRun) or SameDepth(FMemory, U)) then
    begin
      U.ZVerified := FRun;
      CopyDepth(U, T);
      T.ZLoaded := True;
      T.ZShadow := Copy(U.ZShadow, 0, T.Width * T.Height);
      T.ZVerified := FRun;
      Exit;
    end;
  end;
  LoadDepth(T);
  T.ZVerified := FRun;
end;

// The colour and stencil of the box drawn, and the depth of the box written,
// back into guest memory (one wait for the GPU).
procedure TGEVulkanHLEBackend.StoreTarget(T: TVulkanHLETarget);
begin
  Store(TGEHLETarget(T));
end;

// T's newer depth alone back into guest memory (a FlushAll for one depth
// buffer): its pages are no longer held unless another target holds them,
// and a new run starts (what was compared with them is compared again).
procedure TGEVulkanHLEBackend.StoreDepth(T: TGEHLETarget);
begin
  var Dirty := T.Dirty;
  T.Dirty := False;
  try
    Store(T);
  finally
    T.Dirty := Dirty;
  end;
  Inc(FStats.Readbacks);
  ReleaseHolds;
  for var V in FTargets do
  begin
    var U := TGEHLETarget(V);
    if U.Dirty and (U.HeldY1 <= U.HeldY2) then
    begin
      var RowBytes := U.Stride * U.PixelBytes;
      HoldMemory(U.Addr + Cardinal(U.HeldY1) * RowBytes, Cardinal(U.HeldY2 - U.HeldY1 + 1) * RowBytes);
    end;
    if U.ZDirty and (U.ZHeldY1 <= U.ZHeldY2) then
      HoldDepthRows(U, U.ZHeldY1, U.ZHeldY2);
  end;
  NewRun;
end;

procedure TGEVulkanHLEBackend.Store(T: TGEHLETarget);
var
  Regions: array[0..2] of VkBufferImageCopy;
begin
  var CW := 0;
  var CH := 0;
  var ZW := 0;
  var ZH := 0;
  if T.Dirty then
  begin
    T.X1 := Max(T.X1, 0);
    T.Y1 := Max(T.Y1, 0);
    T.X2 := Min(T.X2, T.Width - 1);
    T.Y2 := Min(T.Y2, T.Height - 1);
    CW := Max(T.X2 - T.X1 + 1, 0);
    CH := Max(T.Y2 - T.Y1 + 1, 0);
  end;
  if T.ZDirty then
  begin
    T.ZX1 := Max(T.ZX1, 0);
    T.ZY1 := Max(T.ZY1, 0);
    T.ZX2 := Min(T.ZX2, T.Width - 1);
    T.ZY2 := Min(T.ZY2, T.Height - 1);
    ZW := Max(T.ZX2 - T.ZX1 + 1, 0);
    ZH := Max(T.ZY2 - T.ZY1 + 1, 0);
  end;
  var ColorBytes := (Int64(CW) * CH * 4 + 15) and not Int64(15);
  var StencilBytes := (Int64(CW) * CH + 15) and not Int64(15);
  if ColorBytes + StencilBytes + Int64(ZW) * ZH * 4 > Int64(FReadback.Size) then
    raise EVulkanError.Create('A target is larger than the read back buffer.');
  Record_;
  EndPass;
  ImageBarrier;
  var Count := 0;
  if FScale = 1 then
  begin
    if CW * CH > 0 then
    begin
      Regions[0] := Default(VkBufferImageCopy);
      Regions[0].bufferOffset := 0;
      Regions[0].imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
      Regions[0].imageSubresource.layerCount := 1;
      Regions[0].imageOffset.x := T.X1;
      Regions[0].imageOffset.y := T.Y1;
      Regions[0].imageExtent.width := CW;
      Regions[0].imageExtent.height := CH;
      Regions[0].imageExtent.depth := 1;
      FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1,
        @Regions[0]);
      Regions[1] := Regions[0];
      Regions[1].bufferOffset := ColorBytes;
      Regions[1].imageSubresource.aspectMask := VK_IMAGE_ASPECT_STENCIL_BIT;
      FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, T.Depth.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1,
        @Regions[1]);
      Inc(Count);
    end;
    if ZW * ZH > 0 then
    begin
      Regions[2] := Default(VkBufferImageCopy);
      Regions[2].bufferOffset := ColorBytes + StencilBytes;
      Regions[2].imageSubresource.aspectMask := VK_IMAGE_ASPECT_DEPTH_BIT;
      Regions[2].imageSubresource.layerCount := 1;
      Regions[2].imageOffset.x := T.ZX1;
      Regions[2].imageOffset.y := T.ZY1;
      Regions[2].imageExtent.width := ZW;
      Regions[2].imageExtent.height := ZH;
      Regions[2].imageExtent.depth := 1;
      FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, T.Depth.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1,
        @Regions[2]);
      Inc(Count);
    end;
  end
  else
  begin
    // At a scale the images go through the down-sampling kernel: colour with
    // the stencil in its alpha, then depth as floats.
    if CW * CH > 0 then
    begin
      DownSample(T, T.X1, T.Y1, CW, CH, 0, 1);
      Inc(Count);
    end;
    if ZW * ZH > 0 then
    begin
      DownSample(T, T.ZX1, T.ZY1, ZW, ZH, Cardinal((ColorBytes + StencilBytes) div 4), 2);
      Inc(Count);
    end;
  end;
  HostReadBarrier;
  WaitAll;
  if Count > 0 then
    FReadback.Invalidate;
  var Scaled := FScale > 1;
  var V: PByte := @FMemory.VRAM[0];
  if CW * CH > 0 then
  begin
    var B := Bpp(T.Format);
    var C := PCardinal(FReadback.Data);
    var St := FReadback.Data + ColorBytes;
    for var Y := T.Y1 to T.Y2 do
    begin
      var A := (T.Addr + (Cardinal(Y) * T.Stride + Cardinal(T.X1)) * B) and VRAMMask;
      if (T.Format = 3) and (A + Cardinal(CW) * 4 <= PSPVRAMSize) then
      begin
        // The common case, a row in one piece.
        var D := PCardinal(V + A);
        if Scaled then
          Move(C^, D^, CW * 4)
        else
          for var X := 0 to CW - 1 do
            D[X] := (C[X] and $FFFFFF) or (Cardinal(St[X]) shl 24);
        Inc(C, CW);
        Inc(St, CW);
        Continue;
      end;
      for var X := T.X1 to T.X2 do
      begin
        var Px := C^;
        Inc(C);
        var S8: Cardinal := St^;
        if Scaled then
          S8 := Px shr 24;
        var P := EncodeColorOf(T.Format, Px and $FF, (Px shr 8) and $FF, (Px shr 16) and $FF) or
          StencilBitsOf(T.Format, S8);
        Inc(St);
        A := (T.Addr + (Cardinal(Y) * T.Stride + Cardinal(X)) * B) and VRAMMask;
        if B = 4 then
          PCardinal(V + A)^ := P
        else
          PWord(V + A)^ := Word(P);
      end;
    end;
  end;
  if ZW * ZH > 0 then
  begin
    var Z := PCardinal(FReadback.Data + ColorBytes + StencilBytes);
    var Row: array[0..1023] of Word;
    for var Y := T.ZY1 to T.ZY2 do
    begin
      for var X := 0 to ZW - 1 do
      begin
        // The fragment shader writes k / 65536: the product is k.
        var F: Single;
        if FD24 and not Scaled then
          F := (Z^ and $FFFFFF) * (65536 / 16777215)
        else
          F := PSingle(Z)^ * 65536;
        Inc(Z);
        if not (F > 0) then
          Row[X] := 0
        else if F >= 65535 then
          Row[X] := 65535
        else
          Row[X] := Trunc(F + 0.5);
      end;
      DepthRow(FMemory, T, T.ZX1, Y, ZW, @Row[0], True);
      // The shadow is what guest memory holds now.
      if Length(T.ZShadow) = T.Width * T.Height then
        Move(Row[0], T.ZShadow[Y * T.Width + T.ZX1], ZW * 2);
    end;
  end;
  if T.ZDirty then
  begin
    T.ZDirty := False;
    T.ZStale := False;
    // Outside the box the image holds what guest memory held when it was
    // loaded; a shadow of another size is taken again whole.
    if Length(T.ZShadow) <> T.Width * T.Height then
    begin
      SetLength(T.ZShadow, T.Width * T.Height);
      for var Y := 0 to T.Height - 1 do
        DepthRow(FMemory, T, 0, Y, T.Width, @T.ZShadow[Y * T.Width], False);
    end;
  end;
end;

procedure TGEVulkanHLEBackend.VRAMFault;
begin
  FlushAll;
end;

// Two VRAM ranges (offsets, wrapping round VRAM) share a byte.
function Overlaps(Addr, Bytes, Lo, Size: Cardinal): Boolean;
begin
  Result := (((Int64(Lo) - Addr) and VRAMMask) < Bytes) or (((Int64(Addr) - Lo) and VRAMMask) < Size);
end;

// A depth buffer's physical pages and a VRAM range share a page.
function DepthOverlaps(T: TGEHLETarget; Lo, Size: Cardinal): Boolean;
begin
  var A := T.ZAddr and not Cardinal(PSPPageSize - 1);
  while A < T.ZAddr + DepthBytes(T) do
  begin
    var Page := PSPDepthOffset(A and VRAMMask, T.ZPerm) and not Cardinal(PSPPageSize - 1);
    if Overlaps(Page, PSPPageSize, Lo, Size) then
      Exit(True);
    Inc(A, PSPPageSize);
  end;
  Result := False;
end;

// A watched page is about to be written: a texture's, a depth buffer's that
// was only read, or a drawn target's outside the rows drawn. The GPU draws
// from its own copies: nothing waits, nothing is read back. Textures and
// depth buffers are compared again when used; a drawn target the write may
// reach is Stale outside its rows. The other targets are watched again.
procedure TGEVulkanHLEBackend.WatchFault;
begin
  var Bytes := Max(FMemory.WatchSize, 1);
  var Data := FMemory.HostPtr(FMemory.WatchAddress, Bytes);
  FMemory.ReleaseWatches;
  NewRunForWrite(Data, Bytes);
  Inc(FStats.WatchFaults);
  var A := FMemory.WatchAddress and $1FFFFFFF;
  if (A < PSPVRAMBase) or (A >= PSPVRAMBase + 4 * PSPVRAMSize) then
    Exit;
  // The odd mirrors permute bytes within 64 KB banks: the whole bank counts.
  var Lo, Size: Cardinal;
  if (A and PSPVRAMSize) <> 0 then
  begin
    Lo := A and VRAMMask and not Cardinal($FFFF);
    Size := $10000;
  end
  else
  begin
    Lo := A and VRAMMask;
    Size := Max(FMemory.WatchSize, 1);
  end;
  for var U in FTargets do
  begin
    var T := TGEHLETarget(U);
    if T.Dirty and not T.Stale and Overlaps(T.Addr, T.Bytes, Lo, Size) then
      T.Stale := True;
    if T.ZDirty and not T.ZStale and DepthOverlaps(T, Lo, Size) then
      T.ZStale := True;
    if T.Dirty and not T.Stale then
      WatchTarget(T);
    if T.ZDirty and not T.ZStale then
      WatchDepth(T);
  end;
end;

function IsClutFormat(Format: Integer): Boolean; inline;
begin
  Result := (Format >= 4) and (Format <= 7);
end;

// The bytes of a level its texels can come from, as far as they are compared.
function LevelBytes(const T: TGETexture; const L: TGETexLevel): Cardinal;
begin
  var N := Min(GELevelReach(T, L), UInt64(MaxSource));
  if L.Ptr <> nil then
    N := Min(N, UInt64(L.Size));
  Result := Cardinal(N);
end;

// Floor(V / 16).
function FloorDiv16(V: Integer): Integer; inline;
begin
  if V >= 0 then
    Result := V div 16
  else
    Result := -((15 - V) div 16);
end;

// Guest bytes a texture was decoded from: a write there (in any VRAM mirror)
// first calls OnVRAMFault. The odd mirrors permute bytes within 64 KB banks,
// so all of a bank's pages there are watched.
procedure WatchBytes(M: TPSPMemory; Address, Size: Cardinal);
const
  VRAMPages = PSPVRAMSize shr PSPPageShift;
  BankPages = $10000 shr PSPPageShift;
  Linear0 = PSPVRAMBase shr PSPPageShift;
  Linear2 = ( PSPVRAMBase + 2 * PSPVRAMSize) shr PSPPageShift;
  Odd1 = ( PSPVRAMBase + PSPVRAMSize) shr PSPPageShift;
  Odd3 = ( PSPVRAMBase + 3 * PSPVRAMSize) shr PSPPageShift;
begin
  var A := Address and $1FFFFFFF;
  if Size = 0 then
    Size := 1;
  if (A >= PSPVRAMBase) and (A < PSPVRAMBase + 4 * PSPVRAMSize) then
  begin
    var Lo := A and VRAMMask;
    var Last := (UInt64(Lo) + Min(Size, PSPVRAMSize) - 1) shr PSPPageShift;
    for var Page := Integer(Lo shr PSPPageShift) to Integer(Last) do
    begin
      var P := Page mod VRAMPages;
      M.WatchPage(Linear0 + P);
      M.WatchPage(Linear2 + P);
      var Bank := P div BankPages;
      for var B := Bank * BankPages to Bank * BankPages + BankPages - 1 do
      begin
        M.WatchPage(Odd1 + B);
        M.WatchPage(Odd3 + B);
      end;
    end;
  end
  else
  begin
    var Last := Min(UInt64(A) + Size - 1, UInt64($1FFFFFFF)) shr PSPPageShift;
    for var Page := Integer(A shr PSPPageShift) to Integer(Last) do
      M.WatchPage(Page);
  end;
end;

{ Guest memory: VRAM offsets, wrapping round VRAM }

function TGEVulkanHLEBackend.MemoryEquals(Addr: Cardinal; Data: PByte; Size: Cardinal): Boolean;
begin
  var A := Addr and VRAMMask;
  var First := Min(Size, PSPVRAMSize - A);
  Result := CompareMem(@FMemory.VRAM[A], Data, First) and ((First = Size) or
    CompareMem(@FMemory.VRAM[0], Data + First, Size - First));
end;

procedure TGEVulkanHLEBackend.ReadMemory(Addr: Cardinal; Data: PByte; Size: Cardinal);
begin
  var A := Addr and VRAMMask;
  var First := Min(Size, PSPVRAMSize - A);
  Move(FMemory.VRAM[A], Data^, First);
  if First < Size then
    Move(FMemory.VRAM[0], (Data + First)^, Size - First);
end;

// The pages of the range, in every mirror (TPSPMemory.HoldVRAM).
procedure TGEVulkanHLEBackend.HoldMemory(Addr, Size: Cardinal);
begin
  for var P := Addr shr PSPPageShift to (Addr + Size - 1) shr PSPPageShift do
    FMemory.HoldVRAM(P and (PSPVRAMSize div PSPPageSize - 1));
end;

procedure TGEVulkanHLEBackend.ReleaseHolds;
begin
  FMemory.ReleaseVRAM;
end;

procedure TGEVulkanHLEBackend.WatchMemory(Addr, Size: Cardinal);
begin
  WatchBytes(FMemory, PSPVRAMBase + Addr, Size);
end;

procedure TGEVulkanHLEBackend.ReleaseWatches;
begin
  FMemory.ReleaseWatches;
end;

procedure WatchTextureBytes(M: TPSPMemory; First, Count: Integer; const S: TGERaster);
begin
  for var I := First to First + Count - 1 do
    WatchBytes(M, S.Tex.Levels[I].Addr, Cardinal(Min(GELevelReach(S.Tex, S.Tex.Levels[I]), UInt64(MaxSource))));
end;

// The physical pages of a depth buffer, watched in every mirror.
procedure TGEVulkanHLEBackend.WatchDepth(T: TGEHLETarget);
begin
  var A := T.ZAddr and not Cardinal(PSPPageSize - 1);
  while A < T.ZAddr + DepthBytes(T) do
  begin
    var Page := PSPDepthOffset(A and VRAMMask, T.ZPerm) shr PSPPageShift;
    WatchBytes(FMemory, PSPVRAMBase + (Page shl PSPPageShift), PSPPageSize);
    Inc(A, PSPPageSize);
  end;
end;

// Rows Y1..Y2 of a target are drawn with depth writes: the depth's pages of
// the rows not yet held are held.
procedure TGEVulkanHLEBackend.HoldNewDepthRows(T: TGEHLETarget; Y1, Y2: Integer);
begin
  if T.ZHeldY1 > T.ZHeldY2 then
  begin
    HoldDepthRows(T, Y1, Y2);
    T.ZHeldY1 := Y1;
    T.ZHeldY2 := Y2;
  end
  else
  begin
    if Y1 < T.ZHeldY1 then
    begin
      HoldDepthRows(T, Y1, T.ZHeldY1 - 1);
      T.ZHeldY1 := Y1;
    end;
    if Y2 > T.ZHeldY2 then
    begin
      HoldDepthRows(T, T.ZHeldY2 + 1, Y2);
      T.ZHeldY2 := Y2;
    end;
  end;
end;

// The bytes a texture's texels come from: its levels', then the CLUT's.
function SourceBytes(const R: TGEHLETexRequest; out Bytes: array of TVulkanHLEBytes): Integer;
begin
  var X: PGETexture := @R.S.Tex;
  Result := 0;
  for var I := R.First to R.First + R.Count - 1 do
  begin
    Bytes[Result].Data := X.Levels[I].Ptr;
    Bytes[Result].Size := Integer(LevelBytes(X^, X.Levels[I]));
    Inc(Result);
  end;
  if IsClutFormat(X.Format) and (X.Clut <> nil) then
  begin
    Bytes[Result].Data := X.Clut;
    Bytes[Result].Size := 1024;
    Inc(Result);
  end;
end;

function TGEVulkanHLEBackend.TextureMatches(T: TVulkanHLETexture; Request: Pointer): Boolean;
var
  // The eight levels and the CLUT at most.
  Bytes: array[0..8] of TVulkanHLEBytes;
begin
  if not T.Checkable then
    Exit(False);
  var N := SourceBytes(PGEHLETexRequest(Request)^, Bytes);
  Result := SameSource(T, Slice(Bytes, N));
end;

procedure TGEVulkanHLEBackend.DecodeTexture(T: TVulkanHLETexture; Request: Pointer);
var
  // The eight levels and the CLUT at most.
  Bytes: array[0..8] of TVulkanHLEBytes;
begin
  var R := PGEHLETexRequest(Request);
  var X: PGETexture := @R.S.Tex;
  KeepSource(T, Slice(Bytes, SourceBytes(R^, Bytes)));
  for var I := 0 to T.Levels - 1 do
  begin
    var Level := R.First + I;
    var W := Max(X.Levels[Level].Width, 1);
    var H := Max(X.Levels[Level].Height, 1);
    var P := LevelTexels(T, W, H);
    if X.Format in [8, 9, 10] then
    begin
      for var BY := 0 to (H + 3) div 4 - 1 do
        for var BX := 0 to (W + 3) div 4 - 1 do
        begin
          var Block: TGEDXTBlock;
          var Decoded := GEReadDXTBlock(X^, Level, BX, BY, Block);
          for var DY := 0 to Min(3, H - BY * 4 - 1) do
            for var DX := 0 to Min(3, W - BX * 4 - 1) do
            begin
              var Pixel: Cardinal;
              if Decoded then
                Pixel := Block[DY * 4 + DX]
              else
                Pixel := GEFetchTexel(X^, Level, BX * 4 + DX, BY * 4 + DY);
              PCardinal(PByte(P) + ((BY * 4 + DY) * W + BX * 4 + DX) * 4)^ := Pixel;
            end;
        end;
    end
    else
      for var Y := 0 to H - 1 do
        for var XX := 0 to W - 1 do
        begin
          P^ := GEFetchTexel(X^, Level, XX, Y);
          Inc(P);
        end;
    UploadLevel(T, I, W, H);
  end;
end;

procedure TGEVulkanHLEBackend.DescribeTexture(Request: Pointer; out Width, Height, Levels, Scale: Integer);
begin
  var R := PGEHLETexRequest(Request);
  var X: PGETexture := @R.S.Tex;
  Width := Max(X.Levels[R.First].Width, 1);
  Height := Max(X.Levels[R.First].Height, 1);
  Levels := R.Count;
  Scale := TextureScaleFor(X^, R.First, R.Count);
end;

procedure TGEVulkanHLEBackend.WatchSource(T: TVulkanHLETexture);
begin
  for var I := 0 to High(T.SourceData) do
  begin
    var P := NativeUInt(T.SourceData[I]);
    var Size := Cardinal(T.SourceSizes[I]);
    if Size = 0 then
      Continue;
    var RAM := NativeUInt(@FMemory.RAM[0]);
    var VRAM := NativeUInt(@FMemory.VRAM[0]);
    var Scratch := NativeUInt(@FMemory.Scratch[0]);
    if (P >= RAM) and (P - RAM < PSPRAMSize) and (Size <= PSPRAMSize - (P - RAM)) then
      WatchBytes(FMemory, PSPRAMBase + Cardinal(P - RAM), Size)
    else if (P >= VRAM) and (P - VRAM < PSPVRAMSize) and (Size <= PSPVRAMSize - (P - VRAM)) then
      WatchBytes(FMemory, PSPVRAMBase + Cardinal(P - VRAM), Size)
    else if (P >= Scratch) and (P - Scratch < PSPScratchSize) and (Size <= PSPScratchSize - (P - Scratch)) then
      WatchBytes(FMemory, PSPScratchBase + Cardinal(P - Scratch), Size);
    // The CLUT lives in the engine, not guest memory; its key changes on load.
  end;
end;

procedure TGEVulkanHLEBackend.WatchTexture(T: TVulkanHLETexture; Request: Pointer);
begin
  var R := PGEHLETexRequest(Request);
  WatchTextureBytes(FMemory, R.First, R.Count, R.S^);
end;

// A render target drawn from as a texture, sampled from its image (at its
// scale) without going through VRAM: one level, not swizzled, the target's
// format, address and stride, and an image that is current (newer than guest
// memory with no stale rows, or equal to it). Not the target the draw renders
// into, nor one that shares bytes with it. Nil when the texture is not one.
function TGEVulkanHLEBackend.TargetTexture(const S: TGERaster): TVulkanHLETexture;
begin
  Result := nil;
  var X: PGETexture := @S.Tex;
  if X.Swizzle or (X.Format > 3) then
    Exit;
  var Level := 0;
  if X.NeedLod then
  begin
    if (X.MinFilter >= 4) and (X.MaxLevel > 0) then
      Exit;
  end
  else
    Level := X.Level;
  var L: PGETexLevel := @X.Levels[Level];
  var A := L.Addr and $1FFFFFFF;
  if (A < PSPVRAMBase) or (A >= PSPVRAMBase + 4 * PSPVRAMSize) or ((A and PSPVRAMSize) <> 0) then
    Exit;
  var T: TGEHLETarget := nil;
  for var U in FTargets do
    if (U.Addr = A and VRAMMask) and (U.Format = Cardinal(X.Format)) and (U.Stride = Cardinal(L.BufWidth)) then
    begin
      T := TGEHLETarget(U);
      Break;
    end;
  if T = nil then
    Exit;
  var DrawBytes := Max(S.FBStride, 1) * Bpp(S.FBFormat and 3) * Cardinal(T.Height);
  if Overlaps(T.Addr, T.Bytes, S.FBAddr and VRAMMask, DrawBytes) then
    Exit;
  if T.Dirty then
  begin
    if T.Stale then
      Exit;
  end
  else if not T.Loaded or MemoryHeld(T.Addr, T.Bytes) or not ShadowMatches(T) then
    Exit;
  // Its alpha is its stencil.
  if T.AlphaStale then
    RefreshAlpha(T);
  Result := TargetAsTexture(T);
  // The texture's size in the PSP's texels.
  Result.Width := Max(L.Width, 1);
  Result.Height := Max(L.Height, 1);
end;

// The texture of S's level (or of its levels, halving in size, when the level
// of detail picks one), decoded, compared with its bytes, uploaded.
function TGEVulkanHLEBackend.EnsureTexture(const S: TGERaster): TVulkanHLETexture;
var
  Request: TGEHLETexRequest;
begin
  var X: PGETexture := @S.Tex;
  var First := 0;
  var Count := 1;
  if X.NeedLod then
  begin
    if (X.MinFilter >= 4) and (X.MaxLevel > 0) then
    begin
      var Last := Min(X.MaxLevel, High(X.Levels));
      if X.LevelCount > 0 then
        Last := Min(Last, X.LevelCount - 1);
      while (Count <= Last) and (X.Levels[Count].Width = Max(1, X.Levels[0].Width shr Count)) and
          (X.Levels[Count].Height = Max(1, X.Levels[0].Height shr Count)) do
        Inc(Count);
    end;
  end
  else
    First := EnsureRange(X.Level, 0, High(X.Levels));
  // A target's newer pixels there go back to VRAM first.
  if FMemory.HeldVRAMPages > 0 then
    for var I := First to First + Count - 1 do
    begin
      var A := X.Levels[I].Addr and $1FFFFFFF;
      if (A >= PSPVRAMBase) and (A < PSPVRAMBase + 4 * PSPVRAMSize) and (((A and PSPVRAMSize) <> 0) or MemoryHeld(A and
        VRAMMask, Cardinal(Min(GELevelReach(X^, X.Levels[I]), UInt64(PSPVRAMSize))))) then
      begin
        FlushAll;
        Break;
      end;
    end;
  var Key := FNV($CBF29CE484222325, UInt64(X.Format) or (UInt64(Ord(X.Swizzle)) shl 8) or (UInt64(First) shl 12) or
    (UInt64(Count) shl 16));
  if IsClutFormat(X.Format) then
  begin
    Key := FNV(Key, UInt64(Cardinal(X.ClutFormat)) or (UInt64(Cardinal(X.ClutShift)) shl 8) or
      (UInt64(Cardinal(X.ClutMask)) shl 16) or (UInt64(Cardinal(X.ClutOffset)) shl 32));
    if X.Clut <> nil then
      for var J := 0 to 127 do
        Key := FNV(Key, PUInt64(X.Clut)[J]);
  end;
  for var I := First to First + Count - 1 do
  begin
    Key := FNV(Key, X.Levels[I].Addr);
    Key := FNV(Key, UInt64(Cardinal(X.Levels[I].Width)) or (UInt64(Cardinal(X.Levels[I].Height)) shl 16) or
      (UInt64(Cardinal(X.Levels[I].BufWidth)) shl 32));
  end;
  Request.S := @S;
  Request.First := First;
  Request.Count := Count;
  Result := CachedTexture(Key, @Request);
end;

// The scale a new texture is made at (ScaleFor); 1 for textures that are
// decoded again in every GE run and levels that do not halve in both
// directions.
function TGEVulkanHLEBackend.TextureScaleFor(const X: TGETexture; First, Count: Integer): Integer;
begin
  Result := 1;
  var W := Max(X.Levels[First].Width, 1);
  var H := Max(X.Levels[First].Height, 1);
  var F := ScaleFor(W, H);
  if F < 2 then
    Exit;
  for var I := First to First + Count - 1 do
    if (X.Levels[I].Ptr = nil) or ((W shr (I - First)) = 0) or ((H shr (I - First)) = 0) then
      Exit;
  Result := F;
end;

function TGEVulkanHLEBackend.SameState(const S: TGERaster; Kind: Integer): Boolean;
begin
  Result := (Kind = FLastKind) and CompareMem(@S, @FLast, SizeOf(TGERaster));
  if Result and S.Textured and IsClutFormat(S.Tex.Format) and (S.Tex.Clut <> nil) then
    Result := CompareMem(S.Tex.Clut, @FLastClut[0], SizeOf(FLastClut));
end;

// The state the draw being built was set up for: compared only when the
// engine's serial says it may have changed.
function TGEVulkanHLEBackend.CurrentState(const S: TGERaster; Kind: Integer): Boolean;
begin
  var Serial := FEngineBackend.RasterSerial;
  if (Serial = FLastSerial) and (Kind = FLastKind) then
    Exit(True);
  Result := SameState(S, Kind);
  if Result then
    FLastSerial := Serial;
end;

// Whether the masks keep all of a channel's bits.
function ChannelKept(Keep, Bits: Cardinal): Boolean; inline;
begin
  Result := (Keep and Bits) = Bits;
end;

// The stencil bits drawing may change, as a mask of the 8-bit value. A 4-bit
// stencil is kept as its value times 17 and read back from the high nibble:
// its mask is in both nibbles.
function StencilWriteMask(Format, Keep: Cardinal): Cardinal;
begin
  case Format of
    1:
      if (Keep and $8000) <> 0 then
        Result := 0
      else
        Result := $FF;
    2:
      begin
        var M := not (Keep shr 12) and $F;
        Result := M or (M shl 4);
      end;
    3:
      Result := not (Keep shr 24) and $FF;
  else
    Result := 0;
  end;
end;

// The blend factors: the fixed function's where it has the GE's, a weight
// applied in the fragment shader (Premultiply) where it has not. Doubled
// destination alpha and the doubled factors on the destination side have no
// fixed-function equivalent; they are drawn undoubled.
function SourceFactor(const S: TGERaster; out Premultiply: Cardinal): Integer;
begin
  Premultiply := 0;
  case S.BlendSrc of
    0:
      Result := VK_BLEND_FACTOR_DST_COLOR;
    1:
      Result := VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
    2:
      Result := VK_BLEND_FACTOR_SRC_ALPHA;
    3:
      Result := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    4, 8:
      Result := VK_BLEND_FACTOR_DST_ALPHA;
    5, 9:
      Result := VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
    6:
      begin
        Premultiply := 2;
        Result := VK_BLEND_FACTOR_ONE;
      end;
    7:
      begin
        Premultiply := 3;
        Result := VK_BLEND_FACTOR_ONE;
      end;
  else
    if (S.FixA and $FFFFFF) = 0 then
      Result := VK_BLEND_FACTOR_ZERO
    else if (S.FixA and $FFFFFF) = $FFFFFF then
      Result := VK_BLEND_FACTOR_ONE
    else
    begin
      Premultiply := 1;
      Result := VK_BLEND_FACTOR_ONE;
    end;
  end;
end;

// A stencil operation that changes the stencil (keep is 0, and so are 6 and 7).
function WritesStencil(Op: Integer): Boolean; inline;
begin
  Result := (Op and 7) in [1..5];
end;

// The masks keep some of a colour channel's bits, not all or none.
function PartialMask(Format, Keep: Cardinal): Boolean;
begin
  Result := False;
  for var Bits in [EncodeColorOf(Format, 255, 0, 0), EncodeColorOf(Format, 0, 255, 0), EncodeColorOf(Format, 0, 0, 255)] do
    if ((Keep and Bits) <> 0) and ((Keep and Bits) <> Bits) then
      Exit(True);
end;

function DestFactor(const S: TGERaster): Integer;
begin
  case S.BlendDst of
    0:
      Result := VK_BLEND_FACTOR_SRC_COLOR;
    1:
      Result := VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR;
    2, 6:
      Result := VK_BLEND_FACTOR_SRC_ALPHA;
    3, 7:
      Result := VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    4, 8:
      Result := VK_BLEND_FACTOR_DST_ALPHA;
    5, 9:
      Result := VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
  else
    if (S.FixB and $FFFFFF) = 0 then
      Result := VK_BLEND_FACTOR_ZERO
    else if (S.FixB and $FFFFFF) = $FFFFFF then
      Result := VK_BLEND_FACTOR_ONE
    else
      Result := VK_BLEND_FACTOR_CONSTANT_COLOR;
  end;
end;

const
  // Add, subtract, reverse subtract, minimum, maximum; the absolute
  // difference is drawn as the maximum.
  BlendOps: array[0..7] of Integer = (VK_BLEND_OP_ADD, VK_BLEND_OP_SUBTRACT, VK_BLEND_OP_REVERSE_SUBTRACT,
    VK_BLEND_OP_MIN, VK_BLEND_OP_MAX, VK_BLEND_OP_MAX, VK_BLEND_OP_ADD, VK_BLEND_OP_ADD);

procedure TGEVulkanHLEBackend.SetupState(const S: TGERaster; Kind: Integer);
var
  Push: TGEHLEPush;
begin
  var Watch := TStopwatch.StartNew;
  FlushDraw;
  FStateValid := False;
  var Fmt := S.FBFormat and 3;
  var Clear := S.ClearMode;
  var Textured := S.Textured and not Clear;
  var Tex := FBlank;
  if Textured then
  begin
    Tex := TargetTexture(S);
    if Tex = nil then
      Tex := EnsureTexture(S);
  end;
  var T := TargetFor(S);
  EnsureTarget(T);
  var DepthTest := not Clear and S.DepthTest;
  if DepthTest or (Clear and S.ClearDepth) then
    EnsureDepth(T, S);
  // The shader fetches texels itself: one sampler serves every texture.
  var TexSet := TextureSet(Tex, 0);
  // From the first primitive on the target is newer than guest memory: the
  // rows drawn are held (Emit), the rest watched.
  BeginDrawing(T);
  FDepthWrites := (DepthTest and S.DepthWrite) or (Clear and S.ClearDepth);
  FDepthUsed := DepthTest or (Clear and S.ClearDepth);
  if FDepthWrites and not T.ZDirty then
  begin
    T.ZDirty := True;
    T.ZX1 := MaxInt;
    T.ZY1 := MaxInt;
    T.ZX2 := -1;
    T.ZY2 := -1;
    T.ZHeldY1 := MaxInt;
    T.ZHeldY2 := -1;
    T.ZStale := False;
    WatchDepth(T);
  end
  else if DepthTest and not T.ZDirty and (T.ZWatched <> FRun) then
  begin
    // Only read: the depth image stays valid until guest memory there is
    // written (the next GE run may not set the state up again).
    WatchDepth(T);
    T.ZWatched := FRun;
  end;

  var Key: UInt64 := Cardinal(Kind);
  var Flags := (Fmt shl 16) or (Cardinal(FScale) shl 24);
  var Keep := S.KeepMask;
  var WriteMask: Cardinal := 0;
  if not ChannelKept(Keep, EncodeColorOf(Fmt, 255, 0, 0)) then
    WriteMask := WriteMask or 1;
  if not ChannelKept(Keep, EncodeColorOf(Fmt, 0, 255, 0)) then
    WriteMask := WriteMask or 2;
  if not ChannelKept(Keep, EncodeColorOf(Fmt, 0, 0, 255)) then
    WriteMask := WriteMask or 4;
  var StencilWrite := StencilWriteMask(Fmt, Keep);
  var StencilRef := Cardinal(S.StencilRef and $FF);
  var StencilCompare := Cardinal(S.StencilMask and $FF);
  FClearStencil := False;
  Push := Default(TGEHLEPush);
  var Blended := False;
  if Clear then
  begin
    Flags := Flags or FLAG_CLEAR;
    if S.Dither then
      Flags := Flags or FLAG_DITHER;
    if not S.ClearColor then
      WriteMask := 0;
    if S.ClearStencil and (Fmt <> 0) and (StencilWrite <> 0) then
    begin
      // Always passes and replaces with the primitive's alpha (set in Emit).
      WriteMask := WriteMask or 8;
      FClearStencil := True;
      Key := Key or (UInt64(1) shl 30) or (UInt64(VK_COMPARE_OP_ALWAYS) shl 31) or
        (UInt64(VK_STENCIL_OP_REPLACE) shl 40);
    end;
    if S.ClearDepth then
      Key := Key or (UInt64(1) shl 25) or (UInt64(1) shl 26) or (UInt64(VK_COMPARE_OP_ALWAYS) shl 27);
  end
  else
  begin
    if Textured then
    begin
      Flags := Flags or FLAG_TEXTURED;
      var LodMode: Cardinal := 0;
      if S.Tex.NeedLod then
        // Automatic, the bias alone (also for the undefined mode 3), slope.
        case S.Tex.LevelMode of
          0:
            LodMode := 1;
          2:
            LodMode := 3;
        else
          LodMode := 2;
        end;
      Push.TexFunc := Cardinal(S.TexFunc and 7) or (Cardinal(Ord(S.TexAlpha)) shl 3) or
        (Cardinal(Ord(S.ColorDouble)) shl 4) or (LodMode shl 5) or (Cardinal(Ord(S.Tex.Linear)) shl 7) or
        (Cardinal(S.Tex.MinFilter and 7) shl 8) or (Cardinal(Ord(S.Tex.ClampU)) shl 11) or
        (Cardinal(Ord(S.Tex.ClampV)) shl 12) or (Cardinal(Tex.Levels - 1) shl 13);
      if Tex.Target <> nil then
        Push.TexFunc := Push.TexFunc or (Cardinal(1) shl 16) or (Cardinal(FScale) shl 17) or (Tex.Target.Format shl 21)
      else if Tex.Scale > 1 then
        Push.TexFunc := Push.TexFunc or (Cardinal(Tex.Scale) shl 17);
      Push.Env := PackColor(S.EnvR, S.EnvG, S.EnvB, 0);
      Push.LodBias := S.Tex.LodBias;
      Push.LodSlope := S.Tex.Slope;
    end;
    if S.FogEnabled then
    begin
      Flags := Flags or FLAG_FOG;
      Push.FogColor := PackColor(S.FogR, S.FogG, S.FogB, 0);
    end;
    if S.ColorTest then
      Flags := Flags or FLAG_COLORTEST or (Cardinal(S.ColorTestFunc and 3) shl 8);
    if S.AlphaTest then
    begin
      Flags := Flags or FLAG_ALPHATEST;
      Push.AlphaTest := Cardinal(S.AlphaFunc and 7) or (Cardinal(S.AlphaRef and $FF) shl 8) or
        (Cardinal(S.AlphaMask and $FF) shl 16);
    end;
    if not S.Through then
    begin
      Flags := Flags or FLAG_RANGE;
      if S.DepthClamp then
        Flags := Flags or FLAG_CLAMPZ;
    end;
    if S.Dither then
      Flags := Flags or FLAG_DITHER;
    // In the shader where the device can and the draw writes no depth or
    // stencil (those it only tests, from the images).
    var StencilTest := S.StencilTest and (Fmt <> 0);
    var StencilWrites := StencilTest and (WritesStencil(S.StencilFail) or WritesStencil(S.StencilZFail) or
      WritesStencil(S.StencilZPass));
    Blended := FShaderBlend and (S.Blend or (S.LogicOp and (S.LogicFunc <> 3)) or PartialMask(Fmt, Keep)) and
      not (DepthTest and S.DepthWrite) and not StencilWrites;
    // The fixed function changes the stencil but not its mirror in the alpha:
    // a blend with the destination's alpha needs it brought up to date.
    if T.AlphaStale and (Blended or (S.Blend and ((S.BlendSrc in [4, 5, 8, 9]) or (S.BlendDst in [4, 5, 8, 9])))) then
      RefreshAlpha(T);
    if StencilWrites then
      T.AlphaStale := True;
    if Blended then
    begin
      Key := Cardinal(Kind) or (UInt64(1) shl 43);
      Push.Blend := Cardinal(S.BlendSrc and 15) or (Cardinal(S.BlendDst and 15) shl 4) or (Cardinal(S.BlendOp and
          7) shl 8) or (Cardinal(Ord(S.Blend)) shl 11) or (Cardinal(S.LogicFunc and 15) shl 12) or
        (Cardinal(Ord(S.LogicOp)) shl 16) or (Cardinal(S.DepthFunc and 7) shl 20) or
        (Cardinal(Ord(DepthTest)) shl 23) or (Cardinal(S.StencilFunc and 7) shl 24) or
        (Cardinal(Ord(StencilTest)) shl 27);
      Push.FixB := S.FixB and $FFFFFF;
      Push.Keep := Keep;
      Push.Stencil := Cardinal(S.StencilRef and $FF) or (Cardinal(S.StencilMask and $FF) shl 8);
    end;
    var Logic := not Blended and S.LogicOp and (S.LogicFunc <> 3) and FCompute.Features.LogicOp;
    var Blend := not Blended and S.Blend and not Logic;
    // Unblended colours are stored as the target keeps them (logic
    // operations on the expanded values are the operations on its bits).
    if (Fmt < 3) and not Blend and not Blended then
      Flags := Flags or FLAG_QUANTIZE;
    if Blend then
    begin
      var Premultiply: Cardinal;
      var Src := SourceFactor(S, Premultiply);
      if S.BlendOp >= 3 then
        Premultiply := 0;
      Key := Key or 4 or (UInt64(Src) shl 3) or (UInt64(DestFactor(S)) shl 8) or
        (UInt64(BlendOps[S.BlendOp and 7]) shl 13);
      Flags := Flags or (Premultiply shl 12);
    end;
    if Logic then
      Key := Key or (UInt64(1) shl 20) or (UInt64(S.LogicFunc and 15) shl 21);
    if DepthTest and not Blended then
      Key := Key or (UInt64(1) shl 25) or (UInt64(Ord(S.DepthWrite)) shl 26) or (UInt64(CompareOps[S.DepthFunc and
            7]) shl 27);
    if StencilTest and not Blended then
      Key := Key or (UInt64(1) shl 30) or (UInt64(CompareOps[S.StencilFunc and 7]) shl 31) or
        (UInt64(StencilOps[S.StencilFail and 7]) shl 34) or (UInt64(StencilOps[S.StencilZFail and 7]) shl 37) or
        (UInt64(StencilOps[S.StencilZPass and 7]) shl 40);
  end;
  if not Blended then
    Key := Key or (UInt64(WriteMask) shl 16);

  Push.NdcX := 2 / T.Width;
  Push.NdcY := 2 / T.Height;
  Push.Flags := Flags;
  Push.ColorRef := S.ColorRef;
  Push.ColorMask := S.ColorMask;
  Push.MinZ := S.MinZ;
  Push.MaxZ := S.MaxZ;
  Push.TexW := Tex.Width;
  Push.TexH := Tex.Height;
  for var I := 0 to 7 do
  begin
    Push.Dither0 := Push.Dither0 or (Cardinal(S.DitherMatrix[I] and 15) shl (I * 4));
    Push.Dither1 := Push.Dither1 or (Cardinal(S.DitherMatrix[I + 8] and 15) shl (I * 4));
  end;
  Push.FixA := S.FixA and $FFFFFF;

  FWant.Pipeline := Pipeline(Key);
  FWant.TexSet := TexSet;
  Move(Push, FWant.Push[0], SizeOf(Push));
  var X1 := Max(S.ScissorX1, 0);
  var Y1 := Max(S.ScissorY1, 0);
  var X2 := Min(S.ScissorX2, T.Width - 1);
  var Y2 := Min(S.ScissorY2, T.Height - 1);
  FWant.Scissor.offset.x := X1 * FScale;
  FWant.Scissor.offset.y := Y1 * FScale;
  FWant.Scissor.extent.width := Cardinal(Max(X2 - X1 + 1, 0) * FScale);
  FWant.Scissor.extent.height := Cardinal(Max(Y2 - Y1 + 1, 0) * FScale);
  FWant.Blend := S.FixB and $FFFFFF;
  FWant.Blended := Blended;
  FWant.TargetSet := T.BlendSet;
  FWant.Stencil[0] := StencilCompare;
  FWant.Stencil[1] := StencilWrite;
  FWant.Stencil[2] := StencilRef;
  FTarget := T;
  ApplyBindings;

  FLast := S;
  FLastKind := Kind;
  FLastSerial := FEngineBackend.RasterSerial;
  if S.Textured and IsClutFormat(S.Tex.Format) and (S.Tex.Clut <> nil) then
    Move(S.Tex.Clut^, FLastClut[0], SizeOf(FLastClut));
  FTarget := T;
  FStateValid := True;
  FStats.SetupSeconds := FStats.SetupSeconds + Watch.Elapsed.TotalSeconds;
end;

// What SetupState chose, bound where it is not yet (the command buffer or its
// render pass may be new since).
procedure TGEVulkanHLEBackend.ApplyBindings;
var
  Consts: array[0..3] of Single;
begin
  if FWant.Blended then
    BeginPass(FTarget, FBlendPass, TGEHLETarget(FTarget).BlendFramebuffer)
  else
    BeginPass(FTarget, FRenderPass, FTarget.Framebuffer);
  var Cmd := Slot.Cmd.Handle;
  // Both layouts take set 0 and the push constants alike.
  var Layout := FLayout;
  if FWant.Blended then
    Layout := FBlendLayout;
  if FWant.Pipeline <> FBoundPipeline then
  begin
    FAPI.vkCmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FWant.Pipeline);
    FBoundPipeline := FWant.Pipeline;
  end;
  if FWant.TexSet <> FBoundSet then
  begin
    FAPI.vkCmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, Layout, 0, 1, @FWant.TexSet, 0, nil);
    FBoundSet := FWant.TexSet;
  end;
  if FWant.Blended and (FWant.TargetSet <> FBoundTargetSet) then
  begin
    FAPI.vkCmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FBlendLayout, 1, 1, @FWant.TargetSet, 0, nil);
    FBoundTargetSet := FWant.TargetSet;
  end;
  if not FPushValid or not CompareMem(@FWant.Push, @FBoundPush[0], SizeOf(FWant.Push)) then
  begin
    FAPI.vkCmdPushConstants(Cmd, Layout, VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT, 0,
      SizeOf(FWant.Push), @FWant.Push);
    Move(FWant.Push, FBoundPush[0], SizeOf(FWant.Push));
    FPushValid := True;
  end;
  if not FScissorValid or not CompareMem(@FWant.Scissor, @FBoundScissor, SizeOf(VkRect2D)) then
  begin
    FAPI.vkCmdSetScissor(Cmd, 0, 1, @FWant.Scissor);
    FBoundScissor := FWant.Scissor;
    FScissorValid := True;
  end;
  if not FBlendValid or (FBoundBlend <> FWant.Blend) then
  begin
    Consts[0] := (FWant.Blend and $FF) / 255;
    Consts[1] := ((FWant.Blend shr 8) and $FF) / 255;
    Consts[2] := ((FWant.Blend shr 16) and $FF) / 255;
    Consts[3] := 0;
    FAPI.vkCmdSetBlendConstants(Cmd, @Consts[0]);
    FBoundBlend := FWant.Blend;
    FBlendValid := True;
  end;
  if not FStencilValid or (FBoundStencil[0] <> FWant.Stencil[0]) then
    FAPI.vkCmdSetStencilCompareMask(Cmd, VK_STENCIL_FACE_FRONT_AND_BACK, FWant.Stencil[0]);
  if not FStencilValid or (FBoundStencil[1] <> FWant.Stencil[1]) then
    FAPI.vkCmdSetStencilWriteMask(Cmd, VK_STENCIL_FACE_FRONT_AND_BACK, FWant.Stencil[1]);
  if not FStencilValid or (FBoundStencil[2] <> FWant.Stencil[2]) then
    FAPI.vkCmdSetStencilReference(Cmd, VK_STENCIL_FACE_FRONT_AND_BACK, FWant.Stencil[2]);
  FBoundStencil := FWant.Stencil;
  FStencilValid := True;
end;

procedure TGEVulkanHLEBackend.Emit(Kind: Integer; const S: TGERaster; V: PGEHLEVertex; Count: Integer; X1, Y1, X2, Y2: Integer);
begin
  X1 := Max(X1, Max(S.ScissorX1, 0));
  Y1 := Max(Y1, Max(S.ScissorY1, 0));
  X2 := Min(X2, Min(S.ScissorX2, 1023));
  Y2 := Min(Y2, Min(S.ScissorY2, 1023));
  if (X1 > X2) or (Y1 > Y2) then
    Exit;
  ReserveVertices(Count);
  var T := TGEHLETarget(FTarget);
  if not FStateValid or not CurrentState(S, Kind) or ((Y2 >= T.Height) and (T.Height < T.MaxHeight)) then
  begin
    FNeedY := Y2;
    SetupState(S, Kind);
    T := TGEHLETarget(FTarget);
  end
  else if FPass <> T then
    ApplyBindings;
  X2 := Min(X2, T.Width - 1);
  Y2 := Min(Y2, T.Height - 1);
  if (X1 > X2) or (Y1 > Y2) then
    Exit;
  // Guest memory changed outside the rows drawn so far: the image there is
  // brought back to it before drawing there.
  if (T.Stale and ((Y1 < T.HeldY1) or (Y2 > T.HeldY2))) or (T.ZStale and FDepthUsed and
    ((Y1 < T.ZHeldY1) or (Y2 > T.ZHeldY2))) then
  begin
    FlushAll;
    FNeedY := Y2;
    SetupState(S, Kind);
    T := TGEHLETarget(FTarget);
  end;
  HoldNewRows(T, Y1, Y2);
  if FDepthWrites then
    HoldNewDepthRows(T, Y1, Y2);
  if FClearStencil then
  begin
    var A := V[Count - 1].Color shr 24;
    case T.Format of
      1:
        A := (A shr 7) * 255;
      2:
        A := (A shr 4) * 17;
    end;
    if FBoundStencil[2] <> A then
    begin
      FlushDraw;
      FAPI.vkCmdSetStencilReference(Slot.Cmd.Handle, VK_STENCIL_FACE_FRONT_AND_BACK, A);
      FBoundStencil[2] := A;
    end;
  end;
  AddVertices(V, Count);
  Drawn(T, X1, Y1, X2, Y2);
  if FDepthWrites then
  begin
    T.ZX1 := Min(T.ZX1, X1);
    T.ZY1 := Min(T.ZY1, Y1);
    T.ZX2 := Max(T.ZX2, X2);
    T.ZY2 := Max(T.ZY2, Y2);
  end;
  Inc(FStats.Prims);
end;

const
  NoBox: TGEHLEBox = (1, 1, 0, 0);

// A vertex at (X, Y) pixels with V's depth, coordinates and fog and C's
// colours. Perspective: the coordinates go through 1/w (triangles).
procedure PutVertex(out D: TGEHLEVertex; const V, C: TGEVertex; X, Y: Single; Perspective: Boolean); inline;
begin
  D.X := X;
  D.Y := Y;
  D.Box := NoBox;
  D.Z := V.Z;
  D.Color := PackColor(C.R, C.G, C.B, C.A);
  D.Secondary := PackColor(C.SR, C.SG, C.SB, 0);
  if Perspective then
  begin
    D.S := V.S * V.W;
    D.T := V.T * V.W;
    D.Q := V.Q * V.W;
    D.W := V.W;
  end
  else
  begin
    D.S := V.S;
    D.T := V.T;
    D.Q := V.Q;
    D.W := 1;
  end;
  D.Fog := V.Fog;
end;

procedure TGEVulkanHLEBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
var
  V: array[0..2] of TGEHLEVertex;
begin
  if Int64(V1.X - V0.X) * (V2.Y - V0.Y) - Int64(V1.Y - V0.Y) * (V2.X - V0.X) = 0 then
    Exit;
  // Flat shading takes the last vertex's colours.
  if S.Gouraud and not S.Flat then
  begin
    PutVertex(V[0], V0, V0, V0.X / 16, V0.Y / 16, True);
    PutVertex(V[1], V1, V1, V1.X / 16, V1.Y / 16, True);
  end
  else
  begin
    PutVertex(V[0], V0, V2, V0.X / 16, V0.Y / 16, True);
    PutVertex(V[1], V1, V2, V1.X / 16, V1.Y / 16, True);
  end;
  PutVertex(V[2], V2, V2, V2.X / 16, V2.Y / 16, True);
  var MinX := Min(V0.X, Min(V1.X, V2.X));
  var MinY := Min(V0.Y, Min(V1.Y, V2.Y));
  var MaxX := Max(V0.X, Max(V1.X, V2.X));
  var MaxY := Max(V0.Y, Max(V1.Y, V2.Y));
  // Pixels whose centres can be inside; above 1x those the triangle touches
  // at all (a triangle between the PSP's pixel centres covers some of the
  // image's: small ones, as in faces, would leave holes).
  if FScale = 1 then
    Emit(KindTriangle, S, @V[0], 3, FloorDiv16(MinX + 7), FloorDiv16(MinY + 7), FloorDiv16(MaxX - 8),
      FloorDiv16(MaxY - 8))
  else
    Emit(KindTriangle, S, @V[0], 3, FloorDiv16(MinX), FloorDiv16(MinY), FloorDiv16(MaxX - 1), FloorDiv16(MaxY - 1));
end;

// The first and the last pixel centre a sprite from A to B (1/16 pixels)
// covers, as fractions of the way from A; its middle when it covers none.
procedure SpanCentres(A, B: Integer; out F0, F1: Single);
begin
  var P1 := FloorDiv16(Min(A, B) + 7);
  var P2 := FloorDiv16(Max(A, B) + 7) - 1;
  if P2 < P1 then
  begin
    F0 := 0.5;
    F1 := 0.5;
    Exit;
  end;
  F0 := (P1 * 16 + 8 - A) / (B - A);
  F1 := (P2 * 16 + 8 - A) / (B - A);
end;

// A sprite's coordinate box (TGEHLEVertex.Box): the coordinates at the pixel
// centres it covers, the extremes at its outermost ones (S, T and Q go along
// an axis each). Corners C: (V0.X, V0.Y), (V1.X, V0.Y), (V0.X, V1.Y), (V1.X, V1.Y).
procedure SpriteBox(const V0, V1: TGEVertex; var C: array of TGEHLEVertex);
var
  FX, FY: array[0..1] of Single;
  Box: TGEHLEBox;
begin
  SpanCentres(V0.X, V1.X, FX[0], FX[1]);
  SpanCentres(V0.Y, V1.Y, FY[0], FY[1]);
  for var I := 0 to 3 do
  begin
    var U := FX[I and 1];
    var W := FY[I shr 1];
    var Q := C[0].Q + (C[1].Q - C[0].Q) * U + (C[2].Q - C[0].Q) * W;
    if not (Q > 0) then
      Exit;
    var SV := (C[0].S + (C[1].S - C[0].S) * U + (C[2].S - C[0].S) * W) / Q;
    var TV := (C[0].T + (C[1].T - C[0].T) * U + (C[2].T - C[0].T) * W) / Q;
    if I = 0 then
    begin
      Box[0] := SV;
      Box[1] := TV;
      Box[2] := SV;
      Box[3] := TV;
    end
    else
    begin
      Box[0] := Min(Box[0], SV);
      Box[1] := Min(Box[1], TV);
      Box[2] := Max(Box[2], SV);
      Box[3] := Max(Box[3], TV);
    end;
  end;
  for var I := 0 to 3 do
    C[I].Box := Box;
end;

procedure TGEVulkanHLEBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  V: array[0..5] of TGEHLEVertex;
  C: array[0..3] of TGEHLEVertex;
begin
  if (V0.X = V1.X) or (V0.Y = V1.Y) then
    Exit;
  // S runs along x and T along y, except when the corners are flipped in one
  // axis only: then S runs along y and T along x. Q goes with S. Colours,
  // depth and fog are the second vertex's.
  var Turned := (V0.X > V1.X) <> (V0.Y > V1.Y);
  for var I := 0 to 3 do
  begin
    var AtX1 := (I and 1) <> 0;
    var AtY1 := (I and 2) <> 0;
    var PX := V0.X;
    if AtX1 then
      PX := V1.X;
    var PY := V0.Y;
    if AtY1 then
      PY := V1.Y;
    PutVertex(C[I], V1, V1, PX / 16, PY / 16, False);
    // The slope's level of detail takes the second vertex's w.
    if V1.W > 0 then
      C[I].W := V1.W;
    var SFrom1 := AtX1;
    var TFrom1 := AtY1;
    if Turned then
    begin
      SFrom1 := AtY1;
      TFrom1 := AtX1;
    end;
    if SFrom1 then
    begin
      C[I].S := V1.S;
      C[I].Q := V1.Q;
    end
    else
    begin
      C[I].S := V0.S;
      C[I].Q := V0.Q;
    end;
    if TFrom1 then
      C[I].T := V1.T
    else
      C[I].T := V0.T;
  end;
  // Above 1x the samples keep to the coordinates of the PSP's pixel centres:
  // past them, at the edges, a bilinear sample would take in texels the PSP
  // never reads (lines along the edges of 2D images).
  if FScale > 1 then
    SpriteBox(V0, V1, C);
  V[0] := C[0];
  V[1] := C[1];
  V[2] := C[2];
  V[3] := C[1];
  V[4] := C[3];
  V[5] := C[2];
  // Pixels whose centres lie in [x1, x2) x [y1, y2); above 1x those the
  // sprite touches at all (as triangles).
  if FScale = 1 then
    Emit(KindTriangle, S, @V[0], 6, FloorDiv16(Min(V0.X, V1.X) + 7), FloorDiv16(Min(V0.Y, V1.Y) + 7),
      FloorDiv16(Max(V0.X, V1.X) + 7) - 1, FloorDiv16(Max(V0.Y, V1.Y) + 7) - 1)
  else
    Emit(KindTriangle, S, @V[0], 6, FloorDiv16(Min(V0.X, V1.X)), FloorDiv16(Min(V0.Y, V1.Y)), FloorDiv16(Max(V0.X,
          V1.X) - 1), FloorDiv16(Max(V0.Y, V1.Y) - 1));
end;

// The GE's lines differ from the GPU's in which pixels they cover: they are
// drawn as a point per pixel, where and with what the GE gives each.
procedure TGEVulkanHLEBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
begin
  var X0 := V0.X;
  var Y0 := V0.Y;
  var DX := V1.X - X0;
  var DY := V1.Y - Y0;
  if (DX = 0) and (DY = 0) then
    Exit;
  // Pixels whose centre on the major axis lies between the end points; the
  // minor axis is the containing pixel of the line there.
  var XMajor := Abs(DX) >= Abs(DY);
  var A0, A1, D, Lo, Hi: Integer;
  if XMajor then
  begin
    A0 := Min(V0.X, V1.X);
    A1 := Max(V0.X, V1.X);
    D := DX;
    Lo := S.ScissorX1;
    Hi := S.ScissorX2;
  end
  else
  begin
    A0 := Min(V0.Y, V1.Y);
    A1 := Max(V0.Y, V1.Y);
    D := DY;
    Lo := S.ScissorY1;
    Hi := S.ScissorY2;
  end;
  var P1 := Max(FloorDiv16(A0 + 7), Lo);
  var P2 := Min(FloorDiv16(A1 + 7) - 1, Hi);
  if P2 < P1 then
    Exit;
  var N := P2 - P1 + 1;
  if Length(FLine) < N then
    SetLength(FLine, N);
  var Gouraud := S.Gouraud and not S.Flat;
  var BX1 := MaxInt;
  var BY1 := MaxInt;
  var BX2 := -MaxInt;
  var BY2 := -MaxInt;
  for var I := 0 to N - 1 do
  begin
    var P := P1 + I;
    var C := P * 16 + 8;
    var T: Single;
    var PX, PY: Integer;
    if XMajor then
    begin
      T := (C - X0) / D;
      PX := P;
      PY := FloorDiv16(Y0 + Round(DY * T));
    end
    else
    begin
      T := (C - Y0) / D;
      PY := P;
      PX := FloorDiv16(X0 + Round(DX * T));
    end;
    var Pt: PGEHLEVertex := @FLine[I];
    Pt.X := PX + 0.5;
    Pt.Y := PY + 0.5;
    if Gouraud then
      Pt.Color := PackColor(Round(V0.R + (V1.R - V0.R) * T), Round(V0.G + (V1.G - V0.G) * T),
        Round(V0.B + (V1.B - V0.B) * T), Round(V0.A + (V1.A - V0.A) * T))
    else
      Pt.Color := PackColor(V1.R, V1.G, V1.B, V1.A);
    Pt.Secondary := PackColor(V1.SR, V1.SG, V1.SB, 0);
    Pt.Z := Round(V0.Z + (V1.Z - V0.Z) * T);
    Pt.S := V0.S + (V1.S - V0.S) * T;
    Pt.T := V0.T + (V1.T - V0.T) * T;
    var Q: Single := V0.Q + (V1.Q - V0.Q) * T;
    if (Q <> 1) and (Q <> 0) then
    begin
      Pt.S := Pt.S / Q;
      Pt.T := Pt.T / Q;
    end;
    Pt.Q := 1;
    Pt.W := 1;
    Pt.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    Pt.Box := NoBox;
    BX1 := Min(BX1, PX);
    BY1 := Min(BY1, PY);
    BX2 := Max(BX2, PX);
    BY2 := Max(BY2, PY);
  end;
  Emit(KindPoint, S, @FLine[0], N, BX1, BY1, BX2, BY2);
end;

procedure TGEVulkanHLEBackend.DrawPoint(const S: TGERaster; const V: TGEVertex);
var
  D: array[0..0] of TGEHLEVertex;
begin
  // The pixel the point is in, at its centre.
  var PX := FloorDiv16(V.X);
  var PY := FloorDiv16(V.Y);
  PutVertex(D[0], V, V, PX + 0.5, PY + 0.5, False);
  if (V.Q <> 1) and (V.Q <> 0) then
  begin
    D[0].S := V.S / V.Q;
    D[0].T := V.T / V.Q;
  end;
  D[0].Q := 1;
  Emit(KindPoint, S, @D[0], 1, PX, PY, PX, PY);
end;

procedure TGEVulkanHLEBackend.Access(Address, Size: Cardinal; Write: Boolean);
begin
  if FMemory.HeldVRAMPages = 0 then
    Exit;
  var A := Address and $1FFFFFFF;
  if (A >= PSPVRAMBase) and (A < PSPVRAMBase + 4 * PSPVRAMSize) and (((A and PSPVRAMSize) <> 0) or
    MemoryHeld(A and VRAMMask, Size)) then
    FlushAll;
end;

// Opaque ARGB in the target format's precision, by the kernel.
function TGEVulkanHLEBackend.RecordFrameRegion(T: TVulkanHLETarget; X, Y, W, H: Integer): Boolean;
begin
  DownSample(TGEHLETarget(T), X, Y, W, H, 0, 3, 1);
  Result := True;
end;

procedure TGEVulkanHLEBackend.RecordFrame(T: TVulkanHLETarget; W, H: Integer);
begin
  DownSample(TGEHLETarget(T), 0, 0, W, H, 0, 3, 1);
end;

// The display's framebuffer as the target image holds it, at the scale. The
// image must be what the PSP would show: newer than guest memory (held), or
// equal to it. Guest memory is left alone (nothing is read back).
function TGEVulkanHLEBackend.Present(Address, Format, Stride: Cardinal; var Frame: TEmulatorFrame): Boolean;
begin
  Result := False;
  var A := Address and $1FFFFFFF;
  // The linear views of VRAM.
  if (A < PSPVRAMBase) or (A >= PSPVRAMBase + 4 * PSPVRAMSize) or ((A and PSPVRAMSize) <> 0) then
    Exit;
  var T: TVulkanHLETarget := nil;
  for var U in FTargets do
    if (U.Addr = A and VRAMMask) and (U.Format = Format and 3) and (U.Stride = Stride) and
      (U.Width >= PSPFrameWidth) and (U.Height >= PSPFrameHeight) then
    begin
      T := U;
      Break;
    end;
  if T = nil then
    Exit;
  if not T.Dirty and (not T.Loaded or MemoryHeld(T.Addr, T.Bytes) or not ShadowMatches(T)) then
    Exit;
  // Guest memory changed outside the rows drawn: the display reads it (and
  // the drawn rows back) instead.
  if T.Dirty and T.Stale then
    Exit;
  ReadFrame(T, PSPFrameWidth * FScale, PSPFrameHeight * FScale, Frame);
  Result := True;
end;

end.

