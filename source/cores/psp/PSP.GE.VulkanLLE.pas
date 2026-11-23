unit PSP.GE.VulkanLLE;

// The GE's rasterizer and pixel pipeline on a Vulkan compute device, with the
// arithmetic of PSP.GE.Raster bit for bit (source/gpu/shaders/PSPGERaster.pasm).
//
// Primitives are set up here exactly as PSP.GE.Raster sets them up and go
// with their packed raster state into a batch of passes: runs of primitives
// with one render target, split wherever a texture reads bytes the pass
// draws (render targets and unswizzled textures by their rows, a primitive's
// texture by the texels its coordinates can reach). Batches outlive the GE's
// runs and go to the GPU when the GE stops; until the next Sync (an epoch)
// the VRAM pages they draw into are held (TPSPMemory.HoldVRAM) and the pages
// their textures come from are watched (TPSPMemory.WatchPage): any access to
// a held page, or a write to a watched one, first draws everything (Sync)
// and copies requested drawn pages back into guest memory (Sync returns all).
// The GPU's copy of a page
// is compared with guest memory when a batch first uses it in an epoch;
// textures in main memory are copied into the batch. Mipmapped textures and
// the level of detail are sampled as GESampleTextureLod does. What the
// kernel cannot draw the same way (pixels sharing memory, a primitive
// texturing from the pixels it draws) is drawn after a Sync by the CPU
// renderer's queue (PSP.GE.Workers), and so is a run of the primitives
// after it, so that interleaved CPU and GPU primitives do not each cost a
// Sync; the queue is drained before the GPU draws again.
//
// In check mode every batch, run whenever the GE stops, is also drawn by
// PSP.GE.Raster into guest memory, which keeps the CPU's result, and the two
// are compared.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Types, System.Math, System.Diagnostics,
  System.Generics.Collections, PSP.Types, PSP.Memory, PSP.GE.Texture,
  PSP.GE.Raster, PSP.GE.Backend, PSP.GE.Workers, RM.Vulkan.Bindings,
  RM.Vulkan.Loader, RM.Vulkan.Compute;

const
  VRAMPageCount = PSPVRAMSize div PSPPageSize;

type
  TGEVulkanLLEStats = record
    Batches, Passes, Prims, Fallbacks, UploadedPages: Int64;
    // Waits for everything drawn: in all, for an access to held or watched
    // memory, before a primitive drawn on the CPU. Pages compared and read back.
    Syncs, AccessSyncs, FallbackSyncs, ComparedPages, ReadbackPages: Int64;
    // Primitives the GPU could draw, drawn on the CPU after a CPU-drawn one.
    CPURunPrims: Int64;
    Tiles, Binned: Int64;
    CheckedBatches, BadBatches, BadBytes: Int64;
    // Host seconds waiting for the GPU; GPU seconds uploading, drawing, copying back.
    WaitSeconds, UploadSeconds, DrawSeconds, ReadbackSeconds: Double;
  end;

  TGEVulkanLLEMessage = reference to procedure(const Text: string);
  TGEVulkanLLEPageMask = array[0..VRAMPageCount - 1] of Boolean;
  PGEVulkanLLEPageMask = ^TGEVulkanLLEPageMask;

  TGEVulkanLLESpan = record
    Lo, Len: Int64; // VRAM offset and length, may run past the end (wraps)
    // When Stride > 0, only Rows rows of Width bytes, Stride bytes apart, from
    // Lo (a render target's box, an unswizzled texture level).
    Stride, Width, Rows: Int64;
  end;

  // The VRAM a primitive's texture reads: one span a level it can sample.
  TGEVulkanLLEReads = record
    Count: Integer;
    Spans: array[0..7] of TGEVulkanLLESpan;
    // Only TGETexture.Level is sampled (the first span, when in VRAM).
    OneLevel: Boolean;
  end;

  TGEVulkanLLEPass = record
    First, Count: Integer;
    X1, Y1, X2, Y2: Integer;
    FBAddr, FBStride, FBFormat, ZAddr, ZStride: Cardinal;
    ZPermutation: Integer;
    UsesZ: Boolean;
    // Bytes the pass's whole box covers (depth in whole permutation blocks).
    FB, Z: TGEVulkanLLESpan;
    Reads: TArray<TGEVulkanLLESpan>;
    ReadCount: Integer;
  end;
  PGEVulkanLLEPass = ^TGEVulkanLLEPass;

  TGEVulkanLLECheckPrim = record
    Kind: Integer;
    S: TGERaster;
    V: array[0..2] of TGEVertex;
    Clut: TBytes;
  end;

  // A submitted batch: its buffers, and the pages to copy back when it is done.
  TGEVulkanLLESlot = record
    Cmd: TVulkanCommands;
    PrimBuf, StateBuf, DataBuf, BinBuf, Upload, Readback: TVulkanBuffer;
    Pages: array[0..VRAMPageCount - 1] of Boolean;
    PageCount: Integer;
    Busy: Boolean;
    Order: Int64;
  end;
  PGEVulkanLLESlot = ^TGEVulkanLLESlot;

  TGEVulkanLLEBackend = class(TGERasterBackend)
  private
    FMemory: TPSPMemory;
    FCompute: TVulkanCompute;
    FKernel: TVulkanKernel;
    FVRAM: TVulkanBuffer;
    FSlots: array[0..1] of TGEVulkanLLESlot;
    FNextSlot: Integer;
    FSubmitted: Int64;
    // Until the next Sync (an epoch): pages held as render targets, pages the
    // GPU may have drawn and not given back yet, pages whose GPU copy has been
    // brought up to date (held or watched since), pages to upload with the
    // next submission, watched pages and 64 KB banks of VRAM.
    FHeld: array[0..VRAMPageCount - 1] of Boolean;
    FDrawn: array[0..VRAMPageCount - 1] of Boolean;
    FDrawnCount: Integer;
    FVerified: array[0..VRAMPageCount - 1] of Boolean;
    FVerifiedList: array[0..VRAMPageCount - 1] of Integer;
    FVerifiedCount: Integer;
    FUpload: array[0..VRAMPageCount - 1] of Boolean;
    FUploadCount: Integer;
    FWatched: array[0..VRAMPageCount - 1] of Boolean;
    FWatchedBanks: array[0..VRAMPageCount div 16 - 1] of Boolean;
    FWatchedRAM: Boolean;
    FBins: TArray<Cardinal>;
    FBinCount: Integer;
    FShadow: TBytes;
    FPrims: TArray<Cardinal>;
    FPrimCount: Integer;
    FStates: TArray<Cardinal>;
    FStateCount: Integer;
    FData: TBytes;
    FDataSize: Integer;
    FPasses: TArray<TGEVulkanLLEPass>;
    FPassCount: Integer;
    FLastRaster: TGERaster;
    FLastClut: array[0..1023] of Byte;
    FLastState: Integer;
    FLastTranslation: Integer;
    FLastTex: TGEVulkanLLEReads;
    FCheck: Boolean;
    FCheckPrims: TList<TGEVulkanLLECheckPrim>;
    FStats: TGEVulkanLLEStats;
    FOnMessage: TGEVulkanLLEMessage;
    FWhy: string;
    FReasons: TDictionary<string, Integer>;
    FSnapshots: TDictionary<UInt64, Integer>;
    FLastClutData: Integer;
    FSyncing: Boolean;
    FReleasePrims: Integer;
    // After a CPU-drawn primitive (the GPU synchronized and idle), the next
    // ones go to the CPU renderer's queue too while they cover fewer than
    // FCPUBudget pixels in all: a GPU primitive between two CPU ones would
    // cost a sync. The queue holds and watches pages as the GPU does, so it
    // is drained before the GPU uses memory again.
    // The budget starts small and grows while CPU-drawn primitives come
    // back within a few GPU ones after a run (FGPUSinceRun), up to
    // FCPURunPixels.
    FCPURun: Boolean;
    FCPUBudget, FCPURunPixels, FRunBudget: Int64;
    FGPUSinceRun: Integer;
    FQueue: TGEWorkers;
    FQueued: Boolean;
    FQueueClut: array[0..1023] of Byte;
    FQueueClutValid: Boolean;
    function OnCPU(Pixels: Int64): Boolean;
    procedure Enqueue(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
    procedure DrainQueue;
    procedure Bind(Slot: Integer);
    // Sends the batch to the GPU; with ReadBack, also every page drawn since
    // the last read back, to be put into guest memory when it completes.
    procedure Submit(ReadBack: Boolean; ReadPages: PGEVulkanLLEPageMask = nil);
    procedure SyncRange(Address, Size: Cardinal);
    procedure Complete(Slot: Integer);
    procedure Split(const Why: string);
    function BinPass(const P: TGEVulkanLLEPass; out TilesX, TilesY: Integer): Cardinal;
    procedure Verify(Page: Integer); inline;
    procedure VerifyPage(Page: Integer);
    procedure Hold(const Span: TGEVulkanLLESpan);
    procedure WatchVRAM(const Span: TGEVulkanLLESpan);
    procedure WatchRAM(Address, Size: Cardinal);
    procedure EndEpoch;
    function Pending: Boolean;
    procedure BeginPrim;
    procedure VRAMFault;
    procedure Grow(Slot: Integer; var Buffer: TVulkanBuffer; Bytes: Int64);
    function AddData(Bytes: Integer): Integer;
    function NewPrim: PCardinal;
    function PackState(const S: TGERaster; out Tex: TGEVulkanLLEReads; out Ok: Boolean): Integer;
    function Place(const S: TGERaster; State: Integer; const Tex: TGEVulkanLLEReads; X1, Y1, X2, Y2: Integer): Boolean;
    procedure Record_(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
    procedure Fallback;
    procedure CheckBatch(const Held: array of Boolean; Readback: TVulkanBuffer);
    procedure Message(const Text: string);
  public
    constructor Create(Memory: TPSPMemory; Compute: TVulkanCompute; Check: Boolean);
    destructor Destroy; override;
    procedure DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex); override;
    procedure DrawSprite(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawLine(const S: TGERaster; const V0, V1: TGEVertex); override;
    procedure DrawPoint(const S: TGERaster; const V: TGEVertex); override;
    procedure Sync; override;
    procedure Release; override;
    // Why primitives were drawn on the CPU and why passes were split, with counts.
    function Report: string;
    // Where the batch buffers are.
    function Describe: string;
    property Compute: TVulkanCompute read FCompute;
    // Pixels a run of primitives after a CPU-drawn one may cover (0: none).
    property CPURunPixels: Int64 read FCPURunPixels write FCPURunPixels;
    property Stats: TGEVulkanLLEStats read FStats;
    property OnMessage: TGEVulkanLLEMessage read FOnMessage write FOnMessage;
  end;

// Features and startup arithmetic qualification, without allocating a backend.
function QualifyGEVulkanLLE(Compute: TVulkanCompute; out Error: string): Boolean;

// A GPU backend, or False with the reason when there is no suitable device.
function CreateGEVulkanLLEBackend(Memory: TPSPMemory; Check: Boolean; out Backend: TGEVulkanLLEBackend;
  out Error: string; const DeviceName: string = ''; MaxAPIVersion: Cardinal = VK_API_VERSION_1_2): Boolean;

implementation

uses
  PSP.GE.PascalShaders;

const
  PrimWords = 160;
  StateWords = 128;
  FragWords = 16;
  PageSize = 4096;
  VRAMPages = PSPVRAMSize div PageSize;
  VRAMMask = PSPVRAMSize - 1;

  KindTriangle = 0;
  KindSprite = 1;
  KindFragments = 2;
  KindLine = 3;
  KindPoint = 4;

  // State words, as source/gpu/shaders/PSPGEState.glsl reads them.
  ST_FLAGS = 11;
  ST_DITHER = 42;
  ST_TEXFORMAT = 58;
  ST_LEVELS = 72;
  ST_LEVELDATA = 107;
  ST_MINFILTER = 115;
  ST_MAXLEVEL = 116;
  ST_LEVELMODE = 117;
  ST_LODBIAS = 118;
  ST_SLOPE = 119;
  ST_CLUTSTEP = 120;
  NoData = Cardinal($FFFFFFFF);
  // A batch this large starts drawing when the GE stops (PSP_GPU_RELEASE
  // for measurements).
  ReleasePrims = 256;
  // Pixels drawn on the CPU after a CPU-drawn primitive: at first about an
  // eighth of a screen, at most two screens when CPU-drawn primitives keep
  // coming back within RunReturn GPU ones (PSP_GPU_CPURUN sets the most,
  // 0 for no runs).
  MinRunPixels = 16384;
  DefaultCPURunPixels = 262144;
  RunReturn = 64;

type
  TGEVulkanLLEPush = record
    Table, TilesX: Cardinal;
    X1, Y1, X2, Y2: Integer;
  end;

  TGEVulkanLLEFragment = record
    R, G, B, A: Integer;
    SR, SG, SB: Integer;
    Z: Integer;
    S, T: Single;
    Fog: Single;
  end;

function SameBits(A, B: UInt64; Double: Boolean): Boolean;
begin
  if A = B then
    Exit(True);
  // NaN payloads are not compared: the kernel only ever converts NaNs to integers.
  if Double then
    Result := ((A and $7FF0000000000000) = $7FF0000000000000) and ((A and $FFFFFFFFFFFFF) <> 0) and
      ((B and $7FF0000000000000) = $7FF0000000000000) and ((B and $FFFFFFFFFFFFF) <> 0)
  else
    Result := ((A and $7F800000) = $7F800000) and ((A and $7FFFFF) <> 0) and ((B and $7F800000) = $7F800000) and
      ((B and $7FFFFF) <> 0);
end;

// The device's float arithmetic against the CPU's on operands of all kinds.
function SelfTest(Compute: TVulkanCompute): string;
const
  N = 16384;
  Stride = 16;
  Special: array[0..15] of Cardinal = ($00000000, $80000000, $3F800000, $BF800000, $7F800000, $FF800000, $7FC00000,
    $00000001, $807FFFFF, $00800000, $7F7FFFFF, $3F000000, $4B000000, $CB7FFFFF, $3EFFFFFF, $00000002);
var
  Inputs: array of Cardinal;
  Seed: Cardinal;

  function Rand: Cardinal;
  begin
    Seed := Seed xor (Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor (Seed shl 5);
    Result := Seed;
  end;

  function Operand: Cardinal;
  begin
    case Rand mod 6 of
      0:
        Result := Special[Rand mod 16];
      1:
        Result := Rand and $807FFFFF;
      2:
        Result := (Rand and $80FFFFFF) or (Cardinal(110 + Rand mod 40) shl 23);
    else
      Result := Rand;
    end;
  end;

begin
  Result := '';
  Seed := $9E3779B9;
  SetLength(Inputs, N * 4);
  for var I := 0 to N - 1 do
  begin
    Inputs[I * 4] := Operand;
    Inputs[I * 4 + 1] := Operand;
    Inputs[I * 4 + 2] := Operand;
    Inputs[I * 4 + 3] := Operand;
    case Rand mod 4 of
      0:
        Inputs[I * 4 + 3] := (Inputs[I * 4 + 1] and $800FFFFF) or (Cardinal(1000 + Rand mod 47) shl 20);
      1:
        Inputs[I * 4 + 3] := Inputs[I * 4 + 1] and $800FFFFF;
    end;
  end;
  var Src: TVulkanBuffer := nil;
  var Dst: TVulkanBuffer := nil;
  var K: TVulkanKernel := nil;
  var Cmd: TVulkanCommands := nil;
  var Mask := GetExceptionMask;
  SetExceptionMask(exAllArithmeticExceptions);
  try
    Src := Compute.CreateBuffer(N * 16, vbkUpload);
    Dst := Compute.CreateBuffer(N * Stride * 4, vbkReadback);
    K := Compute.CreateKernel(PSPGEKernelCode(TPSPGEKernel.SelfTest), 2, 4, PSPGEEntryPoint);
    Cmd := Compute.CreateCommands;
    Src.Write(0, Inputs[0], N * 16);
    K.Bind(0, Src);
    K.Bind(1, Dst);
    var Count: Cardinal := N;
    Cmd.Start;
    Cmd.Dispatch(K, N div 64, 1, 1, Count, 4);
    Cmd.FullBarrier;
    Cmd.Run;
    Dst.Invalidate;
    var Names: array[0..7] of string;
    Names[0] := 'single multiply';
    Names[1] := 'double add';
    Names[2] := 'double multiply';
    Names[3] := 'double conversion';
    Names[4] := 'single conversion';
    Names[5] := 'integer conversion';
    Names[6] := 'roundEven';
    Names[7] := 'division';
    var Bad: array[0..7] of Integer;
    FillChar(Bad, SizeOf(Bad), 0);
    for var I := 0 to N - 1 do
    begin
      var R := PCardinal(Dst.Data + I * Stride * 4);
      var A := Inputs[I * 4];
      var B := Inputs[I * 4 + 1];
      var FA := PSingle(@A)^;
      var FB := PSingle(@B)^;
      var DAb := UInt64(A) or (UInt64(B) shl 32);
      var DBb := UInt64(Inputs[I * 4 + 2]) or (UInt64(Inputs[I * 4 + 3]) shl 32);
      var DA := PDouble(@DAb)^;
      var DB := PDouble(@DBb)^;
      var S: Single := FA * FB;
      if not SameBits(R[0], PCardinal(@S)^, False) then
        Inc(Bad[0]);
      var D: Double := DA + DB;
      if not SameBits(PUInt64(@R[1])^, PUInt64(@D)^, True) then
        Inc(Bad[1]);
      D := DA * DB;
      if not SameBits(PUInt64(@R[3])^, PUInt64(@D)^, True) then
        Inc(Bad[2]);
      var DFA: Double := FA;
      D := DFA * DB;
      if not SameBits(PUInt64(@R[5])^, PUInt64(@D)^, True) then
        Inc(Bad[3]);
      S := DA;
      if not SameBits(R[7], PCardinal(@S)^, False) then
        Inc(Bad[4]);
      D := Int64(DBb);
      if not SameBits(PUInt64(@R[8])^, PUInt64(@D)^, True) then
        Inc(Bad[5]);
      D := DA;
      if not (IsNan(DA) or IsInfinite(DA) or (Abs(DA) >= 4503599627370496.0)) then
      begin
        D := Round(DA);
        // roundEven keeps the sign of zero.
        if (D = 0) and (DAb shr 63 <> 0) then
          PUInt64(@D)^ := UInt64($8000000000000000);
      end;
      if not SameBits(PUInt64(@R[10])^, PUInt64(@D)^, True) then
        Inc(Bad[6]);
      D := DA / DB;
      if not SameBits(PUInt64(@R[12])^, PUInt64(@D)^, True) then
        Inc(Bad[7]);
      var T: Cardinal := 0;
      if Abs(DA) < 2147483648.0 then
        T := Cardinal(Trunc(DA));
      if R[14] <> T then
        Inc(Bad[5]);
    end;
    for var J := 0 to 7 do
      if Bad[J] > 0 then
        Result := Result + Format('%s differs from the CPU in %d of %d; ', [Names[J], Bad[J], N]);
  finally
    SetExceptionMask(Mask);
    Cmd.Free;
    K.Free;
    Dst.Free;
    Src.Free;
  end;
end;

function QualifyGEVulkanLLE(Compute: TVulkanCompute; out Error: string): Boolean;
begin
  var F := Compute.Features;
  if not (F.Int64 and F.Int16 and F.Int8 and F.Float64 and F.Storage8 and F.Storage16 and F.DenormPreserve32 and
    F.DenormPreserve64 and F.RoundEven32 and F.RoundEven64 and F.SignedZeroInfNan32 and F.SignedZeroInfNan64) then
  begin
    Error := Compute.Name + ' lacks 64/16/8-bit integers, doubles, small storage or IEEE float controls.';
    Exit(False);
  end;
  Error := SelfTest(Compute);
  if Error <> '' then
    Error := Compute.Name + ': ' + Error;
  Result := Error = '';
end;

function CreateGEVulkanLLEBackend(Memory: TPSPMemory; Check: Boolean; out Backend: TGEVulkanLLEBackend;
  out Error: string; const DeviceName: string; MaxAPIVersion: Cardinal): Boolean;
var
  Compute: TVulkanCompute;
  Taken: Boolean;
begin
  Backend := nil;
  Taken := False;
  if Assigned(Memory.OnVRAMFault) then
  begin
    Error := 'This memory already has a VRAM device.';
    Exit(False);
  end;
{$IFDEF CPUX86}
  Error := 'The Win32/x87 raster reference is not qualified for GPU rendering; use Win64.';
  Exit(False);
{$ENDIF}
  if not TryCreateVulkanCompute(Compute, Error, DeviceName, False, False, MaxAPIVersion) then
    Exit(False);
  try
    if not QualifyGEVulkanLLE(Compute, Error) then
    begin
      Compute.Free;
      Exit(False);
    end;
    Taken := True;
    Backend := TGEVulkanLLEBackend.Create(Memory, Compute, Check);
  except
    on E: Exception do
    begin
      Error := E.Message;
      if not Taken then
        Compute.Free;
      Exit(False);
    end;
  end;
  Result := True;
end;

// CompareMem, 32 bytes at a time (raster states, CLUTs and pages).
function SameBytes(A, B: PByte; Size: NativeInt): Boolean;
begin
  while Size >= 32 do
  begin
    if ((PUInt64(A)^ xor PUInt64(B)^) or (PUInt64(A + 8)^ xor PUInt64(B + 8)^) or (PUInt64(A + 16)^ xor
      PUInt64(B + 16)^) or (PUInt64(A + 24)^ xor PUInt64(B + 24)^)) <>
      0 then
      Exit(False);
    Inc(A, 32);
    Inc(B, 32);
    Dec(Size, 32);
  end;
  while Size > 0 do
  begin
    if A^ <> B^ then
      Exit(False);
    Inc(A);
    Inc(B);
    Dec(Size);
  end;
  Result := True;
end;

{ Spans of VRAM }

function Span(Lo, Len: Int64): TGEVulkanLLESpan; inline;
begin
  Result.Lo := Lo and VRAMMask;
  Result.Len := Min(Len, Int64(PSPVRAMSize));
  Result.Stride := 0;
  Result.Width := 0;
  Result.Rows := 0;
end;

// Rows bytes of Width, Stride apart (Width <= Stride), from Lo.
function RowSpan(Lo, Stride, Width, Rows: Int64): TGEVulkanLLESpan;
begin
  Result := Span(Lo, (Rows - 1) * Stride + Width);
  if (Width <= Stride) and (Rows > 1) and (Result.Len < PSPVRAMSize) then
  begin
    Result.Stride := Stride;
    Result.Width := Width;
    Result.Rows := Rows;
  end;
end;

function FloorDiv(A, B: Int64): Int64; inline;
begin
  Result := A div B;
  if (A mod B <> 0) and ((A < 0) <> (B < 0)) then
    Dec(Result);
end;

// Whether bytes [Lo, Hi) meet a row of R (R.Lo relative to them by Delta).
function MeetsRows(const R: TGEVulkanLLESpan; Delta, Lo, Hi: Int64): Boolean;
begin
  // Rows J with Delta + J * Stride < Hi and Delta + J * Stride + Width > Lo.
  var First := Max(Int64(0), FloorDiv(Lo - Delta - R.Width, R.Stride) + 1);
  var Last := Min(R.Rows - 1, FloorDiv(Hi - Delta - 1, R.Stride));
  Result := First <= Last;
end;

function Overlap(const A, B: TGEVulkanLLESpan): Boolean;
begin
  if (A.Len <= 0) or (B.Len <= 0) then
    Exit(False);
  for var Shift := -1 to 1 do
  begin
    var Lo := B.Lo + Shift * Int64(PSPVRAMSize);
    if (A.Lo < Lo + B.Len) and (Lo < A.Lo + A.Len) then
    begin
      // Rows: only the bytes in them count.
      if (A.Stride = 0) and (B.Stride = 0) then
        Exit(True);
      if B.Stride = 0 then
      begin
        if MeetsRows(A, A.Lo, Lo, Lo + B.Len) then
          Exit(True);
      end
      else if A.Stride = 0 then
      begin
        if MeetsRows(B, Lo, A.Lo, A.Lo + A.Len) then
          Exit(True);
      end
      else if A.Stride = B.Stride then
      begin
        // B's rows start R bytes into a row of A, from Q rows below its first.
        var D := Lo - A.Lo;
        var Q := FloorDiv(D, A.Stride);
        var R := D - Q * A.Stride;
        // Row offsets K = Q + J - I between B's row J and A's row I.
        var KMin := Q - (A.Rows - 1);
        var KMax := Q + (B.Rows - 1);
        if ((KMin <= 0) and (KMax >= 0) and (R < A.Width)) or ((KMin <= -1) and (KMax >= -1) and
          (R > A.Stride - B.Width)) then
          Exit(True);
      end
      else
      begin
        for var J := 0 to B.Rows - 1 do
          if MeetsRows(A, A.Lo, Lo + J * B.Stride, Lo + J * B.Stride + B.Width) then
            Exit(True);
      end;
    end;
  end;
  Result := False;
end;

// Whether every byte of R is one of Q's.
function Contains(const Q, R: TGEVulkanLLESpan): Boolean;
begin
  if (R.Lo < Q.Lo) or (R.Lo + R.Len > Q.Lo + Q.Len) then
    Exit(False);
  if Q.Stride = 0 then
    Exit(True);
  var D := R.Lo - Q.Lo;
  var Row := D div Q.Stride;
  var Column := D mod Q.Stride;
  if R.Stride = 0 then
    Result := (Column + R.Len <= Q.Width) and (Row < Q.Rows)
  else
    Result := (R.Stride = Q.Stride) and (Column + R.Width <= Q.Width) and (Row + R.Rows <= Q.Rows);
end;

// Bytes of a render target a box of pixels covers (X2 < Stride).
function TargetSpan(Addr, Stride, Bpp: Cardinal; X1, Y1, X2, Y2: Integer): TGEVulkanLLESpan;
begin
  var First := Int64(Y1) * Stride + X1;
  Result := RowSpan(Int64(Addr) + First * Bpp, Int64(Stride) * Bpp, Int64(X2 - X1 + 1) * Bpp, Y2 - Y1 + 1);
end;

// EDRAM permutations of a translation (PSPDepthOffset, the odd mirrors) move
// bytes only within aligned blocks: 2 KB untranslated, else 16 times the
// translation width (as PSP.GE.Workers takes them).
function PermutationBlock(Shift: Integer): Int64; inline;
begin
  if Shift = 0 then
    Result := $800
  else
    Result := Int64(1) shl Min(Shift + 4, 21);
end;

// The whole blocks a logical span's bytes lie in: where they can be physically.
function BlockSpan(const S: TGEVulkanLLESpan; Block: Int64): TGEVulkanLLESpan;
begin
  if S.Len <= 0 then
    Exit(S);
  var First := S.Lo and not (Block - 1);
  var Last := (S.Lo + S.Len + Block - 1) and not (Block - 1);
  Result := Span(First, Last - First);
end;

// The guest bytes the texture unit can read for the current level: Size from
// Addr, and when unswizzled, only the first Width bytes of each of Rows rows
// of Stride bytes (texel coordinates are wrapped or clamped into the level).
function TextureBytes(const T: TGETexture; Level: Integer; out Addr, Size: Cardinal;
  out Stride, Width, Rows: Int64): Boolean;
begin
  var L := T.Levels[Level];
  Addr := L.Addr;
  Size := 0;
  Stride := 0;
  Width := 0;
  Rows := 0;
  var W := L.Width;
  var H := L.Height;
  var Bits := 0;
  case T.Format of
    0, 1, 2, 6:
      Bits := 16;
    3, 7:
      Bits := 32;
    4:
      Bits := 4;
    5:
      Bits := 8;
    8, 9, 10:
      begin
        var BlockBytes := 16;
        if T.Format = 8 then
          BlockBytes := 8;
        var BlocksPerRow := L.BufWidth div 4;
        Size := Cardinal(((((H - 1) shr 2) * BlocksPerRow + ((W - 1) shr 2)) + 1) * BlockBytes);
        Exit(True);
      end;
  else
    Exit(False);
  end;
  var RowBytes := (L.BufWidth * Bits) div 8;
  var ByteX := ((W - 1) * Bits) div 8;
  var Bytes := Max(1, Bits div 8);
  if T.Swizzle then
    Size := Cardinal(((((H - 1) shr 3) * (RowBytes shr 4) + (ByteX shr 4)) shl 7) + 7 * 16 + 15 + Bytes)
  else
  begin
    Size := Cardinal((H - 1) * RowBytes + ByteX + Bytes);
    Stride := RowBytes;
    Width := ByteX + Bytes;
    Rows := H;
  end;
  Result := True;
end;

// Texel coordinates Lo..Hi as the sampler wraps or clamps them into a level
// Size (a power of two) wide: the range they all fall into.
procedure TexelRange(var Lo, Hi: Int64; Size: Integer; Clamp: Boolean);
begin
  if Clamp then
  begin
    Lo := EnsureRange(Lo, 0, Size - 1);
    Hi := EnsureRange(Hi, 0, Size - 1);
  end
  else if Hi - Lo + 1 >= Size then
  begin
    Lo := 0;
    Hi := Size - 1;
  end
  else
  begin
    Lo := Lo and (Size - 1);
    Hi := Hi and (Size - 1);
    if Lo > Hi then
    begin
      Lo := 0;
      Hi := Size - 1;
    end;
  end;
end;

const
  TexelLimit = 1048576.0;

// The bytes of an unswizzled level (whose rows are Full) holding the texels
// that coordinates within MinS..MaxS, MinT..MaxT computed with rounding errors
// can sample: two texels more either way for those and the bilinear
// neighbours, and more for large coordinates.
function TexelWindow(const S: TGERaster; MinS, MaxS, MinT, MaxT: Double;
  const Full: TGEVulkanLLESpan): TGEVulkanLLESpan;
begin
  Result := Full;
  var L: PGETexLevel := @S.Tex.Levels[S.Tex.Level];
  var Bits: Integer;
  case S.Tex.Format of
    0, 1, 2, 6:
      Bits := 16;
    3, 7:
      Bits := 32;
    4:
      Bits := 4;
    5:
      Bits := 8;
  else
    Exit;
  end;
  if (L.Width <= 0) or (L.Height <= 0) or (L.BufWidth <= 0) then
    Exit;
  // Also not NaNs.
  if not ((Abs(MinS) < TexelLimit) and (Abs(MaxS) < TexelLimit) and (Abs(MinT) < TexelLimit) and
    (Abs(MaxT) < TexelLimit)) then
    Exit;
  var Margin := 2 + Ceil(Max(Max(Abs(MinS), Abs(MaxS)), Max(Abs(MinT), Abs(MaxT))) / 65536);
  var X1 := Int64(Floor(MinS)) - Margin;
  var X2 := Int64(Floor(MaxS)) + Margin;
  var Y1 := Int64(Floor(MinT)) - Margin;
  var Y2 := Int64(Floor(MaxT)) + Margin;
  TexelRange(X1, X2, L.Width, S.Tex.ClampU);
  TexelRange(Y1, Y2, L.Height, S.Tex.ClampV);
  var RowBytes := Int64(L.BufWidth) * Bits div 8;
  var First := X1 * Bits div 8;
  var Last := X2 * Bits div 8 + Max(1, Bits div 8) - 1;
  Result := RowSpan(Int64(L.Addr) + Y1 * RowBytes + First, RowBytes, Last - First + 1, Y2 - Y1 + 1);
end;

// The texels a triangle can sample. Its pixels' S and T (GEDrawTriangle) are
// combinations of the vertices' S/Q and T/Q with non-negative weights when
// every vertex has positive Q and W.
function TriangleTexels(const S: TGERaster; const V0, V1, V2: TGEVertex;
  const Full: TGEVulkanLLESpan): TGEVulkanLLESpan;
begin
  Result := Full;
  var MinS: Double := 0;
  var MaxS: Double := 0;
  var MinT: Double := 0;
  var MaxT: Double := 0;
  // Transform mode's planes (GEPerspPlanes) round as SpritePerspTexels'.
  var Top: Double := 0;
  var TopW: Double := 0;
  var MinQW: Double := 0;
  var MaxQW: Double := 0;
  for var I := 0 to 2 do
  begin
    var V: PGEVertex := @V0;
    if I = 1 then
      V := @V1;
    if I = 2 then
      V := @V2;
    if not ((V.Q >= 1E-15) and (V.W >= 1E-15)) then
      Exit;
    var CS: Double := V.S / V.Q;
    var CT: Double := V.T / V.Q;
    if not ((Abs(CS) < TexelLimit) and (Abs(CT) < TexelLimit)) then
      Exit;
    var QW: Double := Double(V.Q) * V.W;
    Top := Max(Top, Max(Abs(CS), Abs(CT)));
    TopW := Max(TopW, Max(Abs(V.S), Abs(V.T)) * V.W);
    if I = 0 then
    begin
      MinQW := QW;
      MaxQW := QW;
    end
    else
    begin
      MinQW := Min(MinQW, QW);
      MaxQW := Max(MaxQW, QW);
    end;
    if I = 0 then
    begin
      MinS := CS;
      MaxS := CS;
      MinT := CT;
      MaxT := CT;
    end
    else
    begin
      MinS := Min(MinS, CS);
      MaxS := Max(MaxS, CS);
      MinT := Min(MinT, CT);
      MaxT := Max(MaxT, CT);
    end;
  end;
  if not S.Through then
  begin
    var Err := (TopW + Top * MaxQW) / MinQW / 8192 + 1;
    if not (Err < TexelLimit) then
      Exit;
    MinS := MinS - Err;
    MaxS := MaxS + Err;
    MinT := MinT - Err;
    MaxT := MaxT + Err;
  end;
  Result := TexelWindow(S, MinS, MaxS, MinT, MaxT, Full);
end;

// The texels an unprojected through-mode sprite (box PX1..PX2, PY1..PY2) can
// sample. S and T are linear across the box, so every pixel's lie between
// their values at the corner pixels (GEDrawSprite).
function SpriteTexels(const S: TGERaster; const V0: TGEVertex; SX, SY, TX, TY: Single; PX1, PY1, PX2, PY2: Integer;
  const Full: TGEVulkanLLESpan): TGEVulkanLLESpan;
begin
  var MinS: Double := 0;
  var MaxS: Double := 0;
  var MinT: Double := 0;
  var MaxT: Double := 0;
  for var Corner := 0 to 3 do
  begin
    var PX := PX1;
    if Corner and 1 <> 0 then
      PX := PX2;
    var PY := PY1;
    if Corner and 2 <> 0 then
      PY := PY2;
    var FX: Double := (PX * 16 + 8 - V0.X) / 16;
    var FY: Double := (PY * 16 + 8 - V0.Y) / 16;
    var CS: Double := V0.S + SX * FX + SY * FY;
    var CT: Double := V0.T + TX * FX + TY * FY;
    // Also not NaNs (which Min and Max would drop).
    if not ((Abs(CS) < TexelLimit) and (Abs(CT) < TexelLimit)) then
      Exit(Full);
    if Corner = 0 then
    begin
      MinS := CS;
      MaxS := CS;
      MinT := CT;
      MaxT := CT;
    end
    else
    begin
      MinS := Min(MinS, CS);
      MaxS := Max(MaxS, CS);
      MinT := Min(MinT, CT);
      MaxT := Max(MaxT, CT);
    end;
  end;
  Result := TexelWindow(S, MinS, MaxS, MinT, MaxT, Full);
end;

// The texels a transform-mode sprite can sample (GEDrawSprite). With positive
// Q and w its S runs between the vertices' S/Q and T between either one's T
// over either one's Q, through GESpritePerspPlanes (S W and T W over Q W) or
// its fallback (S and T over Q), widened by the planes' rounding: values with
// 15 significant bits, so S/Q within 2^-13 of the largest S W and S/Q times Q W
// over the smallest Q W.
function SpritePerspTexels(const S: TGERaster; const V0, V1: TGEVertex; const Full: TGEVulkanLLESpan): TGEVulkanLLESpan;
var
  MinS, MaxS, MinT, MaxT, Top: Double;
  First: Boolean;

  procedure Take(CS, CT: Double);
  begin
    if First then
    begin
      MinS := CS;
      MaxS := CS;
      MinT := CT;
      MaxT := CT;
      First := False;
    end;
    MinS := Min(MinS, CS);
    MaxS := Max(MaxS, CS);
    MinT := Min(MinT, CT);
    MaxT := Max(MaxT, CT);
    Top := Max(Top, Max(Abs(CS), Abs(CT)));
  end;

begin
  Result := Full;
  if not ((V0.Q >= 1E-15) and (V1.Q >= 1E-15) and (V0.W >= 1E-15) and (V1.W >= 1E-15)) then
    Exit;
  var QW0: Double := Double(V0.Q) * V0.W;
  var QW1: Double := Double(V1.Q) * V1.W;
  First := True;
  Top := 0;
  Take(V0.S / V0.Q, V0.T / V0.Q);
  Take(V1.S / V1.Q, V1.T / V1.Q);
  Take(V0.S / V0.Q, V0.T / V1.Q);
  Take(V1.S / V1.Q, V1.T / V0.Q);
  Take(V0.S / V0.Q, Double(V0.T) * V0.W / QW0);
  Take(V0.S / V0.Q, Double(V0.T) * V0.W / QW1);
  Take(V0.S / V0.Q, Double(V1.T) * V1.W / QW0);
  Take(V0.S / V0.Q, Double(V1.T) * V1.W / QW1);
  // Also not NaNs (which Min and Max drop).
  if not (Top < TexelLimit) then
    Exit;
  var TopW := Max(Max(Abs(V0.S), Abs(V0.T)) * V0.W, Max(Abs(V1.S), Abs(V1.T)) * V1.W);
  var Err := (TopW + Top * Max(QW0, QW1)) / Min(QW0, QW1) / 8192 + 1;
  if not (Err < TexelLimit) then
    Exit;
  Result := TexelWindow(S, MinS - Err, MaxS + Err, MinT - Err, MaxT + Err, Full);
end;

// Whether Size bytes from Address all lie in VRAM's mirrors.
function InVRAM(Address, Size: Cardinal): Boolean;
begin
  var Phys := Int64(Address and $1FFFFFFF);
  Result := (Phys >= PSPVRAMBase) and (Phys + Size <= PSPVRAMBase + 4 * PSPVRAMSize) and
    (Int64(Address) + Size <= $100000000);
end;

function TouchesVRAM(Address, Size: Cardinal): Boolean;
begin
  var Lo := Int64(Address and $1FFFFFFF);
  var Hi := Lo + Max(Int64(Size), 1);
  Result := ((Hi > PSPVRAMBase) and (Lo < PSPVRAMBase + 4 * PSPVRAMSize)) or ((Hi > $20000000) and
    (Hi - $20000000 > PSPVRAMBase));
end;

{ TGEVulkanLLEBackend }

constructor TGEVulkanLLEBackend.Create(Memory: TPSPMemory; Compute: TVulkanCompute; Check: Boolean);
begin
  inherited Create;
  FMemory := Memory;
  FCompute := Compute;
  FCheck := Check;
  FCheckPrims := TList<TGEVulkanLLECheckPrim>.Create;
  FReasons := TDictionary<string, Integer>.Create;
  FSnapshots := TDictionary<UInt64, Integer>.Create;
  SetLength(FShadow, PSPVRAMSize);
  FVRAM := Compute.CreateBuffer(PSPVRAMSize + 256, vbkDevice);
  FKernel := Compute.CreateKernel(PSPGEKernelCode(TPSPGEKernel.Raster), 8,
    SizeOf(TGEVulkanLLEPush), [], Length(FSlots), PSPGEEntryPoint);
  for var I := 0 to High(FSlots) do
  begin
    var S: PGEVulkanLLESlot := @FSlots[I];
    S.Upload := Compute.CreateBuffer(PSPVRAMSize, vbkUpload);
    S.Readback := Compute.CreateBuffer(PSPVRAMSize, vbkReadback);
    S.PrimBuf := Compute.CreateBuffer(4096 * PrimWords * 4, vbkShared);
    S.StateBuf := Compute.CreateBuffer(1024 * StateWords * 4, vbkShared);
    S.DataBuf := Compute.CreateBuffer(4 shl 20, vbkShared);
    S.BinBuf := Compute.CreateBuffer(1 shl 20, vbkShared);
    S.Cmd := Compute.CreateCommands(4);
    S.Cmd.SpinMicroseconds := 20000;
    Bind(I);
  end;
  var Cmd := FSlots[0].Cmd;
  Cmd.Start;
  Cmd.Fill(FVRAM, 0, FVRAM.Size, 0);
  Cmd.FullBarrier;
  Cmd.Run;
  FLastState := -1;
  FLastClutData := -1;
  FReleasePrims := StrToIntDef(GetEnvironmentVariable('PSP_GPU_RELEASE'), ReleasePrims);
  FCPURunPixels := StrToInt64Def(GetEnvironmentVariable('PSP_GPU_CPURUN'), DefaultCPURunPixels);
  FQueue := TGEWorkers.Create(FMemory);
  FGPUSinceRun := RunReturn;
  FMemory.OnVRAMFault := VRAMFault;
end;

destructor TGEVulkanLLEBackend.Destroy;
begin
  try
    if Pending or FQueued then
      Sync;
  finally
    FQueue.Free;
    FMemory.ReleaseVRAM;
    FMemory.ReleaseWatches;
    FMemory.OnVRAMFault := nil;
    for var I := 0 to High(FSlots) do
    begin
      var S: PGEVulkanLLESlot := @FSlots[I];
      S.Cmd.Free;
      S.BinBuf.Free;
      S.DataBuf.Free;
      S.StateBuf.Free;
      S.PrimBuf.Free;
      S.Readback.Free;
      S.Upload.Free;
    end;
    FKernel.Free;
    FVRAM.Free;
    FSnapshots.Free;
    FReasons.Free;
    FCheckPrims.Free;
    FCompute.Free;
    inherited;
  end;
end;

procedure TGEVulkanLLEBackend.Message(const Text: string);
begin
  if Assigned(FOnMessage) then
    FOnMessage(Text);
end;

// The GPU's copy of a page is brought up to date once an epoch, when the batch
// first uses it: from then on the page is held or watched, so guest memory
// cannot change it before the batch is drawn. Pages are compared with what
// the GPU was last given or gave back.
procedure TGEVulkanLLEBackend.Verify(Page: Integer);
begin
  if not FVerified[Page] then
    VerifyPage(Page);
end;

procedure TGEVulkanLLEBackend.VerifyPage(Page: Integer);
begin
  FVerified[Page] := True;
  FVerifiedList[FVerifiedCount] := Page;
  Inc(FVerifiedCount);
  // A still-held page is authoritative on the GPU, not in guest memory.
  if FHeld[Page] then Exit;
  Inc(FStats.ComparedPages);
  var Guest := @FMemory.VRAM[Page * PageSize];
  if not SameBytes(Guest, @FShadow[Page * PageSize], PageSize) then
  begin
    Move(Guest^, FShadow[Page * PageSize], PageSize);
    FUpload[Page] := True;
    Inc(FUploadCount);
  end;
end;

// Render target pages: held, so that any access first gives them back.
procedure TGEVulkanLLEBackend.Hold(const Span: TGEVulkanLLESpan);
begin
  if Span.Len <= 0 then
    Exit;
  var First := Span.Lo div PageSize;
  var Last := (Span.Lo + Span.Len - 1) div PageSize;
  for var Page := First to Last do
  begin
    var P := Integer(Page mod VRAMPages);
    if not FHeld[P] then
    begin
      Verify(P);
      FHeld[P] := True;
      FMemory.HoldVRAM(P);
    end;
    if not FDrawn[P] then
    begin
      FDrawn[P] := True;
      Inc(FDrawnCount);
    end;
  end;
end;

// Texture pages in VRAM: watched, so that a write first draws the batch. The
// odd mirrors permute bytes within 64 KB banks, so all of a bank's pages
// there are watched.
procedure TGEVulkanLLEBackend.WatchVRAM(const Span: TGEVulkanLLESpan);
const
  Linear0 = PSPVRAMBase shr PSPPageShift;
  Linear2 = (PSPVRAMBase + 2 * PSPVRAMSize) shr PSPPageShift;
  Odd1 = (PSPVRAMBase + PSPVRAMSize) shr PSPPageShift;
  Odd3 = (PSPVRAMBase + 3 * PSPVRAMSize) shr PSPPageShift;
begin
  if Span.Len <= 0 then
    Exit;
  var First := Span.Lo div PageSize;
  var Last := (Span.Lo + Span.Len - 1) div PageSize;
  for var Page := First to Last do
  begin
    var P := Integer(Page mod VRAMPages);
    if FWatched[P] then
      Continue;
    FWatched[P] := True;
    Verify(P);
    FMemory.WatchPage(Linear0 + P);
    FMemory.WatchPage(Linear2 + P);
    var Bank := P shr 4;
    if not FWatchedBanks[Bank] then
    begin
      FWatchedBanks[Bank] := True;
      for var B := Bank * 16 to Bank * 16 + 15 do
      begin
        FMemory.WatchPage(Odd1 + B);
        FMemory.WatchPage(Odd3 + B);
      end;
    end;
  end;
end;

// Textures in main memory: the batch keeps a copy, valid while it is watched.
procedure TGEVulkanLLEBackend.WatchRAM(Address, Size: Cardinal);
begin
  var Lo := Address and $1FFFFFFF;
  var Hi := UInt64(Lo) + Max(Size, 1) - 1;
  if Hi >= $20000000 then
    Hi := $1FFFFFFF;
  for var Page := Integer(Lo shr PSPPageShift) to Integer(Hi shr PSPPageShift) do
    FMemory.WatchPage(Page);
  FWatchedRAM := True;
end;

// Everything has been drawn and given back: guest memory is free again.
procedure TGEVulkanLLEBackend.EndEpoch;
begin
  FMemory.ReleaseVRAM;
  FMemory.ReleaseWatches;
  for var I := 0 to FVerifiedCount - 1 do
    FVerified[FVerifiedList[I]] := False;
  FVerifiedCount := 0;
  FWatchedRAM := False;
  FillChar(FHeld, SizeOf(FHeld), 0);
  FillChar(FWatched, SizeOf(FWatched), 0);
  FillChar(FWatchedBanks, SizeOf(FWatchedBanks), 0);
end;

// Batches stay within reasonable buffer sizes.
procedure TGEVulkanLLEBackend.BeginPrim;
begin
  if (FPrimCount >= 65536) or (FDataSize >= 64 shl 20) then
    if FCheck then
      Sync
    else
      Submit(False);
end;

procedure TGEVulkanLLEBackend.VRAMFault;
begin
  Inc(FStats.AccessSyncs);
  if FCheck or FQueued or (FMemory.SyncSize = 0) then Sync
  else SyncRange(FMemory.SyncAddress, FMemory.SyncSize);
end;

procedure TGEVulkanLLEBackend.Split(const Why: string);
begin
  var N := 0;
  var Key := 'pass split: ' + Why;
  FReasons.TryGetValue(Key, N);
  FReasons.AddOrSetValue(Key, N + 1);
end;

function TGEVulkanLLEBackend.Describe: string;
begin
  if FSlots[0].PrimBuf.DeviceLocal then
    Result := 'batches in device memory'
  else
    Result := 'batches in host memory';
end;

function TGEVulkanLLEBackend.Report: string;
begin
  Result := '';
  for var Pair in FReasons do
    Result := Result + Format('%s: %d'#10, [Pair.Key, Pair.Value]);
end;

// The GE stops: the batch starts on the GPU while the CPU runs on, unless
// the GPU is still drawing the last one: then it grows, and the GPU gets
// fewer, larger passes the busier it is. Nothing is read back: the pages
// stay held or watched until an access or a CPU-drawn primitive needs them
// (Sync).
procedure TGEVulkanLLEBackend.Release;
begin
  // The queue, too, keeps its primitives across GE runs (a large batch
  // starts drawing in the background).
  if FQueued then
    FQueue.Release;
  if FCheck then
    Sync
  else if FPrimCount >= FReleasePrims then
  begin
    var Last: PGEVulkanLLESlot := @FSlots[(FNextSlot + Length(FSlots) - 1) mod Length(FSlots)];
    if not Last.Busy or Last.Cmd.Done then
      Submit(False);
  end;
end;

procedure TGEVulkanLLEBackend.Bind(Slot: Integer);
begin
  var S: PGEVulkanLLESlot := @FSlots[Slot];
  FKernel.Bind(Slot, 0, FVRAM);
  FKernel.Bind(Slot, 1, FVRAM);
  FKernel.Bind(Slot, 2, FVRAM);
  FKernel.Bind(Slot, 3, S.PrimBuf);
  FKernel.Bind(Slot, 4, S.StateBuf);
  FKernel.Bind(Slot, 5, S.DataBuf);
  FKernel.Bind(Slot, 6, S.DataBuf);
  FKernel.Bind(Slot, 7, S.BinBuf);
end;

// Sorts a pass's primitives into 16x16 tiles, keeping their order: a table of
// (first, count) per tile, then the lists. Returns the table's word offset.
function TGEVulkanLLEBackend.BinPass(const P: TGEVulkanLLEPass; out TilesX, TilesY: Integer): Cardinal;
begin
  var TX1 := P.X1 shr 4;
  var TY1 := P.Y1 shr 4;
  TilesX := (P.X2 shr 4) - TX1 + 1;
  TilesY := (P.Y2 shr 4) - TY1 + 1;
  var Tiles := TilesX * TilesY;
  var Total := 0;
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    Inc(Total,
      ((Integer(W[4]) shr 4) - (Integer(W[2]) shr 4) + 1) * ((Integer(W[5]) shr 4) - (Integer(W[3]) shr 4) + 1));
  end;
  Result := FBinCount;
  Inc(FStats.Tiles, Tiles);
  Inc(FStats.Binned, Total);
  var Need := FBinCount + Tiles * 2 + Total;
  if Need > Length(FBins) then
    SetLength(FBins, Max(Need, Length(FBins) * 2));
  var Table := PCardinal(@FBins[FBinCount]);
  FillChar(Table^, Tiles * 2 * 4, 0);
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    for var TY := (Integer(W[3]) shr 4) - TY1 to (Integer(W[5]) shr 4) - TY1 do
      for var TX := (Integer(W[2]) shr 4) - TX1 to (Integer(W[4]) shr 4) - TX1 do
        Inc(Table[(TY * TilesX + TX) * 2 + 1]);
  end;
  var Next := Cardinal(FBinCount + Tiles * 2);
  for var T := 0 to Tiles - 1 do
  begin
    Table[T * 2] := Next;
    Inc(Next, Table[T * 2 + 1]);
    Table[T * 2 + 1] := 0;
  end;
  for var I := P.First to P.First + P.Count - 1 do
  begin
    var W := PCardinal(@FPrims[I * PrimWords]);
    for var TY := (Integer(W[3]) shr 4) - TY1 to (Integer(W[5]) shr 4) - TY1 do
      for var TX := (Integer(W[2]) shr 4) - TX1 to (Integer(W[4]) shr 4) - TX1 do
      begin
        var T := (TY * TilesX + TX) * 2;
        FBins[Table[T] + Table[T + 1]] := Cardinal(I);
        Inc(Table[T + 1]);
      end;
  end;
  FBinCount := Need;
end;

// Only for an idle slot.
procedure TGEVulkanLLEBackend.Grow(Slot: Integer; var Buffer: TVulkanBuffer; Bytes: Int64);
begin
  if Bytes <= Int64(Buffer.Size) then
    Exit;
  var Size := Int64(Buffer.Size);
  while Size < Bytes do
    Size := Size * 2;
  Buffer.Free;
  Buffer := FCompute.CreateBuffer(Size, vbkShared);
  Bind(Slot);
end;

function TGEVulkanLLEBackend.AddData(Bytes: Integer): Integer;
begin
  Result := (FDataSize + 15) and not 15;
  FDataSize := Result + Bytes;
  if FDataSize > Length(FData) then
    SetLength(FData, Max(FDataSize, Length(FData) * 2));
end;

function TGEVulkanLLEBackend.NewPrim: PCardinal;
begin
  if (FPrimCount + 1) * PrimWords > Length(FPrims) then
    SetLength(FPrims, Max(4096 * PrimWords, Length(FPrims) * 2));
  Result := @FPrims[FPrimCount * PrimWords];
  FillChar(Result^, PrimWords * 4, 0);
  Inc(FPrimCount);
  if FGPUSinceRun < RunReturn then
    Inc(FGPUSinceRun);
end;

function TGEVulkanLLEBackend.PackState(const S: TGERaster; out Tex: TGEVulkanLLEReads; out Ok: Boolean): Integer;
var
  LevelData: array[0..7] of Cardinal;
begin
  Ok := True;
  var UsesClut := S.Textured and (S.Tex.Format >= 4) and (S.Tex.Format <= 7);
  // A texture's copy in the batch stays valid: its pages are watched.
  if (FLastState >= 0) and (FLastTranslation = FMemory.VRAMShift) and SameBytes(@S, @FLastRaster, SizeOf(TGERaster)) and
    (not UsesClut or SameBytes(S.Tex.Clut, @FLastClut[0], SizeOf(FLastClut))) then
  begin
    Tex := FLastTex;
    Exit(FLastState);
  end;
  Tex.Count := 0;
  Tex.OneLevel := True;
  for var L := 0 to 7 do
    LevelData[L] := NoData;
  var ClutOfs: Cardinal := 0;
  if S.Textured then
  begin
    // The levels GESampleTexture or GESampleTextureLod can sample.
    var First := S.Tex.Level;
    var Last := S.Tex.Level;
    if S.Tex.NeedLod then
    begin
      First := 0;
      Last := 0;
      if (S.Tex.MinFilter >= 4) and (S.Tex.MaxLevel > 0) then
      begin
        Last := S.Tex.MaxLevel;
        // Level coordinates are scaled by level 0's size (a power of two).
        var W0 := S.Tex.Levels[0].Width;
        var H0 := S.Tex.Levels[0].Height;
        if (Last > 7) or (W0 <= 0) or (H0 <= 0) or (W0 and (W0 - 1) <> 0) or (H0 and (H0 - 1) <> 0) then
        begin
          FWhy := 'mipmaps of unusual sizes';
          Ok := False;
          Exit(-1);
        end;
      end;
    end;
    Tex.OneLevel := (First = Last) and (First = S.Tex.Level);
    var Addrs, Sizes: array[0..7] of Cardinal;
    var Strides, Widths, Rows: array[0..7] of Int64;
    var Valid: array[0..7] of Boolean;
    for var L := First to Last do
    begin
      Valid[L] := TextureBytes(S.Tex, L, Addrs[L], Sizes[L], Strides[L], Widths[L], Rows[L]) and (Sizes[L] > 0);
      if Valid[L] and (Sizes[L] > $1000000) then
      begin
        FWhy := 'texture larger than 16 MB';
        Ok := False;
        Exit(-1);
      end;
    end;
    // Copies of levels outside VRAM that reach it need VRAM as drawn so far,
    // before any copy is made into this batch.
    for var L := First to Last do
      if Valid[L] and not InVRAM(Addrs[L], Sizes[L]) and TouchesVRAM(Addrs[L], Sizes[L]) then
      begin
        Sync;
        Break;
      end;
    for var L := First to Last do
    begin
      if not Valid[L] then
        Continue;
      var Addr := Addrs[L];
      var Size := Sizes[L];
      if InVRAM(Addr, Size) then
      begin
        var Phys := Int64(Addr and $1FFFFFFF);
        var R := Span(Addr, Size);
        var FirstMirror := (Phys - PSPVRAMBase) div PSPVRAMSize;
        var LastMirror := (Phys + Size - 1 - PSPVRAMBase) div PSPVRAMSize;
        if (FirstMirror and 1 <> 0) or (FirstMirror <> LastMirror) then
        begin
          // The odd mirrors permute bytes within aligned blocks (as
          // TPSPMemory.VRAMOffset and PSPDepthOffset).
          var Block := PermutationBlock(FMemory.VRAMShift);
          R := BlockSpan(R, Block);
          var Alignment := 1;
          case S.Tex.Format of
            0, 1, 2, 6:
              Alignment := 2;
            3, 7, 8, 9, 10:
              Alignment := 4;
          end;
          // An unaligned native read can cross the mapped block's upper edge.
          if Addr and Cardinal(Alignment - 1) <> 0 then
          begin
            if R.Lo + R.Len + Block > PSPVRAMSize then
            begin
              FWhy := 'unaligned texture near the physical VRAM boundary';
              Ok := False;
              Exit(-1);
            end;
            R := Span(R.Lo, R.Len + Block);
          end;
        end
        else if Strides[L] > 0 then
          R := RowSpan(Addr, Strides[L], Widths[L], Rows[L]);
        Tex.Spans[Tex.Count] := R;
        Inc(Tex.Count);
      end
      else
      begin
        // The batch's copy of the same bytes: they are watched since.
        var Key := UInt64(Addr) or (UInt64(Size) shl 32);
        var Old: Integer;
        if FSnapshots.TryGetValue(Key, Old) then
          LevelData[L] := Cardinal(Old)
        else
        begin
          var DataOfs := AddData(Size);
          WatchRAM(Addr, Size);
          FMemory.ReadBytes(Addr, FData[DataOfs], Size);
          FSnapshots.AddOrSetValue(Key, DataOfs);
          LevelData[L] := Cardinal(DataOfs);
        end;
      end;
    end;
    if UsesClut then
    begin
      if (FLastClutData >= 0) and SameBytes(@FData[FLastClutData], S.Tex.Clut, 1024) then
        ClutOfs := FLastClutData
      else
      begin
        ClutOfs := AddData(1024);
        Move(S.Tex.Clut^, FData[ClutOfs], 1024);
        FLastClutData := ClutOfs;
      end;
    end;
  end;
  if (FStateCount + 1) * StateWords > Length(FStates) then
    SetLength(FStates, Max(1024 * StateWords, Length(FStates) * 2));
  Result := FStateCount;
  Inc(FStateCount);
  var W := PCardinal(@FStates[Result * StateWords]);
  FillChar(W^, StateWords * 4, 0);
  W[0] := S.FBAddr;
  W[1] := S.FBStride;
  W[2] := S.FBFormat;
  W[3] := S.ZAddr;
  W[4] := S.ZStride;
  W[5] := Cardinal(S.ScissorX1);
  W[6] := Cardinal(S.ScissorY1);
  W[7] := Cardinal(S.ScissorX2);
  W[8] := Cardinal(S.ScissorY2);
  W[9] := Cardinal(S.BandY1);
  W[10] := Cardinal(S.BandY2);
  var Flags: Cardinal := 0;
  if S.Through then
    Flags := Flags or (1 shl 0);
  if S.ClearMode then
    Flags := Flags or (1 shl 1);
  if S.ClearColor then
    Flags := Flags or (1 shl 2);
  if S.ClearStencil then
    Flags := Flags or (1 shl 3);
  if S.ClearDepth then
    Flags := Flags or (1 shl 4);
  if S.Flat then
    Flags := Flags or (1 shl 5);
  if S.Gouraud then
    Flags := Flags or (1 shl 6);
  if S.Textured then
    Flags := Flags or (1 shl 7);
  if S.TexAlpha then
    Flags := Flags or (1 shl 8);
  if S.ColorDouble then
    Flags := Flags or (1 shl 9);
  if S.FogEnabled then
    Flags := Flags or (1 shl 10);
  if S.ColorTest then
    Flags := Flags or (1 shl 11);
  if S.AlphaTest then
    Flags := Flags or (1 shl 12);
  if S.StencilTest then
    Flags := Flags or (1 shl 13);
  if S.DepthTest then
    Flags := Flags or (1 shl 14);
  if S.DepthWrite then
    Flags := Flags or (1 shl 15);
  if S.Blend then
    Flags := Flags or (1 shl 16);
  if S.Dither then
    Flags := Flags or (1 shl 17);
  if S.LogicOp then
    Flags := Flags or (1 shl 18);
  if S.DepthClamp then
    Flags := Flags or (1 shl 19);
  if S.Textured and S.Tex.NeedLod then
    Flags := Flags or (1 shl 20);
  W[104] := S.KeepMask;
  W[105] := Cardinal(S.ZPermutation);
  W[106] := Cardinal(FMemory.VRAMShift);
  W[ST_FLAGS] := Flags;
  W[12] := Cardinal(S.TexFunc);
  W[13] := Cardinal(S.EnvR);
  W[14] := Cardinal(S.EnvG);
  W[15] := Cardinal(S.EnvB);
  W[16] := Cardinal(S.FogR);
  W[17] := Cardinal(S.FogG);
  W[18] := Cardinal(S.FogB);
  W[19] := Cardinal(S.ColorTestFunc);
  W[20] := S.ColorRef;
  W[21] := S.ColorMask;
  W[22] := Cardinal(S.AlphaFunc);
  W[23] := Cardinal(S.AlphaRef);
  W[24] := Cardinal(S.AlphaMask);
  W[25] := Cardinal(S.StencilFunc);
  W[26] := Cardinal(S.StencilRef);
  W[27] := Cardinal(S.StencilMask);
  W[28] := Cardinal(S.StencilFail);
  W[29] := Cardinal(S.StencilZFail);
  W[30] := Cardinal(S.StencilZPass);
  W[31] := Cardinal(S.DepthFunc);
  W[32] := Cardinal(S.MinZ);
  W[33] := Cardinal(S.MaxZ);
  W[34] := Cardinal(S.BlendOp);
  W[35] := Cardinal(S.BlendSrc);
  W[36] := Cardinal(S.BlendDst);
  W[37] := S.FixA;
  W[38] := S.FixB;
  W[39] := Cardinal(S.LogicFunc);
  W[40] := S.MaskRGB;
  W[41] := Cardinal(S.MaskA);
  for var I := 0 to 15 do
    W[ST_DITHER + I] := Cardinal(S.DitherMatrix[I]);
  if S.Textured then
  begin
    W[ST_TEXFORMAT] := Cardinal(S.Tex.Format);
    W[59] := Ord(S.Tex.Swizzle);
    W[60] := Cardinal(S.Tex.Level);
    W[61] := Ord(S.Tex.ClampU);
    W[62] := Ord(S.Tex.ClampV);
    W[63] := Ord(S.Tex.Linear);
    W[64] := Cardinal(S.Tex.ClutFormat);
    W[65] := Cardinal(S.Tex.ClutShift);
    W[66] := Cardinal(S.Tex.ClutMask);
    W[67] := Cardinal(S.Tex.ClutOffset);
    W[71] := ClutOfs;
    for var L := 0 to 7 do
      W[ST_LEVELDATA + L] := LevelData[L];
    W[ST_MINFILTER] := Cardinal(S.Tex.MinFilter);
    W[ST_MAXLEVEL] := Cardinal(S.Tex.MaxLevel);
    W[ST_LEVELMODE] := Cardinal(S.Tex.LevelMode);
    W[ST_LODBIAS] := Cardinal(S.Tex.LodBias);
    W[ST_SLOPE] := PCardinal(@S.Tex.Slope)^;
    W[ST_CLUTSTEP] := Cardinal(S.Tex.Levels[1].ClutAdd);
    for var L := 0 to 7 do
    begin
      W[ST_LEVELS + L * 4] := S.Tex.Levels[L].Addr;
      W[ST_LEVELS + L * 4 + 1] := Cardinal(S.Tex.Levels[L].Width);
      W[ST_LEVELS + L * 4 + 2] := Cardinal(S.Tex.Levels[L].Height);
      W[ST_LEVELS + L * 4 + 3] := Cardinal(S.Tex.Levels[L].BufWidth);
    end;
  end;
  FLastRaster := S;
  if UsesClut then
    Move(S.Tex.Clut^, FLastClut[0], SizeOf(FLastClut));
  FLastState := Result;
  FLastTranslation := FMemory.VRAMShift;
  FLastTex := Tex;
end;

// Whether a pass already reads (and keeps apart from what it draws) a span.
function Covered(const P: TGEVulkanLLEPass; const R: TGEVulkanLLESpan): Boolean;
begin
  for var I := P.ReadCount - 1 downto 0 do
    if Contains(P.Reads[I], R) then
      Exit(True);
  Result := False;
end;

// Puts the next primitive (covering the box) into a pass. False when the
// kernel cannot draw it exactly as the CPU does. Pixels of a box no wider
// than the stride all have their own bytes, even past the stride's end.
function TGEVulkanLLEBackend.Place(const S: TGERaster; State: Integer; const Tex: TGEVulkanLLEReads;
  X1, Y1, X2, Y2: Integer): Boolean;
begin
  var UsesZ := (S.ClearMode and S.ClearDepth) or (not S.ClearMode and S.DepthTest);
  // Within the last pass's box, with its buffers and textures it reads:
  // everything below has been checked and held for the whole box already.
  if FPassCount > 0 then
  begin
    var P: PGEVulkanLLEPass := @FPasses[FPassCount - 1];
    if (X1 >= P.X1) and (Y1 >= P.Y1) and (X2 <= P.X2) and (Y2 <= P.Y2) and (P.FBAddr = S.FBAddr) and
      (P.FBStride = S.FBStride) and (P.FBFormat = S.FBFormat) and (not UsesZ or (P.UsesZ and (P.ZAddr = S.ZAddr) and
      (P.ZStride = S.ZStride) and (P.ZPermutation = S.ZPermutation))) then
    begin
      var Known := True;
      for var I := 0 to Tex.Count - 1 do
        if not Covered(P^, Tex.Spans[I]) then
        begin
          Known := False;
          Break;
        end;
      if Known then
      begin
        Inc(P.Count);
        Exit(True);
      end;
    end;
  end;

  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  // Distinct pixels must not share memory.
  if (X2 - X1 + 1 > Integer(S.FBStride)) or ((Int64(Y2 - Y1) * S.FBStride + X2 - X1 + 1) * Bpp > PSPVRAMSize) then
  begin
    FWhy := 'pixels share colour memory';
    Exit(False);
  end;
  var FB := TargetSpan(S.FBAddr, S.FBStride, Bpp, X1, Y1, X2, Y2);
  var Z := Default(TGEVulkanLLESpan);
  if UsesZ then
  begin
    if (X2 - X1 + 1 > Integer(S.ZStride)) or ((Int64(Y2 - Y1) * S.ZStride + X2 - X1 + 1) * 2 > PSPVRAMSize) then
    begin
      FWhy := 'pixels share depth memory';
      Exit(False);
    end;
    Z := BlockSpan(TargetSpan(S.ZAddr, S.ZStride, 2, X1, Y1, X2, Y2), PermutationBlock(S.ZPermutation));
    if Overlap(FB, Z) then
    begin
      FWhy := 'colour and depth share memory';
      Exit(False);
    end;
  end;
  // A texture read from the pixels being drawn depends on the drawing order.
  for var I := 0 to Tex.Count - 1 do
    if Overlap(Tex.Spans[I], FB) or Overlap(Tex.Spans[I], Z) then
    begin
      FWhy := 'texture from the pixels drawn';
      Exit(False);
    end;

  var NewPass := FPassCount = 0;
  var PFB := FB;
  var PZ := Z;
  if not NewPass then
  begin
    var P: PGEVulkanLLEPass := @FPasses[FPassCount - 1];
    // Primitives without depth go with any depth buffer.
    if (P.FBAddr <> S.FBAddr) or (P.FBStride <> S.FBStride) or (P.FBFormat <> S.FBFormat) or (UsesZ and P.UsesZ and
      ((P.ZAddr <> S.ZAddr) or (P.ZStride <> S.ZStride) or (P.ZPermutation <> S.ZPermutation))) then
    begin
      NewPass := True;
      Split('render target');
    end
    else
    begin
      var PassZ := P.UsesZ or UsesZ;
      var ZAddr := P.ZAddr;
      var ZStride := P.ZStride;
      var ZPermutation := P.ZPermutation;
      if not P.UsesZ then
      begin
        ZAddr := S.ZAddr;
        ZStride := S.ZStride;
        ZPermutation := S.ZPermutation;
      end;
      var UX1 := Min(P.X1, X1);
      var UY1 := Min(P.Y1, Y1);
      var UX2 := Max(P.X2, X2);
      var UY2 := Max(P.Y2, Y2);
      var Changed := (UX1 <> P.X1) or (UY1 <> P.Y1) or (UX2 <> P.X2) or (UY2 <> P.Y2) or (PassZ <> P.UsesZ);
      PFB := P.FB;
      PZ := P.Z;
      if Changed then
      begin
        PFB := TargetSpan(S.FBAddr, S.FBStride, Bpp, UX1, UY1, UX2, UY2);
        if PassZ then
          PZ := BlockSpan(TargetSpan(ZAddr, ZStride, 2, UX1, UY1, UX2, UY2), PermutationBlock(ZPermutation));
      end;
      var TexReadsPass := False;
      for var I := 0 to Tex.Count - 1 do
        if Overlap(Tex.Spans[I], PFB) or Overlap(Tex.Spans[I], PZ) then
          TexReadsPass := True;
      if Changed and ((UX2 - UX1 + 1 > Integer(S.FBStride)) or ((Int64(UY2 - UY1) * S.FBStride + UX2 - UX1 + 1) * Bpp >
        PSPVRAMSize) or (PassZ and ((UX2 - UX1 + 1 > Integer(ZStride)) or ((Int64(UY2 - UY1) * ZStride + UX2 - UX1 +
        1) * 2 > PSPVRAMSize) or Overlap(PFB, PZ)))) then
      begin
        NewPass := True;
        Split('memory span');
      end
      else if TexReadsPass then
      begin
        NewPass := True;
        Split('texture reads the pass');
      end
      else if Changed then
        for var I := 0 to P.ReadCount - 1 do
          if Overlap(P.Reads[I], PFB) or Overlap(P.Reads[I], PZ) then
          begin
            NewPass := True;
            Split('pass reads the target');
            Break;
          end;
      if NewPass then
      begin
        PFB := FB;
        PZ := Z;
      end;
    end;
  end;
  if NewPass then
  begin
    if FPassCount = Length(FPasses) then
      SetLength(FPasses, Max(64, FPassCount * 2));
    var P: PGEVulkanLLEPass := @FPasses[FPassCount];
    Inc(FPassCount);
    var Reads := P.Reads;
    P^ := Default(TGEVulkanLLEPass);
    P.Reads := Reads;
    P.First := FPrimCount;
    P.X1 := X1;
    P.Y1 := Y1;
    P.X2 := X2;
    P.Y2 := Y2;
    P.FBAddr := S.FBAddr;
    P.FBStride := S.FBStride;
    P.FBFormat := S.FBFormat;
  end;
  var P: PGEVulkanLLEPass := @FPasses[FPassCount - 1];
  if UsesZ and not P.UsesZ then
  begin
    P.UsesZ := True;
    P.ZAddr := S.ZAddr;
    P.ZStride := S.ZStride;
    P.ZPermutation := S.ZPermutation;
  end;
  Inc(P.Count);
  P.X1 := Min(P.X1, X1);
  P.Y1 := Min(P.Y1, Y1);
  P.X2 := Max(P.X2, X2);
  P.Y2 := Max(P.Y2, Y2);
  // The whole box's buffers are held, so primitives within it need nothing.
  if (PFB.Lo <> P.FB.Lo) or (PFB.Len <> P.FB.Len) then
  begin
    P.FB := PFB;
    Hold(PFB);
  end;
  if P.UsesZ and ((PZ.Lo <> P.Z.Lo) or (PZ.Len <> P.Z.Len)) then
  begin
    P.Z := PZ;
    Hold(PZ);
  end;
  for var I := 0 to Tex.Count - 1 do
    if not Covered(P^, Tex.Spans[I]) then
    begin
      if P.ReadCount = Length(P.Reads) then
        SetLength(P.Reads, Max(8, P.ReadCount * 2));
      P.Reads[P.ReadCount] := Tex.Spans[I];
      Inc(P.ReadCount);
      WatchVRAM(Tex.Spans[I]);
    end;
  Result := True;
end;

procedure TGEVulkanLLEBackend.Record_(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  if not FCheck then
    Exit;
  var C := Default(TGEVulkanLLECheckPrim);
  C.Kind := Kind;
  C.S := S;
  C.V[0] := V0;
  C.V[1] := V1;
  C.V[2] := V2;
  if S.Textured and (S.Tex.Clut <> nil) then
  begin
    SetLength(C.Clut, 1024);
    Move(S.Tex.Clut^, C.Clut[0], 1024);
  end;
  FCheckPrims.Add(C);
end;

// A primitive the GPU can draw (Pixels in its box) is drawn on the CPU when
// it follows a CPU-drawn one closely enough. Guest memory has everything:
// nothing is pending on the GPU during the run, whose pages the next GPU
// batch compares and uploads as usual.
function TGEVulkanLLEBackend.OnCPU(Pixels: Int64): Boolean;
begin
  if FCPURun and (Pixels <= FCPUBudget) then
  begin
    Dec(FCPUBudget, Pixels);
    Inc(FStats.CPURunPrims);
    Exit(True);
  end;
  // The GPU draws next: the queue's primitives come first.
  FCPURun := False;
  DrainQueue;
  Result := False;
end;

// The CPU renderer's queue draws exactly as PSP.GE.Raster in order (in row
// bands, in the background), holding and watching what it uses meanwhile.
procedure TGEVulkanLLEBackend.Enqueue(Kind: Integer; const S: TGERaster; const V0, V1, V2: TGEVertex);
begin
  if FCheck or (FQueue = nil) then
  begin
    case Kind of
      KindTriangle:
        GEDrawTriangle(S, V0, V1, V2);
      KindSprite:
        GEDrawSprite(S, V0, V1);
      KindLine:
        GEDrawLine(S, V0, V1);
    else
      GEDrawPoint(S, V0);
    end;
    Exit;
  end;
  FQueued := True;
  if S.Textured and (S.Tex.Format >= 4) and (S.Tex.Format <= 7) and (not FQueueClutValid or
    not SameBytes(S.Tex.Clut, @FQueueClut[0], SizeOf(FQueueClut))) then
  begin
    Move(S.Tex.Clut^, FQueueClut[0], SizeOf(FQueueClut));
    FQueueClutValid := True;
    FQueue.ClutChanged;
  end;
  FQueue.StateChanged;
  case Kind of
    KindTriangle:
      FQueue.Triangle(S, V0, V1, V2);
    KindSprite:
      FQueue.Sprite(S, V0, V1);
    KindLine:
      FQueue.Line(S, V0, V1);
  else
    FQueue.Point(S, V0);
  end;
end;

procedure TGEVulkanLLEBackend.DrainQueue;
begin
  if FQueued then
  begin
    FQueued := False;
    FQueue.Sync;
  end;
end;

// Draws everything on the GPU and starts a run on the CPU, whose queue the
// primitive goes to.
procedure TGEVulkanLLEBackend.Fallback;
begin
  if Pending then
  begin
    Inc(FStats.FallbackSyncs);
    Sync;
  end;
  // Check mode compares every batch with the CPU: no runs there.
  FCPURun := not FCheck and (FCPURunPixels > 0);
  if FGPUSinceRun < RunReturn then
    FRunBudget := Min(Max(FRunBudget, MinRunPixels div 4) * 4, FCPURunPixels)
  else
    FRunBudget := Min(MinRunPixels, FCPURunPixels);
  FCPUBudget := FRunBudget;
  FGPUSinceRun := 0;
  Inc(FStats.Fallbacks);
  var N := 0;
  FReasons.TryGetValue(FWhy, N);
  FReasons.AddOrSetValue(FWhy, N + 1);
  if N = 0 then
    Message('gpu: drawn on the CPU: ' + FWhy);
end;

procedure PutVertex(P: PCardinal; const V: TGEVertex);
begin
  P[0] := Cardinal(V.X);
  P[1] := Cardinal(V.Y);
  P[2] := Cardinal(V.Z);
  P[3] := PCardinal(@V.W)^;
  P[4] := Cardinal(V.R);
  P[5] := Cardinal(V.G);
  P[6] := Cardinal(V.B);
  P[7] := Cardinal(V.A);
  P[8] := Cardinal(V.SR);
  P[9] := Cardinal(V.SG);
  P[10] := Cardinal(V.SB);
  P[11] := PCardinal(@V.S)^;
  P[12] := PCardinal(@V.T)^;
  P[13] := PCardinal(@V.Fog)^;
end;

// A colour or fog plane (GEMakeValuePlane): the start, the steps per 1/16
// pixel; its vertex (the same for every plane of the triangle) in
// Anchor[0..1].
procedure PutPlane(P, Anchor: PCardinal; const V0, V1, V2: TGEVertex; C0, C1, C2: Integer);
var
  VP: TGEDepthPlane;
begin
  GEMakeValuePlane(V0, V1, V2, C0, C1, C2, VP);
  PInt64(P)^ := VP.C0;
  PInt64(P + 2)^ := VP.GX;
  PInt64(P + 4)^ := VP.GY;
  Anchor[0] := Cardinal(Integer(VP.AX));
  Anchor[1] := Cardinal(Integer(VP.AY));
end;

// Perspective texture coordinate planes (GEPerspPlanes) in a triangle's
// words: 128..133 S, 134..139 T, 140..145 Q (start and steps), 146, 147 their
// vertex, 148..150 their fraction bits, 151 bit 0 whether they are used (152:
// the level of detail's pixel, GELodPixel).
procedure PutPerspPlanes(P: PCardinal; const PP: TGEPerspPlanes);
begin
  PInt64(P + 128)^ := PP.S.C0;
  PInt64(P + 130)^ := PP.S.GX;
  PInt64(P + 132)^ := PP.S.GY;
  PInt64(P + 134)^ := PP.T.C0;
  PInt64(P + 136)^ := PP.T.GX;
  PInt64(P + 138)^ := PP.T.GY;
  PInt64(P + 140)^ := PP.Q.C0;
  PInt64(P + 142)^ := PP.Q.GX;
  PInt64(P + 144)^ := PP.Q.GY;
  P[146] := Cardinal(Integer(PP.Q.AX));
  P[147] := Cardinal(Integer(PP.Q.AY));
  P[148] := Cardinal(PP.KS);
  P[149] := Cardinal(PP.KT);
  P[150] := Cardinal(PP.KQ);
  P[151] := 1;
end;

// Texture coordinate planes (GEUVPlanes) in a triangle's or a sprite's words:
// 111..116 S, 117..122 T (start and steps), 123, 124 their vertex, 125 bit 0
// whether they are used, bits 8.. and 16.. their fraction bits.
procedure PutUVPlanes(P: PCardinal; const UV: TGEUVPlanes);
begin
  PInt64(P + 111)^ := UV.S.C0;
  PInt64(P + 113)^ := UV.S.GX;
  PInt64(P + 115)^ := UV.S.GY;
  PInt64(P + 117)^ := UV.T.C0;
  PInt64(P + 119)^ := UV.T.GX;
  PInt64(P + 121)^ := UV.T.GY;
  P[123] := Cardinal(Integer(UV.S.AX));
  P[124] := Cardinal(Integer(UV.S.AY));
  P[125] := 1 or (Cardinal(UV.KS) shl 8) or (Cardinal(UV.KT) shl 16);
end;

procedure TGEVulkanLLEBackend.DrawTriangle(const S: TGERaster; const V0, V1, V2: TGEVertex);
var
  Tex: TGEVulkanLLEReads;
  Ok: Boolean;
begin
  BeginPrim;
  // The set-up of GEDrawTriangle.
{$I PSP.GE.TriangleSetup.inc}
  if OnCPU(Int64(PX2 - PX1 + 1) * (PY2 - PY1 + 1)) then
  begin
    Enqueue(KindTriangle, S, V0, V1, V2);
    Exit;
  end;
  var DX0 := X2 - X1;
  var DY0 := Y2 - Y1;
  var DX1 := X0 - X2;
  var DY1 := Y0 - Y2;
  var DX2 := X1 - X0;
  var DY2 := Y1 - Y0;
  var Bias: Cardinal := 0;
  if not ((DY0 < 0) or ((DY0 = 0) and (DX0 > 0))) then
    Bias := Bias or 1;
  if not ((DY1 < 0) or ((DY1 = 0) and (DX1 > 0))) then
    Bias := Bias or 2;
  if not ((DY2 < 0) or ((DY2 = 0) and (DX2 > 0))) then
    Bias := Bias or 4;
  var FArea := 1.0 / Area;

  var State := PackState(S, Tex, Ok);
  var NeedLod := Ok and S.Textured and S.Tex.NeedLod;
  if NeedLod then
  begin
    // GEDrawTriangle keeps the last pixel's level of detail where Q or 1/w
    // is not positive: with finite positive Q*w and w at the corners, every
    // covered pixel has its own.
    var AQ0: Single := A0.Q * A0.W;
    var AQ1: Single := A1.Q * A1.W;
    var AQ2: Single := A2.Q * A2.W;
    if not ((AQ0 > 0) and (AQ0 <= MaxSingle) and (AQ1 > 0) and (AQ1 <= MaxSingle) and (AQ2 > 0) and
      (AQ2 <= MaxSingle) and (A0.W > 0) and (A0.W <= MaxSingle) and (A1.W > 0) and (A1.W <= MaxSingle) and
      (A2.W > 0) and (A2.W <= MaxSingle)) then
    begin
      FWhy := 'level of detail with non-positive Q or w';
      Ok := False;
    end;
  end;
  // Only the texels it samples: it may draw beside them in the same buffer.
  if Ok and (Tex.Count = 1) and Tex.OneLevel and (Tex.Spans[0].Stride > 0) then
    Tex.Spans[0] := TriangleTexels(S, V0, V1, V2, Tex.Spans[0]);
  if not Ok or not Place(S, State, Tex, PX1, PY1, PX2, PY2) then
  begin
    Fallback;
    Enqueue(KindTriangle, S, V0, V1, V2);
    Exit;
  end;
  var P := NewPrim;
  P[0] := KindTriangle;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX1);
  P[3] := Cardinal(PY1);
  P[4] := Cardinal(PX2);
  P[5] := Cardinal(PY2);
  PutVertex(@P[6], A0^);
  PutVertex(@P[20], A1^);
  PutVertex(@P[34], A2^);
  P[48] := Cardinal(V2.R);
  P[49] := Cardinal(V2.G);
  P[50] := Cardinal(V2.B);
  P[51] := Cardinal(V2.A);
  P[52] := Cardinal(V2.SR);
  P[53] := Cardinal(V2.SG);
  P[54] := Cardinal(V2.SB);
  P[55] := Cardinal(UInt64(Area));
  P[56] := Cardinal(UInt64(Area) shr 32);
  P[57] := Cardinal(PUInt64(@FArea)^);
  P[58] := Cardinal(PUInt64(@FArea)^ shr 32);
  P[59] := Bias;
  P[60] := PCardinal(@A0.Q)^;
  P[61] := PCardinal(@A1.Q)^;
  P[62] := PCardinal(@A2.Q)^;
  // The colour and fog planes (64, 65 their vertex).
  if S.Gouraud and not S.Flat then
  begin
    PutPlane(P + 66, P + 64, V0, V1, V2, V0.R, V1.R, V2.R);
    PutPlane(P + 72, P + 64, V0, V1, V2, V0.G, V1.G, V2.G);
    PutPlane(P + 78, P + 64, V0, V1, V2, V0.B, V1.B, V2.B);
    PutPlane(P + 84, P + 64, V0, V1, V2, V0.A, V1.A, V2.A);
  end;
  // Through mode: the texture coordinates' planes (GEUVPlanes): 111..116 S,
  // 117..122 T (start and steps), 123, 124 their vertex, 125 bit 0 whether
  // they are used, bits 8.. and 16.. their fraction bits.
  var UV: TGEUVPlanes;
  P[125] := 0;
  if S.Textured and S.Through and GEUVPlanes(S, V0, V1, V2, UV) then
    PutUVPlanes(P, UV);
  // Transform mode: the perspective planes (GEPerspPlanes).
  var PP: TGEPerspPlanes;
  if S.Textured and not S.Through and GEPerspPlanes(V0, V1, V2, PP) then
    PutPerspPlanes(P, PP);
  // The fog plane, from the vertices' 8-bit fog factors (GEFogByte).
  if S.FogEnabled then
    PutPlane(P + 96, P + 64, V0, V1, V2, GEFogByte(V0.Fog), GEFogByte(V1.Fog), GEFogByte(V2.Fog));
  // The depth plane (GEMakeDepthPlane) when the depths differ: 102, 103 its
  // vertex, 104..109 the start and the steps, 110 whether it is used.
  if (V0.Z <> V1.Z) or (V0.Z <> V2.Z) then
  begin
    var DP: TGEDepthPlane;
    GEMakeDepthPlane(V0, V1, V2, DP);
    if DP.Valid then
    begin
      P[102] := Cardinal(Integer(DP.AX));
      P[103] := Cardinal(Integer(DP.AY));
      PInt64(P + 104)^ := DP.C0;
      PInt64(P + 106)^ := DP.GX;
      PInt64(P + 108)^ := DP.GY;
      P[110] := 1;
    end;
  end;
  if NeedLod then
  begin
    // GEDrawTriangle's steps of S/w and T/w along x and y, as it rounds them.
    var BX0 := -16 * DY0 * FArea;
    var BY0 := 16 * DX0 * FArea;
    var BX1 := -16 * DY1 * FArea;
    var BY1 := 16 * DX1 * FArea;
    var BX2 := -16 * DY2 * FArea;
    var BY2 := 16 * DX2 * FArea;
    var NSX, NSY, NTX, NTY: Single;
    NSX := A0.S * A0.W * BX0 + A1.S * A1.W * BX1 + A2.S * A2.W * BX2;
    NSY := A0.S * A0.W * BY0 + A1.S * A1.W * BY1 + A2.S * A2.W * BY2;
    NTX := A0.T * A0.W * BX0 + A1.T * A1.W * BX1 + A2.T * A2.W * BX2;
    NTY := A0.T * A0.W * BY0 + A1.T * A1.W * BY1 + A2.T * A2.W * BY2;
    // With the perspective planes: their G (GEPerspLodG) alone.
    if P[151] and 1 <> 0 then
    begin
      NSX := GEPerspLodG(PP);
      NSY := 0;
      NTX := 0;
      NTY := 0;
    end;
    P[90] := PCardinal(@NSX)^;
    P[91] := PCardinal(@NSY)^;
    P[92] := PCardinal(@NTX)^;
    P[93] := PCardinal(@NTY)^;
    // 152: GELodPixel.
    P[152] := Cardinal(GELodPixel(V0, V1, V2));
  end;
  Record_(KindTriangle, S, V0, V1, V2);
end;

procedure TGEVulkanLLEBackend.DrawSprite(const S: TGERaster; const V0, V1: TGEVertex);
var
  Tex: TGEVulkanLLEReads;
  Ok: Boolean;
begin
  BeginPrim;
  // The set-up of GEDrawSprite.
  var X1 := Min(V0.X, V1.X);
  var X2 := Max(V0.X, V1.X);
  var Y1 := Min(V0.Y, V1.Y);
  var Y2 := Max(V0.Y, V1.Y);
  var PX1 := (X1 - 9 + 15 + 65536) div 16 - 4096;
  var PX2 := (X2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  var PY1 := (Y1 - 8 + 15 + 65536) div 16 - 4096;
  var PY2 := (Y2 - 8 + 15 + 65536) div 16 - 4096 - 1;
  PX1 := Max(PX1, S.ScissorX1);
  PY1 := Max(PY1, Max(S.ScissorY1, S.BandY1));
  PX2 := Min(PX2, S.ScissorX2);
  PY2 := Min(PY2, Min(S.ScissorY2, S.BandY2));
  if (PX1 > PX2) or (PY1 > PY2) then
    Exit;
  if OnCPU(Int64(PX2 - PX1 + 1) * (PY2 - PY1 + 1)) then
  begin
    Enqueue(KindSprite, S, V0, V1, V1);
    Exit;
  end;
  var Turned := (V0.X > V1.X) <> (V0.Y > V1.Y);
  var SX: Single := 0;
  var SY: Single := 0;
  var TX: Single := 0;
  var TY: Single := 0;
  var QX: Single := 0;
  var QY: Single := 0;
  if V1.X <> V0.X then
  begin
    if Turned then
      TX := GESpriteStep(V1.T - V0.T, V1.X - V0.X)
    else
    begin
      SX := GESpriteStep(V1.S - V0.S, V1.X - V0.X);
      QX := GESpriteStep(V1.Q - V0.Q, V1.X - V0.X);
    end;
  end;
  if V1.Y <> V0.Y then
  begin
    if Turned then
    begin
      SY := GESpriteStep(V1.S - V0.S, V1.Y - V0.Y);
      QY := GESpriteStep(V1.Q - V0.Q, V1.Y - V0.Y);
    end
    else
      TY := GESpriteStep(V1.T - V0.T, V1.Y - V0.Y);
  end;

  var State := PackState(S, Tex, Ok);
  // Only the texels it samples: it may draw beside them in the same buffer.
  if Ok and (Tex.Count = 1) and Tex.OneLevel and (Tex.Spans[0].Stride > 0) then
    if not S.Through then
      Tex.Spans[0] := SpritePerspTexels(S, V0, V1, Tex.Spans[0])
    else if (V0.Q = 1) and (V1.Q = 1) then
      Tex.Spans[0] := SpriteTexels(S, V0, SX, SY, TX, TY, PX1, PY1, PX2, PY2, Tex.Spans[0]);
  if not Ok or not Place(S, State, Tex, PX1, PY1, PX2, PY2) then
  begin
    Fallback;
    Enqueue(KindSprite, S, V0, V1, V1);
    Exit;
  end;
  var P := NewPrim;
  P[0] := KindSprite;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX1);
  P[3] := Cardinal(PY1);
  P[4] := Cardinal(PX2);
  P[5] := Cardinal(PY2);
  PutVertex(@P[6], V0);
  PutVertex(@P[20], V1);
  P[34] := PCardinal(@SX)^;
  P[35] := PCardinal(@SY)^;
  P[36] := PCardinal(@TX)^;
  P[37] := PCardinal(@TY)^;
  P[38] := PCardinal(@QX)^;
  P[39] := PCardinal(@QY)^;
  P[40] := PCardinal(@V0.Q)^;
  P[41] := Ord((V0.Q <> 1) or (V1.Q <> 1));
  // One level of detail for the whole sprite, as GEDrawSprite computes it.
  var Lod := 0;
  if S.Textured and S.Tex.NeedLod then
  begin
    var IW: Single := 1;
    if V1.W > 0 then
      IW := V1.W;
    Lod := GETexLod(S, Max(Max(Abs(SX), Abs(SY)), Max(Abs(TX), Abs(TY))), 1, IW);
  end;
  P[42] := Cardinal(Lod);
  // The texture coordinates' planes as a triangle's: through mode
  // GESpriteUVPlanes, transform mode GESpritePerspPlanes.
  var UV: TGEUVPlanes;
  P[125] := 0;
  if S.Textured and S.Through and GESpriteUVPlanes(S, V0, V1, UV) then
    PutUVPlanes(P, UV);
  var PP: TGEPerspPlanes;
  if S.Textured and not S.Through and GESpritePerspPlanes(V0, V1, PP) then
    PutPerspPlanes(P, PP);
  Record_(KindSprite, S, V0, V1, V1);
end;

function RasterRound(X: Double): Integer;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  assembler;
{$ELSE}
  inline;
{$ENDIF}
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
asm
  .NOFRAME
  CVTSD2SI EAX, XMM0
end;
{$ELSE}
begin
  Result := Round(X);
end;
{$ENDIF}

procedure TGEVulkanLLEBackend.DrawLine(const S: TGERaster; const V0, V1: TGEVertex);
var
  F: TGEVulkanLLEFragment;
  Frags: TArray<TGEVulkanLLEFragment>;
  Pos: TArray<TPoint>;
  Tex: TGEVulkanLLEReads;
  Ok: Boolean;
begin
  BeginPrim;
  // GEDrawLine, keeping the fragments.
  var LW: TGELineWalk;
  if not GELineStart(V0, V1, LW) then
    Exit;
  var PX, PY: Integer;
  var T: Single;
  // Count the pixels (one a step of the major axis, without gaps), then walk
  // them again, kept in increasing order on the major axis as the shader
  // looks them up.
  var Count := 0;
  var First := MaxInt;
  var Probe := LW;
  while GELineNext(Probe, PX, PY, T) do
  begin
    Inc(Count);
    if LW.XMajor then
      First := Min(First, PX)
    else
      First := Min(First, PY);
  end;
  if Count = 0 then
    Exit;
  SetLength(Frags, Count);
  SetLength(Pos, Count);
  var BX1 := MaxInt;
  var BY1 := MaxInt;
  var BX2 := -MaxInt;
  var BY2 := -MaxInt;
  var N := 0;
  while GELineNext(LW, PX, PY, T) do
  begin
    F.R := V1.R;
    F.G := V1.G;
    F.B := V1.B;
    F.A := V1.A;
    F.SR := V1.SR;
    F.SG := V1.SG;
    F.SB := V1.SB;
    F.Z := V1.Z;
    F.S := V1.S;
    F.T := V1.T;
    F.Fog := V1.Fog;
    if not S.Flat and S.Gouraud then
    begin
      F.R := GELineColor(LW, PX, PY, V0.R, V1.R);
      F.G := GELineColor(LW, PX, PY, V0.G, V1.G);
      F.B := GELineColor(LW, PX, PY, V0.B, V1.B);
      F.A := GELineColor(LW, PX, PY, V0.A, V1.A);
    end;
    if S.Antialias then
      F.A := GELineCoverage(LW, PX, PY);
    F.Z := RasterRound(V0.Z + (V1.Z - V0.Z) * T);
    F.S := V0.S + (V1.S - V0.S) * T;
    F.T := V0.T + (V1.T - V0.T) * T;
    var Q := V0.Q + (V1.Q - V0.Q) * T;
    if (Q <> 1) and (Q <> 0) then
    begin
      F.S := F.S / Q;
      F.T := F.T / Q;
    end;
    F.Fog := V0.Fog + (V1.Fog - V0.Fog) * T;
    var Slot := N;
    if LW.Step < 0 then
      Slot := Count - 1 - N;
    Frags[Slot] := F;
    Pos[Slot] := TPoint.Create(PX, PY);
    Inc(N);
    BX1 := Min(BX1, PX);
    BY1 := Min(BY1, PY);
    BX2 := Max(BX2, PX);
    BY2 := Max(BY2, PY);
  end;
  BX1 := Max(BX1, S.ScissorX1);
  BY1 := Max(BY1, Max(S.ScissorY1, S.BandY1));
  BX2 := Min(BX2, S.ScissorX2);
  BY2 := Min(BY2, Min(S.ScissorY2, S.BandY2));
  if (BX1 > BX2) or (BY1 > BY2) then
    Exit;
  if OnCPU(Length(Frags)) then
  begin
    Enqueue(KindLine, S, V0, V1, V1);
    Exit;
  end;
  var State := PackState(S, Tex, Ok);
  if not Ok or not Place(S, State, Tex, BX1, BY1, BX2, BY2) then
  begin
    Fallback;
    Enqueue(KindLine, S, V0, V1, V1);
    Exit;
  end;
  var Ofs := AddData(Length(Frags) * FragWords * 4);
  var W := PCardinal(@FData[Ofs]);
  FillChar(W^, Length(Frags) * FragWords * 4, 0);
  for var I := 0 to High(Frags) do
  begin
    var Q := W + I * FragWords;
    Q[0] := Cardinal(Pos[I].X);
    Q[1] := Cardinal(Pos[I].Y);
    Q[2] := Cardinal(Frags[I].R);
    Q[3] := Cardinal(Frags[I].G);
    Q[4] := Cardinal(Frags[I].B);
    Q[5] := Cardinal(Frags[I].A);
    Q[6] := Cardinal(Frags[I].SR);
    Q[7] := Cardinal(Frags[I].SG);
    Q[8] := Cardinal(Frags[I].SB);
    Q[9] := Cardinal(Frags[I].Z);
    Q[10] := PCardinal(@Frags[I].S)^;
    Q[11] := PCardinal(@Frags[I].T)^;
    Q[12] := PCardinal(@Frags[I].Fog)^;
  end;
  var P := NewPrim;
  P[0] := KindFragments;
  P[1] := Cardinal(State);
  P[2] := Cardinal(BX1);
  P[3] := Cardinal(BY1);
  P[4] := Cardinal(BX2);
  P[5] := Cardinal(BY2);
  P[6] := Cardinal(Length(Frags));
  P[7] := Cardinal(First);
  P[8] := Ord(LW.XMajor);
  P[9] := Cardinal(Ofs div 4);
  Record_(KindLine, S, V0, V1, V1);
end;

procedure TGEVulkanLLEBackend.DrawPoint(const S: TGERaster; const V: TGEVertex);
var
  Tex: TGEVulkanLLEReads;
  Ok: Boolean;
begin
  BeginPrim;
  var PX := (V.X + $100000) div 16 - $10000;
  var PY := (V.Y + $100000) div 16 - $10000;
  if (PX < S.ScissorX1) or (PX > S.ScissorX2) or (PY < S.ScissorY1) or (PY > S.ScissorY2) or (PY < S.BandY1) or
    (PY > S.BandY2) then
    Exit;
  if OnCPU(1) then
  begin
    Enqueue(KindPoint, S, V, V, V);
    Exit;
  end;
  var State := PackState(S, Tex, Ok);
  if not Ok or not Place(S, State, Tex, PX, PY, PX, PY) then
  begin
    Fallback;
    Enqueue(KindPoint, S, V, V, V);
    Exit;
  end;
  var Ofs := AddData(FragWords * 4);
  var Q := PCardinal(@FData[Ofs]);
  FillChar(Q^, FragWords * 4, 0);
  Q[0] := Cardinal(PX);
  Q[1] := Cardinal(PY);
  Q[2] := Cardinal(V.R);
  Q[3] := Cardinal(V.G);
  Q[4] := Cardinal(V.B);
  Q[5] := Cardinal(V.A);
  Q[6] := Cardinal(V.SR);
  Q[7] := Cardinal(V.SG);
  Q[8] := Cardinal(V.SB);
  Q[9] := Cardinal(V.Z);
  var FS: Single := V.S;
  var FT: Single := V.T;
  if S.Textured then
    GEPointUV(S, V, FS, FT);
  Q[10] := PCardinal(@FS)^;
  Q[11] := PCardinal(@FT)^;
  Q[12] := PCardinal(@V.Fog)^;
  var P := NewPrim;
  P[0] := KindFragments;
  P[1] := Cardinal(State);
  P[2] := Cardinal(PX);
  P[3] := Cardinal(PY);
  P[4] := Cardinal(PX);
  P[5] := Cardinal(PY);
  P[6] := 1;
  P[7] := Cardinal(PX);
  P[8] := 1;
  P[9] := Cardinal(Ofs div 4);
  Record_(KindPoint, S, V, V, V);
end;

procedure TGEVulkanLLEBackend.Submit(ReadBack: Boolean; ReadPages: PGEVulkanLLEPageMask);
var
  Push: TGEVulkanLLEPush;
begin
  ReadBack := ReadBack and (FDrawnCount > 0);
  if (FPrimCount = 0) and (FUploadCount = 0) and not ReadBack then
    Exit;
  var Index := FNextSlot;
  var Slot: PGEVulkanLLESlot := @FSlots[Index];
  if Slot.Busy then
    Complete(Index);
  FNextSlot := (FNextSlot + 1) mod Length(FSlots);
  try
    var Tables: TArray<Cardinal>;
    var Grid: TArray<TPoint>;
    if FPrimCount > 0 then
    begin
      Inc(FStats.Batches);
      Inc(FStats.Passes, FPassCount);
      Inc(FStats.Prims, FPrimCount);
      FBinCount := 0;
      SetLength(Tables, FPassCount);
      SetLength(Grid, FPassCount);
      for var I := 0 to FPassCount - 1 do
        Tables[I] := BinPass(FPasses[I], Grid[I].X, Grid[I].Y);
      Grow(Index, Slot.PrimBuf, Int64(FPrimCount) * PrimWords * 4);
      Grow(Index, Slot.StateBuf, Int64(FStateCount) * StateWords * 4);
      Grow(Index, Slot.DataBuf, Max(FDataSize, 16));
      Grow(Index, Slot.BinBuf, Int64(FBinCount) * 4);
      Slot.PrimBuf.Write(0, FPrims[0], FPrimCount * PrimWords * 4);
      Slot.StateBuf.Write(0, FStates[0], FStateCount * StateWords * 4);
      if FDataSize > 0 then
        Slot.DataBuf.Write(0, FData[0], FDataSize);
      Slot.BinBuf.Write(0, FBins[0], FBinCount * 4);
    end;

    var Cmd := Slot.Cmd;
    var Upload := Slot.Upload.Data;
    Cmd.Start;
    Cmd.Timestamp(0);
    // Pages guest memory changed since the GPU last had them (VerifyPage put
    // them into the shadow).
    if FUploadCount > 0 then
    begin
      var Run := -1;
      for var Page := 0 to VRAMPages do
      begin
        if (Page < VRAMPages) and FUpload[Page] then
        begin
          FUpload[Page] := False;
          Move(FShadow[Page * PageSize], Upload[Page * PageSize], PageSize);
          Inc(FStats.UploadedPages);
          if Run < 0 then
            Run := Page;
        end
        else if Run >= 0 then
        begin
          Slot.Upload.Flush(Run * PageSize, (Page - Run) * PageSize);
          Cmd.Copy(Slot.Upload, FVRAM, Run * PageSize, Run * PageSize, (Page - Run) * PageSize);
          Run := -1;
        end;
      end;
      Cmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_SHADER_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or
        VK_ACCESS_TRANSFER_READ_BIT);
    end;
    Cmd.Timestamp(1);
    FKernel.ActiveSet := Index;
    for var I := 0 to FPassCount - 1 do
    begin
      var P: PGEVulkanLLEPass := @FPasses[I];
      Push.Table := Tables[I];
      Push.TilesX := Grid[I].X;
      Push.X1 := P.X1;
      Push.Y1 := P.Y1;
      Push.X2 := P.X2;
      Push.Y2 := P.Y2;
      Cmd.Dispatch(FKernel, Grid[I].X, Grid[I].Y, 1, Push, SizeOf(Push));
      Cmd.Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_SHADER_READ_BIT or
        VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_READ_BIT);
    end;
    Cmd.Timestamp(2);
    // Everything drawn since the last read back: only those pages can differ.
    Slot.PageCount := 0;
    if ReadBack then
    begin
      if FPassCount = 0 then
        Cmd.Barrier(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_TRANSFER_READ_BIT);
      FillChar(Slot.Pages, SizeOf(Slot.Pages), 0);
      for var Page := 0 to VRAMPages - 1 do
        if FDrawn[Page] and ((ReadPages = nil) or ReadPages[Page]) then
        begin
          Slot.Pages[Page] := True;
          FDrawn[Page] := False;
          Inc(Slot.PageCount);
          Dec(FDrawnCount);
        end;
      Inc(FStats.ReadbackPages, Slot.PageCount);
      var Run := -1;
      for var Page := 0 to VRAMPages do
      begin
        if (Page < VRAMPages) and Slot.Pages[Page] then
        begin
          if Run < 0 then
            Run := Page;
        end
        else if Run >= 0 then
        begin
          Cmd.Copy(FVRAM, Slot.Readback, Run * PageSize, Run * PageSize, (Page - Run) * PageSize);
          Run := -1;
        end;
      end;
    end;
    // A later submission must not overwrite VRAM while this one reads it.
    Cmd.Barrier(VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT or VK_ACCESS_TRANSFER_WRITE_BIT,
      VK_PIPELINE_STAGE_HOST_BIT or VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT or VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_ACCESS_HOST_READ_BIT or VK_ACCESS_SHADER_WRITE_BIT or VK_ACCESS_TRANSFER_WRITE_BIT);
    Cmd.Timestamp(3);
    Cmd.Submit;
    Inc(FSubmitted);
    Slot.Order := FSubmitted;
    Slot.Busy := True;
  finally
    FPrimCount := 0;
    FPassCount := 0;
    FStateCount := 0;
    FDataSize := 0;
    FLastState := -1;
    FLastClutData := -1;
    FSnapshots.Clear;
    if FUploadCount > 0 then
    begin
      FillChar(FUpload, SizeOf(FUpload), 0);
      FUploadCount := 0;
    end;
    if not FCheck then
      FCheckPrims.Clear;
  end;
end;

// Waits for a slot's batch and puts the pages it read back into guest memory
// (which in check mode gets the CPU's drawing instead, compared with the GPU's).
procedure TGEVulkanLLEBackend.Complete(Slot: Integer);
begin
  var S: PGEVulkanLLESlot := @FSlots[Slot];
  if not S.Busy then
    Exit;
  var Watch := TStopwatch.StartNew;
  S.Cmd.Wait;
  S.Busy := False;
  FStats.WaitSeconds := FStats.WaitSeconds + Watch.Elapsed.TotalSeconds;
  FStats.UploadSeconds := FStats.UploadSeconds + S.Cmd.Elapsed(0, 1) * 1e-9;
  FStats.DrawSeconds := FStats.DrawSeconds + S.Cmd.Elapsed(1, 2) * 1e-9;
  FStats.ReadbackSeconds := FStats.ReadbackSeconds + S.Cmd.Elapsed(2, 3) * 1e-9;
  if S.PageCount = 0 then
    Exit;
  S.Readback.Invalidate;
  var Back := S.Readback.Data;
  var VRAM: PByte := @FMemory.VRAM[0];
  if FCheck then
  begin
    FMemory.ReleaseVRAM;
    CheckBatch(S.Pages, S.Readback);
    FCheckPrims.Clear;
  end;
  for var Page := 0 to VRAMPages - 1 do
    if S.Pages[Page] then
    begin
      if not FCheck then
        Move(Back[Page * PageSize], VRAM[Page * PageSize], PageSize);
      Move(Back[Page * PageSize], FShadow[Page * PageSize], PageSize);
    end;
  S.PageCount := 0;
end;

// Work or held and watched pages of the GPU's own (not of the queue's).
function TGEVulkanLLEBackend.Pending: Boolean;
begin
  Result := (FPrimCount > 0) or (FDrawnCount > 0) or (FUploadCount > 0) or (FVerifiedCount > 0) or FWatchedRAM;
  for var I := 0 to High(FSlots) do
    Result := Result or FSlots[I].Busy;
end;

procedure TGEVulkanLLEBackend.SyncRange(Address, Size: Cardinal);
var
  Pages: TGEVulkanLLEPageMask;
begin
  if FSyncing then Exit;
  FSyncing := True;
  try
    FillChar(Pages, SizeOf(Pages), 0);
    var Lo := Max(UInt64(Address and $1FFFFFFF), UInt64(PSPVRAMBase));
    var Hi := Min(UInt64(Address and $1FFFFFFF) + Size, UInt64(PSPVRAMBase + 4 * PSPVRAMSize));
    var ReadBack := False;
    if Hi > Lo then
      for var Guest := Lo shr PSPPageShift to (Hi - 1) shr PSPPageShift do
      begin
        var Page := FMemory.VRAMPageAt(Cardinal(Guest shl PSPPageShift));
        if Page >= 0 then
        begin
          Pages[Page] := True;
          ReadBack := ReadBack or FDrawn[Page];
        end;
      end;
    if Pending then Inc(FStats.Syncs);
    // All preceding commands retain queue order, but only the requested
    // pages cross to the CPU. RAM texture snapshots need no GPU wait.
    Submit(ReadBack, @Pages);
    if ReadBack then
    begin
      var First := FNextSlot;
      for var I := 0 to High(FSlots) do Complete((First + I) mod Length(FSlots));
    end;
    for var Page := 0 to VRAMPages - 1 do
      if Pages[Page] and FHeld[Page] and not FDrawn[Page] then
      begin
        FHeld[Page] := False;
        FMemory.ReleaseVRAMPage(Page);
      end;
    // Submitted RAM snapshots are immutable. New uses validate unheld pages;
    // the other dirty VRAM pages stay held and authoritative on the GPU.
    FMemory.ReleaseWatches;
    for var I := 0 to FVerifiedCount - 1 do FVerified[FVerifiedList[I]] := False;
    FVerifiedCount := 0;
    FWatchedRAM := False;
    FillChar(FWatched, SizeOf(FWatched), 0);
    FillChar(FWatchedBanks, SizeOf(FWatchedBanks), 0);
  finally FSyncing := False end;
end;

procedure TGEVulkanLLEBackend.Sync;
begin
  if FSyncing then
    Exit;
  FSyncing := True;
  try
    // The CPU queue's primitives come before anything the GPU draws next.
    DrainQueue;
    if Pending then
      Inc(FStats.Syncs);
    Submit(True);
    // Oldest first.
    var First := FNextSlot;
    for var I := 0 to High(FSlots) do
      Complete((First + I) mod Length(FSlots));
    EndEpoch;
    FStateCount := 0;
    FDataSize := 0;
    FLastState := -1;
    FLastClutData := -1;
    FSnapshots.Clear;
  finally
    FSyncing := False;
  end;
end;

procedure TGEVulkanLLEBackend.CheckBatch(const Held: array of Boolean; Readback: TVulkanBuffer);
begin
  Inc(FStats.CheckedBatches);
  for var I := 0 to FCheckPrims.Count - 1 do
  begin
    var C := FCheckPrims[I];
    if C.Clut <> nil then
      C.S.Tex.Clut := @C.Clut[0];
    case C.Kind of
      KindTriangle:
        GEDrawTriangle(C.S, C.V[0], C.V[1], C.V[2]);
      KindSprite:
        GEDrawSprite(C.S, C.V[0], C.V[1]);
      KindLine:
        GEDrawLine(C.S, C.V[0], C.V[1]);
      KindPoint:
        GEDrawPoint(C.S, C.V[0]);
    end;
  end;
  var CPU := PByte(@FMemory.VRAM[0]);
  var GPU := Readback.Data;
  var Bad := 0;
  var First := -1;
  for var Page := 0 to High(Held) do
    if Held[Page] then
      for var I := Page * PageSize to Page * PageSize + PageSize - 1 do
        if CPU[I] <> GPU[I] then
        begin
          if First < 0 then
            First := I;
          Inc(Bad);
        end;
  if Bad > 0 then
  begin
    Inc(FStats.BadBatches);
    Inc(FStats.BadBytes, Bad);
    if FStats.BadBatches <= 20 then
    begin
      var A := First and not 3;
      Message(Format('gpu check: batch %d (%d prims) differs in %d bytes, first at VRAM %.6x: cpu %.8x gpu %.8x',
        [FStats.Batches, FCheckPrims.Count, Bad, First, PCardinal(CPU + A)^, PCardinal(GPU + A)^]));
    end;
  end;
end;

end.
