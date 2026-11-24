unit Flash.Player;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.Math,
  SWF.Reader, SWF.Movie, SWF.Geometry, SWF.Sound, AVM1.Runtime, Flash.Text,
  Flash.Audio, Media.Image.PixelBuffer, SWF.Video, Flash.Net, AVM2.ABC,
  AVM2.Runtime;

type
  TFlashQuality = (fqLow, fqMedium, fqHigh, fqBest, fq8x8, fq8x8Linear, fq16x16, fq16x16Linear);

  TFlashResourceReader = TFlashNetRead;

  TFlashClip = class;

  TFlashLibrary = class
  public
    Movie: TSWFMovie;
    Root: TFlashClip;
    URI: string;
    SourceBytes: Integer;
    AVM2: TAVM2Runtime;
    ExportNames: TDictionary<string, Integer>;
    Symbols: TDictionary<Integer, string>;
    constructor Create(const Data: TBytes; const Origin: string);
    destructor Destroy; override;
  end;

  TFlashLoadRequest = record
    Target: TFlashClip;
    Loader, CallerRoot: TAVMObject;
    CallerVersion: Byte;
    CallerLibrary: TFlashLibrary;
    Origin, URL: string;
    Generation: Cardinal;
    ReadyFrame: UInt64;
  end;

  TFlashClip = class
  private
    FStoredMatrix: TSWFMatrix;
    FMatrixSnapshot: array[0..5] of Double;
    FMatrixValid: Boolean;
    FSerial: UInt64;
    FTextDocument: TFlashTextDocument;
    FStrokePoints: TList<TSWFPoint>;
    FDrawingEdgeCount: Integer;
    procedure ResetDrawing;
    procedure FinishDrawingStroke;
    function PendingFillEdge(out Edge: TSWFEdge): Boolean;
    function PendingStroke(out Path: TSWFStrokePath): Boolean;
    function GetTextDocument: TFlashTextDocument;
    function GetText: string;
    procedure SetText(const Value: string);
    function GetHTMLText: string;
    procedure SetHTMLText(const Value: string);
    procedure SnapshotMatrix;
    function GetAlpha: Double;
    procedure SetAlpha(Value: Double);
  public
    ColorTransform: TSWFColorTransform;
    SoundTransform: TFlashSoundTransform;
    TransformedByScript: Boolean;
    Script, RegisteredConstructor: TAVMObject;
    CreatedFrame, SynchronousSeekTick: UInt64;
    MovieLibrary: TFlashLibrary;
    MovieRoot, Unloaded, IsLevel, Removing, UnloadDispatching: Boolean;
    FrameScriptPending: Boolean;
    AVM2ConstructionPending, HasAVM2Handle: Boolean;
    PendingAVM2Playing, ApplyingAVM2Goto, ExecutingFrameScript: Boolean;
    LevelIndex: Integer;
    LoadGeneration, ContentGeneration, UnloadGeneration: Cardinal;
    DropTarget: TFlashClip;
    Parent: TFlashClip;
    Masker, Maskee: TFlashClip;
    ClipDepth: Integer;
    MorphRatio: Word;
    VideoState: TSWFVideoState;
    NetStream: TAVMObject;
    BlendMode: TAVMBitmapBlend;
    Filters: TSWFFilters;
    RenderingMask, TestingMask: Boolean;
    HasScrollRect, HasAppliedScrollRect: Boolean;
    NextScrollRect, AppliedScrollRect: TSWFRect;
    Children: TList<TFlashClip>;
    Character, Drawing: TSWFCharacter;
    DrawingTouched: Boolean;
    AttachedBitmap: IImagePixelBuffer;
    AttachedBitmapBounds: TSWFBounds;
    AttachedBitmapSmooth: Boolean;
    Depth, Frame, PendingFrame, Fill, StrokeFill, ButtonStates, ButtonState, FontId, TimelineOrigin, SeekGeneration: Integer;
    Playing, Visible, Dead, Started, IsText, IsEditable: Boolean;
    X, Y, ScaleX, ScaleY, Rotation, Skew: Double;
    PenX, PenY, StartX, StartY: Integer; // Local twips.
    TextWidth, TextHeight: Double;
    Name, VariableName: string;
    TextMultiline: Boolean;
    TextLeftMargin, TextIndent: Double;
    TextColor: Cardinal;
    TextSize, TextLeft, TextTop, TextRight, TextLeading: Double;
    TextAlign: Integer;
    ClipActions: TList<TSWFClipAction>;
    constructor Create;
    destructor Destroy; override;
    function Matrix: TSWFMatrix;
    function WithScrollOffset(const Transform: TSWFMatrix): TSWFMatrix;
    procedure ApplyScrollRect;
    procedure SetMatrix(const Value: TSWFMatrix);
    procedure SetPosition(XValue, YValue: Double);
    procedure SetPositionTwips(XValue, YValue: Integer);
    procedure SetScale(Axis: Integer; Value: Double);
    procedure SetRotation(Value: Double);
    property TextDocument: TFlashTextDocument read GetTextDocument;
    property Text: string read GetText write SetText;
    property HTMLText: string read GetHTMLText write SetHTMLText;
    property Alpha: Double read GetAlpha write SetAlpha;
  end;

  TFlashUnloadRequest = record
    Clip: TFlashClip;
    Generation: Cardinal;
    ReadyFrame: UInt64;
    Remove, Delivered: Boolean;
  end;

  TFlashQueuedConstruct = record
    Clip: TFlashClip;
    Generation: Cardinal;
  end;

  TFlashQueuedAction = record
    Clip: TFlashClip;
    Generation: Cardinal;
    Code: TBytes;
    EventName: string;
    EventFlags: Cardinal;
  end;

  TFlashPixels = TArray<Cardinal>;

  PFlashPixels = ^TFlashPixels;

  PFlashRenderState = ^TFlashRenderState;

  TFlashRenderState = record
    Work: Int64;
    Width, Height: Integer;
    Stage: TSWFRect;
    WithAlpha, IsLayer: Boolean;
    ParentLayer: PFlashRenderState;
    ParentLayerPixels: PFlashPixels;
    DrawableRoot: TFlashClip;
    DrawableMatrix: TSWFMatrix;
    Quality: TFlashQuality;
    SampleCount: Integer;
    FullCoverage: Word;
    SampleX, SampleY: array[0..15] of Double;
    DetailIndex: TArray<Integer>;
    DetailPixels: TList<Integer>;
    DetailColors: TArray<Cardinal>;
    Color: TSWFColorTransform;
    Coverage, MaskOutput: TBytes;
  end;

  TFlashRasterSpan = record
    Y, Left, Right: Integer;
    Coverage: Word;
  end;

  PFlashShapeRaster = ^TFlashShapeRaster;

  TFlashShapeRaster = record
    Fills: TArray<TSWFFill>;
    Matrix: TSWFMatrix;
    Stage: TSWFRect;
    Width, Height: Integer;
    Quality: TFlashQuality;
    Spans: TArray<TFlashRasterSpan>;
    StyleOffsets: TArray<Integer>;
    LastUsed: UInt64;
    TooManySpans: Boolean;
  end;

  TFlashTextureRowState = (trUnfilled, trMixed, trOpaque);

  PFlashTextureSamples = ^TFlashTextureSamples;

  TFlashTextureSamples = record
    Source: TArray<Cardinal>;
    Inverse: TSWFMatrix;
    SourceWidth, TargetWidth, TargetHeight: Integer;
    ContentVersion, LastUsed: UInt64;
    RepeatPixels, Premultiplied: Boolean;
    Colors: TArray<Cardinal>;
    Valid: TBytes;
    Rows: TArray<TFlashTextureRowState>;
  end;

  PFlashFilteredRaster = ^TFlashFilteredRaster;

  TFlashFilteredRaster = record
    Owner: TFlashClip;
    Filters: TSWFFilters;
    Content: TSWFRect;
    Width, Height: Integer;
    Input, Output: TArray<Cardinal>;
    Work, RasterWork: Int64;
    LastUsed: UInt64;
    State: TBytes;
  end;

  PFlashFillHit = ^TFlashFillHit;

  TFlashFillHit = record
    Edges: TArray<TSWFEdge>;
    Indices, Offsets: TArray<Integer>;
    MinY, MaxY, BinScale: Double;
    LastUsed: UInt64;
  end;

  TFlashStrokeHitOutline = record
    Edges: TArray<TSWFEdge>;
    MinY, MaxY: Double;
    Built: Boolean;
  end;

  PFlashStrokeHit = ^TFlashStrokeHit;

  TFlashStrokeHit = record
    Paths: TArray<TSWFStrokePath>;
    Fills: TArray<TSWFFill>;
    Matrix: TSWFMatrix;
    Outlines: TArray<TFlashStrokeHitOutline>;
    EdgeCount: Integer;
    LastUsed: UInt64;
  end;

  TFlashPlayer = class(TAVMHost)
  private
    FClips: TObjectList<TFlashClip>;
    FClipSerial: UInt64;
    FAudio: TFlashAudio;
    FVideoPool: IImagePixelPool;
    FNet: TFlashNetRuntime;
    FGlobalSoundTransform: TFlashSoundTransform;
    FExternalSoundSamples: Integer;
    FLevels: TDictionary<Integer, TFlashClip>;
    FLibraries: TObjectList<TFlashLibrary>;
    FLoads: TList<TFlashLoadRequest>;
    FUnloads: TList<TFlashUnloadRequest>;
    FReadResource: TFlashResourceReader;
    FReadSharedObject: TAVM2SharedReader;
    FWriteSharedObject: TAVM2SharedWriter;
    FOnAVM2Collection: TAVM2CollectionObserver;
    FOnAVM2Reclaim: TAVM2ReclaimObserver;
    FLoadedBytes: Int64;
    FActions: TList<TFlashQueuedAction>;
    FConstructClips: TList<TFlashQueuedConstruct>;
    FDeferFrameActions: Integer;
    FAVM2FrameScriptDepth: Integer;
    FAVM2FrameDepth: Integer;
    FCollectingAVM2Timeline: Boolean;
    FAVM2FrameScriptsChanged: Boolean;
    FRoot, FPressed, FHovered, FTextFocus, FAVM2Stage: TFlashClip;
    FKeys: array[0..255] of Boolean;
    FMouseX, FMouseY, FLastKey: Integer;
    FMouseValid: Boolean;
    FMouseButtons: Byte;
    FAVM2PointerPressed: TAVM2Object;
    FAVM2PointerDown: Boolean;
    FFrameNumber: UInt64;
    FRender: TFlashRenderState;
    FShapeRasters: array[0..127] of TFlashShapeRaster;
    FShapeRasterSpanCount: Integer;
    FTextureSamples: array[0..3] of TFlashTextureSamples;
    FTextureSampleUse: UInt64;
    FFilteredRasters: array[0..63] of TFlashFilteredRaster;
    FFilteredPixels: Integer;
    FFilterSequence: UInt64;
    FFillHits: array[0..7] of TFlashFillHit;
    FStrokeHits: array[0..15] of TFlashStrokeHit;
    FQuality: TFlashQuality;
    FPreferBest: Boolean;
    FViewportQuad: TSWFCharacter;
    FClipRenderDepth: Integer;
    FSeekGeneration: Integer;
    FUseNewInvalidBounds: Boolean;
    FNativeMethods: TDictionary<string, TAVMValue>;
    FBitmapGlyphs: TObjectDictionary<Integer, TSWFCharacter>;
    FDragClip: TFlashClip;
    FDragLastX, FDragLastY: Integer;
    FDragLocked, FDragConstrained, FUpdatingDrag: Boolean;
    FDragBounds: TSWFRect;
    procedure SetQuality(Value: TFlashQuality);
    procedure SetAVM2CollectionObserver(const Observer: TAVM2CollectionObserver);
    procedure SetAVM2ReclaimObserver(const Observer: TAVM2ReclaimObserver);
    procedure ConfigureSamples;
    procedure BeginRender(Width, Height: Integer; const Stage: TSWFRect; Color: TSWFColorTransform; WithAlpha: Boolean; Quality: TFlashQuality; out Previous: TFlashRenderState);
    procedure EndRender(const Previous: TFlashRenderState);
    procedure ResolveSamples(var Pixels: TArray<Cardinal>);
    procedure UpdateDrag;
    function BitmapTextGlyph(Character: Char): TSWFCharacter;
    function CreateClip: TFlashClip;
    function AddClip(Parent: TFlashClip; const Name: string; Depth: Integer; Character: TSWFCharacter; ReplaceDepth: Boolean = True): TFlashClip;
    function Clip(O: TAVMObject): TFlashClip;
    procedure RegisterFrameExports(MovieLibrary: TFlashLibrary; const Frame: TSWFFrame);
    function ClipFrames(C: TFlashClip): TArray<TSWFFrame>;
    function ClipRoot(C: TFlashClip): TFlashClip;
    function LevelClip(Index: Integer; CreateMissing: Boolean): TFlashClip;
    function LevelClips: TArray<TFlashClip>;
    function HitStage(X, Y: Double): TFlashClip;
    procedure DispatchAVM2Pointer(X, Y: Integer; Valid: Boolean; Previous, Buttons: Byte);
    procedure RunCode(C: TFlashClip; const Code: TBytes; Stack: TList<TAVMValue> = nil; const Pool: TArray<string> = nil);
    procedure CallConstructHandler(C: TFlashClip);
    procedure ConstructClip(C: TFlashClip);
    procedure ReportUncaught(const Value: TAVMValue);
    function ResolveLoaderTarget(const Value: TAVMValue; CreateLevels: Boolean = False): TFlashClip;
    procedure QueueLoad(C: TFlashClip; Loader: TAVMObject; const URL: string);
    procedure ProcessLoads;
    procedure ClearMovie(C: TFlashClip);
    procedure DisconnectMask(C: TFlashClip);
    function SetClipMask(C: TFlashClip; const Args: TArray<TAVMValue>): TAVMValue;
    procedure UnloadEvents(C: TFlashClip);
    procedure UnloadMovie(C: TFlashClip);
    procedure ProcessUnloads(Removals: Boolean; Finalize: Boolean = True);
    procedure FinishInput;
    procedure InitializeTextField(C: TFlashClip);
    function ReadBoundTextVariable(C: TFlashClip): TAVMValue;
    function TextFieldCall(const Name: string; C: TFlashClip; const Args: TArray<TAVMValue>): TAVMValue;
    procedure FinalizeRemoval(C: TFlashClip);
    procedure LoaderEvent(const Request: TFlashLoadRequest; const Name: string; const Args: TArray<TAVMValue>);
    function ResolveClip(Start: TFlashClip; const Value: TAVMValue): TFlashClip;
    function DuplicateClip(Source: TFlashClip; const Name: string; Depth: Integer; Initial: TAVMObject): TFlashClip;
    procedure StepClip(C: TFlashClip; Advance: Boolean);
    procedure ConstructAVM2Clip(C: TFlashClip);
    procedure BroadcastAVM2FrameEvent(Phase: TAVM2FrameEvent);
    procedure CompleteAVM2Frame;
    function AVM2TimelineRoot(LibraryItem: TFlashLibrary): TFlashClip;
    procedure RunAVM2FrameScripts;
    procedure ApplyPendingSeeks(C: TFlashClip);
    procedure ApplyAVM2Goto(C: TFlashClip);
    procedure InitializeAttachedClip(C: TFlashClip; Initial: TAVMObject);
    procedure FlushActions;
    procedure ApplyFrame(C: TFlashClip; Index: Integer; ExecuteActions: Boolean = True; Origins: TDictionary<Integer, Integer> = nil; TargetFrame: Integer = -1; ClipEnds: TDictionary<Integer, Integer> = nil; SeekRatios: TDictionary<Integer, Word> = nil; SeekBlends: TDictionary<Integer, TAVMBitmapBlend> = nil; SeekFilters: TDictionary<Integer, TSWFFilters> = nil);
    procedure SeekBack(C: TFlashClip; Index: Integer);
    procedure RemoveClip(C: TFlashClip);
    procedure Fire(C: TFlashClip; const Name: string; Flags: Cardinal = 0);
    procedure ButtonEvent(C: TFlashClip; Conditions: Word);
    procedure PlaySoundEvent(C: TFlashClip; const Event: TSWFSoundEvent);
    procedure InstallSoundClass;
    function SoundCall(const Name: string; Receiver: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
    procedure LoadSound(Receiver: TAVMObject; const URL: string; Streaming: Boolean);
    procedure AddSoundProperties(Receiver: TAVMObject);
    function SoundLibrary(Owner: TFlashClip): TFlashLibrary;
    function ResolveSoundExport(Owner: TFlashClip; const Name: string): TSWFSound;
    function ReadSoundTransform(Owner: TObject): TFlashSoundTransform;
    procedure UpdateSoundProgress(Client: TObject; Position: UInt32; Finished: Boolean);
    function FindFillHit(Shape: TSWFCharacter): PFlashFillHit;
    function PointInShapeFill(Shape: TSWFCharacter; X, Y: Double; DrawingClip: TFlashClip): Boolean;
    function FindStrokeHit(Shape: TSWFCharacter; const Matrix: TSWFMatrix): PFlashStrokeHit;
    function PointOnStroke(Shape: TSWFCharacter; const M: TSWFMatrix; X, Y: Double; DrawingClip: TFlashClip): Boolean;
    function ContainsPoint(C: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; HitState: Boolean; IgnoreVisibility: Boolean = False; MaskGeometry: Boolean = False; MaskRoot: Boolean = False; Depth: Integer = 0): Boolean;
    function PointInMask(Mask: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; Depth: Integer = 0): Boolean;
    function PointChildren(C: TFlashClip; X, Y: Double; const Matrix: TSWFMatrix; HitState: Boolean; Depth: Integer = 0): TArray<TFlashClip>;
    procedure RenderStaticText(C: TFlashClip; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    procedure Broadcast(const Name: string; Flags: Cardinal = 0);
    function Hit(C: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; RequireInteractive: Boolean = True): TFlashClip;
    procedure AddDrawingEdge(C: TFlashClip; X1, Y1, X2, Y2: Double);
    procedure CloseDrawingContour(C: TFlashClip);
    procedure SetDrawingFill(C: TFlashClip; const Style: TSWFFill; Enabled: Boolean);
    procedure SetDrawingLine(C: TFlashClip; const Style: TSWFFill; Enabled: Boolean);
    function ReadDrawingGradient(const Args: TArray<TAVMValue>; out Style: TSWFFill): Boolean;
    function ReadGradientMatrix(const Value: TAVMValue): TSWFMatrix;
    function ReadDrawingLine(const Args: TArray<TAVMValue>): TSWFFill;
    function ReadDrawingColor(const RGB, Alpha: TAVMValue): Cardinal;
    function DrawingOption(const Value: TAVMValue): string;
    procedure AddDrawingBounds(C: TFlashClip; const Bounds: TSWFBounds);
    function WorldMatrix(C: TFlashClip; IncludeOwnScroll: Boolean = True): TSWFMatrix;
    function ScrollRectProperty(C: TFlashClip; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
    function BoundsWithMatrix(C: TFlashClip; const Matrix: TSWFMatrix; IgnoreStrokes: Boolean; PendingScroll: Boolean = False; IncludeFilters: Boolean = False; UseMorphRatio: Boolean = False): TSWFBounds;
    procedure SetDisplaySize(C: TFlashClip; Value: Double; IsWidth: Boolean);
    function SlashPath(C: TFlashClip): string;
    procedure ResolveIndexedProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Target: TFlashClip; out PropertyIndex: Integer);
    procedure RenderClip(C: TFlashClip; const ParentMatrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    procedure RenderClipWithMask(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    function FindFilteredRaster(C: TFlashClip): PFlashFilteredRaster;
    function FilteredLayerState(C: TFlashClip; const Matrix: TSWFMatrix; const Stage: TSWFRect; Opacity: Double): TBytes;
    procedure FilterLayer(C: TFlashClip; var Layer: TArray<Cardinal>; Width, Height: Integer; const Content: TSWFRect; const Filters: TSWFFilters; const State: TBytes; RasterWork: Int64);
    procedure RenderClipGroup(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    function EnsureSampleDetail(Index: Integer; Color: Cardinal): Integer;
    function CoverageAt(Index: Integer): Word;
    procedure RenderClipBody(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    procedure RenderClipVideo(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    function VideoBitmap(C: TFlashClip; var Work: Int64): IImagePixelBuffer;
    function RenderMask(C: TFlashClip; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>; ScriptSource: Boolean = False): TBytes;
    procedure AllocateCoverage(out Coverage: TBytes);
    function ResolveDrawPath(const Path: string): TFlashClip;
    function ScriptMaskMatrix(C: TFlashClip): TSWFMatrix;
    function RenderRectCoverage(const Rect: TSWFRect; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>): TBytes;
    function RenderScrollCoverage(C: TFlashClip; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>): TBytes;
    procedure RenderClipViewport(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
    procedure PlotPixel(Index: Integer; Color: Cardinal; Opacity: Double; var Pixels: TArray<Cardinal>; Coverage: Word);
    function FindShapeRaster(Shape: TSWFCharacter; const Matrix: TSWFMatrix; Glyph: Boolean): PFlashShapeRaster;
    procedure RenderShape(Shape: TSWFCharacter; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>; ColorOverride: Int64 = -1; LibraryMovie: TSWFMovie = nil; DrawingClip: TFlashClip = nil);
    procedure RenderBitmap(Width, Height: Integer; const ImagePixels: TArray<Cardinal>; const Matrix: TSWFMatrix; Smooth, Premultiplied: Boolean; Opacity: Double; var Pixels: TArray<Cardinal>; SnapPixels: Boolean = True; SourceOpaque: Boolean = False);
    function ReadBitmapFillMatrix(const Value: TAVMValue): TSWFMatrix;
    procedure AttachBitmap(C: TFlashClip; const Args: TArray<TAVMValue>);
    procedure BeginBitmapFill(C: TFlashClip; const Args: TArray<TAVMValue>);
    procedure RenderText(C: TFlashClip; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
  public
    Movie: TSWFMovie;
    VM: TAVM1;
    constructor Create(const Data: TBytes; const Origin: string = ''; const Resources: TFlashResourceReader = nil);
    destructor Destroy; override;
    function GetMember(O: TAVMObject; const RequestedName: string; out Value: TAVMValue): Boolean; override;
    function GetStoredMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean; override;
    function SetMember(O: TAVMObject; const RequestedName: string; const Value: TAVMValue): Boolean; override;
    function CallNative(const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue; override;
    function StringValue(O: TAVMObject; out Text: string): Boolean; override;
    function ObjectType(O: TAVMObject): string; override;
    function LevelObject(Index: Integer): TAVMObject; override;
    function ColorTarget(const Value: TAVMValue): TAVMObject; override;
    procedure MarkColorTarget(O: TAVMObject); override;
    function ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean; override;
    procedure WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform); override;
    function BindTransformReference(O: TAVMObject; out Path: string): TAVMObject; override;
    function ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject; override;
    function DisplayParent(O: TAVMObject): TAVMObject; override;
    function ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean; override;
    procedure WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix); override;
    function DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean; override;
    function ReadLibraryBitmap(const Name: string): IImagePixelBuffer; override;
    function DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer; override;
    procedure ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter); override;
    function BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect; override;
    function ActionGetProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Value: TAVMValue): Boolean; override;
    function ActionSetProperty(Start: TAVMObject; const Path, Index, Value: TAVMValue): Boolean; override;
    function ResolveDragTarget(Start: TAVMObject; const Value: TAVMValue): TAVMObject; override;
    procedure StartDrag(Target: TAVMObject; LockCenter: Boolean; const Bounds: TArray<Double>); override;
    procedure StopDrag; override;
    procedure StopSounds; override;
    procedure ToggleQuality; override;
    function ResolveTimelineTarget(Start: TAVMObject; const Path: string): TAVMObject; override;
    procedure Timeline(Target: TAVMObject; const Command: string; const Value: TAVMValue); override;
    procedure CallFrame(Target: TAVMObject; const Value: TAVMValue; Stack: TList<TAVMValue>; const Pool: TArray<string>); override;
    procedure VisitRoots(const Visit: TProc<TAVMObject>); override;
    procedure VisitObjectReferences(O: TAVMObject; const Visit: TProc<TAVMObject>); override;
    procedure SweepUnreachable; override;
    procedure Tick;
    procedure Key(Code: Integer; Pressed: Boolean);
    procedure Pointer(X, Y: Integer; Valid: Boolean; Buttons: Byte);
    procedure ClearInput;
    function Render: TArray<Cardinal>;
    function MixAudio(Frames: Integer): TArray<SmallInt>;
    property FrameNumber: UInt64 read FFrameNumber;
    property Quality: TFlashQuality read FQuality write SetQuality;
    property OnAVM2Collection: TAVM2CollectionObserver read FOnAVM2Collection write SetAVM2CollectionObserver;
    property OnAVM2Reclaim: TAVM2ReclaimObserver read FOnAVM2Reclaim write SetAVM2ReclaimObserver;
    property RootClip: TFlashClip read FRoot;
    property ReadSharedObject: TAVM2SharedReader read FReadSharedObject write FReadSharedObject;
    property WriteSharedObject: TAVM2SharedWriter read FWriteSharedObject write FWriteSharedObject;
  end;

implementation

uses
  System.StrUtils, System.Generics.Defaults, Media.Font.Bitmap, Flash.Filters,
  AVM1.Names, AVM1.Coercion, AVM1.Filters, AVM1.Transforms, AVM1.Trigonometry,
  AVM1.Numeric, AVM1.Broadcaster, AVM1.TextFormat, AVM1.BitmapData,
  Audio.MP3.Metadata;

const
  FlashLibraryMemoryLimit = 256 * 1024 * 1024;
  AVM2ScriptDepth = 65536;
  FlashCachedShapeMinEdges = 24;
  FlashCachedShapeWays = 4;
  FlashCachedShapeTotalSpans = 2 * 1024 * 1024;
  FlashCachedShapeStyleLimit = 512;
  FlashCachedShapeSpanLimit = 131072;
  FlashTextureCacheMinSourcePixels = 64 * 1024;
  FlashTextureCacheMaxSourcePixels = 1024 * 1024;
  FlashTextureCacheMaxTargetPixels = 512 * 1024;
  FlashFillHitBins = 64;
  FlashFillHitMinEdges = 1024;
  FlashFillHitMaxEdges = 131072;
  FlashStrokeHitMinPaths = 16;
  FlashStrokeHitMaxPaths = 1024;
  FlashStrokeHitMaxEdges = 32768;

type
  TFlashAVM2Display = class(TAVM2DisplayHost)
  private
    FPlayer: TFlashPlayer;
    FRoot: TFlashClip;
    function FindSound(const ClassName: string): TSWFSound;
  public
    constructor Create(Player: TFlashPlayer; Root: TFlashClip);
    function CreateStage: TObject; override;
    function EmbeddedBytes(const ClassName: string; out Data: TBytes): Boolean; override;
    function MovieBytes: TBytes; override;
    function LoadTimeline(const Data: TBytes; out Info: TAVM2LoadedMovie): TObject; override;
    procedure StopTimeline(Display: TObject); override;
    function SoundLength(const ClassName: string): Double; override;
    function StartSound(const ClassName: string; Channel: TAVM2Object; Start: Double; Loops: Integer): Boolean; override;
    procedure StopSound(Channel: TAVM2Object); override;
    function EmbeddedBitmap(const ClassName: string): IImagePixelBuffer; override;
    procedure AttachBitmap(Display: TObject; const Buffer: IImagePixelBuffer; Smooth: Boolean); override;
    procedure BeginBitmapFill(Display: TObject; const Buffer: IImagePixelBuffer; const Matrix: TAVM2Matrix; RepeatFill, Smoothing: Boolean); override;
    procedure DrawBitmap(const Target: IImagePixelBuffer; Source: TAVM2Object; const Options: TAVM2BitmapDraw); override;
    function GetColorTransform(Display: TObject): TSWFColorTransform; override;
    procedure SetColorTransform(Display: TObject; const Value: TSWFColorTransform); override;
    function GetFilters(Display: TObject): TSWFFilters; override;
    procedure SetFilters(Display: TObject; const Filters: TSWFFilters); override;
    procedure SetMask(Display, Mask: TObject); override;
    procedure InitializeText(Display: TObject); override;
    function GetTextProperty(Display: TObject; const Name: string; out Value: TAVM2Value): Boolean; override;
    function SetTextProperty(Display: TObject; const Name: string; const Value: TAVM2Value): Boolean; override;
    procedure SetTextFormat(Display: TObject; Format: TAVM2Object; First, Last: Integer); override;
    function CreateDisplay(Document: Boolean; const Classes: TArray<string>; out Name: string): TObject; override;
    procedure Place(Child, Parent: TObject; Position: Integer); override;
    procedure RequestFrameScript(Display: TObject; Frame: Integer); override;
    procedure SetPlaying(Display: TObject; Playing: Boolean); override;
    function GotoFrame(Display: TObject; const Target, Scene: string; HasScene, Playing: Boolean): Boolean; override;
    function TimelineFrame(Display: TObject; Total: Boolean): Integer; override;
    function TimelineLabels(Display: TObject): TArray<TAVM2FrameLabel>; override;
    procedure SetProperty(Display: TObject; const Name: string; Value: Double); override;
    procedure Draw(Display: TObject; Command: TAVM2DisplayMethod; const Args: TArray<Double>); override;
    procedure TransformPoint(Display: TObject; ToGlobal: Boolean; var X, Y: Double); override;
    function GetScrollRect(Display: TObject; out Rect: TAVM2Rectangle): Boolean; override;
    procedure SetScrollRect(Display: TObject; Enabled: Boolean; const Rect: TAVM2Rectangle); override;
    function GetMatrix(Display: TObject; Concatenated, OnStage: Boolean): TAVM2Matrix; override;
    procedure SetMatrix(Display: TObject; const Matrix: TAVM2Matrix; out X, Y, ScaleX, ScaleY, Rotation: Double); override;
    function HitTestPoint(Display: TObject; X, Y: Double; Shape, OnStage: Boolean): Boolean; override;
    function HitTestObject(Display, Other: TObject): Boolean; override;
    function GetBounds(Display, Target: TObject; IgnoreStrokes, PixelBounds: Boolean): TAVM2Rectangle; override;
    function DisplayChildren(Display: TObject): TArray<TAVM2TimelineChild>; override;
  end;

  TFlashSoundState = class
  public
    Player: TFlashPlayer;
    HasTarget: Boolean;
    TargetPath: string;
    Sound: TSWFSound;
    ExternalSound: TSWFSound;
    external, Streaming, Loading, AutoPlay: Boolean;
    BytesLoaded: Integer;
    ExternalTransform: TFlashSoundTransform;
    Generation: UInt64;
    Position, Duration: UInt32;
    destructor Destroy; override;
    procedure ReleaseExternal;
  end;

constructor TFlashAVM2Display.Create(Player: TFlashPlayer; Root: TFlashClip);
begin
  inherited Create;
  FPlayer := Player;
  FRoot := Root;
end;

function TFlashAVM2Display.CreateStage: TObject;
var
  Stage: TFlashClip;
begin
  Result := nil;
  if FRoot <> FPlayer.FRoot then
    Exit;
  Stage := FPlayer.FAVM2Stage;
  if Stage = nil then
  begin
    Stage := FPlayer.CreateClip;
    Stage.HasAVM2Handle := True;
    Stage.MovieLibrary := FRoot.MovieLibrary;
    Stage.Script := FPlayer.VM.NewObject('MovieClip');
    Stage.Script.HostData := Stage;
    Stage.Children.Add(FRoot);
    FRoot.Parent := Stage;
    FRoot.Depth := AVM2ScriptDepth;
    FPlayer.FAVM2Stage := Stage;
  end;
  Result := Stage;
end;

function TFlashAVM2Display.EmbeddedBytes(const ClassName: string; out Data: TBytes): Boolean;
var
  Id: Integer;
  Movie: TSWFMovie;
begin
  Movie := FRoot.MovieLibrary.Movie;
  Result := Movie.AVM2ExportNames.TryGetValue(ClassName, Id) and Movie.BinaryAssets.TryGetValue(Id, Data);
end;

function TFlashAVM2Display.MovieBytes: TBytes;
begin
  Result := FRoot.MovieLibrary.Movie.AVM2MovieBytes;
end;

function TFlashAVM2Display.LoadTimeline(const Data: TBytes; out Info: TAVM2LoadedMovie): TObject;
var
  LibraryItem: TFlashLibrary;
  Clip: TFlashClip;
  LibraryBytes: Int64;
begin
  Result := nil;
  Info := Default(TAVM2LoadedMovie);
  if FPlayer.FLibraries.Count >= 64 then
    Exit;
  try
    LibraryItem := TFlashLibrary.Create(Data, FRoot.MovieLibrary.URI);
  except
    on ESWFError do
      Exit;
  end;
  try
    // Scriptless AS3 timelines can be wrapped by the Loader's own runtime.
    if not LibraryItem.Movie.UsesAVM2 or (LibraryItem.Movie.DocumentClass <> '') or
      (Length(LibraryItem.Movie.Frames) = 0) then
      Exit;
    for var Frame in LibraryItem.Movie.Frames do
      for var Tag in Frame.Tags do
        if Tag.Code in [72, 82] then
          Exit;
    LibraryBytes := Int64(LibraryItem.Movie.DecodedSize) + LibraryItem.Movie.BitmapMemorySize +
      LibraryItem.Movie.SoundMemorySize;
    if FPlayer.FLoadedBytes + Int64(FPlayer.FExternalSoundSamples) * SizeOf(SmallInt) +
      LibraryBytes > FlashLibraryMemoryLimit then
      Exit;
    Clip := FPlayer.CreateClip;
    Clip.MovieLibrary := LibraryItem;
    Clip.MovieRoot := True;
    Clip.CreatedFrame := FPlayer.FFrameNumber;
    Clip.Script := FPlayer.VM.NewObject('MovieClip');
    Clip.Script.HostData := Clip;
    LibraryItem.Root := Clip;
    FPlayer.FLibraries.Add(LibraryItem);
    Inc(FPlayer.FLoadedBytes, LibraryBytes);
    Info.Width := LibraryItem.Movie.Width;
    Info.Height := LibraryItem.Movie.Height;
    Info.Version := LibraryItem.Movie.Version;
    Info.FrameRate := LibraryItem.Movie.FPS;
    LibraryItem := nil;
    try
      FPlayer.StepClip(Clip, False);
    except
      on ESWFError do
      begin
        FPlayer.RemoveClip(Clip);
        Clip.MovieLibrary.Root := nil;
        Exit;
      end;
    end;
    Clip.HasAVM2Handle := True;
    Result := Clip;
  finally
    LibraryItem.Free;
  end;
end;

procedure TFlashAVM2Display.StopTimeline(Display: TObject);
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  if Clip = nil then
    Exit;
  Clip.Playing := False;
  FPlayer.FAudio.StopOwner(Clip);
  for var Child in Clip.Children do
    StopTimeline(Child);
end;

function TFlashAVM2Display.FindSound(const ClassName: string): TSWFSound;
var
  Id: Integer;
  Movie: TSWFMovie;
begin
  Result := nil;
  Movie := FRoot.MovieLibrary.Movie;
  if Movie.AVM2ExportNames.TryGetValue(ClassName, Id) then
    Movie.Sounds.TryGetValue(Id, Result);
end;

function TFlashAVM2Display.SoundLength(const ClassName: string): Double;
var
  Sound: TSWFSound;
begin
  Sound := FindSound(ClassName);
  Result := 0;
  if Sound <> nil then
    Result := 1000.0 * Sound.FrameCount / Sound.SampleRate;
end;

function TFlashAVM2Display.StartSound(const ClassName: string; Channel: TAVM2Object; Start: Double; Loops: Integer): Boolean;
var
  Sound: TSWFSound;
  Info: TSWFSoundInfo;
begin
  Sound := FindSound(ClassName);
  if (Sound = nil) or (Start >= 1000.0 * Sound.FrameCount / Sound.SampleRate) then
    Exit(False);
  Info := Default(TSWFSoundInfo);
  Info.First := Trunc(Start * SWFSoundRate / 1000.0);
  Info.Loops := Min(Loops, High(Integer) - 1) + 1;
  Result := FPlayer.FAudio.Start(Sound, Channel, Info, Channel);
end;

procedure TFlashAVM2Display.StopSound(Channel: TAVM2Object);
begin
  FPlayer.FAudio.StopOwner(Channel);
end;

function TFlashAVM2Display.EmbeddedBitmap(const ClassName: string): IImagePixelBuffer;
var
  Movie: TSWFMovie;
  Definition: TSWFCharacter;
  Id, X, Y: Integer;
begin
  Result := nil;
  Movie := FRoot.MovieLibrary.Movie;
  if not Movie.AVM2ExportNames.TryGetValue(ClassName, Id) or
    not Movie.Characters.TryGetValue(Id, Definition) or (Definition.BitmapWidth = 0) then
    Exit;
  Result := FPlayer.FVideoPool.Allocate(Definition.BitmapWidth, Definition.BitmapHeight, True, 0);
  if Result <> nil then
    for Y := 0 to Definition.BitmapHeight - 1 do
      for X := 0 to Definition.BitmapWidth - 1 do
        Result.SetPixel(X, Y, Definition.BitmapPixels[Y * Definition.BitmapWidth + X]);
end;

procedure TFlashAVM2Display.AttachBitmap(Display: TObject; const Buffer: IImagePixelBuffer; Smooth: Boolean);
var
  Clip: TFlashClip;
  Bounds: TSWFRect;
begin
  Clip := TFlashClip(Display);
  Clip.AttachedBitmap := Buffer;
  Clip.AttachedBitmapSmooth := Smooth;
  Clip.AttachedBitmapBounds := TSWFBounds.Empty;
  if Buffer <> nil then
  begin
    Bounds := Default(TSWFRect);
    Bounds.Right := Buffer.Width * 20;
    Bounds.Bottom := Buffer.Height * 20;
    Clip.AttachedBitmapBounds := TSWFBounds.FromRect(Bounds);
  end;
end;

procedure TFlashAVM2Display.BeginBitmapFill(Display: TObject; const Buffer: IImagePixelBuffer; const Matrix: TAVM2Matrix; RepeatFill, Smoothing: Boolean);
var
  Style: TSWFFill;
begin
  Style := Default(TSWFFill);
  Style.BitmapData := Buffer;
  Style.BitmapRepeat := RepeatFill;
  Style.BitmapSmooth := Smoothing;
  Style.BitmapMatrix.A := SWFFloat32(Matrix.A * 20);
  Style.BitmapMatrix.B := SWFFloat32(Matrix.B * 20);
  Style.BitmapMatrix.C := SWFFloat32(Matrix.C * 20);
  Style.BitmapMatrix.D := SWFFloat32(Matrix.D * 20);
  Style.BitmapMatrix.TX := SWFTwipsFromPixels(Matrix.TX);
  Style.BitmapMatrix.TY := SWFTwipsFromPixels(Matrix.TY);
  FPlayer.SetDrawingFill(TFlashClip(Display), Style, True);
end;

procedure TFlashAVM2Display.DrawBitmap(const Target: IImagePixelBuffer; Source: TAVM2Object; const Options: TAVM2BitmapDraw);
var
  Drawing: TAVMBitmapDrawOptions;
  SourceValue: TAVMValue;
  I: Integer;
begin
  Drawing := Default(TAVMBitmapDrawOptions);
  Drawing.Matrix.A := Options.Matrix.A;
  Drawing.Matrix.B := Options.Matrix.B;
  Drawing.Matrix.C := Options.Matrix.C;
  Drawing.Matrix.D := Options.Matrix.D;
  Drawing.Matrix.TX := SWFTwipsFromPixels(Options.Matrix.TX);
  Drawing.Matrix.TY := SWFTwipsFromPixels(Options.Matrix.TY);
  for I := 0 to 3 do
  begin
    Drawing.ColorTransform.Mult[I] := Options.Color[I];
    if not IsNan(Options.Color[I + 4]) then
      Drawing.ColorTransform.Add[I] := Trunc(EnsureRange(Options.Color[I + 4], -65535.0, 65535.0));
  end;
  Drawing.HasClip := Options.HasClip;
  Drawing.Smooth := Options.Smooth;
  if Options.HasClip then
  begin
    Drawing.ClipRect.Left := SWFTwipsFromPixels(Options.Clip.X);
    Drawing.ClipRect.Top := SWFTwipsFromPixels(Options.Clip.Y);
    Drawing.ClipRect.Right := SWFTwipsFromPixels(Options.Clip.Right);
    Drawing.ClipRect.Bottom := SWFTwipsFromPixels(Options.Clip.Bottom);
  end;
  I := IndexText(Options.Blend, ['normal', 'layer', 'multiply', 'screen', 'lighten', 'darken',
      'difference', 'add', 'subtract', 'invert', 'alpha', 'erase', 'overlay', 'hardlight']);
  if I >= 0 then
    Drawing.Blend := TAVMBitmapBlend(I);
  if Source.BitmapData <> nil then
    SourceValue := AVMBitmapReference(FPlayer.VM, Source.BitmapData)
  else
    SourceValue := TAVMValue.Ref(TFlashClip(Source.DisplayData).Script);
  FPlayer.DrawBitmapData(Target, SourceValue, Drawing);
end;

function TFlashAVM2Display.GetColorTransform(Display: TObject): TSWFColorTransform;
begin
  Result := TSWFColorTransform.Identity;
  if Display <> nil then
    Result := TFlashClip(Display).ColorTransform;
end;

procedure TFlashAVM2Display.SetColorTransform(Display: TObject; const Value: TSWFColorTransform);
begin
  if Display <> nil then
    TFlashClip(Display).ColorTransform := Value;
end;

function TFlashAVM2Display.GetFilters(Display: TObject): TSWFFilters;
begin
  Result := nil;
  if Display <> nil then
    Result := TFlashClip(Display).Filters;
end;

procedure TFlashAVM2Display.SetFilters(Display: TObject; const Filters: TSWFFilters);
begin
  if Display <> nil then
    TFlashClip(Display).Filters := Filters;
end;

procedure TFlashAVM2Display.SetMask(Display, Mask: TObject);
var
  Value: TAVMValue;
begin
  Value := TAVMValue.Ref(nil);
  if Mask <> nil then
    Value := TAVMValue.Ref(TFlashClip(Mask).Script);
  FPlayer.SetClipMask(TFlashClip(Display), [Value]);
end;

procedure TFlashAVM2Display.InitializeText(Display: TObject);
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  Clip.TextWidth := 100;
  Clip.TextHeight := 100;
  Clip.TextSize := 12;
  Clip.TextColor := $FF000000;
  FPlayer.InitializeTextField(Clip);
end;

function TFlashAVM2Display.GetTextProperty(Display: TObject; const Name: string; out Value: TAVM2Value): Boolean;
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  Result := True;
  if Name = 'text' then
    Value := TAVM2Value.Str(Clip.Text)
  else if Name = 'htmlText' then
    Value := TAVM2Value.Str(Clip.HTMLText)
  else if Name = 'length' then
    Value := TAVM2Value.Num(Length(Clip.Text), a2Int)
  else if Name = 'width' then
    Value := TAVM2Value.Num(Clip.TextWidth)
  else if Name = 'height' then
    Value := TAVM2Value.Num(Clip.TextHeight)
  else if Name = 'textColor' then
    Value := TAVM2Value.Num(Cardinal(Trunc(Clip.TextDocument.DefaultFormat.Values[2].Number)) and $FFFFFF, a2UInt)
  else if Name = 'multiline' then
    Value := TAVM2Value.Num(Ord(Clip.TextMultiline), a2Boolean)
  else if Name = 'type' then
  begin
    if Clip.IsEditable then
      Value := TAVM2Value.Str('input')
    else
      Value := TAVM2Value.Str('dynamic');
  end
  else
    Result := False;
end;

procedure TFlashAVM2Display.SetTextFormat(Display: TObject; Format: TAVM2Object; First, Last: Integer);
var
  Clip: TFlashClip;
  Data: TAVMTextFormatData;
  Value: TAVM2Value;
  I: Integer;
begin
  if Format = nil then
    Exit;
  Clip := TFlashClip(Display);
  Data := TAVMTextFormatData.Create;
  try
    for I := Low(AVMFormatNames) to High(AVMFormatNames) do
      if Format.Props.TryGetValue(#0 + AVMFormatNames[I], Value) then
        case Value.Kind of
          a2String:
            Data.Values[I] := TAVMValue.Str(Value.Text);
          a2Boolean:
            Data.Values[I] := TAVMValue.Bool(Value.Number <> 0);
          a2Int, a2UInt, a2Number:
            Data.Values[I] := TAVMValue.Num(Value.Number);
        end;
    if First < 0 then
      Clip.TextDocument.SetDefault(Data)
    else
    begin
      if Last < 0 then
        Last := Length(Clip.Text);
      Clip.TextDocument.SetFormat(First, Last, Data);
    end;
  finally
    Data.Free;
  end;
end;

function TFlashAVM2Display.SetTextProperty(Display: TObject; const Name: string; const Value: TAVM2Value): Boolean;
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  Result := True;
  if Name = 'text' then
    Clip.Text := Value.Text
  else if Name = 'htmlText' then
    Clip.HTMLText := Value.Text
  else if Name = 'multiline' then
  begin
    Clip.TextMultiline := Value.Number <> 0;
    Clip.TextDocument.Multiline := Clip.TextMultiline;
  end
  else if Name = 'type' then
    Clip.IsEditable := Value.Text = 'input'
  else if Name = 'textColor' then
    FPlayer.TextFieldCall('set.textColor', Clip, [TAVMValue.Num(Value.Number)])
  else if Name = 'defaultTextFormat' then
  begin
    SetTextFormat(Display, Value.Obj, -1, -1);
    Result := False;
  end
  else
    Result := False;
end;

function TFlashAVM2Display.CreateDisplay(Document: Boolean; const Classes: TArray<string>; out Name: string): TObject;
var
  Clip: TFlashClip;
  Definition: TSWFCharacter;
  ClassName: string;
  Id: Integer;
begin
  Name := '';
  if Document then
  begin
    FRoot.HasAVM2Handle := True;
    Exit(FRoot);
  end;
  Clip := FPlayer.CreateClip;
  Clip.HasAVM2Handle := True;
  Clip.MovieLibrary := FRoot.MovieLibrary;
  Clip.CreatedFrame := FPlayer.FFrameNumber;
  Clip.Script := FPlayer.VM.NewObject('MovieClip');
  Clip.Script.HostData := Clip;
  for ClassName in Classes do
    if Clip.MovieLibrary.Movie.AVM2ExportNames.TryGetValue(ClassName, Id) and
      Clip.MovieLibrary.Movie.Characters.TryGetValue(Id, Definition) and (Definition.Kind = 39) then
    begin
      Clip.Character := Definition;
      Break;
    end;
  Name := 'instance' + UIntToStr(FPlayer.FClipSerial - 1);
  Clip.Name := Name;
  Clip.FrameScriptPending := True;
  if Clip.Character <> nil then
    FPlayer.StepClip(Clip, False);
  Result := Clip;
end;

procedure TFlashAVM2Display.Place(Child, Parent: TObject; Position: Integer);
var
  Clip, OldParent, NewParent, Peer: TFlashClip;
  InsertDepth: Integer;
begin
  Clip := TFlashClip(Child);
  OldParent := Clip.Parent;
  NewParent := TFlashClip(Parent);
  if Clip.Dead or ((NewParent <> nil) and NewParent.Dead) then
    raise ESWFError.Create('Cannot attach removed AVM2 display object');
  if OldParent <> nil then
  begin
    OldParent.Children.Remove(Clip);
    for Peer in OldParent.Children do
      if (Peer.Depth >= AVM2ScriptDepth) and (Peer.Depth > Clip.Depth) then
        Dec(Peer.Depth);
  end;
  Clip.Parent := NewParent;
  if NewParent = nil then
    Exit;
  InsertDepth := AVM2ScriptDepth + Position;
  for Peer in NewParent.Children do
    if Peer.Depth >= InsertDepth then
      Inc(Peer.Depth);
  Clip.Depth := InsertDepth;
  NewParent.Children.Add(Clip);
end;

procedure TFlashAVM2Display.SetProperty(Display: TObject; const Name: string; Value: Double);
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  if Name = 'x' then
    Clip.SetPosition(Value, Clip.Y)
  else if Name = 'y' then
    Clip.SetPosition(Clip.X, Value)
  else if Name = 'scaleX' then
    Clip.SetScale(0, Value)
  else if Name = 'scaleY' then
    Clip.SetScale(1, Value)
  else if Name = 'rotation' then
    Clip.SetRotation(Value)
  else if Name = 'alpha' then
    Clip.Alpha := Value
  else if Name = 'visible' then
    Clip.Visible := Value <> 0
  else if Name = 'width' then
    FPlayer.SetDisplaySize(Clip, Value, True)
  else if Name = 'height' then
    FPlayer.SetDisplaySize(Clip, Value, False);
end;

procedure TFlashAVM2Display.RequestFrameScript(Display: TObject; Frame: Integer);
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  if (FPlayer.FAVM2FrameScriptDepth = 0) and (Frame = Max(0, Clip.Frame)) then
    Clip.FrameScriptPending := True;
end;

procedure TFlashAVM2Display.SetPlaying(Display: TObject; Playing: Boolean);
begin
  TFlashClip(Display).Playing := Playing;
  if not Playing then
    FPlayer.FAudio.StopStream(TFlashClip(Display));
end;

function SceneStart(const Scenes: TArray<TSWFScene>; Frame: Integer): Integer;
var
  Item: TSWFScene;
begin
  Result := 0;
  for Item in Scenes do
    if Item.StartFrame <= Frame then
      Result := Max(Result, Item.StartFrame);
end;

function FindFrameLabel(Clip: TFlashClip; const Frames: TArray<TSWFFrame>; const Name: string): Integer;
var
  Index: Integer;
  Tag: TSWFTag;
  Reader: TSWFReader;
begin
  if Clip.MovieRoot and (Clip.MovieLibrary.Movie.SceneFrameLabels <> nil) and
    Clip.MovieLibrary.Movie.SceneFrameLabels.TryGetValue(Name, Index) then
    Exit(Index);
  for Index := 0 to High(Frames) do
    for Tag in Frames[Index].Tags do
      if Tag.Code = 43 then
      begin
        Reader := TSWFReader.Create(Tag.Data, Clip.MovieLibrary.Movie.Version);
        try
          if Reader.Str = Name then
            Exit(Index);
        finally
          Reader.Free;
        end;
      end;
  Result := -1;
end;

function DecimalFrameNumber(const Text: string; out Number: Int64): Boolean;
var
  Digits: string;
  Index, FirstDigit: Integer;
begin
  Digits := Trim(Text);
  if Digits = '' then
    Exit(False);
  FirstDigit := 1;
  if CharInSet(Digits[1], ['+', '-']) then
    Inc(FirstDigit);
  for Index := FirstDigit to Length(Digits) do
    if not CharInSet(Digits[Index], ['0'..'9']) then
      Exit(False);
  Result := TryStrToInt64(Digits, Number);
end;

function TFlashAVM2Display.GotoFrame(Display: TObject; const Target, Scene: string; HasScene, Playing: Boolean): Boolean;
var
  Clip: TFlashClip;
  Frames: TArray<TSWFFrame>;
  Scenes: TArray<TSWFScene>;
  Entry: TSWFScene;
  Number: Int64;
  Offset, Index, Last, RequestedScene: Integer;
begin
  Clip := TFlashClip(Display);
  Frames := FPlayer.ClipFrames(Clip);
  Last := Max(0, High(Frames));
  if Clip.MovieRoot then
    Scenes := Clip.MovieLibrary.Movie.SceneLabels;
  RequestedScene := -1;
  Offset := SceneStart(Scenes, Max(0, Clip.Frame));
  if HasScene then
  begin
    Offset := 0;
    for Entry in Scenes do
      if Entry.Name = Scene then
      begin
        RequestedScene := Entry.StartFrame;
        Offset := RequestedScene;
        Break;
      end;
  end;
  if DecimalFrameNumber(Target, Number) then
  begin
    if (Number = -Offset) and Clip.ExecutingFrameScript then
      Exit(True);
    Number := EnsureRange(Number, Int64(-65535), Int64(65535));
    Index := EnsureRange(Integer(Number) + Offset - 1, 0, Last);
  end
  else
  begin
    Index := FindFrameLabel(Clip, Frames, Target);
    if HasScene and ((RequestedScene < 0) or (Index < 0) or (SceneStart(Scenes, Index) <> RequestedScene)) then
      Exit(False);
    if Index < 0 then
    begin
      if Clip.MovieLibrary.Movie.Version >= 11 then
        Exit(False);
      if Clip.ExecutingFrameScript then
        Exit(True);
      Index := 0;
    end;
  end;
  Result := True;
  if Clip.Dead or Clip.Removing then
    Exit;
  if Length(Frames) = 0 then
  begin
    SetPlaying(Clip, Playing);
    Exit;
  end;
  Clip.PendingFrame := Index;
  Clip.PendingAVM2Playing := Playing;
  if Clip.ExecutingFrameScript or Clip.ApplyingAVM2Goto then
    Exit;
  FPlayer.ApplyAVM2Goto(Clip);
  if Clip.MovieLibrary.Movie.Version >= 10 then
    FPlayer.CompleteAVM2Frame
  else if Clip.FrameScriptPending and (FPlayer.FAVM2FrameScriptDepth > 0) then
    FPlayer.FAVM2FrameScriptsChanged := True;
end;

function TFlashAVM2Display.TimelineFrame(Display: TObject; Total: Boolean): Integer;
var
  Clip: TFlashClip;
begin
  Clip := TFlashClip(Display);
  if Total then
    Exit(Max(1, Length(FPlayer.ClipFrames(Clip))));
  Result := Max(0, Clip.Frame);
  if Clip.MovieRoot then
    Dec(Result, SceneStart(Clip.MovieLibrary.Movie.SceneLabels, Result));
  Inc(Result);
end;

function TFlashAVM2Display.TimelineLabels(Display: TObject): TArray<TAVM2FrameLabel>;
var
  Clip: TFlashClip;
  Frames: TArray<TSWFFrame>;
  Labels: TList<TAVM2FrameLabel>;
  Entry: TAVM2FrameLabel;
  Tag: TSWFTag;
  Reader: TSWFReader;
  Scene: TSWFScene;
  I, First, Last: Integer;
begin
  Clip := TFlashClip(Display);
  Frames := FPlayer.ClipFrames(Clip);
  First := 0;
  Last := High(Frames);
  if Clip.MovieRoot then
  begin
    First := SceneStart(Clip.MovieLibrary.Movie.SceneLabels, Max(0, Clip.Frame));
    for Scene in Clip.MovieLibrary.Movie.SceneLabels do
      if Scene.StartFrame > First then
        Last := Min(Last, Scene.StartFrame - 1);
  end;
  Labels := TList<TAVM2FrameLabel>.Create;
  try
    for I := First to Last do
      for Tag in Frames[I].Tags do
        if Tag.Code = 43 then
        begin
          Reader := TSWFReader.Create(Tag.Data, Clip.MovieLibrary.Movie.Version);
          try
            Entry.Name := Reader.Str;
            Entry.Frame := I - First + 1;
            Labels.Add(Entry);
          finally
            Reader.Free;
          end;
        end;
    Result := Labels.ToArray;
  finally
    Labels.Free;
  end;
end;

procedure TFlashAVM2Display.TransformPoint(Display: TObject; ToGlobal: Boolean; var X, Y: Double);
var
  Matrix, Inverse: TSWFMatrix;
  OutputX, OutputY: Integer;
begin
  Matrix := TSWFMatrix.Identity;
  if Display <> nil then
    Matrix := FPlayer.WorldMatrix(TFlashClip(Display));
  if not ToGlobal then
  begin
    if SWFInverseMatrix(Matrix, Inverse) then
      Matrix := Inverse
    else
      Matrix := TSWFMatrix.Identity;
  end;
  SWFTransformPoint(Matrix, SWFTwipsFromPixels(X), SWFTwipsFromPixels(Y), OutputX, OutputY);
  X := OutputX / 20;
  Y := OutputY / 20;
end;

function TFlashAVM2Display.GetScrollRect(Display: TObject; out Rect: TAVM2Rectangle): Boolean;
var
  Clip: TFlashClip;
  Bounds: TSWFRect;
begin
  Clip := TFlashClip(Display);
  Result := (Clip <> nil) and Clip.HasScrollRect;
  if not Result then
    Exit;
  Bounds := Clip.NextScrollRect;
  Rect.X := Bounds.Left / 20;
  Rect.Y := Bounds.Top / 20;
  Rect.Width := SWFAddCoordinate(Bounds.Right, SWFAddCoordinate(not Bounds.Left, 1)) / 20;
  Rect.Height := SWFAddCoordinate(Bounds.Bottom, SWFAddCoordinate(not Bounds.Top, 1)) / 20;
end;

procedure TFlashAVM2Display.SetScrollRect(Display: TObject; Enabled: Boolean; const Rect: TAVM2Rectangle);
var
  Clip: TFlashClip;
  Bounds: TSWFRect;

  function RoundedPixelTwips(Value: Double): Integer;
  var
    Pixels: Int64;
    Bits: Cardinal;
  begin
    if IsNan(Value) or IsInfinite(Value) or (Value < -2147483648.5) or (Value >= 2147483647.5) then
      Pixels := Low(Integer)
    else
      Pixels := Round(Value);
    Bits := Cardinal((Pixels * 20) and Int64($FFFFFFFF));
    Move(Bits, Result, SizeOf(Result));
  end;

begin
  Clip := TFlashClip(Display);
  if Clip = nil then
    Exit;
  if Enabled then
  begin
    Bounds.Left := RoundedPixelTwips(Rect.X);
    Bounds.Top := RoundedPixelTwips(Rect.Y);
    Bounds.Right := RoundedPixelTwips(Rect.Right);
    Bounds.Bottom := RoundedPixelTwips(Rect.Bottom);
    Clip.NextScrollRect := Bounds;
  end;
  Clip.HasScrollRect := Enabled;
end;

function TFlashAVM2Display.GetMatrix(Display: TObject; Concatenated, OnStage: Boolean): TAVM2Matrix;
const
  DetachedScale: array[TFlashQuality] of Double = (20, 10, 5, 5, 2.5, 2.5, 1.25, 1.25);
var
  Clip: TFlashClip;
  Matrix: TSWFMatrix;
begin
  Clip := TFlashClip(Display);
  if Clip = nil then
    Matrix := TSWFMatrix.Identity
  else if Concatenated and OnStage then
    Matrix := FPlayer.WorldMatrix(Clip, False)
  else
    Matrix := Clip.Matrix;
  if Concatenated and not OnStage then
  begin
    Matrix.A := SWFFloat32(Matrix.A * DetachedScale[FPlayer.Quality]);
    Matrix.D := SWFFloat32(Matrix.D * DetachedScale[FPlayer.Quality]);
  end;
  Result.A := Matrix.A;
  Result.B := Matrix.B;
  Result.C := Matrix.C;
  Result.D := Matrix.D;
  Result.TX := Matrix.TX / 20;
  Result.TY := Matrix.TY / 20;
end;

procedure TFlashAVM2Display.SetMatrix(Display: TObject; const Matrix: TAVM2Matrix; out X, Y, ScaleX, ScaleY, Rotation: Double);
var
  Clip: TFlashClip;
  Native: TSWFMatrix;
begin
  Clip := TFlashClip(Display);
  Native.A := Matrix.A;
  Native.B := Matrix.B;
  Native.C := Matrix.C;
  Native.D := Matrix.D;
  Native.TX := SWFTwipsFromPixels(Matrix.TX);
  Native.TY := SWFTwipsFromPixels(Matrix.TY);
  Clip.SetMatrix(Native);
  Clip.TransformedByScript := True;
  X := Clip.X;
  Y := Clip.Y;
  ScaleX := Clip.ScaleX;
  ScaleY := Clip.ScaleY;
  Rotation := Clip.Rotation;
end;

function ChildrenInDepthOrder(Clip: TFlashClip): TArray<TFlashClip>;
begin
  Result := Clip.Children.ToArray;
  for var I := 1 to High(Result) do
    if Result[I - 1].Depth >= Result[I].Depth then
    begin
      TArray.Sort<TFlashClip>(Result, TComparer<TFlashClip>.Construct(
        function(const A, B: TFlashClip): Integer
        begin
          Result := CompareValue(A.Depth, B.Depth);
        end));
      Exit;
    end;
end;

function TFlashAVM2Display.DisplayChildren(Display: TObject): TArray<TAVM2TimelineChild>;
var
  Clip, Child: TFlashClip;
  Sorted: TArray<TFlashClip>;
  Entry: TAVM2TimelineChild;
  Count: Integer;
begin
  Clip := TFlashClip(Display);
  if (Clip = nil) or (Clip.Children.Count = 0) then
    Exit(nil);
  Sorted := ChildrenInDepthOrder(Clip);
  SetLength(Result, Length(Sorted));
  Count := 0;
  for Child in Sorted do
  begin
    if Child.Dead or Child.Removing then
      Continue;
    Child.HasAVM2Handle := True;
    Entry.Handle := Child;
    Entry.Name := Child.Name;
    Entry.SymbolClass := '';
    if (Child.Character <> nil) and (Child.MovieLibrary = Clip.MovieLibrary) then
      Child.MovieLibrary.Movie.AVM2SymbolNames.TryGetValue(Child.Character.Id, Entry.SymbolClass);
    Entry.X := Child.X;
    Entry.Y := Child.Y;
    Entry.ScaleX := Child.ScaleX;
    Entry.ScaleY := Child.ScaleY;
    Entry.Rotation := Child.Rotation;
    Entry.Alpha := Child.Alpha;
    Entry.Visible := Child.Visible;
    if Child.IsText then
      Entry.ClassName := 'TextField'
    else if (Child.Character = nil) or (Child.Character.Kind = 39) then
      Entry.ClassName := 'MovieClip'
    else if Child.Character.Kind in [7, 34] then
      Entry.ClassName := 'SimpleButton'
    else if Child.Character.Kind in [46, 84] then
      Entry.ClassName := 'MorphShape'
    else
      Entry.ClassName := 'Shape';
    Result[Count] := Entry;
    Inc(Count);
  end;
  SetLength(Result, Count);
end;

function TFlashAVM2Display.HitTestPoint(Display: TObject; X, Y: Double; Shape, OnStage: Boolean): Boolean;
var
  Clip, Root: TFlashClip;
  PX, PY, GlobalX, GlobalY: Integer;
  Bounds: TSWFBounds;
  Matrix: TSWFMatrix;
begin
  Result := False;
  Clip := TFlashClip(Display);
  if (Clip = nil) or (Shape and not OnStage) then
    Exit;
  if IsNan(X) or IsNan(Y) or IsInfinite(X) or IsInfinite(Y) then
    Exit;
  PX := SWFTwipsFromPixels(X);
  PY := SWFTwipsFromPixels(Y);
  if FRoot = FPlayer.FRoot then
  begin
    // The top-level SWF receives hitTestPoint coordinates in root space.
    Root := FPlayer.ClipRoot(Clip);
    if Root <> nil then
    begin
      SWFTransformPoint(FPlayer.WorldMatrix(Root), PX, PY, GlobalX, GlobalY);
      PX := GlobalX;
      PY := GlobalY;
    end;
  end;
  Bounds := FPlayer.BoundsWithMatrix(Clip, FPlayer.WorldMatrix(Clip, False), False, False, False, True);
  if not Bounds.Valid or (PX < Bounds.Rect.Left) or (PX > Bounds.Rect.Right) or
    (PY < Bounds.Rect.Top) or (PY > Bounds.Rect.Bottom) then
    Exit;
  if not Shape then
    Exit(True);
  Matrix := TSWFMatrix.Identity;
  if Clip.Parent <> nil then
    Matrix := FPlayer.WorldMatrix(Clip.Parent);
  Result := FPlayer.ContainsPoint(Clip, PX / 20, PY / 20, Matrix, False, True);
end;

function TFlashAVM2Display.HitTestObject(Display, Other: TObject): Boolean;
var
  Clip, OtherClip: TFlashClip;
  Bounds, OtherBounds: TSWFBounds;
begin
  Clip := TFlashClip(Display);
  OtherClip := TFlashClip(Other);
  if (Clip = nil) or (OtherClip = nil) then
    Exit(False);
  Bounds := FPlayer.BoundsWithMatrix(Clip, FPlayer.WorldMatrix(Clip, False), False);
  OtherBounds := FPlayer.BoundsWithMatrix(OtherClip, FPlayer.WorldMatrix(OtherClip, False), False);
  Result := Bounds.Valid and OtherBounds.Valid and (Bounds.Rect.Left <= OtherBounds.Rect.Right) and
    (Bounds.Rect.Right >= OtherBounds.Rect.Left) and (Bounds.Rect.Top <= OtherBounds.Rect.Bottom) and
    (Bounds.Rect.Bottom >= OtherBounds.Rect.Top);
end;

function TFlashAVM2Display.GetBounds(Display, Target: TObject; IgnoreStrokes, PixelBounds: Boolean): TAVM2Rectangle;
var
  Clip, TargetClip: TFlashClip;
  Bounds: TSWFBounds;
  Matrix, Inverse: TSWFMatrix;
begin
  Result := Default(TAVM2Rectangle);
  Clip := TFlashClip(Display);
  if Clip = nil then
    Exit;
  if PixelBounds then
    Bounds := FPlayer.BoundsWithMatrix(Clip, FPlayer.WorldMatrix(Clip, False), IgnoreStrokes)
  else
  begin
    Bounds := FPlayer.BoundsWithMatrix(Clip, TSWFMatrix.Identity, IgnoreStrokes);
    TargetClip := TFlashClip(Target);
    if Bounds.Valid and (Clip <> TargetClip) then
    begin
      Matrix := FPlayer.WorldMatrix(Clip);
      if (TargetClip <> nil) and SWFInverseMatrix(FPlayer.WorldMatrix(TargetClip), Inverse) then
        Matrix := Matrix.ThenBy(Inverse);
      Bounds := Bounds.Transformed(Matrix);
    end;
  end;
  if not Bounds.Valid then
    Exit;
  Result.X := Bounds.Rect.Left / 20;
  Result.Y := Bounds.Rect.Top / 20;
  Result.Width := (Int64(Bounds.Rect.Right) - Bounds.Rect.Left) / 20;
  Result.Height := (Int64(Bounds.Rect.Bottom) - Bounds.Rect.Top) / 20;
end;

procedure TFlashAVM2Display.Draw(Display: TObject; Command: TAVM2DisplayMethod; const Args: TArray<Double>);
const
  Diagonal = 0.7071067811865475244;
  Tangent = 0.4142135623730950488;
  Anchors: array[1..8, 0..1] of Double = ((Diagonal, Diagonal), (0, 1),
    (-Diagonal, Diagonal), (-1, 0), (-Diagonal, -Diagonal), (0, -1), (Diagonal, -Diagonal), (1, 0));
  Controls: array[1..8, 0..1] of Double = ((1, Tangent), (Tangent, 1),
    (-Tangent, 1), (-1, Tangent), (-1, -Tangent), (-Tangent, -1), (Tangent, -1), (1, -Tangent));
var
  Clip: TFlashClip;
  Fill: TSWFFill;
  X, Y, W, H, RX, RY: Double;
  Arc: Integer;

  function Arg(Index: Integer; DefaultValue: Double): Double;
  begin
    Result := DefaultValue;
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  function Color(RGB, Alpha: Double): Cardinal;
  begin
    if IsNan(Alpha) then
      Alpha := 0;
    Result := (Cardinal(Trunc(RGB)) and $FFFFFF) or
      (Cardinal(Trunc(EnsureRange(Alpha, 0.0, 1.0) * 255)) shl 24);
  end;

  procedure MoveTo(X, Y: Double);
  begin
    FPlayer.CallNative('MovieClip.moveTo', Clip.Script, [TAVMValue.Num(X), TAVMValue.Num(Y)]);
  end;

  procedure LineTo(X, Y: Double);
  begin
    FPlayer.CallNative('MovieClip.lineTo', Clip.Script, [TAVMValue.Num(X), TAVMValue.Num(Y)]);
  end;

  procedure CurveTo(ControlX, ControlY, X, Y: Double);
  begin
    FPlayer.CallNative('MovieClip.curveTo', Clip.Script, [TAVMValue.Num(ControlX), TAVMValue.Num(ControlY),
        TAVMValue.Num(X), TAVMValue.Num(Y)]);
  end;

begin
  Clip := TFlashClip(Display);
  Fill := Default(TSWFFill);
  case Command of
    adClear:
      FPlayer.CallNative('MovieClip.clear', Clip.Script, nil);
    adBeginFill:
      begin
        Fill.Color := Color(Args[0], Arg(1, 1));
        FPlayer.SetDrawingFill(Clip, Fill, True);
      end;
    adEndFill:
      FPlayer.SetDrawingFill(Clip, Fill, False);
    adMoveTo:
      MoveTo(Args[0], Args[1]);
    adLineTo:
      LineTo(Args[0], Args[1]);
    adCurveTo:
      CurveTo(Args[0], Args[1], Args[2], Args[3]);
    adDrawRect:
      begin
        X := Args[0];
        Y := Args[1];
        W := Args[2];
        H := Args[3];
        MoveTo(X, Y);
        LineTo(X + W, Y);
        LineTo(X + W, Y + H);
        LineTo(X, Y + H);
        LineTo(X, Y);
      end;
    adDrawRoundRect:
      begin
        X := Args[0];
        Y := Args[1];
        W := Args[2];
        H := Args[3];
        if (W <= 0) or (H <= 0) then
          Exit;
        RX := Max(0.0, Min(W, Args[4])) / 2;
        RY := Arg(5, Args[4]);
        if IsNan(RY) then
          RY := Args[4];
        RY := Max(0.0, Min(H, RY)) / 2;
        MoveTo(X + RX, Y);
        LineTo(X + W - RX, Y);
        CurveTo(X + W, Y, X + W, Y + RY);
        LineTo(X + W, Y + H - RY);
        CurveTo(X + W, Y + H, X + W - RX, Y + H);
        LineTo(X + RX, Y + H);
        CurveTo(X, Y + H, X, Y + H - RY);
        LineTo(X, Y + RY);
        CurveTo(X, Y, X + RX, Y);
      end;
    adDrawCircle, adDrawEllipse:
      begin
        if Command = adDrawCircle then
        begin
          X := Args[0];
          Y := Args[1];
          W := Args[2];
          H := W;
        end
        else
        begin
          W := Args[2] / 2;
          H := Args[3] / 2;
          X := Args[0] + W;
          Y := Args[1] + H;
        end;
        MoveTo(X + W, Y);
        for Arc := 1 to 8 do
          CurveTo(X + W * Controls[Arc, 0], Y + H * Controls[Arc, 1],
            X + W * Anchors[Arc, 0], Y + H * Anchors[Arc, 1]);
      end;
    adLineStyle:
      begin
        W := Arg(0, NaN);
        if IsNan(W) then
          FPlayer.SetDrawingLine(Clip, Fill, False)
        else
        begin
          Fill := FPlayer.ReadDrawingLine([TAVMValue.Num(EnsureRange(W, 0.0, 255.0))]);
          Fill.Color := Color(Arg(1, 0), Arg(2, 1));
          FPlayer.SetDrawingLine(Clip, Fill, True);
        end;
      end;
  end;
end;

destructor TFlashSoundState.Destroy;
begin
  ReleaseExternal;
  inherited;
end;

procedure TFlashSoundState.ReleaseExternal;
begin
  if ExternalSound = nil then
    Exit;
  if Player.FAudio <> nil then
    Player.FAudio.StopSound(ExternalSound);
  Dec(Player.FExternalSoundSamples, Length(ExternalSound.Samples));
  if Sound = ExternalSound then
    Sound := nil;
  FreeAndNil(ExternalSound);
end;

constructor TFlashLibrary.Create(const Data: TBytes; const Origin: string);
begin
  inherited Create;
  ExportNames := TDictionary<string, Integer>.Create;
  Symbols := TDictionary<Integer, string>.Create;
  URI := Origin;
  SourceBytes := Length(Data);
  Movie := TSWFMovie.Create(Data);
end;

destructor TFlashLibrary.Destroy;
begin
  AVM2.Free;
  Movie.Free;
  Symbols.Free;
  ExportNames.Free;
  inherited;
end;

function URLLevel(const Target: string; Modern: Boolean; out LevelId: Integer): Boolean;
var
  S: string;
  I, First: Integer;
  Number: Double;
begin
  LevelId := 0;
  Result := False;
  if Copy(Target, 1, 6) <> '_level' then
    Exit;
  S := Copy(Target, 7, MaxInt);
  if Modern then
  begin
    if S = '' then
      Exit(True);
    if (S <> Trim(S)) or not TryStrToFloat(S, Number, TFormatSettings.Invariant) then
      Exit;
    LevelId := AVMLevelNumber(Number);
    Exit(LevelId >= 0);
  end;
  First := 1;
  if (S <> '') and CharInSet(S[1], ['+', '-']) then
    Inc(First);
  if First > Length(S) then
    Exit;
  for I := First to Length(S) do
    if not CharInSet(S[I], ['0'..'9']) then
      Exit;
  Result := TryStrToInt(S, LevelId);
end;

procedure TFlashPlayer.UnloadEvents(C: TFlashClip);
var
  Action: TSWFClipAction;
  Handler: TAVMValue;
begin
  if C.UnloadDispatching or C.Unloaded then
    Exit;
  C.UnloadDispatching := True;
  try
    for Action in C.ClipActions.ToArray do
      if (Action.Events and SWFClipUnload) <> 0 then
      begin
        try
          RunCode(C, Action.Code);
        except
          on E: EAVMThrown do
            ReportUncaught(E.Value);
        end;
      end;
    try
      Handler := VM.Get(C.Script, 'onUnload');
      VM.Call(Handler, C.Script, nil);
    except
      on E: EAVMThrown do
        ReportUncaught(E.Value);
    end;
  finally
    C.UnloadDispatching := False;
  end;
end;

procedure TFlashPlayer.UnloadMovie(C: TFlashClip);
var
  Request: TFlashUnloadRequest;
begin
  if (C = nil) or C.Dead or C.Removing or C.UnloadDispatching then
    Exit;
  if not C.IsLevel then
  begin
    ClearMovie(C);
    C.UnloadGeneration := C.LoadGeneration;
    Exit;
  end;
  Inc(C.LoadGeneration);
  C.UnloadGeneration := C.LoadGeneration;
  Request := Default(TFlashUnloadRequest);
  Request.Clip := C;
  Request.Generation := C.LoadGeneration;
  Request.ReadyFrame := FFrameNumber + 1;
  if FUnloads.Count >= 65536 then
    raise ESWFError.Create('Flash pending unload limit');
  FUnloads.Add(Request);
end;

procedure TFlashPlayer.FinalizeRemoval(C: TFlashClip);
var
  Key: string;
  Value: TAVMValue;
begin
  DisconnectMask(C);
  C.Dead := True;
  C.Removing := False;
  C.AttachedBitmap := nil;
  C.VideoState := Default(TSWFVideoState);
  C.NetStream := nil;
  C.ResetDrawing;
  if C.Parent <> nil then
  begin
    C.Parent.Children.Remove(C);
    if VM.FindOwnKey(C.Parent.Script, C.Name, Key) then
    begin
      Value := VM.GetData(C.Parent.Script, Key);
      if Value.Obj = C.Script then
        C.Parent.Script.RemoveData(Key);
    end;
  end;
end;

procedure TFlashPlayer.ProcessUnloads(Removals: Boolean; Finalize: Boolean);
var
  Requests: TArray<TFlashUnloadRequest>;
  Request: TFlashUnloadRequest;
  I: Integer;
begin
  Requests := FUnloads.ToArray;
  FUnloads.Clear;
  for I := 0 to High(Requests) do
  begin
    Request := Requests[I];
    if Request.Clip.Dead then
      Continue;
    if (Request.Remove <> Removals) or (Request.ReadyFrame > FFrameNumber) then
    begin
      FUnloads.Add(Request);
      Continue;
    end;
    if Request.Clip.LoadGeneration <> Request.Generation then
      Continue;
    if Request.Remove then
    begin
      if not Request.Delivered then
        UnloadEvents(Request.Clip);
      Request.Delivered := True;
      if Finalize then
        FinalizeRemoval(Request.Clip)
      else
        FUnloads.Add(Request);
    end
    else
      ClearMovie(Request.Clip);
  end;
end;

function TFlashPlayer.ClipRoot(C: TFlashClip): TFlashClip;
var
  Top: TFlashClip;
begin
  Top := C;
  while Top.Parent <> nil do
    Top := Top.Parent;
  if Top.IsLevel and (Top.MovieLibrary = C.MovieLibrary) then
    Result := Top
  else
    Result := C.MovieLibrary.Root;
end;

function TFlashPlayer.LevelClip(Index: Integer; CreateMissing: Boolean): TFlashClip;
var
  Context: TFlashLibrary;
  ConstructorValue: TAVMValue;
begin
  if FLevels.TryGetValue(Index, Result) then
    Exit;
  Result := nil;
  if not CreateMissing then
    Exit;
  if (FLevels.Count >= 1024) or (FClips.Count >= 65536) then
    raise ESWFError.Create('Flash level/display limit');
  Context := FRoot.MovieLibrary;
  if VM.MovieContext is TFlashLibrary then
    Context := TFlashLibrary(VM.MovieContext);
  Result := CreateClip;
  Result.MovieLibrary := Context;
  Result.IsLevel := True;
  Result.LevelIndex := Index;
  Result.Depth := Index;
  Result.CreatedFrame := FFrameNumber;
  Result.Started := True;
  Result.Script := VM.NewObject('MovieClip');
  Result.Script.HostData := Result;
  ConstructorValue := VM.GetSpecial(VM.Global, 'MovieClip');
  VM.PutData(Result.Script, '__proto__', VM.GetData(ConstructorValue.Obj, 'prototype'));
  FLevels.Add(Index, Result);
end;

function TFlashPlayer.LevelObject(Index: Integer): TAVMObject;
var
  C: TFlashClip;
begin
  Result := nil;
  C := LevelClip(Index, False);
  if C <> nil then
    Result := C.Script;
end;

function TFlashPlayer.LevelClips: TArray<TFlashClip>;
var
  Keys: TArray<Integer>;
  I: Integer;
begin
  Keys := FLevels.Keys.ToArray;
  TArray.Sort<Integer>(Keys);
  SetLength(Result, Length(Keys));
  for I := 0 to High(Keys) do
  begin
    Result[I] := FLevels[Keys[I]];
    if (Result[I] = FRoot) and (FAVM2Stage <> nil) then
      Result[I] := FAVM2Stage;
  end;
end;

function TFlashPlayer.HitStage(X, Y: Double): TFlashClip;
var
  Roots: TArray<TFlashClip>;
  I: Integer;
begin
  // Pointer coordinates are pixels in the published frame; display objects
  // retain the SWF stage origin in twips, which need not be a whole pixel.
  X := X + Movie.Stage.Left / 20;
  Y := Y + Movie.Stage.Top / 20;
  Roots := LevelClips;
  Result := nil;
  for I := High(Roots) downto 0 do
  begin
    Result := Hit(Roots[I], X, Y, TSWFMatrix.Identity);
    if Result <> nil then
      Exit;
  end;
end;

function TFlashPlayer.ClipFrames(C: TFlashClip): TArray<TSWFFrame>;
begin
  Result := nil;
  if C.MovieRoot then
    Result := C.MovieLibrary.Movie.Frames
  else if C.Character <> nil then
    Result := C.Character.Frames;
end;

procedure TFlashPlayer.RunCode(C: TFlashClip; const Code: TBytes; Stack: TList<TAVMValue>; const Pool: TArray<string>);
var
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
begin
  PreviousRoot := VM.Root;
  PreviousVersion := VM.SWFVersion;
  PreviousContext := VM.MovieContext;
  VM.Root := ClipRoot(C).Script;
  VM.SWFVersion := C.MovieLibrary.Movie.Version;
  VM.MovieContext := C.MovieLibrary;
  try
    if not C.MovieLibrary.Movie.UsesAVM2 then
      VM.Run(Code, C.Script, Stack, Pool);
  finally
    VM.Root := PreviousRoot;
    VM.SWFVersion := PreviousVersion;
    VM.MovieContext := PreviousContext;
  end;
end;

procedure TFlashPlayer.ReportUncaught(const Value: TAVMValue);
var
  Text: string;
begin
  try
    Text := VM.CoerceString(Value);
  except
    on E: EAVMThrown do
      Text := '[type Object]';
  end;
  if VM.Trace.Count < 4096 then
    VM.Trace.Add('Warning: Uncaught exception, ' + Text);
end;

procedure TFlashPlayer.ConstructClip(C: TFlashClip);
var
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
begin
  PreviousRoot := VM.Root;
  PreviousVersion := VM.SWFVersion;
  PreviousContext := VM.MovieContext;
  VM.Root := ClipRoot(C).Script;
  VM.SWFVersion := C.MovieLibrary.Movie.Version;
  VM.MovieContext := C.MovieLibrary;
  try
    VM.ConstructOnExisting(TAVMValue.Ref(C.RegisteredConstructor), C.Script, nil);
  finally
    VM.Root := PreviousRoot;
    VM.SWFVersion := PreviousVersion;
    VM.MovieContext := PreviousContext;
  end;
end;

procedure TFlashPlayer.CallConstructHandler(C: TFlashClip);
var
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
begin
  PreviousRoot := VM.Root;
  PreviousVersion := VM.SWFVersion;
  PreviousContext := VM.MovieContext;
  VM.Root := ClipRoot(C).Script;
  VM.SWFVersion := C.MovieLibrary.Movie.Version;
  VM.MovieContext := C.MovieLibrary;
  try
    try
      VM.Call(VM.Get(C.Script, 'onConstruct'), C.Script, nil);
    except
      on E: EAVMThrown do
        ReportUncaught(E.Value);
    end;
  finally
    VM.Root := PreviousRoot;
    VM.SWFVersion := PreviousVersion;
    VM.MovieContext := PreviousContext;
  end;
end;

function TFlashPlayer.ResolveLoaderTarget(const Value: TAVMValue; CreateLevels: Boolean = False): TFlashClip;
begin
  Result := nil;
  case Value.Kind of
    avString:
      Result := ResolveClip(Clip(VM.CurrentTarget), Value);
    avObject:
      Result := Clip(Value.Obj);
    avNumber:
      Result := LevelClip(AVMLevelNumber(Value.Number), CreateLevels);
  end;
  if (Result <> nil) and Result.Dead then
    Result := nil;
end;

procedure TFlashPlayer.QueueLoad(C: TFlashClip; Loader: TAVMObject; const URL: string);
var
  Request: TFlashLoadRequest;
  Caller: TFlashClip;
begin
  if (C = nil) or C.Dead or C.Removing then
    Exit;
  if FLoads.Count >= 256 then
    raise ESWFError.Create('Flash pending resource limit');
  Inc(C.LoadGeneration);
  Request := Default(TFlashLoadRequest);
  Request.Target := C;
  Request.Loader := Loader;
  Request.CallerRoot := VM.Root;
  Request.CallerVersion := VM.SWFVersion;
  Caller := Clip(VM.Root);
  if Caller = nil then
    Caller := FRoot;
  Request.CallerLibrary := Caller.MovieLibrary;
  if VM.MovieContext is TFlashLibrary then
    Request.CallerLibrary := TFlashLibrary(VM.MovieContext);
  Request.Origin := Request.CallerLibrary.URI;
  Request.URL := URL;
  Request.Generation := C.LoadGeneration;
  Request.ReadyFrame := FFrameNumber + 1;
  FLoads.Add(Request);
end;

procedure TFlashPlayer.LoaderEvent(const Request: TFlashLoadRequest; const Name: string; const Args: TArray<TAVMValue>);
var
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
  Values: TArray<TAVMValue>;
  I: Integer;
begin
  if Request.Loader = nil then
    Exit;
  PreviousRoot := VM.Root;
  PreviousVersion := VM.SWFVersion;
  PreviousContext := VM.MovieContext;
  VM.MovieContext := Request.CallerLibrary;
  VM.Root := Request.CallerRoot;
  VM.SWFVersion := Request.CallerVersion;
  try
    SetLength(Values, Length(Args) + 1);
    Values[0] := TAVMValue.Str(Name);
    for I := 0 to High(Args) do
      Values[I + 1] := Args[I];
    try
      VM.Call(VM.Get(Request.Loader, 'broadcastMessage'), Request.Loader, Values);
    except
      on E: EAVMThrown do
        ReportUncaught(E.Value);
    end;
  finally
    VM.Root := PreviousRoot;
    VM.SWFVersion := PreviousVersion;
    VM.MovieContext := PreviousContext;
  end;
end;

procedure TFlashPlayer.ClearMovie(C: TFlashClip);
var
  Child: TFlashClip;
  ConstructorValue: TAVMValue;
begin
  if C.UnloadDispatching then
    Exit;
  UnloadEvents(C);
  FAudio.StopOwner(C);
  DisconnectMask(C);
  Inc(C.LoadGeneration);
  Inc(C.ContentGeneration);
  for Child in C.Children.ToArray do
    RemoveClip(Child);
  C.Character := nil;
  C.MorphRatio := 0;
  C.MovieRoot := False;
  C.Unloaded := True;
  C.RegisteredConstructor := nil;
  C.VideoState := Default(TSWFVideoState);
  C.NetStream := nil;
  C.AttachedBitmap := nil;
  C.AttachedBitmapBounds := TSWFBounds.Empty;
  C.Frame := -1;
  C.PendingFrame := -1;
  C.FrameScriptPending := False;
  C.AVM2ConstructionPending := False;
  C.SynchronousSeekTick := 0;
  C.Playing := True;
  C.CreatedFrame := FFrameNumber;
  C.ResetDrawing;
  C.HasScrollRect := False;
  C.HasAppliedScrollRect := False;
  C.NextScrollRect := Default(TSWFRect);
  C.AppliedScrollRect := Default(TSWFRect);
  C.IsText := False;
  FreeAndNil(C.FTextDocument);
  C.ClipActions.Clear;
  if FTextFocus = C then
    FTextFocus := nil;
  C.Script.ClearMembers;
  if C.Script.Watchers <> nil then
  begin
    C.Script.Watchers.Clear;
    C.Script.WatchOrder.Clear;
    C.Script.WatchCaseNames.Clear;
  end;
  C.Script.IsBoxed := False;
  C.Script.PrimitiveValue := Default(TAVMValue);
  C.Script.IsDate := False;
  C.Script.DateValue := 0;
  C.Script.ColorData := nil;
  C.Script.BitmapData := nil;
  FreeAndNil(C.Script.OwnedNativeData);
  C.Script.IsTransform := False;
  C.Script.TransformTarget := nil;
  C.Script.TransformPath := '';
  C.Script.Prototype := nil;
  ConstructorValue := VM.GetSpecial(VM.Global, 'MovieClip');
  VM.PutData(C.Script, '__proto__', VM.GetData(ConstructorValue.Obj, 'prototype'));
end;

procedure TFlashPlayer.ProcessLoads;
var
  Requests: TArray<TFlashLoadRequest>;
  Request: TFlashLoadRequest;
  C: TFlashClip;
  Data: TBytes;
  URI, ErrorCode: string;
  MovieLibrary: TFlashLibrary;
  Code: TBytes;
  Count: Integer;
  InstalledGeneration: Cardinal;
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
  Loaded: Boolean;
begin
  Requests := FLoads.ToArray;
  FLoads.Clear;
  for Request in Requests do
  begin
    C := Request.Target;
    if C.Dead or C.Removing then
      Continue;
    if Request.ReadyFrame > FFrameNumber then
    begin
      FLoads.Add(Request);
      Continue;
    end;
    if C.LoadGeneration <> Request.Generation then
    begin
      if Request.Generation < C.UnloadGeneration then
        LoaderEvent(Request, 'onLoadStart', [TAVMValue.Ref(C.Script)]);
      Continue;
    end;
    LoaderEvent(Request, 'onLoadStart', [TAVMValue.Ref(C.Script)]);
    if C.Dead or (C.LoadGeneration <> Request.Generation) then
      Continue;
    Data := nil;
    URI := '';
    MovieLibrary := nil;
    Loaded := False;
    ErrorCode := 'URLNotFound';
    try
      if Assigned(FReadResource) then
        Loaded := FReadResource(Request.Origin, Request.URL, Data, URI);
      if Loaded then
      begin
        ErrorCode := 'LoadNeverCompleted';
        if (Length(Data) > 64 * 1024 * 1024) or (FLibraries.Count >= 64) then
          Loaded := False
        else
        begin
          MovieLibrary := TFlashLibrary.Create(Data, URI);
          if FLoadedBytes + Int64(FExternalSoundSamples) * SizeOf(SmallInt) + MovieLibrary.Movie.DecodedSize +
            MovieLibrary.Movie.BitmapMemorySize + MovieLibrary.Movie.SoundMemorySize > FlashLibraryMemoryLimit then
          begin
            MovieLibrary.Free;
            MovieLibrary := nil;
            Loaded := False;
          end;
        end;
      end;
    except
      on E: Exception do
      begin
        MovieLibrary.Free;
        MovieLibrary := nil;
        Loaded := False;
      end;
    end;
    if C.Dead or (C.LoadGeneration <> Request.Generation) then
    begin
      MovieLibrary.Free;
      Continue;
    end;
    ClearMovie(C);
    if not Loaded then
    begin
      LoaderEvent(Request, 'onLoadError', [TAVMValue.Ref(C.Script), TAVMValue.Str(ErrorCode), TAVMValue.Num(0)]);
      Continue;
    end;
    Inc(FLoadedBytes, MovieLibrary.Movie.DecodedSize + MovieLibrary.Movie.BitmapMemorySize + MovieLibrary.Movie.SoundMemorySize);
    FLibraries.Add(MovieLibrary);
    C.MovieLibrary := MovieLibrary;
    C.MovieRoot := True;
    C.Unloaded := False;
    MovieLibrary.Root := C;
    InstalledGeneration := C.ContentGeneration;
    PreviousRoot := VM.Root;
    PreviousVersion := VM.SWFVersion;
    PreviousContext := VM.MovieContext;
    VM.MovieContext := MovieLibrary;
    VM.Root := C.Script;
    VM.SWFVersion := MovieLibrary.Movie.Version;
    try
      if Length(MovieLibrary.Movie.Frames) > 0 then
        RegisterFrameExports(MovieLibrary, MovieLibrary.Movie.Frames[0]);
      for Code in MovieLibrary.Movie.InitActions do
        RunCode(C, Code);
      Count := MovieLibrary.SourceBytes;
      LoaderEvent(Request, 'onLoadProgress', [TAVMValue.Ref(C.Script), TAVMValue.Num(Count), TAVMValue.Num(Count)]);
      LoaderEvent(Request, 'onLoadComplete', [TAVMValue.Ref(C.Script), TAVMValue.Num(0)]);
      if C.Dead or (C.ContentGeneration <> InstalledGeneration) then
        Continue;
      InitializeAttachedClip(C, nil);
      FlushActions;
      if C.Dead or (C.ContentGeneration <> InstalledGeneration) then
        Continue;
      LoaderEvent(Request, 'onLoadInit', [TAVMValue.Ref(C.Script)]);
    finally
      VM.Root := PreviousRoot;
      VM.SWFVersion := PreviousVersion;
      VM.MovieContext := PreviousContext;
    end;
  end;
end;

function PlainHTMLText(const HTML: string): string;
var
  Builder: TStringBuilder;
  I, Finish: Integer;
  Tag, Entity: string;
begin
  Builder := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(HTML) do
    begin
      if HTML[I] = '<' then
      begin
        Finish := PosEx('>', HTML, I + 1);
        if Finish = 0 then
        begin
          Builder.Append(HTML[I]);
          Inc(I);
          Continue;
        end;
        Tag := Trim(Copy(HTML, I + 1, Finish - I - 1)).ToLower;
        if Tag.StartsWith('br') or (Tag = '/p') then
          Builder.Append(#10);
        I := Finish + 1;
      end
      else if HTML[I] = '&' then
      begin
        Finish := PosEx(';', HTML, I + 1);
        if (Finish > I) and (Finish - I < 16) then
        begin
          Entity := Copy(HTML, I + 1, Finish - I - 1);
          if Entity = 'amp' then
            Entity := '&'
          else if Entity = 'lt' then
            Entity := '<'
          else if Entity = 'gt' then
            Entity := '>'
          else if Entity = 'quot' then
            Entity := '"'
          else if Entity = 'apos' then
            Entity := #39
          else if Entity = 'nbsp' then
            Entity := ' '
          else if Entity.StartsWith('#') then
          begin
            var Number: Integer;
            var Digits := Copy(Entity, 2, MaxInt);
            if Digits.StartsWith('x', True) then
              Digits := '$' + Copy(Digits, 2, MaxInt);
            if TryStrToInt(Digits, Number) and (Number > 0) and (Number <= $FFFF) then
              Entity := Char(Number)
            else
              Entity := '&' + Entity + ';';
          end
          else
            Entity := '&' + Entity + ';';
          Builder.Append(Entity);
          I := Finish + 1;
        end
        else
        begin
          Builder.Append(HTML[I]);
          Inc(I);
        end;
      end
      else
      begin
        Builder.Append(HTML[I]);
        Inc(I);
      end;
    end;
    Result := Builder.ToString.TrimRight;
  finally
    Builder.Free;
  end;
end;

const
  DisplayPropertyNames: array[0..21] of string = ('_x', '_y', '_xscale', '_yscale', '_currentframe', '_totalframes', '_alpha', '_visible',
    '_width', '_height', '_rotation', '_target', '_framesloaded', '_name', '_droptarget', '_url', '_highquality', '_focusrect', '_soundbuftime', '_quality', '_xmouse', '_ymouse');
  ClipMethods: array[0..37] of string = ('createEmptyMovieClip', 'createTextField',
    'beginFill', 'beginGradientFill', 'moveTo', 'lineTo', 'curveTo', 'endFill', 'lineStyle',
    'nextFrame', 'prevFrame', 'attachMovie', 'getBytesLoaded', 'getBytesTotal', 'clear', 'removeMovieClip',
    'swapDepths', 'getNextHighestDepth', 'getDepth', 'hitTest', 'play', 'stop', 'gotoAndPlay', 'gotoAndStop', 'duplicateMovieClip', 'loadMovie', 'unloadMovie',
    'getBounds', 'getRect', 'localToGlobal', 'globalToLocal', 'getSWFVersion', 'startDrag', 'stopDrag',
    'attachBitmap', 'beginBitmapFill', 'setMask', 'lineGradientStyle');

constructor TFlashClip.Create;
begin
  inherited;
  ColorTransform := TSWFColorTransform.Identity;
  Children := TList<TFlashClip>.Create;
  ClipActions := TList<TSWFClipAction>.Create;
  SoundTransform := TFlashSoundTransform.Identity;
  Drawing := TSWFCharacter.Create;
  ScaleX := 1;
  ScaleY := 1;
  Alpha := 1;
  Visible := True;
  Playing := True;
  PendingFrame := -1;
  Frame := -1;
  TextSize := 12;
  TextColor := $FF000000;
  Drawing.EvenOddFills := True;
  SetMatrix(TSWFMatrix.Identity);
end;

procedure TFlashClip.ResetDrawing;
begin
  Drawing.Fills := nil;
  Drawing.Edges := nil;
  Drawing.StrokePaths := nil;
  Drawing.ShapeBounds := TSWFBounds.Empty;
  Drawing.PathBounds := TSWFBounds.Empty;
  FreeAndNil(FStrokePoints);
  FDrawingEdgeCount := 0;
  DrawingTouched := False;
  Fill := 0;
  StrokeFill := 0;
  PenX := 0;
  PenY := 0;
  StartX := 0;
  StartY := 0;
end;

procedure TFlashClip.FinishDrawingStroke;
var
  Path: TSWFStrokePath;
begin
  if (FStrokePoints = nil) or (FStrokePoints.Count < 2) then
    Exit;
  Path.Fill := StrokeFill;
  Path.Points := FStrokePoints.ToArray;
  Drawing.StrokePaths := Drawing.StrokePaths + [Path];
  FStrokePoints.Clear;
end;

function TFlashClip.PendingFillEdge(out Edge: TSWFEdge): Boolean;
begin
  Result := (Fill <> 0) and ((PenX <> StartX) or (PenY <> StartY));
  if not Result then
    Exit;
  Edge.Fill := Fill;
  Edge.X1 := PenX;
  Edge.Y1 := PenY;
  Edge.X2 := StartX;
  Edge.Y2 := StartY;
end;

function TFlashClip.PendingStroke(out Path: TSWFStrokePath): Boolean;
var
  Edge: TSWFEdge;
  First, Last: TSWFPoint;
begin
  if StrokeFill = 0 then
    Exit(False);
  Path.Fill := StrokeFill;
  if FStrokePoints <> nil then
    Path.Points := FStrokePoints.ToArray
  else
    Path.Points := nil;
  if PendingFillEdge(Edge) then
  begin
    if Length(Path.Points) = 0 then
    begin
      First.X := Edge.X1;
      First.Y := Edge.Y1;
      Path.Points := [First];
    end;
    Last.X := Edge.X2;
    Last.Y := Edge.Y2;
    Path.Points := Path.Points + [Last];
  end;
  Result := Length(Path.Points) >= 2;
end;

function TFlashClip.GetTextDocument: TFlashTextDocument;
const
  Alignments: array[0..3] of string = ('left', 'right', 'center', 'justify');
var
  Data: TAVMTextFormatData;
  Font: TSWFCharacter;
begin
  if FTextDocument = nil then
  begin
    Data := TAVMTextFormatData.Create;
    try
      Data.Values[0] := TAVMValue.Str('Times New Roman');
      if (MovieLibrary <> nil) and MovieLibrary.Movie.Characters.TryGetValue(FontId, Font) and
        (Font.FontName <> '') then
        Data.Values[0] := TAVMValue.Str(Font.FontName);
      Data.Values[1] := TAVMValue.Num(TextSize);
      Data.Values[2] := TAVMValue.Num(TextColor and $FFFFFF);
      Data.Values[3] := TAVMValue.Str('');
      Data.Values[4] := TAVMValue.Str('');
      Data.Values[5] := TAVMValue.Bool(False);
      Data.Values[6] := TAVMValue.Bool(False);
      Data.Values[7] := TAVMValue.Bool(False);
      Data.Values[8] := TAVMValue.Str(Alignments[EnsureRange(TextAlign, 0, 3)]);
      Data.Values[9] := TAVMValue.Num(TextLeftMargin);
      Data.Values[10] := TAVMValue.Num(TextRight);
      Data.Values[11] := TAVMValue.Num(Round(TextIndent));
      Data.Values[12] := TAVMValue.Num(TextLeading);
      Data.Values[13] := TAVMValue.Num(0);
      Data.Values[14] := TAVMValue.Bool(True);
      Data.Values[15] := TAVMValue.Bool(False);
      Data.Values[17] := TAVMValue.Bool(False);
      Data.Values[18] := TAVMValue.Num(0);
      FTextDocument := TFlashTextDocument.Create(Data);
      if MovieLibrary <> nil then
        FTextDocument.Version := MovieLibrary.Movie.Version;
      FTextDocument.Multiline := TextMultiline;
    finally
      Data.Free;
    end;
  end;
  Result := FTextDocument;
end;

function TFlashClip.GetText: string;
begin
  if FTextDocument = nil then
    Result := ''
  else
    Result := FTextDocument.Text;
end;

procedure TFlashClip.SetText(const Value: string);
begin
  if (Value = '') and (FTextDocument = nil) then
    Exit;
  TextDocument.AssignText(Value);
end;

function TFlashClip.GetHTMLText: string;
begin
  if FTextDocument = nil then
    Result := ''
  else
    Result := FTextDocument.HTMLText;
end;

procedure TFlashClip.SetHTMLText(const Value: string);
begin
  TextDocument.AssignHTML(Value);
end;

destructor TFlashClip.Destroy;
begin
  FStrokePoints.Free;
  FTextDocument.Free;
  Drawing.Free;
  ClipActions.Free;
  Children.Free;
  inherited;
end;

function TFlashClip.Matrix: TSWFMatrix;
var
  ScaleChangedX, ScaleChangedY, AngleChanged: Boolean;
  AngleX, AngleY: Double;

  function Same(A, B: Double): Boolean;
  var
    BitsA, BitsB: UInt64;
  begin
    Move(A, BitsA, 8);
    Move(B, BitsB, 8);
    Result := BitsA = BitsB;
  end;

begin
  ScaleChangedX := not FMatrixValid or not Same(ScaleX, FMatrixSnapshot[2]);
  ScaleChangedY := not FMatrixValid or not Same(ScaleY, FMatrixSnapshot[3]);
  AngleChanged := not FMatrixValid or not Same(Rotation, FMatrixSnapshot[4]) or not Same(Skew, FMatrixSnapshot[5]);
  if ScaleChangedX or ScaleChangedY or AngleChanged then
  begin
    AngleX := DegToRad(Rotation);
    AngleY := DegToRad(Rotation + Skew);
    if ScaleChangedX or AngleChanged then
    begin
      FStoredMatrix.A := SWFFloat32(AVMTrig(1, AngleX) * ScaleX);
      FStoredMatrix.B := SWFFloat32(AVMTrig(0, AngleX) * ScaleX);
    end;
    if ScaleChangedY or AngleChanged then
    begin
      FStoredMatrix.C := SWFFloat32(-AVMTrig(0, AngleY) * ScaleY);
      FStoredMatrix.D := SWFFloat32(AVMTrig(1, AngleY) * ScaleY);
    end;
  end;
  if not FMatrixValid or not Same(X, FMatrixSnapshot[0]) then
    FStoredMatrix.TX := SWFTwipsFromPixels(X);
  if not FMatrixValid or not Same(Y, FMatrixSnapshot[1]) then
    FStoredMatrix.TY := SWFTwipsFromPixels(Y);
  SnapshotMatrix;
  Result := FStoredMatrix;
end;

procedure TFlashClip.SnapshotMatrix;
begin
  FMatrixSnapshot[0] := X;
  FMatrixSnapshot[1] := Y;
  FMatrixSnapshot[2] := ScaleX;
  FMatrixSnapshot[3] := ScaleY;
  FMatrixSnapshot[4] := Rotation;
  FMatrixSnapshot[5] := Skew;
  FMatrixValid := True;
end;

procedure TFlashClip.SetPosition(XValue, YValue: Double);
begin
  SetPositionTwips(SWFTwipsFromPixels(XValue), SWFTwipsFromPixels(YValue));
end;

procedure TFlashClip.SetPositionTwips(XValue, YValue: Integer);
begin
  FStoredMatrix := Matrix;
  FStoredMatrix.TX := XValue;
  FStoredMatrix.TY := YValue;
  X := FStoredMatrix.TX / 20;
  Y := FStoredMatrix.TY / 20;
  SnapshotMatrix;
end;

procedure TFlashClip.SetMatrix(const Value: TSWFMatrix);
var
  AngleX, AngleY: Double;
  Mask: TArithmeticExceptionMask;
begin
  FStoredMatrix := Value;
  FStoredMatrix.A := SWFFloat32(Value.A);
  FStoredMatrix.B := SWFFloat32(Value.B);
  FStoredMatrix.C := SWFFloat32(Value.C);
  FStoredMatrix.D := SWFFloat32(Value.D);
  X := Value.TX / 20;
  Y := Value.TY / 20;
  Mask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    ScaleX := Hypot(FStoredMatrix.A, FStoredMatrix.B);
    ScaleY := Hypot(FStoredMatrix.C, FStoredMatrix.D);
    AngleX := ArcTan2(FStoredMatrix.B, FStoredMatrix.A);
    AngleY := ArcTan2(-FStoredMatrix.C, FStoredMatrix.D);
    Rotation := RadToDeg(AngleX);
    Skew := RadToDeg(AngleY - AngleX);
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
  SnapshotMatrix;
end;

procedure TFlashClip.SetScale(Axis: Integer; Value: Double);
var
  Effective, Angle: Double;
  Mask: TArithmeticExceptionMask;
begin
  FStoredMatrix := Matrix;
  TransformedByScript := True;
  if Axis = 0 then
    ScaleX := Value
  else
    ScaleY := Value;
  Mask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    Effective := Value;
    if IsNan(Effective) then
      Effective := 0;
    Angle := DegToRad(Rotation);
    if IsNan(Angle) then
      Angle := 0;
    if Axis = 0 then
    begin
      FStoredMatrix.A := SWFFloat32(AVMTrig(1, Angle) * Effective);
      FStoredMatrix.B := SWFFloat32(AVMTrig(0, Angle) * Effective);
    end
    else
    begin
      Angle := Angle + DegToRad(Skew);
      FStoredMatrix.C := SWFFloat32(-AVMTrig(0, Angle) * Effective);
      FStoredMatrix.D := SWFFloat32(AVMTrig(1, Angle) * Effective);
    end;
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
  SnapshotMatrix;
end;

procedure TFlashClip.SetRotation(Value: Double);
var
  AngleX, AngleY: Double;
  Mask: TArithmeticExceptionMask;
begin
  FStoredMatrix := Matrix;
  Rotation := Value;
  TransformedByScript := True;
  if not IsNan(Value) then
  begin
    Mask := GetExceptionMask;
    SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
    try
      AngleX := DegToRad(Value);
      AngleY := AngleX + DegToRad(Skew);
      FStoredMatrix.A := SWFFloat32(ScaleX * AVMTrig(1, AngleX));
      FStoredMatrix.B := SWFFloat32(ScaleX * AVMTrig(0, AngleX));
      FStoredMatrix.C := SWFFloat32(-ScaleY * AVMTrig(0, AngleY));
      FStoredMatrix.D := SWFFloat32(ScaleY * AVMTrig(1, AngleY));
    finally
      ClearExceptions;
      SetExceptionMask(Mask);
    end;
  end;
  SnapshotMatrix;
end;

constructor TFlashPlayer.Create(const Data: TBytes; const Origin: string; const Resources: TFlashResourceReader);
var
  Name: string;
  Code: TBytes;
  Value, MovieClipClass, MovieClipPrototype: TAVMValue;
  MovieLibrary: TFlashLibrary;
  LoaderClass: TAVMValue;
  LoaderPrototype, StageObject: TAVMObject;
begin
  inherited Create;
  FQuality := fqHigh;
  FClips := TObjectList<TFlashClip>.Create;
  FLevels := TDictionary<Integer, TFlashClip>.Create;
  FAudio := TFlashAudio.Create;
  FGlobalSoundTransform := TFlashSoundTransform.Identity;
  FLibraries := TObjectList<TFlashLibrary>.Create;
  FLoads := TList<TFlashLoadRequest>.Create;
  FUnloads := TList<TFlashUnloadRequest>.Create;
  FReadResource := Resources;
  FActions := TList<TFlashQueuedAction>.Create;
  FConstructClips := TList<TFlashQueuedConstruct>.Create;
  FNativeMethods := TDictionary<string, TAVMValue>.Create;
  FBitmapGlyphs := TObjectDictionary<Integer, TSWFCharacter>.Create([doOwnsValues]);
  MovieLibrary := TFlashLibrary.Create(Data, Origin);
  FLibraries.Add(MovieLibrary);
  Movie := MovieLibrary.Movie;
  FLoadedBytes := Movie.DecodedSize + Movie.BitmapMemorySize + Movie.SoundMemorySize;
  VM := TAVM1.Create(Self);
  VM.SWFVersion := Movie.Version;
  FVideoPool := CreateImagePixelPool(SWFVideoPoolPixels);
  FNet := TFlashNetRuntime.Create(VM, FAudio, Resources, FVideoPool);
  InstallSoundClass;
  StageObject := VM.Get(VM.Global, 'Stage').Obj;
  VM.AddProperty(StageObject, 'width', VM.NativeFunction('Stage.width').Obj, nil);
  VM.AddProperty(StageObject, 'height', VM.NativeFunction('Stage.height').Obj, nil);
  StageObject.Attributes.AddOrSetValue('width', 0);
  StageObject.Attributes.AddOrSetValue('height', 0);
  VM.Global.Attributes.AddOrSetValue('Stage', 1);
  FRoot := CreateClip;
  FRoot.Script := VM.Root;
  VM.Root.HostData := FRoot;
  FRoot.MovieLibrary := MovieLibrary;
  FRoot.MovieRoot := True;
  MovieLibrary.Root := FRoot;
  FRoot.IsLevel := True;
  FRoot.LevelIndex := 0;
  FLevels.Add(0, FRoot);
  MovieClipClass := VM.Get(VM.Global, 'MovieClip');
  MovieClipPrototype := VM.GetData(MovieClipClass.Obj, 'prototype');
  for Name in ClipMethods do
  begin
    Value := VM.NativeFunction('MovieClip.' + Name);
    FNativeMethods.Add(Name, Value);
    VM.PutData(MovieClipPrototype.Obj, Name, Value);
    MovieClipPrototype.Obj.Attributes.AddOrSetValue(Name, 3);
    if Name = 'getRect' then
      MovieClipPrototype.Obj.Attributes.AddOrSetValue(Name, $1003);
    if MatchStr(Name, ['setMask', 'beginFill', 'beginGradientFill', 'moveTo', 'lineTo',
        'curveTo', 'endFill', 'lineStyle', 'clear']) then
      MovieClipPrototype.Obj.Attributes.AddOrSetValue(Name, $83);
    if MatchStr(Name, ['attachBitmap', 'beginBitmapFill', 'lineGradientStyle']) then
      MovieClipPrototype.Obj.Attributes.AddOrSetValue(Name, $1003);
  end;
  VM.AddProperty(MovieClipPrototype.Obj, 'transform', VM.NativeFunction('MovieClip.getTransform').Obj,
    VM.NativeFunction('MovieClip.setTransform').Obj);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('transform', $1001);
  VM.AddProperty(MovieClipPrototype.Obj, 'scrollRect', VM.NativeFunction('MovieClip.getScrollRect').Obj,
    VM.NativeFunction('MovieClip.setScrollRect').Obj);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('scrollRect', $1003);
  VM.AddProperty(MovieClipPrototype.Obj, 'blendMode', VM.NativeFunction('MovieClip.getBlendMode').Obj,
    VM.NativeFunction('MovieClip.setBlendMode').Obj);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('blendMode', $1003);
  VM.AddProperty(MovieClipPrototype.Obj, 'filters', VM.NativeFunction('MovieClip.getFilters').Obj,
    VM.NativeFunction('MovieClip.setFilters').Obj);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('filters', $1003);
  MovieClipClass := VM.Get(VM.Global, 'Button');
  MovieClipPrototype := VM.GetData(MovieClipClass.Obj, 'prototype');
  VM.PutData(MovieClipPrototype.Obj, 'getDepth', FNativeMethods['getDepth']);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('getDepth', 3);
  LoaderClass := VM.NativeFunction('MovieClipLoader');
  LoaderPrototype := VM.NewObject;
  VM.PutData(LoaderClass.Obj, 'prototype', TAVMValue.Ref(LoaderPrototype));
  VM.Put(LoaderPrototype, 'constructor', LoaderClass);
  LoaderPrototype.Attributes.AddOrSetValue('constructor', 1);
  for Name in ['loadClip', 'unloadClip', 'getProgress'] do
  begin
    VM.Put(LoaderPrototype, Name, VM.NativeFunction('MovieClipLoader.' + Name));
    LoaderPrototype.Attributes.AddOrSetValue(Name, 3);
  end;
  AVMInitializeBroadcaster(VM, LoaderPrototype);
  VM.Put(VM.Global, 'MovieClipLoader', LoaderClass);
  MovieClipClass := VM.Get(VM.Global, 'TextField');
  MovieClipPrototype := VM.GetData(MovieClipClass.Obj, 'prototype');
  for Name in ['getTextFormat', 'setTextFormat', 'getNewTextFormat', 'setNewTextFormat', 'removeTextField'] do
  begin
    VM.PutData(MovieClipPrototype.Obj, Name, VM.NativeFunction('TextField.' + Name));
    MovieClipPrototype.Obj.Attributes.AddOrSetValue(Name, $83);
  end;
  VM.PutData(MovieClipPrototype.Obj, 'getDepth', FNativeMethods['getDepth']);
  MovieClipPrototype.Obj.Attributes.AddOrSetValue('getDepth', $87);
  for Name in ['text', 'htmlText', 'length', 'textColor', 'html', 'type', 'multiline'] do
  begin
    if Name = 'length' then
      VM.AddProperty(MovieClipPrototype.Obj, Name, VM.NativeFunction('TextField.get.' + Name).Obj, nil)
    else
      VM.AddProperty(MovieClipPrototype.Obj, Name, VM.NativeFunction('TextField.get.' + Name).Obj,
        VM.NativeFunction('TextField.set.' + Name).Obj);
  end;
  { Root init scripts execute during preload, even when their tags follow
    the ordinary frame scripts in the SWF stream. }
  if Length(Movie.Frames) > 0 then
    RegisterFrameExports(MovieLibrary, Movie.Frames[0]);
  for Code in Movie.InitActions do
    RunCode(FRoot, Code);
  ClearInput;
end;

destructor TFlashPlayer.Destroy;
begin
  FViewportQuad.Free;
  FUnloads.Free;
  FLevels.Free;
  FLoads.Free;
  FConstructClips.Free;
  FActions.Free;
  FBitmapGlyphs.Free;
  FNativeMethods.Free;
  FClips.Free;
  VM.Free;
  FNet.Free;
  FLibraries.Free;
  FAudio.Free;
  inherited;
end;

function TFlashClip.GetAlpha: Double;
begin
  Result := ColorTransform.Mult[3];
end;

procedure TFlashClip.SetAlpha(Value: Double);
begin
  if IsNan(Value) then
    Value := 0;
  if Value >= 127.99609375 then
    ColorTransform.Mult[3] := 32767 / 256.0
  else if Value <= -128 then
    ColorTransform.Mult[3] := -128
  else
    ColorTransform.Mult[3] := Trunc(Value * 256) / 256.0;
end;

function TFlashPlayer.ColorTarget(const Value: TAVMValue): TAVMObject;
var
  C: TFlashClip;
  Path: string;
begin
  Result := nil;
  if Value.Kind = avUndefined then
    Exit;
  C := Clip(Value.Obj);
  if C <> nil then
  begin
    if C.Dead then
      Exit;
  end
  else
  begin
    Path := VM.CoerceString(Value);
    if Path = '' then
      Exit;
    C := ResolveClip(Clip(VM.CurrentTarget), TAVMValue.Str(Path));
  end;
  if C <> nil then
    Result := C.Script;
end;

procedure TFlashPlayer.MarkColorTarget(O: TAVMObject);
var
  C: TFlashClip;
begin
  C := Clip(O);
  if C <> nil then
    C.TransformedByScript := True;
end;

function TFlashPlayer.ReadColorTransform(O: TAVMObject; out Value: TSWFColorTransform): Boolean;
var
  C: TFlashClip;
begin
  C := Clip(O);
  Result := C <> nil;
  Value := TSWFColorTransform.Identity;
  if Result then
    Value := C.ColorTransform;
end;

procedure TFlashPlayer.WriteColorTransform(O: TAVMObject; const Value: TSWFColorTransform);
var
  C: TFlashClip;
begin
  C := Clip(O);
  if C <> nil then
    C.ColorTransform := Value;
end;

function TFlashPlayer.Clip(O: TAVMObject): TFlashClip;
begin
  Result := nil;
  if (O <> nil) and (O.HostData is TFlashClip) then
    Result := TFlashClip(O.HostData);
end;

function TFlashPlayer.BindTransformReference(O: TAVMObject; out Path: string): TAVMObject;
var
  C: TFlashClip;
begin
  Result := nil;
  Path := '';
  if (O = nil) or (O.SuperThis <> nil) then
    Exit;
  C := Clip(O);
  while C <> nil do
  begin
    if not C.IsText and ((C.Character = nil) or (C.Character.Kind = 39) or C.MovieRoot) then
      Break;
    if VM.SWFVersion > 5 then
      Exit;
    C := C.Parent;
  end;
  if C = nil then
    Exit;
  StringValue(C.Script, Path);
  Result := C.Script;
end;

function TFlashPlayer.ResolveTransformReference(var O: TAVMObject; const Path: string): TAVMObject;
var
  C, Child: TFlashClip;
  Parts: TArray<string>;
  I, LevelId: Integer;
  Name: string;
begin
  Result := nil;
  C := Clip(O);
  if (C <> nil) and not C.Dead then
    Exit(C.Script);
  O := nil;
  if Path = '' then
    Exit;
  Parts := Path.Split(['.']);
  if Length(Parts) = 0 then
    Exit;
  if (Copy(Parts[0], 1, 6) <> '_level') or not TryStrToInt(Copy(Parts[0], 7, MaxInt), LevelId) then
    Exit;
  C := LevelClip(LevelId, True);
  if C = nil then
    Exit;
  for I := 1 to High(Parts) do
  begin
    Name := Parts[I];
    Result := nil;
    for Child in C.Children do
      if not Child.Dead and
        ((Child.Name = Name) or ((VM.SWFVersion < 7) and (AVMLowerName(Child.Name) = AVMLowerName(Name)))) then
      begin
        Result := Child.Script;
        Break;
      end;
    if Result = nil then
      Exit;
    C := Clip(Result);
    if C = nil then
      Exit;
  end;
  Result := C.Script;
end;

function TFlashPlayer.DisplayParent(O: TAVMObject): TAVMObject;
var
  C: TFlashClip;
begin
  C := Clip(O);
  Result := nil;
  if (C <> nil) and (C.Parent <> nil) then
    Result := C.Parent.Script;
end;

function TFlashPlayer.ReadDisplayMatrix(O: TAVMObject; out Value: TSWFMatrix): Boolean;
var
  C: TFlashClip;
begin
  C := Clip(O);
  Result := C <> nil;
  Value := TSWFMatrix.Identity;
  if Result then
    Value := C.Matrix;
end;

procedure TFlashPlayer.WriteDisplayMatrix(O: TAVMObject; const Value: TSWFMatrix);
var
  C: TFlashClip;
begin
  C := Clip(O);
  if C <> nil then
    C.SetMatrix(Value);
end;

function TFlashClip.WithScrollOffset(const Transform: TSWFMatrix): TSWFMatrix;
var
  Offset: TSWFMatrix;
begin
  if not HasAppliedScrollRect then
    Exit(Transform);
  Offset := TSWFMatrix.Identity;
  Offset.TX := SWFAddCoordinate(not AppliedScrollRect.Left, 1);
  Offset.TY := SWFAddCoordinate(not AppliedScrollRect.Top, 1);
  Result := Offset.ThenBy(Transform);
end;

procedure TFlashClip.ApplyScrollRect;
begin
  HasAppliedScrollRect := HasScrollRect;
  if HasAppliedScrollRect then
    AppliedScrollRect := NextScrollRect;
end;

function ScrollViewport(const ScrollRect: TSWFRect): TSWFRect;
begin
  Result := Default(TSWFRect);
  Result.Right := SWFAddCoordinate(ScrollRect.Right, SWFAddCoordinate(not ScrollRect.Left, 1));
  Result.Bottom := SWFAddCoordinate(ScrollRect.Bottom, SWFAddCoordinate(not ScrollRect.Top, 1));
end;

function TFlashPlayer.WorldMatrix(C: TFlashClip; IncludeOwnScroll: Boolean): TSWFMatrix;
var
  Parent: TFlashClip;
  Depth: Integer;
begin
  Result := C.Matrix;
  Parent := C.Parent;
  Depth := 0;
  if IncludeOwnScroll then
    Result := C.WithScrollOffset(Result);
  while Parent <> nil do
  begin
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('Flash matrix parent limit');
    if Parent.HasAppliedScrollRect then
    begin
      Result.TX := SWFAddCoordinate(Trunc(Result.TX), SWFAddCoordinate(not Parent.AppliedScrollRect.Left, 1));
      Result.TY := SWFAddCoordinate(Trunc(Result.TY), SWFAddCoordinate(not Parent.AppliedScrollRect.Top, 1));
    end;
    Result := Result.ThenBy(Parent.Matrix);
    Parent := Parent.Parent;
  end;
end;

function TFlashPlayer.BoundsWithMatrix(C: TFlashClip; const Matrix: TSWFMatrix; IgnoreStrokes: Boolean; PendingScroll, IncludeFilters, UseMorphRatio: Boolean): TSWFBounds;

  function Visit(Node: TFlashClip; const Transform: TSWFMatrix; Depth: Integer): TSWFBounds;
  var
    Child: TFlashClip;
    local, ChildBounds: TSWFBounds;
    Rect: TSWFRect;
    ChildMatrix: TSWFMatrix;
    Character: TSWFCharacter;
    PadX, PadY: Integer;
  begin
    Result := TSWFBounds.Empty;
    if Node.Dead then
      Exit;
    if Depth > 128 then
      raise ESWFError.Create('Flash bounds nesting limit');
    if PendingScroll then
    begin
      if Node.HasScrollRect then
        Exit(TSWFBounds.FromRect(ScrollViewport(Node.NextScrollRect)).Transformed(Transform));
    end
    else if Node.HasAppliedScrollRect then
      Exit(TSWFBounds.FromRect(ScrollViewport(Node.AppliedScrollRect)).Transformed(Transform));
    if Node.AttachedBitmap <> nil then
      Result.Include(Node.AttachedBitmapBounds.Transformed(Transform));
    Character := Node.Character;
    if not Node.IsText and (Character <> nil) then
    begin
      if UseMorphRatio then
        Character := Character.ShapeAt(Node.MorphRatio);
      if Character.ShapeBounds.Valid then
      begin
        if IgnoreStrokes then
          local := Character.PathBounds
        else
          local := Character.ShapeBounds;
        Result.Include(local.Transformed(Transform));
      end
      else if not (Character.Kind in [2, 7, 10, 22, 32, 34, 39, 48, 75, 83, 91]) then
        Result.Include(TSWFBounds.FromRect(Character.Bounds).Transformed(Transform));
    end;
    if Node.IsText then
    begin
      Rect.Left := SWFTwipsFromPixels(Node.TextLeft);
      Rect.Top := SWFTwipsFromPixels(Node.TextTop);
      Rect.Right := SWFTwipsFromPixels(Node.TextLeft + Node.TextWidth);
      Rect.Bottom := SWFTwipsFromPixels(Node.TextTop + Node.TextHeight);
      Result.Include(TSWFBounds.FromRect(Rect).Transformed(Transform));
    end;
    if IgnoreStrokes then
      local := Node.Drawing.PathBounds
    else
      local := Node.Drawing.ShapeBounds;
    Result.Include(local.Transformed(Transform));
    for Child in Node.Children do
    begin
      ChildMatrix := Child.Matrix.ThenBy(Transform);
      ChildBounds := Visit(Child, ChildMatrix, Depth + 1);
      Result.Include(ChildBounds);
    end;
    if IncludeFilters and (Depth > 0) and Result.Valid and (Node.Filters <> nil) then
    begin
      FlashFilterPadding(Node.Filters, PadX, PadY);
      Result.Rect.Left := Max(Int64(Low(Integer)), Int64(Result.Rect.Left) - PadX * 20);
      Result.Rect.Right := Min(Int64(High(Integer)), Int64(Result.Rect.Right) + PadX * 20);
      Result.Rect.Top := Max(Int64(Low(Integer)), Int64(Result.Rect.Top) - PadY * 20);
      Result.Rect.Bottom := Min(Int64(High(Integer)), Int64(Result.Rect.Bottom) + PadY * 20);
    end;
  end;

begin
  Result := Visit(C, Matrix, 0);
end;

function TFlashPlayer.DisplayBounds(O: TAVMObject; out Bounds: TSWFRect): Boolean;
var
  C: TFlashClip;
  Value: TSWFBounds;
begin
  C := Clip(O);
  Result := C <> nil;
  Bounds := Default(TSWFRect);
  if not Result then
    Exit;
  Value := BoundsWithMatrix(C, WorldMatrix(C, False), False);
  if Value.Valid then
    Bounds := Value.Rect;
end;

procedure TFlashPlayer.SetDisplaySize(C: TFlashClip; Value: Double; IsWidth: Boolean);
var
  Bounds: TSWFBounds;
  ObjectWidth, ObjectHeight, Aspect, TargetX, TargetY, PreviousX, PreviousY: Double;
  Cosine, Sine, NewX, NewY: Double;
  Mask: TArithmeticExceptionMask;
begin
  if C.IsText then
  begin
    if IsWidth then
      C.TextWidth := SWFTwipsFromPixels(Value) / 20
    else
      C.TextHeight := SWFTwipsFromPixels(Value) / 20;
    C.TransformedByScript := True;
    Exit;
  end;
  Bounds := BoundsWithMatrix(C, TSWFMatrix.Identity, False);
  ObjectWidth := (Int64(Bounds.Rect.Right) - Bounds.Rect.Left) / 20;
  ObjectHeight := (Int64(Bounds.Rect.Bottom) - Bounds.Rect.Top) / 20;
  Mask := GetExceptionMask;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    PreviousX := C.ScaleX;
    PreviousY := C.ScaleY;
    Cosine := Abs(AVMTrig(1, DegToRad(C.Rotation)));
    Sine := Abs(AVMTrig(0, DegToRad(C.Rotation)));
    TargetX := 0;
    TargetY := 0;
    if (IsWidth and (ObjectWidth <> 0)) or (not IsWidth and (ObjectHeight <> 0)) then
    begin
      TargetX := Value / ObjectWidth;
      TargetY := Value / ObjectHeight;
    end;
    if IsWidth then
    begin
      Aspect := ObjectHeight / ObjectWidth;
      NewX := Aspect * (Cosine * TargetX + Sine * TargetY) / ((Cosine + Aspect * Sine) * (Aspect * Cosine + Sine));
      NewY := (Sine * PreviousX + Aspect * Cosine * PreviousY) / (Aspect * Cosine + Sine);
    end
    else
    begin
      Aspect := ObjectWidth / ObjectHeight;
      NewX := (Aspect * Cosine * PreviousX + Sine * PreviousY) / (Aspect * Cosine + Sine);
      NewY := Aspect * (Sine * TargetX + Cosine * TargetY) / ((Cosine + Aspect * Sine) * (Aspect * Cosine + Sine));
    end;
    if IsNan(NewX) or IsInfinite(NewX) then
      NewX := 0;
    if IsNan(NewY) or IsInfinite(NewY) then
      NewY := 0;
    C.SetScale(0, NewX);
    C.SetScale(1, NewY);
  finally
    ClearExceptions;
    SetExceptionMask(Mask);
  end;
end;

function TFlashPlayer.SlashPath(C: TFlashClip): string;
var
  Depth: Integer;
begin
  Result := '';
  Depth := 0;
  while C.Parent <> nil do
  begin
    Result := '/' + C.Name + Result;
    C := C.Parent;
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('Flash path nesting limit');
  end;
  if Result = '' then
    Result := '/'
  else if C.IsLevel and (C.LevelIndex <> 0) then
    Result := '_level' + IntToStr(C.LevelIndex) + Result;
end;

procedure TFlashPlayer.ResolveIndexedProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Target: TFlashClip; out PropertyIndex: Integer);
var
  Number: Double;
  Base: TFlashClip;
  Text: string;
  AllowEmpty: Boolean;
begin
  Number := VM.CoerceNumber(Index);
  Base := Clip(Start);
  AllowEmpty := Base <> nil;
  if Base = nil then
    Base := Clip(VM.Root);
  Target := Clip(Path.Obj);
  if Target = nil then
  begin
    Text := VM.CoerceString(Path);
    if (Text <> '') or AllowEmpty then
      Target := ResolveClip(Base, TAVMValue.Str(Text));
  end;
  PropertyIndex := -1;
  if IsNan(Number) or IsInfinite(Number) or (Number <= -1) or (Number >= Length(DisplayPropertyNames)) then
    Exit;
  PropertyIndex := Trunc(Number);
end;

function TFlashPlayer.ActionGetProperty(Start: TAVMObject; const Path, Index: TAVMValue; out Value: TAVMValue): Boolean;
var
  C: TFlashClip;
  PropertyIndex: Integer;
begin
  Result := True;
  Value := Default(TAVMValue);
  ResolveIndexedProperty(Start, Path, Index, C, PropertyIndex);
  if (C <> nil) and (PropertyIndex >= 0) then
    GetMember(C.Script, DisplayPropertyNames[PropertyIndex], Value);
end;

function TFlashPlayer.ActionSetProperty(Start: TAVMObject; const Path, Index, Value: TAVMValue): Boolean;
var
  C: TFlashClip;
  PropertyIndex: Integer;
begin
  Result := True;
  ResolveIndexedProperty(Start, Path, Index, C, PropertyIndex);
  if PropertyIndex < 0 then
    Exit;
  if (C = nil) or (PropertyIndex in [4, 5, 11, 12, 14, 15, 20, 21]) then
  begin
    { Flash coerces even when the target is missing or the slot is read-only.
      A guest error from this otherwise unused conversion is ignored. }
    try
      if (PropertyIndex in [0..10, 12]) and not (Value.Kind in [avNull, avUndefined]) then
        VM.CoerceNumber(Value)
      else if PropertyIndex in [16, 18, 20, 21] then
        VM.CoerceNumber(Value)
      else if PropertyIndex in [13, 19] then
        VM.CoerceString(Value);
    except
      on E: EAVMThrown do
        ;
    end;
    Exit;
  end;
  SetMember(C.Script, DisplayPropertyNames[PropertyIndex], Value);
end;

function BiasedDepth(Value: Integer): Integer;
begin
  Result := AVMToInt32(Double(Value) + 16384);
end;

procedure TFlashPlayer.RegisterFrameExports(MovieLibrary: TFlashLibrary; const Frame: TSWFFrame);
var
  Tag: TSWFTag;
  R: TSWFReader;
  I, Count, Id: Integer;
  Name: string;
begin
  for Tag in Frame.Tags do
    if Tag.Code = 56 then
    begin
      R := TSWFReader.Create(Tag.Data, MovieLibrary.Movie.Version);
      try
        Count := R.U16;
        for I := 1 to Count do
        begin
          Id := R.U16;
          Name := R.Str;
          if MovieLibrary.Movie.Characters.ContainsKey(Id) or MovieLibrary.Movie.Sounds.ContainsKey(Id) then
          begin
            MovieLibrary.ExportNames.AddOrSetValue(AVMLowerName(Name), Id);
            MovieLibrary.Symbols.AddOrSetValue(Id, Name);
          end;
        end;
      finally
        R.Free;
      end;
    end;
end;

function TFlashPlayer.ResolveClip(Start: TFlashClip; const Value: TAVMValue): TFlashClip;
var
  Path, Part: string;
  I, First, LevelId: Integer;
begin
  Result := Clip(Value.Obj);
  if Result <> nil then
  begin
    if Result.Dead then
      Result := nil;
    Exit;
  end;
  Path := VM.CoerceString(Value);
  Result := Start;
  if Result = nil then
    Result := FRoot;
  I := 1;
  if (Length(Path) > 0) and (Path[1] = '/') then
    Result := ClipRoot(Result);
  while I <= Length(Path) do
  begin
    if (Path[I] = '.') and (I < Length(Path)) and (Path[I + 1] = '.') and
      ((I + 2 > Length(Path)) or (Path[I + 2] = '/')) then
    begin
      Result := Result.Parent;
      Inc(I, 2);
    end
    else if CharInSet(Path[I], ['.', '/', ':']) then
      Inc(I)
    else
    begin
      First := I;
      while (I <= Length(Path)) and not CharInSet(Path[I], ['.', '/', ':']) do
        Inc(I);
      Part := Copy(Path, First, I - First);
      if VM.SWFVersion < 7 then
        Part := AVMLowerName(Part);
      if AVMParseLevelName(Part, VM.SWFVersion, LevelId) then
        Result := LevelClip(LevelId, False)
      else if Part = '_root' then
        Result := ClipRoot(Result)
      else if Part = '_parent' then
        Result := Result.Parent
      else if Part <> 'this' then
        Result := Clip(VM.Get(Result.Script, Part).Obj);
    end;
    if (Result = nil) or Result.Dead then
      Exit(nil);
  end;
end;

procedure TFlashPlayer.DisconnectMask(C: TFlashClip);
begin
  if C.Masker <> nil then
  begin
    C.Masker.Maskee := nil;
    C.Masker := nil;
  end;
  if C.Maskee <> nil then
  begin
    C.Maskee.Masker := nil;
    C.Maskee := nil;
  end;
end;

function TFlashPlayer.ScrollRectProperty(C: TFlashClip; const Name: string; const Args: TArray<TAVMValue>): TAVMValue;
const
  Fields: array[0..3] of string = ('x', 'y', 'width', 'height');
var
  Rect, Viewport: TSWFRect;
  I: Integer;
  O: TAVMObject;
  Key: string;
  Values: array[0..3] of Integer;

  function PixelTwips(Pixels: Integer): Integer;
  var
    Bits: Cardinal;
  begin
    Bits := Cardinal((Int64(Pixels) * 20) and $FFFFFFFF);
    Move(Bits, Result, SizeOf(Result));
  end;

begin
  Result := Default(TAVMValue);
  if C.Dead or C.Removing then
    Exit;
  if Name = 'MovieClip.getScrollRect' then
  begin
    if C.HasScrollRect then
    begin
      Rect := C.NextScrollRect;
      Viewport := ScrollViewport(Rect);
      Result := AVMNewGeometry(VM, 'Rectangle', [TAVMValue.Num(Rect.Left / 20), TAVMValue.Num(Rect.Top / 20),
          TAVMValue.Num(Viewport.Right / 20), TAVMValue.Num(Viewport.Bottom / 20)]);
    end;
    Exit;
  end;
  O := nil;
  if Length(Args) > 0 then
    O := Args[0].Obj;
  C.HasScrollRect := O <> nil;
  if O = nil then
    Exit;
  // AVM1 converts stored own fields in order, without invoking their getters.
  for I := Low(Fields) to High(Fields) do
  begin
    if not VM.FindOwnKey(O, Fields[I], Key) then
      Exit;
    Values[I] := AVMToInt32(VM.CoerceNumber(VM.GetOwnStored(O, Key)));
  end;
  if C.Dead or C.Removing then
    Exit;
  Rect.Left := PixelTwips(Values[0]);
  Rect.Top := PixelTwips(Values[1]);
  Rect.Right := PixelTwips(SWFAddCoordinate(Values[0], Values[2]));
  Rect.Bottom := PixelTwips(SWFAddCoordinate(Values[1], Values[3]));
  C.NextScrollRect := Rect;
end;

function TFlashPlayer.SetClipMask(C: TFlashClip; const Args: TArray<TAVMValue>): TAVMValue;
var
  Start, Mask: TFlashClip;
  Path: string;
begin
  Result := Default(TAVMValue);
  if (C = nil) or C.Dead or C.Removing or (Length(Args) = 0) then
    Exit;
  Mask := nil;
  if not (Args[0].Kind in [avUndefined, avNull]) then
  begin
    Mask := Clip(Args[0].Obj);
    if Mask = nil then
    begin
      Path := VM.CoerceString(Args[0]);
      if Path = '' then
        Exit(TAVMValue.Bool(False));
      Start := Clip(VM.CurrentTarget);
      if (Start = nil) or Start.Dead or Start.Removing then
        Start := Clip(VM.Root);
      Mask := ResolveClip(Start, TAVMValue.Str(Path));
    end;
    if (Mask = nil) or Mask.Dead or Mask.Removing then
      Exit(TAVMValue.Bool(False));
    // Target coercion can run guest code and remove the receiver.
    if C.Dead or C.Removing then
      Exit;
  end;
  if C.Masker <> nil then
    C.Masker.Maskee := nil;
  C.ClipDepth := 0;
  C.Masker := Mask;
  if Mask <> nil then
  begin
    if Mask.Maskee <> nil then
      Mask.Maskee.Masker := nil;
    Mask.ClipDepth := 0;
    Mask.Maskee := C;
  end;
  Result := TAVMValue.Bool(True);
end;

function TFlashPlayer.DuplicateClip(Source: TFlashClip; const Name: string; Depth: Integer; Initial: TAVMObject): TFlashClip;
var
  Action: TSWFClipAction;
begin
  Result := nil;
  if (Source = nil) or Source.Dead or (Source.Parent = nil) or
    (Depth < 0) or (Depth > 2130706428) then
    Exit;
  Result := AddClip(Source.Parent, Name, Depth, Source.Character);
  Result.MorphRatio := Source.MorphRatio;
  Result.BlendMode := Source.BlendMode;
  Result.Filters := Source.Filters;
  Result.AttachedBitmap := Source.AttachedBitmap;
  Result.AttachedBitmapBounds := Source.AttachedBitmapBounds;
  Result.AttachedBitmapSmooth := Source.AttachedBitmapSmooth;
  Result.SetMatrix(Source.Matrix);
  Result.ColorTransform := Source.ColorTransform;
  Result.Alpha := Source.Alpha;
  Result.Drawing.Fills := Copy(Source.Drawing.Fills);
  Result.Drawing.Edges := Copy(Source.Drawing.Edges);
  Result.Drawing.StrokePaths := Copy(Source.Drawing.StrokePaths);
  Result.FDrawingEdgeCount := Source.FDrawingEdgeCount;
  if Source.FStrokePoints <> nil then
    Result.FStrokePoints := TList<TSWFPoint>.Create(Source.FStrokePoints);
  Result.DrawingTouched := Source.DrawingTouched;
  Result.Drawing.ShapeBounds := Source.Drawing.ShapeBounds;
  Result.Drawing.PathBounds := Source.Drawing.PathBounds;
  Result.Fill := Source.Fill;
  Result.StrokeFill := Source.StrokeFill;
  Result.PenX := Source.PenX;
  Result.PenY := Source.PenY;
  Result.StartX := Source.StartX;
  Result.StartY := Source.StartY;
  for Action in Source.ClipActions do
    Result.ClipActions.Add(Action);
  Result.IsText := Source.IsText;
  Result.IsEditable := Source.IsEditable;
  InitializeAttachedClip(Result, Initial);
end;

function TFlashPlayer.CreateClip: TFlashClip;
begin
  if FClips.Count >= 65536 then
    raise ESWFError.Create('Flash clip limit');
  Result := TFlashClip.Create;
  FClips.Add(Result);
  Inc(FClipSerial);
  Result.FSerial := FClipSerial;
end;

function TFlashPlayer.AddClip(Parent: TFlashClip; const Name: string; Depth: Integer; Character: TSWFCharacter; ReplaceDepth: Boolean): TFlashClip;
var
  SymbolName: string;
  ConstructorValue: TAVMValue;
  PreviousVersion: Byte;
begin
  if Parent = nil then
    Parent := FRoot;
  var Ancestor := Parent;
  var Nesting := 0;
  while Ancestor <> nil do
  begin
    Inc(Nesting);
    if Nesting > 128 then
      raise ESWFError.Create('Flash display nesting limit');
    Ancestor := Ancestor.Parent;
  end;
  if ReplaceDepth then
    for var C in Parent.Children.ToArray do
      if C.Depth = Depth then
        RemoveClip(C);
  Result := CreateClip;
  Result.Parent := Parent;
  Result.MovieLibrary := Parent.MovieLibrary;
  Result.Name := Name;
  Result.Depth := Depth;
  Result.Character := Character;
  Result.CreatedFrame := FFrameNumber;
  if (Character <> nil) and (Character.Video <> nil) then
  begin
    Result.Script := VM.NewObject('Video');
    VM.PutData(Result.Script, '__proto__', TAVMValue.Ref(FNet.VideoPrototype));
  end
  else if (Character <> nil) and (Character.Kind in [7, 34]) then
    Result.Script := VM.NewObject('Button')
  else
    Result.Script := VM.NewObject('MovieClip');
  Result.Script.HostData := Result;
  if (Character <> nil) and (Character.Kind = 39) then
  begin
    PreviousVersion := VM.SWFVersion;
    VM.SWFVersion := Result.MovieLibrary.Movie.Version;
    try
      if Result.MovieLibrary.Symbols.TryGetValue(Character.Id, SymbolName) then
        Result.RegisteredConstructor := VM.RegisteredClass(SymbolName);
    finally
      VM.SWFVersion := PreviousVersion;
    end;
    ConstructorValue := TAVMValue.Ref(Result.RegisteredConstructor);
    if ConstructorValue.Obj = nil then
      ConstructorValue := VM.GetSpecial(VM.Global, 'MovieClip');
    VM.PutData(Result.Script, '__proto__', VM.GetData(ConstructorValue.Obj, 'prototype'));
  end;
  Parent.Children.Add(Result);
  if Name <> '' then
    VM.Put(Parent.Script, Name, TAVMValue.Ref(Result.Script));
  if (Character <> nil) and (Character.Kind in [7, 34]) then
  begin
    for var B in Character.Buttons do
    begin
      var Definition: TSWFCharacter;
      if not Result.MovieLibrary.Movie.Characters.TryGetValue(B.CharacterId, Definition) then
        raise ESWFError.Create('Missing button character');
      var Child := AddClip(Result, '', B.Depth, Definition, False);
      Child.ButtonStates := B.States;
      Child.SetMatrix(B.Matrix);
      Child.ColorTransform := B.ColorTransform;
      TryAVMBlendCode(B.BlendMode, Child.BlendMode);
      Child.Filters := B.Filters;
    end;
  end;
  if (Character <> nil) and (Character.Kind = 37) then
  begin
    InitializeTextField(Result);
    var R := TSWFReader.Create(Character.Data, Result.MovieLibrary.Movie.Version);
    try
      var Bounds := R.Rect;
      Result.TextLeft := Bounds.Left / 20;
      Result.TextTop := Bounds.Top / 20;
      Result.IsText := True;
      Result.TextWidth := (Bounds.Right - Bounds.Left) / 20;
      Result.TextHeight := (Bounds.Bottom - Bounds.Top) / 20;
      var Flags := R.U8;
      var Flag2 := R.U8;
      Result.IsEditable := (Flags and 8) = 0;
      Result.TextMultiline := (Flags and $20) <> 0;
      if (Flags and 1) <> 0 then
        Result.FontId := R.U16;
      if (Flag2 and $80) <> 0 then
        R.Str;
      if (Flags and 1) <> 0 then
        Result.TextSize := R.U16 / 20;
      if (Flags and 4) <> 0 then
        Result.TextColor := SWFColor(R, True);
      if (Flags and 2) <> 0 then
        R.U16;
      if (Flag2 and $20) <> 0 then
      begin
        Result.TextAlign := R.U8;
        Result.TextLeftMargin := R.U16 / 20;
        Result.TextRight := R.U16 / 20;
        Result.TextIndent := R.U16 / 20;
        Result.TextLeading := R.S16 / 20;
      end;
      Result.VariableName := R.Str;
      Result.TextDocument.HTML := (Flag2 and 2) <> 0;
      if (Flags and $80) <> 0 then
      begin
        if Result.TextDocument.HTML then
          Result.HTMLText := R.Str
        else
          Result.Text := R.Str;
      end;
    finally
      R.Free;
    end;
  end;
end;

procedure TFlashPlayer.RemoveClip(C: TFlashClip);
var
  Child: TFlashClip;
  HasUnload: Boolean;
  Action: TSWFClipAction;
  Request: TFlashUnloadRequest;
begin
  if (C = nil) or C.IsLevel or C.Dead or C.Removing then
    Exit;
  FAudio.StopOwner(C);
  HasUnload := False;
  for Child in C.Children.ToArray do
  begin
    RemoveClip(Child);
    HasUnload := HasUnload or Child.Removing;
  end;
  Inc(C.LoadGeneration);
  if FTextFocus = C then
    FTextFocus := nil;
  if FPressed = C then
    FPressed := nil;
  if FHovered = C then
    FHovered := nil;
  DisconnectMask(C);
  if C.Parent <> nil then
    C.Parent.Children.Remove(C);
  HasUnload := HasUnload or VM.HasProperty(C.Script, 'onUnload');
  for Action in C.ClipActions do
    HasUnload := HasUnload or ((Action.Events and SWFClipUnload) <> 0);
  if not HasUnload then
  begin
    FinalizeRemoval(C);
    Exit;
  end;
  C.Removing := True;
  Request := Default(TFlashUnloadRequest);
  Request.Clip := C;
  Request.Generation := C.LoadGeneration;
  Request.ReadyFrame := FFrameNumber;
  Request.Remove := True;
  if FUnloads.Count >= 65536 then
    raise ESWFError.Create('Flash pending unload limit');
  FUnloads.Add(Request);
end;

function NativePropertyName(const RequestedName: string; Legacy: Boolean): string;
var
  Folded: string;
begin
  Folded := AVMLowerName(RequestedName);
  if MatchStr(Folded, ['_x', '_y', '_xscale', '_yscale', '_rotation', '_alpha', '_visible',
      '_name', '_currentframe', '_totalframes', '_framesloaded', '_width', '_height', '_target', '_xmouse', '_ymouse']) then
    Exit(Folded);
  Result := RequestedName;
  if not Legacy then
    Exit;
  if MatchStr(Folded, ['_root', '_parent', 'text', 'length']) then
    Result := Folded
  else if Folded = 'htmltext' then
    Result := 'htmlText'
  else if Folded = 'textcolor' then
    Result := 'textColor';
end;

function TFlashPlayer.ObjectType(O: TAVMObject): string;
var
  C: TFlashClip;
begin
  Result := 'object';
  C := Clip(O);
  if (C <> nil) and not C.IsText and (C.AttachedBitmap = nil) and
    ((C.Character = nil) or (C.Character.Kind = 39) or C.MovieRoot) then
    Result := 'movieclip';
end;

function TFlashPlayer.StringValue(O: TAVMObject; out Text: string): Boolean;
var
  C: TFlashClip;
  Depth: Integer;
begin
  C := Clip(O);
  Text := '';
  Result := C <> nil;
  if not Result then
    Exit;
  Depth := 0;
  while C.Parent <> nil do
  begin
    Text := '.' + C.Name + Text;
    C := C.Parent;
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('Flash display nesting limit');
  end;
  if C.IsLevel then
    Text := '_level' + IntToStr(C.LevelIndex) + Text
  else
    Text := '_level0' + Text;
end;

procedure TFlashPlayer.InitializeTextField(C: TFlashClip);
var
  ConstructorValue: TAVMValue;
  Listeners: TAVMObject;
begin
  C.IsText := True;
  C.Script.ClassName := 'TextField';
  ConstructorValue := VM.Get(VM.Global, 'TextField');
  VM.PutData(C.Script, '__proto__', VM.GetData(ConstructorValue.Obj, 'prototype'));
  Listeners := VM.CreateArray([TAVMValue.Ref(C.Script)]);
  VM.PutData(C.Script, '_listeners', TAVMValue.Ref(Listeners));
  C.Script.Attributes.AddOrSetValue('_listeners', 3);
end;

function TFlashPlayer.ReadBoundTextVariable(C: TFlashClip): TAVMValue;
var
  PreviousRoot: TAVMObject;
  PreviousVersion: Byte;
  PreviousContext: TObject;
begin
  if C.Parent = nil then
    Exit(Default(TAVMValue));
  PreviousRoot := VM.Root;
  PreviousVersion := VM.SWFVersion;
  PreviousContext := VM.MovieContext;
  VM.Root := ClipRoot(C).Script;
  VM.SWFVersion := C.MovieLibrary.Movie.Version;
  VM.MovieContext := C.MovieLibrary;
  try
    Result := VM.GetBoundVariable(C.Parent.Script, C.VariableName);
  finally
    VM.Root := PreviousRoot;
    VM.SWFVersion := PreviousVersion;
    VM.MovieContext := PreviousContext;
  end;
end;

function TFlashPlayer.TextFieldCall(const Name: string; C: TFlashClip; const Args: TArray<TAVMValue>): TAVMValue;
var
  PropertyName, Text: string;
  Value, ErrorValue: TAVMValue;
  First, Last: Integer;
  Data: TAVMTextFormatData;
  HasError: Boolean;

  function Arg(Index: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if Index < Length(Args) then
      Result := Args[Index];
  end;

  function Increment(Value: Integer): Integer;
  begin
    if Value = High(Integer) then
      Result := Low(Integer)
    else
      Result := Value + 1;
  end;

begin
  Result := Default(TAVMValue);
  if Name.StartsWith('get.') then
  begin
    PropertyName := Copy(Name, 5, MaxInt);
    if PropertyName = 'text' then
      Exit(TAVMValue.Str(C.Text));
    if PropertyName = 'htmlText' then
      Exit(TAVMValue.Str(C.HTMLText));
    if PropertyName = 'length' then
      Exit(TAVMValue.Num(Length(C.Text)));
    if PropertyName = 'textColor' then
    begin
      Value := C.TextDocument.DefaultFormat.Values[2];
      if Value.Kind = avNull then
        Exit;
      Exit(TAVMValue.Num(Cardinal(AVMToInt32(Value.Number)) and $FFFFFF));
    end;
    if PropertyName = 'html' then
      Exit(TAVMValue.Bool(C.TextDocument.HTML));
    if PropertyName = 'type' then
    begin
      if C.IsEditable then
        Exit(TAVMValue.Str('input'))
      else
        Exit(TAVMValue.Str('dynamic'));
    end;
    if PropertyName = 'multiline' then
      Exit(TAVMValue.Bool(C.TextMultiline));
    Exit;
  end;
  if Name.StartsWith('set.') then
  begin
    PropertyName := Copy(Name, 5, MaxInt);
    Value := Arg(0);
    if PropertyName = 'text' then
    begin
      Text := '';
      if not (Value.Kind in [avNull, avUndefined]) then
        Text := VM.CoerceString(Value);
      C.Text := Text;
    end
    else if PropertyName = 'htmlText' then
      C.HTMLText := VM.CoerceString(Value)
    else if PropertyName = 'html' then
      C.TextDocument.HTML := Value.AsBoolean(VM.SWFVersion)
    else if PropertyName = 'multiline' then
    begin
      C.TextMultiline := Value.AsBoolean(VM.SWFVersion);
      C.TextDocument.Multiline := C.TextMultiline;
    end
    else if PropertyName = 'type' then
    begin
      Text := VM.CoerceString(Value);
      if Text = 'input' then
        C.IsEditable := True
      else if Text = 'dynamic' then
        C.IsEditable := False;
    end
    else if PropertyName = 'textColor' then
    begin
      First := AVMToInt32(VM.CoerceNumber(Value));
      Data := TAVMTextFormatData.Create;
      try
        Data.Values[2] := TAVMValue.Num(Cardinal(First) and $FFFFFF);
        C.TextDocument.SetFormat(0, Length(C.Text), Data);
        C.TextDocument.SetDefault(Data, False);
      finally
        Data.Free;
      end;
    end;
    Exit;
  end;
  if Name = 'removeTextField' then
  begin
    if C.Depth >= 16384 then
      RemoveClip(C);
    Exit;
  end;
  if Name = 'getNewTextFormat' then
    Exit(TAVMValue.Ref(AVMNewTextFormat(VM, C.TextDocument.DefaultFormat)));
  if Name = 'setNewTextFormat' then
  begin
    Value := Arg(0);
    if (Value.Obj <> nil) and (Value.Obj.TextFormatData <> nil) then
      C.TextDocument.SetDefault(Value.Obj.TextFormatData);
    Exit;
  end;
  if Name = 'getTextFormat' then
  begin
    First := 0;
    Last := High(Integer);
    if Length(Args) > 0 then
    begin
      First := AVMToInt32(VM.CoerceNumber(Arg(0)));
      Last := Increment(First);
      if Length(Args) > 1 then
        Last := AVMToInt32(VM.CoerceNumber(Arg(1)));
    end;
    Data := C.TextDocument.GetFormat(First, Last);
    try
      Result := TAVMValue.Ref(AVMNewTextFormat(VM, Data));
    finally
      Data.Free;
    end;
    Exit;
  end;
  if Name = 'setTextFormat' then
  begin
    if Length(Args) = 0 then
      Exit;
    First := 0;
    Last := Length(C.Text);
    Value := Arg(0);
    HasError := False;
    if Length(Args) >= 3 then
    begin
      First := Max(0, AVMToInt32(VM.CoerceNumber(Arg(0))));
      Last := Max(0, AVMToInt32(VM.CoerceNumber(Arg(1))));
      Value := Arg(2);
    end
    else if Length(Args) = 2 then
    begin
      try
        First := AVMToInt32(VM.CoerceNumber(Arg(0)));
      except
        on E: EAVMThrown do
        begin
          ErrorValue := E.Value;
          HasError := True;
          First := 0;
        end;
      end;
      Last := Max(0, Increment(First));
      First := Max(0, First);
      Value := Arg(1);
    end;
    if (Value.Obj <> nil) and (Value.Obj.TextFormatData <> nil) then
      C.TextDocument.SetFormat(First, Last, Value.Obj.TextFormatData);
    if HasError then
      raise EAVMThrown.CreateValue(ErrorValue, 'AVM1 text format index exception');
  end;
end;

function TFlashPlayer.ResolveDragTarget(Start: TAVMObject; const Value: TAVMValue): TAVMObject;
var
  C: TFlashClip;
begin
  C := ResolveClip(Clip(Start), Value);
  Result := nil;
  if (C <> nil) and not C.Dead and not C.Removing then
    Result := C.Script;
end;

procedure TFlashPlayer.StartDrag(Target: TAVMObject; LockCenter: Boolean; const Bounds: TArray<Double>);
var
  C: TFlashClip;
  Values: array[0..3] of Integer;
  I, Temp: Integer;
  Value: Double;
begin
  C := Clip(Target);
  if (C = nil) or C.Dead or C.Removing then
    Exit;
  FDragClip := C;
  FDragLocked := LockCenter;
  FDragConstrained := Length(Bounds) = 4;
  FDragLastX := SWFTwipsFromPixels(Double(FMouseX) + Movie.Stage.Left / 20);
  FDragLastY := SWFTwipsFromPixels(Double(FMouseY) + Movie.Stage.Top / 20);
  if FDragConstrained then
  begin
    for I := 0 to 3 do
    begin
      Value := Bounds[I];
      if IsNan(Value) or IsInfinite(Value) then
        Value := 0;
      Values[I] := SWFTwipsFromPixels(Value);
    end;
    if Values[2] < Values[0] then
    begin
      Temp := Values[0];
      Values[0] := Values[2];
      Values[2] := Temp;
    end;
    if Values[3] < Values[1] then
    begin
      Temp := Values[1];
      Values[1] := Values[3];
      Values[3] := Temp;
    end;
    FDragBounds.Left := Values[0];
    FDragBounds.Top := Values[1];
    FDragBounds.Right := Values[2];
    FDragBounds.Bottom := Values[3];
  end;
end;

procedure TFlashPlayer.StopDrag;
begin
  UpdateDrag;
  FDragClip := nil;
end;

procedure TFlashPlayer.UpdateDrag;
var
  C, Drop, Root: TFlashClip;
  ParentMatrix, InverseMatrix, VectorMatrix, Position: TSWFMatrix;
  MouseX, MouseY, X, Y, DX, DY: Integer;
  WasVisible: Boolean;
  Roots: TArray<TFlashClip>;
  I: Integer;

  function Difference(A, B: Integer): Integer;
  var
    Bits: Cardinal;
  begin
    Bits := Cardinal((Int64(A) - B) and $FFFFFFFF);
    Move(Bits, Result, SizeOf(Result));
  end;

begin
  if FUpdatingDrag or (FDragClip = nil) then
    Exit;
  C := FDragClip;
  if C.Dead or C.Removing then
  begin
    FDragClip := nil;
    Exit;
  end;
  FUpdatingDrag := True;
  try
    ParentMatrix := TSWFMatrix.Identity;
    if C.Parent <> nil then
      ParentMatrix := WorldMatrix(C.Parent);
    if not SWFInverseMatrix(ParentMatrix, InverseMatrix) then
      InverseMatrix := TSWFMatrix.Identity;
    MouseX := SWFTwipsFromPixels(Double(FMouseX) + Movie.Stage.Left / 20);
    MouseY := SWFTwipsFromPixels(Double(FMouseY) + Movie.Stage.Top / 20);
    Position := C.Matrix;
    if FDragLocked then
      SWFTransformPoint(InverseMatrix, MouseX, MouseY, X, Y)
    else
    begin
      VectorMatrix := InverseMatrix;
      VectorMatrix.TX := 0;
      VectorMatrix.TY := 0;
      SWFTransformPoint(VectorMatrix, Difference(MouseX, FDragLastX), Difference(MouseY, FDragLastY), DX, DY);
      X := SWFAddCoordinate(Trunc(Position.TX), DX);
      Y := SWFAddCoordinate(Trunc(Position.TY), DY);
    end;
    if FDragConstrained then
    begin
      X := EnsureRange(X, FDragBounds.Left, FDragBounds.Right);
      Y := EnsureRange(Y, FDragBounds.Top, FDragBounds.Bottom);
    end;
    if not FDragLocked then
    begin
      VectorMatrix := ParentMatrix;
      VectorMatrix.TX := 0;
      VectorMatrix.TY := 0;
      SWFTransformPoint(VectorMatrix, Difference(X, Trunc(Position.TX)), Difference(Y, Trunc(Position.TY)), DX, DY);
      FDragLastX := SWFAddCoordinate(FDragLastX, DX);
      FDragLastY := SWFAddCoordinate(FDragLastY, DY);
    end;
    C.SetPositionTwips(X, Y);
    C.TransformedByScript := True;
    WasVisible := C.Visible;
    C.Visible := False;
    try
      Drop := nil;
      Roots := LevelClips;
      for I := High(Roots) downto 0 do
      begin
        Root := Roots[I];
        Drop := Hit(Root, MouseX / 20, MouseY / 20, TSWFMatrix.Identity, False);
        if Drop <> nil then
          Break;
      end;
      while (Drop <> nil) and (Drop.Character <> nil) and
            not (Drop.Character.Kind in [7, 34, 37, 39]) do
        Drop := Drop.Parent;
      C.DropTarget := Drop;
    finally
      C.Visible := WasVisible;
    end;
  finally
    FUpdatingDrag := False;
  end;
end;

const
  FlashQualityNames: array[TFlashQuality] of string =
    ('LOW', 'MEDIUM', 'HIGH', 'BEST', '8X8', '8X8LINEAR', '16X16', '16X16LINEAR');

procedure TFlashPlayer.SetAVM2CollectionObserver(const Observer: TAVM2CollectionObserver);
begin
  FOnAVM2Collection := Observer;
  for var LibraryItem in FLibraries do
    if LibraryItem.AVM2 <> nil then
      LibraryItem.AVM2.OnCollection := Observer;
end;

procedure TFlashPlayer.SetAVM2ReclaimObserver(const Observer: TAVM2ReclaimObserver);
begin
  FOnAVM2Reclaim := Observer;
  for var LibraryItem in FLibraries do
    if LibraryItem.AVM2 <> nil then
      LibraryItem.AVM2.OnReclaim := Observer;
end;

procedure TFlashPlayer.SetQuality(Value: TFlashQuality);
begin
  FQuality := Value;
  FPreferBest := Value >= fqBest;
end;

procedure TFlashPlayer.ToggleQuality;
begin
  // ActionToggleQuality remembers whether best-quality downsampling was selected.
  if FQuality in [fqHigh, fqBest] then
    FQuality := fqLow
  else if FPreferBest then
    FQuality := fqBest
  else
    FQuality := fqHigh;
end;

function TFlashPlayer.GetMember(O: TAVMObject; const RequestedName: string; out Value: TAVMValue): Boolean;
var
  C: TFlashClip;
  Name: string;
  LevelId: Integer;
  LevelScript: TAVMObject;
  Bounds: TSWFBounds;
begin
  Value := Default(TAVMValue);
  if (RequestedName = '') or (RequestedName[1] <> '_') then
    Exit(False);
  C := Clip(O);
  if C = nil then
    Exit(False);
  Result := True;
  Name := NativePropertyName(RequestedName, VM.SWFVersion < 7);
  if (C.MovieLibrary.Movie.Version < 5) and MatchStr(Name, ['_xscale', '_yscale', '_rotation']) then
    C.SetMatrix(C.Matrix);
  if AVMParseLevelName(RequestedName, VM.SWFVersion, LevelId) then
  begin
    LevelScript := LevelObject(LevelId);
    if LevelScript <> nil then
      Value := TAVMValue.Ref(LevelScript);
  end
  else if SameText(Name, '_quality') then
  begin
    case FQuality of
      fq8x8Linear:
        Value := TAVMValue.Str('8X8');
      fq16x16Linear:
        Value := TAVMValue.Str('16X16');
    else
      Value := TAVMValue.Str(FlashQualityNames[FQuality]);
    end;
  end
  else if SameText(Name, '_highquality') then
  begin
    case FQuality of
      fqHigh:
        Value := TAVMValue.Num(1);
      fqBest:
        Value := TAVMValue.Num(2);
    else
      Value := TAVMValue.Num(0);
    end;
  end
  else if Name = '_root' then
    Value := TAVMValue.Ref(ClipRoot(C).Script)
  else if Name = '_parent' then
  begin
    if C.Parent <> nil then
      Value := TAVMValue.Ref(C.Parent.Script);
  end
  else if Name = '_x' then
    Value := TAVMValue.Num(C.X)
  else if Name = '_y' then
    Value := TAVMValue.Num(C.Y)
  else if Name = '_xscale' then
    Value := TAVMValue.Num(C.ScaleX * 100)
  else if Name = '_yscale' then
    Value := TAVMValue.Num(C.ScaleY * 100)
  else if Name = '_rotation' then
    Value := TAVMValue.Num(C.Rotation)
  else if Name = '_alpha' then
    Value := TAVMValue.Num(C.Alpha * 100)
  else if Name = '_visible' then
    Value := TAVMValue.Bool(C.Visible)
  else if Name = '_name' then
    Value := TAVMValue.Str(C.Name)
  else if Name = '_target' then
    Value := TAVMValue.Str(SlashPath(C))
  else if Name = '_droptarget' then
  begin
    Value := TAVMValue.Str('');
    if (C.DropTarget <> nil) and not C.DropTarget.Dead then
      Value := TAVMValue.Str(SlashPath(C.DropTarget));
  end
  else if Name = '_currentframe' then
    Value := TAVMValue.Num(C.Frame + 1)
  else if (Name = '_totalframes') or (Name = '_framesloaded') then
  begin
    if C.MovieRoot then
      Value := TAVMValue.Num(Length(C.MovieLibrary.Movie.Frames))
    else if C.Character <> nil then
      Value := TAVMValue.Num(Max(1, Length(C.Character.Frames)))
    else
      Value := TAVMValue.Num(1);
  end
  else if (Name = '_width') or (Name = '_height') then
  begin
    Bounds := BoundsWithMatrix(C, C.Matrix, False);
    if Name = '_width' then
      Value := TAVMValue.Num((Int64(Bounds.Rect.Right) - Bounds.Rect.Left) / 20)
    else
      Value := TAVMValue.Num((Int64(Bounds.Rect.Bottom) - Bounds.Rect.Top) / 20);
  end
  else if (Name = '_xmouse') or (Name = '_ymouse') then
  begin
    var M := WorldMatrix(C);
    var Det := M.A * M.D - M.B * M.C;
    var MX := Double(FMouseX) * 20 + Movie.Stage.Left - M.TX;
    var MY := Double(FMouseY) * 20 + Movie.Stage.Top - M.TY;
    if Abs(Det) < 1e-12 then
      Value := TAVMValue.Num(0)
    else if Name = '_xmouse' then
      Value := TAVMValue.Num((M.D * MX - M.C * MY) / Det / 20)
    else
      Value := TAVMValue.Num((-M.B * MX + M.A * MY) / Det / 20);
  end
  else
    Result := False;
end;

function TFlashPlayer.GetStoredMember(O: TAVMObject; const Name: string; out Value: TAVMValue): Boolean;
begin
  { TextField text/HTML/color properties are native accessors; only stage
    path/magic properties have stored native values for Object.watch. }
  Value := Default(TAVMValue);
  Result := (Name <> '') and (Name[1] = '_');
  if Result then
    Result := GetMember(O, Name, Value);
end;

function TFlashPlayer.SetMember(O: TAVMObject; const RequestedName: string; const Value: TAVMValue): Boolean;
var
  C: TFlashClip;
  N: Double;
  Name, Text: string;
  Setting: TFlashQuality;
begin
  C := Clip(O);
  if C = nil then
    Exit(False);
  Result := True;
  Name := NativePropertyName(RequestedName, VM.SWFVersion < 7);
  if SameText(Name, '_quality') then
  begin
    Text := VM.CoerceString(Value);
    for Setting := Low(TFlashQuality) to High(TFlashQuality) do
      if SameText(Text, FlashQualityNames[Setting]) then
      begin
        SetQuality(Setting);
        Break;
      end;
    Exit;
  end;
  if SameText(Name, '_highquality') then
  begin
    if Value.Kind in [avUndefined, avNull] then
      Exit;
    N := VM.CoerceNumber(Value);
    if IsNan(N) then
      Exit;
    if N > 1.5 then
      SetQuality(fqBest)
    else if N = 0 then
      SetQuality(fqLow)
    else
      SetQuality(fqHigh);
    Exit;
  end;
  if Name = '_name' then
  begin
    if (VM.SWFVersion >= 7) and (Value.Kind = avNumber) and IsNan(Value.Number) then
      C.Name := '0'
    else
      C.Name := VM.CoerceString(Value);
    Exit;
  end;
  if MatchStr(Name, ['_currentframe', '_totalframes', '_framesloaded', '_target', '_droptarget', '_xmouse', '_ymouse']) then
    Exit;
  if not MatchStr(Name, ['_x', '_y', '_xscale', '_yscale', '_rotation', '_alpha', '_width', '_height', '_visible']) then
    Exit(False);
  if Value.Kind in [avUndefined, avNull] then
    Exit;
  N := VM.CoerceNumber(Value);
  if IsNan(N) then
    Exit;
  if (C.MovieLibrary.Movie.Version < 5) and MatchStr(Name, ['_xscale', '_yscale', '_rotation', '_width', '_height']) then
    C.SetMatrix(C.Matrix);
  if Name = '_visible' then
  begin
    C.Visible := N <> 0;
    Exit;
  end;
  C.TransformedByScript := True;
  if Name = '_x' then
  begin
    if IsInfinite(N) then
      N := NegInfinity;
    C.SetPosition(N, C.Y);
  end
  else if Name = '_y' then
  begin
    if IsInfinite(N) then
      N := NegInfinity;
    C.SetPosition(C.X, N);
  end
  else if Name = '_xscale' then
    C.SetScale(0, N / 100)
  else if Name = '_yscale' then
    C.SetScale(1, N / 100)
  else if Name = '_rotation' then
  begin
    N := AVMBinaryNumber($3F, N, 360);
    if N < -180 then
      N := N + 360
    else if N > 180 then
      N := N - 360;
    C.SetRotation(N);
  end
  else if Name = '_alpha' then
  begin
    if IsInfinite(N) then
      N := 0;
    C.Alpha := N / 100;
  end
  else if Name = '_width' then
    SetDisplaySize(C, N, True)
  else if Name = '_height' then
    SetDisplaySize(C, N, False);
end;

procedure TFlashPlayer.AddDrawingEdge(C: TFlashClip; X1, Y1, X2, Y2: Double);
var
  Edge: TSWFEdge;
  Point: TSWFPoint;
begin
  if (C.Fill = 0) and (C.StrokeFill = 0) then
    Exit;
  if C.FDrawingEdgeCount >= 1000000 then
    raise ESWFError.Create('Flash drawing edge limit');
  Inc(C.FDrawingEdgeCount);
  AddDrawingBounds(C, TSWFBounds.Line(X1, Y1, X2, Y2));
  if C.Fill <> 0 then
  begin
    Edge.Fill := C.Fill;
    Edge.X1 := X1;
    Edge.Y1 := Y1;
    Edge.X2 := X2;
    Edge.Y2 := Y2;
    C.Drawing.Edges := C.Drawing.Edges + [Edge];
  end;
  if C.StrokeFill = 0 then
    Exit;
  if C.FStrokePoints = nil then
    C.FStrokePoints := TList<TSWFPoint>.Create;
  if C.FStrokePoints.Count = 0 then
  begin
    Point.X := X1;
    Point.Y := Y1;
    C.FStrokePoints.Add(Point);
  end;
  Point.X := X2;
  Point.Y := Y2;
  C.FStrokePoints.Add(Point);
end;

procedure TFlashPlayer.AddDrawingBounds(C: TFlashClip; const Bounds: TSWFBounds);
begin
  if (C.Fill = 0) and (C.StrokeFill = 0) then
    Exit;
  C.Drawing.PathBounds.Include(Bounds);
  if C.Fill <> 0 then
    C.Drawing.ShapeBounds.Include(Bounds);
  if C.StrokeFill <> 0 then
    C.Drawing.ShapeBounds.Include(Bounds.Expanded(C.Drawing.Fills[C.StrokeFill - 1].Line.Width / 2));
end;

procedure TFlashPlayer.CloseDrawingContour(C: TFlashClip);
var
  Edge: TSWFEdge;
begin
  if C.PendingFillEdge(Edge) then
    AddDrawingEdge(C, Edge.X1, Edge.Y1, Edge.X2, Edge.Y2);
  C.FinishDrawingStroke;
end;

procedure TFlashPlayer.SetDrawingFill(C: TFlashClip; const Style: TSWFFill; Enabled: Boolean);
var
  LineStyle: TSWFFill;
  NewStyles: Integer;
begin
  if C.Dead or C.Removing then
    Exit;
  NewStyles := Ord(Enabled);
  if Enabled and (C.StrokeFill <> 0) then
    Inc(NewStyles);
  if Length(C.Drawing.Fills) + NewStyles > 65536 then
    raise ESWFError.Create('Flash drawing fill limit');
  CloseDrawingContour(C);
  C.DrawingTouched := True;
  C.Fill := 0;
  C.StartX := C.PenX;
  C.StartY := C.PenY;
  if not Enabled then
    Exit;
  C.Drawing.Fills := C.Drawing.Fills + [Style];
  C.Fill := Length(C.Drawing.Fills);
  if C.StrokeFill <> 0 then
  begin
    // The current stroke continues above the new fill, while older paths stay below it.
    LineStyle := C.Drawing.Fills[C.StrokeFill - 1];
    C.Drawing.Fills := C.Drawing.Fills + [LineStyle];
    C.StrokeFill := Length(C.Drawing.Fills);
  end;
end;

procedure TFlashPlayer.SetDrawingLine(C: TFlashClip; const Style: TSWFFill; Enabled: Boolean);
begin
  if C.Dead or C.Removing then
    Exit;
  if Enabled and (Length(C.Drawing.Fills) >= 65536) then
    raise ESWFError.Create('Flash drawing fill limit');
  C.FinishDrawingStroke;
  C.DrawingTouched := True;
  C.StrokeFill := 0;
  if not Enabled then
    Exit;
  C.Drawing.Fills := C.Drawing.Fills + [Style];
  C.StrokeFill := Length(C.Drawing.Fills);
end;

function TFlashPlayer.ReadLibraryBitmap(const Name: string): IImagePixelBuffer;
var
  LibraryMovie: TFlashLibrary;
  Target: TFlashClip;
  Definition: TSWFCharacter;
  Id, X, Y, Index: Integer;
begin
  Result := nil;
  Target := Clip(VM.CurrentTarget);
  if Target = nil then
    Target := Clip(VM.Root);
  if Target = nil then
    Exit;
  LibraryMovie := Target.MovieLibrary;
  if not LibraryMovie.ExportNames.TryGetValue(AVMLowerName(Name), Id) or
    not LibraryMovie.Movie.Characters.TryGetValue(Id, Definition) or (Definition.BitmapWidth = 0) then
    Exit;
  VM.ChargeWork((Length(Definition.BitmapPixels) + 31) div 32);
  Result := VM.CreatePixelBuffer(Definition.BitmapWidth, Definition.BitmapHeight, True, 0);
  if Result = nil then
    Exit;
  Index := 0;
  for Y := 0 to Definition.BitmapHeight - 1 do
    for X := 0 to Definition.BitmapWidth - 1 do
    begin
      Result.SetPixel(X, Y, Definition.BitmapPixels[Index]);
      Inc(Index);
    end;
end;

procedure TFlashPlayer.AttachBitmap(C: TFlashClip; const Args: TArray<TAVMValue>);
var
  Bitmap: IImagePixelBuffer;
  Child: TFlashClip;
  Depth: Integer;
  Bounds: TSWFRect;
begin
  if (Length(Args) < 2) or (Args[0].Obj = nil) then
    Exit;
  Bitmap := Args[0].Obj.BitmapData;
  if Bitmap = nil then
    Exit;
  Depth := BiasedDepth(AVMToInt32(VM.CoerceNumber(Args[1])));
  Child := AddClip(C, '', Depth, nil);
  Child.AttachedBitmap := Bitmap;
  Bounds := Default(TSWFRect);
  Bounds.Right := Bitmap.Width * 20;
  Bounds.Bottom := Bitmap.Height * 20;
  Child.AttachedBitmapBounds := TSWFBounds.FromRect(Bounds);
  if Length(Args) >= 4 then
    Child.AttachedBitmapSmooth := Args[3].AsBoolean(VM.SWFVersion);
end;

function TFlashPlayer.ReadBitmapFillMatrix(const Value: TAVMValue): TSWFMatrix;
const
  Names: array[0..5] of string = ('a', 'b', 'c', 'd', 'tx', 'ty');
var
  Values: array[0..5] of TAVMValue;
  Index: Integer;
  Key: string;
  O: TAVMObject;
begin
  Result := TSWFMatrix.Identity;
  Result.A := 20;
  Result.D := 20;
  O := Value.Obj;
  if O = nil then
    Exit;

  for Index := 0 to High(Names) do
  begin
    if not VM.FindOwnKey(O, Names[Index], Key) or
      ((O.Accessors <> nil) and O.Accessors.ContainsKey(Key)) then
      Exit;
    Values[Index] := VM.GetData(O, Key);
  end;
  Result.A := SWFFloat32(SWFFloat32(VM.CoerceNumber(Values[0])) * 20);
  Result.B := SWFFloat32(SWFFloat32(VM.CoerceNumber(Values[1])) * 20);
  Result.C := SWFFloat32(SWFFloat32(VM.CoerceNumber(Values[2])) * 20);
  Result.D := SWFFloat32(SWFFloat32(VM.CoerceNumber(Values[3])) * 20);
  Result.TX := SWFTwipsFromPixels(VM.CoerceNumber(Values[4]));
  Result.TY := SWFTwipsFromPixels(VM.CoerceNumber(Values[5]));
end;

procedure TFlashPlayer.BeginBitmapFill(C: TFlashClip; const Args: TArray<TAVMValue>);
var
  Style: TSWFFill;
begin
  Style := Default(TSWFFill);
  if (Length(Args) > 0) and (Args[0].Obj <> nil) then
    Style.BitmapData := Args[0].Obj.BitmapData;
  if Style.BitmapData <> nil then
  begin
    if Length(Args) > 1 then
      Style.BitmapMatrix := ReadBitmapFillMatrix(Args[1])
    else
      Style.BitmapMatrix := ReadBitmapFillMatrix(Default(TAVMValue));
    Style.BitmapRepeat := True;
    if Length(Args) > 2 then
      Style.BitmapRepeat := Args[2].AsBoolean(VM.SWFVersion);
    if Length(Args) > 3 then
      Style.BitmapSmooth := Args[3].AsBoolean(VM.SWFVersion);
  end;
  // Close the old path after evaluating the guest matrix.
  SetDrawingFill(C, Style, Style.BitmapData <> nil);
end;

function TFlashPlayer.DrawingOption(const Value: TAVMValue): string;
begin
  try
    Result := VM.CoerceString(Value);
  except
    on E: EAVMThrown do
      Result := '';
  end;
end;

function TFlashPlayer.ReadDrawingColor(const RGB, Alpha: TAVMValue): Cardinal;
var
  Color: Cardinal;
  Opacity: Double;
begin
  Color := Cardinal(AVMToInt32(VM.CoerceNumber(RGB))) and $FFFFFF;
  Opacity := VM.CoerceNumber(Alpha);
  if IsNan(Opacity) then
    Opacity := 0;
  Result := Color or (Cardinal(Trunc(EnsureRange(Opacity, 0.0, 100.0) / 100 * 255)) shl 24);
end;

function TFlashPlayer.ReadGradientMatrix(const Value: TAVMValue): TSWFMatrix;
var
  O: TAVMObject;
  Width, Height, Angle, ScaleX, ScaleY, SinAngle, CosAngle: Double;
  Left, Top: Integer;

  function Number(const Key: string): Double;
  begin
    Result := VM.CoerceNumber(VM.Get(O, Key));
  end;

begin
  O := VM.Box(Value);
  if VM.CoerceString(VM.Get(O, 'matrixType')) = 'box' then
  begin
    Width := SWFFloat32(Number('w'));
    Height := SWFFloat32(Number('h'));
    Angle := SWFFloat32(Number('r'));
    Left := SWFTwipsFromPixels(Number('x'));
    Top := SWFTwipsFromPixels(Number('y'));
    ScaleX := SWFFloat32(Width / SWFFloat32(1638.4));
    ScaleY := SWFFloat32(Height / SWFFloat32(1638.4));
    if IsNan(Angle) or IsInfinite(Angle) then
    begin
      SinAngle := NaN;
      CosAngle := NaN;
    end
    else
    begin
      SinAngle := SWFFloat32(Sin(Angle));
      CosAngle := SWFFloat32(Cos(Angle));
    end;
    Result.A := SWFFloat32(CosAngle * ScaleX);
    Result.B := SWFFloat32(SinAngle * ScaleY);
    Result.C := SWFFloat32(-SinAngle * ScaleX);
    Result.D := SWFFloat32(CosAngle * ScaleY);
    Result.TX := SWFAddCoordinate(Left, SWFTwipsFromPixels(Width / 2));
    Result.TY := SWFAddCoordinate(Top, SWFTwipsFromPixels(Height / 2));
  end
  else
  begin
    // AVM1 gradient coefficients already use the SWF gradient space.
    Result.A := SWFFloat32(Number('a'));
    Result.B := SWFFloat32(Number('b'));
    Result.C := SWFFloat32(Number('c'));
    Result.D := SWFFloat32(Number('d'));
    Result.TX := SWFTwipsFromPixels(Number('tx'));
    Result.TY := SWFTwipsFromPixels(Number('ty'));
  end;
end;

function TFlashPlayer.ReadDrawingGradient(const Args: TArray<TAVMValue>; out Style: TSWFFill): Boolean;
var
  Colors, Alphas, Ratios: TAVMObject;
  Count, AlphaCount, RatioCount, Index: Integer;
  Key, Mode: string;
  Ratio, Focal: Double;
  Color: Cardinal;
  RGB, Alpha: TAVMValue;

  function ListLength(O: TAVMObject): Integer;
  begin
    Result := AVMToInt32(VM.CoerceNumber(VM.Get(O, 'length')));
  end;

begin
  Result := False;
  Style := Default(TSWFFill);
  if (Length(Args) < 5) or (Length(Args) > 8) then
    Exit;
  Mode := VM.CoerceString(Args[0]);
  if Mode = 'linear' then
    Style.Gradient.Kind := sgLinear
  else if Mode = 'radial' then
    Style.Gradient.Kind := sgRadial
  else
    Exit;

  Colors := VM.Box(Args[1]);
  Alphas := VM.Box(Args[2]);
  Ratios := VM.Box(Args[3]);
  Count := ListLength(Colors);
  AlphaCount := ListLength(Alphas);
  RatioCount := ListLength(Ratios);
  if (Count < 0) or (Count <> AlphaCount) or (Count <> RatioCount) then
    Exit;
  // Validate and charge before allocating guest-sized storage.
  VM.ChargeWork(Count);
  SetLength(Style.Gradient.Stops, Count);
  for Index := 0 to Count - 1 do
  begin
    Key := IntToStr(Index);
    RGB := TAVMValue.Num(VM.CoerceNumber(VM.Get(Colors, Key)));
    Alpha := VM.Get(Alphas, Key);
    Color := ReadDrawingColor(RGB, Alpha);
    Ratio := VM.CoerceNumber(VM.Get(Ratios, Key));
    if (Ratio <= -1) or (Ratio >= 256) then
      Exit;
    if IsNan(Ratio) then
      Ratio := 0;
    Style.Gradient.Stops[Index].Ratio := Trunc(Ratio);
    Style.Gradient.Stops[Index].Color := Color;
  end;

  Style.Gradient.Matrix := ReadGradientMatrix(Args[4]);
  if Length(Args) > 5 then
  begin
    Mode := DrawingOption(Args[5]);
    if Mode = 'reflect' then
      Style.Gradient.Spread := gsReflect
    else if Mode = 'repeat' then
      Style.Gradient.Spread := gsRepeat;
  end;
  if Length(Args) > 6 then
    Style.Gradient.LinearRGB := DrawingOption(Args[6]) = 'linearRGB';
  if Length(Args) > 7 then
  begin
    try
      Focal := VM.CoerceNumber(Args[7]);
    except
      on E: EAVMThrown do
        Focal := 0;
    end;
    if not IsNan(Focal) and (Focal <> 0) and (Style.Gradient.Kind = sgRadial) then
    begin
      Style.Gradient.Kind := sgFocal;
      Style.Gradient.Focal := Trunc(EnsureRange(Focal, -128.0, 32767 / 256) * 256) / 256;
    end;
  end;
  Result := True;
end;

function TFlashPlayer.ReadDrawingLine(const Args: TArray<TAVMValue>): TSWFFill;
var
  Value: Double;
  Alpha: TAVMValue;
  Mode: string;
begin
  Result := Default(TSWFFill);
  Result.Stroke := True;
  Value := VM.CoerceNumber(Args[0]);
  if IsNan(Value) then
    Value := 0;
  Result.Line.Width := SWFTwipsFromPixels(EnsureRange(Value, 0.0, 255.0));
  Result.Color := $FF000000;
  if Length(Args) > 1 then
  begin
    Alpha := TAVMValue.Num(100);
    if Length(Args) > 2 then
      Alpha := Args[2];
    Result.Color := ReadDrawingColor(Args[1], Alpha);
  end;
  if Length(Args) > 4 then
  begin
    Mode := DrawingOption(Args[4]);
    Result.Line.NoHScale := (Mode = 'none') or (Mode = 'horizontal');
    Result.Line.NoVScale := (Mode = 'none') or (Mode = 'vertical');
  end;
  if Length(Args) > 5 then
  begin
    Mode := DrawingOption(Args[5]);
    if Mode = 'none' then
      Result.Line.StartCap := lcNone
    else if Mode = 'square' then
      Result.Line.StartCap := lcSquare;
    Result.Line.EndCap := Result.Line.StartCap;
  end;
  if Length(Args) > 6 then
  begin
    Mode := DrawingOption(Args[6]);
    if Mode = 'bevel' then
      Result.Line.Join := ljBevel
    else if Mode = 'miter' then
    begin
      Result.Line.Join := ljMiter;
      Value := 3;
      if Length(Args) > 7 then
        Value := VM.CoerceNumber(Args[7]);
      if IsNan(Value) then
        Value := 0;
      Result.Line.MiterLimit := Trunc(EnsureRange(Value, 0.0, 255.0) * 256) / 256;
    end;
  end;
end;

function TFlashPlayer.CallNative(const Name: string; ThisObj: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  C, Child, Original: TFlashClip;
  S, RequestedExport: string;
  AttachDepth, NewDepth, OldDepth: Integer;
  InitialObject, ListenerArray, Listener: TAVMObject;
  ListenerCount: Integer;
  EventName: string;
  DragBounds: TArray<Double>;
  DragIndex: Integer;
  GeometryMatrix, InverseMatrix: TSWFMatrix;
  GeometryBounds, OtherBounds: TSWFBounds;
  PointX, PointY: TAVMValue;
  CoordinateX, CoordinateY, OutputX, OutputY: Integer;
  PointKey, TargetPath: string;
  HitX, HitY, U, T: Double;
  DrawStyle: TSWFFill;
  Mode: TAVMBitmapBlend;
  FilterList: TSWFFilters;
  CurrentVideo: IImagePixelBuffer;
  VideoWork: Int64;
  Alpha: TAVMValue;
  Segment: Integer;
  PreviousX, PreviousY, CurveX, CurveY: Double;

  function Arg(I: Integer): TAVMValue;
  begin
    Result := Default(TAVMValue);
    if (I >= 0) and (I < Length(Args)) then
      Result := Args[I];
  end;

  function Num(I: Integer; DefaultValue: Double = 0): Double;
  begin
    if I >= Length(Args) then
      Exit(DefaultValue);
    Result := Args[I].AsNumber;
    if IsNan(Result) or IsInfinite(Result) or (Abs(Result) > 4294967295.0) then
      Result := DefaultValue;
  end;

  function LocalNumber(O: TAVMObject; const Key: string; out Value: TAVMValue): Boolean;
  begin
    Value := Default(TAVMValue);
    Result := VM.FindOwnKey(O, Key, PointKey);
    if not Result then
      Exit;
    if (O.Accessors <> nil) and O.Accessors.ContainsKey(PointKey) then
      Exit(False);
    Value := VM.GetOwnStored(O, PointKey);
    Result := Value.Kind = avNumber;
  end;

  function GeometryTarget(const Value: TAVMValue): TFlashClip;
  begin
    Result := Clip(Value.Obj);
    if Result <> nil then
      Exit;
    TargetPath := VM.CoerceString(Value);
    if TargetPath = '' then
      Exit(nil);
    Result := ResolveClip(C, TAVMValue.Str(TargetPath));
  end;

begin
  Result := Default(TAVMValue);
  if (Name = 'Sound') or Name.StartsWith('Sound.') then
    Exit(SoundCall(Name, ThisObj, Args));
  if (Name = 'NetConnection') or Name.StartsWith('NetConnection.') or
    (Name = 'NetStream') or Name.StartsWith('NetStream.') then
    Exit(FNet.Call(Name, SoundLibrary(nil).URI, ThisObj, Args));
  if Name = 'Video' then
    Exit;
  if Name.StartsWith('Video.') then
  begin
    C := Clip(ThisObj);
    if (C = nil) or C.Dead or (C.Character = nil) or (C.Character.Video = nil) then
      Exit;
    if Name = 'Video.attachVideo' then
    begin
      if FNet.IsStream(Arg(0).Obj) then
      begin
        C.NetStream := Arg(0).Obj;
        C.VideoState := Default(TSWFVideoState);
      end;
    end
    else
    begin
      VideoWork := 0;
      CurrentVideo := VideoBitmap(C, VideoWork);
      Result := TAVMValue.Num(0);
      if CurrentVideo <> nil then
      begin
        if Name = 'Video.width' then
          Result := TAVMValue.Num(CurrentVideo.Width)
        else if Name = 'Video.height' then
          Result := TAVMValue.Num(CurrentVideo.Height);
      end;
    end;
    Exit;
  end;
  if Name = 'Stage.width' then
    Exit(TAVMValue.Num((Int64(Movie.Stage.Right) - Movie.Stage.Left) div 20));
  if Name = 'Stage.height' then
    Exit(TAVMValue.Num((Int64(Movie.Stage.Bottom) - Movie.Stage.Top) div 20));
  if (Name = 'MovieClip.getFilters') or (Name = 'MovieClip.setFilters') then
  begin
    if ObjectType(ThisObj) <> 'movieclip' then
      Exit;
    C := Clip(ThisObj);
    if Name = 'MovieClip.getFilters' then
      Exit(WriteAVMFilters(VM, C.Filters));
    FilterList := ReadAVMFilters(VM, Arg(0));
    if not (C.Dead or C.Removing) then
      C.Filters := FilterList;
    Exit;
  end;
  if (Name = 'MovieClip.getBlendMode') or (Name = 'MovieClip.setBlendMode') then
  begin
    if ObjectType(ThisObj) <> 'movieclip' then
      Exit;
    C := Clip(ThisObj);
    if Name = 'MovieClip.getBlendMode' then
      Exit(TAVMValue.Str(AVMBlendName(C.BlendMode)));
    if TryAVMBlend(Arg(0), Mode) then
      C.BlendMode := Mode;
    Exit;
  end;
  if (Name = 'MovieClip.getScrollRect') or (Name = 'MovieClip.setScrollRect') then
  begin
    if ObjectType(ThisObj) = 'movieclip' then
      Exit(ScrollRectProperty(Clip(ThisObj), Name, Args));
    Exit;
  end;
  if Name = 'MovieClip.setMask' then
  begin
    if ObjectType(ThisObj) = 'movieclip' then
      Result := SetClipMask(Clip(ThisObj), Args);
    Exit;
  end;
  if (Name = 'MovieClip.attachBitmap') or (Name = 'MovieClip.beginBitmapFill') then
  begin
    if ObjectType(ThisObj) <> 'movieclip' then
      Exit;
    C := Clip(ThisObj);
    if C.Dead or C.Removing then
      Exit;
    if Name = 'MovieClip.attachBitmap' then
      AttachBitmap(C, Args)
    else
      BeginBitmapFill(C, Args);
    Exit;
  end;
  if ((Name = 'MovieClip.startDrag') or (Name = 'MovieClip.stopDrag')) and
    (ObjectType(ThisObj) <> 'movieclip') then
    Exit;
  if Name.StartsWith('TextField.') then
  begin
    C := Clip(ThisObj);
    if (C = nil) or not C.IsText then
      Exit;
    Exit(TextFieldCall(Copy(Name, 11, MaxInt), C, Args));
  end;
  if Name = 'offlineRequest' then
  begin
    Movie.Warn('Network loading is disabled; a failure event was dispatched');
    Exit;
  end;
  if Name = 'memorySharedObject' then
  begin
    Movie.Warn('SharedObject data is currently retained in memory only');
    Exit;
  end;
  if Name = 'MovieClip.getTransform' then
  begin
    if ObjectType(ThisObj) <> 'movieclip' then
      Exit;
    Exit(AVMNewGeometry(VM, 'Transform', [TAVMValue.Ref(ThisObj)]));
  end;
  if Name = 'MovieClip.setTransform' then
  begin
    C := Clip(ThisObj);
    InitialObject := Arg(0).Obj;
    if (C = nil) or (InitialObject = nil) or not InitialObject.IsTransform then
      Exit;
    Listener := ResolveTransformReference(InitialObject.TransformTarget, InitialObject.TransformPath);
    Original := Clip(Listener);
    if Original = nil then
      Exit;
    C.SetMatrix(Original.Matrix);
    C.ColorTransform := Original.ColorTransform;
    C.TransformedByScript := True;
    Exit;
  end;
  if Name = 'MovieClipLoader' then
  begin
    if ThisObj = nil then
      Exit;
    ListenerArray := VM.NewObject('Array');
    VM.PutData(ListenerArray, '0', TAVMValue.Ref(ThisObj));
    VM.SetArrayLength(ListenerArray, 1);
    VM.PutData(ThisObj, '_listeners', TAVMValue.Ref(ListenerArray));
    ThisObj.Attributes.AddOrSetValue('_listeners', 3);
    Exit;
  end;
  if Name.StartsWith('MovieClipLoader.') then
  begin
    S := Copy(Name, 17, MaxInt);
    if MatchStr(S, ['addListener', 'removeListener', 'broadcastMessage']) then
      Exit(AVMBroadcasterCall(VM, 'AsBroadcaster.' + S, ThisObj, Args));
    if Length(Args) = 0 then
      Exit;
    if S = 'loadClip' then
    begin
      if Length(Args) < 2 then
        Exit;
      if Arg(0).Kind <> avString then
        Exit(TAVMValue.Bool(False));
      C := ResolveLoaderTarget(Arg(1), True);
      if C = nil then
        Exit(TAVMValue.Bool(False));
      QueueLoad(C, ThisObj, Arg(0).Text);
      Exit(TAVMValue.Bool(True));
    end;
    C := ResolveLoaderTarget(Arg(0));
    if S = 'unloadClip' then
    begin
      if C = nil then
        Exit(TAVMValue.Bool(False));
      UnloadMovie(C);
      Exit(TAVMValue.Bool(True));
    end;
    if S = 'getProgress' then
    begin
      if (C = nil) and not (Arg(0).Kind in [avString, avNumber]) then
        Exit;
      Listener := VM.NewObject;
      Listener.Prototype := nil;
      Listener.RemoveData('__proto__');
      if C <> nil then
      begin
        ListenerCount := C.MovieLibrary.SourceBytes;
        if C.Unloaded then
          ListenerCount := 0;
        VM.Put(Listener, 'bytesLoaded', TAVMValue.Num(ListenerCount));
        VM.Put(Listener, 'bytesTotal', TAVMValue.Num(ListenerCount));
      end;
      Exit(TAVMValue.Ref(Listener));
    end;
  end;
  if Name = 'Selection.setFocus' then
  begin
    FTextFocus := Clip(Arg(0).Obj);
    if FTextFocus = nil then
      for var Candidate in FClips do
        if not Candidate.Dead and Candidate.IsEditable and (Candidate.Name = Arg(0).AsString) then
          FTextFocus := Candidate;
    Exit(TAVMValue.Bool(FTextFocus <> nil));
  end;
  if Name = 'Selection.setSelection' then
    Exit;
  if Name = 'duplicateMovieClip' then
  begin
    { CloneSprite's depth is already biased. Its coercion order differs from
      the MovieClip method, and it has no return value on the AVM stack. }
    NewDepth := AVMToInt32(VM.CoerceNumber(Arg(2)));
    S := VM.CoerceString(Arg(1));
    Original := ResolveClip(Clip(ThisObj), Arg(0));
    Child := DuplicateClip(Original, S, NewDepth, nil);
    if Child <> nil then
      Exit(TAVMValue.Ref(Child.Script));
    Exit;
  end;
  if Name = 'removeMovieClip' then
  begin
    C := ResolveClip(Clip(ThisObj), Arg(0));
    if (C <> nil) and (C.Depth >= 16384) and (C.Depth < 2130706416) then
      RemoveClip(C);
    Exit;
  end;
  if Name = 'Key.isDown' then
  begin
    var K := Trunc(Num(0));
    Exit(TAVMValue.Bool((K >= 0) and (K <= 255) and FKeys[K]));
  end;
  if Name = 'Key.getCode' then
    Exit(TAVMValue.Num(FLastKey));
  if Name = 'Key.addListener' then
    Exit(AVMBroadcasterCall(VM, 'AsBroadcaster.addListener', VM.Get(VM.Global, 'Key').Obj, Args));
  if Name = 'Key.removeListener' then
    Exit(AVMBroadcasterCall(VM, 'AsBroadcaster.removeListener', VM.Get(VM.Global, 'Key').Obj, Args));
  if Name = 'getURL' then
  begin
    S := VM.CoerceString(Arg(1));
    EventName := VM.CoerceString(Arg(0));
    NewDepth := 0;
    if Length(Args) > 2 then
      NewDepth := AVMToInt32(VM.CoerceNumber(Arg(2)));
    if ((NewDepth and $80) = 0) and URLLevel(S, Length(Args) > 2, OldDepth) then
    begin
      C := LevelClip(OldDepth, EventName <> '');
      if C <> nil then
      begin
        if EventName = '' then
          UnloadMovie(C)
        else
          QueueLoad(C, nil, EventName);
      end;
      Exit;
    end;
    if (NewDepth and $C0) = $40 then
    begin
      C := ResolveClip(Clip(ThisObj), Arg(1));
      if C <> nil then
      begin
        if EventName = '' then
          UnloadMovie(C)
        else
          QueueLoad(C, nil, EventName);
      end;
      Exit;
    end;
    Movie.Warn('External URL navigation is disabled');
    Exit;
  end;
  C := Clip(ThisObj);
  if C = nil then
    raise ESWFError.Create('Flash native requires a MovieClip: ' + Name);
  S := Name;
  if S.StartsWith('MovieClip.') then
    Delete(S, 1, 10);
  if S = 'stopDrag' then
  begin
    StopDrag;
    Exit;
  end;
  if S = 'startDrag' then
  begin
    if ObjectType(ThisObj) <> 'movieclip' then
      Exit;
    DragBounds := nil;
    if Length(Args) > 1 then
    begin
      SetLength(DragBounds, 4);
      for DragIndex := 0 to 3 do
        DragBounds[DragIndex] := VM.CoerceNumber(Arg(DragIndex + 1));
    end;
    StartDrag(ThisObj, Arg(0).AsBoolean(VM.SWFVersion), DragBounds);
    Exit;
  end;
  if C.Dead then
    Exit;
  if (S = 'getBytesLoaded') or (S = 'getBytesTotal') then
  begin
    if C.Unloaded then
      Exit(TAVMValue.Num(0));
    Exit(TAVMValue.Num(C.MovieLibrary.SourceBytes));
  end;
  if S = 'loadMovie' then
  begin
    if Length(Args) > 0 then
    begin
      S := VM.CoerceString(Arg(0));
      if S = '' then
        UnloadMovie(C)
      else
        QueueLoad(C, nil, S);
    end;
    Exit;
  end;
  if S = 'unloadMovie' then
  begin
    UnloadMovie(C);
    Exit;
  end;
  if S = 'attachMovie' then
  begin
    var Id: Integer;
    var Definition: TSWFCharacter;
    if Length(Args) < 3 then
      Exit;
    RequestedExport := VM.CoerceString(Arg(0));
    S := VM.CoerceString(Arg(1));
    AttachDepth := BiasedDepth(AVMToInt32(VM.CoerceNumber(Arg(2))));
    if (AttachDepth < 0) or (AttachDepth > 2130706428) then
      Exit;
    if not C.MovieLibrary.ExportNames.TryGetValue(AVMLowerName(RequestedExport), Id) or
      not C.MovieLibrary.Movie.Characters.TryGetValue(Id, Definition) then
      Exit;
    Child := AddClip(C, S, AttachDepth, Definition);
    InitializeAttachedClip(Child, Arg(3).Obj);
    Exit(TAVMValue.Ref(Child.Script));
  end;
  if S = 'duplicateMovieClip' then
  begin
    if Length(Args) = 0 then
      Exit;
    S := VM.CoerceString(Arg(0));
    NewDepth := 0;
    if Length(Args) > 1 then
      NewDepth := AVMToInt32(VM.CoerceNumber(Arg(1)));
    InitialObject := VM.Box(Arg(2));
    Child := DuplicateClip(C, S, BiasedDepth(NewDepth), InitialObject);
    if (Child <> nil) and (VM.SWFVersion >= 6) then
      Exit(TAVMValue.Ref(Child.Script));
    Exit;
  end;
  if S = 'createEmptyMovieClip' then
  begin
    if Length(Args) < 2 then
      Exit;
    S := VM.CoerceString(Arg(0));
    NewDepth := AVMToInt32(VM.CoerceNumber(Arg(1)));
    Child := AddClip(C, S, BiasedDepth(NewDepth), nil);
    InitializeAttachedClip(Child, nil);
    CallConstructHandler(Child);
    Exit(TAVMValue.Ref(Child.Script));
  end;
  if S = 'createTextField' then
  begin
    NewDepth := BiasedDepth(AVMLevelNumber(VM.CoerceNumber(Arg(1))));
    CoordinateX := AVMToInt32(VM.CoerceNumber(Arg(2)));
    CoordinateY := AVMToInt32(VM.CoerceNumber(Arg(3)));
    OutputX := AVMToInt32(VM.CoerceNumber(Arg(4)));
    OutputY := AVMToInt32(VM.CoerceNumber(Arg(5)));
    S := VM.CoerceString(Arg(0));
    Child := AddClip(C, S, NewDepth, nil);
    InitializeTextField(Child);
    Child.SetPosition(CoordinateX, CoordinateY);
    Child.TextWidth := OutputX;
    Child.TextHeight := OutputY;
    if VM.SWFVersion >= 8 then
      Exit(TAVMValue.Ref(Child.Script));
    Exit;
  end;
  if S = 'clear' then
  begin
    C.ResetDrawing;
    C.DrawingTouched := True;
    Exit;
  end;
  if (S = 'beginFill') or (S = 'endFill') then
  begin
    DrawStyle := Default(TSWFFill);
    if (S = 'endFill') or (Length(Args) = 0) then
      SetDrawingFill(C, DrawStyle, False)
    else
    begin
      Alpha := TAVMValue.Num(100);
      if Length(Args) > 1 then
        Alpha := Args[1];
      DrawStyle.Color := ReadDrawingColor(Args[0], Alpha);
      SetDrawingFill(C, DrawStyle, True);
    end;
    Exit;
  end;
  if S = 'beginGradientFill' then
  begin
    if Arg(0).Kind = avUndefined then
      SetDrawingFill(C, Default(TSWFFill), False)
    else if ((Length(Args) = 5) or (VM.SWFVersion >= 8)) and ReadDrawingGradient(Args, DrawStyle) then
      SetDrawingFill(C, DrawStyle, True);
    Exit;
  end;
  if (S = 'moveTo') or (S = 'lineTo') then
  begin
    if Length(Args) < 2 then
      Exit;
    CoordinateX := SWFTwipsFromPixels(VM.CoerceNumber(Args[0]));
    CoordinateY := SWFTwipsFromPixels(VM.CoerceNumber(Args[1]));
    if C.Dead or C.Removing then
      Exit;
    C.DrawingTouched := True;
    if S = 'moveTo' then
    begin
      CloseDrawingContour(C);
      C.StartX := CoordinateX;
      C.StartY := CoordinateY;
    end
    else
      AddDrawingEdge(C, C.PenX, C.PenY, CoordinateX, CoordinateY);
    C.PenX := CoordinateX;
    C.PenY := CoordinateY;
    Exit;
  end;
  if S = 'curveTo' then
  begin
    if Length(Args) < 4 then
      Exit;
    CoordinateX := SWFTwipsFromPixels(VM.CoerceNumber(Args[0]));
    CoordinateY := SWFTwipsFromPixels(VM.CoerceNumber(Args[1]));
    OutputX := SWFTwipsFromPixels(VM.CoerceNumber(Args[2]));
    OutputY := SWFTwipsFromPixels(VM.CoerceNumber(Args[3]));
    if C.Dead or C.Removing then
      Exit;
    C.DrawingTouched := True;
    AddDrawingBounds(C, TSWFBounds.Quadratic(C.PenX, C.PenY, CoordinateX, CoordinateY, OutputX, OutputY));
    PreviousX := C.PenX;
    PreviousY := C.PenY;
    for Segment := 1 to 12 do
    begin
      T := Segment / 12;
      U := 1 - T;
      CurveX := U * U * C.PenX + 2 * U * T * CoordinateX + T * T * OutputX;
      CurveY := U * U * C.PenY + 2 * U * T * CoordinateY + T * T * OutputY;
      AddDrawingEdge(C, PreviousX, PreviousY, CurveX, CurveY);
      PreviousX := CurveX;
      PreviousY := CurveY;
    end;
    C.PenX := OutputX;
    C.PenY := OutputY;
    Exit;
  end;
  if S = 'lineStyle' then
  begin
    if Length(Args) = 0 then
      SetDrawingLine(C, Default(TSWFFill), False)
    else
      SetDrawingLine(C, ReadDrawingLine(Args), True);
    Exit;
  end;
  if S = 'lineGradientStyle' then
  begin
    if ReadDrawingGradient(Args, DrawStyle) and not C.Dead and (C.StrokeFill <> 0) then
    begin
      DrawStyle.Stroke := True;
      DrawStyle.Line := C.Drawing.Fills[C.StrokeFill - 1].Line;
      SetDrawingLine(C, DrawStyle, True);
    end;
    Exit;
  end;
  if (S = 'removeMovieClip') or (S = 'removeTextField') then
  begin
    if (C.Depth >= 16384) and (C.Depth < 2130706416) then
      RemoveClip(C);
    Exit;
  end;
  if S = 'getDepth' then
    Exit(TAVMValue.Num(AVMToInt32(Double(C.Depth) - 16384)));
  if S = 'getNextHighestDepth' then
  begin
    NewDepth := 0;
    if C.Children.Count > 0 then
      NewDepth := C.Children[0].Depth;
    for Child in C.Children do
      NewDepth := Max(NewDepth, Child.Depth);
    Exit(TAVMValue.Num(Max(0, AVMToInt32(Double(NewDepth) - 16383))));
  end;
  if S = 'swapDepths' then
  begin
    if C.Parent = nil then
      Exit;
    OldDepth := C.Depth;
    if Arg(0).Kind = avNumber then
      NewDepth := BiasedDepth(AVMToInt32(Arg(0).Number))
    else
    begin
      Child := ResolveClip(C, Arg(0));
      if (Child = nil) or (Child.Parent <> C.Parent) then
        Exit;
      NewDepth := Child.Depth;
    end;
    if (NewDepth < 0) or (NewDepth > 2130706428) then
      Exit;
    if C.Parent <> nil then
      for Child in C.Parent.Children do
        if (Child <> C) and (Child.Depth = NewDepth) then
        begin
          Child.Depth := OldDepth;
          Break;
        end;
    C.Depth := NewDepth;
    Exit;
  end;
  if (S = 'setTextFormat') or (S = 'getTextFormat') then
  begin
    if not C.IsText then
      Exit;
    Exit(TextFieldCall(S, C, Args));
  end;
  if S = 'getSWFVersion' then
    Exit(TAVMValue.Num(C.MovieLibrary.Movie.Version));
  if (S = 'localToGlobal') or (S = 'globalToLocal') then
  begin
    InitialObject := Arg(0).Obj;
    if not LocalNumber(InitialObject, 'x', PointX) or not LocalNumber(InitialObject, 'y', PointY) then
      Exit;
    CoordinateX := SWFTwipsFromPixels(PointX.Number);
    CoordinateY := SWFTwipsFromPixels(PointY.Number);
    GeometryMatrix := WorldMatrix(C);
    if (S = 'globalToLocal') then
    begin
      if SWFInverseMatrix(GeometryMatrix, InverseMatrix) then
        GeometryMatrix := InverseMatrix
      else
        GeometryMatrix := TSWFMatrix.Identity;
    end;
    SWFTransformPoint(GeometryMatrix, CoordinateX, CoordinateY, OutputX, OutputY);
    VM.Put(InitialObject, 'x', TAVMValue.Num(OutputX / 20));
    VM.Put(InitialObject, 'y', TAVMValue.Num(OutputY / 20));
    Exit;
  end;
  if (S = 'getBounds') or (S = 'getRect') then
  begin
    if Length(Args) = 0 then
      Original := C
    else
      Original := GeometryTarget(Arg(0));
    if Original = nil then
      Exit;
    if (VM.SWFVersion >= 8) or (FRoot.MovieLibrary.Movie.Version >= 8) then
      FUseNewInvalidBounds := True;
    GeometryBounds := BoundsWithMatrix(C, TSWFMatrix.Identity, S = 'getRect');
    if Original <> C then
    begin
      GeometryMatrix := WorldMatrix(C);
      if not SWFInverseMatrix(WorldMatrix(Original), InverseMatrix) then
        InverseMatrix := TSWFMatrix.Identity;
      GeometryMatrix := GeometryMatrix.ThenBy(InverseMatrix);
      GeometryBounds := GeometryBounds.Transformed(GeometryMatrix);
      if not GeometryBounds.Valid and FUseNewInvalidBounds then
      begin
        GeometryBounds.Rect.Left := $8000000;
        GeometryBounds.Rect.Right := $8000000;
        GeometryBounds.Rect.Top := $8000000;
        GeometryBounds.Rect.Bottom := $8000000;
      end;
    end;
    InitialObject := VM.NewObject;
    VM.Put(InitialObject, 'xMin', TAVMValue.Num(GeometryBounds.Rect.Left / 20));
    VM.Put(InitialObject, 'xMax', TAVMValue.Num(GeometryBounds.Rect.Right / 20));
    VM.Put(InitialObject, 'yMin', TAVMValue.Num(GeometryBounds.Rect.Top / 20));
    VM.Put(InitialObject, 'yMax', TAVMValue.Num(GeometryBounds.Rect.Bottom / 20));
    Exit(TAVMValue.Ref(InitialObject));
  end;
  if MatchText(S, ['play', 'stop', 'gotoAndPlay', 'gotoAndStop', 'nextFrame', 'prevFrame']) then
  begin
    Timeline(ThisObj, S, Arg(0));
    if (C.PendingFrame >= 0) and (C.Frame >= 0) and
      MatchStr(S, ['gotoAndPlay', 'gotoAndStop']) and (VM.CurrentTarget <> nil) then
    begin
      // Expose the destination display list immediately, even on the current
      // clip. Queue frame actions so the calling script can finish first.
      C.SynchronousSeekTick := FFrameNumber + 1;
      Inc(FDeferFrameActions);
      try
        ApplyPendingSeeks(C);
      finally
        Dec(FDeferFrameActions);
      end;
    end;
    Exit;
  end;
  if S = 'hitTest' then
  begin
    Result := TAVMValue.Bool(False);
    if Length(Args) > 1 then
    begin
      HitX := VM.CoerceNumber(Arg(0));
      HitY := VM.CoerceNumber(Arg(1));
      if IsNan(HitX) or IsInfinite(HitX) or IsNan(HitY) or IsInfinite(HitY) then
        Exit;
      CoordinateX := SWFTwipsFromPixels(HitX);
      CoordinateY := SWFTwipsFromPixels(HitY);
      SWFTransformPoint(WorldMatrix(ClipRoot(C)), CoordinateX, CoordinateY, OutputX, OutputY);
      if (Length(Args) > 2) and Arg(2).AsBoolean(VM.SWFVersion) then
      begin
        GeometryMatrix := TSWFMatrix.Identity;
        if C.Parent <> nil then
          GeometryMatrix := WorldMatrix(C.Parent);
        Exit(TAVMValue.Bool(ContainsPoint(C, OutputX / 20, OutputY / 20, GeometryMatrix, False, True)));
      end;
      GeometryBounds := BoundsWithMatrix(C, WorldMatrix(C, False), False);
      Exit(TAVMValue.Bool(GeometryBounds.Valid and (OutputX >= GeometryBounds.Rect.Left) and (OutputX <= GeometryBounds.Rect.Right) and
          (OutputY >= GeometryBounds.Rect.Top) and (OutputY <= GeometryBounds.Rect.Bottom)));
    end;
    if Length(Args) = 1 then
    begin
      Original := GeometryTarget(Arg(0));
      if Original = nil then
        Exit;
      GeometryBounds := BoundsWithMatrix(C, WorldMatrix(C, False), False);
      OtherBounds := BoundsWithMatrix(Original, WorldMatrix(Original, False), False);
      Result := TAVMValue.Bool(GeometryBounds.Valid and OtherBounds.Valid and
        (GeometryBounds.Rect.Left <= OtherBounds.Rect.Right) and (GeometryBounds.Rect.Right >= OtherBounds.Rect.Left) and
        (GeometryBounds.Rect.Top <= OtherBounds.Rect.Bottom) and (GeometryBounds.Rect.Bottom >= OtherBounds.Rect.Top));
    end;
    Exit;
  end;
  raise ESWFError.Create('Flash native is not implemented: ' + Name);
end;

function TFlashPlayer.ResolveTimelineTarget(Start: TAVMObject; const Path: string): TAVMObject;
var
  C: TFlashClip;
begin
  C := ResolveClip(Clip(Start), TAVMValue.Str(Path));
  Result := nil;
  if (C <> nil) and not C.Dead and not C.Removing then
    Result := C.Script;
end;

procedure TFlashPlayer.Timeline(Target: TAVMObject; const Command: string; const Value: TAVMValue);
var
  C: TFlashClip;
  Count, Index: Integer;
  Frames: TArray<TSWFFrame>;
begin
  C := Clip(Target);
  if C = nil then
    Exit;
  if Command = 'play' then
  begin
    C.Playing := True;
    Exit;
  end;
  if Command = 'stop' then
  begin
    C.Playing := False;
    FAudio.StopStream(C);
    Exit;
  end;
  Frames := ClipFrames(C);
  Count := Length(Frames);
  if Count = 0 then
    Exit;
  Index := 0;
  if Value.Kind = avString then
  begin
    for var I := 0 to High(Frames) do
      for var Tag in Frames[I].Tags do
        if Tag.Code = 43 then
        begin
          var R := TSWFReader.Create(Tag.Data, C.MovieLibrary.Movie.Version);
          try
            if R.Str = Value.Text then
              Index := I;
          finally
            R.Free;
          end;
        end;
  end
  else if not IsNan(Value.AsNumber) and not IsInfinite(Value.AsNumber) then
    Index := Trunc(Value.AsNumber) - 1;
  if Command = 'nextFrame' then
    Index := C.Frame + 1
  else if Command = 'prevFrame' then
    Index := C.Frame - 1;
  C.PendingFrame := EnsureRange(Index, 0, Count - 1);
  C.Playing := Command = 'gotoAndPlay';
  if not C.Playing then
    FAudio.StopStream(C);
end;

procedure TFlashPlayer.CallFrame(Target: TAVMObject; const Value: TAVMValue; Stack: TList<TAVMValue>; const Pool: TArray<string>);
var
  C: TFlashClip;
  Frames: TArray<TSWFFrame>;
  FrameTag: TSWFTag;
  R: TSWFReader;
  FrameName, LabelName: string;
  FrameNumber: Double;
  Separator, Index, I: Integer;
begin
  C := Clip(Target);
  if C = nil then
    C := Clip(VM.Root);
  if C = nil then
    C := FRoot;
  FrameName := '';
  if Value.Kind = avNumber then
    FrameNumber := Value.Number
  else
  begin
    FrameName := VM.CoerceString(Value);
    Separator := LastDelimiter(':.', FrameName);
    if Separator > 0 then
    begin
      C := ResolveClip(C, TAVMValue.Str(Copy(FrameName, 1, Separator - 1)));
      Delete(FrameName, 1, Separator);
    end;
    if FrameName = '' then
      Exit;
  end;
  if (C = nil) or C.Dead or C.Removing then
    Exit;
  Frames := ClipFrames(C);
  if (Value.Kind = avNumber) or TryStrToFloat(FrameName, FrameNumber, TFormatSettings.Invariant) then
    Index := AVMToInt32(FrameNumber)
  else
  begin
    Index := 0;
    FrameName := AVMLowerName(FrameName);
    for I := 0 to High(Frames) do
    begin
      for FrameTag in Frames[I].Tags do
        if FrameTag.Code = 43 then
        begin
          R := TSWFReader.Create(FrameTag.Data, C.MovieLibrary.Movie.Version);
          try
            LabelName := AVMLowerName(R.Str);
          finally
            R.Free;
          end;
          if LabelName = FrameName then
          begin
            Index := I + 1;
            Break;
          end;
        end;
      if Index > 0 then
        Break;
    end;
  end;
  if (Index < 1) or (Index > Length(Frames)) then
    Exit;
  // Frame calls run DoAction blocks with the caller's operand stack. They do
  // not perform the called frame's placements, sounds or playhead changes.
  for FrameTag in Frames[Index - 1].Tags do
    if FrameTag.Code = 12 then
      RunCode(C, FrameTag.Data, Stack, Pool);
end;

procedure ReadPlacementHeader(R: TSWFReader; TagCode: Integer; out Flags, Depth, Id: Integer);
begin
  Id := 0;
  case TagCode of
    4:
      begin
        Flags := 6;
        Id := R.U16;
      end;
    26:
      Flags := R.U8;
    70:
      Flags := R.U16;
  else
    Flags := 0;
  end;
  Depth := R.U16;
  if (Flags and $800 <> 0) or ((Flags and $1000 <> 0) and (Flags and 2 = 0)) then
    R.Str;
  if (TagCode <> 4) and (Flags and 2 <> 0) then
    Id := R.U16;
end;

procedure ReadInitialPlacementState(R: TSWFReader; Flags: Integer; out ClipEnd: Integer; out Ratio: Word; out Mode: TAVMBitmapBlend; out Filters: TSWFFilters);
begin
  ClipEnd := 0;
  Ratio := 0;
  Mode := bbNormal;
  Filters := nil;
  if Flags and ($10 or $40 or $100 or $200) = 0 then
    Exit;
  if Flags and 4 <> 0 then
    R.Matrix;
  if Flags and 8 <> 0 then
    R.ColorTransform(True);
  if Flags and 16 <> 0 then
    Ratio := R.U16;
  if Flags and 32 <> 0 then
    R.Str;
  if Flags and 64 <> 0 then
    ClipEnd := R.U16;
  if Flags and $100 <> 0 then
    Filters := R.FilterList;
  if Flags and $200 <> 0 then
    TryAVMBlendCode(R.U8, Mode);
end;

function CanReplaceTimelineGraphic(Current, Replacement: TSWFCharacter): Boolean;
begin
  Result := (Current <> nil) and (Replacement <> nil) and
    (((Current.Kind in [2, 22, 32, 83]) and (Replacement.Kind in [2, 22, 32, 83])) or
    ((Current.Kind in [46, 84]) and (Replacement.Kind in [46, 84])) or
    ((Current.Kind in [11, 33]) and (Replacement.Kind in [11, 33])));
end;

procedure TFlashPlayer.ApplyFrame(C: TFlashClip; Index: Integer; ExecuteActions: Boolean; Origins: TDictionary<Integer, Integer>; TargetFrame: Integer; ClipEnds: TDictionary<Integer, Integer>; SeekRatios: TDictionary<Integer, Word>; SeekBlends: TDictionary<Integer, TAVMBitmapBlend>; SeekFilters: TDictionary<Integer, TSWFFilters>);
var
  Frames: TArray<TSWFFrame>;
  R: TSWFReader;
  Child: TFlashClip;
  Flags, Depth, Id: Integer;
  Character: TSWFCharacter;
  FrameActions: TArray<TBytes>;
  Action: TFlashQueuedAction;
  ClipAction: TSWFClipAction;
  ConstructAction: TFlashQueuedConstruct;
  FrameMatrix: TSWFMatrix;
  FrameColor: TSWFColorTransform;
  NewPlacement, ReplaceCharacter, Visible: Boolean;
  ClipEnd, PreviousClipEnd: Integer;
  Ratio: Word;
  Mode, PreviousBlend: TAVMBitmapBlend;
  FilterList, PreviousFilters: TSWFFilters;
begin
  Frames := ClipFrames(C);
  if (Index < 0) or (Index >= Length(Frames)) then
    Exit;
  C.Frame := Index;
  RegisterFrameExports(C.MovieLibrary, Frames[Index]);
  for var Tag in Frames[Index].Tags do
  begin
    if Tag.Code = 19 then
    begin
      if ExecuteActions and C.Playing and (Frames[Index].StreamSound <> nil) then
        FAudio.StartStream(Frames[Index].StreamSound, C, Frames[Index].StreamOffset, Frames[Index].StreamEnd);
      Continue;
    end;
    if Tag.Code in [18, 45] then
      Continue;
    R := TSWFReader.Create(Tag.Data, C.MovieLibrary.Movie.Version);
    try
      case Tag.Code of
        4, 26, 70:
          begin
            ReadPlacementHeader(R, Tag.Code, Flags, Depth, Id);
            Child := nil;
            for var Item in C.Children do
              if Item.Depth = Depth then
              begin
                Child := Item;
                Break;
              end;
            if Origins <> nil then
            begin
              var Origin: Integer;
              if not Origins.TryGetValue(Depth, Origin) then
                Continue;
              if (Flags and 2) <> 0 then
              begin
                if Origin <> Index then
                begin
                // Replay graphic replacements from the original
                // placement so omitted attributes keep their earlier values.
                  if (Index < Origin) or (Flags and 1 = 0) or (Child = nil) or
                    (Child.SeekGeneration <> FSeekGeneration) or
                    not C.MovieLibrary.Movie.Characters.TryGetValue(Id, Character) or
                    not CanReplaceTimelineGraphic(Child.Character, Character) then
                    Continue;
                end
                else if (Child <> nil) and (Child.TimelineOrigin = Origin) then
                  Continue;
              end
              else
              begin
                if (Child = nil) and (Index < Origin) then
                  Continue;
                if (Child <> nil) and (Child.SeekGeneration <> FSeekGeneration) and (Index <> TargetFrame) then
                  Continue;
              end;
            end;

            NewPlacement := False;
            ReplaceCharacter := False;
            PreviousClipEnd := 0;
            PreviousBlend := bbNormal;
            PreviousFilters := nil;
            if (Flags and 2) <> 0 then
            begin
              if not C.MovieLibrary.Movie.Characters.TryGetValue(Id, Character) then
                raise ESWFError.Create('Missing SWF character');
              if (Child <> nil) and (Flags and 1 <> 0) and CanReplaceTimelineGraphic(Child.Character, Character) then
              begin
                // PlaceObject replacement preserves attributes absent from the tag.
                Child.Character := Character;
              end
              else if (Child = nil) or ((Flags and 1) = 0) or (Child.Character <> Character) then
              begin
                NewPlacement := True;
                ReplaceCharacter := (Child <> nil) and ((Flags and 1) <> 0);
                if ReplaceCharacter then
                begin
                  PreviousClipEnd := Child.ClipDepth;
                  PreviousBlend := Child.BlendMode;
                  PreviousFilters := Child.Filters;
                end;
                Child := AddClip(C, '', Depth, Character);
                Child.TimelineOrigin := Index;
                Child.BlendMode := PreviousBlend;
                Child.Filters := PreviousFilters;
                if Origins <> nil then
                  Child.SeekGeneration := FSeekGeneration;
              end;
            end;
            if Child = nil then
              raise ESWFError.Create('SWF move targets an absent character');
            if (Flags and 4) <> 0 then
            begin
              FrameMatrix := R.Matrix;
              if not Child.TransformedByScript then
                Child.SetMatrix(FrameMatrix);
            end;
            if ((Flags and 8) <> 0) or ((Tag.Code = 4) and (R.Remaining > 0)) then
            begin
              FrameColor := R.ColorTransform(Tag.Code <> 4);
              if not Child.TransformedByScript then
                Child.ColorTransform := FrameColor;
            end;
            if (Flags and 16) <> 0 then
              Child.MorphRatio := R.U16;
            if SeekRatios <> nil then
            begin
              if not SeekRatios.TryGetValue(Depth, Ratio) then
                Ratio := 0;
              Child.MorphRatio := Ratio;
            end;
            if (Flags and 32) <> 0 then
            begin
              Child.Name := R.Str;
              VM.Put(C.Script, Child.Name, TAVMValue.Ref(Child.Script));
            end;
            ClipEnd := 0;
            if (Flags and 64) <> 0 then
              ClipEnd := R.U16;
            if NewPlacement then
            begin
              if (ClipEnds <> nil) and ClipEnds.TryGetValue(Depth, PreviousClipEnd) then
                ClipEnd := PreviousClipEnd
              else if ReplaceCharacter then
                ClipEnd := PreviousClipEnd;
              Child.ClipDepth := ClipEnd;
            end;
            if (Flags and $100) <> 0 then
            begin
              FilterList := R.FilterList;
              if not Child.TransformedByScript then
                Child.Filters := FilterList;
            end;
            if (Flags and $200) <> 0 then
            begin
              TryAVMBlendCode(R.U8, Mode);
              if not Child.TransformedByScript then
                Child.BlendMode := Mode;
            end;
            if (SeekBlends <> nil) and not Child.TransformedByScript then
            begin
              if not SeekBlends.TryGetValue(Depth, Mode) then
                Mode := bbNormal;
              Child.BlendMode := Mode;
            end;
            if (SeekFilters <> nil) and not Child.TransformedByScript then
            begin
              if not SeekFilters.TryGetValue(Depth, FilterList) then
                FilterList := nil;
              Child.Filters := FilterList;
            end;
            if (Flags and $400) <> 0 then
            begin
              if R.Remaining > 0 then
                R.U8;
              Movie.Warn('Placement bitmap caching is not implemented');
            end;
            if (Flags and $2000) <> 0 then
            begin
              Visible := R.U8 <> 0;
              if C.MovieLibrary.Movie.Version >= 11 then
                Child.Visible := Visible;
            end;
            if (Flags and $4000) <> 0 then
            begin
              R.U32;
              Movie.Warn('Placement opaque background is not implemented');
            end;
            if (Flags and 128) <> 0 then
            begin
              R.U16;
              if C.MovieLibrary.Movie.Version >= 6 then
                R.U32
              else
                R.U16;
              while R.Remaining > 0 do
              begin
                var EventFlags: Cardinal;
                if C.MovieLibrary.Movie.Version >= 6 then
                  EventFlags := R.U32
                else
                  EventFlags := R.U16;
                if EventFlags = 0 then
                  Break;
                var Size := R.U32;
                if Size > Cardinal(R.Remaining) then
                  raise ESWFError.Create('Truncated SWF clip action');
                var Actions := R.Bytes(Integer(Size));
                ClipAction := Default(TSWFClipAction);
                ClipAction.Events := EventFlags;
                if (EventFlags and SWFClipKeyPress) <> 0 then
                begin
                  if Length(Actions) = 0 then
                    raise ESWFError.Create('Missing SWF clip-action key code');
                  ClipAction.KeyCode := Actions[0];
                  Actions := Copy(Actions, 1, Length(Actions) - 1);
                end;
                ClipAction.Code := Actions;
                Child.ClipActions.Add(ClipAction);
              end;
            end;
            if not Child.Started then
            begin
              Child.Started := True;
              if FConstructClips.Count >= 65536 then
                raise ESWFError.Create('Flash pending constructor limit');
              ConstructAction := Default(TFlashQueuedConstruct);
              ConstructAction.Clip := Child;
              ConstructAction.Generation := Child.ContentGeneration;
              FConstructClips.Add(ConstructAction);
              Action := Default(TFlashQueuedAction);
              Action.Clip := Child;
              Action.Generation := Child.ContentGeneration;
              Action.EventName := 'onLoad';
              Action.EventFlags := SWFClipLoad;
              FActions.Add(Action);
              Inc(FDeferFrameActions);
              try
                StepClip(Child, False);
              finally
                Dec(FDeferFrameActions);
              end;
            end;
          end;
        5, 28:
          begin
            if Origins <> nil then
              Continue;
            if Tag.Code = 5 then
              R.U16;
            Depth := R.U16;
            for Child in C.Children.ToArray do
              if Child.Depth = Depth then
                RemoveClip(Child);
          end;
        72, 82:
          if ExecuteActions then
          begin
            if C.MovieLibrary.AVM2 = nil then
            begin
              C.MovieLibrary.AVM2 := TAVM2Runtime.Create(
                procedure(Text: string)
                begin
                  if VM.Trace.Count < VM.TraceLimit then
                    VM.Trace.Add(Text);
                end, TFlashAVM2Display.Create(Self, C), C.MovieLibrary.Movie.Version);
              C.MovieLibrary.AVM2.OnCollection := FOnAVM2Collection;
              C.MovieLibrary.AVM2.OnReclaim := FOnAVM2Reclaim;
              C.MovieLibrary.AVM2.SetStageSize(C.MovieLibrary.Movie.Width, C.MovieLibrary.Movie.Height);
              C.MovieLibrary.AVM2.ReadResource := TAVM2ResourceReader(FReadResource);
              C.MovieLibrary.AVM2.ReadSharedObject := FReadSharedObject;
              C.MovieLibrary.AVM2.WriteSharedObject := FWriteSharedObject;
              C.MovieLibrary.AVM2.SetMovieInfo(C.MovieLibrary.URI, C.MovieLibrary.SourceBytes,
                C.MovieLibrary.Movie.Width, C.MovieLibrary.Movie.Height, C.MovieLibrary.Movie.FPS);
              C.MovieLibrary.AVM2.BeginFrame(VM.Milliseconds);
            end;
            Flags := 0;
            if Tag.Code = 82 then
            begin
              Flags := R.U32 and 1;
              R.Str;
            end;
            try
              C.MovieLibrary.AVM2.LoadABC(Tag.Ordinal, R.Bytes(R.Remaining), Flags <> 0);
            except
              on E: EAVM2Error do
                raise ESWFError.Create('AVM2 DoABC: ' + E.Message);
            end;
          end;
        12:
          if ExecuteActions and not C.MovieLibrary.Movie.UsesAVM2 then
            FrameActions := FrameActions + [Tag.Data];
        15:
          if ExecuteActions then
            PlaySoundEvent(C, ReadSWFSoundEvent(R));
        59:
          if ExecuteActions then
          begin
            R.U16;
            FrameActions := FrameActions + [R.Bytes(R.Remaining)];
          end;
      end;
    finally
      R.Free;
    end;
  end;
  if ExecuteActions and (C.MovieLibrary.AVM2 <> nil) then
  begin
    C.AVM2ConstructionPending := True;
    C.FrameScriptPending := True;
    if not FCollectingAVM2Timeline then
      ConstructAVM2Clip(C);
  end;
  if FDeferFrameActions = 0 then
    ProcessUnloads(True, False);
  for var Code in FrameActions do
  begin
    if FDeferFrameActions = 0 then
      RunCode(C, Code)
    else
    begin
      if FActions.Count >= 65536 then
        raise ESWFError.Create('Flash pending action limit');
      Action := Default(TFlashQueuedAction);
      Action.Clip := C;
      Action.Generation := C.ContentGeneration;
      Action.Code := Code;
      FActions.Add(Action);
    end;
  end;
end;

procedure TFlashPlayer.SeekBack(C: TFlashClip; Index: Integer);
var
  Frames: TArray<TSWFFrame>;
  Current, Replacement: TSWFCharacter;
  Origins, Ids, ClipEnds: TDictionary<Integer, Integer>;
  Ratios: TDictionary<Integer, Word>;
  Blends: TDictionary<Integer, TAVMBitmapBlend>;
  Filters: TDictionary<Integer, TSWFFilters>;
  Flags, Id, Depth, ClipEnd, Previous, TimelineDepthLimit: Integer;
  Ratio: Word;
  Mode: TAVMBitmapBlend;
  FilterList: TSWFFilters;
begin
  Frames := ClipFrames(C);
  TimelineDepthLimit := 16384;
  if C.MovieLibrary.Movie.UsesAVM2 then
    TimelineDepthLimit := AVM2ScriptDepth;
  Origins := TDictionary<Integer, Integer>.Create;
  Ids := TDictionary<Integer, Integer>.Create;
  ClipEnds := TDictionary<Integer, Integer>.Create;
  Ratios := TDictionary<Integer, Word>.Create;
  Blends := TDictionary<Integer, TAVMBitmapBlend>.Create;
  Filters := TDictionary<Integer, TSWFFilters>.Create;
  try
    for var I := 0 to Index do
      for var Tag in Frames[I].Tags do
      begin
        var R := TSWFReader.Create(Tag.Data, C.MovieLibrary.Movie.Version);
        try
          if Tag.Code in [4, 26, 70] then
          begin
            ReadPlacementHeader(R, Tag.Code, Flags, Depth, Id);
            ReadInitialPlacementState(R, Flags, ClipEnd, Ratio, Mode, FilterList);
            if (Flags and 2) <> 0 then
            begin
              if ((Flags and 1) = 0) or not Ids.TryGetValue(Depth, Previous) then
              begin
                Origins.AddOrSetValue(Depth, I);
                ClipEnds.AddOrSetValue(Depth, ClipEnd);
                Ratios.Remove(Depth);
                Blends.Remove(Depth);
                Filters.Remove(Depth);
              end
              else if (Previous <> Id) and
                not (C.MovieLibrary.Movie.Characters.TryGetValue(Previous, Current) and
                C.MovieLibrary.Movie.Characters.TryGetValue(Id, Replacement) and
                CanReplaceTimelineGraphic(Current, Replacement)) then
                Origins.AddOrSetValue(Depth, I);
              Ids.AddOrSetValue(Depth, Id);
            end;
            if Flags and 16 <> 0 then
              Ratios.AddOrSetValue(Depth, Ratio);
            if Flags and $200 <> 0 then
              Blends.AddOrSetValue(Depth, Mode);
            if Flags and $100 <> 0 then
              Filters.AddOrSetValue(Depth, FilterList);
          end
          else if Tag.Code in [5, 28] then
          begin
            if Tag.Code = 5 then
              R.U16;
            Depth := R.U16;
            Origins.Remove(Depth);
            Ids.Remove(Depth);
            ClipEnds.Remove(Depth);
            Ratios.Remove(Depth);
            Blends.Remove(Depth);
            Filters.Remove(Depth);
          end;
        finally
          R.Free;
        end;
      end;
    for var Child in C.Children.ToArray do
      if Child.Depth < TimelineDepthLimit then
      begin
        var Origin: Integer;
        if not Origins.TryGetValue(Child.Depth, Origin) or (Child.TimelineOrigin <> Origin) or
          not Ids.TryGetValue(Child.Depth, Id) or (Child.Character = nil) or (Child.Character.Id <> Id) then
          RemoveClip(Child)
        else
        begin
          if not Ratios.TryGetValue(Child.Depth, Ratio) then
            Ratio := 0;
          Child.MorphRatio := Ratio;
          if not Child.TransformedByScript then
          begin
            if not Blends.TryGetValue(Child.Depth, Mode) then
              Mode := bbNormal;
            Child.BlendMode := Mode;
            if not Filters.TryGetValue(Child.Depth, FilterList) then
              FilterList := nil;
            Child.Filters := FilterList;
          end;
        end;
      end;
    Inc(FSeekGeneration);
    for var I := 0 to Index do
      ApplyFrame(C, I, I = Index, Origins, Index, ClipEnds, Ratios, Blends, Filters);
  finally
    Filters.Free;
    Blends.Free;
    Ratios.Free;
    ClipEnds.Free;
    Ids.Free;
    Origins.Free;
  end;
end;

procedure TFlashPlayer.InitializeAttachedClip(C: TFlashClip; Initial: TAVMObject);
var
  Action: TFlashQueuedAction;
  Keys: TArray<string>;
  I: Integer;
begin
  C.Started := True;
  Action := Default(TFlashQueuedAction);
  Action.Clip := C;
  Action.Generation := C.ContentGeneration;
  Action.EventName := 'onLoad';
  Action.EventFlags := SWFClipLoad;
  if FActions.Count >= 65536 then
    raise ESWFError.Create('Flash pending action limit');
  FActions.Add(Action);
  { Build the display list immediately, but frame scripts/load events wait
    until the current AVM action returns. Init values precede the constructor. }
  Inc(FDeferFrameActions);
  try
    StepClip(C, False);
  finally
    Dec(FDeferFrameActions);
  end;
  if Initial <> nil then
  begin
    Keys := VM.Enumerate(Initial);
    for I := High(Keys) downto 0 do
      VM.Put(C.Script, Keys[I], VM.Get(Initial, Keys[I]));
  end;
  ConstructClip(C);
end;

procedure TFlashPlayer.FlushActions;
var
  I, ConstructIndex: Integer;
  Action: TFlashQueuedAction;
  ConstructAction: TFlashQueuedConstruct;
  C: TFlashClip;
begin
  I := 0;
  ConstructIndex := 0;
  try
    while (I < FActions.Count) or (ConstructIndex < FConstructClips.Count) do
    begin
      if ConstructIndex < FConstructClips.Count then
      begin
        ConstructAction := FConstructClips[ConstructIndex];
        C := ConstructAction.Clip;
        Inc(ConstructIndex);
        if C.Dead or (C.ContentGeneration <> ConstructAction.Generation) then
          Continue;
        Fire(C, '', SWFClipInitialize);
        if C.Dead or (C.ContentGeneration <> ConstructAction.Generation) then
          Continue;
        Fire(C, '', SWFClipConstruct);
        if C.Dead or (C.ContentGeneration <> ConstructAction.Generation) then
          Continue;
        ConstructClip(C);
        Continue;
      end;
      Action := FActions[I];
      Inc(I);
      if Action.Clip.Dead or (Action.Clip.ContentGeneration <> Action.Generation) then
        Continue;
      Inc(FDeferFrameActions);
      try
        if Action.EventName <> '' then
          Fire(Action.Clip, Action.EventName, Action.EventFlags)
        else
          RunCode(Action.Clip, Action.Code);
        StepClip(Action.Clip, False);
      finally
        Dec(FDeferFrameActions);
      end;
    end;
  finally
    FConstructClips.Clear;
    FActions.Clear;
  end;
  ProcessUnloads(True);
end;

procedure TFlashPlayer.ApplyPendingSeeks(C: TFlashClip);
var
  Index, Jumps, I: Integer;
begin
  Jumps := 0;
  while C.PendingFrame >= 0 do
  begin
    Inc(Jumps);
    if Jumps > 1024 then
      raise ESWFError.Create('Flash timeline jump limit');
    Index := C.PendingFrame;
    C.PendingFrame := -1;
    if Index = C.Frame then
      Continue;
    FAudio.StopStream(C);
    if Index < C.Frame then
      SeekBack(C, Index)
    else
      for I := C.Frame + 1 to Index do
        ApplyFrame(C, I, I = Index);
  end;
end;

procedure TFlashPlayer.ApplyAVM2Goto(C: TFlashClip);
begin
  C.Playing := C.PendingAVM2Playing;
  if not C.Playing then
    FAudio.StopStream(C);
  C.SynchronousSeekTick := FFrameNumber + 1;
  if C.ApplyingAVM2Goto then
    Exit;
  C.ApplyingAVM2Goto := True;
  try
    ApplyPendingSeeks(C);
  finally
    C.ApplyingAVM2Goto := False;
  end;
end;

procedure TFlashPlayer.StepClip(C: TFlashClip; Advance: Boolean);
var
  Count, Index: Integer;
begin
  if C.Dead or C.Removing then
    Exit;
  if (C <> FRoot) and (C.CreatedFrame = FFrameNumber) then
    Advance := False;
  Count := Length(ClipFrames(C));
  if Count > 0 then
  begin
    Index := C.Frame;
    if Index < 0 then
      Index := 0
    else if Advance and C.Playing and (C.PendingFrame < 0) and
      (C.SynchronousSeekTick <> FFrameNumber + 1) then
      Index := (Index + 1) mod Count;
    if Index <> C.Frame then
    begin
      if Index < C.Frame then
        FAudio.StopStream(C);
      ApplyFrame(C, Index);
    end;
    ApplyPendingSeeks(C);
  end;
  for var Child in C.Children.ToArray do
    StepClip(Child, Advance);
end;

procedure TFlashPlayer.ConstructAVM2Clip(C: TFlashClip);
begin
  if not C.AVM2ConstructionPending then
    Exit;
  C.AVM2ConstructionPending := False;
  try
    C.MovieLibrary.AVM2.SyncTimelineDisplay(C);
    if C.MovieRoot then
      C.MovieLibrary.AVM2.CreateDocument(C.MovieLibrary.Movie.DocumentClass);
  except
    on E: EAVM2Error do
      raise ESWFError.Create('AVM2 document: ' + E.Message);
  end;
end;

procedure TFlashPlayer.BroadcastAVM2FrameEvent(Phase: TAVM2FrameEvent);
var
  MovieLibrary: TFlashLibrary;
begin
  for MovieLibrary in FLibraries.ToArray do
    if (MovieLibrary.AVM2 <> nil) and (MovieLibrary.Root <> nil) and
      (MovieLibrary.Root.MovieLibrary = MovieLibrary) and not MovieLibrary.Root.Dead then
    try
      MovieLibrary.AVM2.BroadcastFrameEvent(Phase);
    except
      on E: EAVM2Error do
        raise ESWFError.Create('AVM2 frame event: ' + E.Message);
    end;
end;

function TFlashPlayer.AVM2TimelineRoot(LibraryItem: TFlashLibrary): TFlashClip;
begin
  Result := LibraryItem.Root;
  if (Result = FRoot) and (FAVM2Stage <> nil) then
    Result := FAVM2Stage;
end;

procedure TFlashPlayer.CompleteAVM2Frame;
var
  MovieLibrary: TFlashLibrary;

  procedure ConstructTree(Clip: TFlashClip);
  var
    Child: TFlashClip;
  begin
    if Clip.Dead or Clip.Removing then
      Exit;
    ConstructAVM2Clip(Clip);
    for Child in ChildrenInDepthOrder(Clip) do
      if (Child.Parent = Clip) and (Child.MovieLibrary = Clip.MovieLibrary) then
        ConstructTree(Child);
  end;

begin
  if FAVM2FrameDepth >= 128 then
    raise ESWFError.Create('AVM2 nested frame limit');
  Inc(FAVM2FrameDepth);
  try
    for MovieLibrary in FLibraries.ToArray do
      if (MovieLibrary.AVM2 <> nil) and (MovieLibrary.Root <> nil) and
        (MovieLibrary.Root.MovieLibrary = MovieLibrary) then
        ConstructTree(AVM2TimelineRoot(MovieLibrary));
    BroadcastAVM2FrameEvent(afConstructed);
    RunAVM2FrameScripts;
    BroadcastAVM2FrameEvent(afExit);
  finally
    Dec(FAVM2FrameDepth);
  end;
end;

procedure TFlashPlayer.RunAVM2FrameScripts;
var
  LibraryItem: TFlashLibrary;
  Jumps, Passes: Integer;

  procedure Visit(Clip: TFlashClip; Runtime: TAVM2Runtime);
  var
    Child: TFlashClip;
  begin
    if Clip.Dead or Clip.Removing then
      Exit;
    while Clip.FrameScriptPending and not Clip.ExecutingFrameScript and not Clip.Dead and not Clip.Removing do
    begin
      Clip.FrameScriptPending := False;
      Clip.ExecutingFrameScript := True;
      try
        Runtime.RunFrameScript(Clip, Max(0, Clip.Frame));
      finally
        Clip.ExecutingFrameScript := False;
      end;
      if Clip.PendingFrame >= 0 then
      begin
        Inc(Jumps);
        if Jumps > 1024 then
          raise ESWFError.Create('AVM2 frame script jump limit');
        ApplyAVM2Goto(Clip);
        if Clip.MovieLibrary.Movie.Version >= 10 then
          CompleteAVM2Frame;
      end;
    end;
    if Clip.Dead or Clip.Removing then
      Exit;
    for Child in ChildrenInDepthOrder(Clip) do
      if (Child.Parent = Clip) and (Child.MovieLibrary = Clip.MovieLibrary) then
        Visit(Child, Runtime);
  end;

begin
  if FAVM2FrameScriptDepth >= 128 then
    raise ESWFError.Create('AVM2 frame script nesting limit');
  Inc(FAVM2FrameScriptDepth);
  Jumps := 0;
  Passes := 0;
  try
    repeat
      Inc(Passes);
      if Passes > 1024 then
        raise ESWFError.Create('AVM2 frame script pass limit');
      FAVM2FrameScriptsChanged := False;
      for LibraryItem in FLibraries.ToArray do
        if (LibraryItem.AVM2 <> nil) and (LibraryItem.Root <> nil) and (LibraryItem.Root.MovieLibrary = LibraryItem) then
        try
          Visit(AVM2TimelineRoot(LibraryItem), LibraryItem.AVM2);
        except
          on E: EAVM2Error do
            raise ESWFError.Create('AVM2 frame script: ' + E.Message);
        end;
    until not FAVM2FrameScriptsChanged;
  finally
    Dec(FAVM2FrameScriptDepth);
  end;
end;

procedure TFlashPlayer.Fire(C: TFlashClip; const Name: string; Flags: Cardinal);
var
  Value: TAVMValue;
  Action: TSWFClipAction;
begin
  if (C = nil) or C.Dead then
    Exit;
  if (Name <> '') and
    ((Name <> 'onMouseMove') or VM.MayHaveEventMember(C.Script, [emMouseMove, emResolve])) and
    ((Name <> 'onEnterFrame') or VM.MayHaveEventMember(C.Script, [emEnterFrame, emResolve])) then
  begin
    Value := VM.Get(C.Script, Name);
    VM.Call(Value, C.Script, nil);
  end;
  for Action in C.ClipActions.ToArray do
    if (Action.Events and Flags) <> 0 then
      RunCode(C, Action.Code);
end;

procedure TFlashPlayer.ButtonEvent(C: TFlashClip; Conditions: Word);
var
  Audio: TSWFButtonSounds;
begin
  if (C = nil) or C.Dead or (C.Character = nil) or not (C.Character.Kind in [7, 34]) then
    Exit;
  if C.MovieLibrary.Movie.ButtonSounds.TryGetValue(C.Character.Id, Audio) then
    case Conditions of
      2:
        PlaySoundEvent(C, Audio[0]);
      1:
        PlaySoundEvent(C, Audio[1]);
      4:
        PlaySoundEvent(C, Audio[2]);
      8:
        PlaySoundEvent(C, Audio[3]);
    end;
  var Target := C.Parent;
  if Target = nil then
    Target := FRoot;
  for var Action in C.Character.ButtonActions do
    if (Action.Conditions and Conditions and $1FF) <> 0 then
      RunCode(Target, Action.Code);
end;

procedure TFlashPlayer.PlaySoundEvent(C: TFlashClip; const Event: TSWFSoundEvent);
var
  Sound: TSWFSound;
begin
  if (Event.Id <> 0) and C.MovieLibrary.Movie.Sounds.TryGetValue(Event.Id, Sound) then
    FAudio.Start(Sound, C, Event.Info);
end;

procedure TFlashPlayer.InstallSoundClass;
var
  ConstructorValue: TAVMValue;
  Prototype: TAVMObject;
  Name: string;
begin
  ConstructorValue := VM.NativeFunction('Sound');
  Prototype := VM.NewObject;
  VM.PutData(ConstructorValue.Obj, 'prototype', TAVMValue.Ref(Prototype));
  ConstructorValue.Obj.Attributes.AddOrSetValue('prototype', 3);
  VM.PutData(Prototype, 'constructor', ConstructorValue);
  Prototype.Attributes.AddOrSetValue('constructor', 1);
  for Name in ['getPan', 'getTransform', 'getVolume', 'setPan', 'setTransform', 'setVolume', 'stop', 'attachSound', 'start', 'getDuration', 'setDuration', 'getPosition', 'setPosition', 'loadSound', 'getBytesLoaded', 'getBytesTotal'] do
  begin
    VM.PutData(Prototype, Name, VM.NativeFunction('Sound.' + Name));
    if MatchStr(Name, ['getDuration', 'setDuration', 'getPosition', 'setPosition', 'loadSound',
        'getBytesLoaded', 'getBytesTotal']) then
      Prototype.Attributes.AddOrSetValue(Name, $87)
    else
      Prototype.Attributes.AddOrSetValue(Name, 7);
  end;
  VM.PutData(VM.Global, 'Sound', ConstructorValue);
  VM.Global.Attributes.AddOrSetValue('Sound', 1);
end;

function TFlashPlayer.SoundLibrary(Owner: TFlashClip): TFlashLibrary;
var
  Caller: TFlashClip;
begin
  if Owner <> nil then
    Result := Owner.MovieLibrary
  else if VM.MovieContext is TFlashLibrary then
    Result := TFlashLibrary(VM.MovieContext)
  else
  begin
    Caller := Clip(VM.Root);
    if Caller = nil then
      Caller := FRoot;
    Result := Caller.MovieLibrary;
  end;
end;

function TFlashPlayer.ResolveSoundExport(Owner: TFlashClip; const Name: string): TSWFSound;
var
  LibraryValue: TFlashLibrary;
  Id: Integer;
begin
  Result := nil;
  LibraryValue := SoundLibrary(Owner);
  if LibraryValue.ExportNames.TryGetValue(AVMLowerName(Name), Id) then
    LibraryValue.Movie.Sounds.TryGetValue(Id, Result);
end;

procedure TFlashPlayer.AddSoundProperties(Receiver: TAVMObject);
begin
  if VM.HasProperty(Receiver, 'position') and VM.HasProperty(Receiver, 'duration') then
    Exit;
  VM.AddProperty(Receiver, 'position', VM.NativeFunction('Sound.position').Obj, nil);
  VM.AddProperty(Receiver, 'duration', VM.NativeFunction('Sound.duration').Obj, nil);
  Receiver.Attributes.AddOrSetValue('position', 3);
  Receiver.Attributes.AddOrSetValue('duration', 3);
end;

procedure TFlashPlayer.LoadSound(Receiver: TAVMObject; const URL: string; Streaming: Boolean);
const
  TagIds: array[0..6] of string = ('COMM', 'TALB', 'TCON', 'TIT2', 'TPE1', 'TRCK', 'TYER');
  LegacyNames: array[0..6] of string = ('comment', 'album', 'genre', 'songname', 'artist', 'track', 'year');
var
  State: TFlashSoundState;
  Data: TBytes;
  URI: string;
  Decoded: TSWFSound;
  Metadata: TMP3Metadata;
  Generation: UInt64;
  Available: Integer;
  Success: Boolean;

  procedure Notify(const Name: string; Value: Boolean);
  begin
    try
      VM.Call(VM.Get(Receiver, Name), Receiver, [TAVMValue.Bool(Value)]);
    except
      on E: EAVMThrown do
        ReportUncaught(E.Value);
    end;
  end;

  function IsCurrent: Boolean;
  begin
    Result := (Receiver.OwnedNativeData = State) and (State.Generation = Generation);
  end;

  procedure InstallMetadata;
  var
    Id3: TAVMObject;
    Frame: TMP3TextFrame;
    Value, FieldValue: TAVMValue;
    Index, CommentCount: Integer;
    Comments: TArray<TAVMValue>;
  begin
    if VM.HasProperty(Receiver, 'id3') then
      Exit;
    Id3 := VM.NewObject;
    Id3.Prototype := nil;
    Id3.RemoveData('__proto__');
    for Frame in Metadata.TextFrames do
    begin
      Value := TAVMValue.Str(Frame.Text);
      FieldValue := Value;
      Index := IndexStr(Frame.Id, TagIds);
      if Index = 0 then
      begin
        CommentCount := Length(Comments);
        SetLength(Comments, CommentCount + 1);
        Comments[CommentCount] := Value;
        FieldValue := TAVMValue.Ref(VM.CreateArray(Comments));
      end;
      if Index >= 0 then
        VM.PutData(Id3, LegacyNames[Index], Value);
      VM.PutData(Id3, Frame.Id, FieldValue);
    end;
    VM.PutData(Receiver, 'id3', TAVMValue.Ref(Id3));
    Receiver.Attributes.AddOrSetValue('id3', 7);
  end;

begin
  State := TFlashSoundState(Receiver.OwnedNativeData);
  Generation := State.Generation;
  if State.Loading then
  begin
    State.Loading := False;
    Notify('onLoad', False);
    if not IsCurrent then
      Exit;
  end;
  State.ReleaseExternal;
  Inc(State.Generation);
  Generation := State.Generation;
  State.external := True;
  State.Streaming := Streaming;
  State.Loading := True;
  State.AutoPlay := Streaming;
  State.BytesLoaded := 0;
  State.Sound := nil;
  State.Position := 0;
  State.Duration := 0;
  State.ExternalTransform := TFlashSoundTransform.Identity;
  Decoded := nil;
  try
    if Assigned(FReadResource) and FReadResource(SoundLibrary(nil).URI, URL, Data, URI) and
      (Length(Data) <= 64 * 1024 * 1024) then
    begin
      Available := Min(SWFMovieSoundSampleLimit,
        (FlashLibraryMemoryLimit - FLoadedBytes) div SizeOf(SmallInt)) - FExternalSoundSamples;
      Metadata := ReadMP3Metadata(Data);
      Decoded := ReadMP3File(Data, Metadata.AudioOffset, Metadata.AudioEnd, Available);
    end;
  except
    on E: Exception do
      Movie.Warn('Sound.loadSound: ' + E.Message);
  end;
  if not IsCurrent then
  begin
    Decoded.Free;
    Exit;
  end;
  Success := Decoded <> nil;
  if Success then
  begin
    State.ExternalSound := Decoded;
    State.Sound := Decoded;
    Inc(FExternalSoundSamples, Length(Decoded.Samples));
    State.BytesLoaded := Length(Data);
    AddSoundProperties(Receiver);
    if not IsCurrent then
      Exit;
    if Metadata.Present then
    begin
      InstallMetadata;
      Notify('onID3', True);
      if not IsCurrent then
        Exit;
    end;
    State.Duration := Trunc(Decoded.FrameCount * 1000.0 / Decoded.SampleRate + 0.5);
  end;
  State.Loading := False;
  Notify('onLoad', Success);
  if Success and IsCurrent and State.AutoPlay then
    SoundCall('Sound.start', Receiver, nil);
end;

function TFlashPlayer.SoundCall(const Name: string; Receiver: TAVMObject; const Args: TArray<TAVMValue>): TAVMValue;
var
  State: TFlashSoundState;
  Owner, Target: TFlashClip;
  Sound: TSWFSound;
  Transform: TFlashSoundTransform;
  ObjectValue: TAVMObject;
  Argument: TAVMValue;
  Symbol, Path: string;
  Offset, Loops: Double;
  Info: TSWFSoundInfo;
  Number: Integer;
  HasTarget: Boolean;

  function TransformValue(const PropertyName: string; Fallback: Integer): Integer;
  begin
    Result := Fallback;
    if VM.HasOwnProperty(ObjectValue, PropertyName) then
      Result := AVMToInt32(VM.CoerceNumber(VM.Get(ObjectValue, PropertyName)));
  end;

  function OwnerClip: TFlashClip;
  begin
    Result := nil;
    if State.external or not State.HasTarget or (State.TargetPath = '') then
      Exit;
    Target := Clip(VM.CurrentTarget);
    if Target = nil then
      Target := Clip(VM.Root);
    Result := ResolveClip(Target, TAVMValue.Str(State.TargetPath));
    if (Result <> nil) and (Result.Dead or Result.Removing) then
      Result := nil;
  end;

  function ArgumentInt: Integer;
  var
    Value: Double;
  begin
    if Length(Args) = 0 then
      Exit(0);
    Value := VM.CoerceNumber(Argument);
    if IsNan(Value) or (Value >= 2147483648.0) or (Value < -2147483648.0) then
      Exit(Low(Integer));
    Result := Trunc(Value);
  end;

begin
  Result := Default(TAVMValue);
  if Receiver = nil then
    Exit;
  Argument := Default(TAVMValue);
  if Length(Args) > 0 then
    Argument := Args[0];
  if Name = 'Sound' then
  begin
    HasTarget := not (Argument.Kind in [avNull, avUndefined]);
    Path := '';
    if HasTarget then
      Path := VM.CoerceString(Argument);
    if not (Receiver.OwnedNativeData is TFlashSoundState) then
    begin
      FreeAndNil(Receiver.OwnedNativeData);
      Receiver.OwnedNativeData := TFlashSoundState.Create;
    end;
    State := TFlashSoundState(Receiver.OwnedNativeData);
    State.Player := Self;
    State.ReleaseExternal;
    Inc(State.Generation);
    State.HasTarget := HasTarget;
    State.TargetPath := Path;
    State.external := False;
    State.Loading := False;
    State.Streaming := False;
    State.AutoPlay := False;
    State.BytesLoaded := 0;
    State.Sound := nil;
    State.Position := 0;
    State.Duration := 0;
    Exit(TAVMValue.Ref(Receiver));
  end;
  if not (Receiver.OwnedNativeData is TFlashSoundState) then
    Exit;
  State := TFlashSoundState(Receiver.OwnedNativeData);
  if MatchStr(Name, ['Sound.setDuration', 'Sound.setPosition']) then
    Exit;

  Symbol := '';
  if (Name = 'Sound.attachSound') or ((Name = 'Sound.stop') and (Length(Args) > 0)) then
    Symbol := VM.CoerceString(Argument);
  Number := 0;
  if MatchStr(Name, ['Sound.setVolume', 'Sound.setPan']) then
    Number := ArgumentInt;
  Owner := OwnerClip;
  if State.HasTarget and not State.external and (Owner = nil) then
    Exit;

  if Name = 'Sound.loadSound' then
  begin
    if Length(Args) > 0 then
      LoadSound(Receiver, VM.CoerceString(Argument),
        (Length(Args) > 1) and Args[1].AsBoolean(VM.SWFVersion));
    Exit;
  end;
  if MatchStr(Name, ['Sound.getBytesLoaded', 'Sound.getBytesTotal']) then
    Exit(TAVMValue.Num(State.BytesLoaded));

  if Name = 'Sound.attachSound' then
  begin
    if State.external then
      Exit;
    Sound := ResolveSoundExport(Owner, Symbol);
    if Sound = nil then
      Exit;
    State.Sound := Sound;
    State.Position := 0;
    State.Duration := Trunc(Sound.FrameCount * 1000.0 / Sound.SampleRate + 0.5);
    AddSoundProperties(Receiver);
    Exit;
  end;
  if MatchStr(Name, ['Sound.getDuration', 'Sound.duration', 'Sound.getPosition', 'Sound.position']) then
  begin
    if State.Sound = nil then
      Exit;
    if (Name = 'Sound.getPosition') or (Name = 'Sound.position') then
      Exit(TAVMValue.Num(State.Position));
    Exit(TAVMValue.Num(State.Duration));
  end;
  if Name = 'Sound.start' then
  begin
    Offset := 0;
    Loops := 1;
    if Length(Args) > 0 then
      Offset := VM.CoerceNumber(Argument);
    if (Length(Args) > 1) and not State.Streaming then
      Loops := VM.CoerceNumber(Args[1]);
    Info := Default(TSWFSoundInfo);
    if not IsNan(Offset) and (Offset > 0) then
    begin
      if Offset >= High(Cardinal) / SWFSoundRate then
        Info.First := High(Cardinal)
      else
        Info.First := Trunc(Offset * SWFSoundRate);
    end;
    if not IsNan(Loops) and (Loops > 1) then
      Info.Loops := Trunc(Min(Loops, High(Word)));
    if State.external then
    begin
      if State.Streaming then
        FAudio.StopSound(State.ExternalSound);
      FAudio.Start(State.Sound, State, Info, Receiver);
    end
    else
      FAudio.Start(State.Sound, Owner, Info, Receiver);
    Exit;
  end;
  if Name = 'Sound.stop' then
  begin
    if State.external then
    begin
      State.AutoPlay := False;
      if (Length(Args) = 0) and (State.ExternalSound <> nil) then
        FAudio.StopSound(State.ExternalSound);
    end
    else if Length(Args) > 0 then
    begin
      Sound := ResolveSoundExport(Owner, Symbol);
      if Sound <> nil then
        FAudio.StopSound(Sound);
    end
    else if Owner <> nil then
      FAudio.StopOwner(Owner)
    else
      FAudio.Clear;
    Exit;
  end;

  if State.external then
    Transform := State.ExternalTransform
  else if Owner <> nil then
    Transform := Owner.SoundTransform
  else
    Transform := FGlobalSoundTransform;
  if Name = 'Sound.getVolume' then
    Exit(TAVMValue.Num(Transform.Volume));
  if Name = 'Sound.getPan' then
    Exit(TAVMValue.Num(Transform.Pan));
  if Name = 'Sound.getTransform' then
  begin
    ObjectValue := VM.NewObject;
    VM.Put(ObjectValue, 'll', TAVMValue.Num(Transform.LL));
    VM.Put(ObjectValue, 'lr', TAVMValue.Num(Transform.LR));
    VM.Put(ObjectValue, 'rr', TAVMValue.Num(Transform.RR));
    VM.Put(ObjectValue, 'rl', TAVMValue.Num(Transform.RL));
    Exit(TAVMValue.Ref(ObjectValue));
  end;
  if Name = 'Sound.setVolume' then
    Transform.Volume := Number
  else if Name = 'Sound.setPan' then
    Transform.SetPan(Number)
  else if Name = 'Sound.setTransform' then
  begin
    ObjectValue := Argument.Obj;
    Transform.LL := TransformValue('ll', Transform.LL);
    Transform.RL := TransformValue('rl', Transform.RL);
    Transform.LR := TransformValue('lr', Transform.LR);
    Transform.RR := TransformValue('rr', Transform.RR);
  end
  else
    Exit;
  if State.external then
    State.ExternalTransform := Transform
  else if Owner <> nil then
    Owner.SoundTransform := Transform
  else
    FGlobalSoundTransform := Transform;
end;

function TFlashPlayer.ReadSoundTransform(Owner: TObject): TFlashSoundTransform;
var
  C: TFlashClip;
  Transform: TAVM2Object;
  Value: TAVM2Value;
begin
  Result := TFlashSoundTransform.Identity;
  if Owner is TAVM2Object then
  begin
    Transform := TAVM2Object(Owner).Props[#0 + 'soundTransform'].Obj;
    if Transform <> nil then
    begin
      if Transform.Props.TryGetValue(#0 + 'volume', Value) and not IsNan(Value.Number) then
        Result.Volume := Round(EnsureRange(Value.Number, 0.0, 1.0) * 10000);
      if Transform.Props.TryGetValue(#0 + 'pan', Value) and not IsNan(Value.Number) then
        Result.SetPan(Round(EnsureRange(Value.Number, -1.0, 1.0) * 10000));
    end;
    Exit(Result.ThenBy(FGlobalSoundTransform));
  end;
  if Owner is TFlashSoundState then
    Exit(Result.ThenBy(TFlashSoundState(Owner).ExternalTransform).ThenBy(FGlobalSoundTransform));
  if Owner is TFlashStreamState then
    Exit(FGlobalSoundTransform);
  C := TFlashClip(Owner);
  while C <> nil do
  begin
    Result := Result.ThenBy(C.SoundTransform);
    C := C.Parent;
  end;
  Result := Result.ThenBy(FGlobalSoundTransform);
end;

procedure TFlashPlayer.UpdateSoundProgress(Client: TObject; Position: UInt32; Finished: Boolean);
var
  O: TAVMObject;
  Channel: TAVM2Object;
begin
  if Client is TAVM2Object then
  begin
    Channel := TAVM2Object(Client);
    Channel.Props[#0 + 'position'] := TAVM2Value.Num(Position);
    Channel.SoundFinished := Finished;
    Exit;
  end;
  O := TAVMObject(Client);
  if O.OwnedNativeData is TFlashSoundState then
    TFlashSoundState(O.OwnedNativeData).Position := Position;
  if Finished then
    VM.QueueEvent(O, 'onSoundComplete', nil);
end;

procedure TFlashPlayer.StopSounds;
begin
  FAudio.Clear;
end;

function TFlashPlayer.MixAudio(Frames: Integer): TArray<SmallInt>;
begin
  Result := FAudio.Mix(Frames, ReadSoundTransform, UpdateSoundProgress);
end;

function HasTimelineMask(C: TFlashClip): Boolean;
begin
  Result := not C.Dead and not C.Removing and (C.ClipDepth > 0) and
    ((C.Children.Count > 0) or C.IsText or (C.AttachedBitmap <> nil) or
    C.DrawingTouched or ((C.Character <> nil) and (C.Character.Kind <> 39)));
end;

function TFlashPlayer.PointInMask(Mask: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; Depth: Integer): Boolean;
begin
  Result := False;
  if Mask.TestingMask or (Depth >= 256) then
    Exit;
  Mask.TestingMask := True;
  try
    Result := ContainsPoint(Mask, X, Y, ParentMatrix, False, False, True, True, Depth);
  finally
    Mask.TestingMask := False;
  end;
end;

function TFlashPlayer.PointChildren(C: TFlashClip; X, Y: Double; const Matrix: TSWFMatrix; HitState: Boolean; Depth: Integer): TArray<TFlashClip>;
type
  TPointMask = record
    PreviousEnd: Integer;
    PreviousInside: Boolean;
  end;
var
  Child: TFlashClip;
  Stack: TStack<TPointMask>;
  Entry: TPointMask;
  Inside: Boolean;
  ClipEnd, Count, State: Integer;
begin
  Result := nil;
  if C.Children.Count = 0 then
    Exit;
  Result := ChildrenInDepthOrder(C);
  Inside := True;
  ClipEnd := 0;
  Count := 0;
  Stack := nil;
  try
    for var I := 0 to High(Result) do
    begin
      Child := Result[I];
      while (ClipEnd > 0) and (Child.Depth > ClipEnd) do
      begin
        Entry := Stack.Pop;
        Inside := Entry.PreviousInside;
        ClipEnd := Entry.PreviousEnd;
      end;
      if Child.ButtonStates <> 0 then
      begin
        State := 1;
        if HitState then
          State := 8;
        if (Child.ButtonStates and State) = 0 then
          Continue;
      end;
      if HasTimelineMask(Child) then
      begin
        if Stack = nil then
          Stack := TStack<TPointMask>.Create;
        if Stack.Count >= 128 then
          raise ESWFError.Create('Flash timeline mask nesting limit');
        Entry.PreviousEnd := ClipEnd;
        Entry.PreviousInside := Inside;
        Stack.Push(Entry);
        ClipEnd := Child.ClipDepth;
        Inside := Inside and PointInMask(Child, X, Y, Matrix, Depth + 1);
      end
      else if Inside and (Child.Maskee = nil) then
      begin
        Result[Count] := Child;
        Inc(Count);
      end;
    end;
    SetLength(Result, Count);
  finally
    Stack.Free;
  end;
end;

function InScrollViewport(C: TFlashClip; X, Y: Double; const Matrix: TSWFMatrix): Boolean;
var
  Viewport: TSWFRect;
  Det, PX, PY, LX, LY: Double;
begin
  if not C.HasAppliedScrollRect then
    Exit(True);
  Result := False;
  Viewport := ScrollViewport(C.AppliedScrollRect);
  if (Viewport.Right <= 0) or (Viewport.Bottom <= 0) then
    Exit;
  Det := Matrix.A * Matrix.D - Matrix.B * Matrix.C;
  if (Det = 0) or IsNan(Det) or IsInfinite(Det) then
    Exit;
  PX := X * 20 - Matrix.TX;
  PY := Y * 20 - Matrix.TY;
  LX := (Matrix.D * PX - Matrix.C * PY) / Det;
  LY := (-Matrix.B * PX + Matrix.A * PY) / Det;
  Result := (LX >= 0) and (LY >= 0) and (LX <= Viewport.Right) and (LY <= Viewport.Bottom);
end;

function TryPaintInverse(const PaintToFrame: TSWFMatrix; out Inverse: TSWFMatrix): Boolean; forward;

procedure BuildStrokeEdges(const Path: TSWFStrokePath; const Line: TSWFStroke; const ShapeToFrame: TSWFMatrix; Edges: TList<TSWFEdge>);
var
  PenToFrame, FrameToPen: TSWFMatrix;
  PenScale, ScaleX, ScaleY, HalfWidth: Double;
  First, Previous, Current, FirstDirection, PreviousDirection, Direction: TSWFPoint;
  DX, DY, SegmentLength: Double;
  I: Integer;
  HasSegment, Closed, TransformCenters: Boolean;

  function Point(X, Y: Double): TSWFPoint;
  begin
    Result.X := X;
    Result.Y := Y;
  end;

  function Add(const A, B: TSWFPoint): TSWFPoint;
  begin
    Result := Point(A.X + B.X, A.Y + B.Y);
  end;

  function Scale(const A: TSWFPoint; Factor: Double): TSWFPoint;
  begin
    Result := Point(A.X * Factor, A.Y * Factor);
  end;

  function Normal(const Tangent: TSWFPoint): TSWFPoint;
  begin
    Result := Point(-Tangent.Y * HalfWidth, Tangent.X * HalfWidth);
  end;

  function Center(const P: TSWFPoint): TSWFPoint;
  var
    X, Y: Double;
  begin
    if not TransformCenters then
      Exit(P);
    X := ShapeToFrame.A * P.X + ShapeToFrame.C * P.Y;
    Y := ShapeToFrame.B * P.X + ShapeToFrame.D * P.Y;
    Result := Point(FrameToPen.A * X + FrameToPen.C * Y, FrameToPen.B * X + FrameToPen.D * Y);
  end;

  procedure EmitEdge(const A, B: TSWFPoint; Reverse: Boolean);
  var
    E: TSWFEdge;
    Temp: Double;
  begin
    E.X1 := PenToFrame.A * A.X + PenToFrame.C * A.Y + PenToFrame.TX;
    E.Y1 := PenToFrame.B * A.X + PenToFrame.D * A.Y + PenToFrame.TY;
    E.X2 := PenToFrame.A * B.X + PenToFrame.C * B.Y + PenToFrame.TX;
    E.Y2 := PenToFrame.B * B.X + PenToFrame.D * B.Y + PenToFrame.TY;
    if E.Y1 = E.Y2 then
      Exit;
    E.Fill := Path.Fill;
    if Reverse then
    begin
      Temp := E.X1;
      E.X1 := E.X2;
      E.X2 := Temp;
      Temp := E.Y1;
      E.Y1 := E.Y2;
      E.Y2 := Temp;
    end;
    if Edges.Count >= 1000000 then
      raise ESWFError.Create('Flash stroke edge limit');
    Edges.Add(E);
  end;

  procedure Polygon(const Points: array of TSWFPoint);
  var
    J: Integer;
    A, B: TSWFPoint;
    Area: Double;
  begin
    Area := 0;
    for J := 1 to High(Points) - 1 do
    begin
      A := Point(Points[J].X - Points[0].X, Points[J].Y - Points[0].Y);
      B := Point(Points[J + 1].X - Points[0].X, Points[J + 1].Y - Points[0].Y);
      Area := Area + A.X * B.Y - A.Y * B.X;
    end;
    if Area = 0 then
      Exit;
    for J := 0 to High(Points) - 1 do
      EmitEdge(Points[J], Points[J + 1], Area < 0);
    EmitEdge(Points[High(Points)], Points[0], Area < 0);
  end;

  procedure Sector(const Origin, FirstRadius, LastRadius: TSWFPoint; Angle: Double);
  var
    J, Steps: Integer;
    StepAngle, A: Double;
    Start, Last, Next: TSWFPoint;
  begin
    // Subdivide further as the stroke grows, with bounded work for extreme scales.
    Steps := Max(1, Ceil(Abs(Angle) * Sqrt(EnsureRange(HalfWidth * PenScale, 1.0, 25.0))));
    Start := Add(Origin, FirstRadius);
    Last := Start;
    StepAngle := Angle / Steps;
    A := ArcTan2(FirstRadius.Y, FirstRadius.X);
    EmitEdge(Origin, Start, Angle < 0);
    for J := 1 to Steps - 1 do
    begin
      Next := Add(Origin, Point(Cos(A + J * StepAngle) * HalfWidth, Sin(A + J * StepAngle) * HalfWidth));
      EmitEdge(Last, Next, Angle < 0);
      Last := Next;
    end;
    Next := Add(Origin, LastRadius);
    EmitEdge(Last, Next, Angle < 0);
    EmitEdge(Next, Origin, Angle < 0);
  end;

  procedure Cap(const Origin, Tangent: TSWFPoint; Kind: TSWFLineCap; StartCap: Boolean);
  var
    Offset, Extension, Left, Right: TSWFPoint;
  begin
    if Kind = lcNone then
      Exit;
    Offset := Normal(Tangent);
    Extension := Scale(Tangent, HalfWidth);
    if StartCap then
    begin
      Offset := Scale(Offset, -1);
      Extension := Scale(Extension, -1);
    end;
    if Kind = lcRound then
      Sector(Origin, Scale(Offset, -1), Offset, Pi)
    else
    begin
      Left := Add(Origin, Offset);
      Right := Add(Origin, Scale(Offset, -1));
      Polygon([Left, Right, Add(Right, Extension), Add(Left, Extension)]);
    end;
  end;

  procedure Join(const Origin, Before, After: TSWFPoint);
  var
    Turn, Dot, Side, MiterLength, Cut: Double;
    FirstOffset, NextOffset, FirstPoint, NextPoint, Miter: TSWFPoint;
  begin
    Turn := Before.X * After.Y - Before.Y * After.X;
    Dot := Before.X * After.X + Before.Y * After.Y;
    if Abs(Turn) < 1e-10 then
    begin
      if (Dot < 0) and (Line.Join = ljRound) then
        Cap(Origin, Before, lcRound, False);
      Exit;
    end;
    if Turn > 0 then
      Side := -1
    else
      Side := 1;
    FirstOffset := Scale(Normal(Before), Side);
    NextOffset := Scale(Normal(After), Side);
    if Line.Join = ljRound then
    begin
      Sector(Origin, FirstOffset, NextOffset, ArcTan2(Turn, Dot));
      Exit;
    end;
    FirstPoint := Add(Origin, FirstOffset);
    NextPoint := Add(Origin, NextOffset);
    if (Line.Join <> ljMiter) or (Line.MiterLimit < 1) or (Dot <= -1 + 1e-10) then
    begin
      Polygon([Origin, FirstPoint, NextPoint]);
      Exit;
    end;
    Miter := Scale(Add(FirstOffset, NextOffset), 1 / (1 + Dot));
    MiterLength := Hypot(Miter.X, Miter.Y) / HalfWidth;
    if MiterLength <= Line.MiterLimit then
      Polygon([Origin, FirstPoint, Add(Origin, Miter), NextPoint])
    else
    begin
      Cut := (Line.MiterLimit - 1 / MiterLength) / (MiterLength - 1 / MiterLength);
      Polygon([Origin, FirstPoint,
          Add(FirstPoint, Scale(Point(Miter.X - FirstOffset.X, Miter.Y - FirstOffset.Y), Cut)),
          Add(NextPoint, Scale(Point(Miter.X - NextOffset.X, Miter.Y - NextOffset.Y), Cut)), NextPoint]);
    end;
  end;

  procedure Body(const A, B, Tangent: TSWFPoint);
  var
    Offset, Opposite: TSWFPoint;
  begin
    Offset := Normal(Tangent);
    Opposite := Scale(Offset, -1);
    Polygon([Add(A, Offset), Add(A, Opposite), Add(B, Opposite), Add(B, Offset)]);
  end;

begin
  if Length(Path.Points) < 2 then
    Exit;
  PenToFrame := ShapeToFrame;
  TransformCenters := Line.NoHScale or Line.NoVScale;
  ScaleX := Hypot(PenToFrame.A, PenToFrame.B);
  ScaleY := Hypot(PenToFrame.C, PenToFrame.D);
  if (ScaleX = 0) or (ScaleY = 0) or IsNan(ScaleX) or IsNan(ScaleY) or
    IsInfinite(ScaleX) or IsInfinite(ScaleY) then
    Exit;
  // One twentieth of a framebuffer pixel per unscaled twip.
  if Line.NoHScale then
  begin
    PenToFrame.A := PenToFrame.A / (20 * ScaleX);
    PenToFrame.B := PenToFrame.B / (20 * ScaleX);
    ScaleX := 1 / 20;
  end;
  if Line.NoVScale then
  begin
    PenToFrame.C := PenToFrame.C / (20 * ScaleY);
    PenToFrame.D := PenToFrame.D / (20 * ScaleY);
    ScaleY := 1 / 20;
  end;
  PenScale := Max(ScaleX, ScaleY);
  HalfWidth := Line.Width / 2;
  if 2 * HalfWidth * PenScale < 1 then
  begin
    PenToFrame := TSWFMatrix.Identity;
    PenToFrame.TX := ShapeToFrame.TX;
    PenToFrame.TY := ShapeToFrame.TY;
    HalfWidth := 0.5;
    PenScale := 1;
    TransformCenters := True;
  end;
  if not TryPaintInverse(PenToFrame, FrameToPen) then
    Exit;

  First := Center(Path.Points[0]);
  Previous := First;
  HasSegment := False;
  Closed := not Line.NoClose and
    (Path.Points[0].X = Path.Points[High(Path.Points)].X) and
    (Path.Points[0].Y = Path.Points[High(Path.Points)].Y);
  for I := 1 to High(Path.Points) do
  begin
    Current := Center(Path.Points[I]);
    DX := Current.X - Previous.X;
    DY := Current.Y - Previous.Y;
    SegmentLength := Hypot(DX, DY);
    if SegmentLength = 0 then
      Continue;
    Direction := Point(DX / SegmentLength, DY / SegmentLength);
    if HasSegment then
      Join(Previous, PreviousDirection, Direction)
    else
    begin
      FirstDirection := Direction;
      if not Closed then
        Cap(First, Direction, Line.StartCap, True);
    end;
    Body(Previous, Current, Direction);
    PreviousDirection := Direction;
    Previous := Current;
    HasSegment := True;
  end;
  if HasSegment then
  begin
    if Closed then
      Join(First, PreviousDirection, FirstDirection)
    else
      Cap(Previous, PreviousDirection, Line.EndCap, False);
  end
  else if (Line.StartCap = lcRound) or (Line.EndCap = lcRound) then
    Sector(First, Point(HalfWidth, 0), Point(HalfWidth, 0), 2 * Pi);
end;

function TFlashPlayer.FindStrokeHit(Shape: TSWFCharacter; const Matrix: TSWFMatrix): PFlashStrokeHit;
var
  Cache, Replacement: PFlashStrokeHit;
begin
  Result := nil;
  if not (Shape.Kind in [2, 22, 32, 83]) or (Shape.Fills = nil) or
    (Length(Shape.StrokePaths) < FlashStrokeHitMinPaths) or
    (Length(Shape.StrokePaths) > FlashStrokeHitMaxPaths) then
    Exit;
  Replacement := @FStrokeHits[Low(FStrokeHits)];
  for var I := Low(FStrokeHits) to High(FStrokeHits) do
  begin
    Cache := @FStrokeHits[I];
    if (Cache.Paths <> nil) and (@Cache.Paths[0] = @Shape.StrokePaths[0]) and
      (@Cache.Fills[0] = @Shape.Fills[0]) and CompareMem(@Cache.Matrix, @Matrix, SizeOf(Matrix)) then
    begin
      Cache.LastUsed := FFrameNumber;
      Exit(Cache);
    end;
    if (Replacement.Paths <> nil) and ((Cache.Paths = nil) or (Cache.LastUsed < Replacement.LastUsed)) then
      Replacement := Cache;
  end;
  Replacement^ := Default(TFlashStrokeHit);
  Replacement.Paths := Shape.StrokePaths;
  Replacement.Fills := Shape.Fills;
  Replacement.Matrix := Matrix;
  Replacement.LastUsed := FFrameNumber;
  SetLength(Replacement.Outlines, Length(Replacement.Paths));
  Result := Replacement;
end;

function RayWinding(const Edge: TSWFEdge; X, Y: Double): Integer; forward;

function TFlashPlayer.PointOnStroke(Shape: TSWFCharacter; const M: TSWFMatrix; X, Y: Double; DrawingClip: TFlashClip): Boolean;
var
  FrameMatrix: TSWFMatrix;
  Edges: TList<TSWFEdge>;
  Cache: PFlashStrokeHit;
  Pending: TSWFStrokePath;
  HasPending: Boolean;

  function Inside(const Outline: TArray<TSWFEdge>; Count: Integer): Boolean;
  var
    Winding: Integer;
  begin
    Winding := 0;
    for var I := 0 to Count - 1 do
      Inc(Winding, RayWinding(Outline[I], X, Y));
    Result := Winding <> 0;
  end;

  procedure Build(const Stroke: TSWFStrokePath);
  begin
    if Edges = nil then
      Edges := TList<TSWFEdge>.Create
    else
      Edges.Clear;
    BuildStrokeEdges(Stroke, Shape.Fills[Stroke.Fill - 1].Line, FrameMatrix, Edges);
  end;

  function HitPath(Index: Integer): Boolean;
  var
    Outline: ^TFlashStrokeHitOutline;
  begin
    if Cache = nil then
    begin
      Build(Shape.StrokePaths[Index]);
      Exit(Inside(Edges.List, Edges.Count));
    end;
    Outline := @Cache.Outlines[Index];
    if not Outline.Built then
    begin
      Build(Shape.StrokePaths[Index]);
      Outline.MinY := Infinity;
      Outline.MaxY := NegInfinity;
      for var I := 0 to Edges.Count - 1 do
      begin
        var E := Edges[I];
        Outline.MinY := Min(Outline.MinY, Min(E.Y1, E.Y2));
        Outline.MaxY := Max(Outline.MaxY, Max(E.Y1, E.Y2));
      end;
      if Cache.EdgeCount + Edges.Count <= FlashStrokeHitMaxEdges then
      begin
        Outline.Edges := Edges.ToArray;
        Inc(Cache.EdgeCount, Edges.Count);
      end;
      Outline.Built := True;
      Exit(Inside(Edges.List, Edges.Count));
    end;
    if (Y < Outline.MinY) or (Y >= Outline.MaxY) then
      Exit(False);
    if Outline.Edges <> nil then
      Exit(Inside(Outline.Edges, Length(Outline.Edges)));
    Build(Shape.StrokePaths[Index]);
    Result := Inside(Edges.List, Edges.Count);
  end;

begin
  HasPending := (DrawingClip <> nil) and DrawingClip.PendingStroke(Pending);
  if (Length(Shape.StrokePaths) = 0) and not HasPending then
    Exit(False);
  FrameMatrix.A := M.A / 20;
  FrameMatrix.B := M.B / 20;
  FrameMatrix.C := M.C / 20;
  FrameMatrix.D := M.D / 20;
  FrameMatrix.TX := M.TX / 20;
  FrameMatrix.TY := M.TY / 20;
  Cache := nil;
  if DrawingClip = nil then
    Cache := FindStrokeHit(Shape, FrameMatrix);
  Edges := nil;
  try
    for var I := 0 to High(Shape.StrokePaths) do
      if HitPath(I) then
        Exit(True);
    if not HasPending then
      Exit(False);
    Build(Pending);
    Result := Inside(Edges.List, Edges.Count);
  finally
    Edges.Free;
  end;
end;

function RayWinding(const Edge: TSWFEdge; X, Y: Double): Integer;
begin
  Result := 0;
  if (Y < Min(Edge.Y1, Edge.Y2)) or (Y >= Max(Edge.Y1, Edge.Y2)) then
    Exit;
  if Edge.X1 + (Y - Edge.Y1) * (Edge.X2 - Edge.X1) / (Edge.Y2 - Edge.Y1) > X then
  begin
    if Edge.Y2 > Edge.Y1 then
      Result := 1
    else
      Result := -1;
  end;
end;

function FillHitBin(Cache: PFlashFillHit; Y: Double): Integer;
begin
  Result := Min(FlashFillHitBins - 1, Trunc((Y - Cache.MinY) * Cache.BinScale));
end;

function TFlashPlayer.FindFillHit(Shape: TSWFCharacter): PFlashFillHit;
var
  Cache, Replacement: PFlashFillHit;
  Counts: array[0..FlashFillHitBins] of Integer;
  First, Last: Integer;

  procedure EdgeBins(const Edge: TSWFEdge);
  begin
    First := FillHitBin(Replacement, Min(Edge.Y1, Edge.Y2));
    Last := FillHitBin(Replacement, Max(Edge.Y1, Edge.Y2));
    // Wide edges share a bin to cap the number of stored indices.
    if Last - First >= 4 then
    begin
      First := FlashFillHitBins;
      Last := First;
    end;
  end;

begin
  Result := nil;
  if not (Shape.Kind in [2, 22, 32, 83]) or
    (Length(Shape.Edges) < FlashFillHitMinEdges) or (Length(Shape.Edges) > FlashFillHitMaxEdges) then
    Exit;
  Replacement := @FFillHits[Low(FFillHits)];
  for var I := Low(FFillHits) to High(FFillHits) do
  begin
    Cache := @FFillHits[I];
    if (Cache.Edges <> nil) and (@Cache.Edges[0] = @Shape.Edges[0]) then
    begin
      Cache.LastUsed := FFrameNumber;
      Exit(Cache);
    end;
    if (Replacement.Edges <> nil) and ((Cache.Edges = nil) or (Cache.LastUsed < Replacement.LastUsed)) then
      Replacement := Cache;
  end;
  Replacement^ := Default(TFlashFillHit);
  Replacement.Edges := Shape.Edges;
  Replacement.LastUsed := FFrameNumber;
  Replacement.MinY := Infinity;
  Replacement.MaxY := NegInfinity;
  for var Edge in Shape.Edges do
  begin
    Replacement.MinY := Min(Replacement.MinY, Min(Edge.Y1, Edge.Y2));
    Replacement.MaxY := Max(Replacement.MaxY, Max(Edge.Y1, Edge.Y2));
  end;
  Result := Replacement;
  if Replacement.MaxY <= Replacement.MinY then
    Exit;
  Replacement.BinScale := FlashFillHitBins / (Replacement.MaxY - Replacement.MinY);
  FillChar(Counts, SizeOf(Counts), 0);
  for var Edge in Shape.Edges do
    if Edge.Y1 <> Edge.Y2 then
    begin
      EdgeBins(Edge);
      for var Bin := First to Last do
        Inc(Counts[Bin]);
    end;
  SetLength(Replacement.Offsets, Length(Counts) + 1);
  for var Bin := 0 to High(Counts) do
  begin
    Replacement.Offsets[Bin + 1] := Replacement.Offsets[Bin] + Counts[Bin];
    Counts[Bin] := Replacement.Offsets[Bin];
  end;
  SetLength(Replacement.Indices, Replacement.Offsets[High(Replacement.Offsets)]);
  for var I := 0 to High(Shape.Edges) do
    if Shape.Edges[I].Y1 <> Shape.Edges[I].Y2 then
    begin
      EdgeBins(Shape.Edges[I]);
      for var Bin := First to Last do
      begin
        Replacement.Indices[Counts[Bin]] := I;
        Inc(Counts[Bin]);
      end;
    end;
end;

function TFlashPlayer.PointInShapeFill(Shape: TSWFCharacter; X, Y: Double; DrawingClip: TFlashClip): Boolean;
var
  local: array[0..31] of Integer;
  Allocated: TArray<Integer>;
  Cache: PFlashFillHit;
  FillCount, Row: Integer;

  function Inside(var Windings: array of Integer): Boolean;
  var
    Edge: TSWFEdge;
    Winding: Integer;

    procedure CountEdge(const Value: TSWFEdge);
    begin
      if (Value.Fill > 0) and (Value.Fill <= FillCount) then
        Inc(Windings[Value.Fill - 1], RayWinding(Value, X, Y));
    end;

    procedure CountBin(Bin: Integer);
    begin
      for var I := Cache.Offsets[Bin] to Cache.Offsets[Bin + 1] - 1 do
        CountEdge(Cache.Edges[Cache.Indices[I]]);
    end;

  begin
    FillChar(Windings[0], FillCount * SizeOf(Integer), 0);
    // Each edge contributes to a single style.
    if Cache <> nil then
    begin
      CountBin(Row);
      CountBin(FlashFillHitBins);
    end
    else
      for Edge in Shape.Edges do
        CountEdge(Edge);
    if (DrawingClip <> nil) and DrawingClip.PendingFillEdge(Edge) and
      (Edge.Fill > 0) and (Edge.Fill <= FillCount) then
      Inc(Windings[Edge.Fill - 1], RayWinding(Edge, X, Y));
    for var I := 0 to FillCount - 1 do
      if not Shape.Fills[I].Stroke then
      begin
        Winding := Windings[I];
        if Shape.EvenOddFills then
          Winding := Winding and 1;
        if Winding <> 0 then
          Exit(True);
      end;
    Result := False;
  end;

begin
  FillCount := Length(Shape.Fills);
  if FillCount = 0 then
    Exit(False);
  Cache := nil;
  if DrawingClip = nil then
    Cache := FindFillHit(Shape);
  if Cache <> nil then
  begin
    if not ((Y >= Cache.MinY) and (Y < Cache.MaxY)) then
      Exit(False);
    Row := FillHitBin(Cache, Y);
  end;
  if FillCount <= Length(local) then
    Exit(Inside(local));
  SetLength(Allocated, FillCount);
  Result := Inside(Allocated);
end;

function TFlashPlayer.ContainsPoint(C: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; HitState, IgnoreVisibility, MaskGeometry, MaskRoot: Boolean; Depth: Integer): Boolean;
var
  Matrix, MaskParent: TSWFMatrix;
  BitmapBounds: TSWFBounds;
  WorldBounds: TSWFRect;
  DrawingClip: TFlashClip;
  Visual: TSWFCharacter;
begin
  Result := False;
  if (Depth >= 256) or C.Dead or C.Removing or (not IgnoreVisibility and not C.Visible) or
    (not MaskRoot and (C.Maskee <> nil)) then
    Exit;
  if C.Masker <> nil then
  begin
    MaskParent := TSWFMatrix.Identity;
    if C.Masker.Parent <> nil then
      MaskParent := WorldMatrix(C.Masker.Parent);
    if not PointInMask(C.Masker, X, Y, MaskParent, Depth + 1) then
      Exit;
  end;
  Matrix := C.Matrix.ThenBy(ParentMatrix);
  if not InScrollViewport(C, X, Y, Matrix) then
    Exit;
  Matrix := C.WithScrollOffset(Matrix);
  BitmapBounds := TSWFBounds.Empty;
  if C.AttachedBitmap <> nil then
  begin
    if not MaskGeometry or (C.AttachedBitmap.Width > 0) then
      BitmapBounds := C.AttachedBitmapBounds;
  end
  else if (C.Character <> nil) and ((C.Character.BitmapWidth > 0) or (C.Character.Video <> nil)) then
    BitmapBounds := C.Character.ShapeBounds;
  if BitmapBounds.Valid and not MaskGeometry then
  begin
    WorldBounds := BitmapBounds.Transformed(Matrix).Rect;
    if (X * 20 >= WorldBounds.Left) and (Y * 20 >= WorldBounds.Top) and
      (X * 20 <= WorldBounds.Right) and (Y * 20 <= WorldBounds.Bottom) then
      Exit(True);
  end;
  var M := Matrix;
  var Det := M.A * M.D - M.B * M.C;
  if Abs(Det) < 1e-12 then
    Exit;
  var PX := X * 20 - M.TX;
  var PY := Y * 20 - M.TY;
  var LX: Double := (M.D * PX - M.C * PY) / Det;
  var LY: Double := (-M.B * PX + M.A * PY) / Det;
  if BitmapBounds.Valid and MaskGeometry then
  begin
    WorldBounds := BitmapBounds.Rect;
    if (LX >= WorldBounds.Left) and (LY >= WorldBounds.Top) and
      (LX < WorldBounds.Right) and (LY < WorldBounds.Bottom) then
      Exit(True);
  end;
  Visual := C.Character;
  if Visual <> nil then
    Visual := Visual.ShapeAt(C.MorphRatio);
  for var Shape in [Visual, C.Drawing] do
    if Shape <> nil then
    begin
      DrawingClip := nil;
      if Shape = C.Drawing then
        DrawingClip := C;
      if PointInShapeFill(Shape, LX, LY, DrawingClip) then
        Exit(True);
      if not MaskGeometry and PointOnStroke(Shape, M, X, Y, DrawingClip) then
        Exit(True);
    end;
  if C.IsText and (LX >= C.TextLeft * 20) and (LY >= C.TextTop * 20) and
    (LX < (C.TextLeft + C.TextWidth) * 20) and (LY < (C.TextTop + C.TextHeight) * 20) then
    Exit(True);
  for var Child in PointChildren(C, X, Y, M, HitState, Depth) do
    if ContainsPoint(Child, X, Y, M, HitState, IgnoreVisibility, MaskGeometry, False, Depth + 1) then
      Exit(True);
end;

procedure TFlashPlayer.RenderStaticText(C: TFlashClip; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
begin
  var Text := C.Character;
  for var RecordValue in Text.TextRecords do
  begin
    var Font: TSWFCharacter;
    if not C.MovieLibrary.Movie.Characters.TryGetValue(RecordValue.FontId, Font) then
      raise ESWFError.Create('Missing static text font');
    var X := RecordValue.X;
    for var G in RecordValue.Glyphs do
    begin
      if (G.Index < 0) or (G.Index >= Font.Glyphs.Count) then
        raise ESWFError.Create('Invalid text glyph index');
      var Scale := RecordValue.Height / 1024.0;
      if Font.Kind = 75 then
        Scale := Scale / 20;
      var GM := TSWFMatrix.Identity;
      GM.A := Scale;
      GM.D := Scale;
      GM.TX := X;
      GM.TY := RecordValue.Y;
      GM := GM.ThenBy(Text.TextMatrix).ThenBy(M);
      RenderShape(Font.Glyphs[G.Index], GM, Opacity, Pixels, RecordValue.Color);
      Inc(X, G.Advance);
    end;
  end;
end;

procedure TFlashPlayer.Broadcast(const Name: string; Flags: Cardinal);
begin
  for var C in FClips.ToArray do
    if not C.Dead and not C.Removing and
      ((Name <> 'onEnterFrame') or (C.CreatedFrame < FFrameNumber)) then
      Fire(C, Name, Flags);
end;

procedure TFlashPlayer.Tick;
var
  Root: TFlashClip;
  MovieLibrary: TFlashLibrary;
  EndMilliseconds: Int64;
begin
  VM.BeginTick;
  VM.Milliseconds := Round(FFrameNumber * 1000 / Movie.FPS);
  for MovieLibrary in FLibraries do
    if MovieLibrary.AVM2 <> nil then
      MovieLibrary.AVM2.BeginFrame(VM.Milliseconds);
  ProcessUnloads(False);
  ProcessLoads;
  FNet.Tick;
  VM.RunTimers;
  if FFrameNumber > 0 then
    Broadcast('onEnterFrame', SWFClipEnterFrame);
  FCollectingAVM2Timeline := True;
  try
    for Root in LevelClips do
      StepClip(Root, True);
  finally
    FCollectingAVM2Timeline := False;
  end;
  BroadcastAVM2FrameEvent(afEnter);
  CompleteAVM2Frame;
  EndMilliseconds := Round((FFrameNumber + 1) * 1000 / Movie.FPS);
  for MovieLibrary in FLibraries.ToArray do
    if (MovieLibrary.AVM2 <> nil) and (MovieLibrary.Root <> nil) and
      (MovieLibrary.Root.MovieLibrary = MovieLibrary) and not MovieLibrary.Root.Dead then
    try
      MovieLibrary.AVM2.RunTimers(EndMilliseconds);
    except
      on E: EAVM2Error do
        raise ESWFError.Create('AVM2 timer: ' + E.Message);
    end;
  FlushActions;
  UpdateDrag;
  Inc(FFrameNumber);
  VM.Collect;
end;

procedure TFlashPlayer.VisitRoots(const Visit: TProc<TAVMObject>);

  procedure VisitClip(C: TFlashClip);
  begin
    if C <> nil then
      Visit(C.Script);
  end;

begin
  VisitClip(FPressed);
  VisitClip(FHovered);
  VisitClip(FTextFocus);
  VisitClip(FDragClip);
  for var C in FClips do
    if not C.Dead or C.HasAVM2Handle then
      Visit(C.Script);
  for var MovieLibrary in FLibraries do
    VisitClip(MovieLibrary.Root);
  FNet.VisitRoots(Visit);
  for var Request in FLoads do
  begin
    Visit(Request.Target.Script);
    Visit(Request.Loader);
    Visit(Request.CallerRoot);
  end;
  for var Pending in FUnloads do
    Visit(Pending.Clip.Script);
  for var Action in FActions do
    Visit(Action.Clip.Script);
  for var Construction in FConstructClips do
    Visit(Construction.Clip.Script);
  for var V in FNativeMethods.Values do
    Visit(V.Obj);
  FAudio.VisitClients(
    procedure(Client: TObject)
    begin
      if Client is TAVMObject then
        Visit(TAVMObject(Client));
    end);
end;

procedure TFlashPlayer.VisitObjectReferences(O: TAVMObject; const Visit: TProc<TAVMObject>);
var
  C: TFlashClip;
begin
  C := Clip(O);
  if C = nil then
    Exit;
  Visit(C.RegisteredConstructor);
  Visit(C.NetStream);
  if C.Parent <> nil then
    Visit(C.Parent.Script);
  if C.DropTarget <> nil then
    Visit(C.DropTarget.Script);
  for var Child in C.Children do
    Visit(Child.Script);
end;

procedure TFlashPlayer.SweepUnreachable;
var
  I: Integer;
  C: TFlashClip;
begin
  // AVM1 still owns the script objects here, including their mark bits.
  for I := FClips.Count - 1 downto 0 do
  begin
    C := FClips[I];
    if C.Dead and not C.Script.Marked then
    begin
      FAudio.StopOwner(C);
      C.Script.HostData := nil;
      FClips.Delete(I);
    end;
  end;
end;

procedure TFlashPlayer.ClearInput;
begin
  FDragClip := nil;
  FillChar(FKeys, SizeOf(FKeys), 0);
  FMouseButtons := 0;
  FMouseValid := False;
  FPressed := nil;
  FHovered := nil;
  FAVM2PointerPressed := nil;
  FAVM2PointerDown := False;
  for var C in FClips do
    C.ButtonState := 0;
end;

procedure TFlashPlayer.FinishInput;
var
  Root: TFlashClip;
begin
  for Root in LevelClips do
    StepClip(Root, False);
  RunAVM2FrameScripts;
  FlushActions;
  UpdateDrag;
end;

procedure TFlashPlayer.Key(Code: Integer; Pressed: Boolean);
var
  Ch: Char;
  Name: string;
  Flags: Cardinal;
  C, Target: TFlashClip;
  ClipAction: TSWFClipAction;
  Action: TSWFButtonAction;
  ButtonCode, CharCode: Integer;
  Runtime: TAVM2Runtime;
begin
  if (Code < 0) or (Code > 255) or (FKeys[Code] = Pressed) then
    Exit;
  FKeys[Code] := Pressed;
  FLastKey := Code;
  VM.BeginTick;
  Runtime := FRoot.MovieLibrary.AVM2;
  if Runtime <> nil then
  begin
    CharCode := 0;
    if Code in [8, 9, 13, 27, 32, 48..57, 65..90] then
      CharCode := Code;
    if (Code in [65..90]) and not FKeys[16] then
      Inc(CharCode, 32);
    Runtime.BeginFrame;
    try
      Runtime.Keyboard(Code, CharCode, Pressed, FKeys[17], FKeys[18], FKeys[16]);
    except
      on E: EAVM2Error do
        raise ESWFError.Create('AVM2 keyboard: ' + E.Message);
    end;
  end;
  if Pressed and (FTextFocus <> nil) and not FTextFocus.Dead then
  begin
    if Code = 8 then
    begin
      if FTextFocus.Text <> '' then
        FTextFocus.Text := Copy(FTextFocus.Text, 1, Length(FTextFocus.Text) - 1);
    end
    else if (Code >= 32) and (Code <= 126) and not FKeys[17] then
    begin
      Ch := Char(Code);
      if (Code >= 65) and (Code <= 90) and not FKeys[16] then
        Ch := Char(Code + 32);
      if Length(FTextFocus.Text) < 1024 then
        FTextFocus.Text := FTextFocus.Text + Ch;
    end;
  end;
  if Pressed then
  begin
    Name := 'onKeyDown';
    Flags := SWFClipKeyDown;
  end
  else
  begin
    Name := 'onKeyUp';
    Flags := SWFClipKeyUp;
  end;
  for C in FClips.ToArray do
    if not C.Dead and not C.Removing then
      for ClipAction in C.ClipActions.ToArray do
        if (ClipAction.Events and Flags) <> 0 then
          RunCode(C, ClipAction.Code);
  AVMBroadcast(VM, VM.Get(VM.Global, 'Key').Obj, Name, nil);
  if Pressed then
  begin
    ButtonCode := Code;
    if (Code >= 65) and (Code <= 90) and not FKeys[16] then
      Inc(ButtonCode, 32);
    case Code of
      37:
        ButtonCode := 1;
      39:
        ButtonCode := 2;
      38:
        ButtonCode := 14;
      40:
        ButtonCode := 15;
      36:
        ButtonCode := 3;
      35:
        ButtonCode := 4;
      45:
        ButtonCode := 5;
      46:
        ButtonCode := 6;
      33:
        ButtonCode := 16;
      34:
        ButtonCode := 17;
      9:
        ButtonCode := 18;
      27:
        ButtonCode := 19;
    end;
    for C in FClips.ToArray do
      if not C.Dead and not C.Removing then
      begin
        for ClipAction in C.ClipActions.ToArray do
          if ((ClipAction.Events and SWFClipKeyPress) <> 0) and
            (ClipAction.KeyCode = ButtonCode) then
            RunCode(C, ClipAction.Code);
        if (C.Character <> nil) and (C.Character.Kind in [7, 34]) then
          for Action in C.Character.ButtonActions do
            if ((Action.Conditions shr 9) and 127) = ButtonCode then
            begin
              Target := C.Parent;
              if Target = nil then
                Target := FRoot;
              RunCode(Target, Action.Code);
            end;
      end;
  end;
  FinishInput;
end;

procedure TFlashPlayer.DispatchAVM2Pointer(X, Y: Integer; Valid: Boolean; Previous, Buttons: Byte);
var
  Runtime: TAVM2Runtime;
  Clip: TFlashClip;
  Target: TAVM2Object;
  StageX, StageY, LocalX, LocalY, DX, DY: Double;
  Matrix: TSWFMatrix;

  procedure Send(const Name: string);
  begin
    Runtime.Mouse(Target, Name, StageX, StageY, LocalX, LocalY, (Buttons and 1) <> 0,
      FKeys[17], FKeys[18], FKeys[16]);
  end;

begin
  Runtime := FRoot.MovieLibrary.AVM2;
  if Runtime = nil then
    Exit;
  if not Valid then
  begin
    FAVM2PointerPressed := nil;
    FAVM2PointerDown := False;
    Exit;
  end;
  StageX := X + Movie.Stage.Left / 20;
  StageY := Y + Movie.Stage.Top / 20;
  Clip := FRoot;
  if FAVM2Stage <> nil then
    Clip := FAVM2Stage;
  Clip := Hit(Clip, StageX, StageY, TSWFMatrix.Identity, False);
  Target := nil;
  while (Clip <> nil) and (Target = nil) do
  begin
    Target := Runtime.DisplayObjectAt(Clip);
    if Target = nil then
      Clip := Clip.Parent;
  end;
  LocalX := StageX;
  LocalY := StageY;
  if (Clip <> nil) and TryPaintInverse(WorldMatrix(Clip, True), Matrix) then
  begin
    DX := StageX - Matrix.TX / 20;
    DY := StageY - Matrix.TY / 20;
    LocalX := Matrix.A * DX + Matrix.C * DY;
    LocalY := Matrix.B * DX + Matrix.D * DY;
  end;
  Runtime.BeginFrame;
  try
    if not FMouseValid or (X <> FMouseX) or (Y <> FMouseY) then
      Send('mouseMove');
    if (Previous and 1) <> (Buttons and 1) then
    begin
      if (Buttons and 1) <> 0 then
      begin
        FAVM2PointerPressed := Target;
        FAVM2PointerDown := True;
        Send('mouseDown');
      end
      else
      begin
        Send('mouseUp');
        if FAVM2PointerDown and (Target = FAVM2PointerPressed) then
          Send('click');
        FAVM2PointerPressed := nil;
        FAVM2PointerDown := False;
      end;
    end;
  except
    on E: EAVM2Error do
      raise ESWFError.Create('AVM2 pointer: ' + E.Message);
  end;
end;

procedure TFlashPlayer.Pointer(X, Y: Integer; Valid: Boolean; Buttons: Byte);
var
  Previous: Byte;
begin
  VM.BeginTick;
  Previous := FMouseButtons;
  FMouseButtons := Buttons;
  DispatchAVM2Pointer(X, Y, Valid, Previous, Buttons);
  if Valid and ((X <> FMouseX) or (Y <> FMouseY)) then
  begin
    FMouseX := X;
    FMouseY := Y;
    Broadcast('onMouseMove', SWFClipMouseMove);
    AVMBroadcast(VM, VM.Get(VM.Global, 'Mouse').Obj, 'onMouseMove', nil);
  end;
  FMouseValid := Valid;
  UpdateDrag;
  var Hovered: TFlashClip := nil;
  if Valid then
    Hovered := HitStage(X, Y);
  if Hovered <> FHovered then
  begin
    if FHovered <> nil then
    begin
      if FHovered = FPressed then
      begin
        FHovered.ButtonState := 3;
        ButtonEvent(FHovered, $10);
        Fire(FHovered, 'onDragOut', SWFClipDragOut);
      end
      else if FDragClip = nil then
      begin
        FHovered.ButtonState := 0;
        ButtonEvent(FHovered, 2);
        Fire(FHovered, 'onRollOut', SWFClipRollOut);
      end;
    end;
    FHovered := Hovered;
    if FHovered <> nil then
    begin
      if FHovered = FPressed then
      begin
        FHovered.ButtonState := 2;
        ButtonEvent(FHovered, $20);
        Fire(FHovered, 'onDragOver', SWFClipDragOver);
      end
      else if FDragClip = nil then
      begin
        FHovered.ButtonState := 1;
        ButtonEvent(FHovered, 1);
        Fire(FHovered, 'onRollOver', SWFClipRollOver);
      end;
    end;
  end;
  if (Buttons and 1) <> (Previous and 1) then
  begin
    if (Buttons and 1) <> 0 then
    begin
      if Valid then
        FPressed := HitStage(X, Y);
      if FPressed <> nil then
      begin
        FPressed.ButtonState := 2;
        ButtonEvent(FPressed, 4);
      end;
      Fire(FPressed, 'onPress', SWFClipPress);
      Broadcast('onMouseDown', SWFClipMouseDown);
      AVMBroadcast(VM, VM.Get(VM.Global, 'Mouse').Obj, 'onMouseDown', nil);
    end
    else
    begin
      Broadcast('onMouseUp', SWFClipMouseUp);
      AVMBroadcast(VM, VM.Get(VM.Global, 'Mouse').Obj, 'onMouseUp', nil);
      if Valid and (FPressed <> nil) and (HitStage(X, Y) = FPressed) then
      begin
        FPressed.ButtonState := 1;
        ButtonEvent(FPressed, 8);
        Fire(FPressed, 'onRelease', SWFClipRelease);
      end
      else
      begin
        if FPressed <> nil then
        begin
          FPressed.ButtonState := 0;
          ButtonEvent(FPressed, $40);
        end;
        Fire(FPressed, 'onReleaseOutside', SWFClipReleaseOutside);
      end;
      FPressed := nil;
    end;
  end;
  FinishInput;
end;

function TFlashPlayer.Hit(C: TFlashClip; X, Y: Double; const ParentMatrix: TSWFMatrix; RequireInteractive: Boolean): TFlashClip;
const
  HandlerNames: array[0..6] of string = ('onPress', 'onRelease', 'onReleaseOutside',
    'onRollOver', 'onRollOut', 'onDragOver', 'onDragOut');
  ButtonFlags = SWFClipPress or SWFClipRelease or SWFClipReleaseOutside or
    SWFClipRollOver or SWFClipRollOut or SWFClipDragOver or SWFClipDragOut;
var
  M, MaskParent: TSWFMatrix;
  Items: TArray<TFlashClip>;
  Child: TFlashClip;
  Enabled: TAVMValue;
  PickParentFirst: Boolean;
  I: Integer;

  function HasButtonHandlers: Boolean;
  begin
    for var Action in C.ClipActions do
      if (Action.Events and ButtonFlags) <> 0 then
        Exit(True);
    if VM.MayHaveEventMember(C.Script, [emButton]) then
      for var Name in HandlerNames do
        if VM.GetSpecial(C.Script, Name).Obj <> nil then
          Exit(True);
    Result := False;
  end;

begin
  Result := nil;
  if C.Dead or C.Removing or not C.Visible or (C.Maskee <> nil) then
    Exit;
  if C.Masker <> nil then
  begin
    MaskParent := TSWFMatrix.Identity;
    if C.Masker.Parent <> nil then
      MaskParent := WorldMatrix(C.Masker.Parent);
    if not PointInMask(C.Masker, X, Y, MaskParent) then
      Exit;
  end;
  M := C.Matrix.ThenBy(ParentMatrix);
  if not InScrollViewport(C, X, Y, M) then
    Exit;
  M := C.WithScrollOffset(M);
  if (C.Character <> nil) and (C.Character.Kind in [7, 34]) then
  begin
    Enabled := VM.Get(C.Script, 'enabled');
    if (Enabled.Kind <> avUndefined) and not Enabled.AsBoolean then
      Exit;
    if ContainsPoint(C, X, Y, ParentMatrix, True) then
      Exit(C);
    Exit;
  end;
  // An AVM1 movie clip with button handlers picks against its whole shape
  // before checking the children for their own handlers.
  PickParentFirst := RequireInteractive and not C.MovieLibrary.Movie.UsesAVM2;
  if PickParentFirst and HasButtonHandlers and ContainsPoint(C, X, Y, ParentMatrix, False) then
    Exit(C);
  Items := PointChildren(C, X, Y, M, False);
  for I := High(Items) downto 0 do
  begin
    Child := Items[I];
    Result := Hit(Child, X, Y, M, RequireInteractive);
    if Result <> nil then
      Exit;
  end;
  if (not RequireInteractive or (not PickParentFirst and HasButtonHandlers)) and
    ContainsPoint(C, X, Y, ParentMatrix, False) then
    Result := C;
end;

// Each 16-bit lane contains a channel product no greater than 255 * 255.
function DivideColorLanesBy255(Value: Cardinal): Cardinal; inline;
begin
  Inc(Value, $00800080);
  Result := ((Value + ((Value shr 8) and $00FF00FF)) shr 8) and $00FF00FF;
end;

procedure Blend(var Pixel: Cardinal; Color: Cardinal; Opacity: Double; WithAlpha: Boolean);
begin
  var A := Integer(Color shr 24);
  if Opacity <> 1 then
    A := EnsureRange(Round(A * Opacity), 0, 255);
  if A = 255 then
  begin
    Pixel := Color or $FF000000;
    Exit;
  end;
  if A = 0 then
  begin
    if not WithAlpha then
      Pixel := Pixel or $FF000000;
    Exit;
  end;
  var Inv := Cardinal(255 - A);
  var RedBlue := DivideColorLanesBy255((Color and $00FF00FF) * Cardinal(A) +
    (Pixel and $00FF00FF) * Inv);
  var Green := (((Color shr 8) and 255) * Cardinal(A) + ((Pixel shr 8) and 255) * Inv + 127) div 255;
  if WithAlpha then
    A := A + Integer(((Pixel shr 24) * Inv + 127) div 255)
  else
    A := 255;
  Pixel := (Cardinal(A) shl 24) or (Green shl 8) or RedBlue;
end;

procedure TFlashPlayer.ConfigureSamples;
const
  SampleCounts: array[TFlashQuality] of Integer = (1, 2, 4, 4, 8, 8, 16, 16);
  Pattern4: array[0..3] of Integer = (1, 3, 0, 2);
  Pattern8: array[0..7] of Integer = (3, 7, 1, 5, 0, 4, 2, 6);
  Pattern16: array[0..15] of Integer = (7, 15, 3, 11, 1, 9, 5, 13, 0, 8, 4, 12, 2, 10, 6, 14);
var
  I, X: Integer;
begin
  FRender.SampleCount := SampleCounts[FRender.Quality];
  FRender.FullCoverage := Word((Cardinal(1) shl FRender.SampleCount) - 1);
  for I := 0 to FRender.SampleCount - 1 do
  begin
    case FRender.SampleCount of
      4:
        X := Pattern4[I];
      8:
        X := Pattern8[I];
      16:
        X := Pattern16[I];
    else
      X := I;
    end;
    FRender.SampleX[I] := (X + 0.5) / FRender.SampleCount;
    FRender.SampleY[I] := (I + 0.5) / FRender.SampleCount;
  end;
end;

function TFlashPlayer.EnsureSampleDetail(Index: Integer; Color: Cardinal): Integer;
var
  Sample, Required: Integer;
begin
  Result := FRender.DetailIndex[Index] - 1;
  if Result >= 0 then
    Exit;
  Result := FRender.DetailPixels.Count * FRender.SampleCount;
  Required := Result + FRender.SampleCount;
  if Required > Length(FRender.DetailColors) then
    SetLength(FRender.DetailColors, Max(Required, Length(FRender.DetailColors) + Max(256, Length(FRender.DetailColors) div 2)));
  for Sample := 0 to FRender.SampleCount - 1 do
    FRender.DetailColors[Result + Sample] := Color;
  FRender.DetailPixels.Add(Index);
  FRender.DetailIndex[Index] := Result + 1;
end;

function TFlashPlayer.CoverageAt(Index: Integer): Word;
var
  SampleBit: Integer;
begin
  if FRender.Coverage = nil then
    Exit(FRender.FullCoverage);
  SampleBit := Index * FRender.SampleCount;
  if FRender.SampleCount = 16 then
    Exit(PWord(@FRender.Coverage[SampleBit shr 3])^);
  Result := (FRender.Coverage[SampleBit shr 3] shr (SampleBit and 7)) and FRender.FullCoverage;
end;

procedure TFlashPlayer.PlotPixel(Index: Integer; Color: Cardinal; Opacity: Double; var Pixels: TArray<Cardinal>; Coverage: Word);
var
  SampleBit, ByteIndex, Shift, Detail, Sample: Integer;
begin
  if (FRender.Coverage <> nil) or (FRender.MaskOutput <> nil) then
  begin
    // Masks store the same sample pattern used by the paint pass.
    SampleBit := Index * FRender.SampleCount;
    ByteIndex := SampleBit shr 3;
    Shift := SampleBit and 7;
    if FRender.SampleCount = 16 then
    begin
      if FRender.Coverage <> nil then
        Coverage := Coverage and PWord(@FRender.Coverage[ByteIndex])^;
      if FRender.MaskOutput <> nil then
      begin
        PWord(@FRender.MaskOutput[ByteIndex])^ := PWord(@FRender.MaskOutput[ByteIndex])^ or Coverage;
        Exit;
      end;
    end
    else
    begin
      if FRender.Coverage <> nil then
        Coverage := Coverage and (FRender.Coverage[ByteIndex] shr Shift);
      if FRender.MaskOutput <> nil then
      begin
        FRender.MaskOutput[ByteIndex] := FRender.MaskOutput[ByteIndex] or Byte(Coverage shl Shift);
        Exit;
      end;
    end;
    if Coverage = 0 then
      Exit;
  end;
  if (Color shr 24 = 0) or (Opacity <= 0) then
    Exit;
  if FRender.SampleCount = 1 then
  begin
    Blend(Pixels[Index], Color, Opacity, FRender.WithAlpha);
    Exit;
  end;
  Detail := FRender.DetailIndex[Index] - 1;
  if (Coverage = FRender.FullCoverage) and (Detail < 0) then
  begin
    Blend(Pixels[Index], Color, Opacity, FRender.WithAlpha);
    Exit;
  end;
  Inc(FRender.Work, FRender.SampleCount);
  if FRender.Work > FlashRenderWorkLimit then
    raise ESWFError.Create('Flash frame rendering work limit');
  if Detail < 0 then
    Detail := EnsureSampleDetail(Index, Pixels[Index]);
  if (Color shr 24 = 255) and (Opacity = 1) then
  begin
    for Sample := 0 to FRender.SampleCount - 1 do
      if Coverage and (Word(1) shl Sample) <> 0 then
        FRender.DetailColors[Detail + Sample] := Color;
  end
  else
    for Sample := 0 to FRender.SampleCount - 1 do
      if Coverage and (Word(1) shl Sample) <> 0 then
        Blend(FRender.DetailColors[Detail + Sample], Color, Opacity, FRender.WithAlpha);
end;

type
  TFlashBilinearAxis = record
    First, Next: Integer;
    Fraction: Double;
  end;

  TFlashBitmapSampler = record
    Width, Height: Integer;
    Pixels: TArray<Cardinal>;
    Inverse: TSWFMatrix;
    RepeatPixels, Smooth, Premultiplied: Boolean;
    function Initialize(ImageWidth, ImageHeight: Integer; const ImagePixels: TArray<Cardinal>; const TextureToFrame: TSWFMatrix; RepeatTexture, SmoothTexture, PremultipliedTexture: Boolean): Boolean;
    procedure Locate(X, Y: Double; out U, V: Double);
    function Coordinate(Value: Double; Extent: Integer): Double;
    function NearestIndex(Value: Double; Extent: Integer): Integer;
    function BilinearAxis(Value: Double; Extent: Integer): TFlashBilinearAxis;
    function BilinearColor(const X, Y: TFlashBilinearAxis): Cardinal;
    function ColorAt(U, V: Double): Cardinal;
  end;

function TryPaintInverse(const PaintToFrame: TSWFMatrix; out Inverse: TSWFMatrix): Boolean;
var
  Determinant: Double;
begin
  Determinant := PaintToFrame.A * PaintToFrame.D - PaintToFrame.B * PaintToFrame.C;
  if (Determinant = 0) or IsNan(Determinant) or IsInfinite(Determinant) then
    Exit(False);
  Inverse.A := PaintToFrame.D / Determinant;
  Inverse.B := -PaintToFrame.B / Determinant;
  Inverse.C := -PaintToFrame.C / Determinant;
  Inverse.D := PaintToFrame.A / Determinant;
  // Keep the origin separate to preserve fractional coordinates.
  Inverse.TX := PaintToFrame.TX;
  Inverse.TY := PaintToFrame.TY;
  Result := True;
end;

procedure LocatePaint(const Inverse: TSWFMatrix; X, Y: Double; out U, V: Double);
begin
  X := X - Inverse.TX;
  Y := Y - Inverse.TY;
  U := Inverse.A * X + Inverse.C * Y;
  V := Inverse.B * X + Inverse.D * Y;
end;

function TFlashBitmapSampler.Initialize(ImageWidth, ImageHeight: Integer; const ImagePixels: TArray<Cardinal>; const TextureToFrame: TSWFMatrix; RepeatTexture, SmoothTexture, PremultipliedTexture: Boolean): Boolean;
begin
  if (ImageWidth <= 0) or (ImageHeight <= 0) or
    (Length(ImagePixels) <> Int64(ImageWidth) * ImageHeight) then
    Exit(False);
  Width := ImageWidth;
  Height := ImageHeight;
  Pixels := ImagePixels;
  RepeatPixels := RepeatTexture;
  Smooth := SmoothTexture;
  Premultiplied := PremultipliedTexture;
  Result := TryPaintInverse(TextureToFrame, Inverse);
end;

procedure TFlashBitmapSampler.Locate(X, Y: Double; out U, V: Double);
begin
  LocatePaint(Inverse, X, Y, U, V);
end;

function TFlashBitmapSampler.Coordinate(Value: Double; Extent: Integer): Double;
begin
  if not RepeatPixels then
    Exit(EnsureRange(Value, 0.0, Double(Extent)));
  if Abs(Value) < 4503599627370496.0 then
    Result := Value - Int(Value / Extent) * Extent
  else
    Result := AVMBinaryNumber($3F, Value, Extent);
  if Result < 0 then
    Result := Result + Extent;
  if Result >= Extent then
    Result := 0;
end;

function TFlashBitmapSampler.NearestIndex(Value: Double; Extent: Integer): Integer;
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit(-1);
  Result := Min(Floor(Coordinate(Value, Extent)), Extent - 1);
end;

function StraightBitmapSample(Color: Cardinal): Cardinal; inline;
var
  Alpha: Cardinal;
begin
  Alpha := Color shr 24;
  if Alpha = 0 then
    Exit(0);
  if Alpha = 255 then
    Exit(Color);
  Result := (Alpha shl 24) or
    (Cardinal(Min(255, Round(((Color shr 16) and 255) * 255.0 / Alpha))) shl 16) or
    (Cardinal(Min(255, Round(((Color shr 8) and 255) * 255.0 / Alpha))) shl 8) or
    Cardinal(Min(255, Round((Color and 255) * 255.0 / Alpha)));
end;

function TFlashBitmapSampler.BilinearAxis(Value: Double; Extent: Integer): TFlashBilinearAxis;
var
  Index: Integer;
begin
  Result := Default(TFlashBilinearAxis);
  if IsNan(Value) or IsInfinite(Value) then
  begin
    Result.First := -1;
    Exit;
  end;
  Value := Coordinate(Value, Extent);
  Value := Value - 0.5;
  Index := Floor(Value);
  Result.Fraction := Value - Index;
  if RepeatPixels then
  begin
    Result.First := Index;
    Result.Next := Index + 1;
    if Index < 0 then
      Result.First := Extent - 1;
    if Result.Next = Extent then
      Result.Next := 0;
  end
  else
  begin
    Result.First := Max(0, Index);
    Result.Next := Min(Index + 1, Extent - 1);
  end;
end;

function TFlashBitmapSampler.BilinearColor(const X, Y: TFlashBilinearAxis): Cardinal;
var
  Top, Bottom: Integer;
  A, B, C, D: Cardinal;
  FX, FY, Alpha, Red, Green, Blue: Double;

  procedure Add(Color: Cardinal; Weight: Double);
  var
    ColorWeight: Double;
  begin
    Alpha := Alpha + Weight * (Color shr 24);
    if Premultiplied then
      ColorWeight := Weight * 255
    else
      ColorWeight := Weight * (Color shr 24);
    Red := Red + ((Color shr 16) and 255) * ColorWeight;
    Green := Green + ((Color shr 8) and 255) * ColorWeight;
    Blue := Blue + (Color and 255) * ColorWeight;
  end;

begin
  if (X.First < 0) or (Y.First < 0) then
    Exit(0);
  Top := Y.First * Width;
  Bottom := Y.Next * Width;
  A := Pixels[Top + X.First];
  B := Pixels[Top + X.Next];
  C := Pixels[Bottom + X.First];
  D := Pixels[Bottom + X.Next];
  if ((A = 0) or (A shr 24 = 255)) and (A = B) and (A = C) and (A = D) then
    Exit(A);
  // Filter in premultiplied space before applying the display transform.
  FX := X.Fraction;
  FY := Y.Fraction;
  Alpha := 0;
  Red := 0;
  Green := 0;
  Blue := 0;
  Add(A, (1 - FX) * (1 - FY));
  Add(B, FX * (1 - FY));
  Add(C, (1 - FX) * FY);
  Add(D, FX * FY);
  if Alpha < 0.5 then
    Exit(0);
  Result := (Cardinal(Round(Alpha)) shl 24) or (Cardinal(Min(255, Round(Red / Alpha))) shl 16) or
    (Cardinal(Min(255, Round(Green / Alpha))) shl 8) or Cardinal(Min(255, Round(Blue / Alpha)));
end;

function TFlashBitmapSampler.ColorAt(U, V: Double): Cardinal;
var
  X, Y: Integer;
begin
  if Smooth then
    Exit(BilinearColor(BilinearAxis(U, Width), BilinearAxis(V, Height)));
  X := NearestIndex(U, Width);
  Y := NearestIndex(V, Height);
  if (X < 0) or (Y < 0) then
    Exit(0);
  Result := Pixels[Y * Width + X];
  if Premultiplied then
    Result := StraightBitmapSample(Result);
end;

function BitmapToFrame(const Matrix: TSWFMatrix; const Stage: TSWFRect): TSWFMatrix;
begin
  Result.A := Matrix.A / 20;
  Result.B := Matrix.B / 20;
  Result.C := Matrix.C / 20;
  Result.D := Matrix.D / 20;
  Result.TX := (Matrix.TX - Stage.Left) / 20;
  Result.TY := (Matrix.TY - Stage.Top) / 20;
end;

function ShapePaintToFrame(const FillMatrix, ShapeMatrix: TSWFMatrix; const Stage: TSWFRect): TSWFMatrix;
var
  Transform: TSWFMatrix;
begin
  // Unlike a display-list matrix, the shader's texture transform retains
  // the fractional translation produced by combining these matrices.
  Transform.A := ShapeMatrix.A * FillMatrix.A + ShapeMatrix.C * FillMatrix.B;
  Transform.B := ShapeMatrix.B * FillMatrix.A + ShapeMatrix.D * FillMatrix.B;
  Transform.C := ShapeMatrix.A * FillMatrix.C + ShapeMatrix.C * FillMatrix.D;
  Transform.D := ShapeMatrix.B * FillMatrix.C + ShapeMatrix.D * FillMatrix.D;
  Transform.TX := ShapeMatrix.A * FillMatrix.TX + ShapeMatrix.C * FillMatrix.TY + ShapeMatrix.TX;
  Transform.TY := ShapeMatrix.B * FillMatrix.TX + ShapeMatrix.D * FillMatrix.TY + ShapeMatrix.TY;
  Result := BitmapToFrame(Transform, Stage);
end;

type
  TFlashGradientSampler = record
    Inverse: TSWFMatrix;
    Gradient: TSWFGradient;
    Focal: Double;
    Mapped: Boolean;
    procedure Initialize(const Style: TSWFGradient; const ShapeMatrix: TSWFMatrix; const Stage: TSWFRect);
    function ColorAt(X, Y: Double): Cardinal;
  end;

procedure TFlashGradientSampler.Initialize(const Style: TSWFGradient; const ShapeMatrix: TSWFMatrix; const Stage: TSWFRect);
begin
  Gradient := Style;
  Focal := EnsureRange(Style.Focal, -0.9999, 0.9999);
  Mapped := TryPaintInverse(ShapePaintToFrame(Style.Matrix, ShapeMatrix, Stage), Inverse);
end;

function GradientLinearComponent(Value: Double): Double;
begin
  Value := Value / 255;
  if Value <= 0.04045 then
    Result := Value / 12.92
  else
    Result := Power((Value + 0.055) / 1.055, 2.4);
end;

function GradientSRGBComponent(Value: Double): Double;
begin
  if Value <= 0.0031308 then
    Result := 12.92 * Value * 255
  else
    Result := (1.055 * Power(Value, 1 / 2.4) - 0.055) * 255;
end;

function TFlashGradientSampler.ColorAt(X, Y: Double): Cardinal;
const
  GradientRadius = 16384.0;
var
  U, V, Distance, Ratio, Fraction: Double;
  Lower, Upper: TSWFGradientStop;
  I: Integer;

  function Channel(Shift: Integer): Cardinal;
  var
    A, B, Value: Double;
  begin
    A := (Lower.Color shr Shift) and 255;
    B := (Upper.Color shr Shift) and 255;
    if Gradient.LinearRGB and (Shift <> 24) then
    begin
      A := GradientLinearComponent(A);
      B := GradientLinearComponent(B);
      Value := GradientSRGBComponent(A + (B - A) * Fraction);
    end
    else
      Value := A + (B - A) * Fraction;
    Result := Round(Value);
  end;

begin
  if Length(Gradient.Stops) = 0 then
    Exit(0);
  Lower := Gradient.Stops[0];
  if (Length(Gradient.Stops) = 1) or not Mapped then
    Exit(Lower.Color);

  LocatePaint(Inverse, X, Y, U, V);
  U := U / GradientRadius;
  V := V / GradientRadius;
  case Gradient.Kind of
    sgLinear:
      Ratio := (U + 1) / 2;
    sgRadial:
      Ratio := Hypot(U, V);
  else
    U := Focal - U;
    Distance := Hypot(U, V);
    if Distance = 0 then
      Ratio := 0
    else
      Ratio := Distance / (Sqrt(1 - Sqr(Focal * V / Distance)) + Focal * U / Distance);
  end;
  if IsNan(Ratio) then
    Exit(Lower.Color);
  if IsInfinite(Ratio) then
  begin
    if Ratio < 0 then
      Exit(Lower.Color);
    Exit(Gradient.Stops[High(Gradient.Stops)].Color);
  end;
  case Gradient.Spread of
    gsReflect:
      Ratio := 1 - Abs(1 - 2 * Frac(Abs(Ratio) / 2));
    gsRepeat:
      begin
        Ratio := Frac(Ratio);
        if Ratio < 0 then
          Ratio := Ratio + 1;
      end;
  end;
  Ratio := Ratio * 255;
  if Ratio < Lower.Ratio then
    Exit(Lower.Color);
  for I := 1 to High(Gradient.Stops) do
  begin
    Upper := Gradient.Stops[I];
    if Ratio < Upper.Ratio then
    begin
      Fraction := (Ratio - Lower.Ratio) / (Upper.Ratio - Lower.Ratio);
      Exit((Channel(24) shl 24) or (Channel(16) shl 16) or
        (Channel(8) shl 8) or Channel(0));
    end;
    Lower := Upper;
  end;
  Result := Lower.Color;
end;

function HasPaintColorTransform(const Color: TSWFColorTransform): Boolean;
begin
  for var I := 0 to 3 do
    if (Color.Mult[I] <> 1) or (Color.Add[I] <> 0) then
      Exit(True);
  Result := False;
end;

procedure TFlashPlayer.RenderBitmap(Width, Height: Integer; const ImagePixels: TArray<Cardinal>; const Matrix: TSWFMatrix; Smooth, Premultiplied: Boolean; Opacity: Double; var Pixels: TArray<Cardinal>; SnapPixels, SourceOpaque: Boolean);
var
  Transform: TSWFMatrix;
  Sampler: TFlashBitmapSampler;
  X, Y, I, Left, Right, Top, Bottom: Integer;
  XCorner, YCorner, U, V, MinX, MaxX, MinY, MaxY, MinU, MaxU, MinV, MaxV, DU, DV: Double;
  SampleU, SampleV: array[0..15] of Double;
  Coverage: Word;
  TransformPaint, AxisAligned: Boolean;
  Horizontal: TArray<TFlashBilinearAxis>;
  Vertical: TFlashBilinearAxis;
  Centers: TArray<Double>;

  function Snap(Value: Double): Double;
  begin
    if Value >= 0 then
      Result := Int(Value + 0.5)
    else
      Result := -Int(0.5 - Value);
  end;

  procedure PaintPixel(Index: Integer; PixelColor: Cardinal; Samples: Word);
  begin
    if PixelColor shr 24 = 0 then
      Exit;
    if TransformPaint then
      PixelColor := FRender.Color.Apply(PixelColor);
    PlotPixel(Index, PixelColor, Opacity, Pixels, Samples);
  end;

  procedure PaintUnscaled(OriginX, OriginY: Integer);
  var
    SourceRow, DestRow, RowBytes: Integer;
    PixelColor: Cardinal;
  begin
    if (Opacity = 1) and not TransformPaint and (FRender.Coverage = nil) and
      ((FRender.DetailPixels = nil) or (FRender.DetailPixels.Count = 0)) then
    begin
      if SourceOpaque then
      begin
        RowBytes := (Right - Left) * SizeOf(Cardinal);
        for var Row := Top to Bottom - 1 do
          Move(ImagePixels[(Row - OriginY) * Width + Left - OriginX],
            Pixels[Row * FRender.Width + Left], RowBytes);
      end
      else
        for var Row := Top to Bottom - 1 do
        begin
          SourceRow := (Row - OriginY) * Width - OriginX;
          DestRow := Row * FRender.Width;
          for var Column := Left to Right - 1 do
          begin
            PixelColor := ImagePixels[SourceRow + Column];
            case PixelColor shr 24 of
              0:
                ;
              255:
                Pixels[DestRow + Column] := PixelColor;
            else
              if Premultiplied then
                PixelColor := StraightBitmapSample(PixelColor);
              Blend(Pixels[DestRow + Column], PixelColor, 1, FRender.WithAlpha);
            end;
          end;
        end;
      Exit;
    end;
    for var Row := Top to Bottom - 1 do
    begin
      SourceRow := (Row - OriginY) * Width - OriginX;
      DestRow := Row * FRender.Width;
      for var Column := Left to Right - 1 do
      begin
        PixelColor := ImagePixels[SourceRow + Column];
        // The samples lie inside the pixel and the filter is centered on its texel.
        if Premultiplied and (PixelColor shr 24 <> 255) and (PixelColor shr 24 <> 0) then
          PixelColor := StraightBitmapSample(PixelColor);
        PaintPixel(DestRow + Column, PixelColor, FRender.FullCoverage);
      end;
    end;
  end;

begin
  Transform := BitmapToFrame(Matrix, FRender.Stage);
  Transform.A := Matrix.A;
  Transform.B := Matrix.B;
  Transform.C := Matrix.C;
  Transform.D := Matrix.D;
  // Both authored and attached bitmaps use auto pixel snapping.
  if SnapPixels and (Transform.B = 0) and (Transform.C = 0) and
    (Matrix.A >= 0.999) and (Matrix.A <= 1.001) and (Matrix.D >= 0.999) and (Matrix.D <= 1.001) then
  begin
    Transform.A := 1;
    Transform.D := 1;
    Transform.TX := Snap(Transform.TX);
    Transform.TY := Snap(Transform.TY);
  end;
  if not Sampler.Initialize(Width, Height, ImagePixels, Transform, False,
    Smooth and ((FRender.Quality <> fqLow) or not SnapPixels), Premultiplied) then
    Exit;
  MinX := Transform.TX;
  MaxX := MinX;
  MinY := Transform.TY;
  MaxY := MinY;
  for I := 1 to 3 do
  begin
    XCorner := 0;
    YCorner := 0;
    if (I and 1) <> 0 then
      XCorner := Width;
    if (I and 2) <> 0 then
      YCorner := Height;
    U := Transform.TX + Transform.A * XCorner + Transform.C * YCorner;
    V := Transform.TY + Transform.B * XCorner + Transform.D * YCorner;
    MinX := Min(MinX, U);
    MaxX := Max(MaxX, U);
    MinY := Min(MinY, V);
    MaxY := Max(MaxY, V);
  end;
  Left := Ceil(EnsureRange(MinX - FRender.SampleY[FRender.SampleCount - 1], 0.0, Double(FRender.Width)));
  Right := Ceil(EnsureRange(MaxX - FRender.SampleY[0], 0.0, Double(FRender.Width)));
  Top := Ceil(EnsureRange(MinY - FRender.SampleY[FRender.SampleCount - 1], 0.0, Double(FRender.Height)));
  Bottom := Ceil(EnsureRange(MaxY - FRender.SampleY[0], 0.0, Double(FRender.Height)));
  Inc(FRender.Work, Int64(Right - Left) * (Bottom - Top));
  if FRender.Work > FlashRenderWorkLimit then
    raise ESWFError.Create('Flash frame rendering work limit');
  if (Right <= Left) or (Bottom <= Top) then
    Exit;

  TransformPaint := HasPaintColorTransform(FRender.Color);
  if (FRender.MaskOutput = nil) and (Transform.A = 1) and (Transform.D = 1) and
    (Transform.B = 0) and (Transform.C = 0) and (Frac(Transform.TX) = 0) and (Frac(Transform.TY) = 0) then
  begin
    PaintUnscaled(Trunc(Transform.TX), Trunc(Transform.TY));
    Exit;
  end;

  MinU := 0;
  MaxU := 0;
  MinV := 0;
  MaxV := 0;
  for I := 0 to FRender.SampleCount - 1 do
  begin
    DU := FRender.SampleX[I] - 0.5;
    DV := FRender.SampleY[I] - 0.5;
    SampleU[I] := Sampler.Inverse.A * DU + Sampler.Inverse.C * DV;
    SampleV[I] := Sampler.Inverse.B * DU + Sampler.Inverse.D * DV;
    MinU := Min(MinU, SampleU[I]);
    MaxU := Max(MaxU, SampleU[I]);
    MinV := Min(MinV, SampleV[I]);
    MaxV := Max(MaxV, SampleV[I]);
  end;
  AxisAligned := Sampler.Smooth and (FRender.MaskOutput = nil) and
    (Sampler.Inverse.B = 0) and (Sampler.Inverse.C = 0);
  if AxisAligned then
  begin
    // Each column and row has the same source coordinates throughout the bitmap.
    SetLength(Horizontal, Right - Left);
    SetLength(Centers, Right - Left);
    for X := Left to Right - 1 do
    begin
      Sampler.Locate(X + 0.5, 0.5, U, V);
      Centers[X - Left] := U;
      Horizontal[X - Left] := Sampler.BilinearAxis(U, Width);
    end;
  end;
  for Y := Top to Bottom - 1 do
  begin
    if AxisAligned then
    begin
      Sampler.Locate(0.5, Y + 0.5, U, V);
      Vertical := Sampler.BilinearAxis(V, Height);
    end;
    for X := Left to Right - 1 do
    begin
      if AxisAligned then
        U := Centers[X - Left]
      else
        Sampler.Locate(X + 0.5, Y + 0.5, U, V);
      if (U + MaxU < 0) or (U + MinU >= Width) or (V + MaxV < 0) or (V + MinV >= Height) then
        Continue;
      Coverage := FRender.FullCoverage;
      if (U + MinU < 0) or (U + MaxU >= Width) or (V + MinV < 0) or (V + MaxV >= Height) then
      begin
        Inc(FRender.Work, FRender.SampleCount);
        if FRender.Work > FlashRenderWorkLimit then
          raise ESWFError.Create('Flash frame rendering work limit');
        Coverage := 0;
        for I := 0 to FRender.SampleCount - 1 do
        begin
          DU := U + SampleU[I];
          DV := V + SampleV[I];
          if (DU >= 0) and (DV >= 0) and (DU < Width) and (DV < Height) then
            Coverage := Coverage or (Word(1) shl I);
        end;
        if Coverage = 0 then
          Continue;
      end;
      if FRender.MaskOutput <> nil then
        PlotPixel(Y * FRender.Width + X, 0, Opacity, Pixels, Coverage)
      else if AxisAligned then
        PaintPixel(Y * FRender.Width + X, Sampler.BilinearColor(Horizontal[X - Left], Vertical), Coverage)
      else
        PaintPixel(Y * FRender.Width + X, Sampler.ColorAt(U, V), Coverage);
    end;
  end;
end;

function TFlashPlayer.FindShapeRaster(Shape: TSWFCharacter; const Matrix: TSWFMatrix; Glyph: Boolean): PFlashShapeRaster;
var
  Raster, Replacement: PFlashShapeRaster;
  TX, TY: UInt64;
  Hash: NativeUInt;
  Bucket: Integer;
begin
  Result := nil;
  // Keep authored geometry alive while its address is used as a key.
  if (FRender.MaskOutput <> nil) or (not Glyph and not (Shape.Kind in [2, 22, 32, 83])) or
    (Length(Shape.Edges) < FlashCachedShapeMinEdges) or (Length(Shape.Fills) = 0) or
    (Length(Shape.Fills) > FlashCachedShapeStyleLimit) then
    Exit;
  Hash := NativeUInt(@Shape.Fills[0]) shr 4;
  Move(Matrix.TX, TX, SizeOf(TX));
  Move(Matrix.TY, TY, SizeOf(TY));
  Hash := Hash xor (Hash shr 7) xor NativeUInt(TX shr 36) xor NativeUInt(TY shr 39);
  Bucket := Integer(Hash and (Length(FShapeRasters) div FlashCachedShapeWays - 1)) * FlashCachedShapeWays;
  Replacement := @FShapeRasters[Bucket];
  for var I := Bucket to Bucket + FlashCachedShapeWays - 1 do
  begin
    Raster := @FShapeRasters[I];
    if (Raster.Fills <> nil) and (@Raster.Fills[0] = @Shape.Fills[0]) and
      (Raster.Quality = FRender.Quality) and (Raster.Width = FRender.Width) and
      (Raster.Height = FRender.Height) and CompareMem(@Raster.Stage, @FRender.Stage, SizeOf(FRender.Stage)) and
      CompareMem(@Raster.Matrix, @Matrix, SizeOf(Matrix)) then
    begin
      Raster.LastUsed := FFrameNumber;
      if not Raster.TooManySpans then
        Result := Raster;
      Exit;
    end;
    if (Replacement.Fills <> nil) and ((Raster.Fills = nil) or (Raster.LastUsed < Replacement.LastUsed)) then
      Replacement := Raster;
  end;
  // Wait for a repeated placement before collecting spans.
  Dec(FShapeRasterSpanCount, Length(Replacement.Spans));
  Replacement^ := Default(TFlashShapeRaster);
  Replacement.Fills := Shape.Fills;
  Replacement.Matrix := Matrix;
  Replacement.Stage := FRender.Stage;
  Replacement.Width := FRender.Width;
  Replacement.Height := FRender.Height;
  Replacement.Quality := FRender.Quality;
  Replacement.LastUsed := FFrameNumber;
end;

procedure TFlashPlayer.RenderShape(Shape: TSWFCharacter; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>; ColorOverride: Int64; LibraryMovie: TSWFMovie; DrawingClip: TFlashClip);
type
  TCross = record
    X: Double;
    Winding: Integer;
  end;

  TScanEdge = record
    Edge: TSWFEdge;
    FirstRow, EndRow, Winding: Integer;
    MinY, MaxY: Double;
  end;

  TStyleGeometry = record
    FirstEdge, FirstStroke: Integer;
  end;
var
  ScanEdges: TList<TScanEdge>;
  SortedEdges: TArray<TScanEdge>;
  Active: TArray<Integer>;
  ActiveCount: Integer;
  Crossings: TArray<TCross>;
  CrossOrder: IComparer<TCross>;
  EdgeOrder: IComparer<TScanEdge>;
  Transitions: TArray<Word>;
  GeometryByStyle: TArray<TStyleGeometry>;
  NextEdge, NextStroke: TArray<Integer>;
  FirstX, EndX, BoundaryCount: Integer;
  Boundaries: array[0..15] of Integer;
  StrokeEdges: TList<TSWFEdge>;
  ShapeToFrame, TextureToFrame: TSWFMatrix;
  Sampler: TFlashBitmapSampler;
  GradientSampler: TFlashGradientSampler;
  Bitmap: TSWFCharacter;
  Style: TSWFFill;
  Fill, StrokeIndex: Integer;
  FlatColor: Cardinal;
  Textured, NearestTexture, Graded, GradientByRow, MonotoneGradient, TransformPaint: Boolean;
  TextureColumns: TArray<Integer>;
  SmoothColumns: TArray<TFlashBilinearAxis>;
  SmoothRow: TFlashBilinearAxis;
  AxisTexture: Boolean;
  TextureSamples: PFlashTextureSamples;
  TextureLeft, TextureRight, TextureY, TextureRow: Integer;
  HasClosing, HasPending: Boolean;
  Closing: TSWFEdge;
  Pending: TSWFStrokePath;
  Raster: PFlashShapeRaster;
  ReplayRaster: Boolean;
  CapturedSpans: TList<TFlashRasterSpan>;
  StyleOffsets: TArray<Integer>;

  procedure Charge(Work: Int64);
  begin
    Inc(FRender.Work, Work);
    if FRender.Work > FlashRenderWorkLimit then
      raise ESWFError.Create('Flash frame rendering work limit');
  end;

  procedure IndexGeometry;
  var
    I, StyleIndex: Integer;
  begin
    // Charge for building and traversing the index before allocating it.
    Charge(Length(Shape.Fills) + 2 * (Int64(Length(Shape.Edges)) + Length(Shape.StrokePaths)));
    SetLength(GeometryByStyle, Length(Shape.Fills));
    SetLength(NextEdge, Length(Shape.Edges));
    SetLength(NextStroke, Length(Shape.StrokePaths));
    // Use one-based links with zero as the terminator. Prepending in reverse
    // keeps the original edge and stroke order within each style.
    for I := High(Shape.Edges) downto 0 do
    begin
      StyleIndex := Shape.Edges[I].Fill;
      if (StyleIndex < 1) or (StyleIndex > Length(GeometryByStyle)) then
        Continue;
      Dec(StyleIndex);
      NextEdge[I] := GeometryByStyle[StyleIndex].FirstEdge;
      GeometryByStyle[StyleIndex].FirstEdge := I + 1;
    end;
    for I := High(Shape.StrokePaths) downto 0 do
    begin
      StyleIndex := Shape.StrokePaths[I].Fill;
      if (StyleIndex < 1) or (StyleIndex > Length(GeometryByStyle)) then
        Continue;
      Dec(StyleIndex);
      NextStroke[I] := GeometryByStyle[StyleIndex].FirstStroke;
      GeometryByStyle[StyleIndex].FirstStroke := I + 1;
    end;
  end;

  procedure AddEdge(const E: TSWFEdge);
  var
    Entry: TScanEdge;
  begin
    if IsNan(E.X1) or IsNan(E.Y1) or IsNan(E.X2) or IsNan(E.Y2) or
      IsInfinite(E.X1) or IsInfinite(E.Y1) or IsInfinite(E.X2) or IsInfinite(E.Y2) then
      Exit;
    Entry.MinY := Min(E.Y1, E.Y2);
    Entry.MaxY := Max(E.Y1, E.Y2);
    if Entry.MinY = Entry.MaxY then
      Exit;
    Entry.FirstRow := Ceil(EnsureRange(Entry.MinY - FRender.SampleY[FRender.SampleCount - 1], 0.0, Double(FRender.Height)));
    Entry.EndRow := Ceil(EnsureRange(Entry.MaxY - FRender.SampleY[0], 0.0, Double(FRender.Height)));
    if Entry.FirstRow >= Entry.EndRow then
      Exit;
    Entry.Edge := E;
    if E.Y2 > E.Y1 then
      Entry.Winding := 1
    else
      Entry.Winding := -1;
    ScanEdges.Add(Entry);
  end;

  procedure PaintSolidSpan(First, Stop: Integer; Color: Cardinal; Coverage: Word);
  var
    Index: Integer;
  begin
    if (Coverage = FRender.FullCoverage) and (FRender.Coverage = nil) and (FRender.MaskOutput = nil) then
    begin
      if (Color shr 24 = 255) and (Opacity = 1) then
      begin
        if (FRender.DetailPixels = nil) or (FRender.DetailPixels.Count = 0) then
          for Index := First to Stop - 1 do
            Pixels[Index] := Color
        else
          for Index := First to Stop - 1 do
            if FRender.DetailIndex[Index] = 0 then
              Pixels[Index] := Color
            else
              PlotPixel(Index, Color, Opacity, Pixels, Coverage);
        Exit;
      end;
      if FRender.SampleCount = 1 then
      begin
        for Index := First to Stop - 1 do
          Blend(Pixels[Index], Color, Opacity, FRender.WithAlpha);
        Exit;
      end;
    end;
    for Index := First to Stop - 1 do
      PlotPixel(Index, Color, Opacity, Pixels, Coverage);
  end;

  procedure CaptureSpan(Y, X0, XEnd: Integer; Coverage: Word);
  var
    Span: TFlashRasterSpan;
  begin
    if (CapturedSpans.Count >= FlashCachedShapeSpanLimit) or
      (CapturedSpans.Count >= FlashCachedShapeTotalSpans - FShapeRasterSpanCount) then
    begin
      Raster.TooManySpans := True;
      FreeAndNil(CapturedSpans);
      Exit;
    end;
    Span.Y := Y;
    Span.Left := X0;
    Span.Right := XEnd;
    Span.Coverage := Coverage;
    CapturedSpans.Add(Span);
  end;

  function FindTextureSamples: PFlashTextureSamples;
  var
    Cache, Replacement: PFlashTextureSamples;
    ScreenPixels: Int64;
    Version: UInt64;
  begin
    Result := nil;
    ScreenPixels := Int64(FRender.Width) * FRender.Height;
    if FRender.WithAlpha or not Sampler.Smooth or
      (Length(Sampler.Pixels) < FlashTextureCacheMinSourcePixels) or
      (Length(Sampler.Pixels) > FlashTextureCacheMaxSourcePixels) or
      (ScreenPixels > FlashTextureCacheMaxTargetPixels) then
      Exit;
    Version := 0;
    if Style.BitmapData <> nil then
      Version := Style.BitmapData.ContentVersion;
    Inc(FTextureSampleUse);
    Replacement := @FTextureSamples[0];
    for var I := Low(FTextureSamples) to High(FTextureSamples) do
    begin
      Cache := @FTextureSamples[I];
      if Cache.LastUsed < Replacement.LastUsed then
        Replacement := Cache;
      if (Cache.Source = nil) or (@Cache.Source[0] <> @Sampler.Pixels[0]) or
        (Cache.ContentVersion <> Version) or (Cache.Premultiplied <> Sampler.Premultiplied) or
        (Cache.SourceWidth <> Sampler.Width) or (Cache.TargetWidth <> FRender.Width) or
        (Cache.TargetHeight <> FRender.Height) or (Cache.RepeatPixels <> Sampler.RepeatPixels) or
        not CompareMem(@Cache.Inverse, @Sampler.Inverse, SizeOf(Cache.Inverse)) then
        Continue;
      Cache.LastUsed := FTextureSampleUse;
      if Cache.Valid = nil then
      begin
        SetLength(Cache.Colors, ScreenPixels);
        SetLength(Cache.Valid, ScreenPixels);
        SetLength(Cache.Rows, FRender.Height);
      end;
      Exit(Cache);
    end;
    // Allocate sampled pixels only when the same source and transform recur.
    Replacement^ := Default(TFlashTextureSamples);
    Replacement.Source := Sampler.Pixels;
    Replacement.ContentVersion := Version;
    Replacement.Premultiplied := Sampler.Premultiplied;
    Replacement.SourceWidth := Sampler.Width;
    Replacement.TargetWidth := FRender.Width;
    Replacement.TargetHeight := FRender.Height;
    Replacement.RepeatPixels := Sampler.RepeatPixels;
    Replacement.Inverse := Sampler.Inverse;
    Replacement.LastUsed := FTextureSampleUse;
  end;

  procedure PaintNearestSpan(Y, X0, XEnd: Integer; Coverage: Word);
  var
    X, Column, RowOffset: Integer;
    U, V: Double;
    Color: Cardinal;

    procedure MapColumns(First, Stop: Integer);
    begin
      for var ColumnX := First to Stop - 1 do
      begin
        Sampler.Locate(ColumnX + 0.5, 0.5, U, V);
        TextureColumns[ColumnX] := Sampler.NearestIndex(U, Sampler.Width);
      end;
    end;

  begin
    // Axis-aligned nearest-neighbor fills can reuse the source coordinates
    // independently across all columns and scanlines of the style.
    if Y <> TextureY then
    begin
      Sampler.Locate(0.5, Y + 0.5, U, V);
      TextureY := Y;
      TextureRow := Sampler.NearestIndex(V, Sampler.Height);
      if TextureRow >= 0 then
        TextureRow := TextureRow * Sampler.Width;
    end;
    if TextureRow < 0 then
      Exit;
    if TextureColumns = nil then
      SetLength(TextureColumns, FRender.Width);
    if TextureLeft = TextureRight then
    begin
      TextureLeft := X0;
      TextureRight := X0;
    end;
    if X0 < TextureLeft then
    begin
      MapColumns(X0, TextureLeft);
      TextureLeft := X0;
    end;
    if XEnd > TextureRight then
    begin
      MapColumns(TextureRight, XEnd);
      TextureRight := XEnd;
    end;
    RowOffset := Y * FRender.Width;
    for X := X0 to XEnd - 1 do
    begin
      Column := TextureColumns[X];
      if Column < 0 then
        Continue;
      Color := Sampler.Pixels[TextureRow + Column];
      if Color shr 24 = 0 then
        Continue;
      if Sampler.Premultiplied then
        Color := StraightBitmapSample(Color);
      if TransformPaint then
        Color := FRender.Color.Apply(Color);
      PlotPixel(RowOffset + X, Color, Opacity, Pixels, Coverage);
    end;
  end;

  procedure PaintBilinearSpan(Y, X0, XEnd: Integer; Coverage: Word);
  var
    X, Index, RowStart: Integer;
    U, V: Double;
    Color: Cardinal;
    CacheWholeRow: Boolean;

    procedure MapColumns(First, Stop: Integer);
    begin
      for var Column := First to Stop - 1 do
      begin
        Sampler.Locate(Column + 0.5, 0.5, U, V);
        SmoothColumns[Column] := Sampler.BilinearAxis(U, Sampler.Width);
      end;
    end;

  begin
    RowStart := Y * FRender.Width;
    CacheWholeRow := (TextureSamples <> nil) and (X0 = 0) and (XEnd = FRender.Width);
    if (TextureSamples <> nil) and (TextureSamples.Rows[Y] <> trUnfilled) and not TransformPaint and
      (Opacity = 1) and (Coverage = FRender.FullCoverage) and (FRender.Coverage = nil) and
      ((FRender.DetailPixels = nil) or (FRender.DetailPixels.Count = 0)) then
    begin
      if TextureSamples.Rows[Y] = trOpaque then
        Move(TextureSamples.Colors[RowStart + X0], Pixels[RowStart + X0], (XEnd - X0) * SizeOf(Cardinal))
      else
        for Index := RowStart + X0 to RowStart + XEnd - 1 do
        begin
          Color := TextureSamples.Colors[Index];
          case Color shr 24 of
            0:
              ;
            255:
              Pixels[Index] := Color;
          else
            Blend(Pixels[Index], Color, 1, FRender.WithAlpha);
          end;
        end;
      Exit;
    end;
    if Y <> TextureY then
    begin
      Sampler.Locate(0.5, Y + 0.5, U, V);
      TextureY := Y;
      SmoothRow := Sampler.BilinearAxis(V, Sampler.Height);
    end;
    if SmoothRow.First < 0 then
      Exit;
    // Keep the mapped column interval for the remaining spans of this fill.
    if SmoothColumns = nil then
      SetLength(SmoothColumns, FRender.Width);
    if TextureLeft = TextureRight then
    begin
      TextureLeft := X0;
      TextureRight := X0;
    end;
    if X0 < TextureLeft then
    begin
      MapColumns(X0, TextureLeft);
      TextureLeft := X0;
    end;
    if XEnd > TextureRight then
    begin
      MapColumns(TextureRight, XEnd);
      TextureRight := XEnd;
    end;
    Index := RowStart + X0;
    for X := X0 to XEnd - 1 do
    begin
      if (TextureSamples <> nil) and (TextureSamples.Valid[Index] <> 0) then
        Color := TextureSamples.Colors[Index]
      else
      begin
        Color := Sampler.BilinearColor(SmoothColumns[X], SmoothRow);
        if TextureSamples <> nil then
        begin
          TextureSamples.Colors[Index] := Color;
          TextureSamples.Valid[Index] := 1;
        end;
      end;
      if Color shr 24 <> 0 then
      begin
        if TransformPaint then
          Color := FRender.Color.Apply(Color);
        PlotPixel(Index, Color, Opacity, Pixels, Coverage);
      end;
      Inc(Index);
    end;
    if CacheWholeRow and (TextureSamples.Rows[Y] = trUnfilled) then
    begin
      TextureSamples.Rows[Y] := trMixed;
      for Index := RowStart to RowStart + FRender.Width - 1 do
        if TextureSamples.Colors[Index] shr 24 <> 255 then
          Exit;
      TextureSamples.Rows[Y] := trOpaque;
    end;
  end;

  procedure PaintSpan(Y, X0, XEnd: Integer; Coverage: Word);
  var
    X, RowOffset: Integer;
    U, V, Scan: Double;
    Color: Cardinal;
  begin
    if (XEnd <= X0) or (Coverage = 0) then
      Exit;
    Charge(XEnd - X0);
    if CapturedSpans <> nil then
      CaptureSpan(Y, X0, XEnd, Coverage);
    RowOffset := Y * FRender.Width;
    Scan := Y + 0.5;
    if Graded then
    begin
      if Length(Style.Gradient.Stops) > 16 then
        Charge(Int64(XEnd - X0) * (Length(Style.Gradient.Stops) div 16));
      if GradientByRow or (MonotoneGradient and (XEnd - X0 >= 16)) then
      begin
        Color := GradientSampler.ColorAt(X0 + 0.5, Scan);
        // Every channel of a monotone gradient stays between the endpoint
        // values, so matching rounded endpoint colors cover the whole span.
        if GradientByRow or (Color = GradientSampler.ColorAt(XEnd - 0.5, Scan)) then
        begin
          if TransformPaint then
            Color := FRender.Color.Apply(Color);
          if Color shr 24 <> 0 then
            PaintSolidSpan(RowOffset + X0, RowOffset + XEnd, Color, Coverage);
          Exit;
        end;
      end;
      for X := X0 to XEnd - 1 do
      begin
        Color := GradientSampler.ColorAt(X + 0.5, Scan);
        if TransformPaint then
          Color := FRender.Color.Apply(Color);
        if Color shr 24 <> 0 then
          PlotPixel(RowOffset + X, Color, Opacity, Pixels, Coverage);
      end;
    end
    else if Textured then
    begin
      if NearestTexture then
      begin
        PaintNearestSpan(Y, X0, XEnd, Coverage);
        Exit;
      end;
      if AxisTexture then
      begin
        PaintBilinearSpan(Y, X0, XEnd, Coverage);
        Exit;
      end;
      for X := X0 to XEnd - 1 do
      begin
        var Index := RowOffset + X;
        if (TextureSamples <> nil) and (TextureSamples.Valid[Index] <> 0) then
          Color := TextureSamples.Colors[Index]
        else
        begin
          Sampler.Locate(X + 0.5, Scan, U, V);
          Color := Sampler.ColorAt(U, V);
          // The texture sample is independent of the current stencil and color transform.
          if TextureSamples <> nil then
          begin
            TextureSamples.Colors[Index] := Color;
            TextureSamples.Valid[Index] := 1;
          end;
        end;
        if Color shr 24 <> 0 then
        begin
          if TransformPaint then
            Color := FRender.Color.Apply(Color);
          PlotPixel(Index, Color, Opacity, Pixels, Coverage);
        end;
      end;
    end
    else
      PaintSolidSpan(RowOffset + X0, RowOffset + XEnd, FlatColor, Coverage);
  end;

  procedure MarkSpan(Y, Sample: Integer; Left, Right: Double);
  var
    X0, XEnd: Integer;
    Bit: Word;
  begin
    X0 := Ceil(EnsureRange(Left - FRender.SampleX[Sample], 0.0, Double(FRender.Width)));
    XEnd := Ceil(EnsureRange(Right - FRender.SampleX[Sample], 0.0, Double(FRender.Width)));
    if XEnd <= X0 then
      Exit;
    if FRender.SampleCount = 1 then
    begin
      PaintSpan(Y, X0, XEnd, FRender.FullCoverage);
      Exit;
    end;
    // The two boundaries mark an entire interval without writing its interior.
    Bit := Word(1) shl Sample;
    Transitions[X0] := Transitions[X0] xor Bit;
    Transitions[XEnd] := Transitions[XEnd] xor Bit;
    if BoundaryCount < Length(Boundaries) then
    begin
      Boundaries[BoundaryCount] := X0;
      Boundaries[BoundaryCount + 1] := XEnd;
    end;
    Inc(BoundaryCount, 2);
    FirstX := Min(FirstX, X0);
    EndX := Max(EndX, XEnd);
  end;

  procedure PaintRow(Y: Integer);
  var
    X, I, J, Start: Integer;
    Coverage: Word;
  begin
    Charge(EndX - FirstX);
    Coverage := 0;
    Start := FirstX;
    if (BoundaryCount <= Length(Boundaries)) and (EndX - FirstX > 24) then
    begin
      // Wide, simple fills usually change coverage at only a few columns.
      for I := 1 to BoundaryCount - 1 do
      begin
        X := Boundaries[I];
        J := I;
        while (J > 0) and (Boundaries[J - 1] > X) do
        begin
          Boundaries[J] := Boundaries[J - 1];
          Dec(J);
        end;
        Boundaries[J] := X;
      end;
      for I := 0 to BoundaryCount - 1 do
      begin
        X := Boundaries[I];
        if Transitions[X] = 0 then
          Continue;
        PaintSpan(Y, Start, X, Coverage);
        Coverage := Coverage xor Transitions[X];
        Transitions[X] := 0;
        Start := X;
      end;
      Exit;
    end;
    for X := FirstX to EndX do
      if Transitions[X] <> 0 then
      begin
        PaintSpan(Y, Start, X, Coverage);
        Coverage := Coverage xor Transitions[X];
        Transitions[X] := 0;
        Start := X;
      end;
  end;

  procedure CrossRow(Y, Sample: Integer; EvenOdd: Boolean);
  var
    Entry: ^TScanEdge;
    Scan, Start: Double;
    Count, Winding: Integer;
  begin
    Charge(ActiveCount);
    if ActiveCount < 2 then
      Exit;
    Scan := Y + FRender.SampleY[Sample];
    Count := 0;
    for var I := 0 to ActiveCount - 1 do
    begin
      Entry := @SortedEdges[Active[I]];
      if (Scan >= Entry.MinY) and (Scan < Entry.MaxY) then
      begin
        Crossings[Count].X := Entry.Edge.X1 + (Scan - Entry.Edge.Y1) *
          (Entry.Edge.X2 - Entry.Edge.X1) / (Entry.Edge.Y2 - Entry.Edge.Y1);
        Crossings[Count].Winding := Entry.Winding;
        Inc(Count);
      end;
    end;
    if Count < 2 then
      Exit;
    if Count = 2 then
    begin
      if EvenOdd or (Crossings[0].Winding <> Crossings[1].Winding) then
        if CompareValue(Crossings[0].X, Crossings[1].X) > 0 then
          MarkSpan(Y, Sample, Crossings[1].X, Crossings[0].X)
        else
          MarkSpan(Y, Sample, Crossings[0].X, Crossings[1].X);
      Exit;
    end;
    TArray.Sort<TCross>(Crossings, CrossOrder, 0, Count);
    Winding := 0;
    Start := 0;
    for var I := 0 to Count - 1 do
    begin
      if Winding = 0 then
        Start := Crossings[I].X;
      Inc(Winding, Crossings[I].Winding);
      if EvenOdd then
        Winding := Winding and 1;
      if Winding = 0 then
        MarkSpan(Y, Sample, Start, Crossings[I].X);
    end;
  end;

  procedure DrawEdges(EvenOdd: Boolean);
  var
    Y, Next, Index, Sample, Count: Integer;
  begin
    Count := ScanEdges.Count;
    if Count = 0 then
      Exit;
    ScanEdges.Sort(EdgeOrder);
    SortedEdges := ScanEdges.List;
    if Count > Length(Active) then
    begin
      SetLength(Active, Count);
      SetLength(Crossings, Count);
    end;
    ActiveCount := 0;
    Next := 0;
    Y := SortedEdges[0].FirstRow;
    while (Next < Count) or (ActiveCount <> 0) do
    begin
      for Index := ActiveCount - 1 downto 0 do
        if SortedEdges[Active[Index]].EndRow <= Y then
        begin
          Dec(ActiveCount);
          Active[Index] := Active[ActiveCount];
        end;
      if (ActiveCount = 0) and (Next < Count) then
        Y := Max(Y, SortedEdges[Next].FirstRow);
      while (Next < Count) and (SortedEdges[Next].FirstRow = Y) do
      begin
        Active[ActiveCount] := Next;
        Inc(ActiveCount);
        Inc(Next);
      end;
      FirstX := FRender.Width;
      EndX := -1;
      BoundaryCount := 0;
      for Sample := 0 to FRender.SampleCount - 1 do
        CrossRow(Y, Sample, EvenOdd);
      if EndX >= 0 then
        PaintRow(Y);
      Inc(Y);
    end;
  end;

  procedure DrawFill;
  var
    EdgeIndex: Integer;

    procedure AddLocalEdge(const Edge: TSWFEdge);
    var
      Transformed: TSWFEdge;
    begin
      Transformed.Fill := Fill;
      Transformed.X1 := (M.A * Edge.X1 + M.C * Edge.Y1 + M.TX - FRender.Stage.Left) / 20;
      Transformed.Y1 := (M.B * Edge.X1 + M.D * Edge.Y1 + M.TY - FRender.Stage.Top) / 20;
      Transformed.X2 := (M.A * Edge.X2 + M.C * Edge.Y2 + M.TX - FRender.Stage.Left) / 20;
      Transformed.Y2 := (M.B * Edge.X2 + M.D * Edge.Y2 + M.TY - FRender.Stage.Top) / 20;
      AddEdge(Transformed);
    end;

  begin
    ScanEdges.Clear;
    EdgeIndex := GeometryByStyle[Fill - 1].FirstEdge;
    while EdgeIndex <> 0 do
    begin
      AddLocalEdge(Shape.Edges[EdgeIndex - 1]);
      EdgeIndex := NextEdge[EdgeIndex - 1];
    end;
    if HasClosing and (Closing.Fill = Fill) then
      AddLocalEdge(Closing);
    DrawEdges(Shape.EvenOddFills);
  end;

  procedure DrawStroke(const LinePath: TSWFStrokePath);
  var
    E: TSWFEdge;
  begin
    Charge(Length(LinePath.Points));
    StrokeEdges.Clear;
    BuildStrokeEdges(LinePath, Style.Line, ShapeToFrame, StrokeEdges);
    Charge(StrokeEdges.Count);
    ScanEdges.Clear;
    for E in StrokeEdges do
      AddEdge(E);
    DrawEdges(False);
  end;

begin
  if Shape = nil then
    Exit;
  if Shape.BitmapWidth > 0 then
  begin
    RenderBitmap(Shape.BitmapWidth, Shape.BitmapHeight, Shape.BitmapPixels, M, True, False, Opacity, Pixels);
    Exit;
  end;
  HasClosing := (DrawingClip <> nil) and DrawingClip.PendingFillEdge(Closing);
  HasPending := (DrawingClip <> nil) and (FRender.MaskOutput = nil) and DrawingClip.PendingStroke(Pending);
  if (Length(Shape.Edges) = 0) and (Length(Shape.StrokePaths) = 0) and not HasPending and not HasClosing then
    Exit;
  Raster := nil;
  if DrawingClip = nil then
    Raster := FindShapeRaster(Shape, M, ColorOverride >= 0);
  ReplayRaster := (Raster <> nil) and (Raster.StyleOffsets <> nil);
  TransformPaint := HasPaintColorTransform(FRender.Color);
  CapturedSpans := nil;
  ScanEdges := nil;
  StrokeEdges := nil;
  try
    if ReplayRaster then
      Charge(Length(Shape.Fills))
    else
    begin
      IndexGeometry;
      ShapeToFrame := BitmapToFrame(M, FRender.Stage);
      if FRender.SampleCount > 1 then
        SetLength(Transitions, FRender.Width + 1);
      EdgeOrder := TComparer<TScanEdge>.Construct(
        function(const A, B: TScanEdge): Integer
        begin
          Result := A.FirstRow - B.FirstRow;
        end);
      CrossOrder := TComparer<TCross>.Construct(
        function(const A, B: TCross): Integer
        begin
          Result := CompareValue(A.X, B.X);
        end);
      ScanEdges := TList<TScanEdge>.Create;
      StrokeEdges := TList<TSWFEdge>.Create;
      if Raster <> nil then
      begin
        SetLength(StyleOffsets, Length(Shape.Fills) + 1);
        CapturedSpans := TList<TFlashRasterSpan>.Create;
      end;
    end;
    for Fill := 1 to Length(Shape.Fills) do
    begin
      if CapturedSpans <> nil then
        StyleOffsets[Fill - 1] := CapturedSpans.Count;
      Style := Shape.Fills[Fill - 1];
      if (FRender.MaskOutput <> nil) and Style.Stroke then
        Continue;
      Textured := (FRender.MaskOutput = nil) and (ColorOverride < 0) and
        ((Style.BitmapId <> 0) or (Style.BitmapData <> nil));
      Graded := (FRender.MaskOutput = nil) and (ColorOverride < 0) and (Style.Gradient.Kind <> sgNone);
      if Graded then
      begin
        GradientSampler.Initialize(Style.Gradient, M, FRender.Stage);
        GradientByRow := (Style.Gradient.Kind = sgLinear) and GradientSampler.Mapped and
          (GradientSampler.Inverse.A = 0);
        MonotoneGradient := (Style.Gradient.Kind = sgLinear) and GradientSampler.Mapped and
          (Style.Gradient.Spread = gsPad) and not Style.Gradient.LinearRGB and
          (Length(Style.Gradient.Stops) = 2) and (Style.Gradient.Stops[0].Ratio < Style.Gradient.Stops[1].Ratio);
      end
      else if Textured then
      begin
        TextureToFrame := ShapePaintToFrame(Style.BitmapMatrix, M, FRender.Stage);
        if Style.BitmapData <> nil then
        begin
          if not Sampler.Initialize(Style.BitmapData.Width, Style.BitmapData.Height,
            Style.BitmapData.SnapshotPremultiplied, TextureToFrame, Style.BitmapRepeat,
            Style.BitmapSmooth and (FRender.Quality <> fqLow), True) then
            Continue;
        end
        else
        begin
          if (Style.BitmapId = $FFFF) or (LibraryMovie = nil) or
            not LibraryMovie.Characters.TryGetValue(Style.BitmapId, Bitmap) then
            Continue;
          if not Sampler.Initialize(Bitmap.BitmapWidth, Bitmap.BitmapHeight, Bitmap.BitmapPixels,
            TextureToFrame, Style.BitmapRepeat, Style.BitmapSmooth and (FRender.Quality <> fqLow), False) then
            Continue;
        end;
        TextureSamples := FindTextureSamples;
        AxisTexture := (Sampler.Inverse.B = 0) and (Sampler.Inverse.C = 0) and (FRender.Width <= 4096);
        NearestTexture := not Sampler.Smooth and AxisTexture;
        TextureLeft := 0;
        TextureRight := 0;
        TextureY := -1;
      end
      else
      begin
        if ColorOverride >= 0 then
          FlatColor := Cardinal(ColorOverride)
        else
          FlatColor := Style.Color;
        if TransformPaint then
          FlatColor := FRender.Color.Apply(FlatColor);
      end;
      if ReplayRaster then
      begin
        for var I := Raster.StyleOffsets[Fill - 1] to Raster.StyleOffsets[Fill] - 1 do
        begin
          var Span := Raster.Spans[I];
          PaintSpan(Span.Y, Span.Left, Span.Right, Span.Coverage);
        end;
      end
      else if Style.Stroke then
      begin
        StrokeIndex := GeometryByStyle[Fill - 1].FirstStroke;
        while StrokeIndex <> 0 do
        begin
          DrawStroke(Shape.StrokePaths[StrokeIndex - 1]);
          StrokeIndex := NextStroke[StrokeIndex - 1];
        end;
        if HasPending and (Pending.Fill = Fill) then
          DrawStroke(Pending);
      end
      else
        DrawFill;
    end;
    if CapturedSpans <> nil then
    begin
      StyleOffsets[High(StyleOffsets)] := CapturedSpans.Count;
      Raster.Spans := CapturedSpans.ToArray;
      Inc(FShapeRasterSpanCount, Length(Raster.Spans));
      Raster.StyleOffsets := StyleOffsets;
    end;
  finally
    CapturedSpans.Free;
    StrokeEdges.Free;
    ScanEdges.Free;
  end;
end;

function TFlashPlayer.BitmapTextGlyph(Character: Char): TSWFCharacter;
var
  Bitmap: TBitmapGlyph;
  X, Y, First: Integer;
  Edges: TList<TSWFEdge>;
  Edge: TSWFEdge;
  Fill: TSWFFill;

  procedure Add(X1, Y1, X2, Y2: Integer);
  begin
    Edge.X1 := X1 * 20;
    Edge.Y1 := Y1 * 20;
    Edge.X2 := X2 * 20;
    Edge.Y2 := Y2 * 20;
    Edge.Fill := 1;
    Edges.Add(Edge);
  end;

begin
  Bitmap := BitmapFontGlyph(TBitmapFontSize.Small, Character);
  if FBitmapGlyphs.TryGetValue(Bitmap.Offset, Result) then
    Exit;
  if FBitmapGlyphs.Count >= 4096 then
    raise ESWFError.Create('Flash bitmap glyph cache limit');
  Result := TSWFCharacter.Create;
  try
    Edges := TList<TSWFEdge>.Create;
    try
      for Y := 0 to Bitmap.Height - 1 do
      begin
        X := 0;
        while X < Bitmap.Width do
        begin
          if not Bitmap.Ink(X, Y) then
          begin
            Inc(X);
            Continue;
          end;
          First := X;
          while (X < Bitmap.Width) and Bitmap.Ink(X, Y) do
            Inc(X);
          Add(First, Y, X, Y);
          Add(X, Y, X, Y + 1);
          Add(X, Y + 1, First, Y + 1);
          Add(First, Y + 1, First, Y);
        end;
      end;
      Fill := Default(TSWFFill);
      Fill.Color := $FF000000;
      Result.Fills := [Fill];
      Result.Edges := Edges.ToArray;
    finally
      Edges.Free;
    end;
    FBitmapGlyphs.Add(Bitmap.Offset, Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure TFlashPlayer.RenderText(C: TFlashClip; const M: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  Text: string;
  Value: TAVMValue;
  Format: TAVMTextFormatData;
  Font: TSWFCharacter;
  Size, Scale, TX, TY, Top, LeftInset, FreeWidth, TotalWidth, LineAscent, LineHeight, Advance, Ascent: Double;
  Leading: Double;
  Color: Cardinal;
  I, Index, LineStart, LineEnd: Integer;
  GM: TSWFMatrix;
  Ch: Char;

  function Number(Data: TAVMTextFormatData; Field: Integer; Default: Double = 0): Double;
  begin
    Result := Default;
    if Data.Values[Field].Kind = avNumber then
      Result := Data.Values[Field].Number;
    if IsNan(Result) or IsInfinite(Result) then
      Result := Default;
  end;

  function FontFor(Data: TAVMTextFormatData): TSWFCharacter;
  var
    Candidate: TSWFCharacter;
    Name: string;
  begin
    Result := nil;
    Name := Data.Values[0].Text;
    if (C.FontId <> 0) and C.MovieLibrary.Movie.Characters.TryGetValue(C.FontId, Candidate) and
      (Candidate.Glyphs.Count > 0) then
      Result := Candidate;
    if (Result <> nil) and SameText(Result.FontName, Name) then
      Exit;
    for Candidate in C.MovieLibrary.Movie.Characters.Values do
      if (Candidate.Glyphs.Count > 0) and SameText(Candidate.FontName, Name) then
        Exit(Candidate);
  end;

  function GlyphIndex(AFont: TSWFCharacter; Character: Char): Integer;
  var
    At: Integer;
  begin
    Result := -1;
    if AFont = nil then
      Exit;
    for At := 0 to High(AFont.FontCodes) do
      if AFont.FontCodes[At] = Ord(Character) then
        Exit(At);
  end;

  function WidthAt(At: Integer; out AFont: TSWFCharacter; out AScale, AAscent: Double): Double;
  var
    Data: TAVMTextFormatData;
    Height: Double;
    GI: Integer;
    Bitmap: TBitmapGlyph;
  begin
    Data := C.TextDocument.FormatAt(At - 1);
    Height := Max(0.0, Number(Data, 1, 12));
    AFont := FontFor(Data);
    AScale := Height * 20 / 1024;
    AAscent := 0;
    if AFont <> nil then
    begin
      if AFont.Kind = 75 then
        AScale := AScale / 20;
      AAscent := AFont.FontAscent;
      if AAscent = 0 then
      begin
        AAscent := 800;
        if AFont.Kind = 75 then
          AAscent := AAscent * 20;
      end;
      AAscent := AAscent * AScale;
      GI := GlyphIndex(AFont, Text[At]);
      if GI >= 0 then
        Result := AFont.FontAdvances[GI] * AScale
      else
        Result := Height * 10;
    end
    else
    begin
      Bitmap := BitmapFontGlyph(TBitmapFontSize.Small, Text[At]);
      AScale := Height / Max(1, Bitmap.Height);
      Result := Bitmap.Width * AScale * 20;
      AAscent := 0;
    end;
    Result := Result + SWFTwipsFromPixels(Number(Data, 18));
  end;

begin
  Text := C.Text;
  if (C.VariableName <> '') and not C.MovieLibrary.Movie.UsesAVM2 then
  begin
    Value := ReadBoundTextVariable(C);
    if Value.Kind <> avUndefined then
    begin
      C.Text := VM.CoerceString(Value);
      Text := C.Text;
    end;
  end;
  Top := C.TextTop * 20 + 40;
  LineStart := 1;
  while LineStart <= Length(Text) do
  begin
    LineEnd := LineStart;
    while (LineEnd <= Length(Text)) and not CharInSet(Text[LineEnd], [#13, #10]) do
      Inc(LineEnd);
    TotalWidth := 0;
    LineAscent := 0;
    LineHeight := 0;
    for I := LineStart to LineEnd - 1 do
    begin
      TotalWidth := TotalWidth + WidthAt(I, Font, Scale, Ascent);
      LineAscent := Max(LineAscent, Ascent);
      LineHeight := Max(LineHeight, Max(0.0, Number(C.TextDocument.FormatAt(I - 1), 1, 12)) * 20);
    end;
    Format := C.TextDocument.FormatAt(LineStart - 1);
    Leading := Number(Format, 12);
    LeftInset := (Number(Format, 9) + Number(Format, 11)) * 20;
    FreeWidth := (C.TextWidth - Number(Format, 10)) * 20 - 80 - LeftInset - TotalWidth;
    TX := C.TextLeft * 20 + 40 + LeftInset;
    if Format.Values[8].Text = 'right' then
      TX := TX + Max(0.0, FreeWidth)
    else if Format.Values[8].Text = 'center' then
      TX := TX + Max(0.0, FreeWidth / 2);
    TY := Top + LineAscent;
    for I := LineStart to LineEnd - 1 do
    begin
      Format := C.TextDocument.FormatAt(I - 1);
      Ch := Text[I];
      Advance := WidthAt(I, Font, Scale, Ascent);
      Size := Max(0.0, Number(Format, 1, 12));
      Color := $FF000000 or (Cardinal(AVMToInt32(Number(Format, 2))) and $FFFFFF);
      if Size > 0 then
      begin
        Index := GlyphIndex(Font, Ch);
        if (Font <> nil) and (Index >= 0) then
        begin
          GM := TSWFMatrix.Identity;
          GM.A := Scale;
          GM.D := Scale;
          GM.TX := TX;
          GM.TY := TY;
          RenderShape(Font.Glyphs[Index], GM.ThenBy(M), Opacity, Pixels, Color);
        end
        else if Font = nil then
        begin
          GM := TSWFMatrix.Identity;
          GM.A := Scale;
          GM.D := Scale;
          GM.TX := TX - 40;
          GM.TY := Top - 40;
          RenderShape(BitmapTextGlyph(Ch), GM.ThenBy(M), Opacity, Pixels, Color);
        end;
      end;
      TX := TX + Advance;
    end;
    Top := Top + LineHeight + Leading * 20;
    LineStart := LineEnd + 1;
    if (LineEnd < Length(Text)) and (Text[LineEnd] = #13) and (Text[LineEnd + 1] = #10) then
      Inc(LineStart);
  end;
end;

procedure TFlashPlayer.AllocateCoverage(out Coverage: TBytes);
var
  ByteCount: Integer;
begin
  ByteCount := (FRender.Width * FRender.Height * FRender.SampleCount + 7) div 8;
  // Account for each stencil allocation as well as its geometry and pixel work.
  Inc(FRender.Work, ByteCount);
  if FRender.Work > FlashRenderWorkLimit then
    raise ESWFError.Create('Flash frame rendering work limit');
  SetLength(Coverage, ByteCount);
end;

function TFlashPlayer.RenderMask(C: TFlashClip; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>; ScriptSource: Boolean): TBytes;
var
  Coverage, PreviousOutput: TBytes;
begin
  // The caller may assign the result directly to FRender.Coverage. The
  // completed stencil must be independent of the coverage used to build it.
  AllocateCoverage(Coverage);
  if C.RenderingMask then
    Exit(Coverage);
  PreviousOutput := FRender.MaskOutput;
  FRender.MaskOutput := Coverage;
  C.RenderingMask := True;
  try
    // A mask contributes its own contents in stage space. Its root's mask link
    // and visibility do not apply to the stencil. Child masks still apply.
    if ScriptSource then
      RenderClipBody(C, Matrix, 1, Pixels)
    else
      RenderClipViewport(C, Matrix, 1, Pixels);
  finally
    C.RenderingMask := False;
    FRender.MaskOutput := PreviousOutput;
  end;
  Result := Coverage;
end;

function TFlashPlayer.ScriptMaskMatrix(C: TFlashClip): TSWFMatrix;
var
  Node: TFlashClip;
  local, Inverse: TSWFMatrix;
  Depth: Integer;
begin
  if FRender.DrawableRoot = nil then
    Exit(WorldMatrix(C));
  // Relative transforms preserve a source subtree even when its stage matrix is singular.
  Node := C;
  local := TSWFMatrix.Identity;
  Depth := 0;
  while (Node <> nil) and (Node <> FRender.DrawableRoot) do
  begin
    Inc(Depth);
    if Depth > 128 then
      raise ESWFError.Create('Flash matrix parent limit');
    local := local.ThenBy(Node.WithScrollOffset(Node.Matrix));
    Node := Node.Parent;
  end;
  if Node = FRender.DrawableRoot then
    Exit(local.ThenBy(Node.WithScrollOffset(FRender.DrawableMatrix)));
  Result := WorldMatrix(C);
  if SWFInverseMatrix(WorldMatrix(FRender.DrawableRoot, False), Inverse) then
    Result := Result.ThenBy(Inverse).ThenBy(FRender.DrawableMatrix);
end;

function TFlashPlayer.RenderRectCoverage(const Rect: TSWFRect; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>): TBytes;
const
  Corners: array[0..3, 0..1] of Integer = ((0, 0), (1, 0), (1, 1), (0, 1));
var
  Coverage, PreviousOutput: TBytes;
  Quad, Transform: TSWFMatrix;
  I, Next: Integer;
begin
  AllocateCoverage(Coverage);
  if (Rect.Right <= Rect.Left) or (Rect.Bottom <= Rect.Top) then
    Exit(Coverage);
  if FViewportQuad = nil then
  begin
    FViewportQuad := TSWFCharacter.Create;
    SetLength(FViewportQuad.Fills, 1);
    FViewportQuad.Fills[0].Color := $FFFFFFFF;
    SetLength(FViewportQuad.Edges, 4);
    for I := 0 to 3 do
    begin
      Next := (I + 1) and 3;
      FViewportQuad.Edges[I].X1 := Corners[I, 0];
      FViewportQuad.Edges[I].Y1 := Corners[I, 1];
      FViewportQuad.Edges[I].X2 := Corners[Next, 0];
      FViewportQuad.Edges[I].Y2 := Corners[Next, 1];
      FViewportQuad.Edges[I].Fill := 1;
    end;
  end;
  if (Rect.Left = 0) and (Rect.Top = 0) then
  begin
    Transform := Matrix;
    Transform.A := Transform.A * Rect.Right;
    Transform.B := Transform.B * Rect.Right;
    Transform.C := Transform.C * Rect.Bottom;
    Transform.D := Transform.D * Rect.Bottom;
  end
  else
  begin
    Quad := TSWFMatrix.Identity;
    Quad.A := Int64(Rect.Right) - Rect.Left;
    Quad.D := Int64(Rect.Bottom) - Rect.Top;
    Quad.TX := Rect.Left;
    Quad.TY := Rect.Top;
    Transform := Quad.ThenBy(Matrix);
  end;
  PreviousOutput := FRender.MaskOutput;
  FRender.MaskOutput := Coverage;
  try
    RenderShape(FViewportQuad, Transform, 1, Pixels);
  finally
    FRender.MaskOutput := PreviousOutput;
  end;
  Result := Coverage;
end;

function TFlashPlayer.RenderScrollCoverage(C: TFlashClip; const Matrix: TSWFMatrix; var Pixels: TArray<Cardinal>): TBytes;
begin
  Result := RenderRectCoverage(ScrollViewport(C.AppliedScrollRect), Matrix, Pixels);
end;

procedure TFlashPlayer.RenderClipViewport(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  PreviousCoverage: TBytes;
begin
  if not C.HasAppliedScrollRect then
  begin
    RenderClipBody(C, Matrix, Opacity, Pixels);
    Exit;
  end;
  // Flash's stencil path retains the content translation of a scrolling
  // mask descendant. Its own viewport does not crop the outer stencil.
  if FRender.MaskOutput <> nil then
  begin
    RenderClipBody(C, C.WithScrollOffset(Matrix), Opacity, Pixels);
    Exit;
  end;
  PreviousCoverage := FRender.Coverage;
  try
    FRender.Coverage := RenderScrollCoverage(C, Matrix, Pixels);
    RenderClipBody(C, C.WithScrollOffset(Matrix), Opacity, Pixels);
  finally
    FRender.Coverage := PreviousCoverage;
  end;
end;

procedure TFlashPlayer.RenderClipWithMask(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  PreviousCoverage: TBytes;
begin
  if C.Masker = nil then
  begin
    RenderClipViewport(C, Matrix, Opacity, Pixels);
    Exit;
  end;
  PreviousCoverage := FRender.Coverage;
  try
    FRender.Coverage := RenderMask(C.Masker, ScriptMaskMatrix(C.Masker), Pixels, True);
    RenderClipViewport(C, Matrix, Opacity, Pixels);
  finally
    FRender.Coverage := PreviousCoverage;
  end;
end;

procedure TFlashPlayer.RenderClip(C: TFlashClip; const ParentMatrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  PreviousColor: TSWFColorTransform;
  Matrix: TSWFMatrix;
begin
  if C.Dead or C.Removing or (C.Maskee <> nil) or ((FRender.MaskOutput = nil) and not C.Visible) then
    Exit;
  Matrix := C.Matrix.ThenBy(ParentMatrix);
  PreviousColor := FRender.Color;
  try
    FRender.Color := C.ColorTransform.ThenBy(FRender.Color);
    if (FRender.MaskOutput = nil) and ((C.BlendMode <> bbNormal) or
      ((FRender.DrawableRoot = nil) and HasFlashFilters(C.Filters))) then
      RenderClipGroup(C, Matrix, Opacity, Pixels)
    else
      RenderClipWithMask(C, Matrix, Opacity, Pixels);
  finally
    FRender.Color := PreviousColor;
  end;
end;

function TFlashPlayer.VideoBitmap(C: TFlashClip; var Work: Int64): IImagePixelBuffer;
var
  Video: TSWFVideoStream;
begin
  if C.NetStream <> nil then
    Exit(FNet.Bitmap(C.NetStream));
  Video := C.Character.Video;
  if Video.PacketCount = 0 then
    Exit(nil);
  Video.Seek(C.MorphRatio, C.VideoState, FVideoPool, Work, FlashRenderWorkLimit);
  Result := C.VideoState.Bitmap;
end;

procedure TFlashPlayer.RenderClipVideo(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  Video: TSWFVideoStream;
  Bitmap: IImagePixelBuffer;
  VideoMatrix: TSWFMatrix;
  VideoVersion: Integer;
  Smooth: Boolean;
  ScaleX, ScaleY: Double;
begin
  Video := C.Character.Video;
  if (Video.Width = 0) or (Video.Height = 0) then
    Exit;
  Bitmap := VideoBitmap(C, FRender.Work);
  if Bitmap = nil then
    Exit;
  VideoMatrix := Matrix;
  ScaleX := Video.Width / Bitmap.Width;
  ScaleY := Video.Height / Bitmap.Height;
  VideoMatrix.A := Matrix.A * ScaleX;
  VideoMatrix.B := Matrix.B * ScaleX;
  VideoMatrix.C := Matrix.C * ScaleY;
  VideoMatrix.D := Matrix.D * ScaleY;
  VideoVersion := C.MovieLibrary.Movie.Version;
  Smooth := False;
  if FRender.Quality <> fqLow then
  begin
    if C.NetStream <> nil then
      Smooth := VM.GetOwnStored(C.Script, 'smoothing').AsBoolean(VideoVersion)
    else if VideoVersion >= 8 then
      Smooth := Video.Smooth
    else if FRender.Quality <> fqMedium then
      Smooth := (FRender.Quality <> fqHigh) or (Video.PacketCount = 1);
  end;
  RenderBitmap(Bitmap.Width, Bitmap.Height, Bitmap.SnapshotPremultiplied, VideoMatrix,
    Smooth, True, Opacity, Pixels, False, not Bitmap.Transparent);
end;

procedure TFlashPlayer.RenderClipBody(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
type
  TDepthMask = record
    PreviousEnd: Integer;
    PreviousCoverage: TBytes;
  end;
var
  PreviousCoverage: TBytes;
  Masks: TStack<TDepthMask>;
  Entry: TDepthMask;
  Child: TFlashClip;
  Items: TArray<TFlashClip>;
  ClipEnd, State: Integer;
begin
  if FClipRenderDepth >= 256 then
    raise ESWFError.Create('Flash masked display nesting limit');
  Inc(FClipRenderDepth);
  try
    if IsNan(Matrix.A) or IsInfinite(Matrix.A) or IsNan(Matrix.B) or IsInfinite(Matrix.B) or
      IsNan(Matrix.C) or IsInfinite(Matrix.C) or IsNan(Matrix.D) or IsInfinite(Matrix.D) then
      Exit;
    if C.Character <> nil then
    begin
      if C.Character.Video <> nil then
        RenderClipVideo(C, Matrix, Opacity, Pixels)
      else
        RenderShape(C.Character.ShapeAt(C.MorphRatio), Matrix, Opacity, Pixels, -1, C.MovieLibrary.Movie);
    end;
    if C.AttachedBitmap <> nil then
      RenderBitmap(C.AttachedBitmap.Width, C.AttachedBitmap.Height, C.AttachedBitmap.SnapshotPremultiplied,
        Matrix, C.AttachedBitmapSmooth, True, Opacity, Pixels, True, not C.AttachedBitmap.Transparent);
    RenderShape(C.Drawing, Matrix, Opacity, Pixels, -1, C.MovieLibrary.Movie, C);
    if C.IsText then
      RenderText(C, Matrix, Opacity, Pixels);
    if (C.Character <> nil) and (C.Character.Kind in [11, 33]) then
      RenderStaticText(C, Matrix, Opacity, Pixels);
    if C.Children.Count = 0 then
      Exit;
    Items := ChildrenInDepthOrder(C);
    PreviousCoverage := FRender.Coverage;
    Masks := nil;
    ClipEnd := 0;
    try
      for Child in Items do
      begin
        Child.ApplyScrollRect;
        while (ClipEnd > 0) and (Child.Depth > ClipEnd) do
        begin
          Entry := Masks.Pop;
          ClipEnd := Entry.PreviousEnd;
          FRender.Coverage := Entry.PreviousCoverage;
        end;
        if Child.ButtonStates <> 0 then
        begin
          State := 1;
          if C.ButtonState = 1 then
            State := 2
          else if C.ButtonState = 2 then
            State := 4;
          if (Child.ButtonStates and State) = 0 then
            Continue;
        end;
        if HasTimelineMask(Child) then
        begin
          if Masks = nil then
            Masks := TStack<TDepthMask>.Create;
          if Masks.Count >= 128 then
            raise ESWFError.Create('Flash timeline mask nesting limit');
          Entry.PreviousEnd := ClipEnd;
          Entry.PreviousCoverage := FRender.Coverage;
          Masks.Push(Entry);
          ClipEnd := Child.ClipDepth;
          FRender.Coverage := RenderMask(Child, Child.Matrix.ThenBy(Matrix), Pixels);
        end
        else
          RenderClip(Child, Matrix, Opacity, Pixels);
      end;
    finally
      FRender.Coverage := PreviousCoverage;
      Masks.Free;
    end;
  finally
    Dec(FClipRenderDepth);
  end;
end;

procedure TFlashPlayer.ResolveSamples(var Pixels: TArray<Cardinal>);
const
  SampleShifts: array[TFlashQuality] of Integer = (0, 1, 2, 2, 3, 3, 4, 4);
  ChannelMask = $00FF00FF;
var
  Linear: array[0..255] of Word;
  Index, Offset, I, SA, SR, SG, SB, Alpha, Weight, Shift: Integer;
  Color, RedBlue, AlphaGreen, Rounding: Cardinal;
begin
  if (FRender.DetailPixels = nil) or (FRender.DetailPixels.Count = 0) then
    Exit;
  Offset := 0;
  if not (FRender.Quality in [fq8x8Linear, fq16x16Linear]) then
  begin
    Shift := SampleShifts[FRender.Quality];
    Rounding := Cardinal(FRender.SampleCount div 2) * $00010001;
    for Index in FRender.DetailPixels do
    begin
      // Sum two channels per word pair. At most 16 samples fit independently in each half.
      RedBlue := Rounding;
      AlphaGreen := Rounding;
      for I := 0 to FRender.SampleCount - 1 do
      begin
        Color := FRender.DetailColors[Offset + I];
        Inc(RedBlue, Color and ChannelMask);
        Inc(AlphaGreen, (Color shr 8) and ChannelMask);
      end;
      Color := ((RedBlue shr Shift) and ChannelMask) or
        (((AlphaGreen shr Shift) and ChannelMask) shl 8);
      if not FRender.WithAlpha then
        Color := Color or $FF000000;
      Pixels[Index] := Color;
      Inc(Offset, FRender.SampleCount);
    end;
    Exit;
  end;

  for I := 0 to 255 do
    Linear[I] := Round(GradientLinearComponent(I) * 4095);
  for Index in FRender.DetailPixels do
  begin
    SR := 0;
    SG := 0;
    SB := 0;
    SA := 0;
    for I := 0 to FRender.SampleCount - 1 do
    begin
      Color := FRender.DetailColors[Offset + I];
      Weight := 1;
      if FRender.WithAlpha then
      begin
        Weight := Color shr 24;
        Inc(SA, Weight);
        Color := UnpremultiplyBitmapColor(Color);
      end;
      Inc(SR, Linear[(Color shr 16) and 255] * Weight);
      Inc(SG, Linear[(Color shr 8) and 255] * Weight);
      Inc(SB, Linear[Color and 255] * Weight);
    end;
    if FRender.WithAlpha then
    begin
      Weight := SA;
      Alpha := (SA + FRender.SampleCount div 2) div FRender.SampleCount;
    end
    else
    begin
      Weight := FRender.SampleCount;
      Alpha := 255;
    end;
    if Weight > 0 then
    begin
      SR := Round(GradientSRGBComponent(SR / (4095 * Weight)));
      SG := Round(GradientSRGBComponent(SG / (4095 * Weight)));
      SB := Round(GradientSRGBComponent(SB / (4095 * Weight)));
    end;
    Color := (Cardinal(Alpha) shl 24) or (Cardinal(SR) shl 16) or (Cardinal(SG) shl 8) or Cardinal(SB);
    if FRender.WithAlpha then
      Color := PremultiplyBitmapColor(Color, True);
    Pixels[Index] := Color;
    Inc(Offset, FRender.SampleCount);
  end;
end;

procedure TFlashPlayer.BeginRender(Width, Height: Integer; const Stage: TSWFRect; Color: TSWFColorTransform; WithAlpha: Boolean; Quality: TFlashQuality; out Previous: TFlashRenderState);
begin
  // Updating a bound TextField may run an AVM1 getter that draws another bitmap.
  Previous := FRender;
  FRender := Default(TFlashRenderState);
  FRender.Quality := Quality;
  FRender.Width := Width;
  FRender.Height := Height;
  FRender.Stage := Stage;
  FRender.Color := Color;
  FRender.WithAlpha := WithAlpha;
  ConfigureSamples;
  if FRender.SampleCount > 1 then
  begin
    SetLength(FRender.DetailIndex, Width * Height);
    FRender.DetailPixels := TList<Integer>.Create;
  end;
end;

procedure TFlashPlayer.EndRender(const Previous: TFlashRenderState);
begin
  FRender.DetailPixels.Free;
  FRender := Previous;
end;

function TFlashPlayer.Render: TArray<Cardinal>;
var
  Root: TFlashClip;
  I: Integer;
  Previous: TFlashRenderState;
begin
  SetLength(Result, Movie.Width * Movie.Height);
  for I := 0 to High(Result) do
    Result[I] := Movie.Background;
  try
    BeginRender(Movie.Width, Movie.Height, Movie.Stage, TSWFColorTransform.Identity, False, FQuality, Previous);
    for Root in LevelClips do
    begin
      Root.ApplyScrollRect;
      RenderClip(Root, TSWFMatrix.Identity, 1, Result);
    end;
    ResolveSamples(Result);
  finally
    EndRender(Previous);
  end;
end;

function BlendBitmapLayer(Dest, Source: Cardinal; Mode: TAVMBitmapBlend): Cardinal;
var
  SourceAlpha, DestAlpha, Alpha, Shift, S, D, Channel: Integer;
  CS, CD, Mixed: Double;
  InverseAlpha, RedBlue, AlphaGreen, Overflow: Cardinal;
begin
  SourceAlpha := Source shr 24;
  if SourceAlpha = 0 then
    Exit(Dest);
  if Mode in [bbNormal, bbLayer] then
  begin
    if SourceAlpha = 255 then
      Exit(Source);
    InverseAlpha := 255 - Cardinal(SourceAlpha);
    RedBlue := (Source and $00FF00FF) + DivideColorLanesBy255((Dest and $00FF00FF) * InverseAlpha);
    AlphaGreen := ((Source shr 8) and $00FF00FF) +
      DivideColorLanesBy255(((Dest shr 8) and $00FF00FF) * InverseAlpha);
    // Saturate each RGB channel even for input outside the premultiplied range.
    Overflow := RedBlue and $01000100;
    RedBlue := RedBlue or (Overflow - (Overflow shr 8));
    Overflow := AlphaGreen and $01000100;
    AlphaGreen := AlphaGreen or (Overflow - (Overflow shr 8));
    Exit((RedBlue and $00FF00FF) or ((AlphaGreen and $00FF00FF) shl 8));
  end;
  DestAlpha := Dest shr 24;
  if Mode in [bbAlpha, bbErase] then
  begin
    if Mode = bbErase then
      SourceAlpha := 255 - SourceAlpha;
    Result := 0;
    for Shift in [0, 8, 16, 24] do
      Result := Result or (Cardinal((Integer((Dest shr Shift) and 255) * SourceAlpha + 127) div 255) shl Shift);
    Exit;
  end;
  Alpha := SourceAlpha + (DestAlpha * (255 - SourceAlpha) + 127) div 255;
  Result := Cardinal(Alpha) shl 24;
  for Shift in [0, 8, 16] do
  begin
    S := (Source shr Shift) and 255;
    D := (Dest shr Shift) and 255;
    case Mode of
      bbAdd:
        Channel := Min(255, S + D);
      bbSubtract:
        Channel := Max(0, D - S);
      bbScreen:
        Channel := S + (D * (255 - S) + 127) div 255;
    else
      if DestAlpha = 0 then
        Channel := S
      else
      begin
        CS := S / SourceAlpha;
        CD := D / DestAlpha;
        case Mode of
          bbMultiply:
            Mixed := CS * CD;
          bbLighten:
            Mixed := Max(CS, CD);
          bbDarken:
            Mixed := Min(CS, CD);
          bbDifference:
            Mixed := Abs(CS - CD);
          bbInvert:
            Mixed := 1 - CD;
          bbOverlay:
            if CD <= 0.5 then
              Mixed := 2 * CS * CD
            else
              Mixed := 1 - 2 * (1 - CS) * (1 - CD);
          bbHardLight:
            if CS <= 0.5 then
              Mixed := 2 * CS * CD
            else
              Mixed := 1 - 2 * (1 - CS) * (1 - CD);
        else
          Mixed := CS;
        end;
        Channel := Round((S * (255 - DestAlpha) + D * (255 - SourceAlpha) + SourceAlpha * DestAlpha * Mixed) / 255);
      end;
    end;
    Result := Result or (Cardinal(EnsureRange(Channel, 0, 255)) shl Shift);
  end;
end;

const
  FlashFilteredRasterEntryPixels = 128 * 1024;

function CanCacheFilters(const Filters: TSWFFilters): Boolean;
const
  SnapshotFilters =[ sfBlur,  sfGlow,  sfDropShadow,  sfBevel,  sfColorMatrix];
begin
  if Length(Filters) > 32 then
    Exit(False);
  for var I := 0 to High(Filters) do
    if not (Filters[I].Kind in SnapshotFilters) or (Filters[I].Kernel <> nil) or
      (Filters[I].GradientStops <> nil) or (Filters[I].MapBitmap <> nil) then
      Exit(False);
  Result := True;
end;

function TFlashPlayer.FindFilteredRaster(C: TFlashClip): PFlashFilteredRaster;
begin
  for var I := Low(FFilteredRasters) to High(FFilteredRasters) do
    if FFilteredRasters[I].Owner = C then
      Exit(@FFilteredRasters[I]);
  Result := nil;
end;

function TFlashPlayer.FilteredLayerState(C: TFlashClip; const Matrix: TSWFMatrix; const Stage: TSWFRect; Opacity: Double): TBytes;
type
  TNodeState = packed record
    Serial, TextRevision: UInt64;
    ContentGeneration: Cardinal;
    LibraryRef, CharacterRef, TextRef: System.Pointer;
    Transform: TSWFMatrix;
    Color: TSWFColorTransform;
    Depth, MorphRatio, ButtonState, ButtonStates, FontId, ChildCount, FilterCount: Integer;
    TextWidth, TextLeft, TextTop: Double;
    Visible, IsText: Boolean;
  end;
const
  NodeLimit = 64;
  StateLimit = 16 * 1024;
var
  State: TMemoryStream;
  NodeCount: Integer;

  function Visit(Node: TFlashClip; IsRoot: Boolean): Boolean;
  var
    Key: TNodeState;
    Child: TFlashClip;
  begin
    Inc(NodeCount);
    // Mutable raster sources and AVM1 text bindings need the normal render path.
    if (NodeCount > NodeLimit) or (Node.FSerial = 0) or Node.Dead or Node.Removing or
      Node.HasScrollRect or Node.HasAppliedScrollRect or Node.RenderingMask or Node.TestingMask or
      (Node.AttachedBitmap <> nil) or Node.DrawingTouched or (Node.Fill <> 0) or (Node.FStrokePoints <> nil) or
      (Node.Drawing.Fills <> nil) or
      (Node.Drawing.Edges <> nil) or (Node.Drawing.StrokePaths <> nil) or
      ((Node.Character <> nil) and (Node.Character.Video <> nil)) or
      (Node.IsText and (Node.VariableName <> '') and not Node.MovieLibrary.Movie.UsesAVM2) then
      Exit(False);
    if (not IsRoot) and ((Node.Masker <> nil) or (Node.Maskee <> nil) or (Node.ClipDepth <> 0) or
      (Node.BlendMode <> bbNormal) or not CanCacheFilters(Node.Filters)) then
      Exit(False);
    if Node.Character <> nil then
      for var Style in Node.Character.Fills do
        if Style.BitmapData <> nil then
          Exit(False);
    Key := Default(TNodeState);
    Key.Serial := Node.FSerial;
    Key.ContentGeneration := Node.ContentGeneration;
    Key.LibraryRef := System.Pointer(Node.MovieLibrary);
    Key.CharacterRef := System.Pointer(Node.Character);
    if not IsRoot then
    begin
      Key.Transform := Node.Matrix;
      Key.Color := Node.ColorTransform;
      Key.FilterCount := Length(Node.Filters);
    end;
    Key.Depth := Node.Depth;
    Key.MorphRatio := Node.MorphRatio;
    Key.ButtonStates := Node.ButtonStates;
    Key.ButtonState := Node.ButtonState;
    Key.ChildCount := Node.Children.Count;
    Key.Visible := Node.Visible;
    Key.IsText := Node.IsText;
    if Node.IsText then
    begin
      if Node.FTextDocument = nil then
        Exit(False);
      Key.TextRef := System.Pointer(Node.FTextDocument);
      Key.TextRevision := Node.FTextDocument.Revision;
      Key.FontId := Node.FontId;
      Key.TextWidth := Node.TextWidth;
      Key.TextLeft := Node.TextLeft;
      Key.TextTop := Node.TextTop;
    end;
    if State.Size + SizeOf(Key) + Key.FilterCount * SizeOf(TSWFFilter) > StateLimit then
      Exit(False);
    State.WriteBuffer(Key, SizeOf(Key));
    if Key.FilterCount <> 0 then
      State.WriteBuffer(Node.Filters[0], Key.FilterCount * SizeOf(TSWFFilter));
    for Child in Node.Children do
      if not Visit(Child, False) then
        Exit(False);
    Result := True;
  end;

begin
  Result := nil;
  State := TMemoryStream.Create;
  try
    State.WriteBuffer(Matrix, SizeOf(Matrix));
    State.WriteBuffer(Stage, SizeOf(Stage));
    State.WriteBuffer(Opacity, SizeOf(Opacity));
    State.WriteBuffer(FRender.Quality, SizeOf(FRender.Quality));
    State.WriteBuffer(FClipRenderDepth, SizeOf(FClipRenderDepth));
    NodeCount := 0;
    if Visit(C, True) then
    begin
      SetLength(Result, State.Size);
      Move(State.Memory^, Result[0], State.Size);
    end;
  finally
    State.Free;
  end;
end;

procedure TFlashPlayer.FilterLayer(C: TFlashClip; var Layer: TArray<Cardinal>; Width, Height: Integer; const Content: TSWFRect; const Filters: TSWFFilters; const State: TBytes; RasterWork: Int64);
const
  // Bound both input snapshots and premultiplied output to 8 MiB in total.
  CachePixels = 1024 * 1024;
var
  Raster, Oldest, Empty: PFlashFilteredRaster;
  Input: TArray<Cardinal>;
  PreviousWork: Int64;
  PixelCount: Integer;
begin
  PixelCount := Length(Layer);
  if (PixelCount <= 0) or (PixelCount > FlashFilteredRasterEntryPixels) or
    (Filters = nil) or not CanCacheFilters(Filters) then
  begin
    ApplyFlashFilters(Layer, Width, Height, Content, Filters, FRender.Work);
    Exit;
  end;

  Inc(FFilterSequence);
  Raster := FindFilteredRaster(C);
  // The input is the resolved layer before the instance's output color and
  // masks. The filter kinds above depend only on these pixels and scalar data.
  if (Raster <> nil) and (Raster.Width = Width) and (Raster.Height = Height) and
    CompareMem(@Raster.Content, @Content, SizeOf(Content)) and
    (Length(Raster.Filters) = Length(Filters)) and
    CompareMem(@Raster.Filters[0], @Filters[0], Length(Filters) * SizeOf(TSWFFilter)) and
    CompareMem(@Raster.Input[0], @Layer[0], PixelCount * SizeOf(Cardinal)) then
  begin
    Inc(FRender.Work, Raster.Work);
    if FRender.Work > FlashRenderWorkLimit then
      raise ESWFError.Create('Flash frame rendering work limit');
    Raster.LastUsed := FFilterSequence;
    Raster.State := State;
    Raster.RasterWork := RasterWork;
    Layer := Raster.Output;
    Exit;
  end;

  Input := Copy(Layer);
  PreviousWork := FRender.Work;
  ApplyFlashFilters(Layer, Width, Height, Content, Filters, FRender.Work);
  if Raster <> nil then
  begin
    Dec(FFilteredPixels, Length(Raster.Input));
    Raster^ := Default(TFlashFilteredRaster);
  end;
  while (Raster = nil) or (PixelCount + FFilteredPixels > CachePixels) do
  begin
    Oldest := nil;
    Empty := nil;
    for var I := Low(FFilteredRasters) to High(FFilteredRasters) do
      if FFilteredRasters[I].Owner = nil then
        Empty := @FFilteredRasters[I]
      else if (Oldest = nil) or (FFilteredRasters[I].LastUsed < Oldest.LastUsed) then
        Oldest := @FFilteredRasters[I];
    if (Empty <> nil) and (PixelCount + FFilteredPixels <= CachePixels) then
      Raster := Empty
    else
    begin
      Dec(FFilteredPixels, Length(Oldest.Input));
      Oldest^ := Default(TFlashFilteredRaster);
      Raster := Oldest;
    end;
  end;
  // Keep a snapshot of the filter values even if the caller reuses its array.
  Raster.Filters := Copy(Filters);
  Raster.Owner := C;
  Raster.Content := Content;
  Raster.Width := Width;
  Raster.Height := Height;
  Raster.Input := Input;
  Raster.Output := Layer;
  Raster.Work := FRender.Work - PreviousWork;
  Raster.State := State;
  Raster.RasterWork := RasterWork;
  Raster.LastUsed := FFilterSequence;
  Inc(FFilteredPixels, PixelCount);
end;

procedure TFlashPlayer.RenderClipGroup(C: TFlashClip; const Matrix: TSWFMatrix; Opacity: Double; var Pixels: TArray<Cardinal>);
var
  Mode: TAVMBitmapBlend;
  UseParentLayer, Filtered, TransformOutput: Boolean;
  Bounds: TSWFBounds;
  Region, Destination, Stage, FilterContent: TSWFRect;
  PadX, PadY, SnapX, SnapY: Integer;
  Filters: TSWFFilters;
  InputColor, OutputColor: TSWFColorTransform;
  InputMatrix: TSWFMatrix;
  Width, Height, X, Y, Sample, Index, GroupIndex, LocalDetail, GroupDetail, ParentDetail, ParentIndex: Integer;
  ParentX, ParentY, ParentXOffset, ParentYOffset: Integer;
  Previous: TFlashRenderState;
  Layer, LayerDetailColors: TArray<Cardinal>;
  LayerDetailIndex: TArray<Integer>;
  Coverage: Word;
  PreviousCoverage: TBytes;
  Source, Back, LayerBack: Cardinal;
  State: TBytes;
  Raster: PFlashFilteredRaster;

  function CacheSnap(Value, Origin: Integer): Integer;
  var
    Offset: Int64;
  begin
    Offset := Int64(Value) - Origin;
    if Offset >= 0 then
      Result := ((Offset + 10) div 20) * 20 - Offset
    else
      Result := -((10 - Offset) div 20) * 20 - Offset;
  end;

  procedure SetParentSample;
  begin
    ParentDetail := -1;
    LayerBack := 0;
    ParentX := X + ParentXOffset;
    ParentY := Y + ParentYOffset;
    if (ParentX < 0) or (ParentX >= FRender.ParentLayer^.Width) or
      (ParentY < 0) or (ParentY >= FRender.ParentLayer^.Height) then
      Exit;
    ParentIndex := ParentY * FRender.ParentLayer^.Width + ParentX;
    LayerBack := FRender.ParentLayerPixels^[ParentIndex];
    if FRender.SampleCount > 1 then
      ParentDetail := FRender.ParentLayer^.DetailIndex[ParentIndex] - 1;
  end;

begin
  Mode := C.BlendMode;
  UseParentLayer := (Mode in [bbAlpha, bbErase]) and not FRender.IsLayer;
  if UseParentLayer and (FRender.ParentLayer = nil) then
    Exit;
  if IsNan(Matrix.A) or IsInfinite(Matrix.A) or IsNan(Matrix.B) or IsInfinite(Matrix.B) or
    IsNan(Matrix.C) or IsInfinite(Matrix.C) or IsNan(Matrix.D) or IsInfinite(Matrix.D) then
    Exit;
  Filtered := (FRender.DrawableRoot = nil) and HasFlashFilters(C.Filters);
  Bounds := BoundsWithMatrix(C, Matrix, False, True, FRender.DrawableRoot = nil);
  if not Bounds.Valid then
    Exit;
  PadX := 0;
  PadY := 0;
  SnapX := 0;
  SnapY := 0;
  OutputColor := FRender.Color;
  InputColor := OutputColor;
  InputMatrix := Matrix;
  TransformOutput := False;
  if Filtered then
  begin
    Filters := C.Filters;
    FlashFilterPadding(Filters, PadX, PadY, True);
    InputColor := TSWFColorTransform.Identity;
    SnapX := CacheSnap(Bounds.Rect.Left, FRender.Stage.Left);
    SnapY := CacheSnap(Bounds.Rect.Top, FRender.Stage.Top);
    InputMatrix.TX := Matrix.TX + SnapX;
    InputMatrix.TY := Matrix.TY + SnapY;
    TransformOutput := HasPaintColorTransform(OutputColor);
  end;
  // Retain a margin for snapped bitmaps and one-pixel strokes.
  Region.Left := Floor((Int64(Bounds.Rect.Left) - FRender.Stage.Left) / 20) - 1 - PadX;
  Region.Top := Floor((Int64(Bounds.Rect.Top) - FRender.Stage.Top) / 20) - 1 - PadY;
  Region.Right := Ceil((Int64(Bounds.Rect.Right) - FRender.Stage.Left) / 20) + 1 + PadX;
  Region.Bottom := Ceil((Int64(Bounds.Rect.Bottom) - FRender.Stage.Top) / 20) + 1 + PadY;
  // Displacement can sample any part of the clip, including an offscreen edge.
  if not HasFlashDisplacement(Filters) then
  begin
    Region.Left := Max(-PadX, Region.Left);
    Region.Top := Max(-PadY, Region.Top);
    Region.Right := Min(FRender.Width + PadX, Region.Right);
    Region.Bottom := Min(FRender.Height + PadY, Region.Bottom);
  end;
  Destination.Left := Max(0, Region.Left);
  Destination.Top := Max(0, Region.Top);
  Destination.Right := Min(FRender.Width, Region.Right);
  Destination.Bottom := Min(FRender.Height, Region.Bottom);
  if (Destination.Right <= Destination.Left) or (Destination.Bottom <= Destination.Top) then
    Exit;
  Width := Region.Right - Region.Left;
  Height := Region.Bottom - Region.Top;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  Inc(FRender.Work, Int64(Width) * Height);
  if FRender.Work > FlashRenderWorkLimit then
    raise ESWFError.Create('Flash frame rendering work limit');
  Stage.Left := FRender.Stage.Left + Region.Left * 20;
  Stage.Top := FRender.Stage.Top + Region.Top * 20;
  Stage.Right := FRender.Stage.Left + Region.Right * 20;
  Stage.Bottom := FRender.Stage.Top + Region.Bottom * 20;
  if Filtered then
  begin
    FilterContent.Left := Floor((Int64(Bounds.Rect.Left) - Stage.Left + SnapX) / 20);
    FilterContent.Top := Floor((Int64(Bounds.Rect.Top) - Stage.Top + SnapY) / 20);
    FilterContent.Right := Ceil((Int64(Bounds.Rect.Right) - Stage.Left + SnapX) / 20);
    FilterContent.Bottom := Ceil((Int64(Bounds.Rect.Bottom) - Stage.Top + SnapY) / 20);
    if (Int64(Width) * Height <= FlashFilteredRasterEntryPixels) and CanCacheFilters(Filters) then
    begin
      State := FilteredLayerState(C, InputMatrix, Stage, Opacity);
      if State <> nil then
      begin
        Raster := FindFilteredRaster(C);
        if (Raster <> nil) and (Raster.Width = Width) and (Raster.Height = Height) and
          CompareMem(@Raster.Content, @FilterContent, SizeOf(FilterContent)) and
          (Length(Raster.Filters) = Length(Filters)) and
          CompareMem(@Raster.Filters[0], @Filters[0], Length(Filters) * SizeOf(TSWFFilter)) and
          (Length(Raster.State) = Length(State)) and
          CompareMem(@Raster.State[0], @State[0], Length(State)) then
        begin
          // Keep charging the work for rasterization and filtering on cache hits.
          Inc(FRender.Work, Raster.RasterWork + Raster.Work);
          if FRender.Work > FlashRenderWorkLimit then
            raise ESWFError.Create('Flash frame rendering work limit');
          Inc(FFilterSequence);
          Raster.LastUsed := FFilterSequence;
          Layer := Raster.Output;
        end;
      end;
    end;
  end;
  if Layer = nil then
  begin
    SetLength(Layer, Width * Height);
    try
      BeginRender(Width, Height, Stage, InputColor, True, FRender.Quality, Previous);
      FRender.Work := Previous.Work;
      FRender.DrawableRoot := Previous.DrawableRoot;
      FRender.DrawableMatrix := Previous.DrawableMatrix;
      FRender.IsLayer := (Mode = bbLayer) and not Filtered;
      if not (FRender.IsLayer or Filtered) then
      begin
        if Previous.IsLayer then
        begin
          FRender.ParentLayer := @Previous;
          FRender.ParentLayerPixels := @Pixels;
        end
        else
        begin
          FRender.ParentLayer := Previous.ParentLayer;
          FRender.ParentLayerPixels := Previous.ParentLayerPixels;
        end;
      end;
      if Filtered then
      begin
        // Filter the resolved cache in stage pixels before applying the
        // instance color transform and its masks at composition time.
        RenderClipBody(C, C.WithScrollOffset(InputMatrix), Opacity, Layer);
        ResolveSamples(Layer);
        FilterLayer(C, Layer, Width, Height, FilterContent, Filters, State, FRender.Work - Previous.Work);
      end
      else
      begin
        RenderClipWithMask(C, Matrix, Opacity, Layer);
        LayerDetailIndex := FRender.DetailIndex;
        LayerDetailColors := FRender.DetailColors;
      end;
      Previous.Work := FRender.Work;
    finally
      EndRender(Previous);
    end;
  end;

  ParentXOffset := 0;
  ParentYOffset := 0;
  LayerBack := 0;
  if UseParentLayer then
  begin
    ParentXOffset := (FRender.Stage.Left - FRender.ParentLayer^.Stage.Left) div 20;
    ParentYOffset := (FRender.Stage.Top - FRender.ParentLayer^.Stage.Top) div 20;
  end;
  PreviousCoverage := FRender.Coverage;
  try
    if Filtered then
    begin
      if C.Masker <> nil then
        FRender.Coverage := RenderMask(C.Masker, ScriptMaskMatrix(C.Masker), Pixels, True);
      if C.HasAppliedScrollRect then
        FRender.Coverage := RenderScrollCoverage(C, Matrix, Pixels);
    end;
    for Y := Destination.Top to Destination.Bottom - 1 do
    begin
      GroupIndex := (Y - Region.Top) * Width + Destination.Left - Region.Left;
      for X := Destination.Left to Destination.Right - 1 do
      begin
        Source := Layer[GroupIndex];
        GroupDetail := -1;
        if LayerDetailIndex <> nil then
          GroupDetail := LayerDetailIndex[GroupIndex] - 1;
        Inc(GroupIndex);
        if TransformOutput then
          Source := PremultiplyBitmapColor(OutputColor.Apply(UnpremultiplyBitmapColor(Source)), True);
        if (Source shr 24 = 0) and (GroupDetail < 0) then
          Continue;
        Index := Y * FRender.Width + X;
        Coverage := CoverageAt(Index);
        if Coverage = 0 then
          Continue;
        ParentDetail := -1;
        if UseParentLayer then
          SetParentSample;
        LocalDetail := -1;
        if FRender.SampleCount > 1 then
          LocalDetail := FRender.DetailIndex[Index] - 1;
        if (Coverage = FRender.FullCoverage) and (GroupDetail < 0) and (LocalDetail < 0) and (ParentDetail < 0) then
        begin
          Back := Pixels[Index];
          if UseParentLayer then
            Back := LayerBack;
          Pixels[Index] := BlendBitmapLayer(Back, Source, Mode);
          Continue;
        end;
        Inc(FRender.Work, FRender.SampleCount);
        if FRender.Work > FlashRenderWorkLimit then
          raise ESWFError.Create('Flash frame rendering work limit');
        if LocalDetail < 0 then
          LocalDetail := EnsureSampleDetail(Index, Pixels[Index]);
        for Sample := 0 to FRender.SampleCount - 1 do
        begin
          if Coverage and (Word(1) shl Sample) = 0 then
            Continue;
          if GroupDetail >= 0 then
            Source := LayerDetailColors[GroupDetail + Sample];
          if Source shr 24 = 0 then
            Continue;
          Back := FRender.DetailColors[LocalDetail + Sample];
          if ParentDetail >= 0 then
            Back := FRender.ParentLayer^.DetailColors[ParentDetail + Sample]
          else if UseParentLayer then
            Back := LayerBack;
          FRender.DetailColors[LocalDetail + Sample] := BlendBitmapLayer(Back, Source, Mode);
        end;
      end;
    end;
  finally
    FRender.Coverage := PreviousCoverage;
  end;
end;

function TFlashPlayer.ResolveDrawPath(const Path: string): TFlashClip;
var
  I, First, Count, Level: Integer;
  HasSlash, FirstPart, Modern, CaseSensitive: Boolean;
  Name: string;
  O: TAVMObject;
  C, Child: TFlashClip;

  function SameName(const A, B: string): Boolean;
  begin
    if CaseSensitive then
      Result := A = B
    else
      Result := AVMLowerName(A) = AVMLowerName(B);
  end;

begin
  Count := Length(Path);
  if Count = 0 then
    Exit(nil);
  C := Clip(VM.CurrentTarget);
  if C = nil then
    C := FRoot;
  I := 1;
  HasSlash := Path[I] = '/';
  FirstPart := not HasSlash;
  Modern := VM.SWFVersion >= 5;
  CaseSensitive := VM.SWFVersion >= 7;
  if HasSlash then
  begin
    C := ClipRoot(C);
    Inc(I);
  end;
  O := C.Script;
  while I <= Count do
  begin
    if Modern then
      while (I <= Count) and (Path[I] = ':') do
        Inc(I);
    if (Copy(Path, I, 2) = '..') and
      ((I + 1 = Count) or (Path[I + 2] = '/') or (Modern and (Path[I + 2] = ':'))) then
    begin
      C := Clip(O);
      if (C = nil) or (C.Parent = nil) then
        Exit(nil);
      O := C.Parent.Script;
      if (I + 2 <= Count) and (Path[I + 2] = '/') then
        HasSlash := True;
      Inc(I, 3);
    end
    else
    begin
      First := I;
      while I <= Count do
      begin
        if Path[I] = '/' then
        begin
          HasSlash := True;
          Break;
        end;
        if Modern and ((Path[I] = ':') or ((Path[I] = '.') and not HasSlash)) then
          Break;
        Inc(I);
      end;
      Name := Copy(Path, First, I - First);
      Inc(I);
      if FirstPart and Modern and SameName(Name, '_root') then
      begin
        C := Clip(VM.CurrentTarget);
        if C = nil then
          C := FRoot;
        O := ClipRoot(C).Script;
      end
      else if FirstPart and AVMParseLevelName(Name, VM.SWFVersion, Level) then
      begin
        C := LevelClip(Level, False);
        if C = nil then
          Exit(nil);
        O := C.Script;
      end
      else
      begin
        C := Clip(O);
        if (C <> nil) and (Name <> '') then
          for Child in C.Children do
            if not Child.Dead and not Child.Removing and SameName(Child.Name, Name) then
            begin
              O := Child.Script;
              Break;
            end;
        if (C = nil) or (O = C.Script) then
          O := VM.Get(O, Name).Obj;
      end;
    end;
    if O = nil then
      Exit(nil);
    FirstPart := False;
  end;
  Result := Clip(O);
end;

procedure TFlashPlayer.ApplyBitmapFilter(const Dest, Source: IImagePixelBuffer; const Rect: TSWFRect; X, Y: Integer; const Filter: TSWFFilter);
begin
  ApplyFlashBitmapFilter(Dest, Source, Rect, X, Y, Filter, VM.ChargeWork);
end;

function TFlashPlayer.BitmapFilterRect(const Rect: TSWFRect; const Filter: TSWFFilter): TSWFRect;
begin
  Result := FlashBitmapFilterRect(Rect, Filter);
end;

function TFlashPlayer.DrawBitmapData(const Target: IImagePixelBuffer; const Source: TAVMValue; const Options: TAVMBitmapDrawOptions): Integer;
var
  Bitmap: IImagePixelBuffer;
  C: TFlashClip;
  Matrix: TSWFMatrix;
  Stage: TSWFRect;
  Bounds: TSWFBounds;
  Pixels, TargetPixels: TArray<Cardinal>;
  Previous: TFlashRenderState;
  Left, Top, Right, Bottom, Width, Height, X, Y, I, TX, TY, TargetWidth: Integer;
  Color, Original: Cardinal;
  Blit, IdentityColor: Boolean;
begin
  C := nil;
  if Source.Obj <> nil then
    Bitmap := Source.Obj.BitmapData;
  if Bitmap <> nil then
  begin
    if Bitmap.Disposed then
      Exit(-3);
    if Options.Blend in [bbAlpha, bbErase] then
      Exit(0);
  end
  else
  begin
    C := Clip(Source.Obj);
    if (C = nil) and (Source.Kind = avString) then
      C := ResolveDrawPath(Source.Text);
    if (C = nil) or C.Dead or C.Removing then
      Exit(-2);
  end;

  if Target.Disposed then
    Exit(-1);
  Matrix := Options.Matrix;
  if IsNan(Matrix.A) or IsInfinite(Matrix.A) or IsNan(Matrix.B) or IsInfinite(Matrix.B) or
    IsNan(Matrix.C) or IsInfinite(Matrix.C) or IsNan(Matrix.D) or IsInfinite(Matrix.D) then
    Exit(0);
  Blit := (Bitmap <> nil) and (Options.Blend in [bbNormal, bbLayer]) and
    (Matrix.A = 1) and (Matrix.B = 0) and (Matrix.C = 0) and (Matrix.D = 1);
  TX := Floor(Matrix.TX / 20);
  TY := Floor(Matrix.TY / 20);
  Left := 0;
  Top := 0;
  Right := Target.Width;
  Bottom := Target.Height;
  if Options.HasClip then
  begin
    if (Options.ClipRect.Right <= Options.ClipRect.Left) or
      (Options.ClipRect.Bottom <= Options.ClipRect.Top) then
      Exit(0);
    Left := Floor(Options.ClipRect.Left / 20);
    Top := Floor(Options.ClipRect.Top / 20);
    if Blit then
    begin
      Right := Left + Ceil((Int64(Options.ClipRect.Right) - Options.ClipRect.Left) / 20);
      Bottom := Top + Ceil((Int64(Options.ClipRect.Bottom) - Options.ClipRect.Top) / 20);
    end
    else
    begin
      Right := Ceil(Options.ClipRect.Right / 20);
      Bottom := Ceil(Options.ClipRect.Bottom / 20);
    end;
    Left := Max(0, Left);
    Top := Max(0, Top);
    Right := Min(Target.Width, Right);
    Bottom := Min(Target.Height, Bottom);
  end;
  if Blit then
  begin
    Left := Max(Left, TX);
    Top := Max(Top, TY);
    Right := Min(Right, TX + Bitmap.Width);
    Bottom := Min(Bottom, TY + Bitmap.Height);
  end
  else
  begin
    Bounds := TSWFBounds.Empty;
    if Bitmap <> nil then
    begin
      Stage := Default(TSWFRect);
      Stage.Right := Bitmap.Width * 20;
      Stage.Bottom := Bitmap.Height * 20;
      Bounds := TSWFBounds.FromRect(Stage).Transformed(Matrix);
    end
    else
    begin
      C.ApplyScrollRect;
      Bounds := BoundsWithMatrix(C, Matrix, False, True);
    end;
    if not Bounds.Valid then
      Exit(0);
    // Keep adjacent pixels for subpixel coverage and snapped bitmap placements.
    Left := Max(Left, Floor(Bounds.Rect.Left / 20) - 1);
    Top := Max(Top, Floor(Bounds.Rect.Top / 20) - 1);
    Right := Min(Right, Ceil(Bounds.Rect.Right / 20) + 1);
    Bottom := Min(Bottom, Ceil(Bounds.Rect.Bottom / 20) + 1);
  end;
  if (Right <= Left) or (Bottom <= Top) then
    Exit(0);
  Width := Right - Left;
  Height := Bottom - Top;
  VM.ChargeWork(1 + (Width * Height - 1) div 32);
  SetLength(Pixels, Width * Height);
  if Blit then
  begin
    IdentityColor := True;
    for I := 0 to 3 do
      IdentityColor := IdentityColor and (Options.ColorTransform.Mult[I] = 1) and (Options.ColorTransform.Add[I] = 0);
    I := 0;
    for Y := Top to Bottom - 1 do
      for X := Left to Right - 1 do
      begin
        Color := Bitmap.PixelPremultiplied(X - TX, Y - TY);
        if not IdentityColor then
          Color := PremultiplyBitmapColor(Options.ColorTransform.Apply(UnpremultiplyBitmapColor(Color)), True);
        Pixels[I] := BlendPremultiplied(Target.PixelPremultiplied(X, Y), Color);
        Inc(I);
      end;
  end
  else
  begin
    Stage.Left := Left * 20;
    Stage.Top := Top * 20;
    Stage.Right := Right * 20;
    Stage.Bottom := Bottom * 20;
    if Options.Blend = bbNormal then
    begin
      TargetWidth := Target.Width;
      TargetPixels := Target.SnapshotPremultiplied;
      if (TargetPixels <> nil) and (TargetWidth >= Right) and (Target.Height >= Bottom) and
        (Length(TargetPixels) = Int64(TargetWidth) * Target.Height) then
      begin
        if Width = TargetWidth then
          Move(TargetPixels[Top * TargetWidth], Pixels[0], NativeInt(Width) * Height * SizeOf(Cardinal))
        else
          for Y := Top to Bottom - 1 do
            Move(TargetPixels[Y * TargetWidth + Left], Pixels[(Y - Top) * Width],
              NativeInt(Width) * SizeOf(Cardinal));
      end
      else
      begin
        I := 0;
        for Y := Top to Bottom - 1 do
          for X := Left to Right - 1 do
          begin
            Pixels[I] := Target.PixelPremultiplied(X, Y);
            Inc(I);
          end;
      end;
      TargetPixels := nil;
    end;
    try
      BeginRender(Width, Height, Stage, Options.ColorTransform, True, FQuality, Previous);
      FRender.IsLayer := True;
      FRender.DrawableRoot := C;
      FRender.DrawableMatrix := Matrix;
      if Options.HasClip and
        ((Options.ClipRect.Left mod 20 <> 0) or (Options.ClipRect.Top mod 20 <> 0) or
        (Options.ClipRect.Right mod 20 <> 0) or (Options.ClipRect.Bottom mod 20 <> 0)) then
        FRender.Coverage := RenderRectCoverage(Options.ClipRect, TSWFMatrix.Identity, Pixels);
      if Bitmap <> nil then
        RenderBitmap(Bitmap.Width, Bitmap.Height, Bitmap.SnapshotPremultiplied, Matrix,
          Options.Smooth, True, 1, Pixels, False)
      else
      begin
        if C.Masker <> nil then
          FRender.Coverage := RenderMask(C.Masker, ScriptMaskMatrix(C.Masker), Pixels, True);
        RenderClipViewport(C, Matrix, 1, Pixels);
      end;
      ResolveSamples(Pixels);
      VM.ChargeWork(Integer(FRender.Work div 32));
    finally
      EndRender(Previous);
    end;
  end;

  if Target.Disposed then
    Exit(-1);
  if (Blit or (Options.Blend = bbNormal)) and
    Target.TryWritePremultiplied(Pixels, Left, Top, Width, Height) then
    Exit(0);
  I := 0;
  for Y := Top to Bottom - 1 do
    for X := Left to Right - 1 do
    begin
      Color := Pixels[I];
      if not Blit and (Options.Blend <> bbNormal) then
      begin
        Original := Target.PixelPremultiplied(X, Y);
        Color := BlendBitmapLayer(Original, Color, Options.Blend);
      end;
      Target.SetPixelPremultiplied(X, Y, Color);
      Inc(I);
    end;
  Result := 0;
end;

end.

