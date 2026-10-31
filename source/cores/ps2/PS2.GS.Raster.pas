unit PS2.GS.Raster;

// GS drawing: the general registers, vertex queue and primitive assembly
// (points, lines, strips, triangles, fans, sprites), the pixel pipeline
// (texture with CLUT and filtering, fog, alpha/destination-alpha/depth tests,
// blending, FBA, masks, colour clamp) and host/local transfers.
// Triangles use edge functions over the scissored bounding box with plane
// equations for the attributes; sprites step their UV linearly.
// References: GS User's Manual (PS2 Linux Kit), ps2tek.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, Core.Snapshots, PS2.Types, PS2.GS.Memory;

const
  GSRegPRIM = $00;
  GSRegRGBAQ = $01;
  GSRegST = $02;
  GSRegUV = $03;
  GSRegXYZF2 = $04;
  GSRegXYZ2 = $05;
  GSRegTEX0_1 = $06;
  GSRegTEX0_2 = $07;
  GSRegCLAMP_1 = $08;
  GSRegCLAMP_2 = $09;
  GSRegFOG = $0A;
  GSRegXYZF3 = $0C;
  GSRegXYZ3 = $0D;
  GSRegTEX1_1 = $14;
  GSRegTEX1_2 = $15;
  GSRegMIPTBP1_1 = $34;
  GSRegMIPTBP2_1 = $36;
  GSRegTEX2_1 = $16;
  GSRegTEX2_2 = $17;
  GSRegXYOFFSET_1 = $18;
  GSRegXYOFFSET_2 = $19;
  GSRegPRMODECONT = $1A;
  GSRegPRMODE = $1B;
  GSRegTEXCLUT = $1C;
  GSRegSCANMSK = $22;
  GSRegTEXA = $3B;
  GSRegFOGCOL = $3D;
  GSRegTEXFLUSH = $3F;
  GSRegSCISSOR_1 = $40;
  GSRegSCISSOR_2 = $41;
  GSRegALPHA_1 = $42;
  GSRegALPHA_2 = $43;
  GSRegDIMX = $44;
  GSRegDTHE = $45;
  GSRegCOLCLAMP = $46;
  GSRegTEST_1 = $47;
  GSRegTEST_2 = $48;
  GSRegPABE = $49;
  GSRegFBA_1 = $4A;
  GSRegFBA_2 = $4B;
  GSRegFRAME_1 = $4C;
  GSRegFRAME_2 = $4D;
  GSRegZBUF_1 = $4E;
  GSRegZBUF_2 = $4F;
  GSRegBITBLTBUF = $50;
  GSRegTRXPOS = $51;
  GSRegTRXREG = $52;
  GSRegTRXDIR = $53;
  GSRegHWREG = $54;
  GSRegSIGNAL = $60;
  GSRegFINISH = $61;
  GSRegLABEL = $62;

type
  TPS2GSVertex = record
    X, Y: Integer;       // 12.4 fixed, offset applied
    Z: Cardinal;
    F: Integer;
    R, G, B, A: Integer;
    S, T, Q: Single;
    U, V: Integer;       // 10.4 fixed
  end;

  // Everything one primitive needs, resolved from the registers.
  TPS2GSDraw = record
    Ctx: Integer;
    IIP, TME, FGE, ABE, FST: Boolean;
    FBP, FBW, FPSM: Cardinal;
    FBMSK: Cardinal;
    ZBP, ZPSM: Cardinal;
    ZMSK: Boolean;
    SX0, SX1, SY0, SY1: Integer;
    ATE: Boolean;
    ATST, AREF, AFAIL: Integer;
    DATE, DATM: Boolean;
    ZTE: Boolean;
    ZTST: Integer;
    BlendA, BlendB, BlendC, BlendD, BlendFix: Integer;
    PABE, FBA, ColClamp: Boolean;
    TBP, TBW, TPSM, TW, TH: Cardinal;
    TCC: Boolean;
    TFX: Integer;
    WMS, WMT: Integer;
    MINU, MAXU, MINV, MAXV: Integer;
    // TEX1: filter when magnifying (MMAG) and minifying (MMIN 0..5), the
    // last mipmap level (MXL), LOD from K only (LCM), L and K.
    Linear: Boolean;
    MMIN, MXL: Integer;
    LCM: Boolean;
    LShift: Integer;
    K: Single;
    // The LOD decides between MMAG and MMIN, or picks levels.
    UseLod: Boolean;
    // Base pointers and widths of levels 0..6 (TEX0, MIPTBP1, MIPTBP2).
    LevelTBP, LevelTBW: array[0..6] of Cardinal;
    TA0, TA1: Integer;
    AEM: Boolean;
    FogR, FogG, FogB: Integer;
    // Worked out once: the largest depth of ZPSM, a 16- or 24-bit frame,
    // whether a pixel reads the frame's colour (when its alpha is written),
    // the CLUT format and the 4-bit formats' CSA offset.
    ZMax: Cardinal;
    FB16, FB24: Boolean;
    DstRead: Boolean;
    Clut32: Boolean;
    ClutOffset: Integer;
  end;

  PPS2GSDraw = ^TPS2GSDraw;

  TPS2GSPrimitive = (gpPoint, gpLine, gpTriangle, gpSprite);

  // How the band threads take a command: each draws its own rows (Draw);
  // the same once every band has finished the earlier commands (Barrier);
  // or, once they have, the first band does the whole job alone while the
  // others wait for it (SoloDraw: a primitive reading its own target;
  // SoloWrite: pixels of a host-to-local transfer; SoloCopy: a local-to-local
  // transfer; SoloClut: a CLUT load). Clut: the first band loads a CLUT while
  // the others wait for it, without waiting for the earlier commands.
  TPS2GSCommandOp = (coDraw, coBarrier, coSoloDraw, coSoloWrite, coSoloCopy, coSoloClut, coClut);

  TPS2GSClut = array[0..511] of Word;

  // A set of the 512 pages (8 KiB) of GS memory.
  TPS2GSPages = array[0..15] of Cardinal;

  // The pages a primitive draws in (frame; depth when it tests or writes it)
  // and reads as texture; whether it may read what it draws.
  TPS2GSFootprint = record
    Frame, Depth, Texture: TPS2GSPages;
    UsesZ, WritesZ, Feedback: Boolean;
  end;

  // A primitive to draw: its kind, the drawing state and its vertices; the
  // host rounding it was queued with (the EE runs with truncation), which
  // the drawing's arithmetic follows wherever it is drawn.
  TPS2GSCommand = record
    Kind: TPS2GSPrimitive;
    Op: TPS2GSCommandOp;
    Rounding: TRoundingMode;
    // The CLUT: a slot of the raster's ring (-1: its current one).
    Clut: Integer;
    D: TPS2GSDraw;
    V: array[0..2] of TPS2GSVertex;
    // SoloWrite: XferCount pixels of the raster's transfer ring from
    // XferStart, the first at (XferX, XferY) of the area. SoloWrite and
    // SoloCopy: the transfer's BITBLTBUF, TRXPOS and TRXREG.
    XferStart: Int64;
    XferCount, XferX, XferY: Integer;
    XferRegs: array[0..2] of UInt64;
  end;
  PPS2GSCommand = ^TPS2GSCommand;

  // Called before an accelerated draw with the pages it reads and writes
  // and whether it takes the current CLUT.
  TPS2GSBeforeDraw = reference to function(const Reads, Writes: TPS2GSPages; Palette: Boolean; Area: Int64): Boolean;

  TPS2GSAccelerator = class abstract
  protected
    FPending: Boolean;
    FRevision: Int64;
    FBeforeDraw: TPS2GSBeforeDraw;
  public
    procedure Sync; virtual; abstract;
    // CPU access to wrapped 8 KiB GS pages; unknown accelerators sync fully.
    procedure ReadPages(First, Last: Integer); virtual;
    procedure WritePages(First, Last: Integer); virtual;
    // The same for sets of pages read and written.
    procedure AccessPages(const Reads, Writes: TPS2GSPages); virtual;
    property Pending: Boolean read FPending;
    // Incremented when work is queued; zero disables CPU write-barrier caching.
    property Revision: Int64 read FRevision;
    // Host software queues must publish before an accepted GPU draw reads
    // their targets, textures or the current palette snapshot.
    property BeforeDraw: TPS2GSBeforeDraw read FBeforeDraw write FBeforeDraw;
    function Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer; Lod: Single): Boolean; virtual; abstract;
    // Optional full coverage/interpolation; False retains the fragment path.
    function Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer): Boolean; virtual;
    function BeginTriangle(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): Boolean; virtual; abstract;
    procedure Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single); virtual; abstract;
    procedure EndTriangle; virtual; abstract;
  end;

  TPS2GSRaster = class;

  // A texture level of the primitive being drawn: its addresses, size and
  // clamp region, in its own texels.
  TPS2GSTexLevel = record
    Addr: TPS2GSAddressing;
    W, H, MinU, MaxU, MinV, MaxV: Integer;
  end;
  PPS2GSTexLevel = ^TPS2GSTexLevel;

  // A triangle's attributes for TPS2GSDrawer.FillTriangle: per vertex as
  // doubles, the inverse of its doubled signed area and the texture size
  // (in 1/16 texels) for S and T.
  TPS2GSTriangle = record
    InvArea: Double;
    R, G, B, A, F, Z, U, V, S, T, Q: array[0..2] of Double;
    SW, TH: Double;
    NeedZ: Boolean;
    // The depth test is done before the other attributes (and not again).
    EarlyZ: Boolean;
  end;

  // The pixel pipeline of one thread: draws primitives into GS memory. With
  // bands (BandCount > 1) only the rows of its band (8-row stripes taken in
  // turn); counting only (CountOnly), it finds which pixels a primitive
  // covers and draws none. PixelsDrawn counts the pixels inside the scissor.
  TPS2GSDrawer = class
  private
    FOwner: TPS2GSRaster;
    FMemory: TPS2GSMemory;
    FD: TPS2GSDraw;
    FClut: PWord;
    FBand, FBandCount: Integer;
    FCountOnly: Boolean;
    FAccelerating: Boolean;
    FPixels: Int64;
    // LOD of the pixel being drawn (K when LCM is set).
    FLod: Single;
    // The primitive's frame and depth buffer addresses, and its texture
    // levels (prepared when first sampled: a bit per level in LevelsReady).
    FFrameAddr, FDepthAddr: TPS2GSAddressing;
    FLevels: array[0..6] of TPS2GSTexLevel;
    FLevelsReady: Cardinal;
    // The pixel passed the depth test already (FillTriangle's early test).
    FZPassed: Boolean;
    // DrawSprite's texture U by column.
    FSpriteU: TArray<Integer>;
    // A pixel is watched (the raster's WatchX, WatchY).
    FWatch: Boolean;
    function InBand(Y: Integer): Boolean; inline;
    procedure DrawPoint(const V: TPS2GSVertex);
    procedure DrawLine(const V0, V1: TPS2GSVertex);
    procedure DrawTriangle(const V0, V1, V2: TPS2GSVertex);
    procedure FillTriangle(const T: TPS2GSTriangle; Y, X0, X1: Integer; E0, E1, Step0, Step1: Int64);
    procedure PrepareLevel(Level: Integer);
    procedure DrawSprite(const V0, V1: TPS2GSVertex);
    procedure LogWatch(X, Y: Integer; WriteFB, WriteZ: Boolean; R, G, B, A: Integer; Z: Cardinal);
    procedure LogSprite(const V0, V1: TPS2GSVertex);
    procedure LogTriangle(const V0, V1, V2: TPS2GSVertex);
    procedure Pixel(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
    procedure Shade(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
    function Texel(U, V: Integer): Cardinal;
    function SampleLevel(Level, U, V: Integer; Linear: Boolean): Cardinal;
    function TexelAt(const L: TPS2GSTexLevel; TU, TV: Integer): Cardinal; inline;
    procedure SetLod(Q: Single); inline;
    function ClampCoord(C, Size, Mode, MinC, MaxC: Integer): Integer; inline;
  public
    constructor Create(Owner: TPS2GSRaster; Band, BandCount: Integer; CountOnly: Boolean);
    procedure Draw(const Command: TPS2GSCommand);
    property PixelsDrawn: Int64 read FPixels;
  end;

  TPS2GSBands = class;

  TPS2GSRaster = class
  private
    FMemory: TPS2GSMemory;
    FOnSignal, FOnFinish: TProc;
    FSignal, FFinish: Boolean;
    FQueue: array[0..2] of TPS2GSVertex;
    FQueueCount: Integer;
    FStripIndex: Integer;
    FCurrent: TPS2GSVertex;
    FQ: Single;
    FClut: TPS2GSClut;
    FCBP0, FCBP1: Cardinal;
    FD: TPS2GSDraw;
    // Host-to-local transfer.
    FXferActive: Boolean;
    FXferX, FXferY: Integer;
    FXferBits: UInt64;
    FXferBitCount: Integer;
    FXferGPURevision: Int64;
    FReadBuffer: TArray<Cardinal>;
    FReadPos: Integer;
    FPrimitives, FPixels, FXferPixels: Int64;
    // Drawing on this thread, and counting the pixels of what the band
    // threads draw (their timing is the same).
    FDrawer, FCounter: TPS2GSDrawer;
    FCommand: TPS2GSCommand;
    FThreads: Integer;
    FBands: TPS2GSBands;
    FAccelerator: TPS2GSAccelerator;
    FVulkan: Boolean;
    FVulkanError: string;
    // Something queued since the last Sync; the 8 KiB pages queued
    // primitives write and read as texture, and the buffer (base, width,
    // format) each written page is drawn through. These only cover what the
    // next command may overlap (a barrier orders everything before it);
    // FPendingWrites has every page written since the last Sync, for reads
    // of GS memory on this thread.
    FPending: Boolean;
    FWritten, FRead, FPendingWrites: TPS2GSPages;
    // The pages queued commands read (textures, depth, CLUTs, copy sources)
    // until the next Sync, for accelerated draws writing them.
    FPendingReads: TPS2GSPages;
    FPageOwner: array[0..511] of UInt64;
    // Host-to-local pixels for the band threads (with FQueueXfer): the ring,
    // its next position, the run not queued yet (its start, length and first
    // pixel in the area), and the ring and queue positions of the queued
    // runs, oldest first.
    FQueueXfer: Boolean;
    FXferRing: TArray<Cardinal>;
    FXferRingPos, FXferRunStart: Int64;
    FXferRunCount, FXferRunX, FXferRunY: Integer;
    FXferRuns: array[0..31] of record StartPos, Position: Int64; end;
    FXferRunHead, FXferRunTail: Integer;
    // CLUTs of queued primitives (the current one copied when it changed),
    // and the queue position after the last primitive using each.
    FClutRing: array of TPS2GSClut;
    FClutUse: array of Int64;
    // The queue position after the load of each slot's CLUT (0: none).
    FClutLoaded: array of Int64;
    FClutSlot: Integer;
    FClutChanged: Boolean;
    // The pixels of the primitive being queued (the counter's).
    FCommandPixels: Int64;
    // Where the accelerator's recent primitives went: taken by it, or to
    // the band threads as it cannot draw them (halved every 4096).
    FRecentAccepted, FRecentFallbacks: Integer;
    FRoute: (rtNone, rtAccelerated, rtDeclined, rtUnsupported);
    function OwnedElsewhere(const Pages: TPS2GSPages; Key: UInt64): Boolean;
    function Hazard(const C: TPS2GSCommand; const F: TPS2GSFootprint): Boolean;
    procedure MarkQueued(const C: TPS2GSCommand; const F: TPS2GSFootprint);
    procedure MarkPendingDraw(const F: TPS2GSFootprint);
    procedure MarkPendingArea(const Regs: array of UInt64);
    procedure ClearOverlap;
    function Queueing: Boolean; inline;
    procedure FlushTransfer;
    procedure RunSolo(const C: TPS2GSCommand; Drawer: TPS2GSDrawer);
    procedure CopyLocal(Buf, Pos, Reg: UInt64);
    procedure Kick(DrawingKick: Boolean);
    procedure SetupDraw;
    procedure Draw(Kind: TPS2GSPrimitive; const V0, V1, V2: TPS2GSVertex);
    procedure QueueDraw(const F: TPS2GSFootprint);
    procedure NoteRoute;
    function BeforeAccelerated(const Reads, Writes: TPS2GSPages; Palette: Boolean; Area: Int64): Boolean;
    function QueueFallback(Drawer: TPS2GSDrawer): Boolean;
    procedure SyncSoftware;
    procedure CheckPrimLogBreak;
    procedure LogRegister(Index: Integer; Value: UInt64);
    procedure LoadClut(Tex0: UInt64);
    procedure ReadClut(Tex0, TexClut: UInt64; var Clut: TPS2GSClut);
    function GetMemory: TPS2GSMemory;
    procedure SetThreads(Value: Integer);
    procedure SetVulkan(Value: Boolean);
    function GetVulkanDraws: Int64;
    function GetVulkanSubmissions: Int64;
    function GetVulkanTexturedDraws: Int64;
    function GetVulkanTriangles: Int64;
    function GetVulkanRasterizedTriangles: Int64;
    function GetVulkanTriangleDispatches: Int64;
    procedure StartTransfer;
    procedure FeedWord(W: Cardinal);
    procedure CheckGPUTransfer;
    procedure BeginTransferRun;
    procedure TransferPixel(Value: Cardinal);
    procedure LocalToLocal;
    procedure LocalToHost;
  public
    // Diagnostics: commands queued for the band threads by operation (next
    // to Regs: what the emulation thread writes, away from what bands read).
    QueuedOps: array[0..7] of Int64;
    Regs: array[0..$7F] of UInt64;
    SigLblId: UInt64;
    // Diagnostics: transfers started (BITBLTBUF, TRXPOS, TRXREG, TRXDIR) when assigned.
    TransferLog: TStrings;
    PrimLog: TStrings;
    // Diagnostics: OnPrimLogBreak runs before the next sprite, triangle or
    // transfer once PrimLog holds PrimLogBreak lines (then PrimLogBreak is 0).
    PrimLogBreak: Integer;
    OnPrimLogBreak: TProc;
    // Diagnostics: writes to this pixel go to PrimLog (WatchX -1: none).
    WatchX, WatchY: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure WriteRegister(Index: Integer; Value: UInt64);
    procedure WriteImage(const Data: TPS2Reg128);
    function ReadImage(out Data: TPS2Reg128): Boolean;
    procedure ClearSignal;
    procedure ClearFinish;
    // The FINISH event reaches CSR (after the drawing time, see OnFinish).
    procedure SetFinish;
    procedure SerializeState(State: TStateArchive);
    // Waits until the band threads have drawn everything queued.
    procedure Sync;
    // GS memory as drawn so far (waits for the band threads).
    property Memory: TPS2GSMemory read GetMemory;
    // Band threads drawing (0 or 1: none, everything drawn at once on the
    // caller's thread). The memory and timing are the same either way.
    property Threads: Integer read FThreads write SetThreads;
    property Vulkan: Boolean read FVulkan write SetVulkan;
    property VulkanError: string read FVulkanError;
    property VulkanDraws: Int64 read GetVulkanDraws;
    property VulkanSubmissions: Int64 read GetVulkanSubmissions;
    property VulkanTexturedDraws: Int64 read GetVulkanTexturedDraws;
    property VulkanTriangles: Int64 read GetVulkanTriangles;
    property VulkanRasterizedTriangles: Int64 read GetVulkanRasterizedTriangles;
    property VulkanTriangleDispatches: Int64 read GetVulkanTriangleDispatches;
    property SignalPending: Boolean read FSignal;
    property FinishPending: Boolean read FFinish;
    property OnSignal: TProc read FOnSignal write FOnSignal;
    // When assigned, a FINISH write calls it instead of raising the event now.
    property OnFinish: TProc read FOnFinish write FOnFinish;
    property Primitives: Int64 read FPrimitives;
    property PixelsDrawn: Int64 read FPixels;
    property PixelsTransferred: Int64 read FXferPixels;
  end;

  // Band threads. Each draws every queued primitive, in queue order, with a
  // drawer of its own band; a pixel's primitives are all drawn by one thread,
  // so the memory ends up as drawn on one thread.
  TPS2GSBands = class
  private const
    RingBits = 12;
    RingSize = 1 shl RingBits;
    RingMask = RingSize - 1;
    SpinRounds = 4000;
  public const
    WakeWeight = 2048;
  private
  private type
    TBand = class(TThread)
    private
      FOwner: TPS2GSBands;
      FIndex: Integer;
      FDrawer: TPS2GSDrawer;
      // The first band's drawer for whole primitives (SoloDraw).
      FSolo: TPS2GSDrawer;
    protected
      procedure Execute; override;
    public
      constructor Create(Owner: TPS2GSBands; Index: Integer; Drawer: TPS2GSDrawer);
      destructor Destroy; override;
    end;

    // What one band thread writes, a cache line apart from the others.
    TSlot = record
      Consumed: Int64;
      Sleeping: Integer;
      Wake: TEvent;
      Pad: array[0..4] of Int64;
    end;
  private
    FRaster: TPS2GSRaster;
    FRing: TArray<TPS2GSCommand>;
    FWrite, FPublished: Int64;
    FSlots: TArray<TSlot>;
    FBands: TArray<TBand>;
    FProgress: TEvent;
    FMainWaiting, FFailed, FBandsWaiting: Integer;
    FUnwoken: Integer;
    FFailure: string;
    function Published: Int64; inline;
    function Slowest: Int64;
    procedure WaitConsumed(Value: Int64);
    // A band thread waits until every band (or the first one) has taken the
    // commands before Value.
    procedure BandWait(Index: Integer; Value: Int64; FirstOnly: Boolean);
    procedure WakeWaitingBands;
    procedure Fail(const Message: string);
    procedure CheckFailed;
  public
    constructor Create(Raster: TPS2GSRaster; Count: Integer);
    destructor Destroy; override;
    // Room for the next primitive (waits for it); Publish hands it over. Bands
    // asleep for want of work are woken once the commands since the last wake
    // weigh WakeWeight (about pixels: a wake costs the emulation thread a
    // system call), or this thread waits for them.
    function Next: PPS2GSCommand;
    procedure Publish(Weight: Integer = WakeWeight);
    procedure Sync;
    // Primitives queued so far; waits until the first Position are drawn.
    property Position: Int64 read FWrite;
    procedure WaitFor(Position: Int64);
    // Waits until the first band thread has taken the commands before Value.
    procedure WaitFirst(Value: Int64);
  end;

implementation

uses
  PS2.GS.Gpu{$IFDEF GS_RACECHECK}, PS2.GS.RaceCheck{$ENDIF};

const
  // Transferred pixels queued for the band threads: the ring, and the most
  // one run (one queued command) takes.
  XferRingSize = 1 shl 20;
  XferRingMask = XferRingSize - 1;
  XferRunMax = 1 shl 16;

{$IF DEFINED(CPUX64) AND DEFINED(MSWINDOWS)}
// The RTL setter stores DefaultMXCSR globally before loading it. Concurrent
// callers can therefore load each other's rounding mode. GS workers must
// change only their own hardware state, never that shared default.
procedure SetDrawerRounding(Mode: TRoundingMode);
asm
  .NOFRAME
  stmxcsr [rsp + 8]
  mov eax, [rsp + 8]
  and eax, $FFFF9FC0                 // clear rounding and status flags
  or eax, $1F80                      // mask arithmetic exceptions
  and ecx, 3
  shl ecx, 13
  or eax, ecx
  mov [rsp + 8], eax
  ldmxcsr [rsp + 8]
end;
{$ELSE}
procedure SetDrawerRounding(Mode: TRoundingMode);
begin
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(Mode);
end;
{$ENDIF}

// Arithmetic shift right (rounds toward minus infinity); Delphi's shr is a
// logical shift, wrong for negative values.
function Sar(V: Int64; N: Integer): Int64; inline;
begin
  if V >= 0 then
    Result := V shr N
  else
    Result := not ((not V) shr N);
end;

function Clamp255(V: Integer): Integer; inline;
begin
  if V < 0 then
    Result := 0
  else if V > 255 then
    Result := 255
  else
    Result := V;
end;

// Round (to nearest, ties to even) without the RTL call: after adding
// 1.5 * 2^52 the double's low 32 bits are the rounded value; exact for
// |D| < 2^31.
function FastRound(D: Double): Integer; inline;
begin
  var T := D + 6755399441055744.0;
  Result := PInteger(@T)^;
end;


// Trunc for 0 <= D < 2^32 (depth): the low 52 bits after adding 1.5 * 2^52
// are 2^51 plus the rounded value.
function TruncDepth(D: Double): Cardinal; inline;
begin
  var T := D + 6755399441055744.0;
  var R := (PInt64(@T)^ and $FFFFFFFFFFFFF) - $8000000000000;
  if R > D then
    Dec(R);
  Result := Cardinal(R);
end;

// A texel coordinate in 1/16 texels, clamped (degenerate S/T/Q give huge or NaN values).
function TexCoord(D: Double): Integer;
begin
  if not (D > -$1000000) then
    Exit(-$1000000);
  if D > $1000000 then
    Exit($1000000);
  Result := Trunc(D);
end;

// TexCoord without the run-time library's Trunc: the rounded value (one of the
// integers around D, whatever the rounding) moved toward zero. Pass a variable
// (an inlined expression argument is worked out at each use).
function TexCoordOf(D: Double): Integer; inline;
begin
  if not (D > -$1000000) then
    Exit(-$1000000);
  if D > $1000000 then
    Exit($1000000);
  Result := FastRound(D);
  if D >= 0 then
  begin
    if Result > D then
      Dec(Result);
  end
  else if Result < D then
    Inc(Result);
end;

constructor TPS2GSRaster.Create;
begin
  inherited Create;
  FMemory := TPS2GSMemory.Create;
  FDrawer := TPS2GSDrawer.Create(Self, 0, 1, False);
  FCounter := TPS2GSDrawer.Create(Self, 0, 1, True);
  FClutSlot := -1;
  WatchX := -1;
  Reset;
end;

function TPS2GSAccelerator.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := False;
end;

procedure TPS2GSAccelerator.ReadPages(First, Last: Integer);
begin
  Sync;
end;

procedure TPS2GSAccelerator.WritePages(First, Last: Integer);
begin
  Sync;
end;

procedure TPS2GSAccelerator.AccessPages(const Reads, Writes: TPS2GSPages);
begin
  if FPending then
    Sync;
end;

destructor TPS2GSRaster.Destroy;
begin
  FBands.Free;
  FAccelerator.Free;
  FCounter.Free;
  FDrawer.Free;
  FMemory.Free;
  inherited;
end;

function TPS2GSRaster.GetVulkanDraws: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).Draws;
end;

function TPS2GSRaster.GetVulkanSubmissions: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).Submissions;
end;

function TPS2GSRaster.GetVulkanTexturedDraws: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).TexturedDraws;
end;

function TPS2GSRaster.GetVulkanTriangles: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).Triangles;
end;

function TPS2GSRaster.GetVulkanRasterizedTriangles: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).RasterizedTriangles;
end;

function TPS2GSRaster.GetVulkanTriangleDispatches: Int64;
begin
  Result := 0;
  if FAccelerator <> nil then
    Result := TPS2GSGpu(FAccelerator).TriangleDispatches;
end;

procedure TPS2GSRaster.SetVulkan(Value: Boolean);
begin
  if Value = FVulkan then Exit;
  Sync;
  FreeAndNil(FAccelerator);
  FVulkan := Value;
  FVulkanError := '';
  FXferGPURevision := -1;
  if Value then
  begin
    try
      FAccelerator := TPS2GSGpu.Create(FMemory.Data, @FClut[0]);
      FAccelerator.BeforeDraw :=
        function(const Reads, Writes: TPS2GSPages; Palette: Boolean; Area: Int64): Boolean
        begin
          Result := BeforeAccelerated(Reads, Writes, Palette, Area);
        end;
    except
      on E: Exception do FVulkanError := E.Message;
    end;
  end;
end;

procedure TPS2GSRaster.SetThreads(Value: Integer);
begin
  if Value <= 1 then
    Value := 0;
  if Value = FThreads then
    Exit;
  Sync;
  FreeAndNil(FBands);
  FThreads := Value;
  FClutRing := nil;
  FClutUse := nil;
  FClutLoaded := nil;
  FClutSlot := -1;
  FXferRing := nil;
  FQueueXfer := False;
  FXferRunHead := 0;
  FXferRunTail := 0;
  if Value > 1 then
  begin
    FBands := TPS2GSBands.Create(Self, Value);
    // Room for the CLUTs of a long queue (a load waits for the slot's last
    // user to be drawn).
    SetLength(FClutRing, 256);
    SetLength(FClutUse, 256);
    SetLength(FClutLoaded, 256);
    SetLength(FXferRing, XferRingSize);
  end;
end;

procedure TPS2GSRaster.Sync;
begin
  if (FAccelerator <> nil) and FAccelerator.Pending then
    FAccelerator.Sync;
  SyncSoftware;
end;

procedure TPS2GSRaster.SyncSoftware;
begin
  FlushTransfer;
  if not FPending then
    Exit;
  FPending := False;
  ClearOverlap;
  FillChar(FPendingWrites, SizeOf(FPendingWrites), 0);
  FillChar(FPendingReads, SizeOf(FPendingReads), 0);
  FBands.Sync;
  {$IFDEF GS_RACECHECK}RaceBarrier(FBands.Position);{$ENDIF}
  // CLUTs loaded on the band threads.
  if (FClutSlot >= 0) and not FClutChanged then
    FClut := FClutRing[FClutSlot];
  FXferRunHead := 0;
  FXferRunTail := 0;
end;

procedure TPS2GSRaster.ClearOverlap;
begin
  FillChar(FWritten, SizeOf(FWritten), 0);
  FillChar(FRead, SizeOf(FRead), 0);
end;

// Commands go to the band threads (diagnostics draw everything here, in order).
function TPS2GSRaster.Queueing: Boolean;
begin
  Result := (FBands <> nil) and (PrimLog = nil) and (WatchX < 0);
end;

// Queues the transferred pixels not queued yet (one SoloWrite).
procedure TPS2GSRaster.FlushTransfer;
begin
  if FXferRunCount = 0 then
    Exit;
  {$IFDEF GS_RACECHECK}RaceBarrier(FBands.Position); RaceBarrier(FBands.Position + 1); RaceDescribe(FBands.Position, 'xfer');{$ENDIF}
  var C := FBands.Next;
  C.Op := coSoloWrite;
  C.Rounding := GetRoundMode;
  C.Clut := -1;
  C.XferStart := FXferRunStart;
  C.XferCount := FXferRunCount;
  C.XferX := FXferRunX;
  C.XferY := FXferRunY;
  C.XferRegs[0] := Regs[GSRegBITBLTBUF];
  C.XferRegs[1] := Regs[GSRegTRXPOS];
  C.XferRegs[2] := Regs[GSRegTRXREG];
  MarkPendingArea(C.XferRegs);
  FBands.Publish;
  FXferRuns[FXferRunTail and High(FXferRuns)].StartPos := FXferRunStart;
  FXferRuns[FXferRunTail and High(FXferRuns)].Position := FBands.Position;
  Inc(FXferRunTail);
  ClearOverlap;
  FPending := True;
  FXferRunCount := 0;
end;

// A whole command on the first band thread (SoloDraw, SoloWrite, SoloCopy).
procedure TPS2GSRaster.RunSolo(const C: TPS2GSCommand; Drawer: TPS2GSDrawer);
begin
  case C.Op of
    coSoloDraw:
      Drawer.Draw(C);
    coSoloWrite:
      begin
        var Buf := C.XferRegs[0];
        var Pos := C.XferRegs[1];
        var Reg := C.XferRegs[2];
        var DBP := Cardinal((Buf shr 32) and $3FFF);
        var DBW := Cardinal((Buf shr 48) and $3F);
        var DPSM := Integer((Buf shr 56) and $3F);
        var DSAX := Integer((Pos shr 32) and $7FF);
        var DSAY := Integer((Pos shr 48) and $7FF);
        var RRW := Integer(Reg and $FFF);
        var X := C.XferX;
        var Y := C.XferY;
        var Head := C.XferStart;
        var Remaining := C.XferCount;
        while Remaining > 0 do
        begin
          var Count := Min(Remaining, Max(1, RRW - X));
          Count := Min(Count, XferRingSize - Integer(Head and XferRingMask));
          FMemory.WriteRow(DPSM, DBP, DBW, Cardinal((DSAX + X) and $7FF), Cardinal((DSAY + Y) and $7FF),
            @FXferRing[Head and XferRingMask], Count);
          Inc(Head, Count);
          Dec(Remaining, Count);
          Inc(X, Count);
          if X >= RRW then
          begin
            X := 0;
            Inc(Y);
          end;
        end;
      end;
    coSoloCopy:
      CopyLocal(C.XferRegs[0], C.XferRegs[1], C.XferRegs[2]);
    coSoloClut, coClut:
      begin
        // The CLUT before the load (XferX's slot), then what it loads.
        FClutRing[C.Clut] := FClutRing[C.XferX];
        ReadClut(C.XferRegs[0], C.XferRegs[1], FClutRing[C.Clut]);
      end;
  end;
end;

function TPS2GSRaster.GetMemory: TPS2GSMemory;
begin
  Sync;
  Result := FMemory;
end;

// The pages (8 KiB, 2048 words; numbered from 0, 512 in all) of buffer BP
// (blocks), BW (64 pixels) in format PSM, rows Y0..Y1, columns 0..X1.
procedure PageSpan(BP, BW, PSM: Cardinal; X1, Y0, Y1: Integer; out First, Last: Integer);
begin
  var PW := 64;
  var PH := 32;
  case PSM of
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
  var Cols := Integer(BW);
  if PW = 128 then
    Cols := (Cols + 1) shr 1;
  Cols := Max(Cols, X1 div PW + 1);
  First := Integer(BP shr 5) + (Y0 div PH) * Cols;
  Last := Integer((BP + 31) shr 5) + (Y1 div PH) * Cols + Cols - 1;
end;

function PagesMeet(const Bits: array of Cardinal; First, Last: Integer): Boolean;
begin
  if Last - First >= 511 then
    Exit(True);
  for var P := First to Last do
    if (Bits[(P and 511) shr 5] and (Cardinal(1) shl (P and 31))) <> 0 then
      Exit(True);
  Result := False;
end;

procedure MarkPages(var Bits: array of Cardinal; First, Last: Integer);
begin
  if Last - First >= 511 then
    Last := First + 511;
  for var P := First to Last do
    Bits[(P and 511) shr 5] := Bits[(P and 511) shr 5] or (Cardinal(1) shl (P and 31));
end;

// The pixels a primitive may draw (inclusive), inside the scissor: as
// TPS2GSDrawer draws sprites and triangles, around the vertices for points
// and lines. False when it draws none.
function PixelRect(const C: TPS2GSCommand; out X0, Y0, X1, Y1: Integer): Boolean;
begin
  var N := 3;
  if C.Kind in [gpLine, gpSprite] then
    N := 2
  else if C.Kind = gpPoint then
    N := 1;
  var MinX := C.V[0].X;
  var MaxX := MinX;
  var MinY := C.V[0].Y;
  var MaxY := MinY;
  for var K := 1 to N - 1 do
  begin
    MinX := Min(MinX, C.V[K].X);
    MaxX := Max(MaxX, C.V[K].X);
    MinY := Min(MinY, C.V[K].Y);
    MaxY := Max(MaxY, C.V[K].Y);
  end;
  case C.Kind of
    gpSprite:
      begin
        X0 := Integer(Sar(MinX + 15, 4));
        X1 := Integer(Sar(MaxX + 15, 4)) - 1;
        Y0 := Integer(Sar(MinY + 15, 4));
        Y1 := Integer(Sar(MaxY + 15, 4)) - 1;
      end;
    gpTriangle:
      begin
        X0 := Integer(Sar(MinX + 15, 4));
        X1 := Integer(Sar(MaxX, 4));
        Y0 := Integer(Sar(MinY + 15, 4));
        Y1 := Integer(Sar(MaxY, 4));
      end;
  else
    X0 := Integer(Sar(MinX, 4)) - 1;
    X1 := Integer(Sar(MaxX, 4)) + 2;
    Y0 := Integer(Sar(MinY, 4)) - 1;
    Y1 := Integer(Sar(MaxY, 4)) + 2;
  end;
  X0 := Max(X0, C.D.SX0);
  X1 := Min(X1, C.D.SX1);
  Y0 := Max(Y0, C.D.SY0);
  Y1 := Min(Y1, C.D.SY1);
  Result := (X0 <= X1) and (Y0 <= Y1);
end;

procedure AddPages(var Pages: TPS2GSPages; First, Last: Integer);
begin
  if Last - First >= 511 then
    Last := First + 511;
  for var P := First to Last do
    Pages[(P and 511) shr 5] := Pages[(P and 511) shr 5] or (Cardinal(1) shl (P and 31));
end;

// The pages holding pixels X0..X1, Y0..Y1 (not negative) of buffer BP
// (blocks), BW (64 pixels) in format PSM, as TPS2GSAddressing places them.
procedure AddRectPages(var Pages: TPS2GSPages; BP, BW, PSM: Cardinal; X0, Y0, X1, Y1: Integer);
begin
  var PW := 64;
  var PH := 32;
  var Cols := Integer(BW);
  case PSM of
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      PH := 64;
    PSMT8:
      begin
        PW := 128;
        PH := 64;
        Cols := (Cols + 1) shr 1;
      end;
    PSMT4:
      begin
        PW := 128;
        PH := 128;
        Cols := (Cols + 1) shr 1;
      end;
  end;
  var PX0 := X0 div PW;
  var PX1 := X1 div PW;
  var PY0 := Y0 div PH;
  var PY1 := Y1 div PH;
  if (PX1 - PX0 + 1) * (PY1 - PY0 + 1) >= 512 then
  begin
    FillChar(Pages, SizeOf(Pages), $FF);
    Exit;
  end;
  // A base inside a page puts each page of the buffer across two.
  var Base := Integer(BP shr 5);
  var Extra := Ord((BP and 31) <> 0);
  for var PY := PY0 to PY1 do
    AddPages(Pages, Base + PY * Cols + PX0, Base + PY * Cols + PX1 + Extra);
end;

function PagesOverlap(const A, B: TPS2GSPages): Boolean;
begin
  var PA := PUInt64(@A);
  var PB := PUInt64(@B);
  for var I := 0 to SizeOf(A) div 8 - 1 do
    if (PA[I] and PB[I]) <> 0 then
      Exit(True);
  Result := False;
end;

// Formats whose pixels share one arrangement and address unit
// (TPS2GSMemory.Locate).
function AddressClass(PSM: Cardinal): Integer;
begin
  case PSM of
    PSMZ32, PSMZ24: Result := 1;
    PSMCT16: Result := 2;
    PSMCT16S: Result := 3;
    PSMZ16: Result := 4;
    PSMZ16S: Result := 5;
    PSMT8: Result := 6;
    PSMT4: Result := 7;
  else
    Result := 0;
  end;
end;

// The range of sprite pixels P0..P1's value, interpolated from A at vertex
// coordinate C0 to B at C1 (12.4) as TPS2GSDrawer.DrawSprite steps it.
procedure SpriteSpan(A, B: Double; C0, C1, P0, P1: Integer; out Lo, Hi: Double);
begin
  var First := A;
  var Last := A;
  if C1 <> C0 then
  begin
    var Slope := (B - A) / (C1 - C0);
    First := A + (P0 * 16 - C0) * Slope;
    Last := A + (P1 * 16 - C0) * Slope;
  end;
  if First < Last then
  begin
    Lo := First;
    Hi := Last;
  end
  else
  begin
    Lo := Last;
    Hi := First;
  end;
end;

// One axis of TexelRect: Lo..Hi in 1/16 texels of level 0 to the texels of
// level Level that SampleLevel fetches for them.
procedure TexelAxis(Lo, Hi, Level: Integer; Linear: Boolean; Size, Mode, MinC, MaxC: Integer; out C0, C1: Integer);
begin
  Lo := Integer(Sar(Lo, Level));
  Hi := Integer(Sar(Hi, Level));
  if Linear then
  begin
    C0 := Integer(Sar(Lo - 8, 4));
    C1 := Integer(Sar(Hi - 8, 4)) + 1;
  end
  else
  begin
    C0 := Integer(Sar(Lo, 4));
    C1 := Integer(Sar(Hi, 4));
  end;
  case Mode of
    0:
      if (C1 - C0 >= Size - 1) or ((C0 and (Size - 1)) > (C1 and (Size - 1))) then
      begin
        C0 := 0;
        C1 := Size - 1;
      end
      else
      begin
        C0 := C0 and (Size - 1);
        C1 := C1 and (Size - 1);
      end;
    1:
      begin
        C0 := EnsureRange(C0, 0, Size - 1);
        C1 := EnsureRange(C1, 0, Size - 1);
      end;
    2:
      if MinC <= MaxC then
      begin
        C0 := EnsureRange(C0, MinC, MaxC);
        C1 := EnsureRange(C1, MinC, MaxC);
      end
      else
      begin
        C0 := MaxC;
        C1 := MinC;
      end;
  else
    // (C and MinC) or MaxC
    C0 := MaxC;
    C1 := MinC or MaxC;
  end;
end;

// The texels of mipmap level Level a sprite or triangle may sample
// (inclusive): from the coordinates at its vertices (a triangle's pixels
// interpolate between them, perspective too when the Qs share a sign) or
// its first and last pixels (sprites), with a margin for the rounding.
// False when any texel may be (points, lines, unbounded coordinates).
function TexelRect(const C: TPS2GSCommand; Level: Integer; out U0, V0, U1, V1: Integer): Boolean;
var
  ULo, UHi, VLo, VHi: Double;
begin
  Result := False;
  case C.Kind of
    gpSprite:
      begin
        var X0, Y0, X1, Y1: Integer;
        if not PixelRect(C, X0, Y0, X1, Y1) then
          Exit;
        var A, B, TA, TB: Double;
        if C.D.FST then
        begin
          A := C.V[0].U;
          B := C.V[1].U;
          TA := C.V[0].V;
          TB := C.V[1].V;
        end
        else
        begin
          var Q0 := C.V[0].Q;
          var Q1 := C.V[1].Q;
          if Q0 = 0 then Q0 := 1;
          if Q1 = 0 then Q1 := 1;
          A := C.V[0].S / Q0 * (1 shl C.D.TW) * 16;
          B := C.V[1].S / Q1 * (1 shl C.D.TW) * 16;
          TA := C.V[0].T / Q0 * (1 shl C.D.TH) * 16;
          TB := C.V[1].T / Q1 * (1 shl C.D.TH) * 16;
        end;
        SpriteSpan(A, B, C.V[0].X, C.V[1].X, X0, X1, ULo, UHi);
        SpriteSpan(TA, TB, C.V[0].Y, C.V[1].Y, Y0, Y1, VLo, VHi);
      end;
    gpTriangle:
      begin
        var SW := Double(1 shl C.D.TW) * 16;
        var TH := Double(1 shl C.D.TH) * 16;
        if not C.D.FST and not (((C.V[0].Q > 0) and (C.V[1].Q > 0) and (C.V[2].Q > 0)) or
          ((C.V[0].Q < 0) and (C.V[1].Q < 0) and (C.V[2].Q < 0))) then
          Exit;
        for var K := 0 to 2 do
        begin
          var U, V: Double;
          if C.D.FST then
          begin
            U := C.V[K].U;
            V := C.V[K].V;
          end
          else
          begin
            U := C.V[K].S / C.V[K].Q * SW;
            V := C.V[K].T / C.V[K].Q * TH;
          end;
          // Also false for NaNs.
          if not ((Abs(U) < 4194304) and (Abs(V) < 4194304)) then
            Exit;
          if K = 0 then
          begin
            ULo := U;
            UHi := U;
            VLo := V;
            VHi := V;
          end
          else
          begin
            if U < ULo then ULo := U;
            if U > UHi then UHi := U;
            if V < VLo then VLo := V;
            if V > VHi then VHi := V;
          end;
        end;
      end;
  else
    Exit;
  end;
  // Also false for NaNs.
  if not ((ULo > -4194304) and (UHi < 4194304) and (VLo > -4194304) and (VHi < 4194304)) then
    Exit;
  var W := Max(1, (1 shl C.D.TW) shr Level);
  var H := Max(1, (1 shl C.D.TH) shr Level);
  var MinU := C.D.MINU shr Level;
  var MaxU := C.D.MAXU shr Level;
  var MinV := C.D.MINV shr Level;
  var MaxV := C.D.MAXV shr Level;
  if C.D.WMS = 3 then
  begin
    MinU := C.D.MINU;
    MaxU := C.D.MAXU;
  end;
  if C.D.WMT = 3 then
  begin
    MinV := C.D.MINV;
    MaxV := C.D.MAXV;
  end;
  var Linear := C.D.Linear or (C.D.UseLod and (C.D.MMIN in [1, 4, 5]));
  // FastRound is within one of the value, whatever the rounding.
  TexelAxis(FastRound(ULo) - 3, FastRound(UHi) + 3, Level, Linear, W, C.D.WMS, MinU, MaxU, U0, U1);
  TexelAxis(FastRound(VLo) - 3, FastRound(VHi) + 3, Level, Linear, H, C.D.WMT, MinV, MaxV, V0, V1);
  Result := True;
end;
// The pages a primitive's texture levels may be read from.
procedure TexturePages(const D: TPS2GSDraw; Level: Integer; out First, Last: Integer);
begin
  var W := Max(1, (1 shl D.TW) shr Level);
  var H := Max(1, (1 shl D.TH) shr Level);
  if D.WMS >= 2 then
    W := Max(W, D.MAXU + 1);
  if D.WMS = 3 then
    W := 1024;
  if D.WMT >= 2 then
    H := Max(H, D.MAXV + 1);
  if D.WMT = 3 then
    H := 1024;
  PageSpan(D.LevelTBP[Level], D.LevelTBW[Level], D.TPSM, W - 1, 0, H - 1, First, Last);
end;

// The mipmap levels a primitive may sample: from the LOD of its vertices'
// Q (pixels interpolate between them; one level more each side for edge
// pixels), as TPS2GSDrawer.Texel picks them.
procedure TextureLevels(const C: TPS2GSCommand; out First, Last: Integer);
begin
  First := 0;
  Last := 0;
  if not C.D.UseLod or (C.D.MMIN < 2) or (C.D.MXL = 0) then
    Exit;
  var D: PPS2GSDraw := @C.D;
  var LodMin, LodMax: Double;
  if D.LCM or D.FST then
  begin
    LodMin := D.K;
    LodMax := D.K;
  end
  else
  begin
    var N := 1;
    var Q0 := C.V[0].Q;
    case C.Kind of
      gpLine, gpSprite: Q0 := C.V[1].Q;
      gpTriangle: N := 3;
    end;
    var QMin := Q0;
    var QMax := Q0;
    for var K := 1 to N - 1 do
    begin
      QMin := Min(QMin, C.V[K].Q);
      QMax := Max(QMax, C.V[K].Q);
    end;
    if not ((QMin > 0) or (QMax < 0)) then
    begin
      // Q crosses zero (or is NaN): any level.
      First := 0;
      Last := D.MXL;
      Exit;
    end;
    var AMin := Max(Min(Abs(QMin), Abs(QMax)), 1E-30);
    var AMax := Max(Max(Abs(QMin), Abs(QMax)), 1E-30);
    LodMin := -Log2(AMax) * (1 shl D.LShift) + D.K;
    LodMax := -Log2(AMin) * (1 shl D.LShift) + D.K;
  end;
  if LodMax < 0 then
    Exit;
  First := Max(0, Trunc(Max(LodMin, 0)) - 1);
  if LodMax >= D.MXL then
    Last := D.MXL
  else
    Last := Min(D.MXL, Trunc(LodMax) + 2);
end;

// Whether pixels X0..X1 (from 0) of rows up to Y1 of a buffer in format
// PSM, width BW, are all at different addresses (no column beyond the
// width, no page twice around the memory).
function Distinct(PSM, BW: Cardinal; X1, Y1: Integer): Boolean;
begin
  var PW := 64;
  var PH := 32;
  var Cols := Integer(BW);
  case PSM of
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      PH := 64;
    PSMT8:
      begin
        PW := 128;
        PH := 64;
        Cols := (Cols + 1) shr 1;
      end;
    PSMT4:
      begin
        PW := 128;
        PH := 128;
        Cols := (Cols + 1) shr 1;
      end;
  end;
  Result := (X1 < PW * Cols) and ((Y1 div PH + 1) * Cols <= 512);
end;

// One axis of SpriteIdentity: A at vertex coordinate C0 to B at C1 (12.4)
// step one texel per pixel, under a texel past pixels P0..P1, which the wrap
// mode leaves alone.
function IdentityAxis(A, B: Double; C0, C1, P0, P1, Size, Mode, MinC, MaxC: Integer): Boolean;
begin
  if (C1 = C0) or (B - A <> C1 - C0) then
    Exit(False);
  // The coordinate (1/16 texels) at pixel P is D + 16 P; the drawer's
  // stepping rounds it by less than 1/1000 unless it is whole.
  var D := A - C0;
  if not ((D >= 0) and (D <= 15.999) and ((D = Int(D)) or (D >= 0.001))) then
    Exit(False);
  case Mode of
    0, 1: Result := P1 < Size;
    2: Result := (P0 >= MinC) and (P1 <= MaxC);
  else
    Result := False;
  end;
end;

// Whether each pixel of a point-sampled sprite (pixels X0..X1, Y0..Y1)
// reads the texel at its own coordinates.
function SpriteIdentity(const C: TPS2GSCommand; X0, Y0, X1, Y1: Integer): Boolean;
begin
  if (C.Kind <> gpSprite) or C.D.Linear or C.D.UseLod then
    Exit(False);
  var A, B, TA, TB: Double;
  if C.D.FST then
  begin
    A := C.V[0].U;
    B := C.V[1].U;
    TA := C.V[0].V;
    TB := C.V[1].V;
  end
  else
  begin
    var Q0 := C.V[0].Q;
    var Q1 := C.V[1].Q;
    if Q0 = 0 then Q0 := 1;
    if Q1 = 0 then Q1 := 1;
    A := C.V[0].S / Q0 * (1 shl C.D.TW) * 16;
    B := C.V[1].S / Q1 * (1 shl C.D.TW) * 16;
    TA := C.V[0].T / Q0 * (1 shl C.D.TH) * 16;
    TB := C.V[1].T / Q1 * (1 shl C.D.TH) * 16;
  end;
  Result := IdentityAxis(A, B, C.V[0].X, C.V[1].X, X0, X1, 1 shl C.D.TW, C.D.WMS, C.D.MINU, C.D.MAXU) and
    IdentityAxis(TA, TB, C.V[0].Y, C.V[1].Y, Y0, Y1, 1 shl C.D.TH, C.D.WMT, C.D.MINV, C.D.MAXV);
end;

// The memory a primitive touches: the pages it draws in (frame, and depth// when tested or written) and reads as texture; Feedback when what it reads
// may be what it draws (another band's rows, or a pixel drawn before).
procedure Footprint(const C: TPS2GSCommand; out F: TPS2GSFootprint);
begin
  FillChar(F, SizeOf(F), 0);
  F.WritesZ := not C.D.ZMSK;
  // The depth test reads the depth buffer.
  F.UsesZ := F.WritesZ or (C.D.ZTST >= 2);
  var X0, Y0, X1, Y1: Integer;
  if not PixelRect(C, X0, Y0, X1, Y1) then
    Exit;
  AddRectPages(F.Frame, C.D.FBP, C.D.FBW, C.D.FPSM, X0, Y0, X1, Y1);
  if F.UsesZ then
    AddRectPages(F.Depth, C.D.ZBP, C.D.FBW, C.D.ZPSM, X0, Y0, X1, Y1);
  // Depth over the frame's own memory: a word may hold one pixel's colour
  // and another row's depth.
  if F.UsesZ and PagesOverlap(F.Depth, F.Frame) then
    F.Feedback := True;
  if not C.D.TME then
    Exit;
  var L0, L1: Integer;
  TextureLevels(C, L0, L1);
  for var L := L0 to L1 do
  begin
    var Pages: TPS2GSPages;
    FillChar(Pages, SizeOf(Pages), 0);
    var TBP := C.D.LevelTBP[L];
    var TBW := C.D.LevelTBW[L];
    var U0, V0, U1, V1: Integer;
    var Bounded := TexelRect(C, L, U0, V0, U1, V1);
    if Bounded then
      AddRectPages(Pages, TBP, TBW, C.D.TPSM, U0, V0, U1, V1)
    else
    begin
      var T0, T1: Integer;
      TexturePages(C.D, L, T0, T1);
      AddPages(Pages, T0, T1);
    end;
    for var I := 0 to High(Pages) do
      F.Texture[I] := F.Texture[I] or Pages[I];
    // Texels of the very buffer it draws, all at different addresses: only
    // those of its own pixels' rectangle are drawn, and a pixel reading its
    // own place reads it before drawing it.
    var Meet := Bounded and (U0 <= X1) and (U1 >= X0) and (V0 <= Y1) and (V1 >= Y0) and
      not SpriteIdentity(C, X0, Y0, X1, Y1);
    // The high byte of words (8H, 4HL, 4HH) the 24-bit formats keep.
    var HighByte := C.D.TPSM in [PSMT8H, PSMT4HL, PSMT4HH];
    if Bounded and (TBP = C.D.FBP) and (TBW = C.D.FBW) and (AddressClass(C.D.TPSM) = AddressClass(C.D.FPSM)) and
      Distinct(C.D.FPSM, TBW, Max(X1, U1), Max(Y1, V1)) then
      F.Feedback := F.Feedback or Meet
    else if PagesOverlap(Pages, F.Frame) and not (HighByte and (C.D.FPSM in [PSMCT24, PSMZ24])) then
      F.Feedback := True;
    if F.WritesZ then
      if Bounded and (TBP = C.D.ZBP) and (TBW = C.D.FBW) and (AddressClass(C.D.TPSM) = AddressClass(C.D.ZPSM)) and
        Distinct(C.D.ZPSM, TBW, Max(X1, U1), Max(Y1, V1)) then
        F.Feedback := F.Feedback or Meet
      else if PagesOverlap(Pages, F.Depth) and not (HighByte and (C.D.ZPSM = PSMZ24)) then
        F.Feedback := True;
  end;
end;

// The pages a primitive reads (texture, frame, depth) and writes.
procedure FootprintAccess(const F: TPS2GSFootprint; out Reads, Writes: TPS2GSPages);
begin
  for var I := 0 to High(Reads) do
  begin
    Reads[I] := F.Texture[I] or F.Frame[I] or F.Depth[I];
    Writes[I] := F.Frame[I];
    if F.WritesZ then
      Writes[I] := Writes[I] or F.Depth[I];
  end;
end;

function BufferKey(BP, BW, PSM: Cardinal): UInt64; inline;
begin
  Result := UInt64(BP) or (UInt64(BW) shl 20) or (UInt64(PSM) shl 32) or (UInt64(1) shl 40);
end;

// Whether a page of Pages that the queued primitives wrote they drew
// through another buffer than Key.
function TPS2GSRaster.OwnedElsewhere(const Pages: TPS2GSPages; Key: UInt64): Boolean;
begin
  for var I := 0 to High(Pages) do
  begin
    var Bits := Pages[I] and FWritten[I];
    var P := I * 32;
    while Bits <> 0 do
    begin
      if (Bits and $FF) = 0 then
      begin
        Bits := Bits shr 8;
        Inc(P, 8);
        Continue;
      end;
      if ((Bits and 1) <> 0) and (FPageOwner[P] <> Key) then
        Exit(True);
      Bits := Bits shr 1;
      Inc(P);
    end;
  end;
  Result := False;
end;

// Whether a primitive must wait for the queued ones: it reads as texture a
// page they write, writes a page they read as texture, or writes a page they
// draw through another buffer (another band's rows). (Reading its own
// target, F.Feedback, it is drawn alone.)
function TPS2GSRaster.Hazard(const C: TPS2GSCommand; const F: TPS2GSFootprint): Boolean;
begin
  if PagesOverlap(F.Texture, FWritten) or PagesOverlap(F.Frame, FRead) or
    (F.WritesZ and PagesOverlap(F.Depth, FRead)) then
    Exit(True);
  // Depth tested or written through another buffer than the queued
  // primitives wrote those pages through: another band's rows.
  Result := OwnedElsewhere(F.Frame, BufferKey(C.D.FBP, C.D.FBW, C.D.FPSM)) or
    (F.UsesZ and OwnedElsewhere(F.Depth, BufferKey(C.D.ZBP, C.D.FBW, C.D.ZPSM)));
end;

procedure TPS2GSRaster.MarkQueued(const C: TPS2GSCommand; const F: TPS2GSFootprint);
begin
  var FKey := BufferKey(C.D.FBP, C.D.FBW, C.D.FPSM);
  var ZKey := BufferKey(C.D.ZBP, C.D.FBW, C.D.ZPSM);
  for var I := 0 to High(FWritten) do
  begin
    var Bits := F.Frame[I];
    var P := I * 32;
    while Bits <> 0 do
    begin
      if (Bits and $FF) = 0 then
      begin
        Bits := Bits shr 8;
        Inc(P, 8);
        Continue;
      end;
      if (Bits and 1) <> 0 then
        FPageOwner[P] := FKey;
      Bits := Bits shr 1;
      Inc(P);
    end;
    FWritten[I] := FWritten[I] or F.Frame[I];
    if F.WritesZ then
    begin
      Bits := F.Depth[I];
      P := I * 32;
      while Bits <> 0 do
      begin
        if (Bits and $FF) = 0 then
        begin
          Bits := Bits shr 8;
          Inc(P, 8);
          Continue;
        end;
        if (Bits and 1) <> 0 then
          FPageOwner[P] := ZKey;
        Bits := Bits shr 1;
        Inc(P);
      end;
      FWritten[I] := FWritten[I] or F.Depth[I];
    end;
    FRead[I] := FRead[I] or F.Texture[I];
  end;
end;

// Before an accelerated draw: the band threads finish the queued commands
// when it reads what they write or writes what they touch (or, a small one,
// it is declined: False); a palettized one takes the CLUT the first band
// thread loaded last.
procedure TPS2GSRaster.NoteRoute;
begin
  case FRoute of
    rtAccelerated: Inc(FRecentAccepted);
    rtUnsupported: Inc(FRecentFallbacks);
  end;
  if FRecentAccepted + FRecentFallbacks >= 4096 then
  begin
    FRecentAccepted := FRecentAccepted div 2;
    FRecentFallbacks := FRecentFallbacks div 2;
  end;
end;

function TPS2GSRaster.BeforeAccelerated(const Reads, Writes: TPS2GSPages; Palette: Boolean; Area: Int64): Boolean;
begin
  FlushTransfer;
  Result := True;
  FRoute := rtAccelerated;
  if not FPending then
    Exit;
  if PagesOverlap(Reads, FPendingWrites) or PagesOverlap(Writes, FPendingWrites) or
    PagesOverlap(Writes, FPendingReads) then
  begin
    // Mostly software lately (three primitives in four the accelerator
    // cannot take): a small draw joins the band threads rather than waiting
    // for them (both paths draw the same pixels).
    if (Area < 65536) and (FRecentFallbacks >= 3 * FRecentAccepted) then
    begin
      FRoute := rtDeclined;
      Exit(False);
    end;
    SyncSoftware;
    Exit;
  end;
  if Palette and (FClutSlot >= 0) and not FClutChanged then
  begin
    FBands.WaitFirst(FClutLoaded[FClutSlot]);
    FClut := FClutRing[FClutSlot];
  end;
end;

// The pages a queued primitive writes, until the next Sync.
procedure TPS2GSRaster.MarkPendingDraw(const F: TPS2GSFootprint);
begin
  for var I := 0 to High(FPendingWrites) do
  begin
    FPendingReads[I] := FPendingReads[I] or F.Texture[I] or F.Depth[I];
    FPendingWrites[I] := FPendingWrites[I] or F.Frame[I];
    if F.WritesZ then
      FPendingWrites[I] := FPendingWrites[I] or F.Depth[I];
  end;
end;
// The pages a queued transfer's destination area may cover, until the next
// Sync.
procedure TPS2GSRaster.MarkPendingArea(const Regs: array of UInt64);
begin
  var Buf := Regs[0];
  var Pos := Regs[1];
  var Reg := Regs[2];
  var DSAX := Integer((Pos shr 32) and $7FF);
  var DSAY := Integer((Pos shr 48) and $7FF);
  var X1 := Min(2047, DSAX + Integer(Reg and $FFF));
  var Y1 := Min(2047, DSAY + Integer((Reg shr 32) and $FFF));
  var P0, P1: Integer;
  PageSpan(Cardinal((Buf shr 32) and $3FFF), Cardinal((Buf shr 48) and $3F), Cardinal((Buf shr 56) and $3F),
    X1, DSAY, Y1, P0, P1);
  MarkPages(FPendingWrites, P0, P1);
end;

procedure TPS2GSRaster.Draw(Kind: TPS2GSPrimitive; const V0, V1, V2: TPS2GSVertex);
begin
  // CPU primitives must see all earlier GPU writes. Sprites decide after
  // clipping whether they can join the batch or need the software path.
  if (FAccelerator <> nil) and (not (Kind in [gpSprite, gpTriangle]) or (PrimLog <> nil) or (WatchX >= 0)) then
    Sync;
  Inc(FPrimitives);
  FCommand.Kind := Kind;
  FCommand.Rounding := GetRoundMode;
  FCommand.Clut := -1;
  FCommand.D := FD;
  FCommand.V[0] := V0;
  FCommand.V[1] := V1;
  FCommand.V[2] := V2;
  // Diagnostics see the primitives drawn in order, here.
  if (FBands = nil) or (FAccelerator <> nil) or (PrimLog <> nil) or (WatchX >= 0) then
  begin
    // GPU acceptance publishes CPU bands first. A fallback can instead
    // join the software queue after publishing pending GPU writes.
    if FPending and (FAccelerator = nil) then Sync;
    var Before := FDrawer.PixelsDrawn;
    FRoute := rtNone;
    FDrawer.Draw(FCommand);
    Inc(FPixels, FDrawer.PixelsDrawn - Before);
    if FAccelerator <> nil then
      NoteRoute;
    Exit;
  end;
  var Before := FCounter.PixelsDrawn;
  FCounter.Draw(FCommand);
  FCommandPixels := FCounter.PixelsDrawn - Before;
  Inc(FPixels, FCommandPixels);
  var F: TPS2GSFootprint;
  Footprint(FCommand, F);
  QueueDraw(F);
end;

function TPS2GSRaster.QueueFallback(Drawer: TPS2GSDrawer): Boolean;
begin
  Result := (Drawer = FDrawer) and (FAccelerator <> nil) and Queueing;
  if not Result then Exit;
  if FRoute = rtNone then
    FRoute := rtUnsupported;
  // Only the emulation thread touches the GPU. Workers receive ordinary
  // software commands; queued GPU work on pages they touch finishes first.
  var F: TPS2GSFootprint;
  Footprint(FCommand, F);
  if FAccelerator.Pending then
  begin
    var Reads, Writes: TPS2GSPages;
    FootprintAccess(F, Reads, Writes);
    FAccelerator.AccessPages(Reads, Writes);
  end;
  var Before := FCounter.PixelsDrawn;
  FCounter.Draw(FCommand);
  FCommandPixels := FCounter.PixelsDrawn - Before;
  Inc(Drawer.FPixels, FCommandPixels);
  QueueDraw(F);
end;

procedure TPS2GSRaster.QueueDraw(const F: TPS2GSFootprint);
begin
  FlushTransfer;
  // Overlapping the queued primitives: the band threads first finish them;
  // reading its own target: the first band thread draws it alone.
  var Feedback := F.Feedback;
  FCommand.Op := coDraw;
  if Hazard(FCommand, F) then
    FCommand.Op := coBarrier;
  if Feedback then
    FCommand.Op := coSoloDraw;
  if FCommand.D.TME and (FCommand.D.TPSM in [PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH]) then
  begin
    // A palettized texture: its CLUT as it is now, in a slot of the ring.
    if FClutChanged or (FClutSlot < 0) then
    begin
      FClutSlot := (FClutSlot + 1) mod Length(FClutRing);
      FBands.WaitFor(FClutUse[FClutSlot]);
      Move(FClut, FClutRing[FClutSlot], SizeOf(FClut));
      FClutLoaded[FClutSlot] := 0;
      FClutChanged := False;
    end;
    FCommand.Clut := FClutSlot;
    FClutUse[FClutSlot] := FBands.Position + 1;
  end;
  {$IFDEF GS_RACECHECK}
  if FCommand.Op <> coDraw then RaceBarrier(FBands.Position);
  if FCommand.Op = coSoloDraw then RaceBarrier(FBands.Position + 1);
  RaceDescribe(FBands.Position, Format('%d op%d fbp %x/%d/%x tbp %x/%d/%x tme %d zbp %x/%x zmsk %d', [Ord(FCommand.Kind), Ord(FCommand.Op), FCommand.D.FBP, FCommand.D.FBW, FCommand.D.FPSM, FCommand.D.TBP, FCommand.D.TBW, FCommand.D.TPSM, Ord(FCommand.D.TME), FCommand.D.ZBP, FCommand.D.ZPSM, Ord(FCommand.D.ZMSK)]));
  {$ENDIF}
  Inc(QueuedOps[Ord(FCommand.Op)]);
  FBands.Next^ := FCommand;
  if FCommand.Op = coDraw then
    FBands.Publish(16 + Integer(Min(FCommandPixels, TPS2GSBands.WakeWeight)))
  else
    FBands.Publish;
  MarkPendingDraw(F);
  if FCommand.Op <> coDraw then
    ClearOverlap;
  if FCommand.Op <> coSoloDraw then
    MarkQueued(FCommand, F);
  FPending := True;
end;

procedure TPS2GSRaster.Reset;
begin
  Sync;
  FXferGPURevision := -1;
  FillChar(Regs, SizeOf(Regs), 0);
  FSignal := False;
  FFinish := False;
  SigLblId := 0;
  FQueueCount := 0;
  FStripIndex := 0;
  FCurrent := Default(TPS2GSVertex);
  FQ := 1;
  FillChar(FClut, SizeOf(FClut), 0);
  FClutChanged := True;
  FCBP0 := 0;
  FCBP1 := 0;
  FXferActive := False;
  FXferBits := 0;
  FXferBitCount := 0;
  FReadBuffer := nil;
  FReadPos := 0;
  Regs[GSRegPRMODECONT] := 1;
  FMemory.Clear;
end;

procedure TPS2GSRaster.ClearSignal;
begin
  FSignal := False;
end;

procedure TPS2GSRaster.SetFinish;
begin
  FFinish := True;
  if Assigned(FOnSignal) then
    FOnSignal();
end;

procedure TPS2GSRaster.ClearFinish;
begin
  FFinish := False;
end;

function SingleOf(V: Cardinal): Single; inline;
begin
  Result := PSingle(@V)^;
end;

procedure TPS2GSRaster.WriteRegister(Index: Integer; Value: UInt64);
begin
  Index := Index and $7F;
  if PrimLog <> nil then
    LogRegister(Index, Value);
  // Queued transferred pixels go with the transfer registers they came with.
  if (FXferRunCount > 0) and ((Index = GSRegBITBLTBUF) or (Index = GSRegTRXPOS) or (Index = GSRegTRXREG)) then
    FlushTransfer;
  if Index in [GSRegBITBLTBUF, GSRegTRXPOS, GSRegTRXREG, GSRegTRXDIR] then
    FXferGPURevision := -1;
  Regs[Index] := Value;
  case Index of
    GSRegPRIM:
      begin
        FQueueCount := 0;
        FStripIndex := 0;
      end;
    GSRegRGBAQ:
      begin
        FCurrent.R := Integer(Value and $FF);
        FCurrent.G := Integer((Value shr 8) and $FF);
        FCurrent.B := Integer((Value shr 16) and $FF);
        FCurrent.A := Integer((Value shr 24) and $FF);
        FCurrent.Q := SingleOf(Cardinal(Value shr 32));
      end;
    GSRegST:
      begin
        FCurrent.S := SingleOf(Cardinal(Value));
        FCurrent.T := SingleOf(Cardinal(Value shr 32));
      end;
    GSRegUV:
      begin
        FCurrent.U := Integer(Value and $3FFF);
        FCurrent.V := Integer((Value shr 16) and $3FFF);
      end;
    GSRegFOG:
      FCurrent.F := Integer((Value shr 56) and $FF);
    GSRegXYZF2, GSRegXYZF3:
      begin
        FCurrent.X := Integer(Value and $FFFF);
        FCurrent.Y := Integer((Value shr 16) and $FFFF);
        FCurrent.Z := Cardinal((Value shr 32) and $FFFFFF);
        FCurrent.F := Integer((Value shr 56) and $FF);
        Kick(Index = GSRegXYZF2);
      end;
    GSRegXYZ2, GSRegXYZ3:
      begin
        FCurrent.X := Integer(Value and $FFFF);
        FCurrent.Y := Integer((Value shr 16) and $FFFF);
        FCurrent.Z := Cardinal(Value shr 32);
        Kick(Index = GSRegXYZ2);
      end;
    GSRegTEX0_1, GSRegTEX0_2:
      LoadClut(Value);
    GSRegTEX2_1, GSRegTEX2_2:
      begin
        // TEX2 replaces the CLUT/format fields of TEX0.
        var T := GSRegTEX0_1 + (Index - GSRegTEX2_1);
        var Mask: UInt64 := (UInt64($3F) shl 20) or (UInt64($FFFFFFF) shl 37);
        Regs[T] := (Regs[T] and not Mask) or (Value and Mask);
        LoadClut(Regs[T]);
      end;
    GSRegTRXDIR:
      StartTransfer;
    GSRegHWREG:
      begin
        FeedWord(Cardinal(Value));
        FeedWord(Cardinal(Value shr 32));
      end;
    GSRegSIGNAL:
      begin
        var Mask := Value shr 32;
        SigLblId := (SigLblId and not Mask) or (Value and Mask and $FFFFFFFF);
        FSignal := True;
        if Assigned(FOnSignal) then
          FOnSignal();
      end;
    GSRegFINISH:
      if Assigned(FOnFinish) then
        FOnFinish()
      else
        SetFinish;
    GSRegLABEL:
      begin
        var Mask := (Value shr 32) shl 32;
        SigLblId := (SigLblId and not Mask) or ((Value shl 32) and Mask);
      end;
  end;
end;

{ Primitives }

procedure TPS2GSRaster.SetupDraw;
begin
  var Attr := Regs[GSRegPRIM];
  if (Regs[GSRegPRMODECONT] and 1) = 0 then
    Attr := (Attr and 7) or (Regs[GSRegPRMODE] and not UInt64(7));
  var D := Default(TPS2GSDraw);
  D.IIP := (Attr and $8) <> 0;
  D.TME := (Attr and $10) <> 0;
  D.FGE := (Attr and $20) <> 0;
  D.ABE := (Attr and $40) <> 0;
  D.FST := (Attr and $100) <> 0;
  D.Ctx := Integer((Attr shr 9) and 1);
  var C := D.Ctx;
  var Frame := Regs[GSRegFRAME_1 + C];
  D.FBP := Cardinal(Frame and $1FF) * 32;
  D.FBW := Cardinal((Frame shr 16) and $3F);
  D.FPSM := Cardinal((Frame shr 24) and $3F);
  D.FBMSK := Cardinal(Frame shr 32);
  var ZBuf := Regs[GSRegZBUF_1 + C];
  D.ZBP := Cardinal(ZBuf and $1FF) * 32;
  D.ZPSM := Cardinal((ZBuf shr 24) and $F) or $30;
  D.ZMSK := (ZBuf and (UInt64(1) shl 32)) <> 0;
  var Sc := Regs[GSRegSCISSOR_1 + C];
  D.SX0 := Integer(Sc and $7FF);
  D.SX1 := Integer((Sc shr 16) and $7FF);
  D.SY0 := Integer((Sc shr 32) and $7FF);
  D.SY1 := Integer((Sc shr 48) and $7FF);
  var Test := Regs[GSRegTEST_1 + C];
  D.ATE := (Test and 1) <> 0;
  D.ATST := Integer((Test shr 1) and 7);
  D.AREF := Integer((Test shr 4) and $FF);
  D.AFAIL := Integer((Test shr 12) and 3);
  D.DATE := (Test and $4000) <> 0;
  D.DATM := (Test and $8000) <> 0;
  D.ZTE := (Test and $10000) <> 0;
  D.ZTST := Integer((Test shr 17) and 3);
  if not D.ZTE then
    D.ZTST := 1;
  var Alpha := Regs[GSRegALPHA_1 + C];
  D.BlendA := Integer(Alpha and 3);
  D.BlendB := Integer((Alpha shr 2) and 3);
  D.BlendC := Integer((Alpha shr 4) and 3);
  D.BlendD := Integer((Alpha shr 6) and 3);
  D.BlendFix := Integer((Alpha shr 32) and $FF);
  D.PABE := (Regs[GSRegPABE] and 1) <> 0;
  D.FBA := (Regs[GSRegFBA_1 + C] and 1) <> 0;
  D.ColClamp := (Regs[GSRegCOLCLAMP] and 1) <> 0;
  var Tex0 := Regs[GSRegTEX0_1 + C];
  D.TBP := Cardinal(Tex0 and $3FFF);
  D.TBW := Cardinal((Tex0 shr 14) and $3F);
  D.TPSM := Cardinal((Tex0 shr 20) and $3F);
  D.TW := Cardinal((Tex0 shr 26) and $F);
  D.TH := Cardinal((Tex0 shr 30) and $F);
  if D.TW > 10 then
    D.TW := 10;
  if D.TH > 10 then
    D.TH := 10;
  D.TCC := (Tex0 and (UInt64(1) shl 34)) <> 0;
  D.TFX := Integer((Tex0 shr 35) and 3);
  var Clamp := Regs[GSRegCLAMP_1 + C];
  D.WMS := Integer(Clamp and 3);
  D.WMT := Integer((Clamp shr 2) and 3);
  D.MINU := Integer((Clamp shr 4) and $3FF);
  D.MAXU := Integer((Clamp shr 14) and $3FF);
  D.MINV := Integer((Clamp shr 24) and $3FF);
  D.MAXV := Integer((Clamp shr 34) and $3FF);
  var Tex1 := Regs[GSRegTEX1_1 + C];
  D.Linear := (Tex1 and $20) <> 0;
  D.MMIN := Integer((Tex1 shr 6) and 7);
  if D.MMIN > 5 then
    D.MMIN := 5;
  D.MXL := Integer((Tex1 shr 2) and 7);
  if D.MXL > 6 then
    D.MXL := 6;
  D.LCM := (Tex1 and 1) <> 0;
  D.LShift := Integer((Tex1 shr 19) and 3);
  // K: signed, 4 fraction bits.
  var KRaw := Integer((Tex1 shr 32) and $FFF);
  if KRaw >= $800 then
    Dec(KRaw, $1000);
  D.K := KRaw / 16;
  D.UseLod := (D.MMIN >= 2) or ((D.MMIN = 1) <> D.Linear);
  D.LevelTBP[0] := D.TBP;
  D.LevelTBW[0] := D.TBW;
  var Mip1 := Regs[GSRegMIPTBP1_1 + C];
  var Mip2 := Regs[GSRegMIPTBP2_1 + C];
  for var L := 0 to 2 do
  begin
    D.LevelTBP[1 + L] := Cardinal((Mip1 shr (L * 20)) and $3FFF);
    D.LevelTBW[1 + L] := Cardinal((Mip1 shr (L * 20 + 14)) and $3F);
    D.LevelTBP[4 + L] := Cardinal((Mip2 shr (L * 20)) and $3FFF);
    D.LevelTBW[4 + L] := Cardinal((Mip2 shr (L * 20 + 14)) and $3F);
  end;
  var TexA := Regs[GSRegTEXA];
  D.TA0 := Integer(TexA and $FF);
  D.AEM := (TexA and $8000) <> 0;
  D.TA1 := Integer((TexA shr 32) and $FF);
  var FogCol := Regs[GSRegFOGCOL];
  D.FogR := Integer(FogCol and $FF);
  D.FogG := Integer((FogCol shr 8) and $FF);
  D.FogB := Integer((FogCol shr 16) and $FF);
  case D.ZPSM of
    PSMZ24: D.ZMax := $FFFFFF;
    PSMZ16, PSMZ16S: D.ZMax := $FFFF;
  else
    D.ZMax := $FFFFFFFF;
  end;
  D.FB16 := (D.FPSM = PSMCT16) or (D.FPSM = PSMCT16S) or (D.FPSM = PSMZ16) or (D.FPSM = PSMZ16S);
  D.FB24 := (D.FPSM = PSMCT24) or (D.FPSM = PSMZ24);
  D.DstRead := D.DATE or (D.ABE and ((D.BlendA = 1) or (D.BlendB = 1) or (D.BlendC = 1) or (D.BlendD = 1))) or
    (D.FBMSK <> 0);
  D.Clut32 := Integer((Tex0 shr 51) and $F) = PSMCT32;
  if (D.TPSM = PSMT4) or (D.TPSM = PSMT4HL) or (D.TPSM = PSMT4HH) then
    D.ClutOffset := Integer((Tex0 shr 56) and $1F) * 16;
  FD := D;
end;

procedure TPS2GSRaster.Kick(DrawingKick: Boolean);
begin
  var Attr := Regs[GSRegPRIM];
  if (Regs[GSRegPRMODECONT] and 1) = 0 then
    Attr := (Attr and 7) or (Regs[GSRegPRMODE] and not UInt64(7));
  var C := Integer((Attr shr 9) and 1);
  var Off := Regs[GSRegXYOFFSET_1 + C];
  var V := FCurrent;
  V.X := FCurrent.X - Integer(Off and $FFFF);
  V.Y := FCurrent.Y - Integer((Off shr 32) and $FFFF);
  var Prim := Integer(Regs[GSRegPRIM] and 7);
  case Prim of
    0:
      begin
        if DrawingKick then
        begin
          SetupDraw;
          Draw(gpPoint, V, V, V);
        end;
      end;
    1, 6:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 2 then
        begin
          FQueueCount := 0;
          if DrawingKick then
          begin
            SetupDraw;
            if Prim = 1 then
              Draw(gpLine, FQueue[0], FQueue[1], FQueue[1])
            else
              Draw(gpSprite, FQueue[0], FQueue[1], FQueue[1]);
          end;
        end;
      end;
    2:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 2 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            Draw(gpLine, FQueue[0], FQueue[1], FQueue[1]);
          end;
          FQueue[0] := FQueue[1];
          FQueueCount := 1;
        end;
      end;
    3:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          FQueueCount := 0;
          if DrawingKick then
          begin
            SetupDraw;
            Draw(gpTriangle, FQueue[0], FQueue[1], FQueue[2]);
          end;
        end;
      end;
    4:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            Draw(gpTriangle, FQueue[0], FQueue[1], FQueue[2]);
          end;
          FQueue[0] := FQueue[1];
          FQueue[1] := FQueue[2];
          FQueueCount := 2;
        end;
      end;
    5:
      begin
        FQueue[FQueueCount] := V;
        Inc(FQueueCount);
        if FQueueCount = 3 then
        begin
          if DrawingKick then
          begin
            SetupDraw;
            Draw(gpTriangle, FQueue[0], FQueue[1], FQueue[2]);
          end;
          FQueue[1] := FQueue[2];
          FQueueCount := 2;
        end;
      end;
  end;
end;

{ TPS2GSDrawer }

constructor TPS2GSDrawer.Create(Owner: TPS2GSRaster; Band, BandCount: Integer; CountOnly: Boolean);
begin
  inherited Create;
  FOwner := Owner;
  FMemory := Owner.FMemory;
  FBand := Band;
  FBandCount := BandCount;
  FCountOnly := CountOnly;
end;

function TPS2GSDrawer.InBand(Y: Integer): Boolean;
begin
  Result := (FBandCount <= 1) or ((Cardinal(Y) shr 3) mod Cardinal(FBandCount) = Cardinal(FBand));
end;

procedure TPS2GSDrawer.Draw(const Command: TPS2GSCommand);
begin
  FD := Command.D;
  FWatch := (FOwner.WatchX >= 0) and (FOwner.PrimLog <> nil);
  if not FCountOnly then
  begin
    FFrameAddr.Init(Integer(FD.FPSM), FD.FBP, FD.FBW);
    FDepthAddr.Init(Integer(FD.ZPSM), FD.ZBP, FD.FBW);
    FLevelsReady := 0;
  end;
  if Command.Clut < 0 then
    FClut := @FOwner.FClut[0]
  else
    FClut := @FOwner.FClutRing[Command.Clut][0];
  case Command.Kind of
    gpPoint: DrawPoint(Command.V[0]);
    gpLine: DrawLine(Command.V[0], Command.V[1]);
    gpTriangle: DrawTriangle(Command.V[0], Command.V[1], Command.V[2]);
    gpSprite: DrawSprite(Command.V[0], Command.V[1]);
  end;
end;

function TPS2GSDrawer.ClampCoord(C, Size, Mode, MinC, MaxC: Integer): Integer;
begin
  case Mode of
    0: Result := C and (Size - 1);
    1:
      if C < 0 then
        Result := 0
      else if C >= Size then
        Result := Size - 1
      else
        Result := C;
    2:
      if C < MinC then
        Result := MinC
      else if C > MaxC then
        Result := MaxC
      else
        Result := C;
  else
    Result := (C and MinC) or MaxC;
  end;
end;

function ExpandTexA(V: Cardinal; TA0, TA1: Integer; AEM: Boolean): Cardinal; inline;
begin
  // 16-bit RGBA5551 to 32-bit with TEXA alpha.
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

function TPS2GSDrawer.TexelAt(const L: TPS2GSTexLevel; TU, TV: Integer): Cardinal;
begin
  var Raw := FMemory.ReadAt(Integer(FD.TPSM), L.Addr.Addr(Cardinal(TU), Cardinal(TV)));
  case FD.TPSM of
    PSMCT32, PSMZ32:
      Result := Raw;
    PSMCT24, PSMZ24:
      begin
        var A := FD.TA0;
        if FD.AEM and ((Raw and $FFFFFF) = 0) then
          A := 0;
        Result := (Raw and $FFFFFF) or (Cardinal(A) shl 24);
      end;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
      Result := ExpandTexA(Raw, FD.TA0, FD.TA1, FD.AEM);
  else
    begin
      // Palettized: CLUT entry.
      var Index := Integer(Raw) + FD.ClutOffset;
      if FD.Clut32 then
      begin
        Index := Index and 255;
        Result := Cardinal(FClut[Index]) or (Cardinal(FClut[Index + 256]) shl 16);
      end
      else
        Result := ExpandTexA(FClut[Index and 511], FD.TA0, FD.TA1, FD.AEM);
    end;
  end;
end;

// LOD = log2(1/Q) * 2^L + K (GS User's Manual, texture mapping), or K
// alone with LCM.
procedure TPS2GSDrawer.SetLod(Q: Single);
begin
  if FD.LCM then
    FLod := FD.K
  else
  begin
    if Q < 0 then
      Q := -Q;
    if Q < 1E-30 then
      Q := 1E-30;
    FLod := -Log2(Q) * (1 shl FD.LShift) + FD.K;
  end;
end;

// One texel of mipmap level Level (U, V in level-0 texels, 4 fraction
// bits), point sampled or bilinear.
procedure TPS2GSDrawer.PrepareLevel(Level: Integer);
begin
  var L: PPS2GSTexLevel := @FLevels[Level];
  L.Addr.Init(Integer(FD.TPSM), FD.LevelTBP[Level], FD.LevelTBW[Level]);
  L.W := Max(1, (1 shl FD.TW) shr Level);
  L.H := Max(1, (1 shl FD.TH) shr Level);
  L.MinU := FD.MINU shr Level;
  L.MaxU := FD.MAXU shr Level;
  L.MinV := FD.MINV shr Level;
  L.MaxV := FD.MAXV shr Level;
  if FD.WMS = 3 then
  begin
    L.MinU := FD.MINU;
    L.MaxU := FD.MAXU;
  end;
  if FD.WMT = 3 then
  begin
    L.MinV := FD.MINV;
    L.MaxV := FD.MAXV;
  end;
  FLevelsReady := FLevelsReady or (Cardinal(1) shl Level);
end;

function TPS2GSDrawer.SampleLevel(Level, U, V: Integer; Linear: Boolean): Cardinal;
begin
  if (FLevelsReady and (Cardinal(1) shl Level)) = 0 then
    PrepareLevel(Level);
  var L: PPS2GSTexLevel := @FLevels[Level];
  U := Integer(Sar(U, Level));
  V := Integer(Sar(V, Level));
  if not Linear then
  begin
    var TU := ClampCoord(Integer(Sar(U, 4)), L.W, FD.WMS, L.MinU, L.MaxU);
    var TV := ClampCoord(Integer(Sar(V, 4)), L.H, FD.WMT, L.MinV, L.MaxV);
    Exit(TexelAt(L^, TU, TV));
  end;
  var U0 := Integer(Sar(U - 8, 4));
  var V0 := Integer(Sar(V - 8, 4));
  var FU := Cardinal((U - 8) and 15);
  var FV := Cardinal((V - 8) and 15);
  var CU0 := ClampCoord(U0, L.W, FD.WMS, L.MinU, L.MaxU);
  var CV0 := ClampCoord(V0, L.H, FD.WMT, L.MinV, L.MaxV);
  var A := TexelAt(L^, CU0, CV0);
  // On a texel's centre (no fraction) the next column or row weighs nothing.
  if (FU or FV) = 0 then
    Exit(A);
  var B := A;
  var C := A;
  var D := A;
  if FU <> 0 then
  begin
    var CU1 := ClampCoord(U0 + 1, L.W, FD.WMS, L.MinU, L.MaxU);
    B := TexelAt(L^, CU1, CV0);
    if FV <> 0 then
    begin
      var CV1 := ClampCoord(V0 + 1, L.H, FD.WMT, L.MinV, L.MaxV);
      C := TexelAt(L^, CU0, CV1);
      D := TexelAt(L^, CU1, CV1);
    end;
  end
  else
  begin
    var CV1 := ClampCoord(V0 + 1, L.H, FD.WMT, L.MinV, L.MaxV);
    C := TexelAt(L^, CU0, CV1);
  end;
  // Two channels at a time (R and B, G and A): no channel's sum carries
  // past its 16 bits.
  var TopRB := (A and $00FF00FF) * (16 - FU) + (B and $00FF00FF) * FU;
  var BottomRB := (C and $00FF00FF) * (16 - FU) + (D and $00FF00FF) * FU;
  var TopGA := ((A shr 8) and $00FF00FF) * (16 - FU) + ((B shr 8) and $00FF00FF) * FU;
  var BottomGA := ((C shr 8) and $00FF00FF) * (16 - FU) + ((D shr 8) and $00FF00FF) * FU;
  Result := (((TopRB * (16 - FV) + BottomRB * FV) shr 8) and $00FF00FF) or
    ((((TopGA * (16 - FV) + BottomGA * FV) shr 8) and $00FF00FF) shl 8);
end;

// A negative LOD magnifies (MMAG); otherwise MMIN filters level 0 or picks
// mipmap levels up to MXL: the nearest one, or the two around the LOD
// blended by its fraction.
function TPS2GSDrawer.Texel(U, V: Integer): Cardinal;
begin
  if not FD.UseLod then
    Exit(SampleLevel(0, U, V, FD.Linear));
  var Lod := FLod;
  if Lod < 0 then
    Exit(SampleLevel(0, U, V, FD.Linear));
  var Bilinear := FD.MMIN in [1, 4, 5];
  if (FD.MMIN <= 1) or (FD.MXL = 0) then
    Exit(SampleLevel(0, U, V, Bilinear));
  if FD.MMIN in [2, 4] then
    Exit(SampleLevel(Min(Trunc(Lod + 0.5), FD.MXL), U, V, Bilinear));
  var L0 := Trunc(Lod);
  if L0 >= FD.MXL then
    Exit(SampleLevel(FD.MXL, U, V, Bilinear));
  var Frac := Round((Lod - L0) * 16);
  var A := SampleLevel(L0, U, V, Bilinear);
  if Frac <= 0 then
    Exit(A);
  var B := SampleLevel(L0 + 1, U, V, Bilinear);
  // Frac is 1..16; two channels at a time as in SampleLevel.
  var W := Cardinal(Frac);
  Result := ((((A and $00FF00FF) * (16 - W) + (B and $00FF00FF) * W) shr 4) and $00FF00FF) or
    ((((((A shr 8) and $00FF00FF) * (16 - W) + ((B shr 8) and $00FF00FF) * W) shr 4) and $00FF00FF) shl 8);
end;

// One channel of the blend (A - B) * C / 128 + D; A, B and D select the
// source colour S (0), the destination colour D (1) or zero.
function BlendTerm(SelA, S, D, SelB, C, SelD: Integer): Integer; inline;
begin
  var VA := 0;
  if SelA = 0 then VA := S else if SelA = 1 then VA := D;
  var VB := 0;
  if SelB = 0 then VB := S else if SelB = 1 then VB := D;
  var VD := 0;
  if SelD = 0 then VD := S else if SelD = 1 then VD := D;
  Result := Integer(Sar((VA - VB) * C, 7)) + VD;
end;

procedure TPS2GSDrawer.Pixel(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
begin
  if (X < FD.SX0) or (X > FD.SX1) or (Y < FD.SY0) or (Y > FD.SY1) then
    Exit;
  Inc(FPixels);
  if FCountOnly then
    Exit;
  Shade(X, Y, Z, R, G, B, A, F, U, V);
end;

// A pixel inside the scissor, counted already.
procedure TPS2GSDrawer.Shade(X, Y: Integer; Z: Cardinal; R, G, B, A, F: Integer; U, V: Integer);
var
  Mask: Cardinal;
begin
  if FAccelerating then
  begin
    FOwner.FAccelerator.Fragment(X, Y, Z, R, G, B, A, F, U, V, FLod);
    Exit;
  end;
  // A failed depth test cannot write either colour or depth, regardless
  // of the texture/alpha test. Reject it before expensive texture reads.
  // Coverage counters above still include every scissored pixel (GS timing).
  if Z > FD.ZMax then
    Z := FD.ZMax;
  var ZA: Cardinal := 0;
  if FD.ZTST <> 1 then
  begin
    if FD.ZTST = 0 then
      Exit;
    ZA := FDepthAddr.Addr(Cardinal(X), Cardinal(Y));
    if not FZPassed then
    begin
      var Old := FMemory.ReadAt(Integer(FD.ZPSM), ZA);
      if (FD.ZTST = 2) and (Z < Old) then
        Exit;
      if (FD.ZTST = 3) and (Z <= Old) then
        Exit;
    end;
  end;
  if FD.TME then
  begin
    var T := Texel(U, V);
    var TR := Integer(T and $FF);
    var TG := Integer((T shr 8) and $FF);
    var TB := Integer((T shr 16) and $FF);
    var TA := Integer(T shr 24);
    case FD.TFX of
      0:
        begin
          R := (R * TR) shr 7;
          G := (G * TG) shr 7;
          B := (B * TB) shr 7;
          if FD.TCC then
            A := (A * TA) shr 7;
        end;
      1:
        begin
          R := TR;
          G := TG;
          B := TB;
          if FD.TCC then
            A := TA;
        end;
      2, 3:
        begin
          R := ((R * TR) shr 7) + A;
          G := ((G * TG) shr 7) + A;
          B := ((B * TB) shr 7) + A;
          if FD.TCC then
          begin
            if FD.TFX = 2 then
              A := TA + A
            else
              A := TA;
          end;
        end;
    end;
    if R > 255 then R := 255;
    if G > 255 then G := 255;
    if B > 255 then B := 255;
    if A > 255 then A := 255;
  end;
  if FD.FGE then
  begin
    R := (F * R + (255 - F) * FD.FogR) shr 8;
    G := (F * G + (255 - F) * FD.FogG) shr 8;
    B := (F * B + (255 - F) * FD.FogB) shr 8;
  end;
  var WriteFB := True;
  var WriteZ := not FD.ZMSK;
  var WriteAlpha := True;
  if FD.ATE then
  begin
    var Pass: Boolean;
    case FD.ATST of
      0: Pass := False;
      1: Pass := True;
      2: Pass := A < FD.AREF;
      3: Pass := A <= FD.AREF;
      4: Pass := A = FD.AREF;
      5: Pass := A >= FD.AREF;
      6: Pass := A > FD.AREF;
    else
      Pass := A <> FD.AREF;
    end;
    if not Pass then
      case FD.AFAIL of
        0: Exit;
        1: WriteZ := False;
        2: WriteFB := False;
      else
        begin
          WriteZ := False;
          WriteAlpha := False;
        end;
      end;
  end;
  // With an always-passing test, locate depth only when alpha permits a
  // write; a rejecting alpha test may have disabled it.
  if (FD.ZTST = 1) and WriteZ then
    ZA := FDepthAddr.Addr(Cardinal(X), Cardinal(Y));
  // Destination colour.
  var Dst: Cardinal := 0;
  var FA := FFrameAddr.Addr(Cardinal(X), Cardinal(Y));
  if FD.DstRead or not WriteAlpha then
  begin
    var Raw := FMemory.ReadAt(Integer(FD.FPSM), FA);
    if FD.FB16 then
      Dst := ((Raw and $1F) shl 3) or (((Raw shr 5) and $1F) shl 11) or (((Raw shr 10) and $1F) shl 19) or
        (((Raw shr 15) and 1) shl 31)
    else if FD.FB24 then
      Dst := (Raw and $FFFFFF) or $80000000
    else
      Dst := Raw;
  end;
  if FD.DATE then
  begin
    var Bit := (Dst shr 31) <> 0;
    if Bit <> FD.DATM then
      Exit;
  end;
  if FD.ABE and (not FD.PABE or (A >= 128)) then
  begin
    var DR := Integer(Dst and $FF);
    var DG := Integer((Dst shr 8) and $FF);
    var DB := Integer((Dst shr 16) and $FF);
    var CC: Integer;
    case FD.BlendC of
      0: CC := A;
      1: CC := Integer(Dst shr 24);
    else
      CC := FD.BlendFix;
    end;
    var NR := BlendTerm(FD.BlendA, R, DR, FD.BlendB, CC, FD.BlendD);
    var NG := BlendTerm(FD.BlendA, G, DG, FD.BlendB, CC, FD.BlendD);
    B := BlendTerm(FD.BlendA, B, DB, FD.BlendB, CC, FD.BlendD);
    R := NR;
    G := NG;
  end;
  if FD.ColClamp then
  begin
    R := Clamp255(R);
    G := Clamp255(G);
    B := Clamp255(B);
  end
  else
  begin
    R := R and $FF;
    G := G and $FF;
    B := B and $FF;
  end;
  if FD.FBA then
    A := A or $80;
  if FWatch and (X = FOwner.WatchX) and (Y = FOwner.WatchY) then
    LogWatch(X, Y, WriteFB, WriteZ and WriteFB or (WriteZ and (FD.AFAIL = 2)), R, G, B, A, Z);
  if WriteFB then
  begin
    var Color := Cardinal(R) or (Cardinal(G) shl 8) or (Cardinal(B) shl 16) or (Cardinal(A and $FF) shl 24);
    Mask := FD.FBMSK;
    if not WriteAlpha then
      Mask := Mask or $FF000000;
    if Mask <> 0 then
      Color := (Color and not Mask) or (Dst and Mask);
    if FD.FB16 then
      FMemory.WriteAt(Integer(FD.FPSM), FA, Color32To16(Color))
    else
      FMemory.WriteAt(Integer(FD.FPSM), FA, Color);
  end;
  if WriteZ and WriteFB or (WriteZ and (FD.AFAIL = 2)) then
    FMemory.WriteAt(Integer(FD.ZPSM), ZA, Z);
end;

// The diagnostics' lines are written apart, so that the drawing routines keep
// no string temporaries.
procedure TPS2GSRaster.LogRegister(Index: Integer; Value: UInt64);
begin
  if (PrimLog.Count < 200000) and (Index in [6, 7, $14, $15, $16, $17, $18, $19, $1C, $3B, $40, $41, $42, $43, $47, $48, $4C,
    $4D, $4E, $4F, $50, $51, $52, $53]) then
    PrimLog.Add(Format('reg %.2x = %.16x', [Index, Value]));
end;

procedure TPS2GSDrawer.LogWatch(X, Y: Integer; WriteFB, WriteZ: Boolean; R, G, B, A: Integer; Z: Cardinal);
begin
  FOwner.PrimLog.Add(Format('watch %d,%d fb=%s z=%s rgba=%d,%d,%d,%d zval=%x fbp=%x zbp=%x', [X, Y, BoolToStr(WriteFB, True),
    BoolToStr(WriteZ, True), R, G, B, A, Z, FD.FBP, FD.ZBP]));
end;

procedure TPS2GSDrawer.LogSprite(const V0, V1: TPS2GSVertex);
begin
  FOwner.PrimLog.Add(Format('sprite %d,%d-%d,%d uv=%d,%d-%d,%d st=%g,%g q=%g rgba=%d,%d,%d,%d tme=%s fst=%s abe=%s fbp=%x fbw=%d fpsm=%x msk=%x tbp=%x tbw=%d tpsm=%x tw=%d th=%d tcc=%s tfx=%d ate=%s atst=%d aref=%d afail=%d zte=%s ztst=%d blend=%d%d%d%d fix=%d z=%x zbp=%x zpsm=%x zmsk=%s',
    [V0.X div 16, V0.Y div 16, V1.X div 16, V1.Y div 16, V0.U div 16, V0.V div 16, V1.U div 16, V1.V div 16, V0.S, V0.T, V0.Q,
    V1.R, V1.G, V1.B, V1.A, BoolToStr(FD.TME, True), BoolToStr(FD.FST, True), BoolToStr(FD.ABE, True), FD.FBP, FD.FBW, FD.FPSM,
    FD.FBMSK, FD.TBP, FD.TBW, FD.TPSM, FD.TW, FD.TH, BoolToStr(FD.TCC, True), FD.TFX, BoolToStr(FD.ATE, True), FD.ATST, FD.AREF,
    FD.AFAIL, BoolToStr(FD.ZTE, True), FD.ZTST, FD.BlendA, FD.BlendB, FD.BlendC, FD.BlendD, FD.BlendFix, V1.Z, FD.ZBP, FD.ZPSM,
    BoolToStr(FD.ZMSK, True)]));
end;

procedure TPS2GSDrawer.LogTriangle(const V0, V1, V2: TPS2GSVertex);
begin
  FOwner.PrimLog.Add(Format('tri %d,%d %d,%d %d,%d uv=%d,%d %d,%d st=%g,%g,%g q=%g rgba=%d,%d,%d,%d tme=%s fge=%s fog=%d,%d,%d z=%x,%x,%x fst=%s abe=%s fbp=%x fbw=%d fpsm=%x tbp=%x tbw=%d tpsm=%x tw=%d th=%d tcc=%s tfx=%d ate=%s atst=%d aref=%d zte=%s ztst=%d blend=%d%d%d%d fix=%d iip=%s',
    [V0.X div 16, V0.Y div 16, V1.X div 16, V1.Y div 16, V2.X div 16, V2.Y div 16, V0.U div 16, V0.V div 16, V2.U div 16, V2.V div 16,
    V0.S, V0.T, V2.S, V0.Q, V0.R, V0.G, V0.B, V0.A, BoolToStr(FD.TME, True), BoolToStr(FD.FGE, True), V0.F, V1.F, V2.F, V0.Z, V1.Z, V2.Z,
    BoolToStr(FD.FST, True), BoolToStr(FD.ABE, True), FD.FBP, FD.FBW, FD.FPSM,
    FD.TBP, FD.TBW, FD.TPSM, FD.TW, FD.TH, BoolToStr(FD.TCC, True), FD.TFX, BoolToStr(FD.ATE, True), FD.ATST, FD.AREF,
    BoolToStr(FD.ZTE, True), FD.ZTST, FD.BlendA, FD.BlendB, FD.BlendC, FD.BlendD, FD.BlendFix, BoolToStr(FD.IIP, True)]));
end;

procedure TPS2GSRaster.CheckPrimLogBreak;
begin
  PrimLogBreak := 0;
  if Assigned(OnPrimLogBreak) then
    OnPrimLogBreak();
end;

procedure TPS2GSDrawer.DrawPoint(const V: TPS2GSVertex);
begin
  if FD.UseLod then
    if FD.FST then
      SetLod(1)
    else
      SetLod(V.Q);
  var U := V.U;
  var TV := V.V;
  if FD.TME and not FD.FST then
  begin
    var Q := V.Q;
    if Q = 0 then
      Q := 1;
    U := TexCoord(V.S / Q * (1 shl FD.TW) * 16);
    TV := TexCoord(V.T / Q * (1 shl FD.TH) * 16);
  end;
  var Y := Integer(Sar(V.Y + 8, 4));
  if InBand(Y) then
    Pixel(Integer(Sar(V.X + 8, 4)), Y, V.Z, V.R, V.G, V.B, V.A, V.F, U, TV);
end;

procedure TPS2GSDrawer.DrawLine(const V0, V1: TPS2GSVertex);
begin
  if FD.UseLod then
    if FD.FST then
      SetLod(1)
    else
      SetLod(V1.Q);
  var DX := V1.X - V0.X;
  var DY := V1.Y - V0.Y;
  var Steps := Max(Abs(DX), Abs(DY)) shr 4;
  // Lines longer than the 2048x2048 drawing space come from garbage vertices.
  if Steps > 4096 then
    Exit;
  if Steps = 0 then
    Steps := 1;
  for var K := 0 to Steps do
  begin
    var T := K / Steps;
    var X := Integer(EnsureRange((Int64(V0.X) + Round(DX * T) + 8) div 16, -1, 4096));
    var Y := Integer(EnsureRange((Int64(V0.Y) + Round(DY * T) + 8) div 16, -1, 4096));
    if not InBand(Y) then
      Continue;
    var R := V1.R;
    var G := V1.G;
    var B := V1.B;
    var A := V1.A;
    if FD.IIP then
    begin
      R := V0.R + Round((V1.R - V0.R) * T);
      G := V0.G + Round((V1.G - V0.G) * T);
      B := V0.B + Round((V1.B - V0.B) * T);
      A := V0.A + Round((V1.A - V0.A) * T);
    end;
    var Z := Cardinal(EnsureRange(Round(V0.Z + (Double(V1.Z) - V0.Z) * T), 0, Int64($FFFFFFFF)));
    var F := V0.F + Round((V1.F - V0.F) * T);
    var U := V0.U + Round((V1.U - V0.U) * T);
    var TV := V0.V + Round((V1.V - V0.V) * T);
    if FD.TME and not FD.FST then
    begin
      var S := V0.S + (V1.S - V0.S) * T;
      var TT := V0.T + (V1.T - V0.T) * T;
      var Q := V0.Q + (V1.Q - V0.Q) * T;
      if Q = 0 then
        Q := 1;
      U := TexCoord(S / Q * (1 shl FD.TW) * 16);
      TV := TexCoord(TT / Q * (1 shl FD.TH) * 16);
    end;
    Pixel(X, Y, Z, EnsureRange(R, 0, 255), EnsureRange(G, 0, 255), EnsureRange(B, 0, 255), EnsureRange(A, 0, 255),
      EnsureRange(F, 0, 255), U, TV);
  end;
end;

procedure TPS2GSDrawer.DrawSprite(const V0, V1: TPS2GSVertex);
begin
  if not FCountOnly and FD.UseLod then
    if FD.FST then
      SetLod(1)
    else
      SetLod(V1.Q);
  if (FOwner.PrimLogBreak > 0) and (FOwner.PrimLog <> nil) and (FOwner.PrimLog.Count >= FOwner.PrimLogBreak) then
    FOwner.CheckPrimLogBreak;
  if (FOwner.PrimLog <> nil) and (FOwner.PrimLog.Count < 200000) then
    LogSprite(V0, V1);
  var X0 := V0.X;
  var X1 := V1.X;
  var Y0 := V0.Y;
  var Y1 := V1.Y;
  var PX0 := Integer(Sar(Min(X0, X1) + 15, 4));
  var PX1 := Integer(Sar(Max(X0, X1) + 15, 4));
  var PY0 := Integer(Sar(Min(Y0, Y1) + 15, 4));
  var PY1 := Integer(Sar(Max(Y0, Y1) + 15, 4));
  if PX0 < FD.SX0 then PX0 := FD.SX0;
  if PY0 < FD.SY0 then PY0 := FD.SY0;
  if PX1 > FD.SX1 + 1 then PX1 := FD.SX1 + 1;
  if PY1 > FD.SY1 + 1 then PY1 := FD.SY1 + 1;
  if (PX0 >= PX1) or (PY0 >= PY1) then
    Exit;
  if FCountOnly then
  begin
    Inc(FPixels, Int64(PX1 - PX0) * (PY1 - PY0));
    Exit;
  end;
  if (Self = FOwner.FDrawer) and (FOwner.FAccelerator <> nil) and
    (FOwner.PrimLog = nil) and (FOwner.WatchX < 0) then
    if FOwner.FAccelerator.Sprite(FD, V0, V1, PX0, PY0, PX1, PY1, FLod) then
    begin
      Inc(FPixels, Int64(PX1 - PX0) * (PY1 - PY0));
      Exit;
    end;
  if Self = FOwner.FDrawer then
  begin
    if FOwner.QueueFallback(Self) then Exit;
    if FOwner.FAccelerator <> nil then FOwner.Sync;
  end;
  // Texture coordinates along the edges (in 1/16 texels).
  var U0, U1, TV0, TV1: Double;
  if FD.FST then
  begin
    U0 := V0.U;
    U1 := V1.U;
    TV0 := V0.V;
    TV1 := V1.V;
  end
  else
  begin
    var Q0 := V0.Q;
    var Q1 := V1.Q;
    if Q0 = 0 then Q0 := 1;
    if Q1 = 0 then Q1 := 1;
    U0 := V0.S / Q0 * (1 shl FD.TW) * 16;
    U1 := V1.S / Q1 * (1 shl FD.TW) * 16;
    TV0 := V0.T / Q0 * (1 shl FD.TH) * 16;
    TV1 := V1.T / Q1 * (1 shl FD.TH) * 16;
  end;
  var DUDX := 0.0;
  if X1 <> X0 then
    DUDX := (U1 - U0) / (X1 - X0) * 16;
  var DVDY := 0.0;
  if Y1 <> Y0 then
    DVDY := (TV1 - TV0) / (Y1 - Y0) * 16;
  var ColumnsReady := False;
  for var Y := PY0 to PY1 - 1 do
  begin
    if not InBand(Y) then
      Continue;
    var VV := TexCoord(TV0 + (Y * 16 - Y0) * DVDY / 16);
    if not ColumnsReady then
    begin
      // The columns' U, the same on every row.
      if Length(FSpriteU) < PX1 - PX0 then
        SetLength(FSpriteU, PX1 - PX0);
      var UStart := U0 + (PX0 * 16 - X0) * DUDX / 16;
      for var X := PX0 to PX1 - 1 do
        FSpriteU[X - PX0] := TexCoord(UStart + (X - PX0) * DUDX);
      ColumnsReady := True;
    end;
    // All inside the scissor.
    Inc(FPixels, PX1 - PX0);
    for var X := PX0 to PX1 - 1 do
      Shade(X, Y, V1.Z, V1.R, V1.G, V1.B, V1.A, V1.F, FSpriteU[X - PX0], VV);
  end;
end;

// Narrows [KL, KR] (steps from the row start) to where E + Step * K >= 0;
// False when no step qualifies.
function EdgeSpan(E, Step: Int64; var KL, KR: Int64): Boolean;
begin
  Result := True;
  if Step > 0 then
  begin
    // K >= ceil(-E / Step)
    var N := -E;
    var K: Int64;
    if N <= 0 then
      K := -((-N) div Step)
    else
      K := (N + Step - 1) div Step;
    if K > KL then
      KL := K;
  end
  else if Step < 0 then
  begin
    // K <= floor(E / -Step)
    var D := -Step;
    var K: Int64;
    if E >= 0 then
      K := E div D
    else
      K := -((-E + D - 1) div D);
    if K < KR then
      KR := K;
  end
  else if E < 0 then
    Result := False;
end;

// Pixels X0..X1 of row Y, all inside the triangle: E0 and E1 are the edge
// functions of vertices 0 and 1 at X0 (positive inside), stepping by Step0
// and Step1 per pixel.
procedure TPS2GSDrawer.FillTriangle(const T: TPS2GSTriangle; Y, X0, X1: Integer; E0, E1, Step0, Step1: Int64);
begin
  // All inside the scissor.
  Inc(FPixels, X1 - X0 + 1);
  for var X := X0 to X1 do
  begin
    var W0 := E0 * T.InvArea;
    var W1 := E1 * T.InvArea;
    var W2 := 1.0 - W0 - W1;
    // The depth goes through a Currency (in 1/10000, rounded as the host
    // rounds), as it always has; truncating that is its units div 10000
    // (an integer part cannot be reached by the rounding of the division).
    var Depth: Cardinal := 0;
    if T.NeedZ then
    begin
      var ZD: Currency := W0 * T.Z[0] + W1 * T.Z[1] + W2 * T.Z[2];
      if ZD < 0 then
        ZD := 0;
      if ZD > 4294967295.0 then
        ZD := 4294967295.0;
      Depth := Cardinal(PInt64(@ZD)^ div 10000);
    end;
    if T.EarlyZ then
    begin
      // Pixel's depth test, before working out the rest: a pixel failing
      // it is only counted.
      var Z := Depth;
      if Z > FD.ZMax then
        Z := FD.ZMax;
      var Old := FMemory.ReadAt(Integer(FD.ZPSM), FDepthAddr.Addr(Cardinal(X), Cardinal(Y)));
      if (Z < Old) or ((FD.ZTST = 3) and (Z = Old)) then
      begin
        Inc(E0, Step0);
        Inc(E1, Step1);
        Continue;
      end;
    end;
    var R := FastRound(W0 * T.R[0] + W1 * T.R[1] + W2 * T.R[2]);
    var G := FastRound(W0 * T.G[0] + W1 * T.G[1] + W2 * T.G[2]);
    var B := FastRound(W0 * T.B[0] + W1 * T.B[1] + W2 * T.B[2]);
    var A := FastRound(W0 * T.A[0] + W1 * T.A[1] + W2 * T.A[2]);
    var F := 0;
    if FD.FGE then
      F := FastRound(W0 * T.F[0] + W1 * T.F[1] + W2 * T.F[2]);
    var U, TV: Integer;
    if FD.TME then
    begin
      if FD.FST then
      begin
        var UD := W0 * T.U[0] + W1 * T.U[1] + W2 * T.U[2];
        var VD := W0 * T.V[0] + W1 * T.V[1] + W2 * T.V[2];
        U := TexCoordOf(UD);
        TV := TexCoordOf(VD);
      end
      else
      begin
        var Q := W0 * T.Q[0] + W1 * T.Q[1] + W2 * T.Q[2];
        if FD.UseLod then
          SetLod(Q);
        if Q = 0 then
          Q := 1;
        var UD := (W0 * T.S[0] + W1 * T.S[1] + W2 * T.S[2]) / Q * T.SW;
        var VD := (W0 * T.T[0] + W1 * T.T[1] + W2 * T.T[2]) / Q * T.TH;
        U := TexCoordOf(UD);
        TV := TexCoordOf(VD);
      end;
    end
    else
    begin
      U := 0;
      TV := 0;
    end;
    Shade(X, Y, Depth, Clamp255(R), Clamp255(G), Clamp255(B), Clamp255(A), Clamp255(F), U, TV);
    Inc(E0, Step0);
    Inc(E1, Step1);
  end;
end;

procedure TPS2GSDrawer.DrawTriangle(const V0, V1, V2: TPS2GSVertex);
begin
  if not FCountOnly and FD.UseLod then
    if FD.FST then
      SetLod(1)
    else
      SetLod(V2.Q);
  if (FOwner.PrimLogBreak > 0) and (FOwner.PrimLog <> nil) and (FOwner.PrimLog.Count >= FOwner.PrimLogBreak) then
    FOwner.CheckPrimLogBreak;
  if (FOwner.PrimLog <> nil) and (FOwner.PrimLog.Count < 200000) then
    LogTriangle(V0, V1, V2);
  var X0 := Int64(V0.X);
  var Y0 := Int64(V0.Y);
  var X1 := Int64(V1.X);
  var Y1 := Int64(V1.Y);
  var X2 := Int64(V2.X);
  var Y2 := Int64(V2.Y);
  var Area := (X1 - X0) * (Y2 - Y0) - (X2 - X0) * (Y1 - Y0);
  if Area = 0 then
    Exit;
  // Bounding box in pixels (sample points at integer pixel coordinates).
  var MinX := Sar(Min(X0, Min(X1, X2)) + 15, 4);
  var MaxX := Sar(Max(X0, Max(X1, X2)), 4);
  var MinY := Sar(Min(Y0, Min(Y1, Y2)) + 15, 4);
  var MaxY := Sar(Max(Y0, Max(Y1, Y2)), 4);
  if MinX < FD.SX0 then MinX := FD.SX0;
  if MinY < FD.SY0 then MinY := FD.SY0;
  if MaxX > FD.SX1 then MaxX := FD.SX1;
  if MaxY > FD.SY1 then MaxY := FD.SY1;
  if (MinX > MaxX) or (MinY > MaxY) then
    Exit;
  var Sign: Int64 := 1;
  if Area < 0 then
    Sign := -1;
  // Edge functions E_i (opposite vertex i), positive inside (times Sign).
  // Top-left rule: an edge that is not top or left needs E > 0.
  var A0 := (Y1 - Y2) * Sign;
  var B0 := (X2 - X1) * Sign;
  var A1 := (Y2 - Y0) * Sign;
  var B1 := (X0 - X2) * Sign;
  var A2 := (Y0 - Y1) * Sign;
  var B2 := (X1 - X0) * Sign;
  var Bias0: Int64 := 0;
  var Bias1: Int64 := 0;
  var Bias2: Int64 := 0;
  if not ((A0 > 0) or ((A0 = 0) and (B0 > 0))) then Bias0 := -1;
  if not ((A1 > 0) or ((A1 = 0) and (B1 > 0))) then Bias1 := -1;
  if not ((A2 > 0) or ((A2 = 0) and (B2 > 0))) then Bias2 := -1;
  var CountCoverage := FCountOnly;
  if not CountCoverage and (Self = FOwner.FDrawer) and (FOwner.FAccelerator <> nil) and
    (FOwner.PrimLog = nil) and (FOwner.WatchX < 0) then
    CountCoverage := FOwner.FAccelerator.Triangle(FD, V0, V1, V2, Integer(MinX), Integer(MinY),
      Integer(MaxX + 1), Integer(MaxY + 1));
  if CountCoverage then
  begin
    // Count the exact scissored coverage, not a second pixel/render walk.
    // No LOD, attribute interpolation, depth or texture work is needed for
    // the timing counter on the emulation thread.
    var PX := Int64(MinX) * 16;
    for var Y := MinY to MaxY do
    begin
      if not InBand(Y) then Continue;
      var PY := Int64(Y) * 16;
      var E0 := A0 * (PX - X1) + B0 * (PY - Y1) + Bias0;
      var E1 := A1 * (PX - X2) + B1 * (PY - Y2) + Bias1;
      var E2 := A2 * (PX - X0) + B2 * (PY - Y0) + Bias2;
      var KL: Int64 := 0;
      var KR: Int64 := MaxX - MinX;
      if EdgeSpan(E0, A0 * 16, KL, KR) and EdgeSpan(E1, A1 * 16, KL, KR) and
        EdgeSpan(E2, A2 * 16, KL, KR) and (KL <= KR) then
        Inc(FPixels, KR - KL + 1);
    end;
    Exit;
  end;
  var T: TPS2GSTriangle;
  T.InvArea := 1.0 / Area;
  // Attribute values per vertex.
  T.R[0] := V0.R; T.G[0] := V0.G; T.B[0] := V0.B; T.A[0] := V0.A;
  T.R[1] := V1.R; T.G[1] := V1.G; T.B[1] := V1.B; T.A[1] := V1.A;
  T.R[2] := V2.R; T.G[2] := V2.G; T.B[2] := V2.B; T.A[2] := V2.A;
  if not FD.IIP then
  begin
    T.R[0] := V2.R; T.R[1] := V2.R;
    T.G[0] := V2.G; T.G[1] := V2.G;
    T.B[0] := V2.B; T.B[1] := V2.B;
    T.A[0] := V2.A; T.A[1] := V2.A;
  end;
  T.F[0] := V0.F; T.F[1] := V1.F; T.F[2] := V2.F;
  T.Z[0] := V0.Z; T.Z[1] := V1.Z; T.Z[2] := V2.Z;
  T.U[0] := V0.U; T.U[1] := V1.U; T.U[2] := V2.U;
  T.V[0] := V0.V; T.V[1] := V1.V; T.V[2] := V2.V;
  T.S[0] := V0.S; T.S[1] := V1.S; T.S[2] := V2.S;
  T.T[0] := V0.T; T.T[1] := V1.T; T.T[2] := V2.T;
  T.Q[0] := V0.Q; T.Q[1] := V1.Q; T.Q[2] := V2.Q;
  T.SW := Double(1 shl FD.TW) * 16;
  T.TH := Double(1 shl FD.TH) * 16;
  // Depth is only read by the test and written unless masked (the watched
  // pixel's line shows it too).
  T.NeedZ := (FD.ZTST >= 2) or not FD.ZMSK or (FOwner.WatchX >= 0);
  var Accelerated := False;
  if not FCountOnly and (Self = FOwner.FDrawer) and (FOwner.FAccelerator <> nil) then
  begin
    if (FOwner.PrimLog = nil) and (FOwner.WatchX < 0) then
      Accelerated := FOwner.FAccelerator.BeginTriangle(FD, Integer(MinX), Integer(MinY),
        Integer(MaxX + 1), Integer(MaxY + 1));
    if not Accelerated then
    begin
      if FOwner.QueueFallback(Self) then Exit;
      FOwner.Sync;
    end;
  end;
  T.EarlyZ := (FD.ZTST >= 2) and not Accelerated;
  FAccelerating := Accelerated;
  FZPassed := T.EarlyZ;
  try
  for var Y := MinY to MaxY do
  begin
    if not InBand(Y) then
      Continue;
    var PY := Int64(Y) * 16;
    var PX := Int64(MinX) * 16;
    var E0 := A0 * (PX - X1) + B0 * (PY - Y1);
    var E1 := A1 * (PX - X2) + B1 * (PY - Y2);
    var E2 := A2 * (PX - X0) + B2 * (PY - Y0);
    // The covered span of the row from the edge equations (no scan over the
    // whole bounding box for thin or mostly clipped triangles); every pixel
    // in it passes all three edge tests.
    var KL: Int64 := 0;
    var KR: Int64 := MaxX - MinX;
    if not EdgeSpan(E0 + Bias0, A0 * 16, KL, KR) or not EdgeSpan(E1 + Bias1, A1 * 16, KL, KR) or
      not EdgeSpan(E2 + Bias2, A2 * 16, KL, KR) or (KL > KR) then
      Continue;
    Inc(E0, A0 * 16 * KL);
    Inc(E1, A1 * 16 * KL);
    FillTriangle(T, Integer(Y), Integer(MinX + KL), Integer(MinX + KR), E0 * Sign, E1 * Sign,
      A0 * 16 * Sign, A1 * 16 * Sign);
  end;
  finally
    FAccelerating := False;
    FZPassed := False;
    if Accelerated then FOwner.FAccelerator.EndTriangle;
  end;
end;

{ CLUT }

procedure TPS2GSRaster.LoadClut(Tex0: UInt64);
begin
  var CLD := Integer((Tex0 shr 61) and 7);
  var CBP := Cardinal((Tex0 shr 37) and $3FFF);
  case CLD of
    0: Exit;
    1: ;
    2: FCBP0 := CBP;
    3: FCBP1 := CBP;
    4:
      begin
        if CBP = FCBP0 then
          Exit;
        FCBP0 := CBP;
      end;
    5:
      begin
        if CBP = FCBP1 then
          Exit;
        FCBP1 := CBP;
      end;
  else
    Exit;
  end;
  var PSM := Integer((Tex0 shr 20) and $3F);
  if not ((PSM = PSMT8) or (PSM = PSMT8H) or (PSM = PSMT4) or (PSM = PSMT4HL) or (PSM = PSMT4HH)) then
    Exit;
  var CPSM := Integer((Tex0 shr 51) and $F);
  var CSM := Integer((Tex0 shr 55) and 1);
  var CSA := Integer((Tex0 shr 56) and $1F);
  FlushTransfer;
  var P0, P1: Integer;
  if CSM = 0 then
    PageSpan(CBP, 1, Cardinal(CPSM), 15, 0, 15, P0, P1)
  else
  begin
    var TexClut := Regs[GSRegTEXCLUT];
    var CY := Integer((TexClut shr 12) and $3FF);
    PageSpan(CBP, Cardinal(TexClut and $3F), Cardinal(CPSM), Integer((TexClut shr 6) and $3F) * 16 + 255, CY, CY, P0,
      P1);
  end;
  // Palettes are snapshotted per GPU draw. Reading unrelated palette RAM
  // need not drain geometry whose targets are on other pages.
  if (FAccelerator <> nil) and FAccelerator.Pending then
  begin
    var GPUFirst := P0;
    var GPULast := P1;
    if CSM <> 0 then
    begin
      var TexClut := Regs[GSRegTEXCLUT];
      var CY := Integer((TexClut shr 12) and $3FF);
      var PH := 32;
      if CPSM in [PSMCT16, PSMCT16S] then PH := 64;
      var BW := Integer(TexClut and $3F);
      GPUFirst := Integer(CBP shr 5) + (CY div PH) * BW;
      GPULast := Integer((CBP + 31) shr 5) + (CY div PH) * BW +
        (Integer((TexClut shr 6) and $3F) * 16 + 255) div 64;
    end;
    FAccelerator.ReadPages(GPUFirst, GPULast);
  end;
  if Queueing and ((FAccelerator = nil) or FPending) then
  begin
    // The first band thread loads it into a new slot of the ring, after the
    // queued primitives that write its pages; the others wait for it.
    if FClutChanged or (FClutSlot < 0) then
    begin
      FClutSlot := (FClutSlot + 1) mod Length(FClutRing);
      FBands.WaitFor(FClutUse[FClutSlot]);
      Move(FClut, FClutRing[FClutSlot], SizeOf(FClut));
      FClutUse[FClutSlot] := FBands.Position;
      FClutLoaded[FClutSlot] := 0;
      FClutChanged := False;
    end;
    var Prev := FClutSlot;
    FClutSlot := (FClutSlot + 1) mod Length(FClutRing);
    FBands.WaitFor(FClutUse[FClutSlot]);
    var C := FBands.Next;
    C.Op := coClut;
    if PagesMeet(FWritten, P0, P1) then
      C.Op := coSoloClut;
    C.Rounding := GetRoundMode;
    C.Clut := FClutSlot;
    C.XferX := Prev;
    C.XferRegs[0] := Tex0;
    C.XferRegs[1] := Regs[GSRegTEXCLUT];
    {$IFDEF GS_RACECHECK}if C.Op = coSoloClut then RaceBarrier(FBands.Position); RaceBarrier(FBands.Position + 1); RaceDescribe(FBands.Position, Format('clut p%d-%d w%x cbp %x csm %d', [P0, P1, FWritten[0], CBP, CSM]));{$ENDIF}
    var Solo := C.Op = coSoloClut;
    FBands.Publish;
    FClutUse[FClutSlot] := FBands.Position;
    if FClutUse[Prev] < FBands.Position then
      FClutUse[Prev] := FBands.Position;
    if Solo then
      ClearOverlap;
    // Later primitives writing these pages wait for the load.
    MarkPages(FRead, P0, P1);
    AddPages(FPendingReads, P0, P1);
    FClutLoaded[FClutSlot] := FBands.Position;
    FPending := True;
    Exit;
  end;
  // Queued primitives keep the CLUT they were queued with; only wait for
  // them when they draw (or transfers write) where this one is read from.
  if FPending and PagesMeet(FPendingWrites, P0, P1) then
    Sync;
  FClutChanged := True;
  ReadClut(Tex0, Regs[GSRegTEXCLUT], FClut);
end;

// The entries a CLUT load (TEX0, TEXCLUT) reads from GS memory, into Clut.
procedure TPS2GSRaster.ReadClut(Tex0, TexClut: UInt64; var Clut: TPS2GSClut);
begin
  var CBP := Cardinal((Tex0 shr 37) and $3FFF);
  var PSM := Integer((Tex0 shr 20) and $3F);
  var CPSM := Integer((Tex0 shr 51) and $F);
  var CSM := Integer((Tex0 shr 55) and 1);
  var CSA := Integer((Tex0 shr 56) and $1F);
  var Count := 16;
  if (PSM = PSMT8) or (PSM = PSMT8H) then
    Count := 256
  else if not ((PSM = PSMT4) or (PSM = PSMT4HL) or (PSM = PSMT4HH)) then
    Exit;
  var Is32 := CPSM = PSMCT32;
  var Base := 0;
  if Count = 16 then
    Base := CSA * 16;
  for var I := 0 to Count - 1 do
  begin
    var X, Y: Integer;
    if CSM = 0 then
    begin
      if Count = 256 then
      begin
        var J := (I and $E7) or ((I and 8) shl 1) or ((I and $10) shr 1);
        X := J and 15;
        Y := J shr 4;
      end
      else
      begin
        X := I and 7;
        Y := I shr 3;
      end;
    end
    else
    begin
      X := Integer((TexClut shr 6) and $3F) * 16 + I;
      Y := Integer((TexClut shr 12) and $3FF);
    end;
    var BW: Cardinal := 1;
    if CSM <> 0 then
      BW := Cardinal(TexClut and $3F);
    if Is32 then
    begin
      var V := FMemory.ReadRaw(PSMCT32, CBP, BW, Cardinal(X), Cardinal(Y));
      var Slot := (Base + I) and 255;
      Clut[Slot] := Word(V);
      Clut[Slot + 256] := Word(V shr 16);
    end
    else
    begin
      var V := FMemory.ReadRaw(CPSM, CBP, BW, Cardinal(X), Cardinal(Y));
      Clut[(Base + I) and 511] := Word(V);
    end;
  end;
end;

{ Transfers }

function TransferBits(PSM: Cardinal): Integer;
begin
  case PSM of
    PSMCT32, PSMZ32: Result := 32;
    PSMCT24, PSMZ24: Result := 24;
    PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: Result := 16;
    PSMT8, PSMT8H: Result := 8;
    PSMT4, PSMT4HL, PSMT4HH: Result := 4;
  else
    Result := 32;
  end;
end;

procedure TPS2GSRaster.StartTransfer;
begin
  var Dir := Integer(Regs[GSRegTRXDIR] and 3);
  if (PrimLogBreak > 0) and (PrimLog <> nil) and (PrimLog.Count >= PrimLogBreak) then
  begin
    Sync;
    CheckPrimLogBreak;
  end;
  if (TransferLog <> nil) and (TransferLog.Count < 100000) then
    TransferLog.Add(Format('buf=%.16x pos=%.16x reg=%.16x dir=%d', [Regs[GSRegBITBLTBUF], Regs[GSRegTRXPOS],
      Regs[GSRegTRXREG], Dir]));
  FlushTransfer;
  FXferActive := False;
  FXferX := 0;
  FXferY := 0;
  FXferBits := 0;
  FXferBitCount := 0;
  FQueueXfer := Queueing;
  case Dir of
    0: FXferActive := True;
    1: LocalToHost;
    2: LocalToLocal;
  end;
end;

procedure TPS2GSRaster.BeginTransferRun;
begin
  // Reserve space for a whole run, once rather than for every input pixel.
  while (FXferRunHead < FXferRunTail) and
    (FXferRingPos + XferRunMax - FXferRuns[FXferRunHead and High(FXferRuns)].StartPos > XferRingSize) do
  begin
    FBands.WaitFor(FXferRuns[FXferRunHead and High(FXferRuns)].Position);
    Inc(FXferRunHead);
  end;
  if FXferRunTail - FXferRunHead > High(FXferRuns) then
  begin
    FBands.WaitFor(FXferRuns[FXferRunHead and High(FXferRuns)].Position);
    Inc(FXferRunHead);
  end;
  FXferRunStart := FXferRingPos;
  FXferRunX := FXferX;
  FXferRunY := FXferY;
end;

procedure TPS2GSRaster.TransferPixel(Value: Cardinal);
begin
  var Reg := Regs[GSRegTRXREG];
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  if (RRW = 0) or (RRH = 0) then
  begin
    FXferActive := False;
    Exit;
  end;
  if FQueueXfer and (FPending or (FXferRunCount > 0)) then
  begin
    // Drawing is queued: the pixels follow it, through the ring.
    if FXferRunCount = 0 then
      BeginTransferRun;
    FXferRing[FXferRingPos and XferRingMask] := Value;
    Inc(FXferRingPos);
    Inc(FXferRunCount);
  end
  else
  begin
    if FPending then
      Sync;
    var Buf := Regs[GSRegBITBLTBUF];
    var Pos := Regs[GSRegTRXPOS];
    FMemory.WriteRaw(Integer((Buf shr 56) and $3F), Cardinal((Buf shr 32) and $3FFF), Cardinal((Buf shr 48) and $3F),
      Cardinal((Integer((Pos shr 32) and $7FF) + FXferX) and $7FF),
      Cardinal((Integer((Pos shr 48) and $7FF) + FXferY) and $7FF), Value);
  end;
  Inc(FXferPixels);
  Inc(FXferX);
  if FXferX >= RRW then
  begin
    FXferX := 0;
    Inc(FXferY);
    if FXferY >= RRH then
      FXferActive := False;
  end;
  if (FXferRunCount > 0) and (not FXferActive or (FXferRunCount >= XferRunMax)) then
    FlushTransfer;
end;

procedure TPS2GSRaster.CheckGPUTransfer;
begin
  if (FAccelerator = nil) or not FAccelerator.Pending or
    ((FAccelerator.Revision <> 0) and (FXferGPURevision = FAccelerator.Revision)) then Exit;
  var Buf := Regs[GSRegBITBLTBUF];
  var Pos := Regs[GSRegTRXPOS];
  var Reg := Regs[GSRegTRXREG];
  var X := Integer((Pos shr 32) and $7FF);
  var Y := Integer((Pos shr 48) and $7FF);
  var W := Integer(Reg and $FFF);
  var H := Integer((Reg shr 32) and $FFF);
  if (W <= 0) or (H <= 0) then Exit;
  if (X + W > 2048) or (Y + H > 2048) then
    FAccelerator.WritePages(0, 511)
  else
  begin
    var PW := 64;
    var PH := 32;
    var PSM := Integer((Buf shr 56) and $3F);
    case PSM of
      PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: PH := 64;
      PSMT8: begin PW := 128; PH := 64; end;
      PSMT4: begin PW := 128; PH := 128; end;
    end;
    var BW := Integer((Buf shr 48) and $3F);
    if PW = 128 then BW := (BW + 1) shr 1;
    var BP := Integer((Buf shr 32) and $3FFF);
    // Use the actual stride, including zero/undersized widths and aliases.
    // Extents beyond the end of VRAM wrap in ReadPages/WritePages.
    var First := (BP shr 5) + (Y div PH) * BW;
    var Last := ((BP + 31) shr 5) + ((Y + H - 1) div PH) * BW + (X + W - 1) div PW;
    FAccelerator.WritePages(First, Last);
  end;
  FXferGPURevision := FAccelerator.Revision;
end;

procedure TPS2GSRaster.FeedWord(W: Cardinal);
begin
  if not FXferActive then
    Exit;
  CheckGPUTransfer;
  var Bits := TransferBits(Cardinal((Regs[GSRegBITBLTBUF] shr 56) and $3F));
  FXferBits := FXferBits or (UInt64(W) shl FXferBitCount);
  Inc(FXferBitCount, 32);
  var Mask := (UInt64(1) shl Bits) - 1;
  while (FXferBitCount >= Bits) and FXferActive do
  begin
    TransferPixel(Cardinal(FXferBits and Mask));
    FXferBits := FXferBits shr Bits;
    Dec(FXferBitCount, Bits);
  end;
end;

procedure TPS2GSRaster.WriteImage(const Data: TPS2Reg128);
begin
  // IMAGE supplies a complete quadword. Unpack ordinary integer formats
  // directly into the software ring, keeping reservation, row progression
  // and barriers per chunk instead of repeating them for 4..32 pixels.
  // Partial final quads, 24-bit bitstreams and unusual state retain FeedWord.
  if FXferActive and FQueueXfer and (FPending or (FXferRunCount > 0)) and
    (FXferBitCount = 0) and (FXferBits = 0) then
  begin
    var Bits := TransferBits(Cardinal((Regs[GSRegBITBLTBUF] shr 56) and $3F));
    if Bits <> 24 then
    begin
      var Count := 128 div Bits;
      var Reg := Regs[GSRegTRXREG];
      var Width := Integer(Reg and $FFF);
      var Height := Integer((Reg shr 32) and $FFF);
      if (Width > 0) and (Height > 0) and (FXferX >= 0) and (FXferX < Width) and
        (FXferY >= 0) and (FXferY < Height) and
        (Int64(Height - FXferY) * Width - FXferX >= Count) and
        (FXferRunCount + Count <= XferRunMax) then
      begin
        CheckGPUTransfer;
        if FXferRunCount = 0 then BeginTransferRun;
        case Bits of
          32: for var K := 0 to 3 do FXferRing[(FXferRingPos + K) and XferRingMask] := Data.UW[K];
          16: for var K := 0 to 7 do FXferRing[(FXferRingPos + K) and XferRingMask] := Data.UH[K];
          8: for var K := 0 to 15 do FXferRing[(FXferRingPos + K) and XferRingMask] := Data.UB[K];
          4: for var K := 0 to 31 do
            FXferRing[(FXferRingPos + K) and XferRingMask] := (Data.UB[K shr 1] shr ((K and 1) * 4)) and 15;
        end;
        Inc(FXferRingPos, Count);
        Inc(FXferRunCount, Count);
        Inc(FXferPixels, Count);
        Inc(FXferX, Count);
        Inc(FXferY, FXferX div Width);
        FXferX := FXferX mod Width;
        FXferActive := FXferY < Height;
        if not FXferActive or (FXferRunCount = XferRunMax) then FlushTransfer;
        Exit;
      end;
    end;
  end;
  for var K := 0 to 3 do
    FeedWord(Data.UW[K]);
end;

procedure TPS2GSRaster.LocalToLocal;
begin
  // The first CPU worker can start the copy as soon as it is published.
  // Its source/destination may alias deferred GPU work, so finish that work
  // even when ordinary software drawing remains queued on the workers.
  if (FAccelerator <> nil) and FAccelerator.Pending then FAccelerator.Sync;
  if Queueing then
  begin
    // After the queued drawing, on the first band thread.
    {$IFDEF GS_RACECHECK}RaceBarrier(FBands.Position); RaceBarrier(FBands.Position + 1); RaceDescribe(FBands.Position, 'copy');{$ENDIF}
    var C := FBands.Next;
    C.Op := coSoloCopy;
    C.Rounding := GetRoundMode;
    C.Clut := -1;
    C.XferRegs[0] := Regs[GSRegBITBLTBUF];
    C.XferRegs[1] := Regs[GSRegTRXPOS];
    C.XferRegs[2] := Regs[GSRegTRXREG];
    MarkPendingArea(C.XferRegs);
    FillChar(FPendingReads, SizeOf(FPendingReads), $FF);
    FBands.Publish;
    ClearOverlap;
    FPending := True;
    Exit;
  end;
  Sync;
  CopyLocal(Regs[GSRegBITBLTBUF], Regs[GSRegTRXPOS], Regs[GSRegTRXREG]);
end;

procedure TPS2GSRaster.CopyLocal(Buf, Pos, Reg: UInt64);
begin
  var SBP := Cardinal(Buf and $3FFF);
  var SBW := Cardinal((Buf shr 16) and $3F);
  var SPSM := Integer((Buf shr 24) and $3F);
  var DBP := Cardinal((Buf shr 32) and $3FFF);
  var DBW := Cardinal((Buf shr 48) and $3F);
  var DPSM := Integer((Buf shr 56) and $3F);
  var SSAX := Integer(Pos and $7FF);
  var SSAY := Integer((Pos shr 16) and $7FF);
  var DSAX := Integer((Pos shr 32) and $7FF);
  var DSAY := Integer((Pos shr 48) and $7FF);
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  for var Y := 0 to RRH - 1 do
    for var X := 0 to RRW - 1 do
    begin
      var V := FMemory.ReadRaw(SPSM, SBP, SBW, Cardinal((SSAX + X) and $7FF), Cardinal((SSAY + Y) and $7FF));
      FMemory.WriteRaw(DPSM, DBP, DBW, Cardinal((DSAX + X) and $7FF), Cardinal((DSAY + Y) and $7FF), V);
    end;
end;

procedure TPS2GSRaster.LocalToHost;
begin
  Sync;
  var Buf := Regs[GSRegBITBLTBUF];
  var Pos := Regs[GSRegTRXPOS];
  var Reg := Regs[GSRegTRXREG];
  var SBP := Cardinal(Buf and $3FFF);
  var SBW := Cardinal((Buf shr 16) and $3F);
  var SPSM := Integer((Buf shr 24) and $3F);
  var SSAX := Integer(Pos and $7FF);
  var SSAY := Integer((Pos shr 16) and $7FF);
  var RRW := Integer(Reg and $FFF);
  var RRH := Integer((Reg shr 32) and $FFF);
  var Bits := TransferBits(Cardinal(SPSM));
  var Acc: UInt64 := 0;
  var Count := 0;
  FReadBuffer := nil;
  SetLength(FReadBuffer, (RRW * RRH * Bits + 31) div 32 + 4);
  var N := 0;
  for var Y := 0 to RRH - 1 do
    for var X := 0 to RRW - 1 do
    begin
      var V := FMemory.ReadRaw(SPSM, SBP, SBW, Cardinal((SSAX + X) and $7FF), Cardinal((SSAY + Y) and $7FF));
      Acc := Acc or (UInt64(V and ((UInt64(1) shl Bits) - 1)) shl Count);
      Inc(Count, Bits);
      while Count >= 32 do
      begin
        FReadBuffer[N] := Cardinal(Acc);
        Inc(N);
        Acc := Acc shr 32;
        Dec(Count, 32);
      end;
    end;
  if Count > 0 then
  begin
    FReadBuffer[N] := Cardinal(Acc);
    Inc(N);
  end;
  SetLength(FReadBuffer, (N + 3) and not 3);
  FReadPos := 0;
end;

function TPS2GSRaster.ReadImage(out Data: TPS2Reg128): Boolean;
begin
  Data := Default(TPS2Reg128);
  if FReadPos + 4 > Length(FReadBuffer) then
    Exit(False);
  for var K := 0 to 3 do
    Data.UW[K] := FReadBuffer[FReadPos + K];
  Inc(FReadPos, 4);
  Result := True;
end;

procedure TPS2GSRaster.SerializeState(State: TStateArchive);
begin
  Sync;
  State.Field(Regs, SizeOf(Regs));
  State.Field(SigLblId, SizeOf(SigLblId));
  State.Field(FSignal, SizeOf(FSignal));
  State.Field(FFinish, SizeOf(FFinish));
  State.Field(FQueue, SizeOf(FQueue));
  State.Field(FQueueCount, SizeOf(FQueueCount));
  State.Field(FStripIndex, SizeOf(FStripIndex));
  State.Field(FCurrent, SizeOf(FCurrent));
  State.Field(FQ, SizeOf(FQ));
  State.Field(FClut, SizeOf(FClut));
  State.Field(FCBP0, SizeOf(FCBP0));
  State.Field(FCBP1, SizeOf(FCBP1));
  State.Field(FXferActive, SizeOf(FXferActive));
  State.Field(FXferX, SizeOf(FXferX));
  State.Field(FXferY, SizeOf(FXferY));
  State.Field(FXferBits, SizeOf(FXferBits));
  State.Field(FXferBitCount, SizeOf(FXferBitCount));
  var N := Length(FReadBuffer);
  State.Field(N, SizeOf(N));
  if State.Loading then
    SetLength(FReadBuffer, N);
  if N > 0 then
    State.Field(FReadBuffer[0], N * 4);
  State.Field(FReadPos, SizeOf(FReadPos));
  State.Field(FMemory.Data^, PS2GSMemorySize);
  FClutChanged := True;
end;

{ TPS2GSBands }

constructor TPS2GSBands.TBand.Create(Owner: TPS2GSBands; Index: Integer; Drawer: TPS2GSDrawer);
begin
  FOwner := Owner;
  FIndex := Index;
  FDrawer := Drawer;
  if Index = 0 then
    FSolo := TPS2GSDrawer.Create(Owner.FRaster, 0, 1, False);
  inherited Create(False);
end;

destructor TPS2GSBands.TBand.Destroy;
begin
  inherited;
  FDrawer.Free;
  FSolo.Free;
end;

procedure TPS2GSBands.TBand.Execute;
begin
  SetDrawerRounding(GetRoundMode);
  var Rounding := GetRoundMode;
  var Position: Int64 := 0;
  while not Terminated do
  begin
    var Spins := 0;
    while (FOwner.Published <= Position) and not Terminated do
    begin
      if Spins < SpinRounds then
      begin
        Inc(Spins);
        YieldProcessor;
        Continue;
      end;
      TInterlocked.Exchange(FOwner.FSlots[FIndex].Sleeping, 1);
      if (FOwner.Published <= Position) and not Terminated then
        FOwner.FSlots[FIndex].Wake.WaitFor(INFINITE);
      TInterlocked.Exchange(FOwner.FSlots[FIndex].Sleeping, 0);
      Spins := 0;
    end;
    if Terminated then
      Break;
    var Last := FOwner.Published;
    while Position < Last do
    begin
      try
        var Command: PPS2GSCommand := @FOwner.FRing[Position and RingMask];
        if Command.Rounding <> Rounding then
        begin
          Rounding := Command.Rounding;
          SetDrawerRounding(Rounding);
        end;
        {$IFDEF PS2_CHECKED}
        if GetRoundMode <> Rounding then
          raise Exception.Create('GS band rounding state changed');
        {$ENDIF}
        {$IFDEF GS_RACECHECK}RaceBandPlus1 := FIndex + 1; RaceCmd := Position;{$ENDIF}
        case Command.Op of
          coDraw:
            FDrawer.Draw(Command^);
          coBarrier:
            begin
              FOwner.BandWait(FIndex, Position, False);
              FDrawer.Draw(Command^);
            end;
          coClut:
            if FIndex = 0 then
              FOwner.FRaster.RunSolo(Command^, FSolo)
            else
              FOwner.BandWait(FIndex, Position + 1, True);
        else
          FOwner.BandWait(FIndex, Position, False);
          if FIndex = 0 then
            FOwner.FRaster.RunSolo(Command^, FSolo)
          else
            FOwner.BandWait(FIndex, Position + 1, True);
        end;
        {$IFDEF PS2_CHECKED}
        if GetRoundMode <> Rounding then
          raise Exception.Create('GS drawer changed host rounding state');
        {$ENDIF}
      except
        on E: Exception do
          FOwner.Fail(E.Message);
      end;
      Inc(Position);
      TInterlocked.Exchange(FOwner.FSlots[FIndex].Consumed, Position);
      if FOwner.FMainWaiting <> 0 then
        FOwner.FProgress.SetEvent;
      if FOwner.FBandsWaiting <> 0 then
        FOwner.WakeWaitingBands;
    end;
  end;
end;

constructor TPS2GSBands.Create(Raster: TPS2GSRaster; Count: Integer);
begin
  inherited Create;
  FRaster := Raster;
  SetLength(FRing, RingSize);
  SetLength(FSlots, Count);
  for var I := 0 to Count - 1 do
    FSlots[I].Wake := TEvent.Create(nil, False, False, '');
  FProgress := TEvent.Create(nil, False, False, '');
  SetLength(FBands, Count);
  for var I := 0 to Count - 1 do
    FBands[I] := TBand.Create(Self, I, TPS2GSDrawer.Create(Raster, I, Count, False));
end;

destructor TPS2GSBands.Destroy;
begin
  for var Band in FBands do
    Band.Terminate;
  for var I := 0 to High(FSlots) do
    FSlots[I].Wake.SetEvent;
  for var Band in FBands do
    Band.Free;
  for var I := 0 to High(FSlots) do
    FSlots[I].Wake.Free;
  FProgress.Free;
  inherited;
end;

function TPS2GSBands.Published: Int64;
begin
  {$IFDEF CPUX64}
  // Aligned 64-bit loads are atomic and ordered on x64 (written by Exchange).
  Result := FPublished;
  {$ELSE}
  Result := TInterlocked.Read(FPublished);
  {$ENDIF}
end;

function TPS2GSBands.Slowest: Int64;
begin
  Result := TInterlocked.Read(FSlots[0].Consumed);
  for var I := 1 to High(FSlots) do
  begin
    var Value := TInterlocked.Read(FSlots[I].Consumed);
    if Value < Result then
      Result := Value;
  end;
end;

procedure TPS2GSBands.Fail(const Message: string);
begin
  if TInterlocked.CompareExchange(FFailed, 2, 0) = 0 then
  begin
    FFailure := Message;
    TInterlocked.Exchange(FFailed, 1);
  end;
end;

procedure RaiseBandFailure(const Failure: string);
begin
  raise Exception.Create('GS band thread: ' + Failure);
end;

procedure TPS2GSBands.CheckFailed;
begin
  if TInterlocked.CompareExchange(FFailed, 0, 0) = 1 then
    RaiseBandFailure(FFailure);
end;

procedure TPS2GSBands.WaitConsumed(Value: Int64);
begin
  if FUnwoken > 0 then
  begin
    FUnwoken := 0;
    WakeWaitingBands;
  end;
  var Spins := 0;
  while Slowest < Value do
  begin
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    TInterlocked.Exchange(FMainWaiting, 1);
    if Slowest < Value then
      FProgress.WaitFor(5);
    TInterlocked.Exchange(FMainWaiting, 0);
  end;
  CheckFailed;
end;

procedure TPS2GSBands.WaitFirst(Value: Int64);
begin
  if FUnwoken > 0 then
  begin
    FUnwoken := 0;
    WakeWaitingBands;
  end;
  var Spins := 0;
  while TInterlocked.Read(FSlots[0].Consumed) < Value do
  begin
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    TInterlocked.Exchange(FMainWaiting, 1);
    if TInterlocked.Read(FSlots[0].Consumed) < Value then
      FProgress.WaitFor(5);
    TInterlocked.Exchange(FMainWaiting, 0);
  end;
  CheckFailed;
end;

procedure TPS2GSBands.BandWait(Index: Integer; Value: Int64; FirstOnly: Boolean);
begin
  var Spins := 0;
  while not TThread.CheckTerminated do
  begin
    if FirstOnly then
    begin
      if TInterlocked.Read(FSlots[0].Consumed) >= Value then
        Exit;
    end
    else if Slowest >= Value then
      Exit;
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    // Asleep until a band finishes a command (a band that finishes one after
    // the check below sees this one waiting and wakes it).
    TInterlocked.Exchange(FSlots[Index].Sleeping, 1);
    TInterlocked.Increment(FBandsWaiting);
    var Reached: Boolean;
    if FirstOnly then
      Reached := TInterlocked.Read(FSlots[0].Consumed) >= Value
    else
      Reached := Slowest >= Value;
    if not Reached then
      FSlots[Index].Wake.WaitFor(1);
    TInterlocked.Decrement(FBandsWaiting);
    TInterlocked.Exchange(FSlots[Index].Sleeping, 0);
  end;
end;

procedure TPS2GSBands.WakeWaitingBands;
begin
  for var I := 0 to High(FSlots) do
    if FSlots[I].Sleeping <> 0 then
      FSlots[I].Wake.SetEvent;
end;

function TPS2GSBands.Next: PPS2GSCommand;
begin
  if FWrite - RingSize >= 0 then
    WaitConsumed(FWrite + 1 - RingSize);
  Result := @FRing[FWrite and RingMask];
end;

procedure TPS2GSBands.Publish(Weight: Integer);
begin
  Inc(FWrite);
  TInterlocked.Exchange(FPublished, FWrite);
  Inc(FUnwoken, Weight);
  if FUnwoken >= WakeWeight then
  begin
    FUnwoken := 0;
    WakeWaitingBands;
  end;
end;

procedure TPS2GSBands.Sync;
begin
  WaitConsumed(FWrite);
end;

procedure TPS2GSBands.WaitFor(Position: Int64);
begin
  WaitConsumed(Position);
end;

end.
