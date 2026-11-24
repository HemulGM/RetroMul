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
// COLCLAMP wrapping or dithering. Resolution and texture scaling are optional
// host enhancements; guest memory remains at its native dimensions.
{$IFDEF PS2_CHECKED}
  {$Q+}
  {$R+}
{$ELSE}
  {$O+}
  {$Q-}
  {$R-}
{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  PS2.GS.Scanout, System.SysUtils, System.Math, System.Diagnostics,
  Core.Emulation.Types, RM.Vulkan.PipelineState, RM.Vulkan.Bindings,
  RM.Vulkan.Loader, RM.Vulkan.Compute, RM.Vulkan.HLE, RM.Vulkan.TexScale,
  PS2.Display.Pixels, PS2.GS.PascalShaders, PS2.Types, PS2.GS.Memory,
  PS2.GS.Raster;

type
  // A target with its depth buffer, which the depth image holds.
  TPageSpan = record
    Base, Size, First, Count: Cardinal;
  end;

  TPS2HLETarget = class(TVulkanHLETarget)
  public
    // The depth buffer's byte address and format.
    ZAddr, ZPSM: Cardinal;
    ZPlan: TPS2HLETarget;
    ZPacked: Boolean;
    ZView: VkImageView;
    ZFlagAt: Int64;
    Pins: array[Boolean] of record
      Pages: TArray<TBytes>;
      Base: Cardinal;
    end;
    BatchAt: array[Boolean] of Int64;
    PackX, PackY, PackW, PackH, PackFirst, PackCount: Integer;
    PackBytes: Int64;
    PackSelected: Boolean;
    Fringe: Boolean;
    ClipX, ClipY, ClipW, ClipH: Integer;
    PackSpans: array of record
      Src, Dst, Size: Integer;
    end;

    ZLoaded: Boolean;
    InActiveTargets: Boolean;
    // The run the depth image was last found equal to GS memory in, and the
    // run its pages were watched in (only tested).
    ZVerified, ZWatched: Int64;
    // GS memory's bytes of the depth buffer when last made equal to it.
    ZShadow: TBytes;
    // Page-row bands (bit N: band N) resolved from the depth image since its
    // last load: equal shadow bytes do not prove the image holds their exact
    // normalized values, so these bands are uploaded again.
    ZReloadRows: UInt64;
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

  // As shaders/PS2.GS.HLEUpload.comp declares it.
  TPS2HLEUploadPush = packed record
    OffsetWords, WidthPages, Format, Scale: Cardinal;
    Width, Height, FirstY, Depth: Cardinal;
  end;

  // A draw's pass: the alpha test's passing pixels, or its failing ones.
  TPS2HLEPass = record
    NativeKey: UInt64;
    Pipeline: VkPipeline;
    Layout: VkPipelineLayout;
    Push: TPS2HLEPush;
  end;

  TPS2HLEDisplay = record
    Target: TPS2HLETarget;
    Version: Int64;
    X, Y, Width, Height: Integer;
    Format: Cardinal;
    Pixels: TArray<Cardinal>;
  end;

  PPS2HLEDisplay = ^TPS2HLEDisplay;

  TPS2GSVulkanHLE = class(TVulkanHLERenderer)
  private
    FMemory: TPS2GSMemory;
    FClut: PWord;
    FWorkerState: PPS2GSDraw;
    FWriterBusy: PBoolean;
    FQueuedWrites: PInteger;
    FPinScope: Boolean;
    FPinEpoch: Int64;
    FPinSeen: array[0..1023] of Int64;
    FNativeFast, FMatchFast, FProofBytes, FReverted: Int64;
    FWorkerFresh: PBoolean;
    FVertexModule, FFragmentModule: VkShaderModule;
    // Shader blending (VK_EXT_fragment_shader_interlock): the GS's pixel
    // operations exactly, for the draws the fixed function cannot do (and
    // that write depth only when they discard nothing).
    FShaderBlend: Boolean;
    FBlendModule: VkShaderModule;
    FDirectProgram: array[Boolean] of VkShaderModule;
    FDirectSampling: Boolean;
    FBlendSetLayout: VkDescriptorSetLayout;
    FBlendLayout: VkPipelineLayout;
    FBlendPool: VkDescriptorPool;
    FBlendPass: VkRenderPass;
    // The state set up blends in the shader.
    FBlended: Boolean;
    FBoundTargetSet: VkDescriptorSet;
    FDynDepth, FDynColor, FDynKnown: Boolean;
    FPrevKey: UInt64;
    FDepthTestCmd, FDepthWriteCmd, FDepthCompareCmd: TVkSetDepthState;
    FColorEnableCmd, FColorEquationCmd, FColorMaskCmd: TVkSetColorState;

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
    FSampledImage: VkImage;
    FScissor: VkRect2D;
    FBoundPass: Integer;
    FBoundScissor: VkRect2D;
    FScissorValid: Boolean;
    FDepthWrites, FDepthUsed: Boolean;
    // The draw samples its own target (its copy, CopyOf): where the copy
    // starts in the image, and the box drawn since the copy was made.
    FFeedback: Boolean;
    FLimitedSource: Boolean;
    FSourceWidth, FSourceHeight: Integer;
    FExtentUses, FExtentDeclines: Int64;
    FRecheckOwnRead: Boolean;
    FCopyOffX, FCopyOffY: Integer;
    FCopyX1, FCopyY1, FCopyX2, FCopyY2: Integer;
    // Rows of the colour's and the depth's pages.
    FPageRows, FZPageRows: Integer;
    // The lowest row the primitive being set up needs in its target.
    FNeedY: Integer;
    // Depth over the depth buffer's range (its largest value plus one).
    FStoreBatched: Boolean;
    FPartialStoreMask: ^TPS2GSPages;
    FPartialBatches, FGroupedPlanes: Int64;
    FCapturingDisplay: Boolean;
    FPageOwners: array[0..511] of record
      Target: TPS2HLETarget;
      Version, Prefix, Queue: Int64;
      X0, Y0, X1, Y1: Integer;
    end;
    FEpochPixels, FEpochFrames: Int64;
    FRGBLease: record
      T: TPS2HLETarget;
      Version, Queue, Cut: Int64;
      BP, BW: Cardinal;
      X, Y, W, H: Integer;
      Pages: TPS2GSPages;
      Pixels: TArray<Cardinal>;
    end;
    FReadSurface: TPS2HLETarget;
    FRGBRepairs, FRGBBlocks, FRGBProtected, FRGBThreat, FRGBPhysical: Int64;
    FDisplayStoreCount: Integer;
    FDisplayViews, FDisplayPixels: Int64;
    FDisplayStores: array of record
      T: TPS2HLETarget;
      Depth: Boolean;
      X1, Y1, X2, Y2: Integer;
      Pages: TPS2GSPages;
    end;
    FPackKernel: TVulkanKernel;
    FPackTable: TVulkanBuffer;
    FHybridKernel: TVulkanKernel;
    FHybridCorners, FHybridOutput: TVulkanBuffer;
    FHybridInputs: array[0..1] of VkBuffer;
    FHybridAvailable: Boolean;
    FHybridJobs, FHybridPixels, FMetricBuilds: Int64;
    FMetricNext: Integer;
    FMetrics: array[0..7] of record
      Count: Integer;
      Words: TArray<Cardinal>;
      Index: array[0..511] of Word;
    end;
    FDepthTable, FDepthFallback: TVulkanBuffer;
    FCanSampleZ: Boolean;
    FZSet: Integer;
    FDepthPack: TVulkanKernel;
    FZPacked, FZPackedPixels, FZRejected: Int64;
    function PlanDepth(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
    procedure EmitDepth(T: TPS2HLETarget);
  private
    FMissing: TArray<Cardinal>;
    FClippedPlanes, FClippedPixels: Int64;
    FScanBank: TPixelBank<Cardinal>;
    FPackedAreas, FPackedPixels: Int64;

    FZScale: Double;
    FDepthClamp: Boolean;
    FUploadKernel: TVulkanKernel;
    FMirrorRAM, FMirrorDecoded: TVulkanBuffer;
    FMirrorShadow: TBytes;
    FMirrorValid: array[0..1023] of Boolean;
    FUsePagePins: Boolean;
    FNativePins, FGPUPins: array[0..1023] of TBytes;
    FJustUploaded: TPS2HLETarget;
    FJustDepth: Boolean;
    FPinReused, FPinCopied, FAfterUpload, FValidated: Int64;
    function NativePin(Index: Integer): TBytes;
    function CapturePins(T: TPS2HLETarget; Z: Boolean; First, Bytes: Cardinal): Boolean;
    function PinMatch(T: TPS2HLETarget; Z: Boolean; Off, Bytes: Cardinal): Boolean;
    function DepthMatches(T: TPS2HLETarget): Boolean;
  protected
    function ShadowMatches(T: TVulkanHLETarget): Boolean; override;
    function CaptureColor(T: TVulkanHLETarget; Whole: Boolean): Boolean; override;
  private
  private
    FDecodeSources: array[0..3] of VkBuffer;
    FMirrorKernel: TVulkanKernel;
    FImageDecode: TVulkanKernel;
    FDecodeBanks: array[0..1] of record
      Upload: VkBuffer;
      RecordingNumber: Int64;
      Issued, Initialized: Integer;
    end;
    FImageDecodes, FImageTexels, FImageSetLimit: Int64;
    FMirrorSent, FMirrorReused, FMirrorLevels, FMirrorTexels: Int64;

    FUploadScratch: TVulkanBuffer;
    FImageLoader: TVulkanKernel;
    FImageOwners: array[0..63] of TPS2HLETarget;
    FDirectLoads, FDirectPixels: Int64;
    function LoadColorImage(T: TPS2HLETarget; Addr: Cardinal): Boolean;
  private
    FUploadSources: array[0..3] of VkBuffer;
    FUploadSourceCount: Integer;
    FColorGpuLoads, FDepthGpuLoads: Int64;
    // The texture being looked up: its GS blocks as runs of bytes (and the
    // CLUT's entries it takes, last), the pages of those blocks.
    FBlockBits: array[0..255] of UInt64;
    FTexBytes: TArray<TVulkanHLEBytes>;
    FTexByteCount: Integer;
    FTexPages: TPS2GSPages;
    FActiveTargets: TArray<TPS2HLETarget>;
    FActiveCount: Integer;
    FSpanCalls, FSpanStores, FSpanChecks: Int64;
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
    FDisplay: array[1..2] of TPS2HLEDisplay;
    FStoreRow: TArray<Cardinal>;
    function FitsTarget(const D: TPS2GSDraw; LastY: Integer): Boolean;
    procedure StoreScaled(T: TPS2HLETarget; Color, Depth: Boolean);
    function TargetFor(const D: TPS2GSDraw): TPS2HLETarget;
    procedure FlushOthers(T: TPS2HLETarget; const Pages: TPS2GSPages);
    procedure CheckDestSpans(T: TPS2HLETarget; const C, Z: TPageSpan);
    procedure ActivateTarget(T: TPS2HLETarget);
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
    procedure LoadDepth(T: TPS2HLETarget; ChangedOnly: Boolean);
    procedure WatchDepth(T: TPS2HLETarget);
    procedure HoldDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
    procedure HoldNewDepthRows(T: TPS2HLETarget; Y1, Y2: Integer);
    procedure HoldTarget(T: TPS2HLETarget);
    function BandRows(T: TVulkanHLETarget): Integer;
    function UploadSet(Buffer: TVulkanBuffer): Integer;
    function UploadTargetGpu(T: TPS2HLETarget; Depth: Boolean): Boolean;
    procedure Store(T: TPS2HLETarget; Color, Depth: Boolean);
    procedure StoreOverlapping(const Pages: TPS2GSPages);
    procedure WatchFault(const Writes: TPS2GSPages);
    function SameState(const D: TPS2GSDraw): Boolean;
    function SameStateFull(const D: TPS2GSDraw): Boolean;
    function StreamSlot(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): PVulkanHLESlot;
    procedure SetupState(const D: TPS2GSDraw);
    function SourceFits(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer): Boolean;
    procedure ProtectRGB(BP, BW: Cardinal; X, Y, W, H: Integer; var Pixels: TArray<Cardinal>);
    function ReadCircuitRaw(Circuit: Integer; BP, BW, PSM: Cardinal; X, Y, W, H: Integer; out Pixels: TArray<Cardinal>; Certified: Boolean): Boolean;
    procedure MarkStoreOwner(T: TPS2HLETarget; Depth: Boolean);
    procedure NoteDisplayStore(T: TPS2HLETarget; IsDepth: Boolean);
    function OwnsDisplayRect(T: TPS2HLETarget; X, Y, W, H: Integer; const Pages: TPS2GSPages): Boolean;
    procedure PrepareMirror;
    function PaletteInput: Integer;
    function PaletteLevel(T: TVulkanHLETexture; L, W, H: Integer; Src, Pal: PCardinal; Count: Integer): Boolean;
    function DecodeImage(T: TVulkanHLETexture; Level, W, H: Integer; const Push; Size: Cardinal): Boolean;
    procedure SyncMirror(Addr, Size: Cardinal);
    function DecodeMirror(T: TVulkanHLETexture; Request: Pointer; L, X, Y, W, H: Integer; Palette: PCardinal; Count: Integer): Boolean;
    procedure ApplyBindings;
    function DrawPipeline(Key: UInt64; var Pass: TPS2HLEPass): VkPipeline;
    procedure ApplyDynamic(Key: UInt64; NewPipe: Boolean);
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
    function PlanPack(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
    function PlanAligned(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
    procedure EmitPack(T: TPS2HLETarget; Id: Integer);
    procedure ApplyPack(T: TPS2HLETarget);
    function BeginStoreBatch: Boolean; override;
    procedure EndStoreBatch; override;
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
    procedure BindWorkerState(D: PPS2GSDraw; Fresh, Busy: PBoolean; TransferCount: PInteger);
    // Memory: the GS memory drawn; Clut: the raster's CLUT (512 entries).
    constructor Create(Memory: TPS2GSMemory; Clut: PWord; Compute: TVulkanCompute; Resolution: Integer = 1);
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
    procedure BeginDisplayFence;
    procedure EndDisplayFence;
    function ReadCircuit(Circuit: Integer; BP, BW, PSM: Cardinal; X, Y, W, H: Integer; out Pixels: TArray<Cardinal>; Certified: Boolean = False
    ): Boolean;
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
    constructor Create(Memory: TPS2GSMemory; Clut: PWord; Resolution: Integer = 1; TextureScale: Integer = 0; TextureFilter: TTexScaleFilter = tfXBRZ
    );
    destructor Destroy; override;
    procedure Sync; override;
    procedure ReadPages(First, Last: Integer); override;
    procedure WritePages(First, Last: Integer); override;
    procedure AccessPages(const Reads, Writes: TPS2GSPages); override;
    function Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex; X0, Y0, X1, Y1: Integer; Lod: Single): Boolean; override;
    function Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean; override;
    function BeginTriangle(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): Boolean; override;
    function PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive; const V0, V1: TPS2GSVertex): Boolean; override;
    procedure Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single); override;
    procedure EndTriangle; override;
    property Renderer: TPS2GSVulkanHLE read FRenderer;
  end;

// CPU-side HLE transfers, exposed for comparison with the original scalar
// addressing/conversion without creating a Vulkan device.
procedure PS2HLELoadColorRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; Target: PCardinal);

procedure PS2HLEStoreColorRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; Source: PCardinal);

procedure PS2HLELoadDepthRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; D24: Boolean; Target: PCardinal);
// The next run of page-row bands at or after Y (moved to its start) whose GS
// memory differs from Shadow or whose bit is set in ReloadRows: its rows, at
// most MaxRows; 0 when none is left.

function PS2HLEChangedRows(Memory: TPS2GSMemory; Addr, RowBytes: Cardinal; Height, PageRows, MaxRows: Integer; const Shadow: TBytes; var Y: Integer; ReloadRows: UInt64 = 0
    ): Integer;

const
  PackPagesEnabled = True;

implementation

uses
  HW.HostFPU;

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

procedure PS2HLELoadColorRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; Target: PCardinal);
begin
  if Count <= 0 then
    Exit;
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Words := PCardinal(Memory.Data);
  var Halves := PWord(Memory.Data);
  var Last := X + Count;
  var Separate := (NativeUInt(Target) >= NativeUInt(Memory.Data) + PS2GSMemorySize) or
    (NativeUInt(Memory.Data) >= NativeUInt(Target) + NativeUInt(Count * 4));
  if Format in [PSMCT32, PSMZ32, PSMCT24, PSMZ24] then
  begin
    var Is24 := Format in [PSMCT24, PSMZ24];
    // Each even-x 32-bit pixel is followed by x+1 at the adjacent word,
    // including page/VRAM boundaries. Do not reorder aliased synthetic I/O.
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and ((X and 7) = 0) and (X + 7 < Last) then
      begin
        // An eight-pixel row stays inside one GS block, including VRAM wrap.
        if Is24 then
        begin
          PUInt64(Target)^ := (PUInt64(Words + At)^ and $00FFFFFF00FFFFFF) or $8000000080000000;
          PUInt64(Target + 2)^ := (PUInt64(Words + At + 4)^ and $00FFFFFF00FFFFFF) or $8000000080000000;
          PUInt64(Target + 4)^ := (PUInt64(Words + At + 8)^ and $00FFFFFF00FFFFFF) or $8000000080000000;
          PUInt64(Target + 6)^ := (PUInt64(Words + At + 12)^ and $00FFFFFF00FFFFFF) or $8000000080000000;
        end
        else
        begin
          PUInt64(Target)^ := PUInt64(Words + At)^;
          PUInt64(Target + 2)^ := PUInt64(Words + At + 4)^;
          PUInt64(Target + 4)^ := PUInt64(Words + At + 8)^;
          PUInt64(Target + 6)^ := PUInt64(Words + At + 12)^;
        end;
        Inc(Target, 8);
        Inc(X, 8);
      end
      else if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        var Pair := PUInt64(Words + At)^;
        if Is24 then
          Pair := (Pair and $00FFFFFF00FFFFFF) or $8000000080000000;
        PUInt64(Target)^ := Pair;
        Inc(Target, 2);
        Inc(X, 2);
      end
      else
      begin
        var Pixel := Words[At];
        if Is24 then
          Pixel := (Pixel and $FFFFFF) or $80000000;
        Target^ := Pixel;
        Inc(Target);
        Inc(X);
      end;
    end;
  end
  else
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        // The next 16-bit pixel is two halfwords away, with independent
        // colour lanes in a UInt64. Scalar reads avoid overreading at wrap.
        var Pair := UInt64(Halves[At]) or (UInt64(Halves[At + 2]) shl 32);
        PUInt64(Target)^ := ((Pair and $0000001F0000001F) shl 3) or
          ((Pair and $000003E0000003E0) shl 6) or
          ((Pair and $00007C0000007C00) shl 9) or
          (((Pair and $0000800000008000) shr 15) * $FF000000);
        Inc(Target, 2);
        Inc(X, 2);
      end
      else
      begin
        var V: Cardinal := Halves[At];
        var C := ((V and $1F) shl 3) or (((V shr 5) and $1F) shl 11) or (((V shr 10) and $1F) shl 19);
        if (V and $8000) <> 0 then
          C := C or $FF000000;
        Target^ := C;
        Inc(Target);
        Inc(X);
      end;
    end;
end;

procedure PS2HLEStoreColorRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; Source: PCardinal);
begin
  if Count <= 0 then
    Exit;
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Words := PCardinal(Memory.Data);
  var Halves := PWord(Memory.Data);
  var Last := X + Count;
  var Separate := (NativeUInt(Source) >= NativeUInt(Memory.Data) + PS2GSMemorySize) or
    (NativeUInt(Memory.Data) >= NativeUInt(Source) + NativeUInt(Count * 4));
  if Format in [PSMCT32, PSMZ32, PSMCT24, PSMZ24] then
  begin
    var Is24 := Format in [PSMCT24, PSMZ24];
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and ((X and 7) = 0) and (X + 7 < Last) then
      begin
        if Is24 then
        begin
          PUInt64(Words + At)^ := (PUInt64(Words + At)^ and $FF000000FF000000) or
            (PUInt64(Source)^ and $00FFFFFF00FFFFFF);
          PUInt64(Words + At + 4)^ := (PUInt64(Words + At + 4)^ and $FF000000FF000000) or
            (PUInt64(Source + 2)^ and $00FFFFFF00FFFFFF);
          PUInt64(Words + At + 8)^ := (PUInt64(Words + At + 8)^ and $FF000000FF000000) or
            (PUInt64(Source + 4)^ and $00FFFFFF00FFFFFF);
          PUInt64(Words + At + 12)^ := (PUInt64(Words + At + 12)^ and $FF000000FF000000) or
            (PUInt64(Source + 6)^ and $00FFFFFF00FFFFFF);
        end
        else
        begin
          PUInt64(Words + At)^ := PUInt64(Source)^;
          PUInt64(Words + At + 4)^ := PUInt64(Source + 2)^;
          PUInt64(Words + At + 8)^ := PUInt64(Source + 4)^;
          PUInt64(Words + At + 12)^ := PUInt64(Source + 6)^;
        end;
        Inc(Source, 8);
        Inc(X, 8);
      end
      else if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        if Is24 then
          PUInt64(Words + At)^ := (PUInt64(Words + At)^ and $FF000000FF000000) or
            (PUInt64(Source)^ and $00FFFFFF00FFFFFF)
        else
          PUInt64(Words + At)^ := PUInt64(Source)^;
        Inc(Source, 2);
        Inc(X, 2);
      end
      else
      begin
        if Is24 then
          Words[At] := (Words[At] and $FF000000) or (Source^ and $FFFFFF)
        else
          Words[At] := Source^;
        Inc(Source);
        Inc(X);
      end;
    end;
  end
  else
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        var Pair := PUInt64(Source)^;
        var V := ((Pair shr 3) and $0000001F0000001F) or
          ((Pair shr 6) and $000003E0000003E0) or
          ((Pair shr 9) and $00007C0000007C00) or
          ((Pair shr 16) and $0000800000008000);
        Halves[At] := Word(V and $FFFF);
        Halves[At + 2] := Word(V shr 32);
        Inc(Source, 2);
        Inc(X, 2);
      end
      else
      begin
        Halves[At] := Word(Color32To16(Source^));
        Inc(Source);
        Inc(X);
      end;
    end;
end;

// Packed depth readback must preserve the caller's floating-point status.
function CanPackDepth: Boolean; inline;
begin
  {$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  Result := (ReadHostMXCSR and $1FA0) = $1FA0;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

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
    PSMZ24:
      Result := 16777216.0;
    PSMZ16, PSMZ16S:
      Result := 65536.0;
  else
    Result := 4294967296.0;
  end;
end;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
function CanNormalizeDepthPair: Boolean;
asm
        .       NOFRAME
        stmxcsr [rsp + 8]
        test    dword ptr[rsp + 8], $1000 // precision exception masked
        setnz   al
end;
{$ELSE}

function CanNormalizeDepthPair: Boolean;
begin
  Result := False;
end;
{$ENDIF}

// The scalar sequence in two independent lanes: integer -> Double, divide,
// then Double -> Single, all with the host rounding mode unchanged.
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}

procedure NormalizeDepthPair(Z0, Z1: Cardinal; Target: PCardinal; Range: Double);
asm
        .       NOFRAME
        mov     eax, ecx
        cvtsi2sd xmm0, rax
        mov     eax, edx
        cvtsi2sd xmm1, rax
        unpcklpd xmm0, xmm1
        unpcklpd xmm3, xmm3
        divpd   xmm0, xmm3
        cvtpd2ps xmm0, xmm0
        movq    qword ptr[r8], xmm0
end;
{$ELSE}

procedure NormalizeDepthPair(Z0, Z1: Cardinal; Target: PCardinal; Range: Double);
begin
  var F: Double := Z0 / Range;
  PSingle(Target)^ := F;
  F := Z1 / Range;
  PSingle(Target + 1)^ := F;
end;
{$ENDIF}

// Unsigned 16/24-bit inputs fit signed dwords. Keep integer -> Double ->
// division -> Single for four independent pixels, without a narrow multiply.
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}

procedure NormalizeSmallDepthQuad(Pair0, Pair1: UInt64; Target: PCardinal; Range: Double);
asm
        .       NOFRAME
        unpcklpd xmm3, xmm3
        movq    xmm0, rcx
        cvtdq2pd xmm0, xmm0
        divpd   xmm0, xmm3
        cvtpd2ps xmm0, xmm0
        movq    xmm1, rdx
        cvtdq2pd xmm1, xmm1
        divpd   xmm1, xmm3
        cvtpd2ps xmm1, xmm1
        movlhps xmm0, xmm1
        movups  [r8], xmm0
end;
{$ELSE}

procedure NormalizeSmallDepthQuad(Pair0, Pair1: UInt64; Target: PCardinal; Range: Double);
begin
  var Values: array[0..3] of Cardinal;
  Values[0] := Cardinal(Pair0 and $FFFFFFFF);
  Values[1] := Cardinal(Pair0 shr 32);
  Values[2] := Cardinal(Pair1 and $FFFFFFFF);
  Values[3] := Cardinal(Pair1 shr 32);
  for var K := 0 to 3 do
  begin
    var F: Double := Values[K] / Range;
    PSingle(Target + K)^ := F;
  end;
end;
{$ENDIF}

procedure PS2HLELoadDepthRow(Memory: TPS2GSMemory; const A: TPS2GSAddressing; Format: Cardinal; Y, X, Count: Integer; D24: Boolean; Target: PCardinal);
begin
  if Count <= 0 then
    Exit;
  var RB := A.RowBase(Cardinal(Y));
  var RO := A.RowOffsets(Cardinal(Y));
  var Range: Double := DepthRange(Format);
  var Last := X + Count;
  if D24 then
  begin
    while X < Last do
    begin
      var F: Double := Memory.ReadAt(Integer(Format), A.InRow(RB, RO, Cardinal(X))) / Range;
      Target^ := Min(Cardinal(Round(F * 16777215)), 16777215);
      Inc(Target);
      Inc(X);
    end;
    Exit;
  end;
  // A trapping conversion must retain scalar exception/write ordering too.
  var Separate := CanNormalizeDepthPair and
    ((NativeUInt(Target) >= NativeUInt(Memory.Data) + PS2GSMemorySize) or
    (NativeUInt(Memory.Data) >= NativeUInt(Target) + NativeUInt(Count * 4)));
  if Format in [PSMZ16, PSMZ16S] then
  begin
    var Source := PWord(Memory.Data);
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and ((X and 1) = 0) and (X + 3 < Last) then
      begin
        var Next := A.InRow(RB, RO, Cardinal(X + 2));
        var Pair0 := UInt64(Source[At]) or (UInt64(Source[At + 2]) shl 32);
        var Pair1 := UInt64(Source[Next]) or (UInt64(Source[Next + 2]) shl 32);
        NormalizeSmallDepthQuad(Pair0, Pair1, Target, Range);
        Inc(Target, 4);
        Inc(X, 4);
      end
      else if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        NormalizeDepthPair(Source[At], Source[At + 2], Target, Range);
        Inc(Target, 2);
        Inc(X, 2);
      end
      else
      begin
        var F: Double := Source[At] / Range;
        PSingle(Target)^ := F;
        Inc(Target);
        Inc(X);
      end;
    end;
  end
  else
  begin
    var Source := PCardinal(Memory.Data);
    var Mask: Cardinal := $FFFFFFFF;
    if Format = PSMZ24 then
      Mask := $FFFFFF;
    while X < Last do
    begin
      var At := A.InRow(RB, RO, Cardinal(X));
      if Separate and (Format = PSMZ24) and ((X and 1) = 0) and (X + 3 < Last) then
      begin
        var Next := A.InRow(RB, RO, Cardinal(X + 2));
        var Pair0 := PUInt64(Source + At)^ and UInt64($00FFFFFF00FFFFFF);
        var Pair1 := PUInt64(Source + Next)^ and UInt64($00FFFFFF00FFFFFF);
        NormalizeSmallDepthQuad(Pair0, Pair1, Target, Range);
        Inc(Target, 4);
        Inc(X, 4);
      end
      else if Separate and ((X and 1) = 0) and (X + 1 < Last) then
      begin
        var Pair := PUInt64(Source + At)^;
        NormalizeDepthPair(Cardinal(Pair and Mask), Cardinal(Pair shr 32) and Mask, Target, Range);
        Inc(Target, 2);
        Inc(X, 2);
      end
      else
      begin
        var F: Double := (Source[At] and Mask) / Range;
        PSingle(Target)^ := F;
        Inc(Target);
        Inc(X);
      end;
    end;
  end;
end;

{ TPS2HLETarget }

function PS2HLEChangedRows(Memory: TPS2GSMemory; Addr, RowBytes: Cardinal; Height, PageRows, MaxRows: Integer; const Shadow: TBytes; var Y: Integer; ReloadRows: UInt64): Integer;

  function Matches(Row: Integer): Boolean;
  begin
    if (Row div PageRows < 64) and ((ReloadRows and (UInt64(1) shl (Row div PageRows))) <> 0) then
      Exit(False);
    var At := Cardinal(Row) * RowBytes;
    var Bytes := Min(Cardinal(PageRows) * RowBytes, Cardinal(Length(Shadow)) - At);
    var Source := (Addr + At) and MemMask;
    var First := Min(Bytes, PS2GSMemorySize - Source);
    Result := VulkanHLEEqualBytes(Memory.Data + Source, @Shadow[At], First) and
      ((First = Bytes) or VulkanHLEEqualBytes(Memory.Data, @Shadow[At + First], Bytes - First));
  end;

begin
  Result := 0;
  if (Y < 0) or (Y >= Height) or (MaxRows <= 0) then
    Exit;
  if (PageRows <= 0) or (RowBytes = 0) then
    Exit(Min(MaxRows, Height - Y));
  if (Y mod PageRows <> 0) or (MaxRows < PageRows) or
    (UInt64(RoundRows(Height, PageRows)) * RowBytes > UInt64(Length(Shadow))) then
    Exit(Min(MaxRows, Height - Y));
  MaxRows := MaxRows - MaxRows mod PageRows;
  while (Y < Height) and Matches(Y) do
    Inc(Y, Min(PageRows, Height - Y));
  while (Y + Result < Height) and (Result < MaxRows) and not Matches(Y + Result) do
    Inc(Result, Min(PageRows, Height - Y - Result));
end;

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

constructor TPS2GSHLE.Create(Memory: TPS2GSMemory; Clut: PWord; Resolution, TextureScale: Integer; TextureFilter: TTexScaleFilter);
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
  FRenderer := TPS2GSVulkanHLE.Create(Memory, Clut, Compute, Resolution);
  FRenderer.TextureScale := TextureScale;
  FRenderer.TextureFilter := TextureFilter;
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

function TPS2GSHLE.Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex; X0, Y0, X1, Y1: Integer; Lod: Single): Boolean;
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

function SupportsImageUsage(Compute: TVulkanCompute; Format: VkFormat; Usage, ExtraUsage: Cardinal): Boolean;
var
  Info: VkPhysicalDeviceImageFormatInfo2;
  Raw, Sampled: VkImageFormatProperties2;
begin
  Result := False;
  if not Assigned(Compute.API.vkGetPhysicalDeviceImageFormatProperties2) then
    Exit;
  Info := Default(VkPhysicalDeviceImageFormatInfo2);
  Info.sType := VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
  Info.format := Format;
  Info.&type := VK_IMAGE_TYPE_2D;
  Info.tiling := VK_IMAGE_TILING_OPTIMAL;
  Info.usage := Usage;
  Raw := Default(VkImageFormatProperties2);
  Raw.sType := VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
  if Compute.API.vkGetPhysicalDeviceImageFormatProperties2(Compute.PhysicalDevice, @Info, @Raw) <> VK_SUCCESS then
    Exit;
  Info.usage := Usage or ExtraUsage;
  Sampled := Default(VkImageFormatProperties2);
  Sampled.sType := VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
  if Compute.API.vkGetPhysicalDeviceImageFormatProperties2(Compute.PhysicalDevice, @Info, @Sampled) <> VK_SUCCESS then
    Exit;
  // The optional readback route must not narrow the renderer's legal target sizes.
  Result :=
    (Sampled.imageFormatProperties.sampleCounts and VK_SAMPLE_COUNT_1_BIT <> 0)
    and (Sampled.imageFormatProperties.maxExtent.width >= Raw.imageFormatProperties.maxExtent.width)
    and (Sampled.imageFormatProperties.maxExtent.height >= Raw.imageFormatProperties.maxExtent.height)
    and (Sampled.imageFormatProperties.maxResourceSize >= Raw.imageFormatProperties.maxResourceSize);
end;

constructor TPS2GSVulkanHLE.Create(Memory: TPS2GSMemory; Clut: PWord; Compute: TVulkanCompute; Resolution: Integer);
var
  Props: VkFormatProperties;
begin
  FMemory := Memory;
  FClut := Clut;
  FRevision := 1;
  FLocalEdges := (Resolution = 2) and Compute.Features.PixelInterlock;
  FNativeTextureView := True;
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  FHostVertices := Resolution = 2;
  FHybridAvailable :=
    (Resolution = 2)
    and (Compute.APIVersion >= VK_API_VERSION_1_2)
    and Compute.Features.Float64
    and Compute.Features.Int64
    and Compute.Features.RoundEven32
    and Compute.Features.RoundEven64
    and Compute.Features.DenormPreserve32
    and Compute.Features.DenormPreserve64
    and Compute.Features.SignedZeroInfNan32
    and Compute.Features.SignedZeroInfNan64;
{$ENDIF}
  inherited Create(Compute, Resolution, SizeOf(TPS2HLEVertex), SizeOf(TPS2HLEPush), 1024, 1024);
  FUsePagePins := Resolution > 1;
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, FDepthFormat, @Props);
  FCanSampleZ :=
    (Resolution > 1)
    and not FD24
    and ((Props.optimalTilingFeatures and VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) <> 0)
    and SupportsImageUsage(Compute, FDepthFormat, FDepthUsage, VK_IMAGE_USAGE_SAMPLED_BIT);

  if FCanSampleZ then
    FDepthUsage := FDepthUsage or VK_IMAGE_USAGE_SAMPLED_BIT;
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_R8G8B8A8_UNORM, @Props);
  FTextureStore :=
    (Resolution = 2)
    and ((Props.optimalTilingFeatures and VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) <> 0)
    and SupportsImageUsage(
    Compute,
    VK_FORMAT_R8G8B8A8_UNORM,
    VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    VK_IMAGE_USAGE_STORAGE_BIT);
  EnableTextureRecycling;
  FDepthClamp := Compute.Features.DepthClamp;
  if Compute.Features.DynamicDepth then
  begin
    FDepthTestCmd := TVkSetDepthState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetDepthTestEnableEXT'));
    FDepthWriteCmd := TVkSetDepthState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetDepthWriteEnableEXT'));
    FDepthCompareCmd := TVkSetDepthState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetDepthCompareOpEXT'));
    FDynDepth := Assigned(FDepthTestCmd) and Assigned(FDepthWriteCmd) and Assigned(FDepthCompareCmd);
  end;
  if Compute.Features.DynamicColor then
  begin
    FColorEnableCmd := TVkSetColorState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetColorBlendEnableEXT'));
    FColorEquationCmd := TVkSetColorState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetColorBlendEquationEXT'));
    FColorMaskCmd := TVkSetColorState(FAPI.vkGetDeviceProcAddr(FDevice, 'vkCmdSetColorWriteMaskEXT'));
    FDynColor := Assigned(FColorEnableCmd) and Assigned(FColorEquationCmd) and Assigned(FColorMaskCmd);
  end;
  FVertexModule := Compute.CreateShaderModule(PS2GSKernelCode(TPS2GSKernel.HLEVertex));
  FFragmentModule := Compute.CreateShaderModule(PS2GSKernelCode(TPS2GSKernel.HLEFragment));
  FDirectProgram[False] := Compute.CreateShaderModule(PS2GSKernelCode(TPS2GSKernel.DirectColor));
  // Shader blending writes the colour as a storage image (RGBA8 storage is
  // required of every device) where the device orders fragments for it.
  FAPI.vkGetPhysicalDeviceFormatProperties(Compute.PhysicalDevice, VK_FORMAT_R8G8B8A8_UNORM, @Props);
  FShaderBlend :=
    Compute.Features.PixelInterlock
    and ((Props.optimalTilingFeatures and VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT) <> 0)
    and (GetEnvironmentVariable('PS2_HLESHADERBLEND') <> '0');
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
  FreeAndNil(FHybridKernel);
  FreeAndNil(FHybridCorners);
  FreeAndNil(FHybridOutput);
  FreeAndNil(FPackKernel);
  FreeAndNil(FDepthPack);
  FreeAndNil(FDepthTable);
  FreeAndNil(FDepthFallback);
  FreeAndNil(FPackTable);
  FreeAndNil(FMirrorKernel);
  FreeAndNil(FMirrorDecoded);
  FreeAndNil(FMirrorRAM);
  FreeAndNil(FImageDecode);
  FreeAndNil(FImageLoader);
  FreeAndNil(FUploadKernel);
  FreeAndNil(FUploadScratch);
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
  for var Blended := False to True do
    if FDirectProgram[Blended] <> 0 then
      FAPI.vkDestroyShaderModule(FDevice, FDirectProgram[Blended], nil);
  if FFragmentModule <> 0 then
    FAPI.vkDestroyShaderModule(FDevice, FFragmentModule, nil);
  inherited;
end;

procedure TPS2GSVulkanHLE.Unbound;
begin
  FDynKnown := False;
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
  FBlendModule := FCompute.CreateShaderModule(PS2GSKernelCode(TPS2GSKernel.HLEBlendFragment));
  FDirectProgram[True] := FCompute.CreateShaderModule(PS2GSKernelCode(TPS2GSKernel.DirectBlend));
  Binding := Default(VkDescriptorSetLayoutBinding);
  Binding.binding := 0;
  Binding.descriptorType := VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  Binding.descriptorCount := 1;
  Binding.stageFlags := VK_SHADER_STAGE_FRAGMENT_BIT;
  SetInfo := Default(VkDescriptorSetLayoutCreateInfo);
  SetInfo.sType := VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  SetInfo.bindingCount := 1;
  SetInfo.pBindings := @Binding;
  CheckVulkan(
    FAPI.vkCreateDescriptorSetLayout(FDevice, @SetInfo, nil, @FBlendSetLayout),
    'vkCreateDescriptorSetLayout'
  );
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
  if FLocalEdges then
    PixelDependency(Deps[0]);
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
  if FRGBLease.T = T then
  begin
    FRGBLease.T := nil;
    FRGBLease.Pixels := nil;
  end;
  for var N := Low(FDisplay) to High(FDisplay) do
    if FDisplay[N].Target = T then
      FDisplay[N] := Default(TPS2HLEDisplay);
  for var I := 0 to 511 do
    if FPageOwners[I].Target = T then
      FPageOwners[I].Target := nil;
  for var SlotId := 0 to High(FImageOwners) do
    if FImageOwners[SlotId] = T then
      FImageOwners[SlotId] := nil;
  var G := TPS2HLETarget(T);
  FreeAndNil(G.ZPlan);
  if G.ZView <> 0 then
    FAPI.vkDestroyImageView(FDevice, G.ZView, nil);
  if G.InActiveTargets then
    for var I := 0 to FActiveCount - 1 do
      if FActiveTargets[I] = G then
      begin
        Dec(FActiveCount);
        FActiveTargets[I] := FActiveTargets[FActiveCount];
        G.InActiveTargets := False;
        Break;
      end;
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
function TPS2GSVulkanHLE.DrawPipeline(Key: UInt64; var Pass: TPS2HLEPass): VkPipeline;
begin
  if FDirectSampling then
    Key := Key or (UInt64(1) shl 25);
  Pass.NativeKey := Key;
  if FDynDepth then
    Key := Key and not (UInt64($1F) shl 17);
  if FDynColor then
    Key := Key and not UInt64($1FFFF);
  Result := Pipeline(Key);
end;

procedure TPS2GSVulkanHLE.ApplyDynamic(Key: UInt64; NewPipe: Boolean);
begin
  var Diff := Key xor FPrevKey;
  if NewPipe or not FDynKnown then
    Diff := High(UInt64);
  var Cmd := Slot.Cmd.Handle;
  if FDynDepth and ((Diff and (UInt64($1F) shl 17)) <> 0) then
  begin
    if (Diff and (UInt64(1) shl 17)) <> 0 then
      FDepthTestCmd(Cmd, (Key shr 17) and 1);
    if (Diff and (UInt64(1) shl 18)) <> 0 then
      FDepthWriteCmd(Cmd, (Key shr 18) and 1);
    if (Diff and (UInt64(7) shl 19)) <> 0 then
      FDepthCompareCmd(Cmd, (Key shr 19) and 7);
  end;
  if FDynColor and ((Key and (UInt64(1) shl 22)) = 0) and ((Diff and $1FFFF) <> 0) then
  begin
    var E := Cardinal(Key and 1);
    var Mask := Cardinal((Key shr 13) and 15);
    var Blend: TVkBlendEquation;
    Blend.SourceColor := (Key shr 1) and 31;
    Blend.DestinationColor := (Key shr 6) and 31;
    Blend.ColorOp := (Key shr 11) and 3;
    Blend.SourceAlpha := VK_BLEND_FACTOR_ONE;
    Blend.DestinationAlpha := VK_BLEND_FACTOR_ZERO;
    Blend.AlphaOp := VK_BLEND_OP_ADD;
    if (Diff and 1) <> 0 then
      FColorEnableCmd(Cmd, 0, 1, @E);
    if (Diff and $1FFE) <> 0 then
      FColorEquationCmd(Cmd, 0, 1, @Blend);
    if (Diff and $1E000) <> 0 then
      FColorMaskCmd(Cmd, 0, 1, @Mask);
  end;
  FDynKnown := True;
  FPrevKey := Key;
end;

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
  dynamic: VkPipelineDynamicStateCreateInfo;
  DynamicStates: array[0..7] of VkDynamicState;
  Info: VkGraphicsPipelineCreateInfo;
begin
  for var I := 0 to 1 do
  begin
    Stages[I] := Default(VkPipelineShaderStageCreateInfo);
    Stages[I].sType := VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    Stages[I].pName := PAnsiChar(PS2GSEntryPoint);
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
  Attributes[0].Binding := 0;
  Attributes[0].Format := VK_FORMAT_R32G32B32_SFLOAT;
  Attributes[0].offset := 0;
  Attributes[1].location := 1;
  Attributes[1].Binding := 0;
  Attributes[1].Format := VK_FORMAT_R8G8B8A8_UNORM;
  Attributes[1].offset := 12;
  Attributes[2].location := 2;
  Attributes[2].Binding := 0;
  Attributes[2].Format := VK_FORMAT_R32G32B32_SFLOAT;
  Attributes[2].offset := 16;
  Attributes[3].location := 3;
  Attributes[3].Binding := 0;
  Attributes[3].Format := VK_FORMAT_R32G32_SFLOAT;
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
  dynamic := Default(VkPipelineDynamicStateCreateInfo);
  dynamic.sType := VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
  dynamic.dynamicStateCount := 2;
  if FDynDepth then
  begin
    DynamicStates[2] := VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE;
    DynamicStates[3] := VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE;
    DynamicStates[4] := VK_DYNAMIC_STATE_DEPTH_COMPARE_OP;
    dynamic.dynamicStateCount := 5;
  end;
  if FDynColor and not Blended then
  begin
    var Id := dynamic.dynamicStateCount;
    DynamicStates[Id] := VK_DYNAMIC_STATE_COLOR_BLEND_ENABLE_EXT;
    DynamicStates[Id + 1] := VK_DYNAMIC_STATE_COLOR_BLEND_EQUATION_EXT;
    DynamicStates[Id + 2] := VK_DYNAMIC_STATE_COLOR_WRITE_MASK_EXT;
    Inc(dynamic.dynamicStateCount, 3);
  end;
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
    BlendState.attachmentCount := 0;
    BlendState.pAttachments := nil;
    Info.layout := FBlendLayout;
    Info.renderPass := FBlendPass;
  end;
  if ((Key shr 25) and 1) <> 0 then
    Stages[1].module := FDirectProgram[Blended];
  Info.basePipelineIndex := -1;
  CheckVulkan(FAPI.vkCreateGraphicsPipelines(FDevice, 0, 1, @Info, nil, @Result), 'vkCreateGraphicsPipelines');
end;

{ GS memory: byte addresses, wrapping round its 4 MiB }

function TPS2GSVulkanHLE.MemoryEquals(Addr: Cardinal; Data: PByte; Size: Cardinal): Boolean;
begin
  var A := Addr and MemMask;
  var First := Min(Size, PS2GSMemorySize - A);
  Result := VulkanHLEEqualBytes(FMemory.Data + A, Data, First) and ((First = Size) or
    VulkanHLEEqualBytes(FMemory.Data, Data + First, Size - First));
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

function TPS2GSVulkanHLE.FitsTarget(const D: TPS2GSDraw; LastY: Integer): Boolean;
begin
  Result := True;
  if FScale = 1 then
    Exit;
  var WidthLimit := Min(Integer(FCompute.Properties.limits.maxImageDimension2D),
    Integer(FCompute.Properties.limits.maxFramebufferWidth));
  var HeightLimit := Min(Integer(FCompute.Properties.limits.maxImageDimension2D),
    Integer(FCompute.Properties.limits.maxFramebufferHeight));
  var Stride := Integer(D.FBW * 64);
  var Rows := PageRowsOf(D.FPSM);
  var Height := Min(2048, Integer(PS2GSMemorySize div (Cardinal(Stride) * PixelBytesOf(D.FPSM))));
  Height := Min(RoundRows(LastY + 1, Rows), Height - Height mod Rows);
  Result := (Stride * FScale <= WidthLimit) and (Height * FScale <= HeightLimit);
end;

// The target D draws into, whole page rows as tall as FNeedY needs.
function TPS2GSVulkanHLE.TargetFor(const D: TPS2GSDraw): TPS2HLETarget;
begin
  var PB := PixelBytesOf(D.FPSM);
  var Stride := D.FBW * 64;
  var PH := PageRowsOf(D.FPSM);
  var MaxH := Min(2048, Integer(PS2GSMemorySize div (Stride * PB)));
  // At 1x the image need not reach beyond the scissor: fewer rows to load,
  // store and keep coherent with other targets.
  if FScale = 1 then
    MaxH := Min(MaxH, RoundRows(D.SY1 + 1, PH));
  if FScale > 1 then
    MaxH := Min(MaxH, Min(Integer(FCompute.Properties.limits.maxImageDimension2D),
        Integer(FCompute.Properties.limits.maxFramebufferHeight)) div FScale);
  MaxH := MaxH - MaxH mod PH;
  var Need := Min(RoundRows(FNeedY + 1, PH), MaxH);
  Result := TPS2HLETarget(FindTarget((D.FBP shl 8) and MemMask, D.FPSM, Stride, PB, Need, Need, MaxH));
end;

// Other targets newer than GS memory in Pages (which T is about to draw):
// those whose drawn rows meet them go back to GS memory first; the others'
// images there become older than what T draws (stale).
function PageSpan(Base, Size: Cardinal): TPageSpan; inline;
begin
  Result.Base := Base;
  Result.Size := Size;
  Result.First := (Base shr PageShift) and 511;
  Result.Count := 0;
  if Size <> 0 then
    Result.Count :=
      Min(UInt64(512), ((Base and ((1 shl PageShift) - 1)) + UInt64(Size) + (1 shl PageShift) - 1) shr PageShift);
end;

function SpanHits(const A, B: TPageSpan): Boolean; inline;
begin
  Result :=
    (A.Count <> 0)
    and (B.Count <> 0)
    and ((((A.First + 512 - B.First) and 511) < B.Count) or (((B.First + 512 - A.First) and 511) < A.Count));
end;

procedure TPS2GSVulkanHLE.ActivateTarget(T: TPS2HLETarget);
begin
  if T.InActiveTargets then
    Exit;
  if FActiveCount = Length(FActiveTargets) then
    SetLength(FActiveTargets, FActiveCount + 16);
  FActiveTargets[FActiveCount] := T;
  Inc(FActiveCount);
  T.InActiveTargets := True;
end;

procedure TPS2GSVulkanHLE.CheckDestSpans(T: TPS2HLETarget; const C, Z: TPageSpan);
var
  Mine: TPS2GSPages;
  MarkC, MarkZ: array[0..31] of TPS2HLETarget;

  function Hits(Base, Size: Cardinal): Boolean;
  begin
    var Other := PageSpan(Base, Size);
    Result := SpanHits(C, Other) or SpanHits(Z, Other);
  end;

  procedure MakePages;
  begin
    FillChar(Mine, SizeOf(Mine), 0);
    AddRange(Mine, C.Base, C.Size);
    AddRange(Mine, Z.Base, Z.Size);
  end;

begin
  if FActiveCount > Length(MarkC) then
  begin
    MakePages;
    FlushOthers(T, Mine);
    Exit;
  end;
  Inc(FSpanCalls);
  var NC := 0;
  var NZ := 0;
  var I := 0;
  var Held := False;
  while I < FActiveCount do
  begin
    var U := FActiveTargets[I];
    if not U.Dirty and not U.ZDirty then
    begin
      U.InActiveTargets := False;
      Dec(FActiveCount);
      FActiveTargets[I] := FActiveTargets[FActiveCount];
      Continue;
    end;
    Inc(I);
    if U = T then
      Continue;
    if U.Dirty then
    begin
      var Row := U.Stride * U.PixelBytes;
      if (U.HeldY1 <= U.HeldY2)
        and Hits(U.Addr + Cardinal(U.HeldY1) * Row, Cardinal(U.HeldY2 - U.HeldY1 + 1) * Row) then
        Held := True;
      if not U.Stale and Hits(U.Addr, U.Bytes) then
      begin
        MarkC[NC] := U;
        Inc(NC);
      end;
    end;
    if U.ZDirty then
    begin
      if (U.ZHeldY1 <= U.ZHeldY2)
        and Hits(U.ZAddr + Cardinal(U.ZHeldY1) * U.ZRowBytes, Cardinal(U.ZHeldY2 - U.ZHeldY1 + 1) * U.ZRowBytes) then
        Held := True;
      if not U.ZStale and Hits(U.ZAddr, U.ZBytes) then
      begin
        MarkZ[NZ] := U;
        Inc(NZ);
      end;
    end;
    if Held then
      Break;
  end;
  if Held then
  begin
    // Actual stores still traverse FTargets in the original order.
    Inc(FSpanStores);
    MakePages;
    FlushOthers(T, Mine);
    Exit;
  end;
  for var J := 0 to NC - 1 do
    MarkC[J].Stale := True;
  for var J := 0 to NZ - 1 do
    MarkZ[J].ZStale := True;
end;

procedure TPS2GSVulkanHLE.FlushOthers(T: TPS2HLETarget; const Pages: TPS2GSPages);
var
  Part: TPS2GSPages;
begin
  var Held := False;
  for var V in FTargets do
  begin
    var U := TPS2HLETarget(V);
    if U = T then
      Continue;
    if U.Dirty and (U.HeldY1 <= U.HeldY2) then
    begin
      FillChar(Part, SizeOf(Part), 0);
      AddRange(Part, U.Addr + Cardinal(U.HeldY1) * U.Stride * U.PixelBytes,
        Cardinal(U.HeldY2 - U.HeldY1 + 1) * U.Stride * U.PixelBytes);
      Held := Held or Meets(Part, Pages);
    end;
    if U.ZDirty and (U.ZHeldY1 <= U.ZHeldY2) then
    begin
      FillChar(Part, SizeOf(Part), 0);
      AddRange(Part, U.ZAddr + Cardinal(U.ZHeldY1) * U.ZRowBytes, Cardinal(U.ZHeldY2 - U.ZHeldY1 + 1) * U.ZRowBytes);
      Held := Held or Meets(Part, Pages);
    end;
  end;
  if Held then
  begin
    Inc(FFlushes[frOthers]);
    StoreOverlapping(Pages);
  end;
  for var V in FTargets do
  begin
    var U := TPS2HLETarget(V);
    if U = T then
      Continue;
    if U.Dirty and not U.Stale then
    begin
      FillChar(Part, SizeOf(Part), 0);
      AddRange(Part, U.Addr, U.Bytes);
      if Meets(Part, Pages) then
        U.Stale := True;
    end;
    if U.ZDirty and not U.ZStale then
    begin
      FillChar(Part, SizeOf(Part), 0);
      AddRange(Part, U.ZAddr, U.ZBytes);
      if Meets(Part, Pages) then
        U.ZStale := True;
    end;
  end;
end;

function TPS2GSVulkanHLE.BandRows(T: TVulkanHLETarget): Integer;
begin
  Result := EnsureRange((HLEUploadCapacity div 2) div (T.Width * FScale * FScale * 4), 1, T.Height);
end;

const
  MirrorEnabled = True;

const
  PinAudit = False;

const
  ScopePins = True;
  AuditScopePins = False;

function TPS2GSVulkanHLE.NativePin(Index: Integer): TBytes;
begin
  var Src := FMemory.Data + Index * 4096;
  if FPinScope and (FPinSeen[Index] = FPinEpoch) then
  begin
    if AuditScopePins then
    begin
      if not VulkanHLEEqualBytes(Src, Pointer(FNativePins[Index]), 4096) then
        raise Exception.Create('Native GS page changed inside an exclusive renderer call');
      Inc(FProofBytes, 4096);
    end;
    Inc(FNativeFast, 4096);
    Exit(FNativePins[Index]);
  end;
  if FPinScope then
    FPinSeen[Index] := FPinEpoch;
  if ScopePins
    and (FGPUPins[Index] <> nil)
    and (Pointer(FGPUPins[Index]) <> Pointer(FNativePins[Index]))
    and VulkanHLEEqualBytes(Src, Pointer(FGPUPins[Index]), 4096) then
  begin
    FNativePins[Index] := FGPUPins[Index];
    Inc(FReverted, 4096);
    Exit(FNativePins[Index]);
  end;
  if (FNativePins[Index] <> nil) and VulkanHLEEqualBytes(Src, Pointer(FNativePins[Index]), 4096) then
    Inc(FPinReused, 4096)
  else
  begin
    // Never change a physical page retained by a target or by the device
    // mirror. A raw CPU store is always verified on the next acquisition.
    if (FNativePins[Index] = nil) or (EmulationBufferReferences(Pointer(FNativePins[Index])) <> 1) then
    begin
      FNativePins[Index] := nil;
      SetLength(FNativePins[Index], 4096);
    end;
    Move(Src^, FNativePins[Index][0], 4096);
    Inc(FPinCopied, 4096);
  end;
  Result := FNativePins[Index];
end;

function TPS2GSVulkanHLE.PinMatch(T: TPS2HLETarget; Z: Boolean; Off, Bytes: Cardinal): Boolean;
begin
  Result := False;
  if (Bytes = 0)
    or ((Off or Bytes) and 4095 <> 0)
    or (UInt64(Off) + Bytes > UInt64(Length(T.Pins[Z].Pages)) * 4096) then
    Exit;
  var Base := T.Pins[Z].Base;
  for var P := Integer(Off shr 12) to Integer((Off + Bytes) shr 12) - 1 do
  begin
    var Pg := (Integer(Base shr 12) + P) and 1023;
    var Source := FMemory.Data + Pg * 4096;
    if FPinScope and (FPinSeen[Pg] = FPinEpoch) and (Pointer(FNativePins[Pg]) = Pointer(T.Pins[Z].Pages[P])) then
    begin
      if AuditScopePins then
      begin
        if not VulkanHLEEqualBytes(Source, Pointer(T.Pins[Z].Pages[P]), 4096) then
          raise Exception.Create('Target shadow changed inside an exclusive renderer call');
        Inc(FProofBytes, 4096);
      end;
      Inc(FMatchFast, 4096);
    end
    else
    begin
      if not VulkanHLEEqualBytes(Source, Pointer(T.Pins[Z].Pages[P]), 4096) then
        Exit;
      if FPinScope then
      begin
        FNativePins[Pg] := T.Pins[Z].Pages[P];
        FPinSeen[Pg] := FPinEpoch;
      end;
    end;
  end;
  Result := True;
end;

function TPS2GSVulkanHLE.CapturePins(T: TPS2HLETarget; Z: Boolean; First, Bytes: Cardinal): Boolean;
begin
  Result := False;
  var Base := T.Addr;
  var Total := T.Bytes;
  if Z then
  begin
    Base := T.ZAddr;
    Total := T.ZBytes;
  end;
  if not FUsePagePins
    or (FScale <= 1)
    or (Total = 0)
    or (Total > PS2GSMemorySize)
    or (((Base or Total or First or Bytes) and 4095) <> 0)
    or (UInt64(First) + Bytes > Total) then
  begin
    T.Pins[Z].Pages := nil;
    FJustUploaded := nil;
    Exit;
  end;
  if (T.Pins[Z].Base <> Base) or (Length(T.Pins[Z].Pages) <> Integer(Total shr 12)) then
  begin
    First := 0;
    Bytes := Total;
    SetLength(T.Pins[Z].Pages, Total shr 12);
    T.Pins[Z].Base := Base;
  end;
  var Immediate := (FJustUploaded = T) and (FJustDepth = Z);
  FJustUploaded := nil;
  for var I := Integer(First shr 12) to Integer((First + Bytes) shr 12) - 1 do
  begin
    var P := (Integer(Base shr 12) + I) and 1023;
    if Immediate then
    begin
      if FGPUPins[P] = nil then
        raise Exception.Create('Missing uploaded GS page');
      T.Pins[Z].Pages[I] := FGPUPins[P];
      Inc(FAfterUpload, 4096);
    end
    else
      T.Pins[Z].Pages[I] := NativePin(P);
    if PinAudit then
    begin
      if not VulkanHLEEqualBytes(FMemory.Data + P * 4096, Pointer(T.Pins[Z].Pages[I]), 4096) then
        raise Exception.Create('Stale shadow capture');
      Inc(FValidated, 4096);
    end;
  end;
  Result := not PinAudit;
  if Result then
    if Z then
      T.ZShadow := nil
    else
      T.Shadow := nil;
end;

function TPS2GSVulkanHLE.CaptureColor(T: TVulkanHLETarget; Whole: Boolean): Boolean;
begin
  var First: Cardinal := 0;
  var Count := T.Bytes;
  if not Whole and (T.HeldY1 <= T.HeldY2) then
  begin
    var Row := T.Stride * T.PixelBytes;
    First := Cardinal(T.HeldY1) * Row;
    Count := Cardinal(T.HeldY2 - T.HeldY1 + 1) * Row;
  end;
  Result := CapturePins(TPS2HLETarget(T), False, First, Count);
end;

function TPS2GSVulkanHLE.ShadowMatches(T: TVulkanHLETarget): Boolean;
begin
  var U := TPS2HLETarget(T);
  if (not FUsePagePins) or (U.Pins[False].Pages = nil) then
    Exit(inherited ShadowMatches(T));
  Result := PinMatch(U, False, 0, T.Bytes);
  if PinAudit and (Result <> inherited ShadowMatches(T)) then
    raise Exception.Create('Colour page identity disagrees');
end;

function TPS2GSVulkanHLE.DepthMatches(T: TPS2HLETarget): Boolean;
begin
  if (not FUsePagePins) or (T.Pins[True].Pages = nil) then
    Exit((Cardinal(Length(T.ZShadow)) = T.ZBytes) and MemoryEquals(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow)));
  Result := (T.Pins[True].Base = T.ZAddr) and PinMatch(T, True, 0, T.ZBytes);
  if PinAudit
    and (Result
    <> ((Cardinal(Length(T.ZShadow)) = T.ZBytes) and MemoryEquals(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow)))) then
    raise Exception.Create('Depth page identity disagrees');
end;

procedure TPS2GSVulkanHLE.PrepareMirror;
begin
  if FMirrorRAM <> nil then
    Exit;
  FMirrorRAM :=
    FCompute
    .CreateBuffer(PS2GSMemorySize, vbkDevice, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_DST_BIT);
  if not FUsePagePins then
    SetLength(FMirrorShadow, PS2GSMemorySize);
end;

procedure TPS2GSVulkanHLE.SyncMirror(Addr, Size: Cardinal);
var
  First: Integer;

  procedure Send(Last: Integer);
  begin
    var At := First * 4096;
    var Bytes := (Last - First) * 4096;
    var Off: Int64;
    var P := StageUpload(Bytes, Off);
    Move((FMemory.Data + At)^, P^, Bytes);
    if not FUsePagePins then
      Move((FMemory.Data + At)^, FMirrorShadow[At], Bytes);
    Slot.Upload.Flush(Off, Bytes);
    Slot.Cmd.Copy(Slot.Upload, FMirrorRAM, Off, At, Bytes);
    Inc(FMirrorSent, Bytes);
    First := -1;
  end;

begin
  if Size = 0 then
    Exit;
  if UInt64(Addr) + Size > PS2GSMemorySize then
    raise Exception.Create('Unsplit GPU memory range');
  First := -1;
  var Last := (Addr + Size - 1) shr 12;
  for var I := Integer(Addr shr 12) to Integer(Last) do
  begin
    var Same: Boolean;
    if FUsePagePins then
    begin
      var Pin := NativePin(I);
      Same := Pointer(Pin) = Pointer(FGPUPins[I]);
      FGPUPins[I] := Pin;
    end
    else
      Same := FMirrorValid[I] and VulkanHLEEqualBytes(FMemory.Data + I * 4096, @FMirrorShadow[I * 4096], 4096);
    if Same then
    begin
      Inc(FMirrorReused, 4096);
      if First >= 0 then
        Send(I);
    end
    else
    begin
      FMirrorValid[I] := True;
      if First < 0 then
        First := I;
    end;
  end;
  if First >= 0 then
    Send(Integer(Last) + 1);
end;

function TPS2GSVulkanHLE.DecodeImage(T: TVulkanHLETexture; Level, W, H: Integer; const Push; Size: Cardinal): Boolean;
const
  SetsPerSlot = 32;
begin
  Result := False;
  if not FTextureStore
    or (T.Image.Usage and VK_IMAGE_USAGE_STORAGE_BIT = 0)
    or (Level <> 0)
    or (T.Levels <> 1)
    or (T.Width <> W)
    or (T.Height <> H)
    or (T.Scale <> 1) then
    Exit;
  var S := Slot;
  var Id := 0;
  while (Id < Length(FDecodeBanks))
    and (FDecodeBanks[Id].Upload <> 0)
    and (FDecodeBanks[Id].Upload <> S.Upload.Handle) do
    Inc(Id);
  if Id = Length(FDecodeBanks) then
    Exit;
  if FImageDecode = nil then
    FImageDecode :=
      TVulkanKernel.Create(
      FCompute,
      PS2GSKernelCode(TPS2GSKernel.DecodeImage),
      2,
      Size,
      [],
      SetsPerSlot * Length(FDecodeBanks),
      'main',
      1
    );
  FDecodeBanks[Id].Upload := S.Upload.Handle;
  if FDecodeBanks[Id].RecordingNumber <> S.RecordingNumber then
  begin
    // Record_ starts a new recording only after this slot's fence completes.
    FDecodeBanks[Id].Issued := 0;
    FDecodeBanks[Id].RecordingNumber := S.RecordingNumber;
  end;
  if FDecodeBanks[Id].Issued >= SetsPerSlot then
  begin
    Inc(FImageSetLimit);
    Exit;
  end;
  var SetId := Id * SetsPerSlot + FDecodeBanks[Id].Issued;
  if FDecodeBanks[Id].Issued = FDecodeBanks[Id].Initialized then
  begin
    FImageDecode.Bind(SetId, 0, FMirrorRAM);
    FImageDecode.Bind(SetId, 1, S.Upload);
    Inc(FDecodeBanks[Id].Initialized);
  end;
  Inc(FDecodeBanks[Id].Issued);
  FImageDecode.BindImage(SetId, 0, T.Image.View);
  FImageDecode.ActiveSet := SetId;
  ImageBarrier;
  S.Cmd.Dispatch(FImageDecode, (W + 7) div 8, (H + 7) div 8, 1, Push, Size);
  ImageBarrier;
  Inc(FImageDecodes);
  Inc(FImageTexels, Int64(W) * H);
  Result := True;
end;

function TPS2GSVulkanHLE.DecodeMirror(T: TVulkanHLETexture; Request: Pointer; L, X, Y, W, H: Integer; Palette: PCardinal; Count: Integer): Boolean;
type
  TPush = packed record
    BP, BW, Format, X, Y, W, H, PaletteAt, TA0, TA1, AEM: Cardinal;
  end;
begin
  Result := False;
  var R := PPS2HLETexRequest(Request);
  var D := R.D;
  if not MirrorEnabled
    or (T.Scale <> 1)
    or (W * H < 2048)
    or (W * H > 1048576)
    or not (D.TPSM
    in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S, PSMZ32, PSMZ24, PSMZ16, PSMZ16S, PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH])
    or (Slot.Upload.Size > FCompute.Properties.limits.maxStorageBufferRange) then
    Exit;
  if not FTexGathered then
    raise Exception.Create('GPU decoder without a closed source footprint');
  PrepareMirror;
  Record_;
  EndPass;
  Slot.Cmd.FullBarrier;
  for var I := 0 to FTexByteCount - 1 do
    if FTexBytes[I].Data <> @FClutCopy[0] then
      SyncMirror(Cardinal(PByte(FTexBytes[I].Data) - FMemory.Data), FTexBytes[I].Size);
  var Off: Int64 := 0;
  if Count > 0 then
  begin
    var Data := StageUpload(4 * Count, Off);
    Move(Palette^, Data^, Count * 4);
    Slot.Upload.Flush(Off, 4 * Count);
  end;
  var P: TPush;
  P.BP := D.LevelTBP[L];
  P.BW := D.LevelTBW[L];
  P.Format := D.TPSM;
  P.X := X;
  P.Y := Y;
  P.W := W;
  P.H := H;
  P.PaletteAt := Off div 4;
  P.TA0 := D.TA0;
  P.TA1 := D.TA1;
  P.AEM := Ord(D.AEM);
  if DecodeImage(T, L, W, H, P, SizeOf(P)) then
  begin
    Inc(FMirrorLevels);
    Inc(FMirrorTexels, Int64(W) * H);
    Exit(True);
  end;
  if FMirrorKernel = nil then
  begin
    FMirrorDecoded :=
      FCompute.CreateBuffer(
      PS2GSMemorySize,
      vbkDevice,
      VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT
    );
    FMirrorKernel := FCompute.CreateKernel(PS2GSKernelCode(TPS2GSKernel.MirrorDecode), 3, SizeOf(TPush), [], 4);
  end;
  var Id := 0;
  while (Id < 4) and (FDecodeSources[Id] <> 0) and (FDecodeSources[Id] <> Slot.Upload.Handle) do
    Inc(Id);
  if Id = 4 then
    Exit;
  if FDecodeSources[Id] = 0 then
  begin
    FMirrorKernel.Bind(Id, 0, FMirrorRAM);
    FMirrorKernel.Bind(Id, 1, FMirrorDecoded);
    FMirrorKernel.Bind(Id, 2, Slot.Upload);
    FDecodeSources[Id] := Slot.Upload.Handle;
  end;
  Slot.Cmd.FullBarrier;
  FMirrorKernel.ActiveSet := Id;
  Slot.Cmd.Dispatch(FMirrorKernel, (W + 7) div 8, (H + 7) div 8, 1, P, SizeOf(P));
  Slot.Cmd.FullBarrier;
  var Region := Default(VkBufferImageCopy);
  Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.imageSubresource.layerCount := 1;
  Region.imageSubresource.mipLevel := L;
  Region.imageExtent.width := W;
  Region.imageExtent.height := H;
  Region.imageExtent.depth := 1;
  FAPI
    .vkCmdCopyBufferToImage(Slot.Cmd.Handle, FMirrorDecoded.Handle, T.Image.Image, VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
  Inc(FMirrorLevels);
  Inc(FMirrorTexels, Int64(W) * H);
  Result := True;
end;

function TPS2GSVulkanHLE.UploadSet(Buffer: TVulkanBuffer): Integer;
begin
  if FUploadKernel = nil then
  begin
    FUploadScratch :=
      FCompute.CreateBuffer(
      HLEUploadCapacity,
      vbkDevice,
      VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT
    );
    FUploadKernel :=
      FCompute.CreateKernel(
      PS2GSKernelCode(TPS2GSKernel.HLEUpload, FScale),
      2,
      SizeOf(TPS2HLEUploadPush),
      [],
      Length(FUploadSources)
    );
  end;
  for var I := 0 to FUploadSourceCount - 1 do
    if FUploadSources[I] = Buffer.Handle then
      Exit(I);
  Result := -1;
  if FUploadSourceCount >= Length(FUploadSources) then
    Exit;
  Result := FUploadSourceCount;
  // Sets are immutable after their first use: earlier queued dispatches may
  // still refer to this same staging buffer and the shared scratch buffer.
  FUploadKernel.Bind(Result, 0, Buffer);
  FUploadKernel.Bind(Result, 1, FUploadScratch);
  FUploadSources[Result] := Buffer.Handle;
  Inc(FUploadSourceCount);
end;

// A target's colour (any frame format) or its 24/16-bit depth loaded on the
// GPU: the raw GS bytes are staged, the compute shader unswizzles them into
// the image's layout with integer operations only (16/24-bit depth values
// have at most 24 significant bits, so their normalized Single is built
// exactly), then copied into the image. False: the CPU path loads it.
const
  ImageLoadEnabled = True;

function TPS2GSVulkanHLE.LoadColorImage(T: TPS2HLETarget; Addr: Cardinal): Boolean;
begin
  Result := False;
  if not ImageLoadEnabled or (FScale <> 2) or not FShaderBlend then
    Exit;
  var Id := -1;
  var Free := -1;
  for var I := 0 to High(FImageOwners) do
  begin
    if FImageOwners[I] = T then
    begin
      Id := I;
      Break;
    end;
    if (Free < 0) and (FImageOwners[I] = nil) then
      Free := I;
  end;
  if Id < 0 then
  begin
    if Free < 0 then
      Exit;
    Id := Free;
    if FImageLoader = nil then
      FImageLoader :=
        TVulkanKernel.Create(
        FCompute,
        PS2GSKernelCode(TPS2GSKernel.ColorLoad2),
        1,
        SizeOf(TPS2HLEUploadPush),
        [],
        Length(FImageOwners),
        'main',
        1
      );
    // The previous target leaves this slot only after its GPU work is done.
    FImageLoader.Bind(Id, 0, FMirrorRAM);
    FImageLoader.BindImage(Id, 0, T.Color.View);
    FImageOwners[Id] := T;
  end;
  var P := Default(TPS2HLEUploadPush);
  P.OffsetWords := Addr div 4;
  P.WidthPages := T.Stride shr 6;
  P.Format := T.Format;
  P.Width := T.Width;
  P.Height := T.Height;
  P.Scale := 2;
  ImageBarrier;
  FImageLoader.ActiveSet := Id;
  Slot.Cmd.Dispatch(FImageLoader, (P.Width + 7) div 8, (P.Height + 7) div 8, 1, P, SizeOf(P));
  ImageBarrier;
  Inc(FDirectLoads);
  Inc(FDirectPixels, Int64(P.Width) * P.Height * 4);
  Result := True;
end;

function TPS2GSVulkanHLE.UploadTargetGpu(T: TPS2HLETarget; Depth: Boolean): Boolean;
var
  Push: TPS2HLEUploadPush;
  Region: VkBufferImageCopy;
begin
  FJustUploaded := nil;
  Result := False;
  // Small native targets are cheaper on the CPU than a dispatch.
  if (FScale = 1) and (Int64(T.Width) * T.Height < 16384) then
    Exit;
  var Addr := T.Addr;
  var Format := T.Format;
  var Bytes := T.Bytes;
  var Image := T.Color.Image;
  var Aspect: Cardinal := VK_IMAGE_ASPECT_COLOR_BIT;
  if Depth then
  begin
    if FD24 or not (T.ZPSM in [PSMZ24, PSMZ16, PSMZ16S]) then
      Exit;
    Addr := T.ZAddr;
    Format := T.ZPSM;
    Bytes := T.ZBytes;
    Image := T.Depth.Image;
    Aspect := VK_IMAGE_ASPECT_DEPTH_BIT;
  end
  else if not (Format in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S]) then
    Exit;
  if (Bytes > PS2GSMemorySize)
    or (Bytes > HLEUploadCapacity)
    or (Slot.Upload.Size > FCompute.Properties.limits.maxStorageBufferRange) then
    Exit;
  var Offset: Int64;
  var SetIndex: Integer;
  if MirrorEnabled and (UInt64(Addr) + Bytes <= PS2GSMemorySize) then
  begin
    PrepareMirror;
    Record_;
    EndPass;
    Slot.Cmd.FullBarrier;
    SyncMirror(Addr, Bytes);
    if not Depth and LoadColorImage(T, Addr) then
    begin
      Inc(FColorGpuLoads);
      if FUsePagePins then
      begin
        FJustUploaded := T;
        FJustDepth := False;
      end;
      Exit(True);
    end;
    Offset := Addr;
    SetIndex := UploadSet(FMirrorRAM);
  end
  else
  begin
    var P := StageUpload(Bytes, Offset);
    ReadMemory(Addr, P, Bytes);
    Slot.Upload.Flush(Offset, Bytes);
    SetIndex := UploadSet(Slot.Upload);
  end;
  if SetIndex < 0 then
    Exit;
  FUploadKernel.ActiveSet := SetIndex;
  Push.OffsetWords := Cardinal(Offset div 4);
  Push.WidthPages := T.Stride shr 6;
  Push.Format := Format;
  Push.Scale := FScale;
  Push.Width := T.Width * FScale;
  Push.Depth := Ord(Depth);
  var Rows := BandRows(T);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    Push.Height := N * FScale;
    Push.FirstY := Y0;
    // Also orders the previous copy's read before the next scratch overwrite.
    Slot.Cmd.FullBarrier;
    Slot.Cmd.Dispatch(FUploadKernel, (Push.Width + 7) div 8, (Push.Height + 7) div 8, 1, Push, SizeOf(Push));
    Slot.Cmd.FullBarrier;
    Region := Default(VkBufferImageCopy);
    Region.imageSubresource.aspectMask := Aspect;
    Region.imageSubresource.layerCount := 1;
    Region.imageOffset.y := Y0 * FScale;
    Region.imageExtent.width := Push.Width;
    Region.imageExtent.height := Push.Height;
    Region.imageExtent.depth := 1;
    FAPI.vkCmdCopyBufferToImage(Slot.Cmd.Handle, FUploadScratch.Handle, Image, VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
    ImageBarrier;
    Inc(Y0, N);
  end;
  if Depth then
    Inc(FDepthGpuLoads)
  else
    Inc(FColorGpuLoads);
  if FUsePagePins and MirrorEnabled and (UInt64(Addr) + Bytes <= PS2GSMemorySize) then
  begin
    FJustUploaded := T;
    FJustDepth := Depth;
  end;
  Result := True;
end;

// GS memory's pixels into the colour image.
procedure TPS2GSVulkanHLE.LoadTarget(T: TVulkanHLETarget);
var
  A: TPS2GSAddressing;
begin
  if UploadTargetGpu(TPS2HLETarget(T), False) then
    Exit;
  A.Init(Integer(T.Format), T.Addr shr 8, T.Stride shr 6);
  var Rows := BandRows(T);
  var PageRows := PageRowsOf(T.Format);
  var Partial := (FScale = 1) and T.Loaded and (T.Format in [PSMCT32, PSMCT24]) and
    (Cardinal(Length(T.Shadow)) = T.Bytes) and (Rows >= PageRows);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    if Partial then
    begin
      N := PS2HLEChangedRows(FMemory, T.Addr, T.Stride * T.PixelBytes, T.Height,
        PageRows, Rows, T.Shadow, Y0);
      if N = 0 then
        Break;
    end;
    var Offset: Int64;
    var P := PCardinal(StageUpload(Int64(T.Width) * N * FScale * FScale * 4, Offset));
    for var Y := Y0 to Y0 + N - 1 do
    begin
      if FScale = 1 then
        PS2HLELoadColorRow(FMemory, A, T.Format, Y, 0, T.Width, P)
      else
      begin
        if Length(FStoreRow) < T.Width then
          SetLength(FStoreRow, T.Width);
        PS2HLELoadColorRow(FMemory, A, T.Format, Y, 0, T.Width, @FStoreRow[0]);
        for var X := 0 to T.Width - 1 do
          for var K := 0 to FScale - 1 do
            P[X * FScale + K] := FStoreRow[X];
        for var K := 1 to FScale - 1 do
          Move(P^, P[T.Width * FScale * K], T.Width * FScale * 4);
      end;
      Inc(P, T.Width * FScale * FScale);
    end;
    CopyToImage(T.Color.Image, VK_IMAGE_ASPECT_COLOR_BIT, Offset, 0, 0, Y0 * FScale,
      T.Width * FScale, N * FScale);
    Inc(Y0, N);
  end;
end;

function TPS2GSVulkanHLE.DepthOf(const D: TPS2GSDraw; Z: Cardinal): Single;
begin
  // Without depth clamping the GPU clips past the range: clamped per vertex.
  if not FDepthClamp and (Z > D.ZMax) then
    Z := D.ZMax;
  Result := Z / FZScale;
end;

procedure TPS2GSVulkanHLE.LoadDepth(T: TPS2HLETarget; ChangedOnly: Boolean);
var
  A: TPS2GSAddressing;
begin
  FZScale := DepthRange(T.ZPSM);
  if UploadTargetGpu(T, True) then
  begin
    if not CapturePins(T, True, 0, T.ZBytes) then
    begin
      SetLength(T.ZShadow, T.ZBytes);
      ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
    end;
    T.ZLoaded := True;
    T.ZReloadRows := 0;
    Inc(FDepthLoads);
    Exit;
  end;
  A.Init(Integer(T.ZPSM), T.ZAddr shr 8, T.Stride shr 6);
  var Rows := BandRows(T);
  var PageRows := PageRowsOf(T.ZPSM);
  var Partial :=
    ChangedOnly and (FScale = 1) and not FD24 and (Cardinal(Length(T.ZShadow)) = T.ZBytes) and (Rows >= PageRows);
  var Y0 := 0;
  while Y0 < T.Height do
  begin
    var N := Min(Rows, T.Height - Y0);
    if Partial then
    begin
      N := PS2HLEChangedRows(FMemory, T.ZAddr, T.ZRowBytes, T.Height, PageRows, Rows, T.ZShadow, Y0, T.ZReloadRows);
      if N = 0 then
        Break;
    end;
    var Offset: Int64;
    var P := PCardinal(StageUpload(Int64(T.Width) * N * FScale * FScale * 4, Offset));
    for var Y := Y0 to Y0 + N - 1 do
    begin
      if FScale = 1 then
        PS2HLELoadDepthRow(FMemory, A, T.ZPSM, Y, 0, T.Width, FD24, P)
      else
      begin
        if Length(FStoreRow) < T.Width then
          SetLength(FStoreRow, T.Width);
        PS2HLELoadDepthRow(FMemory, A, T.ZPSM, Y, 0, T.Width, FD24, @FStoreRow[0]);
        for var X := 0 to T.Width - 1 do
          for var K := 0 to FScale - 1 do
            P[X * FScale + K] := FStoreRow[X];
      end;
      for var K := 1 to FScale - 1 do
        Move(P^, P[T.Width * FScale * K], T.Width * FScale * 4);
      Inc(P, T.Width * FScale * FScale);
    end;
    CopyToImage(T.Depth.Image, VK_IMAGE_ASPECT_DEPTH_BIT, Offset, 0, 0, Y0 * FScale, T.Width * FScale, N * FScale);
    Inc(Y0, N);
  end;
  if not CapturePins(T, True, 0, T.ZBytes) then
  begin
    SetLength(T.ZShadow, T.ZBytes);
    ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
  end;
  T.ZLoaded := True;
  T.ZReloadRows := 0;
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
  if Same and DepthMatches(T) then
  begin
    T.ZVerified := FRun;
    Exit;
  end;
  if MemoryHeld(ZA, T.ZBytes) then
    Flush(frDepth);
  LoadDepth(T, Same);
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
procedure TPS2GSVulkanHLE.BeginDisplayFence;
begin
  FDisplayStoreCount := 0;
  FCapturingDisplay := True;
end;

procedure TPS2GSVulkanHLE.EndDisplayFence;
begin
  FCapturingDisplay := False;
end;

procedure TPS2GSVulkanHLE.MarkStoreOwner(T: TPS2HLETarget; Depth: Boolean);
begin
  var X0 := Max(0, T.X1);
  var X1 := Min(T.Width - 1, T.X2);
  var Y0 := Max(0, T.Y1);
  var Y1 := Min(T.Height - 1, T.Y2);
  var BP := T.Addr shr 8;
  var PSM := T.Format;
  if Depth then
  begin
    X0 := Max(0, T.ZX1);
    X1 := Min(T.Width - 1, T.ZX2);
    Y0 := Max(0, T.ZY1);
    Y1 := Min(T.Height - 1, T.ZY2);
    BP := T.ZAddr shr 8;
    PSM := T.ZPSM;
  end;
  if (X0 > X1) or (Y0 > Y1) then
    Exit;
  var Pages := Default(TPS2GSPages);
  AddRectPages(Pages, BP, T.Stride shr 6, PSM, X0, Y0, X1, Y1);
  if (FRGBLease.T <> nil) and (Depth or (FRGBLease.T <> T)) then
    for var K := 0 to High(Pages) do
      FRGBLease.Pages[K] := FRGBLease.Pages[K] and not Pages[K];
  for var I := 0 to 511 do
    if (Pages[I shr 5] and (Cardinal(1) shl (I and 31))) <> 0 then
    begin
      if FPinScope then
      begin
        FPinSeen[I * 2] := 0;
        FPinSeen[I * 2 + 1] := 0;
      end;
      FPageOwners[I].Target := nil;
      if not Depth
        and (GSCompletedPrefix <> nil)
        and (T.Format = PSMCT32)
        and (T.Width = Integer(T.Stride))
        and (T.Addr and 8191 = 0) then
      begin
        FPageOwners[I].Target := T;
        FPageOwners[I].Version := T.Version;
        FPageOwners[I].Prefix := GSCompletedPrefix^;
        FPageOwners[I].Queue := GSWriterQueueId;
        FPageOwners[I].X0 := X0;
        FPageOwners[I].X1 := X1;
        FPageOwners[I].Y0 := Y0;
        FPageOwners[I].Y1 := Y1;
      end;
    end;
end;

procedure TPS2GSVulkanHLE.NoteDisplayStore(T: TPS2HLETarget; IsDepth: Boolean);
begin
  var X1 := Max(0, T.X1);
  var Y1 := Max(0, T.Y1);
  var X2 := Min(T.Width - 1, T.X2);
  var Y2 := Min(T.Height - 1, T.Y2);
  var Base := T.Addr;
  var Format := T.Format;
  if IsDepth then
  begin
    X1 := Max(0, T.ZX1);
    Y1 := Max(0, T.ZY1);
    X2 := Min(T.Width - 1, T.ZX2);
    Y2 := Min(T.Height - 1, T.ZY2);
    Base := T.ZAddr;
    Format := T.ZPSM;
  end;
  if (X1 > X2) or (Y1 > Y2) then
    Exit;
  if FDisplayStoreCount = Length(FDisplayStores) then
    SetLength(FDisplayStores, 2 * FDisplayStoreCount + 8);
  var I := FDisplayStoreCount;
  Inc(FDisplayStoreCount);
  FDisplayStores[I].T := T;
  FDisplayStores[I].Depth := IsDepth;
  FDisplayStores[I].X1 := X1;
  FDisplayStores[I].Y1 := Y1;
  FDisplayStores[I].X2 := X2;
  FDisplayStores[I].Y2 := Y2;
  FillChar(FDisplayStores[I].Pages, SizeOf(TPS2GSPages), 0);
  AddRectPages(FDisplayStores[I].Pages, Base shr 8, T.Stride shr 6, Format, X1, Y1, X2, Y2);
end;

function TPS2GSVulkanHLE.OwnsDisplayRect(T: TPS2HLETarget; X, Y, W, H: Integer; const Pages: TPS2GSPages): Boolean;
begin
  Result := False;
  for var I := FDisplayStoreCount - 1 downto 0 do
    if Meets(Pages, FDisplayStores[I].Pages) then
      Exit(
        (FDisplayStores[I].T = T)
        and not FDisplayStores[I].Depth
        and (FDisplayStores[I].X1 <= X)
        and (FDisplayStores[I].X2 >= X + W - 1)
        and (FDisplayStores[I].Y1 <= Y)
        and (FDisplayStores[I].Y2 >= Y + H - 1)
      );
end;

procedure TPS2GSVulkanHLE.Store(T: TPS2HLETarget; Color, Depth: Boolean);
var
  Regions: array[0..1] of VkBufferImageCopy;
  A: TPS2GSAddressing;
begin
  if FScale > 1 then
  begin
    if Color and T.Dirty then
      MarkStoreOwner(T, False);
    if Depth and T.ZDirty then
      MarkStoreOwner(T, True);
    if FCapturingDisplay then
    begin
      if Color and T.Dirty then
        NoteDisplayStore(T, False);
      if Depth and T.ZDirty then
        NoteDisplayStore(T, True);
    end;
    StoreScaled(T, Color, Depth);
    Exit;
  end;
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
  var ColorAt: Int64 := 0;
  if FStoreBatched then
  begin
    ColorAt := T.BatchAt[False];
    ColorBytes := T.BatchAt[True];
  end
  else
  begin
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
  end;
  if CW * CH > 0 then
  begin
    A.Init(Integer(T.Format), T.Addr shr 8, T.Stride shr 6);
    var C := PCardinal(FReadback.Data + ColorAt);
    for var Y := T.Y1 to T.Y2 do
    begin
      PS2HLEStoreColorRow(FMemory, A, T.Format, Y, T.X1, CW, C);
      Inc(C, CW);
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
    if T.ZStale then
      T.ZReloadRows := High(UInt64)
    else if (ZW > 0) and (ZH > 0) then
      for var Row := T.ZY1 div PageRowsOf(T.ZPSM) to T.ZY2 div PageRowsOf(T.ZPSM) do
        T.ZReloadRows := T.ZReloadRows or (UInt64(1) shl Row);
    T.ZDirty := False;
    T.ZStale := False;
    if not CapturePins(T, True, 0, T.ZBytes) then
    begin
      SetLength(T.ZShadow, T.ZBytes);
      ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
    end;
  end;
end;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
function SupportsStoreBands: Boolean;
asm
        .       NOFRAME
        mov     r10, rbx
        XOR     eax, eax
        cpuid
        cmp     eax, 7
        jb      @@No
        mov     eax, 1
        cpuid
        AND     ecx, $1C000000
        cmp     ecx, $1C000000
        jne     @@No
        XOR     ecx, ecx
        xgetbv
        AND     eax, 6
        cmp     eax, 6
        jne     @@No
        mov     eax, 7
        XOR     ecx, ecx
        cpuid
        SHR     ebx, 5
        AND     ebx, 1
        mov     eax, ebx
        jmp     @@Done

@@No:
        XOR     eax, eax

@@Done:
        mov     rbx, r10
end;

const
  BandM5: array[0..7] of Cardinal = ($0000001f, $0000001f, $0000001f, $0000001f, $0000001f, $0000001f, $0000001f, $0000001f);
  BandM10: array[0..7] of Cardinal = ($000003e0, $000003e0, $000003e0, $000003e0, $000003e0, $000003e0, $000003e0, $000003e0);
  BandM15: array[0..7] of Cardinal = ($00007c00, $00007c00, $00007c00, $00007c00, $00007c00, $00007c00, $00007c00, $00007c00);
  BandMTop: array[0..7] of Cardinal = ($00008000, $00008000, $00008000, $00008000, $00008000, $00008000, $00008000, $00008000);
  BandM24: array[0..7] of Cardinal = ($00ffffff, $00ffffff, $00ffffff, $00ffffff, $00ffffff, $00ffffff, $00ffffff, $00ffffff);
  BandNorm: array[0..7] of Cardinal = ($00800000, $00800000, $00800000, $00800000, $00800000, $00800000, $00800000, $00800000);
  BandOne: array[0..7] of Cardinal = ($00000001, $00000001, $00000001, $00000001, $00000001, $00000001, $00000001, $00000001);
  BandFOne: array[0..7] of Cardinal = ($3f800000, $3f800000, $3f800000, $3f800000, $3f800000, $3f800000, $3f800000, $3f800000);
  BandMant: array[0..7] of Cardinal = ($007fffff, $007fffff, $007fffff, $007fffff, $007fffff, $007fffff, $007fffff, $007fffff);
  BandShift16: array[0..7] of Cardinal = ($00000086, $00000086, $00000086, $00000086, $00000086, $00000086, $00000086, $00000086);
  BandShift24: array[0..7] of Cardinal = ($0000007e, $0000007e, $0000007e, $0000007e, $0000007e, $0000007e, $0000007e, $0000007e);
  BandZMax16: array[0..7] of Cardinal = ($0000ffff, $0000ffff, $0000ffff, $0000ffff, $0000ffff, $0000ffff, $0000ffff, $0000ffff);

function TileColor32(A, B: PCardinal; Dest: Pointer): Boolean;
asm
        .       NOFRAME
        vmovdqu ymm0, [rcx + 0]
        vshufps ymm0, ymm0, [rdx + 0], $DD
        vmovdqu [r8 + 0], ymm0
        vmovdqu ymm0, [rcx + 32]
        vshufps ymm0, ymm0, [rdx + 32], $DD
        vmovdqu [r8 + 32], ymm0
        mov     eax, 1
        vzeroupper
        ret
end;

function TileColor24(A, B: PCardinal; Dest: Pointer): Boolean;
asm
        .       NOFRAME
        vmovdqu ymm0, [rcx + 0]
        vshufps ymm0, ymm0, [rdx + 0], $DD
        vmovdqu ymm1, [rip + BandM24]
        vpandn  ymm2, ymm1, [r8 + 0]
        vpand   ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vmovdqu [r8 + 0], ymm0
        vmovdqu ymm0, [rcx + 32]
        vshufps ymm0, ymm0, [rdx + 32], $DD
        vmovdqu ymm1, [rip + BandM24]
        vpandn  ymm2, ymm1, [r8 + 32]
        vpand   ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vmovdqu [r8 + 32], ymm0
        mov     eax, 1
        vzeroupper
        ret
end;

function TileColor16(A, B: PCardinal; Dest: Pointer): Boolean;
asm
        .       NOFRAME
        vmovdqu ymm0, [rcx + 0]
        vshufps ymm0, ymm0, [rdx + 0], $DD
        vpsrld  ymm1, ymm0, 3
        vpand   ymm1, ymm1, [rip + BandM5]
        vpsrld  ymm2, ymm0, 6
        vpand   ymm2, ymm2, [rip + BandM10]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 9
        vpand   ymm2, ymm2, [rip + BandM15]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 16
        vpand   ymm2, ymm2, [rip + BandMTop]
        vpor    ymm1, ymm1, ymm2
        vmovdqa ymm0, ymm1
        vmovdqa ymm5, ymm0
        vmovdqu ymm0, [rcx + 64]
        vshufps ymm0, ymm0, [rdx + 64], $DD
        vpsrld  ymm1, ymm0, 3
        vpand   ymm1, ymm1, [rip + BandM5]
        vpsrld  ymm2, ymm0, 6
        vpand   ymm2, ymm2, [rip + BandM10]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 9
        vpand   ymm2, ymm2, [rip + BandM15]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 16
        vpand   ymm2, ymm2, [rip + BandMTop]
        vpor    ymm1, ymm1, ymm2
        vmovdqa ymm0, ymm1
        vpslld  ymm0, ymm0, 16
        vpor    ymm0, ymm0, ymm5
        vmovdqu [r8 + 0], ymm0
        vmovdqu ymm0, [rcx + 32]
        vshufps ymm0, ymm0, [rdx + 32], $DD
        vpsrld  ymm1, ymm0, 3
        vpand   ymm1, ymm1, [rip + BandM5]
        vpsrld  ymm2, ymm0, 6
        vpand   ymm2, ymm2, [rip + BandM10]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 9
        vpand   ymm2, ymm2, [rip + BandM15]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 16
        vpand   ymm2, ymm2, [rip + BandMTop]
        vpor    ymm1, ymm1, ymm2
        vmovdqa ymm0, ymm1
        vmovdqa ymm5, ymm0
        vmovdqu ymm0, [rcx + 96]
        vshufps ymm0, ymm0, [rdx + 96], $DD
        vpsrld  ymm1, ymm0, 3
        vpand   ymm1, ymm1, [rip + BandM5]
        vpsrld  ymm2, ymm0, 6
        vpand   ymm2, ymm2, [rip + BandM10]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 9
        vpand   ymm2, ymm2, [rip + BandM15]
        vpor    ymm1, ymm1, ymm2
        vpsrld  ymm2, ymm0, 16
        vpand   ymm2, ymm2, [rip + BandMTop]
        vpor    ymm1, ymm1, ymm2
        vmovdqa ymm0, ymm1
        vpslld  ymm0, ymm0, 16
        vpor    ymm0, ymm0, ymm5
        vmovdqu [r8 + 32], ymm0
        mov     eax, 1
        vzeroupper
        ret
end;

function TileDepth16(A, B: PCardinal; Dest: Pointer): Boolean;
asm
        .       NOFRAME
        vmovdqu ymm0, [rcx + 0]
        vshufps ymm0, ymm0, [rdx + 0], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift16]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandZMax16]
        vmovdqa ymm5, ymm0
        vmovdqu ymm0, [rcx + 64]
        vshufps ymm0, ymm0, [rdx + 64], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift16]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandZMax16]
        vpslld  ymm0, ymm0, 16
        vpor    ymm0, ymm0, ymm5
        vmovdqu [r8 + 0], ymm0
        vmovdqu ymm0, [rcx + 32]
        vshufps ymm0, ymm0, [rdx + 32], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift16]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandZMax16]
        vmovdqa ymm5, ymm0
        vmovdqu ymm0, [rcx + 96]
        vshufps ymm0, ymm0, [rdx + 96], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift16]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandZMax16]
        vpslld  ymm0, ymm0, 16
        vpor    ymm0, ymm0, ymm5
        vmovdqu [r8 + 32], ymm0
        mov     eax, 1
        vzeroupper
        ret

@@Scalar:
        XOR     eax, eax
        vzeroupper
end;

function TileDepth24(A, B: PCardinal; Dest: Pointer): Boolean;
asm
        .       NOFRAME
        vmovdqu ymm0, [rcx + 0]
        vshufps ymm0, ymm0, [rdx + 0], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift24]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandM24]
        vmovdqu ymm1, [rip + BandM24]
        vpandn  ymm2, ymm1, [r8 + 0]
        vpand   ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vmovdqu [r8 + 0], ymm0
        vmovdqu ymm0, [rcx + 32]
        vshufps ymm0, ymm0, [rdx + 32], $DD
  // Only finite positive normals or zero. Other values retain scalar FP semantics.
        vpsrad  ymm1, ymm0, 31
        vpcmpgtd ymm2, ymm0, [rip + BandFOne]
        vpor    ymm1, ymm1, ymm2
        vmovdqu ymm3, [rip + BandNorm]
        vpcmpgtd ymm2, ymm3, ymm0
        vpxor   ymm4, ymm4, ymm4
        vpcmpgtd ymm4, ymm0, ymm4
        vpand   ymm2, ymm2, ymm4
        vpor    ymm1, ymm1, ymm2
        vptest  ymm1, ymm1
        jnz     @@Scalar
        vpsrld  ymm1, ymm0, 23
        vmovdqu ymm2, [rip + BandShift24]
        vpsubd  ymm1, ymm2, ymm1
        vpand   ymm0, ymm0, [rip + BandMant]
        vpor    ymm0, ymm0, ymm3
        vpsubd  ymm2, ymm1, [rip + BandOne]
        vpsrlvd ymm2, ymm0, ymm2
        vpaddd  ymm2, ymm2, [rip + BandOne]
        vpsrld  ymm2, ymm2, 1
        vpxor   ymm3, ymm3, ymm3
        vpsubd  ymm1, ymm3, ymm1
        vpsllvd ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vpminud ymm0, ymm0, [rip + BandM24]
        vmovdqu ymm1, [rip + BandM24]
        vpandn  ymm2, ymm1, [r8 + 32]
        vpand   ymm0, ymm0, ymm1
        vpor    ymm0, ymm0, ymm2
        vmovdqu [r8 + 32], ymm0
        mov     eax, 1
        vzeroupper
        ret

@@Scalar:
        XOR     eax, eax
        vzeroupper
end;

{$ENDIF}

var
{$IF DEFINED(MSWINDOWS) AND DEFINED(CPUX64)}
  StoreBandsEnabled: Boolean;
{$ENDIF}
  StoredBandPixels: array[Boolean] of Int64;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
function StoreBand(M: TPS2GSMemory; const Address: TPS2GSAddressing; Format: Cardinal; Src: PCardinal; X0, Y0, W, N: Integer; Depth, D24: Boolean): Boolean;
type
  TTile = function(A, B: PCardinal; Dest: Pointer): Boolean;
var
  Apply: TTile;
begin
  Result := False;
  if not StoreBandsEnabled or (W < 8) or Odd(Y0) or Odd(N) then
    Exit;
  if Depth and (D24 or not CanPackDepth) then
    Exit;
  var Small := Is16(Format);
  var Width := 8;
  var Bytes := 4;
  if Small then
  begin
    Width := 16;
    Bytes := 2;
  end;
  if ((X0 or W) and (Width - 1)) <> 0 then
    Exit;
  if Depth then
  begin
    if Small then
      Apply := TileDepth16
    else if Format = PSMZ24 then
      Apply := TileDepth24
    else
      Exit;
  end
  else if Small then
    Apply := TileColor16
  else if Is24(Format) then
    Apply := TileColor24
  else
    Apply := TileColor32;
  var P := Src + 2 * W; // First scaled row containing centres; shuffles select odd X.
  for var I := 0 to N div 2 - 1 do
  begin
    var Row := Address.RowBase(Cardinal(Y0 + 2 * I));
    var Offsets := Address.RowOffsets(Cardinal(Y0 + 2 * I));
    var X := 0;
    while X < W do
    begin
      var At := Address.InRow(Row, Offsets, Cardinal(X0 + X));
      if not Apply(P + 2 * X, P + 2 * X + 4 * W, M.Data + At * Cardinal(Bytes)) then
        Exit;
      Inc(X, Width);
    end;
    Inc(P, W * 8);
  end;
  Inc(StoredBandPixels[Depth], Int64(W) * N);
  Result := True;
end;
{$ELSE}

function StoreBand(M: TPS2GSMemory; const Address: TPS2GSAddressing; Format: Cardinal; Src: PCardinal; X0, Y0, W, N: Integer; Depth, D24: Boolean): Boolean;
begin
  Result := False;
end;
{$ENDIF}

const
  FringeEnabled = True;

function TPS2GSVulkanHLE.PlanPack(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
var
  A: TPS2GSAddressing;
  UnitBytes, FirstByte: Integer;
  Written: Int64;

  procedure Exclude(PX, PY: Integer);
  begin
    var At := Integer(A.Addr(PX, PY)) * UnitBytes - FirstByte;
    var Lane := (At and 63) div UnitBytes;
    FMissing[At shr 6] := FMissing[At shr 6] or (Cardinal(1) shl Lane);
  end;

  procedure Append(Src, Dst, N: Integer);
  begin
    if N <= 0 then
      Exit;
    Inc(Written, N);
    var I := T.PackCount - 1;
    if (I >= 0)
      and (T.PackSpans[I].Src + T.PackSpans[I].Size = Src)
      and (T.PackSpans[I].Dst + T.PackSpans[I].Size = Dst) then
      Inc(T.PackSpans[I].Size, N)
    else
    begin
      if T.PackCount = Length(T.PackSpans) then
        SetLength(T.PackSpans, 16 + T.PackCount * 2);
      T.PackSpans[T.PackCount].Src := Src;
      T.PackSpans[T.PackCount].Dst := Dst;
      T.PackSpans[T.PackCount].Size := N;
      Inc(T.PackCount);
    end;
  end;

begin
  var Tile := 8 shl Ord(Is16(T.Format));
  if not FringeEnabled or (((X or W) and (Tile - 1) = 0) and not Odd(Y or H)) then
  begin
    if T.Fringe then
      T.PackCount := 0;
    T.Fringe := False;
    Exit(PlanAligned(T, X, Y, W, H, Bytes));
  end;
  Result := False;
  if (W < 1) or (H < 1) or (Int64(W) * H < 2048) then
    Exit;
  if T.Fringe and (T.ClipX = X) and (T.ClipY = Y) and (T.ClipW = W) and (T.ClipH = H) then
  begin
    Bytes := T.PackBytes;
    Exit(True);
  end;
  var L := X and  - Tile;
  var Top := Y and  - 2;
  var R := (X + W + Tile - 1) and  - Tile;
  var Bottom := (Y + H + 1) and  - 2;
  if (L < 0) or (Top < 0) or (R > T.Width) or (Bottom > T.Height) then
    Exit;
  if T.Fringe then
    T.PackCount := 0;
  T.Fringe := False;
  if not PlanAligned(T, L, Top, R - L, Bottom - Top, Bytes) then
    Exit;
  var NumTiles := Integer(Bytes shr 6);
  if Length(FMissing) < NumTiles then
    SetLength(FMissing, NumTiles);
  FillChar(FMissing[0], NumTiles * SizeOf(Cardinal), 0);
  A.Init(T.Format, 0, T.Stride shr 6);
  UnitBytes := 4 shr Ord(Is16(T.Format));
  FirstByte := T.PackFirst * 8192;
  // Only the private staging image is rounded outward. Enumerate the exact
  // GS lanes outside the dirty rectangle; they must never reach host VRAM.
  for var PY := Top to Y - 1 do
    for var PX := L to R - 1 do
      Exclude(PX, PY);
  for var PY := Y + H to Bottom - 1 do
    for var PX := L to R - 1 do
      Exclude(PX, PY);
  for var PY := Y to Y + H - 1 do
  begin
    for var PX := L to X - 1 do
      Exclude(PX, PY);
    for var PX := X + W to R - 1 do
      Exclude(PX, PY);
  end;
  var Spans := Copy(T.PackSpans, 0, T.PackCount);
  T.PackCount := 0;
  Written := 0;
  for var Span in Spans do
  begin
    var Chunk := 0;
    var Start := 0;
    while Chunk < Span.Size do
    begin
      var Mask := FMissing[(Span.Src + Chunk) shr 6];
      if Mask <> 0 then
      begin
        Append(Span.Src + Start, Span.Dst + Start, Chunk - Start);
        var U := 0;
        while U < 64 div UnitBytes do
        begin
          if ((Mask shr U) and 1) <> 0 then
            Inc(U)
          else
          begin
            var First := U;
            repeat
              Inc(U)
            until (U = 64 div UnitBytes) or (((Mask shr U) and 1) <> 0);
            var At := Chunk + First * UnitBytes;
            Append(Span.Src + At, Span.Dst + At, (U - First) * UnitBytes);
          end;
        end;
        Start := Chunk + 64;
      end;
      Inc(Chunk, 64);
    end;
    Append(Span.Src + Start, Span.Dst + Start, Span.Size - Start);
  end;
  if Written <> Int64(W) * H * UnitBytes then
    raise Exception.Create('Incomplete physical fringe');
  T.Fringe := True;
  T.ClipX := X;
  T.ClipY := Y;
  T.ClipW := W;
  T.ClipH := H;
  Result := True;
end;

function TPS2GSVulkanHLE.PlanAligned(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
type
  TMask = array[0..1023] of UInt64;
var
  Mask: TMask;
  A: TPS2GSAddressing;
begin
  Result := False;
  if not PackPagesEnabled
    or not FShaderBlend
    or (FScale <= 1)
    or ((T.Addr and 8191) <> 0)
    or (T.Width <> Integer(T.Stride))
    or ((T.Stride and 63) <> 0)
    or not (T.Format in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S, PSMZ32, PSMZ24, PSMZ16, PSMZ16S]) then
    Exit;
  var Small := Is16(T.Format);
  var Tile := 8 shl Ord(Small);
  if ((X or W) and (Tile - 1) <> 0) or Odd(Y) or Odd(H) or (Int64(W) * H < 2048) then
    Exit;
  if (T.PackW = W) and (T.PackH = H) and (T.PackX = X) and (T.PackY = Y) and (T.PackCount <> 0) then
  begin
    Bytes := T.PackBytes;
    Exit(True);
  end;
  var Pitch := T.Stride shr 6;
  var Shift := 5 + Ord(Small);
  var First := (Cardinal(Y) shr Shift) * Pitch + Cardinal(X shr 6);
  var Last := (Cardinal(Y + H - 1) shr Shift) * Pitch + Cardinal((X + W - 1) shr 6);
  if (Last < First) or (Last >= 512) then
    Exit;
  Bytes := Int64(Last - First + 1) * 8192;
  if (Bytes > Int64(W) * H * (8 shr Ord(Small))) or (Bytes > Int64(FReadback.Size)) then
    Exit;
  FillChar(Mask, SizeOf(Mask), 0);
  A.Init(T.Format, 0, Pitch);
  var Needed := 0;
  for var J := 0 to H div 2 - 1 do
  begin
    var RB := A.RowBase(Cardinal(Y + 2 * J));
    var RO := A.RowOffsets(Cardinal(Y + 2 * J));
    for var I := 0 to W div Tile - 1 do
    begin
      var Word := A.InRow(RB, RO, Cardinal(X + I * Tile)) shr Ord(Small);
      var At := Integer(Word shr 4) - Integer(First) * 128;
      if (At < 0) or (At >= Bytes div 64) or (Word and 15 <> 0) then
        raise Exception.Create('Bad physical color tile');
      Mask[At shr 6] := Mask[At shr 6] or (UInt64(1) shl (At and 63));
      Inc(Needed);
    end;
  end;
  T.PackCount := 0;
  var Covered := 0;
  for var I := 0 to Integer(Bytes div 64) - 1 do
    if (Mask[I shr 6] and (UInt64(1) shl (I and 63))) <> 0 then
    begin
      var Src := 64 * I;
      var Dst := (Integer(T.Addr) + Integer(First) * 8192 + Src) and $3FFFFF;
      if (T.PackCount > 0)
        and (T.PackSpans[T.PackCount - 1].Src + T.PackSpans[T.PackCount - 1].Size = Src)
        and (T.PackSpans[T.PackCount - 1].Dst + T.PackSpans[T.PackCount - 1].Size = Dst) then
        Inc(T.PackSpans[T.PackCount - 1].Size, 64)
      else
      begin
        if Length(T.PackSpans) = T.PackCount then
          SetLength(T.PackSpans, 16 + T.PackCount * 2);
        T.PackSpans[T.PackCount].Src := Src;
        T.PackSpans[T.PackCount].Dst := Dst;
        T.PackSpans[T.PackCount].Size := 64;
        Inc(T.PackCount);
      end;
      Inc(Covered);
    end;
  if Covered <> Needed then
    raise Exception.Create('Aliased color tile');
  T.PackW := W;
  T.PackH := H;
  T.PackX := X;
  T.PackY := Y;
  T.PackFirst := First;
  T.PackBytes := Bytes;
  Result := True;
end;

function TPS2GSVulkanHLE.PlanDepth(T: TPS2HLETarget; X, Y, W, H: Integer; out Bytes: Int64): Boolean;
begin
  Result := False;
  if (FTargets.Count > 64) or not FCanSampleZ or FD24 or not (T.ZPSM in [PSMZ32, PSMZ24, PSMZ16, PSMZ16S]) then
    Exit;
  if T.ZPlan = nil then
    T.ZPlan := TPS2HLETarget.Create;
  var Plan := T.ZPlan;
  if (Plan.Addr <> T.ZAddr) or (Plan.Format <> T.ZPSM) or (Plan.Stride <> T.Stride) or (Plan.Height <> T.Height) then
  begin
    Plan.PackCount := 0;
    Plan.Fringe := False;
  end;
  Plan.Addr := T.ZAddr;
  Plan.Format := T.ZPSM;
  Plan.Width := T.Width;
  Plan.Height := T.Height;
  Plan.Stride := T.Stride;
  if not PlanPack(Plan, X, Y, W, H, Bytes) then
    Exit;
  Result := Int64(Plan.PackW) * Plan.PackH * FScale * FScale * 4 <= HLEUploadCapacity;
end;

procedure TPS2GSVulkanHLE.EmitDepth(T: TPS2HLETarget);
type
  TPush = packed record
    X, Y, W, H, Pitch, RowShift, FirstPage, Offset, TableBase, Scale, Bits, FlagAt: Cardinal;
  end;
const
  Formats: array[0..2] of Cardinal = (PSMZ32, PSMZ16, PSMZ16S);
begin
  if FDepthPack = nil then
  begin
    FDepthTable := FCompute.CreateBuffer(3 * 4096 * 4, vbkUpload, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    for var I := Low(Formats) to High(Formats) do
    begin
      var A: TPS2GSAddressing;
      A.Init(Formats[I], 0, 1);
      for var Y := 0 to PageRowsOf(Formats[I]) - 1 do
        for var X := 0 to 63 do
          PCardinal(FDepthTable.Data)[I * 4096 + Y * 64 + X] := A.Addr(X, Y) shr Ord(I <> 0);
    end;
    FDepthTable.Flush(0, 3 * 4096 * 4);
    FDepthPack :=
      TVulkanKernel
      .Create(FCompute, PS2GSKernelCode(TPS2GSKernel.DepthPack), 2, SizeOf(TPush), [], 64, 'main', 1, True);
    for var I := 0 to 63 do
    begin
      FDepthPack.Bind(I, 0, FDepthTable);
      FDepthPack
        .Bind(I, 1, FReadback, 0, Min(FReadback.Size, UInt64(FCompute.Properties.limits.maxStorageBufferRange)));
    end;
  end;

  var Plan := T.ZPlan;
  var Push: TPush;
  Push.X := Plan.PackX;
  Push.Y := Plan.PackY;
  Push.W := Plan.PackW;
  Push.H := Plan.PackH;
  var Table := 0;
  if T.ZPSM = PSMZ16 then
    Table := 1
  else if T.ZPSM = PSMZ16S then
    Table := 2;
  Push.Pitch := T.Stride shr 6;
  Push.RowShift := 5 + Ord(Table <> 0);
  Push.FirstPage := Plan.PackFirst;
  Push.Offset := T.BatchAt[True] div 4;
  Push.TableBase := Table * 4096;
  Push.Scale := FScale;
  Push.Bits := 32;
  if T.ZPSM = PSMZ24 then
    Push.Bits := 24
  else if Table <> 0 then
    Push.Bits := 16;
  Push.FlagAt := T.ZFlagAt div 4;
  Plan.BatchAt[False] := T.BatchAt[True];

  // A set belongs to one plane until the store batch's existing fence completes.
  if T.ZView = 0 then
    T.ZView := CreateView(T.Depth.Image, FDepthFormat, VK_IMAGE_ASPECT_DEPTH_BIT);
  FDepthPack.BindSampled(FZSet, 0, T.ZView, Sampler(0));
  FDepthPack.ActiveSet := FZSet;
  Inc(FZSet);
  Slot.Cmd.Fill(FReadback, T.ZFlagAt, 4, 0);
  Slot.Cmd.FullBarrier;
  Slot.Cmd.Dispatch(FDepthPack, ((Push.W shr Ord(Table <> 0)) + 7) div 8, (Push.H + 7) div 8, 1, Push, SizeOf(Push));
end;

procedure TPS2GSVulkanHLE.EmitPack(T: TPS2HLETarget; Id: Integer);
type
  TPush = packed record
    X, Y, W, H, Pitch, RowShift, First, Offset, TableBase, Scale: Cardinal;
  end;
var
  A: TPS2GSAddressing;
begin
  if FPackKernel = nil then
  begin
    FPackTable := FCompute.CreateBuffer(3 * 4096 * 4, vbkUpload, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    for var F := 0 to 2 do
    begin
      var Format := PSMCT32;
      if F = 1 then
        Format := PSMCT16
      else if F = 2 then
        Format := PSMCT16S;
      A.Init(Format, 0, 1);
      for var Y := 0 to PageRowsOf(Format) - 1 do
        for var X := 0 to 63 do
          PCardinal(FPackTable.Data)[F * 4096 + Y * 64 + X] := A.Addr(X, Y) shr Ord(F <> 0);
    end;
    FPackTable.Flush(0, 3 * 4096 * 4);
    FPackKernel :=
      TVulkanKernel.Create(FCompute, PS2GSKernelCode(TPS2GSKernel.PackedPage), 2, SizeOf(TPush), [], 64, 'main', 1);
    for var K := 0 to 63 do
    begin
      FPackKernel.Bind(K, 0, FPackTable);
      FPackKernel
        .Bind(K, 1, FReadback, 0, Min(FReadback.Size, UInt64(FCompute.Properties.limits.maxStorageBufferRange)));
    end;
  end;
  var P: TPush;
  P.X := T.PackX;
  P.Y := T.PackY;
  P.W := T.PackW;
  P.H := T.PackH;
  var F := 0;
  if T.Format = PSMCT16 then
    F := 1
  else if T.Format = PSMCT16S then
    F := 2;
  P.TableBase := F * 4096;
  P.RowShift := 5 + Ord(F <> 0);
  P.Scale := FScale;
  P.First := T.PackFirst;
  P.Pitch := T.Stride shr 6;
  P.Offset := Cardinal(T.BatchAt[False] div 4);
  FPackKernel.BindImage(Id, 0, T.Color.View);
  FPackKernel.ActiveSet := Id;
  Slot.Cmd.Dispatch(FPackKernel, ((P.W shr Ord(F <> 0)) + 7) div 8, (P.H + 7) div 8, 1, P, SizeOf(P));
  if T.Fringe then
  begin
    Inc(FClippedPlanes);
    Inc(FClippedPixels, Int64(T.ClipW) * T.ClipH);
  end;
  Inc(FPackedAreas);
  Inc(FPackedPixels, Int64(P.W) * P.H);
end;

procedure TPS2GSVulkanHLE.ApplyPack(T: TPS2HLETarget);
begin
  var Source := FReadback.Data + T.BatchAt[False];
  for var I := 0 to T.PackCount - 1 do
  begin
    var R := T.PackSpans[I];
    if not Is24(T.Format) then
      Move((Source + R.Src)^, (FMemory.Data + R.Dst)^, R.Size)
    else
    begin
      var A := PUInt64(Source + R.Src);
      var B := PUInt64(FMemory.Data + R.Dst);
      for var K := 0 to R.Size div 8 - 1 do
        B[K] := (B[K] and $FF000000FF000000) or (A[K] and $00FFFFFF00FFFFFF);
      if Odd(R.Size div 4) then
      begin
        var N := R.Size div 4 - 1;
        PCardinal(B)[N] := (PCardinal(B)[N] and $FF000000) or (PCardinal(A)[N] and $FFFFFF);
      end;
    end;
  end;
end;

procedure TPS2GSVulkanHLE.StoreScaled(T: TPS2HLETarget; Color, Depth: Boolean);
var
  A: TPS2GSAddressing;

  procedure Plane(IsDepth: Boolean);
  var
    Region: VkBufferImageCopy;
  begin
    var X1 := Max(T.X1, 0);
    var Y1 := Max(T.Y1, 0);
    var X2 := Min(T.X2, T.Width - 1);
    var Y2 := Min(T.Y2, T.Height - 1);
    var Image := T.Color.Image;
    var Aspect: Cardinal := VK_IMAGE_ASPECT_COLOR_BIT;
    if IsDepth then
    begin
      X1 := Max(T.ZX1, 0);
      Y1 := Max(T.ZY1, 0);
      X2 := Min(T.ZX2, T.Width - 1);
      Y2 := Min(T.ZY2, T.Height - 1);
      Image := T.Depth.Image;
      Aspect := VK_IMAGE_ASPECT_DEPTH_BIT;
      A.Init(Integer(T.ZPSM), T.ZAddr shr 8, T.Stride shr 6);
    end
    else
      A.Init(Integer(T.Format), T.Addr shr 8, T.Stride shr 6);
    var W := X2 - X1 + 1;
    if (W <= 0) or (Y1 > Y2) then
      Exit;
    if FStoreBatched and not IsDepth and T.PackSelected then
    begin
      ApplyPack(T);
      Exit;
    end;
    var ReadBuffer := FReadback;
    var Batched := FStoreBatched;
    if IsDepth and FStoreBatched and T.ZPacked then
    begin
      // Integer conversion is used only with masked exceptions and sticky
      // precision already set. Unsupported bit patterns take the old scalar path.
      if CanPackDepth and (PCardinal(FReadback.Data + T.ZFlagAt)^ = 0) then
      begin
        ApplyPack(T.ZPlan);
        Inc(FZPacked);

        Inc(FZPackedPixels, Int64(W) * (Y2 - Y1 + 1));
        Exit;
      end;
      Inc(FZRejected);

      // Never overwrite data for another plane in the original batch.
      if FDepthFallback = nil then
        FDepthFallback := FCompute.CreateBuffer(FReadback.Size, vbkReadback, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
      ReadBuffer := FDepthFallback;
      Batched := False;
    end;
    var SW := W * FScale;
    var Rows := Max(1, Integer(ReadBuffer.Size div UInt64(SW * FScale * 4)));
    if Length(FStoreRow) < W then
      SetLength(FStoreRow, W);
    var Range: Double := DepthRange(T.ZPSM);
    var ZMax: Double := Range - 1;
    var Y0 := Y1;
    while Y0 <= Y2 do
    begin
      var N := Min(Rows, Y2 - Y0 + 1);
      var At: Int64 := 0;
      if Batched then
        At := T.BatchAt[IsDepth] + Int64(Y0 - Y1) * SW * FScale * 4
      else
      begin
        Record_;
        EndPass;
        ImageBarrier;
        Region := Default(VkBufferImageCopy);
        Region.imageSubresource.aspectMask := Aspect;
        Region.imageSubresource.layerCount := 1;
        Region.imageOffset.x := X1 * FScale;
        Region.imageOffset.y := Y0 * FScale;
        Region.imageExtent.width := SW;
        Region.imageExtent.height := N * FScale;
        Region.imageExtent.depth := 1;
        FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, Image, VK_IMAGE_LAYOUT_GENERAL, ReadBuffer.Handle, 1, @Region);
        HostReadBarrier;
        WaitAll;
        ReadBuffer.Invalidate(0, UInt64(SW) * UInt64(N) * UInt64(FScale) * 4);
      end;
      if FScale = 2 then
      begin
        var Format := T.Format;
        if IsDepth then
          Format := T.ZPSM;
        if StoreBand(FMemory, A, Format, PCardinal(ReadBuffer.Data + At), X1, Y0, W, N, IsDepth, FD24) then
        begin
          Inc(Y0, N);
          Continue;
        end;
      end;
      // Guest memory has one sample per native pixel, including depth.
      var P := PCardinal(ReadBuffer.Data + At) + (FScale div 2) * (SW + 1);
      for var Y := Y0 to Y0 + N - 1 do
      begin
        if IsDepth then
        begin
          var RB := A.RowBase(Cardinal(Y));
          var RO := A.RowOffsets(Cardinal(Y));
          for var X := 0 to W - 1 do
          begin
            var Raw := P[X * FScale];
            var F: Double;
            if FD24 then
              F := (Raw and $FFFFFF) / 16777215
            else
              F := PSingle(@Raw)^;
            F := F * Range;
            var Value: Cardinal;
            if not (F > 0) then
              Value := 0
            else if F >= ZMax then
              Value := Cardinal(Trunc(ZMax))
            else
              Value := Cardinal(Trunc(F + 0.5));
            FMemory.WriteAt(Integer(T.ZPSM), A.InRow(RB, RO, Cardinal(X1 + X)), Value);
          end;
        end
        else
        begin
          for var X := 0 to W - 1 do
            FStoreRow[X] := P[X * FScale];
          PS2HLEStoreColorRow(FMemory, A, T.Format, Y, X1, W, @FStoreRow[0]);
        end;
        Inc(P, SW * FScale);
      end;
      Inc(Y0, N);
    end;
  end;

begin
  if Color and T.Dirty then
    Plane(False);
  if Depth and T.ZDirty then
  begin
    Plane(True);
    T.ZDirty := False;
    T.ZStale := False;
    if not CapturePins(T, True, 0, T.ZBytes) then
    begin
      SetLength(T.ZShadow, T.ZBytes);
      ReadMemory(T.ZAddr, @T.ZShadow[0], Length(T.ZShadow));
    end;
  end;
end;

// Record every dirty image plane of this full flush in the existing
// readback arena. StoreTarget will still apply CPU writes, depth rounding,
// shadows and alias ordering in the original target order. Nothing is
// recorded before the complete set of offsets has been proven to fit.
const
  BatchStoresEnabled = True;

function TPS2GSVulkanHLE.BeginStoreBatch: Boolean;

  function Rect(T: TPS2HLETarget; Z: Boolean; out X, Y, W, H: Integer): Boolean;
  begin
    if Z then
    begin
      X := Max(T.ZX1, 0);
      Y := Max(T.ZY1, 0);
      W := Min(T.ZX2, T.Width - 1);
      H := Min(T.ZY2, T.Height - 1);
    end
    else
    begin
      X := Max(T.X1, 0);
      Y := Max(T.Y1, 0);
      W := Min(T.X2, T.Width - 1);
      H := Min(T.Y2, T.Height - 1);
    end;
    Result := (X <= W) and (Y <= H);
    if Result then
    begin
      W := (W - X + 1) * FScale;
      H := (H - Y + 1) * FScale;
      X := X * FScale;
      Y := Y * FScale;
    end;
  end;

begin
  Result := False;
  if not BatchStoresEnabled then
    Exit;
  var PackedCount := 0;
  var Bytes: Int64 := 0;
  var Cap := Int64(FReadback.Size);
  var Planes := 0;
  for var Item in FTargets do
  begin
    var T := TPS2HLETarget(Item);
    T.PackSelected := False;
    T.ZPacked := False;
    for var Z := False to True do
    begin
      T.BatchAt[Z] := -1;
      if (Z and not T.ZDirty) or (not Z and not T.Dirty) then
        Continue;
      var X, Y, W, H: Integer;
      if FPartialStoreMask <> nil then
      begin
        var First, Last: Integer;
        var At, Row: Cardinal;
        if Z then
        begin
          First := T.ZHeldY1;
          Last := T.ZHeldY2;
          At := T.ZAddr;
          Row := T.ZRowBytes;
        end
        else
        begin
          First := T.HeldY1;
          Last := T.HeldY2;
          At := T.Addr;
          Row := T.Stride * T.PixelBytes;
        end;
        if First > Last then
          Continue;
        var Part := Default(TPS2GSPages);
        AddRange(Part, At + Cardinal(First) * Row, Cardinal(Last - First + 1) * Row);
        if not Meets(Part, FPartialStoreMask^) then
          Continue;
      end;
      if not Rect(T, Z, X, Y, W, H) then
        Continue;
      Bytes := (Bytes + 15) and not Int64(15);
      var Length := Int64(W) * H * 4;
      if not Z and (PackedCount < 64) and (T.Format in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S]) then
      begin
        var CompactBytes: Int64;
        if PlanPack(T, X div FScale, Y div FScale, W div FScale, H div FScale, CompactBytes)
          and (Bytes + CompactBytes <= FCompute.Properties.limits.maxStorageBufferRange) then
        begin
          Length := CompactBytes;
          T.PackSelected := True;
          Inc(PackedCount);
        end;
      end;
      if Z
        and FCanSampleZ
        and (FScale > 1)
        and (UInt64(HLEUploadCapacity) <= FCompute.Properties.limits.maxStorageBufferRange) then
      begin
        var ZBytes: Int64;
        if PlanDepth(T, X div FScale, Y div FScale, W div FScale, H div FScale, ZBytes)
          and (Bytes + ZBytes + 4 <= FCompute.Properties.limits.maxStorageBufferRange) then
        begin
          T.ZFlagAt := Bytes + ZBytes;
          Length := ZBytes + 4;
          T.ZPacked := True;
        end;
      end;
      if (Bytes > Cap) or (Length > Cap - Bytes) then
      begin
        Exit;
      end;
      T.BatchAt[Z] := Bytes;
      Inc(Bytes, Length);
      Inc(Planes);
    end;
  end;
  if Planes = 0 then
    Exit;
  if FPartialStoreMask <> nil then
  begin
    if (Planes < 2) and (PackedCount = 0) then
      Exit;
    Inc(FPartialBatches);
  end;
  Inc(FGroupedPlanes, Planes);
  FZSet := 0;
  PackedCount := 0;
  Record_;
  EndPass;
  ImageBarrier;
  var Cmd := Slot.Cmd.Handle;
  for var Item in FTargets do
  begin
    var T := TPS2HLETarget(Item);
    for var Z := False to True do
    begin
      if T.BatchAt[Z] < 0 then
        Continue;
      if Z and T.ZPacked then
      begin
        EmitDepth(T);
        Continue;
      end;
      if not Z and T.PackSelected then
      begin
        EmitPack(T, PackedCount);
        Inc(PackedCount);
        Continue;
      end;
      var X, Y, W, H: Integer;
      Rect(T, Z, X, Y, W, H);
      var Region := Default(VkBufferImageCopy);
      Region.bufferOffset := T.BatchAt[Z];
      Region.imageSubresource.layerCount := 1;
      Region.imageOffset.x := X;
      Region.imageOffset.y := Y;
      Region.imageExtent.width := W;
      Region.imageExtent.height := H;
      Region.imageExtent.depth := 1;
      var Image := T.Color.Image;
      Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
      if Z then
      begin
        Image := T.Depth.Image;
        Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_DEPTH_BIT;
      end;
      FAPI.vkCmdCopyImageToBuffer(Cmd, Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Region);
    end;
  end;
  HostReadBarrier;
  WaitAll;
  FReadback.Invalidate(0, Bytes);
  FStoreBatched := True;
  Result := True;
end;

procedure TPS2GSVulkanHLE.EndStoreBatch;
begin
  FStoreBatched := False;
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
  FPartialStoreMask := @Pages;
  try
    BeginStoreBatch;
  finally
    FPartialStoreMask := nil;
  end;
  try
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
        if not CaptureColor(T, False) then
          if Cardinal(Length(T.Shadow)) <> T.Bytes then
          begin
            SetLength(T.Shadow, T.Bytes);
            ReadMemory(T.Addr, @T.Shadow[0], Length(T.Shadow));
          end
          else
          begin
            var RowBytes := T.Stride * T.PixelBytes;
            ReadMemory(
              T.Addr + Cardinal(T.HeldY1) * RowBytes,
              @T.Shadow[Cardinal(T.HeldY1) * RowBytes],
              Cardinal(T.HeldY2 - T.HeldY1 + 1) * RowBytes
            );
          end;
      end;
    end;
  finally
    EndStoreBatch;
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
  if not FCapturingDisplay and AnyPage(Writes) then
    FDisplayStoreCount := 0;
  if AnyPage(Writes) then
    for var I := 0 to 511 do
      if (Writes[I shr 5] and (Cardinal(1) shl (I and 31))) <> 0 then
        FPageOwners[I].Target := nil;
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
    var Delta := Cardinal((Int64(A) - U.Addr) and MemMask);
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
    T.Copy.Image := CreateImage(VK_FORMAT_R8G8B8A8_UNORM, T.Width * FScale, T.Height * FScale, 1,
      VK_IMAGE_USAGE_SAMPLED_BIT or VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
  end;
  Record_;
  EndPass;
  ImageBarrier;
  Region := Default(VkImageCopy);
  Region.srcSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.srcSubresource.layerCount := 1;
  Region.dstSubresource := Region.srcSubresource;
  Region.extent.width := T.Width * FScale;
  Region.extent.height := T.Height * FScale;
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
  Region.srcOffset.x := FCopyX1 * FScale;
  Region.srcOffset.y := FCopyY1 * FScale;
  Region.dstOffset := Region.srcOffset;
  Region.extent.width := (FCopyX2 - FCopyX1 + 1) * FScale;
  Region.extent.height := (FCopyY2 - FCopyY1 + 1) * FScale;
  Region.extent.depth := 1;
  FAPI.vkCmdCopyImage(
    Slot.Cmd.Handle,
    T.Color.Image,
    VK_IMAGE_LAYOUT_GENERAL,
    T.Copy.Image.Image,
    VK_IMAGE_LAYOUT_GENERAL,
    1,
    @Region
  );
  ImageBarrier;
  Inc(FCopies);
  FCopyX1 := MaxInt;
  FCopyY1 := MaxInt;
  FCopyX2 := -1;
  FCopyY2 := -1;
  ApplyBindings;
end;

// The CLUT entries D's texels take, in FClutCopy (FClutCount of them).
type
  TPalettePush = packed record
    W, H, Indices, Palette, Premul, Distances, Count, Shares, OutputAt, Pass: Cardinal;
  end;

function TPS2GSVulkanHLE.PaletteInput: Integer;
begin
  if FHybridKernel = nil then
  begin
    FHybridKernel :=
      TVulkanKernel.Create(
      FCompute,
      PS2GSKernelCode(TPS2GSKernel.PaletteHybrid),
      3,
      SizeOf(TPalettePush),
      [],
      Length(FHybridInputs)
    );
    FHybridCorners := FCompute.CreateBuffer(1025 * 1025 * 4, vbkDevice, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    FHybridOutput :=
      FCompute.CreateBuffer(
      HLEUploadCapacity,
      vbkDevice,
      VK_BUFFER_USAGE_STORAGE_BUFFER_BIT or VK_BUFFER_USAGE_TRANSFER_SRC_BIT
    );
  end;
  for var I := 0 to High(FHybridInputs) do
  begin
    if FHybridInputs[I] = Slot.Upload.Handle then
      Exit(I);
    if FHybridInputs[I] = 0 then
    begin
      FHybridKernel.Bind(I, 0, Slot.Upload);
      FHybridKernel.Bind(I, 1, FHybridCorners);
      FHybridKernel.Bind(I, 2, FHybridOutput);
      FHybridInputs[I] := Slot.Upload.Handle;
      Exit(I);
    end;
  end;
  Result := -1;
end;

function PaletteSlot(C: Cardinal): Integer; inline;
begin
  Result := Integer(((UInt64(C xor (C shr 16)) * $9E3779B1) shr 23) and 511);
end;

function TPS2GSVulkanHLE.PaletteLevel(T: TVulkanHLETexture; L, W, H: Integer; Src, Pal: PCardinal; Count: Integer): Boolean;
begin
  Result := False;
  if not FHybridAvailable
    or (T.Scale <> 2)
    or (TextureFilter <> tfHybrid)
    or ((Count <> 16) and (Count <> 256))
    or (W > 1024)
    or (H > 1024)
    or (W * H < 4096)
    or (W * H * 16 > HLEUploadCapacity)
    or (UInt64(HLEUploadCapacity) > FCompute.Properties.limits.maxStorageBufferRange) then
    Exit;
  var Id := -1;
  for var I := 0 to High(FMetrics) do
    if (FMetrics[I].Count = Count) and CompareMem(Pointer(FMetrics[I].Words), Pal, Count * 4) then
    begin
      Id := I;
      Break;
    end;
  var TableSize := Count * 5 + Count * Count + 20;
  if Id < 0 then
  begin
    Id := FMetricNext;
    FMetricNext := (FMetricNext + 1) and High(FMetrics);
    SetLength(FMetrics[Id].Words, TableSize);
    FMetrics[Id].Count := Count;
    MakeHybridPalette(Pal, Count, Pointer(FMetrics[Id].Words));
    FillChar(FMetrics[Id].Index, SizeOf(FMetrics[Id].Index), 0);
    for var I := 0 to Count - 1 do
    begin
      var At := PaletteSlot(Pal[I]);
      while (FMetrics[Id].Index[At] <> 0) and (Pal[FMetrics[Id].Index[At] - 1] <> Pal[I]) do
        At := (At + 1) and 511;
      FMetrics[Id].Index[At] := I + 1;
    end;
    Inc(FMetricBuilds);
  end;
  var Bytes := Int64(TableSize) * 4 + ((W * H + 3) and  - 4);
  var Offset: Int64;
  var Data := StageUpload(Bytes, Offset);
  Move(FMetrics[Id].Words[0], Data^, TableSize * 4);
  var Indices := Data + TableSize * 4;
  for var I := 0 to W * H - 1 do
  begin
    var C := Src[I];
    var At := PaletteSlot(C);
    var N := Integer(FMetrics[Id].Index[At]);
    while (N <> 0) and (Pal[N - 1] <> C) do
    begin
      At := (At + 1) and 511;
      N := FMetrics[Id].Index[At];
    end;
    if N = 0 then
      Exit;
    Indices[I] := N - 1;
  end;
  Slot.Upload.Flush(Offset, Bytes);
  var SetId := PaletteInput;
  if SetId < 0 then
    Exit;
  var P := Default(TPalettePush);
  P.W := W;
  P.H := H;
  P.Count := Count;
  P.Palette := Offset div 4;
  P.Premul := P.Palette + Cardinal(Count);
  P.Distances := P.Palette + Cardinal(5 * Count);
  P.Shares := P.Distances + Cardinal(Count * Count);
  P.Indices := P.Palette + Cardinal(TableSize);
  Slot.Cmd.FullBarrier;
  FHybridKernel.ActiveSet := SetId;
  Slot.Cmd.Dispatch(FHybridKernel, (W + 8) div 8, (H + 8) div 8, 1, P, SizeOf(P));
  Slot.Cmd.FullBarrier;
  P.Pass := 1;
  Slot.Cmd.Dispatch(FHybridKernel, (W * 2 + 7) div 8, (H * 2 + 7) div 8, 1, P, SizeOf(P));
  Slot.Cmd.FullBarrier;
  var Region := Default(VkBufferImageCopy);
  Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.imageSubresource.layerCount := 1;
  Region.imageSubresource.mipLevel := L;
  Region.imageExtent.width := W * 2;
  Region.imageExtent.height := H * 2;
  Region.imageExtent.depth := 1;
  FAPI
    .vkCmdCopyBufferToImage(Slot.Cmd.Handle, FHybridOutput.Handle, T.Image.Image, VK_IMAGE_LAYOUT_GENERAL, 1, @Region);
  ImageBarrier;
  if FNativeTextureView then
  begin
    if Length(T.NativePending) <> T.Levels then
      SetLength(T.NativePending, T.Levels);
    var Fresh: TArray<Cardinal>;
    SetLength(Fresh, W * H);
    Move(Src^, Fresh[0], W * H * SizeOf(Cardinal));
    T.NativePending[L] := Fresh;
    T.NativeDirty := True;
    Inc(FPendingMipBytes, Int64(W) * H * 4);
  end;
  Inc(FStats.TextureScales);
  Inc(FHybridJobs);
  Inc(FHybridPixels, Int64(W) * H * 4);
  Result := True;
end;

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
function TPS2GSVulkanHLE.TexelBox(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer; out U0, V0, U1, V1: Integer): Boolean;
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
  // part before (FGrow, Emit). Whole GS pages when that is small enough (and
  // a page more on each side a grown part went beyond the last): the same
  // parts for primitives reading the same pages, and a few for primitives
  // crossing a texture in turn.
  var BU0, BV0, BU1, BV1: Integer;
  var Box := (ScaleFor(Request.W, Request.H) = 1) and (Levels = 1) and
    (Request.W * Request.H >= 65536) and (FindTexture(Key) = nil) and
    TexelBox(D, V, Count, BU0, BV0, BU1, BV1);
  if Box then
  begin
    var PW := 64;
    var PH := 32;
    case D.TPSM of
      PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
        PH := 64;
      PSMT8:
        begin
          PW := 128;
          PH := 64;
        end;
      PSMT4:
        begin
          PW := 128;
          PH := 128;
        end;
    end;
    var GU0 := BU0 div PW * PW;
    var GV0 := BV0 div PH * PH;
    var GU1 := (BU1 div PW + 1) * PW - 1;
    var GV1 := (BV1 div PH + 1) * PH - 1;
    if FGrow then
    begin
      GU0 := Min(GU0, FGrowU0) - Ord(BU0 < FGrowU0) * PW;
      GV0 := Min(GV0, FGrowV0) - Ord(BV0 < FGrowV0) * PH;
      GU1 := Max(GU1, FGrowU1) + Ord(BU1 > FGrowU1) * PW;
      GV1 := Max(GV1, FGrowV1) + Ord(BV1 > FGrowV1) * PH;
      BU0 := Min(BU0, FGrowU0);
      BV0 := Min(BV0, FGrowV0);
      BU1 := Max(BU1, FGrowU1);
      BV1 := Max(BV1, FGrowV1);
    end;
    GU0 := Max(GU0, 0);
    GV0 := Max(GV0, 0);
    GU1 := Min(GU1, Request.W - 1);
    GV1 := Min(GV1, Request.H - 1);
    if (GU1 - GU0 + 1) * (GV1 - GV0 + 1) * 16 <= Request.W * Request.H then
    begin
      BU0 := GU0;
      BV0 := GV0;
      BU1 := GU1;
      BV1 := GV1;
    end;
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
  // Vulkan mip extents must remain the native mip extent times this factor.
  if (R.U0 = 0) and (R.V0 = 0) and (Width = 1 shl R.D.TW) and (Height = 1 shl R.D.TH) and
    (Width shr (Levels - 1) > 0) and (Height shr (Levels - 1) > 0) then
    Scale := ScaleFor(Width, Height);
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
    PSMT8, PSMT8H:
      Indices := 256;
    PSMT4, PSMT4HL, PSMT4HH:
      Indices := 16;
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
    if DecodeMirror(T, R, L, X0, Y0, W, H, @Pal[0], Indices) then
      Continue;
    A.Init(PSM, D.LevelTBP[L], D.LevelTBW[L]);
    var P := LevelTexels(T, W, H);
    var NativeInput := P;
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
            P^ :=
              Words[
              (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask
            ];
            Inc(P);
          end;
        PSMCT24, PSMZ24:
          for var X := X0 to X0 + W - 1 do
          begin
            var Raw :=
              Words[
              (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask]
              and $FFFFFF;
            var Alpha := D.TA0;
            if D.AEM and (Raw = 0) then
              Alpha := 0;
            P^ := Raw or (Cardinal(Alpha) shl 24);
            Inc(P);
          end;
        PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ :=
              ExpandTexA(
              Halves[
                (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask
              ],
              D.TA0,
              D.TA1,
              D.AEM
            );
            Inc(P);
          end;
        PSMT8:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ :=
              Pal[
              Bytes[
                (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask
              ]
            ];
            Inc(P);
          end;
        PSMT4:
          for var X := X0 to X0 + W - 1 do
          begin
            var Ad :=
              (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask;
            P^ := Pal[(Bytes[Ad shr 1] shr ((Ad and 1) * 4)) and $F];
            Inc(P);
          end;
        PSMT8H:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ :=
              Pal[
              Words[
                (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask])
                and A.Mask]
              shr 24
            ];
            Inc(P);
          end;
        PSMT4HL:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ :=
              Pal[
              (Words[
                (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask])
                and A.Mask]
              shr 24)
              and $F
            ];
            Inc(P);
          end;
        PSMT4HH:
          for var X := X0 to X0 + W - 1 do
          begin
            P^ :=
              Pal[
              Words[
                (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask])
                and A.Mask]
              shr 28
            ];
            Inc(P);
          end;
      else
        for var X := X0 to X0 + W - 1 do
        begin
          // (Any other format: ReadAt's word as an index.)
          var Index :=
            Integer(
            FMemory.ReadAt(
              PSM,
              (RowBase + (Cardinal(X) shr A.WShift) shl A.PageShift + Offsets[Cardinal(X) and A.WMask]) and A.Mask
            ))
            + D.ClutOffset;
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
    if not PaletteLevel(T, L, W, H, NativeInput, @Pal[0], Indices) then
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

procedure TPS2GSVulkanHLE.BindWorkerState(D: PPS2GSDraw; Fresh, Busy: PBoolean; TransferCount: PInteger);
begin
  FWorkerState := D;
  FWriterBusy := Busy;
  FQueuedWrites := TransferCount;
  FWorkerFresh := Fresh;
  Fresh^ := False;
end;

function TPS2GSVulkanHLE.SameState(const D: TPS2GSDraw): Boolean;
begin
  if FastHLEFront and (@D = FWorkerState) and FWorkerFresh^ then
  begin
    Exit(True);
  end;
  Result := SameStateFull(D);
  if FastHLEFront and (@D = FWorkerState) and Result then
    FWorkerFresh^ := True;
end;

function TPS2GSVulkanHLE.SameStateFull(const D: TPS2GSDraw): Boolean;
begin
  Result := CompareMem(@D, @FLast, SizeOf(TPS2GSDraw));
  if not Result and (FPassCount = 1) then
  begin
    // Vertex-only and already-resolved fields do not alter a single-pass batch.
    var Current := D;
    var Previous := FLast;
    Current.Ctx := 0;
    Previous.Ctx := 0;
    Current.IIP := False;
    Previous.IIP := False;
    Current.FST := False;
    Previous.FST := False;
    Current.ZTE := False;
    Previous.ZTE := False;
    Current.FB16 := False;
    Previous.FB16 := False;
    Current.FB24 := False;
    Previous.FB24 := False;
    Current.DstRead := False;
    Previous.DstRead := False;
    Result := CompareMem(@Current, @Previous, SizeOf(TPS2GSDraw));
  end;
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
    0:
      Result := VK_BLEND_FACTOR_ZERO;
    2:
      Result := VK_BLEND_FACTOR_DST_ALPHA;
    3:
      Result := VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
  else
    Result := VK_BLEND_FACTOR_ONE;
  end;
end;

const
  CheckTargetExtent = True;

function TPS2GSVulkanHLE.SourceFits(const D: TPS2GSDraw; V: PPS2HLEVertex; Count: Integer): Boolean;

  function AxisFits(First, Last, Extent, Available: Integer; Mode, Lo, Hi: Cardinal): Boolean;
  begin
    case Mode of
      0:
        if (First < 0) or (Last >= Extent) then
          Exit(Extent <= Available);
      1:
        Last := EnsureRange(Last, 0, Extent - 1);
      2:
        begin
          if Lo > Hi then
            Exit(False);
          Last := EnsureRange(Last, Integer(Lo), Integer(Hi));
        end;
      3:
        if not RegionRepeatSpan(First, Last, Lo, Hi) then
          Exit(Integer(Lo or Hi) < Available);
    end;
    Result := Last < Available;
  end;

begin
  Result := False;
  if (V = nil) or (Count = 0) then
    Exit;
  var U0 := MaxInt;
  var U1 := -MaxInt;
  var T0 := MaxInt;
  var T1 := -MaxInt;
  for var I := 0 to Count - 1 do
  begin
    if (V[I].Q = 0) or ((V[I].Q > 0) <> (V[0].Q > 0)) then
      Exit;
    var U: Double := V[I].S / V[I].Q / 16;
    var T: Double := V[I].T / V[I].Q / 16;
    if not ((Abs(U) < 65536) and (Abs(T) < 65536)) then
      Exit;
    U0 := Min(U0, Floor(U) - 1);
    U1 := Max(U1, Floor(U) + 1);
    T0 := Min(T0, Floor(T) - 1);
    T1 := Max(T1, Floor(T) + 1);
  end;
  Result :=
    AxisFits(U0, U1, 1 shl D.TW, FSourceWidth, D.WMS, D.MINU, D.MAXU)
    and AxisFits(T0, T1, 1 shl D.TH, FSourceHeight, D.WMT, D.MINV, D.MAXV);
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
  CSpan, ZSpan: TPageSpan;
  Kinds: array[0..1] of TPassKind;
begin
  // Only this call owns the physical source; queued band writes are excluded.
  FPinScope :=
    ScopePins
    and FUsePagePins
    and (GSWriterQueueId <> 0)
    and (GSCompletedPrefix <> nil)
    and (FWriterBusy <> nil)
    and not FWriterBusy^
    and (FQueuedWrites <> nil)
    and (FQueuedWrites^ = 0);
  if FPinScope then
    Inc(FPinEpoch);
  try
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
    ZSpan := Default(TPageSpan);
    // Only the page rows the scissor lets this state draw.
    var SY0 := EnsureRange(D.SY0, 0, T.Height - 1);
    var SY1 := EnsureRange(D.SY1, SY0, T.Height - 1);
    var CY0 := SY0 - SY0 mod FPageRows;
    var CY1 := Min(RoundRows(SY1 + 1, FPageRows), T.Height);
    CSpan := PageSpan(T.Addr + Cardinal(CY0) * T.Stride * T.PixelBytes, Cardinal(CY1 - CY0) * T.Stride * T.PixelBytes);
    if FDepthUsed then
    begin
      var ZY0 := SY0 - SY0 mod FZPageRows;
      var ZY1 := RoundRows(SY1 + 1, FZPageRows);
      ZSpan :=
        PageSpan(
        ((D.ZBP shl 8) and MemMask) + Cardinal(ZY0) * T.Stride * PixelBytesOf(D.ZPSM),
        Cardinal(ZY1 - ZY0) * T.Stride * PixelBytesOf(D.ZPSM)
      );
    end;
    CheckDestSpans(T, CSpan, ZSpan);
    var Tex := FBlank;
    var Source: TPS2HLETarget := nil;
    var OffX := 0;
    var OffY := 0;
    FLimitedSource := False;
    FRecheckOwnRead := False;
    FPartW := 0;
    if D.TME then
    begin
      Source := TargetTexture(D, OffX, OffY);
      if CheckTargetExtent and (Source <> nil) then
      begin
        FSourceWidth := Source.Width - OffX;
        FSourceHeight := Source.Height - OffY;
        var MaxU := (1 shl D.TW) - 1;
        var MaxV := (1 shl D.TH) - 1;
        if D.WMS = 2 then
          MaxU := Max(D.MINU, D.MAXU)
        else if D.WMS = 3 then
          MaxU := D.MINU or D.MAXU;
        if D.WMT = 2 then
          MaxV := Max(D.MINV, D.MAXV)
        else if D.WMT = 3 then
          MaxV := D.MINV or D.MAXV;
        FLimitedSource := (MaxU >= FSourceWidth) or (MaxV >= FSourceHeight);
        if FLimitedSource then
        begin
          Inc(FExtentUses);
          if not SourceFits(D, FSetupV, FSetupCount) then
          begin
            // Clamping to the edge of a Vulkan image is not GS page addressing.
            FRecheckOwnRead := Source = T;
            Source := nil;
            OffX := 0;
            OffY := 0;
            FLimitedSource := False;
            Inc(FExtentDeclines);
          end;
        end;
      end;
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
    if D.TME and (Source = nil) and (FScale = 2) and (Tex.Scale = 2) and Is16(T.Format) then
      NeedNativeMips(Tex);
    FTexSet := TextureSet(Tex, 0);
    FSampledImage := 0;
    if D.TME then
      FSampledImage := Tex.Image.Image;
    // From the first primitive on the target is newer than GS memory: the rows
    // drawn are held (Emit), the rest watched.
    ActivateTarget(T);
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
        if (Source <> T) and not Odd(FScale) then
          Flags := Flags or 64;
        // A compact render-to-texture surface can be stored and sampled again
        // in GS layout. Preserve its native texel lattice through that conversion.
        if (Source <> T) and (FScale = 2) and Is16(Source.Format) and Is16(T.Format) then
          Flags := Flags or 128;
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
      if (Source = nil) and (FScale = 2) and (Tex.Scale = 2) and (Tex.NativeMips.View <> 0) and Is16(T.Format) then
        Flags := Flags or 256;
      Push.Tex :=
        Cardinal(D.TFX)
        or (Cardinal(Ord(D.TCC)) shl 2)
        or (Cardinal(D.WMS) shl 3)
        or (Cardinal(D.WMT) shl 5)
        or (Cardinal(Ord(D.Linear)) shl 7)
        or (Cardinal(D.MMIN) shl 8)
        or (Cardinal(MXL) shl 11)
        or (Cardinal(Ord(D.LCM)) shl 14)
        or (Cardinal(D.LShift) shl 15)
        or (Cardinal(Ord(D.UseLod)) shl 17)
        or (TargetFormat shl 19)
        or (Cardinal(Ord(D.AEM)) shl 21)
        or (D.TW shl 24)
        or (D.TH shl 28);
      Push.ClampU := Cardinal(D.MINU) or (Cardinal(D.MAXU) shl 16);
      Push.ClampV := Cardinal(D.MINV) or (Cardinal(D.MAXV) shl 16);
      Push.TexA := Cardinal(D.TA0) or (Cardinal(D.TA1) shl 8);
      if Source <> nil then
        Push.TexA := Push.TexA or (Cardinal(FScale) shl 16)
      else
        Push.TexA := Push.TexA or (Cardinal(Tex.Scale) shl 16);
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
        if ((CSel <> 2)
          or (SCode = 4)
          or (DCode = 4)
          or (Fix > 128)
          or (D.PABE and (Op = VK_BLEND_OP_REVERSE_SUBTRACT))
          or not D.ColClamp) then
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
    // Use the ordinary sampler when no phase correction or native mip is requested.
    FDirectSampling := (Flags and (64 or 128 or 256)) = 0;
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
      Push.Pixel :=
        Cardinal(D.BlendA)
        or (Cardinal(D.BlendB) shl 2)
        or (Cardinal(D.BlendC) shl 4)
        or (Cardinal(D.BlendD) shl 6)
        or (Cardinal(D.BlendFix) shl 8)
        or (Cardinal(Ord(D.ABE)) shl 16)
        or (Cardinal(Ord(D.PABE)) shl 17)
        or (Cardinal(Ord(D.ColClamp)) shl 18)
        or (Cardinal(Ord(D.DATE)) shl 19)
        or (Cardinal(Ord(D.DATM)) shl 20)
        or (Format shl 21)
        or (Cardinal(D.AFAIL) shl 23)
        or (Cardinal(Ord(Test)) shl 25)
        or (Cardinal(Ord(D.FBA)) shl 26);
      Push.FbMsk := D.FBMSK;
      Push.AlphaTest := Cardinal(D.AREF) or (Cardinal(D.ATST) shl 8);
      var Key :=
        (UInt64(1) shl 22)
        or (UInt64(Ord(DepthTest or FDepthWrites)) shl 17)
        or (UInt64(Ord(FDepthWrites)) shl 18)
        or (UInt64(Compare) shl 19);
      FPasses[0].Pipeline := DrawPipeline(Key, FPasses[0]);
      FPasses[0].Layout := FBlendLayout;
      FPasses[0].Push := Push;
      FPassCount := 1;
    end;
    for var I := 0 to Count - 1 do
    begin
      if (Kinds[I].WriteMask = 0) and not Kinds[I].WritesZ then
        Continue;
      var Key :=
        BlendKey
        or (UInt64(Kinds[I].WriteMask) shl 13)
        or (UInt64(Ord(DepthTest or Kinds[I].WritesZ)) shl 17)
        or (UInt64(Ord(Kinds[I].WritesZ)) shl 18)
        or (UInt64(Compare) shl 19);
      FPasses[FPassCount].Pipeline := DrawPipeline(Key, FPasses[FPassCount]);
      FPasses[FPassCount].Layout := FLayout;
      FPasses[FPassCount].Push := Push;
      FPasses[FPassCount].Push.AlphaTest := Cardinal(D.AREF) or (Cardinal(D.ATST) shl 8) or (Kinds[I].Mode shl 12);
      Inc(FPassCount);
    end;

    var X1 := Max(D.SX0, 0);
    var Y1 := Max(D.SY0, 0);
    var X2 := Min(D.SX1, T.Width - 1);
    var Y2 := Min(D.SY1, T.Height - 1);
    FScissor.offset.x := X1 * FScale;
    FScissor.offset.y := Y1 * FScale;
    FScissor.extent.width := Cardinal(Max(X2 - X1 + 1, 0) * FScale);
    FScissor.extent.height := Cardinal(Max(Y2 - Y1 + 1, 0) * FScale);
    FTarget := T;
    // The passes are new: bound again before the next draw.
    FBoundPass := -1;
    ApplyBindings;
    FLast := D;
    if D.TME and IsPalettized(D.TPSM) then
      Move(FClut^, FLastClut[0], SizeOf(FLastClut));
    FStateValid := True;
    if FWorkerFresh <> nil then
      FWorkerFresh^ := @D = FWorkerState;
    FStats.SetupSeconds := FStats.SetupSeconds + Watch.Elapsed.TotalSeconds;
  finally
    FPinScope := False;
  end;
end;

// What SetupState chose, bound where it is not yet (the command buffer or its
// render pass may be new since).
procedure TPS2GSVulkanHLE.ApplyBindings;
begin
  var T := TPS2HLETarget(FTarget);
  FNextLocal := (FSampledImage <> T.Color.Image) and (FSampledImage <> T.Depth.Image);
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

// Multi-pass batches contain a single complete GS primitive.
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
  var NewPipe := FPasses[Index].Pipeline <> FBoundPipeline;
  if NewPipe then
  begin
    FAPI.vkCmdBindPipeline(Cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, FPasses[Index].Pipeline);
    FBoundPipeline := FPasses[Index].Pipeline;
  end;
  if FDynDepth or FDynColor then
    ApplyDynamic(FPasses[Index].NativeKey, NewPipe);
  FAPI.vkCmdPushConstants(
    Cmd,
    FPasses[Index].Layout,
    VK_SHADER_STAGE_VERTEX_BIT or VK_SHADER_STAGE_FRAGMENT_BIT,
    0,
    SizeOf(TPS2HLEPush),
    @FPasses[Index].Push
  );
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
  if Same and FLimitedSource and not SourceFits(D, V, Count) then
    FStateValid := False;
  if Same and (FPartW > 0) then
  begin
    var BU0, BV0, BU1, BV1: Integer;
    if not TexelBox(D, V, Count, BU0, BV0, BU1, BV1)
      or (BU0 < FPartU0)
      or (BV0 < FPartV0)
      or (BU1 >= FPartU0 + FPartW)
      or (BV1 >= FPartV0 + FPartH) then
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
  if (T.Stale and ((HY1 < T.HeldY1) or (HY2 > T.HeldY2)))
    or (T.ZStale and FDepthUsed and ((ZY1 < T.ZHeldY1) or (ZY2 > T.ZHeldY2))) then
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
  // Complete the earlier primitive's alpha-fail pass before this primitive.
  if (FPassCount > 1) and (FDrawCount <> 0) then
    FlushDraw;
  AddVertices(V, Count);
  Drawn(T, X1, Y1, X2, Y2);
  if FRecheckOwnRead then
    FStateValid := False;
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

function NativeCenterBias(Scale: Integer): Double; inline;
begin
  // The GS store reads sample Scale div 2. Its centre is half a device pixel
  // to the right of the native centre when the scale is even.
  Result := 0.5;
  if not Odd(Scale) then
    Result := Result + 0.5 / Scale;
end;

function TPS2GSVulkanHLE.Sprite(const D: TPS2GSDraw; const V0, V1: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := True;
  if (D.ZTST = 0) or (X0 >= X1) or (Y0 >= Y1) then
    Exit;
  if D.FBW = 0 then
    Exit(False);
  if not FitsTarget(D, Y1 - 1) then
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
    var Q0: Single := V0.Q;
    var Q1: Single := V1.Q;
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
  var Bias: Double := NativeCenterBias(FScale);
  var XA: Double := V0.X / 16 + Bias;
  var XB: Double := V1.X / 16 + Bias;
  var YA: Double := V0.Y / 16 + Bias;
  var YB: Double := V1.Y / 16 + Bias;
  if FScale > 1 then
  begin
    // A GS sprite covers whole native pixels. Retain their interpolation
    // centres while covering every subpixel, including framebuffer edges.
    var DU: Double := (UB - UA) / (XB - XA);
    var DT: Double := (TB - TA) / (YB - YA);
    var LeftU: Double := UA + (X0 - XA) * DU;
    var TopT: Double := TA + (Y0 - YA) * DT;
    UB := UA + (X1 - XA) * DU;
    TB := TA + (Y1 - YA) * DT;
    UA := LeftU;
    TA := TopT;
    XA := X0;
    XB := X1;
    YA := Y0;
    YB := Y1;
  end;
  var Corners: array[0..3] of TPS2HLEVertex;
  for var I := 0 to 3 do
  begin
    Corners[I] := C;
    if (I and 1) = 0 then
    begin
      Corners[I].X := XA;
      Corners[I].S := UA;
    end
    else
    begin
      Corners[I].X := XB;
      Corners[I].S := UB;
    end;
    if (I and 2) = 0 then
    begin
      Corners[I].Y := YA;
      Corners[I].T := TA;
    end
    else
    begin
      Corners[I].Y := YB;
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

function TPS2GSVulkanHLE.StreamSlot(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): PVulkanHLESlot;
begin
  Result := nil;
  if not FastHLEFront
    or not FStateValid
    or (@D <> FWorkerState)
    or not FWorkerFresh^
    or (FDrawCount = 0)
    or (FPartW <> 0)
    or FLimitedSource
    or FRecheckOwnRead
    or FFeedback
    or (FPass <> FTarget)
    or (FPassCount <> 1) then
    Exit;
  var T := TPS2HLETarget(FTarget);
  if (X0 < 0)
    or (Y0 < 0)
    or (X1 > T.Width)
    or (Y1 > T.Height)
    or (Y0 < T.HeldY1)
    or (Y1 - 1 > T.HeldY2)
    or ((FDepthWrites or (FDepthUsed and T.ZStale)) and ((Y0 < T.ZHeldY1) or (Y1 - 1 > T.ZHeldY2))) then
    Exit;
  var Sl := Slot;
  if not Sl.Cmd.Recording or (Sl.VertexCount + 3 > HLEVertexCapacity) then
    Exit;
  Result := Sl;
end;

function TPS2GSVulkanHLE.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex; X0, Y0, X1, Y1: Integer): Boolean;

  procedure Put(var P: TPS2HLEVertex; const V, Colored: TPS2GSVertex);
  begin
    var Bias: Double := NativeCenterBias(FScale);
    P.X := V.X / 16 + Bias;
    P.Y := V.Y / 16 + Bias;
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
  if not FitsTarget(D, Y1 - 1) then
    Exit(False);
  FZScale := DepthRange(D.ZPSM);
  var Sl := StreamSlot(D, X0, Y0, X1, Y1);
  var Dest := PPS2HLEVertex(@FVertices[0]);
  if Sl <> nil then
    Dest := PPS2HLEVertex(Sl.Vertices.Data + Int64(Sl.VertexCount) * SizeOf(TPS2HLEVertex));
  // Flat shading takes the last vertex's colour.
  if D.IIP then
  begin
    Put(Dest[0], V0, V0);
    Put(Dest[1], V1, V1);
  end
  else
  begin
    Put(Dest[0], V0, V2);
    Put(Dest[1], V1, V2);
  end;
  Put(Dest[2], V2, V2);
  if Sl = nil then
    Emit(D, Dest, 3, X0, Y0, X1 - 1, Y1 - 1)
  else
  begin
    Inc(Sl.VertexCount, 3);
    Inc(FDrawCount, 3);
    var T := TPS2HLETarget(FTarget);
    Drawn(T, X0, Y0, X1 - 1, Y1 - 1);
    if FDepthWrites then
    begin
      T.ZX1 := Min(T.ZX1, X0);
      T.ZY1 := Min(T.ZY1, Y0);
      T.ZX2 := Max(T.ZX2, X1 - 1);
      T.ZY2 := Max(T.ZY2, Y1 - 1);
    end;
    Inc(FStats.Prims);
  end;
end;

// A point as the pixel it rounds to; a line as a band one pixel across its
// minor axis, from the pixel its first end rounds to to the one its last
// does (TPS2GSDrawer.DrawLine's pixels, about).
function TPS2GSVulkanHLE.PointOrLine(const D: TPS2GSDraw; Kind: TPS2GSPrimitive; const V0, V1: TPS2GSVertex): Boolean;
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
  if not FitsTarget(D, Min(Max(V0.Y, V1.Y) div 16 + 1, D.SY1)) then
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
procedure TPS2GSVulkanHLE.ProtectRGB(BP, BW: Cardinal; X, Y, W, H: Integer; var Pixels: TArray<Cardinal>);
begin
  var T := FReadSurface;
  if (T = nil)
    or (ChannelDamage = nil)
    or (GSDisplayPageTimes = nil)
    or (GSReaderQueueId = 0)
    or (FScale <> 2)
    or (BP and 31 <> 0)
    or (T.Addr <> BP shl 8)
    or (T.Format <> PSMCT32)
    or T.Dirty
    or T.Stale
    or (T.Stride <> BW * 64)
    or (X < 0)
    or (Y < 0)
    or (X + W > T.Width)
    or (Y + H > T.Height)
    or (Length(Pixels) <> W * H * 4) then
  begin
    FRGBLease.T := nil;
    FRGBLease.Pixels := nil;
    Exit;
  end;
  var Carry :=
    (FRGBLease.T = T)
    and (FRGBLease.Queue = GSReaderQueueId)
    and (FRGBLease.Cut = ChannelFrom)
    and (ChannelFrom >= 0)
    and (ChannelTo >= ChannelFrom)
    and (T.Version >= FRGBLease.Version)
    and (FRGBLease.BP = BP)
    and (FRGBLease.BW = BW)
    and (FRGBLease.X = X)
    and (FRGBLease.Y = Y)
    and (FRGBLease.W = W)
    and (FRGBLease.H = H);
  var Good := Default(TPS2GSPages);
  var Patched := False;
  for var J := Y div 32 to (Y + H - 1) div 32 do
    for var I := X div 64 to (X + W - 1) div 64 do
    begin
      var Pg := (Integer(T.Addr shr 13) + J * Integer(BW) + I) and 511;
      var K := Pg shr 5;
      var Bit := Cardinal(1) shl (Pg and 31);
      var C := FPageOwners[Pg];
      var L := Max(X, I * 64);
      var R := Min(X + W - 1, I * 64 + 63);
      var A := Max(Y, J * 32);
      var B := Min(Y + H - 1, J * 32 + 31);
      if (C.Target <> T)
        or (C.Version <> T.Version)
        or (C.Queue <> GSReaderQueueId)
        or (C.Prefix < GSDisplayPageTimes^[Pg])
        or (C.X0 > L)
        or (C.X1 < R)
        or (C.Y0 > A)
        or (C.Y1 < B) then
        Continue;
      Good[K] := Good[K] or Bit;
      if not Carry then
        Continue;
      if (FRGBLease.Pages[K] and Bit) = 0 then
      begin
        Inc(FRGBPhysical);
        Continue;
      end;
      if (ChannelDamage^[K] and Bit) <> 0 then
      begin
        Inc(FRGBThreat);
        Continue;
      end;
      var Same := True;
      for var PY := A to B do
      begin
        var At := ((2 * (PY - Y) + 1) * W * 2 + 2 * (L - X) + 1);
        for var PX := L to R do
        begin
          if ((Pixels[At] xor FRGBLease.Pixels[At]) and $FFFFFF) <> 0 then
          begin
            Same := False;
            Break;
          end;
          Inc(At, 2);
        end;
        if not Same then
          Break;
      end;
      if not Same then
        Continue;
      Inc(FRGBProtected);
      for var PY := A to B do
      begin
        var At := 4 * (PY - Y) * W + 2 * (L - X);
        var Stride := 2 * W;
        for var PX := L to R do
        begin
          var C0 := Pixels[At];
          if (C0 = Pixels[At + 1])
            and (C0 = Pixels[At + Stride])
            and (C0 = Pixels[At + Stride + 1])
            and ((C0 <> FRGBLease.Pixels[At])
            or (C0 <> FRGBLease.Pixels[At + 1])
            or (C0 <> FRGBLease.Pixels[At + Stride])) then
          begin
            // CT32 readout always supplies the same display alpha. The centre
            // and the underlying native GS bytes are not written by the repair.
            if not Patched then
            begin
              Pixels := Copy(Pixels);
              Patched := True;
              Inc(FRGBRepairs);
            end;
            Pixels[At] := FRGBLease.Pixels[At];
            Pixels[At + 1] := FRGBLease.Pixels[At + 1];
            Pixels[At + Stride] := FRGBLease.Pixels[At + Stride];
            Inc(FRGBBlocks);
          end;
          Inc(At, 2);
        end;
      end;
    end;
  FRGBLease.T := T;
  FRGBLease.Version := T.Version;
  FRGBLease.Cut := ChannelTo;
  FRGBLease.Queue := GSReaderQueueId;
  FRGBLease.BP := BP;
  FRGBLease.BW := BW;
  FRGBLease.X := X;
  FRGBLease.Y := Y;
  FRGBLease.W := W;
  FRGBLease.H := H;
  FRGBLease.Pixels := Pixels;
  FRGBLease.Pages := Good;
end;

function TPS2GSVulkanHLE.ReadCircuit(Circuit: Integer; BP, BW, PSM: Cardinal; X, Y, W, H: Integer; out Pixels: TArray<Cardinal>; Certified: Boolean): Boolean;
begin
  FReadSurface := nil;
  Result := ReadCircuitRaw(Circuit, BP, BW, PSM, X, Y, W, H, Pixels, Certified);
  if not TrackDisplayRGB then
    Exit;
  if Result and (Circuit = 1) and (PSM = PSMCT32) then
    ProtectRGB(BP, BW, X, Y, W, H, Pixels)
  else
  begin
    FRGBLease.T := nil;
    FRGBLease.Pixels := nil;
  end;
end;

function TPS2GSVulkanHLE.ReadCircuitRaw(Circuit: Integer; BP, BW, PSM: Cardinal; X, Y, W, H: Integer; out Pixels: TArray<Cardinal>; Certified: Boolean): Boolean;
var
  Region: VkBufferImageCopy;
begin
  Result := False;
  Pixels := nil;
  if (Circuit < Low(FDisplay)) or (Circuit > High(FDisplay)) or (BW = 0) or (W <= 0) or (H <= 0) then
    Exit;
  var Address := (BP shl 8) and MemMask;
  var Found: TPS2HLETarget := nil;
  var OX := 0;
  var OY := 0;
  for var V in FTargets do
  begin
    var T := TPS2HLETarget(V);
    if not T.Loaded or T.Stale or (T.Stride <> BW * 64) then
      Continue;
    if T.Format <> PSM then
      if not ((T.Format in [PSMCT32, PSMCT24]) and (PSM in [PSMCT32, PSMCT24])) then
        Continue;
    var Delta := Cardinal((Int64(Address) - T.Addr) and MemMask);
    if (Delta >= T.Bytes) or ((Delta and 8191) <> 0) or not ShadowMatches(T) then
      Continue;
    var Pages := Integer(Delta shr PageShift);
    var TX := X + (Pages mod Integer(BW)) * 64;
    var TY := Y + (Pages div Integer(BW)) * PageRowsOf(T.Format);
    if (TX < 0) or (TY < 0) or (TX + W > T.Width) or (TY + H > T.Height) then
      Continue;
    if (Found <> nil) and (Found.LastUse > T.LastUse) then
      Continue;
    Found := T;
    OX := TX;
    OY := TY;
  end;
  var Extra := Found = nil;
  if Certified and (PSM = PSMCT32) and (Found = nil) and (FDisplayStoreCount > 0) then
  begin
    var Pages := Default(TPS2GSPages);
    AddRectPages(Pages, BP, BW, PSM, X, Y, X + W - 1, Y + H - 1);
    for var U in FTargets do
    begin
      var T := TPS2HLETarget(U);
      if not T.Loaded or T.Stale or T.Dirty or (T.Stride <> BW * 64) or (T.Format <> PSM) then
        Continue;
      var Delta := Cardinal((Int64(Address) - T.Addr) and MemMask);
      if (Delta >= T.Bytes) or (Delta and 8191 <> 0) then
        Continue;
      var P := Integer(Delta shr PageShift);
      var TX := X + (P mod Integer(BW)) * 64;
      var TY := Y + (P div Integer(BW)) * PageRowsOf(PSM);
      if (TX < 0) or (TY < 0) or (TX + W > T.Width) or (TY + H > T.Height) then
        Continue;
      if OwnsDisplayRect(T, TX, TY, W, H, Pages) then
      begin
        Found := T;
        OX := TX;
        OY := TY;
        Inc(FDisplayViews);
        Inc(FDisplayPixels, Int64(W) * H);
        Break;
      end;
    end;
  end;

  var Mixed := False;
  var Allowed := Default(TPS2GSPages);
  var PixelsAllowed := 0;
  if (Found = nil) and (GSDisplayPageTimes <> nil) and (PSM = PSMCT32) and ((X + W) <= Integer(BW * 64)) then
    for var U in FTargets do
    begin
      var T := TPS2HLETarget(U);
      if (not T.Loaded)
        or T.Dirty
        or T.Stale
        or (T.Addr <> Address)
        or (T.Stride <> BW * 64)
        or (T.Format <> PSM)
        or (Y + H > T.Height)
        or (X < 0)
        or (Y < 0)
        or ((Cardinal(Length(T.Shadow)) <> T.Bytes) and (T.Pins[False].Pages = nil)) then
        Continue;
      for var J := Y div 32 to (Y + H - 1) div 32 do
        for var I := X div 64 to (X + W - 1) div 64 do
        begin
          var Pg := (Integer(Address shr 13) + J * Integer(BW) + I) and 511;
          var C := FPageOwners[Pg];
          var X0 := Max(X, 64 * I);
          var X1 := Min(X + W - 1, 64 * I + 63);
          var Y0 := Max(Y, 32 * J);
          var Y1 := Min(Y + H - 1, 32 * J + 31);
          if (C.Target = T)
            and (C.Version = T.Version)
            and (GSReaderQueueId <> 0)
            and (C.Queue = GSReaderQueueId)
            and (GSDisplayPageTimes^[Pg] <= C.Prefix)
            and (C.X0 <= X0)
            and (C.X1 >= X1)
            and (C.Y0 <= Y0)
            and (C.Y1 >= Y1) then
          begin
            // Confirm this physical page still agrees, independent of the
            // queue proof. A same-value intervening write fails the prefix test.
            var Off := ((Pg * 8192 - Int64(Address)) and $3FFFFF);
            if ((T.Pins[False].Pages <> nil) and PinMatch(T, False, Off, 8192))
              or ((T.Pins[False].Pages = nil)
              and (Off + 8192 <= Length(T.Shadow))
              and VulkanHLEEqualBytes(FMemory.Data + Pg * 8192, @T.Shadow[Off], 8192)) then
            begin
              Allowed[Pg shr 5] := Allowed[Pg shr 5] or (Cardinal(1) shl (Pg and 31));
              Inc(PixelsAllowed, (X1 - X0 + 1) * (Y1 - Y0 + 1));
            end;
          end;
        end;
      if PixelsAllowed > 0 then
      begin
        Found := T;
        OX := X;
        OY := Y;
        Mixed := PixelsAllowed <> W * H;
        Inc(FEpochFrames);
        Inc(FEpochPixels, PixelsAllowed);
        Break;
      end;
    end;
  if Found = nil then
    Exit;
  FReadSurface := Found;
  var Cache: PPS2HLEDisplay := @FDisplay[Circuit];
  if not Mixed
    and (Cache.Target = Found)
    and (Cache.Version = Found.Version)
    and (Cache.X = OX)
    and (Cache.Y = OY)
    and (Cache.Width = W)
    and (Cache.Height = H)
    and (Cache.Format = PSM) then
  begin
    Pixels := Cache.Pixels;
    if not Extra then
      Inc(FStats.Presents);
    Exit(True);
  end;
  var Watch := TStopwatch.StartNew;
  Record_;
  EndPass;
  ImageBarrier;
  Region := Default(VkBufferImageCopy);
  Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.imageSubresource.layerCount := 1;
  Region.imageOffset.x := OX * FScale;
  Region.imageOffset.y := OY * FScale;
  Region.imageExtent.width := W * FScale;
  Region.imageExtent.height := H * FScale;
  Region.imageExtent.depth := 1;
  var Count := W * H * FScale * FScale;
  if UInt64(Count) * 4 > FReadback.Size then
    Exit;
  FAPI
    .vkCmdCopyImageToBuffer(Slot.Cmd.Handle, Found.Color.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Region);
  HostReadBarrier;
  WaitAll;
  FReadback.Invalidate(0, UInt64(Count) * 4);
  Pixels := FScanBank.Acquire(Count);
  DisplayAlpha(PCardinal(FReadback.Data), @Pixels[0], Count, Is16(PSM));
  if Mixed then
  begin
    var A: TPS2GSAddressing;
    A.Init(PSM, BP, BW);
    for var J := 0 to H - 1 do
      for var B := X div 64 to (X + W - 1) div 64 do
      begin
        var Pg := (Integer(Address shr 13) + ((Y + J) div 32) * Integer(BW) + B) and 511;
        if (Allowed[Pg shr 5] and (Cardinal(1) shl (Pg and 31))) <> 0 then
          Continue;
        for var I := Max(X, B * 64) to Min(X + W - 1, B * 64 + 63) do
        begin
          var V := (PCardinal(FMemory.Data)[A.Addr(I, Y + J)] and $FFFFFF) or $80000000;
          for var SY := 0 to FScale - 1 do
            for var SX := 0 to FScale - 1 do
              Pixels[((J * FScale + SY) * W + I - X) * FScale + SX] := V;
        end;
      end;
    if not Extra then
      Inc(FStats.Presents);
    FStats.PresentSeconds := FStats.PresentSeconds + Watch.Elapsed.TotalSeconds;
    Exit(True);
  end;
  Cache.Target := Found;
  Cache.Version := Found.Version;
  Cache.X := OX;
  Cache.Y := OY;
  Cache.Width := W;
  Cache.Height := H;
  Cache.Format := PSM;
  Cache.Pixels := Pixels;
  if not Extra then
    Inc(FStats.Presents);
  FStats.PresentSeconds := FStats.PresentSeconds + Watch.Elapsed.TotalSeconds;
  Result := True;
end;

procedure TPS2GSVulkanHLE.RecordFrame(T: TVulkanHLETarget; W, H: Integer);
var
  Region: VkBufferImageCopy;
begin
  Region := Default(VkBufferImageCopy);
  Region.imageSubresource.aspectMask := VK_IMAGE_ASPECT_COLOR_BIT;
  Region.imageSubresource.layerCount := 1;
  Region.imageExtent.width := Min(W, T.Width * FScale);
  Region.imageExtent.height := Min(H, T.Height * FScale);
  Region.imageExtent.depth := 1;
  FAPI.vkCmdCopyImageToBuffer(Slot.Cmd.Handle, T.Color.Image, VK_IMAGE_LAYOUT_GENERAL, FReadback.Handle, 1, @Region);
end;

function TPS2GSVulkanHLE.Describe: string;
begin
  Result :=
    Format(
    'mirror_levels=%d mirror_texels=%d mirror_send=%d mirror_reuse=%d ',
    [FMirrorLevels, FMirrorTexels, FMirrorSent, FMirrorReused])
    + Format('pack_areas=%d pack_pixels=%d ', [FPackedAreas, FPackedPixels])
    + Format('band_color=%d band_depth=%d ', [StoredBandPixels[False], StoredBandPixels[True]])
    + Format('partial_batch=%d grouped_planes=%d scale_reused=%d ', [FPartialBatches, FGroupedPlanes, ScaleReused])
    + Format('extent_probes=%d extent_declines=%d ', [FExtentUses, FExtentDeclines])
    + Format(
      'hle scale=%d texturescale=%d filter=%s scaled=%d ',
      [FScale, TextureScale, TexScaleFilterName(TextureFilter), FStats.TextureScales])
    + Format(
      'prims=%d draws=%d submits=%d flushes=%d partial=%d loads=%d zloads=%d readbacks=%d '
      + 'textures=%d hits=%d targettex=%d copies=%d pipelines=%d watchfaults=%d setup=%.0fms wait=%.0fms flush=%.0fms '
      + 'shaderblend=%d/%d parts=%d',
      [
        FStats.Prims,
        FStats.Draws,
        FStats.Submits,
        FStats.Flushes,
        FPartialStores,
        FStats.TargetLoads,
        FDepthLoads,
        FStats.Readbacks,
        FStats.TextureUploads,
        FStats.TextureHits,
        FTargetTextures,
        FCopies,
        FStats.Pipelines,
        FStats.WatchFaults,
        FStats.SetupSeconds * 1000,
        FStats.WaitSeconds * 1000,
        FStats.FlushSeconds * 1000,
        FBlendSetups,
        Ord(FShaderBlend),
        FPartials
      ])
    + Format(
      ' setups=%d flush: others=%d texture=%d depth=%d stale=%d sync=%d',
      [FSetups, FFlushes[frOthers], FFlushes[frTexture], FFlushes[frDepth], FFlushes[frStale], FFlushes[frSync]]);
  Result := Result + Format(' clipped=%d clip_pixels=%d', [FClippedPlanes, FClippedPixels]);
  Result :=
    Result
    + Format(
    ' rented=%d returned=%d allocations=%d evicted=%d',
    [RecycledImages, ReleasedTextureImages, CreatedTextureImages, DroppedImages]);
  Result :=
    Result
    + Format(
    ' pins_reused=%d pins_copied=%d pins_direct=%d pins_validated=%d',
    [FPinReused, FPinCopied, FAfterUpload, FValidated]);
  Result :=
    Result
    + Format(
    ' rgb_repairs=%d rgb_blocks=%d rgb_protected=%d rgb_threats=%d rgb_phys=%d',
    [FRGBRepairs, FRGBBlocks, FRGBProtected, FRGBThreat, FRGBPhysical]);
  Result := Result + Format(' image_loads=%d image_pixels=%d', [FDirectLoads, FDirectPixels]);
  Result :=
    Result
    + Format(
    ' scope_pin=%d scope_match=%d scope_oracle=%d scope_revert=%d',
    [FNativeFast, FMatchFast, FProofBytes, FReverted]);
  Result := Result + Format(' local_cuts=%d global_ends=%d', [FLocalCuts, FFencedEnds]);
  Result :=
    Result
    + Format(
    ' native_images=%d retained_bytes=%d native_upload=%d',
    [FNativeImages, FPendingMipBytes, FNativeMipBytes]);
  Result := Result + Format(' span_dest=%d span_stores=%d span_checks=%d', [FSpanCalls, FSpanStores, FSpanChecks]);
  Result :=
    Result
    + Format(
    ' slab_bound=%d slab_released=%d slab_allocations=%d slab_peak=%d',
    [FSlabBound, FSlabReleased, FSlabAllocated, FSlabPeak]);
  Result := Result + Format(' z_packs=%d z_pixels=%d z_fallback=%d', [FZPacked, FZPackedPixels, FZRejected]);
  Result :=
    Result
    + Format(
    ' direct_decodes=%d direct_texels=%d direct_bank_full=%d',
    [FImageDecodes, FImageTexels, FImageSetLimit]);
  Result :=
    Result + Format(' palette_jobs=%d palette_pixels=%d metric_builds=%d', [FHybridJobs, FHybridPixels, FMetricBuilds]);
  Result := Result + Format(' cgpu=%d zgpu=%d', [FColorGpuLoads, FDepthGpuLoads]);
  for var T in FTargets do
  begin
    Result := Result + Format(' [%x %x %dx%d', [T.Addr, T.Format, T.Width, T.Height]);
    if TPS2HLETarget(T).ZLoaded then
      Result := Result + Format(' z %x %x', [TPS2HLETarget(T).ZAddr, TPS2HLETarget(T).ZPSM]);
    Result := Result + ']';
  end;
end;

initialization
{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
  StoreBandsEnabled := SupportsStoreBands;
{$ENDIF}

end.

