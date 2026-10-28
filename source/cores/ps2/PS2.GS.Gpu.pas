unit PS2.GS.Gpu;

// GS compute path: 32/24-bit sprites, including nearest/bilinear 32/24-bit
// textures without mipmapping, with disjoint
// frame/depth surfaces. Other draws retain the software pixel pipeline.
// Queued sprites retain their own parameters until Sync publishes their
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
  private type
    TPush = record
      Bounds: array[0..3] of Integer;
      Slot: Cardinal;
    end;
  private
    FCompute: TVulkanCompute;
    FKernel: TVulkanKernel;
    FRAM, FState, FCoordinates: TVulkanBuffer;
    FDraws: Int64;
    FTexturedDraws: Int64;
    FUsed: Integer;
    FSubmissions: Int64;
  public
    constructor Create(RAM: Pointer);
    destructor Destroy; override;
    procedure Sync; override;
    function Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer): Boolean; override;
    property Draws: Int64 read FDraws;
    property TexturedDraws: Int64 read FTexturedDraws;
    property Submissions: Int64 read FSubmissions;
  end;

implementation

const
{$I shaders\PS2.GS.Sprite.inc}

constructor TPS2GSGpu.Create(RAM: Pointer);
begin
  inherited Create;
  FCompute := TVulkanCompute.Create;
  FRAM := FCompute.ImportHost(RAM, PS2GSMemorySize);
  if FRAM = nil then
    raise Exception.Create('Vulkan GS needs coherent host-memory import for GS VRAM');
  FState := FCompute.CreateBuffer(BatchSize * 64 * SizeOf(Cardinal), True);
  FCoordinates := FCompute.CreateBuffer(BatchSize * 4096 * SizeOf(Integer), True);
  FKernel := FCompute.CreateKernel(PS2SpriteSPIRV, 3, SizeOf(TPush));
  FCompute.Bind(FKernel, [FRAM, FState, FCoordinates]);
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
  Inc(FSubmissions);
end;

// Same truncation and finite-range handling as the software sprite path.
function TextureCoordinate(D: Double): Integer;
begin
  if not (D > -$1000000) then Exit(-$1000000);
  if D > $1000000 then Exit($1000000);
  Result := Trunc(D);
end;

function TPS2GSGpu.Sprite(const D: TPS2GSDraw; const V0, V: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;
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
    if D.UseLod or (D.TW > 10) or (D.TH > 10) or not (D.TPSM in [PSMCT32, PSMCT24]) then Exit;
    var W := 1 shl D.TW;
    var H := 1 shl D.TH;
    if D.WMS >= 2 then W := Max(W, Max(D.MINU, D.MAXU) + 1);
    if D.WMT >= 2 then H := Max(H, Max(D.MINV, D.MAXV) + 1);
    if D.WMS = 3 then W := 1024;
    if D.WMT = 3 then H := 1024;
    var T0 := D.TBP div 32;
    var T1 := (D.TBP + 31) div 32 + Cardinal((H - 1) div 32) * D.TBW + Cardinal((W - 1) div 64);
    // No texture feedback within one dispatch. Between dispatches the
    // compute barriers allow a previous target to become the next texture.
    if (T1 >= 512) or ((T1 >= F0) and (F1 >= T0)) or
      (not D.ZMSK and (T1 >= Z0) and (Z1 >= T0)) then Exit;
  end;
  // Small draws cost more to submit than to draw on the host.
  if Int64(X1 - X0) * (Y1 - Y0) < 4096 then Exit;
  if FUsed = BatchSize then Sync;
  var P := PCardinal(FState.Data) + FUsed * 64;
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
  FCompute.Launch(FKernel, Push, Cardinal((X1-X0+7) div 8), Cardinal((Y1-Y0+7) div 8), 1);
  Inc(FUsed);
  FPending := True;
  Inc(FDraws);
  if D.TME then Inc(FTexturedDraws);
  Result := True;
end;

end.
