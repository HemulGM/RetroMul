unit PS2.GS.Gpu;

// GS compute path: sprites and triangles to 32/24/16-bit frames, with
// GS direct/palettized textures and mipmapping, disjoint frame/depth
// surfaces and no texture feedback. Other draws keep the software pipeline.
// Exact-FP64 devices rasterize constant-LOD triangles on the GPU. Other
// triangles retain host coverage/interpolation and GPU fragment shading.
// Queued draws retain their own parameters and CLUT until Sync publishes their
// writes to CPU consumers. Compute barriers order draws within each batch.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Generics.Collections, PS2.Types, PS2.GS.Raster, PS2.GS.Memory,
  RM.Vulkan.Compute;

type
  TPS2GSGpu = class(TPS2GSAccelerator)
  private const
    BatchSize = 2048;
    FragmentCapacity = 65536;
    ClusterSize = 128;
    // (uints, 16 MiB: per cluster its tile table, two words a tile, and its
    // entries, a word each.)
    TileCapacity = 4 * 1024 * 1024;
    // The most entries (a draw meeting a tile) a cluster takes: at least a
    // 2048 x 2048 draw's tiles. Phase A's results hold one cluster's: each
    // dispatch waits for the work recorded before it (TVulkanCompute), in
    // this command buffer and those submitted earlier, so every cluster
    // takes them from the start.
    ClusterEntries = 65536;
    HalfBatch = BatchSize div 2;
    HalfFragments = FragmentCapacity div 2;
    HalfTiles = TileCapacity div 2;
    LodCapacity = 1024 * 1024; // uints for LOD tables
  private type
    TPages = TPS2GSPages;
    TPush = record
      Bounds: array[0..3] of Integer;
      Slot: Cardinal;
      Mode: Cardinal;
    end;
    // The triangle kernel's (PS2.GS.Triangle.comp): a cluster's tile-aligned
    // bounds, first state slot, phase (0 A, 1 B), its table and entries in
    // the tile buffer, its first entry in the results, entries, tiles across,
    // where the coverage masks start in the results.
    TTrianglePush = record
      Bounds: array[0..3] of Integer;
      Slot, Mode, TileBase, EntryBase, ResultBase, Count, Width, MaskBase: Cardinal;
    end;
  private
    FCompute: TVulkanCompute;
    FKernel, FTriangleKernel: TVulkanKernel;
    FRAM, FState, FCoordinates, FFragments, FTiles, FResults: TVulkanBuffer;
    FDraws: Int64;
    FTexturedDraws: Int64;
    FUsed: Integer;
    FSubmissions: Int64;
    FTriangles: Int64;
    FRasterizedTriangles: Int64;
    FTriangleDispatches: Int64;
    FFragmentsUsed, FFragmentStart, FFragmentCount: Integer;
    FTriangleState: TPS2GSDraw;
    FHostClut: PWord;
    FReads, FWrites: TPages;
    FTriangleBounds: array[0..3] of Integer;
    FNativeStart, FNativeCount, FTileWordsUsed: Integer;
    // The cluster's entries so far.
    FNativeEntries: Integer;
    FNativeBounds: array[0..3] of Integer;
    FNativeRectangles: array[0..ClusterSize - 1, 0..3] of Integer;
    FNativeLayout: TPS2GSDraw;
    FNativeUsesZ: Boolean;
    FNativeReads, FNativeWrites, FNativeTextures: TPages;
    FMaskScratch: TArray<Cardinal>;
    FRecorded: Boolean;
    // Per-pixel LOD: for each LOD setting and host rounding, the first single
    // precision Q of each mip choice (pairs of Q bits and MipCode).
    FLodKeys: TDictionary<UInt64, Integer>;
    FLodTables: TArray<TArray<Cardinal>>;
    // The tables as the triangle kernel reads them (count, then the pairs),
    // each at its offset, appended as they are made.
    FLodBuffer: TVulkanBuffer;
    FLodOffsets: TArray<Cardinal>;
    FLodUsed: Cardinal;
    // The half of the state slots, fragments and tiles being filled (that of
    // the compute's command buffer; the other half's draws may be running):
    // its ends.
    FUsedEnd, FFragmentsEnd, FTileWordsEnd: Integer;
    procedure TakeHalf;
    procedure NextHalf;
    function LodTable(const D: TPS2GSDraw; Rounding: TRoundingMode): Integer;
    function LodLevels(Table: Integer; QLo, QHi: Single): Cardinal;
    function Supports(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal = $7F;
      SmallAllowed: Boolean = False): Boolean;
    procedure TrackAccess(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal);
    procedure BuildAccess(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal;
      out Reads, Writes, Textures: TPages);
    procedure FlushNative;
    procedure JoinCluster(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; const Writes, Textures: TPages);
    procedure AddToCluster(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; const Reads, Writes, Textures: TPages);
    procedure WriteState(const D: TPS2GSDraw; const V: TPS2GSVertex);
    procedure FlushFragments;
  public
    constructor Create(RAM: Pointer; Clut: PWord = nil);
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
    procedure Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single); override;
    procedure EndTriangle; override;
    property Draws: Int64 read FDraws;
    property TexturedDraws: Int64 read FTexturedDraws;
    property Submissions: Int64 read FSubmissions;
    property Triangles: Int64 read FTriangles;
    property RasterizedTriangles: Int64 read FRasterizedTriangles;
    property TriangleDispatches: Int64 read FTriangleDispatches;
  end;

var
  // Clusters with a tile meeting at least this many draws take two passes
  // (see PS2.GS.Triangle.comp; tests set it to try both).
  PS2GSTwoPhaseDraws: Integer = 8;

implementation

const
{$I shaders\PS2.GS.Sprite.inc}
{$I shaders\PS2.GS.Triangle.inc}

constructor TPS2GSGpu.Create(RAM: Pointer; Clut: PWord);
begin
  inherited Create;
  FHostClut := Clut;
  FLodKeys := TDictionary<UInt64, Integer>.Create;
  FCompute := TVulkanCompute.Create;
  FRAM := FCompute.ImportHost(RAM, PS2GSMemorySize);
  if FRAM = nil then
    raise Exception.Create('Vulkan GS needs coherent host-memory import for GS VRAM');
  FState := FCompute.CreateBuffer(BatchSize * 384 * SizeOf(Cardinal), True);
  FCoordinates := FCompute.CreateBuffer(BatchSize * 4096 * SizeOf(Integer), True);
  FFragments := FCompute.CreateBuffer(FragmentCapacity * 11 * SizeOf(Cardinal), True);
  FKernel := FCompute.CreateKernel(PS2SpriteSPIRV, 4, SizeOf(TPush));
  FCompute.Bind(FKernel, [FRAM, FState, FCoordinates, FFragments]);
  {$IFDEF CPUX64}
  // (The triangle kernel's edge functions take 64-bit integers.)
  if FCompute.ExactDouble and FCompute.Int64 then
  begin
    FTiles := FCompute.CreateBuffer(TileCapacity * SizeOf(Cardinal), True);
    FLodBuffer := FCompute.CreateBuffer(LodCapacity * SizeOf(Cardinal), True);
    // (Each entry's 64 depths and colours, then each entry's coverage mask.)
    FResults := FCompute.CreateBuffer(UInt64(ClusterEntries) * 130 * SizeOf(Cardinal), False);
    FTriangleKernel := FCompute.CreateKernel(PS2TriangleSPIRV, 6, SizeOf(TTrianglePush));
    FCompute.Bind(FTriangleKernel, [FRAM, FState, FTiles, FLodBuffer, FCoordinates, FResults]);
  end;
  {$ENDIF}
  TakeHalf;
end;

procedure TPS2GSGpu.TakeHalf;
begin
  var H := FCompute.Slot;
  FUsed := H * HalfBatch;
  FUsedEnd := FUsed + HalfBatch;
  FFragmentsUsed := H * HalfFragments;
  FFragmentsEnd := FFragmentsUsed + HalfFragments;
  FTileWordsUsed := H * HalfTiles;
  FTileWordsEnd := FTileWordsUsed + HalfTiles;
end;

// The recorded draws start; the other half is filled meanwhile. Their pages
// stay pending until Sync.
procedure TPS2GSGpu.NextHalf;
begin
  FCompute.Submit;
  if FRecorded then Inc(FSubmissions);
  FRecorded := False;
  TakeHalf;
end;

destructor TPS2GSGpu.Destroy;
begin
  Sync;
  FLodKeys.Free;
  FCompute.Free;
  inherited;
end;

procedure TPS2GSGpu.Sync;
begin
  if not FPending then Exit;
  FlushNative;
  FCompute.Finish;
  FPending := False;
  TakeHalf;
  FRecorded := False;
  FillChar(FReads, SizeOf(FReads), 0);
  FillChar(FWrites, SizeOf(FWrites), 0);
  Inc(FSubmissions);
end;

// Same truncation and finite-range handling as the software sprite path.
function TextureCoordinate(D: Double): Integer;
begin
  if not (D > -$1000000) then Exit(-$1000000);
  if D > $1000000 then Exit($1000000);
  Result := Trunc(D);
end;

// The same discrete choices as TPS2GSDrawer.Texel: choose on the host so
// conversion/rounding of LOD never depends on GPU floating-point controls.
function MipCode(const D: TPS2GSDraw; Lod: Single): Cardinal;
begin
  if not D.TME then Exit(0);
  var L0 := 0;
  var L1 := 0;
  var Weight := 0;
  var Linear := D.Linear;
  if D.UseLod and (Lod >= 0) then
  begin
    Linear := D.MMIN in [1, 4, 5];
    if (D.MMIN >= 2) and (D.MXL > 0) then
    begin
      if D.MMIN in [2, 4] then
        L0 := Min(Trunc(Lod + 0.5), D.MXL)
      else
      begin
        L0 := Min(Trunc(Lod), D.MXL);
        if L0 < D.MXL then Weight := Round((Lod - L0) * 16);
      end;
      L1 := L0;
      if Weight > 0 then L1 := L0 + 1;
    end;
  end;
  Result := Cardinal(L0 or (L1 shl 3) or (Weight shl 6) or (Ord(Linear) shl 11));
end;

function MeetsRange(const Bits: array of Cardinal; First, Last: Integer): Boolean;
begin
  if Last - First >= 511 then
  begin
    for var K := 0 to High(Bits) do if Bits[K] <> 0 then Exit(True);
    Exit(False);
  end;
  for var P := First to Last do
    if (Bits[(P and 511) shr 5] and (Cardinal(1) shl (P and 31))) <> 0 then Exit(True);
  Result := False;
end;

procedure TPS2GSGpu.ReadPages(First, Last: Integer);
begin
  if FPending and MeetsRange(FWrites, First, Last) then Sync;
end;

procedure TPS2GSGpu.WritePages(First, Last: Integer);
begin
  if FPending and (MeetsRange(FWrites, First, Last) or MeetsRange(FReads, First, Last)) then Sync;
end;

procedure TPS2GSGpu.AccessPages(const Reads, Writes: TPS2GSPages);
begin
  if not FPending then
    Exit;
  for var K := 0 to High(Reads) do
    if ((FWrites[K] and (Reads[K] or Writes[K])) or (FReads[K] and Writes[K])) <> 0 then
    begin
      Sync;
      Exit;
    end;
end;

// The rows of a frame page: 64 in the 16-bit formats, else 32.
function FrameRows(PSM: Cardinal): Integer; inline;
begin
  if PSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] then Result := 64 else Result := 32;
end;

function Palettized(const D: TPS2GSDraw): Boolean; inline;
begin
  Result := D.TME and (D.TPSM in [PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH]);
end;

procedure TPS2GSGpu.BuildAccess(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal;
  out Reads, Writes, Textures: TPages);
begin
  FillChar(Reads, SizeOf(Reads), 0);
  FillChar(Writes, SizeOf(Writes), 0);
  FillChar(Textures, SizeOf(Textures), 0);
  // The pages of the draw's rectangle and of its textures' extents, as the
  // software path tracks them (not every page up to the last).
  AddRectPages(Writes, D.FBP, D.FBW, D.FPSM, X0, Y0, X1 - 1, Y1 - 1);
  if not D.ZMSK then AddRectPages(Writes, D.ZBP, D.FBW, D.ZPSM, X0, Y0, X1 - 1, Y1 - 1);
  if D.ZTST >= 2 then AddRectPages(Reads, D.ZBP, D.FBW, D.ZPSM, X0, Y0, X1 - 1, Y1 - 1);
  if not D.TME then Exit;
  var Last := 0;
  if D.UseLod and (D.MMIN >= 2) then Last := D.MXL;
  for var L := 0 to Last do
  begin
    if (Levels and (Cardinal(1) shl L)) = 0 then Continue;
    var BP := D.TBP; var BW := D.TBW;
    if L > 0 then begin BP := D.LevelTBP[L]; BW := D.LevelTBW[L]; end;
    var W := Max(1, (1 shl D.TW) shr L);
    var H := Max(1, (1 shl D.TH) shr L);
    if D.WMS = 2 then W := (Max(D.MINU, D.MAXU) shr L) + 1;
    if D.WMT = 2 then H := (Max(D.MINV, D.MAXV) shr L) + 1;
    if D.WMS = 3 then W := (D.MINU or D.MAXU) + 1;
    if D.WMT = 3 then H := (D.MINV or D.MAXV) + 1;
    AddRectPages(Textures, BP, BW, D.TPSM, 0, 0, W - 1, H - 1);
  end;
  for var K := 0 to 15 do Reads[K] := Reads[K] or Textures[K];
end;

procedure TPS2GSGpu.TrackAccess(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal);
var
  Reads, Writes, Textures: TPages;
begin
  BuildAccess(D, X0, Y0, X1, Y1, Levels, Reads, Writes, Textures);
  for var K := 0 to 15 do
  begin
    FReads[K] := FReads[K] or Reads[K];
    FWrites[K] := FWrites[K] or Writes[K];
  end;
  Inc(FRevision);
end;

// Before a draw joins the cluster: the cluster dispatched first when the
// draw differs in layout, reads what it writes or writes what it reads, or
// it is full; a new one started in the state slot the draw takes (FUsed).
procedure TPS2GSGpu.JoinCluster(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; const Writes, Textures: TPages);
begin
  if FNativeCount > 0 then
  begin
    var DrawTiles := ((X1 + 7) shr 3 - X0 shr 3) * ((Y1 + 7) shr 3 - Y0 shr 3);
    var Conflict := (FNativeCount = ClusterSize) or (FNativeEntries + DrawTiles > ClusterEntries) or
      (D.FBP <> FNativeLayout.FBP) or (D.FBW <> FNativeLayout.FBW) or (D.FPSM <> FNativeLayout.FPSM) or
      (D.ZBP <> FNativeLayout.ZBP) or (D.ZPSM <> FNativeLayout.ZPSM);
    for var K := 0 to 15 do
      Conflict := Conflict or ((Textures[K] and FNativeWrites[K]) <> 0) or
        ((Writes[K] and FNativeTextures[K]) <> 0);
    if not Conflict and (FNativeUsesZ or not D.ZMSK or (D.ZTST <> 1)) then
    begin
      // A draw not using depth may extend colour over another draw's
      // depth rows. Per-pixel ordering is only enough for disjoint layouts.
      var MX := Max(FNativeBounds[2], X1);
      var MY := Max(FNativeBounds[3], Y1);
      var F0 := D.FBP div 32;
      var F1 := (D.FBP + 31) div 32 + Cardinal((MY - 1) div FrameRows(D.FPSM)) * D.FBW + Cardinal((MX - 1) div 64);
      var Z0 := D.ZBP div 32;
      var Z1 := (D.ZBP + 31) div 32 + Cardinal((MY - 1) div 32) * D.FBW + Cardinal((MX - 1) div 64);
      Conflict := (F1 >= 512) or (Z1 >= 512) or ((F1 >= Z0) and (Z1 >= F0));
    end;
    if Conflict then FlushNative;
  end;
  if FUsed = FUsedEnd then
  begin
    FlushNative;
    NextHalf;
  end;
  if FNativeCount = 0 then
  begin
    FNativeStart := FUsed;
    FNativeLayout := D;
    FNativeUsesZ := False;
    FNativeBounds[0] := X0; FNativeBounds[1] := Y0;
    FNativeBounds[2] := X1; FNativeBounds[3] := Y1;
    FillChar(FNativeReads, SizeOf(FNativeReads), 0);
    FillChar(FNativeWrites, SizeOf(FNativeWrites), 0);
    FillChar(FNativeTextures, SizeOf(FNativeTextures), 0);
  end;
end;

// The draw in state slot FUsed joins the cluster.
procedure TPS2GSGpu.AddToCluster(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; const Reads, Writes, Textures: TPages);
begin
  FNativeRectangles[FNativeCount, 0] := X0; FNativeRectangles[FNativeCount, 1] := Y0;
  FNativeRectangles[FNativeCount, 2] := X1; FNativeRectangles[FNativeCount, 3] := Y1;
  FNativeBounds[0] := Min(FNativeBounds[0], X0); FNativeBounds[1] := Min(FNativeBounds[1], Y0);
  FNativeBounds[2] := Max(FNativeBounds[2], X1); FNativeBounds[3] := Max(FNativeBounds[3], Y1);
  for var K := 0 to 15 do
  begin
    FReads[K] := FReads[K] or Reads[K]; FWrites[K] := FWrites[K] or Writes[K];
    FNativeReads[K] := FNativeReads[K] or Reads[K];
    FNativeWrites[K] := FNativeWrites[K] or Writes[K];
    FNativeTextures[K] := FNativeTextures[K] or Textures[K];
  end;
  Inc(FNativeCount);
  Inc(FNativeEntries, ((X1 + 7) shr 3 - X0 shr 3) * ((Y1 + 7) shr 3 - Y0 shr 3));
  FNativeUsesZ := FNativeUsesZ or not D.ZMSK or (D.ZTST <> 1);
  Inc(FRevision);
  Inc(FUsed);
  FPending := True;
end;

procedure TPS2GSGpu.FlushNative;
begin
  if FNativeCount = 0 then Exit;
  var TX0 := FNativeBounds[0] shr 3;
  var TY0 := FNativeBounds[1] shr 3;
  var TX1 := (FNativeBounds[2] + 7) shr 3;
  var TY1 := (FNativeBounds[3] + 7) shr 3;
  var Width := TX1 - TX0;
  var Height := TY1 - TY0;
  var Tiles := Width * Height;
  var Entries := FNativeEntries;
  var Words := Tiles * 2 + Entries;
  if FTileWordsUsed + Words > FTileWordsEnd then
  begin
    // Start the recorded work, not this not-yet-dispatched cluster: its
    // parameter/palette snapshots move to the start of the other half.
    var Start := FNativeStart;
    NextHalf;
    Move((PCardinal(FState.Data) + Start * 384)^, (PCardinal(FState.Data) + FUsed * 384)^,
      FNativeCount * 384 * SizeOf(Cardinal));
    // (And the clustered sprites' texture coordinates.)
    for var I := 0 to FNativeCount - 1 do
      if (PCardinal(FState.Data) + (FUsed + I) * 384)[58] = 0 then
        Move((PInteger(FCoordinates.Data) + (Start + I) * 4096)^, (PInteger(FCoordinates.Data) + (FUsed + I) * 4096)^,
          4096 * SizeOf(Integer));
    FNativeStart := FUsed;
    Inc(FUsed, FNativeCount);
  end;
  // The tile table (first entry, count) and the entries (tile | draw shl
  // 16), each tile's in draw order: counted, placed, then filled draw by
  // draw. Built in cached CPU memory, then streamed once to the mapped
  // buffer (read/modify/write there is needlessly expensive).
  if Length(FMaskScratch) < Words then SetLength(FMaskScratch, Words);
  FillChar(FMaskScratch[0], Tiles * 2 * SizeOf(Cardinal), 0);
  for var I := 0 to FNativeCount - 1 do
    for var Y := FNativeRectangles[I, 1] shr 3 to (FNativeRectangles[I, 3] + 7) shr 3 - 1 do
      for var X := FNativeRectangles[I, 0] shr 3 to (FNativeRectangles[I, 2] + 7) shr 3 - 1 do
        Inc(FMaskScratch[((Y - TY0) * Width + X - TX0) * 2 + 1]);
  var First: Cardinal := 0;
  var Most: Cardinal := 0;
  for var T := 0 to Tiles - 1 do
  begin
    if FMaskScratch[T * 2 + 1] > Most then Most := FMaskScratch[T * 2 + 1];
    FMaskScratch[T * 2] := First;
    Inc(First, FMaskScratch[T * 2 + 1]);
    FMaskScratch[T * 2 + 1] := 0;
  end;
  if Integer(First) <> Entries then
    raise Exception.Create('GS GPU: cluster entries miscounted');
  for var I := 0 to FNativeCount - 1 do
    for var Y := FNativeRectangles[I, 1] shr 3 to (FNativeRectangles[I, 3] + 7) shr 3 - 1 do
      for var X := FNativeRectangles[I, 0] shr 3 to (FNativeRectangles[I, 2] + 7) shr 3 - 1 do
      begin
        var T := (Y - TY0) * Width + X - TX0;
        FMaskScratch[Tiles * 2 + Integer(FMaskScratch[T * 2] + FMaskScratch[T * 2 + 1])] :=
          Cardinal(T) or (Cardinal(I) shl 16);
        Inc(FMaskScratch[T * 2 + 1]);
      end;
  Move(FMaskScratch[0], (PCardinal(FTiles.Data) + FTileWordsUsed)^, Words * SizeOf(Cardinal));
  var Push := Default(TTrianglePush);
  Push.Bounds[0] := TX0 * 8; Push.Bounds[1] := TY0 * 8;
  Push.Bounds[2] := TX1 * 8; Push.Bounds[3] := TY1 * 8;
  Push.Slot := Cardinal(FNativeStart);
  Push.TileBase := Cardinal(FTileWordsUsed);
  Push.EntryBase := Cardinal(FTileWordsUsed + Tiles * 2);
  Push.ResultBase := 0;
  Push.Count := Cardinal(Entries);
  Push.Width := Cardinal(Width);
  Push.MaskBase := ClusterEntries * 128;
  // Phase A over the entries (rows of 32768 workgroups), then phase B over
  // the tiles; where no tile meets many draws, both in one pass over the
  // tiles (the serial work per pixel is short then, and no results are kept).
  var TwoPhases := Integer(Most) >= PS2GSTwoPhaseDraws;
  if TwoPhases then
  begin
    Push.Mode := 0;
    FCompute.Launch(FTriangleKernel, Push, Cardinal(Min(Entries, 32768)), Cardinal((Entries + 32767) div 32768), 1);
    Push.Mode := 1;
  end
  else
    Push.Mode := 2;
  FCompute.Launch(FTriangleKernel, Push, Cardinal(Width), Cardinal(Height), 1);
  FRecorded := True;
  Inc(FTriangleDispatches);
  Inc(FTileWordsUsed, Words);
  FNativeCount := 0;
  FNativeEntries := 0;
end;

function TPS2GSGpu.Supports(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal;
  SmallAllowed: Boolean): Boolean;
begin
  Result := False;
  if not (D.FPSM in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S, PSMZ16, PSMZ16S]) or
    not (D.ZPSM in [PSMZ32, PSMZ24]) or (X0 < 0) or (Y0 < 0) or
    (X1 <= X0) or (Y1 <= Y0) or (X1 > 2048) or (Y1 > 2048) then Exit;
  // One invocation must own each pixel (a 16-bit one, half of a word):
  // reject zero stride, row aliases, VRAM wrapping and colour/depth
  // overlap. Bounds are deliberately broad.
  if (D.FBW = 0) or (Cardinal(X1) > D.FBW * 64) then Exit;
  var F0 := D.FBP div 32;
  var F1 := (D.FBP + 31) div 32 + Cardinal((Y1 - 1) div FrameRows(D.FPSM)) * D.FBW + Cardinal((X1 - 1) div 64);
  var Z0 := D.ZBP div 32;
  var Z1 := (D.ZBP + 31) div 32 + Cardinal((Y1 - 1) div 32) * D.FBW + Cardinal((X1 - 1) div 64);
  if F1 >= 512 then Exit;
  if not D.ZMSK or (D.ZTST <> 1) then
    if (Z1 >= 512) or ((F1 >= Z0) and (Z1 >= F0)) then Exit;
  var Overlap := False;
  if D.TME then
  begin
    if (D.TW > 10) or (D.TH > 10) or (D.MXL < 0) or (D.MXL > 6) or
      not (D.TPSM in [PSMCT32, PSMCT24, PSMCT16, PSMCT16S, PSMZ32, PSMZ24, PSMZ16, PSMZ16S,
        PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH]) then Exit;
    if (D.TPSM in [PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH]) and (FHostClut = nil) then Exit;
    var Last := 0;
    if D.UseLod and (D.MMIN >= 2) then Last := D.MXL;
    for var L := 0 to Last do
    begin
      if (Levels and (Cardinal(1) shl L)) = 0 then Continue;
      var BP := D.TBP; var BW := D.TBW;
      if L > 0 then begin BP := D.LevelTBP[L]; BW := D.LevelTBW[L]; end;
      var W := Max(1, (1 shl D.TW) shr L);
      var H := Max(1, (1 shl D.TH) shr L);
      if D.WMS = 2 then W := (Max(D.MINU, D.MAXU) shr L) + 1;
      if D.WMT = 2 then H := (Max(D.MINV, D.MAXV) shr L) + 1;
      if D.WMS = 3 then W := (D.MINU or D.MAXU) + 1;
      if D.WMT = 3 then H := (D.MINV or D.MAXV) + 1;
      var PW := 64; var PH := 32;
      if D.TPSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] then PH := 64;
      if D.TPSM in [PSMT8, PSMT4] then
      begin
        PW := 128; PH := 64; BW := (BW + 1) shr 1;
        if D.TPSM = PSMT4 then PH := 128;
      end;
      var T0 := BP div 32;
      var T1 := (BP + 31) div 32 + Cardinal((H - 1) div PH) * BW + Cardinal((W - 1) div PW);
      // (Past the end of VRAM a texture continues at its start, as on the
      // host; the range comparisons do not wrap.)
      Overlap := Overlap or (T1 >= 512) or ((T1 >= F0) and (F1 >= T0)) or (not D.ZMSK and (T1 >= Z0) and (Z1 >= T0));
    end;
  end;
  // Small draws cost more to submit than to draw on the host.
  if not SmallAllowed and (Int64(X1 - X0) * (Y1 - Y0) < 4096) then Exit;
  // Texture pages that may meet the targets': only where no pixel reads a
  // texel another pixel of the draw writes (OverlapAllowed). Earlier and
  // later draws on those pages are kept apart by the clusters' page checks
  // and barriers.
  if Overlap and not (Assigned(FOverlapAllowed) and FOverlapAllowed) then Exit;
  Result := True;
end;

procedure TPS2GSGpu.WriteState(const D: TPS2GSDraw; const V: TPS2GSVertex);
begin
  var P := PCardinal(FState.Data) + FUsed * 384;
  P[0] := D.FBP; P[1] := D.FBW; P[2] := D.FPSM; P[3] := D.FBMSK;
  P[4] := D.ZBP; P[5] := D.ZPSM; P[6] := Ord(D.ZMSK);
  P[7] := 1;
  if D.ATE then P[7] := Cardinal(D.ATST);
  P[8] := Cardinal(D.AREF); P[9] := Cardinal(D.AFAIL);
  P[10] := Ord(D.DATE); P[11] := Ord(D.DATM); P[12] := Cardinal(D.ZTST);
  P[13] := Cardinal(D.BlendA); P[14] := Cardinal(D.BlendB); P[15] := Cardinal(D.BlendC);
  P[16] := Cardinal(D.BlendD); P[17] := Cardinal(D.BlendFix);
  P[18] := Ord(D.PABE); P[19] := Ord(D.FBA); P[20] := Ord(D.ColClamp);
  P[21] := Ord(D.ABE); P[22] := Ord(D.FGE);
  P[23] := Cardinal(D.FogR); P[24] := Cardinal(D.FogG); P[25] := Cardinal(D.FogB);
  P[26] := Cardinal(V.R); P[27] := Cardinal(V.G); P[28] := Cardinal(V.B);
  P[29] := Cardinal(V.A); P[30] := Cardinal(V.F); P[31] := V.Z;
  P[47] := Ord(D.TME);
  if D.TME then
  begin
    P[32] := D.TBP; P[33] := D.TBW; P[34] := D.TPSM;
    P[35] := Cardinal(1 shl D.TW); P[36] := Cardinal(1 shl D.TH);
    P[37] := Cardinal(D.WMS); P[38] := Cardinal(D.WMT);
    P[39] := Cardinal(D.MINU); P[40] := Cardinal(D.MAXU);
    P[41] := Cardinal(D.MINV); P[42] := Cardinal(D.MAXV);
    P[43] := Cardinal(D.TFX); P[44] := Ord(D.TCC);
    P[45] := Cardinal(D.TA0); P[46] := Ord(D.AEM); P[48] := Ord(D.Linear);
    P[49] := Ord(D.Clut32); P[50] := Cardinal(D.ClutOffset); P[51] := Cardinal(D.TA1);
    for var L := 0 to 6 do
    begin
      P[64 + L] := D.LevelTBP[L]; P[71 + L] := D.LevelTBW[L];
    end;
    P[64] := D.TBP; P[71] := D.TBW;
    if D.TPSM in [PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH] then
      Move(FHostClut^, P[128], 512 * SizeOf(Word));
  end;
end;

function TPS2GSGpu.Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer; Lod: Single): Boolean;
var
  Reads, Writes, Textures: TPages;
begin
  Result := False;
  var Mip := MipCode(D, Lod);
  var Levels := (Cardinal(1) shl (Mip and 7)) or (Cardinal(1) shl ((Mip shr 3) and 7));
  // Where the triangle kernel runs, sprites join its ordered clusters: a
  // small one then costs no dispatch of its own.
  var Clustered := FTriangleKernel <> nil;
  if not Supports(D, X0, Y0, X1, Y1, Levels, Clustered) then Exit;
  if Assigned(FBeforeDraw) or Clustered then
    BuildAccess(D, X0, Y0, X1, Y1, Levels, Reads, Writes, Textures);
  if Assigned(FBeforeDraw) and not FBeforeDraw(Reads, Writes, Palettized(D), Int64(X1 - X0) * (Y1 - Y0)) then
    Exit;
  if Clustered then
    JoinCluster(D, X0, Y0, X1, Y1, Writes, Textures)
  else
  begin
    FlushNative;
    if FUsed = FUsedEnd then NextHalf;
  end;
  WriteState(D, V);
  var P := PCardinal(FState.Data) + FUsed * 384;
  P[52] := Mip;
  if D.TME then
  begin
    // Keep the CPU's arithmetic and rounding for UV/STQ interpolation.
    // The GPU samples these integer coordinates, not an approximate float
    // reconstruction. A sprite needs only one U per column and V per row.
    var U0, U1, TV0, TV1: Double;
    if D.FST then
    begin
      U0 := V0.U; U1 := V.U; TV0 := V0.V; TV1 := V.V;
    end
    else
    begin
      var Q0 := V0.Q;
      var Q1 := V.Q;
      if Q0 = 0 then Q0 := 1;
      if Q1 = 0 then Q1 := 1;
      U0 := V0.S / Q0 * (1 shl D.TW) * 16;
      U1 := V.S / Q1 * (1 shl D.TW) * 16;
      TV0 := V0.T / Q0 * (1 shl D.TH) * 16;
      TV1 := V.T / Q1 * (1 shl D.TH) * 16;
    end;
    var DUDX := 0.0;
    var DVDY := 0.0;
    if V.X <> V0.X then DUDX := (U1 - U0) / (V.X - V0.X) * 16;
    if V.Y <> V0.Y then DVDY := (TV1 - TV0) / (V.Y - V0.Y) * 16;
    var UStart := U0 + (X0 * 16 - V0.X) * DUDX / 16;
    var Coords := PInteger(FCoordinates.Data) + FUsed * 4096;
    for var X := X0 to X1 - 1 do Coords[X - X0] := TextureCoordinate(UStart + (X - X0) * DUDX);
    for var Y := Y0 to Y1 - 1 do Coords[2048 + Y - Y0] := TextureCoordinate(TV0 + (Y * 16 - V0.Y) * DVDY / 16);
  end;
  if Clustered then
  begin
    // (The kernel's sprite: p[58] 0, its rectangle at p[60..63].)
    P[58] := 0;
    P[60] := Cardinal(X0); P[61] := Cardinal(Y0); P[62] := Cardinal(X1); P[63] := Cardinal(Y1);
    AddToCluster(D, X0, Y0, X1, Y1, Reads, Writes, Textures);
    Inc(FDraws);
    if D.TME then Inc(FTexturedDraws);
    Exit(True);
  end;
  var Push: TPush;
  Push.Bounds[0] := X0; Push.Bounds[1] := Y0; Push.Bounds[2] := X1; Push.Bounds[3] := Y1;
  Push.Slot := Cardinal(FUsed);
  Push.Mode := 0;
  FCompute.Launch(FKernel, Push, Cardinal((X1-X0+7) div 8), Cardinal((Y1-Y0+7) div 8), 1);
  FRecorded := True;
  Inc(FUsed);
  FPending := True;
  Inc(FDraws);
  TrackAccess(D, X0, Y0, X1, Y1, Levels);
  if D.TME then Inc(FTexturedDraws);
  Result := True;
end;
// Pixels' Q to MipCode as the host decides (PixelLod, then Texel's choice in
// MipCode), for the rounding the host runs with now: the LOD never rises as
// Q does (System.Math.Log2 of a Single is monotone, checked over every Single
// for both roundings), so each choice holds one run of single-precision Qs.
// -1 when there would be too many runs for a slot.
function TPS2GSGpu.LodTable(const D: TPS2GSDraw; Rounding: TRoundingMode): Integer;

  function CodeAt(Bits: Cardinal): Cardinal;
  begin
    Result := MipCode(D, PixelLod(D, PSingle(@Bits)^));
  end;

begin
  var Key := UInt64(PCardinal(@D.K)^) or (UInt64(D.LShift and 3) shl 32) or (UInt64(D.MMIN and 7) shl 34) or
    (UInt64(D.MXL and 7) shl 37) or (UInt64(Ord(D.Linear)) shl 40) or (UInt64(Ord(Rounding)) shl 41);
  if FLodKeys.TryGetValue(Key, Result) then
    Exit;
  var Entries: TArray<Cardinal>;
  var Count := 0;
  var Start: Cardinal := 0;
  Result := -1;
  while True do
  begin
    if Count = 2000 then
      Exit;
    var Code := CodeAt(Start);
    SetLength(Entries, Count * 2 + 2);
    Entries[Count * 2] := Start;
    Entries[Count * 2 + 1] := Code;
    Inc(Count);
    // The last Single with this choice, up to +infinity.
    var Lo := Start;
    var Hi: Cardinal := $7F800000;
    if CodeAt(Hi) = Code then
      Break;
    while Hi - Lo > 1 do
    begin
      var Mid := Lo + (Hi - Lo) div 2;
      if CodeAt(Mid) = Code then
        Lo := Mid
      else
        Hi := Mid;
    end;
    Start := Hi;
  end;
  var Size := Cardinal(Length(Entries) + 1);
  if FLodUsed + Size > LodCapacity then
  begin
    // Full: queued draws may read any table; they finish, the tables go.
    Sync;
    FLodKeys.Clear;
    FLodTables := nil;
    FLodOffsets := nil;
    FLodUsed := 0;
  end;
  var T := PCardinal(FLodBuffer.Data) + FLodUsed;
  T[0] := Cardinal(Count);
  Move(Entries[0], T[1], Length(Entries) * SizeOf(Cardinal));
  Result := Length(FLodTables);
  FLodTables := FLodTables + [Entries];
  FLodOffsets := FLodOffsets + [FLodUsed];
  Inc(FLodUsed, Size);
  FLodKeys.Add(Key, Result);
end;

// The levels a table's choices take for single-precision Q in QLo..QHi
// (positive).
function TPS2GSGpu.LodLevels(Table: Integer; QLo, QHi: Single): Cardinal;
begin
  Result := 0;
  // (The host's copy: the buffer's memory may be slow to read.)
  var E := PCardinal(@FLodTables[Table][0]);
  var Count := Length(FLodTables[Table]) div 2;
  var Lo := PCardinal(@QLo)^;
  var Hi := PCardinal(@QHi)^;
  if Lo > 0 then Dec(Lo);
  if Hi < $7F800000 then Inc(Hi);
  // The run holding Lo, then each run up to the one holding Hi.
  var A := 0;
  var B := Count - 1;
  while A < B do
  begin
    var M := (A + B + 1) shr 1;
    if E[M * 2] <= Lo then A := M else B := M - 1;
  end;
  while (A < Count) and (E[A * 2] <= Hi) do
  begin
    var Code := E[A * 2 + 1];
    Result := Result or (Cardinal(1) shl (Code and 7)) or (Cardinal(1) shl ((Code shr 3) and 7));
    Inc(A);
  end;
end;

function TPS2GSGpu.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;
var
  Vertices: array[0..2] of TPS2GSVertex;
  Reads, Writes, Textures: TPages;

  function FiniteNormalOrZero(const Value: Single): Boolean;
  begin
    var Bits := PCardinal(@Value)^;
    var E := Bits and $7F800000;
    Result := (E <> $7F800000) and ((E <> 0) or ((Bits and $7FFFFF) = 0));
  end;

begin
  Result := False;
  if FTriangleKernel = nil then Exit;
  var Rounding := GetRoundMode;
  if not (Rounding in [rmNearest, rmTruncate]) then Exit;
  // A per-pixel LOD takes the host's choice from a table of Q (see
  // LodTable); a constant one is chosen here.
  var Table := -1;
  var Mip: Cardinal := 0;
  var Levels: Cardinal;
  if D.TME and D.UseLod and not D.LCM and not D.FST then
  begin
    if not ((V0.Q > 0) and (V1.Q > 0) and (V2.Q > 0)) then Exit;
    Table := LodTable(D, Rounding);
    if Table < 0 then Exit;
    Levels := LodLevels(Table, Min(V0.Q, Min(V1.Q, V2.Q)), Max(V0.Q, Max(V1.Q, V2.Q)));
  end
  else
  begin
    Mip := MipCode(D, D.K);
    Levels := (Cardinal(1) shl (Mip and 7)) or (Cardinal(1) shl ((Mip shr 3) and 7));
  end;
  if not Supports(D, X0, Y0, X1, Y1, Levels, True) then Exit;
  Vertices[0] := V0; Vertices[1] := V1; Vertices[2] := V2;
  for var K := 0 to 2 do
  begin
    var V := Vertices[K];
    if (V.X < -65535) or (V.X > 65535) or (V.Y < -65535) or (V.Y > 65535) then Exit;
    // (Q of one sign: the host's S/Q and T/Q arithmetic is the same either
    // way; per-pixel LOD, from |Q|, took positive ones only above.)
    if D.TME and not D.FST then
      if not FiniteNormalOrZero(V.S) or not FiniteNormalOrZero(V.T) or
        not FiniteNormalOrZero(V.Q) or (V.Q = 0) or ((V.Q > 0) <> (V0.Q > 0)) then Exit;
  end;
  var Area := (Int64(V1.X) - V0.X) * (Int64(V2.Y) - V0.Y) -
    (Int64(V2.X) - V0.X) * (Int64(V1.Y) - V0.Y);
  if Area = 0 then Exit;
  var InvArea: Double := 1.0 / Area;
  BuildAccess(D, X0, Y0, X1, Y1, Levels, Reads, Writes, Textures);
  if Assigned(FBeforeDraw) and not FBeforeDraw(Reads, Writes, Palettized(D), Int64(X1 - X0) * (Y1 - Y0)) then Exit;
  JoinCluster(D, X0, Y0, X1, Y1, Writes, Textures);
  WriteState(D, V2);
  var P := PCardinal(FState.Data) + FUsed * 384;
  P[52] := Mip;
  P[53] := Ord(D.FST);
  P[78] := Ord(Table >= 0);
  if Table >= 0 then
    P[79] := FLodOffsets[Table];
  P[54] := Ord(D.IIP);
  P[55] := 0;
  if Rounding = rmTruncate then P[55] := 3;
  Move(InvArea, P[56], SizeOf(InvArea));
  P[58] := 1;
  if Area < 0 then P[58] := $FFFFFFFF;
  P[59] := Ord((D.ZTST >= 2) or not D.ZMSK);
  P[60] := Cardinal(X0); P[61] := Cardinal(Y0); P[62] := Cardinal(X1); P[63] := Cardinal(Y1);
  for var K := 0 to 2 do
  begin
    var V := Vertices[K];
    var W := P + 80 + K * 16;
    W[0] := Cardinal(V.X); W[1] := Cardinal(V.Y); W[2] := V.Z;
    W[3] := Cardinal(V.R); W[4] := Cardinal(V.G); W[5] := Cardinal(V.B);
    W[6] := Cardinal(V.A); W[7] := Cardinal(V.F);
    W[8] := Cardinal(V.U); W[9] := Cardinal(V.V);
    W[10] := PCardinal(@V.S)^; W[11] := PCardinal(@V.T)^; W[12] := PCardinal(@V.Q)^;
  end;
  AddToCluster(D, X0, Y0, X1, Y1, Reads, Writes, Textures);
  Inc(FTriangles);
  Inc(FRasterizedTriangles);
  Inc(FDraws);
  if D.TME then Inc(FTexturedDraws);
  Result := True;
end;

function TPS2GSGpu.BeginTriangle(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := Supports(D, X0, Y0, X1, Y1);
  if not Result then Exit;
  if Assigned(FBeforeDraw) then
  begin
    var Reads, Writes, Textures: TPages;
    BuildAccess(D, X0, Y0, X1, Y1, $7F, Reads, Writes, Textures);
    if not FBeforeDraw(Reads, Writes, Palettized(D), Int64(X1 - X0) * (Y1 - Y0)) then Exit(False);
  end;
  FlushNative;
  if FUsed = FUsedEnd then NextHalf;
  FTriangleState := D;
  FTriangleBounds[0] := X0; FTriangleBounds[1] := Y0;
  FTriangleBounds[2] := X1; FTriangleBounds[3] := Y1;
  WriteState(D, Default(TPS2GSVertex));
  FFragmentStart := FFragmentsUsed;
  FFragmentCount := 0;
  Inc(FTriangles);
  Inc(FDraws);
  if D.TME then Inc(FTexturedDraws);
end;

procedure TPS2GSGpu.FlushFragments;
begin
  if FFragmentCount = 0 then Exit;
  var Push := Default(TPush);
  Push.Bounds[0] := FFragmentStart;
  Push.Bounds[1] := FFragmentCount;
  Push.Slot := Cardinal(FUsed);
  Push.Mode := 1;
  TrackAccess(FTriangleState, FTriangleBounds[0], FTriangleBounds[1], FTriangleBounds[2], FTriangleBounds[3], $7F);
  FCompute.Launch(FKernel, Push, Cardinal((FFragmentCount + 63) div 64), 1, 1);
  FRecorded := True;
  Inc(FUsed);
  FPending := True;
  FFragmentCount := 0;
end;

procedure TPS2GSGpu.Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single);
begin
  if FFragmentsUsed = FFragmentsEnd then
  begin
    FlushFragments;
    NextHalf;
    WriteState(FTriangleState, Default(TPS2GSVertex));
    FFragmentStart := FFragmentsUsed;
  end;
  // The software edge walker emits each covered pixel exactly once. It
  // supplies the already rounded attributes, avoiding GPU float differences.
  var P := PCardinal(FFragments.Data) + FFragmentsUsed * 11;
  P[0] := Cardinal(X); P[1] := Cardinal(Y); P[2] := Z;
  P[3] := Cardinal(R); P[4] := Cardinal(G); P[5] := Cardinal(B);
  P[6] := Cardinal(A); P[7] := Cardinal(F);
  PInteger(@P[8])^ := U;
  PInteger(@P[9])^ := V;
  P[10] := MipCode(FTriangleState, Lod);
  Inc(FFragmentsUsed);
  Inc(FFragmentCount);
end;

procedure TPS2GSGpu.EndTriangle;
begin
  FlushFragments;
end;

end.
