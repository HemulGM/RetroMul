unit PS2.GS.VulkanHLE;

// The GS drawn with Vulkan graphics pipelines (Video/Renderer=vulkan-hle):
// fast, in the host GPU's arithmetic, not pixel for pixel as the software
// renderer. TPS2GSHLE is the raster's accelerator (TPS2GSRaster.HLE): it
// takes every sprite and triangle; the software renderer draws points, lines
// and what it declines, after the targets went back to GS memory.
//
// - Targets. A GS buffer (FBP, FBW, FPSM) is a target: an RGBA8 image (24-bit
//   formats keep alpha 0x80 there, 16-bit ones bit 15 as alpha 0 or 255). Its
//   rows map to GS memory linearly a page row at a time (FBW pages of 32 rows
//   for 32-bit formats, of 64 for 16-bit ones), so that the base renderer's
//   byte ranges of whole page rows are exactly the buffer's pages: targets
//   are whole page rows tall, and rows drawn are held a page row at a time.
//   The depth buffer (ZBP, ZPSM, the frame's width) is the target's depth
//   image, its value over the format's range.
// - Textures are decoded on the CPU (CLUT, TEXA) to RGBA8 with their mipmap
//   levels and compared with the GS blocks they came from; a target drawn in
//   the texture's own format and width is sampled from its image (a copy of
//   it when the draw renders into it).
// - Holds and watches are sets of GS pages. The raster reports its own
//   accesses to GS memory (transfers, CLUT loads, local copies, the display)
//   through the accelerator's page calls: the targets newer there are stored
//   first, writes to watched pages make textures and targets checked again.
//
// Not drawn as the GS does (yet): the destination alpha test (DATE) is not
// applied; FBMSK masks whole channels only; destination alpha weighs as
// Ad / 255 on 32-bit frames (the GS: Ad / 128); weights above one clamp; no
// COLCLAMP wrapping, dithering, or resolution scaling.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Diagnostics, Core.Emulation.Types, RM.Vulkan.Bindings,
  RM.Vulkan.Loader, RM.Vulkan.Compute, RM.Vulkan.HLE, PS2.Types, PS2.GS.Memory, PS2.GS.Raster;

type
  // A target with its depth buffer, which the depth image holds.
  TPS2HLETarget = class(TVulkanHLETarget)
  public
    // The depth buffer's byte address and format.
    ZAddr, ZPSM: Cardinal;
    ZLoaded: Boolean;
    // The run the depth image was last found equal to GS memory in, and the
    // run its pages were watched in (only tested).
    ZVerified, ZWatched: Int64;
    // GS memory's bytes of the depth buffer when last made equal to it.
    ZShadow: TBytes;
    // Depth newer than GS memory, as the colour's Dirty.
    ZDirty: Boolean;
    ZX1, ZY1, ZX2, ZY2: Integer;
    ZHeldY1, ZHeldY2: Integer;
    ZStale: Boolean;
    // The colour image copied, for draws sampling the target they draw.
    Copy: TVulkanHLETexture;
    // Shader blending: the colour as a storage image (set 1), and a
    // framebuffer of the depth alone.
    BlendSet: VkDescriptorSet;
    BlendFramebuffer: VkFramebuffer;
    constructor Create;
    function ZRowBytes: Cardinal;
    // The depth buffer's bytes: the target's rows, whole page rows.
    function ZBytes: Cardinal;
  end;

  // A vertex as the pipelines take it: position in target pixels with depth
  // over its range, colour, texture coordinates in 1/16 texels (or S, T times
  // the texture's size in 1/16 texels with Q), the Q of the LOD and fog.
  TPS2HLEVertex = packed record
    X, Y, Z: Single;
    Color: Cardinal;
    S, T, Q: Single;
    LodQ, Fog: Single;
  end;
  PPS2HLEVertex = ^TPS2HLEVertex;

  // As shaders/PS2.GS.HLEPush.glsl declares it.
  TPS2HLEPush = packed record
    NdcX, NdcY: Single;
    Flags, Tex, ClampU, ClampV, TexA, FogColor, AlphaTest, Blend: Cardinal;
    LodK: Single;
    TexOffset: Cardinal;
    Pixel, FbMsk: Cardinal;
  end;

  // Why everything went back to GS memory (diagnostics): another target's
  // pixels where a draw goes, a texture's, a depth buffer's, a stale
  // target's, the raster's Sync.
  TPS2HLEFlush = (frOthers, frTexture, frDepth, frStale, frSync);

  // A draw's pass: the alpha test's passing pixels, or its failing ones.
  TPS2HLEPass = record
    Pipeline: VkPipeline;
    Layout: VkPipelineLayout;
    Push: TPS2HLEPush;
  end;

  TPS2GSVulkanHLE = class(TVulkanHLERenderer)
  private
    FMemory: TPS2GSMemory;
    FClut: PWord;
    FVertexModule, FFragmentModule: VkShaderModule;
    // Shader blending (VK_EXT_fragment_shader_interlock): the GS's pixel
    // operations exactly, for the draws the fixed function cannot do (and
    // that write depth only when they discard nothing).
    FShaderBlend: Boolean;
    FBlendModule: VkShaderModule;
    FBlendSetLayout: VkDescriptorSetLayout;
    FBlendLayout: VkPipelineLayout;
    FBlendPool: VkDescriptorPool;
    FBlendPass: VkRenderPass;
    // The state set up blends in the shader.
    FBlended: Boolean;
    FBoundTargetSet: VkDescriptorSet;
    FBlendSetups: Int64;
    FHeld, FWatched: TPS2GSPages;
    FRevision: Int64;
    // The state the draw being built was set up for, with its CLUT.
    FLast: TPS2GSDraw;
    FLastClut: TPS2GSClut;
    FStateValid: Boolean;
    // What it binds: one or two passes, the texture, the scissor.
    FPasses: array[0..1] of TPS2HLEPass;
    FPassCount: Integer;
    FTexSet: VkDescriptorSet;
    FScissor: VkRect2D;
    FBoundPass: Integer;
    FBoundScissor: VkRect2D;
    FScissorValid: Boolean;
    FDepthWrites, FDepthUsed: Boolean;
    // The draw samples its own target (its copy, CopyOf): where the copy
    // starts in the image, and the box drawn since the copy was made.
    FFeedback: Boolean;
    FCopyOffX, FCopyOffY: Integer;
    FCopyX1, FCopyY1, FCopyX2, FCopyY2: Integer;
    // Rows of the colour's and the depth's pages.
    FPageRows, FZPageRows: Integer;
    // The lowest row the primitive being set up needs in its target.
    FNeedY: Integer;
    // Depth over the depth buffer's range (its largest value plus one).
    FZScale: Double;
    FDepthClamp: Boolean;
    // The texture being looked up: its GS blocks as runs of bytes (and the
    // CLUT's entries it takes, last), the pages of those blocks.
    FBlockBits: array[0..255] of UInt64;
    FTexBytes: TArray<TVulkanHLEBytes>;
    FTexByteCount: Integer;
    FTexPages: TPS2GSPages;
    FTexGathered: Boolean;
    FClutCopy: array[0..511] of Word;
    FClutCount: Integer;
    FFlushes: array[TPS2HLEFlush] of Int64;
    // The primitive the state is set up for (its texels may be all a texture
    // decodes), and the part decoded of the state's texture (FPartW 0: all).
    FSetupV: PPS2HLEVertex;
    FSetupCount: Integer;
    FPartU0, FPartV0, FPartW, FPartH: Integer;
    FGrow, FWhole: Boolean;
    FGrowU0, FGrowV0, FGrowU1, FGrowV1: Integer;
    FPartials: Int64;
    FVertices: array[0..5] of TPS2HLEVertex;
    FDepthLoads, FTargetTextures, FCopies, FPartialStores, FSetups: Int64;
    function TargetFor(const D: TPS2GSDraw): TPS2HLETarget;
    procedure FlushOthers(T: TPS2HLETarget; const Pages: TPS2GSPages);
    function TargetTexture(const D: TPS2GSDraw; out OffX, OffY: Integer): TPS2HLETarget;
    function CopyOf(T: TPS2HLETarget): TVulkanHLETexture;
    procedure RefreshCopy(V: PPS2HLEVertex; Count: Integer);
    function HeldFor(TPSM: Cardinal): TPS2GSPages;
    procedure CopyClut(const D: TPS2GSDraw);
    procedure GatherTexture(Request: Pointer);
    procedure Flush(Reason: TPS2HLEFlush);
    function EnsureTexture(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer): TVulkanHLETexture;
    function TexelBox(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer; out U0, V0, U1, V1: Integer): Boolean;
    procedure EnsureDepth(T: TPS2HLETarget; const D: TPS2GSDraw);
    procedure LoadDepth(T: TPS2HLETarget);
    procedure WatchDepth(T: TPS2HLETarget);
    procedure HoldDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
    procedure HoldNewDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
    procedure HoldTarget(T: TPS2HLETarget);
    function BandRows(T: TVulkanHLETarget): Integer;
    function DepthBits(Z: Cardinal): Cardinal; inline;
    procedure Store(T: TPS2HLETarget; Color, Depth: Boolean);
    procedure StoreOverlapping(const Pages: TPS2GSPages);
    procedure WatchFault(const Writes: TPS2GSPages);
    function SameState(const D: TPS2GSDraw): Boolean;
    procedure SetupState(const D: TPS2GSDraw);
    procedure ApplyBindings;
    procedure BindPass(Index: Integer);
    procedure Emit(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer; X1, Y1, X2, Y2: Integer);
    procedure CreateBlend;
    procedure CreateBlendTarget(T: TPS2HLETarget);
    function DepthOf(const D: TPS2GSDraw; Z: Cardinal): Single; inline;
  protected
    procedure Unbound; override;
    procedure FlushDraw; override;
    procedure FreeDevice; override;
    function PipelineFor(Key: UInt64): VkPipeline; override;
    function NewTarget: TVulkanHLETarget; override;
    procedure InitTarget(T: TVulkanHLETarget); override;
    procedure DestroyTarget(T: TVulkanHLETarget); override;
    procedure LoadTarget(T: TVulkanHLETarget); override;
    procedure StoreTarget(T: TVulkanHLETarget); override;
    function TargetNewer(T: TVulkanHLETarget): Boolean; override;
    procedure NewRun; override;
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
  public
    // Memory: the GS memory drawn; Clut: the raster's CLUT (512 entries).
    constructor Create(Memory: TPS2GSMemory; Clut: PWord; Compute: TVulkanCompute);
    destructor Destroy; override;
    // A sprite or triangle (TPS2GSAccelerator's), pixels X0..X1 - 1, Y0..Y1 - 1
    // inside the scissor: False when it is the software renderer's.
    function Sprite(const D: TPS2GSDraw; const V0, V1: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;
    function Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;
    function PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive; const V0, V1: TPS2GSVertex): Boolean;
    // The raster is about to read Reads and write Writes of GS memory.
    procedure Access(const Reads, Writes: TPS2GSPages);
    // Everything drawn back to GS memory (Sync, counted).
    procedure SyncAll;
    // Something is held or watched (accesses must be reported).
    function Pending: Boolean;
    function Describe: string;
    // Changes whenever what is held or watched may have.
    property Revision: Int64 read FRevision;
  end;

  // What the raster draws through (TPS2GSRaster.HLE): the renderer, on a
  // Vulkan device of its own with a graphics queue.
  TPS2GSHLE = class(TPS2GSAccelerator)
  private
    FRenderer: TPS2GSVulkanHLE;
    FCalls: Integer;
    procedure Update; inline;
  public
    constructor Create(Memory: TPS2GSMemory; Clut: PWord);
    destructor Destroy; override;
    procedure Sync; override;
    procedure ReadPages(First, Last: Integer); override;
    procedure WritePages(First, Last: Integer); override;
    procedure AccessPages(const Reads, Writes: TPS2GSPages); override;
    function Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer; Lod: Single): Boolean; override;
    function Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer): Boolean; override;
    function BeginTriangle(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): Boolean; override;
    function PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive; const V0, V1: TPS2GSVertex): Boolean; override;
    procedure Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single); override;
    procedure EndTriangle; override;
    property Renderer: TPS2GSVulkanHLE read FRenderer;
  end;

implementation

const
  PageShift = 13;
  MemMask = PS2GSMemorySize - 1;
  // Blend factors past the bindings' list.
  VK_BLEND_FACTOR_SRC1_ALPHA = 17;
  // Texture bytes compared with their source at most.
  FLAG_TEXTURED = 1;
  FLAG_FOG = 2;
  FLAG_TARGET = 4;
  FLAG_FBA = 8;
  FLAG_ALPHA1 = 16;
  FLAG_BLEND = 32;

{$I shaders\PS2.GS.HLEVert.inc}
{$I shaders\PS2.GS.HLEFrag.inc}
{$I shaders\PS2.GS.HLEBlendFrag.inc}

type
  // A texture as EnsureTexture looks it up (CachedTexture's request).
  TPS2HLETexRequest = record
    D: PPS2GSDraw;
    Levels: Integer;
    // The texels decoded (level 0's, all of them but for a part): U0..U0 + W
    // - 1, V0..V0 + H - 1.
    U0, V0, W, H: Integer;
  end;
  PPS2HLETexRequest = ^TPS2HLETexRequest;

function Is16(PSM: Cardinal): Boolean; inline;
begin
  Result := (PSM = PSMCT16) or (PSM = PSMCT16S) or (PSM = PSMZ16) or (PSM = PSMZ16S);
end;

function Is24(PSM: Cardinal): Boolean; inline;
begin
  Result := (PSM = PSMCT24) or (PSM = PSMZ24);
end;

function IsPalettized(PSM: Cardinal): Boolean; inline;
begin
  Result := (PSM = PSMT8) or (PSM = PSMT8H) or (PSM = PSMT4) or (PSM = PSMT4HL) or (PSM = PSMT4HH);
end;

function PixelBytesOf(PSM: Cardinal): Cardinal; inline;
begin
  if Is16(PSM) then
    Result := 2
  else
    Result := 4;
end;

// Rows of a page of a frame or depth format.
function PageRowsOf(PSM: Cardinal): Integer; inline;
begin
  if Is16(PSM) then
    Result := 64
  else
    Result := 32;
end;

function RoundRows(Rows, PageRows: Integer): Integer; inline;
begin
  Result := (Rows + PageRows - 1) div PageRows * PageRows;
end;

// The pages of GS memory's bytes Addr..Addr + Size - 1 (wrapping).
procedure AddRange(var Pages: TPS2GSPages; Addr, Size: Cardinal);
begin
  if Size = 0 then
    Exit;
  var First := Integer(Addr shr PageShift);
  var Last := Integer((UInt64(Addr) + Size - 1) shr PageShift);
  if Last - First >= 511 then
  begin
    FillChar(Pages, SizeOf(Pages), $FF);
    Exit;
  end;
  for var P := First to Last do
    Pages[(P and 511) shr 5] := Pages[(P and 511) shr 5] or (Cardinal(1) shl (P and 31));
end;

function Meets(const A, B: TPS2GSPages): Boolean;
begin
  for var I := 0 to High(A) do
    if (A[I] and B[I]) <> 0 then
      Exit(True);
  Result := False;
end;

function AnyPage(const A: TPS2GSPages): Boolean;
begin
  for var I := 0 to High(A) do
    if A[I] <> 0 then
      Exit(True);
  Result := False;
end;

{$IFOPT Q+}{$DEFINE HLE_OVERFLOW}{$Q-}{$ENDIF}
// Hashing wraps around.
function FNV(H: UInt64; V: UInt64): UInt64;
begin
  Result := (H xor V) * UInt64($100000001B3);
end;
{$IFDEF HLE_OVERFLOW}{$Q+}{$UNDEF HLE_OVERFLOW}{$ENDIF}

function ExpandTexA(V: Cardinal; TA0, TA1: Integer; AEM: Boolean): Cardinal; inline;
begin
  Result := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
  var A: Integer;
  if (V and $8000) <> 0 then
    A := TA1
  else if AEM and ((V and $7FFF) = 0) then
    A := 0
  else
    A := TA0;
  Result := Result or (Cardinal(A) shl 24);
end;

// The largest depth plus one: depth images hold values over it.
function DepthRange(ZPSM: Cardinal): Double; inline;
begin
  case ZPSM of
    PSMZ24: Result := 16777216.0;
    PSMZ16, PSMZ16S: Result := 65536.0;
  else
    Result := 4294967296.0;
  end;
end;

{ TPS2HLETarget }

constructor TPS2HLETarget.Create;
begin
  inherited;
  ZVerified := -1;
  ZWatched := -1;
end;

function TPS2HLETarget.ZRowBytes: Cardinal;
begin
  Result := Stride * PixelBytesOf(ZPSM);
end;

function TPS2HLETarget.ZBytes: Cardinal;
begin
  Result := Cardinal(RoundRows(Height, PageRowsOf(ZPSM))) * ZRowBytes;
end;

{ TPS2GSHLE }

constructor TPS2GSHLE.Create(Memory: TPS2GSMemory; Clut: PWord);
var
  Compute: TVulkanCompute;
  Error: string;
begin
  inherited Create;
  if not TryCreateVulkanCompute(Compute, Error, '', GetEnvironmentVariable('PS2_HLEVALIDATE') = '1', True) then
    raise EVulkanError.Create(Error);
  if not Compute.Features.DualSrcBlend then
  begin
    Compute.Free;
    raise EVulkanError.Create('The Vulkan device has no dual-source blending.');
  end;
  // (Its destructor frees the device should it fail.)
  FRenderer := TPS2GSVulkanHLE.Create(Memory, Clut, Compute);
  PageReads := True;
  Update;
end;

destructor TPS2GSHLE.Destroy;
begin
  FRenderer.Free;
  inherited;
end;

procedure TPS2GSHLE.Update;
begin
  FPending := FRenderer.Pending;
  FRevision := FRenderer.Revision;
end;

procedure TPS2GSHLE.Sync;
begin
  FRenderer.SyncAll;
  Update;
end;

procedure TPS2GSHLE.ReadPages(First, Last: Integer);
var
  Pages, None: TPS2GSPages;
begin
  FillChar(Pages, SizeOf(Pages), 0);
  FillChar(None, SizeOf(None), 0);
  AddRange(Pages, Cardinal(First and 511) shl PageShift, Cardinal(Min(Last - First + 1, 512)) shl PageShift);
  FRenderer.Access(Pages, None);
  Update;
end;

procedure TPS2GSHLE.WritePages(First, Last: Integer);
var
  Pages, None: TPS2GSPages;
begin
  FillChar(Pages, SizeOf(Pages), 0);
  FillChar(None, SizeOf(None), 0);
  AddRange(Pages, Cardinal(First and 511) shl PageShift, Cardinal(Min(Last - First + 1, 512)) shl PageShift);
  FRenderer.Access(None, Pages);
  Update;
end;

procedure TPS2GSHLE.AccessPages(const Reads, Writes: TPS2GSPages);
begin
  FRenderer.Access(Reads, Writes);
  Update;
end;

function TPS2GSHLE.Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex; X0, Y0, X1, Y1: Integer;
  Lod: Single): Boolean;
begin
  Result := FRenderer.Sprite(D, V0, V, X0, Y0, X1, Y1);
  // A long list starts on the GPU while the rest is recorded.
  Inc(FCalls);
  if (FCalls and 63) = 0 then
    FRenderer.Release;
  Update;
end;

function TPS2GSHLE.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := FRenderer.Triangle(D, V0, V1, V2, X0, Y0, X1, Y1);
  Inc(FCalls);
  if (FCalls and 63) = 0 then
    FRenderer.Release;
  Update;
end;

function TPS2GSHLE.BeginTriangle(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := False;
end;

function TPS2GSHLE.PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive; const V0, V1: TPS2GSVertex): Boolean;
begin
  Result := FRenderer.PointOrLine(D, Kind, V0, V1);
  Update;
end;

procedure TPS2GSHLE.Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single);
begin
end;

procedure TPS2GSHLE.EndTriangle;
begin
end;

{ TPS2GSVulkanHLE }

constructor TPS2GSVulkanHLE.Create(Memory: TPS2GSMemory; Clut: PWord; Compute: TVulkanCompute);
var
  Props: VkFormatProperties;
begin
  FMemory := Memory;
  FClut := Clut;
  FRevision := 1;
  inherited Create(Compute, 1, SizeOf(TPS2HLEVertex), SizeOf(TPS2HLEPush), 1024, 1024);
  FDepthClamp := Compute.Features.DepthClamp;
  FVertexModule := Compute.CreateShaderModule(PS2HLEVertSPIRV);
  FFragmentModule := Compute.CreateShaderModule(PS2HLEFragSPIRV);
  // Shader blending writes the colour as a storage image (RGBA8 storage is
  // required of every device) where the device orders fragments for it.
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_R8G8B8A8_UNORM, @Props);
  FShaderBlend := Compute.Features.PixelInterlock and ((Props.optimalTilingFeatures and
    VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) <> 0) and (GetEnvironmentVariable('PS2_HLESHADERBLEND') <> '0');
  if FShaderBlend then
  begin
    FColorUsage := FColorUsage or VK_IMAGE_USAGE_STORAGE_BIT;
    CreateBlend;
  end;
end;

destructor TPS2GSVulkanHLE.Destroy;
begin
  // What is drawn goes back to GS memory (TVulkanHLERenderer.Destroy).
  inherited;
end;

procedure TPS2GSVulkanHLE.FreeDevice;
begin
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

procedure TPS2GSVulkanHLE.Unbound;
begin
  FBoundPass := -1;
  FBoundTargetSet := 0;
  FScissorValid := False;
end;

function TPS2GSVulkanHLE.NewTarget: TVulkanHLETarget;
begin
  Result := TPS2HLETarget.Create;
end;

procedure TPS2GSVulkanHLE.InitTarget(T: TVulkanHLETarget);
begin
  if FShaderBlend then
    CreateBlendTarget(TPS2HLETarget(T));
end;

// Set 1 of the shader-blending pipelines (the colour as a storage image, in
// FBlendPool) and their framebuffer (the depth alone, FBlendPass).
procedure TPS2GSVulkanHLE.CreateBlend;
var
  Binding: VkDescriptorSetLayoutBinding;
  SetInfo: VkDescriptorSetLayoutCreateInfo;
  Layouts: array[0..1] of VkDescriptorSetLayout;
  Push: VkPushConstantRange;
  Info: VkPipelineLayoutCreateInfo;
  Size: VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
  Attachment: VkAttachmentDescription;
  DepthRef: VkAttachmentReference;
  Subpass: VkSubpassDescription;
  Deps: array[0..1] of VkSubpassDependency;
  PassInfo: VkRenderPassCreateInfo;
begin
  FBlendModule := FCompute.CreateShaderModule(PS2HLEBlendFragSPIRV);
  Binding := Default(VkDescriptorSetLayoutBinding);
  Binding.binding := 0;
  Binding.descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Binding.descriptorCount := 1;
  Binding.stageFlags := VK_SHADER_STAGE_FRAGMENT_BIT;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := 1;
  SetInfo.pBindings := @Binding;
  CheckVulkan(FAPI.vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @FBlendSetLayout),
    'vkCreateDescriptorSetLayout');
  Layouts[0] := FSetLayout;
  Layouts[1] := FBlendSetLayout;
  Push.stageFlags := VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT;
  Push.offset := 0;
  Push.size := SizeOf(TPS2HLEPush);
  Info := Default(VkPipelineLayoutCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  Info.setLayoutCount := 2;
  Info.pSetLayouts := @Layouts[0];
  Info.pushConstantRangeCount := 1;
  Info.pPushConstantRanges := @Push;
  CheckVulkan(FAPI.vkCreatePipelineLayout(FDevice, @Info, nil, @FBlendLayout), 'vkCreatePipelineLayout');
  Size.&type := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Size.descriptorCount := HLEMaxTargets + 8;
  PoolInfo := Default(VkDescriptorPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.flags := VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
  PoolInfo.maxSets := HLEMaxTargets + 8;
  PoolInfo.poolSizeCount := 1;
  PoolInfo.pPoolSizes := @Size;
  CheckVulkan(FAPI.vkCreateDescriptorPool(FDevice, @PoolInfo, nil, @FBlendPool), 'vkCreateDescriptorPool');
  Attachment := Default(VkAttachmentDescription);
  Attachment.format := FDepthFormat;
  Attachment.samples := VK_SAMPLE_COUNT_1_BIT;
  Attachment.loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Attachment.storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  Attachment.stencilLoadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Attachment.stencilStoreOp := VK_ATTACHMENT_STORE_OP_STORE;
  Attachment.initialLayout := VK_IMAGE_LAYOUT_GENERAL;
  Attachment.finalLayout := VK_IMAGE_LAYOUT_GENERAL;
  DepthRef.attachment := 0;
  DepthRef.layout := VK_IMAGE_LAYOUT_GENERAL;
  Subpass := Default(VkSubpassDescription);
  Subpass.pipelineBindPoint := VK_PIPELINE_BIND_POINT_GRAPHICS;
  Subpass.pDepthStencilAttachment := @DepthRef;
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
  PassInfo.attachmentCount := 1;
  PassInfo.pAttachments := @Attachment;
  PassInfo.subpassCount := 1;
  PassInfo.pSubpasses := @Subpass;
  PassInfo.dependencyCount := 2;
  PassInfo.pDependencies := @Deps[0];
  CheckVulkan(FAPI.vkCreateRenderPass(FDevice, @PassInfo, nil, @FBlendPass), 'vkCreateRenderPass');
end;

procedure TPS2GSVulkanHLE.CreateBlendTarget(T: TPS2HLETarget);
var
  Alloc: VkDescriptorSetAllocateInfo;
  Image: VkDescriptorImageInfo;
  Write: VkWriteDescriptorSet;
  Info: VkFramebufferCreateInfo;
begin
  Alloc := Default(VkDescriptorSetAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  Alloc.descriptorPool := FBlendPool;
  Alloc.descriptorSetCount := 1;
  Alloc.pSetLayouts := @FBlendSetLayout;
  CheckVulkan(FAPI.vkAllocateDescriptorSets(FDevice, @Alloc, @T.BlendSet), 'vkAllocateDescriptorSets');
  Image.sampler := 0;
  Image.imageView := T.Color.View;
  Image.imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Write := Default(VkWriteDescriptorSet);
  Write.sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  Write.dstSet := T.BlendSet;
  Write.dstBinding := 0;
  Write.descriptorCount := 1;
  Write.descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Write.pImageInfo := @Image;
  FAPI.vkUpdateDescriptorSets(FDevice, 1, @Write, 0, nil);
  Info := Default(VkFramebufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  Info.renderPass := FBlendPass;
  Info.attachmentCount := 1;
  Info.pAttachments := @T.Depth.View;
  Info.width := T.Width * FScale;
  Info.height := T.Height * FScale;
  Info.layers := 1;
  CheckVulkan(FAPI.vkCreateFramebuffer(FDevice, @Info, nil, @T.BlendFramebuffer), 'vkCreateFramebuffer');
end;

procedure TPS2GSVulkanHLE.DestroyTarget(T: TVulkanHLETarget);
begin
  var G := TPS2HLETarget(T);
  if G.BlendSet <> 0 then
    FAPI.vkFreeDescriptorSets(FDevice, FBlendPool, 1, @G.BlendSet);
  if G.BlendFramebuffer <> 0 then
    FAPI.vkDestroyFramebuffer(FDevice, G.BlendFramebuffer, nil);
  if G.Copy <> nil then
  begin
    FreeSets(G.Copy);
    DestroyImage(G.Copy.Image);
    G.Copy.Free;
  end;
  inherited;
end;

function TPS2GSVulkanHLE.TargetNewer(T: TVulkanHLETarget): Boolean;
begin
  Result := T.Dirty or TPS2HLETarget(T).ZDirty;
end;

// Everything set up is set up again (textures and depth buffers are compared
// with GS memory again).
procedure TPS2GSVulkanHLE.NewRun;
begin
  inherited;
  FStateValid := False;
end;

// Key bits: 0 blend, 1-5 source factor, 6-10 destination factor, 11-12 blend
// operation, 13-16 colour write mask, 17 depth test, 18 depth write, 19-21
// depth compare, 22 shader blending (no colour attachment: bits 0-16 unused).
function TPS2GSVulkanHLE.PipelineFor(Key: UInt64): VkPipeline;
var
  Stages: array[0..1] of VkPipelineShaderStageCreateInfo;
  Binding: VkVertexInputBindingDescription;
  Attributes: array[0..3] of VkVertexInputAttributeDescription;
  VertexInput: VkPipelineVertexInputStateCreateInfo;
  Assembly: VkPipelineInputAssemblyStateCreateInfo;
  Viewport: VkPipelineViewportStateCreateInfo;
  Raster: VkPipelineRasterizationStateCreateInfo;
  Multisample: VkPipelineMultisampleStateCreateInfo;
  DepthStencil: VkPipelineDepthStencilStateCreateInfo;
  Blend: VkPipelineColorBlendAttachmentState;
  BlendState: VkPipelineColorBlendStateCreateInfo;
  Dynamic: VkPipelineDynamicStateCreateInfo;
  DynamicStates: array[0..1] of VkDynamicState;
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
  Stages[1].stage := VK_SHADER_STAGE_FRAGMENT_BIT;
  Stages[1].module := FFragmentModule;
  var Blended := ((Key shr 22) and 1) <> 0;
  if Blended then
    Stages[1].module := FBlendModule;
  Binding.binding := 0;
  Binding.stride := SizeOf(TPS2HLEVertex);
  Binding.inputRate := VK_VERTEX_INPUT_RATE_VERTEX;
  Attributes[0].location := 0;
  Attributes[0].binding := 0;
  Attributes[0].format := VK_FORMAT_R32G32B32_SFLOAT;
  Attributes[0].offset := 0;
  Attributes[1].location := 1;
  Attributes[1].binding := 0;
  Attributes[1].format := VK_FORMAT_R8G8B8A8_UNORM;
  Attributes[1].offset := 12;
  Attributes[2].location := 2;
  Attributes[2].binding := 0;
  Attributes[2].format := VK_FORMAT_R32G32B32_SFLOAT;
  Attributes[2].offset := 16;
  Attributes[3].location := 3;
  Attributes[3].binding := 0;
  Attributes[3].format := VK_FORMAT_R32G32_SFLOAT;
  Attributes[3].offset := 28;
  VertexInput := Default(VkPipelineVertexInputStateCreateInfo);
  VertexInput.sType := VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
  VertexInput.vertexBindingDescriptionCount := 1;
  VertexInput.pVertexBindingDescriptions := @Binding;
  VertexInput.vertexAttributeDescriptionCount := 4;
  VertexInput.pVertexAttributeDescriptions := @Attributes[0];
  Assembly := Default(VkPipelineInputAssemblyStateCreateInfo);
  Assembly.sType := VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
  Assembly.topology := VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
  Viewport := Default(VkPipelineViewportStateCreateInfo);
  Viewport.sType := VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
  Viewport.viewportCount := 1;
  Viewport.scissorCount := 1;
  Raster := Default(VkPipelineRasterizationStateCreateInfo);
  Raster.sType := VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
  // Depth past the buffer's range clamps to it, as the GS clamps to ZMax.
  Raster.depthClampEnable := Ord(FDepthClamp);
  Raster.polygonMode := VK_POLYGON_MODE_FILL;
  Raster.cullMode := VK_CULL_MODE_NONE;
  Raster.frontFace := VK_FRONT_FACE_COUNTER_CLOCKWISE;
  Raster.lineWidth := 1;
  Multisample := Default(VkPipelineMultisampleStateCreateInfo);
  Multisample.sType := VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
  Multisample.rasterizationSamples := VK_SAMPLE_COUNT_1_BIT;
  DepthStencil := Default(VkPipelineDepthStencilStateCreateInfo);
  DepthStencil.sType := VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
  DepthStencil.depthTestEnable := (Key shr 17) and 1;
  DepthStencil.depthWriteEnable := (Key shr 18) and 1;
  DepthStencil.depthCompareOp := (Key shr 19) and 7;
  DepthStencil.maxDepthBounds := 1;
  Blend := Default(VkPipelineColorBlendAttachmentState);
  Blend.blendEnable := Key and 1;
  Blend.srcColorBlendFactor := (Key shr 1) and 31;
  Blend.dstColorBlendFactor := (Key shr 6) and 31;
  Blend.colorBlendOp := (Key shr 11) and 3;
  // The GS writes the source alpha as it is.
  Blend.srcAlphaBlendFactor := VK_BLEND_FACTOR_ONE;
  Blend.dstAlphaBlendFactor := VK_BLEND_FACTOR_ZERO;
  Blend.alphaBlendOp := VK_BLEND_OP_ADD;
  Blend.colorWriteMask := (Key shr 13) and 15;
  BlendState := Default(VkPipelineColorBlendStateCreateInfo);
  BlendState.sType := VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
  BlendState.attachmentCount := 1;
  BlendState.pAttachments := @Blend;
  DynamicStates[0] := VK_DYNAMIC_STATE_VIEWPORT;
  DynamicStates[1] := VK_DYNAMIC_STATE_SCISSOR;
  Dynamic := Default(VkPipelineDynamicStateCreateInfo);
  Dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  Dynamic.dynamicStateCount := 2;
  Dynamic.pDynamicStates := @DynamicStates[0];
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
  Info.pDynamicState := @Dynamic;
  Info.layout := FLayout;
  Info.renderPass := FRenderPass;
  if Blended then
  begin
    BlendState.attachmentCount := 0;
    BlendState.pAttachments := nil;
    Info.layout := FBlendLayout;
    Info.renderPass := FBlendPass;
  end;
  Info.basePipelineIndex := -1;
  CheckVulkan(FAPI.vkCreateGraphicsPipelines(FDevice, 0, 1, @Info, nil, @Result), 'vkCreateGraphicsPipelines');
end;

{ GS memory: byte addresses, wrapping round its 4 MiB }

function TPS2GSVulkanHLE.MemoryEquals(Addr: Cardinal; Data: PByte; Size: Cardinal): Boolean;
begin
  var A := Addr and MemMask;
  var First := Min(Size, PS2GSMemorySize - A);
  Result := CompareMem(FMemory.Data + A, Data, First) and ((First = Size) or
    CompareMem(FMemory.Data, Data + First, Size - First));
end;

procedure TPS2GSVulkanHLE.ReadMemory(Addr: Cardinal; Data: PByte; Size: Cardinal);
begin
  var A := Addr and MemMask;
  var First := Min(Size, PS2GSMemorySize - A);
  Move((FMemory.Data + A)^, Data^, First);
  if First < Size then
    Move(FMemory.Data^, (Data + First)^, Size - First);
end;

procedure TPS2GSVulkanHLE.HoldMemory(Addr, Size: Cardinal);
begin
  AddRange(FHeld, Addr and MemMask, Min(Size, PS2GSMemorySize));
  Inc(FRevision);
end;

function TPS2GSVulkanHLE.MemoryHeld(Addr, Size: Cardinal): Boolean;
var
  Pages: TPS2GSPages;
begin
  FillChar(Pages, SizeOf(Pages), 0);
  AddRange(Pages, Addr and MemMask, Min(Size, PS2GSMemorySize));
  Result := Meets(Pages, FHeld);
end;

procedure TPS2GSVulkanHLE.ReleaseHolds;
begin
  FillChar(FHeld, SizeOf(FHeld), 0);
  Inc(FRevision);
end;

procedure TPS2GSVulkanHLE.WatchMemory(Addr, Size: Cardinal);
begin
  AddRange(FWatched, Addr and MemMask, Min(Size, PS2GSMemorySize));
  Inc(FRevision);
end;

procedure TPS2GSVulkanHLE.ReleaseWatches;
begin
  FillChar(FWatched, SizeOf(FWatched), 0);
  Inc(FRevision);
end;

function TPS2GSVulkanHLE.Pending: Boolean;
begin
  Result := AnyPage(FHeld) or AnyPage(FWatched);
end;

{ Targets }

// The target D draws into, whole page rows as tall as FNeedY needs.
function TPS2GSVulkanHLE.TargetFor(const D: TPS2GSDraw): TPS2HLETarget;
begin
  var PB := PixelBytesOf(D.FPSM);
  var Stride := D.FBW * 64;
  var PH := PageRowsOf(D.FPSM);
  var MaxH := Min(2048, Integer(PS2GSMemorySize div (Stride * PB)));
  MaxH := MaxH - MaxH mod PH;
  var Need := Min(RoundRows(FNeedY + 1, PH), MaxH);
  Result := TPS2HLETarget(FindTarget((D.FBP shl 8) and MemMask, D.FPSM, Stride, PB, Need, Need, MaxH));
end;

// Another target newer than GS memory in Pages (which T is about to use):
// everything goes back to GS memory first.
procedure TPS2GSVulkanHLE.FlushOthers(T: TPS2HLETarget; const Pages: TPS2GSPages);
var
  Theirs: TPS2GSPages;
begin
  for var V in FTargets do
  begin
    var U := TPS2HLETarget(V);
    if (U = T) or not (U.Dirty or U.ZDirty) then
      Continue;
    FillChar(Theirs, SizeOf(Theirs), 0);
    if U.Dirty then
      AddRange(Theirs, U.Addr, U.Bytes);
    if U.ZDirty then
      AddRange(Theirs, U.ZAddr, U.ZBytes);
    if Meets(Theirs, Pages) then
    begin
      Flush(frOthers);
      Exit;
    end;
  end;
end;

function TPS2GSVulkanHLE.BandRows(T: TVulkanHLETarget): Integer;
begin
  Result := EnsureRange((HLEUploadCapacity div 2) div (T.Width * 4), 1, T.Height);
end;

// GS memory's pixels into the colour image.
procedure TPS2GSVulkanHLE.LoadTarget(T: TVulkanHLETarget);
var
  A: TPS2GSAddressing;
begin
  A.Init(Integer(T.Format), T.Addr shr 8, T.Stride shr 6);
  var Words := PCardinal(FMemory.Data);
  var Halves := PWord(FMemory.Data);
  var Rows := BandRows(T);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    var Offset: Int64;
    var P := PCardinal(StageUpload(Int64(T.Width) * N * 4, Offset));
    for var Y := Y0 to Y0 + N - 1 do
    begin
      var RB := A.RowBase(Cardinal(Y));
      var RO := A.RowOffsets(Cardinal(Y));
      case T.Format of
        PSMCT32, PSMZ32:
          for var X := 0 to T.Width - 1 do
          begin
            P^ := Words[A.InRow(RB, RO, Cardinal(X))];
            Inc(P);
          end;
        PSMCT24, PSMZ24:
          for var X := 0 to T.Width - 1 do
          begin
            P^ := (Words[A.InRow(RB, RO, Cardinal(X))] and $FFFFFF) or $80000000;
            Inc(P);
          end;
      else
        for var X := 0 to T.Width - 1 do
        begin
          var V: Cardinal := Halves[A.InRow(RB, RO, Cardinal(X))];
          var C := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
          if (V and $8000) <> 0 then
            C := C or $FF000000;
          P^ := C;
          Inc(P);
        end;
      end;
    end;
    CopyToImage(T.Color.Image, VK_IMAGE_ASPECT_COLOR_BIT, Offset, 0, 0, Y0, T.Width, N);
    Inc(Y0, N);
  end;
end;

// A depth value as the depth image holds it.
function TPS2GSVulkanHLE.DepthBits(Z: Cardinal): Cardinal;
begin
  var F := Z / FZScale;
  if FD24 then
    Result := Min(Cardinal(Round(F * 16777215)), 16777215)
  else
    PSingle(@Result)^ := F;
end;

function TPS2GSVulkanHLE.DepthOf(const D: TPS2GSDraw; Z: Cardinal): Single;
begin
  // Without depth clamping the GPU clips past the range: clamped per vertex.
  if not FDepthClamp and (Z > D.ZMax) then
    Z := D.ZMax;
  Result := Z / FZScale;
end;

procedure TPS2GSVulkanHLE.LoadDepth(T: TPS2HLETarget);
var
  A: TPS2GSAddressing;
begin
  FZScale := DepthRange(T.ZPSM);
  A.Init(Integer(T.ZPSM), T.ZAddr shr 8, T.Stride shr 6);
  var Rows := BandRows(T);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    var Offset: Int64;
    var P := PCardinal(StageUpload(Int64(T.Width) * N * 4, Offset));
    for var Y := Y0 to Y0 + N - 1 do
    begin
      var RB := A.RowBase(Cardinal(Y));
      var RO := A.RowOffsets(Cardinal(Y));
      for var X := 0 to T.Width - 1 do
      begin
        P^ := DepthBits(FMemory.ReadAt(Integer(T.ZPSM), A.InRow(RB, RO, Cardinal(X))));
        Inc(P);
      end;
    end;
    CopyToImage(T.Depth.Image, VK_IMAGE_ASPECT_DEPTH_BIT, Offset, 0, 0, Y0, T.Width, N);
    Inc(Y0, N);
  end;
  SetLength(T.ZShadow, T.ZBytes);
  ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
  T.ZLoaded := True;
  Inc(FDepthLoads);
end;

// The depth image holds D's depth buffer as GS memory has it (or newer).
procedure TPS2GSVulkanHLE.EnsureDepth(T: TPS2HLETarget; const D: TPS2GSDraw);
begin
  var ZA := (D.ZBP shl 8) and MemMask;
  var Same := T.ZLoaded and (T.ZAddr = ZA) and (T.ZPSM = D.ZPSM);
  FZScale := DepthRange(D.ZPSM);
  if Same and T.ZDirty then
    Exit;
  // Its own depth image holds another buffer, or another target this one,
  // newer than GS memory: back there first.
  if T.ZDirty then
    Flush(frDepth)
  else
    for var V in FTargets do
      if (V <> T) and TPS2HLETarget(V).ZDirty and (TPS2HLETarget(V).ZAddr = ZA) then
      begin
        Flush(frDepth);
        Break;
      end;
  T.ZAddr := ZA;
  T.ZPSM := D.ZPSM;
  if Same and (T.ZVerified = FRun) then
    Exit;
  if Same and (Cardinal(Length(T.ZShadow)) = T.ZBytes) and MemoryEquals(ZA, @T.ZShadow[0], Length(T.ZShadow)) then
  begin
    T.ZVerified := FRun;
    Exit;
  end;
  if MemoryHeld(ZA, T.ZBytes) then
    Flush(frDepth);
  LoadDepth(T);
  T.ZVerified := FRun;
end;

procedure TPS2GSVulkanHLE.WatchDepth(T: TPS2HLETarget);
begin
  WatchMemory(T.ZAddr, T.ZBytes);
end;

procedure TPS2GSVulkanHLE.HoldDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
begin
  HoldMemory(T.ZAddr + Cardinal(Y1) * T.ZRowBytes, Cardinal(Y2 - Y1 + 1) * T.ZRowBytes);
end;

procedure TPS2GSVulkanHLE.HoldNewDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
begin
  if T.ZHeldY1 > T.ZHeldY2 then
  begin
    HoldDepthRows(T, Y1, Y2);
    T.ZHeldY1 := Y1;
    T.ZHeldY2 := Y2;
    Exit;
  end;
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

// The rows drawn of a newer target, held again.
procedure TPS2GSVulkanHLE.HoldTarget(T: TPS2HLETarget);
begin
  if T.Dirty and (T.HeldY1 <= T.HeldY2) then
  begin
    var RowBytes := T.Stride * T.PixelBytes;
    HoldMemory(T.Addr + Cardinal(T.HeldY1) * RowBytes, Cardinal(T.HeldY2 - T.HeldY1 + 1) * RowBytes);
  end;
  if T.ZDirty and (T.ZHeldY1 <= T.ZHeldY2) then
    HoldDepthRows(T, T.ZHeldY1, T.ZHeldY2);
end;

// The colour of the box drawn (Color) and the depth of the box written
// (Depth) back into GS memory, with one wait for the GPU. The depth is
// equal to GS memory afterwards; the colour's bookkeeping is the caller's.
procedure TPS2GSVulkanHLE.Store(T: TPS2HLETarget; Color, Depth: Boolean);
var
  Regions: array[0..1] of VkBufferImageCopy;
  A: TPS2GSAddressing;
begin
  Color := Color and T.Dirty;
  Depth := Depth and T.ZDirty;
  var CW := 0;
  var CH := 0;
  var ZW := 0;
  var ZH := 0;
  if Color then
  begin
    T.X1 := Max(T.X1, 0);
    T.Y1 := Max(T.Y1, 0);
    T.X2 := Min(T.X2, T.Width - 1);
    T.Y2 := Min(T.Y2, T.Height - 1);
    CW := Max(T.X2 - T.X1 + 1, 0);
    CH := Max(T.Y2 - T.Y1 + 1, 0);
  end;
  if Depth then
  begin
    T.ZX1 := Max(T.ZX1, 0);
    T.ZY1 := Max(T.ZY1, 0);
    T.ZX2 := Min(T.ZX2, T.Width - 1);
    T.ZY2 := Min(T.ZY2, T.Height - 1);
    ZW := Max(T.ZX2 - T.ZX1 + 1, 0);
    ZH := Max(T.ZY2 - T.ZY1 + 1, 0);
  end;
  var ColorBytes := (Int64(CW) * CH * 4 + 15) and not Int64(15);
  if (CW * CH > 0) and (ZW * ZH > 0) and (ColorBytes + Int64(ZW) * ZH * 4 > Int64(FReadback.Size)) then
  begin
    // One at a time.
    Store(T, True, False);
    Store(T, False, True);
    Exit;
  end;
  Record_;
  EndPass;
  ImageBarrier;
  var Cmd := Slot.Cmd.Handle;
  if CW * CH > 0 then
  begin
    Regions[0] := Default(VkBufferImageCopy);
    Regions[0].imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
    Regions[0].imageSubresource.layerCount := 1;
    Regions[0].imageOffset.x := T.X1;
    Regions[0].imageOffset.y := T.Y1;
    Regions[0].imageExtent.width := CW;
    Regions[0].imageExtent.height := CH;
    Regions[0].imageExtent.depth := 1;
    FAPI.vkCmdCopyImageToBuffer(Cmd, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Regions[0]);
  end;
  if ZW * ZH > 0 then
  begin
    Regions[1] := Default(VkBufferImageCopy);
    Regions[1].bufferOffset := ColorBytes;
    Regions[1].imageSubresource.aspectMask := VK_IMAGE_ASPECT_DEPTH_BIT;
    Regions[1].imageSubresource.layerCount := 1;
    Regions[1].imageOffset.x := T.ZX1;
    Regions[1].imageOffset.y := T.ZY1;
    Regions[1].imageExtent.width := ZW;
    Regions[1].imageExtent.height := ZH;
    Regions[1].imageExtent.depth := 1;
    FAPI.vkCmdCopyImageToBuffer(Cmd, T.Depth.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Regions[1]);
  end;
  HostReadBarrier;
  WaitAll;
  if (CW * CH > 0) or (ZW * ZH > 0) then
    FReadback.Invalidate;
  var Words := PCardinal(FMemory.Data);
  var Halves := PWord(FMemory.Data);
  if CW * CH > 0 then
  begin
    A.Init(Integer(T.Format), T.Addr shr 8, T.Stride shr 6);
    var C := PCardinal(FReadback.Data);
    for var Y := T.Y1 to T.Y2 do
    begin
      var RB := A.RowBase(Cardinal(Y));
      var RO := A.RowOffsets(Cardinal(Y));
      case T.Format of
        PSMCT32, PSMZ32:
          for var X := T.X1 to T.X2 do
          begin
            Words[A.InRow(RB, RO, Cardinal(X))] := C^;
            Inc(C);
          end;
        PSMCT24, PSMZ24:
          for var X := T.X1 to T.X2 do
          begin
            var I := A.InRow(RB, RO, Cardinal(X));
            Words[I] := (Words[I] and $FF000000) or (C^ and $FFFFFF);
            Inc(C);
          end;
      else
        for var X := T.X1 to T.X2 do
        begin
          Halves[A.InRow(RB, RO, Cardinal(X))] := Word(Color32To16(C^));
          Inc(C);
        end;
      end;
    end;
  end;
  if ZW * ZH > 0 then
  begin
    A.Init(Integer(T.ZPSM), T.ZAddr shr 8, T.Stride shr 6);
    var Scale := DepthRange(T.ZPSM);
    var ZMax: Double := Scale - 1;
    var Z := PCardinal(FReadback.Data + ColorBytes);
    for var Y := T.ZY1 to T.ZY2 do
    begin
      var RB := A.RowBase(Cardinal(Y));
      var RO := A.RowOffsets(Cardinal(Y));
      for var X := T.ZX1 to T.ZX2 do
      begin
        var F: Double;
        if FD24 then
          F := (Z^ and $FFFFFF) / 16777215
        else
          F := PSingle(Z)^;
        Inc(Z);
        F := F * Scale;
        var V: Cardinal;
        if not (F > 0) then
          V := 0
        else if F >= ZMax then
          V := Cardinal(Trunc(ZMax))
        else
          V := Cardinal(Trunc(F + 0.5));
        FMemory.WriteAt(Integer(T.ZPSM), A.InRow(RB, RO, Cardinal(X)), V);
      end;
    end;
  end;
  if Depth then
  begin
    T.ZDirty := False;
    T.ZStale := False;
    SetLength(T.ZShadow, T.ZBytes);
    ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
  end;
end;

procedure TPS2GSVulkanHLE.StoreTarget(T: TVulkanHLETarget);
begin
  Store(TPS2HLETarget(T), True, True);
end;

// The targets newer than GS memory in Pages go back to it (not all of them,
// as FlushAll); the rest stay held, and a new run starts (what was compared
// with GS memory there is compared again).
procedure TPS2GSVulkanHLE.StoreOverlapping(const Pages: TPS2GSPages);
var
  Held: TPS2GSPages;
begin
  var Any := False;
  for var V in FTargets do
  begin
    var T := TPS2HLETarget(V);
    var Color := False;
    var Depth := False;
    if T.Dirty and (T.HeldY1 <= T.HeldY2) then
    begin
      FillChar(Held, SizeOf(Held), 0);
      var RowBytes := T.Stride * T.PixelBytes;
      AddRange(Held, T.Addr + Cardinal(T.HeldY1) * RowBytes, Cardinal(T.HeldY2 - T.HeldY1 + 1) * RowBytes);
      Color := Meets(Held, Pages);
    end;
    if T.ZDirty and (T.ZHeldY1 <= T.ZHeldY2) then
    begin
      FillChar(Held, SizeOf(Held), 0);
      AddRange(Held, T.ZAddr + Cardinal(T.ZHeldY1) * T.ZRowBytes, Cardinal(T.ZHeldY2 - T.ZHeldY1 + 1) * T.ZRowBytes);
      Depth := Meets(Held, Pages);
    end;
    if not (Color or Depth) then
      Continue;
    Any := True;
    Store(T, Color, Depth);
    if Color then
    begin
      // As FlushAll leaves it: the shadow of the rows drawn is GS memory's.
      T.Dirty := False;
      T.Stale := False;
      if Cardinal(Length(T.Shadow)) <> T.Bytes then
      begin
        SetLength(T.Shadow, T.Bytes);
        ReadMemory(T.Addr, @T.Shadow[0], Length(T.Shadow));
      end
      else
      begin
        var RowBytes := T.Stride * T.PixelBytes;
        ReadMemory(T.Addr + Cardinal(T.HeldY1) * RowBytes, @T.Shadow[Cardinal(T.HeldY1) * RowBytes],
          Cardinal(T.HeldY2 - T.HeldY1 + 1) * RowBytes);
      end;
    end;
  end;
  if not Any then
    Exit;
  Inc(FPartialStores);
  ReleaseHolds;
  for var V in FTargets do
    HoldTarget(TPS2HLETarget(V));
  NewRun;
end;

// A watched page is about to be written: a texture's, a depth buffer's only
// tested, or a drawn target's outside its rows drawn. Nothing waits for the
// GPU: textures and depth buffers are compared again when used, a drawn
// target the write reaches is Stale outside its rows drawn; the other
// targets are watched again.
procedure TPS2GSVulkanHLE.WatchFault(const Writes: TPS2GSPages);
var
  Pages: TPS2GSPages;
begin
  ReleaseWatches;
  NewRun;
  Inc(FStats.WatchFaults);
  for var V in FTargets do
  begin
    var T := TPS2HLETarget(V);
    if T.Dirty and not T.Stale then
    begin
      FillChar(Pages, SizeOf(Pages), 0);
      AddRange(Pages, T.Addr, T.Bytes);
      if Meets(Pages, Writes) then
        T.Stale := True
      else
        WatchTarget(T);
    end;
    if T.ZDirty and not T.ZStale then
    begin
      FillChar(Pages, SizeOf(Pages), 0);
      AddRange(Pages, T.ZAddr, T.ZBytes);
      if Meets(Pages, Writes) then
        T.ZStale := True
      else
        WatchDepth(T);
    end;
  end;
end;

procedure TPS2GSVulkanHLE.Flush(Reason: TPS2HLEFlush);
begin
  Inc(FFlushes[Reason]);
  FlushAll;
end;

procedure TPS2GSVulkanHLE.SyncAll;
begin
  Inc(FFlushes[frSync]);
  Sync;
end;

procedure TPS2GSVulkanHLE.Access(const Reads, Writes: TPS2GSPages);
var
  Both: TPS2GSPages;
begin
  for var I := 0 to High(Both) do
    Both[I] := Reads[I] or Writes[I];
  if Meets(Both, FHeld) then
    StoreOverlapping(Both);
  if Meets(Writes, FWatched) then
    WatchFault(Writes);
end;

{ Textures }

// A target drawn from as a texture, sampled from its image: newer than GS
// memory with no stale rows, a texture format reading the target's pixels as
// they are (32/24-bit textures of a 32-bit frame, 24-bit ones of a 24-bit
// frame, 16-bit ones of the same 16-bit frame), the frame's width, from a
// page of it (OffX, OffY: where in the image). Nil when it is not one.
function TPS2GSVulkanHLE.TargetTexture(const D: TPS2GSDraw; out OffX, OffY: Integer): TPS2HLETarget;
begin
  Result := nil;
  OffX := 0;
  OffY := 0;
  if D.TBW = 0 then
    Exit;
  var A := (D.TBP shl 8) and MemMask;
  for var V in FTargets do
  begin
    var U := TPS2HLETarget(V);
    if not U.Dirty or U.Stale or (U.Stride <> D.TBW * 64) then
      Continue;
    case D.TPSM of
      PSMCT32:
        if U.Format <> PSMCT32 then
          Continue;
      PSMCT24:
        if not (U.Format in [PSMCT32, PSMCT24]) then
          Continue;
      PSMCT16, PSMCT16S:
        if U.Format <> D.TPSM then
          Continue;
    else
      Exit;
    end;
    var Delta := (A - U.Addr) and MemMask;
    if (Delta >= U.Bytes) or ((Delta and 8191) <> 0) then
      Continue;
    if (Result <> nil) and (Result.LastUse > U.LastUse) then
      Continue;
    var Pages := Integer(Delta shr PageShift);
    var Across := Integer(U.Stride shr 6);
    Result := U;
    OffX := (Pages mod Across) * 64;
    OffY := (Pages div Across) * PageRowsOf(U.Format);
  end;
  if Result <> nil then
    Inc(FTargetTextures);
end;

// T's colour image copied, as a texture: what a draw reads of the target it
// draws is what was there before it.
function TPS2GSVulkanHLE.CopyOf(T: TPS2HLETarget): TVulkanHLETexture;
var
  Region: VkImageCopy;
begin
  if T.Copy = nil then
  begin
    T.Copy := TVulkanHLETexture.Create;
    T.Copy.Width := T.Width;
    T.Copy.Height := T.Height;
    T.Copy.Levels := 1;
    T.Copy.Target := T;
    T.Copy.Image := CreateImage(VK_FORMAT_R8G8B8A8_UNORM, T.Width, T.Height, 1,
      VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
  end;
  Record_;
  EndPass;
  ImageBarrier;
  Region := Default(VkImageCopy);
  Region.srcSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.srcSubresource.layerCount := 1;
  Region.dstSubresource := Region.srcSubresource;
  Region.extent.width := T.Width;
  Region.extent.height := T.Height;
  Region.extent.depth := 1;
  FAPI.vkCmdCopyImage(Slot.Cmd.Handle, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, T.Copy.Image.Image,
    VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
  Inc(FCopies);
  Result := T.Copy;
  FCopyX1 := MaxInt;
  FCopyY1 := MaxInt;
  FCopyX2 := -1;
  FCopyY2 := -1;
end;

// A primitive of a draw sampling its own target (Count vertices) is about to
// be added: when it reads pixels drawn since the copy was made, those go
// into the copy first (the GS reads what is drawn before, primitive by
// primitive; in-place reductions read their own output).
procedure TPS2GSVulkanHLE.RefreshCopy(V: PPS2HLEVertex; Count: Integer);
var
  Region: VkImageCopy;
begin
  if FCopyX1 > FCopyX2 then
    Exit;
  var T := TPS2HLETarget(FTarget);
  // The texels the vertices' coordinates reach, a texel around for filtering.
  var U1 := MaxInt;
  var V1 := MaxInt;
  var U2 := -MaxInt;
  var V2 := -MaxInt;
  for var I := 0 to Count - 1 do
  begin
    var Q := V[I].Q;
    if Q = 0 then
      Q := 1;
    var S := V[I].S / Q / 16;
    var TT := V[I].T / Q / 16;
    if not ((Abs(S) < 65536) and (Abs(TT) < 65536)) then
    begin
      U1 := -MaxInt div 2;
      V1 := -MaxInt div 2;
      U2 := MaxInt div 2;
      V2 := MaxInt div 2;
      Break;
    end;
    U1 := Min(U1, Floor(S) - 1);
    V1 := Min(V1, Floor(TT) - 1);
    U2 := Max(U2, Floor(S) + 1);
    V2 := Max(V2, Floor(TT) + 1);
  end;
  // Wrapping may reach any texel of the texture.
  var W := 1 shl FLast.TW;
  var H := 1 shl FLast.TH;
  if (U1 < 0) or (U2 >= W) or (V1 < 0) or (V2 >= H) then
  begin
    U1 := 0;
    V1 := 0;
    U2 := W - 1;
    V2 := H - 1;
  end;
  Inc(U1, FCopyOffX);
  Inc(U2, FCopyOffX);
  Inc(V1, FCopyOffY);
  Inc(V2, FCopyOffY);
  if (U2 < FCopyX1) or (U1 > FCopyX2) or (V2 < FCopyY1) or (V1 > FCopyY2) then
    Exit;
  Record_;
  EndPass;
  ImageBarrier;
  Region := Default(VkImageCopy);
  Region.srcSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.srcSubresource.layerCount := 1;
  Region.dstSubresource := Region.srcSubresource;
  Region.srcOffset.x := FCopyX1;
  Region.srcOffset.y := FCopyY1;
  Region.dstOffset := Region.srcOffset;
  Region.extent.width := FCopyX2 - FCopyX1 + 1;
  Region.extent.height := FCopyY2 - FCopyY1 + 1;
  Region.extent.depth := 1;
  FAPI.vkCmdCopyImage(Slot.Cmd.Handle, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, T.Copy.Image.Image,
    VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
  Inc(FCopies);
  FCopyX1 := MaxInt;
  FCopyY1 := MaxInt;
  FCopyX2 := -1;
  FCopyY2 := -1;
  ApplyBindings;
end;

// The CLUT entries D's texels take, in FClutCopy (FClutCount of them).
procedure TPS2GSVulkanHLE.CopyClut(const D: TPS2GSDraw);
begin
  var Count := 16;
  if D.TPSM in [PSMT8, PSMT8H] then
    Count := 256;
  var N := 0;
  for var I := 0 to Count - 1 do
  begin
    var Index := I + D.ClutOffset;
    if D.Clut32 then
    begin
      Index := Index and 255;
      FClutCopy[N] := FClut[Index];
      FClutCopy[N + 1] := FClut[Index + 256];
      Inc(N, 2);
    end
    else
    begin
      FClutCopy[N] := FClut[Index and 511];
      Inc(N);
    end;
  end;
  FClutCount := N;
end;

// The GS blocks (256 bytes) of the texture being looked up (its levels
// 0..Levels - 1), as runs of bytes in FTexBytes with the CLUT entries it
// takes (FClutCopy) last: once a look-up, when it is compared or decoded.
procedure TPS2GSVulkanHLE.GatherTexture(Request: Pointer);
var
  A: TPS2GSAddressing;
begin
  if FTexGathered then
    Exit;
  FTexGathered := True;
  var R := PPS2HLETexRequest(Request);
  var D := R.D;
  var Levels := R.Levels;
  FillChar(FBlockBits, SizeOf(FBlockBits), 0);
  // A block's texels, and a texel address's bytes (as a shift, 4-bit: -1).
  var BW := 8;
  var BH := 8;
  var Shift := 2;
  case D.TPSM of
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      begin
        BW := 16;
        Shift := 1;
      end;
    PSMT8:
      begin
        BW := 16;
        BH := 16;
        Shift := 0;
      end;
    PSMT4:
      begin
        BW := 32;
        BH := 16;
        Shift := -1;
      end;
  end;
  for var L := 0 to Levels - 1 do
  begin
    var X0 := 0;
    var Y0 := 0;
    var X1 := Max(1, (1 shl D.TW) shr L) - 1;
    var Y1 := Max(1, (1 shl D.TH) shr L) - 1;
    if L = 0 then
    begin
      X0 := R.U0;
      Y0 := R.V0;
      X1 := R.U0 + R.W - 1;
      Y1 := R.V0 + R.H - 1;
    end;
    A.Init(Integer(D.TPSM), D.LevelTBP[L], D.LevelTBW[L]);
    for var BY := Y0 div BH to Y1 div BH do
      for var BX := X0 div BW to X1 div BW do
      begin
        var U := A.Addr(Cardinal(BX * BW), Cardinal(BY * BH));
        var Block: Cardinal;
        if Shift < 0 then
          Block := U shr 9
        else
          Block := (U shl Shift) shr 8;
        Block := Block and 16383;
        FBlockBits[Block shr 6] := FBlockBits[Block shr 6] or (UInt64(1) shl (Block and 63));
      end;
  end;
  // Runs of blocks, whole words of the set skipped.
  FTexByteCount := 0;
  var Run := -1;
  for var I := 0 to High(FBlockBits) + 1 do
  begin
    var Bits: UInt64 := 0;
    if I <= High(FBlockBits) then
      Bits := FBlockBits[I];
    if ((Bits = 0) and (Run < 0)) or ((Bits = High(UInt64)) and (Run >= 0)) then
      Continue;
    for var K := 0 to 63 do
    begin
      var B := I * 64 + K;
      var Present := ((Bits shr K) and 1) <> 0;
      if Present and (Run < 0) then
        Run := B
      else if not Present and (Run >= 0) then
      begin
        if FTexByteCount >= Length(FTexBytes) then
          SetLength(FTexBytes, FTexByteCount * 2 + 16);
        FTexBytes[FTexByteCount].Data := FMemory.Data + Cardinal(Run) * 256;
        FTexBytes[FTexByteCount].Size := (B - Run) * 256;
        Inc(FTexByteCount);
        Run := -1;
      end;
      if (Run < 0) and ((Bits shr K) = 0) then
        Break;
    end;
  end;
  if IsPalettized(D.TPSM) then
  begin
    if FTexByteCount >= Length(FTexBytes) then
      SetLength(FTexBytes, FTexByteCount + 1);
    FTexBytes[FTexByteCount].Data := @FClutCopy[0];
    FTexBytes[FTexByteCount].Size := FClutCount * 2;
    Inc(FTexByteCount);
  end;
  SetLength(FTexBytes, FTexByteCount);
end;

// The pages held that a texture in format TPSM may read: all of them, but for
// the high-byte formats (8H, 4HL, 4HH) the 24-bit buffers' (which keep that
// byte).
function TPS2GSVulkanHLE.HeldFor(TPSM: Cardinal): TPS2GSPages;
begin
  if not (TPSM in [PSMT8H, PSMT4HL, PSMT4HH]) then
    Exit(FHeld);
  FillChar(Result, SizeOf(Result), 0);
  for var V in FTargets do
  begin
    var T := TPS2HLETarget(V);
    if T.Dirty and not Is24(T.Format) and (T.HeldY1 <= T.HeldY2) then
    begin
      var RowBytes := T.Stride * T.PixelBytes;
      AddRange(Result, T.Addr + Cardinal(T.HeldY1) * RowBytes, Cardinal(T.HeldY2 - T.HeldY1 + 1) * RowBytes);
    end;
    if T.ZDirty and not Is24(T.ZPSM) and (T.ZHeldY1 <= T.ZHeldY2) then
      AddRange(Result, T.ZAddr + Cardinal(T.ZHeldY1) * T.ZRowBytes, Cardinal(T.ZHeldY2 - T.ZHeldY1 + 1) * T.ZRowBytes);
  end;
end;

// The coordinates C0..C1 through region repeat ((C and MinC) or MaxC): the
// lowest and highest; False over more than a texture's width.
function RegionRepeatSpan(var C0, C1: Integer; MinC, MaxC: Integer): Boolean;
begin
  Result := C1 - C0 <= 1024;
  if not Result then
    Exit;
  var Lo := MaxInt;
  var Hi := -MaxInt;
  for var C := C0 to C1 do
  begin
    var R := (C and MinC) or MaxC;
    Lo := Min(Lo, R);
    Hi := Max(Hi, R);
  end;
  C0 := Lo;
  C1 := Hi;
end;

// The texels of level 0 the Count vertices' coordinates reach (a texel around
// for filtering), where the wrap modes keep them inside a box: False where
// they may reach any (wrapping, Q of either sign).
function TPS2GSVulkanHLE.TexelBox(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer;
  out U0, V0, U1, V1: Integer): Boolean;
begin
  Result := False;
  U0 := MaxInt;
  V0 := MaxInt;
  U1 := -MaxInt;
  V1 := -MaxInt;
  if Count <= 0 then
    Exit;
  var Positive := V[0].Q > 0;
  for var I := 0 to Count - 1 do
  begin
    var Q := V[I].Q;
    if (Q = 0) or ((Q > 0) <> Positive) then
      Exit;
    var S := V[I].S / Q / 16;
    var T := V[I].T / Q / 16;
    if not ((Abs(S) < 65536) and (Abs(T) < 65536)) then
      Exit;
    U0 := Min(U0, Floor(S) - 1);
    V0 := Min(V0, Floor(T) - 1);
    U1 := Max(U1, Floor(S) + 1);
    V1 := Max(V1, Floor(T) + 1);
  end;
  var W := 1 shl D.TW;
  var H := 1 shl D.TH;
  // Repeat: only where nothing wraps; clamps keep the box inside; region
  // repeat maps it.
  case D.WMS of
    0:
      if (U0 < -1) or (U1 > W) then
        Exit;
    2:
      begin
        U0 := EnsureRange(U0, D.MINU, D.MAXU);
        U1 := EnsureRange(U1, D.MINU, D.MAXU);
      end;
    3:
      if not RegionRepeatSpan(U0, U1, D.MINU, D.MAXU) then
        Exit;
  end;
  case D.WMT of
    0:
      if (V0 < -1) or (V1 > H) then
        Exit;
    2:
      begin
        V0 := EnsureRange(V0, D.MINV, D.MAXV);
        V1 := EnsureRange(V1, D.MINV, D.MAXV);
      end;
    3:
      if not RegionRepeatSpan(V0, V1, D.MINV, D.MAXV) then
        Exit;
  end;
  U0 := EnsureRange(U0, 0, W - 1);
  U1 := EnsureRange(U1, 0, W - 1);
  V0 := EnsureRange(V0, 0, H - 1);
  V1 := EnsureRange(V1, 0, H - 1);
  Result := (U0 <= U1) and (V0 <= V1);
end;

// D's texture (its levels when the LOD picks them), decoded, compared with
// its bytes, uploaded. A large texture of one level that the primitive
// (Count vertices at V) reads a small part of is decoded in that part alone
// (FPartW and the rest: the push constants' offset).
function TPS2GSVulkanHLE.EnsureTexture(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer): TVulkanHLETexture;
var
  Request: TPS2HLETexRequest;
begin
  var Levels := 1;
  if D.UseLod and (D.MMIN >= 2) and (D.MXL > 0) then
    Levels := Min(D.MXL + 1, Integer(Max(D.TW, D.TH)) + 1);
  if IsPalettized(D.TPSM) then
    CopyClut(D);
  var Key := FNV($CBF29CE484222325, UInt64(D.TPSM) or (UInt64(D.TW) shl 8) or (UInt64(D.TH) shl 12) or
    (UInt64(Levels) shl 16));
  if (D.TPSM in [PSMCT24, PSMCT16, PSMCT16S, PSMZ24, PSMZ16, PSMZ16S]) or
    (IsPalettized(D.TPSM) and not D.Clut32) then
    Key := FNV(Key, UInt64(D.TA0) or (UInt64(D.TA1) shl 8) or (UInt64(Ord(D.AEM)) shl 16));
  for var L := 0 to Levels - 1 do
    Key := FNV(Key, UInt64(D.LevelTBP[L]) or (UInt64(D.LevelTBW[L]) shl 16));
  if IsPalettized(D.TPSM) then
  begin
    Key := FNV(Key, UInt64(Ord(D.Clut32)) or (UInt64(FClutCount) shl 8));
    var P := PUInt64(@FClutCopy[0]);
    for var I := 0 to FClutCount div 4 - 1 do
      Key := FNV(Key, P[I]);
  end;
  Request.U0 := 0;
  Request.V0 := 0;
  Request.W := 1 shl D.TW;
  Request.H := 1 shl D.TH;
  FPartW := 0;
  // A part, unless the whole texture is there already; grown to take in the
  // part before (FGrow, Emit).
  var BU0, BV0, BU1, BV1: Integer;
  var Box := (Levels = 1) and (Request.W * Request.H >= 65536) and (FindTexture(Key) = nil) and
    TexelBox(D, V, Count, BU0, BV0, BU1, BV1);
  if Box and FGrow then
  begin
    BU0 := Min(BU0, FGrowU0);
    BV0 := Min(BV0, FGrowV0);
    BU1 := Max(BU1, FGrowU1);
    BV1 := Max(BV1, FGrowV1);
  end;
  if Box and not FWhole and ((BU1 - BU0 + 1) * (BV1 - BV0 + 1) * 16 <= Request.W * Request.H) then
  begin
    Request.U0 := BU0;
    Request.V0 := BV0;
    Request.W := BU1 - BU0 + 1;
    Request.H := BV1 - BV0 + 1;
    FPartU0 := BU0;
    FPartV0 := BV0;
    FPartW := Request.W;
    FPartH := Request.H;
    Key := FNV(Key, UInt64(BU0) or (UInt64(BV0) shl 16) or (UInt64(Request.W) shl 32) or (UInt64(Request.H) shl 48));
    Inc(FPartials);
  end;
  // A target's newer pixels there go back to GS memory first.
  FillChar(FTexPages, SizeOf(FTexPages), 0);
  if FPartW > 0 then
    AddRectPages(FTexPages, D.TBP, D.TBW, D.TPSM, Request.U0, Request.V0, Request.U0 + Request.W - 1,
      Request.V0 + Request.H - 1)
  else
    for var L := 0 to Levels - 1 do
      AddRectPages(FTexPages, D.LevelTBP[L], D.LevelTBW[L], D.TPSM, 0, 0, Max(1, (1 shl D.TW) shr L) - 1,
        Max(1, (1 shl D.TH) shr L) - 1);
  if Meets(FTexPages, FHeld) and Meets(FTexPages, HeldFor(D.TPSM)) then
    Flush(frTexture);
  Request.D := @D;
  Request.Levels := Levels;
  FTexGathered := False;
  Result := CachedTexture(Key, @Request);
end;

procedure TPS2GSVulkanHLE.DescribeTexture(Request: Pointer; out Width, Height, Levels, Scale: Integer);
begin
  var R := PPS2HLETexRequest(Request);
  Width := R.W;
  Height := R.H;
  Levels := R.Levels;
  Scale := 1;
end;

function TPS2GSVulkanHLE.TextureMatches(T: TVulkanHLETexture; Request: Pointer): Boolean;
begin
  GatherTexture(PPS2HLETexRequest(Request));
  Result := SameSource(T, FTexBytes);
end;

procedure TPS2GSVulkanHLE.DecodeTexture(T: TVulkanHLETexture; Request: Pointer);
var
  A: TPS2GSAddressing;
  Pal: array[0..255] of Cardinal;
begin
  var R := PPS2HLETexRequest(Request);
  var D := R.D;
  GatherTexture(R);
  KeepSource(T, FTexBytes);
  var PSM := Integer(D.TPSM);
  // A palettized texture's indices as colours (as TPS2GSDrawer.TexelFrom).
  var Indices := 0;
  case D.TPSM of
    PSMT8, PSMT8H: Indices := 256;
    PSMT4, PSMT4HL, PSMT4HH: Indices := 16;
  end;
  for var I := 0 to Indices - 1 do
  begin
    var Index := I + D.ClutOffset;
    if D.Clut32 then
    begin
      Index := Index and 255;
      Pal[I] := Cardinal(FClut[Index]) or (Cardinal(FClut[Index + 256]) shl 16);
    end
    else
      Pal[I] := ExpandTexA(FClut[Index and 511], D.TA0, D.TA1, D.AEM);
  end;
  var Words := PCardinal(FMemory.Data);
  var Halves := PWord(FMemory.Data);
  var Bytes := FMemory.Data;
  for var L := 0 to T.Levels - 1 do
  begin
    var W := Max(1, (1 shl D.TW) shr L);
    var H := Max(1, (1 shl D.TH) shr L);
    var X0 := 0;
    var Y0 := 0;
    if L = 0 then
    begin
      X0 := R.U0;
      Y0 := R.V0;
      W := R.W;
      H := R.H;
    end;
    A.Init(PSM, D.LevelTBP[L], D.LevelTBW[L]);
    var P := LevelTexels(T, W, H);
    for var Y := Y0 to Y0 + H - 1 do
    begin
      // A.Addr with the row's part once: (Base + (column + row * Width) shl
      // PageShift + offset) and Mask, the shifted sum split.
      var RowBase := A.Base + ((Cardinal(Y) shr A.HShift) * A.Width) shl A.PageShift;
      var Offsets := A.Offsets + ((Cardinal(Y) and A.HMask) shl A.WShift);
      // As TPS2GSDrawer.TexelFrom (TPS2GSMemory.ReadAt).
      case D.TPSM of
        PSMCT32, PSMZ32:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := Words[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask];
            Inc(P);
          end;
        PSMCT24, PSMZ24:
          for var X := X0 to X0 + W - 1 do
          begin
            var Raw := Words[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and
              A.Mask] and $FFFFFF;
            var Alpha := D.TA0;
            if D.AEM and (Raw = 0) then
              Alpha := 0;
            P^ := Raw or (Cardinal(Alpha) shl 24);
            Inc(P);
          end;
        PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := ExpandTexA(Halves[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and
              A.Mask], D.TA0, D.TA1, D.AEM);
            Inc(P);
          end;
        PSMT8:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := Pal[Bytes[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask]];
            Inc(P);
          end;
        PSMT4:
          for var X := X0 to X0 + W - 1 do
          begin
            var Ad := (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask;
            P^ := Pal[(Bytes[Ad shr 1] shr ((Ad and 1) * 4)) and $F];
            Inc(P);
          end;
        PSMT8H:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := Pal[Words[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and
              A.Mask] shr 24];
            Inc(P);
          end;
        PSMT4HL:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := Pal[(Words[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and
              A.Mask] shr 24) and $F];
            Inc(P);
          end;
        PSMT4HH:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ := Pal[Words[(RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and
              A.Mask] shr 28];
            Inc(P);
          end;
      else
        for var X := X0 to X0 + W - 1 do
        begin
          // (Any other format: ReadAt's word as an index.)
          var Index := Integer(FMemory.ReadAt(PSM, (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift +
            Offsets[Cardinal(X) and A.WMask]) and A.Mask)) + D.ClutOffset;
          if D.Clut32 then
          begin
            Index := Index and 255;
            P^ := Cardinal(FClut[Index]) or (Cardinal(FClut[Index + 256]) shl 16);
          end
          else
            P^ := ExpandTexA(FClut[Index and 511], D.TA0, D.TA1, D.AEM);
          Inc(P);
        end;
      end;
    end;
    UploadLevel(T, L, W, H);
  end;
end;

procedure TPS2GSVulkanHLE.WatchTexture(T: TVulkanHLETexture; Request: Pointer);
begin
  GatherTexture(PPS2HLETexRequest(Request));
  for var I := 0 to FTexByteCount - 1 do
    if (FTexBytes[I].Data <> @FClutCopy[0]) then
      WatchMemory(Cardinal(PByte(FTexBytes[I].Data) - FMemory.Data), FTexBytes[I].Size);
end;

{ Drawing }

function TPS2GSVulkanHLE.SameState(const D: TPS2GSDraw): Boolean;
begin
  Result := CompareMem(@D, @FLast, SizeOf(TPS2GSDraw));
  if Result and D.TME and IsPalettized(D.TPSM) then
    Result := CompareMem(FClut, @FLastClut[0], SizeOf(TPS2GSClut));
end;

// A side's blend weight (TPS2HLEPush.Blend): C times c plus One (C -1..1,
// One 0..1); a negative weight is the operation's.
function WeightCode(C, One: Integer): Cardinal;
begin
  if C = 0 then
    Result := Cardinal(One)
  else if One = 0 then
    Result := 2
  else if C < 0 then
    Result := 3
  else
    Result := 4;
end;

// The fixed function's factor for a weight with c the destination alpha.
function AdFactor(Code: Cardinal): Integer;
begin
  case Code of
    0: Result := VK_BLEND_FACTOR_ZERO;
    2: Result := VK_BLEND_FACTOR_DST_ALPHA;
    3: Result := VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
  else
    Result := VK_BLEND_FACTOR_ONE;
  end;
end;

procedure TPS2GSVulkanHLE.SetupState(const D: TPS2GSDraw);
type
  TPassKind = record
    WriteMask: Cardinal;
    WritesZ: Boolean;
    Mode: Cardinal;
  end;
var
  Push: TPS2HLEPush;
  Mine: TPS2GSPages;
  Kinds: array[0..1] of TPassKind;
begin
  var Watch := TStopwatch.StartNew;
  Inc(FSetups);
  FlushDraw;
  FStateValid := False;
  FPassCount := 0;
  FZScale := DepthRange(D.ZPSM);
  var DepthTest := D.ZTST >= 2;
  // (An alpha test no pixel passes writes depth only with AFAIL ZB_ONLY.)
  FDepthWrites := not D.ZMSK and not (D.ATE and (D.ATST = 0) and (D.AFAIL <> 2));
  FDepthUsed := DepthTest or FDepthWrites;
  var T := TargetFor(D);
  FPageRows := PageRowsOf(T.Format);
  FZPageRows := PageRowsOf(D.ZPSM);
  // Other targets newer than GS memory where this one draws go back first.
  FillChar(Mine, SizeOf(Mine), 0);
  AddRange(Mine, T.Addr, T.Bytes);
  if FDepthUsed then
    AddRange(Mine, (D.ZBP shl 8) and MemMask, Cardinal(RoundRows(T.Height, FZPageRows)) * T.Stride *
      PixelBytesOf(D.ZPSM));
  FlushOthers(T, Mine);
  var Tex := FBlank;
  var Source: TPS2HLETarget := nil;
  var OffX := 0;
  var OffY := 0;
  FPartW := 0;
  if D.TME then
  begin
    Source := TargetTexture(D, OffX, OffY);
    if Source = nil then
      Tex := EnsureTexture(D, FSetupV, FSetupCount)
    else if Source <> T then
      Tex := TargetAsTexture(Source);
  end;
  EnsureTarget(T);
  if FDepthUsed then
    EnsureDepth(T, D);
  FFeedback := Source = T;
  if FFeedback then
  begin
    Tex := CopyOf(T);
    FCopyOffX := OffX;
    FCopyOffY := OffY;
  end;
  FTexSet := TextureSet(Tex, 0);
  // From the first primitive on the target is newer than GS memory: the rows
  // drawn are held (Emit), the rest watched.
  BeginDrawing(T);
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
    // Only tested: the depth image stays valid until GS memory there is written.
    WatchDepth(T);
    T.ZWatched := FRun;
  end;

  var Is16T := Is16(T.Format);
  var Is24T := Is24(T.Format);
  Push := Default(TPS2HLEPush);
  Push.NdcX := 2 / T.Width;
  Push.NdcY := 2 / T.Height;
  var Flags: Cardinal := 0;
  if D.TME then
  begin
    Flags := Flags or FLAG_TEXTURED;
    var MXL := 0;
    var TargetFormat: Cardinal := 0;
    if Source <> nil then
    begin
      Flags := Flags or FLAG_TARGET;
      case D.TPSM of
        PSMCT24:
          TargetFormat := 1;
        PSMCT16, PSMCT16S:
          TargetFormat := 2;
      end;
      Push.TexOffset := Cardinal(OffX) or (Cardinal(OffY) shl 16);
    end
    else
    begin
      MXL := Min(D.MXL, Tex.Levels - 1);
      // A part decoded alone: texel (U, V) is at (U - U0, V - V0) in its image.
      if FPartW > 0 then
        Push.TexOffset := Cardinal((-FPartU0) and $FFFF) or (Cardinal((-FPartV0) and $FFFF) shl 16);
    end;
    Push.Tex := Cardinal(D.TFX) or (Cardinal(Ord(D.TCC)) shl 2) or (Cardinal(D.WMS) shl 3) or
      (Cardinal(D.WMT) shl 5) or (Cardinal(Ord(D.Linear)) shl 7) or (Cardinal(D.MMIN) shl 8) or
      (Cardinal(MXL) shl 11) or (Cardinal(Ord(D.LCM)) shl 14) or (Cardinal(D.LShift) shl 15) or
      (Cardinal(Ord(D.UseLod)) shl 17) or (TargetFormat shl 19) or (Cardinal(Ord(D.AEM)) shl 21) or
      (D.TW shl 24) or (D.TH shl 28);
    Push.ClampU := Cardinal(D.MINU) or (Cardinal(D.MAXU) shl 16);
    Push.ClampV := Cardinal(D.MINV) or (Cardinal(D.MAXV) shl 16);
    Push.TexA := Cardinal(D.TA0) or (Cardinal(D.TA1) shl 8);
    Push.LodK := D.K;
  end;
  if D.FGE then
  begin
    Flags := Flags or FLAG_FOG;
    Push.FogColor := Cardinal(D.FogR) or (Cardinal(D.FogG) shl 8) or (Cardinal(D.FogB) shl 16);
  end;
  if D.FBA then
    Flags := Flags or FLAG_FBA;
  if Is16T then
    Flags := Flags or FLAG_ALPHA1;

  // The channels FBMSK leaves written (wholly masked ones not).
  var RB, GB, BB, AB: Cardinal;
  if Is16T then
  begin
    RB := $F8;
    GB := $F800;
    BB := $F80000;
    AB := $80000000;
  end
  else
  begin
    RB := $FF;
    GB := $FF00;
    BB := $FF0000;
    AB := $FF000000;
  end;
  var WM: Cardinal := 0;
  if (D.FBMSK and RB) <> RB then
    WM := WM or VK_COLOR_COMPONENT_R_BIT;
  if (D.FBMSK and GB) <> GB then
    WM := WM or VK_COLOR_COMPONENT_G_BIT;
  if (D.FBMSK and BB) <> BB then
    WM := WM or VK_COLOR_COMPONENT_B_BIT;
  if not Is24T and ((D.FBMSK and AB) <> AB) then
    WM := WM or VK_COLOR_COMPONENT_A_BIT;

  // The blend (A - B) * C + D as weights of the source and the destination:
  // the source's applied in the shader, the destination's as the second
  // source's alpha, or both the fixed function's destination alpha for C = Ad.
  var BlendKey: UInt64 := 0;
  // What the fixed function draws otherwise than the GS (the shader's then).
  var Inexact := D.DATE;
  var Channels: array[0..3] of Cardinal;
  Channels[0] := RB;
  Channels[1] := GB;
  Channels[2] := BB;
  Channels[3] := AB;
  for var I := 0 to 3 - Ord(Is24T) do
    if ((D.FBMSK and Channels[I]) <> 0) and ((D.FBMSK and Channels[I]) <> Channels[I]) then
      Inexact := True;
  if D.ABE then
  begin
    var CSel := D.BlendC;
    var Fix := D.BlendFix;
    // A 24-bit frame's alpha is 0x80.
    if (CSel = 1) and Is24T then
    begin
      CSel := 2;
      Fix := 128;
    end;
    var SC := Ord(D.BlendA = 0) - Ord(D.BlendB = 0);
    var S1 := Ord(D.BlendD = 0);
    var DC := Ord(D.BlendA = 1) - Ord(D.BlendB = 1);
    var D1 := Ord(D.BlendD = 1);
    if not ((SC = 0) and (S1 = 1) and (DC = 0) and (D1 = 0)) then
    begin
      var Op := VK_BLEND_OP_ADD;
      if (SC < 0) and (S1 = 0) then
        Op := VK_BLEND_OP_REVERSE_SUBTRACT
      else if (DC < 0) and (D1 = 0) then
        Op := VK_BLEND_OP_SUBTRACT;
      var SCode := WeightCode(SC, S1);
      var DCode := WeightCode(DC, D1);
      // Destination alpha (Ad / 128), source alpha (may be above 0x80),
      // weights above one, PABE on a reversed subtraction, wrapping colours.
      if ((CSel <> 2) or (SCode = 4) or (DCode = 4) or (Fix > 128) or
        (D.PABE and (Op = VK_BLEND_OP_REVERSE_SUBTRACT)) or not D.ColClamp) then
        Inexact := True;
      var SF, DF: Integer;
      if CSel <> 1 then
      begin
        Push.Blend := SCode or (DCode shl 3) or (Cardinal(CSel) shl 6) or (Cardinal(Fix) shl 8) or (1 shl 17);
        SF := VK_BLEND_FACTOR_ONE;
        case DCode of
          0:
            DF := VK_BLEND_FACTOR_ZERO;
          1:
            DF := VK_BLEND_FACTOR_ONE;
        else
          begin
            DF := VK_BLEND_FACTOR_SRC1_ALPHA;
            Push.Blend := Push.Blend or (1 shl 18);
          end;
        end;
        // PABE: the shader writes source alpha below 0x80 unblended (a
        // destination weight of its own).
        if D.PABE and (Op <> VK_BLEND_OP_REVERSE_SUBTRACT) then
        begin
          if DF = VK_BLEND_FACTOR_ONE then
          begin
            DF := VK_BLEND_FACTOR_SRC1_ALPHA;
            Push.Blend := Push.Blend or (1 shl 18);
          end;
          Push.Blend := Push.Blend or (1 shl 16);
        end;
      end
      else
      begin
        SF := AdFactor(SCode);
        DF := AdFactor(DCode);
      end;
      Flags := Flags or FLAG_BLEND;
      BlendKey := 1 or (UInt64(SF) shl 1) or (UInt64(DF) shl 6) or (UInt64(Op) shl 11);
    end;
  end;
  Push.Flags := Flags;

  // The alpha test's passing pixels write everything; its failing ones what
  // AFAIL keeps (nothing, the frame, the depth, the colour but its alpha).
  var Count := 0;
  var Test := D.ATE and (D.ATST <> 1);
  if not Test or (D.ATST <> 0) then
  begin
    Kinds[0].WriteMask := WM;
    Kinds[0].WritesZ := FDepthWrites;
    Kinds[0].Mode := Ord(Test);
    Count := 1;
  end;
  if Test and (D.AFAIL <> 0) then
  begin
    var B: TPassKind;
    B.WriteMask := WM;
    B.WritesZ := False;
    case D.AFAIL of
      2:
        begin
          B.WriteMask := 0;
          B.WritesZ := FDepthWrites;
        end;
      3:
        B.WriteMask := WM and 7;
    end;
    B.Mode := 2;
    if (B.WriteMask <> 0) or B.WritesZ then
      if (Count = 1) and (Kinds[0].WriteMask = B.WriteMask) and (Kinds[0].WritesZ = B.WritesZ) then
        Kinds[0].Mode := 0
      else
      begin
        if Count = 0 then
          B.Mode := 0;
        Kinds[Count] := B;
        Inc(Count);
      end;
  end;
  var Compare := VK_COMPARE_OP_ALWAYS;
  if DepthTest then
    if D.ZTST = 3 then
      Compare := VK_COMPARE_OP_GREATER
    else
      Compare := VK_COMPARE_OP_GREATER_OR_EQUAL;
  // In the shader where the fixed function is not the GS: one pass, the
  // alpha test's and DATE's pixels left out there (depth is tested before,
  // so such draws may write depth only when they leave out nothing).
  FBlended := FShaderBlend and Inexact and (WM <> 0) and not (FDepthWrites and (Test or D.DATE));
  if FBlended then
  begin
    Count := 0;
    Inc(FBlendSetups);
    var Format: Cardinal := 0;
    if Is24T then
      Format := 1
    else if Is16T then
      Format := 2;
    Push.Flags := Push.Flags and not Cardinal(FLAG_BLEND);
    Push.Pixel := Cardinal(D.BlendA) or (Cardinal(D.BlendB) shl 2) or (Cardinal(D.BlendC) shl 4) or
      (Cardinal(D.BlendD) shl 6) or (Cardinal(D.BlendFix) shl 8) or (Cardinal(Ord(D.ABE)) shl 16) or
      (Cardinal(Ord(D.PABE)) shl 17) or (Cardinal(Ord(D.ColClamp)) shl 18) or (Cardinal(Ord(D.DATE)) shl 19) or
      (Cardinal(Ord(D.DATM)) shl 20) or (Format shl 21) or (Cardinal(D.AFAIL) shl 23) or
      (Cardinal(Ord(Test)) shl 25) or (Cardinal(Ord(D.FBA)) shl 26);
    Push.FbMsk := D.FBMSK;
    Push.AlphaTest := Cardinal(D.AREF) or (Cardinal(D.ATST) shl 8);
    var Key := (UInt64(1) shl 22) or (UInt64(Ord(DepthTest or FDepthWrites)) shl 17) or
      (UInt64(Ord(FDepthWrites)) shl 18) or (UInt64(Compare) shl 19);
    FPasses[0].Pipeline := Pipeline(Key);
    FPasses[0].Layout := FBlendLayout;
    FPasses[0].Push := Push;
    FPassCount := 1;
  end;
  for var I := 0 to Count - 1 do
  begin
    if (Kinds[I].WriteMask = 0) and not Kinds[I].WritesZ then
      Continue;
    var Key := BlendKey or (UInt64(Kinds[I].WriteMask) shl 13) or
      (UInt64(Ord(DepthTest or Kinds[I].WritesZ)) shl 17) or (UInt64(Ord(Kinds[I].WritesZ)) shl 18) or
      (UInt64(Compare) shl 19);
    FPasses[FPassCount].Pipeline := Pipeline(Key);
    FPasses[FPassCount].Layout := FLayout;
    FPasses[FPassCount].Push := Push;
    FPasses[FPassCount].Push.AlphaTest := Cardinal(D.AREF) or (Cardinal(D.ATST) shl 8) or (Kinds[I].Mode shl 12);
    Inc(FPassCount);
  end;

  var X1 := Max(D.SX0, 0);
  var Y1 := Max(D.SY0, 0);
  var X2 := Min(D.SX1, T.Width - 1);
  var Y2 := Min(D.SY1, T.Height - 1);
  FScissor.offset.x := X1;
  FScissor.offset.y := Y1;
  FScissor.extent.width := Cardinal(Max(X2 - X1 + 1, 0));
  FScissor.extent.height := Cardinal(Max(Y2 - Y1 + 1, 0));
  FTarget := T;
  // The passes are new: bound again before the next draw.
  FBoundPass := -1;
  ApplyBindings;
  FLast := D;
  if D.TME and IsPalettized(D.TPSM) then
    Move(FClut^, FLastClut[0], SizeOf(FLastClut));
  FStateValid := True;
  FStats.SetupSeconds := FStats.SetupSeconds + Watch.Elapsed.TotalSeconds;
end;

// What SetupState chose, bound where it is not yet (the command buffer or its
// render pass may be new since).
procedure TPS2GSVulkanHLE.ApplyBindings;
begin
  var T := TPS2HLETarget(FTarget);
  if FBlended then
    BeginPass(T, FBlendPass, T.BlendFramebuffer)
  else
    BeginPass(T, FRenderPass, T.Framebuffer);
  var Cmd := Slot.Cmd.Handle;
  // (Set 0 and the push constants are alike in both layouts.)
  if FTexSet <> FBoundSet then
  begin
    FAPI.vkCmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FLayout, 0, 1, @FTexSet, 0, nil);
    FBoundSet := FTexSet;
  end;
  if FBlended and (T.BlendSet <> FBoundTargetSet) then
  begin
    FAPI.vkCmdBindDescriptorSets(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FBlendLayout, 1, 1, @T.BlendSet, 0, nil);
    FBoundTargetSet := T.BlendSet;
  end;
  if not FScissorValid or not CompareMem(@FScissor, @FBoundScissor, SizeOf(VkRect2D)) then
  begin
    FAPI.vkCmdSetScissor(Cmd, 0, 1, @FScissor);
    FBoundScissor := FScissor;
    FScissorValid := True;
  end;
end;

// The batch, once for each pass (the passing pixels of all its primitives,
// then the failing ones: the order the GS has within a primitive only).
procedure TPS2GSVulkanHLE.FlushDraw;
begin
  if FDrawCount = 0 then
    Exit;
  var Cmd := Slot.Cmd.Handle;
  for var P := 0 to FPassCount - 1 do
  begin
    BindPass(P);
    FAPI.vkCmdDraw(Cmd, FDrawCount, 1, FDrawFirst, 0);
    Inc(FStats.Draws);
  end;
  FDrawCount := 0;
end;

procedure TPS2GSVulkanHLE.BindPass(Index: Integer);
begin
  if FBoundPass = Index then
    Exit;
  var Cmd := Slot.Cmd.Handle;
  if FPasses[Index].Pipeline <> FBoundPipeline then
  begin
    FAPI.vkCmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FPasses[Index].Pipeline);
    FBoundPipeline := FPasses[Index].Pipeline;
  end;
  FAPI.vkCmdPushConstants(Cmd, FPasses[Index].Layout, VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT, 0,
    SizeOf(TPS2HLEPush), @FPasses[Index].Push);
  FBoundPass := Index;
end;

// Count vertices of D drawing pixels X1..X2, Y1..Y2 (inside the scissor).
procedure TPS2GSVulkanHLE.Emit(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer; X1, Y1, X2, Y2: Integer);
begin
  if (X1 > X2) or (Y1 > Y2) then
    Exit;
  ReserveVertices(Count);
  var T := TPS2HLETarget(FTarget);
  FSetupV := V;
  FSetupCount := Count;
  // The state's texture is a part: set up again when this primitive reads
  // beyond it, with the part grown once to take in both (a neighbouring
  // strip), then with the whole texture (one state's primitives reading an
  // atlas in turn). (The state is compared once: nothing here changes it.)
  var Same := FStateValid and SameState(D);
  if not Same then
  begin
    FGrow := False;
    FWhole := False;
  end;
  if Same and (FPartW > 0) then
  begin
    var BU0, BV0, BU1, BV1: Integer;
    if not TexelBox(D, V, Count, BU0, BV0, BU1, BV1) or (BU0 < FPartU0) or (BV0 < FPartV0) or
      (BU1 >= FPartU0 + FPartW) or (BV1 >= FPartV0 + FPartH) then
    begin
      FStateValid := False;
      FWhole := FGrow;
      FGrow := not FWhole;
      FGrowU0 := FPartU0;
      FGrowV0 := FPartV0;
      FGrowU1 := FPartU0 + FPartW - 1;
      FGrowV1 := FPartV0 + FPartH - 1;
    end;
  end;
  if not FStateValid or not Same or ((Y2 >= T.Height) and (T.Height < T.MaxHeight)) then
  begin
    FNeedY := Y2;
    SetupState(D);
    T := TPS2HLETarget(FTarget);
  end
  else if FPass <> T then
    ApplyBindings;
  if FPassCount = 0 then
    Exit;
  X2 := Min(X2, T.Width - 1);
  Y2 := Min(Y2, T.Height - 1);
  if (X1 > X2) or (Y1 > Y2) then
    Exit;
  // Held a page row at a time (the base's byte ranges are then pages).
  var HY1 := Y1 - Y1 mod FPageRows;
  var HY2 := RoundRows(Y2 + 1, FPageRows) - 1;
  var ZY1 := Y1 - Y1 mod FZPageRows;
  var ZY2 := RoundRows(Y2 + 1, FZPageRows) - 1;
  // GS memory changed outside the rows drawn so far: the image there is
  // brought back to it before drawing there.
  if (T.Stale and ((HY1 < T.HeldY1) or (HY2 > T.HeldY2))) or (T.ZStale and FDepthUsed and
    ((ZY1 < T.ZHeldY1) or (ZY2 > T.ZHeldY2))) then
  begin
    Flush(frStale);
    FNeedY := Y2;
    SetupState(D);
    T := TPS2HLETarget(FTarget);
    if FPassCount = 0 then
      Exit;
  end;
  HoldNewRows(T, HY1, HY2);
  if FDepthWrites then
    HoldNewDepthRows(T, ZY1, ZY2);
  if FFeedback then
  begin
    RefreshCopy(V, Count);
    FCopyX1 := Min(FCopyX1, X1);
    FCopyY1 := Min(FCopyY1, Y1);
    FCopyX2 := Max(FCopyX2, X2);
    FCopyY2 := Max(FCopyY2, Y2);
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

function PackColor(const V: TPS2GSVertex): Cardinal; inline;
begin
  Result := Cardinal(EnsureRange(V.R, 0, 255)) or (Cardinal(EnsureRange(V.G, 0, 255)) shl 8) or
    (Cardinal(EnsureRange(V.B, 0, 255)) shl 16) or (Cardinal(EnsureRange(V.A, 0, 255)) shl 24);
end;

function TPS2GSVulkanHLE.Sprite(const D: TPS2GSDraw; const V0, V1: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := True;
  if (D.ZTST = 0) or (X0 >= X1) or (Y0 >= Y1) then
    Exit;
  if D.FBW = 0 then
    Exit(False);
  // Texture coordinates at the corners (1/16 texels), along x and along y.
  var UA, UB, TA, TB: Double;
  if D.FST then
  begin
    UA := V0.U;
    UB := V1.U;
    TA := V0.V;
    TB := V1.V;
  end
  else
  begin
    var Q0 := V0.Q;
    var Q1 := V1.Q;
    if Q0 = 0 then
      Q0 := 1;
    if Q1 = 0 then
      Q1 := 1;
    UA := V0.S / Q0 * (1 shl D.TW) * 16;
    UB := V1.S / Q1 * (1 shl D.TW) * 16;
    TA := V0.T / Q0 * (1 shl D.TH) * 16;
    TB := V1.T / Q1 * (1 shl D.TH) * 16;
  end;
  FZScale := DepthRange(D.ZPSM);
  var C: TPS2HLEVertex;
  C.Z := DepthOf(D, V1.Z);
  C.Color := PackColor(V1);
  C.Q := 1;
  C.LodQ := 1;
  if not D.FST then
    C.LodQ := V1.Q;
  C.Fog := V1.F;
  var Corners: array[0..3] of TPS2HLEVertex;
  for var I := 0 to 3 do
  begin
    Corners[I] := C;
    if (I and 1) = 0 then
    begin
      Corners[I].X := V0.X / 16 + 0.5;
      Corners[I].S := UA;
    end
    else
    begin
      Corners[I].X := V1.X / 16 + 0.5;
      Corners[I].S := UB;
    end;
    if (I and 2) = 0 then
    begin
      Corners[I].Y := V0.Y / 16 + 0.5;
      Corners[I].T := TA;
    end
    else
    begin
      Corners[I].Y := V1.Y / 16 + 0.5;
      Corners[I].T := TB;
    end;
  end;
  FVertices[0] := Corners[0];
  FVertices[1] := Corners[1];
  FVertices[2] := Corners[2];
  FVertices[3] := Corners[1];
  FVertices[4] := Corners[3];
  FVertices[5] := Corners[2];
  Emit(D, @FVertices[0], 6, X0, Y0, X1 - 1, Y1 - 1);
end;

function TPS2GSVulkanHLE.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;

  procedure Put(var P: TPS2HLEVertex; const V, Colored: TPS2GSVertex);
  begin
    P.X := V.X / 16 + 0.5;
    P.Y := V.Y / 16 + 0.5;
    P.Z := DepthOf(D, V.Z);
    P.Color := PackColor(Colored);
    if D.FST then
    begin
      P.S := V.U;
      P.T := V.V;
      P.Q := 1;
      P.LodQ := 1;
    end
    else
    begin
      P.S := V.S * ((1 shl D.TW) * 16);
      P.T := V.T * ((1 shl D.TH) * 16);
      P.Q := V.Q;
      P.LodQ := V.Q;
    end;
    P.Fog := V.F;
  end;

begin
  Result := True;
  if (D.ZTST = 0) or (X0 >= X1) or (Y0 >= Y1) then
    Exit;
  if D.FBW = 0 then
    Exit(False);
  FZScale := DepthRange(D.ZPSM);
  // Flat shading takes the last vertex's colour.
  if D.IIP then
  begin
    Put(FVertices[0], V0, V0);
    Put(FVertices[1], V1, V1);
  end
  else
  begin
    Put(FVertices[0], V0, V2);
    Put(FVertices[1], V1, V2);
  end;
  Put(FVertices[2], V2, V2);
  Emit(D, @FVertices[0], 3, X0, Y0, X1 - 1, Y1 - 1);
end;

// A point as the pixel it rounds to; a line as a band one pixel across its
// minor axis, from the pixel its first end rounds to to the one its last
// does (TPS2GSDrawer.DrawLine's pixels, about).
function TPS2GSVulkanHLE.PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive;
  const V0, V1: TPS2GSVertex): Boolean;
var
  E: array[0..1] of TPS2HLEVertex;

  procedure Put(var P: TPS2HLEVertex; const V, Colored: TPS2GSVertex);
  begin
    P.Z := DepthOf(D, V.Z);
    P.Color := PackColor(Colored);
    if D.FST then
    begin
      P.S := V.U;
      P.T := V.V;
      P.Q := 1;
      P.LodQ := 1;
    end
    else
    begin
      P.S := V.S * ((1 shl D.TW) * 16);
      P.T := V.T * ((1 shl D.TH) * 16);
      P.Q := V.Q;
      if P.Q = 0 then
        P.Q := 1;
      P.LodQ := V1.Q;
    end;
    P.Fog := V.F;
  end;

begin
  Result := True;
  if D.ZTST = 0 then
    Exit;
  if D.FBW = 0 then
    Exit(False);
  FZScale := DepthRange(D.ZPSM);
  if Kind = gpPoint then
  begin
    var PX := (V0.X + 8) div 16;
    var PY := (V0.Y + 8) div 16;
    if (PX < D.SX0) or (PX > D.SX1) or (PY < D.SY0) or (PY > D.SY1) then
      Exit;
    Put(E[0], V0, V0);
    for var I := 0 to 3 do
    begin
      FVertices[I] := E[0];
      FVertices[I].X := PX + (I and 1);
      FVertices[I].Y := PY + (I shr 1);
    end;
    FVertices[4] := FVertices[3];
    FVertices[3] := FVertices[1];
    FVertices[5] := FVertices[2];
    Emit(D, @FVertices[0], 6, PX, PY, PX, PY);
    Exit;
  end;
  if (V0.X = V1.X) and (V0.Y = V1.Y) then
    Exit;
  // Flat shading takes the last vertex's colour.
  if D.IIP then
    Put(E[0], V0, V0)
  else
    Put(E[0], V0, V1);
  Put(E[1], V1, V1);
  var XMajor := Abs(V1.X - V0.X) >= Abs(V1.Y - V0.Y);
  var Lo := 0;
  if (XMajor and (V1.X < V0.X)) or (not XMajor and (V1.Y < V0.Y)) then
    Lo := 1;
  var VL := V0;
  var VH := V1;
  if Lo = 1 then
  begin
    VL := V1;
    VH := V0;
  end;
  // Corners: the low end's two, then the high end's (the high end a pixel on
  // along the major axis), each a pixel apart across it.
  for var I := 0 to 3 do
  begin
    var High := I >= 2;
    var V := VL;
    var K := Lo;
    if High then
    begin
      V := VH;
      K := 1 - Lo;
    end;
    var C := E[K];
    C.X := V.X / 16;
    C.Y := V.Y / 16;
    if XMajor then
    begin
      if High then
        C.X := C.X + 1;
      C.Y := C.Y + (I and 1);
    end
    else
    begin
      if High then
        C.Y := C.Y + 1;
      C.X := C.X + (I and 1);
    end;
    FVertices[I] := C;
  end;
  FVertices[4] := FVertices[3];
  FVertices[3] := FVertices[1];
  FVertices[5] := FVertices[2];
  var X1 := Max((Min(V0.X, V1.X) + 8) div 16, D.SX0);
  var Y1 := Max((Min(V0.Y, V1.Y) + 8) div 16, D.SY0);
  var X2 := Min((Max(V0.X, V1.X) + 8) div 16, D.SX1);
  var Y2 := Min((Max(V0.Y, V1.Y) + 8) div 16, D.SY1);
  Emit(D, @FVertices[0], 6, X1, Y1, X2, Y2);
end;

// (The display reads GS memory: frames are not read from the images.)
procedure TPS2GSVulkanHLE.RecordFrame(T: TVulkanHLETarget; W, H: Integer);
var
  Region: VkBufferImageCopy;
begin
  Region := Default(VkBufferImageCopy);
  Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.imageSubresource.layerCount := 1;
  Region.imageExtent.width := Min(W, T.Width);
  Region.imageExtent.height := Min(H, T.Height);
  Region.imageExtent.depth := 1;
  FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Region);
end;

function TPS2GSVulkanHLE.Describe: string;
begin
  Result := Format('hle prims=%d draws=%d submits=%d flushes=%d partial=%d loads=%d zloads=%d readbacks=%d ' +
    'textures=%d hits=%d targettex=%d copies=%d pipelines=%d watchfaults=%d setup=%.0fms wait=%.0fms flush=%.0fms ' +
    'shaderblend=%d/%d parts=%d', [FStats.Prims, FStats.Draws, FStats.Submits, FStats.Flushes, FPartialStores, FStats.TargetLoads, FDepthLoads,
    FStats.Readbacks, FStats.TextureUploads, FStats.TextureHits, FTargetTextures, FCopies, FStats.Pipelines,
    FStats.WatchFaults, FStats.SetupSeconds * 1000, FStats.WaitSeconds * 1000, FStats.FlushSeconds * 1000, FBlendSetups,
    Ord(FShaderBlend), FPartials]) +
    Format(' setups=%d flush: others=%d texture=%d depth=%d stale=%d sync=%d', [FSetups, FFlushes[frOthers],
    FFlushes[frTexture], FFlushes[frDepth], FFlushes[frStale], FFlushes[frSync]]);
  for var T in FTargets do
  begin
    Result := Result + Format(' [%x %x %dx%d', [T.Addr, T.Format, T.Width, T.Height]);
    if TPS2HLETarget(T).ZLoaded then
      Result := Result + Format(' z %x %x', [TPS2HLETarget(T).ZAddr, TPS2HLETarget(T).ZPSM]);
    Result := Result + ']';
  end;
end;

end.
