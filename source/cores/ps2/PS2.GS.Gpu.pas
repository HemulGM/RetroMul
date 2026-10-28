unit PS2.GS.Gpu;

// Initial GS compute path: untextured 32/24-bit sprites with disjoint
// frame/depth surfaces. Other draws retain the software pixel pipeline.
// Queued sprites retain their own parameters until Sync publishes their
// writes to CPU consumers. Compute barriers order draws within each batch.
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$POINTERMATH ON}

interface

uses
  System.SysUtils, PS2.Types, PS2.GS.Raster, PS2.GS.Memory, RM.Vulkan.Compute;

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
    FRAM, FState: TVulkanBuffer;
    FDraws: Int64;
    FUsed: Integer;
    FSubmissions: Int64;
  public
    constructor Create(RAM: Pointer);
    destructor Destroy; override;
    procedure Sync; override;
    function Sprite(const D: TPS2GSDraw; const V: TPS2GSVertex;
      X0, Y0, X1, Y1: Integer): Boolean; override;
    property Draws: Int64 read FDraws;
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
  FState := FCompute.CreateBuffer(BatchSize * 32 * SizeOf(Cardinal), True);
  FKernel := FCompute.CreateKernel(PS2SpriteSPIRV, 2, SizeOf(TPush));
  FCompute.Bind(FKernel, [FRAM, FState]);
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

function TPS2GSGpu.Sprite(const D: TPS2GSDraw; const V: TPS2GSVertex;
  X0, Y0, X1, Y1: Integer): Boolean;
begin
  Result := False;
  if D.TME or not (D.FPSM in [PSMCT32, PSMCT24]) or
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
  // Small draws cost more to submit than to draw on the host.
  if Int64(X1 - X0) * (Y1 - Y0) < 4096 then Exit;
  if FUsed = BatchSize then Sync;
  var P := PCardinal(FState.Data) + FUsed * 32;
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
  var Push: TPush;
  Push.Bounds[0] := X0; Push.Bounds[1] := Y0; Push.Bounds[2] := X1; Push.Bounds[3] := Y1;
  Push.Slot := Cardinal(FUsed);
  FCompute.Launch(FKernel, Push, Cardinal((X1-X0+7) div 8), Cardinal((Y1-Y0+7) div 8), 1);
  Inc(FUsed);
  FPending := True;
  Inc(FDraws);
  Result := True;
end;

end.
