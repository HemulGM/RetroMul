unit PSP.GE.Engine;

// The GE's command processor below list control: register writes, matrix
// uploads, vertex processing (decode, morph, skinning, transform, lighting,
// texture coordinate generation), primitive assembly, CLUT loads and block
// transfers. Flow commands (JUMP, CALL, END, ...) are run by the list driver
// in PSP.GE, which owns the program counter. Rasterization is in
// PSP.GE.Raster and works on a snapshot (TGERaster) built here.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Math, System.Classes, System.SyncObjs, PSP.Types,
  PSP.Memory, PSP.GE.Types, PSP.GE.Texture, PSP.GE.Raster, PSP.GE.Backend,
  PSP.GE.Workers;

type
  TGEVec3 = record
    X, Y, Z: Single;
  end;

  // The values a Bezier patch interpolates of a control point: position,
  // normal, texture coordinates and weights (F: P.X .. P.Z, N.X .. N.Z, U, V,
  // Weights[0..7]), the colour in 2^-7 (C: R, G, B, A).
  TGEPatchValues = record
    F: array[0..15] of Double;
    C: array[0..3] of Integer;
  end;

  // A decoded vertex before transform.
  TGEInVertex = record
    U, V: Single;
    R, G, B, A: Integer;
    HasColor: Boolean;
    N: TGEVec3;
    P: TGEVec3;
    Weights: array[0..7] of Single;
  end;

  // A vertex in primitive assembly: its drawn form, its clip coordinates and
  // the planes it lies beyond (GEOut*).
  TGEAsmVertex = record
    V: TGEVertex;
    CX, CY, CZ, CW: Double;
    Code: Integer;
  end;

  // A colour's 8-bit channels.
  TGERGB = array[0..2] of Integer;

  // The lighting registers as Light reads them, decoded once a primitive.
  TGELightUnit = record
    on: Boolean;
    Kind, LType: Integer;
    Pos, SpotDir: TGEVec3;
    // The spot direction as the lighting unit takes it: its components cut
    // to 24-bit floats and RSqrt24 of their squared length.
    SpotRaw: TGEVec3;
    SpotRS: Single;
    SpotFinite: Boolean;
    KA, KB, KC, Cutoff, Expo: Single;
    // Pos, KA, KB and KC finite.
    PosFinite: Boolean;
    SpotPositive: Boolean;
    LA, LD, LS: TGERGB;
    // A directional light's (LType 0) vector and half vector as Light makes
    // them: the same for every vertex.
    DirD, DirH: TGEVec3;
  end;

  PGELightUnit = ^TGELightUnit;

  TGELightSetup = record
    MA, MD, MS, E, AL: TGERGB;
    MAA, ALA: Integer;
    Shine: Single;
    View: TGEVec3;
    Separate: Boolean;
    Lights: array[0..3] of TGELightUnit;
  end;

  // The registers PrepareLight read last (and the floating-point modes its
  // divisions ran in): the same ones give the same setup.
  TGELightRegs = array[0..79] of Cardinal;

  TGESingle12 = array[0..11] of Single;

  PGESingle12 = ^TGESingle12;

  // The matrices and viewport as the vertex unit's arithmetic reads them,
  // decoded once a primitive (GEFloat is exact; the arithmetic is done on
  // the same values as before).
  TGEGeometry = record
    World, View: array[0..11] of Double;
    Proj: array[0..15] of Double;
    // T24 of the projection's translation column (w = 1).
    ProjW: array[0..3] of Double;
    // The rows as ClipPosition uses them (factors, the term added):
    // World's and View's x, y, z, Proj's x, y, z, w.
    Rows: array[0..9, 0..3] of Double;
    // View times world as the vertex unit forms it (Rows24), when every
    // element is normal or zero; else the two apply in turn.
    ViewWorld: array[0..2, 0..3] of Double;
    Combined: Boolean;
    // Every element of ViewWorld, of World's, View's and Proj's rows Small24.
    ViewWorldSmall, WorldSmall, ViewSmall, ProjSmall: Boolean;
    WorldS, TGen: TGESingle12;
    Bone: array[0..95] of Single;
    BoneCount: Integer;
    XScale, XCenter, YScale, YCenter, ZScale, ZCenter: Double;
    OffX, OffY: Integer;
  end;

  TPSPGEEngine = class
  private
    FMemory: TPSPMemory;
    // RAM's host memory where TPSPMemory maps it linearly (DecodeVertex).
    FRAMBase: PByte;
    FWorkers: TGEWorkers;
    FClut: array[0..1023] of Byte;
    FRaster: TGERaster;
    // The texture format and CLUT register FRaster.Tex.Pal was made for.
    FPalKey: Cardinal;
    FVSize: Integer;
    FOffTC, FOffC, FOffN, FOffP: Integer;
    FPrimCost: Int64;
    FAsmType, FAsmCount: Integer;
    FLastU, FLastV: Single;
    FLastN: TGEVec3;
    FAsm: array[0..2] of TGEAsmVertex;
    FPatchCP: array of TGEInVertex;
    FPatchVal: array of TGEPatchValues;
    FPatchGrid: array of TGEAsmVertex;
    FCullOn, FCullCW, FDepthClamp: Boolean;
    FLight: TGELightSetup;
    FLightValid: Boolean;
    FLightRegs: TGELightRegs;
    FLightRegsValid: Boolean;
    FGeom: TGEGeometry;
    FGeomValid: Boolean;
    // The registers FGeom was decoded from: World to Proj, the viewport and
    // offset, the bones decoded.
    FGeomMats: array[0..51] of Cardinal;
    FGeomPort: array[0..7] of Cardinal;
    FGeomBones: array[0..95] of Cardinal;
    FGeomCached: Boolean;
    // The projection times view and world (rows of x, y, z, w) as the vertex
    // unit forms it for positions (probe ge_xyround), when FGeom.Combined;
    // made again when FGeomClipValid is False.
    FGeomClip: array[0..3, 0..3] of Double;
    FGeomClipSmall: Boolean;
    FGeomClipValid: Boolean;
    // What BuildRaster built FRaster from (the 79 registers of GERasterRuns,
    // the VRAM layout), while FRaster is as it built it.
    FRasterKey: array[0..81] of Cardinal;
    FRasterKeyValid: Boolean;
    // The texture cache of textures read from the pixels drawn, and the
    // TEXFLUSH count (TGETexture.CacheEpoch).
    FTexCache: TGETexCache;
    FTexEpoch: Cardinal;
    // Threads that decode and transform the vertices of large primitives
    // (TGEVertexPool on 64-bit hosts; nil on few cores or with
    // PSP_GE_VERTEX_THREADS=0), the vertices' indices and the results.
    FVertexPool: TObject;
    FParIndex: TArray<Integer>;
    FParOut: TArray<TGEAsmVertex>;
    FVertexFormatKey: Cardinal;
    FVertexFormatValid: Boolean;
    procedure PrepareLight;
    procedure PrepareGeometry;
    procedure PrepareClip;
    procedure PrepareBones(Count: Integer);
    procedure SetupVertexFormat(VType: Cardinal);
    procedure DecodeVertex(Addr, VType: Cardinal; out V: TGEInVertex);
    procedure DecodeVertexWith(Addr, VType: Cardinal; out V: TGEInVertex; var LastU, LastV: Single; var LastN: TGEVec3);
    function TransformInParallel(Count: Integer; VType: Cardinal): Boolean;
{$IFDEF CPU64BITS}
    procedure TransformRange(VType: Cardinal; First, Last: Integer; LastU, LastV: Single; const LastN: TGEVec3);
{$ENDIF}
    function ReadVertex(Index: Integer; VType: Cardinal; out V: TGEInVertex): Boolean;
    procedure Skin(const V: TGEInVertex; VType: Cardinal; var P, N: TGEVec3);
    // MP: the model position (after skinning), WP: the world position.
    procedure Light(const V: TGEInVertex; const MP, WP, WN: TGEVec3; var R, G, B, A, SR, SG, SB: Integer);
    function LightVector(L: Integer; const WP: TGEVec3): TGEVec3;
    procedure TexGen(const V: TGEInVertex; const P, N, WP, WN: TGEVec3; out S, T, Q: Single);
    procedure ClipPosition(const P: TGEVec3; out CX, CY, CZ, CW: Double; out VP: TGEVec3);
    procedure Project(var A: TGEAsmVertex);
    procedure TransformVertex(const V: TGEInVertex; VType: Cardinal; out O: TGEAsmVertex);
    function VertexIndex(I: Integer; VType: Cardinal): Integer;
    procedure AdvanceVertices(Count: Integer; VType: Cardinal);
    procedure BoundingBox(Op: Cardinal);
    procedure BuildRaster;
    procedure RasterChanged; inline;
    function ScissoredArea(X1, Y1, X2, Y2: Integer): Int64;
    function FillCost(Pixels: Int64): Int64;
    procedure EmitTriangle(const A, B, C: TGEVertex; Odd: Boolean);
    procedure ClipTriangle(const A, B, C: TGEAsmVertex; Odd: Boolean);
    procedure ClipLine(const A, B: TGEAsmVertex);
    procedure EmitSprite(const A, B: TGEAsmVertex);
    procedure AddVertex(const A: TGEAsmVertex);
    procedure DrawPrim(Op: Cardinal);
    procedure DrawPatch(Op: Cardinal; Spline: Boolean);
    procedure ImmediateVertex(Op: Cardinal);
    procedure LoadClut(Op: Cardinal);
    procedure BlockTransfer(Op: Cardinal);
  public
    Regs: TPSPGERegs;
    // Set by BBOX: the box is (possibly) visible.
    BoxVisible: Boolean;
    // Draws the primitives instead of PSP.GE.Raster when set (not owned).
    Backend: TGERasterBackend;
    // The CPU renderer's queue and pool, used without a backend.
    property Workers: TGEWorkers read FWorkers;
    constructor Create(Memory: TPSPMemory);
    destructor Destroy; override;
    // The GE stops running for now: the backend makes what it drew visible.
    procedure ReleaseBackend; inline;
    procedure Synchronize;
    procedure Restored;
    procedure Reset;
    // Address of a 24-bit pointer parameter with the BASE upper bits and OFFSET.
    function Address(Param: Cardinal): Cardinal; inline;
    // Runs one command; returns its cost in GE nanoseconds.
    function Execute(Op, PC: Cardinal): Integer;
    procedure SaveContext(Address: Cardinal);
    procedure RestoreContext(Address: Cardinal);
    property Memory: TPSPMemory read FMemory;
    // RAM's host memory where TPSPMemory maps it linearly, else nil: reading
    // it there is reading it through TPSPMemory.
    property RAMBase: PByte read FRAMBase;
  end;

const
  // Context words: a header, then the state commands in this order, then the matrices.
  GEContextCmdStart = 17;

var
  GEContextCmds: array of Byte;

implementation

uses
  HW.HostFPU;

{$IFDEF CPU64BITS}
type
  // Workers that decode and transform ranges of a primitive's vertices
  // (TPSPGEEngine.TransformRange) while the GE's thread does its own share.
  // A job is written while FGen is odd and published when it turns even;
  // FActive counts the workers inside the published job.
  TGEVertexPool = class
  private
    FThreads: TArray<TThread>;
    FWake: TEvent;
    FGen, FActive, FNext: Integer;
    FStop: Boolean;
    FEngine: TPSPGEEngine;
    FVType: Cardinal;
    FCount: Integer;
    FLastU, FLastV: Single;
    FLastN: TGEVec3;
    FMXCSR: Cardinal;
    FRound: TRoundingMode;
    FMask: TArithmeticExceptionMask;
    FFailed: Boolean;
    procedure Work;
    procedure Share;
  public
    constructor Create(Threads: Integer);
    destructor Destroy; override;
    // False when a range failed (then nothing of the results counts).
    function Run(Engine: TPSPGEEngine; VType: Cardinal; Count: Integer; LastU, LastV: Single; const LastN: TGEVec3): Boolean;
  end;

const
  // Vertices a worker takes at a time.
  VertexChunk = 32;

procedure VertexYield; inline;
begin
{$IFDEF MSWINDOWS}
  YieldProcessor;
{$ELSE}
  TThread.Yield;
{$ENDIF}
end;

constructor TGEVertexPool.Create(Threads: Integer);
begin
  inherited Create;
  FWake := TEvent.Create(nil, True, False, '');
  SetLength(FThreads, Threads);
  for var I := 0 to Threads - 1 do
  begin
    FThreads[I] := TThread.CreateAnonymousThread(Work);
    FThreads[I].FreeOnTerminate := False;
    FThreads[I].Start;
  end;
end;

destructor TGEVertexPool.Destroy;
begin
  FStop := True;
  FWake.SetEvent;
  for var T in FThreads do
  begin
    T.WaitFor;
    T.Free;
  end;
  FWake.Free;
  inherited;
end;

procedure TGEVertexPool.Share;
begin
  try
    while True do
    begin
      var I := AtomicIncrement(FNext, VertexChunk) - VertexChunk;
      if I >= FCount then
        Break;
      FEngine.TransformRange(FVType, I, Min(I + VertexChunk, FCount) - 1, FLastU, FLastV, FLastN);
    end;
  except
    FFailed := True;
  end;
end;

procedure TGEVertexPool.Work;
begin
  var Seen := AtomicCmpExchange(FGen, 0, 0);
  var Idle := 0;
  while not FStop do
  begin
    var G := AtomicCmpExchange(FGen, 0, 0);
    if (G = Seen) or Odd(G) then
    begin
      // A while spinning (jobs come in bursts), then asleep until the next.
      Inc(Idle);
      if Idle < 4000 then
        VertexYield
      else
      begin
        FWake.WaitFor(2);
        Idle := 4000;
      end;
      Continue;
    end;
    Seen := G;
    Idle := 0;
    AtomicIncrement(FActive);
    if AtomicCmpExchange(FGen, 0, 0) = G then
    begin
      SetExceptionMask(FMask);
      SetRoundMode(FRound);
      WriteHostMXCSR(FMXCSR);
      Share;
    end;
    AtomicDecrement(FActive);
  end;
end;

function TGEVertexPool.Run(Engine: TPSPGEEngine; VType: Cardinal; Count: Integer; LastU, LastV: Single; const LastN: TGEVec3): Boolean;
begin
  AtomicIncrement(FGen);
  while AtomicCmpExchange(FActive, 0, 0) <> 0 do
    VertexYield;
  FEngine := Engine;
  FVType := VType;
  FCount := Count;
  FLastU := LastU;
  FLastV := LastV;
  FLastN := LastN;
  // The workers compute in this thread's floating-point modes.
  FMXCSR := ReadHostMXCSR;
  FRound := GetRoundMode;
  FMask := GetExceptionMask;
  FFailed := False;
  FNext := 0;
  AtomicIncrement(FGen);
  FWake.SetEvent;
  Share;
  while AtomicCmpExchange(FActive, 0, 0) <> 0 do
    VertexYield;
  FWake.ResetEvent;
  Result := not FFailed;
end;
{$ENDIF}

constructor TPSPGEEngine.Create(Memory: TPSPMemory);
begin
  inherited Create;
  FMemory := Memory;
  if (FMemory <> nil) and (Cardinal(Length(FMemory.RAM)) = PSPRAMSize) then
  begin
    FRAMBase := @FMemory.RAM[0];
    for var Page := 0 to PSPRAMSize div PSPPageSize - 1 do
      if FMemory.PageBase(PSPRAMBase + Cardinal(Page) * PSPPageSize) <> FRAMBase + Page * PSPPageSize then
      begin
        FRAMBase := nil;
        Break;
      end;
  end;
  FWorkers := TGEWorkers.Create(FMemory);
{$IFDEF CPU64BITS}
  // Up to three workers, leaving the emulation, its sound and the front end
  // their cores.
  var Threads := Min(TThread.ProcessorCount - 3, 3);
  var Setting := GetEnvironmentVariable('PSP_GE_VERTEX_THREADS');
  if Setting <> '' then
    Threads := Min(StrToIntDef(Setting, 0), 15);
  if Threads > 0 then
    FVertexPool := TGEVertexPool.Create(Threads);
{$ENDIF}
  Reset;
end;

destructor TPSPGEEngine.Destroy;
begin
  FVertexPool.Free;
  FWorkers.Free;
  inherited;
end;

procedure TPSPGEEngine.ReleaseBackend;
begin
  // The CPU queue stays: what it holds and watches brings it back on access.
  if Backend <> nil then
  begin
    FWorkers.Sync;
    Backend.Release;
  end
  else
    FWorkers.Release;
end;

procedure TPSPGEEngine.Synchronize;
begin
  FWorkers.Sync;
  if Backend <> nil then
    Backend.Sync;
end;

procedure TPSPGEEngine.Restored;
begin
  FVertexFormatValid := False;
  FGeomValid := False;
  FGeomClipValid := False;
  FGeomCached := False;
  FLightValid := False;
  FLightRegsValid := False;
  FRasterKeyValid := False;
  FRaster.Tex.PalValid := False;
  FRaster.Tex.Sampler := nil;
  FRaster.Tex.Cache := nil;
  Inc(FTexEpoch);
  FWorkers.ClutChanged;
  RasterChanged;
end;

procedure TPSPGEEngine.Reset;
begin
  FVertexFormatValid := False;
  Regs := Default(TPSPGERegs);
  for var I := 0 to 255 do
    Regs.Cmd[I] := Cardinal(I) shl 24;
  FGeomValid := False;
  FGeomClipValid := False;
  FLightValid := False;
  FLightRegsValid := False;
  FRasterKeyValid := False;
  BoxVisible := True;
  if FWorkers <> nil then
  begin
    FWorkers.Sync;
    FWorkers.ClutChanged;
  end;
  FillChar(FClut, SizeOf(FClut), 0);
  FRaster.Tex.PalValid := False;
  FRaster.Tex.Sampler := nil;
  FRaster.Tex.Cache := nil;
  Inc(FTexEpoch);
  RasterChanged;
end;

function TPSPGEEngine.Address(Param: Cardinal): Cardinal;
begin
  Result := (((Regs.Cmd[GE_BASE] and $0F0000) shl 8) or (Param and $FFFFFF)) + Regs.Offset;
end;

function TPSPGEEngine.Execute(Op, PC: Cardinal): Integer;
begin
  Result := 12;
  var Cmd := Op shr 24;
  var P := Op and $FFFFFF;
  case Cmd of
    GE_VADDR:
      Regs.VAddr := Address(P);
    GE_IADDR:
      Regs.IAddr := Address(P);
    GE_PRIM:
      begin
        Regs.Cmd[Cmd] := Op;
        // Primitive setup, per vertex and per pixel.
        FPrimCost := 1000;
        DrawPrim(Op);
        Exit(4 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_BEZIER, GE_SPLINE:
      begin
        Regs.Cmd[Cmd] := Op;
        FPrimCost := 1000;
        DrawPatch(Op, Cmd = GE_SPLINE);
        Exit(4 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_BBOX:
      begin
        Regs.Cmd[Cmd] := Op;
        BoundingBox(Op);
        Exit(12 + Integer(Min(FPrimCost, 100000000)));
      end;
    $F7:
      begin
        Regs.Cmd[Cmd] := Op;
        FPrimCost := 0;
        ImmediateVertex(Op);
        Exit(12 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_OFFSETADDR:
      Regs.Offset := P shl 8;
    GE_ORIGIN:
      Regs.Offset := PC;
    GE_TEXFLUSH:
      begin
        Inc(FTexEpoch);
        FRaster.Tex.CacheEpoch := FTexEpoch;
        RasterChanged;
      end;
    GE_LOADCLUT:
      begin
        Regs.Cmd[Cmd] := Op;
        LoadClut(Op);
        Exit(4 + Integer(P and $3F) * 8);
      end;
    GE_TRANSFERSTART:
      begin
        Regs.Cmd[Cmd] := Op;
        FPrimCost := 0;
        BlockTransfer(Op);
        Exit(4 + Integer(Min(FPrimCost, 100000000)));
      end;
    GE_BONEMATRIXNUMBER:
      Regs.BoneNum := P and $7F;
    GE_BONEMATRIXDATA:
      begin
        if Regs.BoneNum < 96 then
          Regs.Bone[Regs.BoneNum] := P;
        Regs.BoneNum := (Regs.BoneNum + 1) and $7F;
        Exit;
      end;
    GE_WORLDMATRIXNUMBER:
      Regs.WorldNum := P and $F;
    GE_WORLDMATRIXDATA:
      begin
        if Regs.WorldNum < 12 then
          Regs.World[Regs.WorldNum] := P;
        Regs.WorldNum := (Regs.WorldNum + 1) and $F;
        Exit;
      end;
    GE_VIEWMATRIXNUMBER:
      Regs.ViewNum := P and $F;
    GE_VIEWMATRIXDATA:
      begin
        if Regs.ViewNum < 12 then
          Regs.View[Regs.ViewNum] := P;
        Regs.ViewNum := (Regs.ViewNum + 1) and $F;
        Exit;
      end;
    GE_PROJMATRIXNUMBER:
      Regs.ProjNum := P and $F;
    GE_PROJMATRIXDATA:
      begin
        Regs.Proj[Regs.ProjNum and 15] := P;
        Regs.ProjNum := (Regs.ProjNum + 1) and $F;
        Exit;
      end;
    GE_TGENMATRIXNUMBER:
      Regs.TGenNum := P and $F;
    GE_TGENMATRIXDATA:
      begin
        if Regs.TGenNum < 12 then
          Regs.TGen[Regs.TGenNum] := P;
        Regs.TGenNum := (Regs.TGenNum + 1) and $F;
        Exit;
      end;
  end;
  Regs.Cmd[Cmd] := Op;
end;

{ Vertex format }

const
  TCSize: array[0..3] of Integer = (0, 1, 2, 4);
  ColSize: array[0..7] of Integer = (0, 0, 0, 0, 2, 2, 2, 4);
  NrmSize: array[0..3] of Integer = (0, 1, 2, 4);
  WgtSize: array[0..3] of Integer = (0, 1, 2, 4);

procedure TPSPGEEngine.SetupVertexFormat(VType: Cardinal);
begin
  if FVertexFormatValid and (FVertexFormatKey = VType) then
    Exit;
  FVertexFormatKey := VType;
  FVertexFormatValid := True;
  var Tc := VType and 3;
  var Col := (VType shr 2) and 7;
  var Nrm := (VType shr 5) and 3;
  var Pos := (VType shr 7) and 3;
  var Wgt := (VType shr 9) and 3;
  var WCount := Integer((VType shr 14) and 7) + 1;
  var Off := 0;
  var MaxAlign := 1;
  if Wgt <> 0 then
  begin
    Off := WgtSize[Wgt] * WCount;
    MaxAlign := Max(MaxAlign, WgtSize[Wgt]);
  end;
  if Tc <> 0 then
  begin
    Off := (Off + TCSize[Tc] - 1) and not (TCSize[Tc] - 1);
    FOffTC := Off;
    Inc(Off, TCSize[Tc] * 2);
    MaxAlign := Max(MaxAlign, TCSize[Tc]);
  end;
  if Col <> 0 then
  begin
    var S := ColSize[Col];
    if S = 0 then
      S := 1;
    Off := (Off + S - 1) and not (S - 1);
    FOffC := Off;
    Inc(Off, ColSize[Col]);
    MaxAlign := Max(MaxAlign, S);
  end;
  if Nrm <> 0 then
  begin
    Off := (Off + NrmSize[Nrm] - 1) and not (NrmSize[Nrm] - 1);
    FOffN := Off;
    Inc(Off, NrmSize[Nrm] * 3);
    MaxAlign := Max(MaxAlign, NrmSize[Nrm]);
  end;
  if Pos <> 0 then
  begin
    Off := (Off + NrmSize[Pos] - 1) and not (NrmSize[Pos] - 1);
    FOffP := Off;
    Inc(Off, NrmSize[Pos] * 3);
    MaxAlign := Max(MaxAlign, NrmSize[Pos]);
  end;
  FVSize := (Off + MaxAlign - 1) and not (MaxAlign - 1);
end;

// A vertex's bytes: from its host memory where it lies in RAM (P), else
// through TPSPMemory (faults, held pages).
function VB(P: PByte; M: TPSPMemory; Addr, Off: Cardinal): Cardinal; inline;
begin
  if P <> nil then
    Result := P[Off]
  else
    Result := M.Read8(Addr + Off);
end;

function VH(P: PByte; M: TPSPMemory; Addr, Off: Cardinal): Cardinal; inline;
begin
  if P <> nil then
    Result := PWord(P + Off)^
  else
    Result := M.Read16(Addr + Off);
end;

function VW(P: PByte; M: TPSPMemory; Addr, Off: Cardinal): Cardinal; inline;
begin
  if P <> nil then
    Result := PCardinal(P + Off)^
  else
    Result := M.Read32(Addr + Off);
end;

function VF(P: PByte; M: TPSPMemory; Addr, Off: Cardinal): Single; inline;
begin
  var Bits := VW(P, M, Addr, Off);
  Result := PSingle(@Bits)^;
end;

const
  // Fixed point fractions by multiplying with the power of two (exact, as
  // the division was).
  VInv128: Double = 1 / 128;
  VInv32768: Double = 1 / 32768;

procedure TPSPGEEngine.DecodeVertex(Addr, VType: Cardinal; out V: TGEInVertex);
begin
  DecodeVertexWith(Addr, VType, V, FLastU, FLastV, FLastN);
end;

// LastU, LastV and LastN: the texture coordinates and normal the last vertex
// read had (formats without them take those).
procedure TPSPGEEngine.DecodeVertexWith(Addr, VType: Cardinal; out V: TGEInVertex; var LastU, LastV: Single; var LastN: TGEVec3);
var
  M: TPSPMemory;
  Through: Boolean;
  P: PByte;
begin
  M := FMemory;
  P := nil;
  var Physical := Addr and $1FFFFFFF;
  if (FRAMBase <> nil) and (Physical >= PSPRAMBase) and (Physical - PSPRAMBase <= PSPRAMSize - Cardinal(FVSize)) then
    P := FRAMBase + (Physical - PSPRAMBase);
  // (Default(TGEInVertex) without REP STOS: all its bytes zero.)
  var Q: PUInt64 := @V;
  for var I := 1 to SizeOf(TGEInVertex) div 8 do
  begin
    Q^ := 0;
    Inc(Q);
  end;
  if SizeOf(TGEInVertex) mod 8 <> 0 then
    PCardinal(PByte(@V) + SizeOf(TGEInVertex) - 4)^ := 0;
  Through := (VType and (1 shl 23)) <> 0;
  var Tc := VType and 3;
  var Col := (VType shr 2) and 7;
  var Nrm := (VType shr 5) and 3;
  var Pos := (VType shr 7) and 3;
  var Wgt := (VType shr 9) and 3;
  var WCount := Integer((VType shr 14) and 7) + 1;
  if Wgt <> 0 then
    for var I := 0 to WCount - 1 do
      case Wgt of
        1:
          V.Weights[I] := VB(P, M, Addr, Cardinal(I)) * VInv128;
        2:
          V.Weights[I] := VH(P, M, Addr, Cardinal(I * 2)) * VInv32768;
        3:
          V.Weights[I] := VF(P, M, Addr, Cardinal(I * 4));
      end;
  var TA := Cardinal(FOffTC);
  case Tc of
    0:
      begin
        // Formats without texture coordinates or normals use the last ones read.
        V.U := LastU;
        V.V := LastV;
      end;
    1:
      begin
        // Also in through mode, where they are texels / 128.
        V.U := VB(P, M, Addr, TA) * VInv128;
        V.V := VB(P, M, Addr, TA + 1) * VInv128;
      end;
    2:
      begin
        V.U := VH(P, M, Addr, TA);
        V.V := VH(P, M, Addr, TA + 2);
        if not Through then
        begin
          V.U := V.U * VInv32768;
          V.V := V.V * VInv32768;
        end;
      end;
    3:
      begin
        V.U := VF(P, M, Addr, TA);
        V.V := VF(P, M, Addr, TA + 4);
      end;
  end;
  LastU := V.U;
  LastV := V.V;
  if Col >= 4 then
  begin
    V.HasColor := True;
    var CA := Cardinal(FOffC);
    case Col of
      4:
        begin
          var C := VH(P, M, Addr, CA);
          var R := C and $1F;
          var G := (C shr 5) and $3F;
          var B := (C shr 11) and $1F;
          V.R := (R shl 3) or (R shr 2);
          V.G := (G shl 2) or (G shr 4);
          V.B := (B shl 3) or (B shr 2);
          V.A := 255;
        end;
      5:
        begin
          var C := VH(P, M, Addr, CA);
          var R := C and $1F;
          var G := (C shr 5) and $1F;
          var B := (C shr 10) and $1F;
          V.R := (R shl 3) or (R shr 2);
          V.G := (G shl 3) or (G shr 2);
          V.B := (B shl 3) or (B shr 2);
          V.A := Ord((C and $8000) <> 0) * 255;
        end;
      6:
        begin
          var C := VH(P, M, Addr, CA);
          V.R := (C and $F) * 17;
          V.G := ((C shr 4) and $F) * 17;
          V.B := ((C shr 8) and $F) * 17;
          V.A := ((C shr 12) and $F) * 17;
        end;
      7:
        begin
          var C := VW(P, M, Addr, CA);
          V.R := C and $FF;
          V.G := (C shr 8) and $FF;
          V.B := (C shr 16) and $FF;
          V.A := C shr 24;
        end;
    end;
  end;
  if Nrm <> 0 then
  begin
    var NA := Cardinal(FOffN);
    case Nrm of
      1:
        begin
          V.N.X := ShortInt(VB(P, M, Addr, NA)) * VInv128;
          V.N.Y := ShortInt(VB(P, M, Addr, NA + 1)) * VInv128;
          V.N.Z := ShortInt(VB(P, M, Addr, NA + 2)) * VInv128;
        end;
      2:
        begin
          V.N.X := SmallInt(VH(P, M, Addr, NA)) * VInv32768;
          V.N.Y := SmallInt(VH(P, M, Addr, NA + 2)) * VInv32768;
          V.N.Z := SmallInt(VH(P, M, Addr, NA + 4)) * VInv32768;
        end;
      3:
        begin
          V.N.X := VF(P, M, Addr, NA);
          V.N.Y := VF(P, M, Addr, NA + 4);
          V.N.Z := VF(P, M, Addr, NA + 8);
        end;
    end;
    LastN := V.N;
  end
  else
    V.N := LastN;
  if Pos <> 0 then
  begin
    var PA := Cardinal(FOffP);
    case Pos of
      1:
        // Through mode has no 8-bit positions: they read as the origin.
        if not Through then
        begin
          V.P.X := ShortInt(VB(P, M, Addr, PA)) * VInv128;
          V.P.Y := ShortInt(VB(P, M, Addr, PA + 1)) * VInv128;
          V.P.Z := ShortInt(VB(P, M, Addr, PA + 2)) * VInv128;
        end;
      2:
        if Through then
        begin
          V.P.X := SmallInt(VH(P, M, Addr, PA));
          V.P.Y := SmallInt(VH(P, M, Addr, PA + 2));
          V.P.Z := VH(P, M, Addr, PA + 4);
        end
        else
        begin
          V.P.X := SmallInt(VH(P, M, Addr, PA)) * VInv32768;
          V.P.Y := SmallInt(VH(P, M, Addr, PA + 2)) * VInv32768;
          V.P.Z := SmallInt(VH(P, M, Addr, PA + 4)) * VInv32768;
        end;
      3:
        begin
          V.P.X := VF(P, M, Addr, PA);
          V.P.Y := VF(P, M, Addr, PA + 4);
          V.P.Z := VF(P, M, Addr, PA + 8);
        end;
    end;
  end;
end;

function TPSPGEEngine.ReadVertex(Index: Integer; VType: Cardinal; out V: TGEInVertex): Boolean;
begin
  var Morphs := Integer((VType shr 18) and 7) + 1;
  var Base := Regs.VAddr + Cardinal(Index * FVSize * Morphs);
  if Morphs = 1 then
  begin
    DecodeVertex(Base, VType, V);
    Exit(True);
  end;
  V := Default(TGEInVertex);
  var CR, CG, CB, CA: Single;
  CR := 0;
  CG := 0;
  CB := 0;
  CA := 0;
  for var M := 0 to Morphs - 1 do
  begin
    var W := GEFloat(Regs.Cmd[GE_MORPHWEIGHT0 + M]);
    var T: TGEInVertex;
    DecodeVertex(Base + Cardinal(M * FVSize), VType, T);
    V.U := V.U + T.U * W;
    V.V := V.V + T.V * W;
    V.N.X := V.N.X + T.N.X * W;
    V.N.Y := V.N.Y + T.N.Y * W;
    V.N.Z := V.N.Z + T.N.Z * W;
    V.P.X := V.P.X + T.P.X * W;
    V.P.Y := V.P.Y + T.P.Y * W;
    V.P.Z := V.P.Z + T.P.Z * W;
    CR := CR + T.R * W;
    CG := CG + T.G * W;
    CB := CB + T.B * W;
    CA := CA + T.A * W;
    V.HasColor := T.HasColor;
    for var I := 0 to 7 do
      V.Weights[I] := V.Weights[I] + T.Weights[I] * W;
  end;
  V.R := EnsureRange(Trunc(CR), 0, 255);
  V.G := EnsureRange(Trunc(CG), 0, 255);
  V.B := EnsureRange(Trunc(CB), 0, 255);
  V.A := EnsureRange(Trunc(CA), 0, 255);
  Result := True;
end;

{ Transform and lighting }

function Color24(C: Cardinal; out R, G, B: Integer): Boolean; inline;
begin
  R := C and $FF;
  G := (C shr 8) and $FF;
  B := (C shr 16) and $FF;
  Result := True;
end;

procedure TPSPGEEngine.Skin(const V: TGEInVertex; VType: Cardinal; var P, N: TGEVec3);
var
  KX, KY, KZ, TX, TY, TZ, W: Single;
  I, Bo, WCount: Integer;
begin
  WCount := Integer((VType shr 14) and 7) + 1;
  if not FGeomValid then
    PrepareGeometry;
  if FGeom.BoneCount < WCount * 12 then
    PrepareBones(WCount * 12);
  KX := 0;
  KY := 0;
  KZ := 0;
  TX := 0;
  TY := 0;
  TZ := 0;
  for I := 0 to WCount - 1 do
  begin
    W := V.Weights[I];
    Bo := I * 12;
    var M: PGESingle12 := @FGeom.Bone[Bo];
    KX := KX + W * (M[0] * P.X + M[3] * P.Y + M[6] * P.Z + M[9]);
    KY := KY + W * (M[1] * P.X + M[4] * P.Y + M[7] * P.Z + M[10]);
    KZ := KZ + W * (M[2] * P.X + M[5] * P.Y + M[8] * P.Z + M[11]);
    TX := TX + W * (M[0] * N.X + M[3] * N.Y + M[6] * N.Z);
    TY := TY + W * (M[1] * N.X + M[4] * N.Y + M[7] * N.Z);
    TZ := TZ + W * (M[2] * N.X + M[5] * N.Y + M[8] * N.Z);
  end;
  P.X := KX;
  P.Y := KY;
  P.Z := KZ;
  N.X := TX;
  N.Y := TY;
  N.Z := TZ;
end;

// (M: a matrix's GEFloats.)
function MulPoint(const M: TGESingle12; const P: TGEVec3): TGEVec3;
begin
  Result.X := M[0] * P.X + M[3] * P.Y + M[6] * P.Z + M[9];
  Result.Y := M[1] * P.X + M[4] * P.Y + M[7] * P.Z + M[10];
  Result.Z := M[2] * P.X + M[5] * P.Y + M[8] * P.Z + M[11];
end;

function MulDir(const M: TGESingle12; const P: TGEVec3): TGEVec3;
begin
  Result.X := M[0] * P.X + M[3] * P.Y + M[6] * P.Z;
  Result.Y := M[1] * P.X + M[4] * P.Y + M[7] * P.Z;
  Result.Z := M[2] * P.X + M[5] * P.Y + M[8] * P.Z;
end;

function Normalized(const P: TGEVec3): TGEVec3;
var
  L: Single;
begin
  L := Sqrt(P.X * P.X + P.Y * P.Y + P.Z * P.Z);
  if L > 0 then
  begin
    Result.X := P.X / L;
    Result.Y := P.Y / L;
    Result.Z := P.Z / L;
  end
  else
    Result := P;
end;

{ The vertex unit's arithmetic: 24-bit floats (a 16-bit significand),
  truncated after every operation; an add first truncates both terms to the
  precision of the larger one. }

function T24Special(V: Double): Double;
var
  E: Integer;
  M: Double;
begin
  if (V = 0) or IsNan(V) or IsInfinite(V) then
    Exit(V);
  Frexp(V, M, E);
  // |M| in [0.5, 1): 16 significant bits.
  Result := Ldexp(Int(M * 65536), E - 16);
end;

function T24(V: Double): Double; inline;
begin
  // A normal double: the significand cut to 16 bits (toward zero) in its
  // bits; the rest through Frexp and Ldexp.
  var Bits := PUInt64(@V)^;
  var X := (Bits shr 52) and $7FF;
  if (X <> 0) and (X <> $7FF) then
  begin
    Bits := Bits and UInt64($FFFFFFE000000000);
    Result := PDouble(@Bits)^;
  end
  else
    Result := T24Special(V);
end;

function Exp24(V: Double): Integer; inline;
var
  M: Double;
begin
  var X := Integer((PUInt64(@V)^ shr 52) and $7FF);
  if (X <> 0) and (X <> $7FF) then
    Exit(X - 1022);
  Frexp(V, M, Result);
end;

// Zeros, subnormals, infinities, NaNs and exponents far out.
function Add24Slow(A, B: Double): Double;
begin
  if A = 0 then
    Exit(T24(B));
  if B = 0 then
    Exit(T24(A));
  var E := Max(Exp24(A), Exp24(B));
  var Ulp := Ldexp(1, E - 16);
  Result := T24(Int(A / Ulp) * Ulp + Int(B / Ulp) * Ulp);
end;

function Add24(A, B: Double): Double; inline;
begin
  // Both normal and the larger one's ulp a Single's power of two (Ldexp(1,
  // ..) in Add24Slow): both cut at the larger one's 16th bit in their bits
  // (the smaller to fewer bits, or nothing); the sum is exact.
  var BA := PUInt64(@A)^;
  var BB := PUInt64(@B)^;
  var XA := Integer((BA shr 52) and $7FF);
  var XB := Integer((BB shr 52) and $7FF);
  var X := XA;
  if XB > X then
    X := XB;
  if (XA <> 0) and (XB <> 0) and (X >= 889) and (X <= 1165) then
  begin
    var TA: Double := 0;
    var TB: Double := 0;
    var KA := 16 - (X - XA);
    var KB := 16 - (X - XB);
    if KA > 0 then
    begin
      BA := BA and not ((UInt64(1) shl (53 - KA)) - 1);
      TA := PDouble(@BA)^;
    end;
    if KB > 0 then
    begin
      BB := BB and not ((UInt64(1) shl (53 - KB)) - 1);
      TB := PDouble(@BB)^;
    end;
    Result := T24(TA + TB);
  end
  // (Add24Slow's zero cases, in its order.)
  else if (BA shl 1) = 0 then
    Result := T24(B)
  else if (BB shl 1) = 0 then
    Result := T24(A)
  else
    Result := Add24Slow(A, B);
end;

const
  // The vertex unit's reciprocal (recorded on a PSP-E1000: ge_xform's recip
  // set, every 24-bit float in [1, 4), the same in both octaves): for
  // 1 / (1 + F / 2^15), F a mantissa's 15 bits, segment F shr 8 starts at
  // GERecipNode (in 2^-17) and falls by GERecipSlope (in 2^-23) a step of F;
  // the result keeps 16 fraction bits, truncated (RecipMantissa).
  GERecipNode: array[0..127] of Integer = (
    131073, 130056, 129055, 128072, 127100, 126144, 125204, 124275, 123362, 122462,
    121575, 120701, 119837, 118987, 118151, 117324, 116509, 115705, 114914, 114131,
    113359, 112600, 111848, 111108, 110376, 109655, 108944, 108240, 107546, 106862,
    106185, 105518, 104859, 104207, 103564, 102928, 102301, 101681, 101068, 100464,
    99866, 99274, 98690, 98114, 97543, 96978, 96422, 95870, 95327, 94787,
    94256, 93728, 93208, 92692, 92183, 91681, 91181, 90689, 90202, 89718,
    89241, 88770, 88303, 87839, 87382, 86929, 86482, 86038, 85600, 85165,
    84733, 84308, 83886, 83469, 83056, 82647, 82242, 81840, 81443, 81050,
    80660, 80276, 79893, 79514, 79139, 78767, 78399, 78034, 77674, 77316,
    76961, 76609, 76261, 75915, 75575, 75235, 74899, 74565, 74237, 73909,
    73585, 73265, 72945, 72629, 72317, 72006, 71698, 71394, 71091, 70790,
    70494, 70198, 69907, 69616, 69328, 69043, 68760, 68480, 68201, 67926,
    67651, 67379, 67110, 66842, 66578, 66314, 66053, 65794);
  GERecipSlope: array[0..127] of Byte = (
    254, 250, 246, 243, 239, 235, 232, 228, 225, 222, 219, 216, 212, 209, 207, 204,
    201, 198, 196, 193, 190, 188, 185, 183, 180, 178, 176, 173, 171, 169, 167, 165,
    163, 161, 159, 157, 155, 153, 151, 150, 148, 146, 144, 143, 141, 139, 138, 136,
    135, 133, 132, 130, 129, 127, 126, 125, 123, 122, 121, 119, 118, 117, 116, 114,
    113, 112, 111, 110, 109, 108, 106, 105, 104, 103, 102, 101, 100, 99, 98, 97,
    96, 96, 95, 94, 93, 92, 91, 90, 90, 89, 88, 87, 86, 85, 85, 84,
    83, 82, 82, 81, 80, 80, 79, 78, 78, 77, 76, 76, 75, 74, 74, 73,
    73, 72, 71, 71, 70, 70, 69, 69, 68, 67, 67, 66, 66, 65, 65, 64);

// 1 / (1 + F / 2^15) in 2^-16: 32769..65536.
function RecipMantissa(F: Integer): Integer; inline;
begin
  var I := F shr 8;
  Result := (64 * GERecipNode[I] - GERecipSlope[I] * (F and 255) - 1) shr 7;
end;

// The GE's 1/x from the table, of the top 15 mantissa bits.
function Recip24Slow(V: Double): Double;
var
  M: Double;
  E: Integer;
begin
  if V = 0 then
    Exit(Infinity);
  if IsNan(V) or IsInfinite(V) then
    Exit(0);
  Frexp(Abs(V), M, E);
  M := M * 2;
  Dec(E);
  Result := T24(Ldexp(RecipMantissa(Trunc((M - 1) * 32768)), -16 - E));
  if V < 0 then
    Result := -Result;
end;

function Recip24(V: Double): Double;
begin
  // A normal V whose reciprocal is normal: the mantissa's bits and the power
  // of two (2^(1023 - X - 16)) from its bits; else Recip24Slow.
  var Bits := PUInt64(@V)^;
  var X := Integer((Bits shr 52) and $7FF);
  if (X < 64) or (X > 1980) then
    Exit(Recip24Slow(V));
  var Scale := UInt64(2030 - X) shl 52;
  Result := RecipMantissa(Integer((Bits shr 37) and $7FFF)) * PDouble(@Scale)^;
  if (Bits shr 63) <> 0 then
    Result := -Result;
end;

// Floor of a Double within the Integer range (Math.Floor's result).
function FloorInt(D: Double): Integer; inline;
begin
  Result := Integer(Trunc(D));
  if Result > D then
    Dec(Result);
end;

// Max and Min of Singles as System.Math's (NaN in A, the signs of zeros).
function MaxS(A, B: Single): Single; inline;
begin
  if A <> B then
  begin
    if (PCardinal(@A)^ and $7FFFFFFF) <= $7F800000 then
      if B < A then
        Result := A
      else
        Result := B
    else
      Result := A;
  end
  else if (PCardinal(@B)^ shr 31) <> 0 then
    Result := A
  else
    Result := B;
end;

function MinS(A, B: Single): Single; inline;
begin
  if A <> B then
  begin
    if (PCardinal(@A)^ and $7FFFFFFF) <= $7F800000 then
      if A < B then
        Result := A
      else
        Result := B
    else
      Result := A;
  end
  else if (PCardinal(@A)^ shr 31) <> 0 then
    Result := A
  else
    Result := B;
end;

type
  // A matrix row as the vertex unit uses it: three factors and the term added.
  TGERow24 = array[0..3] of Double;

  PGERow24 = ^TGERow24;

// Count rows times (X, Y, Z): Add24(T24(M0 * X + M1 * Y + M2 * Z), T) each.
procedure Rows24Pascal(Rows: PGERow24; X, Y, Z: Double; Res: PDouble; Count: Integer);
begin
  for var I := 0 to Count - 1 do
  begin
    Res^ := Add24(T24(Rows[0] * X + Rows[1] * Y + Rows[2] * Z), Rows[3]);
    Inc(Rows);
    Inc(Res);
  end;
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
// The same in registers, for terms both normal within Add24's fast range (or
// a zero term); False where some row is not (Res then undefined): Rows24Pascal.
function Rows24Fast(Rows: PGERow24; X, Y, Z: Double; Res: PDouble; Count: Integer): Boolean;
asm
        .       NOFRAME
  // RCX Rows, XMM1..XMM3 X, Y, Z, [RSP+40] Res, [RSP+48] Count.
        MOV     R11, RCX
        MOV     R10, [RSP + 40]

@@Row:
        MOVSD   XMM0, [R11]
        MULSD   XMM0, XMM1
        MOVSD   XMM4, [R11 + 8]
        MULSD   XMM4, XMM2
        ADDSD   XMM0, XMM4
        MOVSD   XMM4, [R11 + 16]
        MULSD   XMM4, XMM3
        ADDSD   XMM0, XMM4
  // A := T24 of the sum (normal), XA its exponent.
        MOVQ    RAX, XMM0
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@Slow
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     R8, $FFFFFFE000000000
        AND     RAX, R8
  // B := the term, XB its exponent; a zero term adds nothing (T24(A)).
        MOV     R8, [R11 + 24]
        MOV     R9, R8
        ADD     R9, R9
        JZ      @@BZero
        MOV     R9, R8
        SHR     R9, 52
        AND     R9D, $7FF
        JZ      @@Slow
  // X := Max(XA, XB) in 889..1165; each cut below the larger one's 16th bit.
        MOV     ECX, EDX
        CMP     R9D, ECX
        JLE     @@Max
        MOV     ECX, R9D

@@Max:
        CMP     ECX, 889
        JL      @@Slow
        CMP     ECX, 1165
        JG      @@Slow
        SUB     EDX, ECX
        NEG     EDX
        SUB     R9D, ECX
        NEG     R9D
        CMP     EDX, 16
        JGE     @@AZero
        LEA     RCX, [RDX + 37]
        SHR     RAX, CL
        SHL     RAX, CL
        MOVQ    XMM0, RAX
        JMP     @@ADone

@@AZero:
        XORPD   XMM0, XMM0

@@ADone:
        CMP     R9D, 16
        JGE     @@BCut
        LEA     RCX, [R9 + 37]
        SHR     R8, CL
        SHL     R8, CL
        MOVQ    XMM4, R8
        JMP     @@BDone

@@BCut:
        XORPD   XMM4, XMM4

@@BDone:
        ADDSD   XMM0, XMM4
  // T24 of the sum: a zero is itself; else normal (the range keeps it so).
        MOVQ    RAX, XMM0
        MOV     RDX, RAX
        ADD     RDX, RDX
        JZ      @@Store
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@Slow
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     RDX, $FFFFFFE000000000
        AND     RAX, RDX
        MOVQ    XMM0, RAX
        JMP     @@Store

@@BZero:
        MOVQ    XMM0, RAX

@@Store:
        MOVSD   [R10], XMM0
        ADD     R10, 8
        ADD     R11, 32
        DEC     DWORD PTR[RSP + 48]
        JNZ     @@Row
        MOV     EAX, 1
        RET

@@Slow:
        XOR     EAX, EAX
end;
{$ENDIF}

// The older model (every row's dot product exact, then truncated, then the
// term added with Add24), kept for values outside Rows24's normal range.

procedure Rows24Old(Rows: PGERow24; X, Y, Z: Double; Res: PDouble; Count: Integer); inline;
begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if not Rows24Fast(Rows, X, Y, Z, Res, Count) then
{$ENDIF}
    Rows24Pascal(Rows, X, Y, Z, Res, Count);
end;

// The vertex unit's matrix rows (recorded on a PSP-E1000 through the depth
// it writes, probe ge_xform): a product keeps its bits down to
// 2^(ea + eb - 15) (ea, eb the factors' exponents), truncated; a row's terms
// (three products and the term added) are truncated at the quantum of the
// largest of them and summed, the sum cut to 16 bits. Normal or zero values
// only (Exact24 says): others go through Rows24Old.

function Exact24(V: Double): Boolean; inline;
begin
  var X := (PUInt64(@V)^ shr 52) and $7FF;
  Result := ((X <> 0) and (X <> $7FF) and (X > 1023 - 900) and (X < 1023 + 900)) or ((PUInt64(@V)^ shl 1) = 0);
end;

// 2^E for E well inside the normal range.
function Pow2(E: Integer): Double; inline;
begin
  var Bits := UInt64(E + 1023) shl 52;
  Result := PDouble(@Bits)^;
end;

function Exponent(V: Double): Integer; inline;
begin
  Result := Integer((PUInt64(@V)^ shr 52) and $7FF) - 1023;
end;

function TruncPow2Slow(V: Double; Q: Integer): Double;
const
  One: Double = 1;
begin
  var P := Ldexp(One, Q);
  Result := Int(V / P) * P;
end;

// Int(V / 2^Q) * 2^Q: V cut toward zero to a multiple of 2^Q, in its bits
// for a normal V and Q (zeros, infinities and NaNs are themselves;
// subnormals and the rest as stated).
function TruncPow2(V: Double; Q: Integer): Double; inline;
begin
  var Bits := PUInt64(@V)^;
  var X := Integer((Bits shr 52) and $7FF);
  if (X = 0) or (X = $7FF) or (Q < -1000) or (Q > 1000) then
  begin
    if (X = $7FF) or ((Bits shl 1) = 0) then
      Exit(V);
    Exit(TruncPow2Slow(V, Q));
  end;
  var Keep := X - 1023 - Q;
  if Keep >= 52 then
    Exit(V);
  if Keep < 0 then
    Bits := Bits and UInt64($8000000000000000)
  else
    Bits := Bits and not ((UInt64(1) shl (52 - Keep)) - 1);
  Result := PDouble(@Bits)^;
end;

// One term of a row: its value (exact) and its quantum's exponent.
type
  TGETerm24 = record
    V: Double;
    Q: Integer;
  end;

function Product24(A, B: Double): TGETerm24; inline;
begin
  if (A = 0) or (B = 0) then
  begin
    Result.V := 0;
    Result.Q := 0;
    Exit;
  end;
  Result.Q := Exponent(A) + Exponent(B) - 15;
  Result.V := TruncPow2(A * B, Result.Q);
end;

function Term24(A: Double): TGETerm24; inline;
begin
  Result.V := A;
  if A = 0 then
    Result.Q := 0
  else
    Result.Q := Exponent(A) - 15;
end;

function Sum24(const T0, T1, T2, T3: TGETerm24): Double;
begin
  var L := T0;
  if Abs(T1.V) > Abs(L.V) then
    L := T1;
  if Abs(T2.V) > Abs(L.V) then
    L := T2;
  if Abs(T3.V) > Abs(L.V) then
    L := T3;
  if L.V = 0 then
    Exit(0);
  Result := T24(TruncPow2(T0.V, L.Q) + TruncPow2(T1.V, L.Q) + TruncPow2(T2.V, L.Q) + TruncPow2(T3.V, L.Q));
end;

// The vector from a vertex to a positional light (L the light's coordinate,
// Row the world matrix's row, X, Y, Z the model position) as the vertex unit
// forms it, a row of its own (recorded on a PSP-E1000, probe ge_wpos2: every
// one of 2,176 rows of distances to the last bit, where the world position
// less the light left 21-37%): the translation less the light coordinate (both
// cut toward zero at the larger's 16th bit, the difference to a 24-bit float)
// is the row's term; the products (Product24) and it are cut at the largest
// quantum among them (not the largest value's), summed and cut to a 24-bit
// float; the vector is its negation.
function LightRow24(const Row: TGERow24; X, Y, Z, L: Double): Double;
var
  T: array[0..3] of TGETerm24;
begin
  var D: Double;
  if Row[3] = 0 then
    D := T24(-L)
  else if L = 0 then
    D := T24(Row[3])
  else
  begin
    var QL := Max(Exponent(Row[3]), Exponent(L)) - 15;
    D := T24(TruncPow2(Row[3], QL) - TruncPow2(L, QL));
  end;
  T[0] := Product24(Row[0], X);
  T[1] := Product24(Row[1], Y);
  T[2] := Product24(Row[2], Z);
  T[3] := Term24(D);
  var Any := False;
  var Q := 0;
  for var I := 0 to 3 do
    if T[I].V <> 0 then
    begin
      if not Any or (T[I].Q > Q) then
        Q := T[I].Q;
      Any := True;
    end;
  if not Any then
    Exit(0);
  Result := -T24(TruncPow2(T[0].V, Q) + TruncPow2(T[1].V, Q) + TruncPow2(T[2].V, Q) + TruncPow2(T[3].V, Q));
end;

function Row24(const Row: TGERow24; X, Y, Z: Double): Double; inline;
begin
  Result := Sum24(Product24(Row[0], X), Product24(Row[1], Y), Product24(Row[2], Z), Term24(Row[3]));
end;

{ Sum24 of three products and a term in the values' bits, for normal values
  (or zeros) of exponents within 400 of 0: every product and sum then stays
  well inside the double's normal range, and the cuts are those of
  Product24, Term24 and Sum24 without their records and calls. }

const
  SignBit64 = UInt64($8000000000000000);
  MagBits64 = UInt64($7FFFFFFFFFFFFFFF);

function Small24(V: Double): Boolean; inline;
begin
  var X := (PUInt64(@V)^ shr 52) and $7FF;
  Result := ((X > 1023 - 400) and (X < 1023 + 400)) or ((PUInt64(@V)^ shl 1) = 0);
end;

// Product24's value (bits) and quantum: a zero factor gives +0 and 0.
procedure ProductBits(A, B: Double; out Bits: UInt64; out Q: Integer); inline;
begin
  var BA := PUInt64(@A)^;
  var BB := PUInt64(@B)^;
  if ((BA shl 1) = 0) or ((BB shl 1) = 0) then
  begin
    Bits := 0;
    Q := 0;
    Exit;
  end;
  var P := A * B;
  var BP := PUInt64(@P)^;
  Q := Integer((BA shr 52) and $7FF) + Integer((BB shr 52) and $7FF) - 2046 - 15;
  // 15 or 16 bits below the leading one.
  var Keep := Integer((BP shr 52) and $7FF) - 1023 - Q;
  Bits := BP and not ((UInt64(1) shl (52 - Keep)) - 1);
end;

// TruncPow2 of a normal value or a zero (in bits) at 2^Q.
function CutBits(Bits: UInt64; Q: Integer): Double; inline;
begin
  if (Bits shl 1) <> 0 then
  begin
    var Keep := Integer((Bits shr 52) and $7FF) - 1023 - Q;
    if Keep < 0 then
      Bits := Bits and SignBit64
    else if Keep < 52 then
      Bits := Bits and not ((UInt64(1) shl (52 - Keep)) - 1);
  end;
  Result := PDouble(@Bits)^;
end;

// Sum24(Product24(A0, B0), Product24(A1, B1), Product24(A2, B2), Term24(T))
// for Small24 values.
function Dot24Bits(A0, B0, A1, B1, A2, B2, T: Double): Double;
var
  V0, V1, V2, V3: UInt64;
  Q0, Q1, Q2, Q3: Integer;
begin
  ProductBits(A0, B0, V0, Q0);
  ProductBits(A1, B1, V1, Q1);
  ProductBits(A2, B2, V2, Q2);
  V3 := PUInt64(@T)^;
  if (V3 shl 1) = 0 then
    Q3 := 0
  else
    Q3 := Integer((V3 shr 52) and $7FF) - 1023 - 15;
  // The largest magnitude, the first of equal ones, gives the quantum.
  var L := V0 and MagBits64;
  var Q := Q0;
  if (V1 and MagBits64) > L then
  begin
    L := V1 and MagBits64;
    Q := Q1;
  end;
  if (V2 and MagBits64) > L then
  begin
    L := V2 and MagBits64;
    Q := Q2;
  end;
  if (V3 and MagBits64) > L then
  begin
    L := V3 and MagBits64;
    Q := Q3;
  end;
  if L = 0 then
    Exit(0);
  Result := T24(CutBits(V0, Q) + CutBits(V1, Q) + CutBits(V2, Q) + CutBits(V3, Q));
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
// Dot24Bits(Row[0], X, Row[1], Y, Row[2], Z, Row[3]) in registers, for
// Small24 values (the same steps in the same order).
function Row24Asm(Row: PGERow24; X, Y, Z: Double): Double;
asm
        .       PUSHNV RBX
        .       PUSHNV RSI
        .       PUSHNV RDI
        .       PUSHNV R12
        .       PUSHNV R13
        .       PUSHNV R14
  // RCX Row (kept in RSI), XMM1..XMM3 X, Y, Z. Terms in R8..R11, quanta in
  // EBX, EDI, R12D, R13D.
        MOV     RSI, RCX
{$I PSP.GE.Row24.inc}
@@RowResult:
end;

// Rows24's fast path for Count rows, X, Y and Z at XYZ: Row24Asm's steps,
// the registers saved once.
function Rows24Asm(Rows: PGERow24; Res: PDouble; Count: Integer; XYZ: PDouble): Boolean;
asm
        .       PUSHNV RBX
        .       PUSHNV RSI
        .       PUSHNV RDI
        .       PUSHNV R12
        .       PUSHNV R13
        .       PUSHNV R14
        .       PUSHNV R15
  // RSI the row, R15 its result, XMM5 the rows' end; XMM1..XMM3 X, Y, Z.
        MOV     RSI, RCX
        MOV     R15, RDX
        MOV     EAX, R8D
        SHL     RAX, 5
        ADD     RAX, RCX
        MOVQ    XMM5, RAX
        MOVSD   XMM1, [R9]
        MOVSD   XMM2, [R9 + 8]
        MOVSD   XMM3, [R9 + 16]

@@Row:
{$I PSP.GE.Row24.inc}
@@RowResult:
        MOVSD   [R15], XMM0
        ADD     R15, 8
        ADD     RSI, 32
        MOVQ    RAX, XMM5
        CMP     RSI, RAX
        JB      @@Row
        MOV     EAX, 1
end;
{$ENDIF}

function Dot24(A0, B0, A1, B1, A2, B2, T: Double): Double;
begin
  if Small24(A0) and Small24(B0) and Small24(A1) and Small24(B1) and Small24(A2) and Small24(B2) and Small24(T) then
    Result := Dot24Bits(A0, B0, A1, B1, A2, B2, T)
  else
    Result := Sum24(Product24(A0, B0), Product24(A1, B1), Product24(A2, B2), Term24(T));
end;

// Every element of Count rows Small24.
function RowsSmall(Rows: PGERow24; Count: Integer): Boolean;
begin
  for var I := 0 to Count - 1 do
  begin
    if not (Small24(Rows[0]) and Small24(Rows[1]) and Small24(Rows[2]) and Small24(Rows[3])) then
      Exit(False);
    Inc(Rows);
  end;
  Result := True;
end;

// Small: RowsSmall of the rows (known beforehand).
procedure Rows24(Rows: PGERow24; X, Y, Z: Double; Res: PDouble; Count: Integer; Small: Boolean);
begin
  if Small and Small24(X) and Small24(Y) and Small24(Z) then
  begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    var XYZ: array[0..2] of Double;
    XYZ[0] := X;
    XYZ[1] := Y;
    XYZ[2] := Z;
    Rows24Asm(Rows, Res, Count, @XYZ[0]);
{$ELSE}
    for var I := 0 to Count - 1 do
    begin
      Res^ := Dot24Bits(Rows[0], X, Rows[1], Y, Rows[2], Z, Rows[3]);
      Inc(Rows);
      Inc(Res);
    end;
{$ENDIF}
    Exit;
  end;
  var Exact := Exact24(X) and Exact24(Y) and Exact24(Z);
  if Exact then
  begin
    var R := Rows;
    for var I := 0 to Count - 1 do
    begin
      if not (Exact24(R[0]) and Exact24(R[1]) and Exact24(R[2]) and Exact24(R[3])) then
      begin
        Exact := False;
        Break;
      end;
      Inc(R);
    end;
  end;
  if not Exact then
  begin
    Rows24Old(Rows, X, Y, Z, Res, Count);
    Exit;
  end;
  for var I := 0 to Count - 1 do
  begin
    Res^ := Row24(Rows^, X, Y, Z);
    Inc(Rows);
    Inc(Res);
  end;
end;

// The view times the world matrix (4x3, columns of three), as the vertex
// unit forms it before it transforms vertices: each element a row sum.
procedure CombineViewWorld(const View, World: array of Double; Rows: PGERow24);
begin
  for var R := 0 to 2 do
  begin
    for var J := 0 to 2 do
      Rows[J] := Sum24(Product24(View[R], World[3 * J]), Product24(View[3 + R], World[3 * J + 1]), Product24(View[6 +
              R], World[3 * J + 2]), Term24(0));
    Rows[3] := Sum24(Product24(View[R], World[9]), Product24(View[3 + R], World[10]), Product24(View[6 + R], World[11]),
        Term24(View[9 + R]));
    Inc(Rows);
  end;
end;

// Three clip coordinates (V) to the viewport (Port: scale and centre of x, y,
// z): Add24(T24(T24(V * RW) * Scale), Centre) each.
procedure Port24Pascal(V: PDouble; RW: Double; Port: PDouble; Res: PDouble);
begin
  for var I := 0 to 2 do
  begin
    Res^ := Add24(T24(T24(V^ * RW) * Port^), PDouble(PByte(Port) + 8)^);
    Inc(V);
    Inc(Port, 2);
    Inc(Res);
  end;
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
// The same in registers where every value on the way is normal or zero and
// the sums within Add24's fast range; False else (Res then undefined).
function Port24Fast(V: PDouble; RW: Double; Port: PDouble; Res: PDouble): Boolean;
asm
        .       NOFRAME
  // RCX V (kept in R10), XMM1 RW, R8 Port, R9 Res; the count in RCX's home.
        MOV     R10, RCX
        MOV     DWORD PTR[RSP + 8], 3

@@Value:
  // T24(V * RW): a normal one cut, a zero kept.
        MOVSD   XMM0, [R10]
        MULSD   XMM0, XMM1
        MOVQ    RAX, XMM0
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@Zero1
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     R11, $FFFFFFE000000000
        AND     RAX, R11
        JMP     @@Scale

@@Zero1:
        MOV     RDX, RAX
        ADD     RDX, RDX
        JNZ     @@Slow

@@Scale:
  // A := T24(that * Scale) in RAX, EDX its exponent (0: a zero).
        MOVQ    XMM0, RAX
        MULSD   XMM0, [R8]
        MOVQ    RAX, XMM0
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@Zero2
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     R11, $FFFFFFE000000000
        AND     RAX, R11
        JMP     @@Add

@@Zero2:
        MOV     RDX, RAX
        ADD     RDX, RDX
        JNZ     @@Slow

@@Add:
  // Add24(A, C), C the centre in R11.
        MOV     R11, [R8 + 8]
        TEST    EDX, EDX
        JZ      @@AZero
  // A zero C: T24(A), that is A.
        MOV     RCX, R11
        ADD     RCX, RCX
        JZ      @@Store
        MOV     RCX, R11
        SHR     RCX, 52
        AND     ECX, $7FF
        JZ      @@Slow
  // Both normal: X := Max(XA, XC) in 889..1165, each cut below the larger
  // one's 16th bit (A has no bits there).
        CMP     EDX, ECX
        JL      @@CLarger
        CMP     EDX, 889
        JL      @@Slow
        CMP     EDX, 1165
        JG      @@Slow
        SUB     EDX, ECX
        CMP     EDX, 16
        JGE     @@Store
        LEA     ECX, [EDX + 37]
        SHR     R11, CL
        SHL     R11, CL
        JMP     @@Sum

@@CLarger:
        CMP     ECX, 889
        JL      @@Slow
        CMP     ECX, 1165
        JG      @@Slow
        SUB     ECX, EDX
        MOV     RDX, $FFFFFFE000000000
        AND     R11, RDX
        CMP     ECX, 16
        JGE     @@OnlyC
        ADD     ECX, 37
        SHR     RAX, CL
        SHL     RAX, CL

@@Sum:
        MOVQ    XMM0, RAX
        MOVQ    XMM2, R11
        ADDSD   XMM0, XMM2
  // T24 of the sum: a zero is itself; else normal (the range keeps it so).
        MOVQ    RAX, XMM0
        MOV     RDX, RAX
        ADD     RDX, RDX
        JZ      @@Store
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@Slow
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     R11, $FFFFFFE000000000
        AND     RAX, R11
        JMP     @@Store

@@OnlyC:
        MOV     RAX, R11
        JMP     @@Store

@@AZero:
  // T24(C).
        MOV     RAX, R11
        MOV     RDX, RAX
        SHR     RDX, 52
        AND     EDX, $7FF
        JZ      @@CZero
        CMP     EDX, $7FF
        JE      @@Slow
        MOV     R11, $FFFFFFE000000000
        AND     RAX, R11
        JMP     @@Store

@@CZero:
        MOV     RDX, RAX
        ADD     RDX, RDX
        JNZ     @@Slow

@@Store:
        MOV     [R9], RAX
        ADD     R10, 8
        ADD     R8, 16
        ADD     R9, 8
        DEC     DWORD PTR[RSP + 8]
        JNZ     @@Value
        MOV     EAX, 1
        RET

@@Slow:
        XOR     EAX, EAX
end;
{$ENDIF}

procedure Port24(V: PDouble; RW: Double; Port: PDouble; Res: PDouble); inline;
begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if not Port24Fast(V, RW, Port, Res) then
{$ENDIF}
    Port24Pascal(V, RW, Port, Res);
end;

// A value as the GE's 24-bit floats hold it: 16 mantissa bits, truncated.
const
  // The lighting unit's 1/sqrt (recorded on a PSP-E1000, ge_dist: the light
  // straight above at every 24-bit float height of [1, 2), the distance read
  // from where linear attenuation steps along a sweep of KB): for
  // V = (1 + G / 2^15) 2^E, segment (E and 1) * 128 + G shr 8 starts at
  // GERSqrtNode (in 2^-23) and falls by GERSqrtSlope (in 2^-23) a step of G;
  // the result keeps 16 bits, truncated (RSqrt24). Each node within the
  // range the sweep allows, where ge_wpos's spot factors and ge_dist's random
  // offsets put it (56 above the range's foot).
  GERSqrtNode: array[0..255] of Integer = (
    8388671, 8356031, 8323836, 8292030, 8260543, 8229432, 8198654, 8168255, 8138172, 8108414,
    8078975, 8049844, 8021055, 7992574, 7964412, 7936511, 7908862, 7881599, 7854520, 7827775,
    7801278, 7775039, 7749116, 7723391, 7697918, 7672767, 7647776, 7623103, 7598588, 7574399,
    7550396, 7526588, 7503039, 7479678, 7456575, 7433656, 7410943, 7388479, 7366206, 7344127,
    7322236, 7300543, 7279039, 7257663, 7236543, 7215615, 7194864, 7174270, 7153854, 7133630,
    7113535, 7093631, 7073916, 7054335, 7034943, 7015678, 6996607, 6977663, 6958904, 6940280,
    6921791, 6903423, 6885246, 6867199, 6849279, 6831548, 6813884, 6796415, 6779071, 6761791,
    6744702, 6727743, 6710911, 6694172, 6677582, 6661119, 6644799, 6628542, 6612478, 6596478,
    6580607, 6564863, 6549180, 6533628, 6518207, 6502911, 6487679, 6472574, 6457598, 6442687,
    6427903, 6413176, 6398584, 6384120, 6369727, 6355455, 6341247, 6327102, 6313086, 6299198,
    6285375, 6271615, 6257980, 6244412, 6230908, 6217535, 6204223, 6191039, 6177918, 6164862,
    6151870, 6139006, 6126207, 6113471, 6100862, 6088240, 6075760, 6063344, 6051007, 6038783,
    6026559, 6014462, 6002428, 5990462, 5978558, 5966719, 5955007, 5943295, 5931647, 5908606,
    5885887, 5863358, 5841087, 5819132, 5797372, 5775871, 5754558, 5733503, 5712688, 5692159,
    5671742, 5651647, 5631679, 5611964, 5592447, 5573118, 5553983, 5535103, 5516344, 5497791,
    5479422, 5461246, 5443263, 5425468, 5407804, 5390335, 5373054, 5355902, 5338943, 5322111,
    5305422, 5288959, 5272575, 5256382, 5240382, 5224447, 5208703, 5193084, 5177599, 5162239,
    5147070, 5131966, 5117055, 5102207, 5087544, 5072953, 5058559, 5044223, 5030078, 5015998,
    5002046, 4988223, 4974463, 4960830, 4947388, 4933951, 4920703, 4907519, 4894462, 4881470,
    4868607, 4855871, 4843199, 4830640, 4818160, 4805823, 4793535, 4781311, 4769278, 4757246,
    4745342, 4733503, 4721791, 4710143, 4698620, 4687100, 4675708, 4664447, 4653183, 4642047,
    4630974, 4619966, 4609086, 4598270, 4587519, 4576831, 4566207, 4555647, 4545208, 4534840,
    4524479, 4514239, 4504063, 4493951, 4483902, 4473982, 4464062, 4454206, 4444415, 4434687,
    4425087, 4415487, 4405948, 4396476, 4387068, 4377724, 4368444, 4359231, 4350079, 4340927,
    4331903, 4322878, 4313982, 4305086, 4296254, 4287486, 4278719, 4270079, 4261439, 4252863,
    4244351, 4235874, 4227488, 4219104, 4210785, 4202528);
  GERSqrtSlope: array[0..255] of Byte = (
    127, 125, 124, 122, 121, 120, 118, 117, 116, 114, 113, 112, 111, 110, 108, 107,
    106, 105, 104, 103, 102, 101, 100, 99, 98, 97, 96, 95, 94, 93, 92, 92,
    91, 90, 89, 88, 87, 87, 86, 85, 84, 83, 83, 82, 81, 81, 80, 79,
    79, 78, 77, 77, 76, 75, 75, 74, 73, 73, 72, 72, 71, 71, 70, 69,
    69, 68, 68, 67, 67, 66, 66, 65, 65, 64, 64, 63, 63, 62, 62, 62,
    61, 61, 60, 60, 59, 59, 59, 58, 58, 57, 57, 56, 56, 56, 55, 55,
    55, 54, 54, 54, 53, 53, 52, 52, 52, 51, 51, 51, 50, 50, 50, 50,
    49, 49, 49, 48, 48, 48, 47, 47, 47, 47, 46, 46, 46, 45, 45, 45,
    89, 88, 87, 86, 85, 84, 84, 83, 82, 81, 80, 79, 78, 77, 77, 76,
    75, 74, 73, 73, 72, 71, 70, 70, 69, 68, 68, 67, 66, 66, 65, 65,
    64, 63, 63, 62, 62, 61, 61, 60, 59, 59, 58, 58, 57, 57, 56, 56,
    55, 55, 54, 54, 54, 53, 53, 52, 52, 51, 51, 51, 50, 50, 49, 49,
    49, 48, 48, 47, 47, 47, 46, 46, 46, 45, 45, 45, 44, 44, 44, 43,
    43, 43, 42, 42, 42, 42, 41, 41, 41, 40, 40, 40, 40, 39, 39, 39,
    38, 38, 38, 38, 37, 37, 37, 37, 36, 36, 36, 36, 36, 35, 35, 35,
    35, 34, 34, 34, 34, 34, 33, 33, 33, 33, 33, 32, 32, 32, 32, 32);

function RSqrt24(V: Double): Double;
var
  M: Double;
  E: Integer;
begin
  if not (V > 0) or IsInfinite(V) then
    Exit(0);
  // A normal V from its bits: the exponent and the top 15 mantissa bits.
  var Bits := PUInt64(@V)^;
  var X := Integer((Bits shr 52) and $7FF);
  if X <> 0 then
  begin
    var EN := X - 1023;
    var GN := Integer((Bits shr 37) and $7FFF);
    var OddN := EN and 1;
    var IN_ := OddN * 128 + (GN shr 8);
    Exit(((GERSqrtNode[IN_] - GERSqrtSlope[IN_] * (GN and 255)) shr 7) * Pow2(-16 - (EN - OddN) div 2));
  end;
  Frexp(V, M, E);
  M := M * 2;
  Dec(E);
  var G := Trunc((M - 1) * 32768);
  var Odd := E and 1;
  var I := Odd * 128 + (G shr 8);
  Result := Ldexp((GERSqrtNode[I] - GERSqrtSlope[I] * (G and 255)) shr 7, -16 - (E - Odd) div 2);
end;

// The squared length of (X, Y, Z), 24-bit floats, as the vertex unit's sum
// of products (Sum24).
function Length2F24(X, Y, Z: Double): Double;
begin
  Result := Dot24(X, X, Y, Y, Z, Z, 0);
end;

// Neither an infinity nor a NaN; a NaN.
function FiniteS(V: Single): Boolean; inline;
begin
  Result := (PCardinal(@V)^ and $7F800000) <> $7F800000;
end;

function NanS(V: Single): Boolean; inline;
begin
  Result := (PCardinal(@V)^ and $7FFFFFFF) > $7F800000;
end;

// Lighting's normal unit: cut the components to 24-bit floats, form their
// squared length as a sum of products and scale them by RSqrt24, cutting
// again. All 393,216 signed-axis factors of the raw-normal PSP sweep match.
function NormalF24(const P: TGEVec3): TGEVec3;
begin
  if not (FiniteS(P.X) and FiniteS(P.Y) and FiniteS(P.Z)) then
    Exit(Normalized(P));
  var X: Double := T24(P.X);
  var Y: Double := T24(P.Y);
  var Z: Double := T24(P.Z);
  var RS := RSqrt24(Length2F24(X, Y, Z));
  if RS = 0 then
    Exit(Normalized(P));
  Result.X := T24(X * RS);
  Result.Y := T24(Y * RS);
  Result.Z := T24(Z * RS);
end;

function F24(V: Single): Single; inline;
begin
  var Bits := PCardinal(@V)^ and $FFFFFF00;
  Result := PSingle(@Bits)^;
end;

// A square root truncated to a 24-bit float (not rounded to single first:
// a light 2.000061 away is 2 to the lighting unit).
function SqrtF24(V: Single): Single;
begin
  var D: Double := Sqrt(Double(V));
  var Bits := PUInt64(@D)^ and not ((UInt64(1) shl 37) - 1);
  Result := PDouble(@Bits)^;
end;

function NormalizedF24(const P: TGEVec3): TGEVec3;
var
  L: Single;
begin
  L := F24(P.X * P.X + P.Y * P.Y + P.Z * P.Z);
  if L > 0 then
  begin
    L := 1 / Sqrt(L);
    Result.X := P.X * L;
    Result.Y := P.Y * L;
    Result.Z := P.Z * L;
  end
  else
    Result := P;
end;

function Dot(const A, B: TGEVec3): Single; inline;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

// The spot cosine's dot product: align Product24's terms at the largest
// quantum, not the largest value's (as LightRow24). Recorded on a PSP-E1000:
// every factor in ge_wpos and ge_spot; the largest value's left eight
// ge_wpos factors one step off after the reciprocal-root table was refined.
function SpotDot24(const A, B: TGEVec3): Double;
var
  T: array[0..2] of TGETerm24;
begin
  T[0] := Product24(T24(A.X), B.X);
  T[1] := Product24(T24(A.Y), B.Y);
  T[2] := Product24(T24(A.Z), B.Z);
  var Any := False;
  var Q := 0;
  for var I := 0 to 2 do
    if T[I].V <> 0 then
    begin
      if not Any or (T[I].Q > Q) then
        Q := T[I].Q;
      Any := True;
    end;
  if not Any then
    Exit(0);
  Result := T24(TruncPow2(T[0].V, Q) + TruncPow2(T[1].V, Q) + TruncPow2(T[2].V, Q));
end;

function Vec3(X, Y, Z: Single): TGEVec3; inline;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Z := Z;
end;

function CmdVec(const C: TGECmds; Index: Integer): TGEVec3;
begin
  Result.X := GEFloat(C[Index]);
  Result.Y := GEFloat(C[Index + 1]);
  Result.Z := GEFloat(C[Index + 2]);
end;

// pow as the GE's lighting unit computes it: log2 and exp2 linear between powers of two.
function GEPow(X, E: Single): Single;
begin
  if not (X > 0) then
  begin
    if E = 0 then
      Exit(1);
    Exit(0);
  end;
  // X as a 24-bit float (ge_light's spot sweeps: exponent 10 and 3.7 exact,
  // where its full mantissa was off in 38 of 131,072).
  var Bits := PCardinal(@X)^ and $FFFFFF00;
  var L2: Double := Integer((Bits shr 23) and $FF) - 127 + (Bits and $7FFFFF) / 8388608.0;
  var Y: Double := L2 * E;
  if IsNan(Y) then
    Exit(1);
  if Y > 127 then
    Exit(Infinity);
  if Y < -127 then
    Exit(0);
  // Floor and Ldexp by an exact power of two (|F| <= 127, the product normal).
  var F := FloorInt(Y);
  var Scale := UInt64(1023 + F) shl 52;
  Result := (1 + (Y - F)) * PDouble(@Scale)^;
end;

function Byte8(C: Cardinal; Shift: Integer): Integer; inline;
begin
  Result := (C shr Shift) and $FF;
end;

// Lighting works in 8 bits (recorded on a PSP-E1000): a
// factor in [0, 1] (N.L, a power, the attenuation, the spot factor) becomes
// 256 times it, truncated, at most 255; two 8-bit values x and y multiply as
// (x + 1/2) (y + 1/2) / 256, truncated (so times 255 changes nothing); the
// terms add up and the sum stops at 255.
function Frac8(V: Single): Integer; inline;
begin
  if not (V > 0) then
    Exit(0);
  V := V * 256;
  if V >= 255 then
    Result := 255
  else
    Result := Trunc(V);
end;

function Mul8(X, Y: Integer): Integer; inline;
begin
  Result := ((2 * X + 1) * (2 * Y + 1)) shr 10;
end;

// The registers lighting reads do not change within a primitive.
procedure TPSPGEEngine.PrepareLight;
var
  C: PGECmds;
  Now: TGELightRegs;
  Mode, Control: Cardinal;
begin
  C := @Regs.Cmd;
{$IF Defined(MSWINDOWS)}
  {$WARN SYMBOL_PLATFORM OFF}
  Mode := GetMXCSR and $FFC0; // sticky exception flags do not affect setup
  {$WARN SYMBOL_PLATFORM ON}
{$ELSE}
  Mode := Ord(GetRoundMode);
{$ENDIF}
{$IFDEF CPUX86}
  Control := Get8087CW;
{$ELSE}
  Control := 0;
{$ENDIF}
  if FLightRegsValid and
    CompareMem(@C[GE_LIGHTENABLE0], @FLightRegs[0], 4 * SizeOf(Cardinal)) and
    CompareMem(@C[GE_MATERIALEMISSIVE], @FLightRegs[4],
      (GE_LAC0 + 12 - GE_MATERIALEMISSIVE) * SizeOf(Cardinal)) and
    (FLightRegs[75] = Regs.View[2]) and (FLightRegs[76] = Regs.View[5]) and
    (FLightRegs[77] = Regs.View[8]) and (FLightRegs[78] = Mode) and (FLightRegs[79] = Control) then
  begin
    FLightValid := True;
    Exit;
  end;
  // What it reads: LIGHTENABLE0..3, the material and light registers from
  // MATERIALEMISSIVE to the last light's colours, the view's z axis and the
  // floating-point modes its divisions run in. The same ones give the same
  // setup: keep it.
  for var I := 0 to 3 do
    Now[I] := C[GE_LIGHTENABLE0 + I];
  for var I := 0 to GE_LAC0 + 11 - GE_MATERIALEMISSIVE do
    Now[4 + I] := C[GE_MATERIALEMISSIVE + I];
  Now[75] := Regs.View[2];
  Now[76] := Regs.View[5];
  Now[77] := Regs.View[8];
  Now[78] := Mode;
  Now[79] := Control;
  FLightRegs := Now;
  FLightRegsValid := True;
  for var Ch := 0 to 2 do
  begin
    FLight.MA[Ch] := Byte8(C[GE_MATERIALAMBIENT], Ch * 8);
    FLight.MD[Ch] := Byte8(C[GE_MATERIALDIFFUSE], Ch * 8);
    FLight.MS[Ch] := Byte8(C[GE_MATERIALSPECULAR], Ch * 8);
    FLight.E[Ch] := Byte8(C[GE_MATERIALEMISSIVE], Ch * 8);
    FLight.AL[Ch] := Byte8(C[GE_AMBIENTCOLOR], Ch * 8);
  end;
  FLight.MAA := Byte8(C[GE_MATERIALALPHA], 0);
  FLight.ALA := Byte8(C[GE_AMBIENTALPHA], 0);
  // The exponent keeps the top 4 bits of its mantissa.
  FLight.Shine := GEFloat(C[GE_MATERIALSPECULARCOEF] and $FFF800);
  // The viewer is at infinity along view space +z.
  FLight.View := Vec3(GEFloat(Regs.View[2]), GEFloat(Regs.View[5]), GEFloat(Regs.View[8]));
  FLight.Separate := (C[GE_LIGHTMODE] and 1) <> 0;
  for var L := 0 to 3 do
  begin
    var U: PGELightUnit := @FLight.Lights[L];
    U.on := (C[GE_LIGHTENABLE0 + L] and 1) <> 0;
    var LT := C[GE_LIGHTTYPE0 + L];
    U.Kind := LT and 3;
    U.LType := (LT shr 8) and 3;
    U.Pos := CmdVec(C^, GE_LX0 + L * 3);
    U.KA := GEFloat(C[GE_LKA0 + L * 3]);
    U.KB := GEFloat(C[GE_LKA0 + L * 3 + 1]);
    U.KC := GEFloat(C[GE_LKA0 + L * 3 + 2]);
    U.PosFinite := FiniteS(U.Pos.X) and FiniteS(U.Pos.Y) and FiniteS(U.Pos.Z) and FiniteS(U.KA) and FiniteS(U.KB) and
      FiniteS(U.KC);
    U.SpotDir := Normalized(CmdVec(C^, GE_LDX0 + L * 3));
    var SD := CmdVec(C^, GE_LDX0 + L * 3);
    U.SpotRaw := Vec3(T24(SD.X), T24(SD.Y), T24(SD.Z));
    U.SpotFinite := not (IsNan(SD.X) or IsNan(SD.Y) or IsNan(SD.Z) or IsInfinite(SD.X) or IsInfinite(SD.Y) or
      IsInfinite(SD.Z));
    U.SpotRS := 0;
    if U.SpotFinite then
      U.SpotRS := RSqrt24(Length2F24(U.SpotRaw.X, U.SpotRaw.Y, U.SpotRaw.Z));
    U.Cutoff := GEFloat(C[GE_LKO0 + L]);
    // Like the shininess, the spot exponent keeps the top 4 bits of its
    // mantissa.
    U.Expo := GEFloat(C[GE_LKS0 + L] and $FFF800);
    U.SpotPositive := GEFloat(C[GE_LDX0 + L * 3]) > 0;
    for var Ch := 0 to 2 do
    begin
      U.LA[Ch] := Byte8(C[GE_LAC0 + L * 3], Ch * 8);
      U.LD[Ch] := Byte8(C[GE_LAC0 + L * 3 + 1], Ch * 8);
      U.LS[Ch] := Byte8(C[GE_LAC0 + L * 3 + 2], Ch * 8);
    end;
    if U.LType = 0 then
    begin
      var D := NormalizedF24(U.Pos);
      var VW := FLight.View;
      U.DirD := D;
      U.DirH := Normalized(Vec3(D.X + VW.X, D.Y + VW.Y, D.Z + VW.Z));
    end;
  end;
  FLightValid := True;
end;

procedure TPSPGEEngine.Light(const V: TGEInVertex; const MP, WP, WN: TGEVec3; var R, G, B, A, SR, SG, SB: Integer);
var
  Upd: Cardinal;
  MA, MD, MS, Lit, Spec: TGERGB;
  MAA, A8, S8, D8: Integer;
  Att, Dist, Den, CosA, NdotL, Diff, NdotH: Single;
  N, D, H: TGEVec3;
  Ch: Integer;
begin
  if not FLightValid then
    PrepareLight;
  Upd := Regs.Cmd[GE_MATERIALUPDATE];
  MA := FLight.MA;
  MD := FLight.MD;
  MS := FLight.MS;
  MAA := FLight.MAA;
  if V.HasColor then
  begin
    if (Upd and 1) <> 0 then
    begin
      MA[0] := V.R;
      MA[1] := V.G;
      MA[2] := V.B;
      MAA := V.A;
    end;
    if (Upd and 2) <> 0 then
    begin
      MD[0] := V.R;
      MD[1] := V.G;
      MD[2] := V.B;
    end;
    if (Upd and 4) <> 0 then
    begin
      MS[0] := V.R;
      MS[1] := V.G;
      MS[2] := V.B;
    end;
  end;
  for Ch := 0 to 2 do
  begin
    Lit[Ch] := FLight.E[Ch] + Mul8(FLight.AL[Ch], MA[Ch]);
    Spec[Ch] := 0;
  end;
  N := NormalF24(WN);
  for var L := 0 to 3 do
  begin
    var U: PGELightUnit := @FLight.Lights[L];
    if not U.on then
      Continue;
    A8 := 255;
    if U.LType = 0 then
      D := U.DirD
    else
    begin
      D := U.Pos;
      if U.PosFinite and FiniteS(WP.X) and FiniteS(WP.Y) and FiniteS(WP.Z) then
      begin
        // The vector to the light (LightRow24), its squared length as a sum
        // of products, the length and the unit vector through RSqrt24
        // (ge_dist: every distance of the sweep, 99.3% of random offsets),
        // and KA + KB d + KC d^2 as a sum of products.
        var DX := LightRow24(PGERow24(@FGeom.Rows[0])^, T24(MP.X), T24(MP.Y), T24(MP.Z), D.X);
        var DY := LightRow24(PGERow24(@FGeom.Rows[1])^, T24(MP.X), T24(MP.Y), T24(MP.Z), D.Y);
        var DZ := LightRow24(PGERow24(@FGeom.Rows[2])^, T24(MP.X), T24(MP.Y), T24(MP.Z), D.Z);
        var Dist2 := Length2F24(DX, DY, DZ);
        var RS := RSqrt24(Dist2);
        Dist := T24(Dist2 * RS);
        D := Vec3(T24(DX * RS), T24(DY * RS), T24(DZ * RS));
        Den := Sum24(Term24(U.KA), Product24(U.KB, Dist), Product24(U.KC, Dist2), Term24(0));
      end
      else
      begin
        D := Vec3(D.X - WP.X, D.Y - WP.Y, D.Z - WP.Z);
        var Dist2 := F24(Dot(D, D));
        Dist := SqrtF24(Dist2);
        D := NormalizedF24(D);
        Den := U.KA + U.KB * Dist + U.KC * Dist2;
      end;
      // 1 / Den by the vertex unit's reciprocal table (Recip24): every
      // recorded attenuation over KA alone and over KC alone.
      if Den <> 0 then
        Att := Recip24(Den)
      else
        Att := 0;
      A8 := Frac8(Att);
    end;
    S8 := 255;
    if U.LType = 2 then
    begin
      // The dot product with the direction as it was given, a sum of
      // products, times RSqrt24 of the direction's squared length (ge_spot).
      if U.SpotFinite and not (NanS(D.X) or NanS(D.Y) or NanS(D.Z)) then
        CosA := T24(SpotDot24(D, U.SpotRaw) * U.SpotRS)
      else
        CosA := Dot(D, U.SpotDir);
      // An infinite direction lights everything or nothing by its sign.
      if NanS(CosA) then
        S8 := 255 * Ord(U.SpotPositive)
      else if CosA >= U.Cutoff then
        S8 := Frac8(GEPow(Max(CosA, 0), U.Expo))
      else
        S8 := 0;
    end;
    NdotL := Dot(N, D);
    Diff := MaxS(NdotL, 0);
    if U.Kind = 2 then
      Diff := GEPow(Diff, FLight.Shine);
    D8 := Frac8(Diff);
    // The spot factor scales the attenuated terms, each on its own (a factor
    // of 255 changes nothing).
    if (S8 = 255) and (A8 = 255) then
      for Ch := 0 to 2 do
        Lit[Ch] := Lit[Ch] + Mul8(U.LA[Ch], MA[Ch]) + Mul8(D8, Mul8(U.LD[Ch], MD[Ch]))
    else
      for Ch := 0 to 2 do
        Lit[Ch] := Lit[Ch] + Mul8(S8, Mul8(A8, Mul8(U.LA[Ch], MA[Ch]))) +
          Mul8(S8, Mul8(A8, Mul8(D8, Mul8(U.LD[Ch], MD[Ch]))));
    if (U.Kind = 1) and (NdotL >= 0) then
    begin
      var VW := FLight.View;
      if U.LType = 0 then
        H := U.DirH
      else
        H := Normalized(Vec3(D.X + VW.X, D.Y + VW.Y, D.Z + VW.Z));
      NdotH := MaxS(Dot(N, H), 0);
      var P8 := Frac8(GEPow(NdotH, FLight.Shine));
      if (S8 = 255) and (A8 = 255) then
        for Ch := 0 to 2 do
          Spec[Ch] := Spec[Ch] + Mul8(P8, Mul8(U.LS[Ch], MS[Ch]))
      else
        for Ch := 0 to 2 do
          Spec[Ch] := Spec[Ch] + Mul8(S8, Mul8(A8, Mul8(P8, Mul8(U.LS[Ch], MS[Ch]))));
    end;
  end;
  if FLight.Separate then
  begin
    SR := Min(Spec[0], 255);
    SG := Min(Spec[1], 255);
    SB := Min(Spec[2], 255);
  end
  else
    for Ch := 0 to 2 do
      Lit[Ch] := Lit[Ch] + Spec[Ch];
  R := Min(Lit[0], 255);
  G := Min(Lit[1], 255);
  B := Min(Lit[2], 255);
  A := Mul8(FLight.ALA, MAA);
end;

// The vector to a light as lighting sees it, for shade mapping: the half
// vector for lights with specular.
function TPSPGEEngine.LightVector(L: Integer; const WP: TGEVec3): TGEVec3;
var
  C: PGECmds;
  D, VW: TGEVec3;
begin
  C := @Regs.Cmd;
  D := CmdVec(C^, GE_LX0 + L * 3);
  if ((C[GE_LIGHTTYPE0 + L] shr 8) and 3) <> 0 then
    D := Vec3(D.X - WP.X, D.Y - WP.Y, D.Z - WP.Z);
  D := Normalized(D);
  if (C[GE_LIGHTTYPE0 + L] and 3) = 1 then
  begin
    VW := Vec3(GEFloat(Regs.View[2]), GEFloat(Regs.View[5]), GEFloat(Regs.View[8]));
    D := Normalized(Vec3(D.X + VW.X, D.Y + VW.Y, D.Z + VW.Z));
  end;
  Result := D;
end;

procedure TPSPGEEngine.TexGen(const V: TGEInVertex; const P, N, WP, WN: TGEVec3; out S, T, Q: Single);
var
  C: PGECmds;
  Src, NW, LU, LV: TGEVec3;
begin
  C := @Regs.Cmd;
  Q := 1;
  case C[GE_TEXMAPMODE] and 3 of
    1:
      begin
        case (C[GE_TEXMAPMODE] shr 8) and 3 of
          0:
            Src := P;
          1:
            Src := Vec3(V.U, V.V, 0);
          2:
            Src := Normalized(N);
        else
          Src := N;
        end;
        if not FGeomValid then
          PrepareGeometry;
        var M: PGESingle12 := @FGeom.TGen;
        S := M[0] * Src.X + M[3] * Src.Y + M[6] * Src.Z + M[9];
        T := M[1] * Src.X + M[4] * Src.Y + M[7] * Src.Z + M[10];
        Q := M[2] * Src.X + M[5] * Src.Y + M[8] * Src.Z + M[11];
      end;
    2:
      begin
        NW := Normalized(WN);
        LU := LightVector(Integer(C[GE_TEXSHADELS] and 3), WP);
        LV := LightVector(Integer((C[GE_TEXSHADELS] shr 8) and 3), WP);
        S := (1 + Dot(NW, LU)) / 2;
        T := (1 + Dot(NW, LV)) / 2;
      end;
  else
    begin
      S := V.U * GEFloat(C[GE_TEXSCALEU]) + GEFloat(C[GE_TEXOFFSETU]);
      T := V.V * GEFloat(C[GE_TEXSCALEV]) + GEFloat(C[GE_TEXOFFSETV]);
    end;
  end;
end;

// A model space position through the matrices in the GE's 24-bit arithmetic:
// clip coordinates and the view space position.
procedure TPSPGEEngine.ClipPosition(const P: TGEVec3; out CX, CY, CZ, CW: Double; out VP: TGEVec3);
begin
  // As Row24 and Row24P on the matrices' GEFloats (decoded once a primitive).
  if not FGeomValid then
    PrepareGeometry;
  var G: ^TGEGeometry := @FGeom;
  var A, B: array[0..2] of Double;
  var Q: array[0..3] of Double;
  if G.Combined then
  begin
    Rows24(@G.ViewWorld[0], T24(P.X), T24(P.Y), T24(P.Z), @B[0], 3, G.ViewWorldSmall);
    // The position goes through all three matrices at once.
    if not FGeomClipValid then
      PrepareClip;
    Rows24(@FGeomClip[0], T24(P.X), T24(P.Y), T24(P.Z), @Q[0], 4, FGeomClipSmall);
  end
  else
  begin
    Rows24(@G.Rows[0], T24(P.X), T24(P.Y), T24(P.Z), @A[0], 3, G.WorldSmall);
    Rows24(@G.Rows[3], A[0], A[1], A[2], @B[0], 3, G.ViewSmall);
    Rows24(@G.Rows[6], B[0], B[1], B[2], @Q[0], 4, G.ProjSmall);
  end;
  CX := Q[0];
  CY := Q[1];
  CZ := Q[2];
  CW := Q[3];
  VP := Vec3(B[0], B[1], B[2]);
end;

// The projection times view and world: each element a row sum of products cut
// to 16 bits (probe ge_xyround), the projection's translation the term added.
procedure TPSPGEEngine.PrepareClip;
begin
  var G: ^TGEGeometry := @FGeom;
  for var R := 0 to 3 do
    for var J := 0 to 3 do
    begin
      var T: Double := 0;
      if J = 3 then
        T := G.Rows[6 + R, 3];
      FGeomClip[R, J] := Sum24(Term24(T24(G.Rows[6 + R, 0] * G.ViewWorld[0, J])), Term24(T24(G.Rows[6 + R, 1] *
        G.ViewWorld[1, J])), Term24(T24(G.Rows[6 + R, 2] * G.ViewWorld[2, J])), Term24(T));
    end;
  FGeomClipSmall := RowsSmall(@FGeomClip[0], 4);
  FGeomClipValid := True;
end;

procedure TPSPGEEngine.PrepareGeometry;
begin
  // Only the registers' values: they cannot change within a command. The
  // same values as last time decode the same.
  var G: ^TGEGeometry := @FGeom;
  var C: PGECmds := @Regs.Cmd;
  if FGeomCached and CompareMem(@Regs.World, @FGeomMats, SizeOf(FGeomMats)) and CompareMem(@C[GE_VIEWPORTXSCALE],
      @FGeomPort, 6 * SizeOf(Cardinal)) and (C[GE_OFFSETX] = FGeomPort[6]) and (C[GE_OFFSETY] = FGeomPort[7]) then
  begin
    if (G.BoneCount > 0) and not CompareMem(@Regs.Bone, @FGeomBones, G.BoneCount * SizeOf(Cardinal)) then
      G.BoneCount := 0;
    FGeomValid := True;
    Exit;
  end;
  Move(Regs.World, FGeomMats, SizeOf(FGeomMats));
  Move(C[GE_VIEWPORTXSCALE], FGeomPort, 6 * SizeOf(Cardinal));
  FGeomPort[6] := C[GE_OFFSETX];
  FGeomPort[7] := C[GE_OFFSETY];
  FGeomCached := True;
  for var I := 0 to 11 do
  begin
    G.WorldS[I] := GEFloat(Regs.World[I]);
    G.World[I] := G.WorldS[I];
    G.View[I] := GEFloat(Regs.View[I]);
    G.TGen[I] := GEFloat(Regs.TGen[I]);
  end;
  for var I := 0 to 15 do
    G.Proj[I] := GEFloat(Regs.Proj[I]);
  for var I := 0 to 3 do
    G.ProjW[I] := T24(G.Proj[12 + I]);
  for var R := 0 to 2 do
  begin
    G.Rows[R, 0] := G.World[R];
    G.Rows[R, 1] := G.World[R + 3];
    G.Rows[R, 2] := G.World[R + 6];
    G.Rows[R, 3] := G.World[R + 9];
    G.Rows[3 + R, 0] := G.View[R];
    G.Rows[3 + R, 1] := G.View[R + 3];
    G.Rows[3 + R, 2] := G.View[R + 6];
    G.Rows[3 + R, 3] := G.View[R + 9];
  end;
  for var R := 0 to 3 do
  begin
    G.Rows[6 + R, 0] := G.Proj[R];
    G.Rows[6 + R, 1] := G.Proj[R + 4];
    G.Rows[6 + R, 2] := G.Proj[R + 8];
    G.Rows[6 + R, 3] := G.ProjW[R];
  end;
  G.Combined := True;
  for var I := 0 to 11 do
    if not (Exact24(G.World[I]) and Exact24(G.View[I])) then
      G.Combined := False;
  if G.Combined then
    CombineViewWorld(G.View, G.World, @G.ViewWorld[0]);
  G.ViewWorldSmall := G.Combined and RowsSmall(@G.ViewWorld[0], 3);
  G.WorldSmall := RowsSmall(@G.Rows[0], 3);
  G.ViewSmall := RowsSmall(@G.Rows[3], 3);
  G.ProjSmall := RowsSmall(@G.Rows[6], 4);
  G.XScale := GEFloat(C[GE_VIEWPORTXSCALE]);
  G.XCenter := GEFloat(C[GE_VIEWPORTXCENTER]);
  G.YScale := GEFloat(C[GE_VIEWPORTYSCALE]);
  G.YCenter := GEFloat(C[GE_VIEWPORTYCENTER]);
  G.ZScale := GEFloat(C[GE_VIEWPORTZSCALE]);
  G.ZCenter := GEFloat(C[GE_VIEWPORTZCENTER]);
  G.OffX := Integer(C[GE_OFFSETX] and $FFFF);
  G.OffY := Integer(C[GE_OFFSETY] and $FFFF);
  G.BoneCount := 0;
  FGeomValid := True;
end;

procedure TPSPGEEngine.PrepareBones(Count: Integer);
begin
  if not FGeomValid then
    PrepareGeometry;
  for var I := FGeom.BoneCount to Min(Count, 96) - 1 do
  begin
    FGeomBones[I] := Regs.Bone[I];
    FGeom.Bone[I] := GEFloat(Regs.Bone[I]);
  end;
  FGeom.BoneCount := Max(FGeom.BoneCount, Min(Count, 96));
end;

const
  GEOutXNeg = 1;
  GEOutXPos = 2;
  GEOutYNeg = 4;
  GEOutYPos = 8;
  GEOutNear = 16;
  GEOutFar = 32;
  GEOutPlanes = 63;
  GEOutZ = GEOutNear or GEOutFar;
  // Projected outside the 4096 pixel screen.
  GEOutScreen = 64;
  // No position.
  GEOutNone = 128;

// Clip coordinates to a screen position (a vertex beyond the 4096 pixel
// screen culls its primitive), depth and 1/w.
procedure TPSPGEEngine.Project(var A: TGEAsmVertex);
begin
  if not FGeomValid then
    PrepareGeometry;
  var G: ^TGEGeometry := @FGeom;
  var RW := Recip24(A.CW);
  // Add24(T24(T24(A.CX * RW) * G.XScale), G.XCenter) and so on.
  var Screen: array[0..2] of Double;
  Port24(@A.CX, RW, @G.XScale, @Screen[0]);
  var SX := Screen[0];
  var SY := Screen[1];
  var SZ := Screen[2];
  if not ((SX >= 0) and (SX <= 4096) and (SY >= 0) and (SY <= 4096)) then
  begin
    A.Code := A.Code or GEOutScreen;
    SX := 0;
    SY := 0;
  end;
  // (SX and SY in 0..4096 here: Floor is Trunc.)
  A.V.X := Integer(Trunc(SX * 16)) - G.OffX;
  A.V.Y := Integer(Trunc(SY * 16)) - G.OffY;
  if not (Abs(SZ) <= 1E9) then
    SZ := 0;
  A.V.Z := FloorInt(SZ);
  if (PUInt64(@RW)^ and $7FFFFFFFFFFFFFFF) = $7FF0000000000000 then
    RW := 0;
  A.V.W := RW;
end;

procedure TPSPGEEngine.TransformVertex(const V: TGEInVertex; VType: Cardinal; out O: TGEAsmVertex);
var
  C: PGECmds;
  R, G, B, A, SR, SG, SB: Integer;
  P, N, WP, WN, VP: TGEVec3;
  CX, CY, CZ, CW: Double;
  S, T, Q: Single;
begin
  O := Default(TGEAsmVertex);
  C := @Regs.Cmd;
  if V.HasColor then
  begin
    R := V.R;
    G := V.G;
    B := V.B;
    A := V.A;
  end
  else
  begin
    Color24(C[GE_MATERIALAMBIENT], R, G, B);
    A := C[GE_MATERIALALPHA] and $FF;
  end;
  if (VType and (1 shl 23)) <> 0 then
  begin
    // Through-mode positions are truncated to 1/16 pixel (recorded on a
    // PSP-E1000: a point at x.97 stays on pixel x).
    O.V.X := Trunc(V.P.X * 16);
    O.V.Y := Trunc(V.P.Y * 16);
    O.V.Z := Trunc(V.P.Z);
    O.V.W := 1;
    O.V.R := R;
    O.V.G := G;
    O.V.B := B;
    O.V.A := A;
    O.V.S := V.U;
    O.V.T := V.V;
    O.V.Q := 1;
    O.V.Fog := 1;
    Exit;
  end;
  P := V.P;
  N := V.N;
  if ((VType shr 9) and 3) <> 0 then
    Skin(V, VType, P, N);
  if (C[GE_REVERSENORMAL] and 1) <> 0 then
    N := Vec3(-N.X, -N.Y, -N.Z);
  if not FGeomValid then
    PrepareGeometry;
  WP := MulPoint(FGeom.WorldS, P);
  WN := MulDir(FGeom.WorldS, N);
  ClipPosition(P, CX, CY, CZ, CW, VP);
  O.CX := CX;
  O.CY := CY;
  O.CZ := CZ;
  O.CW := CW;
  if CX < -CW then
    O.Code := GEOutXNeg;
  if CX > CW then
    O.Code := O.Code or GEOutXPos;
  if CY < -CW then
    O.Code := O.Code or GEOutYNeg;
  if CY > CW then
    O.Code := O.Code or GEOutYPos;
  if CZ < -CW then
    O.Code := O.Code or GEOutNear;
  if CZ > CW then
    O.Code := O.Code or GEOutFar;
  Project(O);

  SR := 0;
  SG := 0;
  SB := 0;
  if (C[GE_LIGHTINGENABLE] and 1) <> 0 then
    Light(V, P, WP, WN, R, G, B, A, SR, SG, SB);
  O.V.R := R;
  O.V.G := G;
  O.V.B := B;
  O.V.A := A;
  O.V.SR := SR;
  O.V.SG := SG;
  O.V.SB := SB;
  TexGen(V, P, N, WP, WN, S, T, Q);
  O.V.Q := Q;
  O.V.S := S * (1 shl (C[GE_TEXSIZE0] and $F));
  O.V.T := T * (1 shl ((C[GE_TEXSIZE0] shr 8) and $F));
  O.V.Fog := (GEFloat(C[GE_FOG1]) + VP.Z) * GEFloat(C[GE_FOG2]);
end;

{ Raster state }

const
  // Bits a texel by texture format (DXT by their blocks).
  TexBits: array[0..15] of Integer = (16, 16, 16, 32, 4, 8, 16, 32, 4, 8, 8, 0, 0, 0, 0, 0);
  // The registers BuildRaster reads, as runs (first, count); with them a few
  // it does not ($1D, $26).
  GERasterRuns: array[0..9, 0..1] of Byte = ((GE_VTYPE, 1), (GE_REGION1, 2), (GE_CLIPENABLE, 13), (GE_SHADEMODE, 1),
    (GE_FRAMEBUFPTR, 20), (GE_TEXSIZE0, 8), (GE_TEXMODE, 2), (GE_CLUTFORMAT, 6), (GE_FOGCOLOR, 2),
    (GE_FRAMEBUFPIXFORMAT, 24));

procedure TPSPGEEngine.BuildRaster;
var
  S: ^TGERaster;
begin
  S := @FRaster;
  var C: PGECmds := @Regs.Cmd;
  // The same registers, VRAM layout and texture memory build the same state
  // (byte for byte): keep it, and the CPU queue its copy of it.
  var Diff: Cardinal := 0;
  var K: PCardinal := @FRasterKey[0];
  for var R := 0 to High(GERasterRuns) do
  begin
    var P: PCardinal := @C[GERasterRuns[R, 0]];
    var Bytes := GERasterRuns[R, 1] * SizeOf(Cardinal);
    if not FRasterKeyValid or not CompareMem(P, K, Bytes) then
    begin
      Diff := 1;
      Move(P^, K^, Bytes);
    end;
    Inc(K, GERasterRuns[R, 1]);
  end;
  var Extra: array[0..2] of Cardinal;
  Extra[0] := Cardinal(FMemory.VRAMShift);
  Extra[1] := Cardinal(UInt64(NativeUInt(@FMemory.VRAM[0])));
  Extra[2] := Cardinal(UInt64(NativeUInt(@FMemory.VRAM[0])) shr 32);
  for var I := 0 to 2 do
  begin
    if K^ <> Extra[I] then
    begin
      Diff := 1;
      K^ := Extra[I];
    end;
    Inc(K);
  end;
  var Same := FRasterKeyValid and (Diff = 0);
  if Same and S.Textured then
    for var L := 0 to S.Tex.LevelCount - 1 do
      if (S.Tex.Levels[L].Size > 0) and (FMemory.HostPtr(S.Tex.Levels[L].Addr, S.Tex.Levels[L].Size) <>
        S.Tex.Levels[L].Ptr) then
      begin
        Same := False;
        Break;
      end;
  if Same then
    Exit;
  FRasterKeyValid := True;
  S.VRAM := @FMemory.VRAM[0];
  S.FBAddr := C[GE_FRAMEBUFPTR] and $1FFFF0;
  S.FBStride := C[GE_FRAMEBUFWIDTH] and $7FC;
  S.FBFormat := C[GE_FRAMEBUFPIXFORMAT] and 3;
  S.ZAddr := C[GE_ZBUFPTR] and $1FFFF0;
  S.ZStride := C[GE_ZBUFWIDTH] and $7FC;
  S.ZPermutation := FMemory.VRAMShift;
  // REGION bounds drawing independently of the scissor. In particular, an
  // oversized scissor must not let depth writes escape into adjacent vertices.
  S.ScissorX1 := Max(C[GE_SCISSOR1] and $3FF, C[GE_REGION1] and $3FF);
  S.ScissorY1 := Max((C[GE_SCISSOR1] shr 10) and $3FF, (C[GE_REGION1] shr 10) and $3FF);
  S.ScissorX2 := Min(C[GE_SCISSOR2] and $3FF, C[GE_REGION2] and $3FF);
  S.ScissorY2 := Min((C[GE_SCISSOR2] shr 10) and $3FF, (C[GE_REGION2] shr 10) and $3FF);
  S.BandY1 := 0;
  S.BandY2 := 1023;
  S.Through := (C[GE_VTYPE] and (1 shl 23)) <> 0;
  S.ClearMode := (C[GE_CLEARMODE] and 1) <> 0;
  S.ClearColor := (C[GE_CLEARMODE] and $100) <> 0;
  S.ClearStencil := (C[GE_CLEARMODE] and $200) <> 0;
  S.ClearDepth := (C[GE_CLEARMODE] and $400) <> 0;
  S.Gouraud := (C[GE_SHADEMODE] and 1) <> 0;
  S.Antialias := ((C[GE_ANTIALIASENABLE] and 1) <> 0) and not S.ClearMode;
  S.Flat := not S.Gouraud;
  S.Textured := ((C[GE_TEXENABLE] and 1) <> 0) and not S.ClearMode;
  if S.Textured then
  begin
    var T: ^TGETexture := @S.Tex;
    T.Memory := FMemory;
    T.Format := C[GE_TEXFORMAT] and $F;
    T.Swizzle := (C[GE_TEXMODE] and 1) <> 0;
    T.LevelCount := Integer((C[GE_TEXMODE] shr 16) and 7) + 1;
    // With a CLUT per level (TEXMODE bit 8) level L's CLUT4 indices go up by
    // 16 L and CLUT8's by 256 L (recorded on a PSP-E1000, ge_clut: CLUT16
    // and CLUT32 unchanged, within the CLUT's 512 entries).
    var ClutStep := 0;
    if (C[GE_TEXMODE] and $100) <> 0 then
      case T.Format of
        4:
          ClutStep := 16;
        5:
          ClutStep := 256;
      end;
    for var L := 0 to 7 do
    begin
      T.Levels[L].Addr := ((C[GE_TEXBUFWIDTH0 + L] and $0F0000) shl 8) or (C[GE_TEXADDR0 + L] and $FFFFFF);
      T.Levels[L].BufWidth := C[GE_TEXBUFWIDTH0 + L] and $7FF;
      // A row is the buffer width's bytes cut to a multiple of 16, at least
      // 16 (ge_clut: every format but DXT, widths 1 to 64; 0 not recorded).
      if (T.Format < 8) and (T.Levels[L].BufWidth > 0) then
      begin
        var RowBytes := Max(16, ((T.Levels[L].BufWidth * TexBits[T.Format]) shr 3) and not 15);
        T.Levels[L].BufWidth := (RowBytes shl 3) div TexBits[T.Format];
      end;
      T.Levels[L].ClutAdd := (L * ClutStep) and $1FF;
      T.Levels[L].Width := 1 shl Min(C[GE_TEXSIZE0 + L] and $F, 9);
      T.Levels[L].Height := 1 shl Min((C[GE_TEXSIZE0 + L] shr 8) and $F, 9);
      T.Levels[L].Size := Cardinal(T.Levels[L].BufWidth * T.Levels[L].Height * TexBits[T.Format]) div 8;
      T.Levels[L].Ptr := nil;
      if (L < T.LevelCount) and (T.Levels[L].Size > 0) then
        T.Levels[L].Ptr := FMemory.HostPtr(T.Levels[L].Addr, T.Levels[L].Size);
      GEFitLevel(T^, T.Levels[L]);
    end;
    T.Level := 0;
    T.ClampU := (C[GE_TEXWRAP] and 1) <> 0;
    T.ClampV := (C[GE_TEXWRAP] and $100) <> 0;
    T.Linear := (C[GE_TEXFILTER] and $100) <> 0;
    T.MinFilter := C[GE_TEXFILTER] and 7;
    T.MaxLevel := T.LevelCount - 1;
    T.LevelMode := C[GE_TEXLEVEL] and 3;
    T.LodBias := ShortInt((C[GE_TEXLEVEL] shr 16) and $FF);
    T.Slope := GEFloat(C[GE_TEXLODSLOPE]);
    T.NeedLod := ((T.MinFilter >= 4) and (T.MaxLevel > 0)) or (((T.MinFilter and 1) <> 0) <> T.Linear);
    T.Clut := @FClut[0];
    var CF := C[GE_CLUTFORMAT];
    T.ClutFormat := CF and 3;
    T.ClutShift := (CF shr 2) and $1F;
    T.ClutMask := (CF shr 8) and $FF;
    T.ClutOffset := ((CF shr 16) and $1F) shl 4;
    // GEPrepareRaster makes the palette again when these or the CLUT change.
    var PalKey := (CF and $1FFFFF) or (Cardinal(T.Format) shl 24);
    if PalKey <> FPalKey then
    begin
      FPalKey := PalKey;
      T.PalValid := False;
    end;
    S.TexFunc := C[GE_TEXFUNC] and 7;
    S.TexAlpha := (C[GE_TEXFUNC] and $100) <> 0;
    S.ColorDouble := (C[GE_TEXFUNC] and $10000) <> 0;
    S.EnvR := C[GE_TEXENVCOLOR] and $FF;
    S.EnvG := (C[GE_TEXENVCOLOR] shr 8) and $FF;
    S.EnvB := (C[GE_TEXENVCOLOR] shr 16) and $FF;
    // A texture in the pixels drawn reads through the texture cache, which
    // starts empty when the textures before did not.
    var Cached := False;
    var Bpp: UInt64 := 2;
    if S.FBFormat = 3 then
      Bpp := 4;
    if (T.Format <= 7) and (S.ScissorX1 <= S.ScissorX2) and (S.ScissorY1 <= S.ScissorY2) then
    begin
      var FLo := UInt64(S.FBAddr) + (UInt64(S.ScissorY1) * S.FBStride + UInt64(S.ScissorX1)) * Bpp;
      var FHi := UInt64(S.FBAddr) + (UInt64(S.ScissorY2) * S.FBStride + UInt64(S.ScissorX2) + 1) * Bpp;
      for var L := 0 to T.LevelCount - 1 do
        if (T.Levels[L].Addr and $0F800000) = PSPVRAMBase then
        begin
          var TLo := UInt64(T.Levels[L].Addr and (PSPVRAMSize - 1));
          if (TLo < FHi) and (FLo < TLo + GELevelReach(T^, T.Levels[L])) then
            Cached := True;
        end;
    end;
    if not Cached then
      T.Cache := nil
    else if T.Cache = nil then
    begin
      Inc(FTexEpoch);
      T.CacheEpoch := FTexEpoch;
      T.Cache := @FTexCache;
    end;
  end
  else
    S.Tex.Cache := nil;
  S.FogEnabled := ((C[GE_FOGENABLE] and 1) <> 0) and not S.ClearMode;
  S.FogR := C[GE_FOGCOLOR] and $FF;
  S.FogG := (C[GE_FOGCOLOR] shr 8) and $FF;
  S.FogB := (C[GE_FOGCOLOR] shr 16) and $FF;
  S.ColorTest := ((C[GE_COLORTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.ColorTestFunc := C[GE_COLORTEST] and 3;
  S.ColorRef := C[GE_COLORREF] and $FFFFFF;
  S.ColorMask := C[GE_COLORTESTMASK] and $FFFFFF;
  S.AlphaTest := ((C[GE_ALPHATESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.AlphaFunc := C[GE_ALPHATEST] and 7;
  S.AlphaRef := (C[GE_ALPHATEST] shr 8) and $FF;
  S.AlphaMask := (C[GE_ALPHATEST] shr 16) and $FF;
  S.StencilTest := ((C[GE_STENCILTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.StencilFunc := C[GE_STENCILTEST] and 7;
  S.StencilRef := (C[GE_STENCILTEST] shr 8) and $FF;
  S.StencilMask := (C[GE_STENCILTEST] shr 16) and $FF;
  S.StencilFail := C[GE_STENCILOP] and 7;
  S.StencilZFail := (C[GE_STENCILOP] shr 8) and 7;
  S.StencilZPass := (C[GE_STENCILOP] shr 16) and 7;
  S.DepthTest := ((C[GE_ZTESTENABLE] and 1) <> 0) and not S.ClearMode;
  S.DepthFunc := C[GE_ZTEST] and 7;
  S.DepthWrite := (C[GE_ZWRITEDISABLE] and 1) = 0;
  S.MinZ := C[GE_MINZ] and $FFFF;
  S.MaxZ := C[GE_MAXZ] and $FFFF;
  S.DepthClamp := (C[GE_CLIPENABLE] and 1) <> 0;
  S.Blend := ((C[GE_BLENDENABLE] and 1) <> 0) and not S.ClearMode;
  S.BlendSrc := C[GE_BLENDMODE] and $F;
  S.BlendDst := (C[GE_BLENDMODE] shr 4) and $F;
  S.BlendOp := (C[GE_BLENDMODE] shr 8) and $F;
  S.FixA := C[GE_BLENDFIXEDA] and $FFFFFF;
  S.FixB := C[GE_BLENDFIXEDB] and $FFFFFF;
  S.Dither := (C[GE_DITHERENABLE] and 1) <> 0;
  for var Row := 0 to 3 do
    for var Col := 0 to 3 do
    begin
      var D := Integer((C[GE_DITH0 + Row] shr (Col * 4)) and $F);
      if D >= 8 then
        D := D - 16;
      S.DitherMatrix[Row * 4 + Col] := D;
    end;
  S.LogicOp := ((C[GE_LOGICOPENABLE] and 1) <> 0) and not S.ClearMode;
  S.LogicFunc := C[GE_LOGICOP] and $F;
  S.MaskRGB := C[GE_MASKRGB] and $FFFFFF;
  S.MaskA := C[GE_MASKALPHA] and $FF;
  GEPrepareRaster(S^);
  FWorkers.StateChanged;
  RasterChanged;
end;

procedure TPSPGEEngine.RasterChanged;
begin
  if Backend <> nil then
    Inc(Backend.RasterSerial);
end;

{ Primitives }

const
  // Texture setup of a textured primitive (the texture cache's fill).
  GETexPrimCost = 2000;
  // Primitives of this many vertices or more are transformed in parallel.
  ParallelVertices = 96;

// Pixels of a 1/16 pixel box inside the scissor, for the drawing cost.
// ns the GE takes to fill Pixels pixels of the current primitive (probe
// ge_fill): 4.77 a pixel into a 32-bit target, 7.19 with its depth written,
// 3.17 into a 16-bit one either way; blending adds nothing.
function TPSPGEEngine.FillCost(Pixels: Int64): Int64;
begin
  var Depth := (FRaster.ClearMode and FRaster.ClearDepth) or
    (not FRaster.ClearMode and FRaster.DepthTest and FRaster.DepthWrite);
  var PerPixel: Int64 := 317;
  if FRaster.FBFormat = 3 then
    if Depth then
      PerPixel := 719
    else
      PerPixel := 477;
  Result := Pixels * PerPixel div 100;
end;

function TPSPGEEngine.ScissoredArea(X1, Y1, X2, Y2: Integer): Int64;
begin
  var W := Min(X2 div 16, FRaster.ScissorX2 + 1) - Max(X1 div 16, FRaster.ScissorX1);
  var H := Min(Y2 div 16, FRaster.ScissorY2 + 1) - Max(Y1 div 16, FRaster.ScissorY1);
  if (W <= 0) or (H <= 0) then
    Exit(0);
  Result := Int64(W) * H;
end;

procedure TPSPGEEngine.EmitTriangle(const A, B, C: TGEVertex; Odd: Boolean);
begin
  if FCullOn then
  begin
    var Cross := Int64(B.X - A.X) * (C.Y - A.Y) - Int64(B.Y - A.Y) * (C.X - A.X);
    if Cross = 0 then
      Exit;
    var CW := Cross > 0;
    if Odd then
      CW := not CW;
    if CW <> FCullCW then
      Exit;
  end;
  if Backend <> nil then
    Backend.DrawTriangle(FRaster, A, B, C)
  else
    FWorkers.Triangle(FRaster, A, B, C);
  Inc(FPrimCost, 100 + FillCost(Min(Abs(Int64(B.X - A.X) * (C.Y - A.Y) - Int64(B.Y - A.Y) * (C.X - A.X)) div 512,
    ScissoredArea(Min(A.X, Min(B.X, C.X)), Min(A.Y, Min(B.Y, C.Y)), Max(A.X, Max(B.X, C.X)),
    Max(A.Y, Max(B.Y, C.Y))))));
end;

type
  PGEAsmVertex = ^TGEAsmVertex;

// Where the edge from A (inside) to B (beyond the near plane z = -w) meets
// the plane: clip coordinates and attributes in proportion, not projected.
// In the vertex unit's arithmetic (gpu/exact's nearclip depth jobs, recorded
// on a PSP-E1000): the distances z + w and their difference as its sums,
// the fraction their quotient by its reciprocal cut to 16 bits, each
// coordinate A + (B - A) T from A.
function NearPoint(const A, B: TGEAsmVertex): TGEAsmVertex;
begin
  var DA := Add24(A.CZ, A.CW);
  var DB := Add24(B.CZ, B.CW);
  var T := T24(DA * Recip24(Add24(DA, -DB)));
  Result.CX := Add24(A.CX, T24(Add24(B.CX, -A.CX) * T));
  Result.CY := Add24(A.CY, T24(Add24(B.CY, -A.CY) * T));
  Result.CZ := Add24(A.CZ, T24(Add24(B.CZ, -A.CZ) * T));
  Result.CW := Add24(A.CW, T24(Add24(B.CW, -A.CW) * T));
  Result.Code := 0;
  Result.V := A.V;
  Result.V.R := A.V.R + Round((B.V.R - A.V.R) * T);
  Result.V.G := A.V.G + Round((B.V.G - A.V.G) * T);
  Result.V.B := A.V.B + Round((B.V.B - A.V.B) * T);
  Result.V.A := A.V.A + Round((B.V.A - A.V.A) * T);
  Result.V.SR := A.V.SR + Round((B.V.SR - A.V.SR) * T);
  Result.V.SG := A.V.SG + Round((B.V.SG - A.V.SG) * T);
  Result.V.SB := A.V.SB + Round((B.V.SB - A.V.SB) * T);
  Result.V.S := A.V.S + (B.V.S - A.V.S) * T;
  Result.V.T := A.V.T + (B.V.T - A.V.T) * T;
  Result.V.Q := A.V.Q + (B.V.Q - A.V.Q) * T;
  Result.V.Fog := A.V.Fog + (B.V.Fog - A.V.Fog) * T;
end;

procedure CopyColors(var D: TGEVertex; const S: TGEVertex); inline;
begin
  D.R := S.R;
  D.G := S.G;
  D.B := S.B;
  D.A := S.A;
  D.SR := S.SR;
  D.SG := S.SG;
  D.SB := S.SB;
end;

// Without depth clamping a primitive with a vertex whose depth after the
// viewport lies outside 0..65535 is not drawn (recorded on a PSP-E1000:
// beyond the far plane but inside that range it is; inside the planes but
// outside it, not).
function DepthOut(const A: TGEAsmVertex): Boolean; inline;
begin
  Result := (A.V.Z < 0) or (A.V.Z > 65535);
end;

// With depth clamping a triangle's vertex depths are clamped to 0..65535
// before its depth plane is made (recorded on a PSP-E1000, ge_zclamp: every
// pixel of triangles with vertices inside the planes and beyond the far one;
// clamping each pixel's depth instead was off in 70% of them).
procedure ClampDepth(var V: TGEVertex); inline;
begin
  if V.Z < 0 then
    V.Z := 0
  else if V.Z > 65535 then
    V.Z := 65535;
end;

// A triangle through the clipper. It is culled when all its vertices lie
// beyond one plane, when without depth clamping any lies beyond the near
// plane or outside the depth range (DepthOut), and when any vertex it is
// drawn with lies outside the 4096 pixel screen. With depth clamping the near
// plane cuts it and the far plane only clamps depth; the polygon left starts
// at the point where its edges come back inside and goes out as a fan
// (gpu/exact's nearclip jobs).
procedure TPSPGEEngine.ClipTriangle(const A, B, C: TGEAsmVertex; Odd: Boolean);
var
  Src: array[0..2] of PGEAsmVertex;
  Poly: array[0..3] of TGEAsmVertex;
begin
  var Codes := A.Code or B.Code or C.Code;
  if ((Codes and GEOutNone) <> 0) or ((A.Code and B.Code and C.Code and GEOutPlanes) <> 0) then
    Exit;
  if not FDepthClamp and (((Codes and GEOutNear) <> 0) or DepthOut(A) or DepthOut(B) or DepthOut(C)) then
    Exit;
  if (Codes and GEOutNear) = 0 then
  begin
    if (Codes and GEOutScreen) = 0 then
      if FDepthClamp and (DepthOut(A) or DepthOut(B) or DepthOut(C)) then
      begin
        var CA := A.V;
        var CB := B.V;
        var CC := C.V;
        ClampDepth(CA);
        ClampDepth(CB);
        ClampDepth(CC);
        EmitTriangle(CA, CB, CC, Odd);
      end
      else
        EmitTriangle(A.V, B.V, C.V, Odd);
    Exit;
  end;
  Src[0] := @A;
  Src[1] := @B;
  Src[2] := @C;
  var N := 0;
  var Entry := 0;
  for var I := 0 to 2 do
  begin
    var P := Src[I];
    var Q := Src[(I + 1) mod 3];
    var PIn := (P.Code and GEOutNear) = 0;
    var QIn := (Q.Code and GEOutNear) = 0;
    if PIn then
    begin
      Poly[N] := P^;
      Inc(N);
    end;
    if PIn <> QIn then
    begin
      if PIn then
        Poly[N] := NearPoint(P^, Q^)
      else
      begin
        Poly[N] := NearPoint(Q^, P^);
        Entry := N;
      end;
      Project(Poly[N]);
      Inc(N);
    end;
  end;
  if Entry <> 0 then
  begin
    var Tmp: array[0..3] of TGEAsmVertex;
    for var I := 0 to N - 1 do
      Tmp[I] := Poly[(Entry + I) mod N];
    for var I := 0 to N - 1 do
      Poly[I] := Tmp[I];
  end;
  for var I := 0 to N - 1 do
  begin
    if (Poly[I].Code and GEOutScreen) <> 0 then
      Exit;
    if FRaster.Flat then
      CopyColors(Poly[I].V, C.V);
    ClampDepth(Poly[I].V);
  end;
  for var I := 1 to N - 2 do
    EmitTriangle(Poly[0].V, Poly[I].V, Poly[I + 1].V, Odd);
end;

procedure TPSPGEEngine.ClipLine(const A, B: TGEAsmVertex);
var
  P, Q: TGEAsmVertex;
begin
  var Codes := A.Code or B.Code;
  if ((Codes and GEOutNone) <> 0) or ((A.Code and B.Code and GEOutPlanes) <> 0) then
    Exit;
  if not FDepthClamp and (((Codes and GEOutNear) <> 0) or DepthOut(A) or DepthOut(B)) then
    Exit;
  P := A;
  Q := B;
  if (A.Code and GEOutNear) <> 0 then
  begin
    P := NearPoint(B, A);
    Project(P);
  end
  else if (B.Code and GEOutNear) <> 0 then
  begin
    Q := NearPoint(A, B);
    Project(Q);
    if FRaster.Flat then
      CopyColors(Q.V, B.V);
  end;
  if ((P.Code or Q.Code) and GEOutScreen) = 0 then
    if Backend <> nil then
      Backend.DrawLine(FRaster, P.V, Q.V)
    else
      FWorkers.Line(FRaster, P.V, Q.V);
end;

procedure TPSPGEEngine.EmitSprite(const A, B: TGEAsmVertex);
begin
  var Codes := A.Code or B.Code;
  if ((Codes and (GEOutNone or GEOutNear or GEOutScreen)) <> 0) or ((A.Code and B.Code and GEOutPlanes) <> 0) then
    Exit;
  if not FDepthClamp and (DepthOut(A) or DepthOut(B)) then
    Exit;
  if Backend <> nil then
    Backend.DrawSprite(FRaster, A.V, B.V)
  else
    FWorkers.Sprite(FRaster, A.V, B.V);
  Inc(FPrimCost, 100 + FillCost(ScissoredArea(Min(A.V.X, B.V.X), Min(A.V.Y, B.V.Y), Max(A.V.X, B.V.X),
    Max(A.V.Y, B.V.Y))));
end;

procedure TPSPGEEngine.AddVertex(const A: TGEAsmVertex);
begin
  var N := FAsmCount;
  Inc(FAsmCount);
  case FAsmType of
    0:
      if (A.Code and (GEOutNone or GEOutPlanes or GEOutScreen)) = 0 then
        if Backend <> nil then
          Backend.DrawPoint(FRaster, A.V)
        else
          FWorkers.Point(FRaster, A.V);
    1:
      begin
        FAsm[N and 1] := A;
        if (N and 1) = 1 then
          ClipLine(FAsm[0], FAsm[1]);
      end;
    2:
      begin
        if N > 0 then
          ClipLine(FAsm[0], A);
        FAsm[0] := A;
      end;
    3:
      begin
        var I := N mod 3;
        FAsm[I] := A;
        if I = 2 then
          ClipTriangle(FAsm[0], FAsm[1], FAsm[2], False);
      end;
    4:
      begin
        // (The last three vertices in turn in FAsm, not moved along.) Every
        // other triangle goes out with its first two vertices swapped, so
        // all wind alike (where the near plane cuts it, this decides where
        // its polygon starts: gpu/exact's nearclip strips).
        FAsm[N mod 3] := A;
        if N >= 2 then
          if ((N - 2) and 1) <> 0 then
            ClipTriangle(FAsm[(N - 1) mod 3], FAsm[(N - 2) mod 3], FAsm[N mod 3], False)
          else
            ClipTriangle(FAsm[(N - 2) mod 3], FAsm[(N - 1) mod 3], FAsm[N mod 3], False);
      end;
    5:
      begin
        // (The centre in FAsm[0], the last two in FAsm[1] and FAsm[2] in turn.)
        if N = 0 then
        begin
          FAsm[0] := A;
          Exit;
        end;
        FAsm[2 - (N and 1)] := A;
        if N >= 2 then
          ClipTriangle(FAsm[0], FAsm[2 - ((N - 1) and 1)], FAsm[2 - (N and 1)], False);
      end;
    6:
      begin
        FAsm[N and 1] := A;
        if (N and 1) = 1 then
          EmitSprite(FAsm[0], FAsm[1]);
      end;
  end;
end;

procedure TPSPGEEngine.DrawPrim(Op: Cardinal);
var
  Raw: TGEInVertex;
  V: TGEAsmVertex;
begin
  var PrimType := Integer((Op shr 16) and 7);
  var Count := Integer(Op and $FFFF);
  var VType := Regs.Cmd[GE_VTYPE];
  FLightValid := False;
  FGeomValid := False;
  FGeomClipValid := False;
  SetupVertexFormat(VType);
  var HasPos := ((VType shr 7) and 3) <> 0;
  if PrimType <> 7 then
  begin
    FAsmType := PrimType;
    FAsmCount := 0;
  end;
  BuildRaster;
  FCullOn := ((Regs.Cmd[GE_CULLENABLE] and 1) <> 0) and not FRaster.ClearMode;
  FCullCW := (Regs.Cmd[GE_CULL] and 1) <> 0;
  FDepthClamp := (Regs.Cmd[GE_CLIPENABLE] and 1) <> 0;
  if FRaster.Textured then
    Inc(FPrimCost, GETexPrimCost);
  if (Count >= ParallelVertices) and (FVertexPool <> nil) and TransformInParallel(Count, VType) then
  begin
    for var I := 0 to Count - 1 do
    begin
      if not HasPos then
        FParOut[I].Code := GEOutNone;
      Inc(FPrimCost, 40);
      AddVertex(FParOut[I]);
    end;
    // The texture coordinates and normal carried on are the last vertex's.
    if ((VType and 3) <> 0) or (((VType shr 5) and 3) <> 0) then
      ReadVertex(FParIndex[Count - 1], VType, Raw);
  end
  else
    for var I := 0 to Count - 1 do
    begin
      ReadVertex(VertexIndex(I, VType), VType, Raw);
      TransformVertex(Raw, VType, V);
      if not HasPos then
        V.Code := GEOutNone;
      Inc(FPrimCost, 40);
      AddVertex(V);
    end;
  AdvanceVertices(Count, VType);
end;

// The vertices of a primitive decoded and transformed on the vertex pool's
// threads into FParOut, when they are all in RAM (read through host memory,
// no faults) and not morphed: what needs preparing is prepared here first,
// so the threads only read the engine. False when it is not done.
function TPSPGEEngine.TransformInParallel(Count: Integer; VType: Cardinal): Boolean;
begin
  Result := False;
{$IFDEF CPU64BITS}
  if (FRAMBase = nil) or (((VType shr 18) and 7) <> 0) then
    Exit;
  if Length(FParIndex) < Count then
  begin
    SetLength(FParIndex, Count);
    SetLength(FParOut, Count);
  end;
  for var I := 0 to Count - 1 do
  begin
    var Index := VertexIndex(I, VType);
    var Physical := (Regs.VAddr + Cardinal(Index * FVSize)) and $1FFFFFFF;
    if (Physical < PSPRAMBase) or (Physical - PSPRAMBase > PSPRAMSize - Cardinal(FVSize)) then
      Exit;
    FParIndex[I] := Index;
  end;
  if not FGeomValid then
    PrepareGeometry;
  if ((Regs.Cmd[GE_LIGHTINGENABLE] and 1) <> 0) and not FLightValid then
    PrepareLight;
  if ((VType shr 9) and 3) <> 0 then
  begin
    var Bones := (Integer((VType shr 14) and 7) + 1) * 12;
    if FGeom.BoneCount < Bones then
      PrepareBones(Bones);
  end;
  Result := TGEVertexPool(FVertexPool).Run(Self, VType, Count, FLastU, FLastV, FLastN);
{$ENDIF}
end;

{$IFDEF CPU64BITS}
// Vertices First..Last of TransformInParallel's primitive, on a pool thread.
procedure TPSPGEEngine.TransformRange(VType: Cardinal; First, Last: Integer; LastU, LastV: Single; const LastN: TGEVec3);
var
  Raw: TGEInVertex;
begin
  var N := LastN;
  for var I := First to Last do
  begin
    DecodeVertexWith(Regs.VAddr + Cardinal(FParIndex[I] * FVSize), VType, Raw, LastU, LastV, N);
    TransformVertex(Raw, VType, FParOut[I]);
  end;
end;

{$ENDIF}

function TPSPGEEngine.VertexIndex(I: Integer; VType: Cardinal): Integer;
begin
  case (VType shr 11) and 3 of
    1:
      Result := FMemory.Read8(Regs.IAddr + Cardinal(I));
    2:
      Result := FMemory.Read16(Regs.IAddr + Cardinal(I * 2));
    3:
      Result := Integer(FMemory.Read32(Regs.IAddr + Cardinal(I * 4)) and $FFFF);
  else
    Result := I;
  end;
end;

// Past the vertices (or indices) a PRIM or BBOX has read.
procedure TPSPGEEngine.AdvanceVertices(Count: Integer; VType: Cardinal);
begin
  case (VType shr 11) and 3 of
    0:
      Regs.VAddr := Regs.VAddr + Cardinal(Count * FVSize * (Integer((VType shr 18) and 7) + 1));
    1:
      Regs.IAddr := Regs.IAddr + Cardinal(Count);
    2:
      Regs.IAddr := Regs.IAddr + Cardinal(Count) * 2;
    3:
      Regs.IAddr := Regs.IAddr + Cardinal(Count) * 4;
  end;
end;

// A screen coordinate in 1/16 pixel, clamped to the 4096 pixel range.
function ScreenCoord(D: Double): Integer;
begin
  if IsNan(D) then
    Exit(0);
  Result := Floor(EnsureRange(D * 16, 0, 65535));
end;

// BOUNDING BOX: may the hull of the vertices be visible? Not when they all
// lie behind the eye (w <= 0), beyond one z plane (with clipping on) or on
// one side of the drawing area: scissor and region together, widened by a
// pixel, against screen positions clamped to the 4096 pixel range before the
// offset. The vertices go through in groups of 256 counted from the end, and
// the flag BJUMP reads is the second last group's (the only one's for 256 or
// fewer).
procedure TPSPGEEngine.BoundingBox(Op: Cardinal);
var
  Raw: TGEInVertex;
  P, N, VP: TGEVec3;
  CX, CY, CZ, CW: Double;
begin
  var Count := Integer(Op and $FFFF);
  var VType := Regs.Cmd[GE_VTYPE];
  FGeomValid := False;
  FGeomClipValid := False;
  SetupVertexFormat(VType);
  FPrimCost := Int64(Count) * 40;
  BoxVisible := False;
  if Count = 0 then
    Exit;
  var C: PGECmds := @Regs.Cmd;
  var Groups := (Count + 255) div 256;
  var First := Count - (Groups - 1) * 256;
  var GStart := 0;
  var GEnd := Count;
  if Groups = 2 then
    GEnd := First
  else if Groups > 2 then
  begin
    GStart := First + (Groups - 3) * 256;
    GEnd := GStart + 256;
  end;
  var Through := (VType and (1 shl 23)) <> 0;
  var Clamp := (C[GE_CLIPENABLE] and 1) <> 0;
  var X1 := (Integer(Max(C[GE_SCISSOR1] and $3FF, C[GE_REGION1] and $3FF)) - 1) * 16;
  var Y1 := (Integer(Max((C[GE_SCISSOR1] shr 10) and $3FF, (C[GE_REGION1] shr 10) and $3FF)) - 1) * 16;
  var X2 := (Integer(Min(C[GE_SCISSOR2] and $3FF, C[GE_REGION2] and $3FF)) + 1) * 16;
  var Y2 := (Integer(Min((C[GE_SCISSOR2] shr 10) and $3FF, (C[GE_REGION2] shr 10) and $3FF)) + 1) * 16;
  var OffX := Integer(C[GE_OFFSETX] and $FFFF);
  var OffY := Integer(C[GE_OFFSETY] and $FFFF);
  var OutMask := $FF;
  for var I := GStart to GEnd - 1 do
  begin
    ReadVertex(VertexIndex(I, VType), VType, Raw);
    var M := 0;
    var SX, SY: Integer;
    if Through then
    begin
      SX := Trunc(Raw.P.X * 16);
      SY := Trunc(Raw.P.Y * 16);
    end
    else
    begin
      P := Raw.P;
      N := Raw.N;
      if ((VType shr 9) and 3) <> 0 then
        Skin(Raw, VType, P, N);
      ClipPosition(P, CX, CY, CZ, CW, VP);
      if not (CW > 0) then
      begin
        OutMask := OutMask and 16;
        Continue;
      end;
      if Clamp then
      begin
        if CZ < -CW then
          M := M or 32;
        if CZ > CW then
          M := M or 64;
      end;
      var RW := Recip24(CW);
      SX := ScreenCoord(Add24(T24(T24(CX * RW) * GEFloat(C[GE_VIEWPORTXSCALE])),
          GEFloat(C[GE_VIEWPORTXCENTER]))) - OffX;
      SY := ScreenCoord(Add24(T24(T24(CY * RW) * GEFloat(C[GE_VIEWPORTYSCALE])),
          GEFloat(C[GE_VIEWPORTYCENTER]))) - OffY;
    end;
    if SX < X1 then
      M := M or 1;
    if SX > X2 then
      M := M or 2;
    if SY < Y1 then
      M := M or 4;
    if SY > Y2 then
      M := M or 8;
    OutMask := OutMask and M;
  end;
  BoxVisible := OutMask = 0;
  AdvanceVertices(Count, VType);
end;

{ Patches }

// Patches as the GE evaluates them (recorded on a PSP-E1000,
// probes ge_patch and ge_spline: every point's depth and colour,
// through mode and 3D): t = I / Div in 8 bits, floored from the nearer end
// (PatchT); along v (each column), then along u. A curve is three levels of
// steps between neighbours (de Casteljau's for Bezier, every step at t; de
// Boor's for splines, from the knots: SplineSteps). A step on floats
// (PatchLerp) cuts both values toward zero at the larger one's 16th
// significant bit and floors A (256 - S) + B S over 256 there; on colours (in
// 2^-7) it floors, and the colour rounds up at the end.
type
  // A curve's six steps (in 1/256): the three of the first level, the two of
  // the second, the last.
  TGEPatchSteps = array[0..5] of Integer;

function PatchT(I, Divs: Integer): Integer;
begin
  if 2 * I <= Divs then
    Result := (I shl 8) div Divs
  else
    Result := 256 - (((Divs - I) shl 8) div Divs);
end;

procedure BezierSteps(T: Integer; out A: TGEPatchSteps);
begin
  for var K := 0 to 5 do
    A[K] := T;
end;

// A uniform cubic B-spline of N points on segment Seg (points Seg .. Seg + 3)
// at T: knot I is I - 3, an open end repeating its knot. Each step's
// fraction between its knots is floored from the nearer one.
procedure SplineSteps(N, Seg, T: Integer; StartOpen, EndOpen: Boolean; out A: TGEPatchSteps);

  function Knot(I: Integer): Integer;
  begin
    Result := I - 3;
    if StartOpen and (Result < 0) then
      Result := 0;
    if EndOpen and (Result > N - 3) then
      Result := N - 3;
  end;

  function Step(KI, KJ: Integer): Integer;
  begin
    if KJ = KI then
      Exit(0);
    var L := T + 256 * (Seg - KI);
    var R := 256 * (KJ - Seg) - T;
    if L <= R then
      Result := L div (KJ - KI)
    else
      Result := 256 - R div (KJ - KI);
  end;

begin
  for var K := 0 to 2 do
    A[K] := Step(Knot(Seg + 1 + K), Knot(Seg + 4 + K));
  for var K := 0 to 1 do
    A[3 + K] := Step(Knot(Seg + 2 + K), Knot(Seg + 4 + K));
  A[5] := Step(Knot(Seg + 3), Knot(Seg + 4));
end;

function PatchLerp(A, B: Double; T: Integer): Double;
begin
  if T = 0 then
    Exit(A);
  if T = 256 then
    Exit(B);
  if IsNan(A) or IsNan(B) or IsInfinite(A) or IsInfinite(B) then
    Exit(A + (B - A) * (T / 256));
  var E: Integer;
  if A = 0 then
  begin
    if B = 0 then
      Exit(0);
    E := Exp24(B);
  end
  else if B = 0 then
    E := Exp24(A)
  else
    E := Max(Exp24(A), Exp24(B));
  var Ulp := Ldexp(1, E - 16);
  var N := Int(A / Ulp) * (256 - T) + Int(B / Ulp) * T;
  Result := FloorInt(N / 256) * Ulp;
end;

// A curve's value and its last pair, before the final interpolation.
function PatchCurve(P0, P1, P2, P3: Double; const A: TGEPatchSteps; out L, R: Double): Double; overload;
begin
  var AB := PatchLerp(P0, P1, A[0]);
  var BC := PatchLerp(P1, P2, A[1]);
  var CD := PatchLerp(P2, P3, A[2]);
  L := PatchLerp(AB, BC, A[3]);
  R := PatchLerp(BC, CD, A[4]);
  Result := PatchLerp(L, R, A[5]);
end;

// A curve's value, and the difference of its last pair (its tangent there,
// in its units), in the vertex unit's add precision.
function PatchCurve(P0, P1, P2, P3: Double; const A: TGEPatchSteps; out D: Double): Double; overload;
var
  L, R: Double;
begin
  Result := PatchCurve(P0, P1, P2, P3, A, L, R);
  D := Add24(R, -L);
end;

function PatchCurve(P0, P1, P2, P3: Double; const A: TGEPatchSteps): Double; overload;
var
  L, R: Double;
begin
  Result := PatchCurve(P0, P1, P2, P3, A, L, R);
end;

function PatchCurveC(C0, C1, C2, C3: Integer; const A: TGEPatchSteps): Integer;
begin
  var AB := (C0 * (256 - A[0]) + C1 * A[0]) shr 8;
  var BC := (C1 * (256 - A[1]) + C2 * A[1]) shr 8;
  var CD := (C2 * (256 - A[2]) + C3 * A[2]) shr 8;
  var ABC := (AB * (256 - A[3]) + BC * A[3]) shr 8;
  var BCD := (BC * (256 - A[4]) + CD * A[4]) shr 8;
  Result := (ABC * (256 - A[5]) + BCD * A[5]) shr 8;
end;

// BEZIER and SPLINE: a grid of UCount x VCount control points, as patches
// (Bezier: 4x4 points sharing edges; spline: every 4x4 window, its points
// on a segment's far edge those of the next segment's near edge) each cut
// into PATCHDIVISION's U x V cells. Each row of cells goes out as a strip
// (top-left, bottom-left, top-right, ...), drawn as triangles, a line strip
// or points by PATCHPRIMITIVE. Without normals, a Bezier patch's come from
// its tangents (along u cross along v: gpu/exact's curves normals jobs).
// DU takes v's value then u's last pair; DV takes v's last pair through u
// before subtracting. The stage order matters at the patch unit's precision.
procedure TPSPGEEngine.DrawPatch(Op: Cardinal; Spline: Boolean);
var
  Ev: TGEInVertex;
  SU, SV: TGEPatchSteps;
begin
  var C: PGECmds := @Regs.Cmd;
  var UCount := Integer(Op and $FF);
  var VCount := Integer((Op shr 8) and $FF);
  var VType := C[GE_VTYPE];
  FLightValid := False;
  FGeomValid := False;
  FGeomClipValid := False;
  SetupVertexFormat(VType);
  var Total := UCount * VCount;
  if (UCount < 4) or (VCount < 4) then
  begin
    AdvanceVertices(Total, VType);
    Exit;
  end;
  if Length(FPatchCP) < Total then
    SetLength(FPatchCP, Total);
  for var I := 0 to Total - 1 do
    ReadVertex(VertexIndex(I, VType), VType, FPatchCP[I]);
  AdvanceVertices(Total, VType);
  if Length(FPatchVal) < Total then
    SetLength(FPatchVal, Total);
  for var I := 0 to Total - 1 do
  begin
    var P: ^TGEInVertex := @FPatchCP[I];
    var Q: ^TGEPatchValues := @FPatchVal[I];
    Q.F[0] := P.P.X;
    Q.F[1] := P.P.Y;
    Q.F[2] := P.P.Z;
    Q.F[3] := P.N.X;
    Q.F[4] := P.N.Y;
    Q.F[5] := P.N.Z;
    Q.F[6] := P.U;
    Q.F[7] := P.V;
    for var K := 0 to 7 do
      Q.F[8 + K] := P.Weights[K];
    Q.C[0] := P.R shl 7;
    Q.C[1] := P.G shl 7;
    Q.C[2] := P.B shl 7;
    Q.C[3] := P.A shl 7;
  end;

  var UDiv := Max(Integer(C[GE_PATCHDIVISION] and $FF), 1);
  var VDiv := Max(Integer((C[GE_PATCHDIVISION] shr 8) and $FF), 1);
  var USegs, VSegs: Integer;
  if Spline then
  begin
    USegs := UCount - 3;
    VSegs := VCount - 3;
  end
  else
  begin
    USegs := (UCount - 1) div 3;
    VSegs := (VCount - 1) div 3;
  end;
  var UStartOpen := ((Op shr 16) and 1) <> 0;
  var UEndOpen := ((Op shr 17) and 1) <> 0;
  var VStartOpen := ((Op shr 18) and 1) <> 0;
  var VEndOpen := ((Op shr 19) and 1) <> 0;
  var HasTC := (VType and 3) <> 0;
  var HasNrm := ((VType shr 5) and 3) <> 0;
  var HasPos := ((VType shr 7) and 3) <> 0;
  // The values evaluated (TGEPatchValues.F).
  var Comps: array[0..15] of Integer;
  var NComps := 0;
  if HasPos then
    for var K := 0 to 2 do
    begin
      Comps[NComps] := K;
      Inc(NComps);
    end;
  if HasNrm then
    for var K := 3 to 5 do
    begin
      Comps[NComps] := K;
      Inc(NComps);
    end;
  if HasTC then
    for var K := 6 to 7 do
    begin
      Comps[NComps] := K;
      Inc(NComps);
    end;
  if ((VType shr 9) and 3) <> 0 then
    for var K := 0 to Integer((VType shr 14) and 7) do
    begin
      Comps[NComps] := 8 + K;
      Inc(NComps);
    end;
  var PCol: array[0..3] of TGEPatchValues;
  var Pt: TGEPatchValues;
  // Each column's last pair along v, carried separately through u.
  var VLo, VHi: array[0..3, 0..2] of Double;
  var MakeNormals := not Spline and not HasNrm and HasPos;
  // (Values a vertex does not have stay 0.)
  FillChar(PCol, SizeOf(PCol), 0);
  FillChar(Pt, SizeOf(Pt), 0);

  BuildRaster;
  FCullOn := ((C[GE_CULLENABLE] and 1) <> 0) and not FRaster.ClearMode;
  FCullCW := ((C[GE_CULL] and 1) <> 0) <> ((C[GE_PATCHFACING] and 1) <> 0);
  FDepthClamp := (C[GE_CLIPENABLE] and 1) <> 0;
  if FRaster.Textured then
    Inc(FPrimCost, GETexPrimCost);
  var PrimType := 4;
  case C[GE_PATCHPRIMITIVE] and 3 of
    1:
      PrimType := 2;
    2, 3:
      PrimType := 0;
  end;
  var Cols := UDiv + 1;
  if Length(FPatchGrid) < Cols * (VDiv + 1) then
    SetLength(FPatchGrid, Cols * (VDiv + 1));

  for var PV := 0 to VSegs - 1 do
    for var PU := 0 to USegs - 1 do
    begin
      for var J := 0 to VDiv do
      begin
        // The segment and step along v (a spline's far edge: the next
        // segment's near one).
        var SegV := PV;
        var QV := PatchT(J, VDiv);
        if Spline then
        begin
          if (J = VDiv) and (PV < VSegs - 1) then
          begin
            SegV := PV + 1;
            QV := 0;
          end;
          SplineSteps(VCount, SegV, QV, VStartOpen, VEndOpen, SV);
        end
        else
          BezierSteps(QV, SV);
        var V0 := SegV;
        if not Spline then
          V0 := PV * 3;
        // Each column along v at this row (the segment along u decides
        // which: see below; both segments' columns where they differ).
        for var I := 0 to UDiv do
        begin
          var SegU := PU;
          var QU := PatchT(I, UDiv);
          if Spline then
          begin
            if (I = UDiv) and (PU < USegs - 1) then
            begin
              SegU := PU + 1;
              QU := 0;
            end;
            SplineSteps(UCount, SegU, QU, UStartOpen, UEndOpen, SU);
          end
          else
            BezierSteps(QU, SU);
          var U0 := SegU;
          if not Spline then
            U0 := PU * 3;
          if (I = 0) or (SegU <> PU) then
            for var A := 0 to 3 do
            begin
              var P0: ^TGEPatchValues := @FPatchVal[V0 * UCount + U0 + A];
              var P1: ^TGEPatchValues := @FPatchVal[(V0 + 1) * UCount + U0 + A];
              var P2: ^TGEPatchValues := @FPatchVal[(V0 + 2) * UCount + U0 + A];
              var P3: ^TGEPatchValues := @FPatchVal[(V0 + 3) * UCount + U0 + A];
              for var K := 0 to NComps - 1 do
              begin
                var X := Comps[K];
                if MakeNormals and (X < 3) then
                  PCol[A].F[X] := PatchCurve(P0.F[X], P1.F[X], P2.F[X], P3.F[X], SV, VLo[A, X], VHi[A, X])
                else
                  PCol[A].F[X] := PatchCurve(P0.F[X], P1.F[X], P2.F[X], P3.F[X], SV);
              end;
              for var X := 0 to 3 do
                PCol[A].C[X] := PatchCurveC(P0.C[X], P1.C[X], P2.C[X], P3.C[X], SV);
            end;
          Ev := Default(TGEInVertex);
          var DU, DV: array[0..2] of Double;
          for var K := 0 to NComps - 1 do
          begin
            var X := Comps[K];
            if MakeNormals and (X < 3) then
            begin
              Pt.F[X] := PatchCurve(PCol[0].F[X], PCol[1].F[X], PCol[2].F[X], PCol[3].F[X], SU, DU[X]);
              // Two steps along v, then all three along u on each side,
              // then the difference. Neither v-first nor u-first
              // interpolation of an already formed difference is the same.
              DV[X] := Add24(PatchCurve(VHi[0, X], VHi[1, X], VHi[2, X], VHi[3, X], SU),
                -PatchCurve(VLo[0, X], VLo[1, X], VLo[2, X], VLo[3, X], SU));
            end
            else
              Pt.F[X] := PatchCurve(PCol[0].F[X], PCol[1].F[X], PCol[2].F[X], PCol[3].F[X], SU);
          end;
          if MakeNormals then
          begin
            // Each product is cut to 24 bits before the subtraction in
            // Add24 precision. A fused sum of products is not equivalent;
            // nor is rounding to Single before the cut.
            Pt.F[3] := Add24(T24(DU[1] * DV[2]), -T24(DU[2] * DV[1]));
            Pt.F[4] := Add24(T24(DU[2] * DV[0]), -T24(DU[0] * DV[2]));
            Pt.F[5] := Add24(T24(DU[0] * DV[1]), -T24(DU[1] * DV[0]));
            if (C[GE_PATCHFACING] and 1) <> 0 then
              for var X := 3 to 5 do
                Pt.F[X] := -Pt.F[X];
          end;
          Ev.P.X := Pt.F[0];
          Ev.P.Y := Pt.F[1];
          Ev.P.Z := Pt.F[2];
          Ev.N.X := Pt.F[3];
          Ev.N.Y := Pt.F[4];
          Ev.N.Z := Pt.F[5];
          Ev.U := Pt.F[6];
          Ev.V := Pt.F[7];
          for var K := 0 to 7 do
            Ev.Weights[K] := Pt.F[8 + K];
          Ev.R := Min(255, (PatchCurveC(PCol[0].C[0], PCol[1].C[0], PCol[2].C[0], PCol[3].C[0], SU) + 127) shr 7);
          Ev.G := Min(255, (PatchCurveC(PCol[0].C[1], PCol[1].C[1], PCol[2].C[1], PCol[3].C[1], SU) + 127) shr 7);
          Ev.B := Min(255, (PatchCurveC(PCol[0].C[2], PCol[1].C[2], PCol[2].C[2], PCol[3].C[2], SU) + 127) shr 7);
          Ev.A := Min(255, (PatchCurveC(PCol[0].C[3], PCol[1].C[3], PCol[2].C[3], PCol[3].C[3], SU) + 127) shr 7);
          Ev.HasColor := FPatchCP[0].HasColor;
          if not HasTC then
          begin
            Ev.U := PU + I / UDiv;
            Ev.V := PV + J / VDiv;
          end;
          if not HasNrm and not MakeNormals then
            Ev.N := FPatchCP[0].N;
          TransformVertex(Ev, VType, FPatchGrid[J * Cols + I]);
          if not HasPos then
            FPatchGrid[J * Cols + I].Code := GEOutNone;
          Inc(FPrimCost, 40);
        end;
      end;
      for var J := 0 to VDiv - 1 do
      begin
        FAsmType := PrimType;
        FAsmCount := 0;
        for var I := 0 to UDiv do
        begin
          AddVertex(FPatchGrid[J * Cols + I]);
          AddVertex(FPatchGrid[(J + 1) * Cols + I]);
        end;
      end;
    end;
end;

// A vertex given by registers $F0-$F9 (screen x, y in 1/16, z, s, t, q,
// colour, fog, secondary colour); $F7 adds it with the alpha, the primitive
// and, on a primitive's first vertex, enables that replace the usual ones.
procedure TPSPGEEngine.ImmediateVertex(Op: Cardinal);
var
  V: TGEVertex;
  AV: TGEAsmVertex;
begin
  var C: PGECmds := @Regs.Cmd;
  var PrimType := Integer((Op shr 8) and 7);
  var Through := (C[GE_VTYPE] and (1 shl 23)) <> 0;
  if PrimType <> 7 then
  begin
    FAsmType := PrimType;
    FAsmCount := 0;
    // (A state built anew, changed below: the next one is built anew too.)
    FRasterKeyValid := False;
    BuildRaster;
    FRasterKeyValid := False;
    FRaster.Through := Through;
    FRaster.Gouraud := (Op and $40000) <> 0;
    FRaster.Flat := not FRaster.Gouraud;
    FRaster.Textured := ((Op and $200000) <> 0) and not FRaster.ClearMode;
    FRaster.FogEnabled := ((Op and $400000) <> 0) and not FRaster.ClearMode;
    FRaster.Dither := ((Op and $800000) <> 0) and not FRaster.ClearMode;
    FCullOn := ((Op and $80000) <> 0) and not FRaster.ClearMode;
    FCullCW := (Op and $100000) <> 0;
    RasterChanged;
  end;
  V := Default(TGEVertex);
  V.X := Integer(C[$F0] and $FFFF);
  V.Y := Integer(C[$F1] and $FFFF);
  Dec(V.X, Integer(C[GE_OFFSETX] and $FFFF));
  Dec(V.Y, Integer(C[GE_OFFSETY] and $FFFF));
  V.Z := C[$F2] and $FFFF;
  V.W := 1;
  V.R := C[$F6] and $FF;
  V.G := (C[$F6] shr 8) and $FF;
  V.B := (C[$F6] shr 16) and $FF;
  V.A := Op and $FF;
  if not Through and ((C[GE_LIGHTMODE] and 1) <> 0) then
  begin
    V.SR := C[$F9] and $FF;
    V.SG := (C[$F9] shr 8) and $FF;
    V.SB := (C[$F9] shr 16) and $FF;
  end;
  var Q := GEFloat(C[$F5]);
  if Q = 0 then
    Q := 1;
  V.S := GEFloat(C[$F3]) / Q * (1 shl (C[GE_TEXSIZE0] and $F));
  V.T := GEFloat(C[$F4]) / Q * (1 shl ((C[GE_TEXSIZE0] shr 8) and $F));
  V.Q := 1;
  V.Fog := (C[$F8] and $FF) / 255;
  Inc(FPrimCost, 40);
  AV := Default(TGEAsmVertex);
  AV.V := V;
  AddVertex(AV);
end;

procedure TPSPGEEngine.LoadClut(Op: Cardinal);
begin
  // The CLUT address loses its low 4 bits.
  var Addr := (((Regs.Cmd[GE_CLUTADDRUPPER] and $0F0000) shl 8) or (Regs.Cmd[GE_CLUTADDR] and $FFFFFF)) and
    not Cardinal($F);
  var Bytes := Integer(Op and $3F) * 32;
  if Bytes > Length(FClut) then
    Bytes := Length(FClut);
  if Bytes > 0 then
    FMemory.ReadBytes(Addr, FClut[0], Bytes);
  FWorkers.ClutChanged;
  FRaster.Tex.PalValid := False;
  FRaster.Tex.Sampler := nil;
  // The next primitive builds its state (and palette) again.
  FRasterKeyValid := False;
  RasterChanged;
end;

// Transfers address VRAM's 8MB of mirrors with wrap-around at the end.
function WrapVRAM(A: Cardinal): Cardinal; inline;
begin
  Result := A and $1FFFFFFF;
  if (Result >= $04000000) and (Result < $08000000) then
    Result := $04000000 or (Result and $7FFFFF);
end;

// Bytes at A, wrapping from the end of VRAM's mirrors to their start.
procedure TransferRead(M: TPSPMemory; A: Cardinal; var Buf; Size: Cardinal);
begin
  var P := WrapVRAM(A);
  var N := Size;
  if (P >= $04000000) and (P < $08000000) and ((P and $7FFFFF) + Size > $800000) then
    N := $800000 - (P and $7FFFFF);
  M.ReadBytes(P, Buf, N);
  if N < Size then
    M.ReadBytes($04000000, PByte(@Buf)[N], Size - N);
end;

procedure TransferWrite(M: TPSPMemory; A: Cardinal; const Buf; Size: Cardinal);
begin
  var P := WrapVRAM(A);
  var N := Size;
  if (P >= $04000000) and (P < $08000000) and ((P and $7FFFFF) + Size > $800000) then
    N := $800000 - (P and $7FFFFF);
  M.WriteBytes(P, Buf, N);
  if N < Size then
    M.WriteBytes($04000000, PByte(@Buf)[N], Size - N);
end;

const
  // What a block transfer costs, ns per 10 bytes moved, by whether its
  // source and destination are in VRAM (probe ge_transfer): main RAM to RAM
  // is slowest, and RAM is slower to read than to write. Besides a start.
  GETransferCost: array[Boolean, Boolean] of Integer = ((81, 57), (34, 42));
  GETransferStartNs = 3000;

function InVRAM(A: Cardinal): Boolean; inline;
begin
  var P := A and $1FFFFFFF;
  Result := (P >= $04000000) and (P < $08000000);
end;

// TRANSFERSTART: a rectangle copy. The buffer addresses lose their low 4
// bits, and each row moves in 64-byte pieces, each read before it is
// written, so an overlapping copy repeats what it has just written once the
// destination is 64 bytes or more past the source.
procedure TPSPGEEngine.BlockTransfer(Op: Cardinal);
var
  Buf: array[0..63] of Byte;
begin
  var C: PGECmds := @Regs.Cmd;
  var Src := (((C[GE_TRANSFERSRCW] and $FF0000) shl 8) or (C[GE_TRANSFERSRC] and $FFFFFF)) and not Cardinal($F);
  var Dst := (((C[GE_TRANSFERDSTW] and $FF0000) shl 8) or (C[GE_TRANSFERDST] and $FFFFFF)) and not Cardinal($F);
  var SrcW := Integer(C[GE_TRANSFERSRCW] and $7F8);
  var DstW := Integer(C[GE_TRANSFERDSTW] and $7F8);
  var SX := Integer(C[GE_TRANSFERSRCPOS] and $3FF);
  var SY := Integer((C[GE_TRANSFERSRCPOS] shr 10) and $3FF);
  var DX := Integer(C[GE_TRANSFERDSTPOS] and $3FF);
  var DY := Integer((C[GE_TRANSFERDSTPOS] shr 10) and $3FF);
  var W := Integer(C[GE_TRANSFERSIZE] and $3FF) + 1;
  var H := Integer((C[GE_TRANSFERSIZE] shr 10) and $3FF) + 1;
  var Bpp := 2;
  if (Op and 1) <> 0 then
    Bpp := 4;
  var RowBytes := Cardinal(W * Bpp);
  for var Y := 0 to H - 1 do
  begin
    var SA := Src + Cardinal(((SY + Y) * SrcW + SX) * Bpp);
    var DA := Dst + Cardinal(((DY + Y) * DstW + DX) * Bpp);
    var Done: Cardinal := 0;
    while Done < RowBytes do
    begin
      var N := RowBytes - Done;
      if N > SizeOf(Buf) then
        N := SizeOf(Buf);
      TransferRead(FMemory, SA + Done, Buf, N);
      TransferWrite(FMemory, DA + Done, Buf, N);
      Inc(Done, N);
    end;
  end;
  FPrimCost := GETransferStartNs + Int64(W) * H * Bpp * GETransferCost[InVRAM(Src), InVRAM(Dst)] div 10;
end;

{ Context }

procedure TPSPGEEngine.SaveContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  FillChar(W, SizeOf(W), 0);
  W[0] := $00000001;
  W[5] := Regs.VAddr;
  W[6] := Regs.IAddr;
  W[7] := Regs.Offset;
  W[8] := Regs.BoneNum;
  W[9] := Regs.WorldNum;
  W[10] := Regs.ViewNum;
  W[11] := Regs.ProjNum;
  W[12] := Regs.TGenNum;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    W[N] := Regs.Cmd[C];
    Inc(N);
  end;
  for var I := 0 to 95 do
  begin
    W[N] := Regs.Bone[I];
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    W[N] := Regs.World[I];
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    W[N] := Regs.View[I];
    Inc(N);
  end;
  for var I := 0 to 15 do
  begin
    W[N] := Regs.Proj[I];
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    W[N] := Regs.TGen[I];
    Inc(N);
  end;
  FMemory.WriteBytes(Address, W[0], N * 4);
end;

procedure TPSPGEEngine.RestoreContext(Address: Cardinal);
begin
  var W: array[0..511] of Cardinal;
  var Total := GEContextCmdStart + Length(GEContextCmds) + 96 + 12 + 12 + 16 + 12;
  FMemory.ReadBytes(Address, W[0], Total * 4);
  Regs.VAddr := W[5];
  Regs.IAddr := W[6];
  Regs.Offset := W[7];
  Regs.BoneNum := W[8] and $7F;
  Regs.WorldNum := W[9] and $F;
  Regs.ViewNum := W[10] and $F;
  Regs.ProjNum := W[11] and $F;
  Regs.TGenNum := W[12] and $F;
  var N := GEContextCmdStart;
  for var C in GEContextCmds do
  begin
    Regs.Cmd[C] := (Cardinal(C) shl 24) or (W[N] and $FFFFFF);
    Inc(N);
  end;
  for var I := 0 to 95 do
  begin
    Regs.Bone[I] := W[N] and $FFFFFF;
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    Regs.World[I] := W[N] and $FFFFFF;
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    Regs.View[I] := W[N] and $FFFFFF;
    Inc(N);
  end;
  for var I := 0 to 15 do
  begin
    Regs.Proj[I] := W[N] and $FFFFFF;
    Inc(N);
  end;
  for var I := 0 to 11 do
  begin
    Regs.TGen[I] := W[N] and $FFFFFF;
    Inc(N);
  end;
end;

procedure InitContextCmds;
const
  Ranges: array[0..15, 0..1] of Byte = (
    ($00, $02), ($10, $10), ($12, $28), ($2C, $33), ($36, $38), ($42, $4D), ($50, $51), ($53, $58),
    ($5B, $B5), ($B8, $C3), ($C5, $D0), ($D2, $E9), ($EB, $EC), ($EE, $EE), ($F0, $F6), ($F8, $F9));
begin
  for var R := 0 to High(Ranges) do
    for var C := Ranges[R, 0] to Ranges[R, 1] do
      GEContextCmds := GEContextCmds + [Byte(C)];
end;

initialization
  InitContextCmds;

end.

