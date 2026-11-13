unit PSP.GE.Workers;

// The CPU renderer's primitive queue. Primitives queue in a batch with a copy
// of their raster state and CLUT; the pool draws a batch with every thread
// taking whole bands of rows and drawing each primitive of the batch that
// reaches its band, in order. A pixel belongs to one band and sees its
// primitives in GE order, so the result does not depend on the thread count.
// One batch may be drawn in the background while the next one fills; it is
// always finished before the next starts.
//
// Batches outlive the GE's command runs. The VRAM pages their primitives draw
// into are held (TPSPMemory.HoldVRAM): any access to them by the CPU, DMA,
// the display or the GE's own reads first draws everything queued. The pages
// their textures come from are watched (TPSPMemory.WatchPage): a write there
// first draws everything queued. A primitive whose buffers or texture overlap
// its batch's in another layout starts a new batch. Primitives whose rows
// alias each other or their own texture, or that could read a held page
// through the page table, are drawn alone after everything queued.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}
{$EXCESSPRECISION OFF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Diagnostics,
  System.SyncObjs, PSP.Types, PSP.Memory, PSP.GE.Texture, PSP.GE.Raster,
  HW.HostFPU;

type
  TGEJobKind = (gjTriangle, gjSprite, gjLine, gjPoint);

  TGEJob = record
    State: Integer;
    Prepared: Integer;
    Kind: TGEJobKind;
    Y1, Y2: Integer;
    V: array[0..2] of TGEVertex;
  end;

  PGEJob = ^TGEJob;

  // VRAM bytes [Lo, Hi) that a batch writes as a buffer (Bytes 2 or 4 a
  // colour pixel, 0 for depth, which also has a permutation) or reads.
  TGERange = record
    Base, Stride, Bytes: Cardinal;
    Permutation: Integer;
    Lo, Hi: Cardinal;
  end;

  PGERange = ^TGERange;

  PGERaster = ^TGERaster;

  TGEBatch = record
    Jobs: TArray<TGEJob>;
    Count: Integer;
    States: TArray<TGERaster>;
    StateCount: Integer;
    Cluts: TArray<Byte>;
    ClutCount: Integer;
    MinY, MaxY: Integer;
    Area: Int64;
    // The floating-point modes the primitives were given.
    MXCSR: UInt32;
    FPUControl: Word;
    BandTop, BandRows, Bands: Integer;
    NextBand: Integer;
    BandOffsets, BandJobs: TArray<Integer>;
    Prepared: TArray<TGEPreparedTriangle>;
  end;

  PGEBatch = ^TGEBatch;

  // What Add finds of a raster state's texture levels, the same for every
  // primitive with that state: the first level (in Add's order) a primitive
  // is drawn alone for whatever its buffers (Fail: -1 the format, LevelCount
  // none) and why, the VRAM levels' ranges before it (checked against each
  // primitive's buffers), and the ranges read and watched.
  TGETexInfo = record
    Fail, FailWhy, LevelCount: Integer;
    UsesClut: Boolean;
    InVRAM: array[0..7] of Boolean;
    Ranges: array[0..7] of TGERange;
    TexCount, WatchedCount: Integer;
    Tex: array[0..7] of TGERange;
    Watched: array[0..39] of TGERange;
  end;

  TGEWorkers = class;

  TGEWorker = class(TThread)
  private
    FOwner: TGEWorkers;
    FStart, FDone: TEvent;
    FError: Exception;
    FBusy: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TGEWorkers);
    destructor Destroy; override;
  end;

  TGEWorkers = class
  private
    const
      JobCapacity = 16384;
      ClutCapacity = 1024;
      RangeCapacity = 16;
      WatchCapacity = 256;
      // Smaller batches are drawn on the calling thread.
      ParallelArea = 24000;
      // A batch this large is started in the background when the GE stops.
      BackgroundArea = 60000;
  private
    FMemory: TPSPMemory;
    FThreads: Integer;
    FBatches: array[0..1] of TGEBatch;
    FBatch: PGEBatch;
    FFlight: PGEBatch;
    FFlightThreads: Integer;
    FStateDirty: Boolean;
    FLastSource: Pointer;
    FClutIndex: Integer;
    FClutGeneration, FClutSnapshot: Cardinal;
    FTargets: array[0..RangeCapacity - 1] of TGERange;
    FTargetCount: Integer;
    FReads: array[0..RangeCapacity - 1] of TGERange;
    FReadCount: Integer;
    FWatches: array[0..WatchCapacity - 1] of TGERange;
    FWatchCount: Integer;
    // The ranges the last primitive watched, all registered (in FWatches or
    // through Watch) since FWatches was last emptied (FWatchEpoch): the same
    // ranges need not be looked up again.
    FWatchEpoch, FLastWatchEpoch: Int64;
    FLastWatched: array[0..39] of TGERange;
    FLastWatchedCount: Integer;
    // The texture levels of the raster state last given (FTexSource), until
    // it changes (StateChanged); FTexGen counts the analyses.
    FTex: TGETexInfo;
    FTexSource: Pointer;
    FTexDirty: Boolean;
    FTexGen, FLastWatchGen: Integer;
    FHolding: Boolean;
    FSavedFault: TPSPVRAMFault;
    FBatchesDrawn, FBackground, FQueued, FAlone, FAccessSyncs, FSplits: Int64;
    FAloneWhy: array[0..6] of Int64;
    // Host time spent waiting for the pool, by what waited (statistics).
    FWaitReason: Integer;
    FWaitTicks: array[0..4] of Int64;
    FSerialTicks: Int64;
    // Of the waits: drawing bands on the emulator thread.
    FHelpTicks: Int64;
    FWorkers: array of TGEWorker;
    procedure StartWorkers;
    procedure Add(const S: TGERaster; Kind: TGEJobKind; const A, B, C: TGEVertex);
    procedure DrawAlone(const S: TGERaster; Kind: TGEJobKind; const A, B, C: TGEVertex; Why: Integer);
    procedure Attach;
    procedure AnalyseTexture(const S: TGERaster);
    procedure Hold(Lo, Hi: Cardinal);
    procedure Extend(var T: TGERange; Lo, Hi: Cardinal);
    procedure Watch(Lo, Hi: Cardinal);
    procedure Fault;
    // Starts drawing the filling batch (in the background when large enough)
    // and begins the next one.
    procedure Kick;
    procedure PrepareBands(B: PGEBatch);
    procedure WaitFlight;
    procedure DrawSerial(B: PGEBatch);
    procedure WorkBands(B: PGEBatch);
  public
    constructor Create(Memory: TPSPMemory);
    destructor Destroy; override;
    procedure Triangle(const S: TGERaster; const A, B, C: TGEVertex);
    procedure Sprite(const S: TGERaster; const A, B: TGEVertex);
    procedure Line(const S: TGERaster; const A, B: TGEVertex);
    procedure Point(const S: TGERaster; const A: TGEVertex);
    // The raster state the engine passes has changed since the last primitive.
    procedure StateChanged; inline;
    // The CLUT the raster state points to has been loaded again.
    procedure ClutChanged; inline;
    // The GE stops running for now: a large batch starts in the background.
    procedure Release;
    // Draws everything queued and gives the held and watched pages back.
    procedure Sync;
    function Describe: string;
    property Threads: Integer read FThreads;
  end;

implementation

var
  GKickArea: Int64 = 400000;
  GKickCount: Integer = 4096;
  GReleaseArea: Int64 = 60000;
  GBandsPerThread: Integer = 3;

const
  AloneNames: array[0..6] of string = ('stride', 'wrap', 'depth layout', 'depth on colour', 'texture layout',
    'texture beyond its level', 'own texture');

// FP state inherited by portable workers, including ARM64's round/mask.
function GetModes(out Control: Word): UInt32; inline;
begin
{$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}
  Control := Get8087CW;
{$ELSE}
  Control := Ord(GetRoundMode) or (Word(Byte(GetExceptionMask)) shl 8);
{$ENDIF}
  Result := ReadHostMXCSR;
end;

procedure SetModes(MXCSR: UInt32; Control: Word); inline;
begin
{$IF Defined(MSWINDOWS) and (Defined(CPUX86) or Defined(CPUX64))}
  {$WARN SYMBOL_PLATFORM OFF}
  SetMXCSR(MXCSR);
  {$WARN SYMBOL_PLATFORM ON}
  Set8087CW(Control);
{$ELSE}
  SetExceptionMask(TArithmeticExceptionMask(Byte(Control shr 8)));
  SetRoundMode(TRoundingMode(Control and 3));
  WriteHostMXCSR(MXCSR);
{$ENDIF}
end;

procedure DrawJob(const S: TGERaster; Kind: TGEJobKind; const A, B, C: TGEVertex); inline;
begin
  case Kind of
    gjTriangle:
      GEDrawTriangle(S, A, B, C);
    gjSprite:
      GEDrawSprite(S, A, B);
    gjLine:
      GEDrawLine(S, A, B);
  else
    GEDrawPoint(S, A);
  end;
end;

function Overlaps(Lo1, Hi1, Lo2, Hi2: Cardinal): Boolean; inline;
begin
  Result := (Lo1 < Hi2) and (Lo2 < Hi1);
end;

function SameLayout(const A, B: TGERange): Boolean; inline;
begin
  Result := (A.Base = B.Base) and (A.Stride = B.Stride) and (A.Bytes = B.Bytes) and (A.Permutation = B.Permutation);
end;

constructor TGEWorker.Create(Owner: TGEWorkers);
begin
  FOwner := Owner;
  FStart := TEvent.Create(nil, False, False, '');
  FDone := TEvent.Create(nil, False, False, '');
  inherited Create(False);
end;

destructor TGEWorker.Destroy;
begin
  Terminate;
  if FStart <> nil then
    FStart.SetEvent;
  WaitFor;
  FStart.Free;
  FDone.Free;
  FError.Free;
  inherited;
end;

procedure TGEWorker.Execute;
begin
  while True do
  begin
    FStart.WaitFor(INFINITE);
    if Terminated then
      Exit;
    try
      var B := FOwner.FFlight;
      SetModes(B.MXCSR, B.FPUControl);
      var T := TStopwatch.GetTimeStamp;
      FOwner.WorkBands(B);
      Inc(FBusy, TStopwatch.GetTimeStamp - T);
    except
      FError := Exception(AcquireExceptionObject);
    end;
    FDone.SetEvent;
  end;
end;

constructor TGEWorkers.Create(Memory: TPSPMemory);
begin
  inherited Create;
  FMemory := Memory;
  FThreads := 1;
  // The pool draws while the emulator thread goes on: leave it and one more.
  FThreads := EnsureRange(StrToIntDef(GetEnvironmentVariable('PSP_GE_THREADS'),
      Min(10, TThread.ProcessorCount - 2)), 1, 16);
  if FMemory = nil then
    FThreads := 1;
  if FThreads > 1 then
    for var I := 0 to 1 do
    begin
      SetLength(FBatches[I].Jobs, JobCapacity);
      SetLength(FBatches[I].States, 64);
      SetLength(FBatches[I].Cluts, ClutCapacity * 1024);
    end;
  FBatch := @FBatches[0];
  FWaitReason := 4;
  // Measurements: PSP_GE_TUNE=kick area,kick count,area started when the GE
  // stops,bands a thread.
  var Tune := GetEnvironmentVariable('PSP_GE_TUNE').Split([',']);
  if Length(Tune) = 4 then
  begin
    GKickArea := StrToInt64(Tune[0]);
    GKickCount := StrToInt(Tune[1]);
    GReleaseArea := StrToInt64(Tune[2]);
    GBandsPerThread := StrToInt(Tune[3]);
  end;
  FClutIndex := -1;
  FStateDirty := True;
end;

destructor TGEWorkers.Destroy;
begin
  if FHolding or (FBatch.Count > 0) or (FFlight <> nil) then
    Sync;
  for var W in FWorkers do
    W.Free;
  inherited;
end;

procedure TGEWorkers.StartWorkers;
begin
  if Length(FWorkers) <> 0 then
    Exit;
  SetLength(FWorkers, FThreads);
  for var I := 0 to High(FWorkers) do
    FWorkers[I] := TGEWorker.Create(Self);
end;

procedure TGEWorkers.StateChanged;
begin
  FStateDirty := True;
  FTexDirty := True;
end;

procedure TGEWorkers.ClutChanged;
begin
  Inc(FClutGeneration);
end;

procedure TGEWorkers.Triangle(const S: TGERaster; const A, B, C: TGEVertex);
begin
  Add(S, gjTriangle, A, B, C);
end;

procedure TGEWorkers.Sprite(const S: TGERaster; const A, B: TGEVertex);
begin
  Add(S, gjSprite, A, B, B);
end;

procedure TGEWorkers.Line(const S: TGERaster; const A, B: TGEVertex);
begin
  Add(S, gjLine, A, B, B);
end;

procedure TGEWorkers.Point(const S: TGERaster; const A: TGEVertex);
begin
  Add(S, gjPoint, A, A, A);
end;

procedure TGEWorkers.DrawAlone(const S: TGERaster; Kind: TGEJobKind; const A, B, C: TGEVertex; Why: Integer);
begin
  Inc(FAlone);
  Inc(FAloneWhy[Why]);
  FWaitReason := 3;
  Sync;
  FWaitReason := 4;
  DrawJob(S, Kind, A, B, C);
end;

procedure TGEWorkers.Attach;
begin
  if FHolding then
    Exit;
  FSavedFault := FMemory.OnVRAMFault;
  FMemory.OnVRAMFault := Fault;
  FHolding := True;
end;

procedure TGEWorkers.Hold(Lo, Hi: Cardinal);
begin
  if Hi <= Lo then
    Exit;
  Attach;
  for var Page := Integer(Lo shr PSPPageShift) to Integer((Hi - 1) shr PSPPageShift) do
    FMemory.HoldVRAM(Page);
end;

// Physical bytes [Lo, Hi) of the whole map.
// A target's range grows to [Lo, Hi): its pages are held (those of the
// range before still are: holds are only given back by Sync, which also
// empties the targets).
procedure TGEWorkers.Extend(var T: TGERange; Lo, Hi: Cardinal);
begin
  if Lo < T.Lo then
  begin
    Hold(Lo, T.Lo);
    T.Lo := Lo;
  end;
  if Hi > T.Hi then
  begin
    Hold(T.Hi, Hi);
    T.Hi := Hi;
  end;
end;

procedure TGEWorkers.Watch(Lo, Hi: Cardinal);
begin
  if Hi <= Lo then
    Exit;
  Attach;
  for var Page := Integer(Lo shr PSPPageShift) to Integer((Hi - 1) shr PSPPageShift) do
    if Page < PSPPageCount then
      FMemory.WatchPage(Page);
end;

procedure TGEWorkers.Fault;
begin
  Inc(FAccessSyncs);
  FWaitReason := 2;
  Sync;
  FWaitReason := 4;
end;

procedure TGEWorkers.Release;
begin
  if (FBatch.Count > 0) and (FBatch.Area >= GReleaseArea) then
  begin
    FWaitReason := 0;
    Kick;
    FWaitReason := 4;
  end;
end;

procedure TGEWorkers.Sync;
begin
  if FBatch.Count > 0 then
    Kick;
  WaitFlight;
  if FHolding then
  begin
    FHolding := False;
    FMemory.ReleaseVRAM;
    FMemory.ReleaseWatches;
    FWatchCount := 0;
    Inc(FWatchEpoch);
    FMemory.OnVRAMFault := FSavedFault;
    FSavedFault := nil;
  end;
end;

procedure TGEWorkers.WaitFlight;
begin
  if FFlight = nil then
    Exit;
  var B := FFlight;
  var T := TStopwatch.GetTimeStamp;
  try
    // Rather than wait, draw the bands nobody has taken yet.
    if B.NextBand < B.Bands then
    begin
      var SavedControl: Word;
      var SavedMXCSR := GetModes(SavedControl);
      SetModes(B.MXCSR, B.FPUControl);
      var H := TStopwatch.GetTimeStamp;
      try
        WorkBands(B);
      finally
        SetModes(SavedMXCSR, SavedControl);
        Inc(FHelpTicks, TStopwatch.GetTimeStamp - H);
      end;
    end;
  finally
    for var I := 0 to FFlightThreads - 1 do
      FWorkers[I].FDone.WaitFor(INFINITE);
  end;
  Inc(FWaitTicks[FWaitReason], TStopwatch.GetTimeStamp - T);
  FFlight := nil;
  B.Count := 0;
  B.StateCount := 0;
  B.ClutCount := 0;
  B.Area := 0;
  for var I := 0 to FFlightThreads - 1 do
    if FWorkers[I].FError <> nil then
    begin
      var E := FWorkers[I].FError;
      FWorkers[I].FError := nil;
      raise E;
    end;
end;

procedure TGEWorkers.PrepareBands(B: PGEBatch);
var
  Heads: array[0..256] of Integer;
begin
  if Length(B.BandOffsets) < B.Bands + 1 then
    SetLength(B.BandOffsets, B.Bands + 1);
  FillChar(B.BandOffsets[0], (B.Bands + 1) * SizeOf(Integer), 0);
  for var I := 0 to B.Count - 1 do
  begin
    var J: PGEJob := @B.Jobs[I];
    var First := EnsureRange((J.Y1 - B.BandTop) div B.BandRows, 0, B.Bands - 1);
    var Last := EnsureRange((J.Y2 - B.BandTop) div B.BandRows, First, B.Bands - 1);
    for var Band := First to Last do
      Inc(B.BandOffsets[Band + 1]);
  end;
  for var Band := 0 to B.Bands - 1 do
  begin
    Inc(B.BandOffsets[Band + 1], B.BandOffsets[Band]);
    Heads[Band] := B.BandOffsets[Band];
  end;
  var Need := B.BandOffsets[B.Bands];
  if Length(B.BandJobs) < Need then
    SetLength(B.BandJobs, Max(Need, Length(B.BandJobs) * 2));
  var PreparedCount := 0;
  var SavedControl: Word;
  var SavedMXCSR := GetModes(SavedControl);
  SetModes(B.MXCSR, B.FPUControl);
  try
    for var I := 0 to B.Count - 1 do
    begin
      var J: PGEJob := @B.Jobs[I];
      var First := EnsureRange((J.Y1 - B.BandTop) div B.BandRows, 0, B.Bands - 1);
      var Last := EnsureRange((J.Y2 - B.BandTop) div B.BandRows, First, B.Bands - 1);
      J.Prepared := -1;
      if (J.Kind = gjTriangle) and (Last > First) then
      begin
        if PreparedCount = Length(B.Prepared) then
          SetLength(B.Prepared, Max(64, PreparedCount * 2));
        GEPrepareTriangle(B.States[J.State], J.V[0], J.V[1], J.V[2], B.Prepared[PreparedCount]);
        J.Prepared := PreparedCount;
        Inc(PreparedCount);
      end;
      for var Band := First to Last do
      begin
        B.BandJobs[Heads[Band]] := I;
        Inc(Heads[Band]);
      end;
    end;
  finally
    SetModes(SavedMXCSR, SavedControl)
  end;
end;

procedure TGEWorkers.Kick;
begin
  WaitFlight;
  var B := FBatch;
  if B.Count = 0 then
    Exit;
  Inc(FBatchesDrawn);
  // The next primitives go into the other batch, with their own lists.
  FTargetCount := 0;
  FReadCount := 0;
  FClutIndex := -1;
  FStateDirty := True;
  var Rows := B.MaxY - B.MinY + 1;
  B.BandTop := B.MinY;
  B.BandRows := Max(4, Rows div (FThreads * GBandsPerThread));
  B.Bands := (Rows + B.BandRows - 1) div B.BandRows;
  B.NextBand := 0;
  if (B.Area >= ParallelArea) and (B.Bands > 1) then
  begin
    PrepareBands(B);
    Inc(FBackground);
    StartWorkers;
    FFlight := B;
    FFlightThreads := Min(FThreads, B.Bands);
    for var I := 0 to FFlightThreads - 1 do
      FWorkers[I].FStart.SetEvent;
    if FBatch = @FBatches[0] then
      FBatch := @FBatches[1]
    else
      FBatch := @FBatches[0];
    Exit;
  end;
  try
    DrawSerial(B);
  finally
    B.Count := 0;
    B.StateCount := 0;
    B.ClutCount := 0;
    B.Area := 0;
  end;
end;

procedure TGEWorkers.DrawSerial(B: PGEBatch);
begin
  var SavedControl: Word;
  var SavedMXCSR := GetModes(SavedControl);
  SetModes(B.MXCSR, B.FPUControl);
  var T := TStopwatch.GetTimeStamp;
  try
    for var I := 0 to B.Count - 1 do
    begin
      var J: PGEJob := @B.Jobs[I];
      DrawJob(B.States[J.State], J.Kind, J.V[0], J.V[1], J.V[2]);
    end;
  finally
    SetModes(SavedMXCSR, SavedControl);
    Inc(FSerialTicks, TStopwatch.GetTimeStamp - T);
  end;
end;

procedure TGEWorkers.WorkBands(B: PGEBatch);
var
  local: TGERaster;
begin
  while True do
  begin
    var Band := AtomicIncrement(B.NextBand) - 1;
    if Band >= B.Bands then
      Break;
    var Y1 := B.BandTop + Band * B.BandRows;
    var Y2 := Y1 + B.BandRows - 1;
    var Current := -1;
    for var At := B.BandOffsets[Band] to B.BandOffsets[Band + 1] - 1 do
    begin
      var J: PGEJob := @B.Jobs[B.BandJobs[At]];
      if (J.Y2 < Y1) or (J.Y1 > Y2) then
        Continue;
      if J.State <> Current then
      begin
        Current := J.State;
        local := B.States[Current];
        local.BandY1 := Max(local.BandY1, Y1);
        local.BandY2 := Min(local.BandY2, Y2);
      end;
      if J.Prepared >= 0 then
        GEDrawPreparedTriangle(local, J.V[0], J.V[1], J.V[2], B.Prepared[J.Prepared])
      else
        DrawJob(local, J.Kind, J.V[0], J.V[1], J.V[2]);
    end;
  end;
end;

procedure TGEWorkers.AnalyseTexture(const S: TGERaster);
begin
  // Add's texture checks, in its order, but those against a primitive's
  // buffers (InVRAM, Ranges).
  var TI: ^TGETexInfo := @FTex;
  FTexSource := @S;
  FTexDirty := False;
  Inc(FTexGen);
  TI.TexCount := 0;
  TI.WatchedCount := 0;
  TI.UsesClut := False;
  TI.LevelCount := 0;
  TI.Fail := 0;
  TI.FailWhy := 0;
  if not S.Textured then
    Exit;
  TI.UsesClut := S.Tex.Format in [4..7];
  if (S.Tex.Format > 10) or (S.Tex.LevelCount > 8) then
  begin
    TI.Fail := -1;
    TI.FailWhy := 4;
    Exit;
  end;
  TI.LevelCount := S.Tex.LevelCount;
  TI.Fail := TI.LevelCount;
  var Base := NativeUInt(S.VRAM);
  for var I := 0 to S.Tex.LevelCount - 1 do
  begin
    TI.InVRAM[I] := False;
    var L: PGETexLevel := @S.Tex.Levels[I];
    if (L.Ptr = nil) or (L.Width <= 0) or (L.Height <= 0) or (L.BufWidth < 0) then
    begin
      TI.Fail := I;
      TI.FailWhy := 4;
      Exit;
    end;
    var Reach := Max(GELevelReach(S.Tex, L^), UInt64(L.Size));
    var P := NativeUInt(L.Ptr);
    if (P >= Base) and (P < Base + PSPVRAMSize) then
    begin
      var R: TGERange;
      R := Default(TGERange);
      R.Lo := Cardinal(P - Base);
      R.Hi := R.Lo + L.Size;
      if (Reach > L.Size) or (R.Hi > PSPVRAMSize) then
      begin
        TI.Fail := I;
        TI.FailWhy := 5;
        Exit;
      end;
      TI.InVRAM[I] := True;
      TI.Ranges[I] := R;
      TI.Tex[TI.TexCount] := R;
      Inc(TI.TexCount);
      // Every mirror of its 64 KB blocks: odd mirrors permute within them.
      for var M := 0 to 3 do
      begin
        TI.Watched[TI.WatchedCount] := Default(TGERange);
        TI.Watched[TI.WatchedCount].Lo := PSPVRAMBase + Cardinal(M) * PSPVRAMSize + (R.Lo and not Cardinal($FFFF));
        TI.Watched[TI.WatchedCount].Hi := PSPVRAMBase + Cardinal(M) * PSPVRAMSize +
          ((R.Hi + $FFFF) and not Cardinal($FFFF));
        Inc(TI.WatchedCount);
      end;
    end
    else
    begin
      var Lo := UInt64(L.Addr and $1FFFFFFF);
      if (Reach > L.Size) and ((Lo < PSPRAMBase) or (Lo + Reach > PSPRAMBase + PSPRAMSize)) then
      begin
        TI.Fail := I;
        TI.FailWhy := 5;
        Exit;
      end;
      TI.Watched[TI.WatchedCount] := Default(TGERange);
      TI.Watched[TI.WatchedCount].Lo := Cardinal(Lo);
      TI.Watched[TI.WatchedCount].Hi := Cardinal(Min(Lo + Reach, UInt64($20000000)));
      Inc(TI.WatchedCount);
    end;
  end;
end;

procedure TGEWorkers.Add(const S: TGERaster; Kind: TGEJobKind; const A, B, C: TGEVertex);
var
  Col, Dep: TGERange;
begin
  if FThreads <= 1 then
  begin
    // Serial reference: the drawing time is the CPU renderer's cost.
    var T := TStopwatch.GetTimeStamp;
    DrawJob(S, Kind, A, B, C);
    Inc(FSerialTicks, TStopwatch.GetTimeStamp - T);
    Exit;
  end;
  if (S.ScissorX1 > S.ScissorX2) or (S.ScissorY1 > S.ScissorY2) then
    Exit;
  // Rows and columns the primitive may reach (lines and points: the scissor).
  var Y1 := Max(S.ScissorY1, S.BandY1);
  var Y2 := Min(S.ScissorY2, S.BandY2);
  var X1 := S.ScissorX1;
  var X2 := S.ScissorX2;
  if Kind in [gjTriangle, gjSprite] then
  begin
    var MinY := Min(A.Y, B.Y);
    var MaxY := Max(A.Y, B.Y);
    var MinX := Min(A.X, B.X);
    var MaxX := Max(A.X, B.X);
    if Kind = gjTriangle then
    begin
      MinY := Min(MinY, C.Y);
      MaxY := Max(MaxY, C.Y);
      MinX := Min(MinX, C.X);
      MaxX := Max(MaxX, C.X);
    end;
    Y1 := Max(Y1, MinY div 16 - 2);
    Y2 := Min(Y2, MaxY div 16 + 2);
    X1 := Max(X1, MinX div 16 - 2);
    X2 := Min(X2, MaxX div 16 + 2);
  end;
  if (Y1 > Y2) or (X1 > X2) then
    Exit;
  // Texels through the texture cache: its pixels in order.
  if S.Textured and (S.Tex.Cache <> nil) then
  begin
    DrawAlone(S, Kind, A, B, C, 6);
    Exit;
  end;

  // The buffers it draws into. Columns past the stride would write the next
  // row, which may be another band's.
  if Cardinal(X2) >= S.FBStride then
  begin
    DrawAlone(S, Kind, A, B, C, 0);
    Exit;
  end;
  var Bpp: Cardinal := 2;
  if S.FBFormat = 3 then
    Bpp := 4;
  Col.Base := S.FBAddr;
  Col.Stride := S.FBStride;
  Col.Bytes := Bpp;
  Col.Permutation := 0;
  Col.Lo := S.FBAddr + (Cardinal(Y1) * S.FBStride + Cardinal(X1)) * Bpp;
  Col.Hi := S.FBAddr + (Cardinal(Y2) * S.FBStride + Cardinal(X2) + 1) * Bpp;
  if Col.Hi > PSPVRAMSize then
  begin
    DrawAlone(S, Kind, A, B, C, 1);
    Exit;
  end;
  var HasZ := S.DepthTest or (S.ClearMode and S.ClearDepth);
  if HasZ then
  begin
    Dep.Base := S.ZAddr;
    Dep.Stride := S.ZStride;
    Dep.Bytes := 0;
    Dep.Permutation := S.ZPermutation;
    // Depth's bank permutation (PSPDepthOffset) stays within an aligned block:
    // 2 KB untranslated, else of 16 times the translation width.
    var Block: Cardinal := $800;
    if S.ZPermutation > 0 then
      Block := Cardinal(1) shl Min(S.ZPermutation + 4, 21);
    Dep.Lo := (S.ZAddr + (Cardinal(Y1) * S.ZStride + Cardinal(X1)) * 2) and not (Block - 1);
    Dep.Hi := (S.ZAddr + (Cardinal(Y2) * S.ZStride + Cardinal(X2) + 1) * 2 + Block - 1) and not (Block - 1);
    if (Cardinal(X2) >= S.ZStride) or (Dep.Hi > PSPVRAMSize) then
    begin
      DrawAlone(S, Kind, A, B, C, 2);
      Exit;
    end;
    if Overlaps(Col.Lo, Col.Hi, Dep.Lo, Dep.Hi) then
    begin
      DrawAlone(S, Kind, A, B, C, 3);
      Exit;
    end;
  end;

  // The texture levels: in VRAM they must lie within their level and apart
  // from this primitive's buffers; elsewhere, reads past the level go
  // through the page table, so they must stay in RAM (never held). (What
  // depends on the state alone: AnalyseTexture.)
  if FTexDirty or (FTexSource <> @S) then
    AnalyseTexture(S);
  var TI: ^TGETexInfo := @FTex;
  if S.Textured then
  begin
    if TI.Fail < 0 then
    begin
      DrawAlone(S, Kind, A, B, C, TI.FailWhy);
      Exit;
    end;
    for var I := 0 to Min(TI.Fail, TI.LevelCount) - 1 do
      if TI.InVRAM[I] and (Overlaps(TI.Ranges[I].Lo, TI.Ranges[I].Hi, Col.Lo, Col.Hi) or
        (HasZ and Overlaps(TI.Ranges[I].Lo, TI.Ranges[I].Hi, Dep.Lo, Dep.Hi))) then
      begin
        DrawAlone(S, Kind, A, B, C, 6);
        Exit;
      end;
    if TI.Fail < TI.LevelCount then
    begin
      DrawAlone(S, Kind, A, B, C, TI.FailWhy);
      Exit;
    end;
  end;
  var TexCount := TI.TexCount;
  var WatchedCount := TI.WatchedCount;
  var UsesClut := TI.UsesClut;

  // Another layout of the same bytes, or bytes the batch reads and this one
  // writes (or the reverse), start a new batch. So do other floating-point
  // modes: a batch draws in the modes it was given, not in those of whoever
  // later makes it draw (the guest CPU's, say).
  var Batch := FBatch;
  var FPUControl: Word;
  var MXCSR := GetModes(FPUControl) and not UInt32($3F);
  var Split := (Batch.Count = JobCapacity) or (FTargetCount > RangeCapacity - 2) or (FReadCount > RangeCapacity - 8) or
    (UsesClut and (Batch.ClutCount = ClutCapacity) and ((FClutIndex < 0) or (FClutSnapshot <> FClutGeneration))) or
    ((Batch.Count > 0) and ((MXCSR <> Batch.MXCSR) or (FPUControl <> Batch.FPUControl)));
  if not Split and (Batch.Count > 0) then
  begin
    for var I := 0 to FTargetCount - 1 do
    begin
      var T: PGERange := @FTargets[I];
      if not SameLayout(T^, Col) and Overlaps(T.Lo, T.Hi, Col.Lo, Col.Hi) then
        Split := True;
      if HasZ and not SameLayout(T^, Dep) and Overlaps(T.Lo, T.Hi, Dep.Lo, Dep.Hi) then
        Split := True;
      for var J := 0 to TexCount - 1 do
        if Overlaps(T.Lo, T.Hi, TI.Tex[J].Lo, TI.Tex[J].Hi) then
          Split := True;
      if Split then
        Break;
    end;
    if not Split then
      for var I := 0 to FReadCount - 1 do
        if Overlaps(FReads[I].Lo, FReads[I].Hi, Col.Lo, Col.Hi) or (HasZ and Overlaps(FReads[I].Lo, FReads[I].Hi,
            Dep.Lo, Dep.Hi)) then
        begin
          Split := True;
          Break;
        end;
  end;
  if Split and (Batch.Count > 0) then
  begin
    Inc(FSplits);
    FWaitReason := 1;
    Kick;
    FWaitReason := 4;
    Batch := FBatch;
  end;

  // The buffers, held until drawn; the textures, watched.
  var Found := False;
  for var I := 0 to FTargetCount - 1 do
    if SameLayout(FTargets[I], Col) then
    begin
      if (Col.Lo < FTargets[I].Lo) or (Col.Hi > FTargets[I].Hi) then
        Extend(FTargets[I], Col.Lo, Col.Hi);
      Found := True;
      Break;
    end;
  if not Found then
  begin
    FTargets[FTargetCount] := Col;
    Inc(FTargetCount);
    Hold(Col.Lo, Col.Hi);
  end;
  if HasZ then
  begin
    Found := False;
    for var I := 0 to FTargetCount - 1 do
      if SameLayout(FTargets[I], Dep) then
      begin
        if (Dep.Lo < FTargets[I].Lo) or (Dep.Hi > FTargets[I].Hi) then
          Extend(FTargets[I], Dep.Lo, Dep.Hi);
        Found := True;
        Break;
      end;
    if not Found then
    begin
      FTargets[FTargetCount] := Dep;
      Inc(FTargetCount);
      Hold(Dep.Lo, Dep.Hi);
    end;
  end;
  for var J := 0 to TexCount - 1 do
  begin
    Found := False;
    for var I := 0 to FReadCount - 1 do
      if (TI.Tex[J].Lo >= FReads[I].Lo) and (TI.Tex[J].Hi <= FReads[I].Hi) then
      begin
        Found := True;
        Break;
      end;
    if not Found then
    begin
      FReads[FReadCount] := TI.Tex[J];
      Inc(FReadCount);
    end;
  end;
  // (The previous primitive's ranges again, since FWatches was emptied: each
  // is in FWatches or its pages are watched already.)
  if (FLastWatchEpoch <> FWatchEpoch) or ((FLastWatchGen <> FTexGen) and ((WatchedCount <> FLastWatchedCount) or
    ((WatchedCount > 0) and not CompareMem(@TI.Watched, @FLastWatched, WatchedCount * SizeOf(TGERange))))) then
  begin
    for var J := 0 to WatchedCount - 1 do
    begin
      Found := False;
      for var I := 0 to FWatchCount - 1 do
        if (TI.Watched[J].Lo >= FWatches[I].Lo) and (TI.Watched[J].Hi <= FWatches[I].Hi) then
        begin
          Found := True;
          Break;
        end;
      if not Found then
      begin
        if FWatchCount < WatchCapacity then
        begin
          FWatches[FWatchCount] := TI.Watched[J];
          Inc(FWatchCount);
        end;
        Watch(TI.Watched[J].Lo, TI.Watched[J].Hi);
      end;
    end;
    if WatchedCount > 0 then
      Move(TI.Watched, FLastWatched, WatchedCount * SizeOf(TGERange));
    FLastWatchedCount := WatchedCount;
  end;
  FLastWatchEpoch := FWatchEpoch;
  FLastWatchGen := FTexGen;

  // The state, with the batch's own copy of the CLUT as loaded now.
  if UsesClut and ((FClutIndex < 0) or (FClutSnapshot <> FClutGeneration)) then
  begin
    FClutIndex := Batch.ClutCount;
    Inc(Batch.ClutCount);
    Move(S.Tex.Clut^, Batch.Cluts[FClutIndex * 1024], 1024);
    FClutSnapshot := FClutGeneration;
    FStateDirty := True;
  end;
  if FStateDirty or (FLastSource <> @S) or (Batch.StateCount = 0) then
  begin
    if Batch.StateCount = Length(Batch.States) then
      SetLength(Batch.States, Batch.StateCount * 2);
    var N: PGERaster := @Batch.States[Batch.StateCount];
    N^ := S;
    if UsesClut then
      N.Tex.Clut := @Batch.Cluts[FClutIndex * 1024];
    if (Batch.StateCount = 0) or not CompareMem(N, @Batch.States[Batch.StateCount - 1], SizeOf(TGERaster)) then
      Inc(Batch.StateCount);
    FStateDirty := False;
    FLastSource := @S;
  end;

  var J: PGEJob := @Batch.Jobs[Batch.Count];
  J.State := Batch.StateCount - 1;
  J.Prepared := -1;
  J.Kind := Kind;
  J.Y1 := Y1;
  J.Y2 := Y2;
  J.V[0] := A;
  J.V[1] := B;
  J.V[2] := C;
  if Batch.Count = 0 then
  begin
    Batch.MinY := Y1;
    Batch.MaxY := Y2;
    Batch.MXCSR := MXCSR;
    Batch.FPUControl := FPUControl;
  end
  else
  begin
    Batch.MinY := Min(Batch.MinY, Y1);
    Batch.MaxY := Max(Batch.MaxY, Y2);
  end;
  Inc(Batch.Count);
  Inc(FQueued);
  if Kind in [gjTriangle, gjSprite] then
    Inc(Batch.Area, Int64(Y2 - Y1 + 1) * (X2 - X1 + 1))
  else
    Inc(Batch.Area, Int64(Y2 - Y1 + 1));
  // A full batch starts drawing while the next one fills.
  if (Batch.Area >= GKickArea) or (Batch.Count >= GKickCount) then
  begin
    FWaitReason := 1;
    Kick;
    FWaitReason := 4;
  end;
end;

function TGEWorkers.Describe: string;
begin
  Result := Format('%d threads, %d batches (%d in the background, %d split, %d synchronized by access), ' +
    '%d queued, %d drawn alone',
    [FThreads, FBatchesDrawn, FBackground, FSplits, FAccessSyncs, FQueued, FAlone]);
  for var I := 0 to High(FAloneWhy) do
    if FAloneWhy[I] > 0 then
      Result := Result + Format(', %s %d', [AloneNames[I], FAloneWhy[I]]);
  var F := TStopwatch.Frequency;
  var Busy: Int64 := 0;
  for var W in FWorkers do
    Inc(Busy, W.FBusy);
  Result := Result + Format('; pool busy %.2fs', [Busy / F]);

  Result := Result + Format('; waited %.2fs (GE stop %.2f, split %.2f, access %.2f, alone %.2f, other %.2f), ' +
    'drawn on the emulator thread %.2fs, helping the pool %.2fs',
    [(FWaitTicks[0] + FWaitTicks[1] + FWaitTicks[2] + FWaitTicks[3] + FWaitTicks[4]) / F, FWaitTicks[0] / F,
      FWaitTicks[1] / F, FWaitTicks[2] / F, FWaitTicks[3] / F, FWaitTicks[4] / F, FSerialTicks / F,
      FHelpTicks / F]);
end;

end.

