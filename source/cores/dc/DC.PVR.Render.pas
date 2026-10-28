unit DC.PVR.Render;

// Software CORE (ISP/TSP) for PowerVR2: walks the region array, renders each
// 32x32 tile from the decoded display lists and writes it to the framebuffer.
// Per tile: opaque and punch-through lists with depth test and deferred
// shading, opaque modifier volumes, then translucent lists either presorted
// or sorted per pixel back to front (depth peeling), translucent modifier
// volumes, fog, blending and the framebuffer packing with optional dither.
// Tiles are independent; a render prepares textures first and triangles
// (on a worker, when the tiles run there) before the tiles, so tiles can run
// on worker threads.
// References: Marcus Comstedt's PowerVR pages, KallistiOS pvr headers.
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}
{$TYPEDADDRESS ON}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Classes, System.SyncObjs, DC.Types,
  DC.Memory, DC.PVR, DC.PVR.TA, DC.PVR.Texture;

const
  TileSize = 32;

type
  // A triangle ready for rasterization: edge and plane equations in pixel
  // space (pixel centres at +0.5).
  TRenderTri = record
    Poly: Integer;
    V0, V1, V2: Integer;          // vertex indices in the context
    EA, EB, EC: array[0..2] of Single;
    ZA, ZB, ZC: Single;           // 1/w plane: Z = ZC + ZA * (x - X0) + ZB * (y - Y0)
    X0, Y0: Single;
    InvArea: Single;
    MinX, MinY, MaxX, MaxY: Integer;
    // Modifier volume membership.
    Volume: Integer;
    // Edges owning the samples on them (left and top edges).
    TopLeft: array[0..2] of Boolean;
    // Mipmap level of the texture and of the second parameter set's.
    Level, Level1: SmallInt;
    // For RowSpan, per edge with EA <> 0: the edge's X at Y = 0 and its
    // slope (EA * X + EB * Y + EC = 0).
    SpanBase, SpanSlope: array[0..2] of Double;
  end;

  PRenderTri = ^TRenderTri;

  TRenderPoly = record
    Texture, Texture1: TPVRTexture;
    Shadow: Boolean;              // affected by modifier volumes
    Translucent, PunchThrough: Boolean;
  end;

  PRenderPoly = ^TRenderPoly;

  // A Gouraud vertex's base and offset colour channels (B, G, R, A) as
  // floating point.
  TChannels = array[0..3] of Single;

  TVertexChannels = record
    Base, Offset: TChannels;
  end;

  PVertexChannels = ^TVertexChannels;

  TTileBuffers = record
    Depth: array[0..TileSize * TileSize - 1] of Single;
    Tag: array[0..TileSize * TileSize - 1] of Integer;   // triangle index, -1 background
    Color: array[0..TileSize * TileSize - 1] of Cardinal;
    Modified: array[0..TileSize * TileSize - 1] of Byte; // modifier volume result
    Stencil: array[0..TileSize * TileSize - 1] of Byte;
    Fresh: array[0..TileSize * TileSize - 1] of Byte;    // shaded in this entry
    PeelDepth: array[0..TileSize * TileSize - 1] of Single;
    PeelTag: array[0..TileSize * TileSize - 1] of Integer;
    BestDepth: array[0..TileSize * TileSize - 1] of Single;
    BestTag: array[0..TileSize * TileSize - 1] of Integer;
  end;

  PTileBuffers = ^TTileBuffers;

  // Translucent fragments of a tile, linked per pixel in submission order,
  // for sorting by depth.
  TFragmentBuffer = record
    Head, Tail: array[0..TileSize * TileSize - 1] of Integer;
    Z: TArray<Single>;
    Tag, Next: TArray<Integer>;
    Count: Integer;
    SortZ: TArray<Single>;
    SortTag: TArray<Integer>;
  end;

  PFragmentBuffer = ^TFragmentBuffer;

  TRegionEntry = record
    Control: Cardinal;
    Lists: array[0..4] of Cardinal;
    Pass: Integer;
  end;

  TDCRenderer = class;

  // Renders groups of region entries on its own tile buffers.
  TDCRenderWorker = class(TThread)
  private
    FOwner: TDCRenderer;
    FSlot: Integer;
    FStart: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TDCRenderer; Slot: Integer);
    destructor Destroy; override;
  end;

  TDCRenderer = class
  private
    FMemory: TDCMemory;
    FPVR: TDCPVR;
    FTA: TDCTA;
    FTextures: TPVRTextureCache;
    FContext: TPVRContext;
    FTris: TArray<TRenderTri>;
    FTriCount: Integer;
    FPolys: TArray<TRenderPoly>;
    // Per vertex of Gouraud strips.
    FChannels: TArray<TVertexChannels>;
    // Triangles per tile and list: Bins[tile][list] -> indices.
    FBinStart: TArray<Integer>;
    FBinCount: TArray<Integer>;
    FBinItems: TArray<Integer>;
    FTilesX, FTilesY: Integer;
    FEntries: TArray<TRegionEntry>;
    FBackground: Cardinal;
    FBackgroundDepth: Single;
    FPalette: array[0..1023] of Cardinal;
    FPaletteGen: Cardinal;
    FPaletteHash: UInt64;
    FFogTable: array[0..127] of Word;
    FFogScale: Double;
    FFogColorRAM, FFogColorVert: Cardinal;
    // Registers the tile workers use, as they were at the render start.
    FShadowScale, FPTAlphaRef, FFBCtrl, FFBStride, FFBBase, FFBClipX, FFBClipY: Cardinal;
    FBusy: Boolean;
    FBuffers: TArray<TTileBuffers>;
    FFragments: TArray<TFragmentBuffer>;
    // Region entries grouped per tile (work items, in any order on the
    // workers) and whether an entry starts its tile from the background.
    FEntryTile, FItemStart, FItemEntries: TArray<Integer>;
    FEntryReset: TArray<Boolean>;
    FItemCount: Integer;
    FNextGroup: Integer;
    FPending: Integer;
    FWorkers: TArray<TDCRenderWorker>;
    FDone: TEvent;
    FThreads: Integer;
    // Closing instruction of each modifier volume (1 inside, 2 outside).
    FVolumeMode: TArray<Byte>;
    FScaleX: Integer;
    FCullValue: Single;
    // Triangles still to set up for the current render (by the first thread
    // rendering tiles).
    FSetupPending: Boolean;
    FSetupLock: TCriticalSection;
    procedure SetThreads(Value: Integer);
    procedure Setup;
    procedure EnsureSetup;
    procedure RenderGroups(Slot: Integer);
    procedure PrepareEntries;
    procedure RenderEntry(N, Slot: Integer);
    procedure Prepare;
    procedure AddTriangle(Poly: Integer; I0, I1, I2: Integer; Volume: Integer);
    procedure Bin;
    procedure ReadRegions;
    procedure ReadBackground;
    function ShadePixel(Tri: Integer; PX, PY: Single; Modified: Boolean; Dest: Cardinal; out Alpha: Integer): Cardinal;
    function Fog(Color: Cardinal; TSP: Cardinal; Z: Single; const V: TPVRVertex): Cardinal;
    procedure RasterOpaque(B: PTileBuffers; TileX, TileY, List, Pass: Integer);
    procedure ApplyVolumes(B: PTileBuffers; TileX, TileY, List, Pass: Integer; Translucent: Boolean);
    procedure ShadeOpaque(B: PTileBuffers; TileX, TileY: Integer);
    procedure RasterTranslucent(B: PTileBuffers; F: PFragmentBuffer; TileX, TileY, Pass: Integer; Presort: Boolean);
    procedure WriteTile(B: PTileBuffers; TileX, TileY: Integer);
    function DepthPass(Mode: Cardinal; Z, Stored: Single): Boolean; inline;
  public
    PolygonsRendered: Integer;
    constructor Create(Memory: TDCMemory; PVR: TDCPVR; TA: TDCTA);
    destructor Destroy; override;
    // Renders the scene selected by PARAM_BASE/REGION_BASE; returns the
    // number of tiles drawn.
    function Render: Integer;
    // Tiles of the current render for worker threads (0..TileCount-1).
    procedure RenderTiles(First, Count, Slot: Integer);
    // Every tile of the current render, on Threads threads (the caller's
    // included). Tiles are independent, so the result does not depend on it.
    procedure RenderAll;
    // Starts the tiles on the worker threads and returns True, or renders
    // them at once (no workers, a single tile, render to texture). Until
    // Wait the workers write FramebufferFirst..FramebufferLast-1 (linear
    // VRAM) and read Context; nothing else.
    function RenderAsync: Boolean;
    procedure Wait;
    function FramebufferFirst: Cardinal;
    function FramebufferLast: Cardinal;
    property Busy: Boolean read FBusy;
    property Context: TPVRContext read FContext;
    function TileCount: Integer;
    property Threads: Integer read FThreads write SetThreads;
  end;

implementation

const
  PVRISPBackgndD = $088;
  PVRISPBackgndT = $08C;
  PVRFPUShadScale = $074;
  PVRFPUCullVal = $078;
  PVRFPUParamCfg = $07C;
  PVRHalfOffset = $080;
  PVRFogColRAM = $0B0;
  PVRFogColVert = $0B4;
  PVRFogDensity = $0B8;
  PVRTextControl = $0E4;
  PVRPTAlphaRef = $11C;
  PVRScalerCtlReg = $0F4;
  PVRFogTable = $200;
  PVRPalette = $1000;
  DitherMatrix: array[0..15] of Integer = (0, 4, 1, 5, 6, 2, 7, 3, 1, 5, 0, 4, 7, 3, 6, 2);

function ARGB(A, R, G, B: Integer): Cardinal; inline;
begin
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
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

function Lerp8(A, B, T: Integer): Integer; inline;
begin
  Result := A + ((B - A) * T + 127) div 255;
end;

// X div 255 for X >= 0 (unsigned: no sign correction).
function Div255(X: Integer): Integer; inline;
begin
  Result := Integer(Cardinal(X) div 255);
end;

{ TDCRenderer }

constructor TDCRenderer.Create(Memory: TDCMemory; PVR: TDCPVR; TA: TDCTA);
begin
  inherited Create;
  FMemory := Memory;
  FPVR := PVR;
  FTA := TA;
  FTextures := TPVRTextureCache.Create(Memory);
  FDone := TEvent.Create(nil, False, False, '');
  FSetupLock := TCriticalSection.Create;
  SetThreads(Min(8, Max(1, TThread.ProcessorCount - 1)));
end;

destructor TDCRenderer.Destroy;
begin
  SetThreads(1);
  FSetupLock.Free;
  FDone.Free;
  FTextures.Free;
  inherited;
end;

procedure TDCRenderer.SetThreads(Value: Integer);
begin
  Wait;
  Value := EnsureRange(Value, 1, 32);
  for var W in FWorkers do
  begin
    W.Terminate;
    W.FStart.SetEvent;
    W.WaitFor;
    W.Free;
  end;
  FWorkers := nil;
  FThreads := Value;
  SetLength(FBuffers, Value);
  SetLength(FFragments, Value);
  SetLength(FWorkers, Value - 1);
  for var I := 0 to Value - 2 do
    FWorkers[I] := TDCRenderWorker.Create(Self, I + 1);
end;

{ TDCRenderWorker }

constructor TDCRenderWorker.Create(Owner: TDCRenderer; Slot: Integer);
begin
  FOwner := Owner;
  FSlot := Slot;
  FStart := TEvent.Create(nil, False, False, '');
  inherited Create(False);
end;

destructor TDCRenderWorker.Destroy;
begin
  inherited;
  FStart.Free;
end;

procedure TDCRenderWorker.Execute;
begin
  // The rasterizer's floating point: nearest rounding, no traps.
  SetExceptionMask(exAllArithmeticExceptions);
  SetRoundMode(rmNearest);
  while True do
  begin
    FStart.WaitFor(INFINITE);
    if Terminated then
      Break;
    FOwner.RenderGroups(FSlot);
    if TInterlocked.Decrement(FOwner.FPending) = 0 then
      FOwner.FDone.SetEvent;
  end;
end;

procedure TDCRenderer.EnsureSetup;
begin
  FSetupLock.Enter;
  try
    if FSetupPending then
    begin
      FSetupPending := False;
      Setup;
    end;
  finally
    FSetupLock.Leave;
  end;
end;

procedure TDCRenderer.RenderGroups(Slot: Integer);
begin
  EnsureSetup;
  while True do
  begin
    var G := TInterlocked.Increment(FNextGroup) - 1;
    if G >= FItemCount then
      Break;
    for var K := FItemStart[G] to FItemStart[G + 1] - 1 do
      RenderEntry(FItemEntries[K], Slot);
  end;
end;

function TDCRenderer.FramebufferFirst: Cardinal;
begin
  Result := FFBBase and $7FFFFF;
end;

function TDCRenderer.FramebufferLast: Cardinal;
begin
  Result := FramebufferFirst + FFBStride * Cardinal(FTilesY * TileSize);
end;

function TDCRenderer.RenderAsync: Boolean;
begin
  Wait;
  if (Length(FWorkers) = 0) or (FItemCount < 2) or ((FFBBase and $1000000) <> 0) then
  begin
    RenderAll;
    Exit(False);
  end;
  FNextGroup := 0;
  FPending := Length(FWorkers);
  FDone.ResetEvent;
  FBusy := True;
  for var W in FWorkers do
    W.FStart.SetEvent;
  Result := True;
end;

procedure TDCRenderer.Wait;
begin
  if not FBusy then
    Exit;
  FDone.WaitFor(INFINITE);
  FBusy := False;
end;

procedure TDCRenderer.RenderAll;
begin
  if (Length(FWorkers) = 0) or (FItemCount < 2) then
  begin
    EnsureSetup;
    RenderTiles(0, Length(FEntries), 0);
    Exit;
  end;
  FNextGroup := 0;
  FPending := Length(FWorkers);
  FDone.ResetEvent;
  for var W in FWorkers do
    W.FStart.SetEvent;
  RenderGroups(0);
  FDone.WaitFor(INFINITE);
end;

function TDCRenderer.TileCount: Integer;
begin
  Result := Length(FEntries);
end;

// Mipmap level from the texel footprint of one pixel (constant over a
// triangle: the screen derivatives of the texture coordinates).
function MipLevel(const T: TRenderTri; const VA, VB, VC: TPVRVertex; Texture: TPVRTexture; TSP: Cardinal): Integer;
begin
  Result := 0;
  if (Texture = nil) or (Texture.Levels <= 1) then
    Exit;
  var DUX := (VA.U * T.EA[0] + VB.U * T.EA[1] - VC.U * (T.EA[0] + T.EA[1])) * T.InvArea * Texture.Width;
  var DVY := (VA.V * T.EB[0] + VB.V * T.EB[1] - VC.V * (T.EB[0] + T.EB[1])) * T.InvArea * Texture.Height;
  var Footprint := Max(Abs(DUX), Abs(DVY));
  var DAdjust := ((TSP shr 8) and 15) / 4.0;
  if DAdjust = 0 then
    DAdjust := 1;
  Footprint := Footprint * DAdjust;
  if Footprint > 1 then
    Result := EnsureRange(Floor(Log2(Footprint)), 0, Texture.Levels - 1);
end;

procedure TDCRenderer.AddTriangle(Poly: Integer; I0, I1, I2: Integer; Volume: Integer);
begin
  var V := FContext.Vertices;
  var X0 := V[I0].X;
  var Y0 := V[I0].Y;
  var X1 := V[I1].X;
  var Y1 := V[I1].Y;
  var X2 := V[I2].X;
  var Y2 := V[I2].Y;
  if FScaleX = 2 then
  begin
    X0 := X0 * 2;
    X1 := X1 * 2;
    X2 := X2 * 2;
  end;
  var Area := (X1 - X0) * (Y2 - Y0) - (X2 - X0) * (Y1 - Y0);
  if IsNan(Area) or (Abs(Area) < 1E-12) then
    Exit;
  var P := FContext.Polys[Poly];
  // Culling: 2 culls counter-clockwise (screen, y down), 3 clockwise.
  if P.Kind <> PolyModifier then
  begin
    var Cull := (P.ISP shr 27) and 3;
    if (Cull = 1) and (Abs(Area) < FCullValue) then
      Exit;
    if (Cull = 2) and (Area < 0) then
      Exit;
    if (Cull = 3) and (Area > 0) then
      Exit;
  end;
  if FTriCount >= Length(FTris) then
    SetLength(FTris, Max(4096, Length(FTris) * 2));
  var T: PRenderTri := @FTris[FTriCount];
  T.Poly := Poly;
  T.V0 := I0;
  T.V1 := I1;
  T.V2 := I2;
  T.Volume := Volume;
  // Orient edges so inside is positive.
  var S: Single := 1;
  if Area < 0 then
    S := -1;
  T.EA[0] := (Y1 - Y2) * S;
  T.EB[0] := (X2 - X1) * S;
  T.EC[0] := (X1 * Y2 - X2 * Y1) * S;
  T.EA[1] := (Y2 - Y0) * S;
  T.EB[1] := (X0 - X2) * S;
  T.EC[1] := (X2 * Y0 - X0 * Y2) * S;
  T.EA[2] := (Y0 - Y1) * S;
  T.EB[2] := (X1 - X0) * S;
  T.EC[2] := (X0 * Y1 - X1 * Y0) * S;
  for var K := 0 to 2 do
  begin
    T.TopLeft[K] := (T.EA[K] > 0) or ((T.EA[K] = 0) and (T.EB[K] > 0));
    if T.EA[K] <> 0 then
    begin
      T.SpanBase[K] := -T.EC[K] / Double(T.EA[K]);
      T.SpanSlope[K] := -T.EB[K] / Double(T.EA[K]);
    end;
  end;
  T.InvArea := 1 / Abs(Area);
  // Z plane from the barycentric weights.
  var Z0 := V[I0].Z;
  var Z1 := V[I1].Z;
  var Z2 := V[I2].Z;
  // Relative to vertex 0, so a constant depth stays exact.
  T.ZA := ((Z1 - Z0) * (Y2 - Y0) - (Z2 - Z0) * (Y1 - Y0)) / Area;
  T.ZB := ((Z2 - Z0) * (X1 - X0) - (Z1 - Z0) * (X2 - X0)) / Area;
  T.ZC := Z0;
  T.X0 := X0;
  T.Y0 := Y0;
  var MinXF := Min(X0, Min(X1, X2));
  var MaxXF := Max(X0, Max(X1, X2));
  var MinYF := Min(Y0, Min(Y1, Y2));
  var MaxYF := Max(Y0, Max(Y1, Y2));
  var Width := FTilesX * TileSize;
  var Height := FTilesY * TileSize;
  if (MaxXF < 0) or (MaxYF < 0) or (MinXF > Width) or (MinYF > Height) then
    Exit;
  T.MinX := EnsureRange(Floor(MinXF), 0, Width - 1);
  T.MaxX := EnsureRange(Ceil(MaxXF), 0, Width - 1);
  T.MinY := EnsureRange(Floor(MinYF), 0, Height - 1);
  T.MaxY := EnsureRange(Ceil(MaxYF), 0, Height - 1);
  T.Level := MipLevel(T^, V[I0], V[I1], V[I2], FPolys[Poly].Texture, P.TSP);
  T.Level1 := MipLevel(T^, V[I0], V[I1], V[I2], FPolys[Poly].Texture1, P.TSP1);
  Inc(FTriCount);
end;

procedure TDCRenderer.Prepare;
begin
  var Mark := FTextures.Clock;
  FTextures.NewScene;
  SetLength(FPolys, FContext.PolyCount);
  var Stride := Integer(FPVR.R[PVRTextControl shr 2] and 31) * 32;
  var PalFormat := FPVR.R[PVRPalRamCtrl shr 2] and 3;
  for var I := 0 to FContext.PolyCount - 1 do
  begin
    var P := FContext.Polys[I];
    var RP := Default(TRenderPoly);
    RP.Translucent := P.List = TAListTranslucent;
    RP.PunchThrough := P.List = TAListPunchThrough;
    RP.Shadow := (P.PCW and $80) <> 0;
    if (P.Kind <> PolyModifier) and ((P.ISP and $02000000) <> 0) then
    begin
      RP.Texture := FTextures.Get(P.TCW, P.TSP, FPalette, PalFormat, FPaletteGen, Stride);
      if P.TwoVolume then
        RP.Texture1 := FTextures.Get(P.TCW1, P.TSP1, FPalette, PalFormat, FPaletteGen, Stride);
    end;
    FPolys[I] := RP;
    if (P.Kind = PolyStrip) and ((P.ISP and $00800000) <> 0) then
    begin
      if Length(FChannels) < Length(FContext.Vertices) then
        SetLength(FChannels, Length(FContext.Vertices));
      for var K := P.First to P.First + P.Count - 1 do
        for var S := 0 to 3 do
        begin
          FChannels[K].Base[S] := (FContext.Vertices[K].Base shr (S * 8)) and $FF;
          FChannels[K].Offset[S] := (FContext.Vertices[K].Offset shr (S * 8)) and $FF;
        end;
    end;
  end;
  FTextures.Trim(4096, Mark);
end;

procedure TDCRenderer.Setup;
begin
  FTriCount := 0;
  var Volume := 0;
  for var I := 0 to FContext.PolyCount - 1 do
  begin
    var P: PPVRPoly := @FContext.Polys[I];
    case P.Kind of
      PolyStrip:
        // Every other strip triangle is reversed to keep one winding;
        // the newest vertex stays last (flat shading uses it).
        for var K := 2 to P.Count - 1 do
          if Odd(K) then
            AddTriangle(I, P.First + K - 1, P.First + K - 2, P.First + K, 0)
          else
            AddTriangle(I, P.First + K - 2, P.First + K - 1, P.First + K, 0);
      PolySprite:
        begin
          AddTriangle(I, P.First, P.First + 1, P.First + 2, 0);
          AddTriangle(I, P.First, P.First + 2, P.First + 3, 0);
        end;
      PolyModifier:
        begin
          AddTriangle(I, P.First, P.First + 1, P.First + 2, Volume);
          if P.VolumeEnd <> 0 then
          begin
            if Volume >= Length(FVolumeMode) then
              SetLength(FVolumeMode, Volume * 2 + 16);
            FVolumeMode[Volume] := P.VolumeEnd;
            Inc(Volume);
          end;
        end;
    end;
  end;
  Bin;
end;

procedure TDCRenderer.Bin;
begin
  // Counting sort of triangles into (tile, list) bins, in submission order.
  var Tiles := FTilesX * FTilesY;
  SetLength(FBinCount, Tiles * 5);
  SetLength(FBinStart, Tiles * 5 + 1);
  FillChar(FBinCount[0], Length(FBinCount) * SizeOf(Integer), 0);
  for var I := 0 to FTriCount - 1 do
  begin
    var T: PRenderTri := @FTris[I];
    var List := FContext.Polys[T.Poly].List;
    for var TY := T.MinY div TileSize to T.MaxY div TileSize do
      for var TX := T.MinX div TileSize to T.MaxX div TileSize do
        Inc(FBinCount[(TY * FTilesX + TX) * 5 + List]);
  end;
  var Sum := 0;
  for var I := 0 to High(FBinCount) do
  begin
    FBinStart[I] := Sum;
    Inc(Sum, FBinCount[I]);
    FBinCount[I] := 0;
  end;
  FBinStart[High(FBinStart)] := Sum;
  SetLength(FBinItems, Sum);
  for var I := 0 to FTriCount - 1 do
  begin
    var T: PRenderTri := @FTris[I];
    var List := FContext.Polys[T.Poly].List;
    for var TY := T.MinY div TileSize to T.MaxY div TileSize do
      for var TX := T.MinX div TileSize to T.MaxX div TileSize do
      begin
        var Bin := (TY * FTilesX + TX) * 5 + List;
        FBinItems[FBinStart[Bin] + FBinCount[Bin]] := I;
        Inc(FBinCount[Bin]);
      end;
  end;
end;

procedure TDCRenderer.ReadRegions;
begin
  // Region array (32-bit VRAM view): control word then five list pointers,
  // or six with FPU_PARAM_CFG bit 21. Repeated tiles are further passes.
  SetLength(FEntries, 0);
  var Address := FPVR.R[PVRRegionBase shr 2] and $7FFFFC;
  var Words := 6;
  if (FPVR.R[PVRFPUParamCfg shr 2] and $200000) <> 0 then
    Words := 6;
  var Seen: TArray<Integer>;
  SetLength(Seen, 64 * 64);
  var Count := 0;
  for var Guard := 0 to 64 * 64 * 4 - 1 do
  begin
    var Control := FMemory.VRAMRead32(Address);
    var E: TRegionEntry;
    E.Control := Control;
    for var L := 0 to 4 do
      E.Lists[L] := FMemory.VRAMRead32(Address + Cardinal(4 + L * 4));
    var TX := Integer((Control shr 2) and $3F);
    var TY := Integer((Control shr 8) and $3F);
    // Entries without lists (such as KallistiOS's initial tile) are not passes.
    E.Pass := Seen[TY * 64 + TX];
    var HasLists := False;
    for var L := 0 to 4 do
      if (E.Lists[L] and $80000000) = 0 then
        HasLists := True;
    if HasLists then
      Inc(Seen[TY * 64 + TX]);
    if Count >= Length(FEntries) then
      SetLength(FEntries, Count * 2 + 64);
    FEntries[Count] := E;
    Inc(Count);
    Inc(Address, Cardinal(Words) * 4);
    if (Control and $80000000) <> 0 then
      Break;
  end;
  SetLength(FEntries, Count);
end;

procedure TDCRenderer.ReadBackground;
begin
  // ISP_BACKGND_T: parameter word offset (bits 23..3) from PARAM_BASE. The
  // ISP, TSP and TCW words precede three vertices; the plane takes the colour
  // of the first, after X, Y, Z and the texture coordinates (one word when
  // packed as 16 bits).
  var Tag := FPVR.R[PVRISPBackgndT shr 2];
  var Base := (FPVR.R[PVRParamBase shr 2] and $F00000) + ((Tag shr 3) and $1FFFFF) * 4;
  var ISP := FMemory.VRAMRead32(Base);
  var ColorWord := 3;
  if (ISP and $02000000) <> 0 then
  begin
    Inc(ColorWord, 2);
    if (ISP and $00400000) <> 0 then
      Dec(ColorWord);
  end;
  FBackground := FMemory.VRAMRead32(Base + 12 + Cardinal(ColorWord) * 4);
  FBackgroundDepth := PSingle(@FPVR.R[PVRISPBackgndD shr 2])^;
end;

{$Q-}{$R-}
function HashStep(Hash: UInt64; Value: Cardinal): UInt64;
begin
  Result := Hash * UInt64(1099511628211) + Value;
end;
{$IFDEF DC_CHECKED}{$Q+}{$R+}{$ENDIF}

function TDCRenderer.Render: Integer;
begin
  PolygonsRendered := 0;
  FContext := FTA.Find(FPVR.R[PVRParamBase shr 2] and $7FFFFF);
  // Palette and fog table snapshots.
  var Hash: UInt64 := FPVR.R[PVRPalRamCtrl shr 2];
  for var I := 0 to 1023 do
  begin
    FPalette[I] := FPVR.R[(PVRPalette shr 2) + I];
    Hash := HashStep(Hash, FPalette[I]);
  end;
  if Hash <> FPaletteHash then
  begin
    FPaletteHash := Hash;
    Inc(FPaletteGen);
  end;
  for var I := 0 to 127 do
    FFogTable[I] := Word(FPVR.R[(PVRFogTable shr 2) + I]);
  // FOG_DENSITY: an 8-bit mantissa (1.7 fixed point) and a signed exponent.
  var Density := FPVR.R[PVRFogDensity shr 2];
  FFogScale := ((Density shr 8) and $FF) / 128.0 * IntPower(2, ShortInt(Density and $FF));
  FFogColorRAM := FPVR.R[PVRFogColRAM shr 2];
  FFogColorVert := FPVR.R[PVRFogColVert shr 2];
  FShadowScale := FPVR.R[PVRFPUShadScale shr 2];
  FPTAlphaRef := FPVR.R[PVRPTAlphaRef shr 2];
  FFBCtrl := FPVR.R[PVRFBWCtrl shr 2];
  FFBStride := (FPVR.R[PVRFBWLineStride shr 2] and $1FF) * 8;
  FFBBase := FPVR.R[PVRFBWSOF1 shr 2] and $1FFFFFF;
  FFBClipX := FPVR.R[PVRFBXClip shr 2];
  FFBClipY := FPVR.R[PVRFBYClip shr 2];
  FCullValue := PSingle(@FPVR.R[PVRFPUCullVal shr 2])^;
  FScaleX := 1;
  if (FPVR.R[PVRScalerCtlReg shr 2] and $10000) <> 0 then
    FScaleX := 2;
  ReadRegions;
  // Lists built for another parameter base (TA_ISP_BASE <> PARAM_BASE): by
  // where the regions point, when that context is newer than one built for
  // this base.
  for var E in FEntries do
  begin
    var Found := False;
    for var L := 0 to 4 do
      if (E.Lists[L] and $80000000) = 0 then
      begin
        var ByList := FTA.FindByObjectList(E.Lists[L] and $7FFFFC);
        if (ByList <> nil) and ((FContext = nil) or (ByList.Used > FContext.Used)) then
          FContext := ByList;
        Found := True;
        Break;
      end;
    if Found then
      Break;
  end;
  ReadBackground;
  var MaxX := 0;
  var MaxY := 0;
  for var E in FEntries do
  begin
    MaxX := Max(MaxX, Integer((E.Control shr 2) and $3F));
    MaxY := Max(MaxY, Integer((E.Control shr 8) and $3F));
  end;
  FTilesX := MaxX + 1;
  FTilesY := MaxY + 1;
  PrepareEntries;
  FSetupPending := False;
  if FContext <> nil then
  begin
    Prepare;
    FSetupPending := True;
    PolygonsRendered := FContext.PolyCount;
  end
  else
    FTriCount := 0;
  Result := Length(FEntries);
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
// Conversions as Round and Floor give them under the rasterizer's nearest
// rounding, without calls into the runtime.
function RoundInt(X: Double): Int64;
asm
        cvtsd2si rax, xmm0
end;

function FloorInt(X: Double): Integer;
asm
        cvttsd2si eax, xmm0
        cvtsi2sd xmm1, eax
        comisd  xmm1, xmm0
        jbe     @Done
        dec     eax

@Done:
end;
{$ELSE}

function RoundInt(X: Double): Int64; inline;
begin
  Result := Round(X);
end;

function FloorInt(X: Double): Integer; inline;
begin
  Result := Floor(X);
end;
{$ENDIF}

{$IFDEF CPUX64}

const
  RoundMagic: Single = 12582912; // 1.5 * 2^23: sums round to integers
  ChannelLow: Single = 0.5;
  ChannelHigh: Single = 255;

// Clamp255(RoundInt(X)); between 0.5 and 255 by single-precision addition,
// which rounds as the conversion does (the current rounding mode): the sum
// is 1.5 * 2^23 + the integer, which its low mantissa bits hold.
function ChannelRound(X: Single): Cardinal; inline;
begin
  if (X > ChannelLow) and (X < ChannelHigh) then
  begin
    var S: Single := X + RoundMagic;
    Result := (PCardinal(@S)^ and $7FFFFF) - $400000;
  end
  else
    Result := Cardinal(Clamp255(RoundInt(X)));
end;
{$ELSE}

function ChannelRound(X: Single): Cardinal; inline;
begin
  Result := Cardinal(Clamp255(RoundInt(X)));
end;
{$ENDIF}

// Perspective-correct Gouraud colour from the vertices' channels.

function GouraudColor(const A, B, C: TChannels; P0, P1, P2: Single): Cardinal; inline;
begin
  // (Locals: inlined, ChannelRound would evaluate an expression per use.)
  var X0: Single := A[0] * P0 + B[0] * P1 + C[0] * P2;
  var X1: Single := A[1] * P0 + B[1] * P1 + C[1] * P2;
  var X2: Single := A[2] * P0 + B[2] * P1 + C[2] * P2;
  var X3: Single := A[3] * P0 + B[3] * P1 + C[3] * P2;
  Result := ChannelRound(X0) or (ChannelRound(X1) shl 8) or (ChannelRound(X2) shl 16) or (ChannelRound(X3) shl 24);
end;

function IsNaNSingle(const V: Single): Boolean; inline;
begin
  Result := (PCardinal(@V)^ and $7FFFFFFF) > $7F800000;
end;

function IsNaNDouble(const V: Double): Boolean; inline;
begin
  Result := (PUInt64(@V)^ and $7FFFFFFFFFFFFFFF) > $7FF0000000000000;
end;

// A sample on an edge belongs to the triangle only for left/top edges, so
// triangles sharing an edge cover each pixel once. The terms that depend on
// the row only (EB * PY per edge, ZB * (PY - Y0)) are computed per row.
type
  TCoverRow = record
    BY: array[0..2] of Single;
    ZY: Single;
  end;

const
  SingleZero: Single = 0;

function CoverRow(const T: TRenderTri; PY: Single): TCoverRow; inline;
begin
  Result.BY[0] := T.EB[0] * PY;
  Result.BY[1] := T.EB[1] * PY;
  Result.BY[2] := T.EB[2] * PY;
  Result.ZY := T.ZB * (PY - T.Y0);
end;

function CoversRow(const T: TRenderTri; const R: TCoverRow; PX: Single; var Z: Single): Boolean; inline;
begin
  Result := False;
  var E: Single := T.EA[0] * PX + R.BY[0] + T.EC[0];
  if (E < SingleZero) or ((E = SingleZero) and not T.TopLeft[0]) then
    Exit;
  E := T.EA[1] * PX + R.BY[1] + T.EC[1];
  if (E < SingleZero) or ((E = SingleZero) and not T.TopLeft[1]) then
    Exit;
  E := T.EA[2] * PX + R.BY[2] + T.EC[2];
  if (E < SingleZero) or ((E = SingleZero) and not T.TopLeft[2]) then
    Exit;
  Result := True;
  Z := T.ZC + T.ZA * (PX - T.X0) + R.ZY;
end;

// Conservative range of tile columns X0..X1 whose sample centres can be
// inside the triangle on the row at PY (Left: the tile's first column);
// coverage is still tested exactly per sample. The margin, 1 + (|EB * PY| +
// |EC|) * 1E-6 / |EA|, exceeds the rounding of the single-precision edge
// functions. Narrow ranges are left to the per-sample tests.
function RowSpan(const T: TRenderTri; PY: Single; Left: Integer; var X0, X1: Integer): Boolean;
begin
  if X1 - X0 < 4 then
    Exit(True);
  for var K := 0 to 2 do
  begin
    if T.EA[K] = 0 then
    begin
      var Magnitude := Abs(Double(T.EB[K]) * PY) + Abs(Double(T.EC[K]));
      var C := Double(T.EB[K]) * PY + T.EC[K];
      if C < -(Magnitude * 1E-6 + 1E-30) then
        Exit(False);
      Continue;
    end;
    var Along := T.SpanSlope[K] * PY;
    var Margin := 1 + (Abs(Along) + Abs(T.SpanBase[K])) * 1E-6;
    var Bound := Along + T.SpanBase[K] - Left - 0.5;
    // Within X0..X1 (0..TileSize-1) where rounded.
    if T.EA[K] > 0 then
    begin
      Bound := Bound - Margin;
      if Bound > X1 then
        Exit(False);
      if Bound > X0 then
        X0 := FloorInt(Bound);
    end
    else
    begin
      Bound := Bound + Margin;
      if Bound < X0 then
        Exit(False);
      if Bound < X1 then
        X1 := -FloorInt(-Bound);
    end;
  end;
  Result := X0 <= X1;
end;

function TDCRenderer.DepthPass(Mode: Cardinal; Z, Stored: Single): Boolean;
begin
  case Mode of
    0:
      Result := False;
    1:
      Result := Z < Stored;
    2:
      Result := Z = Stored;
    3:
      Result := Z <= Stored;
    4:
      Result := Z > Stored;
    5:
      Result := Z <> Stored;
    6:
      Result := Z >= Stored;
  else
    Result := True;
  end;
end;

function TDCRenderer.Fog(Color: Cardinal; TSP: Cardinal; Z: Single; const V: TPVRVertex): Cardinal;
begin
  Result := Color;
  case (TSP shr 22) and 3 of
    0, 3:
      begin
        // Look-up table indexed by FOG_DENSITY * (1/w) on a log scale: for
        // X = 1.m * 2^E (X >= 1) the index is E * 16 plus the top four
        // mantissa bits; the bits below interpolate between the entry's
        // two values.
        var X: Double := FFogScale * Z;
        var Index := 0;
        var Fraction := 0;
        if X >= 1 then
        begin
          var Bits := PUInt64(@X)^;
          var E := Integer((Bits shr 52) and $7FF) - 1023;
          Index := E * 16 + Integer((Bits shr 48) and 15);
          if Index > 127 then
            Index := 127;
          Fraction := Integer(((Bits and UInt64($FFFFFFFFFFFF)) * UInt64(255) + UInt64($800000000000)) shr 48);
        end;
        var Entry := FFogTable[Index];
        var Factor := Lerp8(Entry shr 8, Entry and $FF, Fraction);
        var FogColor := FFogColorRAM;
        if ((TSP shr 22) and 3) = 3 then
        begin
          Result := (Cardinal(Factor) shl 24) or (FogColor and $FFFFFF);
          Exit;
        end;
        // (Lerp8 by 0 keeps the colour.)
        if Factor = 0 then
          Exit;
        Result := ARGB(Color shr 24,
          Lerp8((Color shr 16) and $FF, (FogColor shr 16) and $FF, Factor),
          Lerp8((Color shr 8) and $FF, (FogColor shr 8) and $FF, Factor),
          Lerp8(Color and $FF, FogColor and $FF, Factor));
      end;
    1:
      begin
        // Per vertex: the offset colour's alpha blends towards FOG_COL_VERT.
        var Factor := Integer(V.Offset shr 24);
        var FogColor := FFogColorVert;
        if Factor = 0 then
          Exit;
        Result := ARGB(Color shr 24,
          Lerp8((Color shr 16) and $FF, (FogColor shr 16) and $FF, Factor),
          Lerp8((Color shr 8) and $FF, (FogColor shr 8) and $FF, Factor),
          Lerp8(Color and $FF, FogColor and $FF, Factor));
      end;
  end;
end;

function WrapCoord(C, Size: Integer; Clamp, Flip: Boolean): Integer; inline;
begin
  if Clamp then
  begin
    if C < 0 then
      Exit(0);
    if C > Size - 1 then
      Exit(Size - 1);
    Exit(C);
  end;
  // Power-of-two sizes: the remainders by masking.
  if (Size and (Size - 1)) = 0 then
  begin
    if Flip then
    begin
      Result := C and (Size * 2 - 1);
      if Result >= Size then
        Result := Size * 2 - 1 - Result;
    end
    else
      Result := C and (Size - 1);
    Exit;
  end;
  if Flip then
  begin
    var Period := C mod (Size * 2);
    if Period < 0 then
      Inc(Period, Size * 2);
    if Period >= Size then
      Result := Size * 2 - 1 - Period
    else
      Result := Period;
  end
  else
  begin
    Result := C mod Size;
    if Result < 0 then
      Inc(Result, Size);
  end;
end;

function SampleTexture(T: TPVRTexture; U, V: Single; TSP: Cardinal; Level: Integer): Cardinal;
begin
  if Level >= T.Levels then
    Level := T.Levels - 1;
  var W := Max(1, T.Width shr Level);
  var H := Max(1, T.Height shr Level);
  var ClampU := (TSP and $10000) <> 0;
  var FlipU := (TSP and $40000) <> 0;
  var ClampV := (TSP and $8000) <> 0;
  var FlipV := (TSP and $20000) <> 0;
  var Texels: PCardinal := @T.Texels[T.LevelOffset[Level]];
  var FU := U * W;
  var FV := V * H;
  if IsNaNDouble(FU) or IsNaNDouble(FV) or (Abs(FU) > 1E8) or (Abs(FV) > 1E8) then
    Exit(T.Texels[0]);
  if ((TSP shr 13) and 3) = 0 then
    Exit(Texels[WrapCoord(FloorInt(FV), H, ClampV, FlipV) * W + WrapCoord(FloorInt(FU), W, ClampU, FlipU)]);
  // Bilinear (trilinear passes are treated as bilinear on one level).
  FU := FU - 0.5;
  FV := FV - 0.5;
  // Texel and weight from one rounding: X0 = Floor(FU), FX = Round((FU - X0)
  // * 256) except that FX = 256 becomes X0 + 1, FX = 0, the same blend.
  // (Bits 8..39 of the 64-bit product hold the integer part.)
  var NU := RoundInt(FU * 256);
  var NV := RoundInt(FV * 256);
  var X0 := Integer(NU shr 8);
  var Y0 := Integer(NV shr 8);
  var FX := Integer(NU and 255);
  var FY := Integer(NV and 255);
  var XA := WrapCoord(X0, W, ClampU, FlipU);
  var XB := WrapCoord(X0 + 1, W, ClampU, FlipU);
  var YA := WrapCoord(Y0, H, ClampV, FlipV) * W;
  var YB := WrapCoord(Y0 + 1, H, ClampV, FlipV) * W;
  var C00 := Texels[YA + XA];
  var C10 := Texels[YA + XB];
  var C01 := Texels[YB + XA];
  var C11 := Texels[YB + XB];
  // Per channel (A * (256 - FY) + B * FY + 32768) shr 16 of the row blends
  // A, B = C0 * (256 - FX) + C1 * FX (at most 255 * 256): two channels at a
  // time, 16-bit lanes for the rows, 32-bit lanes for the columns.
  var GX := Cardinal(256 - FX);
  var GY := UInt64(256 - FY);
  var AE := (C00 and $00FF00FF) * GX + (C10 and $00FF00FF) * Cardinal(FX);
  var AO := ((C00 shr 8) and $00FF00FF) * GX + ((C10 shr 8) and $00FF00FF) * Cardinal(FX);
  var BE := (C01 and $00FF00FF) * GX + (C11 and $00FF00FF) * Cardinal(FX);
  var BO := ((C01 shr 8) and $00FF00FF) * GX + ((C11 shr 8) and $00FF00FF) * Cardinal(FX);
  var E := ((UInt64(AE and $FFFF) or (UInt64(AE shr 16) shl 32)) * GY +
    (UInt64(BE and $FFFF) or (UInt64(BE shr 16) shl 32)) * UInt64(FY) + UInt64($0000800000008000));
  var O := ((UInt64(AO and $FFFF) or (UInt64(AO shr 16) shl 32)) * GY +
    (UInt64(BO and $FFFF) or (UInt64(BO shr 16) shl 32)) * UInt64(FY) + UInt64($0000800000008000));
  Result := Cardinal((E shr 16) and $FF) or Cardinal((E shr 32) and $FF0000) or
    (Cardinal((O shr 16) and $FF) shl 8) or (Cardinal((O shr 32) and $FF0000) shl 8);
end;

function TDCRenderer.ShadePixel(Tri: Integer; PX, PY: Single; Modified: Boolean; Dest: Cardinal; out Alpha: Integer): Cardinal;
begin
  var T: PRenderTri := @FTris[Tri];
  var P: PPVRPoly := @FContext.Polys[T.Poly];
  var RP: PRenderPoly := @FPolys[T.Poly];
  var Vs: PPVRVertex := @FContext.Vertices[0];
  var VA: PPVRVertex := @Vs[T.V0];
  var VB: PPVRVertex := @Vs[T.V1];
  var VC: PPVRVertex := @Vs[T.V2];
  // Perspective-correct barycentrics from screen weights and 1/w.
  var W0 := (T.EA[0] * PX + T.EB[0] * PY + T.EC[0]) * T.InvArea;
  var W1 := (T.EA[1] * PX + T.EB[1] * PY + T.EC[1]) * T.InvArea;
  var W2 := 1 - W0 - W1;
  var Z := W0 * VA.Z + W1 * VB.Z + W2 * VC.Z;
  var P0, P1, P2: Single;
  if (Z <> 0) and not IsNaNDouble(Z) and (VA.Z > 0) and (VB.Z > 0) and (VC.Z > 0) then
  begin
    P0 := W0 * VA.Z / Z;
    P1 := W1 * VB.Z / Z;
    P2 := W2 * VC.Z / Z;
  end
  else
  begin
    P0 := W0;
    P1 := W1;
    P2 := W2;
  end;
  // Second parameter set inside a modifier volume (two-volume polygons).
  var UseSecond := Modified and RP.Shadow and P.TwoVolume;
  var TSP := P.TSP;
  var Texture := RP.Texture;
  if UseSecond then
  begin
    TSP := P.TSP1;
    Texture := RP.Texture1;
  end;
  var Base, Offset: Cardinal;
  var Gouraud := (P.ISP and $00800000) <> 0;
  if UseSecond then
  begin
    if Gouraud then
    begin
      Base := 0;
      Offset := 0;
      for var S := 0 to 3 do
      begin
        var Sh := S * 8;
        Base := Base or (Cardinal(Clamp255(RoundInt(((VA.Base1 shr Sh) and $FF) * P0 + ((VB.Base1 shr Sh) and $FF) * P1 +
              ((VC.Base1 shr Sh) and $FF) * P2))) shl Sh);
        Offset := Offset or (Cardinal(Clamp255(RoundInt(((VA.Offset1 shr Sh) and $FF) * P0 + ((VB.Offset1 shr Sh) and $FF) * P1 +
              ((VC.Offset1 shr Sh) and $FF) * P2))) shl Sh);
      end;
    end
    else
    begin
      Base := VC.Base1;
      Offset := VC.Offset1;
    end;
  end
  else if Gouraud and (P.Kind = PolyStrip) then
  begin
    var CA: PVertexChannels := @FChannels[T.V0];
    var CB: PVertexChannels := @FChannels[T.V1];
    var CC: PVertexChannels := @FChannels[T.V2];
    Base := GouraudColor(CA.Base, CB.Base, CC.Base, P0, P1, P2);
    Offset := GouraudColor(CA.Offset, CB.Offset, CC.Offset, P0, P1, P2);
  end
  else
  begin
    Base := VC.Base;
    Offset := VC.Offset;
  end;
  // Use Alpha (TSP bit 20) clear: the vertex colour counts as opaque; the
  // texture's alpha still takes part in the shading instruction.
  if (TSP and $100000) = 0 then
    Base := Base or $FF000000;
  var Color := Base;
  if Texture <> nil then
  begin
    var U, V: Single;
    if UseSecond then
    begin
      U := VA.U1 * P0 + VB.U1 * P1 + VC.U1 * P2;
      V := VA.V1 * P0 + VB.V1 * P1 + VC.V1 * P2;
    end
    else
    begin
      U := VA.U * P0 + VB.U * P1 + VC.U * P2;
      V := VA.V * P0 + VB.V * P1 + VC.V * P2;
    end;
    var Level: Integer := T.Level;
    if UseSecond then
      Level := T.Level1;
    var Tex := SampleTexture(Texture, U, V, TSP, Level);
    // Bump maps: texels hold an elevation S (high byte, 0..pi/2) and a
    // rotation R (low byte, 0..2pi) of the surface normal; the offset colour
    // gives K1 (alpha), K2 (red), K3 (green) and the light rotation Q (blue).
    // The intensity K1 + K2 sin S + K3 cos S cos(R - Q) becomes the alpha of
    // a white texel, and the offset colour is not added.
    var TCW := P.TCW;
    if UseSecond then
      TCW := P.TCW1;
    var Bump := ((TCW shr 27) and 7) = TexBump;
    if Bump then
    begin
      var S := ((Tex shr 8) and $FF) * (Pi / 2 / 255);
      var R := (Tex and $FF) * (2 * Pi / 255);
      var Q := (Offset and $FF) * (2 * Pi / 255);
      var I := ((Offset shr 24) + ((Offset shr 16) and $FF) * Sin(S) + ((Offset shr 8) and $FF) * Cos(S) * Cos(R - Q));
      Tex := (Cardinal(EnsureRange(Round(I), 0, 255)) shl 24) or $FFFFFF;
    end
    else if (TSP and $80000) <> 0 then
      Tex := Tex or $FF000000;
    var TA_ := Integer(Tex shr 24);
    var TR := Integer((Tex shr 16) and $FF);
    var TG := Integer((Tex shr 8) and $FF);
    var TB := Integer(Tex and $FF);
    var CA := Integer(Base shr 24);
    var CR := Integer((Base shr 16) and $FF);
    var CG := Integer((Base shr 8) and $FF);
    var CB := Integer(Base and $FF);
    var A, R, G, B: Integer;
    case (TSP shr 6) and 3 of
      0:
        begin
          R := TR;
          G := TG;
          B := TB;
          A := TA_;
        end;
      1:
        begin
          R := Div255(CR * TR + 127);
          G := Div255(CG * TG + 127);
          B := Div255(CB * TB + 127);
          A := TA_;
        end;
      2:
        begin
          R := Div255(TR * TA_ + CR * (255 - TA_) + 127);
          G := Div255(TG * TA_ + CG * (255 - TA_) + 127);
          B := Div255(TB * TA_ + CB * (255 - TA_) + 127);
          A := CA;
        end;
    else
      begin
        R := Div255(CR * TR + 127);
        G := Div255(CG * TG + 127);
        B := Div255(CB * TB + 127);
        A := Div255(CA * TA_ + 127);
      end;
    end;
    if ((P.ISP and $01000000) <> 0) and not Bump then
    begin
      R := Clamp255(R + Integer((Offset shr 16) and $FF));
      G := Clamp255(G + Integer((Offset shr 8) and $FF));
      B := Clamp255(B + Integer(Offset and $FF));
    end;
    Color := ARGB(A, R, G, B);
  end;
  // Cheap shadow: polygons with the shadow bit are darkened inside volumes.
  if Modified and RP.Shadow and not P.TwoVolume then
  begin
    var Scale := FShadowScale;
    if (Scale and $100) <> 0 then
    begin
      var F := Scale and $FF;
      Color := ARGB(Color shr 24, ((Color shr 16) and $FF) * F div 256, ((Color shr 8) and $FF) * F div 256,
        (Color and $FF) * F div 256);
    end;
  end;
  Color := Fog(Color, TSP, Z, VC^);
  Alpha := Integer(Color shr 24);
  Result := Color;
end;

procedure TDCRenderer.RasterOpaque(B: PTileBuffers; TileX, TileY, List, Pass: Integer);
begin
  var Bin := (TileY * FTilesX + TileX) * 5 + List;
  var PTRef := Integer(FPTAlphaRef and $FF);
  for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
  begin
    var Index := FBinItems[K];
    var T: PRenderTri := @FTris[Index];
    var P: PPVRPoly := @FContext.Polys[T.Poly];
    if P.Pass <> Pass then
      Continue;
    var Mode := P.ISP shr 29;
    var ZWrite := (P.ISP and $04000000) = 0;
    var X0 := Max(T.MinX - TileX * TileSize, 0);
    var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
    var Y0 := Max(T.MinY - TileY * TileSize, 0);
    var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
    for var Y := Y0 to Y1 do
    begin
      var PY: Single := TileY * TileSize + Y + 0.5;
      var SX0 := X0;
      var SX1 := X1;
      if not RowSpan(T^, PY, TileX * TileSize, SX0, SX1) then
        Continue;
      var Row := CoverRow(T^, PY);
      for var X := SX0 to SX1 do
      begin
        var PX: Single := TileX * TileSize + X + 0.5;
        var Z: Single := 0;
        if not CoversRow(T^, Row, PX, Z) then
          Continue;
        var I := Y * TileSize + X;
        // Depth equal to the background plane passes greater-than tests.
        if not DepthPass(Mode, Z, B.Depth[I]) and not ((B.Tag[I] < 0) and (Mode in [4, 6]) and (Z = B.Depth[I])) then
          Continue;
        if List = TAListPunchThrough then
        begin
          var Alpha: Integer;
          ShadePixel(Index, PX, PY, False, 0, Alpha);
          if Alpha < PTRef then
            Continue;
        end;
        if ZWrite then
          B.Depth[I] := Z;
        B.Tag[I] := Index;
        B.Fresh[I] := 1;
      end;
    end;
  end;
end;

procedure TDCRenderer.ApplyVolumes(B: PTileBuffers; TileX, TileY, List, Pass: Integer; Translucent: Boolean);
begin
  // Parity of volume faces in front of the stored depth marks pixels inside;
  // the closing triangle's instruction decides inside/outside modification.
  var Bin := (TileY * FTilesX + TileX) * 5 + List;
  if FBinCount[Bin] = 0 then
    Exit;
  // A volume closes with its last triangle, which may lie outside the tile:
  // close when the volume number changes or the bin ends.
  FillChar(B.Stencil, SizeOf(B.Stencil), 0);
  var Current := -1;
  for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] do
  begin
    var Volume := -2;
    var Index := -1;
    if K < FBinStart[Bin] + FBinCount[Bin] then
    begin
      Index := FBinItems[K];
      if FContext.Polys[FTris[Index].Poly].Pass <> Pass then
        Continue;
      Volume := FTris[Index].Volume;
    end;
    if (Current >= 0) and (Volume <> Current) then
    begin
      var Mode := 0;
      if Current < Length(FVolumeMode) then
        Mode := FVolumeMode[Current];
      for var I := 0 to TileSize * TileSize - 1 do
      begin
        var Inside := B.Stencil[I] <> 0;
        if ((Mode = 1) and Inside) or ((Mode = 2) and not Inside) then
          B.Modified[I] := 1;
      end;
      FillChar(B.Stencil, SizeOf(B.Stencil), 0);
    end;
    Current := Volume;
    if Index < 0 then
      Break;
    var T: PRenderTri := @FTris[Index];
    var X0 := Max(T.MinX - TileX * TileSize, 0);
    var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
    var Y0 := Max(T.MinY - TileY * TileSize, 0);
    var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
    for var Y := Y0 to Y1 do
    begin
      var SX0 := X0;
      var SX1 := X1;
      if not RowSpan(T^, TileY * TileSize + Y + 0.5, TileX * TileSize, SX0, SX1) then
        Continue;
      var Row := CoverRow(T^, TileY * TileSize + Y + 0.5);
      for var X := SX0 to SX1 do
      begin
        var Z: Single := 0;
        var I := Y * TileSize + X;
        if CoversRow(T^, Row, TileX * TileSize + X + 0.5, Z) and (Z > B.Depth[I]) then
          B.Stencil[I] := B.Stencil[I] xor 1;
      end;
    end;
  end;
end;

procedure TDCRenderer.ShadeOpaque(B: PTileBuffers; TileX, TileY: Integer);
begin
  for var Y := 0 to TileSize - 1 do
    for var X := 0 to TileSize - 1 do
    begin
      var I := Y * TileSize + X;
      if B.Fresh[I] = 0 then
        Continue;
      B.Fresh[I] := 0;
      var Tag := B.Tag[I];
      if Tag < 0 then
      begin
        B.Color[I] := FBackground;
        Continue;
      end;
      var Alpha: Integer;
      B.Color[I] := ShadePixel(Tag, TileX * TileSize + X + 0.5, TileY * TileSize + Y + 0.5, B.Modified[I] <> 0, B.Color[I], Alpha);
    end;
end;

function BlendFactor(Instr: Cardinal; Src, Dst: Cardinal; Channel: Integer; Other: Cardinal): Integer; inline;
begin
  case Instr of
    0:
      Result := 0;
    1:
      Result := 255;
    2:
      Result := Integer((Other shr Channel) and $FF);
    3:
      Result := 255 - Integer((Other shr Channel) and $FF);
    4:
      Result := Integer(Src shr 24);
    5:
      Result := 255 - Integer(Src shr 24);
    6:
      Result := Integer(Dst shr 24);
  else
    Result := 255 - Integer(Dst shr 24);
  end;
end;

function BlendChannel(Src, Dst: Cardinal; Sh, FS, FD: Integer): Cardinal; inline;
begin
  var V := Div255(Integer((Src shr Sh) and $FF) * FS + Integer((Dst shr Sh) and $FF) * FD + 127);
  if V > 255 then
    V := 255;
  Result := Cardinal(V) shl Sh;
end;

function Blend(Src, Dst, TSP: Cardinal): Cardinal;
begin
  var SrcInstr := TSP shr 29;
  var DstInstr := (TSP shr 26) and 7;
  // The source factor's "other" colour is the destination and vice versa;
  // only those two instructions differ per channel.
  if (SrcInstr in [2, 3]) or (DstInstr in [2, 3]) then
  begin
    Result := 0;
    for var S := 0 to 3 do
    begin
      var Sh := S * 8;
      var FS := BlendFactor(SrcInstr, Src, Dst, Sh, Dst);
      var FD := BlendFactor(DstInstr, Src, Dst, Sh, Src);
      Result := Result or BlendChannel(Src, Dst, Sh, FS, FD);
    end;
    Exit;
  end;
  var FS := BlendFactor(SrcInstr, Src, Dst, 0, Dst);
  var FD := BlendFactor(DstInstr, Src, Dst, 0, Src);
  Result := BlendChannel(Src, Dst, 0, FS, FD) or BlendChannel(Src, Dst, 8, FS, FD) or
    BlendChannel(Src, Dst, 16, FS, FD) or BlendChannel(Src, Dst, 24, FS, FD);
end;

procedure TDCRenderer.RasterTranslucent(B: PTileBuffers; F: PFragmentBuffer; TileX, TileY, Pass: Integer; Presort: Boolean);
begin
  var Bin := (TileY * FTilesX + TileX) * 5 + TAListTranslucent;
  if FBinCount[Bin] = 0 then
    Exit;
  if Presort then
  begin
    for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
    begin
      var Index := FBinItems[K];
      var T: PRenderTri := @FTris[Index];
      var P: PPVRPoly := @FContext.Polys[T.Poly];
      if P.Pass <> Pass then
        Continue;
      var Mode := P.ISP shr 29;
      var ZWrite := (P.ISP and $04000000) = 0;
      var X0 := Max(T.MinX - TileX * TileSize, 0);
      var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
      var Y0 := Max(T.MinY - TileY * TileSize, 0);
      var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
      for var Y := Y0 to Y1 do
      begin
        var SX0 := X0;
        var SX1 := X1;
        if not RowSpan(T^, TileY * TileSize + Y + 0.5, TileX * TileSize, SX0, SX1) then
          Continue;
        var PY: Single := TileY * TileSize + Y + 0.5;
        var Row := CoverRow(T^, PY);
        for var X := SX0 to SX1 do
        begin
          var PX: Single := TileX * TileSize + X + 0.5;
          var Z: Single := 0;
          if not CoversRow(T^, Row, PX, Z) then
            Continue;
          var I := Y * TileSize + X;
          if not DepthPass(Mode, Z, B.Depth[I]) then
            Continue;
          if ZWrite then
            B.Depth[I] := Z;
          var Alpha: Integer;
          var Src := ShadePixel(Index, PX, PY, B.Modified[I] <> 0, B.Color[I], Alpha);
          B.Color[I] := Blend(Src, B.Color[I], P.TSP);
        end;
      end;
    end;
    Exit;
  end;
  // Autosort: per pixel, the fragments behind the opaque surface blend from
  // the farthest (smaller 1/w) to the nearest; ties follow submission order.
  // At most 256 layers, as the hardware's sorting depth.
  for var I := 0 to TileSize * TileSize - 1 do
  begin
    F.Head[I] := -1;
    F.Tail[I] := -1;
  end;
  F.Count := 0;
  for var K := FBinStart[Bin] to FBinStart[Bin] + FBinCount[Bin] - 1 do
  begin
    var Index := FBinItems[K];
    var T: PRenderTri := @FTris[Index];
    if FContext.Polys[T.Poly].Pass <> Pass then
      Continue;
    var X0 := Max(T.MinX - TileX * TileSize, 0);
    var X1 := Min(T.MaxX - TileX * TileSize, TileSize - 1);
    var Y0 := Max(T.MinY - TileY * TileSize, 0);
    var Y1 := Min(T.MaxY - TileY * TileSize, TileSize - 1);
    for var Y := Y0 to Y1 do
    begin
      var SX0 := X0;
      var SX1 := X1;
      if not RowSpan(T^, TileY * TileSize + Y + 0.5, TileX * TileSize, SX0, SX1) then
        Continue;
      var Row := CoverRow(T^, TileY * TileSize + Y + 0.5);
      for var X := SX0 to SX1 do
      begin
        var Z: Single := 0;
        if not CoversRow(T^, Row, TileX * TileSize + X + 0.5, Z) then
          Continue;
        var I := Y * TileSize + X;
        // In front of the opaque surface.
        if (Z < B.Depth[I]) or (Z < -1E30) or IsNaNSingle(Z) then
          Continue;
        var N := F.Count;
        if N >= Length(F.Z) then
        begin
          var Size := Max(4096, N * 2);
          SetLength(F.Z, Size);
          SetLength(F.Tag, Size);
          SetLength(F.Next, Size);
        end;
        F.Z[N] := Z;
        F.Tag[N] := Index;
        F.Next[N] := -1;
        if F.Tail[I] < 0 then
          F.Head[I] := N
        else
          F.Next[F.Tail[I]] := N;
        F.Tail[I] := N;
        F.Count := N + 1;
      end;
    end;
  end;
  if F.Count = 0 then
    Exit;
  for var I := 0 to TileSize * TileSize - 1 do
  begin
    var Link := F.Head[I];
    if Link < 0 then
      Continue;
    // Stable insertion by depth over fragments in submission order.
    var Count := 0;
    while Link >= 0 do
    begin
      if Count >= Length(F.SortZ) then
      begin
        SetLength(F.SortZ, Max(64, Count * 2));
        SetLength(F.SortTag, Length(F.SortZ));
      end;
      var Z := F.Z[Link];
      var Tag := F.Tag[Link];
      var J := Count;
      while (J > 0) and (F.SortZ[J - 1] > Z) do
      begin
        F.SortZ[J] := F.SortZ[J - 1];
        F.SortTag[J] := F.SortTag[J - 1];
        Dec(J);
      end;
      F.SortZ[J] := Z;
      F.SortTag[J] := Tag;
      Inc(Count);
      Link := F.Next[Link];
    end;
    var PX := TileX * TileSize + (I mod TileSize) + 0.5;
    var PY := TileY * TileSize + (I div TileSize) + 0.5;
    for var L := 0 to Min(Count, 256) - 1 do
    begin
      var Tag := F.SortTag[L];
      var Alpha: Integer;
      var Src := ShadePixel(Tag, PX, PY, B.Modified[I] <> 0, B.Color[I], Alpha);
      B.Color[I] := Blend(Src, B.Color[I], FContext.Polys[FTris[Tag].Poly].TSP);
    end;
  end;
end;

procedure TDCRenderer.WriteTile(B: PTileBuffers; TileX, TileY: Integer);
begin
  var Ctrl := FFBCtrl;
  var Pack := Ctrl and 7;
  var Dither := (Ctrl and 8) <> 0;
  var KVal := (Ctrl shr 8) and $FF;
  var AlphaThreshold := (Ctrl shr 16) and $FF;
  var Stride := FFBStride;
  var Base := FFBBase;
  var ToTexture := (Base and $1000000) <> 0;
  var ClipX := FFBClipX;
  var ClipY := FFBClipY;
  var MinX := Integer(ClipX and $7FF);
  var MaxX := Integer((ClipX shr 16) and $7FF);
  var MinY := Integer(ClipY and $3FF);
  var MaxY := Integer((ClipY shr 16) and $3FF);
  var Bytes: Integer;
  case Pack of
    0..3:
      Bytes := 2;
    4:
      Bytes := 3;
  else
    Bytes := 4;
  end;
  var Width := TileSize div FScaleX;
  for var Y := 0 to TileSize - 1 do
  begin
    var SY := TileY * TileSize + Y;
    if (SY < MinY) or (SY > MaxY) then
      Continue;
    for var X := 0 to Width - 1 do
    begin
      var SX := TileX * Width + X;
      if (SX < MinX) or (SX > MaxX) then
        Continue;
      var C: Cardinal;
      if FScaleX = 2 then
      begin
        // Horizontal 2x supersampling: average neighbouring samples.
        var C0 := B.Color[Y * TileSize + X * 2];
        var C1 := B.Color[Y * TileSize + X * 2 + 1];
        C := (((C0 shr 1) and $7F7F7F7F) + ((C1 shr 1) and $7F7F7F7F));
      end
      else
        C := B.Color[Y * TileSize + X];
      var A := Integer(C shr 24);
      var R := Integer((C shr 16) and $FF);
      var G := Integer((C shr 8) and $FF);
      var BB := Integer(C and $FF);
      if Dither and (Bytes = 2) then
      begin
        // 4x4 ordered dither before truncation to 5/6 bits.
        var D := DitherMatrix[(SY and 3) * 4 + (SX and 3)];
        R := Min(255, R + D);
        G := Min(255, G + D shr 1);
        BB := Min(255, BB + D);
      end;
      var V: Cardinal;
      case Pack of
        0:
          V := (Cardinal(R shr 3) shl 10) or (Cardinal(G shr 3) shl 5) or Cardinal(BB shr 3) or ((KVal shr 7) shl 15);
        1:
          V := (Cardinal(R shr 3) shl 11) or (Cardinal(G shr 2) shl 5) or Cardinal(BB shr 3);
        2:
          V := (Cardinal(A shr 4) shl 12) or (Cardinal(R shr 4) shl 8) or (Cardinal(G shr 4) shl 4) or Cardinal(BB shr 4);
        3:
          begin
            V := (Cardinal(R shr 3) shl 10) or (Cardinal(G shr 3) shl 5) or Cardinal(BB shr 3);
            if Cardinal(A) >= AlphaThreshold then
              V := V or $8000;
          end;
        4, 5:
          V := (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(BB) or (KVal shl 24);
      else
        V := C;
      end;
      var Offset := Base + Cardinal(SY) * Stride + Cardinal(SX * Bytes);
      if ToTexture then
      begin
        if Bytes = 2 then
          FMemory.VRAMWrite64Path(Offset and $7FFFFF, V, 2)
        else
          FMemory.VRAMWrite64Path(Offset and $7FFFFF, V, 4);
        Continue;
      end;
      var P := FMemory.VRAM + (Offset and $7FFFFF);
      case Bytes of
        2:
          PWord(FMemory.VRAM + (Offset and $7FFFFE))^ := Word(V);
        3:
          begin
            P^ := Byte(V);
            (FMemory.VRAM + ((Offset + 1) and $7FFFFF))^ := Byte(V shr 8);
            (FMemory.VRAM + ((Offset + 2) and $7FFFFF))^ := Byte(V shr 16);
          end;
      else
        PCardinal(FMemory.VRAM + (Offset and $7FFFFC))^ := V;
      end;
    end;
  end;
end;

procedure TDCRenderer.PrepareEntries;
begin
  // A tile starts from the background (colour and depth) unless it follows
  // its own previous entry; entries are then grouped per tile, in order, as
  // independent work items.
  var Count := Length(FEntries);
  SetLength(FEntryReset, Count);
  SetLength(FEntryTile, Count);
  var Last := -1;
  for var N := 0 to Count - 1 do
  begin
    var TX := Integer((FEntries[N].Control shr 2) and $3F);
    var TY := Integer((FEntries[N].Control shr 8) and $3F);
    if (TX >= FTilesX) or (TY >= FTilesY) then
    begin
      FEntryTile[N] := -1;
      Continue;
    end;
    var Tile := TY * FTilesX + TX;
    FEntryTile[N] := Tile;
    FEntryReset[N] := Tile <> Last;
    Last := Tile;
  end;
  var Tiles := FTilesX * FTilesY;
  var Counts: TArray<Integer>;
  SetLength(Counts, Tiles + 1);
  for var N := 0 to Count - 1 do
    if FEntryTile[N] >= 0 then
      Inc(Counts[FEntryTile[N]]);
  SetLength(FItemStart, Tiles + 1);
  SetLength(FItemEntries, Count);
  FItemCount := 0;
  var Sum := 0;
  var Slot: TArray<Integer>;
  SetLength(Slot, Tiles);
  for var T := 0 to Tiles - 1 do
    if Counts[T] > 0 then
    begin
      FItemStart[FItemCount] := Sum;
      Slot[T] := Sum;
      Inc(Sum, Counts[T]);
      Inc(FItemCount);
    end;
  FItemStart[FItemCount] := Sum;
  for var N := 0 to Count - 1 do
    if FEntryTile[N] >= 0 then
    begin
      FItemEntries[Slot[FEntryTile[N]]] := N;
      Inc(Slot[FEntryTile[N]]);
    end;
end;

procedure TDCRenderer.RenderEntry(N, Slot: Integer);
begin
  var B: PTileBuffers := @FBuffers[Slot];
  var E := FEntries[N];
  var TX := FEntryTile[N] mod FTilesX;
  var TY := FEntryTile[N] div FTilesX;
  if FEntryReset[N] then
    for var I := 0 to TileSize * TileSize - 1 do
    begin
      B.Color[I] := FBackground;
      B.Depth[I] := FBackgroundDepth;
      B.Tag[I] := -1;
      B.Fresh[I] := 1;
    end
  else if (E.Control and $40000000) = 0 then
    // Depth clears unless z_keep (bit 30); colour persists within a tile.
    for var I := 0 to TileSize * TileSize - 1 do
    begin
      B.Depth[I] := FBackgroundDepth;
      B.Tag[I] := -1;
      B.Fresh[I] := 1;
    end;
  FillChar(B.Modified, SizeOf(B.Modified), 0);
  if FContext <> nil then
  begin
    if (E.Lists[0] and $80000000) = 0 then
      RasterOpaque(B, TX, TY, TAListOpaque, E.Pass);
    if (E.Lists[4] and $80000000) = 0 then
      RasterOpaque(B, TX, TY, TAListPunchThrough, E.Pass);
    if (E.Lists[1] and $80000000) = 0 then
      ApplyVolumes(B, TX, TY, TAListOpaqueMod, E.Pass, False);
  end;
  ShadeOpaque(B, TX, TY);
  if (FContext <> nil) and ((E.Lists[2] and $80000000) = 0) then
  begin
    FillChar(B.Modified, SizeOf(B.Modified), 0);
    if (E.Lists[3] and $80000000) = 0 then
      ApplyVolumes(B, TX, TY, TAListTranslucentMod, E.Pass, True);
    RasterTranslucent(B, @FFragments[Slot], TX, TY, E.Pass, (E.Control and $20000000) <> 0);
  end;
  // no_writeout (bit 28) keeps the tile for a following pass.
  if (E.Control and $10000000) = 0 then
    WriteTile(B, TX, TY);
end;

procedure TDCRenderer.RenderTiles(First, Count, Slot: Integer);
begin
  if Slot >= Length(FBuffers) then
    Exit;
  for var N := First to First + Count - 1 do
    if FEntryTile[N] >= 0 then
      RenderEntry(N, Slot);
end;

end.

