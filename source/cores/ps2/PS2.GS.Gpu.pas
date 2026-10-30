unit PS2.GS.Gpu;

// GS compute path: 32/24-bit sprites and triangles, with
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
  System.SysUtils, System.Math, PS2.Types, PS2.GS.Raster, PS2.GS.Memory, RM.Vulkan.Compute;

type
  TPS2GSGpu = class(TPS2GSAccelerator)
  private const
    BatchSize = 128;
    FragmentCapacity = 65536;
  private type
    TPush = record
      Bounds: array[0..3] of Integer;
      Slot: Cardinal;
      Mode: Cardinal;
    end;
  private
    FCompute: TVulkanCompute;
    FKernel, FTriangleKernel: TVulkanKernel;
    FRAM, FState, FCoordinates, FFragments: TVulkanBuffer;
    FDraws: Int64;
    FTexturedDraws: Int64;
    FUsed: Integer;
    FSubmissions: Int64;
    FTriangles: Int64;
    FRasterizedTriangles: Int64;
    FFragmentsUsed, FFragmentStart, FFragmentCount: Integer;
    FTriangleState: TPS2GSDraw;
    FHostClut: PWord;
    function Supports(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal = $7F): Boolean;
    procedure WriteState(const D: TPS2GSDraw; const V: TPS2GSVertex);
    procedure FlushFragments;
  public
    constructor Create(RAM: Pointer; Clut: PWord = nil);
    destructor Destroy; override;
    procedure Sync; override;
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
  end;

implementation

const
{$I shaders\PS2.GS.Sprite.inc}
{$I shaders\PS2.GS.Triangle.inc}

constructor TPS2GSGpu.Create(RAM: Pointer; Clut: PWord);
begin
  inherited Create;
  FHostClut := Clut;
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
  if FCompute.ExactDouble then
  begin
    FTriangleKernel := FCompute.CreateKernel(PS2TriangleSPIRV, 2, SizeOf(TPush));
    FCompute.Bind(FTriangleKernel, [FRAM, FState]);
  end;
  {$ENDIF}
end;

destructor TPS2GSGpu.Destroy;
begin
  FCompute.Free;
  inherited;
end;

procedure TPS2GSGpu.Sync;
begin
  if not FPending then Exit;
  FCompute.Finish;
  FPending := False;
  FUsed := 0;
  FFragmentsUsed := 0;
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

function TPS2GSGpu.Supports(const D: TPS2GSDraw; X0, Y0, X1, Y1: Integer; Levels: Cardinal): Boolean;
begin
  Result := False;
  if not (D.FPSM in [PSMCT32, PSMCT24]) or
    not (D.ZPSM in [PSMZ32, PSMZ24]) or (X0 < 0) or (Y0 < 0) or
    (X1 <= X0) or (Y1 <= Y0) or (X1 > 2048) or (Y1 > 2048) then Exit;
  // One invocation must own each word: reject zero stride, row aliases,
  // VRAM wrapping and colour/depth overlap. Bounds are deliberately broad.
  if (D.FBW = 0) or (Cardinal(X1) > D.FBW * 64) then Exit;
  var F0 := D.FBP div 32;
  var F1 := (D.FBP + 31) div 32 + Cardinal((Y1 - 1) div 32) * D.FBW + Cardinal((X1 - 1) div 64);
  var Z0 := D.ZBP div 32;
  var Z1 := (D.ZBP + 31) div 32 + Cardinal((Y1 - 1) div 32) * D.FBW + Cardinal((X1 - 1) div 64);
  if F1 >= 512 then Exit;
  if not D.ZMSK or (D.ZTST <> 1) then
    if (Z1 >= 512) or ((F1 >= Z0) and (Z1 >= F0)) then Exit;
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
      if D.WMS = 2 then W := Max(W, (Max(D.MINU, D.MAXU) shr L) + 1);
      if D.WMT = 2 then H := Max(H, (Max(D.MINV, D.MAXV) shr L) + 1);
      if D.WMS = 3 then W := 1024;
      if D.WMT = 3 then H := 1024;
      var PW := 64; var PH := 32;
      if D.TPSM in [PSMCT16, PSMCT16S, PSMZ16, PSMZ16S] then PH := 64;
      if D.TPSM in [PSMT8, PSMT4] then
      begin
        PW := 128; PH := 64; BW := (BW + 1) shr 1;
        if D.TPSM = PSMT4 then PH := 128;
      end;
      var T0 := BP div 32;
      var T1 := (BP + 31) div 32 + Cardinal((H - 1) div PH) * BW + Cardinal((W - 1) div PW);
      if (T1 >= 512) or ((T1 >= F0) and (F1 >= T0)) or
        (not D.ZMSK and (T1 >= Z0) and (Z1 >= T0)) then Exit;
    end;
  end;
  // Small draws cost more to submit than to draw on the host.
  if Int64(X1 - X0) * (Y1 - Y0) < 4096 then Exit;
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
begin
  Result := False;
  var Mip := MipCode(D, Lod);
  if not Supports(D, X0, Y0, X1, Y1, (Cardinal(1) shl (Mip and 7)) or
    (Cardinal(1) shl ((Mip shr 3) and 7))) then Exit;
  if FUsed = BatchSize then Sync;
  WriteState(D, V);
  PCardinal(FState.Data)[FUsed * 384 + 52] := Mip;
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
  var Push: TPush;
  Push.Bounds[0] := X0; Push.Bounds[1] := Y0; Push.Bounds[2] := X1; Push.Bounds[3] := Y1;
  Push.Slot := Cardinal(FUsed);
  Push.Mode := 0;
  FCompute.Launch(FKernel, Push, Cardinal((X1-X0+7) div 8), Cardinal((Y1-Y0+7) div 8), 1);
  Inc(FUsed);
  FPending := True;
  Inc(FDraws);
  if D.TME then Inc(FTexturedDraws);
  Result := True;
end;

function TPS2GSGpu.Triangle(const D: TPS2GSDraw; const V0, V1, V2: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;
var
  Vertices: array[0..2] of TPS2GSVertex;

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
  // Dynamic per-pixel log2/LOD remains on the host. Constant mip decisions
  // retain the existing host rounding and filtering rules.
  if D.TME and D.UseLod and not D.LCM and not D.FST then Exit;
  var Mip := MipCode(D, D.K);
  if not Supports(D, X0, Y0, X1, Y1, (Cardinal(1) shl (Mip and 7)) or
    (Cardinal(1) shl ((Mip shr 3) and 7))) then Exit;
  Vertices[0] := V0; Vertices[1] := V1; Vertices[2] := V2;
  for var K := 0 to 2 do
  begin
    var V := Vertices[K];
    if (V.X < -65535) or (V.X > 65535) or (V.Y < -65535) or (V.Y > 65535) then Exit;
    if D.TME and not D.FST then
      if not FiniteNormalOrZero(V.S) or not FiniteNormalOrZero(V.T) or
        not FiniteNormalOrZero(V.Q) or not (V.Q > 0) then Exit;
  end;
  var Area := (Int64(V1.X) - V0.X) * (Int64(V2.Y) - V0.Y) -
    (Int64(V2.X) - V0.X) * (Int64(V1.Y) - V0.Y);
  if Area = 0 then Exit;
  var InvArea: Double := 1.0 / Area;
  if FUsed = BatchSize then Sync;
  WriteState(D, V2);
  var P := PCardinal(FState.Data) + FUsed * 384;
  P[52] := Mip;
  P[53] := Ord(D.FST);
  P[54] := Ord(D.IIP);
  P[55] := 0;
  if Rounding = rmTruncate then P[55] := 3;
  Move(InvArea, P[56], SizeOf(InvArea));
  P[58] := 1;
  if Area < 0 then P[58] := $FFFFFFFF;
  P[59] := Ord((D.ZTST >= 2) or not D.ZMSK);
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
  var Push := Default(TPush);
  Push.Bounds[0] := X0; Push.Bounds[1] := Y0; Push.Bounds[2] := X1; Push.Bounds[3] := Y1;
  Push.Slot := Cardinal(FUsed);
  FCompute.Launch(FTriangleKernel, Push, Cardinal((X1 - X0 + 7) div 8), Cardinal((Y1 - Y0 + 7) div 8), 1);
  Inc(FUsed);
  FPending := True;
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
  if FUsed = BatchSize then Sync;
  FTriangleState := D;
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
  FCompute.Launch(FKernel, Push, Cardinal((FFragmentCount + 63) div 64), 1, 1);
  Inc(FUsed);
  FPending := True;
  FFragmentCount := 0;
end;

procedure TPS2GSGpu.Fragment(X, Y: Integer; Z: Cardinal; R, G, B, A, F, U, V: Integer; Lod: Single);
begin
  if FFragmentsUsed = FragmentCapacity then
  begin
    FlushFragments;
    Sync;
    WriteState(FTriangleState, Default(TPS2GSVertex));
    FFragmentStart := 0;
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
