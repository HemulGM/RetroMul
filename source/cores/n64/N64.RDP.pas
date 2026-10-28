unit N64.RDP;
// Hot emulation paths use explicit guest arithmetic and bounded indices.
// Define N64_CHECKED to enable range and overflow checks for diagnostics.
// Keep hot paths optimized in application Debug builds as well.
{$IFDEF N64_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, N64.Types,
  Core.Snapshots;

type
  TN64RDPCommandTrace = procedure(const Words: TArray<Cardinal>) of object;
  // Diagnostics: a primitive is done, with the pixels it drew (or, on a timing
  // RDP, would draw).

  TN64RDPPrimitiveTrace = procedure(Pixels: Int64) of object;

  // Diagnostics: the modes the current primitive is drawn with.
  TN64RDPModeWords = record
    Code, Cycle, Tile, TileFormat, TileSize, ColorSize, ColorFormat: Integer;
    CombineHi, CombineLo, OtherHi, OtherLo: Cardinal;
    // TN64RDP.SerialReason.
    Serial: Integer;
  end;
  // The two command words of each 64-bit step, as Execute reads them.

  TN64RDPWords = procedure(W0, W1: Cardinal) of object;

  TN64RDPWordOut = procedure(Value: Cardinal) of object;

  TN64RDPWordIn = function: Cardinal of object;

  TN64RDPGroup = class;

  // Per quarter line of a row.
  TN64Quarters = array[0..3] of Integer;

  TN64Texel = record
    C: array[0..3] of Integer; // RGBA, nine bits including signed conversion output.
  end;

  // Combiner inputs of the pixel being drawn: slots of four lanes (red,
  // green, blue, alpha), which the decoded mux legs index as one flat array.
  TN64CombineInputs = record
    case Integer of
      0:
        (Slots: array[0..15] of TN64Texel);
      1:
        (Flat: array[0..63] of Integer);
  end;

  // The modes as the drawing primitives use them, decoded by DecodeMode
  // whenever a mode, the combiner or one of its constants changed.
  TN64RDPMode = record
    Textured: Boolean;
    // The first combiner cycle run: 0 in two-cycle mode, else 1.
    FirstCycle: Integer;
    // Flat input index of each mux leg, per combiner cycle and lane (lane 3
    // is the alpha equation).
    LegA, LegB, LegC, LegD: array[0..1, 0..3] of Byte;
    // Dither: noise for the combiner or the alpha dither, a seed step for
    // the RGB dither, alpha dither from the noise, else by matrix index.
    NeedsNoise, RGBNoise, AlphaNoise: Boolean;
    AlphaDither: array[0..15] of Byte;
    // Noise generator steps of each pixel RasterRow hands to RasterPixel,
    // and whether a pixel with a colour image address takes one more (the
    // alpha compare with a random threshold).
    PixelSteps: Integer;
    CompareStep: Boolean;
    // Blender mux selections per cycle.
    M1A, M1B, M2A, M2B: array[0..1] of Integer;
  end;

  TN64Tile = record
    Format, Size, Line, TMEM, Palette, SL, TL, SH, TH: Integer;
    ClampS, ClampT, MirrorS, MirrorT: Boolean;
    MaskS, MaskT, ShiftS, ShiftT: Integer;
  end;

  // Raster state of the primitive being drawn (Triangle sets it up, RasterRow
  // and RasterPixel read it). Not serialized: primitives complete in Execute.
  TN64Primitive = record
    // Raw 16.16 attributes: base, dx, de, dy. Every guest add wraps at 32 bits.
    Coeff: array[0..3, 0..7] of Int64;
    SpanAttribute: array[0..7] of Int64;
    Major, Minor: array[0..3] of Integer;
    Invalid: array[0..3] of Boolean;
    Code: Cardinal;
    Cycle, Tile, MaxLevel, UnscrX: Integer;
    Flip: Boolean;
    // Per-primitive derivatives used by partially covered pixels.
    ShadeDX, ShadeDY: array[0..3] of Int64;
    DepthDX, DepthDY: Int64;
    DepthDelta: Cardinal;
    // Look-ahead memo between consecutive pixels of this primitive.
    MemoValid, MemoTexelValid: Boolean;
    MemoNextSA, MemoNextTA, MemoNextW: Int64;
    MemoNextS, MemoNextT, MemoTile, MemoTexelS, MemoTexelT: Integer;
    MemoTexel: TN64Texel;
  end;

  // Blender inputs of the pixel being written (Pixel sets them, Blend and
  // BlendSource read them). Not serialized.
  TN64BlendState = record
    InputColor, BlendedColor, MemoryColor: Cardinal;
    MemoryCoverage, BlendShiftA, BlendShiftB: Integer;
    BlendEnabled, PreWrap: Boolean;
  end;

  // Derived from TN64Tile whenever a tile descriptor changes; not serialized.
  TN64TileInfo = record
    LimitS, LimitT, MaskS, MaskT: Integer;
    ClampS, ClampT: Boolean;
  end;

  TN64RDP = class
  private
    FBus: TN64Bus;
    FTMEM: array[0..4095] of Byte;
    FTiles: array[0..7] of TN64Tile;
    FTileInfo: array[0..7] of TN64TileInfo;
    FPrim: TN64Primitive;
    FBlend: TN64BlendState;
    FMode: TN64RDPMode;
    FModeDirty: Boolean;
    FIn: TN64CombineInputs;
    // Pixels X = FRowFirst..FRowLast of the row being drawn have a colour
    // image address, FRowBase + X * FRowBPP (see RowAddresses).
    FRowFirst, FRowLast, FRowBPP: Integer;
    FRowBase: Cardinal;
    // Decoded texels by (tile, wrapped S, wrapped T). Entries from an older
    // generation are stale: tiles, TMEM or the TLUT mode changed since.
    FTexelGeneration: Cardinal;
    {$IF Defined(CPU64BITS)}
    // An entry in one place (a lookup reads one cache line): Tag is the key
    // (below 2^36) with the generation's low 28 bits from bit 36 on (never 0
    // there: InvalidateTexels skips it, clearing the entries).
    FTexelCache: array[0..1023] of record
      Tag, Quad: UInt64;
      Texel: TN64Texel;
    end;
    FFiltered: array[0..4095] of record
      Tag, Texel: UInt64;
    end;
    // The same for palette indices (TLUTIndex, the same slots), and the
    // decoded palette halfwords (PackedTLUTTexel, by index * 4 + halfword:
    // Tag is the generation's low 28 bits alone).
    FIndexCache: array[0..1023] of record
      Tag: UInt64;
      Value: Integer;
    end;
    FPaletteCache: array[0..1023] of record
      Tag, Texel: UInt64;
    end;
    {$ELSE}
    FTexelKeys: array[0..1023] of UInt64;
    FTexelStamps: array[0..1023] of Cardinal;
    FTexels: array[0..1023] of TN64Texel;
    FPackedTexels: array[0..1023] of UInt64;
    // The same for palette indices (TLUTIndex, the same slots), and the
    // decoded palette halfwords (PackedTLUTTexel, by index * 4 + halfword).
    FIndexKeys: array[0..1023] of UInt64;
    FIndexStamps, FPaletteStamps: array[0..1023] of Cardinal;
    FIndexValues: array[0..1023] of Integer;
    FPaletteTexels: array[0..1023] of UInt64;
    FFilteredKeys, FFilteredTexels: array[0..4095] of UInt64;
    FFilteredStamps: array[0..4095] of Cardinal;
    {$ENDIF}
    FBilinearFiltering: Boolean;
    FColorAddress, FTextureAddress, FFill, FPrimitive, FEnvironment, FOtherHi, FOtherLo: Cardinal;
    FCombineHi, FCombineLo: Cardinal;
    FBlendColor, FFogColor: Cardinal;
    FZAddress, FPrimitiveDepth, FPrimitiveDelta, FPrimitiveLOD: Cardinal;
    FKeyWidth, FKeyCenter, FKeyScale: array[0..2] of Integer;
    FNoiseSeed, FNoise: Cardinal;
    FLODFraction, FMinLevel, FShadeAlpha, FAlphaDither: Integer;
    FColorFormat: Integer;
    FConvert: array[0..5] of Integer;
    FHasCombine: Boolean;
    FColorWidth, FColorSize, FTextureWidth, FTextureSize, FTextureFormat: Integer;
    FScissorX0, FScissorY0, FScissorX1, FScissorY1: Integer;
    FScissorQuarterX0, FScissorQuarterY0, FScissorQuarterX1, FScissorQuarterY1: Integer;
    FScissorField, FScissorOdd: Boolean;
    FCommand: array[0..43] of Cardinal;
    FCommandCount: Integer;
    FWorkClocks: UInt64;
    FTransferBits: UInt64;
    FPipelineCrashed: Boolean;
    FHiddenOld: array[0..7] of Byte;
    FDrawFlip: Boolean;
    FDelayedHidden: Integer;
    FMemoryColor: Cardinal;
    FMemoryCoverage: Integer;
    FOnCommand: TN64RDPCommandTrace;
    FOnCommandCompleted: TN64RDPCommandTrace;
    FTraceWords: TArray<Cardinal>;
    FTimingOnly: Boolean;
    // Timing RDP (see Lazy, Replay): primitives counted lazily, and whether
    // the current list's clocks lack some; no bus at all; the words Execute
    // fed (Capture).
    FLazy, FLazyClocks, FClocksOnly, FCapture: Boolean;
    FCaptured: TArray<Cardinal>;
    FCapturedCount: Integer;
    FOnWords: TN64RDPWords;
    // Diagnostics: OnPrimitive, the pixels counted for the current primitive
    // (timing RDP), and texture/TLUT loads by how their bytes travel.
    FOnPrimitive: TN64RDPPrimitiveTrace;
    FPrimPixels: Int64;
    FLoadStats: array[0..3] of Int64;
    // Counted pixels of the current row (timing RDP).
    FRowMinX, FRowMaxX: Integer;
    // Texture bytes sent with the command words (timing RDP) or received
    // with them (full RDP fed by one), four per word.
    FOnDataOut: TN64RDPWordOut;
    FOnDataIn: TN64RDPWordIn;
    FDataWord: Cardinal;
    FDataBytes: Integer;
    // Band drawing (TN64RDPGroup): this RDP draws the rows with
    // (Y shr BandRowShift) mod FBands = FBand of band-safe primitives; band 0
    // draws the other ones (a serial stretch, between barriers) alone.
    FGroup: TN64RDPGroup;
    FBand, FBands: Integer;
    FSerialPrim, FInSerial, FBandDrawn: Boolean;
    FBandLayout: array[0..1] of UInt64;
    FBarriers: Int64;
    // A band primitive whose rows hand the memory colour on (its first of
    // two cycles blends with the previous pixel's): the first of its rows
    // (from 0), how many such primitives came before (they use the group's
    // carry buffers in turn), and the memory colour before its first pixel
    // (the latest of every band's).
    FCarryPrim: Boolean;
    FCarryFirst: Integer;
    FCarrySeq: Int64;
    FCarryColor: Cardinal;
    FCarryCoverage: Integer;
    // Drawing order of pixels: primitive, then row. FKey* belong to the
    // pixels that last set the per-pixel state a snapshot keeps, so the state
    // of several band RDPs can be merged; a row belongs to one band, so the
    // position within the row is not needed.
    FPrimSeq, FRowKey, FPixelKey: UInt64;
    // FKeyMemory: the last pixel that set FMemoryColor's low byte and
    // FMemoryCoverage; FKeyMemoryRGB: the last one that read its RGB.
    FKeyRaster, FKeyShade, FKeyMemory, FKeyMemoryRGB, FKeyNoise: UInt64;
    FKeyHidden: array[0..7] of UInt64;
    class var
      PerspectiveReciprocal: array[0..32767] of Word;
    class var
      PerspectiveShift: array[0..32767] of Byte;
    function BandReason(Carry: Boolean): Integer;
    procedure SelectBand(Safe: Boolean);
    procedure CarryRow(Y: Integer);
    procedure LoadCarry(Y: Integer);
    procedure ReadMemoryState(A: Cardinal; var Color: Cardinal; var Coverage: Integer); inline;
    function RowSpan(Y: Integer; out Left, Right: Integer): Boolean; inline;
    procedure RowEdges(out EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: TN64Quarters);
    function OwnsRow(Y: Integer): Boolean; inline;
    function ReadsRDRAM: Boolean;
    procedure SetHiddenOld(Index: Integer; Value: Byte); inline;
    procedure MergeCarried(Source: TN64RDP);
    procedure CopyCarried(Source: TN64RDP);
    procedure ResetBands;
    procedure TimingLoad(SourceS, SourceT, Bits, Rows, Count: Integer);
    procedure PutDataByte(Value: Byte);
    procedure EndData;
    function NextDataByte: Byte;
    procedure TraceCommand(Words: Integer);
    function FetchCommand(Address: Cardinal): Cardinal;
    function MemRead8(Address: Cardinal): Byte; inline;
    function MemRead32(Address: Cardinal): Cardinal; inline;
    procedure MemWrite8(Address: Cardinal; Value: Byte); inline;
    procedure MemWrite32(Address, Value: Cardinal); inline;
    function MemReadHidden(Address: Cardinal): Byte; inline;
    procedure MemWriteHidden(Address: Cardinal; Value: Byte); inline;
    function MemRead16(Address: Cardinal): Cardinal; inline;
    procedure MemWrite8Hidden(Address: Cardinal; Value, Hidden: Byte); inline;
    procedure MemWrite16Hidden(Address, Value: Cardinal; Hidden: Byte); inline;
    procedure MemWrite16HiddenBus(Address, Value: Cardinal; Hidden: Byte);
    procedure MemWrite32Hidden(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte); inline;
    procedure MemWrite32HiddenBus(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte);
    function Color16(V: Word): Cardinal;
    function ColorBytes: Integer; inline;
    procedure AddPixelWork(Cycle: Cardinal; BPP: Integer); inline;
    function CoveredPixels(Lo, Hi: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer; out First, Last: Integer): Integer;
    procedure CountRow(Y, Left, Right: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer);
    procedure SkipRow(Y, Left, Right: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer);
    procedure SkipNoise(Steps: Integer);
    procedure MarkRow(Y: Integer);
    procedure MarkRows(YH, YL: Integer);
    function LazyPrimitive: Boolean; inline;
    function BlendSource(Index, Cycle: Integer): Cardinal; inline;
    function Blend(Cycle: Integer; AlwaysBlend: Boolean): Cardinal;
    procedure Pixel(X, Y: Integer; Color: Cardinal; Fill: Boolean = False; Depth: Integer = -1; Delta: Cardinal = 1; Coverage: Integer = 8; CoverageBit: Boolean = True);
    function Texture(Tile: Integer; S, T: Integer; Cycle: Integer; const Previous: TN64Texel): TN64Texel;
    procedure UpdateTileInfo(Tile: Integer);
    procedure SetBilinearFiltering(Value: Boolean);
    procedure InvalidateTexels;
    function TexelBits(Tile, S, T: Integer; out Address: Integer): Cardinal;
    function PaletteIndex(Tile: Integer; Bits: Cardinal): Integer;
    function TLUTIndex(Tile, S, T: Integer): Integer;
    function PackedTLUTTexel(Index, Halfword: Integer): UInt64;
    function DecodeTexel(Tile, S, T: Integer): TN64Texel;
    function TexelAt(Tile, S, T: Integer): TN64Texel; inline;
    function PackedTexelAt(Tile, S, T: Integer): UInt64; inline;
    procedure LoadTLUTPipeline(Tile, SL, TL, SH: Integer);
    procedure LoadTexture(Tile, SL, TL, SH, TH: Integer; Block: Boolean);
    function Converted(const Raw: TN64Texel): TN64Texel;
    procedure DecodeMode(Textured: Boolean);
    procedure Equations(Cycle: Integer; out E0, E1, E2, E3: Integer);
    function Combine(Shade: Cardinal): Cardinal;
    procedure Dither(X, Y: Integer);
    function Coefficient(Base, Group, Channel: Integer): Int64;
    function EdgeQuantise(Value: Int64): Integer;
    function TextureDivide(Coordinate, W: Int64): Integer; inline;
    procedure RowAddresses(Y: Integer);
    procedure RasterRow(Y: Integer);
    procedure RasterPixel(X, Y, Mask, Coverage, Step: Integer);
    procedure Triangle(Code: Cardinal);
    procedure SetCoefficient(Index: Integer; S, T: Int64);
    procedure Rectangle(Code: Cardinal);
    procedure WriteFramebuffer8(Address: Cardinal; Value: Byte);
    procedure WriteFramebuffer16(Address, Value: Cardinal);
    procedure CompleteDelayedHidden;
  public
    const
    // Bands take rows in stripes of 1 shl BandRowShift in turn: narrow ones
    // share the rows of small primitives out, so the bands' work between two
    // barriers differs less (Command & Conquer, four bands, waits at the
    // barriers of primitives with carries: 8 rows 0.55-0.83 s per band in 300
    // frames, 2 rows 0.19-0.25 s; single rows slowed Resident Evil 2).
      BandRowShift = 1;
    // Feed results.
      FeedNone = 0;
      FeedSync = 1; // a Full Sync completed
      FeedStop = 2; // the pipeline crashed; Execute consumes no further words
    // Texture bytes of one load sent through OnDataOut at most; one command
    // adds at most MaxDataWords words to the stream.
      MaxDataBytes = 16384;
      MaxDataWords = 1 + MaxDataBytes div 4;
  public
    // A timing RDP (TimingOnly) runs the same command, edge and coverage code
    // and keeps the same WorkClocks, Consumed and PipelineCrashed, but draws no
    // pixels and loads no texels. Instead it marks the RDRAM pages a full RDP
    // would touch for the list being queued (TN64Bus.MarkRDPRead/Write).
    constructor Create(Bus: TN64Bus; TimingOnly: Boolean = False);
    procedure Reset;
    function Execute(Start, Finish: Cardinal; XBUS: Boolean; out Consumed: Cardinal): Boolean;
    // Execute in two parts, for a worker RDP that gets the words of a timing
    // RDP's Execute (OnWords): BeginList at the start of each Execute call,
    // then Feed for every word pair in order.
    procedure BeginList;
    function Feed(W0, W1: Cardinal): Integer;
    // Copies the complete state of Source (as SerializeState would).
    procedure Assign(Source: TN64RDP);
    // Draws only band Band of Bands from now on, with the other RDPs of
    // Group (fed the same words, on their own threads).
    procedure JoinGroup(Group: TN64RDPGroup; Band, Bands: Integer);
    // For snapshots of a band RDP, whose own count covers only its rows.
    procedure SetWorkClocks(Value: UInt64);
    // A timing RDP runs again, without the bus (ClocksOnly), the Count words
    // an Execute fed it (Capture), as Execute did: their exact clocks, or
    // (Exact False) only the state they leave.
    function Replay(const Words: TArray<Cardinal>; Count: Integer; Exact: Boolean): UInt64;
    // The current list's exact clocks, worked out by a Replay (LazyClocks).
    procedure ResolveClocks(Value: UInt64);
    // Execute's words since its start, for Replay; Buffer takes their place.
    procedure TakeCaptured(var Buffer: TArray<Cardinal>; out Count: Integer);
    function Traced: Boolean;
    procedure SerializeState(State: TStateArchive);
    function Describe: string;
    // Deterministic RCP work estimate. Pipeline stalls/overlap remain approximate.
    property WorkClocks: UInt64 read FWorkClocks;
    property PipelineCrashed: Boolean read FPipelineCrashed;
    property OnCommand: TN64RDPCommandTrace read FOnCommand write FOnCommand;
    property OnCommandCompleted: TN64RDPCommandTrace read FOnCommandCompleted write FOnCommandCompleted;
    property OnWords: TN64RDPWords read FOnWords write FOnWords;
    // A timing RDP with OnDataOut sends each texture or TLUT load as a flag
    // word and possibly the source bytes; the full RDP fed with its words
    // must get them, in the same order, from OnDataIn.
    property OnDataOut: TN64RDPWordOut read FOnDataOut write FOnDataOut;
    property OnDataIn: TN64RDPWordIn read FOnDataIn write FOnDataIn;
    // Words of a command still incomplete at the end of the last Execute.
    property PendingWords: Integer read FCommandCount;
    property TimingOnly: Boolean read FTimingOnly;
    // Timing RDP: WorkClocks matter only for a list with a Full Sync and for
    // a snapshot, the latest list's. Lazy, a primitive marks every row within
    // the scissor it may touch, unless a row may crash the pipeline, but does
    // not count its pixels: LazyClocks, the list's clocks are then short of
    // them (Replay, ResolveClocks).
    property Lazy: Boolean read FLazy write FLazy;
    property LazyClocks: Boolean read FLazyClocks;
    // No bus at all (no marks, no texture bytes sent or read): Replay's.
    property ClocksOnly: Boolean read FClocksOnly write FClocksOnly;
    property Capture: Boolean read FCapture write FCapture;
    // Host preference; excluded from the emulated hardware snapshot.
    property BilinearFiltering: Boolean read FBilinearFiltering write SetBilinearFiltering;
    // Diagnostics (see the types). A timing RDP counts the pixels of each
    // primitive. Load statistics: [0] bytes sent with the command words, [1]
    // read by the drawing RDP as a queued list may write them, [2] read by
    // the drawing RDP as too many, [3] no drawing RDP fed by this one.
    property OnPrimitive: TN64RDPPrimitiveTrace read FOnPrimitive write FOnPrimitive;
    function ModeWords: TN64RDPModeWords;
    function SerialReason: Integer;
    function LoadStats(Kind: Integer): Int64;
  end;

  // RDPs fed the same command stream on their own threads, each drawing one
  // band of rows. They meet at barriers where band 0 must draw alone (a
  // primitive that is not band-safe, a texture load straight from RDRAM) and
  // where the RDRAM layout of the bands changes, so that every byte of RDRAM
  // sees the same accesses, in the same order, as with a single RDP.
  TN64RDPGroup = class
  public
    const
      BarrierSync = 0;  // all RDPs have finished everything before
      BarrierEnter = 1; // ... and band 0 takes over the per-pixel state
      BarrierLeave = 2; // ... and band 0 hands its state and TMEM to all
  private
    const
      SpinRounds = 4000;
  private
    type
      TSlot = record
        Arrived: Int64;
        Waiting: Integer;
        Event: TEvent;
        Pad: array[0..4] of Int64;
      end;
    // A band's memory colour as a primitive with carries starts.

      TCarryState = record
        Color: Cardinal;
        Coverage: Integer;
        KeyMemory, KeyMemoryRGB: UInt64;
        Pad: array[0..4] of Int64;
      end;
  private
    FMembers: TArray<TN64RDP>;
    FSlots: TArray<TSlot>;
    // Carries of the band primitives whose rows hand the memory colour on,
    // in two buffers that such primitives use in turn (the bands meet at
    // each one, so no band gets two ahead): per row, whether a pixel of it
    // reads memory and what the last one reads; per band, its state.
    FCarryValid: array[0..1, 0..1023] of Boolean;
    FCarryColor: array[0..1, 0..1023] of Cardinal;
    FCarryCoverage: array[0..1, 0..1023] of Byte;
    FCarryStates: array[0..1] of TArray<TCarryState>;
    FReleased: Int64;
    FAborted: Integer;
    procedure SetCarry(Seq: Int64; Y: Integer; Valid: Boolean; Color: Cardinal; Coverage: Integer); inline;
    function CarryValid(Seq: Int64; Y: Integer): Boolean; inline;
    procedure GetCarry(Seq: Int64; Y: Integer; var Color: Cardinal; var Coverage: Integer); inline;
    // Each band, once its rows' carries are set: publishes its memory
    // colour, meets the others, and gets the latest of all bands'.
    procedure CarryBarrier(RDP: TN64RDP; out Color: Cardinal; out Coverage: Integer);
    function ReadReleased: Int64; inline;
    function ReadArrived(Member: Integer): Int64; inline;
    function Aborted: Boolean; inline;
    function Reached(Point: Int64; Release: Boolean): Boolean;
    procedure Wait(Member: Integer; Point: Int64; Release: Boolean);
    procedure Wake;
    procedure Barrier(RDP: TN64RDP; Kind: Integer; const Work: TProc); overload;
  public
    // Members[I] draws band I of Length(Members).
    constructor Create(const Members: array of TN64RDP);
    destructor Destroy; override;
    // Called by each member at the same point of the stream.
    procedure Barrier(RDP: TN64RDP; Kind: Integer); overload;
    // The same, band 0 running Work once all have arrived, before any goes
    // on (BarrierSync otherwise).
    procedure Barrier(RDP: TN64RDP; const Work: TProc); overload;
    // Makes waiting members (and later barriers) raise: a member failed.
    procedure Abort;
    // With every member idle: the state after Reset or a state load.
    procedure Restart;
    // With every member idle: the latest per-pixel state of all members.
    procedure MergeInto(Target: TN64RDP);
  end;

implementation

// Arithmetic right shift without relying on signed host shifts or unchecked casts.

function ShiftRight(Value: Int64; Count: Integer): Int64; inline;
begin
  // Floor division by 2^Count. For negative values not(not V shr C) rounds
  // toward minus infinity; the logical shift only sees non-negative values.
  if Value >= 0 then
    Result := Value shr Count
  else
    Result := not ((not Value) shr Count);
end;

function WrapSigned32(Value: Int64): Int64; inline;
begin
  Result := Integer(Cardinal(Value and $FFFFFFFF));
end;

{$IF Defined(CPU64BITS)}
function ClampTo(Value, Low, High: Integer): Integer; inline;
begin
  // EnsureRange, inline (System.Math's is a call on ARM64).
  if Value < Low then
    Result := Low
  else if Value > High then
    Result := High
  else
    Result := Value;
end;
{$ENDIF}

function Clamp9(Value: Integer): Integer; inline;
begin
  Value := Value and $1FF;
  case Value shr 7 of
    0, 1:
      Result := Value;
    2:
      Result := 255;
  else
    Result := 0;
  end;
end;

constructor TN64RDP.Create(Bus: TN64Bus; TimingOnly: Boolean);
begin
  inherited Create;
  FBus := Bus;
  FTimingOnly := TimingOnly;
  FBilinearFiltering := True;
  Reset
end;

procedure TN64RDP.SetBilinearFiltering(Value: Boolean);
begin
  if FBilinearFiltering = Value then
    Exit;
  FBilinearFiltering := Value;
  // Both filtered and nearest results share the coordinate cache. Switching
  // the host mode invalidates it before any new command is drawn.
  InvalidateTexels;
end;

procedure TN64RDP.Assign(Source: TN64RDP);
begin
  FBilinearFiltering := Source.FBilinearFiltering;
  var Stream := TMemoryStream.Create;
  try
    var Writer := TStateArchive.Create(Stream, False);
    try
      Source.SerializeState(Writer);
    finally
      Writer.Free;
    end;
    Stream.Position := 0;
    var Reader := TStateArchive.Create(Stream, True);
    try
      SerializeState(Reader);
    finally
      Reader.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function TN64RDP.Traced: Boolean;
begin
  Result := Assigned(FOnCommand) or Assigned(FOnCommandCompleted);
end;

procedure TN64RDP.JoinGroup(Group: TN64RDPGroup; Band, Bands: Integer);
begin
  FGroup := Group;
  FBand := Band;
  FBands := Bands;
  ResetBands;
end;

procedure TN64RDP.SetWorkClocks(Value: UInt64);
begin
  FWorkClocks := Value;
end;

function TN64RDP.Replay(const Words: TArray<Cardinal>; Count: Integer; Exact: Boolean): UInt64;
begin
  // As Execute's loop, the words fetched already.
  var WasLazy := FLazy;
  FLazy := not Exact;
  try
    BeginList;
    if not FPipelineCrashed then
    begin
      var I := 0;
      while I + 1 < Count do
      begin
        var Status := Feed(Words[I], Words[I + 1]);
        Inc(I, 2);
        if Status = FeedStop then
          Break;
      end;
    end;
  finally
    FLazy := WasLazy;
  end;
  Result := FWorkClocks;
end;

procedure TN64RDP.ResolveClocks(Value: UInt64);
begin
  FWorkClocks := Value;
  FLazyClocks := False;
end;

procedure TN64RDP.TakeCaptured(var Buffer: TArray<Cardinal>; out Count: Integer);
begin
  var Words := FCaptured;
  FCaptured := Buffer;
  Buffer := Words;
  Count := FCapturedCount;
  FCapturedCount := 0;
end;

procedure TN64RDP.ResetBands;
begin
  FPrimSeq := 0;
  FRowKey := 0;
  FPixelKey := 0;
  FKeyRaster := 0;
  FKeyShade := 0;
  FKeyMemory := 0;
  FKeyMemoryRGB := 0;
  FKeyNoise := 0;
  for var I := 0 to High(FKeyHidden) do
    FKeyHidden[I] := 0;
  FSerialPrim := False;
  FInSerial := False;
  FCarryPrim := False;
  FCarrySeq := 0;
  FBandDrawn := False;
  FBandLayout[0] := 0;
  FBandLayout[1] := 0;
  FBarriers := 0;
end;

function TN64RDP.SerialReason: Integer;
begin
  Result := BandReason(True);
end;

function TN64RDP.BandReason(Carry: Boolean): Integer;
begin
  // Whether RDPs that each draw only their own rows of this primitive leave
  // exactly what one RDP drawing all rows leaves (0), or why not: no state
  // may pass from pixel to pixel (the previous pixel's memory colour, the
  // hidden-bit history of byte writes), and no RDRAM byte or halfword may
  // belong to two rows (colour rows wider than the image, Z overlapping
  // colour, 4/8-bit pixels or odd addresses sharing halfwords). The noise
  // generator passes from pixel to pixel too, but its steps over the other
  // bands' rows can be counted (SkipRow). With Carry, a first of two cycles
  // that blends with the previous pixel's memory colour, read from memory,
  // is no reason (9 unless another one is): what the last pixel of a row
  // reads is found before any band draws (CarryRow).
  var Cycle := (FOtherHi shr 20) and 3;
  var Carried := False;
  if FColorSize < 2 then
    Exit(1);
  if Odd(FColorAddress) then
    Exit(2);
  if FScissorX1 > FColorWidth then
    Exit(3);
  // The RGB dither's noise mode reads the noise of the last pixel that took
  // one, possibly in another band.
  if (Cycle < 2) and (((FOtherHi shr 6) and 3) = 2) and not FMode.NeedsNoise then
    Exit(4);
  if Cycle < 2 then
  begin
    for var C := 0 to Integer(Cycle) do
    begin
      var M1A := (FOtherLo shr (30 - C * 2)) and 3;
      var M2A := (FOtherLo shr (22 - C * 2)) and 3;
      var M2B := (FOtherLo shr (18 - C * 2)) and 3;
      // The last cycle bypasses M2A without AA, force-blend or colour-on-
      // coverage; the first of two always blends. BlendSource only reads:
      // Pixel updates the carried state and its keys independently.
      var SecondUsed := (C < Integer(Cycle)) or ((FOtherLo and $4088) <> 0);
      // Without image read, the memory colour is the previous pixel's.
      if ((FOtherLo and $40) = 0) and ((M1A = 1) or (SecondUsed and (M2A = 1))) then
        Exit(5);
      // The first of two cycles blends with the previous pixel's memory.
      if (Cycle = 1) and (C = 0) and ((M1A = 1) or (M2A = 1) or (M2B = 1)) then
      begin
        if not Carry or ((FOtherLo and $40) = 0) then
          Exit(6);
        Carried := True;
      end;
    end;
    if (FOtherLo and $30) <> 0 then
    begin
      if Odd(FZAddress) then
        Exit(7);
      var ColorRow := UInt64(FColorWidth) * UInt64(ColorBytes);
      var ColorFirst := UInt64(FColorAddress) + UInt64(FScissorY0) * ColorRow;
      var ColorEnd := UInt64(FColorAddress) + UInt64(FScissorY1) * ColorRow;
      var ZFirst := UInt64(FZAddress) + UInt64(FScissorY0) * UInt64(FColorWidth) * 2;
      var ZEnd := UInt64(FZAddress) + UInt64(FScissorY1) * UInt64(FColorWidth) * 2;
      if (ZFirst < ColorEnd) and (ColorFirst < ZEnd) then
        Exit(8);
    end;
  end;
  if Carried then
    Exit(9);
  Result := 0;
end;

function TN64RDP.ModeWords: TN64RDPModeWords;
begin
  Result.Code := Integer(FPrim.Code);
  Result.Cycle := Integer((FOtherHi shr 20) and 3);
  Result.Tile := FPrim.Tile;
  Result.TileFormat := FTiles[FPrim.Tile].Format;
  Result.TileSize := FTiles[FPrim.Tile].Size;
  Result.ColorSize := FColorSize;
  Result.ColorFormat := FColorFormat;
  Result.CombineHi := FCombineHi;
  Result.CombineLo := FCombineLo;
  Result.OtherHi := FOtherHi;
  Result.OtherLo := FOtherLo;
  Result.Serial := SerialReason;
end;

function TN64RDP.LoadStats(Kind: Integer): Int64;
begin
  Result := FLoadStats[Kind];
end;

procedure TN64RDP.SelectBand(Safe: Boolean);
begin
  // Barriers where band 0 starts or stops drawing alone, and where the
  // band-safe primitives change colour image or Z buffer: rows of the
  // different layouts may share RDRAM, so the bands must not overlap in time.
  if not Safe then
  begin
    if not FInSerial then
    begin
      FGroup.Barrier(Self, TN64RDPGroup.BarrierEnter);
      FInSerial := True;
    end;
  end
  else
  begin
    var Layout0 := (UInt64(FColorAddress) shl 32) or (UInt64(FColorWidth) shl 2) or UInt64(FColorSize);
    var Layout1 := UInt64(FZAddress);
    if FInSerial then
    begin
      FGroup.Barrier(Self, TN64RDPGroup.BarrierLeave);
      FInSerial := False;
    end
    else if FBandDrawn and ((Layout0 <> FBandLayout[0]) or (Layout1 <> FBandLayout[1])) then
      FGroup.Barrier(Self, TN64RDPGroup.BarrierSync);
    FBandLayout[0] := Layout0;
    FBandLayout[1] := Layout1;
    FBandDrawn := True;
  end;
  FSerialPrim := not Safe;
end;

function TN64RDP.OwnsRow(Y: Integer): Boolean;
begin
  if FBands <= 1 then
    Result := True
  else if FSerialPrim then
    Result := FBand = 0
  else
    Result := ((Y shr BandRowShift) mod FBands) = FBand;
end;

function TN64RDP.ReadsRDRAM: Boolean;
begin
  // A load straight from RDRAM. With band RDPs, band 0 runs it alone (after
  // all bands finished everything before); the others get its TMEM when the
  // serial stretch ends.
  Result := True;
  if FGroup = nil then
    Exit;
  if not FInSerial then
  begin
    FGroup.Barrier(Self, TN64RDPGroup.BarrierEnter);
    FInSerial := True;
  end;
  Result := FBand = 0;
end;

procedure TN64RDP.SetHiddenOld(Index: Integer; Value: Byte);
begin
  FHiddenOld[Index] := Value;
  FKeyHidden[Index] := FPixelKey;
end;

procedure TN64RDP.MergeCarried(Source: TN64RDP);
begin
  // The per-pixel state Source's pixels set later than ours.
  if Source.FKeyRaster > FKeyRaster then
  begin
    FLODFraction := Source.FLODFraction;
    FAlphaDither := Source.FAlphaDither;
    FKeyRaster := Source.FKeyRaster;
  end;
  if Source.FKeyShade > FKeyShade then
  begin
    FShadeAlpha := Source.FShadeAlpha;
    FKeyShade := Source.FKeyShade;
  end;
  // FMemoryColor's RGB passes from pixel to pixel until one reads memory.
  if Source.FKeyMemory > FKeyMemory then
  begin
    FMemoryColor := (FMemoryColor and $FFFFFF00) or (Source.FMemoryColor and $FF);
    FMemoryCoverage := Source.FMemoryCoverage;
    FKeyMemory := Source.FKeyMemory;
  end;
  if Source.FKeyMemoryRGB > FKeyMemoryRGB then
  begin
    FMemoryColor := (Source.FMemoryColor and $FFFFFF00) or (FMemoryColor and $FF);
    FKeyMemoryRGB := Source.FKeyMemoryRGB;
  end;
  // The generator's seed is the same in every band (SkipRow); the noise is
  // the last pixel's that took it.
  if Source.FKeyNoise > FKeyNoise then
  begin
    FNoise := Source.FNoise;
    FKeyNoise := Source.FKeyNoise;
  end;
  for var I := 0 to High(FHiddenOld) do
    if Source.FKeyHidden[I] > FKeyHidden[I] then
    begin
      FHiddenOld[I] := Source.FHiddenOld[I];
      FKeyHidden[I] := Source.FKeyHidden[I];
    end;
end;

procedure TN64RDP.CopyCarried(Source: TN64RDP);
begin
  // After band 0 drew alone: its per-pixel state, noise and TMEM (it alone
  // ran texture loads from RDRAM meanwhile).
  FLODFraction := Source.FLODFraction;
  FAlphaDither := Source.FAlphaDither;
  FKeyRaster := Source.FKeyRaster;
  FShadeAlpha := Source.FShadeAlpha;
  FKeyShade := Source.FKeyShade;
  FMemoryColor := Source.FMemoryColor;
  FMemoryCoverage := Source.FMemoryCoverage;
  FKeyMemory := Source.FKeyMemory;
  FKeyMemoryRGB := Source.FKeyMemoryRGB;
  FHiddenOld := Source.FHiddenOld;
  FKeyHidden := Source.FKeyHidden;
  FNoiseSeed := Source.FNoiseSeed;
  FNoise := Source.FNoise;
  FKeyNoise := Source.FKeyNoise;
  FTMEM := Source.FTMEM;
  InvalidateTexels;
end;

function TexelFromRGBA(Color: Cardinal): TN64Texel; inline;
begin
  Result.C[0] := (Color shr 24) and $FF;
  Result.C[1] := (Color shr 16) and $FF;
  Result.C[2] := (Color shr 8) and $FF;
  Result.C[3] := Color and $FF;
end;

// TexelFromRGBA(Color16(V)) without the packed intermediate.
function Texel5551(V: Word): TN64Texel; inline;
begin
  var R := (V shr 11) and 31;
  var G := (V shr 6) and 31;
  var B := (V shr 1) and 31;
  Result.C[0] := (R shl 3) or (R shr 2);
  Result.C[1] := (G shl 3) or (G shr 2);
  Result.C[2] := (B shl 3) or (B shr 2);
  Result.C[3] := (V and 1) * $FF;
end;

function TexelToRGBA(const Texel: TN64Texel): Cardinal; inline;
begin
  Result := (Cardinal(Clamp9(Texel.C[0])) shl 24) or (Cardinal(Clamp9(Texel.C[1])) shl 16) or
    (Cardinal(Clamp9(Texel.C[2])) shl 8) or Cardinal(Clamp9(Texel.C[3]));
end;

function TN64RDP.Describe: string;
begin
  Result := Format('color=%6.6x width=%d size=%d z=%6.6x modes=%6.6x/%8.8x combine=%6.6x/%8.8x scissor=%d,%d:%d,%d',
    [FColorAddress, FColorWidth, FColorSize, FZAddress, FOtherHi, FOtherLo, FCombineHi, FCombineLo,
      FScissorX0, FScissorY0, FScissorX1, FScissorY1]);
end;

procedure TN64RDP.Reset;
begin
  for var I := 0 to 4095 do
    FTMEM[I] := 0;
  for var I := 0 to 7 do
  begin
    FTiles[I] := Default(TN64Tile);
    UpdateTileInfo(I);
  end;
  FColorAddress := 0;
  FTextureAddress := 0;
  FFill := 0;
  FPrimitive := $FFFFFFFF;
  FEnvironment := 0;
  FOtherHi := 0;
  FOtherLo := 0;
  FColorWidth := 320;
  FColorSize := 2;
  FCombineHi := 0;
  FCombineLo := 0;
  FHasCombine := False;
  FBlendColor := 0;
  FFogColor := 0;
  FZAddress := 0;
  FPrimitiveDepth := 0;
  FPrimitiveDelta := 0;
  FPrimitiveLOD := 0;
  FMinLevel := 0;
  FLODFraction := 0;
  FShadeAlpha := 0;
  FAlphaDither := 0;
  FNoiseSeed := 3;
  FNoise := 0;
  FColorFormat := 0;
  FScissorQuarterX0 := 0;
  FScissorQuarterY0 := 0;
  FScissorQuarterX1 := 4096;
  FScissorQuarterY1 := 4096;
  FScissorField := False;
  FScissorOdd := False;
  for var I := 0 to 2 do
  begin
    FKeyWidth[I] := 0;
    FKeyCenter[I] := 0;
    FKeyScale[I] := 0;
  end;
  for var I := 0 to High(FConvert) do
    FConvert[I] := 0;
  FTextureWidth := 1;
  FTextureSize := 2;
  FTextureFormat := 0;
  FScissorX0 := 0;
  FScissorY0 := 0;
  FScissorX1 := 1024;
  FScissorY1 := 1024;
  FCommandCount := 0;
  FWorkClocks := 0;
  FTransferBits := 0;
  FPipelineCrashed := False;
  FDrawFlip := False;
  FDelayedHidden := -1;
  FMemoryColor := 0;
  FMemoryCoverage := 0;
  for var I := 0 to High(FHiddenOld) do
    FHiddenOld[I] := 0;
  for var I := 0 to High(FCommand) do
    FCommand[I] := 0;
  FModeDirty := True;
end;

// RDRAM accesses bypass the virtual decoder under the TN64Bus RAM contract.
// They use the RDP accessors, which do not wait for queued RDP work: only a
// full RDP draws pixels, and a worker RDP owns the pages of its lists.

function TN64RDP.MemRead8(Address: Cardinal): Byte;
begin
  if Address < FBus.RAMSize then
    Result := FBus.RDPRead8(Address)
  else
    Result := FBus.Read8(Address);
end;

function TN64RDP.MemRead32(Address: Cardinal): Cardinal;
begin
  if UInt64(Address) + 4 <= FBus.RAMSize then
    Result := FBus.RDPRead32(Address)
  else
    Result := FBus.Read32(Address);
end;

procedure TN64RDP.MemWrite8(Address: Cardinal; Value: Byte);
begin
  if Address < FBus.RAMSize then
    FBus.RDPWrite8(Address, Value)
  else
    FBus.Write8(Address, Value);
end;

procedure TN64RDP.MemWrite32(Address, Value: Cardinal);
begin
  if UInt64(Address) + 4 <= FBus.RAMSize then
    FBus.RDPWrite32(Address, Value)
  else
    FBus.Write32(Address, Value);
end;

function TN64RDP.MemReadHidden(Address: Cardinal): Byte;
begin
  if Address < FBus.RAMSize then
    Result := FBus.RDPReadHidden(Address)
  else
    Result := FBus.ReadHidden(Address);
end;

procedure TN64RDP.MemWriteHidden(Address: Cardinal; Value: Byte);
begin
  if Address < FBus.RAMSize then
    FBus.RDPWriteHidden(Address, Value)
  else
    FBus.WriteHidden(Address, Value);
end;

function TN64RDP.MemRead16(Address: Cardinal): Cardinal;
begin
  if UInt64(Address) + 2 <= FBus.RAMSize then
    Result := FBus.RDPRead16(Address)
  else
  begin
    Result := Cardinal(MemRead8(Address)) shl 8;
    Result := Result or MemRead8(Address + 1);
  end;
end;

// The MemWrite*Hidden helpers write data bytes, then the hidden bits of each
// halfword written: the same as MemWrite8/MemWrite32 followed by MemWriteHidden.

procedure TN64RDP.MemWrite8Hidden(Address: Cardinal; Value, Hidden: Byte);
begin
  if Address < FBus.RAMSize then
    FBus.RDPWrite8Hidden(Address, Value, Hidden)
  else
  begin
    FBus.Write8(Address, Value);
    FBus.WriteHidden(Address, Hidden);
  end;
end;

procedure TN64RDP.MemWrite16Hidden(Address, Value: Cardinal; Hidden: Byte);
begin
  if ((Address and 1) = 0) and (UInt64(Address) + 2 <= FBus.RAMSize) then
    FBus.RDPWrite16Hidden(Address, Value, Hidden)
  else
    MemWrite16HiddenBus(Address, Value, Hidden);
end;

procedure TN64RDP.MemWrite16HiddenBus(Address, Value: Cardinal; Hidden: Byte);
begin
  // Odd or outside direct RDRAM: the two bytes may touch different halfwords.
  MemWrite8(Address, Byte((Value shr 8) and $FF));
  MemWrite8(Address + 1, Byte(Value and $FF));
  MemWriteHidden(Address, Hidden);
end;

procedure TN64RDP.MemWrite32Hidden(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte);
begin
  if ((Address and 1) = 0) and (UInt64(Address) + 4 <= FBus.RAMSize) then
    FBus.RDPWrite32Hidden(Address, Value, HiddenHi, HiddenLo)
  else
    MemWrite32HiddenBus(Address, Value, HiddenHi, HiddenLo);
end;

procedure TN64RDP.MemWrite32HiddenBus(Address, Value: Cardinal; HiddenHi, HiddenLo: Byte);
begin
  MemWrite32(Address, Value);
  MemWriteHidden(Address, HiddenHi);
  MemWriteHidden(Address + 2, HiddenLo);
end;

function TN64RDP.Color16(V: Word): Cardinal;
begin
  var R := (V shr 11) and 31;
  var G := (V shr 6) and 31;
  var B := (V shr 1) and 31;
  Result := (((Cardinal(R) shl 3) or (R shr 2)) shl 24) or
    (((Cardinal(G) shl 3) or (G shr 2)) shl 16) or
    (((Cardinal(B) shl 3) or (B shr 2)) shl 8);
  if (V and 1) <> 0 then
    Result := Result or $FF;
end;

procedure TN64RDP.CompleteDelayedHidden;
begin
  if (FDelayedHidden >= 0) and (FDelayedHidden < $800000) then
  begin
    var Address := Cardinal(FDelayedHidden);
    var Hidden := (MemReadHidden(Address) and 1) or (FHiddenOld[(Address div 2) and 7] and 2);
    MemWriteHidden(Address, Hidden);
  end;
  FDelayedHidden := -1;
end;

procedure TN64RDP.WriteFramebuffer8(Address: Cardinal; Value: Byte);
begin
  if Address >= $800000 then
    Exit;
  var Hidden := MemReadHidden(Address);
  var OldIndex := (Address div 2) and 7;
  if not FDrawFlip then
  begin
    if Odd(Address) then
      Hidden := (Hidden and 2) or (Value and 1)
    else
      Hidden := (Hidden and 1) or (FHiddenOld[OldIndex] and 2);
  end
  else
  begin
    if (FDelayedHidden >= 0) and (Cardinal(FDelayedHidden) < Address) then
      CompleteDelayedHidden;
    if Odd(Address) then
    begin
      if FDelayedHidden >= 0 then
        Hidden := Byte((Value and 1) * 3)
      else
        Hidden := (Hidden and 2) or (Value and 1);
      FDelayedHidden := -1;
    end
    else
      FDelayedHidden := Integer(Address + 1);
  end;
  MemWrite8Hidden(Address, Value, Hidden);
  if Odd(Address) then
    SetHiddenOld(OldIndex, Byte((Value and 1) * 3));
end;

procedure TN64RDP.WriteFramebuffer16(Address, Value: Cardinal);
begin
  if ((Address and 1) <> 0) or (UInt64(Address) + 2 > FBus.RAMSize) then
  begin
    if FDrawFlip then
    begin
      WriteFramebuffer8(Address, Byte(Value shr 8));
      WriteFramebuffer8(Address + 1, Byte(Value and $FF))
    end
    else
    begin
      WriteFramebuffer8(Address + 1, Byte(Value and $FF));
      WriteFramebuffer8(Address, Byte(Value shr 8))
    end;
    Exit;
  end;
  // An even halfword in RDRAM: the two WriteFramebuffer8 calls above reduce
  // to this. Both hidden bits end up as the low data bit, and a flipped draw
  // first completes a delayed hidden write left of this halfword.
  if FDrawFlip then
  begin
    if (FDelayedHidden >= 0) and (Cardinal(FDelayedHidden) < Address) then
      CompleteDelayedHidden;
    FDelayedHidden := -1;
  end;
  var Hidden := Byte((Value and 1) * 3);
  FBus.RDPWrite16Hidden(Address, Value, Hidden);
  SetHiddenOld((Address div 2) and 7, Hidden);
end;

procedure TN64RDP.Dither(X, Y: Integer);
begin
  // The noise and the alpha dither of the pixel (DecodeMode decides which).
  if FMode.NeedsNoise then
  begin
    FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
    FNoise := (((FNoiseSeed shr 16) and 7) shl 6) or $20;
    FKeyNoise := FPixelKey;
  end;
  if FMode.RGBNoise then
    FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
  if FMode.AlphaNoise then
    FAlphaDither := Integer((FNoise shr 6) and 7)
  else
  begin
    if FScissorField then
      Y := Y shr 1;
    FAlphaDither := FMode.AlphaDither[((Y and 3) shl 2) or (X and 3)];
  end;
end;

{$IF Defined(CPU64BITS)}
var
  // The highest set bit of each byte (0 for 0 and 1); the leading ones of
  // each 7-bit value.
  HighBit8: array[0..255] of Byte;
  LeadingOnes7: array[0..127] of Byte;
{$ENDIF}

function EncodedDZ(V: Cardinal): Integer;
begin
  // The highest set bit of V's low 16 bits (0 for 0 and 1).
  {$IF Defined(CPU64BITS)}
  V := V and $FFFF;
  if V >= 256 then
    Result := 8 + HighBit8[V shr 8]
  else
    Result := HighBit8[V];
  {$ELSE}
  Result := 0;
  V := V and $FFFF;
  while V > 1 do
  begin
    V := V shr 1;
    Inc(Result)
  end;
  {$ENDIF}
end;

function BlenderDivide(Denominator, Numerator: Integer): Integer;
begin
  // The RDP divider is an eight-step restoring divider, not a host division.
  var D := (Denominator shr 2) and 15;
  var N := Numerator and $7FF;
  var InverseD := D xor 15;
  var Remainder := (InverseD + (N shr 8) + 1) and 7;
  Result := 0;
  for var K := 0 to 7 do
  begin
    var Bit := (N shr (7 - K)) and 1;
    var Temp := D + Remainder * 2 + Bit;
    if (Result and (256 shr K)) <> 0 then
      Temp := InverseD + Remainder * 2 + Bit + 1;
    Remainder := Temp and 7;
    if (Temp and 16) <> 0 then
      Result := Result or (1 shl (7 - K));
  end;
end;

function TN64RDP.BlendSource(Index, Cycle: Integer): Cardinal;
begin
  case Index of
    0:
      if Cycle = 0 then
        Result := FBlend.InputColor
      else
        Result := FBlend.BlendedColor;
    1:
      Result := FBlend.MemoryColor;
    2:
      Result := FBlendColor;
  else
    Result := FFogColor
  end;
end;

{$IF Defined(CPU64BITS)}
function BlendLanes(C: Cardinal): UInt64; inline;
begin
  // A colour's red, green and blue (bits 8..31) in 16-bit lanes 0, 1, 2.
  Result := UInt64((C shr 8) and $FF) or (UInt64((C shr 16) and $FF) shl 16) or (UInt64(C shr 24) shl 32);
end;
{$ENDIF}

function TN64RDP.Blend(Cycle: Integer; AlwaysBlend: Boolean): Cardinal;
begin
  var M1A := FMode.M1A[Cycle];
  var M1B := FMode.M1B[Cycle];
  var M2A := FMode.M2A[Cycle];
  var M2B := FMode.M2B[Cycle];
  var First := BlendSource(M1A, Cycle);
  var Second := BlendSource(M2A, Cycle);
  if ((FOtherLo and $80) <> 0) and not FBlend.PreWrap then
    Exit(Second);
  // Partial reject: the standard input/inverse-input-alpha equation bypasses blending at alpha=255.
  var PartialReject := (M1B = 0) and (M2B = 0) and ((FBlend.InputColor and $FF) = $FF);
  if not AlwaysBlend and (not FBlend.BlendEnabled or PartialReject) then
    Exit(First);
  var Alpha := Integer(FBlend.InputColor and $FF);
  case M1B of
    1:
      Alpha := FFogColor and $FF;
    2:
      Alpha := FShadeAlpha;
    3:
      Alpha := 0
  end;
  var Beta := Alpha xor 255;
  case M2B of
    1:
      Beta := FBlend.MemoryCoverage shl 5;
    2:
      Beta := 255;
    3:
      Beta := 0
  end;
  Alpha := Alpha shr 3;
  Beta := Beta shr 3;
  if M2B = 1 then
  begin
    Alpha := (Alpha shr FBlend.BlendShiftA) and $3C;
    Beta := (Beta shr FBlend.BlendShiftB) or 3;
  end;
  Result := FBlend.InputColor and $FF;
  {$IF Defined(CPU64BITS)}
  if AlwaysBlend or ((FOtherLo and $4000) <> 0) then
  begin
    // The three channels at once, in 16-bit lanes (each sum at most
    // 255 * 31 + 255 * 32 < 2^16): bits 5..12 of each.
    var V := BlendLanes(First) * UInt64(Alpha) + BlendLanes(Second) * UInt64(Beta + 1);
    V := (V shr 5) and UInt64($000000FF00FF00FF);
    Exit(Result or (Cardinal(V and $FF) shl 8) or (Cardinal((V shr 16) and $FF) shl 16) or
      (Cardinal((V shr 32) and $FF) shl 24));
  end;
  {$ENDIF}
  for var Channel := 1 to 3 do
  begin
    var Value := Integer((First shr (Channel * 8)) and $FF) * Alpha +
      Integer((Second shr (Channel * 8)) and $FF) * (Beta + 1);
    if AlwaysBlend or ((FOtherLo and $4000) <> 0) then
      Value := (Value shr 5) and $FF
    else
      Value := BlenderDivide((Alpha and $3C) + (Beta and $3C) + 4, (Value shr 2) and $7FF);
    Result := Result or (Cardinal(Value) shl (Channel * 8));
  end;
end;

function TN64RDP.ColorBytes: Integer;
begin
  // Bytes per colour image pixel; 4-bit images write whole bytes.
  Result := 1;
  if FColorSize >= 2 then
    Result := 1 shl (FColorSize - 1);
end;

procedure TN64RDP.AddPixelWork(Cycle: Cardinal; BPP: Integer);
begin
  if Cycle = 1 then
    Inc(FWorkClocks, 2)
  else if Cycle = 0 then
    Inc(FWorkClocks)
  else
    Inc(FTransferBits, Cardinal(BPP * 8));
end;

procedure TN64RDP.CountRow(Y, Left, Right: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer);
begin
  // Timing RDP in place of RasterRow's pixel loop: the pixels it would hand
  // to Pixel and that Pixel draws (RowAddresses), counted per span.
  // RasterRow has checked Y against the raster and the field already.
  if (Y < FScissorY0) or (Y >= FScissorY1) then
    Exit;
  var BPP := ColorBytes;
  var Room := Int64($800000) - BPP - Int64(FColorAddress);
  if Room < 0 then
    Exit;
  // RowAddresses leaves exactly X = Lo..Hi of this row.
  var Lo := Max(Max(Left, FScissorX0), 0);
  var Hi := Min(Min(Right, FScissorX1 - 1), 1023);
  Hi := Integer(Min(Int64(Hi), Room div BPP - Int64(Y) * FColorWidth));
  if Lo > Hi then
    Exit;
  var First, Last: Integer;
  var Count := CoveredPixels(Lo, Hi, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask, First, Last);
  if Count = 0 then
    Exit;
  FRowMinX := Min(FRowMinX, First);
  FRowMaxX := Max(FRowMaxX, Last);
  Inc(FPrimPixels, Count);
  // Pixel's clocks for each of them.
  var Cycle := (FOtherHi shr 20) and 3;
  if Cycle = 1 then
    Inc(FWorkClocks, UInt64(Count) * 2)
  else if Cycle = 0 then
    Inc(FWorkClocks, UInt64(Count))
  else
    Inc(FTransferBits, UInt64(Count) * UInt64(BPP * 8));
end;

function TN64RDP.CoveredPixels(Lo, Hi: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer; out First, Last: Integer): Integer;
var
  Starts, Ends: array[0..3] of Integer;
begin
  // The pixels X = Lo..Hi of a row (Lo <= Hi) that RasterRow hands to
  // RasterPixel: all for copy and fill, otherwise those with coverage in some
  // quarter line: inside its edges, and at an edge when its mask leaves
  // bits. Their number, and the first and last of them.
  First := Lo;
  Last := Hi;
  if FPrim.Cycle >= 2 then
    Exit(Hi - Lo + 1);
  Result := 0;
  var N := 0;
  for var Q := 0 to 3 do
    if not FPrim.Invalid[Q] and (EdgeLo[Q] <= EdgeHi[Q]) then
    begin
      var S := EdgeLo[Q];
      var E := EdgeHi[Q];
      if S = E then
      begin
        if (QuarterMask[Q] and LoMask[Q] and HiMask[Q]) = 0 then
          Continue;
      end
      else
      begin
        if (QuarterMask[Q] and LoMask[Q]) = 0 then
          Inc(S);
        if (QuarterMask[Q] and HiMask[Q]) = 0 then
          Dec(E);
      end;
      S := Max(S, Lo);
      E := Min(E, Hi);
      if S > E then
        Continue;
        // Insert, ordered by start.
      var I := N;
      while (I > 0) and (Starts[I - 1] > S) do
      begin
        Starts[I] := Starts[I - 1];
        Ends[I] := Ends[I - 1];
        Dec(I);
      end;
      Starts[I] := S;
      Ends[I] := E;
      Inc(N);
    end;
  if N = 0 then
    Exit;
  // Pixels in the union of the spans; they start in order, so the last one
  // ends furthest right.
  var SpanStart := Starts[0];
  var SpanEnd := Ends[0];
  for var I := 1 to N - 1 do
    if Starts[I] > SpanEnd then
    begin
      Inc(Result, SpanEnd - SpanStart + 1);
      SpanStart := Starts[I];
      SpanEnd := Ends[I];
    end
    else
      SpanEnd := Max(SpanEnd, Ends[I]);
  Inc(Result, SpanEnd - SpanStart + 1);
  First := Starts[0];
  Last := SpanEnd;
end;

procedure TN64RDP.SkipRow(Y, Left, Right: Integer; const EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: array of Integer);
begin
  // Another band draws row Y (X = Left..Right, within 0..1023): step the
  // noise generator as its pixels would.
  var First, Last: Integer;
  var Steps := 0;
  if FMode.PixelSteps > 0 then
    Steps := CoveredPixels(Left, Right, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask, First, Last) * FMode.PixelSteps;
  if FMode.CompareStep then
  begin
    RowAddresses(Y);
    var Lo := Max(Left, FRowFirst);
    var Hi := Min(Right, FRowLast);
    if Lo <= Hi then
      Inc(Steps, CoveredPixels(Lo, Hi, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask, First, Last));
  end;
  SkipNoise(Steps);
end;

procedure TN64RDP.SkipNoise(Steps: Integer);
begin
  // FNoiseSeed after Steps steps of its generator, Seed * $343FD + $269EC3
  // modulo 2^32: the composed map Seed * Mul + Add, by squaring. All
  // products are of numbers below 2^32.
  var StepMul: UInt64 := $343FD;
  var StepAdd: UInt64 := $269EC3;
  var Mul: UInt64 := 1;
  var Add: UInt64 := 0;
  var N := Steps;
  while N > 0 do
  begin
    if Odd(N) then
    begin
      Mul := (Mul * StepMul) and $FFFFFFFF;
      Add := (Add * StepMul + StepAdd) and $FFFFFFFF;
    end;
    StepAdd := (StepAdd * StepMul + StepAdd) and $FFFFFFFF;
    StepMul := (StepMul * StepMul) and $FFFFFFFF;
    N := N shr 1;
  end;
  FNoiseSeed := Cardinal((Mul * FNoiseSeed + Add) and $FFFFFFFF);
end;

procedure TN64RDP.MarkRow(Y: Integer);
begin
  // RDRAM a full RDP may touch for the counted pixels FRowMinX..FRowMaxX of
  // row Y: their colour bytes, and their Z halfwords when the Z buffer is
  // used. Bytes next to a pixel that its writes also touch (the hidden bits
  // and other byte of a shared halfword, delayed hidden writes, RDPWrite8's
  // and RDPWrite32's look at the neighbouring byte) always share a halfword
  // with one of its own bytes, and halfwords never straddle the 64-byte
  // lines the marks track, so the pixels' own bytes cover them.
  if FClocksOnly then
    Exit;
  var BPP := ColorBytes;
  var First := (Y * FColorWidth + FRowMinX) * BPP;
  var Bytes := (FRowMaxX - FRowMinX + 1) * BPP;
  FBus.MarkRDPWrite(Cardinal(UInt64(FColorAddress) + Cardinal(First)), Cardinal(Bytes));
  if (((FOtherHi shr 20) and 3) < 2) and ((FOtherLo and $30) <> 0) then
  begin
    var Z := UInt64(FZAddress) + Cardinal((Y * FColorWidth + FRowMinX) * 2);
    if Z < $800000 then
      FBus.MarkRDPWrite(Cardinal(Z), Cardinal((FRowMaxX - FRowMinX + 1) * 2));
  end;
end;

function TN64RDP.LazyPrimitive: Boolean;
begin
  // Triangle's primitive (FPrim.Cycle set) counted lazily: only its rows'
  // marks, unless a row may crash the pipeline (RasterRow) or the pixels
  // are wanted (OnPrimitive).
  Result := FLazy and not Assigned(FOnPrimitive) and ((FPrim.Cycle <> 3) or ((FOtherLo and $24) <> $20));
end;

procedure TN64RDP.MarkRows(YH, YL: Integer);
begin
  // A lazy primitive (Triangle's YH, YL): what MarkRow marks for any pixels
  // CountRow could count, in one range per image from the first row it may
  // reach to the last. Those rows lie within the scissor and the quarter
  // lines Triangle walks; their pixels X within the scissor and 0..1023.
  if FClocksOnly then
    Exit;
  var First := Max(Max(Integer(ShiftRight(YH, 2)), FScissorY0), 0);
  var Last := Min(Min(Integer(ShiftRight(Min(YL, FScissorQuarterY1) - 1, 2)), FScissorY1 - 1), 1023);
  var Lo := Max(FScissorX0, 0);
  var Hi := Min(FScissorX1 - 1, 1023);
  var BPP := ColorBytes;
  if (First > Last) or (Lo > Hi) or (Int64($800000) - BPP - Int64(FColorAddress) < 0) then
    Exit;
  var Start := Int64(FColorAddress) + (Int64(First) * FColorWidth + Lo) * BPP;
  var Stop := Min(Int64(FColorAddress) + (Int64(Last) * FColorWidth + Hi + 1) * BPP, Int64($800000));
  if Start < Stop then
    FBus.MarkRDPWrite(Cardinal(Start), Cardinal(Stop - Start));
  if (((FOtherHi shr 20) and 3) < 2) and ((FOtherLo and $30) <> 0) then
  begin
    Start := Int64(FZAddress) + (Int64(First) * FColorWidth + Lo) * 2;
    Stop := Min(Int64(FZAddress) + (Int64(Last) * FColorWidth + Hi + 1) * 2, Int64($800000));
    if Start < Stop then
      FBus.MarkRDPWrite(Cardinal(Start), Cardinal(Stop - Start));
  end;
end;

procedure TN64RDP.ReadMemoryState(A: Cardinal; var Color: Cardinal; var Coverage: Integer);
begin
  // The memory colour and coverage the blender reads at A (an image read).
  case FColorSize of
    1:
      begin
        var V := Cardinal(MemRead8(A));
        Color := (V shl 24) or (V shl 16) or (V shl 8) or $E0
      end;
    2:
      begin
        var V := Integer(MemRead16(A));
        Color := Color16(V) and $F8F8F800;
        Coverage := ((V and 1) shl 2) or MemReadHidden(A);
        if FColorFormat <> 0 then
        begin
          var I := Cardinal(V shr 8);
          Color := (I shl 24) or (I shl 16) or (I shl 8);
          Coverage := (V shr 5) and 7;
        end;
        Color := Color or Cardinal(Coverage shl 5);
      end;
    3:
      begin
        Color := MemRead32(A);
        Coverage := (Color shr 5) and 7
      end;
  end;
end;

procedure TN64RDP.Pixel(X, Y: Integer; Color: Cardinal; Fill: Boolean; Depth: Integer; Delta: Cardinal; Coverage: Integer; CoverageBit: Boolean);
const
  ZShift: array[0..7] of Integer = (6, 5, 4, 3, 2, 1, 0, 0);
  ZBase: array[0..7] of Cardinal = (0, $20000, $30000, $38000, $3C000, $3E000, $3F000, $3F800);
  Magic: array[0..15] of Byte = (0, 6, 1, 7, 4, 2, 5, 3, 3, 5, 2, 4, 7, 1, 6, 0);
  Bayer: array[0..15] of Byte = (0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2);
var
  DZEncode, OldDZEncode: Integer;
begin
  // Pixels outside the scissor, the raster or RDRAM are dropped.
  if (X < FRowFirst) or (X > FRowLast) then
    Exit;
  var BPP := FRowBPP;
  var A := FRowBase + Cardinal(X * BPP);
  var Cycle := (FOtherHi shr 20) and 3;
  AddPixelWork(Cycle, BPP);
  if Fill then
  begin
    case FColorSize of
      0:
        Exit; // 4-bit fill crashes the guest RDP pipeline; never a host error.
        1:
        begin
          var V := Byte((FFill shr ((3 - (A and 3)) * 8)) and $FF);
          WriteFramebuffer8(A, V);
        end;
      2:
        begin
          var V: Word;
          if (A and 2) = 0 then
            V := Word(FFill shr 16)
          else
            V := Word(FFill and $FFFF);
          MemWrite16Hidden(A, V, Byte((V and 1) * 3));
          SetHiddenOld((A div 2) and 7, Byte((V and 1) * 3));
        end;
      3:
        begin
          MemWrite32Hidden(A, FFill, Byte(((FFill shr 16) and 1) * 3), Byte((FFill and 1) * 3));
          SetHiddenOld((A div 2) and 7, Byte(((FFill shr 16) and 1) * 3));
          SetHiddenOld(((A div 2) + 1) and 7, Byte((FFill and 1) * 3));
        end;
    end;
    Exit;
  end;
  FBlend.InputColor := Color;
  var PreviousMemoryColor := FMemoryColor;
  var PreviousMemoryCoverage := FMemoryCoverage;
  FBlend.MemoryColor := (FMemoryColor and $FFFFFF00) or $E0;
  FBlend.MemoryCoverage := 7;
  // Without a read the memory colour keeps the previous pixel's RGB.
  var MemoryRead := ((FOtherLo and $40) <> 0) and (FColorSize >= 1);
  if MemoryRead then
    ReadMemoryState(A, FBlend.MemoryColor, FBlend.MemoryCoverage);
  var Alpha := Integer(FBlend.InputColor and $FF);
  if Cycle < 2 then
  begin
    FMemoryColor := FBlend.MemoryColor;
    FMemoryCoverage := FBlend.MemoryCoverage;
    FKeyMemory := FPixelKey;
    if MemoryRead then
      FKeyMemoryRGB := FPixelKey;
  end;
  var AlphaProduct := 0;
  if Alpha = 255 then
    Alpha := 256;
  if (Cycle < 2) and ((FOtherLo and $1000) <> 0) then
  begin
    AlphaProduct := (Alpha * Coverage + 4) shr 3;
    Coverage := (AlphaProduct shr 5) and 15;
  end;
  if (Cycle < 2) and ((FOtherLo and $2000) <> 0) then
    if (FOtherLo and $1000) <> 0 then
      Alpha := Min(255, AlphaProduct)
    else
      Alpha := Min(255, Coverage shl 5)
  else if Cycle < 2 then
    Alpha := Min(255, Alpha + FAlphaDither)
  else
    Alpha := Min(255, Alpha);
  FBlend.InputColor := (FBlend.InputColor and $FFFFFF00) or Cardinal(Alpha);
  if (FOtherLo and 1) <> 0 then
  begin
    var Threshold := Integer(FBlendColor and $FF);
    if (FOtherLo and 2) <> 0 then
    begin
      FNoiseSeed := Cardinal((UInt64(FNoiseSeed) * $343FD + $269EC3) and $FFFFFFFF);
      Threshold := (FNoiseSeed shr 16) and $FF;
    end;
    if (Cycle = 2) and (FColorSize = 2) then
    begin
      if Alpha < 128 then
        Exit
    end
    else if Alpha < Threshold then
      Exit;
  end;
  if ((FOtherLo and 8) <> 0) then
  begin
    if Coverage = 0 then
      Exit
  end
  else if not CoverageBit then
    Exit;
  FBlend.PreWrap := ((FBlend.MemoryCoverage + Coverage) and 8) <> 0;
  FBlend.BlendEnabled := ((FOtherLo and $4000) <> 0) or (((FOtherLo and 8) <> 0) and not FBlend.PreWrap);
  if (FOtherLo and 4) <> 0 then
  begin
    Depth := Integer(FPrimitiveDepth);
    Delta := FPrimitiveDelta
  end;
  var ZAddress := UInt64(FZAddress) + Cardinal((Y * FColorWidth + X) * 2);
  var UseDepth := (Depth >= 0) and (ZAddress + 2 <= $800000) and (Cycle < 2);
  DZEncode := EncodedDZ(Delta);
  FBlend.BlendShiftA := 0;
  FBlend.BlendShiftB := Max(0, 15 - DZEncode);
  if FBlend.BlendShiftB > 4 then
    FBlend.BlendShiftB := 4;
  if UseDepth and ((FOtherLo and $10) <> 0) then
  begin
    var ZA := Cardinal(ZAddress);
    var Stored := MemRead16(ZA);
    var Level := (Stored shr 13) and 7;
    var OldZ := (((Stored shr 2) and $7FF) shl ZShift[Level]) + ZBase[Level];
    OldDZEncode := Integer((Stored and 3) shl 2) or MemReadHidden(ZA);
    var OldDZ := Cardinal(1) shl OldDZEncode;
    var Coplanar := False;
    if Level < 3 then
      if OldDZ = $8000 then
      begin
        Coplanar := True;
        OldDZ := $FFFF
      end
      else
        OldDZ := Max(OldDZ * 2, Cardinal(16) shr Level);
    var DZ := Cardinal(1) shl EncodedDZ((Delta or OldDZ) and $FFFF);
    if (Delta or OldDZ) = 0 then
      DZ := 0;
    var Tolerance := DZ * 8;
    var Farther := Coplanar or (Int64(Depth) + Tolerance >= OldZ);
    var Nearer := Coplanar or (Int64(Depth) - Tolerance <= OldZ);
    var InFront := Cardinal(Depth) < OldZ;
    var IsMax := OldZ = $3FFFF;
    {$IF Defined(CPU64BITS)}
    FBlend.BlendShiftA := ClampTo(DZEncode - OldDZEncode, 0, 4);
    FBlend.BlendShiftB := ClampTo(OldDZEncode - DZEncode, 0, 4);
    {$ELSE}
    FBlend.BlendShiftA := EnsureRange(DZEncode - OldDZEncode, 0, 4);
    FBlend.BlendShiftB := EnsureRange(OldDZEncode - DZEncode, 0, 4);
    {$ENDIF}
    FBlend.BlendEnabled := ((FOtherLo and $4000) <> 0) or (((FOtherLo and 8) <> 0) and not FBlend.PreWrap and Farther);
    case (FOtherLo shr 10) and 3 of
      0:
        if not IsMax and ((FBlend.PreWrap and not InFront) or (not FBlend.PreWrap and not Nearer)) then
          Exit;
      1:
        if InFront and Farther and FBlend.PreWrap then
        begin
          var Coefficient := ((OldZ shr EncodedDZ(DZ)) - (Cardinal(Depth) shr EncodedDZ(DZ))) and 15;
          Coverage := Integer((Coefficient * Cardinal(Coverage) shr 3) and 15);
        end
        else if not IsMax and ((FBlend.PreWrap and not InFront) or (not FBlend.PreWrap and not Nearer)) then
          Exit;
      2:
        if not InFront and not IsMax then
          Exit;
      3:
        if not Farther or not Nearer or IsMax then
          Exit;
    end;
  end;
  if Cycle < 2 then
  begin
    FBlend.BlendedColor := FBlend.InputColor;
    if Cycle = 1 then
    begin
      var CurrentMemoryColor := FBlend.MemoryColor;
      var CurrentMemoryCoverage := FBlend.MemoryCoverage;
      FBlend.MemoryColor := PreviousMemoryColor;
      FBlend.MemoryCoverage := PreviousMemoryCoverage;
      FBlend.BlendedColor := Blend(0, True);
      FBlend.MemoryColor := CurrentMemoryColor;
      FBlend.MemoryCoverage := CurrentMemoryCoverage;
    end;
    Color := Blend(Integer(Cycle), False);
    var RGBDither := (FOtherHi shr 6) and 3;
    if RGBDither <> 3 then
    begin
      var Index := ((Y and 3) shl 2) or (X and 3);
      var DitherValue := Integer(Magic[Index]);
      if RGBDither = 1 then
        DitherValue := Bayer[Index];
      if RGBDither = 2 then
        DitherValue := FNoise;
      {$IF Defined(CPU64BITS)}
      // The three channels unrolled: blue (bits 8..15) takes the noise's bits
      // 6..8, green 3..5, red 0..2.
      var T1 := DitherValue;
      var T2 := DitherValue;
      var T3 := DitherValue;
      if RGBDither = 2 then
      begin
        T1 := (DitherValue shr 6) and 7;
        T2 := (DitherValue shr 3) and 7;
        T3 := DitherValue and 7;
      end;
      var V1 := Integer((Color shr 8) and $FF);
      var V2 := Integer((Color shr 16) and $FF);
      var V3 := Integer(Color shr 24);
      if (V1 and 7) > T1 then
        V1 := Min(255, (V1 and $F8) + 8);
      if (V2 and 7) > T2 then
        V2 := Min(255, (V2 and $F8) + 8);
      if (V3 and 7) > T3 then
        V3 := Min(255, (V3 and $F8) + 8);
      Color := (Color and $FF) or (Cardinal(V1) shl 8) or (Cardinal(V2) shl 16) or (Cardinal(V3) shl 24);
      {$ELSE}
      var Dithered := Color and $FF;
      for var Channel := 1 to 3 do
      begin
        var V := Integer((Color shr (Channel * 8)) and $FF);
        var Threshold := DitherValue;
        if RGBDither = 2 then
          Threshold := (DitherValue shr ((3 - Channel) * 3)) and 7;
        if (V and 7) > Threshold then
          V := Min(255, (V and $F8) + 8);
        Dithered := Dithered or (Cardinal(V) shl (Channel * 8));
      end;
      Color := Dithered;
      {$ENDIF}
    end;
  end;
  var FinalCoverage := 7;
  if Cycle < 2 then
    case (FOtherLo shr 8) and 3 of
      0:
        begin
          if FBlend.BlendEnabled then
            FinalCoverage := Coverage + FBlend.MemoryCoverage
          else
            FinalCoverage := Coverage - 1;
          if (FinalCoverage and 8) <> 0 then
            FinalCoverage := 7
          else
            FinalCoverage := FinalCoverage and 7
        end;
      1:
        FinalCoverage := (Coverage + FBlend.MemoryCoverage) and 7;
      2:
        FinalCoverage := 7;
      3:
        FinalCoverage := FBlend.MemoryCoverage;
    end;
  if UseDepth and ((FOtherLo and $20) <> 0) then
  begin
    {$IF Defined(CPU64BITS)}
    var Z := Cardinal(ClampTo(Depth, 0, $3FFFF));
    {$ELSE}
    var Z := Cardinal(EnsureRange(Depth, 0, $3FFFF));
    {$ENDIF}
    {$IF Defined(CPU64BITS)}
    // The leading ones of bits 17..11 (Z < 2^18): the largest Level with
    // ZBase[Level] <= Z.
    var Level := Integer(LeadingOnes7[(Z shr 11) and $7F]);
    {$ELSE}
    var Level := 7;
    while (Level > 0) and (Z < ZBase[Level]) do
      Dec(Level);
    {$ENDIF}
    var Stored := Word((Cardinal(Level) shl 13) or (((Z - ZBase[Level]) shr ZShift[Level]) shl 2) or Cardinal(DZEncode shr 2));
    MemWrite16Hidden(Cardinal(ZAddress), Stored, Byte(DZEncode and 3));
  end;
  case FColorSize of
    0:
      MemWrite8(A, 0);
    1:
      begin
        var V := Byte((Color shr 24) and $FF);
        if Odd(A) then
          V := Byte((Color shr 16) and $FF);
        WriteFramebuffer8(A, V);
      end;
    2:
      begin
        var V := Word(((Color shr 27) shl 11) or (((Color shr 19) and 31) shl 6) or
          (((Color shr 11) and 31) shl 1) or Cardinal(FinalCoverage shr 2));
        if Cycle = 2 then
        begin
          V := (V and $FFFE) or Word(Ord((Color and $FF) >= 128));
          FinalCoverage := Integer(V and 1) * 3;
        end;
        if FColorFormat <> 0 then
        begin
          V := Word(((Color shr 24) shl 8) or Cardinal(FinalCoverage shl 5));
          FinalCoverage := 0
        end;
        if Cycle = 2 then
          WriteFramebuffer16(A, V)
        else
        begin
          MemWrite16Hidden(A, V, Byte(FinalCoverage and 3));
          SetHiddenOld((A div 2) and 7, Byte(FinalCoverage and 3));
        end;
      end;
    3:
      begin
        var V := (Color and $FFFFFF00) or Cardinal(FinalCoverage shl 5);
        MemWrite32Hidden(A, V, Byte(((Color shr 16) and 1) * 3), 0);
        SetHiddenOld((A div 2) and 7, Byte(((Color shr 16) and 1) * 3));
        SetHiddenOld(((A div 2) + 1) and 7, 0);
      end;
  end;
end;

function WrapCoord(Value: Int64; Limit, Mask, Shift: Integer; Clamp, Mirror: Boolean): Integer;
begin
  if Shift <= 10 then
    Value := Value div (1 shl Shift)
  else
    Value := Value * (1 shl (16 - Shift));
  if Clamp then
    Value := EnsureRange(Value, Int64(0), Int64(Max(0, Limit)));
  if Mask > 0 then
  begin
    Mask := Min(Mask, 10);
    var M := (1 shl Mask) - 1;
    if Mirror and ((Value and (M + 1)) <> 0) then
      Value := not Value;
    Value := Value and M;
  end;
  Result := Integer(Value and $FFFF);
end;

function TexelFloor32(Value: Integer): Integer; inline;
begin
  // ShiftRight(Value, 5) for the bilinear filter: decoded texels lie in
  // -128..255, so |Value| < 32768 and the biased sum is never negative.
  Result := ((Value + 32768) shr 5) - 1024;
end;

function Floor256(Value: Int64): Integer;
begin
  Result := Integer(ShiftRight(Value, 8));
end;

const
  PopCount8: array[0..255] of Byte = (
    0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4, 1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    1, 2, 2, 3, 2, 3, 3, 4, 2, 3, 3, 4, 3, 4, 4, 5, 2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    2, 3, 3, 4, 3, 4, 4, 5, 3, 4, 4, 5, 4, 5, 5, 6, 3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7,
    3, 4, 4, 5, 4, 5, 5, 6, 4, 5, 5, 6, 5, 6, 6, 7, 4, 5, 5, 6, 5, 6, 6, 7, 5, 6, 6, 7, 6, 7, 7, 8);

function WrapTexel(Value, Limit, Mask: Integer; Clamp, Mirror: Boolean): Integer; inline;
begin
  // WrapCoord with a zero shift; Clamp is always set when Mask is zero, so
  // the result is non-negative and below 64K before the final mask.
  if Clamp then
    if Value < 0 then
      Value := 0
    else if Value > Limit then
      Value := Limit;
  if Mask > 0 then
  begin
    var M := (1 shl Mask) - 1;
    if Mirror and ((Value and (M + 1)) <> 0) then
      Value := not Value;
    Value := Value and M;
  end;
  Result := Value and $FFFF;
end;

procedure TN64RDP.UpdateTileInfo(Tile: Integer);
begin
  FTileInfo[Tile].LimitS := (FTiles[Tile].SH div 4 - FTiles[Tile].SL div 4) and $3FF;
  FTileInfo[Tile].LimitT := (FTiles[Tile].TH div 4 - FTiles[Tile].TL div 4) and $3FF;
  FTileInfo[Tile].MaskS := Min(FTiles[Tile].MaskS, 10);
  FTileInfo[Tile].MaskT := Min(FTiles[Tile].MaskT, 10);
  FTileInfo[Tile].ClampS := FTiles[Tile].ClampS or (FTiles[Tile].MaskS = 0);
  FTileInfo[Tile].ClampT := FTiles[Tile].ClampT or (FTiles[Tile].MaskT = 0);
  // Every tile or TMEM load command passes through here.
  InvalidateTexels;
end;

procedure TN64RDP.InvalidateTexels;
begin
  {$IF Defined(CPU64BITS)}
  // (Entries keep the generation's low 28 bits: cleared when those wrap.)
  if FTexelGeneration = High(Cardinal) then
    FTexelGeneration := 0;
  Inc(FTexelGeneration);
  if (FTexelGeneration and $0FFFFFFF) <= 1 then
  begin
    FillChar(FTexelCache, SizeOf(FTexelCache), 0);
    FillChar(FFiltered, SizeOf(FFiltered), 0);
    FillChar(FIndexCache, SizeOf(FIndexCache), 0);
    FillChar(FPaletteCache, SizeOf(FPaletteCache), 0);
    if (FTexelGeneration and $0FFFFFFF) = 0 then
      Inc(FTexelGeneration);
  end;
  {$ELSE}
  if FTexelGeneration = High(Cardinal) then
  begin
    for var I := 0 to High(FTexelStamps) do
    begin
      FTexelStamps[I] := 0;
      FIndexStamps[I] := 0;
      FPaletteStamps[I] := 0;
    end;
    for var I := 0 to High(FFilteredStamps) do
      FFilteredStamps[I] := 0;
    FTexelGeneration := 1;
  end
  else
    Inc(FTexelGeneration);
  {$ENDIF}
end;

function TN64RDP.TexelAt(Tile, S, T: Integer): TN64Texel;
begin
  // S, T are wrapped (0..$FFFF) and Tile is 0..7, so the key is exact.
  var Key := (UInt64(Tile) shl 32) or (UInt64(S) shl 16) or UInt64(T);
  var Slot := (S + T * 33 + Tile * 257) and 1023;
  {$IF Defined(CPU64BITS)}
  var Tag := Key or (UInt64(FTexelGeneration and $0FFFFFFF) shl 36);
  if FTexelCache[Slot].Tag = Tag then
    Exit(FTexelCache[Slot].Texel);
  Result := DecodeTexel(Tile, S, T);
  FTexelCache[Slot].Texel := Result;
  FTexelCache[Slot].Quad := UInt64(Result.C[0] and $FF) or
    (UInt64(Result.C[1] and $FF) shl 16) or
    (UInt64(Result.C[2] and $FF) shl 32) or
    (UInt64(Result.C[3] and $FF) shl 48);
  FTexelCache[Slot].Tag := Tag;
  {$ELSE}
  if (FTexelStamps[Slot] = FTexelGeneration) and (FTexelKeys[Slot] = Key) then
    Exit(FTexels[Slot]);
  Result := DecodeTexel(Tile, S, T);
  FTexels[Slot] := Result;
  FPackedTexels[Slot] := UInt64(Result.C[0] and $FF) or
    (UInt64(Result.C[1] and $FF) shl 16) or
    (UInt64(Result.C[2] and $FF) shl 32) or
    (UInt64(Result.C[3] and $FF) shl 48);
  FTexelKeys[Slot] := Key;
  FTexelStamps[Slot] := FTexelGeneration;
  {$ENDIF}
end;

function TN64RDP.PackedTexelAt(Tile, S, T: Integer): UInt64;
begin
  var Key := (UInt64(Tile) shl 32) or (UInt64(S) shl 16) or UInt64(T);
  var Slot := (S + T * 33 + Tile * 257) and 1023;
  {$IF Defined(CPU64BITS)}
  if FTexelCache[Slot].Tag <> Key or (UInt64(FTexelGeneration and $0FFFFFFF) shl 36) then
    TexelAt(Tile, S, T);
  Result := FTexelCache[Slot].Quad;
  {$ELSE}
  if (FTexelStamps[Slot] <> FTexelGeneration) or (FTexelKeys[Slot] <> Key) then
    TexelAt(Tile, S, T);
  Result := FPackedTexels[Slot];
  {$ENDIF}
end;

function TN64RDP.TexelBits(Tile, S, T: Integer; out Address: Integer): Cardinal;
begin
  // Texel (S, T)'s bits in TMEM (4-bit ones in the low nibble) and where
  // they are. S and T are tile coordinates already wrapped/clamped by
  // WrapTexel.
  var Size := FTiles[Tile].Size;
  var Format := FTiles[Tile].Format;
  // TMEM <= 511, Line <= 511, Row <= 255 and S < 64K: every sum fits Integer.
  var LineBase := FTiles[Tile].TMEM * 8 + (T and $FF) * FTiles[Tile].Line * 8;
  if Format = 1 then
    Address := (LineBase + S) and $7FF
  else if Size = 3 then
    Address := (LineBase + S * 2) and $FFF
  else
    Address := (LineBase + ((S * (4 shl Size)) shr 3)) and $FFF;
  if Odd(T) then
    Address := Address xor 4;
  Result := Cardinal(FTMEM[Address]);
  if Size >= 2 then
    Result := (Result shl 8) or FTMEM[(Address + 1) and $FFF];
  if (Size = 3) and (Format = 0) then
  begin
    Address := Address and $7FF;
    Result := (Cardinal(FTMEM[Address]) shl 24) or (Cardinal(FTMEM[(Address + 1) and $7FF]) shl 16) or
      (Cardinal(FTMEM[Address or $800]) shl 8) or FTMEM[((Address + 1) and $7FF) or $800];
  end;
  if Size = 0 then
    if (S and 1) = 0 then
      Result := Result shr 4
    else
      Result := Result and 15;
end;

function TN64RDP.PaletteIndex(Tile: Integer; Bits: Cardinal): Integer;
begin
  // The palette entry of a texel with these bits (TexelBits'): a 4-bit
  // texel's with the tile's palette, else the first byte of the texel's
  // (first) halfword in TMEM (of a 32-bit RGBA texel the low half's).
  case FTiles[Tile].Size of
    0:
      Result := FTiles[Tile].Palette * 16 + Integer(Bits);
    1:
      Result := Integer(Bits);
    2:
      Result := Integer(Bits shr 8);
  else
    if FTiles[Tile].Format = 0 then
      Result := Integer(Bits shr 24)
    else
      Result := Integer(Bits shr 8);
  end;
  Result := Result and $FF;
end;

function TN64RDP.TLUTIndex(Tile, S, T: Integer): Integer;
begin
  // (Cached as TexelAt's texels.)
  var Key := (UInt64(Tile) shl 32) or (UInt64(S) shl 16) or UInt64(T);
  var Slot := (S + T * 33 + Tile * 257) and 1023;
  {$IF Defined(CPU64BITS)}
  var Tag := Key or (UInt64(FTexelGeneration and $0FFFFFFF) shl 36);
  if FIndexCache[Slot].Tag = Tag then
    Exit(FIndexCache[Slot].Value);
  {$ELSE}
  if (FIndexStamps[Slot] = FTexelGeneration) and (FIndexKeys[Slot] = Key) then
    Exit(FIndexValues[Slot]);
  {$ENDIF}
  var Address: Integer;
  Result := PaletteIndex(Tile, TexelBits(Tile, S, T, Address));
  {$IF Defined(CPU64BITS)}
  FIndexCache[Slot].Value := Result;
  FIndexCache[Slot].Tag := Tag;
  {$ELSE}
  FIndexValues[Slot] := Result;
  FIndexKeys[Slot] := Key;
  FIndexStamps[Slot] := FTexelGeneration;
  {$ENDIF}
end;

function TN64RDP.PackedTLUTTexel(Index, Halfword: Integer): UInt64;
begin
  // Halfword (0..3) of palette entry Index, decoded as the TLUT type says,
  // its channels in four 16-bit lanes.
  var Slot := Index * 4 + Halfword;
  {$IF Defined(CPU64BITS)}
  var Tag := UInt64(FTexelGeneration and $0FFFFFFF);
  if FPaletteCache[Slot].Tag = Tag then
    Exit(FPaletteCache[Slot].Texel);
  {$ELSE}
  if FPaletteStamps[Slot] = FTexelGeneration then
    Exit(FPaletteTexels[Slot]);
  {$ENDIF}
  var PA := $800 + Index * 8 + Halfword * 2;
  var V := (Cardinal(FTMEM[PA]) shl 8) or FTMEM[PA + 1];
  if (FOtherHi and $4000) <> 0 then
  begin
    var I := UInt64(V shr 8);
    Result := I or (I shl 16) or (I shl 32) or (UInt64(V and $FF) shl 48);
  end
  else
  begin
    var R := (V shr 11) and 31;
    var G := (V shr 6) and 31;
    var B := (V shr 1) and 31;
    Result := UInt64((R shl 3) or (R shr 2)) or (UInt64((G shl 3) or (G shr 2)) shl 16) or
      (UInt64((B shl 3) or (B shr 2)) shl 32) or (UInt64((V and 1) * $FF) shl 48);
  end;
  {$IF Defined(CPU64BITS)}
  FPaletteCache[Slot].Texel := Result;
  FPaletteCache[Slot].Tag := Tag;
  {$ELSE}
  FPaletteTexels[Slot] := Result;
  FPaletteStamps[Slot] := FTexelGeneration;
  {$ENDIF}
end;

function TN64RDP.DecodeTexel(Tile, S, T: Integer): TN64Texel;
begin
  var Size := FTiles[Tile].Size;
  var Format := FTiles[Tile].Format;
  var Address: Integer;
  var V := TexelBits(Tile, S, T, Address);
  if (FOtherHi and $8000) <> 0 then
  begin
    var PA := ($800 + PaletteIndex(Tile, V) * 8 + ((Address shr 1) and 3) * 2) and $FFF;
    var Palette := (Cardinal(FTMEM[PA]) shl 8) or FTMEM[(PA + 1) and $FFF];
    if (FOtherHi and $4000) = 0 then
      Exit(Texel5551(Word(Palette)));
    Result.C[0] := Palette shr 8;
    Result.C[1] := Result.C[0];
    Result.C[2] := Result.C[0];
    Result.C[3] := Palette and $FF;
    Exit;
  end;
  Result := Default(TN64Texel);
  case Format of
    0:
      begin
        if Size = 3 then
          Exit(TexelFromRGBA(V));
        if Size = 2 then
          Exit(Texel5551(Word(V)));
        if Size = 0 then
          V := V * 17;
        for var I := 0 to 3 do
          Result.C[I] := Integer(V);
      end;
    1:
      if Size <= 1 then
      begin
        var Y := Integer(FTMEM[Address]);
        if Size = 0 then
          Y := (Y and $F0) or (Y shr 4);
        Result.C[0] := Y - 128;
        Result.C[1] := Y - 128;
        Result.C[2] := Y;
        Result.C[3] := Y;
      end
      else
      begin
        Result.C[0] := Integer(FTMEM[Address and $7FE]) - 128;
        Result.C[1] := Integer(FTMEM[(Address and $7FE) + 1]) - 128;
        Result.C[2] := FTMEM[Address or $800];
        Result.C[3] := Result.C[2];
      end;
    2:
      begin
        if Size = 0 then
          V := Cardinal(FTiles[Tile].Palette * 16) + V;
        if Size >= 2 then
        begin
          Result.C[0] := V shr 8;
          Result.C[1] := V and $FF;
          Result.C[2] := Result.C[0];
          Result.C[3] := Result.C[1]
        end
        else
          for var I := 0 to 3 do
            Result.C[I] := Integer(V);
      end;
    3:
      begin
        var Intensity := V;
        var Alpha := V;
        case Size of
          0:
            begin
              Intensity := ((V and 14) shl 4) or ((V and 14) shl 1) or ((V and 14) shr 2);
              Alpha := (V and 1) * 255
            end;
          1:
            begin
              Intensity := (V shr 4) * 17;
              Alpha := (V and 15) * 17
            end;
          2, 3:
            begin
              Intensity := V shr 8;
              Alpha := V and $FF
            end;
        end;
        Result.C[0] := Integer(Intensity);
        Result.C[1] := Integer(Intensity);
        Result.C[2] := Integer(Intensity);
        Result.C[3] := Integer(Alpha);
        if Size = 3 then
          Result.C[1] := Result.C[3];
      end;
  else
    if Size >= 2 then
    begin
      Result.C[0] := V shr 8;
      Result.C[1] := V and $FF;
      Result.C[2] := Result.C[0];
      Result.C[3] := Result.C[1]
    end
    else
    begin
      if Size = 0 then
        V := V * 17;
      for var I := 0 to 3 do
        Result.C[I] := Integer(V)
    end;
  end;
end;

function TN64RDP.Converted(const Raw: TN64Texel): TN64Texel;
begin
  // YUV to RGB with the K0..K3 coefficients of SetConvert.
  var U := Integer(SignedValue(SX(Cardinal(Raw.C[0] and $1FF), 9)));
  var V := Integer(SignedValue(SX(Cardinal(Raw.C[1] and $1FF), 9)));
  var Y := Integer(SignedValue(SX(Cardinal(Raw.C[2] and $1FF), 9)));
  Result.C[0] := (Y + Floor256(FConvert[0] * V + 128)) and $1FF;
  Result.C[1] := (Y + Floor256(FConvert[1] * U + FConvert[2] * V + 128)) and $1FF;
  Result.C[2] := (Y + Floor256(FConvert[3] * U + 128)) and $1FF;
  Result.C[3] := Y and $1FF;
end;

function TN64RDP.Texture(Tile: Integer; S, T: Integer; Cycle: Integer; const Previous: TN64Texel): TN64Texel;
begin
  var Cacheable := (((FOtherHi shr 20) and 3) <> 2) and (FTiles[Tile].Format <> 1) and
    ((FOtherHi and (Cardinal($800) shr Cycle)) <> 0) and
    not ((Cycle = 1) and ((FOtherHi and $200) <> 0)) and
    ((FOtherHi and $A000) <> 0);
  var FilterKey: UInt64 := 0;
  var FilterSlot := 0;
  if Cacheable then
  begin
    FilterKey := UInt64(S and $FFFF) or (UInt64(T and $FFFF) shl 16) or
      (UInt64(Tile) shl 32) or (UInt64(Cycle) shl 35);
    FilterSlot := Integer((FilterKey xor (FilterKey shr 11) xor (FilterKey shr 23)) and 4095);
    {$IF Defined(CPU64BITS)}
    // (From here on the key with the generation: the entry's tag.)
    FilterKey := FilterKey or (UInt64(FTexelGeneration and $0FFFFFFF) shl 36);
    if FFiltered[FilterSlot].Tag = FilterKey then
    begin
      var P := FFiltered[FilterSlot].Texel;
    {$ELSE}
    if (FFilteredStamps[FilterSlot] = FTexelGeneration) and (FFilteredKeys[FilterSlot] = FilterKey) then
    begin
      var P := FFilteredTexels[FilterSlot];
    {$ENDIF}
      Result.C[0] := Integer(P and $FF);
      Result.C[1] := Integer((P shr 16) and $FF);
      Result.C[2] := Integer((P shr 32) and $FF);
      Result.C[3] := Integer((P shr 48) and $FF);
      Exit;
    end;
  end;
  // SmallInt(Word(..)) is the explicit 16-bit sign extension used by SX(.., 16).
  S := SmallInt(Word(S and $FFFF));
  T := SmallInt(Word(T and $FFFF));
  var ShiftS := FTiles[Tile].ShiftS;
  var ShiftT := FTiles[Tile].ShiftT;
  if ShiftS <= 10 then
    S := ((S + 32768) shr ShiftS) - (32768 shr ShiftS)
  else
    S := SmallInt(Word((S * (1 shl (16 - ShiftS))) and $FFFF));
  if ShiftT <= 10 then
    T := ((T + 32768) shr ShiftT) - (32768 shr ShiftT)
  else
    T := SmallInt(Word((T * (1 shl (16 - ShiftT))) and $FFFF));
  var MaxS := S >= FTiles[Tile].SH * 8;
  var MaxT := T >= FTiles[Tile].TH * 8;
  S := S - FTiles[Tile].SL * 8;
  T := T - FTiles[Tile].TL * 8;
  var FX := Integer(S and 31);
  var FY := Integer(T and 31);
  if FTileInfo[Tile].ClampS then
    if MaxS then
    begin
      S := FTileInfo[Tile].LimitS * 32;
      FX := 0
    end
    else if S < 0 then
    begin
      S := 0;
      FX := 0
    end;
  if FTileInfo[Tile].ClampT then
    if MaxT then
    begin
      T := FTileInfo[Tile].LimitT * 32;
      FY := 0
    end
    else if T < 0 then
    begin
      T := 0;
      FY := 0
    end;
  var X := ((S + 65536) shr 5) - 2048;
  var Y := ((T + 65536) shr 5) - 2048;
  // Replace spatial interpolation only. Copy cycles and convert-one's
  // coefficient arithmetic retain their hardware meaning.
  if not FBilinearFiltering and (((FOtherHi shr 20) and 3) <> 2) and
    ((FOtherHi and (Cardinal($800) shr Cycle)) <> 0) and
    ((FOtherHi and $A000) <> 0) and
    not ((Cycle = 1) and ((FOtherHi and $200) <> 0)) then
  begin
    var Nearest := TexelAt(Tile,
      WrapTexel(X + Ord(FX >= 16), FTileInfo[Tile].LimitS, FTileInfo[Tile].MaskS, FTileInfo[Tile].ClampS, FTiles[Tile].MirrorS),
      WrapTexel(Y + Ord(FY >= 16), FTileInfo[Tile].LimitT, FTileInfo[Tile].MaskT, FTileInfo[Tile].ClampT, FTiles[Tile].MirrorT));
    if FTiles[Tile].Format = 1 then
      Exit(Converted(Nearest));
    if Cacheable then
    begin
      {$IF Defined(CPU64BITS)}
      FFiltered[FilterSlot].Texel := UInt64(Nearest.C[0]) or
        (UInt64(Nearest.C[1]) shl 16) or (UInt64(Nearest.C[2]) shl 32) or
        (UInt64(Nearest.C[3]) shl 48);
      FFiltered[FilterSlot].Tag := FilterKey;
      {$ELSE}
      FFilteredTexels[FilterSlot] := UInt64(Nearest.C[0]) or
        (UInt64(Nearest.C[1]) shl 16) or (UInt64(Nearest.C[2]) shl 32) or
        (UInt64(Nearest.C[3]) shl 48);
      FFilteredKeys[FilterSlot] := FilterKey;
      FFilteredStamps[FilterSlot] := FTexelGeneration;
      {$ENDIF}
    end;
    Exit(Nearest);
  end;
  // Wrap each neighbouring coordinate once, then address TMEM with TexelAt.
  var LimitS := FTileInfo[Tile].LimitS;
  var MaskS := FTileInfo[Tile].MaskS;
  var WrapClampS := FTileInfo[Tile].ClampS;
  var MirrorS := FTiles[Tile].MirrorS;
  var LimitT := FTileInfo[Tile].LimitT;
  var MaskT := FTileInfo[Tile].MaskT;
  var WrapClampT := FTileInfo[Tile].ClampT;
  var MirrorT := FTiles[Tile].MirrorT;
  var S0 := WrapTexel(X, LimitS, MaskS, WrapClampS, MirrorS);
  var T0 := WrapTexel(Y, LimitT, MaskT, WrapClampT, MirrorT);
  var Bilerp := (FOtherHi and (Cardinal($800) shr Cycle)) <> 0;
  var ConvertOne := (Cycle = 1) and ((FOtherHi and $200) <> 0);
  var Sample := (FOtherHi and $2000) <> 0;
  if Cacheable then
  begin
    // Non-YUV texels have unsigned 8-bit channels. Four 16-bit lanes hold
    // the weighted sum independently: weights total 32, so each lane is
    // at most 255*32+16 < 2^13 and cannot carry into its neighbour.
    // Fetch only the three taps of the chosen triangle (four at mid-texel).
    var S1 := WrapTexel(X + 1, LimitS, MaskS, WrapClampS, MirrorS);
    var T1 := WrapTexel(Y + 1, LimitT, MaskT, WrapClampT, MirrorT);
    var Sum: UInt64;
    if (FOtherHi and $8000) <> 0 then
    begin
      // Through the TLUT: each palette entry is four halfwords, and tap K
      // reads halfword K of its entry (3 - K in the upper triangle); with
      // point sampling all four taps take the entry of texel (S0, T0), so
      // an entry's four halfwords are filtered between (the same colour as
      // LoadTLUT writes them).
      // (Only the taps the weights use.)
      var I0 := TLUTIndex(Tile, S0, T0);
      if ((FOtherHi and $1000) <> 0) and (FX = 16) and (FY = 16) then
      begin
        // Mid-texel (the upper triangle's halfwords).
        if Sample then
          Sum := PackedTLUTTexel(I0, 3) + PackedTLUTTexel(TLUTIndex(Tile, S1, T0), 2) +
            PackedTLUTTexel(TLUTIndex(Tile, S0, T1), 1) + PackedTLUTTexel(TLUTIndex(Tile, S1, T1), 0)
        else
          Sum := PackedTLUTTexel(I0, 3) + PackedTLUTTexel(I0, 2) + PackedTLUTTexel(I0, 1) + PackedTLUTTexel(I0, 0);
        Sum := Sum * 8;
      end
      else if FX + FY < 32 then
      begin
        Sum := PackedTLUTTexel(I0, 0) * UInt64(32 - FX - FY);
        if FX <> 0 then
          if Sample then
            Inc(Sum, PackedTLUTTexel(TLUTIndex(Tile, S1, T0), 1) * UInt64(FX))
          else
            Inc(Sum, PackedTLUTTexel(I0, 1) * UInt64(FX));
        if FY <> 0 then
          if Sample then
            Inc(Sum, PackedTLUTTexel(TLUTIndex(Tile, S0, T1), 2) * UInt64(FY))
          else
            Inc(Sum, PackedTLUTTexel(I0, 2) * UInt64(FY));
      end
      else if Sample then
        Sum := PackedTLUTTexel(TLUTIndex(Tile, S1, T1), 0) * UInt64(FX + FY - 32) +
          PackedTLUTTexel(TLUTIndex(Tile, S0, T1), 1) * UInt64(32 - FX) +
          PackedTLUTTexel(TLUTIndex(Tile, S1, T0), 2) * UInt64(32 - FY)
      else
        Sum := PackedTLUTTexel(I0, 0) * UInt64(FX + FY - 32) + PackedTLUTTexel(I0, 1) * UInt64(32 - FX) +
          PackedTLUTTexel(I0, 2) * UInt64(32 - FY);
    end
    else if ((FOtherHi and $1000) <> 0) and (FX = 16) and (FY = 16) then
      Sum := (PackedTexelAt(Tile, S0, T0) + PackedTexelAt(Tile, S1, T0) +
        PackedTexelAt(Tile, S0, T1) + PackedTexelAt(Tile, S1, T1)) * 8
    else if FX + FY < 32 then
    begin
      Sum := PackedTexelAt(Tile, S0, T0) * UInt64(32 - FX - FY);
      if FX <> 0 then
        Inc(Sum, PackedTexelAt(Tile, S1, T0) * UInt64(FX));
      if FY <> 0 then
        Inc(Sum, PackedTexelAt(Tile, S0, T1) * UInt64(FY));
    end
    else
      Sum := PackedTexelAt(Tile, S1, T1) * UInt64(FX + FY - 32) +
        PackedTexelAt(Tile, S0, T1) * UInt64(32 - FX) +
        PackedTexelAt(Tile, S1, T0) * UInt64(32 - FY);
    Inc(Sum, UInt64($0010001000100010));
    Result.C[0] := Integer((Sum shr 5) and $FF);
    Result.C[1] := Integer((Sum shr 21) and $FF);
    Result.C[2] := Integer((Sum shr 37) and $FF);
    Result.C[3] := Integer((Sum shr 53) and $FF);
    {$IF Defined(CPU64BITS)}
    FFiltered[FilterSlot].Texel := (Sum shr 5) and UInt64($00FF00FF00FF00FF);
    FFiltered[FilterSlot].Tag := FilterKey;
    {$ELSE}
    FFilteredTexels[FilterSlot] := (Sum shr 5) and UInt64($00FF00FF00FF00FF);
    FFilteredKeys[FilterSlot] := FilterKey;
    FFilteredStamps[FilterSlot] := FTexelGeneration;
    {$ENDIF}
    Exit;
  end;
  var Base := TexelAt(Tile, S0, T0);
  if ((FOtherHi shr 20) and 3) = 2 then
    Exit(Base);
  // At an integer texel the bilinear weights select Base exactly. YUV has
  // separate chroma fractions, so it must keep the general path.
  if Bilerp and not ConvertOne and (FX = 0) and (FY = 0) and (FTiles[Tile].Format <> 1) then
    Exit(Base);
  if not Bilerp then
  begin
    if ConvertOne then
      Exit(Converted(Previous));
    if (not Sample and ((FOtherHi and $8000) = 0)) or
      ((FX + FY < 32) and ((FTiles[Tile].Format <> 1) or
      (((FX shr 1) or ((X and 1) shl 4)) + FY < 32))) then
      Exit(Converted(Base));
  end;
  if Sample or ((FOtherHi and $8000) <> 0) then
  begin
    var S1 := WrapTexel(X + 1, LimitS, MaskS, WrapClampS, MirrorS);
    var T1 := WrapTexel(Y + 1, LimitT, MaskT, WrapClampT, MirrorT);
    var C1 := TexelAt(Tile, S1, T0);
    var C2 := TexelAt(Tile, S0, T1);
    var C3 := TexelAt(Tile, S1, T1);
    var ChromaX := FX;
    if FTiles[Tile].Format = 1 then
    begin
      ChromaX := (FX shr 1) or ((X and 1) shl 4);
      var S2 := WrapTexel(X + 2, LimitS, MaskS, WrapClampS, MirrorS);
      var Chroma1 := TexelAt(Tile, S2, T0);
      var Chroma3 := TexelAt(Tile, S2, T1);
      C1.C[0] := Chroma1.C[0];
      C1.C[1] := Chroma1.C[1];
      C3.C[0] := Chroma3.C[0];
      C3.C[1] := Chroma3.C[1];
    end;
    if not Bilerp then
    begin
      var Raw := Base;
      if FX + FY >= 32 then
      begin
        Raw.C[2] := C3.C[2];
        Raw.C[3] := C3.C[3]
      end;
      if ChromaX + FY >= 32 then
      begin
        Raw.C[0] := C3.C[0];
        Raw.C[1] := C3.C[1]
      end;
      if ConvertOne then
        Raw := Previous;
      Exit(Converted(Raw));
    end;
    for var I := 0 to 3 do
    begin
      var FractionX := FX;
      if I < 2 then
        FractionX := ChromaX;
      var A := Base.C[I];
      var B := C1.C[I];
      var C := C2.C[I];
      var D := C3.C[I];
      if ConvertOne then
      begin
        var PR := Integer(SignedValue(SX(Cardinal(Previous.C[0] and $1FF), 9)));
        var PG := Integer(SignedValue(SX(Cardinal(Previous.C[1] and $1FF), 9)));
        var PB := Integer(SignedValue(SX(Cardinal(Previous.C[2] and $1FF), 9)));
        if FractionX + FY >= 32 then
          Result.C[I] := PB + Floor256(PR * (C - D) + PG * (B - D) + 128)
        else
          Result.C[I] := PB + Floor256(PR * (B - A) + PG * (C - A) + 128);
        if ((FOtherHi and $1000) <> 0) and (FractionX = 16) and (FY = 16) then
          Result.C[I] := PB + Floor256(PR * (C - D) + PG * (B - D) + ((A - D - 1) * 64) + 192);
      end
      else
      begin
        if FractionX + FY >= 32 then
          Result.C[I] := D + TexelFloor32((C - D) * (32 - FractionX) + (B - D) * (32 - FY) + 16)
        else
          Result.C[I] := A + TexelFloor32((B - A) * FractionX + (C - A) * FY + 16);
        if ((FOtherHi and $1000) <> 0) and (FractionX = 16) and (FY = 16) then
          Result.C[I] := Integer(ShiftRight(A + B + C + D + 2, 2));
      end;
      Result.C[I] := Result.C[I] and $1FF;
    end;
  end
  else if Bilerp then
    if ConvertOne then
    begin
      for var I := 0 to 3 do
        Result.C[I] := Previous.C[2] and $1FF
    end
    else
      Result := Base
  else if ConvertOne then
    Result := Converted(Previous)
  else
    Result := Converted(Base);
end;

function Extend9(Value: Integer): Integer; inline;
begin
  // Combiner inputs: nine bits, with 0x180..0x1FF read as negative.
  Result := Value and $1FF;
  {$IF Defined(CPU64BITS)}
  // (Without a branch: Result + 128 reaches 512 just from 0x180 on.)
  Dec(Result, ((Result + 128) shr 9) shl 9);
  {$ELSE}
  if (Result and $180) = $180 then
    Dec(Result, 512);
  {$ENDIF}
end;

function Sign9(Value: Integer): Integer; inline;
begin
  Result := ((Value and $1FF) xor $100) - $100;
end;

const
  // Combiner input slots (TN64CombineInputs.Slots). The constant ones are
  // set by DecodeMode, the others for each pixel: the combined colour and
  // alpha of the first cycle, the texels, the shade (lane 0 of the noise and
  // LOD slots).
  InCombined = 0;
  InTexel = 1;
  InTexel1 = 2;
  InPrimitive = 3;
  InShade = 4;
  InEnvironment = 5;
  InOne = 6;
  InNoise = 7;
  InKeyCenter = 8;
  InKeyScale = 9;
  InConvert = 10; // K4, K5
  InLOD = 11;
  InPrimitiveLOD = 12;
  InZero = 13;
  InTexelNext = 14;

procedure TN64RDP.DecodeMode(Textured: Boolean);
const
  Magic: array[0..15] of Byte = (0, 6, 1, 7, 4, 2, 5, 3, 3, 5, 2, 4, 7, 1, 6, 0);
  Bayer: array[0..15] of Byte = (0, 4, 1, 5, 4, 0, 5, 1, 3, 7, 2, 6, 7, 3, 6, 2);
var
  Sources: array[0..5] of Integer;
begin
  FModeDirty := False;
  FMode.Textured := Textured;
  var Cycle := (FOtherHi shr 20) and 3;
  FMode.FirstCycle := 1;
  if Cycle = 1 then
    FMode.FirstCycle := 0;
  // The constant combiner inputs.
  for var I := 0 to 3 do
  begin
    FIn.Slots[InPrimitive].C[I] := Integer((FPrimitive shr (24 - I * 8)) and $FF);
    FIn.Slots[InEnvironment].C[I] := Integer((FEnvironment shr (24 - I * 8)) and $FF);
    FIn.Slots[InOne].C[I] := 256;
    FIn.Slots[InZero].C[I] := 0;
  end;
  for var I := 0 to 2 do
  begin
    FIn.Slots[InKeyCenter].C[I] := FKeyCenter[I];
    FIn.Slots[InKeyScale].C[I] := FKeyScale[I];
  end;
  FIn.Slots[InConvert].C[0] := FConvert[4];
  FIn.Slots[InConvert].C[1] := FConvert[5];
  FIn.Slots[InPrimitiveLOD].C[0] := Integer(FPrimitiveLOD);
  for var C := 0 to 1 do
  begin
    // TEXEL0 and TEXEL1 of this cycle. The second of two cycles sees TEXEL1
    // as TEXEL0 and the next pixel's texel as TEXEL1; one cycle sees the
    // next pixel's texel as TEXEL1. Without texture they are the shade.
    var Texel0 := InTexel;
    var Texel1 := InTexelNext;
    if Cycle = 1 then
      if C = 0 then
        Texel1 := InTexel1
      else
        Texel0 := InTexel1;
    if not Textured then
    begin
      Texel0 := InShade;
      Texel1 := InShade;
    end;
    // The first cycle run combines with zero.
    var Combined := InCombined;
    if C = FMode.FirstCycle then
      Combined := InZero;
    Sources[0] := Combined;
    Sources[1] := Texel0;
    Sources[2] := Texel1;
    Sources[3] := InPrimitive;
    Sources[4] := InShade;
    Sources[5] := InEnvironment;
    var A, B, M, D, AA, AB, AM, AD: Integer;
    if C = 0 then
    begin
      A := (FCombineHi shr 20) and 15;
      M := (FCombineHi shr 15) and 31;
      AA := (FCombineHi shr 12) and 7;
      AM := (FCombineHi shr 9) and 7;
      B := (FCombineLo shr 28) and 15;
      D := (FCombineLo shr 15) and 7;
      AB := (FCombineLo shr 12) and 7;
      AD := (FCombineLo shr 9) and 7;
    end
    else
    begin
      A := (FCombineHi shr 5) and 15;
      M := FCombineHi and 31;
      AA := (FCombineLo shr 21) and 7;
      AM := (FCombineLo shr 18) and 7;
      B := (FCombineLo shr 24) and 15;
      D := (FCombineLo shr 6) and 7;
      AB := (FCombineLo shr 3) and 7;
      AD := FCombineLo and 7;
    end;
    // RGB legs: A (sub+), B (sub-), C (multiplier), D (adder).
    for var Lane := 0 to 2 do
    begin
      var Leg: Integer;
      case A of
        0..5:
          Leg := Sources[A] * 4 + Lane;
        6:
          Leg := InOne * 4 + Lane;
        7:
          Leg := InNoise * 4;
      else
        Leg := InZero * 4;
      end;
      FMode.LegA[C, Lane] := Byte(Leg);
      case B of
        0..5:
          Leg := Sources[B] * 4 + Lane;
        6:
          Leg := InKeyCenter * 4 + Lane;
        7:
          Leg := InConvert * 4;
      else
        Leg := InZero * 4;
      end;
      FMode.LegB[C, Lane] := Byte(Leg);
      case M of
        0..5:
          Leg := Sources[M] * 4 + Lane;
        6:
          Leg := InKeyScale * 4 + Lane;
        7:
          Leg := Combined * 4 + 3;
        8:
          Leg := Texel0 * 4 + 3;
        9:
          Leg := Texel1 * 4 + 3;
        10:
          Leg := InPrimitive * 4 + 3;
        11:
          Leg := InShade * 4 + 3;
        12:
          Leg := InEnvironment * 4 + 3;
        13:
          Leg := InLOD * 4;
        14:
          Leg := InPrimitiveLOD * 4;
        15:
          Leg := InConvert * 4 + 1;
      else
        Leg := InZero * 4;
      end;
      FMode.LegC[C, Lane] := Byte(Leg);
      case D of
        0..5:
          Leg := Sources[D] * 4 + Lane;
        6:
          Leg := InOne * 4 + Lane;
      else
        Leg := InZero * 4;
      end;
      FMode.LegD[C, Lane] := Byte(Leg);
    end;
    // Alpha legs: sources 0..5 are their alpha lanes, 6 is 256 and 7 zero;
    // the multiplier reads the LOD fraction for 0 and the primitive LOD
    // for 6.
    var AlphaLegs: array[0..3] of Integer;
    AlphaLegs[0] := AA;
    AlphaLegs[1] := AB;
    AlphaLegs[2] := AM;
    AlphaLegs[3] := AD;
    for var K := 0 to 3 do
    begin
      var Leg: Integer;
      case AlphaLegs[K] of
        0..5:
          Leg := Sources[AlphaLegs[K]] * 4 + 3;
        6:
          Leg := InOne * 4 + 3;
      else
        Leg := InZero * 4;
      end;
      if K = 2 then
        case AM of
          0:
            Leg := InLOD * 4;
          6:
            Leg := InPrimitiveLOD * 4;
        end;
      case K of
        0:
          FMode.LegA[C, 3] := Byte(Leg);
        1:
          FMode.LegB[C, 3] := Byte(Leg);
        2:
          FMode.LegC[C, 3] := Byte(Leg);
      else
        FMode.LegD[C, 3] := Byte(Leg);
      end;
    end;
    // Blender mux selections.
    FMode.M1A[C] := Integer((FOtherLo shr (30 - C * 2)) and 3);
    FMode.M1B[C] := Integer((FOtherLo shr (26 - C * 2)) and 3);
    FMode.M2A[C] := Integer((FOtherLo shr (22 - C * 2)) and 3);
    FMode.M2B[C] := Integer((FOtherLo shr (18 - C * 2)) and 3);
  end;
  // Dither: the noise for the combiner and the alpha dither, then a seed
  // step for the RGB dither, per pixel.
  var AlphaMode := (FOtherHi shr 4) and 3;
  var RGBMode := (FOtherHi shr 6) and 3;
  FMode.NeedsNoise := (((FCombineHi shr 5) and 15) = 7) or (AlphaMode = 2);
  if Cycle = 1 then
    FMode.NeedsNoise := FMode.NeedsNoise or (((FCombineHi shr 20) and 15) = 7);
  FMode.RGBNoise := RGBMode = 2;
  FMode.AlphaNoise := AlphaMode = 2;
  FMode.PixelSteps := Ord(FMode.NeedsNoise) + Ord(FMode.RGBNoise);
  // Pixel's alpha compare; a fill returns before it.
  FMode.CompareStep := (Cycle <> 3) and ((FOtherLo and 3) = 3);
  for var Index := 0 to 15 do
  begin
    var Matrix := Magic[Index];
    if RGBMode in [1, 3] then
      Matrix := Bayer[Index];
    case AlphaMode of
      0:
        FMode.AlphaDither[Index] := Matrix;
      1:
        FMode.AlphaDither[Index] := Matrix xor 7;
    else
      FMode.AlphaDither[Index] := 0;
    end;
  end;
end;

procedure TN64RDP.Equations(Cycle: Integer; out E0, E1, E2, E3: Integer);
begin
  // (A - B) * C + D for the four lanes of one cycle, 17 bits each; bits
  // 8..16 are the result.
  E0 := ((Extend9(FIn.Flat[FMode.LegA[Cycle, 0]]) - Extend9(FIn.Flat[FMode.LegB[Cycle, 0]])) *
    Sign9(FIn.Flat[FMode.LegC[Cycle, 0]]) + Extend9(FIn.Flat[FMode.LegD[Cycle, 0]]) * 256 + 128) and $1FFFF;
  E1 := ((Extend9(FIn.Flat[FMode.LegA[Cycle, 1]]) - Extend9(FIn.Flat[FMode.LegB[Cycle, 1]])) *
    Sign9(FIn.Flat[FMode.LegC[Cycle, 1]]) + Extend9(FIn.Flat[FMode.LegD[Cycle, 1]]) * 256 + 128) and $1FFFF;
  E2 := ((Extend9(FIn.Flat[FMode.LegA[Cycle, 2]]) - Extend9(FIn.Flat[FMode.LegB[Cycle, 2]])) *
    Sign9(FIn.Flat[FMode.LegC[Cycle, 2]]) + Extend9(FIn.Flat[FMode.LegD[Cycle, 2]]) * 256 + 128) and $1FFFF;
  E3 := ((Extend9(FIn.Flat[FMode.LegA[Cycle, 3]]) - Extend9(FIn.Flat[FMode.LegB[Cycle, 3]])) *
    Sign9(FIn.Flat[FMode.LegC[Cycle, 3]]) + Extend9(FIn.Flat[FMode.LegD[Cycle, 3]]) * 256 + 128) and $1FFFF;
end;

function TN64RDP.Combine(Shade: Cardinal): Cardinal;
begin
  // The pixel's texels, shade, noise and LOD fraction are in FIn.
  FShadeAlpha := Min(255, Integer(Shade and $FF) + FAlphaDither);
  FKeyShade := FPixelKey;
  // Power-on combiner inputs select the one source on every mux leg.
  if not FHasCombine then
    Exit($FFFFFFFF);
  if FMode.FirstCycle = 0 then
  begin
    // The first of two cycles: its results are the second's combined inputs.
    var E0, E1, E2, E3: Integer;
    Equations(0, E0, E1, E2, E3);
    FIn.Flat[InCombined * 4] := E0 shr 8;
    FIn.Flat[InCombined * 4 + 1] := E1 shr 8;
    FIn.Flat[InCombined * 4 + 2] := E2 shr 8;
    FIn.Flat[InCombined * 4 + 3] := E3 shr 8;
  end;
  var Equation0, Equation1, Equation2, Equation3: Integer;
  Equations(1, Equation0, Equation1, Equation2, Equation3);
  var CombinedAlpha := Equation3 shr 8;
  if (FOtherHi and $100) <> 0 then
    // The A legs themselves.
    Result := (Cardinal(Clamp9(FIn.Flat[FMode.LegA[1, 0]])) shl 16) or
      (Cardinal(Clamp9(FIn.Flat[FMode.LegA[1, 1]])) shl 8) or Cardinal(Clamp9(FIn.Flat[FMode.LegA[1, 2]]))
  else
    Result := (Cardinal(Clamp9(Equation0 shr 8)) shl 16) or (Cardinal(Clamp9(Equation1 shr 8)) shl 8) or
      Cardinal(Clamp9(Equation2 shr 8));
  var FinalAlpha := Clamp9(CombinedAlpha);
  if ((FOtherHi and $100) <> 0) and ((FOtherLo and $2000) = 0) then
  begin
    FinalAlpha := 255;
    for var Channel := 0 to 2 do
    begin
      var Key: Integer;
      case Channel of
        0:
          Key := Equation0;
        1:
          Key := Equation1;
      else
        Key := Equation2;
      end;
      Key := (Key xor $10000) - $10000;
      if Key > 0 then
        if (Key and 15) = 8 then
          Key := -Key + 16
        else
          Key := -Key;
      FinalAlpha := Min(FinalAlpha, EnsureRange(FKeyWidth[Channel] * 16 + Key, 0, 255));
    end;
  end;
  Result := (Result shl 8) or Cardinal(FinalAlpha);
end;

procedure TN64RDP.LoadTLUTPipeline(Tile, SL, TL, SH: Integer);
const
  // A halfword times this: four copies of it.
  Replicate4: UInt64 = $0001000100010001;
begin
  // LoadTLUT as the loading pipeline takes it (angrylion's
  // loading_pipeline): a step per 8 (8-bit image), 1 (16-bit) or 2 (32-bit)
  // texels of the row, each reading the image's 8 bytes on from TIPtr and
  // writing the halfword at TIPtr four times (the whole doubleword where
  // TIPtr is odd) to the four TMEM banks at the tile's S (as the tile's
  // format lays texels out), which moves 64, 16 or 8 quarter texels a step.
  var Size := FTextureSize;
  var SpanAdvance := 8;
  var TIAdvance := 8;
  if Size = 2 then
  begin
    SpanAdvance := 1;
    TIAdvance := 2;
  end
  else if Size = 3 then
    SpanAdvance := 2;
  var Length := ((SH shr 2) - (SL shr 2) + 1) and $FFF;
  var TIPtr := FTextureAddress + Cardinal((FTextureWidth * (TL shr 2) + (SL shr 2)) shl Size) shr 1;
  var Step := 0;
  var J := 0;
  while J < Length do
  begin
    var SS := (Step * ($200 shr Size)) shr 3;
    var Shorts: Integer;
    if (FTiles[Tile].Size = 1) or (FTiles[Tile].Format = 1) then
      Shorts := SS shr 1
    else if FTiles[Tile].Size >= 2 then
      Shorts := SS
    else
      Shorts := SS shr 2;
    Shorts := Shorts and $7FF;
    var Flipped := (Shorts and 2) <> 0;
    var A := ((FTiles[Tile].TMEM shl 2) + Shorts) and $7FD;
    var High := (A and $400) <> 0;
    // Bank K's halfword (the one of A..A+3 that is K mod 4).
    var Banks: array[0..3] of Integer;
    for var K := 0 to 3 do
      Banks[((A + K) and $7FF) and 3] := ((A + K) and $7FF) and $3FF;
    var Words: array[0..3] of Cardinal;
    var Index := (TIPtr shr 2) and not Cardinal(1);
    for var K := 0 to 3 do
    begin
      var Address := ((Index + Cardinal(K)) shl 2) and $FFFFFF;
      if Address < $800000 then
        Words[K] := (Cardinal(MemRead8(Address)) shl 24) or (Cardinal(MemRead8(Address + 1)) shl 16) or
          (Cardinal(MemRead8(Address + 2)) shl 8) or MemRead8(Address + 3)
      else
        Words[K] := 0;
    end;
    var Q: UInt64;
    case TIPtr and 7 of
      0:
        Q := UInt64(Words[0] shr 16) * Replicate4;
      1:
        Q := (UInt64(Words[0]) shl 40) or (UInt64(Words[1]) shl 8) or (Words[2] shr 24);
      2:
        Q := UInt64(Words[0] and $FFFF) * Replicate4;
      3:
        Q := (UInt64(Words[0]) shl 56) or (UInt64(Words[1]) shl 24) or (Words[2] shr 8);
      4:
        Q := UInt64(Words[1] shr 16) * Replicate4;
      5:
        Q := (UInt64(Words[1]) shl 40) or (UInt64(Words[2]) shl 8) or (Words[3] shr 24);
      6:
        Q := UInt64(Words[1] and $FFFF) * Replicate4;
    else
      Q := (UInt64(Words[1]) shl 56) or (UInt64(Words[2]) shl 24) or (Words[3] shr 8);
    end;
    var Halves: array[0..3] of Word;
    var Targets: array[0..3] of Integer;
    if FTiles[Tile].Format = 1 then
    begin
      // YUV: the doubleword's even bytes to the low TMEM half, odd ones to
      // the high half.
      var V0 := Cardinal(((Q shr 56) and $FF) shl 24) or Cardinal(((Q shr 40) and $FF) shl 16) or
        Cardinal(((Q shr 24) and $FF) shl 8) or Cardinal((Q shr 8) and $FF);
      var V1 := Cardinal(((Q shr 48) and $FF) shl 24) or Cardinal(((Q shr 32) and $FF) shl 16) or
        Cardinal(((Q shr 16) and $FF) shl 8) or Cardinal(Q and $FF);
      var B0 := 0;
      if Flipped then
        B0 := 2;
      Targets[0] := Banks[B0];
      Targets[1] := Banks[B0 + 1];
      Targets[2] := Banks[B0] or $400;
      Targets[3] := Banks[B0 + 1] or $400;
      Halves[0] := V0 shr 16;
      Halves[1] := V0 and $FFFF;
      Halves[2] := V1 shr 16;
      Halves[3] := V1 and $FFFF;
    end
    else if (FTiles[Tile].Format = 0) and (FTiles[Tile].Size = 3) then
    begin
      // RGBA32: each texel's high halfword to the low TMEM half, its low
      // halfword to the high half.
      var B0 := 0;
      if Flipped then
        B0 := 2;
      Targets[0] := Banks[B0];
      Targets[1] := Banks[B0 + 1];
      Targets[2] := Banks[B0] or $400;
      Targets[3] := Banks[B0 + 1] or $400;
      Halves[0] := Q shr 48;
      Halves[1] := (Q shr 16) and $FFFF;
      Halves[2] := (Q shr 32) and $FFFF;
      Halves[3] := Q and $FFFF;
    end
    else
    begin
      for var K := 0 to 3 do
      begin
        Targets[K] := Banks[K];
        if High then
          Targets[K] := Targets[K] or $400;
      end;
      Halves[0] := Q shr 48;
      Halves[1] := (Q shr 32) and $FFFF;
      Halves[2] := (Q shr 16) and $FFFF;
      Halves[3] := Q and $FFFF;
    end;
    for var K := 0 to 3 do
    begin
      FTMEM[Targets[K] * 2] := Byte(Halves[K] shr 8);
      FTMEM[Targets[K] * 2 + 1] := Byte(Halves[K]);
    end;
    Inc(TIPtr, TIAdvance);
    Inc(Step);
    Inc(J, SpanAdvance);
  end;
end;

procedure TN64RDP.LoadTexture(Tile, SL, TL, SH, TH: Integer; Block: Boolean);
begin
  if FTextureSize = 0 then
  begin
    FPipelineCrashed := True;
    Exit
  end;
  var R := FTiles[Tile];
  var Bits := 4 shl FTextureSize;
  var Width := ((SH div 4) - (SL div 4) + 1) and $FFF;
  var Height := Max(0, (TH div 4) - (TL div 4) + 1);
  if Block then
  begin
    Width := (SH - SL + 1) and $FFF;
    Height := 1
  end;
  var Bytes := ((Width * Bits + 7) div 8 + 7) and not 7;
  Inc(FWorkClocks, Cardinal(((Int64(Bytes) * Min(Height, 1024)) + 7) div 8));
  var SourceS := SL div 4;
  var SourceT := TL div 4;
  if Block then
  begin
    SourceS := SL;
    SourceT := TL
  end;
  // TMEM layout: linear, RGBA32 split into low/high halves, or YUV16 split.
  var Layout := 0;
  if (R.Format = 0) and (R.Size = 3) then
    Layout := 1
  else if (R.Format = 1) and (FTextureSize = 2) then
    Layout := 2;
  var Count := Min(Bytes, 16384);
  var Rows := Min(Height, 1024);
  if FTimingOnly then
  begin
    TimingLoad(SourceS, SourceT, Bits, Rows, Count);
    Exit;
  end;
  // With a timing RDP feeding this one, the source bytes may come with the
  // command words instead of from RDRAM (see TimingLoad).
  var Payload := Assigned(FOnDataIn) and (FOnDataIn() <> 0);
  FDataBytes := 0;
  if not Payload and not ReadsRDRAM then
    Exit;
  for var Y := 0 to Rows - 1 do
  begin
    // All terms are non-negative and far below 2^31. Bytes from $800000 on
    // are not loaded; the rest of the row is a prefix of Valid bytes.
    var RowSource := UInt64(FTextureAddress) + Cardinal(((SourceT + Y) * FTextureWidth + SourceS) * Bits div 8);
    var Valid := 0;
    if RowSource < $800000 then
      Valid := Integer(Min(UInt64(Count), $800000 - RowSource));
    var Base := R.TMEM * 8 + Y * R.Line * 8;
    var Direct := RowSource + Cardinal(Valid) <= FBus.RAMSize;
    // Odd rows swap 32-bit words; LoadBlock derives the row from dxt.
    var RowSwap := 0;
    if not Block and Odd(Y) then
      RowSwap := 4;
    {$IF Defined(CPU64BITS)}
    if (Layout <= 1) and ((Valid and 3) = 0) and ((Payload and (FDataBytes = 0)) or (not Payload and Direct)) then
    begin
      // A word (four bytes) at a time, where the loop below would put them:
      // with X a multiple of 4 (Base one of 8), bytes X..X + 3 go to Target
      // .. Target + 3 (Layout 0), or X, X + 1 to Target, Target + 1 and X + 2,
      // X + 3 to the same in the upper half (Layout 1); the swap is the same
      // for the four.
      var X := 0;
      while X < Valid do
      begin
        var W: Cardinal;
        if Payload then
          W := FOnDataIn()
        else
          W := FBus.RDPRead32(Cardinal(RowSource) + Cardinal(X));
        var Target: Integer;
        if Layout = 0 then
          Target := (Base + X) and $FFF
        else
          Target := (Base + X div 2) and $7FF;
        if Block then
        begin
          if Odd((X div 8 * TH) div 2048) then
            Target := Target xor 4;
        end
        else
          Target := Target xor RowSwap;
        FTMEM[Target] := Byte(W shr 24);
        FTMEM[Target + 1] := Byte(W shr 16);
        if Layout = 0 then
        begin
          FTMEM[Target + 2] := Byte(W shr 8);
          FTMEM[Target + 3] := Byte(W);
        end
        else
        begin
          FTMEM[Target or $800] := Byte(W shr 8);
          FTMEM[(Target + 1) or $800] := Byte(W);
        end;
        Inc(X, 4);
      end;
      // (As NextDataByte leaves it after whole words.)
      if Payload and (Valid > 0) then
        FDataWord := 0;
      Continue;
    end;
    {$ENDIF}
    for var X := 0 to Valid - 1 do
    begin
      var Target: Integer;
      case Layout of
        0:
          Target := (Base + X) and $FFF;
        1:
          Target := ((Base + X div 4 * 2 + X mod 2) and $7FF) or ((X div 2 and 1) * $800);
      else
        Target := ((Base + X div 2) and $7FF) or ((X and 1) * $800);
      end;
      if Block then
      begin
        if Odd((X div 8 * TH) div 2048) then
          Target := Target xor 4;
      end
      else
        Target := Target xor RowSwap;
      if Payload then
        FTMEM[Target] := NextDataByte
      else if Direct then
        FTMEM[Target] := FBus.RDPRead8(Cardinal(RowSource) + Cardinal(X))
      else
        FTMEM[Target] := MemRead8(Cardinal(RowSource + Cardinal(X)));
    end;
  end;
end;

procedure TN64RDP.TimingLoad(SourceS, SourceT, Bits, Rows, Count: Integer);
begin
  // The full RDP reads Valid bytes from each row's RowSource. When no queued
  // list may write them and they are few, they travel with the command words
  // (flag 1, then the bytes), so the RDRAM pages stay free for the CPU.
  // Otherwise (flag 0) the full RDP reads RDRAM itself, in order with its own
  // writes, and the pages are marked as read.
  if FClocksOnly then
    Exit;
  var Total := 0;
  var Hazard := False;
  for var Y := 0 to Rows - 1 do
  begin
    var RowSource := UInt64(FTextureAddress) + Cardinal(((SourceT + Y) * FTextureWidth + SourceS) * Bits div 8);
    if RowSource < $800000 then
    begin
      var Valid := Integer(Min(UInt64(Count), $800000 - RowSource));
      Inc(Total, Valid);
      if (Valid > 0) and FBus.RDPWriteHazard(Cardinal(RowSource), Cardinal(Valid)) then
        Hazard := True;
    end;
  end;
  var Payload := Assigned(FOnDataOut) and not Hazard and (Total <= MaxDataBytes);
  if Payload then
    Inc(FLoadStats[0])
  else if not Assigned(FOnDataOut) then
    Inc(FLoadStats[3])
  else if Hazard then
    Inc(FLoadStats[1])
  else
    Inc(FLoadStats[2]);
  if Assigned(FOnDataOut) then
    FOnDataOut(Ord(Payload));
  for var Y := 0 to Rows - 1 do
  begin
    var RowSource := UInt64(FTextureAddress) + Cardinal(((SourceT + Y) * FTextureWidth + SourceS) * Bits div 8);
    if RowSource >= $800000 then
      Continue;
    var Valid := Integer(Min(UInt64(Count), $800000 - RowSource));
    if not Payload then
    begin
      FBus.MarkRDPRead(Cardinal(RowSource), Cardinal(Valid));
      Continue;
    end;
    // Whole words where the packing is word-aligned, bytes elsewhere.
    var X := 0;
    while (X < Valid) and (FDataBytes <> 0) do
    begin
      PutDataByte(FBus.RDPRead8(Cardinal(RowSource) + Cardinal(X)));
      Inc(X);
    end;
    while X + 4 <= Valid do
    begin
      FOnDataOut(FBus.RDPRead32(Cardinal(RowSource) + Cardinal(X)));
      Inc(X, 4);
    end;
    while X < Valid do
    begin
      PutDataByte(FBus.RDPRead8(Cardinal(RowSource) + Cardinal(X)));
      Inc(X);
    end;
  end;
  if Payload then
    EndData;
end;

procedure TN64RDP.PutDataByte(Value: Byte);
begin
  // Four bytes per word, first byte in the high bits.
  FDataWord := Cardinal(((UInt64(FDataWord) shl 8) or Value) and $FFFFFFFF);
  Inc(FDataBytes);
  if FDataBytes = 4 then
  begin
    FOnDataOut(FDataWord);
    FDataWord := 0;
    FDataBytes := 0;
  end;
end;

procedure TN64RDP.EndData;
begin
  if FDataBytes > 0 then
    FOnDataOut(Cardinal((UInt64(FDataWord) shl (8 * (4 - FDataBytes))) and $FFFFFFFF));
  FDataWord := 0;
  FDataBytes := 0;
end;

function TN64RDP.NextDataByte: Byte;
begin
  if FDataBytes = 0 then
  begin
    FDataWord := FOnDataIn();
    FDataBytes := 4;
  end;
  Result := Byte(FDataWord shr 24);
  FDataWord := Cardinal((UInt64(FDataWord) shl 8) and $FFFFFFFF);
  Dec(FDataBytes);
end;

const
  XOffset: array[0..15] of Byte = (0, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0);
  YOffset: array[0..15] of Byte = (0, 0, 1, 0, 2, 0, 1, 0, 3, 0, 1, 0, 2, 0, 1, 0);
  ReciprocalPoint: array[0..63] of Integer =
    ($4000, $3F04, $3E10, $3D22, $3C3C, $3B5D, $3A83, $39B1, $38E4, $381C, $375A, $369D, $35E5, $3532, $3483, $33D9,
    $3333, $3291, $31F4, $3159, $30C3, $3030, $2FA1, $2F15, $2E8C, $2E06, $2D83, $2D03, $2C86, $2C0B, $2B93, $2B1E,
    $2AAB, $2A3A, $29CC, $2960, $28F6, $288E, $2828, $27C4, $2762, $2702, $26A4, $2648, $25ED, $2594, $253D, $24E7,
    $2492, $243F, $23EE, $239E, $234F, $2302, $22B6, $226C, $2222, $21DA, $2193, $214D, $2108, $20C5, $2082, $2041);
  ReciprocalSlope: array[0..63] of Integer =
    ($F03, $F0B, $F11, $F19, $F20, $F25, $F2D, $F32, $F37, $F3D, $F42, $F47, $F4C, $F50, $F55, $F59,
    $F5D, $F62, $F64, $F69, $F6C, $F70, $F73, $F76, $F79, $F7C, $F7F, $F82, $F84, $F87, $F8A, $F8C,
    $F8E, $F91, $F93, $F95, $F97, $F99, $F9B, $F9D, $F9F, $FA1, $FA3, $FA4, $FA6, $FA8, $FA9, $FAA,
    $FAC, $FAE, $FAF, $FB0, $FB2, $FB3, $FB5, $FB5, $FB7, $FB8, $FB9, $FBA, $FBC, $FBC, $FBE, $FBE);

function TN64RDP.Coefficient(Base, Group, Channel: Integer): Int64;
begin
  var Index := Channel div 2;
  var Shift := 16 * (1 - (Channel and 1));
  var Hi := (FCommand[Base + Group + Index] shr Shift) and $FFFF;
  var Lo := (FCommand[Base + Group + Index + 4] shr Shift) and $FFFF;
  Result := SignedValue(SX((Hi shl 16) or Lo, 32));
end;

function TN64RDP.EdgeQuantise(Value: Int64): Integer;
begin
  // Sticky bit retains all discarded fractional bits in the eighth-pixel edge.
  var Raw := Cardinal(Value and $FFFFFFFF);
  var Sticky := Ord(((Raw shr 1) and $1FFF) <> 0);
  Result := Integer((Raw shr 13) and $1FFE) or Sticky;
  if ((Raw and $08000000) <> 0) or ((Result < FScissorQuarterX0 * 2) and ((Raw and $04000000) = 0)) then
    Exit(FScissorQuarterX0 * 2);
  Result := Integer((Raw shr 13) and $3FFE) or Sticky;
  if ((Result and $2000) <> 0) or ((Result and $1FFF) >= FScissorQuarterX1 * 2) then
    Result := FScissorQuarterX1 * 2;
  Result := Result and $1FFF;
end;

procedure InitPerspective;
begin
  // Same reciprocal ROM interpolation as TextureDivide, once per W instead
  // of several times for each pixel. These tables are immutable host data.
  for var SW := 1 to 32767 do
  begin
    var Shift := 14;
    var Bits := SW;
    while Bits >= 2 do
    begin
      Bits := Bits shr 1;
      Dec(Shift);
    end;
    var Normal := (SW shl Shift) and $3FFF;
    var Slope := (ReciprocalSlope[Normal shr 8] and $3FF) - 1023;
    var Value := Integer(ShiftRight(Int64(Slope) * ((Normal and $FF) shl 2), 10)) + ReciprocalPoint[Normal shr 8];
    TN64RDP.PerspectiveReciprocal[SW] := Word(Value and $7FFF);
    TN64RDP.PerspectiveShift[SW] := Byte(Shift);
  end;
end;

function TN64RDP.TextureDivide(Coordinate, W: Int64): Integer;
begin
  // Only bits 16..31 participate: sign extension of the discarded upper
  // bits is unnecessary. The reciprocal is a pure function of the 15-bit W.
  {$IF Defined(CPU64BITS)}
  // In 32 bits: |SS| <= 2^15 and the reciprocal < 2^15, so the product and
  // its double fit.
  var SS := Integer(SmallInt(Word(Cardinal(Coordinate) shr 16)));
  if (FOtherHi and $80000) = 0 then
    Exit(SS);
  var SW := Integer((Cardinal(W) shr 16) and $FFFF);
  if (SW = 0) or ((SW and $8000) <> 0) then
    Exit(32767);
  var Product := SS * Integer(PerspectiveReciprocal[SW]);
  var Shift := Integer(PerspectiveShift[SW]);
  var V: Integer;
  if Shift = 14 then
    V := Product * 2
  else if Product >= 0 then
    V := Product shr (13 - Shift)
  else
    V := not ((not Product) shr (13 - Shift));
  if V > 32767 then
    Result := 32767
  else if V < -32768 then
    Result := -32768
  else
    Result := V;
  {$ELSE}
  var SS := Int64(SmallInt(Word((Coordinate shr 16) and $FFFF)));
  if (FOtherHi and $80000) = 0 then
    Exit(Integer(SS));
  var SW := Integer((W shr 16) and $FFFF);
  if (SW = 0) or ((SW and $8000) <> 0) then
    Exit(32767);
  var Reciprocal := Integer(PerspectiveReciprocal[SW]);
  var Shift := Integer(PerspectiveShift[SW]);
  var Product := SS * Reciprocal;
  var V := Product * 2;
  if Shift <> 14 then
    V := ShiftRight(Product, 13 - Shift);
  {$IF Defined(CPU64BITS)}
  if V > 32767 then
    Result := 32767
  else if V < -32768 then
    Result := -32768
  else
    Result := Integer(V);
  {$ELSE}
  Result := Integer(EnsureRange(V, Int64(-32768), Int64(32767)));
  {$ENDIF}
  {$ENDIF}
end;

procedure TN64RDP.RowAddresses(Y: Integer);
begin
  // The pixels of row Y (0..1023, of the drawn field) that the scissor, the
  // 1024 x 1024 raster and the end of RDRAM leave: X = FRowFirst..FRowLast.
  // Everything that decides whether a pixel costs work clocks is here (and
  // in CountRow, which must agree).
  FRowBPP := ColorBytes;
  FRowFirst := 1;
  FRowLast := 0;
  FRowBase := 0;
  var Room := Int64($800000) - FRowBPP - Int64(FColorAddress);
  if (Y < FScissorY0) or (Y >= FScissorY1) or (Room < 0) then
    Exit;
  FRowFirst := Max(FScissorX0, 0);
  FRowLast := Integer(Min(Int64(Min(FScissorX1 - 1, 1023)), Room div FRowBPP - Int64(Y) * FColorWidth));
  FRowBase := Cardinal(UInt64(FColorAddress) + Cardinal(Y * FColorWidth * FRowBPP));
end;

function TN64RDP.RowSpan(Y: Integer; out Left, Right: Integer): Boolean;
begin
  // Whether RasterRow draws row Y, of pixels X = Left..Right (0..1023).
  Result := False;
  Left := 1024;
  Right := 0;
  if FPipelineCrashed then
    Exit;
  for var Q := 0 to 3 do
    if not FPrim.Invalid[Q] then
    begin
      Left := Min(Left, Min(FPrim.Major[Q], FPrim.Minor[Q]) div 8);
      Right := Max(Right, Max(FPrim.Major[Q], FPrim.Minor[Q]) div 8);
    end;
  if (Y < 0) or (Y >= 1024) or (Left > Right) or (Left >= 1024) or (Right < 0) then
    Exit;
  if FScissorField and (Odd(Y) <> FScissorOdd) then
    Exit;
  Left := Max(Left, 0);
  Right := Min(Right, 1023);
  Result := True;
end;

procedure TN64RDP.RowEdges(out EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: TN64Quarters);
begin
  // Per-quarter span edges are constant along the row.
  for var Q := 0 to 3 do
    if not FPrim.Invalid[Q] then
    begin
      var Lo := FPrim.Minor[Q];
      var Hi := FPrim.Major[Q];
      if FPrim.Flip then
      begin
        Lo := FPrim.Major[Q];
        Hi := FPrim.Minor[Q]
      end;
      EdgeLo[Q] := Lo div 8;
      EdgeHi[Q] := Hi div 8;
      LoMask[Q] := $F shr (((Lo and 7) + 1) shr 1);
      HiMask[Q] := $F0 shr (((Hi and 7) + 1) shr 1);
      QuarterMask[Q] := $A shr (Q and 1);
    end;
end;

procedure TN64RDP.CarryRow(Y: Integer);
begin
  // Before a band draws a primitive whose rows hand the memory colour on:
  // whether a pixel of this band's row Y reads memory, and what the last one
  // (in drawing order) reads, as it is before the primitive. Pixel reads
  // memory for each pixel RasterRow hands to RasterPixel within
  // FRowFirst..FRowLast, and no other pixel of the primitive writes it.
  if (Y < 0) or (Y > 1023) or not OwnsRow(Y) then
    Exit;
  var Valid := False;
  var Color: Cardinal := 0;
  var Coverage := 0;
  var Left, Right: Integer;
  if RowSpan(Y, Left, Right) then
  begin
    var EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: TN64Quarters;
    RowEdges(EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask);
    RowAddresses(Y);
    var Lo := Max(Left, FRowFirst);
    var Hi := Min(Right, FRowLast);
    var First, Last: Integer;
    if (Lo <= Hi) and (CoveredPixels(Lo, Hi, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask, First, Last) > 0) then
    begin
      var X := First;
      if FPrim.Flip then
        X := Last;
      Coverage := 7;
      ReadMemoryState(FRowBase + Cardinal(X * FRowBPP), Color, Coverage);
      Valid := True;
    end;
  end;
  FGroup.SetCarry(FCarrySeq, Y, Valid, Color, Coverage);
end;

procedure TN64RDP.LoadCarry(Y: Integer);
begin
  // Before the first pixel of row Y of such a primitive (one of this band's):
  // the memory colour the pixel before it left, unless this band drew that
  // one. That is the last of an earlier row with one that reads memory, or
  // the latest before the primitive.
  if not FGroup.CarryValid(FCarrySeq, Y) then
    Exit;
  var P := Y - 1;
  while (P >= FCarryFirst) and not FGroup.CarryValid(FCarrySeq, P) do
    Dec(P);
  if P < FCarryFirst then
  begin
    FMemoryColor := FCarryColor;
    FMemoryCoverage := FCarryCoverage;
  end
  else if ((P shr BandRowShift) mod FBands) <> FBand then
    FGroup.GetCarry(FCarrySeq, P, FMemoryColor, FMemoryCoverage);
end;

procedure TN64RDP.RasterRow(Y: Integer);
begin
  var Left, Right: Integer;
  if not RowSpan(Y, Left, Right) then
    Exit;
  var StartX := Right;
  var EndX := Left;
  var Step := -1;
  if FPrim.Flip then
  begin
    StartX := Left;
    EndX := Right;
    Step := 1
  end;
  var X := StartX;
  FDelayedHidden := -1;
  FRowMinX := 1024;
  FRowMaxX := -1;
  var EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask: TN64Quarters;
  RowEdges(EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask);
  if FTimingOnly then
    CountRow(Y, Left, Right, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask)
  else if OwnsRow(Y) then
  begin
    FRowKey := (FPrimSeq shl 21) or (UInt64(1) shl 20) or (UInt64(Y) shl 10);
    FPixelKey := FRowKey;
    if FCarryPrim then
      LoadCarry(Y);
    RowAddresses(Y);
    // Strictly inside the span of every quarter line that has one, the mask
    // is the same.
    var InnerLo := -1;
    var InnerHi := 1024;
    var InnerMask := 0;
    for var Q := 0 to 3 do
      if not FPrim.Invalid[Q] and (EdgeLo[Q] <= EdgeHi[Q]) then
      begin
        InnerLo := Max(InnerLo, EdgeLo[Q]);
        InnerHi := Min(InnerHi, EdgeHi[Q]);
        InnerMask := InnerMask or (QuarterMask[Q] shl ((Q - 2) and 4));
      end;
    while True do
    begin
      var Mask := InnerMask;
      if (X <= InnerLo) or (X >= InnerHi) then
      begin
        Mask := 0;
        for var Q := 0 to 3 do
          if not FPrim.Invalid[Q] and (X >= EdgeLo[Q]) and (X <= EdgeHi[Q]) then
          begin
            var RowMask := QuarterMask[Q];
            if X = EdgeLo[Q] then
              RowMask := RowMask and LoMask[Q];
            if X = EdgeHi[Q] then
              RowMask := RowMask and HiMask[Q];
            Mask := Mask or (RowMask shl ((Q - 2) and 4));
          end;
      end;
      var Coverage := Integer(PopCount8[Mask and $FF]);
      if (Coverage <> 0) or (FPrim.Cycle >= 2) then
        RasterPixel(X, Y, Mask, Coverage, Step);
      if X = EndX then
        Break;
      Inc(X, Step);
    end;
  end
  else if not FSerialPrim and ((FMode.PixelSteps > 0) or FMode.CompareStep) then
    SkipRow(Y, Left, Right, EdgeLo, EdgeHi, LoMask, HiMask, QuarterMask);
  if FTimingOnly and (FRowMinX <= FRowMaxX) then
    MarkRow(Y);
  CompleteDelayedHidden;
  if (FPrim.Cycle = 3) and ((FOtherLo and $20) <> 0) and ((FOtherLo and 4) = 0) then
    FPipelineCrashed := True;
end;

procedure TN64RDP.RasterPixel(X, Y, Mask, Coverage, Step: Integer);
const
  NoTexel: TN64Texel = (C: (0, 0, 0, 0));
begin
  // FLODFraction and FAlphaDither (Dither) are set for every pixel.
  FKeyRaster := FPixelKey;
  if FPrim.Cycle >= 2 then
    Coverage := 8;
  var OffX := 0;
  var OffY := 0;
  if Coverage <> 8 then
  begin
    var Expanded := (Mask and 5) or ((Mask and $5A) shl 4) or ((Mask and $A0) shl 8);
    var YMask := 0;
    for var Q := 0 to 3 do
      if (Expanded and ($F000 shr (Q * 4))) <> 0 then
        YMask := YMask or (1 shl Q);
    OffY := YOffset[YMask];
    OffX := XOffset[(Expanded shr ((OffY xor 3) * 4)) and 15];
  end;
  // Only the attribute groups present in this primitive are ever read.
  var Attributes: array[0..7] of Int64;
  var SpanX := X - FPrim.UnscrX;
  {$IF Defined(CPU64BITS)}
  // Unrolled. A shade lane's nine bits are bits of its attribute (with the
  // offsets' products below full coverage, modulo 2^32): the floor shifts
  // and the 9-bit mask below are bit extraction.
  var Shade: Cardinal := 0;
  if (FPrim.Code and 4) <> 0 then
  begin
    var A0 := Cardinal(FPrim.SpanAttribute[0] + FPrim.Coeff[1, 0] * SpanX);
    var A1 := Cardinal(FPrim.SpanAttribute[1] + FPrim.Coeff[1, 1] * SpanX);
    var A2 := Cardinal(FPrim.SpanAttribute[2] + FPrim.Coeff[1, 2] * SpanX);
    var A3 := Cardinal(FPrim.SpanAttribute[3] + FPrim.Coeff[1, 3] * SpanX);
    Attributes[0] := Integer(A0);
    Attributes[1] := Integer(A1);
    Attributes[2] := Integer(A2);
    Attributes[3] := Integer(A3);
    if Coverage = 8 then
      Shade := (Cardinal(Clamp9(Integer((A0 shr 16) and $1FF))) shl 24) or
        (Cardinal(Clamp9(Integer((A1 shr 16) and $1FF))) shl 16) or
        (Cardinal(Clamp9(Integer((A2 shr 16) and $1FF))) shl 8) or Cardinal(Clamp9(Integer((A3 shr 16) and $1FF)))
    else
    begin
      A0 := ((A0 shr 14) shl 2) + Cardinal(OffX * FPrim.ShadeDX[0] + OffY * FPrim.ShadeDY[0]);
      A1 := ((A1 shr 14) shl 2) + Cardinal(OffX * FPrim.ShadeDX[1] + OffY * FPrim.ShadeDY[1]);
      A2 := ((A2 shr 14) shl 2) + Cardinal(OffX * FPrim.ShadeDX[2] + OffY * FPrim.ShadeDY[2]);
      A3 := ((A3 shr 14) shl 2) + Cardinal(OffX * FPrim.ShadeDX[3] + OffY * FPrim.ShadeDY[3]);
      Shade := (Cardinal(Clamp9(Integer((A0 shr 4) and $1FF))) shl 24) or
        (Cardinal(Clamp9(Integer((A1 shr 4) and $1FF))) shl 16) or
        (Cardinal(Clamp9(Integer((A2 shr 4) and $1FF))) shl 8) or Cardinal(Clamp9(Integer((A3 shr 4) and $1FF)));
    end;
  end;
  if (FPrim.Code and 2) <> 0 then
  begin
    Attributes[4] := Integer(Cardinal(FPrim.SpanAttribute[4] + FPrim.Coeff[1, 4] * SpanX));
    Attributes[5] := Integer(Cardinal(FPrim.SpanAttribute[5] + FPrim.Coeff[1, 5] * SpanX));
    Attributes[6] := Integer(Cardinal(FPrim.SpanAttribute[6] + FPrim.Coeff[1, 6] * SpanX));
  end;
  if (FPrim.Code and 1) <> 0 then
    Attributes[7] := Integer(Cardinal(FPrim.SpanAttribute[7] + FPrim.Coeff[1, 7] * SpanX));
  {$ELSE}
  if (FPrim.Code and 4) <> 0 then
    for var I := 0 to 3 do
      Attributes[I] := WrapSigned32(FPrim.SpanAttribute[I] + FPrim.Coeff[1, I] * SpanX);
  if (FPrim.Code and 2) <> 0 then
    for var I := 4 to 6 do
      Attributes[I] := WrapSigned32(FPrim.SpanAttribute[I] + FPrim.Coeff[1, I] * SpanX);
  if (FPrim.Code and 1) <> 0 then
    Attributes[7] := WrapSigned32(FPrim.SpanAttribute[7] + FPrim.Coeff[1, 7] * SpanX);
  var Shade: Cardinal := 0;
  if (FPrim.Code and 4) <> 0 then
  begin
    Shade := 0;
    for var I := 0 to 3 do
    begin
      var V := ShiftRight(Attributes[I], 14);
      if Coverage = 8 then
        V := ShiftRight(V, 2)
      else
        V := ShiftRight(V * 4 + OffX * FPrim.ShadeDX[I] + OffY * FPrim.ShadeDY[I], 4);
      Shade := (Shade shl 8) or Cardinal(Clamp9(Integer(V and $1FF)));
    end;
  end;
  {$ENDIF}
  // Without texture the combiner's texels are the shade (DecodeMode), and
  // so is a copied pixel.
  FLODFraction := 0;
  if (FPrim.Code and 2) <> 0 then
  begin
    // TextureDivide and Texture(.., 0, Default) are pure within a
    // primitive. The previous pixel's look-ahead (NextS/NextT and
    // TexelNext) usually equals this pixel's sample: reuse it on a
    // match of all arguments.
    var S, T: Integer;
    if FPrim.MemoValid and (Attributes[4] = FPrim.MemoNextSA) and (Attributes[6] = FPrim.MemoNextW) then
      S := FPrim.MemoNextS
    else
      S := TextureDivide(Attributes[4], Attributes[6]);
    if FPrim.MemoValid and (Attributes[5] = FPrim.MemoNextTA) and (Attributes[6] = FPrim.MemoNextW) then
      T := FPrim.MemoNextT
    else
      T := TextureDivide(Attributes[5], Attributes[6]);
    FPrim.MemoNextSA := WrapSigned32(Attributes[4] + FPrim.Coeff[1, 4] * Step);
    FPrim.MemoNextTA := WrapSigned32(Attributes[5] + FPrim.Coeff[1, 5] * Step);
    FPrim.MemoNextW := WrapSigned32(Attributes[6] + FPrim.Coeff[1, 6] * Step);
    var NextS := TextureDivide(FPrim.MemoNextSA, FPrim.MemoNextW);
    var NextT := TextureDivide(FPrim.MemoNextTA, FPrim.MemoNextW);
    FPrim.MemoNextS := NextS;
    FPrim.MemoNextT := NextT;
    FPrim.MemoValid := True;
    var Lod := Max(Abs(NextS - S), Abs(NextT - T));
    var NextYS := TextureDivide(WrapSigned32(Attributes[4] + (FPrim.Coeff[3, 4] and not Int64($7FFF))),
      WrapSigned32(Attributes[6] + (FPrim.Coeff[3, 6] and not Int64($7FFF))));
    var NextYT := TextureDivide(WrapSigned32(Attributes[5] + (FPrim.Coeff[3, 5] and not Int64($7FFF))),
      WrapSigned32(Attributes[6] + (FPrim.Coeff[3, 6] and not Int64($7FFF))));
    Lod := Max(Lod, Max(Abs(NextYS - S), Abs(NextYT - T)));
    var Level := 0;
    var Magnify := Lod < 32;
    Lod := Max(Lod, FMinLevel);
    while (Level < 7) and (Lod >= (64 shl Level)) do
      Inc(Level);
    var Distant := (Level >= FPrim.MaxLevel) or (Lod >= $4000);
    if Lod < 32 then
      FLODFraction := Lod * 8
    else
      FLODFraction := ((Lod shl 3) shr Level) and $FF;
    if ((FOtherHi and $60000) = 0) then
      if Distant then
        FLODFraction := 255
      else if Magnify then
        FLODFraction := 0;
    if ((FOtherHi and $40000) <> 0) and Magnify then
      FLODFraction := FLODFraction or $100;
    Level := Min(Level, FPrim.MaxLevel);
    // With LOD disabled, one-cycle lookahead keeps the primitive tile;
    // two-cycle TEXEL1 reads the adjacent tile. LOD may replace either.
    var Tile0 := FPrim.Tile;
    var Tile1 := FPrim.Tile;
    if FPrim.Cycle = 1 then
      Tile1 := (FPrim.Tile + 1) and 7;
    if (FOtherHi and $10000) <> 0 then
    begin
      Tile0 := (FPrim.Tile + Level) and 7;
      Tile1 := (Tile0 + 1) and 7;
      if (FOtherHi and $20000) <> 0 then
      begin
        if not Magnify then
          Tile0 := (Tile0 + 1) and 7;
        if Distant then
          Tile1 := Tile0
        else
          Tile1 := (Tile0 + 1) and 7;
      end
      else if Distant or (Magnify and ((FOtherHi and $40000) = 0)) then
        Tile1 := Tile0;
    end;
    // Texture lookups are pure. One-cycle mode replaces TEXEL1 with the
    // next pixel's texel; copy/fill modes read only TEXEL0.
    if FPrim.MemoTexelValid and (Tile0 = FPrim.MemoTile) and (S = FPrim.MemoTexelS) and (T = FPrim.MemoTexelT) then
      FIn.Slots[InTexel] := FPrim.MemoTexel
    else
      FIn.Slots[InTexel] := Texture(Tile0, S, T, 0, NoTexel);
    FPrim.MemoTexelValid := False;
    if FPrim.Cycle = 1 then
      FIn.Slots[InTexel1] := Texture(Tile1, S, T, 1, FIn.Slots[InTexel]);
    if FPrim.Cycle <= 1 then
    begin
      FIn.Slots[InTexelNext] := Texture(Tile0, NextS, NextT, 0, NoTexel);
      // Lane by lane: copying the whole texel right after its lanes were
      // stored one by one would stall on store forwarding.
      {$IF Defined(CPU64BITS)}
      FPrim.MemoTexel.C[0] := FIn.Slots[InTexelNext].C[0];
      FPrim.MemoTexel.C[1] := FIn.Slots[InTexelNext].C[1];
      FPrim.MemoTexel.C[2] := FIn.Slots[InTexelNext].C[2];
      FPrim.MemoTexel.C[3] := FIn.Slots[InTexelNext].C[3];
      {$ELSE}
      for var I := 0 to 3 do
        FPrim.MemoTexel.C[I] := FIn.Slots[InTexelNext].C[I];
      {$ENDIF}
      FPrim.MemoTile := Tile0;
      FPrim.MemoTexelS := NextS;
      FPrim.MemoTexelT := NextT;
      FPrim.MemoTexelValid := True;
    end;
    if not FHasCombine then
      Shade := TexelToRGBA(FIn.Slots[InTexel]);
  end;
  var Depth := -1;
  var Delta: Cardinal := 1;
  if (FPrim.Code and 1) <> 0 then
  begin
    var Z := ShiftRight(Attributes[7], 10) and $3FFFFF;
    if Coverage = 8 then
      Z := ShiftRight(Z, 3)
    else
      Z := ShiftRight(Z * 4 + OffX * FPrim.DepthDX + OffY * FPrim.DepthDY, 5);
    case (Z and $60000) shr 17 of
      2:
        Depth := $3FFFF;
      3:
        Depth := 0
    else
      Depth := Integer(Z and $3FFFF)
    end;
    Delta := FPrim.DepthDelta;
  end;
  Dither(X, Y);
  if FPrim.Cycle = 3 then
    Pixel(X, Y, FFill, True)
  else if FPrim.Cycle = 2 then
  begin
    if (FPrim.Code and 2) <> 0 then
      Shade := TexelToRGBA(FIn.Slots[InTexel]);
    Pixel(X, Y, Shade, False, -1, 1, 8, True);
  end
  else
  begin
    if FHasCombine then
    begin
      {$IF Defined(CPU64BITS)}
      FIn.Slots[InShade].C[0] := Integer(Shade shr 24);
      FIn.Slots[InShade].C[1] := Integer((Shade shr 16) and $FF);
      FIn.Slots[InShade].C[2] := Integer((Shade shr 8) and $FF);
      FIn.Slots[InShade].C[3] := Integer(Shade and $FF);
      {$ELSE}
      for var I := 0 to 3 do
        FIn.Slots[InShade].C[I] := Integer((Shade shr (24 - I * 8)) and $FF);
      {$ENDIF}
    end;
    FIn.Slots[InNoise].C[0] := Integer(FNoise);
    FIn.Slots[InLOD].C[0] := FLODFraction;
    Pixel(X, Y, Combine(Shade), False, Depth, Delta, Coverage, (Mask and $80) <> 0);
  end;
end;

procedure TN64RDP.Triangle(Code: Cardinal);
var
  XH, XM, XL, DH, DM, DL: Int64;
  YH, YM, YL, BaseY: Integer;
  OffsetAttributes: Boolean;
begin
  // Per-primitive raster state lives in FPrim: nested routines would keep
  // the raster loop's variables in this frame, in memory.
  FPrim.Code := Code;
  FPrimPixels := 0;
  YL := Integer(SignedValue(SX(FCommand[0] and $3FFF, 14)));
  if FPipelineCrashed then
    Exit;
  if (FScissorQuarterX1 <= FScissorQuarterX0) or (FScissorQuarterY1 <= FScissorQuarterY0) then
    Exit;
  YM := Integer(SignedValue(SX((FCommand[1] shr 16) and $3FFF, 14)));
  YH := Integer(SignedValue(SX(FCommand[1] and $3FFF, 14)));
  if YL <= YH then
    Exit;
  XL := SignedValue(SX(FCommand[2], 28));
  DL := SignedValue(SX(FCommand[3], 30));
  XH := SignedValue(SX(FCommand[4], 28));
  DH := SignedValue(SX(FCommand[5], 30));
  XM := SignedValue(SX(FCommand[6], 28));
  DM := SignedValue(SX(FCommand[7], 30));
  FPrim.Flip := (FCommand[0] and $800000) <> 0;
  FDrawFlip := FPrim.Flip;
  FPrim.Tile := (FCommand[0] shr 16) and 7;
  FPrim.MaxLevel := (FCommand[0] shr 19) and 7;
  FPrim.Cycle := (FOtherHi shr 20) and 3;
  Inc(FPrimSeq);
  // (A lazy primitive, below, needs no mode.)
  if (FModeDirty or (FMode.Textured <> ((Code and 2) <> 0))) and not LazyPrimitive then
    DecodeMode((Code and 2) <> 0);
  FCarryPrim := False;
  if FGroup <> nil then
  begin
    var Reason := BandReason(True);
    SelectBand(Reason in [0, 9]);
    FCarryPrim := Reason = 9;
  end;
  if FColorSize = 1 then
  begin
    // Ordered before every pixel of this primitive.
    FPixelKey := FPrimSeq shl 21;
    SetHiddenOld(0, FHiddenOld[0] and 1);
    SetHiddenOld(4, FHiddenOld[4] and 1);
  end;
  if ((FPrim.Cycle = 2) and (FColorSize = 3)) or ((FPrim.Cycle = 3) and ((FColorSize = 0) or ((FOtherLo and $50) <> 0))) then
  begin
    FPipelineCrashed := True;
    Exit
  end;
  if LazyPrimitive then
  begin
    FLazyClocks := True;
    MarkRows(YH, YL);
    Exit;
  end;
  for var Group := 0 to 3 do
    for var I := 0 to 7 do
      FPrim.Coeff[Group, I] := 0;
  var ShadeBase := 8;
  var TextureBase := ShadeBase;
  if (Code and 4) <> 0 then
    Inc(TextureBase, 16);
  var ZBase := TextureBase;
  if (Code and 2) <> 0 then
    Inc(ZBase, 16);
  for var Group := 0 to 3 do
  begin
    var Index := 0;
    case Group of
      1:
        Index := 2;
      2:
        Index := 8;
      3:
        Index := 10
    end;
    if (Code and 4) <> 0 then
      for var I := 0 to 3 do
        FPrim.Coeff[Group, I] := Coefficient(ShadeBase, Index, I);
    if (Code and 2) <> 0 then
      for var I := 0 to 2 do
        FPrim.Coeff[Group, I + 4] := Coefficient(TextureBase, Index, I);
    if (Code and 1) <> 0 then
      FPrim.Coeff[Group, 7] := SignedValue(SX(FCommand[ZBase + Group], 32));
  end;
  for var I := 0 to 6 do
    FPrim.Coeff[1, I] := FPrim.Coeff[1, I] and not Int64(31);
  for var I := 0 to 3 do
  begin
    FPrim.ShadeDX[I] := SignedValue(SX(UInt64(ShiftRight(FPrim.Coeff[1, I], 14) and $1FFF), 13));
    FPrim.ShadeDY[I] := SignedValue(SX(UInt64(ShiftRight(FPrim.Coeff[3, I], 14) and $1FFF), 13));
  end;
  FPrim.DepthDX := ShiftRight(FPrim.Coeff[1, 7], 10);
  FPrim.DepthDY := ShiftRight(FPrim.Coeff[3, 7], 10);
  FPrim.MemoValid := False;
  FPrim.MemoTexelValid := False;
  begin
    var DX := Integer(ShiftRight(FPrim.Coeff[1, 7], 16) and $FFFF);
    var DY := Integer(ShiftRight(FPrim.Coeff[3, 7], 16) and $FFFF);
    if (DX and $8000) <> 0 then
      DX := (DX xor $FFFF) and $7FFF;
    if (DY and $8000) <> 0 then
      DY := (DY xor $FFFF) and $7FFF;
    FPrim.DepthDelta := Cardinal(DX + DY);
    if (FPrim.DepthDelta and $C000) <> 0 then
      FPrim.DepthDelta := $8000
    else if FPrim.DepthDelta = 0 then
      FPrim.DepthDelta := 1
    else if FPrim.DepthDelta = 1 then
      FPrim.DepthDelta := 3
    else
    begin
      var Bit := Cardinal($2000);
      while (Bit > 0) and ((FPrim.DepthDelta and Bit) = 0) do
        Bit := Bit shr 1;
      FPrim.DepthDelta := Bit shl 1;
    end;
  end;
  BaseY := Integer(ShiftRight(YH, 2));
  var QuarterStart := BaseY * 4;
  var LastQuarter := Min(YL, FScissorQuarterY1) - 1;
  OffsetAttributes := not (((FCommand[5] and $80000000) <> 0) xor FPrim.Flip);
  var LoadQuarter := 0;
  if OffsetAttributes then
    LoadQuarter := 3;
  var XMajor := XH and not Int64(1);
  var XMinor := XM and not Int64(1);
  var MajorStep := ShiftRight(DH, 2) and not Int64(1);
  var MinorStep := ShiftRight(DM, 2) and not Int64(1);
  if FCarryPrim then
  begin
    // Rows that hand the memory colour on: first every band finds what its
    // rows' last pixels read, by the same edges (CarryRow); then they all
    // draw, each taking the colour an earlier row left (LoadCarry).
    Inc(FCarrySeq);
    FCarryFirst := Max(0, Integer(ShiftRight(QuarterStart, 2)));
    var CarryMajor := XMajor;
    var CarryMinor := XMinor;
    var CarryMinorStep := MinorStep;
    for var Q := 0 to 3 do
      FPrim.Invalid[Q] := True;
    for var Quarter := QuarterStart to (LastQuarter or 3) do
    begin
      var Q := Quarter and 3;
      if Quarter = YM then
      begin
        CarryMinor := XL and not Int64(1);
        CarryMinorStep := ShiftRight(DL, 2) and not Int64(1)
      end;
      FPrim.Major[Q] := EdgeQuantise(CarryMajor);
      FPrim.Minor[Q] := EdgeQuantise(CarryMinor);
      FPrim.Invalid[Q] := (Quarter < Max(YH, FScissorQuarterY0)) or (Quarter > LastQuarter);
      var MajorCross := (Cardinal(CarryMajor and $FFFFFFFF) xor $08000000) and $0FFFC000;
      var MinorCross := (Cardinal(CarryMinor and $FFFFFFFF) xor $08000000) and $0FFFC000;
      if FPrim.Flip then
        FPrim.Invalid[Q] := FPrim.Invalid[Q] or (MinorCross < MajorCross)
      else
        FPrim.Invalid[Q] := FPrim.Invalid[Q] or (MajorCross < MinorCross);
      if Q = 3 then
        CarryRow(Integer(ShiftRight(Quarter, 2)));
      CarryMajor := WrapSigned32(CarryMajor + MajorStep);
      CarryMinor := WrapSigned32(CarryMinor + CarryMinorStep);
    end;
    FGroup.CarryBarrier(Self, FCarryColor, FCarryCoverage);
  end;
  for var Q := 0 to 3 do
    FPrim.Invalid[Q] := True;
  for var Quarter := QuarterStart to (LastQuarter or 3) do
  begin
    var Q := Quarter and 3;
    var Y := Integer(ShiftRight(Quarter, 2));
    if Quarter = YM then
    begin
      XMinor := XL and not Int64(1);
      MinorStep := ShiftRight(DL, 2) and not Int64(1)
    end;
    FPrim.Major[Q] := EdgeQuantise(XMajor);
    FPrim.Minor[Q] := EdgeQuantise(XMinor);
    FPrim.Invalid[Q] := (Quarter < Max(YH, FScissorQuarterY0)) or (Quarter > LastQuarter);
    var MajorCross := (Cardinal(XMajor and $FFFFFFFF) xor $08000000) and $0FFFC000;
    var MinorCross := (Cardinal(XMinor and $FFFFFFFF) xor $08000000) and $0FFFC000;
    if FPrim.Flip then
      FPrim.Invalid[Q] := FPrim.Invalid[Q] or (MinorCross < MajorCross)
    else
      FPrim.Invalid[Q] := FPrim.Invalid[Q] or (MajorCross < MinorCross);
    // (The span's attributes are RasterPixel's alone: not for a timing RDP.)
    if (Q = LoadQuarter) and not FTimingOnly then
    begin
      FPrim.UnscrX := Integer(SignedValue(SX(UInt64(ShiftRight(XMajor, 16) and $FFF), 12)));
      var Fraction := ShiftRight(XMajor, 8) and $FF;
      {$IF Defined(CPU64BITS)}
      // Only for a row this RDP draws (RasterRow), only the groups the
      // primitive has: RasterPixel reads no others.
      var Groups := 0;
      if OwnsRow(Y) then
      begin
        if (Code and 4) <> 0 then
          Groups := $0F;
        if (Code and 2) <> 0 then
          Groups := Groups or $70;
        if (Code and 1) <> 0 then
          Groups := Groups or $80;
      end;
      for var I := 0 to 7 do
        if (Groups and (1 shl I)) <> 0 then
      {$ELSE}
      for var I := 0 to 7 do
      {$ENDIF}
      begin
        var DE := FPrim.Coeff[2, I] and not Int64($1FF);
        var DY := FPrim.Coeff[3, I] and not Int64($1FF);
        var Offset: Int64 := 0;
        if OffsetAttributes then
          Offset := DE - ShiftRight(DE, 2) - DY + ShiftRight(DY, 2);
        var DX := ShiftRight(FPrim.Coeff[1, I], 8) and not Int64(1);
        if FPrim.Cycle = 2 then
          DX := 0;
        var Base := WrapSigned32(FPrim.Coeff[0, I] + FPrim.Coeff[2, I] * (Y - BaseY));
        FPrim.SpanAttribute[I] := WrapSigned32((Base and not Int64($1FF)) + Offset - Fraction * DX) and not Int64($3FF);
      end;
    end;
    if Q = 3 then
      RasterRow(Y);
    XMajor := WrapSigned32(XMajor + MajorStep);
    XMinor := WrapSigned32(XMinor + MinorStep);
  end;
  if Assigned(FOnPrimitive) then
    FOnPrimitive(FPrimPixels);
end;

procedure TN64RDP.SetCoefficient(Index: Integer; S, T: Int64);
begin
  var SR := Cardinal(S and $FFFFFFFF);
  var TR := Cardinal(T and $FFFFFFFF);
  FCommand[Index] := (SR and $FFFF0000) or (TR shr 16);
  FCommand[Index + 4] := ((SR and $FFFF) shl 16) or (TR and $FFFF);
end;

procedure TN64RDP.Rectangle(Code: Cardinal);
begin
  var A := FCommand[0];
  var B := FCommand[1];
  var ST := FCommand[2];
  var Delta := FCommand[3];
  var XL := (A shr 12) and $FFF;
  var YL := A and $FFF;
  var XH := (B shr 12) and $FFF;
  var YH := B and $FFF;
  var Tile := (B shr 24) and 7;
  if ((FOtherHi shr 20) and 3) in [2, 3] then
    YL := YL or 3;
  for var I := 0 to High(FCommand) do
    FCommand[I] := 0;
  FCommand[0] := $00800000 or (Tile shl 16) or YL;
  FCommand[1] := (YL shl 16) or YH;
  FCommand[2] := XL shl 14;
  FCommand[4] := XH shl 14;
  FCommand[6] := XL shl 14;
  if Code = 54 then
    Triangle(8)
  else
  begin
    var S := SignedValue(SX(ST shr 16, 16));
    var T := SignedValue(SX(ST and $FFFF, 16));
    var DS := SignedValue(SX(Delta shr 16, 16));
    var DT := SignedValue(SX(Delta and $FFFF, 16));
    if ((FOtherHi shr 20) and 3) = 2 then
      DS := ShiftRight(DS, 2);
    SetCoefficient(8, S * 65536, T * 65536);
    if Code = 36 then
    begin
      SetCoefficient(10, DS * 2048, 0);
      SetCoefficient(16, 0, DT * 2048);
      SetCoefficient(18, 0, DT * 2048);
    end
    else
    begin
      SetCoefficient(10, 0, DT * 2048);
      SetCoefficient(16, DS * 2048, 0);
      SetCoefficient(18, DS * 2048, 0);
    end;
    Triangle(10);
  end;
end;

function TN64RDP.Execute(Start, Finish: Cardinal; XBUS: Boolean; out Consumed: Cardinal): Boolean;
begin
  Result := False;
  BeginList;
  Consumed := Start;
  if FPipelineCrashed then
    Exit;
  if (Finish < Start) or (Finish - Start > $800000) then
    raise EReadError.Create('Invalid RDP command range');
  while UInt64(Consumed) + 8 <= Finish do
  begin
    var W0, W1: Cardinal;
    if XBUS then
    begin
      W0 := FetchCommand($04000000 + (Consumed and $FFF));
      W1 := FetchCommand($04000000 + ((Consumed + 4) and $FFF));
    end
    else
    begin
      W0 := FetchCommand(Consumed and $FFFFFF);
      W1 := FetchCommand((Consumed + 4) and $FFFFFF);
    end;
    Inc(Consumed, 8);
    // A worker RDP receives exactly these words, in this order.
    if Assigned(FOnWords) then
      FOnWords(W0, W1);
    if FCapture then
    begin
      if FCapturedCount + 2 > Length(FCaptured) then
        SetLength(FCaptured, Max(64, Length(FCaptured) * 2));
      FCaptured[FCapturedCount] := W0;
      FCaptured[FCapturedCount + 1] := W1;
      Inc(FCapturedCount, 2);
    end;
    var Status := Feed(W0, W1);
    if Status = FeedSync then
      Result := True
    else if Status = FeedStop then
      Break;
  end;
end;

function TN64RDP.FetchCommand(Address: Cardinal): Cardinal;
begin
  // The checked accessor: command words in RDRAM may be the target of queued
  // RDP writes.
  if UInt64(Address) + 4 <= FBus.RAMSize then
    Result := FBus.ReadRAM32(Address)
  else
    Result := FBus.Read32(Address);
end;

procedure TN64RDP.BeginList;
begin
  FWorkClocks := 0;
  FTransferBits := 0;
  FLazyClocks := False;
  FCapturedCount := 0;
end;

function TN64RDP.Feed(W0, W1: Cardinal): Integer;
begin
  Result := FeedNone;
  FCommand[FCommandCount] := W0;
  FCommand[FCommandCount + 1] := W1;
  Inc(FCommandCount, 2);
  var A := FCommand[0];
  var B := FCommand[1];
  var Code := (A shr 24) and 63;
  var Words := 2;
  if Code in [8..15] then
  begin
    Words := 8;
    if (Code and 4) <> 0 then
      Inc(Words, 16);
    if (Code and 2) <> 0 then
      Inc(Words, 16);
    if (Code and 1) <> 0 then
      Inc(Words, 4);
  end
  else if Code in [36, 37] then
    Words := 4;
  if FCommandCount < Words then
    Exit;
  // Trace words live in a field: a managed local here would give Feed an
  // implicit try/finally and keep all of its variables in memory.
  if Assigned(FOnCommand) or Assigned(FOnCommandCompleted) then
    TraceCommand(Words);
  Inc(FWorkClocks, Cardinal(Words div 2));
  case Code of
    0, 38, 39, 40, 41:
      if Code = 41 then
        Result := FeedSync;
    45:
      begin
        FScissorQuarterX0 := (A shr 12) and $FFF;
        FScissorQuarterY0 := A and $FFF;
        FScissorQuarterX1 := (B shr 12) and $FFF;
        FScissorQuarterY1 := B and $FFF;
        FScissorX0 := FScissorQuarterX0 div 4;
        FScissorY0 := FScissorQuarterY0 div 4;
        FScissorX1 := (FScissorQuarterX1 + 3) div 4;
        FScissorY1 := (FScissorQuarterY1 + 3) div 4;
        FScissorField := (B and $02000000) <> 0;
        FScissorOdd := (B and $01000000) <> 0;
      end;
    47:
      begin
        FOtherHi := A and $FFFFFF;
        FOtherLo := B;
        FModeDirty := True;
        InvalidateTexels; // TLUT enable/type select the texel decode.
      end;
    53:
      begin
        var I := (B shr 24) and 7;
        FTiles[I].Format := (A shr 21) and 7;
        FTiles[I].Size := (A shr 19) and 3;
        FTiles[I].Line := (A shr 9) and $1FF;
        FTiles[I].TMEM := A and $1FF;
        FTiles[I].Palette := (B shr 20) and 15;
        FTiles[I].ClampT := (B and $80000) <> 0;
        FTiles[I].MirrorT := (B and $40000) <> 0;
        FTiles[I].MaskT := (B shr 14) and 15;
        FTiles[I].ShiftT := (B shr 10) and 15;
        FTiles[I].ClampS := (B and $200) <> 0;
        FTiles[I].MirrorS := (B and $100) <> 0;
        FTiles[I].MaskS := (B shr 4) and 15;
        FTiles[I].ShiftS := B and 15;
        UpdateTileInfo(I);
      end;
    50, 51, 52, 48:
      begin
        var I := (B shr 24) and 7;
        var SL := Integer((A shr 12) and $FFF);
        var TL := Integer(A and $FFF);
        var SH := Integer((B shr 12) and $FFF);
        var TH := Integer(B and $FFF);
        FTiles[I].SL := SL;
        FTiles[I].TL := TL;
        FTiles[I].SH := SH;
        FTiles[I].TH := TH;
        UpdateTileInfo(I);
        if Code = 50 then
        begin
          FTiles[I].SL := SL;
          FTiles[I].TL := TL;
          FTiles[I].SH := SH;
          FTiles[I].TH := TH
        end
        else if Code = 48 then
        begin
          if FTextureSize = 0 then
          begin
            FPipelineCrashed := True;
            FCommandCount := 0;
            Exit(FeedStop)
          end;
          var Count := ((SH div 4) - (SL div 4) + 1) and $FFF;
          if Count > 0 then
            Inc(FWorkClocks, Cardinal(Min(Count, 256)));
          if (FTextureSize <> 2) or (FTiles[I].Format = 1) or ((FTiles[I].Format = 0) and (FTiles[I].Size = 3)) then
          begin
            // From an 8- or 32-bit image, or into a YUV or RGBA32 tile
            // (LoadTLUTPipeline; else entry J is 4 copies of halfword J, as
            // below): the full RDP reads RDRAM itself (a timing RDP sends no
            // bytes and marks the doublewords the steps read).
            if FClocksOnly then
              // (No bus: Replay.)

            else if FTimingOnly then
            begin
              if Assigned(FOnDataOut) then
              begin
                Inc(FLoadStats[2]);
                FOnDataOut(0);
              end
              else
                Inc(FLoadStats[3]);
              var Steps := (Count + 7) div 8;
              if FTextureSize = 2 then
                Steps := Count div 4 + 1
              else if FTextureSize = 3 then
                Steps := (Count + 1) div 2;
              var First := (UInt64(FTextureAddress) + Cardinal(((TL div 4) * FTextureWidth + SL div 4) shl FTextureSize) shr 1) and
                not UInt64(7);
              if (Steps > 0) and (First < $800000) then
                FBus.MarkRDPRead(Cardinal(First), Cardinal(Min(UInt64(Steps * 8 + 8), $800000 - First)));
            end
            else
            begin
              if Assigned(FOnDataIn) then
                FOnDataIn();
              if ReadsRDRAM then
                LoadTLUTPipeline(I, SL, TL, SH);
            end;
          end
          else
          begin
            // Entry J comes from RDRAM bytes First + 2J and First + 2J + 1, if
            // both lie below $800000. As in LoadTexture, a timing RDP sends them
            // with the command words unless a queued list may write them.
            var First := UInt64(FTextureAddress) + Cardinal(((TL div 4) * FTextureWidth + SL div 4) * 2);
            var Entries := Min(Count, 256);
            if FClocksOnly then
              // (No bus: Replay.)

            else if FTimingOnly then
            begin
              var Payload := Assigned(FOnDataOut) and ((First >= $800000) or
                not FBus.RDPWriteHazard(Cardinal(First), Cardinal(Entries * 2)));
              if Payload then
                Inc(FLoadStats[0])
              else if Assigned(FOnDataOut) then
                Inc(FLoadStats[1])
              else
                Inc(FLoadStats[3]);
              if Assigned(FOnDataOut) then
                FOnDataOut(Ord(Payload));
              if Payload then
              begin
                for var J := 0 to Entries - 1 do
                  if First + Cardinal(J * 2) + 1 < $800000 then
                  begin
                    PutDataByte(FBus.RDPRead8(Cardinal(First) + Cardinal(J * 2)));
                    PutDataByte(FBus.RDPRead8(Cardinal(First) + Cardinal(J * 2) + 1));
                  end;
                EndData;
              end
              else if (Entries > 0) and (First < $800000) then
                FBus.MarkRDPRead(Cardinal(First), Cardinal(Entries * 2));
            end
            else
            begin
              var Payload := Assigned(FOnDataIn) and (FOnDataIn() <> 0);
              FDataBytes := 0;
              if Payload or ReadsRDRAM then
                for var J := 0 to Entries - 1 do
                begin
                  var Source := First + Cardinal(J * 2);
                  var V: Cardinal := 0;
                  if Source + 1 < $800000 then
                    if Payload then
                    begin
                      V := Cardinal(NextDataByte) shl 8;
                      V := V or NextDataByte;
                    end
                    else
                      V := (Cardinal(MemRead8(Cardinal(Source))) shl 8) or MemRead8(Cardinal(Source + 1));
                  for var K := 0 to 3 do
                  begin
                    // Quad-coordinate loading expands S before tile-size addressing.
                    // Standard TLUT tiles use size=4b; 8b/16b tiles leave sparse entries.
                    var Stride := 8 shl Min(FTiles[I].Size, 2);
                    var Address := (FTiles[I].TMEM * 8 + J * Stride + K * 2) and $FFF;
                    FTMEM[Address] := Byte(V shr 8);
                    FTMEM[(Address + 1) and $FFF] := Byte(V and $FF);
                  end;
                end;
            end;
          end;
        end
        else
          LoadTexture(I, SL, TL, SH, TH, Code = 51);
      end;
    54, 36, 37:
      Rectangle(Code);
    55:
      FFill := B;
    56:
      FFogColor := B;
    57:
      FBlendColor := B;
    58:
      begin
        FPrimitive := B;
        FPrimitiveLOD := A and $FF;
        FMinLevel := (A shr 8) and 31;
        FModeDirty := True;
      end;
    59:
      begin
        FEnvironment := B;
        FModeDirty := True;
      end;
    61:
      begin
        FTextureFormat := (A shr 21) and 7;
        FTextureSize := (A shr 19) and 3;
        FTextureWidth := (A and $3FF) + 1;
        FTextureAddress := B and $FFFFFF
      end;
    63:
      begin
        FColorSize := (A shr 19) and 3;
        FColorFormat := (A shr 21) and 7;
        FColorWidth := (A and $3FF) + 1;
        FColorAddress := B and $FFFFFF
      end;
    60:
      begin
        FCombineHi := A and $FFFFFF;
        FCombineLo := B;
        FHasCombine := True;
        FModeDirty := True;
      end;
    46:
      begin
        FPrimitiveDepth := ((B shr 16) and $7FFF) * 8;
        FPrimitiveDelta := B and $FFFF
      end;
    62:
      FZAddress := B and $FFFFFF;
    44:
      begin
        FConvert[0] := Integer(SignedValue(SX((A shr 13) and $1FF, 9))) * 2 + 1;
        FConvert[1] := Integer(SignedValue(SX((A shr 4) and $1FF, 9))) * 2 + 1;
        FConvert[2] := Integer(SignedValue(SX(((A and 15) shl 5) or (B shr 27), 9))) * 2 + 1;
        FConvert[3] := Integer(SignedValue(SX((B shr 18) and $1FF, 9))) * 2 + 1;
        FConvert[4] := (B shr 9) and $1FF;
        FConvert[5] := B and $1FF;
        FModeDirty := True;
      end;
    42:
      begin
        FKeyWidth[1] := (A shr 12) and $FFF;
        FKeyWidth[2] := A and $FFF;
        FKeyCenter[1] := (B shr 24) and $FF;
        FKeyScale[1] := (B shr 16) and $FF;
        FKeyCenter[2] := (B shr 8) and $FF;
        FKeyScale[2] := B and $FF;
        FModeDirty := True;
      end;
    43:
      begin
        FKeyWidth[0] := (B shr 16) and $FFF;
        FKeyCenter[0] := (B shr 8) and $FF;
        FKeyScale[0] := B and $FF;
        FModeDirty := True;
      end;
    8..15:
      Triangle(Code);
  else
    raise EN64Unsupported.CreateFmt('RDP opcode %2.2x is not implemented', [Code]);
  end;
  // Fill/copy memory writes use a 64-bit bus per RCP clock at peak throughput.
  Inc(FWorkClocks, (FTransferBits + 63) div 64);
  FTransferBits := 0;
  FCommandCount := 0;
  if Assigned(FOnCommandCompleted) then
    FOnCommandCompleted(FTraceWords);
end;

procedure TN64RDP.TraceCommand(Words: Integer);
begin
  // Snapshot of the command before execution (Rectangle rewrites FCommand).
  FTraceWords := nil;
  SetLength(FTraceWords, Words);
  for var I := 0 to Words - 1 do
    FTraceWords[I] := FCommand[I];
  if Assigned(FOnCommand) then
    FOnCommand(FTraceWords);
end;

procedure TN64RDP.SerializeState(State: TStateArchive);

  procedure ValidateFlag(var Flag);
  begin
    // Boolean's declared range is 0..1, so Ord(Flag)>1 may be optimized out.
    // Inspect the stored byte without interpreting it as a typed Boolean.
    var Raw: Byte;
    Move(Flag, Raw, SizeOf(Raw));
    if Raw > 1 then
      raise EReadError.Create('Invalid RDP Boolean snapshot');
  end;

begin
  State.Field(FTMEM, SizeOf(FTMEM));
  State.Field(FTiles, SizeOf(FTiles));
  State.Field(FColorAddress, 4);
  State.Field(FTextureAddress, 4);
  State.Field(FFill, 4);
  State.Field(FPrimitive, 4);
  State.Field(FEnvironment, 4);
  State.Field(FOtherHi, 4);
  State.Field(FOtherLo, 4);
  State.Field(FCombineHi, 4);
  State.Field(FCombineLo, 4);
  State.Field(FHasCombine, SizeOf(FHasCombine));
  State.Field(FBlendColor, 4);
  State.Field(FFogColor, 4);
  State.Field(FZAddress, 4);
  State.Field(FPrimitiveDepth, 4);
  State.Field(FPrimitiveDelta, 4);
  State.Field(FPrimitiveLOD, 4);
  State.Field(FConvert, SizeOf(FConvert));
  State.Field(FKeyWidth, SizeOf(FKeyWidth));
  State.Field(FKeyCenter, SizeOf(FKeyCenter));
  State.Field(FKeyScale, SizeOf(FKeyScale));
  State.Field(FNoiseSeed, 4);
  State.Field(FNoise, 4);
  State.Field(FLODFraction, 4);
  State.Field(FMinLevel, 4);
  State.Field(FShadeAlpha, 4);
  State.Field(FAlphaDither, 4);
  State.Field(FColorFormat, 4);
  State.Field(FColorWidth, 4);
  State.Field(FColorSize, 4);
  State.Field(FTextureWidth, 4);
  State.Field(FTextureSize, 4);
  State.Field(FTextureFormat, 4);
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FCommandCount, 4);
  State.Field(FWorkClocks, SizeOf(FWorkClocks));
  State.Field(FTransferBits, SizeOf(FTransferBits));
  State.Field(FPipelineCrashed, SizeOf(FPipelineCrashed));
  State.Field(FHiddenOld, SizeOf(FHiddenOld));
  State.Field(FDrawFlip, SizeOf(FDrawFlip));
  State.Field(FDelayedHidden, 4);
  State.Field(FMemoryColor, 4);
  State.Field(FMemoryCoverage, 4);
  State.Field(FScissorX0, 4);
  State.Field(FScissorY0, 4);
  State.Field(FScissorX1, 4);
  State.Field(FScissorY1, 4);
  State.Field(FScissorQuarterX0, 4);
  State.Field(FScissorQuarterY0, 4);
  State.Field(FScissorQuarterX1, 4);
  State.Field(FScissorQuarterY1, 4);
  State.Field(FScissorField, SizeOf(FScissorField));
  State.Field(FScissorOdd, SizeOf(FScissorOdd));
  if State.Loading then
  begin
    ValidateFlag(FHasCombine);
    ValidateFlag(FPipelineCrashed);
    ValidateFlag(FDrawFlip);
    ValidateFlag(FScissorField);
    ValidateFlag(FScissorOdd);
    for var I := 0 to High(FTiles) do
    begin
      ValidateFlag(FTiles[I].ClampS);
      ValidateFlag(FTiles[I].ClampT);
      ValidateFlag(FTiles[I].MirrorS);
      ValidateFlag(FTiles[I].MirrorT);
    end;
    if (FCommandCount < 0) or (FCommandCount >= Length(FCommand)) or Odd(FCommandCount) then
      raise EReadError.Create('Invalid RDP command snapshot');
    if (FColorSize < 0) or (FColorSize > 3) or (FZAddress > $FFFFFF) or
      (FPrimitiveDepth > $3FFFF) or (FPrimitiveDelta > $FFFF) or (FPrimitiveLOD > 255) or
      (FScissorX0 < 0) or (FScissorX0 > 1024) or (FScissorX1 < 0) or (FScissorX1 > 1024) or
      (FScissorY0 < 0) or (FScissorY0 > 1024) or (FScissorY1 < 0) or (FScissorY1 > 1024) then
      raise EReadError.Create('Invalid RDP rasterizer snapshot');
    for var I := 0 to 5 do
      if ((I < 4) and ((FConvert[I] < -511) or (FConvert[I] > 511))) or
        ((I >= 4) and ((FConvert[I] < 0) or (FConvert[I] > 511))) then
        raise EReadError.Create('Invalid RDP conversion snapshot');
    if (FColorWidth < 1) or (FColorWidth > 4096) or (FTextureWidth < 1) or (FTextureWidth > 4096) or
      (FTextureSize < 0) or (FTextureSize > 3) then
      raise EReadError.Create('Invalid RDP snapshot');
    if (FMinLevel < 0) or (FMinLevel > 31) or (FLODFraction < 0) or (FLODFraction > 511) or
      (FShadeAlpha < 0) or (FShadeAlpha > 255) or (FAlphaDither < 0) or (FAlphaDither > 7) or
      (FColorFormat < 0) or (FColorFormat > 7) or
      (FScissorQuarterX0 < 0) or (FScissorQuarterX0 > 4096) or
      (FScissorQuarterY0 < 0) or (FScissorQuarterY0 > 4096) or
      (FScissorQuarterX1 < 0) or (FScissorQuarterX1 > 4096) or
      (FScissorQuarterY1 < 0) or (FScissorQuarterY1 > 4096) then
      raise EReadError.Create('Invalid RDP pipeline snapshot');
    if (FDelayedHidden < -1) or (FDelayedHidden > $800000) or (FMemoryCoverage < 0) or (FMemoryCoverage > 7) or (FNoise > $1FF) or
      (FWorkClocks > UInt64($10000000000)) then
      raise EReadError.Create('Invalid RDP memory/timing snapshot');
    if FTransferBits > UInt64($10000000000) then
      raise EReadError.Create('Invalid RDP transfer timing snapshot');
    for var I := 0 to High(FHiddenOld) do
      if FHiddenOld[I] > 3 then
        raise EReadError.Create('Invalid RDP hidden snapshot');
    for var I := 0 to 2 do
      if (FKeyWidth[I] < 0) or (FKeyWidth[I] > 4095) or (FKeyCenter[I] < 0) or (FKeyCenter[I] > 255) or
        (FKeyScale[I] < 0) or (FKeyScale[I] > 255) then
        raise EReadError.Create('Invalid RDP key snapshot');
    for var I := 0 to 7 do
      if (FTiles[I].Format < 0) or (FTiles[I].Format > 7) or
        (FTiles[I].SL < 0) or (FTiles[I].SL > 4095) or (FTiles[I].SH < 0) or (FTiles[I].SH > 4095) or
        (FTiles[I].TL < 0) or (FTiles[I].TL > 4095) or (FTiles[I].TH < 0) or (FTiles[I].TH > 4095) or
        (FTiles[I].TMEM < 0) or (FTiles[I].TMEM > 511) or
        (FTiles[I].Palette < 0) or (FTiles[I].Palette > 15) or (FTiles[I].Size < 0) or (FTiles[I].Size > 3) or (FTiles[I].Line < 0) or (FTiles[I].Line > 511) or
        (FTiles[I].MaskS < 0) or (FTiles[I].MaskS > 15) or (FTiles[I].MaskT < 0) or (FTiles[I].MaskT > 15) or
        (FTiles[I].ShiftS < 0) or (FTiles[I].ShiftS > 15) or (FTiles[I].ShiftT < 0) or (FTiles[I].ShiftT > 15) then
        raise EReadError.Create('Invalid RDP tile snapshot');
    for var I := 0 to 7 do
      UpdateTileInfo(I);
    FModeDirty := True;
  end;
end;

{ TN64RDPGroup }

constructor TN64RDPGroup.Create(const Members: array of TN64RDP);
begin
  inherited Create;
  SetLength(FMembers, Length(Members));
  SetLength(FSlots, Length(Members));
  SetLength(FCarryStates[0], Length(Members));
  SetLength(FCarryStates[1], Length(Members));
  for var I := 0 to High(Members) do
  begin
    FMembers[I] := Members[I];
    FSlots[I].Event := TEvent.Create(nil, False, False, '');
    Members[I].JoinGroup(Self, I, Length(Members));
  end;
end;

destructor TN64RDPGroup.Destroy;
begin
  for var I := 0 to High(FSlots) do
    FSlots[I].Event.Free;
  inherited;
end;

function TN64RDPGroup.ReadReleased: Int64;
begin
  {$IFDEF CPUX64}
  Result := FReleased;
  {$ELSE}
  Result := TInterlocked.Read(FReleased);
  {$ENDIF}
end;

function TN64RDPGroup.ReadArrived(Member: Integer): Int64;
begin
  {$IFDEF CPUX64}
  Result := FSlots[Member].Arrived;
  {$ELSE}
  Result := TInterlocked.Read(FSlots[Member].Arrived);
  {$ENDIF}
end;

function TN64RDPGroup.Aborted: Boolean;
begin
  {$IFDEF CPUX64}
  Result := FAborted <> 0;
  {$ELSE}
  Result := TInterlocked.CompareExchange(FAborted, 0, 0) <> 0;
  {$ENDIF}
end;

function TN64RDPGroup.Reached(Point: Int64; Release: Boolean): Boolean;
begin
  if Release then
    Exit(ReadReleased >= Point);
  for var I := 0 to High(FSlots) do
    if ReadArrived(I) < Point then
      Exit(False);
  Result := True;
end;

procedure TN64RDPGroup.Wake;
begin
  // A waiter sets its flag before its final check; both sides use full
  // barriers, so no wake-up is lost.
  for var I := 0 to High(FSlots) do
    if TInterlocked.CompareExchange(FSlots[I].Waiting, 0, 1) = 1 then
      FSlots[I].Event.SetEvent;
end;

procedure TN64RDPGroup.Wait(Member: Integer; Point: Int64; Release: Boolean);
begin
  var Spins := 0;
  while not Reached(Point, Release) do
  begin
    if Aborted then
      raise EN64Unsupported.Create('RDP band stopped: another band failed');
    if Spins < SpinRounds then
    begin
      Inc(Spins);
      YieldProcessor;
      Continue;
    end;
    TInterlocked.Exchange(FSlots[Member].Waiting, 1);
    if Reached(Point, Release) or (Aborted) then
    begin
      TInterlocked.Exchange(FSlots[Member].Waiting, 0);
      Continue;
    end;
    FSlots[Member].Event.WaitFor(INFINITE);
  end;
end;

procedure TN64RDPGroup.Barrier(RDP: TN64RDP; Kind: Integer);
begin
  Barrier(RDP, Kind, nil);
end;

procedure TN64RDPGroup.Barrier(RDP: TN64RDP; const Work: TProc);
begin
  Barrier(RDP, BarrierSync, Work);
end;

procedure TN64RDPGroup.Barrier(RDP: TN64RDP; Kind: Integer; const Work: TProc);
begin
  Inc(RDP.FBarriers);
  var Point := RDP.FBarriers;
  TInterlocked.Exchange(FSlots[RDP.FBand].Arrived, Point);
  Wake;
  if RDP.FBand = 0 then
  begin
    // Everyone has finished all work before this point and waits.
    Wait(0, Point, False);
    // (Before the release: no member may run anything after this point while
    // Work runs. xbustest scene 7 sees it only now and then: the copy it
    // makes is short.)
    if Assigned(Work) then
      Work();
    if Kind = BarrierEnter then
      for var I := 1 to High(FMembers) do
        RDP.MergeCarried(FMembers[I])
    else if Kind = BarrierLeave then
      for var I := 1 to High(FMembers) do
        FMembers[I].CopyCarried(RDP);
    TInterlocked.Exchange(FReleased, Point);
    Wake;
  end
  else
    Wait(RDP.FBand, Point, True);
  RDP.FBandDrawn := False;
end;

procedure TN64RDPGroup.SetCarry(Seq: Int64; Y: Integer; Valid: Boolean; Color: Cardinal; Coverage: Integer);
begin
  var B := Integer(Seq and 1);
  FCarryValid[B, Y] := Valid;
  FCarryColor[B, Y] := Color;
  FCarryCoverage[B, Y] := Byte(Coverage and 7);
end;

function TN64RDPGroup.CarryValid(Seq: Int64; Y: Integer): Boolean;
begin
  Result := FCarryValid[Integer(Seq and 1), Y];
end;

procedure TN64RDPGroup.GetCarry(Seq: Int64; Y: Integer; var Color: Cardinal; var Coverage: Integer);
begin
  var B := Integer(Seq and 1);
  Color := FCarryColor[B, Y];
  Coverage := FCarryCoverage[B, Y];
end;

procedure TN64RDPGroup.CarryBarrier(RDP: TN64RDP; out Color: Cardinal; out Coverage: Integer);
begin
  // As MergeCarried: the low byte and coverage of the band that set them
  // last, the RGB of the one that read memory last.
  var B := Integer(RDP.FCarrySeq and 1);
  FCarryStates[B, RDP.FBand].Color := RDP.FMemoryColor;
  FCarryStates[B, RDP.FBand].Coverage := RDP.FMemoryCoverage;
  FCarryStates[B, RDP.FBand].KeyMemory := RDP.FKeyMemory;
  FCarryStates[B, RDP.FBand].KeyMemoryRGB := RDP.FKeyMemoryRGB;
  Barrier(RDP, BarrierSync);
  // The bands draw this primitive's rows from now on.
  RDP.FBandDrawn := True;
  var Low := RDP.FBand;
  var RGB := RDP.FBand;
  for var I := 0 to High(FMembers) do
  begin
    if FCarryStates[B, I].KeyMemory > FCarryStates[B, Low].KeyMemory then
      Low := I;
    if FCarryStates[B, I].KeyMemoryRGB > FCarryStates[B, RGB].KeyMemoryRGB then
      RGB := I;
  end;
  Color := (FCarryStates[B, RGB].Color and $FFFFFF00) or (FCarryStates[B, Low].Color and $FF);
  Coverage := FCarryStates[B, Low].Coverage;
end;

procedure TN64RDPGroup.Abort;
begin
  TInterlocked.Exchange(FAborted, 1);
  for var I := 0 to High(FSlots) do
    FSlots[I].Event.SetEvent;
end;

procedure TN64RDPGroup.Restart;
begin
  TInterlocked.Exchange(FReleased, 0);
  for var I := 0 to High(FSlots) do
  begin
    TInterlocked.Exchange(FSlots[I].Arrived, 0);
    FMembers[I].ResetBands;
  end;
end;

procedure TN64RDPGroup.MergeInto(Target: TN64RDP);
begin
  for var Member in FMembers do
    if Member <> Target then
      Target.MergeCarried(Member);
end;

initialization
  InitPerspective;
  {$IF Defined(CPU64BITS)}
  for var N := 2 to 255 do
  begin
    var B := 0;
    while (N shr (B + 1)) <> 0 do
      Inc(B);
    HighBit8[N] := B;
  end;
  for var N := 0 to 127 do
  begin
    var B := 0;
    while (B < 7) and ((N and ($40 shr B)) <> 0) do
      Inc(B);
    LeadingOnes7[N] := B;
  end;
  {$ENDIF}

end.

