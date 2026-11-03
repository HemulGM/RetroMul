unit RM.Vulkan.HLE;

// The common part of the Vulkan HLE renderers: a console's GPU drawn with
// Vulkan graphics pipelines in the host GPU's own arithmetic (fast, not bit
// exact), at the console's resolution or a multiple of it (Scale). A console
// derives its renderer from TVulkanHLERenderer.
//
// The contract:
// - Device. The renderer owns a TVulkanCompute with a graphics queue (and
//   frees it). Commands are recorded in a ring of two slots, each with its
//   command buffer, a vertex buffer and a staging buffer for uploads;
//   Submit starts a slot on the GPU and moves to the other, WaitAll waits for
//   both. Every image stays in the general layout; ImageBarrier makes
//   everything recorded before visible to everything after.
// - Targets. A target (TVulkanHLETarget) stands for a surface in the
//   console's memory, keyed by address, format and stride: a colour image
//   (RGBA8) and a depth/stencil image (32-bit float or 24-bit depth, 8-bit
//   stencil), both Scale times the surface's size. FindTarget finds or makes
//   one (growing it, dropping the least recently used). The subclass loads a
//   surface into its images (LoadTarget) and stores them back (StoreTarget)
//   in the console's formats.
// - Coherence. Console memory is the reference whenever the console itself
//   looks at it. A target is either equal to memory (Loaded; Shadow holds
//   the bytes it was loaded from and is compared before each use) or newer
//   (Dirty: drawn since). The rows drawn of a Dirty target are held
//   (HoldMemory): the console's memory calls the subclass back on any access
//   there, and the subclass calls FlushAll, which stores every newer target,
//   releases all holds and watches and starts a new run. The rest of a Dirty
//   target's bytes is watched (WatchMemory): a write there makes the target
//   Stale outside the rows drawn (the subclass decides, it knows where the
//   write went), and the subclass flushes before it draws there. Textures
//   are compared with their bytes once a run (Verified) and watched from then
//   on. The base flushes by itself only when a target grows, when a target
//   to load is held by another and when it is destroyed. Sync is a FlushAll:
//   the subclass calls it when the console needs its memory complete without
//   going through the holds (a saved state); Release when the console's GPU
//   stops for now.
// - Textures. TVulkanHLETexture holds a texture decoded to RGBA8, its levels
//   as mip levels, keyed by the subclass (CachedTexture); the bytes it came
//   from are kept (KeepSource) to be compared later (SameSource). With texture
//   scaling (TextureScale above 1 and Scale above 1) a texture's image is
//   ScaleTexture's larger copy and Scale says how much larger.
// - Pipelines. Cached by a 64-bit key the subclass gives meaning to; it makes
//   them (PipelineFor) with FRenderPass (one RGBA8 colour attachment, one
//   depth/stencil attachment) and FLayout (set 0: one combined image sampler
//   for the fragment shader; push constants for both stages of PushSize).
// - Batches. Vertices (of VertexSize bytes) go into the slot's vertex buffer
//   (AddVertices) and draw as one vkCmdDraw until FlushDraw: the subclass
//   flushes before it changes what is bound. BeginPass starts a render pass
//   on a target; EndPass ends it (both flush).
// - Frames. ReadFrame copies a target's image (RecordFrame, the subclass's
//   conversion) into an emulator frame at the scale.
//
// The renderer runs on the emulation thread; nothing in it is thread safe.

interface

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Generics.Collections,
  System.Generics.Defaults, System.UITypes, Core.Emulation.Types,
  RM.Vulkan.Bindings, RM.Vulkan.Loader, RM.Vulkan.Compute, RM.Vulkan.TexScale;

const
  // Vertices a slot's buffer holds.
  HLEVertexCapacity = 1 shl 18;
  // Bytes of a slot's staging buffer.
  HLEUploadCapacity = 16 shl 20;
  // Targets kept at most (FindTarget drops one past them).
  HLEMaxTargets = 32;

type
  TVulkanHLEStats = record
    Draws, Prims, Submits, Flushes, TargetLoads, Readbacks: Int64;
    TextureUploads, TextureHits, TargetTextures, Pipelines, Presents, WatchFaults: Int64;
    // Uploads scaled (texture scaling), and the time scaling them.
    TextureScales: Int64;
    ScaleSeconds: Double;
    // In flushes: waiting for the GPU, and everything (waiting and storing).
    WaitSeconds, FlushSeconds: Double;
    // Setting up state for primitives (the subclass's), showing frames.
    SetupSeconds, PresentSeconds: Double;
  end;

  TVulkanHLEImage = record
    Image: VkImage;
    Memory: VkDeviceMemory;
    View: VkImageView;
  end;

  TVulkanHLETexture = class;

  // A surface of the console's memory drawn on the GPU.
  TVulkanHLETarget = class
  public
    // Where it is in the subclass's address space, its format (the
    // subclass's numbering), its stride in pixels and the bytes of a pixel.
    Addr, Format, Stride, PixelBytes: Cardinal;
    // Width is the stride's; the height grows up to MaxHeight as drawing needs it.
    Width, Height, MaxHeight: Integer;
    Color, Depth: TVulkanHLEImage;
    Framebuffer: VkFramebuffer;
    // The colour image as a texture, made when one is drawn from it.
    AsTexture: TVulkanHLETexture;
    LastUse: Int64;
    // Console memory's bytes when the image was last made equal to it.
    Shadow: TBytes;
    Loaded: Boolean;
    // Newer than console memory, with the box drawn. Only the pages of the
    // rows drawn (HeldY1..HeldY2) are held, the rest of the target's are
    // watched: a write there makes the image Stale outside those rows.
    Dirty: Boolean;
    X1, Y1, X2, Y2: Integer;
    HeldY1, HeldY2: Integer;
    Stale: Boolean;
    // Changes whenever the colour image may change (made, loaded, drawn):
    // unique among the renderer's targets.
    Version: Int64;
    function Bytes: Cardinal;
  end;

  // A texture decoded to RGBA8, its levels as mip levels 0..Levels - 1.
  TVulkanHLETexture = class
  public
    Key: UInt64;
    Levels: Integer;
    // Level 0's size in the console's texels.
    Width, Height: Integer;
    // The image's texels per the console's along a side: 1, or the texture
    // scaling option's (ScaleTexture).
    Scale: Integer;
    // The bytes it was decoded from (KeepSource). Without them all in host
    // memory it cannot be compared and is decoded again in every run.
    Source: TBytes;
    Checkable: Boolean;
    // The run it was last compared or decoded in.
    Verified: Int64;
    // A scaled texture's bytes changing in close succession (in frames shown,
    // the last at ChangedAt): it is made again unscaled.
    Changes: Integer;
    ChangedAt: Int64;
    // A target's colour image used as the texture (not this object's).
    Target: TVulkanHLETarget;
    Image: TVulkanHLEImage;
    Sets: TDictionary<Cardinal, VkDescriptorSet>;
    LastUse: Int64;
    constructor Create;
    destructor Destroy; override;
  end;

  // Bytes of the console's memory in host memory, nil where it has none.
  TVulkanHLEBytes = record
    Data: Pointer;
    Size: Integer;
  end;

  TVulkanHLESlot = record
    Cmd: TVulkanCommands;
    Vertices: TVulkanBuffer;
    VertexCount: Integer;
    Upload: TVulkanBuffer;
    UploadUsed: Int64;
  end;
  PVulkanHLESlot = ^TVulkanHLESlot;

  TVulkanHLERenderer = class
  private
    FVertexSize: Integer;
    FPool: VkDescriptorPool;
    FPipelines: TDictionary<UInt64, VkPipeline>;
    FSamplers: TDictionary<Cardinal, VkSampler>;
    FTextures: TObjectDictionary<UInt64, TVulkanHLETexture>;
    // Textures replaced while the GPU may still read them: destroyed once it
    // has finished (DestroyRetired).
    FRetired: TList<TVulkanHLETexture>;
    FTextureScale: Integer;
    FTextureFilter: TTexScaleFilter;
    // The texels of a level being scaled, and the larger ones.
    FScaleIn, FScaleOut: TArray<Cardinal>;
    FLevelOffset: Int64;
    FSlots: array[0..1] of TVulkanHLESlot;
    FSlot: Integer;
    FSetCount: Integer;
    FDrawFirst, FDrawCount: Integer;
    FPassRenderPass: VkRenderPass;
    // The shown frames' pixels (ReadFrame), reused once their reader let go.
    FFrames: array[0..2] of TArray<TAlphaColor>;
    // The last frame read, and the target and version it was read from.
    FFrameTarget: TVulkanHLETarget;
    FFrameVersion: Int64;
    FFrameWidth, FFrameHeight: Integer;
    FFramePixels: TArray<TAlphaColor>;
    FFlushing: Boolean;
    procedure CreateRenderPass;
    procedure CreateLayout(PushSize: Integer);
    procedure SetTextureScale(Value: Integer);
    function AddTexture(Key: UInt64; Width, Height, Levels, Scale: Integer; Request: Pointer): TVulkanHLETexture;
    procedure Decode(T: TVulkanHLETexture; Request: Pointer);
    function Changing(T: TVulkanHLETexture): Boolean;
  protected
    FCompute: TVulkanCompute;
    FAPI: TVulkanAPI;
    FDevice: VkDevice;
    FScale: Integer;
    // D32_SFLOAT_S8_UINT where the device has it, else D24_UNORM_S8_UINT (FD24).
    FDepthFormat: VkFormat;
    FD24: Boolean;
    // Usage of the targets' images; the subclass may add to them before it
    // makes targets.
    FColorUsage, FDepthUsage: Cardinal;
    FRenderPass: VkRenderPass;
    FSetLayout: VkDescriptorSetLayout;
    FLayout: VkPipelineLayout;
    // Host-visible, for storing targets and reading frames; also a storage
    // buffer.
    FReadback: TVulkanBuffer;
    FTargets: TList<TVulkanHLETarget>;
    // The target being drawn into, and the one of the render pass.
    FTarget, FPass: TVulkanHLETarget;
    // Counts runs: what was verified in the current one stands.
    FRun: Int64;
    FUseCounter: Int64;
    // The last target version given out.
    FVersion: Int64;
    // What is bound in the command buffer (0: nothing yet).
    FBoundPipeline: VkPipeline;
    FBoundSet: VkDescriptorSet;
    // The texture of untextured draws: one opaque white texel.
    FBlank: TVulkanHLETexture;
    FStats: TVulkanHLEStats;

    // Images.
    function CreateImage(Format: VkFormat; Width, Height, Levels: Integer; Usage, Aspect: Cardinal): TVulkanHLEImage;
    procedure DestroyImage(var Image: TVulkanHLEImage);
    function CreateView(Image: VkImage; Format: VkFormat; Aspect: Cardinal): VkImageView;

    // Commands.
    function Slot: PVulkanHLESlot;
    // Starts recording in the current slot unless it records already (waits
    // for its previous submission: its buffers are free again).
    procedure Record_;
    // The command buffer or the render pass is new: nothing the subclass
    // bound is bound any more.
    procedure Unbound; virtual;
    procedure ImageBarrier;
    // Transfer and shader writes before are visible to the host after.
    procedure HostReadBarrier;
    procedure Submit;
    procedure WaitAll;
    // Room for Bytes in the slot's staging buffer (submitting it when full).
    function StageUpload(Bytes: Int64; out Offset: Int64): PByte;
    procedure CopyToImage(Image: VkImage; Aspect: Cardinal; Offset: Int64; Level, X, Y, W, H: Integer);

    // Batches.
    procedure BeginPass(T: TVulkanHLETarget; Pass: VkRenderPass; Framebuffer: VkFramebuffer);
    procedure EndPass;
    procedure FlushDraw;
    // Room for Count more vertices in the slot (submitting it when full).
    procedure ReserveVertices(Count: Integer);
    // Count vertices after the draw being built.
    procedure AddVertices(V: Pointer; Count: Integer);

    // Pipelines and descriptors.
    function Pipeline(Key: UInt64): VkPipeline;
    function PipelineFor(Key: UInt64): VkPipeline; virtual; abstract;
    // Key bits: 0 clamp U, 1 clamp V, 2 linear magnification, 3 linear
    // minification, 4 mipmaps, 5 linear between levels, 8-11 the highest level.
    function Sampler(Key: Cardinal): VkSampler;
    function TextureSet(T: TVulkanHLETexture; SamplerKey: Cardinal): VkDescriptorSet;
    procedure FreeSets(T: TVulkanHLETexture);
    // Device objects freed after the targets and textures, before the device.
    procedure FreeDevice; virtual;

    // Targets.
    // The target of Stride x NeedHeight pixels at Addr in Format: a new one
    // MinHeight tall at least (twice as tall when it grows), MaxHeight at most.
    function FindTarget(Addr, Format, Stride, PixelBytes: Cardinal;
      NeedHeight, MinHeight, MaxHeight: Integer): TVulkanHLETarget;
    function NewTarget: TVulkanHLETarget; virtual;
    // A new target has its images and framebuffer.
    procedure InitTarget(T: TVulkanHLETarget); virtual;
    procedure DestroyTarget(T: TVulkanHLETarget); virtual;
    // Console memory's surface into the images, each pixel as a block of the
    // scale's size.
    procedure LoadTarget(T: TVulkanHLETarget); virtual; abstract;
    // The images' newer pixels (the box drawn) back into console memory. The
    // renderer clears Dirty and takes the shadow afterwards.
    procedure StoreTarget(T: TVulkanHLETarget); virtual; abstract;
    // The target has pixels console memory does not (FlushAll stores it).
    function TargetNewer(T: TVulkanHLETarget): Boolean; virtual;
    // Equal to console memory (loaded again when it is not).
    procedure EnsureTarget(T: TVulkanHLETarget);
    // T is drawn into from now on: newer than console memory, watched.
    procedure BeginDrawing(T: TVulkanHLETarget);
    // The box drawn grows by X1, Y1 - X2, Y2.
    procedure Drawn(T: TVulkanHLETarget; X1, Y1, X2, Y2: Integer); inline;
    // Rows Y1..Y2 are drawn: the pages of those not yet held are held.
    procedure HoldNewRows(T: TVulkanHLETarget; Y1, Y2: Integer);
    procedure WatchTarget(T: TVulkanHLETarget);
    function ShadowMatches(T: TVulkanHLETarget): Boolean;
    // The target's colour image as a texture of one level.
    function TargetAsTexture(T: TVulkanHLETarget): TVulkanHLETexture;

    // Textures.
    // The texture of Key: verified in this run, or compared again with its
    // bytes (TextureMatches), or decoded (DecodeTexture). Request is the
    // subclass's, handed to those.
    function CachedTexture(Key: UInt64; Request: Pointer): TVulkanHLETexture;
    // A new texture's size, levels and scale (ScaleFor, or 1).
    procedure DescribeTexture(Request: Pointer; out Width, Height, Levels, Scale: Integer); virtual; abstract;
    // The texture's source bytes are still what console memory holds (SameSource).
    function TextureMatches(T: TVulkanHLETexture; Request: Pointer): Boolean; virtual; abstract;
    // The texture's levels decoded and uploaded (KeepSource, LevelTexels,
    // UploadLevel); the renderer watches it afterwards.
    procedure DecodeTexture(T: TVulkanHLETexture; Request: Pointer); virtual; abstract;
    // Writes to the texture's bytes in console memory from now on are seen.
    procedure WatchTexture(T: TVulkanHLETexture; Request: Pointer); virtual; abstract;
    function SameSource(T: TVulkanHLETexture; const Bytes: array of TVulkanHLEBytes): Boolean;
    procedure KeepSource(T: TVulkanHLETexture; const Bytes: array of TVulkanHLEBytes);
    // Where a W x H level's texels go (RGBA8, rows packed), then UploadLevel.
    function LevelTexels(T: TVulkanHLETexture; W, H: Integer): PCardinal;
    procedure UploadLevel(T: TVulkanHLETexture; Level, W, H: Integer);
    // The texture scaling option's factor for a new texture of Width x
    // Height (at most 1024 texels a side); 1 under 8 texels a side (ramps and
    // tables) and without the option.
    function ScaleFor(Width, Height: Integer): Integer;
    procedure DestroyTexture(T: TVulkanHLETexture);
    procedure DestroyRetired;

    // Coherence.
    // Every newer target stored, holds and watches released, a new run.
    procedure FlushAll;
    procedure NewRun; virtual;
    // Console memory, in the subclass's address space (wrapping as the
    // console's does).
    function MemoryEquals(Addr: Cardinal; Data: PByte; Size: Cardinal): Boolean; virtual; abstract;
    procedure ReadMemory(Addr: Cardinal; Data: PByte; Size: Cardinal); virtual; abstract;
    // Any access to the pages of the range calls the subclass first.
    procedure HoldMemory(Addr, Size: Cardinal); virtual; abstract;
    function MemoryHeld(Addr, Size: Cardinal): Boolean; virtual; abstract;
    procedure ReleaseHolds; virtual; abstract;
    // A write to the pages of the range calls the subclass first.
    procedure WatchMemory(Addr, Size: Cardinal); virtual; abstract;
    procedure ReleaseWatches; virtual; abstract;

    // Frames.
    // W x H pixels of the target's colour image as the emulator shows them
    // (TAlphaColor, rows packed), from word 0 of FReadback.
    procedure RecordFrame(T: TVulkanHLETarget; W, H: Integer); virtual; abstract;
    // The target's colour image changes (Drawn and loading do this).
    procedure Changed(T: TVulkanHLETarget); inline;
    procedure ReadFrame(T: TVulkanHLETarget; W, H: Integer; var Frame: TEmulatorFrame);
  public
    // Scale: 1 to 8 times the console's resolution. VertexSize: the bytes of
    // a vertex; PushSize: of the push constants. FrameWidth x FrameHeight:
    // the largest frame shown, at 1x.
    constructor Create(Compute: TVulkanCompute; Scale, VertexSize, PushSize, FrameWidth, FrameHeight: Integer);
    destructor Destroy; override;
    // Console memory holds everything drawn so far.
    procedure Sync;
    // The console's GPU stops for now: what is recorded starts on the GPU
    // when it has finished the previous submission (recording goes on in the
    // other slot without waiting), else it grows until then or until a Sync.
    // The targets stay held.
    procedure Release;
    property Compute: TVulkanCompute read FCompute;
    property Scale: Integer read FScale;
    // Textures made larger by ScaleTexture (2 to TexScaleMax; 0 or 1 none)
    // with the filter when the scale is above 1: an option that is not the
    // console's. Applies to textures uploaded from then on.
    property TextureScale: Integer read FTextureScale write SetTextureScale;
    property TextureFilter: TTexScaleFilter read FTextureFilter write FTextureFilter;
    property Stats: TVulkanHLEStats read FStats;
  end;

implementation

const
  // Release submits no fewer vertices.
  ReleaseVertices = 6144;
  MaxTextures = 1024;
  MaxSets = 8192;

{ TVulkanHLETarget }

function TVulkanHLETarget.Bytes: Cardinal;
begin
  Result := Cardinal(Height) * Stride * PixelBytes;
end;

{ TVulkanHLETexture }

constructor TVulkanHLETexture.Create;
begin
  inherited;
  Scale := 1;
  Sets := TDictionary<Cardinal, VkDescriptorSet>.Create;
end;

destructor TVulkanHLETexture.Destroy;
begin
  Sets.Free;
  inherited;
end;

{ TVulkanHLERenderer }

constructor TVulkanHLERenderer.Create(Compute: TVulkanCompute;
  Scale, VertexSize, PushSize, FrameWidth, FrameHeight: Integer);
var
  Props: VkFormatProperties;
begin
  inherited Create;
  FCompute := Compute;
  FAPI := Compute.API;
  FDevice := Compute.Device;
  FScale := EnsureRange(Scale, 1, 8);
  FVertexSize := VertexSize;
  FPipelines := TDictionary<UInt64, VkPipeline>.Create;
  FSamplers := TDictionary<Cardinal, VkSampler>.Create;
  FTargets := TList<TVulkanHLETarget>.Create;
  FTextures := TObjectDictionary<UInt64, TVulkanHLETexture>.Create([]);
  FRetired := TList<TVulkanHLETexture>.Create;
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_D32_SFLOAT_S8_UINT, @Props);
  if (Props.optimalTilingFeatures and VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) <> 0 then
    FDepthFormat := VK_FORMAT_D32_SFLOAT_S8_UINT
  else
  begin
    FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_D24_UNORM_S8_UINT, @Props);
    if (Props.optimalTilingFeatures and VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT) = 0 then
      raise EVulkanError.Create('No depth/stencil format with 8 stencil bits.');
    FDepthFormat := VK_FORMAT_D24_UNORM_S8_UINT;
    FD24 := True;
  end;
  FColorUsage := VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT or
    VK_IMAGE_USAGE_TRANSFER_DST_BIT or VK_IMAGE_USAGE_SAMPLED_BIT;
  FDepthUsage := VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT or VK_IMAGE_USAGE_TRANSFER_SRC_BIT or
    VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  CreateRenderPass;
  CreateLayout(PushSize);
  for var I := 0 to High(FSlots) do
  begin
    FSlots[I].Cmd := Compute.CreateCommands;
    FSlots[I].Vertices := Compute.CreateBuffer(HLEVertexCapacity * Int64(VertexSize), vbkShared,
      VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    FSlots[I].Upload := Compute.CreateBuffer(HLEUploadCapacity, vbkUpload, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
  end;
  // Also the frames shown at the scale.
  FReadback := Compute.CreateBuffer(Max(HLEUploadCapacity, FrameWidth * FrameHeight * 4 * FScale * FScale), vbkReadback,
    VK_BUFFER_USAGE_TRANSFER_DST_BIT or VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
  FBlank := TVulkanHLETexture.Create;
  FBlank.Width := 1;
  FBlank.Height := 1;
  FBlank.Levels := 1;
  FBlank.Image := CreateImage(VK_FORMAT_R8G8B8A8_UNORM, 1, 1, 1,
    VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
  var Offset: Int64;
  PCardinal(StageUpload(4, Offset))^ := $FFFFFFFF;
  CopyToImage(FBlank.Image.Image, VK_IMAGE_ASPECT_COLOR_BIT, Offset, 0, 0, 0, 1, 1);
end;

destructor TVulkanHLERenderer.Destroy;
begin
  if FCompute <> nil then
  begin
    try
      FlushAll;
    except
    end;
    FCompute.WaitIdle;
    if FTargets <> nil then
      for var T in FTargets do
        DestroyTarget(T);
    FTargets.Free;
    if FTextures <> nil then
      for var T in FTextures.Values do
        DestroyTexture(T);
    FTextures.Free;
    if FRetired <> nil then
      DestroyRetired;
    FRetired.Free;
    if FBlank <> nil then
      DestroyTexture(FBlank);
    if FPipelines <> nil then
      for var P in FPipelines.Values do
        FAPI.vkDestroyPipeline(FDevice, P, nil);
    FPipelines.Free;
    if FSamplers <> nil then
      for var S in FSamplers.Values do
        FAPI.vkDestroySampler(FDevice, S, nil);
    FSamplers.Free;
    FreeDevice;
    FCompute.Free;
  end;
  inherited;
end;

procedure TVulkanHLERenderer.FreeDevice;
begin
  for var I := 0 to High(FSlots) do
  begin
    FSlots[I].Cmd.Free;
    FSlots[I].Vertices.Free;
    FSlots[I].Upload.Free;
  end;
  FReadback.Free;
  if FPool <> 0 then
    FAPI.vkDestroyDescriptorPool(FDevice, FPool, nil);
  if FLayout <> 0 then
    FAPI.vkDestroyPipelineLayout(FDevice, FLayout, nil);
  if FSetLayout <> 0 then
    FAPI.vkDestroyDescriptorSetLayout(FDevice, FSetLayout, nil);
  if FRenderPass <> 0 then
    FAPI.vkDestroyRenderPass(FDevice, FRenderPass, nil);
end;

function TVulkanHLERenderer.CreateImage(Format: VkFormat; Width, Height, Levels: Integer;
  Usage, Aspect: Cardinal): TVulkanHLEImage;
var
  Info: VkImageCreateInfo;
  Req: VkMemoryRequirements;
  Alloc: VkMemoryAllocateInfo;
  View: VkImageViewCreateInfo;
  B: VkImageMemoryBarrier;
begin
  Result := Default(TVulkanHLEImage);
  Info := Default(VkImageCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  Info.imageType := VK_IMAGE_TYPE_2D;
  Info.format := Format;
  Info.extent.width := Width;
  Info.extent.height := Height;
  Info.extent.depth := 1;
  Info.mipLevels := Levels;
  Info.arrayLayers := 1;
  Info.samples := VK_SAMPLE_COUNT_1_BIT;
  Info.tiling := VK_IMAGE_TILING_OPTIMAL;
  Info.usage := Usage;
  Info.sharingMode := VK_SHARING_MODE_EXCLUSIVE;
  Info.initialLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  CheckVulkan(FAPI.vkCreateImage(FDevice, @Info, nil, @Result.Image), 'vkCreateImage');
  FAPI.vkGetImageMemoryRequirements(FDevice, Result.Image, @Req);
  Alloc := Default(VkMemoryAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  Alloc.allocationSize := Req.size;
  var MemoryType := FCompute.FindMemory(Req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, []);
  if MemoryType < 0 then
    MemoryType := FCompute.FindMemory(Req.memoryTypeBits, 0, []);
  Alloc.memoryTypeIndex := MemoryType;
  CheckVulkan(FAPI.vkAllocateMemory(FDevice, @Alloc, nil, @Result.Memory), 'vkAllocateMemory (image)');
  CheckVulkan(FAPI.vkBindImageMemory(FDevice, Result.Image, Result.Memory, 0), 'vkBindImageMemory');
  View := Default(VkImageViewCreateInfo);
  View.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  View.image := Result.Image;
  View.viewType := VK_IMAGE_VIEW_TYPE_2D;
  View.format := Format;
  View.subresourceRange.aspectMask := Aspect;
  View.subresourceRange.levelCount := Levels;
  View.subresourceRange.layerCount := 1;
  CheckVulkan(FAPI.vkCreateImageView(FDevice, @View, nil, @Result.View), 'vkCreateImageView');
  // Every image lives in the general layout.
  Record_;
  EndPass;
  B := Default(VkImageMemoryBarrier);
  B.sType := VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
  B.dstAccessMask := VK_ACCESS_MEMORY_READ_BIT or VK_ACCESS_MEMORY_WRITE_BIT;
  B.oldLayout := VK_IMAGE_LAYOUT_UNDEFINED;
  B.newLayout := VK_IMAGE_LAYOUT_GENERAL;
  B.srcQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  B.dstQueueFamilyIndex := VK_QUEUE_FAMILY_IGNORED;
  B.image := Result.Image;
  B.subresourceRange.aspectMask := Aspect;
  B.subresourceRange.levelCount := Levels;
  B.subresourceRange.layerCount := 1;
  FAPI.vkCmdPipelineBarrier(Slot.Cmd.Handle, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
    0, nil, 0, nil, 1, @B);
end;

procedure TVulkanHLERenderer.DestroyImage(var Image: TVulkanHLEImage);
begin
  if Image.View <> 0 then
    FAPI.vkDestroyImageView(FDevice, Image.View, nil);
  if Image.Image <> 0 then
    FAPI.vkDestroyImage(FDevice, Image.Image, nil);
  if Image.Memory <> 0 then
    FAPI.vkFreeMemory(FDevice, Image.Memory, nil);
  Image := Default(TVulkanHLEImage);
end;

// A view of one level of Image (one aspect of a depth/stencil image).
function TVulkanHLERenderer.CreateView(Image: VkImage; Format: VkFormat; Aspect: Cardinal): VkImageView;
var
  View: VkImageViewCreateInfo;
begin
  View := Default(VkImageViewCreateInfo);
  View.sType := VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  View.image := Image;
  View.viewType := VK_IMAGE_VIEW_TYPE_2D;
  View.format := Format;
  View.subresourceRange.aspectMask := Aspect;
  View.subresourceRange.levelCount := 1;
  View.subresourceRange.layerCount := 1;
  CheckVulkan(FAPI.vkCreateImageView(FDevice, @View, nil, @Result), 'vkCreateImageView');
end;

procedure TVulkanHLERenderer.CreateRenderPass;
var
  Attachments: array[0..1] of VkAttachmentDescription;
  ColorRef, DepthRef: VkAttachmentReference;
  Subpass: VkSubpassDescription;
  Deps: array[0..1] of VkSubpassDependency;
  Info: VkRenderPassCreateInfo;
begin
  Attachments[0] := Default(VkAttachmentDescription);
  Attachments[0].format := VK_FORMAT_R8G8B8A8_UNORM;
  Attachments[0].samples := VK_SAMPLE_COUNT_1_BIT;
  Attachments[0].loadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Attachments[0].storeOp := VK_ATTACHMENT_STORE_OP_STORE;
  Attachments[0].stencilLoadOp := VK_ATTACHMENT_LOAD_OP_DONT_CARE;
  Attachments[0].stencilStoreOp := VK_ATTACHMENT_STORE_OP_DONT_CARE;
  Attachments[0].initialLayout := VK_IMAGE_LAYOUT_GENERAL;
  Attachments[0].finalLayout := VK_IMAGE_LAYOUT_GENERAL;
  Attachments[1] := Attachments[0];
  Attachments[1].format := FDepthFormat;
  Attachments[1].stencilLoadOp := VK_ATTACHMENT_LOAD_OP_LOAD;
  Attachments[1].stencilStoreOp := VK_ATTACHMENT_STORE_OP_STORE;
  ColorRef.attachment := 0;
  ColorRef.layout := VK_IMAGE_LAYOUT_GENERAL;
  DepthRef.attachment := 1;
  DepthRef.layout := VK_IMAGE_LAYOUT_GENERAL;
  Subpass := Default(VkSubpassDescription);
  Subpass.pipelineBindPoint := VK_PIPELINE_BIND_POINT_GRAPHICS;
  Subpass.colorAttachmentCount := 1;
  Subpass.pColorAttachments := @ColorRef;
  Subpass.pDepthStencilAttachment := @DepthRef;
  // Transfers and earlier passes before, transfers after.
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
  Info := Default(VkRenderPassCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
  Info.attachmentCount := 2;
  Info.pAttachments := @Attachments[0];
  Info.subpassCount := 1;
  Info.pSubpasses := @Subpass;
  Info.dependencyCount := 2;
  Info.pDependencies := @Deps[0];
  CheckVulkan(FAPI.vkCreateRenderPass(FDevice, @Info, nil, @FRenderPass), 'vkCreateRenderPass');
end;

procedure TVulkanHLERenderer.CreateLayout(PushSize: Integer);
var
  Binding: VkDescriptorSetLayoutBinding;
  SetInfo: VkDescriptorSetLayoutCreateInfo;
  Push: VkPushConstantRange;
  Info: VkPipelineLayoutCreateInfo;
  PoolSize: VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
begin
  Binding := Default(VkDescriptorSetLayoutBinding);
  Binding.binding := 0;
  Binding.descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  Binding.descriptorCount := 1;
  Binding.stageFlags := VK_SHADER_STAGE_FRAGMENT_BIT;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := 1;
  SetInfo.pBindings := @Binding;
  CheckVulkan(FAPI.vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @FSetLayout), 'vkCreateDescriptorSetLayout');
  Push.stageFlags := VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT;
  Push.offset := 0;
  Push.size := PushSize;
  Info := Default(VkPipelineLayoutCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  Info.setLayoutCount := 1;
  Info.pSetLayouts := @FSetLayout;
  Info.pushConstantRangeCount := 1;
  Info.pPushConstantRanges := @Push;
  CheckVulkan(FAPI.vkCreatePipelineLayout(FDevice, @Info, nil, @FLayout), 'vkCreatePipelineLayout');
  PoolSize.&type := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  PoolSize.descriptorCount := MaxSets;
  PoolInfo := Default(VkDescriptorPoolCreateInfo);
  PoolInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  PoolInfo.flags := VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
  PoolInfo.maxSets := MaxSets;
  PoolInfo.poolSizeCount := 1;
  PoolInfo.pPoolSizes := @PoolSize;
  CheckVulkan(FAPI.vkCreateDescriptorPool(FDevice, @PoolInfo, nil, @FPool), 'vkCreateDescriptorPool');
end;

function TVulkanHLERenderer.Pipeline(Key: UInt64): VkPipeline;
begin
  if FPipelines.TryGetValue(Key, Result) then
    Exit;
  Result := PipelineFor(Key);
  FPipelines.Add(Key, Result);
  Inc(FStats.Pipelines);
end;

function TVulkanHLERenderer.Sampler(Key: Cardinal): VkSampler;
var
  Info: VkSamplerCreateInfo;
begin
  if FSamplers.TryGetValue(Key, Result) then
    Exit;
  Info := Default(VkSamplerCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
  Info.magFilter := (Key shr 2) and 1;
  Info.minFilter := (Key shr 3) and 1;
  Info.mipmapMode := (Key shr 5) and 1;
  if (Key and 1) <> 0 then
    Info.addressModeU := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
  else
    Info.addressModeU := VK_SAMPLER_ADDRESS_MODE_REPEAT;
  if (Key and 2) <> 0 then
    Info.addressModeV := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
  else
    Info.addressModeV := VK_SAMPLER_ADDRESS_MODE_REPEAT;
  Info.addressModeW := VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
  Info.minLod := 0;
  if (Key and 16) <> 0 then
    Info.maxLod := (Key shr 8) and 15
  else
    Info.maxLod := 0;
  Info.borderColor := VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK;
  CheckVulkan(FAPI.vkCreateSampler(FDevice, @Info, nil, @Result), 'vkCreateSampler');
  FSamplers.Add(Key, Result);
end;

function TVulkanHLERenderer.TextureSet(T: TVulkanHLETexture; SamplerKey: Cardinal): VkDescriptorSet;
var
  Alloc: VkDescriptorSetAllocateInfo;
  ImageInfo: VkDescriptorImageInfo;
  Write: VkWriteDescriptorSet;
begin
  if T.Sets.TryGetValue(SamplerKey, Result) then
    Exit;
  // The pool is full: once the GPU is done with them every set goes, and
  // each texture makes the ones it needs again.
  if FSetCount >= MaxSets then
  begin
    WaitAll;
    DestroyRetired;
    for var U in FTextures.Values do
      FreeSets(U);
    for var U in FTargets do
      if U.AsTexture <> nil then
        FreeSets(U.AsTexture);
    FreeSets(FBlank);
  end;
  Alloc := Default(VkDescriptorSetAllocateInfo);
  Alloc.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  Alloc.descriptorPool := FPool;
  Alloc.descriptorSetCount := 1;
  Alloc.pSetLayouts := @FSetLayout;
  CheckVulkan(FAPI.vkAllocateDescriptorSets(FDevice, @Alloc, @Result), 'vkAllocateDescriptorSets');
  ImageInfo.sampler := Sampler(SamplerKey);
  ImageInfo.imageView := T.Image.View;
  ImageInfo.imageLayout := VK_IMAGE_LAYOUT_GENERAL;
  Write := Default(VkWriteDescriptorSet);
  Write.sType := VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  Write.dstSet := Result;
  Write.dstBinding := 0;
  Write.descriptorCount := 1;
  Write.descriptorType := VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  Write.pImageInfo := @ImageInfo;
  FAPI.vkUpdateDescriptorSets(FDevice, 1, @Write, 0, nil);
  T.Sets.Add(SamplerKey, Result);
  Inc(FSetCount);
end;

procedure TVulkanHLERenderer.FreeSets(T: TVulkanHLETexture);
begin
  for var S in T.Sets.Values do
  begin
    var H := S;
    FAPI.vkFreeDescriptorSets(FDevice, FPool, 1, @H);
    Dec(FSetCount);
  end;
  T.Sets.Clear;
  if FBoundSet <> 0 then
    FBoundSet := 0;
end;

function TVulkanHLERenderer.Slot: PVulkanHLESlot;
begin
  Result := @FSlots[FSlot];
end;

procedure TVulkanHLERenderer.Record_;
begin
  var S := Slot;
  if S.Cmd.Recording then
    Exit;
  S.Cmd.Start;
  S.VertexCount := 0;
  S.UploadUsed := 0;
  FPass := nil;
  FDrawCount := 0;
  FBoundPipeline := 0;
  FBoundSet := 0;
  Unbound;
end;

procedure TVulkanHLERenderer.Unbound;
begin
end;

// Everything before is visible to everything after (transfers, attachments,
// shader reads).
procedure TVulkanHLERenderer.ImageBarrier;
var
  B: VkMemoryBarrier;
begin
  B := Default(VkMemoryBarrier);
  B.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  B.srcAccessMask := VK_ACCESS_MEMORY_WRITE_BIT;
  B.dstAccessMask := VK_ACCESS_MEMORY_READ_BIT or VK_ACCESS_MEMORY_WRITE_BIT;
  FAPI.vkCmdPipelineBarrier(Slot.Cmd.Handle, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0,
    1, @B, 0, nil, 0, nil);
end;

procedure TVulkanHLERenderer.HostReadBarrier;
var
  B: VkMemoryBarrier;
begin
  B := Default(VkMemoryBarrier);
  B.sType := VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  B.srcAccessMask := VK_ACCESS_TRANSFER_WRITE_BIT or VK_ACCESS_SHADER_WRITE_BIT;
  B.dstAccessMask := VK_ACCESS_HOST_READ_BIT;
  FAPI.vkCmdPipelineBarrier(Slot.Cmd.Handle, VK_PIPELINE_STAGE_TRANSFER_BIT or VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    VK_PIPELINE_STAGE_HOST_BIT, 0, 1, @B, 0, nil, 0, nil);
end;

procedure TVulkanHLERenderer.Submit;
begin
  var S := Slot;
  if not S.Cmd.Recording then
    Exit;
  EndPass;
  S.Vertices.Flush(0, UInt64(S.VertexCount) * UInt64(FVertexSize));
  S.Cmd.Submit;
  Inc(FStats.Submits);
  FSlot := (FSlot + 1) mod Length(FSlots);
end;

procedure TVulkanHLERenderer.WaitAll;
begin
  Submit;
  for var I := 0 to High(FSlots) do
    FSlots[I].Cmd.Wait;
end;

function TVulkanHLERenderer.StageUpload(Bytes: Int64; out Offset: Int64): PByte;
begin
  Record_;
  EndPass;
  if Bytes > HLEUploadCapacity then
    raise EVulkanError.CreateFmt('An upload of %d bytes is larger than the staging buffer.', [Bytes]);
  var S := Slot;
  Offset := (S.UploadUsed + 15) and not Int64(15);
  if Offset + Bytes > HLEUploadCapacity then
  begin
    Submit;
    Record_;
    S := Slot;
    Offset := 0;
  end;
  S.UploadUsed := Offset + Bytes;
  Result := S.Upload.Data + Offset;
end;

procedure TVulkanHLERenderer.CopyToImage(Image: VkImage; Aspect: Cardinal; Offset: Int64; Level, X, Y, W, H: Integer);
var
  Region: VkBufferImageCopy;
begin
  var S := Slot;
  S.Upload.Flush(Offset, S.UploadUsed - Offset);
  ImageBarrier;
  Region := Default(VkBufferImageCopy);
  Region.bufferOffset := Offset;
  Region.imageSubresource.aspectMask := Aspect;
  Region.imageSubresource.mipLevel := Level;
  Region.imageSubresource.layerCount := 1;
  Region.imageOffset.x := X;
  Region.imageOffset.y := Y;
  Region.imageExtent.width := W;
  Region.imageExtent.height := H;
  Region.imageExtent.depth := 1;
  FAPI.vkCmdCopyBufferToImage(S.Cmd.Handle, S.Upload.Handle, Image, VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
end;

procedure TVulkanHLERenderer.FlushDraw;
begin
  if FDrawCount = 0 then
    Exit;
  FAPI.vkCmdDraw(Slot.Cmd.Handle, FDrawCount, 1, FDrawFirst, 0);
  Inc(FStats.Draws);
  FDrawCount := 0;
end;

procedure TVulkanHLERenderer.EndPass;
begin
  FlushDraw;
  if FPass = nil then
    Exit;
  FAPI.vkCmdEndRenderPass(Slot.Cmd.Handle);
  FPass := nil;
end;

// The target's render pass Pass (FRenderPass with its framebuffer, or the
// subclass's own) over the whole target.
procedure TVulkanHLERenderer.BeginPass(T: TVulkanHLETarget; Pass: VkRenderPass; Framebuffer: VkFramebuffer);
var
  Info: VkRenderPassBeginInfo;
  VP: VkViewport;
  Offset: VkDeviceSize;
begin
  Record_;
  if (FPass = T) and (FPassRenderPass = Pass) then
    Exit;
  EndPass;
  // Everything recorded before is visible to the pass: the render passes'
  // external dependencies alone proved not to be enough for a target drawn in
  // one pass and sampled in the next (Tekken 6's glow on the PSP).
  ImageBarrier;
  Info := Default(VkRenderPassBeginInfo);
  Info.sType := VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
  Info.renderPass := Pass;
  Info.framebuffer := Framebuffer;
  Info.renderArea.extent.width := T.Width * FScale;
  Info.renderArea.extent.height := T.Height * FScale;
  var Cmd := Slot.Cmd.Handle;
  FAPI.vkCmdBeginRenderPass(Cmd, @Info, VK_SUBPASS_CONTENTS_INLINE);
  VP := Default(VkViewport);
  VP.width := T.Width * FScale;
  VP.height := T.Height * FScale;
  VP.maxDepth := 1;
  FAPI.vkCmdSetViewport(Cmd, 0, 1, @VP);
  var Buffer := Slot.Vertices.Handle;
  Offset := 0;
  FAPI.vkCmdBindVertexBuffers(Cmd, 0, 1, @Buffer, @Offset);
  FPass := T;
  FPassRenderPass := Pass;
  FBoundPipeline := 0;
  FBoundSet := 0;
  Unbound;
end;

procedure TVulkanHLERenderer.ReserveVertices(Count: Integer);
begin
  if Slot.Cmd.Recording and (Slot.VertexCount + Count > HLEVertexCapacity) then
    Submit;
end;

procedure TVulkanHLERenderer.AddVertices(V: Pointer; Count: Integer);
begin
  var Sl := Slot;
  if FDrawCount = 0 then
    FDrawFirst := Sl.VertexCount;
  Move(V^, (Sl.Vertices.Data + Int64(Sl.VertexCount) * FVertexSize)^, Count * FVertexSize);
  Inc(Sl.VertexCount, Count);
  Inc(FDrawCount, Count);
end;

{ Targets }

function TVulkanHLERenderer.FindTarget(Addr, Format, Stride, PixelBytes: Cardinal;
  NeedHeight, MinHeight, MaxHeight: Integer): TVulkanHLETarget;
var
  Info: VkFramebufferCreateInfo;
  Views: array[0..1] of VkImageView;
begin
  var Old: TVulkanHLETarget := nil;
  for var T in FTargets do
    if (T.Addr = Addr) and (T.Format = Format) and (T.Stride = Stride) then
    begin
      if T.Height >= NeedHeight then
        Exit(T);
      Old := T;
      Break;
    end;
  var W := Integer(Stride);
  var H := Max(NeedHeight, MinHeight);
  if Old <> nil then
  begin
    H := Max(H, Min(Old.Height * 2, MaxHeight));
    // Its pixels go back to console memory, the larger image starts from there.
    FlushAll;
    FTargets.Remove(Old);
    if FTarget = Old then
      FTarget := nil;
    if FPass = Old then
      FPass := nil;
    DestroyTarget(Old);
  end
  else if FTargets.Count >= HLEMaxTargets then
  begin
    // The longest unused target that console memory holds in full goes.
    var Oldest: TVulkanHLETarget := nil;
    for var T in FTargets do
      if not T.Dirty and (T <> FTarget) and ((Oldest = nil) or (T.LastUse < Oldest.LastUse)) then
        Oldest := T;
    if Oldest <> nil then
    begin
      WaitAll;
      FTargets.Remove(Oldest);
      DestroyTarget(Oldest);
    end;
  end;
  Result := NewTarget;
  Result.Addr := Addr;
  Result.Format := Format;
  Result.Stride := Stride;
  Result.PixelBytes := PixelBytes;
  Result.Width := W;
  Result.Height := H;
  Result.MaxHeight := MaxHeight;
  Result.Color := CreateImage(VK_FORMAT_R8G8B8A8_UNORM, W * FScale, H * FScale, 1, FColorUsage,
    VK_IMAGE_ASPECT_COLOR_BIT);
  Result.Depth := CreateImage(FDepthFormat, W * FScale, H * FScale, 1, FDepthUsage, VK_IMAGE_ASPECT_DEPTH_BIT or
    VK_IMAGE_ASPECT_STENCIL_BIT);
  Views[0] := Result.Color.View;
  Views[1] := Result.Depth.View;
  Info := Default(VkFramebufferCreateInfo);
  Info.sType := VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
  Info.renderPass := FRenderPass;
  Info.attachmentCount := 2;
  Info.pAttachments := @Views[0];
  Info.width := W * FScale;
  Info.height := H * FScale;
  Info.layers := 1;
  CheckVulkan(FAPI.vkCreateFramebuffer(FDevice, @Info, nil, @Result.Framebuffer), 'vkCreateFramebuffer');
  Changed(Result);
  InitTarget(Result);
  FTargets.Add(Result);
end;

function TVulkanHLERenderer.NewTarget: TVulkanHLETarget;
begin
  Result := TVulkanHLETarget.Create;
end;

procedure TVulkanHLERenderer.InitTarget(T: TVulkanHLETarget);
begin
end;

procedure TVulkanHLERenderer.DestroyTarget(T: TVulkanHLETarget);
begin
  if FFrameTarget = T then
    FFrameTarget := nil;
  if T.Framebuffer <> 0 then
    FAPI.vkDestroyFramebuffer(FDevice, T.Framebuffer, nil);
  if T.AsTexture <> nil then
  begin
    FreeSets(T.AsTexture);
    T.AsTexture.Free;
  end;
  DestroyImage(T.Color);
  DestroyImage(T.Depth);
  T.Free;
end;

function TVulkanHLERenderer.TargetNewer(T: TVulkanHLETarget): Boolean;
begin
  Result := T.Dirty;
end;

procedure TVulkanHLERenderer.EnsureTarget(T: TVulkanHLETarget);
begin
  if T.Dirty then
    Exit;
  if T.Loaded and ShadowMatches(T) then
    Exit;
  // Another target's newer pixels there go back first.
  if MemoryHeld(T.Addr, T.Bytes) then
    FlushAll;
  LoadTarget(T);
  Changed(T);
  SetLength(T.Shadow, T.Bytes);
  if Length(T.Shadow) > 0 then
    ReadMemory(T.Addr, @T.Shadow[0], Length(T.Shadow));
  T.Loaded := True;
  Inc(FStats.TargetLoads);
end;

procedure TVulkanHLERenderer.BeginDrawing(T: TVulkanHLETarget);
begin
  Inc(FUseCounter);
  T.LastUse := FUseCounter;
  // From the first primitive on the target is newer than console memory: the
  // rows drawn are held (HoldNewRows), the rest watched.
  if not T.Dirty then
  begin
    T.Dirty := True;
    T.X1 := MaxInt;
    T.Y1 := MaxInt;
    T.X2 := -1;
    T.Y2 := -1;
    T.HeldY1 := MaxInt;
    T.HeldY2 := -1;
    T.Stale := False;
    WatchTarget(T);
  end;
end;

procedure TVulkanHLERenderer.Changed(T: TVulkanHLETarget);
begin
  Inc(FVersion);
  T.Version := FVersion;
end;

procedure TVulkanHLERenderer.Drawn(T: TVulkanHLETarget; X1, Y1, X2, Y2: Integer);
begin
  Changed(T);
  T.X1 := Min(T.X1, X1);
  T.Y1 := Min(T.Y1, Y1);
  T.X2 := Max(T.X2, X2);
  T.Y2 := Max(T.Y2, Y2);
end;

procedure TVulkanHLERenderer.HoldNewRows(T: TVulkanHLETarget; Y1, Y2: Integer);

  procedure Hold(First, Last: Integer);
  begin
    var RowBytes := T.Stride * T.PixelBytes;
    HoldMemory(T.Addr + Cardinal(First) * RowBytes, Cardinal(Last - First + 1) * RowBytes);
  end;

begin
  if T.HeldY1 > T.HeldY2 then
  begin
    Hold(Y1, Y2);
    T.HeldY1 := Y1;
    T.HeldY2 := Y2;
  end
  else
  begin
    if Y1 < T.HeldY1 then
    begin
      Hold(Y1, T.HeldY1 - 1);
      T.HeldY1 := Y1;
    end;
    if Y2 > T.HeldY2 then
    begin
      Hold(T.HeldY2 + 1, Y2);
      T.HeldY2 := Y2;
    end;
  end;
end;

procedure TVulkanHLERenderer.WatchTarget(T: TVulkanHLETarget);
begin
  WatchMemory(T.Addr, T.Bytes);
end;

function TVulkanHLERenderer.ShadowMatches(T: TVulkanHLETarget): Boolean;
begin
  Result := (Length(T.Shadow) > 0) and MemoryEquals(T.Addr, @T.Shadow[0], Length(T.Shadow));
end;

function TVulkanHLERenderer.TargetAsTexture(T: TVulkanHLETarget): TVulkanHLETexture;
begin
  if T.AsTexture = nil then
  begin
    T.AsTexture := TVulkanHLETexture.Create;
    T.AsTexture.Target := T;
    T.AsTexture.Image := T.Color;
    T.AsTexture.Levels := 1;
  end;
  Result := T.AsTexture;
  Inc(FStats.TargetTextures);
end;

{ Textures }

function TVulkanHLERenderer.CachedTexture(Key: UInt64; Request: Pointer): TVulkanHLETexture;
begin
  Inc(FUseCounter);
  if FTextures.TryGetValue(Key, Result) then
  begin
    if Result.Verified = FRun then
      Inc(FStats.TextureHits)
    else if TextureMatches(Result, Request) then
    begin
      WatchTexture(Result, Request);
      Result.Verified := FRun;
      Inc(FStats.TextureHits);
    end
    else if (Result.Scale > 1) and Changing(Result) then
    begin
      // Bytes that keep changing (a video, textures streamed through one
      // place): made again unscaled, the old image kept until the GPU is done.
      FTextures.Remove(Key);
      FRetired.Add(Result);
      Result := AddTexture(Key, Result.Width, Result.Height, Result.Levels, 1, Request);
    end
    else
      Decode(Result, Request);
  end
  else
  begin
    var W, H, Levels, Scale: Integer;
    DescribeTexture(Request, W, H, Levels, Scale);
    Result := AddTexture(Key, W, H, Levels, Scale, Request);
  end;
  Result.LastUse := FUseCounter;
end;

function TVulkanHLERenderer.AddTexture(Key: UInt64; Width, Height, Levels, Scale: Integer;
  Request: Pointer): TVulkanHLETexture;
begin
  Result := TVulkanHLETexture.Create;
  Result.Key := Key;
  Result.Levels := Levels;
  Result.Width := Width;
  Result.Height := Height;
  Result.Scale := Scale;
  Result.Image := CreateImage(VK_FORMAT_R8G8B8A8_UNORM, Width * Scale, Height * Scale, Levels,
    VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
  FTextures.Add(Key, Result);
  Decode(Result, Request);
end;

procedure TVulkanHLERenderer.Decode(T: TVulkanHLETexture; Request: Pointer);
begin
  DecodeTexture(T, Request);
  WatchTexture(T, Request);
  T.Verified := FRun;
  Inc(FStats.TextureUploads);
end;

// A scaled texture's bytes changed: True when they did so last within a
// second (60 frames shown).
function TVulkanHLERenderer.Changing(T: TVulkanHLETexture): Boolean;
begin
  if (T.Changes > 0) and (FStats.Presents - T.ChangedAt <= 60) then
    Inc(T.Changes)
  else
    T.Changes := 1;
  T.ChangedAt := FStats.Presents;
  Result := T.Changes >= 2;
end;

// Bytes is what KeepSource was given, read again.
function TVulkanHLERenderer.SameSource(T: TVulkanHLETexture; const Bytes: array of TVulkanHLEBytes): Boolean;
begin
  if not T.Checkable then
    Exit(False);
  var Off := 0;
  for var B in Bytes do
  begin
    if (B.Data = nil) or (Off + B.Size > Length(T.Source)) or ((B.Size > 0) and
      not CompareMem(B.Data, @T.Source[Off], B.Size)) then
      Exit(False);
    Inc(Off, B.Size);
  end;
  Result := Off = Length(T.Source);
end;

// The bytes a texture is decoded from, kept to compare them later: all of
// them when they are all in host memory (Checkable), else none.
procedure TVulkanHLERenderer.KeepSource(T: TVulkanHLETexture; const Bytes: array of TVulkanHLEBytes);
begin
  T.Checkable := True;
  var Total := 0;
  for var B in Bytes do
    if B.Data = nil then
      T.Checkable := False
    else
      Inc(Total, B.Size);
  if not T.Checkable then
  begin
    T.Source := nil;
    Exit;
  end;
  SetLength(T.Source, Total);
  var Off := 0;
  for var B in Bytes do
  begin
    if B.Size > 0 then
      Move(B.Data^, T.Source[Off], B.Size);
    Inc(Off, B.Size);
  end;
end;

function TVulkanHLERenderer.LevelTexels(T: TVulkanHLETexture; W, H: Integer): PCardinal;
begin
  // Scaled in host memory (the staging buffer is slow to read).
  if T.Scale > 1 then
  begin
    if Length(FScaleIn) < W * H then
      SetLength(FScaleIn, W * H);
    Result := @FScaleIn[0];
  end
  else
    Result := PCardinal(StageUpload(Int64(W) * H * 4, FLevelOffset));
end;

procedure TVulkanHLERenderer.UploadLevel(T: TVulkanHLETexture; Level, W, H: Integer);
begin
  if T.Scale > 1 then
  begin
    var Watch := TStopwatch.StartNew;
    var N := W * H * T.Scale * T.Scale;
    if Length(FScaleOut) < N then
      SetLength(FScaleOut, N);
    ScaleTexture(@FScaleIn[0], W, H, T.Scale, @FScaleOut[0], FTextureFilter);
    Move(FScaleOut[0], StageUpload(Int64(N) * 4, FLevelOffset)^, N * 4);
    Inc(FStats.TextureScales);
    FStats.ScaleSeconds := FStats.ScaleSeconds + Watch.Elapsed.TotalSeconds;
  end;
  CopyToImage(T.Image.Image, VK_IMAGE_ASPECT_COLOR_BIT, FLevelOffset, Level, 0, 0, W * T.Scale, H * T.Scale);
end;

function TVulkanHLERenderer.ScaleFor(Width, Height: Integer): Integer;
begin
  Result := 1;
  if (FTextureScale < 2) or (FScale < 2) then
    Exit;
  if (Width < 8) or (Height < 8) then
    Exit;
  var F := Min(FTextureScale, 1024 div Max(Width, Height));
  if F >= 2 then
    Result := F;
end;

procedure TVulkanHLERenderer.SetTextureScale(Value: Integer);
begin
  if Value < 2 then
    Value := 0;
  FTextureScale := Min(Value, TexScaleMax);
end;

procedure TVulkanHLERenderer.DestroyTexture(T: TVulkanHLETexture);
begin
  FreeSets(T);
  DestroyImage(T.Image);
  T.Free;
end;

// The GPU has finished (WaitAll).
procedure TVulkanHLERenderer.DestroyRetired;
begin
  for var T in FRetired do
    DestroyTexture(T);
  FRetired.Clear;
end;

{ Coherence }

procedure TVulkanHLERenderer.FlushAll;
begin
  if FFlushing then
    Exit;
  FFlushing := True;
  var Watch := TStopwatch.StartNew;
  try
    WaitAll;
    DestroyRetired;
    FStats.WaitSeconds := FStats.WaitSeconds + Watch.Elapsed.TotalSeconds;
    for var T in FTargets do
      if TargetNewer(T) then
      begin
        StoreTarget(T);
        if T.Dirty then
        begin
          T.Dirty := False;
          // The shadow is what the image holds: console memory's in the rows
          // drawn, and outside them what it was when loaded (the console may
          // have written there since: the next use compares and loads the
          // target again).
          if (Cardinal(Length(T.Shadow)) <> T.Bytes) or (T.HeldY1 > T.HeldY2) then
          begin
            SetLength(T.Shadow, T.Bytes);
            if Length(T.Shadow) > 0 then
              ReadMemory(T.Addr, @T.Shadow[0], Length(T.Shadow));
          end
          else
          begin
            var RowBytes := T.Stride * T.PixelBytes;
            for var Y := T.HeldY1 to T.HeldY2 do
              ReadMemory(T.Addr + Cardinal(Y) * RowBytes, @T.Shadow[Cardinal(Y) * RowBytes], RowBytes);
          end;
          T.Stale := False;
        end;
        Inc(FStats.Readbacks);
      end;
    FStats.FlushSeconds := FStats.FlushSeconds + Watch.Elapsed.TotalSeconds;
    ReleaseHolds;
    // Unwatched texture bytes may change from now on: textures are compared
    // with them again.
    ReleaseWatches;
    NewRun;
    Inc(FStats.Flushes);
    if FTextures.Count > MaxTextures then
    begin
      var List := FTextures.Values.ToArray;
      TArray.Sort<TVulkanHLETexture>(List, TComparer<TVulkanHLETexture>.Construct(
          function(const A, B: TVulkanHLETexture): Integer begin Result := CompareValue(A.LastUse, B.LastUse); end));
      for var I := 0 to Length(List) - MaxTextures * 3 div 4 - 1 do
      begin
        FTextures.Remove(List[I].Key);
        DestroyTexture(List[I]);
      end;
    end;
  finally
    FFlushing := False;
  end;
end;

procedure TVulkanHLERenderer.NewRun;
begin
  Inc(FRun);
end;

procedure TVulkanHLERenderer.Sync;
begin
  FlushAll;
end;

procedure TVulkanHLERenderer.Release;
begin
  if not Slot.Cmd.Recording or (FDrawCount = 0) and (Slot.VertexCount = 0) then
    Exit;
  // Small lists wait for more: a submission costs the driver more than it
  // saves the GPU (Tekken 6 on the PSP: some 70 lists a frame).
  if Slot.VertexCount < ReleaseVertices then
    Exit;
  if FSlots[(FSlot + 1) mod Length(FSlots)].Cmd.Done then
    Submit;
end;

{ Frames }

// The references to a dynamic array (System's header before its data).
function DynArrayRefs(const A: TArray<TAlphaColor>): Integer;
type
  THeader = packed record
{$IFDEF CPU64BITS}
    Padding: Integer;
{$ENDIF}
    RefCount: Integer;
    Length: NativeInt;
  end;
  PHeader = ^THeader;
begin
  if A = nil then
    Exit(0);
  Result := PHeader(PByte(Pointer(A)) - SizeOf(THeader))^.RefCount;
end;

procedure TVulkanHLERenderer.ReadFrame(T: TVulkanHLETarget; W, H: Integer; var Frame: TEmulatorFrame);
begin
  // Nothing changed the image since the last frame read from it (a game
  // drawing every other frame): that frame again, without the GPU.
  if (T = FFrameTarget) and (T.Version = FFrameVersion) and (W = FFrameWidth) and (H = FFrameHeight) then
  begin
    Frame.Width := W;
    Frame.Height := H;
    Frame.Pixels := FFramePixels;
    Inc(FStats.Presents);
    Exit;
  end;
  var Watch := TStopwatch.StartNew;
  Record_;
  EndPass;
  ImageBarrier;
  RecordFrame(T, W, H);
  HostReadBarrier;
  WaitAll;
  FReadback.Invalidate(0, UInt64(W * H) * 4);
  Frame.Width := W;
  Frame.Height := H;
  // A buffer of the pool that only the pool holds (the frames before may
  // still be read), else a new one: no allocation and clearing each frame.
  var Pick := -1;
  for var I := 0 to High(FFrames) do
    if (Length(FFrames[I]) = W * H) and (DynArrayRefs(FFrames[I]) = 1) then
    begin
      Pick := I;
      Break;
    end;
  if Pick < 0 then
  begin
    Pick := 0;
    for var I := 0 to High(FFrames) do
      if (FFrames[I] = nil) or (DynArrayRefs(FFrames[I]) = 1) then
      begin
        Pick := I;
        Break;
      end;
    FFrames[Pick] := nil;
    SetLength(FFrames[Pick], W * H);
  end;
  Frame.Pixels := FFrames[Pick];
  Move(FReadback.Data^, Frame.Pixels[0], W * H * 4);
  FFrameTarget := T;
  FFrameVersion := T.Version;
  FFrameWidth := W;
  FFrameHeight := H;
  FFramePixels := Frame.Pixels;
  Inc(FStats.Presents);
  FStats.PresentSeconds := FStats.PresentSeconds + Watch.Elapsed.TotalSeconds;
end;

end.
